#!/usr/bin/env bash

# Shared cron-backed optional reboot maintenance.

filter_managed_reboot_cron() {
    awk -v marker="${CRON_REBOOT_MARKER}" 'index($0, marker) == 0'
}

read_root_crontab() {
    local output status
    if output=$(LC_ALL=C crontab -l 2>&1); then
        printf '%s\n' "${output}"
        return 0
    else
        status=$?
    fi
    [[ "${output}" == "no crontab for "* ]] || \
        die "读取 root crontab 失败（退出码 ${status}）：${output:-无错误信息}"
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job current
    local pre_command profile_pre_command=""
    if [[ -z "${mode}" && -t 0 ]]; then
        printf '请选择定时重启策略：\n'
        printf '  1. 每天凌晨 4 点重启（默认）\n'
        printf '  2. 自定义每天几点重启（0-23）\n'
        printf '  3. 不配置定时重启\n'
        read_bilingual '请选择 [1]（直接回车使用默认值）:' mode
    fi
    mode=${mode:-1}
    case "${mode}" in
    1 | default)
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"
        ;;
    2 | custom)
        [[ -n "${hour}" ]] || hour=$(prompt_value "每天重启小时（0-23）" "")
        [[ "${hour}" =~ ^[0-9]+$ ]] && ((10#${hour} <= 23)) \
            || die "重启小时无效：${hour}"
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${hour}"
        ;;
    3 | none | off | disabled)
        SCHEDULED_REBOOT_ENABLED=0
        SCHEDULED_REBOOT_HOUR=""
        ;;
    *) die "定时重启选项无效：${mode}" ;;
    esac
    current=$(read_root_crontab) || return 1
    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]]; then
        if declare -F scheduled_reboot_profile_pre_command >/dev/null 2>&1; then
            profile_pre_command=$(scheduled_reboot_profile_pre_command)
        fi
        if [[ -n "${profile_pre_command}" ]]; then
            pre_command="${profile_pre_command}"
        fi
        pre_command=${pre_command//%/\\%}
        job="0 ${SCHEDULED_REBOOT_HOUR} * * * ( ${pre_command:-true} ) && /usr/sbin/reboot ${CRON_REBOOT_MARKER}"
    fi
    { printf '%s\n' "${current}" | filter_managed_reboot_cron; \
        [[ -z "${job:-}" ]] || printf '%s\n' "${job}"; } | crontab - \
        || die "写入 root crontab 失败"
}

refresh_saved_daily_reboot_schedule() {
    if [[ "${SCHEDULED_REBOOT_ENABLED:-0}" == "1" ]]; then
        REBOOT_SCHEDULE_MODE=custom
        REBOOT_HOUR="${SCHEDULED_REBOOT_HOUR}"
    else
        REBOOT_SCHEDULE_MODE=none
        REBOOT_HOUR=""
    fi
    configure_daily_reboot
}

remove_daily_reboot_schedule() {
    local current
    current=$(read_root_crontab) || return 1
    printf '%s\n' "${current}" | filter_managed_reboot_cron | crontab - \
        || warn "移除 easy_all 定时重启任务失败，请手动检查 root crontab"
}

restore_preinstall_crontab() {
    if [[ -f "${BACKUP_DIR}/pre-install-crontab" ]]; then
        crontab "${BACKUP_DIR}/pre-install-crontab" >/dev/null 2>&1 \
            || warn "恢复安装前 root crontab 失败"
    elif [[ -f "${BACKUP_DIR}/pre-install-crontab.missing" ]]; then
        crontab -r >/dev/null 2>&1 || true
    fi
}
