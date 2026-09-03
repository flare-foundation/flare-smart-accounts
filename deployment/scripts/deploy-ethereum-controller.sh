#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-ethereum-controller.sh
#
# Reproduces the pinned controller and its three base facets at the production addresses on
# Ethereum (the forge script refuses any other chain id) and records them in
# deployment/deploys/ethereum.json - the record exists only once the contracts do. The
# follow-up facet cut is a separate, owner-gated step.

if [[ $# -ne 0 ]]; then
  echo "Usage: $0" >&2
  exit 2
fi

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

if [[ -z "${ETHEREUM_RPC_URL:-}" ]]; then
  echo "ETHEREUM_RPC_URL is required" >&2
  exit 2
fi
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "DEPLOYER_PRIVATE_KEY is required" >&2
  exit 2
fi

forge script deployment/scripts/DeployEthereumController.s.sol:DeployEthereumController \
  --rpc-url "$ETHEREUM_RPC_URL" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --offline \
  --broadcast | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
