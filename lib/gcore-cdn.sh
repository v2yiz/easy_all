#!/usr/bin/env bash

# Gcore CDN resource, certificate and origin helpers shared by combined profiles.

gcore_api_raw() {
    local method=$1 path=$2 payload=${3:-} response headers payload_file
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    headers="${RUNTIME_TMP}/gcore-api-headers"
    printf 'Authorization: APIKey %s\n' "${GCORE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    if [[ -n "${payload}" ]]; then
        payload_file="${RUNTIME_TMP}/gcore-api-payload"
        printf '%s' "${payload}" >"${payload_file}"
        chmod 0600 "${payload_file}"
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "@${headers}" \
            -H 'Content-Type: application/json' \
            --data-binary "@${payload_file}" -w $'\n%{http_code}' \
            "${GCORE_API_BASE}${path}") || return 1
    else
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "@${headers}" \
            -H 'Accept: application/json' \
            -w $'\n%{http_code}' "${GCORE_API_BASE}${path}") || return 1
    fi
    printf '%s' "${response}"
}

gcore_api_request() {
    local method=$1 path=$2 payload=${3:-} response http_code body
    response=$(gcore_api_raw "${method}" "${path}" "${payload}") \
        || die "Gcore API 请求失败：${method} ${path}"
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    [[ "${http_code}" =~ ^[0-9]{3}$ ]] \
        || die "Gcore API 返回无效 HTTP 状态：${method} ${path}；响应正文：${body}"
    if ((http_code < 200 || http_code >= 300)); then
        printf '%s\n' "${body:-<empty>}" >&2
        die "Gcore API 请求失败（HTTP ${http_code}）：${method} ${path}"
    fi
    if jq -e 'type == "object" and has("errors")' <<<"${body}" >/dev/null 2>&1; then
        printf '%s\n' "${body}" >&2
        die "Gcore API 返回错误：${method} ${path}"
    fi
    if jq -e 'type == "object" and has("error")' <<<"${body}" >/dev/null 2>&1; then
        printf '%s\n' "${body}" >&2
        die "Gcore API 返回错误：${method} ${path}"
    fi
    printf '%s' "${body}"
}

gcore_api_get_optional() {
    local path=$1 http_code response body
    response=$(gcore_api_raw GET "${path}") \
        || {
            fail "Gcore API 请求失败：GET ${path}"
            return 2
        }
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    [[ "${http_code}" =~ ^[0-9]{3}$ ]] \
        || {
            fail "Gcore API 返回无效 HTTP 状态：GET ${path}；响应正文：${body}"
            return 2
        }
    if [[ "${http_code}" == "404" ]]; then
        return 4
    fi
    if ((http_code < 200 || http_code >= 300)); then
        printf '%s\n' "${body:-<empty>}" >&2
        fail "Gcore API 请求失败（HTTP ${http_code}）：GET ${path}"
        return 2
    fi
    printf '%s' "${body}"
}

gcore_api_delete_optional() {
    local path=$1 response http_code body
    response=$(gcore_api_raw DELETE "${path}") || {
        fail "Gcore API 请求失败：DELETE ${path}"
        return 1
    }
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    [[ "${http_code}" =~ ^[0-9]{3}$ ]] || {
        fail "Gcore API 返回无效 HTTP 状态：DELETE ${path}；响应正文：${body}"
        return 1
    }
    [[ "${http_code}" == "404" ]] && return 0
    if ((http_code < 200 || http_code >= 300)); then
        printf '%s\n' "${body:-<empty>}" >&2
        fail "Gcore API 请求失败（HTTP ${http_code}）：DELETE ${path}"
        return 1
    fi
}

gcore_json_items() {
    local json=$1
    if jq -e 'type == "array"' <<<"${json}" >/dev/null 2>&1; then
        jq -c '.[]' <<<"${json}"
    elif jq -e 'type == "object"' <<<"${json}" >/dev/null 2>&1; then
        if jq -e 'has("zones") and (.zones | type == "array")' <<<"${json}" >/dev/null 2>&1; then
            jq -c '.zones[]' <<<"${json}"
        elif jq -e 'has("rrsets") and (.rrsets | type == "array")' <<<"${json}" >/dev/null 2>&1; then
            jq -c '.rrsets[]' <<<"${json}"
        elif jq -e 'has("results") and (.results | type == "array")' <<<"${json}" >/dev/null 2>&1; then
            jq -c '.results[]' <<<"${json}"
        elif jq -e 'has("data") and (.data | type == "array")' <<<"${json}" >/dev/null 2>&1; then
            jq -c '.data[]' <<<"${json}"
        elif jq -e 'has("items") and (.items | type == "array")' <<<"${json}" >/dev/null 2>&1; then
            jq -c '.items[]' <<<"${json}"
        fi
    fi
}

gcore_collect_api_token() {
    local token=${GCORE_API_TOKEN:-}
    if [[ -z "${token}" ]]; then
        token=$(prompt_secret "Gcore API Token（仅当前进程使用，不落盘）") \
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
            die "无法获取 Gcore 官方 IPv4 段，且本机没有可回退的白名单"
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
        grep -Fxq "${cidr}" "${current}" && continue
        ufw allow proto tcp from "${cidr}" to any port 443 \
            comment "${GCORE_UFW_COMMENT}" >/dev/null \
            || die "添加 Gcore 回源 UFW 规则失败：${cidr}"
    done <"${next}"
    ufw reload >/dev/null || die "重载 Gcore 回源 UFW 规则失败"

    install -d -m 0700 "$(dirname "${GCORE_ORIGIN_IPS_FILE}")"
    install -m 0600 "${next}" "${GCORE_ORIGIN_IPS_FILE}"

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${next}" && continue
        ufw delete allow proto tcp from "${cidr}" to any port 443 \
            comment "${GCORE_UFW_COMMENT}" >/dev/null \
            || warn "删除过期 Gcore 回源 UFW 规则失败：${cidr}"
    done <"${current}"
    ufw reload >/dev/null || die "重载 Gcore 回源 UFW 规则失败"
}

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

gcore_uploaded_certificate_id() {
    local endpoint=$1 payload=$2 name certificates certificate_id response
    name=$(jq -er '.name' <<<"${payload}") || return 1
    certificates=$(gcore_api_request GET "${endpoint}") || return 1
    certificate_id=$(gcore_json_items "${certificates}" | jq -sr --arg name "${name}" '
        first(.[] | select(.name == $name and .deleted != true) | .id) // empty')
    if [[ -n "${certificate_id}" ]]; then
        [[ "${certificate_id}" =~ ^[1-9][0-9]*$ ]] || die "Gcore 返回无效的证书 ID"
        # Reinstallation may generate a new client key; update the existing object.
        if [[ "${endpoint}" == "/cdn/sslData" ]]; then
            gcore_api_request PUT "${endpoint}/${certificate_id}" "${payload}" >/dev/null || return 1
        fi
    else
        response=$(gcore_api_request POST "${endpoint}" "${payload}") || return 1
        certificate_id=$(jq -r '.id // empty' <<<"${response}")
        if [[ -z "${certificate_id}" ]]; then
            certificates=$(gcore_api_request GET "${endpoint}") || return 1
            certificate_id=$(gcore_json_items "${certificates}" | jq -sr --arg name "${name}" '
                first(.[] | select(.name == $name and .deleted != true) | .id) // empty')
        fi
    fi
    [[ "${certificate_id}" =~ ^[1-9][0-9]*$ ]] || die "无法获取 Gcore 证书 ID：${name}"
    printf '%s' "${certificate_id}"
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
        '{name:$name,sslCertificate:$cert,sslPrivateKey:$key,validate_root_ca:false}')
    GCORE_ORIGIN_CLIENT_CERT_ID=$(gcore_uploaded_certificate_id "/cdn/sslData" "${cert_payload}") || return 1

    # 2. Upload Let'\''s Encrypt intermediate/root CA to Gcore (/cdn/sslCertificates)
    local issuer_ca_file="${RUNTIME_TMP}/issuer_ca.crt"
    # Extract CA certificate chain (all except the first server leaf cert)
    awk 'BEGIN {c=0} /BEGIN CERTIFICATE/ {c++} c>1 {print}' "${GCORE_CERT_FILE}" >"${issuer_ca_file}"
    [[ -s "${issuer_ca_file}" ]] || install -m 0644 "${GCORE_CERT_FILE}" "${issuer_ca_file}"

    # Trusted CA contents cannot be replaced through the API; version the name by chain.
    ca_name="${ca_name}-$(openssl dgst -sha256 "${issuer_ca_file}" | awk '{print $NF}')"
    ca_payload=$(jq -cn \
        --arg name "${ca_name}" \
        --arg cert "$(<"${issuer_ca_file}")" \
        '{name:$name,sslCertificate:$cert}')
    GCORE_ORIGIN_CA_ID=$(gcore_uploaded_certificate_id "/cdn/sslCertificates" "${ca_payload}") || return 1
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
      use_next: false,
      sources: [{source: $source, enabled: true, backup: false}]
    }')
    response=$(gcore_api_request POST "/cdn/origin_groups" "${payload}")
    GCORE_ORIGIN_GROUP_ID=$(jq -er '.id // empty' <<<"${response}")
}

gcore_edge_certificate_id() {
    local name="easy_all-edge-${VLESS_CDN_DOMAIN}" certificates certificate_id response attempt
    certificates=$(gcore_api_request GET "/cdn/sslData") || return 1
    certificate_id=$(gcore_json_items "${certificates}" | jq -sr --arg name "${name}" '
        first(.[] | select(.name == $name and .automated == true and .deleted != true) | .id) // empty')
    if [[ -z "${certificate_id}" ]]; then
        response=$(gcore_api_request POST "/cdn/sslData" \
            "$(jq -cn --arg name "${name}" '{name:$name,automated:true}')") || return 1
        certificate_id=$(jq -r '.id // empty' <<<"${response}")
        # Some API versions return an empty creation response and expose the object asynchronously.
        if [[ -z "${certificate_id}" ]]; then
            for ((attempt = 1; attempt <= 12; attempt += 1)); do
                certificates=$(gcore_api_request GET "/cdn/sslData") || return 1
                certificate_id=$(gcore_json_items "${certificates}" | jq -sr --arg name "${name}" '
                    first(.[] | select(.name == $name and .automated == true and .deleted != true) | .id) // empty')
                [[ -n "${certificate_id}" ]] && break
                sleep 5
            done
        fi
    fi
    [[ "${certificate_id}" =~ ^[1-9][0-9]*$ ]] || die "无法获取 Gcore 边缘 HTTPS 证书 ID"
    printf '%s' "${certificate_id}"
}

gcore_resolve_edge_certificate_id_for_purge() {
    local resource certificates candidate status
    [[ "${GCORE_EDGE_CERTIFICATE_ID:-}" =~ ^[1-9][0-9]*$ ]] && return 0
    if [[ "${GCORE_CDN_RESOURCE_ID:-}" =~ ^[1-9][0-9]*$ ]]; then
        if resource=$(gcore_api_get_optional \
            "/cdn/resources/${GCORE_CDN_RESOURCE_ID}"); then
            candidate=$(jq -r '.sslData // empty' <<<"${resource}")
            if [[ "${candidate}" =~ ^[1-9][0-9]*$ ]]; then
                GCORE_EDGE_CERTIFICATE_ID=${candidate}
                return 0
            fi
        else
            status=$?
            ((status == 4)) || return 1
        fi
    fi
    certificates=$(gcore_api_request GET "/cdn/sslData") || return 1
    candidate=$(gcore_json_items "${certificates}" | jq -sr \
        --arg name "easy_all-edge-${VLESS_CDN_DOMAIN}" '
        first(.[] | select(
          .name == $name and .automated == true and .deleted != true
        ) | .id) // empty')
    if [[ "${candidate}" =~ ^[1-9][0-9]*$ ]]; then
        GCORE_EDGE_CERTIFICATE_ID=${candidate}
    fi
}

gcore_wait_for_edge_certificate() {
    local certificate_id=$1 attempt state status details
    for ((attempt = 1; attempt <= GCORE_EDGE_PROPAGATION_ATTEMPTS; attempt += 1)); do
        state=$(gcore_api_request GET "/cdn/sslData/${certificate_id}/status") \
            || die "无法读取 Gcore 边缘证书签发状态"
        status=$(jq -r '
            if (.latest_status.status? // "") != "" then
                .latest_status.status | ascii_upcase
            elif .active == true then "ACTIVE"
            else "PENDING"
            end
        ' <<<"${state}")
        case "${status}" in
        ACTIVE | DONE) return 0 ;;
        FAILED | CANCELLED)
            details=$(jq -c '{
                error:(.latest_status.error // null),
                details:(.latest_status.details // null)
            }' <<<"${state}")
            die "Gcore 边缘证书签发 ${status}：${details}"
            ;;
        esac
        ((attempt == GCORE_EDGE_PROPAGATION_ATTEMPTS)) \
            || sleep "${GCORE_EDGE_PROPAGATION_INTERVAL}"
    done
    die "Gcore 边缘证书等待超时：ID=${certificate_id}，状态=${status:-unknown}"
}

gcore_resource_matches_payload() {
    local resource=$1 payload=$2
    jq -en --argjson actual "${resource}" --argjson desired "${payload}" '
      def normalized:
        {
          cname,
          secondaryHostnames: ((.secondaryHostnames // []) | sort),
          originGroup,
          originProtocol,
          active,
          sslEnabled,
          sslData,
          proxy_ssl_enabled,
          proxy_ssl_data,
          proxy_ssl_ca,
          options: {
            allowedHttpMethods: {
              enabled: .options.allowedHttpMethods.enabled,
              value: ((.options.allowedHttpMethods.value // []) | sort)
            },
            websockets: .options.websockets,
            hostHeader: .options.hostHeader,
            redirect_http_to_https: .options.redirect_http_to_https,
            use_dns01_le_challenge: .options.use_dns01_le_challenge,
            sni: .options.sni,
            proxy_connect_timeout: .options.proxy_connect_timeout,
            edge_cache_settings: .options.edge_cache_settings,
            browser_cache_settings: .options.browser_cache_settings,
            ignoreQueryString: .options.ignoreQueryString,
            slice: .options.slice,
            tls_versions: {
              enabled: .options.tls_versions.enabled,
              value: ((.options.tls_versions.value // []) | sort)
            }
          }
        };
      ($actual | normalized) == ($desired | normalized)
    ' >/dev/null
}

gcore_ensure_resource() {
    local payload bootstrap_payload response existing_resources current_resource res subscription_domain
    local resource_id="" edge_certificate_id=""
    local certificate_needs_binding=0
    GCORE_CDN_RESOURCE_CHANGED=0
    subscription_domain=$(active_subscription_link_domain)
    existing_resources=$(gcore_api_request GET "/cdn/resources") || return 1
    while IFS= read -r res; do
        [[ -n "${res}" ]] || continue
        if [[ "$(jq -r '.cname // empty' <<<"${res}")" == "${VLESS_CDN_DOMAIN}" ]]; then
            resource_id=$(jq -er '.id' <<<"${res}") || return 1
            edge_certificate_id=$(jq -r '.sslData // empty' <<<"${res}")
            break
        fi
    done < <(gcore_json_items "${existing_resources}")
    if [[ ! "${edge_certificate_id}" =~ ^[1-9][0-9]*$ ]]; then
        edge_certificate_id=$(gcore_edge_certificate_id) || return 1
        certificate_needs_binding=1
    fi
    GCORE_EDGE_CERTIFICATE_ID=${edge_certificate_id}
    payload=$(jq -cn \
        --arg cname "${VLESS_CDN_DOMAIN}" \
        --arg subscription "${subscription_domain}" \
        --argjson origin_group "${GCORE_ORIGIN_GROUP_ID}" \
        --arg origin "${GCORE_ORIGIN_DOMAIN}" \
        --argjson client_cert_id "${GCORE_ORIGIN_CLIENT_CERT_ID}" \
        --argjson origin_ca_id "${GCORE_ORIGIN_CA_ID}" \
        --argjson edge_certificate_id "${edge_certificate_id}" '{
          cname: $cname,
          secondaryHostnames: (if $subscription == $cname then [] else [$subscription] end),
          originGroup: $origin_group,
          originProtocol: "HTTPS",
          active: true,
          sslEnabled: true,
          sslData: $edge_certificate_id,
          proxy_ssl_enabled: true,
          proxy_ssl_data: $client_cert_id,
          proxy_ssl_ca: $origin_ca_id,
          options: {
            allowedHttpMethods: {enabled: true, value: ["GET", "HEAD"]},
            websockets: {enabled: true, value: true},
            hostHeader: {enabled: true, value: $origin},
            redirect_http_to_https: {enabled: true, value: true},
            use_dns01_le_challenge: {enabled: true, value: true},
            sni: {enabled: true, sni_type: "custom", custom_hostname: $origin},
            proxy_connect_timeout: {enabled: true, value: "5s"},
            edge_cache_settings: {enabled: true, value: "0s", custom_values: {}},
            browser_cache_settings: {enabled: true, value: "0s"},
            ignoreQueryString: {enabled: true, value: false},
            slice: {enabled: true, value: false},
            tls_versions: {enabled: true, value: ["TLSv1.2", "TLSv1.3"]}
          }
        }')
    bootstrap_payload=$(jq -c '
        .options.redirect_http_to_https = {enabled:false,value:false}
    ' <<<"${payload}")

    if [[ -n "${resource_id}" ]]; then
        GCORE_CDN_RESOURCE_ID=${resource_id}
        current_resource=$(gcore_api_request GET \
            "/cdn/resources/${GCORE_CDN_RESOURCE_ID}") || return 1
        if gcore_resource_matches_payload "${current_resource}" "${payload}"; then
            info "Gcore CDN 资源 (ID: ${GCORE_CDN_RESOURCE_ID}) 配置未变化，跳过更新"
        else
            info "更新已有 Gcore CDN 资源 (ID: ${GCORE_CDN_RESOURCE_ID}) 的 HTTPS、mTLS 与配置"
            if ((certificate_needs_binding == 1)); then
                gcore_api_request PUT \
                    "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${bootstrap_payload}" >/dev/null \
                    || return 1
            fi
            gcore_wait_for_edge_certificate "${edge_certificate_id}"
            gcore_api_request PUT \
                "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null || return 1
            GCORE_CDN_RESOURCE_CHANGED=1
        fi
    else
        response=$(gcore_api_request POST "/cdn/resources" "${bootstrap_payload}") || return 1
        GCORE_CDN_RESOURCE_ID=$(jq -er '.id // empty' <<<"${response}") || return 1
        gcore_wait_for_edge_certificate "${edge_certificate_id}"
        gcore_api_request PUT \
            "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null || return 1
        GCORE_CDN_RESOURCE_CHANGED=1
    fi
    if ((GCORE_CDN_RESOURCE_CHANGED == 1)); then
        info "Gcore 边缘 HTTPS 已配置；配置与新证书可能需要等待边缘传播"
    fi
}

gcore_purge_managed_resources() {
    local purge_failed=0
    gcore_collect_api_token
    if ! gcore_resolve_edge_certificate_id_for_purge; then
        warn "无法识别 easy_all 托管的 Gcore 边缘证书"
        purge_failed=1
    fi
    [[ -z "${GCORE_CDN_RESOURCE_ID:-}" ]] \
        || gcore_api_delete_optional "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
            || purge_failed=1
    [[ -z "${GCORE_ORIGIN_GROUP_ID:-}" ]] \
        || gcore_api_delete_optional "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}" \
            || purge_failed=1
    [[ -z "${GCORE_ORIGIN_CLIENT_CERT_ID:-}" ]] \
        || gcore_api_delete_optional "/cdn/sslData/${GCORE_ORIGIN_CLIENT_CERT_ID}" \
            || purge_failed=1
    [[ -z "${GCORE_EDGE_CERTIFICATE_ID:-}" ]] \
        || gcore_api_delete_optional "/cdn/sslData/${GCORE_EDGE_CERTIFICATE_ID}" \
            || purge_failed=1
    [[ -z "${GCORE_ORIGIN_CA_ID:-}" ]] \
        || gcore_api_delete_optional "/cdn/sslCertificates/${GCORE_ORIGIN_CA_ID}" \
            || purge_failed=1
    gcore_purge_managed_dns_records || purge_failed=1
    gcore_clear_api_token
    ((purge_failed == 0))
}

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
