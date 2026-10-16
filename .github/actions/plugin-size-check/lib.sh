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
  local status=ok reasons=() t
  if [ -n "$size" ] && [ -n "$base_size" ] && [ "$base_size" -gt 0 ]; then
    t=$(pct_tenths "$size" "$base_size")
    if [ $(( (size - base_size) * 100 )) -gt $(( size_pct * base_size )) ]; then
      status=fail; reasons+=("size $(fmt_tenths "$t") > +${size_pct}%")
    elif [ $(( (size - base_size) * 100 )) -gt $(( warn_pct * base_size )) ]; then
      reasons+=("size $(fmt_tenths "$t") > +${warn_pct}%")
      status=warn
    fi
  fi
  if [ -n "$size" ] && [ -n "$max_bytes" ] && [ "$size" -gt "$max_bytes" ]; then
    status=fail; reasons+=("size over budget $(fmt_bytes "$max_bytes")")
  fi
  if [ -n "$crates" ] && [ -n "$base_crates" ] && [ $(( crates - base_crates )) -gt "$crate_max" ]; then
    status=fail; reasons+=("+$(( crates - base_crates )) crates > +${crate_max}")
  fi
  if [ -n "$crates" ] && [ -n "$max_crates" ] && [ "$crates" -gt "$max_crates" ]; then
    status=fail; reasons+=("${crates} crates over budget ${max_crates}")
  fi
  local IFS=';'
  echo "${status}|${reasons[*]:-}"
}
