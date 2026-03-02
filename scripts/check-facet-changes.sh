#!/bin/bash

# Script to detect which facets have bytecode changes after modifying a library
# Usage: ./scripts/check-facet-changes.sh [library-name]
# Example: ./scripts/check-facet-changes.sh CustomInstructions.sol

set -e

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACTS_DIR="$PROJECT_ROOT/artifacts"

echo "======================================"
echo "Facet Bytecode Change Detector"
echo "======================================"


# Verify we're in the right directory
if [ ! -d "$ARTIFACTS_DIR" ]; then
    echo "Error: artifacts directory not found at $ARTIFACTS_DIR"
    exit 1
fi

# Capture before state
echo "Capturing bytecode hashes BEFORE changes..."
find "$ARTIFACTS_DIR" -type f -name "*.json" -path "*Facet*" | xargs sha256sum | sort > /tmp/facet_hashes_before.txt
BEFORE_COUNT=$(wc -l < /tmp/facet_hashes_before.txt)
echo "Captured $BEFORE_COUNT artifacts"
echo ""

# Recompile
echo "Compiling with forge build --force..."
cd "$PROJECT_ROOT"
forge build --force > /dev/null 2>&1
echo "Build complete"
echo ""

# Capture after state
echo "Capturing bytecode hashes AFTER changes..."
find "$ARTIFACTS_DIR" -type f -name "*.json" -path "*Facet*" | xargs sha256sum | sort > /tmp/facet_hashes_after.txt
AFTER_COUNT=$(wc -l < /tmp/facet_hashes_after.txt)
echo "Captured $AFTER_COUNT artifacts"
echo ""

# Compare and filter
echo "======================================"
echo "CHANGED IMPLEMENTATION FACETS"
echo "======================================"

CHANGED=$(diff /tmp/facet_hashes_before.txt /tmp/facet_hashes_after.txt | \
    grep -oE "[A-Z][a-zA-Z]*Facet\.json" | \
    grep -v "^I[A-Z]" | \
    sort -u | \
    sed 's/\.json//')

if [ -z "$CHANGED" ]; then
    echo "No facet bytecode changes detected"
    exit 0
fi

echo "$CHANGED" | nl
echo ""

# Summary
FACET_COUNT=$(echo "$CHANGED" | wc -l)
echo "======================================"
echo "Summary: $FACET_COUNT facet(s) need redeployment"
echo "======================================"
echo ""
echo "These facets must be included in the diamond cut:"
echo "$CHANGED" | sed 's/^/  - /'
echo ""

# Cleanup
rm -f /tmp/facet_hashes_before.txt /tmp/facet_hashes_after.txt
