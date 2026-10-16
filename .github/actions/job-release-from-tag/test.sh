#!/usr/bin/env bash
set -euo pipefail

script=$(realpath "$(dirname "$0")/pick.sh")
fail=0
export REPO=argyle-labs/orca
expect() {
  local want=$1 tag=$2 pre=$3 got
  got=$(TAG=$tag EVENT_PRERELEASE=$pre GITHUB_OUTPUT=/dev/stdout bash "$script" 2>/dev/null | sed -n 's/^prerelease=//p' || true)
  got=${got:-fail}
  if [ "$got" = "$want" ]; then
    echo "ok: '$tag' pre='$pre' → $want"
  else
    echo "FAIL: '$tag' pre='$pre' → $got, want $want" >&2
    fail=1
  fi
}
expect true v0.2.1-rc.3 true
expect true 0.2.1-rc.3 ''
expect false v0.2.1 false
expect false v0.2.1 ''
expect fail v0.2.1 true
expect fail v0.2.1-rc.3 false
expect fail next ''
expect fail v0.2.1-beta.1 ''
expect fail '' ''
exit "$fail"
