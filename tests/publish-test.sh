#!/usr/bin/env bash
# publish-images.sh, pins.sh, from.sh, fetch-archives.sh and publish-release.sh
# against a copy of this tree, with gh, docker and curl replaced by stubs: the
# image-row source rules, the refusals of locks/upstream.lock and params.env,
# which inputs move which image, the mica-build-env.lock a release writes, and
# every refusal of a release before anything is written. The lock rules and
# their vectors are mica-build-tools', run here through bin/mica-tools.
#
#   bash tests/publish-test.sh      (no docker; bun 1.4.2 as MICA_BUN or on PATH,
#                                    see bin/bun.sh; the network only on the first
#                                    run, to fetch the pinned mica-build-tools)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
for t in git sha256sum tar jq; do
    command -v "${t}" >/dev/null 2>&1 || { echo "error: ${t} is required" >&2; exit 1; }
done
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
# Every copy of this tree starts with this tree's mirror of the pinned mica-build-tools,
# so it runs offline once this tree holds the commit.
"${REPO}/bin/mica-tools" sync
seed_tools() { mkdir -p "$1/repos/git" && cp -r "${REPO}/repos/git/mica-build-tools.git" "$1/repos/git/"; }
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
seed_tools "${BE}"
g() { git -C "${BE}" -c user.name=test -c user.email=test@example.invalid "$@"; }
g init -q -b main
g add -A
g commit -q -m fixture

# ------------------------------------------------------------ stubs
# docker is a registry in ${STUB_REG}: blobs/<digest> holds manifest bytes and
# tags/<ref with / written %> the digest a tag names; `imagetools inspect [--raw]`
# answers from it, and labels/<digest> holds what `--format '{{json .Image}}'`
# prints (each platform's config labels). `imagetools create -t <tag> <source>`
# points the tag at the source; with several sources it stores a new index of
# their manifests and labels. curl serves the registry's token and tags/list from
# the same tags, as ghcr.io answers them.
STUBS="${WORK}/stubs"
LOG="${WORK}/calls"
REG="${WORK}/registry"
mkdir -p "${STUBS}" "${REG}/blobs" "${REG}/tags" "${REG}/labels"
cat >"${STUBS}/mkindex" <<'STUB'
#!/usr/bin/env bash
# mkindex <label> <platforms> [<inputs>]: store an index of one manifest per platform,
# each labelled com.mica.build-env.inputs=<inputs> when given; print its digest.
set -euo pipefail
entries="" labels='{}'
for p in ${2//,/ }; do
    m="$(printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","label":"%s","arch":"%s"}' "$1" "$p")"
    # A platform manifest ends in a newline, as Docker Hub's do: the digest covers it.
    d="sha256:$(printf '%s\n' "${m}" | sha256sum | cut -d' ' -f1)"
    printf '%s\n' "${m}" >"${STUB_REG}/blobs/${d}"
    entries="${entries:+${entries},}$(printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","platform":{"os":"linux","architecture":"%s"}}' "${d}" "${p}")"
    labels="$(jq -c --arg p "linux/${p}" --arg v "${3-}" '. + {($p): {config: {Labels: (if $v == "" then {} else {"com.mica.build-env.inputs": $v} end)}}}' <<<"${labels}")"
done
i="$(printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[%s]}' "${entries}")"
d="sha256:$(printf '%s' "${i}" | sha256sum | cut -d' ' -f1)"
printf '%s' "${i}" >"${STUB_REG}/blobs/${d}"
printf '%s' "${labels}" >"${STUB_REG}/labels/${d}"
echo "${d}"
STUB
cat >"${STUBS}/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"${STUB_LOG}"
[ -z "${STUB_DOCKER_FAIL-}" ] || exit 1
[ "$1 $2" = "buildx imagetools" ] || { echo "stub docker: unexpected $*" >&2; exit 2; }
resolve() { # resolve <ref>: the digest it names, or fail
    case "$1" in *@sha256:*) [ -f "${STUB_REG}/blobs/${1##*@}" ] && echo "${1##*@}"; return ;; esac
    [ -f "${STUB_REG}/tags/${1//\//%}" ] && cat "${STUB_REG}/tags/${1//\//%}"
}
case "$3" in
inspect)
    if [ "$4" = --raw ]; then
        d="$(resolve "$5")" || exit 1
        cat "${STUB_REG}/blobs/${d}"
    elif [ "${5-}" = --format ]; then
        d="$(resolve "$4")" || exit 1
        cat "${STUB_REG}/labels/${d}" 2>/dev/null || echo '{}'
    else
        d="$(resolve "$4")" || exit 1
        printf 'Name: %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest: %s\n' "$4" "${d}"
    fi ;;
create)
    [ "$4" = -t ] || { echo "stub docker: create takes -t <tag> <source>... here" >&2; exit 2; }
    tag="$5"
    shift 5
    digests=()
    for src in "$@"; do digests+=("$(resolve "${src}")") || { echo "stub docker: no source ${src}" >&2; exit 1; }; done
    if [ "${#digests[@]}" = 1 ]; then
        d="${digests[0]}"
    else
        i="$(for d in "${digests[@]}"; do cat "${STUB_REG}/blobs/${d}"; echo; done |
            jq -sc '{schemaVersion: 2, mediaType: "application/vnd.oci.image.index.v1+json", manifests: [.[].manifests[]]}')"
        d="sha256:$(printf '%s' "${i}" | sha256sum | cut -d' ' -f1)"
        printf '%s' "${i}" >"${STUB_REG}/blobs/${d}"
        for x in "${digests[@]}"; do cat "${STUB_REG}/labels/${x}" 2>/dev/null || echo '{}'; done | jq -sc 'add' >"${STUB_REG}/labels/${d}"
    fi
    printf '%s\n' "${d}" >"${STUB_REG}/tags/${tag//\//%}" ;;
*) echo "stub docker: unexpected $*" >&2; exit 2 ;;
esac
STUB
cat >"${STUBS}/curl" <<'STUB'
#!/usr/bin/env bash
# Serves the registry token and tags/list of the stub registry; every other
# download fails.
echo "curl $*" >>"${STUB_LOG}"
out=""; url=""; headers=""
while [ "$#" -gt 0 ]; do case "$1" in -o) out="$2"; shift 2 ;; -D) headers="$2"; shift 2 ;; -H) shift 2 ;; http*) url="$1"; shift ;; *) shift ;; esac; done
[ -z "${STUB_DOCKER_FAIL-}" ] || case "${url}" in https://ghcr.io/*) exit 22 ;; esac
case "${url}" in
https://ghcr.io/token\?*) echo '{"token":"stub"}'; exit 0 ;;
https://ghcr.io/v2/micaoss/mica-build-env/tags/list*)
    [ -z "${headers}" ] || printf 'HTTP/2 200\r\n' >"${headers}"
    (cd "${STUB_REG}/tags" && ls) | sed -n 's/^ghcr.io%micaoss%mica-build-env://p' | jq -Rsc '{name: "micaoss/mica-build-env", tags: split("\n") | map(select(. != ""))}' >"${out:-/dev/stdout}"
    exit 0 ;;
esac
exit 22
STUB
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}" STUB_LOG="${LOG}" STUB_REG="${REG}"

# GitHub's API and release downloads, for `mica-tools release attach` (tests/github-stub.ts).
GH="${WORK}/github"
mkdir -p "${GH}/releases"
"${MICA_BUN:-bun}" "${HERE}/github-stub.ts" "${GH}" &
GH_PID=$!
trap 'kill "${GH_PID}" 2>/dev/null || true; rm -rf "${WORK}"' EXIT
for _ in $(seq 1 50); do [ -s "${GH}/port" ] && break; sleep 0.1; done
[ -s "${GH}/port" ] || { echo "error: tests/github-stub.ts did not start" >&2; exit 1; }
GH_URL="http://127.0.0.1:$(cat "${GH}/port")"
export GH_TOKEN=stub MICA_SOURCE_REPO=mica-build-env MICA_GITHUB_API="${GH_URL}" MICA_GITHUB_UPLOADS="${GH_URL}" \
    MICA_RELEASES_URL="${GH_URL}/download/{repository}/{release}/"

# ------------------------------------------------------------ mica-build-tools
got="$("${BE}/bin/mica-tools" self-check 2>/dev/null || true)"
[[ "${got}" == "bin/mica-tools is bootstrap/mica-tools at "* ]] && pass "bin/mica-tools is the bootstrap of the pinned mica-build-tools" || fail "self-check: ${got}"
got="$("${BE}/bin/mica-tools" upstream check 2>/dev/null || true)"
[ "${got}" = valid ] && pass "this tree's locks/upstream.lock is valid" || fail "this tree's locks/upstream.lock: ${got}"

# The image row before its source column is refused.
{ printf '# mica-lock v1\nrelease\tmica-build-env\t20260914-2042\t%040d\n' 0; printf 'image\tbase\tindex\tghcr.io/micaoss/mica-build-env:base.x@sha256:%064d\n' 1; } >"${WORK}/row.lock"
got="$("${BE}/bin/mica-tools" lock check "${WORK}/row.lock" 2>/dev/null || true)"
[ "${got}" = "refused column-count" ] && pass "the four-column image row is refused: column-count" || fail "the four-column image row: ${got}"

# ------------------------------------------------------------ the shell shapes this tree refuses
# Under `set -o pipefail` a consumer that exits early (head, grep -q, grep -m,
# sed with q, read) makes the producer die of SIGPIPE and fails the pipeline,
# which small inputs hide until they grow.
early=""
while IFS= read -r f; do
    grep -c 'set -[a-z]*o pipefail\|set -euo pipefail' "${BE}/${f}" >/dev/null || continue
    hits="$(grep -nE '\|[[:space:]]*(head|grep[[:space:]]+(-[a-zA-Z]*[qm])|sed[[:space:]][^|]*[[:space:]]q([[:space:]]|$)|read)([[:space:]]|$)|\|[[:space:]]*awk[^|]*exit[[:space:]]*}' "${BE}/${f}" | grep -v '^[0-9]*: *#' || true)"
    [ -z "${hits}" ] || early="${early}${f}: ${hits}"$'\n'
done < <(cd "${BE}" && git ls-files '*.sh')
[ -z "${early}" ] && pass "no early-exiting consumer on the right of a pipe under pipefail" || fail "early-exiting pipe consumers: ${early}"

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
check_refusal "one source at two versions is refused" "pins go at $(awk -F'\t' '$1 == "source" && $2 == "go" && $3 == "amd64" { print $4 }' "${BE}/locks/upstream.lock") and 1.0.0"
sed -i "s/^source${TAB}go${TAB}amd64${TAB}[^${TAB}]*${TAB}/&x/" "${BE}/locks/upstream.lock"
check_refusal "a lock that breaks the file rules is refused by its rule" "locks/upstream.lock is refused field-value"
sed -i "/^source${TAB}debian-trixie-updates${TAB}/s#/archive/debian/#/archive/debian-security/#" "${BE}/locks/upstream.lock"
check_refusal "a Debian snapshot row at another archive's URL is refused" "is not the InRelease of suite trixie-updates"
sed -i "/^source${TAB}debian-trixie-security${TAB}/s/[0-9]\{8\}T000000Z/19991231T000000Z/g" "${BE}/locks/upstream.lock"
check_refusal "Debian snapshot rows at two instants are refused" "names two debian snapshot instants"
sed -i "s/^source${TAB}debian-trixie${TAB}/source${TAB}centos-9${TAB}/" "${BE}/locks/upstream.lock"
check_refusal "a snapshot row of an unknown distribution is refused" "only the ubuntu-<suite> and debian-<suite> snapshot rows are"

# ------------------------------------------------------------ publish-images.sh
# Every tag is a release: <image>.<release>, per architecture <image>.<arch>.<release>.
tagfile() { printf '%s/tags/ghcr.io%%micaoss%%mica-build-env:%s' "${REG}" "$1"; }
label() { jq -r '[.[].config.Labels["com.mica.build-env.inputs"] // ""] | unique | if length == 1 then .[0] else "" end' "${REG}/labels/$(cat "$(tagfile "$1")")"; }
plan() { : >"${LOG}"; (cd "${BE}" && bash publish-images.sh --plan "$1") >"${WORK}/plan.out" 2>&1; }
merge() { : >"${LOG}"; (cd "${BE}" && bash publish-images.sh --merge "$1" "$2") >"${WORK}/merge.out" 2>&1; }
resolve() { : >"${LOG}"; rm -f "$2"; (cd "${BE}" && bash publish-images.sh --resolve "$1" --out "$2") >"${WORK}/resolve.out" 2>&1; }
actions() { awk '{print $1 ":" $3}' "$1" | tr '\n' ' ' | sed 's/ $//'; }
inputs_of() { awk -v n="$1" '$1 == n {print $2}' "${WORK}/none.plan"; }
R0=20260101-0900
T1=20260102-0304

plan "${WORK}/none.plan" && [ "$(actions "${WORK}/none.plan")" = "base:build c:build go:build rust:build bsp:build" ] &&
    [ "$(grep -cE '^(base|c|go|rust|bsp) [0-9a-f]{64} build$' "${WORK}/none.plan")" = 5 ] &&
    pass "--plan with nothing published builds every image, each named by the sha256 of its inputs" || fail "--plan none: $(cat "${WORK}/none.plan" "${WORK}/plan.out")"

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
build_refusal "--build for another architecture is refused: no emulation" "images are built natively, not emulated" --build "${other}" "${R0}" "${WORK}/none.plan"
sed 's/^\(go [0-9a-f]*\)[0-9a-f] /\1x /' "${WORK}/none.plan" >"${WORK}/stale.plan"
build_refusal "--merge with a plan of other inputs is refused" "but these inputs are" --merge "${R0}" "${WORK}/stale.plan"
build_refusal "--merge with an empty plan is refused" "missing or empty" --merge "${R0}" "${WORK}/empty.plan"
build_refusal "--merge with a release that is not YYYYMMDD-HHMM is refused" "is not YYYYMMDD-HHMM" --merge v0.0.1 "${WORK}/none.plan"
build_refusal "--merge of an image whose architectures were not pushed is refused" "base.amd64.${R0} is not pushed" --merge "${R0}" "${WORK}/none.plan"

# The build jobs of ${R0} pushed <image>.<arch>.${R0}.
for n in base c go rust bsp; do for a in amd64 arm64; do mkindex "${n}-${a}" "${a}" "$(inputs_of "${n}")" >"$(tagfile "${n}.${a}.${R0}")"; done; done
if merge "${R0}" "${WORK}/none.plan" && [ "$(grep -c "imagetools create -t ghcr.io/micaoss/mica-build-env:[a-z]*\.${R0} ghcr.io/micaoss/mica-build-env:[a-z]*\.amd64\.${R0} ghcr.io/micaoss/mica-build-env:[a-z]*\.arm64\.${R0}" "${LOG}")" = 5 ]; then
    pass "--merge publishes each built image as <image>.<release>, both architectures in one index"
else
    fail "--merge ${R0}: $(tail -n3 "${WORK}/merge.out" | tr '\n' ' ')"
fi
ok=1
for n in base c go rust bsp; do [ "$(label "${n}.${R0}")" = "$(inputs_of "${n}")" ] || ok=0; done
[ "${ok}" = 1 ] && pass "... every platform of each image carries its inputs as the label com.mica.build-env.inputs" || fail "... labels: $(label "base.${R0}")"
merge "${R0}" "${WORK}/none.plan" && ! says "${LOG}" "imagetools create" && pass "... a rerun re-points nothing" || fail "... rerun: $(cat "${LOG}")"

plan "${WORK}/all.plan" && [ "$(actions "${WORK}/all.plan")" = "base:published c:published go:published rust:published bsp:published" ] &&
    [ "$(grep -c " published ghcr.io/micaoss/mica-build-env:[a-z]*\.${R0}@sha256:" "${WORK}/all.plan")" = 5 ] &&
    pass "--plan finds every image published with these inputs under its release tag" || fail "--plan all published: $(cat "${WORK}/all.plan" "${WORK}/plan.out")"
if merge "${T1}" "${WORK}/all.plan" && [ "$(grep -c "imagetools create -t ghcr.io/micaoss/mica-build-env:[a-z]*\.${T1} ghcr.io/micaoss/mica-build-env:[a-z]*\.${R0}@sha256:" "${LOG}")" = 5 ]; then
    pass "--merge of a release with no image built tags each published image <image>.<release>"
else
    fail "--merge ${T1}: $(tail -n3 "${WORK}/merge.out" | tr '\n' ' ')"
fi
[ "$(cat "$(tagfile "rust.${T1}")")" = "$(cat "$(tagfile "rust.${R0}")")" ] && pass "... an unchanged image keeps its digest" || fail "... rust.${T1} moved"

if resolve 20260103-0000 "${WORK}/none.rows"; then
    fail "--resolve succeeds for a release that tagged nothing"
elif says "${WORK}/resolve.out" "mica-build-env:base.20260103-0000 (base) is not published"; then
    pass "--resolve refuses a release whose images are not tagged, naming <image>.<release>"
else
    fail "--resolve untagged: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
if says "${LOG}" "imagetools create" || says "${LOG}" "buildx build"; then fail "--resolve builds or pushes: $(cat "${LOG}")"; else pass "--resolve builds and pushes nothing"; fi
if resolve "${T1}" "${WORK}/good.rows"; then pass "--resolve writes the image rows of a tagged release"; else fail "--resolve: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"; fi
shape="$(while IFS="${TAB}" read -r kind source name platform ref; do
    if [ "${kind}" = image ] && [ "${source}" = mica-build-env ] && { { [ "${platform}" = index ] && [[ "${ref}" =~ ^ghcr\.io/micaoss/mica-build-env:${name}\.${T1}@sha256:[0-9a-f]{64}$ ]]; } ||
        { [[ "${platform}" =~ ^(amd64|arm64)$ ]] && [[ "${ref}" =~ ^ghcr\.io/micaoss/mica-build-env@sha256:[0-9a-f]{64}$ ]]; }; }; then
        printf '%s:%s ' "${name}" "${platform}"
    else
        printf 'bad:%s ' "${name}"
    fi
done <"${WORK}/good.rows")"
if [ "${shape}" = "base:index base:amd64 base:arm64 c:index c:amd64 c:arm64 go:index go:amd64 go:arm64 rust:index rust:amd64 rust:arm64 bsp:index bsp:amd64 bsp:arm64 " ]; then
    pass "the image rows name mica-build-env, each index as <image>.<release> and its amd64 and arm64 manifests by digest"
else
    fail "the image rows: ${shape}"
fi

aside() { mkdir -p "${WORK}/aside"; for t in "$@"; do mv "$(tagfile "${t}")" "${WORK}/aside/"; done; }
back() { mv "${WORK}/aside/"* "${REG}/tags/"; }
aside "base.${R0}" "base.${T1}"
plan "${WORK}/nobase.plan" && [ "$(actions "${WORK}/nobase.plan")" = "base:build c:build go:build rust:build bsp:published" ] &&
    pass "--plan rebuilds every child of a base that is not published, even when theirs are, and leaves bsp alone" || fail "--plan no base: $(cat "${WORK}/nobase.plan")"
back
aside "go.${R0}" "go.${T1}"
plan "${WORK}/nogo.plan" && [ "$(actions "${WORK}/nogo.plan")" = "base:published c:published go:build rust:published bsp:published" ] &&
    pass "--plan builds only an image not published with these inputs when its parent is" || fail "--plan no go: $(cat "${WORK}/nogo.plan")"
back

cp "$(tagfile "go.${T1}")" "${WORK}/go.tag"
mkindex other amd64,arm64 >"$(tagfile "go.${T1}")"
if merge "${T1}" "${WORK}/all.plan"; then
    fail "--merge accepts a release tag that holds other inputs"
elif says "${WORK}/merge.out" "go.${T1} already holds .* never re-pointed" && ! says "${LOG}" "imagetools create"; then
    pass "--merge refuses a release tag that holds other inputs, without re-pointing it"
else
    fail "--merge over other inputs: $(tail -n2 "${WORK}/merge.out" | tr '\n' ' ')"
fi
if ! resolve "${T1}" "${WORK}/x.rows" && says "${WORK}/resolve.out" "go.${T1} was published for other inputs"; then
    pass "--resolve refuses a release tag published for other inputs"
else
    fail "--resolve with another go: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
cp "${WORK}/go.tag" "$(tagfile "go.${T1}")"

jq -c '.manifests |= map(select(.platform.architecture == "amd64"))' "${REG}/blobs/$(cat "$(tagfile "base.${T1}")")" >"${WORK}/amd64.index"
d="sha256:$(tr -d '\n' <"${WORK}/amd64.index" | sha256sum | cut -d' ' -f1)"
tr -d '\n' <"${WORK}/amd64.index" >"${REG}/blobs/${d}" && printf '%s\n' "${d}" >"$(tagfile base.20260104-0000)"
jq -c '{"linux/amd64": .["linux/amd64"]}' "${REG}/labels/$(cat "$(tagfile "base.${T1}")")" >"${REG}/labels/${d}"
if ! resolve 20260104-0000 "${WORK}/amd64.rows" && says "${WORK}/resolve.out" "lists no linux/arm64 manifest"; then
    pass "--resolve refuses an index that lists no arm64 manifest"
else
    fail "--resolve amd64 only: $(tail -n2 "${WORK}/resolve.out" | tr '\n' ' ')"
fi
rm -f "$(tagfile base.20260104-0000)"

moved() { # moved LABEL EXPECTED: plan after a change, compare the images whose inputs moved, restore the tree
    local got
    plan "${WORK}/moved.plan" || true
    got="$(awk 'NR == FNR { t[$1] = $2; next } t[$1] != $2 { print $1 }' "${WORK}/all.plan" "${WORK}/moved.plan" | sort | tr '\n' ' ' | sed 's/ $//')"
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

sed -i "s/^\(source${TAB}rust${TAB}[a-z0-9]*${TAB}\)[^${TAB}]*/\11.0.0/" "${BE}/locks/upstream.lock"
moved "the rust version changes" "rust"

sed -i "s/^\(source${TAB}go${TAB}arm64${TAB}[^${TAB}]*${TAB}\)[0-9a-f]*/\1$(printf go | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "a go archive hash changes" "go"

sed -i "/^image${TAB}upstream${TAB}debian:trixie-slim${TAB}/s/@sha256:.*/@sha256:$(printf trixie | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "the Debian base pin changes" "base c go rust"

printf '\n# probe\n' >>"${BE}/lib/common.sh"
moved "lib/common.sh changes" "base bsp c go rust"

printf '\n# probe\n' >>"${BE}/publish-release.sh"
moved "a script no image copies changes" ""

sed -i "/^image${TAB}upstream${TAB}ubuntu:24.04${TAB}/s/@sha256:.*/@sha256:$(printf ubuntu | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "the Ubuntu base pin changes (bsp stands on it)" "bsp"

sed -i "/^image${TAB}upstream${TAB}alpine:3.24.1${TAB}/s/@sha256:.*/@sha256:$(printf alpine | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "an upstream image no build-env image stands on changes" ""

sed -i "s/^\(source${TAB}ubuntu-noble${TAB}all${TAB}[^${TAB}]*${TAB}\)[0-9a-f]*/\1$(printf noble | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "an Ubuntu snapshot InRelease changes" "bsp"

sed -i "s/^\(source${TAB}debian-trixie-security${TAB}all${TAB}[^${TAB}]*${TAB}\)[0-9a-f]*/\1$(printf security | sha256sum | cut -d' ' -f1)/" "${BE}/locks/upstream.lock"
moved "a Debian snapshot InRelease changes (base, c, go and rust install from it)" "base c go rust"

printf '\n# probe\n' >>"${BE}/lib/apt-debian.sh"
moved "lib/apt-debian.sh changes" "base bsp c go rust"

printf '\n# probe\n' >>"${BE}/bsp/apt-install.sh"
moved "bsp/apt-install.sh changes" "bsp"

# ------------------------------------------------------------ fetch-archives.sh
# Its own locks/upstream.lock and a curl stub that serves "archive <name>" for any URL.
FA="${WORK}/fa"
mkdir -p "${FA}/stubs" "${FA}/locks"
cp -r "${BE}/fetch-archives.sh" "${BE}/pins.sh" "${BE}/params.env" "${BE}/bin" "${FA}/"
cp "${BE}/locks/mica-build-tools.pin" "${FA}/locks/"
seed_tools "${FA}"
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
# tests/github-stub.ts answers the tag lookup of `release check` and is the release that
# `release attach` writes.
gh_reset() { rm -rf "${GH}/releases"; mkdir -p "${GH}/releases" "${GH}/tags"; : >"${GH}/log"; }
gh_tag() { rm -f "${GH}/tags/$1" "${GH}/tags/$1.status"; [ -z "${2-}" ] || printf '%s\n' "$2" >"${GH}/tags/$1"; }
gh_release() { mkdir -p "${GH}/releases/$1/assets"; [ -z "${2-}" ] || printf '%s' "$2" >"${GH}/releases/$1/body"; }
gh_lock() { gh_release "$1"; cp "$2" "${GH}/releases/$1/assets/mica-build-env.lock"; printf 'x  mica-build-env.lock\n' >"${GH}/releases/$1/assets/SHA256SUMS"; }
release() { # release LABEL WANT_RC PATTERN TAG: run with the stubs, check rc and output
    : >"${LOG}"
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
none_called() { if [ -s "${LOG}" ] || [ -s "${GH}/log" ]; then fail "$1: $(cat "${LOG}" "${GH}/log" | tr '\n' ' ')"; else pass "$1"; fi; }
nothing_written() { if says "${GH}/log" '^POST \|^PATCH '; then fail "$1: $(grep '^POST \|^PATCH ' "${GH}/log" | tr '\n' ' ')"; else pass "$1"; fi; }
ASSETS="${GH}/releases/${T1}/assets"
notes() { cat "${GH}/releases/${T1}/body" 2>/dev/null; }

T0=20260101-0000
printf '\n' >>"${BE}/README.md"
g commit -q -am tagged
g update-ref refs/remotes/origin/main HEAD
HEAD_SHA="$(g rev-parse HEAD)"
gh_reset
gh_tag "${T1}" "${HEAD_SHA}"
release "a tag that is not YYYYMMDD-HHMM is refused" 1 "is not a release tag <YYYYMMDD-HHMM>" v0.0.1
none_called "... and nothing was asked of GitHub"
release "a time tag without the dash is refused" 1 "is not a release tag <YYYYMMDD-HHMM>" 202601020304
release "a tag that is not a real time is refused" 1 "not a UTC time YYYYMMDD-HHMM" 20261301-1200
release "a tag in the future is refused" 1 "a time in the future" 20990101-0000
none_called "... and nothing was asked of GitHub"
gh_tag "${T1}"
release "a tag that does not exist is refused" 1 "cut the release with gh release create" "${T1}"
nothing_written "... and nothing is written"
echo 502 >"${GH}/tags/${T1}.status"
release "a tag lookup that fails other than 404 is refused" 1 "could not read ${T1}" "${T1}"
gh_tag "${T1}" "$(printf '%040d' 7)"
release "a tag on another commit is refused" 1 "not the checked-out commit" "${T1}"
gh_tag "${T1}" "${HEAD_SHA}"

g update-ref refs/remotes/origin/main HEAD~1
release "a tagged commit that is not on main is refused" 1 "is not on origin/main" "${T1}"
g update-ref refs/remotes/origin/main HEAD

printf 'dirty\n' >>"${BE}/README.md"
release "a dirty tree is refused" 1 "uncommitted changes" "${T1}"
nothing_written "... and nothing is written"
g checkout -q -- .

release "a tag without a published release is refused" 1 "has no published release ${T1}" "${T1}"
nothing_written "... and nothing is written"
gh_release "${T1}"
printf 'other\n' >"${ASSETS}/mica-build-env.lock"
release "a release that already carries the lock with other bytes is refused" 1 "an asset is never replaced" "${T1}"
nothing_written "... and nothing is written"
gh_reset
gh_release "${T1}"
gh_release 20261231-2359
release "a release later than the tag is refused" 1 "has releases later than ${T1} (20261231-2359)" "${T1}"
nothing_written "... and nothing is written"

gh_reset
gh_release "${T1}"
mv "${REG}/tags" "${REG}/tags.kept" && mkdir "${REG}/tags"
release "a tag whose images are not published is refused" 1 "the images job publishes them for ${T1}" "${T1}"
nothing_written "... and nothing is written"
rm -rf "${REG}/tags" && mv "${REG}/tags.kept" "${REG}/tags"
STUB_DOCKER_FAIL=1 release "images that do not read anonymously are refused" 1 "not all published" "${T1}"
nothing_written "... and nothing is written"
sed -i "/^image${TAB}upstream${TAB}/s/@sha256:.*//" "${BE}/locks/upstream.lock"
g commit -q -am "an upstream image without a digest"
g update-ref refs/remotes/origin/main HEAD
gh_tag "${T1}" "$(g rev-parse HEAD)"
release "a locks/upstream.lock that breaks the file rules is refused" 1 "locks/upstream.lock is refused reference-digest" "${T1}"
nothing_written "... and nothing is written"
g reset -q --hard HEAD~1
g update-ref refs/remotes/origin/main HEAD
gh_tag "${T1}" "${HEAD_SHA}"

gh_reset
gh_release "${T1}" "Cut by hand."
release "the first release gets its assets" 0 "carries its assets" "${T1}"
! says "${GH}/log" '^POST /repos/micaoss/mica-build-env/releases$' && ! says "${GH}/log" '^DELETE ' &&
    pass "... attached to the existing release, which is neither created nor has an asset deleted" || fail "... requests: $(tr '\n' ' ' <"${GH}/log")"
[ "$(notes | sed -n 1p)" = 'Cut by hand.' ] && notes | grep -c 'Images: the first release carrying mica-build-env.lock.' >/dev/null &&
    notes | grep -c "mica-build-env ${HEAD_SHA}: mica-build-env.lock (mica-lock v1)" >/dev/null &&
    pass "... its notes keep the body and add the images note" || fail "... notes: $(notes | tr '\n' ' ')"
[ "$(ls "${ASSETS}" | LC_ALL=C sort | tr '\n' ' ')" = "SHA256SUMS mica-build-env.lock " ] && pass "... exactly two assets: mica-build-env.lock and SHA256SUMS" || fail "... assets: $(ls "${ASSETS}" | tr '\n' ' ')"
if (cd "${ASSETS}" && sha256sum -c --quiet SHA256SUMS) 2>/dev/null && [ "$(sed 's/^[0-9a-f]*  //' "${ASSETS}/SHA256SUMS")" = "mica-build-env.lock" ]; then
    pass "... SHA256SUMS lists only mica-build-env.lock"
else
    fail "... SHA256SUMS: $(cat "${ASSETS}/SHA256SUMS" 2>/dev/null)"
fi
got="$("${BE}/bin/mica-tools" lock check "${ASSETS}/mica-build-env.lock" 2>&1 || true)"
[ "${got}" = valid ] && pass "... the lock passes mica-tools lock check" || fail "... lock check: ${got}"
want_lock="$(printf '# mica-lock v1\nrelease\tmica-build-env\t%s\t%s\n' "${T1}" "${HEAD_SHA}"; { cat "${WORK}/good.rows"; grep "^image${TAB}upstream${TAB}" "${BE}/locks/upstream.lock"; } | LC_ALL=C sort -t "${TAB}" -k2,2 -k3,3 -k4,4)"
[ "$(cat "${ASSETS}/mica-build-env.lock")" = "${want_lock}" ] && pass "... the lock is the release row, then this repository's image rows and the upstream image rows of locks/upstream.lock, by source, name and platform" || fail "... lock: $(cat "${ASSETS}/mica-build-env.lock")"
[ "$(grep -c "^image${TAB}upstream${TAB}docker.io/\|${TAB}ghcr.io/micaoss/mica-build-env:upstream\." "${ASSETS}/mica-build-env.lock" || true)" = 0 ] &&
    pass "... upstream images keep their original names and references" || fail "... rewritten upstream rows"
[ "$(sed -n '3,5p' "${ASSETS}/mica-build-env.lock" | cut -f3,4 | tr '\t\n' ': ')" = "base:amd64 base:arm64 base:index " ] &&
    pass "... platforms sort as bytes: amd64, arm64, index" || fail "... order: $(head -n5 "${ASSETS}/mica-build-env.lock")"
[ "$(grep -c "^image${TAB}upstream${TAB}debian:trixie-slim${TAB}" "${ASSETS}/mica-build-env.lock")" = 2 ] &&
    ! says "${ASSETS}/mica-build-env.lock" "${TAB}386${TAB}" &&
    pass "... debian:trixie-slim carries the platforms the release guarantees, and no platform nothing builds for" ||
    fail "... debian rows: $(grep "debian:trixie-slim" "${ASSETS}/mica-build-env.lock")"
cp "${ASSETS}/mica-build-env.lock" "${WORK}/first.lock"
release "a second run over the attached release changes nothing" 0 "carries its assets" "${T1}"
[ "$(notes | grep -c 'Images: ')" = 1 ] && pass "... and its notes are not written twice" || fail "... notes: $(notes | tr '\n' ' ')"

sed "s/\.${T1}@sha256:/.${R0}@sha256:/" "${WORK}/first.lock" >"${WORK}/same.lock"
gh_reset; gh_lock "${T0}" "${WORK}/same.lock"; gh_release "${T1}"
release "a release after one with the same images under its own release tags" 0 "Images: unchanged from ${T0}." "${T1}"
sed "s/@sha256:[0-9a-f]*\$/@sha256:$(printf other | sha256sum | cut -d' ' -f1)/" "${WORK}/first.lock" >"${WORK}/other.lock"
gh_reset; gh_lock "${T0}" "${WORK}/other.lock"; gh_release "${T1}"
release "a release after one with other images" 0 "Images: changed from ${T0}." "${T1}"
notes | grep -c "A release whose images changed is a breaking update: every repository must update to it." >/dev/null &&
    pass "... and its notes say a changed release is a breaking update" || fail "... notes: $(notes | tr '\n' ' ')"
T00=20251231-2359
gh_reset; gh_lock "${T00}" "${WORK}/first.lock"; gh_release "${T0}"; gh_release "${T1}"
release "an earlier release without mica-build-env.lock is skipped for the comparison" 0 "Images: unchanged from ${T00}." "${T1}"
gh_reset; gh_release "${T0}"; gh_release "${T1}"
release "with no earlier release carrying the lock it is the first" 0 "Images: the first release carrying mica-build-env.lock." "${T1}"
gh_reset; gh_lock "${T0}" "${WORK}/first.lock"; touch "${GH}/releases/${T0}/unreadable"; gh_release "${T1}"
release "a previous lock that cannot be read leaves the notes unwritten" 1 "HTTP 404" "${T1}"
[ -z "$(notes)" ] && pass "... and the notes say nothing" || fail "... notes: $(notes | tr '\n' ' ')"
rm "${GH}/releases/${T0}/unreadable"
release "... a second run once it reads writes them" 0 "Images: unchanged from ${T0}." "${T1}"

echo
echo "publish-test: ${PASS_N} passed, ${FAIL_N} failed"
[ "${FAIL_N}" = 0 ]
