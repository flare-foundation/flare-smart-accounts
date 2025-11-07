#!/usr/bin/env bash

# Usage: ./asset-manager-selectors.sh <FacetName>
# Example: ./asset-manager-selectors.sh InstructionsFacet

set -euo pipefail

FACET_NAME=$1

# Fixed interface name
INTERFACE_NAME="IIMasterAccountController"

# Path
ARTIFACTS_DIR="artifacts"
INTERFACE_JSON_PATH="${ARTIFACTS_DIR}/${INTERFACE_NAME}.sol/${INTERFACE_NAME}.json"
FACET_JSON_PATH="${ARTIFACTS_DIR}/${FACET_NAME}.sol/${FACET_NAME}.json"

# Extract function signatures from interface
INTERFACE_FUNCS=$(jq -r '.abi[] | select(.type == "function") | "\(.name)(\(.inputs | map(.type) | join(",")))"' "$INTERFACE_JSON_PATH")

# Create array for matching selectors
SELECTORS=()

FACET_FUNCS=$(jq -r '.abi[] | select(.type == "function") | "\(.name)(\(.inputs | map(.type) | join(",")))"' "$FACET_JSON_PATH")
# TODO: fix if param is tuple

# iterate over facet functions and check if they appear in the INTERFACE_FUNCS
for sig in $FACET_FUNCS; do
  echo "Checking signature: $sig"
  # Check if the signature exists in the interface functions
  if echo "$INTERFACE_FUNCS" | grep -qF "$sig"; then
    selector=$(cast sig "$sig" 2>/dev/null || true)
    echo $selector
    if [ -n "$selector" ]; then
      SELECTORS+=("$selector")
    fi
  fi
done

# Output ABI-encoded bytes4[] (for use in forge)
SELECTORS_STR="["
for i in "${!SELECTORS[@]}"; do
  if [ "$i" -ne 0 ]; then
    SELECTORS_STR+="," # No space before comma for Solidity array
  fi
  SELECTORS_STR+="${SELECTORS[$i]}"
done
SELECTORS_STR+="]"
SELECTORS_STR="${SELECTORS_STR}"
echo $SELECTORS_STR
cast abi-encode "f(bytes4[])" "$SELECTORS_STR"
