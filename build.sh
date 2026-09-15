#!/usr/bin/env bash
# Build the pinned Mica OS builder images out of locks/upstream.lock and params.env.
#
#   bash build.sh  -> localhost/mica-build-{base,c,go,rust}:<arch>
#   bash build.sh  does the same thing
#   bash build.sh base [<image> ...]  builds only the named images
#   MICA_BUILD_PLATFORM=linux/arm64 ...  builds for another architecture
#   MICA_FETCH_SEED=<dir> ...  hands the archives fetch-archives.sh gathered to the fetch stages
#   MICA_BUILD_PARENT=<name:tag@sha256:...> bash build.sh go
#       builds one image on that published parent instead of its localhost/ one
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pins.sh
. "${HERE}/pins.sh"

command -v docker >/dev/null 2>&1 || {
    echo "error: docker is required and not on PATH" >&2
    exit 1
}

# One row per image: <directory>:<input key prefixes>:<its FROM: the upstream.<name> mirror or a LOCAL_ key>.
# Order matters: a row FROM a localhost/mica-build-* tag must follow the row that
# builds it (checked below).
IMAGES=(
    "base:BASE_,DEB_,OPENSSL_:upstream.debian.trixie-slim"
    "c:C_:LOCAL_MICA_BUILD_BASE"
    "go:GO_:LOCAL_MICA_BUILD_C"
    "rust:RUST_,RUSTCHECK_:LOCAL_MICA_BUILD_C"
)

# Arguments select rows by name; none selects the whole table.
declare -A SELECTED=()
for arg in "$@"; do
    known=0
    for row in "${IMAGES[@]}"; do
        [ "${row%%:*}" = "${arg}" ] && known=1 && break
    done
    [ "${known}" = 1 ] || {
        echo "error: '${arg}' is not an image this script builds; the images are: $(printf '%s\n' "${IMAGES[@]}" | cut -d: -f1 | tr '\n' ' ')" >&2
        exit 1
    }
    SELECTED["${arg}"]=1
done
selected() { [ "${#SELECTED[@]}" -eq 0 ] || [ -n "${SELECTED[$1]:-}" ]; }

# A published parent replaces the localhost/ one for exactly one image.
PARENT="${MICA_BUILD_PARENT-}"
if [ -n "${PARENT}" ]; then
    [ "${#SELECTED[@]}" -eq 1 ] || {
        echo "error: MICA_BUILD_PARENT names one parent, so it builds exactly one image; name that image" >&2
        exit 1
    }
    [[ "${PARENT}" =~ ^[a-z0-9][a-z0-9._/-]*:[A-Za-z0-9._-]+@sha256:[0-9a-f]{64}$ ]] || {
        echo "error: MICA_BUILD_PARENT=${PARENT} is not a digest pin (name:tag@sha256:<64 hex>)" >&2
        exit 1
    }
fi

case "$(uname -m)" in
x86_64) HOST_PLATFORM=linux/amd64 ;;
aarch64 | arm64) HOST_PLATFORM=linux/arm64 ;;
*) HOST_PLATFORM="" ;;
esac
MICA_BUILD_PLATFORM="${MICA_BUILD_PLATFORM:-${HOST_PLATFORM}}"
[ -n "${MICA_BUILD_PLATFORM}" ] || {
    echo "error: $(uname -m) is not a platform this script maps; set MICA_BUILD_PLATFORM=linux/<arch> explicitly rather than letting the build guess" >&2
    exit 1
}
PLATFORM_ARCH="${MICA_BUILD_PLATFORM#linux/}"

# Every input as KEY=VALUE, validated; each key is also set as a variable.
pins_load || exit 1
STRIPPED="${PINS}"

# Every upstream image row names a mirror this repository publishes.
bash "${HERE}/from.sh" --check

# `# syntax=` is read before any ARG exists, so each Dockerfile writes the
# frontend out and it is checked against the docker-dockerfile.1 mirror here. A
# Dockerfile without the directive uses the daemon's built-in frontend.
check_dockerfile_frontends() {
    local f line bad=0 seen=0
    while IFS= read -r f; do
        [ -f "${HERE}/${f}" ] || continue
        line="$(sed -n '1,3s/^#[[:space:]]*syntax=[[:space:]]*//p' "${HERE}/${f}" | head -n1)"
        [ -n "${line}" ] || continue
        seen=$((seen + 1))
        [ "${line}" = "${FRONTEND}" ] && continue
        echo "error: ${f} declares '# syntax=${line}', but locks/upstream.lock pins the frontend mirror ${FRONTEND}. The frontend parses this Dockerfile before any ARG exists, so it cannot be passed as a build argument and the reference has to be written out here -- which is why it is checked against the file rather than trusted. Change locks/upstream.lock and every Dockerfile together, or neither" >&2
        bad=1
    done < <(git -C "${HERE}" ls-files '*Dockerfile' 2>/dev/null || true)
    [ "${seen}" -gt 0 ] || {
        echo "error: no tracked Dockerfile declares a '# syntax=' line, so this check passed by having nothing to check. Every Dockerfile in this tree carried one when it was written; if that is genuinely no longer true, delete this check rather than leaving it green and empty" >&2
        return 1
    }
    [ "${bad}" = 0 ] && echo "frontend pin: ${seen} Dockerfile(s) agree with ${FRONTEND}" >&2
    return "${bad}"
}
FRONTEND="$(mirror_ref docker-dockerfile.1)" || exit 1
check_dockerfile_frontends

# Native builds pin the `default` builder: only the docker driver resolves a
# localhost/ tag. Cross builds need a docker-container builder, which is handed
# local parents as OCI layouts in the loop below.
BUILDER_ARGS=(--builder default)
BUILDER_DRIVER=docker
if [ "${MICA_BUILD_PLATFORM}" != "${HOST_PLATFORM}" ]; then
    echo "note: ${MICA_BUILD_PLATFORM} is not the host ${HOST_PLATFORM}; using docker-container builder 'mica-${PLATFORM_ARCH}'"
    docker buildx inspect "mica-${PLATFORM_ARCH}" >/dev/null 2>&1 ||
        docker buildx create --name "mica-${PLATFORM_ARCH}" --driver docker-container >/dev/null
    BUILDER_ARGS=(--builder "mica-${PLATFORM_ARCH}")

    # Read off the builder, not inferred from its name.
    builder_inspect="$(docker buildx inspect "mica-${PLATFORM_ARCH}" 2>/dev/null || true)"
    BUILDER_DRIVER="$(printf '%s\n' "${builder_inspect}" | sed -n 's/^Driver:[[:space:]]*//p')"
    [ -n "${BUILDER_DRIVER}" ] || {
        echo "error: \`docker buildx inspect mica-${PLATFORM_ARCH}\` names no driver, so this build cannot tell whether that builder can resolve a localhost/mica-build-* tag or has to be handed the bases as OCI layouts. Either the builder does not exist or it is not running: \`docker buildx ls\` lists what does" >&2
        exit 1
    }
fi

# Validate the whole table before building anything.
bad=0
built_so_far=()
for row in "${IMAGES[@]}"; do
    name="${row%%:*}"
    rest="${row#*:}"
    prefixes="${rest%%:*}"
    from_key="${rest##*:}"

    # Otherwise the child silently builds on whatever a previous run left tagged.
    case "${from_key}" in
    upstream.*) from_value_early="$(mirror_ref "${from_key#upstream.}")" || exit 1 ;;
    *) from_value_early="${!from_key-}" ;;
    esac
    if selected "${name}" && [ -n "${PARENT}" ]; then
        case "${from_value_early}" in
        localhost/mica-build-*) ;;
        *) echo "error: MICA_BUILD_PARENT replaces a localhost/ parent, and '${name}' builds FROM ${from_key}=${from_value_early}" >&2; bad=1 ;;
        esac
    fi
    case "${from_value_early}" in
    localhost/mica-build-*)
        parent="${from_value_early#localhost/mica-build-}"
        found=0
        for b in ${built_so_far[@]+"${built_so_far[@]}"}; do
            [ "${b}" = "${parent}" ] && found=1 && break
        done
        [ "${found}" = 1 ] ||
            { echo "error: the image table builds '${name}' FROM ${from_key}=${from_value_early}, which this script produces from the '${parent}' row -- but that row does not come earlier in the table. '${name}' would build on whatever a previous run left tagged, and every assertion inside it would still pass" >&2; bad=1; }
        # A selected row whose parent is not selected stands on the parent already in the store.
        if [ -z "${PARENT}" ] && selected "${name}" && ! selected "${parent}"; then
            bash "${HERE}/from.sh" --arch="${PLATFORM_ARCH}" --ref "${from_key}" >/dev/null ||
                { echo "error: '${name}' was selected without '${parent}', so it builds on the ${from_value_early}:${PLATFORM_ARCH} already in the local store, and there is none (see above). Select '${parent}' too" >&2; bad=1; }
        fi
        ;;
    esac
    built_so_far+=("${name}")

    [ -d "${HERE}/${name}" ] ||
        { echo "error: the image table names '${name}', but ${HERE}/${name} does not exist" >&2; bad=1; continue; }
    [ -f "${HERE}/${name}/Dockerfile" ] ||
        { echo "error: ${HERE}/${name}/Dockerfile does not exist" >&2; bad=1; }
    [ -n "${from_value_early}" ] ||
        { echo "error: the image table builds '${name}' FROM ${from_key}, and neither locks/upstream.lock nor params.env defines it" >&2; bad=1; }

    # An empty lock would make the image assert nothing, which looks like passing.
    IFS=',' read -r -a pfx <<<"${prefixes}"
    for p in "${pfx[@]}"; do
        printf '%s\n' "${STRIPPED}" | sed -n "s/^\(${p}[A-Za-z0-9_]*=.*\)$/\1/p" | grep -c . >/dev/null ||
            { echo "error: no input key starts with '${p}', so mica-build-${name} would be handed empty inputs and would assert nothing at all -- which looks exactly like passing" >&2; bad=1; }
    done
done
[ "${bad}" = 0 ] || exit 1

# Read-back records and OCI layouts; temporary, so no stale copy outlives the build.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT
READBACK_DIR="${SCRATCH}/readback"
# The toolchain archives fetch-archives.sh gathered (MICA_FETCH_SEED), else an
# empty directory: an image verifies every archive it takes from it.
SEED="${MICA_FETCH_SEED:-${SCRATCH}/empty-seed}"
mkdir -p "${SEED}"
CTX_DIR="${SCRATCH}/contexts"
mkdir -p "${READBACK_DIR}" "${CTX_DIR}"

for row in "${IMAGES[@]}"; do
    name="${row%%:*}"
    rest="${row#*:}"
    prefixes="${rest%%:*}"
    from_key="${rest##*:}"
    selected "${name}" || continue

    DF_DIR="${HERE}/${name}"
    DOCKERFILE="${DF_DIR}/Dockerfile"
    LOCK="${DF_DIR}/inputs.env"

    # The architecture is in the tag so amd64 and arm64 families coexist; from.sh
    # appends the same suffix when it resolves a LOCAL_ key.
    TAG="localhost/mica-build-${name}:${PLATFORM_ARCH}"

    if [ -n "${PARENT}" ]; then
        FROM_ARGS=(--build-arg "MICA_BASE_IMAGE=${PARENT}")
    else
        mapfile -t FROM_ARGS < <(bash "${HERE}/from.sh" --arch="${PLATFORM_ARCH}" "MICA_BASE_IMAGE=${from_key}")
    fi
    # mapfile cannot fail; an empty array is what a refusal from from.sh looks like.
    [ "${#FROM_ARGS[@]}" -eq 2 ] || {
        echo "error: from.sh did not resolve ${from_key} for linux/${PLATFORM_ARCH} (see its message above); the '${name}' row would have built with an empty FROM" >&2
        exit 1
    }
    from_value="${FROM_ARGS[1]#MICA_BASE_IMAGE=}"

    # This image's own keys only, so another image's pin does not invalidate its layers.
    : >"${LOCK}"
    IFS=',' read -r -a pfx <<<"${prefixes}"
    for p in "${pfx[@]}"; do
        printf '%s\n' "${STRIPPED}" | sed -n "s/^\(${p}[A-Za-z0-9_]*=.*\)$/\1/p" >>"${LOCK}"
    done
    [ -s "${LOCK}" ] || {
        echo "error: ${LOCK} came out empty, though the inputs do carry '${prefixes}' keys; mica-build-${name} would assert nothing at all -- which looks exactly like passing" >&2
        exit 1
    }

    echo
    echo "=== mica-build-${name} ==="
    echo "  from      ${from_key}=${from_value}"
    echo "  platform  ${MICA_BUILD_PLATFORM}"
    echo "  inputs    $(grep -c . "${LOCK}"): $(tr '\n' ' ' <"${LOCK}" | sed 's/=[^ ]*//g')"

    # Exported here, not before the loop: the parent tag was written by the previous iteration.
    CTX_ARGS=()
    if [ "${BUILDER_DRIVER}" != docker ]; then
        case "${from_value}" in
        localhost/*)
            mapfile -t CTX_ARGS < <(bash "${HERE}/from.sh" --arch="${PLATFORM_ARCH}" \
                --contexts="${CTX_DIR}" "${from_key}")
            [ "${#CTX_ARGS[@]}" -eq 2 ] || {
                echo "error: from.sh did not yield an OCI layout context for ${from_key}=${from_value} (see its message above); the '${name}' row would have built against a FROM the '${BUILDER_ARGS[1]}' builder resolves as a registry called 'localhost'" >&2
                exit 1
            }
            echo "  context   ${CTX_ARGS[1]}"
            ;;
        esac
    fi

    docker buildx build "${BUILDER_ARGS[@]}" \
        --platform "${MICA_BUILD_PLATFORM}" \
        "${FROM_ARGS[@]}" \
        ${CTX_ARGS[@]+"${CTX_ARGS[@]}"} \
        --build-context mica-lib="${HERE}/lib" \
        --build-context mica-fetch-seed="${SEED}" \
        -f "${DOCKERFILE}" \
        -t "${TAG}" \
        --load \
        "${DF_DIR}"

    # What landed in the local store, which a stale cache hit or an empty --load would not show.
    id="$(docker image inspect --format '{{.Id}}' "${TAG}" 2>/dev/null || true)"
    [ -n "${id}" ] || {
        echo "error: the build reported success but ${TAG} is not in the local image store" >&2
        exit 1
    }

    # Read /etc/mica-build/<name>.env without executing anything in the image, so a
    # foreign-architecture image can be checked on a host that cannot run it.
    # /bin/sh is never executed; docker create just wants a command.
    cid="$(docker create --platform "${MICA_BUILD_PLATFORM}" "${TAG}" /bin/sh)"
    envfile="${READBACK_DIR}/${name}.env"
    cp_err="${READBACK_DIR}/${name}.cp-err"
    : >"${envfile}"
    cp_rc=0
    docker cp "${cid}:/etc/mica-build/${name}.env" "${envfile}" 2>"${cp_err}" || cp_rc=$?
    docker rm -f "${cid}" >/dev/null

    # A missing file and a broken daemon share an exit code; tell them apart by the message.
    if [ "${cp_rc}" != 0 ]; then
        if grep -c 'Could not find the file' "${cp_err}" >/dev/null; then
            echo "error: ${TAG} carries no /etc/mica-build/${name}.env, so what it asserted at build time cannot be read back out of it. An image that inherits its parent's record and writes none of its own is asserting nothing under its own name" >&2
        else
            echo "error: reading /etc/mica-build/${name}.env out of ${TAG} failed for a reason that is not an absent file, so whether that image carries its own record is unknown: $(tr '\n' ' ' <"${cp_err}")" >&2
        fi
        exit 1
    fi
    recorded="$(cat "${envfile}")"
    [ -n "${recorded}" ] || {
        echo "error: ${TAG} carries /etc/mica-build/${name}.env but it is EMPTY, so what it asserted at build time cannot be read back out of it. An image whose record is a zero-byte file is asserting nothing under its own name" >&2
        exit 1
    }
    echo "  tagged    ${TAG}"
    echo "  image id  ${id}"
    printf '%s\n' "${recorded}" | sed 's/^/  /'
done
