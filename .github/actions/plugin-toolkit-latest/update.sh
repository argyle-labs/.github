#!/usr/bin/env bash
set -euo pipefail

[ -f Cargo.lock ] || { echo "no Cargo.lock; skipping"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
export CARGO_NET_RETRY=${CARGO_NET_RETRY:-5}
field() {
  awk -v want="$1" -v key="$2" '
    /^\[\[package\]\]/ { n=""; next }
    /^name = /         { gsub(/"/, "", $3); n=$3 }
    $1 == key && n == want { gsub(/"/, "", $3); print $3; exit }
  ' Cargo.lock
}
to=(); command -v timeout >/dev/null && to=(timeout 300)
retry() {
  local attempts=3 n
  for n in $(seq 1 "$attempts"); do
    ${to[@]+"${to[@]}"} "$@" && return 0
    if [ "$n" -eq "$attempts" ]; then
      echo "::error title=cargo update failed::$* failed after $attempts attempts"
      return 1
    fi
    echo "::warning title=cargo update retry::attempt $n/$attempts failed; retrying in $((n * 30))s"
    sleep $((n * 30))
  done
}
manifests=()
while IFS= read -r f; do manifests+=("$f"); done < <(git ls-files -- '*Cargo.toml' 2>/dev/null)
[ "${#manifests[@]}" -gt 0 ] || while IFS= read -r f; do manifests+=("$f"); done < <(find . -name Cargo.toml -not -path './target/*')

pins=()
plain=()
for p in orca-plugin-toolkit orca-plugin-toolkit-build; do
  src=$(field "$p" source)
  case "$src" in
    "") echo "$p: not a sourced dependency; skipping" ;;
    registry+*|sparse+*)
      v=$(INDEX_URL=${src#registry+} /bin/bash "$here/../crate-latest/latest.sh" "$p")
      [ -n "$v" ] || { echo "::error::no published version of $p"; exit 1; }
      P="$p" V="$v" perl -i -pe '
        if (/package\s*=\s*"\Q$ENV{P}\E"/ || /^\s*\Q$ENV{P}\E\s*=/) { s/version\s*=\s*"[^"]*"/version = "=$ENV{V}"/ }
      ' "${manifests[@]}"
      pins+=("$p@$v")
      ;;
    *) plain+=("$p") ;;
  esac
done
for pv in ${pins[@]+"${pins[@]}"}; do
  retry cargo update -p "${pv%@*}" --precise "${pv#*@}"
done
for p in ${plain[@]+"${plain[@]}"}; do
  retry cargo update -p "$p"
done

versions=()
for p in orca-plugin-toolkit orca-plugin-toolkit-build; do
  [ -n "$(field "$p" source)" ] || continue
  v=$(field "$p" version)
  echo "$p $v"
  versions+=("$p@$v")
done
out=$(IFS=,; echo "${versions[*]-}")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "versions=$out" >> "$GITHUB_OUTPUT"
fi
exit 0
