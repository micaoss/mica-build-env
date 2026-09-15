#!/usr/bin/env bash
# publish-images.sh, check-lock.sh, pins.sh, from.sh, fetch-archives.sh and
# publish-release.sh against a copy of this tree, with gh, docker and curl
# replaced by stubs: the specification's lock and upstream vectors and the
# image-row source rules, the refusals of locks/upstream.lock and params.env,
# which inputs move which image, the mica-build-env.lock a release writes, and
# every refusal of a release before anything is written.
#
#   bash tests/publish-test.sh      (no network, no docker)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
for t in git sha256sum tar jq; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
PASS_N=0
FAIL_N=0
pass() { PASS_N=$((PASS_N + 1)); echo "PASS: $1"; }
fail() { FAIL_N=$((FAIL_N + 1)); echo "FAIL: $1"; }
says() { grep -c -- "$2" "$1" >/dev/null; }
TAB="$(printf '\t')"

# ------------------------------------------------------------ a copy of this tree
BE="${WORK}/repo"
mkdir -p "${BE}"
(cd "${REPO}" && git ls-files -co --exclude-standard -z | tar -cf - --null --no-recursion -T -) | tar -xf - -C "${BE}"
g() { git -C "${BE}" -c user.name=test -c user.email=test@example.invalid "$@"; }
g init -q -b main
g add -A
g commit -q -m fixture

# ------------------------------------------------------------ stubs
# docker is a registry in ${STUB_REG}: blobs/<digest> holds manifest bytes, and
# `imagetools inspect [--raw]` answers from it; a build-env `<image>.inputs-*` tag
# that is published (any with STUB_ALL=1, else those listed in STUB_PUBLISHED)
# is an index generated from its tag, so a changed tag changes its children's
# inputs as a real one does.
STUBS="${WORK}/stubs"
LOG="${WORK}/calls"
UP="${WORK}/uploaded"
PUBLISHED="${WORK}/published"
REG="${WORK}/registry"
mkdir -p "${STUBS}" "${UP}" "${REG}/blobs"
: >"${PUBLISHED}"
cat >"${STUBS}/mkindex" <<'STUB'
#!/usr/bin/env bash
# mkindex <label> <platforms>: store an index of one manifest per platform; print its digest.
set -euo pipefail
entries=""
for p in ${2//,/ }; do
    m="$(printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","label":"%s","arch":"%s"}' "$1" "$p")"
    # A platform manifest ends in a newline, as Docker Hub's do: the digest covers it.
    d="sha256:$(printf '%s\n' "${m}" | sha256sum | cut -d' ' -f1)"
    printf '%s\n' "${m}" >"${STUB_REG}/blobs/${d}"
    entries="${entries:+${entries},}$(printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","platform":{"os":"linux","architecture":"%s"}}' "${d}" "${p}")"
done
i="$(printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}' "${entries}")"
d="sha256:$(printf '%s' "${i}" | sha256sum | cut -d' ' -f1)"
printf '%s' "${i}" >"${STUB_REG}/blobs/${d}"
echo "${d}"
STUB
cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"${STUB_LOG}"
[ -z "${STUB_DOCKER_FAIL-}" ] || exit 1
[ "$1 $2" = "buildx imagetools" ] || { echo "stub docker: unexpected $*" >&2; exit 2; }
resolve() { # resolve <ref>: the digest it names, or fail
    local ref="$1" tag
    case "${ref}" in *@sha256:*) [ -f "${STUB_REG}/blobs/${ref##*@}" ] && echo "${ref##*@}"; return ;; esac
    tag="${ref##*:}"
    case "${tag}" in
    *.inputs-*)
        [ -n "${STUB_ALL-}" ] || grep -cx "${tag}" "${STUB_PUBLISHED}" >/dev/null || return 1
        mkindex "${tag}" "${STUB_PLATFORMS:-amd64,arm64}" ;;
    *) return 1 ;;
    esac
}
case "$3" in
inspect)
    if [ "$4" = --raw ]; then
        d="$(resolve "$5")" || exit 1
        cat "${STUB_REG}/blobs/${d}"
    else
        d="$(resolve "$4")" || exit 1
        printf 'Name: %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest: %s\n' "$4" "${d}"
    fi ;;
*) echo "stub docker: unexpected $*" >&2; exit 2 ;;
esac
STUB
cat >"${STUBS}/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"${STUB_LOG}"
case "$1 $2" in
api\ repos/*/git/ref/tags/*)
    if [ -n "${STUB_GH_ERR-}" ]; then echo "gh: Bad Gateway (${STUB_GH_ERR})" >&2; exit 1; fi
    if [ -n "${STUB_TAG_SHA-}" ]; then printf '{"object":{"type":"commit","sha":"%s"}}\n' "${STUB_TAG_SHA}"; exit 0; fi
    echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1 ;;
api\ repos/*/releases/tags/*)
    # The release being attached (STUB_TAG_UP) carries STUB_ASSETS; an earlier one
    # carries mica-build-env.lock when listed in STUB_LOCK_TAGS, else the old asset.
    tag="${2##*/}"
    if [ "${tag}" = "${STUB_TAG_UP}" ]; then
        [ -z "${STUB_NO_RELEASE-}" ] || { echo '{"message":"Not Found"}'; echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
        assets="${STUB_ASSETS-}"
    elif printf ' %s ' "${STUB_LOCK_TAGS-}" | grep -c " ${tag} " >/dev/null; then
        assets="mica-build-env.lock SHA256SUMS"
    else
        assets="build-env-image.lock SHA256SUMS"
    fi
    jq -n --arg body "${STUB_BODY-}" --arg assets "${assets}" '{body: $body, assets: [$assets | split(" ")[] | select(. != "") | {name: .}]}' ;;
"release list") printf '%s\n' ${STUB_RELEASES-} ;;
"release upload")
    for a in "$@"; do [ -f "${a}" ] && cp "${a}" "${STUB_UP}/"; done
    exit 0 ;;
"release edit") exit 0 ;;
*) echo "stub gh: unexpected $*" >&2; exit 2 ;;
esac
STUB
cat >"${STUBS}/curl" <<'STUB'
#!/usr/bin/env bash
# Serves a previous release's lock (STUB_PREV_TAG, STUB_PREV_LOCK) and what
# `gh release upload` stored in STUB_UP; every other download fails.
echo "curl $*" >>"${STUB_LOG}"
out=""; url=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
file="${url##*/}"; rest="${url%/*}"; tag="${rest##*/}"
if [ -n "${STUB_PREV_TAG-}" ] && [ "${tag}" = "${STUB_PREV_TAG}" ] && [ "${file}" = mica-build-env.lock ] && [ -n "${STUB_PREV_LOCK-}" ]; then
    cp "${STUB_PREV_LOCK}" "${out}"; exit 0
fi
if [ -n "${STUB_TAG_UP-}" ] && [ "${tag}" = "${STUB_TAG_UP}" ] && [ -f "${STUB_UP}/${file}" ]; then
    cp "${STUB_UP}/${file}" "${out}"; exit 0
fi
exit 22
STUB
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}" STUB_LOG="${LOG}" STUB_UP="${UP}" STUB_PUBLISHED="${PUBLISHED}" STUB_REG="${REG}"

# ------------------------------------------------------------ check-lock.sh over the specification's vectors
# tests/vectors/ is mica:docs/design/release-lock/vectors/ (the lock and upstream
# vectors and their rows of expected.tsv); the directory names the mode.
while IFS="${TAB}" read -r vector want rule _mode; do
    got="$(bash "${BE}/check-lock.sh" "${vector%%/*}" "${BE}/tests/vectors/${vector}" 2>&1 || true)"
    expected=valid
    [ "${want}" = valid ] || expected="refused ${rule}"
    if [ "${got}" = "${expected}" ]; then pass "check-lock ${vector}: ${expected}"; else fail "check-lock ${vector}: '${got}', want '${expected}'"; fi
done <"${BE}/tests/vectors/expected.tsv"
got="$(bash "${BE}/check-lock.sh" upstream "${BE}/locks/upstream.lock" 2>&1 || true)"
[ "${got}" = valid ] && pass "this tree's locks/upstream.lock is valid" || fail "this tree's locks/upstream.lock: ${got}"

# The image row before its source column is refused.
{ printf '# mica-lock v1\nrelease\tmica-build-env\t20260914-2042\t%040d\n' 0; printf 'image\tbase\tindex\tghcr.io/micaoss/mica-build-env:base.x@sha256:%064d\n' 1; } >"${WORK}/row.lock"
got="$(bash "${BE}/check-lock.sh" lock "${WORK}/row.lock" 2>&1 || true)"
[ "${got}" = "refused column-count" ] && pass "the four-column image row is refused: column-count" || fail "the four-column image row: ${got}"

# ------------------------------------------------------------ pins.sh through from.sh --check
check_refusal() { # check_refusal LABEL PATTERN: from.sh --check refuses the edited tree, which is then restored
    if (cd "${BE}" && bash from.sh --check) >"${WORK}/check.out" 2>&1; then
        fail "$1: accepted"
    elif says "${WORK}/check.out" "$2"; then
        pass "$1"
    else
        fail "$1: $(tail -n2 "${WORK}/check.out" | tr '\n' ' ')"
    fi
    g checkout -q -- .
}
(cd "${BE}" && bash from.sh --check) >"${WORK}/check.out" 2>&1 && pass "from.sh --check accepts this tree" || fail "from.sh --check: $(cat "${WORK}/check.out")"
printf 'IMAGE_DEBIAN_TRIXIE=docker.io/library/debian:trixie-slim@sha256:%064d\n' 0 >>"${BE}/params.env"
check_refusal "params.env naming an image is refused" "images and archives are pinned in locks/upstream.lock only"
printf 'GO_URL_AMD64=https://go.dev/dl/go.tar.gz\n' >>"${BE}/params.env"
check_refusal "params.env naming an archive is refused" "images and archives are pinned in locks/upstream.lock only"
sed -i "s/^source${TAB}cargo-deny${TAB}/source${TAB}cargo-denz${TAB}/" "${BE}/locks/upstream.lock"
check_refusal "a source no image installs is refused" "pins the source cargo-denz, which no image installs"
sed -i "s/^\(source${TAB}go${TAB}arm64${TAB}\)[^${TAB}]*/\11.0.0/" "${BE}/locks/upstream.lock"
check_refusal "one source at two versions is refused" "pins go at 1.26.7 and 1.0.0"
sed -i "s/^source${TAB}go${TAB}amd64${TAB}[^${TAB}]*${TAB}/&x/" "${BE}/locks/upstream.lock"
check_refusal "a lock that breaks the file rules is refused by its rule" "locks/upstream.lock is refused field-value"

# ------------------------------------------------------------ publish-images.sh --resolve
resolve() { # resolve OUT: exit status of --resolve, its output in ${WORK}/resolve.out
    : >"${LOG}"
    rm -f "$1"
    (cd "${BE}" && bash publish-images.sh --resolve --out "$1") >"${WORK}/resolve.out" 2>&1
}

if resolve "${WORK}/none.rows"; then
    fail "--resolve succeeds with nothing published"
elif says "${WORK}/resolve.out" "mica-build-env:base.inputs-"; then
    pass "--resolve with nothing published refuses at base"
else
    fail "--resolve with nothing published: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
base_tag="$(sed -n 's/.*mica-build-env:\(base\.inputs-[0-9a-f]*\).*/\1/p' "${WORK}/resolve.out" | head -n1)"
printf '%s\n' "${base_tag}" >"${PUBLISHED}"
if ! resolve "${WORK}/base.rows" && says "${WORK}/resolve.out" "mica-build-env:c.inputs-.* (c) is not published"; then
    pass "--resolve with only base published refuses at c"
else
    fail "--resolve with only base published: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
if says "${LOG}" "imagetools create" || says "${LOG}" "buildx build"; then fail "--resolve builds or pushes: $(cat "${LOG}")"; else pass "--resolve builds and pushes nothing"; fi

export STUB_ALL=1
if STUB_PLATFORMS=amd64 resolve "${WORK}/amd64.rows"; then
    fail "--resolve accepts an index without an arm64 manifest"
elif says "${WORK}/resolve.out" "lists no linux/arm64 manifest"; then
    pass "--resolve refuses an index that lists no arm64 manifest"
else
    fail "--resolve amd64 only: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
if resolve "${WORK}/good.rows"; then pass "--resolve writes the image rows once every image is published"; else fail "--resolve: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"; fi
shape="$(while IFS="${TAB}" read -r kind source name platform ref; do
    if [ "${kind}" = image ] && [ "${source}" = mica-build-env ] && { { [ "${platform}" = index ] && [[ "${ref}" =~ ^ghcr\.io/micaoss/mica-build-env:${name}\.inputs-[0-9a-f]{16}@sha256:[0-9a-f]{64}$ ]]; } ||
        { [[ "${platform}" =~ ^(amd64|arm64)$ ]] && [[ "${ref}" =~ ^ghcr\.io/micaoss/mica-build-env@sha256:[0-9a-f]{64}$ ]]; }; }; then
        printf '%s:%s ' "${name}" "${platform}"
    else
        printf 'bad:%s ' "${name}"
    fi
done <"${WORK}/good.rows")"
if [ "${shape}" = "base:index base:amd64 base:arm64 c:index c:amd64 c:arm64 go:index go:amd64 go:arm64 rust:index rust:amd64 rust:arm64 " ]; then
    pass "the image rows name mica-build-env, each image's index by its inputs tag and its amd64 and arm64 manifests by digest"
else
    fail "the image rows: ${shape}"
fi

# ------------------------------------------------------------ publish-images.sh --plan and --build refusals
plan() { # plan OUT: exit status of --plan, output in ${WORK}/plan.out
    : >"${LOG}"
    (cd "${BE}" && bash publish-images.sh --plan "$1") >"${WORK}/plan.out" 2>&1
}
actions() { awk '{print $1 ":" $3}' "$1" | tr '\n' ' ' | sed 's/ $//'; }
plan "${WORK}/all.plan" && [ "$(actions "${WORK}/all.plan")" = "base:published c:published go:published rust:published" ] &&
    pass "--plan with every image published builds nothing" || fail "--plan all published: $(cat "${WORK}/all.plan" "${WORK}/plan.out")"
awk '{print $2}' "${WORK}/all.plan" >"${WORK}/tags"
tag_of() { awk -v n="$1" '$1 == n {print $2}' "${WORK}/all.plan"; }
STUB_ALL="" STUB_PUBLISHED="${WORK}/none" plan "${WORK}/none.plan" && [ "$(actions "${WORK}/none.plan")" = "base:build c:build go:build rust:build" ] &&
    pass "--plan with nothing published builds every image" || fail "--plan none: $(cat "${WORK}/none.plan")"
grep -vx "$(tag_of base)" "${WORK}/tags" >"${WORK}/no-base"
STUB_ALL="" STUB_PUBLISHED="${WORK}/no-base" plan "${WORK}/nobase.plan" && [ "$(actions "${WORK}/nobase.plan")" = "base:build c:build go:build rust:build" ] &&
    pass "--plan rebuilds every child of a base that is not published, even when their tags are" || fail "--plan no base: $(cat "${WORK}/nobase.plan")"
grep -vx "$(tag_of go)" "${WORK}/tags" >"${WORK}/no-go"
STUB_ALL="" STUB_PUBLISHED="${WORK}/no-go" plan "${WORK}/nogo.plan" && [ "$(actions "${WORK}/nogo.plan")" = "base:published c:published go:build rust:published" ] &&
    pass "--plan builds only an image whose tag is missing when its parent is published" || fail "--plan no go: $(cat "${WORK}/nogo.plan")"

build_refusal() { # build_refusal LABEL PATTERN ARGS...: --build/--merge refuse before any build or push
    local label="$1" pattern="$2"; shift 2
    : >"${LOG}"
    if (cd "${BE}" && bash publish-images.sh "$@") >"${WORK}/build.out" 2>&1; then
        fail "${label}: succeeded"
    elif ! says "${WORK}/build.out" "${pattern}"; then
        fail "${label}: $(tail -n2 "${WORK}/build.out" | tr '\n' ' ')"
    elif says "${LOG}" "docker push" || says "${LOG}" "imagetools create"; then
        fail "${label}: pushed"
    else
        pass "${label}"
    fi
}
case "$(uname -m)" in x86_64) other=arm64 ;; *) other=amd64 ;; esac
build_refusal "--build for another architecture is refused: no emulation" "images are built natively, not emulated" --build "${other}" "${WORK}/none.plan"
sed 's/^\(go [^ ]*\)[0-9a-f] /\1x /' "${WORK}/none.plan" >"${WORK}/stale.plan"
build_refusal "--merge with a plan of other inputs is refused" "these inputs are" --merge "${WORK}/stale.plan"
build_refusal "--merge with an empty plan is refused" "missing or empty" --merge "${WORK}/empty.plan"

moved() { # moved LABEL EXPECTED: resolve after a change, compare the images whose rows moved, restore the tree
    local got
    resolve "${WORK}/moved.rows" || true
    got="$({ diff "${WORK}/good.rows" "${WORK}/moved.rows" || true; } | awk -F"${TAB}" '/^> image/ && $4 == "index" {print $3}' | sort | tr '\n' ' ' | sed 's/ $//')"
    if [ "${got}" = "$2" ]; then pass "$1 -> moves: ${2:-none}"; else fail "$1 -> moves: '${got}', want '$2'"; fi
    g checkout -q -- .
}

printf '\n# probe\n' >>"${BE}/go/assert.sh"
moved "go/assert.sh changes" "go"

sed -i 's/^C_FLOOR_GCC_MIN=.*/C_FLOOR_GCC_MIN=14.3/' "${BE}/params.env"
moved "a C_ floor changes" "c go rust"

sed -i 's/^OPENSSL_FLOOR_JQ_MIN=.*/OPENSSL_FLOOR_JQ_MIN=1.8/' "${BE}/params.env"
moved "an OPENSSL_ floor changes (base carries openssl and jq)" "base c go rust"

sed -i "s/^\(source${TAB}cargo-deny${TAB}[a-z0-9]*${TAB}\)[^${TAB}]*/\10.19.10/" "${BE}/locks/upstream.lock"
moved "a gate tool pin changes (rust carries the gate tools)" "rust"

sed -i "s/^\(source${TAB}rust${TAB}[a-z0-9]*${TAB}\)[^${TAB}]*/\11.99.0/" "${BE}/locks/upstream.lock"
moved "the rust version changes" "rust"

sed -i "s/^\(source${TAB}go${TAB}arm64${TAB}[^${TAB}]*${TAB}\)[0-9a-f]*/\1$(printf go | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "a go archive hash changes" "go"

sed -i "/^image${TAB}upstream${TAB}debian:trixie-slim${TAB}/s/@sha256:.*/@sha256:$(printf trixie | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "the Debian base pin changes" "base c go rust"

printf '\n# probe\n' >>"${BE}/lib/common.sh"
moved "lib/common.sh changes" "base c go rust"

printf '\n# probe\n' >>"${BE}/publish-release.sh"
moved "a script no image copies changes" ""

sed -i "/^image${TAB}upstream${TAB}ubuntu:24.04${TAB}/s/@sha256:.*/@sha256:$(printf ubuntu | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "an upstream image no build-env image stands on changes" ""

# ------------------------------------------------------------ fetch-archives.sh
# Its own locks/upstream.lock and a curl stub that serves "archive <name>" for any URL.
FA="${WORK}/fa"
mkdir -p "${FA}/stubs" "${FA}/locks"
cp "${BE}/fetch-archives.sh" "${BE}/pins.sh" "${BE}/check-lock.sh" "${BE}/params.env" "${FA}/"
body() { printf 'archive %s' "$1"; }
shaof() { body "$1" | sha256sum | cut -d' ' -f1; }
{
    echo "# mica-lock v1"
    printf 'source\tgo\tamd64\t1.0\t%s\thttps://example.invalid/go-amd64.tar.gz\n' "$(shaof go-amd64.tar.gz)"
    printf 'source\tgo\tarm64\t1.0\t%s\thttps://example.invalid/go-arm64.tar.gz\n' "$(shaof go-arm64.tar.gz)"
    printf 'source\trust-std\tamd64\t1.0\t%s\thttps://example.invalid/std-amd64.tar.xz\n' "$(shaof std-amd64.tar.xz)"
    printf 'source\trust-std\tarm64\t1.0\t%s\thttps://example.invalid/std-arm64.tar.xz\n' "$(shaof std-arm64.tar.xz)"
} >"${FA}/locks/upstream.lock"
cat >"${FA}/stubs/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"${STUB_LOG}"
out=""; url=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
printf 'archive %s' "${STUB_CORRUPT:-${url##*/}}" >"${out}"
STUB
chmod +x "${FA}/stubs/curl"
fa() { : >"${LOG}"; (cd "${FA}" && PATH="${FA}/stubs:${PATH}" bash fetch-archives.sh "$@") >"${WORK}/fa.out" 2>&1; }
SEEDDIR="${WORK}/seed"
mkdir -p "${SEEDDIR}"
printf 'old' >"${SEEDDIR}/go1.0.linux-amd64.tar.gz"
if fa amd64 "${SEEDDIR}" && [ "$(ls "${SEEDDIR}" | LC_ALL=C sort | tr '\n' ' ')" = "go-amd64.tar.gz std-arm64.tar.xz " ]; then
    pass "fetch-archives gathers the amd64 archives and the arm64 std, and removes anything else"
else
    fail "fetch-archives amd64: $(ls "${SEEDDIR}" | tr '\n' ' ') $(tail -n2 "${WORK}/fa.out" | tr '\n' ' ')"
fi
fa amd64 "${SEEDDIR}" && ! says "${LOG}" "curl" && pass "... a second run downloads nothing" || fail "... second run: $(cat "${LOG}")"
printf 'tampered' >"${SEEDDIR}/go-amd64.tar.gz"
fa amd64 "${SEEDDIR}" && says "${LOG}" "go-amd64.tar.gz" && [ "$(sha256sum "${SEEDDIR}/go-amd64.tar.gz" | cut -d' ' -f1)" = "$(shaof go-amd64.tar.gz)" ] &&
    pass "... a file that does not match its pin is fetched again" || fail "... tampered: $(cat "${WORK}/fa.out")"
rm -f "${SEEDDIR}"/*
if STUB_CORRUPT=other fa amd64 "${SEEDDIR}"; then
    fail "... a download that does not match its pin is accepted"
elif says "${WORK}/fa.out" "hashes to" && [ -z "$(ls -A "${SEEDDIR}")" ]; then
    pass "... a download that does not match its pin is refused and not kept"
else
    fail "... corrupt download: $(ls -A "${SEEDDIR}") $(cat "${WORK}/fa.out")"
fi

# ------------------------------------------------------------ publish-release.sh
release() { # release LABEL WANT_RC PATTERN TAG: run with the stubs, check rc and output
    : >"${LOG}"
    rm -f "${UP}"/*
    local rc=0
    (cd "${BE}" && bash publish-release.sh "$4") >"${WORK}/release.out" 2>&1 || rc=$?
    if [ "${rc}" != "$2" ]; then
        fail "$1: exit ${rc}, want $2: $(tail -n3 "${WORK}/release.out" | tr '\n' ' ')"
    elif ! says "${WORK}/release.out" "$3"; then
        fail "$1: output lacks '$3': $(tail -n3 "${WORK}/release.out" | tr '\n' ' ')"
    else
        pass "$1"
    fi
}
no_call() { if says "${LOG}" "$2"; then fail "$1: '$2' was called"; else pass "$1"; fi; }
none_called() { if [ -s "${LOG}" ]; then fail "$1: $(tr '\n' ' ' <"${LOG}")"; else pass "$1"; fi; }
nothing_written() { if says "${LOG}" "release upload" || says "${LOG}" "release edit"; then fail "$1: $(grep 'release \(upload\|edit\)' "${LOG}")"; else pass "$1"; fi; }

T0=20260101-0000
T1=20260102-0304
printf '\n' >>"${BE}/README.md"
g commit -q -am tagged
g update-ref refs/remotes/origin/main HEAD
HEAD_SHA="$(g rev-parse HEAD)"
export STUB_TAG_SHA="${HEAD_SHA}" STUB_TAG_UP="${T1}"

release "a tag that is not YYYYMMDD-HHMM is refused" 1 "not a UTC time YYYYMMDD-HHMM" v0.0.1
none_called "... and nothing was asked of gh"
release "a time tag without the dash is refused" 1 "not a UTC time YYYYMMDD-HHMM" 202601020304
release "a tag that is not a real time is refused" 1 "not a UTC time YYYYMMDD-HHMM" 20261301-1200
release "a tag in the future is refused" 1 "a time in the future" 20990101-0000
none_called "... and nothing was asked of gh"
STUB_TAG_SHA="" release "a tag that does not exist is refused" 1 "cut the release with gh release create" "${T1}"
nothing_written "... and nothing is written"
STUB_GH_ERR="HTTP 502" release "a tag lookup that fails other than 404 is refused" 1 "could not read ${T1}" "${T1}"
STUB_TAG_SHA="$(printf '%040d' 7)" release "a tag on another commit is refused" 1 "not the checked-out commit" "${T1}"
STUB_NO_RELEASE=1 release "a tag without a published release is refused" 1 "has no published release" "${T1}"
STUB_ASSETS="mica-build-env.lock" release "a release that already carries an asset is refused" 1 "an asset is never replaced" "${T1}"
nothing_written "... and nothing is written"

g update-ref refs/remotes/origin/main HEAD~1
release "a tagged commit that is not on main is refused" 1 "is not on origin/main" "${T1}"
g update-ref refs/remotes/origin/main HEAD

printf 'dirty\n' >>"${BE}/README.md"
release "a dirty tree is refused" 1 "uncommitted changes" "${T1}"
no_call "... before any release is listed" "release list"
g checkout -q -- .

STUB_RELEASES="${T1} 20261231-2359 v0.0.1" release "a release later than the tag is refused" 1 "the release 20261231-2359 is later than ${T1}" "${T1}"
no_call "... before any image is read" "docker"

STUB_ALL="" release "a tag whose images are not published is refused" 1 "the images job publishes them for ${T1}" "${T1}"
nothing_written "... and nothing is written"
STUB_DOCKER_FAIL=1 release "images that do not read anonymously are refused" 1 "not all published" "${T1}"
nothing_written "... and nothing is written"
sed -i "/^image${TAB}upstream${TAB}/s/@sha256:.*//" "${BE}/locks/upstream.lock"
g commit -q -am "an upstream image without a digest"
g update-ref refs/remotes/origin/main HEAD
STUB_TAG_SHA="$(g rev-parse HEAD)" release "a locks/upstream.lock that breaks the file rules is refused" 1 "locks/upstream.lock is refused reference-digest" "${T1}"
nothing_written "... and nothing is written"
g reset -q --hard HEAD~1
g update-ref refs/remotes/origin/main HEAD
STUB_RELEASES="${T0} ${T1}" STUB_LOCK_TAGS="${T0}" release "a previous lock that cannot be read is refused" 1 "whether the images changed is unknown" "${T1}"
nothing_written "... and nothing is written"

STUB_RELEASES="${T1}" STUB_BODY="Cut by hand." release "the first release gets its assets" 0 "carries its assets" "${T1}"
says "${LOG}" "release upload ${T1} --repo micaoss/mica-build-env " && ! says "${LOG}" "clobber" &&
    pass "... uploaded to the existing release, never with --clobber" || fail "... upload: $(grep 'release upload' "${LOG}")"
no_call "... and never creates a release or a tag" "release create"
says "${LOG}" "release edit ${T1} --repo micaoss/mica-build-env --notes Cut by hand." && says "${LOG}" "Images: the first release." &&
    pass "... its notes keep the body and add the images note" || fail "... notes: $(grep 'release edit' "${LOG}")"
[ "$(ls "${UP}" | LC_ALL=C sort | tr '\n' ' ')" = "SHA256SUMS mica-build-env.lock " ] && pass "... exactly two assets: mica-build-env.lock and SHA256SUMS" || fail "... assets: $(ls "${UP}" | tr '\n' ' ')"
if (cd "${UP}" && sha256sum -c --quiet SHA256SUMS) 2>/dev/null && [ "$(sed 's/^[0-9a-f]*  //' "${UP}/SHA256SUMS")" = "mica-build-env.lock" ]; then
    pass "... SHA256SUMS lists only mica-build-env.lock"
else
    fail "... SHA256SUMS: $(cat "${UP}/SHA256SUMS" 2>/dev/null)"
fi
[ "$(bash "${BE}/check-lock.sh" lock "${UP}/mica-build-env.lock")" = valid ] && pass "... the lock passes check-lock.sh" || fail "... check-lock: $(bash "${BE}/check-lock.sh" lock "${UP}/mica-build-env.lock")"
want_lock="$(printf '# mica-lock v1\nrelease\tmica-build-env\t%s\t%s\n' "${T1}" "${HEAD_SHA}"; { cat "${WORK}/good.rows"; grep "^image${TAB}upstream${TAB}" "${BE}/locks/upstream.lock"; } | LC_ALL=C sort -t "${TAB}" -k2,2 -k3,3 -k4,4)"
[ "$(cat "${UP}/mica-build-env.lock")" = "${want_lock}" ] && pass "... the lock is the release row, then this repository's image rows and the upstream image rows of locks/upstream.lock, by source, name and platform" || fail "... lock: $(cat "${UP}/mica-build-env.lock")"
[ "$(grep -c "^image${TAB}upstream${TAB}docker.io/\|${TAB}ghcr.io/micaoss/mica-build-env:upstream\." "${UP}/mica-build-env.lock" || true)" = 0 ] &&
    pass "... upstream images keep their original names and references" || fail "... rewritten upstream rows"
[ "$(sed -n '3,5p' "${UP}/mica-build-env.lock" | cut -f3,4 | tr '\t\n' ': ')" = "base:amd64 base:arm64 base:index " ] &&
    pass "... platforms sort as bytes: amd64, arm64, index" || fail "... order: $(head -n5 "${UP}/mica-build-env.lock")"
grep -c "^image${TAB}upstream${TAB}debian:trixie-slim${TAB}386${TAB}docker.io/library/debian:trixie-slim@sha256:" "${UP}/mica-build-env.lock" >/dev/null && pass "... debian:trixie-slim carries its 386 row" || fail "... no 386 row"
cp "${UP}/mica-build-env.lock" "${WORK}/first.lock"

STUB_RELEASES="${T0} ${T1}" STUB_LOCK_TAGS="${T0}" STUB_PREV_TAG="${T0}" STUB_PREV_LOCK="${WORK}/first.lock" release "a release after one with the same images" 0 "Images: unchanged from ${T0}." "${T1}"
sed "s/@sha256:[0-9a-f]*\$/@sha256:$(printf other | sha256sum | cut -d' ' -f1)/" "${WORK}/first.lock" >"${WORK}/other.lock"
STUB_RELEASES="${T0} ${T1}" STUB_LOCK_TAGS="${T0}" STUB_PREV_TAG="${T0}" STUB_PREV_LOCK="${WORK}/other.lock" release "a release after one with other images" 0 "Images: changed from ${T0}. This is a breaking update" "${T1}"
says "${LOG}" "This is a breaking update: every repository must update to it." && pass "... and its notes say so" || fail "... notes: $(grep 'release edit' "${LOG}")"
T00=20251231-2359
STUB_RELEASES="${T00} ${T0} ${T1}" STUB_LOCK_TAGS="${T00}" STUB_PREV_TAG="${T00}" STUB_PREV_LOCK="${WORK}/first.lock" release "an earlier release without mica-build-env.lock is skipped for the comparison" 0 "Images: unchanged from ${T00}." "${T1}"
STUB_RELEASES="${T0} ${T1}" release "with no earlier release carrying the lock it is the first" 0 "Images: the first release." "${T1}"

echo
echo "publish-test: ${PASS_N} passed, ${FAIL_N} failed"
[ "${FAIL_N}" = 0 ]
