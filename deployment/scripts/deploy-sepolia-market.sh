#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-sepolia-market.sh <phase> [forge args...]
# Example: deployment/scripts/deploy-sepolia-market.sh market --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/deploy-sepolia-market.sh market --account my-deployer --sender 0xKeystoreAddress
#   phase: assets | market | fund | reset-feeds
#
# Builds the Coston2 <-> Sepolia rehearsal's loan market on Sepolia, one re-runnable phase at a
# time: the loan token and price feeds, then the oracle and the market on the public Morpho, then
# the liquidity. `reset-feeds` is the one phase that touches feed state. The forge script refuses
# any chain but Sepolia and holds the RPC's chain to the name; the phases that deploy something
# record it in deployment/deploys/sepolia.json, the market phase also writes the market's
# parameters and id to deployment/output-internal/sepolia/market.json.

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
  echo "Usage: $0 <assets|market|fund|reset-feeds> [forge args...]" >&2
  exit 2
fi

NETWORK="sepolia"
PHASE="$1"
case "$PHASE" in
  assets|market|fund|reset-feeds) ;;
  *)
    echo "Unknown phase: $PHASE (assets | market | fund | reset-feeds)" >&2
    exit 2
    ;;
esac

if [[ -f .env ]]; then
  set -a
  # shellcheck source=/dev/null
  source .env
  set +a
fi

if [[ -z "${SEPOLIA_RPC_URL:-}" ]]; then
  echo "SEPOLIA_RPC_URL is required" >&2
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

OUTPUT="forge-deploy-output.txt"
# a run that fails after the simulation - forge in the broadcast, or the recorder - leaves its
# output here, and the next run's tee would overwrite it. The preflight is shared with the other
# wrappers that tee, so the leftover it describes may be any of their runs.
# shellcheck source=deployment/scripts/deploy-output-preflight.sh
source "$(dirname "${BASH_SOURCE[0]}")/deploy-output-preflight.sh"
deploy_output_preflight "$OUTPUT" || exit $?

forge script deployment/scripts/DeploySepoliaMarket.s.sol:DeploySepoliaMarket \
  --rpc-url "$SEPOLIA_RPC_URL" \
  --offline \
  --sig "run(string,string)" "$NETWORK" "$PHASE" \
  --broadcast \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} | tee "$OUTPUT"

# only the phases that deploy print record lines; the recorder consumes the output and removes it,
# and a phase that records nothing has nothing to keep
case "$PHASE" in
  assets|market) npx tsx deployment/scripts/save-deployed-addresses.ts ;;
esac
rm -f "$OUTPUT"
