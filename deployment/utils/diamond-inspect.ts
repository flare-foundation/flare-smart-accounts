#!/usr/bin/env node
// Diamond inspection shared by the cut planner (check-cut-plan.ts) and the diamond verifier
// (verify-diamond.ts): the RPC's chain check, the deployment record and cut file loaders, and
// the loupe fetch. The network table itself - names, families, chain ids, RPCs - is networks.ts.
import { readFileSync } from "node:fs";
import Web3 from "web3";
import { baseNetworkName, expectedChainId } from "./networks";
import { validateContractName } from "./pinned-constants";

export interface DeployedContract {
  name: string;
  contractName: string;
  address: string;
}

export interface CutConfig {
  diamond: string;
  facets?: string[];
  deleteSelectorSigs?: string[];
  /** When true the cut removes every live selector the listed facets do not declare. */
  deleteAllOldMethods?: boolean;
}

export interface LoupeFacet {
  facetAddress: string;
  functionSelectors: string[];
}

export const FACETS_ABI = {
  type: "tuple[]",
  components: [
    { name: "facetAddress", type: "address" },
    { name: "functionSelectors", type: "bytes4[]" },
  ],
} as const;

export async function fetchLoupeFacets(
  web3: Web3,
  diamond: string,
  blockTag: string | number = "latest"
): Promise<LoupeFacet[]> {
  const data = web3.eth.abi.encodeFunctionSignature("facets()");
  const encoded = await web3.eth.call({ to: diamond, data }, blockTag);
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

// the RPC is picked by network name while every downstream decision keys on the chain the RPC
// actually serves; a mis-set <NETWORK>_RPC_URL would otherwise preview - and let the executor
// cut - another chain. Every network has an id to hold the RPC to: there is no unlisted local chain
export async function assertRpcChain(web3: Web3, network: string) {
  const baseNetwork = baseNetworkName(network);
  const expected = expectedChainId(network);
  const actual = Number(await web3.eth.getChainId());
  if (actual !== expected) {
    throw new Error(
      `RPC for ${network} answers chain id ${actual}, expected ${expected} - check ${baseNetwork.toUpperCase()}_RPC_URL`
    );
  }
}

export function loadDeployedContracts(network: string): DeployedContract[] {
  const path = `deployment/deploys/${network}.json`;
  return parseDeployedContracts(JSON.parse(readFileSync(path, "utf8")), path);
}

/** The deployment record's entries, validated; exported for tests. */
export function parseDeployedContracts(raw: unknown, path: string): DeployedContract[] {
  if (!Array.isArray(raw)) {
    throw new Error(`Invalid deployed contracts file: ${path}`);
  }
  const seen = new Set<string>();
  return raw.map((item) => {
    if (isDeployedContract(item)) {
      // record names become artifact path components later: a path or case alias in the
      // deploys file must fail here, not resolve a protected artifact during planning
      validateContractName(item.name);
      // one authoritative address per name: a duplicate would let the planner (first match)
      // and the verifier (last match) disagree silently
      if (seen.has(item.name)) {
        throw new Error(`Duplicate deployed contract name ${item.name} in ${path}`);
      }
      seen.add(item.name);
      return item;
    }
    throw new Error(`Invalid deployed contract item in ${path}`);
  });
}

export function isDeployedContract(item: unknown): item is DeployedContract {
  return (
    typeof item === "object" &&
    item !== null &&
    typeof (item as { name?: unknown }).name === "string" &&
    typeof (item as { contractName?: unknown }).contractName === "string" &&
    typeof (item as { address?: unknown }).address === "string"
  );
}

export function loadCutConfig(network: string, cutFileName: string): CutConfig {
  const path = `deployment/cuts/${network}/${normalizeCutFileName(cutFileName)}`;
  return parseCutConfig(JSON.parse(readFileSync(path, "utf8")), path);
}

/** A cut file's fields the tooling reads, validated; exported for tests. */
export function parseCutConfig(raw: unknown, path: string): CutConfig {
  if (typeof raw !== "object" || raw === null) {
    throw new Error(`Invalid cut config: ${path}`);
  }

  const config = raw as {
    diamond?: unknown;
    facets?: unknown;
    deleteSelectorSigs?: unknown;
    deleteAllOldMethods?: unknown;
  };
  if (typeof config.diamond !== "string") {
    throw new Error(`Invalid cut config ${path}: diamond must be a string`);
  }
  if (config.facets !== undefined && !isStringArray(config.facets)) {
    throw new Error(`Invalid cut config ${path}: facets must be an array of strings`);
  }
  if (config.deleteSelectorSigs !== undefined && !isStringArray(config.deleteSelectorSigs)) {
    throw new Error(`Invalid cut config ${path}: deleteSelectorSigs must be an array of strings`);
  }
  if (config.deleteAllOldMethods !== undefined && typeof config.deleteAllOldMethods !== "boolean") {
    throw new Error(`Invalid cut config ${path}: deleteAllOldMethods must be a boolean`);
  }

  const cutConfig: CutConfig = { diamond: config.diamond };
  if (config.facets !== undefined) {
    cutConfig.facets = config.facets;
  }
  if (config.deleteSelectorSigs !== undefined) {
    cutConfig.deleteSelectorSigs = config.deleteSelectorSigs;
  }
  if (config.deleteAllOldMethods !== undefined) {
    cutConfig.deleteAllOldMethods = config.deleteAllOldMethods;
  }
  return cutConfig;
}

function isStringArray(value: unknown): value is string[] {
  return Array.isArray(value) && value.every((item) => typeof item === "string");
}

export function findDiamondAddress(deployedContracts: DeployedContract[]): string {
  const diamonds = deployedContracts.filter(
    (contract) => contract.name === "MasterAccountController" || contract.contractName === "MasterAccountController.sol"
  );
  if (diamonds.length === 0) {
    throw new Error("Could not find MasterAccountController in deployment/deploys file");
  }
  // one controller per record: an ambiguous record must not pick one silently
  if (diamonds.length > 1) {
    throw new Error("Ambiguous deployment record: more than one MasterAccountController entry");
  }
  return diamonds[0]!.address;
}

export function normalizeCutFileName(cutFileName: string): string {
  return cutFileName.endsWith(".json") ? cutFileName : `${cutFileName}.json`;
}
