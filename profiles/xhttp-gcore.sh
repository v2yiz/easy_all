#!/usr/bin/env bash

# Gcore CDN VLESS XHTTP profile.
#
# This Profile is intentionally loaded only by easy_all's third installation
# choice. It reuses the provider-neutral parts of the CDN runtime while
# overriding the transport-specific Xray, Nginx and subscription renderers,
# and owns only the Gcore DNS/CDN adapter and its state.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'xhttp-gcore.sh 是 easy_all 的 Gcore XHTTP Profile；请使用：easy_all install\n' >&2
    exit 2
fi

if [[ "${_EASY_ALL_XHTTP_GCORE_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_EASY_ALL_XHTTP_GCORE_LOADED=1

readonly GCORE_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly XHTTP_PROFILE_ROOT="${GCORE_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="Gcore CDN"
XHTTP_ORIGIN_DNS_NAME_OVERRIDE="Gcore Managed DNS"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray VLESS XHTTP + WebSocket managed by easy_all"
XHTTP_MODE_OVERRIDE="packet-up"
XHTTP_XMUX_ENABLED_OVERRIDE=false

readonly GCORE_API_BASE="https://api.gcore.com"
readonly GCORE_DNS_TTL="300"
readonly GCORE_XHTTP_MAX_BUFFERED_POSTS="100"
readonly GCORE_XHTTP_PADDING_BYTES="100-500"
readonly GCORE_CDN_TRAFFIC_PROTECTION_GB="990"
readonly GCORE_XHTTP_NGINX_TIMEOUT="1h"
readonly GCORE_WEBSOCKET_NGINX_TIMEOUT="1h"
readonly DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT="10087"
GCORE_TRANSPORT_MIGRATION_REQUIRED=0

GCORE_SUBSCRIPTION_CLOUD_ROLLBACK_ON_EXIT=0
GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_MODE=""
GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_DOMAIN=""
GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_SSL_CERT_ID=""
# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"
# Gcore keeps its own global traffic guard because its free CDN quota is finite.
# It deliberately does not source globalping-cdn.sh: the client endpoint is
# always the Gcore DNS name.
# shellcheck source=lib/cdn-traffic-guard.sh
source "${XHTTP_PROFILE_ROOT}/cdn-traffic-guard.sh"

choose_cdn_client_ip_family() {
    CDN_CLIENT_IP_FAMILY=${CDN_CLIENT_IP_FAMILY:-ipv4}
    configure_cdn_client_ip_family
}

readonly ACME_HOME="/root/.acme-gcore.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-tls-service.sh"

alert() { printf '%b%s%b\n' "${RED}" "$*" "${RESET}"; }

traffic_stats_enabled() {
    quota_enabled || cdn_traffic_protection_enabled
}

collect_subscription_link_domain() {
    local current domain
    current=$(subscription_link_domain)
    domain=${SUBSCRIPTION_DOMAIN:-}
    if [[ -t 0 ]]; then
        info "可直接复用 Gcore CDN 节点域名；自定义域名必须由同一 Gcore Managed DNS Zone 托管。"
        domain=$(prompt_value \
            "订阅链接完整域名（含完整主机名）" "${current}" \
            "Full subscription hostname (must be hosted by the same Gcore Managed DNS zone)")
    else
        domain=${domain:-${current}}
    fi
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    [[ "${domain}" != "${GCORE_ORIGIN_DOMAIN:-}" ]] || die "订阅链接域名不能与源站域名相同"
    SUBSCRIPTION_DOMAIN=${domain}
}

verify_origin_dns() {
    local public_ip records attempt resolver_ok last_records=""
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    info "等待 Gcore Managed DNS 源站 A 记录传播到公共 DNS"
    for attempt in {1..60}; do
        records=$(dig +short A "${GCORE_ORIGIN_DOMAIN}" @1.1.1.1 2>/dev/null \
            | awk 'NF' | sort -u || true)
        last_records=${records:-未解析}
        resolver_ok=1
        [[ -n "${records}" ]] || resolver_ok=0
        if [[ -n "${records}" ]]; then
            while read -r record; do
                if ! validate_ipv4 "${record}" || [[ "${record}" != "${public_ip}" ]]; then
                    resolver_ok=0
                    break
                fi
            done <<<"${records}"
        fi
        [[ "${resolver_ok}" == 1 ]] && return 0
        sleep 5
    done
    die "源站域名 ${GCORE_ORIGIN_DOMAIN} 尚未通过 1.1.1.1 解析到当前 VPS ${public_ip}（当前结果：${last_records}）"
}

write_web_root() {
    install -d -m 0755 "${WEB_ROOT}/.well-known/acme-challenge"
    printf '%s\n' 'ready' >"${WEB_ROOT}/index.html"
    chmod 0644 "${WEB_ROOT}/index.html"
}

write_bootstrap_nginx_config() {
    write_web_root
    rm -f -- /etc/nginx/sites-enabled/default
    cat >"${RUNTIME_TMP}/easy_all-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${GCORE_ORIGIN_DOMAIN};
    root ${WEB_ROOT};
    location ^~ /.well-known/acme-challenge/ { try_files \$uri =404; }
    location / { return 404; }
}
EOF
    install -m 0600 "${RUNTIME_TMP}/easy_all-bootstrap.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx HTTP 引导配置校验失败"
    systemctl enable --now nginx >/dev/null || die "启动 Nginx 失败"
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

install_acme_from_github() {
    local acme_home=$1 account_email=$2
    local temp_dir release_file archive source_dir version archive_url
    temp_dir=$(make_temp_dir)
    release_file="${temp_dir}/release.json"
    archive="${temp_dir}/acme.tar.gz"
    source_dir="${temp_dir}/source"
    download_https_file \
        "https://api.github.com/repos/acmesh-official/acme.sh/releases/latest" \
        "${release_file}" " acme.sh 最新版本信息"
    version=$(jq -r '.tag_name // empty' "${release_file}")
    archive_url=$(jq -r '.tarball_url // empty' "${release_file}")
    [[ "${version}" =~ ^v?[0-9]+([.][0-9]+){2}$ ]] \
        || die "GitHub 返回了无效的 acme.sh 版本：${version:-空}"
    [[ "${archive_url}" == https://api.github.com/repos/acmesh-official/acme.sh/tarball/* ]] \
        || die "GitHub 返回了无效的 acme.sh 下载地址"
    info "正在从 GitHub 官方仓库下载 acme.sh ${version}"
    download_https_file "${archive_url}" "${archive}" " acme.sh ${version}"
    tar -tzf "${archive}" >/dev/null 2>&1 || die "acme.sh 下载归档损坏"
    install -d -m 0700 "${source_dir}"
    tar -xzf "${archive}" -C "${source_dir}" --strip-components=1 \
        || die "解压 acme.sh 失败"
    [[ -f "${source_dir}/acme.sh" ]] || die "acme.sh 下载归档内容不完整"
    (
        cd "${source_dir}"
        ACME_USE_WGET=1 sh ./acme.sh --install --use-wget \
            --no-cron --no-profile -m "${account_email}" --home "${acme_home}"
    ) || die "安装 acme.sh 失败"
}

run_acme() {
    ACME_USE_WGET=1 "${ACME_BIN}" "$@" --home "${ACME_HOME}"
}

has_acme_renewal_cron() {
    local crontab_content
    crontab_content=$(crontab -l 2>/dev/null || true)
    awk -v acme_bin="${ACME_BIN}" 'index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/ { found=1 } END { exit !found }' <<<"${crontab_content}"
}

ensure_acme_renewal_setup() {
    run_acme --install-cronjob >/dev/null 2>&1 || warn "acme.sh 未写入续期任务，改用 easy_all 受管 cron"
    local current_file="${RUNTIME_TMP}/acme-renewal.current" cron_file="${RUNTIME_TMP}/acme-renewal.cron"
    crontab -l >"${current_file}" 2>/dev/null || : >"${current_file}"
    awk -v acme_bin="${ACME_BIN}" 'index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/ { next } { print }' "${current_file}" >"${cron_file}"
    printf '17 2 * * * "%s" --cron --home "%s" >/dev/null 2>&1 # easy_all-acme-renewal\n' \
        "${ACME_BIN}" "${ACME_HOME}" >>"${cron_file}"
    crontab "${cron_file}" || die "写入 easy_all acme.sh 自动续期任务失败"
    systemctl enable --now cron.service >/dev/null 2>&1 \
        || die "无法启用证书自动续期所需的 cron.service"
    has_acme_renewal_cron || die "未找到 acme.sh 自动续期定时任务"
}

install_acme() {
    if [[ -x "${ACME_BIN}" ]]; then
        ensure_acme_renewal_setup
        return 0
    fi
    install_acme_from_github "${ACME_HOME}" "${ACME_EMAIL:-admin@${GCORE_ORIGIN_DOMAIN}}"
    [[ -x "${ACME_BIN}" ]] || die "acme.sh 安装后不可用"
    install -m 0600 /dev/null "${ACME_OWNERSHIP_MARKER}"
    ensure_acme_renewal_setup
}

issue_origin_certificate() {
    local issue_status=0
    install_acme
    run_acme --set-default-ca --server letsencrypt >/dev/null \
        || die "设置 Let's Encrypt 为默认 CA 失败"
    info "正在向 Let's Encrypt 申请源站证书：${GCORE_ORIGIN_DOMAIN}"
    run_acme --issue --webroot "${WEB_ROOT}" -d "${GCORE_ORIGIN_DOMAIN}" --keylength ec-256 \
        || issue_status=$?
    [[ "${issue_status}" == 0 || "${issue_status}" == 2 ]] \
        || die "源站证书申请失败（acme.sh 返回 ${issue_status}）"
    install -d -m 0700 "${CERT_DIR}" "${COMMAND_INSTALL_DIR}"
    cat >"${RUNTIME_TMP}/reload-tls-service.sh" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
systemctl reload nginx.service >/dev/null 2>&1 || systemctl restart nginx.service >/dev/null 2>&1
EOF
    install -m 0755 "${RUNTIME_TMP}/reload-tls-service.sh" "${CERT_RELOAD_HOOK}"
    run_acme --install-cert -d "${GCORE_ORIGIN_DOMAIN}" --ecc \
        --fullchain-file "${CERT_FILE}" --key-file "${KEY_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}" || die "安装源站证书失败"
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" && -x "${CERT_RELOAD_HOOK}" ]] \
        || die "源站证书、私钥或续期重载钩子安装不完整"
}

remove_managed_acme_domain() {
    [[ -n "${1:-}" && -x "${ACME_BIN}" ]] || return 0
    run_acme --remove -d "$1" --ecc >/dev/null 2>&1 || true
    rm -rf -- "${ACME_HOME:?}/$1" "${ACME_HOME:?}/${1}_ecc"
}

remove_managed_acme_cron() {
    command -v crontab >/dev/null 2>&1 || return 0
    local current filtered
    current=$(crontab -l 2>/dev/null || true)
    [[ -n "${current}" ]] || return 0
    filtered=$(awk -v acme_bin="${ACME_BIN}" 'index($0, acme_bin) && $0 ~ /(^|[[:space:]])--cron([[:space:]]|$)/ { next } { print }' <<<"${current}")
    [[ "${filtered}" == "${current}" ]] && return 0
    if [[ -n "${filtered}" ]]; then printf '%s\n' "${filtered}" | crontab -; else crontab -r; fi
}

build_node_link() { build_node_links; }
build_mihomo_node() { build_mihomo_nodes; }

readonly GCORE_CLIENT_CA_FILE="${CERT_DIR}/gcore-client-ca.pem"
readonly GCORE_CLIENT_CA_KEY_FILE="${CERT_DIR}/gcore-client-ca.key"
readonly GCORE_CLIENT_CERT_FILE="${CERT_DIR}/gcore-client.pem"
readonly GCORE_CLIENT_KEY_FILE="${CERT_DIR}/gcore-client.key"
readonly GCORE_ORIGIN_ISSUER_FILE="${CERT_DIR}/gcore-origin-issuer.pem"

gcore_api_raw() {
    local method=$1 path=$2 payload=${3:-} retry_count=0
    [[ "${method}" == "GET" ]] && retry_count=3
    local -a curl_args=(
        curl -sS --retry "${retry_count}" --connect-timeout 10 --max-time 45
        -X "${method}" -H "Authorization: APIKey ${GCORE_API_TOKEN}"
        -w $'\n%{http_code}'
    )
    if [[ -n "${payload}" ]]; then
        curl_args+=(-H 'Content-Type: application/json' --data "${payload}")
    fi
    "${curl_args[@]}" "${GCORE_API_BASE}${path}"
}

gcore_api_request() {
    local method=$1 path=$2 payload=${3:-}
    local response status body
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    response=$(gcore_api_raw "${method}" "${path}" "${payload}") \
        || { fail "请求 Gcore API 失败：${method} ${path}" || true; return 1; }
    status=${response##*$'\n'}
    body=${response%$'\n'*}
    if [[ "${status}" =~ ^2[0-9][0-9]$ ]]; then
        printf '%s' "${body}"
        return 0
    fi
    [[ -z "${body}" ]] || printf '%s\n' "${body}" >&2
    fail "Gcore API 请求失败（HTTP ${status}）：${method} ${path}" || true
    return 1
}

# GET an object that may not exist.  Exit status 1 means only HTTP 404; any
# other response is fatal so we never mistake an authorization failure for an
# empty DNS record.
gcore_api_get_optional() {
    local path=$1 response status body
    [[ -n "${GCORE_API_TOKEN:-}" ]] || die "缺少 GCORE_API_TOKEN"
    response=$(gcore_api_raw GET "${path}") \
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

gcore_delete_owned_rrset() {
    local zone=$1 domain=$2 type=$3 expected=$4 owned=$5 existing
    [[ "${owned}" == "1" ]] || return 0
    existing=$(gcore_api_get_optional "/dns/v2/zones/${zone}/${domain}/${type}") || return 0
    jq -e --arg expected "${expected}" '
        [.resource_records[]?.content[]? | rtrimstr(".")] | unique
        == [($expected | rtrimstr("."))]
    ' <<<"${existing}" >/dev/null \
        || die "${domain} 的 ${type} 已发生变化，拒绝在 purge 中删除"
    gcore_api_request DELETE "/dns/v2/zones/${zone}/${domain}/${type}" >/dev/null
}

purge_gcore_resources_before_uninstall() {
    local resource group edge_cert client_cert origin_ca subscription_domain attempt
    [[ "${UNINSTALL_PURGE_CLOUD:-0}" == "1" ]] || return 0
    [[ "${GCORE_CDN_RESOURCE_ID:-}" =~ ^[0-9]+$ \
        && "${GCORE_ORIGIN_GROUP_ID:-}" =~ ^[0-9]+$ \
        && "${GCORE_SSL_CERT_ID:-}" =~ ^[0-9]+$ \
        && "${GCORE_ORIGIN_CA_ID:-}" =~ ^[0-9]+$ \
        && "${GCORE_ORIGIN_CLIENT_CERT_ID:-}" =~ ^[0-9]+$ ]] \
        || die "Gcore 云资源 ID 不完整，已停止卸载；本机内容仍保留"
    gcore_collect_api_token
    resource=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}")
    jq -e --arg domain "${VLESS_CDN_DOMAIN}" \
        --arg name "easy_all xhttp ${VLESS_CDN_DOMAIN}" \
        --arg legacy_name "easy_all websocket ${VLESS_CDN_DOMAIN}" \
        --argjson group "${GCORE_ORIGIN_GROUP_ID}" \
        --argjson edge "${GCORE_SSL_CERT_ID}" \
        --argjson ca "${GCORE_ORIGIN_CA_ID}" \
        --argjson client "${GCORE_ORIGIN_CLIENT_CERT_ID}" '
        (.cname | rtrimstr(".") | ascii_downcase) == $domain
        and (.name == $name or .name == $legacy_name)
        and .originGroup == $group
        and .sslData == $edge
        and .proxy_ssl_ca == $ca
        and .proxy_ssl_data == $client
    ' <<<"${resource}" >/dev/null \
        || die "Gcore CDN 资源所有权标记不匹配，拒绝 purge"

    group=$(gcore_api_request GET "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}")
    jq -e --arg expected "$(gcore_origin_group_name)" '.name == $expected' \
        <<<"${group}" >/dev/null || die "Gcore 源组所有权标记不匹配，拒绝 purge"
    edge_cert=$(gcore_api_request GET "/cdn/sslData/${GCORE_SSL_CERT_ID}")
    jq -e '.automated == true' <<<"${edge_cert}" >/dev/null \
        || die "Gcore 边缘证书所有权标记不匹配，拒绝 purge"
    client_cert=$(gcore_api_request GET "/cdn/sslData/${GCORE_ORIGIN_CLIENT_CERT_ID}")
    jq -e --arg expected "easy-all-origin-client-${GCORE_ORIGIN_DOMAIN}" \
        '.name == $expected and (.automated // false) == false' <<<"${client_cert}" >/dev/null \
        || die "Gcore 回源客户端证书所有权标记不匹配，拒绝 purge"
    origin_ca=$(gcore_api_request GET "/cdn/sslCertificates/${GCORE_ORIGIN_CA_ID}")
    jq -e --arg expected "$(gcore_origin_ca_name)" '.name == $expected' \
        <<<"${origin_ca}" >/dev/null \
        || die "Gcore Trusted CA 所有权标记不匹配，拒绝 purge"

    gcore_api_request DELETE "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" >/dev/null
    for attempt in {1..12}; do
        gcore_api_get_optional "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" >/dev/null || break
        sleep 5
    done
    gcore_api_get_optional "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" >/dev/null \
        && die "等待 Gcore CDN 资源删除超时" || true

    gcore_api_request DELETE "/cdn/sslData/${GCORE_SSL_CERT_ID}" >/dev/null
    gcore_api_request DELETE "/cdn/sslData/${GCORE_ORIGIN_CLIENT_CERT_ID}" >/dev/null
    gcore_api_request DELETE "/cdn/sslCertificates/${GCORE_ORIGIN_CA_ID}" >/dev/null
    gcore_api_request DELETE "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}" >/dev/null

    gcore_delete_owned_rrset "${GCORE_DNS_ZONE}" "${VLESS_CDN_DOMAIN}" CNAME \
        "${GCORE_CDN_TARGET}" "${GCORE_CDN_CNAME_OWNED:-0}"
    subscription_domain=$(active_subscription_link_domain)
    if [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_delete_owned_rrset "${GCORE_SUBSCRIPTION_DNS_ZONE}" "${subscription_domain}" CNAME \
            "${GCORE_CDN_TARGET}" "${GCORE_SUBSCRIPTION_CNAME_OWNED:-0}"
    fi
    gcore_delete_owned_rrset "${GCORE_DNS_ZONE}" "${GCORE_ORIGIN_DOMAIN}" A \
        "${VPS_PUBLIC_IPV4}" "${GCORE_ORIGIN_A_OWNED:-0}"
    gcore_clear_api_token
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
    [[ "${authorized}" =~ ^[0-9]+$ && "${non_gcore}" =~ ^[0-9]+$ ]] \
        || die "Gcore 返回了无效的 ${zone} NS 委派状态；请稍后重试"
    if [[ "${exists}" == "true" && ${authorized} -gt 0 && ${non_gcore} -eq 0 ]]; then
        info "Gcore NS 委派已确认：${zone}（Gcore 权威 NS：${authorized}，非 Gcore 权威 NS：0）"
        return 0
    fi
    die "Gcore 尚未成为 ${zone} 的唯一权威 DNS（Zone 存在：${exists}，Gcore 权威 NS：${authorized}，非 Gcore 权威 NS：${non_gcore}）。本次安装尚未创建任何 DNS/CDN 资源；请完成 docs/preparation-guide.md 的整域名 NS 委派后重试。可先执行：dig NS ${zone} +short"
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

gcore_validate_dns_zones() {
    local cdn_zone subscription_domain subscription_zone
    cdn_zone=$(gcore_find_zone_for_domain "${VLESS_CDN_DOMAIN}")
    [[ -n "${cdn_zone}" ]] \
        || die "Gcore Managed DNS 中没有覆盖 CDN 域名 ${VLESS_CDN_DOMAIN} 的 Zone"
    [[ "${cdn_zone}" == "${GCORE_DNS_ZONE}" ]] \
        || die "源站域名 ${GCORE_ORIGIN_DOMAIN} 与 CDN 域名 ${VLESS_CDN_DOMAIN} 必须位于同一个 Gcore Managed DNS Zone"
    [[ "${VLESS_CDN_DOMAIN}" != "${GCORE_DNS_ZONE}" ]] \
        || die "Gcore CDN 域名必须使用 ${GCORE_DNS_ZONE} 下的子域名，不能直接使用 Zone 根域"
    subscription_domain=$(active_subscription_link_domain)
    subscription_zone=$(gcore_find_zone_for_domain "${subscription_domain}")
    [[ -n "${subscription_zone}" ]] \
        || die "Gcore Managed DNS 中没有覆盖订阅域名 ${subscription_domain} 的 Zone"
    [[ "${subscription_domain}" != "${subscription_zone}" ]] \
        || die "订阅链接域名必须使用 Gcore Managed DNS Zone 下的子域名，不能直接使用根域"
    [[ "${subscription_domain}" != "${GCORE_ORIGIN_DOMAIN}" ]] \
        || die "订阅链接域名不能与源站域名相同"
    GCORE_SUBSCRIPTION_DNS_ZONE=${subscription_zone}
}

gcore_ensure_origin_a_record() {
    local public_ip type existing a_matches=0
    public_ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测本机公网 IPv4"
    validate_ipv4 "${public_ip}" || die "探测到的 VPS 公网 IPv4 无效：${public_ip}"
    VPS_PUBLIC_IPV4=${public_ip}
    for type in A AAAA CNAME; do
        if existing=$(gcore_api_get_optional "/dns/v2/zones/${GCORE_DNS_ZONE}/${GCORE_ORIGIN_DOMAIN}/${type}"); then
            if [[ "${type}" == "A" ]] && jq -e --arg value "${public_ip}" '
                [.resource_records[]?.content[]?] | unique | sort == ([$value] | unique | sort)
            ' <<<"${existing}" >/dev/null; then
                a_matches=1
                continue
            fi
            gcore_require_dns_replace "${GCORE_ORIGIN_DOMAIN} 与源站 A 冲突的 ${type}"
            gcore_api_request DELETE \
                "/dns/v2/zones/${GCORE_DNS_ZONE}/${GCORE_ORIGIN_DOMAIN}/${type}" >/dev/null
            [[ "${type}" != "A" ]] || a_matches=0
        fi
    done
    [[ "${a_matches}" == "1" ]] && return 0
    gcore_api_request PUT "/dns/v2/zones/${GCORE_DNS_ZONE}/${GCORE_ORIGIN_DOMAIN}/A" \
        "$(gcore_rrset_body "${public_ip}")" >/dev/null
    GCORE_ORIGIN_A_OWNED=1
}

gcore_ensure_domain_cname_record() {
    local domain=$1 zone=$2 allow_replace=${3:-1} type existing
    for type in A AAAA; do
        if existing=$(gcore_api_get_optional "/dns/v2/zones/${zone}/${domain}/${type}"); then
            [[ "${allow_replace}" == "1" ]] \
                || die "${domain} 已有 ${type} 记录；独立订阅域名只复用正确 CNAME，拒绝覆盖"
            gcore_require_dns_replace "${domain} 与 CNAME 冲突的 ${type}"
            gcore_api_request DELETE \
                "/dns/v2/zones/${zone}/${domain}/${type}" >/dev/null
        fi
    done
    if existing=$(gcore_api_get_optional "/dns/v2/zones/${zone}/${domain}/CNAME") \
        && jq -e --arg value "${GCORE_CDN_TARGET}" '
            [.resource_records[]?.content[]? | rtrimstr(".")] | unique
            == [($value|rtrimstr("."))]
        ' <<<"${existing}" >/dev/null; then
        info "Gcore ${domain} 已解析到当前 CDN，直接复用"
        return 0
    fi
    if [[ -n "${existing:-}" ]]; then
        [[ "${allow_replace}" == "1" ]] \
            || die "${domain} 已有不指向当前 Gcore CDN 的 CNAME；拒绝覆盖"
        gcore_require_dns_replace "${domain} CNAME"
    fi
    gcore_api_request PUT "/dns/v2/zones/${zone}/${domain}/CNAME" \
        "$(gcore_rrset_body "${GCORE_CDN_TARGET}")" >/dev/null
    if [[ "${domain}" == "${VLESS_CDN_DOMAIN}" ]]; then
        GCORE_CDN_CNAME_OWNED=1
    else
        GCORE_SUBSCRIPTION_CNAME_OWNED=1
    fi
    success "Gcore ${domain} 不存在，已新增 CNAME 解析"
}

gcore_ensure_cname_record() {
    local subscription_domain
    gcore_ensure_domain_cname_record "${VLESS_CDN_DOMAIN}" "${GCORE_DNS_ZONE}"
    subscription_domain=$(active_subscription_link_domain)
    if subscription_enabled && [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_ensure_domain_cname_record "${subscription_domain}" \
            "${GCORE_SUBSCRIPTION_DNS_ZONE}" 0
    fi
}

gcore_wait_for_origin_dns() {
    verify_origin_dns
}

gcore_wait_for_domain_cname() {
    local domain=$1 attempt records
    info "等待 ${domain} 的 Gcore CDN CNAME 传播到公共 DNS"
    for attempt in {1..60}; do
        records=$(dig +short CNAME "${domain}" @1.1.1.1 2>/dev/null \
            | sed 's/\.$//' | tr '[:upper:]' '[:lower:]' | sort -u || true)
        [[ "${records}" == "${GCORE_CDN_TARGET}" ]] && return 0
        sleep 5
    done
    die "域名 ${domain} 尚未通过 1.1.1.1 解析到 Gcore 目标 ${GCORE_CDN_TARGET}"
}

gcore_wait_for_cdn_dns() {
    local subscription_domain
    gcore_wait_for_domain_cname "${VLESS_CDN_DOMAIN}"
    subscription_domain=$(active_subscription_link_domain)
    if subscription_enabled && [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_wait_for_domain_cname "${subscription_domain}"
    fi
}

gcore_origin_group_name() {
    printf 'easy-all-xhttp-%s' "${GCORE_ORIGIN_DOMAIN//./-}"
}

gcore_origin_ca_name() {
    local domain_hash fingerprint
    fingerprint=${CURRENT_GCORE_ORIGIN_ISSUER_SHA256:-${GCORE_ORIGIN_ISSUER_SHA256:-}}
    [[ "${fingerprint}" =~ ^[A-F0-9]{64}$ ]] \
        || die "缺少有效的 Gcore 源站签发 CA 指纹"
    domain_hash=$(printf '%s' "${GCORE_ORIGIN_DOMAIN}" | sha256sum | cut -c1-16)
    printf 'easy-all-origin-ca-%s-%s' "${domain_hash}" \
        "$(printf '%s' "${fingerprint}" | tr 'A-F' 'a-f')"
}

gcore_prepare_origin_validation_material() {
    local csr="${RUNTIME_TMP}/gcore-client.csr" extension="${RUNTIME_TMP}/gcore-client.ext"
    install -d -m 0700 "${CERT_DIR}"
    if [[ -s "${GCORE_CLIENT_CERT_FILE}" ]] \
        && ! openssl x509 -checkend 2592000 -noout -in "${GCORE_CLIENT_CERT_FILE}" >/dev/null; then
        rm -f -- "${GCORE_CLIENT_CA_FILE}" "${GCORE_CLIENT_CA_KEY_FILE}" \
            "${GCORE_CLIENT_CERT_FILE}" "${GCORE_CLIENT_KEY_FILE}"
    fi
    if [[ ! -s "${GCORE_CLIENT_CA_FILE}" || ! -s "${GCORE_CLIENT_CA_KEY_FILE}" \
        || ! -s "${GCORE_CLIENT_CERT_FILE}" || ! -s "${GCORE_CLIENT_KEY_FILE}" ]]; then
        info "生成仅供 Gcore 回源使用的 mTLS 客户端证书"
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
            -out "${GCORE_CLIENT_CA_KEY_FILE}" >/dev/null 2>&1
        openssl req -x509 -new -sha256 -days 3650 \
            -key "${GCORE_CLIENT_CA_KEY_FILE}" \
            -subj '/CN=easy_all Gcore origin client CA' \
            -addext 'basicConstraints=critical,CA:TRUE' \
            -addext 'keyUsage=critical,keyCertSign,cRLSign' \
            -out "${GCORE_CLIENT_CA_FILE}" >/dev/null 2>&1
        openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 \
            -out "${GCORE_CLIENT_KEY_FILE}" >/dev/null 2>&1
        openssl req -new -sha256 -key "${GCORE_CLIENT_KEY_FILE}" \
            -subj '/CN=easy_all Gcore CDN origin client' -out "${csr}" >/dev/null 2>&1
        cat >"${extension}" <<'EOF'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=clientAuth
EOF
        openssl x509 -req -sha256 -days 1095 -in "${csr}" \
            -CA "${GCORE_CLIENT_CA_FILE}" -CAkey "${GCORE_CLIENT_CA_KEY_FILE}" \
            -CAcreateserial -extfile "${extension}" \
            -out "${GCORE_CLIENT_CERT_FILE}" >/dev/null 2>&1
        rm -f -- "${CERT_DIR}/gcore-client-ca.srl"
        chmod 0600 "${GCORE_CLIENT_CA_FILE}" "${GCORE_CLIENT_CA_KEY_FILE}" \
            "${GCORE_CLIENT_CERT_FILE}" "${GCORE_CLIENT_KEY_FILE}"
    fi
    openssl verify -CAfile "${GCORE_CLIENT_CA_FILE}" "${GCORE_CLIENT_CERT_FILE}" >/dev/null \
        || die "Gcore mTLS 客户端证书校验失败"
    awk '/-----BEGIN CERTIFICATE-----/{n++} n >= 2 {print}' "${CERT_FILE}" \
        >"${GCORE_ORIGIN_ISSUER_FILE}"
    [[ -s "${GCORE_ORIGIN_ISSUER_FILE}" ]] \
        || die "源站 fullchain 未包含签发 CA，无法启用 Gcore Origin SSL Validation"
    openssl x509 -in "${GCORE_ORIGIN_ISSUER_FILE}" -noout >/dev/null \
        || die "源站证书链中的 CA 证书无效"
    chmod 0600 "${GCORE_ORIGIN_ISSUER_FILE}"
    CURRENT_GCORE_ORIGIN_ISSUER_SHA256=$(openssl x509 -in "${GCORE_ORIGIN_ISSUER_FILE}" \
        -noout -fingerprint -sha256 | cut -d= -f2 | tr -d ':')
    [[ "${CURRENT_GCORE_ORIGIN_ISSUER_SHA256}" =~ ^[A-F0-9]{64}$ ]] \
        || die "无法计算 Gcore 源站签发 CA 指纹"
}

validate_gcore_origin_issuer_synced() {
    gcore_prepare_origin_validation_material
    [[ -z "${GCORE_ORIGIN_ISSUER_SHA256:-}" \
        || "${GCORE_ORIGIN_ISSUER_SHA256}" == "${CURRENT_GCORE_ORIGIN_ISSUER_SHA256}" ]] \
        || die "源站证书签发链已变化；请执行 easy_all apply-cloud 同步 Gcore Trusted CA"
}

gcore_named_certificate_id() {
    local endpoint=$1 name=$2 response matches count
    response=$(gcore_api_request GET "${endpoint}?limit=1000")
    matches=$(printf '%s' "${response}" | gcore_json_items | jq -c --arg name "${name}" \
        '[.[] | select(.name == $name)]')
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Gcore 中发现多个同名证书：${name}"
    jq -r '.[0].id // empty' <<<"${matches}"
}

gcore_ensure_origin_validation_certificates() {
    local ca_name client_name ca_body client_body certificate_chain current
    gcore_prepare_origin_validation_material
    ca_name=$(gcore_origin_ca_name)
    client_name="easy-all-origin-client-${GCORE_ORIGIN_DOMAIN}"
    ca_body=$(jq -cn --arg name "${ca_name}" \
        --rawfile certificate "${GCORE_ORIGIN_ISSUER_FILE}" \
        '{name:$name,sslCertificate:$certificate}')
    GCORE_ORIGIN_CA_ID=$(gcore_named_certificate_id '/cdn/sslCertificates' "${ca_name}")
    if [[ "${GCORE_ORIGIN_CA_ID:-}" =~ ^[0-9]+$ ]]; then
        current=$(gcore_api_request GET "/cdn/sslCertificates/${GCORE_ORIGIN_CA_ID}")
        jq -e --arg expected "${ca_name}" '.name == $expected' <<<"${current}" >/dev/null \
            || die "状态中的 Gcore Trusted CA 所有权标记不匹配"
    else
        GCORE_ORIGIN_CA_ID=$(gcore_api_request POST '/cdn/sslCertificates' "${ca_body}" \
            | jq -r '.id // empty')
    fi
    [[ "${GCORE_ORIGIN_CA_ID:-}" =~ ^[0-9]+$ ]] \
        || die "Gcore 未返回源站 Trusted CA ID"

    certificate_chain=$(printf '%s\n%s\n' \
        "$(<"${GCORE_CLIENT_CERT_FILE}")" "$(<"${GCORE_CLIENT_CA_FILE}")")
    client_body=$(jq -cn --arg name "${client_name}" \
        --arg certificate "${certificate_chain}" \
        --rawfile private_key "${GCORE_CLIENT_KEY_FILE}" \
        '{name:$name,sslCertificate:$certificate,sslPrivateKey:$private_key,validate_root_ca:false}')
    GCORE_ORIGIN_CLIENT_CERT_ID=${GCORE_ORIGIN_CLIENT_CERT_ID:-$(gcore_named_certificate_id \
        '/cdn/sslData' "${client_name}")}
    if [[ "${GCORE_ORIGIN_CLIENT_CERT_ID:-}" =~ ^[0-9]+$ ]]; then
        current=$(gcore_api_request GET "/cdn/sslData/${GCORE_ORIGIN_CLIENT_CERT_ID}")
        jq -e --arg expected "${client_name}" '.name == $expected' <<<"${current}" >/dev/null \
            || die "状态中的 Gcore 回源客户端证书所有权标记不匹配"
        gcore_api_request PUT "/cdn/sslData/${GCORE_ORIGIN_CLIENT_CERT_ID}" "${client_body}" >/dev/null
    else
        gcore_api_request POST '/cdn/sslData' "${client_body}" >/dev/null
        GCORE_ORIGIN_CLIENT_CERT_ID=$(gcore_named_certificate_id \
            '/cdn/sslData' "${client_name}")
    fi
    [[ "${GCORE_ORIGIN_CLIENT_CERT_ID:-}" =~ ^[0-9]+$ ]] \
        || die "Gcore 未返回回源客户端证书 ID"
    GCORE_ORIGIN_ISSUER_SHA256=${CURRENT_GCORE_ORIGIN_ISSUER_SHA256}
}

gcore_ensure_origin_group() {
    local groups matches count body name current
    name=$(gcore_origin_group_name)
    body=$(jq -cn --arg name "${name}" --arg origin "${GCORE_ORIGIN_DOMAIN}:443" '
        {name:$name,use_next:false,
         sources:[{source:$origin,enabled:true,backup:false,host_header_override:($origin | sub(":443$";""))}]}
    ')
    if [[ -n "${GCORE_ORIGIN_GROUP_ID:-}" ]]; then
        current=$(gcore_api_request GET "/cdn/origin_groups/${GCORE_ORIGIN_GROUP_ID}")
        jq -e --arg expected "${name}" '.name == $expected' <<<"${current}" >/dev/null \
            || die "状态中的 Gcore 源组所有权标记不匹配"
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
    local subscription_domain
    subscription_domain=$(active_subscription_link_domain)
    jq -cn --arg domain "${VLESS_CDN_DOMAIN}" --arg subscription "${subscription_domain}" \
        --arg origin "${GCORE_ORIGIN_DOMAIN}" \
        --argjson origin_group "${GCORE_ORIGIN_GROUP_ID}" \
        --argjson origin_ca "${GCORE_ORIGIN_CA_ID}" \
        --argjson client_cert "${GCORE_ORIGIN_CLIENT_CERT_ID}" '
        {
          cname:$domain,
          secondaryHostnames:(if $subscription == $domain then [] else [$subscription] end),
          name:("easy_all xhttp " + $domain),
          originGroup:$origin_group,
          originProtocol:"HTTPS",
          proxy_ssl_enabled:true,
          proxy_ssl_ca:$origin_ca,
          proxy_ssl_data:$client_cert,
          active:true,
          options:{
            allowedHttpMethods:{enabled:true,value:["GET","HEAD","POST"]},
            websockets:{enabled:true,value:true},
            edge_cache_settings:{enabled:true,value:"0s"},
            browser_cache_settings:{enabled:true,value:"0s"},
            ignoreQueryString:{enabled:true,value:false},
            hostHeader:{enabled:true,value:$origin},
            sni:{enabled:true,sni_type:"custom",custom_hostname:$origin},
            proxy_connect_timeout:{enabled:true,value:"5s"},
            use_dns01_le_challenge:{enabled:true,value:true}
          }
        }
    '
}

gcore_ensure_resource() {
    local resources matches count payload created current
    payload=$(gcore_resource_payload)
    if [[ -n "${GCORE_CDN_RESOURCE_ID:-}" ]]; then
        current=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}")
        jq -e --arg domain "${VLESS_CDN_DOMAIN}" \
            --arg name "easy_all xhttp ${VLESS_CDN_DOMAIN}" \
            --arg legacy_name "easy_all websocket ${VLESS_CDN_DOMAIN}" '
            (.cname | rtrimstr(".") | ascii_downcase) == $domain
            and (.name == $name or .name == $legacy_name)
        ' <<<"${current}" >/dev/null \
            || die "状态中的 Gcore CDN 资源所有权标记不匹配"
        gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" "${payload}" >/dev/null
        return 0
    fi
    resources=$(gcore_api_request GET '/cdn/resources?limit=1000')
    matches=$(printf '%s' "${resources}" | gcore_json_items | jq -c --arg domain "${VLESS_CDN_DOMAIN}" \
        '[.[] | select((.cname // "" | rtrimstr(".") | ascii_downcase) == $domain)]')
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Gcore 中发现多个使用 ${VLESS_CDN_DOMAIN} 的 CDN 资源"
    if ((count == 1)); then
        jq -e --arg expected "easy_all xhttp ${VLESS_CDN_DOMAIN}" \
            --arg legacy "easy_all websocket ${VLESS_CDN_DOMAIN}" \
            '.[0].name == $expected or .[0].name == $legacy' <<<"${matches}" >/dev/null \
            || die "${VLESS_CDN_DOMAIN} 已被非 easy_all Gcore 资源占用，拒绝接管"
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
    local account
    account=$(gcore_api_request GET '/cdn/clients/me')
    GCORE_CDN_TARGET=$(jq -r '.cname // empty' <<<"${account}")
    GCORE_CDN_TARGET=$(normalize_domain "${GCORE_CDN_TARGET}")
    validate_domain "${GCORE_CDN_TARGET}" && [[ "${GCORE_CDN_TARGET}" == *.gcdn.co ]] \
        || die "Gcore /cdn/clients/me 未返回有效的账户专属 CNAME 目标"
}

gcore_certificate_name() {
    local subscription_domain suffix
    subscription_domain=$(active_subscription_link_domain)
    if [[ "${subscription_domain}" == "${VLESS_CDN_DOMAIN}" ]]; then
        printf 'easy-all-%s' "${VLESS_CDN_DOMAIN}"
        return
    fi
    suffix=$(printf '%s|%s' "${VLESS_CDN_DOMAIN}" "${subscription_domain}" \
        | sha256sum | cut -c1-16)
    printf 'easy-all-%s-%s' "${VLESS_CDN_DOMAIN}" "${suffix}"
}

gcore_attach_edge_certificate() {
    gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
        "$(jq -cn --argjson cert "${GCORE_SSL_CERT_ID}" \
            '{sslEnabled:true,sslData:$cert}')" >/dev/null
    gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
        "$(jq -cn '{options:{redirect_http_to_https:{enabled:true,value:true}}}')" \
        >/dev/null
}

gcore_ensure_edge_certificate() {
    local name certificates matches count attempt patch certificate_details
    name=$(gcore_certificate_name)

    if [[ "${GCORE_SSL_CERT_ID:-}" =~ ^[0-9]+$ ]]; then
        certificate_details=$(gcore_api_request GET "/cdn/sslData/${GCORE_SSL_CERT_ID}") \
            || die "读取现有 Gcore 边缘证书失败"
        jq -e '.automated == true' <<<"${certificate_details}" >/dev/null \
            || die "状态中的 Gcore 证书不是自动 Let's Encrypt 证书，拒绝替换"
        gcore_attach_edge_certificate
        info "复用现有 Gcore 自动证书；secondary hostname 变化由同一 CDN 资源自动补发证书"
        return 0
    fi

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
    gcore_attach_edge_certificate
}

gcore_wait_for_cdn_health() {
    local subscription_domain
    gcore_wait_for_domain_health "${VLESS_CDN_DOMAIN}" "CDN"
    subscription_domain=$(active_subscription_link_domain)
    if subscription_enabled && [[ "${subscription_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        gcore_wait_for_domain_health "${subscription_domain}" "订阅"
    fi
}

gcore_probe_xhttp() {
    local probe_dir="${RUNTIME_TMP}/gcore-xhttp-probe"
    local probe_config="${probe_dir}/config.json"
    local probe_log="${probe_dir}/xray.log"
    local probe_port=0 probe_pid=0 attempt response http_code
    install -d -m 0700 "${probe_dir}"
    for attempt in {1..20}; do
        probe_port=$((20000 + RANDOM % 20000))
        if ! ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
            break
        fi
        probe_port=0
    done
    ((probe_port > 0)) || return 1

    jq -n --arg address "${VLESS_CDN_DOMAIN}" --arg host "${VLESS_CDN_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" --arg path "$(xhttp_client_path)" \
        --argjson port "${probe_port}" '
        {
          log:{loglevel:"error"},
          inbounds:[{
            tag:"gcore-xhttp-probe-socks", listen:"127.0.0.1", port:$port,
            protocol:"socks", settings:{udp:false}
          }],
          outbounds:[{
            tag:"proxy", protocol:"vless",
            settings:{vnext:[{
              address:$address, port:443,
              users:[{id:$uuid,encryption:"none"}]
            }]},
            streamSettings:{
              network:"xhttp", security:"tls",
              tlsSettings:{serverName:$host,alpn:["h2"],fingerprint:"chrome"},
              xhttpSettings:{
                host:$host, path:$path, mode:"packet-up",
                extra:{uplinkHTTPMethod:"POST"}
              }
            }
          }]
        }
    ' >"${probe_config}" || return 1
    "${XRAY_BIN}" run -test -config "${probe_config}" >/dev/null 2>"${probe_log}" \
        || return 1
    "${XRAY_BIN}" run -config "${probe_config}" >"${probe_log}" 2>&1 &
    probe_pid=$!
    for attempt in {1..10}; do
        if ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
            break
        fi
        sleep 1
    done
    if ! ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
        kill "${probe_pid}" >/dev/null 2>&1 || true
        wait "${probe_pid}" >/dev/null 2>&1 || true
        return 1
    fi

    response=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:${probe_port}" \
        --connect-timeout 10 --max-time 30 \
        -w $'\n%{http_code}' 'https://cp.cloudflare.com/generate_204' 2>/dev/null \
        || true)
    http_code=${response##*$'\n'}
    response=${response%$'\n'*}
    kill "${probe_pid}" >/dev/null 2>&1 || true
    wait "${probe_pid}" >/dev/null 2>&1 || true
    [[ "${http_code}" == "204" ]]
}

gcore_probe_websocket() {
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
        --arg uuid "${VLESS_UUID}" --arg path "${WEBSOCKET_PATH}" \
        --argjson port "${probe_port}" '
        {log:{loglevel:"error"},
         inbounds:[{tag:"gcore-websocket-probe-socks",listen:"127.0.0.1",port:$port,
                    protocol:"socks",settings:{udp:false}}],
         outbounds:[{tag:"proxy",protocol:"vless",
          settings:{vnext:[{address:$address,port:443,users:[{id:$uuid,encryption:"none"}]}]},
          streamSettings:{network:"ws",security:"tls",
           tlsSettings:{serverName:$host,alpn:["http/1.1"],fingerprint:"chrome"},
           wsSettings:{path:$path,headers:{Host:$host}}}}]}
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
        'https://cp.cloudflare.com/generate_204' 2>/dev/null || true)
    http_code=${response##*$'\n'}
    kill "${probe_pid}" >/dev/null 2>&1 || true
    wait "${probe_pid}" >/dev/null 2>&1 || true
    [[ "${http_code}" == "204" ]]
}

gcore_wait_for_domain_health() {
    local domain=$1 label=$2 attempt status response http_code transport_status transport_verified=0
    local certificate_state certificate_status certificate_error curl_error
    local health_body="${RUNTIME_TMP}/gcore-health-body"
    local health_error="${RUNTIME_TMP}/gcore-health-error"
    info "等待 Gcore ${label}域名 ${domain} 的 CDN 与 Let's Encrypt 证书部署；链路生效可能较慢，请耐心等待，当前公网验收超时约 15 分钟（90 次、每次间隔 10 秒，API/网络请求耗时另计）"
    certificate_status="PENDING"
    for attempt in {1..90}; do
        status=$(gcore_api_request GET "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
            | jq -r '.status // empty' | tr '[:upper:]' '[:lower:]')
        if ((attempt == 1 || attempt % 3 == 0)); then
            certificate_state=$(gcore_api_request GET \
                "/cdn/sslData/${GCORE_SSL_CERT_ID}/status") \
                || die "无法读取 Gcore Let's Encrypt 签发状态"
            certificate_status=$(jq -r '
                if (.latest_status.status? // "") != "" then
                    .latest_status.status | ascii_upcase
                elif .active == true then "PROCESSING"
                else "PENDING"
                end
            ' <<<"${certificate_state}")
            case "${certificate_status}" in
            FAILED | CANCELLED)
                certificate_error=$(jq -r '
                    [.latest_status.error?, .latest_status.details?]
                    | map(select(. != null and . != "")) | join(": ")
                ' <<<"${certificate_state}")
                die "Gcore Let's Encrypt 签发${certificate_status}：${certificate_error:-未返回错误详情}"
                ;;
            esac
        fi

        : >"${health_body}"
        : >"${health_error}"
        http_code=$(curl -sS --proto '=https' --noproxy '*' \
            --connect-timeout 5 --max-time 15 -o "${health_body}" \
            -w '%{http_code}' "https://${domain}/easy_all-health" \
            2>"${health_error}" || true)
        response=$(<"${health_body}")
        transport_status="not-run"
        if [[ "${label}" == "CDN" ]]; then
            if ((transport_verified == 1)); then
                transport_status="ok"
            elif [[ "${http_code}" == "200" && "${response}" == "easy_all ok" ]] \
                && ((attempt == 1 || attempt % 3 == 0)); then
                if gcore_probe_xhttp && gcore_probe_websocket; then
                    transport_verified=1
                    transport_status="ok"
                else
                    transport_status="failed"
                fi
            else
                transport_status="pending"
            fi
        fi
        if [[ "${http_code}" == "200" && "${response}" == "easy_all ok" ]] \
            && { [[ "${label}" != "CDN" ]] || ((transport_verified == 1)); }; then
            [[ "${status}" == "active" ]] \
                || warn "Gcore Resource 状态仍为 ${status:-unknown}，但 ${label}域名端到端 HTTPS 验收已通过"
            success "Gcore ${label}域名回源、边缘证书与 XHTTP/WebSocket 验收通过"
            return 0
        fi
        if ((attempt == 1 || attempt % 3 == 0)); then
            curl_error=$(tr '\n' ' ' <"${health_error}")
            info "Gcore ${label}域名状态：Resource=${status:-unknown}，Let's Encrypt=${certificate_status}，HTTPS=${http_code:-000}，双链路=${transport_status}${curl_error:+（${curl_error}）}"
        fi
        sleep 10
    done
    die "Gcore ${label}域名 ${domain} 公网验收失败；请检查 CNAME、源站证书、Origin Key、CDN 资源和 Let's Encrypt 状态"
}

gcore_prepare_origin() {
    gcore_collect_api_token
    # Both reads are deliberately required.  A CDN-only or DNS-only token cannot
    # reach a later write step with partial state.
    gcore_api_request GET '/cdn/resources?limit=1' >/dev/null
    GCORE_DNS_ZONE=$(gcore_find_zone_for_domain "${GCORE_ORIGIN_DOMAIN}")
    [[ -n "${GCORE_DNS_ZONE}" ]] \
        || die "Gcore Managed DNS 中没有覆盖源站域名 ${GCORE_ORIGIN_DOMAIN} 的 Zone；请先按 docs/preparation-guide.md 委派整个主域名"
    gcore_validate_dns_zones
    gcore_verify_zone_delegation "${GCORE_DNS_ZONE}"
    if [[ "${GCORE_SUBSCRIPTION_DNS_ZONE}" != "${GCORE_DNS_ZONE}" ]]; then
        gcore_verify_zone_delegation "${GCORE_SUBSCRIPTION_DNS_ZONE}"
    fi
    gcore_ensure_origin_a_record
    gcore_wait_for_origin_dns
}

gcore_apply_cdn() {
    local skip_health=${1:-0}
    if validate_domain "${GCORE_CDN_TARGET:-}" \
        && [[ "${GCORE_CDN_TARGET}" == *.gcdn.co ]]; then
        # During update-sub the delivery target is already known.  Publish a
        # missing subscription CNAME before adding the secondary hostname so
        # Gcore can reissue the existing automated certificate immediately.
        gcore_ensure_cname_record
        gcore_wait_for_cdn_dns
    fi
    gcore_ensure_origin_validation_certificates
    gcore_ensure_origin_group
    gcore_ensure_resource
    gcore_detect_cdn_target
    gcore_ensure_cname_record
    gcore_wait_for_cdn_dns
    gcore_ensure_edge_certificate
    [[ "${skip_health}" == "1" ]] || gcore_wait_for_cdn_health
}

snapshot_gcore_subscription_domain_records() {
    local domain=$1 zone=$2 type existing
    printf '%s\n' "${domain}" >"${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain"
    printf '%s\n' "${zone}" >"${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain-zone"
    for type in A AAAA CNAME; do
        if existing=$(gcore_api_get_optional \
            "/dns/v2/zones/${zone}/${domain}/${type}"); then
            printf '%s\n' "${existing}" \
                >"${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain-${type}.json"
        else
            install -m 0600 /dev/null \
                "${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain-${type}.missing"
        fi
    done
}

snapshot_gcore_subscription_cloud_update() {
    local new_domain
    (
        SUBSCRIPTION_MODE=${GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_MODE}
        SUBSCRIPTION_DOMAIN=${GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_DOMAIN}
        gcore_resource_payload
    ) >"${UPDATE_SUB_BACKUP_DIR}/gcore-resource-payload.json"
    new_domain=$(active_subscription_link_domain)
    if subscription_enabled && [[ "${new_domain}" != "${VLESS_CDN_DOMAIN}" ]]; then
        snapshot_gcore_subscription_domain_records \
            "${new_domain}" "${GCORE_SUBSCRIPTION_DNS_ZONE}"
    fi
    GCORE_SUBSCRIPTION_CLOUD_ROLLBACK_ON_EXIT=1
}

restore_gcore_subscription_domain_records() {
    local domain zone type existing body
    [[ -f "${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain" ]] || return 0
    domain=$(<"${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain")
    zone=$(<"${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain-zone")
    for type in A AAAA CNAME; do
        if [[ -f "${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain-${type}.json" ]]; then
            body=$(jq -c '{ttl,resource_records}' \
                "${UPDATE_SUB_BACKUP_DIR}/gcore-new-domain-${type}.json")
            gcore_api_request PUT "/dns/v2/zones/${zone}/${domain}/${type}" \
                "${body}" >/dev/null
        elif existing=$(gcore_api_get_optional \
            "/dns/v2/zones/${zone}/${domain}/${type}"); then
            gcore_api_request DELETE "/dns/v2/zones/${zone}/${domain}/${type}" \
                >/dev/null
        fi
    done
}

rollback_provider_subscription_update() {
    [[ "${GCORE_SUBSCRIPTION_CLOUD_ROLLBACK_ON_EXIT:-0}" == "1" ]] || return 0
    warn "云端订阅更新失败，正在恢复 Gcore CDN secondary hostname 与新域名 DNS"
    gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
        "$(<"${UPDATE_SUB_BACKUP_DIR}/gcore-resource-payload.json")" >/dev/null
    if [[ "${GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_SSL_CERT_ID:-}" =~ ^[0-9]+$ ]]; then
        gcore_api_request PATCH "/cdn/resources/${GCORE_CDN_RESOURCE_ID}" \
            "$(jq -cn --argjson cert "${GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_SSL_CERT_ID}" \
                '{sslEnabled:true,sslData:$cert}')" >/dev/null
    fi
    restore_gcore_subscription_domain_records
    gcore_clear_api_token
}

remove_previous_gcore_subscription_cname() {
    local domain=$1 zone=$2 existing
    [[ -n "${domain}" && -n "${zone}" \
        && "${domain}" != "${VLESS_CDN_DOMAIN}" ]] || return 0
    if ! existing=$(gcore_api_get_optional \
        "/dns/v2/zones/${zone}/${domain}/CNAME"); then
        return 0
    fi
    if ! jq -e --arg value "${GCORE_CDN_TARGET}" '
        [.resource_records[]?.content[]? | rtrimstr(".")] | unique
        == [($value|rtrimstr("."))]
    ' <<<"${existing}" >/dev/null; then
        warn "旧订阅域名 ${domain} 已不再准确指向当前 Gcore CDN，出于安全考虑未删除 DNS"
        return 0
    fi
    if gcore_api_request DELETE "/dns/v2/zones/${zone}/${domain}/CNAME" >/dev/null; then
        success "已清理旧订阅域名 ${domain} 的 Gcore CNAME"
    else
        warn "清理旧订阅域名 ${domain} 的 Gcore CNAME 失败，请手动复核"
    fi
}

collect_install_inputs() {
    PROTOCOL="xhttp"
    CDN_PROVIDER="gcore"
    choose_cdn_client_ip_family
    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-GCORE}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效：${VLESS_UUID}"

    GCORE_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN:-$(prompt_value \
        "Gcore 源站域名（脚本创建 A 记录）" "" \
        "Gcore origin domain (the script creates the A record)")}
    GCORE_ORIGIN_DOMAIN=$(normalize_domain "${GCORE_ORIGIN_DOMAIN}")
    validate_domain "${GCORE_ORIGIN_DOMAIN}" || die "GCORE_ORIGIN_DOMAIN 无效：${GCORE_ORIGIN_DOMAIN}"
    XHTTP_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}

    VLESS_CDN_DOMAIN=${VLESS_CDN_DOMAIN:-$(prompt_value \
        "Gcore CDN 节点域名" "" "Gcore CDN node domain")}
    VLESS_CDN_DOMAIN=$(normalize_domain "${VLESS_CDN_DOMAIN}")
    validate_domain "${VLESS_CDN_DOMAIN}" || die "VLESS_CDN_DOMAIN 无效：${VLESS_CDN_DOMAIN}"
    [[ "${GCORE_ORIGIN_DOMAIN}" != "${VLESS_CDN_DOMAIN}" ]] || die "源站域名与 CDN 域名不能相同"
    GCORE_DNS_ZONE=""
    GCORE_ORIGIN_GROUP_ID=""
    GCORE_CDN_RESOURCE_ID=""
    GCORE_SSL_CERT_ID=""
    GCORE_ORIGIN_CA_ID=""
    GCORE_ORIGIN_CLIENT_CERT_ID=""
    GCORE_ORIGIN_ISSUER_SHA256=""
    GCORE_CDN_TARGET=""
    GCORE_ORIGIN_A_OWNED=0
    GCORE_CDN_CNAME_OWNED=0
    GCORE_SUBSCRIPTION_CNAME_OWNED=0
    CDN_TRAFFIC_PROTECTION_GB=${GCORE_CDN_TRAFFIC_PROTECTION_GB}
    configure_cdn_traffic_protection

    XHTTP_PATH=${XHTTP_PATH:-/xhttp-$(openssl rand -hex 16)}
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效：${XHTTP_PATH}"
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-/ws-$(openssl rand -hex 16)}
    validate_xhttp_path "${WEBSOCKET_PATH}" || die "WEBSOCKET_PATH 无效：${WEBSOCKET_PATH}"
    [[ "${WEBSOCKET_PATH}" != "${XHTTP_PATH}" ]] || die "WebSocket 与 XHTTP 路径不能相同"
    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        || die "XRAY_XHTTP_LOOPBACK_PORT 无效：${XRAY_XHTTP_LOOPBACK_PORT}"
    XRAY_WEBSOCKET_LOOPBACK_PORT=${XRAY_WEBSOCKET_LOOPBACK_PORT:-${DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" \
        || die "XRAY_WEBSOCKET_LOOPBACK_PORT 无效：${XRAY_WEBSOCKET_LOOPBACK_PORT}"
    [[ "${XRAY_WEBSOCKET_LOOPBACK_PORT}" != "${XRAY_XHTTP_LOOPBACK_PORT}" ]] \
        || die "WebSocket 与 XHTTP 本机端口不能相同"
    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "ORIGIN_HEADER_SECRET 格式无效"
    choose_subscription_mode
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
    fi
}

load_state() {
    local variable env_name
    local -a variables=(
        PROTOCOL CDN_PROVIDER
        CDN_CLIENT_IP_FAMILY XHTTP_NODE_NAME VLESS_UUID
        VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN XHTTP_PATH WEBSOCKET_PATH
        GCORE_ORIGIN_DOMAIN GCORE_DNS_ZONE GCORE_SUBSCRIPTION_DNS_ZONE
        GCORE_ORIGIN_GROUP_ID GCORE_CDN_RESOURCE_ID
        GCORE_SSL_CERT_ID GCORE_ORIGIN_CA_ID GCORE_ORIGIN_CLIENT_CERT_ID
        GCORE_CDN_TARGET GCORE_ORIGIN_ISSUER_SHA256 CDN_TRAFFIC_PROTECTION_GB
        VPS_PUBLIC_IPV4 GCORE_ORIGIN_A_OWNED GCORE_CDN_CNAME_OWNED
        GCORE_SUBSCRIPTION_CNAME_OWNED
        XRAY_XHTTP_LOOPBACK_PORT XRAY_WEBSOCKET_LOOPBACK_PORT
        ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
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
    [[ "${CDN_PROVIDER:-}" == "gcore" \
        && ( "${PROTOCOL}" == "xhttp" || "${PROTOCOL}" == "ws" ) ]] \
        || die "状态不是 Gcore CDN XHTTP；请重新安装"
    GCORE_TRANSPORT_MIGRATION_REQUIRED=0
    [[ -n "${WEBSOCKET_PATH:-}" && -n "${XRAY_WEBSOCKET_LOOPBACK_PORT:-}" ]] \
        || GCORE_TRANSPORT_MIGRATION_REQUIRED=1
    if [[ "${PROTOCOL}" == "ws" ]]; then
        GCORE_TRANSPORT_MIGRATION_REQUIRED=1
        WEBSOCKET_PATH=${WEBSOCKET_PATH:-${XHTTP_PATH}}
        XHTTP_PATH="/xhttp-${XHTTP_PATH##*-}"
        PROTOCOL=xhttp
    fi
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-/ws-${XHTTP_PATH##*-}}
    XRAY_WEBSOCKET_LOOPBACK_PORT=${XRAY_WEBSOCKET_LOOPBACK_PORT:-${DEFAULT_XRAY_WEBSOCKET_LOOPBACK_PORT}}
    configure_cdn_client_ip_family
    validate_domain "${GCORE_ORIGIN_DOMAIN:-}" || die "状态中的 Gcore 源站域名无效"
    validate_domain "${VLESS_CDN_DOMAIN:-}" || die "状态中的 Gcore CDN 域名无效"
    [[ "${GCORE_DNS_ZONE:-}" =~ ^[A-Za-z0-9.-]+$ ]] || die "状态中缺少 Gcore DNS Zone"
    [[ "${GCORE_SUBSCRIPTION_DNS_ZONE}" =~ ^[A-Za-z0-9.-]+$ ]] \
        || die "状态中缺少 Gcore 订阅 DNS Zone"
    [[ "${GCORE_ORIGIN_GROUP_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore 源组 ID"
    [[ "${GCORE_CDN_RESOURCE_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore CDN 资源 ID"
    [[ "${GCORE_SSL_CERT_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore 证书 ID"
    [[ "${GCORE_ORIGIN_CA_ID:-}" =~ ^[0-9]+$ ]] || die "状态中缺少 Gcore Trusted CA ID"
    [[ "${GCORE_ORIGIN_CLIENT_CERT_ID:-}" =~ ^[0-9]+$ ]] \
        || die "状态中缺少 Gcore 回源客户端证书 ID"
    [[ "${GCORE_ORIGIN_ISSUER_SHA256:-}" =~ ^[A-F0-9]{64}$ ]] \
        || die "状态中缺少 Gcore 源站签发 CA 指纹"
    for variable in GCORE_ORIGIN_A_OWNED GCORE_CDN_CNAME_OWNED GCORE_SUBSCRIPTION_CNAME_OWNED; do
        [[ "${!variable:-}" == "0" || "${!variable:-}" == "1" ]] \
            || die "状态中的 ${variable} 无效"
    done
    validate_domain "${GCORE_CDN_TARGET:-}" && [[ "${GCORE_CDN_TARGET}" == *.gcdn.co ]] \
        || die "状态中的 Gcore CDN 目标无效"
    validate_uuid "${VLESS_UUID:-}" || die "状态中的 VLESS UUID 无效"
    validate_xhttp_path "${XHTTP_PATH:-}" || die "状态中的 XHTTP 路径无效"
    validate_xhttp_path "${WEBSOCKET_PATH:-}" || die "状态中的 WebSocket 路径无效"
    [[ "${WEBSOCKET_PATH}" != "${XHTTP_PATH}" ]] || die "状态中的 WebSocket 与 XHTTP 路径相同"
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT:-}" \
        || die "状态中的 XHTTP 本机端口无效"
    validate_loopback_port "${XRAY_WEBSOCKET_LOOPBACK_PORT:-}" \
        || die "状态中的 WebSocket 本机端口无效"
    [[ "${XRAY_WEBSOCKET_LOOPBACK_PORT}" != "${XRAY_XHTTP_LOOPBACK_PORT}" ]] \
        || die "状态中的 WebSocket 与 XHTTP 本机端口相同"
    [[ "${ORIGIN_HEADER_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "状态中的源站保护密钥无效"
    XHTTP_ORIGIN_DOMAIN=${GCORE_ORIGIN_DOMAIN}
    configure_cdn_traffic_protection
    [[ "${XHTTP_NODE_NAME:-}" != "VLESS_XHTTP_GCORE" ]] || XHTTP_NODE_NAME="GCORE"
    [[ -n "${XHTTP_NODE_NAME:-}" ]] || die "状态缺少 XHTTP_NODE_NAME；请重新安装"
    [[ -n "${SUB_DOWNLOAD_NAME:-}" ]] || die "状态缺少 SUB_DOWNLOAD_NAME；请重新安装"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME}")
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-}") \
        || die "状态文件中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}"
    SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN:-}")
    validate_domain "${SUBSCRIPTION_DOMAIN}" \
        || die "状态文件中的 SUBSCRIPTION_DOMAIN 无效：${SUBSCRIPTION_DOMAIN}"
    [[ -z "${ALLOWED_TOKENS:-}" ]] \
        || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") \
        || die "状态文件中的 ALLOWED_TOKENS 无效"
    [[ "${QUOTA_ENABLED:-}" == "0" || "${QUOTA_ENABLED:-}" == "1" ]] \
        || die "状态缺少有效的 QUOTA_ENABLED；请重新安装"
    if quota_enabled; then
        validate_user_accounts "${USER_ACCOUNTS:-}" || die "状态文件中的 USER_ACCOUNTS 无效"
        [[ -n "${QUOTA_START_DATE:-}" ]] || die "状态缺少 QUOTA_START_DATE；请重新安装"
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
        printf 'CDN_CLIENT_IP_FAMILY=%q\n' "${CDN_CLIENT_IP_FAMILY}"
        printf 'XHTTP_NODE_NAME=%q\n' "${XHTTP_NODE_NAME}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID}"
        printf 'VLESS_CDN_DOMAIN=%q\n' "${VLESS_CDN_DOMAIN}"
        printf 'SUBSCRIPTION_DOMAIN=%q\n' "$(subscription_link_domain)"
        printf 'XHTTP_PATH=%q\n' "${XHTTP_PATH}"
        printf 'WEBSOCKET_PATH=%q\n' "${WEBSOCKET_PATH}"
        printf 'GCORE_ORIGIN_DOMAIN=%q\n' "${GCORE_ORIGIN_DOMAIN}"
        printf 'GCORE_DNS_ZONE=%q\n' "${GCORE_DNS_ZONE}"
        printf 'GCORE_SUBSCRIPTION_DNS_ZONE=%q\n' "${GCORE_SUBSCRIPTION_DNS_ZONE}"
        printf 'GCORE_ORIGIN_GROUP_ID=%q\n' "${GCORE_ORIGIN_GROUP_ID}"
        printf 'GCORE_CDN_RESOURCE_ID=%q\n' "${GCORE_CDN_RESOURCE_ID}"
        printf 'GCORE_SSL_CERT_ID=%q\n' "${GCORE_SSL_CERT_ID}"
        printf 'GCORE_ORIGIN_CA_ID=%q\n' "${GCORE_ORIGIN_CA_ID}"
        printf 'GCORE_ORIGIN_CLIENT_CERT_ID=%q\n' "${GCORE_ORIGIN_CLIENT_CERT_ID}"
        printf 'GCORE_ORIGIN_ISSUER_SHA256=%q\n' "${GCORE_ORIGIN_ISSUER_SHA256}"
        printf 'GCORE_CDN_TARGET=%q\n' "${GCORE_CDN_TARGET}"
        printf 'VPS_PUBLIC_IPV4=%q\n' "${VPS_PUBLIC_IPV4:-}"
        printf 'GCORE_ORIGIN_A_OWNED=%q\n' "${GCORE_ORIGIN_A_OWNED:-0}"
        printf 'GCORE_CDN_CNAME_OWNED=%q\n' "${GCORE_CDN_CNAME_OWNED:-0}"
        printf 'GCORE_SUBSCRIPTION_CNAME_OWNED=%q\n' "${GCORE_SUBSCRIPTION_CNAME_OWNED:-0}"
        printf 'CDN_TRAFFIC_PROTECTION_GB=%q\n' "${CDN_TRAFFIC_PROTECTION_GB}"
        printf 'XRAY_XHTTP_LOOPBACK_PORT=%q\n' "${XRAY_XHTTP_LOOPBACK_PORT}"
        printf 'XRAY_WEBSOCKET_LOOPBACK_PORT=%q\n' "${XRAY_WEBSOCKET_LOOPBACK_PORT}"
        printf 'ORIGIN_HEADER_SECRET=%q\n' "${ORIGIN_HEADER_SECRET}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'QUOTA_ENABLED=%q\n' "${QUOTA_ENABLED:-0}"
        printf 'USER_ACCOUNTS=%q\n' "${USER_ACCOUNTS:-}"
        printf 'QUOTA_START_DATE=%q\n' "${QUOTA_START_DATE:-}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME}"
        printf 'SUBSCRIPTION_MODE=%q\n' "${SUBSCRIPTION_MODE:-deploy}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Gcore CDN XHTTP 尚未安装"
    load_state
}

xhttp_validate_local_tls_curl_args() {
    XHTTP_LOCAL_TLS_CURL_ARGS+=(--cert "${GCORE_CLIENT_CERT_FILE}" --key "${GCORE_CLIENT_KEY_FILE}")
}

mihomo_transport_marker() {
    printf 'network: xhttp'
}

gcore_base_node_name() {
    local base=${XHTTP_NODE_NAME:-GCORE}
    base=${base#VLESS_}
    base=${base%_XHTTP}
    base=${base%_GCORE}
    base=${base%_WS}
    base=${base%_WEBSOCKET}
    base=${base%_PACKET_UP}
    [[ -n "${base}" ]] || base="GCORE"
    printf '%s' "${base}"
}

xhttp_auto_group_name() {
    printf '%s_AUTO' "$(gcore_base_node_name)"
}

xhttp_websocket_node_name() {
    printf '%s_WS' "$(gcore_base_node_name)"
}

xhttp_packet_up_node_name() {
    printf '%s_XHTTP' "$(gcore_base_node_name)"
}

build_vless_websocket_link() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-$(xhttp_websocket_node_name)}
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&alpn=http%%2F1.1&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${WEBSOCKET_PATH}")" "$(uri_encode "${node_name}")"
}

build_node_links() {
    local endpoint
    while IFS= read -r endpoint; do
        build_vless_xhttp_link "${endpoint}" "$(xhttp_packet_up_node_name)"
        printf '\n'
        build_vless_websocket_link "${endpoint}" "$(xhttp_websocket_node_name)"
        printf '\n'
    done < <(xhttp_client_endpoints)
}

build_mihomo_websocket_node() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-$(xhttp_websocket_node_name)}
    resolve_cdn_client_ip_family
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg path "${WEBSOCKET_PATH}" --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: ws\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: \($ip_version)\n    alpn:\n      - http/1.1\n" +
        "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($host|@json)\n"'
}

build_mihomo_nodes() {
    local endpoint
    while IFS= read -r endpoint; do
        build_mihomo_node_for_endpoint "${endpoint}" "$(xhttp_packet_up_node_name)"
        build_mihomo_websocket_node "${endpoint}" "$(xhttp_websocket_node_name)"
    done < <(xhttp_client_endpoints)
}

build_mihomo_proxy_names() {
    printf '        - %s\n' \
        "$(jq -Rn --arg value "$(xhttp_auto_group_name)" '$value')"
    printf '        - %s\n' \
        "$(jq -Rn --arg value "$(xhttp_websocket_node_name)" '$value')"
    printf '        - %s\n' \
        "$(jq -Rn --arg value "$(xhttp_packet_up_node_name)" '$value')"
}

build_mihomo_proxy_groups() {
    printf '    - name: %s\n' \
        "$(jq -Rn --arg value "$(xhttp_auto_group_name)" '$value')"
    cat <<EOF
      type: url-test
      proxies:
        - $(jq -Rn --arg value "$(xhttp_websocket_node_name)" '$value')
        - $(jq -Rn --arg value "$(xhttp_packet_up_node_name)" '$value')
      url: https://www.gstatic.com/generate_204
      interval: 600
      tolerance: 50
      timeout: 3000
      lazy: true
EOF
}

xhttp_render_xray_config() {
    local clients managed_outbounds managed_routing inbound_sockopt stats_enabled=false
    install -d -m 0755 "${XRAY_DIR}"
    if quota_enabled; then
        clients=$(quota_active_clients_json)
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" \
            '[{id:$id,email:$email}]')
    fi
    cdn_traffic_protection_blocked && clients='[]'
    traffic_stats_enabled && stats_enabled=true
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
    jq -n --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson websocket_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" \
        --argjson clients "${clients}" --argjson stats_enabled "${stats_enabled}" \
        --arg xhttp_path "${XHTTP_PATH}" --arg websocket_path "${WEBSOCKET_PATH}" \
        --arg host "${VLESS_CDN_DOMAIN}" \
        --arg padding "${GCORE_XHTTP_PADDING_BYTES}" \
        --arg mode "${XHTTP_MODE}" \
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
    local keepalive_referer
    keepalive_referer=$(xhttp_server_keepalive_referer)
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
    listen 443 ssl http2 backlog=4096 so_keepalive=15s:5s:3;
    listen [::]:443 ssl http2 backlog=4096 so_keepalive=15s:5s:3;
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
        proxy_set_header Referer "${keepalive_referer}";
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
    nginx -t >/dev/null || die "Nginx XHTTP + WebSocket 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS XHTTP packet-up/H2 + WebSocket over Gcore CDN\n节点链接:\n%s\n\n' "$(build_node_link)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_node
    printf '\n'
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: xhttp packet-up + websocket（Gcore CDN）\n源站域名: %s\nCDN 域名: %s\n订阅链接域名: %s\nGcore 目标: %s\nXHTTP 路径: %s\nWebSocket 路径: %s\n' \
        "${GCORE_ORIGIN_DOMAIN}" "${VLESS_CDN_DOMAIN}" "$(subscription_link_domain)" \
        "${GCORE_CDN_TARGET}" "${XHTTP_PATH}" "${WEBSOCKET_PATH}"
    show_bbrv3_status
    printf 'CDN 客户端节点族: %s（配置值）\n' \
        "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
    printf 'Gcore CDN 客户端接入: CDN 域名\n'
    printf 'Gcore DNS Zone: %s\nGcore 订阅 DNS Zone: %s\n源组 ID: %s\nCDN 资源 ID: %s\n边缘证书 ID: %s\nTrusted CA ID: %s\n回源客户端证书 ID: %s\n' \
        "${GCORE_DNS_ZONE}" "${GCORE_SUBSCRIPTION_DNS_ZONE}" \
        "${GCORE_ORIGIN_GROUP_ID}" "${GCORE_CDN_RESOURCE_ID}" "${GCORE_SSL_CERT_ID}" \
        "${GCORE_ORIGIN_CA_ID}" "${GCORE_ORIGIN_CLIENT_CERT_ID}"
    printf 'Xray: '; systemctl is-active --quiet "${XRAY_SERVICE}" && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '; systemctl is-active --quiet nginx && printf 'active\n' || printf 'inactive\n'
    printf 'UFW: '; LC_ALL=C ufw status 2>/dev/null | sed -n 's/^Status: //p'
    show_quota_status
    show_cdn_traffic_protection_status
}

update_subscription() {
    local previous_mode previous_domain previous_active_domain new_active_domain cloud_update=0
    local previous_subscription_zone previous_ssl_cert_id
    require_root
    begin_quota_maintenance
    collect_installed_state
    [[ "${GCORE_TRANSPORT_MIGRATION_REQUIRED}" != "1" ]] \
        || die "当前安装尚未启用 Gcore XHTTP + WebSocket 双链路；请先执行 easy_all apply-cloud 完成迁移"
    previous_mode=${SUBSCRIPTION_MODE}
    previous_domain=$(subscription_link_domain)
    previous_active_domain=${VLESS_CDN_DOMAIN}
    [[ "${previous_mode}" != "deploy" ]] || previous_active_domain=${previous_domain}
    previous_subscription_zone=${GCORE_SUBSCRIPTION_DNS_ZONE:-}
    previous_ssl_cert_id=${GCORE_SSL_CERT_ID:-}
    snapshot_subscription_update
    info "update-sub 会更新本机 Xray、订阅与 Nginx，并复用现有 Gcore CDN；仅在新增、更换或停用独立订阅域名时同步 secondary hostname、证书与 Managed DNS"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    validate_cdn_client_ip_family_runtime
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
    fi
    new_active_domain=$(active_subscription_link_domain)
    [[ "${new_active_domain}" == "${previous_active_domain}" ]] || cloud_update=1
    if subscription_enabled; then
        write_subscriptions
    else
        remove_subscriptions
    fi
    save_state
    refresh_runtime
    install_quota_timer
    install_cdn_traffic_protection_timer
    subscription_enabled && validate_subscription_runtime
    if [[ "${cloud_update}" == "1" ]]; then
        info "订阅域名发生变化，正在同步 Gcore CDN、边缘证书与 Managed DNS"
        gcore_collect_api_token
        gcore_validate_dns_zones
        gcore_verify_zone_delegation "${GCORE_SUBSCRIPTION_DNS_ZONE}"
        GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_MODE=${previous_mode}
        GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_DOMAIN=${previous_domain}
        GCORE_SUBSCRIPTION_ROLLBACK_PREVIOUS_SSL_CERT_ID=${previous_ssl_cert_id}
        snapshot_gcore_subscription_cloud_update
        gcore_apply_cdn
        save_state
        GCORE_SUBSCRIPTION_CLOUD_ROLLBACK_ON_EXIT=0
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        if [[ "${previous_mode}" == "deploy" \
            && "${previous_active_domain}" != "${new_active_domain}" ]]; then
            remove_previous_gcore_subscription_cname \
                "${previous_domain}" "${previous_subscription_zone}"
        fi
        gcore_clear_api_token
    fi
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    end_quota_maintenance
    show_subscription
    success "Nginx 订阅已刷新"
}

apply_easy_all() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    [[ "${GCORE_TRANSPORT_MIGRATION_REQUIRED}" != "1" ]] \
        || die "当前安装尚未启用 Gcore XHTTP + WebSocket 双链路；请执行 easy_all apply-cloud 一次性迁移"
    validate_gcore_origin_issuer_synced
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    finish_xhttp_apply
    install_cdn_traffic_protection_timer
    success "easy_all Gcore CDN XHTTP 本机配置与订阅已应用；未修改 Gcore 资源"
}

xhttp_renew_origin_certificate() {
    require_root
    collect_installed_state
    [[ "${GCORE_TRANSPORT_MIGRATION_REQUIRED}" != "1" ]] \
        || die "当前安装尚未启用 Gcore XHTTP + WebSocket 双链路；请先执行 easy_all apply-cloud 完成迁移"
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

apply_cloud_resources() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    gcore_prepare_origin
    if [[ "${GCORE_TRANSPORT_MIGRATION_REQUIRED}" == "1" ]]; then
        gcore_apply_cdn 1
        finish_xhttp_apply 1
        gcore_wait_for_cdn_health
    else
        gcore_apply_cdn
        finish_xhttp_apply 1
    fi
    gcore_clear_api_token
    success "easy_all Gcore CDN XHTTP 本机配置、Managed DNS、CDN 与证书已应用"
}

rollback_fresh_install() {
    warn "安装失败，正在恢复本机服务与防火墙；已创建的 Gcore DNS/CDN 资源不会自动删除"
    stop_services
    remove_quota_timer
    remove_cdn_traffic_protection_timer
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
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all Gcore CDN XHTTP 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        read_bilingual \
            '确认删除 easy_all Gcore CDN XHTTP 本机服务、状态和证书？默认保留远端 Gcore 资源。[y/N]（直接回车取消）:' \
            'Delete easy_all Gcore CDN XHTTP local services, state and certificates? Gcore resources are kept by default. [y/N] (press Enter to cancel):' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    UNINSTALL_PURGE_CLOUD=0
    [[ "${mode}" == "--purge-cloud" ]] && UNINSTALL_PURGE_CLOUD=1
    purge_gcore_resources_before_uninstall
    remove_managed_acme_cron
    stop_services
    remove_quota_timer
    remove_cdn_traffic_protection_timer
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    remove_managed_acme_domain "${GCORE_ORIGIN_DOMAIN:-}"
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    success "easy_all Gcore CDN XHTTP 本机内容已卸载；远端 Gcore 资源按卸载选项处理"
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
    alert "源站域名与 CDN 域名必须位于同一个已完整委派到 Gcore Managed DNS 的主域名；独立订阅域名也必须由 Gcore Managed DNS 托管。"
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
    install_cdn_traffic_protection_timer
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
请使用：easy_all install 或 easy_all uninstall [--purge-cloud]
EOF
}
