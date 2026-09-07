import assert from "node:assert/strict";
import { test } from "node:test";
import {
  DIAMOND_STORAGE_POSITION,
  INVALID_INTERFACE_ID,
  VERIFIER_CALLS,
  addressInWord,
  allPassed,
  buildExpectedLayout,
  checkEq,
  diffLayout,
  formatChecks,
  dispatchSlot,
  interfaceId,
  layoutChecks,
  layoutMatches,
} from "./diamond-verify";

const CUT = "0x000000000000000000000000000000000000000A";
const LOUPE = "0x000000000000000000000000000000000000000b";
const STRANGER = "0x000000000000000000000000000000000000000C";

const facets = [
  { name: "DiamondCutFacet", address: CUT, selectors: ["0x1F931C1C"] },
  { name: "DiamondLoupeFacet", address: LOUPE, selectors: ["0x7a0ed627", "0xadfca15e", "0x52ef6b2c", "0xcdffacc6"] },
];

void test("builds the layout lower-cased and drops deleted selectors", () => {
  const layout = buildExpectedLayout(facets, ["0xCDFFACC6"]);
  assert.equal(layout.size, 4);
  assert.deepEqual(layout.get("0x1f931c1c"), { name: "DiamondCutFacet", address: CUT.toLowerCase() });
  assert.equal(layout.has("0xcdffacc6"), false);
});

void test("refuses a selector two facets declare", () => {
  const clashing = [...facets, { name: "Other", address: STRANGER, selectors: ["0x1f931c1c"] }];
  assert.throws(() => buildExpectedLayout(clashing), /declared by both DiamondCutFacet and Other/);
});

void test("an exact loupe answer produces an empty diff", () => {
  const layout = buildExpectedLayout(facets);
  const diff = diffLayout(layout, [
    { facetAddress: CUT, functionSelectors: ["0x1f931c1c"] },
    { facetAddress: LOUPE, functionSelectors: ["0x7a0ed627", "0xadfca15e", "0x52ef6b2c", "0xcdffacc6"] },
  ]);
  assert.equal(layoutMatches(diff), true);
  assert.equal(allPassed(layoutChecks(diff)), true);
});

void test("reports missing, misrouted and unexpected selectors and facets", () => {
  const layout = buildExpectedLayout(facets);
  const diff = diffLayout(layout, [
    // the cut selector routed to the loupe facet, one loupe selector missing, a stranger facet
    // serving an unknown selector
    { facetAddress: LOUPE, functionSelectors: ["0x1f931c1c", "0x7a0ed627", "0xadfca15e", "0x52ef6b2c"] },
    { facetAddress: STRANGER, functionSelectors: ["0xdeadbeef"] },
  ]);
  assert.equal(layoutMatches(diff), false);
  assert.deepEqual(
    diff.missing.map((item) => item.selector),
    ["0xcdffacc6"]
  );
  assert.deepEqual(diff.misrouted, [
    { selector: "0x1f931c1c", expected: { name: "DiamondCutFacet", address: CUT.toLowerCase() }, actual: LOUPE },
  ]);
  assert.deepEqual(diff.unexpected, [{ selector: "0xdeadbeef", actual: STRANGER.toLowerCase() }]);
  assert.deepEqual(diff.unexpectedFacets, [STRANGER.toLowerCase()]);
  const checks = layoutChecks(diff);
  assert.equal(checks.length, 4);
  assert.equal(allPassed(checks), false);
  assert.match(formatChecks(checks), /4 of 4 checks FAILED/);
});

void test("refuses a loupe answer that lists a selector twice", () => {
  const layout = buildExpectedLayout(facets);
  assert.throws(
    () =>
      diffLayout(layout, [
        { facetAddress: CUT, functionSelectors: ["0x1f931c1c"] },
        {
          facetAddress: LOUPE,
          functionSelectors: ["0x1f931c1c", "0x7a0ed627", "0xadfca15e", "0x52ef6b2c", "0xcdffacc6"],
        },
      ]),
    /reports selector 0x1f931c1c twice/
  );
});

void test("computes ERC-165 interface ids as the XOR of the selectors", () => {
  // IERC165, IDiamondCut, IDiamondLoupe and IERC173, from their canonical selectors
  assert.equal(interfaceId(["0x01ffc9a7"]), "0x01ffc9a7");
  assert.equal(interfaceId(["0x1f931c1c"]), "0x1f931c1c");
  assert.equal(interfaceId(["0x7a0ed627", "0xadfca15e", "0x52ef6b2c", "0xcdffacc6"]), "0x48e2b093");
  assert.equal(interfaceId(["0x8da5cb5b", "0xf2fde38b"]), "0x7f5828d0");
  assert.equal(INVALID_INTERFACE_ID, "0xffffffff");
});

void test("equality checks ignore case and the report names the failures", () => {
  const ok = checkEq("owner", CUT, CUT.toLowerCase());
  const bad = checkEq("owner", CUT, STRANGER);
  assert.equal(ok.ok, true);
  assert.equal(bad.ok, false);
  const report = formatChecks([ok, bad]);
  assert.match(report, /ok {4}owner/);
  assert.match(report, /FAIL {2}owner\n {8}expected: 0x0{39}A\n {8}actual: {3}0x0{39}C/);
  assert.match(report, /1 of 2 checks FAILED/);
  assert.match(formatChecks([ok]), /All 1 checks passed/);
});

void test("derives the diamond's dispatch slots from the namespace", () => {
  // the namespace slot and the two dispatch slots, computed independently with cast
  assert.equal(DIAMOND_STORAGE_POSITION, "0xeb1a5094a6c38a6e1d09c3236f970dde096a4bc09d09acb69322054d3aa6e400");
  assert.equal(dispatchSlot("0x7A0ED627"), "0x3cefed86cba579517411f500a8093b4effcfbea58d3a0741d070a661b7b639e2");
  assert.equal(dispatchSlot("0x8da5cb5b"), "0x97158eb12a06e54f18764d68fd44939612c086a73175302054c534aa2ced45cc");
  assert.equal(VERIFIER_CALLS.map((call) => call.selector).join(","), "0x7a0ed627,0x01ffc9a7,0x8da5cb5b");
});

void test("reads the address out of a packed storage word", () => {
  // a dispatch entry packs a uint16 position above the address; a short word is left-padded
  assert.equal(addressInWord(`0x0000000000000000000000${"01"}${CUT.slice(2)}`), CUT.toLowerCase());
  assert.equal(addressInWord(CUT), CUT.toLowerCase());
  assert.equal(addressInWord("0x0"), "0x0000000000000000000000000000000000000000");
});
