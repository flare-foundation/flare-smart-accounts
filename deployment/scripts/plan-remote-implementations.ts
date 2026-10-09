#!/usr/bin/env node
// The preflight of `deploy_remote_account_implementations`: decides which of the remote
// implementations the run should actually deploy, prints the plan, and writes the artifact names
// the forge script takes. Run before the broadcast, so a run that would deploy nothing costs no
// gas and, more to the point, replaces no record.
//
// Why it is a separate command rather than logic inside the forge script: the comparison it makes
// is the cut planner's, over artifacts on disk and code on chain, and that already lives in
// TypeScript. Writing those metadata rules again in Solidity would leave two copies to keep in
// step.

import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import Web3 from "web3";
import { loadDeployedCode } from "../utils/facet-code";
import { assertRpcChain, findDiamondAddress, loadDeployedContracts } from "../utils/diamond-inspect";
import { resolveRpcUrl, validateNetwork } from "../utils/networks";
import { IMPLEMENTATIONS } from "../utils/implementation-verify";
import {
  ALL,
  contractsToDeploy,
  formatPlan,
  knownSlugs,
  planRemoteImplementations,
} from "../utils/implementation-plan";

const FUNCTION_NOT_FOUND = "0x5416eb98";

interface Options {
  network: string;
  /** A comma-separated list of slugs, or `all`. Validated when the plan resolves it. */
  selection: string;
  /** Where to write the list the wrapper hands the deploy script. */
  out?: string;
  noBuild: boolean;
}

function parseOptions(args: string[]): Options {
  const positional: string[] = [];
  let out: string | undefined;
  let noBuild = false;
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--no-build") {
      noBuild = true;
    } else if (arg === "--out") {
      out = args[++i];
    } else if (arg.startsWith("--")) {
      throw new Error(`unknown option: ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  const [network, selection] = positional;
  if (network === undefined || selection === undefined) {
    throw new Error(
      `Usage: tsx plan-remote-implementations.ts <network> <${ALL}|${knownSlugs().join(",")}> ` +
        `[--out <file>] [--no-build]\n` +
        `The selection is mandatory: deploying everything is something to ask for rather than ` +
        `something to get by forgetting.`
    );
  }
  return { network, selection, ...(out !== undefined ? { out } : {}), noBuild };
}

/** `implementationForType(type)` / `implementation()`, or undefined when the facet is not cut. */
function registeredReader(web3: Web3, diamond: string) {
  return async (contract: string): Promise<string | undefined> => {
    const spec = IMPLEMENTATIONS[contract];
    if (spec === undefined) {
      return undefined;
    }
    const signature = spec.target === "personalAccountBeacon" ? "implementation()" : "implementationForType(uint256)";
    const selector = web3.eth.abi.encodeFunctionSignature(signature);
    const data =
      spec.target === "personalAccountBeacon"
        ? selector
        : selector + web3.eth.abi.encodeParameters(["uint256"], [String(spec.subaccountType)]).slice(2);
    try {
      const raw = await web3.eth.call({ to: diamond, data });
      return String(web3.eth.abi.decodeParameter("address", raw)).toLowerCase();
    } catch (error) {
      // A diamond answers a selector it does not serve with FunctionNotFound naming THAT selector,
      // and that is the one failure worth tolerating: the registry's facet is not cut yet, which is
      // a legitimate state before the cut and says nothing about the deploy. The whole payload is
      // compared, not its first four bytes: the same error naming another selector came from
      // somewhere else in the call, and swallowing it would drop a failed registry read out of the
      // plan silently.
      const notServed = (
        FUNCTION_NOT_FOUND + web3.eth.abi.encodeParameters(["bytes4"], [selector]).slice(2)
      ).toLowerCase();
      if (revertData(error) === notServed) {
        return undefined;
      }
      throw error;
    }
  };
}

/** The revert payload of a failed `eth_call`, however the provider chose to report it. */
function revertData(error: unknown): string | undefined {
  const candidates = [error, (error as { cause?: unknown }).cause, (error as { innerError?: unknown }).innerError];
  for (const candidate of candidates) {
    const data = (candidate as { data?: unknown })?.data;
    if (typeof data === "string" && data.startsWith("0x")) {
      return data.toLowerCase();
    }
  }
  return undefined;
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  validateNetwork(options.network);
  if (!options.noBuild) {
    execSync("forge build", { stdio: "inherit" });
  }

  const record = loadDeployedContracts(options.network);
  const web3 = new Web3(resolveRpcUrl(options.network));
  await assertRpcChain(web3, options.network);

  // a record with no controller is a first deployment, where there is no registry to compare
  // against; a record with several is ambiguous, and picking one - or quietly reporting no
  // registration at all - is worse than stopping
  const controllers = record.filter(
    (entry) => entry.name === "MasterAccountController" || entry.contractName === "MasterAccountController.sol"
  );
  const registered = controllers.length === 0 ? undefined : registeredReader(web3, findDiamondAddress(record));

  const plan = await planRemoteImplementations({
    selection: options.selection,
    record: record.map((entry) => ({ name: entry.name, address: entry.address })),
    artifactCode: (contract) => loadDeployedCode(contract),
    code: (address) => web3.eth.getCode(address),
    ...(registered !== undefined ? { registered } : {}),
  });

  console.log(`Remote implementation plan for ${options.network} (${options.selection})`);
  for (const line of formatPlan(plan)) {
    console.log(line);
  }

  // the artifact names, one per line, for the wrapper to hand the deploy script; an empty file
  // is the legitimate "nothing changed" answer rather than a failure
  if (options.out !== undefined) {
    writeFileSync(
      options.out,
      contractsToDeploy(plan)
        .map((contract) => `${contract}\n`)
        .join("")
    );
  }
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
