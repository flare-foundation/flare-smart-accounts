#!/usr/bin/env node
import { execFileSync, execSync } from "node:child_process";
import { existsSync } from "node:fs";
import { basename } from "node:path";
import Web3, { type AbiFunctionFragment } from "web3";
import { isFunctionFragment, loadAbi, toSelector } from "../utils/prep-cut";
import { loadPinnedEthereumAddresses, validateContractName } from "../utils/pinned-constants";
import {
  type DeployedContract,
  type LoupeFacet,
  assertRpcChain,
  fetchLoupeFacets,
  findDiamondAddress,
  isDeployedContract,
  loadCutConfig,
  loadDeployedContracts,
  normalizeCutFileName,
} from "../utils/diamond-inspect";
import { resolveRpcUrl, validateNetwork } from "../utils/networks";
import {
  type FacetAction,
  type FacetPlan,
  ZERO_CODE,
  artifactPathFor,
  buildRepoFacetSourceSet,
  compareFacet,
  hexToBytes,
  loadCreationCode,
  loadDeployedCode,
} from "../utils/facet-code";

interface RepoSelectorInfo {
  contractName: string;
  signature: string;
}

interface StaleSelector {
  selector: string;
  facetAddress: string;
  facetName?: string;
  deployedFacetAddress?: string;
  signature?: string;
  // Set when the selector still exists on another facet in the repo (moved, not removed).
  movedTo?: string;
}

async function main() {
  const args = process.argv.slice(2);
  const noBuild = args.includes("--no-build");
  const positional = args.filter((arg) => !arg.startsWith("--"));
  const network = positional[0];
  const cutFileName = positional[1];

  if (!network) {
    printUsageAndExit();
  }
  validateNetwork(network);

  if (!noBuild) {
    execSync("forge build", { stdio: "inherit" });
  }

  const deployedContracts = loadDeployedContracts(network);
  const cutConfig = cutFileName ? loadCutConfig(network, cutFileName) : undefined;
  const diamond = cutConfig?.diamond ?? findDiamondAddress(deployedContracts);
  const rpcUrl = resolveRpcUrl(network);
  const web3 = new Web3(rpcUrl);
  await assertRpcChain(web3, network);

  const deployedFacets = deployedContracts.filter((contract) => contract.name.endsWith("Facet"));
  const deployedByName = new Map(deployedFacets.map((contract) => [contract.name, contract]));
  if (network === "ethereum") {
    // the complete pin set (controller + three base facets) must be present and correctly
    // recorded before any planning: an omitted or renamed record would otherwise dodge the
    // pinned branch and let a same-named cut entry through the generic ADD path
    const pins = loadPinnedEthereumAddresses();
    for (const [pinnedName, pin] of pins.baseFacets) {
      const record = deployedByName.get(pinnedName);
      if (!record) {
        throw new Error(
          `${pinnedName}: pinned base facet missing from deployment/deploys/ethereum.json — ` +
            `run the pinned bootstrap (DeployEthereumController) before planning a cut`
        );
      }
      if (record.address.toLowerCase() !== pin.address) {
        throw new Error(
          `${pinnedName}: recorded address ${record.address} does not match the pinned ` +
            `historical address ${pin.address} — investigate before cutting`
        );
      }
    }
    const controller = deployedContracts.find((c) => c.name === "MasterAccountController");
    if (!controller || controller.address.toLowerCase() !== pins.controllerAddress) {
      throw new Error(
        `MasterAccountController: the deployment record is missing or does not match the ` +
          `pinned historical address ${pins.controllerAddress} — investigate before cutting`
      );
    }
    // the cut target is the pinned controller, nothing else: with all four record checks
    // passing, a cut file could otherwise aim the cut at another diamond
    if (diamond.toLowerCase() !== pins.controllerAddress) {
      throw new Error(
        `the Ethereum cut target ${diamond} must be the pinned MasterAccountController ` + `${pins.controllerAddress}`
      );
    }
  }
  const cutFacetNames = cutConfig?.facets ?? [];
  for (const name of cutFacetNames) {
    // path aliases and non-canonical casings of protected names must never reach planning
    if (validateContractName(name) === "MasterAccountController") {
      throw new Error("MasterAccountController is not a facet");
    }
  }

  console.log(`Diamond cut plan for ${network}`);
  console.log(
    cutFileName
      ? `Cut file: deployment/cuts/${network}/${normalizeCutFileName(cutFileName)}`
      : "Cut file: none (scope: all deployed facets; ADD detection needs a cut file)"
  );
  console.log(`Diamond: ${diamond}`);
  console.log(noBuild ? "Build: skipped (--no-build)" : "Build: forge build");
  console.log("");

  const facetPlans = await buildFacetPlans(web3, network, deployedFacets, deployedByName, cutFacetNames);
  printFacetPlan(facetPlans);

  const staleSelectors = await buildStaleSelectors(
    web3,
    network,
    deployedContracts,
    deployedFacets,
    cutFacetNames,
    diamond
  );
  const deleteSelectors = new Set(
    (cutConfig?.deleteSelectorSigs ?? []).map((selectorOrSignature) => toSelector(selectorOrSignature).toLowerCase())
  );
  printSelectorPlan(staleSelectors, deleteSelectors);

  printSummary(facetPlans, staleSelectors, deleteSelectors);
}

// --- Section 1: which facet contracts need (re)deploying ---

// The Ethereum bootstrap reproduces the diamond's base facets from pinned historical init
// code, not from current-source artifacts (see deployment/scripts/PinnedControllerInitCode.sol
// and deployment/pinned-init-code/). Comparing them against today's build would wrongly
// propose replacing them; instead they are verified against the pinned Flare runtime-code
// hashes (keccak256 of the deployed code) and reported as intentional reuse. Applies only on
// the "ethereum" network. The pinned values are parsed lazily from PinnedControllerInitCode.sol
// via deployment/utils/pinned-constants.ts, shared with the recorder.

async function buildFacetPlans(
  web3: Web3,
  network: string,
  deployedFacets: DeployedContract[],
  deployedByName: Map<string, DeployedContract>,
  cutFacetNames: string[]
): Promise<FacetPlan[]> {
  const proxyCreationCode = loadCreationCode("PersonalAccountProxy");
  const repoFacetSources = buildRepoFacetSourceSet();
  const plans: FacetPlan[] = [];

  for (const facet of deployedFacets) {
    // the pinned branch runs before all generic planning: a pinned base facet must never be
    // classified by source/artifact/code heuristics, and missing on-chain code is a fatal
    // bootstrap requirement, not an actionable ADD
    const pinned = network === "ethereum" ? loadPinnedEthereumAddresses().baseFacets.get(facet.name) : undefined;
    if (pinned !== undefined) {
      if (facet.address.toLowerCase() !== pinned.address) {
        throw new Error(
          `${facet.name}: recorded address ${facet.address} does not match the pinned ` +
            `historical address ${pinned.address} — investigate before cutting`
        );
      }
      const pinnedCodeHex = await web3.eth.getCode(facet.address);
      if (pinnedCodeHex === ZERO_CODE) {
        throw new Error(
          `${facet.name}: no code at the pinned address — run the Ethereum bootstrap ` +
            `(DeployEthereumController) before planning a cut`
        );
      }
      if (Web3.utils.keccak256(pinnedCodeHex).toLowerCase() !== pinned.runtimeCodeHash) {
        throw new Error(
          `${facet.name}: on-chain code does not match the pinned historical runtime hash — ` +
            `investigate before cutting`
        );
      }
      plans.push({
        name: facet.name,
        address: facet.address,
        action: "REUSE",
        reason: "pinned historical runtime (byte-identical to the Flare production deployment); intentional reuse",
      });
      continue;
    }

    const artifactPath = artifactPathFor(facet.name);
    // Source presence — not artifact presence — is the source of truth for "still exists".
    // A stale artifact (forge does not prune artifacts of deleted sources) must not mask a removal.
    if (!repoFacetSources.has(facet.name)) {
      plans.push({
        name: facet.name,
        address: facet.address,
        action: "REMOVE",
        reason: existsSync(artifactPath)
          ? "removed from source (stale artifact present — run `forge clean`); its live selectors are listed below"
          : "removed from source; its live selectors are listed below",
      });
      continue;
    }

    if (!existsSync(artifactPath)) {
      plans.push({
        name: facet.name,
        address: facet.address,
        action: "REPLACE",
        reason: "source present but artifact missing — run `forge build` (cannot compare; treating as redeploy)",
      });
      continue;
    }

    const deployedCodeHex = await web3.eth.getCode(facet.address);
    if (deployedCodeHex === ZERO_CODE) {
      plans.push({
        name: facet.name,
        address: facet.address,
        action: "ADD",
        reason: "recorded address has no on-chain code; would deploy fresh",
      });
      continue;
    }

    const deployedCode = hexToBytes(deployedCodeHex);
    const currentCode = loadDeployedCode(facet.name);
    plans.push(compareFacet(facet.name, facet.address, deployedCode, currentCode, proxyCreationCode));
  }

  for (const name of cutFacetNames) {
    if (deployedByName.has(name)) {
      continue;
    }
    plans.push({
      name,
      action: "ADD",
      reason: existsSync(artifactPathFor(name))
        ? "in cut, not in deploys; would deploy as new"
        : `in cut, not in deploys, and missing artifact ${artifactPathFor(name)}`,
    });
  }

  return plans;
}

// --- Section 2: which live selectors are orphaned (deletion candidates) ---

async function buildStaleSelectors(
  web3: Web3,
  network: string,
  deployedContracts: DeployedContract[],
  deployedFacets: DeployedContract[],
  cutFacetNames: string[],
  diamond: string
): Promise<StaleSelector[]> {
  // Selectors kept after the cut come from every facet that will remain on the diamond:
  // the deployed facets that still exist in source, plus any new facets listed in the cut.
  // Requiring source presence (not just an artifact) stops a removed facet's stale-artifact
  // selectors from being treated as kept; including the cut's new facets stops moved selectors
  // from being flagged as stale.
  const repoFacetSources = buildRepoFacetSourceSet();
  const keptFacetNames = uniqueStrings([...deployedFacets.map((contract) => contract.name), ...cutFacetNames]).filter(
    (name) => repoFacetSources.has(name) && existsSync(artifactPathFor(name))
  );

  const repoSelectors = buildRepoSelectorMap(keptFacetNames);
  const facetNamesByAddress = buildFacetNamesByAddress(network, deployedContracts);
  const deployedFacetAddressesByName = buildDeployedFacetAddressesByName(deployedContracts);
  const loupeFacets = await fetchLoupeFacets(web3, diamond);

  const stale = enrichStaleSelectors(
    findStaleSelectors(loupeFacets, repoSelectors),
    facetNamesByAddress,
    deployedFacetAddressesByName
  );

  // Classify each stale selector: MOVED (still exists on some facet in the repo, just not in
  // this cut's scope) vs genuinely REMOVED (gone from all source). A moved selector must NOT be
  // added to deleteSelectorSigs — deleting it would drop a live function; its facet belongs in the cut.
  const allRepoSelectors = buildAllRepoFacetSelectorMap();
  for (const selector of stale) {
    const moved = allRepoSelectors.get(selector.selector.toLowerCase());
    if (moved) {
      selector.movedTo = moved.contractName;
      if (!selector.signature) {
        selector.signature = moved.signature;
      }
    }
  }
  return stale;
}

function buildRepoSelectorMap(facetNames: string[]): Map<string, RepoSelectorInfo> {
  const selectors = new Map<string, RepoSelectorInfo>();
  for (const facetName of facetNames) {
    const functions = loadAbi(facetName).filter(isFunctionFragment);
    for (const fn of functions) {
      selectors.set(toSelector(fn).toLowerCase(), {
        contractName: facetName,
        signature: functionSignature(fn),
      });
    }
  }
  return selectors;
}

// Selectors of every concrete facet implementation currently in the repo, regardless of deploy/cut
// scope. Used to tell a MOVED selector (still defined on some facet) apart from a genuinely REMOVED one.
function buildAllRepoFacetSelectorMap(): Map<string, RepoSelectorInfo> {
  const selectors = new Map<string, RepoSelectorInfo>();
  for (const facetName of buildRepoFacetSourceSet()) {
    if (!existsSync(artifactPathFor(facetName))) {
      continue;
    }
    for (const fn of loadAbi(facetName).filter(isFunctionFragment)) {
      const selector = toSelector(fn).toLowerCase();
      if (!selectors.has(selector)) {
        selectors.set(selector, { contractName: facetName, signature: functionSignature(fn) });
      }
    }
  }
  return selectors;
}

function findStaleSelectors(loupeFacets: LoupeFacet[], repoSelectors: Map<string, RepoSelectorInfo>) {
  const staleSelectors: Array<{ selector: string; facetAddress: string }> = [];
  for (const facet of loupeFacets) {
    for (const selector of facet.functionSelectors) {
      if (!repoSelectors.has(selector)) {
        staleSelectors.push({ selector, facetAddress: facet.facetAddress });
      }
    }
  }
  return staleSelectors.sort((a, b) => a.selector.localeCompare(b.selector));
}

function enrichStaleSelectors(
  staleSelectors: Array<{ selector: string; facetAddress: string }>,
  facetNamesByAddress: Map<string, string>,
  deployedFacetAddressesByName: Map<string, string>
): StaleSelector[] {
  const enriched = staleSelectors.map((stale): StaleSelector => {
    const result: StaleSelector = { ...stale };
    const facetName = facetNamesByAddress.get(stale.facetAddress.toLowerCase());
    if (facetName) {
      result.facetName = facetName;
      const deployedFacetAddress = deployedFacetAddressesByName.get(facetName);
      if (deployedFacetAddress) {
        result.deployedFacetAddress = deployedFacetAddress;
      }
    }
    return result;
  });
  const unresolved = enriched.filter((stale) => stale.signature === undefined);
  if (unresolved.length === 0) {
    return enriched;
  }

  const historicalHints = buildHistoricalSelectorHints(unresolved);
  return enriched.map((stale): StaleSelector => {
    if (stale.signature) {
      return stale;
    }
    const signature = historicalHints.get(stale.selector);
    return signature ? { ...stale, signature } : stale;
  });
}

function buildDeployedFacetAddressesByName(deployedContracts: DeployedContract[]): Map<string, string> {
  const addresses = new Map<string, string>();
  for (const contract of deployedContracts) {
    if (contract.name.endsWith("Facet")) {
      addresses.set(contract.name, contract.address);
    }
  }
  return addresses;
}

function buildFacetNamesByAddress(network: string, deployedContracts: DeployedContract[]): Map<string, string> {
  const names = new Map<string, string>();
  for (const contract of deployedContracts) {
    names.set(contract.address.toLowerCase(), contract.name);
  }

  const deployPath = `deployment/deploys/${network}.json`;
  for (const commit of gitLines(["log", "--all", "--format=%H", "--", deployPath])) {
    const deployed = readHistoricalDeployedContracts(commit, deployPath);
    for (const contract of deployed) {
      if (!names.has(contract.address.toLowerCase())) {
        names.set(contract.address.toLowerCase(), contract.name);
      }
    }
  }
  return names;
}

function readHistoricalDeployedContracts(commit: string, deployPath: string): DeployedContract[] {
  const raw = gitOutput(["show", `${commit}:${deployPath}`]);
  if (!raw) {
    return [];
  }
  try {
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }
    return parsed.filter(isDeployedContract);
  } catch {
    return [];
  }
}

function buildHistoricalSelectorHints(staleSelectors: StaleSelector[]): Map<string, string> {
  const selectorsByFacet = new Map<string, Set<string>>();
  for (const stale of staleSelectors) {
    if (!stale.facetName) {
      continue;
    }
    const selectors = selectorsByFacet.get(stale.facetName) ?? new Set<string>();
    selectors.add(stale.selector);
    selectorsByFacet.set(stale.facetName, selectors);
  }

  const hints = new Map<string, string>();
  for (const [facetName, targetSelectors] of selectorsByFacet) {
    for (const signature of historicalFunctionSignatures(facetName)) {
      const selector = new Web3().eth.abi.encodeFunctionSignature(signature).toLowerCase();
      if (targetSelectors.has(selector) && !hints.has(selector)) {
        hints.set(selector, signature);
      }
    }
  }
  return hints;
}

function historicalFunctionSignatures(contractName: string): Set<string> {
  const signatures = new Set<string>();
  const pathspec = `:(glob)contracts/**/${contractName}.sol`;
  const commits = gitLines(["log", "--all", "--format=%H", "--", pathspec]);

  for (const commit of commits) {
    for (const path of historicalContractPaths(commit, contractName)) {
      const source = gitOutput(["show", `${commit}:${path}`]);
      if (!source) {
        continue;
      }
      for (const signature of extractFunctionSignatures(source)) {
        signatures.add(signature);
      }
    }
  }
  return signatures;
}

function historicalContractPaths(commit: string, contractName: string): string[] {
  return gitLines(["ls-tree", "-r", "--name-only", commit, "--", "contracts"]).filter(
    (path) => basename(path) === `${contractName}.sol`
  );
}

function extractFunctionSignatures(source: string): string[] {
  const cleaned = stripSolidityComments(source);
  const signatures: string[] = [];
  const functionPattern = /\bfunction\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
  let match: RegExpExecArray | null;
  while ((match = functionPattern.exec(cleaned)) !== null) {
    const functionName = match[1];
    const openParen = functionPattern.lastIndex - 1;
    const closeParen = findClosingParen(cleaned, openParen);
    if (!functionName || closeParen < 0) {
      continue;
    }
    const inputTypes = parseFunctionInputTypes(cleaned.slice(openParen + 1, closeParen));
    if (inputTypes) {
      signatures.push(`${functionName}(${inputTypes.join(",")})`);
    }
    functionPattern.lastIndex = closeParen + 1;
  }
  return signatures;
}

function stripSolidityComments(source: string): string {
  return source.replace(/\/\*[\s\S]*?\*\//g, "").replace(/\/\/.*$/gm, "");
}

function findClosingParen(source: string, openParen: number): number {
  let depth = 0;
  for (let i = openParen; i < source.length; i++) {
    const char = source[i];
    if (char === "(") {
      depth++;
    } else if (char === ")") {
      depth--;
      if (depth === 0) {
        return i;
      }
    }
  }
  return -1;
}

function parseFunctionInputTypes(params: string): string[] | undefined {
  const chunks = splitTopLevel(params);
  if (!chunks) {
    return undefined;
  }
  const types: string[] = [];
  for (const chunk of chunks) {
    const type = parseSolidityParameterType(chunk);
    if (!type) {
      return undefined;
    }
    types.push(type);
  }
  return types;
}

function parseSolidityParameterType(param: string): string | undefined {
  // Best-effort historical source parsing: struct/interface aliases would require
  // reconstructing old imports and expanding structs to tuple selector form.
  const cleaned = param
    .replace(/\b(?:calldata|memory|storage)\b/g, " ")
    .replace(/\s+/g, " ")
    .trim();
  if (!cleaned) {
    return undefined;
  }

  const tokens = cleaned.split(" ");
  let type = tokens[0];
  if (!type) {
    return undefined;
  }
  if (type === "address" && tokens[1]?.startsWith("payable")) {
    type = `address${tokens[1].slice("payable".length)}`;
  }

  return canonicalSourceType(type);
}

function canonicalSourceType(type: string): string | undefined {
  let suffix = "";
  let baseType = type;
  while (baseType.endsWith("]")) {
    const arrayMatch = /^(.*)(\[(?:[0-9]+)?\])$/.exec(baseType);
    if (!arrayMatch?.[1] || !arrayMatch[2]) {
      return undefined;
    }
    baseType = arrayMatch[1];
    suffix = `${arrayMatch[2]}${suffix}`;
  }

  if (baseType === "uint") {
    return `uint256${suffix}`;
  }
  if (baseType === "int") {
    return `int256${suffix}`;
  }
  if (isCanonicalSourceBaseType(baseType)) {
    return `${baseType}${suffix}`;
  }
  return undefined;
}

function isCanonicalSourceBaseType(type: string): boolean {
  if (["address", "bool", "string", "bytes", "function"].includes(type)) {
    return true;
  }
  if (/^bytes(?:[1-9]|[1-2][0-9]|3[0-2])$/.test(type)) {
    return true;
  }
  if (/^(?:u?int)(?:[1-9][0-9]*)$/.test(type)) {
    const size = Number(type.replace(/u?int/, ""));
    return size >= 8 && size <= 256 && size % 8 === 0;
  }
  return false;
}

function splitTopLevel(value: string): string[] | undefined {
  const trimmed = value.trim();
  if (!trimmed) {
    return [];
  }

  const result: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < value.length; i++) {
    const char = value[i];
    if (char === "(") {
      depth++;
    } else if (char === ")") {
      if (depth === 0) {
        return undefined;
      }
      depth--;
    } else if (char === "," && depth === 0) {
      result.push(value.slice(start, i).trim());
      start = i + 1;
    }
  }

  if (depth !== 0) {
    return undefined;
  }
  result.push(value.slice(start).trim());
  return result.every((item) => item.length > 0) ? result : undefined;
}

function gitLines(args: string[]): string[] {
  return gitOutput(args)
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter(Boolean);
}

function gitOutput(args: string[]): string {
  try {
    return execFileSync("git", args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] });
  } catch {
    return "";
  }
}

function functionSignature(fn: AbiFunctionFragment): string {
  const inputTypes = (fn.inputs ?? []).map((input) => input.type).join(",");
  return `${fn.name}(${inputTypes})`;
}

// --- shared input loading ---

function uniqueStrings(values: string[]): string[] {
  return Array.from(new Set(values));
}

// --- output ---

function printFacetPlan(plans: FacetPlan[]) {
  console.log("=== Facets (deploy) ===");
  if (plans.length === 0) {
    console.log("  (none)");
    console.log("");
    return;
  }
  for (const plan of plans) {
    const address = plan.address ? ` ${plan.address}` : "";
    console.log(`${plan.action.padEnd(8)} ${plan.name.padEnd(28)}${address}`);
    console.log(`         ${plan.reason}`);
    if (plan.deployedHash && plan.currentHash && plan.deployedHash !== plan.currentHash) {
      console.log(`         deployed=${plan.deployedHash} current=${plan.currentHash}`);
    }
  }
  console.log("");
}

function printSelectorPlan(staleSelectors: StaleSelector[], deleteSelectors: Set<string>) {
  const removed = staleSelectors.filter((stale) => !stale.movedTo);
  const moved = staleSelectors.filter((stale) => stale.movedTo);

  console.log("=== Selectors to remove ===");
  if (removed.length === 0) {
    console.log("  (none — every live selector still exists in current source)");
  }
  for (const stale of removed) {
    const listed = deleteSelectors.has(stale.selector);
    console.log(`DELETE   ${stale.selector} ${stale.signature ?? "unknown"}`);
    console.log(
      `         facet=${stale.facetName ?? "unknown"} liveAddress=${stale.facetAddress} deployedAddress=${stale.deployedFacetAddress ?? "unknown"}`
    );
    console.log(
      listed
        ? "         listed in deleteSelectorSigs — will be removed by the cut"
        : "         NOT in deleteSelectorSigs — add it to remove, else it stays live after the cut"
    );
  }
  console.log("");

  if (moved.length > 0) {
    console.log("=== Moved selectors (repoint — do NOT delete) ===");
    for (const stale of moved) {
      const wronglyListed = deleteSelectors.has(stale.selector);
      console.log(`MOVE     ${stale.selector} ${stale.signature ?? "unknown"}`);
      console.log(
        `         live on ${stale.facetName ?? "unknown"} (${stale.facetAddress}); now defined on ${stale.movedTo}`
      );
      console.log(
        wronglyListed
          ? `         ⚠ IN deleteSelectorSigs — REMOVE it: this selector moved, deleting it drops a live function. Add ${stale.movedTo} to the cut's facets instead.`
          : `         add ${stale.movedTo} to the cut's facets so it repoints (Replace); do NOT add to deleteSelectorSigs`
      );
    }
    console.log("");
  }
}

function printSummary(plans: FacetPlan[], staleSelectors: StaleSelector[], deleteSelectors: Set<string>) {
  const count = (action: FacetAction) => plans.filter((plan) => plan.action === action).length;
  const removed = staleSelectors.filter((stale) => !stale.movedTo);
  const moved = staleSelectors.filter((stale) => stale.movedTo);
  const listed = removed.filter((stale) => deleteSelectors.has(stale.selector)).length;
  const needsListing = removed.length - listed;
  const wronglyListedMoved = moved.filter((stale) => deleteSelectors.has(stale.selector));

  console.log("Summary");
  console.log(
    `  Facets:  ${count("ADD")} add, ${count("REPLACE")} replace, ${count("REUSE")} reuse, ${count("REMOVE")} remove`
  );
  console.log(
    `  Selectors to remove: ${removed.length} (${listed} listed, ${needsListing} need adding to deleteSelectorSigs)`
  );
  if (moved.length > 0) {
    console.log(`  Moved selectors: ${moved.length} (repoint by adding their facet to the cut; do NOT delete)`);
  }

  if (needsListing > 0) {
    console.log("");
    console.log("Add only intentionally removed selectors to deleteSelectorSigs in the cut JSON");
    console.log("(entries accept a 4-byte hex selector or a canonical function signature):");
    for (const stale of removed) {
      if (!deleteSelectors.has(stale.selector)) {
        console.log(`  - ${stale.selector} ${stale.signature ?? "unknown"}`);
      }
    }
  }

  if (wronglyListedMoved.length > 0) {
    console.log("");
    console.log(
      "⚠ deleteSelectorSigs contains selectors that MOVED (not removed) — remove these and add their facet to the cut:"
    );
    for (const stale of wronglyListedMoved) {
      console.log(`  - ${stale.selector} ${stale.signature ?? "unknown"} → now on ${stale.movedTo}`);
    }
  }
}

function printUsageAndExit(): never {
  console.error("Usage: pnpm check_cut <network> [cut-file-name] [--no-build]");
  console.error("Example: pnpm check_cut flare cuts-2026-07-01");
  process.exit(1);
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
