# syntax=docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=InvalidDefaultArgInFrom
# mica-build-c -- the native C and C++ toolchain, on top of mica-build-base;
# mica-build-go and mica-build-rust build on it.
# Component-specific -dev packages belong in the consumer's own stage.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS final

# Replaces the parent's inputs: base's keys are already recorded in base.env.
COPY inputs.env /etc/mica-build/inputs.env

# build-essential rather than a hand-picked list, so libc headers cannot go missing.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-c,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-c,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    bash /tmp/mica-lib/apt-debian.sh \
        build-essential \
        cmake \
        pkgconf \
        autoconf \
        automake \
        libtool \
        ccache

# ccache only survives a layer invalidation if the consumer mounts /ccache as a cache.
ENV CCACHE_DIR=/ccache \
    PATH="/usr/lib/ccache:${PATH}"

ARG MICA_BASE_IMAGE
ARG TARGETARCH
RUN --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-c" \
      org.opencontainers.image.description="Mica OS C/C++ toolchain" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mica.build-env.source="c/Dockerfile" \
      com.mica.build-env.pins="locks/upstream.lock"
