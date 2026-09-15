# mica-build-env

The build environment of Mica OS: the build-env images and `RULES.md` (the
rules every Mica repository implements in its own scripts).

**Images.** Public multi-architecture (amd64, arm64) images in
`ghcr.io/micaoss/mica-build-env`:

| Row | Image | Adds |
| --- | --- | --- |
| `image mica-build-env base` | base, on Debian trixie | git, file, binutils, xz, curl, wget, openssl, jq, dpkg-dev, mmdebstrap, python3 (also as `python`), bun |
| `image mica-build-env c` | c, on base | build-essential, cmake, pkgconf, autotools, libtool, ccache |
| `image mica-build-env go` | go, on c | Go, cgo |
| `image mica-build-env rust` | rust, on c | rustc, cargo, cross std and linker, clippy, rustfmt, cargo-nextest, cargo-deny, dbus-daemon |

`locks/upstream.lock` pins every third-party input: the upstream images Mica
OS uses (the Debian base, the Dockerfile frontend, CI tools) by their original
reference and index digest, and the toolchain archives by sha256. These images
build from those references. `params.env` holds the build parameters that are not pins:
version floors, local tags and Rust triples. Every image is tagged with the
release that published it, `<image>.<YYYYMMDD-HHMM>` (for example
`rust.20260915-0030`); only a changed input rebuilds an image, and an unchanged
one keeps its digest under the new release's tag.

**Releases.** A release is tagged with the UTC time it was cut, `YYYYMMDD-HHMM`
(for example `20260218-1411`), and cut by hand:

```sh
gh release create "$(date -u +%Y%m%d-%H%M)" --target <commit of main> --title "$(date -u +%Y%m%d-%H%M)" --notes ""
```

That creates the tag on GitHub and triggers `.github/workflows/release.yml`,
which builds from the tag: its plan job lists the images no release has published
with these inputs, one build job per architecture builds them natively (amd64 on
`ubuntu-24.04`, arm64 on `ubuntu-24.04-arm`), the merge job publishes every image
as `<image>.<release>`, then its assets job attaches `mica-build-env.lock` (mica-lock v1:
the release row, the `image mica-build-env` rows of the four images and the
`image upstream` rows of `locks/upstream.lock`)
and `SHA256SUMS` listing only it, and adds to the notes whether
the images changed from the previous release (a change is a breaking update).
`.github/workflows/ci.yml` runs the gates below on push and pull request and
publishes nothing. A consumer pins the tag and the sha256 of `SHA256SUMS`.

```sh
bash from.sh --check                              # locks/upstream.lock and params.env
bash publish-images.sh --resolve <release> --out images.out   # the images a release tagged, if published
bash tests/publish-test.sh                        # the lock vectors, which inputs move which image, every release refusal
docker run --rm -v "$PWD:/repo:ro" -w /repo "$(bash from.sh --ref upstream:rhysd/actionlint:1.7.12)"   # the workflows
```
