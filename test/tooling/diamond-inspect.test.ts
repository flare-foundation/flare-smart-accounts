import assert from "node:assert/strict";
import { test } from "node:test";
import {
  findDiamondAddress,
  loadCutConfig,
  parseCutConfig,
  parseDeployedContracts,
} from "../../deployment/utils/diamond-inspect";

const DIAMOND = "0x434936d47503353f06750Db1A444DBDC5F0AD37c";

void test("parses a cut file's fields, deleteAllOldMethods included", () => {
  const config = parseCutConfig(
    { diamond: DIAMOND, facets: ["PauseFacet"], deleteSelectorSigs: ["0x12345678"], deleteAllOldMethods: true },
    "test.json"
  );
  assert.deepEqual(config, {
    diamond: DIAMOND,
    facets: ["PauseFacet"],
    deleteSelectorSigs: ["0x12345678"],
    deleteAllOldMethods: true,
  });
  assert.deepEqual(parseCutConfig({ diamond: DIAMOND }, "test.json"), { diamond: DIAMOND });
});

void test("rejects a cut file whose deleteAllOldMethods is not a boolean", () => {
  assert.throws(
    () => parseCutConfig({ diamond: DIAMOND, deleteAllOldMethods: "yes" }, "test.json"),
    /must be a boolean/
  );
  assert.throws(() => parseCutConfig({ facets: [] }, "test.json"), /diamond must be a string/);
});

void test("reads the Ethereum example cut through the loader", () => {
  const config = loadCutConfig("ethereum", "cut-example");
  assert.equal(config.diamond, DIAMOND);
  assert.equal(config.deleteAllOldMethods, false);
  assert.deepEqual(config.deleteSelectorSigs, []);
  assert.equal(config.facets?.length, 6);
});

void test("rejects a deployment record naming one contract twice", () => {
  const entry = { name: "PauseFacet", contractName: "PauseFacet.sol", address: DIAMOND };
  assert.deepEqual(parseDeployedContracts([entry], "deploys.json"), [entry]);
  assert.throws(
    () => parseDeployedContracts([entry, entry], "deploys.json"),
    /Duplicate deployed contract name PauseFacet/
  );
  assert.throws(() => parseDeployedContracts({}, "deploys.json"), /Invalid deployed contracts file/);
});

void test("finds the record's one controller and refuses an ambiguous record", () => {
  const controller = { name: "MasterAccountController", contractName: "MasterAccountController.sol", address: DIAMOND };
  const facet = {
    name: "PauseFacet",
    contractName: "PauseFacet.sol",
    address: "0x0000000000000000000000000000000000000001",
  };
  assert.equal(findDiamondAddress([facet, controller]), DIAMOND);
  assert.throws(() => findDiamondAddress([facet]), /Could not find MasterAccountController/);
  const twin = { name: "Controller2", contractName: "MasterAccountController.sol", address: facet.address };
  assert.throws(() => findDiamondAddress([controller, twin]), /Ambiguous deployment record/);
});
