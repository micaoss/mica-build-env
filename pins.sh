# The inputs of the build-env images, read from locks/upstream.lock (the pins)
# and params.env (the build parameters). Sourced by build.sh, from.sh,
# fetch-archives.sh and publish-images.sh, which set HERE first.
#
#   pins_load         validate both files and set PINS: one KEY=VALUE line per
#                     input, parameters first, and every key as a variable
#   upstream_ref <name> the reference of the upstream image rows <name>
#                     (debian:trixie-slim): its original reference by index digest
#
# A source row becomes the keys the image scripts read: <PREFIX>_VERSION,
# <PREFIX>_URL_<ARCH> and <PREFIX>_SHA256_<ARCH>, the prefix naming the image
# that installs it (SOURCE_PREFIX).

UPSTREAM_LOCK="${HERE}/locks/upstream.lock"
PARAMS_ENV="${HERE}/params.env"

declare -A SOURCE_PREFIX=(
    [bun]=BASE_BUN
    [go]=GO
    [rust]=RUST
    [rust-std]=RUST_STD
    [cargo-nextest]=RUSTCHECK_NEXTEST
    [cargo-deny]=RUSTCHECK_DENY
)

pins_load() {
    local check line key value kind name arch version sha url rest
    local -A versions=()
    check="$(bash "${HERE}/check-lock.sh" upstream "${UPSTREAM_LOCK}" 2>&1)" || {
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
    while IFS=$'\t' read -r kind name arch version sha url rest; do
        [ "${kind}" = source ] || continue
        key="${SOURCE_PREFIX[${name}]-}"
        [ -n "${key}" ] || { echo "error: locks/upstream.lock pins the source ${name}, which no image installs (pins.sh SOURCE_PREFIX)" >&2; return 1; }
        [ "${arch}" != all ] || { echo "error: locks/upstream.lock pins ${name} for all architectures; every archive an image installs is per architecture" >&2; return 1; }
        if [ -z "${versions[${name}]-}" ]; then
            versions["${name}"]="${version}"
            PINS="${PINS}${key}_VERSION=${version}"$'\n'
        elif [ "${versions[${name}]}" != "${version}" ]; then
            echo "error: locks/upstream.lock pins ${name} at ${versions[${name}]} and ${version}; one image installs one version" >&2
            return 1
        fi
        PINS="${PINS}${key}_URL_${arch^^}=${url}"$'\n'"${key}_SHA256_${arch^^}=${sha}"$'\n'
    done <"${UPSTREAM_LOCK}"
    while IFS='=' read -r key value; do
        [ -n "${key}" ] || continue
        printf -v "${key}" '%s' "${value}"
    done <<<"${PINS}"
}

upstream_ref() {
    local ref
    ref="$(awk -F'\t' -v n="$1" '$1 == "image" && $2 == "upstream" && $3 == n { print $5; exit }' "${UPSTREAM_LOCK}")"
    [ -n "${ref}" ] || { echo "error: locks/upstream.lock has no image rows named $1" >&2; return 1; }
    printf '%s\n' "${ref}"
}
