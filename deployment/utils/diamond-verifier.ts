// The diamond verifier's core: given the deployment record, an optional cut file, the pins and
// the expected owner, plus two readers - one for the chain, one for the repository's artifacts
// and sources - it produces the check list verify-diamond.ts prints. Both readers are interfaces
// so the same code runs against a fake chain in the regression tests (forged loupe answers,
// wrong runtimes, both deletion modes) and against web3 and the filesystem in the CLI; the
// checks and their wiring into the verdict are what the tests pin.
import Web3 from "web3";
import { type CutConfig, type DeployedContract, type LoupeFacet, findDiamondAddress } from "./diamond-inspect";
import { type ExpectedFacet, type Check, INVALID_INTERFACE_ID, VERIFIER_CALLS } from "./diamond-verify";
import {
  addressInWord,
  buildExpectedLayout,
  check,
  checkEq,
  diffLayout,
  dispatchSlot,
  interfaceId,
  layoutChecks,
} from "./diamond-verify";
import { ZERO_CODE, compareFacet, hexToBytes } from "./facet-code";
import type { PinnedEthereumAddresses } from "./pinned-constants";
import { toSelector } from "./prep-cut";

/** Reads of one chain state, every one at the block the reader was built for. */
export interface ChainReader {
  /** Runtime code at `address`, `0x` when there is none. */
  code(address: string): Promise<string>;
  /** The 32-byte word at `slot` of `address`. */
  storage(address: string, slot: string): Promise<string>;
  /** The diamond's `facets()` answer. */
  loupeFacets(diamond: string): Promise<LoupeFacet[]>;
  /** The diamond's `owner()` answer. */
  owner(diamond: string): Promise<string>;
  /** The diamond's `supportsInterface(id)` answer. */
  supportsInterface(diamond: string, id: string): Promise<boolean>;
}

/** The repository's view of a contract: its artifact and its source. */
export interface RepoReader {
  /** The artifact's function selectors, lower-case. */
  abiSelectors(contractName: string): string[];
  hasArtifact(contractName: string): boolean;
  /** Whether a facet's source file still exists under `contracts/`. */
  hasSource(facetName: string): boolean;
  deployedCode(contractName: string): Buffer;
  creationCode(contractName: string): Buffer;
}

export interface VerificationInputs {
  network: string;
  /** Verify the bootstrapped diamond is pristine: base facets only, no flag set. */
  preCut: boolean;
  record: DeployedContract[];
  cut?: CutConfig;
  /** The Ethereum pins; present on the `ethereum` network only. */
  pins?: PinnedEthereumAddresses;
  /** The owner to expect: an explicit one, else the pins' initial owner, else governance. */
  expectOwner?: string;
  repo: RepoReader;
  chain: ChainReader;
}

export interface VerificationResult {
  diamond: string;
  checks: Check[];
  /** Observations that are not checks (an owner with nothing to compare against). */
  notes: string[];
}

export const BASE_FACETS = ["DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet"] as const;
export const FLAG_INTERFACES = ["IERC165", "IDiamondCut", "IDiamondLoupe", "IERC173"] as const;
export const DIAMOND_CONTRACT = "MasterAccountController";
export const PROXY_CONTRACT = "PersonalAccountProxy";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

/** Runs every check; throws on inputs that make verification meaningless rather than failing a check. */
export async function verifyDiamond(inputs: VerificationInputs): Promise<VerificationResult> {
  const { record, cut, pins, repo, chain } = inputs;
  if (inputs.preCut && cut) {
    throw new Error("--pre-cut takes no cut file: the expected surface is the base facets alone");
  }
  const recordFacets = record.filter((entry) => entry.name.endsWith("Facet"));
  const recordByName = new Map(recordFacets.map((entry) => [entry.name, entry]));
  for (const name of BASE_FACETS) {
    if (!recordByName.has(name)) {
      throw new Error(`${name} is missing from deployment/deploys/${inputs.network}.json`);
    }
  }
  // the target is the record's one controller; a cut file aiming elsewhere must fail, not verify
  // another deployment successfully
  const diamond = findDiamondAddress(record);
  if (cut && cut.diamond.toLowerCase() !== diamond.toLowerCase()) {
    throw new Error(
      `the cut file targets ${cut.diamond} but deployment/deploys/${inputs.network}.json records the controller at ${diamond}`
    );
  }
  const cutFacetNames = cut?.facets ?? [];
  for (const name of cutFacetNames) {
    if (!recordByName.has(name)) {
      throw new Error(`${name} is in the cut file but not in deployment/deploys/${inputs.network}.json`);
    }
  }

  const checks: Check[] = [];
  const notes: string[] = [];

  // 1. the pins, on Ethereum: the record and the chain must both agree with the historical pins
  if (pins) {
    checks.push(checkEq("pins: the diamond is the pinned controller", pins.controllerAddress, diamond));
    checks.push(
      checkEq(
        "pins: the controller's on-chain code hashes to the pin",
        pins.controllerRuntimeCodeHash,
        await codeHash(chain, diamond)
      )
    );
    for (const [name, pin] of pins.baseFacets) {
      const recorded = recordByName.get(name);
      checks.push(
        checkEq(`pins: ${name} recorded at the pinned address`, pin.address, recorded?.address ?? "<missing>")
      );
      checks.push(
        checkEq(
          `pins: ${name} on-chain code hashes to the pin`,
          pin.runtimeCodeHash,
          await codeHash(chain, pin.address)
        )
      );
    }
  }

  // 2. the dispatcher's table, read from the diamond's storage: every call the verifier makes
  // through the diamond must be routed to the verified base facet, or the loupe's answers and
  // the owner below would be whatever the facet that actually answers chose to say - the
  // diamond's code (pinned, or compared with the artifact) is what reads this table, so it
  // authenticates the responders where the responders cannot authenticate themselves
  for (const call of VERIFIER_CALLS) {
    const served = addressInWord(await chain.storage(diamond, dispatchSlot(call.selector)));
    checks.push(
      checkEq(
        `dispatch: ${call.signature} is served by ${call.facet} (storage)`,
        recordEntry(recordByName, call.facet).address,
        served
      )
    );
  }

  // 3. the expected surface: the base facets alone before the cut; after it every recorded
  // facet, or - with deleteAllOldMethods - exactly the cut file's facets, since that cut removes
  // every other live selector
  if (cut?.deleteAllOldMethods) {
    const keepsBase = BASE_FACETS.every((name) => cutFacetNames.includes(name));
    checks.push(
      check(
        "cut: deleteAllOldMethods keeps the base facets",
        keepsBase,
        "the three base facets listed",
        keepsBase ? "listed" : "a base facet is missing - the cut would remove the diamond's own surface"
      )
    );
  }
  const expectedNames = inputs.preCut
    ? [...BASE_FACETS]
    : cut?.deleteAllOldMethods
      ? cutFacetNames
      : recordFacets.map((entry) => entry.name);
  const expectedFacets: ExpectedFacet[] = expectedNames.map((name) => {
    const entry = recordEntry(recordByName, name);
    return { name: entry.name, address: entry.address, selectors: repo.abiSelectors(entry.name) };
  });
  // the executor ignores deleteSelectorSigs under deleteAllOldMethods (the listed facets' full
  // selector sets survive, everything else goes), so the expectation mirrors that precedence
  const deleteSelectors = cut?.deleteAllOldMethods
    ? []
    : (cut?.deleteSelectorSigs ?? []).map((entry) => toSelector(entry).toLowerCase());
  const layout = buildExpectedLayout(expectedFacets, deleteSelectors);
  checks.push(...layoutChecks(diffLayout(layout, await chain.loupeFacets(diamond))));
  // an explicitly deleted selector must have no dispatch entry at all: the loupe enumerates the
  // selectors array, and a leftover mapping entry would still be callable without appearing there
  const leftovers: string[] = [];
  for (const selector of deleteSelectors) {
    const served = addressInWord(await chain.storage(diamond, dispatchSlot(selector)));
    if (served !== ZERO_ADDRESS) {
      leftovers.push(`${selector} at ${served}`);
    }
  }
  checks.push(
    check(
      "dispatch: deleted selectors have no dispatch entry",
      leftovers.length === 0,
      "none",
      leftovers.join(", ") || "none"
    )
  );

  // 4. the code behind every expected facet is the artifact's (modulo its own metadata trailer; an
  // embedded proxy creation code with different metadata is a change), from a source that still
  // exists; the pinned base facets on Ethereum were hashed against their pins above, and the
  // diamond itself is compared with the controller artifact where no pin covers it
  const proxyCreationCode = repo.creationCode(PROXY_CONTRACT);
  for (const facet of expectedFacets) {
    if (pins?.baseFacets.has(facet.name)) {
      continue;
    }
    const hasSource = repo.hasSource(facet.name);
    checks.push(
      check(
        `source: ${facet.name} still exists in contracts/`,
        hasSource,
        "present",
        hasSource ? "present" : "removed from source"
      )
    );
    checks.push(await codeCheck(chain, repo, facet.name, facet.address, proxyCreationCode));
  }
  if (!pins) {
    checks.push(await codeCheck(chain, repo, DIAMOND_CONTRACT, diamond, proxyCreationCode));
  }

  // 5. ownership: the pinned initial owner on Ethereum; elsewhere the network's own chain
  // config's governance, which the deploy script transfers ownership to only when it is set
  // (the owner() responder was authenticated above)
  const owner = await chain.owner(diamond);
  if (inputs.expectOwner) {
    checks.push(checkEq("owner", inputs.expectOwner, owner));
  } else {
    notes.push(`owner: ${owner} (no expectation available - pass --expect-owner to check it)`);
  }

  // 6. the ERC-165 flags: none before the init has run, all four after it; 0xffffffff never
  const expectFlags = !inputs.preCut;
  for (const name of FLAG_INTERFACES) {
    const id = interfaceId(repo.abiSelectors(name));
    const supported = await chain.supportsInterface(diamond, id);
    checks.push(
      check(
        `erc165: ${name} (${id}) ${expectFlags ? "supported" : "not yet supported"}`,
        supported === expectFlags,
        String(expectFlags),
        String(supported)
      )
    );
  }
  const invalid = await chain.supportsInterface(diamond, INVALID_INTERFACE_ID);
  checks.push(check("erc165: 0xffffffff is not supported", invalid === false, "false", String(invalid)));

  return { diamond, checks, notes };
}

function recordEntry(recordByName: Map<string, DeployedContract>, name: string): DeployedContract {
  const entry = recordByName.get(name);
  if (!entry) {
    throw new Error(`${name} is not in the deployment record`);
  }
  return entry;
}

/** The planner's REUSE verdict as a check: the on-chain code is the artifact's functional code. */
async function codeCheck(
  chain: ChainReader,
  repo: RepoReader,
  name: string,
  address: string,
  proxyCreationCode: Buffer
): Promise<Check> {
  const title = `code: ${name} at ${address} matches the artifact`;
  if (!repo.hasArtifact(name)) {
    return check(title, false, "artifact present", `missing artifact for ${name} - run forge build`);
  }
  const deployedCodeHex = await chain.code(address);
  if (deployedCodeHex === ZERO_CODE) {
    return check(title, false, "code present", "no code");
  }
  const plan = compareFacet(name, address, hexToBytes(deployedCodeHex), repo.deployedCode(name), proxyCreationCode);
  return check(title, plan.action === "REUSE", "REUSE", `${plan.action}: ${plan.reason}`);
}

async function codeHash(chain: ChainReader, address: string): Promise<string> {
  const code = await chain.code(address);
  return code === ZERO_CODE ? "<no code>" : Web3.utils.keccak256(code).toLowerCase();
}
