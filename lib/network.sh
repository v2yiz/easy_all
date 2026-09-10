#!/usr/bin/env bash

# Shared public network discovery and Xray egress policy.

readonly XRAY_OUTBOUND_DOMAIN_STRATEGY="UseIPv4"
readonly XRAY_INBOUND_TCP_KEEPALIVE_IDLE="300"
readonly XRAY_INBOUND_TCP_KEEPALIVE_INTERVAL="30"

validate_ipv6() {
    local ip=${1%%%*} segment rest colons
    [[ -n "${ip}" && ${#ip} -le 39 && "${ip}" == *:* \
        && "${ip}" =~ ^[0-9A-Fa-f:]+$ && "${ip}" != *:::* ]] || return 1
    colons=${ip//[^:]/}
    if [[ "${ip}" == *::* ]]; then
        rest=${ip#*::}
        [[ "${rest}" != *::* ]] || return 1
        ((${#colons} >= 2 && ${#colons} <= 8)) || return 1
    else
        ((${#colons} == 7)) || return 1
    fi
    for segment in ${ip//:/ }; do
        [[ ${#segment} -ge 1 && ${#segment} -le 4 \
            && "${segment}" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    done
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
    info "全局 IPv4-only：已禁用 VPS、Xray 与客户端 IPv6"
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

xray_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
      "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
    ]'
}

xray_direct_outbounds_json() {
    normalize_google_egress_policy
    jq -cn --arg strategy "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" '[
      {
        protocol:"freedom",tag:"direct",sendThrough:"0.0.0.0",
        targetStrategy:"ForceIPv4",settings:{domainStrategy:$strategy}
      },
      {protocol:"blackhole",tag:"block"}
    ]'
}

xray_inbound_sockopt_json() {
    jq -cn --argjson idle "${XRAY_INBOUND_TCP_KEEPALIVE_IDLE}" \
        --argjson interval "${XRAY_INBOUND_TCP_KEEPALIVE_INTERVAL}" \
        '{tcpKeepAliveIdle:$idle,tcpKeepAliveInterval:$interval}'
}

xray_direct_routing_json() {
    local private_ranges
    normalize_google_egress_policy
    private_ranges=$(xray_private_ranges_json)
    jq -cn --argjson private "${private_ranges}" '{
      domainStrategy:"IPOnDemand",
      rules: [
        {type:"field",ip:$private,outboundTag:"block"},
        {type:"field",network:"udp",port:"443",outboundTag:"block"},
        {type:"field",network:"tcp,udp",outboundTag:"direct"}
      ]
    }'
}

xray_xhttp_outbounds_json() {
    xray_direct_outbounds_json
}

xray_xhttp_routing_json() {
    xray_direct_routing_json
}
