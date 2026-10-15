#!/usr/bin/env bash
set -euo pipefail
repo="${REPO:?}"
tag="$TAG"
api="$API_URL"
server="$SERVER_URL"
hdr_auth="Authorization: token ${GITEA_TOKEN}"
accept="Accept: application/json"
# ORCA_SOURCE is the lock source, e.g.
# git+https://github.com/argyle-labs/orca?tag=v0.2.1-rc.10#<sha>.
orca_ref="an unrecorded orca revision"
if [ -n "$ORCA_SOURCE" ]; then
  base=${ORCA_SOURCE%%#*}; rev=${ORCA_SOURCE##*#}; pin=${base#*\?}
  [ "$pin" = "$base" ] && pin="default branch"
  orca_ref="orca \`${pin/=/ }\` @ \`${rev:0:12}\`"
fi
notes="${NOTES:-}"
[ -z "$notes" ] && notes="Automated ${CHANNEL} release of \`${repo}\`, built against plugin-toolkit from ${orca_ref}. Plugin binary + sha256 + minisign signature per host target."
ls -la dist

payload=$(jq -n \
  --arg tag "$tag" \
  --arg sha "$SHA" \
  --arg name "$tag" \
  --arg body "$notes" \
  --argjson pre "$PRERELEASE" \
  '{tag_name:$tag, target_commitish:$sha, name:$name, body:$body, prerelease:$pre, draft:false}')
resp=$(curl -fsSL -X POST -H "$hdr_auth" -H "$accept" -H "Content-Type: application/json" \
  "$api/repos/$repo/releases" -d "$payload" 2>/dev/null || true)
rid=$(printf '%s' "$resp" | jq -r '.id // empty')
if [ -z "$rid" ]; then
  echo "→ create did not return an id; looking up existing release for $tag"
  rid=$(curl -fsSL -H "$hdr_auth" -H "$accept" \
    "$api/repos/$repo/releases/tags/$tag" | jq -r '.id // empty')
fi
if [ -z "$rid" ]; then
  echo "::error::could not create or find release $tag"; echo "$resp"; exit 1
fi
echo "release id: $rid"

for f in dist/*; do
  name=$(basename "$f")
  echo "→ uploading $name"
  code=$(curl -sS -X POST -H "$hdr_auth" \
    -F "attachment=@${f};filename=${name}" \
    -o /tmp/upload_resp.json -w '%{http_code}' \
    "$api/repos/$repo/releases/$rid/assets?name=$name")
  if [ "$code" -ge 300 ]; then
    echo "::error::asset upload failed for $name (HTTP $code)"; cat /tmp/upload_resp.json || true; exit 1
  fi
done
set -- dist/*
echo "published $tag with $# files → ${server}/$repo/releases/tag/$tag"
