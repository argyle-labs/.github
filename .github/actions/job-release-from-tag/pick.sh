#!/usr/bin/env bash
set -euo pipefail
tag=$(printf '%s' "${TAG:-}" | tr -d '[:space:]')
[ -n "$tag" ] && [ "${tag#v}" = "$tag" ] && tag="v$tag"
if [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+-rc\.[0-9]+$ ]]; then
  pre=true
elif [[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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
