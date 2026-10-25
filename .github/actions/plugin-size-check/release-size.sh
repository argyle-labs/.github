#!/usr/bin/env bash
set -Eeuo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"
trap '[ "$BASH_SUBSHELL" -gt 0 ] || { echo "::warning title=release-size::failed at line ${LINENO}: ${BASH_COMMAND}"; exit "${over_budget:-0}"; }' ERR

tag=${TAG:?}
body_tag=${BODY_TAG:-$tag}
budget_file=${BUDGET_FILE:-size-budget.toml}
api="${API_URL:-https://gitea.scottkey.me/api/v1}/repos/${REPO:?}"
history_name="size-history.json"
tmp=$(mktemp -d "${RUNNER_TEMP:-/tmp}/release-size.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
(umask 077 && printf 'Authorization: token %s\n' "${GITEA_TOKEN:-}" > "$tmp/auth")
auth=(-H "@$tmp/auth" -H "Accept: application/json")

size_pct=${SIZE_PCT:-10}; warn_pct=${WARN_PCT:-5}; crate_max=${CRATE_MAX:-15}
max_mib=${BUDGET_MIB:-20}; max_crates=${MAX_CRATES:-}
for key in size-pct warn-pct crates max-mib max-crates; do
  v=$(toml_get "$budget_file" size-check "$key")
  is_uint "$v" || continue
  case $key in
    size-pct) size_pct=$v ;;
    warn-pct) warn_pct=$v ;;
    crates) crate_max=$v ;;
    max-mib) max_mib=$v ;;
    max-crates) max_crates=$v ;;
  esac
done
max_bytes=""
is_uint "$max_mib" && max_bytes=$(( max_mib * 1048576 ))

for page in $(seq 1 20); do
  curl -fsS ${auth[@]+"${auth[@]}"} "$api/releases?limit=50&page=$page" > "$tmp/page-$page.json"
  jq -e 'type == "array"' "$tmp/page-$page.json" >/dev/null
  [ "$(jq length "$tmp/page-$page.json")" -eq 50 ] || break
done
releases=$(for f in $(seq 1 "$page"); do cat "$tmp/page-$f.json"; done | jq -c -s 'add // []')

release_of() { jq -c --arg t "$1" '[.[] | select(.tag_name == $t)] | first // empty' <<< "$releases"; }
fetch_history() {
  local url resp
  url=$(jq -r --arg n "$history_name" '[.assets[]? | select(.name == $n) | .browser_download_url] | first // empty' <<< "$1")
  [ -n "$url" ] || { echo "[]"; return; }
  if resp=$(curl -fsSL ${auth[@]+"${auth[@]}"} "$url") && jq -e 'type == "array"' <<< "$resp" >/dev/null 2>&1; then
    size_history_sanitize "$resp"
  else
    echo "::warning title=release-size::unreadable $history_name at $url" >&2
    echo "[]"
  fi
}

rel=$(release_of "$tag")
[ -n "$rel" ] || { echo "::warning title=release-size::no release $tag"; exit 0; }

if [ -n "${DIST_DIR:-}" ]; then
  prev_hist=$(jq -L "$SEMVER_LIB" -c --arg t "$tag" --arg n "$history_name" "$SIZE_SEMVER"'
    ($t | sv) as $cur
    | [ .[] | select((.draft | not) and any(.assets[]?; .name == $n))
        | select(.tag_name | release_tag)
        | select((.tag_name | sv) < $cur) ]
    | max_by(.tag_name | sv) // empty' <<< "$releases")
  history="[]"
  [ -z "$prev_hist" ] || history=$(fetch_history "$prev_hist")
  date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  entries="[]"
  for f in "$DIST_DIR"/*-"$tag"-*; do
    [ -f "$f" ] || continue
    case $f in *.sha256|*.minisig) continue ;; esac
    name=${f##*/}; bin=${name%%-"$tag"-*}; target=${name##*-"$tag"-}
    size=$(wc -c < "$f" | tr -d '[:space:]')
    crates=$(jq -r '.crates // empty' "${SIZES_DIR:-sizes}/size-${target}.json" 2>/dev/null || true)
    is_uint "$crates" || crates=""
    entries=$(jq -c --arg tag "$tag" --arg t "$target" --arg b "$bin" --arg d "$date" \
      --argjson s "$size" --arg c "$crates" \
      '. + [{tag:$tag, target:$t, bin:$b, size:$s, crates:($c | if . == "" then null else tonumber end), date:$d}]' <<< "$entries")
  done
  history=$(size_history_merge "$history" "$entries" "$tag")
  entries=$(jq -c --arg t "$tag" '[.[] | select(.tag == $t)]' <<< "$history")
  jq . <<< "$history" > "$tmp/$history_name"
  rid=$(jq -r .id <<< "$rel")
  aid=$(jq -r --arg n "$history_name" '.assets[]? | select(.name == $n) | .id' <<< "$rel")
  [ -z "$aid" ] || curl -fsS -X DELETE ${auth[@]+"${auth[@]}"} "$api/releases/$rid/assets/$aid" >/dev/null
  curl -fsS -X POST ${auth[@]+"${auth[@]}"} -F "attachment=@$tmp/$history_name;filename=$history_name" \
    "$api/releases/$rid/assets?name=$history_name" >/dev/null
else
  history=$(fetch_history "$rel")
  entries=$(jq -c --arg t "$tag" '[.[] | select(.tag == $t)]' <<< "$history")
  [ "$entries" != "[]" ] || { echo "no size history for $tag"; exit 0; }
fi

base_tag=$(size_baseline_tag "$releases" "$body_tag")
base="[]"
if [ -n "$base_tag" ]; then
  base=$(jq -c --arg t "$base_tag" '[.[] | select(.tag == $t)]' <<< "$history")
  if [ "$base" = "[]" ]; then
    base=$(release_of "$base_tag" | jq -c --arg t "$base_tag" '
      ($t | gsub("\\."; "\\.")) as $re
      | [.assets[]? | .name as $n | select($n | test("-\($re)-[^.]+$"))
        | {tag: $t, bin: ($n | split("-\($t)-")[0]), target: ($n | split("-\($t)-")[1]), size, crates: null}]')
    base=$(size_history_sanitize "$base")
  fi
fi

section=$(size_section "$entries" "$base" "$base_tag" "$size_pct" "$warn_pct" "$crate_max" "$max_bytes" "$max_crates" 2> "$tmp/annotations")
cat "$tmp/annotations" >&2
over_budget=0
! grep -q '^::error' "$tmp/annotations" || over_budget=1
echo "$section" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

target_rel=$(release_of "$body_tag")
[ -n "$target_rel" ] || { echo "::warning title=release-size::no release $body_tag to annotate"; exit "$over_budget"; }
body=$(body_with_section "$(jq -r '.body // ""' <<< "$target_rel")" "$section")
curl -fsS -X PATCH ${auth[@]+"${auth[@]}"} -H "Content-Type: application/json" \
  "$api/releases/$(jq -r .id <<< "$target_rel")" -d "$(jq -n --arg b "$body" '{body:$b}')" >/dev/null
echo "→ size section on $body_tag (baseline ${base_tag:-none})"
exit "$over_budget"
