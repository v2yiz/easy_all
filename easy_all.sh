#!/usr/bin/env bash

# Unified installer for Reality, AnyTLS, and VLESS WebSocket TLS.

set -Eeuo pipefail
umask 077

readonly STATE_DIR="/etc/easy_all"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly WORKER_FILE="${STATE_DIR}/subscribe-worker.js"
readonly CLOUDFLARE_DEPLOY_LOG="${STATE_DIR}/last-worker-deploy.log"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly WEB_ROOT="/var/www/easy_all"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_FILE="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly COMMAND_PATH="/usr/local/bin/easy_all"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-tls-service.sh"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy-all-xray.service"
readonly XRAY_SERVICE="easy-all-xray.service"
readonly SING_BOX_DIR="${STATE_DIR}/sing-box"
readonly SING_BOX_BIN="${SING_BOX_DIR}/sing-box"
readonly SING_BOX_CONFIG="${SING_BOX_DIR}/config.json"
readonly SING_BOX_SERVICE_FILE="/etc/systemd/system/easy-all-sing-box.service"
readonly SING_BOX_SERVICE="easy-all-sing-box.service"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy-all"
readonly NFT_CONFIG="/etc/nftables.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-bbrv3.conf"
readonly IPV6_SYSCTL_CONF="/etc/sysctl.d/99-enable-ipv6.conf"
readonly OLD_DISABLE_IPV6_CONF="/etc/sysctl.d/99-disable-ipv6.conf"
readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_REPO="/etc/apt/sources.list.d/xanmod-release.list"
readonly DEFAULT_XRAY_LOOPBACK_PORT="10085"
readonly SERVICE_PORT="443"
readonly PORT_BASE="10000"
readonly PORT_MULTIPLIER="6"
readonly DEFAULT_REALITY_TARGET="swdist.apple.com:443"
readonly DEFAULT_REALITY_PORT_MODE="443"
readonly DEFAULT_ANYTLS_PORT_MODE="dynamic"
readonly DEFAULT_REALITY_NODE_NAME="MY_REALITY"
readonly DEFAULT_ANYTLS_NODE_NAME="MY_ANYTLS"
readonly DEFAULT_WSS_NODE_NAME="MY_VLESS_WSS"
readonly DEFAULT_WORKER_NAME="easy-all"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_SAMPLE_WORKER_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/sample-worker.js"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly SING_BOX_RELEASES_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
readonly XRAY_ARCHIVE="Xray-linux-64.zip"
readonly XRAY_DGST="Xray-linux-64.zip.dgst"
readonly STATE_SCHEMA_VERSION="1"

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
SWITCH_ROLLBACK_ON_EXIT=0
SWITCH_BACKUP_DIR=""
INSTALL_ROLLBACK_ON_EXIT=0
cleanup() {
    local path
    if [[ "${SWITCH_ROLLBACK_ON_EXIT:-0}" == "1" && -n "${SWITCH_BACKUP_DIR:-}" ]]; then
        SWITCH_ROLLBACK_ON_EXIT=0
        rollback_protocol_switch || true
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

validate_worker_name() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
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

first_allowed_token() {
    jq -er 'to_entries[0].value' <<<"${ALLOWED_TOKENS}"
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

validate_ws_path() {
    local path=$1
    [[ ${#path} -ge 2 && ${#path} -le 96 ]] || return 1
    [[ "${path}" == /* ]] || return 1
    [[ "${path}" != *"?"* && "${path}" != *"#"* ]] || return 1
    [[ "${path}" =~ ^/[A-Za-z0-9._~:@%+-]+$ ]]
}

generate_ws_path() {
    printf '/%sws' "$(openssl rand -hex 8)"
}

generate_secret() {
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

prompt_value() {
    local label=$1 default=${2:-} value
    if [[ -n "${default}" ]]; then
        read -r -p "${label} [${default}]: " value
        printf '%s' "${value:-${default}}"
    else
        read -r -p "${label}: " value
        printf '%s' "${value}"
    fi
}

prompt_secret() {
    local label=$1 value
    if [[ ! -t 0 ]]; then
        return 1
    fi
    read -r -s -p "${label}: " value
    printf '\n' >&2
    printf '%s' "${value}"
}

interactive_pause() {
    [[ -t 0 ]] || return 0
    read -r -p "确认后按回车继续，Ctrl+C 退出: " _
}

install_packages() {
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y --no-install-recommends \
        ca-certificates curl wget gnupg jq unzip openssl dnsutils nftables nginx \
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
    INSTALL_NGINX_WAS_ACTIVE=0
    systemctl is-active --quiet nginx 2>/dev/null && INSTALL_NGINX_WAS_ACTIVE=1
    if [[ -f "${SYSCTL_CONFIG}" ]]; then
        install -m 0644 "${SYSCTL_CONFIG}" "${BACKUP_DIR}/pre-install-bbr.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-bbr.missing"
    fi
    if command -v crontab >/dev/null 2>&1 \
        && crontab -l >"${BACKUP_DIR}/pre-install-crontab" 2>/dev/null; then
        chmod 0600 "${BACKUP_DIR}/pre-install-crontab"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-crontab.missing"
    fi
    INSTALL_ROLLBACK_ON_EXIT=1
}

install_xanmod_bbr() {
    local key_file keyring_file repo_file
    key_file="${RUNTIME_TMP}/xanmod-archive.key"
    keyring_file="${RUNTIME_TMP}/xanmod-archive-keyring.gpg"
    repo_file="${RUNTIME_TMP}/xanmod-release.list"
    curl -fsSL --retry 3 https://dl.xanmod.org/archive.key -o "${key_file}" \
        || die "下载 XanMod 签名密钥失败"
    gpg --batch --yes --dearmor --output "${keyring_file}" "${key_file}" \
        || die "转换 XanMod 签名密钥失败"
    install -d -m 0755 /etc/apt/keyrings
    install -m 0644 "${keyring_file}" "${XANMOD_KEYRING}"
    printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' \
        "${XANMOD_KEYRING}" "${VERSION_CODENAME}" >"${repo_file}"
    install -m 0644 "${repo_file}" "${XANMOD_REPO}"
    apt-get update
    apt-get install -y linux-xanmod-lts-x64v1
    cat >"${RUNTIME_TMP}/bbr.conf" <<'EOF'
net.core.default_qdisc = fq
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
EOF
    install -m 0644 "${RUNTIME_TMP}/bbr.conf" "${SYSCTL_CONFIG}"
    modprobe tcp_bbr >/dev/null 2>&1 || true
    sysctl -p "${SYSCTL_CONFIG}" >/dev/null || die "应用 BBR sysctl 配置失败"
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
        || die "拥塞控制算法未成功设置为 bbr"
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
        read -r -p "请选择 [1]: " mode
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
    info "配置 XanMod LTS 与 BBR"
    install_xanmod_bbr
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

query_a_records() {
    local domain=$1 resolver=${2:-}
    if [[ -n "${resolver}" ]]; then
        dig +short A "${domain}" @"${resolver}" | awk 'NF'
    else
        dig +short A "${domain}" | awk 'NF'
    fi
}

verify_domain_dns() {
    local domain=$1 public_ip=$2 resolver records record
    local -a resolvers=("" "1.1.1.1" "8.8.8.8")
    for resolver in "${resolvers[@]}"; do
        records=$(query_a_records "${domain}" "${resolver}" | sort -u | paste -sd' ' -)
        [[ -n "${records}" ]] || die "域名 ${domain} 未查询到 A 记录"
        for record in ${records}; do
            validate_ipv4 "${record}" || die "域名 ${domain} 返回了非 IPv4 A 记录：${record}"
            if [[ "${record}" != "${public_ip}" ]]; then
                die "域名 ${domain} 的 A 记录为 ${record}，不是本机公网 IPv4 ${public_ip}。如果使用 Cloudflare，请先关闭代理（灰云 / DNS only）再安装"
            fi
        done
    done
}

print_dns_proxy_preinstall_notice() {
    alert "安装前请确认 Cloudflare DNS A 记录为 DNS only / 灰云，不要开启代理。"
    alert "域名 A 记录必须直接指向当前 VPS 公网 IPv4；脚本会强制校验。"
    alert "如果配置了 AAAA 记录，安装成功前也请保持 DNS only / 灰云并指向当前 VPS 公网 IPv6。"
    if [[ "${PROTOCOL}" == "vless-wss" ]]; then
        alert "安装完成并验证成功后，使用 Cloudflare CDN 时再把 A、AAAA 记录一起切回 Proxied / 橙云。"
    else
        alert "AnyTLS 不能通过普通 Cloudflare CDN 代理，安装完成后也必须保持 DNS only / 灰云。"
    fi
}

print_dns_proxy_postinstall_notice() {
    success "VLESS WebSocket TLS 安装和本机验证已完成"
    alert "现在可以回 Cloudflare；使用 CDN 时请把 A、AAAA 记录一起从 DNS only / 灰云切换为 Proxied / 橙云。"
    alert "Cloudflare SSL/TLS 模式请使用 Full 或 Full (Strict)，推荐 Full (Strict)；不要使用 Flexible。"
    alert "请确认 Cloudflare Network 中 WebSockets 已开启。"
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 状态文件不存在：${STATE_FILE}"
    unset STATE_VERSION
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}"
}

load_state() {
    local variable env_name
    local -a variables=(
        PROTOCOL NODE_NAME NODE_HOST VLESS_UUID REALITY_TARGET
        REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
        VLESS_WSS_DOMAIN WS_PATH XRAY_LOOPBACK_PORT
        ANYTLS_DOMAIN ANYTLS_PASSWORD SUB_PORT_MODE ALLOWED_TOKENS
        WORKER_NAME WORKER_URL CF_ACCOUNT_ID DEPLOY_MODE SUB_DOWNLOAD_NAME
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
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
    XRAY_LOOPBACK_PORT=${XRAY_LOOPBACK_PORT:-${DEFAULT_XRAY_LOOPBACK_PORT}}
    WORKER_NAME=${WORKER_NAME:-${DEFAULT_WORKER_NAME}}
    [[ "${DEPLOY_MODE}" == "manual" ]] && DEPLOY_MODE="worker"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    [[ -z "${ALLOWED_TOKENS:-}" ]] || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
        || die "状态文件中的 ALLOWED_TOKENS 无效"
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX")
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        printf 'PROTOCOL=%q\n' "${PROTOCOL}"
        printf 'NODE_NAME=%q\n' "${NODE_NAME}"
        printf 'NODE_HOST=%q\n' "${NODE_HOST:-}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID:-}"
        printf 'REALITY_TARGET=%q\n' "${REALITY_TARGET:-}"
        printf 'REALITY_PRIVATE_KEY=%q\n' "${REALITY_PRIVATE_KEY:-}"
        printf 'REALITY_PUBLIC_KEY=%q\n' "${REALITY_PUBLIC_KEY:-}"
        printf 'REALITY_SHORT_ID=%q\n' "${REALITY_SHORT_ID:-}"
        printf 'VLESS_WSS_DOMAIN=%q\n' "${VLESS_WSS_DOMAIN:-}"
        printf 'WS_PATH=%q\n' "${WS_PATH:-}"
        printf 'XRAY_LOOPBACK_PORT=%q\n' "${XRAY_LOOPBACK_PORT:-${DEFAULT_XRAY_LOOPBACK_PORT}}"
        printf 'ANYTLS_DOMAIN=%q\n' "${ANYTLS_DOMAIN:-}"
        printf 'ANYTLS_PASSWORD=%q\n' "${ANYTLS_PASSWORD:-}"
        printf 'SUB_PORT_MODE=%q\n' "${SUB_PORT_MODE:-443}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'WORKER_NAME=%q\n' "${WORKER_NAME:-${DEFAULT_WORKER_NAME}}"
        printf 'WORKER_URL=%q\n' "${WORKER_URL:-}"
        printf 'CF_ACCOUNT_ID=%q\n' "${CF_ACCOUNT_ID:-}"
        printf 'DEPLOY_MODE=%q\n' "${DEPLOY_MODE:-}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

validate_protocol() {
    [[ "$1" == "reality" || "$1" == "anytls" || "$1" == "vless-wss" ]]
}

choose_protocol() {
    local requested=${1:-${PROTOCOL:-}}
    if [[ -z "${requested}" && -t 0 ]]; then
        printf '请选择协议：\n'
        printf '  1. VLESS Reality Vision\n'
        printf '  2. AnyTLS\n'
        printf '  3. VLESS WebSocket TLS（仅推荐移动宽带选择）\n'
        read -r -p "请选择 [1]: " requested
    fi
    requested=${requested:-reality}
    case "${requested}" in
    1 | reality) PROTOCOL="reality" ;;
    2 | anytls) PROTOCOL="anytls" ;;
    3 | vless-wss | wss) PROTOCOL="vless-wss" ;;
    *) die "不支持的协议：${requested}" ;;
    esac
    if [[ "${PROTOCOL}" == "vless-wss" ]]; then
        warn "VLESS WebSocket TLS 仅推荐移动宽带用户选择。"
    fi
}

protocol_default_node_name() {
    case "${PROTOCOL}" in
    reality) printf '%s' "${DEFAULT_REALITY_NODE_NAME}" ;;
    anytls) printf '%s' "${DEFAULT_ANYTLS_NODE_NAME}" ;;
    vless-wss) printf '%s' "${DEFAULT_WSS_NODE_NAME}" ;;
    esac
}

validate_reality_target() {
    local target=$1 host port
    [[ "${target}" == *:* ]] || return 1
    host=${target%:*}
    port=${target##*:}
    validate_domain "${host}" || return 1
    [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

collect_install_inputs() {
    validate_protocol "${PROTOCOL}" || die "PROTOCOL 无效：${PROTOCOL:-空}"
    NODE_NAME=${NODE_NAME:-$(protocol_default_node_name)}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"
    case "${PROTOCOL}" in
    reality)
        NODE_HOST=${NODE_HOST:-$(prompt_value "Reality 节点公网 IPv4 或域名" "")}
        validate_domain "${NODE_HOST}" || validate_ipv4 "${NODE_HOST}" \
            || die "Reality 节点地址无效：${NODE_HOST}"
        REALITY_TARGET=${REALITY_TARGET:-${DEFAULT_REALITY_TARGET}}
        validate_reality_target "${REALITY_TARGET}" || die "REALITY_TARGET 无效：${REALITY_TARGET}"
        SUB_PORT_MODE=${SUB_PORT_MODE:-${DEFAULT_REALITY_PORT_MODE}}
        ;;
    anytls)
        ANYTLS_DOMAIN=${ANYTLS_DOMAIN:-$(prompt_value "AnyTLS 完整域名（A 记录必须灰云直连本机）" "")}
        ANYTLS_DOMAIN=$(normalize_domain "${ANYTLS_DOMAIN}")
        validate_domain "${ANYTLS_DOMAIN}" || die "AnyTLS 域名无效：${ANYTLS_DOMAIN}"
        ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(generate_secret)}
        ((${#ANYTLS_PASSWORD} >= 16)) || die "ANYTLS_PASSWORD 至少需要 16 个字符"
        SUB_PORT_MODE=${SUB_PORT_MODE:-${DEFAULT_ANYTLS_PORT_MODE}}
        ;;
    vless-wss)
        VLESS_WSS_DOMAIN=${VLESS_WSS_DOMAIN:-$(prompt_value "VLESS WSS 域名（安装前必须灰云）" "")}
        VLESS_WSS_DOMAIN=$(normalize_domain "${VLESS_WSS_DOMAIN}")
        validate_domain "${VLESS_WSS_DOMAIN}" || die "VLESS WSS 域名无效：${VLESS_WSS_DOMAIN}"
        WS_PATH=${WS_PATH:-$(generate_ws_path)}
        validate_ws_path "${WS_PATH}" || die "WS_PATH 无效：${WS_PATH}"
        XRAY_LOOPBACK_PORT=${XRAY_LOOPBACK_PORT:-${DEFAULT_XRAY_LOOPBACK_PORT}}
        [[ "${XRAY_LOOPBACK_PORT}" =~ ^[0-9]+$ ]] \
            && ((XRAY_LOOPBACK_PORT >= 1024 && XRAY_LOOPBACK_PORT <= 65535)) \
            || die "XRAY_LOOPBACK_PORT 无效：${XRAY_LOOPBACK_PORT}"
        SUB_PORT_MODE="443"
        ;;
    esac
    [[ "${SUB_PORT_MODE}" == "443" || "${SUB_PORT_MODE}" == "dynamic" ]] \
        || die "SUB_PORT_MODE 无效：${SUB_PORT_MODE}"
    [[ "${PROTOCOL}" != "vless-wss" || "${SUB_PORT_MODE}" == "443" ]] \
        || die "VLESS WSS 不支持 dynamic 端口"
    ensure_allowed_tokens
    WORKER_NAME=${WORKER_NAME:-${DEFAULT_WORKER_NAME}}
    validate_worker_name "${WORKER_NAME}" || die "Worker 名称无效：${WORKER_NAME}"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
}

check_install_conflicts() {
    local legacy
    for legacy in /etc/easy_reality /etc/easy_anytls /etc/easy_vless_wss; do
        [[ ! -d "${legacy}" ]] \
            || die "检测到不兼容的旧安装 ${legacy}；请先使用对应旧命令卸载"
    done
    [[ "${SWITCH_IN_PROGRESS:-0}" == "1" ]] && return 0
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
    info "nftables 将放行 SSH 端口：${SSH_PORTS}"
}

configure_nftables() {
    local ssh_ports candidate backup extra_port
    detect_ssh_ports
    ssh_ports=${SSH_PORTS}
    extra_port=""
    [[ "${PROTOCOL}" == "vless-wss" ]] && extra_port=", 80"
    install -d -m 0700 "${BACKUP_DIR}"
    if [[ ! -e "${BACKUP_DIR}/pre-install-nftables.conf" \
        && ! -e "${BACKUP_DIR}/pre-install-nftables.missing" ]]; then
        if [[ -f "${NFT_CONFIG}" ]]; then
            install -m 0644 "${NFT_CONFIG}" "${BACKUP_DIR}/pre-install-nftables.conf"
        else
            install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-nftables.missing"
        fi
    fi
    if [[ -f "${NFT_CONFIG}" ]]; then
        backup="${BACKUP_DIR}/nftables.$(date +%Y%m%d%H%M%S).bak"
        install -m 0644 "${NFT_CONFIG}" "${backup}"
    fi
    candidate="${RUNTIME_TMP}/nftables.conf"
    cat >"${candidate}" <<EOF
#!/usr/sbin/nft -f
flush ruleset

EOF
    if [[ "${SUB_PORT_MODE}" == "dynamic" ]]; then
        cat >>"${candidate}" <<EOF
table inet nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${PORT_BASE}-65535 redirect to :${SERVICE_PORT}
    }
}

EOF
    fi
    cat >>"${candidate}" <<EOF
table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;
        iifname "lo" accept
        ct state invalid drop
        ct state { established, related } accept
        meta l4proto { icmp, ipv6-icmp } accept
        tcp dport { ${ssh_ports}, ${SERVICE_PORT}${extra_port} } accept
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
    nft -c -f "${candidate}" || die "nftables 配置校验失败"
    install -m 0644 "${candidate}" "${NFT_CONFIG}"
    sha256sum "${candidate}" | awk '{print $1}' >"${STATE_DIR}/nftables.sha256"
    chmod 0600 "${STATE_DIR}/nftables.sha256"
    systemctl enable --now nftables >/dev/null 2>&1 || die "启用 nftables 失败"
    nft -f "${NFT_CONFIG}" || die "加载 nftables 配置失败"
}

install_acme() {
    if [[ -x "${ACME_BIN}" ]]; then
        return 0
    fi
    local cert_domain=${ANYTLS_DOMAIN:-${VLESS_WSS_DOMAIN:-example.com}}
    local account_email=${ACME_EMAIL:-admin@${cert_domain}}
    local installer="${RUNTIME_TMP}/get-acme.sh"
    curl -fsSL --retry 3 https://get.acme.sh -o "${installer}" || die "下载 acme.sh 安装器失败"
    sh "${installer}" "email=${account_email}" --home "${ACME_HOME}" \
        || die "安装 acme.sh 失败"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装后未找到 ${ACME_BIN}"
    install -d -m 0700 "${STATE_DIR}"
    install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
}

collect_cloudflare_dns_credentials() {
    if [[ -z "${CF_DNS_API_TOKEN:-}" ]]; then
        CF_DNS_API_TOKEN=$(prompt_secret "Cloudflare DNS API Token（用于 acme.sh DNS-01，输入不回显）") \
            || die "非交互模式必须设置 CF_DNS_API_TOKEN"
    fi
    [[ -n "${CF_DNS_API_TOKEN}" ]] || die "Cloudflare DNS API Token 不能为空"
}

issue_certificate() {
    local cert_domain
    case "${PROTOCOL}" in
    anytls) cert_domain=${ANYTLS_DOMAIN} ;;
    vless-wss) cert_domain=${VLESS_WSS_DOMAIN} ;;
    *) die "Reality 不需要 TLS 证书" ;;
    esac
    install_acme
    collect_cloudflare_dns_credentials
    export CF_Token="${CF_DNS_API_TOKEN}"
    "${ACME_BIN}" --set-default-ca --server letsencrypt >/dev/null
    local issue_status=0
    "${ACME_BIN}" --issue --dns dns_cf -d "${cert_domain}" --keylength ec-256 \
        || issue_status=$?
    [[ "${issue_status}" == "0" || "${issue_status}" == "2" ]] \
        || die "Let's Encrypt 证书申请失败（acme.sh 返回码 ${issue_status}）"
    install -d -m 0700 "${CERT_DIR}" "${COMMAND_INSTALL_DIR}"
    cat >"${RUNTIME_TMP}/reload-tls-service.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files nginx.service >/dev/null 2>&1; then
    systemctl reload nginx.service >/dev/null 2>&1 || systemctl restart nginx.service >/dev/null 2>&1 || true
fi
if command -v systemctl >/dev/null 2>&1 && systemctl list-unit-files easy-all-sing-box.service >/dev/null 2>&1; then
    systemctl restart easy-all-sing-box.service >/dev/null 2>&1 || true
fi
EOF
    install -m 0755 "${RUNTIME_TMP}/reload-tls-service.sh" "${CERT_RELOAD_HOOK}"
    "${ACME_BIN}" --install-cert -d "${cert_domain}" --ecc \
        --fullchain-file "${CERT_FILE}" \
        --key-file "${KEY_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}" \
        || die "安装证书到 easy_all 目录失败"
    unset CF_Token CF_DNS_API_TOKEN
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
    install -d -m 0755 "${XRAY_DIR}"
    case "${PROTOCOL}" in
    reality)
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
        jq -n \
            --arg uuid "${VLESS_UUID}" \
            --arg target "${REALITY_TARGET}" \
            --arg private_key "${REALITY_PRIVATE_KEY}" \
            --arg short_id "${REALITY_SHORT_ID}" \
            --arg sni "${REALITY_TARGET%:*}" '
            {
              log: {loglevel: "warning"},
              inbounds: [{
                tag: "vless-reality-in",
                listen: "0.0.0.0",
                port: 443,
                protocol: "vless",
                settings: {
                  clients: [{id: $uuid, flow: "xtls-rprx-vision"}],
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
                }
              }],
              outbounds: [{protocol: "freedom", tag: "direct"}]
            }' >"${RUNTIME_TMP}/xray-config.json"
        ;;
    vless-wss)
        jq -n \
            --argjson port "${XRAY_LOOPBACK_PORT}" \
            --arg uuid "${VLESS_UUID}" \
            --arg node_name "${NODE_NAME}" \
            --arg path "${WS_PATH}" '
            {
              log: {loglevel: "warning"},
              inbounds: [{
                tag: "vless-ws-in",
                listen: "127.0.0.1",
                port: $port,
                protocol: "vless",
                settings: {
                  clients: [{id: $uuid, email: $node_name}],
                  decryption: "none"
                },
                streamSettings: {
                  network: "ws",
                  wsSettings: {path: $path}
                }
              }],
              outbounds: [{protocol: "freedom", tag: "direct"}]
            }' >"${RUNTIME_TMP}/xray-config.json"
        ;;
    *) die "协议 ${PROTOCOL} 不使用 Xray" ;;
    esac
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray ${PROTOCOL} 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

install_xray_service() {
    cat >"${RUNTIME_TMP}/easy-all-xray.service" <<EOF
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
    install -m 0644 "${RUNTIME_TMP}/easy-all-xray.service" "${XRAY_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${XRAY_SERVICE}" >/dev/null || die "启动 Xray 服务失败"
}

resolve_sing_box_version() {
    local selector=${SING_BOX_VERSION:-latest} releases
    case "${selector}" in
    latest)
        curl -fsSL --retry 3 "${SING_BOX_RELEASES_API}" | jq -er '.tag_name | ltrimstr("v")'
        ;;
    alpha)
        releases=$(curl -fsSL --retry 3 \
            "https://api.github.com/repos/SagerNet/sing-box/releases?per_page=20")
        jq -er '[.[] | select(.prerelease == true)][0].tag_name | ltrimstr("v")' <<<"${releases}"
        ;;
    v*) printf '%s\n' "${selector#v}" ;;
    *) printf '%s\n' "${selector}" ;;
    esac
}

download_sing_box() {
    local version archive_name base_url temp_dir archive checksums expected actual
    version=$(resolve_sing_box_version) || die "无法解析 sing-box 版本"
    [[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][A-Za-z0-9.-]+)?$ ]] \
        || die "sing-box 版本无效：${version}"
    archive_name="sing-box-${version}-linux-amd64.tar.gz"
    base_url="https://github.com/SagerNet/sing-box/releases/download/v${version}"
    temp_dir=$(make_temp_dir)
    archive="${temp_dir}/${archive_name}"
    checksums="${temp_dir}/checksums.txt"
    curl -fL --retry 3 "${base_url}/${archive_name}" -o "${archive}" \
        || die "下载 sing-box ${version} 失败"
    curl -fL --retry 3 "${base_url}/sing-box-${version}-checksums.txt" -o "${checksums}" \
        || die "下载 sing-box 校验文件失败"
    expected=$(awk -v name="${archive_name}" '$2 == name || $2 == "*" name {print $1; exit}' "${checksums}")
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ -n "${expected}" && "${expected,,}" == "${actual,,}" ]] \
        || die "sing-box SHA256 校验失败"
    tar -xzf "${archive}" -C "${temp_dir}"
    install -d -m 0755 "${SING_BOX_DIR}"
    install -m 0755 \
        "${temp_dir}/sing-box-${version}-linux-amd64/sing-box" \
        "${SING_BOX_BIN}"
    printf '%s\n' "${version}" >"${SING_BOX_DIR}/version"
}

write_sing_box_config() {
    local listen_addr="0.0.0.0"
    ip -6 addr show scope global 2>/dev/null | grep -q "inet6" && listen_addr="::"
    install -d -m 0755 "${SING_BOX_DIR}"
    jq -n \
        --arg listen "${listen_addr}" \
        --arg password "${ANYTLS_PASSWORD}" \
        --arg cert "${CERT_FILE}" \
        --arg key "${KEY_FILE}" '
        {
          log: {level: "warn", timestamp: true},
          inbounds: [{
            type: "anytls",
            tag: "anytls-in",
            listen: $listen,
            listen_port: 443,
            users: [{name: "default", password: $password}],
            tls: {
              enabled: true,
              certificate_path: $cert,
              key_path: $key
            }
          }],
          outbounds: [{type: "direct", tag: "direct"}]
        }' >"${RUNTIME_TMP}/sing-box-config.json"
    "${SING_BOX_BIN}" check -c "${RUNTIME_TMP}/sing-box-config.json" >/dev/null \
        || die "sing-box AnyTLS 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/sing-box-config.json" "${SING_BOX_CONFIG}"
}

install_sing_box_service() {
    cat >"${RUNTIME_TMP}/easy-all-sing-box.service" <<EOF
[Unit]
Description=sing-box AnyTLS managed by easy_all
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy-all-sing-box.service" "${SING_BOX_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${SING_BOX_SERVICE}" >/dev/null \
        || die "启动 sing-box 服务失败"
}

write_web_root() {
    install -d -m 0755 "${WEB_ROOT}"
    cat >"${RUNTIME_TMP}/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>Welcome</title>
  <style>
    body { font-family: system-ui, sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #f6f7fb; color: #222; }
    main { max-width: 680px; padding: 40px; border-radius: 20px; background: white; box-shadow: 0 20px 70px rgba(0,0,0,.08); }
  </style>
</head>
<body><main><h1>Welcome</h1><p>This site is running normally.</p></main></body>
</html>
EOF
    install -m 0644 "${RUNTIME_TMP}/index.html" "${WEB_ROOT}/index.html"
}

write_nginx_config() {
    write_web_root
    cat >"${RUNTIME_TMP}/easy_all.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${VLESS_WSS_DOMAIN};
    return 301 https://\$host\$request_uri;
}

server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name ${VLESS_WSS_DOMAIN};

    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    root ${WEB_ROOT};
    index index.html;

    location = ${WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${XRAY_LOOPBACK_PORT};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
    }

    location / {
        try_files \$uri \$uri/ /index.html;
    }
}
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

uri_encode() {
    jq -nr --arg v "$1" '$v|@uri'
}

build_vless_wss_link() {
    local path
    path=$(uri_encode "${WS_PATH}")
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&path=%s&host=%s#%s' \
        "${VLESS_UUID}" "${VLESS_WSS_DOMAIN}" "${VLESS_WSS_DOMAIN}" \
        "${path}" "${VLESS_WSS_DOMAIN}" "$(uri_encode "${NODE_NAME}")"
}

build_reality_link() {
    printf 'vless://%s@%s:443?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${NODE_HOST}" "${REALITY_TARGET%:*}" \
        "$(uri_encode "${REALITY_PUBLIC_KEY}")" "$(uri_encode "${REALITY_SHORT_ID}")" \
        "$(uri_encode "${NODE_NAME}")"
}

build_anytls_link() {
    printf 'anytls://%s@%s:443/?sni=%s&insecure=0#%s' \
        "$(uri_encode "${ANYTLS_PASSWORD}")" "${ANYTLS_DOMAIN}" \
        "$(uri_encode "${ANYTLS_DOMAIN}")" "$(uri_encode "${NODE_NAME}")"
}

build_node_link() {
    case "${PROTOCOL}" in
    reality) build_reality_link ;;
    anytls) build_anytls_link ;;
    vless-wss) build_vless_wss_link ;;
    esac
}

build_mihomo_node() {
    case "${PROTOCOL}" in
    reality)
        jq -nr \
            --arg name "${NODE_NAME}" --arg server "${NODE_HOST}" \
            --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
            --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" '
            "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
            "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
            "    servername: \($sni|@json)\n    client-fingerprint: chrome\n    reality-opts:\n" +
            "      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n    flow: xtls-rprx-vision\n"'
        ;;
    anytls)
        jq -nr \
            --arg name "${NODE_NAME}" --arg server "${ANYTLS_DOMAIN}" \
            --arg password "${ANYTLS_PASSWORD}" '
            "  - name: \($name|@json)\n    type: anytls\n    server: \($server|@json)\n    port: 443\n" +
            "    password: \($password|@json)\n    udp: true\n    sni: \($server|@json)\n" +
            "    client-fingerprint: chrome\n    skip-cert-verify: false\n"'
        ;;
    vless-wss)
        jq -nr \
            --arg name "${NODE_NAME}" --arg server "${VLESS_WSS_DOMAIN}" \
            --arg uuid "${VLESS_UUID}" --arg path "${WS_PATH}" '
            "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
            "    uuid: \($uuid|@json)\n    network: ws\n    tls: true\n    udp: true\n" +
            "    skip-cert-verify: false\n    servername: \($server|@json)\n    client-fingerprint: chrome\n" +
            "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($server|@json)\n"'
        ;;
    esac
}

validate_sample_worker() {
    local source=$1 marker count config_start config_end rules_start rules_end
    [[ -s "${source}" ]] || die "sample-worker.js 为空：${source}"
    for marker in \
        "// EASY_ALL_CONFIG_START" \
        "// EASY_ALL_CONFIG_END" \
        "// EASY_ALL_RULES_START" \
        "// EASY_ALL_RULES_END"; do
        count=$(grep -Fxc "${marker}" "${source}" || true)
        [[ "${count}" == "1" ]] \
            || die "sample-worker.js 模板标记无效：${marker} 应且只能出现一次"
    done
    grep -Fq "const EMBEDDED_CLASH_RULES = " "${source}" \
        || die "sample-worker.js 缺少 Mihomo 规则"
    grep -Fq "export default {" "${source}" \
        || die "sample-worker.js 缺少 Worker module 入口"
    config_start=$(grep -Fn "// EASY_ALL_CONFIG_START" "${source}" | cut -d: -f1)
    config_end=$(grep -Fn "// EASY_ALL_CONFIG_END" "${source}" | cut -d: -f1)
    rules_start=$(grep -Fn "// EASY_ALL_RULES_START" "${source}" | cut -d: -f1)
    rules_end=$(grep -Fn "// EASY_ALL_RULES_END" "${source}" | cut -d: -f1)
    ((config_start < config_end && config_end < rules_start && rules_start < rules_end)) \
        || die "sample-worker.js 模板区块顺序无效"
}

fetch_sample_worker() {
    local destination=$1 source=${SAMPLE_WORKER_SOURCE:-} url
    if [[ -n "${source}" ]]; then
        if [[ -f "${source}" ]]; then
            install -m 0600 "${source}" "${destination}"
        elif [[ "${source}" =~ ^https:// ]]; then
            curl -fsSL --retry 3 "${source}" -o "${destination}" \
                || die "下载 sample-worker.js 失败：${source}"
            chmod 0600 "${destination}"
        else
            die "SAMPLE_WORKER_SOURCE 必须是本地文件或 HTTPS URL：${source}"
        fi
        validate_sample_worker "${destination}"
        return
    fi

    url=${SAMPLE_WORKER_URL:-${DEFAULT_SAMPLE_WORKER_URL}}
    [[ "${url}" =~ ^https:// ]] \
        || die "SAMPLE_WORKER_URL 必须使用 HTTPS：${url}"
    curl -fsSL --retry 3 "${url}" -o "${destination}" \
        || die "下载 sample-worker.js 失败：${url}"
    chmod 0600 "${destination}"
    validate_sample_worker "${destination}"
}

render_worker_from_sample() {
    local template=$1 config=$2 destination=$3
    awk -v config="${config}" '
        $0 == "// EASY_ALL_CONFIG_START" {
            print
            while ((getline line < config) > 0) {
                print line
            }
            close(config)
            replacing = 1
            next
        }
        $0 == "// EASY_ALL_CONFIG_END" {
            replacing = 0
            print
            next
        }
        replacing != 1 {
            print
        }
    ' "${template}" >"${destination}" \
        || die "从 sample-worker.js 生成 Worker 失败"
}

write_worker() {
    local destination=$1 config_json allowed_tokens_json template_file config_file output_file
    install -d -m 0700 "$(dirname "${destination}")"
    ensure_allowed_tokens
    allowed_tokens_json=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
        || die "ALLOWED_TOKENS 无效"
    case "${PROTOCOL}" in
    reality)
        config_json=$(jq -cn \
            --arg type vless --arg security reality --arg network tcp \
            --arg uuid "${VLESS_UUID}" --arg host "${NODE_HOST}" --arg name "${NODE_NAME}" \
            --arg sni "${REALITY_TARGET%:*}" --arg pbk "${REALITY_PUBLIC_KEY}" \
            --arg sid "${REALITY_SHORT_ID}" --arg port_mode "${SUB_PORT_MODE}" \
            --arg fp chrome \
            '{type:$type,security:$security,network:$network,uuid:$uuid,host:$host,name:$name,fp:$fp,sni:$sni,pbk:$pbk,sid:$sid,portMode:$port_mode}')
        ;;
    anytls)
        config_json=$(jq -cn \
            --arg type anytls --arg host "${ANYTLS_DOMAIN}" --arg name "${NODE_NAME}" \
            --arg password "${ANYTLS_PASSWORD}" --arg sni "${ANYTLS_DOMAIN}" \
            --arg port_mode "${SUB_PORT_MODE}" --arg fp chrome \
            '{type:$type,host:$host,name:$name,password:$password,sni:$sni,fp:$fp,udp:true,insecure:false,portMode:$port_mode}')
        ;;
    vless-wss)
        config_json=$(jq -cn \
            --arg type vless --arg security tls --arg network ws \
            --arg uuid "${VLESS_UUID}" --arg host "${VLESS_WSS_DOMAIN}" --arg name "${NODE_NAME}" \
            --arg sni "${VLESS_WSS_DOMAIN}" --arg path "${WS_PATH}" --arg fp chrome \
            '{type:$type,security:$security,network:$network,uuid:$uuid,host:$host,name:$name,fp:$fp,sni:$sni,path:$path,portMode:"443"}')
        ;;
    esac

    template_file="${RUNTIME_TMP}/sample-worker.js"
    config_file="${RUNTIME_TMP}/worker-config.js"
    output_file="${RUNTIME_TMP}/worker.js"
    fetch_sample_worker "${template_file}"
    {
        printf 'const ALLOWED_TOKENS = %s;\n' "${allowed_tokens_json}"
        printf 'const ALLOWED_TOKEN_VALUES = new Set(Object.values(ALLOWED_TOKENS));\n\n'
        printf 'const PORT_BASE = 10000;\n'
        printf 'const PORT_MULTIPLIER = 6;\n'
        printf 'const DEFAULT_SUB_DOWNLOAD_NAME = %s;\n' \
            "$(jq -Rn --arg value "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}" '$value')"
        cat <<'EOF'
const CONFIGS = [];

function defineNode(config) {
    CONFIGS.push(config);
    return config;
}

function isAllowedToken(token) {
    return Boolean(token && ALLOWED_TOKEN_VALUES.has(token));
}
EOF
        printf '\nconst NODE_CONFIG = defineNode(%s);\n' "${config_json}"
        cat <<'EOF'

const DEFAULT_NODE = NODE_CONFIG; // 控制默认输出的节点，支持 [NODE_CONFIG, ...]

function defaultNodeConfigs() {
    return Array.isArray(DEFAULT_NODE) ? DEFAULT_NODE : [DEFAULT_NODE];
}
EOF
    } >"${config_file}"
    render_worker_from_sample "${template_file}" "${config_file}" "${output_file}"
    install -m 0600 "${output_file}" "${destination}"
}

choose_subscription_mode() {
    local mode=${SUBSCRIBE_MODE:-${DEPLOY_MODE:-}}
    if [[ -z "${mode}" && -t 0 ]]; then
        printf '请选择订阅输出方式：\n'
        printf '  1. 自动部署 Cloudflare Worker\n'
        printf '  2. 输出 Worker 内容，手动部署\n'
        printf '  3. 只输出当前协议链接\n'
        read -r -p "请选择 [2]: " mode
    fi
    mode=${mode:-worker}
    case "${mode}" in
    1 | auto) SUBSCRIBE_MODE="auto" ;;
    2 | worker | manual) SUBSCRIBE_MODE="worker" ;;
    3 | link | vless) SUBSCRIBE_MODE="link" ;;
    *) die "订阅输出方式无效：${mode}" ;;
    esac
}

cloudflare_deploy_log() {
    local level=$1
    shift
    local timestamp line message secret_name secret
    message=$*
    for secret_name in \
        CF_API_TOKEN CF_WORKER_API_TOKEN XRAY_UUID VLESS_UUID \
        ANYTLS_PASSWORD REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID; do
        secret=${!secret_name:-}
        [[ -n "${secret}" ]] && message=${message//${secret}/[REDACTED]}
    done
    if [[ -n "${ALLOWED_TOKENS:-}" ]]; then
        while IFS= read -r secret; do
            [[ -n "${secret}" ]] && message=${message//${secret}/[REDACTED]}
        done < <(jq -r '.[]? | strings' <<<"${ALLOWED_TOKENS}" 2>/dev/null || true)
    fi
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    line="[${timestamp}] [${level}] ${message}"
    printf '[Cloudflare Worker] %s\n' "${line}" >&2
    if [[ -d "${STATE_DIR}" ]]; then
        {
            printf '%s\n' "${line}" >>"${CLOUDFLARE_DEPLOY_LOG}"
            chmod 0600 "${CLOUDFLARE_DEPLOY_LOG}"
        } 2>/dev/null || true
    fi
}

prepare_cloudflare_deploy_log() {
    install -d -m 0700 "${STATE_DIR}"
    : >"${CLOUDFLARE_DEPLOY_LOG}"
    chmod 0600 "${CLOUDFLARE_DEPLOY_LOG}"
    info "Cloudflare Worker 部署日志：${CLOUDFLARE_DEPLOY_LOG}"
}

mask_cloudflare_identifier() {
    local value=$1
    if ((${#value} <= 8)); then
        printf '%s' '***'
    else
        printf '%s...%s' "${value:0:4}" "${value: -4}"
    fi
}

cloudflare_retry_delay() {
    local attempt=$1 retry_after=${2:-} delay
    if [[ "${retry_after}" =~ ^[0-9]+$ ]] && ((retry_after > 0)); then
        delay=${retry_after}
    else
        delay=$((1 << (attempt - 1)))
    fi
    ((delay > 30)) && delay=30
    printf '%s\n' "${delay}"
}

cloudflare_api() {
    local method=$1 path=$2 stage=$3
    shift 3
    local header_file="${RUNTIME_TMP}/cf-worker-headers"
    local body_file="${RUNTIME_TMP}/cf-worker-body"
    local response_headers="${RUNTIME_TMP}/cf-worker-response-headers"
    local error_file="${RUNTIME_TMP}/cf-worker-curl-error"
    local attempt max_attempts=5 curl_exit http_meta http_code elapsed
    local response retry_after cf_ray api_codes retryable delay curl_error
    {
        printf 'Authorization: Bearer %s\n' "${CF_WORKER_API_TOKEN}"
        printf 'Accept: application/json\n'
    } >"${header_file}"
    chmod 0600 "${header_file}"

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        : >"${body_file}"
        : >"${response_headers}"
        : >"${error_file}"
        cloudflare_deploy_log "INFO" \
            "${stage}：第 ${attempt}/${max_attempts} 次请求"
        if http_meta=$(curl -sS \
            --connect-timeout 10 \
            --max-time 90 \
            -X "${method}" \
            -H "@${header_file}" \
            -D "${response_headers}" \
            -o "${body_file}" \
            -w $'%{http_code}\t%{time_total}' \
            "https://api.cloudflare.com/client/v4${path}" "$@" \
            2>"${error_file}"); then
            curl_exit=0
        else
            curl_exit=$?
        fi
        response=$(<"${body_file}")
        IFS=$'\t' read -r http_code elapsed <<<"${http_meta:-000	0}"
        retry_after=$(tr -d '\r' <"${response_headers}" \
            | sed -n 's/^[Rr][Ee][Tt][Rr][Yy]-[Aa][Ff][Tt][Ee][Rr]:[[:space:]]*//p' \
            | head -n 1)
        cf_ray=$(tr -d '\r' <"${response_headers}" \
            | sed -n 's/^[Cc][Ff]-[Rr][Aa][Yy]:[[:space:]]*//p' \
            | head -n 1)
        api_codes=$(jq -r '[.errors[]?.code | tostring] | join(",")' \
            <<<"${response}" 2>/dev/null || true)

        if ((curl_exit != 0)); then
            curl_error=$(tr '\r\n' '  ' <"${error_file}" | cut -c1-500)
            if ((attempt == max_attempts)); then
                cloudflare_deploy_log "ERROR" \
                    "${stage}：网络请求失败，curl=${curl_exit}，${curl_error:-无详细信息}"
                printf '%s' "${response}"
                return "${curl_exit}"
            fi
            delay=$(cloudflare_retry_delay "${attempt}" "")
            cloudflare_deploy_log "WARN" \
                "${stage}：网络请求失败，curl=${curl_exit}，${delay} 秒后重试；${curl_error:-无详细信息}"
            sleep "${delay}"
            continue
        fi

        retryable=0
        case "${http_code}" in
        408 | 429 | 500 | 502 | 503 | 504 | 520 | 521 | 522 | 523 | 524) retryable=1 ;;
        esac
        case ",${api_codes}," in
        *,10007,* | *,10035,*) retryable=1 ;;
        esac
        if ((retryable == 1 && attempt < max_attempts)); then
            delay=$(cloudflare_retry_delay "${attempt}" "${retry_after}")
            cloudflare_deploy_log "WARN" \
                "${stage}：HTTP ${http_code}，API 错误码 ${api_codes:-无}，Ray ID ${cf_ray:-无}，${delay} 秒后重试"
            sleep "${delay}"
            continue
        fi

        cloudflare_deploy_log "INFO" \
            "${stage}：HTTP ${http_code}，耗时 ${elapsed:-未知}s，API 错误码 ${api_codes:-无}，Ray ID ${cf_ray:-无}"
        printf '%s' "${response}"
        return 0
    done
}

report_cloudflare_api_failure() {
    local context=$1 response=$2 details
    if details=$(jq -er '[.errors[]? | if .code then "[\(.code)] \(.message)" else .message end] | select(length > 0) | join("\n")' <<<"${response}"); then
        cloudflare_deploy_log "ERROR" \
            "${context}：$(tr '\r\n' '  ' <<<"${details}" | cut -c1-1000)"
        printf '%s\n' "${details}" >&2
    else
        cloudflare_deploy_log "ERROR" \
            "${context}：$(tr '\r\n' '  ' <<<"${response}" | cut -c1-1000)"
        printf '%s\n' "${response}" >&2
    fi
}

deploy_worker() {
    local metadata response subdomain worker_module_file
    WORKER_REPLACED=0
    CF_ACCOUNT_ID=${CF_ACCOUNT_ID:-$(prompt_value "Cloudflare Account ID" "")}
    [[ -n "${CF_ACCOUNT_ID}" ]] || {
        warn "Cloudflare Account ID 为空"
        return 1
    }
    if [[ -z "${CF_WORKER_API_TOKEN:-}" ]]; then
        CF_WORKER_API_TOKEN=$(prompt_secret "Cloudflare Worker API Token（输入不回显）") || {
            warn "非交互模式必须设置 CF_WORKER_API_TOKEN"
            return 1
        }
    fi
    WORKER_NAME=${WORKER_NAME:-${DEFAULT_WORKER_NAME}}
    validate_worker_name "${WORKER_NAME}" || {
        warn "Worker 名称无效：${WORKER_NAME}"
        return 1
    }
    prepare_cloudflare_deploy_log
    cloudflare_deploy_log "INFO" \
        "开始部署：Worker=${WORKER_NAME}，Account=$(mask_cloudflare_identifier "${CF_ACCOUNT_ID}")"
    ensure_allowed_tokens
    metadata=$(jq -cn '{
      main_module: "worker.js",
      compatibility_date: "2026-01-01"
    }')
    worker_module_file="${RUNTIME_TMP}/worker-module.js"
    install -m 0600 "${WORKER_FILE}" "${worker_module_file}"
    response=$(cloudflare_api PUT \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
        "上传 Worker module" \
        -F "metadata=${metadata};type=application/json" \
        -F "worker.js=@${worker_module_file};filename=worker.js;type=application/javascript+module") || {
        cloudflare_deploy_log "ERROR" "上传 Worker module：网络层重试耗尽"
        return 1
    }
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        report_cloudflare_api_failure "Cloudflare Worker module 上传失败" "${response}"
        return 1
    }
    WORKER_REPLACED=1
    cloudflare_deploy_log "SUCCESS" "Worker module 上传成功"
    response=$(cloudflare_api POST \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" \
        "启用 workers.dev 路由" \
        -H "Content-Type: application/json" \
        --data '{"enabled":true,"previews_enabled":false}') || {
        cloudflare_deploy_log "ERROR" "启用 workers.dev 路由：网络层重试耗尽"
        return 1
    }
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        report_cloudflare_api_failure "启用 Worker workers.dev 地址失败" "${response}"
        return 1
    }
    cloudflare_deploy_log "SUCCESS" "workers.dev 路由已启用"
    response=$(cloudflare_api GET \
        "/accounts/${CF_ACCOUNT_ID}/workers/subdomain" \
        "读取账户 workers.dev 子域名") || {
        cloudflare_deploy_log "ERROR" "读取账户 workers.dev 子域名：网络层重试耗尽"
        return 1
    }
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        report_cloudflare_api_failure "读取账户 workers.dev 子域名失败" "${response}"
        return 1
    }
    subdomain=$(jq -er '.result.subdomain' <<<"${response}") || {
        report_cloudflare_api_failure "读取账户 workers.dev 子域名失败" "${response}"
        return 1
    }
    WORKER_URL="https://${WORKER_NAME}.${subdomain}.workers.dev"
    cloudflare_deploy_log "SUCCESS" "部署完成：${WORKER_URL}"
    unset CF_WORKER_API_TOKEN
}

verify_subscription() {
    local code attempt delay token
    local max_attempts=6
    [[ -n "${WORKER_URL:-}" ]] || return 1
    ensure_allowed_tokens
    token=$(first_allowed_token)
    cloudflare_deploy_log "INFO" "Worker 部署完成，等待 5 秒后开始订阅 HTTP 验收"
    sleep 5
    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
            "${WORKER_URL}/subscribe?token=${token}" || true)
        if [[ "${code}" == "200" ]]; then
            cloudflare_deploy_log "SUCCESS" \
                "订阅 HTTP 验收成功：第 ${attempt}/${max_attempts} 次，HTTP 200"
            return 0
        fi
        if ((attempt < max_attempts)); then
            delay=$((RANDOM % 3 + 1))
            cloudflare_deploy_log "WARN" \
                "订阅 HTTP 验收：第 ${attempt}/${max_attempts} 次返回 HTTP ${code:-000}，${delay} 秒后重试"
            sleep "${delay}"
        else
            cloudflare_deploy_log "WARN" \
                "订阅 HTTP 验收：第 ${attempt}/${max_attempts} 次返回 HTTP ${code:-000}"
        fi
    done
    cloudflare_deploy_log "ERROR" \
        "Worker API 部署成功，但订阅 HTTP 验收在 ${max_attempts} 次尝试后仍未通过"
    return 1
}

configure_subscription() {
    collect_installed_state
    choose_subscription_mode
    case "${SUBSCRIBE_MODE}" in
    auto)
        write_worker "${WORKER_FILE}"
        if deploy_worker; then
            DEPLOY_MODE="auto"
            if ! verify_subscription; then
                warn "Worker 已部署，但 HTTP 验收暂未通过；请查看 ${CLOUDFLARE_DEPLOY_LOG}"
            fi
        else
            if [[ "${STRICT_WORKER_DEPLOY:-0}" == "1" \
                && "${WORKER_REPLACED:-0}" == "1" ]]; then
                DEPLOY_MODE="auto"
                warn "Worker 源码已 replace，但后续路由查询失败；保留新协议，避免远端订阅与本机回滚后不一致"
            else
                WORKER_URL=""
                DEPLOY_MODE="worker"
                warn "自动部署失败，已保留 Worker 文件供手动部署；诊断日志：${CLOUDFLARE_DEPLOY_LOG}"
                [[ "${STRICT_WORKER_DEPLOY:-0}" != "1" ]] || return 1
                print_worker_content
            fi
        fi
        unset CF_WORKER_API_TOKEN || true
        ;;
    worker)
        write_worker "${WORKER_FILE}"
        WORKER_URL=""
        DEPLOY_MODE="worker"
        print_worker_content
        ;;
    link)
        WORKER_URL=""
        DEPLOY_MODE="link"
        ;;
    esac
    save_state
}

update_subscription() {
    local requested_port_mode=${SUB_PORT_MODE:-} stored_port_mode
    require_root
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    stored_port_mode=$(
        unset SUB_PORT_MODE
        source_state_file
        printf '%s' "${SUB_PORT_MODE:-443}"
    )
    collect_installed_state
    SUB_PORT_MODE=${requested_port_mode:-${SUB_PORT_MODE:-${stored_port_mode}}}
    [[ "${SUB_PORT_MODE}" == "443" || "${SUB_PORT_MODE}" == "dynamic" ]] \
        || die "SUB_PORT_MODE 无效：${SUB_PORT_MODE}"
    [[ "${PROTOCOL}" != "vless-wss" || "${SUB_PORT_MODE}" == "443" ]] \
        || die "VLESS WSS 不支持 dynamic 端口"
    if [[ "${SUB_PORT_MODE}" != "${stored_port_mode}" ]]; then
        info "订阅端口模式从 ${stored_port_mode} 切换为 ${SUB_PORT_MODE}，同步更新 nftables"
        configure_nftables
    fi
    configure_subscription
    show_subscription
}

update_easy_all() {
    require_root
    register_easy_all_command
    update_subscription
}

print_worker_content() {
    printf '\nWorker 内容如下，ALLOWED_TOKENS 已内嵌，请复制到 Cloudflare Worker：\n'
    printf '%s\n' '----- BEGIN easy_all Worker -----'
    cat "${WORKER_FILE}"
    printf '\n%s\n\n' '----- END easy_all Worker -----'
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    load_state
    validate_protocol "${PROTOCOL:-}" || die "状态文件中的 PROTOCOL 无效"
    case "${PROTOCOL}" in
    reality)
        [[ -n "${NODE_HOST:-}" && -n "${VLESS_UUID:-}" \
            && -n "${REALITY_PUBLIC_KEY:-}" && -n "${REALITY_SHORT_ID:-}" ]] \
            || die "Reality 状态不完整"
        ;;
    anytls)
        [[ -n "${ANYTLS_DOMAIN:-}" && -n "${ANYTLS_PASSWORD:-}" ]] \
            || die "AnyTLS 状态不完整"
        ;;
    vless-wss)
        [[ -n "${VLESS_WSS_DOMAIN:-}" && -n "${VLESS_UUID:-}" && -n "${WS_PATH:-}" ]] \
            || die "VLESS WSS 状态不完整"
        ;;
    esac
    ensure_allowed_tokens
    WORKER_NAME=${WORKER_NAME:-${DEFAULT_WORKER_NAME}}
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
    printf 'Worker 名称: %s\n' "${WORKER_NAME:-${DEFAULT_WORKER_NAME}}"
    printf 'Clash 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
    if [[ -n "${WORKER_URL:-}" ]]; then
        printf '\n订阅地址:\n'
        while IFS=$'\t' read -r user token; do
            printf '通用订阅 (%s): %s/subscribe?token=%s\n' "${user}" "${WORKER_URL}" "${token}"
            printf 'Clash Meta (%s): %s/subscribe?token=%s&flag=clash\n' "${user}" "${WORKER_URL}" "${token}"
        done < <(jq -r 'to_entries[] | [.key, .value] | @tsv' <<<"${ALLOWED_TOKENS}")
    elif [[ "${DEPLOY_MODE:-worker}" == "worker" ]]; then
        printf '\n部署方式: 手动部署；订阅 Token 字典已写入 Worker 文件的 ALLOWED_TOKENS。\n'
        printf '部署命令: npx wrangler deploy %q --name %q\n' "${WORKER_FILE}" "${WORKER_NAME:-${DEFAULT_WORKER_NAME}}"
    fi
    printf '\n'
}

renew_certificate() {
    require_root
    collect_installed_state
    [[ "${PROTOCOL}" != "reality" ]] || die "Reality 不使用 TLS 证书"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 尚未安装"
    local cert_domain
    [[ "${PROTOCOL}" == "anytls" ]] \
        && cert_domain=${ANYTLS_DOMAIN} \
        || cert_domain=${VLESS_WSS_DOMAIN}
    "${ACME_BIN}" --renew -d "${cert_domain}" --ecc --force \
        || die "证书续期失败"
    "${CERT_RELOAD_HOOK}" || true
    success "证书已续期并重载当前 TLS 服务"
}

show_status() {
    require_root
    collect_installed_state
    printf '协议: %s\n' "${PROTOCOL}"
    case "${PROTOCOL}" in
    reality)
        printf '节点: %s\nReality 目标: %s\n' "${NODE_HOST}" "${REALITY_TARGET}"
        ;;
    anytls)
        printf '域名: %s\n' "${ANYTLS_DOMAIN}"
        ;;
    vless-wss)
        printf '域名: %s\nWS Path: %s\n' "${VLESS_WSS_DOMAIN}" "${WS_PATH}"
        ;;
    esac
    printf '核心服务: '
    if [[ "${PROTOCOL}" == "anytls" ]]; then
        systemctl is-active --quiet "${SING_BOX_SERVICE}" 2>/dev/null \
            && printf 'active\n' || printf 'inactive\n'
    else
        systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
            && printf 'active\n' || printf 'inactive\n'
    fi
    if [[ "${PROTOCOL}" == "vless-wss" ]]; then
        printf 'Nginx: '
        systemctl is-active --quiet nginx 2>/dev/null && printf 'active\n' || printf 'inactive\n'
    fi
    printf 'TCP 443: '
    ss -H -ltn "sport = :443" 2>/dev/null | grep -q . && printf 'listening\n' || printf 'not listening\n'
    printf 'Worker: %s\n' "${WORKER_URL:-未自动部署}"
}

register_easy_all_command() {
    local destination="${COMMAND_INSTALL_DIR}/easy_all.sh"
    require_root
    [[ -f "${SCRIPT_FILE}" ]] || die "未找到脚本：${SCRIPT_FILE}"
    install -d -m 0755 "${COMMAND_INSTALL_DIR}" "$(dirname "${COMMAND_PATH}")"
    if [[ "${SCRIPT_FILE}" == "${destination}" ]]; then
        chmod 0755 "${destination}"
    elif [[ ! -f "${destination}" ]] || ! cmp -s "${SCRIPT_FILE}" "${destination}"; then
        install -m 0755 "${SCRIPT_FILE}" "${destination}"
    fi
    rm -f -- "${COMMAND_INSTALL_DIR}/sample-worker.js"
    ln -sfn "${destination}" "${COMMAND_PATH}"
    success "已注册命令：${COMMAND_PATH}"
}

stop_protocol_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true
    if [[ "${PROTOCOL:-}" == "vless-wss" || -f "${NGINX_CONFIG}" ]]; then
        systemctl disable --now nginx >/dev/null 2>&1 || true
    fi
}

remove_managed_acme_domain() {
    local domain=${1:-}
    [[ -n "${domain}" && -x "${ACME_BIN}" ]] || return 0
    "${ACME_BIN}" --remove -d "${domain}" --ecc >/dev/null 2>&1 || true
    rm -rf -- "${ACME_HOME:?}/${domain}" "${ACME_HOME:?}/${domain}_ecc"
}

purge_owned_acme_if_unused() {
    local certificate_rows
    [[ -f "${ACME_OWNERSHIP_MARKER}" && -x "${ACME_BIN}" ]] || return 0
    if ! certificate_rows=$("${ACME_BIN}" --list 2>/dev/null | tail -n +2 | awk 'NF {count++} END {print count+0}'); then
        warn "无法确认 acme.sh 是否仍有其他证书，保留 ${ACME_HOME}"
        return 0
    fi
    if ((certificate_rows > 0)); then
        warn "acme.sh 中仍有其他证书，保留共享目录 ${ACME_HOME}"
        return 0
    fi
    if command -v crontab >/dev/null 2>&1; then
        { crontab -l 2>/dev/null || true; } \
            | awk -v acme="${ACME_BIN}" 'index($0, acme) == 0' | crontab - \
            || warn "清理 acme.sh cron 失败，请手动检查 root crontab"
    fi
    rm -rf -- "${ACME_HOME}"
}

restore_preinstall_nftables() {
    local expected="" actual=""
    [[ -f "${STATE_DIR}/nftables.sha256" ]] && expected=$(<"${STATE_DIR}/nftables.sha256")
    [[ -f "${NFT_CONFIG}" ]] && actual=$(sha256sum "${NFT_CONFIG}" | awk '{print $1}')
    if [[ -n "${expected}" && "${actual}" != "${expected}" ]]; then
        warn "nftables 已被用户修改，不自动覆盖；当前配置保持不变"
        return 0
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-nftables.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-nftables.conf" "${NFT_CONFIG}"
        nft -f "${NFT_CONFIG}" >/dev/null 2>&1 || warn "恢复安装前 nftables 失败"
    elif [[ -f "${BACKUP_DIR}/pre-install-nftables.missing" ]]; then
        rm -f -- "${NFT_CONFIG}"
        nft flush ruleset >/dev/null 2>&1 || true
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
    if [[ "${FORCE:-0}" != "1" && -t 0 ]]; then
        local answer
        read -r -p "确认彻底删除 easy_all 本机服务、状态、证书和备份？[y/N]: " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_protocol_services
    restore_preinstall_nftables
    remove_daily_reboot_schedule
    remove_managed_acme_domain "${ANYTLS_DOMAIN:-}"
    if [[ "${VLESS_WSS_DOMAIN:-}" != "${ANYTLS_DOMAIN:-}" ]]; then
        remove_managed_acme_domain "${VLESS_WSS_DOMAIN:-}"
    fi
    purge_owned_acme_if_unused
    rm -f -- "${XRAY_SERVICE_FILE}" "${SING_BOX_SERVICE_FILE}" \
        "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    success "easy_all 已彻底卸载；远端 Cloudflare Worker 未处理"
}

rollback_fresh_install() {
    warn "首次安装失败，正在恢复本机服务、nftables、crontab 与 BBR 配置"
    stop_protocol_services
    if [[ "${INSTALL_NGINX_WAS_ACTIVE:-0}" == "1" ]]; then
        systemctl enable --now nginx >/dev/null 2>&1 || true
    else
        systemctl disable --now nginx >/dev/null 2>&1 || true
    fi
    restore_preinstall_nftables
    if [[ -f "${BACKUP_DIR}/pre-install-bbr.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr.conf" "${SYSCTL_CONFIG}"
        sysctl -p "${SYSCTL_CONFIG}" >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr.missing" ]]; then
        rm -f -- "${SYSCTL_CONFIG}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-crontab" ]]; then
        crontab "${BACKUP_DIR}/pre-install-crontab" >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-crontab.missing" ]]; then
        crontab -r >/dev/null 2>&1 || true
    fi
    remove_managed_acme_domain "${ANYTLS_DOMAIN:-}"
    if [[ "${VLESS_WSS_DOMAIN:-}" != "${ANYTLS_DOMAIN:-}" ]]; then
        remove_managed_acme_domain "${VLESS_WSS_DOMAIN:-}"
    fi
    purge_owned_acme_if_unused
    rm -f -- "${XRAY_SERVICE_FILE}" "${SING_BOX_SERVICE_FILE}" \
        "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    warn "首次安装产生的服务数据已清理；系统软件包和已安装内核不会降级"
}

protocol_preflight() {
    [[ "${PROTOCOL}" != "reality" ]] || return 0
    local domain public_ip
    [[ "${PROTOCOL}" == "anytls" ]] \
        && domain=${ANYTLS_DOMAIN} \
        || domain=${VLESS_WSS_DOMAIN}
    if [[ "${PROTOCOL}" == "anytls" ]]; then
        alert "${domain} 的 Cloudflare A 记录必须始终保持 DNS only / 灰云。"
        alert "如果配置了 AAAA 记录，也必须保持 DNS only / 灰云并指向当前 VPS 公网 IPv6。"
    else
        alert "安装或切换前，${domain} 的 Cloudflare A 记录必须为 DNS only / 灰云。"
        alert "如果配置了 AAAA 记录，安装或切换前也请保持 DNS only / 灰云并指向当前 VPS 公网 IPv6。"
    fi
    public_ip=$(detect_public_ipv4) || die "无法探测本机公网 IPv4"
    verify_domain_dns "${domain}" "${public_ip}"
}

prepare_protocol_assets() {
    case "${PROTOCOL}" in
    reality) download_xray ;;
    anytls) issue_certificate; download_sing_box ;;
    vless-wss) issue_certificate; download_xray ;;
    esac
}

install_protocol_runtime() {
    case "${PROTOCOL}" in
    reality)
        write_xray_config
        install_xray_service
        ;;
    anytls)
        write_sing_box_config
        install_sing_box_service
        ;;
    vless-wss)
        write_xray_config
        install_xray_service
        write_nginx_config
        ;;
    esac
}

validate_protocol_runtime() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if ss -H -ltn "sport = :443" 2>/dev/null | grep -q .; then
            case "${PROTOCOL}" in
            anytls)
                systemctl is-active --quiet "${SING_BOX_SERVICE}" && return 0
                ;;
            vless-wss)
                systemctl is-active --quiet "${XRAY_SERVICE}" \
                    && systemctl is-active --quiet nginx && return 0
                ;;
            reality)
                systemctl is-active --quiet "${XRAY_SERVICE}" && return 0
                ;;
            esac
        fi
        sleep 2
    done
    die "${PROTOCOL} 服务启动验收失败"
}

cleanup_obsolete_protocol_artifacts() {
    case "${PROTOCOL}" in
    anytls)
        systemctl disable --now nginx >/dev/null 2>&1 || true
        rm -rf -- "${XRAY_DIR}" "${WEB_ROOT}"
        rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}"
        ;;
    reality)
        systemctl disable --now nginx >/dev/null 2>&1 || true
        rm -rf -- "${SING_BOX_DIR}" "${CERT_DIR}" "${WEB_ROOT}"
        rm -f -- "${SING_BOX_SERVICE_FILE}" "${NGINX_CONFIG}"
        ;;
    vless-wss)
        rm -rf -- "${SING_BOX_DIR}"
        rm -f -- "${SING_BOX_SERVICE_FILE}"
        ;;
    esac
    systemctl daemon-reload >/dev/null 2>&1 || true
}

install_all() {
    local requested=${1:-}
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；切换协议请使用 easy_all switch <协议>"
    info "[1/9] 检查系统并选择协议"
    check_platform
    choose_protocol "${requested}"
    check_install_conflicts
    if [[ "${PROTOCOL}" != "reality" ]]; then
        print_dns_proxy_preinstall_notice
        interactive_pause
    fi
    info "[2/9] 安装依赖并初始化服务器"
    snapshot_fresh_install
    install_packages
    initialize_server
    info "[3/9] 收集 ${PROTOCOL} 参数"
    collect_install_inputs
    protocol_preflight
    info "[4/9] 准备核心与证书"
    prepare_protocol_assets
    info "[5/9] 配置 nftables"
    configure_nftables
    info "[6/9] 安装并启动 ${PROTOCOL}"
    install_protocol_runtime
    validate_protocol_runtime
    cleanup_obsolete_protocol_artifacts
    info "[7/9] 保存状态"
    save_state
    info "[8/9] 注册 easy_all 命令"
    register_easy_all_command
    info "[9/9] 配置 Worker 订阅"
    configure_subscription
    INSTALL_ROLLBACK_ON_EXIT=0
    show_subscription
    [[ "${PROTOCOL}" != "vless-wss" ]] || print_dns_proxy_postinstall_notice
    success "easy_all ${PROTOCOL} 安装完成"
}

snapshot_path() {
    local source=$1 name=$2
    if [[ -e "${source}" || -L "${source}" ]]; then
        cp -a "${source}" "${SWITCH_BACKUP_DIR}/${name}"
    else
        : >"${SWITCH_BACKUP_DIR}/${name}.missing"
    fi
}

restore_snapshot_path() {
    local destination=$1 name=$2
    rm -rf -- "${destination}"
    if [[ -e "${SWITCH_BACKUP_DIR}/${name}" || -L "${SWITCH_BACKUP_DIR}/${name}" ]]; then
        cp -a "${SWITCH_BACKUP_DIR}/${name}" "${destination}"
    fi
}

snapshot_protocol_switch() {
    SWITCH_BACKUP_DIR="${RUNTIME_TMP}/switch-backup"
    install -d -m 0700 "${SWITCH_BACKUP_DIR}"
    snapshot_path "${STATE_DIR}" state
    snapshot_path "${WEB_ROOT}" web-root
    snapshot_path "${NFT_CONFIG}" nftables.conf
    snapshot_path "${XRAY_SERVICE_FILE}" xray.service
    snapshot_path "${SING_BOX_SERVICE_FILE}" sing-box.service
    snapshot_path "${NGINX_CONFIG}" nginx.conf
    SWITCH_ROLLBACK_ON_EXIT=1
}

rollback_protocol_switch() {
    local failed_tls_domain="" restored_tls_domain=""
    if [[ "${WORKER_REPLACED:-0}" == "1" ]]; then
        warn "Worker 已完成 replace；为保持远端订阅与本机一致，不再回滚已验收的新协议"
        return 0
    fi
    case "${PROTOCOL:-}" in
    anytls) failed_tls_domain=${ANYTLS_DOMAIN:-} ;;
    vless-wss) failed_tls_domain=${VLESS_WSS_DOMAIN:-} ;;
    esac
    warn "协议切换失败，正在恢复原协议"
    stop_protocol_services
    restore_snapshot_path "${STATE_DIR}" state
    restore_snapshot_path "${WEB_ROOT}" web-root
    restore_snapshot_path "${NFT_CONFIG}" nftables.conf
    restore_snapshot_path "${XRAY_SERVICE_FILE}" xray.service
    restore_snapshot_path "${SING_BOX_SERVICE_FILE}" sing-box.service
    restore_snapshot_path "${NGINX_CONFIG}" nginx.conf
    systemctl daemon-reload >/dev/null 2>&1 || true
    [[ -f "${NFT_CONFIG}" ]] && nft -f "${NFT_CONFIG}" >/dev/null 2>&1 || true
    source_state_file
    case "${PROTOCOL:-}" in
    anytls) restored_tls_domain=${ANYTLS_DOMAIN:-} ;;
    vless-wss) restored_tls_domain=${VLESS_WSS_DOMAIN:-} ;;
    esac
    if [[ -n "${failed_tls_domain}" && "${failed_tls_domain}" != "${restored_tls_domain}" ]]; then
        remove_managed_acme_domain "${failed_tls_domain}"
    fi
    case "${PROTOCOL:-}" in
    anytls) systemctl enable --now "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true ;;
    reality) systemctl enable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true ;;
    vless-wss)
        systemctl enable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
        systemctl enable --now nginx >/dev/null 2>&1 || true
        ;;
    esac
    warn "原协议恢复完成；Worker 上传未成功，远端 Worker 保持原状"
}

reset_protocol_fields() {
    NODE_NAME=""
    NODE_HOST=""
    REALITY_TARGET=""
    REALITY_PRIVATE_KEY=""
    REALITY_PUBLIC_KEY=""
    REALITY_SHORT_ID=""
    VLESS_WSS_DOMAIN=""
    WS_PATH=""
    ANYTLS_DOMAIN=""
    ANYTLS_PASSWORD=""
    SUB_PORT_MODE=""
}

switch_protocol() {
    local requested=${1:-${PROTOCOL:-}}
    local old_protocol old_anytls_domain old_wss_domain new_tls_domain=""
    local requested_node_name=${NODE_NAME:-} requested_node_host=${NODE_HOST:-}
    local requested_target=${REALITY_TARGET:-} requested_anytls_domain=${ANYTLS_DOMAIN:-}
    local requested_anytls_password=${ANYTLS_PASSWORD:-} requested_wss_domain=${VLESS_WSS_DOMAIN:-}
    local requested_ws_path=${WS_PATH:-} requested_port_mode=${SUB_PORT_MODE:-}
    require_root
    require_systemd
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    source_state_file
    validate_protocol "${PROTOCOL:-}" || die "状态文件中的 PROTOCOL 无效"
    old_protocol=${PROTOCOL}
    old_anytls_domain=${ANYTLS_DOMAIN:-}
    old_wss_domain=${VLESS_WSS_DOMAIN:-}
    reset_protocol_fields
    NODE_NAME=${requested_node_name}
    NODE_HOST=${requested_node_host}
    REALITY_TARGET=${requested_target}
    ANYTLS_DOMAIN=${requested_anytls_domain}
    ANYTLS_PASSWORD=${requested_anytls_password}
    VLESS_WSS_DOMAIN=${requested_wss_domain}
    WS_PATH=${requested_ws_path}
    SUB_PORT_MODE=${requested_port_mode}
    PROTOCOL=""
    choose_protocol "${requested}"
    [[ "${PROTOCOL}" != "${old_protocol}" ]] || die "当前已经是 ${PROTOCOL}"
    collect_install_inputs
    protocol_preflight
    WORKER_REPLACED=0
    snapshot_protocol_switch
    SWITCH_IN_PROGRESS=1
    info "准备从 ${old_protocol} 切换到 ${PROTOCOL}"
    stop_protocol_services
    rm -f -- "${XRAY_SERVICE_FILE}" "${SING_BOX_SERVICE_FILE}" "${NGINX_CONFIG}"
    systemctl daemon-reload
    prepare_protocol_assets
    configure_nftables
    install_protocol_runtime
    validate_protocol_runtime
    cleanup_obsolete_protocol_artifacts
    save_state
    STRICT_WORKER_DEPLOY=1
    configure_subscription
    STRICT_WORKER_DEPLOY=0
    save_state
    SWITCH_ROLLBACK_ON_EXIT=0
    case "${PROTOCOL}" in
    anytls) new_tls_domain=${ANYTLS_DOMAIN} ;;
    vless-wss) new_tls_domain=${VLESS_WSS_DOMAIN} ;;
    esac
    if [[ "${old_protocol}" == "anytls" && "${old_anytls_domain}" != "${new_tls_domain}" ]]; then
        remove_managed_acme_domain "${old_anytls_domain}"
    elif [[ "${old_protocol}" == "vless-wss" && "${old_wss_domain}" != "${new_tls_domain}" ]]; then
        remove_managed_acme_domain "${old_wss_domain}"
    fi
    register_easy_all_command
    [[ "${PROTOCOL}" != "vless-wss" ]] || print_dns_proxy_postinstall_notice
    success "协议已从 ${old_protocol} 切换为 ${PROTOCOL}"
}

usage() {
    cat <<EOF
用法: $0 [命令]

  install [reality|anytls|vless-wss]
                选择并安装一种协议（默认 Reality）
  switch <协议> 在 easy_all 创建的安装中切换协议，失败自动回滚
  show          显示当前协议节点和 Mihomo 节点
  subscription  显示链接、订阅和 Worker 信息
  update        注册当前脚本并更新 Worker 订阅
  update-sub    重新配置 Worker 订阅输出
  update-core   更新当前协议核心
  renew-cert    立即续期 AnyTLS/WSS 证书
  status        显示当前协议、服务、端口和 Worker 状态
  register-command
                注册系统命令 easy_all
  uninstall     默认彻底删除所有 easy_all 本机数据；不处理远端 Worker
  help          显示帮助

主要无人值守变量:
  PROTOCOL=reality|anytls|vless-wss
  NODE_NAME=...
  NODE_HOST=...              Reality 节点地址
  REALITY_TARGET=swdist.apple.com:443
  ANYTLS_DOMAIN=node.example.com  ANYTLS_PASSWORD=...
  VLESS_WSS_DOMAIN=node.example.com  WS_PATH=/随机路径
  SUB_PORT_MODE=443|dynamic
  ALLOWED_TOKENS='{"owner":"token1","alice":"token2"}'
  CF_DNS_API_TOKEN=...
  SUBSCRIBE_MODE=auto|worker|link
  CF_WORKER_API_TOKEN=...    CF_ACCOUNT_ID=...
  WORKER_NAME=easy-all       SUB_DOWNLOAD_NAME=MY_SUB
  SAMPLE_WORKER_URL=https://...  默认读取本仓库 main/sample-worker.js

Reality 默认 443；AnyTLS 默认 dynamic；VLESS WSS 固定 443，且仅推荐移动宽带用户选择。
远端 Worker 始终 replace，uninstall 不删除远端 Worker。
EOF
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/core-backup" backup_version="${RUNTIME_TMP}/version-backup"
    require_root
    collect_installed_state
    if [[ "${PROTOCOL}" == "anytls" ]]; then
        install -m 0755 "${SING_BOX_BIN}" "${backup_bin}"
        [[ ! -f "${SING_BOX_DIR}/version" ]] \
            || install -m 0644 "${SING_BOX_DIR}/version" "${backup_version}"
    else
        install -m 0755 "${XRAY_BIN}" "${backup_bin}"
        [[ ! -f "${XRAY_DIR}/version" ]] \
            || install -m 0644 "${XRAY_DIR}/version" "${backup_version}"
    fi
    if (
        if [[ "${PROTOCOL}" == "anytls" ]]; then
            download_sing_box
            systemctl restart "${SING_BOX_SERVICE}"
        else
            download_xray
            systemctl restart "${XRAY_SERVICE}"
        fi
        validate_protocol_runtime
    ); then
        success "${PROTOCOL} 核心已更新"
        return 0
    fi
    warn "新核心验收失败，正在恢复旧版本"
    if [[ "${PROTOCOL}" == "anytls" ]]; then
        install -m 0755 "${backup_bin}" "${SING_BOX_BIN}"
        [[ ! -f "${backup_version}" ]] \
            || install -m 0644 "${backup_version}" "${SING_BOX_DIR}/version"
        systemctl restart "${SING_BOX_SERVICE}"
    else
        install -m 0755 "${backup_bin}" "${XRAY_BIN}"
        [[ ! -f "${backup_version}" ]] \
            || install -m 0644 "${backup_version}" "${XRAY_DIR}/version"
        systemctl restart "${XRAY_SERVICE}"
    fi
    validate_protocol_runtime
    die "核心更新失败，已恢复旧版本"
}

main() {
    case "${1:-install}" in
    install) install_all "${2:-${PROTOCOL:-}}" ;;
    switch)
        [[ -n "${2:-}" ]] || die "switch 必须指定 reality、anytls 或 vless-wss"
        switch_protocol "${2}"
        ;;
    show) require_root; show_node ;;
    subscription) require_root; show_subscription ;;
    update) update_easy_all ;;
    update-sub) update_subscription ;;
    update-core) update_current_core ;;
    renew-cert) renew_certificate ;;
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
