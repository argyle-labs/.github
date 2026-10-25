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
fixture() {
  local dir="$root/$1"
  mkdir -p "$dir"
  cat > "$dir/Cargo.toml" <<TOML
[package]
name = "my-plugin"
version = "0.1.0"

[dependencies]
plugin-toolkit = { version = ">=0.2.1-rc.47", registry = "gitea", package = "orca-plugin-toolkit", default-features = false }

[build-dependencies]
plugin-toolkit-build = { version = ">=0.2.1-rc.47", registry = "gitea", package = "orca-plugin-toolkit-build" }
TOML
  cat > "$dir/Cargo.lock" <<LOCK
[[package]]
name = "my-plugin"
version = "0.1.0"

[[package]]
name = "orca-plugin-toolkit"
version = "0.2.1-rc.47"
source = "sparse+file://$index/"

[[package]]
name = "orca-plugin-toolkit-build"
version = "0.2.1-rc.47"
source = "sparse+file://$index/"
LOCK
  echo "$dir"
}
run() {
  : > "$CARGO_LOG"; : > "$root/out"
  (cd "$1" && GITHUB_OUTPUT="$root/out" /bin/bash "$script" >/dev/null)
}
check() {
  local name=$1 want=$2 dir
  dir=$(fixture "$name")
  run "$dir" && rc=0 || rc=$?
  is "$name: exit 0" "$rc" 0
  is "$name: versions" "$(cat "$root/out")" "versions=orca-plugin-toolkit@$want,orca-plugin-toolkit-build@$want"
  is "$name: manifest pinned" "$(grep -c "version = \"=$want\"" "$dir/Cargo.toml")" 2
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
