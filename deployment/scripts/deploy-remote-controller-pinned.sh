#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-remote-controller-pinned.sh <network> [forge args...]
# Example: deployment/scripts/deploy-remote-controller-pinned.sh sepolia
# Example: deployment/scripts/deploy-remote-controller-pinned.sh sepolia --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/deploy-remote-controller-pinned.sh sepolia --account my-deployer --sender 0xKeystoreAddress
#
# Reproduces the pinned controller and its three base facets at the production addresses on a
# loan chain - Ethereum, or Sepolia as its rehearsal; the forge script refuses any other chain and
# holds the RPC's chain to this name - and records them in deployment/deploys/<network>.json: the
# record exists only once the contracts do. The follow-up facet cut is a separate, owner-gated step.

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

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <network> [forge args...]" >&2
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
# A caller-supplied signer replaces the raw key entirely. Which arguments count as one, and
# which combination is refused outright, live in signer-preflight.sh so the classification can
# be tested directly rather than inferred from a deployment.
# shellcheck source=deployment/scripts/signer-preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-preflight.sh"
signer_preflight ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?
# this wrapper's output is parsed by the recorder below, so a flag that silences or reshapes it
# is refused here rather than after forge has already broadcast
refuse_output_flags ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?

if [[ $SIGNER_SUPPLIED -eq 0 ]]; then
  if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    echo "DEPLOYER_PRIVATE_KEY is required unless a signer is supplied" >&2
    echo "  e.g. --account <name> --sender <address>, or --ledger --sender <address>" >&2
    exit 2
  fi
  FORGE_ARGS+=(--private-key "$DEPLOYER_PRIVATE_KEY")
fi

forge script deployment/scripts/DeployRemoteControllerPinned.s.sol:DeployRemoteControllerPinned \
  --rpc-url "${!RPC_ENV_VAR}" \
  --offline \
  --sig "run(string)" "$NETWORK" \
  --broadcast \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
