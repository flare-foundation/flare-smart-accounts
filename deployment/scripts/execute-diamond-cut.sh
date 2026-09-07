#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/execute-diamond-cut.sh <network> <cut-json-file-name-without-extension>
# Example: deployment/scripts/execute-diamond-cut.sh coston2 cut-example
# Example: deployment/scripts/execute-diamond-cut.sh coston2-staging cut-example

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <network> <cut-json-file-name-without-extension>" >&2
  exit 2
fi

NETWORK="$1"
CUT_JSON="$2"

# Detect staging suffix; base network is used for the RPC env var
STAGING="false"
BASE_NETWORK="$NETWORK"
if [[ "$NETWORK" == *-staging ]]; then
  STAGING="true"
  BASE_NETWORK="${NETWORK%-staging}"
fi

# Ethereum has only the pinned production deployment (the executor rejects this too)
if [[ "$BASE_NETWORK" == "ethereum" && "$STAGING" == "true" ]]; then
  echo "ethereum-staging is not supported: Ethereum has only the pinned production deployment" >&2
  exit 2
fi

# Convert base network to uppercase and build env var name
NETWORK_UPPER=$(echo "$BASE_NETWORK" | tr '[:lower:]' '[:upper:]')
RPC_ENV_VAR="${NETWORK_UPPER}_RPC_URL"

# Load env
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

# Validate required envs (bash indirect expansion)
if [[ -z "${!RPC_ENV_VAR:-}" ]]; then
  echo "$RPC_ENV_VAR is required" >&2
  exit 2
fi
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "DEPLOYER_PRIVATE_KEY is required" >&2
  exit 2
fi

# Create output directory if it doesn't exist
OUTPUT_DIR="deployment/output-internal/$NETWORK"
mkdir -p "$OUTPUT_DIR"

# The cut file's `execute` must be a JSON boolean: Foundry's ABI decoding would execute on a
# truthy non-boolean that the post-cut hook below would not recognise, so anything else is
# rejected before the script runs. A read or parse error aborts here too.
CUT_FILE="deployment/cuts/${NETWORK}/${CUT_JSON}.json"
EXECUTED=$(node -e '
  const c = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (c.execute !== undefined && typeof c.execute !== "boolean") {
    console.error(`${process.argv[1]}: "execute" must be a JSON boolean, got ${JSON.stringify(c.execute)}`);
    process.exit(2);
  }
  process.stdout.write(String(c.execute === true));
' "$CUT_FILE")
# Run forge script
forge script deployment/scripts/ExecuteDiamondCut.s.sol:ExecuteDiamondCut \
  --rpc-url "${!RPC_ENV_VAR}" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --offline \
  --broadcast \
  --sig "run(string,string,bool)" "$BASE_NETWORK" "$CUT_JSON" "$STAGING"

# A cut the script executed (`"execute": true`) is read back at once: the diamond must expose
# exactly the recorded facets' selectors with the ERC-165 flags and the owner in place. A cut
# only prepared for governance is verified by hand after governance executes it.
if [[ "$EXECUTED" == "true" ]]; then
  npx tsx deployment/scripts/verify-diamond.ts "$NETWORK" "$CUT_JSON" --no-build
fi
