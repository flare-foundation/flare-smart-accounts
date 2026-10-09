// The diamond verifier's pure half: the expected selector layout built from facet artifacts and
// the deployment record, its exact two-way comparison with what the loupe reports, the ERC-165
// interface id arithmetic, and the check list the CLI prints. Everything here is deterministic
// over plain values, so it is unit-tested without a chain; verify-diamond.ts does the reading.

import Web3 from "web3";
import type { LoupeFacet } from "./diamond-inspect";

/** A facet the diamond is expected to expose: its recorded address and its artifact's selectors. */
export interface ExpectedFacet {
  name: string;
  address: string;
  selectors: string[];
}

export interface SelectorOwner {
  name: string;
  address: string;
}

/** Selector (lower-case) to the facet expected to serve it. */
export type ExpectedLayout = Map<string, SelectorOwner>;

export interface LayoutDiff {
  /** Expected selectors the diamond does not route at all. */
  missing: { selector: string; expected: SelectorOwner }[];
  /** Expected selectors the diamond routes to another facet. */
  misrouted: { selector: string; expected: SelectorOwner; actual: string }[];
  /** Live selectors no expected facet declares. */
  unexpected: { selector: string; actual: string }[];
  /** Live facet addresses that serve no expected selector. */
  unexpectedFacets: string[];
}

export interface Check {
  name: string;
  ok: boolean;
  expected?: string;
  actual?: string;
}

/** `supportsInterface` must answer false for this id whatever else it supports (EIP-165). */
export const INVALID_INTERFACE_ID = "0xffffffff";

/**
 * LibDiamond's namespace slot, `keccak256(uint256(keccak256("smartAccounts.LibDiamond.DiamondStorage"))
 * - 1) & ~0xff`: the dispatch mapping `facetAddressAndSelectorPosition` sits at it.
 */
export const DIAMOND_STORAGE_POSITION = "0xeb1a5094a6c38a6e1d09c3236f970dde096a4bc09d09acb69322054d3aa6e400";

/** The selectors the verifier itself calls through the diamond, and the base facet each must reach. */
export const VERIFIER_CALLS: readonly { selector: string; signature: string; facet: string }[] = [
  { selector: "0x7a0ed627", signature: "facets()", facet: "DiamondLoupeFacet" },
  { selector: "0x01ffc9a7", signature: "supportsInterface(bytes4)", facet: "DiamondLoupeFacet" },
  { selector: "0x8da5cb5b", signature: "owner()", facet: "OwnershipFacet" },
];

/**
 * The storage slot holding a selector's dispatch entry (`FacetAddressAndSelectorPosition`: the
 * facet address in the low 20 bytes): the mapping key is the selector left-aligned in a word,
 * hashed with the mapping's slot.
 */
export function dispatchSlot(selector: string): string {
  const key = selector.toLowerCase().slice(2).padEnd(64, "0");
  return Web3.utils.keccak256(`0x${key}${DIAMOND_STORAGE_POSITION.slice(2)}`).toLowerCase();
}

/** The address packed into the low 20 bytes of a storage word. */
export function addressInWord(word: string): string {
  return `0x${word.slice(2).padStart(64, "0").slice(-40)}`.toLowerCase();
}

/**
 * Builds the selector-to-facet map the diamond is expected to expose. Every selector must be
 * declared by exactly one facet - a clash is a configuration error, since a diamond cut would
 * have refused it - and the selectors named in `deleteSelectors` (a cut file's
 * `deleteSelectorSigs`, already hashed) are left out.
 */
export function buildExpectedLayout(facets: ExpectedFacet[], deleteSelectors: Iterable<string> = []): ExpectedLayout {
  const layout: ExpectedLayout = new Map();
  for (const facet of facets) {
    for (const rawSelector of facet.selectors) {
      const selector = rawSelector.toLowerCase();
      const existing = layout.get(selector);
      if (existing && existing.name !== facet.name) {
        throw new Error(`selector ${selector} is declared by both ${existing.name} and ${facet.name}`);
      }
      layout.set(selector, { name: facet.name, address: facet.address.toLowerCase() });
    }
  }
  for (const deleted of deleteSelectors) {
    layout.delete(deleted.toLowerCase());
  }
  return layout;
}

/** Compares the expected layout with the loupe's answer in both directions. */
export function diffLayout(expected: ExpectedLayout, loupe: LoupeFacet[]): LayoutDiff {
  const actual = new Map<string, string>();
  for (const facet of loupe) {
    for (const rawSelector of facet.functionSelectors) {
      const selector = rawSelector.toLowerCase();
      // a diamond routes each selector to one facet; a loupe answer listing one twice is not a
      // loupe answer, and collapsing it could pass a corrupt or spoofed response
      if (actual.has(selector)) {
        throw new Error(`the loupe reports selector ${selector} twice`);
      }
      actual.set(selector, facet.facetAddress.toLowerCase());
    }
  }
  const diff: LayoutDiff = { missing: [], misrouted: [], unexpected: [], unexpectedFacets: [] };
  for (const [selector, owner] of expected) {
    const served = actual.get(selector);
    if (served === undefined) {
      diff.missing.push({ selector, expected: owner });
    } else if (served !== owner.address) {
      diff.misrouted.push({ selector, expected: owner, actual: served });
    }
  }
  for (const [selector, served] of actual) {
    if (!expected.has(selector)) {
      diff.unexpected.push({ selector, actual: served });
    }
  }
  const expectedAddresses = new Set([...expected.values()].map((owner) => owner.address));
  for (const facet of loupe) {
    const address = facet.facetAddress.toLowerCase();
    if (!expectedAddresses.has(address) && !diff.unexpectedFacets.includes(address)) {
      diff.unexpectedFacets.push(address);
    }
  }
  return diff;
}

export function layoutMatches(diff: LayoutDiff): boolean {
  return (
    diff.missing.length === 0 &&
    diff.misrouted.length === 0 &&
    diff.unexpected.length === 0 &&
    diff.unexpectedFacets.length === 0
  );
}

/** The layout diff as check-list entries, one per kind of difference, with the details inline. */
export function layoutChecks(diff: LayoutDiff): Check[] {
  return [
    check(
      "selectors: every expected selector is live",
      diff.missing.length === 0,
      "none missing",
      diff.missing.map((item) => `${item.selector} (${item.expected.name})`).join(", ") || "none missing"
    ),
    check(
      "selectors: every expected selector routes to its facet",
      diff.misrouted.length === 0,
      "none misrouted",
      diff.misrouted.map((item) => `${item.selector} (${item.expected.name}) at ${item.actual}`).join(", ") ||
        "none misrouted"
    ),
    check(
      "selectors: no live selector outside the expected set",
      diff.unexpected.length === 0,
      "none unexpected",
      diff.unexpected.map((item) => `${item.selector} at ${item.actual}`).join(", ") || "none unexpected"
    ),
    check(
      "facets: no live facet outside the expected set",
      diff.unexpectedFacets.length === 0,
      "none unexpected",
      diff.unexpectedFacets.join(", ") || "none unexpected"
    ),
  ];
}

/** ERC-165 interface id: the XOR of the interface's function selectors. */
export function interfaceId(selectors: string[]): string {
  let id = 0;
  for (const selector of selectors) {
    id ^= Number.parseInt(selector.slice(2), 16);
  }
  return `0x${(id >>> 0).toString(16).padStart(8, "0")}`;
}

export function check(name: string, ok: boolean, expected?: string, actual?: string): Check {
  const entry: Check = { name, ok };
  if (expected !== undefined) entry.expected = expected;
  if (actual !== undefined) entry.actual = actual;
  return entry;
}

/** An equality check over case-insensitive strings (addresses, hashes, selectors). */
export function checkEq(name: string, expected: string, actual: string): Check {
  return check(name, expected.toLowerCase() === actual.toLowerCase(), expected, actual);
}

export function formatChecks(checks: Check[]): string {
  const lines = checks.map((entry) => {
    const mark = entry.ok ? "ok  " : "FAIL";
    const detail =
      entry.ok || (entry.expected === undefined && entry.actual === undefined)
        ? ""
        : `\n        expected: ${entry.expected ?? "-"}\n        actual:   ${entry.actual ?? "-"}`;
    return `  ${mark}  ${entry.name}${detail}`;
  });
  const failed = checks.filter((entry) => !entry.ok).length;
  lines.push(failed === 0 ? `\nAll ${checks.length} checks passed.` : `\n${failed} of ${checks.length} checks FAILED.`);
  return lines.join("\n");
}

export function allPassed(checks: Check[]): boolean {
  return checks.every((entry) => entry.ok);
}
