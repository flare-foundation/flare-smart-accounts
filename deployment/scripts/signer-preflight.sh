#!/usr/bin/env bash
# Sourced by every wrapper that broadcasts, and by test/tooling/signer-preflight.test.sh
# to test it directly. Defines signer_preflight, which classifies the caller's forge
# arguments and refuses a combination that would sign from an account the caller did
# not name.
#
# Ported from flare-dvn-contracts, where it was written on 2026-09-10. The flag and the
# preflight belong together: accepting --ledger without this is the trap the preflight
# exists for.
#
# Sets SIGNER_SUPPLIED to 1 when anything supplies signing material, so the
# caller knows whether DEPLOYER_PRIVATE_KEY is still required. Returns 2, after
# explaining, when the run must not proceed.
#
# Forge binds ETH_KEYSTORE_ACCOUNT to --account and ETH_KEYSTORE to --keystore,
# so either variable is indistinguishable from typing the flag. Two distinct
# problems follow, and both are refused:
#
#   * a keystore resolves ahead of every other signer, so naming --gcp or
#     --ledger while a variable is set signs from the keystore instead, asking
#     only for a password nobody expected;
#   * --account and --keystore are mutually exclusive in forge, so naming one
#     while the *other* variable is set is rejected by forge itself - with a
#     message citing a flag the caller never typed.
#
# Neither can be worked around here: forge loads the environment file itself,
# after this script, restoring anything unset.

# Long-form selectors that supply signing material and are not keystores.
# Spellings verified against the installed forge; plural and singular both
# exist for several of them.
_SIGNER_SELECTORS=(
  --gcp --aws --turnkey --ledger --trezor --unlocked --browser
  --private-key --private-keys --mnemonics --mnemonic-paths
  --interactive --interactives
  --session --session-ledger --session-trezor --session-interactive
  --session-private-key --session-mnemonic
)
# Selectors feeding the same field as ETH_KEYSTORE_ACCOUNT, and as ETH_KEYSTORE.
_ACCOUNT_SELECTORS=(--account --accounts --session-account)
_KEYSTORE_SELECTORS=(--keystore --keystores --session-keystore)

# Short flags, from `forge script --help`. A cluster is parsed the way clap
# does: characters are flags until one takes a value, after which the rest is
# that value - so -lv is -l -v (a signer), while -Dnotes is -D with the value
# "notes" (no signer, despite the t).
_SHORT_VALUE_FLAGS="CDgjnoRrs"
_SHORT_BOOL_FLAGS="hkqv"
_SHORT_SIGNER_FLAGS="ilt"

_contains() { # needle, haystack...
  local needle="$1"
  shift
  local item
  for item in "$@"; do [[ "$item" == "$needle" ]] && return 0; done
  return 1
}

# shellcheck disable=SC2034  # SIGNER_SUPPLIED is read by the sourcing script.
signer_preflight() {
  local arg selector cluster i char idx value
  local -a argv=("$@")
  SIGNER_SUPPLIED=0
  NAMED_SIGNER=""   # a non-keystore signer the caller spelled out
  NAMED_ACCOUNT=""  # an --account-family selector
  NAMED_KEYSTORE="" # a --keystore-family selector

  for ((idx = 0; idx < ${#argv[@]}; idx++)); do
    arg="${argv[idx]}"
    # --flag=value and --flag alike; a value never decides anything, with one
    # exception below.
    selector="${arg%%=*}"
    # --interactives takes a count, and zero of them supplies no signer: it
    # must neither refuse a run that signs from the variable nor suppress the
    # raw-key fallback. The count is attached or the next argument, and forge
    # accepts a leading plus on it, so `+0` is zero as much as `0` is.
    if [[ "$selector" == "--interactives" ]]; then
      if [[ "$arg" == *=* ]]; then value="${arg#*=}"; else value="${argv[idx + 1]:-}"; fi
      [[ "$value" =~ ^\+?0+$ ]] && continue
    fi
    if _contains "$selector" "${_SIGNER_SELECTORS[@]}"; then
      SIGNER_SUPPLIED=1
      NAMED_SIGNER="$selector"
      continue
    fi
    if _contains "$selector" "${_ACCOUNT_SELECTORS[@]}"; then
      SIGNER_SUPPLIED=1
      NAMED_ACCOUNT="$selector"
      continue
    fi
    if _contains "$selector" "${_KEYSTORE_SELECTORS[@]}"; then
      SIGNER_SUPPLIED=1
      NAMED_KEYSTORE="$selector"
      continue
    fi
    # A short cluster. Walk it as clap would rather than searching the whole
    # string: a value attached to -C, -D, -r and friends must not be read as
    # flags, or an ordinary argument would be mistaken for a signer.
    if [[ "$arg" =~ ^-[^-] ]]; then
      cluster="${arg#-}"
      for ((i = 0; i < ${#cluster}; i++)); do
        char="${cluster:i:1}"
        if [[ "$_SHORT_SIGNER_FLAGS" == *"$char"* ]]; then
          SIGNER_SUPPLIED=1
          NAMED_SIGNER="-$char"
        elif [[ "$_SHORT_BOOL_FLAGS" != *"$char"* ]]; then
          # Either a flag taking a value ($_SHORT_VALUE_FLAGS), whose value is
          # the rest of the string, or a character forge does not accept at
          # all. Both mean nothing further along is a flag, so stop rather
          # than read a value as one.
          break
        fi
      done
    fi
  done

  local keystore_var="" conflict=""
  [[ -n "${ETH_KEYSTORE_ACCOUNT:-}" ]] && keystore_var="ETH_KEYSTORE_ACCOUNT=${ETH_KEYSTORE_ACCOUNT}"
  [[ -n "${ETH_KEYSTORE:-}" ]] && keystore_var="${keystore_var:+$keystore_var and }ETH_KEYSTORE=${ETH_KEYSTORE}"
  [[ -z "$keystore_var" ]] && return 0

  if [[ -n "$NAMED_SIGNER" ]]; then
    conflict="$NAMED_SIGNER was given, but $keystore_var is set.
Forge resolves a keystore ahead of $NAMED_SIGNER, so the run would sign from
the keystore - asking only for the password of an account you did not name."
  elif [[ -n "$NAMED_ACCOUNT" && -n "${ETH_KEYSTORE:-}" ]]; then
    conflict="$NAMED_ACCOUNT was given, but ETH_KEYSTORE=${ETH_KEYSTORE} is set.
Forge binds that variable to --keystore, and --account and --keystore are
mutually exclusive, so forge would reject the run citing a flag you never typed."
  elif [[ -n "$NAMED_KEYSTORE" && -n "${ETH_KEYSTORE_ACCOUNT:-}" ]]; then
    conflict="$NAMED_KEYSTORE was given, but ETH_KEYSTORE_ACCOUNT=${ETH_KEYSTORE_ACCOUNT} is set.
Forge binds that variable to --account, and --keystore and --account are
mutually exclusive, so forge would reject the run citing a flag you never typed."
  else
    SIGNER_SUPPLIED=1 # the variable is itself the signer
    return 0
  fi

  echo "$conflict" >&2
  echo "" >&2
  echo "This script cannot neutralize it: forge loads the environment file" >&2
  echo "itself, after this script has run, restoring whatever it unsets." >&2
  echo "Remove the variable from the environment file, then re-run." >&2
  return 2
}

# Eight wrappers pipe forge's output to a recorder that reads `NETWORK:` and `DEPLOYED:` lines out
# of it. An output flag silences or reshapes those lines, and forge would still BROADCAST first: the
# deployment lands on chain and the recorder then fails with "Network name not found in output",
# leaving the record naming whatever it named before. Refused before anything is sent, because the
# failure is unrecoverable by re-running - the contract is already deployed.
#
# Called only by the wrappers that parse; the others may be run as quietly as the caller likes.
# `--silent` is not in `forge script --help` but forge accepts it and suppresses the same lines
# (verified 2026-09-15: exit 0, no script output). `-s` is NOT here: forge takes a value for it,
# so it is refused by forge itself.
_OUTPUT_SELECTORS=(--quiet --silent --json)

refuse_output_flags() {
  local arg selector cluster i char
  for arg in "$@"; do
    selector="${arg%%=*}"
    if _contains "$selector" "${_OUTPUT_SELECTORS[@]}"; then
      echo "$selector changes the output this wrapper's recorder reads." >&2
      echo "Forge would broadcast first and the recorder would then fail, leaving a deployed" >&2
      echo "contract with no record entry. Re-run without it." >&2
      return 2
    fi
    # a short cluster, walked as clap does: characters are flags until one takes a value
    if [[ "$arg" =~ ^-[^-] ]]; then
      cluster="${arg#-}"
      for ((i = 0; i < ${#cluster}; i++)); do
        char="${cluster:i:1}"
        if [[ "$char" == "q" ]]; then
          echo "-q changes the output this wrapper's recorder reads." >&2
          echo "Forge would broadcast first and the recorder would then fail, leaving a deployed" >&2
          echo "contract with no record entry. Re-run without it." >&2
          return 2
        fi
        if [[ "$_SHORT_BOOL_FLAGS$_SHORT_SIGNER_FLAGS" != *"$char"* ]]; then
          break
        fi
      done
    fi
  done
  return 0
}
