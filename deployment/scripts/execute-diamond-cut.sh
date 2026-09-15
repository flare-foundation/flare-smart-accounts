#!/usr/bin/env bash
set -euo pipefail

# Usage: deployment/scripts/execute-diamond-cut.sh <network> <cut-json-file-name-without-extension> [forge args...]
# Example: deployment/scripts/execute-diamond-cut.sh coston2 cut-example
# Example: deployment/scripts/execute-diamond-cut.sh coston2-staging cut-example
# Example: deployment/scripts/execute-diamond-cut.sh coston2 cuts-2026-09-14 --ledger --sender 0xYourLedgerAddress
# Example: deployment/scripts/execute-diamond-cut.sh coston2 cuts-2026-09-14 --account my-deployer --sender 0xKeystoreAddress

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
  echo "Usage: $0 <network> <cut-json-file-name-without-extension> [forge args...]" >&2
  exit 2
fi

NETWORK="$1"
CUT_JSON="$2"

# Detect staging suffix; base network is used for the RPC env var
STAGING="false"
BASE_NETWORK="$NETWORK"
if [[ "$NETWORK" == *-staging ]]; then
  STAGING="true"
  BASE_NETWORK="${NETWORK%-staging}"
fi

# the loan chains have only the pinned deployment (the executor rejects this too)
if [[ ("$BASE_NETWORK" == "ethereum" || "$BASE_NETWORK" == "sepolia") && "$STAGING" == "true" ]]; then
  echo "$NETWORK is not supported: the loan chains have only the pinned deployment" >&2
  exit 2
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

# The cut file's `execute` must be a JSON boolean: Foundry's ABI decoding would execute on a
# truthy non-boolean that the post-cut hook below would not recognise, so anything else is
# rejected before the script runs. A read or parse error aborts here too.
CUT_FILE="deployment/cuts/${NETWORK}/${CUT_JSON}.json"
# the single quotes are the point: the node script is JavaScript, and its template literals must
# reach node unexpanded rather than being substituted by the shell first
# shellcheck disable=SC2016
EXECUTED=$(node -e '
  const c = JSON.parse(require("node:fs").readFileSync(process.argv[1], "utf8"));
  if (c.execute !== undefined && typeof c.execute !== "boolean") {
    console.error(`${process.argv[1]}: "execute" must be a JSON boolean, got ${JSON.stringify(c.execute)}`);
    process.exit(2);
  }
  process.stdout.write(String(c.execute === true));
' "$CUT_FILE")
# Run forge script
forge script deployment/scripts/ExecuteDiamondCut.s.sol:ExecuteDiamondCut \
  --rpc-url "${!RPC_ENV_VAR}" \
  --offline \
  --broadcast \
  --sig "run(string,string,bool)" "$BASE_NETWORK" "$CUT_JSON" "$STAGING" \
  ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"}

# A cut the script executed (`"execute": true`) is read back at once: the diamond must expose
# exactly the recorded facets' selectors with the ERC-165 flags and the owner in place. A cut
# only prepared for governance is verified by hand after governance executes it.
if [[ "$EXECUTED" == "true" ]]; then
  npx tsx deployment/scripts/verify-diamond.ts "$NETWORK" "$CUT_JSON" --no-build
fi
