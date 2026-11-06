#!/usr/bin/env bash

# Protocol-neutral runtime shared by all easy_all profiles.

readonly RUNTIME_LIB_DIR="${EASY_ALL_RUNTIME_LIB_DIR:?EASY_ALL_RUNTIME_LIB_DIR is required}"

# shellcheck source=lib/log.sh
source "${RUNTIME_LIB_DIR}/log.sh"
# shellcheck source=lib/platform.sh
source "${RUNTIME_LIB_DIR}/platform.sh"
# shellcheck source=lib/profile-common.sh
source "${RUNTIME_LIB_DIR}/profile-common.sh"
# shellcheck source=lib/network.sh
source "${RUNTIME_LIB_DIR}/network.sh"
# shellcheck source=lib/mihomo-template.sh
source "${RUNTIME_LIB_DIR}/mihomo-template.sh"
# shellcheck source=lib/firewall.sh
source "${RUNTIME_LIB_DIR}/firewall.sh"
# shellcheck source=lib/xray-core.sh
source "${RUNTIME_LIB_DIR}/xray-core.sh"
# shellcheck source=lib/scheduled-maintenance.sh
source "${RUNTIME_LIB_DIR}/scheduled-maintenance.sh"
# shellcheck source=lib/subscription-auth.sh
source "${RUNTIME_LIB_DIR}/subscription-auth.sh"
# shellcheck source=lib/worker-config.sh
source "${RUNTIME_LIB_DIR}/worker-config.sh"
# shellcheck source=lib/tcp-tuning.sh
source "${RUNTIME_LIB_DIR}/tcp-tuning.sh"

readonly RUNTIME_WRITE_LOCK_FILE="${RUNTIME_WRITE_LOCK_FILE_OVERRIDE:-/var/lib/easy_all/runtime-write.lock}"

RUNTIME_WRITE_LOCK_DEPTH=0

try_acquire_runtime_write_lock() {
    if ((RUNTIME_WRITE_LOCK_DEPTH > 0)); then
        RUNTIME_WRITE_LOCK_DEPTH=$((RUNTIME_WRITE_LOCK_DEPTH + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 \
        || die "缺少 flock；无法保护 easy_all 运行时更新"
    install -d -m 0700 "$(dirname "${RUNTIME_WRITE_LOCK_FILE}")" \
        || die "无法创建 easy_all 运行时锁目录"
    exec 9>"${RUNTIME_WRITE_LOCK_FILE}" \
        || die "无法打开 easy_all 运行时锁：${RUNTIME_WRITE_LOCK_FILE}"
    if ! flock -w "${1:-0}" 9; then
        exec 9>&-
        return 1
    fi
    RUNTIME_WRITE_LOCK_DEPTH=1
}

acquire_runtime_write_lock() {
    try_acquire_runtime_write_lock "${1:-0}" \
        || die "另一个 easy_all 配置或运行时任务正在运行，请稍后重试"
}

release_runtime_write_lock() {
    ((RUNTIME_WRITE_LOCK_DEPTH > 0)) || return 0
    RUNTIME_WRITE_LOCK_DEPTH=$((RUNTIME_WRITE_LOCK_DEPTH - 1))
    ((RUNTIME_WRITE_LOCK_DEPTH == 0)) || return 0
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
}

# 允许调用方（测试或外部编排）注入隔离临时目录；只有自己创建时才登记清理，
# 否则退出时会删掉不属于 easy_all 的目录。
RUNTIME_TMP_CREATED=0
if [[ -z "${RUNTIME_TMP:-}" ]]; then
    RUNTIME_TMP=$(mktemp -d)
    RUNTIME_TMP_CREATED=1
fi
cleanup_files=()
((RUNTIME_TMP_CREATED == 0)) || cleanup_files=("${RUNTIME_TMP}")
INSTALL_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_ON_EXIT=0
UPDATE_SUB_BACKUP_DIR=""
MIHOMO_TEMPLATE_FILE=""

cleanup() {
    local status=$?
    local path
    if declare -F worker_backup_stop_probe >/dev/null 2>&1; then
        worker_backup_stop_probe || true
    fi
    # 安装中途失败：先说明失败位置与阶段，再由用户决定是否清理本机残留。
    if [[ "${status}" != "0" ]] && declare -F install_failure_report >/dev/null 2>&1; then
        install_failure_report || true
    fi
    if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        if [[ -n "${UPDATE_SUB_BACKUP_DIR:-}" ]]; then
            rollback_subscription_update || true
        else
            warn "订阅更新要求回滚，但备份目录为空"
        fi
    elif [[ "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        INSTALL_ROLLBACK_ON_EXIT=0
        if [[ "${status}" != "0" ]] && declare -F install_cleanup_after_failure >/dev/null 2>&1; then
            install_cleanup_after_failure rollback || true
        else
            rollback_fresh_install || true
        fi
    elif [[ "${status}" != "0" && "${INSTALL_FAILURE_ARMED:-0}" == "1" ]] \
        && declare -F install_cleanup_after_failure >/dev/null 2>&1 \
        && [[ -n "$(install_progress_field PROFILE 2>/dev/null || true)" ]]; then
        # 安装流程在拍快照之前就失败了：仍可只清理本机残留。
        install_cleanup_after_failure partial || true
    fi
    if declare -F recover_pending_service_policy >/dev/null 2>&1; then
        recover_pending_service_policy \
            || warn "恢复 policy-rc.d 事务失败：事务已保留，下次运行安装/清理会自动重试"
    fi
    while ((RUNTIME_WRITE_LOCK_DEPTH > 0)); do
        release_runtime_write_lock || break
    done
    for path in "${cleanup_files[@]:-}"; do
        [[ -n "${path}" ]] && rm -rf -- "${path}"
    done
    return 0
}
trap cleanup EXIT

# One-shot maintenance units write runtime state on exit, so an uninstall must wait for
# any running job to finish (including its own rollback) before deleting files.
stop_maintenance_services() {
    command -v systemctl >/dev/null 2>&1 || return 0
    systemctl stop easy_all-globalping-refresh.service \
        2>/dev/null || true
}

uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

# Profiles whose local subscription content depends on the installed core version define this
# hook (the ML-KEM gate of Reality and combined modes); the Cloudflare-streamup and Bunny
# subscriptions are core-independent and omit it.
refresh_runtime_subscription_after_core_update() {
    declare -F refresh_runtime_subscription >/dev/null 2>&1 || return 0
    # Run in a subshell so a republication failure cannot abort the completed core swap.
    (refresh_runtime_subscription) \
        || warn "核心已更新，但订阅未重新生成；请执行 sudo easy_all apply"
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/xray-backup"
    local backup_config="${RUNTIME_TMP}/xray-config-backup.json"
    local backup_version="${RUNTIME_TMP}/xray-version-backup"
    local version_missing="${RUNTIME_TMP}/xray-version.missing"
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    install -m 0755 "${XRAY_BIN}" "${backup_bin}"
    install -m 0600 "${XRAY_CONFIG}" "${backup_config}"
    if [[ -f "${XRAY_DIR}/version" ]]; then
        install -m 0644 "${XRAY_DIR}/version" "${backup_version}"
    else
        install -m 0600 /dev/null "${version_missing}"
    fi
    if (
        download_xray || exit 1
        systemctl restart "${XRAY_SERVICE}" || exit 1
        validate_protocol_runtime || exit 1
    ); then
        refresh_runtime_subscription_after_core_update
        release_runtime_write_lock
        success "Xray 已更新"
        return 0
    fi
    warn "新核心验收失败，正在恢复旧二进制、版本与运行时配置"
    install -m 0755 "${backup_bin}" "${XRAY_BIN}"
    install -m 0600 "${backup_config}" "${XRAY_CONFIG}"
    if [[ -f "${backup_version}" ]]; then
        install -m 0644 "${backup_version}" "${XRAY_DIR}/version"
    elif [[ -f "${version_missing}" ]]; then
        rm -f -- "${XRAY_DIR}/version"
    fi
    systemctl restart "${XRAY_SERVICE}" \
        || die "恢复旧 Xray 后无法重启 ${XRAY_SERVICE}"
    validate_protocol_runtime
    die "Xray 更新失败，已恢复旧版本"
}
