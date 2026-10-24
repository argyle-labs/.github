#!/usr/bin/env bash
set -euo pipefail

[ -f Cargo.lock ] || { echo "no Cargo.lock; skipping"; exit 0; }
export CARGO_NET_RETRY=${CARGO_NET_RETRY:-5}
field() {
  awk -v want="$1" -v key="$2" '
    /^\[\[package\]\]/ { n=""; next }
    /^name = /         { gsub(/"/, "", $3); n=$3 }
    $1 == key && n == want { gsub(/"/, "", $3); print $3; exit }
  ' Cargo.lock
}
to=(); command -v timeout >/dev/null && to=(timeout 300)
versions=()
for p in orca-plugin-toolkit orca-plugin-toolkit-build; do
  if [ -z "$(field "$p" source)" ]; then
    echo "$p: not a sourced dependency; skipping"
    continue
  fi
  attempts=3
  for n in $(seq 1 "$attempts"); do
    ${to[@]+"${to[@]}"} cargo update -p "$p" && break
    if [ "$n" -eq "$attempts" ]; then
      echo "::error title=cargo update failed::cargo update -p $p failed after $attempts attempts"
      exit 1
    fi
    echo "::warning title=cargo update retry::attempt $n/$attempts failed; retrying in $((n * 30))s"
    sleep $((n * 30))
  done
  v=$(field "$p" version)
  echo "$p $v"
  versions+=("$p@$v")
done
out=$(IFS=,; echo "${versions[*]-}")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "versions=$out" >> "$GITHUB_OUTPUT"
fi
exit 0
