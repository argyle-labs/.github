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
v=$(curl -fsSL --retry 3 --retry-all-errors --max-time 30 "$index/$path" | semver_jq -rs '
  include "semver";
  map(select(.yanked | not) | .vers) | sort_by(key) | last // empty
')
if [ -n "$v" ] && ! semver_valid "$v"; then
  printf '::error::%s: index returned non-semver version %q\n' "$crate" "$v" >&2
  exit 1
fi
printf '%s\n' "$v"
