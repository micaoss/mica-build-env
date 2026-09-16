#!/usr/bin/env bash
# Assert the board toolchain mica-build-bsp promises, including the cross
# compiler, and record what it resolved to.
# mica-build-side: container -- runs in the final stage of bsp/Dockerfile.
set -euo pipefail

MICA_IMAGE=mica-build-bsp
. /tmp/mica-lib/common.sh
. /etc/mica-build/inputs.env

check_arch

codename="$(sed -n 's/^VERSION_CODENAME=//p' /etc/os-release)"
[ "${codename}" = "${BSP_FLOOR_CODENAME}" ] ||
    say "error: this image resolves to Ubuntu '${codename}', but params.env declares BSP_FLOOR_CODENAME=${BSP_FLOOR_CODENAME}. The snapshot rows and the base image name two different suites"

for t in gcc g++ make bc bison flex dtc git patch perl python3 rsync cmake ninja swig cpio zstd xxd; do need "${t}"; done
check gcc     "${BSP_FLOOR_GCC_MIN}"     "$(gcc -dumpfullversion 2>/dev/null || true)"
check dtc     "${BSP_FLOOR_DTC_MIN}"     "$(dtc --version 2>/dev/null | awk '{print $NF}' || true)"
check python3 "${BSP_FLOOR_PYTHON3_MIN}" "$(python3 --version 2>/dev/null | awk '{print $2}' || true)"

# The kernel headers a vendor tree needs, and the libraries U-Boot links against.
for h in /usr/include/openssl/evp.h /usr/include/libelf.h /usr/include/zlib.h; do
    [ -f "${h}" ] || say "error: ${h} is missing, so a kernel or U-Boot build that includes it fails here rather than in this image's own build"
done

# A version check passes without libc headers or a linker; compiling proves both,
# natively and for the other architecture.
d="$(mktemp -d)"
printf '#include <stdio.h>\nint main(void){printf("%%zu\\n", sizeof(void *)); return 0;}\n' >"${d}/probe.c"
if gcc -O2 -o "${d}/native" "${d}/probe.c" 2>"${d}/cc.err"; then
    got="$(file -b "${d}/native" 2>/dev/null || true)"
    case "${arch}:${got}" in
    amd64:*x86-64* | arm64:*aarch64*) echo "ok gcc $(gcc -dumpfullversion) links a ${arch} ELF" ;;
    *) say "error: gcc on this ${arch} image produced '${got}', which is not a ${arch} ELF" ;;
    esac
else
    say "error: gcc cannot compile and link a program that includes stdio.h: $(head -n3 "${d}/cc.err" | tr '\n' ' ')"
fi

# On amd64 the aarch64 cross compiler is a package; on arm64 gcc itself is it,
# which is why the Dockerfile installs the cross packages on amd64 only.
if [ "${arch}" = amd64 ]; then
    need aarch64-linux-gnu-gcc
    if aarch64-linux-gnu-gcc -O2 -o "${d}/cross" "${d}/probe.c" 2>"${d}/cross.err"; then
        case "$(file -b "${d}/cross" 2>/dev/null || true)" in
        *aarch64*) echo "ok aarch64-linux-gnu-gcc $(aarch64-linux-gnu-gcc -dumpfullversion) links an arm64 ELF" ;;
        *) say "error: aarch64-linux-gnu-gcc did not produce an arm64 ELF, so this image cannot cross-build a kernel" ;;
        esac
    else
        say "error: aarch64-linux-gnu-gcc cannot compile and link a program that includes stdio.h; the arm64 libc headers are missing: $(head -n3 "${d}/cross.err" | tr '\n' ' ')"
    fi
fi
rm -rf "${d}"

finish toolchain

mkdir -p /etc/mica-build
{
    echo "MICA_BUILD_IMAGE=mica-build-bsp"
    echo "MICA_BUILD_FROM=${MICA_BASE_IMAGE}"
    echo "MICA_BUILD_ARCH=${arch}"
    echo "MICA_BUILD_UBUNTU=${codename}"
    echo "MICA_BUILD_APT_SNAPSHOT=${BSP_APT_INSTANT}"
    echo "MICA_BUILD_GCC=$(gcc -dumpfullversion)"
    echo "MICA_BUILD_GXX=$(g++ -dumpfullversion)"
    echo "MICA_BUILD_CROSS_GCC=$(aarch64-linux-gnu-gcc -dumpfullversion 2>/dev/null || echo none)"
    echo "MICA_BUILD_DTC=$(dtc --version | awk '{print $NF}')"
    echo "MICA_BUILD_MAKE=$(make --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_CMAKE=$(cmake --version | line1 | awk '{print $NF}')"
    echo "MICA_BUILD_PYTHON3=$(python3 --version | awk '{print $2}')"
} >/etc/mica-build/bsp.env
