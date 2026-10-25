#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/update.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
fail=0
is() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want '$3', got '$2'" >&2; fail=1; fi
}
mkdir -p "$root/bin"
cat > "$root/bin/cargo" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CARGO_LOG"
[ -z "${CARGO_FAIL:-}" ] || { echo "$CARGO_FAIL" >&2; exit 101; }
if [ "$1 $2" = "update -p" ] && [ "${4:-}" = --precise ]; then
  awk -v p="$3" -v v="$5" '/^name = /{n=$3; gsub(/"/,"",n)} /^version = / && n==p {$0="version = \"" v "\""} {print}' Cargo.lock > Cargo.lock.new
  mv Cargo.lock.new Cargo.lock
fi
STUB
chmod +x "$root/bin/cargo"
export PATH="$root/bin:$PATH" CARGO_LOG="$root/cargo.log"

index="$root/index"
mkdir -p "$index/or/ca"
publish() {
  local crate=$1; shift
  : > "$index/or/ca/$crate"
  for v in "$@"; do
    y=false; case "$v" in *!) y=true; v=${v%!} ;; esac
    printf '{"name":"%s","vers":"%s","yanked":%s}\n' "$crate" "$v" "$y" >> "$index/or/ca/$crate"
  done
}
inline='[dependencies]
plugin-toolkit = { version = ">=0.2.1-rc.47", registry = "gitea", package = "orca-plugin-toolkit", default-features = false }

[build-dependencies]
plugin-toolkit-build = { version = ">=0.2.1-rc.47", registry = "gitea", package = "orca-plugin-toolkit-build" }'
fixture() {
  local dir="$root/$1" deps=${2:-$inline} src=${3:-sparse+file://$index/}
  mkdir -p "$dir"
  printf '[package]\nname = "my-plugin"\nversion = "0.1.0"\n\n%s\n' "$deps" > "$dir/Cargo.toml"
  printf '[[package]]\nname = "my-plugin"\nversion = "0.1.0"\n' > "$dir/Cargo.lock"
  for p in orca-plugin-toolkit orca-plugin-toolkit-build ${EXTRA_LOCK:-}; do
    printf '\n[[package]]\nname = "%s"\nversion = "0.2.1-rc.47"\nsource = "%s"\n' "${p%:*}" "$src" >> "$dir/Cargo.lock"
  done
  echo "$dir"
}
run() {
  : > "$CARGO_LOG"; : > "$root/out"
  (cd "$1" && GITHUB_OUTPUT="$root/out" /bin/bash "$script" >/dev/null)
}
check() {
  local name=$1 want=$2 dir
  dir=$(fixture "$name" "${3:-}")
  run "$dir" && rc=0 || rc=$?
  is "$name: exit 0" "$rc" 0
  is "$name: versions" "$(cat "$root/out")" "versions=orca-plugin-toolkit@$want,orca-plugin-toolkit-build@$want"
  is "$name: manifest pinned" "$(grep -c "= \"=$want\"" "$dir/Cargo.toml")" 2
  is "$name: precise updates" "$(paste -sd';' - < "$CARGO_LOG")" "update -p orca-plugin-toolkit --precise $want;update -p orca-plugin-toolkit-build --precise $want"
}

publish orca-plugin-toolkit 0.2.1-rc.9 0.2.1-rc.47 0.2.1-rc.48 0.2.1-rc.49!
publish orca-plugin-toolkit-build 0.2.1-rc.9 0.2.1-rc.47 0.2.1-rc.48 0.2.1-rc.49!
check same-patch-rc 0.2.1-rc.48

publish orca-plugin-toolkit 0.2.1-rc.47 0.2.2-rc.1 0.2.1-rc.48
publish orca-plugin-toolkit-build 0.2.1-rc.47 0.2.2-rc.1 0.2.1-rc.48
check next-patch-rc 0.2.2-rc.1

publish orca-plugin-toolkit 0.2.1-rc.47 0.2.1 0.2.1-rc.50
publish orca-plugin-toolkit-build 0.2.1-rc.47 0.2.1 0.2.1-rc.50
check stable 0.2.1

check shorthand 0.2.1 'orca-plugin-toolkit = ">=0.2.1-rc.47"

[build-dependencies.orca-plugin-toolkit-build]
version = ">=0.2.1-rc.47"
registry = "gitea"'

check dotted-package 0.2.1 '[dependencies.plugin-toolkit]
registry = "gitea"
version = ">=0.2.1-rc.47"
package = "orca-plugin-toolkit"

[target."cfg(unix)".build-dependencies.plugin-toolkit-build]
package = "orca-plugin-toolkit-build"
version = ">=0.2.1-rc.47"'

fails() {
  local name=$1 dir
  dir=$(fixture "$name" "${2:-}" "${3:-}")
  run "$dir" 2>/dev/null && rc=0 || rc=$?
  is "$name: non-zero exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" yes
}

dir=$(fixture git-sourced "" "git+https://example.invalid/orca?tag=v1#abc")
run "$dir" && rc=0 || rc=$?
is 'git-sourced: exit 0' "$rc" 0
is 'git-sourced: plain updates' "$(paste -sd';' - < "$CARGO_LOG")" 'update -p orca-plugin-toolkit;update -p orca-plugin-toolkit-build'
is 'git-sourced: manifest untouched' "$(grep -c '>=0.2.1-rc.47' "$dir/Cargo.toml")" 2

dir=$(fixture registry-git "" "registry+https://example.invalid/index")
run "$dir" && rc=0 || rc=$?
is 'registry+ git index: plain updates' "$(paste -sd';' - < "$CARGO_LOG")" 'update -p orca-plugin-toolkit;update -p orca-plugin-toolkit-build'

rm -f "$index/or/ca/orca-plugin-toolkit-build"
fails absent-404

publish orca-plugin-toolkit-build 0.2.1-rc.47! 0.2.1!
fails all-yanked

publish orca-plugin-toolkit-build 0.2.1
fails no-requirement '[dependencies]
serde = "1"'

rejects() {
  local name=$1 dir
  dir=$(fixture "$name")
  run "$dir" 2>"$root/err" && rc=0 || rc=$?
  is "$name: non-zero exit" "$([ "$rc" -ne 0 ] && echo yes || echo no)" yes
  is "$name: non-semver error" "$(grep -c 'non-semver version' "$root/err")" 1
}

publish orca-plugin-toolkit-build '0.2.1-rc.1\nx'
rejects newline-version

publish orca-plugin-toolkit-build '0.2.1-rc.1;rm -rf /'
rejects semicolon-version

publish orca-plugin-toolkit-build 0.2.1
EXTRA_LOCK=orca-plugin-toolkit fails duplicate-lock-entries

CARGO_FAIL="error: package ID specification did not match any packages" fails non-transient-cargo-error
is 'non-transient: single attempt' "$(wc -l < "$CARGO_LOG" | tr -d ' ')" 1

mkdir "$root/member"
cat > "$root/member/Cargo.lock" <<LOCK
[[package]]
name = "orca-plugin-toolkit"
version = "0.2.1"

[[package]]
name = "orca-plugin-toolkit-build"
version = "0.2.1"
LOCK
run "$root/member" && rc=0 || rc=$?
is 'workspace members: exit 0' "$rc" 0
is 'workspace members: empty versions' "$(cat "$root/out")" 'versions='
is 'workspace members: no cargo calls' "$(cat "$CARGO_LOG")" ''

mkdir "$root/nolock"
run "$root/nolock" && rc=0 || rc=$?
is 'no lock: exit 0' "$rc" 0

exit "$fail"
