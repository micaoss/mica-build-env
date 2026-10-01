#!/usr/bin/env bash
# Install the native linker, the cross linker for the other architecture and
# dbus, from the pinned Debian snapshot (lib/apt-debian.sh).
# mica-build-side: container -- runs in the final stage of rust/Dockerfile.
set -euo pipefail

# rustc links through cc; libc6-dev is named because gcc only recommends it.
case "$(dpkg --print-architecture)" in
amd64) cross=(gcc-aarch64-linux-gnu libc6-dev-arm64-cross) ;;
arm64) cross=(gcc-x86-64-linux-gnu libc6-dev-amd64-cross) ;;
*) echo "mica-build-rust: error: $(dpkg --print-architecture) has no cross linker package named in this script" >&2; exit 1 ;;
esac

# dbus-daemon: several micad and apid tests fail rather than skip without a session bus.
bash /tmp/mica-lib/apt-debian.sh gcc libc6-dev "${cross[@]}" dbus
