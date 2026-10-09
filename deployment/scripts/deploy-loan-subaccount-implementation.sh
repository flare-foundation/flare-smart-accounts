#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-loan-subaccount-implementation.sh <network> [forge args...]
# Example: deployment/scripts/deploy-loan-subaccount-implementation.sh coston2
# Example: deployment/scripts/deploy-loan-subaccount-implementation.sh coston2-staging
# Example: deployment/scripts/deploy-loan-subaccount-implementation.sh coston2 --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/deploy-loan-subaccount-implementation.sh coston2 --account my-deployer --sender 0xKeystoreAddress

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

# Detect staging suffix; base network is used for the RPC env var
STAGING="false"
BASE_NETWORK="$NETWORK"
if [[ "$NETWORK" == *-staging ]]; then
  STAGING="true"
  BASE_NETWORK="${NETWORK%-staging}"
fi

# only Flare-family networks: the Flare-side implementation lays out
# storage for the Flare proxy lineage - the loan chain gets MorphoLoanSubaccountRemote through
# deploy-remote-account-implementations.sh - and the forge script refuses the loan chains too
case "$BASE_NETWORK" in
  flare|songbird|coston|coston2) ;;
  *)
    echo "Unsupported network: $NETWORK" >&2
    exit 2
    ;;
esac

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
# A caller-supplied signer replaces the raw key entirely. Which arguments count as one, and
# which combination is refused outright, live in signer-preflight.sh so the classification can
# be tested directly rather than inferred from a deployment.
# shellcheck source=deployment/scripts/signer-preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/signer-preflight.sh"
signer_preflight ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?
# this wrapper's output is parsed by the recorder below, so a flag that silences or reshapes it
# is refused here rather than after forge has already broadcast
refuse_output_flags ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?

# a run that fails after the simulation - forge in the broadcast, or the recorder - leaves its
# output here, and the next run's tee would overwrite it. The preflight is shared with the other
# wrappers that tee, so the leftover it describes may be any of their runs.
# shellcheck source=deployment/scripts/deploy-output-preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/deploy-output-preflight.sh"
deploy_output_preflight forge-deploy-output.txt || exit $?

if [[ $SIGNER_SUPPLIED -eq 0 ]]; then
  if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    echo "DEPLOYER_PRIVATE_KEY is required unless a signer is supplied" >&2
    echo "  e.g. --account <name> --sender <address>, or --ledger --sender <address>" >&2
    exit 2
  fi
  FORGE_ARGS+=(--private-key "$DEPLOYER_PRIVATE_KEY")
fi

OUTPUT_DIR="deployment/output-internal/$NETWORK"
mkdir -p "$OUTPUT_DIR"

forge script deployment/scripts/DeployLoanSubaccountImplementation.s.sol:DeployLoanSubaccountImplementation \
  --rpc-url "${!RPC_ENV_VAR}" \
  --offline \
  --sig "run(string,bool)" "$BASE_NETWORK" "$STAGING" \
  --broadcast \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
