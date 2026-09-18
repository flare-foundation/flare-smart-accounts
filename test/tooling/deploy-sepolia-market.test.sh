#!/usr/bin/env bash
# Regression scenarios for deploy-sepolia-market.sh, run by `pnpm test:tooling`. The wrapper runs in
# a scratch copy of the repository layout with `forge` and `npx` replaced by stubs that record their
# arguments, so the scenarios pin what the wrapper does around the forge script: the phase is
# validated before anything runs, the recorder runs after the two phases that deploy and after no
# other, the forge output is removed once a run is dealt with, a run that fails after printing
# record lines leaves them in place and blocks the next run until they are recorded or removed,
# while a failed run that printed none is overwritten.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="$HERE/../../deployment/scripts/deploy-sepolia-market.sh"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT

mkdir -p "$SCRATCH/bin" "$SCRATCH/repo/deployment/scripts"
cp "$WRAPPER" "$SCRATCH/repo/deployment/scripts/deploy-sepolia-market.sh"
# the wrapper sources the signer classifier and the staged-output preflight at run time, so the
# scratch copy needs them too
cp "$HERE/../../deployment/scripts/signer-preflight.sh" "$SCRATCH/repo/deployment/scripts/signer-preflight.sh"
cp "$HERE/../../deployment/scripts/deploy-output-preflight.sh" \
  "$SCRATCH/repo/deployment/scripts/deploy-output-preflight.sh"
# the stubs log the command and then one argument per line, so an argument holding a space of its
# own reads differently from two arguments; they print what FORGE_PRINTS says (the wrapper tees
# forge's stdout into the recorder's file) and exit as FORGE_EXIT / NPX_EXIT say (0 by default)
cat > "$SCRATCH/bin/forge" <<'STUB'
#!/usr/bin/env bash
{ printf 'forge\n'; printf '  %s\n' "$@"; } >> "$CALL_LOG"
if [[ -n "${FORGE_PRINTS:-}" ]]; then
  printf '%s\n' "$FORGE_PRINTS"
fi
exit "${FORGE_EXIT:-0}"
STUB
cat > "$SCRATCH/bin/npx" <<'STUB'
#!/usr/bin/env bash
{ printf 'npx\n'; printf '  %s\n' "$@"; } >> "$CALL_LOG"
exit "${NPX_EXIT:-0}"
STUB
chmod +x "$SCRATCH/bin/forge" "$SCRATCH/bin/npx"

export PATH="$SCRATCH/bin:$PATH"
export SEPOLIA_RPC_URL="http://stub.invalid"
export DEPLOYER_PRIVATE_KEY="0x01"
export CALL_LOG="$SCRATCH/calls.log"
OUTPUT="$SCRATCH/repo/forge-deploy-output.txt"

failures=0
run_wrapper() {
  : > "$CALL_LOG"
  (cd "$SCRATCH/repo" && bash deployment/scripts/deploy-sepolia-market.sh "$@") > "$SCRATCH/out.log" 2>&1 && echo 0 || echo $?
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
output_state() {
  if [[ -f "$OUTPUT" ]]; then echo present; else echo absent; fi
}
commands() {
  grep -E '^(forge|npx)$' "$CALL_LOG" | tr '\n' ' '
}
# what the wrapper must call forge with for a phase, argument by argument, with the settings it
# resolved: the stubbed ones unless a scenario names others
forge_vector() {
  local phase="$1" rpc="${2:-http://stub.invalid}" key="${3:-0x01}"
  printf 'forge\n  script\n  deployment/scripts/DeploySepoliaMarket.s.sol:DeploySepoliaMarket\n'
  printf '  --rpc-url\n  %s\n  --offline\n' "$rpc"
  # the signer trails the invocation: a caller-supplied one replaces it in the same position
  printf '  --sig\n  run(string,string)\n  sepolia\n  %s\n  --broadcast\n' "$phase"
  printf '  --private-key\n  %s\n' "$key"
}
recorder_vector() {
  printf 'npx\n  tsx\n  deployment/scripts/save-deployed-addresses.ts\n'
}

echo "deploy-sepolia-market.sh scenarios"

# 1. the assets phase runs the script for sepolia and then the recorder; the output is gone after
export FORGE_PRINTS=$'  NETWORK: sepolia\n  DEPLOYED: TestnetLoanToken, TestnetLoanToken.sol: 0x0000000000000000000000000000000000000001'
expect "assets: wrapper exits 0" "$(run_wrapper assets)" "0"
# the whole call, argument by argument, and nothing else run: the RPC and the key the wrapper
# resolved are as much a part of it as the phase
expect "assets: forge and then the recorder, each with its whole argument vector" \
  "$(cat "$CALL_LOG")" "$(forge_vector assets; recorder_vector)"
expect "assets: those two calls and no others" "$(commands)" "forge npx "
expect "assets: the forge output is removed once recorded" "$(output_state)" "absent"

# 2. the market phase records too
expect "market: wrapper exits 0" "$(run_wrapper market)" "0"
expect "market: forge and then the recorder, each with its whole argument vector" \
  "$(cat "$CALL_LOG")" "$(forge_vector market; recorder_vector)"
expect "market: those two calls and no others" "$(commands)" "forge npx "
expect "market: the forge output is removed" "$(output_state)" "absent"

# 3. fund and reset-feeds deploy nothing and do not record; the output is removed all the same
export FORGE_PRINTS="  NETWORK: sepolia"
for phase in fund reset-feeds; do
  expect "$phase: wrapper exits 0" "$(run_wrapper "$phase")" "0"
  expect "$phase: forge ran with the whole argument vector" "$(cat "$CALL_LOG")" "$(forge_vector "$phase")"
  expect "$phase: forge alone, no recorder" "$(commands)" "forge "
  expect "$phase: the forge output is removed" "$(output_state)" "absent"
done

# 4. an unknown phase, or none, stops before forge
expect "unknown phase: wrapper exits 2" "$(run_wrapper everything)" "2"
expect "unknown phase: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
expect "no phase: wrapper exits 2" "$(run_wrapper)" "2"
expect "two arguments: wrapper exits 2" "$(run_wrapper assets market)" "2"
expect "bad arguments: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"

# 5. the RPC and the key are required before forge runs
expect "no RPC: wrapper exits 2" "$(SEPOLIA_RPC_URL='' run_wrapper assets)" "2"
expect "no RPC: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
expect "no key: wrapper exits 2" "$(DEPLOYER_PRIVATE_KEY='' run_wrapper assets)" "2"
expect "no key: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"

# 6. a forge failure after record lines were printed keeps the output - the deployments it names
#    may have landed - and skips the recorder; the next run refuses until it is dealt with
export FORGE_PRINTS=$'  NETWORK: sepolia\n  DEPLOYED: TestnetLoanToken, TestnetLoanToken.sol: 0x0000000000000000000000000000000000000001'
expect "forge fails after deploying: wrapper fails" "$(FORGE_EXIT=1 run_wrapper assets)" "1"
expect "forge fails after deploying: no recorder" "$(commands)" "forge "
expect "forge fails after deploying: the output is kept" "$(output_state)" "present"
expect "forge fails after deploying: it names the deployment" "$(grep -c '^ *DEPLOYED:' "$OUTPUT")" "1"
expect "rerun over an unrecorded deployment: wrapper exits 2" "$(run_wrapper assets)" "2"
expect "rerun over an unrecorded deployment: nothing ran" "$(wc -l < "$CALL_LOG" | tr -d ' ')" "0"
expect "rerun over an unrecorded deployment: the output is untouched" "$(grep -c '^ *DEPLOYED:' "$OUTPUT")" "1"
expect "rerun over an unrecorded deployment: the message names the network the file names" \
  "$(grep -c 'It names the network sepolia' "$SCRATCH/out.log")" "1"
expect "rerun over an unrecorded deployment: and the deployment it holds" \
  "$(grep -c '^  TestnetLoanToken, TestnetLoanToken.sol: 0x0000000000000000000000000000000000000001$' "$SCRATCH/out.log")" "1"
expect "rerun over an unrecorded deployment: and where that run's receipts are" \
  "$(grep -c 'broadcast/<that script>.s.sol/<chain id>/' "$SCRATCH/out.log")" "1"
# recording it by hand, as the message says, clears the way
rm "$OUTPUT"
expect "after the output is dealt with: wrapper exits 0" "$(run_wrapper assets)" "0"

# 7. a recorder failure keeps the output as well, and blocks the next run the same way
expect "recorder fails: wrapper fails" "$(NPX_EXIT=1 run_wrapper market)" "1"
expect "recorder fails: the output is kept" "$(output_state)" "present"
expect "rerun after a recorder failure: wrapper exits 2" "$(run_wrapper market)" "2"
rm "$OUTPUT"

# 8. a failed run that printed no record line deployed nothing: its output is overwritten
export FORGE_PRINTS="  NETWORK: sepolia"
expect "forge fails before deploying: wrapper fails" "$(FORGE_EXIT=1 run_wrapper fund)" "1"
expect "forge fails before deploying: the output is kept" "$(output_state)" "present"
expect "rerun over a run that deployed nothing: wrapper exits 0" "$(run_wrapper fund)" "0"
expect "rerun over a run that deployed nothing: forge ran" "$(commands)" "forge "
expect "rerun over a run that deployed nothing: the output is removed" "$(output_state)" "absent"

# 9. every deploy wrapper tees to this one file, so a leftover may be another script's run on
#    another network: the message must describe that run, not assume this one
printf '  NETWORK: coston2\n  DEPLOYED: PersonalAccount, PersonalAccount.sol: 0x00000000000000000000000000000000000000aa\n' > "$OUTPUT"
expect "a leftover from another wrapper: wrapper exits 2" "$(run_wrapper assets)" "2"
expect "a leftover from another wrapper: the message names that run's network" \
  "$(grep -c 'It names the network coston2' "$SCRATCH/out.log")" "1"
expect "a leftover from another wrapper: and that run's deployment" \
  "$(grep -c '^  PersonalAccount, PersonalAccount.sol: ' "$SCRATCH/out.log")" "1"
expect "a leftover from another wrapper: sepolia is not claimed" \
  "$(grep -c 'network sepolia' "$SCRATCH/out.log")" "0"
rm "$OUTPUT"

# 10. the settings need not be exported at all: the documented way to run this is with them in the
#    repository's .env, which the wrapper sources
printf 'SEPOLIA_RPC_URL=http://from-dotenv.invalid\nDEPLOYER_PRIVATE_KEY=0x02\n' > "$SCRATCH/repo/.env"
expect "settings from the env file alone: wrapper exits 0" \
  "$( (unset SEPOLIA_RPC_URL DEPLOYER_PRIVATE_KEY; run_wrapper fund) )" "0"
expect "settings from the env file alone: forge got the file's RPC and key" \
  "$(cat "$CALL_LOG")" "$(forge_vector fund http://from-dotenv.invalid 0x02)"
# the file is sourced whatever the environment holds, as in every deploy wrapper here, so its
# settings are the ones used even when others are exported
expect "an env file beside exported settings: wrapper exits 0" "$(run_wrapper fund)" "0"
expect "an env file beside exported settings: forge got the file's" \
  "$(cat "$CALL_LOG")" "$(forge_vector fund http://from-dotenv.invalid 0x02)"
rm "$SCRATCH/repo/.env"
# and with no file, the exported settings are what reach forge
expect "no env file: wrapper exits 0" "$(run_wrapper fund)" "0"
expect "no env file: forge got the exported RPC and key" "$(cat "$CALL_LOG")" "$(forge_vector fund)"

# An output flag must be refused BEFORE forge runs. The recorder reads NETWORK: and DEPLOYED: out
# of forge's output, and forge BROADCASTS first - so accepting one would put contracts on chain and
# then fail the recorder, leaving a record that names none of them. Re-running cannot undo that.
for flag in --quiet --silent --json -q -vq; do
  expect "$flag: exit 2" "$(run_wrapper market "$flag")" "2"
  expect "$flag: forge never ran" "$(commands)" ""
done
# ...and the flags a caller legitimately passes still reach forge
expect "-vvv: wrapper exits 0" "$(run_wrapper fund -vvv)" "0"
expect "-vvv: forge ran" "$(commands)" "forge "

if [[ $failures -ne 0 ]]; then
  echo "$failures scenario(s) failed"
  exit 1
fi
echo "all deploy-sepolia-market.sh scenarios passed"
