#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/cache.sh"
root=$(mktemp -d)
trap 'rm -rf "$root"' EXIT
fail=0
run() { ROOT=$root REPO=org/app BRANCH=$1 MAX_KB=${2:-1000000} MAX_AGE_DAYS=7 bash "$script" 2>/dev/null; }
is() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: want '$3', got '$2'" >&2; fail=1; fi
}

is 'absent root prints nothing' "$(ROOT=$root/none REPO=org/app BRANCH=x MAX_KB=1 MAX_AGE_DAYS=7 bash "$script")" ''

main=$(run main)
is 'main dir' "$main" "$root/org_app/main"
echo built > "$main/lib.rlib"

feat=$(run feat/x)
is 'branch dir slug' "$feat" "$root/org_app/feat_x"
is 'branch seeded from main' "$(cat "$feat/lib.rlib" 2>/dev/null)" built

echo mine > "$feat/lib.rlib"
run feat/x >/dev/null
is 'existing branch dir kept' "$(cat "$feat/lib.rlib")" mine

old=$(run old)
touch -t 202001010000 "$old/.ci-last-used"
run main >/dev/null
is 'stale dir pruned' "$([ -d "$old" ] && echo kept || echo gone)" gone

a=$(run a)
head -c 300000 /dev/zero > "$a/blob"
touch -t 203001010000 "$a/.ci-last-used"
b=$(run b)
head -c 300000 /dev/zero > "$b/blob"
touch -t 203001020000 "$b/.ci-last-used"
run c 500 >/dev/null
is 'oldest pruned over cap' "$([ -d "$a" ] && echo kept || echo gone)" gone
is 'newer kept under cap' "$([ -d "$b" ] && echo kept || echo gone)" kept

exit "$fail"
