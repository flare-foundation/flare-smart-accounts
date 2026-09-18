#!/usr/bin/env bash
# Regression scenarios for deploy-remote-account-implementations.sh, run by `pnpm test:tooling`.
# The wrapper runs in a scratch copy of the repository layout with `forge` and `npx` replaced by
# stubs that record their arguments, so the scenarios pin what the wrapper does around the two:
# that the preflight runs BEFORE the broadcast, that the names it chose reach the forge script in
# the order it chose them, that a plan deploying nothing skips the broadcast AND the recorder
# entirely, and that a bad argument stops before either is reached. The selection is mandatory,
# which is the guard itself: an omitted one used to mean everything. Which names are valid is the
# preflight's business, not the wrapper's, so this file does not keep a second copy of the list.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../deployment/scripts/deploy-remote-account-implementations.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/repo/deployment/scripts"
cp "$WRAPPER" "$SCRATCH/repo/deployment/scripts/deploy-remote-account-implementations.sh"
# the wrapper sources the signer classifier and the staged-output preflight at run time, so the
# scratch copy needs them too
cp "$HERE/../../deployment/scripts/signer-preflight.sh" "$SCRATCH/repo/deployment/scripts/signer-preflight.sh"
cp "$HERE/../../deployment/scripts/deploy-output-preflight.sh" \
  "$SCRATCH/repo/deployment/scripts/deploy-output-preflight.sh"

cat > "$SCRATCH/bin/forge" <<'STUB'
#!/usr/bin/env bash
{
  printf 'forge'
  printf ' %q' "$@"
  printf '\n'
} >> "$CALL_LOG"
exit "${FORGE_EXIT:-0}"
STUB
chmod +x "$SCRATCH/bin/forge"

# the npx stub stands in for both tsx runs the wrapper makes: the preflight, whose --out file it
# writes from PLAN_CONTRACTS (newline-separated artifact names), and the recorder, which only logs
cat > "$SCRATCH/bin/npx" <<'STUB'
#!/usr/bin/env bash
{
  printf 'npx'
  printf ' %q' "$@"
  printf '\n'
} >> "$CALL_LOG"
out=""
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == "--out" ]]; then
    next=$((i + 1))
    out="${!next}"
  fi
done
if [[ -n "$out" ]]; then
  if [[ -n "${PLAN_EXIT:-}" ]]; then
    exit "$PLAN_EXIT"
  fi
  # PLAN_CONTRACTS names what the preflight chose, comma-separated; unset means it chose both, and
  # empty means it chose nothing, which is the "already on chain" answer
  contracts="${PLAN_CONTRACTS-PersonalAccountRemote,MorphoLoanSubaccountRemote}"
  : > "$out"
  if [[ -n "$contracts" ]]; then
    tr ',' '\n' <<< "$contracts" >> "$out"
  fi
fi
exit 0
STUB
chmod +x "$SCRATCH/bin/npx"

export PATH="$SCRATCH/bin:$PATH"
export SEPOLIA_RPC_URL="http://sepolia.invalid"
export DEPLOYER_PRIVATE_KEY="0x01"
export CALL_LOG="$SCRATCH/calls.log"

SCRIPT_ARG="deployment/scripts/DeployRemoteAccountImplementations.s.sol:DeployRemoteAccountImplementations"
SIG="run(string,bool,string[])"

failures=0
run_wrapper() {
  : > "$CALL_LOG"
  (cd "$SCRATCH/repo" && bash deployment/scripts/deploy-remote-account-implementations.sh "$@") \
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
expected_forge() {
  printf 'forge'
  printf ' %q' script "$SCRIPT_ARG" --rpc-url "$SEPOLIA_RPC_URL" \
    --offline --sig "$SIG" sepolia false "$1" --broadcast
  # the signer trails the invocation, so a caller-supplied one lands in the same position
  printf ' %q' --private-key "$DEPLOYER_PRIVATE_KEY"
  printf '\n'
}

echo "deploy-remote-account-implementations.sh scenarios"

expected_preflight() {
  printf 'npx'
  printf ' %q' tsx deployment/scripts/plan-remote-implementations.ts sepolia "$1" \
    --out deployment/output-internal/sepolia/remote-implementations-plan.txt
  printf '\n'
}
expected_recorder() {
  printf 'npx'
  printf ' %q' tsx deployment/scripts/save-deployed-addresses.ts
  printf '\n'
}

# 1. the ordinary run: preflight first, then the broadcast carrying the names it chose, then the
#    recorder
expect "all: wrapper exits 0" "$(run_wrapper sepolia all)" "0"
expect "all: the preflight runs first" "$(call 1)" "$(expected_preflight all)"
expect "all: the broadcast carries both names" \
  "$(call 2)" "$(expected_forge '[PersonalAccountRemote,MorphoLoanSubaccountRemote]')"
expect "all: the recorder runs last" "$(call 3)" "$(expected_recorder)"

# 2. the preflight's choice is what reaches the script, not the operator's selection: `all` can
#    legitimately deploy one and reuse the rest
expect "all, one unchanged: exits 0" \
  "$(PLAN_CONTRACTS=MorphoLoanSubaccountRemote run_wrapper sepolia all)" "0"
expect "all, one unchanged: only the changed one is named" \
  "$(call 2)" "$(expected_forge '[MorphoLoanSubaccountRemote]')"
expect "all, the other unchanged: exits 0" \
  "$(PLAN_CONTRACTS=PersonalAccountRemote run_wrapper sepolia all)" "0"
expect "all, the other unchanged: only the changed one is named" \
  "$(call 2)" "$(expected_forge '[PersonalAccountRemote]')"

# 3. the order the preflight chose is the order the script gets: deployed addresses depend on the
#    deployer's nonce, so reordering them silently would change what lands where
expect "order: exits 0" \
  "$(PLAN_CONTRACTS=MorphoLoanSubaccountRemote,PersonalAccountRemote run_wrapper sepolia all)" "0"
expect "order: the names keep the preflight's order" \
  "$(call 2)" "$(expected_forge '[MorphoLoanSubaccountRemote,PersonalAccountRemote]')"

# 4. a plan deploying nothing is a success that spends no gas and, crucially, does not run the
#    recorder: there is nothing new to record and a rerun must not rewrite the record
expect "nothing to deploy: exits 0" "$(PLAN_CONTRACTS='' run_wrapper sepolia all)" "0"
expect "nothing to deploy: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "nothing to deploy: the recorder did not run" \
  "$(grep -c 'save-deployed-addresses' "$CALL_LOG")" "0"
expect "nothing to deploy: says so" "$(grep -c 'Nothing to deploy' "$SCRATCH/out.log")" "1"

# 5. the selection is passed through verbatim: which names are valid is the preflight's business,
#    and a second copy of the list here would be one more thing to keep in step
PLAN_CONTRACTS=PersonalAccountRemote run_wrapper sepolia personal-account > /dev/null
expect "one name: reaches the preflight verbatim" "$(call 1)" "$(expected_preflight personal-account)"
PLAN_CONTRACTS=PersonalAccountRemote \
  run_wrapper sepolia personal-account,morpho-loan-subaccount > /dev/null
expect "a list of names: reaches the preflight verbatim" \
  "$(call 1)" "$(expected_preflight personal-account,morpho-loan-subaccount)"
expect "a name the preflight rejects: exits with its status" \
  "$(PLAN_EXIT=1 run_wrapper sepolia personal-accounts)" "1"
expect "a name the preflight rejects: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"

# 6. a failing preflight stops the run: its whole purpose is to be believed
expect "failing preflight: wrapper exits with its status" "$(PLAN_EXIT=4 run_wrapper sepolia all)" "4"
expect "failing preflight: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"

# 7. a failing broadcast must not be followed by the recorder
expect "failing broadcast: wrapper exits with forge's status" "$(FORGE_EXIT=3 run_wrapper sepolia all)" "3"
expect "failing broadcast: the recorder did not run" \
  "$(grep -c 'save-deployed-addresses' "$CALL_LOG")" "0"

# 8. everything that stops before anything runs
expect "no selection: usage exit 2" "$(run_wrapper sepolia)" "2"
expect "no selection: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
expect "three arguments: usage exit 2" "$(run_wrapper sepolia all extra)" "2"
expect "Flare-family network: exit 2" "$(run_wrapper coston2 all)" "2"
expect "Flare-family network: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
expect "loan-chain staging: exit 2" "$(run_wrapper sepolia-staging all)" "2"
expect "no key: exit 2" "$(DEPLOYER_PRIVATE_KEY='' run_wrapper sepolia all)" "2"
expect "no key: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
expect "no RPC: exit 2" "$(SEPOLIA_RPC_URL='' run_wrapper sepolia all)" "2"
expect "no RPC: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"

if [[ "$failures" -ne 0 ]]; then
  echo "$failures deploy-remote-account-implementations.sh scenarios failed"
  exit 1
fi
echo "all deploy-remote-account-implementations.sh scenarios passed"
