/**
 * The facet-address updater, run as the cut executor runs it: a directly executable utility, so
 * it enforces its own invariants rather than trusting the caller. The one that matters here is
 * the pinned rule — on a loan chain the four pinned names may only ever hold their pinned
 * addresses — which applies to Sepolia exactly as to Ethereum, since the bootstrap reproduces
 * the same four addresses there.
 */
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { PROTECTED_ETHEREUM_NAMES, loadPinnedEthereumAddresses } from "../../deployment/utils/pinned-constants";

const repoRoot = path.resolve(__dirname, "../..");
const deploymentDir = path.join(repoRoot, "deployment");
const SCRIPT = path.join(deploymentDir, "utils/update-facet-address.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");
const STRANGER = "0x00000000000000000000000000000000deadbeef";
const ORDINARY = "0x1234123412341234123412341234123412341234";

const pins = loadPinnedEthereumAddresses();
const PINNED_FACET = [...pins.baseFacets.entries()][0]!;
/** Each protected name with the one address it may hold: the controller and its three base facets. */
const PROTECTED = PROTECTED_ETHEREUM_NAMES.map((name) => ({
  name,
  address: name === "MasterAccountController" ? pins.controllerAddress : pins.baseFacets.get(name)!.address,
}));

/** A working directory holding one record file and the pinned source the utility parses. */
function scratch(fileName: string): { dir: string; file: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "update-facet-address-"));
  fs.mkdirSync(path.join(dir, "deployment/deploys"), { recursive: true });
  fs.mkdirSync(path.join(dir, "deployment/scripts"), { recursive: true });
  fs.copyFileSync(
    path.join(deploymentDir, "scripts/PinnedControllerInitCode.sol"),
    path.join(dir, "deployment/scripts/PinnedControllerInitCode.sol")
  );
  const file = path.join(dir, `deployment/deploys/${fileName}`);
  fs.writeFileSync(file, JSON.stringify([{ name: "PauseFacet", contractName: "PauseFacet.sol", address: ORDINARY }]));
  return { dir, file };
}

function run(dir: string, file: string, name: string, address: string): { status: number | null; output: string } {
  const result = spawnSync(process.execPath, [TSX_CLI, SCRIPT, file, name, address], {
    cwd: dir,
    encoding: "utf8",
  });
  return { status: result.status, output: `${result.stdout}${result.stderr}` };
}

function addressOf(file: string, name: string): string | undefined {
  const raw = JSON.parse(fs.readFileSync(file, "utf8")) as { name: string; address: string }[];
  return raw.find((item) => item.name === name)?.address;
}

void test("every protected name may not be written elsewhere, on either loan chain", () => {
  // the four are protected as a set - the controller and its three base facets - so each is
  // driven here: exempting any one of them would let that record be pointed somewhere else
  for (const network of ["ethereum", "sepolia"]) {
    for (const protectedName of PROTECTED) {
      const { dir, file } = scratch(`${network}.json`);
      const { status, output } = run(dir, file, protectedName.name, STRANGER);
      assert.notEqual(status, 0, `${network}/${protectedName.name}: the pinned record must not be writable`);
      assert.match(output, /only the canonical pinned Ethereum record/);
      assert.equal(addressOf(file, protectedName.name), undefined, `${network}/${protectedName.name}: nothing written`);
      fs.rmSync(dir, { recursive: true, force: true });
    }
  }
});

void test("a pinned name at its pinned address is written, and ordinary facets are unaffected", () => {
  const { dir, file } = scratch("sepolia.json");
  const pinned = run(dir, file, PINNED_FACET[0], PINNED_FACET[1].address);
  assert.equal(pinned.status, 0, pinned.output);
  assert.equal(addressOf(file, PINNED_FACET[0])?.toLowerCase(), PINNED_FACET[1].address);
  // an ordinary facet has no pin to satisfy: it follows its redeployment freely
  const ordinary = run(dir, file, "PauseFacet", STRANGER);
  assert.equal(ordinary.status, 0, ordinary.output);
  assert.equal(addressOf(file, "PauseFacet"), STRANGER);
  fs.rmSync(dir, { recursive: true, force: true });
});

void test("a Flare-family record is not held to the pins", () => {
  // the pinned bootstrap runs on the loan chains only; a Flare network's facets are deployed from
  // source and their records follow every redeployment
  const { dir, file } = scratch("coston2.json");
  const { status, output } = run(dir, file, PINNED_FACET[0], STRANGER);
  assert.equal(status, 0, output);
  assert.equal(addressOf(file, PINNED_FACET[0]), STRANGER);
  fs.rmSync(dir, { recursive: true, force: true });
});
