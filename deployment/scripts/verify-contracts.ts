import { execFileSync } from "node:child_process";
import { globSync, readFileSync } from "node:fs";
import Web3 from "web3";
import { assertRpcChain } from "../utils/diamond-inspect";
import { FLARE_FAMILY_NETWORKS, baseNetworkName, loadEnv, resolveRpcUrl, validateNetwork } from "../utils/networks";

// Source verification on the block explorers, driven by the record save-deployed-addresses.ts
// writes. Every explorer a chain has is submitted to, not just one: a reader who arrives at
// Etherscan should not see unverified source because we happened to publish to Blockscout.
// Re-runnable, since --skip-is-verified-check resubmits rather than aborting, and failures are
// collected per explorer and reported at the end instead of stopping the batch.

interface Explorer {
  label: string;
  args: string[];
}

interface DeployedContract {
  name: string;
  contractName: string;
  address: string;
}

function blockscout(url: string): Explorer {
  return { label: `blockscout (${new URL(url).host})`, args: ["--verifier", "blockscout", "--verifier-url", url] };
}

// One Etherscan V2 key covers every chain they support. Absent, that explorer is skipped with a
// note rather than failing the run.
function etherscan(chain: string, env: Record<string, string | undefined>): Explorer | undefined {
  const key = env["ETHERSCAN_API_KEY"];
  if (!key) {
    console.log(`  (no ETHERSCAN_API_KEY - skipping Etherscan for ${chain})`);
    return undefined;
  }
  return { label: "etherscan", args: ["--chain", chain, "--etherscan-api-key", key] };
}

function explorersFor(baseNetwork: string, env: Record<string, string | undefined>): Explorer[] {
  // the Flare chains run Blockscout only, at a predictable host and without a key
  if (FLARE_FAMILY_NETWORKS.includes(baseNetwork)) {
    return [blockscout(`https://${baseNetwork}-explorer.flare.network/api/`)];
  }
  const configured = (candidates: (Explorer | undefined)[]) =>
    candidates.filter((explorer): explorer is Explorer => explorer !== undefined);
  switch (baseNetwork) {
    case "ethereum":
      return configured([blockscout("https://eth.blockscout.com/api/"), etherscan("mainnet", env)]);
    case "sepolia":
      return configured([blockscout("https://eth-sepolia.blockscout.com/api/"), etherscan("sepolia", env)]);
    default:
      throw new Error(`No explorer is configured for ${baseNetwork}`);
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
    const matches = globSync(`contracts/{smartAccounts,diamond,composer}/**/${contract.contractName}`);
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
        execFileSync("forge", args, { stdio: "inherit" });
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
