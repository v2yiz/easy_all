#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

readonly STATE_DIR="/etc/easy_reality"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly WORKER_FILE="${STATE_DIR}/subscribe-worker.js"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_FILE="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_reality"
readonly COMMAND_PATH="/usr/local/bin/easy_reality"
readonly INSTALL_DIR="/etc/v2ray-agent/xray"
readonly XRAY_BIN="${INSTALL_DIR}/xray"
readonly XRAY_CONFIG="${INSTALL_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/xray.service"
readonly XRAY_SERVICE="xray.service"
readonly NFT_CONFIG="/etc/nftables.conf"
readonly SYSCTL_CONFIG="/etc/sysctl.d/99-bbrv3.conf"
readonly IPV6_SYSCTL_CONF="/etc/sysctl.d/99-enable-ipv6.conf"
readonly OLD_DISABLE_IPV6_CONF="/etc/sysctl.d/99-disable-ipv6.conf"
readonly XANMOD_KEYRING="/etc/apt/keyrings/xanmod-archive-keyring.gpg"
readonly XANMOD_REPO="/etc/apt/sources.list.d/xanmod-release.list"
readonly DEFAULT_REALITY_TARGET="swdist.apple.com:443"
readonly REALITY_PORT="443"
readonly PORT_BASE="10000"
readonly PORT_MULTIPLIER="6"
readonly DEFAULT_SUB_PORT_MODE="443"
readonly DEFAULT_SUB_DOWNLOAD_NAME="MY_SUB"
readonly LEGACY_CRON_JOB="0 4 * * * /sbin/reboot"
readonly CRON_REBOOT_COMMAND="/usr/bin/flock -n /run/daily-reboot.lock /sbin/reboot"
readonly DEFAULT_REBOOT_HOUR="4"
# 内置 Worker 模板的完整性校验值，不是部署参数；模板内容变更时才需要同步更新。
readonly WORKER_TEMPLATE_SHA256="a4ee21cdfa4acf9e11f4735e41425876fac80759bdeef6b67334ee23837a4d0a"

SCHEDULED_REBOOT_ENABLED=1
SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"
INSTALL_ROLLBACK_ON_EXIT=0
INSTALL_ROLLBACK_AVAILABLE=0

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
    if [[ "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" && "${INSTALL_ROLLBACK_AVAILABLE:-0}" == "1" ]]; then
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

validate_ipv4() {
    local ip=$1 octet
    local -a octets
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"${ip}"
    for octet in "${octets[@]}"; do
        ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
    done
}

validate_node_host() {
    validate_domain "$1" || validate_ipv4 "$1"
}

validate_worker_name() {
    [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]
}

validate_sub_port_mode() {
    [[ "$1" == "443" || "$1" == "dynamic" ]]
}

has_dynamic_port_redirect() {
    local pattern
    pattern="tcp[[:space:]]+dport[[:space:]]+${PORT_BASE}-65535[[:space:]]+redirect[[:space:]]+to[[:space:]]+:${REALITY_PORT}"
    if [[ -f "${NFT_CONFIG}" ]] && grep -Eq "${pattern}" "${NFT_CONFIG}"; then
        return 0
    fi
    command -v nft >/dev/null 2>&1 \
        && nft list ruleset 2>/dev/null | grep -Eq "${pattern}"
}

require_dynamic_port_redirect() {
    [[ "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}" == "dynamic" ]] || return 0
    has_dynamic_port_redirect && return 0
    die "当前 nftables 未配置 ${PORT_BASE}-65535 到 ${REALITY_PORT} 的动态端口转发；请重新执行 install，或手动确认防火墙已放行并转发后再使用 SUB_PORT_MODE=dynamic update-sub"
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

validate_xray_value() {
    local name=$1
    local value=$2
    case "${name}" in
    uuid)
        [[ "${value}" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]
        ;;
    public_key) [[ "${value}" =~ ^[A-Za-z0-9_-]{43,44}$ ]] ;;
    short_id) [[ "${value}" =~ ^[0-9a-f]{16}$ ]] ;;
    *) return 1 ;;
    esac
}

prompt_value() {
    local prompt=$1
    local default_value=$2
    local value=
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

detect_public_ipv4() {
    local ip
    for endpoint in \
        https://api.ipify.org \
        https://ipv4.icanhazip.com \
        https://ifconfig.co/ip; do
        ip=$(curl -fsS4 --max-time 8 "${endpoint}" 2>/dev/null | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            printf '%s' "${ip}"
            return 0
        fi
    done
    return 1
}

load_state() {
    local env_node_host=${NODE_HOST:-}
    local env_sub_token=${SUB_TOKEN:-}
    local env_worker_name=${WORKER_NAME:-}
    local env_worker_url=${WORKER_URL:-}
    local env_account_id=${CF_ACCOUNT_ID:-}
    local env_deploy_mode=${DEPLOY_MODE:-}
    local env_sub_port_mode=${SUB_PORT_MODE:-}
    local env_sub_download_name=${SUB_DOWNLOAD_NAME:-}
    NODE_HOST=""
    SUB_TOKEN=""
    WORKER_NAME=""
    WORKER_URL=""
    CF_ACCOUNT_ID=""
    DEPLOY_MODE=""
    SUB_PORT_MODE=""
    SUB_DOWNLOAD_NAME=""
    if [[ -f "${STATE_FILE}" ]]; then
        # The file is generated by save_state with shell-escaped values.
        # shellcheck source=/dev/null
        source "${STATE_FILE}"
    fi
    NODE_HOST=${env_node_host:-${NODE_HOST}}
    SUB_TOKEN=${env_sub_token:-${SUB_TOKEN}}
    WORKER_NAME=${env_worker_name:-${WORKER_NAME}}
    WORKER_URL=${env_worker_url:-${WORKER_URL}}
    CF_ACCOUNT_ID=${env_account_id:-${CF_ACCOUNT_ID}}
    DEPLOY_MODE=${env_deploy_mode:-${DEPLOY_MODE}}
    [[ "${DEPLOY_MODE}" == "manual" ]] && DEPLOY_MODE="worker"
    SUB_PORT_MODE=${env_sub_port_mode:-${SUB_PORT_MODE}}
    SUB_PORT_MODE=${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}
    validate_sub_port_mode "${SUB_PORT_MODE}" \
        || die "订阅暴露端口模式无效：${SUB_PORT_MODE}，只能是 443 或 dynamic"
    SUB_DOWNLOAD_NAME=${env_sub_download_name:-${SUB_DOWNLOAD_NAME}}
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    validate_sub_download_name "${SUB_DOWNLOAD_NAME}" \
        || die "Clash 下载基础名称无效：${SUB_DOWNLOAD_NAME}，只能使用 1-64 位字母、数字、点、下划线或连字符"
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX")
    cleanup_files+=("${temp}")
    {
        printf 'NODE_HOST=%q\n' "${NODE_HOST}"
        printf 'SUB_TOKEN=%q\n' "${SUB_TOKEN}"
        printf 'WORKER_NAME=%q\n' "${WORKER_NAME}"
        printf 'WORKER_URL=%q\n' "${WORKER_URL}"
        printf 'CF_ACCOUNT_ID=%q\n' "${CF_ACCOUNT_ID}"
        printf 'DEPLOY_MODE=%q\n' "${DEPLOY_MODE:-}"
        printf 'SUB_PORT_MODE=%q\n' "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

choose_subscription_port_mode() {
    local mode
    load_state
    mode=$(prompt_value "订阅暴露端口模式：443 或 dynamic" \
        "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}")
    mode=${mode:-${DEFAULT_SUB_PORT_MODE}}
    validate_sub_port_mode "${mode}" \
        || die "订阅暴露端口模式无效：${mode}，只能是 443 或 dynamic"
    SUB_PORT_MODE="${mode}"
}

choose_subscription_download_name() {
    local name
    name=$(prompt_value "Clash 下载基础名称（不含 .yaml）" \
        "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    name=$(normalize_sub_download_name "${name}")
    validate_sub_download_name "${name}" \
        || die "Clash 下载基础名称无效：${name}，只能使用 1-64 位字母、数字、点、下划线或连字符"
    SUB_DOWNLOAD_NAME="${name}"
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
    [[ "$(dpkg --print-architecture)" == "amd64" ]] || die "XanMod BBRv3 初始化仅支持 amd64"
    ! systemd-detect-virt --container >/dev/null 2>&1 \
        || die "容器不能更换宿主机内核"
}

install_base_packages() {
    info "[1/6] 更新系统并安装基础依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get upgrade -y
    apt-get install -y \
        vim curl wget nftables cron ca-certificates gnupg \
        iproute2 iputils-ping tzdata systemd-timesyncd
    timedatectl set-timezone Asia/Shanghai
    if ! timedatectl set-ntp true; then
        die "无法启用网络时间同步"
    fi
    success "当前时间: $(date)"
}

install_xanmod_bbr() {
    local temp_dir key_file keyring_file repo_file
    temp_dir=$(make_temp_dir)
    key_file="${temp_dir}/archive.key"
    keyring_file="${temp_dir}/archive.gpg"
    repo_file="${temp_dir}/xanmod.list"

    info "[2/6] 安装 XanMod LTS 并配置 BBRv3"
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

    cat >"${temp_dir}/sysctl.conf" <<'EOF'
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
    [[ ! -f "${SYSCTL_CONFIG}" || -f "${SYSCTL_CONFIG}.easy_reality.bak" ]] \
        || cp -a "${SYSCTL_CONFIG}" "${SYSCTL_CONFIG}.easy_reality.bak"
    install -m 0644 "${temp_dir}/sysctl.conf" "${SYSCTL_CONFIG}"
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
        if [[ -n "${SSH_PORTS}" ]]; then
            SSH_PORTS+=", ${port}"
        else
            SSH_PORTS="${port}"
        fi
        ;;
    esac
}

detect_ssh_ports() {
    local client_addr client_port server_addr current_port sshd_bin config
    SSH_PORTS=""

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r client_addr client_port server_addr current_port <<<"${SSH_CONNECTION}"
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
    local temp_dir candidate backup=""
    temp_dir=$(make_temp_dir)
    candidate="${temp_dir}/nftables.conf"
    detect_ssh_ports

    info "[3/6] 配置 nftables"
    cat >"${candidate}" <<EOF
#!/usr/sbin/nft -f
flush ruleset

EOF
    if [[ "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}" == "dynamic" ]]; then
        cat >>"${candidate}" <<EOF
table inet nat {
    chain prerouting {
        type nat hook prerouting priority dstnat; policy accept;
        tcp dport ${PORT_BASE}-65535 redirect to :${REALITY_PORT}
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
        tcp dport { ${SSH_PORTS}, 80, ${REALITY_PORT} } accept
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
        [[ -n "${backup}" ]] && install -m 0644 "${backup}" "${NFT_CONFIG}"
        systemctl restart nftables >/dev/null 2>&1 || true
        die "nftables 启动失败，已尝试恢复原配置"
    fi
    systemctl is-active --quiet nftables || die "nftables 未运行"
}

configure_daily_reboot() {
    local mode=${REBOOT_SCHEDULE_MODE:-} hour=${REBOOT_HOUR:-} job
    info "[4/6] 配置定时重启策略"

    if [[ -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            printf '请选择定时重启策略：\n'
            printf '  1. 每天凌晨 4 点重启（默认）\n'
            printf '  2. 自定义每天几点重启（0-23）\n'
            printf '  3. 不配置定时重启\n'
            read -r -p "请选择 [1]（回车默认 1）: " mode
            mode=${mode:-1}
        else
            mode=1
            info "非交互模式未设置 REBOOT_SCHEDULE_MODE，默认每天凌晨 4 点重启"
        fi
    fi

    case "${mode}" in
    1 | default)
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${DEFAULT_REBOOT_HOUR}"
        ;;
    2 | custom)
        if [[ -z "${hour}" ]]; then
            [[ -t 0 ]] || die "自定义重启时间需要设置 REBOOT_HOUR=0~23"
            read -r -p "请输入每天几点重启，范围 0-23: " hour
        fi
        [[ "${hour}" =~ ^[0-9]+$ ]] && ((10#${hour} >= 0 && 10#${hour} <= 23)) \
            || die "重启小时无效：${hour}，请输入 0~23"
        SCHEDULED_REBOOT_ENABLED=1
        SCHEDULED_REBOOT_HOUR="${hour}"
        ;;
    3 | none | off | disable | disabled)
        SCHEDULED_REBOOT_ENABLED=0
        ;;
    *)
        die "无效定时重启选项：${mode}，请输入 1、2 或 3"
        ;;
    esac

    { crontab -l 2>/dev/null || true; } \
        | awk -v legacy="${LEGACY_CRON_JOB}" -v cmd="${CRON_REBOOT_COMMAND}" '
            $0 == legacy { next }
            $1 == "0" && $2 ~ /^([0-9]|1[0-9]|2[0-3])$/ && $3 == "*" && $4 == "*" && $5 == "*" {
                rest = ""
                for (i = 6; i <= NF; i++) {
                    rest = rest (i == 6 ? "" : " ") $i
                }
                if (rest == cmd) { next }
            }
            { print }
        ' \
        | crontab -

    if [[ "${SCHEDULED_REBOOT_ENABLED}" == "1" ]]; then
        job="0 ${SCHEDULED_REBOOT_HOUR} * * * ${CRON_REBOOT_COMMAND}"
        { crontab -l 2>/dev/null || true; printf '%s\n' "${job}"; } | crontab -
        success "已配置每日 ${SCHEDULED_REBOOT_HOUR}:00 自动重启"
    else
        success "已选择不配置定时重启，并移除脚本托管的每日重启任务"
    fi
}

configure_ipv6_compat() {
    local temp_dir ipv6_file ipv6_disabled
    temp_dir=$(make_temp_dir)
    ipv6_file="${temp_dir}/99-enable-ipv6.conf"

    info "[5/6] 检查 IPv6 兼容状态"

    if [[ ! -d /proc/sys/net/ipv6 ]]; then
        warn "当前内核未暴露 IPv6 sysctl，跳过 IPv6 配置；IPv4 初始化不受影响"
        return 0
    fi

    if [[ -f "${OLD_DISABLE_IPV6_CONF}" ]]; then
        warn "检测到历史禁用 IPv6 配置，正在移除：${OLD_DISABLE_IPV6_CONF}"
        rm -f -- "${OLD_DISABLE_IPV6_CONF}"
    fi

    cat >"${ipv6_file}" <<'EOF'
# 尽力启用 IPv6；没有全局 IPv6 地址不是致命错误。
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.lo.disable_ipv6 = 0
EOF

    install -m 0644 "${ipv6_file}" "${IPV6_SYSCTL_CONF}"
    if ! sysctl -p "${IPV6_SYSCTL_CONF}" >/dev/null; then
        warn "IPv6 sysctl 应用失败，继续按 IPv4-only 场景初始化"
        return 0
    fi

    ipv6_disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 1)
    if [[ "${ipv6_disabled}" != "0" ]]; then
        warn "IPv6 当前仍未启用，可能被内核启动参数禁用；继续按 IPv4-only 场景初始化"
        return 0
    fi

    if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        success "检测到 IPv6 全局地址，双栈网络可用"
    else
        warn "未检测到 IPv6 全局地址，服务器可能未分配 IPv6；继续使用 IPv4"
    fi
}

remove_daily_reboot() {
    { crontab -l 2>/dev/null || true; } \
        | awk -v legacy="${LEGACY_CRON_JOB}" -v cmd="${CRON_REBOOT_COMMAND}" '
            $0 == legacy { next }
            $1 == "0" && $2 ~ /^([0-9]|1[0-9]|2[0-3])$/ && $3 == "*" && $4 == "*" && $5 == "*" {
                rest = ""
                for (i = 6; i <= NF; i++) {
                    rest = rest (i == 6 ? "" : " ") $i
                }
                if (rest == cmd) { next }
            }
            { print }
        ' \
        | crontab -
}

snapshot_system_state() {
    local stamp
    stamp=$(date +%Y%m%d%H%M%S)
    install -d -m 0700 "${BACKUP_DIR}"
    INSTALL_NFT_EXISTED=0
    INSTALL_NFT_SNAPSHOT=""
    INSTALL_CRON_SNAPSHOT="${BACKUP_DIR}/install-crontab.${stamp}.bak"
    INSTALL_SYSCTL_SNAPSHOT=""

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
    INSTALL_ROLLBACK_AVAILABLE=1
}

run_server_initialization() {
    require_root
    info "[1/6] 执行服务器初始化"
    preflight_debian
    install_base_packages
    snapshot_system_state
    install_xanmod_bbr
    configure_daily_reboot
    configure_ipv6_compat
    configure_nftables
}

install_file_if_changed() {
    local source=$1 destination=$2 mode=$3
    if [[ "${source}" == "${destination}" ]]; then
        chmod "${mode}" "${destination}"
        return
    fi
    if [[ ! -f "${destination}" ]] || ! cmp -s "${source}" "${destination}"; then
        install -m "${mode}" "${source}" "${destination}"
    fi
}

register_easy_reality_command() {
    require_root
    [[ -f "${SCRIPT_FILE}" ]] || die "未找到 easy_reality 脚本：${SCRIPT_FILE}"

    install -d -m 0755 "${COMMAND_INSTALL_DIR}" "$(dirname "${COMMAND_PATH}")"
    install_file_if_changed "${SCRIPT_FILE}" "${COMMAND_INSTALL_DIR}/easy_reality.sh" 0755
    ln -sfn "${COMMAND_INSTALL_DIR}/easy_reality.sh" "${COMMAND_PATH}"
    success "已注册命令：${COMMAND_PATH}"
}

install_easy_reality_dependencies() {
    info "[2/6] 安装 easy_reality 运行依赖"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl wget unzip jq openssl ca-certificates
}

rollback_install_side_effects() {
    warn "安装未完成，正在恢复安装前的 nftables、crontab 与 sysctl 配置"
    if [[ "${INSTALL_NFT_EXISTED:-0}" == "1" && -n "${INSTALL_NFT_SNAPSHOT:-}" ]]; then
        install -m 0644 "${INSTALL_NFT_SNAPSHOT}" "${NFT_CONFIG}"
        systemctl restart nftables >/dev/null 2>&1 || true
    elif [[ "${INSTALL_NFT_EXISTED:-0}" == "0" ]]; then
        rm -f -- "${NFT_CONFIG}"
        systemctl disable --now nftables >/dev/null 2>&1 || true
    fi
    if [[ -n "${INSTALL_CRON_SNAPSHOT:-}" && -f "${INSTALL_CRON_SNAPSHOT}" ]]; then
        crontab "${INSTALL_CRON_SNAPSHOT}" 2>/dev/null || crontab -r 2>/dev/null || true
    fi
    if [[ -n "${INSTALL_SYSCTL_SNAPSHOT:-}" && -f "${INSTALL_SYSCTL_SNAPSHOT}" ]]; then
        install -m 0644 "${INSTALL_SYSCTL_SNAPSHOT}" "${SYSCTL_CONFIG}"
        sysctl -p "${SYSCTL_CONFIG}" >/dev/null 2>&1 || true
    fi
}

detect_xray_archive() {
    case "$(uname -m)" in
    x86_64 | amd64) XRAY_ARCHIVE="Xray-linux-64.zip" ;;
    aarch64 | arm64) XRAY_ARCHIVE="Xray-linux-arm64-v8a.zip" ;;
    *) die "Xray 不支持当前架构：$(uname -m)" ;;
    esac
}

download_xray() {
    local version temp_dir archive_url digest_file expected_sha256 actual_sha256
    detect_xray_archive
    version=$(curl -fsSL --retry 3 \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest \
        | jq -er '.tag_name') || die "获取 Xray 最新版本失败"
    temp_dir=$(make_temp_dir)
    archive_url="https://github.com/XTLS/Xray-core/releases/download/${version}/${XRAY_ARCHIVE}"
    digest_file="${temp_dir}/${XRAY_ARCHIVE}.dgst"
    info "下载 Xray-core ${version}"
    curl -fL --retry 3 \
        "${archive_url}" \
        -o "${temp_dir}/${XRAY_ARCHIVE}" || die "下载 Xray-core 失败"
    curl -fL --retry 3 \
        "${archive_url}.dgst" \
        -o "${digest_file}" || die "下载 Xray-core 校验文件失败"
    expected_sha256=$(awk '
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
    ' "${digest_file}")
    [[ "${expected_sha256}" =~ ^[a-f0-9]{64}$ ]] \
        || die "无法解析 Xray-core SHA256 校验值"
    actual_sha256=$(sha256sum "${temp_dir}/${XRAY_ARCHIVE}" | awk '{print $1}')
    [[ "${actual_sha256}" == "${expected_sha256}" ]] \
        || die "Xray-core SHA256 校验失败"
    unzip -jo "${temp_dir}/${XRAY_ARCHIVE}" xray -d "${temp_dir}" >/dev/null \
        || die "解压 Xray-core 失败"
    install -d -m 0755 "${INSTALL_DIR}"
    install -m 0755 "${temp_dir}/xray" "${XRAY_BIN}"
}

read_xray_value() {
    local filter=$1
    [[ -f "${XRAY_CONFIG}" ]] || return 0
    jq -er "${filter} // empty" "${XRAY_CONFIG}" 2>/dev/null || true
}

generate_reality_identity() {
    XRAY_UUID=$(read_xray_value '.inbounds[0].settings.clients[0].id')
    REALITY_PRIVATE_KEY=$(read_xray_value \
        '.inbounds[0].streamSettings.realitySettings.privateKey')
    REALITY_SHORT_ID=$(read_xray_value \
        '.inbounds[0].streamSettings.realitySettings.shortIds[0]')
    XRAY_UUID=${XRAY_UUID:-$("${XRAY_BIN}" uuid)}
    if [[ -z "${REALITY_PRIVATE_KEY}" ]]; then
        local pair
        pair=$("${XRAY_BIN}" x25519)
        REALITY_PRIVATE_KEY=$(awk '/PrivateKey/ {print $NF}' <<<"${pair}")
    fi
    REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
    REALITY_PUBLIC_KEY=$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}" \
        | awk '/Password/ {print $NF}')
    validate_xray_value uuid "${XRAY_UUID}" || die "生成的 UUID 无效"
    validate_xray_value public_key "${REALITY_PUBLIC_KEY}" || die "生成的 REALITY 公钥无效"
    validate_xray_value short_id "${REALITY_SHORT_ID}" || die "生成的 Short ID 无效"
}

write_xray_config() {
    local target=$1
    local server_name=${target%:*}
    local listen_addr temp_dir candidate backup=""
    temp_dir=$(make_temp_dir)
    candidate="${temp_dir}/config.json"
    if ip -6 addr show scope global 2>/dev/null | grep -q "inet6"; then
        listen_addr="::"
        info "检测到全局 IPv6，Xray 将监听 IPv4/IPv6 双栈"
    else
        listen_addr="0.0.0.0"
        info "未检测到全局 IPv6，Xray 将仅监听 IPv4"
    fi

    cat >"${candidate}" <<EOF
{
  "log": {"loglevel": "warning", "error": "${INSTALL_DIR}/error.log"},
  "dns": {"servers": ["localhost"], "queryStrategy": "UseIP"},
  "inbounds": [{
    "tag": "vless-reality-vision",
    "listen": "${listen_addr}",
    "port": ${REALITY_PORT},
    "protocol": "vless",
    "settings": {
      "clients": [{
        "id": "${XRAY_UUID}",
        "email": "vless-reality-vision",
        "flow": "xtls-rprx-vision"
      }],
      "decryption": "none"
    },
    "streamSettings": {
      "network": "raw",
      "security": "reality",
      "realitySettings": {
        "show": false,
        "target": "${target}",
        "xver": 0,
        "serverNames": ["${server_name}"],
        "privateKey": "${REALITY_PRIVATE_KEY}",
        "shortIds": ["${REALITY_SHORT_ID}"]
      },
      "sockopt": {"V6Only": false}
    },
    "sniffing": {
      "enabled": true,
      "destOverride": ["http", "tls", "quic"],
      "routeOnly": true
    }
  }],
  "outbounds": [
    {
      "tag": "direct-dual-stack",
      "protocol": "freedom",
      "settings": {"domainStrategy": "AsIs"},
      "streamSettings": {"sockopt": {
        "domainStrategy": "UseIP",
        "happyEyeballs": {
          "tryDelayMs": 250,
          "prioritizeIPv6": false,
          "interleave": 1,
          "maxConcurrentTry": 4
        }
      }}
    },
    {
      "tag": "ai-ipv4",
      "protocol": "freedom",
      "settings": {"domainStrategy": "ForceIPv4"}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [{
      "type": "field",
      "domain": [
        "domain:claude.ai", "domain:claude.com", "domain:anthropic.com",
        "domain:claudeusercontent.com", "domain:gemini.google.com",
        "domain:bard.google.com", "domain:aistudio.google.com",
        "domain:makersuite.google.com", "domain:ai.google.dev",
        "domain:generativelanguage.googleapis.com", "domain:deepmind.com",
        "domain:deepmind.google", "domain:generativeai.google"
      ],
      "outboundTag": "ai-ipv4"
    }]
  }
}
EOF
    "${XRAY_BIN}" run -test -config "${candidate}" \
        || die "Xray 新配置校验失败"
    if [[ -f "${XRAY_CONFIG}" ]]; then
        install -d -m 0700 "${BACKUP_DIR}"
        backup="${BACKUP_DIR}/xray-config.$(date +%Y%m%d%H%M%S).bak"
        cp -a "${XRAY_CONFIG}" "${backup}"
    fi
    install -m 0600 "${candidate}" "${XRAY_CONFIG}"
    XRAY_CONFIG_BACKUP="${backup}"
}

install_xray_service() {
    cat >"${XRAY_SERVICE_FILE}" <<EOF
[Unit]
Description=Xray VLESS REALITY Vision
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
User=root
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "${XRAY_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable "${XRAY_SERVICE}" >/dev/null
    if ! systemctl restart "${XRAY_SERVICE}" \
        || ! systemctl is-active --quiet "${XRAY_SERVICE}"; then
        if [[ -n "${XRAY_CONFIG_BACKUP:-}" ]]; then
            install -m 0600 "${XRAY_CONFIG_BACKUP}" "${XRAY_CONFIG}"
            systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
        fi
        systemctl status "${XRAY_SERVICE}" --no-pager || true
        die "Xray 启动失败，已尝试恢复原配置"
    fi
}

install_reality() {
    local existing_target target
    info "[5/6] 安装并配置 VLESS REALITY Vision"
    install -d -m 0700 "${STATE_DIR}"
    existing_target=$(read_xray_value \
        '.inbounds[0].streamSettings.realitySettings.target')
    target=$(prompt_value "REALITY 目标域名:端口" \
        "${REALITY_TARGET:-${existing_target:-${DEFAULT_REALITY_TARGET}}}")
    [[ "${target}" == *:* ]] || die "REALITY 目标格式应为 域名:端口"
    validate_domain "${target%:*}" || die "REALITY 目标域名无效"
    [[ "${target##*:}" =~ ^[0-9]+$ ]] \
        && ((10#${target##*:} >= 1 && 10#${target##*:} <= 65535)) \
        || die "REALITY 目标端口无效"
    download_xray
    generate_reality_identity
    write_xray_config "${target}"
    install_xray_service
}

collect_node_state() {
    local prompt_for_host=${1:-false}
    local default_node_host
    load_state
    XRAY_UUID=$(read_xray_value '.inbounds[0].settings.clients[0].id')
    REALITY_PRIVATE_KEY=$(read_xray_value \
        '.inbounds[0].streamSettings.realitySettings.privateKey')
    REALITY_SHORT_ID=$(read_xray_value \
        '.inbounds[0].streamSettings.realitySettings.shortIds[0]')
    REALITY_SNI=$(read_xray_value \
        '.inbounds[0].streamSettings.realitySettings.serverNames[0]')
    [[ -x "${XRAY_BIN}" && -n "${REALITY_PRIVATE_KEY}" ]] \
        || die "请先安装 Reality"
    REALITY_PUBLIC_KEY=$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}" \
        | awk '/Password/ {print $NF}')
    default_node_host="${NODE_HOST:-}"
    if [[ -z "${default_node_host}" ]]; then
        default_node_host=$(detect_public_ipv4 || true)
    fi
    if [[ "${prompt_for_host}" == "true" ]]; then
        warn "节点地址可直接使用当前机器公网 IPv4；如果要 IPv4/IPv6 双栈访问，请填写已正确解析 A 和 AAAA 记录的域名。"
        NODE_HOST=$(prompt_value "节点公网地址（IPv4 或域名）" \
            "${default_node_host}")
    else
        NODE_HOST=${NODE_HOST:-${default_node_host}}
    fi
    [[ -n "${NODE_HOST}" ]] \
        || die "无法自动获取公网 IPv4；请交互输入节点公网地址或设置 NODE_HOST 环境变量"
    validate_node_host "${NODE_HOST}" || die "节点公网地址无效，请输入 IPv4 或域名；双栈请使用已配置 A/AAAA 记录的域名"
    SUB_TOKEN=${SUB_TOKEN:-$(openssl rand -hex 32)}
    WORKER_NAME=${WORKER_NAME:-easy-reality}
}

write_minimal_worker() {
    local destination=$1
    if [[ ! -d "$(dirname "${destination}")" ]]; then
        install -d -m 0700 "$(dirname "${destination}")"
    fi
    cat >"${destination}" <<EOF
const CONFIGS = [];

function defineNode(config) {
  CONFIGS.push(config);
  return config;
}

const VLESS_CONFIG = defineNode({
  uuid: '${XRAY_UUID}',
  host: '${NODE_HOST}',
  name: 'MY_VLESS',
  fp: 'chrome',
  sni: '${REALITY_SNI}',
  pbk: '${REALITY_PUBLIC_KEY}',
  sid: '${REALITY_SHORT_ID}'
});
const DEFAULT_NODE = VLESS_CONFIG;
const PORT_BASE = ${PORT_BASE};
const PORT_MULTIPLIER = ${PORT_MULTIPLIER};
const SUB_PORT_MODE = '${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}';
const SUB_DOWNLOAD_NAME = '${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}';

function dynamicPort() {
  if (SUB_PORT_MODE === '443') {
    return 443;
  }
  const nowUtc8 = new Date(Date.now() + 8 * 60 * 60 * 1000);
  const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
  const hours = Math.floor((nowUtc8.getTime() - yearStart) / 3600000);
  return PORT_BASE + hours * PORT_MULTIPLIER +
    Math.floor(Math.random() * PORT_MULTIPLIER) + 1;
}

function link(cfg, port) {
  const params = new URLSearchParams({
    encryption: 'none',
    security: 'reality',
    type: 'tcp',
    sni: cfg.sni,
    fp: cfg.fp,
    pbk: cfg.pbk,
    sid: cfg.sid,
    flow: 'xtls-rprx-vision',
    packetEncoding: 'xudp'
  });
  return \`vless://\${cfg.uuid}@\${cfg.host}:\${port}?\${params}#\${cfg.name}\`;
}

function encodeBase64(text) {
  const bytes = new TextEncoder().encode(text);
  let binary = '';
  for (let i = 0; i < bytes.length; i += 8192) {
    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
  }
  return btoa(binary);
}

function clashDownloadFilename() {
  return SUB_DOWNLOAD_NAME;
}

function clashProxyNode(cfg, port) {
  return \`  - name: \${cfg.name}
    type: vless
    server: \${cfg.host}
    port: \${port}
    uuid: \${cfg.uuid}
    network: tcp
    tls: true
    udp: true
    flow: xtls-rprx-vision
    servername: \${cfg.sni}
    reality-opts:
      public-key: \${cfg.pbk}
      short-id: \${cfg.sid}
    client-fingerprint: \${cfg.fp}
    packet-encoding: xudp
    ip-version: ipv4-prefer
\`;
}

function clash(configs, ports) {
  const proxyNodes = configs.map((cfg, i) => clashProxyNode(cfg, ports[i])).join('');
  const proxyNames = configs.map(cfg => cfg.name).join('\\n      - ');
  return \`mixed-port: 1080
allow-lan: false
mode: rule
log-level: warning
ipv6: true
dns:
  enable: true
  ipv6: true
  enhanced-mode: fake-ip
  nameserver:
    - https://dns.alidns.com/dns-query
  fallback:
    - https://cloudflare-dns.com/dns-query
proxies:
\${proxyNodes}
proxy-groups:
  - name: PROXY
    type: select
    proxies:
      - \${proxyNames}
rules:
  - DOMAIN-SUFFIX,local,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,google.com,PROXY
  - GEOIP,CN,DIRECT
  - MATCH,PROXY
\`;
}

export default {
  async fetch(request, env) {
    try {
      const url = new URL(request.url);
      if (url.pathname !== '/subscribe') {
        return new Response('Not Found', {status: 404});
      }
      if (!env.SUB_TOKEN || url.searchParams.get('token') !== env.SUB_TOKEN) {
        return new Response('Forbidden', {status: 403});
      }
      const isClash = url.searchParams.get('flag') === 'clash';
      const headers = new Headers({
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        'Content-Type': isClash
          ? 'text/yaml; charset=UTF-8'
          : 'text/plain; charset=UTF-8'
      });
      if (isClash) {
        headers.set('Content-Disposition', 'attachment; filename="' + clashDownloadFilename() + '"');
      }
      const targetConfigs = url.searchParams.get('node') === 'all'
        ? CONFIGS
        : [DEFAULT_NODE];
      const ports = targetConfigs.map(() => dynamicPort());
      const content = isClash
        ? clash(targetConfigs, ports)
        : encodeBase64(targetConfigs.map((cfg, i) => link(cfg, ports[i])).join('\\n'));
      return new Response(content, {
        status: 200,
        headers
      });
    } catch (error) {
      return new Response('Internal Server Error', {status: 500});
    }
  }
};
EOF
    chmod 0600 "${destination}"
}

write_worker() {
    local destination=$1
    local temp_dir template rendered
    local template_b64
    template_b64='H4sIAAAAAAAAA81be3fbxpX/n59iUmcPKZuASL0sU+ttFUqOdWI9VqSa5mR9ZBAYkohAAAEGkhhVe5Q2SvxIYu+uH3Xs1nXcPNqmtruxE8eKku+yFUjpr3yF3pkBQJAEQTZ79pylfCzwzm/u3LlzX4MZDR8/nkDH0eHDj49+s9u4+4F7+T4SUF4zHKWsSRZGrxrWGrZsCmpcvXbw3R3083OzhQJaxpKmkrrX8287b+c1ya6ieUwkdLT7QXP/IXQZTgwPo9OdH6/dffbs6L2r3c2JREI2dJugpcXl4upL04VZdBplM/CZCjfMr5wrzi2dm5tdhuaJKb9TfnHhzNzLBaC9fh6IZUeXiWroSMFlVccLhoJTACyrlSG0lUDw8TqIpmNX/aYp1mJh4lg64rSpxHaCzuZ/ru/AP08Jh5d/1fzVNx7t/+0/TzNM5FU+XVBPSCFcEaRu4hxKrmvYtpNpRnIcVQHS6urKytzM6qpHrRo2YdSzi4ViQNWlGu0+/9oqG8ijlk2gyVXLqGGPYusq61xYmAv6mqU1Rlt66ZWAZntDF9jIie2hYIlnZs9Mw+KvLizOUNMIz2sqEW1xh5+94168ffDsw8bn9xu//T7K6DjvM9OvzK7OLa2emTtXZJZ1AbGPgJInRE3Sk4nwd0OWtBCFfafaiaKJJtGMiqqPiG++KcpGLYQhag2LG6quGBt2VJOuQveKsd5Jl0xTw1EdJFuVIluPizoxRcOqiLLeRjZMrG9YIKRhaD4mBKAUp+ToxOlgGIOH+FB39AjxsqJM44tIsC5jnURNwLGJLGLF6RTTttZBGzr0VAxRx6S9kcBwpibVbSJRn+8CbJaMTU1d71SKbWKsEAw6li3DFjcs0Vw3WecLgc3Nzr80OzMzO7OaPzddOLu6vAJGR63DcsBdcsDrWLdNUcNz/7rj3rvX3P+P5p0nh9//LhKUoFLMLM5Pzy0IhZUzZ+Z+kWZWk56ZW57NF3s1U6MKQ+aWhPzczHI6O3JSzNCf4UmvOa0bgoVtQ1vH7cjMoMCTI2J2gkGzI/2wpyh2koMn+oEnTokj42MDgSfSuVwWxu8j7ES6LGcyudzwyb44PElx2UwEsPeK5qsSeXmpiIbRIvjM9FyvJT2GDj99t3nnJqz90f2nzUsXIUdO64plqAr0VRcLyH34cePi180/P4KW5u09d/8GPDRuvnew9xU8vIpLBUNewwSe3cv3Dn+973674+5+CUHs6Prtw0ePDp5dblz+JMI6ZJCwYjK/Si8tL/7itQgM9XdJjYdIKnMkuR/KsbEFXkI8X+4zZg1bFTzIwLZaiYWVsQT5GVckcF0afvoBJdvGJB45yLAeRjJVGiJ6wmiQAq3URNXoi5EVPXZImYg2RLyKpSqxY25ArWbYsaw4pN+Aaq2ibsYOZRNLNeOXEUQmVj1u/opEJMWoVN9s43MMzXA6Wl6ZR6AjaQ2jxvuX3PefQyg92P++ef3z5pUvmn++0vj9N0D54dv3D7655159RF3k2afoTccgkojcv1yDxvCor8y+9uri8ky6ZEGexZbAWXdJR/1H07BeAbOSg0I4cqrpqlMrtRJtd7tpGQqYKNizVV8fCdleTHzRJEfBECKmdQJ1k6nKg0UYCBMz2F4jhgl986ziQtOmSaPO0lwQWCB6oCCyoBJYVAW3CaxJpGxYNZg5FSN6VrybBxnU+z2GktoP0W4LfIoI3A3mIAn+b7Bg+O35IjzVZFMAZW/WUfMvl0Kq67YCbzDJhwwgdPQUey/hNDUI1Pzv75r3H7oX3208fbv3Ei5Z6jpEMNhPQeGCDp8+Pth70Lz27g/fXgzMCrl3P0cvzy4W5oqz6fwC2PvR3R3YjLmXPmhc+bRx8U8/fHspaoa0PyQ04CtKa1JNUt/C8fGjrUdPo45C9/GTqC5lySZaXcBKn2wQ7lOT7DUumaDodttcjnlad3e/Oti/zautXtzYeD2LKx/SHwFeosegJFODQNp3MJsYVh+RwNqFASRXeV09ICZWeA4TwlYfrw6BdVhT+2BrfaZQeytUc3io3o42r9KK3SiTAZ2thT988ql79WsaFq/dbT75GB4Wy2VVxjR88NcgIVe80/xyr7l3DyzqaOejxs5njQc7jadX3P98v3HnSePm457GVvOHizXwkqrHVxz+lqV3weTA1tJYi8foWLH6MmI6GAAyOjEen/urEApMQ+2TE2p2mYCJ6VgmfP8VZxreBtkxoWzAg9nHy7im6irkw5cNowLBoX+17ncJcmqrZ4E4impQEodAWkXu1cvu8+tQkLjXPoRCPpwkKwwF23bav0celSwlFkALYTpoLKgm0Rd0jgpKieflNyt4vbu5gnVsgeetQ6DVK45U8blBxo0uKaELlEmWYEp9kZCZJZnyLklQd+jKIH0kbU3SVBliI0XLmgpxyJ6InyLr0tLHwB03cAmKPrBDTfixPIKaFmMTFl4ZDMQZ9sS1FiVYvb7Fh2ewNA/u3fTe6PYw+q7h+k+vz6pFwfQ+qEELyMoAu9HKOsn2A4zEAypmtY8cTOq3VDO2luKodVXBRiy3OgRvpxSv9Drx64h+i18gWKoNmAzdO/tHt3fdG++6z29BiGz+4TvYYYULUJsyC63Mj6xDGRvT2MAWjvcKb7xazdFVUu/YB/CZHTy7cri/j/IzC6hn1u0Uu3dG4ciqqksD4DrNtG/y4R4YqMh98Ljxmw8HdUVTqpuSFqsuDjFKb0D2jPfG1gvOlsX2lruINVyxQNlzS6jx8CkYQuO3nzSeX/vh249oNBaJ1053s8P0fZljydgellXFEskmASPoOUf/td+prJjNjIv0VWFmeGSUi9TrHSEDT4pjFDoyEHRycGh25B/ATgyOHckMjh0fhG927JSYHR8DIRjnTB/05Lh4cgI6ZCl4rBscs/6Hu98dPnyEpgsLvY0VxoH2dHZ0ZCQz+g+9PvXiB4qPTkIQZyrYoG+76ft84YW2XNKKRAMUgrOLYM3u7l33+Y3YMeeWWvwGm1Dj7k5z72I/1vPTxfxZT/jWqQI/TOBHV6vF2fmlc9NFeqR1oaZuYqiSDIvkEJhIJiFpmrEhQGmWQ2VJs3GiZig4h+jxQ0IzKgKkGqzlkKqXjYRqrk/kELEcnMCbBFu6pLGNnGXQei2Hkv4JQTZ3KnMqk0xAvC2rMJ5CN9leTyjZyqqG6dEGQmyLKtjg+DLBiodIHPMPQ91799xrH7i3dhsffgzhoqZWjZpB30IFR8IQFP5XJ5g2SFgG2Zk0WJdKIBmXgh0yGhCB6BsBoQZ7UdhOhdpMybKhiHNAftUM0Y11bFmQnWHSNoEMQA0s1MwG5MMhdLZYXPKfgSOsip1Dr09m0mgS1kaYnJzMnA+a+zBGqHiu0M1sbGwUuMH/PqN/XZnLx8Ja6i+uLHhH6v8nyu+zNMTReywL1GvyWg4xW2YEySHgUVDwhFGMqGACpiWwF+JlSQ63q5CzxgRJUcAVbV8jAsqegoBMT5myw6OZADjRDSwrZZxT5JKUOzV58iQ/QppgrdRgquobVMgALen13Pho8JXIZm54OESk771BUG8S3BUTwKiHCkKuyJbRwmDFQnXU70qJUFgI9CzPDgEpza5D3VHraoLZmVRX/OSxRddgr4j1Nu8eHx0dTyb4XHFZcjQi0FN6KGTWfV+ikxwZGRXH6U9LudlT4oj3LyDSvAo/CW8mxmZd4JwimVYJMW3QXcB8mKr7TQdb9S4MfZcHmy76C8qYEJAhj7UOUXmgOXj+h+bebf5OBs0sFGgh+vb37u4H7u4X7u5f0YxxFjVu/b7x5Y3Dzx40fnetcfcL9+5j3pdxbMkLIRb2mHVfbO+MP4e47kNUdtIf0L3Fhi2jDGGTh+IybBkhxPCAxJ8FC7bS0BSy1exENwAspM1IJ6iRToy1ASEWE6reLUpYVc1VTthOdEyoewF6KrcLaFRF0ynFIKLW0pNS00ptfuR3gQqH/sQwzXJj7WMefDsVA2q9gRZ62JEvZKBL5H2gxGhLDQENsiZd2fxCQFZNWua2ujL3GfOP0cfa6D51dKSNHLhnuEExapKqt/MFs2ttyJPRTf5GvKuZBtGS906wqzG05+xqIxsqAe1Ej6mSqlPiTbRA2FTp3YctFgtWddCVvc3pdaECEdL0ouIxdLTzUfP653xj2dx7B3YSjUtX3MufH+1calz5Y4IPwC8Q+fUd/fAbSbzs8EjBqC3B/PGpD8D4WywwrtqY3fvaZtVW9L0t7y7Qj0l6wbWykqNqCku1P6f3puh1qiKu0VM0nPJvmHn3yC60JrlFf20nWnNkl654guFujLZo3OcQXgZu0V+cwK9lbdFfnACZjx7s5mi+4ly1tmyihM3bXqOWjS0iwEBquR7ORWWoMnNoE7oLlmltCuuqDbMMCebJD+XRtjc3dg1QMEwSLAoEEQiqwhquU6lLa9se3a7CDAQmuu1Lzl+tgUtCHIQRoQCA1rLpTZy+LSQC1sEPWVW3CTPx8ioV3malFeTYMYFnVi5ozdn0ReEJWfGneMG/xdddxh9+t+te/qP73n7jxuOo62HBilcwOQtb3rzh6CRYYmDpXr3p7v8XbPTRSjF/YhIy0FdHt55Abjp8eL/58Nbhe3+izd88cXd/3bj1KcpkcpkMOnz6dfOjd5pPHgHIfXwV+sDwXDFsg6AbGytEnoQtgY436Lk4TtH/RKDD2CfQJDqOJjL+f/SSpHd3kXevY8kqEMkiwID1A9FSHk8RJgJfzzia9hrAUkNpBAVttq0/7AdMGyvzNhWg1a2o1qh1Cy3+bRcm5yVSFcGSDCvVYjCMUh2CDrHFCPQKCVZ2qN/M1MHIVHkJjCVV9TUdUvTRR1cbd5+7b19tfraHsv8+ER66dWX0BGp1hhE7roxS3YXEZI+QiyEMw7xASNqebZePWSFeWZ7LGzXT0MFq8w7si2opKAk7PL0bykCihSEwyDg1/PoLydTQ8fPDlTSS0el/Qcl/SsKAsihXJZBYwdMklRkSiVGAalOvpLITXcoCvyP4nKqvpeQycKGxwReCLx3se6Sa7RnOyvK5AiyVXF1iVO/CJ3cQ2aqbfI+S1EFW7/Yl93jZscC5ocVz81Cjd1sUAk64B73bCQKJ8NCi0juglFg2WzR245MS4SHUnwYH1l9VQv1ZUEp2RqXQuDxQzAZxIkkDBU9f2+2XeS+wSAv1wotbdBwWQn/Gn1nAzfFnqk/0y18yvW7/9MUtrs3WigxtH3txq6dFUA40UA5tX2hftpJk44kxJicO2w1fslKdYH/FirBz5zjwTBG3evDZaPTyBmwurTrgk8mwz8pVR18rqG9haJnMnhqZ8rfIKEV7qUDOTMGvf+bjifSmC6lSyonTrc6+ZPTjDXSCvl6msxfLllHLe6bKjuPrKR3CSNrjaDslybKkekpNU64hpp702+EVKRFDSvEhhnqHZ76b5bvc5vV7jYvX+gRpdnCCWbclWh/wm9+dvuLLEJfFAz20/Jfnb+a+/lJHoZhF+Sj6JRLFbIyiPNvqtL+hyF7Mcn3e9EskiuZpHwTP0eNDhvYx8BzNJzSY3WMsyNo+pGx2xKu29cizC/XzsB1VvQv3Nl8V+MWKt0LLM6jJmv762V3Gzpto5edf+O9l7N5ALXM/cSJs46ExwM57mQ/n8bp63pMXnjyTbvGgwoT/mICCuIn4xh+2vMg3gN3aTXbu+5LpjqvqEUuSbKvMoUdrknFoVkcHaDadNwxVTyX/Tfc7wW4gyiqTHbV3MrSevV3b+wsTdPBsz939xL36IMqz8SZzCe81hrdwkl3XZVTGRK6mLAxbPZukIaOtgxGSzfDqEghfrW8t83EsrZUhfRYiUEOrSj9qGaWAKppQJ1D9oBdA7uQwBDpbttQSTg51sA+tMOW+jG1IEDZoaMEg6AzUJAroZou+ISMOVOpjmbEgUfkfz07aBQ6yOpXGDqX0qQgwMdawDlgveUHhlkoyWnJoKtE1vxdAcWJh5aXV4uIrsws0+PD+dKptTQPPdSwzCnO1SqqiwJjt8x0dbL6woa90zICSQN8gnx8K2rtQa+/oQklxXaDMsSB7B2U9Ot1R5Xeoi4YWqHoBw0OZ3W0tXApqJZKmRZpHGwMY0fs7pA6lQAlu4wF6vx7+o5jznZrtnjILX9CvjY9Yk8xUahWy9hCtSiMr8i5dnQB0p4L4GFUsKdSxuYed5d9S3XNJ5iW5ioU8P6JIskJUYEcOaVhNQaataVSD2kqw8Dp9lwUyefGpjVKTNgWpgk9nQqVhMMiSJVVqksed8YxCzW6aqoVtCovkMi3LUCD4sgrT7Fhm0VIrKn1tmDwe1SfPT42FGRU8w1ZpaAQsN21qITLNMkn0U7AVQkCwGoCnED19obHm9E/8P6kS61JN+0kSwTiqrqlQq7cvc5RXd44SZYmeE3ipmYqKTvfO2G0WE+TtqL+P6XBw+vFMAkIXuKWvlyJsJSA8JAnUvMN0jlOIboQAc3qleEaYTEYwigo44RnQaOPbX1ek6eVUXBGg2bUersHqR885InZgrB74UbOG/KnqP3LabZsKJnyQryFLxyoi+LYNzg5ZFKWwZRlWp5FEjXphliJzCLZB9EGEMsEG39u+EI7z45lM26DbXgW0PZX4OzsZc6F5OgAA'
    temp_dir=$(make_temp_dir)
    template="${temp_dir}/worker-template.js"
    rendered="${temp_dir}/worker.js"
    if ! printf '%s' "${template_b64}" | openssl base64 -d -A | gzip -dc >"${template}" \
        || [[ "$(sha256sum "${template}" | awk '{print $1}')" != "${WORKER_TEMPLATE_SHA256}" ]]; then
        [[ "${ALLOW_MINIMAL_WORKER_FALLBACK:-0}" == "1" ]] \
            || die "完整 Worker 模板解码或校验失败，已停止生成订阅"
        warn "完整 Worker 模板解码失败，按显式开关改用最小订阅模板"
        write_minimal_worker "${destination}"
        return
    fi
    awk \
        -v uuid="${XRAY_UUID}" \
        -v host="${NODE_HOST}" \
        -v sni="${REALITY_SNI}" \
        -v pbk="${REALITY_PUBLIC_KEY}" \
        -v sid="${REALITY_SHORT_ID}" \
        -v mode="${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}" \
        -v download="${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}" '
      {
        gsub(/__UUID__/, uuid)
        gsub(/__HOST__/, host)
        gsub(/__SNI__/, sni)
        gsub(/__PBK__/, pbk)
        gsub(/__SID__/, sid)
        gsub(/attachment; filename="MY_VLESS.yaml"/, "attachment; filename=\"" download "\"")
        if (mode == "443") {
          gsub(/const ports = targetConfigs\.map\(\(_, i\) => calculateDynamicPort\(currentHourCount \+ i\)\);/, "const ports = targetConfigs.map(() => 443);")
        }
        print
      }
    ' "${template}" >"${rendered}"
    if [[ -d "$(dirname "${destination}")" ]]; then
        :
    else
        install -d -m 0700 "$(dirname "${destination}")"
    fi
    install -m 0600 "${rendered}" "${destination}"
}

cloudflare_api() {
    local method=$1
    local endpoint=$2
    local header_file
    shift 2
    header_file=$(mktemp "${RUNTIME_TMP}/cf-header.XXXXXX")
    cleanup_files+=("${header_file}")
    chmod 0600 "${header_file}"
    printf 'Authorization: Bearer %s\n' "${CF_API_TOKEN}" >"${header_file}"
    curl -sS --retry 3 -X "${method}" \
        -H @"${header_file}" \
        "https://api.cloudflare.com/client/v4${endpoint}" "$@"
}

deploy_worker() {
    local metadata response subdomain temp_dir worker_module_file
    CF_ACCOUNT_ID=${CF_ACCOUNT_ID:-}
    CF_API_TOKEN=${CF_API_TOKEN:-}
    CF_ACCOUNT_ID=$(prompt_value "Cloudflare Account ID" "${CF_ACCOUNT_ID}")
    if [[ -z "${CF_ACCOUNT_ID}" ]]; then
        fail "Cloudflare Account ID 不能为空"
        return 1
    fi
    if [[ -z "${CF_API_TOKEN}" && -t 0 ]]; then
        info "API Token 仅需 Cloudflare Account / Workers Scripts / Edit 权限"
        info "Cloudflare API Token 不会保存为默认值，也不会写入 ${STATE_FILE}"
        read -r -s -p "Cloudflare API Token: " CF_API_TOKEN
        printf '\n'
    fi
    if [[ -z "${CF_API_TOKEN}" ]]; then
        fail "Cloudflare API Token 不能为空"
        return 1
    fi
    export -n CF_API_TOKEN 2>/dev/null || true
    WORKER_NAME=$(prompt_value "Worker 名称" "${WORKER_NAME}")
    if ! validate_worker_name "${WORKER_NAME}"; then
        fail "Worker 名称格式无效"
        return 1
    fi

    metadata=$(jq -cn \
        --arg token "${SUB_TOKEN}" \
        '{
          main_module: "worker.js",
          compatibility_date: "2024-09-23",
          bindings: [{type: "secret_text", name: "SUB_TOKEN", text: $token}]
        }')
    temp_dir=$(make_temp_dir)
    worker_module_file="${temp_dir}/worker.js"
    install -m 0600 "${WORKER_FILE}" "${worker_module_file}"
    grep -q 'export default' "${worker_module_file}" \
        && grep -q 'async fetch' "${worker_module_file}" \
        || {
            fail "生成的 Worker 缺少 export default fetch 入口"
            return 1
        }
    response=$(cloudflare_api PUT \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}" \
        -F "metadata=${metadata};type=application/json" \
        -F "worker.js=@${worker_module_file};type=application/javascript+module") \
        || return 1
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        jq -r '.errors[]?.message' <<<"${response}" >&2
        return 1
    }

    response=$(cloudflare_api POST \
        "/accounts/${CF_ACCOUNT_ID}/workers/scripts/${WORKER_NAME}/subdomain" \
        -H 'Content-Type: application/json' \
        --data '{"enabled":true,"previews_enabled":false}') || return 1
    jq -e '.success == true' <<<"${response}" >/dev/null || {
        jq -r '.errors[]?.message' <<<"${response}" >&2
        return 1
    }
    response=$(cloudflare_api GET \
        "/accounts/${CF_ACCOUNT_ID}/workers/subdomain") || return 1
    subdomain=$(jq -er '.result.subdomain' <<<"${response}") || return 1
    WORKER_URL="https://${WORKER_NAME}.${subdomain}.workers.dev"
    unset CF_API_TOKEN
}

verify_subscription() {
    [[ -n "${WORKER_URL}" ]] || return 0
    local code attempt
    for attempt in 1 2 3 4 5; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 \
            "${WORKER_URL}/subscribe?token=${SUB_TOKEN}" || true)
        if [[ "${code}" == "200" ]]; then
            return 0
        fi
        warn "订阅验收第 ${attempt} 次返回 HTTP ${code}"
        sleep 2
    done
    return 1
}

choose_subscription_mode() {
    local choice=${SUBSCRIBE_MODE:-}
    if [[ -z "${choice}" && -t 0 ]]; then
        printf '请选择订阅输出方式：\n'
        printf '  1. 自动部署 Cloudflare Worker（默认）\n'
        printf '  2. 输出 Worker 内容，手动部署\n'
        printf '  3. 只输出完整 VLESS 参数\n'
        read -r -p "请选择 [1]（回车默认 1）: " choice
        choice=${choice:-1}
    fi
    choice=${choice:-worker}

    case "${choice}" in
    1 | auto) SUBSCRIBE_MODE="auto" ;;
    2 | worker | manual) SUBSCRIBE_MODE="worker" ;;
    3 | vless | link) SUBSCRIBE_MODE="vless" ;;
    *) die "无效的订阅输出方式：${choice}，请输入 1、2 或 3" ;;
    esac
}

configure_subscription() {
    info "[6/6] 配置订阅输出"
    choose_subscription_mode
    if [[ "${SUBSCRIBE_MODE}" != "vless" && "${SUB_PORT_MODE_LOCKED:-0}" != "1" ]]; then
        choose_subscription_port_mode
        require_dynamic_port_redirect
    fi
    collect_node_state true
    case "${SUBSCRIBE_MODE}" in
    auto)
        choose_subscription_download_name
        write_worker "${WORKER_FILE}"
        if deploy_worker; then
            DEPLOY_MODE="auto"
            success "Worker 已部署：${WORKER_URL}"
            if verify_subscription; then
                success "Worker 已通过 HTTP 验收"
            else
                warn "Worker 已部署，但 HTTP 验收未通过；订阅信息仍会保存，请稍后重试或手动打开 URL 检查"
            fi
        else
            WORKER_URL=""
            DEPLOY_MODE="worker"
            warn "自动部署失败，已保留 Worker 文件供手动部署"
        fi
        ;;
    worker)
        choose_subscription_download_name
        write_worker "${WORKER_FILE}"
        WORKER_URL=""
        DEPLOY_MODE="worker"
        success "Worker 内容已生成：${WORKER_FILE}"
        print_worker_content
        ;;
    vless)
        WORKER_URL=""
        DEPLOY_MODE="vless"
        success "已选择只输出完整 VLESS 参数"
        ;;
    esac
    save_state
    show_subscription
}

print_worker_content() {
    printf '\nWorker 内容如下，请复制到 Cloudflare Worker：\n'
    printf '%s\n' '----- BEGIN easy_reality Worker -----'
    cat "${WORKER_FILE}"
    printf '\n%s\n\n' '----- END easy_reality Worker -----'
}

show_node() {
    collect_node_state false
    printf '\n%s\n\n' "$(build_vless_link)"
}

build_vless_link() {
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#MY_VLESS' \
        "${XRAY_UUID}" \
        "${NODE_HOST}" \
        "${REALITY_PORT}" \
        "${REALITY_SNI}" \
        "${REALITY_PUBLIC_KEY}" \
        "${REALITY_SHORT_ID}"
}

show_subscription() {
    local vless_link=""
    collect_node_state false
    vless_link=$(build_vless_link)
    printf '\n完整 VLESS 节点:\n%s\n' "${vless_link}"
    if [[ "${DEPLOY_MODE:-worker}" == "vless" ]]; then
        printf '\n当前模式: 只输出 VLESS 参数\n\n'
        return
    fi

    printf '\nWorker 文件: %s\n' "${WORKER_FILE}"
    printf '订阅 Token: %s\n' "${SUB_TOKEN:-未生成}"
    printf 'Clash 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
    if [[ -n "${WORKER_URL:-}" ]]; then
        printf '\n订阅地址:\n'
        printf '通用订阅: %s/subscribe?token=%s\n' "${WORKER_URL}" "${SUB_TOKEN}"
        printf 'Clash Meta: %s/subscribe?token=%s&flag=clash\n' \
            "${WORKER_URL}" "${SUB_TOKEN}"
    fi
    if [[ "${DEPLOY_MODE:-worker}" == "worker" ]]; then
        printf '\n部署方式: 手动部署；请在 Worker 中设置加密变量 SUB_TOKEN。\n'
        printf '部署命令: npx wrangler deploy %q --name %q\n' \
            "${WORKER_FILE}" "${WORKER_NAME:-easy-reality}"
        printf '密钥命令: npx wrangler secret put SUB_TOKEN --name %q\n' \
            "${WORKER_NAME:-easy-reality}"
    fi
    printf '\n'
}

show_status() {
    load_state
    printf 'Xray: '
    if systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi
    printf 'nftables: '
    if systemctl is-active --quiet nftables 2>/dev/null; then
        printf 'active\n'
    else
        printf 'inactive\n'
    fi
    printf 'XanMod kernel: %s\n' "$(uname -r)"
    printf 'BBR: %s\n' "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)"
    printf 'Worker URL: %s\n' "${WORKER_URL:-未记录}"
    printf '订阅暴露端口模式: %s\n' "${SUB_PORT_MODE:-${DEFAULT_SUB_PORT_MODE}}"
    printf 'Clash 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"
}

update_xray() {
    require_root
    local temp_dir backup
    temp_dir=$(make_temp_dir)
    backup="${temp_dir}/xray"
    [[ -x "${XRAY_BIN}" && -f "${XRAY_CONFIG}" ]] || die "Xray 尚未安装"
    cp -a "${XRAY_BIN}" "${backup}"
    download_xray
    if ! "${XRAY_BIN}" run -test -config "${XRAY_CONFIG}" \
        || ! systemctl restart "${XRAY_SERVICE}" \
        || ! systemctl is-active --quiet "${XRAY_SERVICE}"; then
        install -m 0755 "${backup}" "${XRAY_BIN}"
        systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
        die "Xray 更新失败，已恢复原核心"
    fi
    success "Xray-core 已更新"
}

latest_backup() {
    local pattern=$1
    ls -t ${pattern} 2>/dev/null | head -n 1 || true
}

restore_system_changes() {
    local nft_backup sysctl_backup
    nft_backup=$(latest_backup "${BACKUP_DIR}/*nftables.conf.*.bak")
    sysctl_backup=$(latest_backup "${BACKUP_DIR}/install-sysctl-bbrv3.*.bak")

    if [[ -n "${nft_backup}" ]]; then
        install -m 0644 "${nft_backup}" "${NFT_CONFIG}"
        systemctl restart nftables >/dev/null 2>&1 \
            || warn "nftables 配置已恢复，但服务重启失败，请手动检查"
        success "已恢复 nftables：${nft_backup}"
    else
        warn "未找到 nftables 备份，跳过恢复"
    fi

    remove_daily_reboot || warn "移除每日重启任务失败，请手动检查 crontab"
    success "已移除 easy_reality 每日重启任务"

    if [[ -n "${sysctl_backup}" ]]; then
        install -m 0644 "${sysctl_backup}" "${SYSCTL_CONFIG}"
        sysctl -p "${SYSCTL_CONFIG}" >/dev/null 2>&1 \
            || warn "sysctl 配置已恢复，但运行时应用失败，请手动检查"
        success "已恢复 sysctl：${sysctl_backup}"
    else
        warn "未找到 sysctl 备份，跳过恢复"
    fi
    warn "XanMod 内核包不会自动卸载；如需移除，请手动确认当前启动内核后处理"
}

uninstall_reality() {
    local mode=${1:-}
    local answer=
    require_root
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "无人值守卸载需要设置 FORCE=1"
        read -r -p "确认删除 Xray、订阅状态和本机 Worker 文件？[y/N]: " answer
        [[ "${answer}" == "y" || "${answer}" == "Y" ]] || return 0
    fi
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${XRAY_SERVICE_FILE}"
    rm -f -- "${XRAY_CONFIG}" "${XRAY_BIN}" "${INSTALL_DIR}/error.log"
    rm -f -- "${STATE_FILE}" "${WORKER_FILE}"
    systemctl daemon-reload
    success "Xray 与 easy_reality 本机状态已删除"
    if [[ "${mode}" == "--restore-system" || "${RESTORE_SYSTEM:-0}" == "1" ]]; then
        restore_system_changes
    else
        warn "nftables、XanMod、BBR、定时重启及已部署的 Cloudflare Worker 未改动；备份保留在 ${BACKUP_DIR}"
    fi
}

install_all() {
    require_root
    load_state
    choose_subscription_mode
    if [[ "${SUBSCRIBE_MODE}" == "vless" ]]; then
        SUB_PORT_MODE="443"
    else
        choose_subscription_port_mode
    fi
    INSTALL_ROLLBACK_ON_EXIT=1
    run_server_initialization
    install_easy_reality_dependencies
    SUB_PORT_MODE_LOCKED=1
    install_reality
    configure_subscription
    INSTALL_ROLLBACK_ON_EXIT=0
    register_easy_reality_command
    success "Reality 一键安装完成"
    if [[ "$(uname -r)" != *xanmod* ]]; then
        warn "需要重启后才会进入 XanMod BBRv3 内核"
    fi
}

usage() {
    cat <<EOF
用法: $0 [命令]

  install       一键初始化系统、安装 Reality 并配置订阅（默认）
  update-sub    重新配置订阅输出、Worker 或 VLESS 参数
  update-xray   更新 Xray-core
  show          显示 Reality 节点链接
  subscription  显示订阅信息
  status        显示服务状态
  register-command
                注册系统命令 easy_reality
  uninstall     删除 Xray 和本机订阅状态
  uninstall --restore-system
                删除 Xray，并恢复最近备份的 nftables/sysctl，移除每日重启
  help          显示帮助

无人值守变量:
  REALITY_TARGET, NODE_HOST, SUBSCRIBE_MODE=auto|worker|vless
  CF_ACCOUNT_ID, CF_API_TOKEN, WORKER_NAME, SUB_PORT_MODE=443|dynamic
  SUB_DOWNLOAD_NAME=MY_SUB

说明:
  NODE_HOST 为客户端连接本机 Reality 节点使用的公网 IPv4 或域名；不提供时默认探测当前机器公网 IPv4。
  若需要 IPv4/IPv6 双栈访问，NODE_HOST 必须填写已正确解析 A 和 AAAA 记录的域名。
  SUB_PORT_MODE 控制订阅暴露端口，默认 443；dynamic 会生成 10000-65535 动态端口并配置 nftables 转发到 443。
  SUBSCRIBE_MODE 控制订阅输出：auto 自动部署 Worker，worker 输出 Worker 内容，vless 只输出完整 VLESS 参数。
  SUB_DOWNLOAD_NAME 控制 Clash 订阅下载显示名，默认 MY_SUB；内容格式仍是 YAML。
  WORKER_TEMPLATE_SHA256 是脚本内置 Worker 模板校验值，不需要用户配置。
EOF
}

main() {
    case "${1:-install}" in
    install) install_all ;;
    update-sub) require_root; configure_subscription ;;
    update-xray) update_xray ;;
    show) require_root; show_node ;;
    subscription) require_root; show_subscription ;;
    status) require_root; show_status ;;
    register-command) register_easy_reality_command ;;
    uninstall) uninstall_reality "${2:-}" ;;
    help | -h | --help) usage ;;
    *) usage; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
