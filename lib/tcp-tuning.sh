#!/usr/bin/env bash

# Shared XanMod LTS BBRv3 kernel management and conservative TCP tuning.

readonly BBRV3_XANMOD_KEY_URL="https://dl.xanmod.org/archive.key"
readonly BBRV3_XANMOD_KEY_FINGERPRINT="D38D7D1DA1349567ADED882D86F7D09EE734E623"
readonly BBRV3_XANMOD_REPOSITORY_URL="https://deb.xanmod.org"
readonly BBRV3_XANMOD_KEYRING="${BBRV3_XANMOD_KEYRING_OVERRIDE:-/etc/apt/keyrings/xanmod-archive-keyring.gpg}"
readonly BBRV3_XANMOD_SOURCE="${BBRV3_XANMOD_SOURCE_OVERRIDE:-/etc/apt/sources.list.d/xanmod-release.list}"
readonly BBRV3_CPUINFO_FILE="${BBRV3_CPUINFO_FILE_OVERRIDE:-/proc/cpuinfo}"
readonly BBRV3_AVAILABLE_CC_FILE="${BBRV3_AVAILABLE_CC_FILE_OVERRIDE:-/proc/sys/net/ipv4/tcp_available_congestion_control}"
readonly BBRV3_EFI_DIR="${BBRV3_EFI_DIR_OVERRIDE:-/sys/firmware/efi}"
readonly BBRV3_EFIVARS_DIR="${BBRV3_EFIVARS_DIR_OVERRIDE:-${BBRV3_EFI_DIR}/efivars}"
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
net.ipv4.tcp_notsent_lowat
net.ipv4.tcp_tw_reuse
net.ipv4.tcp_fin_timeout
net.ipv4.tcp_no_metrics_save
net.ipv4.tcp_keepalive_time
net.ipv4.tcp_keepalive_intvl
net.ipv4.tcp_keepalive_probes
net.ipv4.ip_local_port_range
net.core.somaxconn
net.core.netdev_max_backlog
net.ipv6.conf.all.disable_ipv6
net.ipv6.conf.default.disable_ipv6
net.ipv6.conf.lo.disable_ipv6
EOF
}

snapshot_tcp_runtime() {
    local destination="${BACKUP_DIR}/pre-install-tcp-runtime.conf"
    local packages="${BACKUP_DIR}/pre-install-xanmod-packages"
    local key value
    install -d -m 0700 "${BACKUP_DIR}"
    if [[ ! -e "${packages}" ]]; then
        xanmod_installed_packages >"${packages}"
        chmod 0600 "${packages}"
    fi
    [[ ! -e "${destination}" ]] || return 0
    install -m 0600 /dev/null "${destination}"
    while IFS= read -r key; do
        value=$(sysctl -n "${key}" 2>/dev/null) || continue
        printf '%s = %s\n' "${key}" "${value}" >>"${destination}"
    done < <(tcp_runtime_keys)
}

restore_tcp_runtime() {
    local source="${BACKUP_DIR}/pre-install-tcp-runtime.conf"
    remove_physical_fq_qdisc_service
    if [[ -s "${source}" ]]; then
        sysctl -p "${source}" >/dev/null 2>&1 \
            || warn "恢复安装前 TCP 运行参数失败，请检查 ${source}"
    fi
    restore_physical_qdisc
}

restore_bbr_tcp_install_state() {
    local restore_packages=${1:-0}
    if [[ -f "${BACKUP_DIR}/pre-install-bbr.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr.conf" "${SYSCTL_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr.missing" ]]; then
        rm -f -- "${SYSCTL_CONFIG}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-bbr-module.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr-module.conf" \
            "${BBR_MODULES_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr-module.missing" ]]; then
        rm -f -- "${BBR_MODULES_CONFIG}"
    fi
    restore_tcp_runtime
    [[ "${restore_packages}" != "1" ]] || restore_preinstall_xanmod_packages
}

xanmod_installed_packages() {
    command -v dpkg-query >/dev/null 2>&1 || return 0
    { dpkg-query -W -f='${binary:Package}\t${db:Status-Abbrev}\n' \
        '*xanmod*' 2>/dev/null || true; } \
        | awk -F '\t' '$2 == "ii " {print $1}' | sort -u
}

restore_preinstall_xanmod_packages() {
    local snapshot="${BACKUP_DIR}/pre-install-xanmod-packages"
    local current package running="linux-image-$(uname -r)"
    local -a added=()
    [[ -f "${snapshot}" ]] || return 0
    current=$(mktemp "${RUNTIME_TMP}/xanmod-packages.XXXXXX")
    xanmod_installed_packages >"${current}"
    while IFS= read -r package; do
        [[ -n "${package}" && "${package}" != "${running}" ]] || continue
        added+=("${package}")
    done < <(comm -13 "${snapshot}" "${current}")
    ((${#added[@]} > 0)) || return 0
    apt-get -o DPkg::Lock::Timeout=300 purge -y "${added[@]}" >/dev/null \
        || warn "移除本次失败流程新装的 XanMod 包失败：${added[*]}"
    command -v update-grub >/dev/null 2>&1 && update-grub >/dev/null 2>&1 \
        || true
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
    local variable value disabled=0
    [[ -d "${BBRV3_EFI_DIR}" ]] || return 1
    [[ -d "${BBRV3_EFIVARS_DIR}" ]] || return 0
    for variable in "${BBRV3_EFIVARS_DIR}"/SecureBoot-*; do
        [[ -r "${variable}" ]] || continue
        value=$(od -An -j4 -N1 -tu1 "${variable}" 2>/dev/null | tr -d '[:space:]') \
            || return 0
        case "${value}" in
        0) disabled=1 ;;
        1) return 0 ;;
        *) return 0 ;;
        esac
    done
    ((disabled == 1)) && return 1
    return 0
}

xanmod_key_fingerprint() {
    gpg --batch --show-keys --with-colons "$1" 2>/dev/null \
        | awk -F: '
            $1 == "pub" {pubs += 1; want_fingerprint = 1; next}
            $1 == "fpr" && want_fingerprint {
                if (pubs == 1) fingerprint = $10
                want_fingerprint = 0
            }
            END {
                if (pubs == 1 && fingerprint != "") print fingerprint
                else exit 1
            }
        '
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
        --connect-timeout 10 --max-time 60 \
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

bbrv3_latest_kernel_release() {
    local image release
    for image in /boot/vmlinuz-*xanmod*; do
        [[ -s "${image}" ]] || continue
        release=${image##*/vmlinuz-}
        printf '%s\n' "${release}"
    done | sort -V | tail -n 1
}

bbrv3_kernel_image_installed() {
    local release
    release=$(bbrv3_latest_kernel_release)
    [[ -n "${release}" && -s "/boot/vmlinuz-${release}" \
        && -s "/boot/initrd.img-${release}" ]]
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
    bbrv3_kernel_image_installed \
        || die "最新 XanMod BBRv3 内核缺少可用的 vmlinuz 或 initrd"
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
        if ! physical_fq_active 2>/dev/null; then
            printf 'BBRv3: degraded（实际出口 FQ 未生效；请执行 easy_all apply）\n'
            return 0
        fi
        printf 'BBRv3: active（XanMod %s，fq + bbr）\n' "${release}"
    elif bbrv3_kernel_image_installed; then
        printf 'BBRv3: pending-reboot（当前内核 %s；请重启进入 XanMod）\n' "${release}"
    else
        printf 'BBRv3: unavailable（未找到 XanMod 内核；请执行 easy_all apply）\n'
    fi
}

configure_bbr_tcp() {
    ensure_vps_ip_family
    ensure_bbrv3_kernel
    cat >"${RUNTIME_TMP}/bbr.conf" <<'EOF'
# XanMod BBRv3 (the kernel registers it as tcp_bbr / bbr)
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer (32 MB ceiling for high-BDP cross-border links)
net.core.rmem_max = 33554432
net.core.wmem_max = 33554432
net.ipv4.tcp_rmem = 4096 131072 33554432
net.ipv4.tcp_wmem = 4096 16384 33554432
net.ipv4.tcp_moderate_rcvbuf = 1

# PMTU
net.ipv4.tcp_mtu_probing = 1

# Idle connection
net.ipv4.tcp_slow_start_after_idle = 0

# HTTP/2 & gRPC anti-bufferbloat: limit unsent bytes in write queue
net.ipv4.tcp_notsent_lowat = 32768

# High-concurrency socket recycling & queue optimization
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# Defaults for applications that enable SO_KEEPALIVE. XHTTP application-layer
# keepalive remains responsible for satisfying CDN HTTP/2 idle timeouts.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Outbound TCP/UDP source ports. Keep clear of easy_all's 10000-12927 Reality
# ingress range and the high 65533 SSH listener.
net.ipv4.ip_local_port_range = 13000 60999
EOF
    cat >>"${RUNTIME_TMP}/bbr.conf" <<EOF

# easy_all is globally IPv4-only.
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    if [[ "${PROTOCOL:-}" == "reality" && -z "${CDN_PROVIDER:-}" ]]; then
        cat >>"${RUNTIME_TMP}/bbr.conf" <<'EOF'

# Direct-link routing changes should not reuse stale destination metrics.
net.ipv4.tcp_no_metrics_save = 1
EOF
    fi
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
    apply_physical_fq_qdisc
    if bbrv3_running_kernel_supported; then
        rm -f -- "${BBRV3_REBOOT_MARKER}"
        success "XanMod BBRv3 已启用（$(uname -r)，fq + bbr）"
    else
        install -d -m 0700 "${STATE_DIR}"
        install -m 0600 /dev/null "${BBRV3_REBOOT_MARKER}"
        warn "XanMod BBRv3 内核已安装；当前仍为 $(uname -r)，请在安装结束后执行 sudo reboot"
    fi
}

default_route_iface() {
    ip -o -4 route show to default | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'
}

physical_fq_active() {
    local iface
    iface=$(default_route_iface) || return 1
    [[ -n "${iface}" ]] || return 1
    tc -j qdisc show dev "${iface}" | jq -e '
        [.[] | select(.kind != "ingress" and .kind != "clsact")] |
        any(.[]; .root == true and (.kind == "fq" or .kind == "mq")) and
        ([.[] | select(.kind != "mq")] | length > 0 and all(.[]; .kind == "fq"))
    ' >/dev/null
}

# Only reversible, classless schedulers are managed; preserve mq and ingress.
validate_qdisc_snapshot() {
    jq -e '
        [.[] | select(.kind != "ingress" and .kind != "clsact")] |
        any(.[]; .root == true and (.kind == "fq" or .kind == "fq_codel" or .kind == "pfifo_fast" or .kind == "mq")) and
        ([.[] | select(.kind != "mq")] | length > 0 and all(.[];
            (.root == true or (.parent | type == "string")) and
            (.handle | test("^[0-9a-fA-F]+:$")) and
            (if .kind == "fq" then true
             elif .kind == "fq_codel" then
                ((.options // {} | keys) - ["limit", "flows", "quantum", "target", "interval", "memory_limit", "ecn", "ce_threshold", "ce_threshold_selector", "ce_threshold_mask", "drop_batch"] | length == 0)
             elif .kind == "pfifo_fast" then
                .options.bands == 3 and .options.priomap == [1,2,2,2,1,2,0,0,1,1,1,1,1,1,1,1]
             else false end)))
    ' "$1" >/dev/null
}

qdisc_restore_args() {
    jq -r '
        (if .root then ["root"] else ["parent", .parent] end) +
        (if .handle == "0:" then [] else ["handle", .handle] end) + [.kind] +
        (if .kind == "fq_codel" then
            [(.options // {} | to_entries[]) |
                if .key == "ecn" or .key == "ce_threshold_selector" or .key == "ce_threshold_mask" then empty
                elif .key == "target" or .key == "interval" or .key == "ce_threshold" then .key, ((.value | tostring) + "us")
                else .key, (.value | tostring) end] +
            [if .options.ecn then "ecn" else "noecn" end] +
            (if .options.ce_threshold_selector != null then
                ["ce_threshold_selector", "\(.options.ce_threshold_selector)/\(.options.ce_threshold_mask)"] else [] end)
         else [] end) | .[]
    '
}

# Linux cannot address children of the kernel-created mq handle 0:. Rebuild only
# supported, fully snapshotted trees with a nonzero handle, retaining mq itself.
normalize_mq_handle() {
    local iface=$1 current=$2
    if jq -e 'any(.[]; .root == true and .kind == "mq" and .handle == "0:")' <<<"${current}" >/dev/null; then
        # Rebuilding would discard custom fq options, which we cannot serialize.
        jq -e 'all(.[]; .kind != "fq") and all(.[]; .handle != "ea00:")' <<<"${current}" >/dev/null \
            || return 1
        tc qdisc replace dev "${iface}" root handle ea00: mq || return 1
    fi
}

map_qdisc_parents() {
    local handle=$1
    jq --arg handle "${handle}" '
      map(if .parent and (.kind == "fq" or .kind == "fq_codel" or .kind == "pfifo_fast")
          then .parent = ($handle + (.parent | split(":")[1])) else . end)'
}

configure_physical_fq() {
    local iface current snapshot entry target filters attempt handle failed=0
    local -a args
    command -v tc >/dev/null && command -v jq >/dev/null || die "FQ 配置需要 tc 和 jq"
    iface=$(default_route_iface) || die "无法读取 IPv4 默认出口"
    [[ "${iface}" =~ ^[a-zA-Z0-9_.:-]+$ && "${iface}" != .* ]] || die "无法确定安全的默认出口接口名"
    current=$(tc -j qdisc show dev "${iface}") || die "读取 ${iface} qdisc 失败"
    install -d -m 0700 "${BACKUP_DIR}/qdisc"
    snapshot="${BACKUP_DIR}/qdisc/${iface}.json"
    printf '%s\n' "${current}" >"${snapshot}.tmp"
    validate_qdisc_snapshot "${snapshot}.tmp" || die "${iface} 存在不支持自动恢复的 qdisc；未修改队列"
    filters=$(tc -j filter show dev "${iface}" root) || die "读取 ${iface} 根过滤器失败"
    [[ "$(jq 'length' <<<"${filters}")" == 0 ]] || die "${iface} 存在根过滤器；拒绝替换队列"
    while IFS= read -r target; do
        [[ "${target}" != "0:" ]] || continue
        filters=$(tc -j filter show dev "${iface}" parent "${target}") || die "读取 ${iface} 子队列过滤器失败"
        [[ "$(jq 'length' <<<"${filters}")" == 0 ]] || die "${iface} 存在子队列过滤器；拒绝替换队列"
    done < <(jq -r '.[] | select(.kind == "fq_codel" or .kind == "pfifo_fast") | .handle' <<<"${current}")
    if [[ ! -e "${snapshot}" ]]; then
        mv -- "${snapshot}.tmp" "${snapshot}"
        chmod 0600 "${snapshot}"
    else
        validate_qdisc_snapshot "${snapshot}" || die "原 qdisc 备份无效；停止修改：${snapshot}"
        rm -f -- "${snapshot}.tmp"
    fi
    # Per-attempt snapshot also protects repeat applications after reboot.
    attempt="${snapshot}.apply"
    printf '%s\n' "${current}" >"${attempt}"
    chmod 0600 "${attempt}"
    if ! physical_fq_active; then
        normalize_mq_handle "${iface}" "${current}" \
            || die "${iface} mq 重建失败或存在无法恢复的 FQ 参数；备份：${attempt}"
    fi
    handle=$(tc -j qdisc show dev "${iface}" | jq -r '.[] | select(.root == true and .kind == "mq") | .handle')
    if [[ -n "${handle}" ]]; then
        current=$(map_qdisc_parents "${handle}" <<<"${current}")
    fi
    while IFS= read -r entry; do
        args=()
        if [[ "$(jq -r '.root // false' <<<"${entry}")" == true ]]; then
            args=(root)
        else
            target=$(jq -r '.parent' <<<"${entry}")
            args=(parent "${target}")
        fi
        if ! tc qdisc replace dev "${iface}" "${args[@]}" fq; then
            failed=1
            break
        fi
    done < <(jq -c '.[] | select(.kind == "fq_codel" or .kind == "pfifo_fast")' <<<"${current}")
    if ((failed)) || ! physical_fq_active; then
        restore_qdisc_snapshot "${iface}" "${attempt}" 1 \
            || die "${iface} FQ 应用及回滚失败；备份：${attempt}"
        die "${iface} FQ 应用失败，已恢复原队列；备份：${attempt}"
    fi
    rm -f -- "${attempt}"
}

restore_qdisc_snapshot() {
    local iface=$1 snapshot=$2 force=${3:-0}
    local entry actual expected target arg current handle entries
    local -a args
    current=$(tc -j qdisc show dev "${iface}") || return 1
    entries=$(cat "${snapshot}")
    jq -e 'any(.[]; .kind == "fq_codel" or .kind == "pfifo_fast")' <<<"${entries}" >/dev/null \
        || return 0
    if jq -e 'any(.[]; .root == true and .kind == "mq")' <<<"${entries}" >/dev/null; then
        jq -e 'any(.[]; .root == true and .kind == "mq")' <<<"${current}" >/dev/null || return 1
        if jq -e 'any(.[]; .root == true and .handle == "0:")' <<<"${current}" >/dev/null; then
            validate_qdisc_snapshot <(printf '%s\n' "${current}") || return 1
            normalize_mq_handle "${iface}" "${current}" || return 1
            force=1
        fi
        handle=$(tc -j qdisc show dev "${iface}" | jq -r '.[] | select(.root == true and .kind == "mq") | .handle')
        entries=$(map_qdisc_parents "${handle}" <<<"${entries}")
    fi
    while IFS= read -r entry; do
        target=$(jq -r 'if .root then "root" else .parent end' <<<"${entry}")
        actual=$(tc -j qdisc show dev "${iface}" | jq -Sc --arg target "${target}" '
            .[] | select(if $target == "root" then .root == true else .parent == $target end)') \
            || die "无法读取 ${iface} 队列；保留备份 ${snapshot}"
        expected=$(jq -Sc '{kind, options}' <<<"${entry}")
        [[ "$(jq -Sc '{kind, options}' <<<"${actual}")" != "${expected}" ]] || continue
        [[ "${force}" == 1 || "$(jq -r '.kind' <<<"${actual}")" == fq ]] \
            || die "${iface} 队列已被其他配置改变；请按 ${snapshot} 手动恢复"
        args=()
        while IFS= read -r arg; do args+=("${arg}"); done < <(qdisc_restore_args <<<"${entry}")
        tc qdisc replace dev "${iface}" "${args[@]}" || die "恢复 ${iface} qdisc 失败；保留备份 ${snapshot}"
        actual=$(tc -j qdisc show dev "${iface}" | jq -Sc --arg target "${target}" '
            .[] | select(if $target == "root" then .root == true else .parent == $target end) | {kind, options}') \
            || die "恢复 ${iface} 后读取队列失败；保留备份 ${snapshot}"
        [[ "${actual}" == "${expected}" ]] || die "${iface} qdisc 恢复验收失败；保留备份 ${snapshot}"
    done < <(jq -c '.[] | select(.kind == "fq_codel" or .kind == "pfifo_fast")' <<<"${entries}")
}

restore_physical_qdisc() {
    local snapshot iface
    for snapshot in "${BACKUP_DIR}/qdisc/"*.json; do
        [[ -f "${snapshot}" ]] || continue
        validate_qdisc_snapshot "${snapshot}" || die "qdisc 备份无效；保留备份 ${snapshot}"
        iface=${snapshot##*/}
        iface=${iface%.json}
        restore_qdisc_snapshot "${iface}" "${snapshot}" || die "恢复 ${iface} 失败；备份：${snapshot}"
    done
}

apply_physical_fq_qdisc() {
    configure_physical_fq
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local fq_service_file="${systemd_dir}/easy_all-fq.service"
    local helper="${STATE_DIR}/apply-fq.sh"
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        printf 'BACKUP_DIR=%q\n' "${BACKUP_DIR}"
        printf 'die() { printf "%%s\\n" "$*" >&2; exit 1; }\n'
        declare -f default_route_iface physical_fq_active validate_qdisc_snapshot \
            normalize_mq_handle map_qdisc_parents qdisc_restore_args restore_qdisc_snapshot configure_physical_fq
        printf 'configure_physical_fq\n'
    } >"${helper}"
    chmod 0700 "${helper}"
    cat >"${fq_service_file}" <<EOF_SERVICE
[Unit]
Description=Ensure and verify FQ on the default network interface
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/bin/bash "${helper}"
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload || die "重新加载 FQ 服务失败"
    systemctl enable easy_all-fq.service || die "启用 FQ 开机服务失败"
    systemctl restart easy_all-fq.service || die "启动 FQ 服务失败"
    physical_fq_active || die "FQ 服务启动后实际队列验收失败"
}

remove_physical_fq_qdisc_service() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local fq_service_file="${systemd_dir}/easy_all-fq.service"
    if [[ -f "${fq_service_file}" ]]; then
        systemctl disable --now easy_all-fq.service || die "停止 FQ 服务失败；请保留队列备份"
        rm -f -- "${fq_service_file}"
        systemctl daemon-reload || die "重新加载 systemd 失败"
    fi
    rm -f -- "${STATE_DIR}/apply-fq.sh"
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
