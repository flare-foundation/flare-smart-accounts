import assert from "node:assert/strict";
import { test } from "node:test";
import Web3 from "web3";
import type { CutConfig, DeployedContract, LoupeFacet } from "../../deployment/utils/diamond-inspect";
import { type Check, allPassed, dispatchSlot } from "../../deployment/utils/diamond-verify";
import {
  type ChainReader,
  type RepoReader,
  type VerificationInputs,
  verifyDiamond,
} from "../../deployment/utils/diamond-verifier";
import type { PinnedEthereumAddresses } from "../../deployment/utils/pinned-constants";

// A small diamond: the three base facets and one application facet, each with a distinct fake
// runtime, a controller, and the proxy whose creation code the comparison strips.
const DIAMOND = "0x000000000000000000000000000000000000d1a0";
const OWNER = "0x0000000000000000000000000000000000000e0e";
const STRANGER = "0x000000000000000000000000000000000000bad0";
const ADDRESSES: Record<string, string> = {
  DiamondCutFacet: "0x0000000000000000000000000000000000000c01",
  DiamondLoupeFacet: "0x0000000000000000000000000000000000000c02",
  OwnershipFacet: "0x0000000000000000000000000000000000000c03",
  PauseFacet: "0x0000000000000000000000000000000000000c04",
};
const SELECTORS: Record<string, string[]> = {
  DiamondCutFacet: ["0x1f931c1c"],
  DiamondLoupeFacet: ["0x7a0ed627", "0xadfca15e", "0x52ef6b2c", "0xcdffacc6", "0x01ffc9a7"],
  OwnershipFacet: ["0x8da5cb5b", "0xf2fde38b"],
  PauseFacet: ["0xaaaa0001", "0xaaaa0002"],
  IERC165: ["0x01ffc9a7"],
  IDiamondCut: ["0x1f931c1c"],
  IDiamondLoupe: ["0x7a0ed627", "0xadfca15e", "0x52ef6b2c", "0xcdffacc6"],
  IERC173: ["0x8da5cb5b", "0xf2fde38b"],
};
const FLAG_IDS = ["0x01ffc9a7", "0x1f931c1c", "0x48e2b093", "0x7f5828d0"];

function fakeCode(name: string): Buffer {
  // no CBOR trailer, so the comparison works on the bytes as they are
  return Buffer.concat([Buffer.from("6080604052", "hex"), Buffer.from(name, "utf8")]);
}

const repo: RepoReader = {
  abiSelectors: (name) => SELECTORS[name] ?? [],
  hasArtifact: () => true,
  hasSource: (name) => name in ADDRESSES,
  deployedCode: fakeCode,
  creationCode: (name) => fakeCode(`creation:${name}`),
};

const record: DeployedContract[] = [
  { name: "MasterAccountController", contractName: "MasterAccountController.sol", address: DIAMOND },
  ...Object.entries(ADDRESSES).map(([name, address]) => ({ name, contractName: `${name}.sol`, address })),
];

function word(address: string): string {
  return `0x${address.slice(2).toLowerCase().padStart(64, "0")}`;
}

/** A chain whose state a test mutates before verification. */
class FakeChain implements ChainReader {
  codes = new Map<string, string>();
  storageWords = new Map<string, string>();
  loupe: LoupeFacet[] = [];
  ownerValue = OWNER;
  flags = new Set<string>(FLAG_IDS);

  constructor(facets: string[]) {
    this.codes.set(DIAMOND.toLowerCase(), `0x${fakeCode("MasterAccountController").toString("hex")}`);
    for (const name of facets) {
      const address = ADDRESSES[name]!;
      this.codes.set(address.toLowerCase(), `0x${fakeCode(name).toString("hex")}`);
      for (const selector of SELECTORS[name]!) {
        this.route(selector, address);
      }
      this.loupe.push({ facetAddress: address, functionSelectors: [...SELECTORS[name]!] });
    }
  }

  route(selector: string, facet: string): void {
    this.storageWords.set(`${DIAMOND.toLowerCase()}:${dispatchSlot(selector)}`, word(facet));
  }

  code(address: string): Promise<string> {
    return Promise.resolve(this.codes.get(address.toLowerCase()) ?? "0x");
  }
  storage(address: string, slot: string): Promise<string> {
    return Promise.resolve(this.storageWords.get(`${address.toLowerCase()}:${slot}`) ?? word("0x0"));
  }
  loupeFacets(): Promise<LoupeFacet[]> {
    return Promise.resolve(this.loupe);
  }
  owner(): Promise<string> {
    return Promise.resolve(this.ownerValue);
  }
  supportsInterface(_diamond: string, id: string): Promise<boolean> {
    return Promise.resolve(this.flags.has(id));
  }
}

const ALL = Object.keys(ADDRESSES);
const BASE = ["DiamondCutFacet", "DiamondLoupeFacet", "OwnershipFacet"];

function inputs(chain: FakeChain, overrides: Partial<VerificationInputs> = {}): VerificationInputs {
  return { network: "coston2", preCut: false, record, expectOwner: OWNER, repo, chain, ...overrides };
}

function failed(checks: Check[]): string[] {
  return checks.filter((entry) => !entry.ok).map((entry) => entry.name);
}

function actualOf(checks: Check[], name: string): string {
  const entry = checks.find((candidate) => candidate.name === name);
  assert.ok(entry, `no check named ${name}`);
  return entry.actual ?? "";
}

const PAUSE_CODE_CHECK = `code: PauseFacet at ${ADDRESSES.PauseFacet} matches the artifact`;
const CONTROLLER_CODE_CHECK = `code: MasterAccountController at ${DIAMOND} matches the artifact`;

void test("an honest, complete diamond passes every check", async () => {
  const result = await verifyDiamond(inputs(new FakeChain(ALL)));
  assert.equal(result.diamond, DIAMOND);
  assert.deepEqual(failed(result.checks), []);
  assert.equal(allPassed(result.checks), true);
  assert.deepEqual(result.notes, []);
});

void test("a forged loupe cannot pass: the dispatch table names the real responder", async () => {
  // the loupe answer is perfect, but storage says facets() is served by a stranger
  const chain = new FakeChain(ALL);
  chain.route("0x7a0ed627", STRANGER);
  const result = await verifyDiamond(inputs(chain));
  assert.deepEqual(failed(result.checks), ["dispatch: facets() is served by DiamondLoupeFacet (storage)"]);
  assert.equal(allPassed(result.checks), false);
});

void test("each responder the verifier relies on is authenticated on its own", async () => {
  const ownerForged = new FakeChain(ALL);
  ownerForged.route("0x8da5cb5b", STRANGER);
  assert.deepEqual(failed((await verifyDiamond(inputs(ownerForged))).checks), [
    "dispatch: owner() is served by OwnershipFacet (storage)",
  ]);
  const flagsForged = new FakeChain(ALL);
  flagsForged.route("0x01ffc9a7", STRANGER);
  assert.deepEqual(failed((await verifyDiamond(inputs(flagsForged))).checks), [
    "dispatch: supportsInterface(bytes4) is served by DiamondLoupeFacet (storage)",
  ]);
});

void test("off Ethereum the diamond's own code is compared with the controller artifact", async () => {
  const chain = new FakeChain(ALL);
  chain.codes.set(DIAMOND.toLowerCase(), `0x${fakeCode("MasterAccountController-v2").toString("hex")}`);
  const result = await verifyDiamond(inputs(chain));
  assert.deepEqual(failed(result.checks), [CONTROLLER_CODE_CHECK]);
  assert.match(actualOf(result.checks, CONTROLLER_CODE_CHECK), /^REPLACE/);
});

void test("a codeless address and a missing artifact fail the code check with their reason", async () => {
  const codeless = new FakeChain(ALL);
  codeless.codes.delete(ADDRESSES.PauseFacet!.toLowerCase());
  const codelessResult = await verifyDiamond(inputs(codeless));
  assert.deepEqual(failed(codelessResult.checks), [PAUSE_CODE_CHECK]);
  assert.equal(actualOf(codelessResult.checks, PAUSE_CODE_CHECK), "no code");
  const missingArtifact = { ...repo, hasArtifact: (name: string) => name !== "PauseFacet" };
  const missingArtifactResult = await verifyDiamond(inputs(new FakeChain(ALL), { repo: missingArtifact }));
  assert.deepEqual(failed(missingArtifactResult.checks), [PAUSE_CODE_CHECK]);
  assert.match(actualOf(missingArtifactResult.checks, PAUSE_CODE_CHECK), /missing artifact for PauseFacet/);
});

void test("a facet whose source left the repository is reported even with its artifact present", async () => {
  const removed = { ...repo, hasSource: (name: string) => name !== "PauseFacet" };
  assert.deepEqual(failed((await verifyDiamond(inputs(new FakeChain(ALL), { repo: removed }))).checks), [
    "source: PauseFacet still exists in contracts/",
  ]);
});

void test("0xffffffff answered as supported is a failure of its own", async () => {
  const chain = new FakeChain(ALL);
  chain.flags.add("0xffffffff");
  assert.deepEqual(failed((await verifyDiamond(inputs(chain))).checks), ["erc165: 0xffffffff is not supported"]);
});

void test("a facet with the right selectors but the wrong runtime fails the code check", async () => {
  const chain = new FakeChain(ALL);
  chain.codes.set(ADDRESSES.PauseFacet!.toLowerCase(), `0x${fakeCode("PauseFacet-v2").toString("hex")}`);
  const result = await verifyDiamond(inputs(chain));
  assert.deepEqual(failed(result.checks), [`code: PauseFacet at ${ADDRESSES.PauseFacet} matches the artifact`]);
});

void test("missing, misrouted and unexpected selectors and a stranger facet are reported", async () => {
  const chain = new FakeChain(ALL);
  chain.loupe = [
    ...chain.loupe.filter((facet) => facet.facetAddress !== ADDRESSES.PauseFacet),
    { facetAddress: ADDRESSES.PauseFacet!, functionSelectors: ["0xaaaa0001"] },
    { facetAddress: STRANGER, functionSelectors: ["0xdeadbeef", "0xf2fde38b"] },
  ];
  chain.loupe.find((facet) => facet.facetAddress === ADDRESSES.OwnershipFacet)!.functionSelectors = ["0x8da5cb5b"];
  const result = await verifyDiamond(inputs(chain));
  assert.deepEqual(failed(result.checks), [
    "selectors: every expected selector is live",
    "selectors: every expected selector routes to its facet",
    "selectors: no live selector outside the expected set",
    "facets: no live facet outside the expected set",
  ]);
});

void test("an explicit deletion is expected gone, and a leftover dispatch entry is caught", async () => {
  const cut: CutConfig = { diamond: DIAMOND, facets: ["PauseFacet"], deleteSelectorSigs: ["0xaaaa0002"] };
  // executed cut: the selector is gone from the loupe and from storage
  const clean = new FakeChain(ALL);
  clean.loupe.find((facet) => facet.facetAddress === ADDRESSES.PauseFacet)!.functionSelectors = ["0xaaaa0001"];
  clean.storageWords.delete(`${DIAMOND.toLowerCase()}:${dispatchSlot("0xaaaa0002")}`);
  assert.deepEqual(failed((await verifyDiamond(inputs(clean, { cut }))).checks), []);
  // the loupe no longer lists it, but its mapping entry was left behind
  const leftover = new FakeChain(ALL);
  leftover.loupe.find((facet) => facet.facetAddress === ADDRESSES.PauseFacet)!.functionSelectors = ["0xaaaa0001"];
  assert.deepEqual(failed((await verifyDiamond(inputs(leftover, { cut }))).checks), [
    "dispatch: deleted selectors have no dispatch entry",
  ]);
});

void test("deleteAllOldMethods narrows the surface to the cut's facets and ignores deleteSelectorSigs", async () => {
  // the cut keeps the base facets only: a still-live PauseFacet is unexpected
  const narrowing: CutConfig = { diamond: DIAMOND, facets: BASE, deleteAllOldMethods: true };
  const stale = new FakeChain(ALL);
  assert.deepEqual(failed((await verifyDiamond(inputs(stale, { cut: narrowing }))).checks), [
    "selectors: no live selector outside the expected set",
    "facets: no live facet outside the expected set",
  ]);
  const executed = new FakeChain(BASE);
  assert.deepEqual(failed((await verifyDiamond(inputs(executed, { cut: narrowing }))).checks), []);
  // with PauseFacet in the cut, a listed deleteSelectorSigs entry is ignored: the selector stays expected
  const keeping: CutConfig = {
    diamond: DIAMOND,
    facets: ALL,
    deleteAllOldMethods: true,
    deleteSelectorSigs: ["0xaaaa0002"],
  };
  assert.deepEqual(failed((await verifyDiamond(inputs(new FakeChain(ALL), { cut: keeping }))).checks), []);
  // a cut that drops a base facet is flagged before anything else
  const bricking: CutConfig = { diamond: DIAMOND, facets: ["PauseFacet"], deleteAllOldMethods: true };
  assert.ok(
    failed((await verifyDiamond(inputs(new FakeChain(ALL), { cut: bricking }))).checks).includes(
      "cut: deleteAllOldMethods keeps the base facets"
    )
  );
});

void test("pre-cut expects the base facets alone and no flag", async () => {
  const pristine = new FakeChain(BASE);
  pristine.flags.clear();
  assert.deepEqual(failed((await verifyDiamond(inputs(pristine, { preCut: true }))).checks), []);
  const flagged = new FakeChain(BASE);
  const result = await verifyDiamond(inputs(flagged, { preCut: true }));
  assert.deepEqual(
    failed(result.checks),
    FLAG_IDS.map(
      (id, i) => `erc165: ${["IERC165", "IDiamondCut", "IDiamondLoupe", "IERC173"][i]} (${id}) not yet supported`
    )
  );
  await assert.rejects(
    verifyDiamond(inputs(pristine, { preCut: true, cut: { diamond: DIAMOND } })),
    /--pre-cut takes no cut file/
  );
});

void test("the owner is checked against the expectation, or only reported without one", async () => {
  const chain = new FakeChain(ALL);
  chain.ownerValue = STRANGER;
  assert.deepEqual(failed((await verifyDiamond(inputs(chain))).checks), ["owner"]);
  const { expectOwner: _ignored, ...withoutExpectation } = inputs(chain);
  const unchecked = await verifyDiamond(withoutExpectation);
  assert.deepEqual(failed(unchecked.checks), []);
  assert.match(unchecked.notes[0]!, /no expectation available/);
});

void test("a cut file aiming at another diamond, or a record without the base facets, is refused", async () => {
  await assert.rejects(
    verifyDiamond(inputs(new FakeChain(ALL), { cut: { diamond: STRANGER } })),
    /the cut file targets .* but deployment\/deploys\/coston2.json records the controller/
  );
  await assert.rejects(
    verifyDiamond(inputs(new FakeChain(ALL), { cut: { diamond: DIAMOND, facets: ["GhostFacet"] } })),
    /GhostFacet is in the cut file but not in deployment/
  );
  await assert.rejects(
    verifyDiamond(inputs(new FakeChain(ALL), { record: record.filter((entry) => entry.name !== "OwnershipFacet") })),
    /OwnershipFacet is missing/
  );
});

void test("on Ethereum the pins are checked and the base facets' code is hashed against them", async () => {
  const chain = new FakeChain(ALL);
  const pins: PinnedEthereumAddresses = {
    controllerAddress: DIAMOND,
    controllerRuntimeCodeHash: Web3.utils.keccak256(`0x${fakeCode("MasterAccountController").toString("hex")}`),
    initialOwner: OWNER,
    baseFacets: new Map(
      BASE.map((name) => [
        name,
        { address: ADDRESSES[name]!, runtimeCodeHash: Web3.utils.keccak256(`0x${fakeCode(name).toString("hex")}`) },
      ])
    ),
  };
  assert.deepEqual(failed((await verifyDiamond(inputs(chain, { network: "ethereum", pins }))).checks), []);
  chain.codes.set(ADDRESSES.OwnershipFacet!.toLowerCase(), `0x${fakeCode("OwnershipFacet-tampered").toString("hex")}`);
  assert.deepEqual(failed((await verifyDiamond(inputs(chain, { network: "ethereum", pins }))).checks), [
    "pins: OwnershipFacet on-chain code hashes to the pin",
  ]);
  // under pins the controller is hashed against its pin, not compared with the artifact
  const controllerTampered = new FakeChain(ALL);
  controllerTampered.codes.set(DIAMOND.toLowerCase(), `0x${fakeCode("MasterAccountController-v2").toString("hex")}`);
  assert.deepEqual(failed((await verifyDiamond(inputs(controllerTampered, { network: "ethereum", pins }))).checks), [
    "pins: the controller's on-chain code hashes to the pin",
  ]);
  // a record whose controller is not the pinned one fails the address pin alone
  const elsewhere: PinnedEthereumAddresses = { ...pins, controllerAddress: STRANGER };
  assert.deepEqual(
    failed((await verifyDiamond(inputs(new FakeChain(ALL), { network: "ethereum", pins: elsewhere }))).checks),
    ["pins: the diamond is the pinned controller"]
  );
  // a base facet recorded away from its pin fails the address pin, and the pin's address has no code to hash
  const moved: PinnedEthereumAddresses = {
    ...pins,
    baseFacets: new Map([
      ...pins.baseFacets,
      ["OwnershipFacet", { ...pins.baseFacets.get("OwnershipFacet")!, address: STRANGER }],
    ]),
  };
  const movedResult = await verifyDiamond(inputs(new FakeChain(ALL), { network: "ethereum", pins: moved }));
  assert.deepEqual(failed(movedResult.checks), [
    "pins: OwnershipFacet recorded at the pinned address",
    "pins: OwnershipFacet on-chain code hashes to the pin",
  ]);
  assert.equal(actualOf(movedResult.checks, "pins: OwnershipFacet on-chain code hashes to the pin"), "<no code>");
});
