import { execFileSync } from "node:child_process";
import { globSync, readFileSync } from "node:fs";
import Web3 from "web3";
import { assertRpcChain } from "../utils/diamond-inspect";
import { FLARE_FAMILY_NETWORKS, baseNetworkName, loadEnv, resolveRpcUrl, validateNetwork } from "../utils/networks";

// Source verification on the block explorers, driven by the record save-deployed-addresses.ts
// writes. Every verifier a chain has is submitted to, not just one: a reader who arrives at
// Etherscan should not see unverified source because we happened to publish to Blockscout, and
// Sourcify holds a record no explorer owns. Re-runnable, since --skip-is-verified-check resubmits
// rather than aborting, and failures are collected per explorer and reported at the end instead
// of stopping the batch.

interface Explorer {
  label: string;
  args: string[];
  /**
   * How long to wait before submitting to THIS explorer. Rate limits are per host, so the wait
   * that matters is the one the next submission is about to meet, not a single figure for the run.
   */
  delayMs: number;
}

interface DeployedContract {
  name: string;
  contractName: string;
  address: string;
}

// Public Blockscout instances rate-limit hard: a run's submissions back to back exhaust the window,
// and forge's own retries (five, five seconds apart) do not outlast it, so every Blockscout
// submission fails at once. Spacing them trades a few minutes for not needing the retries at all.
//
// A KEY BUYS NOTHING HERE, so the wait is not conditioned on holding one. Measured 2026-09-15
// against the `/api` endpoint this verifies through, one burst of 15 per arm, each the first thing a
// freshly changed IP did: keyless served 10 and was limited on the 11th; keyed served 10 and was
// limited on the 11th. Identical, because the key is for a different service: it is a PRO key for
// api.blockscout.com, and this per-chain host does not know that token. That host's own key page now
// says chain-specific keys are deprecated and directs to the PRO API, so NO key exists that it will
// honour - its limiting is per IP. A run that shortened its spacing on seeing a key would therefore
// FAIL rather than finish sooner. The key is still passed whenever it is set.
const BLOCKSCOUT_DELAY_MS = 20_000;

// Etherscan and Sourcify never needed Blockscout's figure - Etherscan's free tier allows several
// calls a second and Sourcify is generous - and paying it for them was the larger half of a run's
// waiting: on Sepolia, two of every three submissions. Enough to stay well inside both.
const DEFAULT_SUBMIT_DELAY_MS = 1_000;

// Blockscout's API is Etherscan-compatible, so its key travels in the same flag forge uses for
// Etherscan. Rate limits vary by instance and endpoint: the public Sepolia instance refused every
// keyless submission after the first two in a run, at either spacing, while the Flare instances
// have taken keyless runs; a key raises the limit where the instance honours it.
function blockscout(url: string, env: Record<string, string | undefined>): Explorer {
  const args = ["--verifier", "blockscout", "--verifier-url", url];
  const key = env["BLOCKSCOUT_API_KEY"];
  if (key) {
    args.push("--etherscan-api-key", key);
  } else {
    console.log(`  (no BLOCKSCOUT_API_KEY - keyless submissions may be rate-limited, depending on the instance)`);
  }
  return {
    label: `blockscout (${new URL(url).host})`,
    args,
    delayMs: BLOCKSCOUT_DELAY_MS,
  };
}

// Chain-agnostic, keyless and owned by no explorer, so the record outlives any one of them losing
// or rebuilding its index. Named explicitly: forge reaches Sourcify on its own only when no
// verifier and no Etherscan key are given, which is neither of the paths below. Only for chains
// Sourcify lists - submitting to one it does not support fails the run for nothing.
function sourcify(): Explorer {
  return { label: "sourcify", args: ["--verifier", "sourcify"], delayMs: DEFAULT_SUBMIT_DELAY_MS };
}

// One Etherscan V2 key covers every chain they support. Absent, that explorer is skipped with a
// note rather than failing the run.
function etherscan(chain: string, env: Record<string, string | undefined>): Explorer | undefined {
  const key = env["ETHERSCAN_API_KEY"];
  if (!key) {
    console.log(`  (no ETHERSCAN_API_KEY - skipping Etherscan for ${chain})`);
    return undefined;
  }
  return {
    label: "etherscan",
    args: ["--chain", chain, "--etherscan-api-key", key],
    delayMs: DEFAULT_SUBMIT_DELAY_MS,
  };
}

function explorersFor(baseNetwork: string, env: Record<string, string | undefined>): Explorer[] {
  // the Flare chains have no Etherscan instance: Blockscout at a predictable host and without a
  // key, plus Sourcify wherever it lists the chain - Coston (16) it does not, so that one's source
  // lives in Blockscout's database alone
  if (FLARE_FAMILY_NETWORKS.includes(baseNetwork)) {
    const explorers = [blockscout(`https://${baseNetwork}-explorer.flare.network/api/`, env)];
    if (baseNetwork !== "coston") {
      explorers.push(sourcify());
    }
    return explorers;
  }
  const configured = (candidates: (Explorer | undefined)[]) =>
    candidates.filter((explorer): explorer is Explorer => explorer !== undefined);
  switch (baseNetwork) {
    case "ethereum":
      return configured([blockscout("https://eth.blockscout.com/api/", env), etherscan("mainnet", env), sourcify()]);
    case "sepolia":
      return configured([
        blockscout("https://eth-sepolia.blockscout.com/api/", env),
        etherscan("sepolia", env),
        sourcify(),
      ]);
    default:
      throw new Error(`No explorer is configured for ${baseNetwork}`);
  }
}

/**
 * The operator's override, or `undefined` to let each explorer ask for what it needs.
 *
 * Validated rather than coerced, and before any work: `Number("20s")` is NaN, and a NaN delay would
 * skip every wait while looking configured. Blank is the other coercion to refuse - `Number("")` and
 * `Number(" ")` are both 0, so an empty assignment would silently disable the spacing; it reads as
 * "not configured" here instead, which is what an empty entry in an env template means and leaves
 * the protection on. Disabling stays an explicit numeric zero, and an override applies to EVERY
 * explorer, since someone who names a figure is overruling the judgement, not refining it.
 */
function submitDelayOverrideMs(env: Record<string, string | undefined>): number | undefined {
  const raw = env["VERIFY_SUBMIT_DELAY_MS"];
  if (raw === undefined || raw.trim() === "") {
    return undefined;
  }
  const parsed = Number(raw);
  if (!Number.isFinite(parsed) || parsed < 0) {
    throw new Error(`VERIFY_SUBMIT_DELAY_MS must be a non-negative number of milliseconds, got "${raw}"`);
  }
  return parsed;
}

// Synchronous on purpose: the submissions are execFileSync, and threading async through the loop
// would buy nothing but reordering hazards.
function pause(ms: number): void {
  if (ms > 0) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  }
}

function loadRecord(recordPath: string): DeployedContract[] {
  const raw: unknown = JSON.parse(readFileSync(recordPath, "utf8"));
  if (!Array.isArray(raw)) {
    throw new Error(`${recordPath} is not an array`);
  }
  return raw.map((item) => {
    if (
      typeof item === "object" &&
      item !== null &&
      typeof (item as { address?: unknown }).address === "string" &&
      typeof (item as { contractName?: unknown }).contractName === "string" &&
      typeof (item as { name?: unknown }).name === "string"
    ) {
      return {
        name: (item as { name: string }).name,
        contractName: (item as { contractName: string }).contractName,
        address: (item as { address: string }).address,
      };
    }
    throw new Error(`Invalid entry in ${recordPath}: ${JSON.stringify(item)}`);
  });
}

async function main(): Promise<void> {
  const network = process.argv[2];
  if (!network) {
    throw new Error("Usage: tsx verify-contracts.ts <network> [mock]");
  }
  validateNetwork(network);
  const isMock = process.argv[3] === "mock";
  const env = loadEnv();
  const delayOverrideMs = submitDelayOverrideMs(env);
  // the same variable the deploy wrapper dials, and the chain it answers is checked before anything
  // is submitted: an explorer does not know which chain a record belongs to
  const rpcUrl = resolveRpcUrl(network, env);
  await assertRpcChain(new Web3(rpcUrl), network);
  const explorers = explorersFor(baseNetworkName(network), env);
  if (explorers.length === 0) {
    throw new Error(`No explorer available for ${network}`);
  }

  const recordPath = `deployment/deploys/${network}${isMock ? "_mock" : ""}.json`;
  const contracts = loadRecord(recordPath);
  console.log(
    `Verifying ${contracts.length} contract(s) on ${network} at: ${explorers.map((e) => e.label).join(", ")}`
  );

  const failed: string[] = [];
  let attempted = 0;
  for (const contract of contracts) {
    const contractName = contract.contractName.replace(/\.sol$/, "");
    // the rehearsal market's assets live in contracts/mock, so the search covers it as well
    const matches = globSync(`contracts/{smartAccounts,diamond,composer,mock}/**/${contract.contractName}`);
    if (matches.length === 0) {
      console.log(
        `Skipping ${contract.address} (${contract.contractName}): source file not in repo (removed contract)`
      );
      continue;
    }
    if (matches.length > 1) {
      throw new Error(`Multiple contract files found for ${contract.contractName}: ${matches.join(", ")}`);
    }

    for (const explorer of explorers) {
      // the wait before a submission is the one THAT explorer needs: a Blockscout key raises its
      // limit, and Etherscan and Sourcify never wanted the keyless Blockscout figure at all
      const delayMs = delayOverrideMs ?? explorer.delayMs;
      if (attempted > 0 && delayMs > 0) {
        console.log(`\nWaiting ${(delayMs / 1000).toFixed(1)}s before submitting to ${explorer.label}...`);
        pause(delayMs);
      }
      attempted += 1;
      // one argument vector and no shell: an RPC URL carries a query string more often than not,
      // and a `&` inside a shell command line ends the argument and starts another command
      const args = [
        "verify-contract",
        contract.address,
        `${matches[0]}:${contractName}`,
        "--rpc-url",
        rpcUrl,
        ...explorer.args,
        "--skip-is-verified-check",
        "--watch",
      ];
      console.log(`\nVerifying ${contract.name} at ${contract.address} (${contractName}) on ${explorer.label}`);
      try {
        // the nightly banner would repeat once per submission and bury the result it precedes.
        // ETHERSCAN_API_KEY is blanked, not left alone: forge falls back to it for ANY verifier's
        // key flag - from the environment, or from the env file forge loads on its own, which is
        // why deleting the variable is not enough - and a keyless Blockscout submission would
        // carry the Etherscan key to Blockscout. Each explorer is handed its own key by argument
        // above, and an explicit empty value is what stops the fallback (verified against a local
        // capture endpoint: the request then carries no key field at all)
        execFileSync("forge", args, {
          stdio: "inherit",
          env: { ...process.env, FOUNDRY_DISABLE_NIGHTLY_WARNING: "1", ETHERSCAN_API_KEY: "" },
        });
      } catch {
        console.log(`FAILED: ${contract.name} at ${contract.address} on ${explorer.label}`);
        failed.push(`${contract.name} (${contract.address}) on ${explorer.label}`);
      }
    }
  }

  if (failed.length > 0) {
    console.log(`\n${failed.length} of ${attempted} submission(s) failed:`);
    failed.forEach((entry) => console.log(`  ${entry}`));
    process.exitCode = 1;
    return;
  }
  console.log(`\nAll ${attempted} submission(s) succeeded on ${network}`);
}

main().catch((error: unknown) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
