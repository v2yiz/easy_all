#!/usr/bin/env bash

# Standalone installer for VLESS Reality Vision.

set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_FILE="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"

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
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly ACME_HOME="/root/.acme-easy_all.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-subscription-nginx.sh"
readonly UFW_BEFORE_RULES="/etc/ufw/before.rules"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly UFW_NAT_START="# easy_all-nat-start"
readonly UFW_NAT_END="# easy_all-nat-end"
readonly LEGACY_NFT_CONFIG="/etc/nftables.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-easy_all-bbr.conf"
readonly BBR_MODULES_CONFIG="/etc/modules-load.d/easy_all-bbr.conf"
readonly IPV6_SYSCTL_CONF="/etc/sysctl.d/99-enable-ipv6.conf"
readonly OLD_DISABLE_IPV6_CONF="/etc/sysctl.d/99-disable-ipv6.conf"
readonly SERVICE_PORT="443"
readonly SUBSCRIPTION_HTTPS_PORT="8443"
readonly PORT_BASE="10000"
readonly PORT_MULTIPLIER="6"
readonly DEFAULT_REALITY_TARGET="swdist.apple.com:443"
readonly DEFAULT_REALITY_PORT_MODE="dynamic"
readonly DEFAULT_REALITY_NODE_NAME="MY_REALITY"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/sample-mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly XRAY_ARCHIVE="Xray-linux-64.zip"
readonly XRAY_DGST="Xray-linux-64.zip.dgst"
readonly STATE_SCHEMA_VERSION="2"

# shellcheck source=lib/quota.sh
source "${SCRIPT_DIR}/quota.sh"

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
GEMINI_DOMAIN_SUFFIXES_JSON=""
GEMINI_IP_FAMILY_RESOLVED=""
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
    for path in "${cleanup_files[@]:-}"; do
        [[ -n "${path}" ]] && rm -rf -- "${path}"
    done
}
trap cleanup EXIT

make_temp_dir() {
    mktemp -d "${RUNTIME_TMP}/part.XXXXXX"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行此脚本"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "仅支持使用 systemd 的 Linux 系统"
    [[ -d /run/systemd/system ]] || die "当前系统未由 systemd 管理"
}

ensure_ssh_boot_service() {
    local sshd_bin unit
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    [[ -n "${sshd_bin}" ]] || die "未找到 sshd；无法保证重启后 SSH 可用"
    "${sshd_bin}" -t || die "sshd 配置校验失败；拒绝配置定时重启"

    for unit in ssh.service sshd.service; do
        systemctl cat "${unit}" >/dev/null 2>&1 || continue
        systemctl unmask "${unit}" >/dev/null 2>&1 || true
        systemctl enable --now "${unit}" >/dev/null \
            || die "无法启用 SSH 开机启动：${unit}"
        systemctl is-enabled --quiet "${unit}" \
            || die "SSH 服务未设置为开机启动：${unit}"
        systemctl is-active --quiet "${unit}" \
            || die "SSH 服务未运行：${unit}"
        info "SSH 已设置开机启动并处于运行状态：${unit}"
        return 0
    done
    die "未找到 ssh.service 或 sshd.service；拒绝配置定时重启"
}

validate_domain() {
    local domain=$1 label tld
    local -a labels
    [[ ${#domain} -ge 4 && ${#domain} -le 253 ]] || return 1
    [[ "${domain}" == *.* ]] || return 1
    [[ "${domain}" != \*.* ]] || return 1
    [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "${domain}" != .* && "${domain}" != *. ]] || return 1
    [[ "${domain}" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"${domain}"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    tld=${labels[$((${#labels[@]} - 1))]}
    [[ "${tld}" =~ ^[A-Za-z]{2,}$ ]]
}

normalize_domain() {
    local domain=$1
    domain=${domain%.}
    tr '[:upper:]' '[:lower:]' <<<"${domain}" | tr -d '\n'
}

validate_ipv4() {
    local ip=$1 octet
    local -a octets
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"${ip}"
    for octet in "${octets[@]}"; do
        ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
    done
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_sub_download_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

normalize_sub_download_name() {
    local name=${1:-}
    name=${name%.[Yy][Aa][Mm][Ll]}
    name=${name%.[Yy][Mm][Ll]}
    if validate_sub_download_name "${name}"; then
        printf '%s' "${name}"
    else
        printf '%s' "${DEFAULT_SUB_DOWNLOAD_NAME}"
    fi
}

normalize_allowed_tokens() {
    local raw=$1
    jq -cer '
        def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
        if type != "object" then
            error("ALLOWED_TOKENS 必须是 JSON object")
        else
            to_entries as $entries
            | if ($entries | length) == 0 then
                error("ALLOWED_TOKENS 不能为空")
            else
                if any($entries[]; (.value | type) != "string") then
                    error("ALLOWED_TOKENS token 值必须是字符串")
                else
                    [ $entries[] | {key: (.key | trim), value: (.value | trim)} ] as $clean
                    | if any($clean[]; .key == "" or .value == "") then
                    error("ALLOWED_TOKENS 不允许空用户名或空 token")
                    elif any($clean[]; (.key | test("^[A-Za-z0-9._-]{1,64}$") | not)) then
                    error("ALLOWED_TOKENS 用户名只能包含字母、数字、点、下划线、短横线，长度 1-64")
                    elif any($clean[]; (.value | test("^[A-Za-z0-9._~-]{8,128}$") | not)) then
                    error("ALLOWED_TOKENS token 只能包含 URL 安全字符 A-Z a-z 0-9 . _ ~ -，长度 8-128")
                    elif (($clean | map(.key) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 清洗后存在重复用户名")
                    elif (($clean | map(.value) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 不允许重复 token")
                    else
                    $clean | from_entries
                    end
                end
            end
        end
    ' <<<"${raw}"
}

ensure_allowed_tokens() {
    local raw prompt_default normalized
    if [[ -n "${ALLOWED_TOKENS:-}" ]]; then
        raw=${ALLOWED_TOKENS}
    elif [[ -t 0 ]]; then
        prompt_default=$(jq -cn --arg token "$(generate_secret)" '{owner: $token}')
        raw=$(prompt_value "订阅用户 Token 字典 JSON（用户名=>token）" "${prompt_default}")
    else
        die "非交互模式必须设置 ALLOWED_TOKENS，例如 ALLOWED_TOKENS='{\"owner\":\"$(generate_secret)\"}'"
    fi

    normalized=$(normalize_allowed_tokens "${raw}") \
        || die "ALLOWED_TOKENS 无效；请使用 JSON 对象，例如 {\"owner\":\"$(generate_secret)\"}"
    ALLOWED_TOKENS=${normalized}
}

generate_secret() {
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

prompt_value() {
    local label=$1 default=${2:-} value
    if [[ -n "${default}" ]]; then
        read -r -p "${label} [${default}]（直接回车使用默认值）: " value
        printf '%s' "${value:-${default}}"
    else
        read -r -p "${label}: " value
        printf '%s' "${value}"
    fi
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw \
        socat cron iproute2 iputils-ping tzdata systemd-timesyncd tar
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || die "无法启用网络时间同步"
}

check_platform() {
    [[ -r /etc/os-release ]] || die "无法识别系统版本"
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == "debian" ]] || die "仅支持 Debian"
    [[ "${VERSION_ID:-}" =~ ^(12|13)$ ]] || die "仅支持 Debian 12/13"
    [[ -n "${VERSION_CODENAME:-}" ]] || die "无法识别 Debian 发行版代号"
    [[ "$(dpkg --print-architecture)" == "amd64" ]] || die "仅支持 amd64"
    ! systemd-detect-virt --container >/dev/null 2>&1 \
        || die "容器不能执行内核与防火墙初始化"
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
    if [[ -f "${OLD_DISABLE_IPV6_CONF}" ]]; then
        install -m 0644 "${OLD_DISABLE_IPV6_CONF}" "${BACKUP_DIR}/pre-install-disable-ipv6.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-disable-ipv6.missing"
    fi
    INSTALL_ROLLBACK_ON_EXIT=1
}

configure_bbr_tcp() {
    if [[ "$(uname -r)" == *xanmod* ]]; then
        [[ -f "${STATE_FILE}" ]] \
            || die "当前运行 XanMod 内核；全新安装前请切换到 Debian 官方内核并重启"
        warn "旧安装仍运行 XanMod；本次保留现有 BBR，切换到 Debian 官方内核后再次执行 update"
        return 0
    fi
    cat >"${RUNTIME_TMP}/bbr.conf" <<'EOF'
# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_moderate_rcvbuf = 1

# PMTU
net.ipv4.tcp_mtu_probing = 0

# Idle connection
net.ipv4.tcp_slow_start_after_idle = 1

# Listen queue
net.core.somaxconn = 4096
EOF
    modprobe tcp_bbr >/dev/null 2>&1 || die "当前 Debian 内核不支持 Google BBR (tcp_bbr)"
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control \
        || die "Google BBR 模块已加载，但内核未将其注册为可用拥塞控制算法"
    printf '%s\n' tcp_bbr >"${RUNTIME_TMP}/easy_all-bbr.conf"
    install -m 0644 "${RUNTIME_TMP}/easy_all-bbr.conf" "${BBR_MODULES_CONFIG}"
    install -m 0644 "${RUNTIME_TMP}/bbr.conf" "${SYSCTL_CONFIG}"
    sysctl -p "${SYSCTL_CONFIG}" >/dev/null || die "应用 BBR sysctl 配置失败"
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
        || die "拥塞控制算法未成功设置为 bbr"
    [[ -f "${BBR_MODULES_CONFIG}" && -f "${SYSCTL_CONFIG}" ]] \
        || die "Google BBR 开机配置写入失败"
}

filter_managed_reboot_cron() {
    awk -v marker="${CRON_REBOOT_MARKER}" 'index($0, marker) == 0'
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job
    if [[ -z "${mode}" && -t 0 ]]; then
        printf '请选择定时重启策略：\n'
        printf '  1. 每天凌晨 4 点重启（默认）\n'
        printf '  2. 自定义每天几点重启（0-23）\n'
        printf '  3. 不配置定时重启\n'
        read -r -p "请选择 [1]（直接回车使用默认值）: " mode
    fi
    mode=${mode:-1}
    case "${mode}" in
    1 | default)
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"
        ;;
    2 | custom)
        [[ -n "${hour}" ]] || hour=$(prompt_value "每天重启小时（0-23）" "")
        [[ "${hour}" =~ ^[0-9]+$ ]] && ((10#${hour} <= 23)) \
            || die "重启小时无效：${hour}"
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${hour}"
        ;;
    3 | none | off | disabled)
        SCHEDULED_REBOOT_ENABLED=0
        SCHEDULED_REBOOT_HOUR=""
        ;;
    *) die "定时重启选项无效：${mode}" ;;
    esac
    { crontab -l 2>/dev/null || true; } | filter_managed_reboot_cron | crontab -
    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]]; then
        job="0 ${SCHEDULED_REBOOT_HOUR} * * * /usr/sbin/reboot ${CRON_REBOOT_MARKER}"
        { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
    fi
}

remove_daily_reboot_schedule() {
    { crontab -l 2>/dev/null || true; } | filter_managed_reboot_cron | crontab - \
        || warn "移除 easy_all 定时重启任务失败，请手动检查 root crontab"
}

configure_ipv6_compat() {
    [[ -d /proc/sys/net/ipv6 ]] || {
        warn "当前内核未暴露 IPv6，继续 IPv4-only 安装"
        return 0
    }
    rm -f -- "${OLD_DISABLE_IPV6_CONF}"
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
    info "配置 Debian 官方内核 Google BBR"
    configure_bbr_tcp
    info "配置每日重启与 IPv6"
    configure_daily_reboot
    configure_ipv6_compat
}

detect_public_ipv4() {
    local service ip
    local -a services=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.co"
    )
    for service in "${services[@]}"; do
        ip=$(curl -4fsS --max-time 10 "${service}" 2>/dev/null | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done
    return 1
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 状态文件不存在：${STATE_FILE}"
    unset STATE_VERSION
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "1" || "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}"
}

load_state() {
    local variable env_name
    local -a variables=(
        PROTOCOL CDN_PROVIDER NODE_NAME NODE_HOST VLESS_UUID REALITY_TARGET
        REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
        SUB_PORT_MODE ALLOWED_TOKENS
        SUBSCRIPTION_MODE SUB_DOWNLOAD_NAME SUBSCRIPTION_DOMAIN
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR GEMINI_IP_FAMILY
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
    )
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        printf -v "${env_name}" '%s' "${!variable:-}"
        printf -v "${variable}" '%s' ""
    done
    if [[ -f "${STATE_FILE}" ]]; then
        source_state_file
    fi
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        if [[ -n "${!env_name:-}" ]]; then
            printf -v "${variable}" '%s' "${!env_name}"
        fi
        unset "${env_name}"
    done
    GEMINI_IP_FAMILY=${GEMINI_IP_FAMILY:-auto}
    CDN_PROVIDER=""
    [[ "${GEMINI_IP_FAMILY}" =~ ^(auto|ipv4|ipv6)$ ]] \
        || die "GEMINI_IP_FAMILY 必须是 auto、ipv4 或 ipv6"
    SUBSCRIPTION_MODE=${SUBSCRIPTION_MODE:-link}
    [[ "${SUBSCRIPTION_MODE}" == "selfhost" || "${SUBSCRIPTION_MODE}" == "link" ]] \
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
        QUOTA_START_DATE=${QUOTA_START_DATE:-$(date -u +%Y-%m-%d)}
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
        printf 'GEMINI_IP_FAMILY=%q\n' "${GEMINI_IP_FAMILY:-auto}"
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

collect_reality_node_host() {
    local detected_ip=""
    [[ -z "${NODE_HOST:-}" ]] || return 0

    if detected_ip=$(detect_public_ipv4); then
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
        printf '  2. dynamic（订阅随机端口 10000-65535，默认）\n'
        read -r -p "请选择 [${default_choice}]（直接回车使用默认值）: " requested
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
        domain=$(prompt_value "自托管订阅域名（必须直接解析到当前 VPS）" "")
    fi
    [[ -n "${domain}" ]] \
        || die "自托管订阅模式必须设置 SUBSCRIPTION_DOMAIN"
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    SUBSCRIPTION_DOMAIN=${domain}
}

collect_install_inputs() {
    validate_protocol "${PROTOCOL}" || die "PROTOCOL 无效：${PROTOCOL:-空}"
    NODE_NAME=${NODE_NAME:-$(protocol_default_node_name)}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"
    collect_reality_node_host
    validate_domain "${NODE_HOST}" || validate_ipv4 "${NODE_HOST}" \
        || die "Reality 节点地址无效：${NODE_HOST}"
    collect_reality_target
    validate_reality_target "${REALITY_TARGET}" || die "REALITY_TARGET 无效：${REALITY_TARGET}"
    collect_sub_port_mode
    if validate_domain "${NODE_HOST}" \
        && dig +short AAAA "${NODE_HOST}" 2>/dev/null | grep -q .; then
        die "Reality 节点域名不能发布 AAAA；当前 Xray 入站仅监听 IPv4"
    fi
    choose_subscription_mode
    SUBSCRIPTION_MODE=${SUBSCRIBE_MODE}
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
}

check_install_conflicts() {
    if ss -H -ltn "sport = :${SERVICE_PORT}" 2>/dev/null | grep -q .; then
        die "TCP ${SERVICE_PORT} 已被占用；easy_all 仅支持专用 VPS"
    fi
}

append_ssh_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    ((10#${port} >= 1 && 10#${port} <= 65535)) || return 0
    case ", ${SSH_PORTS:-}, " in
    *", ${port}, "*) ;;
    *)
        [[ -z "${SSH_PORTS:-}" ]] || SSH_PORTS+=", "
        SSH_PORTS+="${port}"
        ;;
    esac
}

detect_ssh_ports() {
    local current_port sshd_bin config
    SSH_PORTS=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ _ current_port <<<"${SSH_CONNECTION}"
        append_ssh_port "${current_port}"
    fi
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    if [[ -n "${sshd_bin}" ]]; then
        while read -r current_port; do
            append_ssh_port "${current_port}"
        done < <("${sshd_bin}" -T 2>/dev/null | awk '$1 == "port" {print $2}')
    fi
    for config in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "${config}" ]] || continue
        while read -r current_port; do
            append_ssh_port "${current_port}"
        done < <(awk '
            /^[[:space:]]*#/ {next}
            tolower($1) == "port" {print $2}
        ' "${config}")
    done
    [[ -n "${SSH_PORTS}" ]] || SSH_PORTS="22"
    info "UFW 将放行 SSH 端口：${SSH_PORTS}"
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
    if [[ -f /etc/default/ufw ]]; then
        install -m 0600 /etc/default/ufw "${BACKUP_DIR}/pre-install-ufw-default"
    fi
}

managed_ufw_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | sed -n "/${UFW_RULE_COMMENT}/s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)\\].*/\\1/p" \
        | sort -rn
}

remove_managed_ufw_rules() {
    local rule_number
    command -v ufw >/dev/null 2>&1 || return 0
    while read -r rule_number; do
        [[ -n "${rule_number}" ]] || continue
        ufw --force delete "${rule_number}" >/dev/null \
            || warn "删除 UFW 规则 ${rule_number} 失败"
    done < <(managed_ufw_rule_numbers)
}

write_ufw_nat_rules() {
    local candidate="${RUNTIME_TMP}/ufw-before.rules"
    [[ -f "${UFW_BEFORE_RULES}" ]] || die "UFW before.rules 不存在：${UFW_BEFORE_RULES}"
    awk -v start="${UFW_NAT_START}" -v end="${UFW_NAT_END}" '
        $0 == start {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "${UFW_BEFORE_RULES}" >"${candidate}"
    if [[ "${SUB_PORT_MODE}" == "dynamic" ]]; then
        {
            printf '%s\n' "${UFW_NAT_START}"
            printf '*nat\n'
            printf ':PREROUTING ACCEPT [0:0]\n'
            printf -- '-A PREROUTING -p tcp --dport %s:65535 -j REDIRECT --to-ports %s\n' \
                "${PORT_BASE}" "${SERVICE_PORT}"
            printf 'COMMIT\n'
            printf '%s\n\n' "${UFW_NAT_END}"
            cat "${candidate}"
        } >"${candidate}.new"
        mv "${candidate}.new" "${candidate}"
    fi
    iptables-restore --test <"${candidate}" \
        || die "UFW NAT 规则校验失败"
    install -m 0644 "${candidate}" "${UFW_BEFORE_RULES}"
}

retire_legacy_nftables() {
    local hash_file="${STATE_DIR}/nftables.sha256" expected actual
    [[ -f "${hash_file}" ]] || return 0
    [[ -f "${LEGACY_NFT_CONFIG}" ]] \
        || die "检测到旧 nftables 管理标记，但配置文件不存在"
    expected=$(<"${hash_file}")
    actual=$(sha256sum "${LEGACY_NFT_CONFIG}" | awk '{print $1}')
    [[ -n "${expected}" && "${actual}" == "${expected}" ]] \
        || die "旧 nftables 配置已被修改，拒绝自动迁移到 UFW"
    [[ ! -f "${BACKUP_DIR}/pre-install-nftables.conf" ]] \
        || die "安装前已存在 nftables 配置，无法安全自动切换到 UFW"

    systemctl disable --now nftables >/dev/null 2>&1 || true
    command -v nft >/dev/null 2>&1 && nft flush ruleset >/dev/null 2>&1 || true
    rm -f -- "${LEGACY_NFT_CONFIG}" "${hash_file}"
    success "旧版 easy_all nftables 已安全退役"
}

configure_ufw() {
    local port rule_number old_rule_numbers
    retire_legacy_nftables
    detect_ssh_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        apt-get update
        apt-get install -y --no-install-recommends ufw
    fi
    old_rule_numbers=$(managed_ufw_rule_numbers)
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    IFS=',' read -ra ports <<<"${SSH_PORTS// /}"
    for port in "${ports[@]}"; do
        ufw allow "${port}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加 SSH UFW 规则失败：TCP ${port}"
    done
    ufw allow "${SERVICE_PORT}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null \
        || die "添加 Reality UFW 规则失败"
    if [[ "${SUBSCRIBE_MODE:-${SUBSCRIPTION_MODE:-}}" == "selfhost" ]]; then
        ufw allow 80/tcp comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加 ACME HTTP UFW 规则失败"
        ufw allow "${SUBSCRIPTION_HTTPS_PORT}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加订阅 UFW 规则失败"
    fi
    while read -r rule_number; do
        [[ -n "${rule_number}" ]] || continue
        ufw --force delete "${rule_number}" >/dev/null \
            || die "删除旧 UFW 规则失败：${rule_number}"
    done <<<"${old_rule_numbers}"
    write_ufw_nat_rules
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
}

download_xray() {
    local release archive_url dgst_url version temp_dir archive dgst expected actual
    temp_dir=$(make_temp_dir)
    release=$(curl -fsSL --retry 3 "${XRAY_RELEASES_API}") || die "读取 Xray 最新版本失败"
    version=$(jq -r '.tag_name' <<<"${release}")
    archive_url=$(jq -r --arg name "${XRAY_ARCHIVE}" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release}")
    dgst_url=$(jq -r --arg name "${XRAY_DGST}" '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release}")
    [[ -n "${archive_url}" && "${archive_url}" != "null" ]] || die "未找到 ${XRAY_ARCHIVE}"
    [[ -n "${dgst_url}" && "${dgst_url}" != "null" ]] || die "未找到 ${XRAY_DGST}"
    archive="${temp_dir}/${XRAY_ARCHIVE}"
    dgst="${temp_dir}/${XRAY_DGST}"
    curl -fL --retry 3 "${archive_url}" -o "${archive}" || die "下载 Xray 失败"
    curl -fL --retry 3 "${dgst_url}" -o "${dgst}" || die "下载 Xray 校验文件失败"
    expected=$(awk '
        BEGIN { IGNORECASE = 1 }
        /SHA256|SHA2-256/ {
            for (i = 1; i <= NF; i++) {
                token = $i
                gsub(/[^A-Fa-f0-9]/, "", token)
                if (token ~ /^[A-Fa-f0-9]{64}$/) {
                    print tolower(token)
                    exit
                }
            }
        }
    ' "${dgst}")
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ -n "${expected}" && "${expected,,}" == "${actual,,}" ]] || die "Xray SHA256 校验失败"
    unzip -qo "${archive}" -d "${temp_dir}/xray"
    install -d -m 0755 "${XRAY_DIR}"
    install -m 0755 "${temp_dir}/xray/xray" "${XRAY_BIN}"
    printf '%s\n' "${version}" >"${XRAY_DIR}/version"
}

write_xray_config() {
    local gemini_domain_strategy clients
    prepare_mihomo_template
    resolve_gemini_ip_family
    [[ "${GEMINI_IP_FAMILY_RESOLVED}" == "ipv6" ]] \
        && gemini_domain_strategy="ForceIPv6" \
        || gemini_domain_strategy="ForceIPv4"
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
            --arg gemini_domain_strategy "${gemini_domain_strategy}" \
            --argjson gemini_domain_suffixes "${GEMINI_DOMAIN_SUFFIXES_JSON}" '
            {
              log: {loglevel: "warning"},
              inbounds: [{
                tag: "vless-reality-in",
                listen: "0.0.0.0",
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
              outbounds: [
                {protocol: "freedom", tag: "direct"},
                {
                  protocol: "freedom",
                  tag: "gemini-family",
                  settings: {domainStrategy: $gemini_domain_strategy}
                }
              ],
              routing: {
                domainStrategy: "AsIs",
                rules: [
                  {
                    type: "field",
                    domain: ($gemini_domain_suffixes | map("domain:" + .)),
                    outboundTag: "gemini-family"
                  },
                  {
                    type: "field",
                    network: "tcp,udp",
                    outboundTag: "direct"
                  }
                ]
              }
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

install_xray_service() {
    cat >"${RUNTIME_TMP}/easy_all-xray.service" <<EOF
[Unit]
Description=Xray ${PROTOCOL} managed by easy_all
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-xray.service" "${XRAY_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${XRAY_SERVICE}" >/dev/null || die "启动 Xray 服务失败"
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
    jq -nr \
            --arg name "${NODE_NAME}" --arg server "${NODE_HOST}" \
            --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
            --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" \
            --argjson port "${port}" '
            "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: \($port)\n" +
            "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
            "    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \($sni|@json)\n" +
            "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
            "    client-fingerprint: chrome\n    packet-encoding: xudp\n    smux:\n      enabled: false\n"'
}

validate_mihomo_template() {
    local source=$1 marker count
    [[ -s "${source}" ]] || die "sample-mihomo.yaml 为空：${source}"
    for marker in \
        "# EASY_ALL_PROXY_NODE" \
        "# EASY_ALL_PROXY_NAME" \
        "# EASY_ALL_GEMINI_DOMAINS_START" \
        "# EASY_ALL_GEMINI_DOMAINS_END"; do
        count=$(grep -Fxc "${marker}" "${source}" || true)
        [[ "${count}" == "1" ]] \
            || die "sample-mihomo.yaml 模板标记无效：${marker} 应且只能出现一次"
    done
    grep -q '^rules:' "${source}" || die "sample-mihomo.yaml 缺少规则"
    extract_gemini_domain_suffixes "${source}" >/dev/null
}

fetch_mihomo_template() {
    local destination=$1 source=${MIHOMO_TEMPLATE_SOURCE:-} url
    if [[ -n "${source}" ]]; then
        if [[ -f "${source}" ]]; then
            install -m 0600 "${source}" "${destination}"
        elif [[ "${source}" =~ ^https:// ]]; then
            curl -fsSL --retry 3 "${source}" -o "${destination}" \
                || die "下载 sample-mihomo.yaml 失败：${source}"
            chmod 0600 "${destination}"
        else
            die "MIHOMO_TEMPLATE_SOURCE 必须是本地文件或 HTTPS URL：${source}"
        fi
    elif [[ -f "${SCRIPT_DIR}/sample-mihomo.yaml" ]]; then
        install -m 0600 "${SCRIPT_DIR}/sample-mihomo.yaml" "${destination}"
    else
        url=${MIHOMO_TEMPLATE_URL:-${DEFAULT_MIHOMO_TEMPLATE_URL}}
        [[ "${url}" =~ ^https:// ]] \
            || die "MIHOMO_TEMPLATE_URL 必须使用 HTTPS：${url}"
        curl -fsSL --retry 3 "${url}" -o "${destination}" \
            || die "下载 sample-mihomo.yaml 失败：${url}"
    fi
    validate_mihomo_template "${destination}"
}

extract_domain_suffix_policy() {
    local source=$1 start_marker=$2 end_marker=$3 description=$4
    local json domain normalized compact
    json=$(awk -v start_marker="${start_marker}" -v end_marker="${end_marker}" '
        $0 == start_marker {
            capture = 1
            next
        }
        $0 == end_marker {
            capture = 0
            exit
        }
        capture == 1 {
            print
        }
    ' "${source}" | sed 's/^#[[:space:]]*//') \
        || die "无法提取 Mihomo ${description} 域名策略"
    jq -e '
        type == "array"
        and length > 0
        and all(.[]; type == "string")
        and length == (unique | length)
    ' <<<"${json}" >/dev/null \
        || die "Mihomo ${description} 域名策略必须是非空且不重复的字符串数组"
    while IFS= read -r domain; do
        validate_domain "${domain}" \
            || die "Mihomo ${description} 域名策略包含无效域名：${domain}"
        normalized=$(normalize_domain "${domain}")
        [[ "${normalized}" == "${domain}" ]] \
            || die "Mihomo ${description} 域名必须使用小写规范格式：${domain}"
    done < <(jq -r '.[]' <<<"${json}")
    compact=$(jq -c '.' <<<"${json}") \
        || die "无法规范化 Mihomo ${description} 域名策略"
    printf '%s\n' "${compact}"
}

extract_gemini_domain_suffixes() {
    extract_domain_suffix_policy "$1" \
        "# EASY_ALL_GEMINI_DOMAINS_START" \
        "# EASY_ALL_GEMINI_DOMAINS_END" \
        "Gemini"
}

measure_gemini_ip_family() {
    local family=$1 flag result attempt
    local -a timings=()
    [[ "${family}" == "ipv6" ]] && flag="-6" || flag="-4"
    for attempt in 1 2 3; do
        result=$(curl "${flag}" --noproxy '*' --silent --show-error \
            --output /dev/null --connect-timeout 5 --max-time 10 \
            --write-out '%{time_total}' 'https://gemini.google.com/' 2>/dev/null) \
            || continue
        [[ "${result}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        timings+=("${result}")
    done
    ((${#timings[@]} > 0)) || return 1
    printf '%s\n' "${timings[@]}" | sort -n | awk '
        { values[NR] = $1 }
        END { print values[int((NR + 1) / 2)] }
    '
}

resolve_gemini_ip_family() {
    local requested=${GEMINI_IP_FAMILY:-auto} ipv4_time="" ipv6_time=""
    local ipv4_display ipv6_display
    case "${requested}" in
    ipv4 | ipv6)
        GEMINI_IP_FAMILY_RESOLVED=${requested}
        ;;
    auto)
        ipv4_time=$(measure_gemini_ip_family ipv4 || true)
        if command -v ip >/dev/null 2>&1 \
            && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' \
            && ip -6 route show default 2>/dev/null | grep -q '^default'; then
            ipv6_time=$(measure_gemini_ip_family ipv6 || true)
        fi
        if [[ -z "${ipv4_time}" && -z "${ipv6_time}" ]]; then
            GEMINI_IP_FAMILY_RESOLVED="ipv4"
            warn "Gemini IPv4/IPv6 测速均失败，保守选择 IPv4"
        elif [[ -z "${ipv4_time}" ]]; then
            GEMINI_IP_FAMILY_RESOLVED="ipv6"
        elif [[ -z "${ipv6_time}" ]]; then
            GEMINI_IP_FAMILY_RESOLVED="ipv4"
        elif awk -v ipv4="${ipv4_time}" -v ipv6="${ipv6_time}" \
            'BEGIN { exit !(ipv6 < ipv4) }'; then
            GEMINI_IP_FAMILY_RESOLVED="ipv6"
        else
            GEMINI_IP_FAMILY_RESOLVED="ipv4"
        fi
        [[ -n "${ipv4_time}" ]] && ipv4_display="${ipv4_time}s" || ipv4_display="不可用"
        [[ -n "${ipv6_time}" ]] && ipv6_display="${ipv6_time}s" || ipv6_display="不可用"
        info "Gemini 出口测速：IPv4 ${ipv4_display}，IPv6 ${ipv6_display}；固定使用 ${GEMINI_IP_FAMILY_RESOLVED}"
        ;;
    *) die "GEMINI_IP_FAMILY 必须是 auto、ipv4 或 ipv6" ;;
    esac
}

prepare_mihomo_template() {
    local template
    if [[ -n "${MIHOMO_TEMPLATE_FILE:-}" \
        && -s "${MIHOMO_TEMPLATE_FILE}" \
        && -n "${GEMINI_DOMAIN_SUFFIXES_JSON:-}" ]]; then
        return 0
    fi
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    fetch_mihomo_template "${template}"
    GEMINI_DOMAIN_SUFFIXES_JSON=$(extract_gemini_domain_suffixes "${template}")
    MIHOMO_TEMPLATE_FILE=${template}
}

render_mihomo_subscription() {
    local template=$1 node_file=$2 destination=$3 node_name
    node_name=$(jq -Rn --arg value "${NODE_NAME}" '$value')
    awk -v node_file="${node_file}" -v node_name="${node_name}" '
        $0 == "# EASY_ALL_GEMINI_DOMAINS_START" { metadata=1; next }
        $0 == "# EASY_ALL_GEMINI_DOMAINS_END" { metadata=0; next }
        metadata == 1 { next }
        $0 == "# EASY_ALL_PROXY_NODE" {
            while ((getline line < node_file) > 0) print line
            close(node_file)
            next
        }
        $0 == "# EASY_ALL_PROXY_NAME" { print "        - " node_name; next }
        { print }
    ' "${template}" >"${destination}" || die "生成 Mihomo 订阅失败"
}

generate_subscription_port() {
    local value
    if [[ "${SUB_PORT_MODE}" == "443" ]]; then
        printf '443\n'
        return 0
    fi
    value=$((16#$(openssl rand -hex 4)))
    printf '%s\n' "$((PORT_BASE + value % (65536 - PORT_BASE)))"
}

install_selfhost_dependencies() {
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

has_acme_renewal_cron() {
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null || true)
    awk -v acme_bin="${ACME_BIN}" '
        index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/ { found=1 }
        END { exit !found }
    ' <<<"${crontab_content}"
}

verify_acme_renewal_setup() {
    command -v crontab >/dev/null 2>&1 || die "未找到 crontab"
    systemctl enable --now cron.service >/dev/null 2>&1 \
        || die "无法启用证书自动续期所需的 cron.service"
    has_acme_renewal_cron || die "未找到 acme.sh 自动续期定时任务"
}

install_managed_acme_renewal_cron() {
    local crontab_content cron_file
    crontab_content=$(crontab -l 2>/dev/null || true)
    cron_file="${RUNTIME_TMP}/acme-renewal.cron"
    awk -v acme_bin="${ACME_BIN}" '
        !(index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/) { print }
    ' <<<"${crontab_content}" >"${cron_file}"
    printf '17 2 * * * "%s" --cron --home "%s" >/dev/null 2>&1 # easy_all-acme-renewal\n' \
        "${ACME_BIN}" "${ACME_HOME}" >>"${cron_file}"
    crontab "${cron_file}" || die "写入 easy_all acme.sh 自动续期定时任务失败"
}

ensure_acme_renewal_setup() {
    run_acme --install-cronjob >/dev/null 2>&1 \
        || warn "acme.sh --install-cronjob 失败，改用 easy_all 受管 cron"
    if ! has_acme_renewal_cron; then
        warn "acme.sh 未写入续期任务，正在写入 easy_all 受管 cron"
        install_managed_acme_renewal_cron
    fi
    verify_acme_renewal_setup
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

run_acme() {
    "${ACME_BIN}" "$@" --home "${ACME_HOME}"
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
    render_mihomo_subscription "${MIHOMO_TEMPLATE_FILE}" "${node_file}" "${mihomo_file}"
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

write_subscription_token_map() {
    if quota_enabled; then
        jq -r 'to_entries[] | "    \"" + .value.token + "\" \"" + .key + "\";"' \
            <<<"$(quota_active_accounts_json)"
        return 0
    fi
    jq -r '.[] | "    \"" + . + "\" 1;"' <<<"${ALLOWED_TOKENS}"
}

write_subscription_nginx_config() {
    local base64_alias="${SUBSCRIPTION_BASE64_FILE}"
    local mihomo_alias="${SUBSCRIPTION_MIHOMO_FILE}"
    if quota_enabled; then
        base64_alias="${SUBSCRIPTION_DIR}/\$easy_all_subscription_allowed/base64.txt"
        mihomo_alias="${SUBSCRIPTION_DIR}/\$easy_all_subscription_allowed/mihomo.yaml"
    fi
    write_subscription_web_root
    {
        cat <<'EOF'
map $arg_token $easy_all_subscription_allowed {
    default __denied__;
EOF
        write_subscription_token_map
        cat <<EOF
}

map \$arg_flag \$easy_all_subscription_uri {
    default /_easy_all_subscription/base64;
    clash /_easy_all_subscription/mihomo;
}

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

    location = /subscribe {
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

    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 订阅配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

validate_selfhosted_subscription() {
    local token status base64_response mihomo_response
    if quota_enabled; then
        token=$(jq -r 'first(.[].token) // empty' <<<"$(quota_active_accounts_json)")
        [[ -n "${token}" ]] || { info "所有配额用户均已停用，跳过订阅内容验收"; return 0; }
    else
        token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    fi
    status=$(curl -ksS --noproxy '*' -o /dev/null -w '%{http_code}' \
        --resolve "${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}:127.0.0.1" \
        "https://${SUBSCRIPTION_DOMAIN}:${SUBSCRIPTION_HTTPS_PORT}/subscribe?token=invalid")
    [[ "${status}" == "403" ]] || die "无效订阅 Token 未被拒绝（HTTP ${status}）"
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

configure_selfhosted_subscription() {
    collect_subscription_domain
    choose_subscription_download_name "$1"
    choose_monthly_quota 1
    quota_enabled || ensure_allowed_tokens
    SUBSCRIPTION_MODE="selfhost"
    install_selfhost_dependencies
    configure_ufw
    verify_subscription_dns
    write_subscription_bootstrap_nginx
    issue_subscription_certificate
    install_static_subscriptions
    write_subscription_nginx_config
    validate_selfhosted_subscription
}

choose_subscription_mode() {
    local mode=${SUBSCRIBE_MODE:-${SUBSCRIPTION_MODE:-}} current_mode default_choice=1
    if [[ "${PROMPT_SUBSCRIPTION_MODE:-0}" == "1" || -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            current_mode=${mode:-selfhost}
            [[ "${current_mode}" == "link" ]] && default_choice=2
            printf '请选择是否部署订阅服务：\n'
            printf '  1. 部署订阅服务（Nginx HTTPS :8443；只有当前服务器时推荐）\n'
            printf '  2. 不部署，仅输出节点信息（多节点聚合或已有订阅服务器时推荐）\n'
            read -r -p "请选择 [${default_choice}]（直接回车使用默认值）: " mode
            mode=${mode:-${current_mode}}
        elif [[ -z "${mode}" ]]; then
            die "非交互模式必须设置 SUBSCRIBE_MODE=selfhost 或 SUBSCRIBE_MODE=link"
        fi
    fi
    mode=${mode:-selfhost}
    case "${mode}" in
    1 | selfhost | nginx) SUBSCRIBE_MODE="selfhost" ;;
    2 | link | vless) SUBSCRIBE_MODE="link" ;;
    *) die "订阅输出方式无效：${mode}" ;;
    esac
}

choose_subscription_download_name() {
    local allow_prompt=${1:-0} name=${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}
    if [[ "${allow_prompt}" == "1" && -t 0 ]]; then
        name=$(prompt_value "Mihomo 下载文件名（不含 .yaml）" "${name}")
    fi
    name=$(normalize_sub_download_name "${name}")
    validate_sub_download_name "${name}" || die "Mihomo 下载文件名无效：${name}"
    SUB_DOWNLOAD_NAME=${name}
}

configure_subscription() {
    local prompt_download_name=${1:-0}
    collect_installed_state
    choose_subscription_mode
    case "${SUBSCRIBE_MODE}" in
    link)
        disable_selfhosted_subscription
        SUBSCRIPTION_MODE="link"
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
        ;;
    selfhost)
        configure_selfhosted_subscription "${prompt_download_name}"
        ;;
    esac
    save_state
}

disable_selfhosted_subscription() {
    if [[ "${SUBSCRIPTION_MODE:-}" == "selfhost" || -f "${NGINX_CONFIG}" ]]; then
        systemctl disable --now nginx >/dev/null 2>&1 || true
        rm -f -- "${NGINX_CONFIG}"
        rm -rf -- "${WEB_ROOT}"
        configure_ufw
    fi
}

renew_subscription_certificate() {
    require_root
    collect_installed_state
    [[ "${SUBSCRIPTION_MODE:-}" == "selfhost" ]] || die "当前未启用自托管订阅"
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
    UPDATE_SUB_ROLLBACK_ON_EXIT=1
}

rollback_subscription_update() {
    warn "订阅更新失败，正在恢复服务端配置、订阅文件、端口模式和 UFW"
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
    unset SUB_PORT_MODE SUBSCRIPTION_MODE SUBSCRIBE_MODE
    source_state_file
    SUBSCRIBE_MODE=${SUBSCRIPTION_MODE}
    configure_ufw || warn "恢复订阅更新前 UFW 失败"
}

update_subscription() {
    local prompt_options=${1:-0}
    local requested_port_mode=${SUB_PORT_MODE:-}
    local requested_download_name=${SUB_DOWNLOAD_NAME:-} stored_port_mode target_port_mode
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
    target_port_mode=${SUB_PORT_MODE}
    SUB_PORT_MODE=${stored_port_mode}
    SUBSCRIBE_MODE=${SUBSCRIPTION_MODE}
    configure_ufw
    SUB_PORT_MODE=${target_port_mode}
    if [[ "${SUB_PORT_MODE}" != "${stored_port_mode}" ]]; then
        info "订阅端口模式从 ${stored_port_mode} 切换为 ${SUB_PORT_MODE}，同步更新 UFW"
        if ! configure_ufw; then
            UPDATE_SUB_ROLLBACK_ON_EXIT=0
            rollback_subscription_update
            return 1
        fi
    fi
    [[ "${prompt_options}" == "1" ]] && PROMPT_SUBSCRIPTION_MODE=1
    if ! configure_subscription "${prompt_download_name}"; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        rollback_subscription_update
        return 1
    fi
    PROMPT_SUBSCRIPTION_MODE=0
    if ! refresh_protocol_runtime_config; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        rollback_subscription_update
        return 1
    fi
    install_quota_timer
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
}

apply_easy_all() {
    require_root
    info "刷新 BBR 与 TCP 参数"
    configure_bbr_tcp
    register_easy_all_command
    collect_installed_state
    SUBSCRIBE_MODE=${SUBSCRIPTION_MODE}
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

quota_rebuild_runtime() {
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
    if [[ "${SUBSCRIPTION_MODE:-}" == "selfhost" ]]; then
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

active_gemini_ip_family() {
    local strategy=""
    [[ -s "${XRAY_CONFIG}" ]] || return 1
    strategy=$(jq -r \
        '.outbounds[]? | select(.tag == "gemini-family") | .settings.domainStrategy' \
        "${XRAY_CONFIG}")
    case "${strategy}" in
    ForceIPv6) printf 'ipv6\n' ;;
    ForceIPv4) printf 'ipv4\n' ;;
    *) return 1 ;;
    esac
}

show_status() {
    local active_family
    require_root
    collect_installed_state
    active_family=$(active_gemini_ip_family || true)
    if [[ -z "${active_family}" ]]; then
        resolve_gemini_ip_family
        active_family=${GEMINI_IP_FAMILY_RESOLVED}
    fi
    printf '协议: %s\n' "${PROTOCOL}"
    printf 'Gemini 出口族: %s（配置: %s）\n' \
        "${active_family}" "${GEMINI_IP_FAMILY:-auto}"
    printf '节点: %s\nReality 目标: %s\n' "${NODE_HOST}" "${REALITY_TARGET}"
    printf '核心服务: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'TCP 443: '
    ss -H -ltn "sport = :443" 2>/dev/null | grep -q . && printf 'listening\n' || printf 'not listening\n'
    if [[ "${SUBSCRIPTION_MODE:-}" == "selfhost" ]]; then
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

register_easy_all_command() {
    local destination="${COMMAND_INSTALL_DIR}/${ENTRY_COMMAND_NAME}"
    require_root
    [[ -n "${ENTRY_SCRIPT_FILE}" && -f "${ENTRY_SCRIPT_FILE}" ]] \
        || die "未找到入口脚本：${ENTRY_SCRIPT_FILE:-缺失}"
    install -d -m 0755 "${COMMAND_INSTALL_DIR}" "$(dirname "${COMMAND_PATH}")"
    if [[ "${ENTRY_SCRIPT_FILE}" == "${destination}" ]]; then
        chmod 0755 "${destination}"
    elif [[ ! -f "${destination}" ]] || ! cmp -s "${ENTRY_SCRIPT_FILE}" "${destination}"; then
        install -m 0755 "${ENTRY_SCRIPT_FILE}" "${destination}"
    fi
    ln -sfn "${destination}" "${COMMAND_PATH}"
    success "已注册单文件命令：${COMMAND_PATH}"
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
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" /etc/default/ufw
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
        || -e "${BACKUP_DIR}/pre-install-enable-ipv6.missing" \
        || -e "${BACKUP_DIR}/pre-install-disable-ipv6.conf" \
        || -e "${BACKUP_DIR}/pre-install-disable-ipv6.missing" ]] || return 0
    if [[ -f "${BACKUP_DIR}/pre-install-enable-ipv6.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-enable-ipv6.conf" "${IPV6_SYSCTL_CONF}"
    else
        rm -f -- "${IPV6_SYSCTL_CONF}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-disable-ipv6.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-disable-ipv6.conf" "${OLD_DISABLE_IPV6_CONF}"
        sysctl -p "${OLD_DISABLE_IPV6_CONF}" >/dev/null 2>&1 || true
    else
        rm -f -- "${OLD_DISABLE_IPV6_CONF}"
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
        read -r -p "确认彻底删除 easy_all 本机服务、状态和备份？[y/N]（直接回车取消）: " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_protocol_services
    remove_quota_timer
    restore_preinstall_firewall
    restore_preinstall_ipv6
    remove_daily_reboot_schedule
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

install_all() {
    local requested=${1:-} prompt_download_name=0
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    [[ -n "${SUB_DOWNLOAD_NAME:-}" ]] || prompt_download_name=1
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
    info "[3/9] 收集 ${PROTOCOL} 参数"
    collect_install_inputs
    info "[4/9] 准备核心"
    prepare_protocol_assets
    info "[5/9] 配置 UFW"
    configure_ufw
    info "[6/9] 安装并启动 ${PROTOCOL}"
    install_protocol_runtime
    validate_protocol_runtime
    info "[7/9] 保存状态"
    save_state
    info "[8/9] 注册 easy_all 命令"
    register_easy_all_command
    info "[9/9] 配置订阅输出"
    configure_subscription "${prompt_download_name}"
    refresh_protocol_runtime_config
    install_quota_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    show_subscription
    success "easy_all ${PROTOCOL} 安装完成"
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
  quota-status  显示每个用户的本月流量与配额状态
  quota-set     修改指定用户的月度额度
  quota-reset   清零指定用户的本月已用量
  status        显示当前协议、服务、端口和订阅状态
  uninstall     默认彻底删除所有 easy_all 本机数据
  help          显示帮助

Reality 默认使用 dynamic 订阅端口。
订阅仅支持 selfhost 与 link 两种选择。
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
