#!/usr/bin/env bash
# Prints a persistent CARGO_TARGET_DIR for REPO + BRANCH under ROOT, a host
# directory mounted into the job container; prints nothing when ROOT is absent.
# A new branch dir is seeded from the repo's BASE dir. Before that, dirs unused
# for MAX_AGE_DAYS are removed, then least-recently-used ones while ROOT holds
# more than MAX_KB. Use is the mtime of each dir's .ci-last-used stamp.
set -euo pipefail
root=${ROOT:?} repo=${REPO:?} branch=${BRANCH:?} base=${BASE:-main}
max_kb=${MAX_KB:?} max_age=${MAX_AGE_DAYS:?}
[ -d "$root" ] || exit 0

slug() { printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'; }
repo_dir="$root/$(slug "$repo")"
dir="$repo_dir/$(slug "$branch")"
seed="$repo_dir/$(slug "$base")"

exec 9> "$root/.lock"
if command -v flock >/dev/null; then flock 9; fi

used() {
  if [ -e "$1/.ci-last-used" ]; then
    stat -c %Y "$1/.ci-last-used" 2>/dev/null || stat -f %m "$1/.ci-last-used"
  else
    echo 0
  fi
}
cutoff=$(($(date +%s) - max_age * 86400))
total=0
lru=()
for d in "$root"/*/*/; do
  [ -d "$d" ] || continue
  d=${d%/}
  [ "$d" != "$dir" ] || continue
  t=$(used "$d")
  if [ "$t" -lt "$cutoff" ]; then
    rm -rf "$d"
    echo "pruned (unused ${max_age}d): ${d#"$root"/}" >&2
    continue
  fi
  kb=$(du -sk "$d" | cut -f1)
  total=$((total + kb))
  lru+=("$t $kb $d")
done
[ ! -d "$dir" ] || total=$((total + $(du -sk "$dir" | cut -f1)))
while IFS=' ' read -r _ kb d; do
  [ -n "$d" ] && [ "$total" -gt "$max_kb" ] || break
  rm -rf "$d"
  total=$((total - kb))
  echo "pruned (over $((max_kb / 1048576))G): ${d#"$root"/}" >&2
done < <(printf '%s\n' "${lru[@]+"${lru[@]}"}" | sort -n)

if [ ! -d "$dir" ]; then
  mkdir -p "$repo_dir"
  if [ -d "$seed" ]; then
    tmp="$dir.seed.$$"
    cp -a --reflink=auto "$seed" "$tmp" 2>/dev/null || { rm -rf "$tmp"; cp -a "$seed" "$tmp"; }
    mv "$tmp" "$dir"
    echo "seeded from ${seed#"$root"/}" >&2
  else
    mkdir -p "$dir"
  fi
fi
touch "$dir/.ci-last-used"
echo "$dir"
