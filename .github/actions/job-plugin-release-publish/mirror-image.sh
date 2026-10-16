#!/usr/bin/env bash
set -uo pipefail
src="$REGISTRY/${NAME,,}:$VERSION"
dst="ghcr.io/${NAME,,}"
fail() {
  echo "::warning title=image-mirror::$1; release continues (Gitea is the source of truth)"
  printf 'Public mirror FAILED: %s\n' "$1" >> "$GITHUB_STEP_SUMMARY"
  exit 0
}
[ "$LOGIN_OUTCOME" = "success" ] || fail "ghcr.io login failed (check secrets.GH_TOKEN)"
docker buildx imagetools create --tag "$dst:$VERSION" --tag "$dst:$CHANNEL_TAG" "$src" \
  || fail "imagetools create $src → $dst failed"
printf 'Mirrored %s → %s:%s %s:%s\n' "$src" "$dst" "$VERSION" "$dst" "$CHANNEL_TAG" | tee -a "$GITHUB_STEP_SUMMARY"
