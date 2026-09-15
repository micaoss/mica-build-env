#!/usr/bin/env bash
# Mirror the upstream images of locks/upstream.lock into this repository's
# package, each whole index copied by digest, and write their mica-lock v1 image rows.
#
#   bash publish-mirrors.sh --publish          copy every image not mirrored yet, then read every mirror back
#   bash publish-mirrors.sh --rows <file>      read every mirror back with no credential and write its rows
#
# Publishing is CI's: the mirror job of .github/workflows/release.yml (`docker
# login ghcr.io` with packages: write). The image rows <name> of
# locks/upstream.lock (one per platform the release guarantees, each naming the
# upstream reference by index digest) mirror to <package>:upstream.<name>.<digest12>;
# a copy of the whole index keeps the upstream digest and every platform. A
# mirror tag that holds another digest is refused, never re-pointed. Its rows in
# mica-build-env.lock are `image upstream.<name> <platform> <mirror>@<index digest>`
# (mica:docs/design/release-lock.md, 2.1).
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCK="${HERE}/locks/upstream.lock"
REPOSITORY="${MICA_IMAGES_REPOSITORY:-ghcr.io/micaoss/mica-build-env}"

USAGE="usage: bash publish-mirrors.sh --publish | --rows <file>"
case "${1-}" in
--publish) [ "$#" -eq 1 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=publish ;;
--rows) [ "$#" -eq 2 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=rows; OUT="$2" ;;
*) echo "${USAGE}" >&2; exit 1 ;;
esac
for t in docker jq sha256sum; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required and not on PATH" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/anon"

# raw <ref> <file> [anon]: the manifest bytes of <ref> into <file>, byte for byte
# (a trailing newline is part of the digest); prints their digest.
raw() {
    if [ "${3-}" = anon ]; then
        DOCKER_CONFIG="${WORK}/anon" docker buildx imagetools inspect --raw "$1" >"$2" 2>/dev/null || return 1
    else
        docker buildx imagetools inspect --raw "$1" >"$2" 2>/dev/null || return 1
    fi
    [ -s "$2" ] || return 1
    printf 'sha256:%s\n' "$(sha256sum "$2" | cut -d' ' -f1)"
}

# The image rows, checked before anything is read or written: the file rules,
# then one reference per name, and that name is the reference's <path>.<tag>.
check="$(bash "${HERE}/check-lock.sh" upstream "${LOCK}" 2>&1)" || { echo "error: locks/upstream.lock is ${check}" >&2; exit 1; }
SOURCES=() NAMES=() TAGS=() DIGESTS=() PLATFORMS=()
while IFS=$'\t' read -r kind name platform src; do
    [ "${kind}" = image ] || continue
    if [ "${#NAMES[@]}" -gt 0 ] && [ "${NAMES[-1]}" = "${name}" ]; then
        [ "${SOURCES[-1]}" = "${src}" ] || { echo "error: locks/upstream.lock names ${name} as ${SOURCES[-1]} and ${src}; one image is one upstream index" >&2; exit 1; }
        PLATFORMS[-1]="${PLATFORMS[-1]},${platform}"
        continue
    fi
    [[ "${src}" =~ ^([a-z0-9.-]+)/([a-z0-9._/-]+):([A-Za-z0-9._-]+)@sha256:[0-9a-f]{64}$ ]] || {
        echo "error: locks/upstream.lock names ${name} as ${src}, which has no tag; the row name is <path>.<tag>" >&2
        exit 1
    }
    path="${BASH_REMATCH[2]}"
    [ "${BASH_REMATCH[1]}" != docker.io ] || path="${path#library/}"
    [ "${name}" = "${path//\//-}.${BASH_REMATCH[3]}" ] || {
        echo "error: locks/upstream.lock names ${src} '${name}', not '${path//\//-}.${BASH_REMATCH[3]}' (<path>.<tag>, / written -)" >&2
        exit 1
    }
    digest="${src##*@}"
    SOURCES+=("${src}") NAMES+=("${name}") TAGS+=("upstream.${name}.${digest:7:12}") DIGESTS+=("${digest}") PLATFORMS+=("${platform}")
done <"${LOCK}"
[ "${#SOURCES[@]}" -gt 0 ] || { echo "error: locks/upstream.lock pins no image" >&2; exit 1; }

# verify <i>: the mirror reads with no credential at its upstream digest, and
# so does the manifest of every platform it guarantees.
verify() {
    local i="$1" ref="${REPOSITORY}:${TAGS[$1]}" got p pd
    got="$(raw "${ref}" "${WORK}/index" anon)" || {
        package="${REPOSITORY#*/}"
        echo "error: ${ref} does not read anonymously. If the package is private, set it public once at https://github.com/orgs/${package%%/*}/packages/container/package/${package#*/}" >&2
        return 1
    }
    [ "${got}" = "${DIGESTS[$i]}" ] || { echo "error: ${ref} reads as ${got}, not the upstream ${DIGESTS[$i]}" >&2; return 1; }
    IFS=',' read -r -a plats <<<"${PLATFORMS[$i]}"
    for p in "${plats[@]}"; do
        pd="$(jq -r --arg a "${p}" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a) | .digest] | first // empty' "${WORK}/index")"
        [ -n "${pd}" ] || { echo "error: ${ref} lists no linux/${p} manifest, which the release guarantees" >&2; return 1; }
        [ "$(raw "${REPOSITORY}@${pd}" "${WORK}/platform" anon || true)" = "${pd}" ] ||
            { echo "error: the linux/${p} manifest ${pd} of ${ref} does not read anonymously at its digest" >&2; return 1; }
    done
}

case "${MODE}" in
publish)
    for i in "${!SOURCES[@]}"; do
        ref="${REPOSITORY}:${TAGS[$i]}"
        if held="$(raw "${ref}" "${WORK}/held")"; then
            [ "${held}" = "${DIGESTS[$i]}" ] || { echo "error: ${ref} already holds ${held}, not ${DIGESTS[$i]}; a mirror tag is never re-pointed" >&2; exit 1; }
            echo "publish-mirrors: ${ref} is mirrored" >&2
        else
            docker buildx imagetools create -t "${ref}" "${SOURCES[$i]}" >&2
            echo "publish-mirrors: copied ${SOURCES[$i]} to ${ref}" >&2
        fi
        verify "${i}"
    done
    echo "publish-mirrors: ${#SOURCES[@]} mirrors read back anonymously" >&2
    ;;
rows)
    : >"${OUT}"
    for i in "${!SOURCES[@]}"; do
        verify "${i}"
        IFS=',' read -r -a plats <<<"${PLATFORMS[$i]}"
        for p in "${plats[@]}"; do
            printf 'image\tupstream.%s\t%s\t%s:%s@%s\n' "${NAMES[$i]}" "${p}" "${REPOSITORY}" "${TAGS[$i]}" "${DIGESTS[$i]}" >>"${OUT}"
        done
    done
    ;;
esac
