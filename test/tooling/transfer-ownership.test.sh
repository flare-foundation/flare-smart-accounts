#!/usr/bin/env bash
# Regression scenarios for transfer-ownership.sh, run by `pnpm test:tooling`. The wrapper runs in a
# scratch copy of the repository layout with `forge` replaced by a stub that records its arguments,
# so the scenarios pin what the wrapper does around the forge script: the WHOLE argument vector,
# script path and RPC included, that the broadcast is followed by a SEPARATE verify run against
# mined state, that a failing broadcast stops before that run, and that every bad argument - a
# network that has no pinned controller, something that is not an address, a missing key - stops
# the run before forge is reached at all. This is the one call of a deployment that cannot be
# undone, so what the wrapper refuses matters as much as what it sends.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../deployment/scripts/transfer-ownership.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/repo/deployment/scripts"
cp "$WRAPPER" "$SCRATCH/repo/deployment/scripts/transfer-ownership.sh"
# the stub logs each argument with Bash escaping to preserve its boundaries, in call order;
# FORGE_FAIL_PHASE names the phase whose run fails, so the two failures can be staged separately
cat > "$SCRATCH/bin/forge" <<'STUB'
#!/usr/bin/env bash
{
  printf 'forge'
  printf ' %q' "$@"
  printf '\n'
} >> "$CALL_LOG"
for argument in "$@"; do
  if [[ -n "${FORGE_FAIL_PHASE:-}" && "$argument" == "${FORGE_FAIL_PHASE}" ]]; then
    exit 3
  fi
done
exit 0
STUB
chmod +x "$SCRATCH/bin/forge"

export PATH="$SCRATCH/bin:$PATH"
export SEPOLIA_RPC_URL="http://sepolia.invalid"
export DEPLOYER_PRIVATE_KEY="0x01"
export CALL_LOG="$SCRATCH/calls.log"

OWNER="0x99E0770aa23CAA9071B6112208297E7a8d8F8a4A"
SAFE="0x7F40b5B310c6CCfd6025D9bFc1FE6dB30aa0741b"
SCRIPT_ARG="deployment/scripts/TransferOwnership.s.sol:TransferOwnership"
SIG="run(string,string,address,address)"

failures=0
run_wrapper() {
  : > "$CALL_LOG"
  (cd "$SCRATCH/repo" && bash deployment/scripts/transfer-ownership.sh "$@") \
    > "$SCRATCH/out.log" 2>&1 && echo 0 || echo $?
}
expect() {
  local name="$1" got="$2" want="$3"
  if [[ "$got" == "$want" ]]; then
    echo "  ok    $name"
  else
    echo "  FAIL  $name"
    echo "        expected: $want"
    echo "        actual:   $got"
    failures=$((failures + 1))
  fi
}
call() {
  sed -n "$1p" "$CALL_LOG"
}
expected_call() {
  printf 'forge'
  printf ' %q' script "$SCRIPT_ARG" --rpc-url "$SEPOLIA_RPC_URL" --offline --sig "$SIG" "$@"
  printf '\n'
}

echo "transfer-ownership.sh scenarios"

# 1. the handover: broadcast with the key, then a separate read-back of the owner
expect "transfer: wrapper exits 0" "$(run_wrapper sepolia "$OWNER" "$SAFE")" "0"
expect "transfer: two forge runs" "$(grep -c '^forge ' "$CALL_LOG")" "2"
expect "transfer: the first broadcasts with the key" \
  "$(call 1)" \
  "$(expected_call sepolia execute "$OWNER" "$SAFE" --private-key 0x01 --broadcast)"
expect "transfer: the second reads the owner back, without key or broadcast" \
  "$(call 2)" "$(expected_call sepolia verify "$OWNER" "$SAFE")"

# 2. a failed broadcast must not be followed by a verification that would read a stale owner and
#    report success
expect "failed broadcast: wrapper exits with forge's status" \
  "$(FORGE_FAIL_PHASE=execute run_wrapper sepolia "$OWNER" "$SAFE")" "3"
expect "failed broadcast: the read-back did not run" "$(grep -c '^forge ' "$CALL_LOG")" "1"

# 3. a failed verification fails the wrapper: the transfer is the one call whose result must be
#    read back, and an unread one is not a completed handover
expect "failed verification: wrapper exits with forge's status" \
  "$(FORGE_FAIL_PHASE=verify run_wrapper sepolia "$OWNER" "$SAFE")" "3"
expect "failed verification: both runs happened" "$(grep -c '^forge ' "$CALL_LOG")" "2"

# 4. everything that stops before forge is reached
expect "unknown network: exit 2" "$(run_wrapper coston2 "$OWNER" "$SAFE")" "2"
expect "unknown network: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "current owner not an address: exit 2" "$(run_wrapper sepolia "0xnope" "$SAFE")" "2"
expect "current owner not an address: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "new owner not an address: exit 2" "$(run_wrapper sepolia "$OWNER" "the safe")" "2"
expect "new owner not an address: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "two arguments: usage exit 2" "$(run_wrapper sepolia "$OWNER")" "2"
expect "four arguments: usage exit 2" "$(run_wrapper sepolia "$OWNER" "$SAFE" extra)" "2"
expect "no key: exit 2" \
  "$(DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia "$OWNER" "$SAFE")" "2"
expect "no key: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "no RPC: exit 2" "$(SEPOLIA_RPC_URL='' run_wrapper sepolia "$OWNER" "$SAFE")" "2"
expect "no RPC: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"

if [[ "$failures" -ne 0 ]]; then
  echo "$failures transfer-ownership.sh scenarios failed"
  exit 1
fi
echo "all transfer-ownership.sh scenarios passed"
