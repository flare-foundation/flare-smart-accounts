#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/configure-remote-controller.sh <network> <prepare|execute|verify> [section] [target]
# Example: deployment/scripts/configure-remote-controller.sh sepolia prepare governance
# Example: deployment/scripts/configure-remote-controller.sh sepolia prepare wiring
# Example: deployment/scripts/configure-remote-controller.sh sepolia execute all throwaway
# Example: deployment/scripts/configure-remote-controller.sh sepolia verify all
#
# Everything the remote controller is configured with after its cut, from
# deployment/chain-config/<network>.json: the roles and timelock duration (governance), the compose
# transport, the loan market and its fee terms (wiring).
#
# Sections: governance (roles, then the timelock duration), transport, market, fees, wiring (the
# last three) and all. Default: governance.
#
# Target: which controller on this chain to configure - `pinned` (the production one the bootstrap
# reproduces) or `throwaway` (the one deploy-remote-controller-throwaway.sh built, found through its
# gitignored `_mock` record). Default: pinned.
#
#   prepare  writes the calls for the owner to submit to deployment/output-internal/<network>/ and
#            prints them. Reads only, and takes no key: the pinned flow's owner is a multisig.
#   execute  submits them, and needs the diamond's current owner to sign: the throwaway flow only.
#            The read-back afterwards is a separate run of the verify phase, against mined state.
#   verify   reads the roles, the duration and the wiring back and fails unless they match the file.

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <network> <prepare|execute|verify> [section] [target]" >&2
  exit 2
fi

NETWORK="$1"
PHASE="$2"
SECTION="${3:-governance}"
TARGET="${4:-pinned}"

# only the loan chains: the Flare family configures inside its own deploy run, and the forge script
# refuses those chain ids too
case "$NETWORK" in
  ethereum|sepolia) ;;
  *)
    echo "Unsupported network: $NETWORK (the remote controller lives on ethereum or sepolia)" >&2
    exit 2
    ;;
esac

case "$PHASE" in
  prepare|execute|verify) ;;
  *)
    echo "Unsupported phase: $PHASE (prepare, execute or verify)" >&2
    exit 2
    ;;
esac

case "$SECTION" in
  governance|transport|market|fees|wiring|all) ;;
  *)
    echo "Unsupported section: $SECTION (governance, transport, market, fees, wiring or all)" >&2
    exit 2
    ;;
esac

case "$TARGET" in
  pinned|throwaway) ;;
  *)
    echo "Unsupported target: $TARGET (pinned or throwaway)" >&2
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

run_phase() {
  local phase="$1"
  shift
  forge script deployment/scripts/ConfigureRemoteController.s.sol:ConfigureRemoteController \
    --rpc-url "${!RPC_ENV_VAR}" \
    --offline \
    --sig "run(string,string,string,string)" "$NETWORK" "$phase" "$SECTION" "$TARGET" \
    "$@"
}

# a key is the execute phase's business alone: prepare and verify only read, and asking for one
# would invite an operator to put the owner's key somewhere it is not needed
if [[ "$PHASE" == "execute" ]]; then
  if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    echo "DEPLOYER_PRIVATE_KEY is required for the execute phase" >&2
    exit 2
  fi
  run_phase execute --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast
  # the run above checks its own work against SIMULATED state: forge collects the transactions and
  # broadcasts them after the script returns. The read-back that means anything is this one, made
  # once they are mined
  echo
  echo "Verifying the configuration on chain, now that the transactions have been broadcast..."
  run_phase verify
else
  run_phase "$PHASE"
fi
