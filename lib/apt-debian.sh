#!/usr/bin/env bash
# Install packages from the Debian archive snapshot locks/upstream.lock pins.
# mica-build-side: container -- runs in the builds of base, c, go and rust.
#
#   bash /tmp/mica-lib/apt-debian.sh <package>...
#
# The instant and the sha256 of every suite's signed InRelease come from
# /etc/mica-build/inputs.env (DEB_APT_INSTANT, DEB_APT_INRELEASE_<SUITE>), which
# build.sh writes out of the debian-<suite> rows. apt is pointed at
# https://snapshot.debian.org/archive/{debian,debian-security}/<instant>/ for
# exactly those suites, and an InRelease with another hash stops the build: the
# archive signature then ties every index and package to it, so the packages of
# an image are the ones its rows name, and moving the snapshot is an input change
# that rebuilds the image. The sources stay in the image, so an image built on
# it installs from the same snapshot.
#
# The upstream image carries no CA bundle, so TLS peer verification is off for
# that one host: authenticity is the archive keyring's signature and the pinned
# InRelease hashes, as for any apt mirror. Check-Valid-Until is off because a
# snapshot's updates and security InRelease expire a week after the instant.
set -euo pipefail

[ "$#" -gt 0 ] || {
    echo "error: apt-debian.sh was called with no packages. A call with none would run apt-get update, install nothing and exit 0, which reads exactly like a dependency list that arrived" >&2
    exit 1
}
. /etc/mica-build/inputs.env
[[ "${DEB_APT_INSTANT:-}" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || {
    echo "error: DEB_APT_INSTANT='${DEB_APT_INSTANT:-}' is not a snapshot instant; without it apt would install whatever the live archive holds today" >&2
    exit 1
}

# One stanza per suite: the security suites live in their own archive.
stanzas="" pins=""
for var in ${!DEB_APT_INRELEASE_@}; do
    suite="${var#DEB_APT_INRELEASE_}"
    suite="${suite//_/-}"
    suite="${suite,,}"
    archive=debian
    [[ "${suite}" != *-security ]] || archive=debian-security
    stanzas="${stanzas}Types: deb
URIs: https://snapshot.debian.org/archive/${archive}/${DEB_APT_INSTANT}/
Suites: ${suite}
Components: main
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
Check-Valid-Until: no

"
    pins="${pins} ${archive}:${suite}=${!var}"
done
[ -n "${pins}" ] || { echo "error: the inputs name no DEB_APT_INRELEASE_<suite>, so no suite is pinned" >&2; exit 1; }

rm -f /etc/apt/sources.list /etc/apt/sources.list.d/* /etc/apt/apt.conf.d/docker-clean
printf '%s' "${stanzas}" >/etc/apt/sources.list.d/mica-snapshot.sources
# A snapshot host answering 503 for minutes is an outage, not a wrong pin: retry
# with a doubling delay up to a minute, about ten minutes per file in all.
cat >/etc/apt/apt.conf.d/50mica-snapshot <<'CONF'
Acquire::https::snapshot.debian.org::Verify-Peer "false";
Acquire::Retries "15";
Acquire::Retries::Delay::Maximum "60";
CONF

apt-get -o APT::Update::Error-Mode=any update
for pin in ${pins}; do
    archive="${pin%%:*}" rest="${pin#*:}"
    suite="${rest%%=*}"
    file="/var/lib/apt/lists/snapshot.debian.org_archive_${archive}_${DEB_APT_INSTANT}_dists_${suite}_InRelease"
    [ -f "${file}" ] || { echo "error: apt fetched no InRelease for ${suite} at ${DEB_APT_INSTANT}" >&2; exit 1; }
    got="$(sha256sum "${file}" | cut -d' ' -f1)"
    [ "${got}" = "${rest#*=}" ] || { echo "error: the ${suite} InRelease of snapshot ${DEB_APT_INSTANT} has sha256 ${got}, and the inputs pin ${rest#*=}" >&2; exit 1; }
done
apt-get install -y --no-install-recommends "$@"
