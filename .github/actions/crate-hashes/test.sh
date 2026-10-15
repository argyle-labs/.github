#!/usr/bin/env bash
set -euo pipefail

script=$(realpath "$(dirname "$0")/hashes.sh")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
git init -q
git config user.email t@t
git config user.name t

mkdir -p .github/workflows a/src b/src c/src d/src shared/assets migrations
echo 'on: push' > .github/workflows/ci.yml
cat > Cargo.toml <<'T'
[workspace]
members = ["a", "b", "c", "d"]
resolver = "2"
T
for c in a b c d; do
  printf '[package]\nname = "%s"\nversion = "0.0.0"\nedition = "2021"\n' "$c" > "$c/Cargo.toml"
done
echo 'pub const X: u8 = 1;' > shared/x.rs
echo 'one' > shared/assets/one.txt
echo '-- m' > migrations/0001.sql
echo 'include!("../../shared/x.rs");' > a/src/lib.rs
# shellcheck disable=SC2016 # literal variable names
echo 'static D: Dir = include_dir!("$CARGO_MANIFEST_DIR/../shared/assets");' > b/src/lib.rs
echo 'static M: Migrator = sqlx::migrate!("../migrations");' > c/src/lib.rs
echo 'include!(concat!(env!("OUT_DIR"), "/gen.rs"));' > d/src/lib.rs
git add -A
cargo generate-lockfile -q --offline 2>/dev/null || cargo generate-lockfile -q
git add -A

run() { WORKFLOW_FILE=.github/workflows/ci.yml bash "$script"; }
fail=0
check() {
  local crate=$1 file=$2 before after
  before=$(run | jq -r --arg c "$crate" '.[$c]')
  echo changed >> "$file"
  git add -A
  after=$(run | jq -r --arg c "$crate" '.[$c]')
  if [ "$before" = "$after" ]; then
    echo "FAIL: $crate hash ignores $file" >&2
    fail=1
  else
    echo "ok: $crate tracks $file"
  fi
}
check a shared/x.rs
check b shared/assets/one.txt
check c migrations/0001.sql

expect() {
  local want=$1 name=$2 got=pass
  shift 2
  printf '%s\n' "$@" > d/src/lib.rs
  git add -A
  run >/dev/null 2>&1 || got=fail
  if [ "$got" = "$want" ]; then
    echo "ok: $name ($want)"
  else
    echo "FAIL: $name should $want" >&2
    fail=1
  fi
}
expect fail 'unresolvable include!' 'include!("../../shared/missing.rs");'
expect pass 'commented-out embed' \
  'let s = 1; // include_str!("../../nope/x")' \
  '/* include_str!("../../nope/x") */' \
  'const R: &str = r#"include_str!("../../nope/x")"#;'
echo generated > d/src/gen.txt
expect pass 'in-crate untracked include' 'const G: &str = include_str!("gen.txt");'
rm d/src/gen.txt
# shellcheck disable=SC2016 # literal variable names
expect fail 'env!("CARGO_MANIFEST_DIR") include' 'include!(concat!(env!("CARGO_MANIFEST_DIR"), "/../shared/x.rs"));'
expect fail 'multi-line embed' 'const X: &str = include_str!(' '  "../../shared/x.rs");'

echo raw > shared/raw.txt
echo hashed > shared/hashed.txt
printf '%s\n' 'const A: &str = include_str!(r"../../shared/raw.txt");' \
  'const B: &str = include_str!(r#"../../shared/hashed.txt"#);' > d/src/lib.rs
git add -A
check d shared/raw.txt
check d shared/hashed.txt
exit "$fail"
