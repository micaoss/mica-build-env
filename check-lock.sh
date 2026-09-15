#!/usr/bin/env bash
# Check a file against the file rules of mica-lock v1
# (mica:docs/design/release-lock.md) and print `valid`, or `refused <rule>` and
# exit 1 at the first rule it breaks.
#
#   bash check-lock.sh lock <file>        a release lock (sections 1.1 to 1.5)
#   bash check-lock.sh upstream <file>    locks/upstream.lock (section 4.1)
#
# publish-release.sh runs it over the lock it writes, pins.sh and
# publish-mirrors.sh over locks/upstream.lock, tests/publish-test.sh over the
# specification's vectors. Registry checks are not file rules.
set -euo pipefail
export LC_ALL=C

[ "$#" -eq 2 ] && { [ "$1" = lock ] || [ "$1" = upstream ]; } || { echo "usage: bash check-lock.sh lock|upstream <file>" >&2; exit 2; }
MODE="$1"
FILE="$2"
[ -f "${FILE}" ] || { echo "error: ${FILE} is not a file" >&2; exit 2; }

refuse() { echo "refused $1"; exit 1; }

KINDS=(release image pool package board upstream apt)
declare -A COLUMNS=([release]=4 [image]=4 [pool]=3 [package]=5 [board]=4 [upstream]=7 [apt]=5)
kind_index() { local i; for i in "${!KINDS[@]}"; do [ "${KINDS[$i]}" != "$1" ] || { echo "$i"; return; }; done; }

# 1.1: UTF-8, LF with a final LF, no CR, header, no empty line, leading space or trailing tab.
iconv -f UTF-8 -t UTF-8 "${FILE}" >/dev/null 2>&1 || refuse encoding
[ -s "${FILE}" ] && [ "$(tail -c1 "${FILE}" | od -An -tx1 | tr -d ' ')" = 0a ] || refuse encoding
[ "$(tr -dc '\r' <"${FILE}" | wc -c)" = 0 ] || refuse encoding
mapfile -t LINES <"${FILE}"
[ "${LINES[0]}" = "# mica-lock v1" ] || refuse header

ROWS=()
for line in "${LINES[@]:1}"; do
    [ -n "${line}" ] || refuse encoding
    case "${line}" in ' '*) refuse encoding ;; *$'\t') refuse encoding ;; '#'*) continue ;; esac
    ROWS+=("${line}")
done

# split <row>: FIELDS, split on every tab (empty fields kept).
split() {
    local rest="$1"
    FIELDS=()
    while [[ "${rest}" == *$'\t'* ]]; do
        FIELDS+=("${rest%%$'\t'*}")
        rest="${rest#*$'\t'}"
    done
    FIELDS+=("${rest}")
}

NAME_RE='^[a-z0-9][a-z0-9.+-]*$'
VERSION_RE='^[A-Za-z0-9.+~:-]+$'
SHA_RE='^[0-9a-f]{64}$'
ARCH_RE='^(amd64|arm64)$'

# 4.1: no release row; image, source and git rows only.
if [ "${MODE}" = upstream ]; then
    declare -A UCOLUMNS=([image]=4 [source]=6 [git]=5)
    UKINDS=(image source git)
    for row in ${ROWS[@]+"${ROWS[@]}"}; do
        split "${row}"
        [ "${FIELDS[0]}" != release ] || refuse upstream-release-row
        [ -n "${UCOLUMNS[${FIELDS[0]}]-}" ] || refuse kind-unknown
        [ "${#FIELDS[@]}" = "${UCOLUMNS[${FIELDS[0]}]}" ] || refuse column-count
    done
    declare -A KEYS=()
    SORTKEYS=()
    for row in ${ROWS[@]+"${ROWS[@]}"}; do
        split "${row}"
        kind="${FIELDS[0]}"
        case "${kind}" in
        image)
            [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" =~ ^(index|amd64|arm64|386)$ ]] || refuse field-value
            [[ "${FIELDS[3]}" == *@sha256:* ]] || refuse reference-digest
            [[ "${FIELDS[3]}" =~ ^[a-z0-9.-]+(:[0-9]+)?/[a-z0-9._/-]+(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] || refuse field-value
            key="${FIELDS[1]}"$'\x01'"${FIELDS[2]}"
            ;;
        source)
            [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" =~ ^(amd64|arm64|all)$ ]] && [[ "${FIELDS[3]}" =~ ${VERSION_RE} ]] &&
                [[ "${FIELDS[4]}" =~ ${SHA_RE} ]] && [[ "${FIELDS[5]}" == https://* ]] || refuse field-value
            key="${FIELDS[1]}"$'\x01'"${FIELDS[2]}"
            ;;
        git)
            [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" == https://* ]] && [ -n "${FIELDS[3]}" ] && [[ "${FIELDS[4]}" =~ ^[0-9a-f]{40}$ ]] || refuse field-value
            key="${FIELDS[1]}"
            ;;
        esac
        [ -z "${KEYS[${kind}$'\x02'${key}]-}" ] || refuse duplicate-key
        KEYS["${kind}"$'\x02'"${key}"]=1
        for i in "${!UKINDS[@]}"; do [ "${UKINDS[$i]}" != "${kind}" ] || SORTKEYS+=("${i}"$'\x01'"${key}"); done
    done
    for ((i = 1; i < ${#SORTKEYS[@]}; i++)); do
        [[ ! "${SORTKEYS[$((i - 1))]}" > "${SORTKEYS[$i]}" ]] || refuse sort-order
    done
    echo valid
    exit 0
fi

for row in ${ROWS[@]+"${ROWS[@]}"}; do
    split "${row}"
    [ -n "${COLUMNS[${FIELDS[0]}]-}" ] || refuse kind-unknown
    [ "${#FIELDS[@]}" = "${COLUMNS[${FIELDS[0]}]}" ] || refuse column-count
done

releases=0
for row in ${ROWS[@]+"${ROWS[@]}"}; do [ "${row%%$'\t'*}" != release ] || releases=$((releases + 1)); done
[ "${#ROWS[@]}" -gt 0 ] && [ "${ROWS[0]%%$'\t'*}" = release ] && [ "${releases}" = 1 ] || refuse release-row

split "${ROWS[0]}"
REPOSITORY="${FIELDS[1]}" RELEASE="${FIELDS[2]}"
[[ "${REPOSITORY}" =~ ^[a-z0-9][a-z0-9-]*$ ]] && { [[ "${RELEASE}" =~ ^[0-9]{8}-[0-9]{4}$ ]] || [ "${RELEASE}" = offline ]; } &&
    [[ "${FIELDS[3]}" =~ ^[0-9a-f]{40}$ ]] || refuse field-value
REGISTRY=ghcr.io/micaoss
[ "${RELEASE}" != offline ] || REGISTRY=local

reference() {
    [[ "$1" =~ ^(ghcr\.io/micaoss|local)/([a-z0-9][a-z0-9-]*)(:[A-Za-z0-9._-]+)?@sha256:[0-9a-f]{64}$ ]] || {
        [[ "$1" == *@sha256:* ]] && refuse field-value
        refuse reference-digest
    }
    [ "${BASH_REMATCH[1]}" = "${REGISTRY}" ] || refuse reference-registry
    [ "${BASH_REMATCH[2]}" = "${REPOSITORY}" ] || refuse reference-repository
}

declare -A KEYS=() POOLS=()
SORTKEYS=() PACKAGE_ARCHES=() BASE_ONLY=0
for row in "${ROWS[@]:1}"; do
    split "${row}"
    kind="${FIELDS[0]}"
    case "${kind}" in
    image)
        [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" =~ ^(index|amd64|arm64|386)$ ]] || refuse field-value
        reference "${FIELDS[3]}"
        key="${FIELDS[1]}"$'\x01'"${FIELDS[2]}"
        ;;
    pool)
        [[ "${FIELDS[1]}" =~ ${ARCH_RE} ]] || refuse field-value
        reference "${FIELDS[2]}"
        key="${FIELDS[1]}"
        POOLS["${FIELDS[1]}"]=1
        ;;
    package)
        [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" =~ ${ARCH_RE} ]] && [[ "${FIELDS[3]}" =~ ${VERSION_RE} ]] && [[ "${FIELDS[4]}" =~ ${SHA_RE} ]] || refuse field-value
        key="${FIELDS[1]}"$'\x01'"${FIELDS[2]}"
        PACKAGE_ARCHES+=("${FIELDS[2]}")
        ;;
    board)
        [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" =~ ${ARCH_RE} ]] || refuse field-value
        reference "${FIELDS[3]}"
        key="${FIELDS[1]}"
        ;;
    upstream)
        roots="${FIELDS[6]}"
        sorted="$(tr ',' '\n' <<<"${roots}" | sort -u | paste -sd, -)"
        ok=1
        for r in ${roots//,/ }; do [[ "${r}" =~ ${NAME_RE} ]] || ok=0; done
        [[ "${FIELDS[1]}" =~ ${NAME_RE} ]] && [[ "${FIELDS[2]}" =~ ${ARCH_RE} ]] && [[ "${FIELDS[3]}" =~ ${VERSION_RE} ]] &&
            [[ "${FIELDS[4]}" =~ ${SHA_RE} ]] && [[ "${FIELDS[5]}" == https://* ]] && [ "${ok}" = 1 ] && [ "${sorted}" = "${roots}" ] || refuse field-value
        key="${FIELDS[1]}"$'\x01'"${FIELDS[2]}"
        BASE_ONLY=1
        ;;
    apt)
        [[ "${FIELDS[1]}" == https://* ]] && [ -n "${FIELDS[2]}" ] && [ -n "${FIELDS[3]}" ] && [[ "${FIELDS[4]}" == /* ]] || refuse field-value
        key=""
        BASE_ONLY=1
        ;;
    *) refuse release-row ;;
    esac
    [ -z "${KEYS[${kind}$'\x02'${key}]-}" ] || refuse duplicate-key
    KEYS["${kind}"$'\x02'"${key}"]=1
    SORTKEYS+=("$(kind_index "${kind}")"$'\x01'"${key}")
done

[ "${REPOSITORY}" = mica-system-base ] || [ "${BASE_ONLY}" = 0 ] || refuse base-only-kind
for a in ${PACKAGE_ARCHES[@]+"${PACKAGE_ARCHES[@]}"}; do [ -n "${POOLS[${a}]-}" ] || refuse package-without-pool; done
for ((i = 1; i < ${#SORTKEYS[@]}; i++)); do
    [[ ! "${SORTKEYS[$((i - 1))]}" > "${SORTKEYS[$i]}" ]] || refuse sort-order
done
echo valid
