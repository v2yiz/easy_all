#!/usr/bin/env bash

# Gcore CDN XHTTP profile.
#
# This Profile is intentionally loaded only by easy_all's third installation
# choice.  It reuses the XHTTP runtime (Xray, Nginx, subscriptions and quotas)
# and owns only the Gcore DNS/CDN adapter and its state.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'xhttp_gcore.sh 是 easy_all 的 Gcore CDN Profile；请使用：easy_all install\n' >&2
    exit 2
fi

readonly XHTTP_GCORE_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly XHTTP_PROFILE_ROOT="${XHTTP_GCORE_PROFILE_ROOT}/lib"
readonly XHTTP_PROFILE_FILE="${XHTTP_GCORE_PROFILE_ROOT}/xhttp_gcore.sh"
XHTTP_CDN_NAME_OVERRIDE="Gcore CDN"
XHTTP_ORIGIN_DNS_NAME_OVERRIDE="Gcore Managed DNS"

readonly GCORE_API_BASE="https://api.gcore.com"
readonly GCORE_DNS_TTL="300"
readonly DEFAULT_GCORE_FEE_PROTECTION_GB="980"
readonly GCORE_XHTTP_STREAM_UP_SERVER_SECS="10-14"
# Gcore closes idle H2 connections after 15 seconds; ping before that limit.
readonly GCORE_XHTTP_H_KEEP_ALIVE_PERIOD="10"
XHTTP_XMUX_H_KEEP_ALIVE_PERIOD_OVERRIDE=${GCORE_XHTTP_H_KEEP_ALIVE_PERIOD}

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"

gcore_api_request() {
    local method=$1 path=$2 payload=${3:-}
    local -a retry_args=()
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    [[ "${method}" != "GET" ]] || retry_args=(--retry 3)
    if [[ -n "${payload}" ]]; then
        curl -fsS "${retry_args[@]}" --connect-timeout 10 --max-time 45 \
            -X "${method}" -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
            -H 'Content-Type: application/json' --data "${payload}" \
            "${GCORE_API_BASE}${path}"
    else
        curl -fsS "${retry_args[@]}" --connect-timeout 10 --max-time 45 \
            -X "${method}" -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
            "${GCORE_API_BASE}${path}"
    fi
}

# GET an object that may not exist.  Exit status 1 means only HTTP 404; any
# other response is fatal so we never mistake an authorization failure for an
# empty DNS record.
gcore_api_get_optional() {
    local path=$1 response status body
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    response=$(curl -sS --retry 3 --connect-timeout 10 --max-time 45 \
        -X GET -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
        -w $'\n%{http_code}' "${GCORE_API_BASE}${path}") \
        || die "请求 Gcore API 失败：GET ${path}"
    status=${response##*$'\n'}
    body=${response%$'\n'*}
    case "${status}" in
    200) printf '%s\n' "${body}" ;;
    404) return 1 ;;
    *)
        [[ -z "${body}" ]] || printf '%s\n' "${body}" >&2
        die "Gcore API 请求失败（HTTP ${status}）：GET ${path}"
        ;;
    esac
}

gcore_json_items() {
    jq -c '
        if type == "array" then .
        elif (.results? | type) == "array" then .results
        elif (.items? | type) == "array" then .items
        elif (.zones? | type) == "array" then .zones
        else [] end
    '
}

gcore_collect_api_token() {
    if [[ -z "${GCORE_API_TOKEN:-}" ]]; then
        GCORE_API_TOKEN=$(prompt_secret "Gcore API Token（输入不回显）" \
            "Gcore API Token (input is hidden)") \
            || die "非交互模式必须设置 GCORE_API_TOKEN"
    fi
    # Permanent API tokens may contain characters such as '$'.  Do not
    # over-validate their alphabet here; the API authentication check below is
    # authoritative, while whitespace is never a valid token value.
    [[ ${#GCORE_API_TOKEN} -ge 16 && ${#GCORE_API_TOKEN} -le 512 \
        && "${GCORE_API_TOKEN}" != *[[:space:]]* ]] \
        || die "GCORE_API_TOKEN 格式无效"
}

gcore_clear_api_token() {
    unset GCORE_API_TOKEN
}

gcore_find_zone_for_domain() {
    local domain=$1 zones
    zones=$(gcore_api_request GET '/dns/v2/zones?limit=1000')
    printf '%s' "${zones}" | gcore_json_items | jq -r --arg domain "${domain}" '
        map(.name | rtrimstr(".") | ascii_downcase)
        | map(select(. as $zone | ($domain == $zone or ($domain | endswith("." + $zone)))))
        | sort_by(length) | last // empty
    '
}

gcore_verify_zone_delegation() {
    local zone=$1 result authorized non_gcore exists
    result=$(gcore_api_request GET "/dns/v2/analyze/${zone}/delegation-status")
    authorized=$(jq -r '.gcore_authorized_count // 0' <<<"${result}")
    non_gcore=$(jq -r '.non_gcore_authorized_count // 0' <<<"${result}")
    exists=$(jq -r '.zone_exists // false' <<<"${result}")
    [[ "${exists}" == "true" && "${authorized}" =~ ^[0-9]+$ \
        && "${non_gcore}" =~ ^[0-9]+$ && ${authorized} -gt 0 && ${non_gcore} -eq 0 ]] \
        || die "Gcore 尚未成为 ${zone} 的唯一权威 DNS；请先完成 docs/gcore-guide.md 的整域名 NS 委派"
}

gcore_rrset_body() {
    local value=$1
    jq -cn --arg value "${value}" --argjson ttl "${GCORE_DNS_TTL}" \
        '{ttl:$ttl,resource_records:[{content:[$value]}]}'
}

gcore_require_dns_replace() {
    [[ "${GCORE_DNS_REPLACE:-0}" == "1" ]] \
        || die "$1 已有不属于 easy_all 的记录；为避免覆盖业务 DNS，拒绝修改。确认替换后重试并设置 GCORE_DNS_REPLACE=1"
}

gcore_upsert_rrset() {
    local zone=$1 name=$2 type=$3 value=$4 existing expected
    if existing=$(gcore_api_get_optional "/dns/v2/zones/${zone}/${name}/${type}"); then
        expected=$(jq -cn --arg value "${value}" '[$value]')
        if jq -e --argjson expected "${expected}" '
            [.resource_records[]?.content[]?] | unique | sort == ($expected | unique | sort)
        ' <<<"${existing}" >/dev/null; then
            return 0
        fi
        gcore_require_dns_replace "${name} ${type}"
    fi
    gcore_api_request PUT "/dns/v2/zones/${zone}/${name}/${type}" \
        "$(gcore_rrset_body "${value}")" >/dev/null
}

gcore_ensure_cname_record() {
    local type existing
    for type in A AAAA; do
        if existing=$(gcore_api_get_optional "/dns/v2/zones/${GCORE_DNS_ZONE}/${VLESS_CDN_DOMAIN}/${type}"); then
            gcore_require_dns_replace "${VLESS_CDN_DOMAIN} 与 CNAME 冲突的 ${type}"
            gcore_api_request DELETE \
                "/dns/v2/zones/${GCORE_DNS_ZONE}/${VLESS_CDN_DOMAIN}/${type}" >/dev/null
        fi
    done
    gcore_upsert_rrset "${GCORE_DNS_ZONE}" "${VLESS_CDN_DOMAIN}" CNAME \
        "${GCORE_CDN_TARGET}"
}

gcore_wait_for_origin_dns() {
    AWS_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}
    verify_origin_dns
}

gcore_wait_for_cdn_dns() {
    local attempt records resolver all_match
    info "等待 Gcore CDN CNAME 传播到公共 DNS"
    for attempt in {1..60}; do
        all_match=1
        for resolver in 1.1.1.1 8.8.8.8; do
            records=$(dig +short CNAME "${VLESS_CDN_DOMAIN}" @"${resolver}" 2>/dev/null \
                | sed 's/\.$//' | tr '[:upper:]' '[:lower:]' | sort -u || true)
            [[ "${records}" == "${GCORE_CDN_TARGET}" ]] || { all_match=0; break; }
        done
        [[ "${all_match}" == "1" ]] && return 0
        sleep 5
    done
    die "CDN 域名 ${VLESS_CDN_DOMAIN} 尚未解析到 Gcore 目标 ${GCORE_CDN_TARGET}"
}

gcore_origin_group_name() {
    printf 'easy-all-xhttp-%s' "${GCORE_ORIGIN_DOMAIN//./-}"
}

gcore_ensure_origin_group() {
    local groups matches count body name
    name=$(gcore_origin_group_name)
    body=$(jq -cn --arg name "${name}" --arg origin "${GCORE_ORIGIN_DOMAIN}:443" '
        {name:$name,use_next:false,
         sources:[{source:$origin,enabled:true,backup:false,host_header_override:($origin | sub(":443$";""))}]}
    ')
    if [[ -n "${GCORE_ORIGIN_GROUP_ID:-}" ]]; then
        gcore_api_request PATCH "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}" "${body}" >/dev/null
        return 0
    fi
    groups=$(gcore_api_request GET '/cdn/origin_groups?limit=1000')
    matches=$(printf '%s' "${groups}" | gcore_json_items | jq -c --arg name "${name}" \
        '[.[] | select(.name == $name)]')
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Gcore 中发现多个同名 easy_all 源组：${name}"
    if ((count == 1)); then
        GCORE_ORIGIN_GROUP_ID=$(jq -r '.[0].id' <<<"${matches}")
        gcore_api_request PATCH "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}" "${body}" >/dev/null
    else
        GCORE_ORIGIN_GROUP_ID=$(gcore_api_request POST '/cdn/origin_groups' "${body}" | jq -r '.id // empty')
        [[ "${GCORE_ORIGIN_GROUP_ID}" =~ ^[0-9]+$ ]] \
            || die "Gcore 未返回源组 ID"
    fi
}

gcore_resource_payload() {
    jq -cn --arg domain "${VLESS_CDN_DOMAIN}" --arg origin "${GCORE_ORIGIN_DOMAIN}" \
        --arg key "${ORIGIN_HEADER_SECRET}" --argjson origin_group "${GCORE_ORIGIN_GROUP_ID}" '
        {
          cname:$domain,
          name:("easy_all xhttp " + $domain),
          originGroup:$origin_group,
          originProtocol:"HTTPS",
          proxy_ssl_enabled:true,
          active:true,
          options:{
            allowedHttpMethods:{enabled:true,value:["GET","HEAD","POST"]},
            grpc_passthrough:{enabled:true,value:true},
            edge_cache_settings:{enabled:true,value:"0s",default:"0s",custom_values:{any:"0s"}},
            browser_cache_settings:{enabled:true,value:"0s"},
            ignoreQueryString:{enabled:true,value:false},
            hostHeader:{enabled:true,value:$origin},
            sni:{enabled:true,sni_type:"custom",custom_hostname:$origin},
            staticRequestHeaders:{enabled:true,value:{"X-Easy-All-Origin-Key":$key}},
            proxy_connect_timeout:{enabled:true,value:"5s"},
            proxy_read_timeout:{enabled:true,value:"30s"},
            redirect_http_to_https:{enabled:true,value:true}
          }
        }
    '
}

gcore_ensure_resource() {
    local resources matches count payload created
    payload=$(gcore_resource_payload)
    if [[ -n "${GCORE_CDN_RESOURCE_ID:-}" ]]; then
        gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null
        return 0
    fi
    resources=$(gcore_api_request GET '/cdn/resources?limit=1000')
    matches=$(printf '%s' "${resources}" | gcore_json_items | jq -c --arg domain "${VLESS_CDN_DOMAIN}" \
        '[.[] | select((.cname // "" | rtrimstr(".") | ascii_downcase) == $domain)]')
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Gcore 中发现多个使用 ${VLESS_CDN_DOMAIN} 的 CDN 资源"
    if ((count == 1)); then
        GCORE_CDN_RESOURCE_ID=$(jq -r '.[0].id' <<<"${matches}")
        gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null
    else
        created=$(gcore_api_request POST '/cdn/resources' "${payload}")
        GCORE_CDN_RESOURCE_ID=$(jq -r '.id // empty' <<<"${created}")
        [[ "${GCORE_CDN_RESOURCE_ID}" =~ ^[0-9]+$ ]] \
            || die "Gcore 未返回 CDN 资源 ID"
    fi
}

gcore_detect_cdn_target() {
    local resource target
    resource=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}")
    target=$(jq -r '
        [.cdn_domain?, .cdn_hostname?, .cname_target?, .delivery_domain?, .cname?]
        | map(select(type == "string" and endswith(".gcdn.co"))) | first // empty
    ' <<<"${resource}")
    # Gcore documents the assigned delivery target as <custom-domain>.gcdn.co.
    # Older API responses omit that derived field, so only then use the documented
    # deterministic target and verify it through public DNS before issuing TLS.
    GCORE_CDN_TARGET=${target:-${VLESS_CDN_DOMAIN}.gcdn.co}
    GCORE_CDN_TARGET=$(normalize_domain "${GCORE_CDN_TARGET}")
    validate_domain "${GCORE_CDN_TARGET}" && [[ "${GCORE_CDN_TARGET}" == *.gcdn.co ]] \
        || die "Gcore 返回的 CDN 目标无效：${GCORE_CDN_TARGET:-缺失}"
}

gcore_certificate_name() {
    printf 'easy-all-%s' "${VLESS_CDN_DOMAIN}"
}

gcore_ensure_edge_certificate() {
    local name certificates matches count attempt patch
    name=$(gcore_certificate_name)

    # Validate the resource after its CNAME is publicly visible, before asking
    # Let's Encrypt to issue a certificate.  This avoids an unusable issuance
    # request when DNS is not ready yet.
    gcore_api_request POST "/cdn/resources/${GCORE_CDN_RESOURCE_ID}/ssl/le/pre-validate" >/dev/null \
        || die "Gcore Let's Encrypt 预检查失败；请确认 ${VLESS_CDN_DOMAIN} 的 CNAME 已生效"

    certificates=$(gcore_api_request GET '/cdn/sslData?limit=1000')
    matches=$(printf '%s' "${certificates}" | gcore_json_items | jq -c --arg name "${name}" \
        '[.[] | select(.name == $name)]')
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Gcore 中发现多个同名 easy_all 证书：${name}"
    if ((count == 1)); then
        GCORE_SSL_CERT_ID=$(jq -r '.[0].id' <<<"${matches}")
    else
        gcore_api_request POST '/cdn/sslData' \
            "$(jq -cn --arg name "${name}" '{automated:true,name:$name}')" >/dev/null
        for attempt in {1..12}; do
            certificates=$(gcore_api_request GET '/cdn/sslData?limit=1000')
            GCORE_SSL_CERT_ID=$(printf '%s' "${certificates}" | gcore_json_items | jq -r --arg name "${name}" '
                [.[] | select(.name == $name)] | if length == 1 then .[0].id else empty end
            ')
            [[ "${GCORE_SSL_CERT_ID}" =~ ^[0-9]+$ ]] && break
            sleep 5
        done
        [[ "${GCORE_SSL_CERT_ID:-}" =~ ^[0-9]+$ ]] \
            || die "等待 Gcore Let's Encrypt 证书创建超时"
    fi
    gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
        "$(jq -cn --argjson cert "${GCORE_SSL_CERT_ID}" '{sslEnabled:true,sslData:$cert}')" >/dev/null
}

gcore_wait_for_cdn_health() {
    local attempt status response
    info "等待 Gcore CDN 与 Let's Encrypt 证书部署（最多约 15 分钟）"
    for attempt in {1..90}; do
        status=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" | jq -r '.status // empty')
        response=$(curl -fsS --connect-timeout 5 --max-time 15 \
            "https://${VLESS_CDN_DOMAIN}/easy_all-health" 2>/dev/null || true)
        [[ "${status}" == "active" && "${response}" == "easy_all ok" ]] \
            && { success "Gcore CDN 回源与边缘证书验收通过"; return 0; }
        sleep 10
    done
    die "Gcore CDN 公网验收失败；请检查 CNAME、源站证书、Origin Key、Gcore CDN 资源和 Let's Encrypt 状态"
}

gcore_prepare_origin() {
    local public_ip
    gcore_collect_api_token
    # Both reads are deliberately required.  A CDN-only or DNS-only token cannot
    # reach a later write step with partial state.
    gcore_api_request GET '/cdn/resources?limit=1' >/dev/null
    GCORE_DNS_ZONE=$(gcore_find_zone_for_domain "${GCORE_ORIGIN_DOMAIN}")
    [[ -n "${GCORE_DNS_ZONE}" ]] \
        || die "Gcore Managed DNS 中没有覆盖源站域名 ${GCORE_ORIGIN_DOMAIN} 的 Zone；请先按 docs/gcore-guide.md 委派整个主域名"
    gcore_verify_zone_delegation "${GCORE_DNS_ZONE}"
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    gcore_upsert_rrset "${GCORE_DNS_ZONE}" "${GCORE_ORIGIN_DOMAIN}" A "${public_ip}"
    gcore_wait_for_origin_dns
}

gcore_apply_cdn() {
    gcore_ensure_origin_group
    gcore_ensure_resource
    gcore_detect_cdn_target
    gcore_ensure_cname_record
    gcore_wait_for_cdn_dns
    gcore_ensure_edge_certificate
    gcore_wait_for_cdn_health
}

configure_gcore_fee_protection() {
    if [[ -z "${GCORE_FEE_PROTECTION_GB:-}" || "${GCORE_FEE_PROTECTION_GB}" == "0" ]]; then
        GCORE_FEE_PROTECTION_GB=${DEFAULT_GCORE_FEE_PROTECTION_GB}
    fi
    validate_cloudfront_fee_protection_gb "${GCORE_FEE_PROTECTION_GB}" \
        || die "Gcore 全局费用保护额度必须是 1-1000 的整数 GB"
    GCORE_FEE_PROTECTION_GB=$((10#${GCORE_FEE_PROTECTION_GB}))
    [[ "${GCORE_FEE_PROTECTION_GB}" == "${DEFAULT_GCORE_FEE_PROTECTION_GB}" ]] \
        || die "Gcore Free CDN 全局费用保护额度固定为 ${DEFAULT_GCORE_FEE_PROTECTION_GB} GB"
    CLOUDFRONT_FEE_PROTECTION_GB=${GCORE_FEE_PROTECTION_GB}
    configure_cloudfront_fee_protection
}

collect_install_inputs() {
    PROTOCOL="xhttp"
    CDN_PROVIDER="gcore"
    configure_cdn_client_ip_family
    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"

    GCORE_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN:-$(prompt_value \
        "Gcore 源站域名（脚本创建 A 记录）" "" \
        "Gcore origin domain (the script creates the A record)")}
    GCORE_ORIGIN_DOMAIN=$(normalize_domain "${GCORE_ORIGIN_DOMAIN}")
    validate_domain "${GCORE_ORIGIN_DOMAIN}" || die "GCORE_ORIGIN_DOMAIN 无效：${GCORE_ORIGIN_DOMAIN}"
    AWS_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}

    VLESS_CDN_DOMAIN=${VLESS_CDN_DOMAIN:-$(prompt_value \
        "Gcore CDN 节点域名" "" "Gcore CDN node domain")}
    VLESS_CDN_DOMAIN=$(normalize_domain "${VLESS_CDN_DOMAIN}")
    validate_domain "${VLESS_CDN_DOMAIN}" || die "VLESS_CDN_DOMAIN 无效：${VLESS_CDN_DOMAIN}"
    [[ "${GCORE_ORIGIN_DOMAIN}" != "${VLESS_CDN_DOMAIN}" ]] || die "源站域名与 CDN 域名不能相同"
    GCORE_DNS_ZONE=""
    GCORE_ORIGIN_GROUP_ID=""
    GCORE_CDN_RESOURCE_ID=""
    GCORE_SSL_CERT_ID=""
    GCORE_CDN_TARGET=""
    GCORE_FEE_PROTECTION_GB=${GCORE_FEE_PROTECTION_GB:-${DEFAULT_GCORE_FEE_PROTECTION_GB}}
    configure_gcore_fee_protection

    XHTTP_PATH=${XHTTP_PATH:-$(generate_xhttp_path)}
    XHTTP_PATH="/xhttp-${XHTTP_PATH#/vless-}"
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效：${XHTTP_PATH}"
    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        || die "XRAY_XHTTP_LOOPBACK_PORT 无效：${XRAY_XHTTP_LOOPBACK_PORT}"
    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "ORIGIN_HEADER_SECRET 格式无效"
    choose_subscription_mode
    if subscription_enabled; then
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
    fi
}

load_state() {
    local variable env_name
    local -a variables=(
        PROTOCOL CDN_PROVIDER XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN XHTTP_PATH
        GCORE_ORIGIN_DOMAIN GCORE_DNS_ZONE GCORE_ORIGIN_GROUP_ID GCORE_CDN_RESOURCE_ID
        GCORE_SSL_CERT_ID GCORE_CDN_TARGET GCORE_FEE_PROTECTION_GB
        XRAY_XHTTP_LOOPBACK_PORT ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
        CDN_CLIENT_IP_FAMILY
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
    )
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        printf -v "${env_name}" '%s' "${!variable:-}"
        printf -v "${variable}" '%s' ""
    done
    source_state_file
    for variable in "${variables[@]}"; do
        env_name="EASY_ALL_ENV_${variable}"
        if [[ -n "${!env_name:-}" ]]; then
            printf -v "${variable}" '%s' "${!env_name}"
        fi
        unset "${env_name}"
    done
    [[ "${PROTOCOL}" == "xhttp" && "${CDN_PROVIDER:-}" == "gcore" ]] \
        || die "状态不是 Gcore CDN XHTTP；请重新安装"
    configure_cdn_client_ip_family
    validate_domain "${GCORE_ORIGIN_DOMAIN:-}" || die "状态中的 Gcore 源站域名无效"
    validate_domain "${VLESS_CDN_DOMAIN:-}" || die "状态中的 Gcore CDN 域名无效"
    [[ "${GCORE_DNS_ZONE:-}" =~ ^[A-Za-z0-9.-]+$ ]] || die "状态中缺少 Gcore DNS Zone"
    [[ "${GCORE_ORIGIN_GROUP_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore 源组 ID"
    [[ "${GCORE_CDN_RESOURCE_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore CDN 资源 ID"
    [[ "${GCORE_SSL_CERT_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore 证书 ID"
    validate_domain "${GCORE_CDN_TARGET:-}" && [[ "${GCORE_CDN_TARGET}" == *.gcdn.co ]] \
        || die "状态中的 Gcore CDN 目标无效"
    validate_uuid "${VLESS_UUID:-}" || die "状态中的 VLESS UUID 无效"
    validate_xhttp_path "${XHTTP_PATH:-}" || die "状态中的 XHTTP 路径无效"
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT:-}" \
        || die "状态中的 XHTTP 本机端口无效"
    [[ "${ORIGIN_HEADER_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "状态中的源站保护密钥无效"
    AWS_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}
    configure_gcore_fee_protection
    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
    SUBSCRIPTION_MODE=$(normalize_subscription_mode \
        "${SUBSCRIPTION_MODE:-$([[ -n "${ALLOWED_TOKENS:-}" ]] && printf deploy || printf link)}") \
        || die "状态文件中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}"
    [[ -z "${ALLOWED_TOKENS:-}" ]] \
        || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
        || die "状态文件中的 ALLOWED_TOKENS 无效"
    QUOTA_ENABLED=${QUOTA_ENABLED:-0}
    [[ "${QUOTA_ENABLED}" == "0" || "${QUOTA_ENABLED}" == "1" ]] \
        || die "状态文件中的 QUOTA_ENABLED 无效"
    if quota_enabled; then
        validate_user_accounts "${USER_ACCOUNTS:-}" || die "状态文件中的 USER_ACCOUNTS 无效"
        QUOTA_START_DATE=${QUOTA_START_DATE:-$(date -u +%Y-%m-%d)}
        validate_quota_start_date "${QUOTA_START_DATE}" \
            || die "状态文件中的 QUOTA_START_DATE 无效：${QUOTA_START_DATE}"
    else
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
    fi
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX")
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        printf 'PROTOCOL=%q\n' "xhttp"
        printf 'CDN_PROVIDER=%q\n' "gcore"
        printf 'XHTTP_NODE_NAME=%q\n' "${XHTTP_NODE_NAME}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID}"
        printf 'VLESS_CDN_DOMAIN=%q\n' "${VLESS_CDN_DOMAIN}"
        printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH}"
        printf 'GCORE_ORIGIN_DOMAIN=%q\n' "${GCORE_ORIGIN_DOMAIN}"
        printf 'GCORE_DNS_ZONE=%q\n' "${GCORE_DNS_ZONE}"
        printf 'GCORE_ORIGIN_GROUP_ID=%q\n' "${GCORE_ORIGIN_GROUP_ID}"
        printf 'GCORE_CDN_RESOURCE_ID=%q\n' "${GCORE_CDN_RESOURCE_ID}"
        printf 'GCORE_SSL_CERT_ID=%q\n' "${GCORE_SSL_CERT_ID}"
        printf 'GCORE_CDN_TARGET=%q\n' "${GCORE_CDN_TARGET}"
        printf 'GCORE_FEE_PROTECTION_GB=%q\n' "${GCORE_FEE_PROTECTION_GB}"
        printf 'XRAY_XHTTP_LOOPBACK_PORT=%q\n' "${XRAY_XHTTP_LOOPBACK_PORT}"
        printf 'ORIGIN_HEADER_SECRET=%q\n' "${ORIGIN_HEADER_SECRET}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'QUOTA_ENABLED=%q\n' "${QUOTA_ENABLED:-0}"
        printf 'USER_ACCOUNTS=%q\n' "${USER_ACCOUNTS:-}"
        printf 'QUOTA_START_DATE=%q\n' "${QUOTA_START_DATE:-}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME}"
        printf 'SUBSCRIPTION_MODE=%q\n' "${SUBSCRIPTION_MODE:-deploy}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
        printf 'CDN_CLIENT_IP_FAMILY=%q\n' "ipv4"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Gcore CDN XHTTP 尚未安装"
    load_state
}

# Gcore currently limits an origin read timeout to 30 seconds.  Keep XHTTP's
# stream-up server window strictly below that edge limit instead of inheriting
# CloudFront's 20-40-second range.
xhttp_render_xray_config() {
    local clients managed_outbounds managed_routing stats_enabled=false
    install -d -m 0755 "${XRAY_DIR}"
    if quota_enabled; then
        clients=$(quota_active_clients_json)
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" \
            '[{id:$id,email:$email}]')
    fi
    cloudfront_fee_protection_blocked && clients='[]'
    traffic_stats_enabled && stats_enabled=true
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    jq -n --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson clients "${clients}" --argjson stats_enabled "${stats_enabled}" \
        --arg xhttp_path "${XHTTP_PATH}" --arg xhttp_host "${VLESS_CDN_DOMAIN}" \
        --arg stream_up_server_secs "${GCORE_XHTTP_STREAM_UP_SERVER_SECS}" \
        --argjson managed_outbounds "${managed_outbounds}" \
        --argjson managed_routing "${managed_routing}" '
        {log:{loglevel:"warning"},
         inbounds:[{tag:"vless-xhttp-h2-in",listen:"127.0.0.1",port:$xhttp_port,protocol:"vless",
          settings:{clients:$clients,decryption:"none"},
          streamSettings:{network:"xhttp",xhttpSettings:{host:$xhttp_host,path:$xhttp_path,mode:"stream-up",scStreamUpServerSecs:$stream_up_server_secs}},
          sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:false}}],
         outbounds:$managed_outbounds,
         routing:$managed_routing}
        + (if $stats_enabled then {api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]},stats:{},policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}}} else {} end)
    ' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS XHTTP stream-up/H2 over Gcore CDN\n节点链接:\n%s\n\n' "$(build_node_link)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node
    printf '\n'
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: xhttp（Gcore CDN）\n源站域名: %s\nCDN 域名: %s\nGcore 目标: %s\nXHTTP 路径: %s\n' \
        "${GCORE_ORIGIN_DOMAIN}" "${VLESS_CDN_DOMAIN}" "${GCORE_CDN_TARGET}" "${XHTTP_PATH}"
    show_bbrv3_status
    printf 'CDN 客户端节点族: %s（固定）\n' \
        "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
    printf 'Gcore DNS Zone: %s\n源组 ID: %s\nCDN 资源 ID: %s\n证书 ID: %s\n' \
        "${GCORE_DNS_ZONE}" "${GCORE_ORIGIN_GROUP_ID}" "${GCORE_CDN_RESOURCE_ID}" "${GCORE_SSL_CERT_ID}"
    printf 'Xray: '; systemctl is-active --quiet "${XRAY_SERVICE}" && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '; systemctl is-active --quiet nginx && printf 'active\n' || printf 'inactive\n'
    printf 'UFW: '; LC_ALL=C ufw status 2>/dev/null | sed -n 's/^Status: //p'
    show_quota_status
    show_cloudfront_fee_protection_status
}

update_subscription() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    info "update-sub 只更新本机 Xray、订阅与 Nginx，并复用现有 Gcore CDN；不会修改 Gcore 资源"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    validate_cdn_client_ip_family_runtime
    if subscription_enabled; then
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
        write_subscriptions
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
        remove_subscriptions
    fi
    save_state
    refresh_runtime
    install_quota_timer
    install_cloudfront_fee_protection_timer
    end_quota_maintenance
    subscription_enabled && validate_subscription_runtime
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Nginx 订阅已刷新"
}

apply_easy_all() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    finish_xhttp_apply
    success "easy_all Gcore CDN XHTTP 本机配置与订阅已应用；未修改 Gcore 资源"
}

apply_cloud_resources() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    gcore_prepare_origin
    gcore_apply_cdn
    finish_xhttp_apply
    gcore_clear_api_token
    success "easy_all Gcore CDN XHTTP 本机配置、Managed DNS、CDN 与边缘证书已应用"
}

rollback_fresh_install() {
    warn "安装失败，正在恢复本机服务与防火墙；已创建的 Gcore DNS/CDN 资源不会自动删除"
    stop_services
    remove_quota_timer
    remove_cloudfront_fee_protection_timer
    restore_preinstall_firewall
    if [[ -f "${BACKUP_DIR}/pre-install-bbr.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr.conf" "${SYSCTL_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr.missing" ]]; then
        rm -f -- "${SYSCTL_CONFIG}"
    fi
    restore_tcp_runtime
    if [[ -f "${BACKUP_DIR}/pre-install-bbr-module.conf" ]]; then
        install -m 0644 "${BACKUP_DIR}/pre-install-bbr-module.conf" "${BBR_MODULES_CONFIG}"
    elif [[ -f "${BACKUP_DIR}/pre-install-bbr-module.missing" ]]; then
        rm -f -- "${BBR_MODULES_CONFIG}"
    fi
    if [[ -f "${BACKUP_DIR}/pre-install-crontab" ]]; then
        crontab "${BACKUP_DIR}/pre-install-crontab" >/dev/null 2>&1 || true
    elif [[ -f "${BACKUP_DIR}/pre-install-crontab.missing" ]]; then
        crontab -r >/dev/null 2>&1 || true
    fi
    remove_managed_acme_domain "${GCORE_ORIGIN_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    gcore_clear_api_token
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" ]] || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all Gcore CDN XHTTP 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        read_bilingual \
            '确认删除 easy_all Gcore CDN XHTTP 本机服务、状态和证书？远端 Gcore 资源会保留。[y/N]（直接回车取消）:' \
            'Delete easy_all Gcore CDN XHTTP local services, state and certificates? Remote Gcore resources will be kept. [y/N] (press Enter to cancel):' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_services
    remove_quota_timer
    remove_cloudfront_fee_protection_timer
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    remove_managed_acme_domain "${GCORE_ORIGIN_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    success "easy_all Gcore CDN XHTTP 本机内容已卸载；Gcore DNS、源组、CDN 与边缘证书未删除"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="gcore"
    require_root
    require_systemd
    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    check_platform
    check_install_conflicts
    snapshot_fresh_install
    info "[1/9] 安装系统依赖"
    install_packages
    ensure_ssh_boot_service
    info "[2/9] 安装 XanMod LTS BBRv3 与配置定时重启"
    configure_bbr_tcp
    configure_daily_reboot
    info "[3/9] 收集 Gcore 域名、订阅与 VLESS 参数"
    collect_install_inputs
    alert "源站域名与 CDN 域名必须位于同一个已完整委派到 Gcore Managed DNS 的主域名。"
    info "[4/9] 验证 Gcore 权限与 DNS 委派，并创建源站 A 记录"
    gcore_prepare_origin
    info "[5/9] 配置防火墙与 HTTP-01 入口"
    configure_ufw
    write_bootstrap_nginx_config
    info "[6/9] 申请源站证书并安装 Xray"
    issue_origin_certificate
    download_xray
    write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    info "[7/9] 配置 Gcore 源组、CDN、CNAME 与免费 Let's Encrypt"
    gcore_apply_cdn
    validate_cdn_client_ip_family_runtime
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi
    info "[8/9] 保存状态并注册命令"
    save_state
    register_easy_all_command
    install_quota_timer
    install_cloudfront_fee_protection_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    gcore_clear_api_token
    info "[9/9] 输出节点与订阅"
    show_subscription
    show_bbrv3_status
    success "easy_all Gcore CDN XHTTP 安装完成"
}

usage() {
    cat <<'EOF'
Gcore Profile 只能由 easy_all 统一入口调用。
请使用：easy_all install
EOF
}
