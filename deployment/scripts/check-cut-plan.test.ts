/**
 * The cut planner's pinned-bootstrap gate, run as an operator runs it: the real CLI in a scratch
 * repository, with a fake JSON-RPC server for the chain.
 *
 * The gate is what stops a cut being planned against a chain whose four pinned records are not
 * the pinned ones — the controller and its three base facets, reproduced from historical init
 * code rather than built from source. It applies on the loan chains, Ethereum and Sepolia alike,
 * since Sepolia reproduces the same addresses; every case here is driven on Sepolia, with one
 * Flare-family case proving the gate is scoped to that family rather than universal.
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { createServer, type Server } from "node:http";
import { createRequire } from "node:module";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { after, before, test } from "node:test";
import Web3 from "web3";
import { FACETS_ABI } from "../utils/diamond-inspect";
import { loadPinnedEthereumAddresses } from "../utils/pinned-constants";

const here = __dirname;
const repoRoot = path.resolve(here, "../..");
const SCRIPT = path.join(here, "check-cut-plan.ts");
const TSX_CLI = createRequire(__filename).resolve("tsx/cli");

const SEPOLIA_CHAIN_ID = "0xaa36a7";
const ETHEREUM_CHAIN_ID = "0x1";
const COSTON2_CHAIN_ID = "0x72";
/** The pins apply to both loan chains, so the cases that exercise them run on both. */
const LOAN_CHAINS = [
  { network: "sepolia", chainId: SEPOLIA_CHAIN_ID },
  { network: "ethereum", chainId: ETHEREUM_CHAIN_ID },
];
const STRANGER = "0x00000000000000000000000000000000deadbeef";
/** Read from the repository's own pinned source, so the fixtures cannot drift from the pins. */
const pins = loadPinnedEthereumAddresses();
const PINNED_FACETS = [...pins.baseFacets.entries()].map(([name, pin]) => ({ name, ...pin }));

type Record_ = { name: string; contractName: string; address: string };
const entry = (name: string, address: string): Record_ => ({ name, contractName: `${name}.sol`, address });

/** Answers the two methods the planner reaches before it needs anything else. */
class FakeRpc {
  private server: Server | undefined;
  chainId = SEPOLIA_CHAIN_ID;
  /** Runtime code by address, lower-cased; anything unlisted has none. */
  code = new Map<string, string>();
  /** How many times the code at an address was read: zero means a gate fired before any of it. */
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
          if (one.method === "eth_call") {
            // the loupe's `facets()`, answered empty: the plan's selector sections have nothing
            // to reconcile, so a run that gets past the pins finishes instead of erroring
            return { jsonrpc: "2.0", id: one.id, result: new Web3().eth.abi.encodeParameter(FACETS_ABI, []) };
          }
          return { jsonrpc: "2.0", id: one.id, result: null };
        };
        res.setHeader("content-type", "application/json");
        const parsed: unknown = JSON.parse(body);
        res.end(JSON.stringify(Array.isArray(parsed) ? parsed.map(answer) : answer(request)));
      });
    });
    await new Promise<void>((resolve) => this.server!.listen(0, "127.0.0.1", resolve));
    const address = this.server.address();
    if (address === null || typeof address === "string") {
      throw new Error("the fake RPC did not bind a port");
    }
    this.url = `http://127.0.0.1:${address.port}`;
  }

  reset(): void {
    this.chainId = SEPOLIA_CHAIN_ID;
    this.code = new Map();
    this.codeReads = 0;
  }

  async stop(): Promise<void> {
    await new Promise<void>((resolve) => this.server?.close(() => resolve()));
  }
}

/**
 * One accepted runtime per pinned facet, each different from the others: a comparison that took
 * some other facet's hash, or one hash for all three, would accept the wrong bytes and is caught
 * by the cases below.
 */
const ACCEPTED = new Map(
  PINNED_FACETS.map((facet, index) => [facet.name, `0x6080604052348015${index.toString(16).padStart(2, "0")}56`])
);
/** Bytes no pin accepts, for the facet a corruption case puts wrong code at. */
const CORRUPT = "0x6080604052348015600e575f80fd5b50";

/** `DiamondCutFacet` -> `DIAMOND_CUT_FACET`, the pinned source's constant prefix for that facet. */
function constantPrefix(facetName: string): string {
  return facetName.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toUpperCase();
}

/**
 * The pinned source with each base facet's runtime-code hash replaced by the keccak of the code
 * that facet is to be served, so a scenario can present a chain whose pinned addresses hold code
 * the pins accept. The real hashes are the keccak of the Flare production runtimes, which only an
 * EVM run reproduces; what this fixture exercises is the planner's comparison against whatever the
 * pins say, not the pins themselves, which `pinned-constants.test.ts` and the Solidity guard tests
 * hold to the real bytes.
 */
function pinnedSourceAccepting(accepted: Map<string, string>): string {
  let source = fs.readFileSync(path.join(repoRoot, "deployment/scripts/PinnedControllerInitCode.sol"), "utf8");
  for (const [name, code] of accepted) {
    const declaration = new RegExp(`(${constantPrefix(name)}_RUNTIME_CODE_HASH\\s*=\\s*)0x[0-9a-fA-F]{64}`, "g");
    const matches = source.match(declaration) ?? [];
    assert.equal(matches.length, 1, `expected one runtime-hash constant for ${name}`);
    source = source.replace(declaration, `$1${Web3.utils.keccak256(code).toLowerCase()}`);
  }
  return source;
}

interface RepoOptions {
  /** A cut file written as `planned.json`, for the runs that pass one. */
  cut?: { diamond: string };
  /** A pinned source other than the repository's own. */
  pinnedSource?: string;
  /**
   * Leave out the artifact `buildFacetPlans` loads first. A run that reaches planning then fails
   * on that artifact, which is how a case tells the record gate - which runs before planning -
   * from the planning branch that words its refusal the same way.
   */
  omitProxyArtifact?: boolean;
}

/**
 * A repository holding one deployment record, the pinned source the planner parses and the one
 * artifact `buildFacetPlans` loads before its loop.
 */
function scratchRepo(network: string, record: Record_[], options: RepoOptions = {}): string {
  const { cut, pinnedSource, omitProxyArtifact } = options;
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "check-cut-plan-"));
  fs.mkdirSync(path.join(dir, "deployment/deploys"), { recursive: true });
  fs.mkdirSync(path.join(dir, "deployment/scripts"), { recursive: true });
  if (cut) {
    fs.mkdirSync(path.join(dir, `deployment/cuts/${network}`), { recursive: true });
    fs.writeFileSync(
      path.join(dir, `deployment/cuts/${network}/planned.json`),
      JSON.stringify({ ...cut, facets: [], deleteSelectorSigs: [], execute: false })
    );
  }
  fs.mkdirSync(path.join(dir, "artifacts/PersonalAccountProxy.sol"), { recursive: true });
  fs.writeFileSync(path.join(dir, `deployment/deploys/${network}.json`), JSON.stringify(record, null, 2));
  if (pinnedSource === undefined) {
    fs.copyFileSync(
      path.join(repoRoot, "deployment/scripts/PinnedControllerInitCode.sol"),
      path.join(dir, "deployment/scripts/PinnedControllerInitCode.sol")
    );
  } else {
    fs.writeFileSync(path.join(dir, "deployment/scripts/PinnedControllerInitCode.sol"), pinnedSource);
  }
  if (omitProxyArtifact !== true) {
    fs.writeFileSync(
      path.join(dir, "artifacts/PersonalAccountProxy.sol/PersonalAccountProxy.json"),
      JSON.stringify({ abi: [], bytecode: { object: "0x6001" }, deployedBytecode: { object: "0x6001" } })
    );
  }
  return dir;
}

/** The complete, correct pin set: the controller and its three base facets at the pinned addresses. */
function pinnedRecord(): Record_[] {
  return [
    entry("MasterAccountController", pins.controllerAddress),
    ...PINNED_FACETS.map((facet) => entry(facet.name, facet.address)),
  ];
}

function runCli(
  cwd: string,
  rpcUrl: string,
  network: string,
  cutFileName?: string
): Promise<{ status: number | null; output: string }> {
  const env: NodeJS.ProcessEnv = {
    ...process.env,
    SEPOLIA_RPC_URL: rpcUrl,
    ETHEREUM_RPC_URL: rpcUrl,
    COSTON2_RPC_URL: rpcUrl,
  };
  const args = cutFileName ? [network, cutFileName, "--no-build"] : [network, "--no-build"];
  return new Promise((resolve, reject) => {
    const child = spawn(process.execPath, [TSX_CLI, SCRIPT, ...args], { cwd, env });
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

const rpc = new FakeRpc();
const scratches: string[] = [];

function repoFor(network: string, record: Record_[], options: RepoOptions = {}): string {
  const dir = scratchRepo(network, record, options);
  scratches.push(dir);
  return dir;
}

before(async () => {
  await rpc.start();
});

after(async () => {
  await rpc.stop();
  for (const dir of scratches) {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

void test("a pinned base facet missing from the record stops the plan, on either loan chain", async () => {
  // both chains, because the pins are a loan-chain rule and not a Sepolia one: Ethereum is where
  // it matters, Sepolia only reproduces it
  for (const chain of LOAN_CHAINS) {
    rpc.reset();
    rpc.chainId = chain.chainId;
    const record = pinnedRecord().filter((item) => item.name !== "OwnershipFacet");
    const { status, output } = await runCli(repoFor(chain.network, record), rpc.url, chain.network);
    assert.notEqual(status, 0, output);
    assert.match(
      output,
      new RegExp(`OwnershipFacet: pinned base facet missing from deployment/deploys/${chain.network}\\.json`)
    );
  }
});

void test("a pinned base facet recorded at another address stops the plan, before planning starts", async () => {
  rpc.reset();
  const record = pinnedRecord().map((item) => (item.name === "DiamondCutFacet" ? entry(item.name, STRANGER) : item));
  // the record gate and the planning branch word this refusal alike, so the gate is identified by
  // when it fires. Planning needs an artifact this repository does not have: reaching planning at
  // all fails on that instead, so only the gate can produce the pinned message here
  const repo = repoFor("sepolia", record, { omitProxyArtifact: true });
  const { status, output } = await runCli(repo, rpc.url, "sepolia");
  assert.notEqual(status, 0, output);
  assert.match(output, /DiamondCutFacet: recorded address .* does not match the pinned historical address/);
  assert.equal(rpc.codeReads, 0, "the record gate runs before the chain is read at all");
});

void test("a controller recorded at another address stops the plan", async () => {
  rpc.reset();
  const record = pinnedRecord().map((item) =>
    item.name === "MasterAccountController" ? entry(item.name, STRANGER) : item
  );
  const { status, output } = await runCli(repoFor("sepolia", record), rpc.url, "sepolia");
  assert.notEqual(status, 0, output);
  assert.match(output, /MasterAccountController: the deployment record is missing or does not match the pinned/);
});

void test("a pinned address with no code stops the plan on either loan chain: no bootstrap has run", async () => {
  // the planning branch, like the record gate, belongs to the family rather than to one chain
  for (const chain of LOAN_CHAINS) {
    rpc.reset();
    rpc.chainId = chain.chainId;
    const run = await runCli(repoFor(chain.network, pinnedRecord()), rpc.url, chain.network);
    assert.notEqual(run.status, 0, run.output);
    assert.match(run.output, /no code at the pinned address/);
  }
});

void test("each pinned address is compared against its own pin, and other code stops the plan", async () => {
  // one facet at a time holds code no pin accepts while the others hold theirs, in the record's
  // own order: reaching the third means the first two were checked and passed, so a comparison
  // that stopped early - or that used another facet's hash - is caught. A pinned facet is never
  // reclassified by the generic heuristics, so this is a stop, not a REPLACE
  for (const subject of PINNED_FACETS) {
    rpc.reset();
    for (const facet of PINNED_FACETS) {
      rpc.code.set(facet.address, facet.name === subject.name ? CORRUPT : ACCEPTED.get(facet.name)!);
    }
    const repo = repoFor("sepolia", pinnedRecord(), { pinnedSource: pinnedSourceAccepting(ACCEPTED) });
    const { status, output } = await runCli(repo, rpc.url, "sepolia");
    assert.notEqual(status, 0, output);
    assert.match(
      output,
      new RegExp(`${subject.name}: on-chain code does not match the pinned historical runtime hash`)
    );
  }
});

void test("code the pins accept is planned as intentional reuse, not replaced", async () => {
  // the baseline the refusals are refusals against: with every pinned address holding code the
  // pins accept, the plan gets through and reports the pinned facets as REUSE. A comparison that
  // always rejected - or one that classified a pinned facet by the generic heuristics - fails here
  rpc.reset();
  for (const facet of PINNED_FACETS) {
    rpc.code.set(facet.address, ACCEPTED.get(facet.name)!);
  }
  const repo = repoFor("sepolia", pinnedRecord(), { pinnedSource: pinnedSourceAccepting(ACCEPTED) });
  const { status, output } = await runCli(repo, rpc.url, "sepolia");
  assert.equal(status, 0, output);
  assert.doesNotMatch(output, /pinned historical runtime hash|no code at the pinned address/);
  for (const facet of PINNED_FACETS) {
    assert.match(output, new RegExp(`${facet.name}.*REUSE|REUSE.*${facet.name}`));
  }
  assert.match(output, /pinned historical runtime \(byte-identical/);
});

void test("a cut file may not aim a loan chain's cut at another diamond", async () => {
  rpc.reset();
  // the record is complete and correct, so the four record checks pass and the cut file is the
  // only thing left that could point the cut somewhere else
  for (const facet of PINNED_FACETS) {
    rpc.code.set(facet.address, ACCEPTED.get(facet.name)!);
  }
  const elsewhere = repoFor("sepolia", pinnedRecord(), { cut: { diamond: STRANGER } });
  const refused = await runCli(elsewhere, rpc.url, "sepolia", "planned");
  assert.notEqual(refused.status, 0, refused.output);
  assert.match(refused.output, /the loan-chain cut target .* must be the pinned MasterAccountController/);
  // the pinned controller as the target passes that gate and the plan goes on to the facets
  const permitted = repoFor("sepolia", pinnedRecord(), { cut: { diamond: pins.controllerAddress } });
  const second = await runCli(permitted, rpc.url, "sepolia", "planned");
  assert.doesNotMatch(second.output, /must be the pinned MasterAccountController/);
});

void test("the gate is a loan-chain rule: a Flare-family plan is not held to the pins", async () => {
  rpc.reset();
  rpc.chainId = COSTON2_CHAIN_ID;
  // the same record that failed every case above, on a chain that has no pinned bootstrap: the
  // planner may fail later for its own reasons, but never for a pin
  const record = pinnedRecord().map((item) => (item.name === "DiamondCutFacet" ? entry(item.name, STRANGER) : item));
  const { output } = await runCli(repoFor("coston2", record), rpc.url, "coston2");
  assert.doesNotMatch(output, /pinned base facet missing|pinned historical address|pinned historical runtime/);
});

void test("the pin fixtures are the repository's own pins, not a copy", () => {
  // the cases above are only about the pins if these are the pins: three base facets, each with a
  // real address and runtime hash, and a controller distinct from them
  assert.equal(PINNED_FACETS.length, 3);
  for (const facet of PINNED_FACETS) {
    assert.match(facet.address, /^0x[0-9a-f]{40}$/);
    assert.match(facet.runtimeCodeHash, /^0x[0-9a-f]{64}$/);
    assert.notEqual(facet.address, pins.controllerAddress);
    assert.notEqual(Web3.utils.keccak256("0x60016001").toLowerCase(), facet.runtimeCodeHash);
  }
});
