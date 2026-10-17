#!/usr/bin/env bash

toml_get() {
  local file=$1 table=$2 key=$3
  [ -f "$file" ] || return 0
  awk -v t="[$table]" -v k="$key" '
    /^[[:space:]]*\[/ { gsub(/[[:space:]]/, ""); cur=$0; next }
    cur == t {
      line=$0; sub(/[[:space:]]*#.*$/, "", line)
      split(line, kv, "=")
      name=kv[1]; gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", name)
      if (name != k) next
      val=substr(line, index(line, "=") + 1)
      gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", val)
      print val; exit
    }' "$file"
}

release_baseline() {
  local json=$1 bin=$2 target=$3
  jq -r --arg bin "$bin" --arg target "$target" '
    [ .[] | select(.draft | not) | . as $r
      | .assets[]? | select(.name == "\($bin)-\($r.tag_name)-\($target)")
      | "\($r.tag_name) \(.size)" ] | first // empty' <<< "$json"
}

pct_tenths() {
  local now=$1 base=$2
  echo $(( (now - base) * 1000 / base ))
}

fmt_tenths() {
  local t=$1 sign=+
  if [ "$t" -lt 0 ]; then sign=-; t=$(( -t )); fi
  echo "${sign}$(( t / 10 )).$(( t % 10 ))%"
}

fmt_bytes() {
  awk -v b="$1" 'BEGIN { printf "%.2f MiB", b / 1048576 }'
}

evaluate() {
  local size=$1 base_size=$2 crates=$3 base_crates=$4
  local size_pct=$5 warn_pct=$6 crate_max=$7 max_bytes=$8 max_crates=$9
  local relative=${10:-fail} status=ok reasons=() t v
  for v in size base_size crates base_crates max_bytes max_crates; do
    is_uint "${!v}" || printf -v "$v" '%s' ""
  done
  for v in size_pct warn_pct crate_max; do
    is_uint "${!v}" || printf -v "$v" '%s' 0
  done
  if [ -n "$size" ] && [ -n "$base_size" ] && [ "$base_size" -gt 0 ]; then
    t=$(pct_tenths "$size" "$base_size")
    if [ $(( (size - base_size) * 100 )) -gt $(( size_pct * base_size )) ]; then
      status=$relative; reasons+=("size $(fmt_tenths "$t") > +${size_pct}%")
    elif [ $(( (size - base_size) * 100 )) -gt $(( warn_pct * base_size )) ]; then
      reasons+=("size $(fmt_tenths "$t") > +${warn_pct}%")
      status=warn
    fi
  fi
  if [ -n "$size" ] && [ -n "$max_bytes" ] && [ "$size" -gt "$max_bytes" ]; then
    status=fail; reasons+=("size over budget $(fmt_bytes "$max_bytes")")
  fi
  if [ -n "$crates" ] && [ -n "$base_crates" ] && [ $(( crates - base_crates )) -gt "$crate_max" ]; then
    [ "$status" = fail ] || status=$relative; reasons+=("+$(( crates - base_crates )) crates > +${crate_max}")
  fi
  if [ -n "$crates" ] && [ -n "$max_crates" ] && [ "$crates" -gt "$max_crates" ]; then
    status=fail; reasons+=("${crates} crates over budget ${max_crates}")
  fi
  local IFS=';'
  echo "${status}|${reasons[*]:-}"
}

is_uint() {
  [[ ${1:-} =~ ^[0-9]+$ ]]
}

SIZE_SEMVER='def sv: capture("^v(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(-rc\\.(?<r>[0-9]+))?$")
  | [(.a, .b, .c | tonumber), (if .r then 0 else 1 end), ((.r // "0") | tonumber)];'

size_baseline_tag() {
  local json=$1 tag=$2
  jq -r --arg tag "$tag" "$SIZE_SEMVER"'
    ($tag | sv) as $cur
    | ($tag | test("-rc\\.")) as $rc
    | [ .[] | select((.draft | not) and ($rc or (.prerelease | not)))
        | select(.tag_name | test("^v[0-9]+\\.[0-9]+\\.[0-9]+(-rc\\.[0-9]+)?$"))
        | select((.tag_name | sv) < $cur) ]
    | max_by(.tag_name | sv) | .tag_name // empty' <<< "$json"
}

size_history_sanitize() {
  jq -c 'def id: type == "string" and test("^[A-Za-z0-9._-]+$");
    if type == "array" then
      [ .[] | select(type == "object"
          and (.size | type) == "number" and .size >= 0
          and ((.crates | type) == "number" and .crates >= 0 or .crates == null)
          and (.bin | id) and (.target | id) and (.tag | id))
        | {tag, target, bin, size: (.size | floor), crates: (.crates | if . == null then null else floor end), date: (.date | if type == "string" then gsub("[^0-9TZ:.-]"; "") else null end)} ]
    else [] end' <<< "${1:-[]}" 2>/dev/null || echo "[]"
}

size_history_merge() {
  local history=$1 entries=$2 tag=$3
  jq -c -n --argjson h "$(size_history_sanitize "$history")" --argjson e "$(size_history_sanitize "$entries")" --arg tag "$tag" \
    '[$h[] | select(.tag != $tag)] + $e'
}

md_clean() {
  printf '%s' "${1//[<>|\`]/}"
}

size_section() {
  local entries=$1 base=$2 base_tag=$3 size_pct=$4 warn_pct=$5 crate_max=$6 max_bytes=$7 max_crates=$8
  local rows=() top="" top_t=-1 crate_up=0 name target size crates bsize bcrates res status why sz bs sd cd t d
  base_tag=$(md_clean "$base_tag")
  is_uint "$warn_pct" || warn_pct=0
  while IFS=$'\t' read -r name target size crates bsize bcrates; do
    is_uint "$size" || continue
    is_uint "$crates" || crates=""
    is_uint "$bsize" || bsize=""
    is_uint "$bcrates" || bcrates=""
    name=$(md_clean "$name"); target=$(md_clean "$target")
    res=$(evaluate "$size" "$bsize" "$crates" "$bcrates" "$size_pct" "$warn_pct" "$crate_max" "$max_bytes" "$max_crates" warn)
    status=${res%%|*}; why=${res#*|}
    sz=$(fmt_bytes "$size"); bs=-; sd=-; cd=-
    if [ -n "$bsize" ] && [ "$bsize" -gt 0 ]; then
      t=$(pct_tenths "$size" "$bsize")
      bs=$(fmt_bytes "$bsize")
      sd="$(printf '%+d' $(( size - bsize ))) B ($(fmt_tenths "$t"))"
      if [ $(( (size - bsize) * 100 )) -gt $(( warn_pct * bsize )) ] && [ "$t" -gt "$top_t" ]; then top_t=$t; fi
    fi
    if [ -n "$crates" ] && [ -n "$bcrates" ]; then
      d=$(( crates - bcrates ))
      cd=$(printf '%+d' "$d")
      if [ "$d" -gt "$crate_up" ]; then crate_up=$d; fi
      if [ "$d" -gt 0 ] && [ "$status" = ok ]; then
        echo "::warning title=release-size::${name} ${target}: ${cd} crates since ${base_tag}" >&2
      fi
    fi
    case $status in
      fail) echo "::error title=release-size::${name} ${target}: ${why}" >&2 ;;
      warn) echo "::warning title=release-size::${name} ${target}: ${why}" >&2 ;;
    esac
    rows+=("| ${name} | ${target} | ${sz} | ${bs} | ${sd} | ${crates:--} | ${cd} | $(status_icon "$status") ${status}${why:+: ${why//[<|\`]/}} |")
  done < <(jq -r --argjson b "$(size_history_sanitize "$base")" '
    .[] as $e | ([$b[] | select(.bin == $e.bin and .target == $e.target)] | first) as $p
    | [$e.bin, $e.target, $e.size, ($e.crates // ""), ($p.size // ""), ($p.crates // "")] | map(tostring) | @tsv' \
    <<< "$(size_history_sanitize "$entries")")
  if [ "$top_t" -ge 0 ]; then top="⚠ size grew $(fmt_tenths "$top_t") since ${base_tag}"; fi
  if [ "$crate_up" -gt 0 ] && [ -n "$top" ]; then
    top="${top}, +${crate_up} crates"
  elif [ "$crate_up" -gt 0 ]; then
    top="⚠ crates grew +${crate_up} since ${base_tag}"
  fi
  echo "$SIZE_MARKER"
  [ -z "$top" ] || { echo "**${top}**"; echo; }
  echo "### Size"
  echo "Baseline: \`${base_tag:-none}\`."
  echo
  echo "| bin | target | size | previous | delta | crates | delta | status |"
  echo "|---|---|---:|---:|---:|---:|---:|---|"
  printf '%s\n' ${rows[@]+"${rows[@]}"}
  echo "$SIZE_END"
}

status_icon() {
  case $1 in fail) echo "❌" ;; warn) echo "⚠️" ;; *) echo "✅" ;; esac
}

SIZE_MARKER='<!-- release-size -->'
SIZE_END='<!-- /release-size -->'

body_with_section() {
  local body=$1 section=$2 head rest tail=""
  if [[ $body == *"$SIZE_MARKER"* ]]; then
    head=${body%%"$SIZE_MARKER"*}
    rest=${body#*"$SIZE_MARKER"}
    [[ $rest != *"$SIZE_END"* ]] || tail=${rest#*"$SIZE_END"}
    printf '%s%s%s' "${head//"$SIZE_END"/}" "$section" "$tail"
  elif [ -n "$body" ]; then
    printf '%s\n\n%s' "${body//"$SIZE_END"/}" "$section"
  else
    printf '%s' "$section"
  fi
}
