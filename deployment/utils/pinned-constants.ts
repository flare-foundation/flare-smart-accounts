import { readFileSync } from "node:fs";

// The loan-chain bootstrap - Ethereum, or Sepolia reproducing it - recreates the controller and
// its base facets from pinned historical
// init code (see deployment/scripts/PinnedControllerInitCode.sol and
// deployment/pinned-init-code/). The TypeScript tooling parses that Solidity file at runtime,
// so preview, execution, and recording share one source of truth and cannot drift.

export const PINNED_SOURCE = "deployment/scripts/PinnedControllerInitCode.sol";

/** The four deployment records the pinned bootstrap depends on, on either loan chain. */
export const PROTECTED_ETHEREUM_NAMES = [
  "MasterAccountController",
  "DiamondCutFacet",
  "DiamondLoupeFacet",
  "OwnershipFacet",
] as const;

export interface PinnedBaseFacet {
  address: string;
  runtimeCodeHash: string;
}

export interface PinnedEthereumAddresses {
  controllerAddress: string;
  controllerRuntimeCodeHash: string;
  /** `DiamondArgs.owner` of the pinned bootstrap: the diamond's owner until it is transferred. */
  initialOwner: string;
  baseFacets: Map<string, PinnedBaseFacet>;
}

const SOLIDITY_IDENTIFIER = /^[A-Za-z_][A-Za-z0-9_]*$/;

/**
 * Rejects any contract name that is not a plain Solidity identifier (names become artifact
 * path components, so `./OwnershipFacet` would resolve a protected artifact while evading
 * exact-match guards) and any non-canonical casing of a protected name (development
 * filesystems are often case-insensitive, so `ownershipfacet` resolves the same artifact
 * there). Returns the canonical protected name when the name is one, else undefined.
 */
export function validateContractName(name: string): string | undefined {
  if (!SOLIDITY_IDENTIFIER.test(name)) {
    throw new Error(`"${name}": contract names must be Solidity identifiers`);
  }
  const canonical = PROTECTED_ETHEREUM_NAMES.find(
    (protectedName) => protectedName.toLowerCase() === name.toLowerCase()
  );
  if (canonical && canonical !== name) {
    throw new Error(`"${name}": protected names must use their canonical spelling (${canonical})`);
  }
  return canonical;
}

/**
 * Removes everything a Solidity lexer would not treat as code — block comments, line
 * comments, and string literals — then collapses whitespace, so constant parsing can never
 * match a stale commented-out declaration or declaration-like text inside a string. A single
 * alternation pass mirrors lexer behavior: whichever token starts first wins.
 */
export function stripSolidity(raw: string): string {
  return raw.replace(/\/\*[\s\S]*?\*\/|\/\/[^\n]*|"(?:[^"\\\n]|\\.)*"/g, " ").replace(/\s+/g, " ");
}

/**
 * Extracts one pinned constant from stripped Solidity source. Anchored on the complete typed
 * declaration, requires exactly one match, and enforces the type's hex width, so refactored
 * syntax fails loudly instead of silently matching something else.
 */
export function parsePinnedConstant(strippedSource: string, name: string, type: "address" | "bytes32"): string {
  const declaration = new RegExp(
    `\\b${type}\\s+(?:internal\\s+|private\\s+|public\\s+)?constant\\s+${name}\\s*=\\s*(0x[0-9a-fA-F]+)\\s*;`,
    "g"
  );
  const matches = [...strippedSource.matchAll(declaration)];
  if (matches.length !== 1) {
    throw new Error(
      `expected exactly one "${type} constant ${name}" declaration in ${PINNED_SOURCE}, ` + `found ${matches.length}`
    );
  }
  const value = matches[0]?.[1];
  const hexDigits = type === "address" ? 40 : 64;
  if (!value || value.length !== 2 + hexDigits) {
    throw new Error(`"${name}" in ${PINNED_SOURCE} is not a ${hexDigits}-hex-digit ${type}`);
  }
  return value.toLowerCase();
}

let cachedAddresses: PinnedEthereumAddresses | undefined;

/** Parses (and memoizes) the pinned Ethereum addresses from the Solidity constants file. */
export function loadPinnedEthereumAddresses(): PinnedEthereumAddresses {
  if (cachedAddresses) return cachedAddresses;
  const source = stripSolidity(readFileSync(PINNED_SOURCE, "utf8"));
  const baseFacet = (prefix: string): PinnedBaseFacet => ({
    address: parsePinnedConstant(source, prefix, "address"),
    runtimeCodeHash: parsePinnedConstant(source, `${prefix}_RUNTIME_CODE_HASH`, "bytes32"),
  });
  cachedAddresses = {
    controllerAddress: parsePinnedConstant(source, "MASTER_ACCOUNT_CONTROLLER", "address"),
    controllerRuntimeCodeHash: parsePinnedConstant(source, "MASTER_ACCOUNT_CONTROLLER_RUNTIME_CODE_HASH", "bytes32"),
    initialOwner: parsePinnedConstant(source, "INITIAL_OWNER", "address"),
    baseFacets: new Map([
      ["DiamondCutFacet", baseFacet("DIAMOND_CUT_FACET")],
      ["DiamondLoupeFacet", baseFacet("DIAMOND_LOUPE_FACET")],
      ["OwnershipFacet", baseFacet("OWNERSHIP_FACET")],
    ]),
  };
  return cachedAddresses;
}
