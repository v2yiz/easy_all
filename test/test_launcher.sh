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

cron_path=$(
    env -i PATH=/usr/bin:/bin bash -c \
        'source "$1"; printf "%s" "$PATH"' _ "${ROOT_DIR}/easy_all"
)
[[ ":${cron_path}:" == *":/usr/local/sbin:"* \
    && ":${cron_path}:" == *":/usr/sbin:"* \
    && ":${cron_path}:" == *":/sbin:"* ]] \
    || fail "launcher must restore administrative command paths for cron"

launcher_content=$(<"${ROOT_DIR}/easy_all")
[[ "${launcher_content}" == *'self-update      只更新 easy_all 项目代码'* \
    && "${launcher_content}" == *'git clone --depth 1 --branch main'* \
    && "${launcher_content}" == *'"${repo_dir}/easy_all" register-command'* ]] \
    || fail "self-update must download and register the complete project"
[[ "${launcher_content}" != *'cp -a "${EASY_ALL_INSTALL_DIR}/." "${stage}/"'* ]] \
    || fail "runtime registration must not retain files removed from the manifest"
[[ "${launcher_content}" == *'"profiles/reality.sh"'* \
    && "${launcher_content}" == *'"profiles/xhttp-cloudflare.sh"'* \
    && "${launcher_content}" == *'"profiles/xhttp-aws.sh"'* \
    && "${launcher_content}" == *'"lib/globalping-cdn.sh"'* \
    && "${launcher_content}" == *'templates/mihomo.yaml'* ]] \
    || fail "runtime registration must use the organized profile and template paths"
preserve_source="${TMP_DIR}/preserve-source"
preserve_stage="${TMP_DIR}/preserve-stage"
mkdir -p "${preserve_source}" "${preserve_stage}"
printf '#!/bin/sh\n' >"${preserve_source}/fail2ban-ufw-cidr.sh"
printf '#!/bin/sh\n' >"${preserve_source}/reload-subscription-nginx.sh"
printf 'unmanaged\n' >"${preserve_source}/unmanaged-runtime-file"
stage_preserved_runtime_files "${preserve_source}" "${preserve_stage}"
[[ -x "${preserve_stage}/fail2ban-ufw-cidr.sh" \
    && -x "${preserve_stage}/reload-subscription-nginx.sh" ]] \
    || fail "runtime registration must preserve managed helper scripts"
[[ ! -e "${preserve_stage}/unmanaged-runtime-file" ]] \
    || fail "runtime registration must preserve only allowlisted runtime files"

self_update_invocation="${TMP_DIR}/self-update-invocation"
self_update_repo_path="${TMP_DIR}/self-update-repo-path"
export SELF_UPDATE_INVOCATION_FILE="${self_update_invocation}"
export SELF_UPDATE_REPO_PATH_FILE="${self_update_repo_path}"
git() {
    [[ "${1:-}" == "clone" ]] || return 1
    local destination="${!#}" relative_path
    printf '%s\n' "${destination}" >"${SELF_UPDATE_REPO_PATH_FILE}"
    mkdir -p "${destination}"
    for relative_path in easy_all templates/mihomo.yaml "${EASY_ALL_RUNTIME_MODULES[@]}"; do
        mkdir -p "${destination}/$(dirname -- "${relative_path}")"
        cp "${ROOT_DIR}/${relative_path}" "${destination}/${relative_path}"
    done
    printf '%s\n' '#!/usr/bin/env bash' \
        'printf "%s\\n" "$*" >"${SELF_UPDATE_INVOCATION_FILE}"' \
        >"${destination}/easy_all"
    chmod 0700 "${destination}/easy_all"
}
make_temp_dir() { mktemp -d "${TMP_DIR}/self-update.XXXXXX"; }
require_root() { :; }
die() { fail "$*"; }
success() { :; }
unified_self_update
assert_equal "self-update invokes register-command in the downloaded tree" \
    "register-command" "$(<"${self_update_invocation}")"
self_update_repo=$(<"${self_update_repo_path}")
[[ ! -e "${self_update_repo}" ]] \
    || fail "self-update must remove its temporary clone after registration"
unset -f git make_temp_dir require_root die success
unset SELF_UPDATE_INVOCATION_FILE SELF_UPDATE_REPO_PATH_FILE

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
    && "${guide}" == *"[2] Cloudflare CDN 精选 IP - XHTTP"* \
    && "${guide}" == *"CLOUDFLARE_API_TOKEN"* \
    && "${guide}" == *"选择 CloudFront 计费：1 Free 固定套餐，或 2 按量付费（默认推荐；升级 Paid plan 本身不收费）"* \
    && "${guide}" == *"Choose CloudFront billing: 1 Free flat-rate, or 2 pay-as-you-go (recommended; upgrading the Paid plan itself is free)"* \
    && "${guide}" == *"Globalping 使用中国大陆探针"* \
    && "${guide}" == *"[3] AWS CDN 精选 IP - XHTTP"* \
    && "${guide}" == *"CDN XHTTP"* ]] \
    || fail "install guide does not describe all installation branches and defaults"
readme=$(<"${ROOT_DIR}/README.md")
[[ "${readme}" == *'A[easy_all install] --> B{先选择安装模式}'* ]] \
    || fail "README install flow must choose the mode before profile initialization"
[[ "${readme}" == *'R3 --> R4{订阅输出选择}'* \
    && "${readme}" == *'R4 -->|部署| R5[订阅域名、文件名、Token 或用户配额]'* \
    && "${readme}" == *'R4 -->|仅节点| R6[不收集订阅服务参数]'* \
    && "${readme}" == *'R5 --> R7[公共运行时：下载 Xray / 配置 UFW / 安装并验收 Xray]'* \
    && "${readme}" == *'R6 --> R7'* \
    && "${readme}" == *'R7 --> R8[应用已选输出：部署 Nginx/证书/订阅，或清理订阅服务]'* \
    && "${readme}" == *'R8 --> R9[保存最终状态 / 注册 easy_all / 配置配额任务]'* \
    && "${readme}" == *'X5 --> X7[AWS IAM 授权（同一命令内复用）/ Route 53 源站 A]'* \
    && "${readme}" == *'X7 --> X8[UFW / Nginx HTTP-01]'* \
    && "${readme}" == *'X8 --> X9[源站证书 / Xray / Nginx / 本机运行时验收]'* \
    && "${readme}" == *'X3 --> X3A{CloudFront 计费模式选择}'* \
    && "${readme}" == *'X3A -->|Free 固定套餐| X4{订阅输出选择}'* \
    && "${readme}" == *'X3A -->|按量付费| X4'* \
    && "${readme}" == *'X9 --> X10[ACM / Paid account plan 检查或确认升级（升级本身不收费）/ CloudFront Aliases / Route 53 Alias A/AAAA / 公网验收 / Globalping 精选 IPv4 / 生成订阅]'* \
    && "${readme}" == *'X10 --> X11[保存状态 / 注册 easy_all / 配置用户配额与全局费用保护任务]'* ]] \
    || fail "README install flow must match the installer execution order"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'请选择 [1]（直接回车使用默认值）:'* \
    && "$(<"${ROOT_DIR}/easy_all")" == *'Choose [1] (press Enter to use the default):'* ]] \
    || fail "install mode prompt must be bilingual and explain the enter default"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'直连 - Reality（优化线路推荐）'* \
    && "$(<"${ROOT_DIR}/easy_all")" == *'Cloudflare CDN 精选 IP - XHTTP'* \
    && "$(<"${ROOT_DIR}/easy_all")" == *'AWS CDN 精选 IP - XHTTP'* ]] \
    || fail "install mode prompt must explain line recommendations"
assert_equal "no state means no installed mode" "" "$(detect_installed_mode)"

printf 'STATE_VERSION=5\nPROTOCOL=reality\nCDN_PROVIDER=\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "Reality state selects Reality profile" "reality" "$(detect_installed_mode)"

printf 'STATE_VERSION=7\nPROTOCOL=xhttp\nCDN_PROVIDER=cloudflare\nCLOUDFLARE_CDN_ENDPOINT_MODE=optimized\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "Cloudflare state selects the second mode" "cloudflare" "$(detect_installed_mode)"

printf 'STATE_VERSION=7\nPROTOCOL=xhttp\nCDN_PROVIDER=aws\nAWS_CLOUDFRONT_BILLING_MODE=payg\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "AWS state selects the third mode" "aws-cdn" "$(detect_installed_mode)"

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

[[ "${launcher_content}" == *"2) printf 'cloudflare"* \
    && "${launcher_content}" == *"3) printf 'aws-cdn"* ]] \
    || fail "installation choices must retain the three supported modes in order"

printf 'ok - easy_all launcher tests passed\n'
