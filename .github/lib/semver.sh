#!/usr/bin/env bash

SEMVER_LIB=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

semver_jq() {
  jq -L "$SEMVER_LIB" "$@"
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
  local f=valid
  case ${1-} in --stable|--rc) f=${1#--} ;; esac
  semver_jq -Rnr "include \"semver\"; [inputs | select(ltrimstr(\"v\") | $f)] | max"
}
