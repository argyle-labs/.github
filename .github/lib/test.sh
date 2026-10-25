#!/usr/bin/env bash
set -euo pipefail

# shellcheck source=/dev/null
. "$(cd "$(dirname "$0")" && pwd)/semver.sh"
fail=0
is() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want '$3', got '$2'" >&2; fail=1; fi
}
yes() {
  local name=$1; shift
  if "$@"; then echo "ok: $name"; else echo "FAIL: $name: want accept" >&2; fail=1; fi
}
no() {
  local name=$1; shift
  if "$@"; then echo "FAIL: $name: want reject" >&2; fail=1; else echo "ok: $name"; fi
}
max() {
  printf '%s\n' "${@:2}" | semver_max "$1"
}

is "rc.10 > rc.9" "$(max '' 1.0.0-rc.9 1.0.0-rc.10)" 1.0.0-rc.10
is "release > rc" "$(max '' 1.0.0-rc.10 1.0.0 1.0.0-rc.9)" 1.0.0
is "numeric < alphanumeric" "$(max '' 1.0.0-alpha 1.0.0-1)" 1.0.0-alpha
is "shorter prerelease lower" "$(max '' 1.0.0-rc.1.1 1.0.0-rc.1)" 1.0.0-rc.1.1
is "minor numeric" "$(max '' 0.9.0 0.10.0)" 0.10.0
is "build metadata ignored" "$(max '' 1.2.3+zzz 1.2.4+aaa)" 1.2.4+aaa
is "build metadata equal" "$(semver_jq -nr 'include "semver"; ("1.2.3+a" | key) == ("1.2.3+b" | key)')" true
is "tags keep prefix" "$(max '' v0.2.0 v0.10.0 v0.9.0)" v0.10.0
is "invalid skipped" "$(max '' 9.9 01.0.0 1.0.0 garbage)" 1.0.0
is "empty input" "$(max '' </dev/null)" ""
is "stable only" "$(max --stable v1.0.0 v1.1.0-rc.1 v0.9.0)" v1.0.0
is "rc only" "$(max --rc v1.1.0-rc.9 v1.1.0-rc.10 v1.1.0 v1.1.0-beta.99)" v1.1.0-rc.10

yes "valid core" semver_valid 1.2.3
yes "valid prerelease" semver_valid 1.2.3-rc.1
yes "valid build" semver_valid 1.2.3+build.7
no "leading zero core" semver_valid 01.2.3
no "leading zero prerelease" semver_valid 1.2.3-rc.01
no "newline" semver_valid $'1.2.3\nx'
no "trailing newline" semver_valid $'1.2.3\n'
no "semicolon" semver_valid '1.2.3;rm -rf /'
no "two parts" semver_valid 1.2
no "empty" semver_valid ''
no "empty identifier" semver_valid 1.2.3-rc..1
yes "stable" semver_valid --stable 1.95.0
no "stable rejects rc" semver_valid --stable 1.95.0-rc.1
no "stable rejects build" semver_valid --stable 1.95.0+b
yes "rc" semver_valid --rc 1.0.0-rc.3
no "rc rejects beta" semver_valid --rc 1.0.0-beta.1
no "rc rejects stable" semver_valid --rc 1.0.0

yes "tag" semver_valid_tag v1.2.3-beta.1
no "tag needs v" semver_valid_tag 1.2.3
no "tag double v" semver_valid_tag vv1.2.3
yes "stable tag" semver_valid_tag --stable v1.2.3
no "stable tag rejects rc" semver_valid_tag --stable v1.2.3-rc.1
yes "rc tag" semver_valid_tag --rc v1.2.3-rc.4
no "rc tag rejects stable" semver_valid_tag --rc v1.2.3
no "tag newline" semver_valid_tag --stable $'v1.2.3\nv9.9.9'

exit "$fail"
