# Mica build rules

What every Mica repository follows when it builds, publishes and consumes
artifacts. Each repository implements these rules in its own scripts. The
rules that apply to a release of mica-build-env are this file at its tag.

## 1. Releases of mica-build-env

- A release is tagged with the UTC time it was cut, `YYYYMMDD-HHMM` (for
  example `20260218-1411`), and carries two assets: `mica-build-env.lock` and
  `SHA256SUMS` listing only it. The lock is written when the release is cut,
  in mica-lock v1 (`mica:docs/design/release-lock.md`, checked by
  `check-lock.sh`): the release row, then `image <source> <name> <platform>
  <reference>` rows sorted by source, name and platform:
  - source `mica-build-env`, each build-env image (`base`, `c`, `go`, `rust`):
    `index` as
    `ghcr.io/micaoss/mica-build-env:<image>.<YYYYMMDD-HHMM>@sha256:<64 hex>`,
    and `amd64` and `arm64` as `ghcr.io/micaoss/mica-build-env@sha256:<64 hex>`,
    the platform manifests;
  - source `upstream`, each upstream image of `locks/upstream.lock` (section 2)
    as it is there: its original name and reference, one row per platform the
    release guarantees, each naming the index digest.

  It is not the repository's `locks/upstream.lock`, which pins the images'
  third-party inputs.
- A release is cut by hand with `gh release create <YYYYMMDD-HHMM> --target
  <commit of main>`, which creates the tag on GitHub; no tag is created or
  pushed locally. Publishing then runs only in CI: `release.yml`, triggered by
  `release: published`, builds from the release's tag, publishes the images
  its inputs name, and attaches the assets to that release. Each architecture
  is built natively on its own runner, and a final job merges the
  per-architecture images into the multi-arch index; nothing is emulated. `ci.yml` runs the
  quality gates on push and pull request and publishes nothing.
- A release exists only when every build-env image of its commit is
  published and reads with no credential at the digest its row names. An asset is never replaced, and no
  time-tagged release may be later than the one being attached
  (`publish-release.sh`).
- Once the assets are attached, the release notes gain the comparison of its
  `image` rows with those of the previous release carrying a
  `mica-build-env.lock`:
  "Images: unchanged" or "Images: changed". A release whose images changed
  (a build-env image, an upstream base image, or a toolchain version or hash)
  is a breaking update: every repository must update to it.
- A consumer records the tag and the sha256 of `SHA256SUMS`. It downloads
  from `https://github.com/micaoss/mica-build-env/releases/download/<tag>/` and
  refuses the assets unless `SHA256SUMS` hashes to the recorded value and
  `sha256sum -c SHA256SUMS` passes.
- Each repository pins its own mica-build-env release, in its own tree. Between
  breaking updates, repositories may be on different releases and move to a
  newer one when they choose.
- One repository builds with one release at a time: its images and pins all
  come from the release it pins.
- Consuming another repository's artifact never requires the environment
  that built it: the artifact is checked against its pin (section 5), not
  against the consumer's build-env.

## 2. Images

- Every base image is pinned as `name:tag@sha256:<64 lowercase hex>`, the
  digest of the multi-architecture index; a tag alone or a malformed digest is
  refused. A Dockerfile names no image
  directly: it takes its `FROM` as a build argument with no default.
- A consumer takes the build-env images and the upstream images from the
  `mica-build-env.lock` of the release it pins; an upstream image is read from
  its original registry at the pinned digest, and Mica does not republish it.
- mica-build-env pins its third-party inputs in `locks/upstream.lock`
  (`mica:docs/design/release-lock.md`, 4.1): `image upstream` rows name each
  upstream image by its original name (`debian:trixie-slim`) and reference
  (`docker.io/library/debian:trixie-slim@sha256:<index digest>`), one row per
  platform the release guarantees, and `source` rows each toolchain archive by version,
  sha256 and URL per architecture. Build parameters that are not pins (the
  `*_FLOOR_*_MIN` floors, `LOCAL_MICA_BUILD_*` tags, Rust triples) are in
  `params.env`, which names no image or archive (`pins.sh`).
- The build-env images live in `ghcr.io/micaoss/mica-build-env`, one index
  with amd64 and arm64 (`publish-images.sh`):

  | Row | Image | Adds |
  | --- | --- | --- |
  | `image mica-build-env base` | base, on `debian:trixie-slim` | ca-certificates, git, file, binutils, xz, curl, wget, openssl, jq, dpkg-dev, mmdebstrap, python3 (also as `python`), bun (source `bun`) |
  | `image mica-build-env c` | c, on base | build-essential, cmake, pkgconf, autoconf, automake, libtool, ccache |
  | `image mica-build-env go` | go, on c | Go (source `go`), cgo through c, `GOTOOLCHAIN=local` |
  | `image mica-build-env rust` | rust, on c | rustc, cargo, clippy and rustfmt (source `rust`), std (source `rust-std`) and a linker for the other architecture, cargo-nextest and cargo-deny (sources `cargo-nextest`, `cargo-deny`), dbus-daemon |

- Each release tags every image `<image>.<YYYYMMDD-HHMM>` (for example
  `rust.20260915-0030`), and its lock names that tag. An image that did not
  change keeps its digest under the new release's tag.
- Whether an image is rebuilt is decided by `<image>.inputs-<16 hex>`: a hash of the image's inputs from
  `locks/upstream.lock` and `params.env`, its parent's inputs tag (the
  `debian:trixie-slim` reference for base), its Dockerfile, its
  dockerignore allow-list and `lib/`. An image is rebuilt only when those
  inputs change or its parent is rebuilt, which also rebuilds every image
  built on it; a tag that exists is never re-pointed. Each index is also tagged
  `<image>.build-<commit12>`; the per-architecture sources are
  `<image>.<arch>.build-<commit12>`.
- Each image asserts what it promises while it builds (`<image>/assert.sh`) and
  records what it resolved to in `/etc/mica-build/<image>.env`. Versions
  installed from a sha256-pinned archive are asserted exactly. Versions
  installed from apt are asserted against a floor (`*_FLOOR_*_MIN`), and a
  floor is never lowered to make a build pass.
- `LOCAL_MICA_BUILD_*` keys name the local tags `build.sh` builds before
  publishing. They are not part of the release contract.

## 3. Publishing

- A repository chooses how it publishes what it builds; an OCI package is not
  required. Any of these is a valid transport:
  - a GitHub release of the repository itself;
  - an HTTP server on the build host or network (for example a local apt
    repository);
  - the repository's own public GHCR package, `ghcr.io/micaoss/<repository>`.
- Whatever the transport:
  - an artifact's name says what it is and what built it:
    `<package>_<version>_<arch>.deb` for a Debian package,
    `<repository>-<commit12>.tar.gz` for a source archive;
  - a published name never serves other bytes: nothing is replaced or
    re-pointed, and a changed build gets a new name;
  - the publisher reads back what it published and compares the bytes; a
    release or GHCR package must also read with no credential;
  - the artifact records the repository and full commit that built it (the
    `Mica-Source-Repo` and `Mica-Source-Commit` control fields of a `.deb`,
    the release notes, or the OCI annotations below).
- When the transport is OCI:
  - a tag says what the artifact is: `<kind>[.<name>]*.build-<commit12>`;

    | Kind | Tag | artifactType |
    | --- | --- | --- |
    | source | `<repository>:source.build-<c12>` | `application/vnd.mica.source` |
    | pool | `<repository>:pool.<arch>.build-<c12>` | `application/vnd.mica.pool` |
    | board | `mica-boards:board.<board>.build-<c12>` | `application/vnd.mica.board` |
    | root | `mica-build:root.<product>.build-<c12>` | `application/vnd.mica.root` |

  - a manifest is an OCI image manifest with an empty config, annotated with
    `org.opencontainers.image.revision` (the full commit),
    `org.opencontainers.image.created`, `org.opencontainers.image.source`,
    `mica.source-repo` and `mica.source-commit`, plus `mica.arch` for a pool;
    every layer carries `org.opencontainers.image.title`. A pool has one
    `application/vnd.mica.deb` layer per archive; a source artifact has
    exactly one `application/vnd.mica.source.tar+gzip` layer;
  - a token-endpoint refusal reports its own status (401 or 403); 000 means
    the registry could not be reached.

## 4. Source archives

- A source archive is made by `git -c tar.tar.gz.command='gzip -cn' archive
  --format=tar.gz --prefix=<repository>-<commit12>/ <full commit>`, so one
  commit always gives the same bytes.
- Only a clean tree at HEAD is published. A historical commit additionally
  needs its full 40-hex commit id and the expected 64-hex sha256, must be an
  ancestor of HEAD, and is refused before anything is written when its
  archive does not hash to the expected value.
- A source pin, `deps/sources/<name>.json`, records `name`, `repository`,
  `commit` (40 hex), `path`, `asset`, `sha256`, and where the asset is
  fetched from when that is not the repository's GHCR package.

## 5. Readers

- A reader fetches exactly what a pin names and never follows a "latest" name.
- A reader refuses the bytes unless they hash to the pinned sha256, and
  refuses what they claim to be unless it matches the pin: a `.deb`'s control
  fields, a source archive's top directory, an OCI artifact's artifactType,
  `mica.source-repo`, revision, layers and title.
- A reader reads only the location the pin names. A 401, 403, 404, transport
  failure, wrong identity, corrupt content or hash mismatch stops the read;
  there is no fallback to another location.

## 6. Debian packages

- Versions come from `<VERSION>+git<commit12>[.dirty]-1`, where the number is
  the repository's one-line `VERSION` file. One stamp covers a whole pool, and
  a `.dirty` archive is never published.
- Packing happens inside the target architecture's image, with
  `SOURCE_DATE_EPOCH` required. Every mtime is set to it, ownership is
  `root:root`, and `Installed-Size`, `DEBIAN/md5sums`, `Mica-Source-Repo` and
  `Mica-Source-Commit` are written by the packer; the control template must
  not carry them.
- A pool pin, `deps/packages/<name>.json`, records `name`, `repository`,
  `commit` and, per architecture, `version`, `architecture`, `sha256` and
  `asset`. A fetched archive must match its pin field by field.
- A pool passes these gates:
  - no path is shipped by two archives unless they mutually conflict, and
    `Replaces` is refused;
  - one architecture and one git stamp, and imported archives equal their pins;
  - two builds under one `SOURCE_DATE_EPOCH` are byte-identical;
  - every package ships a non-empty copyright file;
  - enablement symlinks match `ENABLEMENT`;
  - there are no conffiles;
  - maintainer scripts parse as POSIX sh;
  - every archive maps to a producer or a pin;
  - `all` archives are identical across pools.
