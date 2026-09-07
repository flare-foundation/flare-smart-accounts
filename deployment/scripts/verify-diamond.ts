#!/usr/bin/env node
// Reads a deployed diamond back and compares it with what the repository says it should be, the
// way dvn's verify-deployment.ts gates its records: a named check list, expected against actual,
// non-zero exit on any mismatch. Two moments matter for the loan-chain cut and both are covered:
//
//   pnpm verify_diamond ethereum --pre-cut
//     The bootstrapped diamond is pristine: owner still the pinned initial owner, exactly the
//     three pinned base facets with exactly their canonical selectors, no ERC-165 flag set yet,
//     on-chain code hashing to the pins.
//   pnpm verify_diamond <network> [cut-file]
//     The diamond exposes exactly the intended surface: every facet the deployment record lists,
//     each with its artifact's selectors (less the cut file's deleteSelectorSigs), no stale or
//     orphan selector, the four ERC-165 flags true, the owner as expected, code present behind
//     every facet.
//
// Every read is made at one block, resolved once from VERIFY_BLOCK_TAG (default `latest`; set
// `finalized` for reorg-proof reads), so the checks describe a single state. Facet code is
// compared with the artifacts the way the planner compares it - identical modulo the facet's own
// metadata trailer; a change in the embedded proxy creation code's metadata counts as a change -
// and against the pinned hashes on Ethereum.
import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import Web3 from "web3";
import { isFunctionFragment, loadAbi, toSelector } from "../utils/prep-cut";
import {
  ZERO_CODE,
  artifactPathFor,
  buildRepoFacetSourceSet,
  compareFacet,
  hexToBytes,
  loadCreationCode,
  loadDeployedCode,
} from "../utils/facet-code";
import { loadPinnedEthereumAddresses } from "../utils/pinned-constants";
import {
  type DeployedContract,
  assertRpcChain,
  fetchLoupeFacets,
  findDiamondAddress,
  loadCutConfig,
  loadDeployedContracts,
  resolveRpcUrl,
  validateNetwork,
} from "../utils/diamond-inspect";
import {
  type Check,
  type ExpectedFacet,
  INVALID_INTERFACE_ID,
  VERIFIER_CALLS,
  addressInWord,
  allPassed,
  buildExpectedLayout,
  check,
  checkEq,
  diffLayout,
  dispatchSlot,
  formatChecks,
  interfaceId,
  layoutChecks,
} from "../utils/diamond-verify";

const BASE_FACETS = ["DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet"] as const;
const FLAG_INTERFACES = ["IERC165", "IDiamondCut", "IDiamondLoupe", "IERC173"] as const;
const DIAMOND_CONTRACT = "MasterAccountController";
const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

interface Options {
  network: string;
  cutFileName?: string;
  preCut: boolean;
  expectOwner?: string;
  noBuild: boolean;
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  validateNetwork(options.network);
  if (options.preCut && options.cutFileName) {
    throw new Error("--pre-cut takes no cut file: the expected surface is the base facets alone");
  }
  if (!options.noBuild) {
    execSync("forge build", { stdio: "inherit" });
  }

  const record = loadDeployedContracts(options.network);
  const cut = options.cutFileName ? loadCutConfig(options.network, options.cutFileName) : undefined;
  // the target is the record's one controller; a cut file aiming elsewhere must fail, not verify
  // another deployment successfully
  const diamond = findDiamondAddress(record);
  if (cut && cut.diamond.toLowerCase() !== diamond.toLowerCase()) {
    throw new Error(
      `the cut file targets ${cut.diamond} but deployment/deploys/${options.network}.json records the controller at ${diamond}`
    );
  }
  const web3 = new Web3(resolveRpcUrl(options.network));
  await assertRpcChain(web3, options.network);
  // one block for every read: `latest` and `finalized` move between calls, and a verdict must
  // describe a single state
  const requestedBlock = process.env.VERIFY_BLOCK_TAG ?? "latest";
  const blockTag = Number((await web3.eth.getBlock(requestedBlock)).number);

  console.log(`Diamond verification for ${options.network} (${options.preCut ? "pre-cut" : "post-cut"})`);
  console.log(`Diamond: ${diamond}`);
  console.log(`Block: ${blockTag} (${requestedBlock})`);
  if (cut) console.log(`Cut file: deployment/cuts/${options.network}/${options.cutFileName}`);
  console.log("");

  const checks: Check[] = [];
  const recordFacets = record.filter((entry) => entry.name.endsWith("Facet"));
  const recordByName = new Map(recordFacets.map((entry) => [entry.name, entry]));

  // 1. the pins, on Ethereum: the record and the chain must both agree with the historical pins
  const isEthereum = options.network === "ethereum";
  const pins = isEthereum ? loadPinnedEthereumAddresses() : undefined;
  if (pins) {
    checks.push(checkEq("pins: the diamond is the pinned controller", pins.controllerAddress, diamond));
    checks.push(
      checkEq(
        "pins: the controller's on-chain code hashes to the pin",
        pins.controllerRuntimeCodeHash,
        await codeHash(web3, diamond, blockTag)
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
          await codeHash(web3, pin.address, blockTag)
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
    const served = addressInWord(await web3.eth.getStorageAt(diamond, dispatchSlot(call.selector), blockTag));
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
  for (const name of BASE_FACETS) {
    if (!recordByName.has(name)) {
      throw new Error(`${name} is missing from deployment/deploys/${options.network}.json`);
    }
  }
  const cutFacetNames = cut?.facets ?? [];
  for (const name of cutFacetNames) {
    if (!recordByName.has(name)) {
      throw new Error(`${name} is in the cut file but not in deployment/deploys/${options.network}.json`);
    }
  }
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
  const expectedNames = options.preCut
    ? [...BASE_FACETS]
    : cut?.deleteAllOldMethods
      ? cutFacetNames
      : recordFacets.map((entry) => entry.name);
  const expectedFacets: ExpectedFacet[] = expectedNames.map((name) => expectedFacet(recordEntry(recordByName, name)));
  // the executor ignores deleteSelectorSigs under deleteAllOldMethods (the listed facets' full
  // selector sets survive, everything else goes), so the expectation mirrors that precedence
  const deleteSelectors = cut?.deleteAllOldMethods
    ? []
    : (cut?.deleteSelectorSigs ?? []).map((entry) => toSelector(entry).toLowerCase());
  const layout = buildExpectedLayout(expectedFacets, deleteSelectors);
  const loupe = await fetchLoupeFacets(web3, diamond, blockTag);
  checks.push(...layoutChecks(diffLayout(layout, loupe)));
  // an explicitly deleted selector must have no dispatch entry at all: the loupe enumerates the
  // selectors array, and a leftover mapping entry would still be callable without appearing there
  const leftovers: string[] = [];
  for (const selector of deleteSelectors) {
    const served = addressInWord(await web3.eth.getStorageAt(diamond, dispatchSlot(selector), blockTag));
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

  // 4. the code behind every expected facet is the artifact's (modulo its own metadata trailer;
  // an embedded proxy creation code with different metadata is a change), from a source that
  // still exists; the pinned base
  // facets on Ethereum were hashed against their pins above, and the diamond itself is compared
  // with the controller artifact where no pin covers it
  const proxyCreationCode = loadCreationCode("PersonalAccountProxy");
  const sources = buildRepoFacetSourceSet();
  for (const facet of expectedFacets) {
    if (pins?.baseFacets.has(facet.name)) {
      continue;
    }
    checks.push(
      check(
        `source: ${facet.name} still exists in contracts/`,
        sources.has(facet.name),
        "present",
        sources.has(facet.name) ? "present" : "removed from source"
      )
    );
    checks.push(await codeCheck(web3, facet.name, facet.address, blockTag, proxyCreationCode));
  }
  if (!pins) {
    checks.push(await codeCheck(web3, DIAMOND_CONTRACT, diamond, blockTag, proxyCreationCode));
  }

  // 5. ownership: the pinned initial owner on Ethereum; elsewhere the network's own chain
  // config's governance, which the deploy script transfers ownership to only when it is set
  // (the owner() responder was authenticated above)
  const owner = await readAddress(web3, diamond, "owner()", blockTag);
  const expectedOwner = options.expectOwner ?? pins?.initialOwner ?? chainConfigGovernance(options.network);
  if (expectedOwner) {
    checks.push(checkEq("owner", expectedOwner, owner));
  } else {
    console.log(`owner: ${owner} (no expectation available - pass --expect-owner to check it)\n`);
  }

  // 6. the ERC-165 flags: none before the init has run, all four after it; 0xffffffff never
  const expectFlags = !options.preCut;
  for (const name of FLAG_INTERFACES) {
    const id = interfaceId(abiSelectors(name));
    const supported = await supportsInterface(web3, diamond, id, blockTag);
    checks.push(
      check(
        `erc165: ${name} (${id}) ${expectFlags ? "supported" : "not yet supported"}`,
        supported === expectFlags,
        String(expectFlags),
        String(supported)
      )
    );
  }
  const invalid = await supportsInterface(web3, diamond, INVALID_INTERFACE_ID, blockTag);
  checks.push(check("erc165: 0xffffffff is not supported", invalid === false, "false", String(invalid)));

  console.log(formatChecks(checks));
  if (!allPassed(checks)) {
    process.exitCode = 1;
  }
}

function parseOptions(args: string[]): Options {
  const options: Options = { network: "", preCut: false, noBuild: false };
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--pre-cut") {
      options.preCut = true;
    } else if (arg === "--no-build") {
      options.noBuild = true;
    } else if (arg === "--expect-owner") {
      const value = args[++i];
      if (!value || !/^0x[0-9a-fA-F]{40}$/.test(value)) {
        throw new Error("--expect-owner needs an address");
      }
      options.expectOwner = value;
    } else if (arg.startsWith("--")) {
      throw new Error(`Unknown option ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  const [network, cutFileName] = positional;
  if (!network || positional.length > 2) {
    console.error(
      "Usage: pnpm verify_diamond <network> [cut-file] [--pre-cut] [--expect-owner <address>] [--no-build]"
    );
    process.exit(2);
  }
  options.network = network;
  if (cutFileName) options.cutFileName = cutFileName;
  return options;
}

function expectedFacet(entry: DeployedContract): ExpectedFacet {
  return { name: entry.name, address: entry.address, selectors: abiSelectors(entry.name) };
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
  web3: Web3,
  name: string,
  address: string,
  blockTag: number,
  proxyCreationCode: Buffer
): Promise<Check> {
  const title = `code: ${name} at ${address} matches the artifact`;
  if (!existsSync(artifactPathFor(name))) {
    return check(title, false, "artifact present", `missing ${artifactPathFor(name)} - run forge build`);
  }
  const deployedCodeHex = await web3.eth.getCode(address, blockTag);
  if (deployedCodeHex === ZERO_CODE) {
    return check(title, false, "code present", "no code");
  }
  const plan = compareFacet(name, address, hexToBytes(deployedCodeHex), loadDeployedCode(name), proxyCreationCode);
  return check(title, plan.action === "REUSE", "REUSE", `${plan.action}: ${plan.reason}`);
}

function abiSelectors(contractName: string): string[] {
  return loadAbi(contractName)
    .filter(isFunctionFragment)
    .map((fragment) => toSelector(fragment).toLowerCase());
}

async function codeHash(web3: Web3, address: string, blockTag: number): Promise<string> {
  const code = await web3.eth.getCode(address, blockTag);
  return code === ZERO_CODE ? "<no code>" : Web3.utils.keccak256(code).toLowerCase();
}

async function readAddress(web3: Web3, diamond: string, signature: string, blockTag: number): Promise<string> {
  const data = web3.eth.abi.encodeFunctionSignature(signature);
  const encoded = await web3.eth.call({ to: diamond, data }, blockTag);
  return String(web3.eth.abi.decodeParameter("address", encoded)).toLowerCase();
}

async function supportsInterface(web3: Web3, diamond: string, id: string, blockTag: number): Promise<boolean> {
  const data = web3.eth.abi.encodeFunctionCall(
    { type: "function", name: "supportsInterface", inputs: [{ type: "bytes4", name: "interfaceId" }] },
    [id]
  );
  const encoded = await web3.eth.call({ to: diamond, data }, blockTag);
  return Boolean(web3.eth.abi.decodeParameter("bool", encoded));
}

/**
 * The governance address of this exact network's chain config (staging has its own file), the
 * diamond's owner once the deploy script transferred it - which it does only for a non-zero
 * governance; zero means the deployer kept ownership, so there is no expectation to check.
 */
function chainConfigGovernance(network: string): string | undefined {
  const path = `deployment/chain-config/${network}.json`;
  if (!existsSync(path)) return undefined;
  const config = JSON.parse(readFileSync(path, "utf8")) as { governance?: unknown };
  if (typeof config.governance !== "string" || config.governance.toLowerCase() === ZERO_ADDRESS) return undefined;
  return config.governance;
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
