#!/usr/bin/env bash
# Fetch the sha256-pinned bun and unpack it to /opt/bun/bin/bun.
# mica-build-side: container -- runs in the fetch stage of base/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-base
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

uarch="$(target_uarch)"
url_key="BASE_BUN_URL_${uarch}"
sha_key="BASE_BUN_SHA256_${uarch}"
url="${!url_key-}"
fetch_verified "${sha_key}" "${url}" "${!sha_key-}"

mkdir -p /tmp/unpack /opt/bun/bin
unzip -q -o "${FETCHED}" -d /tmp/unpack
dir="/tmp/unpack/$(basename "${url}" .zip)"
[ -f "${dir}/bun" ] || {
    echo "${MICA_IMAGE}: error: ${url} unpacked without ${dir}/bun; the archive layout is not what this script expects" >&2
    exit 1
}
install -m 0755 "${dir}/bun" /opt/bun/bin/bun
rm -rf /tmp/unpack
