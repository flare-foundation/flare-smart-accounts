#!/usr/bin/env node
// Names the parameters of the calls `prepare` wrote, so a governance sheet can be filled from the
// tool instead of by decoding hex. Reads the file `prepare` produced; makes no chain call and takes
// no key, because naming what is already encoded needs neither.

import { readFileSync } from "node:fs";
import Web3 from "web3";
import { validateNetwork } from "../utils/networks";
import {
  decodeCall,
  formatParameters,
  formatSheetRow,
  parsePrepared,
  selectorTable,
  type AbiCoder,
} from "../utils/decode-calls";

interface Options {
  network: string;
  section: string;
  sheet: boolean;
  flat: boolean;
}

function parseOptions(args: string[]): Options {
  const positional: string[] = [];
  let sheet = false;
  let flat = false;
  for (const arg of args) {
    if (arg === "--sheet") {
      sheet = true;
    } else if (arg === "--flat") {
      flat = true;
    } else if (arg.startsWith("--")) {
      throw new Error(`unknown option: ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  const [network, section] = positional;
  if (network === undefined) {
    throw new Error("Usage: tsx describe-calls.ts <network> [section] [--sheet] [--flat]");
  }
  return { network, section: section ?? "governance", sheet, flat };
}

function main(): void {
  const options = parseOptions(process.argv.slice(2));
  validateNetwork(options.network);
  const path = `deployment/output-internal/${options.network}/configuration-${options.section}.txt`;
  let contents: string;
  try {
    contents = readFileSync(path, "utf8");
  } catch {
    throw new Error(
      `no prepared calls at ${path} - run "pnpm configure_remote_controller ${options.network} ` +
        `prepare ${options.section}" first`
    );
  }

  const web3 = new Web3();
  const coder: AbiCoder = {
    encodeFunctionSignature: (signature) => web3.eth.abi.encodeFunctionSignature(signature),
    decodeParameters: (types, hex) => web3.eth.abi.decodeParameters(types as never, hex) as Record<string, unknown>,
  };
  const table = selectorTable(coder);
  const { notes, calls } = parsePrepared(contents);

  for (const note of notes) {
    console.log(note);
  }
  if (calls.length === 0) {
    console.log(`no calls in ${path} - the section had nothing left to submit`);
    return;
  }
  for (const call of calls) {
    const decoded = decodeCall(coder, table, call.calldata, { flat: options.flat });
    if (options.sheet) {
      console.log(`${call.description}\t${call.target}\t${formatSheetRow(decoded)}\t${call.calldata}`);
      continue;
    }
    console.log(`\n${call.index}. ${call.description}`);
    console.log(`     target = ${call.target}`);
    for (const line of formatParameters(decoded)) {
      console.log(line);
    }
    console.log(`     calldata = ${call.calldata}`);
  }
}

try {
  main();
} catch (error: unknown) {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
}
