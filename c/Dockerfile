# syntax=docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=InvalidDefaultArgInFrom
# mica-build-c -- the native C and C++ toolchain, on top of mica-build-base;
# mica-build-go and mica-build-rust build on it. On amd64 it also cross-compiles
# C for armhf, which has no native runner: the arm-linux-gnueabihf gcc,
# binutils, libc and kernel UAPI headers, armhf as a dpkg foreign architecture so a consumer can
# install armhf -dev packages beside them, and pkgconf:armhf for
# arm-linux-gnueabihf-pkg-config.
# Component-specific -dev packages belong in the consumer's own stage.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS final

# Replaces the parent's inputs: base's keys are already recorded in base.env.
COPY inputs.env /etc/mica-build/inputs.env

# build-essential rather than a hand-picked list, so libc headers cannot go missing.
# The foreign architecture is added before apt-debian.sh updates, so the armhf
# indices of the same snapshot are fetched with the native ones.
ARG TARGETARCH
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-c,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-c,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    cross=""; \
    if [ "${TARGETARCH}" = amd64 ]; then \
        dpkg --add-architecture armhf; \
        cross="gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf libc6-dev-armhf-cross linux-libc-dev-armhf-cross pkgconf:armhf"; \
    fi; \
    bash /tmp/mica-lib/apt-debian.sh \
        build-essential \
        cmake \
        pkgconf \
        autoconf \
        automake \
        libtool \
        ccache \
        ${cross}

# ccache only survives a layer invalidation if the consumer mounts /ccache as a cache.
ENV CCACHE_DIR=/ccache \
    PATH="/usr/lib/ccache:${PATH}"

ARG MICA_BASE_IMAGE
RUN --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-c" \
      org.opencontainers.image.description="Mica OS C/C++ toolchain" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mica.build-env.source="c/Dockerfile" \
      com.mica.build-env.pins="locks/upstream.lock"
