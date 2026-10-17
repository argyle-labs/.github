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
trap '[ -n "${KEEP:-}" ] || rm -rf "$work"' EXIT
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

ch=$(cat "$fx/channels.json")
eq "rc baseline = latest rc" "$(size_baseline_tag "$ch" v0.4.0-rc.2)" "v0.4.0-rc.1"
eq "stable baseline skips rcs + drafts" "$(size_baseline_tag "$ch" v0.4.0)" "v0.3.0"
eq "rc baseline falls back to stable" "$(size_baseline_tag "$(jq -c '[.[] | select(.tag_name != "v0.4.0-rc.1")]' <<< "$ch")" v0.4.0-rc.2)" "v0.3.0"
eq "no baseline" "$(size_baseline_tag "[]" v0.1.0)" ""

e1='[{"tag":"v2","target":"t","bin":"b","size":2,"crates":1}]'
eq "history append" "$(size_history_merge '[{"tag":"v1","target":"t","bin":"b","size":1}]' "$e1" v2 | jq -c 'map(.tag)')" '["v1","v2"]'
eq "history rerun replaces" "$(size_history_merge "$(size_history_merge '[]' "$e1" v2)" "$e1" v2 | jq length)" "1"

cur='[{"tag":"v1","bin":"orca-plugin-demo","target":"x86_64-unknown-linux-gnu","size":11534336,"crates":204}]'
prev='[{"tag":"v1","bin":"orca-plugin-demo","target":"x86_64-unknown-linux-gnu","size":10485760,"crates":200}]'
sec=$(size_section "$cur" "$prev" v0.3.0 20 5 15 $((20 * mib)) "" 2>"$work/warn") || true
warn=$(cat "$work/warn")
eq "headline" "$(sed -n 2p <<< "$sec")" "**⚠ size grew +10.0% since v0.3.0, +4 crates**"
eq "row" "$(grep '^| orca' <<< "$sec")" "| orca-plugin-demo | x86_64-unknown-linux-gnu | 11.00 MiB | 10.00 MiB | +1048576 B (+10.0%) | 204 | +4 | ⚠️ warn: size +10.0% > +5% |"
eq "growth ::warning" "$(grep -c '^::warning title=release-size::orca-plugin-demo' <<< "$warn")" "1"
quiet=$(size_section "$prev" "$prev" v0.3.0 20 5 15 "" "" 2>&1 >/dev/null)
eq "no growth no warning" "$quiet" ""
eq "no growth no headline" "$(size_section "$prev" "$prev" v0.3.0 20 5 15 "" "" 2>/dev/null | sed -n 2p)" "### Size"
crw=$(size_section '[{"tag":"v1","bin":"b","target":"t","size":10,"crates":203}]' '[{"tag":"v1","bin":"b","target":"t","size":10,"crates":200}]' v1 20 5 15 "" "" 2>&1 >/dev/null)
eq "crate growth ::warning" "$crw" "::warning title=release-size::b t: +3 crates since v1"
eq "crate headline" "$(size_section '[{"tag":"v1","bin":"b","target":"t","size":10,"crates":203}]' '[{"tag":"v1","bin":"b","target":"t","size":10,"crates":200}]' v1 20 5 15 "" "" 2>/dev/null | sed -n 2p)" "**⚠ crates grew +3 since v1**"
eq "absolute fail" "$(size_section '[{"tag":"v1","bin":"b","target":"t","size":30,"crates":1}]' "[]" "" 20 5 15 20 "" 2>/dev/null | grep -c '❌ fail: size over budget')" "1"

once=$(body_with_section "notes" "$SIZE_MARKER
A
$SIZE_END")
twice=$(body_with_section "$once" "$SIZE_MARKER
B
$SIZE_END")
eq "body append" "$once" "notes

$SIZE_MARKER
A
$SIZE_END"
eq "body idempotent" "$twice" "notes

$SIZE_MARKER
B
$SIZE_END"
eq "body keeps tail" "$(body_with_section "x
$SIZE_MARKER
A
$SIZE_END
tail" "$SIZE_MARKER
B
$SIZE_END")" "x
$SIZE_MARKER
B
$SIZE_END
tail"
eq "body empty" "$(body_with_section "" "S")" "S"

rs="$work/rs"
mkdir -p "$rs/bin" "$rs/dist" "$rs/sizes"
cat > "$rs/bin/curl" <<STUB
#!/usr/bin/env bash
args="\$*"
echo "\$args" >> "$rs/argv"
case "\$args" in
  *"-X PATCH"*) u=""; d=""; while [ \$# -gt 0 ]; do case "\$1" in http*) u=\$1 ;; -d) d=\$2 ;; esac; shift; done; printf '%s' "\$d" > "$rs/patch-\${u##*/}" ;;
  *"-X DELETE"*) echo "\$args" >> "$rs/deleted" ;;
  *"-X POST"*) f=\${args#*attachment=@}; cp "\${f%%;*}" "$rs/uploaded.json" ;;
  *history-rc1.json*) cat "$fx/history-rc1.json" ;;
  *releases*) cat "$rs/releases.json" ;;
  *) exit 22 ;;
esac
STUB
chmod +x "$rs/bin/curl"
rsrun() {
  (cd "$rs" && env PATH="$rs/bin:$PATH" GITHUB_STEP_SUMMARY="$rs/summary" REPO=argyle-labs/demo GITEA_TOKEN=sekrit-token "$@" \
    bash "$here/release-size.sh") >"$rs/out" 2>&1
}
cp "$fx/channels.json" "$rs/releases.json"
head -c 11534336 /dev/zero > "$rs/dist/orca-plugin-demo-v0.4.0-rc.2-x86_64-unknown-linux-gnu"
echo x > "$rs/dist/orca-plugin-demo-v0.4.0-rc.2-x86_64-unknown-linux-gnu.sha256"
echo '{"target":"x86_64-unknown-linux-gnu","crates":210}' > "$rs/sizes/size-x86_64-unknown-linux-gnu.json"
rsrun TAG=v0.4.0-rc.2 DIST_DIR=dist SIZES_DIR=sizes || { cat "$rs/out" >&2; fail=1; }
eq "history carried + appended" "$(jq -c 'map(.tag)' "$rs/uploaded.json")" '["v0.3.0","v0.4.0-rc.1","v0.4.0-rc.2"]'
eq "history crates" "$(jq '.[-1].crates' "$rs/uploaded.json")" "210"
rc_body=$(jq -r .body "$rs/patch-5")
eq "rc body keeps notes" "$(head -n 1 <<< "$rc_body")" "Automated rc release."
eq "rc baseline rc.1" "$(grep -c 'since v0.4.0-rc.1' <<< "$rc_body")" "1"
eq "rc row vs rc.1" "$(grep -c '| 10.30 MiB | +734336 B (+6.7%) | 210 | +5 |' <<< "$rc_body")" "1"
eq "rc ::warning" "$(grep -c '^::warning title=release-size' "$rs/out")" "1"

jq --slurpfile h "$rs/uploaded.json" --arg b "$rc_body" \
  'map(if .id == 5 then .body = $b | .assets = [{id: 51, name: "size-history.json", browser_download_url: "https://git.example/history-rc2.json"}] else . end)' \
  "$fx/channels.json" > "$rs/releases.json"
cp "$rs/uploaded.json" "$rs/history-rc2.json"
sed -i.bak "s|\*history-rc1.json\*) cat \"$fx/history-rc1.json\"|*history-rc2.json*) cat \"$rs/history-rc2.json\"|" "$rs/bin/curl"
rsrun TAG=v0.4.0-rc.2 BODY_TAG=v0.4.0 || { cat "$rs/out" >&2; fail=1; }
st_body=$(jq -r .body "$rs/patch-6")
eq "stable draft baseline v0.3.0" "$(grep -c 'since v0.3.0' <<< "$st_body")" "1"
eq "stable draft row" "$(grep -c '| 10.00 MiB | +1048576 B (+10.0%) | 210 | +10 |' <<< "$st_body")" "1"

rsrun TAG=v0.4.0-rc.2 DIST_DIR=dist SIZES_DIR=sizes || { cat "$rs/out" >&2; fail=1; }
again=$(jq -r .body "$rs/patch-5")
eq "rerun idempotent" "$(grep -c '^<!-- release-size -->' <<< "$again")" "1"
eq "rerun replaces asset" "$(grep -c 'assets/51' "$rs/deleted")" "1"

pwn="$work/pwn"
hostile=$(jq -c -n --arg p "a[\$(touch $pwn)]" '[
  {tag:"v1", target:"t", bin:"b", size:10, crates:$p},
  {tag:"v1", target:"t", bin:"<!-- release-size -->", size:10, crates:1},
  {tag:"v1", target:"t|x", bin:"b", size:10, crates:1},
  {tag:"v1", target:"t", bin:"b", size:"10", crates:1},
  {tag:"v1", target:"t", bin:"ok", size:10.7, crates:2.2}]')
eq "hostile entries dropped" "$(size_history_sanitize "$hostile")" '[{"tag":"v1","target":"t","bin":"ok","size":10,"crates":2,"date":null}]'
eq "non-array history" "$(size_history_sanitize '{"a":1}')" "[]"
eq "invalid json history" "$(size_history_sanitize 'nope')" "[]"
size_section "$hostile" "$hostile" v1 20 5 15 "" "" >/dev/null 2>&1
evaluate 1 1 "a[\$(touch $pwn)]" 1 10 5 15 "" "" >/dev/null
eq "no code execution" "$([ -e "$pwn" ] && echo pwned || echo clean)" "clean"
eq "md clean" "$(md_clean 'a<b>|c`d')" "abcd"
eq "body END before MARKER" "$(body_with_section "x $SIZE_END y
$SIZE_MARKER
A" "$SIZE_MARKER
B
$SIZE_END")" "x  y
$SIZE_MARKER
B
$SIZE_END"
eq "body stray END" "$(body_with_section "x $SIZE_END" "S")" "x 

S"
sv='[{"tag_name":"v0.10.0","draft":false,"prerelease":false},{"tag_name":"v0.9.0","draft":false,"prerelease":false},{"tag_name":"v1.0.0","draft":false,"prerelease":false},{"tag_name":"vXdotY","draft":false,"prerelease":false}]'
eq "semver baseline" "$(size_baseline_tag "$sv" v0.11.0)" "v0.10.0"
eq "baseline below current only" "$(size_baseline_tag "$sv" v0.9.1)" "v0.9.0"

cp "$fx/channels.json" "$rs/releases.json"
rm -f "$rs"/patch-*
printf '#!/usr/bin/env bash\nexit 22\n' > "$rs/bin/curl.fail"
mv "$rs/bin/curl" "$rs/bin/curl.ok"; mv "$rs/bin/curl.fail" "$rs/bin/curl"; chmod +x "$rs/bin/curl"
if rsrun TAG=v0.4.0-rc.2 DIST_DIR=dist SIZES_DIR=sizes; then got=pass; else got=fail; fi
eq "curl failure fails step" "$got" "fail"
eq "curl failure ::warning" "$(grep -c '^::warning title=release-size::failed at line' "$rs/out")" "1"
eq "curl failure no patch" "$(find "$rs" -maxdepth 1 -name 'patch-*' | wc -l | tr -d ' ')" "0"
eq "curl called" "$([ -s "$rs/argv" ] && echo yes)" "yes"
eq "token not in argv" "$(grep -c 'sekrit-token' "$rs/argv" || true)" "0"
exit "$fail"
