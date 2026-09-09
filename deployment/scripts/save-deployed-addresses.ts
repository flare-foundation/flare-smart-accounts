import fs from "node:fs";
import { PROTECTED_ETHEREUM_NAMES, loadPinnedEthereumAddresses, validateContractName } from "../utils/pinned-constants";
import {
  type ContractInfo,
  PROTECTED_RECORD_NAMES,
  mergeDeployedRecords,
  parseAllowedReplacements,
} from "../utils/deploy-records";

// Read Forge output from a output file
const outputPath = "forge-deploy-output.txt";
const output = fs.readFileSync(outputPath, "utf8");

const lines = output.split("\n");
const contracts: ContractInfo[] = [];
let network: string = "unknown";

lines.forEach((line: string) => {
  const match = line.match(/^\s*DEPLOYED:\s*([^,]+),\s*([^:]+):\s*(0x[a-fA-F0-9]{40})$/);
  const matchNetwork = line.match(/^\s*NETWORK:\s*([a-zA-Z0-9_-]+)/);
  if (match && match[1] && match[2] && match[3]) {
    contracts.push({
      name: match[1].trim(),
      contractName: match[2].trim(),
      address: match[3].trim(),
    });
  } else if (matchNetwork && matchNetwork[1]) {
    network = matchNetwork[1].trim();
  }
});

if (network === "unknown") {
  throw new Error("Network name not found in output");
}

const allowedBaseNetworks = ["coston2", "coston", "flare", "songbird", "scdev", "ethereum"];
const isValidNetwork =
  allowedBaseNetworks.includes(network) ||
  (network.endsWith("-staging") && allowedBaseNetworks.includes(network.replace(/-staging$/, "")));
if (!isValidNetwork) {
  throw new Error(`Invalid network: ${network}`);
}

// the four pinned Ethereum records are chain-recovered facts, not build outputs: on ethereum
// a protected name (in any casing - development filesystems can be case-insensitive) may only
// ever be recorded with its canonical spelling and canonical pinned address, whether or not a
// record already exists - the pinned bootstrap records through here too, so this is what keeps
// it from ever writing anything but the pins
function checkProtectedEthereumRecord(record: ContractInfo): void {
  const canonical = PROTECTED_ETHEREUM_NAMES.find(
    (protectedName) => protectedName.toLowerCase() === record.name.toLowerCase()
  );
  if (!canonical) return;
  const pins = loadPinnedEthereumAddresses();
  const pinnedAddress =
    canonical === "MasterAccountController" ? pins.controllerAddress : pins.baseFacets.get(canonical)?.address;
  if (record.name !== canonical || record.address.toLowerCase() !== pinnedAddress) {
    throw new Error(
      `${record.name}: only the canonical pinned Ethereum record ` +
        `(${canonical} @ ${pinnedAddress}) may be written — refusing ${record.address}`
    );
  }
}

fs.mkdirSync("deployment/deploys", { recursive: true });
const isMock = process.argv[2] === "mock";
const filePath = `deployment/deploys/${network}${isMock ? "_mock" : ""}.json`;

let existingContracts: ContractInfo[] = [];
if (fs.existsSync(filePath)) {
  const raw: unknown = JSON.parse(fs.readFileSync(filePath, "utf8"));
  if (!Array.isArray(raw)) {
    throw new Error(`Invalid contract info format in ${filePath}`);
  }
  existingContracts = raw.map((item) => {
    if (
      typeof item === "object" &&
      item !== null &&
      typeof (item as { name?: unknown }).name === "string" &&
      typeof (item as { contractName?: unknown }).contractName === "string" &&
      typeof (item as { address?: unknown }).address === "string"
    ) {
      return {
        name: (item as { name: string }).name,
        contractName: (item as { contractName: string }).contractName,
        address: (item as { address: string }).address,
      };
    }
    throw new Error(`Invalid contract info item in ${filePath}`);
  });
}

for (const deployed of contracts) {
  // every record name must be a plain identifier in canonical spelling on every network:
  // record names become artifact path components downstream, and a path or case alias
  // (`./OwnershipFacet`) would not equal a protected name under whole-string comparison
  validateContractName(deployed.name);
  if (network === "ethereum") {
    checkProtectedEthereumRecord(deployed);
  }
}

// records follow their redeployments freely, which is what the deploy scripts are for; the two
// that name a live contract the tooling resolves through may not change quietly - deploy-records.ts
//
// scdev and the `_mock` files are exempt. Both are throwaway records, gitignored rather than
// tracked, and neither describes a live deployment. A local loop that edits a base facet changes
// the controller's CREATE2 input and so its address on every iteration, so enforcing the guard
// there would make the override part of everyone's environment permanently - which is exactly how
// a guard stops guarding anything.
const isThrowawayRecord = network === "scdev" || isMock;
const merged = mergeDeployedRecords(
  existingContracts,
  contracts,
  isThrowawayRecord ? new Set(PROTECTED_RECORD_NAMES) : parseAllowedReplacements(process.env.ALLOW_RECORD_REPLACEMENT)
);

fs.writeFileSync(filePath, JSON.stringify(merged, null, 2));
fs.unlinkSync(outputPath);
console.log(`Saved deployed addresses to ${filePath}`);
