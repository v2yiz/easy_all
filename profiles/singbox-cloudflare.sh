#!/usr/bin/env bash

# Cloudflare CDN Sing-box (VLESS WebSocket + VLESS gRPC) profile.
#
# This Profile provides a Sing-box backend over Cloudflare CDN, running both
# VLESS + WebSocket and VLESS + gRPC on local loopback ports behind
# Nginx with Cloudflare Origin CA and Origin Key protection.
# Outputs 3-carrier optimized IPs (3 per carrier, total 18 nodes, no domain fallback).

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'singbox-cloudflare.sh 是 easy_all 的 Cloudflare Sing-box Profile；请使用：easy_all install\n' >&2
    exit 2
fi

SINGBOX_PROFILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if ! declare -F cloudflare_api_request >/dev/null; then
    # shellcheck source=profiles/xhttp-cloudflare.sh
    source "${SINGBOX_PROFILE_DIR}/xhttp-cloudflare.sh"
fi
# shellcheck source=lib/singbox-core.sh
source "${SINGBOX_PROFILE_DIR}/../lib/singbox-core.sh"

DEFAULT_SINGBOX_VLESS_WS_LOOPBACK_PORT="10087"
DEFAULT_SINGBOX_VLESS_GRPC_LOOPBACK_PORT="10086"

SINGBOX_VLESS_WS_LOOPBACK_PORT="${SINGBOX_VLESS_WS_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_WS_LOOPBACK_PORT}}"
SINGBOX_VLESS_GRPC_LOOPBACK_PORT="${SINGBOX_VLESS_GRPC_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_GRPC_LOOPBACK_PORT}}"
GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-}"
ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-}"
BACKEND="singbox"
PROTOCOL="singbox-cf"
CDN_PROVIDER="cloudflare"

generate_grpc_service_name() {
    printf 'grpc-%s' "$(openssl rand -hex 6)"
}

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

can_in_place_migrate_from_xhttp_cloudflare() {
    local state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    [[ -f "${state_path}" ]] || return 1
    local cdn backend proto
    cdn=$(read_state_field "${state_path}" CDN_PROVIDER || true)
    backend=$(read_state_field "${state_path}" BACKEND || true)
    proto=$(read_state_field "${state_path}" PROTOCOL || true)
    [[ "${cdn}" == "cloudflare" && "${backend}" != "singbox" && ("${proto}" == "xhttp" || "${proto}" == "ws") ]]
}

can_in_place_migrate_from_singbox_cloudflare() {
    local state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    [[ -f "${state_path}" ]] || return 1
    local cdn backend proto
    cdn=$(read_state_field "${state_path}" CDN_PROVIDER || true)
    backend=$(read_state_field "${state_path}" BACKEND || true)
    proto=$(read_state_field "${state_path}" PROTOCOL || true)
    [[ "${cdn}" == "cloudflare" && "${backend}" == "singbox" && "${proto}" == "singbox-cf" ]]
}

collect_install_inputs() {
    PROTOCOL="singbox-cf"
    BACKEND="singbox"
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

    WEBSOCKET_PATH=${WEBSOCKET_PATH:-/ws-$(openssl rand -hex 12)}
    [[ "${WEBSOCKET_PATH}" =~ ^/[A-Za-z0-9._~/-]{3,128}$ ]] || die "WEBSOCKET_PATH 无效"

    GRPC_SERVICE_NAME=${GRPC_SERVICE_NAME:-$(generate_grpc_service_name)}
    [[ "${GRPC_SERVICE_NAME}" =~ ^[A-Za-z0-9._~-]{3,64}$ ]] || die "GRPC_SERVICE_NAME 无效"

    SINGBOX_VLESS_WS_LOOPBACK_PORT=${SINGBOX_VLESS_WS_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_WS_LOOPBACK_PORT}}
    validate_loopback_port "${SINGBOX_VLESS_WS_LOOPBACK_PORT}" || die "WebSocket 本机端口无效"

    SINGBOX_VLESS_GRPC_LOOPBACK_PORT=${SINGBOX_VLESS_GRPC_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_GRPC_LOOPBACK_PORT}}
    validate_loopback_port "${SINGBOX_VLESS_GRPC_LOOPBACK_PORT}" || die "gRPC 本机端口无效"

    [[ "${SINGBOX_VLESS_WS_LOOPBACK_PORT}" != "${SINGBOX_VLESS_GRPC_LOOPBACK_PORT}" ]] \
        || die "WebSocket 与 gRPC 本机端口不能冲突"

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
        SINGBOX_VLESS_WS_LOOPBACK_PORT SINGBOX_VLESS_GRPC_LOOPBACK_PORT
        WEBSOCKET_PATH GRPC_SERVICE_NAME
        ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    [[ -f "${state_path}" ]] || return 1
    for variable in "${variables[@]}"; do
        env_name=$(env -i bash -c 'source "$1" && printf "%s" "${'"${variable}"':-}"' _ "${state_path}")
        printf -v "${variable}" '%s' "${env_name}"
    done
    [[ "${PROTOCOL}" == "singbox-cf" || ("${CDN_PROVIDER:-}" == "cloudflare" && "${BACKEND:-}" == "singbox") ]] \
        || die "状态不是 Cloudflare Sing-box"
    configure_cdn_client_ip_family
    validate_domain "${CLOUDFLARE_ORIGIN_DOMAIN:-}" && validate_domain "${VLESS_CDN_DOMAIN:-}" \
        && validate_uuid "${VLESS_UUID:-}" || die "Cloudflare 状态缺少有效域名或 UUID"
    WEBSOCKET_PATH=${WEBSOCKET_PATH:-/ws-$(openssl rand -hex 12)}
    [[ "${WEBSOCKET_PATH}" =~ ^/[A-Za-z0-9._~/-]{3,128}$ ]] || die "状态中的 WEBSOCKET_PATH 无效"
    GRPC_SERVICE_NAME=${GRPC_SERVICE_NAME:-$(generate_grpc_service_name)}
    [[ "${GRPC_SERVICE_NAME}" =~ ^[A-Za-z0-9._~-]{3,64}$ ]] || die "状态中的 GRPC_SERVICE_NAME 无效"
    SINGBOX_VLESS_WS_LOOPBACK_PORT=${SINGBOX_VLESS_WS_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_WS_LOOPBACK_PORT}}
    SINGBOX_VLESS_GRPC_LOOPBACK_PORT=${SINGBOX_VLESS_GRPC_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_GRPC_LOOPBACK_PORT}}
    validate_loopback_port "${SINGBOX_VLESS_WS_LOOPBACK_PORT}" || die "状态中的 WebSocket 端口无效"
    validate_loopback_port "${SINGBOX_VLESS_GRPC_LOOPBACK_PORT}" || die "状态中的 gRPC 端口无效"
    [[ "${SINGBOX_VLESS_WS_LOOPBACK_PORT}" != "${SINGBOX_VLESS_GRPC_LOOPBACK_PORT}" ]] || die "端口冲突"
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
    BACKEND="singbox"
    PROTOCOL="singbox-cf"
    CDN_PROVIDER="cloudflare"
}

save_state() {
    local target="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local state_dir="$(dirname "${target}")"
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
            SINGBOX_VLESS_WS_LOOPBACK_PORT SINGBOX_VLESS_GRPC_LOOPBACK_PORT \
            WEBSOCKET_PATH GRPC_SERVICE_NAME ORIGIN_HEADER_SECRET ALLOWED_TOKENS \
            SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR; do
            case "${v}" in
            STATE_VERSION) printf '%s=%q\n' "${v}" "${STATE_SCHEMA_VERSION}" ;;
            PROTOCOL) printf '%s=%q\n' "${v}" "singbox-cf" ;;
            BACKEND) printf '%s=%q\n' "${v}" "singbox" ;;
            CDN_PROVIDER) printf '%s=%q\n' "${v}" "cloudflare" ;;
            SUBSCRIPTION_DOMAIN) printf '%s=%q\n' "${v}" "$(subscription_link_domain)" ;;
            *) printf '%s=%q\n' "${v}" "${!v:-}" ;;
            esac
        done
    } >"${t}"
    install -m 0600 "${t}" "${target}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Cloudflare CDN Sing-box 尚未安装"
    load_state
}

singbox_render_config() {
    install -d -m 0755 "${SINGBOX_DIR}"
    jq -n \
        --argjson ws_port "${SINGBOX_VLESS_WS_LOOPBACK_PORT}" \
        --argjson grpc_port "${SINGBOX_VLESS_GRPC_LOOPBACK_PORT}" \
        --arg vless_uuid "${VLESS_UUID}" \
        --arg ws_path "${WEBSOCKET_PATH}" \
        --arg grpc_service "${GRPC_SERVICE_NAME}" '
    {
      log: { level: "warn" },
      inbounds: [
        {
          type: "vless",
          tag: "vless-ws-in",
          listen: "127.0.0.1",
          listen_port: $ws_port,
          users: [{ name: "vless-ws-user", uuid: $vless_uuid }],
          transport: {
            type: "ws",
            path: $ws_path,
            max_early_data: 2048,
            early_data_header_name: "Sec-WebSocket-Protocol"
          },
          multiplex: {
            enabled: true,
            padding: false
          }
        },
        {
          type: "vless",
          tag: "vless-grpc-in",
          listen: "127.0.0.1",
          listen_port: $grpc_port,
          users: [{ name: "vless-grpc-user", uuid: $vless_uuid }],
          transport: {
            type: "grpc",
            service_name: $grpc_service
          },
          multiplex: {
            enabled: true,
            padding: false
          }
        }
      ],
      outbounds: [
        { type: "direct", tag: "direct" }
      ],
      route: {
        rules: [
          { ip_is_private: true, action: "reject" },
          { network: "udp", port: [443], action: "reject" }
        ],
        auto_detect_interface: true
      }
    }
    ' >"${RUNTIME_TMP}/singbox-config.json"
    if [[ -x "${SINGBOX_BIN}" ]]; then
        "${SINGBOX_BIN}" check -c "${RUNTIME_TMP}/singbox-config.json" >/dev/null 2>&1 || true
    fi
    install -m 0600 "${RUNTIME_TMP}/singbox-config.json" "${SINGBOX_CONFIG}"
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
server {
    listen 80;
    listen [::]:80;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    location / { return 301 https://${XHTTP_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl ${listen_h2}backlog=4096;
    listen [::]:443 ssl ${listen_h2}backlog=4096;${http2_directive}
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
    location = ${WEBSOCKET_PATH} {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host ${VLESS_CDN_DOMAIN};
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_buffering off;
        proxy_connect_timeout 5s;
        proxy_read_timeout 1h;
        proxy_send_timeout 1h;
        proxy_pass http://127.0.0.1:${SINGBOX_VLESS_WS_LOOPBACK_PORT};
        access_log off;
    }

    location ^~ /${GRPC_SERVICE_NAME}/ {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_set_header Host ${VLESS_CDN_DOMAIN};
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_pass grpc://127.0.0.1:${SINGBOX_VLESS_GRPC_LOOPBACK_PORT};
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

cloudflare_add_singbox_header_rule() {
    local ruleset=$1 host=$2 ws_path=$3 grpc_service=$4 ref
    ref=$(cloudflare_ref "header:${host}:${ws_path}:${grpc_service}")
    local expr
    expr="http.host eq \"${host}\" and (starts_with(http.request.uri.path, \"${ws_path}\") or starts_with(http.request.uri.path, \"/${grpc_service}\") or starts_with(http.request.uri.path, \"/easy_all-health\") or starts_with(http.request.uri.path, \"/subscribe\"))"
    cloudflare_upsert_rule "${ruleset}" "${ref}" \
        "$(jq -cn --arg ref "${ref}" --arg expr "${expr}" --arg key "${ORIGIN_HEADER_SECRET}" \
            '{ref:$ref,description:"easy_all singbox origin header",expression:$expr,action:"rewrite",action_parameters:{headers:{"X-Easy-All-Origin-Key":{operation:"set",value:$key}}}}')"
}

cloudflare_configure_rules() {
    local host transform strict ref
    host=${VLESS_CDN_DOMAIN}
    transform=$(cloudflare_managed_ruleset "easy_all singbox headers ${host}" "http_request_late_transform")
    cloudflare_add_singbox_header_rule "${transform}" "${host}" "${WEBSOCKET_PATH}" "${GRPC_SERVICE_NAME}"
    if subscription_enabled \
        && [[ "$(active_subscription_link_domain)" != "${VLESS_CDN_DOMAIN}" ]]; then
        cloudflare_add_header_rule "${transform}" \
            "$(active_subscription_link_domain)" "/subscribe" ""
    fi
    strict=$(cloudflare_managed_ruleset "easy_all singbox strict ${host}" "http_config_settings")
    while IFS= read -r host; do
        ref=$(cloudflare_ref "strict:${host}")
        cloudflare_upsert_rule "${strict}" "${ref}" \
            "$(jq -cn --arg ref "${ref}" --arg host "${host}" \
                '{ref:$ref,description:"easy_all singbox strict origin TLS",expression:("http.host eq \""+$host+"\""),action:"set_config",action_parameters:{ssl:"strict",security_level:"essentially_off",bic:false}}')"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')
    CLOUDFLARE_HEADER_RULESET_ID=${transform}
    CLOUDFLARE_STRICT_RULESET_ID=${strict}
}

stop_services() {
    systemctl stop "${SINGBOX_SERVICE}" nginx 2>/dev/null || true
}

validate_protocol_runtime() {
    local attempt response
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${SINGBOX_SERVICE}" \
            && systemctl is-active --quiet nginx \
            && ss -H -ltn "sport = :443" 2>/dev/null | grep -q .; then
            response=$(curl -fsS \
                --resolve "${XHTTP_ORIGIN_DOMAIN}:443:127.0.0.1" \
                -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" \
                "https://${XHTTP_ORIGIN_DOMAIN}/easy_all-health" || true)
            if [[ "${response}" == "easy_all ok" ]]; then
                return 0
            fi
        fi
        sleep 2
    done
    die "VLESS Sing-box 本机运行时验收失败"
}

finish_singbox_apply() {
    local sync_cloud=${1:-0}
    write_certificate
    singbox_render_config
    write_nginx_config
    if ! systemctl is-active --quiet "${SINGBOX_SERVICE}"; then
        install_singbox_service
    else
        systemctl reload-or-restart "${SINGBOX_SERVICE}" || systemctl restart "${SINGBOX_SERVICE}" || die "重启 Sing-box 失败"
    fi
    validate_protocol_runtime
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    else
        cleanup_disabled_subscription_runtime
    fi
    save_state
    ((sync_cloud == 1)) || return 0
}

build_vless_ws_link() {
    local server=$1 node_name=$2
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&alpn=http%%2F1.1&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${WEBSOCKET_PATH}")" "$(uri_encode "${node_name}")"
}

build_vless_grpc_link() {
    local server=$1 node_name=$2
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=grpc&serviceName=%s&sni=%s&fp=chrome&alpn=h2&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${GRPC_SERVICE_NAME}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${node_name}")"
}

build_mihomo_ws_node() {
    local server=$1 node_name=$2
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

build_mihomo_grpc_node() {
    local server=$1 node_name=$2
    resolve_cdn_client_ip_family
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg service "${GRPC_SERVICE_NAME}" --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: grpc\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: \($ip_version)\n    alpn:\n      - h2\n" +
        "    grpc-opts:\n      grpc-service-name: \($service|@json)\n"'
}

# Strictly filter out any fallback lines: only valid carrier IP candidates are yielded.
# 3 carriers x 3 IPs = 9 IPs (which will produce exactly 18 nodes, no domain fallback).
cloudflare_singbox_client_candidates() {
    if declare -F cloudflare_client_candidates >/dev/null 2>&1; then
        local ip label carrier
        while IFS=$'\t' read -r ip label carrier; do
            [[ -n "${ip}" ]] || continue
            [[ "${carrier}" == "fallback" ]] && continue
            printf '%s\t%s\t%s\n' "${ip}" "${label}" "${carrier}"
        done < <(cloudflare_client_candidates)
    fi
}

build_node_links() {
    local ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        build_vless_ws_link "${ip}" "${label}_WS"
        printf '\n'
        build_vless_grpc_link "${ip}" "${label}_GRPC"
        printf '\n'
    done < <(cloudflare_singbox_client_candidates)
}

build_mihomo_nodes() {
    local ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_ws_node "${ip}" "${label}_WS"
        build_mihomo_grpc_node "${ip}" "${label}_GRPC"
    done < <(cloudflare_singbox_client_candidates)
}

build_mihomo_proxy_names() {
    printf '        - "AUTO"\n'
    local telecom_count=0 unicom_count=0 mobile_count=0
    local ip label carrier
    local -a all_nodes=()
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        all_nodes+=("${label}_WS" "${label}_GRPC")
        case "${carrier}" in
            telecom) telecom_count=$((telecom_count + 1)) ;;
            unicom)  unicom_count=$((unicom_count + 1)) ;;
            mobile)  mobile_count=$((mobile_count + 1)) ;;
        esac
    done < <(cloudflare_singbox_client_candidates)

    ((telecom_count > 0)) && printf '        - "电信优选"\n'
    ((unicom_count > 0))  && printf '        - "联通优选"\n'
    ((mobile_count > 0))  && printf '        - "移动优选"\n'
    local node
    for node in "${all_nodes[@]}"; do
        printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
    done
}

build_mihomo_proxy_groups() {
    local -a all_nodes=() telecom_nodes=() unicom_nodes=() mobile_nodes=()
    local ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        local n_ws="${label}_WS" n_grpc="${label}_GRPC"
        all_nodes+=("${n_ws}" "${n_grpc}")
        case "${carrier}" in
            telecom) telecom_nodes+=("${n_ws}" "${n_grpc}") ;;
            unicom)  unicom_nodes+=("${n_ws}" "${n_grpc}") ;;
            mobile)  mobile_nodes+=("${n_ws}" "${n_grpc}") ;;
        esac
    done < <(cloudflare_singbox_client_candidates)

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
    local c_name
    for c_name in "电信优选" "联通优选" "移动优选"; do
        local -a c_nodes=()
        case "${c_name}" in
            电信优选) c_nodes=("${telecom_nodes[@]}") ;;
            联通优选) c_nodes=("${unicom_nodes[@]}") ;;
            移动优选) c_nodes=("${mobile_nodes[@]}") ;;
        esac
        if ((${#c_nodes[@]} > 0)); then
            printf '    - name: %s\n' "$(jq -Rn --arg value "${c_name}" '$value')"
            printf '      type: url-test\n'
            printf '      proxies:\n'
            for node in "${c_nodes[@]}"; do
                printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
            done
            cat <<EOF
      url: https://cp.cloudflare.com/generate_204
      interval: 300
      tolerance: 50
      timeout: 3000
      lazy: true
EOF
        fi
    done
}

build_singbox_subscription_json() {
    local host=${VLESS_CDN_DOMAIN}
    local -a all_nodes=() telecom_nodes=() unicom_nodes=() mobile_nodes=()
    local ip label carrier
    local outbounds_json="[]"

    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        local n_ws="${label}_WS" n_grpc="${label}_GRPC"
        all_nodes+=("${n_ws}" "${n_grpc}")
        case "${carrier}" in
            telecom) telecom_nodes+=("${n_ws}" "${n_grpc}") ;;
            unicom)  unicom_nodes+=("${n_ws}" "${n_grpc}") ;;
            mobile)  mobile_nodes+=("${n_ws}" "${n_grpc}") ;;
        esac
        # Add WS outbound
        outbounds_json=$(jq -c \
            --arg tag "${n_ws}" --arg server "${ip}" --arg host "${host}" \
            --arg uuid "${VLESS_UUID}" --arg path "${WEBSOCKET_PATH}" \
            '. + [{
              type: "vless",
              tag: $tag,
              server: $server,
              server_port: 443,
              uuid: $uuid,
              tls: {
                enabled: true,
                server_name: $host,
                utls: { enabled: true, fingerprint: "chrome" },
                alpn: ["http/1.1"]
              },
              transport: {
                type: "ws",
                path: $path,
                headers: { Host: $host }
              },
              packet_encoding: "xudp"
            }]' <<<"${outbounds_json}")
        # Add gRPC outbound
        outbounds_json=$(jq -c \
            --arg tag "${n_grpc}" --arg server "${ip}" --arg host "${host}" \
            --arg uuid "${VLESS_UUID}" --arg service "${GRPC_SERVICE_NAME}" \
            '. + [{
              type: "vless",
              tag: $tag,
              server: $server,
              server_port: 443,
              uuid: $uuid,
              tls: {
                enabled: true,
                server_name: $host,
                utls: { enabled: true, fingerprint: "chrome" },
                alpn: ["h2"]
              },
              transport: {
                type: "grpc",
                service_name: $service
              },
              packet_encoding: "xudp"
            }]' <<<"${outbounds_json}")
    done < <(cloudflare_singbox_client_candidates)

    local -a selector_tags=()
    selector_tags+=("AUTO")
    ((${#telecom_nodes[@]} > 0)) && selector_tags+=("电信优选")
    ((${#unicom_nodes[@]} > 0))  && selector_tags+=("联通优选")
    ((${#mobile_nodes[@]} > 0))  && selector_tags+=("移动优选")
    for n in "${all_nodes[@]}"; do
        selector_tags+=("${n}")
    done

    jq -n \
        --argjson selector_tags "$(printf '%s\n' "${selector_tags[@]}" | jq -R . | jq -s .)" \
        --argjson all_nodes "$(printf '%s\n' "${all_nodes[@]}" | jq -R . | jq -s .)" \
        --argjson telecom_nodes "$(printf '%s\n' "${telecom_nodes[@]}" | jq -R . | jq -s .)" \
        --argjson unicom_nodes "$(printf '%s\n' "${unicom_nodes[@]}" | jq -R . | jq -s .)" \
        --argjson mobile_nodes "$(printf '%s\n' "${mobile_nodes[@]}" | jq -R . | jq -s .)" \
        --argjson node_outbounds "${outbounds_json}" '
    {
      log: { level: "warn" },
      dns: {
        reverse_mapping: true,
        servers: [
          { tag: "fakeip", type: "fakeip", inet4_range: "198.18.0.0/15" },
          { tag: "local", type: "udp", server: "223.5.5.5", server_port: 53 },
          { tag: "remote", type: "https", server: "1.1.1.1", detour: "PROXY" }
        ],
        rules: [
          { clash_mode: "Direct", action: "route", server: "local" },
          { clash_mode: "Global", action: "route", server: "fakeip" },
          {
            domain_suffix: [
              "wechat.com", "weixin.com", "qq.com", "qpic.cn", "qlogo.cn",
              "tencent.com", "servicewechat.com", "tenpay.com", "wechatpay.cn", "gtimg.com"
            ],
            action: "route",
            server: "local"
          },
          { rule_set: "geosite-cn", action: "route", server: "local" },
          { rule_set: ["geosite-category-ai", "geosite-geolocation-!cn"], action: "route", server: "fakeip" }
        ],
        final: "local",
        strategy: "prefer_ipv4"
      },
      experimental: {
        cache_file: { enabled: true, store_fakeip: true }
      },
      http_clients: [
        { tag: "proxy-client", detour: "PROXY" }
      ],
      inbounds: [
        { type: "mixed", tag: "mixed-in", listen: "127.0.0.1", listen_port: 2080 },
        {
          type: "tun",
          tag: "tun-in",
          address: ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
          auto_route: true,
          strict_route: false,
          stack: "mixed",
          endpoint_independent_nat: true
        }
      ],
      outbounds: (
        [
          { type: "selector", tag: "PROXY", outbounds: $selector_tags },
          {
            type: "urltest",
            tag: "AUTO",
            outbounds: $all_nodes,
            url: "https://cp.cloudflare.com/generate_204",
            interval: "5m",
            tolerance: 50,
            idle_timeout: "30m"
          }
        ] +
        (if ($telecom_nodes | length) > 0 then [{
          type: "urltest",
          tag: "电信优选",
          outbounds: $telecom_nodes,
          url: "https://cp.cloudflare.com/generate_204",
          interval: "5m",
          tolerance: 50,
          idle_timeout: "30m"
        }] else [] end) +
        (if ($unicom_nodes | length) > 0 then [{
          type: "urltest",
          tag: "联通优选",
          outbounds: $unicom_nodes,
          url: "https://cp.cloudflare.com/generate_204",
          interval: "5m",
          tolerance: 50,
          idle_timeout: "30m"
        }] else [] end) +
        (if ($mobile_nodes | length) > 0 then [{
          type: "urltest",
          tag: "移动优选",
          outbounds: $mobile_nodes,
          url: "https://cp.cloudflare.com/generate_204",
          interval: "5m",
          tolerance: 50,
          idle_timeout: "30m"
        }] else [] end) +
        $node_outbounds +
        [{ type: "direct", tag: "direct" }]
      ),
      route: {
        default_domain_resolver: "local",
        default_http_client: "proxy-client",
        rules: [
          { action: "sniff" },
          { protocol: "dns", action: "hijack-dns" },
          { clash_mode: "Direct", action: "route", outbound: "direct" },
          { clash_mode: "Global", action: "route", outbound: "PROXY" },
          {
            domain_suffix: [
              "wechat.com", "weixin.com", "qq.com", "qpic.cn", "qlogo.cn",
              "tencent.com", "servicewechat.com", "tenpay.com", "wechatpay.cn", "gtimg.com"
            ],
            action: "route",
            outbound: "direct"
          },
          { ip_is_private: true, action: "route", outbound: "direct" },
          { rule_set: ["geoip-cn", "geosite-cn"], action: "route", outbound: "direct" },
          { network: "udp", port: [443], action: "reject" },
          { rule_set: ["geosite-category-ai", "geosite-geolocation-!cn"], action: "route", outbound: "PROXY" }
        ],
        rule_set: [
          {
            tag: "geosite-category-ai",
            type: "remote",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-category-ai-chat-!cn.srs",
            http_client: "proxy-client"
          },
          {
            tag: "geosite-geolocation-!cn",
            type: "remote",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-geolocation-!cn.srs",
            http_client: "proxy-client"
          },
          {
            tag: "geosite-cn",
            type: "remote",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
            http_client: "proxy-client"
          },
          {
            tag: "geoip-cn",
            type: "remote",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
            http_client: "proxy-client"
          }
        ],
        final: "PROXY",
        auto_detect_interface: true
      }
    }
    '
}

write_subscriptions() {
    local template node_file group_file name_file base64_file mihomo_file singbox_file
    prepare_mihomo_template
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
    base64_file="${RUNTIME_TMP}/subscription-base64.txt"
    mihomo_file="${RUNTIME_TMP}/subscription-mihomo.yaml"
    singbox_file="${RUNTIME_TMP}/subscription-singbox.json"

    build_mihomo_nodes >"${node_file}"
    build_mihomo_proxy_groups >"${group_file}"
    build_mihomo_proxy_names >"${name_file}"
    build_node_links | openssl base64 -A >"${base64_file}"
    printf '\n' >>"${base64_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}" \
        "${XHTTP_NODE_NAME}" "${CDN_CLIENT_IP_FAMILY_RESOLVED:-ipv4}" \
        "${group_file}" "${name_file}"
    build_singbox_subscription_json >"${singbox_file}"

    grep -Fq 'network: ws' "${mihomo_file}" || die "Mihomo 订阅缺少 WS 节点"
    grep -Fq 'network: grpc' "${mihomo_file}" || die "Mihomo 订阅缺少 gRPC 节点"

    rm -rf -- "${SUBSCRIPTION_DIR}"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
    install -o root -g www-data -m 0640 "${singbox_file}" "${SUBSCRIPTION_SINGBOX_FILE:-${SUBSCRIPTION_DIR}/singbox.json}"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS WebSocket + gRPC over Cloudflare CDN（Sing-box 后端，三网精选 18 节点）\n节点链接:\n%s\n\n' "$(build_node_links)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_nodes
}

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: VLESS WS + gRPC（Cloudflare CDN Sing-box 双链路）\n后端: Sing-box (%s)\n客户端 CDN 节点域名: %s\nCloudflare 回源域名: %s（单域名架构）\nOrigin CA: %s（到期 %s）\n候选来源: Cloudflare 官方 IPv4 CIDR / 三网 Globalping eyeball 探针\n域名兜底: disabled (三网独立精选 18 节点，无域名兜底)\n' \
        "$(singbox_installed_version)" "${VLESS_CDN_DOMAIN}" "${CLOUDFLARE_ORIGIN_DOMAIN}" "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}"
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
        printf '通用订阅 (%s): https://%s/subscribe?token=%s\n' \
            "${user}" "${subscription_domain}" "${token}"
        printf 'Mihomo (%s):  https://%s/subscribe?token=%s&flag=clash\n' \
            "${user}" "${subscription_domain}" "${token}"
        printf 'Sing-box (%s):https://%s/subscribe?token=%s&flag=singbox\n' \
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
    cloudflare_validate_grpc_edge "${VLESS_CDN_DOMAIN}"
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
    info "检测到当前已安装模式 2（Cloudflare XHTTP + WebSocket）。"
    info "正在执行就地平滑迁移至模式 5（保留全部 Cloudflare 云端资产、Origin CA 与 VLESS 凭据，切换本地后端为 Sing-box 双链路）..."
    load_state

    VLESS_UUID="${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}"
    WEBSOCKET_PATH="${WEBSOCKET_PATH:-/ws-$(openssl rand -hex 12)}"
    GRPC_SERVICE_NAME="${GRPC_SERVICE_NAME:-$(generate_grpc_service_name)}"
    SINGBOX_VLESS_WS_LOOPBACK_PORT="${DEFAULT_SINGBOX_VLESS_WS_LOOPBACK_PORT}"
    SINGBOX_VLESS_GRPC_LOOPBACK_PORT="${DEFAULT_SINGBOX_VLESS_GRPC_LOOPBACK_PORT}"
    ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-$(generate_secret)}"
    XHTTP_ORIGIN_DOMAIN="${VLESS_CDN_DOMAIN}"
    BACKEND="singbox"
    PROTOCOL="singbox-cf"
    CDN_PROVIDER="cloudflare"

    info "[1/6] 下载 Sing-box 核心并生成 VLESS WS + gRPC 双链路配置"
    download_singbox
    singbox_render_config
    install_singbox_service

    info "[2/6] 停止并停用 Xray 服务与配额定时器"
    systemctl stop easy_all-xray.service >/dev/null 2>&1 || true
    systemctl disable easy_all-xray.service >/dev/null 2>&1 || true
    remove_quota_timer >/dev/null 2>&1 || true

    info "[3/6] 同步 Cloudflare 边缘规则与 gRPC 支持"
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn

    info "[4/6] 更新 Nginx 反代配置并重载"
    write_nginx_config
    validate_protocol_runtime

    info "[5/6] 刷新三网精选 IP 并生成新格式订阅（18 节点无域名兜底）"
    refresh_cloudflare_cdn_ips

    info "[6/6] 保存状态并更新 easy_all 命令注册"
    save_state
    register_easy_all_command

    show_node
    if subscription_enabled; then
        show_subscription
    fi
    success "已成功就地平滑迁移至 Sing-box（VLESS-WS + VLESS-gRPC 双链路，三网精选 18 节点）！"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="cloudflare"
    BACKEND="singbox"
    PROTOCOL="singbox-cf"
    require_root
    require_systemd

    if can_in_place_migrate_from_xhttp_cloudflare; then
        local migrate_ans=""
        read_bilingual \
            "检测到当前已安装模式 2（Cloudflare XHTTP + WebSocket）。是否直接就地无缝迁移至模式 5（保留全部 Cloudflare 云资源与 VLESS 凭据，切换本地后端为 Sing-box 双链路）？[Y/n]:" \
            "Detected existing Mode 2 (Cloudflare XHTTP + WebSocket). Migrate in-place to Mode 5 (preserve all Cloudflare cloud resources & VLESS creds, switch backend to Sing-box)? [Y/n]:" migrate_ans
        if [[ -z "${migrate_ans}" || "${migrate_ans}" =~ ^[Yy]$ ]]; then
            migrate_from_xhttp_cloudflare
            return 0
        fi
    fi

    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    require_fresh_environment
    acquire_runtime_write_lock
    record_initial_environment
    collect_install_inputs
    info "正在配置 XanMod LTS BBRv3、TCP 优化与日常重启..."
    configure_bbr_tcp
    configure_daily_reboot
    install_system_dependencies
    download_singbox
    cloudflare_configure_origin_firewall
    xhttp_configure_ufw
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 1
    cloudflare_configure_cdn
    finish_singbox_apply 1
    cloudflare_validate_cdn_health
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    register_easy_all_command
    refresh_cloudflare_cdn_ips
    cloudflare_clear_api_token
    INSTALL_ROLLBACK_ON_EXIT=0
    release_runtime_write_lock
    success "easy_all Cloudflare CDN Sing-box 安装完成"
    show_node
    if subscription_enabled; then
        show_subscription
    fi
}

apply_easy_all() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    finish_singbox_apply
    install_globalping_refresh_timer
    success "Cloudflare Sing-box 本机配置已应用；未修改 Cloudflare 资源"
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
    finish_singbox_apply 1
    cloudflare_validate_cdn_health
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
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
    finish_singbox_apply 1
    cloudflare_validate_cdn_health
    cloudflare_cleanup_previous_subscription_host "${previous_subscription_host}"
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
    success "Cloudflare 订阅、Origin CA 与回源规则已更新"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all Cloudflare Sing-box 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        read_bilingual \
            '确认删除 easy_all Cloudflare CDN Sing-box 本机服务、状态和证书？默认保留远端 Cloudflare 资源。[y/N]（直接回车取消）:' \
            'Delete easy_all Cloudflare CDN Sing-box local services, state and certificates? Cloudflare resources are kept by default. [y/N] (press Enter to cancel):' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_services
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_preinstall_firewall
    if [[ "${mode}" == "--purge-cloud" ]]; then
        cloudflare_collect_api_token
        cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
            "$(cloudflare_ref "header:${VLESS_CDN_DOMAIN}:${WEBSOCKET_PATH}:${GRPC_SERVICE_NAME}")"
        cloudflare_purge_managed_rule "${CLOUDFLARE_STRICT_RULESET_ID:-}" \
            "$(cloudflare_ref "strict:${VLESS_CDN_DOMAIN}")"
        if subscription_enabled && [[ "${SUBSCRIPTION_DOMAIN}" != "${VLESS_CDN_DOMAIN}" ]]; then
            cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
                "$(cloudflare_ref "header:${SUBSCRIPTION_DOMAIN}:/subscribe")"
            cloudflare_purge_managed_rule "${CLOUDFLARE_STRICT_RULESET_ID:-}" \
                "$(cloudflare_ref "strict:${SUBSCRIPTION_DOMAIN}")"
            cloudflare_delete_proxied_a "${SUBSCRIPTION_DOMAIN}"
        fi
        cloudflare_delete_proxied_a "${VLESS_CDN_DOMAIN}"
        cloudflare_clear_api_token
    fi
    rm -f -- "${SINGBOX_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${SINGBOX_DIR}"
    success "easy_all Cloudflare CDN Sing-box 已卸载"
}
