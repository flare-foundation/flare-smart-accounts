import * as fs from "fs";

// Read Forge output from a output file
const outputPath = "forge-deploy-output.txt";
const output = fs.readFileSync(outputPath, "utf8");

const lines = output.split("\n");
type ContractInfo = {
  name: string;
  contractName: string;
  address: string;
};

const contracts: ContractInfo[] = [];
let network: string = "unknown";

lines.forEach((line: string) => {
  const match = line.match(/^\s*DEPLOYED:\s*([^,]+),\s*([^:]+):\s*(0x[a-fA-F0-9]{40})$/);
  const matchNetwork = line.match(/^\s*NETWORK:\s*([a-zA-Z0-9_-]+)/);
  if (match) {
    contracts.push({
      name: match[1].trim(),
      contractName: match[2].trim(),
      address: match[3].trim(),
    });
  } else if (matchNetwork) {
    network = matchNetwork[1].trim();
  }
});

if (network === "unknown") {
  throw new Error("Network name not found in output.");
}
fs.mkdirSync("deployment/deploys", { recursive: true });
const isMock = process.argv[2] === "mock";
fs.writeFileSync(`deployment/deploys/${network}${isMock ? "_mock" : ""}.json`, JSON.stringify(contracts, null, 2));
fs.unlinkSync(outputPath);
console.log(`Saved deployed addresses to deployment/deploys/${network}${isMock ? "_mock" : ""}.json`);
