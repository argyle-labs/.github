# shellcheck shell=bash
http_curl() {
  local args=(-fsS --retry 3 --retry-all-errors --connect-timeout 10 --max-time "${HTTP_MAX_TIME:-300}")
  if [ -n "${HTTP_AUTH:-}" ]; then
    curl "${args[@]}" -H @<(printf 'Authorization: %s\n' "$HTTP_AUTH") "$@"
  else
    curl "${args[@]}" "$@"
  fi
}

http_json() {
  http_curl -H "Accept: application/json" -H "Content-Type: application/json" "$@"
}
