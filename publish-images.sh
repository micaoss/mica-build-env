#!/usr/bin/env bash
# Publish the build-env images to GHCR as multi-architecture images tagged with
# the release, and write their image rows of mica-build-env.lock (mica-lock v1):
# index, amd64 and arm64 per image.
#
#   bash publish-images.sh --plan <file>                       which images these inputs need built, and which are published already
#   bash publish-images.sh --build <arch> <release> <plan>     build them natively for <arch> and push <image>.<arch>.<release>
#   bash publish-images.sh --merge <release> <plan>            publish every image as <image>.<release>
#   bash publish-images.sh --resolve <release> --out <file>    build nothing; write the image rows of <release> or refuse
#
# Publishing is CI's: .github/workflows/release.yml runs --plan, then --build on
# an amd64 and an arm64 runner, then --merge, when a release is published
# (`docker login ghcr.io` with packages: write). base builds on
# debian:trixie-slim (locks/upstream.lock), c on base, go and rust on c.
#
# Every tag is a release: <image>.<release> (for example rust.20260915-0030).
# An image's inputs are its keys of locks/upstream.lock and params.env
# (pins.sh), its parent's inputs (or the upstream reference for base), its
# Dockerfile, dockerignore and the scripts that allow-list admits, and lib/;
# their sha256 is the index annotation com.mica.build-env.inputs. An image is
# built when no release tag of it carries these inputs, or its parent is built
# in the same plan; otherwise the release tags the published index it finds, so
# an unchanged image keeps its digest. A published tag is never re-pointed, and
# every row written names a digest that reads with no credential.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY="${MICA_IMAGES_REPOSITORY:-ghcr.io/micaoss/mica-build-env}"
ANNOTATION=com.mica.build-env.inputs
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

USAGE="usage: bash publish-images.sh --plan <file> | --build <amd64|arm64> <release> <plan> | --merge <release> <plan> | --resolve <release> --out <file>"
MODE=""
RELEASE=""
case "${1-}" in
--plan) [ "$#" -eq 2 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=plan; PLAN="$2" ;;
--build) [ "$#" -eq 4 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=build; ARCH="$2"; RELEASE="$3"; PLAN="$4" ;;
--merge) [ "$#" -eq 3 ] || { echo "${USAGE}" >&2; exit 1; }; MODE=merge; RELEASE="$2"; PLAN="$3" ;;
--resolve) [ "$#" -eq 4 ] && [ "$3" = --out ] || { echo "${USAGE}" >&2; exit 1; }; MODE=resolve; RELEASE="$2"; OUT="$4" ;;
*) echo "${USAGE}" >&2; exit 1 ;;
esac
[ "${MODE}" = plan ] || [[ "${RELEASE}" =~ ^[0-9]{8}-[0-9]{4}$ ]] || { echo "error: the release '${RELEASE}' is not YYYYMMDD-HHMM" >&2; exit 1; }
for t in docker jq curl sha256sum; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required and not on PATH" >&2; exit 1; }
done

pins_load || exit 1
STRIPPED="${PINS}"

# inputs_of <image> <prefixes> <parent inputs or base image pin>: the sha256 of the image's inputs.
inputs_of() {
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
    printf '%s\n' "${sha}" | sha256sum | cut -d' ' -f1
}

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/anon"

# raw <ref> <file>: the manifest bytes of <ref>, read with no credential, into
# <file> byte for byte (a trailing newline is part of the digest); prints their digest.
raw() {
    DOCKER_CONFIG="${WORK}/anon" docker buildx imagetools inspect --raw "$1" >"$2" 2>/dev/null && [ -s "$2" ] || return 1
    printf 'sha256:%s\n' "$(sha256sum "$2" | cut -d' ' -f1)"
}
# Captured whole before parsing: a pipe into awk would break under pipefail.
index_digest() {
    local out
    out="$(docker buildx imagetools inspect "$1" 2>/dev/null)" || return 1
    printf '%s\n' "${out}" | awk '/^Digest:[[:space:]]/{print $2; exit}'
}

# release_tags <image>: the <image>.<YYYYMMDD-HHMM> tags of the package, newest first,
# listed with no credential through the registry's tags API.
release_tags() {
    local host="${REPOSITORY%%/*}" path="${REPOSITORY#*/}" token url next
    token="$(curl -fsSL "https://${host}/token?scope=repository:${path}:pull&service=${host}" | jq -r '.token // empty')" || return 1
    url="https://${host}/v2/${path}/tags/list?n=1000"
    : >"${WORK}/tags"
    while [ -n "${url}" ]; do
        curl -fsSL -D "${WORK}/headers" -H "Authorization: Bearer ${token}" -o "${WORK}/page" "${url}" || return 1
        jq -r '.tags[]?' "${WORK}/page" >>"${WORK}/tags"
        next="$(sed -n 's/^[Ll]ink: *<\([^>]*\)>; *rel="next".*/\1/p' "${WORK}/headers" | tr -d '\r')"
        url="${next:+https://${host}${next}}"
    done
    grep -E "^${1}\.[0-9]{8}-[0-9]{4}\$" "${WORK}/tags" | LC_ALL=C sort -r || true
}

clean_tree() {
    command -v git >/dev/null 2>&1 || { echo "error: git is required and not on PATH" >&2; exit 1; }
    [ -z "$(git -C "${HERE}" status --porcelain)" ] || {
        echo "error: ${HERE} has uncommitted changes; a release is built from its clean commit" >&2
        exit 1
    }
}

# Every image's inputs, parents first: INPUTS[<image>].
declare -A INPUTS=() PARENT=()
for row in "${IMAGES[@]}"; do
    IFS='|' read -r name prefixes parent <<<"${row}"
    case "${parent}" in
    upstream:*) from="$(upstream_ref "${parent#upstream:}")" || exit 1 ;;
    *) from="${INPUTS[${parent}]}" ;;
    esac
    [ -n "${from}" ] || { echo "error: ${name}'s parent ${parent} resolved to nothing" >&2; exit 1; }
    INPUTS["${name}"]="$(inputs_of "${name}" "${prefixes}" "${from}")"
    PARENT["${name}"]="${parent}"
done

# read_plan <file>: ACTION[<image>] (build or published) and SOURCE[<image>] (the
# published <image>.<release>@<digest>) from a plan whose inputs are this tree's.
declare -A ACTION=() SOURCE=()
read_plan() {
    local name inputs action source
    [ -s "$1" ] || { echo "error: the plan $1 is missing or empty" >&2; exit 1; }
    while read -r name inputs action source; do
        [ "${INPUTS[${name}]-}" = "${inputs}" ] || { echo "error: the plan $1 names ${name} with the inputs ${inputs}, but these inputs are ${INPUTS[${name}]-nothing}" >&2; exit 1; }
        case "${action}:${source}" in
        build:) ;;
        published:"${REPOSITORY}:${name}".[0-9]*@sha256:*) ;;
        *) echo "error: the plan $1 gives ${name} the action '${action} ${source}'" >&2; exit 1 ;;
        esac
        ACTION["${name}"]="${action}" SOURCE["${name}"]="${source}"
    done <"$1"
    for row in "${IMAGES[@]}"; do
        [ -n "${ACTION[${row%%|*}]-}" ] || { echo "error: the plan $1 does not name ${row%%|*}" >&2; exit 1; }
    done
}

# inputs_annotation <manifest file>: the inputs an index was published for.
inputs_annotation() { jq -r --arg k "${ANNOTATION}" '.annotations[$k] // empty' "$1"; }

case "${MODE}" in
plan)
    : >"${PLAN}"
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        parent="${PARENT[${name}]}"
        found=""
        if [ "${ACTION[${parent}]-}" = build ]; then
            echo "publish-images: ${name} builds because its parent ${parent} does" >&2
        else
            tags="$(release_tags "${name}")" || { echo "error: the tags of ${REPOSITORY} could not be listed anonymously" >&2; exit 1; }
            for t in ${tags}; do
                d="$(raw "${REPOSITORY}:${t}" "${WORK}/index")" || continue
                [ "$(inputs_annotation "${WORK}/index")" = "${INPUTS[${name}]}" ] || continue
                found="${REPOSITORY}:${t}@${d}"
                break
            done
            if [ -n "${found}" ]; then
                echo "publish-images: ${name} is published with these inputs as ${found}" >&2
            else
                echo "publish-images: no release of ${name} carries these inputs; ${name} builds" >&2
            fi
        fi
        if [ -n "${found}" ]; then ACTION["${name}"]=published; else ACTION["${name}"]=build; fi
        printf '%s %s %s%s\n' "${name}" "${INPUTS[${name}]}" "${ACTION[${name}]}" "${found:+ ${found}}" >>"${PLAN}"
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
    clean_tree
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
            MICA_BUILD_PLATFORM="linux/${ARCH}" MICA_BUILD_PARENT="${SOURCE[${parent}]}" bash "${HERE}/build.sh" "${name}" >&2
            ;;
        esac
        src="${REPOSITORY}:${name}.${ARCH}.${RELEASE}"
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
    clean_tree
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        rel="${REPOSITORY}:${name}.${RELEASE}"
        if held="$(index_digest "${rel}")" && [ -n "${held}" ]; then
            # A rerun of this release: the tag must already be these inputs.
            raw "${rel}" "${WORK}/held" >/dev/null && [ "$(inputs_annotation "${WORK}/held")" = "${INPUTS[${name}]}" ] || {
                echo "error: ${rel} already holds ${held}, which is not these inputs; a published tag is never re-pointed" >&2
                exit 1
            }
            echo "publish-images: ${rel} is published with these inputs; not re-pointed" >&2
        elif [ "${ACTION[${name}]}" = build ]; then
            sources=()
            for arch in "${ARCHES[@]}"; do
                src="${REPOSITORY}:${name}.${arch}.${RELEASE}"
                index_digest "${src}" >/dev/null || { echo "error: ${src} is not pushed; the ${arch} build job did not finish ${name}" >&2; exit 1; }
                sources+=("${src}")
            done
            docker buildx imagetools create --annotation "index:${ANNOTATION}=${INPUTS[${name}]}" -t "${rel}" "${sources[@]}" >&2
        else
            docker buildx imagetools create -t "${rel}" "${SOURCE[${name}]}" >&2
        fi
        digest="$(raw "${rel}" "${WORK}/index")" && [ "$(inputs_annotation "${WORK}/index")" = "${INPUTS[${name}]}" ] || {
            package="${REPOSITORY#*/}"
            echo "error: ${rel} does not read anonymously with these inputs. If the package is private, set it public once at https://github.com/orgs/${package%%/*}/packages/container/package/${package#*/} (Package settings, Danger Zone, Change visibility: Public) and rerun" >&2
            exit 1
        }
        [ "${ACTION[${name}]}" = build ] || [ -n "${held}" ] || [ "${digest}" = "${SOURCE[${name}]##*@}" ] || { echo "error: ${rel} is ${digest}, not ${SOURCE[${name}]}" >&2; exit 1; }
        echo "publish-images: published ${rel}@${digest}" >&2
    done
    ;;

resolve)
    : >"${OUT}"
    for row in "${IMAGES[@]}"; do
        name="${row%%|*}"
        ref="${REPOSITORY}:${name}.${RELEASE}"
        digest="$(raw "${ref}" "${WORK}/index")" || {
            echo "error: ${ref} (${name}) is not published or does not read anonymously; the release workflow publishes it for ${RELEASE}" >&2
            exit 1
        }
        [ "$(inputs_annotation "${WORK}/index")" = "${INPUTS[${name}]}" ] || {
            echo "error: ${ref} was published for other inputs than this commit's; it is not the image these inputs name" >&2
            exit 1
        }
        printf 'image\tmica-build-env\t%s\tindex\t%s@%s\n' "${name}" "${ref}" "${digest}" >>"${OUT}"
        for arch in "${ARCHES[@]}"; do
            pd="$(jq -r --arg a "${arch}" '[.manifests[]? | select(.platform.os == "linux" and .platform.architecture == $a) | .digest] | first // empty' "${WORK}/index")"
            [ -n "${pd}" ] || { echo "error: ${ref}@${digest} lists no linux/${arch} manifest" >&2; exit 1; }
            [ "$(raw "${REPOSITORY}@${pd}" "${WORK}/platform" || true)" = "${pd}" ] || {
                echo "error: the linux/${arch} manifest ${pd} of ${ref} does not read anonymously at its digest" >&2
                exit 1
            }
            printf 'image\tmica-build-env\t%s\t%s\t%s@%s\n' "${name}" "${arch}" "${REPOSITORY}" "${pd}" >>"${OUT}"
        done
    done
    echo "publish-images: wrote the image rows of ${#IMAGES[@]} images to ${OUT}" >&2
    ;;
esac
