import assert from "node:assert/strict";
import { test } from "node:test";
import {
  type AccountIdentity,
  BEACON_SLOT,
  type ChainReader,
  encodeRegistration,
  IMPLEMENTATIONS,
  type ImplementationSpec,
  type RegistryTarget,
  type RepoReader,
  type Stage,
  SUBACCOUNT_TYPE_LOAN,
  type VerificationInputs,
  verifyImplementation,
} from "./implementation-verify";
import { type Check, allPassed } from "./diamond-verify";

const DIAMOND = "0x000000000000000000000000000000000000d1a0";
const IMPL = "0x0000000000000000000000000000000000001111";
const OTHER_IMPL = "0x0000000000000000000000000000000000002222";
const ACCOUNT = "0x00000000000000000000000000000000000aaaa1";
const SUBACCOUNT = "0x00000000000000000000000000000000000bbbb2";
const STRANGER = "0x000000000000000000000000000000000000bad0";
const OWNER = "rTestXrplOwner1111111111111111111";
const ETHEREUM = 1;
const FLARE = 14;

function fakeCode(name: string): Buffer {
  // no CBOR trailer, so the comparison works on the bytes as they are
  return Buffer.concat([Buffer.from("6080604052", "hex"), Buffer.from(name, "utf8")]);
}

const repo: RepoReader = {
  hasArtifact: () => true,
  hasSource: (name) => name in IMPLEMENTATIONS || name === "PersonalAccountProxy",
  deployedCode: fakeCode,
  creationCode: (name) => fakeCode(`creation:${name}`),
};

function word(address: string): string {
  return `0x${address.slice(2).toLowerCase().padStart(64, "0")}`;
}

/** A chain whose state a test mutates before verification. */
class FakeChain implements ChainReader {
  codes = new Map<string, string>();
  storageWords = new Map<string, string>();
  beaconImpl: string | undefined = IMPL;
  typeImpl: string | undefined = IMPL;
  queued = new Map<string, bigint>();
  duration: bigint | undefined = 3600n;
  accounts = new Map<string, string>([
    [`pa:${OWNER}`, ACCOUNT],
    [`sub:${OWNER}:${SUBACCOUNT_TYPE_LOAN}`, SUBACCOUNT],
  ]);
  identities = new Map<string, AccountIdentity>([
    [ACCOUNT, { controller: DIAMOND, xrplOwner: OWNER }],
    [SUBACCOUNT, { controller: DIAMOND, parent: ACCOUNT, subaccountType: BigInt(SUBACCOUNT_TYPE_LOAN) }],
  ]);

  constructor(contract = "PersonalAccountRemote") {
    this.codes.set(IMPL.toLowerCase(), `0x${fakeCode(contract).toString("hex")}`);
    // PersonalAccountProxy is an OZ BeaconProxy and records the beacon in the ERC-1967 slot
    this.codes.set(ACCOUNT.toLowerCase(), `0x${fakeCode("PersonalAccountProxy").toString("hex")}`);
    this.storageWords.set(`${ACCOUNT.toLowerCase()}:${BEACON_SLOT}`, word(DIAMOND));
    // SubaccountProxy is a plain proxy with immutables: that slot is never written
    this.codes.set(SUBACCOUNT.toLowerCase(), `0x${fakeCode("SubaccountProxy").toString("hex")}`);
  }

  /** Queues exactly the registration a stage-`queued` run expects to find. */
  queue(spec: ImplementationSpec, implementation: string, maturity = 1_800_000_000n): void {
    this.queued.set(encodeRegistration(spec, implementation).toLowerCase(), maturity);
  }

  code(address: string): Promise<string> {
    return Promise.resolve(this.codes.get(address.toLowerCase()) ?? "0x");
  }
  storage(address: string, slot: string): Promise<string> {
    return Promise.resolve(this.storageWords.get(`${address.toLowerCase()}:${slot}`) ?? word("0x0"));
  }
  registered(_diamond: string, spec: ImplementationSpec): Promise<string | undefined> {
    return Promise.resolve(spec.target === "personalAccountBeacon" ? this.beaconImpl : this.typeImpl);
  }
  timelockMaturity(_diamond: string, encodedCall: string): Promise<bigint> {
    return Promise.resolve(this.queued.get(encodedCall.toLowerCase()) ?? 0n);
  }
  timelockDuration(): Promise<bigint | undefined> {
    return Promise.resolve(this.duration);
  }
  personalAccount(_diamond: string, xrplOwner: string): Promise<string> {
    return Promise.resolve(this.accounts.get(`pa:${xrplOwner}`) ?? "0x0000000000000000000000000000000000000000");
  }
  subaccount(_diamond: string, xrplOwner: string, subaccountType: number): Promise<string> {
    return Promise.resolve(
      this.accounts.get(`sub:${xrplOwner}:${subaccountType}`) ?? "0x0000000000000000000000000000000000000000"
    );
  }
  accountIdentity(account: string, _target: RegistryTarget): Promise<AccountIdentity> {
    return Promise.resolve(this.identities.get(account) ?? { controller: STRANGER });
  }
}

function inputs(chain: FakeChain, overrides: Partial<VerificationInputs> = {}): VerificationInputs {
  return {
    network: "ethereum",
    chainId: ETHEREUM,
    diamond: DIAMOND,
    contract: "PersonalAccountRemote",
    implementation: IMPL,
    stage: "pre" as Stage,
    repo,
    chain,
    ...overrides,
  };
}

function failed(checks: Check[]): string[] {
  return checks.filter((entry) => !entry.ok).map((entry) => entry.name);
}

function actualOf(checks: Check[], name: string): string {
  const entry = checks.find((candidate) => candidate.name === name);
  assert.ok(entry, `no check named ${name}`);
  return entry.actual ?? "";
}

const CODE_CHECK = `code: PersonalAccountRemote at ${IMPL} matches the artifact`;
const BEACON_NOT_YET = "registry: the Personal Account beacon is not already the implementation";
const BEACON_LIVE = "registry: the Personal Account beacon points at the implementation";

void test("before queueing: the reviewed code, the right chain family, and the calldata to queue", async () => {
  const chain = new FakeChain();
  chain.beaconImpl = OTHER_IMPL;
  const result = await verifyImplementation(inputs(chain));
  assert.deepEqual(failed(result.checks), []);
  assert.equal(allPassed(result.checks), true);
  // the calldata is what governance must queue, and what the queued stage looks for
  assert.equal(
    result.encodedCall,
    `0xd2ea87ef${"0".repeat(24)}${IMPL.slice(2)}`,
    "setPersonalAccountImplementation(address) with the implementation as its only argument"
  );
  assert.ok(result.notes.some((note) => note.includes(`currently holds ${OTHER_IMPL}`)));
  assert.ok(result.notes.some((note) => note.includes("duration 3600 seconds")));
});

void test("a wrong runtime behind the address fails, at every stage", async () => {
  for (const stage of ["pre", "queued", "live"] as Stage[]) {
    const chain = new FakeChain();
    chain.codes.set(IMPL.toLowerCase(), `0x${fakeCode("PersonalAccountRemote-v2").toString("hex")}`);
    chain.queue(IMPLEMENTATIONS.PersonalAccountRemote!, IMPL);
    if (stage !== "live") {
      chain.beaconImpl = OTHER_IMPL;
    }
    const result = await verifyImplementation(inputs(chain, { stage }));
    assert.ok(failed(result.checks).includes(CODE_CHECK), `stage ${stage} missed the wrong runtime`);
    assert.match(actualOf(result.checks, CODE_CHECK), /^REPLACE/);
  }
});

void test("a codeless address, a missing artifact and a removed source each fail alone", async () => {
  const codeless = new FakeChain();
  codeless.codes.delete(IMPL.toLowerCase());
  codeless.beaconImpl = OTHER_IMPL;
  const codelessResult = await verifyImplementation(inputs(codeless));
  assert.deepEqual(failed(codelessResult.checks), [CODE_CHECK]);
  assert.equal(actualOf(codelessResult.checks, CODE_CHECK), "no code at the address");

  const missingArtifact = new FakeChain();
  missingArtifact.beaconImpl = OTHER_IMPL;
  const missingArtifactResult = await verifyImplementation(
    inputs(missingArtifact, { repo: { ...repo, hasArtifact: () => false } })
  );
  assert.deepEqual(failed(missingArtifactResult.checks), [CODE_CHECK]);
  assert.match(actualOf(missingArtifactResult.checks, CODE_CHECK), /missing artifact for PersonalAccountRemote/);

  const removed = new FakeChain();
  removed.beaconImpl = OTHER_IMPL;
  const removedResult = await verifyImplementation(inputs(removed, { repo: { ...repo, hasSource: () => false } }));
  assert.deepEqual(failed(removedResult.checks), ["source: PersonalAccountRemote still exists in contracts/"]);
});

void test("an implementation on the wrong chain family is refused, in both directions", async () => {
  // a remote implementation on Flare would corrupt every Personal Account's storage
  const onFlare = new FakeChain();
  onFlare.beaconImpl = OTHER_IMPL;
  const remoteOnFlare = await verifyImplementation(inputs(onFlare, { network: "flare", chainId: FLARE }));
  assert.deepEqual(failed(remoteOnFlare.checks), ["chain: PersonalAccountRemote belongs on flare (chain 14)"]);
  assert.match(
    actualOf(remoteOnFlare.checks, "chain: PersonalAccountRemote belongs on flare (chain 14)"),
    /lays out the remote lineage's storage/
  );
  // and the Flare Personal Account does not belong on Ethereum
  const flareOnEthereum = new FakeChain("PersonalAccount");
  flareOnEthereum.beaconImpl = OTHER_IMPL;
  const result = await verifyImplementation(inputs(flareOnEthereum, { contract: "PersonalAccount" }));
  assert.deepEqual(failed(result.checks), ["chain: PersonalAccount belongs on ethereum (chain 1)"]);
  // each on its own chain passes
  const flareHome = new FakeChain("PersonalAccount");
  flareHome.beaconImpl = OTHER_IMPL;
  assert.deepEqual(
    failed(
      (await verifyImplementation(inputs(flareHome, { contract: "PersonalAccount", network: "flare", chainId: FLARE })))
        .checks
    ),
    []
  );
});

void test("queued: only this exact calldata counts, and the duration must be non-zero", async () => {
  const spec = IMPLEMENTATIONS.PersonalAccountRemote!;
  const queued = new FakeChain();
  queued.beaconImpl = OTHER_IMPL;
  queued.queue(spec, IMPL);
  const result = await verifyImplementation(inputs(queued, { stage: "queued" }));
  assert.deepEqual(failed(result.checks), []);
  assert.ok(result.notes.some((note) => note.includes("executable after 1800000000")));

  // a queued registration naming another address is not this registration
  const wrongAddress = new FakeChain();
  wrongAddress.beaconImpl = OTHER_IMPL;
  wrongAddress.queue(spec, OTHER_IMPL);
  const wrongResult = await verifyImplementation(inputs(wrongAddress, { stage: "queued" }));
  assert.deepEqual(failed(wrongResult.checks), ["timelock: exactly this registration is queued"]);
  assert.match(actualOf(wrongResult.checks, "timelock: exactly this registration is queued"), /another address/);

  // a registration queued for the other registry is not this one either
  const wrongTarget = new FakeChain();
  wrongTarget.beaconImpl = OTHER_IMPL;
  wrongTarget.queue(IMPLEMENTATIONS.LoanSubaccountRemote!, IMPL);
  assert.deepEqual(failed((await verifyImplementation(inputs(wrongTarget, { stage: "queued" }))).checks), [
    "timelock: exactly this registration is queued",
  ]);

  // a zero timelock would let the registration execute in the same breath as it is queued
  const instant = new FakeChain();
  instant.beaconImpl = OTHER_IMPL;
  instant.queue(spec, IMPL);
  instant.duration = 0n;
  assert.deepEqual(failed((await verifyImplementation(inputs(instant, { stage: "queued" }))).checks), [
    "timelock: the duration is non-zero",
  ]);
});

void test("before it is live, an already-registered implementation says so", async () => {
  for (const stage of ["pre", "queued"] as Stage[]) {
    const chain = new FakeChain();
    chain.queue(IMPLEMENTATIONS.PersonalAccountRemote!, IMPL);
    const result = await verifyImplementation(inputs(chain, { stage }));
    assert.ok(failed(result.checks).includes(BEACON_NOT_YET), `stage ${stage}`);
    assert.match(actualOf(result.checks, BEACON_NOT_YET), /already registered/);
  }
});

void test("live: the registry must point at the implementation", async () => {
  assert.deepEqual(failed((await verifyImplementation(inputs(new FakeChain(), { stage: "live" }))).checks), []);
  const elsewhere = new FakeChain();
  elsewhere.beaconImpl = OTHER_IMPL;
  const result = await verifyImplementation(inputs(elsewhere, { stage: "live" }));
  assert.deepEqual(failed(result.checks), [BEACON_LIVE]);
  assert.equal(actualOf(result.checks, BEACON_LIVE), OTHER_IMPL);
});

void test("the subaccount registry is read for its own type", async () => {
  const chain = new FakeChain("LoanSubaccountRemote");
  const asLoan = { contract: "LoanSubaccountRemote", stage: "live" as Stage };
  assert.deepEqual(failed((await verifyImplementation(inputs(chain, asLoan))).checks), []);
  // the beacon holding the right address does not make the type registry right
  chain.typeImpl = OTHER_IMPL;
  assert.deepEqual(failed((await verifyImplementation(inputs(chain, asLoan))).checks), [
    "registry: subaccount type 1 points at the implementation",
  ]);
});

void test("live with a sample account: beacon, controller, owner, parent and type are read back", async () => {
  const honest = new FakeChain();
  assert.deepEqual(
    failed((await verifyImplementation(inputs(honest, { stage: "live", sampleXrplOwner: OWNER }))).checks),
    []
  );

  // a proxy that does not point at this controller as its beacon
  const wrongBeacon = new FakeChain();
  wrongBeacon.storageWords.set(`${ACCOUNT.toLowerCase()}:${BEACON_SLOT}`, word(STRANGER));
  assert.deepEqual(
    failed((await verifyImplementation(inputs(wrongBeacon, { stage: "live", sampleXrplOwner: OWNER }))).checks),
    [`sample: ${ACCOUNT} is served by this controller as its beacon`]
  );

  // an account that reports another controller, and one initialized for another owner
  const wrongController = new FakeChain();
  wrongController.identities.set(ACCOUNT, { controller: STRANGER, xrplOwner: OWNER });
  assert.deepEqual(
    failed((await verifyImplementation(inputs(wrongController, { stage: "live", sampleXrplOwner: OWNER }))).checks),
    [`sample: ${ACCOUNT} reports this controller`]
  );
  const wrongOwner = new FakeChain();
  wrongOwner.identities.set(ACCOUNT, { controller: DIAMOND, xrplOwner: "rSomebodyElse" });
  const ownerResult = await verifyImplementation(inputs(wrongOwner, { stage: "live", sampleXrplOwner: OWNER }));
  assert.deepEqual(failed(ownerResult.checks), [`sample: ${ACCOUNT} was initialized for ${OWNER}`]);
  assert.equal(actualOf(ownerResult.checks, `sample: ${ACCOUNT} was initialized for ${OWNER}`), "rSomebodyElse");

  // asking for a sample that does not exist fails the request instead of passing quietly:
  // omitting --xrpl-owner is how a registry-only verification is asked for
  const empty = new FakeChain();
  empty.codes.delete(ACCOUNT.toLowerCase());
  const emptyResult = await verifyImplementation(inputs(empty, { stage: "live", sampleXrplOwner: OWNER }));
  assert.deepEqual(failed(emptyResult.checks), [`sample: ${OWNER}'s account at ${ACCOUNT} is materialized`]);
  assert.match(
    actualOf(emptyResult.checks, `sample: ${OWNER}'s account at ${ACCOUNT} is materialized`),
    /drop --xrpl-owner to verify the registry alone/
  );
  // and none of the identity checks are reported when there is nothing to read
  assert.equal(emptyResult.checks.filter((entry) => entry.name.includes("reports this controller")).length, 0);
});

void test("a sample subaccount's parent and type are checked, not just its controller", async () => {
  const asLoan = { contract: "LoanSubaccountRemote", stage: "live" as Stage, sampleXrplOwner: OWNER };
  const honest = new FakeChain("LoanSubaccountRemote");
  assert.deepEqual(failed((await verifyImplementation(inputs(honest, asLoan))).checks), []);

  const wrongParent = new FakeChain("LoanSubaccountRemote");
  wrongParent.identities.set(SUBACCOUNT, {
    controller: DIAMOND,
    parent: STRANGER,
    subaccountType: BigInt(SUBACCOUNT_TYPE_LOAN),
  });
  assert.deepEqual(failed((await verifyImplementation(inputs(wrongParent, asLoan))).checks), [
    `sample: ${SUBACCOUNT}'s parent is ${OWNER}'s Personal Account`,
  ]);

  const wrongType = new FakeChain("LoanSubaccountRemote");
  wrongType.identities.set(SUBACCOUNT, { controller: DIAMOND, parent: ACCOUNT, subaccountType: 7n });
  const typeResult = await verifyImplementation(inputs(wrongType, asLoan));
  assert.deepEqual(failed(typeResult.checks), [`sample: ${SUBACCOUNT} is of type 1`]);
  assert.equal(actualOf(typeResult.checks, `sample: ${SUBACCOUNT} is of type 1`), "7");
});

void test("meaningless inputs are refused rather than verified", async () => {
  const chain = new FakeChain();
  await assert.rejects(
    verifyImplementation(inputs(chain, { contract: "GhostAccount" })),
    /GhostAccount is not a registered implementation/
  );
  await assert.rejects(verifyImplementation(inputs(chain, { implementation: "0xdead" })), /is not an address/);
  await assert.rejects(
    verifyImplementation(inputs(chain, { implementation: DIAMOND })),
    /cannot be the controller itself/
  );
  await assert.rejects(
    verifyImplementation(inputs(chain, { stage: "queued", sampleXrplOwner: OWNER })),
    /a sample account can only be checked once the registration is live/
  );
});

void test("the encoded registration matches the setters' signatures", () => {
  // the selectors are the setters' own, as `cast sig` reports them:
  // setPersonalAccountImplementation(address) = 0xd2ea87ef
  // setSubaccountImplementation(uint256,address) = 0x7468497f
  assert.equal(
    encodeRegistration(IMPLEMENTATIONS.PersonalAccount!, IMPL),
    `0xd2ea87ef${"0".repeat(24)}${IMPL.slice(2)}`
  );
  assert.equal(
    encodeRegistration(IMPLEMENTATIONS.LoanSubaccount!, IMPL),
    `0x7468497f${"0".repeat(63)}1${"0".repeat(24)}${IMPL.slice(2)}`
  );
  // both remote variants register through the same setters as their Flare twins
  assert.equal(
    encodeRegistration(IMPLEMENTATIONS.PersonalAccountRemote!, IMPL),
    encodeRegistration(IMPLEMENTATIONS.PersonalAccount!, IMPL)
  );
  assert.equal(
    encodeRegistration(IMPLEMENTATIONS.LoanSubaccountRemote!, IMPL),
    encodeRegistration(IMPLEMENTATIONS.LoanSubaccount!, IMPL)
  );
});

void test("a registry whose facet is not cut is a named failure, not a crash", async () => {
  // what the Coston2 dry run hit: implementationForType reverts FunctionNotFound because
  // SubaccountsFacet is not cut there yet, so there is nothing to register into
  const uncut = new FakeChain("LoanSubaccountRemote");
  uncut.typeImpl = undefined;
  for (const stage of ["pre", "queued", "live"] as Stage[]) {
    const result = await verifyImplementation(inputs(uncut, { contract: "LoanSubaccountRemote", stage }));
    assert.ok(
      failed(result.checks).includes("registry: SubaccountsFacet is cut on the controller"),
      `stage ${stage} did not report the uncut registry`
    );
    assert.match(
      actualOf(result.checks, "registry: SubaccountsFacet is cut on the controller"),
      /does not serve it - cut SubaccountsFacet first/
    );
  }
  // the Personal Account registry names its own facet
  const noBeacon = new FakeChain();
  noBeacon.beaconImpl = undefined;
  assert.ok(
    failed((await verifyImplementation(inputs(noBeacon))).checks).includes(
      "registry: PersonalAccountsFacet is cut on the controller"
    )
  );
});

void test("an uncut timelock facet fails the duration check instead of crashing", async () => {
  const chain = new FakeChain();
  chain.beaconImpl = OTHER_IMPL;
  chain.queue(IMPLEMENTATIONS.PersonalAccountRemote!, IMPL);
  chain.duration = undefined;
  const result = await verifyImplementation(inputs(chain, { stage: "queued" }));
  assert.deepEqual(failed(result.checks), ["timelock: the duration is non-zero"]);
  assert.equal(
    actualOf(result.checks, "timelock: the duration is non-zero"),
    "TimelockFacet is not cut on the controller"
  );
  // at `pre` it fails the same check, since the calldata this run prints would register
  // immediately rather than queue
  const pre = new FakeChain();
  pre.beaconImpl = OTHER_IMPL;
  pre.duration = undefined;
  const preResult = await verifyImplementation(inputs(pre));
  assert.deepEqual(failed(preResult.checks), ["timelock: the duration is non-zero"]);
  assert.ok(preResult.notes.some((note) => note.includes("TimelockFacet is not cut")));
  // once live the timelock no longer bears on this registration, so it is only a note
  const live = new FakeChain();
  live.duration = undefined;
  const liveResult = await verifyImplementation(inputs(live, { stage: "live" }));
  assert.deepEqual(failed(liveResult.checks), []);
  assert.ok(liveResult.notes.some((note) => note.includes("TimelockFacet is not cut")));
});

void test("a real subaccount proxy has no beacon slot, and is verified without one", async () => {
  // SubaccountProxy is a plain proxy: it holds the controller and the type as immutables and
  // resolves implementationForType on every call, so there is no ERC-1967 slot to read. A slot
  // check here would fail every valid loan subaccount
  const chain = new FakeChain("LoanSubaccountRemote");
  assert.equal(
    await chain.storage(SUBACCOUNT, BEACON_SLOT),
    `0x${"0".repeat(64)}`,
    "the fake must model the real proxy: no beacon slot"
  );
  const result = await verifyImplementation(
    inputs(chain, { contract: "LoanSubaccountRemote", stage: "live", sampleXrplOwner: OWNER })
  );
  assert.deepEqual(failed(result.checks), []);
  assert.equal(
    result.checks.filter((entry) => entry.name.includes("as its beacon")).length,
    0,
    "no beacon-slot check for a subaccount"
  );
  // the Personal Account's proxy does record it, and that check stays
  const pa = new FakeChain();
  const paResult = await verifyImplementation(inputs(pa, { stage: "live", sampleXrplOwner: OWNER }));
  assert.equal(paResult.checks.filter((entry) => entry.name.includes("as its beacon")).length, 1);
});

void test("a missing sample subaccount fails the request too", async () => {
  const chain = new FakeChain("LoanSubaccountRemote");
  chain.codes.delete(SUBACCOUNT.toLowerCase());
  const result = await verifyImplementation(
    inputs(chain, { contract: "LoanSubaccountRemote", stage: "live", sampleXrplOwner: OWNER })
  );
  assert.deepEqual(failed(result.checks), [`sample: ${OWNER}'s account at ${SUBACCOUNT} is materialized`]);
});

void test("a zero timelock duration is caught before the call is handed to governance", async () => {
  // at `pre` the run prints a calldata to queue; with a zero delay that call is not a queue
  // step at all, it registers immediately, so this has to be known before handing it over
  const chain = new FakeChain();
  chain.beaconImpl = OTHER_IMPL;
  chain.duration = 0n;
  assert.deepEqual(failed((await verifyImplementation(inputs(chain))).checks), ["timelock: the duration is non-zero"]);
  // and once it is live the duration no longer bears on this registration
  const live = new FakeChain();
  live.duration = 0n;
  const liveResult = await verifyImplementation(inputs(live, { stage: "live" }));
  assert.deepEqual(failed(liveResult.checks), []);
  assert.equal(liveResult.checks.filter((entry) => entry.name.startsWith("timelock:")).length, 0);
});
