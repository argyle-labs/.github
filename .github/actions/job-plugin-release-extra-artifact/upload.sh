#!/usr/bin/env bash
set -euo pipefail
: "${NAME:?}" "${SRC:?}" "${TAG:?}" "${REPO:?}" "${API_URL:?}"
[ -d "$SRC" ] || { echo "::error::$SRC is not a directory"; exit 1; }

missing=()
command -v zstd >/dev/null || missing+=(zstd)
command -v jq >/dev/null || missing+=(jq)
if [ "${#missing[@]}" -gt 0 ]; then
  sudo=""
  [ "$(id -u)" -eq 0 ] || sudo=sudo
  $sudo apt-get update -qq
  DEBIAN_FRONTEND=noninteractive $sudo apt-get install -y --no-install-recommends "${missing[@]}"
fi

out=$(mktemp -d "${RUNNER_TEMP:-/tmp}/extra.XXXXXX")
trap 'rm -rf "$out"' EXIT
asset="${NAME}-${TAG}.tar.zst"
tar -C "$SRC" --zstd -cf "$out/$asset" .
(cd "$out" && sha256sum "$asset" > "$asset.sha256")

auth="Authorization: token ${GITEA_TOKEN}"
rid=$(curl -fsS -H "$auth" "$API_URL/repos/$REPO/releases/tags/$TAG" | jq -r '.id // empty')
[ -n "$rid" ] || { echo "::error::no release for $TAG"; exit 1; }
assets=$(curl -fsS -H "$auth" "$API_URL/repos/$REPO/releases/$rid/assets")

for f in "$asset" "$asset.sha256"; do
  for aid in $(printf '%s' "$assets" | jq -r --arg n "$f" '.[] | select(.name == $n) | .id'); do
    curl -fsS -X DELETE -H "$auth" "$API_URL/repos/$REPO/releases/$rid/assets/$aid" >/dev/null
  done
  echo "→ uploading $f"
  curl -fsS -H "$auth" -F "attachment=@$out/$f;filename=$f" \
    "$API_URL/repos/$REPO/releases/$rid/assets?name=$f" >/dev/null
done
echo "uploaded $asset to $TAG"
