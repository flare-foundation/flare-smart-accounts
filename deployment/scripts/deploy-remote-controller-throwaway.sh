#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-remote-controller-throwaway.sh <network>
# Example: deployment/scripts/deploy-remote-controller-throwaway.sh sepolia
#
# A remote controller built from current source and owned by the deploying key: the throwaway mode
# of deployment/RUNBOOK.md Part B, for rehearsing everything downstream of the bootstrap without the
# ceremony. It lands at a different address from the production controller, on purpose, and its
# addresses go to the gitignored `<network>_mock` record so no tool resolves the real deployment
# through them. The production path is deploy-remote-controller-pinned.sh.
#
# Address parity with the Flare side only holds if both sides run the SAME build: deploy the
# matching fresh Flare controller from this commit, not another.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <network>" >&2
  exit 2
fi

NETWORK="$1"

# only the loan chains: the facet set and both implementations are the remote side's, and the forge
# script refuses the Flare-family chain ids too
case "$NETWORK" in
  ethereum|sepolia) ;;
  *)
    echo "Unsupported network: $NETWORK (the remote controller lives on ethereum or sepolia)" >&2
    exit 2
    ;;
esac

# a throwaway on Ethereum is a throwaway with real money beside it, and nothing about the rehearsal
# needs mainnet: the rehearsal chain is Sepolia
if [[ "$NETWORK" == "ethereum" ]]; then
  echo "Refusing: the throwaway deployment is for sepolia; ethereum takes the pinned bootstrap" >&2
  exit 2
fi

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

forge script deployment/scripts/DeployRemoteControllerThrowaway.s.sol:DeployRemoteControllerThrowaway \
  --rpc-url "${!RPC_ENV_VAR}" \
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --offline \
  --sig "run(string)" "$NETWORK" \
  --broadcast | tee forge-deploy-output.txt

# the throwaway record: gitignored, and exempt from the guard on the names the tooling resolves a
# live deployment through, because it describes no live deployment
npx tsx deployment/scripts/save-deployed-addresses.ts mock
