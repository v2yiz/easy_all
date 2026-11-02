#!/usr/bin/env bash
# Independent Bunny WS profile.
set -Eeuo pipefail
umask 077
readonly BUNNY_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR="${BUNNY_PROFILE_ROOT}/../lib"
readonly STATE_DIR="${STATE_DIR:-/etc/easy_all}"
readonly STATE_FILE="${STATE_FILE:-${STATE_DIR}/state.env}"
readonly BACKUP_DIR="${BACKUP_DIR:-${STATE_DIR}/backups}"
readonly BUNNY_RECOVERY_DIR="${BUNNY_RECOVERY_DIR:-/etc/easy_all-bunny}"
readonly BUNNY_JOURNAL="${BUNNY_JOURNAL:-${BUNNY_RECOVERY_DIR}/ownership.json}"
readonly BUNNY_KEY_FILE="${BUNNY_KEY_FILE:-${BUNNY_RECOVERY_DIR}/bunny-api.key}"
readonly BUNNY_CLOUDFLARE_TOKEN_FILE="${BUNNY_CLOUDFLARE_TOKEN_FILE:-${BUNNY_RECOVERY_DIR}/cloudflare-dns.token}"
readonly BUNNY_CONFIG="${BUNNY_CONFIG:-${BUNNY_RECOVERY_DIR}/config.json}"
readonly CERT_DIR="${CERT_DIR:-${STATE_DIR}/certs}"
readonly CERT_FILE="${CERT_FILE:-${CERT_DIR}/fullchain.pem}"
readonly KEY_FILE="${KEY_FILE:-${CERT_DIR}/private.key}"
readonly LEGO_DIR="${LEGO_DIR:-${STATE_DIR}/acme}"
readonly LEGO_BIN="${LEGO_BIN:-${LEGO_DIR}/lego}"
readonly WEB_ROOT="${WEB_ROOT:-/var/www/easy_all}"
readonly SUBSCRIPTION_DIR="${SUBSCRIPTION_DIR:-${WEB_ROOT}/subscriptions}"
readonly SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_BASE64_FILE:-${SUBSCRIPTION_DIR}/base64.txt}"
readonly SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_MIHOMO_FILE:-${SUBSCRIPTION_DIR}/mihomo.yaml}"
readonly COMMAND_PATH="${COMMAND_PATH:-/usr/local/bin/easy_all}"
readonly XRAY_DIR="${XRAY_DIR:-${STATE_DIR}/xray}"
readonly XRAY_BIN="${XRAY_BIN:-${XRAY_DIR}/xray}"
readonly XRAY_CONFIG="${XRAY_CONFIG:-${XRAY_DIR}/config.json}"
readonly XRAY_SERVICE_FILE="${XRAY_SERVICE_FILE:-/etc/systemd/system/easy_all-xray.service}"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly NGINX_CONFIG="${NGINX_CONFIG:-/etc/nginx/conf.d/easy_all.conf}"
readonly NGINX_DEFAULT_SITE="${NGINX_DEFAULT_SITE:-/etc/nginx/sites-enabled/default}"
readonly CERT_RENEW_SERVICE_FILE="${CERT_RENEW_SERVICE_FILE:-/etc/systemd/system/easy_all-cert-renew.service}"
readonly CERT_RENEW_TIMER_FILE="${CERT_RENEW_TIMER_FILE:-/etc/systemd/system/easy_all-cert-renew.timer}"
readonly BUNNY_REFRESH_SERVICE_FILE="${BUNNY_REFRESH_SERVICE_FILE:-/etc/systemd/system/easy_all-bunny-ips.service}"
readonly BUNNY_REFRESH_TIMER_FILE="${BUNNY_REFRESH_TIMER_FILE:-/etc/systemd/system/easy_all-bunny-ips.timer}"
readonly UFW_BEFORE_RULES="${UFW_BEFORE_RULES:-/etc/ufw/before.rules}"
readonly BUNNY_EDGE_IP_FILE="${BUNNY_EDGE_IP_FILE:-${STATE_DIR}/bunny-edge-ips}"

EASY_ALL_RUNTIME_LIB_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/runtime-core.sh"
source "${SCRIPT_DIR}/lego-install.sh"
source "${SCRIPT_DIR}/bunny-runtime.sh"

PROTOCOL=bunny-ws
CDN_PROVIDER=bunny

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y && apt-get install -y --no-install-recommends \
        curl jq nginx openssl ca-certificates ufw python3 fail2ban iptables || die "安装系统依赖失败"
}

bunny_save_config() {
    install -d -m 0700 "${BUNNY_RECOVERY_DIR}"
    cat >"${BUNNY_CONFIG}" <<EOF
{"zone":"${CLOUDFLARE_ZONE}","origin":"${ORIGIN_DOMAIN}","cdn":"${CDN_DOMAIN}",
"ipv4":"${VPS_PUBLIC_IPV4}","name":"${BUNNY_PULL_NAME}","secret":"${ORIGIN_HEADER_SECRET}",
"bandwidth_gb":${BUNNY_BANDWIDTH_GB:-500}}
EOF
    chmod 0600 "${BUNNY_CONFIG}"
}

load_state() {
    [[ -s "${STATE_FILE}" ]] || die "状态文件不存在: ${STATE_FILE}"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${PROTOCOL:-}" == "bunny-ws" ]] || die "非 Bunny 协议状态"
    ALLOWED_TOKENS="[\"${OWNER_TOKEN}\"]"
}

save_state() {
    install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
    cat >"${STATE_FILE}" <<EOF
STATE_VERSION="2"
PROTOCOL="bunny-ws"
CDN_PROVIDER="bunny"
CLOUDFLARE_ZONE="${CLOUDFLARE_ZONE}"
ORIGIN_DOMAIN="${ORIGIN_DOMAIN}"
CDN_DOMAIN="${CDN_DOMAIN}"
VPS_PUBLIC_IPV4="${VPS_PUBLIC_IPV4}"
BUNNY_PULL_NAME="${BUNNY_PULL_NAME}"
BUNNY_BANDWIDTH_GB="${BUNNY_BANDWIDTH_GB:-500}"
ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET}"
VLESS_UUID="${VLESS_UUID}"
OWNER_TOKEN="${OWNER_TOKEN}"
WEBSOCKET_PATH="${WEBSOCKET_PATH}"
TCP_ACCELERATION="${TCP_ACCELERATION:-bbrv3}"
SCHEDULED_REBOOT_ENABLED="${SCHEDULED_REBOOT_ENABLED:-0}"
SCHEDULED_REBOOT_HOUR="${SCHEDULED_REBOOT_HOUR:-}"
SUB_DOWNLOAD_NAME="${SUB_DOWNLOAD_NAME:-EASY_ALL}"
EOF
    chmod 0600 "${STATE_FILE}"
}

bunny_prepare_credentials() {
    install -d -m 0700 "${BUNNY_RECOVERY_DIR}"
    if [[ ! -s "${BUNNY_KEY_FILE}" ]]; then
        local key; key=$(prompt_secret 'Bunny Account API Key') || die '缺少 Bunny API Key'
        printf '%s\n' "${key}" >"${BUNNY_KEY_FILE}"
    fi
    if [[ ! -s "${BUNNY_CLOUDFLARE_TOKEN_FILE}" ]]; then
        local token; token=$(prompt_secret 'Cloudflare DNS Token') || die '缺少 Cloudflare Token'
        printf '%s\n' "${token}" >"${BUNNY_CLOUDFLARE_TOKEN_FILE}"
    fi
    chmod 0600 "${BUNNY_KEY_FILE}" "${BUNNY_CLOUDFLARE_TOKEN_FILE}"
}

bunny_collect_inputs() {
    install -d -m 0700 "${BUNNY_RECOVERY_DIR}"
    if [[ -f "${BUNNY_CONFIG}" ]]; then
        CLOUDFLARE_ZONE=$(jq -r .zone "${BUNNY_CONFIG}")
        ORIGIN_DOMAIN=$(jq -r .origin "${BUNNY_CONFIG}")
        CDN_DOMAIN=$(jq -r .cdn "${BUNNY_CONFIG}")
        VPS_PUBLIC_IPV4=$(jq -r .ipv4 "${BUNNY_CONFIG}")
        BUNNY_PULL_NAME=$(jq -r .name "${BUNNY_CONFIG}")
        BUNNY_BANDWIDTH_GB=$(jq -r .bandwidth_gb "${BUNNY_CONFIG}")
        ORIGIN_HEADER_SECRET=$(jq -r .secret "${BUNNY_CONFIG}")
    else
        CLOUDFLARE_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' '')")
        ORIGIN_DOMAIN=$(normalize_domain "$(prompt_value '源站域名' "origin.${CLOUDFLARE_ZONE}")")
        CDN_DOMAIN=$(normalize_domain "$(prompt_value 'CDN 节点/订阅域名' "cdn.${CLOUDFLARE_ZONE}")")
        VPS_PUBLIC_IPV4=${VPS_IP:-${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)}}
        BUNNY_PULL_NAME=${BUNNY_PULL_NAME:-"easyall$(openssl rand -hex 6)"}
        ORIGIN_HEADER_SECRET=$(generate_secret)
        BUNNY_BANDWIDTH_GB=$(prompt_value 'Pull Zone 月流量限制（GB）' 500)
    fi
    bunny_prepare_credentials
    VLESS_UUID=${VLESS_UUID:-$(python3 -c 'import uuid; print(uuid.uuid4())')}
    OWNER_TOKEN=${OWNER_TOKEN:-$(generate_secret)}
    ALLOWED_TOKENS="[\"${OWNER_TOKEN}\"]"
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-"/ws-$(openssl rand -hex 16)"}
    TCP_ACCELERATION=${TCP_ACCELERATION:-bbrv3}
    SUB_DOWNLOAD_NAME=EASY_ALL
    STATE_VERSION=2
}

build_node_links() {
    local clean_path=${WEBSOCKET_PATH#/}
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&host=%s&sni=%s&path=%%2F%s#%s\n' \
        "${VLESS_UUID}" "${CDN_DOMAIN}" "${CDN_DOMAIN}" "${CDN_DOMAIN}" "${clean_path}" "${SUB_DOWNLOAD_NAME}"
}

build_mihomo_nodes() {
    cat <<EOF
  - name: "${SUB_DOWNLOAD_NAME}"
    type: vless
    server: ${CDN_DOMAIN}
    port: 443
    uuid: ${VLESS_UUID}
    network: ws
    tls: true
    udp: true
    sni: ${CDN_DOMAIN}
    ws-opts:
      path: "${WEBSOCKET_PATH}"
      headers:
        Host: ${CDN_DOMAIN}
EOF
}

write_subscriptions() {
    local stage="${RUNTIME_TMP}/sub-stage"
    prepare_mihomo_template
    mkdir -p "${stage}"
    build_node_links | openssl base64 -A >"${stage}/base64.txt"
    printf '\n' >>"${stage}/base64.txt"
    build_mihomo_nodes >"${RUNTIME_TMP}/nodes.yaml"
    build_mihomo_proxy_names >"${RUNTIME_TMP}/names.yaml"
    render_mihomo_subscription "${MIHOMO_TEMPLATE_FILE}" "${RUNTIME_TMP}/nodes.yaml" \
        "${stage}/mihomo.yaml" BUNNY_WS '' "${RUNTIME_TMP}/names.yaml"
    publish_subscription_files "${stage}"
}

write_xray_config() {
    install -d -m 0700 "${XRAY_DIR}"
    cat >"${XRAY_CONFIG}" <<EOF
{"log":{"loglevel":"warning","access":"none"},
"inbounds":[{"tag":"bunny-ws","listen":"127.0.0.1","port":10086,"protocol":"vless",
"settings":{"clients":[{"id":"${VLESS_UUID}"}],"decryption":"none"},
"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"${WEBSOCKET_PATH}"}}}],
"outbounds":[{"protocol":"freedom","settings":{"domainStrategy":"UseIPv4"}}]}
EOF
    chmod 0600 "${XRAY_CONFIG}"
    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" >/dev/null 2>&1 || true
}

write_nginx_config() {
    {
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen 80 default_server;
    server_name _;
    return 404;
}
server {
    listen 443 ssl;
    server_name ${ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    add_header Cache-Control "no-store" always;
    location = /easy_all-health {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        return 200 "easy_all ok\n";
    }
EOF
        write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}"
        cat <<EOF
    location = ${WEBSOCKET_PATH} {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${CDN_DOMAIN};
        proxy_set_header X-Easy-All-Origin-Key "";
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_pass http://127.0.0.1:10086;
    }
    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/nginx.conf"
    [[ ! -e "${NGINX_DEFAULT_SITE}" ]] || mv "${NGINX_DEFAULT_SITE}" "${BACKUP_DIR}/nginx-default"
    install -m 0600 "${RUNTIME_TMP}/nginx.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
}

apply_cloud_resources() {
    bunny_prepare_credentials
    bunny_save_config
    python3 "${SCRIPT_DIR}/bunny-api.py" apply \
        --journal "${BUNNY_JOURNAL}" --key-file "${BUNNY_KEY_FILE}" \
        --cloudflare-token-file "${BUNNY_CLOUDFLARE_TOKEN_FILE}" --config "${BUNNY_CONFIG}"
}

apply_easy_all() {
    apply_cloud_resources "$@"
    info "云端资源配置完成"
}

show_subscription() {
    load_state
    print_subscription_credentials "${OWNER_TOKEN}"
}

show_status() {
    load_state
    printf '\n=== Bunny CDN (VLESS-WS) ===\n'
    printf 'CDN 域名: %s\n' "${CDN_DOMAIN}"
    printf '源站域名: %s\n' "${ORIGIN_DOMAIN}"
    printf 'Xray 状态: %s\n' "$(systemctl is-active "${XRAY_SERVICE}" 2>/dev/null || echo inactive)"
    printf 'Nginx 状态: %s\n' "$(systemctl is-active nginx 2>/dev/null || echo inactive)"
}

install_all() {
    require_root
    require_systemd
    check_platform
    install_packages
    ensure_runtime_dependencies
    bunny_collect_inputs
    bunny_save_config
    apply_cloud_resources
    bunny_issue_certificate "${ORIGIN_DOMAIN}"
    write_xray_config
    write_subscriptions
    write_nginx_config
    bunny_refresh_firewall
    bunny_install_ip_timer
    install_certificate_renewal_timer
    save_state
    validate_protocol_runtime
    validate_subscription_runtime
    bunny_validate_edge
    python3 "${SCRIPT_DIR}/bunny-api.py" mark-committed --journal "${BUNNY_JOURNAL}" >/dev/null 2>&1 || true
    show_status
    show_subscription
}

uninstall_all() {
    require_root
    bunny_remove_local
    info "已卸载本机服务；云端配置及恢复凭据保留在 ${BUNNY_RECOVERY_DIR}"
}
