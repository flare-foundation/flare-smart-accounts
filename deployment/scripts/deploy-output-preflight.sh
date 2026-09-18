#!/usr/bin/env bash
# Sourced by every wrapper that tees a forge run to forge-deploy-output.txt, and exercised
# through them by test/tooling/execute-diamond-cut.test.sh and
# test/tooling/deploy-sepolia-market.test.sh. Defines deploy_output_preflight, which refuses to
# start while a previous run's record lines are still sitting there unrecorded.
#
# The file is the staging area between a run and the deployment record: forge prints a
# DEPLOYED line per deployment during the SIMULATION, the wrapper tees them here, and the
# recorder promotes them only once forge has exited. A leftover therefore names deployments
# that may have landed while the record never got them - evidence the next run's tee would
# overwrite. One without record lines deployed nothing and is overwritten silently.
#
# Every deploy wrapper tees to this one path, so the leftover is not necessarily the caller's:
# what it says about itself - the network it names, the contracts it recorded - is what points
# at the run to recover.
#
# Returns 2, after printing what is there and how to settle it, when the run must not proceed.

deploy_output_preflight() {
  local output="${1:-forge-deploy-output.txt}"
  if [[ ! -f "$output" ]] || ! grep -q '^[[:space:]]*DEPLOYED:' "$output"; then
    return 0
  fi
  local left_network
  left_network="$(sed -n 's/^[[:space:]]*NETWORK:[[:space:]]*//p' "$output" | head -n 1)"
  echo "$output is left from a run that deployed something the record never got." >&2
  echo "It names the network ${left_network:-(none named)} and these contracts:" >&2
  sed -n 's/^[[:space:]]*DEPLOYED:[[:space:]]*/  /p' "$output" >&2
  echo "Any deploy wrapper writes this file, so start from those lines: they say which script's" >&2
  echo "run to recover, and its receipts are under broadcast/<that script>.s.sol/<chain id>/." >&2
  echo "The recorder writes every DEPLOYED line it finds, and the simulation prints one for each" >&2
  echo "deployment the run intended, landed or not. Settle every transaction hash in that run's" >&2
  echo "run-latest.json against the chain first: no receipt yet is not proof it never landed - a" >&2
  echo "pending one can still be mined - so wait for it or replace it at its nonce. An oracle made" >&2
  echo "by Morpho's factory is in its transaction's logs rather than a receipt's own contract." >&2
  echo "Then delete the lines that did not land, record what is left" >&2
  echo "(npx tsx deployment/scripts/save-deployed-addresses.ts), or remove the file, and run again." >&2
  return 2
}
