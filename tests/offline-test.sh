#!/usr/bin/env bash
# The offline release offline.sh wrote to _out/offline/ (make offline first):
# the pinned mica-build-tools take it as an offline pin in a consumer and
# resolve every image to its `local` reference; the layout is whole; docker
# loads it and runs each image by its name and index digest. The refusals under
# CI and on a dirty tree run against a copy of this tree.
#
#   bash tests/offline-test.sh      (docker; bun 1.4.2 as MICA_BUN or on PATH,
#                                    see bin/bun.sh)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
NAME=mica-build-env
OUT="${REPO}/_out/offline"
for t in docker git jq tar; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required" >&2; exit 1; }
done
[ -f "${OUT}/SHA256SUMS" ] || { echo "error: ${OUT}/SHA256SUMS does not exist; run make offline first" >&2; exit 1; }
WORK="$(mktemp -d)"
LOADED=()
cleanup() {
    [ "${#LOADED[@]}" -eq 0 ] || docker image rm "${LOADED[@]}" >/dev/null 2>&1 || true
    rm -rf "${WORK}"
}
trap cleanup EXIT
PASS_N=0
FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $1"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $1"; }
IMAGES=(base c go rust bsp)

# ------------------------------------------------------------ the pinned tools in a consumer
C="${WORK}/consumer"
mkdir -p "${C}/locks" "${C}/repos/git"
cp -r "${REPO}/bin" "${C}/"
cp "${REPO}/locks/mica-build-tools.pin" "${C}/locks/"
cp -r "${REPO}/repos/git/mica-build-tools.git" "${C}/repos/git/"
if (cd "${C}" && env -u CI -u GITHUB_ACTIONS bin/mica-tools local-lock "${NAME}" "${REPO}") >"${WORK}/local-lock.log" 2>&1; then
    pass "mica-tools local-lock takes _out/offline as the offline pin of ${NAME}"
else
    fail "mica-tools local-lock refused _out/offline: $(cat "${WORK}/local-lock.log")"
fi
if cmp -s "${C}/locks/${NAME}.lock" "${OUT}/${NAME}.lock"; then
    pass "the consumer's locks/${NAME}.lock is the offline lock"
else
    fail "the consumer's locks/${NAME}.lock is not the offline lock"
fi
for name in "${IMAGES[@]}"; do
    want="$(awk -F'\t' -v n="${name}" '$1 == "image" && $2 == "'"${NAME}"'" && $3 == n && $4 == "index" {print $5}' "${OUT}/${NAME}.lock")"
    got="$(cd "${C}" && bin/mica-tools from --ref "${NAME}:${name}" 2>&1)" || got="refused: ${got}"
    if [ -n "${want}" ] && [ "${got}" = "${want}" ] && [[ "${got}" == "local/${NAME}:${name}.offline@sha256:"* ]]; then
        pass "from --ref ${NAME}:${name} resolves to ${got}"
    else
        fail "from --ref ${NAME}:${name} resolves to '${got}', the lock names '${want}'"
    fi
done

# ------------------------------------------------------------ the layout is whole
# Every blob index.json reaches is in oci/ and hashes to its name; no other blob is.
B="${OUT}/oci/blobs/sha256"
reached() {
    local d="$1" kind
    echo "${d#sha256:}"
    kind="$(jq -r '.mediaType // ""' "${B}/${d#sha256:}" 2>/dev/null || true)"
    case "${kind}" in
    application/vnd.oci.image.index.v1+json) for m in $(jq -r '.manifests[].digest' "${B}/${d#sha256:}"); do reached "${m}"; done ;;
    application/vnd.oci.image.manifest.v1+json) jq -r '.config.digest, .layers[].digest | sub("^sha256:"; "")' "${B}/${d#sha256:}" ;;
    esac
}
if [ "$(jq -r .imageLayoutVersion "${OUT}/oci/oci-layout")" = 1.0.0 ] &&
    for d in $(jq -r '.manifests[].digest' "${OUT}/oci/index.json"); do reached "${d}"; done | sort -u >"${WORK}/reached" &&
    find "${B}" -type f -printf '%f\n' | sort >"${WORK}/held" && cmp -s "${WORK}/reached" "${WORK}/held" &&
    (cd "${B}" && for f in *; do printf '%s  %s\n' "${f}" "${f}"; done | sha256sum -c --quiet); then
    pass "oci/ holds every blob its index.json reaches, each hashing to its name, and no other"
else
    fail "oci/ is not a whole layout: $(diff "${WORK}/reached" "${WORK}/held" | sed -n '1,5p')"
fi

# ------------------------------------------------------------ docker reads the layout
if tar -C "${OUT}/oci" -cf - . | docker load >"${WORK}/load.log" 2>&1; then
    pass "docker load reads _out/offline/oci"
else
    fail "docker load refused _out/offline/oci: $(cat "${WORK}/load.log")"
fi
arch="$(awk -F'\t' '$1 == "image" && $2 == "'"${NAME}"'" && $4 != "index" {print $4; exit}' "${OUT}/${NAME}.lock")"
for name in "${IMAGES[@]}"; do
    ref="local/${NAME}:${name}.offline"
    LOADED+=("${ref}")
    index="$(awk -F'\t' -v n="${name}" '$1 == "image" && $2 == "'"${NAME}"'" && $3 == n && $4 == "index" {sub(/.*@/, "", $5); print $5}' "${OUT}/${NAME}.lock")"
    platform="$(awk -F'\t' -v n="${name}" -v a="${arch}" '$1 == "image" && $2 == "'"${NAME}"'" && $3 == n && $4 == a {sub(/.*@/, "", $5); print $5}' "${OUT}/${NAME}.lock")"
    id="$(docker image inspect --format '{{.Id}}' "${ref}" 2>/dev/null || true)"
    if [ "${id}" = "${index}" ]; then
        pass "${ref} is loaded as ${index}"
    else
        fail "${ref} is loaded as '${id}', the lock names ${index}"
    fi
    listed="$(jq -r --arg a "${arch}" '.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a) | .digest' "${B}/${index#sha256:}")"
    if [ "${listed}" = "${platform}" ]; then
        pass "the index of ${name} lists ${platform} as its linux/${arch} manifest"
    else
        fail "the index of ${name} lists '${listed}' as its linux/${arch} manifest, the lock names ${platform}"
    fi
    # docker resolves a digest to the image index it loaded, not to a manifest inside it.
    if docker run --rm --label ai-agent=true --platform "linux/${arch}" "${ref}@${index}" test -s "/etc/mica-build/${name}.env" &&
        [ "$(docker run --rm --label ai-agent=true "${ref}" uname -m)" = "$(uname -m)" ]; then
        pass "${ref}@${index} runs and holds /etc/mica-build/${name}.env"
    else
        fail "${ref}@${index} does not run or holds no /etc/mica-build/${name}.env"
    fi
done

# ------------------------------------------------------------ refusals
BE="${WORK}/repo"
mkdir -p "${BE}"
(cd "${REPO}" && git ls-files -co --exclude-standard -z | tar -cf - --null --no-recursion -T -) | tar -xf - -C "${BE}"
g() { git -C "${BE}" -c user.name=test -c user.email=test@example.invalid "$@"; }
g init -q -b main
g add -A
g commit -q -m fixture
for v in CI GITHUB_ACTIONS; do
    if env "${v}=true" bash "${BE}/offline.sh" >"${WORK}/ci.log" 2>&1; then
        fail "offline.sh ran with ${v}=true"
    elif grep -q 'never built under CI' "${WORK}/ci.log"; then
        pass "offline.sh refuses with ${v}=true"
    else
        fail "offline.sh failed with ${v}=true for another reason: $(cat "${WORK}/ci.log")"
    fi
done
echo dirty >>"${BE}/README.md"
if env -u CI -u GITHUB_ACTIONS bash "${BE}/offline.sh" >"${WORK}/dirty.log" 2>&1; then
    fail "offline.sh ran on a dirty tree"
elif grep -q 'uncommitted changes' "${WORK}/dirty.log"; then
    pass "offline.sh refuses a dirty tree"
else
    fail "offline.sh failed on a dirty tree for another reason: $(cat "${WORK}/dirty.log")"
fi
if [ ! -e "${BE}/_out" ]; then
    pass "a refused offline.sh writes no _out"
else
    fail "a refused offline.sh wrote ${BE}/_out"
fi

echo "offline-test: ${PASS_N} passed, ${FAIL_N} failed"
[ "${FAIL_N}" = 0 ]
