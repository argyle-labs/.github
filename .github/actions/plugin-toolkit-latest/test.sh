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
STUB
chmod +x "$root/bin/cargo"
export PATH="$root/bin:$PATH" CARGO_LOG="$root/cargo.log"

reg='registry+sparse+https://gitea.example/api/packages/org/cargo/'
run() {
  : > "$CARGO_LOG"; : > "$root/out"
  (cd "$1" && GITHUB_OUTPUT="$root/out" bash "$script" >/dev/null)
}

mkdir "$root/both"
cat > "$root/both/Cargo.lock" <<LOCK
[[package]]
name = "my-plugin"
version = "0.1.0"

[[package]]
name = "orca-plugin-toolkit"
version = "0.2.1-rc.47"
source = "$reg"

[[package]]
name = "orca-plugin-toolkit-build"
version = "0.2.1-rc.46"
source = "$reg"
LOCK
run "$root/both" && rc=0 || rc=$?
is 'both registry deps: exit 0' "$rc" 0
is 'both registry deps: versions output' "$(cat "$root/out")" 'versions=orca-plugin-toolkit@0.2.1-rc.47,orca-plugin-toolkit-build@0.2.1-rc.46'
is 'both registry deps: cargo calls' "$(cat "$CARGO_LOG" | paste -sd';' -)" 'update -p orca-plugin-toolkit;update -p orca-plugin-toolkit-build'

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
