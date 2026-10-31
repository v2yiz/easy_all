#!/usr/bin/env bash

# Mieru (mita) direct profile for the unified easy_all launcher.
#
# The profile sticks to the upstream workflow documented by the mieru project:
# install the official mita Debian package from GitHub Releases, then write the
# server configuration with `mita apply config` and start the proxy with
# `mita start`. No TLS certificate, static site, subscription or quota is used.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'mieru-direct.sh 是 easy_all 的 Mieru 直连 Profile；请使用：easy_all install\n' >&2
    exit 2
fi

readonly MIERU_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_DIR="${MIERU_PROFILE_ROOT}/../lib"

readonly STATE_DIR="/etc/easy_all"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly MIERU_DIR="${STATE_DIR}/mieru"
# The shared runtime still imports Xray helpers; the Mieru profile never uses them.
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_DIR}/xray"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly MIERU_SERVER_CONFIG="${MIERU_DIR}/server_config.json"
readonly MIERU_CLIENT_CONFIG="${MIERU_DIR}/client_config.json"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly ENTRY_COMMAND_NAME="${EASY_ALL_ENTRY_COMMAND:-easy_all}"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
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
readonly DEFAULT_REBOOT_HOUR="4"
readonly MIERU_SERVICE="mita.service"
readonly MIERU_PACKAGE="mita"
readonly MIERU_RELEASES_API="https://api.github.com/repos/enfein/mieru/releases/latest"
readonly MIERU_RELEASE_BASE="https://github.com/enfein/mieru/releases/download"
readonly MIERU_PACKAGE_ARCH="amd64"
readonly MIERU_MTU="1400"
readonly MIERU_MULTIPLEXING="MULTIPLEXING_LOW"
readonly MIERU_TRANSPORT="TCP"
readonly DEFAULT_MIERU_NODE_NAME="MY_MIERU"
readonly DEFAULT_MIERU_PORT="2090"
readonly DEFAULT_MIERU_PORT_RANGE="50000-50512"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly CRON_DYNAMIC_PORT_MARKER="# easy_all-managed-dynamic-ports"
readonly STATE_SCHEMA_VERSION="1"
readonly MIN_COMPATIBLE_STATE_VERSION="1"

MIERU_DOWNLOAD_VERSION=""
MIERU_DOWNLOAD_PACKAGE=""
MIERU_PORT_RANGE=""
MIERU_TRAFFIC_PATTERN_JSON=""

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
    [[ "$1" == "mieru" ]]
}

choose_protocol() {
    local requested=${1:-${PROTOCOL:-}}
    requested=${requested:-mieru}
    case "${requested}" in
    4 | mieru | mieru-direct) PROTOCOL="mieru" ;;
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

mieru_host_is_valid() {
    validate_ipv4 "$1" || validate_domain "$1"
}

mieru_validate_node_state() {
    local host=${NODE_HOST:-}
    if ! validate_ipv4 "${host}"; then
        host=$(normalize_domain "${host}")
    fi
    mieru_host_is_valid "${host}" \
        || die "Mieru 连接地址无效（需为 IPv4 或 DNS only 域名）：${NODE_HOST:-空}"
    NODE_HOST=${host}
    [[ -n "${NODE_NAME:-}" && ${#NODE_NAME} -le 64 ]] \
        || die "状态文件中的节点名称无效"
}

mieru_validate_port_state() {
    [[ "${MIERU_PORT:-}" =~ ^[0-9]+$ ]] \
        && ((10#${MIERU_PORT} >= 1025 && 10#${MIERU_PORT} <= 65535)) \
        || die "Mieru 端口无效（应为 1025-65535）：${MIERU_PORT:-空}"
}

mieru_validate_port_range_state() {
    local begin end
    [[ "${MIERU_PORT_RANGE:-}" =~ ^([0-9]+)-([0-9]+)$ ]] \
        || die "Mieru 端口范围无效（应形如 50000-50512）：${MIERU_PORT_RANGE:-空}"
    begin=${BASH_REMATCH[1]}
    end=${BASH_REMATCH[2]}
    ((10#${begin} >= 1025 && 10#${end} <= 65535 && 10#${begin} <= 10#${end})) \
        || die "Mieru 端口范围无效（应形如 50000-50512）：${MIERU_PORT_RANGE}"
}

mieru_validate_user_state() {
    [[ "${MIERU_USER_NAME:-}" =~ ^[A-Za-z0-9._~-]{1,64}$ ]] \
        || die "Mieru 用户名无效：需为 1-64 位字母、数字或 . _ ~ -"
    [[ "${MIERU_USER_PASSWORD:-}" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] \
        || die "Mieru 密码无效：需为 8-64 位字母、数字或 . _ ~ -"
}

mieru_validate_client_ports_state() {
    local socks5=${MIERU_CLIENT_SOCKS5_PORT:-} http=${MIERU_CLIENT_HTTP_PORT:-} rpc=${MIERU_CLIENT_RPC_PORT:-} port
    for port in "${socks5}" "${http}" "${rpc}"; do
        [[ "${port}" =~ ^[0-9]+$ ]] \
            && ((10#${port} >= 1025 && 10#${port} <= 65535)) \
            || die "状态文件中的 Mieru 客户端端口无效：${port:-空}"
    done
    [[ "${socks5}" != "${http}" && "${socks5}" != "${rpc}" && "${http}" != "${rpc}" ]] \
        || die "状态文件中的 Mieru 客户端端口重复"
}

mieru_validate_traffic_state() {
    [[ "${MIERU_TRAFFIC_SEED:-}" =~ ^[0-9]+$ ]] \
        && ((10#${MIERU_TRAFFIC_SEED} >= 1 && 10#${MIERU_TRAFFIC_SEED} <= 2147483647)) \
        || die "Mieru traffic-pattern seed 无效"
    [[ "${MIERU_TRAFFIC_PATTERN:-}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
        || die "Mieru traffic-pattern 无效"
}

load_state() {
    local variable
    local -a variables=(
        PROTOCOL TCP_ACCELERATION NODE_NAME NODE_HOST MIERU_PORT MIERU_PORT_RANGE
        MIERU_USER_NAME MIERU_USER_PASSWORD MIERU_VERSION
        MIERU_TRAFFIC_SEED MIERU_TRAFFIC_PATTERN
        MIERU_CLIENT_SOCKS5_PORT MIERU_CLIENT_HTTP_PORT MIERU_CLIENT_RPC_PORT
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
        || die "状态协议不是 mieru；请重新安装"
    if [[ -f "${STATE_FILE}" ]]; then
        mieru_validate_node_state
        mieru_validate_port_state
        mieru_validate_port_range_state
        mieru_validate_user_state
        mieru_validate_client_ports_state
        mieru_validate_traffic_state
        [[ "${MIERU_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){2}$ ]] \
            || die "状态文件中的 mita 版本无效；请重新运行 easy_all update-core"
    fi
    TCP_ACCELERATION=$(normalize_tcp_acceleration "${TCP_ACCELERATION:-bbrv3}") \
        || die "状态文件中的 TCP_ACCELERATION 无效"
}

save_state() {
    enforce_ipv4_only_policy
    mieru_validate_node_state
    mieru_validate_port_state
    mieru_validate_port_range_state
    mieru_validate_user_state
    mieru_validate_client_ports_state
    mieru_validate_traffic_state
    [[ "${MIERU_VERSION:-}" =~ ^[0-9]+(\.[0-9]+){2}$ ]] \
        || die "无法保存无效的 mita 版本：${MIERU_VERSION:-空}"
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
        printf 'MIERU_PORT=%q\n' "${MIERU_PORT}"
        printf 'MIERU_PORT_RANGE=%q\n' "${MIERU_PORT_RANGE}"
        printf 'MIERU_USER_NAME=%q\n' "${MIERU_USER_NAME}"
        printf 'MIERU_USER_PASSWORD=%q\n' "${MIERU_USER_PASSWORD}"
        printf 'MIERU_VERSION=%q\n' "${MIERU_VERSION}"
        printf 'MIERU_TRAFFIC_SEED=%q\n' "${MIERU_TRAFFIC_SEED}"
        printf 'MIERU_TRAFFIC_PATTERN=%q\n' "${MIERU_TRAFFIC_PATTERN}"
        printf 'MIERU_CLIENT_SOCKS5_PORT=%q\n' "${MIERU_CLIENT_SOCKS5_PORT}"
        printf 'MIERU_CLIENT_HTTP_PORT=%q\n' "${MIERU_CLIENT_HTTP_PORT}"
        printf 'MIERU_CLIENT_RPC_PORT=%q\n' "${MIERU_CLIENT_RPC_PORT}"
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
    [[ -n "${NODE_HOST:-}" && -n "${MIERU_USER_NAME:-}" && -n "${NODE_NAME:-}" ]] \
        || die "Mieru 状态不完整"
}

mita_package_installed() {
    dpkg -s "${MIERU_PACKAGE}" >/dev/null 2>&1
}

mita_listening_on_port() {
    ss -H -ltn "sport = :${1}" 2>/dev/null \
        | awk 'NR {found=1} END {exit !found}'
}

check_install_conflicts() {
    local port
    mita_package_installed \
        && die "检测到已安装 mita 软件包；easy_all 仅支持专用 VPS，请先卸载现有 mieru 服务"
    [[ ! -e /etc/mita/server.conf.pb ]] \
        || die "检测到既有 /etc/mita/server.conf.pb；请先卸载现有 mieru 服务"
    for port in 443 8443; do
        if mita_listening_on_port "${port}"; then
            die "TCP ${port} 已被占用；easy_all 仅支持专用 VPS"
        fi
    done
    [[ ! -f /etc/nginx/conf.d/easy_all.conf ]] \
        || die "检测到既有 easy_all Nginx 配置；请先卸载其他 easy_all 模式"
}

# --- Official mita release ------------------------------------------------

mieru_package_asset() {
    printf 'mita_%s_%s.deb\n' "$1" "${MIERU_PACKAGE_ARCH}"
}

mieru_installed_version() {
    local output
    output=$(mita version 2>/dev/null | head -n 1) || return 1
    output=${output//[[:space:]]/}
    [[ "${output}" =~ ^([0-9]+(\.[0-9]+){2}) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

download_mieru_package() {
    local temp_dir=$1 release_file version asset archive_url digest_url
    local archive digest expected actual
    release_file="${temp_dir}/release.json"
    download_https_file "${MIERU_RELEASES_API}" "${release_file}" \
        " mieru 最新版本信息"
    version=$(jq -r '.tag_name // empty' "${release_file}")
    [[ "${version}" =~ ^v[0-9]+(\.[0-9]+){2}$ ]] \
        || die "GitHub 返回了无效的 mieru 版本：${version:-空}"
    asset=$(mieru_package_asset "${version#v}")
    archive_url=$(jq -r --arg name "${asset}" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "${release_file}")
    digest_url=$(jq -r --arg name "${asset}.sha256.txt" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "${release_file}")
    [[ "${archive_url}" == "${MIERU_RELEASE_BASE}/${version}/${asset}" ]] \
        || die "未找到 ${asset}"
    [[ "${digest_url}" == "${MIERU_RELEASE_BASE}/${version}/${asset}.sha256.txt" ]] \
        || die "未找到 ${asset}.sha256.txt"
    archive="${temp_dir}/${asset}"
    digest="${temp_dir}/${asset}.sha256.txt"
    info "正在从 GitHub 官方 Release 下载 mita ${version}"
    download_https_file "${archive_url}" "${archive}" " mita ${version}"
    download_https_file "${digest_url}" "${digest}" " mita 校验文件"
    expected=$(awk 'NR == 1 {print tolower($1)}' "${digest}")
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
        || die "mita SHA256 校验文件格式无效"
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ "${expected}" == "${actual}" ]] \
        || die "mita SHA256 校验失败：期望 ${expected}，实际 ${actual}"
    MIERU_DOWNLOAD_VERSION=${version#v}
    MIERU_DOWNLOAD_PACKAGE=${archive}
}

install_mieru_package() {
    local package=$1 expected=$2 installed
    export DEBIAN_FRONTEND=noninteractive
    dpkg -i "${package}" >/dev/null || die "安装 ${MIERU_PACKAGE} 软件包失败"
    systemctl daemon-reload
    systemctl enable "${MIERU_SERVICE}" >/dev/null 2>&1 \
        || die "设置 mita 开机启动失败"
    systemctl restart "${MIERU_SERVICE}" || die "启动 mita 服务失败"
    command -v mita >/dev/null 2>&1 || die "mita 安装后不可用"
    installed=$(mieru_installed_version) \
        || die "无法读取 mita 版本"
    [[ "${installed}" == "${expected}" ]] \
        || die "mita 版本验收失败：期望 ${expected}，实际 ${installed}"
    printf '%s\n' "${installed}"
}

install_latest_mieru_package() {
    local temp_dir
    temp_dir=$(make_temp_dir)
    download_mieru_package "${temp_dir}"
    MIERU_VERSION=$(install_mieru_package \
        "${MIERU_DOWNLOAD_PACKAGE}" "${MIERU_DOWNLOAD_VERSION}")
    info "已安装官方 mita ${MIERU_VERSION}"
}

remove_mieru_package() {
    local status=0
    systemctl disable --now "${MIERU_SERVICE}" >/dev/null 2>&1 || true
    if mita_package_installed; then
        export DEBIAN_FRONTEND=noninteractive
        dpkg --purge "${MIERU_PACKAGE}" >/dev/null || status=1
    fi
    ((status != 0)) || {
        rm -rf -- /etc/mita /var/lib/mita /var/run/mita /var/run/mita.sock
        userdel mita >/dev/null 2>&1 || true
        groupdel mita >/dev/null 2>&1 || true
    }
    return "${status}"
}

# --- Configuration --------------------------------------------------------

render_mieru_server_config() {
    local destination=$1
    jq -n \
        --argjson port "${MIERU_PORT}" \
        --arg user "${MIERU_USER_NAME}" \
        --arg password "${MIERU_USER_PASSWORD}" \
        --argjson mtu "${MIERU_MTU}" \
        --argjson seed "${MIERU_TRAFFIC_SEED}" '
        {
            portBindings: [{port: $port, protocol: "TCP"}],
            users: [{name: $user, password: $password}],
            loggingLevel: "INFO",
            mtu: $mtu,
            dns: {dualStack: "PREFER_IPv4"},
            trafficPattern: {seed: $seed, unlockAll: false}
        }' >"${destination}" || die "渲染 mita 服务器配置失败"
}

validate_mieru_server_config() {
    local config=$1
    jq -e \
        --arg user "${MIERU_USER_NAME}" \
        --arg password "${MIERU_USER_PASSWORD}" \
        --argjson port "${MIERU_PORT}" \
        --argjson seed "${MIERU_TRAFFIC_SEED}" \
        --argjson mtu "${MIERU_MTU}" '
        (.portBindings | length) == 1
        and .portBindings[0].port == $port
        and .portBindings[0].protocol == "TCP"
        and (.users | length) == 1
        and .users[0].name == $user
        and .users[0].password == $password
        and .dns.dualStack == "PREFER_IPv4"
        and .mtu == $mtu
        and .trafficPattern.seed == $seed
        and .trafficPattern.unlockAll == false
    ' "${config}" >/dev/null \
        || die "生成的 mita 服务器配置不符合官方格式"
}

render_mieru_client_config() {
    local destination=$1
    [[ -n "${MIERU_TRAFFIC_PATTERN_JSON}" ]] \
        || die "缺少 Mieru traffic-pattern JSON；请重新执行 easy_all apply"
    jq -n \
        --arg user "${MIERU_USER_NAME}" \
        --arg password "${MIERU_USER_PASSWORD}" \
        --arg server "${NODE_HOST}" \
        --arg port_range "${MIERU_PORT_RANGE}" \
        --argjson mtu "${MIERU_MTU}" \
        --argjson pattern "${MIERU_TRAFFIC_PATTERN_JSON}" \
        --arg multiplexing "${MIERU_MULTIPLEXING}" \
        --argjson socks5 "${MIERU_CLIENT_SOCKS5_PORT}" \
        --argjson http "${MIERU_CLIENT_HTTP_PORT}" \
        --argjson rpc "${MIERU_CLIENT_RPC_PORT}" '
        {
            profiles: [{
                profileName: "default",
                user: {name: $user, password: $password},
                servers: [
                    (if ($server | test("^[0-9]{1,3}(\\.[0-9]{1,3}){3}$"))
                     then {ipAddress: $server}
                     else {domainName: $server}
                     end)
                    + {portBindings: [{portRange: $port_range, protocol: "TCP"}]}
                ],
                mtu: $mtu,
                multiplexing: {level: $multiplexing},
                handshakeMode: "HANDSHAKE_STANDARD",
                trafficPattern: $pattern
            }],
            activeProfile: "default",
            rpcPort: $rpc,
            socks5Port: $socks5,
            loggingLevel: "INFO",
            httpProxyPort: $http
        }' >"${destination}" || die "渲染 Mieru 客户端配置失败"
}

validate_protocol_runtime() {
    local attempt status
    for attempt in 1 2 3 4 5; do
        status=$(mita status 2>/dev/null || true)
        if systemctl is-active --quiet "${MIERU_SERVICE}" \
            && [[ "${status}" == *RUNNING* ]] \
            && mita_listening_on_port "${MIERU_PORT}"; then
            return 0
        fi
        sleep 2
    done
    die "Mieru 运行时验收失败：mita 未处于 RUNNING 或未监听 TCP ${MIERU_PORT}"
}

apply_mieru_config() {
    local server_config=$1
    validate_mieru_server_config "${server_config}"
    mita apply config "${server_config}" >/dev/null \
        || die "mita 拒绝了服务器配置；请检查端口与用户名/密码"
    mita stop >/dev/null 2>&1 || true
    mita start >/dev/null || die "启动 mita 代理失败"
    validate_protocol_runtime
    refresh_mieru_traffic_pattern
}

# The exported pattern is the official base64 protobuf representation used by
# Mihomo (`traffic-pattern`) and by simple mierus:// sharing links.
refresh_mieru_traffic_pattern() {
    local pattern json seed
    pattern=$(mita export traffic-pattern 2>/dev/null | tr -d '[:space:]') \
        || die "导出 Mieru traffic-pattern 失败"
    [[ "${pattern}" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] \
        || die "mita 返回了无效的 traffic-pattern"
    # Decode the exact same base64 used by Mihomo and mierus:// links, so the
    # native client config cannot drift from the shared traffic-pattern.
    json=$(mita explain traffic-pattern "${pattern}" 2>/dev/null) \
        || die "解析 Mieru traffic-pattern 失败"
    json=$(jq -ce 'if type == "object" then . else error("not an object") end' \
        <<<"${json}") || die "mita 返回了无效的 traffic-pattern JSON"
    seed=$(jq -er '.seed // empty' <<<"${json}" 2>/dev/null || true)
    [[ -z "${seed}" || "${seed}" == "${MIERU_TRAFFIC_SEED}" ]] \
        || die "Mieru traffic-pattern seed 与状态不一致：${seed} != ${MIERU_TRAFFIC_SEED}"
    MIERU_TRAFFIC_PATTERN=${pattern}
    MIERU_TRAFFIC_PATTERN_JSON=${json}
}

# --- UFW ------------------------------------------------------------------

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

mieru_write_nat_rules() {
    local begin end
    IFS=- read -r begin end <<<"${MIERU_PORT_RANGE}"
    printf -- '-A PREROUTING -p tcp --dport %s:%s -j REDIRECT --to-ports %s\n' \
        "${begin}" "${end}" "${MIERU_PORT}"
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
            mieru_write_nat_rules
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

write_mieru_nat_rules() {
    mieru_validate_port_range_state
    write_ufw_nat_rules_for_family "${UFW_BEFORE_RULES}" iptables-restore \
        "${UFW_NAT_START}" "${UFW_NAT_END}" 1 "IPv4"
    if [[ -f "${UFW_BEFORE6_RULES}" ]] \
        && grep -Fq "${UFW_NAT6_START}" "${UFW_BEFORE6_RULES}"; then
        write_ufw_nat_rules_for_family "${UFW_BEFORE6_RULES}" ip6tables-restore \
            "${UFW_NAT6_START}" "${UFW_NAT6_END}" 0 "IPv6"
    fi
}

filter_dynamic_port_cron() {
    awk -v marker="${CRON_DYNAMIC_PORT_MARKER}" 'index($0, marker) == 0'
}

configure_dynamic_port_rotation() {
    local current job
    current=$(read_root_crontab) || return 1
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

rotate_dynamic_ports() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    write_mieru_nat_rules
    ufw reload >/dev/null || die "刷新 UFW NAT 规则失败"
    end_quota_maintenance
    success "已刷新 UFW NAT：TCP ${MIERU_PORT_RANGE} → ${MIERU_PORT}"
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
    desired_ports="${SSH_PORTS} ${MIERU_PORT}"
    apply_ssh_ufw_policy "${desired_ports}"
    write_mieru_nat_rules
    ufw reload >/dev/null || die "加载 UFW NAT 规则失败"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

# --- Node output ----------------------------------------------------------

build_mierus_link() {
    printf 'mierus://%s:%s@%s?mtu=%s&multiplexing=%s&port=%s&profile=default&protocol=%s&traffic-pattern=%s' \
        "${MIERU_USER_NAME}" "${MIERU_USER_PASSWORD}" "${NODE_HOST}" \
        "${MIERU_MTU}" "${MIERU_MULTIPLEXING}" "${MIERU_PORT_RANGE}" "${MIERU_TRANSPORT}" \
        "$(uri_encode "${MIERU_TRAFFIC_PATTERN}")"
}

build_mihomo_node() {
    jq -nr \
        --arg name "${NODE_NAME}" --arg server "${NODE_HOST}" \
        --arg user "${MIERU_USER_NAME}" --arg password "${MIERU_USER_PASSWORD}" \
        --arg pattern "${MIERU_TRAFFIC_PATTERN}" \
        --arg multiplexing "${MIERU_MULTIPLEXING}" \
        --arg port_range "${MIERU_PORT_RANGE}" '
        "  - name: \($name|@json)\n    type: mieru\n    server: \($server|@json)\n" +
        "    port-range: \($port_range|@json)\n" +
        "    transport: TCP\n    udp: true\n    username: \($user|@json)\n" +
        "    password: \($password|@json)\n    multiplexing: \($multiplexing)\n" +
        "    traffic-pattern: \($pattern|@json)\n"'
}

show_node() {
    collect_installed_state
    printf '\n协议: %s（官方 mita）\n节点名称: %s\n服务器: %s（%s）\n' \
        "${PROTOCOL}" "${NODE_NAME}" "${NODE_HOST}" "${MIERU_TRANSPORT}"
    printf '端口范围: %s（UFW NAT 转发到内部 TCP %s）\n' \
        "${MIERU_PORT_RANGE}" "${MIERU_PORT}"
    printf '用户名: %s\n密码: %s\nmita 版本: %s\n\n' \
        "${MIERU_USER_NAME}" "${MIERU_USER_PASSWORD}" "${MIERU_VERSION}"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node
    printf '\nMieru 客户端分享链接:\n%s\n\n' "$(build_mierus_link)"
    printf 'Mieru 客户端配置（已保存到 %s，权限 0600）:\n' "${MIERU_CLIENT_CONFIG}"
    if [[ -f "${MIERU_CLIENT_CONFIG}" ]]; then
        cat "${MIERU_CLIENT_CONFIG}"
    else
        printf '（安装或 apply 后生成）\n'
    fi
    printf '\n'
}

show_subscription() {
    collect_installed_state
    show_node
    printf '订阅服务: 未部署\n'
    printf '本模式不提供在线订阅；请将上方 mieru 分享链接、客户端配置或 Mihomo 片段手工导入客户端。\n'
    printf '需要在线订阅时请改用 Reality 模式的订阅输出。\n\n'
}

show_status() {
    local status
    require_root
    collect_installed_state
    printf '协议: %s（官方 mita）\n' "${PROTOCOL}"
    show_tcp_acceleration_status
    printf 'VPS 网络栈: IPv4-only（IPv6 全局禁用）\n'
    printf '节点名称: %s\n服务器: %s（%s）\n' \
        "${NODE_NAME}" "${NODE_HOST}" "${MIERU_TRANSPORT}"
    printf '端口范围: %s → 内部 TCP %s\n' "${MIERU_PORT_RANGE}" "${MIERU_PORT}"
    printf 'mita 服务: '
    systemctl is-active --quiet "${MIERU_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'mita 版本: %s\n' "$(mieru_installed_version || printf 'unknown')"
    status=$(mita status 2>/dev/null || true)
    printf 'mita 状态: %s\n' "${status:-unknown}"
    printf 'TCP %s: ' "${MIERU_PORT}"
    mita_listening_on_port "${MIERU_PORT}" \
        && printf 'listening\n' || printf 'not listening\n'
    printf 'UFW NAT: '
    grep -Fq "${UFW_NAT_START}" "${UFW_BEFORE_RULES}" 2>/dev/null \
        && printf 'active（%s → %s）\n' "${MIERU_PORT_RANGE}" "${MIERU_PORT}" \
        || printf 'missing\n'
    printf '客户端配置: %s\n' "${MIERU_CLIENT_CONFIG}"
}

# --- Lifecycle ------------------------------------------------------------

stop_protocol_services() {
    mita stop >/dev/null 2>&1 || true
    systemctl disable --now "${MIERU_SERVICE}" >/dev/null 2>&1 || true
}

apply_easy_all() {
    local backup_dir old_server="" old_client=""
    require_root
    begin_quota_maintenance
    collect_installed_state
    install -d -m 0700 "${MIERU_DIR}"
    configure_tcp_acceleration
    configure_ipv4_only
    backup_dir=$(make_temp_dir)
    if [[ -f "${MIERU_SERVER_CONFIG}" ]]; then
        old_server="${backup_dir}/server_config.json"
        install -m 0600 "${MIERU_SERVER_CONFIG}" "${old_server}"
    fi
    if [[ -f "${MIERU_CLIENT_CONFIG}" ]]; then
        old_client="${backup_dir}/client_config.json"
        install -m 0600 "${MIERU_CLIENT_CONFIG}" "${old_client}"
    fi
    render_mieru_server_config "${RUNTIME_TMP}/server_config.json"
    if ! (
        install -m 0600 "${RUNTIME_TMP}/server_config.json" "${MIERU_SERVER_CONFIG}"
        apply_mieru_config "${MIERU_SERVER_CONFIG}"
        render_mieru_client_config "${RUNTIME_TMP}/client_config.json"
        install -m 0600 "${RUNTIME_TMP}/client_config.json" "${MIERU_CLIENT_CONFIG}"
    ); then
        warn "新配置验收失败，正在恢复旧配置"
        if [[ -n "${old_server}" ]]; then
            install -m 0600 "${old_server}" "${MIERU_SERVER_CONFIG}"
        else
            rm -f -- "${MIERU_SERVER_CONFIG}"
        fi
        if [[ -n "${old_client}" ]]; then
            install -m 0600 "${old_client}" "${MIERU_CLIENT_CONFIG}"
        else
            rm -f -- "${MIERU_CLIENT_CONFIG}"
        fi
        if [[ -n "${old_server}" ]]; then
            apply_mieru_config "${MIERU_SERVER_CONFIG}" >/dev/null 2>&1 || true
        else
            mita stop >/dev/null 2>&1 || true
        fi
        die "Mieru 本机配置应用失败，已恢复旧配置"
    fi
    refresh_mieru_traffic_pattern
    configure_ufw
    configure_dynamic_port_rotation
    register_easy_all_command
    save_state
    end_quota_maintenance
    show_node
    success "easy_all Mieru 直连本机配置已应用"
}

update_mieru_core() {
    (($# == 0)) || die "update-core 不接受参数"
    local previous
    require_root
    begin_quota_maintenance
    collect_installed_state
    previous=${MIERU_VERSION}
    install_latest_mieru_package
    if ! (apply_mieru_config "${MIERU_SERVER_CONFIG}"); then
        MIERU_VERSION=${previous}
        warn "mita 已升级到 ${MIERU_DOWNLOAD_VERSION}，但运行时验收失败；请执行 easy_all status 检查或重新运行 easy_all apply"
        die "Mieru 核心更新失败"
    fi
    refresh_mieru_traffic_pattern
    render_mieru_client_config "${MIERU_CLIENT_CONFIG}"
    chmod 0600 "${MIERU_CLIENT_CONFIG}"
    save_state
    end_quota_maintenance
    success "mita 已更新到 ${MIERU_VERSION}"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" ]] || die "uninstall 不接受参数 ${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" || -L "${COMMAND_PATH}" ]] \
        || die "easy_all 尚未安装"
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
    fi
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        read_bilingual \
            '删除 easy_all 本机服务、mita 软件包与状态？[y/N]:' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    if [[ -f "${STATE_FILE}" ]]; then
        load_state
    fi
    stop_protocol_services
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    remove_mieru_package || die "卸载 mita 软件包失败；状态与防火墙备份已保留"
    remove_dynamic_port_rotation
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_bbr_tcp_install_state
    remove_daily_reboot_schedule
    rm -f -- "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}"
    success "easy_all Mieru 直连本机内容与 mita 软件包已卸载"
}

rollback_fresh_install() {
    warn "首次安装失败，正在恢复本机服务、UFW、crontab 与 BBR 配置"
    stop_protocol_services
    remove_mieru_package || warn "回滚时卸载 mita 失败，请手动执行 dpkg --purge mita"
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    remove_dynamic_port_rotation || true
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_bbr_tcp_install_state 1
    restore_preinstall_crontab
    rm -f -- "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${COMMAND_INSTALL_DIR}"
    warn "首次安装产生的服务数据已清理"
}

# --- Input collection -----------------------------------------------------

mieru_generate_secret() {
    local length=$1
    openssl rand -base64 48 \
        | tr -d '=+/\n' | tr -c 'A-Za-z0-9._~-' '-' | cut -c1-"${length}"
}

collect_mieru_node_name() {
    [[ -n "${NODE_NAME:-}" ]] || {
        if [[ -t 0 ]]; then
            NODE_NAME=$(prompt_value "节点名称" "${DEFAULT_MIERU_NODE_NAME}")
        else
            NODE_NAME=${DEFAULT_MIERU_NODE_NAME}
        fi
    }
    [[ -n "${NODE_NAME}" && ${#NODE_NAME} -le 64 ]] \
        || die "节点名称无效：${NODE_NAME}"
}

collect_mieru_node_host() {
    local detected_ip="" host
    if [[ -n "${NODE_HOST:-}" ]]; then
        host=${NODE_HOST}
        if ! validate_ipv4 "${host}"; then
            host=$(normalize_domain "${host}")
        fi
        mieru_host_is_valid "${host}" \
            || die "Mieru 客户端连接地址必须是 IPv4 或 DNS only 域名：${NODE_HOST}"
        NODE_HOST=${host}
        return 0
    fi
    if detected_ip=$(detect_public_ipv4); then
        if [[ -t 0 ]]; then
            info "已自动检测本机公网 IPv4：${detected_ip}；直接回车使用该 IP，或输入其他入站 IPv4/灰云域名"
            NODE_HOST=$(prompt_value \
                "Mieru 客户端连接地址（公网 IPv4 或 DNS only 域名）" \
                "${detected_ip}")
        else
            NODE_HOST=${detected_ip}
        fi
    else
        [[ -t 0 ]] || die "无法自动检测本机公网 IPv4；非交互模式请设置 NODE_HOST"
        warn "无法自动检测本机公网 IPv4，请手动填写客户端可连接的入站地址"
        NODE_HOST=$(prompt_value \
            "Mieru 客户端连接地址（公网 IPv4 或 DNS only 域名）" "")
    fi
    host=${NODE_HOST}
    if ! validate_ipv4 "${host}"; then
        host=$(normalize_domain "${host}")
    fi
    mieru_host_is_valid "${host}" \
        || die "Mieru 客户端连接地址必须是 IPv4 或 DNS only 域名：${NODE_HOST}"
    NODE_HOST=${host}
}

collect_mieru_port() {
    local requested=${MIERU_PORT:-}
    if [[ -z "${requested}" && -t 0 ]]; then
        requested=$(prompt_value \
            "Mieru 内部监听端口（仅作为 UFW NAT 目标，默认 2090；外部端口范围为 ${DEFAULT_MIERU_PORT_RANGE}）" \
            "${DEFAULT_MIERU_PORT}")
    fi
    MIERU_PORT=${requested:-${DEFAULT_MIERU_PORT}}
    mieru_validate_port_state
    if mita_listening_on_port "${MIERU_PORT}"; then
        die "TCP ${MIERU_PORT} 已被占用；请选择其他端口"
    fi
}

collect_mieru_credentials() {
    if [[ -z "${MIERU_USER_NAME:-}" ]]; then
        MIERU_USER_NAME=$(mieru_generate_secret 16)
    fi
    if [[ -z "${MIERU_USER_PASSWORD:-}" ]]; then
        MIERU_USER_PASSWORD=$(mieru_generate_secret 32)
    fi
    mieru_validate_user_state
}

collect_mieru_client_ports() {
    local socks5=${MIERU_CLIENT_SOCKS5_PORT:-1080}
    local http=${MIERU_CLIENT_HTTP_PORT:-8080}
    local rpc=${MIERU_CLIENT_RPC_PORT:-} random
    if [[ -z "${rpc}" ]]; then
        random=$(od -An -N2 -tu2 /dev/urandom | tr -d '[:space:]')
        [[ "${random}" =~ ^[0-9]+$ ]] \
            || die "无法生成 Mieru 客户端管理端口"
        rpc=$((2000 + 10#${random} % 6001))
    fi
    MIERU_CLIENT_SOCKS5_PORT=${socks5}
    MIERU_CLIENT_HTTP_PORT=${http}
    MIERU_CLIENT_RPC_PORT=${rpc}
    mieru_validate_client_ports_state
}

collect_mieru_traffic_seed() {
    local random
    if [[ -z "${MIERU_TRAFFIC_SEED:-}" ]]; then
        random=$(od -An -N4 -tu4 /dev/urandom | tr -d '[:space:]')
        [[ "${random}" =~ ^[0-9]+$ ]] \
            || die "无法生成 Mieru traffic-pattern seed"
        MIERU_TRAFFIC_SEED=$((1 + 10#${random} % 2147483646))
    fi
    [[ "${MIERU_TRAFFIC_SEED}" =~ ^[0-9]+$ ]] \
        && ((10#${MIERU_TRAFFIC_SEED} >= 1 && 10#${MIERU_TRAFFIC_SEED} <= 2147483647)) \
        || die "Mieru traffic-pattern seed 无效"
}

collect_mieru_inputs() {
    validate_protocol "${PROTOCOL}"
    collect_mieru_node_name
    collect_mieru_node_host
    collect_mieru_port
    MIERU_PORT_RANGE=${DEFAULT_MIERU_PORT_RANGE}
    mieru_validate_port_range_state
    collect_mieru_credentials
    collect_mieru_client_ports
    collect_mieru_traffic_seed
    refresh_google_egress_selection
}

run_mieru_install_pipeline() {
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    info "[1/7] 检查系统"
    check_platform
    choose_protocol "${1:-}"
    check_install_conflicts
    info "[2/7] 安装依赖并初始化服务器"
    snapshot_fresh_install
    install_packages
    initialize_server
    info "[3/7] 收集 Mieru 节点参数"
    collect_mieru_inputs
    info "[4/7] 安装官方 mita 软件包"
    install_latest_mieru_package
    info "[5/7] 应用官方 mita 配置并启动代理"
    install -d -m 0700 "${MIERU_DIR}"
    render_mieru_server_config "${MIERU_SERVER_CONFIG}"
    chmod 0600 "${MIERU_SERVER_CONFIG}"
    apply_mieru_config "${MIERU_SERVER_CONFIG}"
    render_mieru_client_config "${MIERU_CLIENT_CONFIG}"
    chmod 0600 "${MIERU_CLIENT_CONFIG}"
    info "[6/7] 配置 UFW 与端口范围 NAT"
    configure_ufw
    configure_dynamic_port_rotation
    info "[7/7] 保存状态并注册 easy_all 命令"
    save_state
    register_easy_all_command
    INSTALL_ROLLBACK_ON_EXIT=0
    show_node
    show_tcp_acceleration_status
    success "easy_all ${PROTOCOL} 安装完成"
    prompt_bbrv3_reboot
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    run_mieru_install_pipeline "${1:-}"
}
