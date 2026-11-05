#!/usr/bin/env bash
# Local Bunny TLS, origin verification, firewall and recovery lifecycle.

bunny_reject_ssh_443() {
    detect_ssh_ports strict
    [[ " ${SSH_PORTS} " != *" 443 "* ]] \
        || die 'SSH 端口配置包含 443，无法与 Bunny 回源共用该端口'
}

bunny_refresh_firewall() {
    local response="${RUNTIME_TMP}/bunny-edges.json" addresses="${RUNTIME_TMP}/bunny-edges"
    curl -4fsS --proto '=https' -H 'Accept: application/json' --connect-timeout 10 --max-time 30 \
        https://api.bunny.net/system/edgeserverlist -o "${response}" || die 'Bunny 回源池获取失败'
    python3 "${SCRIPT_DIR}/bunny-api.py" ips --input "${response}" >"${addresses}" || die 'Bunny 回源池校验失败'
    bunny_reject_ssh_443
    # SSH 开机自启与 Fail2ban 与其他模式保持一致：只放行端口而不配 jail，
    # 会让文档承诺的 SSH 暴力破解防护在这一个模式里静默缺失。
    ensure_ssh_boot_service
    verify_ssh_ufw_no_unmanaged_block "${SSH_PORTS}"
    disable_ufw_ipv6 || die '配置 UFW IPv4 策略失败'
    apply_ssh_ufw_policy "${SSH_PORTS}" "${SSH_PORTS}"
    # Tighten defaults only after all SSH listeners have effective ALLOW rules.
    ufw default deny incoming >/dev/null || die '设置 UFW 默认入站策略失败'
    ufw default allow outgoing >/dev/null || die '设置 UFW 默认出站策略失败'
    python3 - "${UFW_BEFORE_RULES}" "${addresses}" "${RUNTIME_TMP}/bunny-before.rules" <<'PYTHON' || die 'UFW 规则生成失败'
import pathlib, sys
source, addresses, target = map(pathlib.Path, sys.argv[1:])
lines = source.read_text().splitlines(); output = []; skip = False; inserted = False; in_filter = False
for line in lines:
    if line == '# easy_all-bunny-start': skip = True; continue
    if line == '# easy_all-bunny-end': skip = False; continue
    if skip: continue
    if line == '*filter': in_filter = True
    if in_filter and not inserted and line.startswith('-A '):
        output += ['# easy_all-bunny-start', ':easy_all_bunny - [0:0]',
                   '-A ufw-before-input ! -i lo -p tcp --dport 443 -j easy_all_bunny']
        output += ['-A easy_all_bunny -s ' + ip + ' -j ACCEPT' for ip in addresses.read_text().splitlines()]
        output += ['-A easy_all_bunny -j DROP', '# easy_all-bunny-end']
        inserted = True
    output.append(line)
if not inserted: raise SystemExit('Cannot insert filter')
target.write_text('\n'.join(output) + '\n')
PYTHON
    iptables-restore --test <"${RUNTIME_TMP}/bunny-before.rules" || die 'iptables 语法检查未通过'
    install -m 0640 "${RUNTIME_TMP}/bunny-before.rules" "${UFW_BEFORE_RULES}" || die '安装 UFW 回源规则失败'
    ufw --force enable >/dev/null || die '启用 UFW 回源规则失败'
    ufw reload >/dev/null || die '重载 UFW 回源规则失败'
    install -m 0600 "${addresses}" "${BUNNY_EDGE_IP_FILE}" || die '保存 Bunny 回源池失败'
    ensure_ssh_fail2ban
}

refresh_bunny_origin_ips() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    bunny_refresh_firewall
    release_runtime_write_lock
}

bunny_install_ip_timer() {
    cat >"${BUNNY_REFRESH_SERVICE_FILE}" <<EOF
[Unit]
Description=Refresh Bunny official origin IPv4 allowlist
After=network-online.target
[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} refresh-origin-ips
EOF
    cat >"${BUNNY_REFRESH_TIMER_FILE}" <<'EOF'
[Unit]
Description=Refresh Bunny origin pool every six hours
[Timer]
OnBootSec=5m
OnUnitActiveSec=6h
RandomizedDelaySec=10m
Persistent=true
[Install]
WantedBy=timers.target
EOF
    chmod 0644 "${BUNNY_REFRESH_SERVICE_FILE}" "${BUNNY_REFRESH_TIMER_FILE}"
    systemctl daemon-reload || die '重新加载 Bunny 回源定时器失败'
    systemctl enable --now easy_all-bunny-ips.timer >/dev/null || die '启用 Bunny 回源定时器失败'
}

bunny_certificate_current() {
    local cert=${1:-"${CERT_FILE}"} key=${2:-"${KEY_FILE}"}
    [[ -s "${cert}" && -s "${key}" ]] || return 1
    openssl x509 -checkend 2592000 -noout -in "${cert}" >/dev/null 2>&1
}

bunny_issue_certificate() {
    local domain=$1
    ensure_lego || die "安装 lego 失败"
    info "正在为 ${domain} 申请/验证证书"
    local token; token=$(<"${BUNNY_CLOUDFLARE_TOKEN_FILE}")
    CF_DNS_API_TOKEN="${token}" "${LEGO_BIN}" --email "admin@${CLOUDFLARE_ZONE}" \
        --dns cloudflare --domains "${domain}" --path "${LEGO_DIR}" run || die "证书申请失败"
    install -d -m 0700 "${CERT_DIR}"
    install -m 0600 "${LEGO_DIR}/certificates/${domain}.crt" "${CERT_FILE}"
    install -m 0600 "${LEGO_DIR}/certificates/${domain}.key" "${KEY_FILE}"
}

renew_bunny_certificate() {
    local force=${1:-0}
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if [[ "${force}" != 1 ]] && bunny_certificate_current; then
        info "证书有效，无需续期"
        if ! systemctl reload nginx >/dev/null 2>&1 \
            || ! systemctl is-active --quiet nginx; then
            release_runtime_write_lock
            die "当前证书已生效，但 Nginx 重载失败"
        fi
        release_runtime_write_lock
        return 0
    fi
    bunny_issue_certificate "${ORIGIN_DOMAIN}"
    if ! systemctl restart nginx >/dev/null 2>&1 \
        || ! systemctl is-active --quiet nginx; then
        release_runtime_write_lock
        die "证书已续期，但 Nginx 重启失败"
    fi
    release_runtime_write_lock
}

validate_protocol_runtime() {
    systemctl is-active --quiet "${XRAY_SERVICE}" || die "Xray 未正常运行"
    systemctl is-active --quiet nginx || die "Nginx 未正常运行"
}

validate_subscription_runtime() {
    [[ -s "${SUBSCRIPTION_BASE64_FILE}" && -s "${SUBSCRIPTION_MIHOMO_FILE}" ]] || die "订阅文件缺失"
}

bunny_validate_edge() {
    info "正在检验 Bunny 边缘 HTTP 可达性；这不代表生产 WebSocket 101 或 VLESS 数据面已验收"
    local code
    if ! code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 30 \
        "https://${CDN_DOMAIN}${WEBSOCKET_PATH}"); then
        code=000
    fi
    [[ "${code}" != "000" ]] || warn "Bunny 边缘 HTTP 不可达；独立真实 VLESS 数据面尚未验收"
}

# 返回非零表示有本机产物没删掉：部分安装的清理据此保留 marker 以便重试，
# 普通 uninstall 调用方显式容忍失败（见 ws-bunny.sh:uninstall_all）。
bunny_remove_local() {
    local failed=0 retain_state=0
    systemctl disable --now "${XRAY_SERVICE}" easy_all-bunny-ips.timer easy_all-cert-renew.timer >/dev/null 2>&1 || true
    systemctl stop "${XRAY_SERVICE}" easy_all-bunny-ips.service easy_all-cert-renew.service >/dev/null 2>&1 || true
    rm -f "${XRAY_SERVICE_FILE}" "${BUNNY_REFRESH_SERVICE_FILE}" "${BUNNY_REFRESH_TIMER_FILE}" \
        "${CERT_RENEW_SERVICE_FILE}" "${CERT_RENEW_TIMER_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" \
        || { warn "删除 Bunny 服务/配置失败"; failed=1; }
    systemctl daemon-reload >/dev/null 2>&1 || true
    # 恢复安装前配置失败时绝不能删状态目录：备份就在里面，删了就再也补不回来。
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" "${UFW_DEFAULT_CONFIG}" \
        || { warn "恢复 ${UFW_DEFAULT_CONFIG} 失败"; failed=1; retain_state=1; }
    [[ ! -f "${BACKUP_DIR}/pre-install-nginx-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-nginx-default" "${NGINX_DEFAULT_SITE}" \
        || { warn "恢复 ${NGINX_DEFAULT_SITE} 失败"; failed=1; retain_state=1; }
    systemctl reload nginx >/dev/null 2>&1 || true
    ! declare -f restore_preinstall_ipv6 >/dev/null 2>&1 || restore_preinstall_ipv6
    if ((retain_state == 1)); then
        warn "安装前配置未能恢复；保留 ${STATE_DIR} 及其备份，修正后重试"
    else
        rm -rf "${STATE_DIR}" "${WEB_ROOT}" \
            || { warn "删除 Bunny 状态目录失败"; failed=1; }
    fi
    if [[ -f "${UFW_BEFORE_RULES}" ]]; then
        remove_ufw_managed_block "${UFW_BEFORE_RULES}" \
            '# easy_all-bunny-start' '# easy_all-bunny-end' \
            || warn "移除 Bunny 回源 UFW 区块失败：${UFW_BEFORE_RULES}"
    fi
    ufw reload >/dev/null 2>&1 || true
    ((failed == 0))
}
