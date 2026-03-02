#!/bin/bash

# Extract all error definitions from ABI artifacts and get their 4-byte selectors
# Usage: ./scripts/extract-error-selectors.sh [output-file]

OUTPUT_FILE="${1:-error-selectors.txt}"
# directory containing ABI artifact JSON files
ARTIFACTS_DIR="artifacts"
# temp file to collect all error signatures before deduplication
SIGS_TMP="$(mktemp -t error-sigs.XXXXXX)"

# remove temp file on script exit (success or failure)
trap 'rm -f "$SIGS_TMP"' EXIT

# header
{
	echo "======================================"
	echo "Error Selectors"
	echo "======================================"
	echo ""
	echo "Format: SELECTOR | ERROR SIGNATURE"
	echo ""
} > "$OUTPUT_FILE"

if [ -d "$ARTIFACTS_DIR" ] && find "$ARTIFACTS_DIR" -name "*.json" -type f | grep -q .; then
	echo "Scanning $ARTIFACTS_DIR for ABI error signatures..."

	# jq filter to extract and canonicalize error signatures from ABI
	# handles tuple types recursively, including tuple arrays like tuple[]
	expand_inputs_jq='
		def expand_type(i):
			# convert tuple to canonical form: (type1,type2,...)
			if i.type == "tuple" then
				"(" + (i.components | map(expand_type(.)) | join(",")) + ")"
			# convert tuple array to canonical form: (type1,type2,...)[...]
			elif (i.type | test("^tuple(\\[.*\\])+$")) then
				"(" + (i.components | map(expand_type(.)) | join(",")) + ")" + (i.type | sub("^tuple"; ""))
			# return primitive types unchanged
			else
				i.type
			end;
		# extract error definitions, expand tuple parameters, build signature
		# output format: ErrorName(type1,type2,...)
		(.abi // [])[] | select(.type == "error") | "\(.name)(\(.inputs | map(expand_type(.)) | join(",")))"
	'

	# process each artifact JSON file
	find "$ARTIFACTS_DIR" -name "*.json" -type f | while read -r file; do
		# extract signatures and append to temp file
		jq -r "$expand_inputs_jq" "$file" >> "$SIGS_TMP"
	done
else
	echo "ABI artifacts not found in $ARTIFACTS_DIR. Build artifacts first." >&2
	exit 1
fi

# deduplicate signatures and compute selectors
sort -u "$SIGS_TMP" | while read -r sig; do
	[ -z "$sig" ] && continue

	# use cast sig to compute 4-byte keccak256 selector from signature
	selector=$(cast sig "$sig" 2>/dev/null)

	if [ -n "$selector" ]; then
		# output: SELECTOR | SIGNATURE
		printf "%s | %s\n" "$selector" "$sig" >> "$OUTPUT_FILE"
	else
		echo "Failed: $sig" >&2
	fi
done

echo ""
echo "Output written to: $OUTPUT_FILE"
