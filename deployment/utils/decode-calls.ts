/**
 * Naming the parameters of a prepared governance call.
 *
 * `prepare` writes a function name, a target and a calldata blob. A governance sheet has a column
 * per parameter, so filling one from that output means decoding hex by hand — which is what the
 * 2026-09-14 deployment actually did, for every row, on both chains.
 *
 * The names come from the compiled ABI rather than from strings written beside the encoder. Two
 * reasons, and the second is the important one. A hand-written rendering silently outdates when a
 * struct gains a field, while an ABI built from the same sources as the encoder cannot. And
 * decoding the payload is a SECOND SOURCE: it reads back what was actually encoded, so a wrong
 * encoding shows up as a wrong value here, where restating the inputs would agree with itself and
 * prove nothing.
 *
 * Tuples are flattened to dotted paths (`_market.marketParams.lltv`), because that is how the
 * fields appear in a sheet and how an operator says them out loud.
 */

import { globSync, readFileSync } from "node:fs";

export interface AbiParameter {
  name: string;
  type: string;
  components?: AbiParameter[];
}

export interface AbiFunction {
  type: string;
  name: string;
  inputs: AbiParameter[];
}

/** One decoded parameter: its dotted path and its value, rendered as a sheet would carry it. */
export interface DecodedParameter {
  path: string;
  type: string;
  value: string;
}

export interface DecodedCall {
  selector: string;
  /** The canonical signature the selector hashes from, when it is known. */
  signature?: string;
  parameters: DecodedParameter[];
}

/** The subset of web3's ABI coder this needs, so the decoder can be tested without a chain. */
export interface AbiCoder {
  encodeFunctionSignature(signature: string): string;
  decodeParameters(types: unknown[], hex: string): Record<string, unknown>;
}

function canonicalType(parameter: AbiParameter): string {
  if (!parameter.type.startsWith("tuple")) {
    return parameter.type;
  }
  const inner = (parameter.components ?? []).map(canonicalType).join(",");
  return `(${inner})${parameter.type.slice("tuple".length)}`;
}

export function signatureOf(fn: AbiFunction): string {
  return `${fn.name}(${fn.inputs.map(canonicalType).join(",")})`;
}

/**
 * Every function in the given artifacts, by selector.
 *
 * Built from the INTERNAL facet interfaces (`IIFacet`), which are what the configuration script
 * encodes against. A collision keeps the first: identical signatures decode identically, so which
 * one wins does not change a decode.
 */
export function selectorTable(
  coder: AbiCoder,
  artifactPaths: string[] = defaultArtifactPaths()
): Map<string, AbiFunction> {
  const table = new Map<string, AbiFunction>();
  for (const path of artifactPaths) {
    let abi: unknown;
    try {
      abi = (JSON.parse(readFileSync(path, "utf8")) as { abi?: unknown }).abi;
    } catch {
      continue;
    }
    if (!Array.isArray(abi)) {
      continue;
    }
    for (const item of abi) {
      const fn = item as AbiFunction;
      if (fn.type !== "function" || !Array.isArray(fn.inputs)) {
        continue;
      }
      const selector = coder.encodeFunctionSignature(signatureOf(fn));
      if (!table.has(selector)) {
        table.set(selector, fn);
      }
    }
  }
  return table;
}

export function defaultArtifactPaths(): string[] {
  // ordered, not merged: the internal interfaces first, since theirs are the names to prefer
  return [
    ...globSync("artifacts/II*Facet.sol/*.json"),
    ...globSync("artifacts/I*Facet.sol/*.json"),
    ...globSync("artifacts/*Facet.sol/*.json"),
    ...globSync("artifacts/IOwnableWithTimelock.sol/*.json"),
  ];
}

/**
 * One value, in the bracketed form a governance sheet and the Safe Transaction Builder both take:
 * a struct is `[field, field, ...]`, nested to any depth, with its fields in declaration order.
 *
 * EVERY scalar inside the brackets is quoted, integers included. The Safe Transaction Builder
 * parses these with `JSON.parse` and accepts a decimal string for any integer ABI field, so
 * quoting costs nothing there, while a bare integer is read as an IEEE double and is exact only to
 * about 9.0e15 - and the bound cuts both ways, since a negative integer past `-(2^53)` loses its
 * low digits just as an unsigned one does. A magnitude-dependent rule would be a second thing to
 * reason about at the moment someone is pasting a value into a multisig.
 */
function render(parameter: AbiParameter, value: unknown): string {
  if (parameter.type === "tuple" && parameter.components !== undefined) {
    const record = value as Record<string, unknown>;
    const fields = parameter.components.map((component, index) => {
      const name = component.name === "" ? String(index) : component.name;
      return render(component, record[name] ?? record[String(index)]);
    });
    return `[${fields.join(",")}]`;
  }
  if (isArrayType(parameter.type)) {
    const element = elementOf(parameter);
    return `[${(value as unknown[]).map((item) => render(element, item)).join(",")}]`;
  }
  return renderScalar(value);
}

function renderScalar(value: unknown): string {
  if (typeof value === "boolean") {
    return value ? "true" : "false";
  }
  if (typeof value === "bigint" || typeof value === "number") {
    return `"${value.toString()}"`;
  }
  // escaped as JSON, not wrapped in quotes: a value carrying a quote would otherwise produce
  // invalid JSON, and one carrying a backslash-n would become a real newline when parsed - which
  // for a string[] of XRPL wallets is a value the operator never typed
  return JSON.stringify(String(value));
}

/**
 * The dotted-path view: one line per LEAF, for reading a call rather than pasting it.
 *
 * Arrays are walked as well as structs, with an index in the path (`_cuts[0].facetAddress`), or a
 * promise of leaves would stop at the first array and hand back a bracket - which is the other
 * view, and the reason someone asked for this one.
 */
function flatten(parameter: AbiParameter, value: unknown, prefix: string, into: DecodedParameter[]): void {
  if (parameter.type === "tuple" && parameter.components !== undefined) {
    const record = value as Record<string, unknown>;
    for (const [index, component] of parameter.components.entries()) {
      const name = component.name === "" ? String(index) : component.name;
      flatten(component, record[name] ?? record[String(index)], `${prefix}.${name}`, into);
    }
    return;
  }
  if (isArrayType(parameter.type)) {
    const element = elementOf(parameter);
    const items = value as unknown[];
    if (items.length === 0) {
      into.push({ path: prefix, type: canonicalType(parameter), value: "[]" });
      return;
    }
    for (const [index, item] of items.entries()) {
      flatten(element, item, `${prefix}[${index}]`, into);
    }
    return;
  }
  into.push({
    path: prefix,
    type: canonicalType(parameter),
    value: unquoted(render(parameter, value)),
  });
}

function isArrayType(type: string): boolean {
  return /\[\d*\]$/.test(type);
}

function elementOf(parameter: AbiParameter): AbiParameter {
  return { ...parameter, type: parameter.type.replace(/\[\d*\]$/, "") };
}

/**
 * A top-level scalar as a sheet cell holds it: plain, since that cell is not JSON. Only the quotes
 * a scalar rendering added are removed, and a JSON escape is undone with a parse rather than by
 * trimming, so a value containing a quote survives.
 */
function unquoted(rendered: string): string {
  if (!rendered.startsWith('"')) {
    return rendered;
  }
  return String(JSON.parse(rendered));
}

/**
 * Decodes one prepared payload against the table.
 *
 * An unknown selector is not an error: the caller still has the calldata, and saying so beats
 * inventing names for it.
 */
export function decodeCall(
  coder: AbiCoder,
  table: Map<string, AbiFunction>,
  calldata: string,
  options: { flat?: boolean } = {}
): DecodedCall {
  const selector = calldata.slice(0, 10).toLowerCase();
  const fn = table.get(selector);
  if (fn === undefined) {
    return { selector, parameters: [] };
  }
  // the ABI's own input objects, tuple components and all: the coder wants the descriptor it was
  // compiled from, not a canonical signature string
  const decoded = coder.decodeParameters(fn.inputs as unknown[], `0x${calldata.slice(10)}`);
  const parameters: DecodedParameter[] = [];
  for (const [index, input] of fn.inputs.entries()) {
    const name = input.name === "" ? `arg${index}` : input.name;
    const value = decoded[name] ?? decoded[String(index)];
    if (options.flat === true) {
      flatten(input, value, name, parameters);
      continue;
    }
    // a struct is ONE parameter with one bracketed value, which is how a sheet column and the Safe
    // Transaction Builder both take it; splitting it into columns per field is the other view
    parameters.push({
      path: name,
      type: canonicalType(input),
      value: unquoted(render(input, value)),
    });
  }
  return { selector, signature: signatureOf(fn), parameters };
}

/**
 * A value safe to put in a line or a tab-separated cell.
 *
 * A top-level scalar is printed as written, which is what a sheet cell wants - but a value carrying
 * a tab or a newline would end that cell or that row early, silently turning one parameter into
 * two columns or two rows. Only such a value is escaped, so every ordinary one is untouched and the
 * pathological one is visible rather than structural. Bracketed values need no handling: they are
 * JSON already, and JSON escapes its own control characters.
 */
function cell(value: string): string {
  return /[\t\r\n]/.test(value) ? JSON.stringify(value) : value;
}

/** One `  name = value` line per parameter, for reading beside the call it belongs to. */
export function formatParameters(call: DecodedCall): string[] {
  if (call.signature === undefined) {
    return [`     (${call.selector} is not a selector this repository builds - nothing decoded)`];
  }
  return call.parameters.map((parameter) => `     ${parameter.path} = ${cell(parameter.value)}`);
}

/**
 * The parameters as a sheet row would carry them: name, value, name, value, tab separated.
 *
 * A call it could not decode says so in the row rather than leaving the parameter area empty, which
 * would be indistinguishable from a function that takes none - and a row quietly carrying no
 * arguments is the one a reviewer waves through.
 */
export function formatSheetRow(call: DecodedCall): string {
  if (call.signature === undefined) {
    return `UNKNOWN SELECTOR ${call.selector} - nothing decoded`;
  }
  return call.parameters.flatMap((parameter) => [cell(parameter.path), cell(parameter.value)]).join("\t");
}

export interface PreparedCall {
  index: string;
  description: string;
  target: string;
  calldata: string;
}

/** The lines `prepare` writes: `N. description | target | calldata`, plus any leading notes. */
export function parsePrepared(contents: string): { notes: string[]; calls: PreparedCall[] } {
  const notes: string[] = [];
  const calls: PreparedCall[] = [];
  for (const line of contents.split("\n")) {
    if (line.trim() === "") {
      continue;
    }
    if (!line.includes("|")) {
      notes.push(line.trim());
      continue;
    }
    const [head, target, calldata] = line.split("|").map((part) => part.trim());
    const [index, ...rest] = head!.split(".");
    calls.push({
      index: index!.trim(),
      description: rest.join(".").trim(),
      target: target!,
      calldata: calldata!,
    });
  }
  return { notes, calls };
}
