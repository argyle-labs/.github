#!/usr/bin/env bash
set -euo pipefail
repo="${REPO:?}"
tag="$TAG"
api="$API_URL"
server="$SERVER_URL"
hdr_auth="Authorization: token ${GITEA_TOKEN}"
accept="Accept: application/json"
resp_file=$(mktemp "${RUNNER_TEMP:-/tmp}/upload_resp.XXXXXX")
trap 'rm -f "$resp_file"' EXIT
orca_ref="an unrecorded orca revision"
if [ -n "$ORCA_SOURCE" ]; then
  base=${ORCA_SOURCE%%#*}; rev=${ORCA_SOURCE##*#}; pin=${base#*\?}
  [ "$pin" = "$base" ] && pin="default branch"
  orca_ref="orca \`${pin/=/ }\` @ \`${rev:0:12}\`"
fi
notes="${NOTES:-}"
[ -z "$notes" ] && notes="Automated ${CHANNEL} release of \`${repo}\`, built against plugin-toolkit from ${orca_ref}. Plugin binary + sha256 + minisign signature per host target."
ls -la dist

existing=$(curl -fsS -H "$hdr_auth" -H "$accept" "$api/repos/$repo/releases/tags/$tag" 2>/dev/null || true)
rid=$(printf '%s' "$existing" | jq -r '.id // empty' 2>/dev/null || true)
if [ -n "$rid" ]; then
  echo "→ publishing on existing release $tag (id $rid)"
  if [ -n "${NOTES:-}" ] || [ -z "$(printf '%s' "$existing" | jq -r '.body // empty')" ]; then
    curl -fsS -X PATCH -H "$hdr_auth" -H "$accept" -H "Content-Type: application/json" \
      "$api/repos/$repo/releases/$rid" -d "$(jq -n --arg body "$notes" '{body:$body}')" >/dev/null
  fi
  for f in dist/*; do
    name=$(basename "$f")
    aid=$(printf '%s' "$existing" | jq -r --arg n "$name" '.assets[]? | select(.name == $n) | .id')
    [ -z "$aid" ] || curl -fsS -X DELETE -H "$hdr_auth" "$api/repos/$repo/releases/$rid/assets/$aid" >/dev/null
  done
elif [ "${CREATE:-false}" = true ]; then
  payload=$(jq -n \
    --arg tag "$tag" \
    --arg sha "$SHA" \
    --arg name "$tag" \
    --arg body "$notes" \
    --argjson pre "$PRERELEASE" \
    '{tag_name:$tag, target_commitish:$sha, name:$name, body:$body, prerelease:$pre, draft:false}')
  resp=$(curl -fsSL -X POST -H "$hdr_auth" -H "$accept" -H "Content-Type: application/json" \
    "$api/repos/$repo/releases" -d "$payload")
  rid=$(printf '%s' "$resp" | jq -r '.id // empty')
  [ -n "$rid" ] || { echo "::error::could not create release $tag"; echo "$resp"; exit 1; }
else
  echo "::error::no release for $tag"; exit 1
fi
echo "release id: $rid"

for f in dist/*; do
  name=$(basename "$f")
  echo "→ uploading $name"
  code=$(curl -sS -X POST -H "$hdr_auth" \
    -F "attachment=@${f};filename=${name}" \
    -o "$resp_file" -w '%{http_code}' \
    "$api/repos/$repo/releases/$rid/assets?name=$name")
  if [ "$code" -ge 300 ]; then
    echo "::error::asset upload failed for $name (HTTP $code)"; cat "$resp_file" || true; exit 1
  fi
done
set -- dist/*
echo "published $tag with $# files → ${server}/$repo/releases/tag/$tag"
