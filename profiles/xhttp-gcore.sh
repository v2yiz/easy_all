#!/usr/bin/env bash

# Gcore CDN Profile for easy_all (Mode 3).
#
# Provides high-performance, edge-accelerated VLESS over Gcore CDN.
# Uses official Gcore API and Geofeed to curate IPv4 nodes for Hong Kong,
# Japan, and Los Angeles, directional eyeball Globalping testing (no cross testing),
# and strictly outputs top 2 nodes per carrier (total 6 nodes, no domain fallback).
# Server side enables mTLS origin validation and dual-path Xray (WebSocket + XHTTP packet-up).

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'xhttp-gcore.sh 是 easy_all 的 Gcore CDN Profile；请使用：easy_all install\n' >&2
    exit 2
fi

if [[ "${_EASY_ALL_XHTTP_GCORE_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_EASY_ALL_XHTTP_GCORE_LOADED=1

readonly GCORE_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly XHTTP_PROFILE_ROOT="${GCORE_PROFILE_ROOT}/../lib"
CDN_PROVIDER="gcore"
BACKEND="xray"
PROTOCOL="gcore"
XHTTP_CDN_NAME_OVERRIDE="Gcore CDN"
XHTTP_ORIGIN_DNS_NAME_OVERRIDE="Gcore Managed DNS"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray VLESS WebSocket managed by easy_all"
XHTTP_MODE_OVERRIDE="packet-up"
XHTTP_XMUX_ENABLED_OVERRIDE=false

readonly GCORE_API_BASE="https://api.gcore.com"
readonly GCORE_DNS_TTL="300"
readonly GCORE_XHTTP_MAX_BUFFERED_POSTS="100"
readonly GCORE_XHTTP_PADDING_BYTES="100-500"
readonly GCORE_CDN_TRAFFIC_PROTECTION_GB="990"
readonly GCORE_WEBSOCKET_NGINX_TIMEOUT="1h"
readonly GCORE_XHTTP_NGINX_TIMEOUT="1h"
readonly DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT="10087"
readonly GCORE_ORIGIN_IPS_FILE="/etc/easy_all/gcore-origin-ipv4.txt"
readonly GCORE_UFW_COMMENT="easy_all-gcore-origin"

GLOBALPING_CACHE_BASENAME_OVERRIDE="gcore-cdn-ips.json"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
source "${XHTTP_PROFILE_ROOT}/globalping-cdn.sh"
# shellcheck source=lib/gcore-ip-pool.sh
source "${XHTTP_PROFILE_ROOT}/gcore-ip-pool.sh"
# shellcheck source=lib/xray-core.sh
source "${XHTTP_PROFILE_ROOT}/xray-core.sh"

readonly ACME_HOME="/root/.acme-gcore.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-tls-service.sh"

readonly GCORE_CLIENT_CA_KEY="${CERT_DIR}/gcore-client-ca.key"
readonly GCORE_CLIENT_CA_FILE="${CERT_DIR}/gcore-client-ca.crt"
readonly GCORE_CLIENT_CERT_KEY="${CERT_DIR}/gcore-client.key"
readonly GCORE_CLIENT_CERT_FILE="${CERT_DIR}/gcore-client.crt"

choose_cdn_client_ip_family() {
    CDN_CLIENT_IP_FAMILY=${CDN_CLIENT_IP_FAMILY:-ipv4}
    configure_cdn_client_ip_family
}

# --- Gcore API and Credentials ---

gcore_api_raw() {
    local method=$1 path=$2 payload=${3:-} response
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    if [[ -n "${payload}" ]]; then
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
            -H 'Content-Type: application/json' \
            --data "${payload}" "${GCORE_API_BASE}${path}") || return 1
    else
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
            -H 'Accept: application/json' \
            "${GCORE_API_BASE}${path}") || return 1
    fi
    printf '%s' "${response}"
}

gcore_api_request() {
    local method=$1 path=$2 payload=${3:-} response
    response=$(gcore_api_raw "${method}" "${path}" "${payload}") \
        || die "Gcore API 请求失败：${method} ${path}"
    if jq -e 'type == "object" and has("errors")' <<<"${response}" >/dev/null 2>&1; then
        jq -c '.errors // .' <<<"${response}" >&2
        die "Gcore API 返回错误：${method} ${path}"
    fi
    if jq -e 'type == "object" and has("error")' <<<"${response}" >/dev/null 2>&1; then
        jq -c '.error // .' <<<"${response}" >&2
        die "Gcore API 返回错误：${method} ${path}"
    fi
    printf '%s' "${response}"
}

gcore_api_get_optional() {
    local path=$1 http_code response
    response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 \
        -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
        -H 'Accept: application/json' \
        -w '\n%{http_code}' \
        "${GCORE_API_BASE}${path}") || return 1
    http_code=$(tail -n 1 <<<"${response}")
    response=$(sed '$d' <<<"${response}")
    if [[ "${http_code}" == "404" ]]; then
        return 1
    fi
    if ((http_code < 200 || http_code >= 300)); then
        return 1
    fi
    printf '%s' "${response}"
}

gcore_json_items() {
    local json=$1
    if jq -e 'type == "array"' <<<"${json}" >/dev/null 2>&1; then
        jq -c '.[]' <<<"${json}"
    elif jq -e 'type == "object" and has("results") and (.results | type == "array")' <<<"${json}" >/dev/null 2>&1; then
        jq -c '.results[]' <<<"${json}"
    elif jq -e 'type == "object" and has("data") and (.data | type == "array")' <<<"${json}" >/dev/null 2>&1; then
        jq -c '.data[]' <<<"${json}"
    fi
}

gcore_collect_api_token() {
    local token=${GCORE_API_TOKEN:-}
    if [[ -z "${token}" ]]; then
        token=$(prompt_secret "Gcore API Token（仅当前进程使用，不落盘）" \
            "Gcore API Token (current process only; never saved)") \
            || die "非交互模式必须设置 GCORE_API_TOKEN"
    fi
    [[ ${#token} -ge 16 && ${#token} -le 512 && "${token}" != *[[:space:]]* ]] \
        || die "GCORE_API_TOKEN 格式无效"
    GCORE_API_TOKEN=${token}
}

gcore_clear_api_token() {
    unset GCORE_API_TOKEN
}

# --- Origin Firewall (UFW) using Gcore Official CIDRs ---

gcore_fetch_origin_ipv4_ranges() {
    local response
    response=$(curl -fsS --retry 3 --connect-timeout 10 --max-time 30 \
        "${GCORE_API_BASE}/cdn/public-net-list") || return 1
    jq -er '
        .addresses
        | select(type == "array" and length > 0)
        | unique[]
        | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([89]|[12][0-9]|3[0-2])$"))
    ' <<<"${response}" | sort -u
}

gcore_origin_ufw_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | sed -n "/${GCORE_UFW_COMMENT}/s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)\\].*/\\1/p" \
        | sort -rn
}

gcore_remove_origin_firewall_rules() {
    local number
    while IFS= read -r number; do
        [[ -n "${number}" ]] || continue
        ufw --force delete "${number}" >/dev/null 2>&1 \
            || warn "删除 Gcore 回源 UFW 规则 ${number} 失败"
    done < <(gcore_origin_ufw_rule_numbers)
}

gcore_configure_origin_firewall() {
    local next current cidr
    next="${RUNTIME_TMP}/gcore-origin-ipv4.txt"
    if ! gcore_fetch_origin_ipv4_ranges >"${next}" || [[ ! -s "${next}" ]]; then
        if [[ -s "${GCORE_ORIGIN_IPS_FILE}" ]]; then
            warn "获取 Gcore 官方 IP 段失败，继续使用上一版回源白名单"
            install -m 0600 "${GCORE_ORIGIN_IPS_FILE}" "${next}"
        else
            warn "无法获取 Gcore 官方 IPv4 段，跳过 UFW 回源白名单限制"
            return 0
        fi
    fi
    current="${RUNTIME_TMP}/gcore-origin-ipv4.current"
    if [[ -s "${GCORE_ORIGIN_IPS_FILE}" ]]; then
        install -m 0600 "${GCORE_ORIGIN_IPS_FILE}" "${current}"
    else
        : >"${current}"
    fi

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${next}" && continue
        ufw delete allow proto tcp from "${cidr}" to any port 443 comment "${GCORE_UFW_COMMENT}" >/dev/null 2>&1 || true
    done <"${current}"

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${current}" && continue
        ufw allow proto tcp from "${cidr}" to any port 443 comment "${GCORE_UFW_COMMENT}" >/dev/null 2>&1 || true
    done <"${next}"

    install -d -m 0700 "$(dirname "${GCORE_ORIGIN_IPS_FILE}")"
    install -m 0600 "${next}" "${GCORE_ORIGIN_IPS_FILE}"
}

# --- DNS & Zone Management ---

gcore_find_zone_for_domain() {
    local domain=$1 zones matched="" candidate
    zones=$(gcore_api_request GET "/dns/v2/zones")
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        if [[ "${domain}" == "${candidate}" || "${domain}" == *".${candidate}" ]]; then
            if [[ -z "${matched}" || ${#candidate} -gt ${#matched} ]]; then
                matched=${candidate}
            fi
        fi
    done < <(gcore_json_items "${zones}" | jq -r '.name // empty')
    [[ -n "${matched}" ]] || return 1
    printf '%s' "${matched}"
}

gcore_verify_zone_delegation() {
    local zone=$1 status
    status=$(gcore_api_request GET "/dns/v2/analyze/${zone}/delegation-status")
    if ! jq -e '.delegated == true' <<<"${status}" >/dev/null 2>&1; then
        warn "Zone ${zone} 在 Gcore 尚未通过 DNS 委派校验"
    fi
}

gcore_ensure_origin_a_record() {
    local public_ip
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}

    local payload
    payload=$(jq -cn --arg ip "${public_ip}" --argjson ttl "${GCORE_DNS_TTL}" \
        '{records:[{content:$ip}],ttl:$ttl}')
    info "在 Gcore Managed DNS 配置源站 A 记录: ${GCORE_ORIGIN_DOMAIN} -> ${public_ip}"
    gcore_api_request PUT "/dns/v2/zones/${GCORE_DNS_ZONE}/${GCORE_ORIGIN_DOMAIN}/A" "${payload}" >/dev/null
}

gcore_ensure_cdn_cname_record() {
    local payload
    payload=$(jq -cn --arg target "${GCORE_CDN_TARGET}" --argjson ttl "${GCORE_DNS_TTL}" \
        '{records:[{content:$target}],ttl:$ttl}')
    info "在 Gcore Managed DNS 配置 CDN CNAME 记录: ${VLESS_CDN_DOMAIN} -> ${GCORE_CDN_TARGET}"
    gcore_api_request PUT "/dns/v2/zones/${GCORE_DNS_ZONE}/${VLESS_CDN_DOMAIN}/CNAME" "${payload}" >/dev/null
}

# --- Origin Let's Encrypt Certificate (ACME) ---

write_web_root() {
    install -d -m 0755 "${WEB_ROOT}/.well-known/acme-challenge"
    printf '%s\n' 'ready' >"${RUNTIME_TMP}/index.html"
    install -m 0644 "${RUNTIME_TMP}/index.html" "${WEB_ROOT}/index.html"
    rm -f -- "${RUNTIME_TMP}/index.html"
}

write_bootstrap_nginx_config() {
    write_web_root
    cat >"${RUNTIME_TMP}/easy_all-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${GCORE_ORIGIN_DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ {
        try_files \$uri =404;
    }
    location / {
        return 200 "easy_all bootstrap ready\n";
    }
}
EOF
    install -m 0600 "${RUNTIME_TMP}/easy_all-bootstrap.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx bootstrap 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "启动/重载 Nginx 失败"
}

install_acme() {
    [[ -x "${ACME_BIN}" ]] && return 0
    local archive_file temp_dir
    archive_file=$(make_temp_dir)/acme.sh.tar.gz
    temp_dir=$(make_temp_dir)/acme-extract
    download_https_file \
        "https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.1.0.tar.gz" \
        "${archive_file}" "acme.sh"
    mkdir -p "${temp_dir}"
    tar -xzf "${archive_file}" -C "${temp_dir}"
    local source_dir
    source_dir=$(find "${temp_dir}" -mindepth 1 -maxdepth 1 -type d | head -n 1)
    [[ -n "${source_dir}" && -f "${source_dir}/acme.sh" ]] || die "解压 acme.sh 源码失败"
    install -d -m 0700 "${ACME_HOME}"
    (
        cd "${source_dir}"
        ./acme.sh --install --home "${ACME_HOME}" \
            --config-home "${ACME_HOME}/data" \
            --cert-home "${ACME_HOME}/certs" >/dev/null
    )
    [[ -x "${ACME_BIN}" ]] || die "安装 acme.sh 失败"
    touch "${ACME_OWNERSHIP_MARKER}"
}

run_acme() {
    "${ACME_BIN}" --home "${ACME_HOME}" \
        --config-home "${ACME_HOME}/data" \
        --cert-home "${ACME_HOME}/certs" "$@"
}

issue_origin_certificate() {
    install_acme
    run_acme --set-default-ca --server letsencrypt >/dev/null || true
    install -d -m 0700 "${CERT_DIR}"
    if ! run_acme --issue -d "${GCORE_ORIGIN_DOMAIN}" -w "${WEB_ROOT}" \
        --keylength ec-256 --force; then
        die "源站域名 ${GCORE_ORIGIN_DOMAIN} 证书签发失败"
    fi
    if ! run_acme --install-cert -d "${GCORE_ORIGIN_DOMAIN}" --ecc \
        --cert-file "${CERT_FILE}" \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${FULLCHAIN_FILE}"; then
        die "安装源站 ECC 证书失败"
    fi
    chmod 0600 "${KEY_FILE}"
    chmod 0644 "${CERT_FILE}" "${FULLCHAIN_FILE}"
}

# --- Origin Validation & mTLS with Gcore ---

gcore_origin_group_name() {
    printf 'easy_all-%s' "${GCORE_ORIGIN_DOMAIN}"
}

gcore_origin_ca_name() {
    printf 'easy_all-origin-ca-%s' "${GCORE_ORIGIN_DOMAIN}"
}

gcore_prepare_origin_validation_material() {
    install -d -m 0700 "${CERT_DIR}"

    if [[ ! -s "${GCORE_CLIENT_CA_FILE}" || ! -s "${GCORE_CLIENT_CERT_FILE}" ]]; then
        info "生成源站 mTLS 专用客户端证书与 CA"
        local tmp_ca_key="${RUNTIME_TMP}/gcore-client-ca.key"
        local tmp_ca_file="${RUNTIME_TMP}/gcore-client-ca.crt"
        local tmp_cert_key="${RUNTIME_TMP}/gcore-client.key"
        local tmp_cert_file="${RUNTIME_TMP}/gcore-client.crt"
        local tmp_csr="${RUNTIME_TMP}/client.csr"

        openssl ecparam -name prime256v1 -genkey -noout -out "${tmp_ca_key}"
        openssl req -x509 -new -nodes -key "${tmp_ca_key}" -sha256 -days 3650 \
            -subj "/CN=easy_all Gcore Origin Client CA" -out "${tmp_ca_file}"
        openssl ecparam -name prime256v1 -genkey -noout -out "${tmp_cert_key}"
        openssl req -new -key "${tmp_cert_key}" \
            -subj "/CN=easy_all Gcore Edge Client" \
            -out "${tmp_csr}"
        openssl x509 -req -in "${tmp_csr}" \
            -CA "${tmp_ca_file}" -CAkey "${tmp_ca_key}" -CAcreateserial \
            -out "${tmp_cert_file}" -days 3650 -sha256

        install -m 0600 "${tmp_ca_key}" "${GCORE_CLIENT_CA_KEY}"
        install -m 0644 "${tmp_ca_file}" "${GCORE_CLIENT_CA_FILE}"
        install -m 0600 "${tmp_cert_key}" "${GCORE_CLIENT_CERT_KEY}"
        install -m 0644 "${tmp_cert_file}" "${GCORE_CLIENT_CERT_FILE}"
        rm -f -- "${tmp_ca_key}" "${tmp_ca_file}" "${tmp_cert_key}" "${tmp_cert_file}" "${tmp_csr}"
    fi
}

gcore_ensure_origin_validation_certificates() {
    gcore_prepare_origin_validation_material
    local cert_name ca_name cert_payload ca_payload
    cert_name="easy_all-edge-client-${GCORE_ORIGIN_DOMAIN}"
    ca_name=$(gcore_origin_ca_name)

    # 1. Upload VPS client certificate to Gcore (/cdn/sslData)
    cert_payload=$(jq -cn \
        --arg name "${cert_name}" \
        --arg cert "$(<"${GCORE_CLIENT_CERT_FILE}")" \
        --arg key "$(<"${GCORE_CLIENT_CERT_KEY}")" \
        '{name:$name,sslCertificate:$cert,sslPrivateKey:$key}')
    local cert_res
    cert_res=$(gcore_api_request POST "/cdn/sslData" "${cert_payload}")
    GCORE_ORIGIN_CLIENT_CERT_ID=$(jq -er '.id // empty' <<<"${cert_res}")

    # 2. Upload Let'\''s Encrypt intermediate/root CA to Gcore (/cdn/sslCertificates)
    local issuer_ca_file="${RUNTIME_TMP}/issuer_ca.crt"
    # Extract CA certificate chain (all except the first server leaf cert)
    awk 'BEGIN {c=0} /BEGIN CERTIFICATE/ {c++} c>1 {print}' "${FULLCHAIN_FILE}" >"${issuer_ca_file}"
    [[ -s "${issuer_ca_file}" ]] || install -m 0644 "${FULLCHAIN_FILE}" "${issuer_ca_file}"

    ca_payload=$(jq -cn \
        --arg name "${ca_name}" \
        --arg cert "$(<"${issuer_ca_file}")" \
        '{name:$name,sslCertificate:$cert}')
    local ca_res
    ca_res=$(gcore_api_request POST "/cdn/sslCertificates" "${ca_payload}")
    GCORE_ORIGIN_CA_ID=$(jq -er '.id // empty' <<<"${ca_res}")
}

gcore_ensure_origin_group() {
    local group_name payload response existing_groups group
    group_name=$(gcore_origin_group_name)
    existing_groups=$(gcore_api_request GET "/cdn/origin_groups")
    while IFS= read -r group; do
        [[ -n "${group}" ]] || continue
        if [[ "$(jq -r '.name // empty' <<<"${group}")" == "${group_name}" ]]; then
            GCORE_ORIGIN_GROUP_ID=$(jq -r '.id' <<<"${group}")
            return 0
        fi
    done < <(gcore_json_items "${existing_groups}")

    payload=$(jq -cn --arg name "${group_name}" --arg source "${GCORE_ORIGIN_DOMAIN}" '{
      name: $name,
      use_next: true,
      origins: [{source: $source, enabled: true, backup: false}]
    }')
    response=$(gcore_api_request POST "/cdn/origin_groups" "${payload}")
    GCORE_ORIGIN_GROUP_ID=$(jq -er '.id // empty' <<<"${response}")
}

gcore_ensure_resource() {
    local payload response existing_resources res
    payload=$(jq -cn \
        --arg cname "${VLESS_CDN_DOMAIN}" \
        --argjson origin_group "${GCORE_ORIGIN_GROUP_ID}" \
        --arg host "${VLESS_CDN_DOMAIN}" \
        --argjson client_cert_id "${GCORE_ORIGIN_CLIENT_CERT_ID}" \
        --argjson origin_ca_id "${GCORE_ORIGIN_CA_ID}" '{
          cname: $cname,
          originGroup: $origin_group,
          originProtocol: "HTTPS",
          options: {
            websockets: {enabled: true},
            hostHeader: {enabled: true, value: $host},
            force_ssl: {enabled: true},
            proxy_cache: {enabled: false},
            edge_cache_settings: {enabled: true, value: "0s", custom_values: {}},
            browser_cache_settings: {enabled: true, value: "0s"},
            ignore_query_string: {enabled: false},
            slice: {enabled: false},
            origin_ssl_validation: {
              enabled: true,
              auth_type: "client_certificate",
              ssl_data_id: $client_cert_id,
              ssl_certificate_id: $origin_ca_id
            }
          }
        }')

    existing_resources=$(gcore_api_request GET "/cdn/resources")
    while IFS= read -r res; do
        [[ -n "${res}" ]] || continue
        if [[ "$(jq -r '.cname // empty' <<<"${res}")" == "${VLESS_CDN_DOMAIN}" ]]; then
            GCORE_CDN_RESOURCE_ID=$(jq -r '.id' <<<"${res}")
            info "更新已有 Gcore CDN 资源 (ID: ${GCORE_CDN_RESOURCE_ID}) 的 mTLS 与配置"
            gcore_api_request PUT "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null || true
            return 0
        fi
    done < <(gcore_json_items "${existing_resources}")

    response=$(gcore_api_request POST "/cdn/resources" "${payload}")
    GCORE_CDN_RESOURCE_ID=$(jq -er '.id // empty' <<<"${response}")
}

gcore_prepare_origin() {
    gcore_collect_api_token
    info "获取 Gcore 账户专属 CNAME 调度目标"
    local client_me
    client_me=$(gcore_api_request GET "/cdn/clients/me")
    GCORE_CDN_TARGET=$(jq -er '.cname // empty' <<<"${client_me}")
    [[ -n "${GCORE_CDN_TARGET}" ]] || die "无法从 Gcore 账户获取 CNAME 调度目标"

    info "检索 Gcore Managed DNS Zone"
    GCORE_DNS_ZONE=$(gcore_find_zone_for_domain "${GCORE_ORIGIN_DOMAIN}") \
        || die "未找到匹配域名 ${GCORE_ORIGIN_DOMAIN} 的 Gcore DNS Zone"
    gcore_verify_zone_delegation "${GCORE_DNS_ZONE}"
    gcore_ensure_origin_a_record
    gcore_ensure_cdn_cname_record
}

gcore_apply_cdn() {
    info "配置 Gcore 源组、证书与 CDN 资源"
    gcore_ensure_origin_group
    gcore_ensure_origin_validation_certificates
    gcore_ensure_resource
}

# --- Service Configurations (Xray & Nginx) ---

xhttp_render_xray_config() {
    local clients managed_outbounds managed_routing inbound_sockopt stats_enabled=false
    install -d -m 0755 "${XRAY_DIR}"
    if quota_enabled; then
        clients=$(quota_active_clients_json)
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" \
            '[{id:$id,email:$email}]')
    fi
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
    quota_enabled && stats_enabled=true

    jq -n --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson websocket_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" \
        --argjson clients "${clients}" --argjson stats_enabled "${stats_enabled}" \
        --arg xhttp_path "${XHTTP_PATH}" --arg websocket_path "${WEBSOCKET_PATH}" \
        --arg host "${VLESS_CDN_DOMAIN}" \
        --arg padding "${GCORE_XHTTP_PADDING_BYTES}" \
        --arg mode "packet-up" \
        --argjson max_buffered_posts "${GCORE_XHTTP_MAX_BUFFERED_POSTS}" \
        --argjson inbound_sockopt "${inbound_sockopt}" \
        --argjson managed_outbounds "${managed_outbounds}" \
        --argjson managed_routing "${managed_routing}" '
        {log:{loglevel:"warning"},
         inbounds:[{tag:"vless-xhttp-h2-in",listen:"127.0.0.1",port:$xhttp_port,protocol:"vless",
          settings:{clients:$clients,decryption:"none"},
          streamSettings:{network:"xhttp",sockopt:$inbound_sockopt,
            xhttpSettings:{host:$host,path:$xhttp_path,mode:$mode,
              xPaddingBytes:$padding,scMaxBufferedPosts:$max_buffered_posts}},
          sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:false}},
         {tag:"vless-websocket-in",listen:"127.0.0.1",port:$websocket_port,protocol:"vless",
          settings:{clients:$clients,decryption:"none"},
          streamSettings:{network:"ws",sockopt:$inbound_sockopt,wsSettings:{path:$websocket_path}},
          sniffing:{enabled:true,destOverride:["http","tls","quic"],routeOnly:false}}],
         outbounds:$managed_outbounds,
         routing:$managed_routing}
        + (if $stats_enabled then {api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]},stats:{},policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}}} else {} end)
    ' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

write_nginx_config() {
    local http2_directive="" listen_h2="http2 "
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    gcore_prepare_origin_validation_material
    write_web_root
    {
        write_subscription_nginx_maps
        cat <<EOF
upstream gcore_websocket_backend {
    server 127.0.0.1:${XRAY_WEBSOCKET_LOOPBACK_PORT};
    keepalive 32;
}

upstream gcore_xhttp_backend {
    server 127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${GCORE_ORIGIN_DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 301 https://${GCORE_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3;
    listen [::]:443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3;${http2_directive}
    server_name ${GCORE_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_client_certificate ${GCORE_CLIENT_CA_FILE};
    ssl_verify_client on;
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "easy_all ok\n";
    }

EOF
        write_subscription_nginx_locations
        cat <<EOF
    location = ${WEBSOCKET_PATH} {
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${VLESS_CDN_DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_connect_timeout 5s;
        proxy_read_timeout ${GCORE_WEBSOCKET_NGINX_TIMEOUT};
        proxy_send_timeout ${GCORE_WEBSOCKET_NGINX_TIMEOUT};
        proxy_pass http://gcore_websocket_backend;
        access_log off;
    }

    location ^~ ${XHTTP_PATH}/ {
        client_max_body_size 0;
        client_body_timeout ${GCORE_XHTTP_NGINX_TIMEOUT};
        proxy_http_version 1.1;
        proxy_set_header Connection "";
        proxy_set_header Host ${VLESS_CDN_DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_request_buffering off;
        proxy_connect_timeout 5s;
        proxy_read_timeout ${GCORE_XHTTP_NGINX_TIMEOUT};
        proxy_send_timeout ${GCORE_XHTTP_NGINX_TIMEOUT};
        proxy_pass http://gcore_xhttp_backend;
        access_log off;
    }

    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx Gcore 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

# --- Subscription Rendering (Strictly 6 Curated Nodes, No Domain Fallback) ---

build_vless_websocket_link() {
    local server=$1 node_name=$2
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&alpn=http%%2F1.1&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${WEBSOCKET_PATH}")" "$(uri_encode "${node_name}")"
}

build_mihomo_websocket_node() {
    local server=$1 node_name=$2
    resolve_cdn_client_ip_family
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg path "${WEBSOCKET_PATH}" --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED:-ipv4}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: ws\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: \($ip_version)\n    alpn:\n      - http/1.1\n" +
        "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($host|@json)\n"'
}

build_node_links() {
    local ip label carrier region
    while IFS=$'\t' read -r ip label carrier region; do
        [[ -n "${ip}" ]] || continue
        build_vless_websocket_link "${ip}" "优选${label}"
        printf '\n'
    done < <(gcore_client_candidates)
}

build_mihomo_nodes() {
    local ip label carrier region
    while IFS=$'\t' read -r ip label carrier region; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_websocket_node "${ip}" "优选${label}"
    done < <(gcore_client_candidates)
}

build_mihomo_proxy_names() {
    printf '        - "AUTO"\n'
}

build_mihomo_proxy_groups() {
    local -a all_nodes=()
    local ip label carrier region
    while IFS=$'\t' read -r ip label carrier region; do
        [[ -n "${ip}" ]] || continue
        all_nodes+=("优选${label}")
    done < <(gcore_client_candidates)

    printf '    - name: "AUTO"\n'
    printf '      type: url-test\n'
    printf '      proxies:\n'
    local node
    for node in "${all_nodes[@]}"; do
        printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
    done
    cat <<EOF
      url: https://www.gstatic.com/generate_204
      interval: 300
      tolerance: 30
      timeout: 3000
      lazy: true
EOF
}

write_subscriptions() {
    local template node_file group_file name_file base64_file mihomo_file
    prepare_mihomo_template
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"

    build_mihomo_nodes >"${node_file}"
    build_mihomo_proxy_groups >"${group_file}"
    build_mihomo_proxy_names >"${name_file}"
    build_node_links | openssl base64 -A >"${base64_file}"
    printf '\n' >>"${base64_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}" \
        "${XHTTP_NODE_NAME}" "${CDN_CLIENT_IP_FAMILY_RESOLVED:-ipv4}" \
        "${group_file}" "${name_file}"

    grep -Fq 'network: ws' "${mihomo_file}" || die "Mihomo 订阅缺少 WebSocket 节点"

    rm -rf -- "${SUBSCRIPTION_DIR}"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
}

# --- Lifecycle Commands ---

show_node() {
    collect_installed_state
    printf '\n协议: VLESS WebSocket over Gcore CDN（精选 6 节点）\n节点链接:\n%s\n\n' "$(build_node_links)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_nodes
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: VLESS WebSocket + XHTTP packet-up（Gcore CDN）\n后端: Xray (%s)\n客户端 CDN 节点域名: %s\nGcore 回源域名: %s\nGcore 目标: %s\n候选来源: Gcore 官方公共 IP 池 / 三网 Globalping eyeball 定向探针\n域名兜底: disabled (全网精选 6 节点，无域名兜底)\n' \
        "$(xray_installed_version)" "${VLESS_CDN_DOMAIN}" "${GCORE_ORIGIN_DOMAIN}" "${GCORE_CDN_TARGET}"
    show_globalping_status
}

show_subscription() {
    collect_installed_state
    show_node
    if ! subscription_enabled; then
        printf '订阅服务: 未部署，仅输出节点信息\n\n'
        return 0
    fi
    printf 'Mihomo 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME}"
    local user token subscription_domain
    subscription_domain=$(subscription_link_domain)
    printf '订阅链接域名: %s\n' "${subscription_domain}"
    while IFS=$'\t' read -r user token; do
        printf '通用订阅 (Base64) (%s): https://%s/subscribe?token=%s\n' \
            "${user}" "${subscription_domain}" "${token}"
        printf 'Mihomo / Clash   (%s): https://%s/subscribe?token=%s&flag=clash\n' \
            "${user}" "${subscription_domain}" "${token}"
    done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"${ALLOWED_TOKENS}")
    printf '\n'
}

refresh_gcore_cdn_ips() {
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
    if ! refresh_gcore_globalping_cache; then
        refresh_status=1
        warn "Globalping 刷新失败，保留上一版本有效缓存"
    fi
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi
    save_state
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    release_runtime_write_lock
    ((refresh_status == 0)) || return 1
    success "Gcore CDN 精选 IP 与订阅已刷新"
}

rollback_fresh_install() {
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    gcore_remove_origin_firewall_rules
    restore_preinstall_firewall
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    gcore_clear_api_token
}

install_all() {
    [[ -t 0 || "${FORCE_INTERACTIVE:-0}" == "1" ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="gcore"
    BACKEND="xray"
    PROTOCOL="gcore"
    require_root
    require_systemd

    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    check_platform
    check_install_conflicts
    snapshot_fresh_install
    install_packages
    ensure_ssh_boot_service
    configure_bbr_tcp
    configure_daily_reboot
    collect_install_inputs
    gcore_prepare_origin
    configure_ufw
    write_bootstrap_nginx_config
    issue_origin_certificate
    download_xray
    xhttp_render_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    gcore_apply_cdn
    persist_globalping_token
    refresh_gcore_globalping_cache || warn "首次 Globalping 测量失败"
    subscription_enabled && { write_subscriptions; validate_subscription_runtime; }
    save_state
    register_easy_all_command
    install_quota_timer
    install_globalping_refresh_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    gcore_clear_api_token
    show_subscription
    success "easy_all Gcore CDN 精选节点安装完成"
    show_bbrv3_status
    prompt_bbrv3_reboot
}

apply_easy_all() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    finish_xhttp_apply
    install_globalping_refresh_timer
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Gcore CDN 本机配置已应用；未修改 Gcore 资源"
}

apply_cloud_resources() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    gcore_prepare_origin
    gcore_apply_cdn
    finish_xhttp_apply 1
    install_globalping_refresh_timer
    gcore_clear_api_token
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "easy_all Gcore CDN 本机配置、Managed DNS、CDN 与证书已应用"
}

xhttp_renew_origin_certificate() {
    require_root
    collect_installed_state
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 尚未安装"
    run_acme --renew -d "${GCORE_ORIGIN_DOMAIN}" --ecc --force \
        || die "源站证书续期失败"
    "${CERT_RELOAD_HOOK}" || die "证书已续期，但 Nginx 重载失败"
    gcore_collect_api_token
    gcore_ensure_origin_validation_certificates
    gcore_ensure_resource
    save_state
    gcore_clear_api_token
    success "源站证书与 Gcore Trusted CA 已同步续期"
}

update_subscription() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    validate_cdn_client_ip_family_runtime
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
        write_subscriptions
    else
        remove_subscriptions
    fi
    save_state
    refresh_runtime
    install_quota_timer
    subscription_enabled && validate_subscription_runtime
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Nginx 订阅已刷新"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        read_bilingual \
            '确认删除 easy_all Gcore CDN 本机服务、状态和证书？默认保留远端 Gcore 资源。[y/N]（直接回车取消）:' \
            'Delete easy_all Gcore CDN local services, state and certificates? Gcore resources are kept by default. [y/N] (press Enter to cancel):' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    if [[ "${mode}" == "--purge-cloud" ]]; then
        info "正在清理 Gcore CDN 远端资源..."
        gcore_collect_api_token
        # Remove CDN resource, origin group, SSL certificates
        [[ -z "${GCORE_CDN_RESOURCE_ID:-}" ]] || gcore_api_request DELETE "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" >/dev/null 2>&1 || true
        [[ -z "${GCORE_ORIGIN_GROUP_ID:-}" ]] || gcore_api_request DELETE "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}" >/dev/null 2>&1 || true
        [[ -z "${GCORE_ORIGIN_CLIENT_CERT_ID:-}" ]] || gcore_api_request DELETE "/cdn/sslData/${GCORE_ORIGIN_CLIENT_CERT_ID}" >/dev/null 2>&1 || true
        [[ -z "${GCORE_ORIGIN_CA_ID:-}" ]] || gcore_api_request DELETE "/cdn/sslCertificates/${GCORE_ORIGIN_CA_ID}" >/dev/null 2>&1 || true
        gcore_clear_api_token
    fi
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    gcore_remove_origin_firewall_rules
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    success "easy_all Gcore CDN 本机内容已卸载"
}
