#!/usr/bin/env bash
set -euo pipefail

script="$(cd "$(dirname "$0")" && pwd)/guard.sh"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/bin"
cat > "$work/bin/sccache" <<'T'
#!/bin/bash
cat "$STATS"
T
chmod +x "$work/bin/sccache"

cat > "$work/quota.log" <<'T'
[2026-11-01T00:00:00Z INFO sccache::server] server started
[2026-11-01T00:00:01Z ERROR sccache::server] cache write failed: S3 PutObject status code 403: QuotaExceeded: bucket quota exceeded
[2026-11-01T00:00:02Z ERROR sccache::server] request https://s3/x?X-Amz-Credential=GK0123456789abcdef&X-Amz-Signature=deadbeefcafe failed
[2026-11-01T00:00:03Z DEBUG sccache::server] Authorization: AWS4-HMAC-SHA256 Credential=GKsecretsecretsecret, secret_access_key=hunter2
[2026-11-01T00:00:04Z ERROR sccache::server] s3 secret 5f3c0123456789abcdef0123456789abcdef0123456789abcdef0123456789ab in bucket orca-sccache
[2026-11-01T00:00:05Z ERROR sccache::server] s3 aws secret wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY rejected
[2026-11-01T00:00:06Z ERROR sccache::server] s3 Authorization: Bearer tok3nvalue123 rejected
T

fail=0
expect() {
  local want=$1 name=$2 event=$3 stats=$4 must=$5 mustnot=$6 log=${7:-$work/quota.log} got=pass out
  printf '%s' "$stats" > "$work/stats.json"
  out=$(PATH="$work/bin:$PATH" STATS="$work/stats.json" GITHUB_EVENT_NAME=$event \
    SCCACHE_BYPASS_FLAG="$work/none" GITHUB_STEP_SUMMARY='' \
    bash "$script" stats "$log" 2>&1) || got=fail
  if [ "$got" = "$want" ] && [[ "$out" == *"$must"* ]] && { [ -z "$mustnot" ] || [[ "$out" != *"$mustnot"* ]]; }; then
    echo "ok: $name ($want)"
  else
    echo "FAIL: $name should $want [$must] without [$mustnot], got $got: $out" >&2
    fail=1
  fi
}

ro='{"stats":{"cache_write_errors":74,"cache_writes":0}}'
expect fail "read-only on push names the cause" push "$ro" QuotaExceeded ""
expect fail "credentials scrubbed" push "$ro" "X-Amz-Signature=***" deadbeefcafe
expect fail "secret key scrubbed" push "$ro" "::error" hunter2
expect fail "access key id scrubbed" push "$ro" "::error" GK0123456789abcdef
expect fail "bucket name survives" push "$ro" orca-sccache ""
expect fail "status code survives" push "$ro" "status code 403" ""
expect fail "bare hex secret scrubbed" push "$ro" "s3 secret ***" 5f3c0123456789abcdef
expect fail "base64 secret scrubbed" push "$ro" "aws secret ***" wJalrXUtnFEMI
expect fail "bearer token scrubbed" push "$ro" "Authorization: ***" tok3nvalue123
expect pass "read-only on pull_request warns" pull_request "$ro" "::warning title=sccache READ-ONLY" ""
expect pass "some writes succeeded" push '{"stats":{"cache_write_errors":3,"cache_writes":10}}' "" READ-ONLY
expect pass "no write errors" push '{"stats":{"cache_write_errors":0,"cache_writes":0}}' "" READ-ONLY
expect fail "pretty-printed stats parsed" push $'{\n  "stats": {\n    "cache_write_errors" : 74,\n    "cache_writes" : 0\n  }\n}' "::error title=sccache READ-ONLY" "stats unreadable"
expect pass "pretty-printed stats with writes" push $'{\n  "stats": {\n    "cache_write_errors": 3,\n    "cache_writes": 10\n  }\n}' "" "stats unreadable"
expect fail "unreadable stats + quota log on push" push 'garbage' "stats unreadable" ""
expect fail "unreadable stats + quota log names cause" push 'garbage' "QuotaExceeded" hunter2
expect pass "unreadable stats + quota log on pull_request" pull_request 'garbage' "::warning title=sccache READ-ONLY" "::error"
printf '[2026-11-01T00:00:00Z INFO sccache::server] server started\n' > "$work/clean.log"
expect pass "unreadable stats + clean log warns" push 'garbage' "::warning title=sccache guard::stats unreadable" READ-ONLY "$work/clean.log"

cat > "$work/write.log" <<'T'
[2026-11-01T00:00:00Z ERROR sccache::server] storage write check failed
  PUT https://s3/x?X-Amz-Credential=GK0123456789abcdef%2Fus-east-1&X-Amz-Signature=deadbeefcafe
T
out=$(GITHUB_EVENT_NAME=push GITHUB_STEP_SUMMARY='' bash "$script" errlog "$work/write.log" 2>&1) && got=pass || got=fail
if [ "$got" = fail ] && [[ "$out" == *"X-Amz-Signature=***"* ]] && [[ "$out" != *deadbeefcafe* ]] && [[ "$out" != *GK0123456789abcdef* ]]; then
  echo "ok: errlog output scrubbed (fail)"
else
  echo "FAIL: errlog output should be scrubbed, got $got: $out" >&2
  fail=1
fi

out=$(AWS_SECRET_ACCESS_KEY=awssecretval AWS_SESSION_TOKEN=sesstok SCCACHE_S3_KEY_PREFIX=pfx \
  SCCACHE_S3_SECRET=s3secretval SCCACHE_BUCKET=orca-sccache GITHUB_EVENT_NAME=push GITHUB_STEP_SUMMARY='' \
  bash "$script" errlog "$work/none.log" 2>&1) || true
if [[ "$out" == *"::add-mask::awssecretval"* ]] && [[ "$out" == *"::add-mask::sesstok"* ]] \
  && [[ "$out" == *"::add-mask::s3secretval"* ]] && [[ "$out" == *"::add-mask::pfx"* ]] && [[ "$out" != *orca-sccache* ]]; then
  echo "ok: add-mask emitted for set secret env vars"
else
  echo "FAIL: add-mask lines missing, got: $out" >&2
  fail=1
fi
out=$(env -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN GITHUB_EVENT_NAME=push bash "$script" errlog "$work/none.log" 2>&1) || true
if [[ "$out" != *add-mask* ]]; then
  echo "ok: no add-mask for unset vars"
else
  echo "FAIL: add-mask emitted for unset vars: $out" >&2
  fail=1
fi

exit "$fail"
