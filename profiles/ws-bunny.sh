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
readonly SUBSCRIPTION_MIHOMO_IOS_FILE="${SUBSCRIPTION_MIHOMO_IOS_FILE:-${SUBSCRIPTION_DIR}/mihomo-ios.yaml}"
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
readonly UFW_DEFAULT_CONFIG="${UFW_DEFAULT_CONFIG:-/etc/default/ufw}"
readonly UFW_RULE_COMMENT="${UFW_RULE_COMMENT:-easy_all-managed}"
readonly UFW_BEFORE_RULES="${UFW_BEFORE_RULES:-/etc/ufw/before.rules}"
readonly BUNNY_EDGE_IP_FILE="${BUNNY_EDGE_IP_FILE:-${STATE_DIR}/bunny-edge-ips}"

# 与其他模式共用同一把写锁：跨模式清理/重装必须在同一临界区，否则 Bunny 安装期间
# 另一个模式的安装会把仍在运行的 Bunny 当成残留清理掉。

EASY_ALL_RUNTIME_LIB_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/runtime-core.sh"
source "${SCRIPT_DIR}/lego-install.sh"
source "${SCRIPT_DIR}/bunny-runtime.sh"

PROTOCOL=bunny-ws
CDN_PROVIDER=bunny

install_packages() {
    local pkgs=(
        curl wget coreutils tar jq openssl ca-certificates ufw python3
        python3-jsonschema fail2ban iptables iproute2 unzip sudo vim
    )
    local nginx_active_before=unknown
    command -v systemctl >/dev/null 2>&1 \
        && nginx_active_before=$(systemctl is-active nginx 2>/dev/null || true)

    if packages_already_installed "${pkgs[@]}" && nginx_package_installed; then
        info "系统基础依赖包与 Nginx 已全部安装，跳过 APT 索引更新与包安装"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update -y \
            && apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${pkgs[@]}" \
            || die "安装系统依赖失败"
        if [[ "${nginx_active_before}" == "active" ]] || nginx_package_installed; then
            apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends nginx \
                || die "安装 nginx 失败"
        else
            install_nginx_without_start nginx || die "安装 nginx 失败"
        fi
        quiet_freshly_installed_nginx "${nginx_active_before}"
    fi
}

bunny_ensure_python_jsonschema() {
    python3 -c 'import jsonschema' >/dev/null 2>&1 && return
    info "正在安装 Bunny 云端同步所需的 Python JSON Schema 依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update -y \
        && apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends python3-jsonschema \
        || die "安装 python3-jsonschema 失败"
}

collect_installed_state() {
    load_state
}

bunny_save_config() {
    install -d -m 0700 "${BUNNY_RECOVERY_DIR}"
    local temp
    temp=$(mktemp "${BUNNY_CONFIG}.XXXXXX") || die "创建 Bunny 配置暂存文件失败"
    cat >"${temp}" <<EOF
{"zone":"${CLOUDFLARE_ZONE}","origin":"${ORIGIN_DOMAIN}","cdn":"${CDN_DOMAIN}",
"ipv4":"${VPS_PUBLIC_IPV4}","name":"${BUNNY_PULL_NAME}","secret":"${ORIGIN_HEADER_SECRET}",
"bandwidth_gb":${BUNNY_BANDWIDTH_GB:-500}}
EOF
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${BUNNY_CONFIG}"
}

load_state() {
    [[ -s "${STATE_FILE}" ]] || die "状态文件不存在: ${STATE_FILE}"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "0" ]] || die "状态版本无效；当前版本为 0"
    [[ "${PROTOCOL:-}" == "bunny-ws" ]] || die "非 Bunny 协议状态"
    ALLOWED_TOKENS="[\"${OWNER_TOKEN}\"]"
}

save_state() {
    install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") || die "创建状态暂存文件失败"
    cat >"${temp}" <<EOF
STATE_VERSION="0"
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
TCP_ACCELERATION="${TCP_ACCELERATION:-skyline}"
SCHEDULED_REBOOT_ENABLED="${SCHEDULED_REBOOT_ENABLED:-0}"
SCHEDULED_REBOOT_HOUR="${SCHEDULED_REBOOT_HOUR:-}"
SUB_DOWNLOAD_NAME="${SUB_DOWNLOAD_NAME:-EASY_ALL}"
EOF
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${STATE_FILE}"
}

bunny_prepare_credentials() {
    install -d -m 0700 "${BUNNY_RECOVERY_DIR}"
    if [[ ! -s "${BUNNY_KEY_FILE}" ]]; then
        local key
        key=$(prompt_secret 'Bunny Account API Key') || die '缺少 Bunny API Key'
        printf '%s\n' "${key}" >"${BUNNY_KEY_FILE}"
    fi
    if [[ ! -s "${BUNNY_CLOUDFLARE_TOKEN_FILE}" ]]; then
        local token
        token=$(prompt_secret 'Cloudflare DNS Token') || die '缺少 Cloudflare Token'
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
        BUNNY_PULL_NAME=$(jq -r .name "${BUNNY_CONFIG}")
        BUNNY_BANDWIDTH_GB=$(jq -r .bandwidth_gb "${BUNNY_CONFIG}")
        ORIGIN_HEADER_SECRET=$(jq -r .secret "${BUNNY_CONFIG}")
    else
        CLOUDFLARE_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' '')")
        validate_domain "${CLOUDFLARE_ZONE}" || die "Cloudflare Zone 无效：${CLOUDFLARE_ZONE}"
        ORIGIN_DOMAIN=$(normalize_domain "$(prompt_value '源站域名' "origin.${CLOUDFLARE_ZONE}")")
        validate_domain "${ORIGIN_DOMAIN}" || die "源站域名无效：${ORIGIN_DOMAIN}"
        CDN_DOMAIN=$(normalize_domain "$(prompt_value 'CDN 节点/订阅域名' "cdn.${CLOUDFLARE_ZONE}")")
        validate_domain "${CDN_DOMAIN}" || die "CDN 域名无效：${CDN_DOMAIN}"
        [[ "${ORIGIN_DOMAIN}" != "${CDN_DOMAIN}" ]] || die "源站域名与 CDN 域名不能相同"
        BUNNY_PULL_NAME=${BUNNY_PULL_NAME:-"easyall$(openssl rand -hex 6)"}
        ORIGIN_HEADER_SECRET=$(generate_secret)
        BUNNY_BANDWIDTH_GB=$(prompt_value 'Pull Zone 月流量限制（GB）' 500)
    fi
    VPS_PUBLIC_IPV4=${VPS_IP:-$(detect_public_ipv4)} \
        || die '公网 IPv4 探测失败；可用 VPS_IP=<IPv4> 指定'
    validate_ipv4 "${VPS_PUBLIC_IPV4}" || die "公网 IPv4 无效：${VPS_PUBLIC_IPV4}"
    bunny_prepare_credentials
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"
    OWNER_TOKEN=${OWNER_TOKEN:-$(generate_secret)}
    # 与其他模式同一约束：Token 会写进 state.env（后续由 root source）与 Nginx map 键。
    [[ "${OWNER_TOKEN}" =~ ^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$ ]] \
        || die '订阅 Token 无效：需 8-128 位 URL 安全字符（A-Z a-z 0-9 . _ ~ -），首字符不能是 ~'
    ALLOWED_TOKENS="[\"${OWNER_TOKEN}\"]"
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-"/ws-$(openssl rand -hex 16)"}
    # 路径会写进 state.env 与 Nginx 的 location = ，只允许路径安全字符。
    [[ "${WEBSOCKET_PATH}" =~ ^/[A-Za-z0-9._/-]{1,95}$ && "${WEBSOCKET_PATH}" != *//* ]] \
        || die "WEBSOCKET_PATH 无效：需以 / 开头、仅含 A-Z a-z 0-9 . _ - /，长度 2-96：${WEBSOCKET_PATH}"
    TCP_ACCELERATION=${TCP_ACCELERATION:-skyline}
    SUB_DOWNLOAD_NAME=EASY_ALL
    STATE_VERSION=0
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
    render_mihomo_subscription "${MIHOMO_TEMPLATE_FILE}" "${RUNTIME_TMP}/nodes.yaml" \
        "${stage}/mihomo.yaml" "${SUB_DOWNLOAD_NAME}"
    strip_mihomo_sniffer "${stage}/mihomo.yaml" >"${stage}/mihomo-ios.yaml"
    publish_subscription_files "${stage}"
}

write_xray_config() {
    install -d -m 0700 "${XRAY_DIR}"
    cat >"${XRAY_CONFIG}" <<EOF
{"log":{"loglevel":"warning","access":"none"},
"inbounds":[{"tag":"bunny-ws","listen":"127.0.0.1","port":10086,"protocol":"vless",
"settings":{"clients":[{"id":"${VLESS_UUID}"}],"decryption":"none"},
"streamSettings":{"network":"ws","security":"none","wsSettings":{"path":"${WEBSOCKET_PATH}"}}}],
"outbounds":$(xray_direct_outbounds_json),
"routing":$(xray_direct_routing_json)}
EOF
    chmod 0600 "${XRAY_CONFIG}"
    "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" >/dev/null 2>&1 \
        || die "Xray 配置校验失败"
}

write_nginx_config() {
    optimize_nginx_system_config
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
    rm -f -- "${NGINX_DEFAULT_SITE}"
    install -m 0600 "${RUNTIME_TMP}/nginx.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || true
}

apply_cloud_resources() {
    acquire_runtime_write_lock
    bunny_ensure_python_jsonschema
    bunny_save_config
    if ! python3 "${SCRIPT_DIR}/bunny-api.py" apply \
        --journal "${BUNNY_JOURNAL}" --key-file "${BUNNY_KEY_FILE}" \
        --cloudflare-token-file "${BUNNY_CLOUDFLARE_TOKEN_FILE}" --config "${BUNNY_CONFIG}" \
        --lock-file "${RUNTIME_WRITE_LOCK_FILE}" --lock-fd 9; then
        release_runtime_write_lock
        return 1
    fi
    release_runtime_write_lock
}

apply_easy_all() {
    require_root
    acquire_runtime_write_lock
    load_state
    bunny_prepare_credentials
    apply_cloud_resources
    configure_ipv4_only
    write_xray_config
    write_subscriptions
    write_nginx_config
    systemctl restart "${XRAY_SERVICE}" || die "Xray 服务重启失败"
    validate_protocol_runtime
    validate_subscription_runtime
    release_runtime_write_lock
    info "本机配置、订阅与云端资源已同步"
}

show_node() {
    load_state
    build_node_links
}

show_subscription() {
    load_state
    printf '订阅 (owner): https://%s/subscribe?token=%s\n' \
        "${CDN_DOMAIN}" "${OWNER_TOKEN}"
    printf '%s\n' '  同一链接按客户端自动下发：Clash/mihomo/Stash/FlClash → YAML；Shadowrocket/v2rayN/v2rayNG/NekoBox → Base64'
}

show_status() {
    load_state
    printf '\n=== Bunny CDN (VLESS-WS) ===\n'
    printf 'CDN 域名: %s\n' "${CDN_DOMAIN}"
    printf '源站域名: %s\n' "${ORIGIN_DOMAIN}"
    printf 'Xray 状态: %s\n' "$(systemctl is-active "${XRAY_SERVICE}" 2>/dev/null || echo inactive)"
    printf 'Nginx 状态: %s\n' "$(systemctl is-active nginx 2>/dev/null || echo inactive)"
}

# 中断/失败后的本机清理：保留 Bunny journal 与云端资源，交给 uninstall --purge-cloud。
cleanup_partial_install() {
    # 删除失败时必须保留 marker：否则既丢了模式线索，调用方还会误以为已清理完成。
    bunny_remove_local || { warn "Bunny 残留未完全删除；保留安装进度标记以便重试"; return 1; }
    # bunny_remove_local 会恢复 Debian 默认站点并 reload；若不停掉，紧随其后的端口断言
    # 会被自己刚恢复的默认站点挡住。
    systemctl disable --now nginx >/dev/null 2>&1 || true
    install_progress_clear
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    require_root
    acquire_runtime_write_lock
    require_systemd
    check_platform
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    report_host_init_state
    ensure_swap
    install_failure_begin bunny-ws
    # bunny 的源站 nginx 固定监听 80（default_server）与 443，端口占用必须提前拦住。
    prepare_fresh_install 80 443
    install_progress_begin bunny-ws
    install_progress_stage packages
    install_packages
    bunny_reject_ssh_443
    install_progress_stage tcp
    snapshot_ipv6_state
    choose_tcp_acceleration
    configure_tcp_acceleration
    configure_ipv4_only
    install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
    [[ -e "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0600 "${UFW_DEFAULT_CONFIG}" "${BACKUP_DIR}/pre-install-ufw-default"
    [[ -e "${BACKUP_DIR}/pre-install-nginx-default" || ! -e "${NGINX_DEFAULT_SITE}" ]] \
        || install -m 0600 "${NGINX_DEFAULT_SITE}" "${BACKUP_DIR}/pre-install-nginx-default"
    install_progress_stage inputs
    bunny_collect_inputs
    bunny_save_config
    install_progress_stage cloud
    apply_cloud_resources
    bunny_issue_certificate "${ORIGIN_DOMAIN}"
    install_progress_stage services
    download_xray
    write_xray_config
    install_xray_service
    write_subscriptions
    write_nginx_config
    bunny_refresh_firewall
    validate_protocol_runtime
    validate_subscription_runtime
    bunny_validate_edge
    register_easy_all_command \
        || die "注册 easy_all 命令失败；修复后重新运行 sudo easy_all install"
    bunny_install_ip_timer \
        || die "启用 Bunny 回源定时器失败；修复后重新运行 sudo easy_all install"
    install_certificate_renewal_timer \
        || die "启用证书续期定时器失败；修复后重新运行 sudo easy_all install"
    install_progress_stage state
    save_state
    install_progress_clear
    python3 "${SCRIPT_DIR}/bunny-api.py" mark-committed --journal "${BUNNY_JOURNAL}" >/dev/null 2>&1 || true
    release_runtime_write_lock
    # 从这里开始只剩展示类命令：失败不再算“安装失败”。
    INSTALL_FAILURE_ARMED=0
    show_status
    show_subscription
    prompt_kernel_reboot
}

uninstall_all() {
    local purge_cloud=0
    if [[ $# -gt 1 || ( $# -eq 1 && "${1:-}" != "--purge-cloud" ) ]]; then
        die "用法：easy_all uninstall [--purge-cloud]"
    fi
    if [[ "${1:-}" == "--purge-cloud" ]]; then
        purge_cloud=1
    fi
    require_root
    acquire_runtime_write_lock
    if [[ "${purge_cloud}" == "1" ]]; then
        bunny_ensure_python_jsonschema
        if ! python3 "${SCRIPT_DIR}/bunny-api.py" purge \
            --journal "${BUNNY_JOURNAL}" --key-file "${BUNNY_KEY_FILE}" \
            --cloudflare-token-file "${BUNNY_CLOUDFLARE_TOKEN_FILE}" \
            --lock-file "${RUNTIME_WRITE_LOCK_FILE}" --lock-fd 9; then
            release_runtime_write_lock
            die "云端资源未清理完成；本机安装和 journal 已保留，可重试 easy_all uninstall --purge-cloud"
        fi
    fi
    bunny_remove_local || warn "部分 Bunny 本机文件未删除，请手工核对后清理"
    release_runtime_write_lock
    if [[ "${purge_cloud}" == "1" ]]; then
        info "已卸载本机服务并清理云端 Pull Zone 与 DNS 记录"
    else
        info "已卸载本机服务；云端配置及恢复凭据保留在 ${BUNNY_RECOVERY_DIR}"
    fi
}
