#!/usr/bin/env bash
set -euo pipefail
e=$(printf '%s' "${EXPECTED:-}" | tr -d '[:space:]')
c=$(printf '%s' "${COMPUTED:-}" | tr -d '[:space:]')
[ -z "$e" ] && exit 0
if [ "${e#[vV]}" != "${c#[vV]}" ]; then
  echo "::error::expected-version $EXPECTED != computed $COMPUTED"
  exit 1
fi
echo "→ expected-version $EXPECTED matches computed $COMPUTED"
