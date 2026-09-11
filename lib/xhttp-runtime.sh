#!/usr/bin/env bash

# Shared local runtime for CDN profiles.

readonly SCRIPT_DIR="${XHTTP_LIB_DIR:?XHTTP_LIB_DIR is required}"

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
readonly XRAY_BIN="${XRAY_BIN:-${XRAY_DIR}/xray}"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="${XHTTP_SERVICE_DESCRIPTION_OVERRIDE:-Xray VLESS XHTTP managed by easy_all}"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly UFW_DEFAULT_CONFIG="/etc/default/ufw"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-easy_all-bbr.conf"
readonly BBR_MODULES_CONFIG="/etc/modules-load.d/easy_all-bbr.conf"
readonly DEFAULT_XRAY_XHTTP_LOOPBACK_PORT="10086"
readonly SERVICE_PORT="443"
readonly DEFAULT_XHTTP_NODE_NAME="VLESS_XHTTP_H2"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/templates/mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_ARCHIVE="Xray-linux-64.zip"
readonly XRAY_DGST="Xray-linux-64.zip.dgst"
readonly STATE_SCHEMA_VERSION="9"
readonly XHTTP_NGINX_STREAM_TIMEOUT="1h"
readonly XHTTP_SERVER_KEEPALIVE_PADDING_LENGTH="100"
readonly XHTTP_CDN_NAME="${XHTTP_CDN_NAME_OVERRIDE:-Cloudflare}"
readonly SUBSCRIPTION_DEPLOY_DESCRIPTION="${SUBSCRIPTION_DEPLOY_DESCRIPTION_OVERRIDE:-${XHTTP_CDN_NAME} + Nginx}"

# shellcheck source=lib/runtime-core.sh
EASY_ALL_RUNTIME_LIB_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/runtime-core.sh"
# Keep at least one element: Debian still ships Bash versions where expanding
# an empty array under `set -u` raises "unbound variable".  Restricting these
# local probes to HTTPS is also the intended behavior for every provider.
XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')

nginx_supports_http2_directive() {
    command -v nginx >/dev/null 2>&1 || return 1
    local ver major minor patch
    ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    [[ -n "${ver}" ]] || return 1
    IFS=. read -r major minor patch <<<"${ver}"
    patch=${patch:-0}
    if (( major > 1 || (major == 1 && minor > 25) || (major == 1 && minor == 25 && patch >= 1) )); then
        return 0
    fi
    return 1
}

validate_xhttp_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
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
    read_bilingual "${label}，粘贴后按回车键；输入过程不会显示任何字符:" value 1
    printf '%s' "${value}"
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all XHTTP 状态文件不存在：${STATE_FILE}"
    # The state file must declare its own version; clear any value left behind by
    # an earlier `source` so a missing STATE_VERSION fails loudly instead of passing.
    unset STATE_VERSION
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
        domain=$(prompt_value "订阅链接完整域名（含完整主机名）" "${current}")
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
    apt-get -o DPkg::Lock::Timeout=300 update
    apt-get -o DPkg::Lock::Timeout=300 upgrade -y
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw nginx \
        fail2ban python3-systemd socat cron iproute2 iputils-ping tzdata \
        systemd-timesyncd tar util-linux
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || die "无法启用网络时间同步"
}

snapshot_fresh_install() {
    install -d -m 0700 "${BACKUP_DIR}"
    snapshot_ufw_state
    snapshot_platform_security_state
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
    if [[ -f "${UFW_DEFAULT_CONFIG}" ]]; then
        install -m 0600 "${UFW_DEFAULT_CONFIG}" "${BACKUP_DIR}/pre-install-ufw-default"
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
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ufw
    fi
    ensure_ssh_boot_service
    detect_ssh_ports
    configure_ufw_ip_family
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
    local keepalive_referer http2_directive="" listen_h2="http2 "
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    keepalive_referer=$(xhttp_server_keepalive_referer)
    install -d -m 0755 "${WEB_ROOT}"
    {
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen 80;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    location / { return 301 https://${XHTTP_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl ${listen_h2}backlog=4096;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;${http2_directive}
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
    local token base64_response base64_decoded mihomo_response marker
    XHTTP_ORIGIN_DOMAIN="${XHTTP_ORIGIN_DOMAIN:-}"
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    if declare -F xhttp_validate_local_tls_curl_args >/dev/null 2>&1; then
        xhttp_validate_local_tls_curl_args
    fi
    validate_subscription_token_rejection \
        "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
        "https://${XHTTP_ORIGIN_DOMAIN}/subscribe" \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}"
    if quota_enabled; then
        token=$(jq -r 'first(.[].token) // empty' <<<"$(quota_active_accounts_json)")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    fi
    base64_response=$(curl -fsS --noproxy '*' "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
        --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
        --get --data-urlencode "token=${token}" \
        "https://${XHTTP_ORIGIN_DOMAIN}/subscribe") || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    base64_decoded=$(printf '%s' "${base64_response}" | openssl base64 -d -A 2>/dev/null) \
        || die "通用订阅响应不是有效的 Base64"
    grep -Fq 'type=xhttp' <<<"${base64_decoded}" || die "通用订阅响应缺少 XHTTP 节点"
    mihomo_response=$(curl -fsS --noproxy '*' "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
        --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
        --get --data-urlencode "token=${token}" --data-urlencode "flag=clash" \
        "https://${XHTTP_ORIGIN_DOMAIN}/subscribe") || die "Mihomo 订阅本机验收失败"
    marker='network: xhttp'
    declare -F mihomo_transport_marker >/dev/null 2>&1 \
        && marker=$(mihomo_transport_marker)
    grep -Fq "${marker}" <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
}

xhttp_require_subscription_hooks() {
    local hook
    for hook in build_node_links build_mihomo_nodes \
        build_mihomo_proxy_groups build_mihomo_proxy_names; do
        declare -F "${hook}" >/dev/null 2>&1 \
            || die "CDN Profile 缺少订阅渲染钩子：${hook}"
    done
}

write_subscriptions() {
    local template node_file group_file name_file base64_file mihomo_file user uuid user_dir marker
    prepare_mihomo_template
    xhttp_require_subscription_hooks
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"
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
        "${XHTTP_NODE_NAME}" "${group_file}" "${name_file}"

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
    if [[ -f "${NGINX_CONFIG}" ]]; then
        install -m 0600 "${NGINX_CONFIG}" "${backup}/nginx.conf"
    fi
    if write_xray_config && write_nginx_config \
        && systemctl restart "${XRAY_SERVICE}" && validate_protocol_runtime; then
        success "运行时配置已刷新"
        return 0
    fi
    warn "刷新失败，恢复旧配置"
    install -m 0600 "${backup}/config.json" "${XRAY_CONFIG}"
    if [[ -f "${backup}/nginx.conf" ]]; then
        install -m 0600 "${backup}/nginx.conf" "${NGINX_CONFIG}"
    else
        rm -f -- "${NGINX_CONFIG}"
    fi
    systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
    die "运行时刷新失败"
}

rebuild_traffic_runtime() {
    refresh_runtime
}

snapshot_subscription_update() {
    UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
    [[ -f "${STATE_FILE}" ]] && install -m 0600 "${STATE_FILE}" "${UPDATE_SUB_BACKUP_DIR}/state.env"
    if [[ -n "${XRAY_CONFIG:-}" && -f "${XRAY_CONFIG}" ]]; then
        install -m 0600 "${XRAY_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/xray-config.json"
    fi
    if [[ -f "${NGINX_CONFIG}" ]]; then
        install -m 0600 "${NGINX_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/nginx.conf"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/nginx.conf.missing"
    fi
    if [[ -f "${CERT_FILE}" ]]; then
        install -m 0644 "${CERT_FILE}" "${UPDATE_SUB_BACKUP_DIR}/certificate.pem"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/certificate.missing"
    fi
    if [[ -f "${KEY_FILE}" ]]; then
        install -m 0600 "${KEY_FILE}" "${UPDATE_SUB_BACKUP_DIR}/private.key"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/private-key.missing"
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
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/xray-config.json" && -n "${XRAY_CONFIG:-}" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/xray-config.json" "${XRAY_CONFIG}"
        systemctl restart "${XRAY_SERVICE:-easy_all-xray.service}" >/dev/null 2>&1 \
            || warn "恢复订阅更新前 Xray 配置失败"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" "${NGINX_CONFIG}"
    else
        rm -f -- "${NGINX_CONFIG}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/certificate.pem" ]]; then
        install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/certificate.pem" "${CERT_FILE}"
    else
        rm -f -- "${CERT_FILE}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/private.key" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/private.key" "${KEY_FILE}"
    else
        rm -f -- "${KEY_FILE}"
    fi
    rm -rf -- "${SUBSCRIPTION_DIR}"
    if [[ -d "${UPDATE_SUB_BACKUP_DIR}/subscriptions" ]]; then
        install -d -o root -g www-data -m 0750 "$(dirname "${SUBSCRIPTION_DIR}")"
        cp -a "${UPDATE_SUB_BACKUP_DIR}/subscriptions" "${SUBSCRIPTION_DIR}"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 \
        || warn "恢复订阅更新前 Nginx 配置失败"
}

commit_subscription_update() {
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
}

finish_xhttp_apply() {
    local state_current=${1:-0} runtime_already_refreshed=${2:-0}
    local defer_state_save=${3:-0}
    if [[ "${runtime_already_refreshed}" != "1" ]]; then
        if [[ "${state_current}" == "1" ]]; then
            XHTTP_RUNTIME_STATE_CURRENT=1 refresh_runtime
        else
            refresh_runtime
        fi
    fi
    if subscription_enabled; then
        ensure_allowed_tokens
        write_subscriptions
        validate_subscription_runtime
    else
        remove_subscriptions
    fi
    [[ "${defer_state_save}" == "1" ]] || save_state
    register_easy_all_command
    refresh_saved_daily_reboot_schedule
    install_quota_timer
    [[ "${defer_state_save}" == "1" ]] || show_subscription
}

renew_certificate() {
    require_root
    collect_installed_state
    xhttp_renew_origin_certificate
}

restore_preinstall_firewall() {
    remove_managed_ufw_rules
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" \
            "${UFW_DEFAULT_CONFIG}"
    if [[ -f "${BACKUP_DIR}/pre-install-ufw.active" ]]; then
        ufw --force enable >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-ufw.inactive" \
        || -f "${BACKUP_DIR}/pre-install-ufw.missing" ]]; then
        command -v ufw >/dev/null 2>&1 \
            && ufw --force disable >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1 \
        && LC_ALL=C ufw status numbered 2>/dev/null | grep -q '^[[:space:]]*\['; then
        ufw --force enable >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1 || true
    fi
}

stop_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now nginx >/dev/null 2>&1 || true
}
