# The inputs of the build-env images, read from locks/upstream.lock (the pins)
# and params.env (the build parameters). Sourced by build.sh, from.sh,
# fetch-archives.sh and publish-images.sh, which set HERE first.
#
#   pins_load         validate both files and set PINS: one KEY=VALUE line per
#                     input, parameters first, and every key as a variable
#   upstream_ref <name> the reference of the upstream image rows <name>
#                     (debian:trixie-slim): its original reference by index digest
#
# locks/upstream.lock is read through mica-build-tools (`upstream check`,
# `upstream rows`, `from`); what is decided here is which image installs each
# source row.
#
# A per-architecture source row becomes the keys the image scripts read:
# <PREFIX>_VERSION, <PREFIX>_URL_<ARCH> and <PREFIX>_SHA256_<ARCH>, the prefix
# naming the image that installs it (SOURCE_PREFIX). The `all` rows are the
# archive snapshots the images install packages from: `ubuntu-<suite>` become
# BSP_APT_INSTANT and one BSP_APT_INRELEASE_<SUITE> per suite, inputs of bsp
# alone; `debian-<suite>` become DEB_APT_INSTANT and DEB_APT_INRELEASE_<SUITE>,
# inputs of base, c, go and rust.

PARAMS_ENV="${HERE}/params.env"

declare -A SOURCE_PREFIX=(
    [bun]=BASE_BUN
    [go]=GO
    [rust]=RUST
    [rust-std]=RUST_STD
    [cargo-nextest]=RUSTCHECK_NEXTEST
    [cargo-deny]=RUSTCHECK_DENY
    [cargo-shear]=RUSTCHECK_SHEAR
    [typos]=RUSTCHECK_TYPOS
)

pins_load() {
    local check rows line key value kind name arch version sha url rest suite prefix archive want
    local -A versions=() instants=()
    check="$("${HERE}/bin/mica-tools" upstream check 2>&1)" || {
        echo "error: locks/upstream.lock is ${check}" >&2
        return 1
    }
    PINS=""
    while IFS= read -r line; do
        case "${line}" in '' | '#'*) continue ;; esac
        [[ "${line}" =~ ^(LOCAL_MICA_BUILD_[A-Z]+|[A-Z]+_FLOOR_[A-Z0-9_]+|RUST_TRIPLE_(AMD64|ARM64))=([^[:space:]\$\`\"\']+)$ ]] || {
            echo "error: params.env line '${line}' is not a floor, a local tag or a Rust triple; images and archives are pinned in locks/upstream.lock only" >&2
            return 1
        }
        PINS="${PINS}${line}"$'\n'
    done <"${PARAMS_ENV}"
    rows="$("${HERE}/bin/mica-tools" upstream rows source)" || return 1
    while IFS=$'\t' read -r kind name arch version sha url rest; do
        [ -n "${kind}" ] || continue
        if [ "${arch}" = all ]; then
            # An archive snapshot: one instant per distribution, one signed InRelease per suite.
            [[ "${version}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || { echo "error: the snapshot row ${name} names the instant '${version}', not YYYYMMDDTHHMMSSZ" >&2; return 1; }
            case "${name}" in
            ubuntu-*)
                suite="${name#ubuntu-}" prefix=BSP
                want="https://snapshot.ubuntu.com/ubuntu/${version}/dists/${suite}/InRelease"
                ;;
            debian-*)
                suite="${name#debian-}" prefix=DEB archive=debian
                [[ "${suite}" != *-security ]] || archive=debian-security
                want="https://snapshot.debian.org/archive/${archive}/${version}/dists/${suite}/InRelease"
                ;;
            *) echo "error: locks/upstream.lock pins ${name} for all architectures; only the ubuntu-<suite> and debian-<suite> snapshot rows are" >&2; return 1 ;;
            esac
            [ "${url}" = "${want}" ] || {
                echo "error: the snapshot row ${name} is not the InRelease of suite ${suite} at ${version}: ${url}" >&2
                return 1
            }
            if [ -z "${instants[${prefix}]-}" ]; then
                instants["${prefix}"]="${version}"
                PINS="${PINS}${prefix}_APT_INSTANT=${version}"$'\n'
            elif [ "${instants[${prefix}]}" != "${version}" ]; then
                echo "error: locks/upstream.lock names two ${name%%-*} snapshot instants, ${instants[${prefix}]} and ${version}; a snapshot moves as a whole" >&2
                return 1
            fi
            key="${prefix}_APT_INRELEASE_${suite^^}"
            PINS="${PINS}${key//-/_}=${sha}"$'\n'
            continue
        fi
        key="${SOURCE_PREFIX[${name}]-}"
        [ -n "${key}" ] || { echo "error: locks/upstream.lock pins the source ${name}, which no image installs (pins.sh SOURCE_PREFIX)" >&2; return 1; }
        if [ -z "${versions[${name}]-}" ]; then
            versions["${name}"]="${version}"
            PINS="${PINS}${key}_VERSION=${version}"$'\n'
        elif [ "${versions[${name}]}" != "${version}" ]; then
            echo "error: locks/upstream.lock pins ${name} at ${versions[${name}]} and ${version}; one image installs one version" >&2
            return 1
        fi
        PINS="${PINS}${key}_URL_${arch^^}=${url}"$'\n'"${key}_SHA256_${arch^^}=${sha}"$'\n'
    done <<<"${rows}"
    while IFS='=' read -r key value; do
        [ -n "${key}" ] || continue
        printf -v "${key}" '%s' "${value}"
    done <<<"${PINS}"
}

upstream_ref() {
    "${HERE}/bin/mica-tools" from --ref "upstream:$1"
}
