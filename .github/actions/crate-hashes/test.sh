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

echo 'include!("../../shared/missing.rs");' > d/src/lib.rs
git add -A
if run >/dev/null 2>&1; then
  echo "FAIL: unresolvable include! did not fail" >&2
  fail=1
else
  echo "ok: unresolvable include! fails"
fi
exit "$fail"
