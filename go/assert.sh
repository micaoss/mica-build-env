#!/usr/bin/env bash
# Assert the Go toolchain mica-build-go promises and record what it resolved to.
# mica-build-side: container -- runs in the final stage of go/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-go
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

check_arch
need go

# Exact, not a floor: the tarball is sha256-pinned, so the version is known.
got="$(go version 2>/dev/null | awk '{print $3}' | sed 's/^go//' || true)"
if [ -z "${got}" ]; then
    say "error: could not read a version out of 'go version'"
elif [ "${got}" = "${GO_VERSION}" ]; then
    echo "ok go ${got} (exactly GO_VERSION, which the sha256 pin makes checkable exactly)"
else
    say "error: go is ${got}, but locks/upstream.lock pins go ${GO_VERSION} by sha256. This is not a floor: the recorded tarball hash and the installed compiler have come apart, and one of the two is lying about what this image builds with"
fi

# Without GOTOOLCHAIN=local a go.mod can make go download and run another toolchain.
tc="$(go env GOTOOLCHAIN 2>/dev/null || true)"
if [ "${tc}" != "local" ]; then
    say "error: GOTOOLCHAIN is '${tc}' and not 'local'. Since Go 1.21 the go command downloads and runs whatever toolchain a go.mod's 'go' line names, so with anything but 'local' the sha256-pinned tarball in this image is a default that the first forward go.mod silently replaces -- over the network, mid-build, saying nothing"
else
    echo "ok GOTOOLCHAIN=local (the go.mod toolchain-download path is closed)"
fi
hostarch="$(go env GOARCH 2>/dev/null || true)"
[ "${hostarch}" = "${arch}" ] || say "error: go reports GOARCH=${hostarch} on a ${arch} image; the tarball for the wrong architecture was unpacked"

case "${arch}" in
amd64) other=arm64; otherelf=aarch64 ;;
arm64) other=amd64; otherelf=x86-64 ;;
*) other=""; otherelf="" ;;
esac

# Build a native and a cross binary; GOPROXY=off turns any network access into an error.
d="$(mktemp -d)"
printf 'package main\n\nimport (\n\t"fmt"\n\t"runtime"\n)\n\nfunc main() { fmt.Println(runtime.GOARCH) }\n' >"${d}/main.go"
(cd "${d}" && GOPROXY=off GOFLAGS=-mod=mod go mod init probe >/dev/null 2>&1) ||
    say "error: 'go mod init' failed in an empty directory; the toolchain is present but not functional"
if (cd "${d}" && GOPROXY=off GOCACHE="${d}/cache" go build -o "${d}/probe" . 2>"${d}/native.err"); then
    got="$(file -b "${d}/probe")"
    case "${arch}:${got}" in
    amd64:*x86-64*) echo "ok go builds an amd64 ELF" ;;
    arm64:*aarch64*) echo "ok go builds an arm64 ELF" ;;
    *) say "error: go on this ${arch} image produced '${got}', which is not a ${arch} ELF" ;;
    esac
else
    say "error: go cannot build a standard-library-only program: $(head -n3 "${d}/native.err" | tr '\n' ' ')"
fi
if [ -n "${other}" ]; then
    if (cd "${d}" && GOPROXY=off GOCACHE="${d}/cache" CGO_ENABLED=0 GOARCH="${other}" go build -o "${d}/cross" . 2>"${d}/cross.err"); then
        got="$(file -b "${d}/cross")"
        case "${got}" in
        *"${otherelf}"*) echo "ok go cross-builds a ${other} ELF with no extra pin (this is why locks/upstream.lock has no go-std source)" ;;
        *) say "error: GOARCH=${other} produced '${got}', which is not a ${other} ELF; this image cannot cross-build for the architecture the other board ships" ;;
        esac
    else
        say "error: GOARCH=${other} go build failed, so this image cannot cross-build for the architecture the other board ships: $(head -n3 "${d}/cross.err" | tr '\n' ' ')"
    fi
fi
# cgo through mica-build-c's toolchain.
mkdir -p "${d}/cgo"
printf 'package main\n\n// int add(int a, int b) { return a + b; }\nimport "C"\n\nimport "fmt"\n\nfunc main() { fmt.Println(C.add(1, 2)) }\n' >"${d}/cgo/main.go"
(cd "${d}/cgo" && GOPROXY=off GOFLAGS=-mod=mod go mod init cgoprobe >/dev/null 2>&1) ||
    say "error: 'go mod init' failed for the cgo probe"
if (cd "${d}/cgo" && GOPROXY=off GOCACHE="${d}/cache" CGO_ENABLED=1 go build -o "${d}/cgo.bin" . 2>"${d}/cgo.err"); then
    got="$("${d}/cgo.bin" 2>/dev/null || true)"
    if [ "${got}" = 3 ]; then
        echo "ok go builds and runs a cgo program"
    else
        say "error: the cgo probe built but printed '${got}' instead of 3"
    fi
else
    say "error: CGO_ENABLED=1 go build failed, so go cannot use the C toolchain it is built on: $(head -n3 "${d}/cgo.err" | tr '\n' ' ')"
fi
rm -rf "${d}"

finish toolchain

mkdir -p /etc/mica-build /go
sha_key="GO_SHA256_${arch^^}"
{
    echo "MICA_BUILD_IMAGE=mica-build-go"
    echo "MICA_BUILD_FROM=${MICA_BASE_IMAGE}"
    echo "MICA_BUILD_ARCH=${arch}"
    echo "MICA_BUILD_GO=$(go version | awk '{print $3}' | sed 's/^go//')"
    echo "MICA_BUILD_GO_SHA256=${!sha_key}"
    echo "MICA_BUILD_GOROOT=$(go env GOROOT)"
    echo "MICA_BUILD_GOTOOLCHAIN=$(go env GOTOOLCHAIN)"
    echo "MICA_BUILD_GO_CROSS=${other:-none}"
} >/etc/mica-build/go.env
