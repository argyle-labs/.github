#!/usr/bin/env bash
set -euo pipefail
channel="${CHANNEL:-}"
if [ -z "$channel" ]; then
  if [ "$PRERELEASE" = true ]; then channel=rc; else channel=stable; fi
fi
src="${ORCA_SOURCE:-}"
if [ -z "$src" ]; then
  src=$(awk '
    /^\[\[package\]\]/          { want=0; next }
    /^name = "plugin-toolkit"$/ { want=1; next }
    want && /^source = /        { gsub(/"/, "", $3); print $3; exit }
  ' Cargo.lock 2>/dev/null || true)
fi
channel_tag=latest
[ "$channel" = stable ] || channel_tag="$channel"
{
  echo "version=$VERSION"
  echo "prerelease=$PRERELEASE"
  echo "channel=$channel"
  echo "channel-tag=$channel_tag"
  echo "orca-source=$src"
} >> "$GITHUB_OUTPUT"
