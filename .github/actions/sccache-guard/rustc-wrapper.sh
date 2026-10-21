#!/bin/bash
set -uo pipefail
limit=${SCCACHE_WRAP_TIMEOUT:-1200}
flag=${SCCACHE_BYPASS_FLAG:-${RUNNER_TEMP:-/tmp}/sccache-bypass}
[ -e "$flag" ] && exec "$@"
sccache "$@" &
pid=$!
(
  for ((i = 0; i < limit; i++)); do
    kill -0 "$pid" 2>/dev/null || exit 0
    sleep 1
  done
  : > "$flag"
  kill "$pid" 2>/dev/null
) &
dog=$!
wait "$pid" 2>/dev/null
rc=$?
kill "$dog" 2>/dev/null
wait "$dog" 2>/dev/null
if [ "$rc" -ne 0 ] && [ -e "$flag" ]; then
  echo "warning: sccache stalled for ${limit}s; compiling the rest of this job uncached" >&2
  exec "$@"
fi
exit "$rc"
