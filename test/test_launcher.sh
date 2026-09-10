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
    && "${launcher_content}" == *'git clone --depth 1 --branch "${target_branch}"'* \
    && "${launcher_content}" == *'"${repo_dir}/easy_all" register-command'* ]] \
    || fail "self-update must download and register the complete project"
[[ "${launcher_content}" != *'cp -a "${EASY_ALL_INSTALL_DIR}/." "${stage}/"'* ]] \
    || fail "runtime registration must not retain files removed from the manifest"
[[ "${launcher_content}" == *'"profiles/reality.sh"'* \
    && "${launcher_content}" == *'"profiles/xhttp-cloudflare-streamup.sh"'* \
    && "${launcher_content}" == *'"lib/globalping-cdn.sh"'* \
    && "${launcher_content}" == *'"worker-src/index.js"'* \
    && "${launcher_content}" == *'"scripts/build-worker.mjs"'* \
    && "${launcher_content}" == *'templates/mihomo.yaml'* ]] \
    || fail "runtime registration must use the organized profile and template paths"
for migration_tombstone in profiles/xhttp-gcore.sh lib/gcore-ip-pool.sh; do
    [[ -f "${ROOT_DIR}/${migration_tombstone}" ]] \
        || fail "legacy self-update migration tombstone is missing: ${migration_tombstone}"
    [[ "${launcher_content}" != *"${migration_tombstone}"* ]] \
        || fail "migration tombstone must not be installed at runtime: ${migration_tombstone}"
    ! grep -Eq '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${ROOT_DIR}/${migration_tombstone}" \
        || fail "migration tombstone must not contain executable functions: ${migration_tombstone}"
done
preserve_source="${TMP_DIR}/preserve-source"
preserve_stage="${TMP_DIR}/preserve-stage"
mkdir -p "${preserve_source}" "${preserve_stage}"
printf '#!/bin/sh\n' >"${preserve_source}/fail2ban-ufw-cidr.sh"
printf 'unmanaged\n' >"${preserve_source}/unmanaged-runtime-file"
stage_preserved_runtime_files "${preserve_source}" "${preserve_stage}"
[[ -x "${preserve_stage}/fail2ban-ufw-cidr.sh" ]] \
    || fail "runtime registration must preserve the managed Fail2ban helper"
[[ ! -e "${preserve_stage}/unmanaged-runtime-file" ]] \
    || fail "runtime registration must preserve only allowlisted runtime files"

self_update_invocation="${TMP_DIR}/self-update-invocation"
self_update_repo_path="${TMP_DIR}/self-update-repo-path"
self_update_branch="${TMP_DIR}/self-update-branch"
export SELF_UPDATE_INVOCATION_FILE="${self_update_invocation}"
export SELF_UPDATE_REPO_PATH_FILE="${self_update_repo_path}"
export SELF_UPDATE_BRANCH_FILE="${self_update_branch}"
git() {
    [[ "${1:-}" == "clone" ]] || return 1
    local destination="${!#}" relative_path
    printf '%s\n' "${destination}" >"${SELF_UPDATE_REPO_PATH_FILE}"
    printf '%s\n' "$5" >"${SELF_UPDATE_BRANCH_FILE}"
    mkdir -p "${destination}"
    for relative_path in easy_all templates/mihomo.yaml \
        "${EASY_ALL_RUNTIME_MODULES[@]}" "${EASY_ALL_RUNTIME_ASSETS[@]}"; do
        mkdir -p "${destination}/$(dirname -- "${relative_path}")"
        cp "${ROOT_DIR}/${relative_path}" "${destination}/${relative_path}"
    done
    if [[ "${SELF_UPDATE_OMIT_TARGET_MODULE:-0}" != "1" ]]; then
        printf '# target release module\n' >"${destination}/lib/target-only.sh"
    fi
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -e' \
        '[[ -f "$(dirname -- "$0")/lib/target-only.sh" ]] || { printf "missing target runtime module\n" >&2; exit 1; }' \
        'printf "%s\\n" "$*" >"${SELF_UPDATE_INVOCATION_FILE}"' \
        >"${destination}/easy_all"
    chmod 0700 "${destination}/easy_all"
    if [[ -n "${SELF_UPDATE_MISSING_PATH:-}" ]]; then
        rm -f -- "${destination}/${SELF_UPDATE_MISSING_PATH}"
    fi
    if [[ "${SELF_UPDATE_INVALID_LAUNCHER:-0}" == "1" ]]; then
        printf 'if\n' >"${destination}/easy_all"
    fi
}
make_temp_dir() { mktemp -d "${TMP_DIR}/self-update.XXXXXX"; }
require_root() { :; }
die() { fail "$*"; }
success() { :; }
unified_self_update
assert_equal "self-update invokes register-command in the downloaded tree" \
    "register-command" "$(<"${self_update_invocation}")"
assert_equal "self-update defaults to dev branch" \
    "dev" "$(<"${self_update_branch}")"
self_update_repo=$(<"${self_update_repo_path}")
[[ ! -e "${self_update_repo}" ]] \
    || fail "self-update must remove its temporary clone after registration"

unified_self_update "custom-feat"
assert_equal "self-update respects custom branch argument" \
    "custom-feat" "$(<"${self_update_branch}")"

runtime_validator=$(declare -f runtime_tree_is_complete)
runtime_tree_is_complete() { fail "installed release still requires a removed module"; }
unified_self_update
assert_equal "self-update delegates manifest validation to the target release" \
    "register-command" "$(<"${self_update_invocation}")"
eval "${runtime_validator}"

legacy_runtime_tree_is_complete() {
    local root=$1 relative_path
    for relative_path in easy_all templates/mihomo.yaml \
        profiles/xhttp-gcore.sh lib/gcore-ip-pool.sh; do
        [[ -f "${root}/${relative_path}" ]] || return 1
    done
}
assert_equal "legacy updater accepts the migration tombstones" \
    "yes" "$(legacy_runtime_tree_is_complete "${ROOT_DIR}" && printf 'yes')"

rm -f -- "${self_update_invocation}"
export -f git
assert_failure_contains "target release rejects its own missing module" \
    "missing target runtime module" \
    env ROOT_DIR="${ROOT_DIR}" TMP_DIR="${TMP_DIR}" SELF_UPDATE_OMIT_TARGET_MODULE=1 \
    bash -c '
        source "$1"
        require_root() { :; }
        make_temp_dir() { mktemp -d "${TMP_DIR}/update.XXXXXX"; }
        die() { printf "%s\n" "$*" >&2; exit 1; }
        success() { :; }
        unified_self_update
    ' _ "${ROOT_DIR}/easy_all"
[[ ! -e "${self_update_invocation}" ]] \
    || fail "incomplete target runtime must not be registered"

for missing_path in easy_all templates/mihomo.yaml; do
    SELF_UPDATE_MISSING_PATH="${missing_path}"
    assert_failure_contains "self-update identifies missing ${missing_path}" \
        "下载的 easy_all 项目缺少" unified_self_update
done
unset SELF_UPDATE_MISSING_PATH
SELF_UPDATE_INVALID_LAUNCHER=1
assert_failure_contains "self-update rejects invalid launcher syntax" \
    "下载的 easy_all 入口语法校验失败" unified_self_update
unset SELF_UPDATE_INVALID_LAUNCHER
[[ ! -e "${self_update_invocation}" ]] \
    || fail "invalid target entry must not be registered"

unset -f git make_temp_dir require_root die success
unset SELF_UPDATE_INVOCATION_FILE SELF_UPDATE_REPO_PATH_FILE SELF_UPDATE_BRANCH_FILE

[[ "${launcher_content}" == *'apply-cloud)'* \
    && "${launcher_content}" == *'"${mode}" == "cloudflare-streamup"'* \
    && "${launcher_content}" == *'apply_cloud_resources'* ]] \
    || fail "launcher must expose the explicit CDN cloud apply"
[[ "${launcher_content}" != *$'\n    update)'* \
    && "${launcher_content}" != *$'\n    update-cloud)'* ]] \
    || fail "launcher must not expose the removed update commands"

guide=$(show_install_guide 2>&1)
[[ "${guide}" == *"[1 默认] 直连 Reality"* \
    && "${guide}" == *"适用线路：优化线路"* && "${guide}" == *"适用线路：非优化线路"* \
    && "${guide}" == *"只有当前服务器时推荐部署订阅服务"* \
    && "${guide}" == *"多节点聚合或已有订阅服务器时推荐仅输出节点信息"* \
    && "${guide}" == *"[2] Cloudflare CDN 精选 IP - 纯 XHTTP stream-up"* \
    && "${guide}" == *"全网综合优选"* \
    && "${guide}" == *"Worker 为唯一公开聚合入口"* \
    && "${guide}" == *"默认 easyall"* \
    && "${guide}" == *"VPS 仅计出站时，月度出站额度通常是代理载荷的主要上限（并非严格等值）"* \
    && "${guide}" == *"XHTTP"* \
    && "${guide}" != *"AWS"* ]] \
    || fail "install guide does not describe the supported installation branches and defaults"
readme=$(<"${ROOT_DIR}/README.md")
[[ "${readme}" == *'A["easy_all install"] --> B{"选择安装模式"}'* ]] \
    || fail "README install flow must choose the mode before profile initialization"
[[ "${readme}" == *'R3 --> R4{"4/9 订阅输出选择"}'* \
    && "${readme}" == *'R4 -->|部署| R5["收集订阅域名、文件名、Token 或用户配额"]'* \
    && "${readme}" == *'R4 -->|仅节点| R6["不收集订阅服务参数"]'* \
    && "${readme}" == *'R5 --> R7["5-7/9 准备 Xray、配置 UFW、安装并验收 Reality"]'* \
    && "${readme}" == *'R6 --> R7'* \
    && "${readme}" == *'R7 --> R8["8/9 部署或清理订阅服务"]'* \
    && "${readme}" == *'R8 --> R9["9/9 完成证书轮换、保存状态、注册命令与任务"]'* \
    && "${readme}" == *'C1 --> C2["2/7 全局禁用 IPv6，收集节点域名、Globalping、订阅与 Worker 参数"]'* \
    && "${readme}" == *'C4 --> C5["5/7 Globalping 筛选 6 个 IPv4，生成并验收源订阅"]'* \
    && "${readme}" == *'C5 --> C6["6/7 构建上传 Worker，绑定独立订阅域名并完成聚合验收"]'* \
    && "${readme}" != *'选择 IPv4 或双栈'* \
    && "${readme}" != *'AWS'* \
    && "${readme}" != *'CloudFront'* \
    && "${readme}" != *'Route 53'* ]] \
    || fail "README install flow must match the installer execution order"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'请选择 [1]（直接回车使用默认值）:'* \
    && "$(<"${ROOT_DIR}/easy_all")" != *'Choose the installation mode:'* \
    && "$(<"${ROOT_DIR}/easy_all")" != *'Direct - Reality'* ]] \
    || fail "install mode prompt must be Chinese-only and explain the enter default"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'直连 - Reality（优化线路推荐）'* \
    && "$(<"${ROOT_DIR}/easy_all")" == *'Cloudflare CDN 精选 IP（非优化线路推荐）'* \
    && "$(<"${ROOT_DIR}/easy_all")" != *'AWS CDN 精选 IP - XHTTP'* ]] \
    || fail "install mode prompt must explain line recommendations"
interactive_sources=$(
    cat "${ROOT_DIR}/easy_all" \
        "${ROOT_DIR}/lib/profile-common.sh" \
        "${ROOT_DIR}/lib/subscription-auth.sh" \
        "${ROOT_DIR}/lib/quota.sh" \
        "${ROOT_DIR}/lib/scheduled-maintenance.sh" \
        "${ROOT_DIR}/lib/xhttp-runtime.sh" \
        "${ROOT_DIR}/profiles/reality.sh" \
        "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" \
        "${ROOT_DIR}/scripts/debian-init.sh"
)
for english_prompt in \
    "Choose the" "Choose [" "press Enter" "Delete local" \
    "Initial SSH login" "Current password" "Final non-root" \
    "Additional TCP ports" "Full subscription hostname"; do
    [[ "${interactive_sources}" != *"${english_prompt}"* ]] \
        || fail "interactive prompts must not contain English text: ${english_prompt}"
done
assert_equal "no state means no installed mode" "" "$(detect_installed_mode)"

printf 'STATE_VERSION=7\nPROTOCOL=reality\nCDN_PROVIDER=\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "Reality state selects Reality profile" "reality" "$(detect_installed_mode)"

printf 'STATE_VERSION=9\nPROTOCOL=cloudflare-streamup\nCDN_PROVIDER=cloudflare\n' >"${EASY_ALL_STATE_FILE}"
assert_equal "Cloudflare streamup state selects cloudflare-streamup" "cloudflare-streamup" "$(detect_installed_mode)"

printf 'STATE_VERSION=8\nPROTOCOL=cloudflare-streamup\nCDN_PROVIDER=cloudflare\n' >"${EASY_ALL_STATE_FILE}"
assert_failure_contains "stale Cloudflare state explains reinstall prerequisite" \
    "如需全新安装，请先执行 easy_all uninstall" \
    detect_installed_mode

printf 'STATE_VERSION=9\nPROTOCOL=singbox-cf\nCDN_PROVIDER=cloudflare\n' >"${EASY_ALL_STATE_FILE}"
assert_failure_contains "legacy singbox-cf state is rejected" \
    "无法识别已安装协议" \
    detect_installed_mode

printf 'STATE_VERSION=9\nPROTOCOL=xhttp\nCDN_PROVIDER=cloudflare\n' >"${EASY_ALL_STATE_FILE}"
assert_failure_contains "legacy xhttp state is rejected" \
    "无法识别已安装协议" \
    detect_installed_mode

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

if command -v python3 >/dev/null 2>&1; then
    pty_output_mode2=$(
        python3 -c "import pty, os, subprocess, sys
master, slave = os.openpty()
p = subprocess.Popen(['bash', '-c', 'source \"\$1\"; mode=\$(choose_install_mode); printf \"MODE=<\$mode>\\n\"', '_', sys.argv[1]], stdin=slave, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
os.close(slave)
os.write(master, b'2\n')
stdout, _ = p.communicate()
os.close(master)
sys.stdout.write(stdout.decode())" "${ROOT_DIR}/easy_all"
    )
    [[ "${pty_output_mode2}" == *"MODE=<cloudflare-streamup>"* ]] \
        || fail "interactive menu choice 2 failed: ${pty_output_mode2}"

fi

[[ "${launcher_content}" == *"1) printf 'reality"* \
    && "${launcher_content}" == *"2) printf 'cloudflare-streamup"* \
    && "${launcher_content}" != *"3) printf"* ]] \
    || fail "installation choices must retain only the supported modes in order"

printf 'ok - easy_all launcher tests passed\n'
