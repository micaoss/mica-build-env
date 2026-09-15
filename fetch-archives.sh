#!/usr/bin/env bash
# Fill a directory with the sha256-pinned toolchain archives one architecture's
# images fetch (the source rows of locks/upstream.lock for <ARCH>, and the
# rust-std row of the other architecture), each verified against its sha256, and remove every other
# file. build.sh hands the directory to the image builds as the mica-fetch-seed
# context; an image still verifies each archive it takes from it.
#
#   bash fetch-archives.sh <amd64|arm64> <dir>
#
# A cache of the directory only saves the downloads: an image never uses a file
# that does not hash to its pin, and without the directory it downloads them.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ "$#" -eq 2 ] || { echo "usage: bash fetch-archives.sh <amd64|arm64> <dir>" >&2; exit 1; }
ARCH="$1"
DIR="$2"
case "${ARCH}" in amd64) UARCH=AMD64 UOTHER=ARM64 ;; arm64) UARCH=ARM64 UOTHER=AMD64 ;; *) echo "error: '${ARCH}' is not amd64 or arm64" >&2; exit 1 ;; esac
for t in curl sha256sum; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required and not on PATH" >&2; exit 1; }
done

# shellcheck source=pins.sh
. "${HERE}/pins.sh"
pins_load || exit 1
STRIPPED="${PINS}"
# An architecture's own std ships inside its toolchain archive, so only the other one's std is fetched.
mapfile -t URL_KEYS < <(printf '%s\n' "${STRIPPED}" | sed -n "/_STD_URL_${UARCH}=/d; s/^\([A-Z0-9_]*_URL_${UARCH}\)=.*/\1/p; s/^\([A-Z0-9_]*_STD_URL_${UOTHER}\)=.*/\1/p")
[ "${#URL_KEYS[@]}" -gt 0 ] || { echo "error: locks/upstream.lock names no archive for ${ARCH}" >&2; exit 1; }

mkdir -p "${DIR}"
declare -A WANT=()
for uk in "${URL_KEYS[@]}"; do
    sk="${uk/_URL_/_SHA256_}"
    url="${!uk}"
    sha="${!sk-}"
    [[ "${sha}" =~ ^[0-9a-f]{64}$ ]] || { echo "error: ${sk} is '${sha}', not a sha256 pin, so ${url} cannot be verified" >&2; exit 1; }
    file="$(basename "${url}")"
    WANT["${file}"]=1
    if [ -f "${DIR}/${file}" ] && [ "$(sha256sum "${DIR}/${file}" | cut -d' ' -f1)" = "${sha}" ]; then
        echo "fetch-archives: ${file} is present and matches ${sk}"
        continue
    fi
    echo "fetch-archives: fetching ${url}"
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "${DIR}/${file}.part" "${url}"
    got="$(sha256sum "${DIR}/${file}.part" | cut -d' ' -f1)"
    [ "${got}" = "${sha}" ] || {
        rm -f "${DIR}/${file}.part"
        echo "error: ${url} hashes to ${got}, but locks/upstream.lock records ${sha} (${sk})" >&2
        exit 1
    }
    mv "${DIR}/${file}.part" "${DIR}/${file}"
done

# Nothing but the pinned archives, so the cache does not carry old ones.
for f in "${DIR}"/* "${DIR}"/.[!.]*; do
    [ -e "${f}" ] || continue
    [ -n "${WANT[$(basename "${f}")]-}" ] || { rm -rf "${f}"; echo "fetch-archives: removed $(basename "${f}")"; }
done
