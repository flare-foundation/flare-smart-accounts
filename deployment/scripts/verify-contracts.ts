import * as fs from "fs";
import { execSync } from "child_process";
import glob from "glob";

// get network from command line argument (mandatory)
const network = process.argv[2];
if (!network) {
  throw new Error("Usage: ts-node verify-contracts.ts <network>");
}
// check if network is valid (supports base networks and any "*-staging")
const allowedBaseNetworks = ["coston2", "coston", "flare", "songbird", "scdev"];
const isValidNetwork = allowedBaseNetworks.includes(network) || (network.endsWith("-staging") && allowedBaseNetworks.includes(network.replace(/-staging$/, "")));
if (!isValidNetwork) {
  throw new Error(`Invalid network: ${network}`);
}
console.log(`Verifying contracts on network: ${network}`);

const isMock = process.argv[3] === "mock";
// set paths and URLs based on network
const addressesFilePath = `deployment/deploys/${network}${isMock ? "_mock" : ""}.json`;
// for any "*-staging" network, use the base network for RPC and verifier
const baseNetwork = network.endsWith("-staging") ? network.replace(/-staging$/, "") : network;
const rpcUrl = `https://${baseNetwork}-api.flare.network/ext/C/rpc`;
const verifierUrl = `https://${baseNetwork}-explorer.flare.network/api/`;
const verifier = "blockscout";


const raw: unknown = JSON.parse(fs.readFileSync(addressesFilePath, "utf8"));
if (!Array.isArray(raw)) {
  throw new Error("Invalid contract info format");
}
const contracts = raw.map((item) => {
  if (
    typeof item === "object" &&
    item !== null &&
    typeof (item as { address?: unknown }).address === "string" &&
    typeof (item as { contractName?: unknown }).contractName === "string" &&
    typeof (item as { name?: unknown }).name === "string"
  ) {
    return {
      name: (item as { name?: unknown }).name,
      contractName: (item as { contractName: string }).contractName,
      address: (item as { address: string }).address,
    };
  }
  throw new Error("Invalid contract info item");
});

contracts.forEach(contract => {
  const address = contract.address;
  const contractFile = contract.contractName;
  // remove .sol from contractFile for the contract name
  const contractName = contractFile.replace(".sol", "");
  // find the full path of the contract file
  const matches = glob.sync(`contracts/{smartAccounts,diamond}/**/${contractFile}`);
  console.log(matches);
  if (matches.length === 0) {
    throw new Error(`Contract file not found: ${contractFile}`);
  }
  if (matches.length > 1) {
    throw new Error(`Multiple contract files found for ${contractFile}: ${matches.join(", ")}`);
  }
  const contractPath = matches[0];
  const verifyCmd = `forge verify-contract \
    --rpc-url ${rpcUrl} \
    --verifier ${verifier} \
    --verifier-url '${verifierUrl}' \
    ${address} \
    ${contractPath}:${contractName} \
    --skip-is-verified-check`;
  console.log(`Verifying: ${address} (${contractFile}:${contractName})`);
  try {
    execSync(verifyCmd, { stdio: "inherit" });
  } catch (err) {
    if (err instanceof Error) {
      throw err;
    } else {
      throw new Error(String(err));
    }
  }
});
