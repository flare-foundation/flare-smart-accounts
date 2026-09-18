#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/deploy-smart-accounts.sh <network> <fullDeploy:boolean> [forge args...]
# Example: scripts/deploy-smart-accounts.sh coston2 false
# Example: scripts/deploy-smart-accounts.sh coston2-staging false
# Example: scripts/deploy-smart-accounts.sh coston2 false --ledger --sender 0xYourLedgerAddress
# Example: scripts/deploy-smart-accounts.sh coston2 false --account my-deployer --sender 0xKeystoreAddress

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
  echo "Usage: $0 <network> <fullDeploy:boolean> [forge args...]" >&2
  exit 2
fi

NETWORK="$1"
FULL_DEPLOY="$2"

# Detect staging suffix; base network is used for the RPC env var
STAGING="false"
BASE_NETWORK="$NETWORK"
if [[ "$NETWORK" == *-staging ]]; then
  STAGING="true"
  BASE_NETWORK="${NETWORK%-staging}"
fi

# Convert base network to uppercase and build env var name
NETWORK_UPPER=$(echo "$BASE_NETWORK" | tr '[:lower:]' '[:upper:]')
RPC_ENV_VAR="${NETWORK_UPPER}_RPC_URL"

# Load env
if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

# Validate required envs (bash indirect expansion)
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

# Create output directory if it doesn't exist
OUTPUT_DIR="deployment/output-internal/$NETWORK"
mkdir -p "$OUTPUT_DIR"
# Run forge script
forge script deployment/scripts/DeploySmartAccounts.s.sol:DeploySmartAccounts \
  --rpc-url "${!RPC_ENV_VAR}" \
  --offline \
  --sig "run(string,bool,bool)" "$BASE_NETWORK" "$FULL_DEPLOY" "$STAGING" \
  --broadcast \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} | tee forge-deploy-output.txt
npx tsx deployment/scripts/save-deployed-addresses.ts
