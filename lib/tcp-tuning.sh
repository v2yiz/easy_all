#!/usr/bin/env bash

# Shared XanMod LTS BBRv3 kernel management and conservative TCP tuning.

readonly BBRV3_XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly BBRV3_XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly BBRV3_XANMOD_REPOSITORY_URL="https://deb.xanmod.org"
readonly BBRV3_XANMOD_KEYRING="${BBRV3_XANMOD_KEYRING_OVERRIDE:-/etc/apt/keyrings/xanmod-archive-keyring.gpg}"
readonly BBRV3_XANMOD_SOURCE="${BBRV3_XANMOD_SOURCE_OVERRIDE:-/etc/apt/sources.list.d/xanmod-release.list}"
readonly BBRV3_CPUINFO_FILE="${BBRV3_CPUINFO_FILE_OVERRIDE:-/proc/cpuinfo}"
readonly BBRV3_AVAILABLE_CC_FILE="${BBRV3_AVAILABLE_CC_FILE_OVERRIDE:-/proc/sys/net/ipv4/tcp_available_congestion_control}"
readonly BBRV3_MINIMUM_XANMOD_VERSION="6.4.11"
readonly BBRV3_REBOOT_MARKER="${STATE_DIR}/bbrv3-reboot-required"

BBRV3_KERNEL_PACKAGE=""

tcp_runtime_keys() {
    cat <<'EOF'
net.core.default_qdisc
net.ipv4.tcp_congestion_control
net.core.rmem_max
net.core.wmem_max
net.ipv4.tcp_rmem
net.ipv4.tcp_wmem
net.ipv4.tcp_moderate_rcvbuf
net.ipv4.tcp_mtu_probing
net.ipv4.tcp_slow_start_after_idle
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.ipv4.ip_local_port_range
net.core.somaxconn
net.ipv6.conf.all.disable_ipv6
net.ipv6.conf.default.disable_ipv6
net.ipv6.conf.lo.disable_ipv6
EOF
}

snapshot_tcp_runtime() {
    local destination="${BACKUP_DIR}/pre-install-tcp-runtime.conf"
    local key value
    [[ ! -e "${destination}" ]] || return 0
    install -d -m 0700 "${BACKUP_DIR}"
    install -m 0600 /dev/null "${destination}"
    while IFS= read -r key; do
        value=$(sysctl -n "${key}" 2>/dev/null) || continue
        printf '%s = %s\n' "${key}" "${value}" >>"${destination}"
    done < <(tcp_runtime_keys)
}

restore_tcp_runtime() {
    local source="${BACKUP_DIR}/pre-install-tcp-runtime.conf"
    [[ -s "${source}" ]] || return 0
    sysctl -p "${source}" >/dev/null 2>&1 \
        || warn "恢复安装前 TCP 运行参数失败，请检查 ${source}"
}

bbrv3_cpu_level() {
    local flags required flag level=0
    flags=$(awk -F: '$1 ~ /^[[:space:]]*flags[[:space:]]*$/ {print " " $2 " "; exit}' \
        "${BBRV3_CPUINFO_FILE}")
    [[ -n "${flags}" ]] || die "无法读取 CPU x86-64 指令集能力"
    for required in \
        "lm cmov cx8 fpu fxsr mmx syscall sse2" \
        "cx16 lahf_lm popcnt sse4_1 sse4_2 ssse3" \
        "avx avx2 bmi1 bmi2 f16c fma abm movbe xsave"; do
        for flag in ${required}; do
            [[ "${flags}" == *" ${flag} "* ]] || {
                ((level >= 1)) || die "CPU 不满足 XanMod x86-64-v1 最低要求"
                printf '%s\n' "${level}"
                return 0
            }
        done
        level=$((level + 1))
    done
    printf '%s\n' "${level}"
}

bbrv3_kernel_package() {
    printf 'linux-xanmod-lts-x64v%s\n' "$(bbrv3_cpu_level)"
}

bbrv3_debian_codename() {
    local codename
    # shellcheck source=/dev/null
    source /etc/os-release
    codename=${VERSION_CODENAME:-}
    case "${codename}" in
    bookworm | trixie) printf '%s\n' "${codename}" ;;
    *) die "XanMod BBRv3 仅支持当前项目的 Debian 12/13：${codename:-未知}" ;;
    esac
}

bbrv3_secure_boot_enabled() {
    local variable value
    for variable in /sys/firmware/efi/efivars/SecureBoot-*; do
        [[ -r "${variable}" ]] || continue
        value=$(od -An -j4 -N1 -tu1 "${variable}" 2>/dev/null | tr -d '[:space:]')
        [[ "${value}" != "1" ]] || return 0
    done
    return 1
}

xanmod_key_fingerprint() {
    gpg --batch --show-keys --with-colons "$1" 2>/dev/null \
        | awk -F: '$1 == "fpr" {print $10; exit}'
}

xanmod_repository_line() {
    printf 'deb [signed-by=%s] %s %s main\n' \
        "${BBRV3_XANMOD_KEYRING}" "${BBRV3_XANMOD_REPOSITORY_URL}" \
        "$(bbrv3_debian_codename)"
}

xanmod_repository_ready() {
    local expected
    [[ -s "${BBRV3_XANMOD_KEYRING}" && -s "${BBRV3_XANMOD_SOURCE}" ]] || return 1
    [[ "$(xanmod_key_fingerprint "${BBRV3_XANMOD_KEYRING}")" \
        == "${BBRV3_XANMOD_KEY_FINGERPRINT}" ]] || return 1
    expected=$(xanmod_repository_line)
    [[ "$(<"${BBRV3_XANMOD_SOURCE}")" == "${expected}" ]]
}

ensure_xanmod_repository() {
    local key keyring source fingerprint
    xanmod_repository_ready && return 0
    if ! command -v gpg >/dev/null 2>&1; then
        info "安装 XanMod APT 公钥校验依赖：gnupg"
        apt-get -o DPkg::Lock::Timeout=300 update || die "刷新 Debian APT 索引失败"
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends gnupg \
            || die "安装 XanMod BBRv3 所需的 gnupg 失败"
    fi
    command -v gpg >/dev/null 2>&1 || die "安装 XanMod BBRv3 需要 gnupg"
    key="${RUNTIME_TMP}/xanmod-archive.key"
    keyring="${RUNTIME_TMP}/xanmod-archive-keyring.gpg"
    source="${RUNTIME_TMP}/xanmod-release.list"
    curl -fL --proto '=https' --tlsv1.2 --retry 3 \
        "${BBRV3_XANMOD_KEY_URL}" -o "${key}" \
        || die "下载 XanMod 官方 APT 公钥失败"
    fingerprint=$(xanmod_key_fingerprint "${key}")
    [[ "${fingerprint}" == "${BBRV3_XANMOD_KEY_FINGERPRINT}" ]] \
        || die "XanMod APT 公钥指纹不匹配：${fingerprint:-缺失}"
    gpg --batch --yes --dearmor --output "${keyring}" "${key}" \
        || die "转换 XanMod APT 公钥失败"
    xanmod_repository_line >"${source}"
    install -d -m 0755 "$(dirname -- "${BBRV3_XANMOD_KEYRING}")" \
        "$(dirname -- "${BBRV3_XANMOD_SOURCE}")"
    install -m 0644 "${keyring}" "${BBRV3_XANMOD_KEYRING}"
    install -m 0644 "${source}" "${BBRV3_XANMOD_SOURCE}"
    xanmod_repository_ready || die "XanMod APT 仓库写入后验收失败"
}

bbrv3_meta_package_installed() {
    local package=${1:-${BBRV3_KERNEL_PACKAGE:-$(bbrv3_kernel_package)}}
    dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null \
        | grep -qx 'ii '
}

bbrv3_kernel_image_installed() {
    find /boot -maxdepth 1 -type f -name 'vmlinuz-*xanmod*' -size +0c \
        -print -quit 2>/dev/null | grep -q .
}

bbrv3_running_kernel_supported() {
    local release version
    release=$(uname -r)
    [[ "${release}" == *xanmod* ]] || return 1
    version=${release%%-*}
    dpkg --compare-versions "${version}" ge "${BBRV3_MINIMUM_XANMOD_VERSION}"
}

ensure_bbrv3_kernel() {
    BBRV3_KERNEL_PACKAGE=$(bbrv3_kernel_package)
    if ! bbrv3_running_kernel_supported && bbrv3_secure_boot_enabled; then
        die "检测到 UEFI Secure Boot；拒绝安装或切换到无法确认可启动的 XanMod BBRv3 内核"
    fi
    ensure_xanmod_repository
    if ! bbrv3_meta_package_installed "${BBRV3_KERNEL_PACKAGE}"; then
        info "安装 XanMod LTS BBRv3 内核：${BBRV3_KERNEL_PACKAGE}"
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${BBRV3_KERNEL_PACKAGE}" \
            || die "安装 XanMod LTS BBRv3 内核失败"
    fi
    bbrv3_meta_package_installed "${BBRV3_KERNEL_PACKAGE}" \
        || die "XanMod BBRv3 元包安装后验收失败：${BBRV3_KERNEL_PACKAGE}"
    bbrv3_kernel_image_installed || die "未找到已安装的 XanMod BBRv3 内核镜像"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null || die "更新 GRUB 的 XanMod BBRv3 启动项失败"
    fi
}

show_bbrv3_status() {
    local release
    release=$(uname -r)
    if bbrv3_running_kernel_supported \
        && [[ "$(sysctl -n net.core.default_qdisc 2>/dev/null || true)" == "fq" ]] \
        && [[ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)" == "bbr" ]]; then
        printf 'BBRv3: active（XanMod %s，fq + bbr）\n' "${release}"
    elif bbrv3_kernel_image_installed; then
        printf 'BBRv3: pending-reboot（当前内核 %s；请重启进入 XanMod）\n' "${release}"
    else
        printf 'BBRv3: unavailable（未找到 XanMod 内核；请执行 easy_all apply）\n'
    fi
}

configure_bbr_tcp() {
    ensure_bbrv3_kernel
    cat >"${RUNTIME_TMP}/bbr.conf" <<'EOF'
# XanMod BBRv3 (the kernel registers it as tcp_bbr / bbr)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_moderate_rcvbuf = 1

# PMTU
net.ipv4.tcp_mtu_probing = 1

# Idle connection
net.ipv4.tcp_slow_start_after_idle = 0

# Defaults for applications that enable SO_KEEPALIVE. XHTTP application-layer
# keepalive remains responsible for satisfying CDN HTTP/2 idle timeouts.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Outbound TCP/UDP source ports. Keep clear of easy_all's 10000-12927 Reality
# ingress range and the high 65533 SSH listener.
net.ipv4.ip_local_port_range = 13000 60999

# Disable IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1

# Listen queue
net.core.somaxconn = 4096
EOF
    modprobe tcp_bbr >/dev/null 2>&1 \
        || die "当前内核不支持 tcp_bbr"
    grep -qw bbr "${BBRV3_AVAILABLE_CC_FILE}" \
        || die "tcp_bbr 已加载，但内核未将 bbr 注册为可用拥塞控制算法"
    printf '%s\n' tcp_bbr >"${RUNTIME_TMP}/easy_all-bbr.conf"
    install -m 0644 "${RUNTIME_TMP}/easy_all-bbr.conf" "${BBR_MODULES_CONFIG}"
    install -m 0644 "${RUNTIME_TMP}/bbr.conf" "${SYSCTL_CONFIG}"
    sysctl -p "${SYSCTL_CONFIG}" >/dev/null || die "应用 BBR sysctl 配置失败"
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
        || die "拥塞控制算法未成功设置为 bbr"
    [[ -f "${BBR_MODULES_CONFIG}" && -f "${SYSCTL_CONFIG}" ]] \
        || die "BBRv3 开机配置写入失败"
    if bbrv3_running_kernel_supported; then
        rm -f -- "${BBRV3_REBOOT_MARKER}"
        success "XanMod BBRv3 已启用（$(uname -r)，fq + bbr）"
    else
        install -d -m 0700 "${STATE_DIR}"
        install -m 0600 /dev/null "${BBRV3_REBOOT_MARKER}"
        warn "XanMod BBRv3 内核已安装；当前仍为 $(uname -r)，请在安装结束后执行 sudo reboot"
    fi
}

prompt_bbrv3_reboot() {
    local choice
    if bbrv3_running_kernel_supported; then
        return 0
    fi
    printf '\n'
    printf '%s\n' "========================================================================"
    printf '%s\n' "⚠️  【重要提示：请立即重启服务器以激活 BBRv3】"
    printf '%s\n' "XanMod LTS 内核已安装完成，当前运行仍为原版内核 ($(uname -r))。"
    printf '%s\n' "系统必须重启后才会真正载入 XanMod BBRv3 内核！"
    printf '%s\n' "请保存好上方的节点与订阅链接后，立即重启服务器。"
    printf '%s\n' "========================================================================"
    if [[ "${EASY_ALL_NO_REBOOT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ -t 0 ]]; then
        printf '是否现在立即重启服务器以生效 BBRv3？[y/N]: '
        read -r choice || choice="n"
        case "${choice}" in
            [yY]|[yY][eE][sS])
                info "正在重启服务器..."
                ${REBOOT_COMMAND:-reboot}
                ;;
            *)
                warn "已跳过自动重启，请在保存配置后手动执行: sudo reboot"
                ;;
        esac
    else
        warn "检测到非交互式环境，请在保存配置后手动执行: sudo reboot"
    fi
}

