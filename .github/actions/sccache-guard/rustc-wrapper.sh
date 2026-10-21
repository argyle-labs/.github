#!/bin/bash
set -uo pipefail
limit=${SCCACHE_WRAP_TIMEOUT:-1800}
flag=${SCCACHE_BYPASS_FLAG:-${RUNNER_TEMP:-/tmp}/sccache-bypass-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${GITHUB_JOB:-job}}
[ -e "$flag" ] && exec "$@"
sccache "$@" &
pid=$!
(
  for ((i = 0; i < limit; i++)); do
    kill -0 "$pid" 2>/dev/null || exit 0
    [ -e "$flag" ] && break
    sleep 1
  done
  kill -0 "$pid" 2>/dev/null || exit 0
  : > "$flag"
  kill "$pid" 2>/dev/null
) </dev/null >/dev/null 2>&1 &
dog=$!
wait "$pid" 2>/dev/null
rc=$?
kill "$dog" 2>/dev/null
wait "$dog" 2>/dev/null
if [ -e "$flag" ] && { [ "$rc" -eq 143 ] || [ "$rc" -eq 137 ]; }; then
  echo "warning: sccache stalled; compiling the rest of this job uncached" >&2
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && mkdir "$flag.reported" 2>/dev/null; then
    echo "**sccache stalled in job ${GITHUB_JOB:-job}; the rest of the job compiled uncached.**" >> "$GITHUB_STEP_SUMMARY"
  fi
  sccache --stop-server </dev/null >/dev/null 2>&1 &
  stopper=$!
  for ((i = 0; i < 10; i++)); do
    kill -0 "$stopper" 2>/dev/null || break
    sleep 1
  done
  exec "$@"
fi
exit "$rc"
