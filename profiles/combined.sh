#!/usr/bin/env bash
# Combined profile: direct Reality + Cloudflare XHTTP + Gcore WebSocket.
set -Eeuo pipefail
umask 077

readonly COMBINED_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XHTTP_LIB_DIR="${COMBINED_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="Cloudflare + Gcore"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray direct/Cloudflare/Gcore managed by easy_all"
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
source "${XHTTP_LIB_DIR}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/gcore-cdn.sh
source "${XHTTP_LIB_DIR}/gcore-cdn.sh"
# shellcheck source=lib/reality-target.sh
source "${XHTTP_LIB_DIR}/reality-target.sh"

readonly REALITY_PORT=8443
readonly XRAY_WEBSOCKET_LOOPBACK_PORT=10087
# XHTTP 侧的本机回环端口必须在这里定义：write_xray_config / write_nginx_config 都直接引用它，
# 缺了会在 set -u 下让首次安装崩在写配置阶段（该缺省来自 xhttp-runtime 的常量）。
# 这里刻意不接受环境覆盖：combined 没有针对该端口的校验与状态持久化，静默接受覆盖会出现
# "安装时用 A、之后 apply 又变回默认" 的隐性不一致；需要自定义端口时应先补校验、冲突检查与状态恢复。
readonly XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}"
readonly CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE_OVERRIDE:-https://api.cloudflare.com/client/v4}"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
readonly CF_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
readonly CLOUDFLARE_UFW_COMMENT="easy_all-cf-origin"
readonly CLOUDFLARE_ORIGIN_IPS_FILE="${STATE_DIR}/cloudflare-origin-ipv4.txt"
readonly GCORE_API_BASE="https://api.gcore.com"
readonly GCORE_UFW_COMMENT="easy_all-gcore-origin"
readonly GCORE_ORIGIN_IPS_FILE="${STATE_DIR}/gcore-origin-ipv4.txt"
# 新建的 Gcore 资源约 15 分钟才能在所有边缘生效（状态 processed），此期间 HTTP-01 必然失败。
# 先等资源 active + 节点 CNAME 生效（最多 30 分钟），再申请证书；失败时最多强制重试 2 次（间隔 60 秒）。
readonly GCORE_EDGE_READY_ATTEMPTS=120
readonly GCORE_EDGE_READY_INTERVAL=15
readonly GCORE_EDGE_PROPAGATION_ATTEMPTS=90
readonly GCORE_EDGE_PROPAGATION_INTERVAL=10
readonly GCORE_EDGE_FORCE_RETRIES=2
readonly GCORE_EDGE_FORCE_RETRY_INTERVAL=60
readonly GCORE_CERT_FILE="${CERT_DIR}/gcore-origin.pem"
readonly GCORE_KEY_FILE="${CERT_DIR}/gcore-origin.key"
readonly GCORE_CLIENT_CA_FILE="${CERT_DIR}/gcore-client-ca.crt"
readonly GCORE_CLIENT_CA_KEY="${CERT_DIR}/gcore-client-ca.key"
readonly GCORE_CLIENT_CERT_FILE="${CERT_DIR}/gcore-client.crt"
readonly GCORE_CLIENT_CERT_KEY="${CERT_DIR}/gcore-client.key"
readonly ACME_HOME="/root/.acme-combined.sh"
readonly ACME_BIN="${ACME_HOME}/acme.sh"
readonly ACME_OWNERSHIP_MARKER="${STATE_DIR}/acme-installed-by-easy_all"
readonly CERT_RELOAD_HOOK="${COMMAND_INSTALL_DIR}/reload-tls-service.sh"
readonly CLOUDFLARE_TOKEN_FILE="${STATE_DIR}/cloudflare.token"
readonly COMBINED_RECORD_COMMENT="easy_all combined"

PROTOCOL=combined
BACKEND=xray
CDN_PROVIDER=cloudflare
QUOTA_ENABLED=0
XHTTP_NODE_NAME=easy_all

load_state() {
    local variable
    local -a variables=(
        STATE_VERSION PROTOCOL TCP_ACCELERATION
        VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
        DIRECT_DOMAIN CF_NODE_DOMAIN CF_ORIGIN_DOMAIN GCORE_NODE_DOMAIN GCORE_ORIGIN_DOMAIN
        SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS VLESS_UUID
        DIRECT_NODE_NAME CF_NODE_PREFIX GCORE_NODE_NAME
        XHTTP_PATH WEBSOCKET_PATH REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
        CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
        GCORE_CDN_RESOURCE_ID GCORE_ORIGIN_GROUP_ID GCORE_ORIGIN_CLIENT_CERT_ID GCORE_ORIGIN_CA_ID
        GCORE_EDGE_CERTIFICATE_ID SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    for variable in "${variables[@]}"; do
        unset "${variable}" 2>/dev/null || true
    done
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；请重新安装"
    [[ "${PROTOCOL:-}" == "combined" ]] || die "状态协议不是 combined；请重新安装"
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]] || die "状态缺少 Cloudflare Zone ID；请重新安装"
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${CF_ORIGIN_DOMAIN}
    # 2.0.0 状态的组合模式没有这些字段，回退到当时的固定名称，避免 apply 时静默改名。
    : "${DIRECT_NODE_NAME:=直连}" "${CF_NODE_PREFIX:=CF-优选}" "${GCORE_NODE_NAME:=Gcore}"
    # 这里只告警不阻断：历史状态可能存着非法 Token，若在此 die，连 edit-sub 和 uninstall 都进不去。
    # 真正写配置前的拦截点在 combined_require_valid_owner_token。
    combined_tokens_ready \
        || warn "状态文件中的订阅 Token 不符合 8-128 位 URL 安全字符要求；请执行 sudo easy_all edit-sub 重新配置"
    combined_sync_allowed_tokens
    SUBSCRIPTION_MODE=deploy
}

collect_installed_state() {
    load_state
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") || die "创建状态暂存文件失败"
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        for variable in \
            PROTOCOL TCP_ACCELERATION VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID \
            DIRECT_DOMAIN CF_NODE_DOMAIN CF_ORIGIN_DOMAIN GCORE_NODE_DOMAIN GCORE_ORIGIN_DOMAIN \
            SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS VLESS_UUID \
            DIRECT_NODE_NAME CF_NODE_PREFIX GCORE_NODE_NAME \
            XHTTP_PATH WEBSOCKET_PATH REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID \
            CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON \
            GCORE_CDN_RESOURCE_ID GCORE_ORIGIN_GROUP_ID GCORE_ORIGIN_CLIENT_CERT_ID GCORE_ORIGIN_CA_ID \
            GCORE_EDGE_CERTIFICATE_ID SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR; do
            printf '%s=%q\n' "${variable}" "${!variable:-}"
        done
    } >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${STATE_FILE}"
}

validate_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *[[:cntrl:]]* ]]
}

collect_install_inputs() {
    params_declare CF_ZONE --required \
        --label 'Cloudflare 根 Zone（如 example.com）' \
        --normalize normalize_domain --check validate_domain
    params_declare DIRECT_DOMAIN --required \
        --label '直连节点域名' --default "node.${CF_ZONE}" \
        --normalize normalize_domain --check validate_domain
    params_declare CF_NODE_DOMAIN --required \
        --label 'Cloudflare 节点域名（橙云）' --default "cf.${CF_ZONE}" \
        --normalize normalize_domain --check validate_domain
    params_declare CF_ORIGIN_DOMAIN --required \
        --label 'Cloudflare 回源域名（橙云）' --default "cf-origin.${CF_ZONE}" \
        --normalize normalize_domain --check validate_domain
    params_declare GCORE_NODE_DOMAIN --required \
        --label 'Gcore 节点域名（灰云 CNAME）' --default "gcore.${CF_ZONE}" \
        --normalize normalize_domain --check validate_domain
    params_declare GCORE_ORIGIN_DOMAIN --required \
        --label 'Gcore 回源域名（灰云 A）' --default "gcore-origin.${CF_ZONE}" \
        --normalize normalize_domain --check validate_domain
    params_declare SUBSCRIPTION_DOMAIN --required \
        --label '订阅域名（橙云）' --default "sub.${CF_ZONE}" \
        --normalize normalize_domain --check validate_domain

    params_declare CLOUDFLARE_API_TOKEN --required --secret \
        --label 'Cloudflare API Token（DNS 编辑权限）' --check params_check_cf_token
    params_declare GCORE_API_TOKEN --required --secret \
        --label 'Gcore API Token（CDN 权限）' --check params_check_gcore_token
    params_declare GLOBALPING_TOKEN --required --secret \
        --label 'Globalping Access Token' --check validate_globalping_token

    params_declare REALITY_TARGET --required \
        --label 'Reality 伪装目标（域名:端口）' --default 'swdist.apple.com:443' \
        --normalize params_normalize_reality_target --check validate_reality_target
    params_declare XHTTP_PATH \
        --label 'XHTTP 路径（留空自动生成）' --default-fn params_default_xhttp_path \
        --normalize normalize_xhttp_path --check validate_xhttp_path
    params_declare WEBSOCKET_PATH \
        --label 'WebSocket 路径（留空自动生成）' --default-fn params_default_websocket_path \
        --check params_check_websocket_path

    params_declare DIRECT_NODE_NAME --required \
        --label '直连节点名' --default '🇺🇸直连' --check validate_node_name
    params_declare CF_NODE_PREFIX --required \
        --label 'Cloudflare 节点名前缀（自动追加 1~6）' --default '🇺🇸CF' \
        --check validate_node_name
    params_declare GCORE_NODE_NAME --required \
        --label 'Gcore 节点名' --default '🇺🇸GCore' --check validate_node_name
    params_declare SUB_DOWNLOAD_NAME --required \
        --label 'Mihomo 下载文件名（不含 .yaml）' --default "${DEFAULT_SUB_DOWNLOAD_NAME}" \
        --normalize normalize_sub_download_name --check validate_sub_download_name

    params_declare VLESS_UUID \
        --label '节点 UUID（留空自动生成）' --default-fn params_default_uuid --check validate_uuid
    params_declare OWNER_TOKEN \
        --label '订阅 Token（单个用户，留空自动生成；与 ALLOWED_TOKENS 二选一）' \
        --check params_check_token
    params_declare ALLOWED_TOKENS --type json_object \
        --label '订阅用户 Token 字典 {"用户":"token"}（与 OWNER_TOKEN 二选一）' \
        --normalize params_normalize_allowed_tokens

    params_declare VPS_PUBLIC_IPV4 \
        --label '本机公网 IPv4（留空则在安装阶段自动探测）' \
        --check validate_ipv4
    params_declare TCP_ACCELERATION \
        --label 'TCP 加速：skyline（默认）或 bbrv3' --default skyline \
        --normalize normalize_tcp_acceleration
    params_declare REBOOT_SCHEDULE_MODE \
        --label '定时重启：1=每天 04:00，2=自定义小时，3=不配置' --default 1 \
        --check params_check_reboot_mode
    params_declare REBOOT_HOUR \
        --label '自定义重启小时（0-23，仅模式 2 需要）' --check params_check_hour
}

params_cross_combined() {
    local domain index
    if validate_domain "${CF_ZONE}"; then
        for domain in "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${CF_ORIGIN_DOMAIN}" \
            "${GCORE_NODE_DOMAIN}" "${GCORE_ORIGIN_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
            case "${domain}" in
            *".${CF_ZONE}") ;;
            *) params_error "域名必须属于 ${CF_ZONE}：${domain}" ;;
            esac
        done
        [[ "$(printf '%s\n' "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${CF_ORIGIN_DOMAIN}" \
            "${GCORE_NODE_DOMAIN}" "${GCORE_ORIGIN_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" \
            | sort -u | wc -l | tr -d ' ')" == "6" ]] \
            || params_error '六个域名必须互不相同'
    fi
    if [[ -n "${DIRECT_NODE_NAME}" && -n "${GCORE_NODE_NAME}" && -n "${CF_NODE_PREFIX}" ]]; then
        [[ "${DIRECT_NODE_NAME}" != "${GCORE_NODE_NAME}" ]] \
            || params_error '直连节点名与 Gcore 节点名不能相同'
        for index in 1 2 3 4 5 6; do
            [[ "${CF_NODE_PREFIX}${index}" != "${DIRECT_NODE_NAME}" \
                && "${CF_NODE_PREFIX}${index}" != "${GCORE_NODE_NAME}" ]] \
                || params_error "Cloudflare 节点名 ${CF_NODE_PREFIX}${index} 与直连/Gcore 节点名重复"
        done
    fi
    if [[ -n "${OWNER_TOKEN}" && -n "${ALLOWED_TOKENS}" ]]; then
        params_error 'OWNER_TOKEN 与 ALLOWED_TOKENS 不能同时提供：单用户用 OWNER_TOKEN，多用户用 ALLOWED_TOKENS'
    fi
    if [[ "${REBOOT_SCHEDULE_MODE}" == "2" && -z "${REBOOT_HOUR}" ]]; then
        params_error 'REBOOT_SCHEDULE_MODE=2 时必须提供 REBOOT_HOUR（0-23）'
    fi
}

# 依赖已安装工具与网络：参数校验完成后、任何云端/本机配置写入之前运行。
apply_install_inputs() {
    if [[ -z "${VPS_PUBLIC_IPV4}" ]]; then
        VPS_PUBLIC_IPV4=$(detect_public_ipv4) \
            || die "无法自动探测本机公网 IPv4；请在参数文件里填写 VPS_PUBLIC_IPV4"
    fi
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${CF_ORIGIN_DOMAIN}
    if [[ -z "${ALLOWED_TOKENS}" && -z "${OWNER_TOKEN}" ]]; then
        OWNER_TOKEN=$(generate_secret)
    fi
    if [[ -z "${ALLOWED_TOKENS}" ]]; then
        ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}')
    fi
    combined_sync_allowed_tokens
    combined_validate_install_owner_token
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"
}

persist_cloudflare_token() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/cloudflare.token.XXXXXX") || die "创建 Cloudflare Token 暂存文件失败"
    printf '%s\n' "${CLOUDFLARE_API_TOKEN}" >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${CLOUDFLARE_TOKEN_FILE}"
}

cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -s "${CLOUDFLARE_TOKEN_FILE}" ]]; then
        CLOUDFLARE_API_TOKEN=$(<"${CLOUDFLARE_TOKEN_FILE}")
    fi
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（DNS 编辑权限）') \
            || die '缺少 Cloudflare API Token'
    fi
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,100}$ ]] \
        || die "Cloudflare Token 格式无效"
}

cloudflare_origin_certificate_hosts() {
    jq -cn --arg node "${CF_NODE_DOMAIN}" --arg origin "${CF_ORIGIN_DOMAIN}" \
        --arg sub "${SUBSCRIPTION_DOMAIN}" '[$node, $origin, $sub]'
}

dns_ensure_record() {
    local host=$1 type=$2 content=$3 proxied=$4 records count record id current current_proxied comment payload
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" "${type}" "${host}")
    count=$(jq 'length' <<<"${records}")
    ((count <= 1)) || die "Cloudflare ${host} 存在多条 ${type} 记录，拒绝覆盖"
    if ((count == 1)); then
        record=$(jq -c '.[0]' <<<"${records}")
        id=$(jq -r '.id' <<<"${record}")
        current=$(jq -r '.content' <<<"${record}")
        current_proxied=$(jq -r '.proxied' <<<"${record}")
        comment=$(jq -r '.comment // empty' <<<"${record}")
        [[ "${current}" == "${content}" && "${current_proxied}" == "${proxied}" ]] && return 0
        [[ "${comment}" == "${COMBINED_RECORD_COMMENT}" ]] \
            || die "Cloudflare ${host} 的 ${type} 记录与目标不一致；拒绝覆盖"
        cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" \
            "$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
                --argjson proxied "${proxied}" --arg comment "${COMBINED_RECORD_COMMENT}" \
                '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')" >/dev/null
        return 0
    fi
    payload=$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
        --argjson proxied "${proxied}" --arg comment "${COMBINED_RECORD_COMMENT}" \
        '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')
    cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${payload}" >/dev/null
}

combined_ensure_dns() {
    cloudflare_collect_api_token
    CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}") \
        || die "Cloudflare 中没有 active Zone：${CF_ZONE}"
    dns_ensure_record "${DIRECT_DOMAIN}" A "${VPS_PUBLIC_IPV4}" false
    dns_ensure_record "${CF_NODE_DOMAIN}" A "${VPS_PUBLIC_IPV4}" true
    dns_ensure_record "${CF_ORIGIN_DOMAIN}" A "${VPS_PUBLIC_IPV4}" true
    dns_ensure_record "${GCORE_ORIGIN_DOMAIN}" A "${VPS_PUBLIC_IPV4}" false
    dns_ensure_record "${SUBSCRIPTION_DOMAIN}" A "${VPS_PUBLIC_IPV4}" true
    GCORE_CDN_TARGET=$(gcore_cdn_target)
    dns_ensure_record "${GCORE_NODE_DOMAIN}" CNAME "${GCORE_CDN_TARGET}" false
}

gcore_cdn_target() {
    gcore_collect_api_token
    local target
    target=$(gcore_api_request GET "/cdn/clients/me" | jq -er '.cname // empty') \
        || die "无法从 Gcore 账户获取 CNAME 调度目标"
    normalize_domain "${target}"
}

write_cert_reload_hook() {
    install -d -m 0755 "${COMMAND_INSTALL_DIR}"
    cat >"${CERT_RELOAD_HOOK}" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
# nginx 尚未启动（首次安装期间就属于这种情况）时无需 reload：安装流程稍后会自行启动。
# 这里也不能退化成 restart，否则会让还没写完整配置的 nginx 提前带着默认站点上线。
systemctl is-active --quiet nginx || exit 0
nginx -t >/dev/null || exit 1
systemctl reload nginx || systemctl restart nginx
EOF
    chmod 0755 "${CERT_RELOAD_HOOK}"
}

combined_gcore_certificate_current() {
    [[ -s "${GCORE_CERT_FILE}" && -s "${GCORE_KEY_FILE}" ]] \
        && openssl x509 -in "${GCORE_CERT_FILE}" -checkend 2592000 -noout >/dev/null 2>&1 \
        && openssl x509 -in "${GCORE_CERT_FILE}" -checkhost "${GCORE_ORIGIN_DOMAIN}" -noout >/dev/null 2>&1
}

combined_issue_certificates() {
    local force=${1:-0}
    local -a issue_args
    local issue_rc=0
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_ORIGIN_DOMAIN}
    CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CF_CA_ROOT_FILE}"
    cloudflare_issue_origin_certificate "${force}"
    # Origin CA 一签发就落盘 ID/到期时间：后面 acme 源站证书失败时，续装可直接复用这张证书，
    # 不会重复 POST /certificates，也不会留下无法吊销的旧证书。
    persist_install_identity || warn "无法落盘安装身份；中断后 Cloudflare Origin CA 会重新签发"

    install_acme
    run_acme --set-default-ca --server letsencrypt >/dev/null || true
    write_cert_reload_hook
    if [[ "${force}" != "1" ]] && combined_gcore_certificate_current; then
        return 0
    fi
    issue_args=(--issue --dns dns_cf -d "${GCORE_ORIGIN_DOMAIN}" --keylength ec-256)
    # 重装/重试时不要强制重签：acme.sh 缓存里已有未到续期时间的证书就复用，
    # 否则会持续消耗 Let's Encrypt 的“同一标识符集合 5 张/168h”限额（2.4.4 现场）。
    if ((force == 1)); then
        issue_args+=(--force)
    fi
    CF_Token="${CLOUDFLARE_API_TOKEN}" run_acme "${issue_args[@]}" || issue_rc=$?
    if ((issue_rc == 2)); then
        # acme.sh 的 RENEW_SKIP：缓存证书仍有效，直接安装即可。
        info "复用 acme.sh 缓存的 Gcore 回源证书（未重新签发）：${GCORE_ORIGIN_DOMAIN}"
    elif ((issue_rc != 0)); then
        die "Gcore 回源域名 ${GCORE_ORIGIN_DOMAIN} 证书签发失败"
    fi
    CF_Token="${CLOUDFLARE_API_TOKEN}" run_acme --install-cert -d "${GCORE_ORIGIN_DOMAIN}" --ecc \
        --key-file "${GCORE_KEY_FILE}" \
        --fullchain-file "${GCORE_CERT_FILE}" \
        --reloadcmd "${CERT_RELOAD_HOOK}" || die "安装 Gcore 回源证书失败"
    chmod 0600 "${GCORE_KEY_FILE}"
    chmod 0644 "${GCORE_CERT_FILE}"
    CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
}

reality_mlkem_required() {
    local version major minor patch
    version=$(xray_installed_version)
    version=${version#v}
    IFS=. read -r major minor patch _ <<<"${version}"
    [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ && "${patch}" =~ ^[0-9]+$ ]] || return 1
    ((10#${major} * 10000 + 10#${minor} * 100 + 10#${patch} >= 260908))
}

write_xray_config() {
    local clients managed_outbounds managed_routing inbound_sockopt mlkem=0
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
    clients=$(jq -cn --arg id "${VLESS_UUID}" '[{id:$id,email:"easy_all.owner"}]')
    reality_mlkem_required && mlkem=1
    install -d -m 0755 "${XRAY_DIR}"
    if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
        REALITY_PRIVATE_KEY=$("${XRAY_BIN}" x25519 | awk '/PrivateKey/ {print $NF}')
    fi
    REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
    REALITY_PUBLIC_KEY=$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}" \
        | awk '/Password|PublicKey/ {print $NF; exit}')
    [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] \
        || die "生成 Reality X25519 密钥失败"
    jq -n \
        --argjson clients "$(jq -c '[.[] | . + {flow:"xtls-rprx-vision"}]' <<<"${clients}")" \
        --argjson ws_clients "${clients}" \
        --arg target "${REALITY_TARGET}" \
        --arg private_key "${REALITY_PRIVATE_KEY}" \
        --arg short_id "${REALITY_SHORT_ID}" \
        --arg sni "${REALITY_TARGET%:*}" \
        --argjson reality_port "${REALITY_PORT}" \
        --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson ws_port "${XRAY_WEBSOCKET_LOOPBACK_PORT}" \
        --arg host "${CF_NODE_DOMAIN}" \
        --arg path "${XHTTP_PATH}" \
        --arg ws_path "${WEBSOCKET_PATH}" \
        --arg secs "${CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS:-600}" \
        --arg padding "${CLOUDFLARE_XHTTP_PADDING_BYTES:-100}" \
        --arg xray_asset_dir "${XRAY_DIR}" \
        --argjson sockopt "${inbound_sockopt}" \
        --argjson outbounds "${managed_outbounds}" \
        --argjson routing "${managed_routing}" '
        {
          log: {loglevel: "warning"},
          env: {XRAY_LOCATION_ASSET: $xray_asset_dir},
          inbounds: [
            {
              tag: "vless-reality-in",
              listen: "0.0.0.0",
              port: $reality_port,
              protocol: "vless",
              settings: {clients: $clients, decryption: "none"},
              streamSettings: {
                network: "raw",
                security: "reality",
                sockopt: $sockopt,
                realitySettings: {
                  show: false, target: $target, xver: 0,
                  serverNames: [$sni], privateKey: $private_key, shortIds: [$short_id]
                }
              },
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            },
            {
              tag: "vless-xhttp-in",
              listen: "127.0.0.1",
              port: $xhttp_port,
              protocol: "vless",
              settings: {clients: $ws_clients, decryption: "none"},
              streamSettings: {
                network: "xhttp",
                sockopt: $sockopt,
                xhttpSettings: {
                  host: $host, path: $path, mode: "stream-up",
                  xPaddingBytes: $padding, scStreamUpServerSecs: $secs
                }
              },
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            },
            {
              tag: "vless-ws-in",
              listen: "127.0.0.1",
              port: $ws_port,
              protocol: "vless",
              settings: {clients: $ws_clients, decryption: "none"},
              streamSettings: {network: "ws", sockopt: $sockopt, wsSettings: {path: $ws_path}},
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            }
          ],
          outbounds: $outbounds,
          routing: $routing
        }' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

xhttp_validate_local_tls_curl_args() {
    cloudflare_ensure_origin_ca_root
    # --noproxy 必须有：--resolve 只改 DNS 解析，若机器上有 http_proxy/https_proxy，
    # 回环探活会被转发到代理而失败（订阅验收早就带了 --noproxy，这里补齐）。
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https' --noproxy '*' --cacert "${CF_CA_ROOT_FILE}")
}

xhttp_configure_ufw() {
    snapshot_ufw_state
    detect_ssh_ports strict
    verify_ssh_ufw_no_unmanaged_block "${SSH_PORTS}"
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null || die "设置 UFW 默认入站策略失败"
    ufw default allow outgoing >/dev/null || die "设置 UFW 默认出站策略失败"
    ufw default deny routed >/dev/null || die "设置 UFW 默认转发策略失败"
    apply_ssh_ufw_policy "${SSH_PORTS}" "${SSH_PORTS}"
    ufw allow "${REALITY_PORT}"/tcp comment "${UFW_RULE_COMMENT}" >/dev/null \
        || die "放行 Reality 端口失败"
    cloudflare_configure_origin_firewall
    gcore_configure_origin_firewall
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
}

combined_render_nginx_config() {
    local http2_directive=${1-} listen_h2=${2-}
    if (($# == 0)); then
        listen_h2="http2 "
        if nginx_supports_http2_directive; then
            http2_directive=$'\n    http2 on;'
            listen_h2=""
        fi
    fi
    # 只有现代分支能按 server 关闭 HTTP/2；旧版分支沿用 socket 级标记，关不掉也不假装关了。
    local gcore_listen_h2=${listen_h2} gcore_http2=${http2_directive}
    if [[ -z "${listen_h2}" ]]; then
        gcore_listen_h2=""
        gcore_http2=""
    fi
    write_subscription_nginx_maps
    cat <<EOF
server {
    listen 443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3 default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen 443 ssl ${listen_h2};
    server_name ${CF_NODE_DOMAIN} ${CF_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;${http2_directive}
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "easy_all ok\n";
    }

    location ^~ ${XHTTP_PATH}/ {
        client_max_body_size 0;
        client_body_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_set_header Host ${CF_NODE_DOMAIN};
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_socket_keepalive on;
        grpc_read_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_send_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};
        access_log off;
    }

    location / { return 404; }
}

server {
    # Gcore 回源块只承载 WebSocket：WebSocket 的 Upgrade 只能在 HTTP/1.1 上完成，所以
    # 现代 nginx（>= 1.25.1，http2 指令按 server 生效）这里刻意不启用 HTTP/2。
    # 旧版 nginx 的 listen ... http2 是地址级联集（ngx_http.c:1343 取或、1440 写回），
    # 无法按 SNI 关闭，因此旧版分支保持与其它块一致，避免制造一条无效的 "protocol options redefined" 警告。
    listen 443 ssl ${gcore_listen_h2};
    server_name ${GCORE_ORIGIN_DOMAIN};
    ssl_certificate ${GCORE_CERT_FILE};
    ssl_certificate_key ${GCORE_KEY_FILE};
    ssl_client_certificate ${GCORE_CLIENT_CA_FILE};
    ssl_verify_client on;
    ssl_protocols TLSv1.2 TLSv1.3;${gcore_http2}

    location = ${WEBSOCKET_PATH} {
        if (\$ssl_client_verify != SUCCESS) { return 403; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${GCORE_NODE_DOMAIN};
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_pass http://127.0.0.1:${XRAY_WEBSOCKET_LOOPBACK_PORT};
    }

    location / { return 404; }
}

server {
    listen 443 ssl ${listen_h2};
    server_name ${SUBSCRIPTION_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;${http2_directive}
    add_header Cache-Control "no-store" always;

EOF
    write_subscription_nginx_locations
    cat <<EOF
}
EOF
}

# 任何会写 Nginx 配置/订阅文件的路径都先过这里；install 另有更早的校验点。
combined_require_valid_owner_token() {
    combined_tokens_ready && return 0
    die "订阅 Token 无效（需 8-128 位 URL 安全字符，或 {\"user1\":\"token1\"} 字典）；请先执行 sudo easy_all edit-sub 重新配置"
}

write_nginx_config() {
    local http2_directive="" listen_h2="http2 "
    combined_require_valid_owner_token
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    install -d -m 0755 "${WEB_ROOT}"
    combined_render_nginx_config "${http2_directive}" "${listen_h2}" >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

combined_certificate_covers_node_domain() {
    local out=""
    [[ -s "${CERT_FILE}" ]] || return 1
    out=$(openssl x509 -in "${CERT_FILE}" -checkhost "${CF_NODE_DOMAIN}" -noout 2>/dev/null || true)
    [[ "${out}" == *"does match certificate"* && "${out}" != *"does NOT match"* ]]
}

# XHTTP stream-up 路径由 grpc_pass 转发给 Xray，普通 GET 会因缺少 gRPC 帧/流式请求体被拒绝或挂起；
# 探测同一 server 块内的 /easy_all-health 可在不触发代理流的前提下验证 CF_NODE_DOMAIN 的本机 TLS 握手、
# Origin CA 证书 SAN 覆盖与 Nginx SNI/Host 路由（未命中该 server 块时会落入 default_server 被拒绝握手）。
combined_validate_cf_node_sni() {
    local mode=${1:-strict} response
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    xhttp_validate_local_tls_curl_args
    response=$(curl -fsS --connect-timeout 5 --max-time 15 \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
        --resolve "${CF_NODE_DOMAIN}:443:127.0.0.1" \
        "https://${CF_NODE_DOMAIN}/easy_all-health" 2>/dev/null || true)
    if [[ "${response}" == "easy_all ok" ]]; then
        return 0
    fi
    if [[ "${mode}" == "lenient" ]] && ! combined_certificate_covers_node_domain; then
        warn "当前 Origin CA 证书未覆盖 ${CF_NODE_DOMAIN}；本机配置已重建，请执行 sudo easy_all apply-cloud 重签证书"
        return 0
    fi
    die "Cloudflare 节点域名 ${CF_NODE_DOMAIN} 本机 TLS/SNI 验收失败：请确认 Nginx server_name 与 Origin CA 证书 SAN 已覆盖该域名（升级后请执行 sudo easy_all apply-cloud）"
}

combined_gcore_resource() {
    gcore_collect_api_token
    # 只在有定义时保存：首次安装不经过 load_state，两个变量都可能还不存在，
    # 直接 ${VAR} 会在 set -u 下崩成 "SUBSCRIPTION_MODE: unbound variable"（2.3.4 现场）。
    local saved_domain="" saved_sub="" had_domain=0 had_sub=0 rc=0
    if [[ -n "${VLESS_CDN_DOMAIN+x}" ]]; then
        had_domain=1
        saved_domain=${VLESS_CDN_DOMAIN}
    fi
    if [[ -n "${SUBSCRIPTION_MODE+x}" ]]; then
        had_sub=1
        saved_sub=${SUBSCRIPTION_MODE}
    fi
    VLESS_CDN_DOMAIN=${GCORE_NODE_DOMAIN}
    SUBSCRIPTION_MODE=link
    if ! { GCORE_EDGE_CERTIFICATE_ID=$(gcore_edge_certificate_id) \
        && gcore_ensure_origin_validation_certificates \
        && gcore_ensure_origin_group \
        && gcore_ensure_resource; }; then
        rc=1
    fi
    # 失败分支同样要还原，否则 VLESS_CDN_DOMAIN 会滞留在 Gcore 节点域名上。
    # "原本未定义"要还原成未定义，不能留成空串，否则后续裸读会拿到空值而不是报错。
    if ((had_domain)); then
        VLESS_CDN_DOMAIN=${saved_domain}
    else
        unset VLESS_CDN_DOMAIN
    fi
    if ((had_sub)); then
        SUBSCRIPTION_MODE=${saved_sub}
    else
        unset SUBSCRIPTION_MODE
    fi
    return "${rc}"
}

validate_subscription_runtime() {
    local token base64_response base64_decoded mihomo_response
    local -a tls_args=(--proto '=https' --cacert "${CF_CA_ROOT_FILE}")
    cloudflare_ensure_origin_ca_root
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    base64_response=$(printf '%s' "${token}" | curl -fsS --noproxy '*' \
        --connect-timeout 5 --max-time 20 "${tls_args[@]}" \
        --resolve "${SUBSCRIPTION_DOMAIN}:443:127.0.0.1" \
        --get --data-urlencode 'token@-' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    base64_decoded=$(printf '%s' "${base64_response}" | openssl base64 -d -A 2>/dev/null) \
        || die "通用订阅响应不是有效的 Base64"
    grep -Fq 'type=xhttp' <<<"${base64_decoded}" || die "通用订阅缺少 Cloudflare 节点"
    mihomo_response=$(printf '%s' "${token}" | curl -fsS --noproxy '*' \
        --connect-timeout 5 --max-time 20 "${tls_args[@]}" \
        --resolve "${SUBSCRIPTION_DOMAIN}:443:127.0.0.1" \
        --get --data-urlencode 'token@-' --data-urlencode 'flag=clash' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || die "Mihomo 订阅本机验收失败"
    grep -Fq 'network: xhttp' <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
    validate_subscription_token_rejection \
        "${SUBSCRIPTION_DOMAIN}:443:127.0.0.1" "https://${SUBSCRIPTION_DOMAIN}/subscribe" \
        "${tls_args[@]}"
}

combined_validate_gcore() {
    local attempt code
    for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        code=$(curl -sS -o /dev/null -w '%{http_code}' --connect-timeout 8 --max-time 15 \
            -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
            -H "Sec-WebSocket-Key: $(openssl rand -base64 16)" -H 'Sec-WebSocket-Version: 13' \
            "https://${GCORE_NODE_DOMAIN}${WEBSOCKET_PATH}" 2>/dev/null || printf '000')
        [[ "${code}" == "101" ]] && return 0
        ((attempt == 15)) || sleep 10
    done
    warn "Gcore 边缘 WebSocket 验收未返回 101（最后状态 ${code}）；上游就绪后执行 sudo easy_all apply"
}

build_vless_xhttp_link() {
    local server=$1 node_name=$2 client_path extra
    client_path=$(xhttp_client_path)
    extra=$(jq -cn '{uplinkHTTPMethod:"POST",noGRPCHeader:false,xmux:{maxConnections:4,cMaxReuseTimes:0,hMaxRequestTimes:"300-600",hMaxReusableSecs:"900-1800",hKeepAlivePeriod:0}}')
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up&extra=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${CF_NODE_DOMAIN}" "${CF_NODE_DOMAIN}" \
        "$(uri_encode "${client_path}")" "$(uri_encode "${extra}")" "$(uri_encode "${node_name}")"
}

build_mihomo_xhttp_node() {
    local server=$1 node_name=$2 client_path
    client_path=$(xhttp_client_path)
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${CF_NODE_DOMAIN}" --arg uuid "${VLESS_UUID}" --arg path "${client_path}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: ipv4\n    alpn:\n      - h2\n" +
        "    xhttp-opts:\n      host: \($host|@json)\n      path: \($path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n        max-connections: 4\n" +
        "        c-max-reuse-times: 0\n        h-max-request-times: 300-600\n        h-max-reusable-secs: 900-1800\n        h-keep-alive-period: 0\n"'
}

build_reality_link() {
    local mlkem_param=""
    reality_mlkem_required || mlkem_param="&mlkem=0"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&packetEncoding=xudp%s#%s' \
        "${VLESS_UUID}" "${DIRECT_DOMAIN}" "${REALITY_PORT}" "${REALITY_TARGET%:*}" \
        "$(uri_encode "${REALITY_PUBLIC_KEY}")" "$(uri_encode "${REALITY_SHORT_ID}")" \
        "${mlkem_param}" "$(uri_encode "${DIRECT_NODE_NAME}")"
}

build_mihomo_reality_node() {
    local mlkem=""
    reality_mlkem_required && mlkem=$'      support-x25519mlkem768: true\n'
    jq -nr --arg name "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" --argjson port "${REALITY_PORT}" \
        --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
        --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" --arg mlkem "${mlkem}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: \($port)\n" +
        "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \($sni|@json)\n" +
        "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
        $mlkem +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n    ip-version: ipv4\n"'
}

build_vless_ws_link() {
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&alpn=http%%2F1.1&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${GCORE_NODE_DOMAIN}" "${GCORE_NODE_DOMAIN}" \
        "${GCORE_NODE_DOMAIN}" "$(uri_encode "${WEBSOCKET_PATH}")" "$(uri_encode "${GCORE_NODE_NAME}")"
}

build_mihomo_ws_node() {
    jq -nr --arg name "${GCORE_NODE_NAME}" --arg server "${GCORE_NODE_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg path "${WEBSOCKET_PATH}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: ws\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($server|@json)\n" +
        "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($server|@json)\n"'
}

combined_cf_candidates() {
    cloudflare_globalping_cache_compatible || return 1
    jq -r '.candidates | to_entries[] | [.value.ip, ((.key + 1) | tostring)] | @tsv' \
        "${GLOBALPING_CACHE_FILE}"
}

build_node_links() {
    local ip label
    build_reality_link
    printf '\n'
    build_vless_ws_link
    printf '\n'
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_vless_xhttp_link "${ip}" "${CF_NODE_PREFIX}${label}"
        printf '\n'
    done < <(combined_cf_candidates)
}

build_mihomo_nodes() {
    local ip label
    build_mihomo_reality_node
    build_mihomo_ws_node
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_xhttp_node "${ip}" "${CF_NODE_PREFIX}${label}"
    done < <(combined_cf_candidates)
}

collect_node_names() {
    local ip label names
    names=$(jq -cn --arg d "${DIRECT_NODE_NAME}" --arg g "${GCORE_NODE_NAME}" '[$d, $g]')
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        names=$(jq -cn --argjson names "${names}" --arg value "${CF_NODE_PREFIX}${label}" \
            '$names + [$value]')
    done < <(combined_cf_candidates)
    printf '%s' "${names}"
}

build_mihomo_proxy_names() {
    printf '        - "AUTO"\n'
    collect_node_names | jq -r '.[] | "        - \(.|@json)"'
}

build_mihomo_worker_rules() {
    :
}

build_mihomo_proxy_groups() {
    printf '    - name: AUTO\n      type: url-test\n      proxies:\n'
    collect_node_names | jq -r '.[] | "        - \(.|@json)"'
    cat <<'EOF'
      url: https://www.gstatic.com/generate_204
      interval: 300
      tolerance: 50
EOF
}

show_node() {
    collect_installed_state
    local ip label
    printf '\n直连节点:\n'
    build_reality_link
    printf '\n\nGcore 节点:\n'
    build_vless_ws_link
    printf '\n\nCloudflare 节点（优选 IPv4）:\n'
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_vless_xhttp_link "${ip}" "${CF_NODE_PREFIX}${label}"
        printf '\n'
    done < <(combined_cf_candidates)
}

show_status() {
    local cf_cert_raw cf_cert_enddate="" expected_tokens actual_tokens
    require_root
    collect_installed_state
    printf '协议: 直连 Reality + Cloudflare XHTTP + Gcore WebSocket\n'
    show_tcp_acceleration_status
    printf '直连入口: %s:%s\n' "${DIRECT_DOMAIN}" "${REALITY_PORT}"
    printf 'Cloudflare: %s（回源 %s）\n' "${CF_NODE_DOMAIN}" "${CF_ORIGIN_DOMAIN}"
    printf 'Gcore: %s（回源 %s）\n' "${GCORE_NODE_DOMAIN}" "${GCORE_ORIGIN_DOMAIN}"
    printf '订阅: https://%s/subscribe\n' "${SUBSCRIPTION_DOMAIN}"
    printf '核心服务: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '
    systemctl is-active --quiet nginx 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'Cloudflare 优选 IP: %s 个（%s）\n' \
        "$(jq '.candidates | length' "${GLOBALPING_CACHE_FILE}" 2>/dev/null || printf 0)" \
        "$(jq -r '.measured_at // "未生成"' "${GLOBALPING_CACHE_FILE}" 2>/dev/null || printf '未生成')"
    if [[ -s "${CERT_FILE}" ]] \
        && cf_cert_raw=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null || true) \
        && [[ "${cf_cert_raw}" == notAfter=* ]]; then
        cf_cert_enddate=${cf_cert_raw#notAfter=}
    fi
    if [[ -z "${cf_cert_enddate}" ]]; then
        printf 'Cloudflare 回源证书到期: 未知\n'
    elif combined_certificate_covers_node_domain; then
        printf 'Cloudflare 回源证书到期: %s（已覆盖 %s）\n' "${cf_cert_enddate}" "${CF_NODE_DOMAIN}"
    else
        printf 'Cloudflare 回源证书到期: %s（证书未覆盖 %s，请执行 sudo easy_all apply-cloud）\n' \
            "${cf_cert_enddate}" "${CF_NODE_DOMAIN}"
    fi
    if [[ -s "${GCORE_CERT_FILE}" ]]; then
        printf 'Gcore 回源证书到期: %s\n' \
            "$(openssl x509 -in "${GCORE_CERT_FILE}" -noout -enddate 2>/dev/null | cut -d= -f2 || true)"
    fi
    if [[ -f "${NGINX_CONFIG}" ]]; then
        expected_tokens=$(write_subscription_token_map 2>/dev/null \
            | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
            | grep -v '^$' | LC_ALL=C sort -u || true)
        actual_tokens=$(awk '
            /^[[:space:]]*map[[:space:]]+\$arg_token[[:space:]]+\$easy_all_subscription_allowed[[:space:]]*\{/ {
                in_map = 1
                next
            }
            in_map && /^[[:space:]]*\}/ {
                in_map = 0
                exit
            }
            in_map {
                sub(/^[[:space:]]+/, "")
                sub(/[[:space:]]+$/, "")
                if ($0 != "" && $0 != "default __denied__;") {
                    print $0
                }
            }
        ' "${NGINX_CONFIG}" 2>/dev/null | LC_ALL=C sort -u || true)
        if [[ "${expected_tokens}" != "${actual_tokens}" ]]; then
            printf '运行中配置与状态不一致，请执行 sudo easy_all apply\n'
        fi
    fi
    show_globalping_status
}

refresh_combined_cdn_ips() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    combined_require_valid_owner_token
    persist_globalping_token
    refresh_globalping_cache || die "Cloudflare 优选 IP 刷新失败"
    write_subscriptions
    validate_subscription_runtime
    save_state
    release_runtime_write_lock
    success "Cloudflare 优选 IP 与订阅已刷新"
}

combined_finish_local() {
    write_subscriptions
    validate_subscription_runtime
    save_state
    register_easy_all_command
    install_globalping_refresh_timer
}

apply_easy_all() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    configure_tcp_acceleration
    xhttp_configure_ufw
    write_xray_config
    install_xray_service
    gcore_prepare_origin_validation_material
    write_nginx_config
    validate_protocol_runtime
    combined_validate_cf_node_sni lenient
    if ! globalping_cache_valid; then
        persist_globalping_token
        refresh_globalping_cache || warn "Cloudflare 优选 IP 刷新失败，沿用现有缓存"
    fi
    combined_finish_local
    release_runtime_write_lock
    success "本机配置与订阅已应用；未修改 DNS 与 Gcore 资源"
}

apply_cloud_resources() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    snapshot_subscription_update
    configure_tcp_acceleration
    xhttp_configure_ufw
    combined_ensure_dns
    combined_issue_certificates
    write_xray_config
    install_xray_service
    gcore_prepare_origin_validation_material
    write_nginx_config
    validate_protocol_runtime
    combined_validate_cf_node_sni
    combined_gcore_resource || die "同步 Gcore CDN 资源失败"
    combined_validate_gcore
    persist_cloudflare_token
    persist_globalping_token
    refresh_globalping_cache || warn "Cloudflare 优选 IP 刷新失败，沿用现有缓存"
    combined_finish_local
    # 吊销不可逆，必须先关闭回滚再吊销，避免后续中断时恢复已吊销的旧证书。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    gcore_clear_api_token
    commit_subscription_update
    success "本机配置、订阅与云端资源已同步"
}

# 组合模式跨越本机、Cloudflare 与 Gcore 三部分：失败/中断时只回滚本机，云端已创建的
# 资源按设计保留，并用 purge 命令提示清理——擅自删除会让同域名重装撞上残留记录。
cleanup_partial_install() {
    cleanup_partial_install_local || return 1
    # 刻意不卸载 acme.sh、不删 /root/.acme-combined.sh 的证书缓存：每次重试都重新签发会打满
    # Let's Encrypt 的“同一标识符集合 5 张/168h”限额（2.4.4 现场）。重试时 acme.sh 会跳过未到
    # 续期时间的证书；真正的 uninstall 才执行 acme.sh --uninstall。
    if [[ -e "${ACME_HOME}" ]]; then
        warn "已保留 acme.sh 证书缓存 ${ACME_HOME}，重试安装会复用已签证书；不再安装可执行 sudo ${ACME_BIN} --uninstall"
    fi
    remove_daily_reboot_schedule || true
    cleanup_partial_install_files \
        "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}" \
        "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
}

rollback_fresh_install() {
    warn "组合模式首次安装未完成，正在回滚本机服务、UFW、crontab 与 TCP 配置"
    cleanup_partial_install || true
    warn "本次已创建的 Cloudflare 记录/Origin CA 与 Gcore CDN 资源按设计保留；如不再使用请清理："
    warn "  bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) purge-cloudflare --all"
    warn "  bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) purge-gcore --all"
}

install_all() {
    require_root
    acquire_runtime_write_lock
    require_systemd
    check_platform
    [[ ! -f "${STATE_FILE}" ]] || die "检测到已有 easy_all 安装；一台 VPS 只允许一种模式"
    install_failure_begin combined
    # 参数预检先于任何系统修改：失败时只可能装过 jq/ca-certificates。
    install_params_preflight combined
    prepare_fresh_install 80 443 "${REALITY_PORT}"
    install_progress_begin combined
    # 快照必须早于任何系统修改（TCP 加速、内核、定时重启、crontab），否则回滚恢复的是
    # “已被本次安装改过”的状态。
    snapshot_fresh_install
    install_progress_stage packages
    install_packages
    install_progress_stage tcp
    choose_tcp_acceleration
    configure_tcp_acceleration
    configure_daily_reboot
    install_progress_stage inputs
    apply_install_inputs
    # 身份落盘：中断续装时要用它覆盖预检新生成的值，保证已写出的节点/订阅不失效。
    persist_install_identity || warn "无法落盘安装身份；中断后无法完全复用 UUID/路径/Token"
    install_progress_stage core
    download_xray
    validate_reality_target_runtime
    install_progress_stage services
    xhttp_configure_ufw
    combined_ensure_dns
    combined_issue_certificates
    write_xray_config
    # 此时已有 Reality 密钥与 Origin CA 元数据，再落一次盘供续装复用。
    persist_install_identity || warn "无法落盘安装身份；中断后无法完全复用密钥与证书元数据"
    install_xray_service
    write_bootstrap_nginx_config
    gcore_prepare_origin_validation_material
    write_nginx_config
    validate_protocol_runtime
    combined_validate_cf_node_sni
    install_progress_stage cloud
    combined_gcore_resource || die "同步 Gcore CDN 资源失败"
    combined_validate_gcore
    persist_cloudflare_token
    persist_globalping_token
    # 此刻还没有可用订阅，状态也未落盘：失败即回滚本机，云端资源保留并提示清理。
    refresh_globalping_cache \
        || die "首次 Cloudflare 优选 IP 生成失败；本机安装已回滚，云端资源保留，可稍后重试安装，或先执行 sudo easy_all purge-cloudflare --all 与 sudo easy_all purge-gcore 清理残留"
    install_progress_stage subscription
    write_subscriptions
    validate_subscription_runtime
    install_progress_stage state
    save_state
    # 状态已落盘：从这一刻起失败不必再回滚本机——uninstall 已经可用，而下面的
    # cloudflare_finalize_certificate_rotation 会吊销旧证书（不可逆），回滚反而会留下吊销后的残局。
    INSTALL_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    register_easy_all_command
    install_globalping_refresh_timer
    gcore_clear_api_token
    release_runtime_write_lock
    install_progress_clear
    # 从这里开始只剩展示类命令：失败不再算“安装失败”。
    INSTALL_FAILURE_ARMED=0
    show_subscription
    success "easy_all 组合模式安装完成（直连 + Cloudflare + Gcore）"
    show_tcp_acceleration_status
    prompt_bbrv3_reboot
}

# 当前 Cloudflare 环境变量 Token 与 ALLOWED_TOKENS 的格式约束（与 normalize_allowed_tokens 一致）。
combined_token_valid() {
    local token=${1:-}
    # 首字符排除 ~：nginx map 中 "~..." 形式的键会被解析为正则，可能匹配到别的 token。
    [[ "${token}" =~ ^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$ ]]
}

# Token 字典（{用户: token}）是否可用：能解析、能规范化、每个 token 都合法
combined_tokens_ready() {
    local normalized
    if [[ -z "${ALLOWED_TOKENS:-}" ]]; then
        combined_token_valid "${OWNER_TOKEN:-}" || return 1
        ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}') || return 1
        return 0
    fi
    normalized=$(normalize_allowed_tokens "${ALLOWED_TOKENS}" 2>/dev/null) || return 1
    ALLOWED_TOKENS=${normalized}
    OWNER_TOKEN=$(jq -er 'to_entries[0].value' <<<"${normalized}") || return 1
    return 0
}

# 安装阶段在改动任何云端资源之前就拒绝非法 Token（环境变量传入同样受检）
combined_validate_install_owner_token() {
    combined_tokens_ready && return 0
    die "订阅 Token 无效：需 8-128 位 URL 安全字符（A-Z a-z 0-9 . _ ~ -），或形如 {\"user1\":\"token1\"} 的 JSON 字典；请修正后重试（清空 OWNER_TOKEN 可自动生成）"
}


# Token 字典的唯一入口：已有字典则保留（多用户），否则由 OWNER_TOKEN 派生 {owner: OWNER_TOKEN}。
# 首次安装路径不经过 load_state，必须显式同步，否则 write_subscription_token_map 会在 set -u 下崩掉（2.2.2 现场）。
combined_sync_allowed_tokens() {
    if [[ -z "${ALLOWED_TOKENS:-}" ]]; then
        [[ -n "${OWNER_TOKEN:-}" ]] || return 0
        ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}') \
            || die '生成订阅 Token 字典失败'
    fi
    export ALLOWED_TOKENS
}

# 输入可以是单个 Token，或 {"用户":"token",...} 字典（多用户共享同一节点与订阅内容）
combined_apply_tokens() {
    local raw=${1:-} normalized token
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
    [[ -n "${raw}" ]] || return 1
    if [[ "${raw}" == \{* ]]; then
        normalized=$(normalize_allowed_tokens "${raw}" 2>/dev/null) || return 1
    else
        token=${raw//[[:space:]]/}
        combined_token_valid "${token}" || return 1
        normalized=$(jq -cn --arg token "${token}" '{owner:$token}') || return 1
    fi
    ALLOWED_TOKENS=${normalized}
    OWNER_TOKEN=$(jq -er 'to_entries[0].value' <<<"${normalized}") || return 1
    return 0
}

update_subscription() {
    local raw_tokens="" caller_tokens=${ALLOWED_TOKENS:-}
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if [[ -t 0 ]]; then
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME}")")
        raw_tokens=$(prompt_value \
            "订阅 Token（单个 Token，或 JSON 字典 {\"用户\":\"token\",...}）" "${ALLOWED_TOKENS}")
    else
        raw_tokens=${caller_tokens:-${ALLOWED_TOKENS:-}}
    fi
    combined_apply_tokens "${raw_tokens}" \
        || die "订阅 Token 无效；请输入 8-128 位 URL 安全字符，或 JSON 字典形如 {\"user1\":\"$(generate_secret)\"}"
    snapshot_subscription_update
    write_nginx_config
    write_subscriptions
    validate_subscription_runtime
    save_state
    commit_subscription_update
    show_subscription
    success "订阅已刷新"
}

renew_certificate() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    combined_require_valid_owner_token
    cloudflare_collect_api_token
    CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}")
    snapshot_subscription_update
    combined_issue_certificates 1
    nginx -t >/dev/null || die "证书更新后 Nginx 配置校验失败"
    systemctl reload nginx || die "证书更新后 Nginx 重载失败"
    save_state
    # 吊销不可逆，必须先关闭回滚再吊销，避免后续中断时恢复已吊销的旧证书。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    success "证书已更新"
}

update_reality_target() {
    local target=${1:-} current backup_config
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    combined_require_valid_owner_token
    current=${REALITY_TARGET}
    if [[ -z "${target}" ]]; then
        [[ -t 0 ]] || die "非交互模式必须传入 域名:端口"
        target=$(prompt_value 'Reality 伪装目标（域名:端口）' "${current}")
    fi
    validate_reality_target "${target}" \
        || die "Reality 目标无效，需为 域名:端口：${target}"
    target="$(normalize_domain "${target%:*}"):${target##*:}"
    if [[ "${target}" == "${current}" ]]; then
        info "Reality 目标未变化：${current}"
        release_runtime_write_lock
        return 0
    fi
    REALITY_TARGET=${target}
    backup_config="$(make_temp_dir)/config.json"
    install -m 0600 "${XRAY_CONFIG}" "${backup_config}"
    if (
        validate_reality_target_runtime
        write_xray_config
        systemctl restart "${XRAY_SERVICE}"
        validate_protocol_runtime
    ); then
        save_state
        write_subscriptions
        save_state
        release_runtime_write_lock
        success "Reality 目标已更新：${current} → ${REALITY_TARGET}；请刷新客户端订阅"
        return 0
    fi
    warn "新运行时配置验收失败，正在恢复旧配置"
    REALITY_TARGET=${current}
    install -m 0600 "${backup_config}" "${XRAY_CONFIG}"
    systemctl restart "${XRAY_SERVICE}" || die "恢复旧配置后无法重启 ${XRAY_SERVICE}"
    validate_protocol_runtime
    die "运行时配置更新失败，已恢复旧配置"
}

purge_combined_dns() {
    local host type records count id comment
    for host in "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${CF_ORIGIN_DOMAIN}" \
        "${GCORE_ORIGIN_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
        records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${host}")
        count=$(jq 'length' <<<"${records}")
        ((count == 1)) || continue
        id=$(jq -r '.[0].id' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        [[ "${comment}" == "${COMBINED_RECORD_COMMENT}" ]] || continue
        cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null \
            || warn "删除 Cloudflare 记录失败：${host}"
    done
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" CNAME "${GCORE_NODE_DOMAIN}")
    count=$(jq 'length' <<<"${records}")
    if ((count == 1)); then
        id=$(jq -r '.[0].id' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        if [[ "${comment}" == "${COMBINED_RECORD_COMMENT}" ]]; then
            cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null \
                || warn "删除 Cloudflare Gcore CNAME 失败"
        fi
    fi
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all 尚未安装"
    if [[ "${mode}" == "--purge-cloud" && ! -f "${STATE_FILE}" ]]; then
        die "缺少状态文件，无法安全识别云端资源；本机内容未删除"
    fi
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        if [[ "${mode}" == "--purge-cloud" ]]; then
            read_bilingual '删除本机内容以及 easy_all 创建的 Cloudflare 记录与 Gcore CDN 资源？[y/N]:' answer
        else
            read_bilingual '删除 easy_all 本机服务、状态和证书（保留远端资源）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${mode}" == "--purge-cloud" ]]; then
        cloudflare_collect_api_token
        CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}")
        purge_combined_dns
        gcore_purge_managed_resources \
            || die "Gcore 远端资源未完全清理；本机状态仍保留，可直接重试 uninstall --purge-cloud"
        cloudflare_clear_api_token
    else
        warn "远端资源（Cloudflare 记录与 Gcore CDN）已保留；本机状态删除后无法再用 easy_all 清理"
    fi
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    gcore_remove_origin_firewall_rules
    cloudflare_remove_origin_firewall_rules
    restore_preinstall_firewall
    restore_bbr_tcp_install_state
    remove_daily_reboot_schedule
    # 只清理 easy_all 安装的 acme.sh（所有权标记）；失败回滚保留的证书缓存也按此标记在真正卸载时清掉。
    if [[ -x "${ACME_BIN}" && -f "${ACME_OWNERSHIP_MARKER}" ]]; then
        "${ACME_BIN}" --uninstall </dev/null >/dev/null 2>&1 \
            || warn "acme.sh 卸载失败，请手工清理 ${ACME_HOME}"
    fi
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    success "easy_all 组合模式本机内容已卸载"
}

gcore_purge_managed_dns_records() {
    return 0
}
