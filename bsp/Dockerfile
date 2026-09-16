# syntax=docker.io/docker/dockerfile:1@sha256:ecfaec9ed6d810b56388c508f4121597bfbba70d41a6dfeee4d8cad5f295fc32
# check=skip=InvalidDefaultArgInFrom
# mica-build-bsp -- the board toolchain: Ubuntu 24.04 with its gcc 13.3, the
# cross toolchain and the packages the kernel, U-Boot and packer stages of
# mica-boards build with. It stands on ubuntu:24.04 and not on mica-build-base,
# because the vendor kernel trees are built with Ubuntu's gcc 13.3 deliberately.
#
# The packages come from the Ubuntu archive snapshot locks/upstream.lock pins,
# installed once here (apt-install.sh); a consumer builds FROM this image by
# digest and reaches no archive at all.
ARG MICA_BASE_IMAGE

FROM ${MICA_BASE_IMAGE} AS final

COPY inputs.env /etc/mica-build/inputs.env

# The package list stays here, beside the FROM that says which image it is
# installed into: it is what this image is. On arm64 Ubuntu ships no
# gcc-aarch64-linux-gnu -- build-essential's own gcc is the aarch64 compiler
# there -- so the cross packages are installed on amd64 only, as mica-boards
# writes it today.
ARG DEBIAN_FRONTEND=noninteractive
ARG TARGETARCH
RUN --mount=type=bind,source=apt-install.sh,target=/tmp/apt-install.sh \
    cross=""; [ "${TARGETARCH}" != amd64 ] || cross="gcc-aarch64-linux-gnu libc6-dev-arm64-cross"; \
    bash /tmp/apt-install.sh \
        autoconf \
        automake \
        bc \
        bison \
        build-essential \
        ca-certificates \
        cmake \
        cpio \
        curl \
        device-tree-compiler \
        flex \
        gawk \
        git \
        gperf \
        kmod \
        libelf-dev \
        libexpat-dev \
        libglib2.0-dev \
        libgmp-dev \
        libgnutls28-dev \
        libmpc-dev \
        libmpfr-dev \
        libslirp-dev \
        libssl-dev \
        libtool \
        ninja-build \
        patch \
        patchutils \
        perl \
        python3 \
        python3-dev \
        python3-pyelftools \
        python3-setuptools \
        python3-tomli \
        rsync \
        swig \
        texinfo \
        uuid-dev \
        vim-common \
        xxd \
        xz-utils \
        zlib1g-dev \
        zstd \
        ${cross}

ARG MICA_BASE_IMAGE
RUN --mount=type=bind,from=mica-lib,target=/tmp/mica-lib \
    --mount=type=bind,source=assert.sh,target=/tmp/assert.sh \
    bash /tmp/assert.sh

LABEL org.opencontainers.image.title="mica-build-bsp" \
      org.opencontainers.image.description="Mica OS board toolchain: Ubuntu 24.04, gcc 13.3, cross toolchain, kernel and U-Boot build dependencies" \
      org.opencontainers.image.base.name="${MICA_BASE_IMAGE}" \
      com.mica.build-env.source="bsp/Dockerfile" \
      com.mica.build-env.pins="locks/upstream.lock"
