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

launcher_content=$(<"${ROOT_DIR}/easy_all")
[[ "${launcher_content}" == *'self-update      只更新 easy_all 项目代码'* \
    && "${launcher_content}" == *'git clone --depth 1 --branch main'* \
    && "${launcher_content}" == *'"${repo_dir}/easy_all" register-command'* ]] \
    || fail "self-update must download and register the complete project"
[[ "${launcher_content}" == *'apply-cloud)'* \
    && "${launcher_content}" == *'apply_cloud_resources'* ]] \
    || fail "launcher must expose the explicit XHTTP cloud apply"
[[ "${launcher_content}" != *$'\n    update)'* \
    && "${launcher_content}" != *$'\n    update-cloud)'* ]] \
    || fail "launcher must not expose the removed update commands"

guide=$(show_install_guide 2>&1)
[[ "${guide}" == *"[1 默认] 直连 Reality"* \
    && "${guide}" == *"适用线路：优化线路"* && "${guide}" == *"适用线路：非优化线路"* \
    && "${guide}" == *"只有当前服务器时推荐部署订阅服务"* \
    && "${guide}" == *"多节点聚合或已有订阅服务器时推荐仅输出节点信息"* \
    && "${guide}" == *"CDN XHTTP"* ]] \
    || fail "install guide does not describe both branches and defaults"
readme=$(<"${ROOT_DIR}/README.md")
[[ "${readme}" == *'A[easy_all install] --> B{先选择安装模式}'* ]] \
    || fail "README install flow must choose the mode before profile initialization"
[[ "${readme}" == *'R3 -->|部署| R4[订阅域名、文件名、Token 或用户配额]'* \
    && "${readme}" == *'R3 -->|仅节点| R5[准备仅节点输出]'* \
    && "${readme}" == *'R4 --> R6D[公共运行时：下载 Xray / 配置 UFW / 安装并验收 Xray]'* \
    && "${readme}" == *'R5 --> R6L[公共运行时：下载 Xray / 配置 UFW / 安装并验收 Xray]'* \
    && "${readme}" == *'R6D --> R8[安装 Nginx / 申请订阅证书 / 生成并验收订阅]'* \
    && "${readme}" == *'R6L --> R9[仅输出节点，不安装订阅服务]'* \
    && "${readme}" == *'R8 --> R10[保存最终状态 / 注册 easy_all / 配置配额任务]'* \
    && "${readme}" == *'X4 --> X6[AWS IAM / Route 53 源站 A 记录]'* \
    && "${readme}" == *'X6 --> X7[配置 UFW / Nginx HTTP-01 / 源站证书 / 安装 Xray 与 Nginx]'* \
    && "${readme}" == *'X7 --> X8[ACM 证书 / CloudFront / Route 53 CDN CNAME]'* \
    && "${readme}" == *'X8 --> X9[保存状态并注册 easy_all]'* ]] \
    || fail "README install flow must match the installer execution order"
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
