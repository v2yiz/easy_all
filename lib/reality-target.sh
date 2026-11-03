#!/usr/bin/env bash

# Reality target validation shared by the Reality and combined profiles.

readonly RIPE_PREFIX_OVERVIEW_API="https://stat.ripe.net/data/prefix-overview/data.json"

validate_reality_target() {
    local target=$1 host port
    [[ "${target}" == *:* ]] || return 1
    host=${target%:*}
    port=${target##*:}
    validate_domain "${host}" || return 1
    [[ "${port}" =~ ^[0-9]+$ ]] && ((port >= 1 && port <= 65535))
}

reality_tls_ping_succeeded() {
    awk '
        /Pinging with SNI/ {in_sni=1; next}
        in_sni && /Handshake succeeded/ {handshake=1}
        in_sni && /TLS Version:[[:space:]]*TLS 1\.3/ {tls13=1}
        END {exit !(handshake && tls13)}
    '
}

lookup_ip_asns() {
    local ip=$1 response
    response=$(curl --noproxy '*' -fsS --retry 2 \
        --connect-timeout 5 --max-time 10 --get \
        --data-urlencode "resource=${ip}" "${RIPE_PREFIX_OVERVIEW_API}" \
        2>/dev/null) || return 1
    jq -r '.data.asns // [] | map(tostring) | join(" ")' <<<"${response}"
}

resolve_reality_target_ipv4s() {
    local host=${REALITY_TARGET%:*} record
    while IFS= read -r record; do
        validate_ipv4 "${record}" && printf '%s\n' "${record}"
    done < <(dig +short A "${host}" 2>/dev/null || true)
}

validate_reality_target_asn() {
    local vps_ip vps_asns target_ip target_asns vps_asn target_asn
    local target_asn_summary="" matched=0
    vps_ip=$(detect_public_ipv4 || true)
    [[ -n "${vps_ip}" ]] || {
        warn "无法检测 VPS 公网 IPv4，跳过 Reality 同 ASN 检查"
        return 0
    }
    vps_asns=$(lookup_ip_asns "${vps_ip}" || true)
    [[ -n "${vps_asns}" ]] || {
        warn "无法查询 VPS ASN，跳过 Reality 同 ASN 检查"
        return 0
    }
    while IFS= read -r target_ip; do
        [[ -n "${target_ip}" ]] || continue
        target_asns=$(lookup_ip_asns "${target_ip}" || true)
        [[ -n "${target_asns}" ]] || continue
        [[ -z "${target_asn_summary}" ]] || target_asn_summary+=", "
        target_asn_summary+="${target_ip}=AS${target_asns// /,AS}"
        for vps_asn in ${vps_asns}; do
            for target_asn in ${target_asns}; do
                [[ "${vps_asn}" != "${target_asn}" ]] || matched=1
            done
        done
        [[ "${matched}" != "1" ]] || break
    done < <(resolve_reality_target_ipv4s | head -n 4)
    if [[ "${matched}" == "1" ]]; then
        success "Reality 目标与 VPS 命中同 ASN（AS${vps_asns// /,AS}）"
    elif [[ -n "${target_asn_summary}" ]]; then
        warn "Reality 目标与 VPS 不同 ASN（VPS AS${vps_asns// /,AS}；${target_asn_summary}）；同 ASN 目标的伪装一致性更好"
    else
        warn "无法解析 Reality 目标 IPv4/ASN，跳过同 ASN 检查"
    fi
}

validate_reality_target_runtime() {
    local output
    info "验收 Reality 目标 TLS 1.3：${REALITY_TARGET}"
    output=$(timeout 25 "${XRAY_BIN}" tls ping "${REALITY_TARGET}" 2>&1) \
        || die "Reality 目标不可达或 TLS 探测失败：${REALITY_TARGET}（${output}）"
    reality_tls_ping_succeeded <<<"${output}" \
        || die "Reality 目标未通过带 SNI 的 TLS 1.3 握手：${REALITY_TARGET}（${output}）"
    success "Reality 目标已通过带 SNI 的 TLS 1.3 握手"
    validate_reality_target_asn
}
