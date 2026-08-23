#!/usr/bin/env bash

# Shared cron-backed maintenance for acme.sh renewal and optional reboots.
# Certificate issuance and domain cleanup remain Profile-specific.

run_acme() {
    "${ACME_BIN}" "$@" --home "${ACME_HOME}"
}

has_acme_renewal_cron() {
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null || true)
    awk -v acme_bin="${ACME_BIN}" '
        index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/ { found=1 }
        END { exit !found }
    ' <<<"${crontab_content}"
}

install_managed_acme_renewal_cron() {
    local crontab_content cron_file
    crontab_content=$(crontab -l 2>/dev/null || true)
    cron_file="${RUNTIME_TMP}/acme-renewal.cron"
    awk -v acme_bin="${ACME_BIN}" '
        !(index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/) { print }
    ' <<<"${crontab_content}" >"${cron_file}"
    printf '17 2 * * * "%s" --cron --home "%s" >/dev/null 2>&1 # easy_all-acme-renewal\n' \
        "${ACME_BIN}" "${ACME_HOME}" >>"${cron_file}"
    crontab "${cron_file}" || die "写入 easy_all acme.sh 自动续期定时任务失败"
}

verify_acme_renewal_setup() {
    command -v crontab >/dev/null 2>&1 || die "未找到 crontab；无法配置证书自动续期"
    systemctl enable --now cron.service >/dev/null 2>&1 \
        || die "无法启用证书自动续期所需的 cron.service"
    systemctl is-enabled --quiet cron.service \
        || die "cron.service 未设置为开机启动"
    systemctl is-active --quiet cron.service \
        || die "cron.service 未运行"
    has_acme_renewal_cron || die "未找到 acme.sh 自动续期定时任务"
}

ensure_acme_renewal_setup() {
    run_acme --install-cronjob >/dev/null 2>&1 \
        || warn "acme.sh --install-cronjob 失败，改用 easy_all 受管 cron"
    if ! has_acme_renewal_cron; then
        warn "acme.sh 未写入续期任务，正在写入 easy_all 受管 cron"
        install_managed_acme_renewal_cron
    fi
    verify_acme_renewal_setup
}

filter_managed_reboot_cron() {
    awk -v marker="${CRON_REBOOT_MARKER}" 'index($0, marker) == 0'
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job
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
        job="0 ${SCHEDULED_REBOOT_HOUR} * * * /usr/sbin/reboot ${CRON_REBOOT_MARKER}"
        { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
    fi
}

remove_daily_reboot_schedule() {
    { crontab -l 2>/dev/null || true; } | filter_managed_reboot_cron | crontab - \
        || warn "移除 easy_all 定时重启任务失败，请手动检查 root crontab"
}
