#!/usr/bin/env bash
# Move the pins of locks/upstream.lock to what upstream publishes today, and
# locks/mica-build-tools.pin to that tool's latest release. Every changed row is
# measured here: an archive is downloaded and hashed, an image tag is resolved to
# its index digest, a snapshot suite's InRelease is hashed at the new instant.
#
#   bash update-pins.sh
#
# Run monthly by .github/workflows/update.yml, which commits the result to main
# and releases it after the gates and an amd64 build of every image pass.
#
# - go, rust and rust-std: the latest stable release; the gate tools
#   (cargo-nextest, cargo-deny, cargo-shear, typos): their latest release. The
#   new URL is the pinned URL with the version replaced.
# - bun is not moved: mica-build-tools and the TypeScript repositories declare
#   the same bun in packageManager, so it moves by hand, with them.
# - image rows: each name's tag resolved again to its index digest.
# - debian-<suite> and ubuntu-<suite> rows: today's instant, 00:00:00 UTC.
set -euo pipefail
export LC_ALL=C

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${HERE}/locks/upstream.lock"
for t in curl jq sha256sum docker gh; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required and not on PATH" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 --max-time 1800 "$@"; }

# field <kind> <name> <arch|platform> <column>: one column of a row.
field() { awk -F'\t' -v k="$1" -v n="$2" -v a="$3" -v c="$4" '$1 == k && ($1 == "image" ? $3 : $2) == n && ($1 == "image" ? $4 : $3) == a { print $c }' "${LOCK}"; }

# set_source <name> <version>: every arch row of <name> at <version>, measured.
set_source() {
    local name="$1" version="$2" arch old url sha
    for arch in $(awk -F'\t' -v n="${name}" '$1 == "source" && $2 == n { print $3 }' "${LOCK}"); do
        old="$(field source "${name}" "${arch}" 4)"
        [ "${old}" != "${version}" ] || continue
        url="$(field source "${name}" "${arch}" 6)"
        url="${url//${old}/${version}}"
        fetch -o "${WORK}/archive" "${url}"
        sha="$(sha256sum "${WORK}/archive" | cut -d' ' -f1)"
        awk -F'\t' -v OFS='\t' -v n="${name}" -v a="${arch}" -v v="${version}" -v s="${sha}" -v u="${url}" \
            '$1 == "source" && $2 == n && $3 == a { $4 = v; $5 = s; $6 = u } { print }' "${LOCK}" >"${WORK}/lock"
        cp "${WORK}/lock" "${LOCK}"
        echo "${name} ${arch}: ${old} -> ${version}"
    done
}

# github_latest <owner/repo> <tag prefix>: the version of the latest release whose tag starts with the prefix.
github_latest() {
    local tags tag
    tags="$(gh api "repos/$1/releases?per_page=50" --jq '.[] | select(.draft == false and .prerelease == false) | .tag_name')"
    for tag in ${tags}; do
        case "${tag}" in "$2"*) echo "${tag#"$2"}"; return ;; esac
    done
    echo "error: $1 has no release tagged $2<version>" >&2
    return 1
}

channel="$(fetch https://static.rust-lang.org/dist/channel-rust-stable.toml)"
rust="$(printf '%s\n' "${channel}" | awk '/^\[/ { f = ($0 == "[pkg.rust]") } f && /^version = / { print $3 }' | tr -d '"')"
[[ "${rust}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: no stable rust version in channel-rust-stable.toml ('${rust}')" >&2; exit 1; }
set_source rust "${rust}"
set_source rust-std "${rust}"

godl="$(fetch 'https://go.dev/dl/?mode=json')"
go="$(printf '%s\n' "${godl}" | jq -r '[.[] | select(.stable)][0].version')"
[[ "${go}" =~ ^go[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || { echo "error: no stable go version from go.dev ('${go}')" >&2; exit 1; }
set_source go "${go#go}"

set_source cargo-nextest "$(github_latest nextest-rs/nextest cargo-nextest-)"
set_source cargo-deny "$(github_latest EmbarkStudios/cargo-deny '')"
set_source cargo-shear "$(github_latest Boshen/cargo-shear v)"
set_source typos "$(github_latest crate-ci/typos v)"

# Image rows: the tag's index digest today.
for name in $(awk -F'\t' '$1 == "image" { print $3 }' "${LOCK}" | sort -u); do
    ref="$(awk -F'\t' -v n="${name}" '$1 == "image" && $3 == n { print $5 }' "${LOCK}" | sort -u)"
    [ "$(printf '%s\n' "${ref}" | wc -l)" = 1 ] || { echo "error: the image rows of ${name} name more than one reference" >&2; exit 1; }
    out="$(DOCKER_CONFIG="${WORK}" docker buildx imagetools inspect "${ref%@*}")"
    digest="$(printf '%s\n' "${out}" | awk '/^Digest:/ { print $2 }')"
    digest="${digest%%$'\n'*}"
    [[ "${digest}" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "error: ${ref%@*} resolved to no index digest" >&2; exit 1; }
    [ "${ref##*@}" != "${digest}" ] || continue
    awk -F'\t' -v OFS='\t' -v n="${name}" -v r="${ref%@*}@${digest}" '$1 == "image" && $3 == n { $5 = r } { print }' "${LOCK}" >"${WORK}/lock"
    cp "${WORK}/lock" "${LOCK}"
    echo "${name}: ${ref##*@} -> ${digest}"
done

# Snapshot rows: today's instant, every suite's InRelease hashed there.
instant="$(date -u +%Y%m%dT000000Z)"
for name in $(awk -F'\t' '$1 == "source" && $3 == "all" { print $2 }' "${LOCK}"); do
    old="$(field source "${name}" all 4)"
    [ "${old}" != "${instant}" ] || continue
    url="$(field source "${name}" all 6)"
    url="${url//${old}/${instant}}"
    fetch -o "${WORK}/InRelease" "${url}"
    sha="$(sha256sum "${WORK}/InRelease" | cut -d' ' -f1)"
    awk -F'\t' -v OFS='\t' -v n="${name}" -v v="${instant}" -v s="${sha}" -v u="${url}" \
        '$1 == "source" && $2 == n && $3 == "all" { $4 = v; $5 = s; $6 = u } { print }' "${LOCK}" >"${WORK}/lock"
    cp "${WORK}/lock" "${LOCK}"
    echo "${name}: ${old} -> ${instant}"
done

"${HERE}/bin/mica-tools" upstream check >/dev/null
"${HERE}/bin/mica-tools" locks update
