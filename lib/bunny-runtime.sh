#!/usr/bin/env bash
# Local Bunny TLS, origin verification, firewall and recovery lifecycle.

bunny_refresh_firewall() {
    local response="${RUNTIME_TMP}/bunny-edges.json" addresses="${RUNTIME_TMP}/bunny-edges"
    curl -4fsS --proto '=https' -H 'Accept: application/json' --connect-timeout 10 --max-time 30 \
        https://api.bunny.net/system/edgeserverlist -o "${response}" || die 'Bunny 回源池获取失败'
    python3 "${SCRIPT_DIR}/bunny-api.py" ips --input "${response}" >"${addresses}" || die 'Bunny 回源池校验失败'
    disable_ufw_ipv6 || true
    ufw default deny incoming >/dev/null || true
    ufw default allow outgoing >/dev/null || true
    apply_ssh_ufw_policy "${EASY_ALL_ADDITIONAL_SSH_PORT:-}" || true
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
    install -m 0640 "${RUNTIME_TMP}/bunny-before.rules" "${UFW_BEFORE_RULES}"
    ufw --force enable >/dev/null && ufw reload >/dev/null
    install -m 0600 "${addresses}" "${BUNNY_EDGE_IP_FILE}"
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
    systemctl daemon-reload
    systemctl enable --now easy_all-bunny-ips.timer >/dev/null 2>&1 || true
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
        release_runtime_write_lock; return 0
    fi
    bunny_issue_certificate "${ORIGIN_DOMAIN}"
    systemctl restart nginx >/dev/null 2>&1 || true
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
    info "正在检验 Bunny 边缘连通性..."
    local code
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 "https://${CDN_DOMAIN}${WEBSOCKET_PATH}" || echo "000")
    [[ "${code}" != "000" ]] || warn "边缘域名解析尚未完全就绪，请稍后重试"
}

bunny_remove_local() {
    systemctl disable --now "${XRAY_SERVICE}" easy_all-bunny-ips.timer easy_all-cert-renew.timer >/dev/null 2>&1 || true
    systemctl stop "${XRAY_SERVICE}" easy_all-bunny-ips.service easy_all-cert-renew.service >/dev/null 2>&1 || true
    rm -f "${XRAY_SERVICE_FILE}" "${BUNNY_REFRESH_SERVICE_FILE}" "${BUNNY_REFRESH_TIMER_FILE}" "${CERT_RENEW_SERVICE_FILE}" "${CERT_RENEW_TIMER_FILE}" "${NGINX_CONFIG}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
    rm -rf "${STATE_DIR}" "${WEB_ROOT}"
    if [[ -f "${UFW_BEFORE_RULES}" ]]; then
        sed -i.bak '/# easy_all-bunny-start/,/# easy_all-bunny-end/d' "${UFW_BEFORE_RULES}" 2>/dev/null || true
        ufw reload >/dev/null 2>&1 || true
    fi
}
