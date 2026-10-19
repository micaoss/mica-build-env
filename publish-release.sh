#!/usr/bin/env bash
# Write mica-build-env.lock, the mica-lock v1 lock of a published release
# YYYYMMDD-HHMM (UTC) (mica-build-tools:docs/spec/release-lock.md) naming the build-env
# images its tag's inputs name and the upstream images of locks/upstream.lock,
# and attach it with `mica-tools release attach`: SHA256SUMS listing only it,
# both read back anonymously, and the notes' "Images: unchanged|changed" against
# the previous release carrying the lock (RULES.md section 1).
#
#   bash publish-release.sh <YYYYMMDD-HHMM>
#
# Run by the assets job of .github/workflows/release.yml (on release: published,
# GH_TOKEN with contents: write) after its images job succeeded. The release was
# cut with `gh release create <tag> --target <commit>`. Nothing is written unless
# `mica-tools release check` passes (the tag is a UTC time naming the checked-out
# commit, on main, from a clean tree) and every image is published and reads
# with no credential; `release attach` refuses a release that is not published,
# a later time-tagged release, and an asset that would be replaced. A change in
# the images is a breaking update.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=mica-build-env

for t in docker curl; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required and not on PATH" >&2; exit 1; }
done

[ "$#" -eq 1 ] || { echo "usage: bash publish-release.sh <YYYYMMDD-HHMM>" >&2; exit 1; }
TAG="$1"
# Build rules, section 1: a UTC time, not in the future, naming this commit, on main, from a clean tree.
HEAD="$("${HERE}/bin/mica-tools" release check "${TAG}")" || {
    echo "error: ${TAG} is not a release this checkout can publish; nothing was attached" >&2
    exit 1
}
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/assets"

bash "${HERE}/from.sh" --check

LOCK="${NAME}.lock"

# The rows: the images this commit's inputs name, each read back with no
# credential at its digest, and the upstream image rows of locks/upstream.lock
# as they are (this repository does not republish them).
bash "${HERE}/publish-images.sh" --resolve "${TAG}" --out "${WORK}/images.rows" || {
    echo "error: the build-env images of ${HEAD} are not all published; the images job publishes them for ${TAG}; nothing was attached" >&2
    exit 1
}
check="$("${HERE}/bin/mica-tools" upstream check)" || {
    echo "error: locks/upstream.lock at ${HEAD} is ${check}; nothing was attached" >&2
    exit 1
}
"${HERE}/bin/mica-tools" upstream rows image >"${WORK}/upstream.rows"
[ -s "${WORK}/upstream.rows" ] || {
    echo "error: locks/upstream.lock at ${HEAD} names no upstream image; nothing was attached" >&2
    exit 1
}
# mica-lock v1: the release row, then the image rows sorted by source, name and platform as bytes.
{
    echo "# mica-lock v1"
    printf 'release\t%s\t%s\t%s\n' "${NAME}" "${TAG}" "${HEAD}"
    cat "${WORK}/images.rows" "${WORK}/upstream.rows" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4
} >"${WORK}/assets/${LOCK}"
check="$("${HERE}/bin/mica-tools" lock check "${WORK}/assets/${LOCK}")" || {
    echo "error: the lock written for ${TAG} is ${check}; nothing was attached" >&2
    exit 1
}

"${HERE}/bin/mica-tools" release attach "${TAG}" "${WORK}/assets/${LOCK}" --notes "${NAME} ${HEAD}: ${LOCK} (mica-lock v1) names its build-env images and the upstream images they build on. Verify with SHA256SUMS. A release whose images changed is a breaking update: every repository must update to it." || {
    echo "error: the assets of ${TAG} were not attached" >&2
    exit 1
}
echo "publish-release: ${TAG} at ${HEAD} carries its assets and reads anonymously."
cat "${WORK}/assets/${LOCK}"
