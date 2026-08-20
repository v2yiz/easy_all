#!/usr/bin/env bash

# Shared host preflight and SSH boot-safety checks.

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
