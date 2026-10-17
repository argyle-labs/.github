#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "$0")/lib.sh"

budget_file=${BUDGET_FILE:-size-budget.toml}
api=${API_URL:-https://gitea.scottkey.me/api/v1}
hdr=$(mktemp -d "${RUNNER_TEMP:-/tmp}/size-check.XXXXXX")
trap 'rm -rf "$hdr"' EXIT
(umask 077 && printf 'Authorization: token %s\n' "${GITEA_TOKEN:-}" > "$hdr/auth")
auth=(-H "@$hdr/auth" -H "Accept: application/json")
marker='<!-- plugin-size-check -->'

size_pct=${SIZE_PCT:?}; warn_pct=${WARN_PCT:?}; crate_max=${CRATE_MAX:?}
max_mib=$BUDGET_MIB; max_crates=${MAX_CRATES:-}
overridden=false
for key in size-pct warn-pct crates max-mib max-crates; do
  v=$(toml_get "$budget_file" size-check "$key")
  [ -n "$v" ] || continue
  is_uint "$v" || { echo "::error title=plugin-size-check::$budget_file [size-check] $key is not a whole number"; exit 1; }
  overridden=true
  case $key in
    size-pct) size_pct=$v ;;
    warn-pct) warn_pct=$v ;;
    crates) crate_max=$v ;;
    max-mib) max_mib=$v ;;
    max-crates) max_crates=$v ;;
  esac
done
reason=$(toml_get "$budget_file" size-check reason)
if [ "$overridden" = true ] && [ -z "$reason" ]; then
  echo "::error title=plugin-size-check::$budget_file overrides [size-check] thresholds without a reason"
  exit 1
fi
max_bytes=""
if is_uint "$max_mib"; then max_bytes=$(( max_mib * 1048576 )); else max_mib=""; fi
is_uint "$max_crates" || max_crates=""

count_crates() {
  (cd "$1" && cargo tree -e normal --prefix none --no-dedupe --workspace ${TARGET:+--target "$TARGET"}) \
    | sed 's/ (\/.*)$//' | sort -u | grep -c .
}

wt="${RUNNER_TEMP:-/tmp}/size-base-$$"
trap 'git worktree remove --force "$wt" >/dev/null 2>&1 || true; rm -rf "$hdr"' EXIT
crates_at() {
  local ref=$1
  [ -n "$ref" ] || return 0
  git rev-parse -q --verify "${ref}^{commit}" >/dev/null || git fetch -q --depth 1 origin "$ref" || return 0
  git worktree add -q --detach "$wt" "$ref" || return 0
  rm -f "$wt/.cargo/config.toml"
  count_crates "$wt" || true
}

crates=$(count_crates .)

releases="[]"
bins=()
if [ -n "${DIST_DIR:-}" ]; then
  while IFS= read -r b; do [ -n "$b" ] && bins+=("$b"); done <<< "${BINS:-}"
  if [ "${#bins[@]}" -gt 0 ]; then
    releases=$(curl -fsS "${auth[@]}" "$api/repos/$REPO/releases?limit=20" 2>/dev/null || echo "[]")
  fi
fi

base_tag=""
base_sizes=()
for b in ${bins[@]+"${bins[@]}"}; do
  t=""; s=""
  read -r t s <<< "$(release_baseline "$releases" "$b" "$TARGET")" || true
  if [ -n "$s" ]; then
    base_tag=${base_tag:-$t}
  else
    s=$(toml_get "$budget_file" baseline "$TARGET")
    is_uint "$s" || s=""
  fi
  base_sizes+=("$s")
done

base_ref=${BASE_REF:-$base_tag}
base_crates=$(crates_at "$base_ref")
base_src=${base_ref:-none}
if [ -z "$base_crates" ]; then
  base_crates=$(toml_get "$budget_file" baseline crates)
  is_uint "$base_crates" || base_crates=""
  base_src=none
  [ -n "$base_crates" ] && base_src=$budget_file
fi

relative=fail
[ -n "${BASE_REF:-}" ] || [ -n "${PR_NUMBER:-}" ] || relative=warn

rows=()
worst=ok
add_row() {
  local name=$1 size=$2 bsize=$3 res status why
  res=$(evaluate "$size" "$bsize" "$crates" "$base_crates" "$size_pct" "$warn_pct" "$crate_max" "$max_bytes" "$max_crates" "$relative")
  status=${res%%|*}; why=${res#*|}
  case $status in
    fail) worst=fail; echo "::error title=plugin-size-check::${name} ${TARGET:-host}: ${why}" ;;
    warn) [ "$worst" = fail ] || worst=warn; echo "::warning title=plugin-size-check::${name} ${TARGET:-host}: ${why}" ;;
  esac
  local sz=- bs=- sd=- cd=-
  [ -n "$size" ] && sz=$(fmt_bytes "$size")
  [ -n "$bsize" ] && bs=$(fmt_bytes "$bsize")
  if [ -n "$size" ] && [ -n "$bsize" ] && [ "$bsize" -gt 0 ]; then sd=$(fmt_tenths "$(pct_tenths "$size" "$bsize")"); fi
  if [ -n "$base_crates" ]; then cd=$(printf '%+d' $(( crates - base_crates ))); fi
  rows+=("| ${name} | ${TARGET:-host} | ${sz} | ${bs} | ${sd} | ${crates} | ${cd} | ${status}${why:+: ${why}} |")
}

if [ "${#bins[@]}" -gt 0 ]; then
  for i in "${!bins[@]}"; do
    b=${bins[$i]}
    f=$(find "$DIST_DIR" -maxdepth 1 -type f -name "${b}-*-${TARGET}" | head -n 1)
    sz=""; [ -n "$f" ] && sz=$(wc -c < "$f" | tr -d '[:space:]')
    add_row "$b" "$sz" "${base_sizes[$i]}"
  done
else
  add_row "${REPO##*/}" "" ""
fi

report=$(
  echo "$marker"
  echo "### Plugin size check (${worst})"
  echo "Baseline: release \`${base_tag:-none}\`, crates at \`${base_src}\`. Fail: +${size_pct}% size, +${crate_max} crates${max_mib:+, ${max_mib} MiB}${max_crates:+, ${max_crates} crates}. Warn: +${warn_pct}%."
  [ "$overridden" = true ] && echo "Override from \`${budget_file}\`: ${reason}"
  echo
  echo "| bin | target | size | baseline | delta | crates | delta | status |"
  echo "|---|---|---:|---:|---:|---:|---:|---|"
  printf '%s\n' "${rows[@]}"
)
echo "$report" >> "${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ -n "${PR_NUMBER:-}" ]; then
  body=$(jq -n --arg b "$report" '{body:$b}')
  cid=$(curl -fsS "${auth[@]}" "$api/repos/$REPO/issues/$PR_NUMBER/comments" 2>/dev/null \
    | jq -r --arg m "$marker" '[.[] | select(.body | startswith($m)) | .id] | first // empty' || true)
  if [ -n "$cid" ]; then
    curl -fsS "${auth[@]}" -X PATCH -H "Content-Type: application/json" \
      "$api/repos/$REPO/issues/comments/$cid" -d "$body" >/dev/null \
      || echo "::warning title=plugin-size-check::could not update PR comment $cid"
  else
    curl -fsS "${auth[@]}" -X POST -H "Content-Type: application/json" \
      "$api/repos/$REPO/issues/$PR_NUMBER/comments" -d "$body" >/dev/null \
      || echo "::warning title=plugin-size-check::could not post PR comment"
  fi
fi

if [ -n "${DIST_DIR:-}" ] && [ -n "${TARGET:-}" ]; then
  jq -n --arg t "$TARGET" --argjson c "$crates" '{target:$t, crates:$c}' > "$DIST_DIR/size-${TARGET}.json"
fi

[ "$worst" != fail ]
