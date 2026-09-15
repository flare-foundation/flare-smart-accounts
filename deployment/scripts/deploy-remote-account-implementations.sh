#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-remote-account-implementations.sh <network> <selection> [forge args...]
# Selection: `all`, or a comma-separated list of implementation names
# Example: deployment/scripts/deploy-remote-account-implementations.sh sepolia all
# Example: deployment/scripts/deploy-remote-account-implementations.sh sepolia morpho-loan-subaccount
# Example: deployment/scripts/deploy-remote-account-implementations.sh sepolia personal-account,morpho-loan-subaccount
# Example: deployment/scripts/deploy-remote-account-implementations.sh sepolia all --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/deploy-remote-account-implementations.sh sepolia all --account my-deployer --sender 0xKeystoreAddress
#
# The selection is mandatory. Deploying everything is a thing to ask for, not a thing to get by
# omission: once one implementation is live, redeploying it because another changed replaces a
# record other tooling resolves through, and costs a pointless timelocked re-registration.
#
# Names rather than a flag each, because more subaccount types are expected: a new one is a new
# name here and a new row in the preflight's table, and no existing argument moves.
#
# Naming a selection is not the whole guard. A preflight compares each selected implementation
# against the address already recorded, and an unchanged one is SKIPPED - a successful skip, not a
# failure - so `all` can legitimately deploy one and reuse the rest. The preflight validates the
# names themselves, so this wrapper does not keep a second copy of the list.

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

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <network> <all|name[,name...]> [forge args...]" >&2
  exit 2
fi

NETWORK="$1"
SELECTION="$2"

# Detect staging suffix; base network is used for the RPC env var
STAGING="false"
BASE_NETWORK="$NETWORK"
if [[ "$NETWORK" == *-staging ]]; then
  STAGING="true"
  BASE_NETWORK="${NETWORK%-staging}"
fi

# only the loan chains: the remote implementations lay out storage for the loan chains' proxy
# lineages, and the forge script refuses Flare-family chain ids too
case "$BASE_NETWORK" in
  ethereum|sepolia) ;;
  *)
    echo "Unsupported network: $NETWORK" >&2
    exit 2
    ;;
esac

# the loan chains have only the pinned deployment (the cut flow rejects this too)
if [[ ("$BASE_NETWORK" == "ethereum" || "$BASE_NETWORK" == "sepolia") && "$STAGING" == "true" ]]; then
  echo "$NETWORK is not supported: the loan chains have only the pinned deployment" >&2
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

OUTPUT_DIR="deployment/output-internal/$NETWORK"
mkdir -p "$OUTPUT_DIR"

# the preflight runs BEFORE the broadcast so a run that would deploy nothing spends no gas and,
# more to the point, replaces no record
PLAN_FILE="$OUTPUT_DIR/remote-implementations-plan.txt"
npx tsx deployment/scripts/plan-remote-implementations.ts "$BASE_NETWORK" "$SELECTION" --out "$PLAN_FILE"

# one artifact name per line, in the order the script takes them; an empty file is the legitimate
# "nothing changed" answer
CONTRACTS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && CONTRACTS+=("$line")
done < "$PLAN_FILE"

if [[ ${#CONTRACTS[@]} -eq 0 ]]; then
  echo
  echo "Nothing to deploy: every selected implementation is already on chain as this code."
  echo "The deployment record is unchanged. If one of them is not registered yet, that is a"
  echo "separate step: pnpm configure_remote_controller $BASE_NETWORK prepare implementations"
  exit 0
fi

# forge takes a string[] as a bracketed, comma-separated list
CONTRACTS_ARG="[$(IFS=,; echo "${CONTRACTS[*]}")]"

forge script deployment/scripts/DeployRemoteAccountImplementations.s.sol:DeployRemoteAccountImplementations \
  --rpc-url "${!RPC_ENV_VAR}" \
  --offline \
  --sig "run(string,bool,string[])" \
  "$BASE_NETWORK" "$STAGING" "$CONTRACTS_ARG" \
  --broadcast \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
