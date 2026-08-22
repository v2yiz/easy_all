#!/usr/bin/env bash

# Shared local runtime for XHTTP Profiles. Provider state and cloud APIs remain
# in the AWS and Gcore Profiles.

readonly EASY_ALL_PROFILE="xhttp"
readonly SCRIPT_DIR="${XHTTP_PROFILE_ROOT:?XHTTP_PROFILE_ROOT is required}"
readonly SCRIPT_FILE="${XHTTP_PROFILE_FILE:?XHTTP_PROFILE_FILE is required}"

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
readonly ENTRY_SCRIPT_FILE="${EASY_ALL_ENTRY_SCRIPT:-${SCRIPT_FILE}}"
readonly ENTRY_COMMAND_NAME="easy_all"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-tls-service.sh"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="Xray VLESS XHTTP managed by easy_all"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly ACME_HOME="/root/.acme-aws.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-easy_all-bbr.conf"
readonly BBR_MODULES_CONFIG="/etc/modules-load.d/easy_all-bbr.conf"
readonly BBR_ALLOW_EXISTING_XANMOD="0"
readonly DEFAULT_XRAY_XHTTP_LOOPBACK_PORT="10086"
readonly SERVICE_PORT="443"
readonly DEFAULT_XHTTP_NODE_NAME="VLESS_XHTTP_H2"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/sample-mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_ARCHIVE="Xray-linux-64.zip"
readonly XRAY_DGST="Xray-linux-64.zip.dgst"
readonly STATE_SCHEMA_VERSION="4"
readonly XHTTP_NGINX_STREAM_TIMEOUT="1h"
readonly XHTTP_SERVER_KEEPALIVE_PADDING_LENGTH="100"
readonly XHTTP_XMUX_MAX_CONCURRENCY="8-16"
readonly XHTTP_XMUX_C_MAX_REUSE_TIMES="0"
readonly XHTTP_XMUX_H_MAX_REUSABLE_SECS="1800-3000"
readonly XHTTP_XMUX_H_KEEP_ALIVE_PERIOD="0"
readonly XHTTP_CDN_NAME="${XHTTP_CDN_NAME_OVERRIDE:-CloudFront}"
readonly XHTTP_ORIGIN_DNS_NAME="${XHTTP_ORIGIN_DNS_NAME_OVERRIDE:-Route 53}"

# shellcheck source=lib/quota.sh
source "${SCRIPT_DIR}/quota.sh"
# shellcheck source=lib/cdn-traffic-guard.sh
source "${SCRIPT_DIR}/cdn-traffic-guard.sh"
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
alert() { printf '%b%s%b\n' "${RED}" "$*" "${RESET}"; }
fail() { printf '%b%s%b\n' "${RED}" "$*" "${RESET}" >&2; return 1; }
die() { fail "$*"; exit 1; }

RUNTIME_TMP=$(mktemp -d)
cleanup_files=("${RUNTIME_TMP}")
INSTALL_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_ON_EXIT=0
UPDATE_SUB_BACKUP_DIR=""
MIHOMO_TEMPLATE_FILE=""
GEMINI_DOMAIN_SUFFIXES_JSON=""
GEMINI_IP_FAMILY_RESOLVED=""
CDN_CLIENT_IP_FAMILY_RESOLVED=""

cleanup() {
    local path
    if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        rollback_subscription_update || true
    elif [[ "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        INSTALL_ROLLBACK_ON_EXIT=0
        rollback_fresh_install || true
    fi
    for path in "${cleanup_files[@]:-}"; do
        [[ -n "${path}" ]] && rm -rf -- "${path}"
    done
}
trap cleanup EXIT

validate_xhttp_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
}

configure_cdn_client_ip_family() {
    CDN_CLIENT_IP_FAMILY=${CDN_CLIENT_IP_FAMILY:-auto}
    CDN_CLIENT_IP_FAMILY_RESOLVED=""
    [[ "${CDN_CLIENT_IP_FAMILY}" =~ ^(auto|ipv4|dual)$ ]] \
        || die "CDN_CLIENT_IP_FAMILY 必须是 auto、ipv4 或 dual"
}

cdn_domain_has_address_record() {
    local type=$1 resolver record
    for resolver in 1.1.1.1 8.8.8.8; do
        while IFS= read -r record; do
            case "${type}" in
            A)
                validate_ipv4 "${record}" && return 0
                ;;
            AAAA)
                [[ "${record}" == *:* \
                    && "${record}" =~ ^[0-9A-Fa-f:]+$ ]] && return 0
                ;;
            *) return 1 ;;
            esac
        done < <(dig +short "${type}" "${VLESS_CDN_DOMAIN}" @"${resolver}" \
            2>/dev/null || true)
    done
    return 1
}

cdn_domain_is_dual_stack() {
    cdn_domain_has_address_record A && cdn_domain_has_address_record AAAA
}

resolve_cdn_client_ip_family() {
    [[ -n "${CDN_CLIENT_IP_FAMILY_RESOLVED:-}" ]] && return 0
    configure_cdn_client_ip_family
    case "${CDN_CLIENT_IP_FAMILY}" in
    ipv4) CDN_CLIENT_IP_FAMILY_RESOLVED="ipv4" ;;
    dual) CDN_CLIENT_IP_FAMILY_RESOLVED="dual" ;;
    auto)
        if cdn_domain_is_dual_stack; then
            CDN_CLIENT_IP_FAMILY_RESOLVED="dual"
        else
            CDN_CLIENT_IP_FAMILY_RESOLVED="ipv4"
        fi
        ;;
    esac
}

validate_cdn_client_ip_family_runtime() {
    resolve_cdn_client_ip_family
    if [[ "${CDN_CLIENT_IP_FAMILY}" == "dual" ]] \
        && ! cdn_domain_is_dual_stack; then
        die "CDN_CLIENT_IP_FAMILY=dual 需要 ${VLESS_CDN_DOMAIN} 在公共 DNS 同时提供 A 和 AAAA"
    fi
}

validate_loopback_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

generate_xhttp_path() {
    printf '/vless-%s' "$(openssl rand -hex 12)"
}

prompt_secret() {
    local label=$1 value
    [[ -t 0 ]] || return 1
    read -r -s -p "${label}: " value
    printf '\n' >&2
    printf '%s' "${value}"
}

choose_subscription_mode() {
    local mode=${SUBSCRIBE_MODE:-${SUBSCRIPTION_MODE:-}} current_mode default_choice=1
    if [[ "${PROMPT_SUBSCRIPTION_MODE:-0}" == "1" || -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            current_mode=${mode:-deploy}
            [[ "${current_mode}" == "link" ]] && default_choice=2
            printf '请选择是否部署订阅服务：\n'
            printf '  1. 部署订阅服务（%s + Nginx；只有当前服务器时推荐）\n' \
                "${XHTTP_CDN_NAME}"
            printf '  2. 不部署，仅输出节点信息（多节点聚合或已有订阅服务器时推荐）\n'
            read -r -p "请选择 [${default_choice}]（直接回车使用默认值）: " mode
            mode=${mode:-${current_mode}}
        elif [[ -z "${mode}" ]]; then
            die "非交互模式必须设置 SUBSCRIBE_MODE=deploy 或 SUBSCRIBE_MODE=link"
        fi
    fi
    mode=${mode:-deploy}
    case "${mode}" in
    1 | deploy | selfhost | nginx) SUBSCRIPTION_MODE="deploy" ;;
    2 | link | node) SUBSCRIPTION_MODE="link" ;;
    *) die "订阅服务选项无效：${mode}" ;;
    esac
}

subscription_enabled() {
    [[ "${SUBSCRIPTION_MODE:-deploy}" == "deploy" ]]
}

choose_subscription_download_name() {
    local name=${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}
    if [[ -t 0 ]]; then
        name=$(prompt_value "Mihomo 下载文件名（不含 .yaml）" "${name}")
    fi
    name=$(normalize_sub_download_name "${name}")
    validate_sub_download_name "${name}" || die "Mihomo 下载文件名无效：${name}"
    SUB_DOWNLOAD_NAME=${name}
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all XHTTP 状态文件不存在：${STATE_FILE}"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}"
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
        ca-certificates curl wget jq unzip openssl dnsutils ufw nginx \
        fail2ban python3-systemd socat cron iproute2 iputils-ping tzdata \
        systemd-timesyncd tar
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

verify_origin_dns() {
    local public_ip records resolver attempt resolver_ok last_records=""
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    info "等待 ${XHTTP_ORIGIN_DNS_NAME} 源站 A 记录传播到公共 DNS"
    for attempt in {1..60}; do
        last_records=""
        for resolver in 1.1.1.1 8.8.8.8; do
            records=$(dig +short A "${AWS_ORIGIN_DOMAIN}" @"${resolver}" 2>/dev/null \
                | awk 'NF' | sort -u || true)
            last_records+="${resolver}: ${records:-未解析}; "
            resolver_ok=1
            [[ -n "${records}" ]] || resolver_ok=0
            if [[ -n "${records}" ]]; then
                while read -r record; do
                    if ! validate_ipv4 "${record}" || [[ "${record}" != "${public_ip}" ]]; then
                        resolver_ok=0
                        break
                    fi
                done <<<"${records}"
            fi
            [[ "${resolver_ok}" == 1 ]] && return 0
        done
        sleep 5
    done
    die "源站域名 ${AWS_ORIGIN_DOMAIN} 尚未解析到当前 VPS ${public_ip}（公共 DNS：${last_records% })"
}

write_web_root() {
    install -d -m 0755 "${WEB_ROOT}/.well-known/acme-challenge"
    printf '%s\n' 'ready' >"${WEB_ROOT}/index.html"
    chmod 0644 "${WEB_ROOT}/index.html"
}

write_bootstrap_nginx_config() {
    write_web_root
    rm -f -- /etc/nginx/sites-enabled/default
    cat >"${RUNTIME_TMP}/easy_all-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${AWS_ORIGIN_DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 404; }
}
EOF
    install -m 0600 "${RUNTIME_TMP}/easy_all-bootstrap.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx HTTP 引导配置校验失败"
    systemctl enable --now nginx >/dev/null || die "启动 Nginx 失败"
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

install_acme() {
    if [[ -x "${ACME_BIN}" ]]; then
        ensure_acme_renewal_setup
        return 0
    fi
    local installer="${RUNTIME_TMP}/get-acme.sh"
    local account_email=${ACME_EMAIL:-admin@${AWS_ORIGIN_DOMAIN}}
    curl -fsSL --retry 3 https://get.acme.sh -o "${installer}" || die "下载 acme.sh 失败"
    sh "${installer}" "email=${account_email}" --home "${ACME_HOME}" || die "安装 acme.sh 失败"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装后不可用"
    install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
    ensure_acme_renewal_setup
}

issue_origin_certificate() {
    local issue_status=0
    install_acme
    run_acme --set-default-ca --server letsencrypt >/dev/null \
        || die "设置 Let's Encrypt 为默认 CA 失败"
    run_acme --issue --webroot "${WEB_ROOT}" -d "${AWS_ORIGIN_DOMAIN}" --keylength ec-256 \
        || issue_status=$?
    [[ "${issue_status}" == 0 || "${issue_status}" == 2 ]] \
        || die "源站证书申请失败（acme.sh 返回 ${issue_status}）"
    install -d -m 0700 "${CERT_DIR}" "${COMMAND_INSTALL_DIR}"
    cat >"${RUNTIME_TMP}/reload-tls-service.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx.service >/dev/null 2>&1 || systemctl restart nginx.service >/dev/null 2>&1
EOF
    install -m 0755 "${RUNTIME_TMP}/reload-tls-service.sh" "${CERT_RELOAD_HOOK}"
    run_acme --install-cert -d "${AWS_ORIGIN_DOMAIN}" --ecc \
        --fullchain-file "${CERT_FILE}" --key-file "${KEY_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}" || die "安装源站证书失败"
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" && -x "${CERT_RELOAD_HOOK}" ]] \
        || die "源站证书、私钥或续期重载钩子安装不完整"
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

write_subscription_nginx_maps() {
    subscription_enabled || return 0
    cat <<'EOF'
map $arg_token $easy_all_subscription_allowed {
    default __denied__;
EOF
    write_subscription_token_map
    cat <<'EOF'
}

map $arg_flag $easy_all_subscription_uri {
    default /_easy_all_subscription/base64;
    clash /_easy_all_subscription/mihomo;
}

EOF
}

write_subscription_nginx_locations() {
    local base64_alias="${SUBSCRIPTION_BASE64_FILE}"
    local mihomo_alias="${SUBSCRIPTION_MIHOMO_FILE}"
    subscription_enabled || return 0
    if quota_enabled; then
        base64_alias="${SUBSCRIPTION_DIR}/\$easy_all_subscription_allowed/base64.txt"
        mihomo_alias="${SUBSCRIPTION_DIR}/\$easy_all_subscription_allowed/mihomo.yaml"
    fi
    cat <<EOF
    location = /subscribe {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        if (\$request_method !~ ^(GET|HEAD)$) { return 405; }
        if (\$easy_all_subscription_allowed = __denied__) { return 403; }
        rewrite ^ \$easy_all_subscription_uri last;
    }

    location = /_easy_all_subscription/base64 {
        internal;
        alias ${base64_alias};
        default_type text/plain;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

    location = /_easy_all_subscription/mihomo {
        internal;
        alias ${mihomo_alias};
        default_type text/yaml;
        add_header Content-Disposition "attachment; filename=${SUB_DOWNLOAD_NAME}" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

EOF
}

write_nginx_config() {
    local keepalive_referer
    keepalive_referer=$(xhttp_server_keepalive_referer)
    write_web_root
    {
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${AWS_ORIGIN_DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://${AWS_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl http2 backlog=4096;
    listen [::]:443 ssl http2 backlog=4096;
    server_name ${AWS_ORIGIN_DOMAIN};
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
        write_subscription_nginx_locations
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
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${XRAY_SERVICE}" \
            && systemctl is-active --quiet nginx \
            && ss -H -ltn "sport = :443" 2>/dev/null | grep -q .; then
            response=$(curl -fsS --resolve "${AWS_ORIGIN_DOMAIN}:443:127.0.0.1" \
                -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
                "https://${AWS_ORIGIN_DOMAIN}/easy_all-health" || true)
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
    local token base64_response mihomo_response
    if quota_enabled; then
        token=$(jq -r 'first(.[].token) // empty' <<<"$(quota_active_accounts_json)")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    fi
    base64_response=$(curl -fsS --resolve "${AWS_ORIGIN_DOMAIN}:443:127.0.0.1" \
        -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
        --get --data-urlencode "token=${token}" \
        "https://${AWS_ORIGIN_DOMAIN}/subscribe") || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    mihomo_response=$(curl -fsS --resolve "${AWS_ORIGIN_DOMAIN}:443:127.0.0.1" \
        -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
        --get --data-urlencode "token=${token}" --data-urlencode "flag=clash" \
        "https://${AWS_ORIGIN_DOMAIN}/subscribe") || die "Mihomo 订阅本机验收失败"
    grep -Fq 'network: xhttp' <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
}

uri_encode() {
    jq -nr --arg value "$1" '$value|@uri'
}

build_vless_xhttp_link() {
    local extra
    extra=$(jq -cn \
        --arg max_concurrency "${XHTTP_XMUX_MAX_CONCURRENCY}" \
        --argjson c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --argjson h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '{
        noGRPCHeader:false,
        uplinkHTTPMethod:"POST",
        xmux:{
            maxConcurrency:$max_concurrency,
            cMaxReuseTimes:$c_max_reuse_times,
            hMaxReusableSecs:$h_max_reusable_secs,
            hKeepAlivePeriod:$h_keep_alive_period
        }
    }')
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up&extra=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${XHTTP_PATH}")" "$(uri_encode "${extra}")" "$(uri_encode "${XHTTP_NODE_NAME}")"
}

build_node_link() {
    build_vless_xhttp_link
}

build_mihomo_node() {
    resolve_cdn_client_ip_family
    jq -nr --arg xhttp_name "${XHTTP_NODE_NAME}" \
        --arg server "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg xhttp_path "${XHTTP_PATH}" \
        --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED}" \
        --arg max_concurrency "${XHTTP_XMUX_MAX_CONCURRENCY}" \
        --arg c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --arg h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '
        "  - name: \($xhttp_name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($server|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: \($ip_version)\n    alpn:\n      - h2\n    xhttp-opts:\n" +
        "      host: \($server|@json)\n      path: \($xhttp_path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n" +
        "        max-concurrency: \($max_concurrency|@json)\n        c-max-reuse-times: \($c_max_reuse_times)\n" +
        "        h-max-reusable-secs: \($h_max_reusable_secs|@json)\n" +
        "        h-keep-alive-period: \($h_keep_alive_period)\n"'
}

render_mihomo_subscription() {
    local template=$1 node_file=$2 destination=$3 node_name ipv6_enabled=false
    resolve_cdn_client_ip_family
    [[ "${CDN_CLIENT_IP_FAMILY_RESOLVED}" != "dual" ]] || ipv6_enabled=true
    node_name=$(jq -Rn --arg value "${XHTTP_NODE_NAME}" '$value')
    awk -v node_file="${node_file}" -v node_name="${node_name}" \
        -v ipv6_enabled="${ipv6_enabled}" '
        $0 ~ /^ipv6: (true|false)$/ {
            print "ipv6: " ipv6_enabled
            next
        }
        $0 == "# EASY_ALL_PROXY_NODE" {
            while ((getline line < node_file) > 0) print line
            close(node_file)
            next
        }
        $0 == "# EASY_ALL_PROXY_NAME" { print "        - " node_name; next }
        { print }
    ' "${template}" >"${destination}" || die "生成 Mihomo 订阅失败"
}

write_subscriptions() {
    local template node_file base64_file mihomo_file user uuid user_dir
    prepare_mihomo_template
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"
    resolve_cdn_client_ip_family

    if quota_enabled; then
        rm -rf -- "${SUBSCRIPTION_DIR}"
        install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
        while IFS=$'\t' read -r user uuid; do
            user_dir="${SUBSCRIPTION_DIR}/${user}"
            (
                VLESS_UUID=${uuid}
                build_mihomo_node >"${node_file}.${user}"
                printf '%s' "$(build_node_link)" | openssl base64 -A >"${base64_file}.${user}"
                printf '\n' >>"${base64_file}.${user}"
                render_mihomo_subscription "${template}" "${node_file}.${user}" \
                    "${mihomo_file}.${user}"
            )
            grep -Fq 'network: xhttp' "${mihomo_file}.${user}" \
                || die "Mihomo 订阅缺少 XHTTP 节点：${user}"
            install -d -o root -g www-data -m 0750 "${user_dir}"
            install -o root -g www-data -m 0640 \
                "${base64_file}.${user}" "${user_dir}/base64.txt"
            install -o root -g www-data -m 0640 \
                "${mihomo_file}.${user}" "${user_dir}/mihomo.yaml"
        done < <(jq -r 'to_entries[] | [.key,.value.uuid] | @tsv' <<<"${USER_ACCOUNTS}")
        return 0
    fi
    build_mihomo_node >"${node_file}"
    printf '%s' "$(build_node_link)" | openssl base64 -A >"${base64_file}"
    printf '\n' >>"${base64_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}"

    grep -Fq 'network: xhttp' "${mihomo_file}" || die "Mihomo 订阅缺少 XHTTP 节点"
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
    local user token
    while IFS=$'\t' read -r user token; do
        printf '通用订阅 (%s): https://%s/subscribe?token=%s\n' \
            "${user}" "${VLESS_CDN_DOMAIN}" "${token}"
        printf 'Mihomo (%s):  https://%s/subscribe?token=%s&flag=clash\n' \
            "${user}" "${VLESS_CDN_DOMAIN}" "${token}"
    done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"${ALLOWED_TOKENS}")
    printf '\n'
}

refresh_runtime() {
    local backup
    collect_installed_state
    cloudfront_fee_protection_checkpoint
    backup=$(make_temp_dir)
    install -m 0600 "${XRAY_CONFIG}" "${backup}/config.json"
    install -m 0600 "${NGINX_CONFIG}" "${backup}/nginx.conf"
    if write_xray_config && write_nginx_config \
        && systemctl restart "${XRAY_SERVICE}" && validate_protocol_runtime \
        && cloudfront_fee_mark_enforced; then
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
    warn "订阅更新失败，正在恢复状态、Nginx 配置与订阅文件"
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
    refresh_runtime
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
    install_cloudfront_fee_protection_timer
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/xray-backup"
    require_root
    begin_quota_maintenance
    collect_installed_state
    install -m 0755 "${XRAY_BIN}" "${backup_bin}"
    if download_xray; then
        cloudfront_fee_protection_checkpoint
        if cloudfront_fee_protection_needs_apply; then
            write_xray_config
        fi
        if systemctl restart "${XRAY_SERVICE}" && validate_protocol_runtime \
            && cloudfront_fee_mark_enforced; then
            end_quota_maintenance
            success "Xray 已更新"
            return 0
        fi
    fi
    install -m 0755 "${backup_bin}" "${XRAY_BIN}"
    systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    die "Xray 更新失败，已恢复旧版本"
}

renew_certificate() {
    require_root
    collect_installed_state
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 尚未安装"
    run_acme --renew -d "${AWS_ORIGIN_DOMAIN}" --ecc --force || die "源站证书续期失败"
    "${CERT_RELOAD_HOOK}" || die "证书已续期，但 Nginx 重载失败"
    success "源站证书已续期"
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

remove_managed_acme_domain() {
    [[ -n "${1:-}" && -x "${ACME_BIN}" ]] || return 0
    run_acme --remove -d "$1" --ecc >/dev/null 2>&1 || true
    rm -rf -- "${ACME_HOME:?}/$1" "${ACME_HOME:?}/${1}_ecc"
}

stop_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now nginx >/dev/null 2>&1 || true
}
