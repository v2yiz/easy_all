#!/usr/bin/env bash

# Shared UFW filter-rule management for all easy_all profiles.
#
# The calling profile provides UFW_RULE_COMMENT, UFW_DEFAULT_CONFIG and
# info/warn/die. Profile modules remain responsible for snapshots and NAT rules.

: "${UFW_DEFAULT_CONFIG:=/etc/default/ufw}"
: "${UFW_RULE_COMMENT:=easy_all-managed}"

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
    local desired_ports=${1//,/ } status
    command -v ufw >/dev/null 2>&1 || return 0
    status=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 1
    awk -v comment="${UFW_RULE_COMMENT}" -v desired=" ${desired_ports} " '
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
        ' <<<"${status}" | sort -rn
}

ufw_tcp_port_is_allowed() {
    local port=$1 source=${2:-} status line endpoint action direction actual_source extra
    status=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ "${line}" == *'(v6)'* ]] && continue
        [[ "${line}" =~ ^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*(.*)$ ]] || continue
        line=${BASH_REMATCH[1]}
        read -r endpoint action direction actual_source extra <<<"${line%%' # '*}"
        [[ "${action}" == "ALLOW" && "${direction}" == "IN" && -z "${extra}" ]] || continue
        [[ -z "${source}" || "${actual_source}" == "${source}" ]] || continue
        ufw_endpoint_matches_tcp_port "${endpoint}" "${port}" && return 0
    done <<<"${status}"
    return 1
}

verify_ufw_tcp_ports() {
    local desired_ports=$1 port
    for port in ${desired_ports}; do
        ufw_tcp_port_is_allowed "${port}" \
            || die "UFW 未有效放行 TCP ${port}；停止应用以避免服务或 SSH 失联"
    done
}

ufw_tcp_port_has_unmanaged_anywhere_allow() {
    local port=$1 status added line endpoint action direction source extra comment
    command -v ufw >/dev/null 2>&1 || die "未找到 ufw 命令"
    status=$(LC_ALL=C ufw status numbered 2>/dev/null) \
        || die "读取 UFW 状态失败"
    if [[ "${status}" == 'Status: inactive' ]]; then
        added=$(LC_ALL=C ufw show added 2>/dev/null) \
            || die "读取 UFW 已保存规则失败"
        while IFS= read -r line; do
            [[ "${line}" =~ ^ufw[[:space:]]+allow[[:space:]]+([0-9]+)(/tcp)?([[:space:]].*)?$ ]] \
                || continue
            [[ "${BASH_REMATCH[1]}" == "${port}" ]] || continue
            extra=${BASH_REMATCH[3]:-}
            comment=""
            if [[ -n "${extra}" ]]; then
                [[ "${extra}" =~ ^[[:space:]]+comment[[:space:]]+\'([^\']*)\'[[:space:]]*$ ]] \
                    || continue
                comment=${BASH_REMATCH[1]}
            fi
            [[ "${comment}" == "${UFW_RULE_COMMENT}" ]] || return 0
        done <<<"${added}"
        return 1
    fi

    while IFS= read -r line; do
        [[ "${line}" == *'(v6)'* ]] && continue
        [[ "${line}" =~ ^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*(.*)$ ]] || continue
        line=${BASH_REMATCH[1]}
        read -r endpoint action direction source extra <<<"${line%%' # '*}"
        [[ "${action}" == "ALLOW" ]] || continue
        ufw_endpoint_matches_tcp_port "${endpoint}" "${port}" || continue
        [[ "${direction}" == "IN" && "${source}" == "Anywhere" && -z "${extra}" ]] || continue
        comment=""
        [[ "${line}" != *' # '* ]] || comment=${line#*' # '}
        [[ "${comment}" == "${UFW_RULE_COMMENT}" ]] || return 0
    done <<<"${status}"
    return 1
}

ufw_endpoint_matches_tcp_port() {
    local endpoint=$1 port=$2 base=${1%/*} protocol="" token lower upper
    [[ "${endpoint}" == */* ]] && protocol=${endpoint##*/}
    [[ -z "${protocol}" || "${protocol}" == "tcp" ]] || return 1
    [[ "${base}" != "Anywhere" && "${base}" != "Any" ]] || return 0
    for token in ${base//,/ }; do
        if [[ "${token}" =~ ^([0-9]+):([0-9]+)$ ]]; then
            lower=${BASH_REMATCH[1]}
            upper=${BASH_REMATCH[2]}
            ((10#${port} >= 10#${lower} && 10#${port} <= 10#${upper})) && return 0
        elif [[ "${token}" =~ ^[0-9]+$ ]] && ((10#${port} == 10#${token})); then
            return 0
        fi
    done
    return 1
}

ufw_ssh_port_has_unmanaged_block() {
    local port=$1 status added line endpoint action direction comment source
    local -a fields
    local index protocol source_scoped
    command -v ufw >/dev/null 2>&1 || die "读取 UFW SSH 阻断规则失败"
    status=$(LC_ALL=C ufw status numbered 2>/dev/null) \
        || die "读取 UFW SSH 阻断规则失败"
    if [[ "${status}" != 'Status: inactive' ]]; then
        while IFS= read -r line; do
            [[ "${line}" == *'(v6)'* ]] && continue
            [[ "${line}" =~ ^[[:space:]]*\[[[:space:]]*[0-9]+\][[:space:]]*(.*)$ ]] || continue
            line=${BASH_REMATCH[1]}
            comment=""
            if [[ "${line}" == *' # '* ]]; then
                comment=${line#*' # '}
                line=${line%%' # '*}
            fi
            read -r -a fields <<<"${line}"
            endpoint=${fields[0]:-}
            action=${fields[1]:-}
            direction=${fields[2]:-}
            source=${fields[3]:-}
            if [[ "${action}" == "on" ]]; then
                action=${fields[3]:-}
                direction=${fields[4]:-}
                source=${fields[5]:-}
            fi
            [[ "${direction}" == "IN" ]] || continue
            ufw_endpoint_matches_tcp_port "${endpoint}" "${port}" || continue
            case "${action}" in
            DENY|REJECT)
                # 按来源封禁（如 Fail2ban 封单 IP）不阻断其他客户端的 SSH。
                [[ "${source}" == "Anywhere" || "${source}" == "Any" ]] || continue
                if [[ "${port}" == "22" && "${endpoint}" == "22/tcp" \
                    && "${comment}" == "${UFW_RULE_COMMENT}" ]]; then
                    continue
                fi
                return 0
                ;;
            esac
        done <<<"${status}"
        return 1
    fi

    added=$(LC_ALL=C ufw show added 2>/dev/null) \
        || die "读取 UFW SSH 阻断规则失败"
    while IFS= read -r line; do
        [[ "${line}" == ufw[[:space:]]* ]] || continue
        comment=""
        if [[ "${line}" =~ ^(.*)[[:space:]]+comment[[:space:]]+\'([^\']*)\'[[:space:]]*$ ]]; then
            line=${BASH_REMATCH[1]}
            comment=${BASH_REMATCH[2]}
        fi
        read -r -a fields <<<"${line}"
        action=${fields[1]:-}
        [[ "${action}" == "allow" || "${action}" == "deny" || "${action}" == "reject" ]] || continue
        endpoint="Anywhere"
        protocol=""
        source_scoped=0
        index=2
        while ((index < ${#fields[@]})); do
            case "${fields[index]}" in
            in|IN) ;;
            out|OUT) index=${#fields[@]}; continue ;;
            proto|PROTO) protocol=${fields[index+1]:-}; index=$((index + 2)); continue ;;
            from|FROM)
                # from 后不是 any/Anywhere 时是按来源限定的规则，不会阻断全部客户端。
                case "${fields[index+1]:-}" in
                any|ANY|Any|anywhere|Anywhere) ;;
                *) source_scoped=1 ;;
                esac
                index=$((index + 2)); continue
                ;;
            to|TO) index=$((index + 2)); continue ;;
            [0-9]*|[0-9]*:[0-9]*|[0-9]*,*|Any|Anywhere) endpoint=${fields[index]} ;;
            esac
            index=$((index + 1))
        done
        [[ "${source_scoped}" == "0" ]] || continue
        [[ -z "${protocol}" || "${protocol}" == "tcp" ]] || continue
        ufw_endpoint_matches_tcp_port "${endpoint}" "${port}" || continue
        case "${action}" in
        deny|reject)
            if [[ "${port}" == "22" && "${endpoint}" == "22/tcp" \
                && "${comment}" == "${UFW_RULE_COMMENT}" ]]; then
                continue
            fi
            return 0
            ;;
        esac
    done <<<"${added}"
    return 1
}

verify_ssh_ufw_no_unmanaged_block() {
    local desired_ports=$1 port blocked=""
    desired_ports=$(normalize_ufw_tcp_ports "${desired_ports}") \
        || die "SSH UFW 预检端口列表无效：${desired_ports}"
    for port in ${desired_ports}; do
        ufw_ssh_port_has_unmanaged_block "${port}" && blocked+="${port}"$'\n'
    done
    [[ -z "${blocked}" ]] \
        || die "SSH TCP ${blocked//$'\n'/ } 存在更早生效的第三方 UFW DENY/REJECT；停止应用以保留现有规则"
}

apply_managed_ufw_tcp_ports() {
    local desired_ports ssh_ports=${2:-} port rule_number stale
    desired_ports=$(normalize_ufw_tcp_ports "$1") \
        || die "受管 UFW TCP 端口列表无效：$1"

    # Add and verify the full desired set first. UFW can report success while
    # skipping a duplicate, so deleting numbered rules first may remove the
    # only SSH allow rule and lock out the administrator.
    for port in ${desired_ports}; do
        if [[ -n "${ssh_ports}" && " ${ssh_ports} " == *" ${port} "* ]] \
            && ufw_tcp_port_has_unmanaged_anywhere_allow "${port}"; then
            info "UFW TCP ${port} 已由第三方规则全局放行；保留原规则"
            continue
        fi
        ufw allow "${port}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "添加受管 UFW 规则失败：TCP ${port}"
    done
    if [[ -n "${ssh_ports}" ]]; then
        remove_managed_ssh22_ufw_deny || die "撤销受管 SSH 22 阻断规则失败"
    fi
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    verify_ufw_tcp_ports "${desired_ports}"
    for port in ${ssh_ports}; do
        ufw_ssh_port_is_allowed "${port}" || die "UFW 未按规则顺序有效放行 SSH ${port}；保留旧规则"
    done

    stale=$(stale_managed_ufw_rule_numbers "${desired_ports}") || die "读取过期 UFW 规则失败"
    while read -r rule_number; do
        [[ -n "${rule_number}" ]] || continue
        ufw --force delete "${rule_number}" >/dev/null \
            || die "删除过期 UFW 规则失败：${rule_number}"
    done <<<"${stale}"

    ufw reload >/dev/null || die "重载 UFW 失败"
    verify_ufw_tcp_ports "${desired_ports}"
    for port in ${ssh_ports}; do
        ufw_ssh_port_is_allowed "${port}" || die "UFW 未按规则顺序有效放行 SSH ${port}"
    done
}

# UFW is ordered. An earlier deny can make an existing allow ineffective.
ufw_ssh_port_is_allowed() {
    LC_ALL=C ufw status numbered 2>/dev/null | awk -v port="${1:-${SSH_PORTS:-22}}" '
        /\(v6\)/ {next}
        {
            if (decided) next
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
            # Keep reading after a decision: an early `exit` closes the pipe and
            # `pipefail` then reports SIGPIPE from `ufw status` as a real failure.
            if (fields[action] == "DENY" || fields[action] == "REJECT") {
                # 只有来源为 Anywhere 的 DENY/REJECT 才阻断所有客户端；Fail2ban 按 IP
                # 封禁时来源是具体地址，不能据此判定 SSH 不可达。
                if (fields[action+2] == "Anywhere" || fields[action+2] == "Any") decided=1
                next
            }
            # An interface-only allow cannot establish global SSH reachability.
            if (action == 2 && fields[action] == "ALLOW" && fields[action+2] == "Anywhere") {allowed=1; decided=1}
        }
        END {exit !allowed}
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
    local numbers number remaining status added managed
    numbers=$(managed_ssh22_ufw_rule_numbers) || return 1
    # `status numbered` hides persisted rules while UFW is inactive. Query the
    # saved commands, and delete by specification only after exact ownership is
    # established; comments alone do not constrain UFW's rule matching.
    status=$(LC_ALL=C ufw status numbered 2>/dev/null) || return 1
    if [[ "${status}" == 'Status: inactive' ]]; then
        added=$(LC_ALL=C ufw show added 2>/dev/null) || return 1
        managed="ufw deny 22/tcp comment '${UFW_RULE_COMMENT}'"
        if grep -Fx -- "${managed}" <<<"${added}" >/dev/null; then
            ufw --force delete deny 22/tcp >/dev/null || return 1
            added=$(LC_ALL=C ufw show added 2>/dev/null) || return 1
            ! grep -Fx -- "${managed}" <<<"${added}" >/dev/null || return 1
        fi
        return 0
    fi
    [[ -n "${numbers}" ]] || return 0
    while read -r number; do
        ufw --force delete "${number}" >/dev/null || return 1
    done <<<"${numbers}"
    ufw reload >/dev/null || return 1
    remaining=$(managed_ssh22_ufw_rule_numbers) || return 1
    [[ -z "${remaining}" ]]
}

apply_ssh_ufw_policy() {
    local desired_ports ssh_ports
    desired_ports=$(normalize_ufw_tcp_ports "$1") || die "SSH UFW 端口列表无效"
    # Existing profiles pass business ports too; only the SSH subset needs the
    # ordered, globally reachable ALLOW check. Bunny passes its detected set.
    ssh_ports=$(normalize_ufw_tcp_ports "${2:-${SSH_PORTS:-22}}") || die "SSH UFW 校验端口列表无效"
    verify_ssh_ufw_no_unmanaged_block "${ssh_ports}"
    apply_managed_ufw_tcp_ports "${desired_ports}" "${ssh_ports}"
}

# 原子移除 easy_all 注入的规则区块；不用 sed -i，避免在系统目录留下 .bak。
remove_ufw_managed_block() {
    local file=$1 start=$2 end=$3 candidate mode
    [[ -f "${file}" ]] || return 0
    grep -Fxq -- "${start}" "${file}" || return 0
    # 缺少结束标记时不能按区块删除，否则会连带删掉文件其余内容。
    if ! grep -Fxq -- "${end}" "${file}"; then
        warn "UFW 规则区块缺少结束标记 ${end}：${file}"
        return 1
    fi
    mode=$(stat -c '%a' "${file}" 2>/dev/null || stat -f '%Lp' "${file}" 2>/dev/null || true)
    [[ -n "${mode}" ]] || mode=0644
    candidate=$(mktemp "$(dirname -- "${file}")/.easy-all-ufw-block.XXXXXX") || return 1
    if ! awk -v start="${start}" -v end="${end}" '
        $0 == start {skip=1; next}
        $0 == end {skip=0; next}
        !skip {print}
    ' "${file}" >"${candidate}"; then
        rm -f -- "${candidate}"
        return 1
    fi
    install -m "${mode}" "${candidate}" "${file}" || { rm -f -- "${candidate}"; return 1; }
    rm -f -- "${candidate}"
}

# 卸载只回收业务端口：保留 UFW 启用状态、默认策略与 SSH 放行，绝不执行 ufw disable。
reclaim_ufw_business_rules() {
    local ssh_ports status number port allowed_before=""
    command -v ufw >/dev/null 2>&1 || return 0
    # 用命令替换读完整输出：`ufw status | grep -q` 在封禁条目很多时会因 SIGPIPE + pipefail 误判。
    status=$(LC_ALL=C ufw status 2>/dev/null) || return 0
    [[ "${status}" == *'Status: active'* ]] || return 0
    # 无法确认 SSH 端口时宁可保留全部规则，也不能删掉 SSH 放行造成失联。
    if ! ssh_ports=$(detect_ssh_ports strict && printf '%s' "${SSH_PORTS}"); then
        warn "无法确认当前 SSH 端口；保留现有 UFW 规则，请人工核对 ufw status"
        return 1
    fi
    ssh_ports=$(normalize_ufw_tcp_ports "${ssh_ports}") \
        || { warn "SSH 端口列表无效；保留现有 UFW 规则"; return 1; }
    for port in ${ssh_ports}; do
        ufw_ssh_port_is_allowed "${port}" && allowed_before+=" ${port}"
    done
    # 每次删除前重新读取编号：Fail2ban 的 `ufw insert 1` 会让所有编号后移。
    for _ in {1..16}; do
        read -r number < <(stale_managed_ufw_rule_numbers "${ssh_ports}" | head -n 1) || break
        [[ -n "${number}" ]] || break
        ufw --force delete "${number}" >/dev/null 2>&1 \
            || { warn "删除业务 UFW 规则 ${number} 失败"; return 1; }
    done
    ufw reload >/dev/null 2>&1 || true
    for port in ${ssh_ports}; do
        ufw_ssh_port_is_allowed "${port}" && continue
        if [[ " ${allowed_before} " != *" ${port} "* ]]; then
            # 原本就只允许指定来源（或未放行）：不能擅自扩大为全网放行。
            warn "UFW 未全局放行 SSH ${port}；保留现有规则，请人工核对 ufw status"
            continue
        fi
        # 删除按编号执行，若 Fail2ban 插入封禁规则导致编号漂移，必须补回 SSH 放行。
        warn "UFW 未保留 SSH ${port} 放行，正在补回受管放行规则"
        ufw allow "${port}/tcp" comment "${UFW_RULE_COMMENT}" >/dev/null 2>&1 \
            && ufw reload >/dev/null 2>&1 || true
        ufw_ssh_port_is_allowed "${port}" \
            || { warn "UFW 无法恢复 SSH ${port} 放行；请立即通过 Console 核对"; return 1; }
    done
}
