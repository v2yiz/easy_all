#!/usr/bin/env bash

# Shared TCP acceleration and conservative TCP tuning.

readonly ZABBLY_KEY_URL="https://pkgs.zabbly.com/key.asc"
readonly ZABBLY_KEY_FINGERPRINT="4EFC590696CB15B87C73A3AD82CC8797C838DCFD"
readonly ZABBLY_REPOSITORY_URL="https://pkgs.zabbly.com/kernel/stable"
readonly ZABBLY_KEYRING="${ZABBLY_KEYRING_OVERRIDE:-/etc/apt/keyrings/zabbly.asc}"
readonly ZABBLY_SOURCE="${ZABBLY_SOURCE_OVERRIDE:-/etc/apt/sources.list.d/zabbly-kernel.sources}"
readonly ZABBLY_KERNEL_PACKAGE="linux-zabbly"
readonly SECUREBOOT_EFI_DIR="${SECUREBOOT_EFI_DIR_OVERRIDE:-/sys/firmware/efi}"
readonly SECUREBOOT_EFIVARS_DIR="${SECUREBOOT_EFIVARS_DIR_OVERRIDE:-${SECUREBOOT_EFI_DIR}/efivars}"
readonly KERNEL_BOOT_DIR="${KERNEL_BOOT_DIR_OVERRIDE:-/boot}"
readonly KERNEL_REBOOT_MARKER="${STATE_DIR}/kernel-reboot-required"
TCP_SYSCTL_CONF="${TCP_SYSCTL_CONF_OVERRIDE:-/etc/sysctl.d/99-easy_all-tcp.conf}"

readonly SKYLINE_VERSION="v0.5.1"
readonly SKYLINE_COMMIT="3b371629831da9823503ef303ba2028b40ba208a"
readonly SKYLINE_SOURCE_SHA256="7ae2a724f802e35dced7e61f0f51aa2449944fff8955222e02971e4b21174d44"
readonly SKYLINE_ARTIFACT_SHA256="7bf33c0a814ad6a7e40b11fe5819cd822db10fad1f882587c6da5023ac678858"
readonly SKYLINE_MINIMUM_KERNEL_VERSION="6.12"
readonly SKYLINE_SOURCE_DIR="${STATE_DIR}/skyline-speeder"
# 诊断日志不能放 STATE_DIR：安装失败回滚会整目录删除，日志会随提示一起消失。
readonly SKYLINE_LOG_DIR="/var/log/easy_all"
readonly SKYLINE_INSTALL_LOG="${SKYLINE_LOG_DIR}/skyline-speeder-install.log"
readonly SKYLINE_LOG_TAIL_LINES=20
readonly SKYLINE_BTF_FILE="${SKYLINE_BTF_FILE_OVERRIDE:-/sys/kernel/btf/vmlinux}"
readonly SKYLINE_CGROUP_FILE="${SKYLINE_CGROUP_FILE_OVERRIDE:-/sys/fs/cgroup/cgroup.controllers}"
EASY_ALL_TCP_DIR="${EASY_ALL_TCP_DIR_OVERRIDE:-/usr/local/lib/easy_all-tcp}"

require_supported_tcp_architecture() {
    local architecture
    architecture=$(dpkg --print-architecture) || die "无法识别系统架构"
    case "${architecture}" in
    amd64|arm64) ;;
    *) die "TCP 内核加速目前仅支持 amd64 与 arm64；当前架构 ${architecture} 请保留原有内核" ;;
    esac
}

choose_tcp_acceleration() {
    TCP_ACCELERATION="skyline"
}

check_skyline_requirements() {
    running_kernel_supported \
        || die "Skyline Speeder 需要 Linux 6.12+；请重启进入已安装的兼容内核后重试"
    [[ -r "${SKYLINE_BTF_FILE}" ]] \
        || die "Skyline Speeder 需要内核 BTF：${SKYLINE_BTF_FILE}"
    [[ -f "${SKYLINE_CGROUP_FILE}" ]] \
        || die "Skyline Speeder 需要挂载统一的 cgroup v2"
}

install_skyline_speeder() {
    local archive="${RUNTIME_TMP}/skyline-speeder.tar.gz"
    local stage previous
    if [[ -x "${SKYLINE_SOURCE_DIR}/install.sh" && -r "${SKYLINE_SOURCE_DIR}/.easy-all-commit" ]] \
        && [[ "$(<"${SKYLINE_SOURCE_DIR}/.easy-all-commit")" == "${SKYLINE_COMMIT}" ]]; then
        return 0
    fi
    local url="https://codeload.github.com/CYBERVERSE-Research/skyline-speeder/tar.gz/${SKYLINE_COMMIT}"
    local rc=0
    curl -fL --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 10 --max-time 180 \
        "${url}" -o "${archive}" || { rc=$?; skyline_fail "下载 Skyline Speeder 安装器失败：${url}" "${rc}"; }
    printf '%s  %s\n' "${SKYLINE_SOURCE_SHA256}" "${archive}" \
        | sha256sum -c - >/dev/null \
        || { rc=$?; skyline_fail "Skyline Speeder 源码 SHA256 校验失败：${archive}（期望 ${SKYLINE_SOURCE_SHA256}）" "${rc}"; }
    install -d -m 0700 "${STATE_DIR}"
    stage=$(mktemp -d "${STATE_DIR}/skyline-speeder.stage.XXXXXX") \
        || die "创建 Skyline Speeder 暂存目录失败"
    cleanup_files+=("${stage}")
    tar -xzf "${archive}" -C "${stage}" --strip-components=1 \
        || die "解压 Skyline Speeder 安装器失败"
    run_skyline_installer bash "${stage}/install.sh" --check \
        || { rc=$?; skyline_fail "Skyline Speeder 安装前检查失败：${stage}/install.sh --check" "${rc}"; }
    printf '%s\n' "${SKYLINE_COMMIT}" >"${stage}/.easy-all-commit" \
        || die "保存 Skyline Speeder 源码版本失败"
    # Retain the previous uninstaller until the verified replacement is in place.
    previous="${stage}.previous"
    if [[ -e "${SKYLINE_SOURCE_DIR}" ]]; then
        mv -- "${SKYLINE_SOURCE_DIR}" "${previous}" || die "备份 Skyline Speeder 安装器失败"
    fi
    if ! mv -- "${stage}" "${SKYLINE_SOURCE_DIR}"; then
        if [[ -e "${previous}" ]]; then
            mv -- "${previous}" "${SKYLINE_SOURCE_DIR}" \
                || warn "旧 Skyline Speeder 安装器保留在 ${previous}，请先恢复后重试"
        fi
        die "保留 Skyline Speeder 安装器失败"
    fi
    rm -rf -- "${previous}"
}

stop_skyline_speeder() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}" unit
    for unit in skyline-speeder-enable.service skyline-speederd.service; do
        [[ -f "${systemd_dir}/${unit}" ]] || continue
        systemctl disable --now "${unit}" \
            || die "停止 Skyline Speeder 失败：${unit}；请保留安装状态后重试"
    done
}

install_skyline_boot_setup() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    cat >"${systemd_dir}/easy_all-skyline-setup.service" <<EOF_SERVICE
[Unit]
Description=Install and activate Skyline Speeder after the kernel upgrade
After=network-online.target systemd-sysctl.service easy_all-fq.service
Wants=network-online.target
ConditionPathExists=${STATE_FILE}
ConditionPathExists=${KERNEL_REBOOT_MARKER}

[Service]
Type=oneshot
ExecStart="${COMMAND_PATH}" tcp-resume
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF_SERVICE
    systemctl daemon-reload || die "重新加载 Skyline 开机安装任务失败"
    systemctl enable easy_all-skyline-setup.service || die "启用 Skyline 开机安装任务失败"
}

remove_skyline_boot_setup() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    [[ -f "${systemd_dir}/easy_all-skyline-setup.service" ]] || return 0
    # A setup removing itself passes 0; cancellation must also stop an active job.
    if [[ "${1:-1}" == "1" ]]; then
        systemctl stop easy_all-skyline-setup.service || die "停止 Skyline 开机安装任务失败"
    fi
    systemctl disable easy_all-skyline-setup.service || die "取消 Skyline 开机安装任务失败"
    rm -f -- "${systemd_dir}/easy_all-skyline-setup.service"
    systemctl daemon-reload || die "重新加载 Skyline 开机安装任务失败"
}

resume_skyline_after_reboot() {
    (($# == 0)) || die "tcp-resume 不接受参数"
    require_root
    require_supported_tcp_architecture
    try_acquire_runtime_write_lock 60 \
        || die "Skyline 开机任务等待运行时锁 60 秒超时；已保留回退配置和开机任务，请在其他任务结束后执行 sudo easy_all apply 重试"
    collect_installed_state
    if [[ "${TCP_ACCELERATION}" != "skyline" || ! -f "${KERNEL_REBOOT_MARKER}" ]]; then
        remove_skyline_boot_setup 0
    else
        # A boot into the old kernel must fail, not schedule another upgrade/reboot.
        check_skyline_requirements
        configure_tcp_acceleration
    fi
    release_runtime_write_lock
}

check_skyline_build_memory() {
    local mem_total_kb swap_total_kb total_mb
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' "${EASY_ALL_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null || echo 0)
    swap_total_kb=$(awk '/SwapTotal:/ {print $2}' "${EASY_ALL_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null || echo 0)
    total_mb=$(( (mem_total_kb + swap_total_kb) / 1024 ))
    if (( total_mb > 0 && total_mb < 1536 )); then
        warn "当前系统总内存+交换空间仅 ${total_mb}MB（低于 1.5GB）；编译 Rust/BPF 可能耗尽内存，若遇编译失败建议配置 Swap"
    fi
}

skyline_build_jobs() {
    if [[ -n "${EASY_ALL_CARGO_BUILD_JOBS:-}" ]]; then
        printf '%s\n' "${EASY_ALL_CARGO_BUILD_JOBS}"
        return 0
    fi
    local mem_total_kb
    mem_total_kb=$(awk '/MemTotal:/ {print $2}' "${EASY_ALL_MEMINFO_FILE:-/proc/meminfo}" 2>/dev/null || echo 0)
    if (( mem_total_kb > 0 && mem_total_kb < 2097152 )); then
        printf '1\n'
    else
        printf '2\n'
    fi
}

# 日志目录/文件由 root 独占（0700 / 0600）。写入不可用时只告警，安装输出回退到终端直出。
skyline_prepare_log() {
    install -d -m 0700 "${SKYLINE_LOG_DIR}" 2>/dev/null \
        || { warn "无法创建 Skyline 日志目录 ${SKYLINE_LOG_DIR}；安装输出只显示在终端"; return 1; }
    if ! touch "${SKYLINE_INSTALL_LOG}" || ! chmod 0600 "${SKYLINE_INSTALL_LOG}"; then
        warn "无法写入 Skyline 安装日志 ${SKYLINE_INSTALL_LOG}；安装输出只显示在终端"
        return 1
    fi
    SKYLINE_LOG_READY=1
}

# 编译可能持续数分钟：输出继续上屏，同时落日志。tee 的退出码不能代替安装器自身的退出码。
run_skyline_installer() {
    local rc=0
    if [[ "${SKYLINE_LOG_READY:-0}" == "1" ]]; then
        "$@" 2>&1 | tee -a "${SKYLINE_INSTALL_LOG}" || rc=${PIPESTATUS[0]}
    else
        "$@" || rc=$?
    fi
    return "${rc}"
}

# 失败必须终止并给出阶段、退出码与日志尾部；仍然不写 BBR、不 warn 后继续、不报成功。
skyline_fail() {
    local stage=$1 rc=$2
    printf 'Skyline 安装日志：%s（末尾 %s 行）\n' \
        "${SKYLINE_INSTALL_LOG}" "${SKYLINE_LOG_TAIL_LINES}" >&2
    if [[ -r "${SKYLINE_INSTALL_LOG}" ]]; then
        tail -n "${SKYLINE_LOG_TAIL_LINES}" "${SKYLINE_INSTALL_LOG}" >&2 || true
    fi
    die "${stage}（退出码 ${rc}）"
}

# 区分服务状态、拥塞控制、qdisc 与物理接口 FQ：只报“验收失败”无法定位是哪一环没生效。
skyline_acceptance_summary() {
    local cc qdisc summary=""
    systemctl is-active --quiet skyline-speederd.service \
        || summary+="skyline-speederd.service 未运行；"
    systemctl is-active --quiet skyline-speeder-enable.service \
        || summary+="skyline-speeder-enable.service 未运行；"
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cc=unknown
    [[ "${cc}" == "skyline_cc" ]] || summary+="tcp_congestion_control=${cc}；"
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qdisc=unknown
    [[ "${qdisc}" == "fq" ]] || summary+="default_qdisc=${qdisc}；"
    physical_fq_active || summary+="物理接口未使用 fq 队列规则；"
    printf '%s' "${summary:-未找到具体差异}"
}

# 运行态验收失败先取现场：停服务会抹掉最有价值的 unit 状态与 journal。
skyline_runtime_diagnostics() {
    local unit cc qdisc
    for unit in skyline-speederd.service skyline-speeder-enable.service; do
        printf -- '--- %s ---\n' "${unit}" >&2
        systemctl is-active "${unit}" >&2 2>&1 || true
        systemctl show -p Result -p ExecMainStatus "${unit}" >&2 2>&1 || true
        journalctl -u "${unit}" -b --no-pager -n "${SKYLINE_LOG_TAIL_LINES}" >&2 2>&1 || true
    done
    cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || cc=unknown
    qdisc=$(sysctl -n net.core.default_qdisc 2>/dev/null) || qdisc=unknown
    printf 'tcp_congestion_control=%s default_qdisc=%s physical_fq_active=%s\n' \
        "${cc}" "${qdisc}" "$(physical_fq_active && printf yes || printf no)" >&2
}

configure_tcp_acceleration() {
    require_supported_tcp_architecture
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local glibc artifact="${RUNTIME_TMP}/skyline-speeder-${SKYLINE_VERSION}.tar.gz"
    local installed_commit="" installed_version architecture version_stderr_note=""
    local version_error_file="${RUNTIME_TMP}/skyline-speederd-version.err"
    local rc=0
    architecture=$(dpkg --print-architecture)
    TCP_ACCELERATION="skyline"
    if skyline_speeder_active; then
        configure_tcp_parameters
        # 输出不再丢弃：重启失败的原因要让用户看到（变身与否仍由随后的运行态验收决定）。
        systemctl restart skyline-speeder-enable.service \
            || systemctl enable --now skyline-speeder-enable.service \
            || warn "重启 Skyline 启用任务失败；以随后的运行态验收为准"
        skyline_speeder_active \
            || die "Skyline Speeder 重新启用失败（当前拥塞控制 $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo unknown)）；重试：sudo easy_all apply"
        info "Skyline Speeder 已在运行（fq + skyline_cc），TCP 参数已刷新"
        return 0
    fi
    if ! running_kernel_supported; then
        local on_disk
        on_disk=$(zabbly_kernel_release_on_disk)
        if [[ -f "${systemd_dir}/easy_all-skyline-setup.service" && -f "${KERNEL_REBOOT_MARKER}" ]] \
            && [[ -n "${on_disk}" ]] \
            && dpkg --compare-versions "${on_disk%%-*}" ge "${SKYLINE_MINIMUM_KERNEL_VERSION}"; then
            info "Zabbly 6.12+ LTS 兼容内核与 Skyline 开机自动安装任务已就绪（等待重启生效），跳过重复配置"
            return 0
        fi
        info "当前内核 $(uname -r) 低于 Linux 6.12，正在安装或升级兼容的 Zabbly 6.12+ LTS 内核"
        ensure_zabbly_kernel "${SKYLINE_MINIMUM_KERNEL_VERSION}"
        stop_skyline_speeder
        configure_tcp_parameters
        install -d -m 0700 "${STATE_DIR}"
        install -m 0600 /dev/null "${KERNEL_REBOOT_MARKER}"
        install_skyline_boot_setup
        warn "兼容内核已准备；Skyline 将在重启后自动安装启用，其余安装完成后只需重启一次"
        return 0
    fi
    check_skyline_requirements
    skyline_prepare_log || true
    install_skyline_speeder
    stop_skyline_speeder
    configure_tcp_parameters
    [[ ! -r "${SKYLINE_SOURCE_DIR}/.easy-all-installed" ]] \
        || installed_commit=$(<"${SKYLINE_SOURCE_DIR}/.easy-all-installed")
    installed_version=$(skyline-speederd --version 2>"${version_error_file}") \
        || installed_version=""
    if [[ "${installed_commit}" != "${SKYLINE_COMMIT}" \
        || "${installed_version}" != "skyline-speederd ${SKYLINE_VERSION#v}" \
        || ! -f "${systemd_dir}/skyline-speederd.service" \
        || ! -f "${systemd_dir}/skyline-speeder-enable.service" ]]; then
        glibc=$(getconf GNU_LIBC_VERSION) || die "无法检测 Skyline Speeder 的 glibc 兼容性"
        glibc=${glibc##* }
        if [[ "${architecture}" != "amd64" ]] || dpkg --compare-versions "${glibc}" lt 2.38; then
            warn "当前架构 ${architecture}（或 glibc ${glibc}）不支持预编译包，将从源码编译 Rust/BPF；可能耗时较长并占用较多 CPU、内存及磁盘，请勿中断安装"
            check_skyline_build_memory
            local cargo_jobs
            cargo_jobs=$(skyline_build_jobs)
            run_skyline_installer env "CARGO_BUILD_JOBS=${cargo_jobs}" \
                bash "${SKYLINE_SOURCE_DIR}/install.sh" --source --no-enable \
                || { rc=$?; skyline_fail "Skyline Speeder 源码安装失败：${SKYLINE_SOURCE_DIR}/install.sh --source（TCP 调优配置已保留）" "${rc}"; }
        else
            local artifact_url="https://github.com/CYBERVERSE-Research/skyline-speeder/releases/download/${SKYLINE_VERSION}/skyline-speeder-${SKYLINE_VERSION}-x86_64.tar.gz"
            curl -fL --proto '=https' --tlsv1.2 --retry 3 \
                --connect-timeout 10 --max-time 180 \
                "${artifact_url}" -o "${artifact}" \
                || { rc=$?; skyline_fail "下载 Skyline Speeder 预编译包失败：${artifact_url}" "${rc}"; }
            printf '%s  %s\n' "${SKYLINE_ARTIFACT_SHA256}" "${artifact}" >"${artifact}.sha256"
            sha256sum -c "${artifact}.sha256" >/dev/null \
                || { rc=$?; skyline_fail "Skyline Speeder 预编译包 SHA256 校验失败：${artifact}（期望 ${SKYLINE_ARTIFACT_SHA256}）" "${rc}"; }
            run_skyline_installer env "SKYLINE_ARTIFACT_URL=${artifact}" \
                bash "${SKYLINE_SOURCE_DIR}/install.sh" --prebuilt --no-enable \
                || { rc=$?; skyline_fail "Skyline Speeder 预编译包安装失败：${SKYLINE_SOURCE_DIR}/install.sh --prebuilt（TCP 调优配置已保留）" "${rc}"; }
        fi
        rc=0
        installed_version=$(skyline-speederd --version 2>"${version_error_file}") || rc=$?
        if [[ "${installed_version}" != "skyline-speederd ${SKYLINE_VERSION#v}" ]]; then
            version_stderr_note=""
            [[ ! -s "${version_error_file}" ]] || version_stderr_note="，stderr：$(<"${version_error_file}")"
            stop_skyline_speeder
            sysctl -p "${TCP_SYSCTL_CONF}" >/dev/null || die "回退 TCP 调优配置失败"
            skyline_fail "Skyline Speeder 版本验收失败（期望 skyline-speederd ${SKYLINE_VERSION#v}，实际 ${installed_version:-未能读取}${version_stderr_note}）" "${rc}"
        fi
        printf '%s\n' "${SKYLINE_COMMIT}" >"${SKYLINE_SOURCE_DIR}/.easy-all-installed" \
            || die "保存 Skyline Speeder 安装版本失败"
    fi
    rc=0
    systemctl enable --now skyline-speederd.service || rc=$?
    if ((rc != 0)); then
        skyline_runtime_diagnostics
        skyline_fail "启动 Skyline Speeder 守护进程失败：skyline-speederd.service" "${rc}"
    fi
    rc=0
    systemctl enable --now skyline-speeder-enable.service || rc=$?
    if ((rc != 0)) || ! skyline_speeder_active; then
        # 停服务前先取现场：unit 状态与 journal 在 stop 之后就看不到了。
        skyline_runtime_diagnostics
        stop_skyline_speeder
        sysctl -p "${TCP_SYSCTL_CONF}" >/dev/null || die "回退 TCP 调优配置失败"
        skyline_fail "Skyline Speeder 启用后验收失败（$(skyline_acceptance_summary)），已停用服务并保留回退配置" "${rc}"
    fi
    remove_skyline_boot_setup 0
    rm -f -- "${KERNEL_REBOOT_MARKER}"
    success "Skyline Speeder 已启用（fq + skyline_cc）"
}

skyline_speeder_active() {
    systemctl is-active --quiet skyline-speederd.service \
        && systemctl is-active --quiet skyline-speeder-enable.service \
        && [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "skyline_cc" ]] \
        && [[ "$(sysctl -n net.core.default_qdisc)" == "fq" ]] \
        && physical_fq_active
}

show_tcp_acceleration_status() {
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local current_cc
    current_cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) || current_cc="unknown"
    if skyline_speeder_active 2>/dev/null; then
        printf 'Skyline Speeder: active（fq + skyline_cc）\n'
    elif [[ -f "${KERNEL_REBOOT_MARKER}" ]]; then
        if [[ -f "${systemd_dir}/easy_all-skyline-setup.service" ]] \
            && systemctl is-failed --quiet easy_all-skyline-setup.service; then
            printf 'Skyline Speeder: degraded（开机自动安装或启用失败，当前拥塞控制 %s；查看 journalctl -u easy_all-skyline-setup.service -b；重试：sudo easy_all apply）\n' "${current_cc}"
        elif [[ -f "${systemd_dir}/easy_all-skyline-setup.service" ]] && running_kernel_supported; then
            printf 'Skyline Speeder: pending-activation（开机任务将自动安装并启用；进度查看 journalctl -u easy_all-skyline-setup.service -b -f）\n'
        elif running_kernel_supported; then
            printf 'Skyline Speeder: degraded（兼容内核已运行，但无开机安装任务，当前拥塞控制 %s；重试：sudo easy_all apply）\n' "${current_cc}"
        elif [[ -f "${systemd_dir}/easy_all-skyline-setup.service" ]]; then
            printf 'Skyline Speeder: pending-reboot（当前内核 %s；其余安装完成后重启一次，将自动安装并启用）\n' "$(uname -r)"
        else
            printf 'Skyline Speeder: pending-reboot（当前内核 %s；请执行 sudo easy_all apply 准备开机自动启用任务）\n' "$(uname -r)"
        fi
    else
        printf 'Skyline Speeder: degraded（服务、拥塞控制或 FQ 未生效，当前拥塞控制 %s；重试：sudo easy_all apply）\n' "${current_cc}"
    fi
}

platform_codename() {
    local os_release="${EASY_ALL_OS_RELEASE_FILE:-/etc/os-release}"
    local codename
    # shellcheck source=/dev/null
    source "${os_release}"
    codename=${VERSION_CODENAME:-}
    if ! platform_is_supported_codename "${codename}"; then
        die "当前发行版代号 ${codename:-未知} 暂无经过验证的 Zabbly 内核仓库（仅支持 Debian bookworm/trixie 与 Ubuntu jammy/noble/resolute）"
    fi
    printf '%s\n' "${codename}"
}

secure_boot_enabled() {
    local variable value disabled=0
    [[ -d "${SECUREBOOT_EFI_DIR}" ]] || return 1
    [[ -d "${SECUREBOOT_EFIVARS_DIR}" ]] || return 0
    for variable in "${SECUREBOOT_EFIVARS_DIR}"/SecureBoot-*; do
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

zabbly_key_fingerprint() {
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

zabbly_repository_content() {
    local codename
    codename=$(platform_codename)
    cat <<EOF
Types: deb
URIs: ${ZABBLY_REPOSITORY_URL}
Suites: ${codename}
Components: main
Signed-By: ${ZABBLY_KEYRING}
EOF
}

zabbly_repository_ready() {
    local expected
    [[ -s "${ZABBLY_KEYRING}" && -s "${ZABBLY_SOURCE}" ]] || return 1
    [[ "$(zabbly_key_fingerprint "${ZABBLY_KEYRING}")" \
        == "${ZABBLY_KEY_FINGERPRINT}" ]] || return 1
    expected=$(zabbly_repository_content)
    [[ "$(<"${ZABBLY_SOURCE}")" == "${expected}" ]]
}

ensure_zabbly_repository() {
    local key source fingerprint
    zabbly_repository_ready && return 0
    if ! command -v gpg >/dev/null 2>&1; then
        info "安装 Zabbly APT 公钥校验依赖：gnupg"
        apt-get -o DPkg::Lock::Timeout=300 update || die "刷新 APT 索引失败"
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends gnupg \
            || die "安装 Zabbly 内核所需的 gnupg 失败"
    fi
    command -v gpg >/dev/null 2>&1 || die "安装 Zabbly 内核需要 gnupg"
    key="${RUNTIME_TMP}/zabbly.asc"
    source="${RUNTIME_TMP}/zabbly-kernel.sources"
    curl -fL --proto '=https' --tlsv1.2 --retry 3 \
        --connect-timeout 10 --max-time 60 \
        "${ZABBLY_KEY_URL}" -o "${key}" \
        || die "下载 Zabbly 官方 APT 公钥失败"
    fingerprint=$(zabbly_key_fingerprint "${key}")
    [[ "${fingerprint}" == "${ZABBLY_KEY_FINGERPRINT}" ]] \
        || die "Zabbly APT 公钥指纹不匹配：${fingerprint:-缺失}"
    zabbly_repository_content >"${source}"
    install -d -m 0755 "$(dirname -- "${ZABBLY_KEYRING}")" \
        "$(dirname -- "${ZABBLY_SOURCE}")"
    install -m 0644 "${key}" "${ZABBLY_KEYRING}"
    install -m 0644 "${source}" "${ZABBLY_SOURCE}"
    zabbly_repository_ready || die "Zabbly APT 仓库写入后验收失败"
}

zabbly_kernel_installed() {
    local package=${1:-${ZABBLY_KERNEL_PACKAGE}}
    dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null \
        | grep -qx 'ii '
}

zabbly_kernel_release_on_disk() {
    local image release
    for image in "${KERNEL_BOOT_DIR}"/vmlinuz-*zabbly*; do
        [[ -s "${image}" ]] || continue
        release=${image##*/vmlinuz-}
        [[ -s "${KERNEL_BOOT_DIR}/initrd.img-${release}" \
            || -s "${KERNEL_BOOT_DIR}/initramfs-${release}.img" ]] || continue
        printf '%s\n' "${release}"
    done | sort -V | tail -n 1
}

zabbly_kernel_image_installed() {
    [[ -n "$(zabbly_kernel_release_on_disk)" ]]
}

running_kernel_supported() {
    local release version
    release=$(uname -r)
    version=${release%%-*}
    dpkg --compare-versions "${version}" ge "${SKYLINE_MINIMUM_KERNEL_VERSION}"
}

ensure_zabbly_kernel() {
    local minimum_version=${1:-${SKYLINE_MINIMUM_KERNEL_VERSION}} release
    if running_kernel_supported; then
        return 0
    fi
    if secure_boot_enabled; then
        die "检测到 UEFI Secure Boot；拒绝安装或切换到无法确认可启动的内核"
    fi
    ensure_zabbly_repository
    release=$(zabbly_kernel_release_on_disk)
    if ! zabbly_kernel_installed "${ZABBLY_KERNEL_PACKAGE}" \
        || [[ -z "${release}" ]] \
        || ! dpkg --compare-versions "${release%%-*}" ge "${minimum_version}"; then
        info "安装或升级 Zabbly 6.12+ LTS 内核：${ZABBLY_KERNEL_PACKAGE}"
        apt-get -o DPkg::Lock::Timeout=300 update || die "刷新 Zabbly APT 索引失败"
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${ZABBLY_KERNEL_PACKAGE}" \
            || die "安装 Zabbly 6.12+ LTS 内核失败"
    fi
    zabbly_kernel_installed "${ZABBLY_KERNEL_PACKAGE}" \
        || die "Zabbly 内核元包安装后验收失败：${ZABBLY_KERNEL_PACKAGE}"
    zabbly_kernel_image_installed \
        || die "最新 Zabbly 内核缺少可用的 vmlinuz 或 initrd"
    release=$(zabbly_kernel_release_on_disk)
    dpkg --compare-versions "${release%%-*}" ge "${minimum_version}" \
        || die "已安装的 Zabbly 内核 ${release} 低于所需版本 ${minimum_version}；请检查 APT 仓库或软件包锁定状态"
    if command -v update-grub >/dev/null 2>&1; then
        update-grub >/dev/null || die "更新 GRUB 启动项失败"
    fi
}

configure_tcp_parameters() {
    ensure_vps_ip_family
    cat >"${RUNTIME_TMP}/tcp-tuning.conf" <<'EOF'
# TCP tuning only; Skyline Speeder attaches skyline_cc at boot.
net.core.default_qdisc = fq

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

# Fast dead connection failure (Skyline recommended tuning)
net.ipv4.tcp_retries2 = 8

# High-concurrency socket recycling & queue optimization
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 65535

# Defaults for applications that enable SO_KEEPALIVE; the transport-level keepalive
# of the CDN WebSocket hop must still satisfy the CDN HTTP/2 idle timeouts.
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5

# Outbound TCP/UDP source ports stay below the registered ingress ports (443/8443).
net.ipv4.ip_local_port_range = 13000 60999
EOF
    if [[ "${PROTOCOL:-}" == "anytls" ]]; then
        cat >>"${RUNTIME_TMP}/tcp-tuning.conf" <<'EOF'

# Direct-link routing changes should not reuse stale destination metrics.
net.ipv4.tcp_no_metrics_save = 1
EOF
    fi
    install -m 0644 "${RUNTIME_TMP}/tcp-tuning.conf" "${TCP_SYSCTL_CONF}"
    sysctl -p "${TCP_SYSCTL_CONF}" >/dev/null || die "应用 TCP sysctl 配置失败"
    [[ -f "${TCP_SYSCTL_CONF}" ]] || die "TCP 开机配置写入失败"
    apply_physical_fq_qdisc
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
    local iface current entry target filters attempt handle failed=0
    local -a args
    command -v tc >/dev/null && command -v jq >/dev/null || die "FQ 配置需要 tc 和 jq"
    iface=$(default_route_iface) || die "无法读取 IPv4 默认出口"
    [[ "${iface}" =~ ^[a-zA-Z0-9_.:-]+$ && "${iface}" != .* ]] || die "无法确定安全的默认出口接口名"
    current=$(tc -j qdisc show dev "${iface}") || die "读取 ${iface} qdisc 失败"
    install -d -m 0700 "${BACKUP_DIR}/qdisc"
    # 本次应用前的队列快照：仅用于本次替换失败时立即回滚。
    attempt="${BACKUP_DIR}/qdisc/${iface}.json.apply"
    printf '%s\n' "${current}" >"${attempt}"
    chmod 0600 "${attempt}"
    validate_qdisc_snapshot "${attempt}" || die "${iface} 存在不支持自动恢复的 qdisc；未修改队列"
    filters=$(tc -j filter show dev "${iface}" root) || die "读取 ${iface} 根过滤器失败"
    [[ "$(jq 'length' <<<"${filters}")" == 0 ]] || die "${iface} 存在根过滤器；拒绝替换队列"
    while IFS= read -r target; do
        [[ "${target}" != "0:" ]] || continue
        filters=$(tc -j filter show dev "${iface}" parent "${target}") || die "读取 ${iface} 子队列过滤器失败"
        [[ "$(jq 'length' <<<"${filters}")" == 0 ]] || die "${iface} 存在子队列过滤器；拒绝替换队列"
    done < <(jq -r '.[] | select(.kind == "fq_codel" or .kind == "pfifo_fast") | .handle' <<<"${current}")
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

apply_physical_fq_qdisc() {
    configure_physical_fq
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    local fq_service_file="${systemd_dir}/easy_all-fq.service"
    local helper_dir="${EASY_ALL_TCP_DIR_OVERRIDE:-${EASY_ALL_TCP_DIR:-/usr/local/lib/easy_all-tcp}}"
    local helper="${helper_dir}/apply-fq.sh"
    install -d -m 0755 "${helper_dir}"
    {
        printf '#!/usr/bin/env bash\nset -Eeuo pipefail\n'
        # 开机由 systemd 拉起：PATH 与备份目录都不能依赖当时的交互环境。
        printf '%s\n' 'export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"'
        # helper 是独立服务，快照必须留在自己的目录下：写业务 STATE_DIR/backups
        # 会在卸载后重建 /etc/easy_all，并被安装守卫误判为未完成安装。
        printf 'BACKUP_DIR=%q\n' "${helper_dir}/backups"
        printf 'die() { printf "%%s\\n" "$*" >&2; exit 1; }\n'
        declare -f default_route_iface physical_fq_active validate_qdisc_snapshot \
            normalize_mq_handle map_qdisc_parents qdisc_restore_args restore_qdisc_snapshot configure_physical_fq
        printf 'configure_physical_fq\n'
    } >"${helper}"
    chmod 0755 "${helper}"
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

prompt_kernel_reboot() {
    local choice
    [[ -f "${KERNEL_REBOOT_MARKER}" ]] || return 0
    if running_kernel_supported; then
        return 0
    fi
    printf '\n'
    printf '%s\n' "========================================================================"
    printf '%s\n' "【重要提示：请重启服务器以加载 Skyline Speeder 所需的兼容内核】"
    printf '%s\n' "其余安装已完成，只需重启一次；开机将自动安装并启用 Skyline，无需再次执行命令。"
    printf '%s\n' "Zabbly 6.12+ LTS 内核已安装完成，当前运行仍为 $(uname -r)。"
    printf '%s\n' "系统必须重启后才会真正载入新内核！"
    printf '%s\n' "请保存好上方的节点与订阅链接后，立即重启服务器。"
    printf '%s\n' "========================================================================"
    if [[ "${EASY_ALL_NO_REBOOT:-0}" == "1" ]]; then
        return 0
    fi
    if [[ "${PARAMS_LOADED:-0}" == "1" ]]; then
        warn "安装已完成；请按上方提示重启服务器以载入新内核：sudo reboot"
        return 0
    fi
    if [[ -t 0 ]]; then
        # 走共享读取原语（readline）：裸 read 在 raw 会话里等不到 \n 会挂住。
        read_prompt '是否现在立即重启服务器以载入新内核？[y/N]: ' choice || choice="n"
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
