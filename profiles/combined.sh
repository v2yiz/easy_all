#!/usr/bin/env bash
# Combined profile: direct Reality + Cloudflare XHTTP.
set -Eeuo pipefail
umask 077

readonly COMBINED_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XHTTP_LIB_DIR="${COMBINED_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="Cloudflare"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray direct/Cloudflare managed by easy_all"
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
source "${XHTTP_LIB_DIR}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/reality-target.sh
source "${XHTTP_LIB_DIR}/reality-target.sh"

readonly REALITY_PORT=8443
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
readonly CLOUDFLARE_TOKEN_FILE="${STATE_DIR}/cloudflare.token"
readonly COMBINED_RECORD_COMMENT="easy_all combined"

PROTOCOL=combined
BACKEND=xray
CDN_PROVIDER=cloudflare
XHTTP_NODE_NAME=easy_all

load_state() {
    local variable
    local -a variables=(
        STATE_VERSION PROTOCOL TCP_ACCELERATION
        VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
        DIRECT_DOMAIN CF_NODE_DOMAIN
        SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS VLESS_UUID
        DIRECT_NODE_NAME CF_NODE_PREFIX
        XHTTP_PATH REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
        CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
        SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
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
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}
    # 2.0.0 状态的组合模式没有这些字段，回退到当时的固定名称，避免 apply 时静默改名。
    : "${DIRECT_NODE_NAME:=直连}" "${CF_NODE_PREFIX:=CF-优选}"
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
            DIRECT_DOMAIN CF_NODE_DOMAIN \
            SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS VLESS_UUID \
            DIRECT_NODE_NAME CF_NODE_PREFIX \
            XHTTP_PATH REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID \
            CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON \
            SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR; do
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
    local domain index
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' '')")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"

    DIRECT_DOMAIN=$(normalize_domain "$(prompt_value '直连节点域名' "node.${CF_ZONE}")")
    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'Cloudflare 节点域名（橙云）' "cf.${CF_ZONE}")")
    SUBSCRIPTION_DOMAIN=$(normalize_domain "$(prompt_value '订阅域名（橙云）' "sub.${CF_ZONE}")")
    for domain in "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
        validate_domain "${domain}" || die "域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] || die "域名必须属于 ${CF_ZONE}：${domain}"
    done
    [[ "$(printf '%s\n' "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" | sort -u | wc -l | tr -d ' ')" == "3" ]] \
        || die "三个域名必须互不相同"
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}

    CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（DNS 编辑权限）') \
        || die '缺少 Cloudflare API Token'
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,100}$ ]] || die "Cloudflare Token 格式无效"
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"

    REALITY_TARGET=$(prompt_value 'Reality 伪装目标（域名:端口）' 'swdist.apple.com:443')
    validate_reality_target "${REALITY_TARGET}" \
        || die "Reality 目标无效，需为 域名:端口：${REALITY_TARGET}"
    REALITY_TARGET="$(normalize_domain "${REALITY_TARGET%:*}"):${REALITY_TARGET##*:}"
    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP 路径无效"

    DIRECT_NODE_NAME=$(prompt_value '直连节点名' "${DIRECT_NODE_NAME:-🇺🇸直连}")
    CF_NODE_PREFIX=$(prompt_value 'Cloudflare 节点名前缀（自动追加 1~6）' "${CF_NODE_PREFIX:-🇺🇸CF}")
    validate_node_name "${DIRECT_NODE_NAME}" || die "直连节点名无效（1-64 字符，不能含换行）"
    validate_node_name "${CF_NODE_PREFIX}" || die "Cloudflare 节点名前缀无效"
    for index in 1 2 3 4 5 6; do
        [[ "${CF_NODE_PREFIX}${index}" != "${DIRECT_NODE_NAME}" ]] \
            || die "Cloudflare 节点名 ${CF_NODE_PREFIX}${index} 与直连节点名重复"
    done
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")")

    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"
    if [[ -z "${ALLOWED_TOKENS:-}" && -z "${OWNER_TOKEN:-}" ]]; then
        OWNER_TOKEN=$(generate_secret)
    fi
    if [[ -z "${ALLOWED_TOKENS:-}" ]]; then
        ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}')
    fi
    combined_sync_allowed_tokens
    combined_validate_install_owner_token

    if [[ -z "${VPS_PUBLIC_IPV4:-}" ]]; then
        VPS_PUBLIC_IPV4=$(detect_public_ipv4) \
            || die "无法自动探测本机公网 IPv4"
    fi
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
        CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（仅限 DNS 编辑权限；将保存到 root 受控文件以支持后续定时与免交互运维）') \
            || die '缺少 Cloudflare API Token'
    fi
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,100}$ ]] \
        || die "Cloudflare Token 格式无效"
}

cloudflare_origin_certificate_hosts() {
    jq -cn --arg node "${CF_NODE_DOMAIN}" \
        --arg sub "${SUBSCRIPTION_DOMAIN}" '[$node, $sub]'
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
    dns_ensure_record "${SUBSCRIPTION_DOMAIN}" A "${VPS_PUBLIC_IPV4}" true
}

combined_issue_certificates() {
    local force=${1:-0}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}
    CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CF_CA_ROOT_FILE}"
    cloudflare_issue_origin_certificate "${force}"
    # Origin CA 一签发就落盘 ID/到期时间：续装可直接复用这张证书，
    # 不会重复 POST /certificates，也不会留下无法吊销的旧证书。
    persist_install_identity || warn "无法落盘安装身份；中断后 Cloudflare Origin CA 会重新签发"
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
    local clients managed_outbounds managed_routing inbound_sockopt
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
    clients=$(jq -cn --arg id "${VLESS_UUID}" '[{id:$id,email:"easy_all.owner"}]')
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
        --arg host "${CF_NODE_DOMAIN}" \
        --arg path "${XHTTP_PATH}" \
        --arg secs "${CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS:-600}" \
        --arg padding "${CLOUDFLARE_XHTTP_PADDING_BYTES:-100-1000}" \
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
    snapshot_platform_security_state
    # SSH 开机自启与 Fail2ban 与其他模式保持一致：只做 UFW 放行、不配 jail 会让文档承诺的暴力破解防护静默缺失。
    ensure_ssh_boot_service
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
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
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
    write_subscription_nginx_maps
    cat <<EOF
server {
    listen 443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3 default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen 443 ssl ${listen_h2};
    server_name ${CF_NODE_DOMAIN};
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
    optimize_nginx_system_config
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

combined_cf_candidates() {
    cloudflare_globalping_cache_compatible || return 1
    jq -r '.candidates | to_entries[] | [.value.ip, ((.key + 1) | tostring)] | @tsv' \
        "${GLOBALPING_CACHE_FILE}"
}

build_node_links() {
    local ip label
    build_reality_link
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
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_xhttp_node "${ip}" "${CF_NODE_PREFIX}${label}"
    done < <(combined_cf_candidates)
}

collect_node_names() {
    local ip label names
    names=$(jq -cn --arg d "${DIRECT_NODE_NAME}" '[$d]')
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
    printf '协议: 直连 Reality + Cloudflare XHTTP\n'
    show_tcp_acceleration_status
    printf '直连入口: %s:%s\n' "${DIRECT_DOMAIN}" "${REALITY_PORT}"
    printf 'Cloudflare: %s\n' "${CF_NODE_DOMAIN}"
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

# update-core 换核心后按新核心版本重写订阅：Reality 节点的 ML-KEM 开关依赖核心版本。
refresh_runtime_subscription() {
    write_subscriptions
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
    configure_ipv4_only
    xhttp_configure_ufw
    write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    combined_validate_cf_node_sni lenient
    if ! globalping_cache_valid; then
        persist_globalping_token
        refresh_globalping_cache || warn "Cloudflare 优选 IP 刷新失败，沿用现有缓存"
    fi
    combined_finish_local
    release_runtime_write_lock
    success "本机配置与订阅已应用；未修改 DNS 与云端资源"
}

apply_cloud_resources() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    snapshot_subscription_update
    configure_tcp_acceleration
    configure_ipv4_only
    xhttp_configure_ufw
    combined_ensure_dns
    combined_issue_certificates
    write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    combined_validate_cf_node_sni
    persist_cloudflare_token
    persist_globalping_token
    refresh_globalping_cache || warn "Cloudflare 优选 IP 刷新失败，沿用现有缓存"
    combined_finish_local
    # 吊销不可逆，必须先关闭回滚再吊销，避免后续中断时恢复已吊销的旧证书。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    success "本机配置、订阅与云端资源已同步"
}

# 组合模式跨越本机与 Cloudflare 两部分：失败/中断时只回滚本机，云端已创建的
# 资源按设计保留，并用 purge 命令提示清理——擅自删除会让同域名重装撞上残留记录。
cleanup_partial_install() {
    cleanup_partial_install_local || return 1
    remove_daily_reboot_schedule || true
    cleanup_partial_install_files \
        "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}" \
        "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
}

rollback_fresh_install() {
    warn "组合模式首次安装未完成，正在回滚本机服务、UFW 与 crontab 配置（保留前置初始化：SWAP、系统依赖与 TCP/Skyline 加速）"
    cleanup_partial_install || true
    warn "本次已创建的 Cloudflare 记录/Origin CA 按设计保留；如不再使用请清理："
    warn "  bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) purge-cloudflare --all"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    require_root
    acquire_runtime_write_lock
    require_systemd
    check_platform
    [[ ! -f "${STATE_FILE}" ]] || die "检测到已有 easy_all 安装；一台 VPS 只允许一种模式"
    report_host_init_state
    ensure_swap
    install_failure_begin combined
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
    configure_ipv4_only
    install_progress_stage inputs
    collect_install_inputs
    # 身份落盘：中断续装时要用它覆盖新生成的值，保证已写出的节点/订阅不失效。
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
    write_nginx_config
    validate_protocol_runtime
    combined_validate_cf_node_sni
    install_progress_stage cloud
    persist_cloudflare_token
    persist_globalping_token
    # 此刻还没有可用订阅，状态也未落盘：失败即回滚本机，云端资源保留并提示清理。
    refresh_globalping_cache \
        || die "首次 Cloudflare 优选 IP 生成失败；本机安装已回滚，云端资源保留，可稍后重试安装，或先执行 sudo easy_all purge-cloudflare --all 清理残留"
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
    release_runtime_write_lock
    install_progress_clear
    # 从这里开始只剩展示类命令：失败不再算“安装失败”。
    INSTALL_FAILURE_ARMED=0
    show_subscription
    success "easy_all 组合模式安装完成（直连 + Cloudflare）"
    show_tcp_acceleration_status
    prompt_kernel_reboot
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
    for host in "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" \
        "${SUBSCRIPTION_DOMAIN}"; do
        records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${host}")
        count=$(jq 'length' <<<"${records}")
        ((count == 1)) || continue
        id=$(jq -r '.[0].id' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        [[ "${comment}" == "${COMBINED_RECORD_COMMENT}" ]] || continue
        cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null \
            || warn "删除 Cloudflare 记录失败：${host}"
    done
}

purge_combined_origin_certificate() {
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]] || return 0
    # cloudflare_api_request 失败会直接退出所在进程，用子 shell 兜住以免中断卸载。
    (cloudflare_api_request DELETE "/certificates/${CLOUDFLARE_ORIGIN_CERT_ID}" >/dev/null) \
        || warn "吊销 Cloudflare Origin CA 证书失败：${CLOUDFLARE_ORIGIN_CERT_ID}；请到控制台手动删除"
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
            read_bilingual '删除本机内容以及 easy_all 创建的 Cloudflare 记录？[y/N]:' answer
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
        purge_combined_origin_certificate
        cloudflare_clear_api_token
    else
        warn "远端资源（Cloudflare 记录）已保留；本机状态删除后无法再用 easy_all 清理"
    fi
    stop_services
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_platform_security_state || {
        warn "SSH 配置恢复失败；请通过服务商 Console 检查"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_preinstall_nginx_default_site || warn "恢复安装前 Nginx 默认站点失败"
    remove_daily_reboot_schedule
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    success "easy_all 组合模式本机内容已卸载"
}
