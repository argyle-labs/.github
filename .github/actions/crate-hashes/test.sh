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
printf '[dependencies]\na = { path = "../a", optional = true }\n[dev-dependencies]\nb = { path = "../b" }\n' >> c/Cargo.toml
echo 'pub const X: u8 = 1;' > shared/x.rs
echo 'one' > shared/assets/one.txt
echo '-- m' > migrations/0001.sql
echo 'include!("../../shared/x.rs");' > a/src/lib.rs
# shellcheck disable=SC2016 # literal variable names
echo 'static D: Dir = include_dir!("$CARGO_MANIFEST_DIR/../shared/assets");' > b/src/lib.rs
echo 'static M: Migrator = sqlx::migrate!("../migrations");' > c/src/lib.rs
echo 'include!(concat!(env!("OUT_DIR"), "/gen.rs"));' > d/src/lib.rs
git add -A
cargo generate-lockfile -q --offline
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
check c a/src/lib.rs
check c b/src/lib.rs

expect() {
  local want=$1 name=$2 got=pass err="" errs
  shift 2
  if [ "$want" = fail ]; then
    err=$1
    shift
  fi
  printf '%s\n' "$@" > d/src/lib.rs
  git add -A
  errs=$(run 2>&1 >/dev/null) || got=fail
  if [ "$got" = "$want" ] && [[ "$errs" == *"$err"* ]]; then
    echo "ok: $name ($want)"
  else
    echo "FAIL: $name should $want [$err], got $got: $errs" >&2
    fail=1
  fi
}
expect fail 'unresolvable include!' "embeds '../../shared/missing.rs' but it is not a tracked file" 'include!("../../shared/missing.rs");'
expect pass 'commented-out embed' \
  'let s = 1; // include_str!("../../nope/x")' \
  '/* include_str!("../../nope/x") */' \
  'const R: &str = r#"include_str!("../../nope/x")"#;'
echo generated > d/src/gen.txt
expect pass 'in-crate untracked include' 'const G: &str = include_str!("gen.txt");'
rm d/src/gen.txt
# shellcheck disable=SC2016 # literal variable names
expect fail 'env!("CARGO_MANIFEST_DIR") include' 'uses env!() in an include path' 'include!(concat!(env!("CARGO_MANIFEST_DIR"), "/../shared/x.rs"));'
expect fail 'unclosed multi-line embed' 'parentheses never close' 'const X: &str = include_str!(' '  "../../shared/x.rs"'
expect fail 'multi-line non-literal embed' 'has a non-literal embed' 'const X: &str = include_str!(' '  PATH);'
expect pass 'multi-line OUT_DIR include' 'include!(concat!(' '    env!("OUT_DIR"),' '    "/gen.rs"' '));'
expect pass 'multi-line block comment embed' '/*' '  include_str!("../../nope/x")' '*/' 'const Y: u8 = 1;'

echo raw > shared/raw.txt
echo hashed > shared/hashed.txt
echo multi > shared/multi.txt
echo bytes > shared/bytes.txt
printf '%s\n' 'const A: &str = include_str!(r"../../shared/raw.txt");' \
  'const B: &str = include_str!(r#"../../shared/hashed.txt"#);' \
  'const C: &str = include_str!(' '  "../../shared/multi.txt"' ');' \
  'const D: (&[u8], &str) = (br"x\", include_str!("../../shared/bytes.txt"));' > d/src/lib.rs
git add -A
check d shared/raw.txt
check d shared/hashed.txt
check d shared/multi.txt
check d shared/bytes.txt

echo star > shared/star.txt
printf '%s\n' 'const P: &str = "assets/*";' 'const S: &str = include_str!("../../shared/star.txt");' '/* c */' > d/src/lib.rs
git add -A
check d shared/star.txt
echo slash > shared/slash.txt
printf '%s\n' '// see dir/*' 'const S: &str = include_str!("../../shared/slash.txt");' '/* c */' > d/src/lib.rs
git add -A
check d shared/slash.txt
echo paren > shared/paren.txt
printf '%s\n' 'const S: (&str, &str) = (include_str!(' '  "../../shared/paren.txt"), "(");' 'const T: u8 = 0;' > d/src/lib.rs
git add -A
check d shared/paren.txt
filler=()
for _ in $(seq 1500); do filler+=('const Z: u8 = 0;'); done
t0=$(date +%s)
expect fail 'unclosed embed before 1500 lines' 'parentheses never close' 'const X: &str = include_str!(' "${filler[@]}"
if [ $(($(date +%s) - t0)) -ge 5 ]; then
  echo "FAIL: unclosed embed took $(($(date +%s) - t0))s" >&2
  fail=1
fi
exit "$fail"
