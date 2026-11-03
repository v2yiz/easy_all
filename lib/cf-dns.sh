#!/usr/bin/env bash

# Cloudflare DNS and Origin CA helpers shared by combined profiles.

cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret "Cloudflare API Token（仅当前进程使用，不落盘）") \
            || die "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
    fi
    [[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
        && "${CLOUDFLARE_API_TOKEN}" != *[[:space:]]* ]] || die "CLOUDFLARE_API_TOKEN 格式无效"
}

cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" \
        "${RUNTIME_TMP}/cloudflare-worker-api-headers"
}

cloudflare_api_request() {
    local method=$1 path=$2 payload=${3:-} response headers payload_file status
    local -a retry_args=(--retry 0)
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "缺少 CLOUDFLARE_API_TOKEN"
    headers="${RUNTIME_TMP}/cloudflare-api-headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
        "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    case "${method}" in
    GET | HEAD | PUT) retry_args=(--retry 2) ;;
    esac
    if [[ -n "${payload}" ]]; then
        payload_file="${RUNTIME_TMP}/cloudflare-api-payload"
        printf '%s' "${payload}" >"${payload_file}"
        chmod 0600 "${payload_file}"
        response=$(curl -sS "${retry_args[@]}" --connect-timeout 10 --max-time 45 -X "${method}" -w $'\n%{http_code}' \
            -H "@${headers}" \
            --data-binary "@${payload_file}" "${CLOUDFLARE_API_BASE}${path}") || die "Cloudflare API 请求失败：${method} ${path}"
    else
        response=$(curl -sS "${retry_args[@]}" --connect-timeout 10 --max-time 45 -X "${method}" -w $'\n%{http_code}' \
            -H "@${headers}" "${CLOUDFLARE_API_BASE}${path}") || die "Cloudflare API 请求失败：${method} ${path}"
    fi
    status=${response##*$'\n'}
    response=${response%$'\n'*}
    if [[ "${method}" == "DELETE" && ( "${status}" == "200" || "${status}" == "204" ) && -z "${response//[[:space:]]/}" ]]; then
        printf 'null\n'
        return 0
    fi
    [[ "${status}" == 2[0-9][0-9] ]] || {
        printf '%s\n' "${response:-<empty>}" >&2
        die "Cloudflare API HTTP ${status:-000}：${method} ${path}"
    }
    jq -se 'length == 1 and (.[0] | type == "object" and .success == true)' \
        <<<"${response}" >/dev/null \
        || { printf '%s\n' "${response:-<empty>}" >&2; die "Cloudflare API 返回错误（HTTP ${status}）：${method} ${path}"; }
    jq -sc '.[0].result' <<<"${response}"
}

cloudflare_origin_ufw_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | sed -n "/${CLOUDFLARE_UFW_COMMENT}/s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)\\].*/\\1/p" \
        | sort -rn
}

cloudflare_remove_origin_firewall_rules() {
    local number
    while IFS= read -r number; do
        [[ -n "${number}" ]] || continue
        ufw --force delete "${number}" >/dev/null 2>&1 \
            || warn "删除 Cloudflare 回源 UFW 规则 ${number} 失败"
    done < <(cloudflare_origin_ufw_rule_numbers)
}

cloudflare_configure_origin_firewall() {
    local next current cidr
    next="${RUNTIME_TMP}/cloudflare-origin-ipv4.txt"
    if ! cloudflare_fetch_origin_ipv4_ranges >"${next}" || [[ ! -s "${next}" ]]; then
        if [[ -s "${CLOUDFLARE_ORIGIN_IPS_FILE}" ]]; then
            warn "获取 Cloudflare 官方 IP 段失败，继续使用上一版回源白名单"
            install -m 0600 "${CLOUDFLARE_ORIGIN_IPS_FILE}" "${next}"
        else
            die "无法获取 Cloudflare 官方 IPv4 段，且本机没有可回退的白名单"
        fi
    fi
    current="${RUNTIME_TMP}/cloudflare-origin-ipv4.current"
    if [[ -s "${CLOUDFLARE_ORIGIN_IPS_FILE}" ]]; then
        install -m 0600 "${CLOUDFLARE_ORIGIN_IPS_FILE}" "${current}"
    else
        : >"${current}"
    fi

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        ufw allow proto tcp from "${cidr}" to any port 443 \
            comment "${CLOUDFLARE_UFW_COMMENT}" >/dev/null \
            || die "添加 Cloudflare 回源 UFW 规则失败：${cidr}"
    done <"${next}"
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        ufw_tcp_port_is_allowed 443 "${cidr}" \
            || die "UFW 未有效放行 Cloudflare 回源：${cidr}"
    done <"${next}"

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${next}" && continue
        ufw --force delete allow proto tcp from "${cidr}" to any port 443 >/dev/null \
            || warn "删除过期 Cloudflare 回源 UFW 规则失败：${cidr}"
    done <"${current}"
    install -d -m 0700 "$(dirname "${CLOUDFLARE_ORIGIN_IPS_FILE}")"
    install -m 0600 "${next}" "${CLOUDFLARE_ORIGIN_IPS_FILE}"
    ufw reload >/dev/null || die "重载 UFW 失败"
}

cloudflare_lookup_parent_zone() {
    local domain=$1 candidate zone
    candidate=${domain}
    while [[ "${candidate}" == *.* ]]; do
        zone=$(cloudflare_api_request GET "/zones?name=${candidate}&status=active&per_page=50" | jq -r --arg name "${candidate}" '[.[] | select((.name|ascii_downcase)==$name) | .id] | if length == 1 then .[0] else empty end')
        if [[ -n "${zone}" ]]; then printf '%s' "${zone}"; return; fi
        candidate=${candidate#*.}
    done
    return 1
}

cloudflare_find_parent_zone() {
    local domain=$1
    cloudflare_lookup_parent_zone "${domain}" \
        || die "Cloudflare active Zone 未覆盖域名：${domain}"
}

cloudflare_record_list() { cloudflare_api_request GET "/zones/$1/dns_records?type=$2&name=$3&per_page=100"; }

cloudflare_require_single_record() {
    local records=$1 count
    count=$(jq 'length' <<<"${records}")
    ((count <= 1)) || die "Cloudflare 中发现多个同名同类型 DNS 记录，拒绝猜测或覆盖"
}

cloudflare_ensure_proxied_a() {
    local zone=$1 host=$2 ip=$3 records record id content proxied comment type payload result
    for type in A AAAA CNAME; do
        records=$(cloudflare_record_list "${zone}" "${type}" "${host}")
        cloudflare_require_single_record "${records}"
        [[ "${type}" == A ]] || [[ $(jq 'length' <<<"${records}") == 0 ]] || die "${host} 已有 ${type} 记录；拒绝覆盖"
        if [[ "${type}" == A && $(jq 'length' <<<"${records}") == 1 ]]; then
            record=$(jq -c '.[0]' <<<"${records}"); id=$(jq -r '.id' <<<"${record}")
            content=$(jq -r '.content' <<<"${record}"); proxied=$(jq -r '.proxied' <<<"${record}")
            comment=$(jq -r '.comment // empty' <<<"${record}")
            if [[ "${content}" == "${ip}" && "${proxied}" == true ]]; then
                return 0
            fi
            [[ "${comment}" == "easy_all xhttp origin" ]] \
                || die "${host} 的 A 记录与 easy_all 目标不一致或未代理；拒绝覆盖"
            payload=$(jq -cn --arg name "${host}" --arg content "${ip}" \
                '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"easy_all xhttp origin"}')
            cloudflare_api_request PATCH "/zones/${zone}/dns_records/${id}" \
                "${payload}" >/dev/null
            return 0
        fi
    done
    result=$(cloudflare_api_request POST "/zones/${zone}/dns_records" \
        "$(jq -cn --arg name "${host}" --arg content "${ip}" '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"easy_all xhttp origin"}')")
    CLOUDFLARE_CREATED_DNS_RECORD_ID=$(jq -r '.id // empty' <<<"${result}")
    [[ -n "${CLOUDFLARE_CREATED_DNS_RECORD_ID}" ]] \
        || die "Cloudflare 未返回新建 DNS 记录 ID"
}

cloudflare_validate_zones() {
    local zone
    CLOUDFLARE_ZONE_ID=$(cloudflare_find_parent_zone "${VLESS_CDN_DOMAIN}")
    CLOUDFLARE_CDN_ZONE_ID=${CLOUDFLARE_ZONE_ID}
    CLOUDFLARE_SUBSCRIPTION_ZONE_ID=$(cloudflare_find_parent_zone "$(active_subscription_link_domain)")
    [[ "${CLOUDFLARE_ZONE_ID}" == "${CLOUDFLARE_SUBSCRIPTION_ZONE_ID}" ]] || die "订阅域名必须在同一个 Cloudflare Zone"
    zone=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}")
    CLOUDFLARE_ZONE_NAME=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    CLOUDFLARE_ACCOUNT_ID=$(jq -r '.account.id // empty' <<<"${zone}")
    [[ -n "${CLOUDFLARE_ZONE_NAME}" ]] || die "Cloudflare Zone 未返回有效名称"
    [[ "${CLOUDFLARE_ACCOUNT_ID}" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "Cloudflare Zone 未返回有效 Account ID"
    cloudflare_validate_universal_hostname "${VLESS_CDN_DOMAIN}"
    cloudflare_validate_universal_hostname "$(active_subscription_link_domain)"
}

cloudflare_ensure_origin_ca_root() {
    CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
    if [[ -s "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" ]] \
        && openssl x509 -in "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" -noout >/dev/null 2>&1; then
        return 0
    fi
    install -d -m 0700 "${CERT_DIR}"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        "${CLOUDFLARE_ORIGIN_CA_ROOT_URL}" \
        -o "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" \
        || die "下载 Cloudflare Origin CA ECC 根证书失败"
    openssl x509 -in "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" -noout >/dev/null 2>&1 \
        || die "Cloudflare Origin CA ECC 根证书格式无效"
    install -m 0644 "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" \
        "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
}

cloudflare_origin_certificate_is_current() {
    local host expected_hosts actual_hosts
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] || return 1
    openssl x509 -in "${CERT_FILE}" -checkend 2592000 -noout >/dev/null 2>&1 \
        || return 1
    while IFS= read -r host; do
        openssl x509 -in "${CERT_FILE}" -checkhost "${host}" -noout >/dev/null 2>&1 \
            || return 1
    done < <(jq -r '.[]' <<<"$(cloudflare_origin_certificate_hosts)")
    expected_hosts=$(cloudflare_origin_certificate_hosts | jq -r '.[]' | sort -u)
    actual_hosts=$(openssl x509 -in "${CERT_FILE}" -noout -ext subjectAltName 2>/dev/null \
        | sed -n '2,$p' | tr ',' '\n' \
        | sed -n 's/^[[:space:]]*DNS://p' | sort -u)
    [[ -n "${actual_hosts}" && "${actual_hosts}" == "${expected_hosts}" ]] \
        || return 1
    [[ "$(openssl x509 -in "${CERT_FILE}" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" \
        == "$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null \
        | sha256sum | cut -d' ' -f1)" ]] || return 1
}

cloudflare_origin_certificate_hosts() {
    jq -cn --arg cdn "${VLESS_CDN_DOMAIN}" '[$cdn]'
}

cloudflare_origin_certificate_is_reusable() {
    # A current certificate on disk is only reusable with the Cloudflare side
    # metadata that save_state persists and load_state requires; reusing one
    # without the ID/expiry would persist an incomplete state that renew and
    # uninstall cannot resolve afterwards.
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" ]] \
        && cloudflare_origin_certificate_is_current
}

cloudflare_issue_origin_certificate() {
    local force=${1:-0} key csr result cert expires hosts san old_id
    cloudflare_ensure_origin_ca_root
    if [[ "${force}" != "1" ]] && cloudflare_origin_certificate_is_reusable; then
        return 0
    fi
    cloudflare_collect_api_token
    old_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    install -d -m 0700 "${CERT_DIR}"
    key="${RUNTIME_TMP}/cloudflare-origin-ecc.key"
    csr="${RUNTIME_TMP}/cloudflare-origin.csr"
    openssl ecparam -name prime256v1 -genkey -noout -out "${key}"
    chmod 0600 "${key}"
    hosts=$(cloudflare_origin_certificate_hosts)
    san=$(jq -r 'map("DNS:" + .) | join(",")' <<<"${hosts}")
    openssl req -new -sha256 -key "${key}" -subj "/CN=${CLOUDFLARE_ORIGIN_DOMAIN}" \
        -addext "subjectAltName=${san}" -out "${csr}"
    result=$(cloudflare_api_request POST '/certificates' "$(jq -cn --arg csr "$(<"${csr}")" --argjson hosts "${hosts}" --argjson validity "${CLOUDFLARE_ORIGIN_VALIDITY_DAYS}" '{hostnames:$hosts,requested_validity:$validity,request_type:"origin-ecc",csr:$csr}')")
    cert=$(jq -r '.certificate // empty' <<<"${result}"); CLOUDFLARE_ORIGIN_CERT_ID=$(jq -r '.id // empty' <<<"${result}"); expires=$(jq -r '.expires_on // empty' <<<"${result}")
    [[ -n "${cert}" && -n "${CLOUDFLARE_ORIGIN_CERT_ID}" && -n "${expires}" ]] || die "Cloudflare 未返回 Origin CA 证书、ID 或到期时间"
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID=${CLOUDFLARE_ORIGIN_CERT_ID}
    printf '%s\n' "${cert}" >"${RUNTIME_TMP}/origin.pem"
    openssl verify -CAfile "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" \
        "${RUNTIME_TMP}/origin.pem" >/dev/null \
        || die "Cloudflare Origin CA 证书链验证失败"
    install -m 0600 "${RUNTIME_TMP}/origin.pem" "${CERT_FILE}"
    install -m 0600 "${key}" "${KEY_FILE}"
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=${expires}
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=${old_id}
}

cloudflare_finalize_certificate_rotation() {
    local old_id=${CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID:-}
    [[ -n "${old_id}" && "${old_id}" != "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]] \
        || return 0
    if ! (cloudflare_api_request DELETE "/certificates/${old_id}" >/dev/null); then
        warn "新证书已通过公网验收，但撤销旧 Cloudflare Origin CA 证书失败：${old_id}"
        return 0
    fi
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=""
}

cloudflare_fetch_origin_ipv4_ranges() {
    local response
    response=$(curl -fsS --retry 3 --connect-timeout 10 --max-time 30 \
        "${CLOUDFLARE_API_BASE}/ips") \
        || return 1
    jq -er '
        select(.success == true)
        | .result.ipv4_cidrs
        | select(type == "array" and length > 0)
        | unique[]
        | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([89]|[12][0-9]|3[0-2])$"))
    ' <<<"${response}" | sort -u
}
