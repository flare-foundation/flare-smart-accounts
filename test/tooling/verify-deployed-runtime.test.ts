/**
 * The gate between a run's printed record lines and the deployment record, run as the wrappers run
 * it: the real CLI in a scratch repository, with a fake JSON-RPC server for the chain.
 *
 * What it exists to stop is a record naming an address that never received the contract. A deploy
 * script prints its `DEPLOYED:` lines during forge's SIMULATION, so a run that reverted, was
 * refused by the signer or broadcast only half of itself still printed a full set of them. The
 * wrapper withholds the recorder when forge exits non-zero; these cases cover what the chain has to
 * settle after it exits zero.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";

const repoRoot = path.resolve(__dirname, "../..");
const SCRIPT = path.join(repoRoot, "deployment/scripts/verify-deployed-runtime.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");

const COSTON2_CHAIN_ID = "0x72";
const FACET = "0x1234123412341234123412341234123412341234";
const OTHER = "0x5678567856785678567856785678567856785678";

/**
 * Runtime code with a well-formed CBOR metadata trailer, as solc emits: the last two bytes give the
 * trailer's length and the byte it points at opens a CBOR map. A recompile of unchanged sources can
 * move those bytes without changing an instruction, which is the difference the check tolerates.
 */
function withMetadata(functional: string, metadataByte: string): string {
  const metadata = `a1${metadataByte.repeat(3)}`;
  const length = (metadata.length / 2).toString(16).padStart(4, "0");
  return `0x${functional}${metadata}${length}`;
}

const RUNTIME = withMetadata("6080604052", "11");
/** Same instructions, different trailer: the tolerated difference. */
const RUNTIME_RECOMPILED = withMetadata("6080604052", "22");
/** Different instructions: not the same contract. */
const OTHER_RUNTIME = withMetadata("60806040ff", "11");

class FakeRpc {
  private server: Server | undefined;
  chainId = COSTON2_CHAIN_ID;
  /** Runtime code by address, lower-cased; anything unlisted has none. */
  code = new Map<string, string>();
  /** How many code reads the run made: zero means it stopped before reaching the chain. */
  codeReads = 0;
  url = "";

  async start(): Promise<void> {
    this.server = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk: Buffer) => {
        body += chunk.toString();
      });
      req.on("end", () => {
        const request = JSON.parse(body) as { id: number; method: string; params?: unknown[] };
        const answer = (one: { id: number; method: string; params?: unknown[] }) => {
          if (one.method === "eth_chainId") {
            return { jsonrpc: "2.0", id: one.id, result: this.chainId };
          }
          if (one.method === "eth_getCode") {
            this.codeReads += 1;
            const [target] = one.params ?? [];
            const address = typeof target === "string" ? target.toLowerCase() : "";
            return { jsonrpc: "2.0", id: one.id, result: this.code.get(address) ?? "0x" };
          }
          return { jsonrpc: "2.0", id: one.id, error: { code: -32601, message: one.method } };
        };
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end(JSON.stringify(answer(request)));
      });
    });
    await new Promise<void>((resolve) => {
      this.server?.listen(0, "127.0.0.1", resolve);
    });
    const address = this.server?.address();
    this.url = typeof address === "object" && address ? `http://127.0.0.1:${address.port}` : "";
  }

  reset(): void {
    this.code.clear();
    this.codeReads = 0;
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => {
      this.server?.close(() => {
        resolve();
      });
    });
  }
}

const rpc = new FakeRpc();
before(async () => {
  await rpc.start();
});
after(async () => {
  await rpc.stop();
});

/** A scratch repository holding one artifact and the staged output the wrapper would have teed. */
function repoWith(output: string | undefined, artifactRuntime = RUNTIME): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "verify-runtime-"));
  fs.mkdirSync(path.join(dir, "artifacts/PauseFacet.sol"), { recursive: true });
  fs.writeFileSync(
    path.join(dir, "artifacts/PauseFacet.sol/PauseFacet.json"),
    JSON.stringify({ deployedBytecode: { object: artifactRuntime } })
  );
  if (output !== undefined) {
    fs.writeFileSync(path.join(dir, "forge-deploy-output.txt"), output);
  }
  return dir;
}

function staged(address: string, network = "coston2"): string {
  return `NETWORK: ${network}\nDEPLOYED: PauseFacet, PauseFacet.sol: ${address}\n`;
}

function runCli(cwd: string, network = "coston2"): Promise<{ status: number | null; output: string }> {
  const env: NodeJS.ProcessEnv = { ...process.env, COSTON2_RPC_URL: rpc.url, SEPOLIA_RPC_URL: rpc.url };
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [TSX_CLI, SCRIPT, network], { cwd, env });
    let output = "";
    child.stdout.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      output += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (status) => {
      resolve({ status, output });
    });
  });
}

void test("an address carrying the artifact's runtime is promoted", async () => {
  rpc.reset();
  rpc.code.set(FACET, RUNTIME);
  const run = await runCli(repoWith(staged(FACET)));
  assert.equal(run.status, 0, run.output);
  assert.match(run.output, /all 1 deployments carry the runtime they are recorded as/);
});

void test("only the metadata trailer differing is still the same contract", async () => {
  rpc.reset();
  rpc.code.set(FACET, RUNTIME_RECOMPILED);
  const run = await runCli(repoWith(staged(FACET)));
  assert.equal(run.status, 0, run.output);
  assert.match(run.output, /modulo its metadata trailer/);
});

void test("an address with no code stops the promotion", async () => {
  // the reproduced defect: the run printed the address it simulated, and nothing was deployed there
  rpc.reset();
  const run = await runCli(repoWith(staged(FACET)));
  assert.equal(run.status, 2, run.output);
  assert.match(run.output, /no code at this address/);
  assert.match(run.output, /Nothing was recorded/);
});

void test("an address carrying another contract stops the promotion", async () => {
  // the nonce-drift shape: the broadcast landed, but not at the address the simulation printed,
  // so the printed one holds whatever else is there
  rpc.reset();
  rpc.code.set(FACET, OTHER_RUNTIME);
  const run = await runCli(repoWith(staged(FACET)));
  assert.equal(run.status, 2, run.output);
  assert.match(run.output, /runtime is not PauseFacet/);
});

void test("one bad entry stops the whole run, and every entry is still reported", async () => {
  // the bad one first: a check that gave up there would leave the operator to discover the rest of
  // the run's state one rerun at a time
  rpc.reset();
  rpc.code.set(FACET, RUNTIME);
  const output = `NETWORK: coston2\nDEPLOYED: PauseFacet, PauseFacet.sol: ${OTHER}\nDEPLOYED: PauseFacet, PauseFacet.sol: ${FACET}\n`;
  const run = await runCli(repoWith(output));
  assert.equal(run.status, 2, run.output);
  assert.equal(rpc.codeReads, 2, "the run stopped at the first failure instead of reporting both");
  assert.match(run.output, /1 of 2 deployments are not on coston2 as printed/);
  assert.match(run.output, /ok\s+PauseFacet @ 0x1234/);
});

void test("output naming another network is refused before the chain is read", async () => {
  // the record file is picked by the name in the output, so a disagreement means the check and the
  // recorder would be talking about different chains
  rpc.reset();
  const run = await runCli(repoWith(staged(FACET, "songbird")));
  assert.equal(run.status, 2, run.output);
  assert.equal(rpc.codeReads, 0);
  assert.match(run.output, /names network songbird, this run is coston2/);
});

void test("a run that deployed nothing passes without reading the chain", async () => {
  rpc.reset();
  const run = await runCli(repoWith("NETWORK: coston2\nReusing deployed facet at: 0x1\n"));
  assert.equal(run.status, 0, run.output);
  assert.equal(rpc.codeReads, 0);
  assert.match(run.output, /no DEPLOYED lines/);
});

void test("a missing staged output is a failure, not an empty pass", async () => {
  rpc.reset();
  const run = await runCli(repoWith(undefined));
  assert.equal(run.status, 2, run.output);
  assert.match(run.output, /forge-deploy-output\.txt is missing/);
});

void test("an RPC serving another chain stops the run", async () => {
  // the check is only worth its exit code if it asked the chain the record is for
  rpc.reset();
  rpc.chainId = "0x1";
  rpc.code.set(FACET, RUNTIME);
  const run = await runCli(repoWith(staged(FACET)));
  rpc.chainId = COSTON2_CHAIN_ID;
  assert.equal(run.status, 1, run.output);
  assert.match(run.output, /answers chain id 1, expected 114/);
});
