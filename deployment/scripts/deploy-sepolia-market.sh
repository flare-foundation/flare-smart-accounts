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
# output here, and one that printed record lines names deployments that may have landed. That file
# is evidence the next run's tee would overwrite, so it stops the wrapper until it is dealt with;
# a leftover without record lines deployed nothing and is overwritten. Every deploy wrapper here
# tees to this one path, so the leftover is not necessarily this script's: what it says about
# itself - the network it names, the contracts it recorded - is what points at the run to recover.
if [[ -f "$OUTPUT" ]] && grep -q '^[[:space:]]*DEPLOYED:' "$OUTPUT"; then
  left_network="$(sed -n 's/^[[:space:]]*NETWORK:[[:space:]]*//p' "$OUTPUT" | head -n 1)"
  echo "$OUTPUT is left from a run that deployed something the record never got." >&2
  echo "It names the network ${left_network:-(none named)} and these contracts:" >&2
  sed -n 's/^[[:space:]]*DEPLOYED:[[:space:]]*/  /p' "$OUTPUT" >&2
  echo "Any deploy wrapper writes this file, so start from those lines: they say which script's" >&2
  echo "run to recover, and its receipts are under broadcast/<that script>.s.sol/<chain id>/." >&2
  echo "The recorder writes every DEPLOYED line it finds, and the simulation prints one for each" >&2
  echo "deployment the run intended, landed or not. Settle every transaction hash in that run's" >&2
  echo "run-latest.json against the chain first: no receipt yet is not proof it never landed - a" >&2
  echo "pending one can still be mined - so wait for it or replace it at its nonce. An oracle made" >&2
  echo "by Morpho's factory is in its transaction's logs rather than a receipt's own contract." >&2
  echo "Then delete the lines that did not land, record what is left" >&2
  echo "(npx tsx deployment/scripts/save-deployed-addresses.ts), or remove the file, and run again." >&2
  exit 2
fi

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
