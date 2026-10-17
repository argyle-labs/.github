#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

tag=${TAG:?}
body_tag=${BODY_TAG:-$tag}
budget_file=${BUDGET_FILE:-size-budget.toml}
api="${API_URL:-https://gitea.scottkey.me/api/v1}/repos/${REPO:?}"
auth=(-H "Authorization: token ${GITEA_TOKEN:-}" -H "Accept: application/json")
history_name="size-history.json"

size_pct=${SIZE_PCT:-10}; warn_pct=${WARN_PCT:-5}; crate_max=${CRATE_MAX:-15}
max_mib=${BUDGET_MIB:-20}; max_crates=${MAX_CRATES:-}
for key in size-pct warn-pct crates max-mib max-crates; do
  v=$(toml_get "$budget_file" size-check "$key")
  [ -n "$v" ] || continue
  case $key in
    size-pct) size_pct=$v ;;
    warn-pct) warn_pct=$v ;;
    crates) crate_max=$v ;;
    max-mib) max_mib=$v ;;
    max-crates) max_crates=$v ;;
  esac
done
max_bytes=""
[ -n "$max_mib" ] && max_bytes=$(( max_mib * 1048576 ))

releases=$(curl -fsS "${auth[@]}" "$api/releases?draft=true&limit=50")
release_of() { jq -c --arg t "$1" '[.[] | select(.tag_name == $t)] | first // empty' <<< "$releases"; }
fetch_history() {
  local url
  url=$(jq -r --arg n "$history_name" '[.assets[]? | select(.name == $n) | .browser_download_url] | first // empty' <<< "$1")
  [ -n "$url" ] && curl -fsSL "${auth[@]}" "$url" 2>/dev/null || echo "[]"
}

rel=$(release_of "$tag")
[ -n "$rel" ] || { echo "::error title=release-size::no release $tag"; exit 1; }

if [ -n "${DIST_DIR:-}" ]; then
  prev_hist=$(jq -c --arg t "$tag" --arg n "$history_name" \
    '[.[] | select((.draft | not) and .tag_name != $t and any(.assets[]?; .name == $n))] | first // empty' <<< "$releases")
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
    entries=$(jq -c --arg tag "$tag" --arg t "$target" --arg b "$bin" --arg d "$date" \
      --argjson s "$size" --arg c "$crates" \
      '. + [{tag:$tag, target:$t, bin:$b, size:$s, crates:($c | if . == "" then null else tonumber end), date:$d}]' <<< "$entries")
  done
  history=$(size_history_merge "$history" "$entries" "$tag")
  hist_file="${RUNNER_TEMP:-/tmp}/$history_name"
  jq . <<< "$history" > "$hist_file"
  rid=$(jq -r .id <<< "$rel")
  aid=$(jq -r --arg n "$history_name" '.assets[]? | select(.name == $n) | .id' <<< "$rel")
  [ -z "$aid" ] || curl -fsS -X DELETE "${auth[@]}" "$api/releases/$rid/assets/$aid" >/dev/null
  curl -fsS -X POST "${auth[@]}" -F "attachment=@${hist_file};filename=${history_name}" \
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
    base=$(release_of "$base_tag" | jq -c --arg t "$base_tag" \
      '[.assets[]? | .name as $n | select($n | test("-\($t)-[^.]+$"))
        | {bin: ($n | split("-\($t)-")[0]), target: ($n | split("-\($t)-")[1]), size}]')
  fi
fi

section=$(size_section "$entries" "$base" "$base_tag" "$size_pct" "$warn_pct" "$crate_max" "$max_bytes" "$max_crates")
echo "$section" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

target_rel=$(release_of "$body_tag")
[ -n "$target_rel" ] || { echo "::warning title=release-size::no release $body_tag to annotate"; exit 0; }
body=$(body_with_section "$(jq -r '.body // ""' <<< "$target_rel")" "$section")
curl -fsS -X PATCH "${auth[@]}" -H "Content-Type: application/json" \
  "$api/releases/$(jq -r .id <<< "$target_rel")" -d "$(jq -n --arg b "$body" '{body:$b}')" >/dev/null
echo "→ size section on $body_tag (baseline ${base_tag:-none})"
