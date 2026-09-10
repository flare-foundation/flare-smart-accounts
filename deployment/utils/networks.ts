// The one place the TypeScript tooling agrees on which network is which, the counterpart of
// deployment/scripts/DeployNetworks.sol for the Forge scripts: the two chain families, the chain
// id each name must answer, and where each RPC comes from. A chain in neither family has no name
// here and every tool refuses it; a rehearsal runs against a fork of the real chain, under its name.
import { existsSync, readFileSync } from "node:fs";

/** The Flare family, where the home accounts live. Each has a public RPC the tooling defaults to. */
export const FLARE_FAMILY_NETWORKS = ["coston2", "coston", "flare", "songbird"];
/**
 * The loan chains, where the remote accounts live: Ethereum, and Sepolia as its testnet. Each has
 * only the pinned deployment - no `-staging` alias - and no default RPC.
 */
export const LOAN_CHAIN_NETWORKS = ["ethereum", "sepolia"];
export const SUPPORTED_BASE_NETWORKS = [...FLARE_FAMILY_NETWORKS, ...LOAN_CHAIN_NETWORKS];

/** The chain id each network's RPC must answer. */
export const CHAIN_IDS: Record<string, number> = {
  flare: 14,
  songbird: 19,
  coston: 16,
  coston2: 114,
  ethereum: 1,
  sepolia: 11155111,
};
/** The families by id, as `DeployNetworks.sol` holds them; the test pins them to the names above. */
export const FLARE_FAMILY_CHAIN_IDS = [14, 19, 16, 114];
export const LOAN_CHAIN_IDS = [1, 11155111];

/** `coston2-staging` -> `coston2`: a staging alias shares its base network's chain and RPC. */
export function baseNetworkName(network: string): string {
  return network.endsWith("-staging") ? network.replace(/-staging$/, "") : network;
}

/** A network name every tool accepts: a known base network, or a Flare-family staging alias. */
export function validateNetwork(network: string): void {
  const baseNetwork = baseNetworkName(network);
  if (!SUPPORTED_BASE_NETWORKS.includes(baseNetwork)) {
    throw new Error(`Invalid network: ${network}`);
  }
  if (LOAN_CHAIN_NETWORKS.includes(baseNetwork) && network !== baseNetwork) {
    // the pin logic keys on the exact network name while the executor keys on the chain id; a
    // staging alias would skip every preview pin check yet execute pinned
    throw new Error(`Unsupported network: ${network} — the loan chains have only the pinned deployment`);
  }
}

/** The chain id a network's RPC must answer; a name without one is not a network here. */
export function expectedChainId(network: string): number {
  const expected = CHAIN_IDS[baseNetworkName(network)];
  if (expected === undefined) {
    throw new Error(`Invalid network: ${network}`);
  }
  return expected;
}

/** The repository's env file under the process environment, which wins: it is what the wrappers export. */
export function loadEnv(): Record<string, string | undefined> {
  return { ...readDotEnv(), ...process.env };
}

/**
 * The RPC for a network: `<NETWORK>_RPC_URL` from the environment or the env file, else the public
 * Flare RPC of a Flare-family network. The loan chains have no default - the variable is required,
 * and it is the same one the deploy wrapper dials.
 */
export function resolveRpcUrl(network: string, env: Record<string, string | undefined> = loadEnv()): string {
  const baseNetwork = baseNetworkName(network);
  const rpcEnvName = `${baseNetwork.toUpperCase()}_RPC_URL`;
  const rpcUrl = env[rpcEnvName];
  if (rpcUrl) {
    return rpcUrl;
  }
  if (!FLARE_FAMILY_NETWORKS.includes(baseNetwork)) {
    throw new Error(`${rpcEnvName} is required for the ${baseNetwork} network`);
  }
  return `https://${baseNetwork}-api.flare.network/ext/C/rpc`;
}

function readDotEnv(): Record<string, string> {
  if (!existsSync(".env")) {
    return {};
  }
  const env: Record<string, string> = {};
  for (const line of readFileSync(".env", "utf8").split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) {
      continue;
    }
    const separator = trimmed.indexOf("=");
    if (separator < 0) {
      continue;
    }
    const key = trimmed.slice(0, separator).trim();
    const value = trimmed
      .slice(separator + 1)
      .trim()
      .replace(/^['"]|['"]$/g, "");
    env[key] = value;
  }
  return env;
}
