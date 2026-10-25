#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. "$(dirname "${BASH_SOURCE[0]}")/../../lib/semver.sh"
tag=$(printf '%s' "${TAG:-}" | tr -d '[:space:]')
[ -n "$tag" ] && [ "${tag#v}" = "$tag" ] && tag="v$tag"
if semver_valid_tag --rc "$tag"; then
  pre=true
elif semver_valid_tag --stable "$tag"; then
  pre=false
else
  echo "::error::tag '$TAG' is neither vX.Y.Z-rc.N nor vX.Y.Z"
  exit 1
fi
if [ -n "${EVENT_PRERELEASE:-}" ] && [ "$EVENT_PRERELEASE" != "$pre" ]; then
  echo "::error::release prerelease=$EVENT_PRERELEASE does not match tag $tag"
  exit 1
fi
{
  echo "version=${tag#v}"
  echo "tag=$tag"
  echo "rel-name=${REPO##*/} $tag"
  echo "prerelease=$pre"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"
