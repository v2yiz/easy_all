#!/usr/bin/env bash

# Shared public network discovery and VPS-side Google/Gemini egress policy.

readonly GEMINI_OUTBOUND_IP_FAMILY="ipv4"
readonly GEMINI_OUTBOUND_DOMAIN_STRATEGY="ForceIPv4"

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
        || printf '%s（未应用，请执行 easy_all apply）\n' "${GEMINI_OUTBOUND_IP_FAMILY}"
}
