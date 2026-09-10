#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-ethereum-controller.sh <network>
# Example: deployment/scripts/deploy-ethereum-controller.sh sepolia
#
# Reproduces the pinned controller and its three base facets at the production addresses on a
# loan chain - Ethereum, or Sepolia as its rehearsal; the forge script refuses any other chain and
# holds the RPC's chain to this name - and records them in deployment/deploys/<network>.json: the
# record exists only once the contracts do. The follow-up facet cut is a separate, owner-gated step.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <network>" >&2
  exit 2
fi

NETWORK="$1"
case "$NETWORK" in
  ethereum|sepolia) ;;
  *)
    echo "Unsupported network: $NETWORK (the pinned bootstrap runs on ethereum or sepolia)" >&2
    exit 2
    ;;
esac
NETWORK_UPPER=$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')
RPC_ENV_VAR="${NETWORK_UPPER}_RPC_URL"

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

if [[ -z "${!RPC_ENV_VAR:-}" ]]; then
  echo "$RPC_ENV_VAR is required" >&2
  exit 2
fi
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "DEPLOYER_PRIVATE_KEY is required" >&2
  exit 2
fi

forge script deployment/scripts/DeployEthereumController.s.sol:DeployEthereumController \
  --rpc-url "${!RPC_ENV_VAR}" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --offline \
  --sig "run(string)" "$NETWORK" \
  --broadcast | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
