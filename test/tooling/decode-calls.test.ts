/**
 * Naming the parameters of a prepared governance call.
 *
 * The decode is a SECOND SOURCE on what `prepare` encoded, not a restatement of its inputs, so the
 * cases below drive real payloads — the ones the 2026-09-14 Sepolia deployment actually submitted —
 * through the same ABI the script encodes against, and check the names and values that come back.
 * A test that built its own calldata from the same table would agree with itself and prove nothing.
 */
import assert from "node:assert/strict";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import Web3 from "web3";
import {
  decodeCall,
  formatParameters,
  formatSheetRow,
  defaultArtifactPaths,
  parsePrepared,
  selectorTable,
  signatureOf,
  type AbiCoder,
  type AbiFunction,
} from "../../deployment/utils/decode-calls";

const web3 = new Web3();
const coder: AbiCoder = {
  encodeFunctionSignature: (signature) => web3.eth.abi.encodeFunctionSignature(signature),
  decodeParameters: (types, hex) => web3.eth.abi.decodeParameters(types as never, hex) as Record<string, unknown>,
};
/**
 * The selector table is built from compiled artifacts, so this suite needs a `forge build` to have
 * run. Missing, it SKIPS rather than reporting a failure per case — except under
 * `REQUIRE_FORGE_TOOLING`, which is how the Foundry-equipped CI job demands it actually run. The
 * node-only job has no artifacts, and nine failures there would say nothing about this code.
 */
const artifacts = defaultArtifactPaths();
const missing = artifacts.length === 0 ? "no compiled artifacts - run forge build" : undefined;
if (missing !== undefined && process.env["REQUIRE_FORGE_TOOLING"] !== undefined) {
  throw new Error(`REQUIRE_FORGE_TOOLING is set but there are ${missing}`);
}
const skip = missing;
const table = missing === undefined ? selectorTable(coder, artifacts) : new Map<string, AbiFunction>();

/** Exactly what the Safe submitted on Sepolia on 2026-09-14, copied from the governance sheet. */
const TRANSPORT =
  "0x026512410000000000000000000000006edce65403992e310a62460808c4b910d972f10f000000000000000000000000" +
  "81672c5d42f3573ad95a0bdfbe824faac547d4e600000000000000000000000000000000000000000000000000000000" +
  "00009d66000000000000000000000000cd3d2127935ae82af54fc31ccd9d3440dbf46639";
const MARKET =
  "0x5007785f0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000" +
  "d011ee229e7459ba1ddd22631ef7bf528d424a140000000000000000000000001b5a184869ad208e736bfecf53560e99" +
  "40c3e67f00000000000000000000000081672c5d42f3573ad95a0bdfbe824faac547d4e6000000000000000000000000" +
  "38866de4f3e3ec99f02a5e169713729d6c8a29f00000000000000000000000008c5ddcd3f601c91d1bf51c8ec2606601" +
  "0acaba7c0000000000000000000000000000000000000000000000000aaf96eb9d0d0000";
const FEES =
  "0x9835f83d0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000" +
  "00000000000000000000000000f8b0a10e470000000000000000000000000000000000000000000000000000002386f2" +
  "6fc1000000000000000000000000000099e0770aa23caa9071b6112208297e7a8d8f8a4a";
const DURATION = "0x150fea090000000000000000000000000000000000000000000000000000000000000e10";

function pairs(calldata: string, flat = false): Record<string, string> {
  const decoded = decodeCall(coder, table, calldata, { flat });
  return Object.fromEntries(decoded.parameters.map((parameter) => [parameter.path, parameter.value]));
}

void test("a struct is ONE parameter whose value is the bracketed form the sheet carries", { skip }, () => {
  // character for character what the 2026-09-14 governance sheet held for this row, nesting and
  // quoting included: a struct inside a struct, beside a scalar
  assert.deepEqual(pairs(MARKET), {
    _subaccountType: "1",
    _market:
      '["0xd011EE229E7459ba1ddd22631eF7bF528d424A14",' +
      '["0x1B5A184869aD208E736BFecF53560e9940c3E67f",' +
      '"0x81672c5d42F3573aD95A0bdfBE824FaaC547d4E6",' +
      '"0x38866de4F3e3Ec99F02a5E169713729D6C8a29F0",' +
      '"0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c",' +
      '"770000000000000000"]]',
  });
});

void test("--flat gives the dotted paths instead, for reading rather than pasting", { skip }, () => {
  assert.deepEqual(pairs(MARKET, true), {
    _subaccountType: "1",
    "_market.morpho": "0xd011EE229E7459ba1ddd22631eF7bF528d424A14",
    "_market.marketParams.loanToken": "0x1B5A184869aD208E736BFecF53560e9940c3E67f",
    "_market.marketParams.collateralToken": "0x81672c5d42F3573aD95A0bdfBE824FaaC547d4E6",
    "_market.marketParams.oracle": "0x38866de4F3e3Ec99F02a5E169713729D6C8a29F0",
    "_market.marketParams.irm": "0x8C5dDCD3F601c91D1BF51c8ec26066010ACAbA7c",
    "_market.marketParams.lltv": "770000000000000000",
  });
});

void test("every integer inside the brackets is quoted, whatever its magnitude", { skip }, () => {
  // a bare integer is read as an IEEE double and is exact only to about 9.0e15, in BOTH directions,
  // so a magnitude-dependent rule is one more thing to reason about at the moment someone pastes a
  // value into a multisig. The Safe builder parses these with JSON.parse and takes a decimal string
  // for any integer field, so quoting costs nothing
  assert.deepEqual(pairs(TRANSPORT), {
    _transport:
      '["0x6EDCE65403992e310A62460808c4b910D972f10f",' +
      '"0x81672c5d42F3573aD95A0bdfBE824FaaC547d4E6",' +
      '"40294",' +
      '"0x000000000000000000000000cd3d2127935ae82af54fc31ccd9d3440dbf46639"]',
  });
});

void test("a top-level scalar is plain, because a sheet cell is not JSON", { skip }, () => {
  // only values INSIDE a bracket are parsed as JSON by anything; a column of its own is read as
  // written, and quoting it would put the quotes in the cell
  assert.deepEqual(pairs(DURATION), { _timelockDurationSeconds: "3600" });
  assert.deepEqual(pairs(MARKET)["_subaccountType"], "1");
});

void test("the fee terms keep their exact integers, never scaled to a percentage", { skip }, () => {
  // a WAD shown as "7%" would be a second representation to reconcile against the sheet, and the
  // sheet carries the integer
  assert.deepEqual(pairs(FEES), {
    _subaccountType: "1",
    _terms: '["70000000000000000","10000000000000000","0x99E0770aa23CAA9071B6112208297E7a8d8F8a4A"]',
  });
  assert.deepEqual(pairs(FEES, true)["_terms.feeFloor"], "70000000000000000");
});

void test("the decoded signature is the one the selector hashes from", { skip }, () => {
  // the names are only trustworthy if they came from the function the selector actually names
  for (const [calldata, signature] of [
    [TRANSPORT, "setComposeTransport((address,address,uint32,bytes32))"],
    [MARKET, "registerLoanMarket(uint256,(address,(address,address,address,address,uint256)))"],
    [FEES, "setLoanFeeTerms(uint256,(uint64,uint64,address))"],
    [DURATION, "setTimelockDuration(uint256)"],
  ] as [string, string][]) {
    const decoded = decodeCall(coder, table, calldata);
    assert.equal(decoded.signature, signature);
    assert.equal(web3.eth.abi.encodeFunctionSignature(signature), decoded.selector);
  }
});

void test("a string carrying a quote or a backslash survives the round trip", { skip }, () => {
  // driven through the REAL string[] signature: unescaped, a value holding a quote produces
  // invalid JSON, and one holding a backslash-n becomes a genuine newline when the bracketed cell
  // is parsed - a wallet the operator never typed
  const signature = "addXrplProviderWallets(string[])";
  const awkward = ['rAbc"quoted', "rDef\\nNotANewline", "rGhi\ttabbed"];
  const calldata =
    web3.eth.abi.encodeFunctionSignature(signature) + web3.eth.abi.encodeParameters(["string[]"], [awkward]).slice(2);

  const value = pairs(calldata)["_xrplProviderWallets"]!;
  assert.deepEqual(JSON.parse(value), awkward, "the cell must parse back to exactly what was encoded");
});

void test("a negative integer inside a tuple is quoted like any other", { skip }, () => {
  // the precision bound cuts both ways: -9007199254740993 read bare comes back as
  // -9007199254740992, and a magnitude rule guarding only the upper end would miss it. Driven
  // through a REAL encode of a tuple and read back with JSON.parse, because a bare integer only
  // loses its digits when something parses the bracketed cell
  const signature = "f((int256,address))";
  const amount = -9007199254740993n;
  const recipient = "0x99E0770aa23CAA9071B6112208297E7a8d8F8a4A";
  const input = {
    name: "_terms",
    type: "tuple",
    components: [
      { name: "amount", type: "int256" },
      { name: "recipient", type: "address" },
    ],
  };
  const calldata =
    web3.eth.abi.encodeFunctionSignature(signature) +
    web3.eth.abi.encodeParameters([input as never], [[amount.toString(), recipient]]).slice(2);
  const local = new Map([
    [web3.eth.abi.encodeFunctionSignature(signature), { type: "function", name: "f", inputs: [input] }],
  ]);

  const value = decodeCall(coder, local as never, calldata).parameters[0]!.value;
  const parsed = JSON.parse(value) as [string, string];
  assert.equal(parsed[0], amount.toString(), "the digits must survive a JSON parse of the cell");
  assert.equal(typeof parsed[0], "string", "a bare integer here would come back rounded");
  assert.equal(parsed[1], recipient);
});

void test("a selector this repository does not build is said so, not guessed at", { skip }, () => {
  const decoded = decodeCall(coder, table, "0xdeadbeef00");
  assert.equal(decoded.signature, undefined);
  assert.deepEqual(decoded.parameters, []);
  assert.match(formatParameters(decoded)[0]!, /not a selector this repository builds/);
});

void test("the sheet form is name, value, name, value, with the struct as one cell", { skip }, () => {
  const row = formatSheetRow(decodeCall(coder, table, FEES)).split("\t");
  assert.deepEqual(row, [
    "_subaccountType",
    "1",
    "_terms",
    '["70000000000000000","10000000000000000","0x99E0770aa23CAA9071B6112208297E7a8d8F8a4A"]',
  ]);
});

void test("--flat walks arrays too, with an index in the path", { skip }, () => {
  // a promise of one line per LEAF that stops at the first array hands back a bracket instead,
  // which is the other view and the reason someone asked for this one
  const signature = "addXrplProviderWallets(string[])";
  const wallets = ["rAlpha", "rBeta"];
  const calldata =
    web3.eth.abi.encodeFunctionSignature(signature) + web3.eth.abi.encodeParameters(["string[]"], [wallets]).slice(2);

  assert.deepEqual(pairs(calldata, true), {
    "_xrplProviderWallets[0]": "rAlpha",
    "_xrplProviderWallets[1]": "rBeta",
  });
  // an empty array has no leaves, and saying nothing at all would lose the parameter
  const empty =
    web3.eth.abi.encodeFunctionSignature(signature) + web3.eth.abi.encodeParameters(["string[]"], [[]]).slice(2);
  assert.deepEqual(pairs(empty, true), { _xrplProviderWallets: "[]" });
});

void test("a value carrying a tab or a newline cannot break a row or a line", { skip }, () => {
  // with --sheet --flat a raw tab would end the cell and a raw newline the ROW, silently turning
  // one parameter into two columns or one call into two rows - and the reader would see a
  // plausible-looking sheet rather than an error
  const signature = "addXrplProviderWallets(string[])";
  const wallets = ["rAlpha\tTabbed", "rBeta\nSecondLine", "rGamma"];
  const calldata =
    web3.eth.abi.encodeFunctionSignature(signature) + web3.eth.abi.encodeParameters(["string[]"], [wallets]).slice(2);

  const row = formatSheetRow(decodeCall(coder, table, calldata, { flat: true }));
  assert.equal(row.split("\t").length, 6, "three parameters means six cells, whatever they contain");
  assert.equal(row.includes("\n"), false, "no value may end the row");
  // an ordinary value is untouched, so the escaping never shows up where it is not needed
  assert.ok(row.includes("\trGamma"), "a value with nothing to escape is printed as written");
  for (const line of formatParameters(decodeCall(coder, table, calldata, { flat: true }))) {
    assert.equal(line.includes("\n"), false, "no printed line may be split by a value");
  }
});

void test("a call it cannot decode says so in the sheet row rather than looking argument-free", { skip }, () => {
  const row = formatSheetRow(decodeCall(coder, table, "0xdeadbeef00"));
  assert.match(row, /UNKNOWN SELECTOR 0xdeadbeef/);
});

void test("the table is built from the interfaces the script encodes against", { skip }, () => {
  // a table that missed them would decode nothing, and the failure would look like a bad payload
  for (const signature of [
    "setPersonalAccountImplementation(address)",
    "setSubaccountImplementation(uint256,address)",
    "setComposeTransport((address,address,uint32,bytes32))",
    "registerLoanMarket(uint256,(address,(address,address,address,address,uint256)))",
    "setLoanFeeTerms(uint256,(uint64,uint64,address))",
    "setTimelockDuration(uint256)",
    "addPausers(address[])",
    "addUnpausers(address[])",
  ]) {
    const selector = web3.eth.abi.encodeFunctionSignature(signature);
    const fn = table.get(selector);
    assert.ok(fn !== undefined, `${signature} is missing from the table`);
    assert.equal(signatureOf(fn), signature);
  }
});

void test("the first artifact to claim a selector keeps it, names and all", { skip }, () => {
  // a selector fixes the signature but NOT the parameter names, so the same function declared on an
  // internal interface and on its public parent can carry different names for the same field - and
  // the names are the whole point. The internal ones are searched first and must win
  const root = mkdtempSync(join(tmpdir(), "decode-calls-"));
  const write = (name: string, parameterName: string) => {
    mkdirSync(join(root, name), { recursive: true });
    const path = join(root, name, "artifact.json");
    writeFileSync(
      path,
      JSON.stringify({
        abi: [{ type: "function", name: "setThing", inputs: [{ name: parameterName, type: "uint256" }] }],
      })
    );
    return path;
  };
  const internal = write("IIThingFacet.sol", "_theInternalName");
  const external = write("IThingFacet.sol", "aDifferentName");

  const preferred = selectorTable(coder, [internal, external]);
  const reversed = selectorTable(coder, [external, internal]);
  const selector = web3.eth.abi.encodeFunctionSignature("setThing(uint256)");

  assert.equal(preferred.get(selector)?.inputs[0]?.name, "_theInternalName");
  assert.equal(reversed.get(selector)?.inputs[0]?.name, "aDifferentName", "order is what decides");
});

void test("the default search puts the internal interfaces first", { skip }, () => {
  // the ordering above only helps if the real search is ordered that way
  const paths = defaultArtifactPaths();
  const firstInternal = paths.findIndex((path) => /\/II[A-Za-z]+Facet\.sol\//.test(path));
  const firstPublic = paths.findIndex((path) => /\/I[A-Z][A-Za-z]*Facet\.sol\//.test(path) && !/\/II/.test(path));
  assert.ok(firstInternal >= 0, "no internal facet interface artifacts found");
  assert.ok(firstPublic < 0 || firstInternal < firstPublic, "an internal interface must be searched first");
});

void test("the prepared file parses into its notes and its calls", { skip }, () => {
  const { notes, calls } = parsePrepared(
    "PROVISIONAL: something the run wanted to say\n" +
      `1. setLoanFeeTerms | 0xAbC | ${FEES}\n` +
      `2. EXECUTE setLoanFeeTerms | 0xAbC | 0x1234\n`
  );
  assert.deepEqual(notes, ["PROVISIONAL: something the run wanted to say"]);
  assert.equal(calls.length, 2);
  assert.deepEqual(
    { index: calls[0]!.index, description: calls[0]!.description, target: calls[0]!.target },
    { index: "1", description: "setLoanFeeTerms", target: "0xAbC" }
  );
  // an EXECUTE line is a call like any other; its payload wraps the one above it
  assert.equal(calls[1]!.description, "EXECUTE setLoanFeeTerms");
});

void test("an empty prepared file yields no calls rather than a parse error", { skip }, () => {
  // what a fully skipped section writes, and a reader must not treat that as malformed
  assert.deepEqual(parsePrepared(""), { notes: [], calls: [] });
  assert.deepEqual(parsePrepared("\n\n"), { notes: [], calls: [] });
});
