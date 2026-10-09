import { strict as assert } from "node:assert";
import { execFile, execFileSync, spawn, type ChildProcess } from "node:child_process";
import { copyFileSync, cpSync, existsSync, mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { test } from "node:test";
import { promisify } from "node:util";

/**
 * Runs the account/OFT round trip against two independent forks of an empty local chain. This
 * supplies the same-address accounts on separate chains without needing a public RPC. The Solidity
 * suite skips in an ordinary offline forge run; this runner requires every selected test to pass,
 * so the Foundry-equipped CI job cannot silently skip the integration evidence.
 *
 * The local node, artifacts and compilation cache belong to this run. Nothing is broadcast, and no
 * deployment record or repository artifact is written. Existing build outputs are copied to avoid
 * rebuilding unchanged contracts while keeping concurrent tooling runs isolated.
 */
const ROOT = resolve(__dirname, "../..");
const CHAIN_ID = 31337;
const SUITE = "test/integration/LoanOftRoundTrip.t.sol:LoanOftRoundTripTest";
const run = promisify(execFile);

function missingPrerequisite(): string | undefined {
  for (const tool of ["anvil", "forge"]) {
    try {
      execFileSync(tool, ["--version"], { stdio: "ignore" });
    } catch {
      return `${tool} is not installed or cannot run`;
    }
  }
  return undefined;
}

const missing = missingPrerequisite();
if (missing !== undefined && process.env.REQUIRE_FORGE_TOOLING !== undefined) {
  throw new Error(`REQUIRE_FORGE_TOOLING is set but ${missing}`);
}

async function freePort(): Promise<number> {
  return new Promise((resolvePort, reject) => {
    const probe = createServer();
    probe.once("error", reject);
    probe.listen(0, "127.0.0.1", () => {
      const address = probe.address();
      if (address === null || typeof address === "string") {
        probe.close();
        reject(new Error("the local port was not assigned"));
        return;
      }
      probe.close((error) => {
        if (error) reject(error);
        else resolvePort(address.port);
      });
    });
  });
}

async function rpc(url: string, method: string): Promise<unknown> {
  const response = await fetch(url, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ jsonrpc: "2.0", id: 1, method, params: [] }),
    signal: AbortSignal.timeout(1000),
  });
  assert.ok(response.ok, `local RPC returned HTTP ${String(response.status)}`);
  const body = (await response.json()) as { result?: unknown; error?: unknown };
  assert.equal(body.error, undefined, `${method} failed: ${JSON.stringify(body.error)}`);
  assert.notEqual(body.result, undefined, `${method} returned no result`);
  return body.result;
}

async function waitForChain(anvil: ChildProcess, url: string, spawnError: () => Error | undefined): Promise<void> {
  let lastError: unknown;
  for (let attempt = 0; attempt < 100; attempt++) {
    const error = spawnError();
    if (error) throw error;
    if (anvil.exitCode !== null || anvil.signalCode !== null) {
      throw new Error(`anvil exited with ${String(anvil.exitCode ?? anvil.signalCode)} before it served anything`);
    }
    try {
      await rpc(url, "anvil_nodeInfo");
      assert.equal(await rpc(url, "eth_chainId"), `0x${CHAIN_ID.toString(16)}`, "wrong local chain id");
      // A foreign process answering on the released port cannot conceal our child's bind failure.
      assert.equal(anvil.exitCode, null, "our anvil exited during readiness checks");
      assert.equal(anvil.signalCode, null, "our anvil was killed during readiness checks");
      return;
    } catch (caught) {
      lastError = caught;
    }
    await new Promise((resolveDelay) => setTimeout(resolveDelay, 100));
  }
  throw new Error("anvil did not start a usable local chain", { cause: lastError });
}

async function stop(anvil: ChildProcess): Promise<void> {
  if (anvil.pid === undefined || anvil.exitCode !== null || anvil.signalCode !== null) return;
  await new Promise<void>((resolveStopped) => {
    const kill = setTimeout(() => anvil.kill("SIGKILL"), 2000);
    anvil.once("close", () => {
      clearTimeout(kill);
      resolveStopped();
    });
    anvil.kill();
  });
}

void test(
  "the loan account OFT round trip runs on independent local chains without skipped cases",
  { skip: missing },
  async () => {
    const scratch = mkdtempSync(join(tmpdir(), "loan-oft-roundtrip-"));
    let anvil: ChildProcess | undefined;
    try {
      const artifacts = join(scratch, "artifacts");
      if (existsSync(join(ROOT, "artifacts"))) cpSync(join(ROOT, "artifacts"), artifacts, { recursive: true });
      const cache = join(scratch, "cache");
      mkdirSync(cache);
      const compilationCache = join(ROOT, "cache", "solidity-files-cache.json");
      if (existsSync(compilationCache)) copyFileSync(compilationCache, join(cache, "solidity-files-cache.json"));

      const port = await freePort();
      const url = `http://127.0.0.1:${String(port)}`;
      let spawnError: Error | undefined;
      anvil = spawn(
        "anvil",
        ["--host", "127.0.0.1", "--chain-id", String(CHAIN_ID), "--port", String(port), "--silent"],
        {
          cwd: ROOT,
          stdio: "ignore",
        }
      );
      anvil.once("error", (error) => {
        spawnError = error;
      });
      await waitForChain(anvil, url, () => spawnError);

      const { stdout } = await run(
        "forge",
        ["test", "--offline", "--match-contract", "^LoanOftRoundTripTest$", "--json"],
        {
          cwd: ROOT,
          encoding: "utf8",
          timeout: 180_000,
          maxBuffer: 16 * 1024 * 1024,
          env: {
            ...process.env,
            FOUNDRY_PROFILE: "default",
            FOUNDRY_OUT: artifacts,
            FOUNDRY_CACHE_PATH: cache,
            FOUNDRY_BROADCAST: join(scratch, "broadcast"),
            F28_LOCAL_RPC_URL: url,
            REQUIRE_LOAN_OFT_ROUNDTRIP: "1",
            FOUNDRY_DISABLE_NIGHTLY_WARNING: "1",
          },
        }
      );
      const results = JSON.parse(stdout) as Record<
        string,
        { test_results: Record<string, { status: string; reason: unknown }> }
      >;
      assert.deepEqual(Object.keys(results), [SUITE], "forge must execute the round-trip suite");
      const tests = Object.entries(results[SUITE]?.test_results ?? {});
      assert.ok(tests.length > 0, "the selected suite must contain tests");
      for (const [name, result] of tests) {
        assert.equal(result.status, "Success", `${name}: ${result.status}, ${JSON.stringify(result.reason)}`);
      }
    } finally {
      if (anvil !== undefined) await stop(anvil);
      rmSync(scratch, { recursive: true, force: true });
    }
  }
);
