/**
 * The explorer submission, run as an operator runs it: the real script in a scratch working
 * directory, `forge` replaced by a stub that records the time of each call and every argument it
 * received, the RPC a fake server answering `eth_chainId`. What is pinned: the RPC URL reaches forge
 * as one argument whatever characters it carries, the chain the RPC answers is checked before any
 * submission, the complete argument vector of every submission on every supported network including
 * the staging aliases, and the spacing between submissions with the validation of its override.
 */
import assert from "node:assert/strict";
import { spawn, type ChildProcess, type ChildProcessWithoutNullStreams } from "node:child_process";
import { createServer, type Server } from "node:http";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";
import { pathToFileURL } from "node:url";

const repoRoot = path.resolve(__dirname, "../..");
const SCRIPT = path.join(repoRoot, "deployment/scripts/verify-contracts.ts");
// Node runs the TypeScript itself through tsx's import hook rather than through the tsx CLI, which
// launches a second process: killing the launcher would leave that one alive to finish its wait and
// submit again after the test ended. Resolved to an absolute URL because a run's working directory
// is a scratch directory with no node_modules to resolve the bare specifier against.
const TSX_HOOK = pathToFileURL(createRequire(__filename).resolve("tsx")).href;
const FACET = "0x1234123412341234123412341234123412341234";
const SOURCE = "contracts/smartAccounts/facets/PauseFacet.sol";

/** The chain id each network's RPC must answer, as the fake server reports it. */
const CHAIN_ID_HEX: Record<string, string> = {
  coston2: "0x72",
  "coston2-staging": "0x72",
  coston: "0x10",
  "coston-staging": "0x10",
  flare: "0xe",
  songbird: "0x13",
  ethereum: "0x1",
  sepolia: "0xaa36a7",
};

const blockscout = (host: string) => ["--verifier", "blockscout", "--verifier-url", `https://${host}/api/`];
const etherscan = (chain: string, key: string) => ["--chain", chain, "--etherscan-api-key", key];
const SOURCIFY = ["--verifier", "sourcify"];

/** The whole vector one submission must produce, so a missing or reordered argument fails. */
function submission(rpcUrl: string, explorerArgs: string[]): string[] {
  return [
    "verify-contract",
    FACET,
    `${SOURCE}:PauseFacet`,
    "--rpc-url",
    rpcUrl,
    ...explorerArgs,
    "--skip-is-verified-check",
    "--watch",
  ];
}

interface RpcRequest {
  id: number;
  method: string;
}

/** Answers `eth_chainId` with one fixed chain; every other method gets null. */
class FakeRpc {
  private server: Server | undefined;

  constructor(private readonly chainId: string) {}

  async start(): Promise<string> {
    this.server = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk: Buffer) => {
        body += chunk.toString();
      });
      req.on("end", () => {
        const request = JSON.parse(body) as RpcRequest | RpcRequest[];
        const answer = (one: RpcRequest) => ({
          jsonrpc: "2.0",
          id: one.id,
          result: one.method === "eth_chainId" ? this.chainId : null,
        });
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(Array.isArray(request) ? request.map(answer) : answer(request)));
      });
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const address = this.server.address();
    if (address === null || typeof address === "string") {
      throw new Error("the fake RPC did not bind a port");
    }
    return `http://127.0.0.1:${address.port}`;
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }
}

/**
 * A working directory holding one recorded facet with its source file, and the forge stub. The stub
 * is node rather than shell so it can stamp each call with a millisecond clock: the spacing tests
 * compare submission times, which total runtime cannot distinguish from a wait in the wrong place.
 * A call carrying the argument named in FORGE_FAIL_WHEN exits non-zero, so a failure can be staged.
 */
function scratch(network: string): { dir: string; log: string } {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "verify-contracts-"));
  fs.mkdirSync(path.join(dir, "bin"));
  fs.mkdirSync(path.join(dir, "deployment/deploys"), { recursive: true });
  fs.mkdirSync(path.dirname(path.join(dir, SOURCE)), { recursive: true });
  fs.writeFileSync(path.join(dir, SOURCE), "");
  fs.writeFileSync(
    path.join(dir, `deployment/deploys/${network}.json`),
    JSON.stringify([{ name: "PauseFacet", contractName: "PauseFacet.sol", address: FACET }])
  );
  const log = path.join(dir, "forge.log");
  fs.writeFileSync(
    path.join(dir, "bin/forge"),
    [
      "#!/usr/bin/env node",
      'const fs = require("node:fs");',
      "const argv = process.argv.slice(2);",
      `fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ at: Date.now(), argv }) + "\\n");`,
      "const fail = process.env.FORGE_FAIL_WHEN;",
      "process.exit(fail && argv.includes(fail) ? 3 : 0);",
      "",
    ].join("\n"),
    { mode: 0o755 }
  );
  return { dir, log };
}

/** The environment a run gets: the ambient one, spacing off unless the case is about it. */
function childEnvironment(dir: string, env: Record<string, string>): NodeJS.ProcessEnv {
  const childEnv: NodeJS.ProcessEnv = { ...process.env, VERIFY_SUBMIT_DELAY_MS: "0", ...env };
  if (!("ETHERSCAN_API_KEY" in env)) {
    delete childEnv.ETHERSCAN_API_KEY;
  }
  childEnv.PATH = `${path.join(dir, "bin")}:${process.env.PATH ?? ""}`;
  return childEnv;
}

/** One process, so that killing it kills the run: see TSX_HOOK. */
const scriptArgv = (network: string) => ["--import", TSX_HOOK, SCRIPT, network];

/** The run whose output a case reads. */
function spawnScript(dir: string, network: string, env: Record<string, string>): ChildProcessWithoutNullStreams {
  return spawn(process.execPath, scriptArgv(network), { cwd: dir, env: childEnvironment(dir, env) });
}

/** The run a case only times, so its output goes nowhere and cannot fill a pipe while it waits. */
function spawnScriptQuietly(dir: string, network: string, env: Record<string, string>): ChildProcess {
  return spawn(process.execPath, scriptArgv(network), {
    cwd: dir,
    env: childEnvironment(dir, env),
    stdio: "ignore",
  });
}

/**
 * Runs the script as a child process, asynchronously: the fake RPC lives in this process, so a
 * synchronous spawn would block the event loop the server needs to answer the child.
 */
function run(
  dir: string,
  network: string,
  env: Record<string, string>
): Promise<{ status: number | null; output: string }> {
  return new Promise((resolve, reject) => {
    const child = spawnScript(dir, network, env);
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, output }));
  });
}

const sleep = (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Starts a run, waits for its first submission, then watches for `windowMs` and kills the child,
 * answering how many submissions landed in that window. For the default spacing, which is twenty
 * seconds: waiting it out would make the suite unusable, and the announcement cannot be observed
 * either, since the wait blocks the child's event loop before the line reaches the pipe. What a
 * disabled wait looks like is the second submission arriving immediately after the first.
 */
async function submissionsWithin(
  dir: string,
  network: string,
  env: Record<string, string>,
  log: string,
  windowMs: number
): Promise<number> {
  const child = spawnScriptQuietly(dir, network, env);
  const ended = new Promise<void>((resolve) => child.on("close", () => resolve()));
  try {
    const deadline = Date.now() + 30_000;
    while (calls(log).length === 0) {
      if (Date.now() > deadline || child.exitCode !== null) {
        throw new Error("the run made no submission at all");
      }
      await sleep(25);
    }
    await sleep(windowMs);
    return calls(log).length;
  } finally {
    // awaited, so the count is read from a run that is over rather than one still mid-wait: a
    // survivor would submit again, into a suite that had stopped looking
    child.kill("SIGKILL");
    await ended;
  }
}

/** The stub's calls in order, each with the time it ran and the argument vector it received. */
function calls(log: string): { at: number; argv: string[] }[] {
  if (!fs.existsSync(log)) {
    return [];
  }
  return fs
    .readFileSync(log, "utf8")
    .split("\n")
    .filter((line) => line.length > 0)
    .map((line) => JSON.parse(line) as { at: number; argv: string[] });
}

const vectors = (log: string): string[][] => calls(log).map((call) => call.argv);

/** How many times the script announced a wait; one per gap between submissions. */
const waits = (output: string): number => output.split("before the next submission").length - 1;

void test("the RPC URL reaches forge as one argument, query string and all", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["coston2"]!);
  const base = await rpc.start();
  try {
    // an RPC URL with a key in its query string is the common case, and `&` is what a shell would
    // read as the end of the command
    const url = `${base}/?key=abc&trace=1`;
    const { dir, log } = scratch("coston2");
    const { status, output } = await run(dir, "coston2", { COSTON2_RPC_URL: url });
    assert.equal(status, 0, output);
    assert.deepEqual(vectors(log), [
      submission(url, blockscout("coston2-explorer.flare.network")),
      submission(url, SOURCIFY),
    ]);
  } finally {
    await rpc.stop();
  }
});

void test("an RPC answering another chain stops the run before any submission", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["coston"]!);
  const base = await rpc.start();
  try {
    const { dir, log } = scratch("coston2");
    const { status, output } = await run(dir, "coston2", { COSTON2_RPC_URL: base });
    assert.notEqual(status, 0, "the chain check must fail the run");
    assert.match(output, /RPC for coston2 answers chain id 16, expected 114/);
    assert.deepEqual(calls(log), []);
  } finally {
    await rpc.stop();
  }
});

void test("every network submits to exactly its verifiers, staging aliases included", async () => {
  // Sourcify carries every chain here except Coston (16), and the exclusion is keyed on the base
  // network, so the staging aliases must follow their base rather than their own name.
  const cases: { network: string; explorers: string[][] }[] = [
    { network: "coston2", explorers: [blockscout("coston2-explorer.flare.network"), SOURCIFY] },
    { network: "coston2-staging", explorers: [blockscout("coston2-explorer.flare.network"), SOURCIFY] },
    { network: "coston", explorers: [blockscout("coston-explorer.flare.network")] },
    { network: "coston-staging", explorers: [blockscout("coston-explorer.flare.network")] },
    { network: "flare", explorers: [blockscout("flare-explorer.flare.network"), SOURCIFY] },
    { network: "songbird", explorers: [blockscout("songbird-explorer.flare.network"), SOURCIFY] },
    { network: "ethereum", explorers: [blockscout("eth.blockscout.com"), SOURCIFY] },
    { network: "sepolia", explorers: [blockscout("eth-sepolia.blockscout.com"), SOURCIFY] },
  ];
  for (const { network, explorers } of cases) {
    const rpc = new FakeRpc(CHAIN_ID_HEX[network]!);
    const base = await rpc.start();
    try {
      const { dir, log } = scratch(network);
      const variable = `${network.replace(/-staging$/, "").toUpperCase()}_RPC_URL`;
      const { status, output } = await run(dir, network, { [variable]: base });
      assert.equal(status, 0, output);
      assert.deepEqual(
        vectors(log),
        explorers.map((explorer) => submission(base, explorer)),
        `${network} submitted to the wrong verifiers`
      );
    } finally {
      await rpc.stop();
    }
  }
});

void test("a loan chain skips Etherscan without the key and reaches all three with it", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["sepolia"]!);
  const base = await rpc.start();
  try {
    const withoutKey = scratch("sepolia");
    const first = await run(withoutKey.dir, "sepolia", { SEPOLIA_RPC_URL: base });
    assert.equal(first.status, 0, first.output);
    assert.match(first.output, /skipping Etherscan for sepolia/);
    assert.deepEqual(vectors(withoutKey.log), [
      submission(base, blockscout("eth-sepolia.blockscout.com")),
      submission(base, SOURCIFY),
    ]);

    const withKey = scratch("sepolia");
    const second = await run(withKey.dir, "sepolia", { SEPOLIA_RPC_URL: base, ETHERSCAN_API_KEY: "key" });
    assert.equal(second.status, 0, second.output);
    assert.deepEqual(vectors(withKey.log), [
      submission(base, blockscout("eth-sepolia.blockscout.com")),
      submission(base, etherscan("sepolia", "key")),
      submission(base, SOURCIFY),
    ]);
  } finally {
    await rpc.stop();
  }
});

void test("mainnet takes the mainnet Etherscan chain, not the network name", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["ethereum"]!);
  const base = await rpc.start();
  try {
    const { dir, log } = scratch("ethereum");
    const { status, output } = await run(dir, "ethereum", { ETHEREUM_RPC_URL: base, ETHERSCAN_API_KEY: "key" });
    assert.equal(status, 0, output);
    assert.deepEqual(vectors(log), [
      submission(base, blockscout("eth.blockscout.com")),
      submission(base, etherscan("mainnet", "key")),
      submission(base, SOURCIFY),
    ]);
  } finally {
    await rpc.stop();
  }
});

void test("the wait falls between submissions, once per gap, failures included", async () => {
  const delayMs = 400;
  const rpc = new FakeRpc(CHAIN_ID_HEX["sepolia"]!);
  const base = await rpc.start();
  try {
    // three submissions, two gaps: nothing waits before the first, and a failed submission does not
    // buy the next one an early start - the window the spacing protects is the explorer's, not ours
    const { dir, log } = scratch("sepolia");
    const { status, output } = await run(dir, "sepolia", {
      SEPOLIA_RPC_URL: base,
      ETHERSCAN_API_KEY: "key",
      FORGE_FAIL_WHEN: "blockscout",
      VERIFY_SUBMIT_DELAY_MS: String(delayMs),
    });
    assert.equal(status, 1, output);
    const times = calls(log).map((call) => call.at);
    assert.equal(times.length, 3, output);
    assert.equal(waits(output), 2, "one announced wait per gap, and none before the first submission");
    assert.ok(times[1]! - times[0]! >= delayMs, `first gap was ${times[1]! - times[0]!}ms`);
    assert.ok(times[2]! - times[1]! >= delayMs, `second gap was ${times[2]! - times[1]!}ms`);
  } finally {
    await rpc.stop();
  }
});

void test("a blank delay is not a zero: the default spacing still applies", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["coston2"]!);
  const base = await rpc.start();
  try {
    // `Number("")` and `Number("   ")` are both 0, so a blank assignment would have disabled the
    // spacing silently. The twenty-second default is not waited out: with it disabled the second
    // submission follows the first at once, so a window far shorter than the default separates the
    // two behaviors.
    const { dir, log } = scratch("coston2");
    const landed = await submissionsWithin(
      dir,
      "coston2",
      { COSTON2_RPC_URL: base, VERIFY_SUBMIT_DELAY_MS: "   " },
      log,
      1_000
    );
    assert.equal(landed, 1, "the second submission must still be waiting out the default delay");
  } finally {
    await rpc.stop();
  }
});

void test("a delay that is not a number fails the run before any submission", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["coston2"]!);
  const base = await rpc.start();
  try {
    // `Number("20s")` is NaN and NaN > 0 is false, so a coerced typo would skip every wait while
    // looking configured; it must fail the run instead, before anything is submitted
    const { dir, log } = scratch("coston2");
    const { status, output } = await run(dir, "coston2", { COSTON2_RPC_URL: base, VERIFY_SUBMIT_DELAY_MS: "20s" });
    assert.equal(status, 1, output);
    assert.match(output, /VERIFY_SUBMIT_DELAY_MS must be a non-negative number/);
    assert.deepEqual(calls(log), []);
  } finally {
    await rpc.stop();
  }
});

void test("a failed submission is reported, the others still run, and the exit code says so", async () => {
  const rpc = new FakeRpc(CHAIN_ID_HEX["sepolia"]!);
  const base = await rpc.start();
  try {
    // Blockscout fails, Etherscan and Sourcify are still submitted to: one explorer's outage must
    // not leave the source unverified on the others, and the run must still end in failure so
    // nobody reads a partial result as success
    const { dir, log } = scratch("sepolia");
    const { status, output } = await run(dir, "sepolia", {
      SEPOLIA_RPC_URL: base,
      ETHERSCAN_API_KEY: "key",
      FORGE_FAIL_WHEN: "blockscout",
    });
    assert.equal(status, 1, output);
    assert.match(output, /FAILED: PauseFacet at 0x1234[0-9a-f]* on blockscout \(eth-sepolia\.blockscout\.com\)/);
    assert.match(output, /1 of 3 submission\(s\) failed/);
    assert.equal(calls(log).length, 3, "the Etherscan and Sourcify submissions must still have run");
  } finally {
    await rpc.stop();
  }
});
