/**
 * The recorder itself, run as the deploy wrappers run it.
 *
 * `deploy-records.test.ts` covers the merge rule in isolation; this covers the wiring, which is
 * the part that would go quiet if the guard were ever dropped from the script. Each case spawns
 * the real script in a temporary working directory, because it reads `forge-deploy-output.txt`
 * and writes `deployment/deploys/<network>.json` relative to the cwd.
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

const here = __dirname;
const repoRoot = path.resolve(here, "../..");
const SCRIPT = path.join(here, "save-deployed-addresses.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");

const CONTROLLER_A = "0xaaaabbbbccccddddeeeeffff1111222233334444";
const CONTROLLER_B = "0x5555666677778888999900001111222233334444";
const FACET = "0x1234123412341234123412341234123412341234";
/** `PinnedControllerInitCode.MASTER_ACCOUNT_CONTROLLER`: the one address that name may hold on Ethereum. */
const PINNED_CONTROLLER = "0x434936d47503353f06750Db1A444DBDC5F0AD37c";

type DeployRecord = { name: string; contractName: string; address: string };

function setUp(network: string, existing: DeployRecord[], deployed: DeployRecord[]): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "recorder-"));
  fs.mkdirSync(path.join(dir, "deployment/deploys"), { recursive: true });
  if (existing.length > 0) {
    fs.writeFileSync(path.join(dir, `deployment/deploys/${network}.json`), JSON.stringify(existing, null, 2));
  }
  const lines = [`NETWORK: ${network}`, ...deployed.map((r) => `DEPLOYED: ${r.name}, ${r.contractName}: ${r.address}`)];
  fs.writeFileSync(path.join(dir, "forge-deploy-output.txt"), `${lines.join("\n")}\n`);
  return dir;
}

function run(cwd: string, allow?: string, mock = false): { status: number | null; stderr: string } {
  const childEnv: Record<string, string | undefined> = { ...process.env };
  if (allow !== undefined) {
    childEnv.ALLOW_RECORD_REPLACEMENT = allow;
  } else {
    delete childEnv.ALLOW_RECORD_REPLACEMENT;
  }
  const args = mock ? [TSX_CLI, SCRIPT, "mock"] : [TSX_CLI, SCRIPT];
  const result = spawnSync(process.execPath, args, { cwd, env: childEnv, encoding: "utf8" });
  return { status: result.status, stderr: `${result.stderr}${result.stdout}` };
}

function readRecords(dir: string, file: string): DeployRecord[] {
  const raw: unknown = JSON.parse(fs.readFileSync(path.join(dir, `deployment/deploys/${file}.json`), "utf8"));
  return raw as DeployRecord[];
}

const controller = (address: string): DeployRecord => ({
  name: "MasterAccountController",
  contractName: "MasterAccountController.sol",
  address,
});
const pauseFacet: DeployRecord = { name: "PauseFacet", contractName: "PauseFacet.sol", address: FACET };

void test("a refused replacement writes nothing, and the retry the error names actually works", () => {
  // the ALLOWED record comes first in the batch deliberately: a recorder that wrote each entry as
  // it merged would land the facet before reaching the controller it must refuse, and a test that
  // put the refused one first could not tell the difference
  const dir = setUp("coston2", [controller(CONTROLLER_A)], [pauseFacet, controller(CONTROLLER_B)]);
  const { status, stderr } = run(dir);

  assert.notEqual(status, 0, "the recorder should have failed");
  assert.match(stderr, /MasterAccountController: refusing to replace the recorded address/);
  assert.match(stderr, /rerun the recorder alone with the override/);

  const after = readRecords(dir, "coston2");
  assert.equal(after.length, 1, "the batch was partially applied");
  assert.equal(after[0]?.name, "MasterAccountController");
  assert.equal(after[0]?.address, CONTROLLER_A);

  // and the retry the message advertises: same directory, no redeployment, just the override.
  // Asserting the output file merely exists would pass against a truncated one
  const retry = run(dir, "MasterAccountController");
  assert.equal(retry.status, 0, retry.stderr);
  const retried = readRecords(dir, "coston2");
  assert.equal(retried.find((r) => r.name === "MasterAccountController")?.address, CONTROLLER_B);
  assert.equal(retried.find((r) => r.name === "PauseFacet")?.address, FACET);
});

void test("the override lets the named replacement through, and consumes the forge output", () => {
  const dir = setUp("coston2", [controller(CONTROLLER_A)], [controller(CONTROLLER_B), pauseFacet]);
  const { status, stderr } = run(dir, "MasterAccountController");

  assert.equal(status, 0, stderr);
  const after = readRecords(dir, "coston2");
  assert.equal(after.find((r) => r.name === "MasterAccountController")?.address, CONTROLLER_B);
  assert.equal(after.find((r) => r.name === "PauseFacet")?.address, FACET);
  assert.ok(!fs.existsSync(path.join(dir, "forge-deploy-output.txt")), "a successful run should consume its input");
});

void test("an implementation upgrade records with no override at all", () => {
  // the ordinary upgrade path: `deploy_personal_account_implementation` records under this name
  // every time it runs, so needing a flag here would put the flag in everyone's environment
  const impl = (address: string): DeployRecord => ({
    name: "PersonalAccountImplementation",
    contractName: "PersonalAccount.sol",
    address,
  });
  const dir = setUp("flare", [impl(CONTROLLER_A)], [impl(CONTROLLER_B)]);
  const { status, stderr } = run(dir);

  assert.equal(status, 0, stderr);
  assert.equal(readRecords(dir, "flare")[0]?.address, CONTROLLER_B);
});

void test("the mock files are exempt, and a network the tooling does not know is not recorded at all", () => {
  // the mock records are gitignored rather than tracked and describe no live deployment. A name
  // outside both families - a local chain, say - has no record here: the recorder refuses it
  // before the guard question arises, while the sepolia record is written like any other
  const unknown = setUp("scdev", [controller(CONTROLLER_A)], [controller(CONTROLLER_B)]);
  const unknownRun = run(unknown);
  assert.notEqual(unknownRun.status, 0, "an unknown network must not be recorded");
  assert.match(unknownRun.stderr, /Invalid network: scdev/);
  assert.equal(readRecords(unknown, "scdev")[0]?.address, CONTROLLER_A);
  const sepolia = setUp("sepolia", [], [pauseFacet]);
  const sepoliaRun = run(sepolia);
  assert.equal(sepoliaRun.status, 0, sepoliaRun.stderr);
  assert.equal(readRecords(sepolia, "sepolia")[0]?.address, FACET);

  const mocked = setUp("coston2", [], [controller(CONTROLLER_B)]);
  fs.writeFileSync(
    path.join(mocked, "deployment/deploys/coston2_mock.json"),
    JSON.stringify([controller(CONTROLLER_A)], null, 2)
  );
  const mockRun = run(mocked, undefined, true);
  assert.equal(mockRun.status, 0, mockRun.stderr);
  assert.equal(readRecords(mocked, "coston2_mock")[0]?.address, CONTROLLER_B);
});

void test("the Ethereum pins hold even when the override names the controller", () => {
  // the two guards compose: an override for the replacement rule must not buy a way past the
  // pinned-Ethereum rule, which allows only one address for that name on that chain.
  //
  // The existing record starts at the PINNED address on purpose. With a non-canonical one there,
  // a recorder that checked the stored record instead of the incoming one would refuse for the
  // wrong reason and this test could not tell
  const dir = setUp("ethereum", [controller(PINNED_CONTROLLER)], [controller(CONTROLLER_B)]);
  fs.mkdirSync(path.join(dir, "deployment/scripts"), { recursive: true });
  fs.copyFileSync(
    path.join(repoRoot, "deployment/scripts/PinnedControllerInitCode.sol"),
    path.join(dir, "deployment/scripts/PinnedControllerInitCode.sol")
  );

  const { status, stderr } = run(dir, "MasterAccountController");
  assert.notEqual(status, 0, "the pinned Ethereum record must not be writable");
  assert.match(stderr, /only the canonical pinned Ethereum record/);
  assert.equal(readRecords(dir, "ethereum")[0]?.address, PINNED_CONTROLLER);
});
