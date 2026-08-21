#!/usr/bin/env bash

# Shared public network discovery and VPS-side Gemini egress family selection.

detect_public_ipv4() {
    local service ip
    local -a services=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.co"
    )
    for service in "${services[@]}"; do
        ip=$(curl -4fsS --max-time 10 "${service}" 2>/dev/null | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done
    return 1
}

measure_gemini_ip_family() {
    local family=$1 flag result attempt
    local -a timings=()
    [[ "${family}" == "ipv6" ]] && flag="-6" || flag="-4"
    for attempt in 1 2 3; do
        result=$(curl "${flag}" --noproxy '*' --silent --show-error \
            --output /dev/null --connect-timeout 5 --max-time 10 \
            --write-out '%{time_total}' 'https://gemini.google.com/' 2>/dev/null) \
            || continue
        [[ "${result}" =~ ^[0-9]+([.][0-9]+)?$ ]] || continue
        timings+=("${result}")
    done
    ((${#timings[@]} > 0)) || return 1
    printf '%s\n' "${timings[@]}" | sort -n | awk '
        { values[NR] = $1 }
        END { print values[int((NR + 1) / 2)] }
    '
}

resolve_gemini_ip_family() {
    local requested=${GEMINI_IP_FAMILY:-auto} ipv4_time="" ipv6_time=""
    local ipv4_display ipv6_display
    case "${requested}" in
    ipv4 | ipv6)
        GEMINI_IP_FAMILY_RESOLVED=${requested}
        ;;
    auto)
        ipv4_time=$(measure_gemini_ip_family ipv4 || true)
        if command -v ip >/dev/null 2>&1 \
            && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6 ' \
            && ip -6 route show default 2>/dev/null | grep -q '^default'; then
            ipv6_time=$(measure_gemini_ip_family ipv6 || true)
        fi
        if [[ -z "${ipv4_time}" && -z "${ipv6_time}" ]]; then
            GEMINI_IP_FAMILY_RESOLVED="ipv4"
            warn "Gemini IPv4/IPv6 测速均失败，保守选择 IPv4"
        elif [[ -z "${ipv4_time}" ]]; then
            GEMINI_IP_FAMILY_RESOLVED="ipv6"
        elif [[ -z "${ipv6_time}" ]]; then
            GEMINI_IP_FAMILY_RESOLVED="ipv4"
        elif awk -v ipv4="${ipv4_time}" -v ipv6="${ipv6_time}" \
            'BEGIN { exit !(ipv6 < ipv4) }'; then
            GEMINI_IP_FAMILY_RESOLVED="ipv6"
        else
            GEMINI_IP_FAMILY_RESOLVED="ipv4"
        fi
        [[ -n "${ipv4_time}" ]] && ipv4_display="${ipv4_time}s" || ipv4_display="不可用"
        [[ -n "${ipv6_time}" ]] && ipv6_display="${ipv6_time}s" || ipv6_display="不可用"
        info "Gemini 出口测速：IPv4 ${ipv4_display}，IPv6 ${ipv6_display}；固定使用 ${GEMINI_IP_FAMILY_RESOLVED}"
        ;;
    *) die "GEMINI_IP_FAMILY 必须是 auto、ipv4 或 ipv6" ;;
    esac
}

active_gemini_ip_family() {
    local strategy=""
    [[ -s "${XRAY_CONFIG}" ]] || return 1
    strategy=$(jq -r \
        '.outbounds[]? | select(.tag == "gemini-family") | .settings.domainStrategy' \
        "${XRAY_CONFIG}")
    case "${strategy}" in
    ForceIPv6) printf 'ipv6\n' ;;
    ForceIPv4) printf 'ipv4\n' ;;
    *) return 1 ;;
    esac
}

gemini_ip_family_status() {
    active_gemini_ip_family \
        || printf '未应用，请执行 easy_all apply\n'
}
