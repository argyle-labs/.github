#!/usr/bin/env bash
set -euo pipefail
rel_api="${API_URL:-https://gitea.scottkey.me/api/v1}/repos/${REPO}/releases"
rel_name="${REPO##*/} $TAG"
auth=(-H "Authorization: token ${GITEA_TOKEN}")
list=$(curl -fsS "${auth[@]}" "${rel_api}?draft=true&limit=50")
ids=$(jq -r --argjson pre "$PRERELEASE" '.[] | select(.draft and .prerelease == $pre) | .id' <<< "$list")
for id in $ids; do
  curl -fsS "${auth[@]}" -X DELETE "${rel_api}/${id}" >/dev/null
  echo "→ deleted older draft id=$id"
done
body=$(jq -n --arg tag "$TAG" --arg name "$rel_name" --arg body "$REL_BODY" \
  --arg target "$TARGET" --argjson pre "$PRERELEASE" \
  '{tag_name:$tag, target_commitish:$target, name:$name, body:$body, prerelease:$pre, draft:true}')
id=$(curl -fsS "${auth[@]}" -X POST -H "Content-Type: application/json" -d "$body" "$rel_api" | jq -r '.id')
if [ -z "$id" ] || [ "$id" = null ]; then
  echo "::error::draft release not created"
  exit 1
fi
echo "→ draft $rel_name ($TAG @ $TARGET) id=$id"
