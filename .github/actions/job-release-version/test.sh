#!/usr/bin/env bash
set -euo pipefail

script=$(realpath "$(dirname "$0")/check.sh")
fail=0
expect() {
  local want=$1 expected=$2 computed=$3 got=pass
  EXPECTED=$expected COMPUTED=$computed bash "$script" >/dev/null || got=fail
  if [ "$got" = "$want" ]; then
    echo "ok: '$expected' vs '$computed' ($want)"
  else
    echo "FAIL: '$expected' vs '$computed' should $want" >&2
    fail=1
  fi
}
expect pass '' 0.2.1-rc.18
expect pass 0.2.1-rc.18 0.2.1-rc.18
expect pass v0.2.1-rc.18 0.2.1-rc.18
expect pass v0.2.1 v0.2.1
expect pass ' v0.2.1-rc.18 ' 0.2.1-rc.18
expect pass V0.2.1 0.2.1
expect fail v0.2.1-rc.17 0.2.1-rc.18
expect fail 0.2.2 0.2.1
exit "$fail"
