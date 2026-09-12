#!/usr/bin/env bash
# Regression scenarios for configure-remote-controller.sh, run by `pnpm test:tooling`. The wrapper
# runs in a scratch copy of the repository layout with `forge` replaced by a stub that records its
# arguments, so the scenarios pin what the wrapper does around the forge script: the WHOLE argument
# vector, script path and RPC included, which phase, section and target reach it, that only
# `execute` is given a key and `--broadcast`, that a broadcast is followed by a SEPARATE verify run
# against mined state, that a failing broadcast stops before that run, that a failing verification
# fails the wrapper, that the environment file is read when the variable is not exported, and that
# a bad argument stops everything before forge is reached at all.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../deployment/scripts/configure-remote-controller.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/repo/deployment/scripts"
cp "$WRAPPER" "$SCRATCH/repo/deployment/scripts/configure-remote-controller.sh"
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
# distinct per network, so a run that dialled the wrong chain's RPC fails the comparison
export SEPOLIA_RPC_URL="http://sepolia.invalid"
export ETHEREUM_RPC_URL="http://ethereum.invalid"
export DEPLOYER_PRIVATE_KEY="0x01"
export CALL_LOG="$SCRATCH/calls.log"

SCRIPT_ARG="deployment/scripts/ConfigureRemoteController.s.sol:ConfigureRemoteController"
SIG="run(string,string,string,string)"

failures=0
run_wrapper() {
  : > "$CALL_LOG"
  (cd "$SCRATCH/repo" && bash deployment/scripts/configure-remote-controller.sh "$@") \
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
# the whole vector of the nth call, so a swapped script path or RPC cannot pass
call() {
  sed -n "$1p" "$CALL_LOG"
}
expected_call() {
  local rpc="$1"
  shift
  printf 'forge'
  printf ' %q' script "$SCRIPT_ARG" --rpc-url "$rpc" --offline --sig "$SIG" "$@"
  printf '\n'
}

echo "configure-remote-controller.sh scenarios"

# 1. prepare: one run, the complete vector, no key and no broadcast, section and target defaulted
expect "prepare: wrapper exits 0" "$(run_wrapper sepolia prepare)" "0"
expect "prepare: one forge run" "$(grep -c '^forge ' "$CALL_LOG")" "1"
expect "prepare: the whole argument vector" \
  "$(call 1)" "$(expected_call "$SEPOLIA_RPC_URL" sepolia prepare governance pinned)"

# 2. the section and target are passed through as given, and the network picks its own RPC
expect "wiring/throwaway: wrapper exits 0" "$(run_wrapper sepolia prepare wiring throwaway)" "0"
expect "wiring/throwaway: the whole argument vector" \
  "$(call 1)" "$(expected_call "$SEPOLIA_RPC_URL" sepolia prepare wiring throwaway)"
expect "implementations: accepted and passed through" \
  "$(run_wrapper sepolia prepare implementations)" "0"
expect "implementations: the whole argument vector" \
  "$(call 1)" "$(expected_call "$SEPOLIA_RPC_URL" sepolia prepare implementations pinned)"
expect "ethereum: dials its own RPC" "$(run_wrapper ethereum prepare)" "0"
expect "ethereum: the whole argument vector" \
  "$(call 1)" "$(expected_call "$ETHEREUM_RPC_URL" ethereum prepare governance pinned)"

# 3. execute: the broadcast, then a SEPARATE verify run - the script's own read-back sees simulated
#    state, so the one that means anything is made after the transactions are mined
expect "execute: wrapper exits 0" "$(run_wrapper sepolia execute all throwaway)" "0"
expect "execute: two forge runs" "$(grep -c '^forge ' "$CALL_LOG")" "2"
expect "execute: the first broadcasts with the key" \
  "$(call 1)" \
  "$(expected_call "$SEPOLIA_RPC_URL" sepolia execute all throwaway --private-key 0x01 --broadcast)"
expect "execute: the second verifies, without key or broadcast" \
  "$(call 2)" "$(expected_call "$SEPOLIA_RPC_URL" sepolia verify all throwaway)"

# 4. verify stands on its own, and needs no key at all
expect "verify without a key: wrapper exits 0" \
  "$(DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia verify all)" "0"
expect "verify without a key: one run, the whole vector" \
  "$(call 1)" "$(expected_call "$SEPOLIA_RPC_URL" sepolia verify all pinned)"

# 5. a failing broadcast stops before the verification
expect "failed broadcast: wrapper exits with forge's status" \
  "$(FORGE_FAIL_PHASE=execute run_wrapper sepolia execute governance)" "3"
expect "failed broadcast: the verification did not run" "$(grep -c '^forge ' "$CALL_LOG")" "1"

# 6. a failing verification after a successful broadcast fails the wrapper
expect "failed verification: wrapper exits with forge's status" \
  "$(FORGE_FAIL_PHASE=verify run_wrapper sepolia execute governance)" "3"
expect "failed verification: both runs happened" "$(grep -c '^forge ' "$CALL_LOG")" "2"

# 7. the environment file is read when the variable is not exported, which is how an operator runs it
printf 'SEPOLIA_RPC_URL=http://from-the-file.invalid\nDEPLOYER_PRIVATE_KEY=0x02\n' \
  > "$SCRATCH/repo/.env"
expect "env file: the run dials the RPC it names" \
  "$(SEPOLIA_RPC_URL='' DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia prepare)" "0"
expect "env file: the whole argument vector" \
  "$(call 1)" "$(expected_call "http://from-the-file.invalid" sepolia prepare governance pinned)"
expect "env file: its key is what execute signs with" \
  "$(SEPOLIA_RPC_URL='' DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia execute governance)" "0"
expect "env file: the key reaches forge" \
  "$(call 1)" \
  "$(expected_call "http://from-the-file.invalid" sepolia execute governance pinned --private-key 0x02 --broadcast)"
rm -f "$SCRATCH/repo/.env"

# 8. every argument is validated before forge is reached
expect "unknown network: exit 2" "$(run_wrapper coston2 prepare)" "2"
expect "unknown network: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "unknown phase: exit 2" "$(run_wrapper sepolia apply)" "2"
expect "unknown phase: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "unknown section: exit 2" "$(run_wrapper sepolia prepare everything)" "2"
expect "unknown section: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "unknown target: exit 2" "$(run_wrapper sepolia prepare governance other)" "2"
expect "unknown target: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "one argument: usage exit 2" "$(run_wrapper sepolia)" "2"
expect "five arguments: usage exit 2" "$(run_wrapper sepolia prepare governance pinned extra)" "2"

# 9. execute is the only phase that needs a key, and says so rather than running without one
expect "execute without a key: exit 2" \
  "$(DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia execute governance)" "2"
expect "execute without a key: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "prepare without a key: still runs" "$(DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia prepare)" "0"

# 10. the RPC for the named network is required
expect "no RPC: exit 2" "$(SEPOLIA_RPC_URL='' run_wrapper sepolia prepare)" "2"
expect "no RPC: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"

if [[ "$failures" -gt 0 ]]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "all scenarios passed"
