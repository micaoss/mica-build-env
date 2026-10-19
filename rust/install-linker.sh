#!/usr/bin/env bash
# Install the native linker, the cross linkers for the architectures this image
# cross-builds for and dbus, from the pinned Debian snapshot (lib/apt-debian.sh),
# and on amd64 name the armhf linker in cargo's configuration under CARGO_HOME.
# mica-build-side: container -- runs in the final stage of rust/Dockerfile.
set -euo pipefail

# rustc links through cc; libc6-dev is named because gcc only recommends it.
case "$(dpkg --print-architecture)" in
amd64) cross=(gcc-aarch64-linux-gnu libc6-dev-arm64-cross gcc-arm-linux-gnueabihf libc6-dev-armhf-cross) ;;
arm64) cross=(gcc-x86-64-linux-gnu libc6-dev-amd64-cross) ;;
*) echo "mica-build-rust: error: $(dpkg --print-architecture) has no cross linker package named in this script" >&2; exit 1 ;;
esac

# dbus-daemon: several micad and apid tests fail rather than skip without a session bus.
bash /tmp/mica-lib/apt-debian.sh gcc libc6-dev "${cross[@]}" dbus

# A file rather than an ENV beside the other linkers, so the arm64 image does
# not name a linker it lacks; a consumer's .cargo/config.toml or
# CARGO_TARGET_ARMV7_UNKNOWN_LINUX_GNUEABIHF_LINKER still wins.
if [ "$(dpkg --print-architecture)" = amd64 ]; then
    mkdir -p /usr/local/cargo
    printf '[target.armv7-unknown-linux-gnueabihf]\nlinker = "arm-linux-gnueabihf-gcc"\n' >/usr/local/cargo/config.toml
fi
