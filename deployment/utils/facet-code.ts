#!/usr/bin/env node
// Facet code comparison shared by the cut planner (check-cut-plan.ts) and the diamond verifier
// (verify-diamond.ts): the artifact loaders, the metadata stripping (the facet's own trailer and
// the PersonalAccountProxy creation code embedded in some facets), the REUSE/REPLACE verdict, and
// the source-presence set that decides whether a recorded facet still exists in the repository.
import { createHash } from "node:crypto";
import { globSync, readFileSync } from "node:fs";
import { basename } from "node:path";

export interface BytecodeOutput {
  object: string;
}

export type FacetAction = "ADD" | "REPLACE" | "REUSE" | "REMOVE";

export interface FacetPlan {
  name: string;
  address?: string;
  action: FacetAction;
  reason: string;
  currentHash?: string;
  deployedHash?: string;
}

export const ZERO_CODE = "0x";

export function compareFacet(
  facetName: string,
  address: string,
  deployedCode: Buffer,
  currentCode: Buffer,
  proxyCreationCode: Buffer
): FacetPlan {
  const deployedRuntime = stripMetadata(deployedCode);
  const currentRuntime = stripMetadata(currentCode);
  const deployedHash = shortHash(deployedRuntime);
  const currentHash = shortHash(currentRuntime);

  if (deployedCode.equals(currentCode)) {
    return {
      name: facetName,
      address,
      action: "REUSE",
      reason: "full deployed bytecode matches",
      currentHash,
      deployedHash,
    };
  }

  if (deployedRuntime.equals(currentRuntime)) {
    return {
      name: facetName,
      address,
      action: "REUSE",
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
    action: "REPLACE",
    reason: onlyEmbeddedProxyMetadataChanged
      ? "embedded PersonalAccountProxy.creationCode metadata differs; would redeploy"
      : "functional runtime bytecode differs; would redeploy",
    currentHash,
    deployedHash,
  };
}

export function hasOnlyEmbeddedProxyMetadataChange(
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

export function stripEmbeddedProxyMetadata(code: Buffer, proxyCreationCode: Buffer): Buffer {
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

export function loadDeployedCode(contractName: string): Buffer {
  const artifact = loadArtifact(contractName);
  if (isBytecodeOutput(artifact.deployedBytecode)) {
    return hexToBytes(artifact.deployedBytecode.object);
  }
  throw new Error(`Missing deployed bytecode object for ${contractName}`);
}

export function loadCreationCode(contractName: string): Buffer {
  const artifact = loadArtifact(contractName);
  if (isBytecodeOutput(artifact.bytecode)) {
    return hexToBytes(artifact.bytecode.object);
  }
  throw new Error(`Missing creation bytecode object for ${contractName}`);
}

export function isBytecodeOutput(value: unknown): value is BytecodeOutput {
  return (
    typeof value === "object" &&
    value !== null &&
    "object" in value &&
    typeof (value as { object?: unknown }).object === "string"
  );
}

export function loadArtifact(contractName: string): { bytecode?: unknown; deployedBytecode?: unknown } {
  return JSON.parse(readFileSync(artifactPathFor(contractName), "utf8")) as {
    bytecode?: unknown;
    deployedBytecode?: unknown;
  };
}

// The trailer length is read from the compared code itself, which is sound: a reuse verdict
// requires the functional prefix to hash-match the artifact's functional code, so a crafted
// trailer can only append unreachable bytes to functionally identical code - a poisoned deploy
// record cannot route selectors to different logic. The artifact side always carries a real
// trailer (foundry.toml keeps the default CBOR metadata).
export function stripMetadata(code: Buffer): Buffer {
  const suffixLength = metadataSuffixLength(code);
  return code.subarray(0, code.length - suffixLength);
}

export function metadataSuffixLength(code: Buffer): number {
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

export function hexToBytes(hex: string): Buffer {
  const normalized = hex.startsWith("0x") ? hex.slice(2) : hex;
  return Buffer.from(normalized, "hex");
}

export function shortHash(data: Buffer): string {
  return createHash("sha256").update(data).digest("hex").slice(0, 16);
}

// Names of every concrete facet implementation currently in the repo
// (contracts/**/facets/*Facet.sol, interfaces excluded). Source presence — not artifact presence —
// is the source of truth for whether a facet still exists; a stale artifact for a deleted facet
// (forge does not prune artifacts of removed sources) must not mask its removal.
export function buildRepoFacetSourceSet(): Set<string> {
  const names = new Set<string>();
  for (const sourcePath of globSync("contracts/**/facets/*Facet.sol")) {
    if (/interface/i.test(sourcePath)) {
      continue;
    }
    names.add(basename(sourcePath).replace(/\.sol$/, ""));
  }
  return names;
}

export function artifactPathFor(contractName: string): string {
  return `artifacts/${contractName}.sol/${contractName}.json`;
}
