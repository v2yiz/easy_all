#!/usr/bin/env bash

# Cloudflare CDN XHTTP stream-up profile.
#
# This Profile provides pure VLESS XHTTP stream-up over Cloudflare CDN,
# fully adapted to Cloudflare HTTP/2 and gRPC edge streaming with
# randomized keep-alive server timeout and packet padding.
# Strictly outputs top 5 curated IPv4 nodes (no domain fallback).

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'xhttp-cloudflare-streamup.sh 是 easy_all 的 Cloudflare 纯 XHTTP Stream-up Profile；请使用：easy_all install\n' >&2
    exit 2
fi

PROFILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if ! declare -F cloudflare_api_request >/dev/null; then
    # shellcheck source=profiles/xhttp-cloudflare.sh
    source "${PROFILE_DIR}/xhttp-cloudflare.sh"
fi
# shellcheck source=lib/xray-core.sh
source "${PROFILE_DIR}/../lib/xray-core.sh"

XRAY_XHTTP_LOOPBACK_PORT="${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}}"
ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-}"
BACKEND="xray"
PROTOCOL="cloudflare-streamup"
CDN_PROVIDER="cloudflare"

read_state_field() {
    local file=$1 key=$2 line value
    [[ -f "${file}" ]] || return 1
    line=$(grep -E "^${key}=" "${file}" | tail -n 1) || return 1
    value=${line#*=}
    value=${value#\'}
    value=${value%\'}
    value=${value#\"}
    value=${value%\"}
    printf '%s\n' "${value}"
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
    printf '%s\n' "${path}"
}

can_in_place_migrate_from_xhttp_cloudflare() {
    local state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    [[ -f "${state_path}" ]] || return 1
    local cdn proto
    cdn=$(read_state_field "${state_path}" CDN_PROVIDER || true)
    proto=$(read_state_field "${state_path}" PROTOCOL || true)
    [[ "${cdn}" == "cloudflare" && ("${proto}" == "xhttp" || "${proto}" == "ws" || "${proto}" == "singbox-cf") ]]
}

can_in_place_migrate_from_streamup_cloudflare() {
    local state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    [[ -f "${state_path}" ]] || return 1
    local cdn proto
    cdn=$(read_state_field "${state_path}" CDN_PROVIDER || true)
    proto=$(read_state_field "${state_path}" PROTOCOL || true)
    [[ "${cdn}" == "cloudflare" && ("${proto}" == "cloudflare-streamup" || "${proto}" == "xhttp-streamup" || "${proto}" == "singbox-cf") ]]
}

collect_install_inputs() {
    PROTOCOL="cloudflare-streamup"
    BACKEND="xray"
    CDN_PROVIDER="cloudflare"
    choose_cdn_client_ip_family

    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"

    info "Cloudflare 模式采用单域名架构：此域名同时用于客户端连接、Cloudflare 回源和 VPS 证书。"
    VLESS_CDN_DOMAIN=$(normalize_domain "${VLESS_CDN_DOMAIN:-$(prompt_value "客户端连接的 CDN 节点域名" "" "CDN hostname used by clients")}")
    validate_domain "${VLESS_CDN_DOMAIN}" || die "VLESS_CDN_DOMAIN 无效"
    CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}

    info "Cloudflare 模式从官方 IPv4 CIDR 轮换抽样，并使用三网 Globalping eyeball 探针预筛。"
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"

    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效"

    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "XHTTP 本机端口无效"

    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "Origin header 密钥无效"

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
        CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME
        CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID
        CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
        CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID
        XRAY_XHTTP_LOOPBACK_PORT XHTTP_PATH
        ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    [[ -f "${state_path}" ]] || return 1
    for variable in "${variables[@]}"; do
        env_name=$(env -i bash -c 'source "$1" && printf "%s" "${'"${variable}"':-}"' _ "${state_path}")
        printf -v "${variable}" '%s' "${env_name}"
    done
    [[ "${PROTOCOL}" == "cloudflare-streamup" || "${PROTOCOL}" == "xhttp-streamup" || "${PROTOCOL}" == "singbox-cf" || ("${CDN_PROVIDER:-}" == "cloudflare" && "${BACKEND:-}" == "xray") ]] \
        || die "状态不是 Cloudflare XHTTP Stream-up"
    configure_cdn_client_ip_family
    validate_domain "${CLOUDFLARE_ORIGIN_DOMAIN:-}" && validate_domain "${VLESS_CDN_DOMAIN:-}" \
        && validate_uuid "${VLESS_UUID:-}" || die "Cloudflare 状态缺少有效域名或 UUID"
    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "状态中的 XHTTP_PATH 无效"

    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "状态中的 XHTTP 本机端口无效"
    [[ "${CLOUDFLARE_ORIGIN_DOMAIN}" == "${VLESS_CDN_DOMAIN}" ]] \
        || die "Cloudflare 状态不是单一 Proxied 源站域名架构"
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${CLOUDFLARE_ZONE_NAME:-}" \
        && -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
        && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" ]] \
        || die "状态缺少 Cloudflare Zone 或 Origin CA 资源"
    [[ "${ORIGIN_HEADER_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "源站密钥无效"
    XHTTP_ORIGIN_DOMAIN=${CLOUDFLARE_ORIGIN_DOMAIN}
    SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN:-${VLESS_CDN_DOMAIN}}")
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-none}") || die "订阅模式无效"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}") || die "订阅文件名无效"
    [[ -z "${ALLOWED_TOKENS:-}" ]] || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") || die "Token 无效"
    BACKEND="xray"
    PROTOCOL="cloudflare-streamup"
    CDN_PROVIDER="cloudflare"
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
            CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME \
            CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID \
            CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON \
            CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID \
            XRAY_XHTTP_LOOPBACK_PORT XHTTP_PATH ORIGIN_HEADER_SECRET ALLOWED_TOKENS \
            SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR; do
            case "${v}" in
            STATE_VERSION) printf '%s=%q\n' "${v}" "${STATE_SCHEMA_VERSION}" ;;
            PROTOCOL) printf '%s=%q\n' "${v}" "cloudflare-streamup" ;;
            BACKEND) printf '%s=%q\n' "${v}" "xray" ;;
            CDN_PROVIDER) printf '%s=%q\n' "${v}" "cloudflare" ;;
            SUBSCRIPTION_DOMAIN) printf '%s=%q\n' "${v}" "$(subscription_link_domain)" ;;
            *) printf '%s=%q\n' "${v}" "${!v:-}" ;;
            esac
        done
    } >"${t}"
    install -m 0600 "${t}" "${target}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Cloudflare CDN XHTTP stream-up 尚未安装"
    load_state
}

xhttp_render_xray_config() {
    install -d -m 0755 "${XRAY_DIR}"
    local clients
    clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" '[{id:$id,email:$email}]')
    local outbounds routing sockopt
    outbounds=$(xray_xhttp_outbounds_json)
    routing=$(xray_xhttp_routing_json)
    sockopt=$(xray_inbound_sockopt_json)
    jq -n \
        --argjson port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson clients "${clients}" \
        --arg host "${VLESS_CDN_DOMAIN}" \
        --arg path "${XHTTP_PATH}" \
        --arg secs "${CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS}" \
        --arg padding "${CLOUDFLARE_XHTTP_PADDING_BYTES}" \
        --argjson sockopt "${sockopt}" \
        --argjson outbounds "${outbounds}" \
        --argjson routing "${routing}" '
        {
          log: { loglevel: "warning" },
          inbounds: [
            {
              tag: "vless-xhttp-h2-in",
              listen: "127.0.0.1",
              port: $port,
              protocol: "vless",
              settings: {
                clients: $clients,
                decryption: "none"
              },
              streamSettings: {
                network: "xhttp",
                sockopt: $sockopt,
                xhttpSettings: {
                  host: $host,
                  path: $path,
                  mode: "stream-up",
                  xPaddingBytes: $padding,
                  scStreamUpServerSecs: $secs
                }
              },
              sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                routeOnly: false
              }
            }
          ],
          outbounds: $outbounds,
          routing: $routing
        }' >"${RUNTIME_TMP}/xray-config.json"
    if [[ -x "${XRAY_BIN}" ]]; then
        "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null 2>&1 || die "Xray 配置校验失败"
    fi
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

write_nginx_config() {
    local http2_directive="" listen_h2="http2 "
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    install -d -m 0755 "${WEB_ROOT}"
    {
        write_subscription_nginx_maps
        cat <<EOF
upstream cf_xhttp_backend {
    server 127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};
    keepalive 32;
}

server {
    listen 80;
    listen [::]:80;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    location / { return 301 https://${XHTTP_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3;
    listen [::]:443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3;${http2_directive}
    server_name ${XHTTP_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "easy_all ok\n";
    }

EOF
        write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}"
        cat <<EOF
    location = ${XHTTP_PATH} {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Host ${VLESS_CDN_DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_socket_keepalive on;
        proxy_pass http://cf_xhttp_backend;
        access_log off;
    }

    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

cloudflare_add_streamup_header_rule() {
    local ruleset=$1 host=$2 path=$3 ref
    ref=$(cloudflare_ref "header:${host}:${path}")
    local expr
    expr="http.host eq \"${host}\" and (starts_with(http.request.uri.path, \"${path}\") or starts_with(http.request.uri.path, \"/easy_all-health\") or starts_with(http.request.uri.path, \"/subscribe\"))"
    cloudflare_upsert_rule "${ruleset}" "${ref}" \
        "$(jq -cn --arg ref "${ref}" --arg expr "${expr}" --arg key "${ORIGIN_HEADER_SECRET}" \
            '{ref:$ref,description:"easy_all xhttp streamup origin header",expression:$expr,action:"rewrite",action_parameters:{headers:{"X-Easy-All-Origin-Key":{operation:"set",value:$key}}}}')"
}

cloudflare_configure_rules() {
    local host transform strict ref
    host=${VLESS_CDN_DOMAIN}
    transform=$(cloudflare_managed_ruleset "easy_all xhttp streamup headers ${host}" "http_request_late_transform")
    cloudflare_add_streamup_header_rule "${transform}" "${host}" "${XHTTP_PATH}"
    if subscription_enabled \
        && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then
        cloudflare_add_header_rule "${transform}" \
            "$(active_subscription_link_domain)" "/subscribe" ""
    fi
    strict=$(cloudflare_managed_ruleset "easy_all xhttp streamup strict ${host}" "http_config_settings")
    while IFS= read -r host; do
        ref=$(cloudflare_ref "strict:${host}")
        cloudflare_upsert_rule "${strict}" "${ref}" \
            "$(jq -cn --arg ref "${ref}" --arg host "${host}" \
                '{ref:$ref,description:"easy_all xhttp streamup strict origin TLS",expression:("http.host eq \""+$host+"\""),action:"set_config",action_parameters:{ssl:"strict",security_level:"essentially_off",bic:false}}')"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')
    CLOUDFLARE_HEADER_RULESET_ID=${transform}
    CLOUDFLARE_STRICT_RULESET_ID=${strict}
}

stop_services() {
    systemctl stop "${XRAY_SERVICE}" "${SINGBOX_SERVICE:-easy_all-singbox.service}" nginx 2>/dev/null || true
}

validate_protocol_runtime() {
    local attempt response
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    if declare -F xhttp_validate_local_tls_curl_args >/dev/null 2>&1; then
        xhttp_validate_local_tls_curl_args
    fi
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${XRAY_SERVICE}" \
            && systemctl is-active --quiet nginx \
            && ss -H -ltn "sport = :443" 2>/dev/null | grep -q .; then
            response=$(curl -fsS "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" \
                --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
                -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
                "https://${XHTTP_ORIGIN_DOMAIN}/easy_all-health" || true)
            if [[ "${response}" == "easy_all ok" ]]; then
                return 0
            fi
        fi
        sleep 2
    done
    die "VLESS XHTTP 本机运行时验收失败"
}

finish_xhttp_apply() {
    local sync_cloud=${1:-0}
    xhttp_render_xray_config
    write_nginx_config
    if ! systemctl is-active --quiet "${XRAY_SERVICE}"; then
        install_xray_service
    else
        systemctl reload-or-restart "${XRAY_SERVICE}" || systemctl restart "${XRAY_SERVICE}" || die "重启 Xray 失败"
    fi
    validate_protocol_runtime
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    else
        remove_subscriptions
    fi
    save_state
    ((sync_cloud == 1)) || return 0
}

build_vless_xhttp_link() {
    local server=$1 node_name=$2
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${XHTTP_PATH}")" "$(uri_encode "${node_name}")"
}

build_mihomo_xhttp_node() {
    local server=$1 node_name=$2
    resolve_cdn_client_ip_family
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg path "${XHTTP_PATH}" --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED:-ipv4}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: \($ip_version)\n    alpn:\n      - h2\n" +
        "    xhttp-opts:\n      host: \($host|@json)\n      path: \($path|@json)\n      mode: stream-up\n" +
        "      uplink-http-method: POST\n      reuse-settings:\n        max-connections: 4\n" +
        "        c-max-reuse-times: 0\n        h-max-request-times: 300-600\n        h-max-reusable-secs: 900-1800\n        h-keep-alive-period: 0\n"'
}

# Strictly filter out any fallback lines: select top 5 high-quality unique IPs.
# 5 IPs x 1 protocol (XHTTP stream-up) = 5 nodes (no domain fallback).
cloudflare_xhttp_streamup_client_candidates() {
    if cdn_optimization_enabled && globalping_cache_valid; then
        jq -r '
          .candidates
          | group_by(.ip)
          | map(sort_by([(if .tls_verified == true then 0 else 1 end), .avg_rtt_ms])[0])
          | sort_by([(if .tls_verified == true then 0 else 1 end), .avg_rtt_ms, .ip])
          | .[0:5]
          | to_entries[]
          | [.value.ip, (if (.key + 1) < 10 then "0" + ((.key + 1)|tostring) else ((.key + 1)|tostring) end), (.value.carrier // "anycast")]
          | @tsv
        ' "${GLOBALPING_CACHE_FILE}"
    elif declare -F cloudflare_client_candidates >/dev/null 2>&1; then
        local ip label carrier count=0
        while IFS=$'\t' read -r ip label carrier; do
            [[ -n "${ip}" ]] || continue
            [[ "${carrier}" == "fallback" ]] && continue
            count=$((count + 1))
            local idx
            idx=$(printf '%02d' "${count}")
            printf '%s\t%s\t%s\n' "${ip}" "${idx}" "${carrier}"
            ((count >= 5)) && break
        done < <(cloudflare_client_candidates)
    fi
}

build_node_links() {
    local ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        build_vless_xhttp_link "${ip}" "XHTTP${label}"
        printf '\n'
    done < <(cloudflare_xhttp_streamup_client_candidates)
}

build_mihomo_nodes() {
    local ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_xhttp_node "${ip}" "XHTTP${label}"
    done < <(cloudflare_xhttp_streamup_client_candidates)
}

build_mihomo_proxy_names() {
    printf '        - "AUTO"\n'
    local ip label carrier
    local -a all_nodes=()
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        all_nodes+=("XHTTP${label}")
    done < <(cloudflare_xhttp_streamup_client_candidates)

    local node
    for node in "${all_nodes[@]}"; do
        printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
    done
}

build_mihomo_proxy_groups() {
    local -a all_nodes=()
    local ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        all_nodes+=("XHTTP${label}")
    done < <(cloudflare_xhttp_streamup_client_candidates)

    printf '    - name: "AUTO"\n'
    printf '      type: url-test\n'
    printf '      proxies:\n'
    local node
    for node in "${all_nodes[@]}"; do
        printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
    done
    cat <<EOF
      url: https://cp.cloudflare.com/generate_204
      interval: 300
      tolerance: 50
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

    grep -Fq 'network: xhttp' "${mihomo_file}" || die "Mihomo 订阅缺少 XHTTP 节点"
    grep -Fq 'mode: stream-up' "${mihomo_file}" || die "Mihomo 订阅缺少 stream-up 模式"

    rm -rf -- "${SUBSCRIPTION_DIR}"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS XHTTP stream-up over Cloudflare CDN（精选 5 节点）\n节点链接:\n%s\n\n' "$(build_node_links)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_nodes
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: VLESS XHTTP stream-up（Cloudflare CDN 纯流模式）\n后端: Xray (%s)\n客户端 CDN 节点域名: %s\nCloudflare 回源域名: %s（单域名架构）\nOrigin CA: %s（到期 %s）\n候选来源: Cloudflare 官方 IPv4 CIDR / 三网 Globalping eyeball 探针\n域名兜底: disabled (全网精选 5 节点，无域名兜底)\n' \
        "$(xray_installed_version)" "${VLESS_CDN_DOMAIN}" "${CLOUDFLARE_ORIGIN_DOMAIN}" "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}"
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

refresh_cloudflare_cdn_ips() {
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
    if ! refresh_globalping_cache; then
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
    success "Cloudflare CDN 精选 IP 与订阅已刷新"
}

migrate_from_xhttp_cloudflare() {
    require_root
    info "检测到当前已安装 Cloudflare 模式。"
    info "正在执行就地平滑迁移至模式 5（保留全部 Cloudflare 云端资产、Origin CA 与 VLESS 凭据，切换为纯 XHTTP stream-up 精选 5 节点）..."
    load_state

    VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}"
    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}"
    ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-$(generate_secret)}"
    XHTTP_ORIGIN_DOMAIN="${VLESS_CDN_DOMAIN}"
    BACKEND="xray"
    PROTOCOL="cloudflare-streamup"
    CDN_PROVIDER="cloudflare"

    info "[1/6] 停止旧 Sing-box 服务（若存在）并确保 Xray 核心已就绪"
    systemctl stop easy_all-singbox.service >/dev/null 2>&1 || true
    systemctl disable easy_all-singbox.service >/dev/null 2>&1 || true
    download_xray
    xhttp_render_xray_config
    install_xray_service

    info "[2/6] 停止旧配额定时器（若有）"
    remove_quota_timer >/dev/null 2>&1 || true

    info "[3/6] 同步 Cloudflare 边缘规则"
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn

    info "[4/6] 更新 Nginx 反代配置并重载"
    write_nginx_config
    validate_protocol_runtime

    info "[5/6] 刷新精选 IP 并生成新格式订阅（5 节点无域名兜底）"
    refresh_cloudflare_cdn_ips

    info "[6/6] 保存状态并更新 easy_all 命令注册"
    save_state
    register_easy_all_command

    show_node
    if subscription_enabled; then
        show_subscription
    fi
    success "已成功就地平滑迁移至 Cloudflare 纯 XHTTP stream-up（精选 5 节点）！"
}

rollback_fresh_install() {
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_preinstall_firewall
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    cloudflare_clear_api_token
}

install_all() {
    [[ -t 0 || "${FORCE_INTERACTIVE:-0}" == "1" ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="cloudflare"
    BACKEND="xray"
    PROTOCOL="cloudflare-streamup"
    require_root
    require_systemd

    if can_in_place_migrate_from_xhttp_cloudflare; then
        local migrate_ans=""
        read_bilingual \
            "检测到当前已安装 Cloudflare 模式。是否直接就地无缝迁移至模式 5（保留全部 Cloudflare 云资源与 VLESS 凭据，切换为纯 XHTTP stream-up 模式）？[Y/n]:" \
            "Detected existing Cloudflare Mode. Migrate in-place to Mode 5 (preserve Cloudflare resources & VLESS creds, switch to pure XHTTP stream-up)? [Y/n]:" migrate_ans
        if [[ -z "${migrate_ans}" || "${migrate_ans}" =~ ^[Yy]$ ]]; then
            migrate_from_xhttp_cloudflare
            return 0
        fi
    fi

    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    check_platform
    check_install_conflicts
    snapshot_fresh_install
    install_packages
    ensure_ssh_boot_service
    configure_bbr_tcp
    configure_daily_reboot
    collect_install_inputs
    cloudflare_prepare_origin
    configure_ufw
    write_bootstrap_nginx_config
    cloudflare_issue_origin_certificate 0
    download_xray
    xhttp_render_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    cloudflare_configure_cdn
    cloudflare_validate_cdn_health
    cloudflare_finalize_certificate_rotation
    persist_globalping_token
    refresh_globalping_cache || warn "首次 Globalping 测量失败，暂回退 CDN 域名"
    subscription_enabled && { write_subscriptions; validate_subscription_runtime; }
    save_state
    register_easy_all_command
    install_quota_timer
    install_globalping_refresh_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    cloudflare_clear_api_token
    show_subscription
    success "easy_all Cloudflare CDN 纯 XHTTP stream-up 安装完成"
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
    success "Cloudflare XHTTP stream-up 本机配置已应用；未修改 Cloudflare 资源"
}

apply_cloud_resources() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn
    finish_xhttp_apply 1
    cloudflare_validate_cdn_health
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Cloudflare DNS、Origin CA、规则和本机配置已应用"
}

update_subscription() {
    local previous_subscription_host=""
    require_root
    collect_installed_state
    if subscription_enabled; then
        previous_subscription_host=$(active_subscription_link_domain)
    fi
    snapshot_subscription_update
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        choose_monthly_quota 0
        ensure_allowed_tokens
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        choose_monthly_quota 0
    fi
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn
    finish_xhttp_apply 1
    cloudflare_validate_cdn_health
    cloudflare_cleanup_previous_subscription_host "${previous_subscription_host}"
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_subscription
    success "Cloudflare 订阅、Origin CA 与回源规则已更新"
}

purge_cloudflare_resources_before_uninstall() {
    local host header_name strict_name
    [[ "${UNINSTALL_PURGE_CLOUD:-0}" == "1" ]] || return 0
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
        && -n "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
        && -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
        || die "状态缺少 Cloudflare 证书或 ruleset ID，已停止卸载；本机状态仍保留"
    cloudflare_collect_api_token

    cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID}" \
        "$(cloudflare_ref "header:${VLESS_CDN_DOMAIN}:${XHTTP_PATH}")"
    if subscription_enabled \
        && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then
        cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID}" \
            "$(cloudflare_ref "header:$(active_subscription_link_domain):/subscribe")"
    fi
    while IFS= read -r host; do
        cloudflare_purge_managed_rule "${CLOUDFLARE_STRICT_RULESET_ID}" \
            "$(cloudflare_ref "strict:${host}")"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')

    header_name="easy_all xhttp streamup headers ${VLESS_CDN_DOMAIN}"
    strict_name="easy_all xhttp streamup strict ${VLESS_CDN_DOMAIN}"
    cloudflare_purge_empty_owned_ruleset "${CLOUDFLARE_HEADER_RULESET_ID}" \
        "${header_name}" "http_request_late_transform"
    cloudflare_purge_empty_owned_ruleset "${CLOUDFLARE_STRICT_RULESET_ID}" \
        "${strict_name}" "http_config_settings"

    while IFS= read -r host; do
        cloudflare_purge_managed_dns_record "${host}"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')

    cloudflare_api_request DELETE "/certificates/${CLOUDFLARE_ORIGIN_CERT_ID}" >/dev/null \
        || die "Cloudflare Origin CA 吊销失败，已停止卸载；本机状态仍保留"
    cloudflare_clear_api_token
    success "easy_all 托管的 Cloudflare DNS、规则、ruleset 与 Origin CA 证书已清理"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all Cloudflare XHTTP stream-up 尚未安装"
    if [[ "${mode}" == "--purge-cloud" && ! -f "${STATE_FILE}" ]]; then
        die "缺少状态文件，无法安全识别 easy_all 托管的 Cloudflare 资源；本机内容未删除"
    fi
    [[ ! -f "${STATE_FILE}" ]] || load_state
    [[ "${FORCE:-0}" == 1 || -t 0 ]] \
        || die "非交互卸载必须设置 FORCE=1"
    UNINSTALL_PURGE_CLOUD=0
    [[ "${mode}" == "--purge-cloud" ]] && UNINSTALL_PURGE_CLOUD=1
    if [[ "${FORCE:-0}" != 1 ]]; then
        if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
            read_bilingual \
                '删除本机内容以及 easy_all 托管的 Cloudflare DNS、规则和 Origin CA 证书？[y/N]:' \
                'Delete local content and easy_all-managed Cloudflare DNS, rules, and Origin CA certificate? [y/N]:' answer
        else
            read_bilingual \
                '删除本机内容（Cloudflare 资源保留）？[y/N]:' \
                'Delete local content (Cloudflare resources are kept)? [y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    purge_cloudflare_resources_before_uninstall
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    rm -f -- "${XRAY_SERVICE_FILE}" "${SINGBOX_SERVICE_FILE:-/etc/systemd/system/easy_all-singbox.service}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}" "${SINGBOX_DIR:-/etc/easy_all/singbox}"
    if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
        success "本机内容及 easy_all 托管的 Cloudflare 远端资源已卸载"
    else
        success "本机内容已卸载；远端 Cloudflare 资源已保留"
    fi
}
