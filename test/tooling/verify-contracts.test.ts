/**
 * The explorer submission, run as an operator runs it: the real script in a scratch working
 * directory, `forge` replaced by a stub that records each argument on its own line, the RPC a
 * fake server answering `eth_chainId`. What is pinned: the RPC URL reaches forge as one argument
 * whatever characters it carries, the chain the RPC answers is checked before any submission, and
 * a loan chain reaches both its explorers exactly when the Etherscan key is present.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { test } from "node:test";

const repoRoot = path.resolve(__dirname, "../..");
const SCRIPT = path.join(repoRoot, "deployment/scripts/verify-contracts.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");
const FACET = "0x1234123412341234123412341234123412341234";
const SOURCE = "contracts/smartAccounts/facets/PauseFacet.sol";

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

/** A working directory holding one recorded facet with its source file, and the forge stub. */
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
  // one line per argument and a separator per call, so an argument that was split - or one that
  // swallowed the ones after it - shows as the wrong lines; a call carrying the argument named in
  // FORGE_FAIL_WHEN fails, so a submission's failure can be staged
  fs.writeFileSync(
    path.join(dir, "bin/forge"),
    [
      "#!/usr/bin/env bash",
      `printf '%s\\n' "$@" >> "${log}"`,
      `echo -- >> "${log}"`,
      'for argument in "$@"; do [[ "$argument" == "${FORGE_FAIL_WHEN:-}" ]] && exit 3; done',
      "exit 0",
      "",
    ].join("\n"),
    { mode: 0o755 }
  );
  return { dir, log };
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
  const childEnv: NodeJS.ProcessEnv = { ...process.env, ...env };
  if (!("ETHERSCAN_API_KEY" in env)) {
    delete childEnv.ETHERSCAN_API_KEY;
  }
  childEnv.PATH = `${path.join(dir, "bin")}:${process.env.PATH ?? ""}`;
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [TSX_CLI, SCRIPT, network], { cwd: dir, env: childEnv });
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

/** The stub's calls, each as the argument vector forge received. */
function calls(log: string): string[][] {
  if (!fs.existsSync(log)) {
    return [];
  }
  return fs
    .readFileSync(log, "utf8")
    .split("--\n")
    .filter((call) => call.length > 0)
    .map((call) => call.trimEnd().split("\n"));
}

void test("the RPC URL reaches forge as one argument, query string and all", async () => {
  const rpc = new FakeRpc("0x72");
  const base = await rpc.start();
  try {
    // an RPC URL with a key in its query string is the common case, and `&` is what a shell would
    // read as the end of the command
    const url = `${base}/?key=abc&trace=1`;
    const { dir, log } = scratch("coston2");
    const { status, output } = await run(dir, "coston2", { COSTON2_RPC_URL: url });
    assert.equal(status, 0, output);
    const [call, ...rest] = calls(log);
    assert.deepEqual(rest, []);
    assert.deepEqual(call, [
      "verify-contract",
      FACET,
      `${SOURCE}:PauseFacet`,
      "--rpc-url",
      url,
      "--verifier",
      "blockscout",
      "--verifier-url",
      "https://coston2-explorer.flare.network/api/",
      "--skip-is-verified-check",
      "--watch",
    ]);
  } finally {
    await rpc.stop();
  }
});

void test("an RPC answering another chain stops the run before any submission", async () => {
  const rpc = new FakeRpc("0x10");
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

void test("a loan chain reaches Blockscout alone without the Etherscan key, and both with it", async () => {
  const rpc = new FakeRpc("0xaa36a7");
  const base = await rpc.start();
  try {
    const withoutKey = scratch("sepolia");
    const first = await run(withoutKey.dir, "sepolia", { SEPOLIA_RPC_URL: base });
    assert.equal(first.status, 0, first.output);
    assert.match(first.output, /skipping Etherscan for sepolia/);
    assert.deepEqual(
      calls(withoutKey.log).map((call) => call.slice(5)),
      [
        [
          "--verifier",
          "blockscout",
          "--verifier-url",
          "https://eth-sepolia.blockscout.com/api/",
          "--skip-is-verified-check",
          "--watch",
        ],
      ]
    );

    const withKey = scratch("sepolia");
    const second = await run(withKey.dir, "sepolia", { SEPOLIA_RPC_URL: base, ETHERSCAN_API_KEY: "key" });
    assert.equal(second.status, 0, second.output);
    assert.deepEqual(
      calls(withKey.log).map((call) => call.slice(5)),
      [
        [
          "--verifier",
          "blockscout",
          "--verifier-url",
          "https://eth-sepolia.blockscout.com/api/",
          "--skip-is-verified-check",
          "--watch",
        ],
        ["--chain", "sepolia", "--etherscan-api-key", "key", "--skip-is-verified-check", "--watch"],
      ]
    );
  } finally {
    await rpc.stop();
  }
});

void test("a failed submission is reported, the others still run, and the exit code says so", async () => {
  const rpc = new FakeRpc("0xaa36a7");
  const base = await rpc.start();
  try {
    // Blockscout fails, Etherscan is still submitted to: one explorer's outage must not leave the
    // source unverified on the other, and the run must still end in failure so nobody reads a
    // partial result as success
    const { dir, log } = scratch("sepolia");
    const { status, output } = await run(dir, "sepolia", {
      SEPOLIA_RPC_URL: base,
      ETHERSCAN_API_KEY: "key",
      FORGE_FAIL_WHEN: "blockscout",
    });
    assert.equal(status, 1, output);
    assert.match(output, /FAILED: PauseFacet at 0x1234[0-9a-f]* on blockscout \(eth-sepolia\.blockscout\.com\)/);
    assert.match(output, /1 of 2 submission\(s\) failed/);
    assert.equal(calls(log).length, 2, "the Etherscan submission must still have run");
  } finally {
    await rpc.stop();
  }
});
