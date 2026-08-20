// update-facet-address.ts
import fs from "fs";
import { basename } from "node:path";
import { loadPinnedEthereumAddresses, validateContractName } from "./pinned-constants";

const [filePath, facetName, facetAddress] = process.argv.slice(2);

if (!filePath || !facetName || !facetAddress) {
  console.error("Usage: update-facet-address.ts <filePath> <facetName> <facetAddress>");
  process.exit(1);
}

// the utility is directly executable, so it enforces the invariants itself instead of
// trusting its caller: names must be plain identifiers in canonical spelling, addresses must
// be well-formed, and the pinned Ethereum records may only ever hold their canonical values
const canonicalName = validateContractName(facetName);
if (!/^0x[0-9a-fA-F]{40}$/.test(facetAddress)) {
  throw new Error(`"${facetAddress}": not a well-formed address`);
}
if (canonicalName && basename(filePath) === "ethereum.json") {
  const pins = loadPinnedEthereumAddresses();
  const pinnedAddress =
    canonicalName === "MasterAccountController" ? pins.controllerAddress : pins.baseFacets.get(canonicalName)?.address;
  if (facetAddress.toLowerCase() !== pinnedAddress) {
    throw new Error(
      `${facetName}: only the canonical pinned Ethereum record ` +
        `(${canonicalName} @ ${pinnedAddress}) may be written — refusing ${facetAddress}`
    );
  }
}

interface ContractEntry {
  name: string;
  contractName: string;
  address: string;
}

const data: ContractEntry[] = JSON.parse(fs.readFileSync(filePath, "utf8")) as ContractEntry[];

let found = false;
for (const entry of data) {
  if (entry.name === facetName) {
    entry.address = facetAddress;
    found = true;
    break;
  }
}
if (!found) {
  data.push({ name: facetName, contractName: `${facetName}.sol`, address: facetAddress });
}

fs.writeFileSync(filePath, JSON.stringify(data, null, 2));
console.log(`Updated ${facetName} to ${facetAddress} in ${filePath}`);
