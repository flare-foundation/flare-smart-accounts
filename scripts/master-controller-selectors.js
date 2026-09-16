process.removeAllListeners("warning");
process.on("warning", (e) => {
  if (e.name !== "DeprecationWarning") return;
});

const { readFileSync } = require("fs");
const { join } = require("path");
let Web3 = require("web3");
// Support both CommonJS and ESM builds of web3
Web3 = Web3.default || Web3;
const web3 = new Web3();

// Foundry's output directory, which a caller may move. The OFT round-trip runner compiles into a
// scratch directory so concurrent tooling runs stay isolated; reading the repository's own
// `artifacts/` from there would either find nothing, or answer with selectors from an older build.
function artifactsDir() {
  return process.env.FOUNDRY_OUT || "artifacts";
}

function getInterfaceSelectors() {
  const iiMasterAccountControllerArtifactPath = join(
    artifactsDir(),
    "IIMasterAccountController.sol/IIMasterAccountController.json"
  );
  const iiMasterAccountControllerArtifact = JSON.parse(readFileSync(iiMasterAccountControllerArtifactPath, "utf8"));
  const interfaceSelectors = getInterfaceSelectorMap(iiMasterAccountControllerArtifact.abi);
  return interfaceSelectors;
}

function getInterfaceSelectorMap(abiItems) {
  const interfaceSelectorPairs = abiItems
    .filter((it) => it.type === "function")
    .map((it) => [web3.eth.abi.encodeFunctionSignature(it), it]);
  return new Map(interfaceSelectorPairs);
}

function getContractSelectors(contractName) {
  const filterSelectors = getInterfaceSelectors();
  const contractArtifactPath = join(artifactsDir(), `${contractName}.sol/${contractName}.json`);
  const contractArtifact = JSON.parse(readFileSync(contractArtifactPath, "utf8"));
  const contractSelectors = contractArtifact.abi
    .filter((it) => it.type === "function")
    .map((it) => web3.eth.abi.encodeFunctionSignature(it));
  const exposedSelectors = contractSelectors.filter((sel) => filterSelectors.has(sel));
  return exposedSelectors;
}

if (require.main === module) {
  const contractName = process.argv[2];
  if (!contractName) {
    console.error("Usage: node asset-manager-selectors.js <ContractName>");
    process.exit(1);
  }
  const selectors = getContractSelectors(contractName);
  // Output ABI-encoded bytes4[]
  process.stdout.write(web3.eth.abi.encodeParameter("bytes4[]", selectors));
}
