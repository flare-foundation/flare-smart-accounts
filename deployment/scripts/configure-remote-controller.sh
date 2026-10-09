#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/configure-remote-controller.sh <network> <prepare|execute|verify> [section] [target] [forge args...]
# Example: deployment/scripts/configure-remote-controller.sh sepolia prepare governance
# Example: deployment/scripts/configure-remote-controller.sh sepolia prepare wiring
# Example: deployment/scripts/configure-remote-controller.sh sepolia execute all throwaway
# Example: deployment/scripts/configure-remote-controller.sh sepolia verify all
# Example: deployment/scripts/configure-remote-controller.sh sepolia prepare governance --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/configure-remote-controller.sh sepolia prepare governance --account my-deployer --sender 0xKeystoreAddress
#
# Everything the remote controller is configured with after its cut, from
# deployment/chain-config/<network>.json: the roles and timelock duration (governance), the compose
# transport, the loan market and its fee terms (wiring). The implementations section is the one
# exception: its two addresses are deploy outputs, read from the target's deployment record.
#
# Sections: governance (roles, then the timelock duration), implementations (the remote Personal
# Account and the type's remote subaccount), transport, market, fees, wiring (the last three) and
# all. Default: governance.
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

if [[ $# -lt 2 || $# -gt 4 ]]; then
  echo "Usage: $0 <network> <prepare|execute|verify> [section] [target] [forge args...]" >&2
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
  governance|implementations|transport|market|fees|wiring|all) ;;
  *)
    echo "Unsupported section: $SECTION (governance, implementations, transport, market, fees," \
      "wiring or all)" >&2
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
  # A caller-supplied signer replaces the raw key entirely. Which arguments count as one, and
  # which combination is refused outright, live in signer-preflight.sh so the classification can
  # be tested directly rather than inferred from a deployment.
  # shellcheck source=deployment/scripts/signer-preflight.sh
  source "$(dirname "${BASH_SOURCE[0]}")/signer-preflight.sh"
  signer_preflight ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?

  if [[ $SIGNER_SUPPLIED -eq 0 ]]; then
    if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
      echo "A signer is required for the execute phase" >&2
      echo "  e.g. --account <name> --sender <address>, or --ledger --sender <address>" >&2
      exit 2
    fi
    FORGE_ARGS+=(--private-key "$DEPLOYER_PRIVATE_KEY")
  fi
  run_phase execute ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} --broadcast
  # the run above checks its own work against SIMULATED state: forge collects the transactions and
  # broadcasts them after the script returns. The read-back that means anything is this one, made
  # once they are mined
  echo
  echo "Verifying the configuration on chain, now that the transactions have been broadcast..."
  run_phase verify
else
  run_phase "$PHASE" ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"}
fi
