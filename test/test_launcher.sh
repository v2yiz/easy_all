#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_failure_contains() {
    local label=$1 expected=$2
    shift 2
    local output
    if output=$("$@" 2>&1); then
        fail "${label}: command unexpectedly succeeded"
    fi
    [[ "${output}" == *"${expected}"* ]] \
        || fail "${label}: missing '${expected}' in '${output}'"
}

export EASY_ALL_STATE_FILE_OVERRIDE="${TMP_DIR}/state.env"
# shellcheck source=/dev/null
source "${ROOT_DIR}/easy_all"

guide=$(show_install_guide 2>&1)
[[ "${guide}" == *"公共步骤"* && "${guide}" == *"[1 默认] 直连 Reality"* \
    && "${guide}" == *"适用线路：优化线路"* && "${guide}" == *"适用线路：非优化线路"* \
    && "${guide}" == *"只有当前服务器：推荐部署订阅服务"* \
    && "${guide}" == *"多节点聚合或已有订阅服务器：推荐仅输出节点信息"* \
    && "${guide}" == *"CDN XHTTP"* ]] \
    || fail "install guide does not describe both branches and defaults"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'请选择 [1]（直接回车使用默认值）: '* ]] \
    || fail "install mode prompt must explain the enter default"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'直连 - Reality（优化线路推荐）'* \
    && "$(<"${ROOT_DIR}/easy_all")" == *'CDN - XHTTP（非优化线路推荐）'* ]] \
    || fail "install mode prompt must explain line recommendations"

assert_equal "no state means no installed mode" "" "$(detect_installed_mode)"

printf 'STATE_VERSION=2\nPROTOCOL=reality\nCDN_PROVIDER=\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "Reality state selects Reality profile" "reality" "$(detect_installed_mode)"

printf 'STATE_VERSION=2\nPROTOCOL=xhttp\nCDN_PROVIDER=aws\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "XHTTP state selects XHTTP profile" "xhttp" "$(detect_installed_mode)"

rm -f -- "${EASY_ALL_STATE_FILE}"
assert_failure_contains "install rejects a mode argument" \
    "install 不接受协议参数" \
    env EASY_ALL_STATE_FILE_OVERRIDE="${EASY_ALL_STATE_FILE}" \
        "${ROOT_DIR}/easy_all" install reality

assert_failure_contains "install requires an interactive terminal" \
    "安装必须在交互终端中执行" \
    env EASY_ALL_STATE_FILE_OVERRIDE="${EASY_ALL_STATE_FILE}" \
        "${ROOT_DIR}/easy_all" install

ln -s "${ROOT_DIR}/easy_all" "${TMP_DIR}/easy_all-link"
resolved_root=$(
    bash -c 'source "$1"; printf "%s" "${EASY_ALL_ROOT}"' _ "${TMP_DIR}/easy_all-link"
)
assert_equal "symlinked command resolves the module root" "${ROOT_DIR}" "${resolved_root}"

if command -v script >/dev/null 2>&1; then
    pty_output=$(
        printf '\n' | script -q /dev/null bash -c \
            'source "$1"; mode=$(choose_install_mode); printf "MODE=<%s>\n" "$mode"' \
            _ "${ROOT_DIR}/easy_all"
    )
    [[ "${pty_output}" == *"MODE=<reality>"* ]] \
        || fail "interactive menu output polluted the selected mode: ${pty_output}"

fi

printf 'ok - easy_all launcher tests passed\n'
