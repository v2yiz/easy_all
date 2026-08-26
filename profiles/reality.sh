#!/usr/bin/env bash

# Standalone installer for VLESS Reality Vision.

set -Eeuo pipefail
umask 077

readonly REALITY_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR="${REALITY_PROFILE_ROOT}/../lib"
readonly SCRIPT_FILE="${REALITY_PROFILE_ROOT}/$(basename -- "${BASH_SOURCE[0]}")"

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
readonly ENTRY_COMMAND_NAME="${EASY_ALL_ENTRY_COMMAND:-easy_all}"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="Xray VLESS Reality managed by easy_all"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly ACME_HOME="/root/.acme-easy_all.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-subscription-nginx.sh"
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
readonly SUBSCRIPTION_HTTPS_PORT="8443"
readonly PORT_BASE="10000"
readonly DYNAMIC_PORT_ROTATION_HOURS="3"
readonly DYNAMIC_PORT_MAX="$((PORT_BASE + 366 * 24 / DYNAMIC_PORT_ROTATION_HOURS - 1))"
readonly DYNAMIC_PORT_RETENTION_DAYS="7"
readonly DYNAMIC_PORT_RETENTION_WINDOWS="$((DYNAMIC_PORT_RETENTION_DAYS * 24 / DYNAMIC_PORT_ROTATION_HOURS))"
readonly DYNAMIC_PORT_TODAY_WINDOWS="$((24 / DYNAMIC_PORT_ROTATION_HOURS))"
readonly DYNAMIC_PORT_NEXT_DAY_WINDOWS="$((6 / DYNAMIC_PORT_ROTATION_HOURS))"
readonly DYNAMIC_PORT_OPEN_WINDOWS="$((DYNAMIC_PORT_RETENTION_WINDOWS + DYNAMIC_PORT_TODAY_WINDOWS + DYNAMIC_PORT_NEXT_DAY_WINDOWS))"
readonly DEFAULT_REALITY_TARGET="swdist.apple.com:443"
readonly DEFAULT_REALITY_PORT_MODE="dynamic"
readonly DEFAULT_REALITY_NODE_NAME="MY_REALITY"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/templates/mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly CRON_DYNAMIC_PORT_MARKER="# easy_all-managed-dynamic-ports"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_ARCHIVE="Xray-linux-64.zip"
readonly XRAY_DGST="Xray-linux-64.zip.dgst"
readonly STATE_SCHEMA_VERSION="5"
readonly RIPE_PREFIX_OVERVIEW_API="https://stat.ripe.net/data/prefix-overview/data.json"
readonly SUBSCRIPTION_DEPLOY_DESCRIPTION="Nginx HTTPS :${SUBSCRIPTION_HTTPS_PORT}"

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
REALITY_CLIENT_IP_FAMILY_RESOLVED=""
cleanup() {
    local path
    if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" \
        && -n "${UPDATE_SUB_BACKUP_DIR:-}" ]]; then
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

validate_ipv6() {
    local ip=${1%%%*} segment rest colons
    [[ -n "${ip}" && ${#ip} -le 39 && "${ip}" == *:* \
        && "${ip}" =~ ^[0-9A-Fa-f:]+$ && "${ip}" != *:::* ]] || return 1
    colons=${ip//[^:]/}
    if [[ "${ip}" == *::* ]]; then
        rest=${ip#*::}
        [[ "${rest}" != *::* ]] || return 1
        ((${#colons} >= 2 && ${#colons} <= 8)) || return 1
    else
        ((${#colons} == 7)) || return 1
    fi
    for segment in ${ip//:/ }; do
        [[ ${#segment} -ge 1 && ${#segment} -le 4 \
            && "${segment}" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    done
}

canonicalize_ipv6() {
    local ip=${1%%%*} canonical=""
    validate_ipv6 "${ip}" || return 1
    if command -v ip >/dev/null 2>&1; then
        canonical=$(ip -6 route get "${ip}" 2>/dev/null \
            | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /:/) {print $i; exit}}' \
            || true)
    fi
    [[ -n "${canonical}" ]] || canonical=${ip}
    tr '[:upper:]' '[:lower:]' <<<"${canonical}" | tr -d '\n'
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw \
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
        install -m 0644 "${BBR_MODULES_CONFIG}" \
            "${BACKUP_DIR}/pre-install-bbr-module.conf"
    else
        install -m 0600 /dev/null \
            "${BACKUP_DIR}/pre-install-bbr-module.missing"
    fi
    if command -v crontab >/dev/null 2>&1 \
        && crontab -l >"${BACKUP_DIR}/pre-install-crontab" 2>/dev/null; then
        chmod 0600 "${BACKUP_DIR}/pre-install-crontab"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-crontab.missing"
    fi
    if [[ -f "${IPV6_SYSCTL_CONF}" ]]; then
        install -m 0644 "${IPV6_SYSCTL_CONF}" "${BACKUP_DIR}/pre-install-enable-ipv6.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-enable-ipv6.missing"
    fi
    snapshot_tcp_runtime
    INSTALL_ROLLBACK_ON_EXIT=1
}

configure_ipv6() {
    [[ -d /proc/sys/net/ipv6 ]] || {
        warn "当前内核未暴露 IPv6，继续 IPv4-only 安装"
        return 0
    }
    cat >"${RUNTIME_TMP}/enable-ipv6.conf" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    install -m 0644 "${RUNTIME_TMP}/enable-ipv6.conf" "${IPV6_SYSCTL_CONF}"
    sysctl -p "${IPV6_SYSCTL_CONF}" >/dev/null \
        || warn "IPv6 sysctl 应用失败，继续 IPv4-only 安装"
}

initialize_server() {
    ensure_ssh_boot_service
    info "配置 XanMod LTS 内核 BBRv3"
    configure_bbr_tcp
    info "配置每日重启与 IPv6"
    configure_daily_reboot
    configure_ipv6
}

refresh_saved_daily_reboot_schedule() {
    if [[ "${SCHEDULED_REBOOT_ENABLED:-0}" == "1" ]]; then
        REBOOT_SCHEDULE_MODE=custom
        REBOOT_HOUR="${SCHEDULED_REBOOT_HOUR}"
    else
        REBOOT_SCHEDULE_MODE=none
        REBOOT_HOUR=""
    fi
    configure_daily_reboot
}

detect_public_ipv6() {
    local service candidate canonical
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 -o addr show scope global 2>/dev/null | grep -q 'inet6 ' || return 1
    ip -6 route show default 2>/dev/null | grep -q '^default' || return 1
    local -a services=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
        "https://ifconfig.co/ip"
    )
    for service in "${services[@]}"; do
        candidate=$(curl -6fsS --noproxy '*' --max-time 10 "${service}" 2>/dev/null \
            | tr -d '[:space:]' || true)
        validate_ipv6 "${candidate}" || continue
        canonical=$(canonicalize_ipv6 "${candidate}") || continue
        printf '%s\n' "${canonical}"
        return 0
    done
    return 1
}

detect_reality_inbound_family() {
    local detected=""
    case "${REALITY_INBOUND_IP_FAMILY:-}" in
    ipv4)
        VPS_PUBLIC_IPV6=""
        info "未启用 Reality IPv6 入站；使用 IPv4 监听"
        return 0
        ;;
    dual)
        detected=${VPS_PUBLIC_IPV6:-$(detect_public_ipv6 || true)}
        validate_ipv6 "${detected}" \
            || die "REALITY_INBOUND_IP_FAMILY=dual 但未检测到可用公网 IPv6"
        VPS_PUBLIC_IPV6=$(canonicalize_ipv6 "${detected}")
        info "已启用 Reality IPv4/IPv6 双栈入站：${VPS_PUBLIC_IPV6}"
        return 0
        ;;
    "") ;;
    *) die "REALITY_INBOUND_IP_FAMILY 必须是 ipv4 或 dual" ;;
    esac

    if [[ -n "${VPS_PUBLIC_IPV6:-}" ]]; then
        validate_ipv6 "${VPS_PUBLIC_IPV6}" \
            || die "VPS_PUBLIC_IPV6 无效：${VPS_PUBLIC_IPV6}"
        detected=$(canonicalize_ipv6 "${VPS_PUBLIC_IPV6}")
    else
        detected=$(detect_public_ipv6 || true)
    fi
    if [[ -n "${detected}" ]]; then
        REALITY_INBOUND_IP_FAMILY="dual"
        VPS_PUBLIC_IPV6=${detected}
        info "检测到公网 IPv6，Reality 将启用 IPv4/IPv6 双栈入站：${VPS_PUBLIC_IPV6}"
    else
        REALITY_INBOUND_IP_FAMILY="ipv4"
        VPS_PUBLIC_IPV6=""
        info "未检测到可用公网 IPv6，Reality 将保持 IPv4 入站"
    fi
}

validate_reality_node_dns() {
    local record canonical expected records="" mismatch=""
    local resolver public_ipv4 answer resolved_ipv4=0
    local -a resolvers=("" "1.1.1.1" "8.8.8.8")
    validate_domain "${NODE_HOST}" || return 0

    public_ipv4=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4 || true)}
    validate_ipv4 "${public_ipv4}" \
        || die "无法探测本机公网 IPv4，不能校验 Reality 节点域名 ${NODE_HOST}"
    VPS_PUBLIC_IPV4=${public_ipv4}
    for resolver in "${resolvers[@]}"; do
        if [[ -n "${resolver}" ]]; then
            answer=$(dig +time=2 +tries=1 +short A "${NODE_HOST}" \
                @"${resolver}" 2>/dev/null) \
                || continue
        else
            answer=$(dig +time=2 +tries=1 +short A "${NODE_HOST}" 2>/dev/null) \
                || continue
        fi
        while IFS= read -r record; do
            validate_ipv4 "${record}" || continue
            resolved_ipv4=1
            [[ "${record}" == "${public_ipv4}" ]] \
                || die "${NODE_HOST} 的 A 记录 ${record} 未指向本机公网 IPv4 ${public_ipv4}"
        done <<<"${answer}"
    done
    [[ "${resolved_ipv4}" == "1" ]] \
        || die "${NODE_HOST} 未通过系统 DNS 或公共 DNS 解析到 IPv4 地址"

    while IFS= read -r record; do
        validate_ipv6 "${record}" || continue
        canonical=$(canonicalize_ipv6 "${record}") || continue
        [[ -z "${records}" ]] || records+=$'\n'
        records+=${canonical}
    done < <(dig +time=2 +tries=1 +short AAAA "${NODE_HOST}" 2>/dev/null || true)

    if [[ -z "${records}" ]]; then
        if [[ "${REALITY_INBOUND_IP_FAMILY}" == "dual" ]]; then
            info "${NODE_HOST} 尚未发布 AAAA；当前可先使用 IPv4，添加 AAAA=${VPS_PUBLIC_IPV6} 后即可双栈连接"
        fi
        return 0
    fi
    [[ "${REALITY_INBOUND_IP_FAMILY}" == "dual" ]] \
        || die "${NODE_HOST} 发布了 AAAA（${records//$'\n'/, }），但服务器没有可用公网 IPv6；请删除 AAAA 或为 VPS 配置 IPv6"
    expected=$(canonicalize_ipv6 "${VPS_PUBLIC_IPV6}")
    while IFS= read -r record; do
        [[ "${record}" == "${expected}" ]] || mismatch=${record}
    done <<<"${records}"
    [[ -z "${mismatch}" ]] \
        || die "${NODE_HOST} 的 AAAA ${mismatch} 未指向本机公网 IPv6 ${expected}"
    success "Reality 域名 AAAA 已匹配本机公网 IPv6：${expected}"
}

resolve_reality_client_ip_family() {
    REALITY_CLIENT_IP_FAMILY_RESOLVED="dual"
}

validate_reality_client_ip_family_runtime() {
    resolve_reality_client_ip_family
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 状态文件不存在：${STATE_FILE}"
    unset STATE_VERSION
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；请重新安装"
}

load_state() {
    local variable env_name state_loaded=0
    local -a variables=(
        PROTOCOL CDN_PROVIDER NODE_NAME NODE_HOST VLESS_UUID REALITY_TARGET
        REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
        REALITY_INBOUND_IP_FAMILY VPS_PUBLIC_IPV6
        SUB_PORT_MODE ALLOWED_TOKENS
        SUBSCRIPTION_MODE SUB_DOWNLOAD_NAME SUBSCRIPTION_DOMAIN
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
    )
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        printf -v "${env_name}" '%s' "${!variable:-}"
        printf -v "${variable}" '%s' ""
    done
    if [[ -f "${STATE_FILE}" ]]; then
        source_state_file
        state_loaded=1
    fi
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        if [[ -n "${!env_name:-}" ]]; then
            printf -v "${variable}" '%s' "${!env_name}"
        fi
        unset "${env_name}"
    done
    REALITY_INBOUND_IP_FAMILY=${REALITY_INBOUND_IP_FAMILY:-ipv4}
    REALITY_CLIENT_IP_FAMILY_RESOLVED="dual"
    CDN_PROVIDER=""
    if [[ "${state_loaded}" == "1" ]]; then
        [[ "${PROTOCOL:-}" == "reality" ]] || die "状态协议不是 reality；请重新安装"
        [[ -n "${SUBSCRIPTION_MODE:-}" ]] || die "状态缺少 SUBSCRIPTION_MODE；请重新安装"
        [[ -n "${SUB_DOWNLOAD_NAME:-}" ]] || die "状态缺少 SUB_DOWNLOAD_NAME；请重新安装"
        [[ "${QUOTA_ENABLED:-}" == "0" || "${QUOTA_ENABLED:-}" == "1" ]] \
            || die "状态缺少有效的 QUOTA_ENABLED；请重新安装"
    fi
    [[ "${REALITY_INBOUND_IP_FAMILY}" == "ipv4" \
        || "${REALITY_INBOUND_IP_FAMILY}" == "dual" ]] \
        || die "状态文件中的 REALITY_INBOUND_IP_FAMILY 无效：${REALITY_INBOUND_IP_FAMILY}"
    if [[ "${REALITY_INBOUND_IP_FAMILY}" == "dual" ]]; then
        validate_ipv6 "${VPS_PUBLIC_IPV6:-}" \
            || die "双栈状态缺少有效的 VPS_PUBLIC_IPV6"
        VPS_PUBLIC_IPV6=$(canonicalize_ipv6 "${VPS_PUBLIC_IPV6}")
    else
        VPS_PUBLIC_IPV6=""
    fi
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-link}") \
        || die "状态文件中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}"
    if [[ -n "${SUBSCRIPTION_DOMAIN:-}" ]]; then
        SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN}")
        validate_domain "${SUBSCRIPTION_DOMAIN}" \
            || die "状态文件中的 SUBSCRIPTION_DOMAIN 无效：${SUBSCRIPTION_DOMAIN}"
    fi
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    [[ -z "${ALLOWED_TOKENS:-}" ]] || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
        || die "状态文件中的 ALLOWED_TOKENS 无效"
    QUOTA_ENABLED=${QUOTA_ENABLED:-0}
    [[ "${QUOTA_ENABLED}" == "0" || "${QUOTA_ENABLED}" == "1" ]] \
        || die "状态文件中的 QUOTA_ENABLED 无效"
    if quota_enabled; then
        validate_user_accounts "${USER_ACCOUNTS:-}" \
            || die "状态文件中的 USER_ACCOUNTS 无效"
        [[ -n "${QUOTA_START_DATE:-}" ]] || die "状态缺少 QUOTA_START_DATE；请重新安装"
        validate_quota_start_date "${QUOTA_START_DATE}" \
            || die "状态文件中的 QUOTA_START_DATE 无效：${QUOTA_START_DATE}"
    else
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
    fi
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX")
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        printf 'PROTOCOL=%q\n' "${PROTOCOL}"
        printf 'CDN_PROVIDER=%q\n' ""
        printf 'NODE_NAME=%q\n' "${NODE_NAME}"
        printf 'NODE_HOST=%q\n' "${NODE_HOST:-}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID:-}"
        printf 'REALITY_TARGET=%q\n' "${REALITY_TARGET:-}"
        printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY:-}"
        printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY:-}"
        printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID:-}"
        printf 'REALITY_INBOUND_IP_FAMILY=%q\n' "${REALITY_INBOUND_IP_FAMILY:-ipv4}"
        printf 'VPS_PUBLIC_IPV6=%q\n' "${VPS_PUBLIC_IPV6:-}"
        printf 'SUB_PORT_MODE=%q\n' "${SUB_PORT_MODE:-$(protocol_default_port_mode)}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'QUOTA_ENABLED=%q\n' "${QUOTA_ENABLED:-0}"
        printf 'USER_ACCOUNTS=%q\n' "${USER_ACCOUNTS:-}"
        printf 'QUOTA_START_DATE=%q\n' "${QUOTA_START_DATE:-}"
        printf 'SUBSCRIPTION_MODE=%q\n' "${SUBSCRIPTION_MODE:-link}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
        printf 'SUBSCRIPTION_DOMAIN=%q\n' "${SUBSCRIPTION_DOMAIN:-}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

validate_protocol() {
    [[ "$1" == "reality" ]]
}

choose_protocol() {
    local requested=${1:-${PROTOCOL:-}}
    requested=${requested:-reality}
    case "${requested}" in
    1 | reality) PROTOCOL="reality" ;;
    vless-xhttp | xhttp | vless-wss | wss)
        die "XHTTP 请通过 easy_all install 交互选择“CDN - XHTTP”"
        ;;
    *) die "不支持的协议：${requested}" ;;
    esac
}

protocol_default_node_name() {
    validate_protocol "${PROTOCOL}" || die "无法确定未知协议的默认节点名：${PROTOCOL:-空}"
    printf '%s' "${DEFAULT_REALITY_NODE_NAME}"
}

protocol_default_port_mode() {
    validate_protocol "${PROTOCOL}" || die "无法确定未知协议的默认订阅端口模式：${PROTOCOL:-空}"
    printf '%s' "${DEFAULT_REALITY_PORT_MODE}"
}

validate_reality_target() {
    local target=$1 host port
    [[ "${target}" == *:* ]] || return 1
    host=${target%:*}
    port=${target##*:}
    validate_domain "${host}" || return 1
    [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

reality_tls_ping_succeeded() {
    awk '
        /Pinging with SNI/ {in_sni=1; next}
        in_sni && /Handshake succeeded/ {handshake=1}
        in_sni && /TLS Version:[[:space:]]*TLS 1\.3/ {tls13=1}
        END {exit !(handshake && tls13)}
    '
}

lookup_ip_asns() {
    local ip=$1 response
    response=$(curl --noproxy '*' -fsS --retry 2 \
        --connect-timeout 5 --max-time 10 --get \
        --data-urlencode "resource=${ip}" "${RIPE_PREFIX_OVERVIEW_API}" \
        2>/dev/null) || return 1
    jq -r '.data.asns // [] | map(tostring) | join(" ")' <<<"${response}"
}

resolve_reality_target_ipv4s() {
    local host=${REALITY_TARGET%:*} record
    while IFS= read -r record; do
        validate_ipv4 "${record}" && printf '%s\n' "${record}"
    done < <(dig +short A "${host}" 2>/dev/null || true)
}

validate_reality_target_asn() {
    local vps_ip vps_asns target_ip target_asns vps_asn target_asn
    local target_asn_summary="" matched=0
    vps_ip=$(detect_public_ipv4 || true)
    [[ -n "${vps_ip}" ]] || {
        warn "无法检测 VPS 公网 IPv4，跳过 Reality 同 ASN 检查"
        return 0
    }
    vps_asns=$(lookup_ip_asns "${vps_ip}" || true)
    [[ -n "${vps_asns}" ]] || {
        warn "无法查询 VPS ASN，跳过 Reality 同 ASN 检查"
        return 0
    }
    while IFS= read -r target_ip; do
        [[ -n "${target_ip}" ]] || continue
        target_asns=$(lookup_ip_asns "${target_ip}" || true)
        [[ -n "${target_asns}" ]] || continue
        [[ -z "${target_asn_summary}" ]] || target_asn_summary+=", "
        target_asn_summary+="${target_ip}=AS${target_asns// /,AS}"
        for vps_asn in ${vps_asns}; do
            for target_asn in ${target_asns}; do
                [[ "${vps_asn}" != "${target_asn}" ]] || matched=1
            done
        done
        [[ "${matched}" != "1" ]] || break
    done < <(resolve_reality_target_ipv4s | head -n 4)
    if [[ "${matched}" == "1" ]]; then
        success "Reality 目标与 VPS 命中同 ASN（AS${vps_asns// /,AS}）"
    elif [[ -n "${target_asn_summary}" ]]; then
        warn "Reality 目标与 VPS 不同 ASN（VPS AS${vps_asns// /,AS}；${target_asn_summary}）；同 ASN 目标的伪装一致性更好"
    else
        warn "无法解析 Reality 目标 IPv4/ASN，跳过同 ASN 检查"
    fi
}

validate_reality_target_runtime() {
    local output
    info "验收 Reality 目标 TLS 1.3：${REALITY_TARGET}"
    output=$(timeout 25 "${XRAY_BIN}" tls ping "${REALITY_TARGET}" 2>&1) \
        || die "Reality 目标不可达或 TLS 探测失败：${REALITY_TARGET}"
    reality_tls_ping_succeeded <<<"${output}" \
        || die "Reality 目标未通过带 SNI 的 TLS 1.3 握手：${REALITY_TARGET}"
    success "Reality 目标已通过带 SNI 的 TLS 1.3 握手"
    validate_reality_target_asn
}

collect_reality_node_host() {
    local detected_ip=""
    [[ -z "${NODE_HOST:-}" ]] || return 0

    if detected_ip=$(detect_public_ipv4); then
        VPS_PUBLIC_IPV4=${detected_ip}
        if [[ -t 0 ]]; then
            info "已自动检测本机公网 IPv4：${detected_ip}；直接回车使用，或输入其他入站 IPv4/灰云域名"
            NODE_HOST=$(prompt_value \
                "Reality 客户端连接地址（公网 IPv4 或 DNS only / 灰云域名）" \
                "${detected_ip}" \
                "Reality client address (public IPv4 or DNS-only / grey-cloud domain)")
        else
            NODE_HOST=${detected_ip}
        fi
        return 0
    fi

    if [[ -t 0 ]]; then
        warn "无法自动检测本机公网 IPv4，请手动填写客户端可连接的入站地址"
        NODE_HOST=$(prompt_value \
            "Reality 客户端连接地址（公网 IPv4 或 DNS only / 灰云域名）" "" \
            "Reality client address (public IPv4 or DNS-only / grey-cloud domain)")
        return 0
    fi
    die "无法自动检测 Reality 节点公网 IPv4；非交互模式请设置 NODE_HOST"
}

collect_reality_target() {
    [[ -z "${REALITY_TARGET:-}" ]] || return 0
    if [[ -t 0 ]]; then
        REALITY_TARGET=$(prompt_value \
            "Reality SNI / 伪装目标（域名:端口）" \
            "${DEFAULT_REALITY_TARGET}" \
            "Reality SNI / camouflage target (domain:port)")
    else
        REALITY_TARGET=${DEFAULT_REALITY_TARGET}
    fi
}

collect_sub_port_mode() {
    local default_mode=${1:-$(protocol_default_port_mode)}
    local requested=${SUB_PORT_MODE:-} default_choice
    case "${default_mode}" in
    443) default_choice=1 ;;
    dynamic) default_choice=2 ;;
    *) die "默认订阅端口模式无效：${default_mode}" ;;
    esac

    if [[ -z "${requested}" && -t 0 ]]; then
        printf '请选择订阅端口模式：\n'
        printf 'Choose the subscription port mode:\n'
        printf '  1. 固定 443\n'
        printf '     Fixed port 443\n'
        printf '  2. dynamic（订阅每 3 小时轮换端口 %s-%s，默认）\n' \
            "${PORT_BASE}" "${DYNAMIC_PORT_MAX}"
        printf '     dynamic (three-hour rotating subscription port %s-%s; default)\n' \
            "${PORT_BASE}" "${DYNAMIC_PORT_MAX}"
        read_bilingual \
            "请选择 [${default_choice}]（直接回车使用默认值）:" \
            "Choose [${default_choice}] (press Enter to use the default):" requested
    fi
    requested=${requested:-${default_mode}}
    case "${requested}" in
    1 | 443) SUB_PORT_MODE="443" ;;
    2 | dynamic) SUB_PORT_MODE="dynamic" ;;
    *) die "SUB_PORT_MODE 无效：${requested}" ;;
    esac
}

collect_subscription_domain() {
    local domain=${SUBSCRIPTION_DOMAIN:-}
    if [[ -z "${domain}" && -t 0 ]]; then
        domain=$(prompt_value "自托管订阅域名（必须直接解析到当前 VPS）" "" \
            "Self-hosted subscription domain (must resolve directly to this VPS)")
    fi
    [[ -n "${domain}" ]] \
        || die "自托管订阅模式必须设置 SUBSCRIPTION_DOMAIN"
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    SUBSCRIPTION_DOMAIN=${domain}
}

collect_reality_inputs() {
    validate_protocol "${PROTOCOL}" || die "PROTOCOL 无效：${PROTOCOL:-空}"
    detect_reality_inbound_family
    NODE_NAME=${NODE_NAME:-$(protocol_default_node_name)}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"
    collect_reality_node_host
    validate_domain "${NODE_HOST}" || validate_ipv4 "${NODE_HOST}" \
        || die "Reality 节点地址无效：${NODE_HOST}"
    validate_reality_node_dns
    validate_reality_client_ip_family_runtime
    collect_reality_target
    validate_reality_target "${REALITY_TARGET}" || die "REALITY_TARGET 无效：${REALITY_TARGET}"
    collect_sub_port_mode
}

check_install_conflicts() {
    if ss -H -ltn "sport = :${SERVICE_PORT}" 2>/dev/null | grep -q .; then
        die "TCP ${SERVICE_PORT} 已被占用；easy_all 仅支持专用 VPS"
    fi
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
    local dynamic=0 dual_dynamic=0
    [[ "${SUB_PORT_MODE}" != "dynamic" ]] || dynamic=1
    [[ "${REALITY_INBOUND_IP_FAMILY:-ipv4}" != "dual" ]] \
        || dual_dynamic=${dynamic}
    write_ufw_nat_rules_for_family "${UFW_BEFORE_RULES}" iptables-restore \
        "${UFW_NAT_START}" "${UFW_NAT_END}" "${dynamic}" "IPv4"
    if [[ "${REALITY_INBOUND_IP_FAMILY:-ipv4}" == "dual" ]]; then
        write_ufw_nat_rules_for_family "${UFW_BEFORE6_RULES}" ip6tables-restore \
            "${UFW_NAT6_START}" "${UFW_NAT6_END}" "${dual_dynamic}" "IPv6"
    elif [[ -f "${UFW_BEFORE6_RULES}" ]] \
        && grep -Fq "${UFW_NAT6_START}" "${UFW_BEFORE6_RULES}"; then
        write_ufw_nat_rules_for_family "${UFW_BEFORE6_RULES}" ip6tables-restore \
            "${UFW_NAT6_START}" "${UFW_NAT6_END}" 0 "IPv6"
    fi
}

filter_dynamic_port_cron() {
    awk -v marker="${CRON_DYNAMIC_PORT_MARKER}" 'index($0, marker) == 0'
}

restore_dynamic_port_rotation_schedule() {
    local snapshot=$1 candidate="${RUNTIME_TMP}/rollback-dynamic-port.cron"
    { crontab -l 2>/dev/null || true; } | filter_dynamic_port_cron >"${candidate}"
    if [[ -f "${snapshot}" ]]; then
        awk -v marker="${CRON_DYNAMIC_PORT_MARKER}" \
            'index($0, marker) != 0' "${snapshot}" >>"${candidate}"
    fi
    crontab "${candidate}" \
        || warn "恢复 easy_all 动态端口定时任务失败，请手动检查 root crontab"
}

configure_dynamic_port_rotation() {
    local job
    { crontab -l 2>/dev/null || true; } | filter_dynamic_port_cron | crontab -
    if [[ "${SUB_PORT_MODE:-}" != "dynamic" ]]; then
        return 0
    fi
    job="1 0 * * * \"${COMMAND_PATH}\" rotate-dynamic-ports >/dev/null 2>&1 ${CRON_DYNAMIC_PORT_MARKER}"
    { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
}

remove_dynamic_port_rotation() {
    { crontab -l 2>/dev/null || true; } | filter_dynamic_port_cron | crontab - \
        || warn "移除 easy_all 动态端口定时任务失败，请手动检查 root crontab"
}

dynamic_port_rotation_for_now() {
    local day_of_year hour_of_day elapsed_hours
    day_of_year=$(TZ=Asia/Shanghai date +%j)
    hour_of_day=$(TZ=Asia/Shanghai date +%H)
    elapsed_hours=$(( (10#${day_of_year} - 1) * 24 + 10#${hour_of_day} ))
    printf '%s\n' "$((elapsed_hours / DYNAMIC_PORT_ROTATION_HOURS))"
}

dynamic_port_for_current_window() {
    local rotation
    rotation=$(dynamic_port_rotation_for_now)
    printf '%s\n' "$((PORT_BASE + rotation))"
}

days_in_year() {
    local year=$1
    if (( year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) )); then
        printf '366\n'
    else
        printf '365\n'
    fi
}

write_dynamic_nat_rules() {
    local day_of_year current_year previous_year previous_year_windows
    local current_year_days today_start_rotation next_day_start_rotation
    local offset rotation port
    day_of_year=$(TZ=Asia/Shanghai date +%j)
    current_year=$(TZ=Asia/Shanghai date +%Y)
    previous_year=$((10#${current_year} - 1))
    previous_year_windows=$(( $(days_in_year "${previous_year}") * 24 / DYNAMIC_PORT_ROTATION_HOURS ))
    current_year_days=$(days_in_year "${current_year}")
    today_start_rotation=$(( (10#${day_of_year} - 1) * DYNAMIC_PORT_TODAY_WINDOWS ))
    if (( 10#${day_of_year} < current_year_days )); then
        next_day_start_rotation=$((today_start_rotation + DYNAMIC_PORT_TODAY_WINDOWS))
    else
        next_day_start_rotation=0
    fi

    for ((offset = 1; offset <= DYNAMIC_PORT_RETENTION_WINDOWS; offset++)); do
        rotation=$((today_start_rotation - offset))
        if (( rotation < 0 )); then
            rotation=$((previous_year_windows + rotation))
        fi
        port=$((PORT_BASE + rotation))
        printf -- '-A PREROUTING -p tcp --dport %s -j REDIRECT --to-ports %s\n' \
            "${port}" "${SERVICE_PORT}"
    done
    for ((offset = 0; offset < DYNAMIC_PORT_TODAY_WINDOWS; offset++)); do
        rotation=$((today_start_rotation + offset))
        port=$((PORT_BASE + rotation))
        printf -- '-A PREROUTING -p tcp --dport %s -j REDIRECT --to-ports %s\n' \
            "${port}" "${SERVICE_PORT}"
    done
    for ((offset = 0; offset < DYNAMIC_PORT_NEXT_DAY_WINDOWS; offset++)); do
        rotation=$((next_day_start_rotation + offset))
        port=$((PORT_BASE + rotation))
        printf -- '-A PREROUTING -p tcp --dport %s -j REDIRECT --to-ports %s\n' \
            "${port}" "${SERVICE_PORT}"
    done
}

enable_ufw_ipv6() {
    local candidate="${RUNTIME_TMP}/ufw-default"
    [[ "${REALITY_INBOUND_IP_FAMILY:-ipv4}" == "dual" ]] || return 0
    [[ -f "${UFW_DEFAULT_CONFIG}" ]] \
        || die "双栈模式缺少 UFW 默认配置：${UFW_DEFAULT_CONFIG}"
    awk '
        BEGIN {updated=0}
        /^IPV6=/ {print "IPV6=yes"; updated=1; next}
        {print}
        END {if (!updated) print "IPV6=yes"}
    ' "${UFW_DEFAULT_CONFIG}" >"${candidate}"
    install -m 0644 "${candidate}" "${UFW_DEFAULT_CONFIG}"
}

configure_ufw() {
    local desired_ports
    ensure_ssh_boot_service
    detect_ssh_ports
    info "UFW 将放行 SSH 端口：${SSH_PORTS}"
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends ufw
    fi
    enable_ufw_ipv6
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    desired_ports="${SSH_PORTS//,/ } ${SERVICE_PORT}"
    if subscription_enabled; then
        desired_ports+=" 80 ${SUBSCRIPTION_HTTPS_PORT}"
    fi
    apply_managed_ufw_tcp_ports "${desired_ports}"
    write_ufw_nat_rules
    ufw reload >/dev/null || die "加载 UFW NAT 规则失败"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

write_xray_config() {
    local clients managed_outbounds managed_routing listen_address="0.0.0.0"
    managed_outbounds=$(xray_direct_outbounds_json)
    managed_routing=$(xray_direct_routing_json)
    [[ "${REALITY_INBOUND_IP_FAMILY:-ipv4}" != "dual" ]] || listen_address="::"
    install -d -m 0755 "${XRAY_DIR}"
    if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
        local pair
        pair=$("${XRAY_BIN}" x25519)
        REALITY_PRIVATE_KEY=$(awk '/PrivateKey/ {print $NF}' <<<"${pair}")
    fi
    REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
    REALITY_PUBLIC_KEY=$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}" \
        | awk '/Password|PublicKey/ {print $NF; exit}')
    [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] \
        || die "生成 Reality X25519 密钥失败"
    [[ "${REALITY_SHORT_ID}" =~ ^[0-9a-fA-F]{2,16}$ ]] \
        || die "Reality Short ID 无效"
    if quota_enabled; then
        clients=$(quota_active_clients_json "xtls-rprx-vision")
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" \
            '[{id:$id,email:"easy_all.owner",flow:"xtls-rprx-vision"}]')
    fi
    jq -n \
            --argjson clients "${clients}" \
            --argjson quota_enabled "$([[ "${QUOTA_ENABLED:-0}" == "1" ]] && printf true || printf false)" \
            --arg target "${REALITY_TARGET}" \
            --arg private_key "${REALITY_PRIVATE_KEY}" \
            --arg short_id "${REALITY_SHORT_ID}" \
            --arg sni "${REALITY_TARGET%:*}" \
            --arg listen_address "${listen_address}" \
            --argjson managed_outbounds "${managed_outbounds}" \
            --argjson managed_routing "${managed_routing}" '
            {
              log: {loglevel: "warning"},
              inbounds: [{
                tag: "vless-reality-in",
                listen: $listen_address,
                port: 443,
                protocol: "vless",
                settings: {
                  clients: $clients,
                  decryption: "none"
                },
                streamSettings: {
                  network: "raw",
                  security: "reality",
                  realitySettings: {
                    show: false,
                    target: $target,
                    xver: 0,
                    serverNames: [$sni],
                    privateKey: $private_key,
                    shortIds: [$short_id]
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
            }
            + (if $quota_enabled then {
                api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]},
                stats:{},
                policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}}
              } else {} end)' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray ${PROTOCOL} 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

uri_encode() {
    jq -nr --arg v "$1" '$v|@uri'
}

build_reality_link() {
    local port=${1:-443}
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${NODE_HOST}" "${port}" "${REALITY_TARGET%:*}" \
        "$(uri_encode "${REALITY_PUBLIC_KEY}")" "$(uri_encode "${REALITY_SHORT_ID}")" \
        "$(uri_encode "${NODE_NAME}")"
}

build_node_link() {
    build_reality_link "${1:-443}"
}

build_mihomo_node() {
    local port=${1:-443}
    resolve_reality_client_ip_family
    jq -nr \
            --arg name "${NODE_NAME}" --arg server "${NODE_HOST}" \
            --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
            --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" \
            --arg ip_version "${REALITY_CLIENT_IP_FAMILY_RESOLVED}" \
            --argjson port "${port}" '
            "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: \($port)\n" +
            "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
            "    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \($sni|@json)\n" +
            "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
            "    client-fingerprint: chrome\n    packet-encoding: xudp\n    ip-version: \($ip_version)\n" +
            "    smux:\n      enabled: false\n"'
}

generate_subscription_port() {
    if [[ "${SUB_PORT_MODE}" == "443" ]]; then
        printf '443\n'
        return 0
    fi
    dynamic_port_for_current_window
}

scheduled_reboot_pre_command() {
    printf '"%s" rotate-dynamic-ports >/dev/null 2>&1' "${COMMAND_PATH}"
}

rotate_dynamic_ports() {
    require_root
    collect_installed_state
    [[ "${SUB_PORT_MODE}" == "dynamic" ]] || return 0
    write_ufw_nat_rules
    ufw reload >/dev/null || die "刷新动态端口 NAT 规则失败"
    success "动态端口 NAT 已刷新：开放 ${DYNAMIC_PORT_OPEN_WINDOWS} 个端口，覆盖最近 ${DYNAMIC_PORT_RETENTION_DAYS} 天并预开放当天及次日凌晨端口"
}

install_subscription_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends nginx cron
    command -v nginx >/dev/null 2>&1 || die "Nginx 安装后不可用"
}

verify_subscription_dns() {
    local public_ip records resolver attempt resolver_ok all_ok last_records=""
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} \
        || die "无法探测当前 VPS 公网 IPv4"
    validate_ipv4 "${public_ip}" || die "VPS_PUBLIC_IPV4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    info "等待 ${SUBSCRIPTION_DOMAIN} 仅解析到当前 VPS ${public_ip}"
    for attempt in {1..60}; do
        all_ok=1
        for resolver in 1.1.1.1 8.8.8.8; do
            records=$(dig +short A "${SUBSCRIPTION_DOMAIN}" @"${resolver}" 2>/dev/null \
                | awk 'NF' | sort -u || true)
            last_records=${records:-未解析}
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
            [[ "${resolver_ok}" == "1" ]] || all_ok=0
        done
        [[ "${all_ok}" == "1" ]] && return 0
        sleep 5
    done
    die "${SUBSCRIPTION_DOMAIN} 未仅解析到 ${public_ip}（最近结果：${last_records}）"
}

write_subscription_web_root() {
    install -d -m 0755 "${WEB_ROOT}/.well-known/acme-challenge"
}

write_subscription_bootstrap_nginx() {
    write_subscription_web_root
    if [[ ! -f "${NGINX_CONFIG}" ]]; then
        ss -H -ltn "sport = :80" 2>/dev/null | grep -q . \
            && die "TCP 80 已被占用，无法申请订阅证书"
        ss -H -ltn "sport = :${SUBSCRIPTION_HTTPS_PORT}" 2>/dev/null | grep -q . \
            && die "TCP ${SUBSCRIPTION_HTTPS_PORT} 已被占用"
    fi
    rm -f -- /etc/nginx/sites-enabled/default
    cat >"${RUNTIME_TMP}/easy_all-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SUBSCRIPTION_DOMAIN};
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
        install -d -m 0700 "${STATE_DIR}"
        install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
        ensure_acme_renewal_setup
        return 0
    fi
    local installer="${RUNTIME_TMP}/get-acme.sh"
    curl -fsSL --retry 3 https://get.acme.sh -o "${installer}" \
        || die "下载 acme.sh 失败"
    sh "${installer}" "email=${ACME_EMAIL:-admin@${SUBSCRIPTION_DOMAIN}}" \
        --home "${ACME_HOME}" || die "安装 acme.sh 失败"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装后不可用"
    install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
    ensure_acme_renewal_setup
}

describe_acme_issue_failure() {
    local log_file=$1 issue_status=$2 retry_hint="" duplicate_set=0
    if grep -Eqi \
        'rate.?limit|rateLimited|too many (certificates|registrations|new orders|failed authorizations)|HTTP[^0-9]*429|status[^0-9]*429|retry after' \
        "${log_file}"; then
        retry_hint=$(grep -Eio 'retry after[^,;]*' "${log_file}" | head -n1 || true)
        grep -Eqi 'exact set of identifiers|duplicate certificate' "${log_file}" \
            && duplicate_set=1
        printf "Let's Encrypt 触发签发限流（acme.sh 返回 %s）。" "${issue_status}"
        [[ -z "${retry_hint}" ]] || printf 'CA 提示：%s。' "${retry_hint}"
        if [[ "${duplicate_set}" == "1" ]]; then
            printf '请等待 CA 指定时间后再试，或改用已解析到本机且未用于该证书集合的全新订阅域名；不要连续重试。'
        else
            printf '请等待 CA 指定时间后再试，不要连续重试；当前限流不应假设换子域名可以绕过。'
        fi
        return 0
    fi
    printf '订阅证书申请失败（acme.sh 返回 %s）；请检查上方 acme.sh 输出、DNS、CAA 和 TCP 80。' \
        "${issue_status}"
}

issue_subscription_certificate() {
    local issue_status=0 issue_log="${RUNTIME_TMP}/acme-issue.log"
    install_acme
    run_acme --set-default-ca --server letsencrypt >/dev/null \
        || die "设置 Let's Encrypt 为默认 CA 失败"
    if run_acme --issue --webroot "${WEB_ROOT}" -d "${SUBSCRIPTION_DOMAIN}" \
        --keylength ec-256 2>&1 | tee "${issue_log}"; then
        issue_status=0
    else
        issue_status=${PIPESTATUS[0]}
    fi
    [[ "${issue_status}" == "0" || "${issue_status}" == "2" ]] \
        || die "$(describe_acme_issue_failure "${issue_log}" "${issue_status}")"
    install -d -m 0700 "${CERT_DIR}" "${COMMAND_INSTALL_DIR}"
    cat >"${RUNTIME_TMP}/reload-subscription-nginx.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx.service >/dev/null 2>&1 || systemctl restart nginx.service
EOF
    install -m 0755 "${RUNTIME_TMP}/reload-subscription-nginx.sh" "${CERT_RELOAD_HOOK}"
    run_acme --install-cert -d "${SUBSCRIPTION_DOMAIN}" --ecc \
        --fullchain-file "${CERT_FILE}" --key-file "${KEY_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}" || die "安装订阅证书失败"
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] || die "订阅证书安装不完整"
}

generate_subscription_files() {
    local base64_file=$1 mihomo_file=$2 node_file port
    ensure_allowed_tokens
    prepare_mihomo_template
    port=$(generate_subscription_port)
    node_file="${RUNTIME_TMP}/subscription-node.yaml"
    build_mihomo_node "${port}" >"${node_file}"
    printf '%s' "$(build_node_link "${port}")" | openssl base64 -A >"${base64_file}"
    printf '\n' >>"${base64_file}"
    resolve_reality_client_ip_family
    render_mihomo_subscription "${MIHOMO_TEMPLATE_FILE}" "${node_file}" "${mihomo_file}" \
        "${NODE_NAME}" "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    printf '%s' "$(<"${base64_file}")" | openssl base64 -d -A \
        | grep -Fq 'security=reality' || die "Base64 订阅内容无效"
    grep -Fq 'reality-opts:' "${mihomo_file}" || die "Mihomo 订阅缺少 Reality 节点"
    grep -Fq 'rules:' "${mihomo_file}" || die "Mihomo 订阅缺少规则"
}

install_static_subscriptions() {
    local base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    local mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"
    local user uuid user_dir
    if quota_enabled; then
        rm -rf -- "${SUBSCRIPTION_DIR}"
        install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
        while IFS=$'\t' read -r user uuid; do
            user_dir="${SUBSCRIPTION_DIR}/${user}"
            (
                VLESS_UUID=${uuid}
                generate_subscription_files "${base64_file}.${user}" "${mihomo_file}.${user}"
            )
            install -d -o root -g www-data -m 0750 "${user_dir}"
            install -o root -g www-data -m 0640 \
                "${base64_file}.${user}" "${user_dir}/base64.txt"
            install -o root -g www-data -m 0640 \
                "${mihomo_file}.${user}" "${user_dir}/mihomo.yaml"
        done < <(jq -r 'to_entries[] | [.key,.value.uuid] | @tsv' <<<"${USER_ACCOUNTS}")
        return 0
    fi
    generate_subscription_files "${base64_file}" "${mihomo_file}"
    rm -rf -- "${SUBSCRIPTION_DIR}"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
}

write_subscription_nginx_config() {
    write_subscription_web_root
    {
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${SUBSCRIPTION_DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 404; }
}

server {
    listen ${SUBSCRIPTION_HTTPS_PORT} ssl http2;
    listen [::]:${SUBSCRIPTION_HTTPS_PORT} ssl http2;
    server_name ${SUBSCRIPTION_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

EOF
        write_subscription_nginx_locations
        cat <<'EOF'
    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 订阅配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

validate_subscription_runtime() {
    local token base64_response mihomo_response
    validate_subscription_token_rejection \
        "${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        "https://${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}/subscribe"
    if quota_enabled; then
        token=$(jq -r 'first(.[].token) // empty' <<<"$(quota_active_accounts_json)")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    fi
    base64_response=$(curl -fsS --noproxy '*' \
        --resolve "${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        --get --data-urlencode "token=${token}" \
        "https://${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}/subscribe") \
        || die "Base64 订阅本机验收失败"
    printf '%s' "${base64_response}" | openssl base64 -d -A \
        | grep -Fq 'security=reality' || die "Base64 订阅响应无效"
    mihomo_response=$(curl -fsS --noproxy '*' \
        --resolve "${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        --get --data-urlencode "token=${token}" --data-urlencode "flag=clash" \
        "https://${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}/subscribe") \
        || die "Mihomo 订阅本机验收失败"
    grep -Fq 'reality-opts:' <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
}

collect_deployed_subscription_inputs() {
    local prompt_options=${1:-1} prompt_download_name=${2:-0}
    collect_subscription_domain
    choose_subscription_download_name "${prompt_download_name}"
    if [[ "${prompt_options}" == "1" ]]; then
        choose_monthly_quota 1
    fi
    quota_enabled || ensure_allowed_tokens
    SUBSCRIPTION_MODE="deploy"
}

collect_link_subscription_inputs() {
    SUBSCRIPTION_MODE="link"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    ALLOWED_TOKENS=""
    choose_monthly_quota 0
}

collect_subscription_inputs() {
    local prompt_options=${1:-1} prompt_download_name=${2:-0}
    choose_subscription_mode
    case "${SUBSCRIPTION_MODE}" in
    deploy)
        collect_deployed_subscription_inputs \
            "${prompt_options}" "${prompt_download_name}"
        ;;
    link) collect_link_subscription_inputs ;;
    *) die "无法收集未知订阅输出方式：${SUBSCRIPTION_MODE:-空}" ;;
    esac
}

deploy_subscription_service() {
    install_subscription_dependencies
    verify_subscription_dns
    write_subscription_bootstrap_nginx
    issue_subscription_certificate
    install_static_subscriptions
    write_subscription_nginx_config
    validate_subscription_runtime
}

remove_subscription_service_runtime() {
    if [[ -f "${NGINX_CONFIG}" || -d "${WEB_ROOT}" ]]; then
        systemctl disable --now nginx >/dev/null 2>&1 || true
        rm -f -- "${NGINX_CONFIG}"
        rm -rf -- "${WEB_ROOT}"
    fi
}

deploy_subscription_output() {
    case "${SUBSCRIPTION_MODE:-}" in
    deploy) deploy_subscription_service ;;
    link) remove_subscription_service_runtime ;;
    *) die "无法部署未知订阅输出方式：${SUBSCRIPTION_MODE:-空}" ;;
    esac
}

renew_subscription_certificate() {
    require_root
    collect_installed_state
    subscription_enabled || die "当前未启用自托管订阅"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 尚未安装"
    run_acme --renew -d "${SUBSCRIPTION_DOMAIN}" --ecc --force \
        || die "订阅证书续期失败"
    "${CERT_RELOAD_HOOK}" || die "续期后重载 Nginx 失败"
    success "订阅证书已续期"
}

snapshot_subscription_update() {
    UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
    install -m 0600 "${STATE_FILE}" "${UPDATE_SUB_BACKUP_DIR}/state.env"
    if [[ -f "${XRAY_CONFIG}" ]]; then
        install -m 0600 "${XRAY_CONFIG}" \
            "${UPDATE_SUB_BACKUP_DIR}/runtime-config.json"
    else
        install -m 0600 /dev/null \
            "${UPDATE_SUB_BACKUP_DIR}/runtime-config.json.missing"
    fi
    if [[ -f "${NGINX_CONFIG}" ]]; then
        install -m 0600 "${NGINX_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/nginx.conf"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/nginx.conf.missing"
    fi
    if [[ -d "${SUBSCRIPTION_DIR}" ]]; then
        install -d -m 0700 "${UPDATE_SUB_BACKUP_DIR}/subscriptions"
        cp -a "${SUBSCRIPTION_DIR}/." "${UPDATE_SUB_BACKUP_DIR}/subscriptions/"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/subscriptions.missing"
    fi
    if [[ -f "${CERT_FILE}" ]]; then
        install -m 0600 "${CERT_FILE}" "${UPDATE_SUB_BACKUP_DIR}/fullchain.pem"
        install -m 0600 "${KEY_FILE}" "${UPDATE_SUB_BACKUP_DIR}/private.key"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/certificate.missing"
    fi
    if [[ -f "${UFW_BEFORE_RULES}" ]]; then
        install -m 0600 "${UFW_BEFORE_RULES}" \
            "${UPDATE_SUB_BACKUP_DIR}/ufw-before.rules"
    else
        install -m 0600 /dev/null \
            "${UPDATE_SUB_BACKUP_DIR}/ufw-before.rules.missing"
    fi
    if [[ -f "${UFW_BEFORE6_RULES}" ]]; then
        install -m 0600 "${UFW_BEFORE6_RULES}" \
            "${UPDATE_SUB_BACKUP_DIR}/ufw-before6.rules"
    else
        install -m 0600 /dev/null \
            "${UPDATE_SUB_BACKUP_DIR}/ufw-before6.rules.missing"
    fi
    if [[ -f "${UFW_DEFAULT_CONFIG}" ]]; then
        install -m 0600 "${UFW_DEFAULT_CONFIG}" \
            "${UPDATE_SUB_BACKUP_DIR}/ufw-default"
    else
        install -m 0600 /dev/null \
            "${UPDATE_SUB_BACKUP_DIR}/ufw-default.missing"
    fi
    { crontab -l 2>/dev/null || true; } \
        >"${UPDATE_SUB_BACKUP_DIR}/root.crontab"
    chmod 0600 "${UPDATE_SUB_BACKUP_DIR}/root.crontab"
    UPDATE_SUB_ROLLBACK_ON_EXIT=1
}

rollback_subscription_update() {
    warn "本机配置更新失败，正在恢复服务端配置、订阅文件、端口模式和 UFW"
    install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/state.env" "${STATE_FILE}"
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/runtime-config.json" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/runtime-config.json" \
            "${XRAY_CONFIG}"
        systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 \
            || warn "恢复订阅更新前 ${XRAY_SERVICE} 失败"
    else
        rm -f -- "${XRAY_CONFIG}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" "${NGINX_CONFIG}"
    else
        rm -f -- "${NGINX_CONFIG}"
    fi
    if [[ -d "${UPDATE_SUB_BACKUP_DIR}/subscriptions" ]]; then
        install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
        cp -a "${UPDATE_SUB_BACKUP_DIR}/subscriptions/." "${SUBSCRIPTION_DIR}/"
    else
        rm -rf -- "${SUBSCRIPTION_DIR}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/fullchain.pem" ]]; then
        install -d -m 0700 "${CERT_DIR}"
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/fullchain.pem" "${CERT_FILE}"
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/private.key" "${KEY_FILE}"
    fi
    if [[ -f "${NGINX_CONFIG}" ]]; then
        systemctl enable --now nginx >/dev/null 2>&1 || true
        systemctl reload nginx >/dev/null 2>&1 || true
    else
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
    [[ ! -f "${UPDATE_SUB_BACKUP_DIR}/ufw-before.rules" ]] \
        || install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/ufw-before.rules" \
            "${UFW_BEFORE_RULES}"
    [[ ! -f "${UPDATE_SUB_BACKUP_DIR}/ufw-before6.rules" ]] \
        || install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/ufw-before6.rules" \
            "${UFW_BEFORE6_RULES}"
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/ufw-default" ]]; then
        install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/ufw-default" \
            "${UFW_DEFAULT_CONFIG}"
    elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/ufw-default.missing" ]]; then
        rm -f -- "${UFW_DEFAULT_CONFIG}"
    fi
    unset SUB_PORT_MODE SUBSCRIPTION_MODE
    source_state_file
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-link}") \
        || die "备份状态中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}"
    restore_dynamic_port_rotation_schedule \
        "${UPDATE_SUB_BACKUP_DIR}/root.crontab"
    configure_ufw || warn "恢复订阅更新前 UFW 失败"
}

update_subscription() {
    local prompt_options=${1:-0}
    local requested_port_mode=${SUB_PORT_MODE:-}
    local requested_download_name=${SUB_DOWNLOAD_NAME:-} stored_port_mode
    local prompt_download_name=0
    require_root
    begin_quota_maintenance
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    stored_port_mode=$(
        unset SUB_PORT_MODE
        source_state_file
        printf '%s' "${SUB_PORT_MODE:-$(protocol_default_port_mode)}"
    )
    collect_installed_state
    refresh_saved_daily_reboot_schedule
    if [[ "${prompt_options}" == "1" ]]; then
        SUB_PORT_MODE=${requested_port_mode}
        collect_sub_port_mode "${stored_port_mode}"
        [[ -n "${requested_download_name}" ]] || prompt_download_name=1
    else
        SUB_PORT_MODE=${requested_port_mode:-${SUB_PORT_MODE:-${stored_port_mode}}}
        [[ "${SUB_PORT_MODE}" == "443" || "${SUB_PORT_MODE}" == "dynamic" ]] \
            || die "SUB_PORT_MODE 无效：${SUB_PORT_MODE}"
    fi
    prepare_mihomo_template
    snapshot_subscription_update
    [[ "${prompt_options}" == "1" ]] && PROMPT_SUBSCRIPTION_MODE=1
    collect_subscription_inputs "${prompt_options}" "${prompt_download_name}"
    PROMPT_SUBSCRIPTION_MODE=0
    if [[ "${SUB_PORT_MODE}" != "${stored_port_mode}" ]]; then
        info "订阅端口模式从 ${stored_port_mode} 切换为 ${SUB_PORT_MODE}，同步更新 UFW"
    fi
    if ! configure_ufw || ! deploy_subscription_output; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        rollback_subscription_update
        end_quota_maintenance
        return 1
    fi
    save_state
    if ! refresh_protocol_runtime_config; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        rollback_subscription_update
        end_quota_maintenance
        return 1
    fi
    configure_dynamic_port_rotation
    install_quota_timer
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
}

apply_easy_all() {
    require_root
    info "安装或验收 XanMod LTS BBRv3，并刷新 TCP 参数"
    configure_bbr_tcp
    register_easy_all_command
    collect_installed_state
    update_subscription
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    load_state
    validate_protocol "${PROTOCOL:-}" || die "状态文件中的 PROTOCOL 无效"
    [[ -n "${NODE_HOST:-}" && -n "${VLESS_UUID:-}" \
        && -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] \
        || die "Reality 状态不完整"
}

refresh_protocol_runtime_config() {
    local backup_dir backup_config
    collect_installed_state
    backup_dir=$(make_temp_dir)
    [[ -f "${XRAY_CONFIG}" ]] || die "当前协议配置不存在：${XRAY_CONFIG}"
    backup_config="${backup_dir}/config.json"
    install -m 0600 "${XRAY_CONFIG}" "${backup_config}"

    if (
        validate_reality_node_dns
        validate_reality_client_ip_family_runtime
        validate_reality_target_runtime
        write_xray_config
        systemctl restart "${XRAY_SERVICE}"
        validate_protocol_runtime
    ); then
        success "${PROTOCOL} 运行时配置已刷新"
        return 0
    fi

    warn "新运行时配置验收失败，正在恢复旧配置"
    install -m 0600 "${backup_config}" "${XRAY_CONFIG}"
    systemctl restart "${XRAY_SERVICE}" \
        || die "恢复旧配置后无法重启 ${XRAY_SERVICE}"
    validate_protocol_runtime
    die "运行时配置更新失败，已恢复旧配置"
}

rebuild_traffic_runtime() {
    local backup
    backup=$(make_temp_dir)
    install -m 0600 "${XRAY_CONFIG}" "${backup}/xray.json"
    install -m 0600 "${NGINX_CONFIG}" "${backup}/nginx.conf"
    if (
        write_xray_config
        write_subscription_nginx_config
        systemctl restart "${XRAY_SERVICE}"
        validate_protocol_runtime
    ); then
        return 0
    fi
    install -m 0600 "${backup}/xray.json" "${XRAY_CONFIG}"
    install -m 0600 "${backup}/nginx.conf" "${NGINX_CONFIG}"
    systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl reload nginx >/dev/null 2>&1 || true
    return 1
}

show_node() {
    collect_installed_state
    printf '\n协议: %s\n节点链接:\n%s\n\n' "${PROTOCOL}" "$(build_node_link)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node
    printf '\n'
}

show_subscription() {
    local user token
    collect_installed_state
    show_node
    printf 'Clash 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
    if subscription_enabled; then
        [[ -n "${ALLOWED_TOKENS:-}" ]] || die "自托管订阅 Token 字典缺失"
        printf '订阅方式: VPS Nginx HTTPS :%s\n' "${SUBSCRIPTION_HTTPS_PORT}"
        printf '\n订阅地址:\n'
        while IFS=$'\t' read -r user token; do
            printf '通用订阅 (%s): https://%s:%s/subscribe?token=%s\n' \
                "${user}" "${SUBSCRIPTION_DOMAIN}" "${SUBSCRIPTION_HTTPS_PORT}" "${token}"
            printf 'Mihomo (%s): https://%s:%s/subscribe?token=%s&flag=clash\n' \
                "${user}" "${SUBSCRIPTION_DOMAIN}" "${SUBSCRIPTION_HTTPS_PORT}" "${token}"
        done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${ALLOWED_TOKENS}")
        printf '\n'
        return 0
    fi
    printf '订阅方式: 未部署，仅输出节点信息\n\n'
}

show_status() {
    require_root
    collect_installed_state
    printf '协议: %s\n' "${PROTOCOL}"
    show_bbrv3_status
    if [[ "${REALITY_INBOUND_IP_FAMILY:-ipv4}" == "dual" ]]; then
        printf 'Reality 入站族: IPv4 + IPv6（%s）\n' "${VPS_PUBLIC_IPV6}"
    else
        printf 'Reality 入站族: IPv4\n'
    fi
    resolve_reality_client_ip_family
    printf 'Reality 客户端节点族: %s（自动双栈）\n' \
        "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    printf '节点: %s\nReality 目标: %s\n' "${NODE_HOST}" "${REALITY_TARGET}"
    printf '核心服务: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'TCP 443: '
    ss -H -ltn "sport = :443" 2>/dev/null | grep -q . && printf 'listening\n' || printf 'not listening\n'
    if subscription_enabled; then
        printf '自托管订阅: https://%s:%s/subscribe\n' \
            "${SUBSCRIPTION_DOMAIN}" "${SUBSCRIPTION_HTTPS_PORT}"
        printf 'Nginx: '
        systemctl is-active --quiet nginx 2>/dev/null \
            && printf 'active\n' || printf 'inactive\n'
    else
        printf '订阅服务: disabled（仅节点）\n'
    fi
    show_quota_status
}

stop_protocol_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    if [[ -f "${NGINX_CONFIG}" ]]; then
        rm -f -- "${NGINX_CONFIG}"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 || true
    fi
}

remove_managed_acme_domain() {
    [[ -n "${1:-}" && -x "${ACME_BIN}" ]] || return 0
    if [[ "${PRESERVE_ACME:-0}" == "1" ]]; then
        warn "已按 PRESERVE_ACME=1 保留 ${ACME_HOME}，同域名重装可复用 ACME 账户和证书"
        return 0
    fi
    run_acme --remove -d "$1" --ecc >/dev/null 2>&1 || true
    rm -rf -- "${ACME_HOME:?}/$1" "${ACME_HOME:?}/${1}_ecc"
    if [[ -f "${ACME_OWNERSHIP_MARKER}" ]]; then
        rm -rf -- "${ACME_HOME}"
    fi
}

restore_preinstall_firewall() {
    remove_managed_ufw_rules
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" \
            "${UFW_DEFAULT_CONFIG}"
    if [[ -f "${BACKUP_DIR}/pre-install-ufw-before.rules" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-ufw-before.rules" \
            "${UFW_BEFORE_RULES}"
    elif [[ -f "${UFW_BEFORE_RULES}" ]]; then
        awk -v start="${UFW_NAT_START}" -v end="${UFW_NAT_END}" '
            $0 == start {skip=1; next}
            $0 == end {skip=0; next}
            !skip {print}
        ' "${UFW_BEFORE_RULES}" >"${RUNTIME_TMP}/ufw-before-restored.rules"
        install -m 0644 "${RUNTIME_TMP}/ufw-before-restored.rules" \
            "${UFW_BEFORE_RULES}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-ufw-before6.rules" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-ufw-before6.rules" \
            "${UFW_BEFORE6_RULES}"
    elif [[ -f "${UFW_BEFORE6_RULES}" ]]; then
        awk -v start="${UFW_NAT6_START}" -v end="${UFW_NAT6_END}" '
            $0 == start {skip=1; next}
            $0 == end {skip=0; next}
            !skip {print}
        ' "${UFW_BEFORE6_RULES}" >"${RUNTIME_TMP}/ufw-before6-restored.rules"
        install -m 0644 "${RUNTIME_TMP}/ufw-before6-restored.rules" \
            "${UFW_BEFORE6_RULES}"
    fi
    if command -v ufw >/dev/null 2>&1 \
        && LC_ALL=C ufw status numbered 2>/dev/null | grep -q '^[[:space:]]*\['; then
        ufw --force enable >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-ufw.active" ]]; then
        ufw --force enable >/dev/null 2>&1 || true
    elif command -v ufw >/dev/null 2>&1; then
        ufw --force disable >/dev/null 2>&1 || true
    fi
    command -v ufw >/dev/null 2>&1 && ufw reload >/dev/null 2>&1 || true
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

uninstall_all() {
    local mode=${1:-}
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge" ]] \
        || die "uninstall 不支持参数 ${mode}；当前默认即为 purge"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" || -L "${COMMAND_PATH}" ]] \
        || die "easy_all 尚未安装"
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
    fi
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        local answer
        read_bilingual \
            '确认彻底删除 easy_all 本机服务、状态和备份？[y/N]（直接回车取消）:' \
            'Delete all easy_all local services, state and backups? [y/N] (press Enter to cancel):' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_protocol_services
    remove_quota_timer
    restore_preinstall_firewall
    restore_preinstall_ipv6
    remove_daily_reboot_schedule
    remove_dynamic_port_rotation
    remove_managed_acme_domain "${SUBSCRIPTION_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}" "${WEB_ROOT}"
    success "easy_all 已彻底卸载"
}

rollback_fresh_install() {
    warn "首次安装失败，正在恢复本机服务、UFW、crontab 与 BBR 配置"
    stop_protocol_services
    remove_quota_timer
    restore_preinstall_firewall
    restore_preinstall_ipv6
    if [[ -f "${BACKUP_DIR}/pre-install-bbr.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr.conf" "${SYSCTL_CONFIG}"
        sysctl -p "${SYSCTL_CONFIG}" >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr.missing" ]]; then
        rm -f -- "${SYSCTL_CONFIG}"
    fi
    restore_tcp_runtime
    if [[ -f "${BACKUP_DIR}/pre-install-bbr-module.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr-module.conf" \
            "${BBR_MODULES_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr-module.missing" ]]; then
        rm -f -- "${BBR_MODULES_CONFIG}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-crontab" ]]; then
        crontab "${BACKUP_DIR}/pre-install-crontab" >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-crontab.missing" ]]; then
        crontab -r >/dev/null 2>&1 || true
    fi
    remove_managed_acme_domain "${SUBSCRIPTION_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}" "${WEB_ROOT}"
    warn "首次安装产生的服务数据已清理；系统软件包和已安装内核不会降级"
}

prepare_protocol_assets() {
    download_xray
    validate_reality_target_runtime
}

install_protocol_runtime() {
    write_xray_config
    install_xray_service
}

validate_protocol_runtime() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if ss -H -ltn "sport = :443" 2>/dev/null | grep -q . \
            && systemctl is-active --quiet "${XRAY_SERVICE}"; then
            validate_quota_api
            return 0
        fi
        sleep 2
    done
    die "${PROTOCOL} 服务启动验收失败"
}

run_reality_install_pipeline() {
    local requested=${1:-} prompt_download_name=${2:-0}
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    info "[1/9] 检查系统"
    check_platform
    choose_protocol "${requested}"
    check_install_conflicts
    info "[2/9] 安装依赖并初始化服务器"
    snapshot_fresh_install
    install_packages
    initialize_server
    info "[3/9] 收集 Reality 节点参数"
    collect_reality_inputs
    info "[4/9] 选择并收集订阅输出参数"
    collect_subscription_inputs 1 "${prompt_download_name}"
    info "[5/9] 准备核心"
    prepare_protocol_assets
    info "[6/9] 配置 UFW"
    configure_ufw
    info "[7/9] 安装并启动 ${PROTOCOL}"
    install_protocol_runtime
    validate_protocol_runtime
    info "[8/9] 应用订阅输出配置"
    deploy_subscription_output
    info "[9/9] 保存状态并注册 easy_all 命令"
    save_state
    register_easy_all_command
    configure_dynamic_port_rotation
    install_quota_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    show_subscription
    show_bbrv3_status
    success "easy_all ${PROTOCOL} 安装完成"
}

install_all() {
    local requested=${1:-} prompt_download_name=0
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    [[ -n "${SUB_DOWNLOAD_NAME:-}" ]] || prompt_download_name=1
    run_reality_install_pipeline "${requested}" "${prompt_download_name}"
}

usage() {
    cat <<EOF
用法: $0 [命令]

  install       交互安装 VLESS Reality Vision
  show          显示当前协议节点和 Mihomo 节点
  subscription  显示节点与订阅信息
  self-update   只更新 easy_all 项目代码，不刷新部署
  apply         将已安装代码应用到服务端与当前订阅模式
  update-sub    选择部署订阅服务或仅输出节点
  update-core   更新 Xray 核心
  renew-cert    强制续期自托管订阅证书
  rotate-dynamic-ports  刷新动态端口的最近 7 天 NAT 保留窗口（内部任务）
  quota-status  显示每个用户的本月流量与配额状态
  quota-set     修改指定用户的月度额度
  quota-reset   清零指定用户的本月已用量
  status        显示当前协议、服务、端口和订阅状态
  uninstall     默认彻底删除所有 easy_all 本机数据
  help          显示帮助

Reality 默认使用 dynamic 订阅端口。
订阅仅支持 deploy 与 link 两种选择。
EOF
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/core-backup" backup_version="${RUNTIME_TMP}/version-backup"
    require_root
    begin_quota_maintenance
    collect_installed_state
    install -m 0755 "${XRAY_BIN}" "${backup_bin}"
    [[ ! -f "${XRAY_DIR}/version" ]] \
        || install -m 0644 "${XRAY_DIR}/version" "${backup_version}"
    if (
        download_xray
        systemctl restart "${XRAY_SERVICE}"
        validate_protocol_runtime
    ); then
        end_quota_maintenance
        success "${PROTOCOL} 核心已更新"
        return 0
    fi
    warn "新核心验收失败，正在恢复旧版本"
    install -m 0755 "${backup_bin}" "${XRAY_BIN}"
    [[ ! -f "${backup_version}" ]] \
        || install -m 0644 "${backup_version}" "${XRAY_DIR}/version"
    systemctl restart "${XRAY_SERVICE}"
    validate_protocol_runtime
    die "核心更新失败，已恢复旧版本"
}

main() {
    case "${1:-install}" in
    install) install_all "${2:-${PROTOCOL:-}}" ;;
    show) require_root; show_node ;;
    subscription) require_root; show_subscription ;;
    apply) apply_easy_all ;;
    update-sub) update_subscription 1 ;;
    update-core) update_current_core ;;
    renew-cert) renew_subscription_certificate ;;
    rotate-dynamic-ports) rotate_dynamic_ports ;;
    quota-sync) quota_sync_usage ;;
    quota-status) require_root; collect_installed_state; show_quota_status ;;
    quota-set) shift; quota_set_user "$@" ;;
    quota-reset) shift; quota_reset_user "$@" ;;
    status) show_status ;;
    register-command) register_easy_all_command ;;
    uninstall) uninstall_all "${2:-}" ;;
    help | -h | --help) usage ;;
    *) usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
