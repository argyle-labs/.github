# shellcheck shell=bash
# Sourced: sets up a curl config holding the S3 credentials (mode 600, never
# argv) and defines s3, a SigV4-signed curl. Garage rejects requests without
# x-amz-content-sha256, which curl only adds itself from 8.x.
CURL_CFG=$(umask 077 && mktemp "${RUNNER_TEMP:-/tmp}/ci-pass-curl.XXXXXX")
trap 'rm -f "$CURL_CFG"' EXIT
esc() { local v=${1//\\/\\\\}; printf '%s' "${v//\"/\\\"}"; }
printf 'user = "%s:%s"\n' "$(esc "$S3_ACCESS_KEY")" "$(esc "$S3_SECRET_KEY")" > "$CURL_CFG"
s3() {
  curl -sS --max-time 20 --aws-sigv4 "aws:amz:$S3_REGION:s3" --config "$CURL_CFG" \
    -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" "$@"
}
export CURL_CFG S3_REGION
export -f s3
