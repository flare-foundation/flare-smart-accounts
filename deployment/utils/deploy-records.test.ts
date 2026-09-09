import assert from "node:assert/strict";
import { test } from "node:test";
import {
  type ContractInfo,
  PROTECTED_RECORD_NAMES,
  mergeDeployedRecords,
  parseAllowedReplacements,
} from "./deploy-records";

const record = (name: string, address: string): ContractInfo => ({
  name,
  contractName: `${name}.sol`,
  address,
});

// hex letters, so an upper-cased copy really differs textually: an all-digit fixture would let
// the address comparison drop its normalization and still pass
const A = "0xaaaabbbbccccddddeeeeffff1111222233334444";
const A_UPPER = "0xAAAABBBBCCCCDDDDEEEEFFFF1111222233334444";
const B = "0x2222222222222222222222222222222222222222";

void test("a new record is appended", () => {
  const merged = mergeDeployedRecords([record("PauseFacet", A)], [record("ReaderFacet", B)]);
  assert.deepEqual(
    merged.map((item) => item.name),
    ["PauseFacet", "ReaderFacet"]
  );
});

void test("a facet record is replaced freely: redeploying one is the ordinary cut flow", () => {
  const merged = mergeDeployedRecords([record("PauseFacet", A)], [record("PauseFacet", B)]);
  assert.equal(merged.length, 1);
  assert.equal(merged[0]?.address, B);
});

void test("replacing the recorded controller with a different address is refused", () => {
  // this is what `deploy_contracts <network> false` does on a live network: `false` skips only the
  // cut and the vault configuration, so a controller is still deployed from current source - which
  // deliberately cannot reproduce the historical production address - and recorded over the live one
  assert.throws(
    () => mergeDeployedRecords([record("MasterAccountController", A)], [record("MasterAccountController", B)]),
    (error: Error) => {
      assert.match(error.message, /refusing to replace the recorded address/);
      assert.match(error.message, /ALLOW_RECORD_REPLACEMENT=MasterAccountController/);
      return true;
    }
  );
});

void test("the protected set is exactly these two records", () => {
  // pinned independently of the module's own list: a test that iterates the list it is testing
  // loses its case the moment a name is dropped from it, and silently passes
  assert.deepEqual([...PROTECTED_RECORD_NAMES].sort(), ["FAssetRedeemComposer_FXRP", "MasterAccountController"]);
});

void test("every protected record is covered, not just the controller", () => {
  for (const name of ["MasterAccountController", "FAssetRedeemComposer_FXRP"]) {
    assert.throws(
      () => mergeDeployedRecords([record(name, A)], [record(name, B)]),
      new RegExp(`${name}: refusing to replace`),
      `${name} was replaceable`
    );
  }
});

void test("an implementation upgrade needs no flag: that is what the deploy scripts are for", () => {
  // `deploy_personal_account_implementation` and its siblings deploy a new implementation and
  // record it under these exact names, so their entries are MEANT to follow every upgrade.
  // Protecting them would demand the override on the ordinary path, the flag would end up set
  // permanently, and the guard would stop guarding anything
  for (const name of [
    "PersonalAccountImplementation",
    "LoanSubaccountImplementation",
    "PersonalAccountRemoteImplementation",
    "MorphoLoanSubaccountRemoteImplementation",
    "FAssetRedeemComposerImplementation",
    "FAssetRedeemerAccountImplementation",
  ]) {
    const merged = mergeDeployedRecords([record(name, A)], [record(name, B)]);
    assert.equal(merged[0]?.address, B, `${name} should follow its redeployment`);
  }
});

void test("re-recording a protected record at the same address needs no flag", () => {
  // a rerun that redeployed nothing must not demand an override, and a differently-cased copy of
  // the same address is the same address
  const merged = mergeDeployedRecords(
    [record("MasterAccountController", A)],
    [record("MasterAccountController", A_UPPER)]
  );
  assert.equal(merged.length, 1);
});

void test("a protected record absent from the file is recorded without a flag", () => {
  // the first deployment on a network is not a replacement
  const merged = mergeDeployedRecords([], [record("MasterAccountController", A)]);
  assert.equal(merged[0]?.address, A);
});

void test("the named record may be replaced when the caller opts in, and only that one", () => {
  const existing = [record("MasterAccountController", A), record("FAssetRedeemComposer_FXRP", A)];
  const allowed = parseAllowedReplacements("MasterAccountController");

  const merged = mergeDeployedRecords(existing, [record("MasterAccountController", B)], allowed);
  assert.equal(merged[0]?.address, B);

  assert.throws(
    () => mergeDeployedRecords(existing, [record("FAssetRedeemComposer_FXRP", B)], allowed),
    /FAssetRedeemComposer_FXRP: refusing to replace/,
    "opting in for one record must not authorize another"
  );
});

void test("the opt-in list is comma-separated and tolerates spacing", () => {
  const allowed = parseAllowedReplacements(" MasterAccountController , FAssetRedeemComposer_FXRP ");
  assert.deepEqual([...allowed].sort(), ["FAssetRedeemComposer_FXRP", "MasterAccountController"]);
});

void test("an unset or empty opt-in authorizes nothing", () => {
  assert.equal(parseAllowedReplacements(undefined).size, 0);
  assert.equal(parseAllowedReplacements("").size, 0);
  assert.equal(parseAllowedReplacements(" , ").size, 0);
});

void test("the input record is not mutated", () => {
  const existing = [record("PauseFacet", A)];
  mergeDeployedRecords(existing, [record("PauseFacet", B)]);
  assert.equal(existing[0]?.address, A, "the caller's array was mutated");
});
