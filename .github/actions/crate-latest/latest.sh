#!/usr/bin/env bash
set -euo pipefail

crate=${1:?usage: latest.sh <crate>}
index=${INDEX_URL:-${CARGO_REGISTRIES_GITEA_INDEX:-sparse+https://gitea.scottkey.me/api/packages/argyle-labs/cargo/}}
index=${index#sparse+}
index=${index%/}
name=$(tr '[:upper:]' '[:lower:]' <<< "$crate")
case ${#name} in
  1) path=1/$name ;;
  2) path=2/$name ;;
  3) path=3/${name:0:1}/$name ;;
  *) path=${name:0:2}/${name:2:2}/$name ;;
esac
curl -fsSL --retry 3 --retry-all-errors --max-time 30 "$index/$path" | jq -rs '
  def key:
    (split("+")[0]) as $v
    | ($v | index("-")) as $i
    | [ (if $i then $v[:$i] else $v end | split(".") | map(tonumber)),
        (if $i then [0, ($v[$i + 1:] | split(".") | map(if test("^[0-9]+$") then [0, tonumber] else [1, .] end))] else [1] end) ];
  map(select(.yanked | not) | .vers) | sort_by(key) | last // empty
'
