#!/usr/bin/env bash

# Shared Cloudflare XHTTP core for the pure CDN profile (mode 2) and the
# direct Reality + CDN profile (mode 3).
#
# Profile contract provided before this file is sourced:
#   CDN_EXPECTED_PROTOCOL   state PROTOCOL owned by the profile (cdn / combined)
#   CDN_MODE_LABEL          user-facing mode name used by status/install output
#   CDN_ENTRY_SUMMARY       entry summary used in the install success message
#   CDN_REALITY_ENABLED     1 when the profile also serves the direct Reality inbound
#   CDN_INSTALL_PORTS       TCP ports that must be free before a fresh install
#   CDN_STATE_VARIABLES     state.env fields persisted by the profile
# plus the Cloudflare constants required by lib/cf-dns.sh (CLOUDFLARE_UFW_COMMENT,
# CLOUDFLARE_UFW_PORT, CLOUDFLARE_ORIGIN_CA_ROOT_FILE, CF_CA_ROOT_FILE, ...).
#
# The profile keeps its own collect_install_inputs and, when Reality is enabled,
# the Reality link/node builders and update_reality_target.

cdn_reality_enabled() { [[ "${CDN_REALITY_ENABLED:-0}" == "1" ]]; }

cdn_load_state() {
    local variable
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    # 状态文件必须自带版本号：先清掉可能残留的值，缺失时才能报错而不是沿用旧值。
    unset STATE_VERSION
    for variable in "${CDN_STATE_VARIABLES[@]}"; do
        unset "${variable}" 2>/dev/null || true
    done
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；请重新安装"
    [[ "${PROTOCOL:-}" == "${CDN_EXPECTED_PROTOCOL}" ]] \
        || die "状态协议不是 ${CDN_EXPECTED_PROTOCOL}；请重新安装"
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]] || die "状态缺少 Cloudflare Zone ID；请重新安装"
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}
    # 这里只告警不阻断：历史状态可能存着非法配置，若在此 die，连 edit-sub 和 uninstall 都进不去。
    # 真正写配置前的拦截点在 cdn_require_valid_owner_token。
    cdn_sync_allowed_tokens \
        || warn "状态文件中的订阅配置无效；请执行 sudo easy_all edit-sub 重新配置"
    SUBSCRIPTION_MODE=deploy
}

load_state() { cdn_load_state; }

collect_installed_state() { load_state; }

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp variable
    cdn_sync_config_tokens || true
    if [[ -z "${SUBSCRIPTION_CONFIG:-}" && -n "${ALLOWED_TOKENS:-}" ]]; then
        SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" \
            --argjson n "${AGGREGATION_NODES:-[]}" '{allowedTokens:$t,nodes:$n}') \
            || die "无法生成订阅配置"
    fi
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") || die "创建状态暂存文件失败"
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        for variable in "${CDN_STATE_VARIABLES[@]}"; do
            printf '%s=%q\n' "${variable}" "${!variable:-}"
        done
    } >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${STATE_FILE}"
}

validate_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *[[:cntrl:]]* ]]
}

persist_cloudflare_token() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/cloudflare.token.XXXXXX") || die "创建 Cloudflare Token 暂存文件失败"
    declare -p cleanup_files >/dev/null 2>&1 && cleanup_files+=("${temp}")
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

# 回源证书与回源 Nginx 只服务 CDN 节点域名与订阅域名；两种 CDN 模式相同。
cloudflare_origin_certificate_hosts() {
    jq -cn --arg node "${CF_NODE_DOMAIN}" --arg sub "${SUBSCRIPTION_DOMAIN}" '[$node, $sub]'
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
        if [[ "${current}" == "${content}" && "${current_proxied}" == "${proxied}" ]]; then
            # 跨 CDN 模式重装时目标一致但注释仍属于另一个模式：改注释为当前模式的所有权标记，
            # 否则 uninstall --purge-cloud 会因注释不匹配而漏删这条记录。第三方/无注释记录
            # 沿用旧行为（内容一致即可复用，不接管所有权）。
            [[ "${comment}" == easy_all* && "${comment}" != "${CDN_RECORD_COMMENT}" ]] || return 0
            cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" \
                "$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
                    --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
                    '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')" >/dev/null
            return 0
        fi
        # 记录内容与目标不一致时，只接管 easy_all 自己创建的记录（允许换机/换模式重装更新 IP）；
        # 第三方或无注释记录一律拒绝覆盖。
        [[ "${comment}" == easy_all* ]] \
            || die "Cloudflare ${host} 的 ${type} 记录与目标不一致；拒绝覆盖"
        cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" \
            "$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
                --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
                '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')" >/dev/null
        return 0
    fi
    payload=$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
        --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
        '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')
    cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${payload}" >/dev/null
}

# 仅直连模式（模式 3）有灰云直连域名；纯 CDN 模式为空。
cdn_dns_only_domains() {
    cdn_reality_enabled || return 0
    [[ -z "${DIRECT_DOMAIN:-}" ]] || printf '%s\n' "${DIRECT_DOMAIN}"
}

cdn_proxied_domains() {
    printf '%s\n' "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"
}

cdn_ensure_dns() {
    local domain
    cloudflare_collect_api_token
    CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}") \
        || die "Cloudflare 中没有 active Zone：${CF_ZONE}"
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        dns_ensure_record "${domain}" A "${VPS_PUBLIC_IPV4}" false
    done < <(cdn_dns_only_domains)
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        dns_ensure_record "${domain}" A "${VPS_PUBLIC_IPV4}" true
    done < <(cdn_proxied_domains)
}

cdn_issue_certificates() {
    local force=${1:-0}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}
    cloudflare_issue_origin_certificate "${force}"
    # Origin CA 一签发就落盘 ID/到期时间：续装可直接复用这张证书，
    # 不会重复 POST /certificates，也不会留下无法吊销的旧证书。
    persist_install_identity || warn "无法落盘安装身份；中断后 Cloudflare Origin CA 会重新签发"
}

cdn_write_xray_config() {
    local clients managed_outbounds managed_routing inbound_sockopt reality_enabled=false
    local reality_target=${REALITY_TARGET:-} reality_sni
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
    clients=$(jq -cn --arg id "${VLESS_UUID}" '[{id:$id,email:"easy_all.owner"}]')
    install -d -m 0755 "${XRAY_DIR}"
    if cdn_reality_enabled; then
        reality_enabled=true
        if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
            REALITY_PRIVATE_KEY=$("${XRAY_BIN}" x25519 | awk '/PrivateKey/ {print $NF}')
        fi
        REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
        REALITY_PUBLIC_KEY=$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}" \
            | awk '/Password|PublicKey/ {print $NF; exit}')
        [[ -n "${REALITY_PRIVATE_KEY}" && -n "${REALITY_PUBLIC_KEY}" ]] \
            || die "生成 Reality X25519 密钥失败"
    fi
    reality_sni=${reality_target%%:*}
    jq -n \
        --argjson clients "${clients}" \
        --argjson reality_enabled "${reality_enabled}" \
        --arg target "${reality_target}" \
        --arg sni "${reality_sni}" \
        --arg private_key "${REALITY_PRIVATE_KEY:-}" \
        --arg short_id "${REALITY_SHORT_ID:-}" \
        --argjson reality_port "${REALITY_PORT:-0}" \
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
          inbounds: (
            (if $reality_enabled then [{
              tag: "vless-reality-in",
              listen: "0.0.0.0",
              port: $reality_port,
              protocol: "vless",
              settings: {clients: [$clients[] | . + {flow:"xtls-rprx-vision"}], decryption: "none"},
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
            }] else [] end)
            +
            [{
              tag: "vless-xhttp-in",
              listen: "127.0.0.1",
              port: $xhttp_port,
              protocol: "vless",
              settings: {clients: $clients, decryption: "none"},
              streamSettings: {
                network: "xhttp",
                sockopt: $sockopt,
                xhttpSettings: {
                  host: $host, path: $path, mode: "stream-up",
                  xPaddingBytes: $padding, scStreamUpServerSecs: $secs
                }
              },
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            }]
          ),
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
    if cdn_reality_enabled; then
        ufw allow "${REALITY_PORT}"/tcp comment "${UFW_RULE_COMMENT}" >/dev/null \
            || die "放行 Reality 端口失败"
    fi
    cloudflare_configure_origin_firewall
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

cdn_render_nginx_config() {
    local http2_directive=${1-} listen_h2=${2-}
    if (($# == 0)); then
        listen_h2="http2 "
        if nginx_supports_http2_directive; then
            http2_directive=$'\n    http2 on;'
            listen_h2=""
        fi
    fi
    write_subscription_nginx_maps 1
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
    write_subscription_nginx_locations "" static 1
    cat <<EOF
}
EOF
}

# 本机节点名必须与 Mihomo 分组名、其他本机节点互不重名：存量状态可能沿用
# 4.3.0 之前允许的 CDN-FALLBACK / 官方兜底节点名，渲染前统一拦截。
cdn_validate_local_node_names() {
    local direct=${DIRECT_NODE_NAME:-} index
    cdn_reality_enabled || return 0
    case "${direct}" in
    "" | AUTO | CDN-AUTO | CDN-FALLBACK | PROXY | GLOBAL | DIRECT | REJECT | PASS)
        printf '直连节点名无效或与保留组名冲突：%s\n' "${direct}" >&2
        return 1
        ;;
    esac
    if [[ "${direct}" == "$(cdn_cf_domain_node_name)" ]]; then
        printf '直连节点名与 CDN 官方兜底节点重名：%s\n' "${direct}" >&2
        return 1
    fi
    for index in 1 2 3 4 5 6; do
        if [[ "${direct}" == "${CF_NODE_PREFIX}${index}" ]]; then
            printf '直连节点名与 Cloudflare 优选节点重名：%s\n' "${direct}" >&2
            return 1
        fi
    done
    return 0
}

# 任何会写 Nginx 配置/订阅文件的路径都先过这里；install 另有更早的校验点。
cdn_require_valid_owner_token() {
    cdn_validate_local_node_names \
        || die "本机节点名与 CDN 兜底节点或保留组名冲突；请修改 /etc/easy_all/state.env 中的 DIRECT_NODE_NAME / CF_NODE_PREFIX，或执行 sudo easy_all uninstall 后重装"
    cdn_config_ready && return 0
    die "订阅配置无效（需 allowedTokens 与 nodes；节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru）；请先执行 sudo easy_all edit-sub 重新配置"
}

write_nginx_config() {
    optimize_nginx_system_config
    local http2_directive="" listen_h2="http2 "
    cdn_require_valid_owner_token
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    install -d -m 0755 "${WEB_ROOT}"
    cdn_render_nginx_config "${http2_directive}" "${listen_h2}" >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

cdn_certificate_covers_node_domain() {
    local out=""
    [[ -s "${CERT_FILE}" ]] || return 1
    out=$(openssl x509 -in "${CERT_FILE}" -checkhost "${CF_NODE_DOMAIN}" -noout 2>/dev/null || true)
    # macOS/LibreSSL 没有 -checkhost（报 unknown option）：退回按证书 SAN 集合判定，
    # 否则开发机上 status/apply 会误报“证书未覆盖节点域名”。
    [[ -n "${out}" ]] \
        || { cloudflare_certificate_san_hosts "${CERT_FILE}" | grep -Fxq "${CF_NODE_DOMAIN}"; return; }
    [[ "${out}" == *"does match certificate"* && "${out}" != *"does NOT match"* ]]
}

# XHTTP stream-up 路径由 grpc_pass 转发给 Xray，普通 GET 会因缺少 gRPC 帧/流式请求体被拒绝或挂起；
# 探测同一 server 块内的 /easy_all-health 可在不触发代理流的前提下验证 CF_NODE_DOMAIN 的本机 TLS 握手、
# Origin CA 证书 SAN 覆盖与 Nginx SNI/Host 路由（未命中该 server 块时会落入 default_server 被拒绝握手）。
cdn_validate_cf_node_sni() {
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
    if [[ "${mode}" == "lenient" ]] && ! cdn_certificate_covers_node_domain; then
        warn "当前 Origin CA 证书未覆盖 ${CF_NODE_DOMAIN}；本机配置已重建，请执行 sudo easy_all apply-cloud 重签证书"
        return 0
    fi
    die "Cloudflare 节点域名 ${CF_NODE_DOMAIN} 本机 TLS/SNI 验收失败：请确认 Nginx server_name 与 Origin CA 证书 SAN 已覆盖该域名（升级后请执行 sudo easy_all apply-cloud）"
}

# 兜底组必须按分组块结构校验：按名字子串匹配会被聚合节点名（如 name: CDN-FALLBACK）掩盖。
cdn_subscription_has_fallback_group() {
    local yaml=$1 block expected_member
    block=$(awk '
        $0 == "    - name: CDN-FALLBACK" { inside = 1; next }
        inside && (/^[[:space:]]*- name: / || /^[^[:space:]]/) { exit }
        inside { print }
    ' <<<"${yaml}")
    [[ -n "${block}" ]] || return 1
    grep -Eq '^[[:space:]]+type: fallback$' <<<"${block}" || return 1
    grep -Fxq '        - "CDN-AUTO"' <<<"${block}" || return 1
    # 节点名允许引号/反斜杠，渲染器用 @json 转义；这里必须用同一编码再整行比对。
    expected_member=$(jq -nr --arg name "$(cdn_cf_domain_node_name)" '"        - \($name|@json)"')
    grep -Fxq "${expected_member}" <<<"${block}" || return 1
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
    cdn_subscription_has_fallback_group "${mihomo_response}" \
        || die "Mihomo 订阅缺少 CDN 域名兜底分组"
    validate_subscription_token_rejection \
        "${SUBSCRIPTION_DOMAIN}:443:127.0.0.1" "https://${SUBSCRIPTION_DOMAIN}/subscribe" \
        "${tls_args[@]}"
}

# 官方调度兜底节点：连接橙云 CDN 域名本身，由 Cloudflare 官方 Anycast 调度决定边缘。
cdn_cf_domain_node_name() {
    printf '%s官方' "${CF_NODE_PREFIX}"
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

cdn_cf_candidates() {
    cloudflare_globalping_cache_compatible || return 1
    jq -r '.candidates | to_entries[] | [.value.ip, ((.key + 1) | tostring)] | @tsv' \
        "${GLOBALPING_CACHE_FILE}"
}

build_node_links() {
    local ip label extra
    if cdn_reality_enabled; then
        declare -F build_reality_link >/dev/null || die "缺少 Reality 节点渲染钩子：build_reality_link"
        build_reality_link
        printf '\n'
    fi
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_vless_xhttp_link "${ip}" "${CF_NODE_PREFIX}${label}"
        printf '\n'
    done < <(cdn_cf_candidates)
    build_vless_xhttp_link "${CF_NODE_DOMAIN}" "$(cdn_cf_domain_node_name)"
    printf '\n'
    extra=$(aggregation_node_links)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
}

build_mihomo_nodes() {
    local ip label extra
    if cdn_reality_enabled; then
        declare -F build_mihomo_reality_node >/dev/null \
            || die "缺少 Reality 节点渲染钩子：build_mihomo_reality_node"
        build_mihomo_reality_node
    fi
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_xhttp_node "${ip}" "${CF_NODE_PREFIX}${label}"
    done < <(cdn_cf_candidates)
    build_mihomo_xhttp_node "${CF_NODE_DOMAIN}" "$(cdn_cf_domain_node_name)"
    extra=$(aggregation_mihomo_nodes)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
}

# 6 个优选 IP 节点名（CDN-AUTO 成员）；官方域名兜底节点不参与测速。
cdn_cf_ip_node_names() {
    local ip label names
    names='[]'
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        names=$(jq -cn --argjson names "${names}" --arg value "${CF_NODE_PREFIX}${label}" \
            '$names + [$value]')
    done < <(cdn_cf_candidates)
    printf '%s\n' "${names}"
}

build_mihomo_proxy_names() {
    local extra direct=""
    # 订阅渲染的最后一道闸：坏名字在这里就失败，不会把重复节点/组名发布出去。
    cdn_validate_local_node_names \
        || die "本机节点名与 CDN 兜底节点或保留组名冲突；请修改状态或重装后再发布订阅"
    if cdn_reality_enabled; then
        direct=${DIRECT_NODE_NAME:-}
    fi
    extra=$(aggregation_node_names)
    jq -nr --arg direct "${direct}" --argjson extra "${extra}" '
        (if $direct == "" then [] else [$direct] end) + $extra + ["CDN-FALLBACK"]
        | .[] | "        - \(.|@json)"'
}

build_mihomo_proxy_groups() {
    local names
    names=$(cdn_cf_ip_node_names)
    [[ -n "${names}" && "${names}" != "[]" ]] \
        || die "Cloudflare 优选 IP 缓存不可用，无法生成 CDN-AUTO；请执行 sudo easy_all refresh-cdn-ips"
    printf '    - name: CDN-AUTO\n      type: url-test\n      proxies:\n'
    jq -r '.[] | "        - \(.|@json)"' <<<"${names}"
    cat <<'EOF'
      url: https://www.gstatic.com/generate_204
      interval: 300
      tolerance: 50
    - name: CDN-FALLBACK
      type: fallback
      proxies:
        - "CDN-AUTO"
EOF
    jq -nr --arg name "$(cdn_cf_domain_node_name)" '"        - \($name|@json)"'
    cat <<'EOF'
      url: https://www.gstatic.com/generate_204
      interval: 300
EOF
}

show_node() {
    local ip label extra
    collect_installed_state
    if cdn_reality_enabled; then
        printf '\n直连节点:\n'
        build_reality_link
        printf '\n'
    fi
    printf '\nCloudflare 节点（优选 IPv4 + 官方调度域名兜底）:\n'
    while IFS=$'\t' read -r ip label; do
        [[ -n "${ip}" ]] || continue
        build_vless_xhttp_link "${ip}" "${CF_NODE_PREFIX}${label}"
        printf '\n'
    done < <(cdn_cf_candidates)
    build_vless_xhttp_link "${CF_NODE_DOMAIN}" "$(cdn_cf_domain_node_name)"
    printf '\n'
    extra=$(aggregation_node_links)
    printf '\n聚合节点（订阅内联）:\n'
    if [[ -n "${extra}" ]]; then
        printf '%s\n' "${extra}"
    else
        printf '无\n'
    fi
}

show_status() {
    local cf_cert_raw cf_cert_enddate="" expected_tokens actual_tokens
    require_root
    collect_installed_state
    if cdn_reality_enabled; then
        printf '协议: 直连 Reality + Cloudflare XHTTP\n'
    else
        printf '协议: Cloudflare XHTTP（纯 CDN）\n'
    fi
    show_tcp_acceleration_status
    if cdn_reality_enabled; then
        printf '直连入口: %s:%s\n' "${DIRECT_DOMAIN}" "${REALITY_PORT}"
    fi
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
    elif cdn_certificate_covers_node_domain; then
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

refresh_cdn_ips() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_valid_owner_token
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

cdn_finish_local() {
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
    cdn_write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_cf_node_sni lenient
    if ! globalping_cache_valid; then
        persist_globalping_token
        refresh_globalping_cache || warn "Cloudflare 优选 IP 刷新失败，沿用现有缓存"
    fi
    cdn_finish_local
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
    cdn_ensure_dns
    cdn_issue_certificates
    cdn_write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_cf_node_sni
    persist_cloudflare_token
    persist_globalping_token
    refresh_globalping_cache || warn "Cloudflare 优选 IP 刷新失败，沿用现有缓存"
    cdn_finish_local
    # 吊销不可逆，必须先关闭回滚再吊销，避免后续中断时恢复已吊销的旧证书。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    success "本机配置、订阅与云端资源已同步"
}

# 跨越本机与 Cloudflare 两部分：失败/中断时只回滚本机，云端已创建的
# 资源按设计保留，并用 purge 命令提示清理——擅自删除会让同域名重装撞上残留记录。
cleanup_partial_install() {
    cleanup_partial_install_local || return 1
    remove_daily_reboot_schedule || true
    cleanup_partial_install_files \
        "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" \
        "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
}

rollback_fresh_install() {
    warn "${CDN_MODE_LABEL} 模式首次安装未完成，正在回滚本机服务、UFW 与 crontab 配置（保留前置初始化：SWAP、系统依赖与 TCP/Skyline 加速）"
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
    install_failure_begin "${CDN_EXPECTED_PROTOCOL}"
    prepare_fresh_install "${CDN_INSTALL_PORTS[@]}"
    install_progress_begin "${CDN_EXPECTED_PROTOCOL}"
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
    if cdn_reality_enabled; then
        validate_reality_target_runtime
    fi
    install_progress_stage services
    xhttp_configure_ufw
    cdn_ensure_dns
    cdn_issue_certificates
    cdn_write_xray_config
    # 此时已有 Reality 密钥与 Origin CA 元数据，再落一次盘供续装复用。
    persist_install_identity || warn "无法落盘安装身份；中断后无法完全复用密钥与证书元数据"
    install_xray_service
    write_bootstrap_nginx_config
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_cf_node_sni
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
    success "easy_all ${CDN_MODE_LABEL} 安装完成（${CDN_ENTRY_SUMMARY}）"
    show_tcp_acceleration_status
    prompt_kernel_reboot
}

# 当前 Cloudflare 环境变量 Token 与 ALLOWED_TOKENS 的格式约束（与 normalize_allowed_tokens 一致）。
cdn_token_valid() {
    local token=${1:-}
    # 首字符排除 ~：nginx map 中 "~..." 形式的键会被解析为正则，可能匹配到别的 token。
    [[ "${token}" =~ ^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$ ]]
}

# 本机节点名（用于拒绝聚合 JSON 中的重名）：CDN 优选节点、官方域名兜底节点，
# 以及直连模式下的本机 Reality 节点。这里按命名规则生成而不读优选缓存：安装输入阶段
# 还没有缓存，读缓存会让重名校验在首装时静默失效。
cdn_local_node_names() {
    local names='[]' index
    for index in 1 2 3 4 5 6; do
        names=$(jq -cn --argjson names "${names}" --arg value "${CF_NODE_PREFIX}${index}" \
            '$names + [$value]')
    done
    names=$(jq -cn --argjson names "${names}" --arg value "$(cdn_cf_domain_node_name)" \
        '$names + [$value]')
    if cdn_reality_enabled; then
        names=$(jq -cn --argjson names "${names}" --arg value "${DIRECT_NODE_NAME:-}" \
            '$names + [$value]')
    fi
    printf '%s' "${names}"
}

# 订阅配置的唯一入口：allowedTokens 与 nodes 一起校验，并派生运行时变量。
cdn_apply_subscription_config() {
    apply_local_aggregation_config "${1:-}" "$(cdn_local_node_names)" || return 1
    OWNER_TOKEN=$(jq -er '.allowedTokens | to_entries[0].value' <<<"${SUBSCRIPTION_CONFIG}") || return 1
}

# 兼容旧状态与环境变量：把单独的 Token 字典折叠进统一配置。
cdn_sync_allowed_tokens() {
    if [[ -n "${SUBSCRIPTION_CONFIG:-}" ]] \
        && cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" 2>/dev/null; then
        return 0
    fi
    if [[ -z "${ALLOWED_TOKENS:-}" ]]; then
        [[ -n "${OWNER_TOKEN:-}" ]] || return 1
        ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}') || return 1
    fi
    # 旧配置校验失败时仍按原 nodes 重建后再校验：直接折叠成 [] 会把用户的聚合节点静默丢掉。
    local nodes=${AGGREGATION_NODES:-[]}
    if [[ "${nodes}" == "[]" && -n "${SUBSCRIPTION_CONFIG:-}" ]]; then
        nodes=$(jq -c 'if (.nodes | type) == "array" then .nodes else [] end' \
            <<<"${SUBSCRIPTION_CONFIG}" 2>/dev/null || printf '[]')
    fi
    SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" \
        --argjson n "${nodes}" '{allowedTokens:$t,nodes:$n}') || return 1
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}"
}

# 兼容直接修改 ALLOWED_TOKENS 的旧入口：以当前 Token 字典为准更新配置。
cdn_sync_config_tokens() {
    local configured
    [[ -n "${SUBSCRIPTION_CONFIG:-}" && -n "${ALLOWED_TOKENS:-}" ]] || return 0
    configured=$(jq -c '.allowedTokens // empty' <<<"${SUBSCRIPTION_CONFIG}" 2>/dev/null) || return 0
    [[ "${configured}" == "${ALLOWED_TOKENS}" ]] && return 0
    SUBSCRIPTION_CONFIG=$(jq -c --argjson t "${ALLOWED_TOKENS}" \
        '.allowedTokens = $t' <<<"${SUBSCRIPTION_CONFIG}") || return 1
}

cdn_config_ready() {
    cdn_validate_local_node_names || return 1
    cdn_sync_config_tokens || return 1
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG:-}" >/dev/null 2>&1
}

# 安装阶段在改动任何云端资源之前就拒绝非法配置（环境变量传入同样受检）
cdn_validate_install_owner_token() {
    cdn_validate_local_node_names \
        || die "本机节点名与 CDN 兜底节点或保留组名冲突"
    if [[ -z "${SUBSCRIPTION_CONFIG:-}" ]] \
        && [[ -n "${ALLOWED_TOKENS:-}" || -n "${OWNER_TOKEN:-}" ]]; then
        cdn_sync_allowed_tokens || true
    fi
    cdn_config_ready && return 0
    die "订阅配置无效：allowedTokens 需为 8-128 位 URL 安全字符的 {\"用户\":\"token\"} 字典；nodes 仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
}

# 仅修改 Token 字典（兼容入口），保持 nodes 不变。
cdn_apply_tokens() {
    local raw=${1:-} normalized token
    raw=${raw#"${raw%%[![:space:]]*}"}
    raw=${raw%"${raw##*[![:space:]]}"}
    [[ -n "${raw}" ]] || return 1
    if [[ "${raw}" == \{* ]]; then
        normalized=$(normalize_allowed_tokens "${raw}" 2>/dev/null) || return 1
    else
        token=${raw//[[:space:]]/}
        cdn_token_valid "${token}" || return 1
        normalized=$(jq -cn --arg token "${token}" '{owner:$token}') || return 1
    fi
    ALLOWED_TOKENS=${normalized}
    OWNER_TOKEN=$(jq -er 'to_entries[0].value' <<<"${normalized}") || return 1
    if [[ -n "${SUBSCRIPTION_CONFIG:-}" ]]; then
        SUBSCRIPTION_CONFIG=$(jq -c --argjson t "${ALLOWED_TOKENS}" \
            '.allowedTokens = $t' <<<"${SUBSCRIPTION_CONFIG}") || return 1
    else
        SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" \
            '{allowedTokens:$t,nodes:[]}') || return 1
    fi
    return 0
}

update_subscription() {
    local raw_config="" caller_config=${SUBSCRIPTION_CONFIG:-}
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if [[ -t 0 ]]; then
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME}")")
        raw_config=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}")
    else
        raw_config=${caller_config:-${SUBSCRIPTION_CONFIG:-}}
    fi
    cdn_apply_subscription_config "${raw_config}" \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes；节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
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
    cdn_require_valid_owner_token
    cloudflare_collect_api_token
    snapshot_subscription_update
    cdn_issue_certificates 1
    nginx -t >/dev/null || die "证书更新后 Nginx 配置校验失败"
    systemctl reload nginx || die "证书更新后 Nginx 重载失败"
    # 新证书必须真的能完成本机 TLS/SNI 握手才允许吊销旧证书（吊销不可逆）。
    cdn_validate_cf_node_sni
    save_state
    # 吊销不可逆，必须先关闭回滚再吊销，避免后续中断时恢复已吊销的旧证书。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    success "证书已更新"
}

purge_cdn_dns() {
    local host records count id comment
    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${host}")
        count=$(jq 'length' <<<"${records}")
        ((count == 1)) || continue
        id=$(jq -r '.[0].id' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        [[ "${comment}" == "${CDN_RECORD_COMMENT}" ]] || continue
        (cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null) \
            || warn "删除 Cloudflare 记录失败：${host}"
    done < <(cdn_dns_only_domains; cdn_proxied_domains)
}

purge_cdn_origin_certificate() {
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
        # cloudflare_api_request / Zone 查询失败会 die；放进子 shell，保证本机卸载、安全状态恢复
        # 与 UFW 回收照常执行，不会把 VPS 锁在半卸载状态。
        if ! (
            cloudflare_collect_api_token
            # 命令替换里的 die 只结束子替换进程；这里显式退出子 shell，避免拿空 Zone 继续删记录。
            zone=$(cloudflare_lookup_parent_zone "${CF_ZONE}") || exit 1
            CLOUDFLARE_ZONE_ID=${zone}
            purge_cdn_dns
            purge_cdn_origin_certificate
            cloudflare_clear_api_token
        ); then
            warn "Cloudflare 资源清理未完成；本机卸载继续。可稍后执行：easy_all purge-cloudflare --domain ${CF_ZONE:-<域名>}"
        fi
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
    success "easy_all ${CDN_MODE_LABEL} 本机内容已卸载"
}
