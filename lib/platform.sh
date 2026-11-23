#!/usr/bin/env bash

# Shared host preflight and SSH boot-safety checks.

EASY_ALL_SSH_PORT_CONFIG="${EASY_ALL_SSH_PORT_CONFIG:-/etc/ssh/sshd_config.d/00-easy-all-ports.conf}"
# 安装收尾把 SSH 端口迁移到目标端口（写 sshd_config.d 片段，重启后生效）。未预设时为空：
# 交互安装会询问（默认 22222），非交互与测试可用环境变量直接指定。
EASY_ALL_TARGET_SSH_PORT="${EASY_ALL_TARGET_SSH_PORT:-}"
# sshd 的权限分离目录：容器与精简镜像里常常不存在，sshd -t/-T 会直接失败。
EASY_ALL_SSHD_PRIVSEP_DIR="${EASY_ALL_SSHD_PRIVSEP_DIR:-/run/sshd}"
EASY_ALL_SSHD_CONFIG="${EASY_ALL_SSHD_CONFIG:-/etc/ssh/sshd_config}"
EASY_ALL_SSHD_CONFIG_DIR="${EASY_ALL_SSHD_CONFIG_DIR:-/etc/ssh/sshd_config.d}"
EASY_ALL_FAIL2BAN_CONFIG="${EASY_ALL_FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/99-easy-all-sshd.local}"
EASY_ALL_FAIL2BAN_ACTION_CONFIG="${EASY_ALL_FAIL2BAN_ACTION_CONFIG:-/etc/fail2ban/action.d/easy-all-ufw-cidr.conf}"
# Fail2ban 是常驻安全基线：helper 放在独立系统路径，卸载 easy_all 时保留。
EASY_ALL_FAIL2BAN_CIDR_HELPER="${EASY_ALL_FAIL2BAN_CIDR_HELPER:-/usr/local/sbin/fail2ban-ufw-cidr.sh}"
EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR:-/var/lib/easy_all/fail2ban-ufw-cidr}"
if [[ -z "${IPV6_SYSCTL_CONF:-}" ]]; then
    IPV6_SYSCTL_CONF="/etc/sysctl.d/99-enable-ipv6.conf"
fi

# 平台支持范围的唯一来源：codename → 发行版族 + /etc/os-release 的 VERSION_ID。
# check_platform 与 lib/tcp-tuning.sh 的 Zabbly 仓库选择都从这里派生，新增代号只改这张表。
platform_codename_table() {
    case "${1:-}" in
    bookworm) printf 'debian 12\n' ;;
    trixie) printf 'debian 13\n' ;;
    jammy) printf 'ubuntu 22.04\n' ;;
    noble) printf 'ubuntu 24.04\n' ;;
    resolute) printf 'ubuntu 26.04\n' ;;
    *) return 1 ;;
    esac
}

platform_is_supported_codename() {
    platform_codename_table "${1:-}" >/dev/null
}

check_platform() {
    local os_release="${EASY_ALL_OS_RELEASE_FILE:-/etc/os-release}"
    [[ -r "${os_release}" ]] || die "无法识别系统版本"
    # shellcheck source=/dev/null
    source "${os_release}"
    local id="${ID:-}" version_id="${VERSION_ID:-}" codename="${VERSION_CODENAME:-}"
    local family="" expected_version="" entry=""
    entry=$(platform_codename_table "${codename}") || entry=""
    read -r family expected_version <<<"${entry}"
    # 代号必须与发行版成族：Debian 只有 bookworm/trixie，Ubuntu 只有三个 LTS，其余一律拦截。
    if [[ "${family}" != "${id}" ]]; then
        case "${id}" in
        debian)
            die "不支持当前 Debian 版本/代号 ${codename:-${version_id:-未知}}（仅支持 Debian 12 bookworm 与 13 trixie）"
            ;;
        ubuntu)
            die "不支持当前 Ubuntu 版本/代号 ${codename:-${version_id:-未知}}（仅支持 Ubuntu 22.04 jammy、24.04 noble 与 26.04 resolute）"
            ;;
        *)
            die "仅支持 Debian 12+ 或 Ubuntu 22.04+（当前发行版：${id:-未知}）"
            ;;
        esac
    fi
    # 代号必须由 VERSION_ID 印证：缺失或不一致说明 /etc/os-release 被改过或不是官方镜像。
    [[ -n "${version_id}" ]] \
        || die "系统版本信息缺失：${id} 的 /etc/os-release 没有 VERSION_ID，无法与代号 ${codename} 互相印证"
    [[ "${version_id}" == "${expected_version}" ]] \
        || die "系统版本信息不一致：${id} VERSION_ID=${version_id} 与代号 ${codename} 不匹配"

    local architecture
    architecture=$(dpkg --print-architecture) || die "无法识别系统架构"
    case "${architecture}" in
    amd64|arm64) ;;
    *) die "不支持系统架构 ${architecture}（仅支持 amd64 与 arm64）" ;;
    esac

    ! systemd-detect-virt --container >/dev/null 2>&1 \
        || die "容器不能执行内核与防火墙初始化"
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行此脚本"
}

require_systemd() {
    command -v systemctl >/dev/null 2>&1 || die "仅支持使用 systemd 的 Linux 系统"
    [[ -d /run/systemd/system ]] || die "当前系统未由 systemd 管理"
}

ensure_swap() {
    local swap_file="${EASY_ALL_SWAP_FILE:-/swapfile}"
    local meminfo="${EASY_ALL_MEMINFO_FILE:-/proc/meminfo}"
    local fstab_file="${EASY_ALL_FSTAB_FILE:-/etc/fstab}"
    local swap_total
    swap_total=$(awk '/SwapTotal:/ {print $2}' "${meminfo}" 2>/dev/null || echo 0)
    if (( swap_total > 0 )); then
        return 0
    fi

    local target_dir avail_kb
    local created_new=0
    if [[ ! -f "${swap_file}" ]]; then
        # 空间检查只对新建生效：同名 Swap 文件已存在且魔数校验通过时直接复用，磁盘已满但
        # 交换文件完好的机器仍能拿到 Swap，不会因为没有 1.5GB 余量而跳过。
        target_dir=$(dirname "${swap_file}")
        # `df -k` 在长设备名下会换行错位；`-P` 保证一个文件系统一行。仍可能取不到数字
        # （df 失败/权限不足），此时按「无法确认」处理：宁可跳过，也不在可能已满的盘上写 1GB。
        # `df` 自身失败时在 pipefail 下会让赋值返回非零；不能因此中断安装，按“无法确认”处理。
        avail_kb=$(df -Pk "${target_dir}" 2>/dev/null | awk 'NR == 2 {print $4}') || avail_kb=""
        if [[ ! "${avail_kb}" =~ ^[0-9]{1,15}$ ]]; then
            warn "无法确认磁盘剩余空间（${target_dir}）；跳过创建 Swap，请手动配置或释放空间"
            return 0
        fi
        avail_kb=$((10#${avail_kb}))
        if (( avail_kb == 0 )); then
            warn "磁盘已无可用空间（${target_dir}）；跳过创建 Swap，请释放空间后手动配置"
            return 0
        fi
        if (( avail_kb < 1572864 )); then
            warn "磁盘剩余空间不足 1.5GB（当前剩余 $((avail_kb / 1024))MB）；跳过创建 Swap，请注意内存占用"
            return 0
        fi
        info "检测到系统未配置 Swap，正在创建 1GB 交换文件..."
        created_new=1
        if ! fallocate -l 1G "${swap_file}" 2>/dev/null; then
            dd if=/dev/zero of="${swap_file}" bs=1M count=1024 status=none \
                || { warn "创建 1GB Swap 文件失败；跳过配置 Swap"; return 0; }
        fi
        chmod 0600 "${swap_file}"
        mkswap "${swap_file}" >/dev/null 2>&1 || {
            warn "格式化 Swap 文件失败；清理并跳过"
            rm -f -- "${swap_file}"
            return 0
        }
    else
        # 同名文件不一定就是 Swap：复用前按 SWAPSPACE2 魔数确认。魔数固定在 PAGE_SIZE-10
        # 偏移（内核按页写 swap header），64K 页内核用 4086 会误判，因此按 getconf PAGE_SIZE
        # 计算；取不到时退回 4K 页。不是 Swap 就什么都不改（不 mkswap、不写 fstab、不 swapon）。
        local swap_page_size swap_magic_offset
        swap_page_size=$(getconf PAGE_SIZE 2>/dev/null || true)
        [[ "${swap_page_size}" =~ ^[0-9]{1,10}$ ]] || swap_page_size=4096
        swap_magic_offset=$((swap_page_size - 10))
        if [[ "$(dd if="${swap_file}" bs=1 skip="${swap_magic_offset}" count=10 2>/dev/null)" != "SWAPSPACE2" ]]; then
            warn "已存在非 Swap 的同名文件（${swap_file}）；跳过 Swap 配置"
            return 0
        fi
        chmod 0600 "${swap_file}"
        info "复用已有的 Swap 文件（${swap_file}）"
    fi
    if ! swapon "${swap_file}" 2>/dev/null; then
        if (( created_new == 1 )); then
            warn "启用 Swap 文件失败（可能是容器环境或只读文件系统）；已删除新建的 Swap 文件并跳过"
            rm -f -- "${swap_file}"
        else
            # 复用路径不能删用户原有文件（可能是别处配置的 Swap），只跳过后续写入。
            warn "启用 Swap 文件失败（可能是容器环境或只读文件系统）；保留已有文件并跳过"
        fi
        return 0
    fi
    if [[ -f "${fstab_file}" ]] && ! grep -q "^${swap_file}[[:space:]]" "${fstab_file}" 2>/dev/null; then
        if [[ -s "${fstab_file}" && -n "$(tail -c 1 "${fstab_file}" 2>/dev/null)" ]]; then
            printf '\n' >>"${fstab_file}"
        fi
        printf '%s none swap sw 0 0\n' "${swap_file}" >>"${fstab_file}"
    fi
    success "已成功配置并启用 1GB Swap（${swap_file}）"
}

packages_already_installed() {
    local pkg
    for pkg in "$@"; do
        if ! dpkg -s "${pkg}" 2>/dev/null | grep -q "^Status: install ok installed"; then
            return 1
        fi
    done
    return 0
}

snapshot_ipv6_state() {
    local backup_dir="${BACKUP_DIR:-${STATE_DIR:-/etc/easy_all}/backups}"
    local destination="${backup_dir}/pre-install-ipv6-runtime.conf"
    local key value
    install -d -m 0700 "${backup_dir}"
    if [[ ! -e "${backup_dir}/pre-install-enable-ipv6.conf" \
        && ! -e "${backup_dir}/pre-install-enable-ipv6.missing" ]]; then
        if [[ -f "${IPV6_SYSCTL_CONF}" ]]; then
            install -m 0644 "${IPV6_SYSCTL_CONF}" "${backup_dir}/pre-install-enable-ipv6.conf"
        else
            install -m 0600 /dev/null "${backup_dir}/pre-install-enable-ipv6.missing"
        fi
    fi
    if [[ ! -e "${destination}" ]]; then
        install -m 0600 /dev/null "${destination}"
        for key in net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6; do
            value=$(sysctl -n "${key}" 2>/dev/null) || continue
            printf '%s = %s\n' "${key}" "${value}" >>"${destination}"
        done
    fi
}

configure_ipv4_only() {
    [[ -d "${EASY_ALL_PROC_IPV6_DIR:-/proc/sys/net/ipv6}" ]] || return 0
    local tmp_dir="${RUNTIME_TMP:-/tmp}" tmp_file
    # 固定文件名会被同机其他进程/用户预置（软链接或并发截断），用 mktemp 保证独占后再 install。
    tmp_file=$(mktemp "${tmp_dir}/enable-ipv6.XXXXXX") \
        || die "创建 IPv4-only 策略临时文件失败（${tmp_dir}）"
    cat >"${tmp_file}" <<'EOF'
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    if ! install -m 0644 "${tmp_file}" "${IPV6_SYSCTL_CONF}"; then
        rm -f -- "${tmp_file}"
        die "写入 IPv4-only 策略文件失败：${IPV6_SYSCTL_CONF}"
    fi
    rm -f -- "${tmp_file}"
    sysctl -p "${IPV6_SYSCTL_CONF}" >/dev/null \
        || die "应用全局 IPv4-only 策略失败"
}

restore_preinstall_ipv6() {
    local backup_dir="${BACKUP_DIR:-${STATE_DIR:-/etc/easy_all}/backups}"
    local runtime_conf="${backup_dir}/pre-install-ipv6-runtime.conf"
    local line key value
    [[ -e "${backup_dir}/pre-install-enable-ipv6.conf" \
        || -e "${backup_dir}/pre-install-enable-ipv6.missing" ]] || return 0
    if [[ -f "${backup_dir}/pre-install-enable-ipv6.conf" ]]; then
        install -m 0644 "${backup_dir}/pre-install-enable-ipv6.conf" "${IPV6_SYSCTL_CONF}"
        sysctl -p "${IPV6_SYSCTL_CONF}" >/dev/null 2>&1 || true
    else
        rm -f -- "${IPV6_SYSCTL_CONF}"
        if [[ -s "${runtime_conf}" ]]; then
            while IFS= read -r line || [[ -n "${line}" ]]; do
                [[ "${line}" == *=* ]] || continue
                key=${line%% = *}
                value=${line#* = }
                key=${key//[[:space:]]/}
                value=${value//[[:space:]]/}
                [[ -n "${key}" ]] || continue
                sysctl -w "${key}=${value}" >/dev/null 2>&1 || true
            done <"${runtime_conf}"
        else
            sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || true
            sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || true
        fi
    fi
}

snapshot_platform_security_state() {
    local sentinel="${BACKUP_DIR}/pre-install-platform-security.snapshotted"
    [[ ! -e "${sentinel}" ]] || return 0
    install -d -m 0700 "${BACKUP_DIR}"
    if [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]]; then
        install -m 0600 "${EASY_ALL_SSH_PORT_CONFIG}" "${BACKUP_DIR}/pre-install-ssh-port.conf"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ssh-port.conf.missing"
    fi
    install -m 0600 /dev/null "${sentinel}"
}

restore_platform_security_state() {
    local sshd_bin="" unit="" sentinel="${BACKUP_DIR}/pre-install-platform-security.snapshotted"
    local current_ssh_config="${RUNTIME_TMP}/current-easy-all-ssh-port.conf" current_ssh_had=0
    local ssh_config_restored=1
    if [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]]; then
        install -m 0600 "${EASY_ALL_SSH_PORT_CONFIG}" "${current_ssh_config}" || return 1
        current_ssh_had=1
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-ssh-port.conf" ]]; then
        if ! install -d -m 0755 "$(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}")" \
            || ! install -m 0644 "${BACKUP_DIR}/pre-install-ssh-port.conf" \
                "${EASY_ALL_SSH_PORT_CONFIG}"; then
            ssh_config_restored=0
        fi
    elif [[ -f "${BACKUP_DIR}/pre-install-ssh-port.conf.missing" \
        || ( ! -e "${sentinel}" \
            && -f "${EASY_ALL_SSH_PORT_CONFIG}" \
            && "$(<"${EASY_ALL_SSH_PORT_CONFIG}")" == *"Managed by easy_all"* ) ]]; then
        rm -f -- "${EASY_ALL_SSH_PORT_CONFIG}" || ssh_config_restored=0
    fi
    # 安装收尾注释掉的 Port 行必须一并还原，否则恢复后的 sshd 仍只监听 22222。
    restore_post_install_sshd_backups || ssh_config_restored=0
    reload_ssh_socket_generator

    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    local expected_listeners="" ssh_restored=0 attempt
    if ((ssh_config_restored == 1)) && [[ -n "${sshd_bin}" ]] \
        && run_sshd_check "${sshd_bin}" -t >/dev/null 2>&1; then
        expected_listeners=$(ssh_effective_listeners "${sshd_bin}") || expected_listeners=""
        for unit in ssh.service sshd.service; do
            systemctl cat "${unit}" >/dev/null 2>&1 || continue
            if [[ -n "${expected_listeners}" ]]; then
                # SIGHUP re-reads the config but does not reliably rebind listen
                # sockets on every OpenSSH build, so verify and fall back to a
                # restart. A restart keeps established SSH sessions alive.
                if systemctl reload "${unit}" >/dev/null 2>&1 \
                    && wait_for_ssh_listeners "${expected_listeners}"; then
                    ssh_restored=1
                elif systemctl restart "${unit}" >/dev/null 2>&1 \
                    && wait_for_ssh_listeners "${expected_listeners}"; then
                    ssh_restored=1
                fi
            fi
            break
        done
    fi
    if ((ssh_restored == 0)); then
        warn "SSH 监听未收敛（仅 IPv4）：期望 [$(tr '\n' ' ' <<<"${expected_listeners}")]，实际 [$(ssh_actual_listeners 2>/dev/null | tr '\n' ' ')]"
        warn "SSH 配置或实际监听未收敛；保留当前 SSH 配置、防火墙、状态与备份，卸载/回滚未完成"
        restore_managed_ssh_port_config "${sshd_bin}" "${unit}" "${current_ssh_config}" "${current_ssh_had}" \
            || warn "尝试保留恢复前的 SSH 配置或重载失败，请立即通过 Console 检查"
        return 1
    fi

    # 卸载与安装失败回滚都不回收常驻安全基线：保留 Fail2ban jail/action/helper、
    # 封禁规则与运行状态。
}

# --- sshd 调用与 /run/sshd 兜底 ------------------------------------------------

# 容器与精简镜像常常没有 /run/sshd，sshd -t/-T 会直接报
# 「Missing privilege separation directory」；目录缺失时按 sshd 的要求补齐。
ensure_sshd_privsep_dir() {
    local privsep_dir=${1:-${EASY_ALL_SSHD_PRIVSEP_DIR:-/run/sshd}} parent
    [[ -n "${privsep_dir}" && ! -d "${privsep_dir}" ]] || return 0
    parent=$(dirname -- "${privsep_dir}")
    [[ -d "${parent}" && -w "${parent}" ]] || return 0
    install -d -m 0755 "${privsep_dir}" >/dev/null 2>&1 || true
}

# 统一的 sshd -t/-T 调用：成功才透传 stdout；最终失败把捕获的 stderr 交回调用方，
# 由调用方决定 die 还是 return 1。privsep 目录缺失时补齐后重试一次。
run_sshd_check() {
    local sshd_bin=$1 mode=$2 attempt dir="${EASY_ALL_SSHD_PRIVSEP_DIR:-/run/sshd}"
    local output="" stderr_log="" errtext=""
    stderr_log=$(mktemp "${RUNTIME_TMP:-${TMPDIR:-/tmp}}/easy-all-sshd-check.XXXXXX" 2>/dev/null || true)
    [[ -n "${stderr_log}" ]] || stderr_log="${TMPDIR:-/tmp}/easy-all-sshd-check.$$"
    for attempt in 1 2; do
        ensure_sshd_privsep_dir "${dir}"
        if output=$("${sshd_bin}" "${mode}" 2>"${stderr_log}"); then
            rm -f -- "${stderr_log}"
            printf '%s' "${output}"
            return 0
        fi
        [[ "${attempt}" == "1" ]] || break
        errtext=$(<"${stderr_log}")
        [[ "${errtext}" =~ Missing\ privilege\ separation\ directory:[[:space:]]*([^[:space:]]+) ]] || break
        dir=${BASH_REMATCH[1]}
    done
    cat -- "${stderr_log}" >&2 2>/dev/null || true
    rm -f -- "${stderr_log}"
    return 1
}

# 当前登录会话的服务端端口：sudo 会清空 SSH_*，因此保留进程树 + established 连接的回退。
detect_current_ssh_login_port() {
    local port="" pid="${PPID:-}" comm="" endpoint=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        read -r _ _ _ port <<<"${SSH_CONNECTION}"
    fi
    if [[ -z "${port}" && -n "${SSH_CLIENT:-}" ]]; then
        read -r _ _ port <<<"${SSH_CLIENT}"
    fi
    if [[ -z "${port}" ]]; then
        while [[ -n "${pid}" && "${pid}" != "0" && "${pid}" != "1" ]]; do
            comm=$(ps -o comm= -p "${pid}" 2>/dev/null || true)
            comm=${comm//[[:space:]]/}
            [[ "${comm}" != sshd* ]] || break
            pid=$(ps -o ppid= -p "${pid}" 2>/dev/null || true)
            pid=${pid//[[:space:]]/}
        done
        if [[ "${comm:-}" == sshd* ]]; then
            # $4 是本端地址:端口（ss -tn 的输出为 State Recv-Q Send-Q Local Peer）。
            endpoint=$(ss -H -tnp state established 2>/dev/null \
                | awk -v owner="pid=${pid}," 'index($0, owner) {print $4; exit}')
            port=${endpoint##*:}
        fi
    fi
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
    ((10#${port} >= 1 && 10#${port} <= 65535)) || return 1
    printf '%s' "${port}"
}

# 交互终端判定：生产只认 stdin 终端；自动化测试通过覆盖本函数模拟交互终端。
ssh_port_migration_interactive() {
    [[ -t 0 ]]
}

# 目标端口的业务冲突校验：命中时打印原因并返回 0（供提示循环复用），否则返回 1。
ssh_target_port_conflicts() {
    local port=$1 business="" endpoint=""
    for endpoint in 80 443 8443; do
        [[ "${port}" != "${endpoint}" ]] || { printf '与业务入口端口 %s 冲突' "${port}"; return 0; }
    done
    if declare -F runtime_public_tcp_ports >/dev/null 2>&1; then
        business=$(runtime_public_tcp_ports 2>/dev/null || true)
    fi
    if declare -F runtime_cloudflare_only_port >/dev/null 2>&1; then
        business+=" $(runtime_cloudflare_only_port 2>/dev/null || true)"
    fi
    for endpoint in ${business}; do
        [[ "${port}" != "${endpoint}" ]] || { printf '与业务端口 %s 冲突' "${port}"; return 0; }
    done
    # 已被其他进程监听的端口不可用；sshd/systemd 的既有监听不算冲突（迁移前就是它们占着旧端口）。
    if ss -H -ltnp "sport = :${port}" 2>/dev/null \
        | awk -v p=":${port}" '/users:/ && $4 ~ (p "$") && $0 !~ /users:.*\("(sshd|systemd)"/ {found = 1} END {exit !found}'; then
        printf '端口 %s 已被其他进程监听' "${port}"
        return 0
    fi
    return 1
}

# 交互询问目标端口：三选一菜单（不变更 / 默认 22222 / 自定义）。
# 结果直接写入指定变量（终端读不能放进 $( ) 子 shell）；「不变更」写入空字符串。
prompt_target_ssh_port() {
    local variable=$1 choice="" port="" reason=""
    while :; do
        printf '%s\n' "当前检测到的 SSH 端口：${SSH_PORTS:-未知}" \
            "请选择 SSH 端口变更方式：" \
            "  1. 不变更（保持当前 SSH 端口）" \
            "  2. 修改为 22222（默认）" \
            "  3. 自定义端口" >&2
        read_prompt '请选择 [2]（直接回车默认 2）: ' choice
        choice=${choice//[[:space:]]/}
        case "${choice:-2}" in
        1)
            printf -v "${variable}" '%s' ""
            return 0
            ;;
        2)
            if reason=$(ssh_target_port_conflicts 22222); then
                warn "端口不可用：${reason}"
                continue
            fi
            printf -v "${variable}" '%s' 22222
            return 0
            ;;
        3) ;;
        *)
            warn "无效选项：请输入 1、2 或 3"
            continue
            ;;
        esac
        while :; do
            read_prompt '请输入迁移后的 SSH 端口: ' port
            port=${port//[[:space:]]/}
            if [[ -z "${port}" || ! "${port}" =~ ^[1-9][0-9]{0,4}$ ]] \
                || ((10#${port} > 65535)); then
                warn "端口无效：请输入 1..65535 之间的十进制端口（不接受前导零）"
                continue
            fi
            if reason=$(ssh_target_port_conflicts "${port}"); then
                warn "端口不可用：${reason}"
                continue
            fi
            printf -v "${variable}" '%s' "${port}"
            return 0
        done
    done
}

# 迁移后的有效端口必须只有目标端口：显式 ListenAddress 携带的旧端口只出现在
# listenaddress 行里，因此 port 与 IPv4 listenaddress 都要比较。
sshd_t_has_only_port() {
    awk -v target="${2:-}" '
        $1 == "port" {p = $2}
        $1 == "listenaddress" && $2 !~ /\[/ {p = $2; sub(/.*:/, "", p)}
        p != "" {
            if (p != target) bad = 1
            else found = 1
            p = ""
        }
        END {exit !(found && !bad)}
    ' <<<"${1:-}"
}

# 受管片段里记录的迁移目标端口：apply 等新进程靠它识别「已迁移未重启」窗口。
ssh_managed_target_port() {
    local port=""
    [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]] || return 1
    grep -Fqx '# Managed by easy_all' "${EASY_ALL_SSH_PORT_CONFIG}" 2>/dev/null || return 1
    port=$(awk '$1 == "Port" {print $2; exit}' "${EASY_ALL_SSH_PORT_CONFIG}")
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] || return 1
    printf '%s' "${port}"
}

append_ssh_port() {
    local port=$1
    [[ "${port}" =~ ^[0-9]+$ ]] || return 0
    ((10#${port} >= 1 && 10#${port} <= 65535)) || return 0
    case " ${SSH_PORTS:-} " in
    *" ${port} "*) ;;
    *)
        [[ -z "${SSH_PORTS:-}" ]] || SSH_PORTS+=" "
        SSH_PORTS+="${port}"
        ;;
    esac
}

detect_ssh_ports() {
    local strict=${1:-} current_port sshd_bin config output="" actual="" effective="" login_port=""
    local endpoint fallback=""
    SSH_PORTS=""
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    login_port=$(detect_current_ssh_login_port 2>/dev/null || true)
    if [[ -n "${sshd_bin}" ]]; then
        output=$(run_sshd_check "${sshd_bin}" -T) || {
            output=""
            [[ "${strict}" != strict ]] || die "无法读取有效 SSH 配置；保留现有防火墙"
        }
        effective=$(awk '$1 == "listenaddress" && $2 !~ /\[/ {print $2}' <<<"${output}")
    fi
    actual=$(ssh_actual_listeners sshd) || {
        [[ "${strict}" != strict ]] || die "无法读取实际 SSH 监听；保留现有防火墙"
    }
    # ssh.socket 激活态：监听套接字由 systemd 持有，sshd 进程自己没有监听，
    # 此时只接受与有效配置端口或当前登录端口一致的 systemd 监听项。
    if [[ -z "${actual}" ]]; then
        local effective_ports=""
        for endpoint in ${effective}; do
            effective_ports+=" ${endpoint##*:}"
        done
        while read -r endpoint; do
            current_port=${endpoint##*:}
            [[ "${current_port}" =~ ^[0-9]+$ ]] || continue
            if [[ "${effective_ports} " == *" ${current_port} "* \
                || "${current_port}" == "${login_port}" ]]; then
                fallback+="${fallback:+$'\n'}${endpoint}"
            fi
        done < <(ssh_actual_listeners 2>/dev/null || true)
        actual="${fallback}"
    fi
    if [[ "${strict}" == strict && ( -z "${effective}" || -z "${actual}" ) ]]; then
        die "无法确定有效 IPv4 SSH 监听集合；保留现有防火墙"
    fi
    for current_port in ${effective} ${actual}; do
        append_ssh_port "${current_port##*:}"
    done
    append_ssh_port "${login_port}"
    if [[ -n "${output}" ]]; then
        while read -r current_port; do
            append_ssh_port "${current_port}"
        done < <(awk '$1 == "port" {print $2}' <<<"${output}")
    fi
    for config in "${EASY_ALL_SSHD_CONFIG}" "${EASY_ALL_SSHD_CONFIG_DIR}"/*.conf; do
        [[ -f "${config}" ]] || continue
        while read -r current_port; do
            append_ssh_port "${current_port}"
        done < <(awk '
            /^[[:space:]]*#/ {next}
            tolower($1) == "port" {print $2}
        ' "${config}")
    done
    if [[ -z "${SSH_PORTS}" ]]; then
        [[ "${strict}" != strict ]] || die "未检测到有效 SSH 端口；保留现有防火墙"
        SSH_PORTS="22"
    fi
}

# sshd -T may retain Port entries alongside explicit ListenAddress endpoints.
# Only the effective IPv4 endpoints determine the supported listener set; the
# actual socket list is filtered the same way, because a restored pre-install
# sshd legitimately binds both 0.0.0.0 and [::] on its port.
ssh_effective_listeners() {
    local output
    output=$(run_sshd_check "$1" -T) || return 1
    awk '$1 == "listenaddress" && $2 !~ /\[/ {print $2}' <<<"${output}" | sort -u
}

ssh_actual_listeners() {
    local output
    output=$(ss -H -ltnp 2>/dev/null) || return 1
    awk -v owner="${1:-}" '
        /users:\(\("(sshd|systemd)"/ && $4 !~ /^\[/ {
            if (owner == "sshd" && $0 !~ /users:.*\("sshd"/) next
            print $4
        }
    ' <<<"${output}" | sort -u
}

wait_for_ssh_listeners() {
    local expected=$1 attempt
    for attempt in {1..10}; do
        ssh_listeners_match "${expected}" && return 0
        sleep 0.5
    done
    return 1
}

ssh_listeners_match() {
    local expected=$1 actual endpoint
    [[ -n "${expected}" ]] || return 1
    actual=$(ssh_actual_listeners) || return 1
    [[ "${actual}" == "${expected}" ]] || return 1
    # Endpoint equality alone cannot prove that a systemd socket serves SSH.
    while read -r endpoint; do
        ssh_managed_port_is_listening "${endpoint##*:}" || return 1
    done <<<"${expected}"
}

ssh_managed_port_is_listening() {
    local port=$1 output
    output=$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)
    [[ -n "${output}" ]] || return 1
    # A systemd-owned socket alone does not identify its protocol. Require an
    # sshd owner, including sockets whose users list starts with systemd.
    ! grep -Ev 'users:.*\("sshd"' <<<"${output}" >/dev/null
}

restore_managed_ssh_port_config() {
    local sshd_bin=$1 unit=$2 backup_file=$3 had_config=$4
    if [[ "${had_config}" == "1" ]]; then
        install -m 0644 "${backup_file}" "${EASY_ALL_SSH_PORT_CONFIG}" || return 1
    else
        rm -f -- "${EASY_ALL_SSH_PORT_CONFIG}" || return 1
    fi
    run_sshd_check "${sshd_bin}" -t >/dev/null 2>&1 && systemctl reload "${unit}" >/dev/null 2>&1
}

install_fail2ban_dependencies() {
    local package needs_install=0
    for package in fail2ban python3-systemd; do
        dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null \
            | grep -qx 'ii ' || needs_install=1
    done
    if [[ "${needs_install}" == "1" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends fail2ban python3-systemd
    fi
    command -v fail2ban-client >/dev/null 2>&1 \
        || die "Fail2ban 安装后仍不可用"
}

restore_managed_fail2ban_file() {
    local destination=$1 backup_file=$2 had_config=$3 mode=$4
    if [[ "${had_config}" == "1" ]]; then
        install -m "${mode}" "${backup_file}" "${destination}"
    else
        rm -f -- "${destination}"
    fi
}

restore_managed_fail2ban_config() {
    local jail_backup=$1 jail_had_config=$2 action_backup=$3 action_had_config=$4
    local helper_backup=$5 helper_had_config=$6
    restore_managed_fail2ban_file "${EASY_ALL_FAIL2BAN_CONFIG}" "${jail_backup}" \
        "${jail_had_config}" 0644
    restore_managed_fail2ban_file "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}" "${action_backup}" \
        "${action_had_config}" 0644
    restore_managed_fail2ban_file "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" "${helper_backup}" \
        "${helper_had_config}" 0755
    if fail2ban-client -t >/dev/null 2>&1; then
        systemctl restart fail2ban.service >/dev/null 2>&1 || true
    fi
}

write_fail2ban_cidr_ufw_helper() {
    local destination=$1
    cat >"${destination}" <<'EOF'
#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

fail2ban_cidr_usage() {
    printf 'usage: %s ban|unban IP [state-directory]\n' "${0##*/}" >&2
    exit 2
}

fail2ban_cidr_network_for_ip() {
    local address=$1 first second third fourth octet
    if [[ "${address}" == *:* ]]; then
        [[ "${address}" =~ ^[0-9A-Fa-f:.]+$ ]] || return 1
        # 产品仅支持 IPv4（README 与 lib/firewall.sh 的 set_ufw_ipv6 no 一致）：对 IPv6 调 ufw
        # 必然失败并把 fail2ban action 拖成报错，这里只留审计日志并按「无需处理」成功退出。
        logger -t easy_all "fail2ban 收到 IPv6 封禁请求（${address}）：本产品仅支持 IPv4，已跳过 UFW 操作" 2>/dev/null || true
        exit 0
    fi

    IFS=. read -r first second third fourth <<<"${address}"
    [[ -n "${first}" && -n "${second}" && -n "${third}" && -n "${fourth}" ]] || return 1
    for octet in "${first}" "${second}" "${third}" "${fourth}"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#${octet} <= 255)) || return 1
    done
    NETWORK="$((10#${first})).$((10#${second})).$((10#${third})).$((10#${fourth}))/32"
    STATE_KEY="v4-$((10#${first}))-$((10#${second}))-$((10#${third}))-$((10#${fourth}))"
}

fail2ban_cidr_acquire_lock() {
    exec 9>"${LOCK_FILE}" || return 1
    if command -v flock >/dev/null 2>&1; then
        flock -w 10 9 || {
            printf 'timed out waiting for Fail2ban CIDR ban lock\n' >&2
            return 1
        }
    else
        local attempt
        for attempt in {1..100}; do
            if mkdir "${LOCK_FILE}.d" 2>/dev/null; then
                return 0
            fi
            sleep 0.1
        done
        printf 'timed out waiting for Fail2ban CIDR ban lock\n' >&2
        return 1
    fi
}

fail2ban_cidr_rule_exists() {
    local target="${NETWORK%/32}"
    LC_ALL=C "${UFW_BIN}" status 2>/dev/null \
        | awk -v network="${target}" '
            $0 ~ /DENY[[:space:]]+IN/ {
                for (i = 1; i <= NF; i++) {
                    val = $i
                    sub(/\/32$/, "", val)
                    if (val == network) {
                        found = 1
                        break
                    }
                }
            }
            END {exit(found ? 0 : 1)}
        '
}

fail2ban_cidr_release_lock() {
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&- 2>/dev/null || true
    rmdir "${LOCK_FILE}.d" 2>/dev/null || true
}

fail2ban_cidr_read_count() {
    local value=0
    if [[ -f "${COUNT_FILE}" ]]; then
        read -r value <"${COUNT_FILE}" || value=""
        [[ "${value}" =~ ^[1-9][0-9]*$ ]] || {
            printf 'invalid Fail2ban CIDR ban state: %s\n' "${COUNT_FILE}" >&2
            return 1
        }
    fi
    printf '%s\n' "${value}"
}

fail2ban_cidr_main() {
    local action=${1:-} address=${2:-} state_dir=${3:-/var/lib/easy_all/fail2ban-ufw-cidr}
    local count temporary
    [[ "${action}" == "ban" || "${action}" == "unban" ]] || fail2ban_cidr_usage
    [[ -n "${address}" && "${state_dir}" == /* && "${state_dir}" != *[[:space:]]* ]] || fail2ban_cidr_usage
    fail2ban_cidr_network_for_ip "${address}" || {
        printf 'invalid IP address: %s\n' "${address}" >&2
        exit 2
    }

    UFW_BIN=${EASY_ALL_FAIL2BAN_UFW_BIN:-ufw}
    command -v "${UFW_BIN}" >/dev/null 2>&1 || {
        printf 'ufw command is unavailable: %s\n' "${UFW_BIN}" >&2
        exit 1
    }
    install -d -m 0700 "${state_dir}"
    LOCK_FILE="${state_dir}/.lock"
    COUNT_FILE="${state_dir}/${STATE_KEY}.count"
    fail2ban_cidr_acquire_lock
    trap fail2ban_cidr_release_lock EXIT
    count=$(fail2ban_cidr_read_count)

    case "${action}" in
    ban)
        if ((count == 0)) || ! fail2ban_cidr_rule_exists; then
            "${UFW_BIN}" insert 1 deny from "${NETWORK}" to any \
                comment easy_all-fail2ban-cidr >/dev/null
        fi
        temporary=$(mktemp "${COUNT_FILE}.XXXXXX")
        printf '%s\n' "$((count + 1))" >"${temporary}"
        mv -f -- "${temporary}" "${COUNT_FILE}"
        ;;
    unban)
        ((count > 0)) || return 0
        if ((count == 1)); then
            # 规则可能已被外部删除（手工 ufw delete / 被其他工具重建）：删除失败不能挡住计数文件清理，
            # 否则同一网段再也解不开（计数 >0 但规则已不在）。
            "${UFW_BIN}" --force delete deny from "${NETWORK}" to any >/dev/null 2>&1 || true
            rm -f -- "${COUNT_FILE}"
        else
            temporary=$(mktemp "${COUNT_FILE}.XXXXXX")
            printf '%s\n' "$((count - 1))" >"${temporary}"
            mv -f -- "${temporary}" "${COUNT_FILE}"
        fi
        ;;
    esac
}

fail2ban_cidr_main "$@"
EOF
    chmod 0755 "${destination}"
}

write_fail2ban_cidr_action_config() {
    local destination=$1
    cat >"${destination}" <<EOF
[Definition]
actionban = ${EASY_ALL_FAIL2BAN_CIDR_HELPER} ban <ip> ${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}
actionunban = ${EASY_ALL_FAIL2BAN_CIDR_HELPER} unban <ip> ${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}
EOF
}

wait_for_ssh_fail2ban() {
    local attempt
    for attempt in {1..20}; do
        if systemctl is-active --quiet fail2ban.service \
            && fail2ban-client status sshd >/dev/null 2>&1; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

ensure_ssh_fail2ban() {
    local jail_candidate action_candidate helper_candidate
    local jail_backup action_backup helper_backup ports_csv
    local jail_had_config=0 action_had_config=0 helper_had_config=0

    install_fail2ban_dependencies
    command -v ufw >/dev/null 2>&1 || die "未找到 UFW；无法启用 Fail2ban SSH 防护"
    if [[ -z "${SSH_PORTS:-}" ]]; then
        detect_ssh_ports strict
    fi
    ports_csv=$(tr -s ' ' ',' <<<"${SSH_PORTS}")
    ports_csv=${ports_csv#,}
    ports_csv=${ports_csv%,}
    [[ -n "${ports_csv}" ]] || die "无法确定 Fail2ban 需要保护的 SSH 端口"

    install -d -m 0755 "$(dirname -- "${EASY_ALL_FAIL2BAN_CONFIG}")" \
        "$(dirname -- "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}")" \
        "$(dirname -- "${EASY_ALL_FAIL2BAN_CIDR_HELPER}")"
    jail_candidate=$(mktemp "$(dirname -- "${EASY_ALL_FAIL2BAN_CONFIG}")/.easy-all-fail2ban.XXXXXX")
    action_candidate=$(mktemp "$(dirname -- "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}")/.easy-all-fail2ban-action.XXXXXX")
    helper_candidate=$(mktemp "$(dirname -- "${EASY_ALL_FAIL2BAN_CIDR_HELPER}")/.easy-all-fail2ban-helper.XXXXXX")
    jail_backup=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-fail2ban-jail-backup.XXXXXX")
    action_backup=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-fail2ban-action-backup.XXXXXX")
    helper_backup=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-fail2ban-helper-backup.XXXXXX")
    if [[ -f "${EASY_ALL_FAIL2BAN_CONFIG}" ]]; then
        install -m 0600 "${EASY_ALL_FAIL2BAN_CONFIG}" "${jail_backup}"
        jail_had_config=1
    fi
    if [[ -f "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}" ]]; then
        install -m 0600 "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}" "${action_backup}"
        action_had_config=1
    fi
    if [[ -f "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" ]]; then
        install -m 0700 "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" "${helper_backup}"
        helper_had_config=1
    fi
    cat >"${jail_candidate}" <<EOF
[sshd]
banaction = easy-all-ufw-cidr
usedns = no
bantime = 3h
findtime = 3m
maxretry = 6
bantime.increment = true
bantime.maxtime = 1w
enabled = true
backend = systemd
port = ${ports_csv}
EOF
    chmod 0644 "${jail_candidate}"
    write_fail2ban_cidr_action_config "${action_candidate}"
    chmod 0644 "${action_candidate}"
    write_fail2ban_cidr_ufw_helper "${helper_candidate}"
    bash -n "${helper_candidate}" || {
        rm -f -- "${jail_candidate}" "${action_candidate}" "${helper_candidate}" \
            "${jail_backup}" "${action_backup}" "${helper_backup}"
        die "Fail2ban CIDR 封禁辅助脚本语法校验失败"
    }

    if [[ -f "${EASY_ALL_FAIL2BAN_CONFIG}" ]] \
        && cmp -s "${jail_candidate}" "${EASY_ALL_FAIL2BAN_CONFIG}" \
        && [[ -f "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}" ]] \
        && cmp -s "${action_candidate}" "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}" \
        && [[ -x "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" ]] \
        && cmp -s "${helper_candidate}" "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" \
        && fail2ban-client -t >/dev/null 2>&1 \
        && systemctl is-enabled --quiet fail2ban.service \
        && systemctl is-active --quiet fail2ban.service \
        && fail2ban-client status sshd >/dev/null 2>&1; then
        rm -f -- "${jail_candidate}" "${action_candidate}" "${helper_candidate}" \
            "${jail_backup}" "${action_backup}" "${helper_backup}"
            info "Fail2ban 已保护 SSH 端口 ${SSH_PORTS}：IPv4 按单 IP 封禁；3 分钟失败 6 次，首次封禁 3 小时并递增至 1 周"
        return 0
    fi

    if ! install -m 0755 "${helper_candidate}" "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" \
        || ! install -m 0644 "${action_candidate}" "${EASY_ALL_FAIL2BAN_ACTION_CONFIG}" \
        || ! install -m 0644 "${jail_candidate}" "${EASY_ALL_FAIL2BAN_CONFIG}"; then
        restore_managed_fail2ban_config "${jail_backup}" "${jail_had_config}" \
            "${action_backup}" "${action_had_config}" "${helper_backup}" "${helper_had_config}"
        rm -f -- "${jail_candidate}" "${action_candidate}" "${helper_candidate}" \
            "${jail_backup}" "${action_backup}" "${helper_backup}"
        die "Fail2ban SSH 防护配置写入失败，已恢复原配置"
    fi
    if ! fail2ban-client -t >/dev/null 2>&1; then
        restore_managed_fail2ban_config "${jail_backup}" "${jail_had_config}" \
            "${action_backup}" "${action_had_config}" "${helper_backup}" "${helper_had_config}"
        rm -f -- "${jail_candidate}" "${action_candidate}" "${helper_candidate}" \
            "${jail_backup}" "${action_backup}" "${helper_backup}"
        die "Fail2ban SSH 防护配置校验失败，已恢复原配置"
    fi
    if ! systemctl enable fail2ban.service >/dev/null 2>&1 \
        || ! systemctl restart fail2ban.service \
        || ! wait_for_ssh_fail2ban; then
        restore_managed_fail2ban_config "${jail_backup}" "${jail_had_config}" \
            "${action_backup}" "${action_had_config}" "${helper_backup}" "${helper_had_config}"
        rm -f -- "${jail_candidate}" "${action_candidate}" "${helper_candidate}" \
            "${jail_backup}" "${action_backup}" "${helper_backup}"
        die "Fail2ban SSH 防护启动失败，已恢复原配置"
    fi
    rm -f -- "${jail_candidate}" "${action_candidate}" "${helper_candidate}" \
        "${jail_backup}" "${action_backup}" "${helper_backup}"
    info "Fail2ban 已保护 SSH 端口 ${SSH_PORTS}：IPv4 按单 IP 封禁；3 分钟失败 6 次，首次封禁 3 小时并递增至 1 周"
}

ensure_ssh_boot_service() {
    local sshd_bin unit
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    [[ -n "${sshd_bin}" ]] || die "未找到 sshd；无法保证重启后 SSH 可用"
    run_sshd_check "${sshd_bin}" -t \
        || die "sshd 配置校验失败；无法保证重启后 SSH 可用，已中止"

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
    die "未找到 ssh.service 或 sshd.service；无法保证重启后 SSH 可用，已中止"
}

# --- 安装收尾的 SSH 端口迁移 ------------------------------------------------
# 只写 sshd_config.d 片段并按需改写 Port / ListenAddress 端口，再 daemon-reload；
# 绝不重启 sshd / ssh.socket，当前安装会话靠已建立的 TCP 连接维持，新端口下次开机生效。

# ssh.socket 的 ListenStream 由 generator 从 sshd_config 生成，需要 daemon-reload 重新生成。
reload_ssh_socket_generator() {
    systemctl is-enabled --quiet ssh.socket >/dev/null 2>&1 \
        || systemctl is-active --quiet ssh.socket >/dev/null 2>&1 \
        || return 0
    systemctl daemon-reload >/dev/null 2>&1 || true
}

sshd_config_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || true
}

# 备份名用 main-/d- 前缀编码归属：主配置还原到 EASY_ALL_SSHD_CONFIG，其余回 sshd_config.d。
restore_post_install_sshd_backups() {
    local backup_dir="${BACKUP_DIR}/sshd-port-backup" backup name target mode restored=1
    [[ -d "${backup_dir}" ]] || return 0
    for backup in "${backup_dir}"/*; do
        [[ -f "${backup}" ]] || continue
        name=${backup##*/}
        case "${name}" in
        main-*) target=${EASY_ALL_SSHD_CONFIG} ;;
        d-*)
            target="${EASY_ALL_SSHD_CONFIG_DIR}/${name#d-}"
            install -d -m 0755 "${EASY_ALL_SSHD_CONFIG_DIR}" || { restored=0; continue; }
            ;;
        *) continue ;;
        esac
        mode=$(sshd_config_mode "${backup}")
        [[ -n "${mode}" ]] || mode=0644
        install -m "${mode}" "${backup}" "${target}" || restored=0
    done
    ((restored == 1))
}

rollback_post_install_ssh_config() {
    if [[ -f "${BACKUP_DIR}/pre-install-ssh-port.conf" ]]; then
        install -d -m 0755 "$(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}")" \
            && install -m 0644 "${BACKUP_DIR}/pre-install-ssh-port.conf" \
                "${EASY_ALL_SSH_PORT_CONFIG}" \
            || warn "恢复 ${EASY_ALL_SSH_PORT_CONFIG} 失败"
    else
        rm -f -- "${EASY_ALL_SSH_PORT_CONFIG}" || warn "删除 ${EASY_ALL_SSH_PORT_CONFIG} 失败"
    fi
    restore_post_install_sshd_backups || warn "恢复 sshd 端口备份失败；请人工核对 SSH 配置"
    reload_ssh_socket_generator
}

# 「已迁移到 target_port 但尚未重启」的判定：配置文件与 sshd -T 都已经只认新端口。
ssh_post_install_port_migrated() {
    local target_port=${1:-} sshd_bin output
    [[ -n "${target_port}" ]] || target_port=${EASY_ALL_TARGET_SSH_PORT:-}
    [[ -n "${target_port}" ]] || target_port=$(ssh_managed_target_port || printf '22222')
    [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]] || return 1
    grep -Fq "Managed by easy_all" "${EASY_ALL_SSH_PORT_CONFIG}" 2>/dev/null || return 1
    grep -qx "Port ${target_port}" "${EASY_ALL_SSH_PORT_CONFIG}" 2>/dev/null || return 1
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    [[ -n "${sshd_bin}" ]] || return 1
    output=$(run_sshd_check "${sshd_bin}" -T 2>/dev/null) || return 1
    sshd_t_has_only_port "${output}" "${target_port}"
}

configure_post_install_ssh_port() {
    local target_port=${1:-}
    local sshd_bin sshd_t_out config candidate backup_dir backup_file listen_out mode
    local old_ports="" old_port reason=""
    local -a pending_denies=()
    sshd_bin=$(command -v sshd 2>/dev/null || true)
    [[ -n "${sshd_bin}" || ! -x /usr/sbin/sshd ]] || sshd_bin=/usr/sbin/sshd
    [[ -n "${sshd_bin}" ]] || die "未找到 sshd；无法迁移 SSH 端口"

    # 顺序固定：先采集旧端口（交互提示要展示、UFW 禁用与迁移校验都依赖它），再解析目标端口。
    detect_ssh_ports
    old_ports=${SSH_PORTS}
    EASY_ALL_MIGRATED_FROM_SSH_PORTS="${old_ports}"
    # 收尾的 prompt_kernel_reboot 靠它区分「已迁移」与「选了不变更」，故必须对同进程可见（不用 local）。
    EASY_ALL_SSH_PORT_CHANGED=1
    if [[ -z "${target_port}" ]]; then
        target_port=${EASY_ALL_TARGET_SSH_PORT:-}
    fi
    if [[ -n "${target_port}" ]]; then
        if [[ ! "${target_port}" =~ ^[1-9][0-9]{0,4}$ ]] || ((10#${target_port} > 65535)); then
            die "SSH 目标端口无效：${target_port}（需为 1..65535 的十进制端口）"
        fi
        if reason=$(ssh_target_port_conflicts "${target_port}"); then
            die "SSH 目标端口不可用：${reason}"
        fi
    elif ssh_port_migration_interactive; then
        prompt_target_ssh_port target_port
        # 菜单返回空字符串表示「1. 不变更」：sshd 配置、受管片段与 UFW 全部保持原样。
        if [[ -z "${target_port}" ]]; then
            EASY_ALL_SSH_PORT_CHANGED=0
            EASY_ALL_TARGET_SSH_PORT=""
            info "已保留当前 SSH 端口（${old_ports}），不做变更"
            return 0
        fi
    else
        target_port=22222
    fi
    EASY_ALL_TARGET_SSH_PORT="${target_port}"

    # 只读预检先行：第三方 UFW 已阻断新端口时直接中止，此时尚未改动任何文件。
    verify_ssh_ufw_no_unmanaged_block "${target_port}"

    backup_dir="${BACKUP_DIR}/sshd-port-backup"
    install -d -m 0700 "${BACKUP_DIR}" "${backup_dir}" || die "创建 SSH 配置备份目录失败"
    install -d -m 0755 "$(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}")" \
        || die "创建 $(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}") 失败"
    candidate=$(mktemp "$(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}")/.easy-all-ports.XXXXXX") \
        || die "创建 SSH 端口配置候选文件失败"
    printf '# Managed by easy_all\nPort %s\n' "${target_port}" >"${candidate}"
    chmod 0644 "${candidate}"
    mv -f -- "${candidate}" "${EASY_ALL_SSH_PORT_CONFIG}" \
        || die "写入 ${EASY_ALL_SSH_PORT_CONFIG} 失败"

    for config in "${EASY_ALL_SSHD_CONFIG}" "${EASY_ALL_SSHD_CONFIG_DIR}"/*.conf; do
        [[ -f "${config}" && "${config}" != "${EASY_ALL_SSH_PORT_CONFIG}" ]] || continue
        candidate=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-sshd-port.XXXXXX") \
            || die "创建 sshd 配置候选文件失败"
        if ! awk -v target="${target_port}" '
            /^[[:space:]]*#/ {print; next}
            tolower($1) == "port" && $2 != target {
                printf "# easy_all-disabled-port: %s\n", $0
                next
            }
            tolower($1) == "listenaddress" {
                # 只动显式带端口的形态（host:port、[v6]:port、:port）；裸 IPv6 地址不动。
                addr = $2
                if ((addr ~ /^[^:]+:[0-9]+$/ || addr ~ /\]:[0-9]+$/ || addr ~ /^:[0-9]+$/) \
                    && addr !~ (":" target "$")) {
                    # 只换地址字段里的端口，保留缩进、关键词与行尾注释。
                    sub(/:[0-9]+/, ":" target)
                }
            }
            {print}
        ' "${config}" >"${candidate}"; then
            rm -f -- "${candidate}"
            rollback_post_install_ssh_config
            die "生成 ${config} 的端口迁移候选失败；已恢复原 SSH 配置"
        fi
        if cmp -s "${candidate}" "${config}"; then
            rm -f -- "${candidate}"
            continue
        fi
        mode=$(sshd_config_mode "${config}")
        [[ -n "${mode}" ]] || mode=0644
        if [[ "${config}" == "${EASY_ALL_SSHD_CONFIG}" ]]; then
            backup_file="${backup_dir}/main-${config##*/}"
        else
            backup_file="${backup_dir}/d-${config##*/}"
        fi
        if [[ ! -f "${backup_file}" ]] \
            && ! install -m "${mode}" "${config}" "${backup_file}"; then
            rm -f -- "${candidate}"
            rollback_post_install_ssh_config
            die "备份 ${config} 失败；已恢复原 SSH 配置"
        fi
        if ! install -m "${mode}" "${candidate}" "${config}"; then
            rm -f -- "${candidate}"
            rollback_post_install_ssh_config
            die "注释 ${config} 中的旧 Port/ListenAddress 端口失败；已恢复原 SSH 配置"
        fi
        rm -f -- "${candidate}"
    done

    if ! run_sshd_check "${sshd_bin}" -t >/dev/null; then
        rollback_post_install_ssh_config
        die "SSH 端口迁移后 sshd 配置校验失败；已恢复原配置"
    fi
    sshd_t_out=$(run_sshd_check "${sshd_bin}" -T 2>/dev/null) || sshd_t_out=""
    if ! sshd_t_has_only_port "${sshd_t_out}" "${target_port}"; then
        rollback_post_install_ssh_config
        die "SSH 端口迁移后有效端口不是 ${target_port}（或仍包含其他端口）；已恢复原配置"
    fi
    if systemctl is-enabled --quiet ssh.socket >/dev/null 2>&1 \
        || systemctl is-active --quiet ssh.socket >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        listen_out=$(systemctl show -p Listen ssh.socket 2>/dev/null || true)
        if ! grep -Eq ":${target_port}([^0-9]|$)" <<<"${listen_out}"; then
            rollback_post_install_ssh_config
            die "ssh.socket 未按 ${target_port} 生成监听端口；已恢复原配置"
        fi
    fi
    # 记录本次才需要新增的受管 deny：失败时只撤销这些，不误删旧安装留下的规则。
    for old_port in ${old_ports}; do
        [[ "${old_port}" != "${target_port}" ]] || continue
        ufw_managed_ssh_deny_exists "${old_port}" && continue
        pending_denies+=("${old_port}")
    done
    # UFW 与 Fail2ban 内部用 die 退出：放进子 shell 才能捕获失败并先回滚 sshd 配置。
    if ! ( apply_post_install_ssh_ufw_policy "${target_port}" "${old_ports}" \
        && SSH_PORTS="${target_port}" \
        && ensure_ssh_fail2ban ); then
        for old_port in ${pending_denies[@]+"${pending_denies[@]}"}; do
            ufw --force delete deny "${old_port}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null 2>&1 || true
        done
        if ((${#pending_denies[@]} > 0)); then
            ufw reload >/dev/null 2>&1 || true
        fi
        rollback_post_install_ssh_config
        die "SSH 端口迁移后更新 UFW 或 Fail2ban 失败；已恢复原 SSH 配置"
    fi
    info "SSH 端口已迁移为 ${target_port}；原端口已禁用，重启后生效"
}
