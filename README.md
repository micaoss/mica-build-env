# mica-build-env

The build environment of Mica OS: five build-env images and `RULES.md`, the
rules every Mica repository implements in its own scripts.

## Images

Public multi-architecture (amd64, arm64) images in
`ghcr.io/micaoss/mica-build-env`, each tagged with the release that published
it, `<image>.<YYYYMMDD-HHMM>` (for example `rust.20260915-0138`):

| Image | Built on | Adds |
| --- | --- | --- |
| `base` | `debian:trixie-slim` | ca-certificates, git, file, binutils, xz, curl, wget, openssl, jq, dpkg-dev, mmdebstrap, python3 (also as `python`), bun |
| `c` | `base` | build-essential, cmake, pkgconf, autoconf, automake, libtool, ccache |
| `go` | `c` | Go with cgo, `GOTOOLCHAIN=local` |
| `rust` | `c` | rustc, cargo, clippy, rustfmt, std and linker for the other architecture, cargo-nextest, cargo-deny, dbus-daemon |
| `bsp` | `ubuntu:24.04` | the board toolchain: Ubuntu's gcc 13.3, the aarch64 cross toolchain on amd64, and the kernel, U-Boot and packer build dependencies |

Each image asserts what it promises while it builds and records what it
resolved to in `/etc/mica-build/<image>.env`.

## Using a release

A release carries exactly two assets:

- `mica-build-env.lock` (mica-lock v1, `mica:docs/design/release-lock.md`):
  - the release row;
  - `image mica-build-env <image> <index|amd64|arm64> ghcr.io/micaoss/mica-build-env...@sha256:...` for the five images;
  - `image upstream <name> <platform> <reference>` for every third-party image Mica OS uses, with its original name and reference (for example `docker.io/library/debian:trixie-slim@sha256:...`).
- `SHA256SUMS`, listing only the lock.

A consumer commits the lock unchanged as `locks/mica-build-env.lock` and records
the release in `locks/pins/mica-build-env.pin`:

```text
# mica-pin v1
REPOSITORY=mica-build-env
RELEASE=<YYYYMMDD-HHMM>
SHA256SUMS=<sha256 of that release's SHA256SUMS>
```

It takes every build-env and third-party image only from the lock's rows, and
refuses the assets unless `SHA256SUMS` hashes to the pinned value and
`sha256sum -c SHA256SUMS` passes. A release whose notes say "Images: changed"
is a breaking update.

## Inputs

- `locks/upstream.lock` pins every third-party input:
  - the upstream images, by original reference and index digest, one row per platform a release guarantees;
  - the toolchain archives (bun, go, rust, rust-std, cargo-nextest, cargo-deny), by version, sha256 and URL per architecture;
  - the Ubuntu archive snapshot `bsp` installs from: one `ubuntu-<suite>` row per suite, naming the snapshot instant and the sha256 of that suite's signed InRelease. They are inputs of `bsp` alone and are read only while that image is built, never by a consumer.
- `params.env` holds the build parameters that are not pins: version floors, local tags and Rust triples.

An image's inputs are its rows and keys from those two files, its parent's
inputs, its Dockerfile, the scripts it mounts and `lib/`. Their sha256 is the
image label `com.mica.build-env.inputs`. A release rebuilds an image only when
no published release of it carries these inputs, or its parent is rebuilt;
otherwise it tags the published image, which keeps its digest.

## Releasing

A release is tagged with the UTC time it is cut, and only from a commit of
`main`:

```sh
gh release create "$(date -u +%Y%m%d-%H%M)" --target <commit of main> --title "$(date -u +%Y%m%d-%H%M)" --notes ""
```

That triggers `.github/workflows/release.yml`, which builds from the tag:

1. **plan**: lists which images need building and which are already published with these inputs;
2. **build**: builds those natively, amd64 on `ubuntu-24.04` and arm64 on `ubuntu-24.04-arm`, and pushes `<image>.<arch>.<release>`;
3. **merge**: publishes every image as `<image>.<release>`;
4. **assets**: writes and checks the lock, attaches it with `SHA256SUMS`, reads both back anonymously, and notes whether the images changed from the previous release.

Nothing is published from a workstation. `.github/workflows/ci.yml` runs the
gates on every push and pull request and publishes nothing.

## Development

```sh
bash from.sh --check          # locks/upstream.lock and params.env are valid
bash tests/publish-test.sh    # lock vectors, which inputs move which image, every release refusal (no network)
bash build.sh [<image> ...]   # build localhost/mica-build-<image>:<arch> from the pinned inputs
docker run --rm -v "$PWD:/repo:ro" -w /repo "$(bash from.sh --ref upstream:rhysd/actionlint:1.7.12)"   # lint the workflows
```

| File | Purpose |
| --- | --- |
| `build.sh` | builds the images locally |
| `from.sh`, `pins.sh` | resolve the pinned inputs and the `FROM` of each image |
| `fetch-archives.sh` | gathers the toolchain archives CI caches |
| `publish-images.sh` | plans, builds, merges and resolves the published images |
| `publish-release.sh` | writes the lock and attaches the release assets |
| `check-lock.sh` | checks a lock or `locks/upstream.lock` against mica-lock v1 |
| `<image>/` | each image's Dockerfile and its fetch and assert scripts |
