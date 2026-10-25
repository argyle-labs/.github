#!/usr/bin/env bash

SEMVER_LIB=${SEMVER_LIB:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

command -v jq >/dev/null || { echo "::error::semver.sh: jq not found" >&2; return 1; }

semver_jq() {
  local rc=0
  jq -L "$SEMVER_LIB" "$@" || rc=$?
  [ "$rc" -le 1 ] || echo "::error::semver.sh: jq failed (exit $rc, module path $SEMVER_LIB)" >&2
  return "$rc"
}

semver_valid() {
  local f=valid
  case ${1-} in
    --stable|--rc) f=${1#--}; shift ;;
    --any) shift ;;
  esac
  semver_jq -ne --arg v "${1-}" "include \"semver\"; \$v | $f" >/dev/null
}

semver_valid_tag() {
  local mode=--any
  case ${1-} in --stable|--rc) mode=$1; shift ;; esac
  case ${1-} in
    v*) semver_valid "$mode" "${1#v}" ;;
    *) return 1 ;;
  esac
}

semver_max() {
  local f=valid rc=0
  case ${1-} in --stable|--rc) f=${1#--} ;; esac
  semver_jq -Rnr "include \"semver\"; [inputs | select(ltrimstr(\"v\") | $f)] | max" || rc=$?
  [ "$rc" -ne 1 ] || echo "::error::semver.sh: jq failed (exit 1, module path $SEMVER_LIB)" >&2
  return "$rc"
}
