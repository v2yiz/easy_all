#!/usr/bin/env bash

# VLESS Reality Vision profile for the unified easy_all launcher.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'reality.sh 是 easy_all 的 Reality Profile；请使用：easy_all install\n' >&2
    exit 2
fi

readonly REALITY_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR="${REALITY_PROFILE_ROOT}/../lib"

readonly STATE_DIR="/etc/easy_all"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly MIHOMO_TEMPLATE_SNAPSHOT_FILE="${MIHOMO_TEMPLATE_SNAPSHOT_FILE_OVERRIDE:-${STATE_DIR}/mihomo-template.yaml}"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly WEB_ROOT="/var/www/easy_all"
readonly SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
readonly SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.port-template"
readonly SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.port-template"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly ENTRY_COMMAND_NAME="${EASY_ALL_ENTRY_COMMAND:-easy_all}"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="Xray VLESS Reality managed by easy_all"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly REALITY_SUBSCRIPTION_JS="/etc/nginx/easy_all-reality-subscription.js"
readonly CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
readonly CLOUDFLARE_ORIGIN_IPS_FILE="${STATE_DIR}/cloudflare-origin-ipv4.txt"
readonly CLOUDFLARE_SUBSCRIPTION_UFW_COMMENT="easy_all-reality-cloudflare-subscription"
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
readonly DYNAMIC_PORTS_PER_HOUR="6"
readonly DYNAMIC_PORT_ROTATION_HOURS="1"
readonly DYNAMIC_PORT_MAX="$((PORT_BASE + 366 * 24 * DYNAMIC_PORTS_PER_HOUR - 1))"
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
readonly STATE_SCHEMA_VERSION="8"
readonly MIN_COMPATIBLE_STATE_VERSION="6"
readonly RIPE_PREFIX_OVERVIEW_API="https://stat.ripe.net/data/prefix-overview/data.json"
readonly SUBSCRIPTION_DEPLOY_DESCRIPTION="Nginx HTTPS :${SUBSCRIPTION_HTTPS_PORT}"
readonly SUBSCRIPTION_AGGREGATION_DESCRIPTION="Cloudflare Worker 下发；Nginx 仅作私有节点源"
readonly SUBSCRIPTION_AGGREGATION_ENABLED=1
readonly SUBSCRIPTION_DEFAULT_MODE="link"
readonly DEFAULT_CLOUDFLARE_WORKER_NAME="easyall-reality"
readonly CLOUDFLARE_WORKER_COMPATIBILITY_DATE="2026-09-09"
readonly CLOUDFLARE_WORKER_SOURCE_HEADER="X-Easy-All-Worker-Source"
readonly CLOUDFLARE_WORKER_SOURCE_FILE="${REALITY_PROFILE_ROOT}/../worker-src/index.js"
readonly CLOUDFLARE_WORKER_BUILD_SCRIPT="${REALITY_PROFILE_ROOT}/../scripts/build-worker.mjs"
readonly CLOUDFLARE_WORKER_BUILD_FILE="${CLOUDFLARE_WORKER_BUILD_FILE_OVERRIDE:-${STATE_DIR}/worker.js}"
readonly CLOUDFLARE_WORKER_READY_ATTEMPTS="${CLOUDFLARE_WORKER_READY_ATTEMPTS_OVERRIDE:-30}"
readonly CLOUDFLARE_WORKER_READY_INTERVAL="${CLOUDFLARE_WORKER_READY_INTERVAL_OVERRIDE:-5}"

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

validate_reality_node_dns() {
    local record records=""
    local resolver public_ipv4 answer resolved_ipv4=0
    local -a resolvers=("" "1.1.1.1" "8.8.8.8")
    validate_ipv4 "${NODE_HOST}" && return 0
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
        [[ -z "${records}" ]] || records+=$'\n'
        records+=${record}
    done < <(dig +time=2 +tries=1 +short AAAA "${NODE_HOST}" \
        @1.1.1.1 2>/dev/null || true)

    [[ -z "${records}" ]] \
        || die "${NODE_HOST} 发布了 AAAA（${records//$'\n'/, }）；easy_all 全局禁用 IPv6，请删除全部 AAAA"
}

resolve_reality_client_ip_family() {
    REALITY_CLIENT_IP_FAMILY_RESOLVED="ipv4"
}

validate_reality_client_ip_family_runtime() {
    resolve_reality_client_ip_family
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 状态文件不存在：${STATE_FILE}"
    unset STATE_VERSION
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" =~ ^[0-9]+$ ]] \
        && ((10#${STATE_VERSION} >= 10#${MIN_COMPATIBLE_STATE_VERSION})) \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；最低兼容版本为 ${MIN_COMPATIBLE_STATE_VERSION}"
    if ((10#${STATE_VERSION} < 10#${STATE_SCHEMA_VERSION})); then
        GOOGLE_EGRESS_MODE="ipv4"
        GOOGLE_EGRESS_RESOLVED="ipv4"
        VPS_IP_FAMILY="ipv4"
        VPS_PUBLIC_IPV6=""
        STATE_VERSION="${STATE_SCHEMA_VERSION}"
    fi
}

resolve_persisted_mihomo_template() {
    MIHOMO_TEMPLATE_SNAPSHOT=${MIHOMO_TEMPLATE_SNAPSHOT:-0}
    [[ "${MIHOMO_TEMPLATE_SNAPSHOT}" == "1" ]] || return 0
    if [[ -r "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" && -s "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" ]]; then
        # Only preselect the persisted file: an explicit MIHOMO_TEMPLATE_SOURCE in this
        # process still wins, and validation stays mandatory in prepare_mihomo_template.
        MIHOMO_TEMPLATE_FILE=${MIHOMO_TEMPLATE_SNAPSHOT_FILE}
        MIHOMO_TEMPLATE_TRUSTED=1
        return 0
    fi
    MIHOMO_TEMPLATE_SNAPSHOT=0
    MIHOMO_TEMPLATE_FILE=""
}

persist_mihomo_template_snapshot() {
    local temp
    [[ -n "${MIHOMO_TEMPLATE_FILE:-}" && -s "${MIHOMO_TEMPLATE_FILE}" ]] \
        || die "缺少待持久化的 Mihomo 模板"
    install -d -m 0700 "${STATE_DIR}" || die "创建状态目录失败"
    if [[ -s "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" ]] \
        && cmp -s "${MIHOMO_TEMPLATE_FILE}" "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}"; then
        MIHOMO_TEMPLATE_FILE=${MIHOMO_TEMPLATE_SNAPSHOT_FILE}
    else
        temp=$(mktemp "${STATE_DIR}/mihomo-template.yaml.XXXXXX") \
            || die "创建 Mihomo 模板快照暂存文件失败"
        cleanup_files+=("${temp}")
        install -m 0600 "${MIHOMO_TEMPLATE_FILE}" "${temp}" \
            || die "复制 Mihomo 模板快照失败"
        mv -f -- "${temp}" "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" \
            || die "原子替换 Mihomo 模板快照失败"
        MIHOMO_TEMPLATE_FILE=${MIHOMO_TEMPLATE_SNAPSHOT_FILE}
    fi
    MIHOMO_TEMPLATE_SNAPSHOT=1
    MIHOMO_TEMPLATE_TRUSTED=1
    MIHOMO_TEMPLATE_PREPARED=1
}

load_state() {
    local variable env_name state_loaded=0 reload=0
    if [[ "${1:-}" == "--reload" ]]; then
        # --reload 读取磁盘真值：不回填调用方当前值，否则拿不到已变更的持久化身份。
        reload=1
    elif (($# > 0)); then
        die "load_state 不支持参数：$1"
    fi
    local -a variables=(
        PROTOCOL CDN_PROVIDER TCP_ACCELERATION NODE_NAME NODE_HOST VLESS_UUID REALITY_TARGET
        REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
        VPS_IP_FAMILY VPS_PUBLIC_IPV6
        GOOGLE_EGRESS_MODE GOOGLE_EGRESS_RESOLVED
        SUB_PORT_MODE ALLOWED_TOKENS
        SUBSCRIPTION_MODE SUB_DOWNLOAD_NAME SUBSCRIPTION_DOMAIN SUB_SOURCE_DOMAIN
        CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME CLOUDFLARE_ACCOUNT_ID
        CLOUDFLARE_ORIGIN_CERT_ID
        CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON CLOUDFLARE_STRICT_RULESET_ID
        CLOUDFLARE_WORKER_NAME CLOUDFLARE_WORKER_DOMAIN_ID
        WORKER_SOURCE_SECRET WORKER_AGGREGATION_CONFIG
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
        MIHOMO_TEMPLATE_SNAPSHOT
    )
    for variable in "${variables[@]}"; do
        if [[ "${reload}" != "1" ]]; then
            env_name="EASY_ALL_ENV_${variable}"
            printf -v "${env_name}" '%s' "${!variable:-}"
        fi
        printf -v "${variable}" '%s' ""
    done
    if [[ -f "${STATE_FILE}" ]]; then
        source_state_file
        state_loaded=1
    fi
    if [[ "${reload}" != "1" ]]; then
        for variable in "${variables[@]}"; do
            env_name="EASY_ALL_ENV_${variable}"
            if [[ -n "${!env_name:-}" ]]; then
                printf -v "${variable}" '%s' "${!env_name}"
            fi
            unset "${env_name}"
        done
    fi
    resolve_persisted_mihomo_template
    CDN_PROVIDER=""
    TCP_ACCELERATION=$(normalize_tcp_acceleration "${TCP_ACCELERATION:-bbrv3}") \
        || die "状态文件中的 TCP_ACCELERATION 无效"
    enforce_ipv4_only_policy
    if [[ "${state_loaded}" == "1" ]]; then
        [[ "${PROTOCOL:-}" == "reality" ]] || die "状态协议不是 reality；请重新安装"
        [[ -n "${SUBSCRIPTION_MODE:-}" ]] || die "状态缺少 SUBSCRIPTION_MODE；请重新安装"
        [[ -n "${SUB_DOWNLOAD_NAME:-}" ]] || die "状态缺少 SUB_DOWNLOAD_NAME；请重新安装"
        [[ "${QUOTA_ENABLED:-}" == "0" || "${QUOTA_ENABLED:-}" == "1" ]] \
            || die "状态缺少有效的 QUOTA_ENABLED；请重新安装"
        validate_google_egress_policy_state \
            || die "状态缺少有效的 Google 出站策略；请重新安装"
    fi
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-link}") \
        || die "状态文件中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}"
    if [[ -n "${SUBSCRIPTION_DOMAIN:-}" ]]; then
        SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN}")
        validate_domain "${SUBSCRIPTION_DOMAIN}" \
            || die "状态文件中的 SUBSCRIPTION_DOMAIN 无效：${SUBSCRIPTION_DOMAIN}"
    fi
    if [[ -n "${SUB_SOURCE_DOMAIN:-}" ]]; then
        SUB_SOURCE_DOMAIN=$(normalize_domain "${SUB_SOURCE_DOMAIN}")
        validate_domain "${SUB_SOURCE_DOMAIN}" \
            || die "状态文件中的 SUB_SOURCE_DOMAIN 无效：${SUB_SOURCE_DOMAIN}"
    fi
    if subscription_enabled; then
        [[ "${SUBSCRIPTION_DOMAIN}" != "${NODE_HOST:-}" ]] \
            || die "订阅域名不能与 Reality 直连节点域名相同；请重新安装"
        [[ -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${CLOUDFLARE_ZONE_NAME:-}" \
            && -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
            && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" \
            && -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
            || die "Reality Cloudflare 订阅状态不完整；请重新安装"
    fi
    if worker_subscription_enabled; then
        [[ -n "${SUB_SOURCE_DOMAIN:-}" && "${SUB_SOURCE_DOMAIN}" != "${SUBSCRIPTION_DOMAIN}" \
            && "${SUB_SOURCE_DOMAIN}" != "${NODE_HOST:-}" ]] \
            || die "Worker 聚合的私有源域名缺失或与公开域名相同；请重新安装"
        [[ "${CLOUDFLARE_ACCOUNT_ID:-}" =~ ^[0-9A-Fa-f]{32}$ ]] \
            || die "状态缺少有效的 Cloudflare Account ID；请重新安装"
        validate_cloudflare_worker_name "${CLOUDFLARE_WORKER_NAME:-}" \
            || die "状态缺少有效的 Cloudflare Worker 名称；请重新安装"
        [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" ]] \
            || die "状态缺少 Worker 自定义域名 ID；请重新安装"
        [[ "${WORKER_SOURCE_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            || die "状态缺少有效的 Worker 订阅源密钥；请重新安装"
        WORKER_AGGREGATION_CONFIG=$(normalize_worker_aggregation_config \
            "${WORKER_AGGREGATION_CONFIG:-}" | jq -c 'del(.allowedTokens)') \
            || die "状态中的 Worker 聚合配置无效；请重新安装"
    else
        SUB_SOURCE_DOMAIN=""
        CLOUDFLARE_WORKER_NAME=""
        CLOUDFLARE_WORKER_DOMAIN_ID=""
        WORKER_SOURCE_SECRET=""
        WORKER_AGGREGATION_CONFIG='{"nodes":[],"fallbackCdnNodes":[]}'
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
    enforce_ipv4_only_policy
    TCP_ACCELERATION=$(normalize_tcp_acceleration "${TCP_ACCELERATION:-bbrv3}") \
        || die "无法保存无效的 TCP_ACCELERATION"
    if worker_subscription_enabled; then
        [[ "${CLOUDFLARE_ACCOUNT_ID:-}" =~ ^[0-9A-Fa-f]{32}$ \
            && -n "${SUB_SOURCE_DOMAIN:-}" \
            && -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" \
            && "${WORKER_SOURCE_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            && validate_cloudflare_worker_name "${CLOUDFLARE_WORKER_NAME:-}" \
            || die "无法保存不完整的 Worker 聚合状态"
        WORKER_AGGREGATION_CONFIG=$(normalize_worker_aggregation_config \
            "${WORKER_AGGREGATION_CONFIG:-}" | jq -c 'del(.allowedTokens)') \
            || die "无法保存无效的 Worker 聚合配置"
    fi
    install -d -m 0700 "${STATE_DIR}"
    local temp aggregation empty_aggregation='{"nodes":[],"fallbackCdnNodes":[]}'
    aggregation=${WORKER_AGGREGATION_CONFIG:-${empty_aggregation}}
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") \
        || die "创建状态暂存文件失败"
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        printf 'PROTOCOL=%q\n' "${PROTOCOL}"
        printf 'CDN_PROVIDER=%q\n' ""
        printf 'TCP_ACCELERATION=%q\n' "${TCP_ACCELERATION}"
        printf 'NODE_NAME=%q\n' "${NODE_NAME}"
        printf 'NODE_HOST=%q\n' "${NODE_HOST:-}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID:-}"
        printf 'REALITY_TARGET=%q\n' "${REALITY_TARGET:-}"
        printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY:-}"
        printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY:-}"
        printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID:-}"
        printf 'VPS_IP_FAMILY=%q\n' "${VPS_IP_FAMILY:-ipv4}"
        printf 'VPS_PUBLIC_IPV6=%q\n' "${VPS_PUBLIC_IPV6:-}"
        validate_google_egress_policy_state \
            || die "无法保存无效的 Google 出站策略"
        printf 'GOOGLE_EGRESS_MODE=%q\n' "${GOOGLE_EGRESS_MODE}"
        printf 'GOOGLE_EGRESS_RESOLVED=%q\n' "${GOOGLE_EGRESS_RESOLVED}"
        printf 'SUB_PORT_MODE=%q\n' "${SUB_PORT_MODE:-$(protocol_default_port_mode)}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'QUOTA_ENABLED=%q\n' "${QUOTA_ENABLED:-0}"
        printf 'USER_ACCOUNTS=%q\n' "${USER_ACCOUNTS:-}"
        printf 'QUOTA_START_DATE=%q\n' "${QUOTA_START_DATE:-}"
        printf 'MIHOMO_TEMPLATE_SNAPSHOT=%q\n' "${MIHOMO_TEMPLATE_SNAPSHOT:-0}"
        printf 'SUBSCRIPTION_MODE=%q\n' "${SUBSCRIPTION_MODE:-link}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
        printf 'SUBSCRIPTION_DOMAIN=%q\n' "${SUBSCRIPTION_DOMAIN:-}"
        printf 'SUB_SOURCE_DOMAIN=%q\n' "${SUB_SOURCE_DOMAIN:-}"
        printf 'CLOUDFLARE_ZONE_ID=%q\n' "${CLOUDFLARE_ZONE_ID:-}"
        printf 'CLOUDFLARE_ZONE_NAME=%q\n' "${CLOUDFLARE_ZONE_NAME:-}"
        printf 'CLOUDFLARE_ACCOUNT_ID=%q\n' "${CLOUDFLARE_ACCOUNT_ID:-}"
        printf 'CLOUDFLARE_ORIGIN_CERT_ID=%q\n' "${CLOUDFLARE_ORIGIN_CERT_ID:-}"
        printf 'CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=%q\n' "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}"
        printf 'CLOUDFLARE_STRICT_RULESET_ID=%q\n' "${CLOUDFLARE_STRICT_RULESET_ID:-}"
        printf 'CLOUDFLARE_WORKER_NAME=%q\n' "${CLOUDFLARE_WORKER_NAME:-}"
        printf 'CLOUDFLARE_WORKER_DOMAIN_ID=%q\n' "${CLOUDFLARE_WORKER_DOMAIN_ID:-}"
        printf 'WORKER_SOURCE_SECRET=%q\n' "${WORKER_SOURCE_SECRET:-}"
        printf 'WORKER_AGGREGATION_CONFIG=%q\n' "${aggregation}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}" || die "写入状态暂存文件失败"
    chmod 0600 "${temp}" && mv -f -- "${temp}" "${STATE_FILE}" \
        || die "原子保存状态文件失败：${STATE_FILE}"
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

# Nginx always serves the private node source. Local subscription mode publishes
# that host directly; Worker aggregation keeps it private behind a custom domain.
subscription_origin_domain() {
    if worker_subscription_enabled; then
        printf '%s' "${SUB_SOURCE_DOMAIN:-}"
    else
        printf '%s' "${SUBSCRIPTION_DOMAIN:-}"
    fi
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
                "${detected_ip}")
        else
            NODE_HOST=${detected_ip}
        fi
        return 0
    fi

    if [[ -t 0 ]]; then
        warn "无法自动检测本机公网 IPv4，请手动填写客户端可连接的入站地址"
        NODE_HOST=$(prompt_value \
            "Reality 客户端连接地址（公网 IPv4 或 DNS only / 灰云域名）" "")
        return 0
    fi
    die "无法自动检测 Reality 节点公网 IPv4；非交互模式请设置 NODE_HOST"
}

collect_reality_target() {
    [[ -z "${REALITY_TARGET:-}" ]] || return 0
    if [[ -t 0 ]]; then
        REALITY_TARGET=$(prompt_value \
            "Reality SNI / 伪装目标（域名:端口）" \
            "${DEFAULT_REALITY_TARGET}")
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
        printf '  1. 固定 443\n'
        printf '  2. dynamic（订阅每小时提供 %s 个动态端口 %s-%s，默认）\n' \
            "${DYNAMIC_PORTS_PER_HOUR}" "${PORT_BASE}" "${DYNAMIC_PORT_MAX}"
        read_bilingual \
            "请选择 [${default_choice}]（直接回车使用默认值）:" requested
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
    # A Worker Custom Domain owns the hostname; switching back to a local
    # subscription must not try to reuse it as a proxied origin record.
    [[ "${PREVIOUS_SUBSCRIPTION_MODE:-}" != "worker" ]] || domain=""
    if [[ -z "${domain}" && -t 0 ]]; then
        domain=$(prompt_value "Cloudflare 代理的订阅域名（Zone 下一级子域名）" "")
    fi
    [[ -n "${domain}" ]] \
        || die "自托管订阅模式必须设置 SUBSCRIPTION_DOMAIN"
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    [[ "${domain}" != "${NODE_HOST:-}" ]] \
        || die "订阅域名不能与 Reality 直连节点域名相同；请使用独立的 Cloudflare 一级子域名"
    SUBSCRIPTION_DOMAIN=${domain}
}

collect_reality_inputs() {
    validate_protocol "${PROTOCOL}" || die "PROTOCOL 无效：${PROTOCOL:-空}"
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
    choose_google_egress_mode
}

check_install_conflicts() {
    if ss -H -ltn "sport = :${SERVICE_PORT}" 2>/dev/null \
        | awk 'NR {found=1} END {exit !found}'; then
        die "TCP ${SERVICE_PORT} 已被占用；easy_all 仅支持专用 VPS"
    fi
}

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
    [[ "${SUB_PORT_MODE}" != "dynamic" ]] || dynamic=1
    write_ufw_nat_rules_for_family "${UFW_BEFORE_RULES}" iptables-restore \
        "${UFW_NAT_START}" "${UFW_NAT_END}" "${dynamic}" "IPv4"
    if [[ -f "${UFW_BEFORE6_RULES}" ]] \
        && grep -Fq "${UFW_NAT6_START}" "${UFW_BEFORE6_RULES}"; then
        write_ufw_nat_rules_for_family "${UFW_BEFORE6_RULES}" ip6tables-restore \
            "${UFW_NAT6_START}" "${UFW_NAT6_END}" 0 "IPv6"
    fi
}

filter_dynamic_port_cron() {
    awk -v marker="${CRON_DYNAMIC_PORT_MARKER}" 'index($0, marker) == 0'
}

restore_dynamic_port_rotation_schedule() {
    local snapshot=$1 candidate="${RUNTIME_TMP}/rollback-dynamic-port.cron" current
    current=$(read_root_crontab) || return 1
    printf '%s\n' "${current}" | filter_dynamic_port_cron >"${candidate}"
    if [[ -f "${snapshot}" ]]; then
        awk -v marker="${CRON_DYNAMIC_PORT_MARKER}" \
            'index($0, marker) != 0' "${snapshot}" >>"${candidate}"
    fi
    crontab "${candidate}" \
        || warn "恢复 easy_all 动态端口定时任务失败，请手动检查 root crontab"
}

configure_dynamic_port_rotation() {
    local current job
    current=$(read_root_crontab) || return 1
    if [[ "${SUB_PORT_MODE:-}" != "dynamic" ]]; then
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

reality_cloudflare_fetch_origin_ipv4_ranges() {
    local response
    response=$(curl -fsS --retry 3 --connect-timeout 10 --max-time 30 \
        "${CLOUDFLARE_API_BASE}/ips") || return 1
    jq -er '
        select(.success == true)
        | .result.ipv4_cidrs
        | select(type == "array" and length > 0)
        | unique[]
        | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([89]|[12][0-9]|3[0-2])$"))
    ' <<<"${response}" | sort -u
}

reality_cloudflare_subscription_ufw_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | sed -n "/${CLOUDFLARE_SUBSCRIPTION_UFW_COMMENT}/s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)\\].*/\\1/p" \
        | sort -rn
}

reality_cloudflare_remove_subscription_firewall_rules() {
    local number
    while IFS= read -r number; do
        [[ -n "${number}" ]] || continue
        ufw --force delete "${number}" >/dev/null 2>&1 \
            || warn "删除 Cloudflare 订阅 UFW 规则 ${number} 失败"
    done < <(reality_cloudflare_subscription_ufw_rule_numbers)
}

reality_cloudflare_configure_subscription_firewall() {
    local next current cidr
    next="${RUNTIME_TMP}/reality-cloudflare-origin-ipv4.txt"
    if ! reality_cloudflare_fetch_origin_ipv4_ranges >"${next}" || [[ ! -s "${next}" ]]; then
        if [[ -s "${CLOUDFLARE_ORIGIN_IPS_FILE}" ]]; then
            warn "获取 Cloudflare 官方 IP 段失败，继续使用上一版订阅回源白名单"
            install -m 0600 "${CLOUDFLARE_ORIGIN_IPS_FILE}" "${next}"
        else
            die "无法获取 Cloudflare 官方 IPv4 段，且没有可回退的订阅回源白名单"
        fi
    fi
    current="${RUNTIME_TMP}/reality-cloudflare-origin-ipv4.current"
    if [[ -s "${CLOUDFLARE_ORIGIN_IPS_FILE}" ]]; then
        install -m 0600 "${CLOUDFLARE_ORIGIN_IPS_FILE}" "${current}"
    else
        : >"${current}"
    fi
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        ufw allow proto tcp from "${cidr}" to any port "${SUBSCRIPTION_HTTPS_PORT}" \
            comment "${CLOUDFLARE_SUBSCRIPTION_UFW_COMMENT}" >/dev/null \
            || die "添加 Cloudflare 订阅回源规则失败：${cidr}"
    done <"${next}"
    ufw reload >/dev/null || die "重载 UFW 失败"
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        ufw_tcp_port_is_allowed "${SUBSCRIPTION_HTTPS_PORT}" "${cidr}" \
            || die "UFW 未有效放行 Cloudflare 订阅回源：${cidr}"
    done <"${next}"
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${next}" && continue
        ufw --force delete allow proto tcp from "${cidr}" to any port "${SUBSCRIPTION_HTTPS_PORT}" \
            >/dev/null || warn "删除过期 Cloudflare 订阅回源规则失败：${cidr}"
    done <"${current}"
    install -m 0600 "${next}" "${CLOUDFLARE_ORIGIN_IPS_FILE}"
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
    if subscription_enabled; then
        ufw_tcp_port_has_unmanaged_anywhere_allow "${SUBSCRIPTION_HTTPS_PORT}" \
            && die "检测到非 easy_all 管理的 TCP ${SUBSCRIPTION_HTTPS_PORT} 全网放行规则；请先删除该规则，避免绕过 Cloudflare 回源白名单"
        apply_ssh_ufw_policy "${desired_ports}"
        reality_cloudflare_configure_subscription_firewall
    else
        reality_cloudflare_remove_subscription_firewall_rules
    fi
    apply_ssh_ufw_policy "${desired_ports}"
    write_ufw_nat_rules
    ufw reload >/dev/null || die "加载 UFW NAT 规则失败"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

write_xray_config() {
    local clients managed_outbounds managed_routing inbound_sockopt listen_address="0.0.0.0"
    managed_outbounds=$(xray_direct_outbounds_json)
    managed_routing=$(xray_direct_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
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
            --arg xray_asset_dir "${XRAY_DIR}" \
            --argjson inbound_sockopt "${inbound_sockopt}" \
            --argjson managed_outbounds "${managed_outbounds}" \
            --argjson managed_routing "${managed_routing}" '
            {
              log: {loglevel: "warning"},
              env: {XRAY_LOCATION_ASSET:$xray_asset_dir},
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
                  sockopt: $inbound_sockopt,
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

build_reality_link() {
    local port=${1:-443} mlkem_param=""
    # Xray clients negotiate ML-KEM themselves; the hint only lets the Worker
    # mirror this server's capability in its Mihomo output.
    if ! reality_mlkem_required; then
        mlkem_param="&mlkem=0"
    fi
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&packetEncoding=xudp%s#%s' \
        "${VLESS_UUID}" "${NODE_HOST}" "${port}" "${REALITY_TARGET%:*}" \
        "$(uri_encode "${REALITY_PUBLIC_KEY}")" "$(uri_encode "${REALITY_SHORT_ID}")" \
        "${mlkem_param}" "$(uri_encode "${NODE_NAME}")"
}

build_node_link() {
    build_reality_link "${1:-443}"
}

# Xray 26.9.8+ rejects a REALITY ClientHello without an X25519MLKEM768 key share, and mihomo
# strips that share unless reality-opts.support-x25519mlkem768 is set (mihomo 5cf0f18, v1.19.9).
# Older servers may fail authentication on a hybrid share, so gate on the installed core.
# The version encoding assumes minor and patch stay below 100, which holds for Xray releases.
reality_mlkem_required() {
    local version major minor patch
    version=$(xray_installed_version)
    version=${version//[[:space:]]/}
    version=${version#v}
    IFS=. read -r major minor patch _ <<<"${version}"
    if [[ ! "${major}" =~ ^[0-9]+$ || ! "${minor}" =~ ^[0-9]+$ || ! "${patch}" =~ ^[0-9]+$ ]]; then
        warn "无法确定 Xray 核心版本，Reality 订阅未下发 support-x25519mlkem768；执行 sudo easy_all update-core 可恢复" >&2
        return 1
    fi
    ((10#${major} * 10000 + 10#${minor} * 100 + 10#${patch} >= 260908))
}

build_mihomo_node() {
    local port=${1:-443} mlkem=0
    resolve_reality_client_ip_family
    if reality_mlkem_required; then
        mlkem=1
    fi
    jq -nr \
            --arg name "${NODE_NAME}" --arg server "${NODE_HOST}" \
            --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
            --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" \
            --arg ip_version "${REALITY_CLIENT_IP_FAMILY_RESOLVED}" \
            --argjson port "${port}" --argjson mlkem "${mlkem}" '
            "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: \($port)\n" +
            "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
            "    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \($sni|@json)\n" +
            "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
            (if $mlkem == 1 then "      support-x25519mlkem768: true\n" else "" end) +
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

rotate_dynamic_ports() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    if [[ "${SUB_PORT_MODE}" != "dynamic" ]]; then
        end_quota_maintenance
        return 0
    fi
    write_ufw_nat_rules
    ufw reload >/dev/null || die "刷新动态端口 NAT 规则失败"
    if subscription_enabled; then
        install_static_subscriptions
        # Persist the snapshot flag so later refreshes reuse the same template.
        save_state
    fi
    end_quota_maintenance
    success "动态端口 NAT 与订阅快照已刷新：开放 ${PORT_BASE}-${DYNAMIC_PORT_MAX} 转发至 ${SERVICE_PORT}（每小时 ${DYNAMIC_PORTS_PER_HOUR} 个端口）"
}

install_subscription_dependencies() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update || return 1
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends nginx cron libnginx-mod-http-js \
        || return 1
    command -v nginx >/dev/null 2>&1 || die "Nginx 安装后不可用"
}

reality_cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret \
            "Cloudflare API Token（仅当前进程使用，不落盘）") \
            || die "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
    fi
    [[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
        && "${CLOUDFLARE_API_TOKEN}" != *[[:space:]]* ]] \
        || die "CLOUDFLARE_API_TOKEN 格式无效"
}

reality_cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN
    rm -f -- "${RUNTIME_TMP}/reality-cloudflare-api-headers" \
        "${RUNTIME_TMP}/reality-cloudflare-worker-api-headers" \
        "${RUNTIME_TMP}/reality-worker-config.json"
}

reality_cloudflare_api_request() {
    local method=$1 path=$2 payload=${3:-} response headers
    local -a retry_args=(--retry 0)
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "缺少 CLOUDFLARE_API_TOKEN"
    headers="${RUNTIME_TMP}/reality-cloudflare-api-headers"
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

reality_cloudflare_find_parent_zone() {
    local domain=$1 candidate zone
    candidate=${domain}
    while [[ "${candidate}" == *.* ]]; do
        zone=$(reality_cloudflare_api_request GET \
            "/zones?name=${candidate}&status=active&per_page=50" \
            | jq -r --arg name "${candidate}" \
                '[.[] | select((.name|ascii_downcase)==$name) | .id] | if length == 1 then .[0] else empty end')
        if [[ -n "${zone}" ]]; then printf '%s' "${zone}"; return; fi
        candidate=${candidate#*.}
    done
    die "Cloudflare active Zone 未覆盖订阅域名：${domain}"
}

reality_cloudflare_record_list() {
    reality_cloudflare_api_request GET \
        "/zones/$1/dns_records?type=$2&name=$3&per_page=100"
}

reality_cloudflare_ensure_proxied_a() {
    local records record="" id content proxied comment type payload count
    local origin_domain
    origin_domain=$(subscription_origin_domain)
    # Check every conflicting record type before returning or changing DNS.
    for type in A AAAA CNAME; do
        records=$(reality_cloudflare_record_list \
            "${CLOUDFLARE_ZONE_ID}" "${type}" "${origin_domain}") \
            || die "读取 Cloudflare ${type} 记录失败"
        count=$(jq -er 'if type == "array" then length else error("expected records array") end' \
            <<<"${records}") || die "Cloudflare ${type} 记录响应无效"
        ((count <= 1)) || die "Cloudflare 中发现多个同名 ${type} 记录，拒绝覆盖"
        [[ "${type}" == A ]] || ((count == 0)) \
            || die "${origin_domain} 已有 ${type} 记录；拒绝覆盖"
        if [[ "${type}" == A && "${count}" == 1 ]]; then
            record=$(jq -c '.[0]' <<<"${records}")
        fi
    done
    if [[ -n "${record}" ]]; then
        id=$(jq -r '.id' <<<"${record}")
        content=$(jq -r '.content' <<<"${record}")
        proxied=$(jq -r '.proxied' <<<"${record}")
        comment=$(jq -r '.comment // empty' <<<"${record}")
        if [[ "${content}" == "${VPS_PUBLIC_IPV4}" && "${proxied}" == true ]]; then
            return 0
        fi
        [[ "${comment}" == "easy_all reality subscription origin" ]] \
            || die "${origin_domain} 的 A 记录不属于 easy_all 或目标不一致；拒绝覆盖"
    fi
    payload=$(jq -cn --arg name "${origin_domain}" --arg content "${VPS_PUBLIC_IPV4}" \
        '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"easy_all reality subscription origin"}')
    if [[ -n "${record}" ]]; then
        reality_cloudflare_api_request PATCH \
            "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" "${payload}" >/dev/null
    else
        reality_cloudflare_api_request POST \
            "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${payload}" >/dev/null
    fi
}

reality_cloudflare_prepare_subscription() {
    local zone prefix origin_domain
    origin_domain=$(subscription_origin_domain)
    [[ -n "${origin_domain}" ]] || die "当前订阅模式缺少 Cloudflare 回源域名"
    reality_cloudflare_collect_api_token
    CLOUDFLARE_ZONE_ID=$(reality_cloudflare_find_parent_zone "${origin_domain}")
    zone=$(reality_cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}")
    CLOUDFLARE_ZONE_NAME=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    [[ -n "${CLOUDFLARE_ZONE_NAME}" \
        && "${origin_domain}" == *."${CLOUDFLARE_ZONE_NAME}" ]] \
        || die "订阅回源域名不属于 Cloudflare Zone"
    prefix=${origin_domain%.${CLOUDFLARE_ZONE_NAME}}
    [[ -n "${prefix}" && "${prefix}" != *.* ]] \
        || die "Reality 的 Cloudflare 订阅仅支持 Zone 下一级子域名"
    CLOUDFLARE_ACCOUNT_ID=$(jq -r '.account.id // empty' <<<"${zone}")
    [[ "${CLOUDFLARE_ACCOUNT_ID}" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "Cloudflare Zone 未返回有效 Account ID"
    VPS_PUBLIC_IPV4=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} \
        || die "无法探测当前 VPS 公网 IPv4"
    validate_ipv4 "${VPS_PUBLIC_IPV4}" || die "VPS_PUBLIC_IPV4 无效：${VPS_PUBLIC_IPV4}"
    reality_cloudflare_ensure_proxied_a
}

reality_cloudflare_ensure_origin_ca_root() {
    if [[ -s "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" ]] \
        && openssl x509 -in "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" -noout >/dev/null 2>&1; then
        return 0
    fi
    install -d -m 0700 "${CERT_DIR}"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        "${CLOUDFLARE_ORIGIN_CA_ROOT_URL}" \
        -o "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" \
        || die "下载 Cloudflare Origin CA ECC 根证书失败"
    openssl x509 -in "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" -noout >/dev/null 2>&1 \
        || die "Cloudflare Origin CA ECC 根证书格式无效"
    install -m 0644 "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" \
        "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
}

reality_cloudflare_origin_certificate_is_current() {
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] || return 1
    openssl x509 -in "${CERT_FILE}" -checkend 2592000 -noout >/dev/null 2>&1 \
        && openssl x509 -in "${CERT_FILE}" -checkhost "$(subscription_origin_domain)" -noout >/dev/null 2>&1 \
        && [[ "$(openssl x509 -in "${CERT_FILE}" -pubkey -noout 2>/dev/null \
            | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" \
            == "$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null \
            | sha256sum | cut -d' ' -f1)" ]]
}

reality_cloudflare_origin_certificate_is_reusable() {
    # A current certificate on disk is only reusable with the Cloudflare side
    # metadata that save_state persists and load_state requires. Reusing one
    # without it (e.g. deploy -> link -> deploy clears the ID) writes an
    # incomplete state file that later hard-fails as "订阅状态不完整".
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" ]] \
        && reality_cloudflare_origin_certificate_is_current
}

reality_cloudflare_issue_origin_certificate() {
    local force=${1:-0} key csr result cert expires old_id origin_domain
    origin_domain=$(subscription_origin_domain)
    [[ -n "${origin_domain}" ]] || die "当前订阅模式缺少 Cloudflare 回源域名"
    reality_cloudflare_ensure_origin_ca_root
    if [[ "${force}" != 1 ]] && reality_cloudflare_origin_certificate_is_reusable; then
        return 0
    fi
    reality_cloudflare_collect_api_token
    old_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    key="${RUNTIME_TMP}/reality-cloudflare-origin.key"
    csr="${RUNTIME_TMP}/reality-cloudflare-origin.csr"
    openssl ecparam -name prime256v1 -genkey -noout -out "${key}"
    chmod 0600 "${key}"
    openssl req -new -sha256 -key "${key}" -subj "/CN=${origin_domain}" \
        -addext "subjectAltName=DNS:${origin_domain}" -out "${csr}"
    result=$(reality_cloudflare_api_request POST '/certificates' \
        "$(jq -cn --arg csr "$(<"${csr}")" --arg host "${origin_domain}" \
            --argjson validity "${CLOUDFLARE_ORIGIN_VALIDITY_DAYS}" \
            '{hostnames:[$host],requested_validity:$validity,request_type:"origin-ecc",csr:$csr}')")
    cert=$(jq -r '.certificate // empty' <<<"${result}")
    CLOUDFLARE_ORIGIN_CERT_ID=$(jq -r '.id // empty' <<<"${result}")
    expires=$(jq -r '.expires_on // empty' <<<"${result}")
    [[ -n "${cert}" && -n "${CLOUDFLARE_ORIGIN_CERT_ID}" && -n "${expires}" ]] \
        || die "Cloudflare 未返回 Origin CA 证书、ID 或到期时间"
    printf '%s\n' "${cert}" >"${RUNTIME_TMP}/reality-origin.pem"
    openssl verify -CAfile "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" \
        "${RUNTIME_TMP}/reality-origin.pem" >/dev/null \
        || die "Cloudflare Origin CA 证书链验证失败"
    install -m 0600 "${RUNTIME_TMP}/reality-origin.pem" "${CERT_FILE}"
    install -m 0600 "${key}" "${KEY_FILE}"
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=${expires}
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=${old_id}
}

reality_cloudflare_ref() {
    printf 'easy_all_%s' "$(printf '%s' "$1" | sha256sum | cut -c1-24)"
}

reality_cloudflare_configure_strict_tls() {
    local listed matches count ruleset rules ref rule_matches rule_count rule_id payload
    listed=$(reality_cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets")
    matches=$(jq -c '[.[] | select(.kind=="zone" and .phase=="http_config_settings")]' \
        <<<"${listed}")
    count=$(jq length <<<"${matches}")
    ((count <= 1)) || die "Cloudflare 存在多个 Zone 配置 ruleset，拒绝猜测"
    if ((count == 1)); then
        ruleset=$(jq -r '.[0].id' <<<"${matches}")
    else
        ruleset=$(reality_cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets" \
            "$(jq -cn '{name:"easy_all reality subscription strict",kind:"zone",phase:"http_config_settings",rules:[]}')" \
            | jq -r '.id // empty')
    fi
    [[ -n "${ruleset}" ]] || die "Cloudflare 未返回 Strict TLS ruleset ID"
    ref=$(reality_cloudflare_ref "reality-strict:$(subscription_origin_domain)")
    payload=$(jq -cn --arg ref "${ref}" --arg host "$(subscription_origin_domain)" \
        '{ref:$ref,description:"easy_all reality subscription strict TLS",expression:("http.host eq \""+$host+"\""),action:"set_config",action_parameters:{ssl:"strict"}}')
    rules=$(reality_cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    rule_matches=$(jq -c --arg ref "${ref}" '[.rules[]? | select(.ref==$ref)]' <<<"${rules}")
    rule_count=$(jq length <<<"${rule_matches}")
    ((rule_count <= 1)) || die "Cloudflare 中存在多个 Reality Strict TLS 规则，拒绝覆盖"
    if ((rule_count == 1)); then
        rule_id=$(jq -r '.[0].id' <<<"${rule_matches}")
        reality_cloudflare_api_request PATCH \
            "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${rule_id}" \
            "${payload}" >/dev/null
    else
        reality_cloudflare_api_request POST \
            "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules" \
            "${payload}" >/dev/null
    fi
    CLOUDFLARE_STRICT_RULESET_ID=${ruleset}
}

write_subscription_web_root() {
    install -d -m 0755 "${WEB_ROOT}"
}

write_subscription_bootstrap_nginx() {
    local http2_directive="" listen_h2=" http2"
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    write_subscription_web_root
    if [[ ! -f "${NGINX_CONFIG}" ]]; then
        ss -H -ltn "sport = :${SUBSCRIPTION_HTTPS_PORT}" 2>/dev/null \
            | awk 'NR {found=1} END {exit !found}' \
            && die "TCP ${SUBSCRIPTION_HTTPS_PORT} 已被占用"
    fi
    rm -f -- /etc/nginx/sites-enabled/default
    cat >"${RUNTIME_TMP}/easy_all-bootstrap.conf" <<EOF
server {
    listen ${SUBSCRIPTION_HTTPS_PORT} ssl${listen_h2};${http2_directive}
    server_name $(subscription_origin_domain);
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    location = /easy_all-health { default_type text/plain; return 200 'easy_all ok'; }
    location / { return 404; }
}
EOF
    install -m 0600 "${RUNTIME_TMP}/easy_all-bootstrap.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx HTTP 引导配置校验失败"
    systemctl enable --now nginx >/dev/null || die "启动 Nginx 失败"
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

generate_subscription_files() {
    local base64_template=$1 mihomo_template=$2 node_file port link placeholder end_token
    # Numeric files validate generation only; runtime publication contains two port templates.
    local base64_file="${RUNTIME_TMP}/subscription-base64.validation.txt"
    local mihomo_file="${RUNTIME_TMP}/subscription-mihomo.validation.yaml"
    placeholder=__EASY_ALL_REALITY_PORT__
    end_token=EASY_ALL_REALITY_TEMPLATE_END_V1
    ensure_allowed_tokens
    prepare_mihomo_template
    port=$(generate_subscription_port)
    node_file="${RUNTIME_TMP}/subscription-node.yaml"
    build_mihomo_node "${port}" >"${node_file}" || return 1
    link=$(build_node_link "${port}") || return 1
    printf '%s' "${link}" | openssl base64 -A >"${base64_file}" || return 1
    printf '\n' >>"${base64_file}"
    render_mihomo_subscription "${MIHOMO_TEMPLATE_FILE}" "${node_file}" "${mihomo_file}" \
        "${NODE_NAME}" || return 1
    printf '%s' "$(<"${base64_file}")" | openssl base64 -d -A \
        | grep -Fq 'security=reality' || die "Base64 订阅内容无效"
    grep -Fq 'reality-opts:' "${mihomo_file}" || die "Mihomo 订阅缺少 Reality 节点"
    grep -Fq 'rules:' "${mihomo_file}" || die "Mihomo 订阅缺少规则"
    if grep -Fq "${placeholder}" "${mihomo_file}" \
        || grep -Fq "${end_token}" "${mihomo_file}" \
        || [[ "${link}" == *"${placeholder}"* ]]; then
        die "订阅模板包含保留标记"
    fi
    awk -v port="${port}" -v placeholder="${placeholder}" '
        $0 == "    port: " port { $0="    port: " placeholder; count++ }
        { print }
        END { if (count != 1) exit 1 }
    ' "${node_file}" >"${node_file}.port-template" \
        || die "Reality 节点端口模板无效"
    render_mihomo_subscription "${MIHOMO_TEMPLATE_FILE}" "${node_file}.port-template" \
        "${mihomo_template}" "${NODE_NAME}" || return 1
    awk -v placeholder="${placeholder}" '
        { line=$0; while ((pos=index(line,placeholder)) > 0) {
            count++; line=substr(line,pos+length(placeholder))
        } }
        $0 == "    port: " placeholder { ports++ }
        END { if (count != 1 || ports != 1) exit 1 }
    ' "${mihomo_template}" || die "Reality YAML 端口模板无效"
    printf '# %s\n' "${end_token}" >>"${mihomo_template}" || return 1
    # The marker shares the staging file and is appended only after complete rendering.
    [[ "$(tail -n 1 "${mihomo_template}")" == "# ${end_token}" ]] \
        && [[ "$(grep -Fc "${end_token}" "${mihomo_template}")" == 1 ]] \
        || die "Reality YAML 终止标记无效"
    link=$(build_node_link "${placeholder}") || return 1
    [[ "${link}" == *":${placeholder}?"* \
        && "${link#*${placeholder}}" != *"${placeholder}"* ]] \
        || die "Reality 链接端口模板无效"
    printf '%s' "${link}" | openssl base64 -A >"${base64_template}" || return 1
    printf '\n' >>"${base64_template}"
}

install_static_subscriptions() {
    local base64_file="${RUNTIME_TMP}/subscription-base64.port-template"
    local mihomo_file="${RUNTIME_TMP}/subscription-mihomo.port-template"
    local stage_dir user uuid user_dir
    install -d -m 0755 "${WEB_ROOT}" || return 1
    prepare_mihomo_template || return 1
    persist_mihomo_template_snapshot || return 1
    # A republication that died inside a subshell cannot unregister its stage dir, so sweep
    # leftovers from earlier failed runs before staging a new generation.
    rm -rf -- "${WEB_ROOT}"/.subscriptions.stage.* 2>/dev/null || true
    stage_dir=$(mktemp -d "${WEB_ROOT}/.subscriptions.stage.XXXXXX") \
        || die "创建订阅暂存目录失败"
    cleanup_files+=("${stage_dir}")
    install -d -o root -g www-data -m 0750 "${stage_dir}" || return 1
    if quota_enabled; then
        while IFS=$'\t' read -r user uuid; do
            user_dir="${stage_dir}/${user}"
            (
                VLESS_UUID=${uuid}
                generate_subscription_files "${base64_file}.${user}" "${mihomo_file}.${user}"
            ) || return 1
            install -d -o root -g www-data -m 0750 "${user_dir}" || return 1
            install -o root -g www-data -m 0640 \
                "${base64_file}.${user}" "${user_dir}/base64.port-template" || return 1
            install -o root -g www-data -m 0640 \
                "${mihomo_file}.${user}" "${user_dir}/mihomo.port-template" || return 1
        done < <(jq -r 'to_entries[] | [.key,.value.uuid] | @tsv' <<<"${USER_ACCOUNTS}")
    else
        generate_subscription_files "${base64_file}" "${mihomo_file}" || return 1
        install -o root -g www-data -m 0640 "${base64_file}" \
            "${stage_dir}/base64.port-template" || return 1
        install -o root -g www-data -m 0640 "${mihomo_file}" \
            "${stage_dir}/mihomo.port-template" || return 1
    fi
    publish_subscription_files "${stage_dir}" || return 1
    rm -rf -- "${stage_dir}"
}

install_reality_subscription_renderer() {
    local candidate
    candidate=$(mktemp "${REALITY_SUBSCRIPTION_JS}.XXXXXX") || return 1
    cleanup_files+=("${candidate}")
    install -o root -g root -m 0644 "${SCRIPT_DIR}/reality-subscription.js" "${candidate}" \
        || return 1
    mv -f -- "${candidate}" "${REALITY_SUBSCRIPTION_JS}"
}

write_subscription_nginx_config() {
    local http2_directive="" listen_h2=" http2" candidate
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    write_subscription_web_root
    {
        printf 'js_import easy_all_reality_subscription from %s;\n' "${REALITY_SUBSCRIPTION_JS}"
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen ${SUBSCRIPTION_HTTPS_PORT} ssl${listen_h2};${http2_directive}
    server_name $(subscription_origin_domain);
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;

    location = /easy_all-health {
        default_type text/plain;
        return 200 'easy_all ok';
    }

EOF
        if worker_subscription_enabled; then
            write_subscription_nginx_locations "" "${WORKER_SOURCE_SECRET:-}" reality
        else
            write_subscription_nginx_locations "" "" reality
        fi
        cat <<'EOF'
    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    candidate=$(mktemp "${NGINX_CONFIG}.XXXXXX") || return 1
    cleanup_files+=("${candidate}")
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${candidate}" || return 1
    mv -f -- "${candidate}" "${NGINX_CONFIG}" || return 1
    nginx -t >/dev/null || die "Nginx 订阅配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

validate_subscription_response_port() {
    local port=$1 start=$2 finish=$3 instant hour base
    [[ "${port}" =~ ^[0-9]+$ ]] || die "订阅响应端口无效"
    if [[ "${SUB_PORT_MODE}" == "443" ]]; then
        [[ "${port}" == 443 ]] || die "订阅响应端口不符合固定模式"
        return 0
    fi
    for instant in "${start}" "${finish}"; do
        hour=$(TZ=Asia/Shanghai date -d "@${instant}" '+%j %H') || return 1
        base=$((PORT_BASE + ((10#${hour% *} - 1) * 24 + 10#${hour#* }) * DYNAMIC_PORTS_PER_HOUR))
        ((port >= base && port < base + DYNAMIC_PORTS_PER_HOUR)) && return 0
    done
    die "订阅响应端口不在请求时段的小时池中"
}

# The Worker keeps the Nginx source private; local probes must present the
# same shared secret the Worker sends on every upstream fetch. The secret goes
# into a 0600 header file so it never appears on the curl argv.
reality_prepare_worker_source_header() {
    worker_subscription_enabled || return 0
    [[ "${WORKER_SOURCE_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "Worker 聚合模式缺少有效的订阅源密钥"
    REALITY_WORKER_SOURCE_HEADER_FILE="${RUNTIME_TMP}/reality-worker-source-headers"
    printf 'X-Easy-All-Worker-Source: %s\n' "${WORKER_SOURCE_SECRET}" \
        >"${REALITY_WORKER_SOURCE_HEADER_FILE}" \
        || die "写入 Worker 订阅源请求头文件失败"
    chmod 0600 "${REALITY_WORKER_SOURCE_HEADER_FILE}"
}

reality_subscription_curl() {
    reality_prepare_worker_source_header
    if [[ -n "${REALITY_WORKER_SOURCE_HEADER_FILE:-}" ]]; then
        curl -H "@${REALITY_WORKER_SOURCE_HEADER_FILE}" "$@"
        return
    fi
    curl "$@"
}

validate_subscription_runtime() {
    local token base64_response base64_decoded mihomo_response accounts uuid start finish port flag headers method_status
    local origin_domain
    origin_domain=$(subscription_origin_domain)
    [[ -n "${origin_domain}" ]] || die "当前订阅模式缺少 Cloudflare 回源域名"
    if worker_subscription_enabled; then
        reality_prepare_worker_source_header
        validate_subscription_token_rejection \
            "${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
            "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/subscribe" \
            --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" \
            -H "@${REALITY_WORKER_SOURCE_HEADER_FILE}"
    else
        validate_subscription_token_rejection \
            "${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
            "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/subscribe" \
            --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
    fi
    method_status=$(reality_subscription_curl -sS --proto '=https' --request POST \
        --connect-timeout 5 --max-time 20 -o /dev/null -w '%{http_code}' \
        --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" --noproxy '*' \
        --resolve "${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        --get --data-urlencode 'token=invalid' \
        "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/subscribe") \
        || die "订阅方法限制本机验收失败"
    [[ "${method_status}" == 405 ]] || die "订阅方法限制未生效"
    if quota_enabled; then
        accounts=$(quota_active_accounts_json) || die "读取配额用户失败"
        token=$(jq -r 'first(.[].token) // empty' <<<"${accounts}")
        uuid=$(jq -r 'first(.[].uuid) // empty' <<<"${accounts}")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
        uuid=${VLESS_UUID}
    fi
    start=$(date +%s)
    base64_response=$(printf '%s' "${token}" | reality_subscription_curl -fsS --proto '=https' \
        --connect-timeout 5 --max-time 20 \
        --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" --noproxy '*' \
        --resolve "${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        --get --data-urlencode 'token@-' \
        "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/subscribe") \
        || die "Base64 订阅本机验收失败"
    finish=$(date +%s)
    [[ -n "${base64_response}" ]] || die "Base64 订阅响应为空"
    base64_decoded=$(printf '%s' "${base64_response}" | openssl base64 -d -A 2>/dev/null) \
        || die "Base64 订阅响应不是有效的 Base64"
    grep -Fq 'security=reality' <<<"${base64_decoded}" || die "Base64 订阅响应缺少 Reality 节点"
    [[ "${base64_decoded}" == "vless://${uuid}@"* \
        && "${base64_decoded}" != *"__EASY_ALL_REALITY_PORT__"* ]] \
        || die "Base64 订阅响应节点无效"
    port=${base64_decoded%%\?*}; port=${port##*:}
    validate_subscription_response_port "${port}" "${start}" "${finish}" || return 1
    start=$(date +%s)
    mihomo_response=$(printf '%s' "${token}" | reality_subscription_curl -fsS --proto '=https' \
        --connect-timeout 5 --max-time 20 \
        --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" --noproxy '*' \
        --resolve "${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        --get --data-urlencode 'token@-' --data-urlencode "flag=clash" \
        "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/subscribe") \
        || die "Mihomo 订阅本机验收失败"
    finish=$(date +%s)
    grep -Fq 'reality-opts:' <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
    [[ "${mihomo_response}" != *"__EASY_ALL_REALITY_PORT__"* \
        && "${mihomo_response}" != *"EASY_ALL_REALITY_TEMPLATE_END_V1"* ]] \
        || die "Mihomo 订阅响应模板无效"
    port=$(awk -v uuid="${uuid}" '
        /^    port: [0-9]+$/ { port=$2 }
        $0 == "    uuid: \"" uuid "\"" { print port; count++ }
        END { if (count != 1) exit 1 }
    ' <<<"${mihomo_response}") || die "Mihomo 订阅响应节点无效"
    validate_subscription_response_port "${port}" "${start}" "${finish}" || return 1
    for flag in base64 clash; do
        headers=$(printf '%s' "${token}" | reality_subscription_curl -fsS --head --proto '=https' \
            --connect-timeout 5 --max-time 20 \
            --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" --noproxy '*' \
            --resolve "${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
            --get --data-urlencode 'token@-' --data-urlencode "flag=${flag}" \
            "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/subscribe") \
            || die "订阅 HEAD 本机验收失败"
        grep -Eiq '^content-length: [1-9][0-9]*' <<<"${headers}" \
            || die "订阅 HEAD 缺少完整表示长度"
        if [[ "${flag}" == clash ]]; then
            grep -Eiq '^content-type: text/yaml' <<<"${headers}" || die "订阅 HEAD 类型无效"
        else
            grep -Eiq '^content-type: text/plain' <<<"${headers}" || die "订阅 HEAD 类型无效"
        fi
    done
}

reality_cloudflare_validate_public_subscription() {
    local attempt response origin_domain
    origin_domain=$(subscription_origin_domain)
    for attempt in {1..60}; do
        response=$(curl -fsS --connect-timeout 5 --max-time 15 \
            "https://${origin_domain}:${SUBSCRIPTION_HTTPS_PORT}/easy_all-health" \
            2>/dev/null || true)
        if [[ "${response}" == "easy_all ok" ]]; then
            success "Cloudflare Reality 订阅回源验收通过"
            return 0
        fi
        sleep 5
    done
    die "Cloudflare 订阅回源验收失败；请检查 Proxied DNS、Origin CA、Strict TLS 与 8443 回源"
}

reality_cloudflare_finalize_certificate_rotation() {
    local old_id=${CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID:-}
    [[ -n "${old_id}" && "${old_id}" != "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]] \
        || return 0
    if ! (reality_cloudflare_api_request DELETE "/certificates/${old_id}" >/dev/null); then
        warn "新证书已生效，但撤销旧 Cloudflare Origin CA 证书失败：${old_id}"
        return 0
    fi
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=""
}

reset_worker_subscription_inputs() {
    SUB_SOURCE_DOMAIN=""
    CLOUDFLARE_WORKER_NAME=""
    CLOUDFLARE_WORKER_DOMAIN_ID=""
    WORKER_SOURCE_SECRET=""
    WORKER_AGGREGATION_CONFIG='{"nodes":[],"fallbackCdnNodes":[]}'
}

collect_deployed_subscription_inputs() {
    local prompt_options=${1:-1} prompt_download_name=${2:-0}
    collect_subscription_domain
    choose_subscription_download_name "${prompt_download_name}"
    if [[ "${prompt_options}" == "1" ]]; then
        choose_monthly_quota 1
    fi
    quota_enabled || ensure_allowed_tokens "${prompt_options}"
    reset_worker_subscription_inputs
    SUBSCRIPTION_MODE="deploy"
}

collect_worker_public_domain() {
    local prompt_options=${1:-1} domain=${SUBSCRIPTION_DOMAIN:-}
    # The previous local subscription already uses SUBSCRIPTION_DOMAIN as its
    # proxied origin, so only a previous Worker deployment may reuse it.
    [[ "${PREVIOUS_SUBSCRIPTION_MODE:-}" == "worker" ]] || domain=""
    if [[ "${prompt_options}" == "1" && -t 0 ]]; then
        domain=$(prompt_value \
            "Cloudflare Worker 订阅域名（公开入口，Zone 下一级子域名）" "${domain}")
    fi
    [[ -n "${domain}" ]] \
        || die "Worker 订阅聚合必须设置 SUBSCRIPTION_DOMAIN"
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    [[ "${domain}" != "${NODE_HOST:-}" ]] \
        || die "订阅域名不能与 Reality 直连节点域名相同；请使用独立的 Cloudflare 一级子域名"
    SUBSCRIPTION_DOMAIN=${domain}
}

collect_worker_source_domain() {
    local prompt_options=${1:-1} domain=${SUB_SOURCE_DOMAIN:-}
    [[ "${PREVIOUS_SUBSCRIPTION_MODE:-}" == "worker" ]] || domain=""
    if [[ "${prompt_options}" == "1" && -t 0 ]]; then
        domain=$(prompt_value \
            "私有节点源域名（Cloudflare 代理到本机，仅供 Worker 回源；必须与公开域名不同）" "${domain}")
    fi
    [[ -n "${domain}" ]] \
        || die "Worker 订阅聚合必须设置 SUB_SOURCE_DOMAIN"
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUB_SOURCE_DOMAIN 无效：${domain}"
    [[ "${domain}" != "${SUBSCRIPTION_DOMAIN}" ]] \
        || die "私有节点源域名不能与 Worker 公开订阅域名相同"
    [[ "${domain}" != "${NODE_HOST:-}" ]] \
        || die "私有节点源域名不能与 Reality 直连节点域名相同"
    SUB_SOURCE_DOMAIN=${domain}
}

validate_worker_aggregation_node_names() {
    local name empty_aggregation='{"nodes":[],"fallbackCdnNodes":[]}'
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        [[ "${name}" != "${NODE_NAME}" ]] \
            || die "Worker 聚合配置中的节点名与本地 Reality 节点名重复：${name}；请改用不重复的名称"
    done < <(jq -r '.nodes[]?.name // empty' \
        <<<"${WORKER_AGGREGATION_CONFIG:-${empty_aggregation}}")
}

collect_worker_subscription_inputs() {
    local prompt_options=${1:-1} prompt_download_name=${2:-0}
    local WORKER_AGGREGATION_QUESTION="是否写入其他直连节点的聚合 JSON（另外两台节点的信息）？"
    collect_worker_public_domain "${prompt_options}"
    collect_worker_source_domain "${prompt_options}"
    if [[ "${prompt_options}" == "1" ]]; then
        choose_cloudflare_worker_name
        NODE_NAME=$(prompt_value \
            "本机节点名称（聚合后作为客户端展示名，必须与其他节点不同）" \
            "${NODE_NAME}")
    else
        validate_cloudflare_worker_name "${CLOUDFLARE_WORKER_NAME:-}" \
            || die "Worker 名称无效：${CLOUDFLARE_WORKER_NAME:-空}"
    fi
    choose_subscription_download_name "${prompt_download_name}"
    if [[ "${prompt_options}" == "1" ]]; then
        choose_monthly_quota 1
    fi
    quota_enabled || ensure_allowed_tokens "${prompt_options}"
    WORKER_SOURCE_SECRET=${WORKER_SOURCE_SECRET:-$(generate_secret)}
    [[ "${WORKER_SOURCE_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "WORKER_SOURCE_SECRET 格式无效"
    if [[ "${prompt_options}" == "1" ]]; then
        choose_worker_aggregation_config
    else
        WORKER_AGGREGATION_CONFIG=$(normalize_worker_aggregation_config \
            "${WORKER_AGGREGATION_CONFIG:-}" | jq -c 'del(.allowedTokens)') \
            || die "Worker 聚合配置无效；请执行 sudo easy_all update-sub 重新配置"
    fi
    validate_worker_aggregation_node_names
    SUBSCRIPTION_MODE="worker"
}

collect_link_subscription_inputs() {
    SUBSCRIPTION_MODE="link"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    ALLOWED_TOKENS=""
    reset_worker_subscription_inputs
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
    worker)
        collect_worker_subscription_inputs \
            "${prompt_options}" "${prompt_download_name}"
        ;;
    link) collect_link_subscription_inputs ;;
    *) die "无法收集未知订阅输出方式：${SUBSCRIPTION_MODE:-空}" ;;
    esac
}

reality_worker_source_url() {
    printf 'https://%s:%s/subscribe' \
        "${SUB_SOURCE_DOMAIN}" "${SUBSCRIPTION_HTTPS_PORT}"
}

ensure_reality_worker_builder() {
    local major
    if ! command -v node >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends nodejs \
            || die "安装 Worker 构建依赖 nodejs 失败"
    fi
    major=$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true)
    [[ "${major}" =~ ^[0-9]+$ && "${major}" -ge 18 ]] \
        || die "Worker 构建需要 Node.js 18 或更高版本"
}

reality_worker_build() {
    local config aggregation build_output
    [[ -s "${CLOUDFLARE_WORKER_SOURCE_FILE}" ]] \
        || die "缺少 Worker 运行源码：${CLOUDFLARE_WORKER_SOURCE_FILE}"
    [[ -s "${CLOUDFLARE_WORKER_BUILD_SCRIPT}" ]] \
        || die "缺少 Worker 构建脚本：${CLOUDFLARE_WORKER_BUILD_SCRIPT}"
    ensure_reality_worker_builder
    prepare_mihomo_template
    aggregation=$(normalize_worker_aggregation_config \
        "${WORKER_AGGREGATION_CONFIG:-}") \
        || die "Worker 聚合配置无效"
    config=$(jq -cn \
        --argjson aggregation "${aggregation}" \
        --arg source_url "$(reality_worker_source_url)" \
        --arg source_secret "${WORKER_SOURCE_SECRET}" \
        --arg download_name "${SUB_DOWNLOAD_NAME}" '{
          allowedTokens:{},
          nodes:$aggregation.nodes,
          vpsSubUrl:$source_url,
          vpsCdnUseRequestToken:true,
          delegateTokenValidation:true,
          requireDynamicCdn:true,
          sourceSecret:$source_secret,
          fallbackCdnNodes:$aggregation.fallbackCdnNodes,
          subscriptionDownloadName:$download_name
        }')
    printf '%s\n' "${config}" >"${RUNTIME_TMP}/reality-worker-config.json"
    chmod 0600 "${RUNTIME_TMP}/reality-worker-config.json"
    install -d -m 0700 "$(dirname "${CLOUDFLARE_WORKER_BUILD_FILE}")"
    build_output=$(
        EASY_ALL_WORKER_CONFIG_PATH="${RUNTIME_TMP}/reality-worker-config.json" \
        EASY_ALL_WORKER_OUTPUT_PATH="${CLOUDFLARE_WORKER_BUILD_FILE}" \
        EASY_ALL_WORKER_TEMPLATE_PATH="${MIHOMO_TEMPLATE_FILE}" \
        MIHOMO_TEMPLATE_TRUSTED="${MIHOMO_TEMPLATE_TRUSTED:-0}" \
        EASY_ALL_WORKER_SOURCE_PATH="${CLOUDFLARE_WORKER_SOURCE_FILE}" \
            node "${CLOUDFLARE_WORKER_BUILD_SCRIPT}"
    ) || die "Worker 构建失败"
    [[ -s "${CLOUDFLARE_WORKER_BUILD_FILE}" ]] \
        || die "Worker 构建未生成输出文件"
    chmod 0600 "${CLOUDFLARE_WORKER_BUILD_FILE}"
    info "${build_output}"
}

reality_worker_snapshot_deployment() {
    local name=$1 destination=$2 deployments
    [[ ! -s "${destination}" ]] || return 0
    deployments=$(reality_cloudflare_api_request GET \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${name}")/deployments") \
        || die "无法读取 Worker ${name} 当前部署，中止更新"
    jq -ce '
      .deployments[0].versions
      | select(type == "array" and length >= 1 and length <= 2)
      | select(all(.[];
          (.version_id | type) == "string"
          and (.version_id | test("^[0-9A-Fa-f-]{36}$"))
          and (.percentage | type) == "number"
          and .percentage > 0))
      | select((map(.percentage) | add) == 100)
      | {
          strategy:"percentage",
          versions:map({version_id,percentage}),
          annotations:{"workers/message":"easy_all automatic rollback"}
        }
    ' <<<"${deployments}" >"${destination}" \
        || die "Worker ${name} 当前部署信息无效，中止更新以避免无法回滚"
    chmod 0600 "${destination}"
}

reality_worker_restore_deployment() {
    local name=$1 source=$2
    [[ -s "${source}" ]] || return 1
    reality_cloudflare_api_request POST \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${name}")/deployments?force=true" \
        "$(<"${source}")" >/dev/null
}

reality_worker_validate_access() {
    local scripts domains count
    worker_subscription_enabled || return 0
    [[ "${CLOUDFLARE_ACCOUNT_ID:-}" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "Cloudflare Zone 未返回有效 Account ID"
    scripts=$(reality_cloudflare_api_request GET \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts") \
        || die "当前 Cloudflare Token 缺少 Account / Workers Scripts / Write 权限"
    count=$(jq --arg name "${CLOUDFLARE_WORKER_NAME}" \
        '[.[] | select(.id == $name)] | length' <<<"${scripts}")
    ((count <= 1)) || die "Cloudflare 返回多个同名 Worker：${CLOUDFLARE_WORKER_NAME}"
    CLOUDFLARE_WORKER_EXISTS=${count}
    if ((count == 1)); then
        [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" ]] \
            || die "Worker ${CLOUDFLARE_WORKER_NAME} 已存在且无本机所有权记录，拒绝覆盖"
        domains=$(reality_cloudflare_api_request GET \
            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains") \
            || die "无法验证 Worker ${CLOUDFLARE_WORKER_NAME} 的自定义域名所有权"
        jq -e --arg id "${CLOUDFLARE_WORKER_DOMAIN_ID}" \
            --arg service "${CLOUDFLARE_WORKER_NAME}" \
            'any(.[]; .id == $id and .service == $service)' \
            <<<"${domains}" >/dev/null \
            || die "Worker ${CLOUDFLARE_WORKER_NAME} 所有权记录与 Cloudflare 不一致，拒绝覆盖"
        reality_worker_snapshot_deployment "${CLOUDFLARE_WORKER_NAME}" \
            "${RUNTIME_TMP}/reality-worker-deployment-prev.json"
        info "复用 Worker ${CLOUDFLARE_WORKER_NAME}，将更新订阅脚本"
    fi
    if [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" && "${count}" != "1" ]]; then
        die "状态中的 Worker ${CLOUDFLARE_WORKER_NAME} 不存在：Worker 名称不能在 update-sub 中就地修改，请改回原名称或重新安装"
    fi
}

reality_worker_upload() {
    local script metadata headers response path
    script="${CLOUDFLARE_WORKER_BUILD_FILE}"
    metadata="${RUNTIME_TMP}/reality-worker-metadata.json"
    headers="${RUNTIME_TMP}/reality-cloudflare-worker-api-headers"
    [[ -s "${script}" ]] || die "缺少已构建的 Worker 文件"
    jq -n \
        --arg date "${CLOUDFLARE_WORKER_COMPATIBILITY_DATE}" '{
          main_module:"worker.js",
          compatibility_date:$date,
          compatibility_flags:["global_fetch_strictly_public"]
        }' >"${metadata}"
    printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}" "${metadata}"
    path="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${CLOUDFLARE_WORKER_NAME}")"
    response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 60 \
        -X PUT -H "@${headers}" \
        -F "metadata=@${metadata};type=application/json" \
        -F "worker.js=@${script};type=application/javascript+module" \
        "${CLOUDFLARE_API_BASE}${path}") \
        || die "Cloudflare API 请求失败：PUT ${path}"
    jq -e '.success == true' <<<"${response}" >/dev/null \
        || {
            printf '%s\n' "${response:-<empty>}" >&2
            die "Cloudflare Worker 上传失败：PUT ${path}；请根据上方 Cloudflare API 错误码和消息排查"
        }
    if [[ "${CLOUDFLARE_WORKER_EXISTS:-1}" == "0" ]]; then
        CLOUDFLARE_WORKER_CREATED=1
    fi
}

reality_worker_attach_domain() {
    local domains matches count existing_service result records type
    domains=$(reality_cloudflare_api_request GET \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains") \
        || die "无法读取 Worker 自定义域名列表"
    matches=$(jq -c --arg host "${SUBSCRIPTION_DOMAIN}" \
        '[.[] | select((.hostname | ascii_downcase) == $host)]' <<<"${domains}")
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Cloudflare 中存在多个订阅 Worker 自定义域名：${SUBSCRIPTION_DOMAIN}"
    if ((count == 1)); then
        existing_service=$(jq -r '.[0].service // empty' <<<"${matches}")
        [[ "${existing_service}" == "${CLOUDFLARE_WORKER_NAME}" ]] \
            || die "订阅域名 ${SUBSCRIPTION_DOMAIN} 已绑定到其他 Worker：${existing_service}"
        CLOUDFLARE_WORKER_DOMAIN_ID=$(jq -r '.[0].id // empty' <<<"${matches}")
        [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID}" ]] \
            || die "Cloudflare Worker 自定义域名缺少 ID"
        return 0
    fi
    for type in A AAAA CNAME; do
        records=$(reality_cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" \
            "${type}" "${SUBSCRIPTION_DOMAIN}")
        [[ "$(jq 'length' <<<"${records}")" == "0" ]] \
            || die "订阅域名 ${SUBSCRIPTION_DOMAIN} 已有 ${type} 记录；拒绝由 Worker Custom Domain 接管"
    done
    result=$(reality_cloudflare_api_request PUT \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" \
        "$(jq -cn --arg host "${SUBSCRIPTION_DOMAIN}" \
            --arg service "${CLOUDFLARE_WORKER_NAME}" \
            --arg zone_id "${CLOUDFLARE_ZONE_ID}" \
            --arg zone_name "${CLOUDFLARE_ZONE_NAME}" \
            '{hostname:$host,service:$service,zone_id:$zone_id,zone_name:$zone_name}')")
    CLOUDFLARE_WORKER_DOMAIN_ID=$(jq -r '.id // empty' <<<"${result}")
    [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID}" ]] \
        || die "Cloudflare 未返回 Worker 自定义域名 ID"
    CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=${CLOUDFLARE_WORKER_DOMAIN_ID}
}

reality_worker_detach_domain() {
    local account_id=$1 domain_id=$2 service=$3 domains
    [[ -n "${account_id}" && -n "${domain_id}" ]] || return 0
    domains=$(reality_cloudflare_api_request GET \
        "/accounts/${account_id}/workers/domains") || return 1
    jq -e --arg id "${domain_id}" --arg service "${service}" \
        'any(.[]; .id == $id and .service == $service)' <<<"${domains}" >/dev/null \
        || return 0
    reality_cloudflare_api_request DELETE \
        "/accounts/${account_id}/workers/domains/${domain_id}" >/dev/null
}

reality_worker_deploy() {
    worker_subscription_enabled || return 0
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" && -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
        || die "Worker 聚合需要先完成 Cloudflare 回源域名、Origin CA 与 Strict TLS 配置"
    CLOUDFLARE_WORKER_CREATED=0
    CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=""
    rm -f -- "${RUNTIME_TMP}/reality-worker-deployment-prev.json"
    [[ "${SUBSCRIPTION_DOMAIN}" == *."${CLOUDFLARE_ZONE_NAME}" ]] \
        || die "Worker 公开订阅域名必须与私有节点源域名位于同一 Cloudflare Zone"
    local public_prefix=${SUBSCRIPTION_DOMAIN%.${CLOUDFLARE_ZONE_NAME}}
    [[ -n "${public_prefix}" && "${public_prefix}" != *.* ]] \
        || die "Worker 公开订阅域名必须是 Zone 下一级子域名"
    reality_worker_validate_access
    reality_worker_build
    reality_worker_upload
    reality_cloudflare_api_request POST \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${CLOUDFLARE_WORKER_NAME}")/subdomain" \
        "$(jq -cn '{enabled:false,previews_enabled:false}')" >/dev/null
    reality_worker_attach_domain
    reality_worker_validate_public
}

reality_worker_delete_resources() {
    local domain_id=${1-${CLOUDFLARE_WORKER_DOMAIN_ID:-}} \
        worker_name=${2-${CLOUDFLARE_WORKER_NAME:-}} \
        account_id=${3-${CLOUDFLARE_ACCOUNT_ID:-}} \
        domains="" scripts="" extra_domains
    if [[ -n "${worker_name}" && -n "${account_id}" ]]; then
        domains=$(reality_cloudflare_api_request GET \
            "/accounts/${account_id}/workers/domains") || return 1
        extra_domains=$(jq --arg name "${worker_name}" --arg id "${domain_id}" \
            '[.[] | select(.service == $name and .id != $id)] | length' <<<"${domains}")
        ((extra_domains == 0)) \
            || die "Worker ${worker_name} 还绑定了非本安装管理的 Custom Domain，拒绝删除"
    fi
    if [[ -n "${domain_id}" && -n "${domains}" ]]; then
        if jq -e --arg id "${domain_id}" \
            'any(.[]; .id == $id)' <<<"${domains}" >/dev/null; then
            jq -e --arg id "${domain_id}" --arg name "${worker_name}" \
                'any(.[]; .id == $id and .service == $name)' <<<"${domains}" >/dev/null \
                || die "Worker Custom Domain 所有权与状态不一致，拒绝删除"
            reality_cloudflare_api_request DELETE \
                "/accounts/${account_id}/workers/domains/${domain_id}" >/dev/null \
                || return 1
        fi
    fi
    if [[ -n "${worker_name}" && -n "${account_id}" ]]; then
        scripts=$(reality_cloudflare_api_request GET \
            "/accounts/${account_id}/workers/scripts") || return 1
        if jq -e --arg name "${worker_name}" \
            'any(.[]; .id == $name)' <<<"${scripts}" >/dev/null; then
            reality_cloudflare_api_request DELETE \
                "/accounts/${account_id}/workers/scripts/$(uri_encode "${worker_name}")" >/dev/null \
                || return 1
        fi
    fi
}

reality_worker_rollback_created() {
    local failed=0
    if [[ "${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID:-}" != "" ]]; then
        reality_cloudflare_api_request DELETE \
            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID}" \
            >/dev/null || failed=1
    fi
    if [[ -s "${RUNTIME_TMP}/reality-worker-deployment-prev.json" ]] \
        && [[ -n "${CLOUDFLARE_WORKER_NAME:-}" && "${CLOUDFLARE_WORKER_CREATED:-0}" != "1" ]]; then
        reality_worker_restore_deployment "${CLOUDFLARE_WORKER_NAME}" \
            "${RUNTIME_TMP}/reality-worker-deployment-prev.json" || failed=1
    fi
    if [[ "${CLOUDFLARE_WORKER_CREATED:-0}" == "1" ]]; then
        reality_worker_delete_resources \
            "${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID:-${CLOUDFLARE_WORKER_DOMAIN_ID:-}}" \
            "${CLOUDFLARE_WORKER_NAME:-}" "${CLOUDFLARE_ACCOUNT_ID:-}" || failed=1
    fi
    rm -f -- "${RUNTIME_TMP}/reality-worker-deployment-prev.json"
    CLOUDFLARE_WORKER_CREATED=0
    CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=""
    ((failed == 0))
}

reality_worker_validate_public() {
    local attempt token="" status decoded clash_response accounts uuid first_aggregate
    worker_subscription_enabled || return 0
    [[ -n "${SUBSCRIPTION_DOMAIN:-}" ]] || die "缺少 Worker 公开订阅域名"
    for attempt in $(seq 1 "${CLOUDFLARE_WORKER_READY_ATTEMPTS}"); do
        status=$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 20 \
            -o /dev/null -w '%{http_code}' \
            "https://${SUBSCRIPTION_DOMAIN}/subscribe?token=invalid") || status="000"
        [[ "${status}" != "403" ]] || break
        sleep "${CLOUDFLARE_WORKER_READY_INTERVAL}"
    done
    [[ "${status}" == "403" ]] \
        || die "Worker 未按预期拒绝无效 Token（HTTP ${status}）；请检查 Cloudflare Worker、Custom Domain 与 TLS 状态"
    if quota_enabled; then
        accounts=$(quota_active_accounts_json) || die "读取配额用户失败"
        token=$(jq -r 'first(.[].token) // empty' <<<"${accounts}")
        uuid=$(jq -r 'first(.[].uuid) // empty' <<<"${accounts}")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过 Worker 订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
        uuid=${VLESS_UUID}
    fi
    decoded=""
    for attempt in $(seq 1 "${CLOUDFLARE_WORKER_READY_ATTEMPTS}"); do
        decoded=$(printf '%s' "${token}" | curl -fsS --noproxy '*' \
            --connect-timeout 5 --max-time 20 \
            --get --data-urlencode 'token@-' \
            "https://${SUBSCRIPTION_DOMAIN}/subscribe" 2>/dev/null \
            | openssl base64 -d -A 2>/dev/null || true)
        if [[ "${decoded}" == *"security=reality"* && "${decoded}" == *"vless://${uuid}@"* ]]; then
            break
        fi
        sleep "${CLOUDFLARE_WORKER_READY_INTERVAL}"
    done
    [[ "${decoded}" == *"security=reality"* ]] \
        || die "Worker 聚合订阅未返回 Reality 节点；请检查私有节点源与 Worker 日志"
    [[ "${decoded}" == *"vless://${uuid}@"* ]] \
        || die "Worker 聚合订阅缺少本机 Reality 节点；请检查私有节点源与配额用户"
    clash_response=$(printf '%s' "${token}" | curl -fsS --noproxy '*' \
        --connect-timeout 5 --max-time 20 --get --data-urlencode 'token@-' \
        --data-urlencode 'flag=clash' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") \
        || die "Worker Mihomo 订阅验收失败"
    grep -Fq 'reality-opts:' <<<"${clash_response}" || die "Worker Mihomo 订阅缺少 Reality 节点"
    grep -Fq -- "${NODE_NAME}" <<<"${clash_response}" \
        || die "Worker Mihomo 订阅缺少本机节点名称"
    if jq -e '.nodes | length > 0' \
        <<<"${WORKER_AGGREGATION_CONFIG:-{\"nodes\":[]}}" >/dev/null; then
        first_aggregate=$(jq -r '.nodes[0].name' \
            <<<"${WORKER_AGGREGATION_CONFIG}" 2>/dev/null || true)
        [[ -z "${first_aggregate}" ]] \
            || grep -Fq -- "${first_aggregate}" <<<"${clash_response}" \
            || die "Worker Mihomo 订阅缺少聚合节点：${first_aggregate}"
    fi
    success "Cloudflare Worker 订阅聚合公网验收通过"
}

deploy_subscription_service() {
    install_subscription_dependencies || return 1
    install_reality_subscription_renderer || return 1
    reality_cloudflare_prepare_subscription
    reality_cloudflare_issue_origin_certificate 0
    reality_cloudflare_configure_strict_tls
    write_subscription_bootstrap_nginx
    install_static_subscriptions || return 1
    write_subscription_nginx_config || return 1
    validate_subscription_runtime || return 1
    reality_cloudflare_validate_public_subscription
}

remove_subscription_service_runtime() {
    if [[ -f "${NGINX_CONFIG}" || -d "${WEB_ROOT}" ]]; then
        systemctl disable --now nginx >/dev/null 2>&1 || true
        rm -f -- "${NGINX_CONFIG}"
        rm -rf -- "${WEB_ROOT}"
    fi
    rm -f -- "${REALITY_SUBSCRIPTION_JS}"
}

deploy_subscription_output() {
    case "${SUBSCRIPTION_MODE:-}" in
    deploy) deploy_subscription_service ;;
    worker)
        deploy_subscription_service
        reality_worker_deploy
        ;;
    link) remove_subscription_service_runtime ;;
    *) die "无法部署未知订阅输出方式：${SUBSCRIPTION_MODE:-空}" ;;
    esac
}

renew_subscription_certificate() {
    require_root
    collect_installed_state
    subscription_enabled || die "当前未启用自托管订阅"
    reality_cloudflare_prepare_subscription
    reality_cloudflare_issue_origin_certificate 1
    reality_cloudflare_configure_strict_tls
    nginx -t >/dev/null || die "Cloudflare 新源站证书安装后 Nginx 校验失败"
    systemctl reload nginx || systemctl restart nginx \
        || die "Cloudflare 新源站证书安装后 Nginx 重载失败"
    validate_subscription_runtime
    reality_cloudflare_validate_public_subscription
    reality_cloudflare_finalize_certificate_rotation
    save_state
    reality_cloudflare_clear_api_token
    success "Cloudflare Origin CA 订阅证书已轮换"
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
    if [[ -f "${REALITY_SUBSCRIPTION_JS}" ]]; then
        install -m 0600 "${REALITY_SUBSCRIPTION_JS}" "${UPDATE_SUB_BACKUP_DIR}/reality-subscription.js"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/reality-subscription.js.missing"
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
    local candidate rollback_status=0
    warn "本机配置更新失败，正在恢复服务端配置、订阅文件、端口模式和 UFW"
    if declare -F reality_worker_rollback_created >/dev/null 2>&1; then
        (reality_worker_rollback_created) \
            || warn "回滚本次新建的 Worker 资源失败，请手工检查 Cloudflare"
    fi
    restore_state_file "${UPDATE_SUB_BACKUP_DIR}/state.env" "${STATE_FILE}"
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/runtime-config.json" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/runtime-config.json" \
            "${XRAY_CONFIG}"
        systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 \
            || warn "恢复订阅更新前 ${XRAY_SERVICE} 失败"
    else
        rm -f -- "${XRAY_CONFIG}"
    fi
    # Isolate fatal asset errors so firewall and port-mode recovery can still run.
    if (
        restore_cleanup_count=${#cleanup_files[@]}
        trap 'for ((i=restore_cleanup_count; i<${#cleanup_files[@]}; i++)); do
            rm -f -- "${cleanup_files[i]}"
        done' EXIT
        if [[ -f "${UPDATE_SUB_BACKUP_DIR}/reality-subscription.js" ]]; then
            install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/reality-subscription.js" "${REALITY_SUBSCRIPTION_JS}" \
                || { warn "恢复订阅渲染脚本失败"; return 1; }
        elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/reality-subscription.js.missing" ]]; then
            rm -f -- "${REALITY_SUBSCRIPTION_JS}" || return 1
        fi
        if [[ -d "${UPDATE_SUB_BACKUP_DIR}/subscriptions" ]]; then
            publish_subscription_files "${UPDATE_SUB_BACKUP_DIR}/subscriptions" || return 1
        else
            rm -rf -- "${SUBSCRIPTION_DIR}"
        fi
        if [[ -f "${UPDATE_SUB_BACKUP_DIR}/fullchain.pem" ]]; then
            install -d -m 0700 "${CERT_DIR}"
            install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/fullchain.pem" "${CERT_FILE}" || return 1
            install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/private.key" "${KEY_FILE}" || return 1
        fi
        if [[ -f "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" ]]; then
            candidate=$(mktemp "${NGINX_CONFIG}.XXXXXX") || return 1
            cleanup_files+=("${candidate}")
            install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" "${candidate}" || return 1
            mv -f -- "${candidate}" "${NGINX_CONFIG}" || return 1
        else
            rm -f -- "${NGINX_CONFIG}"
        fi
        if [[ -f "${NGINX_CONFIG}" ]]; then
            nginx -t >/dev/null 2>&1 \
                && systemctl enable --now nginx >/dev/null 2>&1 \
                && systemctl reload nginx >/dev/null 2>&1 \
                || { warn "恢复订阅配置后 Nginx 校验或重载失败"; return 1; }
        elif command -v nginx >/dev/null 2>&1; then
            nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 \
                || { warn "恢复 Nginx 配置失败"; return 1; }
        fi
    ); then
        :
    else
        rollback_status=1
        warn "订阅资产或 Nginx 恢复失败，继续恢复端口模式、定时任务和 UFW"
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
        "${UPDATE_SUB_BACKUP_DIR}/root.crontab" \
        || { warn "恢复订阅更新前定时任务失败"; rollback_status=1; }
    configure_ufw || { warn "恢复订阅更新前 UFW 失败"; rollback_status=1; }
    return "${rollback_status}"
}

update_subscription() {
    local prompt_options=${1:-0}
    local requested_port_mode=${SUB_PORT_MODE:-}
    local requested_download_name=${SUB_DOWNLOAD_NAME:-} stored_port_mode
    local prompt_download_name=0 previous_subscription_mode previous_origin_domain
    local previous_cloudflare_zone_id previous_cloudflare_ruleset_id previous_cloudflare_cert_id
    local previous_worker_name previous_worker_domain_id previous_account_id
    local current_origin_domain PREVIOUS_SUBSCRIPTION_MODE
    require_root
    begin_quota_maintenance
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    stored_port_mode=$(
        unset SUB_PORT_MODE
        source_state_file
        printf '%s' "${SUB_PORT_MODE:-$(protocol_default_port_mode)}"
    )
    collect_installed_state
    previous_subscription_mode=${SUBSCRIPTION_MODE}
    PREVIOUS_SUBSCRIPTION_MODE=${previous_subscription_mode}
    previous_origin_domain=$(subscription_origin_domain)
    previous_cloudflare_zone_id=${CLOUDFLARE_ZONE_ID:-}
    previous_cloudflare_ruleset_id=${CLOUDFLARE_STRICT_RULESET_ID:-}
    previous_cloudflare_cert_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    previous_worker_name=${CLOUDFLARE_WORKER_NAME:-}
    previous_worker_domain_id=${CLOUDFLARE_WORKER_DOMAIN_ID:-}
    previous_account_id=${CLOUDFLARE_ACCOUNT_ID:-}
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
    if [[ "${prompt_options}" == "1" ]]; then
        choose_google_egress_mode
    else
        refresh_google_egress_selection
    fi
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
    reality_cloudflare_finalize_certificate_rotation
    save_state
    configure_dynamic_port_rotation
    install_quota_timer
    # The new deployment is live and persisted: cleanup failures below must not
    # roll the machine back to a state whose cloud resources are already gone.
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    current_origin_domain=$(subscription_origin_domain)
    if [[ "${previous_subscription_mode}" != "link" \
        && ( "${SUBSCRIPTION_MODE}" == "link" \
            || "${current_origin_domain}" != "${previous_origin_domain}" ) ]]; then
        if [[ "${SUBSCRIPTION_MODE}" != "link" ]]; then
            reality_cloudflare_purge_managed_resources \
                "${previous_origin_domain}" "${previous_cloudflare_zone_id}" \
                "${previous_cloudflare_ruleset_id}" ""
            info "已清理上一订阅回源域名的 Cloudflare Strict TLS 规则与 DNS：${previous_origin_domain}"
        else
            reality_cloudflare_purge_managed_resources \
                "${previous_origin_domain}" "${previous_cloudflare_zone_id}" \
                "${previous_cloudflare_ruleset_id}" "${previous_cloudflare_cert_id}"
        fi
    fi
    if [[ "${previous_subscription_mode}" == "worker" ]]; then
        if [[ "${SUBSCRIPTION_MODE}" != "worker" \
            || "${CLOUDFLARE_WORKER_NAME:-}" != "${previous_worker_name}" ]]; then
            reality_worker_delete_resources "${previous_worker_domain_id}" \
                "${previous_worker_name}" "${previous_account_id}"
        elif [[ "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" != "${previous_worker_domain_id}" ]]; then
            reality_worker_detach_domain "${previous_account_id}" \
                "${previous_worker_domain_id}" "${previous_worker_name}"
        fi
    fi
    if [[ "${SUBSCRIPTION_MODE}" == "link" ]]; then
        CLOUDFLARE_ZONE_ID=""
        CLOUDFLARE_ZONE_NAME=""
        CLOUDFLARE_ACCOUNT_ID=""
        CLOUDFLARE_ORIGIN_CERT_ID=""
        CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=""
        CLOUDFLARE_STRICT_RULESET_ID=""
        SUB_SOURCE_DOMAIN=""
        CLOUDFLARE_WORKER_NAME=""
        CLOUDFLARE_WORKER_DOMAIN_ID=""
        WORKER_SOURCE_SECRET=""
        WORKER_AGGREGATION_CONFIG='{"nodes":[],"fallbackCdnNodes":[]}'
        save_state
    fi
    reality_cloudflare_clear_api_token
    end_quota_maintenance
    show_subscription
}

apply_easy_all() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    info "应用 TCP 加速并刷新 TCP 参数"
    configure_tcp_acceleration
    configure_ipv4_only
    register_easy_all_command
    update_subscription
    end_quota_maintenance
}

update_reality_target() {
    (($# <= 1)) || die "用法：easy_all reality-target [域名:端口]"
    local current requested
    require_root
    begin_quota_maintenance
    collect_installed_state
    current=${REALITY_TARGET}
    requested=${1:-}
    if [[ -z "${requested}" ]]; then
        [[ -t 0 ]] || die "非交互模式请指定：easy_all reality-target <域名:端口>"
        info "当前 Reality SNI / 伪装目标：${current}"
        requested=$(prompt_value \
            "新的 Reality SNI / 伪装目标（域名:端口）" "${current}")
    fi
    validate_reality_target "${requested}" \
        || die "Reality 目标无效，需为 域名:端口：${requested}"
    requested="$(normalize_domain "${requested%:*}"):${requested##*:}"
    # Never republish the subscriptions here: a failed state write can leave the runtime ahead
    # of the state file, and republishing would push the stale target to clients.
    if [[ "${requested}" == "${current}" ]]; then
        info "Reality 目标未变化：${current}"
        if subscription_enabled; then
            info "如需重新下发订阅（例如上次重发中断），执行 sudo easy_all apply"
        fi
        end_quota_maintenance
        return 0
    fi
    REALITY_TARGET=${requested}
    # Validate and restart before persisting: a failed handshake restores the old runtime
    # config inside refresh_protocol_runtime_config, so the state file must keep matching it.
    refresh_protocol_runtime_config
    # Persist as soon as the new target is live: a failed republication must not leave the
    # state file on the previous SNI while Xray already serves the new one. The second save
    # persists the Mihomo template snapshot written by the republication.
    save_state
    if subscription_enabled; then
        install_static_subscriptions
        save_state
    fi
    end_quota_maintenance
    success "Reality 目标已更新：${current} → ${REALITY_TARGET}"
    show_node
    info "客户端需刷新订阅或重新导入节点；使用聚合配置下发的还需同步聚合配置里的 sni"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    load_state
    validate_protocol "${PROTOCOL:-}" || die "状态文件中的 PROTOCOL 无效"
    [[ -n "${NODE_HOST:-}" && -n "${VLESS_UUID:-}" \
        && -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" \
        && -n "${REALITY_SHORT_ID:-}" ]] \
        || die "Reality 状态不完整"
}

refresh_runtime_subscription() {
    subscription_enabled || return 0
    install_static_subscriptions
    save_state
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
        write_xray_config || exit 1
        write_subscription_nginx_config || exit 1
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
    local port
    collect_installed_state
    if quota_enabled; then
        printf '\n配额已启用：owner 凭据为不限量账号，请使用 show_subscription 输出的各用户订阅地址，避免分发 owner 节点绕过配额。\n\n'
        return 0
    fi
    port=$(generate_subscription_port)
    printf '\n协议: %s\n节点链接:\n%s\n\n' \
        "${PROTOCOL}" "$(build_node_link "${port}")"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node "${port}"
    printf '\n'
}

show_subscription() {
    local user token aggregation_count=0 empty_aggregation='{"nodes":[],"fallbackCdnNodes":[]}'
    collect_installed_state
    show_node
    printf 'Clash 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
    if worker_subscription_enabled; then
        [[ -n "${ALLOWED_TOKENS:-}" ]] || die "Worker 聚合订阅 Token 字典缺失"
        aggregation_count=$(jq '.nodes | length' \
            <<<"${WORKER_AGGREGATION_CONFIG:-${empty_aggregation}}")
        printf '订阅方式: Cloudflare Worker 聚合（Nginx 私有源 :%s 仅供回源）\n' \
            "${SUBSCRIPTION_HTTPS_PORT}"
        printf 'Worker: %s\n私有节点源: https://%s:%s/subscribe（请勿直接分发）\n' \
            "${CLOUDFLARE_WORKER_NAME}" "${SUB_SOURCE_DOMAIN}" \
            "${SUBSCRIPTION_HTTPS_PORT}"
        printf '聚合配置额外节点: %s\n' "${aggregation_count}"
        printf '\n订阅地址:\n'
        while IFS=$'\t' read -r user token; do
            printf '通用订阅 (%s): https://%s/subscribe?token=%s\n' \
                "${user}" "${SUBSCRIPTION_DOMAIN}" "${token}"
            printf 'Mihomo (%s): https://%s/subscribe?token=%s&flag=clash\n' \
                "${user}" "${SUBSCRIPTION_DOMAIN}" "${token}"
        done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${ALLOWED_TOKENS}")
        printf '\n'
        return 0
    fi
    if subscription_enabled; then
        [[ -n "${ALLOWED_TOKENS:-}" ]] || die "自托管订阅 Token 字典缺失"
        printf '订阅方式: Cloudflare Universal SSL → Origin CA :%s\n' \
            "${SUBSCRIPTION_HTTPS_PORT}"
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
    show_tcp_acceleration_status
    printf 'VPS 网络栈: IPv4-only（IPv6 全局禁用）\n'
    printf 'Google 出站: %s\n' "$(google_egress_status)"
    resolve_reality_client_ip_family
    printf 'Reality 客户端节点族: %s（固定）\n' \
        "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    printf '节点: %s\nReality 目标: %s\n' "${NODE_HOST}" "${REALITY_TARGET}"
    printf '核心服务: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'TCP 443: '
    ss -H -ltn "sport = :443" 2>/dev/null \
        | awk 'NR {found=1} END {exit !found}' \
        && printf 'listening\n' || printf 'not listening\n'
    if subscription_enabled; then
        if worker_subscription_enabled; then
            printf '订阅聚合: https://%s/subscribe（Worker %s）\n' \
                "${SUBSCRIPTION_DOMAIN}" "${CLOUDFLARE_WORKER_NAME}"
            printf '私有节点源: https://%s:%s/subscribe（仅供 Worker 回源）\n' \
                "${SUB_SOURCE_DOMAIN}" "${SUBSCRIPTION_HTTPS_PORT}"
        else
            printf '自托管订阅: https://%s:%s/subscribe\n' \
                "${SUBSCRIPTION_DOMAIN}" "${SUBSCRIPTION_HTTPS_PORT}"
        fi
        printf 'Cloudflare Origin CA 到期: %s\n' \
            "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}"
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

reality_cloudflare_purge_managed_resources() {
    local host=$1 zone_id=$2 ruleset_id=$3 cert_id=$4
    local rules matches count rule_id records dns_id comment ref
    [[ -n "${host}" && -n "${zone_id}" ]] || return 0
    reality_cloudflare_collect_api_token
    if [[ -n "${ruleset_id}" ]]; then
        rules=$(reality_cloudflare_api_request GET \
            "/zones/${zone_id}/rulesets/${ruleset_id}")
        ref=$(reality_cloudflare_ref "reality-strict:${host}")
        matches=$(jq -c --arg ref "${ref}" '[.rules[]? | select(.ref==$ref)]' <<<"${rules}")
        count=$(jq length <<<"${matches}")
        ((count <= 1)) || die "Cloudflare 中存在多个受管 Reality Strict TLS 规则，拒绝删除"
        if ((count == 1)); then
            rule_id=$(jq -r '.[0].id // empty' <<<"${matches}")
            [[ -n "${rule_id}" ]] || die "Cloudflare Reality Strict TLS 规则缺少 ID"
            reality_cloudflare_api_request DELETE \
                "/zones/${zone_id}/rulesets/${ruleset_id}/rules/${rule_id}" >/dev/null
        fi
    fi
    records=$(reality_cloudflare_api_request GET \
        "/zones/${zone_id}/dns_records?type=A&name=${host}&per_page=100")
    count=$(jq length <<<"${records}")
    ((count <= 1)) || die "Cloudflare 订阅域名 ${host} 有多个 A 记录，拒绝删除"
    if ((count == 1)); then
        dns_id=$(jq -r '.[0].id // empty' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        if [[ -n "${dns_id}" && "${comment}" == "easy_all reality subscription origin" ]]; then
            reality_cloudflare_api_request DELETE \
                "/zones/${zone_id}/dns_records/${dns_id}" >/dev/null
        else
            info "Cloudflare DNS ${host} 不属于 easy_all，予以保留"
        fi
    fi
    if [[ -n "${cert_id}" ]]; then
        reality_cloudflare_api_request DELETE "/certificates/${cert_id}" >/dev/null \
            || die "Cloudflare Origin CA 证书吊销失败；本机状态仍保留"
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
    if [[ -f "${BACKUP_DIR}/pre-install-ufw.active" ]]; then
        ufw --force enable >/dev/null 2>&1 || true
        ufw reload >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-ufw.inactive" \
        || -f "${BACKUP_DIR}/pre-install-ufw.missing" ]]; then
        command -v ufw >/dev/null 2>&1 \
            && ufw --force disable >/dev/null 2>&1 || true
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

uninstall_all() {
    local mode=${1:-}
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
        local answer
        if [[ "${mode}" == "--purge-cloud" ]]; then
            read_bilingual \
                '删除本机内容以及 easy_all 托管的 Cloudflare 订阅 DNS、Strict TLS 规则和 Origin CA？[y/N]:' answer
        else
            read_bilingual \
                '删除 easy_all 本机服务、状态和备份（保留 Cloudflare 资源）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    # 必须读磁盘真值：等待锁期间其他任务可能已改写模式/域名/Zone/证书/ruleset，
    # 普通 load_state 会回填等待前的内存值，导致漏删或错删 Cloudflare 资源。
    if [[ -f "${STATE_FILE}" ]]; then
        load_state --reload
    fi
    UNINSTALL_PURGE_CLOUD=0
    [[ "${mode}" == "--purge-cloud" ]] && UNINSTALL_PURGE_CLOUD=1
    if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 && "${SUBSCRIPTION_MODE:-}" != "link" ]]; then
        [[ -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]] \
            || die "状态缺少 Cloudflare Zone 或 Origin CA 证书 ID；本机内容未删除"
        if worker_subscription_enabled; then
            [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" && -n "${CLOUDFLARE_WORKER_NAME:-}" ]] \
                || die "状态缺少 Cloudflare Account ID 或 Worker 名称；本机内容未删除"
            reality_cloudflare_collect_api_token
            reality_worker_delete_resources "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" \
                "${CLOUDFLARE_WORKER_NAME}" "${CLOUDFLARE_ACCOUNT_ID}" \
                || die "Worker ${CLOUDFLARE_WORKER_NAME} 删除失败；本机内容未删除"
        fi
        reality_cloudflare_purge_managed_resources \
            "$(subscription_origin_domain)" "${CLOUDFLARE_ZONE_ID}" \
            "${CLOUDFLARE_STRICT_RULESET_ID:-}" "${CLOUDFLARE_ORIGIN_CERT_ID}"
    fi
    stop_protocol_services
    remove_quota_timer
    reality_cloudflare_remove_subscription_firewall_rules
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_bbr_tcp_install_state
    remove_daily_reboot_schedule
    remove_dynamic_port_rotation
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${REALITY_SUBSCRIPTION_JS}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}" "${WEB_ROOT}"
    if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
        success "easy_all 本机内容及托管的 Cloudflare Reality 订阅资源已卸载"
    else
        success "easy_all 本机内容已卸载；Cloudflare 资源已保留"
    fi
}

rollback_fresh_install() {
    warn "首次安装失败，正在恢复本机服务、UFW、crontab 与 BBR 配置"
    stop_protocol_services
    remove_quota_timer
    reality_cloudflare_remove_subscription_firewall_rules
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_bbr_tcp_install_state 1
    restore_preinstall_crontab
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ZONE_ID:-}" \
        && -n "${SUBSCRIPTION_DOMAIN:-}" ]]; then
        if worker_subscription_enabled; then
            (reality_worker_delete_resources \
                "${CLOUDFLARE_WORKER_DOMAIN_ID:-${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID:-}}" \
                "${CLOUDFLARE_WORKER_NAME:-}" "${CLOUDFLARE_ACCOUNT_ID:-}") \
                || warn "首次安装创建的 Worker 资源未能自动清理"
        fi
        (reality_cloudflare_purge_managed_resources \
            "$(subscription_origin_domain)" "${CLOUDFLARE_ZONE_ID}" \
            "${CLOUDFLARE_STRICT_RULESET_ID:-}" "${CLOUDFLARE_ORIGIN_CERT_ID:-}") \
            || warn "首次安装创建的 Cloudflare 资源未能自动清理"
    fi
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${REALITY_SUBSCRIPTION_JS}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}" "${WEB_ROOT}"
    warn "首次安装产生的服务数据已清理；本次新装且未运行的 XanMod 包已尝试移除"
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
        if ss -H -ltn "sport = :443" 2>/dev/null \
            | awk 'NR {found=1} END {exit !found}' \
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
    reality_cloudflare_finalize_certificate_rotation
    save_state
    register_easy_all_command
    configure_dynamic_port_rotation
    install_quota_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    reality_cloudflare_clear_api_token
    show_subscription
    show_tcp_acceleration_status
    success "easy_all ${PROTOCOL} 安装完成"
    prompt_bbrv3_reboot
}

install_all() {
    local requested=${1:-} prompt_download_name=0
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    [[ -n "${SUB_DOWNLOAD_NAME:-}" ]] || prompt_download_name=1
    run_reality_install_pipeline "${requested}" "${prompt_download_name}"
}
