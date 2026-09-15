#!/usr/bin/env bash
# Turn the upstream mirrors of locks/upstream.lock and the LOCAL_ tags of
# params.env into the --build-arg lines that carry a `FROM` into a Dockerfile,
# and refuse everything that must not reach one.
#
#   bash from.sh MICA_BASE_IMAGE=upstream.debian.trixie-slim
#       -> --build-arg MICA_BASE_IMAGE=ghcr.io/micaoss/mica-build-env:upstream.debian.trixie-slim.d7e12182ce18@sha256:d7e12182...
#   bash from.sh --ref upstream.debian.trixie-slim
#       -> ghcr.io/micaoss/mica-build-env:upstream.debian.trixie-slim.d7e12182ce18@sha256:d7e12182...
#   bash from.sh --check
#       -> validate locks/upstream.lock and params.env, print nothing, exit 0 or 1
#   bash from.sh --arch=arm64 --contexts=/some/dir LOCAL_MICA_BUILD_C
#       -> --build-context localhost/mica-build-c:arm64=oci-layout:///some/dir/mica-build-c-arm64
#
# upstream.<name> resolves to the mirror of the image rows <name>, pinned by the
# upstream index digest; LOCAL_ keys resolve to `<name>:<arch>` and must exist in
# the local image store. It builds and pulls nothing; --contexts only exports
# local images as OCI layouts.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pins.sh
. "${HERE}/pins.sh"
pins_load || exit 1

# A LOCAL_ tag must exist locally and hold the architecture its name says;
# otherwise docker reports a failed pull from a registry called `localhost`.
FROM_ARCH=""
check_local_key() {
    local k="$1" v="$2" got
    case "${v}" in
    localhost/*) ;;
    *)
        echo "error: ${k}=${v} in params.env does not start with localhost/, but its LOCAL_ prefix says it is an image this repository builds. One of the two is wrong" >&2
        return 1
        ;;
    esac
    docker image inspect "${v}" >/dev/null 2>&1 || {
        echo "error: ${k} resolves to ${v}, which is not in the local docker image store. It is built by \`MICA_BUILD_PLATFORM=linux/${FROM_ARCH} bash build.sh\` (build.sh), which must run before any component build that stands on it -- there is no registry to fall back to and docker would report this as a failed pull from a host called 'localhost'. Note the architecture in that tag: a family for another architecture is a DIFFERENT tag and does not satisfy this, which is the point -- the two used to share one name and overwrite each other" >&2
        return 1
    }
    [ -n "${FROM_ARCH}" ] || return 0
    got="$(docker image inspect --format '{{.Architecture}}' "${v}" 2>/dev/null || true)"
    [ -n "${got}" ] || {
        echo "error: ${v} is in the local image store but reports no architecture, so nothing can say whether it matches the ${FROM_ARCH} build that is about to stand on it" >&2
        return 1
    }
    [ "${got}" = "${FROM_ARCH}" ] || {
        echo "error: ${k} resolves to ${v}, whose tag says ${FROM_ARCH} and whose image is ${got}. That tag is written by build.sh and by nothing else, so this is not a family that needs rebuilding -- it is a tag that lies about what it holds, which means it was applied by hand or by a build that composed the suffix differently from from.sh. Retag or rebuild it; do not pass --arch=${got} to make this sentence go away, because the FROM under it would then be the wrong architecture for the build that asked" >&2
        return 1
    }
    return 0
}

# One key to its validated value; every output mode goes through here.
resolve_key() {
    local key="$1" val
    case "${key}" in
    upstream.*) mirror_ref "${key#upstream.}" || return 1; return 0 ;;
    esac
    val="${!key-}"
    if [ -z "${val}" ]; then
        echo "error: params.env defines no ${key}. Every base image in this tree is an upstream.<name> mirror of locks/upstream.lock or a LOCAL_ tag; if this is a new one, pin it there rather than writing it into a FROM or a docker run" >&2
        return 1
    fi
    case "${key}" in
    LOCAL_*)
        # Both architectures coexist in the store, so there is no default to guess.
        [ -n "${FROM_ARCH}" ] || {
            echo "error: ${key} is an image this repository builds, and those are tagged by architecture -- ${val}:amd64 and ${val}:arm64 are two images that coexist in one store. Pass --arch=<amd64|arm64> to say which this build stands on. Guessing the host's would be wrong for exactly the cross builds this naming exists to serve, and silently: the wrong-architecture base still resolves" >&2
            return 1
        }
        val="${val}:${FROM_ARCH}"
        check_local_key "${key}" "${val}" || return 1
        ;;
    *)
        echo "error: ${key} is neither an upstream.<name> mirror nor a LOCAL_ key, so from.sh cannot say what would make it valid. A base image is either an upstream image pinned in locks/upstream.lock (upstream.<name>) or one this repository builds (LOCAL_)" >&2
        return 1
        ;;
    esac
    printf '%s\n' "${val}"
}

# --check: pins_load above validated both files; every image row must name a mirror.
if [ "${1-}" = "--check" ]; then
    [ "$#" -eq 1 ] || { echo "error: --check takes no other arguments" >&2; exit 1; }
    mapfile -t names < <(awk -F'\t' '$1 == "image" { print $2 }' "${UPSTREAM_LOCK}" | sort -u)
    [ "${#names[@]}" -gt 0 ] || {
        echo "error: locks/upstream.lock pins no image at all, so this check passed by having nothing to check" >&2
        exit 1
    }
    for n in "${names[@]}"; do mirror_ref "${n}" >/dev/null; done
    exit 0
fi

if [ "${1-}" != "${1#--arch=}" ]; then
    FROM_ARCH="${1#--arch=}"
    shift
    [ -n "${FROM_ARCH}" ] || {
        echo "error: --arch= was given with no architecture. Omit the flag entirely to skip the check; an empty one reads like a check that ran" >&2
        exit 1
    }
fi

# --ref: exactly one bare reference, for `docker run` call sites.
if [ "${1-}" = "--ref" ]; then
    shift
    [ "$#" -eq 1 ] || {
        echo "error: --ref takes exactly one upstream.<name> or LOCAL_ key. It prints one reference on stdout; a call with none would print an empty string that a caller would substitute into a docker command line as no image at all, and a call with several would have to be read back by position" >&2
        exit 1
    }
    resolve_key "$1"
    exit 0
fi

# --contexts: export LOCAL_ images as OCI layouts for builders that cannot read
# the local image store (any driver but `docker`). The named build context
# overrides the matching FROM, so Dockerfiles stay unchanged.
if [ "${1-}" != "${1#--contexts=}" ]; then
    CTX_DIR="${1#--contexts=}"
    shift
    [ -n "${CTX_DIR}" ] || {
        echo "error: --contexts= was given with no directory. It is where the OCI layouts are written; an empty one would put them at the filesystem root" >&2
        exit 1
    }
    [ -d "${CTX_DIR}" ] || {
        echo "error: --contexts=${CTX_DIR} is not a directory. This writes one layout per key into it and does not create it: a caller that mistyped the path would otherwise get a tree of exports nothing reads" >&2
        exit 1
    }
    [ "$#" -gt 0 ] || {
        echo "error: --contexts= takes at least one LOCAL_ key. A call with none would print nothing and exit 0, and a caller that substituted that into a docker command line would build with no --build-context at all -- which is the unresolvable FROM this mode exists to prevent" >&2
        exit 1
    }
    CTX_ABS="$(cd "${CTX_DIR}" && pwd)"
    bad=0
    out=()
    for key in "$@"; do
        case "${key}" in
        LOCAL_*) ;;
        *)
            echo "error: ${key} is not a LOCAL_ key. Only an image this repository builds is exported as a layout; an upstream.<name> mirror is a digest-pinned reference that every driver resolves for itself" >&2
            bad=1
            continue
            ;;
        esac
        if ! val="$(resolve_key "${key}")"; then
            bad=1
            continue
        fi
        # No colon in the path handed to oci-layout://.
        dir="${CTX_ABS}/$(printf '%s' "${val##*/}" | tr ':' '-')"
        rm -rf "${dir}"
        mkdir -p "${dir}"
        if ! docker image save "${val}" | tar -x -C "${dir}"; then
            echo "error: exporting ${val} to an OCI layout under ${dir} failed" >&2
            bad=1
            continue
        fi
        # `docker image save` writes an OCI layout only with the containerd image store.
        if [ ! -f "${dir}/oci-layout" ] || [ ! -f "${dir}/index.json" ]; then
            echo "error: \`docker image save ${val}\` did not produce an OCI layout (no oci-layout/index.json under ${dir}); this daemon writes the older docker-archive format, which buildx cannot take as a build context. A builder that cannot read the local image store needs the containerd image store enabled on the daemon that holds ${val}" >&2
            bad=1
            continue
        fi
        out+=(--build-context "${val}=oci-layout://${dir}")
    done
    [ "${bad}" = 0 ] || exit 1
    printf '%s\n' "${out[@]}"
    exit 0
fi

[ "$#" -gt 0 ] || {
    cat >&2 <<'USAGE'
usage: from.sh [--arch=<amd64|arm64>] <ARG_NAME>=<upstream.NAME|LOCAL_KEY> [...]
       from.sh [--arch=<amd64|arm64>] --ref <upstream.NAME|LOCAL_KEY>
       from.sh [--arch=<amd64|arm64>] --contexts=<DIR> <LOCAL_KEY> [...]
       from.sh --check

A call with no pairs would print nothing and exit 0, and a caller that
substituted that into a docker command line would build with no --build-arg at
all -- which is precisely the unpinned build this file exists to prevent.
USAGE
    exit 1
}

bad=0
out=()
for pair in "$@"; do
    arg="${pair%%=*}"
    key="${pair#*=}"
    if [ "${arg}" = "${pair}" ] || [ -z "${arg}" ] || [ -z "${key}" ]; then
        echo "error: '${pair}' is not <ARG_NAME>=<upstream.NAME|LOCAL_KEY>" >&2
        bad=1
        continue
    fi
    # Keep going so every bad key is reported, not just the first.
    if ! val="$(resolve_key "${key}")"; then
        bad=1
        continue
    fi
    out+=(--build-arg "${arg}=${val}")
done
[ "${bad}" = 0 ] || exit 1

printf '%s\n' "${out[@]}"
