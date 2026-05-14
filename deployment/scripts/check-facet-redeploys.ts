#!/usr/bin/env node
import { execSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, readFileSync } from "node:fs";
import Web3 from "web3";

interface DeployedContract {
  name: string;
  contractName: string;
  address: string;
}

interface CutConfig {
  facets?: string[];
}

interface BytecodeOutput {
  object: string;
}

type ComparisonStatus = "changed" | "metadata-only" | "exact" | "missing-address" | "missing-artifact" | "missing-code";

interface ComparisonResult {
  name: string;
  address?: string;
  status: ComparisonStatus;
  reason: string;
  currentHash?: string;
  deployedHash?: string;
}

const ZERO_CODE = "0x";
const SUPPORTED_BASE_NETWORKS = ["coston2", "coston", "flare", "songbird", "scdev"];

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
  const facetNames = cutFileName
    ? loadCutFacetNames(network, cutFileName)
    : deployedContracts.filter((contract) => contract.name.endsWith("Facet")).map((contract) => contract.name);
  const deployedByName = new Map(deployedContracts.map((contract) => [contract.name, contract]));
  const rpcUrl = resolveRpcUrl(network);
  const web3 = new Web3(rpcUrl);
  const proxyCreationCode = loadCreationCode("PersonalAccountProxy");

  console.log(`Checking facet redeploys for ${network}`);
  console.log(
    cutFileName
      ? `Scope: deployment/cuts/${network}/${normalizeCutFileName(cutFileName)}`
      : "Scope: all deployed facets"
  );
  console.log(noBuild ? "Build: skipped (--no-build)" : "Build: forge build");
  console.log("");

  const results: ComparisonResult[] = [];
  for (const facetName of facetNames) {
    const deployed = deployedByName.get(facetName);
    if (!deployed) {
      results.push({
        name: facetName,
        status: "missing-address",
        reason: "not present in deployment/deploys file; would deploy as new",
      });
      continue;
    }

    const artifactPath = artifactPathFor(facetName);
    if (!existsSync(artifactPath)) {
      results.push({
        name: facetName,
        address: deployed.address,
        status: "missing-artifact",
        reason: `missing artifact ${artifactPath}`,
      });
      continue;
    }

    const deployedCodeHex = await web3.eth.getCode(deployed.address);
    if (deployedCodeHex === ZERO_CODE) {
      results.push({
        name: facetName,
        address: deployed.address,
        status: "missing-code",
        reason: "address has no deployed code; would redeploy",
      });
      continue;
    }

    const deployedCode = hexToBytes(deployedCodeHex);
    const currentCode = loadDeployedCode(facetName);
    results.push(compareFacet(facetName, deployed.address, deployedCode, currentCode, proxyCreationCode));
  }

  printResults(results);
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

function loadCutFacetNames(network: string, cutFileName: string): string[] {
  const path = `deployment/cuts/${network}/${normalizeCutFileName(cutFileName)}`;
  const raw: unknown = JSON.parse(readFileSync(path, "utf8"));
  if (
    typeof raw === "object" &&
    raw !== null &&
    Array.isArray((raw as CutConfig).facets) &&
    (raw as CutConfig).facets?.every((facet) => typeof facet === "string")
  ) {
    return (raw as { facets: string[] }).facets;
  }
  throw new Error(`Invalid cut file facets array: ${path}`);
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

function compareFacet(
  facetName: string,
  address: string,
  deployedCode: Buffer,
  currentCode: Buffer,
  proxyCreationCode: Buffer
): ComparisonResult {
  const deployedRuntime = stripMetadata(deployedCode);
  const currentRuntime = stripMetadata(currentCode);
  const deployedHash = shortHash(deployedRuntime);
  const currentHash = shortHash(currentRuntime);

  if (deployedCode.equals(currentCode)) {
    return {
      name: facetName,
      address,
      status: "exact",
      reason: "full deployed bytecode matches",
      currentHash,
      deployedHash,
    };
  }

  if (deployedRuntime.equals(currentRuntime)) {
    return {
      name: facetName,
      address,
      status: "metadata-only",
      reason: "only the facet trailing Solidity metadata differs; would reuse",
      currentHash,
      deployedHash,
    };
  }

  const onlyEmbeddedProxyMetadataChanged = hasOnlyEmbeddedProxyMetadataChange(
    deployedRuntime,
    currentRuntime,
    proxyCreationCode
  );
  return {
    name: facetName,
    address,
    status: "changed",
    reason: onlyEmbeddedProxyMetadataChanged
      ? "embedded PersonalAccountProxy.creationCode metadata differs; would redeploy"
      : "functional runtime bytecode differs; would redeploy",
    currentHash,
    deployedHash,
  };
}

function hasOnlyEmbeddedProxyMetadataChange(
  deployedRuntime: Buffer,
  currentRuntime: Buffer,
  proxyCreationCode: Buffer
): boolean {
  const normalizedDeployedRuntime = stripEmbeddedProxyMetadata(deployedRuntime, proxyCreationCode);
  const normalizedCurrentRuntime = stripEmbeddedProxyMetadata(currentRuntime, proxyCreationCode);
  return (
    (!normalizedDeployedRuntime.equals(deployedRuntime) || !normalizedCurrentRuntime.equals(currentRuntime)) &&
    normalizedDeployedRuntime.equals(normalizedCurrentRuntime)
  );
}

function stripEmbeddedProxyMetadata(code: Buffer, proxyCreationCode: Buffer): Buffer {
  const strippedProxyCreationCode = stripMetadata(proxyCreationCode);
  if (strippedProxyCreationCode.length === proxyCreationCode.length) {
    return code;
  }

  const chunks: Buffer[] = [];
  let cursor = 0;
  let changed = false;
  while (cursor < code.length) {
    const index = code.indexOf(strippedProxyCreationCode, cursor);
    if (index < 0) {
      chunks.push(code.subarray(cursor));
      break;
    }

    const embeddedProxy = code.subarray(index, index + proxyCreationCode.length);
    if (
      embeddedProxy.length === proxyCreationCode.length &&
      stripMetadata(embeddedProxy).equals(strippedProxyCreationCode)
    ) {
      chunks.push(code.subarray(cursor, index));
      chunks.push(strippedProxyCreationCode);
      cursor = index + proxyCreationCode.length;
      changed = true;
    } else {
      chunks.push(code.subarray(cursor, index + 1));
      cursor = index + 1;
    }
  }

  return changed ? Buffer.concat(chunks) : code;
}

function loadDeployedCode(contractName: string): Buffer {
  const artifact = loadArtifact(contractName);
  if (isBytecodeOutput(artifact.deployedBytecode)) {
    return hexToBytes(artifact.deployedBytecode.object);
  }
  throw new Error(`Missing deployed bytecode object for ${contractName}`);
}

function loadCreationCode(contractName: string): Buffer {
  const artifact = loadArtifact(contractName);
  if (isBytecodeOutput(artifact.bytecode)) {
    return hexToBytes(artifact.bytecode.object);
  }
  throw new Error(`Missing creation bytecode object for ${contractName}`);
}

function isBytecodeOutput(value: unknown): value is BytecodeOutput {
  return (
    typeof value === "object" &&
    value !== null &&
    "object" in value &&
    typeof (value as { object?: unknown }).object === "string"
  );
}

function loadArtifact(contractName: string): { bytecode?: unknown; deployedBytecode?: unknown } {
  return JSON.parse(readFileSync(artifactPathFor(contractName), "utf8")) as {
    bytecode?: unknown;
    deployedBytecode?: unknown;
  };
}

function artifactPathFor(contractName: string): string {
  return `artifacts/${contractName}.sol/${contractName}.json`;
}

function stripMetadata(code: Buffer): Buffer {
  const suffixLength = metadataSuffixLength(code);
  return code.subarray(0, code.length - suffixLength);
}

function metadataSuffixLength(code: Buffer): number {
  if (code.length < 2) {
    return 0;
  }
  const metadataLength = ((code[code.length - 2] ?? 0) << 8) | (code[code.length - 1] ?? 0);
  if (metadataLength === 0 || metadataLength + 2 > code.length) {
    return 0;
  }
  const metadataStart = code.length - metadataLength - 2;
  if ((code[metadataStart] ?? 0) >> 5 !== 5) {
    return 0;
  }
  return metadataLength + 2;
}

function hexToBytes(hex: string): Buffer {
  const normalized = hex.startsWith("0x") ? hex.slice(2) : hex;
  return Buffer.from(normalized, "hex");
}

function shortHash(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex").slice(0, 16);
}

function printResults(results: ComparisonResult[]) {
  const wouldRedeploy = results.filter((result) =>
    ["changed", "missing-address", "missing-artifact", "missing-code"].includes(result.status)
  );
  const reusable = results.filter((result) => ["exact", "metadata-only"].includes(result.status));

  for (const result of results) {
    const marker = wouldRedeploy.includes(result) ? "REDEPLOY" : "REUSE";
    const address = result.address ? ` ${result.address}` : "";
    console.log(`${marker.padEnd(8)} ${result.name.padEnd(28)} ${result.status.padEnd(16)}${address}`);
    console.log(`         ${result.reason}`);
    if (result.deployedHash && result.currentHash && result.deployedHash !== result.currentHash) {
      console.log(`         deployed=${result.deployedHash} current=${result.currentHash}`);
    }
  }

  console.log("");
  console.log(`Summary: ${wouldRedeploy.length} would redeploy, ${reusable.length} would reuse`);
  if (wouldRedeploy.length > 0) {
    console.log("Facets that need redeployment:");
    for (const result of wouldRedeploy) {
      console.log(`  - ${result.name}`);
    }
  }
}

function printUsageAndExit(): never {
  console.error("Usage: pnpm check_facet_redeploys <network> [cut-file-name] [--no-build]");
  console.error("Example: pnpm check_facet_redeploys coston2 cuts-2026-05-14");
  process.exit(1);
}

main().catch((err: unknown) => {
  console.error(err instanceof Error ? err.message : String(err));
  process.exit(1);
});
