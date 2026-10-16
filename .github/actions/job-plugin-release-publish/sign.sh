#!/usr/bin/env bash
set -euo pipefail
set +x
[ -n "$PLUGIN_SIGNING_KEY" ] || { echo "::error::secrets.PLUGIN_SIGNING_KEY missing; refusing unsigned plugin release"; exit 1; }
tool=$(mktemp -d -p "$RUNNER_TEMP")
tarball="$tool/minisign.tar.gz"
curl -fsSL --retry 5 --retry-connrefused -o "$tarball" \
  "https://github.com/jedisct1/minisign/releases/download/${MINISIGN_VERSION}/minisign-${MINISIGN_VERSION}-linux.tar.gz"
echo "${MINISIGN_SHA256}  $tarball" | sha256sum -c -
tar -xzf "$tarball" -C "$tool"
minisign="$tool/minisign-linux/$(uname -m)/minisign"
key=$(mktemp -p "$RUNNER_TEMP")
trap 'rm -f "$key"' EXIT
chmod 600 "$key"
printf '%s\n' "$PLUGIN_SIGNING_KEY" > "$key"
shopt -s nullglob
for f in dist/*; do
  case "$f" in *.sha256|*.minisig) continue ;; esac
  name=$(basename "$f")
  plugin=${name%-"${TAG}"-*}
  sha=$(sha256sum "$f" | cut -d' ' -f1)
  "$minisign" -S -s "$key" -m "$f" -x "$f.minisig" \
    -t "plugin=${plugin} version=${VERSION} sha256=${sha}" </dev/null
  "$minisign" -V -q -P "$PLUGIN_SIGNING_PUBKEY" -m "$f" -x "$f.minisig" \
    || { echo "::error::$name signature does not verify against the published key"; exit 1; }
  echo "signed $name"
done
for f in dist/*; do
  case "$f" in *.sha256|*.minisig) ;; *) [ -f "$f.minisig" ] || { echo "::error::missing signature for $f"; exit 1; } ;; esac
done
