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
    # 显式模板：macOS 的 mktemp 在无模板时忽略 TMPDIR，直接落到系统临时目录，
    # 受限环境（沙箱/CI）会 EPERM；GNU mktemp 行为不变。
    RUNTIME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/easy_all-runtime.XXXXXXXX") \
        || die "无法创建运行时临时目录"
    RUNTIME_TMP_CREATED=1
fi
cleanup_files=()
((RUNTIME_TMP_CREATED == 0)) || cleanup_files=("${RUNTIME_TMP}")
INSTALL_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_NO_RESTART=0
UPDATE_SUB_BACKUP_DIR=""
MIHOMO_TEMPLATE_FILE=""

cleanup() {
    local status=$?
    local path
    # 安装中途失败：先说明失败位置与阶段，再由用户决定是否清理本机残留。
    if [[ "${status}" != "0" ]] && declare -F install_failure_report >/dev/null 2>&1; then
        install_failure_report || true
    fi
    # 云端保留资源的点名必须早于可能 die 的回滚动作：回滚里的状态恢复失败会 exit，
    # 放在回滚之后就会漏报本次已签发的新证书。
    if [[ "${status}" != "0" ]] && declare -F profile_report_retained_resources >/dev/null 2>&1; then
        profile_report_retained_resources || true
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
    # 凭据只允许存在于内存：成功、失败、EXIT、INT/TERM 都走同一清理钩子。
    if declare -F clear_profile_credentials >/dev/null 2>&1; then
        clear_profile_credentials || true
    fi
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
    # 先停 timer 再停 oneshot service：否则 timer 可能在删除过程中重新拉起任务。
    systemctl stop easy_all-cdn-traffic-guard.timer 2>/dev/null || true
    systemctl stop easy_all-cdn-traffic-guard.service 2>/dev/null || true
}

uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

# Profiles whose local subscription content depends on the installed core version define this
# hook (the ML-KEM gate of Reality and combined modes).
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
    local restart_allowed=1
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if declare -F cdn_traffic_needs_restricted_recovery >/dev/null 2>&1 \
        && cdn_traffic_needs_restricted_recovery; then
        die "CDN 流量保护仍待落实；请先执行 sudo easy_all cdn-traffic-sync（订阅损坏先 edit-sub，证书故障先 renew-cert）再更新核心"
    fi
    if declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1; then
        cdn_traffic_protection_checkpoint \
            || die "流量 checkpoint 产生待落实的 CDN 阻断状态；已中止核心更新，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    # 备份不完整就不能开始覆盖：回滚依据必须先完整存在。
    install -m 0755 "${XRAY_BIN}" "${backup_bin}" \
        || die "备份当前 Xray 二进制失败：${XRAY_BIN}；已中止核心更新"
    install -m 0600 "${XRAY_CONFIG}" "${backup_config}" \
        || die "备份当前 Xray 配置失败：${XRAY_CONFIG}；已中止核心更新"
    if [[ -f "${XRAY_DIR}/version" ]]; then
        install -m 0644 "${XRAY_DIR}/version" "${backup_version}" \
            || die "备份当前 Xray 版本失败：${XRAY_DIR}/version；已中止核心更新"
    else
        install -m 0600 /dev/null "${version_missing}" \
            || die "记录 Xray 版本缺失标记失败：${version_missing}；已中止核心更新"
    fi
    # 下载在独立子 shell 里执行：它写出的文件失败只能靠退出码传回，不能依赖数组清理。
    if ! ( download_xray ); then
        restart_allowed=1
    elif declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1 \
        && ! cdn_traffic_protection_checkpoint; then
        # 候选已经装好、但还没 restart：记录“不得重启”，交给唯一恢复段只恢复文件。
        restart_allowed=0
    elif (
        systemctl restart "${XRAY_SERVICE}" || exit 1
        validate_protocol_runtime || exit 1
    ); then
        refresh_runtime_subscription_after_core_update
        release_runtime_write_lock
        success "Xray 已更新"
        return 0
    fi
    warn "Xray 更新失败，正在恢复旧二进制、版本与运行时配置"
    install -m 0755 "${backup_bin}" "${XRAY_BIN}" \
        || die "恢复旧 Xray 二进制失败：${XRAY_BIN}（本次核心更新未完成）"
    install -m 0600 "${backup_config}" "${XRAY_CONFIG}" \
        || die "恢复旧 Xray 配置失败：${XRAY_CONFIG}（本次核心更新未完成）"
    if [[ -f "${backup_version}" ]]; then
        install -m 0644 "${backup_version}" "${XRAY_DIR}/version" \
            || die "恢复旧 Xray 版本失败：${XRAY_DIR}/version（本次核心更新未完成）"
    elif [[ -f "${version_missing}" ]]; then
        rm -f -- "${XRAY_DIR}/version" \
            || die "移除新 Xray 版本失败：${XRAY_DIR}/version（本次核心更新未完成）"
    fi
    if [[ "${restart_allowed}" != "1" ]]; then
        die "Xray 更新失败，已恢复旧版本；CDN 流量待落实，未重启旧服务，请运行 sudo easy_all cdn-traffic-sync"
    fi
    # 恢复重启同样要过最后采样门禁；拒绝时只恢复文件，不重新放行旧运行时。
    if declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1 \
        && ! cdn_traffic_protection_checkpoint; then
        # 这里没有停服务：旧 Xray 仍可能以开放配置运行，停机会连带切断模式 4/5 的 Reality 直连。
        warn "恢复前 CDN 流量采样未通过；未重启 Xray，旧进程可能仍在以开放配置运行；保护会在保护定时器下一轮（约 15 秒）收敛，也可立即执行 sudo easy_all cdn-traffic-sync"
        die "Xray 更新失败，已恢复旧版本；CDN 流量待落实，未重启旧服务"
    fi
    systemctl restart "${XRAY_SERVICE}" \
        || die "恢复旧 Xray 后无法重启 ${XRAY_SERVICE}"
    validate_protocol_runtime
    die "Xray 更新失败，已恢复旧版本"
}
