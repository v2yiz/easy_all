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

    # 不能拿缓存文件当作“规则还在”的证明（回滚/手工改过 UFW 后缓存仍完整）。ufw 对完全
    # 相同的规则是幂等的（输出 Skipping），所以每次都对全部期望 CIDR 重新放行。
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
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

# 边缘证书一旦进入 FAILED，Gcore 不会自行重签；重新安装会读回同一个失败状态并立即终止。
# 用官方 force-retry 入口重试（次数/间隔由 Profile 常量控制），避免在真实配置错误上反复消耗重试额度。
gcore_force_retry_edge_certificate() {
    local certificate_id=$1 response http_code body
    response=$(gcore_api_raw POST "/cdn/sslData/${certificate_id}/force-retry") || return 1
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    if [[ ! "${http_code}" =~ ^2[0-9]{2}$ ]]; then
        printf '%s\n' "${body:-<empty>}" >&2
        return 1
    fi
}

gcore_edge_certificate_failure_details() {
    jq -c '{
        error:(.latest_status.error // null),
        details:(.latest_status.details // null)
    }' <<<"$1"
}

gcore_edge_certificate_status() {
    local certificate_id=$1 state
    state=$(gcore_api_request GET "/cdn/sslData/${certificate_id}/status") \
        || die "无法读取 Gcore 边缘证书签发状态"
    jq -r '
        if (.latest_status.status? // "") != "" then
            .latest_status.status | ascii_upcase
        elif .active == true then "ACTIVE"
        else "PENDING"
        end
    ' <<<"${state}"
}

gcore_edge_certificate_hint() {
    printf '（组合模式用 HTTP-01 签发：需要资源上存在来自系统模板的 "Let'\''s Encrypt HTTP-01 challenge" 规则，安装器会自动创建；另确认 %s 的灰云 CNAME 指向 Gcore 并已传播，CDN 资源新建后最长要约 15 分钟才会在所有边缘生效。残留的失败证书可先执行 sudo easy_all purge-gcore --domain %s,%s）' \
        "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" "${GCORE_ORIGIN_DOMAIN}"
}

# Gcore 的 HTTP-01 默认不会在边缘直接应答，必须在资源上创建来自系统模板
# "Let's Encrypt HTTP-01 challenge" 的规则（路径 /.well-known/acme-challenge/）；否则请求会被回源，
# 而我们的源站要求 mTLS，边缘只能拿到 502（现场报错）。参考 Gcore 文档「Create and use CDN rule templates」。
GCORE_LE_RULE_NAME="Let's Encrypt HTTP-01 challenge"
# 可复用的规则必须：路径根就是 /.well-known/acme-challenge（带目录边界，排除 -backup 之类）、
# ruleType 0、未被禁用。名字相同但路径/类型不符则终止，由用户删除或修正。

gcore_ensure_le_http01_rule() {
    local rules existing fixable by_name templates template payload response rule_id
    rules=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}/rules") || return 1
    existing=$(gcore_json_items "${rules}" | jq -sr --arg name "${GCORE_LE_RULE_NAME}" '
        def le_path: ((.rule // "") | sub("^\\^"; "") | test("^/\\.well-known/acme-challenge(/|$)"));
        first(.[] | select(.deleted != true and .active != false
            and ((.ruleType // 0) == 0) and le_path) | .id) // empty')
    if [[ -n "${existing}" ]]; then
        GCORE_LE_RULE_ID=${existing}
        info "Gcore HTTP-01 验证规则已存在（ID ${existing}），跳过创建"
        return 0
    fi
    # 路径对但被禁用（ruleType 0）的规则可以原地启用，不新建一个同名/同路径冲突的对象。
    fixable=$(gcore_json_items "${rules}" | jq -sr '
        def le_path: ((.rule // "") | sub("^\\^"; "") | test("^/\\.well-known/acme-challenge(/|$)"));
        first(.[] | select(.deleted != true and le_path) | select((.ruleType // 0) == 0)) // empty')
    if [[ -n "${fixable}" ]]; then
        rule_id=$(jq -r '.id // empty' <<<"${fixable}")
        payload=$(jq -c '{rule, ruleType: (.ruleType // 0), active: true}
            + (if .name then {name} else {} end)' <<<"${fixable}")
        gcore_api_request PUT "/cdn/resources/${GCORE_CDN_RESOURCE_ID}/rules/${rule_id}" \
            "${payload}" >/dev/null || return 1
        GCORE_LE_RULE_ID=${rule_id}
        info "已启用资源上被禁用的 HTTP-01 验证规则（ID ${rule_id}）"
        return 0
    fi
    # 名字相同但路径/类型不对：不静默复用，也不硬删别人的规则。
    by_name=$(gcore_json_items "${rules}" | jq -sr --arg name "${GCORE_LE_RULE_NAME}" '
        first(.[] | select(.deleted != true and .name == $name) | .id) // empty')
    if [[ -n "${by_name}" ]]; then
        die "资源上已有同名规则「${GCORE_LE_RULE_NAME}」（ID ${by_name}），但路径不是 /.well-known/acme-challenge 或 ruleType 不是 0；请删除或修正后再试"
    fi
    templates=$(gcore_api_request GET "/cdn/resources/rule_templates?limit=100") || return 1
    template=$(gcore_json_items "${templates}" | jq -sr --arg name "${GCORE_LE_RULE_NAME}" '
        first(.[] | select(.name == $name)) // empty')
    [[ -n "${template}" ]] || die "Gcore 账户没有系统规则模板「${GCORE_LE_RULE_NAME}」，HTTP-01 证书无法签发"
    payload=$(jq -c --arg name "${GCORE_LE_RULE_NAME}" '{
        name: $name,
        rule: (.rule // "/.well-known/acme-challenge/"),
        ruleType: 0,
        active: true,
        weight: 1
    } + (if .options then {options: .options} else {} end)' <<<"${template}")
    response=$(gcore_api_request POST "/cdn/resources/${GCORE_CDN_RESOURCE_ID}/rules" "${payload}") || return 1
    rule_id=$(jq -r '.id // empty' <<<"${response}")
    [[ "${rule_id}" =~ ^[1-9][0-9]*$ ]] || die "创建 Gcore HTTP-01 验证规则失败"
    GCORE_LE_RULE_ID=${rule_id}
    info "已创建 Gcore HTTP-01 验证规则（ID ${rule_id}），证书验证由 Gcore 边缘自己应答"
}

# 规则刚创建时边缘配置可能还在下发；用 Gcore 的 pre-validate 接口探活，通过后再重试证书，
# 避免白白消耗 force-retry。预检不可用或超时时只告警，不阻断后续签发尝试。
gcore_wait_for_le_prevalidation() {
    local attempts=${1:-20}
    local interval=${2:-15}
    local attempt response code body details="" start=${SECONDS}
    for ((attempt = 1; attempt <= attempts; attempt += 1)); do
        if ! response=$(gcore_api_raw POST "/cdn/resources/${GCORE_CDN_RESOURCE_ID}/ssl/le/pre-validate"); then
            warn "HTTP-01 预检请求失败（网络错误）；继续尝试签发"
            return 0
        fi
        code=${response##*$'\n'}
        body=${response%$'\n'*}
        case "${code}" in
        200 | 201 | 204) return 0 ;;
        400)
            details=$(jq -c '.errors // .' <<<"${body}" 2>/dev/null || printf '%s' "${body}")
            ;;
        *)
            warn "HTTP-01 预检返回 HTTP ${code:-未知}；继续尝试签发"
            return 0
            ;;
        esac
        if ((attempt == 1 || attempt % 4 == 0)); then
            info "等待 Gcore HTTP-01 验证路径就绪（已等待 $((SECONDS - start)) 秒）：${details}"
        fi
        ((attempt == attempts)) || sleep "${interval}"
    done
    warn "HTTP-01 预检在 $((attempts * interval / 60)) 分钟内仍未通过；继续尝试签发，失败时会给出提示"
    return 0
}

# 新建的 Gcore 资源会处于 processed 状态约 15 分钟，这期间边缘还没接流量，HTTP-01 必然失败。
# 先等资源变成 active、且节点 CNAME 已解析到账户 CNAME，再申请或重试证书。
gcore_wait_for_cdn_readiness() {
    local attempts=${1:-${GCORE_EDGE_READY_ATTEMPTS}}
    local interval=${2:-${GCORE_EDGE_READY_INTERVAL}}
    local attempt status cname expected observed_cname="未解析" observed_status="unknown"
    local start=${SECONDS}
    expected=$(normalize_domain "${GCORE_CDN_TARGET:-}")
    for ((attempt = 1; attempt <= attempts; attempt += 1)); do
        status=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
            | jq -r '.status // (if .active == true then "active" else "unknown" end)') \
            || return 1
        cname=$(dig +short CNAME "${VLESS_CDN_DOMAIN}" @1.1.1.1 2>/dev/null \
            | sed 's/\.$//' | tr '[:upper:]' '[:lower:]' | sort -u | head -n 1 || true)
        [[ -z "${cname}" ]] || observed_cname=${cname}
        [[ -z "${status}" ]] || observed_status=${status}
        if [[ "${status}" == "active" ]] \
            && { [[ -z "${expected}" ]] || [[ "${cname}" == "${expected}" ]]; }; then
            return 0
        fi
        # 每约 60 秒打印一次进度：长时间无输出容易被当成卡死，定时写终端也有助于保活。
        if ((attempt == 1 || attempt % 4 == 0)); then
            info "等待 Gcore 边缘就绪（已等待 $((SECONDS - start)) 秒；资源=${observed_status}；${VLESS_CDN_DOMAIN} 的 CNAME=${observed_cname}，期望 ${expected:-未知}）：第 ${attempt}/${attempts} 次"
        fi
        ((attempt == attempts)) || sleep "${interval}"
    done
    die "Gcore 边缘在 $((attempts * interval / 60)) 分钟内未就绪（已等待 $((SECONDS - start)) 秒；资源=${observed_status}；${VLESS_CDN_DOMAIN} 的 CNAME=${observed_cname}，期望 ${expected:-未知}）。请确认灰云 CNAME 与 Gcore 账户 CNAME 一致，稍后重试安装$(gcore_edge_certificate_hint)"
}

gcore_wait_for_edge_certificate() {
    local certificate_id=$1
    local attempts=${2:-${GCORE_EDGE_PROPAGATION_ATTEMPTS}}
    local interval=${3:-${GCORE_EDGE_PROPAGATION_INTERVAL}}
    local attempt state status details retries=0
    local start=${SECONDS}
    for ((attempt = 1; attempt <= attempts; attempt += 1)); do
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
        CANCELLED)
            details=$(gcore_edge_certificate_failure_details "${state}")
            die "Gcore 边缘证书签发 CANCELLED：${details}$(gcore_edge_certificate_hint)"
            ;;
        FAILED)
            details=$(gcore_edge_certificate_failure_details "${state}")
            if ((retries >= GCORE_EDGE_FORCE_RETRIES)); then
                die "Gcore 边缘证书签发 FAILED：${details}$(gcore_edge_certificate_hint)"
            fi
            retries=$((retries + 1))
            info "Gcore 边缘证书签发失败，第 ${retries}/${GCORE_EDGE_FORCE_RETRIES} 次强制重试：${details}"
            gcore_force_retry_edge_certificate "${certificate_id}" \
                || warn "Gcore 未接受强制重试请求；继续等待签发状态"
            sleep "${GCORE_EDGE_FORCE_RETRY_INTERVAL}"
            continue
            ;;
        esac
        # 签发阶段可能持续十几分钟，每约 60 秒打印一次进度，避免看起来像卡死。
        if ((attempt == 1 || attempt % 6 == 0)); then
            info "等待 Gcore 边缘证书签发（状态=${status}，已等待 $((SECONDS - start)) 秒）：第 ${attempt}/${attempts} 次"
        fi
        ((attempt == attempts)) || sleep "${interval}"
    done
    die "Gcore 边缘证书等待超时：ID=${certificate_id}，状态=${status:-unknown}，已等待 $((SECONDS - start)) 秒$(gcore_edge_certificate_hint)"
}

# 证书已经 ACTIVE 时直接返回，避免幂等重跑去等边缘就绪；否则先等资源/CNAME 就绪再申请或重试。
# 就绪检查或状态读取失败必须向上传播，不能再拿未确认就绪的状态去 force-retry。
gcore_ensure_edge_certificate_ready() {
    local certificate_id=$1 status
    # 规则必须存在：续期也靠它，所以证书已 ACTIVE 时也要核对/补齐。
    gcore_ensure_le_http01_rule || return 1
    status=$(gcore_edge_certificate_status "${certificate_id}") || return 1
    if [[ "${status}" != "ACTIVE" && "${status}" != "DONE" ]]; then
        gcore_wait_for_cdn_readiness || return 1
        gcore_wait_for_le_prevalidation
    fi
    gcore_wait_for_edge_certificate "${certificate_id}"
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
    local payload bootstrap_payload response existing_resources current_resource res
    local resource_id="" edge_certificate_id=""
    GCORE_CDN_RESOURCE_CHANGED=0
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
    fi
    GCORE_EDGE_CERTIFICATE_ID=${edge_certificate_id}
    # 组合模式的 Zone 留在 Cloudflare，没有把 _acme-challenge 委派给 Gcore，DNS-01 必然失败；
    # 订阅域名是橙云 A 指向 VPS，Gcore 也无法用 HTTP-01 验证它，因此边缘证书只覆盖节点域名。
    # 订阅域名继续使用本机 Cloudflare Origin CA 证书。
    payload=$(jq -cn \
        --arg cname "${VLESS_CDN_DOMAIN}" \
        --argjson origin_group "${GCORE_ORIGIN_GROUP_ID}" \
        --arg origin "${GCORE_ORIGIN_DOMAIN}" \
        --argjson client_cert_id "${GCORE_ORIGIN_CLIENT_CERT_ID}" \
        --argjson origin_ca_id "${GCORE_ORIGIN_CA_ID}" \
        --argjson edge_certificate_id "${edge_certificate_id}" '{
          cname: $cname,
          secondaryHostnames: [],
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
            use_dns01_le_challenge: {enabled: false, value: false},
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
            # 先落 HTTP-01 与域名集合，Gcore 才会按新配置重新签发；否则重试仍用旧挑战方式。
            gcore_api_request PUT \
                "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${bootstrap_payload}" >/dev/null \
                || return 1
            GCORE_CDN_RESOURCE_CHANGED=1
        fi
        # 配置未变化时也要确认证书状态：上次失败的证书不会自行重签；资源刚创建时边缘还没生效，
        # 先等就绪再判断/重试，避免把“还没激活”当成永久失败。
        gcore_ensure_edge_certificate_ready "${edge_certificate_id}" || return 1
        if ((GCORE_CDN_RESOURCE_CHANGED == 1)); then
            gcore_api_request PUT \
                "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null || return 1
        fi
    else
        response=$(gcore_api_request POST "/cdn/resources" "${bootstrap_payload}") || return 1
        GCORE_CDN_RESOURCE_ID=$(jq -er '.id // empty' <<<"${response}") || return 1
        gcore_ensure_edge_certificate_ready "${edge_certificate_id}" || return 1
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
    local archive_file temp_dir source_dir
    # ACME_HOME 可能来自上次失败安装（回滚刻意保留证书缓存），此时补所有权标记与自动续期任务。
    if [[ ! -x "${ACME_BIN}" ]]; then
        archive_file=$(make_temp_dir)/acme.sh.tar.gz
        temp_dir=$(make_temp_dir)/acme-extract
        download_https_file \
            "https://github.com/acmesh-official/acme.sh/archive/refs/tags/3.1.0.tar.gz" \
            "${archive_file}" "acme.sh"
        mkdir -p "${temp_dir}"
        tar -xzf "${archive_file}" -C "${temp_dir}"
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
    else
        # 续期任务必须显式补回：安装前快照在 acme.sh 安装之前拍摄，回滚会用该快照覆盖 root
        # crontab（restore_preinstall_crontab），把首次安装写进去的 acme.sh --cron 条目一起删掉；
        # 重试走这条复用分支不会重装 acme.sh，续期任务就会永久缺失，证书到期后 Gcore 回源 TLS 失效。
        # 该入口幂等：crontab 里已有 --cron 条目时只读取后返回，不会追加第二条。
        run_acme --install-cronjob >/dev/null 2>&1 \
            || warn "恢复 acme.sh 自动续期任务失败，证书到期不会自动续签；装好 cron 后执行 sudo ${ACME_BIN} --home ${ACME_HOME} --config-home ${ACME_HOME}/data --cert-home ${ACME_HOME}/certs --install-cronjob"
    fi
    mkdir -p "$(dirname "${ACME_OWNERSHIP_MARKER}")"
    touch "${ACME_OWNERSHIP_MARKER}"
    gcore_sync_acme_cf_token
}

# acme.sh 的 --issue 在缓存证书仍有效时会跳过整个 DNS 挑战（RENEW_SKIP），dns_cf 也就不会把当前
# Cloudflare Token 写回 account.conf；而定时续期只读 account.conf。每次安装时同步一次，
# 避免换了 Token 后续期仍用已撤销的旧 Token。acme.sh 固定 3.1.0，键名 SAVED_CF_Token 稳定。
gcore_sync_acme_cf_token() {
    local token=${CLOUDFLARE_API_TOKEN:-}
    local conf=${GCORE_ACME_ACCOUNT_CONF:-${ACME_HOME}/data/account.conf}
    local tmp saved
    [[ -n "${token}" && -f "${conf}" ]] || return 0
    [[ "${token}" =~ ^[A-Za-z0-9._~-]+$ ]] || return 0
    saved=$(sed -n "s/^SAVED_CF_Token='\(.*\)'$/\1/p" "${conf}" | tail -n 1)
    [[ "${saved}" != "${token}" ]] || return 0
    if ! tmp=$(mktemp "${conf}.XXXXXX"); then
        warn "无法在 ${conf} 旁创建临时文件；续期可能继续使用旧 Cloudflare Token"
        return 0
    fi
    # Token 通过子进程环境传递，不能放进 awk 的 argv（ps/proc cmdline 对同机用户可见）。
    if CF_TOKEN="${token}" awk -v q="'" '
        /^SAVED_CF_Token=/ { print "SAVED_CF_Token=" q ENVIRON["CF_TOKEN"] q; seen = 1; next }
        { print }
        END { if (!seen) print "SAVED_CF_Token=" q ENVIRON["CF_TOKEN"] q }
    ' "${conf}" >"${tmp}"; then
        chmod 0600 "${tmp}"
        if mv -f -- "${tmp}" "${conf}"; then
            info "已把当前 Cloudflare Token 同步到 acme.sh 续期配置"
            return 0
        fi
    fi
    rm -f -- "${tmp}"
    warn "更新 ${conf} 中的 Cloudflare Token 失败；续期可能继续使用旧 Token"
}

run_acme() {
    "${ACME_BIN}" --home "${ACME_HOME}" \
        --config-home "${ACME_HOME}/data" \
        --cert-home "${ACME_HOME}/certs" "$@"
}
