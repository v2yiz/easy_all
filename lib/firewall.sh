#!/usr/bin/env bash

# Shared UFW filter-rule management for all easy_all profiles.
#
# The calling profile provides UFW_RULE_COMMENT, UFW_DEFAULT_CONFIG and
# info/warn/die. Profile modules remain responsible for snapshots and NAT rules.

set_ufw_ipv6() {
    local enabled=$1 candidate
    [[ "${enabled}" == "yes" || "${enabled}" == "no" ]] \
        || die "UFW IPv6 开关无效：${enabled}"
    [[ -f "${UFW_DEFAULT_CONFIG}" ]] \
        || die "缺少 UFW 默认配置：${UFW_DEFAULT_CONFIG}"
    candidate=$(mktemp "$(dirname -- "${UFW_DEFAULT_CONFIG}")/.easy-all-ufw-default.XXXXXX") \
        || die "无法创建 UFW 默认配置候选文件"
    cleanup_files+=("${candidate}")
    awk -v enabled="${enabled}" '
        BEGIN {updated=0}
        /^IPV6=/ {print "IPV6=" enabled; updated=1; next}
        {print}
        END {if (!updated) print "IPV6=" enabled}
    ' "${UFW_DEFAULT_CONFIG}" >"${candidate}" \
        || die "生成 UFW 默认配置失败"
    [[ -s "${candidate}" ]] || die "生成的 UFW 默认配置为空"
    chmod 0644 "${candidate}"
    mv -f -- "${candidate}" "${UFW_DEFAULT_CONFIG}" \
        || die "替换 UFW 默认配置失败"
}

configure_ufw_ip_family() {
    set_ufw_ipv6 no
}

disable_ufw_ipv6() {
    set_ufw_ipv6 no
}

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
    local port=$1 source=${2:-}
    LC_ALL=C ufw status numbered 2>/dev/null \
        | awk -v expected="${port}/tcp" -v source="${source}" '
            {
                line=$0
                sub(/^[[:space:]]*\[[[:space:]]*[^]]*\][[:space:]]*/, "", line)
                endpoint=line
                sub(/[[:space:]].*$/, "", endpoint)
                if (endpoint == expected &&
                    line ~ /^[0-9]+\/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN([[:space:]]|$)/) {
                    sub(/^[0-9]+\/tcp([[:space:]]+\(v6\))?[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]*/, "", line)
                    sub(/[[:space:]].*$/, "", line)
                    if (source == "" || line == source) found=1
                }
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

ufw_tcp_port_has_unmanaged_anywhere_allow() {
    local port=$1
    command -v ufw >/dev/null 2>&1 || return 1
    LC_ALL=C ufw status numbered 2>/dev/null \
        | awk -v port="${port}" -v expected="${port}/tcp" -v managed="${UFW_RULE_COMMENT}" '
            index($0, managed) != 0 {next}
            {
                line=$0
                sub(/^[[:space:]]*\[[[:space:]]*[^]]*\][[:space:]]*/, "", line)
                endpoint=line
                sub(/[[:space:]].*$/, "", endpoint)
                if ((endpoint == expected || endpoint == port) &&
                    line ~ ("^" port "(/tcp)?([[:space:]]+\\(v6\\))?[[:space:]]+ALLOW[[:space:]]+IN[[:space:]]+Anywhere([[:space:]]|$)")) {
                    found=1
                }
            }
            END {exit(found ? 0 : 1)}
        '
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

# UFW is ordered. An earlier deny can make an existing allow ineffective.
ufw_ssh_port_is_allowed() {
    LC_ALL=C ufw status numbered 2>/dev/null | awk -v port="${EASY_ALL_ADDITIONAL_SSH_PORT}" '
        /\(v6\)/ {next}
        {
            line=$0
            sub(/^[[:space:]]*\[[[:space:]]*[^]]*\][[:space:]]*/, "", line)
            split(line, fields, /[[:space:]]+/)
            endpoint=fields[1]
            sub(/\/tcp$/, "", endpoint)
            relevant=(endpoint == port || endpoint == "Anywhere")
            count=split(endpoint, ranges, ",")
            for (i=1; i<=count; i++) {
                if (ranges[i] == port) relevant=1
                if (split(ranges[i], bounds, ":") == 2 && port >= bounds[1] && port <= bounds[2]) relevant=1
            }
            if (!relevant) next
            action=2
            if (fields[2] == "on") action=4
            if (fields[action+1] != "IN") next
            if (fields[action] == "DENY" || fields[action] == "REJECT") exit
            # An interface-only allow cannot establish global SSH reachability.
            if (action == 2 && fields[action] == "ALLOW" && fields[action+2] == "Anywhere") {allowed=1; exit}
        }
        END {exit !allowed}
    '
}

ufw_ssh22_deny_is_first() {
    LC_ALL=C ufw status numbered 2>/dev/null | awk -v comment="${UFW_RULE_COMMENT}" '
        /^[[:space:]]*\[/ {
            marker=$0
            sub(/^.*#[[:space:]]*/, "", marker)
            if ($0 ~ /^[[:space:]]*\[[[:space:]]*1\][[:space:]]+22\/tcp[[:space:]]+DENY[[:space:]]+IN[[:space:]]+Anywhere[[:space:]]/ &&
                marker == comment) found=1
            exit
        }
        END {exit !found}
    '
}

managed_ssh22_ufw_rule_numbers() {
    local status
    command -v ufw >/dev/null 2>&1 || return 0
    status=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 1
    awk -v comment="${UFW_RULE_COMMENT}" '
        {
            marker=$0; sub(/^.*#[[:space:]]*/, "", marker)
            if (marker != comment) next
            number=$0
            sub(/^[[:space:]]*\[[[:space:]]*/, "", number); sub(/\].*$/, "", number)
            line=$0; sub(/^[[:space:]]*\[[^]]*\][[:space:]]*/, "", line)
            if (number ~ /^[0-9]+$/ && line ~ /^22\/tcp([[:space:]]+\(v6\))?[[:space:]]+DENY[[:space:]]+IN[[:space:]]+Anywhere([[:space:]]|$)/) print number
        }
    ' <<<"${status}" | sort -rn
}

remove_managed_ssh22_ufw_deny() {
    local numbers number remaining
    numbers=$(managed_ssh22_ufw_rule_numbers) || return 1
    [[ -n "${numbers}" ]] || return 0
    while read -r number; do
        ufw --force delete "${number}" >/dev/null || return 1
    done <<<"${numbers}"
    ufw reload >/dev/null || return 1
    remaining=$(managed_ssh22_ufw_rule_numbers) || return 1
    [[ -z "${remaining}" ]]
}

apply_ssh_ufw_policy() {
    local desired_ports port
    desired_ports=$(normalize_ufw_tcp_ports "$1") || die "SSH UFW 端口列表无效"
    for port in ${desired_ports}; do
        ((10#${port} != 22)) || die "TCP 22 是禁用的 SSH 端口；不能加入额外放行列表"
    done
    case " ${desired_ports} " in
    *" ${EASY_ALL_ADDITIONAL_SSH_PORT} "*) ;;
    *) die "SSH UFW 策略必须放行 ${EASY_ALL_ADDITIONAL_SSH_PORT}" ;;
    esac
    apply_managed_ufw_tcp_ports "${desired_ports}"
    ufw_ssh_port_is_allowed || die "UFW 未有效放行 SSH 65533；拒绝关闭 22"
    if ! ufw_ssh22_deny_is_first; then
        # Delete only this tool's misplaced deny after the replacement SSH allow
        # has been verified. UFW otherwise skips an identical insert as duplicate.
        remove_managed_ssh22_ufw_deny || die "删除过期 SSH 22 deny 失败"
        ufw insert 1 deny 22/tcp comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加优先 SSH 22 deny 失败"
        ufw reload >/dev/null || die "重载 UFW 失败"
    fi
    ufw_ssh_port_is_allowed || die "UFW SSH 65533 放行验证失败"
    ufw_ssh22_deny_is_first || die "UFW TCP 22 优先拒绝规则未生效"
}
