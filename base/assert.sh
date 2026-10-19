#!/usr/bin/env bash
# Assert the floor mica-build-base promises and record what it resolved to.
# mica-build-side: container -- runs in the final stage of base/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-base
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

check_arch

codename="$(. /etc/os-release; echo "${VERSION_CODENAME:-}")"
if [ "${codename}" != "${BASE_FLOOR_CODENAME}" ]; then
    say "error: the base resolves to Debian '${codename}', but params.env declares BASE_FLOOR_CODENAME=${BASE_FLOOR_CODENAME}. The digest pin was changed to a well-formed digest of a DIFFERENT image"
fi

# binutils by five programs: a slimmed package can ship strip without readelf.
for t in git file strip objdump readelf ar nm xz bun; do need "${t}"; done
check git      "${BASE_FLOOR_GIT_MIN}"      "$(git --version 2>/dev/null | awk '{print $3}' || true)"
check file     "${BASE_FLOOR_FILE_MIN}"     "$(file --version 2>/dev/null | line1 | sed 's/^file-//' || true)"
check binutils "${BASE_FLOOR_BINUTILS_MIN}" "$(strip --version 2>/dev/null | line1 | awk '{print $NF}' || true)"
check xz       "${BASE_FLOOR_XZ_MIN}"       "$(xz --version 2>/dev/null | line1 | awk '{print $NF}' || true)"

# The bundle file, not dpkg: the package can be installed with an empty bundle.
bundle=/etc/ssl/certs/ca-certificates.crt
if [ ! -s "${bundle}" ]; then
    say "error: ${bundle} is missing or empty; every TLS fetch in every image built on this one would fail naming the remote host and never the cause"
else
    echo "ok ca-certificates $(grep -c 'BEGIN CERTIFICATE' "${bundle}") certificates"
fi

# bun comes from a sha256-pinned archive, so its version is asserted exactly.
got="$(bun --version 2>/dev/null || true)"
if [ -z "${got}" ]; then
    say "error: could not read a version out of 'bun --version'"
elif [ "${got}" = "${BASE_BUN_VERSION}" ]; then
    echo "ok bun ${got} (exactly BASE_BUN_VERSION)"
else
    say "error: bun is ${got}, but locks/upstream.lock pins bun ${BASE_BUN_VERSION} by sha256; the recorded archive hash and the installed binary have come apart"
fi
case "${arch}" in
amd64) bunarch=x64 ;;
arm64) bunarch=arm64 ;;
*) bunarch="${arch}" ;;
esac
got="$(bun -e 'console.log(process.arch)' 2>&1 || true)"
[ "${got}" = "${bunarch}" ] || say "error: bun cannot run a script on this ${arch} image: ${got}"

# Debian packaging: dpkg and dpkg-dev floored separately, perl because the dpkg-dev tools are perl.
dpkg_version() {
    "$1" --version 2>/dev/null | sed -n 's/.*version \([0-9][0-9.]*\).*/\1/p' | line1 || true
}
check dpkg     "${DEB_FLOOR_DPKG_MIN}"     "$(dpkg_version dpkg)"
check dpkg-deb "${DEB_FLOOR_DPKG_MIN}"     "$(dpkg_version dpkg-deb)"
check dpkg-dev "${DEB_FLOOR_DPKG_DEV_MIN}" "$(dpkg_version dpkg-shlibdeps)"
check perl     "${DEB_FLOOR_PERL_MIN}"     "$(perl -e 'printf "%vd", $^V' 2>/dev/null || true)"
# Run, not command -v: these are perl scripts whose Dpkg modules may not load.
for t in dpkg-scanpackages dpkg-gencontrol; do
    "${t}" --version >/dev/null 2>&1 || say "error: ${t} does not run, but packing and indexing a pool stand on it"
done
for t in md5sum sha256sum du curl wget mmdebstrap python3 python; do need "${t}"; done
# `python` is python3 (python-is-python3), not a second interpreter.
[ "$(python --version 2>&1)" = "$(python3 --version 2>&1)" ] ||
    say "error: python is '$(python --version 2>&1)' but python3 is '$(python3 --version 2>&1)'; python must be python3"
check mmdebstrap "${BASE_FLOOR_MMDEBSTRAP_MIN}" "$(mmdebstrap --version 2>/dev/null | awk '{print $NF}' || true)"

# openssl mints trust material, so it has to hash, not only report a version.
check openssl "${OPENSSL_FLOOR_OPENSSL_MIN}" "$(openssl version 2>/dev/null | sed -n 's/^OpenSSL \([0-9][0-9.]*\).*/\1/p' || true)"
check jq      "${OPENSSL_FLOOR_JQ_MIN}"      "$(jq --version 2>/dev/null | sed -n 's/^jq-\([0-9][0-9.]*\).*/\1/p' || true)"
printf 'x' | openssl dgst -sha256 >/dev/null 2>&1 ||
    say "error: openssl runs but cannot hash, so the libcrypto behind it is not usable"

# armhf packs on amd64: dpkg-shlibdeps resolves an armhf ELF against the
# symbols files of libc6:armhf and libgcc-s1:armhf, symbol-exact as for the
# native architecture. The probe is built by the armhf-probe stage.
if [ "${arch}" = amd64 ]; then
    case " $(dpkg --print-foreign-architectures | tr '\n' ' ') " in
    *" armhf "*) echo "ok armhf is a dpkg foreign architecture" ;;
    *) say "error: armhf is not a dpkg foreign architecture, so no armhf library can be installed for dpkg-shlibdeps" ;;
    esac
    for p in libc6 libgcc-s1; do
        native="$(dpkg-query -W -f='${Version}' "${p}:amd64" 2>/dev/null || true)"
        got="$(dpkg-query -W -f='${Version}' "${p}:armhf" 2>/dev/null || true)"
        if [ -z "${got}" ]; then
            say "error: ${p}:armhf is not installed, so dpkg-shlibdeps cannot resolve an armhf binary that links it"
        elif [ "${got}" != "${native}" ]; then
            say "error: ${p}:armhf is ${got} and ${p}:amd64 is ${native}; both come from one snapshot and must be one version"
        elif [ ! -s "/var/lib/dpkg/info/${p}:armhf.symbols" ]; then
            say "error: ${p}:armhf carries no symbols file, so dpkg-shlibdeps would fall back to its shlibs minimum"
        else
            echo "ok ${p}:armhf ${got} with its symbols file"
        fi
    done
    d="$(mktemp -d)"
    mkdir -p "${d}/debian"
    printf 'Source: probe\n\nPackage: probe\nArchitecture: armhf\n' >"${d}/debian/control"
    cp /tmp/armhf-probe/probe "${d}/probe"
    needed="$(readelf -d "${d}/probe" | sed -n 's/.*(NEEDED).*\[\(.*\)\]$/\1/p' | sort | tr '\n' ' ')"
    [ "${needed}" = "libc.so.6 libgcc_s.so.1 " ] || say "error: the armhf probe needs '${needed}', not libc.so.6 and libgcc_s.so.1, so it proves nothing about both"
    if got="$(cd "${d}" && DEB_HOST_ARCH=armhf dpkg-shlibdeps -O probe 2>"${d}/err")"; then
        if [[ "${got}" =~ ^shlibs:Depends=libc6\ \(\>=\ [0-9][0-9.~+-]*\),\ libgcc-s1\ \(\>=\ [0-9][0-9.~+-]*\)$ ]]; then
            echo "ok dpkg-shlibdeps on an armhf ELF: ${got#shlibs:Depends=}"
        else
            say "error: DEB_HOST_ARCH=armhf dpkg-shlibdeps printed '${got}', not libc6 (>= x), libgcc-s1 (>= y)"
        fi
    else
        say "error: DEB_HOST_ARCH=armhf dpkg-shlibdeps failed on an armhf ELF linking libc and libgcc_s: $(tr '\n' ' ' <"${d}/err")"
    fi
    rm -rf "${d}"
fi

finish floor

uarch="${arch^^}"
sha_key="BASE_BUN_SHA256_${uarch}"
mkdir -p /etc/mica-build
{
    echo "MICA_BUILD_IMAGE=mica-build-base"
    echo "MICA_BUILD_FROM=${MICA_BASE_IMAGE}"
    echo "MICA_BUILD_ARCH=${arch}"
    echo "MICA_BUILD_DEBIAN=${codename}"
    echo "MICA_BUILD_APT_SNAPSHOT=${DEB_APT_INSTANT}"
    echo "MICA_BUILD_GIT=$(git --version | awk '{print $3}')"
    echo "MICA_BUILD_FILE=$(file --version | line1 | sed 's/^file-//')"
    echo "MICA_BUILD_BINUTILS=$(strip --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_XZ=$(xz --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_BUN=$(bun --version)"
    echo "MICA_BUILD_BUN_SHA256=${!sha_key-}"
    echo "MICA_BUILD_CURL=$(curl --version | line1 | awk '{print $2}')"
    echo "MICA_BUILD_DPKG=$(dpkg-query -W -f='${Version}' dpkg)"
    echo "MICA_BUILD_DPKG_DEV=$(dpkg-query -W -f='${Version}' dpkg-dev)"
    echo "MICA_BUILD_PERL=$(dpkg-query -W -f='${Version}' perl)"
    echo "MICA_BUILD_OPENSSL=$(dpkg-query -W -f='${Version}' openssl)"
    echo "MICA_BUILD_OPENSSL_VERSION=$(openssl version)"
    echo "MICA_BUILD_JQ=$(dpkg-query -W -f='${Version}' jq)"
    echo "MICA_BUILD_MMDEBSTRAP=$(dpkg-query -W -f='${Version}' mmdebstrap)"
    echo "MICA_BUILD_PYTHON3=$(python3 --version | awk '{print $2}')"
    [ "${arch}" != amd64 ] || echo "MICA_BUILD_ARMHF_LIBC6=$(dpkg-query -W -f='${Version}' libc6:armhf)"
    [ "${arch}" != amd64 ] || echo "MICA_BUILD_ARMHF_LIBGCC_S1=$(dpkg-query -W -f='${Version}' libgcc-s1:armhf)"
} >/etc/mica-build/base.env
