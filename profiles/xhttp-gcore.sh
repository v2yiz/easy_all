#!/usr/bin/env bash

# Gcore CDN Profile for easy_all (Mode 3).
#
# Provides high-performance, edge-accelerated VLESS over Gcore CDN.
# Resolves the account CDN hostname from Hong Kong, Japan, and Los Angeles,
# then selects up to 2 verified IPv4 endpoints per China carrier.
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
readonly GCORE_DNS_PROPAGATION_ATTEMPTS="${GCORE_DNS_PROPAGATION_ATTEMPTS_OVERRIDE:-60}"
readonly GCORE_DNS_PROPAGATION_INTERVAL="${GCORE_DNS_PROPAGATION_INTERVAL_OVERRIDE:-5}"
readonly GCORE_EDGE_PROPAGATION_ATTEMPTS="${GCORE_EDGE_PROPAGATION_ATTEMPTS_OVERRIDE:-90}"
readonly GCORE_EDGE_PROPAGATION_INTERVAL="${GCORE_EDGE_PROPAGATION_INTERVAL_OVERRIDE:-10}"

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

collect_subscription_link_domain() {
    local current domain
    current=$(subscription_link_domain)
    domain=${SUBSCRIPTION_DOMAIN:-}
    if [[ -t 0 ]]; then
        info "可复用 Gcore CDN 节点域名；自定义订阅域名必须由 Gcore Managed DNS 托管。"
        domain=$(prompt_value "订阅链接完整域名（含完整主机名）" "${current}")
    else
        domain=${domain:-${current}}
    fi
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    [[ "${domain}" != "${GCORE_ORIGIN_DOMAIN:-}" ]] \
        || die "订阅链接域名不能与源站域名相同"
    SUBSCRIPTION_DOMAIN=${domain}
}

# --- Gcore API and Credentials ---

gcore_api_raw() {
    local method=$1 path=$2 payload=${3:-} response
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    if [[ -n "${payload}" ]]; then
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
            -H 'Content-Type: application/json' \
            --data "${payload}" -w $'\n%{http_code}' \
            "${GCORE_API_BASE}${path}") || return 1
    else
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "Authorization: APIKey ${GCORE_API_TOKEN}" \
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
        || die "Gcore API 请求失败：GET ${path}"
    http_code=${response##*$'\n'}
    body=${response%$'\n'*}
    [[ "${http_code}" =~ ^[0-9]{3}$ ]] \
        || die "Gcore API 返回无效 HTTP 状态：GET ${path}；响应正文：${body}"
    if [[ "${http_code}" == "404" ]]; then
        return 1
    fi
    if ((http_code < 200 || http_code >= 300)); then
        printf '%s\n' "${body:-<empty>}" >&2
        die "Gcore API 请求失败（HTTP ${http_code}）：GET ${path}"
    fi
    printf '%s' "${body}"
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
    ufw reload >/dev/null 2>&1 || true
}

configure_ufw() {
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
    apply_managed_ufw_tcp_ports "${desired_ports} 80 443"
    gcore_configure_origin_firewall
    apply_managed_ufw_tcp_ports "${desired_ports} 80"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

# --- DNS & Zone Management ---

gcore_find_zone_for_domain() {
    local domain candidate matched="" zones
    domain=$(normalize_domain "$1")
    zones=$(gcore_api_request GET "/dns/v2/zones")
    while IFS= read -r candidate; do
        [[ -n "${candidate}" ]] || continue
        candidate=$(normalize_domain "${candidate}")
        if [[ "${domain}" == "${candidate}" || "${domain}" == *".${candidate}" ]]; then
            if [[ -z "${matched}" || ${#candidate} -gt ${#matched} ]]; then
                matched=${candidate}
            fi
        fi
    done < <(gcore_json_items "${zones}" | jq -r '.name // empty')
    [[ -n "${matched}" ]] || return 1
    printf '%s' "${matched}"
}

gcore_validate_dns_zones() {
    local cdn_zone subscription_domain subscription_zone
    cdn_zone=$(gcore_find_zone_for_domain "${VLESS_CDN_DOMAIN}") \
        || die "Gcore Managed DNS 中没有覆盖 CDN 域名 ${VLESS_CDN_DOMAIN} 的 Zone"
    [[ "${cdn_zone}" == "${GCORE_DNS_ZONE}" ]] \
        || die "源站域名 ${GCORE_ORIGIN_DOMAIN} 与 CDN 域名 ${VLESS_CDN_DOMAIN} 必须位于同一个 Gcore Managed DNS Zone"
    [[ "${VLESS_CDN_DOMAIN}" != "${GCORE_DNS_ZONE}" ]] \
        || die "Gcore CDN 域名必须使用 ${GCORE_DNS_ZONE} 下的子域名，不能直接使用 Zone 根域"

    subscription_domain=$(active_subscription_link_domain)
    subscription_zone=$(gcore_find_zone_for_domain "${subscription_domain}") \
        || die "Gcore Managed DNS 中没有覆盖订阅域名 ${subscription_domain} 的 Zone"
    [[ "${subscription_domain}" != "${subscription_zone}" ]] \
        || die "订阅链接域名必须使用 Gcore Managed DNS Zone 下的子域名，不能直接使用根域"
    [[ "${subscription_domain}" != "${GCORE_ORIGIN_DOMAIN}" ]] \
        || die "订阅链接域名不能与源站域名相同"
    GCORE_SUBSCRIPTION_DNS_ZONE=${subscription_zone}
}

gcore_verify_zone_delegation() {
    local zone=$1 status authorized non_gcore exists
    status=$(gcore_api_request GET "/dns/v2/analyze/${zone}/delegation-status")
    if jq -e '.delegated == true' <<<"${status}" >/dev/null 2>&1; then
        return 0
    fi
    authorized=$(jq -r '.gcore_authorized_count // 0' <<<"${status}") \
        || die "Gcore 返回了无效的 ${zone} 委派状态：${status}"
    non_gcore=$(jq -r '.non_gcore_authorized_count // 0' <<<"${status}") \
        || die "Gcore 返回了无效的 ${zone} 委派状态：${status}"
    exists=$(jq -r '.zone_exists // false' <<<"${status}") \
        || die "Gcore 返回了无效的 ${zone} 委派状态：${status}"
    [[ "${authorized}" =~ ^[0-9]+$ && "${non_gcore}" =~ ^[0-9]+$ \
        && ( "${exists}" == "true" || "${exists}" == "false" ) ]] \
        || die "Gcore 返回了无效的 ${zone} 委派状态：${status}"
    [[ "${exists}" == "true" && "${authorized}" -gt 0 && "${non_gcore}" -eq 0 ]] \
        || die "Gcore 尚未成为 ${zone} 的唯一权威 DNS（Zone 存在：${exists}，Gcore 权威 NS：${authorized}，非 Gcore 权威 NS：${non_gcore}）"
}

gcore_ensure_origin_a_record() {
    local public_ip
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}

    local payload
    payload=$(jq -cn --arg ip "${public_ip}" --argjson ttl "${GCORE_DNS_TTL}" \
        '{resource_records:[{content:[$ip]}],ttl:$ttl}')
    info "在 Gcore Managed DNS 配置源站 A 记录: ${GCORE_ORIGIN_DOMAIN} -> ${public_ip}"
    gcore_api_request PUT "/dns/v2/zones/${GCORE_DNS_ZONE}/${GCORE_ORIGIN_DOMAIN}/A" "${payload}" >/dev/null
}

gcore_ensure_domain_cname_record() {
    local domain=$1 zone=$2 payload
    payload=$(jq -cn --arg target "${GCORE_CDN_TARGET}" --argjson ttl "${GCORE_DNS_TTL}" \
        '{resource_records:[{content:[$target]}],ttl:$ttl}')
    info "在 Gcore Managed DNS 配置 CDN CNAME 记录: ${domain} -> ${GCORE_CDN_TARGET}"
    gcore_api_request PUT "/dns/v2/zones/${zone}/${domain}/CNAME" "${payload}" >/dev/null
}

gcore_ensure_cdn_cname_records() {
    local subscription_domain
    gcore_ensure_domain_cname_record "${VLESS_CDN_DOMAIN}" "${GCORE_DNS_ZONE}"
    subscription_domain=$(active_subscription_link_domain)
    if [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_ensure_domain_cname_record \
            "${subscription_domain}" "${GCORE_SUBSCRIPTION_DNS_ZONE}"
    fi
}

gcore_wait_for_origin_dns() {
    local attempt records last_records="未解析"
    info "等待 Gcore Managed DNS 源站 A 记录传播到 1.1.1.1"
    for ((attempt = 1; attempt <= GCORE_DNS_PROPAGATION_ATTEMPTS; attempt += 1)); do
        records=$(dig +short A "${GCORE_ORIGIN_DOMAIN}" @1.1.1.1 2>/dev/null \
            | awk 'NF' | sort -u || true)
        [[ -z "${records}" ]] || last_records=${records//$'\n'/,}
        if [[ -n "${records}" ]] && awk -v expected="${VPS_PUBLIC_IPV4}" '
            BEGIN {ok=1; count=0}
            NF {count++; if ($0 != expected) ok=0}
            END {exit !(ok && count > 0)}
        ' <<<"${records}"; then
            return 0
        fi
        sleep "${GCORE_DNS_PROPAGATION_INTERVAL}"
    done
    die "源站域名 ${GCORE_ORIGIN_DOMAIN} 尚未通过 1.1.1.1 解析到当前 VPS ${VPS_PUBLIC_IPV4}（当前结果：${last_records}）"
}

gcore_wait_for_domain_cname() {
    local domain=$1 attempt records last_records="未解析" expected
    expected=$(normalize_domain "${GCORE_CDN_TARGET}")
    info "等待 ${domain} 的 Gcore CDN CNAME 传播到 1.1.1.1"
    for ((attempt = 1; attempt <= GCORE_DNS_PROPAGATION_ATTEMPTS; attempt += 1)); do
        records=$(dig +short CNAME "${domain}" @1.1.1.1 2>/dev/null \
            | sed 's/\.$//' | tr '[:upper:]' '[:lower:]' | sort -u || true)
        [[ -z "${records}" ]] || last_records=${records//$'\n'/,}
        [[ "${records}" == "${expected}" ]] && return 0
        sleep "${GCORE_DNS_PROPAGATION_INTERVAL}"
    done
    die "CDN 域名 ${domain} 尚未通过 1.1.1.1 解析到 Gcore 目标 ${expected}（当前结果：${last_records}）"
}

gcore_wait_for_cdn_dns() {
    local subscription_domain
    gcore_wait_for_domain_cname "${VLESS_CDN_DOMAIN}"
    subscription_domain=$(active_subscription_link_domain)
    if [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_wait_for_domain_cname "${subscription_domain}"
    fi
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

write_cert_reload_hook() {
    install -d -m 0755 "$(dirname "${CERT_RELOAD_HOOK}")"
    cat >"${RUNTIME_TMP}/reload-tls-service.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
nginx -t >/dev/null 2>&1 || exit 1
systemctl reload nginx 2>/dev/null || systemctl restart nginx 2>/dev/null || exit 1
EOF
    install -m 0755 "${RUNTIME_TMP}/reload-tls-service.sh" "${CERT_RELOAD_HOOK}"
    rm -f -- "${RUNTIME_TMP}/reload-tls-service.sh"
}

issue_origin_certificate() {
    write_cert_reload_hook
    install_acme
    run_acme --set-default-ca --server letsencrypt >/dev/null || true
    install -d -m 0700 "${CERT_DIR}"
    if ! run_acme --issue -d "${GCORE_ORIGIN_DOMAIN}" -w "${WEB_ROOT}" \
        --keylength ec-256 --force; then
        die "源站域名 ${GCORE_ORIGIN_DOMAIN} 证书签发失败"
    fi
    if ! run_acme --install-cert -d "${GCORE_ORIGIN_DOMAIN}" --ecc \
        --key-file "${KEY_FILE}" \
        --fullchain-file "${CERT_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}"; then
        die "安装源站 ECC 证书失败"
    fi
    chmod 0600 "${KEY_FILE}"
    chmod 0644 "${CERT_FILE}"
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
    awk 'BEGIN {c=0} /BEGIN CERTIFICATE/ {c++} c>1 {print}' "${CERT_FILE}" >"${issuer_ca_file}"
    [[ -s "${issuer_ca_file}" ]] || install -m 0644 "${CERT_FILE}" "${issuer_ca_file}"

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

gcore_ensure_resource() {
    local payload response existing_resources res subscription_domain
    local resource_id="" edge_certificate_id=""
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
            allowedHttpMethods: {enabled: true, value: ["GET", "HEAD", "POST"]},
            websockets: {enabled: true, value: true},
            hostHeader: {enabled: true, value: $origin},
            redirect_http_to_https: {enabled: true, value: true},
            use_dns01_le_challenge: {enabled: true, value: true},
            sni: {enabled: true, sni_type: "custom", custom_hostname: $origin},
            proxy_connect_timeout: {enabled: true, value: "5s"},
            edge_cache_settings: {enabled: true, value: "0s", custom_values: {}},
            browser_cache_settings: {enabled: true, value: "0s"},
            ignoreQueryString: {enabled: true, value: false},
            slice: {enabled: true, value: false}
          }
        }')

    if [[ -n "${resource_id}" ]]; then
        GCORE_CDN_RESOURCE_ID=${resource_id}
        info "更新已有 Gcore CDN 资源 (ID: ${GCORE_CDN_RESOURCE_ID}) 的 HTTPS、mTLS 与配置"
        gcore_api_request PUT "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null || return 1
    else
        response=$(gcore_api_request POST "/cdn/resources" "${payload}") || return 1
        GCORE_CDN_RESOURCE_ID=$(jq -er '.id // empty' <<<"${response}") || return 1
    fi
    info "Gcore 边缘 HTTPS 已配置；新申请的证书由 Gcore 异步签发，签发完成前客户端 HTTPS 可能暂不可用"
}

gcore_probe_xhttp() {
    local probe_uuid=${1:-${VLESS_UUID}}
    local probe_dir="${RUNTIME_TMP}/gcore-xhttp-probe"
    local probe_config="${probe_dir}/config.json" probe_log="${probe_dir}/xray.log"
    local probe_port=0 probe_pid=0 attempt response http_code
    install -d -m 0700 "${probe_dir}"
    for attempt in {1..20}; do
        probe_port=$((20000 + RANDOM % 20000))
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . || break
        probe_port=0
    done
    ((probe_port > 0)) || return 1
    jq -n --arg address "${VLESS_CDN_DOMAIN}" --arg host "${VLESS_CDN_DOMAIN}" \
        --arg uuid "${probe_uuid}" --arg path "$(xhttp_client_path)" \
        --argjson port "${probe_port}" '
        {
          log:{loglevel:"error"},
          inbounds:[{
            tag:"gcore-xhttp-probe-socks",listen:"127.0.0.1",port:$port,
            protocol:"socks",settings:{udp:false}
          }],
          outbounds:[{
            tag:"proxy",protocol:"vless",
            settings:{vnext:[{address:$address,port:443,
                              users:[{id:$uuid,encryption:"none"}]}]},
            streamSettings:{
              network:"xhttp",security:"tls",
              tlsSettings:{serverName:$host,alpn:["h2"],fingerprint:"chrome"},
              xhttpSettings:{host:$host,path:$path,mode:"packet-up",
                             extra:{uplinkHTTPMethod:"POST"}}
            }
          }]
        }
    ' >"${probe_config}" || return 1
    "${XRAY_BIN}" run -test -config "${probe_config}" >/dev/null 2>"${probe_log}" || return 1
    "${XRAY_BIN}" run -config "${probe_config}" >"${probe_log}" 2>&1 &
    probe_pid=$!
    for attempt in {1..10}; do
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . && break
        sleep 1
    done
    if ! ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
        kill "${probe_pid}" >/dev/null 2>&1 || true
        wait "${probe_pid}" >/dev/null 2>&1 || true
        return 1
    fi
    response=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:${probe_port}" \
        --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' \
        'https://cp.cloudflare.com/generate_204' 2>>"${probe_log}" || true)
    http_code=${response##*$'\n'}
    kill "${probe_pid}" >/dev/null 2>&1 || true
    wait "${probe_pid}" >/dev/null 2>&1 || true
    [[ "${http_code}" == "204" ]]
}

gcore_probe_websocket() {
    local probe_uuid=${1:-${VLESS_UUID}}
    local probe_dir="${RUNTIME_TMP}/gcore-websocket-probe"
    local probe_config="${probe_dir}/config.json" probe_log="${probe_dir}/xray.log"
    local probe_port=0 probe_pid=0 attempt response http_code
    install -d -m 0700 "${probe_dir}"
    for attempt in {1..20}; do
        probe_port=$((20000 + RANDOM % 20000))
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . || break
        probe_port=0
    done
    ((probe_port > 0)) || return 1
    jq -n --arg address "${VLESS_CDN_DOMAIN}" --arg host "${VLESS_CDN_DOMAIN}" \
        --arg uuid "${probe_uuid}" --arg path "${WEBSOCKET_PATH}" \
        --argjson port "${probe_port}" '
        {
          log:{loglevel:"error"},
          inbounds:[{
            tag:"gcore-websocket-probe-socks",listen:"127.0.0.1",port:$port,
            protocol:"socks",settings:{udp:false}
          }],
          outbounds:[{
            tag:"proxy",protocol:"vless",
            settings:{vnext:[{address:$address,port:443,
                              users:[{id:$uuid,encryption:"none"}]}]},
            streamSettings:{
              network:"ws",security:"tls",
              tlsSettings:{serverName:$host,alpn:["http/1.1"],fingerprint:"chrome"},
              wsSettings:{path:$path,headers:{Host:$host}}
            }
          }]
        }
    ' >"${probe_config}" || return 1
    "${XRAY_BIN}" run -test -config "${probe_config}" >/dev/null 2>"${probe_log}" || return 1
    "${XRAY_BIN}" run -config "${probe_config}" >"${probe_log}" 2>&1 &
    probe_pid=$!
    for attempt in {1..10}; do
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . && break
        sleep 1
    done
    if ! ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
        kill "${probe_pid}" >/dev/null 2>&1 || true
        wait "${probe_pid}" >/dev/null 2>&1 || true
        return 1
    fi
    response=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:${probe_port}" \
        --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' \
        'https://cp.cloudflare.com/generate_204' 2>>"${probe_log}" || true)
    http_code=${response##*$'\n'}
    kill "${probe_pid}" >/dev/null 2>&1 || true
    wait "${probe_pid}" >/dev/null 2>&1 || true
    [[ "${http_code}" == "204" ]]
}

gcore_wait_for_domain_health() {
    local domain=$1 label=$2 verify_transport=$3 probe_uuid=${4:-}
    local attempt resource status certificate_state certificate_status="PENDING"
    local certificate_error response http_code curl_status=0 curl_error
    local transport_status transport_verified=0 validation_label="HTTPS"
    local health_body="${RUNTIME_TMP}/gcore-edge-health-body"
    local health_error="${RUNTIME_TMP}/gcore-edge-health-error"
    if ((verify_transport == 1)); then
        validation_label="HTTPS 与 XHTTP/WebSocket"
    else
        transport_verified=1
    fi
    info "等待 Gcore ${label}域名 ${domain} 的资源、边缘证书与公网链路传播（最多 ${GCORE_EDGE_PROPAGATION_ATTEMPTS} 轮、每轮间隔 ${GCORE_EDGE_PROPAGATION_INTERVAL} 秒，网络请求耗时另计）"
    for ((attempt = 1; attempt <= GCORE_EDGE_PROPAGATION_ATTEMPTS; attempt += 1)); do
        resource=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}") \
            || die "无法读取 Gcore CDN Resource 状态"
        status=$(jq -r '.status // empty' <<<"${resource}" | tr '[:upper:]' '[:lower:]')
        if ((attempt == 1 || attempt % 3 == 0)); then
            certificate_state=$(gcore_api_request GET \
                "/cdn/sslData/${GCORE_EDGE_CERTIFICATE_ID}/status") \
                || die "无法读取 Gcore 边缘证书签发状态"
            certificate_status=$(jq -r '
                if (.latest_status.status? // "") != "" then
                    .latest_status.status | ascii_upcase
                elif .active == true then "ACTIVE"
                else "PENDING"
                end
            ' <<<"${certificate_state}")
            case "${certificate_status}" in
            FAILED | CANCELLED)
                certificate_error=$(jq -c '{
                    error:(.latest_status.error // null),
                    details:(.latest_status.details // null)
                }' <<<"${certificate_state}")
                die "Gcore 边缘证书签发 ${certificate_status}：${certificate_error}"
                ;;
            esac
        fi

        : >"${health_body}"
        : >"${health_error}"
        if http_code=$(curl -sS --proto '=https' --noproxy '*' \
            --connect-timeout 5 --max-time 15 -o "${health_body}" \
            -w '%{http_code}' "https://${domain}/easy_all-health" \
            2>"${health_error}"); then
            curl_status=0
        else
            curl_status=$?
        fi
        response=$(<"${health_body}")
        transport_status="not-required"
        if ((curl_status == 0)) && [[ "${http_code}" == "200" && "${response}" == "easy_all ok" ]]; then
            if ((verify_transport == 0)); then
                transport_status="not-required"
            elif ((transport_verified == 1)); then
                transport_status="ok"
            elif ((attempt == 1 || attempt % 3 == 0)); then
                if gcore_probe_xhttp "${probe_uuid}" \
                    && gcore_probe_websocket "${probe_uuid}"; then
                    transport_verified=1
                    transport_status="ok"
                else
                    transport_status="failed"
                fi
            fi
        fi
        if ((curl_status == 0 && transport_verified == 1)) \
            && [[ "${http_code}" == "200" && "${response}" == "easy_all ok" ]]; then
            [[ "${status}" == "active" ]] \
                || warn "Gcore Resource 状态仍为 ${status:-unknown}，但 ${label}域名端到端验收已通过"
            success "Gcore ${label}域名回源、边缘证书与 ${validation_label} 验收通过"
            return 0
        fi
        if ((attempt == 1 || attempt % 3 == 0)); then
            curl_error=$(tr '\n' ' ' <"${health_error}")
            info "Gcore ${label}域名状态：Resource=${status:-unknown}，证书=${certificate_status}，curl=${curl_status}，HTTPS=${http_code:-000}，传输=${transport_status}${curl_error:+，错误=${curl_error}}"
        fi
        sleep "${GCORE_EDGE_PROPAGATION_INTERVAL}"
    done
    die "Gcore ${label}域名 ${domain} 边缘传播超时：Resource=${status:-unknown}，证书=${certificate_status}，curl=${curl_status}，HTTPS=${http_code:-000}；请检查 CNAME、边缘证书、CDN Resource 与回源配置"
}

gcore_wait_for_cdn_health() {
    local subscription_domain probe_uuid="" verify_transport=1
    if quota_enabled; then
        probe_uuid=$(quota_active_accounts_json | jq -er 'first(to_entries[]).value.uuid') \
            || verify_transport=0
        if ((verify_transport == 0)); then
            info "所有配额用户均已停用，跳过 XHTTP/WebSocket 业务探针，仅验收 CDN 公网健康接口"
        fi
    else
        probe_uuid=${VLESS_UUID}
    fi
    gcore_wait_for_domain_health \
        "${VLESS_CDN_DOMAIN}" "CDN" "${verify_transport}" "${probe_uuid}"

    subscription_domain=$(active_subscription_link_domain)
    if [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_wait_for_domain_health "${subscription_domain}" "订阅" 0
    fi
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
        || die "未找到匹配域名 ${GCORE_ORIGIN_DOMAIN} 的 Gcore DNS Zone。请先在 Gcore 控制台（DNS -> Add zone）添加根域名托管 Zone，并将域名权威 NS 委派至 Gcore"
    gcore_validate_dns_zones
    gcore_verify_zone_delegation "${GCORE_DNS_ZONE}"
    if [[ "${GCORE_SUBSCRIPTION_DNS_ZONE}" != "${GCORE_DNS_ZONE}" ]]; then
        gcore_verify_zone_delegation "${GCORE_SUBSCRIPTION_DNS_ZONE}"
    fi
    gcore_ensure_origin_a_record
    gcore_ensure_cdn_cname_records
    gcore_wait_for_origin_dns
    gcore_wait_for_cdn_dns
}

gcore_apply_cdn() {
    info "配置 Gcore 源组、证书与 CDN 资源"
    gcore_ensure_origin_group
    gcore_ensure_origin_validation_certificates
    gcore_ensure_resource
    gcore_wait_for_cdn_health
}

normalize_websocket_path() {
    local path=${1:-}
    while [[ "${path}" =~ ^/(ws|websocket)-/(ws|websocket)- ]]; do
        path="/${path#/*-/}"
    done
    if [[ "${path}" =~ ^/(ws|websocket)- ]]; then
        path="/ws-${path#/*-}"
    elif [[ -n "${path}" ]]; then
        path="/ws-${path#/}"
    else
        path="/ws-$(openssl rand -hex 12)"
    fi
    path="${path%/}"
    printf '%s\n' "${path}"
}

normalize_xhttp_path() {
    local path=${1:-}
    while [[ "${path}" =~ ^/(xhttp|vless)-/(xhttp|vless)- ]]; do
        path="/${path#/*-/}"
    done
    if [[ "${path}" =~ ^/(xhttp|vless)- ]]; then
        path="/xhttp-${path#/*-}"
    elif [[ -n "${path}" ]]; then
        path="/xhttp-${path#/}"
    else
        path="/xhttp-$(openssl rand -hex 12)"
    fi
    path="${path%/}"
    printf '%s\n' "${path}"
}

collect_install_inputs() {
    PROTOCOL="gcore"
    BACKEND="xray"
    CDN_PROVIDER="gcore"
    choose_cdn_client_ip_family

    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"

    info "Gcore 模式需要两个不同子域名：CDN 节点域名用于客户端连接，源站域名用于 VPS 真实回源与证书。"
    VLESS_CDN_DOMAIN=$(normalize_domain "${VLESS_CDN_DOMAIN:-$(prompt_value "客户端连接的 CDN 节点域名" "")}")
    validate_domain "${VLESS_CDN_DOMAIN}" || die "VLESS_CDN_DOMAIN 无效"

    GCORE_ORIGIN_DOMAIN=$(normalize_domain "${GCORE_ORIGIN_DOMAIN:-$(prompt_value "VPS 回源解析的源站域名" "")}")
    validate_domain "${GCORE_ORIGIN_DOMAIN}" || die "GCORE_ORIGIN_DOMAIN 无效"

    [[ "${VLESS_CDN_DOMAIN}" != "${GCORE_ORIGIN_DOMAIN}" ]] \
        || die "CDN 节点域名与源站域名不能相同"
    XHTTP_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}

    info "Gcore 模式需要具有 CDN 与 Managed DNS 权限的 API Token。"
    gcore_collect_api_token

    info "Gcore 模式通过香港、日本、洛杉矶 Globalping 探针发现真实 DNS 入口，并使用三网 eyeball 探针定向测速。"
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"

    WEBSOCKET_PATH=$(normalize_websocket_path "${WEBSOCKET_PATH:-}")
    validate_xhttp_path "${WEBSOCKET_PATH}" || die "WEBSOCKET_PATH 无效"

    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效"

    XRAY_WEBSOCKET_LOOPBACK_PORT=${XRAY_WEBSOCKET_LOOPBACK_PORT:-${DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" || die "WebSocket 本机端口无效"

    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "XHTTP 本机端口无效"

    choose_subscription_mode
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        choose_monthly_quota 0
        ensure_allowed_tokens
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
    fi
}

load_state() {
    local variable env_name state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local -a variables=(
        STATE_VERSION PROTOCOL BACKEND CDN_PROVIDER
        CDN_CLIENT_IP_FAMILY XHTTP_NODE_NAME VLESS_UUID
        VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN
        GCORE_ORIGIN_DOMAIN GCORE_DNS_ZONE GCORE_SUBSCRIPTION_DNS_ZONE GCORE_CDN_TARGET
        GCORE_CDN_RESOURCE_ID GCORE_ORIGIN_GROUP_ID
        GCORE_ORIGIN_CLIENT_CERT_ID GCORE_ORIGIN_CA_ID
        VPS_PUBLIC_IPV4 WEBSOCKET_PATH XHTTP_PATH
        XRAY_WEBSOCKET_LOOPBACK_PORT XRAY_XHTTP_LOOPBACK_PORT
        ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
    )
    [[ -f "${state_path}" ]] || return 1
    for variable in "${variables[@]}"; do
        env_name=$(env -i bash -c 'source "$1" && printf "%s" "${'"${variable}"':-}"' _ "${state_path}")
        printf -v "${variable}" '%s' "${env_name}"
    done
    [[ "${PROTOCOL}" == "gcore" && "${CDN_PROVIDER:-}" == "gcore" && "${BACKEND:-}" == "xray" ]] \
        || die "状态不是 Gcore CDN"
    configure_cdn_client_ip_family
    validate_domain "${GCORE_ORIGIN_DOMAIN:-}" && validate_domain "${VLESS_CDN_DOMAIN:-}" \
        && validate_uuid "${VLESS_UUID:-}" || die "Gcore 状态缺少有效域名或 UUID"
    [[ "${GCORE_ORIGIN_DOMAIN}" != "${VLESS_CDN_DOMAIN}" ]] \
        || die "Gcore 状态中源站域名与 CDN 节点域名不能相同"
    XHTTP_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}
    WEBSOCKET_PATH=$(normalize_websocket_path "${WEBSOCKET_PATH:-}")
    validate_xhttp_path "${WEBSOCKET_PATH}" || die "状态中的 WEBSOCKET_PATH 无效"
    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "状态中的 XHTTP_PATH 无效"

    XRAY_WEBSOCKET_LOOPBACK_PORT=${XRAY_WEBSOCKET_LOOPBACK_PORT:-${DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" || die "状态中的 WebSocket 本机端口无效"
    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "状态中的 XHTTP 本机端口无效"

    SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN:-${VLESS_CDN_DOMAIN}}")
    GCORE_SUBSCRIPTION_DNS_ZONE=${GCORE_SUBSCRIPTION_DNS_ZONE:-${GCORE_DNS_ZONE}}
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-none}") || die "订阅模式无效"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}") || die "订阅文件名无效"
    [[ -z "${ALLOWED_TOKENS:-}" ]] || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") || die "Token 无效"
    QUOTA_ENABLED=${QUOTA_ENABLED:-0}
    [[ "${QUOTA_ENABLED}" == "0" || "${QUOTA_ENABLED}" == "1" ]] \
        || die "状态文件中的 QUOTA_ENABLED 无效"
    if quota_enabled; then
        validate_user_accounts "${USER_ACCOUNTS:-}" || die "状态文件中的 USER_ACCOUNTS 无效"
        validate_quota_start_date "${QUOTA_START_DATE:-}" || die "状态文件中的 QUOTA_START_DATE 无效"
    else
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
    fi
    BACKEND="xray"
    PROTOCOL="gcore"
    CDN_PROVIDER="gcore"
}

save_state() {
    local target="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local state_dir
    state_dir="$(dirname "${target}")"
    install -d -m 0700 "${state_dir}"
    local t
    t=$(mktemp "${state_dir}/state.env.XXXXXX")
    cleanup_files+=("${t}")
    {
        for v in STATE_VERSION PROTOCOL BACKEND CDN_PROVIDER CDN_CLIENT_IP_FAMILY \
            XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN \
            GCORE_ORIGIN_DOMAIN GCORE_DNS_ZONE GCORE_SUBSCRIPTION_DNS_ZONE GCORE_CDN_TARGET \
            GCORE_CDN_RESOURCE_ID GCORE_ORIGIN_GROUP_ID \
            GCORE_ORIGIN_CLIENT_CERT_ID GCORE_ORIGIN_CA_ID \
            VPS_PUBLIC_IPV4 WEBSOCKET_PATH XHTTP_PATH \
            XRAY_WEBSOCKET_LOOPBACK_PORT XRAY_XHTTP_LOOPBACK_PORT \
            ALLOWED_TOKENS SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE \
            SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR \
            QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE; do
            case "${v}" in
            STATE_VERSION) printf '%s=%q\n' "${v}" "${STATE_SCHEMA_VERSION}" ;;
            PROTOCOL) printf '%s=%q\n' "${v}" "gcore" ;;
            BACKEND) printf '%s=%q\n' "${v}" "xray" ;;
            CDN_PROVIDER) printf '%s=%q\n' "${v}" "gcore" ;;
            SUBSCRIPTION_DOMAIN) printf '%s=%q\n' "${v}" "$(subscription_link_domain)" ;;
            *) printf '%s=%q\n' "${v}" "${!v:-}" ;;
            esac
        done
    } >"${t}"
    install -m 0600 "${t}" "${target}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Gcore CDN 尚未安装"
    load_state
}

mihomo_transport_marker() {
    printf 'network: ws\n'
}

xhttp_validate_local_tls_curl_args() {
    XHTTP_LOCAL_TLS_CURL_ARGS=(
        --proto '=https'
        --cert "${GCORE_CLIENT_CERT_FILE}"
        --key "${GCORE_CLIENT_CERT_KEY}"
    )
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
    local ip label carrier region count=0
    while IFS=$'\t' read -r ip label carrier region; do
        [[ -n "${ip}" ]] || continue
        count=$((count + 1))
        build_vless_websocket_link "${ip}" "优选${label}"
        printf '\n'
    done < <(gcore_client_candidates)
    if (( count == 0 )); then
        build_vless_websocket_link "${VLESS_CDN_DOMAIN}" "优选1"
        printf '\n'
    fi
}

build_mihomo_nodes() {
    local ip label carrier region count=0
    while IFS=$'\t' read -r ip label carrier region; do
        [[ -n "${ip}" ]] || continue
        count=$((count + 1))
        build_mihomo_websocket_node "${ip}" "优选${label}"
    done < <(gcore_client_candidates)
    if (( count == 0 )); then
        build_mihomo_websocket_node "${VLESS_CDN_DOMAIN}" "优选1"
    fi
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
    if (( ${#all_nodes[@]} == 0 )); then
        all_nodes+=("优选1")
    fi

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
    local template node_file group_file name_file base64_file mihomo_file user uuid user_dir marker='network: ws'
    prepare_mihomo_template
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"
    resolve_cdn_client_ip_family

    if quota_enabled; then
        rm -rf -- "${SUBSCRIPTION_DIR}"
        install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
        while IFS=$'\t' read -r user uuid; do
            user_dir="${SUBSCRIPTION_DIR}/${user}"
            (
                VLESS_UUID=${uuid}
                build_mihomo_nodes >"${node_file}.${user}"
                build_mihomo_proxy_groups >"${group_file}.${user}"
                build_mihomo_proxy_names >"${name_file}.${user}"
                build_node_links | openssl base64 -A >"${base64_file}.${user}"
                printf '\n' >>"${base64_file}.${user}"
                render_mihomo_subscription "${template}" "${node_file}.${user}" \
                    "${mihomo_file}.${user}" "${XHTTP_NODE_NAME}" \
                    "${CDN_CLIENT_IP_FAMILY_RESOLVED:-ipv4}" \
                    "${group_file}.${user}" "${name_file}.${user}"
            )
            grep -Fq "${marker}" "${mihomo_file}.${user}" \
                || die "Mihomo 订阅缺少有效节点：${user}"
            install -d -o root -g www-data -m 0750 "${user_dir}"
            install -o root -g www-data -m 0640 \
                "${base64_file}.${user}" "${user_dir}/base64.txt"
            install -o root -g www-data -m 0640 \
                "${mihomo_file}.${user}" "${user_dir}/mihomo.yaml"
        done < <(jq -r 'to_entries[] | [.key,.value.uuid] | @tsv' <<<"${USER_ACCOUNTS}")
        return 0
    fi

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
    printf '\n协议: VLESS WebSocket over Gcore CDN（最多 6 个已验证节点）\n节点链接:\n%s\n\n' "$(build_node_links)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_nodes
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: VLESS WebSocket + XHTTP packet-up（Gcore CDN）\n后端: Xray (%s)\n客户端 CDN 节点域名: %s\nGcore 回源域名: %s\nGcore 目标: %s\n候选来源: Globalping 多地区 DNS / 三网 eyeball 定向探针\n节点数量: 最多 6 个，以实际验证结果为准\n' \
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
    if ! gcore_globalping_cache_valid; then
        info "当前 Globalping 优选缓存未就绪或已过期，正在执行刷新..."
        refresh_gcore_globalping_cache || warn "Globalping 刷新失败，将使用现有缓存或域名兜底"
    fi
    finish_xhttp_apply
    install_globalping_refresh_timer
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
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
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"
    persist_globalping_token
    refresh_gcore_globalping_cache \
        || warn "Globalping 刷新失败，保留上一版本有效缓存"
    finish_xhttp_apply 1
    install_globalping_refresh_timer
    gcore_clear_api_token
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
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
    gcore_wait_for_cdn_health
    save_state
    gcore_clear_api_token
    success "源站证书与 Gcore Trusted CA 已同步续期"
}

update_subscription() {
    local previous_active_domain new_active_domain cloud_update=0
    require_root
    begin_quota_maintenance
    collect_installed_state
    previous_active_domain=$(active_subscription_link_domain)
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
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        remove_subscriptions
    fi
    new_active_domain=$(active_subscription_link_domain)
    [[ "${new_active_domain}" == "${previous_active_domain}" ]] || cloud_update=1
    refresh_runtime
    install_quota_timer
    subscription_enabled && validate_subscription_runtime
    if ((cloud_update == 1)); then
        info "订阅域名发生变化，正在同步 Gcore CDN、边缘证书与 Managed DNS"
        gcore_prepare_origin
        gcore_apply_cdn
        gcore_clear_api_token
    fi
    save_state
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
            '确认删除 easy_all Gcore CDN 本机服务、状态和证书？默认保留远端 Gcore 资源。[y/N]（直接回车取消）:' answer
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
