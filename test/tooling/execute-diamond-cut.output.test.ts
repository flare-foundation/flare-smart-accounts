import { strict as assert } from "node:assert";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import {
  copyFileSync,
  existsSync,
  mkdtempSync,
  readFileSync,
  readdirSync,
  rmSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

/**
 * The cut executor, run for real: `forge script` against a local chain, preparing a cut from a
 * fixture that deploys one facet and an initializer.
 *
 * What no Solidity test can see from inside is checked here. The executor hands the recorder its
 * deployments by PRINTING a line per deployment, and forge swallows console output before any
 * cheatcode can observe it, so the wrapper scenarios can only stub that output - they would stay
 * green with the printing removed and the deployments going unrecorded. This runs the script
 * itself and reads its stdout, covering both sites that print: the facet loop and the initializer
 * resolution, which is why the fixture names a facet AND an initializer that is not one of them.
 *
 * It pins the other half of the same rule too: the executor writes no deployment record. It used
 * to write one from inside the script, which outlived the simulation that computed it - so the
 * record file is compared before and after a run that really did deploy.
 *
 * The run writes nothing into the repository. Forge's broadcast and cache directories are pointed
 * at a scratch directory (the compilation cache is copied in, so this compiles nothing it does not
 * have to), and the prepared cut's own outputs, which are gitignored working files named after the
 * fixture, are removed afterwards.
 *
 * Prerequisites are `anvil` and `forge`. Missing, they skip the tests, unless
 * `REQUIRE_FORGE_TOOLING` is set, which is how the Foundry-equipped CI job demands they run.
 */

/** Coston2: the fixture lives in its cut directory, so the chain must answer with its id. */
const CHAIN_ID = 114;
const NETWORK = "coston2";
const CUT_NAME = "records-what-it-deploys";
// anvil's first account and its key: funded, and nobody's secret
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
/** The fixture's diamond. Nothing is cut into it; it only has to answer the loupe. */
const DIAMOND = "0x00000000000000000000000000000000DeaDBeef";
/**
 * Runtime that returns an empty `Facet[]` to every call: the ABI head (offset 0x20) then a zero
 * length. The executor reads the diamond's current facets to build the cut, and an empty answer
 * makes every entry an addition - which is all this test needs the diamond for.
 */
const EMPTY_FACETS_RUNTIME = "0x6020600052600060205260406000f3";
const RECORD_FILE = `deployment/deploys/${NETWORK}.json`;
const COMPILATION_CACHE = "cache/solidity-files-cache.json";
/**
 * The receipts of real cuts on this network, which a recovery reads: what the run must leave
 * exactly as it found, along with forge's own copy of them.
 */
const REPOSITORY_EVIDENCE = ["broadcast/ExecuteDiamondCut.s.sol", "cache/ExecuteDiamondCut.s.sol", RECORD_FILE];
/** The prepared cut's own outputs, named after the fixture so no real cut's outputs are touched. */
const CUT_OUTPUTS = [
  `deployment/output-internal/${NETWORK}/facets-${CUT_NAME}.txt`,
  `deployment/output-internal/${NETWORK}/loupe-${CUT_NAME}.txt`,
  `deployment/output-internal/${NETWORK}/diamond-cut-encoded-${CUT_NAME}.bin`,
  `deployment/output-internal/${NETWORK}/decoded-${CUT_NAME}.json`,
];

/** The recorder's own line shape, mirrored from `save-deployed-addresses.ts`. */
const DEPLOYED_LINE = /^\s*DEPLOYED:\s*([^,]+),\s*([^:]+):\s*(0x[a-fA-F0-9]{40})$/;
const NETWORK_LINE = /^\s*NETWORK:\s*([a-zA-Z0-9_-]+)/;

let anvil: ChildProcess | undefined;
let scratch = "";
let rpcUrl = "";
let output = "";
let recordBefore = "";
let evidenceBefore = new Map<string, string>();

/** Every file under `paths`, with what it holds. */
function evidence(paths: string[]): Map<string, string> {
  const found = new Map<string, string>();
  const walk = (path: string): void => {
    if (!existsSync(path)) return;
    if (statSync(path).isDirectory()) {
      for (const entry of readdirSync(path)) walk(join(path, entry));
      return;
    }
    found.set(path, readFileSync(path, "utf8"));
  };
  for (const path of paths) walk(path);
  return found;
}

function available(tool: string): boolean {
  try {
    execFileSync("which", [tool], { stdio: "pipe" });
    return true;
  } catch {
    return false;
  }
}

function missingPrerequisite(): string | undefined {
  if (!available("anvil")) return "anvil is not installed";
  if (!available("forge")) return "forge is not installed";
  return undefined;
}

const missing = missingPrerequisite();
const required = process.env.REQUIRE_FORGE_TOOLING !== undefined;
if (missing !== undefined && required) {
  throw new Error(`REQUIRE_FORGE_TOOLING is set but ${missing}`);
}
const skip = missing;

/** A port the kernel just handed out, so two runs on one machine cannot collide. */
async function freePort(): Promise<number> {
  return new Promise((resolve, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      if (address === null || typeof address === "string") {
        reject(new Error("no port"));
        return;
      }
      const { port } = address;
      probe.close(() => resolve(port));
    });
  });
}

async function rpc(method: string, params: unknown[]): Promise<string> {
  const response = await fetch(rpcUrl, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params }),
  });
  const body = (await response.json()) as { result?: unknown; error?: { message: string } };
  if (body.error) throw new Error(`${method}: ${body.error.message}`);
  return typeof body.result === "string" ? body.result : JSON.stringify(body.result);
}

/** Waits for the chain this test started, and for no other. */
async function waitForOurChain(): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (anvil?.exitCode !== null) {
      throw new Error(`anvil exited with ${String(anvil?.exitCode)} before it served anything`);
    }
    try {
      await rpc("anvil_nodeInfo", []);
      const id = await rpc("eth_chainId", []);
      assert.equal(Number(BigInt(id)), CHAIN_ID, "the local chain does not answer with Coston2's id");
      return;
    } catch {
      // not listening yet
    }
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("anvil did not come up");
}

before(async () => {
  if (skip !== undefined) return;
  recordBefore = existsSync(RECORD_FILE) ? readFileSync(RECORD_FILE, "utf8") : "";
  evidenceBefore = evidence(REPOSITORY_EVIDENCE);
  scratch = mkdtempSync(join(tmpdir(), "execute-cut-output-"));
  // forge rebuilds nothing it already has, as long as it can see the compilation cache
  if (existsSync(COMPILATION_CACHE)) copyFileSync(COMPILATION_CACHE, join(scratch, "solidity-files-cache.json"));
  const port = await freePort();
  rpcUrl = `http://127.0.0.1:${port}`;
  anvil = spawn("anvil", ["--chain-id", String(CHAIN_ID), "--port", String(port), "--silent"], {
    stdio: "ignore",
  });
  await waitForOurChain();
  await rpc("anvil_setCode", [DIAMOND, EMPTY_FACETS_RUNTIME]);
  output = execFileSync(
    "forge",
    [
      "script",
      "deployment/scripts/ExecuteDiamondCut.s.sol:ExecuteDiamondCut",
      "--rpc-url",
      rpcUrl,
      "--private-key",
      DEPLOYER_KEY,
      "--offline",
      "--sig",
      "run(string,string,bool)",
      NETWORK,
      CUT_NAME,
      "false",
      "--broadcast",
    ],
    {
      encoding: "utf8",
      env: {
        ...process.env,
        DEPLOYER_PRIVATE_KEY: DEPLOYER_KEY,
        FOUNDRY_BROADCAST: join(scratch, "broadcast"),
        FOUNDRY_CACHE_PATH: scratch,
      },
    }
  );
});

after(() => {
  anvil?.kill();
  if (scratch !== "") rmSync(scratch, { recursive: true, force: true });
  for (const path of CUT_OUTPUTS) {
    if (existsSync(path)) unlinkSync(path);
  }
});

void test("the run prints the network and a record line for the facet and the initializer", { skip }, () => {
  const lines = output.split("\n");
  const network = lines.map((line) => NETWORK_LINE.exec(line)).find((match) => match !== null);
  assert.equal(network?.[1], NETWORK, "the recorder reads the network from this line");
  const deployed = lines.map((line) => DEPLOYED_LINE.exec(line)).filter((match) => match !== null);
  assert.deepEqual(
    deployed.map((match) => [match[1], match[2]]),
    [
      ["PauseFacet", "PauseFacet.sol"],
      ["MasterAccountControllerInit", "MasterAccountControllerInit.sol"],
    ],
    "one line from the facet loop and one from the initializer resolution, named as the record names them"
  );
});

void test("what the lines name really is deployed on the chain", { skip }, async () => {
  const deployed = output
    .split("\n")
    .map((line) => DEPLOYED_LINE.exec(line))
    .filter((match) => match !== null);
  assert.equal(deployed.length, 2, "the run deployed both");
  for (const match of deployed) {
    const code = await rpc("eth_getCode", [match[3] as string, "latest"]);
    assert.ok(code.length > 2, `${match[1] as string}: nothing at the address the line names`);
  }
});

void test("the run deployed, and still wrote no deployment record", { skip }, () => {
  // the defect this replaced: the executor wrote the record from inside the script, over FFI, as
  // each facet was deployed - a write that outlived the simulation that computed its addresses.
  // The two deployments above are what makes this an assertion rather than a tautology
  const recordAfter = existsSync(RECORD_FILE) ? readFileSync(RECORD_FILE, "utf8") : "";
  assert.equal(recordAfter, recordBefore, `${RECORD_FILE} was written by the run itself`);
});

void test("the run leaves the repository's own receipts as it found them", { skip }, () => {
  // a real cut's receipts are the evidence its recovery procedure reads, and this network has
  // some: forge was pointed at the scratch directory so the run cannot add to or disturb them
  assert.ok(
    existsSync(join(scratch, "broadcast", "ExecuteDiamondCut.s.sol", String(CHAIN_ID))),
    "the receipts landed in the scratch directory"
  );
  assert.deepEqual(
    [...evidence(REPOSITORY_EVIDENCE).entries()].sort(),
    [...evidenceBefore.entries()].sort(),
    "the repository's own receipts and cache receipts are as the run found them"
  );
});
