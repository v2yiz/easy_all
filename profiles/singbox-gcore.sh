#!/usr/bin/env bash

# Gcore CDN Sing-box (Trojan + VLESS WebSocket) profile.
#
# This Profile provides a Sing-box backend over Gcore CDN, running both
# Trojan + WebSocket and VLESS + WebSocket on local loopback ports behind
# Nginx with Gcore mTLS origin protection.
# It also provides in-place seamless migration from xhttp-gcore.sh.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'singbox-gcore.sh 是 easy_all 的 Gcore Sing-box Profile；请使用：easy_all install\n' >&2
    exit 2
fi

SINGBOX_PROFILE_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
if ! declare -F gcore_apply_cdn >/dev/null; then
    # shellcheck source=profiles/xhttp-gcore.sh
    source "${SINGBOX_PROFILE_DIR}/xhttp-gcore.sh"
fi
# shellcheck source=lib/singbox-core.sh
source "${SINGBOX_PROFILE_DIR}/../lib/singbox-core.sh"

DEFAULT_SINGBOX_TROJAN_LOOPBACK_PORT="10088"
DEFAULT_SINGBOX_VLESS_LOOPBACK_PORT="10087"

SINGBOX_TROJAN_LOOPBACK_PORT="${SINGBOX_TROJAN_LOOPBACK_PORT:-${DEFAULT_SINGBOX_TROJAN_LOOPBACK_PORT}}"
SINGBOX_VLESS_LOOPBACK_PORT="${SINGBOX_VLESS_LOOPBACK_PORT:-${DEFAULT_SINGBOX_VLESS_LOOPBACK_PORT}}"
TROJAN_PASSWORD="${TROJAN_PASSWORD:-}"
TROJAN_PATH="${TROJAN_PATH:-}"
ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-}"
XHTTP_ORIGIN_DOMAIN="${XHTTP_ORIGIN_DOMAIN:-${GCORE_ORIGIN_DOMAIN:-}}"

generate_trojan_path() {
    printf '/trojan-%s' "$(openssl rand -hex 12)"
}

generate_trojan_password() {
    generate_secret
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

load_state() {
    local variable env_name state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local -a variables=(
        PROTOCOL BACKEND CDN_PROVIDER
        CDN_CLIENT_IP_FAMILY XHTTP_NODE_NAME VLESS_UUID
        TROJAN_PASSWORD TROJAN_PATH
        VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN WEBSOCKET_PATH
        GCORE_ORIGIN_DOMAIN GCORE_DNS_ZONE GCORE_SUBSCRIPTION_DNS_ZONE
        GCORE_ORIGIN_GROUP_ID GCORE_CDN_RESOURCE_ID
        GCORE_SSL_CERT_ID GCORE_ORIGIN_CA_ID GCORE_ORIGIN_CLIENT_CERT_ID
        GCORE_CDN_TARGET GCORE_ORIGIN_ISSUER_SHA256 CDN_TRAFFIC_PROTECTION_GB
        VPS_PUBLIC_IPV4 GCORE_ORIGIN_A_OWNED GCORE_CDN_CNAME_OWNED
        GCORE_SUBSCRIPTION_CNAME_OWNED
        SINGBOX_TROJAN_LOOPBACK_PORT SINGBOX_VLESS_LOOPBACK_PORT
        ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    [[ -f "${state_path}" ]] || return 1
    for variable in "${variables[@]}"; do
        env_name=$(env -i bash -c 'source "$1" && printf "%s" "${'"${variable}"':-}"' _ "${state_path}")
        printf -v "${variable}" '%s' "${env_name}"
    done
    XHTTP_ORIGIN_DOMAIN="${GCORE_ORIGIN_DOMAIN}"
}

mihomo_transport_marker() {
    printf 'network: ws'
}

can_in_place_migrate_from_xhttp_gcore() {
    local state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    [[ -f "${state_path}" ]] || return 1
    local cdn backend proto
    cdn=$(read_state_field "${state_path}" CDN_PROVIDER || true)
    backend=$(read_state_field "${state_path}" BACKEND || true)
    proto=$(read_state_field "${state_path}" PROTOCOL || true)
    [[ "${cdn}" == "gcore" && "${backend}" != "singbox" && ("${proto}" == "xhttp" || "${proto}" == "ws") ]]
}

singbox_trojan_node_name() {
    printf '%s_TROJAN_WS' "$(gcore_base_node_name)"
}

singbox_vless_node_name() {
    printf '%s_VLESS_WS' "$(gcore_base_node_name)"
}

singbox_auto_group_name() {
    printf '%s_AUTO' "$(gcore_base_node_name)"
}

build_trojan_websocket_link() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-$(singbox_trojan_node_name)}
    printf 'trojan://%s@%s:443?security=tls&type=ws&sni=%s&host=%s&path=%s#%s' \
        "$(uri_encode "${TROJAN_PASSWORD}")" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${TROJAN_PATH}")" "$(uri_encode "${node_name}")"
}

build_vless_websocket_link() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-$(singbox_vless_node_name)}
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&alpn=http%%2F1.1&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${WEBSOCKET_PATH}")" "$(uri_encode "${node_name}")"
}

build_node_links() {
    local endpoint
    while IFS= read -r endpoint; do
        build_trojan_websocket_link "${endpoint}" "$(singbox_trojan_node_name)"
        printf '\n'
        build_vless_websocket_link "${endpoint}" "$(singbox_vless_node_name)"
        printf '\n'
    done < <(xhttp_client_endpoints)
}

build_mihomo_trojan_node() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-$(singbox_trojan_node_name)}
    resolve_cdn_client_ip_family
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${VLESS_CDN_DOMAIN}" --arg password "${TROJAN_PASSWORD}" \
        --arg path "${TROJAN_PATH}" --arg ip_version "${CDN_CLIENT_IP_FAMILY_RESOLVED}" '
        "  - name: \($name|@json)\n    type: trojan\n    server: \($server|@json)\n    port: 443\n" +
        "    password: \($password|@json)\n    network: ws\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    ip-version: \($ip_version)\n    alpn:\n      - http/1.1\n" +
        "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($host|@json)\n"'
}

build_mihomo_websocket_node() {
    local server=${1:-${VLESS_CDN_DOMAIN}} node_name=${2:-$(singbox_vless_node_name)}
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
        build_mihomo_trojan_node "${endpoint}" "$(singbox_trojan_node_name)"
        build_mihomo_websocket_node "${endpoint}" "$(singbox_vless_node_name)"
    done < <(xhttp_client_endpoints)
}

build_mihomo_proxy_names() {
    printf '        - %s\n' \
        "$(jq -Rn --arg value "$(singbox_auto_group_name)" '$value')"
    printf '        - %s\n' \
        "$(jq -Rn --arg value "$(singbox_trojan_node_name)" '$value')"
    printf '        - %s\n' \
        "$(jq -Rn --arg value "$(singbox_vless_node_name)" '$value')"
}

build_mihomo_proxy_groups() {
    printf '    - name: %s\n' \
        "$(jq -Rn --arg value "$(singbox_auto_group_name)" '$value')"
    cat <<EOF
      type: url-test
      proxies:
        - $(jq -Rn --arg value "$(singbox_trojan_node_name)" '$value')
        - $(jq -Rn --arg value "$(singbox_vless_node_name)" '$value')
      url: https://www.gstatic.com/generate_204
      interval: 600
      tolerance: 50
      timeout: 3000
      lazy: true
EOF
}

build_singbox_subscription_json() {
    local trojan_name vless_name auto_name host
    trojan_name=$(singbox_trojan_node_name)
    vless_name=$(singbox_vless_node_name)
    auto_name=$(singbox_auto_group_name)
    host=${VLESS_CDN_DOMAIN}

    jq -n \
        --arg trojan_name "${trojan_name}" \
        --arg vless_name "${vless_name}" \
        --arg auto_name "${auto_name}" \
        --arg host "${host}" \
        --arg trojan_pw "${TROJAN_PASSWORD}" \
        --arg trojan_path "${TROJAN_PATH}" \
        --arg vless_uuid "${VLESS_UUID}" \
        --arg vless_path "${WEBSOCKET_PATH}" '
    {
      log: { level: "warn" },
      dns: {
        servers: [
          { tag: "remote", address: "https://1.1.1.1/dns-query", detour: "PROXY" },
          { tag: "local", address: "https://223.5.5.5/dns-query", detour: "direct" },
          { tag: "block", address: "rcode://success" }
        ],
        rules: [
          { outbound: "any", server: "local" },
          { clash_mode: "Direct", server: "local" },
          { clash_mode: "Global", server: "remote" },
          { rule_set: "geosite-cn", server: "local" }
        ],
        strategy: "prefer_ipv4"
      },
      inbounds: [
        {
          type: "mixed",
          tag: "mixed-in",
          listen: "127.0.0.1",
          listen_port: 2080
        },
        {
          type: "tun",
          tag: "tun-in",
          inet4_address: "172.19.0.1/30",
          auto_route: true,
          strict_route: false,
          stack: "mixed",
          sniff: true
        }
      ],
      outbounds: [
        {
          type: "selector",
          tag: "PROXY",
          outbounds: [$auto_name, $trojan_name, $vless_name]
        },
        {
          type: "urltest",
          tag: $auto_name,
          outbounds: [$trojan_name, $vless_name],
          url: "https://www.gstatic.com/generate_204",
          interval: "10m",
          tolerance: 50
        },
        {
          type: "trojan",
          tag: $trojan_name,
          server: $host,
          server_port: 443,
          password: $trojan_pw,
          tls: {
            enabled: true,
            server_name: $host,
            utls: { enabled: true, fingerprint: "chrome" },
            alpn: ["http/1.1"]
          },
          transport: {
            type: "ws",
            path: $trojan_path,
            headers: { Host: $host }
          }
        },
        {
          type: "vless",
          tag: $vless_name,
          server: $host,
          server_port: 443,
          uuid: $vless_uuid,
          tls: {
            enabled: true,
            server_name: $host,
            utls: { enabled: true, fingerprint: "chrome" },
            alpn: ["http/1.1"]
          },
          transport: {
            type: "ws",
            path: $vless_path,
            headers: { Host: $host }
          },
          packet_encoding: "xudp"
        },
        { type: "direct", tag: "direct" },
        { type: "block", tag: "block" },
        { type: "dns", tag: "dns-out" }
      ],
      route: {
        rules: [
          { protocol: "dns", outbound: "dns-out" },
          { clash_mode: "Direct", outbound: "direct" },
          { clash_mode: "Global", outbound: "PROXY" },
          { ip_is_private: true, outbound: "direct" },
          { rule_set: ["geoip-cn", "geosite-cn"], outbound: "direct" }
        ],
        rule_set: [
          {
            tag: "geosite-cn",
            type: "remote",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-cn.srs",
            download_detour: "direct"
          },
          {
            tag: "geoip-cn",
            type: "remote",
            format: "binary",
            url: "https://raw.githubusercontent.com/SagerNet/sing-geoip/rule-set/geoip-cn.srs",
            download_detour: "direct"
          }
        ],
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
        "$(gcore_base_node_name)" "${CDN_CLIENT_IP_FAMILY_RESOLVED:-ipv4}" \
        "${group_file}" "${name_file}"
    build_singbox_subscription_json >"${singbox_file}"

    grep -Fq 'type: trojan' "${mihomo_file}" || die "Mihomo 订阅缺少 Trojan 节点"
    grep -Fq 'type: vless' "${mihomo_file}" || die "Mihomo 订阅缺少 VLESS 节点"
    jq -e '.outbounds[] | select(.type == "trojan")' "${singbox_file}" >/dev/null \
        || die "Sing-box 订阅缺少 Trojan 节点"

    rm -rf -- "${SUBSCRIPTION_DIR}"
    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    install -o root -g www-data -m 0640 "${base64_file}" "${SUBSCRIPTION_BASE64_FILE}"
    install -o root -g www-data -m 0640 "${mihomo_file}" "${SUBSCRIPTION_MIHOMO_FILE}"
    install -o root -g www-data -m 0640 "${singbox_file}" "${SUBSCRIPTION_SINGBOX_FILE:-${SUBSCRIPTION_DIR}/singbox.json}"
}

singbox_render_config() {
    install -d -m 0755 "${SINGBOX_DIR}"
    jq -n \
        --argjson trojan_port "${SINGBOX_TROJAN_LOOPBACK_PORT}" \
        --argjson vless_port "${SINGBOX_VLESS_LOOPBACK_PORT}" \
        --arg trojan_pw "${TROJAN_PASSWORD}" \
        --arg trojan_path "${TROJAN_PATH}" \
        --arg vless_uuid "${VLESS_UUID}" \
        --arg vless_path "${WEBSOCKET_PATH}" '
    {
      log: { level: "warn" },
      inbounds: [
        {
          type: "trojan",
          tag: "trojan-ws-in",
          listen: "127.0.0.1",
          listen_port: $trojan_port,
          users: [{ name: "trojan-user", password: $trojan_pw }],
          transport: {
            type: "ws",
            path: $trojan_path,
            max_early_data: 2048,
            early_data_header_name: "Sec-WebSocket-Protocol"
          }
        },
        {
          type: "vless",
          tag: "vless-ws-in",
          listen: "127.0.0.1",
          listen_port: $vless_port,
          users: [{ name: "vless-user", uuid: $vless_uuid }],
          transport: {
            type: "ws",
            path: $vless_path,
            max_early_data: 2048,
            early_data_header_name: "Sec-WebSocket-Protocol"
          }
        }
      ],
      outbounds: [
        { type: "direct", tag: "direct" },
        { type: "block", tag: "block" }
      ],
      route: {
        rules: [
          { ip_is_private: true, outbound: "block" }
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
    gcore_prepare_origin_validation_material
    write_web_root
    {
        write_subscription_nginx_maps
        cat <<EOF
upstream gcore_trojan_backend {
    server 127.0.0.1:${SINGBOX_TROJAN_LOOPBACK_PORT};
    keepalive 32;
}

upstream gcore_vless_backend {
    server 127.0.0.1:${SINGBOX_VLESS_LOOPBACK_PORT};
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
    location = ${TROJAN_PATH} {
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
        proxy_pass http://gcore_trojan_backend;
        access_log off;
    }

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
        proxy_pass http://gcore_vless_backend;
        access_log off;
    }

    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx Sing-box Trojan + VLESS WebSocket 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

save_state() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX")
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        printf 'PROTOCOL=%q\n' "singbox-ws"
        printf 'BACKEND=%q\n' "singbox"
        printf 'CDN_PROVIDER=%q\n' "gcore"
        printf 'CDN_CLIENT_IP_FAMILY=%q\n' "${CDN_CLIENT_IP_FAMILY}"
        printf 'XHTTP_NODE_NAME=%q\n' "${XHTTP_NODE_NAME}"
        printf 'VLESS_UUID=%q\n' "${VLESS_UUID}"
        printf 'TROJAN_PASSWORD=%q\n' "${TROJAN_PASSWORD}"
        printf 'VLESS_CDN_DOMAIN=%q\n' "${VLESS_CDN_DOMAIN}"
        printf 'SUBSCRIPTION_DOMAIN=%q\n' "$(subscription_link_domain)"
        printf 'TROJAN_PATH=%q\n' "${TROJAN_PATH}"
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
        printf 'SINGBOX_TROJAN_LOOPBACK_PORT=%q\n' "${SINGBOX_TROJAN_LOOPBACK_PORT}"
        printf 'SINGBOX_VLESS_LOOPBACK_PORT=%q\n' "${SINGBOX_VLESS_LOOPBACK_PORT}"
        printf 'ORIGIN_HEADER_SECRET=%q\n' "${ORIGIN_HEADER_SECRET:-}"
        printf 'ALLOWED_TOKENS=%q\n' "${ALLOWED_TOKENS:-}"
        printf 'SUB_DOWNLOAD_NAME=%q\n' "${SUB_DOWNLOAD_NAME}"
        printf 'SUBSCRIPTION_MODE=%q\n' "${SUBSCRIPTION_MODE:-deploy}"
        printf 'SCHEDULED_REBOOT_ENABLED=%q\n' "${SCHEDULED_REBOOT_ENABLED:-0}"
        printf 'SCHEDULED_REBOOT_HOUR=%q\n' "${SCHEDULED_REBOOT_HOUR:-}"
    } >"${temp}"
    install -m 0600 "${temp}" "${STATE_FILE}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Gcore Sing-box 尚未安装"
    load_state
}

show_node() {
    collect_installed_state
    printf '\n协议: Trojan + VLESS WebSocket over Gcore CDN（Sing-box 后端）\n节点链接:\n%s\n\n' "$(build_node_links)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_nodes
    printf '\n'
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

show_status() {
    require_root
    collect_installed_state
    resolve_cdn_client_ip_family
    printf '协议: Trojan + VLESS WebSocket（Gcore CDN / Sing-box 后端）\n源站域名: %s\nCDN 域名: %s\n订阅链接域名: %s\nGcore 目标: %s\nTrojan 路径: %s\nVLESS 路径: %s\n' \
        "${GCORE_ORIGIN_DOMAIN}" "${VLESS_CDN_DOMAIN}" "$(subscription_link_domain)" \
        "${GCORE_CDN_TARGET}" "${TROJAN_PATH}" "${WEBSOCKET_PATH}"
    show_bbrv3_status
    printf 'CDN 客户端节点族: %s（配置值）\n' "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
    printf 'Gcore CDN 客户端接入: CDN 域名\n'
    printf 'Gcore DNS Zone: %s\nGcore 订阅 DNS Zone: %s\n源组 ID: %s\nCDN 资源 ID: %s\n边缘证书 ID: %s\n' \
        "${GCORE_DNS_ZONE}" "${GCORE_SUBSCRIPTION_DNS_ZONE}" \
        "${GCORE_ORIGIN_GROUP_ID}" "${GCORE_CDN_RESOURCE_ID}" "${GCORE_SSL_CERT_ID}"
    printf 'Sing-box: '; systemctl is-active --quiet "${SINGBOX_SERVICE}" && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '; systemctl is-active --quiet nginx && printf 'active\n' || printf 'inactive\n'
    printf 'UFW: '; LC_ALL=C ufw status 2>/dev/null | sed -n 's/^Status: //p'
}

migrate_from_xhttp_gcore() {
    require_root
    info "检测到当前已安装模式 3（Gcore XHTTP + WebSocket）。"
    info "正在执行就地平滑迁移至模式 4（保留全部 Gcore 云端资产、DNS 与 VLESS 凭据，仅切换本地后端为 Sing-box）..."
    load_state

    # Inherit existing VLESS credentials and Gcore cloud material
    VLESS_UUID="${VLESS_UUID:-$(generate_user_uuid)}"
    WEBSOCKET_PATH="${WEBSOCKET_PATH:-/vless-$(openssl rand -hex 12)}"
    TROJAN_PASSWORD="${TROJAN_PASSWORD:-$(generate_secret)}"
    TROJAN_PATH="${TROJAN_PATH:-$(generate_trojan_path)}"
    SINGBOX_TROJAN_LOOPBACK_PORT="${DEFAULT_SINGBOX_TROJAN_LOOPBACK_PORT}"
    SINGBOX_VLESS_LOOPBACK_PORT="${DEFAULT_SINGBOX_VLESS_LOOPBACK_PORT}"
    ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-$(generate_secret)}"
    XHTTP_ORIGIN_DOMAIN="${GCORE_ORIGIN_DOMAIN}"
    BACKEND="singbox"
    PROTOCOL="singbox-ws"
    CDN_PROVIDER="gcore"

    info "[1/5] 安装 Sing-box 核心并生成双链路配置"
    download_singbox
    singbox_render_config
    install_singbox_service

    info "[2/5] 停止并停用 Xray 服务"
    systemctl stop easy_all-xray.service >/dev/null 2>&1 || true
    systemctl disable easy_all-xray.service >/dev/null 2>&1 || true

    info "[3/5] 更新 Nginx 反代配置并重载"
    write_nginx_config

    info "[4/5] 生成新格式订阅（Base64、Mihomo YAML、Sing-box JSON）"
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi

    info "[5/5] 保存状态并更新 easy_all 命令注册"
    save_state
    register_easy_all_command

    show_subscription
    success "已成功就地迁移至 Sing-box（Trojan + VLESS WebSocket）！"
    info "原 VLESS WebSocket 凭据与路径完全复用，老客户端仍可正常连接；同时新增了 Trojan WS 节点与 flag=singbox 订阅。"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="gcore"
    BACKEND="singbox"
    PROTOCOL="singbox-ws"
    require_root
    require_systemd

    if can_in_place_migrate_from_xhttp_gcore; then
        local migrate_ans=""
        read_bilingual \
            "检测到当前已安装模式 3（Gcore XHTTP + WebSocket）。是否直接就地无缝迁移至模式 4（保留全部 Gcore 云资源与 VLESS 凭据，仅替换本地后端为 Sing-box）？[Y/n]:" \
            "Detected existing Mode 3 (Gcore XHTTP + WebSocket). Migrate in-place to Mode 4 (preserve all Gcore cloud resources & VLESS creds, switch backend to Sing-box)? [Y/n]:" migrate_ans
        if [[ -z "${migrate_ans}" || "${migrate_ans}" =~ ^[Yy]$ ]]; then
            migrate_from_xhttp_gcore
            return 0
        fi
    fi

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
    info "[3/9] 收集 Gcore 域名、订阅与凭据参数"
    collect_install_inputs
    TROJAN_PASSWORD=$(generate_secret)
    TROJAN_PATH=$(generate_trojan_path)
    alert "源站域名与 CDN 域名必须位于同一个已完整委派到 Gcore Managed DNS 的主域名；独立订阅域名也必须由 Gcore Managed DNS 托管。"
    info "[4/9] 验证 Gcore 权限与 DNS 委派，并创建源站 A 记录"
    gcore_prepare_origin
    info "[5/9] 配置防火墙与 HTTP-01 入口"
    configure_ufw
    write_bootstrap_nginx_config
    info "[6/9] 申请源站证书并安装 Sing-box"
    issue_origin_certificate
    download_singbox
    singbox_render_config
    install_singbox_service
    write_nginx_config
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
    INSTALL_ROLLBACK_ON_EXIT=0
    gcore_clear_api_token
    info "[9/9] 输出节点与订阅"
    show_subscription
    show_bbrv3_status
    success "easy_all Gcore CDN Sing-box 安装完成"
}

apply_easy_all() {
    require_root
    collect_installed_state
    validate_gcore_origin_issuer_synced
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    singbox_render_config
    systemctl restart "${SINGBOX_SERVICE}" || die "重启 Sing-box 服务失败"
    write_nginx_config
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi
    success "easy_all Gcore Sing-box 本机配置与订阅已应用；未修改 Gcore 资源"
}

update_subscription() {
    local previous_mode previous_domain previous_active_domain new_active_domain cloud_update=0
    local previous_subscription_zone previous_ssl_cert_id
    require_root
    collect_installed_state
    previous_mode=${SUBSCRIPTION_MODE}
    previous_domain=$(subscription_link_domain)
    previous_active_domain=${VLESS_CDN_DOMAIN}
    [[ "${previous_mode}" != "deploy" ]] || previous_active_domain=${previous_domain}
    previous_subscription_zone=${GCORE_SUBSCRIPTION_DNS_ZONE:-}
    previous_ssl_cert_id=${GCORE_SSL_CERT_ID:-}
    snapshot_subscription_update
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    validate_cdn_client_ip_family_runtime
    if subscription_enabled; then
        collect_subscription_link_domain
        choose_subscription_download_name
        ensure_allowed_tokens
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
    fi
    new_active_domain=$(active_subscription_link_domain)
    [[ "${new_active_domain}" == "${previous_active_domain}" ]] || cloud_update=1
    if subscription_enabled; then
        write_subscriptions
    else
        remove_subscriptions
    fi
    save_state
    write_nginx_config
    subscription_enabled && validate_subscription_runtime
    if [[ "${cloud_update}" == "1" ]]; then
        info "订阅域名发生变化，正在同步 Gcore CDN、边缘证书与 Managed DNS"
        gcore_collect_api_token
        gcore_validate_dns_zones
        gcore_verify_zone_delegation "${GCORE_SUBSCRIPTION_DNS_ZONE}"
        gcore_apply_cdn
        save_state
        gcore_clear_api_token
    fi
    show_subscription
    success "Nginx 订阅已刷新"
}

apply_cloud_resources() {
    require_root
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
    configure_ufw
    gcore_prepare_origin
    gcore_apply_cdn
    singbox_render_config
    systemctl restart "${SINGBOX_SERVICE}" || die "重启 Sing-box 服务失败"
    write_nginx_config
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi
    gcore_clear_api_token
    success "easy_all Gcore CDN Sing-box 本机配置、Managed DNS、CDN 与证书已应用"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all Gcore Sing-box 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" && ! -t 0 ]]; then
        die "非交互卸载必须显式设置 FORCE=1"
    fi
    if [[ "${FORCE:-0}" != "1" ]]; then
        read_bilingual \
            '确认删除 easy_all Gcore CDN Sing-box 本机服务、状态和证书？默认保留远端 Gcore 资源。[y/N]（直接回车取消）:' \
            'Delete easy_all Gcore CDN Sing-box local services, state and certificates? Gcore resources are kept by default. [y/N] (press Enter to cancel):' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    UNINSTALL_PURGE_CLOUD=0
    [[ "${mode}" == "--purge-cloud" ]] && UNINSTALL_PURGE_CLOUD=1
    purge_gcore_resources_before_uninstall
    remove_managed_acme_cron
    systemctl disable --now "${SINGBOX_SERVICE}" >/dev/null 2>&1 || true
    systemctl stop "${SINGBOX_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now nginx >/dev/null 2>&1 || true
    systemctl stop nginx >/dev/null 2>&1 || true
    restore_preinstall_firewall
    remove_daily_reboot_schedule
    remove_managed_acme_domain "${GCORE_ORIGIN_DOMAIN:-}"
    rm -f -- "${SINGBOX_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" "${CERT_RELOAD_HOOK}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}"
    gcore_clear_api_token
    success "easy_all Gcore CDN Sing-box 本机内容已卸载；远端 Gcore 资源按卸载选项处理"
}
