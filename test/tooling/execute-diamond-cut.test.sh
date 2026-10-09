#!/usr/bin/env bash
# Regression scenarios for execute-diamond-cut.sh, run by `pnpm test:tooling`. The wrapper runs in
# a scratch copy of the repository layout with `forge` and `npx` replaced by stubs that record
# their arguments, so the scenarios pin what the wrapper does before and after the forge script:
# the cut file's `execute` flag is validated before anything runs, the post-cut verification is
# invoked exactly when the cut executed, with the staging network name when it is one, and a
# missing cut file or a bad argument count stops the run; a failing forge script skips the
# verification and a failing verification fails the wrapper.
#
# The record steps are here for the same reason. The cut's facet addresses reach the deployment
# record only after forge has exited, through the runtime check and then the recorder, so each
# step's failure must stop the next one: that ordering is what keeps a run that never broadcast
# out of the record, and it is invisible in the script itself.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../deployment/scripts/execute-diamond-cut.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/repo/deployment/scripts" "$SCRATCH/repo/deployment/cuts/coston2" \
  "$SCRATCH/repo/deployment/cuts/coston2-staging"
cp "$WRAPPER" "$SCRATCH/repo/deployment/scripts/execute-diamond-cut.sh"
# the wrapper sources the signer classifier and the staged-output preflight at run time, so the
# scratch copy needs them too
cp "$HERE/../../deployment/scripts/signer-preflight.sh" "$SCRATCH/repo/deployment/scripts/signer-preflight.sh"
cp "$HERE/../../deployment/scripts/deploy-output-preflight.sh" \
  "$SCRATCH/repo/deployment/scripts/deploy-output-preflight.sh"
# the stubs log their arguments in call order and exit as FORGE_EXIT / NPX_EXIT say (0 by default)
cat > "$SCRATCH/bin/forge" <<'STUB'
#!/usr/bin/env bash
printf 'forge %s\n' "$*" >> "$CALL_LOG"
# the wrapper tees forge's stdout into the file the record steps read, so a scenario that cares
# what they see says it here
printf '%s' "${FORGE_PRINTS:-}"
exit "${FORGE_EXIT:-0}"
STUB
cat > "$SCRATCH/bin/npx" <<'STUB'
#!/usr/bin/env bash
printf 'npx %s\n' "$*" >> "$CALL_LOG"
# three npx steps run in order, so failing them all at once cannot show which one stopped the
# rest: NPX_FAIL_SCRIPT fails one by name and leaves the others passing
if [[ -n "${NPX_FAIL_SCRIPT:-}" ]]; then
  case "$*" in
    *"$NPX_FAIL_SCRIPT"*) exit "${NPX_FAIL_STATUS:-1}" ;;
  esac
  exit 0
fi
exit "${NPX_EXIT:-0}"
STUB
chmod +x "$SCRATCH/bin/forge" "$SCRATCH/bin/npx"

export PATH="$SCRATCH/bin:$PATH"
export COSTON2_RPC_URL="http://stub.invalid"
# present so a missing variable is never what stops a loan-chain scenario
export ETHEREUM_RPC_URL="http://stub.invalid"
export SEPOLIA_RPC_URL="http://stub.invalid"
export DEPLOYER_PRIVATE_KEY="0x01"
export CALL_LOG="$SCRATCH/calls.log"

failures=0
run_wrapper() {
  : > "$CALL_LOG"
  (cd "$SCRATCH/repo" && bash deployment/scripts/execute-diamond-cut.sh "$@") > "$SCRATCH/out.log" 2>&1 && echo 0 || echo $?
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
cut_file() {
  printf '{"diamond": "0x434936d47503353f06750Db1A444DBDC5F0AD37c", "facets": [], "execute": %s}\n' "$2" > "$1"
}
# the calls in order, one word each: `forge`, then the script name of every npx step
call_sequence() {
  sed -e 's|^forge .*|forge|' -e 's|^npx tsx deployment/scripts/\([a-z-]*\)\.ts.*|\1|' "$CALL_LOG" | tr '\n' ' '
}

echo "execute-diamond-cut.sh scenarios"

# 1. an executed cut is verified afterwards, for the network the wrapper was given
cut_file "$SCRATCH/repo/deployment/cuts/coston2/executed.json" true
expect "executed cut: wrapper exits 0" "$(run_wrapper coston2 executed)" "0"
expect "executed cut: forge ran with the base network and staging=false" \
  "$(grep -c 'forge script .* --sig run(string,string,bool) coston2 executed false' "$CALL_LOG")" "1"
expect "executed cut: the verifier ran for coston2 with --no-build" \
  "$(grep -c '^npx tsx deployment/scripts/verify-diamond.ts coston2 executed --no-build$' "$CALL_LOG")" "1"
expect "executed cut: forge, then the record steps, then the verifier" \
  "$(call_sequence)" "forge verify-deployed-runtime save-deployed-addresses verify-diamond "

# 2. a prepared-only cut still records what it deployed, and is not verified by the wrapper
cut_file "$SCRATCH/repo/deployment/cuts/coston2/prepared.json" false
expect "prepared cut: wrapper exits 0" "$(run_wrapper coston2 prepared)" "0"
expect "prepared cut: forge and the record steps ran, the verifier did not" \
  "$(call_sequence)" "forge verify-deployed-runtime save-deployed-addresses "

# 3. a non-boolean execute flag is rejected before forge runs
cut_file "$SCRATCH/repo/deployment/cuts/coston2/numeric.json" 1
expect "numeric execute: wrapper exits 2" "$(run_wrapper coston2 numeric)" "2"
expect "numeric execute: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "numeric execute: the message names the flag" "$(grep -c '"execute" must be a JSON boolean' "$SCRATCH/out.log")" "1"

# 4. a staging network reads its own cut directory and verifies under its own name
cut_file "$SCRATCH/repo/deployment/cuts/coston2-staging/staged.json" true
expect "staging cut: wrapper exits 0" "$(run_wrapper coston2-staging staged)" "0"
expect "staging cut: forge ran with the base network and staging=true" \
  "$(grep -c 'forge script .* --sig run(string,string,bool) coston2 staged true' "$CALL_LOG")" "1"
expect "staging cut: the verifier ran for coston2-staging" \
  "$(grep -c '^npx tsx deployment/scripts/verify-diamond.ts coston2-staging staged --no-build$' "$CALL_LOG")" "1"

# 5. a missing cut file stops the run before forge
expect "missing cut file: wrapper fails" "$([[ "$(run_wrapper coston2 nowhere)" != "0" ]] && echo failed || echo passed)" "failed"
expect "missing cut file: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"

# 6. the argument count is enforced
expect "one argument: usage exit 2" "$(run_wrapper coston2)" "2"

# 6b. a staging alias of a loan chain is refused for that reason and before forge is reached; the
# RPC variables are set above, so a missing one cannot be what produced the exit code
for alias in ethereum-staging sepolia-staging; do
  expect "$alias: refused" "$(run_wrapper "$alias" anything)" "2"
  expect "$alias: the message names the rule" \
    "$(grep -c "$alias is not supported: the loan chains have only the pinned deployment" "$SCRATCH/out.log")" "1"
  expect "$alias: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
done

# 7. a failing forge script stops the run with its status; nothing is recorded or verified. This
# is the case the in-script record write could not survive: forge runs the whole script in
# simulation first, so a write from in there would already have named addresses this run never
# deployed
expect "forge failure: wrapper exits with forge's status" "$(FORGE_EXIT=3 run_wrapper coston2 executed)" "3"
expect "forge failure: forge ran once" "$(grep -c '^forge ' "$CALL_LOG")" "1"
expect "forge failure: nothing recorded and nothing verified" "$(grep -c '^npx ' "$CALL_LOG")" "0"

# 8. each record step stops the ones after it
expect "runtime check failure: wrapper exits with its status" \
  "$(NPX_FAIL_SCRIPT=verify-deployed-runtime.ts run_wrapper coston2 executed)" "1"
expect "runtime check failure: the recorder never ran" "$(call_sequence)" "forge verify-deployed-runtime "
expect "recorder failure: wrapper exits with its status" \
  "$(NPX_FAIL_SCRIPT=save-deployed-addresses.ts NPX_FAIL_STATUS=2 run_wrapper coston2 executed)" "2"
expect "recorder failure: the diamond was not verified against a record it never got" \
  "$(call_sequence)" "forge verify-deployed-runtime save-deployed-addresses "
expect "verifier failure: wrapper exits with the verifier's status" \
  "$(NPX_FAIL_SCRIPT=verify-diamond.ts run_wrapper coston2 executed)" "1"
expect "verifier failure: it ran last" \
  "$(call_sequence)" "forge verify-deployed-runtime save-deployed-addresses verify-diamond "

# 9. forge's record lines reach the file the record steps read
expect "staged output: wrapper exits 0" \
  "$(FORGE_PRINTS='NETWORK: coston2
DEPLOYED: OwnershipFacet, OwnershipFacet.sol: 0x1234123412341234123412341234123412341234
' run_wrapper coston2 executed)" "0"
expect "staged output: the record line was teed to the recorder's file" \
  "$(grep -c '^DEPLOYED: OwnershipFacet, OwnershipFacet.sol: 0x1234123412341234123412341234123412341234$' \
    "$SCRATCH/repo/forge-deploy-output.txt")" "1"

# 10. that file left behind names deployments the record never got, so the next run stops rather
# than overwriting it - the stub recorder above does not consume it, which is what a failed one
# would also leave
expect "stale staged output: refused" "$(run_wrapper coston2 executed)" "2"
expect "stale staged output: forge did not run" "$(grep -c '^forge ' "$CALL_LOG")" "0"
expect "stale staged output: the message names what to recover" \
  "$(grep -c 'OwnershipFacet, OwnershipFacet.sol' "$SCRATCH/out.log")" "1"
rm -f "$SCRATCH/repo/forge-deploy-output.txt"

if [[ "$failures" -ne 0 ]]; then
  echo "$failures scenario(s) FAILED"
  exit 1
fi
echo "all scenarios passed"
