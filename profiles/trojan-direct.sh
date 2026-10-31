#!/usr/bin/env bash

# Trojan (TLS) direct profile for the unified easy_all launcher.
#
# TLS is terminated by Xray on TCP 443. Anything that is not a valid Trojan
# session is handed to a local Nginx instance that serves a static marketing
# site, so a browser visiting the same hostname sees a normal website.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'trojan-direct.sh 是 easy_all 的 Trojan 直连 Profile；请使用：easy_all install\n' >&2
    exit 2
fi

readonly TROJAN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR="${TROJAN_PROFILE_ROOT}/../lib"
readonly SITE_TEMPLATE_DIR="${TROJAN_PROFILE_ROOT}/../templates/site"

readonly STATE_DIR="/etc/easy_all"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly LEGO_DIR="${STATE_DIR}/acme"
readonly LEGO_BIN="${LEGO_DIR}/lego"
readonly LEGO_VERSION_FILE="${LEGO_DIR}/version"
readonly LEGO_CERT_DIR="${LEGO_DIR}/certificates"
readonly LEGO_DNS_ENV="${LEGO_DIR}/cloudflare-dns.env"
readonly LEGO_INSTALL_HOOK="${LEGO_DIR}/install-certificate"
readonly WEB_ROOT="/var/www/easy_all"
readonly SITE_ROOT="${WEB_ROOT}/site"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly ENTRY_COMMAND_NAME="${EASY_ALL_ENTRY_COMMAND:-easy_all}"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="Xray Trojan direct managed by easy_all"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly NGINX_SITE_LISTEN="127.0.0.1:8080"
readonly NGINX_SITE_PORT="8080"
readonly CERT_RENEW_SERVICE_FILE="/etc/systemd/system/easy_all-cert-renew.service"
readonly CERT_RENEW_TIMER_FILE="/etc/systemd/system/easy_all-cert-renew.timer"
readonly CERT_RENEW_SERVICE="easy_all-cert-renew.service"
readonly CERT_RENEW_TIMER="easy_all-cert-renew.timer"
readonly UFW_BEFORE_RULES="/etc/ufw/before.rules"
readonly UFW_BEFORE6_RULES="/etc/ufw/before6.rules"
readonly UFW_DEFAULT_CONFIG="/etc/default/ufw"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly UFW_NAT_START="# easy_all-nat-start"
readonly UFW_NAT_END="# easy_all-nat-end"
readonly UFW_NAT6_START="# easy_all-nat6-start"
readonly UFW_NAT6_END="# easy_all-nat6-end"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-easy_all-bbr.conf"
readonly BBR_MODULES_CONFIG="/etc/modules-load.d/easy_all-bbr.conf"
readonly IPV6_SYSCTL_CONF="/etc/sysctl.d/99-enable-ipv6.conf"
readonly SERVICE_PORT="443"
readonly PORT_BASE="10000"
readonly DYNAMIC_PORTS_PER_HOUR="6"
readonly DYNAMIC_PORT_ROTATION_HOURS="1"
readonly DYNAMIC_PORT_MAX="$((PORT_BASE + 366 * 24 * DYNAMIC_PORTS_PER_HOUR - 1))"
readonly DEFAULT_TROJAN_NODE_NAME="MY_TROJAN"
readonly DEFAULT_TROJAN_PORT_MODE="dynamic"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly CRON_DYNAMIC_PORT_MARKER="# easy_all-managed-dynamic-ports"
readonly CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"
readonly CLOUDFLARE_DNS_COMMENT="easy_all trojan direct node"
readonly LEGO_RELEASE_BASE="https://github.com/go-acme/lego/releases/download"
# Pinned on purpose: the release archive is verified against the checksums file
# published in the same release, so the download stays reproducible.
readonly LEGO_VERSION="v4.35.2"
readonly LEGO_ARCHIVE="lego_${LEGO_VERSION#v}_linux_amd64.tar.gz"
readonly LEGO_CHECKSUMS="lego_${LEGO_VERSION#v}_checksums.txt"
readonly LEGO_TIMEOUT="15m"
readonly STATE_SCHEMA_VERSION="1"
readonly MIN_COMPATIBLE_STATE_VERSION="1"
readonly SITE_DOMAIN_TOKEN="__EASY_ALL_SITE_DOMAIN__"
readonly SITE_INDEX_MARKER="Operational Analytics for Product Teams"
readonly SITE_NAME="Northlake Analytics"

# shellcheck source=lib/runtime-core.sh
EASY_ALL_RUNTIME_LIB_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/runtime-core.sh"

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update
    apt-get -o DPkg::Lock::Timeout=300 upgrade -y
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw \
        fail2ban python3-systemd socat cron iproute2 iputils-ping tzdata \
        systemd-timesyncd tar util-linux nginx
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
        install -m 0644 "${BBR_MODULES_CONFIG}" \
            "${BACKUP_DIR}/pre-install-bbr-module.conf"
    else
        install -m 0600 /dev/null \
            "${BACKUP_DIR}/pre-install-bbr-module.missing"
    fi
    if [[ -f "${IPV6_SYSCTL_CONF}" ]]; then
        install -m 0644 "${IPV6_SYSCTL_CONF}" "${BACKUP_DIR}/pre-install-enable-ipv6.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-enable-ipv6.missing"
    fi
    if command -v crontab >/dev/null 2>&1 \
        && crontab -l >"${BACKUP_DIR}/pre-install-crontab" 2>/dev/null; then
        chmod 0600 "${BACKUP_DIR}/pre-install-crontab"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-crontab.missing"
    fi
    snapshot_tcp_runtime
    INSTALL_ROLLBACK_ON_EXIT=1
}

configure_ipv4_only() {
    [[ -d /proc/sys/net/ipv6 ]] || return 0
    cat >"${RUNTIME_TMP}/enable-ipv6.conf" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    install -m 0644 "${RUNTIME_TMP}/enable-ipv6.conf" "${IPV6_SYSCTL_CONF}"
    sysctl -p "${IPV6_SYSCTL_CONF}" >/dev/null \
        || die "应用全局 IPv4-only 策略失败"
}

initialize_server() {
    ensure_ssh_boot_service
    choose_tcp_acceleration
    info "配置 TCP 加速：${TCP_ACCELERATION}"
    configure_tcp_acceleration
    info "配置每日重启与全局 IPv4-only 网络栈"
    configure_daily_reboot
    configure_ipv4_only
}

validate_protocol() {
    [[ "$1" == "trojan" ]]
}

choose_protocol() {
    local requested=${1:-${PROTOCOL:-}}
    requested=${requested:-trojan}
    case "${requested}" in
    3 | trojan | trojan-direct) PROTOCOL="trojan" ;;
    *) die "不支持的协议：${requested}" ;;
    esac
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 状态文件不存在：${STATE_FILE}"
    unset STATE_VERSION
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" =~ ^[0-9]+$ ]] \
        && ((10#${STATE_VERSION} >= 10#${MIN_COMPATIBLE_STATE_VERSION})) \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；最低兼容版本为 ${MIN_COMPATIBLE_STATE_VERSION}"
    STATE_VERSION="${STATE_SCHEMA_VERSION}"
}

trojan_validate_domain_state() {
    validate_domain "${NODE_HOST:-}" \
        || die "状态文件中的 Trojan 域名无效：${NODE_HOST:-空}"
    [[ "${NODE_HOST}" != *"${SITE_DOMAIN_TOKEN}"* ]] \
        || die "状态文件中的 Trojan 域名无效：${NODE_HOST}"
}

trojan_validate_password_state() {
    [[ "${TROJAN_PASSWORD:-}" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] \
        || die "状态文件中的 Trojan 密码无效"
}

trojan_validate_port_mode_state() {
    case "${TROJAN_PORT_MODE:-}" in
    443 | dynamic) ;;
    *) die "状态文件中的 Trojan 端口模式无效：${TROJAN_PORT_MODE:-空}" ;;
    esac
}

load_state() {
    local variable
    local -a variables=(
        PROTOCOL TCP_ACCELERATION NODE_NAME NODE_HOST TROJAN_PASSWORD TROJAN_PORT_MODE
        TROJAN_ACME_EMAIL CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME TROJAN_DNS_RECORD_ID
        VPS_IP_FAMILY VPS_PUBLIC_IPV6 GOOGLE_EGRESS_MODE GOOGLE_EGRESS_RESOLVED
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    for variable in "${variables[@]}"; do
        printf -v "${variable}" '%s' ""
    done
    if [[ -f "${STATE_FILE}" ]]; then
        source_state_file
    fi
    enforce_ipv4_only_policy
    [[ ! -f "${STATE_FILE}" ]] || validate_protocol "${PROTOCOL:-}" \
        || die "状态协议不是 trojan；请重新安装"
    if [[ -f "${STATE_FILE}" ]]; then
        trojan_validate_domain_state
        trojan_validate_password_state
        trojan_validate_port_mode_state
        [[ -n "${NODE_NAME:-}" ]] || die "状态缺少节点名；请重新安装"
        [[ "${TROJAN_ACME_EMAIL:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
            || die "状态文件中的 ACME 邮箱无效"
        [[ "${CLOUDFLARE_ZONE_ID:-}" =~ ^[0-9A-Fa-f]{32}$ ]] \
            || die "状态缺少有效的 Cloudflare Zone ID；请重新安装"
        validate_domain "${CLOUDFLARE_ZONE_NAME:-}" \
            || die "状态文件中的 Cloudflare Zone 名称无效"
        [[ "${NODE_HOST}" == *".${CLOUDFLARE_ZONE_NAME}" ]] \
            || die "Trojan 域名不属于状态中的 Cloudflare Zone"
        [[ -z "${TROJAN_DNS_RECORD_ID:-}" || "${TROJAN_DNS_RECORD_ID}" =~ ^[0-9A-Fa-f]{32}$ ]] \
            || die "状态文件中的 Cloudflare DNS 记录 ID 无效"
    fi
    TCP_ACCELERATION=$(normalize_tcp_acceleration "${TCP_ACCELERATION:-bbrv3}") \
        || die "状态文件中的 TCP_ACCELERATION 无效"
}

save_state() {
    enforce_ipv4_only_policy
    trojan_validate_domain_state
    trojan_validate_password_state
    trojan_validate_port_mode_state
    [[ "${TROJAN_ACME_EMAIL:-}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
        || die "无法保存无效的 ACME 邮箱"
    [[ "${CLOUDFLARE_ZONE_ID:-}" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "无法保存无效的 Cloudflare Zone ID"
    validate_domain "${CLOUDFLARE_ZONE_NAME:-}" \
        || die "无法保存无效的 Cloudflare Zone 名称"
    TCP_ACCELERATION=$(normalize_tcp_acceleration "${TCP_ACCELERATION:-bbrv3}") \
        || die "无法保存无效的 TCP_ACCELERATION"
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") || die "创建状态暂存文件失败"
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        printf 'PROTOCOL=%q\n' "${PROTOCOL}"
        printf 'TCP_ACCELERATION=%q\n' "${TCP_ACCELERATION}"
        printf 'NODE_NAME=%q\n' "${NODE_NAME}"
        printf 'NODE_HOST=%q\n' "${NODE_HOST}"
        printf 'TROJAN_PASSWORD=%q\n' "${TROJAN_PASSWORD}"
        printf 'TROJAN_PORT_MODE=%q\n' "${TROJAN_PORT_MODE}"
        printf 'TROJAN_ACME_EMAIL=%q\n' "${TROJAN_ACME_EMAIL}"
        printf 'CLOUDFLARE_ZONE_ID=%q\n' "${CLOUDFLARE_ZONE_ID}"
        printf 'CLOUDFLARE_ZONE_NAME=%q\n' "${CLOUDFLARE_ZONE_NAME}"
        printf 'TROJAN_DNS_RECORD_ID=%q\n' "${TROJAN_DNS_RECORD_ID:-}"
        printf 'VPS_IP_FAMILY=%q\n' "${VPS_IP_FAMILY:-ipv4}"
        printf 'VPS_PUBLIC_IPV6=%q\n' "${VPS_PUBLIC_IPV6:-}"
        printf 'GOOGLE_EGRESS_MODE=%q\n' "${GOOGLE_EGRESS_MODE:-ipv4}"
        printf 'GOOGLE_EGRESS_RESOLVED=%q\n' "${GOOGLE_EGRESS_RESOLVED:-ipv4}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}" || die "写入状态暂存文件失败"
    chmod 0600 "${temp}" && mv -f -- "${temp}" "${STATE_FILE}" \
        || die "原子保存状态文件失败：${STATE_FILE}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    load_state
    validate_protocol "${PROTOCOL:-}" || die "状态文件中的 PROTOCOL 无效"
    [[ -n "${NODE_HOST:-}" && -n "${TROJAN_PASSWORD:-}" && -n "${NODE_NAME:-}" ]] \
        || die "Trojan 状态不完整"
}

check_install_conflicts() {
    local port
    for port in "${SERVICE_PORT}" "${NGINX_SITE_PORT}"; do
        if ss -H -ltn "sport = :${port}" 2>/dev/null \
            | awk 'NR {found=1} END {exit !found}'; then
            die "TCP ${port} 已被占用；easy_all 仅支持专用 VPS"
        fi
    done
    [[ ! -f "${NGINX_CONFIG}" ]] \
        || die "检测到既有 ${NGINX_CONFIG}；请先卸载其他 easy_all 模式"
}

# --- Cloudflare DNS -------------------------------------------------------

trojan_cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret \
            "Cloudflare API Token（需 Zone:Read 与 Zone:DNS:Edit；仅当前进程使用）") \
            || die "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
    fi
    [[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
        && "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9._-]+$ ]] \
        || die "CLOUDFLARE_API_TOKEN 格式无效"
}

trojan_cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN
    rm -f -- "${RUNTIME_TMP}/trojan-cloudflare-api-headers"
}

# Read-only access to the persisted DNS token for apply/uninstall, so a renewal
# never has to be retyped. The file is root-only and holds a Zone-scoped token.
trojan_dns_token_from_env() {
    local token
    [[ -s "${LEGO_DNS_ENV}" ]] || return 1
    token=$(sed -n "s/^CLOUDFLARE_DNS_API_TOKEN='\\([A-Za-z0-9._-]*\\)'$/\\1/p" \
        "${LEGO_DNS_ENV}" | head -n 1)
    [[ -n "${token}" ]] || return 1
    printf '%s' "${token}"
}

trojan_cloudflare_api_request() {
    local method=$1 path=$2 payload=${3:-} response headers
    local -a retry_args=(--retry 0)
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "缺少 CLOUDFLARE_API_TOKEN"
    headers="${RUNTIME_TMP}/trojan-cloudflare-api-headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
        "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    case "${method}" in
    GET | HEAD | PUT) retry_args=(--retry 2) ;;
    esac
    if [[ -n "${payload}" ]]; then
        response=$(curl -sS "${retry_args[@]}" --connect-timeout 10 --max-time 45 \
            -X "${method}" -H "@${headers}" --data "${payload}" \
            "${CLOUDFLARE_API_BASE}${path}") \
            || die "Cloudflare API 请求失败：${method} ${path}"
    else
        response=$(curl -sS "${retry_args[@]}" --connect-timeout 10 --max-time 45 \
            -X "${method}" -H "@${headers}" "${CLOUDFLARE_API_BASE}${path}") \
            || die "Cloudflare API 请求失败：${method} ${path}"
    fi
    jq -es 'length == 1 and (.[0] | type == "object" and .success == true)' \
        <<<"${response}" >/dev/null \
        || { jq -c '.errors // .' <<<"${response}" >&2 || true; die "Cloudflare API 返回错误：${method} ${path}"; }
    jq -c '.result' <<<"${response}"
}

trojan_cloudflare_find_parent_zone() {
    local domain=$1 candidate zone
    candidate=${domain}
    while [[ "${candidate}" == *.* ]]; do
        zone=$(trojan_cloudflare_api_request GET \
            "/zones?name=${candidate}&status=active&per_page=50" \
            | jq -r --arg name "${candidate}" \
                '[.[] | select((.name|ascii_downcase)==$name) | .id] | if length == 1 then .[0] else empty end')
        if [[ -n "${zone}" ]]; then printf '%s' "${zone}"; return; fi
        candidate=${candidate#*.}
    done
    die "Cloudflare active Zone 未覆盖 Trojan 域名：${domain}"
}

trojan_cloudflare_record_list() {
    trojan_cloudflare_api_request GET \
        "/zones/$1/dns_records?type=$2&name=$3&per_page=100"
}

# The Trojan endpoint must be reachable directly, so the managed A record is
# always DNS only (proxied=false). Foreign records are never overwritten.
trojan_cloudflare_ensure_dns_a() {
    local type records record="" count id content proxied comment payload
    for type in A AAAA CNAME; do
        records=$(trojan_cloudflare_record_list \
            "${CLOUDFLARE_ZONE_ID}" "${type}" "${NODE_HOST}") \
            || die "读取 Cloudflare ${type} 记录失败"
        count=$(jq -er 'if type == "array" then length else error("expected records array") end' \
            <<<"${records}") || die "Cloudflare ${type} 记录响应无效"
        ((count <= 1)) || die "Cloudflare 中发现多个同名 ${type} 记录，拒绝覆盖"
        if [[ "${type}" != A ]] && ((count > 0)); then
            [[ "${type}" != AAAA ]] \
                || die "${NODE_HOST} 已有 AAAA 记录；easy_all 全局禁用 IPv6，拒绝继续"
            die "${NODE_HOST} 已有 CNAME 记录；Trojan 需要独立的 A 记录，拒绝继续"
        fi
        if [[ "${type}" == A && "${count}" == 1 ]]; then
            record=$(jq -c '.[0]' <<<"${records}")
        fi
    done
    if [[ -n "${record}" ]]; then
        id=$(jq -r '.id' <<<"${record}")
        content=$(jq -r '.content' <<<"${record}")
        proxied=$(jq -r '.proxied' <<<"${record}")
        comment=$(jq -r '.comment // empty' <<<"${record}")
        if [[ "${content}" == "${VPS_PUBLIC_IPV4}" && "${proxied}" == false ]]; then
            TROJAN_DNS_RECORD_ID=${id}
            return 0
        fi
        [[ "${comment}" == "${CLOUDFLARE_DNS_COMMENT}" ]] \
            || die "${NODE_HOST} 的 A 记录不属于 easy_all 或目标不一致；拒绝覆盖"
    fi
    payload=$(jq -cn --arg name "${NODE_HOST}" --arg content "${VPS_PUBLIC_IPV4}" \
        --arg comment "${CLOUDFLARE_DNS_COMMENT}" \
        '{type:"A",name:$name,content:$content,ttl:1,proxied:false,comment:$comment}')
    if [[ -n "${record}" ]]; then
        trojan_cloudflare_api_request PATCH \
            "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" "${payload}" >/dev/null
        TROJAN_DNS_RECORD_ID=${id}
    else
        TROJAN_DNS_RECORD_ID=$(trojan_cloudflare_api_request POST \
            "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${payload}" \
            | jq -r '.id // empty')
        [[ "${TROJAN_DNS_RECORD_ID}" =~ ^[0-9A-Fa-f]{32}$ ]] \
            || die "Cloudflare 未返回新建 A 记录的 ID"
    fi
}

trojan_cloudflare_prepare() {
    local zone
    trojan_cloudflare_collect_api_token
    CLOUDFLARE_ZONE_ID=$(trojan_cloudflare_find_parent_zone "${NODE_HOST}")
    zone=$(trojan_cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}")
    CLOUDFLARE_ZONE_NAME=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    [[ -n "${CLOUDFLARE_ZONE_NAME}" && "${NODE_HOST}" == *".${CLOUDFLARE_ZONE_NAME}" ]] \
        || die "Trojan 域名不属于 Cloudflare Zone"
    VPS_PUBLIC_IPV4=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} \
        || die "无法探测当前 VPS 公网 IPv4"
    validate_ipv4 "${VPS_PUBLIC_IPV4}" || die "VPS_PUBLIC_IPV4 无效：${VPS_PUBLIC_IPV4}"
    trojan_cloudflare_ensure_dns_a
    trojan_cloudflare_validate_public_dns
}

trojan_cloudflare_validate_public_dns() {
    local attempt record resolver answer found=0
    local -a resolvers=("1.1.1.1" "")
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        for resolver in "${resolvers[@]}"; do
            if [[ -n "${resolver}" ]]; then
                answer=$(dig +time=2 +tries=1 +short A "${NODE_HOST}" @"${resolver}" \
                    2>/dev/null || true)
            else
                answer=$(dig +time=2 +tries=1 +short A "${NODE_HOST}" 2>/dev/null || true)
            fi
            found=0
            while IFS= read -r record; do
                validate_ipv4 "${record}" || continue
                found=1
                [[ "${record}" == "${VPS_PUBLIC_IPV4}" ]] \
                    || die "${NODE_HOST} 的 A 记录 ${record} 未指向本机公网 IPv4 ${VPS_PUBLIC_IPV4}"
            done <<<"${answer}"
            [[ "${found}" == "0" ]] || return 0
        done
        sleep 2
    done
    die "${NODE_HOST} 未在 30 秒内解析到 IPv4；请检查 Cloudflare DNS 与域名 NS 是否已生效"
}

trojan_cloudflare_delete_dns_record() {
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${TROJAN_DNS_RECORD_ID:-}" ]] || return 0
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || {
        warn "缺少 CLOUDFLARE_API_TOKEN，跳过删除 Cloudflare A 记录 ${NODE_HOST}"
        return 0
    }
    trojan_cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${TROJAN_DNS_RECORD_ID}" >/dev/null
    success "已删除 easy_all 托管的 Cloudflare A 记录：${NODE_HOST}"
}

# --- ACME / certificate ---------------------------------------------------

write_cloudflare_dns_env() {
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || trojan_cloudflare_collect_api_token
    install -d -m 0700 "${LEGO_DIR}"
    local temp
    temp=$(mktemp "${LEGO_DIR}/cloudflare-dns.env.XXXXXX") \
        || die "创建 Cloudflare DNS 凭据暂存文件失败"
    cleanup_files+=("${temp}")
    printf "CLOUDFLARE_DNS_API_TOKEN='%s'\n" "${CLOUDFLARE_API_TOKEN}" >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${LEGO_DNS_ENV}" \
        || die "保存 Cloudflare DNS 凭据失败"
}

download_lego() {
    local archive checksums dir expected actual
    dir=$(make_temp_dir)
    archive="${dir}/${LEGO_ARCHIVE}"
    checksums="${dir}/${LEGO_CHECKSUMS}"
    info "正在下载 lego ${LEGO_VERSION}（Let's Encrypt 客户端）"
    download_https_file "${LEGO_RELEASE_BASE}/${LEGO_ARCHIVE}" "${archive}" \
        " lego ${LEGO_VERSION}"
    download_https_file "${LEGO_RELEASE_BASE}/${LEGO_CHECKSUMS}" "${checksums}" \
        " lego 校验文件"
    expected=$(awk -v name="${LEGO_ARCHIVE}" '$2 == name {print tolower($1)}' "${checksums}")
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
        || die "lego 校验文件未包含 ${LEGO_ARCHIVE} 的 SHA256"
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ "${expected}" == "${actual}" ]] \
        || die "lego SHA256 校验失败：期望 ${expected}，实际 ${actual}"
    tar -xzf "${archive}" -C "${dir}" lego \
        || die "解压 lego 失败"
    install -d -m 0700 "${LEGO_DIR}"
    install -m 0755 "${dir}/lego" "${LEGO_BIN}"
    printf '%s\n' "${LEGO_VERSION}" >"${LEGO_VERSION_FILE}"
}

ensure_lego() {
    [[ -x "${LEGO_BIN}" && -r "${LEGO_VERSION_FILE}" ]] \
        && [[ "$(<"${LEGO_VERSION_FILE}")" == "${LEGO_VERSION}" ]] \
        && return 0
    download_lego
}

write_certificate_install_hook() {
    install -d -m 0700 "${LEGO_DIR}" "${CERT_DIR}"
    local temp
    temp=$(mktemp "${LEGO_DIR}/install-certificate.XXXXXX") \
        || die "创建证书安装钩子暂存文件失败"
    cleanup_files+=("${temp}")
    cat >"${temp}" <<EOF
#!/bin/sh
set -eu
umask 077
: "\${LEGO_CERT_PATH:?LEGO_CERT_PATH is required}"
: "\${LEGO_CERT_KEY_PATH:?LEGO_CERT_KEY_PATH is required}"
install -m 0600 -- "\${LEGO_CERT_PATH}" "${CERT_FILE}"
install -m 0600 -- "\${LEGO_CERT_KEY_PATH}" "${KEY_FILE}"
if systemctl cat "${XRAY_SERVICE}" >/dev/null 2>&1; then
    systemctl restart "${XRAY_SERVICE}"
fi
EOF
    chmod 0700 "${temp}"
    mv -f -- "${temp}" "${LEGO_INSTALL_HOOK}" \
        || die "安装证书安装钩子失败"
}

lego_certificate_path() {
    printf '%s/%s.crt\n' "${LEGO_CERT_DIR}" "${NODE_HOST}"
}

lego_private_key_path() {
    printf '%s/%s.key\n' "${LEGO_CERT_DIR}" "${NODE_HOST}"
}

certificate_is_current() {
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] || return 1
    openssl x509 -in "${CERT_FILE}" -checkend 2592000 -noout >/dev/null 2>&1 \
        && openssl x509 -in "${CERT_FILE}" -checkhost "${NODE_HOST}" -noout >/dev/null 2>&1 \
        && [[ "$(openssl x509 -in "${CERT_FILE}" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" \
            == "$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null \
            | sha256sum | cut -d' ' -f1)" ]]
}

certificate_fingerprint() {
    openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null \
        || printf 'missing\n'
}

install_certificate_files() {
    local cert key
    cert=$(lego_certificate_path)
    key=$(lego_private_key_path)
    [[ -s "${cert}" && -s "${key}" ]] \
        || die "lego 未生成证书文件：${cert}"
    install -d -m 0700 "${CERT_DIR}"
    install -m 0600 "${cert}" "${CERT_FILE}"
    install -m 0600 "${key}" "${KEY_FILE}"
    certificate_is_current \
        || die "新证书验收失败（域名或私钥不匹配，或有效期不足 30 天）"
}

run_lego() {
    local -a args=(
        --accept-tos
        --email "${TROJAN_ACME_EMAIL}"
        --path "${LEGO_DIR}"
        --key-type ec256
        --dns cloudflare
        --dns.resolvers 1.1.1.1:53
        -d "${NODE_HOST}"
    )
    [[ -s "${LEGO_DNS_ENV}" ]] \
        || die "缺少 Cloudflare DNS 凭据文件：${LEGO_DNS_ENV}"
    (
        set -a
        # shellcheck source=/dev/null
        . "${LEGO_DNS_ENV}"
        set +a
        timeout "${LEGO_TIMEOUT}" "${LEGO_BIN}" "${args[@]}" "$@"
    )
}

issue_trojan_certificate() {
    local force=${1:-0}
    ensure_lego
    write_certificate_install_hook
    if [[ "${force}" != "1" ]] && certificate_is_current; then
        return 0
    fi
    info "正在通过 Cloudflare DNS-01 签发 ${NODE_HOST} 的 Let's Encrypt 证书"
    run_lego run --run-hook "${LEGO_INSTALL_HOOK}" \
        || die "Let's Encrypt 证书签发失败；请检查 DNS-01 记录与 API Token 权限"
    install_certificate_files
    success "证书已签发：${NODE_HOST}"
}

renew_trojan_certificate() {
    local force=${1:-0} before after
    require_root
    collect_installed_state
    begin_quota_maintenance
    ensure_lego
    write_certificate_install_hook
    if [[ "${force}" == "1" ]]; then
        # easy_all renew-cert is the explicit operator action: re-issue instead of
        # waiting for the 30-day renewal window.
        info "强制重新签发证书：${NODE_HOST}"
        issue_trojan_certificate 1
        systemctl restart "${XRAY_SERVICE}" \
            || die "新证书已安装，但无法重启 ${XRAY_SERVICE}"
        end_quota_maintenance
        success "证书已重新签发，Xray 已加载新证书"
        return 0
    fi
    [[ -s "${LEGO_DNS_ENV}" ]] \
        || die "缺少 Cloudflare DNS 凭据文件：${LEGO_DNS_ENV}"
    before=$(certificate_fingerprint)
    info "检查证书续期：${NODE_HOST}"
    run_lego renew --days 30 --renew-hook "${LEGO_INSTALL_HOOK}" \
        || die "证书续期失败；现有证书保持不变"
    after=$(certificate_fingerprint)
    if [[ "${before}" != "${after}" ]]; then
        certificate_is_current || die "续期后的证书验收失败；请检查 ${CERT_FILE}"
        success "证书已续期，Xray 已重启并加载新证书"
    else
        certificate_is_current \
            || die "当前证书即将到期但未续期；请检查 Cloudflare DNS-01 与 API Token"
        info "证书未到续期时间，保持不变"
    fi
    end_quota_maintenance
}

install_certificate_renewal_timer() {
    cat >"${RUNTIME_TMP}/easy_all-cert-renew.service" <<EOF
[Unit]
Description=easy_all Let's Encrypt certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} cert-renew
EOF
    cat >"${RUNTIME_TMP}/easy_all-cert-renew.timer" <<'EOF'
[Unit]
Description=Run easy_all certificate renewal twice a day

[Timer]
OnCalendar=*-*-* 03,15:23:00
RandomizedDelaySec=30m
Persistent=true
Unit=easy_all-cert-renew.service

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-cert-renew.service" "${CERT_RENEW_SERVICE_FILE}"
    install -m 0644 "${RUNTIME_TMP}/easy_all-cert-renew.timer" "${CERT_RENEW_TIMER_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${CERT_RENEW_TIMER}" >/dev/null \
        || die "启用证书续期定时器失败"
}

remove_certificate_renewal_timer() {
    systemctl disable --now "${CERT_RENEW_TIMER}" >/dev/null 2>&1 || true
    systemctl stop "${CERT_RENEW_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${CERT_RENEW_SERVICE_FILE}" "${CERT_RENEW_TIMER_FILE}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

# --- Static fallback site -------------------------------------------------

render_static_site() {
    local source=${SITE_TEMPLATE_DIR} target
    target="${RUNTIME_TMP}/site"
    [[ -d "${source}" ]] || die "缺少静态站点模板：${source}"
    rm -rf -- "${target}"
    install -d -m 0755 "${target}"
    while IFS= read -r file; do
        local relative=${file#"${source}/"}
        install -d -m 0755 "${target}/$(dirname -- "${relative}")"
        sed "s|${SITE_DOMAIN_TOKEN}|${NODE_HOST}|g" "${file}" >"${target}/${relative}" \
            || die "渲染静态站点文件失败：${relative}"
        chmod 0644 "${target}/${relative}"
    done < <(find "${source}" -type f | sort)
    if grep -rqF -e "${SITE_DOMAIN_TOKEN}" "${target}"; then
        die "静态站点模板仍包含未替换的域名占位符"
    fi
    [[ -s "${target}/index.html" ]] || die "静态站点模板缺少 index.html"
    grep -qF -e "${SITE_INDEX_MARKER}" "${target}/index.html" \
        || die "静态站点首页缺少预期内容标记"
}

install_static_site() {
    local stage
    render_static_site
    install -d -m 0755 "${WEB_ROOT}"
    stage=$(mktemp -d "${WEB_ROOT}/.site.stage.XXXXXX") \
        || die "创建静态站点暂存目录失败"
    cleanup_files+=("${stage}")
    cp -a "${RUNTIME_TMP}/site/." "${stage}/" \
        || die "复制静态站点失败"
    # mktemp creates 0700; Nginx runs as www-data and must be able to read the site.
    find "${stage}" -type d -exec chmod 0755 {} +
    find "${stage}" -type f -exec chmod 0644 {} +
    chmod 0755 "${stage}"
    rm -rf -- "${SITE_ROOT}"
    mv "${stage}" "${SITE_ROOT}" || die "发布静态站点失败"
}

write_site_nginx_config() {
    [[ -f "${SITE_ROOT}/index.html" ]] \
        || die "静态站点未就绪：${SITE_ROOT}"
    rm -f -- /etc/nginx/sites-enabled/default
    cat >"${RUNTIME_TMP}/easy_all.conf" <<EOF
# Managed by easy_all: Trojan fallback static site.
# Only Xray may reach this listener; it is never exposed directly.
server {
    listen ${NGINX_SITE_LISTEN} default_server;
    server_name ${NODE_HOST};
    root ${SITE_ROOT};
    index index.html;
    charset utf-8;
    server_tokens off;

    add_header X-Content-Type-Options "nosniff" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;
    add_header X-Frame-Options "SAMEORIGIN" always;

    access_log off;
    error_page 404 /404.html;

    location = /404.html {
        internal;
    }

    location ~* \.(?:css|js|svg|png|jpg|jpeg|gif|ico|webp|woff2?)\$ {
        expires 7d;
        try_files \$uri =404;
    }

    location ^~ /.well-known/ {
        try_files \$uri =404;
    }

    location ~ /\. {
        deny all;
    }

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 回落站点配置校验失败"
    systemctl enable --now nginx >/dev/null || die "启动 Nginx 失败"
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

remove_site_nginx_config() {
    if [[ -f "${NGINX_CONFIG}" ]]; then
        rm -f -- "${NGINX_CONFIG}"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
}

# --- Xray ----------------------------------------------------------------

write_xray_config() {
    local clients outbounds routing sockopt
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] \
        || die "缺少 TLS 证书：${CERT_FILE}"
    outbounds=$(xray_direct_outbounds_json)
    routing=$(xray_direct_routing_json)
    sockopt=$(xray_inbound_sockopt_json)
    install -d -m 0755 "${XRAY_DIR}"
    jq -n \
            --arg password "${TROJAN_PASSWORD}" \
            --arg cert "${CERT_FILE}" \
            --arg key "${KEY_FILE}" \
            --arg xray_asset_dir "${XRAY_DIR}" \
            --argjson fallback_port "${NGINX_SITE_PORT}" \
            --argjson inbound_sockopt "${sockopt}" \
            --argjson managed_outbounds "${outbounds}" \
            --argjson managed_routing "${routing}" '
            {
              log: {loglevel: "warning"},
              env: {XRAY_LOCATION_ASSET: $xray_asset_dir},
              inbounds: [{
                tag: "trojan-in",
                listen: "0.0.0.0",
                port: 443,
                protocol: "trojan",
                settings: {
                  clients: [{password: $password, email: "easy_all.owner"}],
                  fallbacks: [{dest: $fallback_port, xver: 0}]
                },
                streamSettings: {
                  network: "tcp",
                  security: "tls",
                  sockopt: $inbound_sockopt,
                  tlsSettings: {
                    alpn: ["http/1.1"],
                    minVersion: "1.2",
                    certificates: [{certificateFile: $cert, keyFile: $key}]
                  }
                },
                sniffing: {
                  enabled: true,
                  destOverride: ["http", "tls", "quic"],
                  routeOnly: false
                }
              }],
              outbounds: $managed_outbounds,
              routing: $managed_routing
            }' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray ${PROTOCOL} 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

validate_protocol_runtime() {
    local attempt response robots
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${XRAY_SERVICE}" \
            && systemctl is-active --quiet nginx \
            && ss -H -ltn "sport = :${SERVICE_PORT}" 2>/dev/null \
                | awk 'NR {found=1} END {exit !found}' \
            && ss -H -ltn "sport = :${NGINX_SITE_PORT}" 2>/dev/null \
                | awk 'NR {found=1} END {exit !found}'; then
            response=$(curl -fsS --connect-timeout 5 --max-time 20 \
                --resolve "${NODE_HOST}:${SERVICE_PORT}:127.0.0.1" \
                "https://${NODE_HOST}/" 2>/dev/null || true)
            if [[ "${response}" == *"${SITE_INDEX_MARKER}"* ]]; then
                robots=$(curl -fsS --connect-timeout 5 --max-time 20 \
                    --resolve "${NODE_HOST}:${SERVICE_PORT}:127.0.0.1" \
                    "https://${NODE_HOST}/robots.txt" 2>/dev/null || true)
                [[ "${robots}" == *"Sitemap: https://${NODE_HOST}/sitemap.xml"* ]] \
                    || { sleep 2; continue; }
                return 0
            fi
        fi
        sleep 2
    done
    die "Trojan 运行时验收失败：TLS 443 未正确回落到静态站点"
}

# --- UFW and dynamic ports -----------------------------------------------

snapshot_ufw_state() {
    local status
    [[ ! -e "${BACKUP_DIR}/pre-install-ufw.active" \
        && ! -e "${BACKUP_DIR}/pre-install-ufw.inactive" \
        && ! -e "${BACKUP_DIR}/pre-install-ufw.missing" ]] || return 0
    install -d -m 0700 "${BACKUP_DIR}"
    if ! command -v ufw >/dev/null 2>&1; then
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw.missing"
    else
        status=$(LC_ALL=C ufw status 2>&1) \
            || die "读取安装前 UFW 状态失败：${status:-未知错误}"
        case "${status}" in
        *'Status: active'*) install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw.active" ;;
        *'Status: inactive'*) install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw.inactive" ;;
        *) die "无法识别安装前 UFW 状态" ;;
        esac
    fi
    if [[ -f "${UFW_BEFORE_RULES}" ]]; then
        install -m 0600 "${UFW_BEFORE_RULES}" "${BACKUP_DIR}/pre-install-ufw-before.rules"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw-before.missing"
    fi
    if [[ -f "${UFW_BEFORE6_RULES}" ]]; then
        install -m 0600 "${UFW_BEFORE6_RULES}" "${BACKUP_DIR}/pre-install-ufw-before6.rules"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw-before6.missing"
    fi
    if [[ -f "${UFW_DEFAULT_CONFIG}" ]]; then
        install -m 0600 "${UFW_DEFAULT_CONFIG}" "${BACKUP_DIR}/pre-install-ufw-default"
    fi
}

restore_preinstall_firewall() {
    remove_managed_ufw_rules
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" \
            "${UFW_DEFAULT_CONFIG}"
    if [[ -f "${BACKUP_DIR}/pre-install-ufw-before.rules" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-ufw-before.rules" "${UFW_BEFORE_RULES}"
    elif [[ -f "${UFW_BEFORE_RULES}" ]]; then
        awk -v start="${UFW_NAT_START}" -v end="${UFW_NAT_END}" '
            $0 == start {skip=1; next}
            $0 == end {skip=0; next}
            !skip {print}
        ' "${UFW_BEFORE_RULES}" >"${RUNTIME_TMP}/ufw-before-restored.rules"
        install -m 0644 "${RUNTIME_TMP}/ufw-before-restored.rules" "${UFW_BEFORE_RULES}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-ufw-before6.rules" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-ufw-before6.rules" "${UFW_BEFORE6_RULES}"
    elif [[ -f "${UFW_BEFORE6_RULES}" ]]; then
        awk -v start="${UFW_NAT6_START}" -v end="${UFW_NAT6_END}" '
            $0 == start {skip=1; next}
            $0 == end {skip=0; next}
            !skip {print}
        ' "${UFW_BEFORE6_RULES}" >"${RUNTIME_TMP}/ufw-before6-restored.rules"
        install -m 0644 "${RUNTIME_TMP}/ufw-before6-restored.rules" "${UFW_BEFORE6_RULES}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-ufw.active" ]]; then
        ufw --force enable >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-ufw.inactive" \
        || -f "${BACKUP_DIR}/pre-install-ufw.missing" ]]; then
        command -v ufw >/dev/null 2>&1 && ufw --force disable >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1 \
        && LC_ALL=C ufw status numbered 2>/dev/null \
            | awk '/^[[:space:]]*\[/ {found=1} END {exit !found}'; then
        ufw --force enable >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1 || true
    fi
}

restore_preinstall_ipv6() {
    [[ -e "${BACKUP_DIR}/pre-install-enable-ipv6.conf" \
        || -e "${BACKUP_DIR}/pre-install-enable-ipv6.missing" ]] || return 0
    if [[ -f "${BACKUP_DIR}/pre-install-enable-ipv6.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-enable-ipv6.conf" "${IPV6_SYSCTL_CONF}"
    else
        rm -f -- "${IPV6_SYSCTL_CONF}"
    fi
}

filter_dynamic_port_cron() {
    awk -v marker="${CRON_DYNAMIC_PORT_MARKER}" 'index($0, marker) == 0'
}

configure_dynamic_port_rotation() {
    local current job
    current=$(read_root_crontab) || return 1
    if [[ "${TROJAN_PORT_MODE:-}" != "dynamic" ]]; then
        printf '%s\n' "${current}" | filter_dynamic_port_cron | crontab - \
            || die "写入 root crontab 失败"
        return 0
    fi
    job="@reboot \"${COMMAND_PATH}\" rotate-dynamic-ports >/dev/null 2>&1 ${CRON_DYNAMIC_PORT_MARKER}"
    { printf '%s\n' "${current}" | filter_dynamic_port_cron; printf '%s\n' "${job}"; } \
        | crontab - || die "写入 root crontab 失败"
}

remove_dynamic_port_rotation() {
    local current
    current=$(read_root_crontab) || return 1
    printf '%s\n' "${current}" | filter_dynamic_port_cron | crontab - \
        || warn "移除 easy_all 动态端口定时任务失败，请手动检查 root crontab"
}

dynamic_port_rotation_for_now() {
    local day_of_year hour_of_day elapsed_hours
    day_of_year=$(TZ=Asia/Shanghai date +%j)
    hour_of_day=$(TZ=Asia/Shanghai date +%H)
    elapsed_hours=$(( (10#${day_of_year} - 1) * 24 + 10#${hour_of_day} ))
    printf '%s\n' "$((elapsed_hours / DYNAMIC_PORT_ROTATION_HOURS))"
}

dynamic_port_slot_for_now() {
    local requested=${1:-${DYNAMIC_PORT_SLOT:-}}
    local epoch_seconds
    if [[ "${requested}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$((10#${requested} % DYNAMIC_PORTS_PER_HOUR))"
        return 0
    fi
    epoch_seconds=$(TZ=Asia/Shanghai date +%s)
    if [[ "${epoch_seconds}" =~ ^[0-9]+$ ]]; then
        printf '%s\n' "$((10#${epoch_seconds} % DYNAMIC_PORTS_PER_HOUR))"
    else
        printf '0\n'
    fi
}

dynamic_port_for_current_window() {
    local rotation slot offset candidate port ssh_port skip
    rotation=$(dynamic_port_rotation_for_now)
    slot=$(dynamic_port_slot_for_now "${1:-}")
    if declare -F detect_ssh_ports >/dev/null 2>&1; then
        detect_ssh_ports
    else
        SSH_PORTS=${SSH_PORTS:-22}
    fi
    for ((offset = 0; offset < DYNAMIC_PORTS_PER_HOUR; offset++)); do
        candidate=$(( (slot + offset) % DYNAMIC_PORTS_PER_HOUR ))
        port=$((PORT_BASE + rotation * DYNAMIC_PORTS_PER_HOUR + candidate))
        skip=0
        for ssh_port in ${SSH_PORTS}; do
            [[ "${port}" != "${ssh_port}" ]] || skip=1
        done
        if (( skip == 0 )); then
            printf '%s\n' "${port}"
            return 0
        fi
    done
    printf '%s\n' "$((PORT_BASE + rotation * DYNAMIC_PORTS_PER_HOUR + slot))"
}

write_dynamic_nat_rules() {
    local ssh_port
    if declare -F detect_ssh_ports >/dev/null 2>&1; then
        detect_ssh_ports
    else
        SSH_PORTS=${SSH_PORTS:-22}
    fi
    for ssh_port in ${SSH_PORTS}; do
        [[ "${ssh_port}" =~ ^[0-9]+$ ]] || continue
        if (( 10#${ssh_port} >= PORT_BASE && 10#${ssh_port} <= DYNAMIC_PORT_MAX )); then
            printf -- '-A PREROUTING -p tcp --dport %s -j RETURN\n' "${ssh_port}"
        fi
    done
    printf -- '-A PREROUTING -p tcp --dport %s:%s -j REDIRECT --to-ports %s\n' \
        "${PORT_BASE}" "${DYNAMIC_PORT_MAX}" "${SERVICE_PORT}"
}

write_ufw_nat_rules_for_family() {
    local source=$1 restore_command=$2 start=$3 end=$4 enabled=$5 label=$6
    local candidate="${RUNTIME_TMP}/ufw-${label}.rules"
    [[ -f "${source}" ]] || die "UFW ${label} 规则不存在：${source}"
    awk -v start="${start}" -v end="${end}" '
        $0 == start {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "${source}" >"${candidate}"
    if [[ "${enabled}" == "1" ]]; then
        {
            printf '%s\n' "${start}"
            printf '*nat\n'
            printf ':PREROUTING ACCEPT [0:0]\n'
            write_dynamic_nat_rules
            printf 'COMMIT\n'
            printf '%s\n\n' "${end}"
            cat "${candidate}"
        } >"${candidate}.new"
        mv "${candidate}.new" "${candidate}"
    fi
    "${restore_command}" --test <"${candidate}" \
        || die "UFW ${label} NAT 规则校验失败"
    install -m 0644 "${candidate}" "${source}"
}

write_ufw_nat_rules() {
    local dynamic=0
    [[ "${TROJAN_PORT_MODE}" != "dynamic" ]] || dynamic=1
    write_ufw_nat_rules_for_family "${UFW_BEFORE_RULES}" iptables-restore \
        "${UFW_NAT_START}" "${UFW_NAT_END}" "${dynamic}" "IPv4"
    if [[ -f "${UFW_BEFORE6_RULES}" ]] \
        && grep -Fq "${UFW_NAT6_START}" "${UFW_BEFORE6_RULES}"; then
        write_ufw_nat_rules_for_family "${UFW_BEFORE6_RULES}" ip6tables-restore \
            "${UFW_NAT6_START}" "${UFW_NAT6_END}" 0 "IPv6"
    fi
}

configure_ufw() {
    local desired_ports
    ensure_ssh_boot_service
    SSH_PORTS="${EASY_ALL_ADDITIONAL_SSH_PORT}"
    info "UFW 将放行 SSH 端口：${SSH_PORTS}"
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ufw
    fi
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null || die "设置 UFW 默认入站策略失败"
    ufw default allow outgoing >/dev/null || die "设置 UFW 默认出站策略失败"
    ufw default deny routed >/dev/null || die "设置 UFW 默认转发策略失败"
    desired_ports="${SSH_PORTS//,/ } ${SERVICE_PORT}"
    apply_ssh_ufw_policy "${desired_ports}"
    write_ufw_nat_rules
    ufw reload >/dev/null || die "加载 UFW NAT 规则失败"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

# --- Node output ----------------------------------------------------------

build_trojan_link() {
    local port=${1:-443}
    printf 'trojan://%s@%s:%s?security=tls&type=tcp&sni=%s&alpn=http%%2F1.1&fp=chrome&allowInsecure=0#%s' \
        "$(uri_encode "${TROJAN_PASSWORD}")" "${NODE_HOST}" "${port}" \
        "${NODE_HOST}" "$(uri_encode "${NODE_NAME}")"
}

build_mihomo_node() {
    local port=${1:-443}
    jq -nr \
        --arg name "${NODE_NAME}" --arg server "${NODE_HOST}" \
        --arg password "${TROJAN_PASSWORD}" \
        --argjson port "${port}" '
        "  - name: \($name|@json)\n    type: trojan\n    server: \($server|@json)\n    port: \($port)\n" +
        "    password: \($password|@json)\n    network: tcp\n    udp: true\n" +
        "    sni: \($server|@json)\n    alpn:\n      - http/1.1\n" +
        "    skip-cert-verify: false\n    client-fingerprint: chrome\n" +
        "    ip-version: ipv4\n    smux:\n      enabled: false\n"'
}

show_node() {
    local port dynamic_port
    collect_installed_state
    port=${SERVICE_PORT}
    printf '\n协议: %s（TLS + 回落静态站点）\n节点链接:\n%s\n\n' \
        "${PROTOCOL}" "$(build_trojan_link "${port}")"
    if [[ "${TROJAN_PORT_MODE}" == "dynamic" ]]; then
        dynamic_port=$(dynamic_port_for_current_window)
        printf '动态端口: 已开放 TCP %s-%s，全部重定向到 %s（当前时段示例端口 %s）\n' \
            "${PORT_BASE}" "${DYNAMIC_PORT_MAX}" "${SERVICE_PORT}" "${dynamic_port}"
        printf '同一密码下的动态端口示例:\n%s\n\n' "$(build_trojan_link "${dynamic_port}")"
    else
        printf '端口模式: 固定 %s\n\n' "${SERVICE_PORT}"
    fi
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node "${port}"
    printf '\n'
}

show_subscription() {
    collect_installed_state
    show_node
    printf '订阅服务: 未部署\n'
    printf '本模式不提供在线订阅；请将上方节点链接或 Mihomo 片段手工导入客户端。\n'
    printf '需要在线订阅时请改用 Reality 模式的订阅输出。\n\n'
}

show_status() {
    local cert_end cert_subject site_status nat_status
    require_root
    collect_installed_state
    printf '协议: %s\n' "${PROTOCOL}"
    show_tcp_acceleration_status
    printf 'VPS 网络栈: IPv4-only（IPv6 全局禁用）\n'
    printf '域名: %s\n' "${NODE_HOST}"
    printf '节点名: %s\n' "${NODE_NAME}"
    printf '端口模式: %s\n' "${TROJAN_PORT_MODE}"
    if [[ "${TROJAN_PORT_MODE}" == "dynamic" ]]; then
        if grep -Fq "${UFW_NAT_START}" "${UFW_BEFORE_RULES}" 2>/dev/null; then
            nat_status="active（${PORT_BASE}-${DYNAMIC_PORT_MAX} → ${SERVICE_PORT}）"
        else
            nat_status="missing"
        fi
        printf '动态端口 NAT: %s\n' "${nat_status}"
    fi
    cert_subject=$(openssl x509 -in "${CERT_FILE}" -noout -subject 2>/dev/null || printf 'missing\n')
    cert_end=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null || printf 'missing\n')
    printf '证书: %s\n证书到期: %s\n' "${cert_subject#subject=}" "${cert_end#notAfter=}"
    printf '核心服务: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf '回落站点服务: '
    systemctl is-active --quiet nginx 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'TCP %s: ' "${SERVICE_PORT}"
    ss -H -ltn "sport = :${SERVICE_PORT}" 2>/dev/null \
        | awk 'NR {found=1} END {exit !found}' \
        && printf 'listening\n' || printf 'not listening\n'
    site_status=$(curl -fsS --connect-timeout 5 --max-time 15 \
        --resolve "${NODE_HOST}:${SERVICE_PORT}:127.0.0.1" \
        "https://${NODE_HOST}/" 2>/dev/null || true)
    if [[ "${site_status}" == *"${SITE_INDEX_MARKER}"* ]]; then
        printf '回落站点: 200 OK（%s）\n' "${SITE_NAME}"
    else
        printf '回落站点: 不可用\n'
    fi
    printf '证书续期定时器: '
    systemctl is-active --quiet "${CERT_RENEW_TIMER}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
}

# --- Lifecycle ------------------------------------------------------------

stop_protocol_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    remove_site_nginx_config
}

rotate_dynamic_ports() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    if [[ "${TROJAN_PORT_MODE}" != "dynamic" ]]; then
        end_quota_maintenance
        return 0
    fi
    write_ufw_nat_rules
    ufw reload >/dev/null || die "刷新动态端口 NAT 规则失败"
    end_quota_maintenance
    success "动态端口 NAT 已刷新：开放 ${PORT_BASE}-${DYNAMIC_PORT_MAX} 全部转发至 ${SERVICE_PORT}"
}

apply_easy_all() {
    local backup_dir
    require_root
    begin_quota_maintenance
    collect_installed_state
    info "应用 TCP 加速并刷新 TCP 参数"
    configure_tcp_acceleration
    configure_ipv4_only
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(trojan_dns_token_from_env || true)
    fi
    trojan_cloudflare_prepare
    write_cloudflare_dns_env
    backup_dir=$(make_temp_dir)
    [[ ! -f "${XRAY_CONFIG}" ]] || install -m 0600 "${XRAY_CONFIG}" "${backup_dir}/config.json"
    [[ ! -f "${NGINX_CONFIG}" ]] || install -m 0600 "${NGINX_CONFIG}" "${backup_dir}/nginx.conf"
    if ! (
        ensure_lego
        write_certificate_install_hook
        issue_trojan_certificate 0 || exit 1
        install_static_site || exit 1
        write_site_nginx_config || exit 1
        write_xray_config || exit 1
        systemctl restart "${XRAY_SERVICE}" || exit 1
        validate_protocol_runtime || exit 1
    ); then
        warn "新配置验收失败，正在恢复旧配置"
        [[ ! -f "${backup_dir}/config.json" ]] \
            || install -m 0600 "${backup_dir}/config.json" "${XRAY_CONFIG}"
        [[ ! -f "${backup_dir}/nginx.conf" ]] \
            || install -m 0600 "${backup_dir}/nginx.conf" "${NGINX_CONFIG}"
        systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
        systemctl reload nginx >/dev/null 2>&1 || true
        die "本机配置应用失败，已恢复旧配置"
    fi
    configure_ufw
    configure_dynamic_port_rotation
    register_easy_all_command
    save_state
    install_certificate_renewal_timer
    trojan_cloudflare_clear_api_token
    end_quota_maintenance
    show_node
    success "easy_all Trojan 直连本机配置已应用"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数 ${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" || -L "${COMMAND_PATH}" ]] \
        || die "easy_all 尚未安装"
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
    fi
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        if [[ "${mode}" == "--purge-cloud" ]]; then
            read_bilingual \
                "删除本机内容以及 easy_all 托管的 Cloudflare A 记录？[y/N]:" answer
        else
            read_bilingual \
                '删除 easy_all 本机服务、状态与证书（保留 Cloudflare DNS 记录）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
    fi
    if [[ "${mode}" == "--purge-cloud" && -s "${LEGO_DNS_ENV}" ]]; then
        # shellcheck source=/dev/null
        . "${LEGO_DNS_ENV}"
        export CLOUDFLARE_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN:-}"
        trojan_cloudflare_delete_dns_record \
            || die "Cloudflare A 记录删除失败；本机内容未删除"
    elif [[ "${mode}" == "--purge-cloud" ]]; then
        warn "缺少 ${LEGO_DNS_ENV}，无法删除 Cloudflare A 记录 ${NODE_HOST:-}"
    fi
    stop_protocol_services
    remove_certificate_renewal_timer
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_bbr_tcp_install_state
    remove_daily_reboot_schedule
    remove_dynamic_port_rotation
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}" "${WEB_ROOT}"
    if [[ "${mode}" == "--purge-cloud" ]]; then
        success "easy_all 本机内容及托管的 Cloudflare A 记录已卸载"
    else
        success "easy_all 本机内容已卸载；Cloudflare A 记录已保留"
    fi
}

rollback_fresh_install() {
    warn "首次安装失败，正在恢复本机服务、UFW、crontab 与 BBR 配置"
    stop_protocol_services
    remove_certificate_renewal_timer
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_bbr_tcp_install_state 1
    restore_preinstall_crontab
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}" "${WEB_ROOT}"
    warn "首次安装产生的服务数据已清理"
}

# --- Input collection -----------------------------------------------------

collect_trojan_node_name() {
    [[ -n "${NODE_NAME:-}" ]] || {
        if [[ -t 0 ]]; then
            NODE_NAME=$(prompt_value "节点名称" "${DEFAULT_TROJAN_NODE_NAME}")
        else
            NODE_NAME=${DEFAULT_TROJAN_NODE_NAME}
        fi
    }
    [[ -n "${NODE_NAME}" && ${#NODE_NAME} -le 64 ]] \
        || die "节点名称无效：${NODE_NAME}"
}

collect_trojan_domain() {
    local domain=${NODE_HOST:-}
    if [[ -z "${domain}" ]]; then
        [[ -t 0 ]] || die "非交互模式必须设置 NODE_HOST（Trojan 域名）"
        info "Trojan 需要 TLS 证书，因此必须使用指向本机 IPv4 的域名（Cloudflare 托管 Zone，DNS only）"
        domain=$(prompt_value "Trojan 节点域名（例如 node.example.com，不能填 IPv4）" "")
    fi
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "Trojan 节点域名无效：${domain}"
    NODE_HOST=${domain}
}

collect_trojan_acme_email() {
    local email=${TROJAN_ACME_EMAIL:-}
    if [[ -z "${email}" ]]; then
        if [[ -t 0 ]]; then
            email=$(prompt_value "Let's Encrypt 注册邮箱（用于到期提醒）" \
                "admin@${CLOUDFLARE_ZONE_NAME:-example.com}")
        else
            email="admin@${CLOUDFLARE_ZONE_NAME:-example.com}"
        fi
    fi
    [[ "${email}" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] \
        || die "ACME 邮箱无效：${email}"
    TROJAN_ACME_EMAIL=${email}
}

collect_trojan_password() {
    local password=${TROJAN_PASSWORD:-}
    if [[ -z "${password}" && -t 0 ]]; then
        info "直接回车将自动生成 32 位随机密码"
        password=$(prompt_secret "Trojan 密码（8-64 位字母、数字或 . _ ~ -）" || true)
    fi
    if [[ -z "${password}" ]]; then
        password=$(openssl rand -base64 48 \
            | tr -d '=+/\n' | tr -c 'A-Za-z0-9' '-' | cut -c1-32)
    fi
    [[ "${password}" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] \
        || die "Trojan 密码无效：需为 8-64 位字母、数字或 . _ ~ -"
    TROJAN_PASSWORD=${password}
}

collect_trojan_port_mode() {
    local requested=${TROJAN_PORT_MODE:-} default_choice=2
    if [[ -z "${requested}" && -t 0 ]]; then
        printf '请选择端口模式：\n'
        printf '  1. 固定 443\n'
        printf '  2. dynamic（开放 %s-%s，全部重定向到 443，默认）\n' \
            "${PORT_BASE}" "${DYNAMIC_PORT_MAX}"
        read_bilingual "请选择 [${default_choice}]（直接回车使用默认值）:" requested
    fi
    requested=${requested:-${DEFAULT_TROJAN_PORT_MODE}}
    case "${requested}" in
    1 | 443) TROJAN_PORT_MODE="443" ;;
    2 | dynamic) TROJAN_PORT_MODE="dynamic" ;;
    *) die "端口模式无效：${requested}" ;;
    esac
}

collect_trojan_inputs() {
    validate_protocol "${PROTOCOL}"
    collect_trojan_node_name
    collect_trojan_domain
    trojan_cloudflare_prepare
    collect_trojan_acme_email
    collect_trojan_password
    collect_trojan_port_mode
    refresh_google_egress_selection
}

run_trojan_install_pipeline() {
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    info "[1/8] 检查系统"
    check_platform
    choose_protocol "${1:-}"
    check_install_conflicts
    info "[2/8] 安装依赖并初始化服务器"
    snapshot_fresh_install
    install_packages
    initialize_server
    info "[3/8] 收集 Trojan 节点参数"
    collect_trojan_inputs
    info "[4/8] 签发 TLS 证书"
    ensure_lego
    write_certificate_install_hook
    write_cloudflare_dns_env
    issue_trojan_certificate 0
    info "[5/8] 下载并安装 Xray 核心"
    download_xray
    info "[6/8] 部署回落静态站点"
    install_static_site
    write_site_nginx_config
    info "[7/8] 配置 UFW 并启动 Trojan"
    configure_ufw
    write_xray_config
    install_xray_service
    validate_protocol_runtime
    info "[8/8] 保存状态并注册 easy_all 命令"
    save_state
    register_easy_all_command
    configure_dynamic_port_rotation
    install_certificate_renewal_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    trojan_cloudflare_clear_api_token
    show_node
    show_tcp_acceleration_status
    success "easy_all ${PROTOCOL} 安装完成"
    prompt_bbrv3_reboot
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    run_trojan_install_pipeline "${1:-}"
}
