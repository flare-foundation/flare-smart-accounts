#!/bin/bash

# Extract all error definitions from Solidity files in folder contracts and get their 4-byte selectors
# Usage: ./scripts/extract-error-selectors.sh [output-file]

OUTPUT_FILE="${1:-error-selectors.txt}"
CONTRACTS_DIR="contracts"

# Header
{
    echo "======================================"
    echo "Error Selectors"
    echo "======================================"
    echo ""
    echo "Format: SELECTOR | ERROR SIGNATURE"
    echo ""
} > "$OUTPUT_FILE"

# extract all error definitions (including multi-line)
echo "Scanning $CONTRACTS_DIR for error signatures..."

# process all .sol files, collapse multi-line errors to single line, then extract
find "$CONTRACTS_DIR" -name "*.sol" -type f | while read -r file; do
    # collapse multiline definitions in one line
    tr '\n' ' ' < "$file" | \
    # extract error lines
    grep -oE 'error [A-Za-z_][A-Za-z0-9_]*\([^)]*\)' | \
    sed 's/error //' | while read -r sig; do
        # clean up whitespace (not needed for cast sig, but nicer output)
        sig=$(echo "$sig" | sed 's/[[:space:]]\+/ /g' | sed 's/[[:space:]]*([[:space:]]*/(/g' | sed 's/[[:space:]]*,[[:space:]]*/,/g' | sed 's/[[:space:]]*)[[:space:]]*/)/g')

        # get selector
        selector=$(cast sig "$sig" 2>/dev/null)

        if [ -n "$selector" ]; then
            printf "%-10s | %s\n" "$selector" "$sig" >> "$OUTPUT_FILE"
        else
            echo "Failed: $sig" >&2
        fi
    done
done

echo ""
echo "Output written to: $OUTPUT_FILE"
