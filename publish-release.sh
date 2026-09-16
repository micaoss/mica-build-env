#!/usr/bin/env bash
# Attach the assets to a published release YYYYMMDD-HHMM (UTC): mica-build-env.lock,
# the mica-lock v1 lock of the release (mica:docs/design/release-lock.md) naming
# the build-env images its tag's inputs name and the upstream images of
# locks/upstream.lock, and
# SHA256SUMS listing only that lock; then add to its notes whether the image rows
# changed from the previous release that carries mica-build-env.lock.
#
#   bash publish-release.sh <YYYYMMDD-HHMM>
#
# Run by the assets job of .github/workflows/release.yml (on release: published,
# GH_TOKEN with contents: write) after its images job succeeded. The release was
# cut with `gh release create <tag> --target <commit>`. Nothing is written unless
# the tag is a UTC time later than every other time-tagged release, names the
# checked-out commit, that commit is on main, the release carries no asset yet,
# and every image is published and reads with no credential. A change in the
# images is a breaking update.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${MICA_RELEASE_REPO:-micaoss/mica-build-env}"
NAME="${REPO##*/}"

for t in gh git docker curl jq sha256sum date; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required and not on PATH" >&2; exit 1; }
done

[ "$#" -eq 1 ] || { echo "usage: bash publish-release.sh <YYYYMMDD-HHMM>" >&2; exit 1; }
TAG="$1"
[[ "${TAG}" =~ ^[0-9]{8}-[0-9]{4}$ ]] &&
    [ "$(date -u -d "${TAG:0:8} ${TAG:9:2}:${TAG:11:2}" +%Y%m%d-%H%M 2>/dev/null)" = "${TAG}" ] || {
    echo "error: the tag '${TAG}' is not a UTC time YYYYMMDD-HHMM; nothing was attached" >&2
    exit 1
}
[ "${TAG/-/}" -le "$(date -u +%Y%m%d%H%M)" ] || {
    echo "error: the tag ${TAG} is a time in the future; nothing was attached" >&2
    exit 1
}
HEAD="$(git -C "${HERE}" rev-parse HEAD)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${WORK}/assets" "${WORK}/download" "${WORK}/previous"

# gh_status <path>: the HTTP status of a GET; the body goes to ${WORK}/body.
gh_status() {
    if gh api "$1" >"${WORK}/body" 2>"${WORK}/err"; then
        echo 200
    else
        codes="$(sed -n 's/.*(HTTP \([0-9]*\)).*/\1/p' "${WORK}/err")"
        printf '%s\n' "${codes%%$'\n'*}"
    fi
}

# The release's tag names exactly this commit, on main.
case "$(gh_status "repos/${REPO}/git/ref/tags/${TAG}")" in
200) ;;
404) echo "error: ${TAG} does not exist in ${REPO}; cut the release with gh release create ${TAG} --target <commit>; nothing was attached" >&2; exit 1 ;;
*) echo "error: could not read ${TAG} in ${REPO}: $(cat "${WORK}/err")" >&2; exit 1 ;;
esac
tagged="$(jq -r 'select(.object.type == "commit") | .object.sha' "${WORK}/body")"
[ "${tagged}" = "${HEAD}" ] || {
    echo "error: ${TAG} names '${tagged:-a non-commit object}', not the checked-out commit ${HEAD}; nothing was attached" >&2
    exit 1
}
git -C "${HERE}" merge-base --is-ancestor "${HEAD}" origin/main 2>/dev/null || {
    echo "error: ${HEAD} is not on origin/main; a release is cut from a commit of main; nothing was attached" >&2
    exit 1
}

# The release is published and carries nothing yet: an asset is never replaced.
case "$(gh_status "repos/${REPO}/releases/tags/${TAG}")" in
200) ;;
404) echo "error: ${TAG} has no published release; cut it with gh release create ${TAG} --target <commit>; nothing was attached" >&2; exit 1 ;;
*) echo "error: could not read the release ${TAG}: $(cat "${WORK}/err")" >&2; exit 1 ;;
esac
cp "${WORK}/body" "${WORK}/release.json"
[ "$(jq -r '.assets | length' "${WORK}/release.json")" = 0 ] || {
    echo "error: the release ${TAG} already carries $(jq -r '[.assets[].name] | join(", ")' "${WORK}/release.json"); an asset is never replaced; nothing was attached" >&2
    exit 1
}

[ -z "$(git -C "${HERE}" status --porcelain)" ] || {
    echo "error: ${HERE} has uncommitted changes; the lock names the images of the tagged commit, so it is generated from a clean one" >&2
    exit 1
}
bash "${HERE}/from.sh" --check

# No time-tagged release may be later; the previous one is the latest earlier release carrying a lock.
gh release list --repo "${REPO}" --limit 1000 --json tagName --jq '.[].tagName' |
    { grep -xE '[0-9]{8}-[0-9]{4}' || true; } | { grep -vx "${TAG}" || true; } | sort >"${WORK}/releases"
later="$(awk -v t="${TAG}" '$0 > t' "${WORK}/releases" | tail -n1)"
[ -z "${later}" ] || {
    echo "error: the release ${later} is later than ${TAG}; nothing was attached" >&2
    exit 1
}
LOCK="${NAME}.lock"
previous=""
while read -r t; do
    case "$(gh_status "repos/${REPO}/releases/tags/${t}")" in
    200) jq -r '.assets[].name' "${WORK}/body" | grep -cx "${LOCK}" >/dev/null && { previous="${t}"; break; } ;;
    *) echo "error: could not read the release ${t}: $(cat "${WORK}/err"); nothing was attached" >&2; exit 1 ;;
    esac
done < <(sort -r "${WORK}/releases")

# The rows: the images this commit's inputs name, each read back with no
# credential at its digest, and the upstream image rows of locks/upstream.lock
# as they are (this repository does not republish them).
bash "${HERE}/publish-images.sh" --resolve "${TAG}" --out "${WORK}/images.rows" || {
    echo "error: the build-env images of ${HEAD} are not all published; the images job publishes them for ${TAG}; nothing was attached" >&2
    exit 1
}
check="$(bash "${HERE}/check-lock.sh" upstream "${HERE}/locks/upstream.lock")" || {
    echo "error: locks/upstream.lock at ${HEAD} is ${check}; nothing was attached" >&2
    exit 1
}
grep "^image$(printf '\t')upstream$(printf '\t')" "${HERE}/locks/upstream.lock" >"${WORK}/upstream.rows" || {
    echo "error: locks/upstream.lock at ${HEAD} names no upstream image; nothing was attached" >&2
    exit 1
}
# mica-lock v1: the release row, then the image rows sorted by source, name and platform as bytes.
{
    echo "# mica-lock v1"
    printf 'release\t%s\t%s\t%s\n' "${NAME}" "${TAG}" "${HEAD}"
    cat "${WORK}/images.rows" "${WORK}/upstream.rows" | LC_ALL=C sort -t "$(printf '\t')" -k2,2 -k3,3 -k4,4
} >"${WORK}/assets/${LOCK}"
check="$(bash "${HERE}/check-lock.sh" lock "${WORK}/assets/${LOCK}")" || {
    echo "error: the lock written for ${TAG} is ${check}; nothing was attached" >&2
    exit 1
}

if [ -z "${previous}" ]; then
    images_note="Images: the first release."
else
    curl -fsSL --retry 3 --retry-delay 2 -o "${WORK}/previous/${LOCK}" "https://github.com/${REPO}/releases/download/${previous}/${LOCK}" || {
        echo "error: the ${LOCK} of the previous release ${previous} could not be read, so whether the images changed is unknown; nothing was attached" >&2
        exit 1
    }
    # Compared by digest: every release tags its images anew, so the tags always differ.
    if cmp -s <(grep '^image' "${WORK}/previous/${LOCK}" | sed -E 's/:[A-Za-z0-9._-]+@sha256:/@sha256:/') \
        <(grep '^image' "${WORK}/assets/${LOCK}" | sed -E 's/:[A-Za-z0-9._-]+@sha256:/@sha256:/'); then
        images_note="Images: unchanged from ${previous}."
    else
        images_note="Images: changed from ${previous}. This is a breaking update: every repository must update to it."
    fi
fi

(cd "${WORK}/assets" && sha256sum "${LOCK}" >SHA256SUMS)

gh release upload "${TAG}" --repo "${REPO}" \
    "${WORK}/assets/${LOCK}" "${WORK}/assets/SHA256SUMS"

for f in "${LOCK}" SHA256SUMS; do
    curl -fsSL --retry 3 --retry-delay 2 -o "${WORK}/download/${f}" "https://github.com/${REPO}/releases/download/${TAG}/${f}"
    cmp -s "${WORK}/assets/${f}" "${WORK}/download/${f}" || {
        echo "error: the published ${f} of ${TAG} is not the file that was uploaded" >&2
        exit 1
    }
done
(cd "${WORK}/download" && sha256sum -c --quiet SHA256SUMS)

body="$(jq -r '.body // ""' "${WORK}/release.json")"
gh release edit "${TAG}" --repo "${REPO}" \
    --notes "${body:+${body}

}${NAME} ${HEAD}: ${LOCK} (mica-lock v1) names its build-env images and the upstream images they build on. Verify with SHA256SUMS. ${images_note}"

echo "publish-release: ${TAG} at ${HEAD} carries its assets and reads anonymously. ${images_note}"
echo "tag=${TAG}"
echo "sha256sums=$(sha256sum "${WORK}/download/SHA256SUMS" | cut -d' ' -f1)"
cat "${WORK}/download/${LOCK}"
