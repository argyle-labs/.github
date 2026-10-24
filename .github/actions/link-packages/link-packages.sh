#!/usr/bin/env bash
set -euo pipefail

warn() {
  echo "::warning title=link-packages::$1"
}

command -v jq >/dev/null || { warn "jq not available; skipping package links"; exit 0; }

: "${GITEA_TOKEN:?GITEA_TOKEN required}"
: "${API_URL:?API_URL required}"
: "${OWNER:?OWNER required}"
: "${REPO_NAME:?REPO_NAME required}"
: "${TYPE:?TYPE required}"
NAMES="${NAMES:-}"
QUERY="${QUERY:-}"
DRY_RUN="${DRY_RUN:-false}"
MAX_PAGES=100

safe='^[A-Za-z0-9._-]+$'
for v in "$OWNER" "$REPO_NAME" "$TYPE"; do
  [[ "$v" =~ $safe ]] || { warn "invalid owner/repo/type '$v'; skipping package links"; exit 0; }
done

[[ "$GITEA_TOKEN" =~ $safe ]] || { warn "token has unexpected characters; skipping package links"; exit 0; }

auth_cfg="$(mktemp)"
trap 'rm -f "$auth_cfg"' EXIT
printf 'header = "Authorization: token %s"\n' "$GITEA_TOKEN" > "$auth_cfg"

api() {
  curl -sS --retry 3 --retry-all-errors --max-time 30 -K "$auth_cfg" "$@"
}

if [ -z "$NAMES" ]; then
  [ -n "$QUERY" ] || { echo "::error::NAMES or QUERY required" >&2; exit 1; }
  found=""
  page=1
  while [ "$page" -le "$MAX_PAGES" ]; do
    body="$(api -f -G "$API_URL/packages/$OWNER" \
      --data-urlencode "type=$TYPE" --data-urlencode "q=$QUERY" \
      --data-urlencode "page=$page" --data-urlencode "limit=50")" \
      || { warn "listing $TYPE packages for $OWNER failed"; exit 0; }
    count="$(jq 'length' <<<"$body" 2>/dev/null)" \
      || { warn "listing $TYPE packages returned invalid JSON"; exit 0; }
    [ "$count" -gt 0 ] || break
    batch="$(jq -r --arg q "$QUERY" '.[] | select(.name | startswith($q)) | .name' <<<"$body" 2>/dev/null)" \
      || { warn "listing $TYPE packages returned invalid JSON"; exit 0; }
    found+="$batch"$'\n'
    page=$((page + 1))
  done
  [ "$page" -le "$MAX_PAGES" ] || warn "stopped listing at $MAX_PAGES pages"
  NAMES="$(sort -u <<<"$found")"
fi

name_re="$safe"
[ "$TYPE" = "container" ] && name_re='^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$'

planned=()
for name in $NAMES; do
  if [[ "$name" =~ $name_re ]]; then
    planned+=("$name")
  else
    warn "skipping invalid package name '$name'"
  fi
done

echo "planned $TYPE links -> $OWNER/$REPO_NAME (${#planned[@]}):"
printf '  %s\n' ${planned[@]+"${planned[@]}"}
if [ "$DRY_RUN" = "true" ]; then
  echo "dry run; nothing linked"
  exit 0
fi

linked=0
skipped=0
failed=0
for name in ${planned[@]+"${planned[@]}"}; do
  path_name="${name//\//%2F}"
  code="$(api -o /dev/null -w '%{http_code}' -X POST \
    "$API_URL/packages/$OWNER/$TYPE/$path_name/-/link/$REPO_NAME" || echo 000)"
  case "$code" in
    201) linked=$((linked + 1)); echo "linked $TYPE/$name -> $OWNER/$REPO_NAME" ;;
    400)
      body="$(api -f "$API_URL/packages/$OWNER/$TYPE/$path_name/-/latest" || true)"
      current="$(jq -r '.repository.name // empty' <<<"$body" 2>/dev/null || true)"
      if [ "$current" = "$REPO_NAME" ]; then
        skipped=$((skipped + 1)); echo "already linked: $TYPE/$name"
      else
        failed=$((failed + 1)); warn "link $TYPE/$name -> $OWNER/$REPO_NAME rejected (HTTP 400); currently linked to '${current:-unknown}': ${body:0:300}"
      fi
      ;;
    *) failed=$((failed + 1)); warn "link $TYPE/$name -> $OWNER/$REPO_NAME failed (HTTP $code)" ;;
  esac
done

echo "link-packages: $linked linked, $skipped already linked, $failed failed"
exit 0
