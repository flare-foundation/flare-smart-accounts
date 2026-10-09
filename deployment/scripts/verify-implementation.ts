#!/usr/bin/env node
// Verifies an account implementation before and after it is registered, the way verify-diamond.ts
// verifies the diamond's surface: a named check list, expected against actual, non-zero exit on
// any mismatch. Registering is the deployment's one blind step - the setters check only that the
// address has code - so the same question is asked at three moments:
//
//   pnpm verify_implementation <network> <Contract> <address> --stage pre
//     Before the timelocked registration is queued: the address holds the reviewed artifact's
//     code, from a source still in the repository, and the implementation belongs on this chain
//     family. Prints the exact calldata to queue.
//   pnpm verify_implementation <network> <Contract> <address> --stage queued
//     After queueing, before execution: that exact calldata is queued, the timelock duration is
//     non-zero, and the code behind the address still matches - nothing changed under the call.
//   pnpm verify_implementation <network> <Contract> <address> --stage live [--xrpl-owner <owner>]
//     After execution: the registry points at it, and with --xrpl-owner a materialized account
//     is read back - the controller is its beacon, it reports this controller, and it was
//     initialized with the expected owner, parent and type.
//
// Every read is made at one block, resolved once from VERIFY_BLOCK_TAG (default `latest`; set
// `finalized` for reorg-proof reads). The checks live in deployment/utils/implementation-verify.ts
// behind two reader interfaces, which is where the regression tests drive them with a fake chain.
import { execSync } from "node:child_process";
import { existsSync } from "node:fs";
import Web3 from "web3";
import { artifactPathFor, loadCreationCode, loadDeployedCode } from "../utils/facet-code";
import { assertRpcChain, findDiamondAddress, loadDeployedContracts } from "../utils/diamond-inspect";
import { resolveRpcUrl, validateNetwork } from "../utils/networks";
import { allPassed, formatChecks } from "../utils/diamond-verify";
import {
  type AccountIdentity,
  type ChainReader,
  IMPLEMENTATIONS,
  type ImplementationSpec,
  type RegistryTarget,
  type RepoReader,
  type Stage,
  verifyImplementation,
} from "../utils/implementation-verify";

interface Options {
  network: string;
  contract: string;
  implementation: string;
  stage: Stage;
  xrplOwner?: string;
  noBuild: boolean;
}

async function main(): Promise<void> {
  const options = parseOptions(process.argv.slice(2));
  validateNetwork(options.network);
  if (!options.noBuild) {
    execSync("forge build", { stdio: "inherit" });
  }

  const record = loadDeployedContracts(options.network);
  const diamond = findDiamondAddress(record);
  const web3 = new Web3(resolveRpcUrl(options.network));
  await assertRpcChain(web3, options.network);
  const requestedBlock = process.env.VERIFY_BLOCK_TAG ?? "latest";
  const block = Number((await web3.eth.getBlock(requestedBlock)).number);
  const chainId = Number(await web3.eth.getChainId());

  const result = await verifyImplementation({
    network: options.network,
    chainId,
    diamond,
    contract: options.contract,
    implementation: options.implementation,
    stage: options.stage,
    ...(options.xrplOwner !== undefined ? { sampleXrplOwner: options.xrplOwner } : {}),
    repo: fsRepoReader(),
    chain: web3ChainReader(web3, block),
  });

  console.log(`Implementation verification for ${options.network} (stage: ${options.stage})`);
  console.log(`Controller: ${diamond}`);
  console.log(`${options.contract}: ${options.implementation}`);
  console.log(`Block: ${block} (${requestedBlock})`);
  console.log(`Registration calldata: ${result.encodedCall}`);
  for (const note of result.notes) {
    console.log(note);
  }
  console.log("");
  console.log(formatChecks(result.checks));
  if (!allPassed(result.checks)) {
    process.exitCode = 1;
  }
}

function parseOptions(args: string[]): Options {
  const options: Options = { network: "", contract: "", implementation: "", stage: "pre", noBuild: false };
  const positional: string[] = [];
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!;
    if (arg === "--no-build") {
      options.noBuild = true;
    } else if (arg === "--stage") {
      const value = args[++i];
      if (value !== "pre" && value !== "queued" && value !== "live") {
        throw new Error("--stage takes pre, queued or live");
      }
      options.stage = value;
    } else if (arg === "--xrpl-owner") {
      const value = args[++i];
      if (!value) {
        throw new Error("--xrpl-owner needs an XRPL address");
      }
      options.xrplOwner = value;
    } else if (arg.startsWith("--")) {
      throw new Error(`Unknown option ${arg}`);
    } else {
      positional.push(arg);
    }
  }
  const [network, contract, implementation] = positional;
  if (!network || !contract || !implementation || positional.length > 3) {
    console.error(
      "Usage: pnpm verify_implementation <network> <Contract> <address>" +
        " [--stage pre|queued|live] [--xrpl-owner <owner>] [--no-build]\n" +
        `       <Contract> is one of ${Object.keys(IMPLEMENTATIONS).join(", ")}`
    );
    process.exit(2);
  }
  options.network = network;
  options.contract = contract;
  options.implementation = implementation;
  return options;
}

function fsRepoReader(): RepoReader {
  return {
    hasArtifact: (contractName) => existsSync(artifactPathFor(contractName)),
    // the implementations live beside their bases; source presence, not artifact presence, is
    // what says a contract still exists (forge does not prune artifacts of removed sources)
    hasSource: (contractName) => existsSync(`contracts/smartAccounts/implementation/${contractName}.sol`),
    deployedCode: loadDeployedCode,
    creationCode: loadCreationCode,
  };
}

/** `FunctionNotFound(bytes4)`: the diamond does not serve the selector, so the facet is not cut. */
const FUNCTION_NOT_FOUND = "0x5416eb98";
/** `TimelockInvalidSelector()`: the timelock getter's answer for a call that is not queued. */
const TIMELOCK_NOT_QUEUED = "0x08d9e6dc";

function web3ChainReader(web3: Web3, block: number): ChainReader {
  const callAddress = async (to: string, signature: string, params: unknown[] = []): Promise<string> => {
    const value = await callDecoded(web3, to, signature, params, "address", block);
    return String(value).toLowerCase();
  };
  /** Runs a read, returning `undefined` when it reverts with one of the expected errors. */
  const tolerate = async <T>(read: () => Promise<T>, expected: string[]): Promise<T | undefined> => {
    try {
      return await read();
    } catch (error) {
      if (expected.some((selector) => revertSelectors(error).includes(selector))) {
        return undefined;
      }
      throw error;
    }
  };
  return {
    code: (address) => web3.eth.getCode(address, block),
    storage: async (address, slot) => String(await web3.eth.getStorageAt(address, slot, block)),
    registered: (diamond, spec: ImplementationSpec) =>
      tolerate(
        () =>
          spec.target === "personalAccountBeacon"
            ? callAddress(diamond, "implementation()")
            : callAddress(diamond, "implementationForType(uint256)", [String(spec.subaccountType)]),
        [FUNCTION_NOT_FOUND]
      ),
    timelockMaturity: async (diamond, encodedCall) => {
      // the getter reverts TimelockInvalidSelector() for a call it has never recorded; that is
      // this check's "not queued", not an error
      const maturity = await tolerate(
        async () =>
          BigInt(
            String(
              await callDecoded(
                web3,
                diamond,
                "getExecuteTimelockedCallTimestamp(bytes)",
                [encodedCall],
                "uint256",
                block
              )
            )
          ),
        [TIMELOCK_NOT_QUEUED, FUNCTION_NOT_FOUND]
      );
      return maturity ?? 0n;
    },
    timelockDuration: (diamond) =>
      tolerate(
        async () =>
          BigInt(String(await callDecoded(web3, diamond, "getTimelockDurationSeconds()", [], "uint256", block))),
        [FUNCTION_NOT_FOUND]
      ),
    personalAccount: (diamond, xrplOwner) => callAddress(diamond, "getPersonalAccount(string)", [xrplOwner]),
    subaccount: (diamond, xrplOwner, subaccountType) =>
      callAddress(diamond, "getSubaccount(string,uint256)", [xrplOwner, String(subaccountType)]),
    accountIdentity: async (account, target: RegistryTarget): Promise<AccountIdentity> => {
      const identity: AccountIdentity = { controller: await callAddress(account, "controllerAddress()") };
      if (target === "personalAccountBeacon") {
        identity.xrplOwner = String(await callDecoded(web3, account, "xrplOwner()", [], "string", block));
      } else {
        identity.parent = await callAddress(account, "parentPersonalAccount()");
        identity.subaccountType = BigInt(
          String(await callDecoded(web3, account, "subaccountType()", [], "uint256", block))
        );
      }
      return identity;
    },
  };
}

/** One `eth_call` at the fixed block, encoded from the signature and decoded to one value. */
async function callDecoded(
  web3: Web3,
  to: string,
  signature: string,
  params: unknown[],
  returnType: string,
  block: number
): Promise<unknown> {
  const match = /^(\w+)\((.*)\)$/.exec(signature);
  if (!match) {
    throw new Error(`Malformed signature ${signature}`);
  }
  const inputs = match[2] === "" ? [] : match[2]!.split(",").map((type, index) => ({ type, name: `a${index}` }));
  const data = web3.eth.abi.encodeFunctionCall({ type: "function", name: match[1]!, inputs }, params);
  const encoded = await web3.eth.call({ to, data }, block);
  return web3.eth.abi.decodeParameter(returnType, encoded);
}

/** Every 4-byte selector visible in a revert, from the structured fields and the message text. */
function revertSelectors(error: unknown): string[] {
  const seen: string[] = [];
  const walk = (value: unknown, depth: number): void => {
    if (depth > 4 || value === null || value === undefined) {
      return;
    }
    if (typeof value === "string") {
      for (const match of value.matchAll(/0x[0-9a-fA-F]{8,}/g)) {
        seen.push(match[0].slice(0, 10).toLowerCase());
      }
      return;
    }
    if (typeof value === "object") {
      for (const nested of Object.values(value as Record<string, unknown>)) {
        walk(nested, depth + 1);
      }
    }
  };
  walk(error instanceof Error ? { ...error, revertMessage: error.message } : error, 0);
  return seen;
}

main().catch((error: unknown) => {
  const message = error instanceof Error ? error.message : String(error);
  // web3's message for a reverted call names nothing; the revert data is what an operator can
  // actually look up, so it goes on the line too
  const data = revertSelectors(error).filter((selector) => selector !== "0x");
  console.error(data.length === 0 ? message : `${message} (revert data: ${[...new Set(data)].join(", ")})`);
  process.exit(1);
});
