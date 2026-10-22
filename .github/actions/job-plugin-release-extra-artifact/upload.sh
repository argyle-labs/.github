#!/usr/bin/env bash
set -euo pipefail
: "${NAME:?}" "${SRC:?}" "${TAG:?}" "${REPO:?}" "${API_URL:?}" "${GITEA_TOKEN:?}"
safe='^[A-Za-z0-9._+-]+$'
[[ $NAME =~ $safe && $NAME != *..* ]] || { echo "::error::invalid name '$NAME'"; exit 1; }
[[ $TAG =~ $safe ]] || { echo "::error::invalid tag '$TAG'"; exit 1; }
[ -d "$SRC" ] || { echo "::error::$SRC is not a directory"; exit 1; }
# shellcheck source=../../lib/http.sh
. "$(dirname "$0")/../../lib/http.sh"

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

export HTTP_AUTH="token ${GITEA_TOKEN}"
rel_api="$API_URL/repos/$REPO/releases"
rid=$(http_json "$rel_api/tags/$TAG" | jq -r '.id // empty')
[ -n "$rid" ] || { echo "::error::no release for $TAG"; exit 1; }

for f in "$asset" "$asset.sha256"; do
  tmp_name="$f.uploading-${GITHUB_RUN_ID:-$$}"
  echo "→ uploading $f"
  new=$(http_curl -F "attachment=@$out/$f;filename=$tmp_name" "$rel_api/$rid/assets?name=$tmp_name" | jq -r '.id // empty')
  [ -n "$new" ] || { echo "::error::upload of $f returned no asset id"; exit 1; }
  http_json "$rel_api/$rid/assets" \
    | jq -r --arg n "$f" '.[] | select(.name == $n) | .id' \
    | while read -r aid; do
        http_curl -X DELETE "$rel_api/$rid/assets/$aid" >/dev/null
      done
  http_json -X PATCH "$rel_api/$rid/assets/$new" -d "$(jq -n --arg n "$f" '{name:$n}')" >/dev/null
done
echo "uploaded $asset to $TAG"
