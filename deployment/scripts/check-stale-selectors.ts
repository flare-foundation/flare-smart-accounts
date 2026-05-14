#!/usr/bin/env node
import { execFileSync, execSync } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { basename } from "node:path";
import Web3, { type AbiFunctionFragment } from "web3";
import { isFunctionFragment, loadAbi, toSelector } from "../utils/prep-cut";

interface DeployedContract {
  name: string;
  contractName: string;
  address: string;
}

interface CutConfig {
  diamond: string;
  facets?: string[];
  deleteSelectorSigs?: string[];
}

interface LoupeFacet {
  facetAddress: string;
  functionSelectors: string[];
}

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
}

const SUPPORTED_BASE_NETWORKS = ["coston2", "coston", "flare", "songbird", "scdev"];
const FACETS_ABI = {
  type: "tuple[]",
  components: [
    { name: "facetAddress", type: "address" },
    { name: "functionSelectors", type: "bytes4[]" },
  ],
} as const;

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
  const repoFacetNames = deployedContracts
    .filter((contract) => contract.name.endsWith("Facet"))
    .map((contract) => contract.name);
  const deleteSelectors = new Set(
    (cutConfig?.deleteSelectorSigs ?? []).map((selectorOrSignature) => toSelector(selectorOrSignature).toLowerCase())
  );

  const selectorHints = buildSelectorHints(cutConfig);
  const facetNamesByAddress = buildFacetNamesByAddress(network, deployedContracts);
  const deployedFacetAddressesByName = buildDeployedFacetAddressesByName(deployedContracts);
  const repoSelectors = buildRepoSelectorMap(repoFacetNames);
  const loupeFacets = await fetchLoupeFacets(resolveRpcUrl(network), diamond);
  const staleSelectors = enrichStaleSelectors(
    findStaleSelectors(loupeFacets, repoSelectors),
    facetNamesByAddress,
    deployedFacetAddressesByName,
    selectorHints
  );

  console.log(`Checking stale selectors for ${network}`);
  console.log(
    cutFileName ? `Cut file: deployment/cuts/${network}/${normalizeCutFileName(cutFileName)}` : "Cut file: none"
  );
  console.log("Selector scope: all deployed facet artifacts");
  console.log(`Diamond: ${diamond}`);
  console.log(noBuild ? "Build: skipped (--no-build)" : "Build: forge build");
  console.log("");

  if (staleSelectors.length === 0) {
    console.log("No stale selectors found.");
    return;
  }

  for (const stale of staleSelectors) {
    const listed = deleteSelectors.has(stale.selector);
    console.log(`${listed ? "DELETE-LISTED" : "REVIEW"} ${stale.selector} ${stale.signature ?? "unknown"}`);
    console.log(
      `         facet=${stale.facetName ?? "unknown"} liveAddress=${stale.facetAddress} deployedAddress=${stale.deployedFacetAddress ?? "unknown"}`
    );
    console.log("         selector is live in the diamond but absent from current artifact ABIs");
  }

  const needsReview = staleSelectors.filter((stale) => !deleteSelectors.has(stale.selector));
  console.log("");
  console.log(`Summary: ${staleSelectors.length} stale selector(s), ${needsReview.length} needing manual review`);
  if (needsReview.length > 0) {
    console.log("Review these selectors before executing the cut:");
    for (const stale of needsReview) {
      console.log(`  - ${stale.selector} ${stale.signature ?? "unknown"}`);
    }
    console.log("Add only intentionally removed selectors to deleteSelectorSigs in the cut JSON.");
  }
}

function validateNetwork(network: string) {
  const baseNetwork = baseNetworkName(network);
  if (!SUPPORTED_BASE_NETWORKS.includes(baseNetwork)) {
    throw new Error(`Invalid network: ${network}`);
  }
}

function loadDeployedContracts(network: string): DeployedContract[] {
  const path = `deployment/deploys/${network}.json`;
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (!Array.isArray(raw)) {
    throw new Error(`Invalid deployed contracts file: ${path}`);
  }
  return raw.map((item) => {
    if (
      typeof item === "object" &&
      item !== null &&
      typeof (item as { name?: unknown }).name === "string" &&
      typeof (item as { contractName?: unknown }).contractName === "string" &&
      typeof (item as { address?: unknown }).address === "string"
    ) {
      return item as DeployedContract;
    }
    throw new Error(`Invalid deployed contract item in ${path}`);
  });
}

function loadCutConfig(network: string, cutFileName: string): CutConfig {
  const path = `deployment/cuts/${network}/${normalizeCutFileName(cutFileName)}`;
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (typeof raw !== "object" || raw === null) {
    throw new Error(`Invalid cut config: ${path}`);
  }

  const config = raw as { diamond?: unknown; facets?: unknown; deleteSelectorSigs?: unknown };
  if (typeof config.diamond !== "string") {
    throw new Error(`Invalid cut config ${path}: diamond must be a string`);
  }
  if (config.facets !== undefined && !isStringArray(config.facets)) {
    throw new Error(`Invalid cut config ${path}: facets must be an array of strings`);
  }
  if (config.deleteSelectorSigs !== undefined && !isStringArray(config.deleteSelectorSigs)) {
    throw new Error(`Invalid cut config ${path}: deleteSelectorSigs must be an array of strings`);
  }

  const cutConfig: CutConfig = { diamond: config.diamond };
  if (config.facets !== undefined) {
    cutConfig.facets = config.facets;
  }
  if (config.deleteSelectorSigs !== undefined) {
    cutConfig.deleteSelectorSigs = config.deleteSelectorSigs;
  }
  return cutConfig;
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

function findDiamondAddress(deployedContracts: DeployedContract[]): string {
  const diamond = deployedContracts.find(
    (contract) => contract.name === "MasterAccountController" || contract.contractName === "MasterAccountController.sol"
  );
  if (!diamond) {
    throw new Error("Could not find MasterAccountController in deployment/deploys file");
  }
  return diamond.address;
}

function buildRepoSelectorMap(facetNames: string[]): Map<string, RepoSelectorInfo> {
  const selectors = new Map<string, RepoSelectorInfo>();
  for (const facetName of facetNames) {
    const artifactPath = artifactPathFor(facetName);
    if (!existsSync(artifactPath)) {
      console.warn(`Skipping ${facetName}: missing artifact ${artifactPath}`);
      continue;
    }

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

function buildSelectorHints(cutConfig: CutConfig | undefined): Map<string, string> {
  const hints = new Map<string, string>();
  for (const selectorOrSignature of cutConfig?.deleteSelectorSigs ?? []) {
    if (isFunctionSignature(selectorOrSignature)) {
      hints.set(toSelector(selectorOrSignature).toLowerCase(), selectorOrSignature);
    }
  }
  return hints;
}

async function fetchLoupeFacets(rpcUrl: string, diamond: string): Promise<LoupeFacet[]> {
  const web3 = new Web3(rpcUrl);
  const data = web3.eth.abi.encodeFunctionSignature("facets()");
  const encoded = await web3.eth.call({ to: diamond, data });
  const decoded = web3.eth.abi.decodeParameter(FACETS_ABI, encoded);
  if (!Array.isArray(decoded)) {
    throw new Error("Could not decode DiamondLoupe facets()");
  }

  return decoded.map((item) => {
    if (
      typeof item === "object" &&
      item !== null &&
      typeof (item as { facetAddress?: unknown }).facetAddress === "string" &&
      Array.isArray((item as { functionSelectors?: unknown }).functionSelectors)
    ) {
      const functionSelectors = (item as { functionSelectors: unknown[] }).functionSelectors.map((selector) =>
        String(selector).toLowerCase()
      );
      return {
        facetAddress: (item as { facetAddress: string }).facetAddress,
        functionSelectors,
      };
    }
    throw new Error("Invalid DiamondLoupe facet item");
  });
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
  deployedFacetAddressesByName: Map<string, string>,
  selectorHints: Map<string, string>
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
    const signature = selectorHints.get(stale.selector);
    if (signature) {
      result.signature = signature;
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

function isDeployedContract(item: unknown): item is DeployedContract {
  return (
    typeof item === "object" &&
    item !== null &&
    typeof (item as { name?: unknown }).name === "string" &&
    typeof (item as { contractName?: unknown }).contractName === "string" &&
    typeof (item as { address?: unknown }).address === "string"
  );
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

function isFunctionSignature(value: string): boolean {
  return /^[A-Za-z_][A-Za-z0-9_]*\(.*\)$/.test(value);
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

function normalizeCutFileName(cutFileName: string): string {
  return cutFileName.endsWith(".json") ? cutFileName : `${cutFileName}.json`;
}

function resolveRpcUrl(network: string): string {
  const env = { ...readDotEnv(), ...process.env };
  const baseNetwork = baseNetworkName(network);
  const rpcEnvName = `${baseNetwork.toUpperCase()}_RPC_URL`;
  const rpcUrl = env[rpcEnvName];
  if (rpcUrl) {
    return rpcUrl;
  }
  return `https://${baseNetwork}-api.flare.network/ext/C/rpc`;
}

function baseNetworkName(network: string): string {
  return network.endsWith("-staging") ? network.replace(/-staging$/, "") : network;
}

function readDotEnv(): Record<string, string> {
  if (!existsSync(".env")) {
    return {};
  }
  const env: Record<string, string> = {};
  for (const line of readFileSync(".env", "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    const separator = trimmed.indexOf("=");
    if (separator < 0) {
      continue;
    }
    const key = trimmed.slice(0, separator).trim();
    const value = trimmed
      .slice(separator + 1)
      .trim()
      .replace(/^['"]|['"]$/g, "");
    env[key] = value;
  }
  return env;
}

function artifactPathFor(contractName: string): string {
  return `artifacts/${contractName}.sol/${contractName}.json`;
}

function printUsageAndExit(): never {
  console.error("Usage: pnpm check_stale_selectors <network> [cut-file-name] [--no-build]");
  console.error("Example: pnpm check_stale_selectors coston2 cuts-2026-05-14");
  process.exit(1);
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
