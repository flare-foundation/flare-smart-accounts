#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-remote-account-implementations.sh <network>
# Example: deployment/scripts/deploy-remote-account-implementations.sh coston2
# Example: deployment/scripts/deploy-remote-account-implementations.sh coston2-staging

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <network>" >&2
  exit 2
fi

NETWORK="$1"

# Detect staging suffix; base network is used for the RPC env var
STAGING="false"
BASE_NETWORK="$NETWORK"
if [[ "$NETWORK" == *-staging ]]; then
  STAGING="true"
  BASE_NETWORK="${NETWORK%-staging}"
fi

# only the loan chain (and the local dev chain): the remote implementations lay out storage
# for the loan chain's proxy lineages, and the forge script refuses Flare-family chain ids too
case "$BASE_NETWORK" in
  ethereum|scdev) ;;
  *)
    echo "Unsupported network: $NETWORK" >&2
    exit 2
    ;;
esac

# Ethereum has only the pinned production deployment (the cut flow rejects this too)
if [[ "$BASE_NETWORK" == "ethereum" && "$STAGING" == "true" ]]; then
  echo "ethereum-staging is not supported: Ethereum has only the pinned production deployment" >&2
  exit 2
fi

NETWORK_UPPER=$(echo "$BASE_NETWORK" | tr '[:lower:]' '[:upper:]')
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

OUTPUT_DIR="deployment/output-internal/$NETWORK"
mkdir -p "$OUTPUT_DIR"

forge script deployment/scripts/DeployRemoteAccountImplementations.s.sol:DeployRemoteAccountImplementations \
  --rpc-url "${!RPC_ENV_VAR}" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --offline \
  --sig "run(string,bool)" "$BASE_NETWORK" "$STAGING" \
  --broadcast | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
