# Helpers shared by the builder image scripts. Sourced; the caller sets MICA_IMAGE.
# mica-build-side: container -- sourced only by scripts that run inside a mica-build-* image build.

fail=0

say() {
    echo "${MICA_IMAGE}: $*" >&2
    fail=1
}

# line1: the first line of stdin. It reads all of it: `head -n1` would exit
# early, and under `set -o pipefail` the producer then dies of SIGPIPE and takes
# the script with it.
line1() {
    local all
    all="$(cat)"
    printf '%s\n' "${all%%$'\n'*}"
}

# ge A B: true when version A >= B.
ge() {
    [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | line1)" = "$2" ]
}

need() {
    command -v "$1" >/dev/null 2>&1 || say "error: $1 is not on PATH, but this image promises it"
}

# check NAME FLOOR GOT: GOT must be at least FLOOR.
check() {
    local name="$1" want="$2" got="$3"
    if [ -z "${got}" ]; then
        say "error: could not read a version out of ${name}"
    elif ge "${got}" "${want}"; then
        echo "ok ${name} ${got} (floor ${want})"
    else
        say "error: ${name} is ${got}, below the floor ${want} that params.env declares. Either the apt archive moved backwards or the floor was raised without measuring; do not lower the floor to make this pass"
    fi
}

# check_arch [DETAIL]: sets arch and refuses an image that is not TARGETARCH.
check_arch() {
    arch="$(dpkg --print-architecture)"
    if [ -n "${TARGETARCH:-}" ] && [ "${arch}" != "${TARGETARCH}" ]; then
        say "error: this image is ${arch} but the build asked for ${TARGETARCH}; the builder has no emulator for it and silently produced a host-architecture image${1:+. $1}"
    fi
}

# finish WHAT: exit non-zero when any check above failed.
finish() {
    [ "${fail}" = 0 ] || {
        echo "${MICA_IMAGE}: the $1 this image promises is not what it contains; see the errors above" >&2
        exit 1
    }
}

# target_uarch: TARGETARCH in upper case, as used by the per-architecture keys.
target_uarch() {
    local a="${TARGETARCH:?TARGETARCH is unset; buildkit always sets it, so this image is being built by something that is not buildx}"
    printf '%s\n' "${a^^}"
}

# fetch_verified KEY URL SHA256: download URL into the cache mount, verify it
# against the pin and set FETCHED to its path. A cached file that does not
# match is taken from the mica-fetch-seed context when that copy matches, else
# fetched again.
fetch_verified() {
    local key="$1" url="$2" want="$3" tb seed got=""
    [ -n "${url}" ] || { echo "${MICA_IMAGE}: error: the inputs define no URL for ${key}, so there is no pinned archive to install" >&2; return 1; }
    [ -n "${want}" ] || { echo "${MICA_IMAGE}: error: the inputs define no ${key}, so ${url} would be installed unverified" >&2; return 1; }
    tb="/var/cache/mica-fetch/$(basename "${url}")"
    if [ -s "${tb}" ]; then
        got="$(sha256sum "${tb}" | awk '{print $1}')"
    fi
    seed="/tmp/mica-fetch-seed/$(basename "${url}")"
    if [ "${got}" != "${want}" ] && [ -s "${seed}" ] && [ "$(sha256sum "${seed}" | awk '{print $1}')" = "${want}" ]; then
        cp "${seed}" "${tb}.part"
        mv "${tb}.part" "${tb}"
        got="${want}"
        echo "using the seeded ${seed}, which matches the recorded hash"
    elif [ "${got}" != "${want}" ]; then
        echo "fetching ${url}"
        curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 -o "${tb}.part" "${url}"
        mv "${tb}.part" "${tb}"
        got="$(sha256sum "${tb}" | awk '{print $1}')"
    else
        echo "using the cached ${tb}, which already matches the recorded hash"
    fi
    [ "${got}" = "${want}" ] || {
        echo "${MICA_IMAGE}: error: ${url} hashes to ${got}, but locks/upstream.lock records ${want} (${key}). Either the pin is wrong or the bytes are not the ones this tree agreed to build with; do not paste the new hash over the old one without knowing which" >&2
        return 1
    }
    echo "ok ${key} ${got}"
    FETCHED="${tb}"
}
