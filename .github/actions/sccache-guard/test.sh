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
T

fail=0
expect() {
  local want=$1 name=$2 event=$3 stats=$4 must=$5 mustnot=$6 got=pass out
  printf '%s' "$stats" > "$work/stats.json"
  out=$(PATH="$work/bin:$PATH" STATS="$work/stats.json" GITHUB_EVENT_NAME=$event \
    SCCACHE_BYPASS_FLAG="$work/none" GITHUB_STEP_SUMMARY='' \
    bash "$script" stats "$work/quota.log" 2>&1) || got=fail
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
expect pass "read-only on pull_request warns" pull_request "$ro" "::warning title=sccache READ-ONLY" ""
expect pass "some writes succeeded" push '{"stats":{"cache_write_errors":3,"cache_writes":10}}' "" READ-ONLY
expect pass "no write errors" push '{"stats":{"cache_write_errors":0,"cache_writes":0}}' "" READ-ONLY
expect pass "unparseable stats" push 'garbage' "" READ-ONLY

exit "$fail"
