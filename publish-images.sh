#!/usr/bin/env bash
# Publish the build-env images to GHCR as multi-architecture images and write
# their image rows of mica-build-env.lock (mica-lock v1): index, amd64 and arm64 per image.
#
#   bash publish-images.sh --plan <file>              which images these inputs still need, by tag
#   bash publish-images.sh --build <arch> <plan>      build them natively for <arch> and push <image>.<arch>.build-<commit12>
#   bash publish-images.sh --merge <plan> <release>   merge both architectures into <image>.inputs-<16> and .build-<commit12>,
#                                                     then tag every image <image>.<release>
#   bash publish-images.sh --resolve <release> --out <file>
#                                                     build nothing; write the image rows naming <image>.<release>,
#                                                     or refuse if an image is not published under it
#
# Publishing is CI's: .github/workflows/release.yml runs --plan, then --build on
# an amd64 and an arm64 runner, then --merge, when a release is published
# (`docker login ghcr.io` with packages: write). base builds on
# debian:trixie-slim (locks/upstream.lock), c on base, go and rust on c. An image's inputs are its
# keys of locks/upstream.lock and params.env (pins.sh), its parent's inputs tag (or the upstream reference for base), its
# Dockerfile, dockerignore and the scripts that allow-list admits, and lib/; the
# image is this repository's package tagged <image>.inputs-<sha256 prefix> of
# them. An image is built when that tag is not published or its parent is built
# in the same plan. Each release then tags every image <image>.<release> (the
# same digest when the image did not change), and its lock names that tag; a
# published tag is never re-pointed. Every row written names a digest that reads
# with no credential.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="${MICA_IMAGES_REPOSITORY:-ghcr.io/micaoss/mica-build-env}"
# shellcheck source=pins.sh
. "${HERE}/pins.sh"
ARCHES=(amd64 arm64)

# <image>|<input key prefixes>|<parent: an upstream:<name> image or an earlier image>
IMAGES=(
    "base|BASE_,DEB_,OPENSSL_|upstream:debian:trixie-slim"
    "c|C_|base"
    "go|GO_|c"
    "rust|RUST_,RUSTCHECK_|c"
)

USAGE="usage: bash publish-images.sh --plan <file> | --build <amd64|arm64> <plan> | --merge <plan> <release> | --resolve <release> --out <file>"
MODE=""
case "${1-}" in
--plan) [ "$#" -eq 2 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=plan; PLAN="$2" ;;
--build) [ "$#" -eq 3 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=build; ARCH="$2"; PLAN="$3" ;;
--merge) [ "$#" -eq 3 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=merge; PLAN="$2"; RELEASE="$3" ;;
--resolve) [ "$#" -eq 4 ] && [ "$3" = --out ] || { echo "${USAGE}" >&2; exit 1; }; MODE=resolve; RELEASE="$2"; OUT="$4" ;;
*) echo "${USAGE}" >&2; exit 1 ;;
esac
[[ "${RELEASE-00000000-0000}" =~ ^[0-9]{8}-[0-9]{4}$ ]] || { echo "error: the release '${RELEASE}' is not YYYYMMDD-HHMM" >&2; exit 1; }
command -v docker >/dev/null 2>&1 || { echo "error: docker is required and not on PATH" >&2; exit 1; }

pins_load || exit 1
STRIPPED="${PINS}"

# inputs_tag <image> <prefixes> <parent inputs tag or base image pin>
inputs_tag() {
    local name="$1" prefixes="$2" parent="$3" p f sha
    local -a pfx files
    IFS=',' read -r -a pfx <<<"${prefixes}"
    mapfile -t files < <(sed -n 's/^!\(.*\)$/\1/p' "${HERE}/${name}/Dockerfile.dockerignore" | grep -vx 'inputs.env')
    sha="$(
        cd "${HERE}"
        for p in "${pfx[@]}"; do
            printf '%s\n' "${STRIPPED}" | sed -n "s/^\(${p}[A-Za-z0-9_]*=.*\)$/\1/p"
        done
        printf 'MICA_BASE_IMAGE=%s\n' "${parent}"
        cat "${name}/Dockerfile" "${name}/Dockerfile.dockerignore"
        for f in "${files[@]}"; do cat "${name}/${f}"; done
        cat lib/*
    )"
    sha="$(printf '%s\n' "${sha}" | sha256sum | cut -d' ' -f1)"
    printf '%s.inputs-%s\n' "${name}" "${sha:0:16}"
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/anon"

# Captured whole before parsing: a pipe into awk would break under pipefail.
index_digest() {
    local out
    out="$(docker buildx imagetools inspect "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${out}" | awk '/^Digest:[[:space:]]/{print $2; exit}'
}
# Public, always: read with an empty docker configuration.
anon_digest() { DOCKER_CONFIG="${WORK}/anon" index_digest "$1"; }

clean_commit() {
    command -v git >/dev/null 2>&1 || { echo "error: git is required and not on PATH" >&2; exit 1; }
    [ -z "$(git -C "${HERE}" status --porcelain)" ] || {
        echo "error: ${HERE} has uncommitted changes; the published tags name a commit, so they are built from a clean one" >&2
        exit 1
    }
    COMMIT="$(git -C "${HERE}" rev-parse HEAD)"
}

# Every image's tag, parents first: TAG[<image>].
declare -A TAG=() PARENT=()
for row in "${IMAGES[@]}"; do
    IFS='|' read -r name prefixes parent <<<"${row}"
    case "${parent}" in
    upstream:*) from="$(upstream_ref "${parent#upstream:}")" || exit 1 ;;
    *) from="${TAG[${parent}]}" ;;
    esac
    [ -n "${from}" ] || { echo "error: ${name}'s parent ${parent} resolved to nothing" >&2; exit 1; }
    TAG["${name}"]="$(inputs_tag "${name}" "${prefixes}" "${from}")"
    PARENT["${name}"]="${parent}"
done

# read_plan <file>: ACTION[<image>] from a plan whose tags are this tree's.
declare -A ACTION=()
read_plan() {
    local name tag action
    [ -s "$1" ] || { echo "error: the plan $1 is missing or empty" >&2; exit 1; }
    while read -r name tag action; do
        [ "${TAG[${name}]-}" = "${tag}" ] || { echo "error: the plan $1 names ${name} as ${tag}, but these inputs are ${TAG[${name}]-nothing}" >&2; exit 1; }
        case "${action}" in build | published) ACTION["${name}"]="${action}" ;; *) echo "error: the plan $1 gives ${name} the action '${action}'" >&2; exit 1 ;; esac
    done <"$1"
    for row in "${IMAGES[@]}"; do
        [ -n "${ACTION[${row%%|*}]-}" ] || { echo "error: the plan $1 does not name ${row%%|*}" >&2; exit 1; }
    done
}

case "${MODE}" in
plan)
    declare -A BUILD=()
    : >"${PLAN}"
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        parent="${PARENT[${name}]}"
        if [ -n "${BUILD[${parent}]-}" ]; then
            echo "publish-images: ${name} builds because its parent ${parent} does" >&2
            BUILD["${name}"]=1
        elif digest="$(anon_digest "${REPOSITORY}:${TAG[${name}]}")" && [ -n "${digest}" ]; then
            echo "publish-images: ${REPOSITORY}:${TAG[${name}]} is published" >&2
        else
            echo "publish-images: ${REPOSITORY}:${TAG[${name}]} is not published; ${name} builds" >&2
            BUILD["${name}"]=1
        fi
        printf '%s %s %s\n' "${name}" "${TAG[${name}]}" "$([ -n "${BUILD[${name}]-}" ] && echo build || echo published)" >>"${PLAN}"
    done
    ;;

build)
    case "${ARCH}" in amd64 | arm64) ;; *) echo "${USAGE}" >&2; exit 1 ;; esac
    case "$(uname -m)" in x86_64) host=amd64 ;; aarch64 | arm64) host=arm64 ;; *) host="$(uname -m)" ;; esac
    [ "${host}" = "${ARCH}" ] || {
        echo "error: --build ${ARCH} runs on a ${ARCH} host, and this one is ${host}; images are built natively, not emulated" >&2
        exit 1
    }
    read_plan "${PLAN}"
    clean_commit
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        [ "${ACTION[${name}]}" = build ] || continue
        parent="${PARENT[${name}]}"
        case "${parent}:${ACTION[${parent}]-}" in
        upstream:*:* | *:build)
            # The upstream image, or a parent this job has just built into the local store.
            MICA_BUILD_PLATFORM="linux/${ARCH}" bash "${HERE}/build.sh" "${name}" >&2
            ;;
        *)
            from="${REPOSITORY}:${TAG[${parent}]}"
            digest="$(anon_digest "${from}")" && [ -n "${digest}" ] || { echo "error: ${from} (${name}'s parent) does not read anonymously" >&2; exit 1; }
            MICA_BUILD_PLATFORM="linux/${ARCH}" MICA_BUILD_PARENT="${from}@${digest}" bash "${HERE}/build.sh" "${name}" >&2
            ;;
        esac
        src="${REPOSITORY}:${name}.${ARCH}.build-${COMMIT:0:12}"
        docker tag "localhost/mica-build-${name}:${ARCH}" "${src}"
        # A push that reports success is read back; the registry has answered
        # 404 for a tag it just accepted, so a missing tag is pushed again.
        for try in 1 2 3 4 5; do
            docker push -q "${src}" >&2
            index_digest "${src}" >/dev/null && break
            [ "${try}" -lt 5 ] || { echo "error: ${src} was pushed ${try} times and still does not resolve" >&2; exit 1; }
            echo "publish-images: ${src} does not resolve after the push; pushing again" >&2
            sleep $((try * 5))
        done
        echo "publish-images: pushed ${src}" >&2
    done
    ;;

merge)
    read_plan "${PLAN}"
    clean_commit
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        [ "${ACTION[${name}]}" = build ] || continue
        sources=()
        for arch in "${ARCHES[@]}"; do
            src="${REPOSITORY}:${name}.${arch}.build-${COMMIT:0:12}"
            index_digest "${src}" >/dev/null || { echo "error: ${src} is not pushed; the ${arch} build job did not finish ${name}" >&2; exit 1; }
            sources+=("${src}")
        done
        # The plan was made before the builds: a tag published since is not re-pointed,
        # unless this commit's own merge made it (a rerun), which its build tag names.
        if existing="$(index_digest "${REPOSITORY}:${TAG[${name}]}")" && [ -n "${existing}" ]; then
            [ "$(index_digest "${REPOSITORY}:${name}.build-${COMMIT:0:12}" || true)" = "${existing}" ] || {
                echo "error: ${REPOSITORY}:${TAG[${name}]} was published after the plan by another commit; a published tag is never re-pointed" >&2
                exit 1
            }
            echo "publish-images: ${REPOSITORY}:${TAG[${name}]} is this commit's merge; not re-pointed" >&2
        else
            docker buildx imagetools create -t "${REPOSITORY}:${TAG[${name}]}" -t "${REPOSITORY}:${name}.build-${COMMIT:0:12}" "${sources[@]}" >&2
        fi
        digest="$(anon_digest "${REPOSITORY}:${TAG[${name}]}")" && [ -n "${digest}" ] || {
            package="${REPOSITORY#*/}"
            echo "error: ${REPOSITORY}:${TAG[${name}]} was pushed and does not read anonymously. If the package is private, set it public once at https://github.com/orgs/${package%%/*}/packages/container/package/${package#*/} (Package settings, Danger Zone, Change visibility: Public) and rerun" >&2
            exit 1
        }
        echo "publish-images: merged ${REPOSITORY}:${TAG[${name}]}@${digest}" >&2
    done
    # Every image, built now or published before, under this release's tag.
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        digest="$(anon_digest "${REPOSITORY}:${TAG[${name}]}")" && [ -n "${digest}" ] || {
            echo "error: ${REPOSITORY}:${TAG[${name}]} (${name}) does not read anonymously, so it cannot be tagged for ${RELEASE}" >&2
            exit 1
        }
        rel="${REPOSITORY}:${name}.${RELEASE}"
        if existing="$(index_digest "${rel}")" && [ -n "${existing}" ]; then
            [ "${existing}" = "${digest}" ] || { echo "error: ${rel} already holds ${existing}, not ${digest}; a published tag is never re-pointed" >&2; exit 1; }
            echo "publish-images: ${rel} is tagged" >&2
        else
            docker buildx imagetools create -t "${rel}" "${REPOSITORY}:${TAG[${name}]}@${digest}" >&2
        fi
        [ "$(anon_digest "${rel}" || true)" = "${digest}" ] || { echo "error: ${rel} does not read anonymously at ${digest}" >&2; exit 1; }
        echo "publish-images: tagged ${rel}@${digest}" >&2
    done
    ;;

resolve)
    command -v jq >/dev/null 2>&1 || { echo "error: jq is required and not on PATH" >&2; exit 1; }
    : >"${OUT}"
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        ref="${REPOSITORY}:${name}.${RELEASE}"
        # The manifest bytes go to a file untouched: a trailing newline is part of the digest.
        DOCKER_CONFIG="${WORK}/anon" docker buildx imagetools inspect --raw "${ref}" >"${WORK}/index" 2>/dev/null && [ -s "${WORK}/index" ] || {
            echo "error: ${ref} (${name}) is not published or does not read anonymously; the release workflow builds and tags it for ${RELEASE}" >&2
            exit 1
        }
        digest="sha256:$(sha256sum "${WORK}/index" | cut -d' ' -f1)"
        [ "$(anon_digest "${REPOSITORY}:${TAG[${name}]}" || true)" = "${digest}" ] || {
            echo "error: ${ref} is ${digest}, which is not ${REPOSITORY}:${TAG[${name}]}, the image these inputs name" >&2
            exit 1
        }
        printf 'image\tmica-build-env\t%s\tindex\t%s@%s\n' "${name}" "${ref}" "${digest}" >>"${OUT}"
        for arch in "${ARCHES[@]}"; do
            pd="$(jq -r --arg a "${arch}" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a) | .digest] | first // empty' "${WORK}/index")"
            [ -n "${pd}" ] || { echo "error: ${ref}@${digest} lists no linux/${arch} manifest" >&2; exit 1; }
            DOCKER_CONFIG="${WORK}/anon" docker buildx imagetools inspect --raw "${REPOSITORY}@${pd}" >"${WORK}/platform" 2>/dev/null &&
                [ "sha256:$(sha256sum "${WORK}/platform" | cut -d' ' -f1)" = "${pd}" ] || {
                echo "error: the linux/${arch} manifest ${pd} of ${ref} does not read anonymously at its digest" >&2
                exit 1
            }
            printf 'image\tmica-build-env\t%s\t%s\t%s@%s\n' "${name}" "${arch}" "${REPOSITORY}" "${pd}" >>"${OUT}"
        done
    done
    echo "publish-images: wrote the image rows of ${#IMAGES[@]} images to ${OUT}" >&2
    ;;
esac
