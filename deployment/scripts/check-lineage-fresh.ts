/**
 * Proxy-lineage freshness check, for the pre-cut storage-layout gate.
 *
 * An implementation whose storage layout was re-laid may only be deployed while no proxy of its
 * lineage exists on that network. The check is decisive where the chain offers a decisive
 * signal and fails closed everywhere else - it never infers freshness from silence:
 *
 * - a Personal Account proxy resolves the controller's beacon in its own constructor and
 *   delegate-calls `initialize`, which reverts while the beacon is unset, and the setter refuses
 *   a codeless address, so the beacon can never return to zero. A zero beacon therefore proves
 *   no Personal Account was ever created here; a non-zero one means proxies may exist;
 * - a subaccount proxy can only be created when `implementationForType(type)` is non-zero
 *   (`Subaccounts.createSubaccount` requires it) and that value can never return to zero
 *   either, but the type space is unbounded, so probing the low types can prove NOT fresh (a
 *   registration found) but can never prove fresh. Freshness needs the registration history: the
 *   `SubaccountImplementationSet` events since the diamond's creation. An RPC that serves
 *   full-range logs (a private node; the public Flare RPCs cap a query at 30 blocks) makes this
 *   decisive; without one the check fails closed;
 * - a facet that is absent now may still have been installed earlier - by the full deploy or by
 *   a cut - and removed after proxies were created. With the event history available, the
 *   history decides. Without it, the retained history of the repository's records decides: the
 *   network's deployment record and its cut files as they stand, plus every version of them that
 *   git holds on the refs of this clone (the records themselves are mutable - a facet has been
 *   dropped from a deployment record before - so only the history counts, and a shallow clone
 *   cannot answer). A facet named anywhere in that history, historical or example records
 *   included, may have been installed, and its lineage is NOT PROVEN; a facet named nowhere is
 *   called fresh on the stated assumption that every installation was committed under the
 *   canonical facet name before execution and remains reachable from this clone's refs. The event
 *   history is the check that needs no assumption.
 *
 * Preconditions are checked, not assumed: an unknown network, a network without a deployment
 * record, a malformed record or cut file, a record without exactly one controller, a recorded
 * controller without code, or an RPC answering with another chain id all fail; a shallow clone
 * blocks only the git fallback, never the decisive on-chain checks. Caveat: a proxy deployed
 * outside the controller (own CREATE2, own salt) is invisible here, but it also would not sit at
 * a canonical address.
 *
 * Usage:
 *   pnpm check_lineage_fresh <network> [subaccounts|personal-accounts|all]
 * The RPC comes from `<NETWORK>_RPC_URL` (environment or the repository's env file), else the
 * public Flare RPC of a Flare-family network; the loan chains have no default.
 */

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync } from "node:fs";
import { Web3 } from "web3";
import { assertRpcChain } from "../utils/diamond-inspect";
import { resolveRpcUrl, validateNetwork } from "../utils/networks";

/** Subaccount types probed while the facet is cut: 0 is reserved, the space is a raw counter from 1. */
const PROBED_SUBACCOUNT_TYPES = 32;

const IMPLEMENTATION_FOR_TYPE_ABI = {
  name: "implementationForType",
  type: "function",
  inputs: [{ name: "subaccountType", type: "uint256" }],
  outputs: [{ name: "", type: "address" }],
} as const;

const IMPLEMENTATION_ABI = {
  name: "implementation",
  type: "function",
  inputs: [],
  outputs: [{ name: "", type: "address" }],
} as const;

const ZERO = "0x0000000000000000000000000000000000000000";
/** `Diamond.FunctionNotFound(bytes4)`: the facet carrying this selector is not cut now. */
const FUNCTION_NOT_FOUND = "0x5416eb98";
/** A getter whose facet is not cut now: an answer, not a failure. */
const NOT_CUT = Symbol("not-cut");

type Verdict = "fresh" | "not-fresh" | "unproven";
type DeployRecord = { name: string; address: string };

function deployRecordPath(network: string): string {
  return `deployment/deploys/${network}.json`;
}

function cutsDir(network: string): string {
  return `deployment/cuts/${network}`;
}

/** The network's deployment record, every entry checked: a malformed entry is an error, not a skip. */
function readDeployRecords(network: string): DeployRecord[] {
  const path = deployRecordPath(network);
  if (!existsSync(path)) {
    throw new Error(
      `${network}: no deployment record (${path}). Freshness is not inferred from a missing record: ` +
        "if nothing was ever deployed there, the runbook says so; if something was, record it first"
    );
  }
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(raw)) {
    throw new Error(`Invalid deployed contracts file: ${path}`);
  }
  return raw.map((item, index): DeployRecord => {
    const name = (item as { name?: unknown }).name;
    const address = (item as { address?: unknown }).address;
    if (typeof item !== "object" || item === null || typeof name !== "string" || typeof address !== "string") {
      throw new Error(`Malformed entry ${index} in ${path}: expected an object with string "name" and "address"`);
    }
    return { name, address };
  });
}

/** The one controller the record names; none or several is a broken record, not a choice. */
function findController(records: DeployRecord[], network: string): string {
  const controllers = records.filter((item) => item.name === "MasterAccountController");
  const [controller] = controllers;
  if (controllers.length !== 1 || controller === undefined) {
    throw new Error(
      `${deployRecordPath(network)} records ${controllers.length} MasterAccountController entries; exactly one is required`
    );
  }
  return controller.address;
}

/**
 * The facets named by the network's cut files as they stand, nested directories included (the cut
 * executor accepts path-based names); a malformed cut file is an error.
 */
function facetsInCurrentCuts(network: string): string[] {
  const dir = cutsDir(network);
  if (!existsSync(dir)) {
    return [];
  }
  return readdirSync(dir, { recursive: true, encoding: "utf8" })
    .filter((file) => file.endsWith(".json"))
    .flatMap((file) => {
      const path = `${dir}/${file}`;
      const cut: unknown = JSON.parse(readFileSync(path, "utf8"));
      const facets = (cut as { facets?: unknown }).facets;
      if (!Array.isArray(facets) || !facets.every((facet) => typeof facet === "string")) {
        throw new Error(`Malformed cut file ${path}: expected a "facets" array of strings`);
      }
      return facets;
    });
}

function git(args: string[]): string {
  return execFileSync("git", args, { encoding: "utf8" }).trim();
}

/**
 * Whether the facet was ever named by the network's records: in the deployment record or a cut
 * file as they stand (uncommitted edits included), or in any version of them git holds on this
 * clone's refs. Git is the retained history the mutable records lack; a shallow clone has
 * truncated it and cannot answer. What the refs do not hold is invisible, hence the assumption
 * this check states with every FRESH verdict.
 */
function facetEverRecorded(network: string, records: DeployRecord[], facet: string): boolean {
  if (records.some((record) => record.name === facet) || facetsInCurrentCuts(network).includes(facet)) {
    return true;
  }
  if (git(["rev-parse", "--is-shallow-repository"]) !== "false") {
    throw new Error(
      "shallow clone: the records' history is truncated, so an absent facet cannot be proven never installed; " +
        "use a full clone"
    );
  }
  // every commit on any ref that added or removed an occurrence of the facet's name in the records;
  // --full-history keeps the merged commits that added and later removed it, which git's default
  // path simplification drops when the merge's tree matches its first parent
  const commits = git([
    "log",
    "--all",
    "--full-history",
    "--format=%H",
    `-S${facet}`,
    "--",
    deployRecordPath(network),
    cutsDir(network),
  ]);
  return commits.length > 0;
}

async function readAddress(
  web3: Web3,
  to: string,
  abi: typeof IMPLEMENTATION_ABI | typeof IMPLEMENTATION_FOR_TYPE_ABI,
  args: unknown[]
): Promise<string | typeof NOT_CUT> {
  const data = web3.eth.abi.encodeFunctionCall(abi, args);
  try {
    const result = await web3.eth.call({ to, data });
    return web3.eth.abi.decodeParameter("address", result) as string;
  } catch (error: unknown) {
    if (JSON.stringify(error ?? "").includes(FUNCTION_NOT_FOUND.slice(2))) {
      return NOT_CUT;
    }
    throw error;
  }
}

/**
 * The registration events the controller ever emitted for `signature`, or `undefined` when the
 * RPC refuses the full range (the public Flare RPCs cap a query at 30 blocks), i.e. no history.
 */
async function registrationHistory(web3: Web3, controller: string, signature: string): Promise<string[] | undefined> {
  const topic = web3.utils.keccak256(signature);
  try {
    const logs = await web3.eth.getPastLogs({ address: controller, fromBlock: 0, toBlock: "latest", topics: [topic] });
    return logs.map((log) => {
      if (typeof log === "string") {
        return log;
      }
      const indexed = log.topics?.[1];
      const registered =
        indexed === undefined ? "" : `type ${String(web3.eth.abi.decodeParameter("uint256", indexed))} `;
      return `${registered}at block ${String(log.blockNumber)}`;
    });
  } catch {
    return undefined;
  }
}

function report(lineage: string, verdict: Verdict, reason: string): Verdict {
  const label = { fresh: "FRESH", "not-fresh": "NOT FRESH", unproven: "NOT PROVEN" }[verdict];
  (verdict === "fresh" ? console.log : console.error)(`  ${lineage}: ${label} — ${reason}`);
  return verdict;
}

/** The facet is absent now and the RPC serves no history: the records' retained history decides. */
function absentFacetVerdict(network: string, records: DeployRecord[], lineage: string, facet: string): Verdict {
  if (facetEverRecorded(network, records, facet)) {
    return report(
      lineage,
      "unproven",
      `${facet} is not cut now but a record of ${network} (current, historical or example) names it, so it may ` +
        "have been installed and removed after proxies were created; an RPC serving the full event history would decide"
    );
  }
  return report(
    lineage,
    "fresh",
    `${facet} is not cut now and no record of ${network} names it, now or in the history git holds on this ` +
      "clone's refs - assuming every installation was committed under the canonical facet name before execution " +
      "and remains reachable from those refs; an RPC serving the full event history needs no such assumption"
  );
}

async function checkSubaccounts(
  web3: Web3,
  network: string,
  records: DeployRecord[],
  controller: string
): Promise<Verdict> {
  const registered: string[] = [];
  let cut = true;
  for (let type = 1; type <= PROBED_SUBACCOUNT_TYPES; type++) {
    const implementation = await readAddress(web3, controller, IMPLEMENTATION_FOR_TYPE_ABI, [type]);
    if (implementation === NOT_CUT) {
      cut = false;
      break;
    }
    if (implementation !== ZERO) {
      registered.push(`type ${type} -> ${implementation}`);
    }
  }
  if (registered.length > 0) {
    return report("subaccounts", "not-fresh", `${registered.join(", ")}; proxies may exist, the layout is binding`);
  }
  const history = await registrationHistory(web3, controller, "SubaccountImplementationSet(uint256,address)");
  if (history !== undefined) {
    return history.length === 0
      ? report(
          "subaccounts",
          "fresh",
          "no SubaccountImplementationSet event in the controller's history, so no proxy can exist"
        )
      : report(
          "subaccounts",
          "not-fresh",
          `registrations in the history: ${history.join(", ")}; the layout is binding`
        );
  }
  if (!cut) {
    return absentFacetVerdict(network, records, "subaccounts", "SubaccountsFacet");
  }
  return report(
    "subaccounts",
    "unproven",
    `SubaccountsFacet is cut and types 1..${PROBED_SUBACCOUNT_TYPES} are unregistered, but the type space is ` +
      "unbounded and this RPC serves no event history; use one that does (a private node)"
  );
}

async function checkPersonalAccounts(
  web3: Web3,
  network: string,
  records: DeployRecord[],
  controller: string
): Promise<Verdict> {
  const beacon = await readAddress(web3, controller, IMPLEMENTATION_ABI, []);
  if (beacon !== NOT_CUT) {
    return beacon === ZERO
      ? report(
          "personal-accounts",
          "fresh",
          "the beacon is unset and can never return to zero, so no Personal Account exists"
        )
      : report("personal-accounts", "not-fresh", `beacon -> ${beacon}; proxies may exist, the layout is binding`);
  }
  const history = await registrationHistory(web3, controller, "PersonalAccountImplementationSet(address)");
  if (history !== undefined) {
    return history.length === 0
      ? report("personal-accounts", "fresh", "no PersonalAccountImplementationSet event in the controller's history")
      : report(
          "personal-accounts",
          "not-fresh",
          `beacon set in the history: ${history.join(", ")}; the layout is binding`
        );
  }
  return absentFacetVerdict(network, records, "personal-accounts", "PersonalAccountsFacet");
}

async function main(): Promise<void> {
  const [network, requested = "all"] = process.argv.slice(2);
  if (!network) {
    throw new Error("Usage: pnpm check_lineage_fresh <network> [subaccounts|personal-accounts|all]");
  }
  if (!["subaccounts", "personal-accounts", "all"].includes(requested)) {
    throw new Error(`Unknown lineage "${requested}" (subaccounts | personal-accounts | all)`);
  }
  validateNetwork(network);

  const records = readDeployRecords(network);
  const controller = findController(records, network);
  const web3 = new Web3(resolveRpcUrl(network));
  await assertRpcChain(web3, network);
  const code = await web3.eth.getCode(controller);
  if (code === "0x") {
    throw new Error(`${network}: the recorded controller ${controller} has no code; the record and the chain disagree`);
  }
  console.log(`${network}: controller ${controller}`);

  const verdicts: Verdict[] = [];
  if (requested === "subaccounts" || requested === "all") {
    verdicts.push(await checkSubaccounts(web3, network, records, controller));
  }
  if (requested === "personal-accounts" || requested === "all") {
    verdicts.push(await checkPersonalAccounts(web3, network, records, controller));
  }

  const failed = verdicts.filter((verdict) => verdict !== "fresh").length;
  if (failed > 0) {
    console.error(
      `\n${failed} lineage(s) are not proven fresh on ${network}: an implementation with a re-laid layout ` +
        "must not be deployed or registered there"
    );
    process.exit(1);
  }
  console.log(`\nevery checked lineage is fresh on ${network}`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
