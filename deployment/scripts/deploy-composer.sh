#!/usr/bin/env bash
set -euo pipefail

# Usage: scripts/deploy-composer.sh <network> <onlyImpl:boolean> [forge args...]
# Example: scripts/deploy-composer.sh coston2 false
# Example: scripts/deploy-composer.sh coston2 true
# Example: scripts/deploy-composer.sh coston2 false --ledger --sender 0xYourLedgerAddress
# Example: scripts/deploy-composer.sh coston2 false --account my-deployer --sender 0xKeystoreAddress

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
  echo "Usage: $0 <network> <onlyImpl:boolean> [forge args...]" >&2
  exit 2
fi

NETWORK="$1"
ONLY_IMPL="$2"

# only Flare-family networks: the composer is a Flare-side contract, and the forge script holds
# the RPC's chain to this name
case "$NETWORK" in
  flare|songbird|coston|coston2) ;;
  *)
    echo "Unsupported network: $NETWORK" >&2
    exit 2
    ;;
esac

# Convert network to uppercase and build env var name
NETWORK_UPPER=$(echo "$NETWORK" | tr '[:lower:]' '[:upper:]')
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

if [[ $SIGNER_SUPPLIED -eq 0 ]]; then
  if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
    echo "DEPLOYER_PRIVATE_KEY is required unless a signer is supplied" >&2
    echo "  e.g. --account <name> --sender <address>, or --ledger --sender <address>" >&2
    exit 2
  fi
  FORGE_ARGS+=(--private-key "$DEPLOYER_PRIVATE_KEY")
fi

# Run forge script
# Outputs to forge-deploy-output.txt in root so save-deployed-addresses.ts can pick it up
forge script deployment/scripts/DeployComposer.s.sol:DeployComposer \
  --rpc-url "${!RPC_ENV_VAR}" \
  --offline \
  --sig "run(string,bool)" "$NETWORK" "$ONLY_IMPL" \
  --broadcast \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} | tee forge-deploy-output.txt

npx tsx deployment/scripts/save-deployed-addresses.ts
