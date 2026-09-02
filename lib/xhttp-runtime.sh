#!/usr/bin/env bash

# Shared local runtime for the Cloudflare XHTTP profile.

readonly SCRIPT_DIR="${XHTTP_PROFILE_ROOT:?XHTTP_PROFILE_ROOT is required}"

readonly STATE_DIR="/etc/easy_all"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly WEB_ROOT="/var/www/easy_all"
readonly SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
readonly SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
readonly SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly ENTRY_COMMAND_NAME="easy_all"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="${XHTTP_SERVICE_DESCRIPTION_OVERRIDE:-Xray VLESS XHTTP managed by easy_all}"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-easy_all-bbr.conf"
readonly BBR_MODULES_CONFIG="/etc/modules-load.d/easy_all-bbr.conf"
readonly DEFAULT_XRAY_XHTTP_LOOPBACK_PORT="10086"
readonly SERVICE_PORT="443"
readonly DEFAULT_XHTTP_NODE_NAME="VLESS_XHTTP_H2"
readonly DEFAULT_CDN_CLIENT_IP_FAMILY="ipv6-prefer"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/templates/mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_ARCHIVE="Xray-linux-64.zip"
readonly XRAY_DGST="Xray-linux-64.zip.dgst"
readonly STATE_SCHEMA_VERSION="7"
readonly XHTTP_NGINX_STREAM_TIMEOUT="1h"
readonly XHTTP_SERVER_KEEPALIVE_PADDING_LENGTH="100"
readonly XHTTP_XMUX_MAX_CONNECTIONS="4"
readonly XHTTP_XMUX_C_MAX_REUSE_TIMES="0"
readonly XHTTP_XMUX_H_MAX_REQUEST_TIMES="300-600"
readonly XHTTP_XMUX_H_MAX_REUSABLE_SECS="900-1800"
readonly XHTTP_XMUX_H_KEEP_ALIVE_PERIOD="0"
readonly XHTTP_URL_TEST_INTERVAL="${XHTTP_URL_TEST_INTERVAL_OVERRIDE:-300}"
readonly XHTTP_CDN_NAME="Cloudflare"
readonly SUBSCRIPTION_DEPLOY_DESCRIPTION="${XHTTP_CDN_NAME} + Nginx"

# shellcheck source=lib/quota.sh
source "${SCRIPT_DIR}/quota.sh"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/platform.sh"
# shellcheck source=lib/profile-common.sh
source "${SCRIPT_DIR}/profile-common.sh"
# shellcheck source=lib/network.sh
source "${SCRIPT_DIR}/network.sh"
# shellcheck source=lib/mihomo-template.sh
source "${SCRIPT_DIR}/mihomo-template.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/firewall.sh"
# shellcheck source=lib/xray-core.sh
source "${SCRIPT_DIR}/xray-core.sh"
# shellcheck source=lib/scheduled-maintenance.sh
source "${SCRIPT_DIR}/scheduled-maintenance.sh"
# shellcheck source=lib/subscription-auth.sh
source "${SCRIPT_DIR}/subscription-auth.sh"
# shellcheck source=lib/tcp-tuning.sh
source "${SCRIPT_DIR}/tcp-tuning.sh"

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
CYAN='\033[1;36m'
RESET='\033[0m'

info() { printf '%b%s%b\n' "${CYAN}" "$*" "${RESET}"; }
success() { printf '%b%s%b\n' "${GREEN}" "$*" "${RESET}"; }
warn() { printf '%b%s%b\n' "${YELLOW}" "$*" "${RESET}"; }
fail() { printf '%b%s%b\n' "${RED}" "$*" "${RESET}" >&2; return 1; }
die() { fail "$*"; exit 1; }

RUNTIME_TMP=$(mktemp -d)
cleanup_files=("${RUNTIME_TMP}")
INSTALL_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_ON_EXIT=0
UPDATE_SUB_BACKUP_DIR=""
MIHOMO_TEMPLATE_FILE=""
CDN_CLIENT_IP_FAMILY_RESOLVED=""
# Keep at least one element: Debian still ships Bash versions where expanding
# an empty array under `set -u` raises "unbound variable".  Restricting these
# local probes to HTTPS is also the intended behavior for every provider.
XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')

cleanup() {
    local path
    if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        rollback_subscription_update || true
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

validate_xhttp_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
}

validate_cdn_client_ip_family() {
    [[ "$1" == "ipv6-prefer" || "$1" == "ipv4" ]]
}

configure_cdn_client_ip_family() {
    local expected=${DEFAULT_CDN_CLIENT_IP_FAMILY}
    if declare -F cdn_optimization_enabled >/dev/null 2>&1 \
        && cdn_optimization_enabled; then
        expected="ipv4"
    fi
    CDN_CLIENT_IP_FAMILY=${CDN_CLIENT_IP_FAMILY:-${expected}}
    if [[ "${expected}" == "ipv4" ]]; then
        CDN_CLIENT_IP_FAMILY="ipv4"
        CDN_CLIENT_IP_FAMILY_RESOLVED=${CDN_CLIENT_IP_FAMILY}
        return 0
    fi
    validate_cdn_client_ip_family "${CDN_CLIENT_IP_FAMILY}" \
        || die "CDN_CLIENT_IP_FAMILY 必须是 ipv6-prefer 或 ipv4"
    CDN_CLIENT_IP_FAMILY_RESOLVED=${CDN_CLIENT_IP_FAMILY}
}

choose_cdn_client_ip_family() {
    if declare -F cdn_optimization_enabled >/dev/null 2>&1 \
        && cdn_optimization_enabled; then
        CDN_CLIENT_IP_FAMILY="ipv4"
    else
        CDN_CLIENT_IP_FAMILY=${DEFAULT_CDN_CLIENT_IP_FAMILY}
    fi
    configure_cdn_client_ip_family
}

resolve_cdn_client_ip_family() {
    configure_cdn_client_ip_family
}

validate_cdn_client_ip_family_runtime() {
    resolve_cdn_client_ip_family
}

validate_loopback_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

generate_xhttp_path() {
    printf '/vless-%s' "$(openssl rand -hex 12)"
}

prompt_secret() {
    local label=$1 label_en=${2:-Input secretly / see the Chinese prompt above} value
    [[ -t 0 ]] || return 1
    read_bilingual "${label}，粘贴后按 Enter；输入过程不会显示任何字符:" \
        "${label_en}; paste it and press Enter; no characters will be displayed:" value 1
    printf '%s' "${value}"
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all XHTTP 状态文件不存在：${STATE_FILE}"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；请重新安装"
}

subscription_link_domain() {
    printf '%s' "${SUBSCRIPTION_DOMAIN:-${VLESS_CDN_DOMAIN}}"
}

active_subscription_link_domain() {
    if subscription_enabled; then
        subscription_link_domain
    else
        printf '%s' "${VLESS_CDN_DOMAIN}"
    fi
}

collect_subscription_link_domain() {
    local current domain
    current=$(subscription_link_domain)
    domain=${SUBSCRIPTION_DOMAIN:-}
    if [[ -t 0 ]]; then
        info "可直接复用 CDN 节点域名；自定义域名必须已由 Cloudflare DNS Zone 托管。"
        domain=$(prompt_value \
            "订阅链接完整域名（含完整主机名）" "${current}" \
            "Full subscription hostname (must be hosted by the same DNS provider as the CDN domain)")
    else
        domain=${domain:-${current}}
    fi
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    SUBSCRIPTION_DOMAIN=${domain}
}

check_install_conflicts() {
    local port
    for port in 80 443; do
        if ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
            die "TCP ${port} 已被占用；easy_all 仅支持专用 VPS"
        fi
    done
    [[ ! -d /etc/easy_all ]] \
        || die "检测到已有 easy_all 安装；一台 VPS 只允许一种模式"
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw nginx \
        fail2ban python3-systemd socat cron iproute2 iputils-ping tzdata \
        systemd-timesyncd tar util-linux
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || die "无法启用网络时间同步"
}

snapshot_fresh_install() {
    install -d -m 0700 "${BACKUP_DIR}"
    snapshot_ufw_state
    if [[ -f "${SYSCTL_CONFIG}" ]]; then
        install -m 0644 "${SYSCTL_CONFIG}" "${BACKUP_DIR}/pre-install-bbr.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-bbr.missing"
    fi
    if [[ -f "${BBR_MODULES_CONFIG}" ]]; then
        install -m 0644 "${BBR_MODULES_CONFIG}" "${BACKUP_DIR}/pre-install-bbr-module.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-bbr-module.missing"
    fi
    if crontab -l >"${BACKUP_DIR}/pre-install-crontab" 2>/dev/null; then
        chmod 0600 "${BACKUP_DIR}/pre-install-crontab"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-crontab.missing"
    fi
    snapshot_tcp_runtime
    INSTALL_ROLLBACK_ON_EXIT=1
}

snapshot_ufw_state() {
    [[ ! -e "${BACKUP_DIR}/pre-install-ufw.active" \
        && ! -e "${BACKUP_DIR}/pre-install-ufw.inactive" \
        && ! -e "${BACKUP_DIR}/pre-install-ufw.missing" ]] || return 0
    install -d -m 0700 "${BACKUP_DIR}"
    if ! command -v ufw >/dev/null 2>&1; then
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw.missing"
    elif LC_ALL=C ufw status 2>/dev/null | grep -q '^Status: active'; then
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw.active"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw.inactive"
    fi
    if [[ -f /etc/default/ufw ]]; then
        install -m 0600 /etc/default/ufw "${BACKUP_DIR}/pre-install-ufw-default"
    fi
}

configure_ufw() {
    if declare -F xhttp_configure_ufw >/dev/null 2>&1; then
        xhttp_configure_ufw
        return
    fi
    local desired_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ufw
    fi
    ensure_ssh_boot_service
    detect_ssh_ports
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    desired_ports="${SSH_PORTS} 80 443"
    apply_managed_ufw_tcp_ports "${desired_ports}"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

write_bootstrap_nginx_config() {
    rm -f -- /etc/nginx/sites-enabled/default
}

write_xray_config() {
    declare -F xhttp_render_xray_config >/dev/null \
        || die "XHTTP Profile 缺少 xhttp_render_xray_config 实现"
    xhttp_render_xray_config
}

xhttp_server_keepalive_referer() {
    local padding
    printf -v padding '%*s' "${XHTTP_SERVER_KEEPALIVE_PADDING_LENGTH}" ''
    padding=${padding// /X}
    printf 'https://%s%s/?x_padding=%s' "${VLESS_CDN_DOMAIN}" "${XHTTP_PATH}" "${padding}"
}

xhttp_client_path() {
    printf '%s/' "${XHTTP_PATH%/}"
}

write_nginx_config() {
    local keepalive_referer
    keepalive_referer=$(xhttp_server_keepalive_referer)
    install -d -m 0755 "${WEB_ROOT}"
    {
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    location / { return 301 https://${XHTTP_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl http2 backlog=4096;
    listen [::]:443 ssl http2 backlog=4096;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "easy_all ok\n";
    }

EOF
        write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}"
        cat <<EOF
    location ^~ ${XHTTP_PATH}/ {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        client_max_body_size 0;
        client_body_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_set_header Host ${VLESS_CDN_DOMAIN};
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_set_header X-Easy-All-Origin-Key \$http_x_easy_all_origin_key;
        grpc_set_header Referer "${keepalive_referer}";
        grpc_socket_keepalive on;
        grpc_read_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_send_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};
        access_log off;
    }

    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

validate_protocol_runtime() {
    local attempt response
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    if declare -F xhttp_validate_local_tls_curl_args >/dev/null 2>&1; then
        xhttp_validate_local_tls_curl_args
    fi
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${XRAY_SERVICE}" \
            && systemctl is-active --quiet nginx \
            && ss -H -ltn "sport = :443" 2>/dev/null | grep -q .; then
            response=$(curl -fsS "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
                --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
                -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
                "https://${XHTTP_ORIGIN_DOMAIN}/easy_all-health" || true)
            if [[ "${response}" == "easy_all ok" ]]; then
                validate_quota_api
                return 0
            fi
        fi
        sleep 2
    done
    die "VLESS XHTTP 本机运行时验收失败"
}

validate_subscription_runtime() {
    local token base64_response mihomo_response marker
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    if declare -F xhttp_validate_local_tls_curl_args >/dev/null 2>&1; then
        xhttp_validate_local_tls_curl_args
    fi
    validate_subscription_token_rejection \
        "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
        "https://${XHTTP_ORIGIN_DOMAIN}/subscribe" \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
        -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}"
    if quota_enabled; then
        token=$(jq -r 'first(.[].token) // empty' <<<"$(quota_active_accounts_json)")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    fi
    base64_response=$(curl -fsS --noproxy '*' "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
        --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
        -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
        --get --data-urlencode "token=${token}" \
        "https://${XHTTP_ORIGIN_DOMAIN}/subscribe") || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    mihomo_response=$(curl -fsS --noproxy '*' "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
        --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
        -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
        --get --data-urlencode "token=${token}" --data-urlencode "flag=clash" \
        "https://${XHTTP_ORIGIN_DOMAIN}/subscribe") || die "Mihomo 订阅本机验收失败"
    marker='network: xhttp'
    declare -F mihomo_transport_marker >/dev/null 2>&1 \
        && marker=$(mihomo_transport_marker)
    grep -Fq "${marker}" <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
}

uri_encode() {
    jq -nr --arg value "$1" '$value|@uri'
}

build_vless_xhttp_link() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-${XHTTP_NODE_NAME}}
    local extra client_path
    client_path=$(xhttp_client_path)
    extra=$(jq -cn \
        --argjson max_connections "${XHTTP_XMUX_MAX_CONNECTIONS}" \
        --argjson c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_request_times "${XHTTP_XMUX_H_MAX_REQUEST_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --argjson h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '{
        noGRPCHeader:false,
        uplinkHTTPMethod:"POST",
        xmux:{
            maxConnections:$max_connections,
            cMaxReuseTimes:$c_max_reuse_times,
            hMaxRequestTimes:$h_max_request_times,
            hMaxReusableSecs:$h_max_reusable_secs,
            hKeepAlivePeriod:$h_keep_alive_period
        }
    }')
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up&extra=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${client_path}")" "$(uri_encode "${extra}")" "$(uri_encode "${node_name}")"
}

xhttp_client_endpoints() {
    if declare -F cdn_client_endpoints >/dev/null 2>&1; then
        cdn_client_endpoints
    else
        printf '%s\n' "${VLESS_CDN_DOMAIN}"
    fi
}

xhttp_using_optimized_candidates() {
    declare -F cdn_optimization_enabled >/dev/null 2>&1 \
        && cdn_optimization_enabled \
        && declare -F globalping_cache_valid >/dev/null 2>&1 \
        && globalping_cache_valid
}

xhttp_node_name_for_endpoint() {
    local index=$1
    if xhttp_using_optimized_candidates; then
        printf '%s_IP_%02d' "${XHTTP_NODE_NAME}" "${index}"
    else
        printf '%s' "${XHTTP_NODE_NAME}"
    fi
}

build_node_links() {
    local endpoint index=1
    while IFS= read -r endpoint; do
        build_vless_xhttp_link "${endpoint}" \
            "$(xhttp_node_name_for_endpoint "${index}")"
        printf '\n'
        index=$((index + 1))
    done < <(xhttp_client_endpoints)
}

build_mihomo_node_for_endpoint() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-${XHTTP_NODE_NAME}}
    resolve_cdn_client_ip_family
    jq -nr --arg xhttp_name "${node_name}" \
        --arg server "${server}" --arg host "${VLESS_CDN_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" \
        --arg xhttp_path "$(xhttp_client_path)" \
        --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED}" \
        --argjson max_connections "${XHTTP_XMUX_MAX_CONNECTIONS}" \
        --arg c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_request_times "${XHTTP_XMUX_H_MAX_REQUEST_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --arg h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '
        "  - name: \($xhttp_name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: \($ip_version)\n    alpn:\n      - h2\n    xhttp-opts:\n" +
        "      host: \($host|@json)\n      path: \($xhttp_path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n" +
        "        max-connections: \($max_connections|tostring|@json)\n        c-max-reuse-times: \($c_max_reuse_times)\n" +
        "        h-max-request-times: \($h_max_request_times|@json)\n" +
        "        h-max-reusable-secs: \($h_max_reusable_secs|@json)\n" +
        "        h-keep-alive-period: \($h_keep_alive_period)\n"'
}

build_mihomo_nodes() {
    local endpoint index=1
    while IFS= read -r endpoint; do
        build_mihomo_node_for_endpoint "${endpoint}" \
            "$(xhttp_node_name_for_endpoint "${index}")"
        index=$((index + 1))
    done < <(xhttp_client_endpoints)
}

xhttp_auto_group_name() {
    if [[ "${CDN_PROVIDER:-}" == "cloudflare" ]]; then
        printf 'AUTO'
    else
        printf '%s_AUTO' "${XHTTP_NODE_NAME}"
    fi
}

build_mihomo_proxy_names() {
    local endpoint index=1
    if xhttp_using_optimized_candidates; then
        printf '        - %s\n' \
            "$(jq -Rn --arg value "$(xhttp_auto_group_name)" '$value')"
        return 0
    fi
    while IFS= read -r endpoint; do
        printf '        - %s\n' \
            "$(jq -Rn --arg value "$(xhttp_node_name_for_endpoint "${index}")" '$value')"
        index=$((index + 1))
    done < <(xhttp_client_endpoints)
}

build_mihomo_proxy_groups() {
    local endpoint index=1
    xhttp_using_optimized_candidates || return 0
    printf '    - name: %s\n' \
        "$(jq -Rn --arg value "$(xhttp_auto_group_name)" '$value')"
    cat <<'EOF'
      type: url-test
      proxies:
EOF
    while IFS= read -r endpoint; do
        printf '        - %s\n' \
            "$(jq -Rn --arg value "$(xhttp_node_name_for_endpoint "${index}")" '$value')"
        index=$((index + 1))
    done < <(xhttp_client_endpoints)
    cat <<EOF
      url: https://www.gstatic.com/generate_204
      interval: ${XHTTP_URL_TEST_INTERVAL}
      tolerance: 50
      lazy: false
EOF
}

write_subscriptions() {
    local template node_file group_file name_file base64_file mihomo_file user uuid user_dir marker
    prepare_mihomo_template
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"
    resolve_cdn_client_ip_family
    marker='network: xhttp'
    declare -F mihomo_transport_marker >/dev/null 2>&1 \
        && marker=$(mihomo_transport_marker)

    if quota_enabled; then
        rm -rf -- "${SUBSCRIPTION_DIR}"
        install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
        while IFS=$'\t' read -r user uuid; do
            user_dir="${SUBSCRIPTION_DIR}/${user}"
            (
                VLESS_UUID=${uuid}
                build_mihomo_nodes >"${node_file}.${user}"
                build_mihomo_proxy_groups >"${group_file}.${user}"
                build_mihomo_proxy_names >"${name_file}.${user}"
                build_node_links | openssl base64 -A >"${base64_file}.${user}"
                printf '\n' >>"${base64_file}.${user}"
                render_mihomo_subscription "${template}" "${node_file}.${user}" \
                    "${mihomo_file}.${user}" "${XHTTP_NODE_NAME}" \
                    "${CDN_CLIENT_IP_FAMILY_RESOLVED}" \
                    "${group_file}.${user}" "${name_file}.${user}"
            )
            grep -Fq "${marker}" "${mihomo_file}.${user}" \
                || die "Mihomo 订阅缺少有效节点：${user}"
            install -d -o root -g www-data -m 0750 "${user_dir}"
            install -o root -g www-data -m 0640 \
                "${base64_file}.${user}" "${user_dir}/base64.txt"
            install -o root -g www-data -m 0640 \
                "${mihomo_file}.${user}" "${user_dir}/mihomo.yaml"
        done < <(jq -r 'to_entries[] | [.key,.value.uuid] | @tsv' <<<"${USER_ACCOUNTS}")
        return 0
    fi
    build_mihomo_nodes >"${node_file}"
    build_mihomo_proxy_groups >"${group_file}"
    build_mihomo_proxy_names >"${name_file}"
    build_node_links | openssl base64 -A >"${base64_file}"
    printf '\n' >>"${base64_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}" \
        "${XHTTP_NODE_NAME}" "${CDN_CLIENT_IP_FAMILY_RESOLVED}" \
        "${group_file}" "${name_file}"

    grep -Fq "${marker}" "${mihomo_file}" || die "Mihomo 订阅缺少有效节点"
    grep -Fq "${VLESS_CDN_DOMAIN}" "${mihomo_file}" || die "Mihomo 订阅缺少 CDN 域名"
    rm -rf -- "${SUBSCRIPTION_DIR}"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
}

remove_subscriptions() {
    rm -rf -- "${SUBSCRIPTION_DIR}"
}

show_subscription() {
    collect_installed_state
    show_node
    if ! subscription_enabled; then
        printf '订阅服务: 未部署，仅输出节点信息\n\n'
        return 0
    fi
    printf 'Mihomo 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME}"
    local user token subscription_domain
    subscription_domain=$(subscription_link_domain)
    printf '订阅链接域名: %s\n' "${subscription_domain}"
    while IFS=$'\t' read -r user token; do
        printf '通用订阅 (%s): https://%s/subscribe?token=%s\n' \
            "${user}" "${subscription_domain}" "${token}"
        printf 'Mihomo (%s):  https://%s/subscribe?token=%s&flag=clash\n' \
            "${user}" "${subscription_domain}" "${token}"
    done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"${ALLOWED_TOKENS}")
    printf '\n'
}

refresh_runtime() {
    local backup
    [[ "${XHTTP_RUNTIME_STATE_CURRENT:-0}" == "1" ]] || collect_installed_state
    backup=$(make_temp_dir)
    install -m 0600 "${XRAY_CONFIG}" "${backup}/config.json"
    install -m 0600 "${NGINX_CONFIG}" "${backup}/nginx.conf"
    if write_xray_config && write_nginx_config \
        && systemctl restart "${XRAY_SERVICE}" && validate_protocol_runtime; then
        success "运行时配置已刷新"
        return 0
    fi
    warn "刷新失败，恢复旧配置"
    install -m 0600 "${backup}/config.json" "${XRAY_CONFIG}"
    install -m 0600 "${backup}/nginx.conf" "${NGINX_CONFIG}"
    systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
    die "运行时刷新失败"
}

rebuild_traffic_runtime() {
    refresh_runtime
}

snapshot_subscription_update() {
    UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
    install -m 0600 "${STATE_FILE}" "${UPDATE_SUB_BACKUP_DIR}/state.env"
    install -m 0600 "${XRAY_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/xray-config.json"
    if [[ -f "${NGINX_CONFIG}" ]]; then
        install -m 0600 "${NGINX_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/nginx.conf"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/nginx.conf.missing"
    fi
    if [[ -d "${SUBSCRIPTION_DIR}" ]]; then
        cp -a "${SUBSCRIPTION_DIR}" "${UPDATE_SUB_BACKUP_DIR}/subscriptions"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/subscriptions.missing"
    fi
    UPDATE_SUB_ROLLBACK_ON_EXIT=1
}

rollback_subscription_update() {
    if declare -F rollback_provider_subscription_update >/dev/null 2>&1; then
        if ! (rollback_provider_subscription_update); then
            warn "恢复订阅更新前的云端 CDN/DNS 状态失败，请立即执行 easy_all apply-cloud 复核"
        fi
    fi
    warn "本机配置更新失败，正在恢复状态、Nginx 与订阅文件"
    [[ -f "${UPDATE_SUB_BACKUP_DIR}/state.env" ]] \
        && install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/state.env" "${STATE_FILE}"
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/xray-config.json" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/xray-config.json" "${XRAY_CONFIG}"
        systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 \
            || warn "恢复订阅更新前 Xray 配置失败"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" "${NGINX_CONFIG}"
    else
        rm -f -- "${NGINX_CONFIG}"
    fi
    rm -rf -- "${SUBSCRIPTION_DIR}"
    if [[ -d "${UPDATE_SUB_BACKUP_DIR}/subscriptions" ]]; then
        install -d -o root -g www-data -m 0750 "$(dirname "${SUBSCRIPTION_DIR}")"
        cp -a "${UPDATE_SUB_BACKUP_DIR}/subscriptions" "${SUBSCRIPTION_DIR}"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 \
        || warn "恢复订阅更新前 Nginx 配置失败"
}

finish_xhttp_apply() {
    local state_current=${1:-0}
    if [[ "${state_current}" == "1" ]]; then
        XHTTP_RUNTIME_STATE_CURRENT=1 refresh_runtime
    else
        refresh_runtime
    fi
    validate_cdn_client_ip_family_runtime
    if subscription_enabled; then
        ensure_allowed_tokens
        write_subscriptions
        validate_subscription_runtime
    else
        remove_subscriptions
    fi
    save_state
    register_easy_all_command
    install_quota_timer
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
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
        download_xray
        systemctl restart "${XRAY_SERVICE}"
        validate_protocol_runtime
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

renew_certificate() {
    require_root
    collect_installed_state
    xhttp_renew_origin_certificate
}

restore_preinstall_firewall() {
    remove_managed_ufw_rules
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" /etc/default/ufw
    if command -v ufw >/dev/null 2>&1 \
        && LC_ALL=C ufw status numbered 2>/dev/null | grep -q '^[[:space:]]*\['; then
        ufw --force enable >/dev/null 2>&1 || true
        info "检测到其他 UFW 规则，保留 UFW 启用状态"
    elif [[ -f "${BACKUP_DIR}/pre-install-ufw.active" ]]; then
        ufw --force enable >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1 || true
    fi
}

stop_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now nginx >/dev/null 2>&1 || true
}
