#!/usr/bin/env bash

# CDN XHTTP profile. Currently backed by AWS CloudFront.

set -Eeuo pipefail
umask 077

readonly EASY_ALL_PROFILE="xhttp"
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
readonly ENTRY_COMMAND_NAME="easy_all"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-tls-service.sh"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly ACME_HOME="/root/.acme-aws.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-easy_all-bbr.conf"
readonly BBR_MODULES_CONFIG="/etc/modules-load.d/easy_all-bbr.conf"
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
readonly STATE_SCHEMA_VERSION="2"
readonly AWS_CONTROL_REGION="us-east-1"
readonly CLOUDFRONT_CACHE_POLICY_ID="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
readonly CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID="b689b0a8-53d0-40ab-baf2-68738e2966ac"
readonly CLOUDFRONT_ORIGIN_ID="easy_all-xhttp-origin"
readonly CLOUDFRONT_CONNECTION_ATTEMPTS="2"
readonly CLOUDFRONT_CONNECTION_TIMEOUT="3"
readonly CLOUDFRONT_ORIGIN_READ_TIMEOUT="60"
readonly CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT="60"
readonly XHTTP_STREAM_UP_SERVER_SECS="20-40"
readonly XHTTP_XMUX_MAX_CONCURRENCY="8-16"
readonly XHTTP_XMUX_C_MAX_REUSE_TIMES="0"
readonly XHTTP_XMUX_H_MAX_REQUEST_TIMES="600-900"
readonly XHTTP_XMUX_H_MAX_REUSABLE_SECS="1800-3000"
readonly XHTTP_XMUX_H_KEEP_ALIVE_PERIOD="0"

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
    [[ "${domain}" == *.* && "${domain}" != \*.* ]] || return 1
    [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "${domain}" != .* && "${domain}" != *. && "${domain}" != *..* ]] || return 1
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

validate_xhttp_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
}

validate_loopback_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
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

generate_secret() {
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

generate_xhttp_path() {
    printf '/vless-%s' "$(openssl rand -hex 12)"
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
    [[ -t 0 ]] || return 1
    read -r -s -p "${label}: " value
    printf '\n' >&2
    printf '%s' "${value}"
}

normalize_allowed_tokens() {
    local raw=$1
    jq -cer '
        def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
        if type != "object" or length == 0 then
            error("ALLOWED_TOKENS 必须是非空 JSON object")
        else
            [to_entries[] | {key:(.key|trim), value:(.value|tostring|trim)}] as $clean
            | if any($clean[]; (.key|test("^[A-Za-z0-9._-]{1,64}$")|not)) then
                error("用户名格式无效")
              elif any($clean[]; (.value|test("^[A-Za-z0-9._~-]{8,128}$")|not)) then
                error("token 格式无效")
              elif (($clean|map(.value)|unique|length) != ($clean|length)) then
                error("token 不允许重复")
              else $clean|from_entries end
        end
    ' <<<"${raw}"
}

ensure_allowed_tokens() {
    local raw normalized default
    if [[ -n "${ALLOWED_TOKENS:-}" ]]; then
        raw=${ALLOWED_TOKENS}
    elif [[ -t 0 ]]; then
        default=$(jq -cn --arg token "$(generate_secret)" '{owner:$token}')
        raw=$(prompt_value "订阅用户 Token 字典 JSON（用户名=>token）" "${default}")
    else
        die "非交互模式必须设置 ALLOWED_TOKENS，例如 ALLOWED_TOKENS='{\"owner\":\"$(generate_secret)\"}'"
    fi
    normalized=$(normalize_allowed_tokens "${raw}") || die "ALLOWED_TOKENS 无效"
    ALLOWED_TOKENS=${normalized}
}

choose_subscription_mode() {
    local mode=${SUBSCRIBE_MODE:-${SUBSCRIPTION_MODE:-}} current_mode default_choice=1
    if [[ "${PROMPT_SUBSCRIPTION_MODE:-0}" == "1" || -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            current_mode=${mode:-deploy}
            [[ "${current_mode}" == "link" ]] && default_choice=2
            printf '请选择是否部署订阅服务：\n'
            printf '  1. 部署订阅服务（CloudFront + Nginx）\n'
            printf '  2. 不部署，仅输出节点信息\n'
            read -r -p "请选择 [${default_choice}]: " mode
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

collect_install_inputs() {
    PROTOCOL="xhttp"
    CDN_PROVIDER="aws"
    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"

    AWS_ORIGIN_DOMAIN=${AWS_ORIGIN_DOMAIN:-$(prompt_value "AWS Route 53 源站域名（脚本创建 A 记录）" "")}
    AWS_ORIGIN_DOMAIN=$(normalize_domain "${AWS_ORIGIN_DOMAIN}")
    validate_domain "${AWS_ORIGIN_DOMAIN}" || die "AWS_ORIGIN_DOMAIN 无效：${AWS_ORIGIN_DOMAIN}"

    VLESS_CDN_DOMAIN=${VLESS_CDN_DOMAIN:-$(prompt_value "AWS CloudFront CDN 域名" "")}
    VLESS_CDN_DOMAIN=$(normalize_domain "${VLESS_CDN_DOMAIN}")
    validate_domain "${VLESS_CDN_DOMAIN}" || die "VLESS_CDN_DOMAIN 无效：${VLESS_CDN_DOMAIN}"
    [[ "${AWS_ORIGIN_DOMAIN}" != "${VLESS_CDN_DOMAIN}" ]] || die "源站域名与 CDN 域名不能相同"

    XHTTP_PATH=${XHTTP_PATH:-$(generate_xhttp_path)}
    XHTTP_PATH="/xhttp-${XHTTP_PATH#/vless-}"
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效：${XHTTP_PATH}"
    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        || die "XRAY_XHTTP_LOOPBACK_PORT 无效：${XRAY_XHTTP_LOOPBACK_PORT}"
    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "ORIGIN_HEADER_SECRET 格式无效"
    choose_subscription_mode
    if subscription_enabled; then
        choose_subscription_download_name
        ensure_allowed_tokens
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
    fi
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all XHTTP 状态文件不存在：${STATE_FILE}"
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "1" || "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}"
}

load_state() {
    local variable env_name
    local -a variables=(
        PROTOCOL CDN_PROVIDER XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN
        XHTTP_PATH AWS_ORIGIN_DOMAIN
        XRAY_XHTTP_LOOPBACK_PORT ORIGIN_HEADER_SECRET
        AWS_ORIGIN_ROUTE53_ZONE_ID AWS_ROUTE53_ZONE_ID AWS_ACM_CERTIFICATE_ARN
        AWS_CLOUDFRONT_DISTRIBUTION_ID AWS_CLOUDFRONT_DOMAIN
        ALLOWED_TOKENS SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        printf -v "${env_name}" '%s' "${!variable:-}"
        printf -v "${variable}" '%s' ""
    done
    source_state_file
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        if [[ -n "${!env_name:-}" ]]; then
            printf -v "${variable}" '%s' "${!env_name}"
        fi
        unset "${env_name}"
    done
    [[ "${PROTOCOL}" == "xhttp" ]] || die "状态协议不是 xhttp；请重新安装"
    CDN_PROVIDER=${CDN_PROVIDER:-aws}
    [[ "${CDN_PROVIDER}" == "aws" ]] \
        || die "当前版本不支持 CDN Provider：${CDN_PROVIDER}"
    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    [[ -n "${XHTTP_PATH:-}" ]] || die "状态中缺少 XHTTP_PATH；请卸载后重新安装"
    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    SUBSCRIPTION_MODE=${SUBSCRIPTION_MODE:-$([[ -n "${ALLOWED_TOKENS:-}" ]] && printf deploy || printf link)}
    [[ "${SUBSCRIPTION_MODE}" == "deploy" || "${SUBSCRIPTION_MODE}" == "link" ]] \
        || die "状态文件中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}"
    [[ -z "${ALLOWED_TOKENS:-}" ]] \
        || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
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
        printf 'CDN_PROVIDER=%q\n' "${CDN_PROVIDER:-aws}"
        printf 'XHTTP_NODE_NAME=%q\n' "${XHTTP_NODE_NAME}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID}"
        printf 'VLESS_CDN_DOMAIN=%q\n' "${VLESS_CDN_DOMAIN}"
        printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH}"
        printf 'AWS_ORIGIN_DOMAIN=%q\n' "${AWS_ORIGIN_DOMAIN}"
        printf 'XRAY_XHTTP_LOOPBACK_PORT=%q\n' "${XRAY_XHTTP_LOOPBACK_PORT}"
        printf 'ORIGIN_HEADER_SECRET=%q\n' "${ORIGIN_HEADER_SECRET}"
        printf 'AWS_ORIGIN_ROUTE53_ZONE_ID=%q\n' "${AWS_ORIGIN_ROUTE53_ZONE_ID:-}"
        printf 'AWS_ROUTE53_ZONE_ID=%q\n' "${AWS_ROUTE53_ZONE_ID:-}"
        printf 'AWS_ACM_CERTIFICATE_ARN=%q\n' "${AWS_ACM_CERTIFICATE_ARN:-}"
        printf 'AWS_CLOUDFRONT_DISTRIBUTION_ID=%q\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}"
        printf 'AWS_CLOUDFRONT_DOMAIN=%q\n' "${AWS_CLOUDFRONT_DOMAIN:-}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME}"
        printf 'SUBSCRIPTION_MODE=%q\n' "${SUBSCRIPTION_MODE:-deploy}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all XHTTP 尚未安装"
    load_state
    validate_domain "${AWS_ORIGIN_DOMAIN}" || die "状态中的源站域名无效"
    validate_domain "${VLESS_CDN_DOMAIN}" || die "状态中的 CDN 域名无效"
    validate_uuid "${VLESS_UUID}" || die "状态中的 VLESS UUID 无效"
    validate_xhttp_path "${XHTTP_PATH}" || die "状态中的 XHTTP 路径无效"
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        || die "状态中的 XHTTP 本机端口无效"
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "状态中的源站保护密钥无效"
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
        socat cron iproute2 iputils-ping tzdata systemd-timesyncd tar
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || die "无法启用网络时间同步"
}

install_aws_cli() {
    command -v aws >/dev/null 2>&1 && return 0
    local temp_dir archive
    temp_dir=$(make_temp_dir)
    archive="${temp_dir}/awscliv2.zip"
    curl -fsSL --retry 3 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${archive}" \
        || die "下载 AWS CLI v2 失败"
    unzip -q "${archive}" -d "${temp_dir}"
    "${temp_dir}/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
        || die "安装 AWS CLI v2 失败"
    command -v aws >/dev/null 2>&1 || die "AWS CLI v2 安装后不可用"
}

configure_bbr_tcp() {
    [[ "$(uname -r)" != *xanmod* ]] \
        || die "当前仍在运行 XanMod 内核；请先切换到 Debian 官方内核并重启"
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
        printf '请选择定时重启策略：\n  1. 每天凌晨 4 点重启（默认）\n  2. 自定义小时\n  3. 不配置\n'
        read -r -p "请选择 [1]: " mode
    fi
    mode=${mode:-1}
    case "${mode}" in
    1 | default) SCHEDULED_REBOOT_ENABLED=1; SCHEDULED_REBOOT_HOUR=${DEFAULT_REBOOT_HOUR} ;;
    2 | custom)
        [[ -n "${hour}" ]] || hour=$(prompt_value "每天重启小时（0-23）" "")
        [[ "${hour}" =~ ^[0-9]+$ ]] && ((10#${hour} <= 23)) || die "重启小时无效"
        SCHEDULED_REBOOT_ENABLED=1; SCHEDULED_REBOOT_HOUR=${hour}
        ;;
    3 | none | off) SCHEDULED_REBOOT_ENABLED=0; SCHEDULED_REBOOT_HOUR="" ;;
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
        || warn "移除 easy_all 定时重启任务失败"
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

append_ssh_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    ((10#${port} >= 1 && 10#${port} <= 65535)) || return 0
    case " ${SSH_PORTS:-} " in
    *" ${port} "*) ;;
    *) [[ -z "${SSH_PORTS:-}" ]] || SSH_PORTS+=" "; SSH_PORTS+="${port}" ;;
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
        while read -r current_port; do append_ssh_port "${current_port}"; done \
            < <("${sshd_bin}" -T 2>/dev/null | awk '$1 == "port" {print $2}')
    fi
    for config in /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf; do
        [[ -f "${config}" ]] || continue
        while read -r current_port; do append_ssh_port "${current_port}"; done \
            < <(awk 'tolower($1)=="port" && $1 !~ /^#/ {print $2}' "${config}")
    done
    [[ -n "${SSH_PORTS}" ]] || SSH_PORTS=22
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

configure_ufw() {
    local port rule_number old_rule_numbers
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ufw
    fi
    detect_ssh_ports
    old_rule_numbers=$(managed_ufw_rule_numbers)
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    for port in ${SSH_PORTS}; do
        ufw allow "${port}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加 SSH UFW 规则失败：TCP ${port}"
    done
    ufw allow 80/tcp comment "${UFW_RULE_COMMENT}" >/dev/null \
        || die "添加 HTTP UFW 规则失败"
    ufw allow 443/tcp comment "${UFW_RULE_COMMENT}" >/dev/null \
        || die "添加 HTTPS UFW 规则失败"
    while read -r rule_number; do
        [[ -n "${rule_number}" ]] || continue
        ufw --force delete "${rule_number}" >/dev/null \
            || die "删除旧 UFW 规则失败：${rule_number}"
    done <<<"${old_rule_numbers}"

    ufw --force enable >/dev/null || die "启用 UFW 失败"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
}

detect_public_ipv4() {
    local service ip
    for service in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.co; do
        ip=$(curl -4fsS --max-time 10 "${service}" 2>/dev/null | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then printf '%s\n' "${ip}"; return 0; fi
    done
    return 1
}

verify_origin_dns() {
    local public_ip records resolver attempt resolver_ok all_ok last_records=""
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    info "等待 Route 53 源站 A 记录传播到公共 DNS"
    for attempt in {1..60}; do
        all_ok=1
        for resolver in 1.1.1.1 8.8.8.8; do
            records=$(dig +short A "${AWS_ORIGIN_DOMAIN}" @"${resolver}" 2>/dev/null \
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
            [[ "${resolver_ok}" == 1 ]] || all_ok=0
        done
        [[ "${all_ok}" == 1 ]] && return 0
        sleep 5
    done
    die "源站域名 ${AWS_ORIGIN_DOMAIN} 尚未只解析到当前 VPS ${public_ip}（最近结果：${last_records}）"
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

verify_acme_renewal_setup() {
    local crontab_content
    command -v crontab >/dev/null 2>&1 || die "未找到 crontab；无法配置证书自动续期"
    systemctl enable --now cron.service >/dev/null 2>&1 \
        || die "无法启用证书自动续期所需的 cron.service"
    systemctl is-enabled --quiet cron.service \
        || die "cron.service 未设置为开机启动"
    systemctl is-active --quiet cron.service \
        || die "cron.service 未运行"
    crontab_content=$(crontab -l 2>/dev/null || true)
    awk -v acme_bin="${ACME_BIN}" '
        index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/ { found=1 }
        END { exit !found }
    ' <<<"${crontab_content}" || die "未找到 acme.sh 自动续期定时任务"
}

install_acme() {
    if [[ -x "${ACME_BIN}" ]]; then
        verify_acme_renewal_setup
        return 0
    fi
    local installer="${RUNTIME_TMP}/get-acme.sh"
    local account_email=${ACME_EMAIL:-admin@${AWS_ORIGIN_DOMAIN}}
    curl -fsSL --retry 3 https://get.acme.sh -o "${installer}" || die "下载 acme.sh 失败"
    sh "${installer}" "email=${account_email}" --home "${ACME_HOME}" || die "安装 acme.sh 失败"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装后不可用"
    install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
    verify_acme_renewal_setup
}

run_acme() {
    "${ACME_BIN}" "$@" --home "${ACME_HOME}"
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

download_xray() {
    local release archive_url dgst_url version temp_dir archive dgst expected actual
    temp_dir=$(make_temp_dir)
    release=$(curl -fsSL --retry 3 "${XRAY_RELEASES_API}") || die "读取 Xray 最新版本失败"
    version=$(jq -r '.tag_name' <<<"${release}")
    archive_url=$(jq -r --arg name "${XRAY_ARCHIVE}" '.assets[]|select(.name==$name)|.browser_download_url' <<<"${release}")
    dgst_url=$(jq -r --arg name "${XRAY_DGST}" '.assets[]|select(.name==$name)|.browser_download_url' <<<"${release}")
    [[ -n "${archive_url}" && "${archive_url}" != null ]] || die "未找到 Xray 压缩包"
    [[ -n "${dgst_url}" && "${dgst_url}" != null ]] || die "未找到 Xray 校验文件"
    archive="${temp_dir}/${XRAY_ARCHIVE}"; dgst="${temp_dir}/${XRAY_DGST}"
    curl -fL --retry 3 "${archive_url}" -o "${archive}" || die "下载 Xray 失败"
    curl -fL --retry 3 "${dgst_url}" -o "${dgst}" || die "下载 Xray 校验文件失败"
    expected=$(awk 'BEGIN{IGNORECASE=1} /SHA256|SHA2-256/{for(i=1;i<=NF;i++){gsub(/[^A-Fa-f0-9]/,"",$i);if($i~/^[A-Fa-f0-9]{64}$/){print tolower($i);exit}}}' "${dgst}")
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ -n "${expected}" && "${expected,,}" == "${actual,,}" ]] || die "Xray SHA256 校验失败"
    unzip -qo "${archive}" -d "${temp_dir}/xray"
    install -d -m 0755 "${XRAY_DIR}"
    install -m 0755 "${temp_dir}/xray/xray" "${XRAY_BIN}"
    printf '%s\n' "${version}" >"${XRAY_DIR}/version"
}

write_xray_config() {
    install -d -m 0755 "${XRAY_DIR}"
    jq -n --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --arg uuid "${VLESS_UUID}" \
        --arg xhttp_name "${XHTTP_NODE_NAME}" \
        --arg xhttp_path "${XHTTP_PATH}" --arg xhttp_host "${VLESS_CDN_DOMAIN}" \
        --arg stream_up_server_secs "${XHTTP_STREAM_UP_SERVER_SECS}" '
        {
          log:{loglevel:"warning"},
          inbounds:[{
              tag:"vless-xhttp-h2-in", listen:"127.0.0.1", port:$xhttp_port, protocol:"vless",
              settings:{clients:[{id:$uuid,email:$xhttp_name}],decryption:"none"},
              streamSettings:{
                network:"xhttp",
                xhttpSettings:{
                  host:$xhttp_host,
                  path:$xhttp_path,
                  mode:"stream-up",
                  scStreamUpServerSecs:$stream_up_server_secs
                }
              },
              sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:false}
          }],
          outbounds:[{protocol:"freedom",tag:"direct"}],
          routing:{domainStrategy:"AsIs",rules:[{type:"field",network:"tcp,udp",outboundTag:"direct"}]}
        }' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

install_xray_service() {
    cat >"${RUNTIME_TMP}/easy_all-xray.service" <<EOF
[Unit]
Description=Xray VLESS XHTTP managed by easy_all
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
    systemctl enable --now "${XRAY_SERVICE}" >/dev/null || die "启动 Xray 失败"
}

write_subscription_token_map() {
    jq -r '.[] | "    \"" + . + "\" 1;"' <<<"${ALLOWED_TOKENS}"
}

write_subscription_nginx_maps() {
    subscription_enabled || return 0
    cat <<'EOF'
map $arg_token $easy_all_subscription_allowed {
    default 0;
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
    subscription_enabled || return 0
    cat <<EOF
    location = /subscribe {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        if (\$request_method !~ ^(GET|HEAD)$) { return 405; }
        if (\$easy_all_subscription_allowed = 0) { return 403; }
        rewrite ^ \$easy_all_subscription_uri last;
    }

    location = /_easy_all_subscription/base64 {
        internal;
        alias ${SUBSCRIPTION_BASE64_FILE};
        default_type text/plain;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

    location = /_easy_all_subscription/mihomo {
        internal;
        alias ${SUBSCRIPTION_MIHOMO_FILE};
        default_type text/yaml;
        add_header Content-Disposition "attachment; filename=${SUB_DOWNLOAD_NAME}.yaml" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

EOF
}

write_nginx_config() {
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
        client_body_timeout 5m;
        grpc_set_header Host ${VLESS_CDN_DOMAIN};
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_set_header X-Easy-All-Origin-Key \$http_x_easy_all_origin_key;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
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
            [[ "${response}" == "easy_all ok" ]] && return 0
        fi
        sleep 2
    done
    die "VLESS XHTTP 本机运行时验收失败"
}

validate_subscription_runtime() {
    local token base64_response mihomo_response
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
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

collect_aws_credentials() {
    local identity arn
    export AWS_DEFAULT_REGION="${AWS_CONTROL_REGION}"
    export AWS_PAGER=""
    if [[ "${AWS_USE_DEFAULT_CREDENTIAL_CHAIN:-0}" == "1" ]]; then
        identity=$(aws sts get-caller-identity --output json) || die "AWS 默认凭证链不可用"
        arn=$(jq -r '.Arn // empty' <<<"${identity}")
        [[ "${arn}" != *":root" ]] || die "拒绝使用 AWS 根用户凭证；请改用专用 IAM 用户或 Role"
        return 0
    fi
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        AWS_ACCESS_KEY_ID=$(prompt_secret "AWS IAM Access Key ID（输入不回显）") \
            || die "非交互模式必须设置 AWS_ACCESS_KEY_ID"
    fi
    if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        AWS_SECRET_ACCESS_KEY=$(prompt_secret "AWS IAM Secret Access Key（输入不回显）") \
            || die "非交互模式必须设置 AWS_SECRET_ACCESS_KEY"
    fi
    [[ -n "${AWS_ACCESS_KEY_ID}" && -n "${AWS_SECRET_ACCESS_KEY}" ]] \
        || die "AWS 访问密钥不能为空"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
    [[ -z "${AWS_SESSION_TOKEN:-}" ]] || export AWS_SESSION_TOKEN
    identity=$(aws sts get-caller-identity --output json) || die "AWS 凭证验证失败"
    arn=$(jq -r '.Arn // empty' <<<"${identity}")
    [[ "${arn}" != *":root" ]] || die "拒绝使用 AWS 根用户访问密钥；请改用专用 IAM 用户"
}

clear_aws_credentials() {
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
}

find_route53_zone_for_domain() {
    local domain=$1 zones=$2
    jq -r --arg domain "${domain}." '
        [.HostedZones[] | select(.Config.PrivateZone == false) |
          select(.Name as $name | ($domain==$name or ($domain|endswith("." + $name))))]
        | sort_by(.Name|length) | last // empty | [.Id,.Name] | @tsv' <<<"${zones}"
}

find_route53_zones() {
    local zones origin_zone viewer_zone
    zones=$(aws route53 list-hosted-zones --output json) || die "查询 Route 53 Hosted Zone 失败"
    origin_zone=$(find_route53_zone_for_domain "${AWS_ORIGIN_DOMAIN}" "${zones}")
    viewer_zone=$(find_route53_zone_for_domain "${VLESS_CDN_DOMAIN}" "${zones}")
    [[ -n "${origin_zone}" ]] \
        || die "Route 53 中没有覆盖源站域名 ${AWS_ORIGIN_DOMAIN} 的 Public Hosted Zone"
    [[ -n "${viewer_zone}" ]] \
        || die "Route 53 中没有覆盖 CDN 域名 ${VLESS_CDN_DOMAIN} 的 Public Hosted Zone"
    IFS=$'\t' read -r AWS_ORIGIN_ROUTE53_ZONE_ID AWS_ORIGIN_ROUTE53_ZONE_NAME <<<"${origin_zone}"
    IFS=$'\t' read -r AWS_ROUTE53_ZONE_ID AWS_ROUTE53_ZONE_NAME <<<"${viewer_zone}"
    AWS_ORIGIN_ROUTE53_ZONE_ID=${AWS_ORIGIN_ROUTE53_ZONE_ID#/hostedzone/}
    AWS_ROUTE53_ZONE_ID=${AWS_ROUTE53_ZONE_ID#/hostedzone/}
    [[ "${VLESS_CDN_DOMAIN}." != "${AWS_ROUTE53_ZONE_NAME}" ]] \
        || die "easy_all CDN XHTTP 当前要求使用子域名，不能直接使用 Hosted Zone 根域"
}

build_origin_a_change_batch() {
    local destination=$1 conflicts=$2 public_ip=$3
    jq -n --arg name "${AWS_ORIGIN_DOMAIN}." --arg value "${public_ip}" \
        --argjson conflicts "${conflicts}" '
        {Comment:"easy_all Route 53 origin A",
         Changes:(if ($conflicts|length)==0 then
           [{Action:"CREATE",ResourceRecordSet:{Name:$name,Type:"A",TTL:300,
             ResourceRecords:[{Value:$value}]}}]
         else
           (($conflicts|map({Action:"DELETE",ResourceRecordSet:.})) +
             [{Action:"CREATE",ResourceRecordSet:{Name:$name,Type:"A",TTL:300,
               ResourceRecords:[{Value:$value}]}}])
         end)}' >"${destination}"
}

ensure_origin_a_record() {
    local records conflicts change public_ip
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    records=$(aws route53 list-resource-record-sets \
        --hosted-zone-id "${AWS_ORIGIN_ROUTE53_ZONE_ID}" --output json) \
        || die "查询源站 Route 53 记录失败"
    conflicts=$(jq -c --arg name "${AWS_ORIGIN_DOMAIN}." '
        [.ResourceRecordSets[] | select(.Name==$name and
          (.Type=="A" or .Type=="AAAA" or .Type=="CNAME"))]' <<<"${records}")
    if jq -e --arg value "${public_ip}" '
        length==1 and .[0].Type=="A" and (.[0].AliasTarget? == null) and
        ((.[0].ResourceRecords // [])|length)==1 and
        .[0].ResourceRecords[0].Value==$value' <<<"${conflicts}" >/dev/null; then
        info "Route 53 源站 A 记录已指向当前 VPS"
        return 0
    fi
    if [[ "$(jq 'length' <<<"${conflicts}")" -gt 0 ]]; then
        [[ "${AWS_ORIGIN_DNS_REPLACE:-0}" == "1" ]] \
            || die "${AWS_ORIGIN_DOMAIN} 已有冲突的 A/AAAA/CNAME；拒绝覆盖。确认后可设置 AWS_ORIGIN_DNS_REPLACE=1"
    fi
    change="${RUNTIME_TMP}/route53-origin-a.json"
    build_origin_a_change_batch "${change}" "${conflicts}" "${public_ip}"
    aws route53 change-resource-record-sets --hosted-zone-id "${AWS_ORIGIN_ROUTE53_ZONE_ID}" \
        --change-batch "file://${change}" >/dev/null || die "写入源站 Route 53 A 记录失败"
    success "Route 53 源站 A 记录已指向 ${public_ip}"
}

prepare_aws_origin_dns() {
    install_aws_cli
    collect_aws_credentials
    find_route53_zones
    ensure_origin_a_record
    verify_origin_dns
}

certificate_covers_domain() {
    local description=$1
    jq -e --arg domain "${VLESS_CDN_DOMAIN}" '
        def covers($name):
            $name == $domain or
            ($name|startswith("*.") and ($domain|endswith($name[1:])) and
             (($domain|split(".")|length) == ($name|split(".")|length)));
        ([.Certificate.DomainName] + (.Certificate.SubjectAlternativeNames // []))
        | any(.[]; covers(.))' <<<"${description}" >/dev/null
}

find_or_request_acm_certificate() {
    local certificates description arn status token attempt record_name record_type record_value change
    if [[ -n "${AWS_ACM_CERTIFICATE_ARN:-}" ]]; then
        arn=${AWS_ACM_CERTIFICATE_ARN}
    else
        certificates=$(aws acm list-certificates --region "${AWS_CONTROL_REGION}" \
            --certificate-statuses ISSUED PENDING_VALIDATION --output json) \
            || die "列出 ACM 证书失败"
        arn=$(jq -r --arg domain "${VLESS_CDN_DOMAIN}" \
            '.CertificateSummaryList[]?|select(.DomainName==$domain)|.CertificateArn' \
            <<<"${certificates}" | head -n1)
        if [[ -z "${arn}" ]]; then
            token=$(printf '%s' "${VLESS_CDN_DOMAIN}" | sha256sum | cut -c1-32)
            arn=$(aws acm request-certificate --region "${AWS_CONTROL_REGION}" \
                --domain-name "${VLESS_CDN_DOMAIN}" --validation-method DNS \
                --idempotency-token "${token}" --query CertificateArn --output text) \
                || die "申请 ACM 证书失败"
        fi
        AWS_ACM_CERTIFICATE_ARN=${arn}
    fi

    description=""
    for attempt in {1..15}; do
        if description=$(aws acm describe-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${arn}" --output json 2>/dev/null); then
            break
        fi
        sleep 2
    done
    [[ -n "${description}" ]] || die "读取 ACM 证书失败"
    certificate_covers_domain "${description}" || die "ACM 证书不覆盖 ${VLESS_CDN_DOMAIN}"

    status=$(jq -r '.Certificate.Status' <<<"${description}")
    [[ "${status}" == "ISSUED" ]] && return 0
    [[ "${status}" == "PENDING_VALIDATION" ]] || die "ACM 证书状态不可用：${status}"

    for attempt in {1..30}; do
        description=$(aws acm describe-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" --output json) || die "读取 ACM 验证记录失败"
        record_name=$(jq -r '.Certificate.DomainValidationOptions[]?|select(.ResourceRecord)|.ResourceRecord.Name' <<<"${description}" | head -n1)
        record_type=$(jq -r '.Certificate.DomainValidationOptions[]?|select(.ResourceRecord)|.ResourceRecord.Type' <<<"${description}" | head -n1)
        record_value=$(jq -r '.Certificate.DomainValidationOptions[]?|select(.ResourceRecord)|.ResourceRecord.Value' <<<"${description}" | head -n1)
        [[ -n "${record_name}" && -n "${record_value}" ]] && break
        sleep 2
    done
    [[ -n "${record_name:-}" && -n "${record_value:-}" ]] || die "ACM 尚未生成 DNS 验证记录"
    change=$(jq -cn --arg name "${record_name}" --arg type "${record_type}" --arg value "${record_value}" \
        '{Comment:"easy_all ACM DNS validation",Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:$type,TTL:300,ResourceRecords:[{Value:$value}]}}]}')
    aws route53 change-resource-record-sets --hosted-zone-id "${AWS_ROUTE53_ZONE_ID}" \
        --change-batch "${change}" >/dev/null || die "写入 ACM DNS 验证记录失败"
    info "等待 ACM 证书签发（通常几分钟）"
    for attempt in {1..120}; do
        status=$(aws acm describe-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" --query Certificate.Status --output text) \
            || die "查询 ACM 状态失败"
        [[ "${status}" == "ISSUED" ]] && return 0
        [[ "${status}" == "PENDING_VALIDATION" ]] || die "ACM 证书签发失败：${status}"
        sleep 5
    done
    die "等待 ACM 证书签发超时；请检查 Route 53 CNAME 与 CAA 记录"
}

cloudfront_marker() {
    printf 'easy_all:xhttp:%s' "${VLESS_CDN_DOMAIN}"
}

build_distribution_config() {
    local destination=$1 caller_reference=$2
    jq -n \
        --arg caller "${caller_reference}" --arg alias "${VLESS_CDN_DOMAIN}" \
        --arg origin "${AWS_ORIGIN_DOMAIN}" --arg origin_id "${CLOUDFRONT_ORIGIN_ID}" \
        --arg origin_key "${ORIGIN_HEADER_SECRET}" --arg comment "$(cloudfront_marker)" \
        --arg cache_policy "${CLOUDFRONT_CACHE_POLICY_ID}" \
        --arg origin_policy "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}" \
        --argjson connection_attempts "${CLOUDFRONT_CONNECTION_ATTEMPTS}" \
        --argjson connection_timeout "${CLOUDFRONT_CONNECTION_TIMEOUT}" \
        --argjson origin_read_timeout "${CLOUDFRONT_ORIGIN_READ_TIMEOUT}" \
        --argjson origin_keepalive_timeout "${CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT}" \
        --arg certificate "${AWS_ACM_CERTIFICATE_ARN}" '
        {
          CallerReference:$caller,
          Aliases:{Quantity:1,Items:[$alias]},
          DefaultRootObject:"",
          Origins:{Quantity:1,Items:[{
            Id:$origin_id,DomainName:$origin,OriginPath:"",
            CustomHeaders:{Quantity:1,Items:[{HeaderName:"X-Easy-All-Origin-Key",HeaderValue:$origin_key}]},
            CustomOriginConfig:{HTTPPort:80,HTTPSPort:443,OriginProtocolPolicy:"https-only",
              OriginSslProtocols:{Quantity:1,Items:["TLSv1.2"]},
              OriginReadTimeout:$origin_read_timeout,OriginKeepaliveTimeout:$origin_keepalive_timeout},
            ConnectionAttempts:$connection_attempts,ConnectionTimeout:$connection_timeout,
            OriginShield:{Enabled:false}
          }]},
          OriginGroups:{Quantity:0},
          DefaultCacheBehavior:{
            TargetOriginId:$origin_id,
            TrustedSigners:{Enabled:false,Quantity:0},TrustedKeyGroups:{Enabled:false,Quantity:0},
            ViewerProtocolPolicy:"https-only",
            AllowedMethods:{Quantity:7,Items:["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
              CachedMethods:{Quantity:2,Items:["GET","HEAD"]}},
            GrpcConfig:{Enabled:true},
            SmoothStreaming:false,Compress:false,
            LambdaFunctionAssociations:{Quantity:0},FunctionAssociations:{Quantity:0},
            FieldLevelEncryptionId:"",CachePolicyId:$cache_policy,OriginRequestPolicyId:$origin_policy
          },
          CacheBehaviors:{Quantity:0},CustomErrorResponses:{Quantity:0},
          Comment:$comment,Logging:{Enabled:false,IncludeCookies:false,Bucket:"",Prefix:""},
          PriceClass:"PriceClass_All",Enabled:true,
          ViewerCertificate:{CloudFrontDefaultCertificate:false,ACMCertificateArn:$certificate,
            SSLSupportMethod:"sni-only",MinimumProtocolVersion:"TLSv1.2_2021"},
          Restrictions:{GeoRestriction:{RestrictionType:"none",Quantity:0}},
          WebACLId:"",HttpVersion:"http2",IsIPV6Enabled:true,Staging:false,
          ContinuousDeploymentPolicyId:""
        }' >"${destination}"
}

find_managed_distribution() {
    local distributions marker
    marker=$(cloudfront_marker)
    distributions=$(aws cloudfront list-distributions --output json) || die "列出 CloudFront 分配失败"
    jq -r --arg marker "${marker}" \
        '.DistributionList.Items[]?|select(.Comment==$marker)|.Id' \
        <<<"${distributions}" | head -n1
}

configure_cloudfront_distribution() {
    local id=${AWS_CLOUDFRONT_DISTRIBUTION_ID:-} existing config etag caller response comment
    config="${RUNTIME_TMP}/cloudfront-distribution.json"
    if [[ -z "${id}" ]]; then id=$(find_managed_distribution); fi
    if [[ -n "${id}" ]]; then
        existing=$(aws cloudfront get-distribution-config --id "${id}" --output json) \
            || die "读取 CloudFront 分配 ${id} 失败"
        comment=$(jq -r '.DistributionConfig.Comment' <<<"${existing}")
        if [[ "${comment}" != "$(cloudfront_marker)" \
            && "${AWS_ADOPT_DISTRIBUTION:-0}" != "1" ]]; then
            die "CloudFront 分配 ${id} 不是 easy_all XHTTP 管理；若确定要完整改写，请设置 AWS_ADOPT_DISTRIBUTION=1"
        fi
        etag=$(jq -r '.ETag' <<<"${existing}")
        caller=$(jq -r '.DistributionConfig.CallerReference' <<<"${existing}")
        build_distribution_config "${config}" "${caller}"
        response=$(aws cloudfront update-distribution --id "${id}" --if-match "${etag}" \
            --distribution-config "file://${config}" --output json) \
            || die "更新 CloudFront 分配失败"
    else
        caller="easy_all-xhttp-$(date +%s)-$(openssl rand -hex 6)"
        build_distribution_config "${config}" "${caller}"
        response=$(aws cloudfront create-distribution --distribution-config "file://${config}" --output json) \
            || die "创建 CloudFront 分配失败；若域名已绑定其他分配，请显式采用或先解除冲突"
    fi
    AWS_CLOUDFRONT_DISTRIBUTION_ID=$(jq -r '.Distribution.Id' <<<"${response}")
    AWS_CLOUDFRONT_DOMAIN=$(jq -r '.Distribution.DomainName' <<<"${response}")
    [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" && "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" != null ]] \
        || die "CloudFront API 未返回分配 ID"
}

ensure_viewer_cname() {
    local records conflicts change target existing_type
    target="${AWS_CLOUDFRONT_DOMAIN}."
    records=$(aws route53 list-resource-record-sets --hosted-zone-id "${AWS_ROUTE53_ZONE_ID}" \
        --output json) || die "查询 Route 53 记录失败"
    conflicts=$(jq -c --arg name "${VLESS_CDN_DOMAIN}." \
        '[.ResourceRecordSets[]|select(.Name==$name and .Type!="NS" and .Type!="SOA")]' <<<"${records}")
    if [[ "$(jq 'length' <<<"${conflicts}")" -gt 0 ]]; then
        if jq -e --arg target "${target}" \
            'length==1 and .[0].Type=="CNAME" and
             ((.[0].ResourceRecords[0].Value|rtrimstr(".")) == ($target|rtrimstr(".")))' \
            <<<"${conflicts}" >/dev/null; then
            return 0
        fi
        [[ "${AWS_DNS_REPLACE:-0}" == "1" ]] \
            || die "${VLESS_CDN_DOMAIN} 已有 DNS 记录；拒绝覆盖。确认后可设置 AWS_DNS_REPLACE=1"
    fi
    existing_type=$(jq -r 'if length==1 then .[0].Type else "MULTIPLE" end' <<<"${conflicts}")
    if [[ "$(jq 'length' <<<"${conflicts}")" -eq 0 || "${existing_type}" == "CNAME" ]]; then
        change=$(jq -cn --arg name "${VLESS_CDN_DOMAIN}." --arg target "${target}" \
            '{Comment:"easy_all CloudFront CNAME",Changes:[{Action:"UPSERT",ResourceRecordSet:{Name:$name,Type:"CNAME",TTL:300,ResourceRecords:[{Value:$target}]}}]}')
    else
        change=$(jq -cn --arg name "${VLESS_CDN_DOMAIN}." --arg target "${target}" \
            --argjson conflicts "${conflicts}" '
            {Comment:"easy_all replace conflicting DNS records",
             Changes:(($conflicts|map({Action:"DELETE",ResourceRecordSet:.})) +
               [{Action:"CREATE",ResourceRecordSet:{Name:$name,Type:"CNAME",TTL:300,ResourceRecords:[{Value:$target}]}}])}')
    fi
    aws route53 change-resource-record-sets --hosted-zone-id "${AWS_ROUTE53_ZONE_ID}" \
        --change-batch "${change}" >/dev/null || die "写入 CloudFront CNAME 失败"
}

wait_for_cloudfront() {
    info "等待 CloudFront 分配完成（可能需要 5-20 分钟）"
    if timeout 1200 aws cloudfront wait distribution-deployed \
        --id "${AWS_CLOUDFRONT_DISTRIBUTION_ID}"; then
        success "CloudFront 分配已部署"
    else
        die "等待 CloudFront 分配部署超时"
    fi
}

validate_cloudfront_health() {
    local attempt response
    for attempt in {1..20}; do
        response=$(curl -fsS --connect-timeout 5 --max-time 15 \
            "https://${VLESS_CDN_DOMAIN}/easy_all-health" 2>/dev/null || true)
        [[ "${response}" == "easy_all ok" ]] && { success "CloudFront 回源验收通过"; return 0; }
        sleep 10
    done
    die "CloudFront 公网验收失败；请检查 DNS、源站证书、Origin Key 与 gRPC 配置"
}

configure_aws_cdn() {
    install_aws_cli
    collect_aws_credentials
    find_route53_zones
    find_or_request_acm_certificate
    configure_cloudfront_distribution
    ensure_viewer_cname
    wait_for_cloudfront
    validate_cloudfront_health
    clear_aws_credentials
}

cdn_install_dependencies() {
    case "${CDN_PROVIDER:-aws}" in
    aws) install_aws_cli ;;
    *) die "不支持的 CDN Provider：${CDN_PROVIDER:-缺失}" ;;
    esac
}

cdn_prepare_origin() {
    case "${CDN_PROVIDER:-aws}" in
    aws) prepare_aws_origin_dns ;;
    *) die "不支持的 CDN Provider：${CDN_PROVIDER:-缺失}" ;;
    esac
}

cdn_apply() {
    case "${CDN_PROVIDER:-aws}" in
    aws) configure_aws_cdn ;;
    *) die "不支持的 CDN Provider：${CDN_PROVIDER:-缺失}" ;;
    esac
}

uri_encode() {
    jq -nr --arg value "$1" '$value|@uri'
}

build_vless_xhttp_link() {
    local extra
    extra=$(jq -cn \
        --arg max_concurrency "${XHTTP_XMUX_MAX_CONCURRENCY}" \
        --argjson c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_request_times "${XHTTP_XMUX_H_MAX_REQUEST_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --argjson h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '{
        noGRPCHeader:false,
        uplinkMethod:"POST",
        xmux:{
            maxConcurrency:$max_concurrency,
            cMaxReuseTimes:$c_max_reuse_times,
            hMaxRequestTimes:$h_max_request_times,
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
    jq -nr --arg xhttp_name "${XHTTP_NODE_NAME}" \
        --arg server "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg xhttp_path "${XHTTP_PATH}" \
        --arg max_concurrency "${XHTTP_XMUX_MAX_CONCURRENCY}" \
        --arg c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_request_times "${XHTTP_XMUX_H_MAX_REQUEST_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --arg h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '
        "  - name: \($xhttp_name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($server|@json)\n    client-fingerprint: chrome\n" +
        "    ip-version: ipv4\n    packet-encoding: xudp\n    alpn:\n      - h2\n    xhttp-opts:\n" +
        "      host: \($server|@json)\n      path: \($xhttp_path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n" +
        "        max-concurrency: \($max_concurrency|@json)\n        c-max-reuse-times: \($c_max_reuse_times)\n" +
        "        h-max-request-times: \($h_max_request_times|@json)\n" +
        "        h-max-reusable-secs: \($h_max_reusable_secs|@json)\n" +
        "        h-keep-alive-period: \($h_keep_alive_period)\n"'
}

validate_mihomo_template() {
    local source=$1 marker
    [[ -s "${source}" ]] || die "Mihomo 模板为空"
    for marker in "# EASY_ALL_PROXY_NODE" "# EASY_ALL_PROXY_NAME"; do
        [[ "$(grep -Fxc "${marker}" "${source}" || true)" == 1 ]] \
            || die "Mihomo 模板标记无效：${marker}"
    done
}

fetch_mihomo_template() {
    local destination=$1 source=${MIHOMO_TEMPLATE_SOURCE:-} url
    if [[ -n "${source}" ]]; then
        if [[ -f "${source}" ]]; then
            install -m 0600 "${source}" "${destination}"
        elif [[ "${source}" =~ ^https:// ]]; then
            curl -fsSL --retry 3 "${source}" -o "${destination}" || die "下载 Mihomo 模板失败"
        else
            die "MIHOMO_TEMPLATE_SOURCE 必须是本地文件或 HTTPS URL"
        fi
    elif [[ -f "${SCRIPT_DIR}/sample-mihomo.yaml" ]]; then
        install -m 0600 "${SCRIPT_DIR}/sample-mihomo.yaml" "${destination}"
    else
        url=${MIHOMO_TEMPLATE_URL:-${DEFAULT_MIHOMO_TEMPLATE_URL}}
        curl -fsSL --retry 3 "${url}" -o "${destination}" || die "下载 Mihomo 模板失败"
    fi
    validate_mihomo_template "${destination}"
}

render_mihomo_subscription() {
    local template=$1 node_file=$2 destination=$3 node_name
    node_name=$(jq -Rn --arg value "${XHTTP_NODE_NAME}" '$value')
    awk -v node_file="${node_file}" -v node_name="${node_name}" '
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
    local template node_file base64_file mihomo_file
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"

    fetch_mihomo_template "${template}"
    build_mihomo_node >"${node_file}"
    printf '%s' "$(build_node_link)" | openssl base64 -A >"${base64_file}"
    printf '\n' >>"${base64_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}"

    grep -Fq 'network: xhttp' "${mihomo_file}" || die "Mihomo 订阅缺少 XHTTP 节点"
    grep -Fq "${VLESS_CDN_DOMAIN}" "${mihomo_file}" || die "Mihomo 订阅缺少 CDN 域名"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
}

remove_subscriptions() {
    rm -rf -- "${SUBSCRIPTION_DIR}"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS XHTTP stream-up/H2 over AWS CloudFront\n节点链接:\n%s\n\n' "$(build_node_link)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node
    printf '\n'
}

show_subscription() {
    collect_installed_state
    show_node
    if ! subscription_enabled; then
        printf '订阅服务: 未部署，仅输出节点信息\n\n'
        return 0
    fi
    printf 'Mihomo 下载文件名: %s.yaml\n' "${SUB_DOWNLOAD_NAME}"
    local token
    while IFS= read -r token; do
        printf '通用订阅: https://%s/subscribe?token=%s\n' "${VLESS_CDN_DOMAIN}" "${token}"
        printf 'Mihomo:  https://%s/subscribe?token=%s&flag=clash\n' \
            "${VLESS_CDN_DOMAIN}" "${token}"
    done < <(jq -r '.[]' <<<"${ALLOWED_TOKENS}")
    printf '\n'
}

show_status() {
    require_root
    collect_installed_state
    printf '协议: xhttp\n源站域名: %s\nCDN 域名: %s\nXHTTP 路径: %s\n' \
        "${AWS_ORIGIN_DOMAIN}" "${VLESS_CDN_DOMAIN}" "${XHTTP_PATH}"
    printf 'CloudFront 分配 ID: %s\nCloudFront 域名: %s\n' \
        "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-未知}" "${AWS_CLOUDFRONT_DOMAIN:-未知}"
    printf 'Route 53 源站 Zone ID: %s\nRoute 53 CDN Zone ID: %s\n' \
        "${AWS_ORIGIN_ROUTE53_ZONE_ID:-未知}" "${AWS_ROUTE53_ZONE_ID:-未知}"
    printf 'Xray: '; systemctl is-active --quiet "${XRAY_SERVICE}" && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '; systemctl is-active --quiet nginx && printf 'active\n' || printf 'inactive\n'
    printf 'UFW: '; LC_ALL=C ufw status 2>/dev/null | sed -n 's/^Status: //p'
    printf 'TCP 443: '; ss -H -ltn 'sport = :443' 2>/dev/null | grep -q . \
        && printf 'listening\n' || printf 'not listening\n'
    if subscription_enabled; then
        printf '订阅服务: enabled\n订阅文件: %s, %s\n' \
            "${SUBSCRIPTION_BASE64_FILE}" "${SUBSCRIPTION_MIHOMO_FILE}"
    else
        printf '订阅服务: disabled（仅节点）\n'
    fi
}

register_easy_all_command() {
    local destination="${COMMAND_INSTALL_DIR}/${ENTRY_COMMAND_NAME}"
    require_root
    [[ -f "${ENTRY_SCRIPT_FILE}" ]] || die "未找到入口脚本：${ENTRY_SCRIPT_FILE}"
    install -d -m 0755 "${COMMAND_INSTALL_DIR}" "$(dirname "${COMMAND_PATH}")"
    if [[ "${ENTRY_SCRIPT_FILE}" != "${destination}" ]]; then
        install -m 0755 "${ENTRY_SCRIPT_FILE}" "${destination}"
    else
        chmod 0755 "${destination}"
    fi
    ln -sfn "${destination}" "${COMMAND_PATH}"
}

refresh_runtime() {
    local backup
    collect_installed_state
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

update_subscription() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    if subscription_enabled; then
        choose_subscription_download_name
        ensure_allowed_tokens
        write_subscriptions
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        remove_subscriptions
    fi
    write_nginx_config
    subscription_enabled && validate_subscription_runtime
    save_state
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Nginx 订阅已刷新"
}

update_easy_all() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    cdn_prepare_origin
    cdn_apply
    refresh_runtime
    if subscription_enabled; then
        ensure_allowed_tokens
        write_subscriptions
        validate_subscription_runtime
    else
        remove_subscriptions
    fi
    save_state
    register_easy_all_command
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "easy_all CDN XHTTP 已更新"
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/xray-backup"
    require_root
    collect_installed_state
    install -m 0755 "${XRAY_BIN}" "${backup_bin}"
    if download_xray && systemctl restart "${XRAY_SERVICE}" && validate_protocol_runtime; then
        success "Xray 已更新"
        return 0
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

rollback_fresh_install() {
    warn "安装失败，正在恢复本机服务与防火墙；已创建的 AWS 资源不会自动删除"
    stop_services
    restore_preinstall_firewall
    if [[ -f "${BACKUP_DIR}/pre-install-bbr.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr.conf" "${SYSCTL_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr.missing" ]]; then
        rm -f -- "${SYSCTL_CONFIG}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-bbr-module.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr-module.conf" "${BBR_MODULES_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr-module.missing" ]]; then
        rm -f -- "${BBR_MODULES_CONFIG}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-crontab" ]]; then
        crontab "${BACKUP_DIR}/pre-install-crontab" >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-crontab.missing" ]]; then
        crontab -r >/dev/null 2>&1 || true
    fi
    remove_managed_acme_domain "${AWS_ORIGIN_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
}

uninstall_all() {
    local mode=${1:-}
    require_root
    [[ -z "${mode}" ]] || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all XHTTP 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        local answer
        read -r -p "确认删除 easy_all XHTTP 本机服务、状态和证书？远端 AWS 资源会保留。[y/N]: " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_services
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    remove_managed_acme_domain "${AWS_ORIGIN_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    success "easy_all XHTTP 本机内容已卸载；CloudFront、ACM 与 Route 53 记录未删除"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="aws"
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all update"
    check_platform
    check_install_conflicts
    snapshot_fresh_install
    info "[1/9] 安装系统依赖"
    install_packages
    ensure_ssh_boot_service
    cdn_install_dependencies
    info "[2/9] 初始化 Google BBR 与定时重启"
    configure_bbr_tcp
    configure_daily_reboot
    info "[3/9] 收集域名与 VLESS 参数"
    collect_install_inputs
    alert "源站域名与 CDN 域名都必须位于 AWS Route 53 Public Hosted Zone。"
    info "[4/9] 创建并验证 Route 53 源站 A 记录"
    cdn_prepare_origin
    info "[5/9] 配置防火墙与 HTTP-01 入口"
    configure_ufw
    write_bootstrap_nginx_config
    info "[6/9] 申请源站证书并安装 Xray"
    issue_origin_certificate
    download_xray
    write_xray_config
    install_xray_service
    subscription_enabled && write_subscriptions
    write_nginx_config
    validate_protocol_runtime
    subscription_enabled && validate_subscription_runtime
    info "[7/9] 配置 ACM、CloudFront 与 Route 53 CDN 记录"
    cdn_apply
    info "[8/9] 保存状态并注册命令"
    save_state
    register_easy_all_command
    INSTALL_ROLLBACK_ON_EXIT=0
    info "[9/9] 输出节点与订阅"
    show_subscription
    success "easy_all CDN XHTTP 安装完成"
}

usage() {
    cat <<EOF
用法: ${ENTRY_COMMAND_NAME} [命令]

  install          安装 VLESS XHTTP TLS + Route 53 + CloudFront
  update           刷新 Route 53、运行时、CloudFront 与当前订阅模式
  update-sub       选择部署订阅服务或仅输出节点
  show             显示 VLESS 链接与 Mihomo 节点
  subscription     显示节点与订阅状态
  status           显示本机、Route 53 与 CloudFront 状态摘要
  update-core      更新 Xray，失败时恢复旧版本
  renew-cert       强制续期源站 Let's Encrypt 证书
  register-command 重新注册 /usr/local/bin/easy_all
  uninstall        删除本机内容，保留远端 AWS 资源

发布单个 VLESS XHTTP stream-up/H2 节点。节点 DNS 全部由 Route 53 管理；
CloudFront 使用 HTTPS 回源、禁用缓存、启用 gRPC，并转发除 Host 外的全部查看器请求头。
可选择部署 CloudFront + Nginx Token 订阅，或仅输出节点信息。
EOF
}

main() {
    case "${1:-install}" in
    install) install_all ;;
    update) update_easy_all ;;
    update-sub) update_subscription ;;
    show) require_root; show_node ;;
    subscription) require_root; show_subscription ;;
    status) show_status ;;
    update-core) update_current_core ;;
    renew-cert) renew_certificate ;;
    register-command) register_easy_all_command ;;
    uninstall) uninstall_all ;;
    help | -h | --help) usage ;;
    *) usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
