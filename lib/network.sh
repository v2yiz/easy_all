#!/usr/bin/env bash

# Shared public network discovery and Xray IPv4 egress policy.

readonly XRAY_OUTBOUND_DOMAIN_STRATEGY="ForceIPv4"

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

xray_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
      "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
    ]'
}

xray_direct_outbounds_json() {
    jq -cn --arg strategy "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" '[
      {protocol:"freedom",tag:"direct",settings:{domainStrategy:$strategy}},
      {protocol:"blackhole",tag:"block"}
    ]'
}

xray_direct_routing_json() {
    local private_ranges
    private_ranges=$(xray_private_ranges_json)
    jq -cn --argjson private "${private_ranges}" '{
      domainStrategy:"IPOnDemand",
      rules:[
        {type:"field",ip:$private,outboundTag:"block"},
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
