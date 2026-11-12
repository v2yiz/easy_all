#!/usr/bin/env bash

# Cloudflare API, DNS, Origin CA and origin-firewall helpers shared by both profiles.
# Profile-specific contracts provided by the caller: CLOUDFLARE_UFW_COMMENT,
# CLOUDFLARE_UFW_PORT, CLOUDFLARE_ORIGIN_CA_ROOT_FILE, CLOUDFLARE_ORIGIN_DOMAIN,
# plus cloudflare_origin_certificate_hosts when the certificate needs several names.

: "${CLOUDFLARE_API_BASE:=https://api.cloudflare.com/client/v4}"

# Cloudflare API Token 持久路径与事务（五模式共用，design §5/§6）：
# Token 不写入 state，单独 0600 同目录原子保存；读取只服务于后续维护命令，
# 失败与日志都不得回显 Token。
: "${CLOUDFLARE_TOKEN_FILE:=${STATE_DIR:-/etc/easy_all}/cloudflare.token}"

cloudflare_token_file() {
    printf '%s\n' "${CLOUDFLARE_TOKEN_FILE}"
}

# 20–512 位 URL 安全字符；bash 3.2 不接受 >255 的区间量词，所以分开判长度。
cloudflare_token_format_valid() {
    # set -u 下 CLOUDFLARE_API_TOKEN 可能未定义，必须先给默认值再取长度。
    local token=${CLOUDFLARE_API_TOKEN:-}
    [[ ${#token} -ge 20 && ${#token} -le 512 && "${token}" =~ ^[A-Za-z0-9_-]+$ ]]
}

# 优先复用已持久化的 Token（下一进程/维护命令），否则交互输入。
# 可选参数是本模式需要的最小权限文案：只能在真正需要时多加权限（design §9）。
cloudflare_collect_api_token() {
    local label=${1:-'Cloudflare API Token（Zone 只读 + DNS 编辑）'} file
    file=$(cloudflare_token_file)
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -s "${file}" ]]; then
        CLOUDFLARE_API_TOKEN=$(<"${file}")
    fi
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        prompt_secret_into CLOUDFLARE_API_TOKEN "${label}" \
            || die '缺少 Cloudflare API Token'
    fi
    cloudflare_token_format_valid || die "Cloudflare Token 格式无效"
}

# 0600 同目录原子写：失败不留下半截文件，也不把 Token 写进 state 或日志。
persist_cloudflare_token() {
    local file dir temp
    cloudflare_token_format_valid || die "Cloudflare Token 格式无效；未落盘"
    file=$(cloudflare_token_file)
    dir=$(dirname -- "${file}")
    install -d -m 0700 "${dir}" || die "创建 Cloudflare Token 目录失败：${dir}"
    temp=$(mktemp "${file}.XXXXXX") || die "创建 Cloudflare Token 暂存文件失败"
    declare -p cleanup_files >/dev/null 2>&1 && cleanup_files+=("${temp}")
    if ! (umask 077; printf '%s\n' "${CLOUDFLARE_API_TOKEN}" >"${temp}") \
        || ! chmod 0600 "${temp}" \
        || ! mv -f -- "${temp}" "${file}"; then
        rm -f -- "${temp}"
        die "保存 Cloudflare Token 失败：${file}"
    fi
}

cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" "${RUNTIME_TMP}/cloudflare-api-payload"
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

cloudflare_remove_origin_firewall_rules() {
    # 按完整规则规格删除：status 编号只用于发现端口与来源 CIDR，不用于删除（Fail2ban 插入会让编号漂移）。
    delete_stale_ufw_rules "${CLOUDFLARE_UFW_COMMENT}" \
        || { warn "删除 Cloudflare 回源 UFW 规则未完成；请人工核对 ufw status"
             return 1; }
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
        ufw allow proto tcp from "${cidr}" to any port "${CLOUDFLARE_UFW_PORT}" \
            comment "${CLOUDFLARE_UFW_COMMENT}" >/dev/null \
            || die "添加 Cloudflare 回源 UFW 规则失败：${cidr}"
    done <"${next}"
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        ufw_tcp_port_is_allowed "${CLOUDFLARE_UFW_PORT}" "${cidr}" \
            || die "UFW 未有效放行 Cloudflare 回源：${cidr}"
    done <"${next}"

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${next}" && continue
        ufw --force delete allow proto tcp from "${cidr}" to any port "${CLOUDFLARE_UFW_PORT}" \
            >/dev/null || warn "删除过期 Cloudflare 回源规则失败：${cidr}"
    done <"${current}"
    install -d -m 0700 "$(dirname "${CLOUDFLARE_ORIGIN_IPS_FILE}")"
    install -m 0600 "${next}" "${CLOUDFLARE_ORIGIN_IPS_FILE}"
    ufw reload >/dev/null || die "重载 UFW 失败"
}

# Zone 级 SSL/TLS 模式严格校验（design §9）：只读、不修改全区设置。
# 只有 value=strict 才继续；权限不足 403 与 full/flexible/off 都必须在此停止，
# 且必须发生在任何 DNS/证书/Origin Rule 写入之前。
cloudflare_ensure_zone_ssl_strict() {
    local zone_id=${1:-${CLOUDFLARE_ZONE_ID:-}} response value
    [[ -n "${zone_id}" ]] || die "缺少 Cloudflare Zone ID；无法校验 SSL 模式"
    response=$(cloudflare_api_request GET "/zones/${zone_id}/settings/ssl") || return 1
    value=$(jq -r '.value // empty' <<<"${response}") || value=""
    case "${value}" in
    strict) return 0 ;;
    "")
        die "Cloudflare Zone ${zone_id} 的 SSL 模式读取结果为空；请在控制台确认 SSL/TLS 为 Full (strict) 后重试"
        ;;
    *)
        die "Cloudflare Zone ${zone_id} 的 SSL 模式是 ${value}，本工具只支持 Full (strict)：请人工把 SSL/TLS 改为 Full (strict) 后重试（本工具不会自动修改全区设置）"
        ;;
    esac
}

cloudflare_lookup_parent_zone() {
    local domain=$1 candidate zone
    candidate=${domain}
    while [[ "${candidate}" == *.* ]]; do
        zone=$(cloudflare_api_request GET "/zones?name=${candidate}&status=active&per_page=50" | jq -r --arg name "${candidate}" '[.[] | select((.name|ascii_downcase)==($name|ascii_downcase)) | .id] | if length == 1 then .[0] else empty end')
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

# 第二参数为空串表示不限类型：调用方要按名字识别跨类型冲突。
cloudflare_record_list() {
    local type_filter=""
    [[ -z "${2:-}" ]] || type_filter="type=$2&"
    cloudflare_api_request GET "/zones/$1/dns_records?${type_filter}name=$3&per_page=100"
}

cloudflare_ensure_origin_ca_root() {
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

# 证书 SAN 里的 DNS 名（去重）：优先 -ext（OpenSSL 3），LibreSSL/OpenSSL 1.x 与 -text 格式退回解析
# X509v3 段。macOS 的 LibreSSL 既没 -ext 也没 -checkhost，所以两种模式都不得依赖它们。
cloudflare_certificate_san_hosts() {
    local cert=$1 san
    san=$(openssl x509 -in "${cert}" -noout -ext subjectAltName 2>/dev/null \
        | sed -n '2,$p' || true)
    [[ -n "${san}" ]] \
        || san=$(openssl x509 -in "${cert}" -noout -text 2>/dev/null \
            | awk '/X509v3 Subject Alternative Name/ {found = 1; next}
                   found && /^[[:space:]]*$/ {exit}
                   found && /^[[:space:]]*DNS:/ {print; next}
                   found {exit}' || true)
    printf '%s\n' "${san}" | tr ',' '\n' \
        | sed -n 's/^[[:space:]]*DNS://p' | sort -u || true
}

cloudflare_origin_certificate_is_current() {
    local expected_hosts actual_hosts cert_pub key_pub
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] || return 1
    openssl x509 -in "${CERT_FILE}" -checkend 2592000 -noout >/dev/null 2>&1 \
        || return 1
    # SAN 集合精确比对已经等于逐域名覆盖检查，不再依赖 -checkhost（LibreSSL 没有该选项）。
    expected_hosts=$(cloudflare_origin_certificate_hosts | jq -r '.[]' | sort -u)
    actual_hosts=$(cloudflare_certificate_san_hosts "${CERT_FILE}")
    [[ -n "${actual_hosts}" && "${actual_hosts}" == "${expected_hosts}" ]] \
        || return 1
    # 与 certificate_key_matches 同一口径：比公钥 PEM 且必须非空，避免两侧命令同时失败时
    # 拿同一个空输入哈希误判“配对”。
    cert_pub=$(openssl x509 -in "${CERT_FILE}" -pubkey -noout 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "${KEY_FILE}" -pubout 2>/dev/null) || return 1
    [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]] || return 1
}

cloudflare_origin_certificate_hosts() {
    jq -cn --arg host "${CLOUDFLARE_ORIGIN_DOMAIN}" '[$host]'
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
