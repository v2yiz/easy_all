#!/usr/bin/env bash

# Shared host preflight and SSH boot-safety checks.

readonly EASY_ALL_ADDITIONAL_SSH_PORT="65533"
EASY_ALL_SSH_PORT_CONFIG="${EASY_ALL_SSH_PORT_CONFIG:-/etc/ssh/sshd_config.d/00-easy-all-ports.conf}"
EASY_ALL_FAIL2BAN_CONFIG="${EASY_ALL_FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/99-easy-all-sshd.local}"
EASY_ALL_LEGACY_FAIL2BAN_CONFIG="${EASY_ALL_LEGACY_FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/99-debian-init-sshd.local}"

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

ssh_effective_port_exists() {
    local sshd_bin=$1 expected_port=$2
    "${sshd_bin}" -T 2>/dev/null | awk -v expected="${expected_port}" '
        $1 == "port" && $2 == expected {found=1}
        $1 == "listenaddress" {
            address=$2
            sub(/^.*\]:/, "", address)
            sub(/^.*:/, "", address)
            if (address == expected) found=1
        }
        END {exit(found ? 0 : 1)}
    '
}

ssh_managed_port_is_listening() {
    local port=$1 output
    output=$(ss -H -ltnp "sport = :${port}" 2>/dev/null || true)
    [[ -n "${output}" ]] || return 1
    grep -Eq 'users:\(\("(sshd|systemd)"' <<<"${output}"
}

ssh_port_is_listening() {
    local port=$1 output
    output=$(ss -H -ltn "sport = :${port}" 2>/dev/null || true)
    [[ -n "${output}" ]]
}

restore_managed_ssh_port_config() {
    local sshd_bin=$1 unit=$2 backup_file=$3 had_config=$4
    if [[ "${had_config}" == "1" ]]; then
        install -m 0644 "${backup_file}" "${EASY_ALL_SSH_PORT_CONFIG}"
    else
        rm -f -- "${EASY_ALL_SSH_PORT_CONFIG}"
    fi
    "${sshd_bin}" -t >/dev/null 2>&1 && systemctl reload "${unit}" >/dev/null 2>&1 || true
}

ensure_additional_ssh_port() {
    local sshd_bin=$1 unit=$2 candidate backup had_config=0 address_family port attempt
    local preserve_port
    local enable_ipv4=1
    local enable_ipv6=0

    [[ "${EASY_ALL_ADDITIONAL_SSH_PORT}" =~ ^[0-9]+$ ]] \
        && ((10#${EASY_ALL_ADDITIONAL_SSH_PORT} >= 1 \
            && 10#${EASY_ALL_ADDITIONAL_SSH_PORT} <= 65535)) \
        || die "新增 SSH 端口无效：${EASY_ALL_ADDITIONAL_SSH_PORT}"

    detect_ssh_ports
    for preserve_port in ${EASY_ALL_SSH_PRESERVE_PORTS:-}; do
        append_ssh_port "${preserve_port}"
    done
    append_ssh_port "${EASY_ALL_ADDITIONAL_SSH_PORT}"
    if ssh_port_is_listening "${EASY_ALL_ADDITIONAL_SSH_PORT}" \
        && ! ssh_managed_port_is_listening "${EASY_ALL_ADDITIONAL_SSH_PORT}"; then
        die "TCP ${EASY_ALL_ADDITIONAL_SSH_PORT} 已被非 SSH 进程占用；拒绝修改 sshd"
    fi

    install -d -m 0755 "$(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}")"
    candidate=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-ssh-ports.XXXXXX")
    backup=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-ssh-ports-backup.XXXXXX")
    if [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]]; then
        install -m 0600 "${EASY_ALL_SSH_PORT_CONFIG}" "${backup}"
        had_config=1
    fi

    address_family=$("${sshd_bin}" -T 2>/dev/null \
        | awk '$1 == "addressfamily" && !found {value=$2; found=1} END {if (found) print value}')
    [[ "${address_family:-any}" != "inet6" ]] || enable_ipv4=0
    if [[ "${address_family:-any}" != "inet" \
        && -r /proc/sys/net/ipv6/conf/all/disable_ipv6 \
        && "$(< /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "0" ]]; then
        enable_ipv6=1
    fi
    [[ "${enable_ipv4}" == "1" || "${enable_ipv6}" == "1" ]] \
        || die "sshd 仅允许 IPv6，但当前系统 IPv6 不可用"

    {
        printf '%s\n' '# Managed by easy_all. Keep every detected SSH port and add 65533.'
        for port in ${SSH_PORTS}; do
            printf 'Port %s\n' "${port}"
        done
        for port in ${SSH_PORTS}; do
            [[ "${enable_ipv4}" == "1" ]] && printf 'ListenAddress 0.0.0.0:%s\n' "${port}"
            [[ "${enable_ipv6}" == "1" ]] && printf 'ListenAddress [::]:%s\n' "${port}"
        done
    } >"${candidate}"

    if [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]] \
        && cmp -s "${candidate}" "${EASY_ALL_SSH_PORT_CONFIG}" \
        && ssh_effective_port_exists "${sshd_bin}" "${EASY_ALL_ADDITIONAL_SSH_PORT}" \
        && ssh_managed_port_is_listening "${EASY_ALL_ADDITIONAL_SSH_PORT}"; then
        rm -f -- "${candidate}" "${backup}"
        info "SSH 已同时监听现有端口与新增端口 ${EASY_ALL_ADDITIONAL_SSH_PORT}"
        return 0
    fi

    install -m 0644 "${candidate}" "${EASY_ALL_SSH_PORT_CONFIG}"
    if ! "${sshd_bin}" -t \
        || ! ssh_effective_port_exists "${sshd_bin}" "${EASY_ALL_ADDITIONAL_SSH_PORT}"; then
        restore_managed_ssh_port_config "${sshd_bin}" "${unit}" "${backup}" "${had_config}"
        rm -f -- "${candidate}" "${backup}"
        die "sshd 未接受新增端口 ${EASY_ALL_ADDITIONAL_SSH_PORT}，已恢复原 SSH 配置"
    fi
    if ! systemctl reload "${unit}" >/dev/null 2>&1; then
        restore_managed_ssh_port_config "${sshd_bin}" "${unit}" "${backup}" "${had_config}"
        rm -f -- "${candidate}" "${backup}"
        die "重载 ${unit} 失败，已恢复原 SSH 配置"
    fi
    for attempt in {1..10}; do
        ssh_managed_port_is_listening "${EASY_ALL_ADDITIONAL_SSH_PORT}" && break
        sleep 0.5
    done
    if ! ssh_managed_port_is_listening "${EASY_ALL_ADDITIONAL_SSH_PORT}"; then
        restore_managed_ssh_port_config "${sshd_bin}" "${unit}" "${backup}" "${had_config}"
        rm -f -- "${candidate}" "${backup}"
        die "sshd 重载后仍未监听 ${EASY_ALL_ADDITIONAL_SSH_PORT}，已恢复原 SSH 配置"
    fi
    rm -f -- "${candidate}" "${backup}"
    info "SSH 已同时监听现有端口与新增端口 ${EASY_ALL_ADDITIONAL_SSH_PORT}"
}

install_fail2ban_dependencies() {
    local package needs_install=0
    for package in fail2ban python3-systemd; do
        dpkg-query -W -f='${db:Status-Abbrev}' "${package}" 2>/dev/null \
            | grep -qx 'ii ' || needs_install=1
    done
    if [[ "${needs_install}" == "1" ]]; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get update
        apt-get install -y --no-install-recommends fail2ban python3-systemd
    fi
    command -v fail2ban-client >/dev/null 2>&1 \
        || die "Fail2ban 安装后仍不可用"
}

restore_managed_fail2ban_config() {
    local backup_file=$1 had_config=$2
    if [[ "${had_config}" == "1" ]]; then
        install -m 0644 "${backup_file}" "${EASY_ALL_FAIL2BAN_CONFIG}"
    else
        rm -f -- "${EASY_ALL_FAIL2BAN_CONFIG}"
    fi
    if fail2ban-client -t >/dev/null 2>&1; then
        systemctl restart fail2ban.service >/dev/null 2>&1 || true
    fi
}

ensure_ssh_fail2ban() {
    local candidate backup ports_csv had_config=0

    install_fail2ban_dependencies
    command -v ufw >/dev/null 2>&1 || die "未找到 UFW；无法启用 Fail2ban SSH 防护"
    detect_ssh_ports
    append_ssh_port "${EASY_ALL_ADDITIONAL_SSH_PORT}"
    ports_csv=${SSH_PORTS// /,}
    [[ -n "${ports_csv}" ]] || die "无法确定 Fail2ban 需要保护的 SSH 端口"

    install -d -m 0755 "$(dirname -- "${EASY_ALL_FAIL2BAN_CONFIG}")"
    candidate=$(mktemp "$(dirname -- "${EASY_ALL_FAIL2BAN_CONFIG}")/.easy-all-fail2ban.XXXXXX")
    backup=$(mktemp "${RUNTIME_TMP:-/tmp}/easy-all-fail2ban-backup.XXXXXX")
    if [[ -f "${EASY_ALL_FAIL2BAN_CONFIG}" ]]; then
        install -m 0600 "${EASY_ALL_FAIL2BAN_CONFIG}" "${backup}"
        had_config=1
    fi
    cat >"${candidate}" <<EOF
[DEFAULT]
banaction = ufw
usedns = no
ignoreip = 127.0.0.1/8 ::1
bantime = 3h
findtime = 3m
maxretry = 6
bantime.increment = true
bantime.maxtime = 1w

[sshd]
enabled = true
backend = systemd
port = ${ports_csv}
EOF
    chmod 0644 "${candidate}"

    if [[ -f "${EASY_ALL_FAIL2BAN_CONFIG}" ]] \
        && cmp -s "${candidate}" "${EASY_ALL_FAIL2BAN_CONFIG}" \
        && fail2ban-client -t >/dev/null 2>&1 \
        && systemctl is-enabled --quiet fail2ban.service \
        && systemctl is-active --quiet fail2ban.service \
        && fail2ban-client status sshd >/dev/null 2>&1; then
        rm -f -- "${candidate}" "${backup}" "${EASY_ALL_LEGACY_FAIL2BAN_CONFIG}"
        info "Fail2ban 已保护 SSH 端口 ${SSH_PORTS}：3 分钟失败 6 次，首次封禁 3 小时并递增至 1 周"
        return 0
    fi

    mv -f -- "${candidate}" "${EASY_ALL_FAIL2BAN_CONFIG}"
    if ! fail2ban-client -t >/dev/null 2>&1; then
        restore_managed_fail2ban_config "${backup}" "${had_config}"
        rm -f -- "${backup}"
        die "Fail2ban SSH 防护配置校验失败，已恢复原配置"
    fi
    if ! systemctl enable fail2ban.service >/dev/null 2>&1 \
        || ! systemctl restart fail2ban.service \
        || ! systemctl is-active --quiet fail2ban.service \
        || ! fail2ban-client status sshd >/dev/null 2>&1; then
        restore_managed_fail2ban_config "${backup}" "${had_config}"
        rm -f -- "${backup}"
        die "Fail2ban SSH 防护启动失败，已恢复原配置"
    fi
    rm -f -- "${backup}" "${EASY_ALL_LEGACY_FAIL2BAN_CONFIG}"
    info "Fail2ban 已保护 SSH 端口 ${SSH_PORTS}：3 分钟失败 6 次，首次封禁 3 小时并递增至 1 周"
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
        ensure_additional_ssh_port "${sshd_bin}" "${unit}"
        info "SSH 已设置开机启动并处于运行状态：${unit}"
        return 0
    done
    die "未找到 ssh.service 或 sshd.service；拒绝配置定时重启"
}
