// The registration verifier's CLI end to end: the real verify-implementation.ts run as a child
// process against a fake JSON-RPC server and a scratch repository, so what the node tests of
// verifyImplementation() cannot see is pinned here - the exit status on failed checks, the block
// every read is made at, and above all the two revert mappings the CLI's readers make
// (`FunctionNotFound` to "the facet is not cut", `TimelockInvalidSelector` to "not queued"),
// which a fake handing over already-decoded values can never exercise.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import Web3 from "web3";
import { BEACON_SLOT } from "../utils/implementation-verify";

const SCRIPT = join(__dirname, "verify-implementation.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");
const DIAMOND = "0x000000000000000000000000000000000000d1a0";
const IMPL = "0x0000000000000000000000000000000000001111";
const OTHER_IMPL = "0x0000000000000000000000000000000000002222";
const ACCOUNT = "0x00000000000000000000000000000000000aaaa1";
const OWNER = "rSampleOwner11111111111111111111";
const BLOCK = "0x1234";

// the selectors the CLI's readers must know, and one it must not swallow
const FUNCTION_NOT_FOUND = "0x5416eb98";
const TIMELOCK_NOT_QUEUED = "0x08d9e6dc";
const SOME_OTHER_ERROR = "0xdeadbeef";

const web3 = new Web3();
const ZERO_WORD = `0x${"0".repeat(64)}`;

function fakeCode(name: string): string {
  return `0x6080604052${Buffer.from(name, "utf8").toString("hex")}`;
}

interface RpcRequest {
  method: string;
  params: unknown[];
}

/** What the fake diamond answers; a scenario mutates this before running the CLI. */
interface ChainState {
  /** The revert selector `implementation()` should throw, if any. */
  registryRevert?: string;
  /** The revert selector the timelock getter should throw, if any. */
  timelockRevert?: string;
  beaconImpl: string;
  duration: bigint;
  maturity: bigint;
  accountHasCode: boolean;
  /** The one calldata the timelock getter answers a maturity for. */
  queuedCall: string;
}

/** `setPersonalAccountImplementation(address)` with IMPL, as the core encodes it. */
const REGISTRATION_CALL = `0xd2ea87ef${"0".repeat(24)}${IMPL.slice(2)}`;

function honestState(): ChainState {
  return {
    beaconImpl: IMPL,
    duration: 3600n,
    maturity: 1_800_000_000n,
    accountHasCode: true,
    queuedCall: REGISTRATION_CALL,
  };
}

class RevertError extends Error {
  constructor(readonly selector: string) {
    super(`execution reverted, data: "${selector}"`);
  }
}

function answer(state: ChainState, request: RpcRequest): unknown {
  const { method, params } = request;
  if (method === "eth_chainId") {
    return "0x1";
  }
  if (method === "eth_getBlockByNumber") {
    return {
      number: BLOCK,
      hash: `0x${"11".repeat(32)}`,
      parentHash: `0x${"22".repeat(32)}`,
      nonce: "0x0000000000000000",
      sha3Uncles: `0x${"33".repeat(32)}`,
      logsBloom: `0x${"00".repeat(256)}`,
      transactionsRoot: `0x${"44".repeat(32)}`,
      stateRoot: `0x${"55".repeat(32)}`,
      receiptsRoot: `0x${"66".repeat(32)}`,
      miner: OTHER_IMPL,
      difficulty: "0x0",
      totalDifficulty: "0x0",
      extraData: "0x",
      size: "0x200",
      gasLimit: "0x1c9c380",
      gasUsed: "0x0",
      timestamp: "0x65000000",
      baseFeePerGas: "0x1",
      mixHash: `0x${"77".repeat(32)}`,
      transactions: [],
      uncles: [],
    };
  }
  if (method === "eth_getCode") {
    const address = String(params[0]).toLowerCase();
    if (address === IMPL.toLowerCase()) {
      return fakeCode("PersonalAccountRemote");
    }
    if (address === ACCOUNT.toLowerCase() && state.accountHasCode) {
      return fakeCode("PersonalAccountProxy");
    }
    return "0x";
  }
  if (method === "eth_getStorageAt") {
    const address = String(params[0]).toLowerCase();
    const slot = String(params[1]).toLowerCase();
    if (address === ACCOUNT.toLowerCase() && BigInt(slot) === BigInt(BEACON_SLOT)) {
      return `0x${DIAMOND.slice(2).padStart(64, "0")}`;
    }
    return ZERO_WORD;
  }
  if (method === "eth_call") {
    const call = params[0] as { to?: string; data?: string; input?: string };
    const data = (call.data ?? call.input ?? "0x").toLowerCase();
    const selector = data.slice(0, 10);
    const to = String(call.to ?? "").toLowerCase();
    // each read belongs to one contract; a call sent anywhere else is not the read it claims
    const expectAt = (address: string): void => {
      if (to !== address.toLowerCase()) {
        throw new Error(`${selector} was called on ${to}, expected ${address.toLowerCase()}`);
      }
    };
    // the selectors here are the contracts' own, from `cast sig`
    // implementation()
    if (selector === "0x5c60da1b") {
      expectAt(DIAMOND);
      if (state.registryRevert) {
        throw new RevertError(state.registryRevert);
      }
      return web3.eth.abi.encodeParameter("address", state.beaconImpl);
    }
    // getExecuteTimelockedCallTimestamp(bytes): the argument IS the registration, so a maturity
    // is returned only for the exact calldata the setter's signature produces
    if (selector === "0xb071614b") {
      expectAt(DIAMOND);
      if (state.timelockRevert) {
        throw new RevertError(state.timelockRevert);
      }
      const asked = String(web3.eth.abi.decodeParameter("bytes", `0x${data.slice(10)}`)).toLowerCase();
      if (asked !== state.queuedCall.toLowerCase()) {
        // what the real getter does for a call it has never recorded
        throw new RevertError(TIMELOCK_NOT_QUEUED);
      }
      return web3.eth.abi.encodeParameter("uint256", state.maturity.toString());
    }
    // getTimelockDurationSeconds()
    if (selector === "0xf1dd663e") {
      expectAt(DIAMOND);
      return web3.eth.abi.encodeParameter("uint256", state.duration.toString());
    }
    // getPersonalAccount(string): answered for the owner the run was given
    if (selector === "0xd09318d4") {
      expectAt(DIAMOND);
      const asked = String(web3.eth.abi.decodeParameter("string", `0x${data.slice(10)}`));
      if (asked !== OWNER) {
        throw new Error(`getPersonalAccount asked for ${asked}, expected ${OWNER}`);
      }
      return web3.eth.abi.encodeParameter("address", ACCOUNT);
    }
    // controllerAddress() and xrplOwner() are the account's own getters, not the diamond's
    if (selector === "0x4b24ea47") {
      expectAt(ACCOUNT);
      return web3.eth.abi.encodeParameter("address", DIAMOND);
    }
    if (selector === "0x966276f8") {
      expectAt(ACCOUNT);
      return web3.eth.abi.encodeParameter("string", OWNER);
    }
    throw new Error(`unexpected eth_call selector ${selector}`);
  }
  throw new Error(`unexpected RPC method ${method}`);
}

class FakeRpc {
  state = honestState();
  requests: RpcRequest[] = [];
  private server: Server | undefined;
  url = "";

  async start(): Promise<void> {
    this.server = createServer((req, res) => {
      let body = "";
      req.on("data", (chunk: Buffer) => {
        body += chunk.toString("utf8");
      });
      req.on("end", () => {
        const parsed = JSON.parse(body) as
          | { id: number; method: string; params?: unknown[] }[]
          | { id: number; method: string; params?: unknown[] };
        const batch = Array.isArray(parsed) ? parsed : [parsed];
        const replies = batch.map((item) => {
          const request = { method: item.method, params: item.params ?? [] };
          this.requests.push(request);
          try {
            return { jsonrpc: "2.0", id: item.id, result: answer(this.state, request) };
          } catch (error) {
            const message = (error as Error).message;
            const data = error instanceof RevertError ? error.selector : undefined;
            return { jsonrpc: "2.0", id: item.id, error: { code: 3, message, ...(data ? { data } : {}) } };
          }
        });
        res.setHeader("content-type", "application/json");
        res.end(JSON.stringify(Array.isArray(parsed) ? replies : replies[0]));
      });
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const address = this.server.address();
    if (address === null || typeof address === "string") {
      throw new Error("fake RPC did not bind a port");
    }
    this.url = `http://127.0.0.1:${address.port}`;
  }

  reset(): void {
    this.state = honestState();
    this.requests = [];
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }
}

/** A repository holding the record and the artifacts the fake chain matches. */
function scratchRepo(): string {
  const root = mkdtempSync(join(tmpdir(), "verify-implementation-cli-"));
  mkdirSync(join(root, "deployment/deploys"), { recursive: true });
  mkdirSync(join(root, "contracts/smartAccounts/implementation"), { recursive: true });
  writeFileSync(
    join(root, "deployment/deploys/ethereum.json"),
    JSON.stringify([{ name: "MasterAccountController", contractName: "MasterAccountController.sol", address: DIAMOND }])
  );
  for (const name of ["PersonalAccountRemote", "PersonalAccountProxy"]) {
    mkdirSync(join(root, `artifacts/${name}.sol`), { recursive: true });
    writeFileSync(
      join(root, `artifacts/${name}.sol/${name}.json`),
      JSON.stringify({
        abi: [],
        bytecode: { object: fakeCode(`creation:${name}`) },
        deployedBytecode: { object: fakeCode(name) },
      })
    );
    writeFileSync(join(root, `contracts/smartAccounts/implementation/${name}.sol`), `contract ${name} {}\n`);
  }
  return root;
}

interface RunResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runCli(cwd: string, rpcUrl: string, args: string[]): Promise<RunResult> {
  const env: NodeJS.ProcessEnv = { ...process.env, ETHEREUM_RPC_URL: rpcUrl, VERIFY_BLOCK_TAG: "finalized" };
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [TSX_CLI, SCRIPT, ...args], { cwd, env });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", reject);
    child.on("close", (status) => resolve({ status, stdout, stderr }));
  });
}

const rpc = new FakeRpc();
let repo = "";

before(async () => {
  await rpc.start();
  repo = scratchRepo();
});

after(async () => {
  await rpc.stop();
  rmSync(repo, { recursive: true, force: true });
});

const LIVE = ["ethereum", "PersonalAccountRemote", IMPL, "--stage", "live", "--no-build"];

void test("an honest live registration passes, with every read at the resolved block", async () => {
  rpc.reset();
  const result = await runCli(repo, rpc.url, LIVE);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /^Block: 4660 \(finalized\)$/m);
  assert.match(result.stdout, /All \d+ checks passed\./);
  const blockRequests = rpc.requests.filter((request) => request.method === "eth_getBlockByNumber");
  assert.deepEqual(
    blockRequests.map((request) => request.params[0]),
    ["finalized"]
  );
  for (const read of rpc.requests.filter((request) =>
    ["eth_getCode", "eth_call", "eth_getStorageAt"].includes(request.method)
  )) {
    assert.equal(read.params.at(-1), BLOCK, `${read.method} was not read at the resolved block`);
  }
});

void test("a failed check exits 1 after printing the check list", async () => {
  rpc.reset();
  rpc.state.beaconImpl = OTHER_IMPL;
  const result = await runCli(repo, rpc.url, LIVE);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL {2}registry: the Personal Account beacon points at the implementation/);
  assert.match(result.stdout, /1 of \d+ checks FAILED\./);
});

void test("FunctionNotFound from the registry becomes the uncut-facet check, not a crash", async () => {
  rpc.reset();
  rpc.state.registryRevert = FUNCTION_NOT_FOUND;
  const result = await runCli(repo, rpc.url, LIVE);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL {2}registry: PersonalAccountsFacet is cut on the controller/);
  assert.match(result.stdout, /cut PersonalAccountsFacet first/);
});

void test('TimelockInvalidSelector reads as "not queued" rather than failing the run', async () => {
  rpc.reset();
  rpc.state.timelockRevert = TIMELOCK_NOT_QUEUED;
  rpc.state.beaconImpl = OTHER_IMPL;
  const result = await runCli(repo, rpc.url, [
    "ethereum",
    "PersonalAccountRemote",
    IMPL,
    "--stage",
    "queued",
    "--no-build",
  ]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL {2}timelock: exactly this registration is queued/);
  assert.match(result.stdout, /no queued call with this calldata/);
  // the run still completed: the other checks were evaluated and printed
  assert.match(result.stdout, /ok {4}timelock: the duration is non-zero/);
});

void test("an unexpected revert is not swallowed", async () => {
  rpc.reset();
  rpc.state.registryRevert = SOME_OTHER_ERROR;
  const result = await runCli(repo, rpc.url, LIVE);
  assert.equal(result.status, 1);
  assert.doesNotMatch(result.stdout, /checks passed/);
  // the revert data is named, so an unknown error is diagnosable rather than opaque
  assert.match(result.stderr, /revert data: .*0xdeadbeef/);
});

void test("an explicitly requested sample that does not exist fails the run", async () => {
  rpc.reset();
  rpc.state.accountHasCode = false;
  const result = await runCli(repo, rpc.url, [...LIVE, "--xrpl-owner", OWNER]);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL {2}sample: .* is materialized/);
});

void test("bad usage exits 2 and names the accepted contracts", async () => {
  rpc.reset();
  const missing = await runCli(repo, rpc.url, ["ethereum", "PersonalAccountRemote"]);
  assert.equal(missing.status, 2);
  assert.match(missing.stderr, /Usage: pnpm verify_implementation/);
  assert.match(missing.stderr, /PersonalAccount, PersonalAccountRemote, LoanSubaccount, LoanSubaccountRemote/);
  const badStage = await runCli(repo, rpc.url, ["ethereum", "PersonalAccountRemote", IMPL, "--stage", "later"]);
  assert.equal(badStage.status, 1);
  assert.match(badStage.stderr, /--stage takes pre, queued or live/);
});

void test("queued: the exact registration calldata is what the getter is asked for", async () => {
  rpc.reset();
  rpc.state.beaconImpl = OTHER_IMPL;
  const result = await runCli(repo, rpc.url, [
    "ethereum",
    "PersonalAccountRemote",
    IMPL,
    "--stage",
    "queued",
    "--no-build",
  ]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /All \d+ checks passed\./);
  assert.match(result.stdout, new RegExp(`Registration calldata: ${REGISTRATION_CALL}`));
  assert.match(result.stdout, /timelock: executable after 1800000000/);
  // the fake only answers a maturity for that exact calldata, so passing proves the CLI asked
  // about the registration it printed, on the diamond
  const asked = rpc.requests.filter(
    (request) =>
      request.method === "eth_call" &&
      String((request.params[0] as { data?: string }).data ?? "").startsWith("0xb071614b")
  );
  assert.equal(asked.length, 1);
  assert.equal(String((asked[0]!.params[0] as { to?: string }).to).toLowerCase(), DIAMOND.toLowerCase());
});

void test("live with a materialized sample passes, and reads its storage at the same block", async () => {
  rpc.reset();
  const result = await runCli(repo, rpc.url, [...LIVE, "--xrpl-owner", OWNER]);
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /All \d+ checks passed\./);
  assert.match(result.stdout, /ok {4}sample: .* is served by this controller as its beacon/);
  assert.match(result.stdout, new RegExp(`ok {4}sample: .* was initialized for ${OWNER}`));
  // the beacon slot is read, on the account, at the resolved block
  const storageReads = rpc.requests.filter((request) => request.method === "eth_getStorageAt");
  assert.equal(storageReads.length, 1);
  assert.equal(String(storageReads[0]!.params[0]).toLowerCase(), ACCOUNT.toLowerCase());
  assert.equal(BigInt(String(storageReads[0]!.params[1])), BigInt(BEACON_SLOT));
  assert.equal(storageReads[0]!.params[2], BLOCK);
});
