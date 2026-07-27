#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly STATE_DIR="/etc/easy_anytls"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly WORKER_FILE="${STATE_DIR}/subscribe-worker.js"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_FILE="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_anytls"
readonly COMMAND_PATH="/usr/local/bin/easy_anytls"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-sing-box.sh"
readonly SING_BOX_BIN="/usr/local/bin/sing-box"
readonly SING_BOX_CONFIG_DIR="/etc/sing-box"
readonly SING_BOX_CONFIG="${SING_BOX_CONFIG_DIR}/config.json"
readonly SING_BOX_SERVICE_FILE="/etc/systemd/system/sing-box.service"
readonly SING_BOX_SERVICE="sing-box.service"
readonly ACME_HOME="/root/.acme.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy-anytls"
readonly SING_BOX_START_DIAGNOSTICS="${STATE_DIR}/last-start-diagnostics.log"
readonly NFT_CONFIG="/etc/nftables.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-bbrv3.conf"
readonly IPV6_SYSCTL_CONF="/etc/sysctl.d/99-enable-ipv6.conf"
readonly OLD_DISABLE_IPV6_CONF="/etc/sysctl.d/99-disable-ipv6.conf"
readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_REPO="/etc/apt/sources.list.d/xanmod-release.list"
readonly ANYTLS_PORT="443"
readonly PORT_BASE="10000"
readonly PORT_MULTIPLIER="6"
readonly DEFAULT_SUB_PORT_MODE="dynamic"
readonly DEFAULT_NODE_NAME="MY_ANYTLS"
readonly DEFAULT_WORKER_NAME="easy-anytls"
readonly DEFAULT_SUB_DOWNLOAD_NAME="MY_SUB"
readonly DEFAULT_REBOOT_HOUR="4"
readonly LEGACY_CRON_JOB="0 4 * * * /sbin/reboot"
readonly CRON_REBOOT_COMMAND="/usr/bin/flock -n /run/daily-reboot.lock /sbin/reboot"
readonly MIN_SING_BOX_VERSION="1.12.0"
readonly SING_BOX_START_TIMEOUT="20"
readonly GITHUB_RELEASES_API="https://api.github.com/repos/SagerNet/sing-box/releases"

INSTALL_ROLLBACK_ON_EXIT=0
INSTALL_ROLLBACK_AVAILABLE=0
SCHEDULED_REBOOT_ENABLED=1
SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"

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
cleanup() {
    local path
    if [[ "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" \
        && "${INSTALL_ROLLBACK_AVAILABLE:-0}" == "1" ]]; then
        INSTALL_ROLLBACK_ON_EXIT=0
        rollback_install_side_effects
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
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] \
            || return 1
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

tcp_port_is_listening() {
    local port=$1 listeners
    listeners=$(ss -H -ltn "sport = :${port}" 2>/dev/null) || return 1
    [[ -n "${listeners//[[:space:]]/}" ]]
}

wait_for_sing_box_ready() {
    local timeout=${1:-${SING_BOX_START_TIMEOUT}} attempt
    for ((attempt = 1; attempt <= timeout; attempt++)); do
        if systemctl is-active --quiet "${SING_BOX_SERVICE}" 2>/dev/null \
            && tcp_port_is_listening "${ANYTLS_PORT}"; then
            return 0
        fi
        systemctl is-failed --quiet "${SING_BOX_SERVICE}" 2>/dev/null \
            && return 1
        sleep 1
    done
    return 1
}

capture_sing_box_start_diagnostics() {
    local temp="${RUNTIME_TMP}/sing-box-start-diagnostics.log"
    install -d -m 0700 "${STATE_DIR}"
    {
        printf 'easy_anytls sing-box startup diagnostics\n'
        printf 'Captured: %s\n\n' "$(date --iso-8601=seconds 2>/dev/null || date)"
        printf '[systemctl status]\n'
        systemctl status "${SING_BOX_SERVICE}" --no-pager -l 2>&1 || true
        printf '\n[systemctl properties]\n'
        systemctl show "${SING_BOX_SERVICE}" \
            -p ActiveState -p SubState -p Result -p MainPID \
            -p ExecMainCode -p ExecMainStatus 2>&1 || true
        printf '\n[journalctl]\n'
        journalctl -u "${SING_BOX_SERVICE}" -b -n 100 --no-pager \
            2>&1 || true
        printf '\n[TCP %s listeners]\n' "${ANYTLS_PORT}"
        ss -H -ltnp "sport = :${ANYTLS_PORT}" 2>&1 || true
        printf '\n[configuration check]\n'
        "${SING_BOX_BIN}" check -c "${SING_BOX_CONFIG}" 2>&1 || true
    } >"${temp}"
    install -m 0600 "${temp}" "${SING_BOX_START_DIAGNOSTICS}"
    warn "sing-box 启动验收失败；以下诊断已保存在 ${SING_BOX_START_DIAGNOSTICS}"
    sed -n '1,220p' "${temp}" >&2
}

validate_worker_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

normalize_sub_download_name() {
    local name=${1:-}
    name=${name%.[Yy][Aa][Mm][Ll]}
    name=${name%.[Yy][Mm][Ll]}
    printf '%s' "${name:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
}

validate_sub_download_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

validate_subscribe_mode() {
    [[ "$1" == "auto" || "$1" == "worker" || "$1" == "link" ]]
}

validate_sub_port_mode() {
    [[ "$1" == "443" || "$1" == "dynamic" ]]
}

has_dynamic_port_redirect() {
    local pattern
    pattern="tcp[[:space:]]+dport[[:space:]]+${PORT_BASE}-65535[[:space:]]+redirect[[:space:]]+to[[:space:]]+:${ANYTLS_PORT}"
    if [[ -f "${NFT_CONFIG}" ]] && grep -Eq "${pattern}" "${NFT_CONFIG}"; then
        return 0
    fi
    command -v nft >/dev/null 2>&1 \
        && nft list ruleset 2>/dev/null | grep -Eq "${pattern}"
}

write_dynamic_port_redirect_block() {
    cat <<EOF
table inet nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${PORT_BASE}-65535 redirect to :${ANYTLS_PORT}
    }
}

EOF
}

insert_dynamic_port_redirect_block() {
    local source=$1 destination=$2 block_file=$3
    awk -v block_file="${block_file}" '
        function print_block() {
            while ((getline line < block_file) > 0) {
                print line
            }
            close(block_file)
        }
        !inserted && $0 ~ /^[[:space:]]*table[[:space:]]+inet[[:space:]]+filter[[:space:]]*\{/ {
            print_block()
            inserted = 1
        }
        {print}
        END {
            if (!inserted) {
                print_block()
            }
        }
    ' "${source}" >"${destination}"
}

install_dynamic_port_redirect() {
    [[ -f "${NFT_CONFIG}" ]] \
        || die "未找到 ${NFT_CONFIG}，无法自动补充动态端口转发"
    if grep -Eq '^[[:space:]]*table[[:space:]]+inet[[:space:]]+nat[[:space:]]*\{' "${NFT_CONFIG}"; then
        die "检测到 ${NFT_CONFIG} 已存在 table inet nat，但缺少 ${PORT_BASE}-65535 -> ${ANYTLS_PORT}；请手动合并动态端口转发规则后重试"
    fi

    local temp_dir block candidate backup
    temp_dir=$(make_temp_dir)
    block="${temp_dir}/dynamic-port-redirect.nft"
    candidate="${temp_dir}/nftables-with-dynamic-port.conf"
    backup="${BACKUP_DIR}/nftables.dynamic-port.$(date +%Y%m%d%H%M%S).bak"
    write_dynamic_port_redirect_block >"${block}"
    insert_dynamic_port_redirect_block "${NFT_CONFIG}" "${candidate}" "${block}"
    nft -c -f "${candidate}" || die "动态端口转发后的 nftables 配置校验失败"

    install -d -m 0700 "${BACKUP_DIR}"
    cp -a "${NFT_CONFIG}" "${backup}"
    install -m 0644 "${candidate}" "${NFT_CONFIG}"
    if ! systemctl restart nftables; then
        install -m 0644 "${backup}" "${NFT_CONFIG}"
        systemctl restart nftables >/dev/null 2>&1 || true
        die "重启 nftables 失败，已恢复原配置"
    fi
    success "已补充动态端口转发 ${PORT_BASE}-65535 -> ${ANYTLS_PORT}"
}

require_dynamic_port_redirect() {
    [[ "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}" == "dynamic" ]] || return 0
    has_dynamic_port_redirect && return 0
    install_dynamic_port_redirect
    has_dynamic_port_redirect && return 0
    die "当前 nftables 未配置 ${PORT_BASE}-65535 到 ${ANYTLS_PORT} 的动态端口转发；请手动确认防火墙已放行并转发后再使用 SUB_PORT_MODE=dynamic update-sub，或使用 SUB_PORT_MODE=443 继续固定 443"
}

validate_sing_box_selector() {
    local selector=${1#v}
    [[ "${selector}" == "latest" || "${selector}" == "alpha" ]] && return 0
    [[ "${selector}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]
}

version_core() {
    local version=${1#v}
    version=${version%%-*}
    printf '%s' "${version}"
}

version_at_least() {
    local actual required first
    actual=$(version_core "$1")
    required=$(version_core "$2")
    [[ "${actual}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    [[ "${required}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    first=$(printf '%s\n%s\n' "${required}" "${actual}" | sort -V | head -n 1)
    [[ "${first}" == "${required}" ]]
}

prompt_value() {
    local prompt=$1 default_value=$2 value=
    if [[ ! -t 0 ]]; then
        printf '%s' "${default_value}"
        return
    fi
    if [[ -n "${default_value}" ]]; then
        read -r -p "${prompt} [${default_value}]（回车使用默认值）: " value
    else
        read -r -p "${prompt}: " value
    fi
    printf '%s' "${value:-${default_value}}"
}

prompt_secret() {
    local prompt=$1 value=
    [[ -t 0 ]] || return 1
    read -r -s -p "${prompt}: " value
    printf '\n' >&2
    printf '%s' "${value}"
}

generate_secret() {
    openssl rand -base64 32 | tr '+/' '-_' | tr -d '=\n'
}

uri_encode() {
    jq -rn --arg value "$1" '$value | @uri'
}

load_state() {
    local env_domain=${ANYTLS_DOMAIN:-}
    local env_password=${ANYTLS_PASSWORD:-}
    local env_node_name=${NODE_NAME:-}
    local env_selector=${SING_BOX_VERSION:-}
    local env_channel=${SING_BOX_CHANNEL:-}
    local env_installed=${SING_BOX_INSTALLED_VERSION:-}
    local env_sub_token=${SUB_TOKEN:-}
    local env_worker_name=${WORKER_NAME:-}
    local env_worker_url=${WORKER_URL:-}
    local env_account_id=${CF_ACCOUNT_ID:-}
    local env_deploy_mode=${DEPLOY_MODE:-}
    local env_sub_port_mode=${SUB_PORT_MODE:-}
    local env_sub_download_name=${SUB_DOWNLOAD_NAME:-}

    ANYTLS_DOMAIN=""
    ANYTLS_PASSWORD=""
    NODE_NAME=""
    SING_BOX_VERSION=""
    SING_BOX_CHANNEL=""
    SING_BOX_INSTALLED_VERSION=""
    SUB_TOKEN=""
    WORKER_NAME=""
    WORKER_URL=""
    CF_ACCOUNT_ID=""
    DEPLOY_MODE=""
    SUB_PORT_MODE=""
    SUB_DOWNLOAD_NAME=""
    ACME_INSTALLED_BY_EASY_ANYTLS=""

    if [[ -f "${STATE_FILE}" ]]; then
        # The file is generated by save_state with shell-escaped values.
        # shellcheck source=/dev/null
        source "${STATE_FILE}"
    fi
    SAVED_ANYTLS_DOMAIN=${ANYTLS_DOMAIN:-}

    ANYTLS_DOMAIN=${env_domain:-${ANYTLS_DOMAIN}}
    ANYTLS_PASSWORD=${env_password:-${ANYTLS_PASSWORD}}
    NODE_NAME=${env_node_name:-${NODE_NAME:-${DEFAULT_NODE_NAME}}}
    SING_BOX_VERSION=${env_selector:-${SING_BOX_VERSION:-}}
    SING_BOX_CHANNEL=${env_channel:-${SING_BOX_CHANNEL:-latest}}
    SING_BOX_INSTALLED_VERSION=${env_installed:-${SING_BOX_INSTALLED_VERSION}}
    SUB_TOKEN=${env_sub_token:-${SUB_TOKEN}}
    WORKER_NAME=${env_worker_name:-${WORKER_NAME:-${DEFAULT_WORKER_NAME}}}
    WORKER_URL=${env_worker_url:-${WORKER_URL}}
    CF_ACCOUNT_ID=${env_account_id:-${CF_ACCOUNT_ID}}
    DEPLOY_MODE=${env_deploy_mode:-${DEPLOY_MODE:-link}}
    SUB_PORT_MODE=${env_sub_port_mode:-${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}}
    validate_sub_port_mode "${SUB_PORT_MODE}" \
        || die "订阅暴露端口模式无效：${SUB_PORT_MODE}，只能是 443 或 dynamic"
    SUB_DOWNLOAD_NAME=${env_sub_download_name:-${SUB_DOWNLOAD_NAME}}
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    ACME_INSTALLED_BY_EASY_ANYTLS=${ACME_INSTALLED_BY_EASY_ANYTLS:-0}
    [[ ! -f "${ACME_OWNERSHIP_MARKER}" ]] \
        || ACME_INSTALLED_BY_EASY_ANYTLS=1
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX")
    cleanup_files+=("${temp}")
    {
        printf 'ANYTLS_DOMAIN=%q\n' "${ANYTLS_DOMAIN}"
        printf 'ANYTLS_PASSWORD=%q\n' "${ANYTLS_PASSWORD}"
        printf 'NODE_NAME=%q\n' "${NODE_NAME:-${DEFAULT_NODE_NAME}}"
        printf 'SING_BOX_VERSION=%q\n' "${SING_BOX_VERSION:-latest}"
        printf 'SING_BOX_CHANNEL=%q\n' "${SING_BOX_CHANNEL:-latest}"
        printf 'SING_BOX_INSTALLED_VERSION=%q\n' "${SING_BOX_INSTALLED_VERSION:-}"
        printf 'SUB_TOKEN=%q\n' "${SUB_TOKEN:-}"
        printf 'WORKER_NAME=%q\n' "${WORKER_NAME:-${DEFAULT_WORKER_NAME}}"
        printf 'WORKER_URL=%q\n' "${WORKER_URL:-}"
        printf 'CF_ACCOUNT_ID=%q\n' "${CF_ACCOUNT_ID:-}"
        printf 'DEPLOY_MODE=%q\n' "${DEPLOY_MODE:-link}"
        printf 'SUB_PORT_MODE=%q\n' "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
        printf 'ACME_INSTALLED_BY_EASY_ANYTLS=%q\n' \
            "${ACME_INSTALLED_BY_EASY_ANYTLS:-0}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

choose_domain() {
    local domain
    domain=$(prompt_value "AnyTLS 单域名（必须已有 A 记录指向本机）" \
        "${ANYTLS_DOMAIN:-}")
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" \
        || die "域名无效：${domain}；仅支持单个完整域名，不支持 IP 或泛域名"
    if [[ -n "${SAVED_ANYTLS_DOMAIN:-}" \
        && "${domain}" != "${SAVED_ANYTLS_DOMAIN}" ]]; then
        die "已安装域名为 ${SAVED_ANYTLS_DOMAIN}；为避免遗留证书续期和订阅，请先卸载后再更换域名"
    fi
    ANYTLS_DOMAIN="${domain}"
}

choose_sing_box_version() {
    local choice=${SING_BOX_VERSION:-}
    if [[ -z "${choice}" && -t 0 ]]; then
        printf '请选择 sing-box 版本：\n'
        printf '  1. 最新稳定版 release（默认）\n'
        printf '  2. 最新 alpha/pre-release\n'
        printf '  3. 指定具体版本号\n'
        read -r -p "请选择 [1]（回车默认 1）: " choice
        choice=${choice:-1}
        if [[ "${choice}" == "3" ]]; then
            read -r -p "请输入版本号（例如 1.13.12 或 v1.14.0-alpha.26）: " choice
        fi
    fi
    choice=${choice:-latest}
    case "${choice}" in
    1 | latest | stable) choice="latest" ;;
    2 | alpha | prerelease) choice="alpha" ;;
    esac
    validate_sing_box_selector "${choice}" \
        || die "sing-box 版本选择无效：${choice}"
    SING_BOX_VERSION="${choice}"
    if [[ "${choice}" == "alpha" ]]; then
        warn "已选择最新 alpha/pre-release，可能包含未稳定的行为"
    fi
}

choose_subscription_mode() {
    local choice=${SUBSCRIBE_MODE:-}
    if [[ -z "${choice}" && -t 0 ]]; then
        printf '请选择订阅输出方式：\n'
        printf '  1. 自动部署 Cloudflare Worker（默认）\n'
        printf '  2. 输出 Worker 内容，手动部署\n'
        printf '  3. 只输出 AnyTLS 配置和纯链接\n'
        read -r -p "请选择 [1]（回车默认 1）: " choice
        choice=${choice:-1}
    fi
    choice=${choice:-auto}
    case "${choice}" in
    1 | auto) SUBSCRIBE_MODE="auto" ;;
    2 | worker | manual) SUBSCRIBE_MODE="worker" ;;
    3 | link | anytls) SUBSCRIBE_MODE="link" ;;
    *) die "订阅输出方式无效：${choice}" ;;
    esac
}

choose_subscription_port_mode() {
    local mode=${SUB_PORT_MODE:-}
    if [[ -z "${mode}" && -t 0 ]]; then
        printf '请选择订阅暴露端口模式：\n'
        printf '  1. dynamic：10000-65535 动态端口转发到 443（默认）\n'
        printf '  2. 443：固定使用 443\n'
        read -r -p "请选择 [1]（回车默认 dynamic）: " mode
        mode=${mode:-1}
    fi
    mode=${mode:-${DEFAULT_SUB_PORT_MODE}}
    case "${mode}" in
    1 | dynamic) SUB_PORT_MODE="dynamic" ;;
    2 | 443) SUB_PORT_MODE="443" ;;
    *) die "订阅暴露端口模式无效：${mode}，只能是 443 或 dynamic" ;;
    esac
}

choose_subscription_download_name() {
    local name
    name=$(prompt_value "Mihomo 下载基础名称（不含 .yaml）" \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    name=$(normalize_sub_download_name "${name}")
    validate_sub_download_name "${name}" \
        || die "下载基础名称无效：${name}"
    SUB_DOWNLOAD_NAME="${name}"
}

detect_public_ipv4() {
    local endpoint ip
    local -a detected=()
    for endpoint in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.co/ip; do
        ip=$(curl -fsS4 --max-time 8 "${endpoint}" 2>/dev/null \
            | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            detected+=("${ip}")
        fi
    done
    ((${#detected[@]} >= 2)) \
        || die "无法通过至少两个公网服务确认本机公网 IPv4"
    ip=$(printf '%s\n' "${detected[@]}" | sort | uniq -c \
        | sort -rn | awk 'NR == 1 {print $2}')
    local count
    count=$(printf '%s\n' "${detected[@]}" | awk -v target="${ip}" \
        '$0 == target {count++} END {print count+0}')
    ((count >= 2)) || die "公网 IPv4 探测结果不一致：${detected[*]}"
    printf '%s' "${ip}"
}

query_a_records() {
    local domain=$1 resolver=${2:-}
    local -a args=(+time=5 +tries=2 +short A "${domain}")
    [[ -z "${resolver}" ]] || args+=("@${resolver}")
    dig "${args[@]}" 2>/dev/null \
        | awk '/^([0-9]{1,3}\.){3}[0-9]{1,3}$/ {print}' \
        | sort -u
}

validate_resolved_ipv4_set() {
    local expected=$1 records=$2 record count=0
    while IFS= read -r record; do
        [[ -n "${record}" ]] || continue
        validate_ipv4 "${record}" || return 1
        [[ "${record}" == "${expected}" ]] || return 1
        count=$((count + 1))
    done <<<"${records}"
    ((count >= 1))
}

verify_domain_dns() {
    local domain=$1 public_ip=$2 resolver records
    local -a resolvers=("" "1.1.1.1" "8.8.8.8")
    for resolver in "${resolvers[@]}"; do
        records=$(query_a_records "${domain}" "${resolver}")
        if ! validate_resolved_ipv4_set "${public_ip}" "${records}"; then
            [[ -n "${resolver}" ]] || resolver="系统解析器"
            die "DNS A 记录校验失败：${domain} 经 ${resolver} 解析为 [${records:-无 A 记录}]，本机公网 IPv4 为 ${public_ip}。请关闭 Cloudflare 代理并等待 DNS 生效后重试"
        fi
    done
    success "DNS 校验通过：${domain} -> ${public_ip}"
}

bootstrap_dns_dependencies() {
    command -v curl >/dev/null 2>&1 \
        || die "缺少 curl；请先安装 curl 后运行脚本"
    if ! command -v dig >/dev/null 2>&1; then
        info "首次 DNS 校验需要 dig，正在安装 dnsutils"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y dnsutils ca-certificates
    fi
}

preflight_debian() {
    local major_version
    require_root
    require_systemd
    [[ -r /etc/os-release ]] || die "无法识别操作系统"
    # shellcheck source=/dev/null
    source /etc/os-release
    [[ "${ID:-}" == "debian" ]] || die "初始化仅支持 Debian"
    [[ -n "${VERSION_CODENAME:-}" ]] || die "无法识别 Debian 发行版代号"
    major_version=${VERSION_ID%%.*}
    [[ "${major_version}" =~ ^[0-9]+$ ]] && ((major_version >= 12)) \
        || die "初始化仅支持 Debian 12 及以上版本"
    [[ "$(dpkg --print-architecture)" == "amd64" ]] \
        || die "当前仅支持 Debian amd64"
    ! systemd-detect-virt --container >/dev/null 2>&1 \
        || die "容器不能执行内核与防火墙初始化"
}

check_service_conflicts() {
    [[ -d /etc/easy_reality ]] \
        && die "检测到 easy_reality 状态目录；easy_anytls 默认不与 Reality 共用专用 VPS"
    if systemctl is-active --quiet xray.service 2>/dev/null; then
        die "检测到运行中的 xray.service，可能占用 443 端口"
    fi
    if [[ ! -f "${STATE_FILE}" \
        && ( -f "${SING_BOX_BIN}" || -f "${SING_BOX_CONFIG}" \
            || -f "${SING_BOX_SERVICE_FILE}" ) ]]; then
        die "检测到非 easy_anytls 管理的 sing-box 二进制、配置或 systemd 服务，拒绝覆盖"
    fi
    if [[ ! -f "${STATE_FILE}" ]] \
        && tcp_port_is_listening "${ANYTLS_PORT}"; then
        die "TCP ${ANYTLS_PORT} 已被其他服务占用"
    fi
}

install_base_packages() {
    info "[1/8] 更新系统并安装基础依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        vim curl wget nftables cron ca-certificates gnupg \
        iproute2 iputils-ping tzdata systemd-timesyncd \
        jq openssl dnsutils tar
    timedatectl set-timezone Asia/Shanghai
    timedatectl set-ntp true || die "无法启用网络时间同步"
    success "当前时间：$(date)"
}

install_xanmod_bbr() {
    local temp_dir key_file keyring_file repo_file
    temp_dir=$(make_temp_dir)
    key_file="${temp_dir}/archive.key"
    keyring_file="${temp_dir}/archive.gpg"
    repo_file="${temp_dir}/xanmod.list"

    info "[2/8] 安装 XanMod LTS 并配置 BBR"
    install -d -m 0755 /etc/apt/keyrings
    wget -qO "${key_file}" https://dl.xanmod.org/archive.key \
        || die "下载 XanMod 签名密钥失败"
    gpg --batch --yes --dearmor --output "${keyring_file}" "${key_file}" \
        || die "转换 XanMod 签名密钥失败"
    install -m 0644 "${keyring_file}" "${XANMOD_KEYRING}"
    printf 'deb [signed-by=%s] http://deb.xanmod.org %s main\n' \
        "${XANMOD_KEYRING}" "${VERSION_CODENAME}" >"${repo_file}"
    install -m 0644 "${repo_file}" "${XANMOD_REPO}"
    apt-get update
    apt-get install -y linux-xanmod-lts-x64v1

    local sysctl_file="${temp_dir}/sysctl.conf"
    cat >"${sysctl_file}" <<'EOF'
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
    install -m 0644 "${sysctl_file}" "${SYSCTL_CONFIG}"
    modprobe tcp_bbr 2>/dev/null || true
    sysctl -p "${SYSCTL_CONFIG}" >/dev/null
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
        || die "拥塞控制算法未成功设置为 bbr"
}

append_ssh_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    ((10#${port} >= 1 && 10#${port} <= 65535)) || return 0
    case ", ${SSH_PORTS}, " in
    *", ${port}, "*) ;;
    *)
        [[ -z "${SSH_PORTS}" ]] || SSH_PORTS+=", "
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
}

configure_nftables() {
    local temp_dir candidate backup=""
    temp_dir=$(make_temp_dir)
    candidate="${temp_dir}/nftables.conf"
    detect_ssh_ports
    info "[5/8] 配置 nftables（SSH + TCP ${ANYTLS_PORT}）"
    cat >"${candidate}" <<EOF
#!/usr/sbin/nft -f
flush ruleset

EOF
    if [[ "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}" == "dynamic" ]]; then
        cat >>"${candidate}" <<EOF
table inet nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${PORT_BASE}-65535 redirect to :${ANYTLS_PORT}
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
        meta l4proto { icmp, icmpv6 } accept
        tcp dport { ${SSH_PORTS}, ${ANYTLS_PORT} } accept
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
    if [[ -f "${NFT_CONFIG}" ]]; then
        backup="${BACKUP_DIR}/nftables.conf.$(date +%Y%m%d%H%M%S).bak"
        install -d -m 0700 "${BACKUP_DIR}"
        cp -a "${NFT_CONFIG}" "${backup}"
    fi
    install -m 0644 "${candidate}" "${NFT_CONFIG}"
    systemctl enable nftables >/dev/null
    if ! systemctl restart nftables; then
        [[ -z "${backup}" ]] || install -m 0644 "${backup}" "${NFT_CONFIG}"
        systemctl restart nftables >/dev/null 2>&1 || true
        die "nftables 启动失败，已尝试恢复原配置"
    fi
    systemctl is-active --quiet nftables || die "nftables 未运行"
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job
    info "[3/8] 配置定时重启策略"
    if [[ -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            printf '请选择定时重启策略：\n'
            printf '  1. 每天凌晨 4 点重启（默认）\n'
            printf '  2. 自定义每天几点重启（0-23）\n'
            printf '  3. 不配置定时重启\n'
            read -r -p "请选择 [1]: " mode
            mode=${mode:-1}
        else
            mode=1
        fi
    fi
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
    3 | none | off | disable | disabled) SCHEDULED_REBOOT_ENABLED=0 ;;
    *) die "定时重启选项无效：${mode}" ;;
    esac

    { crontab -l 2>/dev/null || true; } \
        | filter_managed_reboot_cron | crontab -
    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]]; then
        job="0 ${SCHEDULED_REBOOT_HOUR} * * * ${CRON_REBOOT_COMMAND}"
        { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
    fi
}

filter_managed_reboot_cron() {
    awk -v legacy="${LEGACY_CRON_JOB}" -v cmd="${CRON_REBOOT_COMMAND}" '
        $0 == legacy {next}
        index($0, cmd) {next}
        {print}
    '
}

remove_daily_reboot_schedule() {
    { crontab -l 2>/dev/null || true; } \
        | filter_managed_reboot_cron | crontab - \
        || warn "移除 easy_anytls 定时重启任务失败，请手动检查 root crontab"
}

configure_ipv6_compat() {
    local temp_dir ipv6_file
    info "[4/8] 检查 IPv6 兼容状态"
    [[ -d /proc/sys/net/ipv6 ]] || {
        warn "当前内核未暴露 IPv6，继续 IPv4-only 安装"
        return 0
    }
    temp_dir=$(make_temp_dir)
    ipv6_file="${temp_dir}/99-enable-ipv6.conf"
    [[ ! -f "${OLD_DISABLE_IPV6_CONF}" ]] || rm -f -- "${OLD_DISABLE_IPV6_CONF}"
    cat >"${ipv6_file}" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF
    install -m 0644 "${ipv6_file}" "${IPV6_SYSCTL_CONF}"
    sysctl -p "${IPV6_SYSCTL_CONF}" >/dev/null \
        || warn "IPv6 sysctl 应用失败，继续 IPv4-only 安装"
}

snapshot_system_state() {
    local stamp
    stamp=$(date +%Y%m%d%H%M%S)
    install -d -m 0700 "${BACKUP_DIR}"
    INSTALL_NFT_EXISTED=0
    INSTALL_NFT_SNAPSHOT=""
    INSTALL_CRON_SNAPSHOT="${BACKUP_DIR}/install-crontab.${stamp}.bak"
    INSTALL_SYSCTL_SNAPSHOT=""
    INSTALL_SING_BOX_BIN_EXISTED=0
    INSTALL_SING_BOX_CONFIG_EXISTED=0
    INSTALL_SING_BOX_SERVICE_EXISTED=0
    INSTALL_CERT_EXISTED=0
    INSTALL_KEY_EXISTED=0
    INSTALL_RELOAD_HOOK_EXISTED=0
    INSTALL_SING_BOX_WAS_ACTIVE=0
    if [[ -f "${NFT_CONFIG}" ]]; then
        INSTALL_NFT_EXISTED=1
        INSTALL_NFT_SNAPSHOT="${BACKUP_DIR}/install-nftables.conf.${stamp}.bak"
        cp -a "${NFT_CONFIG}" "${INSTALL_NFT_SNAPSHOT}"
    fi
    crontab -l >"${INSTALL_CRON_SNAPSHOT}" 2>/dev/null || :
    if [[ -f "${SYSCTL_CONFIG}" ]]; then
        INSTALL_SYSCTL_SNAPSHOT="${BACKUP_DIR}/install-sysctl-bbrv3.${stamp}.bak"
        cp -a "${SYSCTL_CONFIG}" "${INSTALL_SYSCTL_SNAPSHOT}"
    fi
    if [[ -f "${SING_BOX_BIN}" ]]; then
        INSTALL_SING_BOX_BIN_EXISTED=1
        INSTALL_SING_BOX_BIN_SNAPSHOT="${BACKUP_DIR}/install-sing-box.${stamp}.bak"
        cp -a "${SING_BOX_BIN}" "${INSTALL_SING_BOX_BIN_SNAPSHOT}"
    fi
    if [[ -f "${SING_BOX_CONFIG}" ]]; then
        INSTALL_SING_BOX_CONFIG_EXISTED=1
        INSTALL_SING_BOX_CONFIG_SNAPSHOT="${BACKUP_DIR}/install-sing-box-config.${stamp}.bak"
        cp -a "${SING_BOX_CONFIG}" "${INSTALL_SING_BOX_CONFIG_SNAPSHOT}"
    fi
    if [[ -f "${SING_BOX_SERVICE_FILE}" ]]; then
        INSTALL_SING_BOX_SERVICE_EXISTED=1
        INSTALL_SING_BOX_SERVICE_SNAPSHOT="${BACKUP_DIR}/install-sing-box-service.${stamp}.bak"
        cp -a "${SING_BOX_SERVICE_FILE}" "${INSTALL_SING_BOX_SERVICE_SNAPSHOT}"
    fi
    if [[ -f "${CERT_FILE}" ]]; then
        INSTALL_CERT_EXISTED=1
        INSTALL_CERT_SNAPSHOT="${BACKUP_DIR}/install-fullchain.${stamp}.bak"
        cp -a "${CERT_FILE}" "${INSTALL_CERT_SNAPSHOT}"
    fi
    if [[ -f "${KEY_FILE}" ]]; then
        INSTALL_KEY_EXISTED=1
        INSTALL_KEY_SNAPSHOT="${BACKUP_DIR}/install-private-key.${stamp}.bak"
        cp -a "${KEY_FILE}" "${INSTALL_KEY_SNAPSHOT}"
    fi
    if [[ -f "${CERT_RELOAD_HOOK}" ]]; then
        INSTALL_RELOAD_HOOK_EXISTED=1
        INSTALL_RELOAD_HOOK_SNAPSHOT="${BACKUP_DIR}/install-reload-hook.${stamp}.bak"
        cp -a "${CERT_RELOAD_HOOK}" "${INSTALL_RELOAD_HOOK_SNAPSHOT}"
    fi
    if systemctl is-active --quiet "${SING_BOX_SERVICE}" 2>/dev/null; then
        INSTALL_SING_BOX_WAS_ACTIVE=1
    fi
    INSTALL_ROLLBACK_AVAILABLE=1
}

rollback_install_side_effects() {
    warn "安装未完成，正在恢复安装前的系统配置、sing-box 与生产证书"
    if [[ "${INSTALL_NFT_EXISTED:-0}" == "1" \
        && -n "${INSTALL_NFT_SNAPSHOT:-}" ]]; then
        install -m 0644 "${INSTALL_NFT_SNAPSHOT}" "${NFT_CONFIG}"
        systemctl restart nftables >/dev/null 2>&1 || true
    elif [[ "${INSTALL_NFT_EXISTED:-0}" == "0" ]]; then
        rm -f -- "${NFT_CONFIG}"
        systemctl disable --now nftables >/dev/null 2>&1 || true
    fi
    if [[ -n "${INSTALL_CRON_SNAPSHOT:-}" \
        && -f "${INSTALL_CRON_SNAPSHOT}" ]]; then
        crontab "${INSTALL_CRON_SNAPSHOT}" 2>/dev/null \
            || crontab -r 2>/dev/null || true
    fi
    if [[ -n "${INSTALL_SYSCTL_SNAPSHOT:-}" \
        && -f "${INSTALL_SYSCTL_SNAPSHOT}" ]]; then
        install -m 0644 "${INSTALL_SYSCTL_SNAPSHOT}" "${SYSCTL_CONFIG}"
        sysctl -p "${SYSCTL_CONFIG}" >/dev/null 2>&1 || true
    fi
    if [[ "${INSTALL_SING_BOX_BIN_EXISTED:-0}" == "1" ]]; then
        install -m 0755 "${INSTALL_SING_BOX_BIN_SNAPSHOT}" "${SING_BOX_BIN}"
    else
        rm -f -- "${SING_BOX_BIN}"
    fi
    if [[ "${INSTALL_SING_BOX_CONFIG_EXISTED:-0}" == "1" ]]; then
        install -d -m 0755 "${SING_BOX_CONFIG_DIR}"
        install -m 0600 "${INSTALL_SING_BOX_CONFIG_SNAPSHOT}" "${SING_BOX_CONFIG}"
    else
        rm -f -- "${SING_BOX_CONFIG}"
    fi
    if [[ "${INSTALL_SING_BOX_SERVICE_EXISTED:-0}" == "1" ]]; then
        install -m 0644 "${INSTALL_SING_BOX_SERVICE_SNAPSHOT}" \
            "${SING_BOX_SERVICE_FILE}"
    else
        rm -f -- "${SING_BOX_SERVICE_FILE}"
    fi
    if [[ "${INSTALL_CERT_EXISTED:-0}" == "1" ]]; then
        install -d -m 0700 "${CERT_DIR}"
        install -m 0600 "${INSTALL_CERT_SNAPSHOT}" "${CERT_FILE}"
    else
        rm -f -- "${CERT_FILE}"
    fi
    if [[ "${INSTALL_KEY_EXISTED:-0}" == "1" ]]; then
        install -d -m 0700 "${CERT_DIR}"
        install -m 0600 "${INSTALL_KEY_SNAPSHOT}" "${KEY_FILE}"
    else
        rm -f -- "${KEY_FILE}"
    fi
    if [[ "${INSTALL_RELOAD_HOOK_EXISTED:-0}" == "1" ]]; then
        install -d -m 0755 "${COMMAND_INSTALL_DIR}"
        install -m 0755 "${INSTALL_RELOAD_HOOK_SNAPSHOT}" "${CERT_RELOAD_HOOK}"
    else
        rm -f -- "${CERT_RELOAD_HOOK}"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    if [[ "${INSTALL_SING_BOX_WAS_ACTIVE:-0}" == "1" ]]; then
        systemctl restart "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true
    else
        systemctl disable --now "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true
    fi
}

run_server_initialization() {
    preflight_debian
    check_service_conflicts
    install_base_packages
    snapshot_system_state
    install_xanmod_bbr
    configure_daily_reboot
    configure_ipv6_compat
    configure_nftables
}

resolve_sing_box_release() {
    local selector=$1 response tag version asset_name
    local api_url
    case "${selector}" in
    latest)
        api_url="${GITHUB_RELEASES_API}/latest"
        SING_BOX_CHANNEL="latest"
        ;;
    alpha)
        api_url="${GITHUB_RELEASES_API}?per_page=100"
        SING_BOX_CHANNEL="alpha"
        ;;
    *)
        tag=${selector#v}
        api_url="${GITHUB_RELEASES_API}/tags/v${tag}"
        SING_BOX_CHANNEL="pinned"
        ;;
    esac
    response=$(curl -fsSL --retry 3 \
        -H "Accept: application/vnd.github+json" "${api_url}") \
        || die "获取 sing-box release 信息失败"
    if [[ "${selector}" == "alpha" ]]; then
        response=$(jq -ec '
            [
              .[]
              | select(.draft == false and .prerelease == true)
              | select(.tag_name | test("-alpha\\.[0-9]+$"))
            ][0] // empty
        ' <<<"${response}") || die "未找到 sing-box alpha release"
    fi
    tag=$(jq -er '.tag_name' <<<"${response}") \
        || die "sing-box release 缺少 tag_name"
    version=${tag#v}
    version_at_least "${version}" "${MIN_SING_BOX_VERSION}" \
        || die "sing-box ${version} 低于 AnyTLS 最低版本 ${MIN_SING_BOX_VERSION}"
    asset_name="sing-box-${version}-linux-amd64.tar.gz"
    SING_BOX_RELEASE_TAG="${tag}"
    SING_BOX_RELEASE_VERSION="${version}"
    SING_BOX_ASSET_NAME="${asset_name}"
    SING_BOX_ASSET_URL=$(jq -er --arg name "${asset_name}" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        <<<"${response}") || die "release 中未找到 ${asset_name}"
    SING_BOX_ASSET_DIGEST=$(jq -er --arg name "${asset_name}" '
        .assets[]
        | select(.name == $name)
        | .digest // empty
    ' <<<"${response}") || die "release 未提供 ${asset_name} 的 SHA-256 digest"
    [[ "${SING_BOX_ASSET_DIGEST}" =~ ^sha256:[a-fA-F0-9]{64}$ ]] \
        || die "sing-box release digest 格式无效"
}

download_sing_box_binary() {
    local selector=$1 destination=$2 temp_dir archive expected actual extracted
    resolve_sing_box_release "${selector}"
    temp_dir=$(make_temp_dir)
    archive="${temp_dir}/${SING_BOX_ASSET_NAME}"
    info "下载 sing-box ${SING_BOX_RELEASE_VERSION}（${SING_BOX_CHANNEL}）"
    curl -fL --retry 3 "${SING_BOX_ASSET_URL}" -o "${archive}" \
        || die "下载 sing-box 失败"
    expected=${SING_BOX_ASSET_DIGEST#sha256:}
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    actual=$(tr '[:upper:]' '[:lower:]' <<<"${actual}" | tr -d '\n')
    expected=$(tr '[:upper:]' '[:lower:]' <<<"${expected}" | tr -d '\n')
    [[ "${actual}" == "${expected}" ]] \
        || die "sing-box SHA-256 校验失败"
    tar -xzf "${archive}" -C "${temp_dir}" \
        || die "解压 sing-box 失败"
    extracted="${temp_dir}/sing-box-${SING_BOX_RELEASE_VERSION}-linux-amd64/sing-box"
    [[ -x "${extracted}" ]] || die "sing-box release 包内未找到可执行文件"
    install -m 0755 "${extracted}" "${destination}"
}

install_sing_box_binary() {
    local temp_bin="${RUNTIME_TMP}/sing-box.new"
    info "[6/8] 解析、校验并安装 sing-box"
    download_sing_box_binary "${SING_BOX_VERSION}" "${temp_bin}"
    "${temp_bin}" version | grep -Fq "${SING_BOX_RELEASE_VERSION}" \
        || die "sing-box 二进制版本验收失败"
    install -m 0755 "${temp_bin}" "${SING_BOX_BIN}"
    SING_BOX_INSTALLED_VERSION="${SING_BOX_RELEASE_VERSION}"
}

install_acme() {
    local installer
    if [[ -x "${ACME_BIN}" ]]; then
        ACME_INSTALLED_BY_EASY_ANYTLS=${ACME_INSTALLED_BY_EASY_ANYTLS:-0}
        if [[ "${ACME_INSTALLED_BY_EASY_ANYTLS}" == "1" ]]; then
            install -d -m 0700 "${STATE_DIR}"
            install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
        fi
        ensure_acme_cron
        return 0
    fi
    installer="${RUNTIME_TMP}/get-acme.sh"
    curl -fsSL --retry 3 https://get.acme.sh -o "${installer}" \
        || die "下载 acme.sh 安装器失败"
    sh "${installer}" \
        || die "安装 acme.sh 失败"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装后未找到 ${ACME_BIN}"
    ACME_INSTALLED_BY_EASY_ANYTLS=1
    install -d -m 0700 "${STATE_DIR}"
    install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
    ensure_acme_cron
}

ensure_acme_cron() {
    local job
    crontab -l 2>/dev/null | grep -Fq "${ACME_BIN}" && return 0
    job="17 2 * * * \"${ACME_BIN}\" --cron --home \"${ACME_HOME}\" > /dev/null"
    { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
}

collect_cloudflare_dns_credentials() {
    local token=${CF_DNS_API_TOKEN:-}
    if [[ -z "${token}" ]]; then
        token=$(prompt_secret "Cloudflare DNS API Token（输入不回显）") \
            || die "非交互模式必须设置 CF_DNS_API_TOKEN"
    fi
    [[ -n "${token}" ]] || die "CF_DNS_API_TOKEN 不能为空"
    CF_DNS_TOKEN_VALUE="${token}"
}

acme_issue_status_is_usable() {
    local status=$1
    [[ "${status}" == "0" || "${status}" == "2" ]]
}

validate_certificate() {
    local domain=$1
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] \
        || die "证书或私钥文件为空"
    openssl x509 -in "${CERT_FILE}" -noout -checkend 86400 \
        || die "证书有效期不足 24 小时"
    openssl x509 -in "${CERT_FILE}" -noout -checkhost "${domain}" \
        >/dev/null || die "证书不覆盖域名 ${domain}"
    local cert_key pub_key
    cert_key=$(openssl x509 -in "${CERT_FILE}" -pubkey -noout \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum \
        | awk '{print $1}')
    pub_key=$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null \
        | sha256sum | awk '{print $1}')
    [[ -n "${cert_key}" && "${cert_key}" == "${pub_key}" ]] \
        || die "证书与私钥不匹配"
}

issue_certificate() {
    local domain=$1 issue_status=0
    info "[7/8] 使用 Let's Encrypt + Cloudflare DNS 签发单域名证书"
    install_acme
    collect_cloudflare_dns_credentials
    unset CF_Zone_ID CF_Account_ID || true
    export CF_Token="${CF_DNS_TOKEN_VALUE}"
    "${ACME_BIN}" --set-default-ca --server letsencrypt
    "${ACME_BIN}" --issue --server letsencrypt --dns dns_cf \
        -d "${domain}" --keylength ec-256 || issue_status=$?
    if ! acme_issue_status_is_usable "${issue_status}"; then
        die "Let's Encrypt 证书申请失败（acme.sh 返回码 ${issue_status}）"
    fi
    if [[ "${issue_status}" == "2" ]]; then
        info "现有证书尚未到续期时间，继续安装 acme.sh 中的有效证书"
    fi
    install_certificate_reload_hook
    install -d -m 0700 "${CERT_DIR}"
    touch "${CERT_FILE}" "${KEY_FILE}"
    chmod 0600 "${CERT_FILE}" "${KEY_FILE}"
    "${ACME_BIN}" --install-cert -d "${domain}" --ecc \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${CERT_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}" \
        || die "安装证书到 easy_anytls 目录失败"
    unset CF_Token CF_DNS_API_TOKEN
    CF_DNS_TOKEN_VALUE=""
    validate_certificate "${domain}"
    crontab -l 2>/dev/null | grep -Fq "${ACME_BIN}" \
        || die "未检测到 acme.sh 自动续期 cron"
}

ensure_anytls_password() {
    ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(generate_secret)}
    [[ ${#ANYTLS_PASSWORD} -ge 16 && ${#ANYTLS_PASSWORD} -le 256 ]] \
        || die "ANYTLS_PASSWORD 长度必须为 16-256 个字符"
}

install_certificate_reload_hook() {
    install -d -m 0755 "${COMMAND_INSTALL_DIR}"
    cat >"${RUNTIME_TMP}/reload-sing-box.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
if ! /usr/bin/systemctl is-active --quiet ${SING_BOX_SERVICE}; then
    exit 0
fi
/usr/bin/systemctl restart ${SING_BOX_SERVICE}
for ((attempt = 1; attempt <= ${SING_BOX_START_TIMEOUT}; attempt++)); do
    if /usr/bin/systemctl is-active --quiet ${SING_BOX_SERVICE} \
        && [[ -n "\$(/usr/bin/ss -H -ltn 'sport = :${ANYTLS_PORT}' 2>/dev/null)" ]]; then
        exit 0
    fi
    /usr/bin/systemctl is-failed --quiet ${SING_BOX_SERVICE} && break
    sleep 1
done
/usr/bin/systemctl status ${SING_BOX_SERVICE} --no-pager -l >&2 || true
/usr/bin/journalctl -u ${SING_BOX_SERVICE} -b -n 100 --no-pager >&2 || true
exit 1
EOF
    install -m 0755 "${RUNTIME_TMP}/reload-sing-box.sh" "${CERT_RELOAD_HOOK}"
}

write_sing_box_config() {
    local candidate backup="" listen_addr
    candidate="${RUNTIME_TMP}/sing-box-config.json"
    if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        listen_addr="::"
    else
        listen_addr="0.0.0.0"
    fi
    jq -n \
        --arg listen "${listen_addr}" \
        --arg domain "${ANYTLS_DOMAIN}" \
        --arg password "${ANYTLS_PASSWORD}" \
        --arg cert "${CERT_FILE}" \
        --arg key "${KEY_FILE}" \
        --argjson port "${ANYTLS_PORT}" '
        {
          log: {
            level: "warn",
            timestamp: true
          },
          dns: {
            servers: [
              {
                type: "local",
                tag: "local"
              }
            ]
          },
          inbounds: [
            {
              type: "anytls",
              tag: "anytls-in",
              listen: $listen,
              listen_port: $port,
              users: [
                {
                  name: "default",
                  password: $password
                }
              ],
              tls: {
                enabled: true,
                server_name: $domain,
                certificate_path: $cert,
                key_path: $key
              }
            }
          ],
          outbounds: [
            {
              type: "direct",
              tag: "direct"
            }
          ],
          route: {
            default_domain_resolver: "local",
            rules: [
              {
                domain_suffix: [
                  "claude.ai",
                  "claude.com",
                  "anthropic.com",
                  "claudeusercontent.com",
                  "gemini.google.com",
                  "bard.google.com",
                  "aistudio.google.com",
                  "makersuite.google.com",
                  "ai.google.dev",
                  "generativelanguage.googleapis.com",
                  "deepmind.com",
                  "deepmind.google",
                  "generativeai.google"
                ],
                action: "resolve",
                server: "local",
                strategy: "ipv4_only"
              }
            ],
            final: "direct"
          }
        }
    ' >"${candidate}"
    "${SING_BOX_BIN}" check -c "${candidate}" \
        || die "sing-box AnyTLS 配置校验失败"
    install -d -m 0755 "${SING_BOX_CONFIG_DIR}"
    if [[ -f "${SING_BOX_CONFIG}" ]]; then
        backup="${BACKUP_DIR}/sing-box-config.$(date +%Y%m%d%H%M%S).bak"
        install -d -m 0700 "${BACKUP_DIR}"
        cp -a "${SING_BOX_CONFIG}" "${backup}"
    fi
    install -m 0600 "${candidate}" "${SING_BOX_CONFIG}"
    SING_BOX_CONFIG_BACKUP="${backup}"
}

install_sing_box_service() {
    local previous_service="" failure_reason=""
    if [[ -f "${SING_BOX_SERVICE_FILE}" ]]; then
        previous_service="${BACKUP_DIR}/sing-box.service.$(date +%Y%m%d%H%M%S).bak"
        install -d -m 0700 "${BACKUP_DIR}"
        cp -a "${SING_BOX_SERVICE_FILE}" "${previous_service}"
    fi
    cat >"${RUNTIME_TMP}/sing-box.service" <<EOF
[Unit]
Description=sing-box AnyTLS managed by easy_anytls
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SING_BOX_BIN} run -c ${SING_BOX_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=${STATE_DIR}
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "${RUNTIME_TMP}/sing-box.service" "${SING_BOX_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable "${SING_BOX_SERVICE}" >/dev/null
    if ! systemctl restart "${SING_BOX_SERVICE}"; then
        failure_reason="systemctl restart 执行失败"
    elif ! wait_for_sing_box_ready; then
        failure_reason="服务未能在 ${SING_BOX_START_TIMEOUT} 秒内保持 active 并监听 TCP ${ANYTLS_PORT}"
    fi
    if [[ -n "${failure_reason}" ]]; then
        capture_sing_box_start_diagnostics
        if [[ -n "${SING_BOX_CONFIG_BACKUP:-}" ]]; then
            install -m 0600 "${SING_BOX_CONFIG_BACKUP}" "${SING_BOX_CONFIG}"
        fi
        if [[ -n "${previous_service}" ]]; then
            install -m 0644 "${previous_service}" "${SING_BOX_SERVICE_FILE}"
        fi
        systemctl daemon-reload
        systemctl restart "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true
        die "sing-box 启动失败：${failure_reason}；已尝试恢复原配置"
    fi
    rm -f -- "${SING_BOX_START_DIAGNOSTICS}"
}

build_anytls_link() {
    local port=${1:-}
    local encoded_password encoded_domain encoded_name
    port=${port:-$(current_subscribe_port)}
    encoded_password=$(uri_encode "${ANYTLS_PASSWORD}")
    encoded_domain=$(uri_encode "${ANYTLS_DOMAIN}")
    encoded_name=$(uri_encode "${NODE_NAME:-${DEFAULT_NODE_NAME}}")
    printf 'anytls://%s@%s:%s/?sni=%s&insecure=0#%s' \
        "${encoded_password}" "${ANYTLS_DOMAIN}" "${port}" \
        "${encoded_domain}" "${encoded_name}"
}

build_client_outbound_json() {
    local port=${1:-}
    port=${port:-$(current_subscribe_port)}
    jq -n \
        --arg tag "${NODE_NAME:-${DEFAULT_NODE_NAME}}" \
        --arg server "${ANYTLS_DOMAIN}" \
        --arg password "${ANYTLS_PASSWORD}" \
        --argjson port "${port}" '
        {
          type: "anytls",
          tag: $tag,
          server: $server,
          server_port: $port,
          password: $password,
          tls: {
            enabled: true,
            server_name: $server,
            insecure: false,
            utls: {
              enabled: true,
              fingerprint: "chrome"
            }
          }
        }
    '
}

current_subscribe_port() {
    local mode=${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}
    local day hour hour_count random_offset
    if [[ "${mode}" == "443" ]]; then
        printf '%s' "${ANYTLS_PORT}"
        return
    fi
    day=$(TZ=Asia/Shanghai date +%j)
    hour=$(TZ=Asia/Shanghai date +%H)
    hour_count=$(((10#${day} - 1) * 24 + 10#${hour}))
    random_offset=$((RANDOM % PORT_MULTIPLIER + 1))
    printf '%s' "$((PORT_BASE + hour_count * PORT_MULTIPLIER + random_offset))"
}

write_worker() {
    local destination=$1 config_json download_json
    config_json=$(jq -cn \
        --arg name "${NODE_NAME:-${DEFAULT_NODE_NAME}}" \
        --arg server "${ANYTLS_DOMAIN}" \
        --arg password "${ANYTLS_PASSWORD}" \
        --arg sni "${ANYTLS_DOMAIN}" \
        --arg port_mode "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}" \
        --argjson port "${ANYTLS_PORT}" \
        --argjson port_base "${PORT_BASE}" \
        --argjson port_multiplier "${PORT_MULTIPLIER}" \
        '{
          name: $name,
          server: $server,
          password: $password,
          sni: $sni,
          portBase: $port_base,
          portMultiplier: $port_multiplier
        } + if $port_mode == "443" then {port: $port} else {} end')
    download_json=$(jq -cn --arg value \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}" '$value')
    install -d -m 0700 "$(dirname "${destination}")"
    {
        printf 'const CONFIG = Object.freeze(%s);\n' "${config_json}"
        printf 'const DOWNLOAD_NAME = %s;\n' "${download_json}"
        cat <<'EOF'

function encodeBase64Utf8(value) {
  const bytes = new TextEncoder().encode(value);
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary);
}

function dynamicPort(config) {
  if (config.port) {
    return config.port;
  }
  const nowUtc8 = new Date(Date.now() + 8 * 60 * 60 * 1000);
  const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
  const hours = Math.floor((nowUtc8.getTime() - yearStart) / 3600000);
  return config.portBase + hours * config.portMultiplier +
    Math.floor(Math.random() * config.portMultiplier) + 1;
}

function anytlsUri(config, port) {
  const auth = encodeURIComponent(config.password);
  const sni = encodeURIComponent(config.sni);
  const name = encodeURIComponent(config.name);
  return `anytls://${auth}@${config.server}:${port}/?sni=${sni}&insecure=0#${name}`;
}

function yamlQuote(value) {
  return JSON.stringify(String(value));
}

const FAKE_IP_FILTER = `      - '+.lan'
      - '+.local'
      - 'localhost'
      - 'time.windows.com'
      - 'time.apple.com'
      - '*.ntp.org.cn'
      - 'pool.ntp.org'`;

const MIHOMO_RULES = `rules:
  # ==================== 局域网直连 ====================
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve

  # ==================== 国内高流量服务直连 ====================
  # DOMAIN-SUFFIX 同时覆盖域名解析得到的 IPv4（A）与 IPv6（AAAA）。
  # 视频 / 直播：哔哩哔哩、爱奇艺、优酷、抖音、西瓜、快手
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,b23.tv,DIRECT
  - DOMAIN-SUFFIX,bilivideo.com,DIRECT
  - DOMAIN-SUFFIX,bilivideo.cn,DIRECT
  - DOMAIN-SUFFIX,hdslb.com,DIRECT
  - DOMAIN-SUFFIX,biliapi.net,DIRECT
  - DOMAIN-SUFFIX,biliapi.com,DIRECT
  - DOMAIN-SUFFIX,acgvideo.com,DIRECT
  - DOMAIN-SUFFIX,iqiyi.com,DIRECT
  - DOMAIN-SUFFIX,qiyi.com,DIRECT
  - DOMAIN-SUFFIX,qiyipic.com,DIRECT
  - DOMAIN-SUFFIX,iqiyipic.com,DIRECT
  - DOMAIN-SUFFIX,youku.com,DIRECT
  - DOMAIN-SUFFIX,ykimg.com,DIRECT
  - DOMAIN-SUFFIX,douyin.com,DIRECT
  - DOMAIN-SUFFIX,douyincdn.com,DIRECT
  - DOMAIN-SUFFIX,douyinpic.com,DIRECT
  - DOMAIN-SUFFIX,douyinstatic.com,DIRECT
  - DOMAIN-SUFFIX,byteimg.com,DIRECT
  - DOMAIN-SUFFIX,pstatp.com,DIRECT
  - DOMAIN-SUFFIX,snssdk.com,DIRECT
  - DOMAIN-SUFFIX,toutiao.com,DIRECT
  - DOMAIN-SUFFIX,ixigua.com,DIRECT
  - DOMAIN-SUFFIX,ixiguavideo.com,DIRECT
  - DOMAIN-SUFFIX,kuaishou.com,DIRECT
  - DOMAIN-SUFFIX,gifshow.com,DIRECT
  - DOMAIN-SUFFIX,ks-cdn.com,DIRECT
  - DOMAIN-SUFFIX,kwaicdn.com,DIRECT

  # 社区 / 图片：知乎、小红书、微博
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - DOMAIN-SUFFIX,zhimg.com,DIRECT
  - DOMAIN-SUFFIX,xiaohongshu.com,DIRECT
  - DOMAIN-SUFFIX,xhscdn.com,DIRECT
  - DOMAIN-SUFFIX,xhslink.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,weibo.cn,DIRECT
  - DOMAIN-SUFFIX,sina.com.cn,DIRECT
  - DOMAIN-SUFFIX,sinaimg.cn,DIRECT

  # 腾讯 / 百度 / 网易及常用云 CDN
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,gtimg.com,DIRECT
  - DOMAIN-SUFFIX,gtimg.cn,DIRECT
  - DOMAIN-SUFFIX,qpic.cn,DIRECT
  - DOMAIN-SUFFIX,qlogo.cn,DIRECT
  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT
  - DOMAIN-SUFFIX,wechat.com,DIRECT
  - DOMAIN-SUFFIX,myqcloud.com,DIRECT
  - DOMAIN-SUFFIX,qcloud.com,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,bdimg.com,DIRECT
  - DOMAIN-SUFFIX,bdstatic.com,DIRECT
  - DOMAIN-SUFFIX,bcebos.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,126.com,DIRECT
  - DOMAIN-SUFFIX,126.net,DIRECT
  - DOMAIN-SUFFIX,127.net,DIRECT

  # 电商 / 本地生活及其静态资源
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,tmall.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,alicdn.com,DIRECT
  - DOMAIN-SUFFIX,tbcdn.cn,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,jdcdn.com,DIRECT
  - DOMAIN-SUFFIX,360buyimg.com,DIRECT
  - DOMAIN-SUFFIX,pinduoduo.com,DIRECT
  - DOMAIN-SUFFIX,yangkeduo.com,DIRECT
  - DOMAIN-SUFFIX,meituan.com,DIRECT
  - DOMAIN-SUFFIX,meituan.net,DIRECT
  - DOMAIN-SUFFIX,dianping.com,DIRECT

  # ==================== AI 服务 ====================
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,claude.com,PROXY
  - DOMAIN-SUFFIX,claudeusercontent.com,PROXY
  - DOMAIN,gemini.google.com,PROXY
  - DOMAIN,aistudio.google.com,PROXY
  - DOMAIN,ai.google.dev,PROXY
  - DOMAIN-SUFFIX,generativeai.google,PROXY

  # ==================== Apple 精确分流 ====================
  - DOMAIN-SUFFIX,apple-relay.akamaized.net,PROXY
  - DOMAIN-SUFFIX,apple-relay.apple.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.cloudflare.com,PROXY
  - DOMAIN-SUFFIX,apple.com,DIRECT
  - DOMAIN-SUFFIX,apple.co,DIRECT
  - DOMAIN-SUFFIX,apple.com.cn,DIRECT
  - DOMAIN-SUFFIX,aaplimg.com,DIRECT
  - DOMAIN-SUFFIX,icloud.com,DIRECT
  - DOMAIN-SUFFIX,mzstatic.com,DIRECT

  # ==================== Microsoft 精确分流 ====================
  - DOMAIN-SUFFIX,microsoft.com,PROXY
  - DOMAIN-SUFFIX,bing.com,PROXY
  - DOMAIN-SUFFIX,live.com,PROXY
  - DOMAIN-SUFFIX,outlook.com,PROXY
  - DOMAIN-SUFFIX,office.com,PROXY
  - DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
  - DOMAIN-SUFFIX,windowsupdate.com,DIRECT

  # ==================== Google / YouTube ====================
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
  - DOMAIN-SUFFIX,googleusercontent.com,PROXY
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  - DOMAIN-SUFFIX,googlevideo.com,PROXY
  - DOMAIN-SUFFIX,youtube.com,PROXY
  - DOMAIN-SUFFIX,ytimg.com,PROXY

  # ==================== Telegram IP 段 ====================
  - IP-CIDR,91.105.192.0/23,PROXY,no-resolve
  - IP-CIDR,91.108.4.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.8.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.12.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.16.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.20.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.56.0/22,PROXY,no-resolve
  - IP-CIDR,149.154.160.0/20,PROXY,no-resolve
  - IP-CIDR,185.76.151.0/24,PROXY,no-resolve

  # ==================== GEOSITE / GEOIP 兜底 ====================
  - GEOSITE,geolocation-!cn,PROXY
  - GEOSITE,CN,DIRECT
  # GEOIP CN 数据同时匹配国内 IPv4 与 IPv6 目标地址。
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,PROXY
`;

const MIHOMO_TEMPLATE = `mixed-port: 1080
allow-lan: false
mode: rule
log-level: info
ipv6: true
external-controller: '127.0.0.1:9090'
unified-delay: true
profile:
    store-selected: true

sniffer:
    enable: true
    force-dns-mapping: true
    parse-pure-ip: true
    override-destination: true
    sniff:
      HTTP:
        ports: [80, 8080-8880]
        override-destination: true
      TLS:
        ports: [443, 8443]
      QUIC:
        ports: [443, 8443]

tun:
    enable: true
    stack: mixed
    auto-route: true
    auto-detect-interface: true
    inet4-address:
      - 198.18.0.1/30
    inet6-address:
      - fdfe:dcba:9877::1/126
    dns-hijack:
      - any:53
      - tcp://any:53
    strict-route: false

dns:
    enable: true
    ipv6: true
    prefer-h3: false
    use-hosts: true
    use-system-hosts: true
    respect-rules: true
    listen: '127.0.0.1:5335'

    default-nameserver:
      - 223.5.5.5
      - 119.29.29.29
      - 8.8.8.8

    proxy-server-nameserver:
      - https://223.5.5.5/dns-query
      - https://dns.alidns.com/dns-query

    nameserver-policy:
      '+.lan': system
      '+.local': system

    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    fake-ip-range6: fdfe:dcba:9876::1/64
    fake-ip-filter:
{fake_ip_filter}

    nameserver:
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query
      - https://223.5.5.5/dns-query

    fallback:
      - https://1.1.1.1/dns-query
      - https://1.0.0.1/dns-query
      - https://dns.google/dns-query
      - https://cloudflare-dns.com/dns-query

    fallback-filter:
        geoip: true
        geoip-code: CN
        ipcidr:
          - 240.0.0.0/4
          - 0.0.0.0/32
          - 127.0.0.1/32
        domain:
          - '+.google.com'
          - '+.googleapis.com'
          - '+.youtube.com'
          - '+.github.com'

proxies:
{proxy_node}

proxy-groups:
    - name: PROXY
      type: select
      proxies:
        - {proxy_name}

{rules}`;

function mihomoProxyNode(config, port) {
  return [
    `  - name: ${yamlQuote(config.name)}`,
    '    type: anytls',
    `    server: ${yamlQuote(config.server)}`,
    `    port: ${port}`,
    `    password: ${yamlQuote(config.password)}`,
    `    sni: ${yamlQuote(config.sni)}`,
    '    client-fingerprint: chrome',
    '    udp: true',
    '    skip-cert-verify: false'
  ].join('\n');
}

function mihomoYaml(config, port) {
  return MIHOMO_TEMPLATE
    .replace('{fake_ip_filter}', FAKE_IP_FILTER)
    .replace('{proxy_node}', mihomoProxyNode(config, port))
    .replace('{proxy_name}', yamlQuote(config.name))
    .replace('{rules}', MIHOMO_RULES);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    if (url.pathname !== '/subscribe') {
      return new Response('Not Found', {status: 404});
    }
    if (!env.SUB_TOKEN || url.searchParams.get('token') !== env.SUB_TOKEN) {
      return new Response('Forbidden', {status: 403});
    }
    const isClash = url.searchParams.get('flag') === 'clash';
    const headers = {
      'cache-control': 'no-store, no-cache, must-revalidate, max-age=0',
      'pragma': 'no-cache',
      'expires': '0',
      'access-control-allow-origin': '*'
    };
    if (isClash) {
      const port = dynamicPort(CONFIG);
      headers['content-type'] = 'text/yaml; charset=utf-8';
      headers['content-disposition'] = `attachment; filename="${DOWNLOAD_NAME}.yaml"`;
      return new Response(mihomoYaml(CONFIG, port), {
        status: 200,
        headers
      });
    }
    const port = dynamicPort(CONFIG);
    headers['content-type'] = 'text/plain; charset=utf-8';
    return new Response(encodeBase64Utf8(anytlsUri(CONFIG, port)), {
      status: 200,
      headers
    });
  }
};
EOF
    } >"${RUNTIME_TMP}/worker.js"
    install -m 0600 "${RUNTIME_TMP}/worker.js" "${destination}"
}

cloudflare_api() {
    local method=$1 path=$2
    shift 2
    local header_file="${RUNTIME_TMP}/cf-worker-headers"
    {
        printf 'Authorization: Bearer %s\n' "${CF_WORKER_API_TOKEN}"
        printf 'Accept: application/json\n'
    } >"${header_file}"
    chmod 0600 "${header_file}"
    curl -sS --retry 3 -X "${method}" \
        -H "@${header_file}" \
        "https://api.cloudflare.com/client/v4${path}" "$@"
}

report_cloudflare_api_failure() {
    local context=$1 response=$2 details
    warn "${context}"
    if details=$(jq -er '
        [(.errors // [])[] |
          if .code then "[\(.code)] \(.message)" else .message end] |
        select(length > 0) | join("\n")
    ' <<<"${response}"); then
        printf '%s\n' "${details}" >&2
    else
        printf '%s\n' "${response}" >&2
    fi
}

deploy_worker() {
    local metadata response subdomain worker_module_file
    CF_ACCOUNT_ID=${CF_ACCOUNT_ID:-$(prompt_value "Cloudflare Account ID" "")}
    [[ -n "${CF_ACCOUNT_ID}" ]] || {
        warn "Cloudflare Account ID 为空"
        return 1
    }
    if [[ -z "${CF_WORKER_API_TOKEN:-}" ]]; then
        CF_WORKER_API_TOKEN=$(prompt_secret \
            "Cloudflare Worker API Token（输入不回显）") || {
            warn "非交互模式必须设置 CF_WORKER_API_TOKEN"
            return 1
        }
    fi
    WORKER_NAME=$(prompt_value "Cloudflare Worker 名称" \
        "${WORKER_NAME:-${DEFAULT_WORKER_NAME}}")
    validate_worker_name "${WORKER_NAME}" || {
        warn "Worker 名称无效：${WORKER_NAME}"
        return 1
    }
    SUB_TOKEN=${SUB_TOKEN:-$(generate_secret)}
    metadata=$(jq -cn --arg token "${SUB_TOKEN}" '{
      main_module: "worker.js",
      compatibility_date: "2026-01-01",
      bindings: [{type: "secret_text", name: "SUB_TOKEN", text: $token}]
    }')
    worker_module_file="${RUNTIME_TMP}/worker-module.js"
    install -m 0600 "${WORKER_FILE}" "${worker_module_file}"
    response=$(cloudflare_api PUT \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
        -F "metadata=${metadata};type=application/json" \
        -F "worker.js=@${worker_module_file};filename=worker.js;type=application/javascript+module") \
        || return 1
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        report_cloudflare_api_failure "Cloudflare Worker module 上传失败" "${response}"
        return 1
    }
    response=$(cloudflare_api POST \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" \
        -H "Content-Type: application/json" \
        --data '{"enabled":true}') || return 1
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        report_cloudflare_api_failure "启用 Worker workers.dev 地址失败" "${response}"
        return 1
    }
    response=$(cloudflare_api GET \
        "/accounts/${CF_ACCOUNT_ID}/workers/subdomain") || return 1
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        report_cloudflare_api_failure "读取账户 workers.dev 子域名失败" "${response}"
        return 1
    }
    subdomain=$(jq -er '.result.subdomain' <<<"${response}") || {
        report_cloudflare_api_failure "Cloudflare 响应缺少 workers.dev 子域名" "${response}"
        return 1
    }
    WORKER_URL="https://${WORKER_NAME}.${subdomain}.workers.dev"
    unset CF_WORKER_API_TOKEN
}

verify_subscription() {
    local code attempt
    [[ -n "${WORKER_URL:-}" ]] || return 1
    for attempt in 1 2 3 4 5; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
            "${WORKER_URL}/subscribe?token=${SUB_TOKEN}" || true)
        [[ "${code}" == "200" ]] && return 0
        warn "订阅验收第 ${attempt} 次返回 HTTP ${code}"
        sleep 2
    done
    return 1
}

configure_subscription() {
    choose_subscription_mode
    choose_subscription_port_mode
    require_dynamic_port_redirect
    case "${SUBSCRIBE_MODE}" in
    auto)
        choose_subscription_download_name
        write_worker "${WORKER_FILE}"
        if deploy_worker; then
            DEPLOY_MODE="auto"
            verify_subscription \
                || warn "Worker 已部署，但 HTTP 验收暂未通过"
        else
            WORKER_URL=""
            DEPLOY_MODE="worker"
            SUB_TOKEN=${SUB_TOKEN:-$(generate_secret)}
            warn "自动部署失败，已保留 Worker 文件供手动部署"
            print_worker_content
        fi
        unset CF_WORKER_API_TOKEN || true
        ;;
    worker)
        choose_subscription_download_name
        SUB_TOKEN=${SUB_TOKEN:-$(generate_secret)}
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

print_worker_content() {
    printf '\nWorker 内容如下，请复制到 Cloudflare Worker：\n'
    printf '%s\n' '----- BEGIN easy_anytls Worker -----'
    cat "${WORKER_FILE}"
    printf '\n%s\n\n' '----- END easy_anytls Worker -----'
}

collect_anytls_state() {
    load_state
    [[ -n "${ANYTLS_DOMAIN}" && -n "${ANYTLS_PASSWORD}" ]] \
        || die "AnyTLS 尚未完成安装"
    validate_domain "${ANYTLS_DOMAIN}" || die "状态文件中的域名无效"
}

show_node() {
    collect_anytls_state
    local port
    port=$(current_subscribe_port)
    printf '\nsing-box AnyTLS 客户端 outbound:\n'
    build_client_outbound_json "${port}"
    printf '\nAnyTLS 纯链接:\n%s\n\n' "$(build_anytls_link "${port}")"
}

show_subscription() {
    collect_anytls_state
    show_node
    if [[ "${DEPLOY_MODE:-link}" == "link" ]]; then
        printf '当前模式：只输出配置与纯链接\n\n'
        return
    fi
    printf 'Worker 文件: %s\n' "${WORKER_FILE}"
    printf '订阅暴露端口模式: %s\n' "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}"
    printf '订阅 Token: %s\n' "${SUB_TOKEN:-未生成}"
    if [[ -n "${WORKER_URL:-}" ]]; then
        printf '通用订阅: %s/subscribe?token=%s\n' \
            "${WORKER_URL}" "${SUB_TOKEN}"
        printf 'Mihomo: %s/subscribe?token=%s&flag=clash\n' \
            "${WORKER_URL}" "${SUB_TOKEN}"
    else
        printf '部署方式：手动部署，并将 SUB_TOKEN 设置为 Worker 加密变量。\n'
    fi
    printf '\n'
}

show_status() {
    collect_anytls_state
    local public_ip="" records="" expires=""
    public_ip=$(detect_public_ipv4 2>/dev/null || true)
    records=$(query_a_records "${ANYTLS_DOMAIN}" "" | paste -sd, -)
    expires=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null \
        | cut -d= -f2- || true)
    printf 'sing-box: '
    systemctl is-active --quiet "${SING_BOX_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'TCP %s: ' "${ANYTLS_PORT}"
    tcp_port_is_listening "${ANYTLS_PORT}" \
        && printf 'listening\n' || printf 'not listening\n'
    printf 'sing-box 版本: %s\n' \
        "$("${SING_BOX_BIN}" version 2>/dev/null | head -n 1 || echo 未安装)"
    printf '版本通道: %s\n' "${SING_BOX_CHANNEL:-未知}"
    printf 'AnyTLS 域名: %s\n' "${ANYTLS_DOMAIN}"
    printf '订阅暴露端口模式: %s\n' "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}"
    printf 'DNS A 记录: %s\n' "${records:-无}"
    printf '本机公网 IPv4: %s\n' "${public_ip:-探测失败}"
    printf '证书到期时间: %s\n' "${expires:-读取失败}"
    printf 'acme.sh 自动续期: '
    crontab -l 2>/dev/null | grep -Fq "${ACME_BIN}" \
        && printf '已配置\n' || printf '未检测到\n'
    printf 'nftables: '
    systemctl is-active --quiet nftables 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'BBR: %s\n' \
        "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf 'Worker URL: %s\n' "${WORKER_URL:-未记录}"
    if [[ -f "${SING_BOX_START_DIAGNOSTICS}" ]]; then
        printf '最近启动失败诊断: %s\n' "${SING_BOX_START_DIAGNOSTICS}"
    fi
}

update_sing_box() {
    require_root
    collect_anytls_state
    local selector=${SING_BOX_VERSION_OVERRIDE:-${SING_BOX_VERSION:-latest}}
    local backup="${RUNTIME_TMP}/sing-box.backup"
    local new_bin="${RUNTIME_TMP}/sing-box.update"
    [[ -x "${SING_BOX_BIN}" ]] || die "sing-box 尚未安装"
    if [[ "${SING_BOX_CHANNEL:-}" == "pinned" \
        && -z "${SING_BOX_VERSION_OVERRIDE:-}" ]]; then
        die "当前为指定版本锁定模式；请设置 SING_BOX_VERSION_OVERRIDE=新版本 后更新"
    fi
    cp -a "${SING_BOX_BIN}" "${backup}"
    download_sing_box_binary "${selector}" "${new_bin}"
    "${new_bin}" check -c "${SING_BOX_CONFIG}" \
        || die "新 sing-box 与当前配置不兼容"
    install -m 0755 "${new_bin}" "${SING_BOX_BIN}"
    if ! systemctl restart "${SING_BOX_SERVICE}" \
        || ! wait_for_sing_box_ready; then
        capture_sing_box_start_diagnostics
        install -m 0755 "${backup}" "${SING_BOX_BIN}"
        systemctl restart "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true
        die "sing-box 更新后未能通过启动验收，已恢复旧版本；诊断见 ${SING_BOX_START_DIAGNOSTICS}"
    fi
    SING_BOX_VERSION="${selector}"
    SING_BOX_INSTALLED_VERSION="${SING_BOX_RELEASE_VERSION}"
    save_state
    success "sing-box 已更新到 ${SING_BOX_INSTALLED_VERSION}"
}

renew_certificate() {
    require_root
    collect_anytls_state
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 尚未安装"
    "${ACME_BIN}" --renew -d "${ANYTLS_DOMAIN}" --ecc --force \
        || die "证书续期失败"
    validate_certificate "${ANYTLS_DOMAIN}"
    systemctl restart "${SING_BOX_SERVICE}" \
        || die "证书续期后重启 sing-box 失败"
    if ! wait_for_sing_box_ready; then
        capture_sing_box_start_diagnostics
        die "证书已续期，但 sing-box 未能通过启动验收；诊断见 ${SING_BOX_START_DIAGNOSTICS}"
    fi
    success "证书已续期并重启 sing-box"
}

register_easy_anytls_command() {
    require_root
    [[ -f "${SCRIPT_FILE}" ]] || die "未找到脚本：${SCRIPT_FILE}"
    install -d -m 0755 "${COMMAND_INSTALL_DIR}" "$(dirname "${COMMAND_PATH}")"
    install -m 0755 "${SCRIPT_FILE}" "${COMMAND_INSTALL_DIR}/easy_anytls.sh"
    ln -sfn "${COMMAND_INSTALL_DIR}/easy_anytls.sh" "${COMMAND_PATH}"
    success "已注册命令：${COMMAND_PATH}"
}

delete_remote_worker() {
    local response
    [[ "${DELETE_CLOUDFLARE_WORKER:-0}" == "1" ]] || {
        warn "远端 Cloudflare Worker 未删除；如需删除，请设置 DELETE_CLOUDFLARE_WORKER=1 并提供 CF_WORKER_API_TOKEN"
        return 0
    }
    [[ -n "${CF_ACCOUNT_ID:-}" && -n "${WORKER_NAME:-}" ]] \
        || die "删除远端 Worker 需要 CF_ACCOUNT_ID 和 WORKER_NAME"
    [[ -n "${CF_WORKER_API_TOKEN:-}" ]] \
        || die "删除远端 Worker 需要 CF_WORKER_API_TOKEN"
    response=$(cloudflare_api DELETE \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}") \
        || die "Cloudflare Worker 删除请求失败"
    jq -e '.success == true' <<<"${response}" >/dev/null \
        || die "Cloudflare Worker 删除失败：$(jq -r '.errors[]?.message' <<<"${response}")"
    unset CF_WORKER_API_TOKEN
    success "已删除远端 Cloudflare Worker：${WORKER_NAME}"
}

purge_acme_installation() {
    local profile other_domain_config=
    if [[ "${ACME_INSTALLED_BY_EASY_ANYTLS:-0}" != "1" \
        && "${PURGE_SHARED_ACME:-0}" != "1" ]]; then
        warn "acme.sh 非 easy_anytls 专属或来源未知，未删除；确需删除请使用 uninstall --purge 并设置 PURGE_SHARED_ACME=1"
        return
    fi
    if [[ "${PURGE_SHARED_ACME:-0}" != "1" && -d "${ACME_HOME}" ]]; then
        other_domain_config=$(find "${ACME_HOME}" -mindepth 2 -maxdepth 2 \
            -type f -name '*.conf' -print -quit 2>/dev/null || true)
        if [[ -n "${other_domain_config}" ]]; then
            warn "acme.sh 中还有其他证书配置，按共享组件保留；确需全部删除请使用 uninstall --purge 并设置 PURGE_SHARED_ACME=1"
            return
        fi
    fi
    [[ ! -x "${ACME_BIN}" ]] || "${ACME_BIN}" --uninstall >/dev/null 2>&1 || true
    { crontab -l 2>/dev/null || true; } \
        | awk -v acme_home="${ACME_HOME}" 'index($0, acme_home) == 0 {print}' \
        | crontab - || warn "移除 acme.sh cron 失败，请手动检查"
    for profile in /root/.bashrc /root/.profile /root/.zshrc; do
        [[ -f "${profile}" ]] || continue
        sed -i "\\|${ACME_HOME}|d" "${profile}" \
            || warn "无法清理 ${profile} 中的 acme.sh 初始化行"
    done
    rm -rf -- "${ACME_HOME}"
    success "已清理 easy_anytls 安装的 acme.sh"
}

purge_anytls_backups() {
    rm -f -- \
        "${BACKUP_DIR}"/install-sing-box.*.bak \
        "${BACKUP_DIR}"/install-sing-box-config.*.bak \
        "${BACKUP_DIR}"/install-sing-box-service.*.bak \
        "${BACKUP_DIR}"/install-fullchain.*.bak \
        "${BACKUP_DIR}"/install-private-key.*.bak \
        "${BACKUP_DIR}"/install-reload-hook.*.bak \
        "${BACKUP_DIR}"/sing-box-config.*.bak \
        "${BACKUP_DIR}"/sing-box.service.*.bak
}

filter_anytls_dynamic_redirect() {
    awk -v first="${PORT_BASE}" -v target="${ANYTLS_PORT}" '
        $0 ~ "^[[:space:]]*tcp[[:space:]]+dport[[:space:]]+" first \
            "-65535[[:space:]]+redirect[[:space:]]+to[[:space:]]+:" target \
            "([[:space:]]|$)" {next}
        {print}
    '
}

remove_anytls_dynamic_redirect() {
    [[ -f "${NFT_CONFIG}" ]] || return 0
    local temp_dir candidate
    temp_dir=$(make_temp_dir)
    candidate="${temp_dir}/nftables-after-anytls-uninstall.conf"
    filter_anytls_dynamic_redirect <"${NFT_CONFIG}" >"${candidate}"
    if cmp -s "${NFT_CONFIG}" "${candidate}"; then
        return 0
    fi
    nft -c -f "${candidate}" \
        || {
            warn "移除 AnyTLS 动态端口转发后的 nftables 配置校验失败，已保留原配置"
            return 0
        }
    install -m 0644 "${candidate}" "${NFT_CONFIG}"
    systemctl restart nftables >/dev/null 2>&1 \
        || warn "重启 nftables 失败，请手动检查 ${NFT_CONFIG}"
    success "已移除 AnyTLS 专属动态端口转发 ${PORT_BASE}-65535 -> ${ANYTLS_PORT}"
}

remove_anytls_local_files() {
    systemctl disable --now "${SING_BOX_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${SING_BOX_SERVICE_FILE}" "${SING_BOX_CONFIG}" "${SING_BOX_BIN}"
    rm -f -- "${STATE_FILE}" "${WORKER_FILE}" "${CERT_FILE}" "${KEY_FILE}" \
        "${SING_BOX_START_DIAGNOSTICS}" "${ACME_OWNERSHIP_MARKER}"
    rm -f -- "${COMMAND_PATH}" "${COMMAND_INSTALL_DIR}/easy_anytls.sh" \
        "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload
    rmdir "${SING_BOX_CONFIG_DIR}" "${COMMAND_INSTALL_DIR}" "${CERT_DIR}" \
        2>/dev/null || true
}

uninstall_anytls() {
    local mode=${1:-} answer= purge_mode=0
    local purge_shared_acme_requested=${PURGE_SHARED_ACME:-0}
    local PURGE_SHARED_ACME=0
    require_root
    case "${mode}" in
    "") ;;
    --restore-system)
        warn "--restore-system 已废弃；卸载不会改动服务器初始化配置"
        ;;
    --purge) purge_mode=1 ;;
    *) die "卸载参数无效：${mode}；仅支持 --purge 或兼容参数 --restore-system" ;;
    esac
    load_state
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "无人值守卸载需要设置 FORCE=1"
        read -r -p "确认删除 AnyTLS 服务、证书、专属 acme.sh 内容、定时重启和本机 Worker 文件？[y/N]: " answer
        [[ "${answer}" == "y" || "${answer}" == "Y" ]] || return 0
        if [[ "${purge_mode}" == "1" ]]; then
            read -r -p "彻底清理会额外删除 AnyTLS 专属历史备份，输入 PURGE 继续: " answer
            [[ "${answer}" == "PURGE" ]] || return 0
        fi
    fi
    [[ "${purge_mode}" != "1" ]] || delete_remote_worker
    if [[ -n "${ANYTLS_DOMAIN:-}" && -x "${ACME_BIN}" ]]; then
        "${ACME_BIN}" --remove -d "${ANYTLS_DOMAIN}" --ecc \
            >/dev/null 2>&1 \
            || warn "acme.sh 未能正常取消 ${ANYTLS_DOMAIN} 的续期登记，将继续清理当前域名内部目录"
        rm -rf -- "${ACME_HOME:?}/${ANYTLS_DOMAIN}" \
            "${ACME_HOME:?}/${ANYTLS_DOMAIN}_ecc"
    fi
    remove_daily_reboot_schedule
    if [[ "${purge_mode}" == "1" ]]; then
        PURGE_SHARED_ACME="${purge_shared_acme_requested}"
    fi
    purge_acme_installation
    remove_anytls_dynamic_redirect
    remove_anytls_local_files
    if [[ "${purge_mode}" == "1" ]]; then
        purge_anytls_backups
    else
        warn "默认卸载保留历史备份、共享 acme.sh 和远端 Cloudflare Worker"
    fi
    rmdir "${BACKUP_DIR}" "${STATE_DIR}" "${SING_BOX_CONFIG_DIR}" \
        "${COMMAND_INSTALL_DIR}" 2>/dev/null || true
    success "AnyTLS 本机服务、核心、当前配置和证书已删除"
    warn "除 AnyTLS 专属动态端口转发外，nftables、BBR、IPv6、XanMod、时区、NTP 和系统软件包均未改动"
}

install_all() {
    require_root
    preflight_debian
    load_state
    choose_domain
    choose_sing_box_version
    choose_subscription_mode
    choose_subscription_port_mode
    bootstrap_dns_dependencies
    local public_ip
    public_ip=$(detect_public_ipv4)
    verify_domain_dns "${ANYTLS_DOMAIN}" "${public_ip}"
    INSTALL_ROLLBACK_ON_EXIT=1
    run_server_initialization
    verify_domain_dns "${ANYTLS_DOMAIN}" "${public_ip}"
    install_sing_box_binary
    issue_certificate "${ANYTLS_DOMAIN}"
    info "[8/8] 写入 AnyTLS 配置、启动服务并配置订阅"
    ensure_anytls_password
    write_sing_box_config
    install_sing_box_service
    configure_subscription
    INSTALL_ROLLBACK_ON_EXIT=0
    register_easy_anytls_command
    show_subscription
    success "AnyTLS 一键安装完成"
    if [[ "$(uname -r)" != *xanmod* ]]; then
        warn "需要重启后才会进入 XanMod BBR 内核"
    fi
}

usage() {
    cat <<EOF
用法: $0 [命令]

  install       初始化服务器、申请单域名证书并安装 sing-box AnyTLS（默认）
  show          显示 sing-box 客户端配置和 AnyTLS 纯链接
  subscription  显示配置、纯链接和订阅信息
  update-sub    重新配置 Worker 订阅输出
  update-singbox
                按已保存的 stable/alpha 通道更新 sing-box
  renew-cert    立即强制续期单域名证书
  status        显示服务、DNS、证书、续期和 Worker 状态
  register-command
                注册系统命令 easy_anytls
  uninstall     删除 AnyTLS 服务、证书、acme.sh 专属内容、定时重启和 Worker 文件
  uninstall --purge
                额外清理 AnyTLS 专属历史备份；可显式强制清理共享 acme.sh
  help          显示帮助

主要无人值守变量:
  ANYTLS_DOMAIN=node.example.com
  SING_BOX_VERSION=latest|alpha|具体版本
  CF_DNS_API_TOKEN=...
  SUBSCRIBE_MODE=auto|worker|link
  CF_WORKER_API_TOKEN=...  CF_ACCOUNT_ID=...
  WORKER_NAME=easy-anytls  SUB_PORT_MODE=dynamic|443
  SUB_DOWNLOAD_NAME=MY_SUB
  FORCE=1                  无人值守确认卸载
  DELETE_CLOUDFLARE_WORKER=1
                            --purge 时同时删除远端 Worker（需 Worker Token）
  PURGE_SHARED_ACME=1      明确允许删除来源未知/安装前已存在的 acme.sh

指定版本更新:
  SING_BOX_VERSION_OVERRIDE=1.13.12 easy_anytls update-singbox

动态订阅端口:
  SUB_PORT_MODE 默认 dynamic，会生成 10000-65535 动态端口并配置 nftables 转发到 443。
  如需固定 443，可设置 SUB_PORT_MODE=443。

一键下载:
  curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && sudo ./easy_anytls.sh install
EOF
}

main() {
    case "${1:-install}" in
    install) install_all ;;
    show) require_root; show_node ;;
    subscription) require_root; show_subscription ;;
    update-sub) require_root; collect_anytls_state; configure_subscription; show_subscription ;;
    update-singbox) update_sing_box ;;
    renew-cert) renew_certificate ;;
    status) require_root; show_status ;;
    register-command) register_easy_anytls_command ;;
    uninstall) uninstall_anytls "${2:-}" ;;
    help | -h | --help) usage ;;
    *) usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
