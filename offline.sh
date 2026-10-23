#!/usr/bin/env bash
# Build every build-env image locally for the host architecture and write the
# offline release of this checkout (mica-build-tools:docs/spec/release-lock.md
# sections 6 and 7) to _out/offline/:
#
#   mica-build-env.lock  release row `offline` and HEAD; per image an `index` and
#                        a host-architecture row, `local/mica-build-env:<image>.offline@sha256:`
#                        and `local/mica-build-env@sha256:`; the upstream image rows
#                        of locks/upstream.lock unchanged
#   oci/                 one OCI image layout holding every image: its index.json
#                        names each image index `<image>.offline`, and for `docker load`
#                        `docker.io/local/mica-build-env:<image>.offline` (the name docker
#                        resolves `local/mica-build-env:<image>.offline` to)
#   SHA256SUMS           over the lock (what `mica-tools local-lock` verifies)
#
#   bash offline.sh      (make offline)
#
# The images are built by build.sh from the pinned inputs, natively: an image
# for another architecture is not built here (no emulation), so the lock names
# the host architecture only. A consumer reads it through `mica-tools local-lock
# mica-build-env <this checkout>`. Refused under CI and on a dirty tree.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAME=mica-build-env
die() { echo "offline.sh: error: $*" >&2; exit 1; }
cd "${HERE}"

[ -z "${CI-}" ] && [ -z "${GITHUB_ACTIONS-}" ] || die "an offline release is never built under CI; CI publishes the real releases"
for t in docker jq git sha256sum tar; do
    command -v "${t}" >/dev/null 2>&1 || die "${t} is required and not on PATH"
done
[ -z "$(git status --porcelain)" ] || die "the checkout has uncommitted changes; an offline release names a clean commit"
COMMIT="$(git rev-parse HEAD)"
case "$(uname -m)" in
x86_64) ARCH=amd64 ;;
aarch64 | arm64) ARCH=arm64 ;;
*) die "$(uname -m) is not a host build-env images are built on" ;;
esac
IMAGES=(base c go rust bsp)

MICA_BUILD_PLATFORM="linux/${ARCH}" bash "${HERE}/build.sh" "${IMAGES[@]}"
[ -z "$(git status --porcelain)" ] || die "the checkout changed during the build; the images name no commit"
[ "$(git rev-parse HEAD)" = "${COMMIT}" ] || die "HEAD moved during the build"

OUT="${HERE}/_out/offline"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
rm -rf "${OUT}"
mkdir -p "${OUT}/oci/blobs/sha256"
printf '{"imageLayoutVersion":"1.0.0"}' >"${OUT}/oci/oci-layout"

# Each image as docker saves it: the index docker names by the tag, its platform
# manifest and attestation, their configs and layers, into one layout. The save
# may also carry referrers of the image; they are left out.
copy_blob() {
    local digest="$1" from="${WORK}/save/blobs/sha256/${1#sha256:}"
    [ -f "${from}" ] || die "the saved layout of ${tag} lacks ${digest}"
    [ "sha256:$(sha256sum "${from}" | cut -d' ' -f1)" = "${digest}" ] || die "the saved blob ${digest} of ${tag} does not hash to its name"
    [ -e "${OUT}/oci/blobs/sha256/${digest#sha256:}" ] || cp "${from}" "${OUT}/oci/blobs/sha256/"
}
entries=() rows=()
for name in "${IMAGES[@]}"; do
    tag="localhost/mica-build-${name}:${ARCH}"
    rm -rf "${WORK}/save"
    mkdir -p "${WORK}/save"
    docker image save "${tag}" | tar -x -C "${WORK}/save"
    [ -f "${WORK}/save/oci-layout" ] || die "\`docker image save ${tag}\` wrote no OCI layout; the daemon needs the containerd image store"
    top="$(jq -c --arg t "${tag}" '[.manifests[] | select(.annotations["io.containerd.image.name"] == $t)] | if length == 1 then .[0] else error("not one image") end' "${WORK}/save/index.json")" ||
        die "the saved layout of ${tag} does not name exactly one image ${tag}"
    index="$(jq -r .digest <<<"${top}")"
    [ "$(jq -r .mediaType <<<"${top}")" = application/vnd.oci.image.index.v1+json ] ||
        die "${tag} is saved as $(jq -r .mediaType <<<"${top}"), not an image index"
    copy_blob "${index}"
    platform="$(jq -r --arg a "${ARCH}" '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest] | if length == 1 then .[0] else "" end' \
        "${WORK}/save/blobs/sha256/${index#sha256:}")"
    [ -n "${platform}" ] || die "the index of ${tag} lists no one linux/${ARCH} manifest"
    for manifest in $(jq -r '.manifests[].digest' "${WORK}/save/blobs/sha256/${index#sha256:}"); do
        copy_blob "${manifest}"
        for blob in $(jq -r '.config.digest, .layers[].digest' "${WORK}/save/blobs/sha256/${manifest#sha256:}"); do
            copy_blob "${blob}"
        done
    done
    ref="local/${NAME}:${name}.offline"
    entries+=("$(jq -c --arg ref "docker.io/${ref}" --arg tag "${name}.offline" \
        '{mediaType, digest, size, annotations: {"io.containerd.image.name": $ref, "org.opencontainers.image.ref.name": $tag}}' <<<"${top}")")
    rows+=("$(printf 'image\t%s\t%s\tindex\t%s@%s' "${NAME}" "${name}" "${ref}" "${index}")")
    rows+=("$(printf 'image\t%s\t%s\t%s\tlocal/%s@%s' "${NAME}" "${name}" "${ARCH}" "${NAME}" "${platform}")")
    echo "offline.sh: ${ref}@${index} (linux/${ARCH} ${platform})"
done
printf '%s\n' "${entries[@]}" | jq -sc '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: .}' >"${OUT}/oci/index.json"

# mica-lock v1: the release row, then the image rows sorted by source, name and platform as bytes.
"${HERE}/bin/mica-tools" upstream rows image >"${WORK}/upstream.rows"
[ -s "${WORK}/upstream.rows" ] || die "locks/upstream.lock names no upstream image"
{
    echo "# mica-lock v1"
    printf 'release\t%s\toffline\t%s\n' "${NAME}" "${COMMIT}"
    { printf '%s\n' "${rows[@]}"; cat "${WORK}/upstream.rows"; } | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4
} >"${OUT}/${NAME}.lock"
check="$("${HERE}/bin/mica-tools" lock check "${OUT}/${NAME}.lock")" || die "the offline lock is ${check}"
(cd "${OUT}" && sha256sum "${NAME}.lock" >SHA256SUMS)

echo "offline.sh: ${OUT}/${NAME}.lock, ${OUT}/oci ($(find "${OUT}/oci/blobs/sha256" -type f | wc -l) blobs), ${OUT}/SHA256SUMS at ${COMMIT}"
