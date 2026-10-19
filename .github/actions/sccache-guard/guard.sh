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
    command -v sccache >/dev/null 2>&1 || exit 0
    stats=$(sccache --show-stats 2>&1) || exit 0
    werr=$(echo "$stats" | awk '/^Cache write errors/ {print $NF}')
    wavg=$(echo "$stats" | awk '/^Average cache write/ {print $(NF-1)}')
    case "$werr" in ''|*[!0-9]*) werr=0 ;; esac
    if [ "$werr" -gt 0 ] && [ "$wavg" = 0.000 ]; then
      readonly_fail "${werr} cache write errors and no successful write"
    fi
    ;;
  *) echo "usage: guard.sh errlog <file> | stats" >&2; exit 2 ;;
esac
