#!/usr/bin/env bash

# Cloudflare CDN XHTTP profile.  Cloudflare credentials are deliberately
# process-only: state.env contains resource ids but never CF_API_TOKEN.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'xhttp-cloudflare.sh 是 easy_all 的 Cloudflare Profile；请使用：easy_all install\n' >&2
    exit 2
fi

readonly XHTTP_CLOUDFLARE_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly XHTTP_PROFILE_ROOT="${XHTTP_CLOUDFLARE_PROFILE_ROOT}/../lib"
readonly CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
readonly CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS="20-40"
readonly CLOUDFLARE_XHTTP_PADDING_BYTES="100-1000"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_IPS_FILE="/etc/easy_all/cloudflare-origin-ipv4.txt"
readonly CLOUDFLARE_UFW_COMMENT="easy_all-cloudflare-origin"
XHTTP_URL_TEST_INTERVAL_OVERRIDE=300

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"
source "${XHTTP_PROFILE_ROOT}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_PROFILE_ROOT}/cloudflare-ip-pool.sh"

cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret "Cloudflare API Token（仅当前进程使用，不落盘）" \
            "Cloudflare API Token (current process only; never saved)") \
            || die "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
    fi
    [[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
        && "${CLOUDFLARE_API_TOKEN}" != *[[:space:]]* ]] || die "CLOUDFLARE_API_TOKEN 格式无效"
}
cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers"
}

cloudflare_api_request() {
    local method=$1 path=$2 payload=${3:-} response headers
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "缺少 CLOUDFLARE_API_TOKEN"
    headers="${RUNTIME_TMP}/cloudflare-api-headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
        "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    if [[ -n "${payload}" ]]; then
        # Do not use curl's --fail here: Cloudflare returns a useful JSON
        # error body for 4xx responses, and jq below can surface that detail
        # instead of reducing it to a generic "request failed" message.
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "@${headers}" \
            --data "${payload}" "${CLOUDFLARE_API_BASE}${path}") || die "Cloudflare API 请求失败：${method} ${path}"
    else
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "@${headers}" "${CLOUDFLARE_API_BASE}${path}") || die "Cloudflare API 请求失败：${method} ${path}"
    fi
    jq -e '.success == true' <<<"${response}" >/dev/null || { jq -c '.errors // .' <<<"${response}" >&2; die "Cloudflare API 返回错误：${method} ${path}"; }
    jq -c '.result' <<<"${response}"
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

    # Add every new range before deleting stale ranges.  A failed refresh can
    # therefore never leave port 443 without the previous Cloudflare allowlist.
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        # Re-assert every desired rule so a manually removed UFW entry is
        # restored even when the cached Cloudflare range list is unchanged.
        ufw allow proto tcp from "${cidr}" to any port 443 \
            comment "${CLOUDFLARE_UFW_COMMENT}" >/dev/null \
            || die "添加 Cloudflare 回源 UFW 规则失败：${cidr}"
    done <"${next}"
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"

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

xhttp_configure_ufw() {
    local desired_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ufw
    fi
    ensure_ssh_boot_service
    detect_ssh_ports
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    desired_ports=${SSH_PORTS}
    # Keep SSH and a temporary unrestricted 443 rule while the Cloudflare
    # source ranges are staged.  Remove unrestricted 443 only after every
    # current Cloudflare range has been accepted by UFW.
    apply_managed_ufw_tcp_ports "${desired_ports} 443"
    cloudflare_configure_origin_firewall
    apply_managed_ufw_tcp_ports "${desired_ports}"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

cloudflare_find_parent_zone() {
    local domain=$1 candidate zone
    candidate=${domain}
    while [[ "${candidate}" == *.* ]]; do
        # An empty result is expected while walking a hostname's suffixes;
        # it is not an API failure and must not abort the search.
        zone=$(cloudflare_api_request GET "/zones?name=${candidate}&status=active&per_page=50" | jq -r --arg name "${candidate}" '[.[] | select((.name|ascii_downcase)==$name) | .id] | if length == 1 then .[0] else empty end')
        if [[ -n "${zone}" ]]; then printf '%s' "${zone}"; return; fi
        candidate=${candidate#*.}
    done
    die "Cloudflare active Zone 未覆盖域名：${domain}"
}

cloudflare_record_list() { cloudflare_api_request GET "/zones/$1/dns_records?type=$2&name=$3&per_page=100"; }
cloudflare_require_single_record() {
    local records=$1 count
    count=$(jq 'length' <<<"${records}")
    ((count <= 1)) || die "Cloudflare 中发现多个同名同类型 DNS 记录，拒绝猜测或覆盖"
}

# Only an existing, fully identical proxied A is reusable.  Every other A,
# AAAA or CNAME is a conflict: replacing it could expose a user's origin.
cloudflare_ensure_proxied_a() {
    local zone=$1 host=$2 ip=$3 records record id content proxied comment type payload
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
    cloudflare_api_request POST "/zones/${zone}/dns_records" \
        "$(jq -cn --arg name "${host}" --arg content "${ip}" '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"easy_all xhttp origin"}')" >/dev/null
}

cloudflare_validate_zones() {
    local zone
    CLOUDFLARE_ZONE_ID=$(cloudflare_find_parent_zone "${VLESS_CDN_DOMAIN}")
    CLOUDFLARE_CDN_ZONE_ID=${CLOUDFLARE_ZONE_ID}
    CLOUDFLARE_SUBSCRIPTION_ZONE_ID=$(cloudflare_find_parent_zone "$(active_subscription_link_domain)")
    [[ "${CLOUDFLARE_ZONE_ID}" == "${CLOUDFLARE_SUBSCRIPTION_ZONE_ID}" ]] || die "订阅域名必须在同一个 Cloudflare Zone"
    zone=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}")
    CLOUDFLARE_ZONE_NAME=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    [[ -n "${CLOUDFLARE_ZONE_NAME}" ]] || die "Cloudflare Zone 未返回有效名称"
    cloudflare_validate_universal_hostname "${VLESS_CDN_DOMAIN}"
    cloudflare_validate_universal_hostname "$(active_subscription_link_domain)"
}

cloudflare_validate_universal_hostname() {
    local host=$1 prefix
    [[ "${host}" == *."${CLOUDFLARE_ZONE_NAME}" ]] \
        || die "${host} 不属于 Cloudflare Zone ${CLOUDFLARE_ZONE_NAME}"
    prefix=${host%.${CLOUDFLARE_ZONE_NAME}}
    [[ -n "${prefix}" && "${prefix}" != *.* ]] \
        || die "Cloudflare 模式首版只支持 Zone 下的一级子域名：${host}"
}

cloudflare_prepare_origin() {
    local ip
    cloudflare_collect_api_token
    cloudflare_validate_zones
    ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测 VPS 公网 IPv4"
    validate_ipv4 "${ip}" || die "VPS 公网 IPv4 无效：${ip}"
    VPS_PUBLIC_IPV4=${ip}
    cloudflare_ensure_proxied_a "${CLOUDFLARE_ZONE_ID}" "${VLESS_CDN_DOMAIN}" "${ip}"
    if subscription_enabled && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then
        cloudflare_ensure_proxied_a "${CLOUDFLARE_ZONE_ID}" "$(active_subscription_link_domain)" "${ip}"
    fi
    # A proxied record correctly resolves to Cloudflare anycast addresses, so
    # The shared DNS propagation check is inapplicable to proxied Cloudflare DNS.
    # Public end-to-end verification is performed after TLS/rules are deployed.
    CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
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
    jq -cn --arg cdn "${VLESS_CDN_DOMAIN}" \
        --arg sub "$(active_subscription_link_domain)" '[$cdn,$sub] | unique'
}

cloudflare_issue_origin_certificate() {
    local force=${1:-0} key csr result cert expires hosts san old_id
    cloudflare_ensure_origin_ca_root
    if [[ "${force}" != "1" ]] && cloudflare_origin_certificate_is_current; then
        return 0
    fi
    cloudflare_collect_api_token
    old_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    install -d -m 0700 "${CERT_DIR}"
    key="${RUNTIME_TMP}/cloudflare-origin-ecc.key"
    csr="${RUNTIME_TMP}/cloudflare-origin.csr"
    openssl ecparam -name prime256v1 -genkey -noout -out "${key}"
    chmod 0600 "${key}"
    hosts=$(jq -cn --arg origin "${CLOUDFLARE_ORIGIN_DOMAIN}" --arg cdn "${VLESS_CDN_DOMAIN}" --arg sub "$(active_subscription_link_domain)" '[$origin,$cdn,$sub] | unique')
    san=$(jq -r 'map("DNS:" + .) | join(",")' <<<"${hosts}")
    openssl req -new -sha256 -key "${key}" -subj "/CN=${CLOUDFLARE_ORIGIN_DOMAIN}" \
        -addext "subjectAltName=${san}" -out "${csr}"
    result=$(cloudflare_api_request POST '/certificates' "$(jq -cn --arg csr "$(<"${csr}")" --argjson hosts "${hosts}" --argjson validity "${CLOUDFLARE_ORIGIN_VALIDITY_DAYS}" '{hostnames:$hosts,requested_validity:$validity,request_type:"origin-ecc",csr:$csr}')")
    cert=$(jq -r '.certificate // empty' <<<"${result}"); CLOUDFLARE_ORIGIN_CERT_ID=$(jq -r '.id // empty' <<<"${result}"); expires=$(jq -r '.expires_on // empty' <<<"${result}")
    [[ -n "${cert}" && -n "${CLOUDFLARE_ORIGIN_CERT_ID}" && -n "${expires}" ]] || die "Cloudflare 未返回 Origin CA 证书、ID 或到期时间"
    printf '%s\n' "${cert}" >"${RUNTIME_TMP}/origin.pem"
    openssl verify -CAfile "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" \
        "${RUNTIME_TMP}/origin.pem" >/dev/null \
        || die "Cloudflare Origin CA 证书链验证失败"
    install -m 0600 "${RUNTIME_TMP}/origin.pem" "${CERT_FILE}"
    install -m 0600 "${key}" "${KEY_FILE}"
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=${expires}
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=${old_id}
}

xhttp_validate_local_tls_curl_args() {
    cloudflare_ensure_origin_ca_root
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https' --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}")
}
xhttp_renew_origin_certificate() {
    local old_id
    cloudflare_collect_api_token
    old_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    cloudflare_issue_origin_certificate 1
    nginx -t >/dev/null || die "Cloudflare 新源站证书安装后 Nginx 配置校验失败"
    systemctl reload nginx || systemctl restart nginx \
        || die "Cloudflare 新源站证书已安装，但 Nginx 重载失败"
    validate_protocol_runtime
    save_state
    if [[ -n "${old_id}" && "${old_id}" != "${CLOUDFLARE_ORIGIN_CERT_ID}" ]]; then
        if ! (cloudflare_api_request DELETE "/certificates/${old_id}" >/dev/null); then
            warn "新证书已生效，但撤销旧 Cloudflare Origin CA 证书失败：${old_id}"
        fi
    fi
    cloudflare_clear_api_token
    success "Cloudflare Origin CA 源站证书已轮换"
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

cloudflare_ref() { printf 'easy_all_%s' "$(printf '%s' "$1" | sha256sum | cut -c1-24)"; }
cloudflare_managed_ruleset() {
    local name=$1 phase=$2 listed matches count id
    listed=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets")
    matches=$(jq -c --arg phase "${phase}" \
        '[.[] | select(.kind=="zone" and .phase==$phase)]' <<<"${listed}")
    count=$(jq length <<<"${matches}")
    ((count <= 1)) \
        || die "Cloudflare phase ${phase} 存在多个 zone ruleset，拒绝猜测"
    if ((count == 1)); then jq -r '.[0].id' <<<"${matches}"; return; fi
    id=$(cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets" "$(jq -cn --arg name "${name}" --arg phase "${phase}" '{name:$name,kind:"zone",phase:$phase,rules:[]}')" | jq -r '.id // empty')
    [[ -n "${id}" ]] || die "Cloudflare 未返回 ruleset ID"; printf '%s' "${id}"
}

# Update a rule only by our stable ref in a ruleset owned by easy_all.  We
# never PUT an entrypoint ruleset, which would replace unrelated user rules.
cloudflare_upsert_rule() {
    local ruleset=$1 ref=$2 payload=$3 rules matches count id
    rules=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    matches=$(jq -c --arg ref "${ref}" '[.rules[]? | select(.ref==$ref)]' <<<"${rules}"); count=$(jq length <<<"${matches}")
    ((count <= 1)) || die "Cloudflare ruleset 中有多个 easy_all ref ${ref}，拒绝覆盖"
    if ((count == 1)); then id=$(jq -r '.[0].id' <<<"${matches}"); cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${id}" "${payload}" >/dev/null
    else cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules" "${payload}" >/dev/null; fi
}

cloudflare_add_header_rule() {
    local ruleset=$1 host=$2 path=$3 ws_path=${4:-} ref
    ref=$(cloudflare_ref "header:${host}:${path}")
    local expr
    if [[ -n "${ws_path}" ]]; then
        expr="http.host eq \"${host}\" and (starts_with(http.request.uri.path, \"${path}\") or starts_with(http.request.uri.path, \"${ws_path}\") or starts_with(http.request.uri.path, \"/easy_all-health\") or starts_with(http.request.uri.path, \"/subscribe\"))"
    else
        expr="http.host eq \"${host}\" and (starts_with(http.request.uri.path, \"${path}\") or starts_with(http.request.uri.path, \"/easy_all-health\") or starts_with(http.request.uri.path, \"/subscribe\"))"
    fi
    # Health, subscription and dual-link transports are protected by the same origin header.
    cloudflare_upsert_rule "${ruleset}" "${ref}" "$(jq -cn --arg ref "${ref}" --arg host "${host}" --arg path "${path}" --arg expr "${expr}" --arg key "${ORIGIN_HEADER_SECRET}" '{ref:$ref,description:("easy_all origin header for "+$path),expression:$expr,action:"rewrite",action_parameters:{headers:{"X-Easy-All-Origin-Key":{operation:"set",value:$key}}}}')"
}

cloudflare_configure_rules() {
    local host transform strict ref
    host=${VLESS_CDN_DOMAIN}
    transform=$(cloudflare_managed_ruleset "easy_all xhttp headers ${host}" "http_request_late_transform")
    cloudflare_add_header_rule "${transform}" "${host}" "${XHTTP_PATH}" "${WEBSOCKET_PATH:-}"
    if subscription_enabled \
        && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then
        cloudflare_add_header_rule "${transform}" \
            "$(active_subscription_link_domain)" "/subscribe" ""
    fi
    # Host-scoped strict TLS/configuration rule; it is kept in a separate
    # easy_all-owned ruleset so no customer configuration rule is overwritten.
    strict=$(cloudflare_managed_ruleset "easy_all xhttp strict ${host}" "http_config_settings")
    while IFS= read -r host; do
        ref=$(cloudflare_ref "strict:${host}")
        cloudflare_upsert_rule "${strict}" "${ref}" "$(jq -cn --arg ref "${ref}" --arg host "${host}" '{ref:$ref,description:"easy_all xhttp strict origin TLS",expression:("http.host eq \""+$host+"\""),action:"set_config",action_parameters:{ssl:"strict",security_level:"essentially_off",bic:false}}')"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')
    CLOUDFLARE_HEADER_RULESET_ID=${transform}; CLOUDFLARE_STRICT_RULESET_ID=${strict}
}

cloudflare_delete_managed_rule() {
    local ruleset=$1 ref=$2 rules matches count id
    [[ -n "${ruleset}" ]] || return 0
    if ! rules=$(cloudflare_api_request GET \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}"); then
        warn "读取 Cloudflare ruleset 失败，保留旧规则 ${ref}"
        return 0
    fi
    matches=$(jq -c --arg ref "${ref}" \
        '[.rules[]? | select(.ref==$ref)]' <<<"${rules}")
    count=$(jq length <<<"${matches}")
    if ((count > 1)); then
        warn "Cloudflare ruleset 中存在多个旧 easy_all ref ${ref}，拒绝删除"
        return 0
    fi
    ((count == 1)) || return 0
    id=$(jq -r '.[0].id' <<<"${matches}")
    if ! (cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${id}" >/dev/null); then
        warn "删除旧 Cloudflare 规则失败：${ref}"
    fi
}

cloudflare_cleanup_previous_subscription_host() {
    local old_host=$1 current_host records count id comment
    [[ -n "${old_host}" && "${old_host}" != "${VLESS_CDN_DOMAIN}" ]] || return 0
    current_host=$(active_subscription_link_domain)
    [[ "${old_host}" != "${current_host}" ]] || return 0

    cloudflare_delete_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
        "$(cloudflare_ref "header:${old_host}:/subscribe")"
    cloudflare_delete_managed_rule "${CLOUDFLARE_STRICT_RULESET_ID:-}" \
        "$(cloudflare_ref "strict:${old_host}")"

    if ! records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${old_host}"); then
        warn "读取旧 Cloudflare 订阅 DNS 失败，保留 ${old_host}"
        return 0
    fi
    count=$(jq length <<<"${records}")
    ((count == 1)) || {
        ((count == 0)) || warn "旧订阅域名 ${old_host} 有多个 A 记录，拒绝删除"
        return 0
    }
    id=$(jq -r '.[0].id // empty' <<<"${records}")
    comment=$(jq -r '.[0].comment // empty' <<<"${records}")
    [[ -n "${id}" && "${comment}" == "easy_all xhttp origin" ]] || {
        warn "旧订阅域名 ${old_host} 不是 easy_all 标记的 DNS 记录，予以保留"
        return 0
    }
    if ! (cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null); then
        warn "删除旧 Cloudflare 订阅 DNS 失败：${old_host}"
    fi
}

cloudflare_configure_cdn() {
    cloudflare_configure_rules
    # Orange-cloud DNS is Cloudflare's CDN attachment.  HTTP/2 to origin is
    # controlled by the zone setting.  Cloudflare's current public API does
    # not expose the Network → gRPC toggle, so that one is called out below.
    # Keep these payloads valid JSON.  Cloudflare rejects the shell-style
    # `{value:"..."}` form with HTTP 400 because JSON object keys must be
    # quoted.  jq also makes the intended string values explicit.
    cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/settings/origin_max_http_version" \
        "$(jq -cn '{value:"2"}')" >/dev/null
    warn "请在 Cloudflare 控制台的 Network → gRPC 中手动开启 gRPC；该开关当前没有可用的 Zone Settings API"
}

cloudflare_validate_cdn_health() {
    cloudflare_wait_for_health "${VLESS_CDN_DOMAIN}" "CDN"
    cloudflare_validate_grpc_edge "${VLESS_CDN_DOMAIN}"
    if subscription_enabled && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then cloudflare_wait_for_health "$(active_subscription_link_domain)" "订阅"; fi
}

cloudflare_validate_grpc_edge() {
    local domain=$1 body_file metadata curl_status http_code content_type
    body_file=$(mktemp "${RUNTIME_TMP}/cloudflare-grpc-check.XXXXXX")
    if metadata=$(curl -sS --http2 --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 15 --noproxy '*' \
        -X POST -H 'Content-Type: application/grpc' -H 'TE: trailers' \
        --data-binary '' -o "${body_file}" \
        -w $'%{http_code}\t%{content_type}' \
        "https://${domain}/easy_all-health" 2>/dev/null); then
        curl_status=0
    else
        curl_status=$?
    fi
    rm -f -- "${body_file}"
    IFS=$'\t' read -r http_code content_type <<<"${metadata}"

    ((curl_status == 0)) \
        || die "Cloudflare gRPC 边缘验收失败：无法连接 ${domain}"
    if [[ "${http_code}" == "403" && "${content_type}" == text/html* ]]; then
        die "Cloudflare Zone 尚未开启 gRPC；请在控制台 Network → gRPC 开启后重试"
    fi
    [[ "${http_code}" == "200" ]] \
        || die "Cloudflare gRPC 边缘验收失败：HTTP ${http_code:-未知}"
    success "Cloudflare gRPC 边缘验收通过"
}

cloudflare_wait_for_health() {
    local domain=$1 label=$2 attempt response
    for attempt in {1..60}; do
        response=$(curl -fsS --connect-timeout 5 --max-time 15 "https://${domain}/easy_all-health" 2>/dev/null || true)
        [[ "${response}" == "easy_all ok" ]] && { success "Cloudflare ${label} 公共健康验收通过"; return; }
        sleep 5
    done
    die "Cloudflare ${label} ${domain} 公共健康验收失败；请检查 DNS、Origin CA、Strict TLS 和规则"
}

collect_install_inputs() {
    PROTOCOL=xhttp; CDN_PROVIDER=cloudflare; choose_cdn_client_ip_family
    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}; VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}; validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"
    info "Cloudflare 模式采用单域名架构：此域名同时用于客户端连接、Cloudflare 回源和 VPS 证书。"
    VLESS_CDN_DOMAIN=$(normalize_domain "${VLESS_CDN_DOMAIN:-$(prompt_value "客户端连接的 CDN 节点域名" "" "CDN hostname used by clients")}"); validate_domain "${VLESS_CDN_DOMAIN}" || die "VLESS_CDN_DOMAIN 无效"
    CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    info "Cloudflare 模式从官方 IPv4 CIDR 轮换抽样，并使用三网 Globalping eyeball 探针预筛。"; collect_globalping_token; validate_globalping_access || die "Globalping Token 验证失败"
    XHTTP_PATH=${XHTTP_PATH:-$(generate_xhttp_path)}; XHTTP_PATH="/xhttp-${XHTTP_PATH#/vless-}"; validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效"
    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}; validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "XHTTP 本机端口无效"
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-/ws-$(openssl rand -hex 12)}
    [[ "${WEBSOCKET_PATH}" =~ ^/[A-Za-z0-9._~/-]{3,128}$ ]] || die "WEBSOCKET_PATH 无效"
    XRAY_WEBSOCKET_LOOPBACK_PORT=${XRAY_WEBSOCKET_LOOPBACK_PORT:-${DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" || die "WebSocket 本机端口无效"
    [[ "${XRAY_WEBSOCKET_LOOPBACK_PORT}" != "${XRAY_XHTTP_LOOPBACK_PORT}" ]] || die "XHTTP 与 WebSocket 本机端口不能冲突"
    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "Origin header 密钥无效"
    choose_subscription_mode; if subscription_enabled; then collect_subscription_link_domain; choose_subscription_download_name; choose_monthly_quota 1; quota_enabled || ensure_allowed_tokens; else SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}; SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}"); ALLOWED_TOKENS=""; choose_monthly_quota 0; fi
}

load_state() {
    local v e; local -a vars=(PROTOCOL CDN_PROVIDER CDN_CLIENT_IP_FAMILY XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN XHTTP_PATH CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID XRAY_XHTTP_LOOPBACK_PORT XRAY_WEBSOCKET_LOOPBACK_PORT WEBSOCKET_PATH ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR)
    for v in "${vars[@]}"; do e="EASY_ALL_ENV_${v}"; printf -v "${e}" %s "${!v:-}"; printf -v "${v}" %s ""; done; source_state_file; for v in "${vars[@]}"; do e="EASY_ALL_ENV_${v}"; [[ -z "${!e:-}" ]] || printf -v "${v}" %s "${!e}"; unset "${e}"; done
    [[ "${PROTOCOL}" == xhttp && "${CDN_PROVIDER:-}" == cloudflare ]] || die "状态不是 Cloudflare CDN XHTTP"; configure_cdn_client_ip_family
    validate_domain "${CLOUDFLARE_ORIGIN_DOMAIN:-}" && validate_domain "${VLESS_CDN_DOMAIN:-}" && validate_uuid "${VLESS_UUID:-}" && validate_xhttp_path "${XHTTP_PATH:-}" && validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT:-}" || die "Cloudflare 状态缺少必要有效字段"
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-/ws-$(openssl rand -hex 12)}
    [[ "${WEBSOCKET_PATH}" =~ ^/[A-Za-z0-9._~/-]{3,128}$ ]] || die "状态中的 WEBSOCKET_PATH 无效"
    XRAY_WEBSOCKET_LOOPBACK_PORT=${XRAY_WEBSOCKET_LOOPBACK_PORT:-${DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" || die "状态中的 WebSocket 本机端口无效"
    [[ "${XRAY_WEBSOCKET_LOOPBACK_PORT}" != "${XRAY_XHTTP_LOOPBACK_PORT}" ]] || die "XHTTP 与 WebSocket 本机端口不能冲突"
    [[ "${CLOUDFLARE_ORIGIN_DOMAIN}" == "${VLESS_CDN_DOMAIN}" ]] \
        || die "Cloudflare 状态不是单一 Proxied 源站域名架构"
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${CLOUDFLARE_ZONE_NAME:-}" \
        && -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
        && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" ]] \
        || die "状态缺少 Cloudflare Zone 或 Origin CA 资源"
    [[ "${ORIGIN_HEADER_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "状态中的源站密钥无效"; XHTTP_ORIGIN_DOMAIN=${CLOUDFLARE_ORIGIN_DOMAIN}
    SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN:-}"); validate_domain "${SUBSCRIPTION_DOMAIN}" || die "订阅域名状态无效"; SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-}") || die "订阅模式状态无效"; SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-}") || die "订阅文件名状态无效"
    [[ -z "${ALLOWED_TOKENS:-}" ]] \
        || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
        || die "状态中的订阅 Token 无效"
    [[ "${QUOTA_ENABLED:-}" == "0" || "${QUOTA_ENABLED:-}" == "1" ]] \
        || die "状态缺少有效的 QUOTA_ENABLED"
    if quota_enabled; then
        validate_user_accounts "${USER_ACCOUNTS:-}" || die "状态中的配额用户无效"
        validate_quota_start_date "${QUOTA_START_DATE:-}" || die "状态中的配额账期无效"
    else
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
    fi
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"; local t; t=$(mktemp "${STATE_DIR}/state.env.XXXXXX"); cleanup_files+=("${t}")
    { for v in STATE_VERSION PROTOCOL CDN_PROVIDER CDN_CLIENT_IP_FAMILY XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN XHTTP_PATH CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID XRAY_XHTTP_LOOPBACK_PORT XRAY_WEBSOCKET_LOOPBACK_PORT WEBSOCKET_PATH ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR; do case "${v}" in STATE_VERSION) printf '%s=%q\n' "${v}" "${STATE_SCHEMA_VERSION}";; PROTOCOL) printf '%s=%q\n' "${v}" xhttp;; CDN_PROVIDER) printf '%s=%q\n' "${v}" cloudflare;; SUBSCRIPTION_DOMAIN) printf '%s=%q\n' "${v}" "$(subscription_link_domain)";; *) printf '%s=%q\n' "${v}" "${!v:-}";; esac; done; } >"${t}"; install -m 0600 "${t}" "${STATE_FILE}"
}
collect_installed_state() { [[ -f "${STATE_FILE}" ]] || die "easy_all Cloudflare CDN XHTTP 尚未安装"; load_state; }

xhttp_render_xray_config() {
    local clients outbounds routing sockopt stats=false
    install -d -m 0755 "${XRAY_DIR}"
    if quota_enabled; then
        clients=$(quota_active_clients_json)
        stats=true
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" '[{id:$id,email:$email}]')
    fi
    outbounds=$(xray_xhttp_outbounds_json)
    routing=$(xray_xhttp_routing_json)
    sockopt=$(xray_inbound_sockopt_json)
    jq -n --argjson port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson websocket_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" \
        --argjson clients "${clients}" \
        --argjson stats "${stats}" \
        --arg host "${VLESS_CDN_DOMAIN}" \
        --arg path "${XHTTP_PATH}" \
        --arg websocket_path "${WEBSOCKET_PATH}" \
        --arg secs "${CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS}" \
        --arg padding "${CLOUDFLARE_XHTTP_PADDING_BYTES}" \
        --argjson sockopt "${sockopt}" \
        --argjson outbounds "${outbounds}" \
        --argjson routing "${routing}" '
        {
          log: {loglevel: "warning"},
          inbounds: [
            {
              tag: "vless-xhttp-h2-in",
              listen: "127.0.0.1",
              port: $port,
              protocol: "vless",
              settings: {clients: $clients, decryption: "none"},
              streamSettings: {
                network: "xhttp",
                sockopt: $sockopt,
                xhttpSettings: {
                  host: $host,
                  path: $path,
                  mode: "stream-up",
                  xPaddingBytes: $padding,
                  scStreamUpServerSecs: $secs
                }
              },
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            },
            {
              tag: "vless-websocket-in",
              listen: "127.0.0.1",
              port: $websocket_port,
              protocol: "vless",
              settings: {clients: $clients, decryption: "none"},
              streamSettings: {
                network: "ws",
                sockopt: $sockopt,
                wsSettings: {path: $websocket_path}
              },
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            }
          ],
          outbounds: $outbounds,
          routing: $routing
        } + (if $stats then {api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]},stats:{},policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}}} else {} end)' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS XHTTP stream-up + WebSocket over Cloudflare CDN\n节点链接:\n%s\n\n' "$(build_node_links)"
    build_mihomo_nodes
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    local fallback_desc="disabled (三网独立精选 IP)"
    if ! globalping_cache_valid; then
        fallback_desc="enabled (仅当测量缓存未就绪时回退 CDN 域名)"
    fi
    printf '协议: xhttp + websocket（Cloudflare CDN 双链路）\n客户端 CDN 节点域名: %s\nCloudflare 回源域名: %s（单域名架构）\nOrigin CA: %s（到期 %s）\n候选来源: Cloudflare 官方 IPv4 CIDR / 三网 Globalping eyeball 探针\n域名兜底: %s\n' "${VLESS_CDN_DOMAIN}" "${CLOUDFLARE_ORIGIN_DOMAIN}" "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}" "${fallback_desc}"
    show_globalping_status
}

refresh_cloudflare_cdn_ips() {
    local refresh_status=0
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    install_globalping_refresh_timer
    snapshot_subscription_update
    configure_ufw
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"
    persist_globalping_token
    cloudflare_validate_grpc_edge "${VLESS_CDN_DOMAIN}"
    if ! refresh_globalping_cache; then
        refresh_status=1
        warn "Globalping 刷新失败，保留有效缓存或回退域名"
    fi
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi
    save_state
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    release_runtime_write_lock
    ((refresh_status == 0)) || return 1
    success "Cloudflare CDN 精选 IP 已刷新"
}

update_subscription() {
    local previous_subscription_host=""
    require_root
    begin_quota_maintenance
    collect_installed_state
    if subscription_enabled; then
        previous_subscription_host=$(active_subscription_link_domain)
    fi
    snapshot_subscription_update
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
    fi
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn
    finish_xhttp_apply 1
    cloudflare_validate_cdn_health
    cloudflare_cleanup_previous_subscription_host "${previous_subscription_host}"
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
    success "Cloudflare 订阅、Origin CA 与回源规则已更新"
}
apply_easy_all() { require_root; begin_quota_maintenance; collect_installed_state; snapshot_subscription_update; configure_bbr_tcp; configure_ufw; finish_xhttp_apply; install_globalping_refresh_timer; success "Cloudflare 本机配置已应用；未修改 Cloudflare 资源"; }
apply_cloud_resources() { require_root; begin_quota_maintenance; collect_installed_state; snapshot_subscription_update; configure_bbr_tcp; configure_ufw; cloudflare_prepare_origin; cloudflare_issue_origin_certificate 0; cloudflare_configure_cdn; finish_xhttp_apply 1; cloudflare_validate_cdn_health; cloudflare_finalize_certificate_rotation; install_globalping_refresh_timer; cloudflare_clear_api_token; success "Cloudflare DNS、Origin CA、规则和本机配置已应用"; }

rollback_fresh_install() { stop_services; remove_quota_timer; remove_globalping_refresh_timer; cloudflare_remove_origin_firewall_rules; restore_preinstall_firewall; rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"; systemctl daemon-reload >/dev/null 2>&1 || true; rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"; cloudflare_clear_api_token; }

cloudflare_purge_managed_rule() {
    local ruleset=$1 ref=$2 rules matches count id
    rules=$(cloudflare_api_request GET \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    matches=$(jq -c --arg ref "${ref}" \
        '[.rules[]? | select(.ref==$ref)]' <<<"${rules}")
    count=$(jq length <<<"${matches}")
    ((count <= 1)) \
        || die "Cloudflare ruleset 中有多个 easy_all ref ${ref}，已停止卸载以避免误删"
    ((count == 1)) || return 0
    id=$(jq -r '.[0].id // empty' <<<"${matches}")
    [[ -n "${id}" ]] || die "Cloudflare easy_all 规则缺少 ID：${ref}"
    cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${id}" \
        >/dev/null
}

cloudflare_purge_empty_owned_ruleset() {
    local ruleset=$1 expected_name=$2 expected_phase=$3 current
    current=$(cloudflare_api_request GET \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    if jq -e --arg name "${expected_name}" --arg phase "${expected_phase}" '
        .name == $name and .kind == "zone" and .phase == $phase
        and ((.rules // []) | length) == 0
    ' <<<"${current}" >/dev/null; then
        cloudflare_api_request DELETE \
            "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}" >/dev/null
    fi
}

cloudflare_purge_managed_dns_record() {
    local host=$1 records count id comment
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${host}")
    count=$(jq length <<<"${records}")
    ((count <= 1)) \
        || die "Cloudflare 域名 ${host} 有多个 A 记录，已停止卸载以避免误删"
    ((count == 1)) || return 0
    id=$(jq -r '.[0].id // empty' <<<"${records}")
    comment=$(jq -r '.[0].comment // empty' <<<"${records}")
    if [[ -z "${id}" || "${comment}" != "easy_all xhttp origin" ]]; then
        info "Cloudflare DNS ${host} 不是 easy_all 标记的记录，予以保留"
        return 0
    fi
    cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null
}

purge_cloudflare_resources_before_uninstall() {
    local host header_name strict_name
    [[ "${UNINSTALL_PURGE_CLOUD:-0}" == "1" ]] || return 0
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
        && -n "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
        && -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
        || die "状态缺少 Cloudflare 证书或 ruleset ID，已停止卸载；本机状态仍保留"
    cloudflare_collect_api_token

    cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID}" \
        "$(cloudflare_ref "header:${VLESS_CDN_DOMAIN}:${XHTTP_PATH}")"
    if subscription_enabled \
        && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then
        cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID}" \
            "$(cloudflare_ref "header:$(active_subscription_link_domain):/subscribe")"
    fi
    while IFS= read -r host; do
        cloudflare_purge_managed_rule "${CLOUDFLARE_STRICT_RULESET_ID}" \
            "$(cloudflare_ref "strict:${host}")"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')

    header_name="easy_all xhttp headers ${VLESS_CDN_DOMAIN}"
    strict_name="easy_all xhttp strict ${VLESS_CDN_DOMAIN}"
    cloudflare_purge_empty_owned_ruleset "${CLOUDFLARE_HEADER_RULESET_ID}" \
        "${header_name}" "http_request_late_transform"
    cloudflare_purge_empty_owned_ruleset "${CLOUDFLARE_STRICT_RULESET_ID}" \
        "${strict_name}" "http_config_settings"

    while IFS= read -r host; do
        cloudflare_purge_managed_dns_record "${host}"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')

    cloudflare_api_request DELETE "/certificates/${CLOUDFLARE_ORIGIN_CERT_ID}" >/dev/null \
        || die "Cloudflare Origin CA 吊销失败，已停止卸载；本机状态仍保留"
    cloudflare_clear_api_token
    success "easy_all 托管的 Cloudflare DNS、规则、ruleset 与 Origin CA 证书已清理"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] \
        || die "easy_all Cloudflare CDN XHTTP 尚未安装"
    if [[ "${mode}" == "--purge-cloud" && ! -f "${STATE_FILE}" ]]; then
        die "缺少状态文件，无法安全识别 easy_all 托管的 Cloudflare 资源；本机内容未删除"
    fi
    [[ ! -f "${STATE_FILE}" ]] || load_state
    [[ "${FORCE:-0}" == 1 || -t 0 ]] \
        || die "非交互卸载必须设置 FORCE=1"
    UNINSTALL_PURGE_CLOUD=0
    [[ "${mode}" == "--purge-cloud" ]] && UNINSTALL_PURGE_CLOUD=1
    if [[ "${FORCE:-0}" != 1 ]]; then
        if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
            read_bilingual \
                '删除本机内容以及 easy_all 托管的 Cloudflare DNS、规则和 Origin CA 证书？[y/N]:' \
                'Delete local content and easy_all-managed Cloudflare DNS, rules, and Origin CA certificate? [y/N]:' answer
        else
            read_bilingual \
                '删除本机内容（Cloudflare 资源保留）？[y/N]:' \
                'Delete local content (Cloudflare resources are kept)? [y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    purge_cloudflare_resources_before_uninstall
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
        success "本机内容及 easy_all 托管的 Cloudflare 远端资源已卸载"
    else
        success "本机内容已卸载；远端 Cloudflare 资源已保留"
    fi
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"; CDN_PROVIDER=cloudflare; require_root; require_systemd; [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装"; check_platform; check_install_conflicts; snapshot_fresh_install
    install_packages; ensure_ssh_boot_service; configure_bbr_tcp; configure_daily_reboot; collect_install_inputs; cloudflare_prepare_origin; configure_ufw; write_bootstrap_nginx_config; cloudflare_issue_origin_certificate 0; download_xray; write_xray_config; install_xray_service; write_nginx_config; validate_protocol_runtime; cloudflare_configure_cdn; cloudflare_validate_cdn_health; cloudflare_finalize_certificate_rotation; persist_globalping_token; refresh_globalping_cache || warn "首次 Globalping 测量失败，暂回退 CDN 域名"; subscription_enabled && { write_subscriptions; validate_subscription_runtime; }; save_state; register_easy_all_command; install_quota_timer; install_globalping_refresh_timer; INSTALL_ROLLBACK_ON_EXIT=0; cloudflare_clear_api_token; show_subscription; success "easy_all Cloudflare CDN XHTTP 安装完成"
}
usage() { printf 'Cloudflare Profile 只能由 easy_all 统一入口调用。\n'; }
