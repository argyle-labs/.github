#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/hash.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
mkdir -p .github/workflows a/src a/schema
echo 'on: push' > .github/workflows/ci.yml
printf '[package]\nname = "a"\nversion = "0.0.0"\n' > a/Cargo.toml
echo '{}' > a/schema/api.json
echo 'fn main() {}' > a/build.rs

fail=0
expect() {
  local want=$1 name=$2 extra=$3 got=pass err="" errs
  shift 3
  if [ "$want" = fail ]; then
    err=$1
    shift
  fi
  printf '%s\n' "$@" > a/src/lib.rs
  git add -A
  errs=$(WORKFLOW_FILE=.github/workflows/ci.yml EXTRA_PATHS=$extra bash "$script" 2>&1) || got=fail
  if [ "$got" = "$want" ] && [[ "$errs" == *"$err"* ]]; then
    echo "ok: $name ($want)"
  else
    echo "FAIL: $name should $want [$err], got $got: $errs" >&2
    fail=1
  fi
}
out_dir='static S: &[u8] = include_bytes!(concat!(env!("OUT_DIR"), "/api.json"));'
expect fail 'OUT_DIR include without extra-paths' '' 'uses env!() in an include path' "$out_dir"
expect pass 'OUT_DIR include with extra-paths' 'a/schema' "$out_dir"
expect pass 'direct env!("OUT_DIR") include with extra-paths' 'a/schema' 'const S: &str = include_str!(env!("OUT_DIR"));'
# shellcheck disable=SC2016 # literal variable names
expect fail 'CARGO_MANIFEST_DIR env! include' 'a/schema' 'uses env!() in an include path' 'const S: &str = include_str!(concat!(env!("CARGO_MANIFEST_DIR"), "/schema/api.json"));'
expect pass 'literal include' '' 'const S: &str = include_str!("../schema/api.json");'

printf '%s\n' "$out_dir" > a/src/lib.rs
git add -A
run() { WORKFLOW_FILE=.github/workflows/ci.yml EXTRA_PATHS=a/schema bash "$script"; }
before=$(run)
echo '{"x":1}' > a/schema/api.json
git add -A
if [ "$before" = "$(run)" ]; then
  echo "FAIL: hash ignores extra-paths input a/schema/api.json" >&2
  fail=1
else
  echo "ok: hash tracks a/schema/api.json"
fi
exit "$fail"
