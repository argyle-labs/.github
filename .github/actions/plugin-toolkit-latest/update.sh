#!/usr/bin/env bash
set -euo pipefail

[ -f Cargo.lock ] || { echo "no Cargo.lock; skipping"; exit 0; }
here=$(cd "$(dirname "$0")" && pwd)
export CARGO_NET_RETRY=${CARGO_NET_RETRY:-5}
entries() {
  awk -v want="$1" '
    function flush() { if (n == want) print v, (s == "" ? "-" : s) }
    /^\[\[package\]\]/ { flush(); n = v = s = ""; next }
    /^name = /         { gsub(/"/, "", $3); n = $3 }
    /^version = /      { gsub(/"/, "", $3); v = $3 }
    /^source = /       { gsub(/"/, "", $3); s = $3 }
    END                { flush() }
  ' Cargo.lock
}
transient='network|timed? ?out|connection|could not resolve|failed to (download|get|fetch|query|update)|spurious|tls|ssl|reset by peer|50[234]'
to=(); command -v timeout >/dev/null && to=(timeout 300)
retry() {
  local attempts=3 n rc log
  log=$(mktemp)
  for n in $(seq 1 "$attempts"); do
    rc=0
    ${to[@]+"${to[@]}"} "$@" > >(tee "$log") 2>&1 || rc=$?
    [ "$rc" -eq 0 ] && { rm -f "$log"; return 0; }
    if [ "$rc" -ne 124 ] && ! grep -qiE "$transient" "$log"; then
      echo "::error title=cargo update failed::$* failed (exit $rc, not a network error)"
      rm -f "$log"; return 1
    fi
    if [ "$n" -eq "$attempts" ]; then
      echo "::error title=cargo update failed::$* failed after $attempts attempts"
      rm -f "$log"; return 1
    fi
    echo "::warning title=cargo update retry::attempt $n/$attempts failed; retrying in $((n * 30))s"
    sleep $((n * 30))
  done
}
pin() {
  P="$1" V="$2" perl -0777 -i -pe '
    my ($p, $v) = ($ENV{P}, $ENV{V});
    my $line = sub {
      my $l = shift;
      if ($l =~ /^\s*([\w-]+)\s*=\s*\{.*\}/) {
        my $key = $1;
        my ($pkg) = $l =~ /package\s*=\s*"([^"]*)"/;
        $main::hits += $l =~ s/version\s*=\s*"[^"]*"/version = "=$v"/ if ($pkg // $key) eq $p;
      } elsif ($l =~ /^\s*\Q$p\E\s*=\s*"/) {
        $main::hits += $l =~ s/=\s*"[^"]*"/= "=$v"/;
      }
      $l;
    };
    my @parts = split /^(?=\s*\[)/m;
    for (@parts) {
      if (/\A\s*\[(?:[^\]]*\.)?(?:dev-|build-)?dependencies\.([^\]\s]+)\]/) {
        (my $key = $1) =~ s/["\x27]//g;
        my ($pkg) = /^\s*package\s*=\s*"([^"]*)"/m;
        $main::hits += s/^(\s*version\s*=\s*)"[^"]*"/$1"=$v"/m if ($pkg // $key) eq $p;
      } else {
        $_ = join "", map { $line->($_) } split /(?<=\n)/;
      }
    }
    $_ = join "", @parts;
    END { print STDERR (($main::hits // 0) . "\n") }
  ' "${manifests[@]}" 2>&1 >/dev/null | awk '{ s += $1 } END { print s + 0 }'
}
manifests=()
while IFS= read -r f; do manifests+=("$f"); done < <(git ls-files -- '*Cargo.toml' 2>/dev/null)
[ "${#manifests[@]}" -gt 0 ] || while IFS= read -r f; do manifests+=("$f"); done < <(find . -name Cargo.toml -not -path './target/*')

pins=()
plain=()
for p in orca-plugin-toolkit orca-plugin-toolkit-build; do
  found=(); while IFS= read -r e; do found+=("$e"); done < <(entries "$p")
  [ "${#found[@]}" -le 1 ] || { echo "::error::Cargo.lock has ${#found[@]} entries for $p (${found[*]}); expected one"; exit 1; }
  [ -n "${found[0]:-}" ] || { echo "$p: not in Cargo.lock; skipping"; continue; }
  src=${found[0]#* }
  case "$src" in
    -) echo "$p: workspace member or path dependency; skipping" ;;
    sparse+*)
      v=$(INDEX_URL=$src /bin/bash "$here/../crate-latest/latest.sh" "$p") || { echo "::error::index lookup for $p failed ($src)"; exit 1; }
      [ -n "$v" ] || { echo "::error::no published (non-yanked) version of $p in $src"; exit 1; }
      n=$(pin "$p" "$v")
      [ "$n" -gt 0 ] || { echo "::error::no manifest requirement for $p was rewritten to =$v"; exit 1; }
      pins+=("$p@$v")
      ;;
    *) echo "$p: $src is not a sparse index; plain cargo update"; plain+=("$p") ;;
  esac
done
for pv in ${pins[@]+"${pins[@]}"}; do
  retry cargo update -p "${pv%@*}" --precise "${pv#*@}"
done
for p in ${plain[@]+"${plain[@]}"}; do
  retry cargo update -p "$p"
done

versions=()
for p in orca-plugin-toolkit orca-plugin-toolkit-build; do
  e=$(entries "$p")
  case "$e" in ""|*" -") continue ;; esac
  v=${e%% *}
  echo "$p $v"
  versions+=("$p@$v")
done
out=$(IFS=,; echo "${versions[*]-}")
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "versions=$out" >> "$GITHUB_OUTPUT"
fi
exit 0
