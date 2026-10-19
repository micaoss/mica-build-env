# syntax=docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=InvalidDefaultArgInFrom
# mica-build-base -- the floor every Mica OS builder image stands on: the basic
# system tools (ca-certificates, git, file, binutils, xz, curl, wget, openssl,
# jq, the Debian packaging tools, mmdebstrap, python3) and a sha256-pinned bun. mica-build-c builds
# on it. Built by build.sh. On amd64 it also packs for armhf, which has no
# runner of its own: armhf is a dpkg foreign architecture with libc6:armhf and
# libgcc-s1:armhf installed, so dpkg-shlibdeps resolves an armhf binary
# against their symbols files.

# No default: a driver that forgets the argument must fail, not build from a floating tag.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS fetch

COPY inputs.env /etc/mica-build/inputs.env

RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-base-fetch,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-base-fetch,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    bash /tmp/mica-lib/apt-debian.sh ca-certificates curl unzip

ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/mica-fetch,id=mica-fetch-bun,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    --mount=type=bind,from=mica-fetch-seed,target=/tmp/mica-fetch-seed \
    --mount=type=bind,source=fetch.sh,target=/tmp/fetch.sh \
    bash /tmp/fetch.sh

# An armhf ELF that links libc and libgcc_s, for assert.sh to run
# dpkg-shlibdeps on; on any other architecture an empty directory. Its cross
# compiler stays in this stage.
FROM ${MICA_BASE_IMAGE} AS armhf-probe

COPY inputs.env /etc/mica-build/inputs.env

ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-base-probe,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-base-probe,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    mkdir -p /probe; \
    if [ "${TARGETARCH}" = amd64 ]; then \
        bash /tmp/mica-lib/apt-debian.sh gcc-arm-linux-gnueabihf libc6-dev-armhf-cross; \
        printf '#include <stdio.h>\n#include <unwind.h>\nstatic _Unwind_Reason_Code step(struct _Unwind_Context *c, void *n) { (void)c; ++*(int *)n; return _URC_NO_REASON; }\nint main(void) { int n = 0; _Unwind_Backtrace(step, &n); printf("%%d\\n", n); return 0; }\n' >/tmp/probe.c; \
        arm-linux-gnueabihf-gcc -O2 -shared-libgcc -o /probe/probe /tmp/probe.c; \
    fi

FROM ${MICA_BASE_IMAGE} AS base

# The filtered inputs build.sh writes, so unrelated pins and comments in
# locks/upstream.lock and params.env do not invalidate this layer.
COPY inputs.env /etc/mica-build/inputs.env

# The packages come from the Debian archive snapshot locks/upstream.lock pins
# (lib/apt-debian.sh), which also removes docker-clean so the apt cache mount
# keeps the downloaded .debs. openssl is named although ca-certificates pulls it in, so the version that
# mints keys is declared, floored and recorded. The foreign architecture is
# added before apt-debian.sh updates, so the armhf indices of the same snapshot
# are fetched with the native ones.
ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-base,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-base,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    armhf=""; \
    if [ "${TARGETARCH}" = amd64 ]; then \
        dpkg --add-architecture armhf; \
        armhf="libc6:armhf libgcc-s1:armhf"; \
    fi; \
    bash /tmp/mica-lib/apt-debian.sh \
        ca-certificates \
        git \
        file \
        binutils \
        xz-utils \
        curl \
        wget \
        openssl \
        jq \
        dpkg-dev \
        mmdebstrap \
        python3 \
        python-is-python3 \
        ${armhf}

COPY --from=fetch /opt/bun/bin/bun /usr/local/bin/bun

ARG MICA_BASE_IMAGE
RUN --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    --mount=type=bind,from=armhf-probe,source=/probe,target=/tmp/armhf-probe \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-base" \
      org.opencontainers.image.description="Mica OS common build floor: system tools, Debian packaging, mmdebstrap, python3, openssl, jq, bun" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mica.build-env.source="base/Dockerfile" \
      com.mica.build-env.pins="locks/upstream.lock"
