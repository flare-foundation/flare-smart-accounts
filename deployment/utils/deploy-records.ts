/**
 * Merging deployed addresses into a network's deployment record.
 *
 * Almost every record is replaced freely, because that is what the tooling is for: a redeployed
 * facet, a new account implementation. The two below are different. They name the live diamond and
 * the live composer proxy — the addresses users hold a position in, and the ones other tooling
 * resolves *through* the record, since `check_cut` and `verify_diamond` take the diamond from
 * `MasterAccountController`. Replacing one silently does not touch the live contract; it makes
 * every later check ask its questions of an address that was never live.
 *
 * The way that happens by accident: `deploy_contracts <network> false` is documented as a
 * facet-only mode, but `false` only skips the diamond cut and the vault configuration. The script
 * still deploys a controller and both implementations from current source and records them — and
 * current source deliberately cannot reproduce the historical production controller address. So a
 * command described as harmless can point the tooling at an address that was never live.
 */

export type ContractInfo = {
  name: string;
  contractName: string;
  address: string;
};

/** What a deploy script's printed record lines say: which network, and which entries. */
export type DeployOutput = {
  /** From the `NETWORK:` line; undefined when the output carries none. */
  network: string | undefined;
  contracts: ContractInfo[];
};

/**
 * Reads the record lines a deploy script prints, as the wrappers capture them.
 *
 * `NETWORK:` names the record file and `DEPLOYED: <name>, <Source>.sol: <address>` names one entry.
 * The grammar lives here because two steps read the same file: the runtime check that decides
 * whether an entry may be promoted, and the recorder that promotes it. Anything else in the output
 * - forge's own logging, the script's progress lines - is ignored, so the file may be a full
 * transcript rather than a prepared list.
 */
export function parseDeployOutput(output: string): DeployOutput {
  const contracts: ContractInfo[] = [];
  let network: string | undefined;

  for (const line of output.split("\n")) {
    const deployed = line.match(/^\s*DEPLOYED:\s*([^,]+),\s*([^:]+):\s*(0x[a-fA-F0-9]{40})$/);
    const named = line.match(/^\s*NETWORK:\s*([a-zA-Z0-9_-]+)/);
    if (deployed && deployed[1] && deployed[2] && deployed[3]) {
      contracts.push({ name: deployed[1].trim(), contractName: deployed[2].trim(), address: deployed[3].trim() });
    } else if (named && named[1]) {
      network = named[1].trim();
    }
  }

  return { network, contracts };
}

/**
 * Records that name a contract users hold a position in, whose address is not supposed to change
 * for the life of a deployment. Their existing entry may not be replaced without saying so.
 *
 * Deliberately short. Implementation records are NOT here: `deploy_personal_account_implementation`
 * and its siblings exist to deploy a new implementation and record it, so their entries are meant
 * to follow every upgrade. Protecting those would demand the override on the ordinary upgrade path,
 * the flag would end up set permanently, and this guard would stop guarding anything. Facet records
 * are the same story — a redeployed facet is the ordinary cut flow.
 *
 * Not the pinned-Ethereum list either, which is stricter and narrower: those may hold only their
 * one pinned address, on one chain. These may hold any address, on any network — they just may not
 * change quietly, so re-bootstrapping a network from scratch is the one case that needs the flag.
 */
export const PROTECTED_RECORD_NAMES = ["MasterAccountController", "FAssetRedeemComposer_FXRP"] as const;

/** Names the caller has explicitly authorized replacing, from `ALLOW_RECORD_REPLACEMENT`. */
export function parseAllowedReplacements(raw: string | undefined): Set<string> {
  return new Set(
    (raw ?? "")
      .split(",")
      .map((name) => name.trim())
      .filter((name) => name.length > 0)
  );
}

/**
 * Merges `deployed` into `existing`, in place of same-name entries, appending the rest.
 *
 * Replacing a protected record's existing entry with a different address throws unless its name is
 * in `allowedReplacements`. Re-recording the same address is always fine: a rerun that redeploys
 * nothing should not need a flag.
 */
export function mergeDeployedRecords(
  existing: ContractInfo[],
  deployed: ContractInfo[],
  allowedReplacements: Set<string> = new Set()
): ContractInfo[] {
  const merged = [...existing];
  for (const record of deployed) {
    const index = merged.findIndex((item) => item.name === record.name);
    if (index < 0) {
      merged.push(record);
      continue;
    }
    const current = merged[index];
    const isProtected = (PROTECTED_RECORD_NAMES as readonly string[]).includes(record.name);
    const isChange = current !== undefined && current.address.toLowerCase() !== record.address.toLowerCase();
    if (isProtected && isChange && !allowedReplacements.has(record.name)) {
      throw new Error(
        `${record.name}: refusing to replace the recorded address ${current?.address} with ` +
          `${record.address}. Other tooling resolves the live deployment through this record, so ` +
          `replacing it by accident misdirects every later check. Nothing was written, and the ` +
          `forge output file is kept, so if this replacement is deliberate you do NOT need to ` +
          `deploy again — rerun the recorder alone with the override: ` +
          `ALLOW_RECORD_REPLACEMENT=${record.name} npx tsx deployment/scripts/save-deployed-addresses.ts ` +
          `(comma-separate several names).`
      );
    }
    merged[index] = record;
  }
  return merged;
}
