#!/usr/bin/env bash
set -euo pipefail
fail=0
while IFS= read -r r; do
  r=${r//[[:space:]]/}
  [ -n "$r" ] || continue
  name=${r%%:*}; res=${r#*:}
  echo "  $name = $res"
  case "$res" in success|skipped) ;; *) echo "::error::$name = $res"; fail=1 ;; esac
done <<< "$RESULTS"
exit $fail
