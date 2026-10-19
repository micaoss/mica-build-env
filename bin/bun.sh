#!/usr/bin/env bash
# Put the bun of this repository's `source bun <arch>` rows of locks/upstream.lock at <dir>/bun,
# verified by sha256, and print its path: the bun bin/mica-tools runs on (MICA_BUN). This
# repository has no locks/mica-build-env.lock to take the base image from, so its CI and a
# host without that bun take it from its own pin (mica-build-tools:docs/design.md 2.2).
# locks/upstream.lock is read here with awk because this runs before the tool can.
#
#   MICA_BUN="$(bash bin/bun.sh <dir>)"
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 1 ] || { echo "usage: bash bin/bun.sh <dir>" >&2; exit 2; }
mkdir -p "$1"
DIR="$(cd "$1" && pwd)"
case "$(uname -m)" in x86_64) arch=amd64 ;; aarch64) arch=arm64 ;; *) echo "error: no bun row for $(uname -m)" >&2; exit 1 ;; esac
row="$(awk -F'\t' -v a="${arch}" '$1 == "source" && $2 == "bun" && $3 == a { print $5 "\t" $6 }' "${HERE}/locks/upstream.lock")"
[ -n "${row}" ] && [ "$(printf '%s\n' "${row}" | wc -l)" -eq 1 ] || { echo "error: locks/upstream.lock has no one source bun ${arch} row" >&2; exit 1; }
sha="${row%%$'\t'*}" url="${row#*$'\t'}"
if [ ! -x "${DIR}/bun" ]; then
    tmp="$(mktemp -d)"
    trap 'rm -rf "${tmp}"' EXIT
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --max-time 600 -o "${tmp}/bun.zip" "${url}"
    [ "$(sha256sum "${tmp}/bun.zip" | cut -d' ' -f1)" = "${sha}" ] || { echo "error: ${url} does not hash to ${sha}" >&2; exit 1; }
    unzip -q -o "${tmp}/bun.zip" -d "${tmp}"
    install -m 0755 "${tmp}/$(basename "${url}" .zip)/bun" "${DIR}/bun"
fi
echo "${DIR}/bun"
