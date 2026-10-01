# mica-build-env

The build environment of Mica OS: five build-env images. `RULES.md` says what
its releases carry and what each image holds; the rules every Mica repository
follows when it builds are `mica-build-tools:docs/spec/build-rules.md`,
implemented by `mica-build-tools`, which every repository pins by commit.

## Images

Public multi-architecture (amd64, arm64) images in
`ghcr.io/micaoss/mica-build-env`, each tagged with the release that published
it, `<image>.<YYYYMMDD-HHMM>` (for example `rust.20260915-0138`):

| Image | Built on | Adds |
| --- | --- | --- |
| `base` | `debian:trixie-slim` | ca-certificates, git, file, binutils, xz, curl, wget, openssl, jq, dpkg-dev, mmdebstrap, python3 (also as `python`), bun |
| `c` | `base` | build-essential, cmake, pkgconf, autoconf, automake, libtool, ccache |
| `go` | `c` | Go with cgo, `GOTOOLCHAIN=local` |
| `rust` | `c` | rustc, cargo, clippy, rustfmt, std and linker for the other architecture, cargo-nextest, cargo-deny, cargo-shear, typos, dbus-daemon |
| `bsp` | `ubuntu:24.04` | the board toolchain: Ubuntu's gcc 13.3, the aarch64 cross toolchain on amd64, and the kernel, U-Boot and packer build dependencies |

Each image asserts what it promises while it builds and records what it
resolved to in `/etc/mica-build/<image>.env`.

## Using a release

A release carries exactly two assets:

- `mica-build-env.lock` (mica-lock v1, `mica-build-tools:docs/spec/release-lock.md`):
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
  - the toolchain archives (bun, go, rust, rust-std, cargo-nextest, cargo-deny, cargo-shear, typos), by version, sha256 and URL per architecture;
  - the archive snapshots the images install packages from, one row per suite naming the snapshot instant and the sha256 of that suite's signed InRelease: the Debian snapshot (`debian-trixie`, `debian-trixie-updates`, `debian-trixie-security`) of `base`, `c`, `go` and `rust`, and the Ubuntu snapshot (`ubuntu-<suite>`) of `bsp`. Moving a snapshot is an input change: the images built from it are rebuilt, with the security and point-release fixes up to the new instant.
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
2. **build**: builds those natively, amd64 on `ubuntu-26.04` and arm64 on `ubuntu-26.04-arm`, and pushes `<image>.<arch>.<release>`;
3. **merge**: publishes every image as `<image>.<release>`;
4. **assets**: writes and checks the lock, attaches it with `SHA256SUMS`, reads both back anonymously, and notes whether the images changed from the previous release.

Nothing is published from a workstation. `.github/workflows/ci.yml` runs the
gates on every push and pull request and publishes nothing.
`.github/workflows/update.yml` runs `update-pins.sh` on the first of every
month (and by hand); when anything moved and the gates and an amd64 build of
every image pass on the new pins, it commits them to main, cuts a release and
runs `release.yml` on it. bun is not moved: it
moves by hand, with the `packageManager` of mica-build-tools and the TypeScript
repositories.

## Development

The lock rules run in `mica-build-tools`, at the commit `locks/mica-build-tools.pin`
names, through `bin/mica-tools`; it needs bun 1.4.2, which `bin/bun.sh` takes
from the `source bun` row of `locks/upstream.lock`:

```sh
export MICA_BUN="$(bash bin/bun.sh .tmp/bun)"
bash from.sh --check          # locks/upstream.lock and params.env are valid
bash tests/publish-test.sh    # which inputs move which image, every release refusal (no docker)
bash build.sh [<image> ...]   # build localhost/mica-build-<image>:<arch> from the pinned inputs
docker run --rm -v "$PWD:/repo:ro" -w /repo "$(bash from.sh --ref upstream:rhysd/actionlint:1.7.12)"   # lint the workflows
```

| File | Purpose |
| --- | --- |
| `build.sh` | builds the images locally |
| `from.sh`, `pins.sh` | resolve the pinned inputs and the `FROM` of each image |
| `fetch-archives.sh` | gathers the toolchain archives CI caches |
| `update-pins.sh` | moves `locks/upstream.lock` and `locks/mica-build-tools.pin` to upstream's latest releases, measuring every changed row |
| `publish-images.sh` | plans, builds, merges and resolves the published images |
| `publish-release.sh` | writes the lock, then attaches it with `mica-tools release attach` |
| `bin/mica-tools`, `locks/mica-build-tools.pin` | runs the pinned `mica-build-tools`, which checks a lock or `locks/upstream.lock` against mica-lock v1 |
| `bin/bun.sh` | the bun `bin/mica-tools` runs on, from `locks/upstream.lock` |
| `<image>/` | each image's Dockerfile and its fetch and assert scripts |
