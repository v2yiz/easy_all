#!/usr/bin/env bash

# Shared host preflight and SSH boot-safety checks.

readonly EASY_ALL_ADDITIONAL_SSH_PORT="65533"
EASY_ALL_SSH_PORT_CONFIG="${EASY_ALL_SSH_PORT_CONFIG:-/etc/ssh/sshd_config.d/00-easy-all-ports.conf}"
EASY_ALL_FAIL2BAN_CONFIG="${EASY_ALL_FAIL2BAN_CONFIG:-/etc/fail2ban/jail.d/99-easy-all-sshd.local}"
EASY_ALL_FAIL2BAN_ACTION_CONFIG="${EASY_ALL_FAIL2BAN_ACTION_CONFIG:-/etc/fail2ban/action.d/easy-all-ufw-cidr.conf}"
EASY_ALL_FAIL2BAN_CIDR_HELPER="${EASY_ALL_FAIL2BAN_CIDR_HELPER:-/usr/local/lib/easy_all/fail2ban-ufw-cidr.sh}"
EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR:-/var/lib/easy_all/fail2ban-ufw-cidr}"
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
        NETWORK="${address}"
        STATE_KEY="v6-${address//:/-}"
        return 0
    fi

    IFS=. read -r first second third fourth <<<"${address}"
    [[ -n "${first}" && -n "${second}" && -n "${third}" && -n "${fourth}" ]] || return 1
    for octet in "${first}" "${second}" "${third}" "${fourth}"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#${octet} <= 255)) || return 1
    done
    NETWORK="$((10#${first})).$((10#${second})).$((10#${third})).0/24"
    STATE_KEY="v4-$((10#${first}))-$((10#${second}))-$((10#${third}))"
}

fail2ban_cidr_acquire_lock() {
    local attempt owner
    for attempt in {1..100}; do
        if mkdir "${LOCK_DIR}" 2>/dev/null; then
            printf '%s\n' "$$" >"${LOCK_DIR}/pid"
            return 0
        fi
        if [[ -r "${LOCK_DIR}/pid" ]]; then
            read -r owner <"${LOCK_DIR}/pid" || owner=""
            if [[ "${owner}" =~ ^[0-9]+$ ]] && ! kill -0 "${owner}" 2>/dev/null; then
                rm -f -- "${LOCK_DIR}/pid"
                rmdir "${LOCK_DIR}" 2>/dev/null || true
                continue
            fi
        fi
        sleep 0.1
    done
    printf 'timed out waiting for Fail2ban CIDR ban lock\n' >&2
    return 1
}

fail2ban_cidr_release_lock() {
    rm -f -- "${LOCK_DIR}/pid"
    rmdir "${LOCK_DIR}" 2>/dev/null || true
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
    LOCK_DIR="${state_dir}/.lock"
    COUNT_FILE="${state_dir}/${STATE_KEY}.count"
    fail2ban_cidr_acquire_lock
    trap fail2ban_cidr_release_lock EXIT
    count=$(fail2ban_cidr_read_count)

    case "${action}" in
    ban)
        if ((count == 0)); then
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
            "${UFW_BIN}" --force delete deny from "${NETWORK}" to any >/dev/null
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
    detect_ssh_ports
    append_ssh_port "${EASY_ALL_ADDITIONAL_SSH_PORT}"
    ports_csv=${SSH_PORTS// /,}
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
[DEFAULT]
banaction = easy-all-ufw-cidr
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
            "${jail_backup}" "${action_backup}" "${helper_backup}" \
            "${EASY_ALL_LEGACY_FAIL2BAN_CONFIG}"
        info "Fail2ban 已保护 SSH 端口 ${SSH_PORTS}：IPv4 按 /24 封禁；3 分钟失败 6 次，首次封禁 3 小时并递增至 1 周"
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
        "${jail_backup}" "${action_backup}" "${helper_backup}" \
        "${EASY_ALL_LEGACY_FAIL2BAN_CONFIG}"
    info "Fail2ban 已保护 SSH 端口 ${SSH_PORTS}：IPv4 按 /24 封禁；3 分钟失败 6 次，首次封禁 3 小时并递增至 1 周"
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
