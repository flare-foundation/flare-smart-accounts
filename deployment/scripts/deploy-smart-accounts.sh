#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/deploy-smart-accounts.sh <network> <fullDeploy:boolean>
# Example: scripts/deploy-smart-accounts.sh coston2 false

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <network> <fullDeploy:boolean>" >&2
  exit 2
fi

NETWORK="$1"
FULL_DEPLOY="$2"

# Convert network to uppercase and build env var name
NETWORK_UPPER=$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')
RPC_ENV_VAR="${NETWORK_UPPER}_RPC_URL"

# Load env
if [[ -f .env ]]; then
  set -a
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
# Run forge script
forge script deployment/scripts/DeploySmartAccounts.s.sol:DeploySmartAccounts \
  --rpc-url "${!RPC_ENV_VAR}" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --sig "run(bool)" "$FULL_DEPLOY" \
  --broadcast | tee forge-deploy-output.txt
ts-node deployment/scripts/save-deployed-addresses.ts

