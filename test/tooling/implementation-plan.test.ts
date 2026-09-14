/**
 * What a remote-implementation deploy decides to do, over the record and the chain.
 *
 * The decision is the whole point of the preflight: once one implementation is live, redeploying
 * it because the other changed replaces a record other tooling resolves through, and buys a
 * pointless timelocked re-registration. So the rule under test is that a selected implementation
 * whose recorded address already carries this code is SKIPPED — a successful skip, not a failure —
 * while everything else still deploys.
 */
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  ALL,
  REMOTE_IMPLEMENTATIONS,
  contractsToDeploy,
  formatPlan,
  knownSlugs,
  planRemoteImplementations,
  resolveSelection,
  type RecordedImplementation,
} from "../../deployment/utils/implementation-plan";

const PERSONAL_ACCOUNT = "PersonalAccountRemote";
const LOAN_SUBACCOUNT = "MorphoLoanSubaccountRemote";
const PERSONAL_ACCOUNT_RECORD = "PersonalAccountRemoteImplementation";
const LOAN_SUBACCOUNT_RECORD = "MorphoLoanSubaccountRemoteImplementation";

const PA_ADDRESS = "0x00000000000000000000000000000000000000aa";
const LS_ADDRESS = "0x00000000000000000000000000000000000000bb";
const ZERO = "0x0000000000000000000000000000000000000000";

/**
 * A runtime with a well-formed metadata trailer, so the comparison exercises the stripping rather
 * than plain equality. The last two bytes are the trailer's own length, as solc writes it.
 */
function runtime(body: string, metadata: string): Buffer {
  const trailer = Buffer.from(metadata, "hex");
  const length = Buffer.alloc(2);
  length.writeUInt16BE(trailer.length);
  return Buffer.concat([Buffer.from(body, "hex"), trailer, length]);
}

const PA_CODE = runtime("60806040aaaa", "a264697066735822abababab");
const PA_CODE_REBUILT = runtime("60806040aaaa", "a264697066735822cdcdcdcd");
const PA_CODE_CHANGED = runtime("60806040aaff", "a264697066735822abababab");
const LS_CODE = runtime("60806040bbbb", "a264697066735822abababab");

interface Scenario {
  selection: string;
  record?: RecordedImplementation[];
  onChain?: Record<string, Buffer>;
  artifacts?: Record<string, Buffer>;
  registered?: Record<string, string>;
}

function plan(scenario: Scenario) {
  const artifacts = scenario.artifacts ?? { [PERSONAL_ACCOUNT]: PA_CODE, [LOAN_SUBACCOUNT]: LS_CODE };
  const onChain = scenario.onChain ?? {};
  return planRemoteImplementations({
    selection: scenario.selection,
    record: scenario.record ?? [],
    artifactCode: (contract) => {
      const code = artifacts[contract];
      assert.ok(code !== undefined, `no artifact fixture for ${contract}`);
      return code;
    },
    code: (address) => {
      const code = onChain[address.toLowerCase()];
      return Promise.resolve(code === undefined ? "0x" : `0x${code.toString("hex")}`);
    },
    ...(scenario.registered !== undefined
      ? { registered: (contract: string) => Promise.resolve(scenario.registered?.[contract]) }
      : {}),
  });
}

void test("a first deployment deploys everything the caller named", async () => {
  const result = await plan({ selection: ALL });
  assert.deepEqual(
    result.entries.map((entry) => [entry.contract, entry.action]),
    [
      [PERSONAL_ACCOUNT, "DEPLOY"],
      [LOAN_SUBACCOUNT, "DEPLOY"],
    ]
  );
  assert.deepEqual(contractsToDeploy(result).length, 2);
  assert.match(result.entries[0]!.reason, /nothing recorded/);
});

void test("naming one implementation leaves the others out of the plan entirely", async () => {
  // the selection is the guard against redeploying an implementation nobody changed, so an
  // unnamed one must not appear even as a skip: the deploy script is never handed its name
  for (const implementation of REMOTE_IMPLEMENTATIONS) {
    const result = await plan({ selection: implementation.slug });
    assert.deepEqual(
      result.entries.map((entry) => entry.contract),
      [implementation.contract]
    );
    const other = REMOTE_IMPLEMENTATIONS.find((candidate) => candidate !== implementation)!;
    assert.equal(contractsToDeploy(result).includes(other.contract), false);
  }
});

void test("an implementation whose recorded address already carries this code is skipped", async () => {
  const result = await plan({
    selection: ALL,
    record: [
      { name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS },
      { name: LOAN_SUBACCOUNT_RECORD, address: LS_ADDRESS },
    ],
    onChain: { [PA_ADDRESS]: PA_CODE, [LS_ADDRESS]: LS_CODE },
  });
  assert.deepEqual(
    result.entries.map((entry) => [entry.contract, entry.action]),
    [
      [PERSONAL_ACCOUNT, "REUSE"],
      [LOAN_SUBACCOUNT, "REUSE"],
    ]
  );
  assert.equal(result.entries[0]!.address, PA_ADDRESS);
  assert.deepEqual(contractsToDeploy(result), []);
  assert.ok(result.notes.some((note) => note.includes("nothing to deploy")));
});

void test("only the trailing metadata differing is still the same implementation", async () => {
  // a rebuild changes the metadata hash without changing a single instruction; treating that as a
  // change is exactly the pointless redeploy this preflight exists to prevent
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE_REBUILT },
  });
  assert.equal(result.entries[0]!.action, "REUSE");
});

void test("a changed implementation deploys even though its name is recorded", async () => {
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE_CHANGED },
  });
  assert.equal(result.entries[0]!.action, "DEPLOY");
  assert.match(result.entries[0]!.reason, /different code/);
});

void test("all can deploy one and reuse the rest", async () => {
  // the case the selection alone cannot express, and the reason the comparison is not optional
  const result = await plan({
    selection: ALL,
    record: [
      { name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS },
      { name: LOAN_SUBACCOUNT_RECORD, address: LS_ADDRESS },
    ],
    onChain: { [PA_ADDRESS]: PA_CODE, [LS_ADDRESS]: runtime("60806040bbff", "a264697066735822abababab") },
  });
  assert.deepEqual(contractsToDeploy(result), [LOAN_SUBACCOUNT]);
});

void test("a recorded address carrying no code on this chain deploys", async () => {
  // the record is per network but a hand-edited one can name an address from another chain; an
  // empty code answer is not "unchanged"
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: {},
  });
  assert.equal(result.entries[0]!.action, "DEPLOY");
  assert.match(result.entries[0]!.reason, /carries no code/);
});

void test("a duplicated record name is refused before anything is broadcast", async () => {
  // the recorder replaces the FIRST match, so a deploy would update one entry and leave the rest
  // for other tooling to read
  await assert.rejects(
    plan({
      selection: "personal-account",
      record: [
        { name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS },
        { name: PERSONAL_ACCOUNT_RECORD, address: LS_ADDRESS },
      ],
      onChain: { [PA_ADDRESS]: PA_CODE },
    }),
    /holds 2 entries named PersonalAccountRemoteImplementation/
  );
});

void test("a duplicate of an implementation this run does not touch is not its business", async () => {
  const result = await plan({
    selection: "personal-account",
    record: [
      { name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS },
      { name: LOAN_SUBACCOUNT_RECORD, address: LS_ADDRESS },
      { name: LOAN_SUBACCOUNT_RECORD, address: PA_ADDRESS },
    ],
    onChain: { [PA_ADDRESS]: PA_CODE },
  });
  assert.equal(result.entries[0]!.action, "REUSE");
});

void test("reusing an address does not make it a registered one", async () => {
  // registration is a timelocked governance call, so an implementation can sit recorded and
  // unregistered for as long as the signers take; a skipped deploy leaves that exactly as pending
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE },
    registered: { [PERSONAL_ACCOUNT]: ZERO },
  });
  assert.equal(result.entries[0]!.action, "REUSE");
  assert.equal(result.entries[0]!.registrationPending, true);
  assert.ok(formatPlan(result).some((line) => line.includes("registration still pending")));
});

void test("a registry pointing elsewhere is reported, not repaired", async () => {
  // one of the two addresses is the one governance was actually pointed at, and which is intended
  // is a question for a person; overwriting the record here would answer it silently
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE },
    registered: { [PERSONAL_ACCOUNT]: LS_ADDRESS },
  });
  assert.equal(result.entries[0]!.action, "REUSE");
  assert.equal(result.entries[0]!.address, PA_ADDRESS);
  assert.ok(
    result.notes.some((note) => note.includes(PA_ADDRESS) && note.includes(LS_ADDRESS)),
    "the note must name both addresses so the operator can tell them apart"
  );
});

void test("a registry pointing elsewhere is named while a replacement is prepared too", async () => {
  // the case the report matters most in: the recorded address is being superseded, and the address
  // the diamond actually serves today is the one positions are held against. Naming only the record
  // would leave the operator replacing one address while governance points at another
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE_CHANGED },
    registered: { [PERSONAL_ACCOUNT]: LS_ADDRESS },
  });
  assert.equal(result.entries[0]!.action, "DEPLOY");
  assert.equal(result.entries[0]!.registered, LS_ADDRESS);
  assert.ok(
    result.notes.some((note) => note.includes(PA_ADDRESS) && note.includes(LS_ADDRESS)),
    "a DEPLOY must name the registered address as a REUSE does"
  );
  // the note has to be true about what the deploy actually does: the record is replaced, the
  // registry is not - it keeps what it has until governance registers the replacement
  assert.ok(
    result.notes.some((note) => note.includes(`the registry keeps ${LS_ADDRESS}`)),
    "a deploy changes the record, never the registry"
  );
});

void test("a zero registry is not a disagreement to report", async () => {
  // nothing has ever been registered, which is the ordinary state before the first registration
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE_CHANGED },
    registered: { [PERSONAL_ACCOUNT]: ZERO },
  });
  assert.equal(result.entries[0]!.registrationPending, true);
  assert.equal(
    result.notes.some((note) => note.includes("decide which is intended")),
    false
  );
});

void test("a registry already holding the reused address leaves nothing pending", async () => {
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE },
    registered: { [PERSONAL_ACCOUNT]: PA_ADDRESS.toUpperCase().replace("0X", "0x") },
  });
  assert.equal(result.entries[0]!.registrationPending, false);
  assert.equal(
    result.notes.some((note) => note.includes("decide which is intended")),
    false,
    "the record and the registry agree, so there is nothing to decide"
  );
});

void test("no registry at all says nothing about registration", async () => {
  // before the cut the registry's facet does not exist, which is a legitimate state and not a
  // finding about the deploy
  const result = await plan({
    selection: "personal-account",
    record: [{ name: PERSONAL_ACCOUNT_RECORD, address: PA_ADDRESS }],
    onChain: { [PA_ADDRESS]: PA_CODE },
  });
  assert.equal(result.entries[0]!.registered, undefined);
  assert.equal(result.entries[0]!.registrationPending, undefined);
});

void test("the selection resolves names, in the order given", () => {
  assert.deepEqual(
    resolveSelection("morpho-loan-subaccount,personal-account").map((implementation) => implementation.slug),
    ["morpho-loan-subaccount", "personal-account"]
  );
  assert.deepEqual(
    resolveSelection(" personal-account , morpho-loan-subaccount ").map((one) => one.slug),
    knownSlugs()
  );
  assert.deepEqual(
    resolveSelection(ALL).map((one) => one.slug),
    knownSlugs()
  );
});

void test("an unknown name is refused rather than skipped", () => {
  // silently deploying a shorter list than the operator asked for is how an implementation gets
  // left behind, and a typo is the likeliest way to ask for one that does not exist
  assert.throws(() => resolveSelection("personal-accounts"), /unknown implementation: personal-accounts/);
  assert.throws(() => resolveSelection("personal-account,aave-subaccount"), /aave-subaccount/);
  assert.throws(() => resolveSelection(""), /name what to deploy/);
  assert.throws(() => resolveSelection("  ,  "), /name what to deploy/);
});

void test("a name given twice is refused, and so is all plus a name", () => {
  // both usually mean one of them was meant to be a different name
  assert.throws(() => resolveSelection("personal-account,personal-account"), /named twice/);
  assert.throws(() => resolveSelection(`${ALL},personal-account`), /already means every implementation/);
});

void test("adding a subaccount type is a row in the table, not an argument", () => {
  // the shape this interface exists to have: every implementation is addressed by name, and the
  // table is the single place that knows the set
  for (const implementation of REMOTE_IMPLEMENTATIONS) {
    assert.match(implementation.slug, /^[a-z][a-z-]*[a-z]$/, "slugs are the operator-facing names");
    assert.ok(implementation.recordName.endsWith("Implementation"));
    assert.equal(resolveSelection(implementation.slug)[0], implementation);
  }
  assert.equal(new Set(knownSlugs()).size, REMOTE_IMPLEMENTATIONS.length, "slugs are unique");
});
