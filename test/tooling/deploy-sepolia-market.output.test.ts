import { strict as assert } from "node:assert";
import { execFileSync, spawn, type ChildProcess } from "node:child_process";
import { copyFileSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, statSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";

/**
 * The market script's assets phase, run for real: `forge script` against a local chain answering
 * with Sepolia's id, broadcasting as an ordinary EOA. What no Solidity test can see from inside is
 * checked here - that the run prints the record lines at all, in the shape
 * `save-deployed-addresses.ts` parses out of its stdout - and what the deployment record would name
 * is read back from the chain: three contracts, each answering to the deploying EOA rather than to
 * the script contract that created them.
 *
 * The run writes nothing into the repository. A deployment's receipts are the evidence its recovery
 * procedure reads, so forge's broadcast and cache directories are pointed at a scratch directory
 * for the run (the compilation cache is copied in, so this compiles nothing it does not have to),
 * and only that directory is removed afterwards.
 *
 * Prerequisites are `anvil`, `forge`, and a Sepolia deployment record that is absent or empty - a
 * record naming assets would make the phase reuse them, and what it names is not on this chain.
 * Missing, they skip the tests, unless `REQUIRE_FORGE_TOOLING` is set, which is how the
 * Foundry-equipped CI job demands they run: that job clears the record in its own disposable
 * checkout first, so the live record a Sepolia deployment leaves behind never grounds the job. A
 * developer's checkout is not disposable, so nothing here touches a record it finds.
 */

const CHAIN_ID = 11155111;
// anvil's first account and its key: funded, and nobody's secret
const DEPLOYER = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";
const DEPLOYER_KEY = "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80";
const OWNER_SELECTOR = "0x8da5cb5b";
const RECORD_FILE = "deployment/deploys/sepolia.json";
const COMPILATION_CACHE = "cache/solidity-files-cache.json";
/// Everything the run could write into the repository if it were not redirected: the receipts the
/// recovery procedure reads, and forge's own copy of them.
const REPOSITORY_EVIDENCE = ["broadcast/DeploySepoliaMarket.s.sol", "cache/DeploySepoliaMarket.s.sol", RECORD_FILE];

/** The recorder's own line shape, mirrored from `save-deployed-addresses.ts`. */
const DEPLOYED_LINE = /^\s*DEPLOYED:\s*([^,]+),\s*([^:]+):\s*(0x[a-fA-F0-9]{40})$/;
const NETWORK_LINE = /^\s*NETWORK:\s*([a-zA-Z0-9_-]+)/;

let anvil: ChildProcess | undefined;
let scratch = "";
let rpcUrl = "";
let output = "";
let evidenceBefore = new Map<string, string>();

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
  if (existsSync(RECORD_FILE)) {
    return `${RECORD_FILE} exists, so the phase would reuse what it names; clear it in a disposable checkout`;
  }
  return undefined;
}

/** Every file under `_paths`, with what it holds: what the run must leave exactly as it found. */
function evidence(_paths: string[]): Map<string, string> {
  const found = new Map<string, string>();
  const walk = (path: string): void => {
    if (!existsSync(path)) return;
    if (statSync(path).isDirectory()) {
      for (const entry of readdirSync(path)) walk(join(path, entry));
      return;
    }
    found.set(path, readFileSync(path, "utf8"));
  };
  for (const path of _paths) walk(path);
  return found;
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

/** Waits for the chain this test started, and for no other: the child must still be running, the
 * endpoint must answer anvil's own `anvil_nodeInfo`, and the chain id must be Sepolia's. */
async function waitForOurChain(): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt++) {
    if (anvil?.exitCode !== null) {
      throw new Error(`anvil exited with ${String(anvil?.exitCode)} before it served anything`);
    }
    try {
      await rpc("anvil_nodeInfo", []);
      const id = await rpc("eth_chainId", []);
      assert.equal(Number(BigInt(id)), CHAIN_ID, "the local chain does not answer with Sepolia's id");
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
  evidenceBefore = evidence(REPOSITORY_EVIDENCE);
  scratch = mkdtempSync(join(tmpdir(), "sepolia-market-output-"));
  // forge rebuilds nothing it already has, as long as it can see the compilation cache
  if (existsSync(COMPILATION_CACHE)) copyFileSync(COMPILATION_CACHE, join(scratch, "solidity-files-cache.json"));
  const port = await freePort();
  rpcUrl = `http://127.0.0.1:${port}`;
  anvil = spawn("anvil", ["--chain-id", String(CHAIN_ID), "--port", String(port), "--silent"], {
    stdio: "ignore",
  });
  await waitForOurChain();
  output = execFileSync(
    "forge",
    [
      "script",
      "deployment/scripts/DeploySepoliaMarket.s.sol:DeploySepoliaMarket",
      "--rpc-url",
      rpcUrl,
      "--private-key",
      DEPLOYER_KEY,
      "--offline",
      "--sig",
      "run(string,string)",
      "sepolia",
      "assets",
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
});

void test("the assets phase prints the network and one record line per deployment", { skip }, () => {
  const lines = output.split("\n");
  const network = lines.map((line) => NETWORK_LINE.exec(line)).find((match) => match !== null);
  assert.equal(network?.[1], "sepolia", "the recorder reads the network from this line");
  const deployed = lines.map((line) => DEPLOYED_LINE.exec(line)).filter((match) => match !== null);
  assert.deepEqual(
    deployed.map((match) => [match[1], match[2]]),
    [
      ["TestnetLoanToken", "TestnetLoanToken.sol"],
      ["TestnetFeedCollateralUsd", "TestnetPriceFeed.sol"],
      ["TestnetFeedLoanUsd", "TestnetPriceFeed.sol"],
    ],
    "three lines, named as the record names them"
  );
});

void test("what the lines name is deployed and belongs to the deploying EOA", { skip }, async () => {
  const deployed = output
    .split("\n")
    .map((line) => DEPLOYED_LINE.exec(line))
    .filter((match) => match !== null);
  assert.equal(deployed.length, 3, "the phase deployed all three");
  for (const match of deployed) {
    const address = match[3] as string;
    const code = await rpc("eth_getCode", [address, "latest"]);
    assert.ok(code.length > 2, `${match[1] as string}: nothing at the address the line names`);
    const owner = await rpc("eth_call", [{ to: address, data: OWNER_SELECTOR }, "latest"]);
    assert.equal(
      `0x${owner.slice(-40)}`.toLowerCase(),
      DEPLOYER.toLowerCase(),
      `${match[1] as string}: owned by something other than the deploying EOA`
    );
  }
});

void test("the run leaves the repository's receipts, cache and record exactly as they were", { skip }, () => {
  // forge was pointed at the scratch directory for both, so a deployment's own evidence - the
  // receipts its recovery procedure reads, forge's copy of them, and the record - is untouched
  assert.ok(
    existsSync(join(scratch, "broadcast", "DeploySepoliaMarket.s.sol", String(CHAIN_ID))),
    "the receipts landed in the scratch directory"
  );
  assert.ok(
    existsSync(join(scratch, "DeploySepoliaMarket.s.sol", String(CHAIN_ID))),
    "and so did forge's own copy of them"
  );
  assert.deepEqual(
    [...evidence(REPOSITORY_EVIDENCE).entries()].sort(),
    [...evidenceBefore.entries()].sort(),
    "the repository's receipts, cache receipts and deployment record are as the run found them"
  );
});
