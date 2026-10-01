# syntax=docker.io/docker/dockerfile:1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# check=skip=InvalidDefaultArgInFrom
# mica-build-base -- the floor every Mica OS builder image stands on: the basic
# system tools (ca-certificates, git, file, binutils, xz, curl, wget, openssl,
# jq, the Debian packaging tools, mmdebstrap, python3) and a sha256-pinned bun. mica-build-c builds
# on it. Built by build.sh.

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

FROM ${MICA_BASE_IMAGE} AS base

# The filtered inputs build.sh writes, so unrelated pins and comments in
# locks/upstream.lock and params.env do not invalidate this layer.
COPY inputs.env /etc/mica-build/inputs.env

# The packages come from the Debian archive snapshot locks/upstream.lock pins
# (lib/apt-debian.sh), which also removes docker-clean so the apt cache mount
# keeps the downloaded .debs. openssl is named although ca-certificates pulls it in, so the version that
# mints keys is declared, floored and recorded.
RUN --mount=type=cache,target=/var/cache/apt,id=apt-cache-mica-build-base,sharing=locked \
    --mount=type=cache,target=/var/lib/apt/lists,id=apt-lists-mica-build-base,sharing=locked \
    --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
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
        python-is-python3

COPY --from=fetch /opt/bun/bin/bun /usr/local/bin/bun

ARG MICA_BASE_IMAGE
ARG TARGETARCH
RUN --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-base" \
      org.opencontainers.image.description="Mica OS common build floor: system tools, Debian packaging, mmdebstrap, python3, openssl, jq, bun" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mica.build-env.source="base/Dockerfile" \
      com.mica.build-env.pins="locks/upstream.lock"
