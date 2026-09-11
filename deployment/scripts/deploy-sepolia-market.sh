#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/deploy-sepolia-market.sh <phase>
#   phase: assets | market | fund | reset-feeds
#
# Builds the Coston2 <-> Sepolia rehearsal's loan market on Sepolia, one re-runnable phase at a
# time: the loan token and price feeds, then the oracle and the market on the public Morpho, then
# the liquidity. `reset-feeds` is the one phase that touches feed state. The forge script refuses
# any chain but Sepolia and holds the RPC's chain to the name; the phases that deploy something
# record it in deployment/deploys/sepolia.json, the market phase also writes the market's
# parameters and id to deployment/output-internal/sepolia/market.json.

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 <assets|market|fund|reset-feeds>" >&2
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
if [[ -z "${DEPLOYER_PRIVATE_KEY:-}" ]]; then
  echo "DEPLOYER_PRIVATE_KEY is required" >&2
  exit 2
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
  --private-key "$DEPLOYER_PRIVATE_KEY" \
  --offline \
  --sig "run(string,string)" "$NETWORK" "$PHASE" \
  --broadcast | tee "$OUTPUT"

# only the phases that deploy print record lines; the recorder consumes the output and removes it,
# and a phase that records nothing has nothing to keep
case "$PHASE" in
  assets|market) npx tsx deployment/scripts/save-deployed-addresses.ts ;;
esac
rm -f "$OUTPUT"
