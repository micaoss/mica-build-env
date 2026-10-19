#!/usr/bin/env bash
# Fetch the sha256-pinned Go tarball and unpack it to /opt/go.
# mica-build-side: container -- runs in the fetch stage of go/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-go
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

uarch="$(target_uarch)"
url_key="GO_URL_${uarch}"
sha_key="GO_SHA256_${uarch}"
url="${!url_key-}"
fetch_verified "${sha_key}" "${url}" "${!sha_key-}"

mkdir -p /opt
tar -C /opt -xzf "${FETCHED}"
[ -x /opt/go/bin/go ] || {
    echo "${MICA_IMAGE}: error: ${url} unpacked without an executable /opt/go/bin/go; the tarball layout is not what this script expects" >&2
    exit 1
}
