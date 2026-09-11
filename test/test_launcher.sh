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
manifest_content=$(<"${ROOT_DIR}/runtime.manifest")
[[ "${launcher_content}" == *'self-update [--dev|--branch <分支>]'* \
    && "${launcher_content}" == *'git clone --depth 1 --branch "${target_branch}"'* \
    && "${launcher_content}" == *'"${repo_dir}/easy_all" verify-release'* \
    && "${launcher_content}" == *'"${repo_dir}/easy_all" register-command'* ]] \
    || fail "self-update must download and register the complete project"
[[ "${launcher_content}" != *'cp -a "${EASY_ALL_INSTALL_DIR}/." "${stage}/"'* ]] \
    || fail "runtime registration must not retain files removed from the manifest"
[[ "${manifest_content}" == *'profiles/reality.sh'* \
    && "${manifest_content}" == *'profiles/xhttp-cloudflare-streamup.sh'* \
    && "${manifest_content}" == *'lib/runtime-core.sh'* \
    && "${manifest_content}" == *'lib/globalping-cdn.sh'* \
    && "${manifest_content}" == *'worker-src/index.js'* \
    && "${manifest_content}" == *'scripts/build-worker.mjs'* \
    && "${manifest_content}" == *'templates/mihomo.yaml'* ]] \
    || fail "runtime registration must use the organized profile and template paths"
runtime_tree_is_complete "${ROOT_DIR}" \
    || fail "repository runtime must satisfy its manifest"

# These tombstones bridge self-update for launchers that still validate the cloned
# tree against their own baked-in manifest. They must exist in the source tree, but
# must never be installed at runtime.
for migration_tombstone in profiles/xhttp-gcore.sh lib/gcore-ip-pool.sh; do
    [[ -f "${ROOT_DIR}/${migration_tombstone}" ]] \
        || fail "legacy self-update migration tombstone is missing: ${migration_tombstone}"
    [[ "${launcher_content}" != *"${migration_tombstone}"* ]] \
        || fail "migration tombstone must not be installed at runtime: ${migration_tombstone}"
    ! grep -Fxq "${migration_tombstone}" "${ROOT_DIR}/runtime.manifest" \
        || fail "migration tombstone must stay out of the runtime manifest: ${migration_tombstone}"
    ! grep -Eq '^[A-Za-z_][A-Za-z0-9_]*\(\)' "${ROOT_DIR}/${migration_tombstone}" \
        || fail "migration tombstone must not contain executable functions: ${migration_tombstone}"
done

invalid_manifest_root="${TMP_DIR}/invalid-manifest"
mkdir -p "${invalid_manifest_root}"
printf '../escape.sh\n' >"${invalid_manifest_root}/runtime.manifest"
if runtime_manifest_paths "${invalid_manifest_root}" >/dev/null 2>&1; then
    fail "runtime manifest must reject parent-directory traversal"
fi
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
    if [[ "${1:-}" == "check-ref-format" ]]; then
        [[ "${3:-}" != *..* && -n "${3:-}" ]]
        return
    fi
    [[ "${1:-}" == "clone" ]] || return 1
    local destination="${!#}" relative_path
    printf '%s\n' "${destination}" >"${SELF_UPDATE_REPO_PATH_FILE}"
    printf '%s\n' "$5" >"${SELF_UPDATE_BRANCH_FILE}"
    mkdir -p "${destination}"
    cp "${ROOT_DIR}/runtime.manifest" "${destination}/runtime.manifest"
    while IFS= read -r relative_path; do
        [[ -n "${relative_path}" && "${relative_path}" != \#* ]] || continue
        mkdir -p "${destination}/$(dirname -- "${relative_path}")"
        cp "${ROOT_DIR}/${relative_path}" "${destination}/${relative_path}"
    done <"${ROOT_DIR}/runtime.manifest"
    printf '%s\n' 'lib/target-only.sh' >>"${destination}/runtime.manifest"
    if [[ "${SELF_UPDATE_OMIT_TARGET_MODULE:-0}" != "1" ]]; then
        printf '# target release module\n' >"${destination}/lib/target-only.sh"
    fi
    printf '%s\n' '#!/usr/bin/env bash' \
        'set -e' \
        'root=$(cd -- "$(dirname -- "$0")" && pwd)' \
        'case "${1:-}" in' \
        'verify-release)' \
        '  [[ -f "${root}/lib/target-only.sh" ]] || { printf "missing target runtime module\n" >&2; exit 1; }' \
        '  while IFS= read -r path; do' \
        '    [[ -n "${path}" && "${path}" != \#* ]] || continue' \
        '    [[ -f "${root}/${path}" ]] || { printf "missing manifest path: %s\n" "${path}" >&2; exit 1; }' \
        '  done <"${root}/runtime.manifest"' \
        '  ;;' \
        'register-command) printf "%s\\n" "$*" >"${SELF_UPDATE_INVOCATION_FILE}" ;;' \
        '*) exit 1 ;;' \
        'esac' \
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
assert_equal "self-update defaults to main branch" \
    "main" "$(<"${self_update_branch}")"
self_update_repo=$(<"${self_update_repo_path}")
[[ ! -e "${self_update_repo}" ]] \
    || fail "self-update must remove its temporary clone after registration"

unified_self_update --dev
assert_equal "self-update --dev selects dev" \
    "dev" "$(<"${self_update_branch}")"
unified_self_update --branch "custom-feat"
assert_equal "self-update respects --branch" \
    "custom-feat" "$(<"${self_update_branch}")"
assert_failure_contains "self-update rejects unknown options" \
    "用法：easy_all self-update" unified_self_update --unknown
assert_failure_contains "self-update rejects invalid branches" \
    "无效的 Git 分支" unified_self_update --branch "bad..branch"

runtime_validator=$(declare -f runtime_tree_is_complete)
runtime_tree_is_complete() { fail "installed release still requires a removed module"; }
unified_self_update
assert_equal "self-update delegates manifest validation to the target release" \
    "register-command" "$(<"${self_update_invocation}")"
eval "${runtime_validator}"

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

SELF_UPDATE_MISSING_PATH="easy_all"
assert_failure_contains "self-update identifies missing easy_all" \
    "下载的 easy_all 项目缺少" unified_self_update
SELF_UPDATE_MISSING_PATH="runtime.manifest"
assert_failure_contains "self-update identifies missing runtime manifest" \
    "下载的 easy_all 项目缺少运行时清单" unified_self_update
SELF_UPDATE_MISSING_PATH="templates/mihomo.yaml"
assert_failure_contains "self-update identifies missing manifest path" \
    "missing manifest path" unified_self_update
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
    && "${guide}" == *"适用场景：直连效果良好，且 VPS 公网 IP 未被封锁"* \
    && "${guide}" == *"适用场景：直连效果不佳、VPS 公网 IP 已被封，或明确追求 Cloudflare CDN 纯 XHTTP"* \
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
[[ "${readme}" == *'## 选择模式'* \
    && "${readme}" == *'**1. 直连 Reality**'* \
    && "${readme}" == *'**2. Cloudflare CDN**'* \
    && "${readme}" == *'bootstrap.sh'* \
    && "${readme}" != *'选择 IPv4 或双栈'* \
    && "${readme}" != *'AWS'* \
    && "${readme}" != *'CloudFront'* \
    && "${readme}" != *'Route 53'* ]] \
    || fail "README onboarding must describe the supported installation modes"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'请选择 [1]（直接回车使用默认值）:'* \
    && "$(<"${ROOT_DIR}/easy_all")" != *'Choose the installation mode:'* \
    && "$(<"${ROOT_DIR}/easy_all")" != *'Direct - Reality'* ]] \
    || fail "install mode prompt must be Chinese-only and explain the enter default"
[[ "$(<"${ROOT_DIR}/easy_all")" == *'直连 - Reality（直连效果良好且 IP 未被封时）'* \
    && "$(<"${ROOT_DIR}/easy_all")" == *'Cloudflare CDN 精选 IP（直连不佳、IP 被封或追求纯 XHTTP 时）'* \
    && "$(<"${ROOT_DIR}/easy_all")" != *'AWS CDN 精选 IP - XHTTP'* ]] \
    || fail "install mode prompt must explain mode selection criteria"
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
