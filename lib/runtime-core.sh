#!/usr/bin/env bash

# Protocol-neutral runtime shared by all easy_all profiles.

readonly RUNTIME_LIB_DIR="${EASY_ALL_RUNTIME_LIB_DIR:?EASY_ALL_RUNTIME_LIB_DIR is required}"

# shellcheck source=lib/log.sh
source "${RUNTIME_LIB_DIR}/log.sh"
# shellcheck source=lib/quota.sh
source "${RUNTIME_LIB_DIR}/quota.sh"
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

RUNTIME_TMP=$(mktemp -d)
cleanup_files=("${RUNTIME_TMP}")
INSTALL_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_ON_EXIT=0
UPDATE_SUB_BACKUP_DIR=""
MIHOMO_TEMPLATE_FILE=""

cleanup() {
    local path
    if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        if [[ -n "${UPDATE_SUB_BACKUP_DIR:-}" ]]; then
            rollback_subscription_update || true
        else
            warn "订阅更新要求回滚，但备份目录为空"
        fi
    elif [[ "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        INSTALL_ROLLBACK_ON_EXIT=0
        rollback_fresh_install || true
    fi
    end_quota_maintenance || true
    for path in "${cleanup_files[@]:-}"; do
        [[ -n "${path}" ]] && rm -rf -- "${path}"
    done
}
trap cleanup EXIT

uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/xray-backup"
    local backup_config="${RUNTIME_TMP}/xray-config-backup.json"
    local backup_version="${RUNTIME_TMP}/xray-version-backup"
    local version_missing="${RUNTIME_TMP}/xray-version.missing"
    require_root
    begin_quota_maintenance
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
        end_quota_maintenance
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
