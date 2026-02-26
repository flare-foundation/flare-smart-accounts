#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/deploy-composer.sh <network> <onlyImpl:boolean>
# Example: scripts/deploy-composer.sh coston2 false
# Example: scripts/deploy-composer.sh coston2 true

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <network> <onlyImpl:boolean>" >&2
  exit 2
fi

NETWORK="$1"
ONLY_IMPL="$2"

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

# Run forge script
# Outputs to forge-deploy-output.txt in root so save-deployed-addresses.ts can pick it up
forge script deployment/scripts/DeployComposer.s.sol:DeployComposer \
  --rpc-url "${!RPC_ENV_VAR}" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --sig "run(bool)" "$ONLY_IMPL" \
  --broadcast | tee forge-deploy-output.txt

# Run save script with "composer" arg to save to <network>_composer.json
ts-node deployment/scripts/save-deployed-addresses.ts composer
