#!/usr/bin/env bash

# Shared cron-backed optional reboot maintenance.

filter_managed_reboot_cron() {
    awk -v marker="${CRON_REBOOT_MARKER}" 'index($0, marker) == 0'
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job pre_command=""
    if [[ -z "${mode}" && -t 0 ]]; then
        printf '请选择定时重启策略：\n'
        printf 'Choose the scheduled reboot policy:\n'
        printf '  1. 每天凌晨 4 点重启（默认）\n'
        printf '     Reboot every day at 04:00 (default)\n'
        printf '  2. 自定义每天几点重启（0-23）\n'
        printf '     Choose a daily reboot hour (0-23)\n'
        printf '  3. 不配置定时重启\n'
        printf '     Do not configure scheduled reboots\n'
        read_bilingual \
            '请选择 [1]（直接回车使用默认值）:' \
            'Choose [1] (press Enter to use the default):' mode
    fi
    mode=${mode:-1}
    case "${mode}" in
    1 | default)
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"
        ;;
    2 | custom)
        [[ -n "${hour}" ]] || hour=$(prompt_value "每天重启小时（0-23）" "" \
            "Daily reboot hour (0-23)")
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
    { crontab -l 2>/dev/null || true; } | filter_managed_reboot_cron | crontab -
    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]]; then
        if declare -F scheduled_reboot_pre_command >/dev/null 2>&1; then
            pre_command=$(scheduled_reboot_pre_command)
        fi
        if [[ -n "${pre_command}" ]]; then
            job="0 ${SCHEDULED_REBOOT_HOUR} * * * ${pre_command} && /usr/sbin/reboot ${CRON_REBOOT_MARKER}"
        else
            job="0 ${SCHEDULED_REBOOT_HOUR} * * * /usr/sbin/reboot ${CRON_REBOOT_MARKER}"
        fi
        { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
    fi
}

remove_daily_reboot_schedule() {
    { crontab -l 2>/dev/null || true; } | filter_managed_reboot_cron | crontab - \
        || warn "移除 easy_all 定时重启任务失败，请手动检查 root crontab"
}
