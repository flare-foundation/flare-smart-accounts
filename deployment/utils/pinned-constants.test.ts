import assert from "node:assert/strict";
import { test } from "node:test";
import {
  PROTECTED_ETHEREUM_NAMES,
  loadPinnedEthereumAddresses,
  parsePinnedConstant,
  stripSolidity,
  validateContractName,
} from "./pinned-constants";

const ADDRESS = "0x434936d47503353f06750Db1A444DBDC5F0AD37c";
const OTHER_ADDRESS = "0x0000000000000000000000000000000000000001";
const HASH = `0x${"ab".repeat(32)}`;

function declaration(name: string, value: string, type = "address"): string {
  return `${type} internal constant ${name} = ${value};`;
}

void test("parses a plain typed declaration", () => {
  const source = stripSolidity(declaration("PIN", ADDRESS));
  assert.equal(parsePinnedConstant(source, "PIN", "address"), ADDRESS.toLowerCase());
});

void test("parses a bytes32 declaration split across lines", () => {
  const source = stripSolidity(`bytes32 internal constant PIN_HASH =\n    ${HASH};`);
  assert.equal(parsePinnedConstant(source, "PIN_HASH", "bytes32"), HASH);
});

void test("ignores declarations inside block comments", () => {
  const source = stripSolidity(`/* stale: ${declaration("PIN", OTHER_ADDRESS)} */\n${declaration("PIN", ADDRESS)}`);
  assert.equal(parsePinnedConstant(source, "PIN", "address"), ADDRESS.toLowerCase());
});

void test("ignores declarations inside line comments and strings", () => {
  const source = stripSolidity(
    `// stale: ${declaration("PIN", OTHER_ADDRESS)}\n` +
      `string internal constant NOTE = "${declaration("PIN", OTHER_ADDRESS)}";\n` +
      declaration("PIN", ADDRESS)
  );
  assert.equal(parsePinnedConstant(source, "PIN", "address"), ADDRESS.toLowerCase());
});

void test("throws when the only declaration is commented out", () => {
  const source = stripSolidity(`/* ${declaration("PIN", ADDRESS)} */`);
  assert.throws(() => parsePinnedConstant(source, "PIN", "address"), /found 0/);
});

void test("throws on refactored syntax it does not understand", () => {
  const source = stripSolidity(`address internal constant PIN = address(${ADDRESS});`);
  assert.throws(() => parsePinnedConstant(source, "PIN", "address"), /found 0/);
});

void test("does not match longer identifiers sharing the name", () => {
  const source = stripSolidity(`${declaration("WRAPPED_PIN", OTHER_ADDRESS)}\n${declaration("PIN_V2", OTHER_ADDRESS)}`);
  assert.throws(() => parsePinnedConstant(source, "PIN", "address"), /found 0/);
});

void test("throws on duplicate declarations", () => {
  const source = stripSolidity(`${declaration("PIN", ADDRESS)}\n${declaration("PIN", ADDRESS)}`);
  assert.throws(() => parsePinnedConstant(source, "PIN", "address"), /found 2/);
});

void test("throws on a wrong-width value", () => {
  const source = stripSolidity(declaration("PIN", "0x1234"));
  assert.throws(() => parsePinnedConstant(source, "PIN", "address"), /40-hex-digit/);
});

void test("throws on a type mismatch", () => {
  const source = stripSolidity(declaration("PIN", ADDRESS));
  assert.throws(() => parsePinnedConstant(source, "PIN", "bytes32"), /found 0/);
});

void test("the protected set is exactly these four names", () => {
  // written out rather than derived: every protection downstream - the recorder, the cut
  // executor, the facet-address updater - iterates this list, and their tests iterate it too, so
  // dropping a name here would drop both the protection and the cases that would have caught it
  assert.deepEqual(
    [...PROTECTED_ETHEREUM_NAMES],
    ["MasterAccountController", "DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet"]
  );
  // and each of the three facets is a pin in its own right, the controller being the fourth
  const pins = loadPinnedEthereumAddresses();
  assert.deepEqual([...pins.baseFacets.keys()].sort(), ["DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet"]);
});

void test("loads all six pins from the real constants file", () => {
  const pins = loadPinnedEthereumAddresses();
  assert.equal(pins.controllerAddress, ADDRESS.toLowerCase());
  assert.equal(pins.baseFacets.size, 3);
  for (const facet of pins.baseFacets.values()) {
    assert.match(facet.address, /^0x[0-9a-f]{40}$/);
    assert.match(facet.runtimeCodeHash, /^0x[0-9a-f]{64}$/);
  }
});

void test("accepts ordinary and canonical protected contract names", () => {
  assert.equal(validateContractName("SubaccountsFacet"), undefined);
  assert.equal(validateContractName("OwnershipFacet"), "OwnershipFacet");
  assert.equal(validateContractName("MasterAccountControllerInit"), undefined);
});

void test("rejects path aliases and non-canonical casings", () => {
  assert.throws(() => validateContractName("./OwnershipFacet"), /Solidity identifiers/);
  assert.throws(() => validateContractName(""), /Solidity identifiers/);
  assert.throws(() => validateContractName("ownershipfacet"), /canonical spelling/);
  assert.throws(() => validateContractName("MASTERACCOUNTCONTROLLER"), /canonical spelling/);
});

void test("exposes the pinned initial owner and the controller's runtime code hash", () => {
  const pins = loadPinnedEthereumAddresses();
  assert.equal(pins.initialOwner, "0x7801A7e1FD6a99d1a74DC0a59622b3b7dc4049bA".toLowerCase());
  assert.match(pins.controllerRuntimeCodeHash, /^0x[0-9a-f]{64}$/);
  assert.equal(pins.controllerAddress, ADDRESS.toLowerCase());
});
