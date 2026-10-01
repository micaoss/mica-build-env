# mica-build-env: its releases and its images

The build rules every Mica repository follows are
`mica-build-tools:docs/spec/build-rules.md`, beside the tools that implement
them: releases (1), images (2), publishing (3), source archives (4), readers
(5), Debian packages (6). The release lock is
`mica-build-tools:docs/spec/release-lock.md`.

What follows is this repository's own: what its releases carry, which images
it builds, what each holds, and how they are pinned and rebuilt. The rules
that apply to a release of mica-build-env are the build rules of the
`mica-build-tools` commit its `locks/mica-build-tools.pin` names, and this
file at its tag.

## 1. Releases of mica-build-env

- A release carries `mica-build-env.lock` and `SHA256SUMS` listing only it
  (build rules, section 1). The lock is the release row, then
  `image <source> <name> <platform> <reference>` rows sorted by source, name
  and platform:
  - source `mica-build-env`, each build-env image (`base`, `c`, `go`, `rust`, `bsp`):
    `index` as
    `ghcr.io/micaoss/mica-build-env:<image>.<YYYYMMDD-HHMM>@sha256:<64 hex>`,
    and `amd64` and `arm64` as `ghcr.io/micaoss/mica-build-env@sha256:<64 hex>`,
    the platform manifests;
  - source `upstream`, each upstream image of `locks/upstream.lock` (section 2)
    as it is there: its original name and reference, one row per platform the
    release guarantees, each naming the index digest.

  It is not the repository's `locks/upstream.lock`, which pins the images'
  third-party inputs.
- It is cut with `gh release create <YYYYMMDD-HHMM> --target <commit of
  main>`. `release.yml`, triggered by `release: published`, builds from the
  release's tag, publishes the images its inputs name, and attaches the
  assets. Each architecture is built natively on its own runner, and a final
  job merges the per-architecture images into the multi-arch index; nothing
  is emulated. `ci.yml` runs the quality gates on push and pull request and
  publishes nothing.
- A release exists only when every build-env image of its commit is
  published and reads with no credential at the digest its row names.
- The release notes say "Images: unchanged" or "Images: changed" against the
  previous release. A release whose images changed is a breaking update for
  every repository (build rules, section 1).

## 2. Images

- mica-build-env pins its third-party inputs in `locks/upstream.lock`
  (`mica-build-tools:docs/spec/release-lock.md` 4.1): `image upstream` rows name each
  upstream image by its original name (`debian:trixie-slim`) and reference
  (`docker.io/library/debian:trixie-slim@sha256:<index digest>`), one row per
  platform the release guarantees, and `source` rows each toolchain archive by version,
  sha256 and URL per architecture, plus the rows of the archive snapshots the
  images install packages from (`all`, the instant as the version and the
  sha256 of that suite's signed InRelease): `debian-<suite>` for base, c, go
  and rust, one instant for `trixie`, `trixie-updates` and `trixie-security`,
  and `ubuntu-<suite>` for bsp. No image installs from a live archive. Build parameters that are not pins (the
  `*_FLOOR_*_MIN` floors, `LOCAL_MICA_BUILD_*` tags, Rust triples) are in
  `params.env`, which names no image or archive (`pins.sh`).
- The build-env images live in `ghcr.io/micaoss/mica-build-env`, one index
  with amd64 and arm64 (`publish-images.sh`):

  | Row | Image | Adds |
  | --- | --- | --- |
  | `image mica-build-env base` | base, on `debian:trixie-slim` and the Debian archive snapshot | ca-certificates, git, file, binutils, xz, curl, wget, openssl, jq, dpkg-dev, mmdebstrap, python3 (also as `python`), bun (source `bun`) |
  | `image mica-build-env c` | c, on base | build-essential, cmake, pkgconf, autoconf, automake, libtool, ccache |
  | `image mica-build-env go` | go, on c | Go (source `go`), cgo through c, `GOTOOLCHAIN=local` |
  | `image mica-build-env bsp` | bsp, on `ubuntu:24.04` | Ubuntu's gcc 13.3, the aarch64 cross toolchain on amd64, and the kernel, U-Boot and packer build dependencies of the boards; the Ubuntu archive snapshot is installed once here, so no build of a consumer reaches an archive |
  | `image mica-build-env rust` | rust, on c | rustc, cargo, clippy and rustfmt (source `rust`), std (source `rust-std`) and a linker for the other architecture, cargo-nextest, cargo-deny, cargo-shear and typos (sources `cargo-nextest`, `cargo-deny`, `cargo-shear`, `typos`), dbus-daemon |

- Every tag is the release that published it: each release tags every image
  `<image>.<YYYYMMDD-HHMM>` (for example `rust.20260915-0030`), and its lock
  names that tag; the per-architecture sources are
  `<image>.<arch>.<YYYYMMDD-HHMM>`. No tag carries a hash or a commit.
- An image's inputs are its rows of `locks/upstream.lock` and its keys of
  `params.env`, its parent's inputs (the `debian:trixie-slim` reference for
  base), its Dockerfile, its dockerignore allow-list and `lib/`; their sha256
  is the image label `com.mica.build-env.inputs` on every platform. An image is rebuilt only
  when no release tag of it carries these inputs or its parent is rebuilt,
  which also rebuilds every image built on it; otherwise the new release tags
  the published index, so an unchanged image keeps its digest. A tag that
  exists is never re-pointed.
- Each image asserts what it promises while it builds (`<image>/assert.sh`) and
  records what it resolved to in `/etc/mica-build/<image>.env`. Versions
  installed from a sha256-pinned archive are asserted exactly. Versions
  installed from an archive snapshot are asserted against a floor
  (`*_FLOOR_*_MIN`), and a floor is never lowered to make a build pass.
- `LOCAL_MICA_BUILD_*` keys name the local tags `build.sh` builds before
  publishing. They are not part of the release contract.
