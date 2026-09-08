#!/usr/bin/env bash

# Shared public network discovery and Xray egress policy.

readonly XRAY_OUTBOUND_DOMAIN_STRATEGY="AsIs"
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

canonicalize_ipv6() {
    local ip=${1%%%*} canonical=""
    validate_ipv6 "${ip}" || return 1
    if command -v ip >/dev/null 2>&1; then
        canonical=$(ip -6 route get "${ip}" 2>/dev/null \
            | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /:/) {print $i; exit}}' \
            || true)
    fi
    [[ -n "${canonical}" ]] || canonical=${ip}
    tr '[:upper:]' '[:lower:]' <<<"${canonical}" | tr -d '\n'
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

enable_ipv6_for_detection() {
    [[ -d /proc/sys/net/ipv6 ]] || return 1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || return 1
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || return 1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || return 1
}

detect_public_ipv6() {
    local service candidate canonical
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 -o addr show scope global 2>/dev/null | grep -q 'inet6 ' || return 1
    ip -6 route show default 2>/dev/null | grep -q '^default' || return 1
    local -a services=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
        "https://ifconfig.co/ip"
    )
    for service in "${services[@]}"; do
        candidate=$(curl -6fsS --noproxy '*' --max-time 10 "${service}" 2>/dev/null \
            | tr -d '[:space:]' || true)
        validate_ipv6 "${candidate}" || continue
        canonical=$(canonicalize_ipv6 "${candidate}") || continue
        printf '%s\n' "${canonical}"
        return 0
    done
    return 1
}

ensure_vps_ip_family() {
    local detected=""
    case "${VPS_IP_FAMILY:-}" in
    dual)
        validate_ipv6 "${VPS_PUBLIC_IPV6:-}" \
            || die "双栈状态缺少有效的 VPS_PUBLIC_IPV6"
        VPS_PUBLIC_IPV6=$(canonicalize_ipv6 "${VPS_PUBLIC_IPV6}")
        return 0
        ;;
    ipv4)
        VPS_PUBLIC_IPV6=""
        return 0
        ;;
    "") ;;
    *) die "VPS_IP_FAMILY 必须是 ipv4 或 dual" ;;
    esac

    if enable_ipv6_for_detection; then
        detected=$(detect_public_ipv6 || true)
    fi
    if [[ -n "${detected}" ]]; then
        VPS_IP_FAMILY="dual"
        VPS_PUBLIC_IPV6=${detected}
        info "检测到可用公网 IPv6：${VPS_PUBLIC_IPV6}；启用 VPS 双栈，Google 出站固定 IPv4"
    else
        VPS_IP_FAMILY="ipv4"
        VPS_PUBLIC_IPV6=""
        info "未检测到可用公网 IPv6；保持 VPS IPv4-only"
    fi
}

vps_dual_stack_enabled() {
    [[ "${VPS_IP_FAMILY:-ipv4}" == "dual" ]]
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
    jq -cn --arg strategy "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" \
        --argjson dual "$([[ "${VPS_IP_FAMILY:-ipv4}" == "dual" ]] \
            && printf true || printf false)" '
      [
        {protocol:"freedom",tag:"direct",settings:{domainStrategy:$strategy}}
      ]
      + (if $dual then [
          {
            protocol:"freedom",
            tag:"direct-google-ipv4",
            sendThrough:"0.0.0.0",
            targetStrategy:"ForceIPv4",
            settings:{domainStrategy:"UseIPv4"}
          }
        ] else [] end)
      + [{protocol:"blackhole",tag:"block"}]
    '
}

xray_inbound_sockopt_json() {
    jq -cn --argjson idle "${XRAY_INBOUND_TCP_KEEPALIVE_IDLE}" \
        --argjson interval "${XRAY_INBOUND_TCP_KEEPALIVE_INTERVAL}" \
        '{tcpKeepAliveIdle:$idle,tcpKeepAliveInterval:$interval}'
}

xray_direct_routing_json() {
    local private_ranges
    private_ranges=$(xray_private_ranges_json)
    jq -cn --argjson private "${private_ranges}" \
        --argjson dual "$([[ "${VPS_IP_FAMILY:-ipv4}" == "dual" ]] \
            && printf true || printf false)" '{
      domainStrategy:"IPOnDemand",
      rules: (
        [
          {type:"field",ip:$private,outboundTag:"block"},
          {type:"field",network:"udp",port:"443",outboundTag:"block"}
        ]
        + (if $dual then [
            {
              type:"field",
              domain:["geosite:google"],
              outboundTag:"direct-google-ipv4",
              ruleTag:"google-ipv4-only"
            },
            {
              type:"field",
              ip:["geoip:google"],
              outboundTag:"direct-google-ipv4",
              ruleTag:"google-ipv4-only-ip"
            }
          ] else [] end)
        + [{type:"field",network:"tcp,udp",outboundTag:"direct"}]
      )
    }'
}

xray_xhttp_outbounds_json() {
    xray_direct_outbounds_json
}

xray_xhttp_routing_json() {
    xray_direct_routing_json
}
