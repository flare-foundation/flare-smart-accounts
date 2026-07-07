import fs from "fs";
import Web3, { AbiFunctionFragment, AbiItem } from "web3";
import { DiamondSelectors, type DiamondCut } from "./diamond";

const web3 = new Web3();

export interface FacetInput {
  address: string;
  selectors: string[];
}

export interface InitInput {
  address: string;
  calldata: string;
}

export interface CutConfigInput {
  diamond: string;
  facets: FacetInput[];
  deleteAllOldMethods?: boolean;
  deleteMethods?: string[];
  init?: InitInput;
}

export interface PreparedDiamondCutResult {
  cuts: DiamondCut[];
  initAddress: string;
  initCalldata: string;
  addedSelectors?: string[];
  replacedSelectors?: string[];
  removedSelectors?: string[];
}

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000";

export function prepareDiamondCut(
  config: CutConfigInput,
  deployedSelectors: DiamondSelectors
): PreparedDiamondCutResult {
  // Build a DiamondSelectors object from the facets in the config
  const newSelectorsPossiblyExisting = createNewSelectors(config.facets);
  // Remove any selectors that already exist in the deployed diamond with the same facet address
  const newSelectors = newSelectorsPossiblyExisting.removeExisting(deployedSelectors);
  const deletedSelectors = config.deleteAllOldMethods
    ? deployedSelectors.remove(newSelectorsPossiblyExisting).toDeleteSelectors()
    : createDeletedSelectors(deployedSelectors, config.deleteMethods ?? []);
  const cuts = deployedSelectors.createCuts(newSelectors, deletedSelectors);
  const initAddress = config.init?.address ?? ZERO_ADDRESS;
  const initCalldata = config.init?.calldata ?? "0x";
  // const addedSelectors: string[] = [];
  // const replacedSelectors: string[] = [];
  // const removedSelectors: string[] = [];
  // for (const c of cuts) {
  //   if (c.action === FacetCutAction.Add) addedSelectors.push(...c.functionSelectors);
  //   else if (c.action === FacetCutAction.Replace) replacedSelectors.push(...c.functionSelectors);
  //   else if (c.action === FacetCutAction.Remove) removedSelectors.push(...c.functionSelectors);
  // }
  // return { cuts, initAddress, initCalldata, addedSelectors, replacedSelectors, removedSelectors };
  return { cuts, initAddress, initCalldata };
}

function createNewSelectors(facets: FacetInput[]): DiamondSelectors {
  let selectors = new DiamondSelectors();
  for (const facet of facets) {
    const selectorMap = new Map<string, string>();
    for (const s of facet.selectors) {
      selectorMap.set(s, facet.address);
    }
    selectors = selectors.merge(new DiamondSelectors(selectorMap));
  }
  return selectors;
}

function createDeletedSelectors(deployedSelectors: DiamondSelectors, deleteMethods: string[]): DiamondSelectors {
  const selectorMap: Map<string, string> = new Map();
  for (const methodSigOrSelector of deleteMethods) {
    const selector = toSelector(methodSigOrSelector);
    const facet = deployedSelectors.selectorMap.get(selector);
    if (facet == null) throw new Error(`Unknown method to delete '${methodSigOrSelector}'`);
    selectorMap.set(selector, ZERO_ADDRESS); // diamondCut operation requires 0 facet address for deleted methods
  }
  return new DiamondSelectors(selectorMap);
}

export function selectorsFromLoupeData(
  facets: Array<{ facetAddress: string; functionSelectors: string[] }>
): DiamondSelectors {
  const m = new Map<string, string>();
  for (const f of facets) {
    for (const sel of f.functionSelectors) {
      m.set(sel, f.facetAddress);
    }
  }
  return new DiamondSelectors(m);
}

// narrow to function fragments before encoding; avoids passing constructors/events
export function isFunctionFragment(item: unknown): item is AbiFunctionFragment {
  return (
    typeof item === "object" &&
    item !== null &&
    "type" in item &&
    (item as { type?: string }).type === "function" &&
    "name" in item &&
    typeof (item as { name?: unknown }).name === "string"
  );
}

export function toSelector(item: string | AbiItem) {
  if (typeof item === "string") {
    if (/^0x[0-9a-f]{8}$/i.test(item)) return item;
    if (/^[A-Za-z_][A-Za-z0-9_]*\(.*\)$/.test(item)) {
      requireCanonicalFunctionSignature(item);
      return web3.eth.abi.encodeFunctionSignature(item);
    }
  }
  if (isFunctionFragment(item)) {
    return web3.eth.abi.encodeFunctionSignature(item);
  }
  throw new Error(
    "toSelector: expected a 4-byte hex selector, a function signature string, or a function ABI fragment"
  );
}

function requireCanonicalFunctionSignature(signature: string) {
  if (/\s/.test(signature)) {
    throw new Error(`Invalid function signature '${signature}': use canonical ABI format without whitespace`);
  }

  const match = /^([A-Za-z_][A-Za-z0-9_]*)\((.*)\)$/.exec(signature);
  if (!match) {
    throw new Error(`Invalid function signature '${signature}'`);
  }

  const params = splitTopLevelTypes(match[2] ?? "");
  if (!params || !params.every(isCanonicalAbiType)) {
    throw new Error(`Invalid function signature '${signature}': use canonical ABI parameter types`);
  }
}

function splitTopLevelTypes(types: string): string[] | undefined {
  if (types.length === 0) {
    return [];
  }

  const result: string[] = [];
  let depth = 0;
  let start = 0;
  for (let i = 0; i < types.length; i++) {
    const c = types[i];
    if (c === "(") {
      depth++;
    } else if (c === ")") {
      if (depth === 0) {
        return undefined;
      }
      depth--;
    } else if (c === "," && depth === 0) {
      result.push(types.slice(start, i));
      start = i + 1;
    }
  }

  if (depth !== 0) {
    return undefined;
  }
  result.push(types.slice(start));
  return result.every((type) => type.length > 0) ? result : undefined;
}

function isCanonicalAbiType(type: string): boolean {
  let baseType = type;
  while (baseType.endsWith("]")) {
    const arrayMatch = /^(.*)(\[(?:[1-9][0-9]*)?\])$/.exec(baseType);
    if (!arrayMatch || !arrayMatch[1]) {
      return false;
    }
    baseType = arrayMatch[1];
  }

  // Canonical Solidity selector form uses bare-paren tuples like (t1,t2),
  // NOT the `tuple(...)` JSON-ABI form. The two hash to different selectors.
  if (baseType.startsWith("(") && baseType.endsWith(")")) {
    const tupleTypes = splitTopLevelTypes(baseType.slice(1, -1));
    return !!tupleTypes && tupleTypes.every(isCanonicalAbiType);
  }

  return isCanonicalElementaryAbiType(baseType);
}

function isCanonicalElementaryAbiType(type: string): boolean {
  if (["address", "bool", "string", "bytes", "function"].includes(type)) {
    return true;
  }

  const bytesMatch = /^bytes([0-9]+)$/.exec(type);
  if (bytesMatch?.[1]) {
    const size = Number(bytesMatch[1]);
    return size >= 1 && size <= 32;
  }

  const intMatch = /^(?:u?int)([0-9]+)$/.exec(type);
  if (intMatch?.[1]) {
    const size = Number(intMatch[1]);
    return size >= 8 && size <= 256 && size % 8 === 0;
  }

  const fixedMatch = /^(?:u?fixed)([0-9]+)x([0-9]+)$/.exec(type);
  if (fixedMatch?.[1] && fixedMatch[2]) {
    const bits = Number(fixedMatch[1]);
    const decimals = Number(fixedMatch[2]);
    return bits >= 8 && bits <= 256 && bits % 8 === 0 && decimals >= 1 && decimals <= 80;
  }

  return false;
}

export function loadAbi(contractName: string): AbiItem[] {
  const raw = fs.readFileSync(`artifacts/${contractName}.sol/${contractName}.json`, "utf8");
  const parsed = JSON.parse(raw) as { abi: AbiItem[] };
  return parsed.abi;
}

export function parseArgs(argv: string[]) {
  const args: Record<string, string> = {};
  for (let i = 2; i < argv.length; i += 2) {
    const key = argv[i];
    const value = argv[i + 1];
    if (key === undefined || value === undefined) continue;
    args[key.replace(/^--/, "")] = value;
  }
  return args;
}

export function readFacetsFile(p: string) {
  // line format: address|contractName
  const lines = fs.readFileSync(p, "utf8").split(/\r?\n/).filter(Boolean);
  return lines.map((l) => {
    const parts = l.split("|");
    if (parts.length !== 2 || !parts[0] || !parts[1]) {
      throw new Error(`Invalid facets line (expected address|contractName): ${l}`);
    }
    return { address: parts[0], contractName: parts[1] };
  });
}

export function readLoupeFile(p: string) {
  // line format: facetAddress|sel1,sel2,sel3
  const lines = fs.readFileSync(p, "utf8").split(/\r?\n/).filter(Boolean);
  return lines.map((l) => {
    const [facetAddress, selectors] = l.split("|");
    if (!facetAddress) {
      throw new Error(`Invalid loupe line (expected facetAddress|selectors): ${l}`);
    }
    const functionSelectors = (selectors ? selectors.split(",") : []).filter(Boolean);
    return { facetAddress, functionSelectors };
  });
}
