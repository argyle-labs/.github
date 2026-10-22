#!/usr/bin/env bash
set -euo pipefail

here=$(realpath "$(dirname "$0")")
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
eq() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: got '$2' want '$3'" >&2; fail=1; fi
}

cat > "$tmp/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
case "$*" in
  *"-X DELETE"*) [ -z "${DELETE_FAIL:-}" ] ;;
  *) printf '%s' "$LIST" ;;
esac
STUB
chmod +x "$tmp/curl"

run() {
  : > "$tmp/calls"
  PATH="$tmp:$PATH" CALLS="$tmp/calls" API_URL=https://g/api/v1 REPO=o/r RUN_ID=7 NAME=nextest-archive GITEA_TOKEN=t \
    bash "$here/delete.sh"
}

out=$(LIST='{"artifacts":[{"id":3,"name":"nextest-archive"},{"id":4,"name":"lcov"}]}' run)
eq "deletes matching id" "$(grep -c 'DELETE' "$tmp/calls")" "1"
eq "targets id 3" "$(grep -o 'artifacts/3' "$tmp/calls")" "artifacts/3"
eq "reports deletion" "$out" "deleted artifact 'nextest-archive' (3)"

out=$(LIST='{"artifacts":[]}' run)
eq "absent artifact" "$out" "no artifact 'nextest-archive' in run 7"

out=$(LIST='{"artifacts":[{"id":3,"name":"nextest-archive"}]}' DELETE_FAIL=1 run)
eq "failure only warns" "$out" "::warning title=delete-artifact::deleting artifact 'nextest-archive' (3) failed"

eq "token not in args" "$(grep -c 't$\|token t' "$tmp/calls" || true)" "0"

exit "$fail"
