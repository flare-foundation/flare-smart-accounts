#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/transfer-ownership.sh <network> <expected-current-owner> <new-owner> [forge args...]
# Example: deployment/scripts/transfer-ownership.sh sepolia 0xDeployer... 0xSafe...
# Example: deployment/scripts/transfer-ownership.sh sepolia 0xCurrentOwner 0xNewOwner --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/transfer-ownership.sh sepolia 0xCurrentOwner 0xNewOwner --account my-deployer --sender 0xKeystoreAddress
#
# Hands the pinned remote controller to a new owner, with the preflight a raw `cast send` has none
# of. transferOwnership is the one call of a deployment that cannot be undone: one step, no
# acceptance from the new owner, no timelock, and a wrong address ends governance of that diamond.
#
# The expected current owner is not decoration: the run compares it against the chain and stops if
# it differs, which is what catches a wrong network or a diamond somebody has already taken. The
# signer must be that owner.
#
# Both handovers come through here. The bootstrap's historical owner is on hardware and signs the
# transfer at the start of a chain's deployment (RUNBOOK B3, `--ledger --sender`); the deployer-owned
# one at the end of a rehearsal (RUNBOOK Part B) signs with `--account` or the raw key. A throwaway
# controller is never handed on, so there is no target argument.
#
# The broadcast is followed by a SEPARATE verify run: the script's own read-back would see simulated
# state, since forge broadcasts a script's transactions after it returns.

# Arguments up to the first one beginning with "-" are this wrapper's own; from there on they
# are passed through to forge, which is where a signer goes: --account <name> for a keystore,
# --ledger for the hardware path, with --sender. A positional argument never begins with "-",
# so the two need no separator between them.
FORGE_ARGS=()
_own=0
for _arg in "$@"; do
  if [[ "$_arg" == -* ]]; then
    break
  fi
  _own=$((_own + 1))
done
if [[ $_own -lt $# ]]; then
  FORGE_ARGS=("${@:_own+1}")
  set -- "${@:1:_own}"
fi

if [[ $# -ne 3 ]]; then
  echo "Usage: $0 <network> <expected-current-owner> <new-owner> [forge args...]" >&2
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

# A caller-supplied signer replaces the raw key entirely. Which arguments count as one, and
# which combination is refused outright, live in signer-preflight.sh so the classification can
# be tested directly rather than inferred from a deployment.
# shellcheck source=deployment/scripts/signer-preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-preflight.sh"
signer_preflight ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?

if [[ $SIGNER_SUPPLIED -eq 0 ]]; then
  if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    echo "A signer is required, and it must be the diamond's current owner" >&2
    echo "  e.g. --account <name> --sender <address>, or --ledger --sender <address>" >&2
    exit 2
  fi
  FORGE_ARGS+=(--private-key "$DEPLOYER_PRIVATE_KEY")
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

run_phase execute ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} --broadcast
echo
echo "Reading the owner back on chain, now that the transfer has been broadcast..."
run_phase verify
