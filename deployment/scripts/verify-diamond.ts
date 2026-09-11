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
//     The diamond exposes exactly the intended surface: every facet the deployment record lists
//     (or, under deleteAllOldMethods, exactly the cut file's), each with its artifact's selectors
//     (less the cut file's deleteSelectorSigs, which must also have no dispatch entry left), no
//     stale or orphan selector, the four ERC-165 flags true, the owner as expected, the artifact's
//     code behind every facet.
//
// Every read is made at one block, resolved once from VERIFY_BLOCK_TAG (default `latest`; set
// `finalized` for reorg-proof reads), so the checks describe a single state. The checks themselves
// live in deployment/utils/diamond-verifier.ts behind two reader interfaces, which is where the
// regression tests drive them with a fake chain; this file wires web3 and the filesystem to them.
import { execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import Web3 from "web3";
import { isFunctionFragment, loadAbi, toSelector } from "../utils/prep-cut";
import { artifactPathFor, buildRepoFacetSourceSet, loadCreationCode, loadDeployedCode } from "../utils/facet-code";
import { loadPinnedEthereumAddresses } from "../utils/pinned-constants";
import { assertRpcChain, fetchLoupeFacets, loadCutConfig, loadDeployedContracts } from "../utils/diamond-inspect";
import { isLoanChainNetwork, resolveRpcUrl, validateNetwork } from "../utils/networks";
import { allPassed, formatChecks } from "../utils/diamond-verify";
import { type ChainReader, type RepoReader, verifyDiamond } from "../utils/diamond-verifier";

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
  if (!options.noBuild) {
    execSync("forge build", { stdio: "inherit" });
  }

  const record = loadDeployedContracts(options.network);
  const cut = options.cutFileName ? loadCutConfig(options.network, options.cutFileName) : undefined;
  const pins = isLoanChainNetwork(options.network) ? loadPinnedEthereumAddresses() : undefined;
  const web3 = new Web3(resolveRpcUrl(options.network));
  await assertRpcChain(web3, options.network);
  // one block for every read: `latest` and `finalized` move between calls, and a verdict must
  // describe a single state
  const requestedBlock = process.env.VERIFY_BLOCK_TAG ?? "latest";
  const block = Number((await web3.eth.getBlock(requestedBlock)).number);

  const result = await verifyDiamond({
    network: options.network,
    preCut: options.preCut,
    record,
    ...(cut ? { cut } : {}),
    ...(pins ? { pins } : {}),
    ...expectOwnerInput(options, pins?.initialOwner),
    repo: fsRepoReader(),
    chain: web3ChainReader(web3, block),
  });

  console.log(`Diamond verification for ${options.network} (${options.preCut ? "pre-cut" : "post-cut"})`);
  console.log(`Diamond: ${result.diamond}`);
  console.log(`Block: ${block} (${requestedBlock})`);
  if (cut) console.log(`Cut file: deployment/cuts/${options.network}/${options.cutFileName}`);
  for (const note of result.notes) console.log(note);
  console.log("");
  console.log(formatChecks(result.checks));
  if (!allPassed(result.checks)) {
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

/**
 * The owner to expect: the explicit option, else what the stage says it should be.
 *
 * On a loan chain that depends on where in the runbook the run sits. `--pre-cut` is the bootstrap's
 * own diamond, which the pinned initial owner still holds; every later run is after the transfer
 * (RUNBOOK.md B3 hands it over before the cut), so the chain config's governance is the expectation
 * and the pin would report a mismatch on every one of them. Elsewhere - and on a loan chain whose
 * config names no governance yet - the order is unchanged.
 *
 * A zero governance is no expectation at all: the deploy script transfers ownership only to a
 * non-zero one, so zero means the deployer kept it and there is nothing to compare against.
 */
function expectOwnerInput(options: Options, pinnedOwner: string | undefined): { expectOwner?: string } {
  // the explicit flag needs nothing else, and the pre-cut pin needs no config: neither should be
  // stopped by a chain config it would not have read
  if (options.expectOwner) return { expectOwner: options.expectOwner };
  const configured = () => chainConfigGovernance(options.network);
  const expected = options.preCut ? (pinnedOwner ?? configured()) : (configured() ?? pinnedOwner);
  return expected ? { expectOwner: expected } : {};
}

/**
 * The chain config's governance, or undefined where there is nothing to expect: no config, no key,
 * or the zero address, which the deploy script reads as "the deployer keeps it". Anything else that
 * is not an address is a malformed config and stops the run - an empty string is not "no
 * expectation", it is a typo that would otherwise disable the owner check without a word.
 */
function chainConfigGovernance(network: string): string | undefined {
  const path = `deployment/chain-config/${network}.json`;
  if (!existsSync(path)) return undefined;
  const config = JSON.parse(readFileSync(path, "utf8")) as { governance?: unknown };
  if (config.governance === undefined) return undefined;
  if (typeof config.governance !== "string" || !Web3.utils.isAddress(config.governance)) {
    throw new Error(`${path}: "governance" must be an address, got ${JSON.stringify(config.governance)}`);
  }
  return config.governance.toLowerCase() === ZERO_ADDRESS ? undefined : config.governance;
}

function fsRepoReader(): RepoReader {
  const sources = buildRepoFacetSourceSet();
  return {
    abiSelectors: (contractName) =>
      loadAbi(contractName)
        .filter(isFunctionFragment)
        .map((fragment) => toSelector(fragment).toLowerCase()),
    hasArtifact: (contractName) => existsSync(artifactPathFor(contractName)),
    hasSource: (facetName) => sources.has(facetName),
    deployedCode: loadDeployedCode,
    creationCode: loadCreationCode,
  };
}

function web3ChainReader(web3: Web3, block: number): ChainReader {
  return {
    code: (address) => web3.eth.getCode(address, block),
    storage: async (address, slot) => String(await web3.eth.getStorageAt(address, slot, block)),
    loupeFacets: (diamond) => fetchLoupeFacets(web3, diamond, block),
    owner: async (diamond) => {
      const data = web3.eth.abi.encodeFunctionSignature("owner()");
      const encoded = await web3.eth.call({ to: diamond, data }, block);
      return String(web3.eth.abi.decodeParameter("address", encoded)).toLowerCase();
    },
    supportsInterface: async (diamond, id) => {
      const data = web3.eth.abi.encodeFunctionCall(
        { type: "function", name: "supportsInterface", inputs: [{ type: "bytes4", name: "interfaceId" }] },
        [id]
      );
      const encoded = await web3.eth.call({ to: diamond, data }, block);
      return Boolean(web3.eth.abi.decodeParameter("bool", encoded));
    },
  };
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : error);
  process.exit(1);
});
