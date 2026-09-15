#!/usr/bin/env bash
# Install the sha256-pinned Rust toolchain for the target architecture (with
# clippy and rustfmt), plus the std for the other architecture, into /opt/rust,
# and the sha256-pinned cargo-nextest and cargo-deny into /opt/cargo-bin.
# mica-build-side: container -- runs in the fetch stage of rust/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-rust
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

uarch="$(target_uarch)"
case "${uarch}" in
AMD64) uother=ARM64 ;;
ARM64) uother=AMD64 ;;
*) echo "${MICA_IMAGE}: error: ${TARGETARCH} is not an architecture params.env gives a Rust triple for" >&2; exit 1 ;;
esac
triple_key="RUST_TRIPLE_${uarch}"
otriple_key="RUST_TRIPLE_${uother}"
triple="${!triple_key-}"
otriple="${!otriple_key-}"
[ -n "${triple}" ] && [ -n "${otriple}" ] || {
    echo "${MICA_IMAGE}: error: params.env is missing RUST_TRIPLE_${uarch} or RUST_TRIPLE_${uother}" >&2
    exit 1
}

# install_pinned URL_KEY SHA_KEY COMPONENTS
install_pinned() {
    local url_key="$1" sha_key="$2" components="$3" url dir c
    url="${!url_key-}"
    fetch_verified "${sha_key}" "${url}" "${!sha_key-}"
    tar -C /tmp/unpack -xJf "${FETCHED}"
    dir="/tmp/unpack/$(basename "${url}" .tar.xz)"
    [ -x "${dir}/install.sh" ] && [ -f "${dir}/components" ] || {
        echo "${MICA_IMAGE}: error: ${url} unpacked without an executable ${dir}/install.sh and a components file; the tarball layout is not what this script expects" >&2
        exit 1
    }
    # install.sh installs nothing for an unknown name without saying so.
    for c in ${components//,/ }; do
        grep -qx "${c}" "${dir}/components" || {
            echo "${MICA_IMAGE}: error: ${url} carries no component named '${c}'. It carries: $(tr '\n' ' ' <"${dir}/components")" >&2
            exit 1
        }
    done
    "${dir}/install.sh" --prefix=/opt/rust --disable-ldconfig --components="${components}"
}

# Components named explicitly: docs are not needed, and a renamed component
# fails here instead of silently not installing.
mkdir -p /opt/rust /opt/cargo-bin /tmp/unpack
install_pinned "RUST_URL_${uarch}" "RUST_SHA256_${uarch}" "rustc,cargo,rust-std-${triple},clippy-preview,rustfmt-preview"
install_pinned "RUST_STD_URL_${uother}" "RUST_STD_SHA256_${uother}" "rust-std-${otriple}"
rm -rf /tmp/unpack

for b in rustc cargo cargo-clippy clippy-driver cargo-fmt rustfmt; do
    [ -x "/opt/rust/bin/${b}" ] || {
        echo "${MICA_IMAGE}: error: install.sh reported success but /opt/rust/bin/${b} is not there" >&2
        exit 1
    }
done

url_key="RUSTCHECK_NEXTEST_URL_${uarch}"
sha_key="RUSTCHECK_NEXTEST_SHA256_${uarch}"
nurl="${!url_key-}"
fetch_verified "${sha_key}" "${nurl}" "${!sha_key-}"
tar -C /opt/cargo-bin -xzf "${FETCHED}" cargo-nextest
[ -x /opt/cargo-bin/cargo-nextest ] || {
    echo "${MICA_IMAGE}: error: ${nurl} does not carry cargo-nextest at the root of the archive" >&2
    exit 1
}

url_key="RUSTCHECK_DENY_URL_${uarch}"
sha_key="RUSTCHECK_DENY_SHA256_${uarch}"
durl="${!url_key-}"
fetch_verified "${sha_key}" "${durl}" "${!sha_key-}"
ddir="$(basename "${durl}" .tar.gz)"
tar -C /opt/cargo-bin --strip-components=1 -xzf "${FETCHED}" "${ddir}/cargo-deny"
[ -x /opt/cargo-bin/cargo-deny ] || {
    echo "${MICA_IMAGE}: error: ${durl} does not carry ${ddir}/cargo-deny" >&2
    exit 1
}
