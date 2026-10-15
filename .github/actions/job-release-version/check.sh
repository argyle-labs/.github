#!/usr/bin/env bash
# Fails when EXPECTED (optional, leading v allowed) differs from COMPUTED.
set -euo pipefail
[ -z "${EXPECTED:-}" ] && exit 0
if [ "${EXPECTED#v}" != "${COMPUTED#v}" ]; then
  echo "::error::expected-version $EXPECTED != computed $COMPUTED"
  exit 1
fi
echo "→ expected-version $EXPECTED matches computed $COMPUTED"
