// The verifier CLI end to end: the real verify-diamond.ts run as a child process against a fake
// JSON-RPC server and a scratch repository (record, artifacts, sources), so what the node tests of
// verifyDiamond() cannot see is pinned here - the exit status on failed checks, the block every
// read is made at, the chain-id guard, and the abort on a cut file aiming at another diamond.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { createRequire } from "node:module";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { after, before, test } from "node:test";
import Web3, { type AbiItem } from "web3";
import { FACETS_ABI, type LoupeFacet } from "../../deployment/utils/diamond-inspect";
import { dispatchSlot } from "../../deployment/utils/diamond-verify";
import { loadPinnedEthereumAddresses } from "../../deployment/utils/pinned-constants";
import { isFunctionFragment, toSelector } from "../../deployment/utils/prep-cut";

const SCRIPT = join(__dirname, "../../deployment/scripts/verify-diamond.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");
const DIAMOND = "0x000000000000000000000000000000000000d1a0";
/** The bootstrap's own owner: the verifier's default on a loan chain when no flag names one. */
const PINNED_INITIAL_OWNER = loadPinnedEthereumAddresses().initialOwner;
const OWNER = "0x0000000000000000000000000000000000000e0e";
const STRANGER = "0x000000000000000000000000000000000000bad0";
const BLOCK = "0x1234";
const ADDRESSES: Record<string, string> = {
  DiamondCutFacet: "0x0000000000000000000000000000000000000c01",
  DiamondLoupeFacet: "0x0000000000000000000000000000000000000c02",
  OwnershipFacet: "0x0000000000000000000000000000000000000c03",
  PauseFacet: "0x0000000000000000000000000000000000000c04",
};

// the canonical ABIs, so the selectors are the real ones the verifier's dispatch checks name
const fn = (name: string, inputs: AbiItem["inputs"] = []): AbiItem => ({ type: "function", name, inputs });
const CUT_ABI = [
  fn("diamondCut", [
    {
      name: "_diamondCut",
      type: "tuple[]",
      components: [
        { name: "facetAddress", type: "address" },
        { name: "action", type: "uint8" },
        { name: "functionSelectors", type: "bytes4[]" },
      ],
    },
    { name: "_init", type: "address" },
    { name: "_calldata", type: "bytes" },
  ]),
];
const LOUPE_ABI = [
  fn("facets"),
  fn("facetFunctionSelectors", [{ name: "_facet", type: "address" }]),
  fn("facetAddresses"),
  fn("facetAddress", [{ name: "_functionSelector", type: "bytes4" }]),
];
const ERC165_ABI = [fn("supportsInterface", [{ name: "_interfaceId", type: "bytes4" }])];
const OWNERSHIP_ABI = [fn("owner"), fn("transferOwnership", [{ name: "_newOwner", type: "address" }])];
const ABIS: Record<string, AbiItem[]> = {
  DiamondCutFacet: CUT_ABI,
  DiamondLoupeFacet: [...LOUPE_ABI, ...ERC165_ABI],
  OwnershipFacet: OWNERSHIP_ABI,
  PauseFacet: [fn("pause"), fn("unpause")],
  IERC165: ERC165_ABI,
  IDiamondCut: CUT_ABI,
  IDiamondLoupe: LOUPE_ABI,
  IERC173: OWNERSHIP_ABI,
  MasterAccountController: [],
  PersonalAccountProxy: [],
};

function selectorsOf(name: string): string[] {
  return (ABIS[name] ?? []).filter(isFunctionFragment).map((fragment) => toSelector(fragment).toLowerCase());
}

function fakeCode(name: string): string {
  return `0x6080604052${Buffer.from(name, "utf8").toString("hex")}`;
}

function interfaceIdOf(name: string): string {
  let id = 0;
  for (const selector of selectorsOf(name)) {
    id ^= Number.parseInt(selector.slice(2), 16);
  }
  return `0x${(id >>> 0).toString(16).padStart(8, "0")}`;
}

/** The chain the fake RPC serves; a scenario mutates it before running the CLI. */
interface ChainState {
  chainId: string;
  code: Map<string, string>;
  storage: Map<string, string>;
  loupe: LoupeFacet[];
  owner: string;
  flags: Set<string>;
}

function honestChain(): ChainState {
  const state: ChainState = {
    chainId: "0x72",
    code: new Map([[DIAMOND, fakeCode("MasterAccountController")]]),
    storage: new Map(),
    loupe: [],
    owner: OWNER,
    flags: new Set(["IERC165", "IDiamondCut", "IDiamondLoupe", "IERC173"].map(interfaceIdOf)),
  };
  for (const [name, address] of Object.entries(ADDRESSES)) {
    state.code.set(address, fakeCode(name));
    const selectors = selectorsOf(name);
    for (const selector of selectors) {
      state.storage.set(`${DIAMOND}:${BigInt(dispatchSlot(selector))}`, `0x${address.slice(2).padStart(64, "0")}`);
    }
    state.loupe.push({ facetAddress: address, functionSelectors: selectors });
  }
  return state;
}

interface RpcRequest {
  method: string;
  params: unknown[];
}

const web3 = new Web3();
const ZERO_WORD = `0x${"0".repeat(64)}`;

function answer(state: ChainState, request: RpcRequest): unknown {
  const { method, params } = request;
  if (method === "eth_chainId") {
    return state.chainId;
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
      miner: STRANGER,
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
    return state.code.get(String(params[0]).toLowerCase()) ?? "0x";
  }
  if (method === "eth_getStorageAt") {
    const key = `${String(params[0]).toLowerCase()}:${BigInt(String(params[1]))}`;
    return state.storage.get(key) ?? ZERO_WORD;
  }
  if (method === "eth_call") {
    const call = params[0] as { data?: string; input?: string };
    const data = (call.data ?? call.input ?? "0x").toLowerCase();
    const selector = data.slice(0, 10);
    if (selector === "0x7a0ed627") {
      return web3.eth.abi.encodeParameter(FACETS_ABI, state.loupe);
    }
    if (selector === "0x8da5cb5b") {
      return web3.eth.abi.encodeParameter("address", state.owner);
    }
    if (selector === "0x01ffc9a7") {
      return web3.eth.abi.encodeParameter("bool", state.flags.has(`0x${data.slice(10, 18)}`));
    }
    throw new Error(`unexpected eth_call selector ${selector}`);
  }
  throw new Error(`unexpected RPC method ${method}`);
}

class FakeRpc {
  state = honestChain();
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
            return { jsonrpc: "2.0", id: item.id, error: { code: -32601, message: (error as Error).message } };
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
    this.state = honestChain();
    this.requests = [];
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }
}

/** A repository with the record, the artifacts and the facet sources the honest chain matches. */
function scratchRepo(): string {
  const root = mkdtempSync(join(tmpdir(), "verify-diamond-cli-"));
  mkdirSync(join(root, "deployment/deploys"), { recursive: true });
  mkdirSync(join(root, "deployment/cuts/coston2"), { recursive: true });
  mkdirSync(join(root, "deployment/scripts"), { recursive: true });
  mkdirSync(join(root, "contracts/smartAccounts/facets"), { recursive: true });
  const record = [
    { name: "MasterAccountController", contractName: "MasterAccountController.sol", address: DIAMOND },
    ...Object.entries(ADDRESSES).map(([name, address]) => ({ name, contractName: `${name}.sol`, address })),
  ];
  writeFileSync(join(root, "deployment/deploys/coston2.json"), JSON.stringify(record, null, 2));
  for (const [name, abi] of Object.entries(ABIS)) {
    mkdirSync(join(root, `artifacts/${name}.sol`), { recursive: true });
    const artifact = {
      abi,
      bytecode: { object: fakeCode(`creation:${name}`) },
      deployedBytecode: { object: fakeCode(name) },
    };
    writeFileSync(join(root, `artifacts/${name}.sol/${name}.json`), JSON.stringify(artifact));
  }
  for (const name of Object.keys(ADDRESSES)) {
    writeFileSync(join(root, `contracts/smartAccounts/facets/${name}.sol`), `contract ${name} {}\n`);
  }
  writeFileSync(
    join(root, "deployment/cuts/coston2/elsewhere.json"),
    JSON.stringify({ diamond: STRANGER, facets: ["PauseFacet"], execute: false })
  );
  return root;
}

interface RunResult {
  status: number | null;
  stdout: string;
  stderr: string;
}

function runCli(cwd: string, rpcUrl: string, args: string[], blockTag?: string): Promise<RunResult> {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    COSTON2_RPC_URL: rpcUrl,
    SEPOLIA_RPC_URL: rpcUrl,
    ETHEREUM_RPC_URL: rpcUrl,
  };
  if (blockTag !== undefined) {
    env.VERIFY_BLOCK_TAG = blockTag;
  }
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

const BASE_ARGS = ["coston2", "--no-build", "--expect-owner", OWNER];

void test("an honest diamond passes, and every read is made at the block the tag resolved to", async () => {
  rpc.reset();
  const result = await runCli(repo, rpc.url, BASE_ARGS, "finalized");
  assert.equal(result.status, 0, result.stdout + result.stderr);
  assert.match(result.stdout, /^Block: 4660 \(finalized\)$/m);
  assert.match(result.stdout, /All \d+ checks passed\./);
  const blockRequests = rpc.requests.filter((request) => request.method === "eth_getBlockByNumber");
  assert.deepEqual(
    blockRequests.map((request) => request.params[0]),
    ["finalized"]
  );
  const reads = rpc.requests.filter((request) =>
    ["eth_getCode", "eth_getStorageAt", "eth_call"].includes(request.method)
  );
  assert.ok(reads.length > 10, `expected the reads to go through the RPC, saw ${reads.length}`);
  for (const read of reads) {
    assert.equal(read.params.at(-1), BLOCK, `${read.method} was not read at the resolved block`);
  }
});

void test("failed checks make the CLI exit 1 after printing them", async () => {
  rpc.reset();
  rpc.state.code.set(ADDRESSES.PauseFacet!, fakeCode("PauseFacet-v2"));
  const result = await runCli(repo, rpc.url, BASE_ARGS);
  assert.equal(result.status, 1, result.stdout + result.stderr);
  assert.match(result.stdout, /FAIL {2}code: PauseFacet at .* matches the artifact/);
  assert.match(result.stdout, /1 of \d+ checks FAILED\./);
});

void test("an RPC answering another chain id aborts before any check", async () => {
  rpc.reset();
  rpc.state.chainId = "0x10";
  const result = await runCli(repo, rpc.url, BASE_ARGS);
  assert.equal(result.status, 1);
  assert.match(result.stderr, /RPC for coston2 answers chain id 16, expected 114/);
  assert.doesNotMatch(result.stdout, /checks/);
});

void test("a cut file targeting another diamond aborts with the record's controller named", async () => {
  rpc.reset();
  const result = await runCli(repo, rpc.url, ["coston2", "elsewhere", "--no-build", "--expect-owner", OWNER]);
  assert.equal(result.status, 1);
  assert.match(result.stderr, new RegExp(`the cut file targets ${STRANGER} but deployment/deploys/coston2.json`));
});

/** The pins and the default owner are a loan-chain rule, so both chains are driven, not one. */
const LOAN_CHAINS = [
  { network: "sepolia", chainId: "0xaa36a7" },
  { network: "ethereum", chainId: "0x1" },
];

/** Gives the scratch repo this network's record and the pinned source the verifier parses. */
function prepareLoanChain(network: string): void {
  writeFileSync(
    join(repo, `deployment/deploys/${network}.json`),
    readFileSync(join(repo, "deployment/deploys/coston2.json"), "utf8")
  );
  copyFileSync(
    join(__dirname, "../../deployment/scripts/PinnedControllerInitCode.sol"),
    join(repo, "deployment/scripts/PinnedControllerInitCode.sol")
  );
}

void test("the pins are read on both loan chains, and on no other", async () => {
  // the pinned bootstrap reproduces Ethereum's controller at the same address on Sepolia, so the
  // verifier holds both chains to the pins. The fixture diamond is not the pinned controller, so
  // the pin checks appear and fail - which is what proves they were consulted at all
  for (const chain of LOAN_CHAINS) {
    rpc.reset();
    rpc.state.chainId = chain.chainId;
    prepareLoanChain(chain.network);
    const result = await runCli(repo, rpc.url, [chain.network, "--no-build", "--expect-owner", OWNER]);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    assert.match(result.stdout, /pins: the diamond is the pinned controller/);
    assert.match(result.stdout, /pins: OwnershipFacet recorded at the pinned address/);
  }

  // a Flare-family chain has no pinned bootstrap, so the same record raises no pin check at all
  rpc.reset();
  const onCoston2 = await runCli(repo, rpc.url, BASE_ARGS);
  assert.equal(onCoston2.status, 0, onCoston2.stdout + onCoston2.stderr);
  assert.doesNotMatch(onCoston2.stdout, /pins:/);
});

void test("without --expect-owner a loan chain is held to the pinned initial owner", async () => {
  // the bootstrap's own owner is the default on both, so an operator who omits the flag before
  // the handover still gets a real check rather than none: the fixture answers another owner
  for (const chain of LOAN_CHAINS) {
    rpc.reset();
    rpc.state.chainId = chain.chainId;
    prepareLoanChain(chain.network);
    const result = await runCli(repo, rpc.url, [chain.network, "--no-build"]);
    assert.equal(result.status, 1, result.stdout + result.stderr);
    // the check's expectation is the pinned owner, printed under its name; without the default it
    // would fall back to the chain config's governance, which these networks do not have
    assert.match(result.stdout, new RegExp(`FAIL\\s+owner[\\s\\S]{0,120}?${PINNED_INITIAL_OWNER}`, "i"));
  }
});
