#!/usr/bin/env bash
# Per-crate pass markers at ci-pass/<repo>/<job>/crate/<name>/<hash>.
# check-batch writes `missing` (JSON list) and `packages` (-p args);
# record-batch writes markers for $CRATES. Any backend failure in check-batch
# reports every crate as missing.
set -uo pipefail
PUT_BODY=""

# An empty or malformed map would otherwise run nothing. record-batch only
# warns: the job it records already passed.
all=$(jq -ce 'if type == "object" and length > 0 then keys else error end' <<< "${HASHES:-}" 2>/dev/null) || {
  if [ "$MODE" = record-batch ]; then
    echo "::warning title=ci-pass record skipped::hashes input is empty or not a non-empty JSON object"
    exit 0
  fi
  echo "::error title=ci-pass cache::hashes input is empty or not a non-empty JSON object"
  exit 1
}
emit() {
  echo "missing=$(jq -c . <<< "$1")" >> "$GITHUB_OUTPUT"
  echo "packages=$(jq -r 'map("-p " + .) | join(" ")' <<< "$1")" >> "$GITHUB_OUTPUT"
}

if [ -z "$ENDPOINT" ] || [ -z "$S3_ACCESS_KEY" ]; then
  echo "::warning title=ci-pass cache unavailable::no endpoint/credentials; running every crate"
  [ "$MODE" = check-batch ] && emit "$all"
  exit 0
fi
case "$ENDPOINT" in *://*) base="$ENDPOINT" ;; *) base="http://$ENDPOINT" ;; esac
# Credentials go to curl via a mode-600 config file, never argv.
CURL_CFG=$(umask 077 && mktemp "${RUNNER_TEMP:-/tmp}/ci-pass-curl.XXXXXX")
trap 'rm -f "$CURL_CFG"' EXIT
esc() { local v=${1//\\/\\\\}; printf '%s' "${v//\"/\\\"}"; }
printf 'user = "%s:%s"\n' "$(esc "$S3_ACCESS_KEY")" "$(esc "$S3_SECRET_KEY")" > "$CURL_CFG"

# One line per marker: "<crate> <job> <url>".
markers() {
  jq -r --arg jobs "$1" --arg base "$base/$BUCKET/ci-pass/$GITHUB_REPOSITORY" --argjson h "$HASHES" '
    .[] as $c | ($jobs | split(" ") | map(select(. != "")))[] as $j
    | "\($c) \($j) \($base)/\($j)/crate/\($c)/\($h[$c])"' <<< "$2"
}
# Reads marker lines and runs one curl per line, 16 at a time; prints
# "<crate> <job> <http code>". With PUT_BODY set it writes markers instead.
s3_each() {
  export CURL_CFG PUT_BODY
  # shellcheck disable=SC2016 # expanded by the inner bash
  xargs -P 16 -L 1 bash -c '
    put=()
    [ -z "${PUT_BODY:-}" ] || put=(-X PUT --data-binary "$PUT_BODY")
    code=$(curl -sS --max-time 20 --aws-sigv4 "aws:amz:us-east-1:s3" \
      --config "$CURL_CFG" -o /dev/null -w "%{http_code}" "${put[@]}" "$3" 2>/dev/null) || code=err
    echo "$1 $2 $code"' _
}

if [ "$MODE" = record-batch ]; then
  [ "$(jq length <<< "$CRATES")" -gt 0 ] || exit 0
  results=$(markers "$JOB" "$CRATES" | PUT_BODY=$GITHUB_SHA s3_each)
  echo "recorded $JOB passes for $(awk '$3 == 200' <<< "$results" | wc -l | tr -d ' ') crate(s)"
  failed=$(awk '$3 != 200 {printf "%s ", $1}' <<< "$results")
  [ -z "$failed" ] || echo "::warning title=ci-pass record failed::$JOB markers not written for: $failed"
  exit 0
fi

if [ "$FORCE" = true ]; then
  echo "forced full run"
  emit "$all"
  exit 0
fi
expected=$(markers "$JOB $ALSO" "$all" | wc -l)
results=$(markers "$JOB $ALSO" "$all" | s3_each)
if [ "$(grep -c . <<< "$results")" -ne "$expected" ] || awk '$3 != 200 && $3 != 404 {bad=1} END {exit !bad}' <<< "$results"; then
  echo "::warning title=ci-pass cache error::marker lookup failed; running every crate"
  emit "$all"
  exit 0
fi
missing=$(awk '$3 == 404 {print $1}' <<< "$results" | jq -Rn '[inputs] | unique')
emit "$missing"
echo "$(jq length <<< "$missing") of $(jq length <<< "$all") crate(s) need $JOB${ALSO:+ (or $ALSO)}: $(jq -r 'join(" ")' <<< "$missing")"
