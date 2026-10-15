#!/usr/bin/env bash
set -euo pipefail
case "$CHANNEL" in
  stable)
    version="$STABLE_VERSION"; tag="$STABLE_TAG"; prerelease=false ;;
  rc)
    version="$RC_VERSION"; tag="$RC_TAG"; prerelease=true ;;
  *)
    echo "::error::channel must be rc|stable (got '$CHANNEL')"; exit 1 ;;
esac
{
  echo "version=$version"
  echo "tag=$tag"
  echo "prerelease=$prerelease"
} >> "$GITHUB_OUTPUT"
echo "→ $CHANNEL ($BUMP) from ${PREVIOUS_STABLE}: $tag"
