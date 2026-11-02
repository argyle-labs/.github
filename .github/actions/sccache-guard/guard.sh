#!/bin/bash
set -uo pipefail

scrub() {
  perl -pe '
      s/((?:X-Amz-)?(?:Signature|Credential|Security-Token)=)[^&\s",]*/$1***/gi;
      s/(Authorization:?\s*)\S+(\s+\S+)?/$1***/gi;
      s/((?:secret|token|password|access_key|key_id)\w*"?\s*[:=]\s*"?)[^"&\s,]+/$1***/gi;
      s/\b(AKIA|ASIA|GK)[A-Za-z0-9]{12,}/$1***/g;
      s/\b[0-9a-f]{40,}\b/***/gi;
      s{(?<![A-Za-z0-9/+])[A-Za-z0-9/+]{40}(?![A-Za-z0-9/+])}{***}g'
}

mask_env() {
  local v
  for v in AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN $(compgen -v SCCACHE_S3_); do
    case "$v" in
      AWS_*|*KEY*|*SECRET*|*TOKEN*|*PASSWORD*) [ -n "${!v:-}" ] && echo "::add-mask::${!v}" ;;
    esac
  done
}

s3_cause() {
  [ -r "${1:-}" ] || return 0
  grep -iE 'quota|denied|forbidden|unauthori[sz]ed|nosuchbucket|invalidaccesskey|signaturedoesnotmatch|status[ _-]?code|[^0-9](403|404|500|503)[^0-9]|s3|error' "$1" \
    | tail -n 5 \
    | scrub \
    | cut -c1-300 \
    | tr '\n' ' '
}

readonly_fail() {
  cause=$(s3_cause "${log:-}")
  msg="sccache cache is READ-ONLY: $1; the cache will not fill. ${cause:+Last S3 errors: $cause}"
  msg=${msg% }
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "**$msg**" >> "$GITHUB_STEP_SUMMARY"
  fi
  case "${GITHUB_EVENT_NAME:-}" in
    pull_request|pull_request_target) echo "::warning title=sccache READ-ONLY::$msg"; return 0 ;;
    *) echo "::error title=sccache READ-ONLY::$msg"; return 1 ;;
  esac
}

case "${1:-}" in
  errlog|stats) mask_env ;;
esac

case "${1:-}" in
  errlog)
    log=${2:-}
    ro=$(grep -A 5 'storage write check failed' "${2:-}" 2>/dev/null) || exit 0
    readonly_fail "backend write check failed: $(echo "$ro" | scrub | tr '\n' ' ')"
    ;;
  stats)
    flag=${SCCACHE_BYPASS_FLAG:-${RUNNER_TEMP:-/tmp}/sccache-bypass-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-0}-${GITHUB_JOB:-job}}
    if [ -e "$flag" ]; then
      echo "::warning title=sccache stalled::sccache stalled and was bypassed; this job compiled uncached and its stats come from a fresh server."
      exit 0
    fi
    command -v sccache >/dev/null 2>&1 || exit 0
    log=${2:-${SCCACHE_ERROR_LOG:-}}
    stats=$(sccache --show-stats --stats-format json 2>/dev/null) || exit 0
    werr=$(echo "$stats" | grep -o '"cache_write_errors":[0-9]*' | cut -d: -f2)
    wok=$(echo "$stats" | grep -o '"cache_writes":[0-9]*' | cut -d: -f2)
    case "$werr" in ''|*[!0-9]*) werr=0 ;; esac
    case "$wok" in ''|*[!0-9]*) exit 0 ;; esac
    if [ "$werr" -gt 0 ] && [ "$wok" -eq 0 ]; then
      readonly_fail "${werr} cache write errors and no successful write"
    fi
    ;;
  install)
    dir="${RUNNER_TEMP:-/tmp}/sccache-guard"
    mkdir -p "$dir" || exit 1
    for f in rustc-wrapper.sh cc-wrapper.sh cxx-wrapper.sh; do
      install -m 0755 "$(dirname "$0")/$f" "$dir/$f" || exit 1
    done
    {
      echo "RUSTC_WRAPPER=$dir/rustc-wrapper.sh"
      echo "SCCACHE_CC=$dir/cc-wrapper.sh"
      echo "SCCACHE_CXX=$dir/cxx-wrapper.sh"
      if [ "${2:-}" = true ]; then echo "CC=$dir/cc-wrapper.sh"; echo "CXX=$dir/cxx-wrapper.sh"; fi
    } >> "${GITHUB_ENV:-/dev/null}"
    ;;
  *) echo "usage: guard.sh errlog <file> | stats | install [cc]" >&2; exit 2 ;;
esac
