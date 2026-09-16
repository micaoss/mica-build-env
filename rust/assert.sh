#!/usr/bin/env bash
# Assert the Rust toolchain and gate tools mica-build-rust promises, including
# the cross build, and record what it resolved to.
# mica-build-side: container -- runs in the final stage of rust/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-rust
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

check_arch

uarch="${arch^^}"
case "${uarch}" in
AMD64) uother=ARM64; otherelf=aarch64; crosscc=aarch64-linux-gnu-gcc ;;
ARM64) uother=AMD64; otherelf=x86-64; crosscc=x86_64-linux-gnu-gcc ;;
*) echo "${MICA_IMAGE}: error: ${arch} is not an architecture params.env gives a Rust triple for" >&2; exit 1 ;;
esac
triple_key="RUST_TRIPLE_${uarch}"
otriple_key="RUST_TRIPLE_${uother}"
triple="${!triple_key}"
otriple="${!otriple_key}"

for t in rustc cargo cc "${crosscc}" cargo-clippy clippy-driver rustfmt cargo-nextest cargo-deny dbus-daemon; do need "${t}"; done

# rustc is exact (sha256-pinned); cargo's own version sequence is not pinned, so it is checked by building.
got="$(rustc --version 2>/dev/null | awk '{print $2}' || true)"
if [ -z "${got}" ]; then
    say "error: could not read a version out of 'rustc --version'"
elif [ "${got}" = "${RUST_VERSION}" ]; then
    echo "ok rustc ${got} (exactly RUST_VERSION, which the sha256 pin makes checkable exactly)"
else
    say "error: rustc is ${got}, but locks/upstream.lock pins rust ${RUST_VERSION} by sha256. This is not a floor: the recorded tarball hash and the installed compiler have come apart, and one of the two is lying about what this image builds with"
fi
echo "ok cargo $(cargo --version 2>/dev/null | awk '{print $2}' || true) (present; its number is upstream's sequence and not a value locks/upstream.lock pins -- what it must do is build, which is checked below)"

sysroot="$(rustc --print sysroot 2>/dev/null || true)"
for tr in "${triple}" "${otriple}"; do
    if [ -d "${sysroot}/lib/rustlib/${tr}/lib" ]; then
        echo "ok std for ${tr}"
    else
        say "error: no std for ${tr} under ${sysroot}/lib/rustlib. A cargo build --target ${tr} fails with 'can't find crate for std', which reads as a broken source tree and is a broken image"
    fi
done

# Real native and cross cargo builds; --offline because the probe depends on nothing.
export CARGO_HOME=/usr/local/cargo
mkdir -p "${CARGO_HOME}"
d="$(mktemp -d)"
mkdir -p "${d}/probe/src"
printf '[package]\nname = "probe"\nversion = "0.0.0"\nedition = "2021"\n\n[[bin]]\nname = "probe"\npath = "src/main.rs"\n' >"${d}/probe/Cargo.toml"
printf 'fn main() { println!("{}", std::env::consts::ARCH); }\n' >"${d}/probe/src/main.rs"
if (cd "${d}/probe" && cargo build --offline --release --target "${triple}" >"${d}/native.log" 2>&1); then
    gotelf="$(file -b "${d}/probe/target/${triple}/release/probe")"
    case "${arch}:${gotelf}" in
    amd64:*x86-64*) echo "ok cargo links an amd64 ELF for ${triple}" ;;
    arm64:*aarch64*) echo "ok cargo links an arm64 ELF for ${triple}" ;;
    *) say "error: cargo on this ${arch} image produced '${gotelf}', which is not a ${arch} ELF" ;;
    esac
else
    say "error: cargo cannot build and link a std-only binary for its own target ${triple}: $(tail -n5 "${d}/native.log" | tr '\n' ' ')"
fi
if (cd "${d}/probe" && cargo build --offline --release --target "${otriple}" >"${d}/cross.log" 2>&1); then
    gotelf="$(file -b "${d}/probe/target/${otriple}/release/probe")"
    case "${gotelf}" in
    *"${otherelf}"*) echo "ok cargo cross-links a ${otriple} ELF through ${crosscc} (this is what RUST_STD_SHA256_${uother} and the cross linker package buy)" ;;
    *) say "error: cargo --target ${otriple} produced '${gotelf}', which is not a ${otherelf} ELF; this image cannot cross-build for the architecture the other board ships" ;;
    esac
else
    say "error: cargo --target ${otriple} failed, so this image cannot cross-build for the architecture the other board ships: $(tail -n5 "${d}/cross.log" | tr '\n' ' ')"
fi
rm -rf "${d}"

# clippy-driver links the compiler it was built with, so it must be rustc's own release.
rustc_rel="$(rustc -vV 2>/dev/null | sed -n 's/^release: //p' || true)"
clippy_rel="$(clippy-driver -vV 2>/dev/null | sed -n 's/^release: //p' || true)"
if [ -z "${rustc_rel}" ] || [ -z "${clippy_rel}" ]; then
    say "error: could not read a release line out of 'rustc -vV' or 'clippy-driver -vV'"
elif [ "${rustc_rel}" = "${clippy_rel}" ]; then
    echo "ok clippy-driver ${clippy_rel} is the same release as rustc"
else
    say "error: rustc is ${rustc_rel} and clippy-driver is ${clippy_rel}; they came from different tarballs, so this image holds two toolchains"
fi
rustfmt_v="$(rustfmt --version 2>/dev/null || true)"
case "${rustfmt_v}" in
rustfmt*) echo "ok ${rustfmt_v}" ;;
*) say "error: 'rustfmt --version' printed '${rustfmt_v}' rather than a version line" ;;
esac

# nextest and deny are sha256-pinned, so their versions are asserted exactly.
nextest_v="$(cargo nextest --version 2>/dev/null || true)"
case "${nextest_v}" in
*"${RUSTCHECK_NEXTEST_VERSION}"*) echo "ok cargo nextest ${RUSTCHECK_NEXTEST_VERSION} (exactly RUSTCHECK_NEXTEST_VERSION)" ;;
*) say "error: 'cargo nextest --version' printed '${nextest_v}', which does not carry the pinned RUSTCHECK_NEXTEST_VERSION=${RUSTCHECK_NEXTEST_VERSION}" ;;
esac
deny_v="$(cargo deny --version 2>/dev/null || true)"
case "${deny_v}" in
*"${RUSTCHECK_DENY_VERSION}"*) echo "ok cargo deny ${RUSTCHECK_DENY_VERSION} (exactly RUSTCHECK_DENY_VERSION)" ;;
*) say "error: 'cargo deny --version' printed '${deny_v}', which does not carry the pinned RUSTCHECK_DENY_VERSION=${RUSTCHECK_DENY_VERSION}" ;;
esac
dbus_v="$(dbus-daemon --version 2>/dev/null | line1 || true)"
[ -n "${dbus_v}" ] || say "error: dbus-daemon is installed but 'dbus-daemon --version' printed nothing"

finish toolchain

mkdir -p /etc/mica-build
sha_key="RUST_SHA256_${uarch}"
std_key="RUST_STD_SHA256_${uother}"
{
    echo "MICA_BUILD_IMAGE=mica-build-rust"
    echo "MICA_BUILD_FROM=${MICA_BASE_IMAGE}"
    echo "MICA_BUILD_ARCH=${arch}"
    echo "MICA_BUILD_RUSTC=$(rustc --version | awk '{print $2}')"
    echo "MICA_BUILD_CARGO=$(cargo --version | awk '{print $2}')"
    echo "MICA_BUILD_RUST_SHA256=${!sha_key}"
    echo "MICA_BUILD_RUST_HOST_TRIPLE=${triple}"
    echo "MICA_BUILD_RUST_CROSS_TRIPLE=${otriple}"
    echo "MICA_BUILD_RUST_CROSS_STD_SHA256=${!std_key}"
    echo "MICA_BUILD_RUST_CROSS_LINKER=${crosscc}"
    echo "MICA_BUILD_CLIPPY=${clippy_rel}"
    echo "MICA_BUILD_RUSTFMT=$(rustfmt --version | awk '{print $2}')"
    echo "MICA_BUILD_NEXTEST=${RUSTCHECK_NEXTEST_VERSION}"
    echo "MICA_BUILD_DENY=${RUSTCHECK_DENY_VERSION}"
    echo "MICA_BUILD_DBUS=$(dbus-daemon --version | line1 | awk '{print $NF}')"
    nextest_key="RUSTCHECK_NEXTEST_SHA256_${uarch}"
    deny_key="RUSTCHECK_DENY_SHA256_${uarch}"
    echo "MICA_BUILD_NEXTEST_SHA256=${!nextest_key-}"
    echo "MICA_BUILD_DENY_SHA256=${!deny_key-}"
} >/etc/mica-build/rust.env
