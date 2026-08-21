#!/usr/bin/env bash

# Shared UFW filter-rule management for all easy_all profiles.
#
# The calling profile provides UFW_RULE_COMMENT plus info/warn/die. Profile
# modules remain responsible for their own snapshots, NAT rules and IPv6 policy.

managed_ufw_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | sed -n "/${UFW_RULE_COMMENT}/s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)\\].*/\\1/p" \
        | sort -rn
}

remove_managed_ufw_rules() {
    local rule_number
    command -v ufw >/dev/null 2>&1 || return 0
    while read -r rule_number; do
        [[ -n "${rule_number}" ]] || continue
        ufw --force delete "${rule_number}" >/dev/null \
            || warn "删除 UFW 规则 ${rule_number} 失败"
    done < <(managed_ufw_rule_numbers)
}

normalize_ufw_tcp_ports() {
    local raw=$1 normalized="" port
    for port in ${raw//,/ }; do
        [[ "${port}" =~ ^[0-9]+$ ]] || return 1
        ((10#${port} >= 1 && 10#${port} <= 65535)) || return 1
        case " ${normalized} " in
        *" ${port} "*) ;;
        *) [[ -z "${normalized}" ]] || normalized+=" "; normalized+="${port}" ;;
        esac
    done
    [[ -n "${normalized}" ]] || return 1
    printf '%s\n' "${normalized}"
}

stale_managed_ufw_rule_numbers() {
    local desired_ports=${1//,/ }
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | awk -v comment="${UFW_RULE_COMMENT}" -v desired=" ${desired_ports} " '
            index($0, comment) == 0 {next}
            {
                line=$0
                sub(/^[[:space:]]*\[[[:space:]]*/, "", line)
                number=line
                sub(/[[:space:]]*\].*$/, "", number)
                sub(/^[^]]*\][[:space:]]*/, "", line)
                endpoint=line
                sub(/[[:space:]].*$/, "", endpoint)
                port=endpoint
                sub(/\/tcp$/, "", port)
                if (number !~ /^[0-9]+$/ || endpoint != port "/tcp") next
                if (line !~ /^[0-9]+\/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN([[:space:]]|$)/) next
                if (index(desired, " " port " ") == 0) print number
            }
        ' | sort -rn
}

ufw_tcp_port_is_allowed() {
    local port=$1
    LC_ALL=C ufw status numbered 2>/dev/null \
        | awk -v expected="${port}/tcp" '
            {
                line=$0
                sub(/^[[:space:]]*\[[[:space:]]*[^]]*\][[:space:]]*/, "", line)
                endpoint=line
                sub(/[[:space:]].*$/, "", endpoint)
                if (endpoint == expected &&
                    line ~ /^[0-9]+\/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN([[:space:]]|$)/) found=1
            }
            END {exit(found ? 0 : 1)}
        '
}

verify_ufw_tcp_ports() {
    local desired_ports=$1 port
    for port in ${desired_ports}; do
        ufw_tcp_port_is_allowed "${port}" \
            || die "UFW 未有效放行 TCP ${port}；停止应用以避免服务或 SSH 失联"
    done
}

apply_managed_ufw_tcp_ports() {
    local desired_ports port rule_number
    desired_ports=$(normalize_ufw_tcp_ports "$1") \
        || die "受管 UFW TCP 端口列表无效：$1"

    # Add and verify the full desired set first. UFW can report success while
    # skipping a duplicate, so deleting numbered rules first may remove the
    # only SSH allow rule and lock out the administrator.
    for port in ${desired_ports}; do
        ufw allow "${port}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加受管 UFW 规则失败：TCP ${port}"
    done
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    verify_ufw_tcp_ports "${desired_ports}"

    while read -r rule_number; do
        [[ -n "${rule_number}" ]] || continue
        ufw --force delete "${rule_number}" >/dev/null \
            || die "删除过期 UFW 规则失败：${rule_number}"
    done < <(stale_managed_ufw_rule_numbers "${desired_ports}")

    ufw reload >/dev/null || die "重载 UFW 失败"
    verify_ufw_tcp_ports "${desired_ports}"
}
