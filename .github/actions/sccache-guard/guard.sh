#!/bin/bash
set -uo pipefail

readonly_fail() {
  msg="sccache cache is READ-ONLY: $1; the cache will not fill (check the S3 cache backend disk, quota and credentials)."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "**$msg**" >> "$GITHUB_STEP_SUMMARY"
  fi
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request|pull_request_target) echo "::warning title=sccache READ-ONLY::$msg"; return 0 ;;
    *) echo "::error title=sccache READ-ONLY::$msg"; return 1 ;;
  esac
}

case "${1:-}" in
  errlog)
    ro=$(grep -A 5 'storage write check failed' "${2:-}" 2>/dev/null) || exit 0
    readonly_fail "backend write check failed: $(echo "$ro" | tr '\n' ' ')"
    ;;
  stats)
    flag=${SCCACHE_BYPASS_FLAG:-${RUNNER_TEMP:-/tmp}/sccache-bypass-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${GITHUB_JOB:-job}}
    if [ -e "$flag" ]; then
      echo "::warning title=sccache stalled::sccache stalled and was bypassed; this job compiled uncached and its stats come from a fresh server."
      exit 0
    fi
    command -v sccache >/dev/null 2>&1 || exit 0
    stats=$(sccache --show-stats 2>&1) || exit 0
    werr=$(echo "$stats" | awk '/^Cache write errors/ {print $NF}')
    wavg=$(echo "$stats" | awk '/^Average cache write/ {print $(NF-1)}')
    case "$werr" in ''|*[!0-9]*) werr=0 ;; esac
    if [ "$werr" -gt 0 ] && [ "$wavg" = 0.000 ]; then
      readonly_fail "${werr} cache write errors and no successful write"
    fi
    ;;
  install)
    wrap="${RUNNER_TEMP:-/tmp}/sccache-rustc-wrapper.sh"
    install -m 0755 "$(dirname "$0")/rustc-wrapper.sh" "$wrap" || exit 1
    {
      echo "RUSTC_WRAPPER=$wrap"
      if [ "${2:-}" = true ]; then echo "CC=$wrap cc"; echo "CXX=$wrap c++"; fi
    } >> "${GITHUB_ENV:-/dev/null}"
    ;;
  *) echo "usage: guard.sh errlog <file> | stats | install [cc]" >&2; exit 2 ;;
esac
