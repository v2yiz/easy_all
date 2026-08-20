#!/usr/bin/env bash

# Shared acme.sh invocation and renewal scheduling. Certificate issuance and
# domain cleanup remain profile-specific because their challenge flows differ.

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
