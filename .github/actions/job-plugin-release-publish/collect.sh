#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob
mkdir -p dist sizes
bad=0
for d in artifacts/*/; do
  d=${d%/}; art=${d#artifacts/}
  case "$art" in
    ui-dist) continue ;;
    plugin-*) triple=${art#plugin-} ;;
    *) echo "::error::unexpected artifact $art"; bad=1; continue ;;
  esac
  mapfile -t files < <(find "$d" -type f); wait $!
  for f in ${files[@]+"${files[@]}"}; do
    rel=${f#"$d"/}
    case "$rel" in
      */*) echo "::error::$art: unexpected nested file $rel"; bad=1 ;;
      "size-${triple}.json") mv "$f" sizes/ ;;
      ?*"-${TAG}-${triple}"|?*"-${TAG}-${triple}.sha256")
        if [ -e "dist/$rel" ]; then
          echo "::error::duplicate asset $rel"; bad=1
        else
          mv "$f" dist/
        fi ;;
      *) echo "::error::$art: unexpected file $rel"; bad=1 ;;
    esac
  done
done
[ "$bad" = 0 ] || exit 1
assets=(dist/*)
[ ${#assets[@]} -gt 0 ] || { echo "::error::no release assets collected"; exit 1; }
for f in ${assets[@]+"${assets[@]}"}; do
  case "$f" in
    *.sha256) [ -f "${f%.sha256}" ] || { echo "::error::orphan checksum $f"; bad=1; } ;;
    *) [ -f "$f.sha256" ] || { echo "::error::missing checksum for $f"; bad=1; } ;;
  esac
done
IFS=, read -ra requested <<< "${TARGETS//[][\"[:space:]]/}"
for t in ${requested[@]+"${requested[@]}"}; do
  case "$TAG" in *-rc.*) case "$t" in *-apple-darwin) continue ;; esac ;; esac
  bins=(dist/*-"${TAG}-${t}")
  [ ${#bins[@]} -gt 0 ] || { echo "::error::no binary for requested target $t"; bad=1; }
done
[ "$bad" = 0 ] || exit 1
