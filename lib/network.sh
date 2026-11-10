#!/usr/bin/env bash

# Shared public network discovery and egress policy (sing-box).


validate_ipv6() {
    local ip=${1%%%*} segment rest groups=0
    [[ -n "${ip}" && ${#ip} -le 39 && "${ip}" == *:* \
        && "${ip}" =~ ^[0-9A-Fa-f:]+$ && "${ip}" != *:::* ]] || return 1
    if [[ "${ip}" == *::* ]]; then
        rest=${ip#*::}
        [[ "${rest}" != *::* ]] || return 1
    fi
    for segment in ${ip//:/ }; do
        groups=$((groups + 1))
        [[ ${#segment} -ge 1 && ${#segment} -le 4 \
            && "${segment}" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    done
    if [[ "${ip}" == *::* ]]; then
        ((groups < 8))
    else
        ((groups == 8))
    fi
}

detect_public_ipv4() {
    local service ip
    local -a services=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.co"
    )
    for service in "${services[@]}"; do
        ip=$(curl -4fsS --noproxy '*' --max-time 10 "${service}" 2>/dev/null \
            | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done
    return 1
}

enforce_ipv4_only_policy() {
    VPS_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV6=""
    GOOGLE_EGRESS_MODE="ipv4"
    GOOGLE_EGRESS_RESOLVED="ipv4"
}

ensure_vps_ip_family() {
    enforce_ipv4_only_policy
    info "全局 IPv4-only：已禁用 VPS、sing-box 与客户端 IPv6"
}

validate_google_egress_mode() {
    [[ "$1" == "ipv4" ]]
}

validate_google_egress_family() {
    [[ "$1" == "ipv4" ]]
}

validate_google_egress_policy_state() {
    [[ "${VPS_IP_FAMILY:-}" == "ipv4" && -z "${VPS_PUBLIC_IPV6:-}" ]] \
        && validate_google_egress_mode "${GOOGLE_EGRESS_MODE:-}" \
        && validate_google_egress_family "${GOOGLE_EGRESS_RESOLVED:-}"
}

normalize_google_egress_policy() {
    enforce_ipv4_only_policy
}

refresh_google_egress_selection() {
    normalize_google_egress_policy
    info "Google 原生出站: IPv4（项目全局禁用 IPv6）"
}

choose_google_egress_mode() {
    refresh_google_egress_selection
}

google_egress_status() {
    normalize_google_egress_policy
    printf 'IPv4（固定）'
}
