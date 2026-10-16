#!/usr/bin/env bash
set -euo pipefail

here=$(realpath "$(dirname "$0")")
# shellcheck source=/dev/null
. "$here/lib.sh"
fx="$here/fixtures"
fail=0
eq() {
  if [ "$2" = "$3" ]; then echo "ok: $1"; else echo "FAIL: $1: got '$2' want '$3'" >&2; fail=1; fi
}

rel=$(cat "$fx/releases.json")
eq "latest published asset" "$(release_baseline "$rel" orca-plugin-demo x86_64-unknown-linux-gnu)" "v0.2.1 10485760"
eq "skips drafts, older release" "$(release_baseline "$rel" orca-plugin-demo x86_64-unknown-linux-musl)" "v0.2.0 8388608"
eq "no asset" "$(release_baseline "$rel" orca-plugin-demo aarch64-unknown-linux-gnu)" ""
eq "empty api" "$(release_baseline "[]" orca-plugin-demo x86_64-unknown-linux-gnu)" ""

eq "toml threshold" "$(toml_get "$fx/size-budget.toml" size-check size-pct)" "25"
eq "toml inline comment" "$(toml_get "$fx/size-budget.toml" size-check max-mib)" "30"
eq "toml string" "$(toml_get "$fx/size-budget.toml" size-check reason)" "bundles SQLCipher"
eq "toml bare key" "$(toml_get "$fx/size-budget.toml" baseline x86_64-unknown-linux-gnu)" "10485760"
eq "toml quoted key" "$(toml_get "$fx/size-budget.toml" baseline aarch64-unknown-linux-gnu)" "9000000"
eq "toml other table" "$(toml_get "$fx/size-budget.toml" baseline size-pct)" ""
eq "toml missing file" "$(toml_get "$fx/none.toml" baseline crates)" ""

eq "fmt +" "$(fmt_tenths "$(pct_tenths 11534336 10485760)")" "+10.0%"
eq "fmt -" "$(fmt_tenths "$(pct_tenths 9437184 10485760)")" "-10.0%"

mib=1048576
eq "unchanged" "$(evaluate $((10 * mib)) $((10 * mib)) 200 200 10 5 15 $((20 * mib)) "")" "ok|"
eq "warn band" "$(evaluate 11100000 $((10 * mib)) 200 200 10 5 15 "" "")" "warn|size +5.8% > +5%"
eq "at threshold" "$(evaluate 11534336 $((10 * mib)) 200 200 10 5 15 "" "")" "warn|size +10.0% > +5%"
eq "at warn" "$(evaluate 11010048 $((10 * mib)) 200 200 10 5 15 "" "")" "ok|"
eq "over threshold" "$(evaluate 11534337 $((10 * mib)) 200 200 10 5 15 "" "")" "fail|size +10.0% > +10%"
eq "crates growth" "$(evaluate "" "" 216 200 10 5 15 "" "")" "fail|+16 crates > +15"
eq "crates at limit" "$(evaluate "" "" 215 200 10 5 15 "" "")" "ok|"
eq "absolute size" "$(evaluate $((21 * mib)) "" 200 "" 10 5 15 $((20 * mib)) "")" "fail|size over budget 20.00 MiB"
eq "absolute crates" "$(evaluate "" "" 301 "" 10 5 15 "" 300)" "fail|301 crates over budget 300"
eq "no baseline" "$(evaluate $mib "" 200 "" 10 5 15 "" "")" "ok|"
eq "release size advisory" "$(evaluate 11534337 $((10 * mib)) 200 200 10 5 15 "" "" warn)" "warn|size +10.0% > +10%"
eq "release crates advisory" "$(evaluate "" "" 216 200 10 5 15 "" "" warn)" "warn|+16 crates > +15"
eq "release absolute size" "$(evaluate $((21 * mib)) $((10 * mib)) 200 200 10 5 15 $((20 * mib)) "" warn)" "fail|size +110.0% > +10%;size over budget 20.00 MiB"
eq "release absolute crates" "$(evaluate "" "" 301 200 10 5 15 "" 300 warn)" "fail|+101 crates > +15;301 crates over budget 300"
eq "warn then crate fail" "$(evaluate 11100000 $((10 * mib)) 300 200 10 5 15 "" "")" "fail|size +5.8% > +5%;+100 crates > +15"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin" "$work/dist"
cat > "$work/bin/curl" <<STUB
#!/usr/bin/env bash
case "\$*" in *releases*) cat "$fx/releases.json" ;; *) exit 22 ;; esac
STUB
cat > "$work/bin/cargo" <<'STUB'
#!/usr/bin/env bash
seq 1 "${CRATES:?}" | sed 's/^/crate-/'
echo "crate-1"
echo "orca-plugin-demo v0.3.0 (/work/demo)"
STUB
cat > "$work/bin/git" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "$work/bin/"*
run() {
  local want=$1 got=pass; shift
  (cd "$work" && env PATH="$work/bin:$PATH" GITHUB_STEP_SUMMARY="$work/summary" REPO=argyle-labs/demo \
    TARGET=x86_64-unknown-linux-gnu BINS=orca-plugin-demo DIST_DIR=dist \
    SIZE_PCT=10 WARN_PCT=5 CRATE_MAX=15 BUDGET_MIB=20 "$@" bash "$here/check.sh") >/dev/null 2>&1 || got=fail
  eq "check.sh $*" "$got" "$want"
}
head -c 11100000 /dev/zero > "$work/dist/orca-plugin-demo-v0.3.0-x86_64-unknown-linux-gnu"
run pass CRATES=200
if grep -q '| orca-plugin-demo | x86_64-unknown-linux-gnu | 10.59 MiB | 10.00 MiB | +5.8% | 201 | - | warn' "$work/summary"; then
  echo "ok: summary row"
else
  echo "FAIL: summary row" >&2; cat "$work/summary" >&2; fail=1
fi
head -c 12582912 /dev/zero > "$work/dist/orca-plugin-demo-v0.3.0-x86_64-unknown-linux-gnu"
run fail CRATES=200 BASE_REF=main
run pass CRATES=200
head -c 22020096 /dev/zero > "$work/dist/orca-plugin-demo-v0.3.0-x86_64-unknown-linux-gnu"
run fail CRATES=200
head -c 12582912 /dev/zero > "$work/dist/orca-plugin-demo-v0.3.0-x86_64-unknown-linux-gnu"
cp "$fx/size-budget.toml" "$work/size-budget.toml"
run pass CRATES=200
run fail CRATES=230 BASE_REF=main
cp "$fx/no-reason.toml" "$work/size-budget.toml"
run fail CRATES=200
rm "$work/size-budget.toml"
run pass CRATES=200 DIST_DIR= BINS=
exit "$fail"
