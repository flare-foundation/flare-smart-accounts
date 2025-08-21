import * as fs from 'fs';
import { execSync } from 'child_process';
import glob from 'glob';

// get network from command line argument (mandatory)
const network = process.argv[2];
if (!network) {
  throw new Error('Usage: ts-node verify-contracts.ts <network>');
}
// check if network is valid (flare/songbird/coston/coston2/scdev)
if (!['coston2', 'coston', 'flare', 'songbird', 'scdev'].includes(network)) {
  throw new Error(`Invalid network: ${network}`);
}

// set paths and URLs based on network
const jsonPath = `deployment/deploys/${network}.json`;
const rpcUrl = `https://${network}-api.flare.network/ext/C/rpc`;
const verifierUrl = `https://${network}-explorer.flare.network/api/`;
const verifier = 'blockscout';

const contracts = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));

contracts.forEach((contract: any) => {
  const address = contract.address;
  const contractFile = contract.contractName;
  // remove .sol from contractFile for the contract name
  const contractName = contractFile.replace('.sol', '');
  // find the full path of the contract file
  const matches = glob.sync(`contracts/xrpcw/**/${contractFile}`);
  console.log(matches)
  if (matches.length === 0) {
    throw new Error(`Contract file not found: ${contractFile}`);
  }
  if (matches.length > 1) {
    throw new Error(`Multiple contract files found for ${contractFile}: ${matches.join(', ')}`);
  }
  let contractPath = matches[0];
  const verifyCmd = `forge verify-contract \
    --rpc-url ${rpcUrl} \
    --verifier ${verifier} \
    --verifier-url '${verifierUrl}' \
    ${address} \
    ${contractPath}:${contractName}`;
  console.log(`Verifying: ${address} (${contractFile}:${contractName})`);
  try {
    execSync(verifyCmd, { stdio: 'inherit' });
  } catch (err) {
    if (err instanceof Error) {
      throw err;
    } else {
      throw new Error(String(err));
    }
  }
});
