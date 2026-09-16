#!/usr/bin/env bash
# Install packages from the Ubuntu archive snapshot locks/upstream.lock pins, and
# leave no apt lists behind.
# mica-build-side: container -- runs in the build of bsp/Dockerfile.
#
#   bash apt-install.sh git build-essential ...
#
# The instant and the sha256 of every suite's signed InRelease come from
# /etc/mica-build/inputs.env (BSP_APT_INSTANT, BSP_APT_INRELEASE_<SUITE>), which
# build.sh writes out of the ubuntu-<suite> rows. apt is pointed at
# https://snapshot.ubuntu.com/ubuntu/<instant>/ for exactly those suites, and an
# InRelease with another hash stops the build: the archive signature then ties
# every index and package to it, so this image's toolchain is the one the rows
# name. This runs once, when a build-env release builds the image; no consumer
# build ever reaches an archive.
#
# The image carries no CA bundle, so TLS peer verification is off for that one
# host: authenticity is the archive keyring's signature and the pinned InRelease
# hashes, as for any apt mirror.
set -euo pipefail

[ "$#" -gt 0 ] || {
    echo "error: apt-install.sh was called with no packages. A call with none would run apt-get update, install nothing and exit 0, which reads exactly like a dependency list that arrived" >&2
    exit 1
}
. /etc/mica-build/inputs.env
[[ "${BSP_APT_INSTANT:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || {
    echo "error: BSP_APT_INSTANT='${BSP_APT_INSTANT:-}' is not a snapshot instant; without it apt would install whatever the live archive holds today" >&2
    exit 1
}

# One suite per BSP_APT_INRELEASE_<SUITE> key, the underscores written back as dashes.
suites="" pins=""
for var in ${!BSP_APT_INRELEASE_@}; do
    suite="${var#BSP_APT_INRELEASE_}"
    suite="${suite//_/-}"
    suites="${suites} ${suite,,}"
    pins="${pins} ${suite,,}=${!var}"
done
[ -n "${suites}" ] || { echo "error: the inputs name no BSP_APT_INRELEASE_<suite>, so no suite is pinned" >&2; exit 1; }

rm -f /etc/apt/sources.list /etc/apt/sources.list.d/*
cat >/etc/apt/sources.list.d/mica-snapshot.sources <<SOURCES
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${BSP_APT_INSTANT}/
Suites:${suites}
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
echo 'Acquire::https::snapshot.ubuntu.com::Verify-Peer "false";' >/etc/apt/apt.conf.d/50mica-snapshot

apt-get -o APT::Update::Error-Mode=any update
for pin in ${pins}; do
    suite="${pin%%=*}"
    file="/var/lib/apt/lists/snapshot.ubuntu.com_ubuntu_${BSP_APT_INSTANT}_dists_${suite}_InRelease"
    [ -f "${file}" ] || { echo "error: apt fetched no InRelease for ${suite} at ${BSP_APT_INSTANT}" >&2; exit 1; }
    got="$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "${got}" = "${pin#*=}" ] || { echo "error: the ${suite} InRelease of snapshot ${BSP_APT_INSTANT} has sha256 ${got}, and the inputs pin ${pin#*=}" >&2; exit 1; }
done
apt-get install -y --no-install-recommends "$@"
rm -rf /var/lib/apt/lists/*
