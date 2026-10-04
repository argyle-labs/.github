#!/bin/bash
# Run one cargo build on a persistent macOS host inside a locked, reusable
# target-dir slot. See action.yml for the inputs (SLOT_* env).
# Must stay bash 3.2 + BSD userland safe: it runs under macOS /bin/bash.
set -euo pipefail

: "${SLOT_SCOPE:?}" "${SLOT_TARGET:?}" "${SLOT_RUN:?}"
SLOT_BINS="${SLOT_BINS:-}"
SLOT_PROFILE="${SLOT_PROFILE:-release}"
SLOT_COUNT="${SLOT_COUNT:-3}"
SLOT_CAP_GB="${SLOT_CAP_GB:-4}"
SLOT_SCCACHE="${SLOT_SCCACHE:-false}"
SLOT_MIN_FREE_GB="${SLOT_MIN_FREE_GB:-15}"
SLOT_JANITOR_DAYS="${SLOT_JANITOR_DAYS:-14}"
SLOT_BUSY_RETRIES="${SLOT_BUSY_RETRIES:-5}"
SLOT_BUSY_WAIT="${SLOT_BUSY_WAIT:-30}"

# These become path components. set -f: unquoted $SLOT_BINS must not glob.
set -f
for v in "$SLOT_SCOPE" "$SLOT_TARGET" "$SLOT_PROFILE" $SLOT_BINS; do
  case "$v" in
    ''|.*|*[!A-Za-z0-9._-]*) echo "::error::mint-cargo-slot: invalid scope/target/profile/bin '$v'"; exit 1 ;;
  esac
done
set +f
for v in "$SLOT_COUNT" "$SLOT_CAP_GB" "$SLOT_MIN_FREE_GB" "$SLOT_JANITOR_DAYS" \
  "$SLOT_BUSY_RETRIES" "$SLOT_BUSY_WAIT"; do
  case "$v" in
    ''|*[!0-9]*) echo "::error::mint-cargo-slot: expected a number, got '$v'"; exit 1 ;;
  esac
done
[ "$SLOT_COUNT" -ge 1 ] || { echo "::error::mint-cargo-slot: slots must be >= 1"; exit 1; }

root="$HOME/Library/Caches/orca-ci/target"
base="$root/$SLOT_SCOPE/$SLOT_TARGET"

# Runs under lockf with the slot lock held; the kernel drops the lock if this
# process dies, so there is no stale-lock state to clean up.
inner() {
  slot="$1"; k="$2"
  : > "$SLOT_WORK/acquired"
  touch "$slot/.last-used"

  cap_kb=$((SLOT_CAP_GB * 1048576))
  size_kb=$(du -sk "$slot" | awk '{print $1}')
  if [ "$size_kb" -gt "$cap_kb" ]; then
    echo "slot s$k is $((size_kb / 1048576))G (cap ${SLOT_CAP_GB}G): pruning"
    # .lock stays: deleting it would let another job lock a new inode at the same path.
    find "$slot" -mindepth 1 -maxdepth 1 ! -name .lock ! -name .last-used -exec rm -rf {} +
  fi

  free_kb=$(df -Pk "$slot" | awk 'NR == 2 {print $4}')
  if [ "$free_kb" -lt $((SLOT_MIN_FREE_GB * 1048576)) ]; then
    echo "::error title=Low disk on build host::$((free_kb / 1048576))G free under $root; need at least ${SLOT_MIN_FREE_GB}G to build"
    return 1
  fi

  # launchd's default soft limit (256) is too low for large links.
  maxf=$(sysctl -n kern.maxfilesperproc 2>/dev/null || echo "")
  if [ -n "$maxf" ] && ! ulimit -n "$maxf" 2>/dev/null; then
    echo "::warning::could not raise open-file limit to $maxf (now $(ulimit -n))"
  fi

  export CARGO_TARGET_DIR="$slot" TARGET="$SLOT_TARGET" BINS="$SLOT_BINS"
  # Per-slot port keeps concurrent jobs and the operator's own server (default
  # port) apart; only this port is ever stopped.
  export SCCACHE_SERVER_PORT=$((4300 + k))
  use_sccache=false
  if [ "$SLOT_SCCACHE" = true ]; then
    if command -v sccache >/dev/null 2>&1; then
      sccache --stop-server >/dev/null 2>&1 || true
      [ -n "${SCCACHE_ERROR_LOG:-}" ] && : > "$SCCACHE_ERROR_LOG" 2>/dev/null || true
      if sccache --start-server >/dev/null 2>&1; then
        use_sccache=true
        sccache --zero-stats >/dev/null 2>&1 || true
        if [ -n "${SCCACHE_ERROR_LOG:-}" ] && ro=$(grep -A 5 'storage write check failed' "$SCCACHE_ERROR_LOG" 2>/dev/null); then
          echo "::error title=sccache READ-ONLY::sccache cache is READ-ONLY (backend write check failed): cache will not fill. $(echo "$ro" | tr '\n' ' ')"
        fi
      else
        echo "::warning title=sccache unavailable::sccache did not start on port $SCCACHE_SERVER_PORT; building UNCACHED. $(tail -n 5 "${SCCACHE_ERROR_LOG:-/dev/null}" 2>/dev/null | tr '\n' ' ')"
      fi
    else
      echo "::warning title=sccache unavailable::sccache not installed; building UNCACHED."
    fi
  fi
  if [ "$use_sccache" = true ]; then
    export RUSTC_WRAPPER=sccache CARGO_INCREMENTAL=0
  else
    # Empty overrides a global ~/.cargo/config.toml rustc-wrapper.
    export RUSTC_WRAPPER=
    case "${CC:-}" in "sccache "*) export CC="${CC#sccache }" ;; esac
    case "${CXX:-}" in "sccache "*) export CXX="${CXX#sccache }" ;; esac
  fi

  # cargo re-uplifts a Fresh binary, so a missing one after the build means the
  # build did not produce it; a stale one must never be copied back.
  set -f
  for b in $SLOT_BINS; do rm -f "$slot/$SLOT_TARGET/$SLOT_PROFILE/$b"; done
  set +f

  echo "slot s$k: CARGO_TARGET_DIR=$slot sccache=$use_sccache port=$SCCACHE_SERVER_PORT nofile=$(ulimit -n)"
  t0=$SECONDS
  rc=0
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -i /bin/bash -euo pipefail -c "$SLOT_RUN" || rc=$?
  else
    /bin/bash -euo pipefail -c "$SLOT_RUN" || rc=$?
  fi
  touch "$slot/.last-used"

  summary="${GITHUB_STEP_SUMMARY:-/dev/null}"
  {
    echo "### $SLOT_TARGET: build $((SECONDS - t0))s (slot s$k, exit $rc)"
    echo "slot s$k size: $(du -sk "$slot" | awk '{printf "%.1fG", $1 / 1048576}') (cap ${SLOT_CAP_GB}G)"
    if [ "$use_sccache" = true ]; then
      stats=$(sccache --show-stats 2>&1) || stats="(sccache server not running)"
      echo '```'
      echo "$stats"
      echo '```'
      # ReadOnly mode fails every write without ever completing one.
      werr=$(echo "$stats" | awk '/^Cache write errors/ {print $NF}')
      wavg=$(echo "$stats" | awk '/^Average cache write/ {print $(NF-1)}')
      case "$werr" in ''|*[!0-9]*) werr=0 ;; esac
      if [ "${werr:-0}" -gt 0 ] && [ "$wavg" = 0.000 ]; then
        echo "**sccache cache is READ-ONLY**: ${werr} cache write errors and no successful write; the cache did not fill."
      fi
    fi
  } | tee -a "$summary"
  if [ "$use_sccache" = true ]; then
    if errs=$(grep -m 20 -iE 'error|warn|failed|panic' "${SCCACHE_ERROR_LOG:-}" 2>/dev/null); then
      echo "::warning title=sccache errors::$(echo "$errs" | tr '\n' ' ')"
    fi
    sccache --stop-server >/dev/null 2>&1 || true
  fi
  [ "$rc" -eq 0 ] || return "$rc"

  # Copy out while the lock is held so a later job cannot overwrite the binary
  # before the caller stages it.
  out="$PWD/target/$SLOT_TARGET/$SLOT_PROFILE"
  mkdir -p "$out"
  set -f
  for b in $SLOT_BINS; do
    src="$slot/$SLOT_TARGET/$SLOT_PROFILE/$b"
    [ -f "$src" ] || { echo "::error::binary not found at $src"; ls -la "$slot/$SLOT_TARGET/$SLOT_PROFILE" || true; return 1; }
    cp "$src" "$out/$b"
    echo "copied $src -> $out/$b"
  done
  set +f
}

if [ "${1:-}" = __inner ]; then
  inner "$2" "$3"
  exit $?
fi

mkdir -p "$base"
SLOT_WORK=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/mint-cargo-slot.XXXXXX")
export SLOT_WORK
trap 'rm -rf "$SLOT_WORK"' EXIT

# Janitor: a slot is renamed away while its lock is held, so a job that
# recreates the path gets a fresh dir and lock instead of racing the delete.
# Best-effort: a janitor failure never fails the build. set -e does not apply
# inside a subshell on the left of ||, so failures exit explicitly.
(
  n=0
  find "$root" -mindepth 3 -maxdepth 3 -type d -name 's[0-9]*' | while IFS= read -r d; do
    stamp="$d/.last-used"
    [ -e "$stamp" ] || stamp="$d"
    [ -n "$(find "$stamp" -maxdepth 0 -mtime +"$SLOT_JANITOR_DAYS")" ] || continue
    n=$((n + 1))
    trash="$root/.trash.$$.$n"
    if lockf -k -s -t 0 "$d/.lock" mv "$d" "$trash" 2>/dev/null && [ -d "$trash" ]; then
      echo "janitor: removing unused slot $d"
      rm -rf "$trash" || exit 1
    fi
  done || exit 1
  # Trash left by a janitor killed mid-delete holds no lock and no live slot.
  find "$root" -mindepth 1 -maxdepth 1 -name '.trash.*' -exec rm -rf {} + || exit 1
) || echo "::warning title=mint-cargo-slot janitor::janitor under $root failed (see errors above); building anyway"

export SLOT_SCOPE SLOT_TARGET SLOT_RUN SLOT_BINS SLOT_PROFILE SLOT_COUNT SLOT_CAP_GB \
  SLOT_SCCACHE SLOT_MIN_FREE_GB SLOT_JANITOR_DAYS
self="$0"
attempt=0
while :; do
  k=0
  while [ "$k" -lt "$SLOT_COUNT" ]; do
    slot="$base/s$k"
    mkdir -p "$slot"
    rm -f "$SLOT_WORK/acquired"
    rc=0
    lockf -k -s -t 0 "$slot/.lock" /bin/bash "$self" __inner "$slot" "$k" || rc=$?
    if [ -e "$SLOT_WORK/acquired" ]; then
      exit "$rc"
    fi
    echo "slot s$k busy"
    k=$((k + 1))
  done
  [ "$attempt" -lt "$SLOT_BUSY_RETRIES" ] || break
  attempt=$((attempt + 1))
  echo "all $SLOT_COUNT slots busy; retry $attempt/$SLOT_BUSY_RETRIES in ${SLOT_BUSY_WAIT}s"
  sleep "$SLOT_BUSY_WAIT"
done
echo "::error title=No free build slot::all $SLOT_COUNT slots under $base are locked by other jobs"
exit 1
