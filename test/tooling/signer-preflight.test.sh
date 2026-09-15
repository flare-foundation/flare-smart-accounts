#!/usr/bin/env bash
# The signer classifier, and the wiring that makes it load-bearing. Run by `pnpm test:tooling`.
#
# Two halves. The first walks every wrapper that broadcasts and asserts it still consults the
# classifier and still falls back to the raw key only when nothing else signs - a wrapper that
# loses either line accepts --ledger and then quietly signs with DEPLOYER_PRIVATE_KEY, or
# refuses to run at all. The second executes signer_preflight over the argument spellings forge
# accepts, because a guard is only as good as the flag that happened to be tested.
#
# End-to-end proof that a Ledger reaches forge, and that a stale keystore variable stops the run,
# is in transfer-ownership.test.sh, against the stub - that being the wrapper whose one call
# cannot be undone.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS="$HERE/../../deployment/scripts"
failed=0

note() { # description, ok?
  if [[ "$2" == "yes" ]]; then
    echo "  ok    $1"
  else
    echo "  FAIL  $1" >&2
    failed=1
  fi
}

echo "signer-preflight.sh: every broadcasting wrapper is wired to it"

# Every wrapper that signs. Listed rather than globbed: a new one must be added here deliberately,
# which is the moment to wire it, and a wrapper that stops broadcasting should leave this list.
WRAPPERS=(
  configure-remote-controller.sh
  deploy-composer.sh
  deploy-loan-subaccount-implementation.sh
  deploy-personal-account-implementation.sh
  deploy-remote-account-implementations.sh
  deploy-remote-controller-pinned.sh
  deploy-remote-controller-throwaway.sh
  deploy-sepolia-market.sh
  deploy-smart-accounts.sh
  execute-diamond-cut.sh
  transfer-ownership.sh
)

# The fragments below are the wrapper's own source text, matched literally: the dollar signs are
# part of what must be present, not expansions here.
# shellcheck disable=SC2016
SOURCES_IT='source "$(dirname "${BASH_SOURCE[0]}")/signer-preflight.sh"'
# shellcheck disable=SC2016
RUNS_IT='signer_preflight ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?'
# shellcheck disable=SC2016
FALLS_BACK='if [[ $SIGNER_SUPPLIED -eq 0 ]]; then'
# shellcheck disable=SC2016
PASSES_ON='FORGE_ARGS[@]+"${FORGE_ARGS[@]}"'
# the whole line, not the name: `refuse_output_flags ... || true` would still contain the name while
# letting --quiet through to forge
# shellcheck disable=SC2016
REFUSES_OUTPUT='refuse_output_flags ${FORGE_ARGS[@]+"${FORGE_ARGS[@]}"} || exit $?'

contains() { # haystack, needle
  case "$1" in
    *"$2"*) return 0 ;;
    *) return 1 ;;
  esac
}

for wrapper in "${WRAPPERS[@]}"; do
  path="$SCRIPTS/$wrapper"
  if [[ ! -f "$path" ]]; then
    note "$wrapper exists" "no"
    continue
  fi
  body="$(cat "$path")"
  verdict() { # description, fragment
    if contains "$body" "$2"; then
      note "$wrapper $1" "yes"
    else
      note "$wrapper $1" "no"
    fi
  }
  verdict "sources the classifier" "$SOURCES_IT"
  verdict "runs it, and stops when it refuses" "$RUNS_IT"
  # the raw key is a fallback, never an addition: a wrapper that appended it unconditionally would
  # hand forge two signers, and forge would take the keystore
  verdict "falls back to the key only when nothing else signs" "$FALLS_BACK"
  # The caller's arguments have to reach FORGE, or a signer flag is collected and then dropped. The
  # fragment also appears in the preflight calls themselves, so those lines are excluded: matching
  # anywhere would pass a wrapper that classifies its arguments and then never forwards them.
  forwarding="$(grep -F "$PASSES_ON" "$path" | grep -vcE '^[[:space:]]*(signer_preflight|refuse_output_flags) ' || true)"
  if [[ "${forwarding:-0}" -ge 1 ]]; then
    note "$wrapper passes the collected arguments on to forge" "yes"
  else
    note "$wrapper passes the collected arguments on to forge" "no"
  fi
  # a wrapper whose output feeds the recorder must refuse the flags that silence or reshape it,
  # before forge broadcasts rather than after
  if [[ "$body" == *"save-deployed-addresses"* ]]; then
    verdict "refuses output flags, being one whose output is parsed" "$REFUSES_OUTPUT"
  fi
done

echo "signer-preflight.sh: classification"

# shellcheck source=deployment/scripts/signer-preflight.sh
source "$SCRIPTS/signer-preflight.sh"

case_is() { # description, expected "rc:signer", env assignments..., -- args...
  local description="$1" expected="$2"
  shift 2
  local -a env_pairs=() args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do env_pairs+=("$1"); shift; done
  [[ $# -gt 0 ]] && shift
  args=("$@")

  local actual
  actual=$(
    unset ETH_KEYSTORE ETH_KEYSTORE_ACCOUNT
    for pair in ${env_pairs[@]+"${env_pairs[@]}"}; do export "${pair?}"; done
    SIGNER_SUPPLIED=0
    signer_preflight ${args[@]+"${args[@]}"} >/dev/null 2>&1
    echo "$?:$SIGNER_SUPPLIED"
  )
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok    $description"
  else
    echo "  FAIL  $description (expected rc:signer $expected, got $actual)" >&2
    failed=1
  fi
}

# An explicitly named non-keystore signer alongside a keystore variable must stop the run. Every
# spelling forge accepts counts.
case_is "--gcp with a keystore account is refused" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --gcp --sender 0xabc
case_is "--ledger with a keystore path is refused" "2:1" \
  ETH_KEYSTORE=/tmp/ks -- --ledger --sender 0xabc
case_is "--interactive is refused (singular spelling)" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --interactive
case_is "--interactives is refused (plural spelling)" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --interactives 1
case_is "--mnemonic-paths is refused" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --mnemonic-paths /tmp/m
case_is "the --flag=value form is refused too" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --private-key=0xdead

# ...but zero interactive keys is not a signer, in either spelling, so it may neither refuse the
# variable's run nor suppress the raw-key fallback.
case_is "--interactives 0 leaves the variable's signer alone" "0:1" \
  ETH_KEYSTORE_ACCOUNT=chosen -- --interactives 0
case_is "--interactives=0 leaves it alone too" "0:1" \
  ETH_KEYSTORE_ACCOUNT=chosen -- --interactives=0
case_is "--interactives 0 alone is not a signer" "0:0" -- --interactives 0
case_is "--interactives 2 is still a signer" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --interactives 2
# forge accepts a leading plus on the count, so +0 is zero as much as 0 is; reading it as a signer
# would suppress the fallback key, or refuse a run that legitimately signs from the variable
case_is "--interactives +0 is zero, not a signer" "0:1" \
  ETH_KEYSTORE_ACCOUNT=chosen -- --interactives +0
case_is "--interactives=+0 likewise" "0:1" \
  ETH_KEYSTORE_ACCOUNT=chosen -- --interactives=+0
case_is "--interactives +0 alone is not a signer" "0:0" -- --interactives +0
case_is "--interactives +2 is still a signer" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --interactives +2

# Short clusters behave exactly like the long forms they abbreviate: forge parses -lv as -l -v.
case_is "the short -l form is refused" "2:1" ETH_KEYSTORE_ACCOUNT=stale -- -l
case_is "the -lv cluster is refused" "2:1" ETH_KEYSTORE_ACCOUNT=stale -- -lv
case_is "the -qi cluster is refused" "2:1" ETH_KEYSTORE_ACCOUNT=stale -- -qi

# ...and a value attached to a value-taking short flag is not a cluster of flags. -D takes a
# level, so the t in "notes" is part of the value, not --trezor.
case_is "-Dnotes is not a signer despite the t" "0:1" ETH_KEYSTORE_ACCOUNT=stale -- -Dnotes
case_is "-rURL is not a signer despite the r" "0:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- -rhttp://localhost:8545

# A keystore flag and its own variable feed one field, so the flag wins and nothing is refused.
case_is "--account with a keystore account is allowed" "0:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --account intended
case_is "--keystores with a keystore path is allowed" "0:1" \
  ETH_KEYSTORE=/tmp/ks -- --keystores /tmp/other

# Across fields forge itself refuses, citing a flag the caller never typed, so name the variable
# that caused it while we still can.
case_is "--account with ETH_KEYSTORE is refused" "2:1" ETH_KEYSTORE=/tmp/ks -- --account intended
case_is "--keystore with ETH_KEYSTORE_ACCOUNT is refused" "2:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --keystore /tmp/ks

# Auxiliary options supply no signing material, so they must neither abort a run that legitimately
# signs from the variable nor suppress the fallback key.
case_is "--mnemonic-indexes does not count as a signer" "0:1" \
  ETH_KEYSTORE_ACCOUNT=stale -- --mnemonic-indexes 0

# Without a variable set, everything proceeds; only the signer verdict differs.
case_is "--ledger alone is a signer" "0:1" -- --ledger
case_is "-l alone is a signer" "0:1" -- -l
case_is "a keystore variable alone is a signer" "0:1" ETH_KEYSTORE_ACCOUNT=only --
case_is "no signer at all" "0:0" -- --slow
case_is "--sender alone is not a signer" "0:0" -- --sender 0xabc
case_is "the wrapper's own arguments are not signers" "0:0" -- -vvv

echo "signer-preflight.sh: output flags, for the wrappers whose output is parsed"

# The recorder reads NETWORK: and DEPLOYED: out of forge's output. An output flag silences or
# reshapes those lines, and forge broadcasts BEFORE the recorder runs - so the contract lands on
# chain and no record names it, which re-running cannot undo.
refuses() { # description, expected rc, args...
  local description="$1" expected="$2"
  shift 2
  local actual
  actual=$(refuse_output_flags "$@" >/dev/null 2>&1; echo $?)
  if [[ "$actual" == "$expected" ]]; then
    echo "  ok    $description"
  else
    echo "  FAIL  $description (expected rc $expected, got $actual)" >&2
    failed=1
  fi
}

refuses "--quiet is refused" 2 --quiet
refuses "--silent is refused" 2 --silent
refuses "--json is refused" 2 --json
refuses "-q is refused" 2 -q
refuses "a cluster containing q is refused" 2 -vq
refuses "--json=true form is refused" 2 --json=true
# ...and everything a caller legitimately passes must survive
refuses "--ledger is allowed" 0 --ledger --sender 0xabc
refuses "--account is allowed" 0 --account deployer --sender 0xabc
refuses "-vvv is allowed" 0 -vvv
refuses "--slow is allowed" 0 --slow
# a value attached to a value-taking short flag is not a cluster of flags: -D takes a level, so the
# q in "quiet" is part of the value rather than the quiet flag
refuses "-Dquiet is allowed, the q being part of the value" 0 -Dquiet
refuses "nothing at all is allowed" 0

if [[ $failed -ne 0 ]]; then
  echo "" >&2
  echo "A wrapper lost its signer wiring, or the classifier changed verdict." >&2
  echo "Either accepts --ledger and signs with something else - restore it." >&2
  exit 1
fi
echo "all signer-preflight.sh scenarios passed"
