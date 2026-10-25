#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/semver.sh"

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
vers=$(curl -fsSL --retry 3 --retry-all-errors --max-time 30 "$index/$path" | semver_jq -cs 'map(select(.yanked | not) | .vers)')
bad=$(semver_jq -j 'include "semver"; first(.[] | select(valid | not) | "!" + tostring) // ""' <<< "$vers")
if [ -n "$bad" ]; then
  printf '::error::%s: index returned non-semver version %q\n' "$crate" "${bad#!}" >&2
  exit 1
fi
v=$(semver_jq -r 'include "semver"; sort_by(key) | last // empty' <<< "$vers")
printf '%s\n' "$v"
