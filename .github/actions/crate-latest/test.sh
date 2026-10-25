#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/latest.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
fail=0
is() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want '$3', got '$2'" >&2; fail=1; fi
}
mkdir -p "$root/or/ca"
publish() {
  : > "$root/or/ca/orca-x"
  for v in "$@"; do
    y=false; case "$v" in *!) y=true; v=${v%!} ;; esac
    printf '{"name":"orca-x","vers":"%s","yanked":%s}\n' "$v" "$y" >> "$root/or/ca/orca-x"
  done
}
resolve() {
  INDEX_URL="sparse+file://$root/" /bin/bash "$script" orca-x 2>"$root/err"
}
accepts() {
  local name=$1 want=$2 got rc
  shift 2
  publish "$@"
  got=$(resolve) && rc=0 || rc=$?
  is "$name: exit 0" "$rc" 0
  is "$name: version" "$got" "$want"
}
rejects() {
  local name=$1 rc
  shift
  publish "$@"
  resolve >/dev/null && rc=0 || rc=$?
  is "$name: exit 1" "$rc" 1
  is "$name: non-semver error" "$(grep -c 'non-semver version' "$root/err")" 1
}

accepts valid 0.2.1 0.2.1-rc.9 0.2.1 0.2.0
accepts prerelease 1.0.0-rc.2 1.0.0-rc.1 1.0.0-rc.2
accepts build-meta 1.2.3+build.7 1.2.3+build.7
accepts empty-passthrough '' 0.1.0!
rejects newline '0.2.1-rc.1\nx'
rejects semicolon '0.2.1-rc.1;rm -rf /'
rejects leading-zero 01.2.3

exit "$fail"
