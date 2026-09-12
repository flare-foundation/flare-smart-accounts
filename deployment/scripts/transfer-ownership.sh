#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/transfer-ownership.sh <network> <expected-current-owner> <new-owner>
# Example: deployment/scripts/transfer-ownership.sh sepolia 0xDeployer... 0xSafe...
#
# Hands the pinned remote controller to a new owner, with the preflight a raw `cast send` has none
# of. transferOwnership is the one call of a deployment that cannot be undone: one step, no
# acceptance from the new owner, no timelock, and a wrong address ends governance of that diamond.
#
# The expected current owner is not decoration: the run compares it against the chain and stops if
# it differs, which is what catches a wrong network or a diamond somebody has already taken. The
# signing key must be that owner.
#
# One case only - the deployer-owned handover at the end of a rehearsal (RUNBOOK Part B). The
# bootstrap's historical owner signs its own transfer from a wallet, which no wrapper can drive, and
# a throwaway controller is never handed on, so there is no target argument.
#
# The broadcast is followed by a SEPARATE verify run: the script's own read-back would see simulated
# state, since forge broadcasts a script's transactions after it returns.

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <network> <expected-current-owner> <new-owner>" >&2
  exit 2
fi

NETWORK="$1"
CURRENT_OWNER="$2"
NEW_OWNER="$3"

# only the loan chains: the Flare family's controllers are governance-owned and their handovers are
# multisig transactions, not something a key here can sign. The forge script refuses them too
case "$NETWORK" in
  ethereum|sepolia) ;;
  *)
    echo "Unsupported network: $NETWORK (the pinned controller lives on ethereum or sepolia)" >&2
    exit 2
    ;;
esac

for address in "$CURRENT_OWNER" "$NEW_OWNER"; do
  if [[ ! "$address" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
    echo "Not an address: $address" >&2
    exit 2
  fi
done

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
  echo "DEPLOYER_PRIVATE_KEY is required: it must be the diamond's current owner" >&2
  exit 2
fi

run_phase() {
  local phase="$1"
  shift
  forge script deployment/scripts/TransferOwnership.s.sol:TransferOwnership \
    --rpc-url "${!RPC_ENV_VAR}" \
    --offline \
    --sig "run(string,string,address,address)" "$NETWORK" "$phase" "$CURRENT_OWNER" "$NEW_OWNER" \
    "$@"
}

run_phase execute --private-key "$DEPLOYER_PRIVATE_KEY" --broadcast
echo
echo "Reading the owner back on chain, now that the transfer has been broadcast..."
run_phase verify
