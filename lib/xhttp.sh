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
readonly STATE_SCHEMA_VERSION="2"
readonly AWS_CONTROL_REGION="us-east-1"
readonly AWS_CLOUDFRONT_PLAN_FAMILY="CloudFront"
readonly AWS_CLOUDFRONT_PLAN_TIER="FREE"
readonly CLOUDFRONT_CACHE_POLICY_ID="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
readonly CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID="b689b0a8-53d0-40ab-baf2-68738e2966ac"
readonly CLOUDFRONT_ORIGIN_ID="easy_all-xhttp-origin"
readonly CLOUDFRONT_ROUTE53_ZONE_ID="Z2FDTNDATAQYW2"
readonly CLOUDFRONT_CONNECTION_ATTEMPTS="2"
readonly CLOUDFRONT_CONNECTION_TIMEOUT="3"
readonly CLOUDFRONT_ORIGIN_READ_TIMEOUT="60"
readonly CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT="60"
readonly XHTTP_STREAM_UP_SERVER_SECS="20-40"
readonly XHTTP_XMUX_MAX_CONCURRENCY="4-8"
readonly XHTTP_XMUX_C_MAX_REUSE_TIMES="0"
readonly XHTTP_XMUX_H_MAX_REUSABLE_SECS="1800-3000"
readonly XHTTP_XMUX_H_KEEP_ALIVE_PERIOD="0"

# shellcheck source=lib/quota.sh
source "${SCRIPT_DIR}/quota.sh"
# shellcheck source=lib/platform.sh
source "${SCRIPT_DIR}/platform.sh"
# shellcheck source=lib/profile-runtime.sh
source "${SCRIPT_DIR}/profile-runtime.sh"
# shellcheck source=lib/network.sh
source "${SCRIPT_DIR}/network.sh"
# shellcheck source=lib/firewall.sh
source "${SCRIPT_DIR}/firewall.sh"
# shellcheck source=lib/xray-core.sh
source "${SCRIPT_DIR}/xray-core.sh"
# shellcheck source=lib/acme-renewal.sh
source "${SCRIPT_DIR}/acme-renewal.sh"
# shellcheck source=lib/subscription-auth.sh
source "${SCRIPT_DIR}/subscription-auth.sh"
# shellcheck source=lib/validation.sh
source "${SCRIPT_DIR}/validation.sh"
# shellcheck source=lib/tcp-tuning.sh
source "${SCRIPT_DIR}/tcp-tuning.sh"
# shellcheck source=lib/reboot-schedule.sh
source "${SCRIPT_DIR}/reboot-schedule.sh"

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
            printf '  1. 部署订阅服务（CloudFront + Nginx；只有当前服务器时推荐）\n'
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
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
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
        AWS_WAF_WEB_ACL_ARN AWS_CLOUDFRONT_DISTRIBUTION_ID
        AWS_CLOUDFRONT_DISTRIBUTION_ARN AWS_CLOUDFRONT_DOMAIN
        AWS_CLOUDFRONT_PRICING_PLAN_ARN
        ALLOWED_TOKENS SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
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
        printf 'AWS_WAF_WEB_ACL_ARN=%q\n' "${AWS_WAF_WEB_ACL_ARN:-}"
        printf 'AWS_CLOUDFRONT_DISTRIBUTION_ID=%q\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}"
        printf 'AWS_CLOUDFRONT_DISTRIBUTION_ARN=%q\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ARN:-}"
        printf 'AWS_CLOUDFRONT_DOMAIN=%q\n' "${AWS_CLOUDFRONT_DOMAIN:-}"
        printf 'AWS_CLOUDFRONT_PRICING_PLAN_ARN=%q\n' "${AWS_CLOUDFRONT_PRICING_PLAN_ARN:-}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'QUOTA_ENABLED=%q\n' "${QUOTA_ENABLED:-0}"
        printf 'USER_ACCOUNTS=%q\n' "${USER_ACCOUNTS:-}"
        printf 'QUOTA_START_DATE=%q\n' "${QUOTA_START_DATE:-}"
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

aws_cli_supports_flat_rate_plans() {
    aws --version 2>&1 | grep -q '^aws-cli/2\.' \
        && aws freetier get-account-plan-state --generate-cli-skeleton input \
            >/dev/null 2>&1 \
        && aws pricing-plan-manager list-subscriptions --generate-cli-skeleton input \
            >/dev/null 2>&1
}

install_aws_cli() {
    if command -v aws >/dev/null 2>&1 && aws_cli_supports_flat_rate_plans; then
        return 0
    fi
    local temp_dir archive
    info "安装或更新支持 CloudFront 固定套餐的 AWS CLI v2"
    temp_dir=$(make_temp_dir)
    archive="${temp_dir}/awscliv2.zip"
    curl -fsSL --retry 3 "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "${archive}" \
        || die "下载 AWS CLI v2 失败"
    unzip -q "${archive}" -d "${temp_dir}"
    "${temp_dir}/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
        || die "安装 AWS CLI v2 失败"
    hash -r
    command -v aws >/dev/null 2>&1 && aws_cli_supports_flat_rate_plans \
        || die "AWS CLI v2 安装后仍不支持 CloudFront 固定套餐 API"
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

configure_ufw() {
    local desired_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends ufw
    fi
    detect_ssh_ports
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    desired_ports="${SSH_PORTS} 80 443"
    apply_managed_ufw_tcp_ports "${desired_ports}"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
}

verify_origin_dns() {
    local public_ip records resolver attempt resolver_ok last_records=""
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    info "等待 Route 53 源站 A 记录传播到公共 DNS"
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
    local clients
    install -d -m 0755 "${XRAY_DIR}"
    if quota_enabled; then
        clients=$(quota_active_clients_json)
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" \
            '[{id:$id,email:$email}]')
    fi
    jq -n --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson clients "${clients}" \
        --argjson quota_enabled "$([[ "${QUOTA_ENABLED:-0}" == "1" ]] && printf true || printf false)" \
        --arg xhttp_path "${XHTTP_PATH}" --arg xhttp_host "${VLESS_CDN_DOMAIN}" \
        --arg stream_up_server_secs "${XHTTP_STREAM_UP_SERVER_SECS}" '
        {
          log:{loglevel:"warning"},
          inbounds:[{
              tag:"vless-xhttp-h2-in", listen:"127.0.0.1", port:$xhttp_port, protocol:"vless",
              settings:{clients:$clients,decryption:"none"},
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
        }
        + (if $quota_enabled then {
            api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]},
            stats:{},
            policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}}
          } else {} end)' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
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

collect_aws_credentials() {
    local identity arn
    export AWS_DEFAULT_REGION="${AWS_CONTROL_REGION}"
    export AWS_PAGER=""
    if [[ "${AWS_USE_DEFAULT_CREDENTIAL_CHAIN:-0}" == "1" ]]; then
        identity=$(aws sts get-caller-identity --output json) || die "AWS 默认凭证链不可用"
        arn=$(jq -r '.Arn // empty' <<<"${identity}")
        [[ "${arn}" != *":root" ]] || die "拒绝使用 AWS 根用户凭证；请改用专用 IAM 用户或 Role"
        AWS_ACCOUNT_ID=$(jq -r '.Account // empty' <<<"${identity}")
        [[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || die "AWS STS 未返回有效账号 ID"
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
    AWS_ACCOUNT_ID=$(jq -r '.Account // empty' <<<"${identity}")
    [[ "${AWS_ACCOUNT_ID}" =~ ^[0-9]{12}$ ]] || die "AWS STS 未返回有效账号 ID"
}

clear_aws_credentials() {
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_SECURITY_TOKEN
}

confirm_aws_paid_account_upgrade() {
    local answer
    [[ "${AWS_ACCOUNT_PLAN_UPGRADE:-0}" == "1" ]] && return 0
    if [[ ! -t 0 ]]; then
        die "AWS 账号仍是 Free account plan；非交互执行必须显式设置 AWS_ACCOUNT_PLAN_UPGRADE=1"
    fi
    alert "CloudFront Free 固定套餐要求 AWS 账号先升级为 Paid account plan。"
    warn "升级不会清空正常剩余的 Free Tier Credit，但超出 Credit 或套餐范围的资源可能扣费。"
    read -r -p "确认由脚本将 AWS 账号 ${AWS_ACCOUNT_ID} 升级为 Paid account plan？[y/N]（直接回车取消）: " answer
    [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消 AWS 账号计划升级"
}

ensure_aws_paid_account_plan() {
    local state plan_type plan_status response attempt
    state=$(aws freetier get-account-plan-state --region "${AWS_CONTROL_REGION}" --output json) \
        || die "查询 AWS account plan 失败；请确认 IAM 包含 freetier:GetAccountPlanState"
    plan_type=$(jq -r '.accountPlanType // empty' <<<"${state}")
    plan_status=$(jq -r '.accountPlanStatus // empty' <<<"${state}")
    case "${plan_type}" in
    PAID)
        info "AWS account plan 已是 Paid（${plan_status:-UNKNOWN}）"
        return 0
        ;;
    FREE)
        confirm_aws_paid_account_upgrade
        response=$(aws freetier upgrade-account-plan --region "${AWS_CONTROL_REGION}" \
            --account-plan-type PAID --output json) \
            || die "AWS account plan 升级失败；请确认 IAM 包含 freetier:UpgradeAccountPlan"
        [[ "$(jq -r '.accountPlanType // empty' <<<"${response}")" == "PAID" ]] \
            || die "AWS API 未确认 account plan 已升级为 Paid"
        for attempt in {1..12}; do
            state=$(aws freetier get-account-plan-state --region "${AWS_CONTROL_REGION}" \
                --output json) || die "复核 AWS account plan 失败"
            [[ "$(jq -r '.accountPlanType // empty' <<<"${state}")" == "PAID" ]] \
                && { success "AWS account plan 已升级为 Paid；剩余 Free Tier Credit 保留至原到期日"; return 0; }
            sleep 5
        done
        die "AWS account plan 升级已提交，但等待 Paid 状态超时"
        ;;
    *)
        die "AWS API 返回未知 account plan：${plan_type:-缺失}（状态 ${plan_status:-缺失}）"
        ;;
    esac
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

select_reusable_acm_certificate() {
    local certificates=$1
    jq -r --arg domain "${VLESS_CDN_DOMAIN}" '
        def covers($name):
            $name == $domain or
            ($name|startswith("*.") and ($domain|endswith($name[1:])) and
             (($domain|split(".")|length) == ($name|split(".")|length)));
        [.CertificateSummaryList[]? |
          select(any(([.DomainName] + (.SubjectAlternativeNameSummaries // []))[]; covers(.)))]
        | sort_by((if .Status == "ISSUED" then 0 else 1 end), .DomainName, .CertificateArn)
        | first.CertificateArn // empty' <<<"${certificates}"
}

find_or_request_acm_certificate() {
    local certificates description arn status token attempt record_name record_type record_value change
    if [[ -n "${AWS_ACM_CERTIFICATE_ARN:-}" ]]; then
        arn=${AWS_ACM_CERTIFICATE_ARN}
    else
        certificates=$(aws acm list-certificates --region "${AWS_CONTROL_REGION}" \
            --certificate-statuses ISSUED PENDING_VALIDATION --output json) \
            || die "列出 ACM 证书失败"
        arn=$(select_reusable_acm_certificate "${certificates}")
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

waf_web_acl_name() {
    local suffix
    suffix=$(printf '%s' "${VLESS_CDN_DOMAIN}" | sha256sum | cut -c1-16)
    printf 'easy-all-xhttp-%s' "${suffix}"
}

list_cloudfront_web_acls() {
    local marker="" response web_acls='[]'
    local -a arguments
    while true; do
        arguments=(wafv2 list-web-acls --scope CLOUDFRONT --region "${AWS_CONTROL_REGION}"
            --limit 100 --no-paginate --output json)
        [[ -z "${marker}" ]] || arguments+=(--next-marker "${marker}")
        response=$(aws "${arguments[@]}") || die "列出 CloudFront WAF Web ACL 失败"
        web_acls=$(jq -cn --argjson existing "${web_acls}" \
            --argjson page "$(jq -c '.WebACLs // []' <<<"${response}")" \
            '$existing + $page')
        marker=$(jq -r '.NextMarker // empty' <<<"${response}")
        [[ -n "${marker}" ]] || break
    done
    jq -cn --argjson web_acls "${web_acls}" '{WebACLs:$web_acls}'
}

ensure_cloudfront_web_acl() {
    local web_acls matches count response name
    name=$(waf_web_acl_name)
    web_acls=$(list_cloudfront_web_acls)

    if [[ -n "${AWS_WAF_WEB_ACL_ARN:-}" ]] \
        && jq -e --arg arn "${AWS_WAF_WEB_ACL_ARN}" \
            'any(.WebACLs[]?; .ARN == $arn)' <<<"${web_acls}" >/dev/null; then
        info "复用 CloudFront Free 套餐 WAF：${AWS_WAF_WEB_ACL_ARN}"
        return 0
    fi

    matches=$(jq -c --arg name "${name}" '[.WebACLs[]? | select(.Name == $name)]' <<<"${web_acls}")
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "发现多个同名 WAF Web ACL：${name}"
    if ((count == 1)); then
        AWS_WAF_WEB_ACL_ARN=$(jq -r '.[0].ARN' <<<"${matches}")
        info "复用 easy_all CloudFront WAF：${AWS_WAF_WEB_ACL_ARN}"
        return 0
    fi

    response=$(aws wafv2 create-web-acl --scope CLOUDFRONT --region "${AWS_CONTROL_REGION}" \
        --name "${name}" --description "Dedicated to easy_all CloudFront Free plan" \
        --default-action 'Allow={}' \
        --visibility-config \
            "SampledRequestsEnabled=false,CloudWatchMetricsEnabled=true,MetricName=${name}" \
        --output json) || die "创建 CloudFront Free 套餐所需 WAF Web ACL 失败"
    AWS_WAF_WEB_ACL_ARN=$(jq -r '.Summary.ARN // empty' <<<"${response}")
    [[ "${AWS_WAF_WEB_ACL_ARN}" == arn:aws:wafv2:${AWS_CONTROL_REGION}:*:global/webacl/* ]] \
        || die "WAF API 未返回有效的 CloudFront Web ACL ARN"
    success "已创建默认放行的独占 WAF Web ACL；不会改变 XHTTP 请求路径"
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
        --arg certificate "${AWS_ACM_CERTIFICATE_ARN}" \
        --arg web_acl "${AWS_WAF_WEB_ACL_ARN}" '
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
          WebACLId:$web_acl,HttpVersion:"http2",IsIPV6Enabled:true,Staging:false,
          ContinuousDeploymentPolicyId:""
        }' >"${destination}"
}

find_managed_distribution() {
    local distributions marker ids count
    marker=$(cloudfront_marker)
    distributions=$(aws cloudfront list-distributions --output json) || die "列出 CloudFront 分配失败"
    ids=$(jq -c --arg marker "${marker}" \
        '[.DistributionList.Items[]?|select(.Comment==$marker)|.Id]' <<<"${distributions}")
    count=$(jq 'length' <<<"${ids}")
    ((count <= 1)) \
        || die "发现多个带有 ${marker} 标记的 CloudFront 分配；请清理重复资源或显式设置 AWS_CLOUDFRONT_DISTRIBUTION_ID"
    jq -r 'first // empty' <<<"${ids}"
}

configure_cloudfront_distribution() {
    local id=${AWS_CLOUDFRONT_DISTRIBUTION_ID:-} existing config etag caller response comment
    local create_error
    config="${RUNTIME_TMP}/cloudfront-distribution.json"
    if [[ -z "${id}" ]]; then id=$(find_managed_distribution); fi
    if [[ -n "${id}" ]]; then
        existing=$(aws cloudfront get-distribution-config --id "${id}" --output json) \
            || die "读取 CloudFront 分配 ${id} 失败"
        comment=$(jq -r '.DistributionConfig.Comment' <<<"${existing}")
        [[ "${comment}" == "$(cloudfront_marker)" ]] \
            || die "CloudFront 分配 ${id} 不是当前 easy_all XHTTP 管理，拒绝接管旧部署或其他分配"
        etag=$(jq -r '.ETag' <<<"${existing}")
        caller=$(jq -r '.DistributionConfig.CallerReference' <<<"${existing}")
        build_distribution_config "${config}" "${caller}"
        response=$(aws cloudfront update-distribution --id "${id}" --if-match "${etag}" \
            --distribution-config "file://${config}" --output json) \
            || die "更新 CloudFront 分配失败"
    else
        caller="easy_all-xhttp-$(date +%s)-$(openssl rand -hex 6)"
        build_distribution_config "${config}" "${caller}"
        create_error="${RUNTIME_TMP}/cloudfront-create.stderr"
        if ! response=$(aws cloudfront create-distribution --distribution-config "file://${config}" \
            --output json 2>"${create_error}"); then
            if grep -Fq "CNAMEAlreadyExists" "${create_error}"; then
                die "CDN 域名 ${VLESS_CDN_DOMAIN} 已绑定其他 CloudFront 分配；脚本不会接管旧部署，请先删除旧分配或解除该别名"
            fi
            cat "${create_error}" >&2
            die "创建 CloudFront 分配失败"
        fi
    fi
    AWS_CLOUDFRONT_DISTRIBUTION_ID=$(jq -r '.Distribution.Id' <<<"${response}")
    AWS_CLOUDFRONT_DISTRIBUTION_ARN=$(jq -r '.Distribution.ARN // empty' <<<"${response}")
    AWS_CLOUDFRONT_DOMAIN=$(jq -r '.Distribution.DomainName' <<<"${response}")
    [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" && "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" != null ]] \
        || die "CloudFront API 未返回分配 ID"
    if [[ -z "${AWS_CLOUDFRONT_DISTRIBUTION_ARN}" ]]; then
        AWS_CLOUDFRONT_DISTRIBUTION_ARN="arn:aws:cloudfront::${AWS_ACCOUNT_ID}:distribution/${AWS_CLOUDFRONT_DISTRIBUTION_ID}"
    fi
}

build_viewer_alias_change_batch() {
    local destination=$1 conflicts=$2 target=$3
    jq -n --arg name "${VLESS_CDN_DOMAIN}." --arg target "${target}" \
        --arg target_zone "${CLOUDFRONT_ROUTE53_ZONE_ID}" --argjson conflicts "${conflicts}" '
        def alias_record($type):
          {Action:"CREATE",ResourceRecordSet:{Name:$name,Type:$type,
            AliasTarget:{HostedZoneId:$target_zone,DNSName:$target,EvaluateTargetHealth:false}}};
        {Comment:"easy_all CloudFront Alias A/AAAA",
         Changes:(($conflicts | map({Action:"DELETE",ResourceRecordSet:.})) +
           [alias_record("A"),alias_record("AAAA")])}' >"${destination}"
}

viewer_records_are_alias_target() {
    local conflicts=$1 target=$2 require_both=${3:-0}
    jq -e --arg target "${target}" --arg zone "${CLOUDFRONT_ROUTE53_ZONE_ID}" \
        --argjson require_both "${require_both}" '
        (length >= 1 and length <= 2) and
        (all(.[];
          (.Type == "A" or .Type == "AAAA") and
          .AliasTarget.HostedZoneId == $zone and
          .AliasTarget.EvaluateTargetHealth == false and
          ((.AliasTarget.DNSName | rtrimstr(".")) == ($target | rtrimstr("."))))) and
        ((map(.Type) | unique | length) == length) and
        (($require_both == 0) or ((map(.Type) | sort) == ["A","AAAA"]))' \
        <<<"${conflicts}" >/dev/null
}

ensure_viewer_alias_records() {
    local records conflicts change target
    target="${AWS_CLOUDFRONT_DOMAIN}."
    records=$(aws route53 list-resource-record-sets --hosted-zone-id "${AWS_ROUTE53_ZONE_ID}" \
        --output json) || die "查询 Route 53 记录失败"
    conflicts=$(jq -c --arg name "${VLESS_CDN_DOMAIN}." \
        '[.ResourceRecordSets[]|select(.Name==$name and .Type!="NS" and .Type!="SOA")]' <<<"${records}")
    if viewer_records_are_alias_target "${conflicts}" "${target}" 1; then
        info "Route 53 CDN Alias A/AAAA 已指向当前 CloudFront 分配"
        return 0
    fi
    if [[ "$(jq 'length' <<<"${conflicts}")" -gt 0 ]]; then
        [[ "${AWS_DNS_REPLACE:-0}" == "1" ]] \
            || die "${VLESS_CDN_DOMAIN} 已有 DNS 记录；拒绝覆盖。确认后可设置 AWS_DNS_REPLACE=1"
    fi
    change="${RUNTIME_TMP}/route53-viewer-alias.json"
    build_viewer_alias_change_batch "${change}" "${conflicts}" "${target}"
    aws route53 change-resource-record-sets --hosted-zone-id "${AWS_ROUTE53_ZONE_ID}" \
        --change-batch "file://${change}" >/dev/null || die "写入 CloudFront Alias A/AAAA 失败"
    success "Route 53 CDN 记录已收敛为免查询费的 CloudFront Alias A/AAAA"
}

wait_for_cloudfront() {
    info "等待 CloudFront 分配完成（可能需要 5-20 分钟）"
    info "分配 ID: ${AWS_CLOUDFRONT_DISTRIBUTION_ID}"
    info "控制台: https://console.aws.amazon.com/cloudfront/v4/home#/distributions/${AWS_CLOUDFRONT_DISTRIBUTION_ID}"
    if timeout 1200 aws cloudfront wait distribution-deployed \
        --id "${AWS_CLOUDFRONT_DISTRIBUTION_ID}"; then
        success "CloudFront 分配已部署"
    else
        die "等待 CloudFront 分配部署超时"
    fi
}

select_cloudfront_pricing_subscription() {
    local subscriptions=$1 distribution_arn=$2
    jq -c --arg distribution "${distribution_arn}" '
        [.subscriptionSummaries[]? |
          select(any(.resourceArns[]?; . == $distribution))]' <<<"${subscriptions}"
}

wait_for_cloudfront_pricing_plan() {
    local attempt details status reason get_error
    get_error="${RUNTIME_TMP}/pricing-plan-get.stderr"
    info "等待 CloudFront Free 固定套餐生效（通常 2-5 分钟）"
    for attempt in {1..120}; do
        if ! details=$(aws pricing-plan-manager get-subscription --region "${AWS_CONTROL_REGION}" \
            --arn "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}" --output json 2>"${get_error}"); then
            if ((attempt <= 6)) && grep -Fq 'ResourceNotFoundException' "${get_error}"; then
                sleep 5
                continue
            fi
            [[ ! -s "${get_error}" ]] || cat "${get_error}" >&2
            die "查询 CloudFront 固定套餐状态失败"
        fi
        status=$(jq -r '.subscription.status // .status // empty' <<<"${details}")
        case "${status}" in
        ACTIVE)
            success "CloudFront Free 固定套餐已生效"
            return 0
            ;;
        FAILED)
            reason=$(jq -r '.subscription.statusReason // .statusReason // "AWS 未返回原因"' \
                <<<"${details}")
            die "CloudFront Free 固定套餐同步失败：${reason}"
            ;;
        SYNC_IN_PROGRESS) sleep 5 ;;
        PENDING_APPROVAL)
            die "FREE 固定套餐异常进入 PENDING_APPROVAL；拒绝自动批准任何付费套餐"
            ;;
        *) die "CloudFront 固定套餐返回未知状态：${status:-缺失}" ;;
        esac
    done
    die "等待 CloudFront Free 固定套餐生效超时"
}

ensure_cloudfront_free_pricing_plan() {
    local distribution_arn zone_arn subscriptions matches count response details
    local tier actual_waf resources etag token
    distribution_arn=${AWS_CLOUDFRONT_DISTRIBUTION_ARN:-}
    if [[ -z "${distribution_arn}" ]]; then
        distribution_arn="arn:aws:cloudfront::${AWS_ACCOUNT_ID}:distribution/${AWS_CLOUDFRONT_DISTRIBUTION_ID}"
        AWS_CLOUDFRONT_DISTRIBUTION_ARN=${distribution_arn}
    fi
    zone_arn="arn:aws:route53:::hostedzone/${AWS_ROUTE53_ZONE_ID}"
    subscriptions=$(aws pricing-plan-manager list-subscriptions --region "${AWS_CONTROL_REGION}" \
        --output json) || die "列出 CloudFront 固定套餐失败"
    matches=$(select_cloudfront_pricing_subscription "${subscriptions}" "${distribution_arn}")
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "当前 CloudFront 分配关联了多个固定套餐；拒绝继续修改"

    if ((count == 0)); then
        token="easyall-free-$(printf '%s' "${distribution_arn}" | sha256sum | cut -c1-32)"
        response=$(aws pricing-plan-manager create-subscription --region "${AWS_CONTROL_REGION}" \
            --plan-family "${AWS_CLOUDFRONT_PLAN_FAMILY}" \
            --plan-tier "${AWS_CLOUDFRONT_PLAN_TIER}" \
            --resource-arns "${distribution_arn}" "${AWS_WAF_WEB_ACL_ARN}" "${zone_arn}" \
            --approval-mode IMMEDIATE --client-token "${token}" --output json) \
            || die "创建 CloudFront Free 固定套餐失败"
        AWS_CLOUDFRONT_PRICING_PLAN_ARN=$(jq -r \
            '.subscription.arn // .arn // empty' <<<"${response}")
        [[ -n "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}" ]] \
            || die "PricingPlanManager 未返回订阅 ARN"
        success "已创建 CloudFront Free 固定套餐，并加入 Route 53 Hosted Zone"
    else
        AWS_CLOUDFRONT_PRICING_PLAN_ARN=$(jq -r '.[0].arn' <<<"${matches}")
        tier=$(jq -r '.[0].planTier // empty' <<<"${matches}")
        [[ "${tier}" == "${AWS_CLOUDFRONT_PLAN_TIER}" ]] \
            || die "当前 CloudFront 分配已使用 ${tier:-未知} 固定套餐；为避免计费变化，脚本不会自动改为 FREE"
        info "复用已有 CloudFront Free 固定套餐：${AWS_CLOUDFRONT_PRICING_PLAN_ARN}"
    fi

    wait_for_cloudfront_pricing_plan
    details=$(aws pricing-plan-manager get-subscription --region "${AWS_CONTROL_REGION}" \
        --arn "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}" --output json) \
        || die "读取 CloudFront Free 固定套餐详情失败"
    resources=$(jq -c '.subscription.resourceArns // .resourceArns // []' <<<"${details}")
    actual_waf=$(jq -r '[.[] | select(startswith("arn:aws:wafv2:"))] | first // empty' \
        <<<"${resources}")
    [[ "${actual_waf}" == "${AWS_WAF_WEB_ACL_ARN}" ]] \
        || die "CloudFront Free 固定套餐关联的 WAF 与当前分配不一致"

    if ! jq -e --arg zone "${zone_arn}" 'any(.[]; . == $zone)' <<<"${resources}" >/dev/null; then
        etag=$(jq -r '.eTag // empty' <<<"${details}")
        [[ -n "${etag}" ]] || die "PricingPlanManager 未返回关联 Route 53 所需 ETag"
        token="easyall-zone-$(printf '%s' "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}:${zone_arn}" \
            | sha256sum | cut -c1-32)"
        aws pricing-plan-manager associate-resources-to-subscription \
            --region "${AWS_CONTROL_REGION}" --arn "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}" \
            --if-match "${etag}" --resource-arns "${zone_arn}" --client-token "${token}" \
            --output json >/dev/null || die "将 Route 53 Hosted Zone 加入 CloudFront Free 固定套餐失败"
        wait_for_cloudfront_pricing_plan
        success "Route 53 Hosted Zone 已由 CloudFront Free 固定套餐覆盖标准费用"
    else
        info "Route 53 Hosted Zone 已在 CloudFront Free 固定套餐中"
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
    ensure_aws_paid_account_plan
    ensure_cloudfront_web_acl
    configure_cloudfront_distribution
    ensure_viewer_alias_records
    wait_for_cloudfront
    ensure_cloudfront_free_pricing_plan
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
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --argjson h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '{
        noGRPCHeader:false,
        uplinkMethod:"POST",
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
    jq -nr --arg xhttp_name "${XHTTP_NODE_NAME}" \
        --arg server "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg xhttp_path "${XHTTP_PATH}" \
        --arg max_concurrency "${XHTTP_XMUX_MAX_CONCURRENCY}" \
        --arg c_max_reuse_times "${XHTTP_XMUX_C_MAX_REUSE_TIMES}" \
        --arg h_max_reusable_secs "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}" \
        --arg h_keep_alive_period "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}" '
        "  - name: \($xhttp_name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($server|@json)\n    client-fingerprint: chrome\n" +
        "    ip-version: ipv4\n    packet-encoding: xudp\n    alpn:\n      - h2\n    xhttp-opts:\n" +
        "      host: \($server|@json)\n      path: \($xhttp_path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n" +
        "        max-concurrency: \($max_concurrency|@json)\n        c-max-reuse-times: \($c_max_reuse_times)\n" +
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
    local template node_file base64_file mihomo_file user uuid user_dir
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"

    fetch_mihomo_template "${template}"
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
    show_quota_status
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

quota_rebuild_runtime() {
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

update_subscription() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    info "update-sub 只更新本机 Xray、订阅与 Nginx，并复用现有 CloudFront；不会修改 AWS 资源"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    if subscription_enabled; then
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
        write_subscriptions
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
        remove_subscriptions
    fi
    save_state
    refresh_runtime
    install_quota_timer
    end_quota_maintenance
    subscription_enabled && validate_subscription_runtime
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Nginx 订阅已刷新"
}

finish_xhttp_apply() {
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
    install_quota_timer
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
}

apply_easy_all() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    finish_xhttp_apply
    success "easy_all CDN XHTTP 本机配置与订阅已应用；未修改 AWS 资源"
}

apply_cloud_resources() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    cdn_prepare_origin
    cdn_apply
    finish_xhttp_apply
    success "easy_all CDN XHTTP 本机配置、Route 53、WAF、CloudFront 与 Free 固定套餐已应用"
}

update_current_core() {
    local backup_bin="${RUNTIME_TMP}/xray-backup"
    require_root
    begin_quota_maintenance
    collect_installed_state
    install -m 0755 "${XRAY_BIN}" "${backup_bin}"
    if download_xray && systemctl restart "${XRAY_SERVICE}" && validate_protocol_runtime; then
        end_quota_maintenance
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
    remove_quota_timer
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
        read -r -p "确认删除 easy_all XHTTP 本机服务、状态和证书？远端 AWS 资源会保留。[y/N]（直接回车取消）: " answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_services
    remove_quota_timer
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    remove_managed_acme_domain "${AWS_ORIGIN_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    success "easy_all XHTTP 本机内容已卸载；CloudFront、WAF、Free 固定套餐、ACM 与 Route 53 记录未删除"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="aws"
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
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
    info "[7/9] 配置 ACM、确认 AWS Paid plan、WAF、CloudFront Free 固定套餐与 Route 53 CDN Alias"
    cdn_apply
    info "[8/9] 保存状态并注册命令"
    save_state
    register_easy_all_command
    install_quota_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    info "[9/9] 输出节点与订阅"
    show_subscription
    success "easy_all CDN XHTTP 安装完成"
}

usage() {
    cat <<EOF
用法: ${ENTRY_COMMAND_NAME} [命令]

  install          安装 VLESS XHTTP TLS + Route 53 + CloudFront
  self-update      只更新 easy_all 项目代码，不刷新部署
  apply            按当前状态应用本机运行时与订阅，不修改 AWS
  apply-cloud      应用本机并同步 Route 53、ACM 与 CloudFront
  update-sub       更新订阅选择、配额与本机运行时
  show             显示 VLESS 链接与 Mihomo 节点
  subscription     显示节点与订阅状态
  status           显示本机状态与已保存的 AWS 资源 ID
  update-core      更新 Xray，失败时恢复旧版本
  renew-cert       强制续期源站 Let's Encrypt 证书
  quota-status     显示每个用户的本月流量与配额状态
  quota-set        修改指定用户的月度额度
  quota-reset      清零指定用户的本月已用量
  uninstall        删除本机内容，保留远端 AWS 资源

发布单个 VLESS XHTTP stream-up/H2 节点。节点 DNS 全部由 Route 53 管理；
CloudFront 使用 HTTPS 回源、禁用缓存、启用 gRPC，并转发除 Host 外的全部查看器请求头。
可选择部署 CloudFront + Nginx Token 订阅，或仅输出节点信息。
EOF
}

main() {
    case "${1:-install}" in
    install) install_all ;;
    apply) apply_easy_all ;;
    apply-cloud) apply_cloud_resources ;;
    update-sub) update_subscription ;;
    show) require_root; show_node ;;
    subscription) require_root; show_subscription ;;
    status) show_status ;;
    update-core) update_current_core ;;
    renew-cert) renew_certificate ;;
    quota-sync) quota_sync_usage ;;
    quota-status) require_root; collect_installed_state; show_quota_status ;;
    quota-set) shift; quota_set_user "$@" ;;
    quota-reset) shift; quota_reset_user "$@" ;;
    register-command) register_easy_all_command ;;
    uninstall) uninstall_all ;;
    help | -h | --help) usage ;;
    *) usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
