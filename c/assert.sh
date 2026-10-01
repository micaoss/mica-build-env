#!/usr/bin/env bash
# Assert the C/C++ toolchain mica-build-c promises and record what it resolved to.
# mica-build-side: container -- runs in the final stage of c/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-c
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

check_arch

# Floors, not exact versions: these come from the unpinned apt archive.
for t in gcc g++ cc make cmake pkgconf ccache autoconf automake libtoolize python3 ld; do need "${t}"; done
check gcc     "${C_FLOOR_GCC_MIN}"     "$(gcc -dumpfullversion 2>/dev/null || true)"
check g++     "${C_FLOOR_GCC_MIN}"     "$(g++ -dumpfullversion 2>/dev/null || true)"
check make    "${C_FLOOR_MAKE_MIN}"    "$(make --version 2>/dev/null | line1 | awk '{print $NF}' || true)"
check cmake   "${C_FLOOR_CMAKE_MIN}"   "$(cmake --version 2>/dev/null | line1 | awk '{print $NF}' || true)"
check pkgconf "${C_FLOOR_PKGCONF_MIN}" "$(pkgconf --version 2>/dev/null || true)"
check ccache  "${C_FLOOR_CCACHE_MIN}"  "$(ccache --version 2>/dev/null | line1 | awk '{print $3}' || true)"

# A version check passes without libc headers or a working linker; compiling proves both.
d="$(mktemp -d)"
printf '#include <stdio.h>\n#include <stdlib.h>\nint main(void){printf("%%zu\\n", sizeof(void *)); return EXIT_SUCCESS;}\n' >"${d}/probe.c"
printf '#include <string>\n#include <vector>\nint main(){std::vector<std::string> v{"a"}; return v.size() == 1 ? 0 : 1;}\n' >"${d}/probe.cc"
if gcc -O2 -o "${d}/probe.c.bin" "${d}/probe.c" 2>"${d}/cc.err"; then
    got="$(file -b "${d}/probe.c.bin")"
    case "${arch}:${got}" in
    amd64:*x86-64*) echo "ok gcc links an amd64 ELF" ;;
    arm64:*aarch64*) echo "ok gcc links an arm64 ELF" ;;
    *) say "error: gcc on this ${arch} image produced '${got}', which is not a ${arch} ELF. A toolchain that compiles for the wrong architecture passes every version check above and fails at exec time on the device" ;;
    esac
else
    say "error: gcc cannot compile and link a program that includes stdio.h: $(head -n3 "${d}/cc.err" | tr '\n' ' ')"
fi
g++ -O2 -o "${d}/probe.cc.bin" "${d}/probe.cc" 2>"${d}/cxx.err" ||
    say "error: g++ cannot compile and link a program that includes <string> and <vector>; the C++ standard library headers are missing even though g++ itself is present: $(head -n3 "${d}/cxx.err" | tr '\n' ' ')"
rm -rf "${d}"

finish toolchain

mkdir -p /etc/mica-build
{
    echo "MICA_BUILD_IMAGE=mica-build-c"
    echo "MICA_BUILD_FROM=${MICA_BASE_IMAGE}"
    echo "MICA_BUILD_ARCH=${arch}"
    echo "MICA_BUILD_GCC=$(gcc -dumpfullversion)"
    echo "MICA_BUILD_GXX=$(g++ -dumpfullversion)"
    echo "MICA_BUILD_MAKE=$(make --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_CMAKE=$(cmake --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_PKGCONF=$(pkgconf --version)"
    echo "MICA_BUILD_CCACHE=$(ccache --version | line1 | awk '{print $3}')"
    echo "MICA_BUILD_AUTOCONF=$(autoconf --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_PYTHON3=$(python3 --version | awk '{print $2}')"
} >/etc/mica-build/c.env
