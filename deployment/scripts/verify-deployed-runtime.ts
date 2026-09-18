/**
 * The gate between a run's printed record lines and the deployment record.
 *
 * A deploy script prints its `DEPLOYED:` lines while forge SIMULATES it, so they name what the run
 * intended to deploy rather than what landed. The wrappers already withhold the recorder when forge
 * exits non-zero, which covers the reverted and the refused run; this covers the rest of the gap by
 * asking the chain. Each line is promoted only if its address carries the runtime of the artifact
 * the record names - so a phantom address, a half-broadcast run, or a deployment that landed
 * somewhere other than the simulated address stops here, with the record untouched.
 *
 * The check is exact, then modulo the trailing Solidity metadata, which is the same tolerance the
 * cut planner and the diamond verifier apply: a recompile of unchanged sources can move the CBOR
 * trailer without changing a single instruction.
 *
 * It suits a run whose every entry is a plain contract deployed from this repository's artifacts -
 * the cut flow's facets and initializer. A record naming a proxy would fail it, since a proxy's
 * runtime is the proxy's, not its implementation's, which is why the wrappers opt in rather than
 * this running everywhere by default.
 */
import { readFileSync } from "node:fs";
import Web3 from "web3";
import { assertRpcChain } from "../utils/diamond-inspect";
import { type ContractInfo, parseDeployOutput } from "../utils/deploy-records";
import { hexToBytes, loadDeployedCode, shortHash, stripMetadata } from "../utils/facet-code";
import { resolveRpcUrl, validateNetwork } from "../utils/networks";

const OUTPUT_PATH = "forge-deploy-output.txt";

function printUsageAndExit(): never {
  console.error("Usage: verify-deployed-runtime.ts <network>");
  console.error(`Reads ${OUTPUT_PATH} and checks every DEPLOYED line against the chain.`);
  process.exit(2);
}

/** The artifact a record names: its `contractName` is the source file, `Foo.sol` for `Foo`. */
function artifactNameOf(record: ContractInfo): string {
  return record.contractName.replace(/\.sol$/, "");
}

type Verdict = { record: ContractInfo; ok: boolean; reason: string };

function verdictFor(record: ContractInfo, deployedCode: Buffer): Verdict {
  const expected = loadDeployedCode(artifactNameOf(record));
  if (deployedCode.length === 0) {
    return { record, ok: false, reason: "no code at this address" };
  }
  if (deployedCode.equals(expected)) {
    return { record, ok: true, reason: "runtime matches the artifact" };
  }
  if (stripMetadata(deployedCode).equals(stripMetadata(expected))) {
    return { record, ok: true, reason: "runtime matches the artifact modulo its metadata trailer" };
  }
  return {
    record,
    ok: false,
    reason:
      `runtime is not ${artifactNameOf(record)} ` +
      `(chain ${shortHash(stripMetadata(deployedCode))}, artifact ${shortHash(stripMetadata(expected))})`,
  };
}

async function main(): Promise<void> {
  const [network, ...rest] = process.argv.slice(2);
  if (!network || rest.length > 0) {
    printUsageAndExit();
  }
  validateNetwork(network);

  let output: string;
  try {
    output = readFileSync(OUTPUT_PATH, "utf8");
  } catch {
    console.error(`${OUTPUT_PATH} is missing: there is nothing to promote, and nothing was checked.`);
    process.exit(2);
  }

  const parsed = parseDeployOutput(output);
  // the run's own name for the network, not the caller's: a record file is picked by the former,
  // so a disagreement means the check and the recorder would read different chains
  if (parsed.network !== network) {
    console.error(
      `${OUTPUT_PATH} names network ${parsed.network ?? "(none)"}, this run is ${network} - ` +
        `refusing to check one run's output against another's chain.`
    );
    process.exit(2);
  }
  if (parsed.contracts.length === 0) {
    console.log(`${network}: no DEPLOYED lines - the run deployed nothing, so there is nothing to check.`);
    return;
  }

  const web3 = new Web3(resolveRpcUrl(network));
  await assertRpcChain(web3, network);

  const verdicts: Verdict[] = [];
  for (const record of parsed.contracts) {
    const deployedCode = hexToBytes(await web3.eth.getCode(record.address));
    verdicts.push(verdictFor(record, deployedCode));
  }

  for (const verdict of verdicts) {
    const mark = verdict.ok ? "ok    " : "FAILED";
    console.log(`  ${mark} ${verdict.record.name} @ ${verdict.record.address}: ${verdict.reason}`);
  }

  const failed = verdicts.filter((verdict) => !verdict.ok);
  if (failed.length > 0) {
    console.error(
      `\n${failed.length} of ${verdicts.length} deployments are not on ${network} as printed. Nothing was ` +
        `recorded and ${OUTPUT_PATH} is kept: settle each transaction in this run's ` +
        `broadcast/<script>.s.sol/<chain id>/run-latest.json against the chain - a pending one can still ` +
        `be mined - then delete the lines that did not land and record what is left with ` +
        `\`npx tsx deployment/scripts/save-deployed-addresses.ts\`, or remove the file and run again.`
    );
    process.exit(2);
  }
  console.log(`${network}: all ${verdicts.length} deployments carry the runtime they are recorded as.`);
}

void main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exit(1);
});
