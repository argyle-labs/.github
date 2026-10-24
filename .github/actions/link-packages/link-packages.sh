#!/usr/bin/env bash
set -euo pipefail

: "${GITEA_TOKEN:?GITEA_TOKEN required}"
: "${API_URL:?API_URL required}"
: "${OWNER:?OWNER required}"
: "${REPO_NAME:?REPO_NAME required}"
: "${TYPE:?TYPE required}"
NAMES="${NAMES:-}"
QUERY="${QUERY:-}"

auth_cfg="$(mktemp)"
trap 'rm -f "$auth_cfg"' EXIT
printf 'header = "Authorization: token %s"\n' "$GITEA_TOKEN" > "$auth_cfg"

api() {
  curl -sS --retry 3 --retry-all-errors --max-time 30 -K "$auth_cfg" "$@"
}

warn() {
  echo "::warning title=link-packages::$1"
}

if [ -z "$NAMES" ]; then
  [ -n "$QUERY" ] || { echo "::error::NAMES or QUERY required" >&2; exit 1; }
  page=1
  found=""
  while :; do
    body="$(api -f "$API_URL/packages/$OWNER?type=$TYPE&q=$QUERY&page=$page&limit=50")" \
      || { warn "listing $TYPE packages for $OWNER failed"; exit 0; }
    batch="$(jq -r '.[] | select(.repository == null) | .name' <<<"$body")"
    [ "$(jq 'length' <<<"$body")" -gt 0 ] || break
    found+="$batch"$'\n'
    page=$((page + 1))
  done
  NAMES="$(sort -u <<<"$found")"
fi

linked=0
skipped=0
failed=0
for name in $NAMES; do
  code="$(api -o /dev/null -w '%{http_code}' -X POST \
    "$API_URL/packages/$OWNER/$TYPE/$name/-/link/$REPO_NAME" || echo 000)"
  case "$code" in
    201) linked=$((linked + 1)); echo "linked $TYPE/$name -> $OWNER/$REPO_NAME" ;;
    400) skipped=$((skipped + 1)); echo "already linked: $TYPE/$name" ;;
    *) failed=$((failed + 1)); warn "link $TYPE/$name -> $OWNER/$REPO_NAME failed (HTTP $code)" ;;
  esac
done

echo "link-packages: $linked linked, $skipped already linked, $failed failed"
exit 0
