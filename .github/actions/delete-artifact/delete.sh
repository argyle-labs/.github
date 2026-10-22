#!/usr/bin/env bash
set -uo pipefail

hdr=$(mktemp -d)
trap 'rm -rf "$hdr"' EXIT
(umask 077 && printf 'Authorization: token %s\n' "${GITEA_TOKEN:-}" > "$hdr/auth")

warn() {
  echo "::warning title=delete-artifact::$1"
  exit 0
}

list=$(curl -fsS --retry 3 --max-time 30 -H @"$hdr/auth" \
  "$API_URL/repos/$REPO/actions/runs/$RUN_ID/artifacts?name=$NAME") \
  || warn "listing artifacts of run $RUN_ID failed"
ids=$(jq -r --arg n "$NAME" '.artifacts[]? | select(.name == $n) | .id' <<< "$list") \
  || warn "unreadable artifact list"
if [ -z "$ids" ]; then
  echo "no artifact '$NAME' in run $RUN_ID"
  exit 0
fi
for id in $ids; do
  if curl -fsS --retry 3 --max-time 30 -X DELETE -H @"$hdr/auth" \
      "$API_URL/repos/$REPO/actions/artifacts/$id" > /dev/null; then
    echo "deleted artifact '$NAME' ($id)"
  else
    warn "deleting artifact '$NAME' ($id) failed"
  fi
done
