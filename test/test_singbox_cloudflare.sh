#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/singbox-cloudflare.sh"
CORE_LIB="${ROOT_DIR}/lib/singbox-core.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected <${expected}> but got <${actual}>"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing ${expected}"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: contains unexpected ${unexpected}"
}

# 1. Syntax check
bash -n "${PROFILE}" "${CORE_LIB}"

# 2. Source modules in isolated environment
export STATE_DIR="${TMP_DIR}/state"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export SINGBOX_DIR_OVERRIDE="${TMP_DIR}/singbox"
export SINGBOX_BIN_OVERRIDE="${TMP_DIR}/singbox/sing-box"
export SINGBOX_CONFIG_OVERRIDE="${TMP_DIR}/singbox/config.json"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/cert.pem"
export KEY_FILE="${CERT_DIR}/key.pem"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
export SUBSCRIPTION_SINGBOX_FILE="${SUBSCRIPTION_DIR}/singbox.json"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export STATE_FILE="${STATE_DIR}/state.env"
export VLESS_CDN_DOMAIN="node.example.com"
export CLOUDFLARE_ORIGIN_DOMAIN="node.example.com"
export XHTTP_ORIGIN_DOMAIN="node.example.com"
export VLESS_UUID="11111111-2222-4111-8111-111111111111"
export WEBSOCKET_PATH="/ws-test-path"
export GRPC_SERVICE_NAME="grpc-test-service"
export SINGBOX_VLESS_WS_LOOPBACK_PORT=10087
export SINGBOX_VLESS_GRPC_LOOPBACK_PORT=10086
export ORIGIN_HEADER_SECRET="test-origin-secret-12345678"
export ALLOWED_TOKENS='{"owner":"test-token-12345"}'
export SUB_DOWNLOAD_NAME="TEST_SUB"
export SUBSCRIPTION_MODE="deploy"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"
export CLOUDFLARE_ZONE_ID="test-zone-id"
export CLOUDFLARE_ZONE_NAME="example.com"
export CLOUDFLARE_ORIGIN_CERT_ID="test-origin-cert-id"
export CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2035-01-01T00:00:00Z"
export GLOBALPING_CACHE_FILE_OVERRIDE="${STATE_DIR}/cloudflare-cdn-ips.json"
export CDN_CLIENT_IP_FAMILY="ipv4"
export XHTTP_NODE_NAME="TEST_NODE"

mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" "${TMP_DIR}/singbox"
touch "${CERT_FILE}" "${KEY_FILE}"

install() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
        esac
    done
    local target="${args[${#args[@]}-1]}"
    if [[ "${target}" == /etc/easy_all/* || "${target}" == "/etc/easy_all" ]]; then
        target="${TMP_DIR}/state${target#/etc/easy_all}"
        args[${#args[@]}-1]="${target}"
    elif [[ "${target}" == "/etc/nginx/conf.d/easy_all.conf" ]]; then
        target="${TMP_DIR}/nginx.conf"
        args[${#args[@]}-1]="${target}"
    elif [[ "${target}" == /var/www/easy_all/* || "${target}" == "/var/www/easy_all" ]]; then
        target="${TMP_DIR}/web${target#/var/www/easy_all}"
        args[${#args[@]}-1]="${target}"
    fi
    if [[ " ${args[*]} " == *" -d "* ]]; then
        mkdir -p "${target}"
    elif [[ -n "${target}" ]]; then
        mkdir -p "$(dirname "${target}")"
    fi
    command install "${args[@]}"
}

rm() {
    local args=()
    for arg in "$@"; do
        if [[ "${arg}" == /var/www/easy_all/* || "${arg}" == "/var/www/easy_all" ]]; then
            args+=("${TMP_DIR}/web${arg#/var/www/easy_all}")
        else
            args+=("${arg}")
        fi
    done
    command rm "${args[@]}"
}

# shellcheck source=profiles/singbox-cloudflare.sh
source "${PROFILE}"

# 3. Test singbox_render_config
singbox_render_config
singbox_conf=$(<"${SINGBOX_CONFIG}")

assert_contains "singbox config has warning log level" "${singbox_conf}" '"level": "warn"'
assert_contains "singbox config contains vless-ws-in" "${singbox_conf}" '"tag": "vless-ws-in"'
assert_contains "singbox config contains vless-grpc-in" "${singbox_conf}" '"tag": "vless-grpc-in"'
assert_contains "singbox config ws port" "${singbox_conf}" '"listen_port": 10087'
assert_contains "singbox config grpc port" "${singbox_conf}" '"listen_port": 10086'
assert_contains "singbox config ws path" "${singbox_conf}" '"path": "/ws-test-path"'
assert_contains "singbox config grpc service name" "${singbox_conf}" '"service_name": "grpc-test-service"'
assert_contains "singbox config uuid" "${singbox_conf}" '"uuid": "11111111-2222-4111-8111-111111111111"'
assert_contains "singbox config multiplex enabled" "${singbox_conf}" '"enabled": true'
assert_contains "singbox config private ip reject" "${singbox_conf}" '"ip_is_private": true'
assert_contains "singbox config udp 443 reject" "${singbox_conf}" '"port": ['

# 4. Test write_nginx_config
nginx() { :; }
systemctl() { :; }
write_nginx_config
nginx_conf=$(<"${TMP_DIR}/nginx.conf")

assert_contains "nginx config contains domain" "${nginx_conf}" "server_name node.example.com;"
assert_contains "nginx config contains ws location" "${nginx_conf}" "location = /ws-test-path"
assert_contains "nginx config contains ws proxy_pass" "${nginx_conf}" "proxy_pass http://127.0.0.1:10087;"
assert_contains "nginx config contains grpc location" "${nginx_conf}" "location ^~ /grpc-test-service/ {"
assert_contains "nginx config contains grpc_pass" "${nginx_conf}" "grpc_pass grpc://127.0.0.1:10086;"
assert_contains "nginx config checks origin key" "${nginx_conf}" 'if ($http_x_easy_all_origin_key != "test-origin-secret-12345678") { return 404; }'
assert_contains "nginx config has health endpoint" "${nginx_conf}" "location = /easy_all-health"

# 5. Test 18 nodes output across 3 carriers with no domain fallback
# Set up mock Globalping cache with 9 candidates (3 telecom, 3 unicom, 3 mobile)
cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{
  "updated_at": 1725500000,
  "candidates": [
    {"ip": "104.16.1.1", "label": "电信01", "carrier": "telecom"},
    {"ip": "104.16.1.2", "label": "电信02", "carrier": "telecom"},
    {"ip": "104.16.1.3", "label": "电信03", "carrier": "telecom"},
    {"ip": "104.16.2.1", "label": "联通01", "carrier": "unicom"},
    {"ip": "104.16.2.2", "label": "联通02", "carrier": "unicom"},
    {"ip": "104.16.2.3", "label": "联通03", "carrier": "unicom"},
    {"ip": "104.16.3.1", "label": "移动01", "carrier": "mobile"},
    {"ip": "104.16.3.2", "label": "移动02", "carrier": "mobile"},
    {"ip": "104.16.3.3", "label": "移动03", "carrier": "mobile"}
  ]
}
EOF

# Mock validation functions
cdn_optimization_enabled() { return 0; }
globalping_cache_valid() { return 0; }
cloudflare_validate_grpc_edge() { return 0; }

candidates_output=$(cloudflare_singbox_client_candidates)
assert_equal "Candidates count is exactly 9" "9" "$(wc -l <<<"${candidates_output}" | tr -d ' ')"

# Test node links: exactly 18 links (9 WS + 9 gRPC)
node_links=$(build_node_links)
link_count=$(grep -c '^vless://' <<<"${node_links}")
assert_equal "Total node links is exactly 18" "18" "${link_count}"

ws_link_count=$(grep -c 'type=ws' <<<"${node_links}")
assert_equal "WS node links count is 9" "9" "${ws_link_count}"

grpc_link_count=$(grep -c 'type=grpc' <<<"${node_links}")
assert_equal "gRPC node links count is 9" "9" "${grpc_link_count}"

# Verify NO domain fallback link
assert_not_contains "Node links do not contain domain as server" "${node_links}" "@node.example.com:443"

# Verify carrier nodes in links
assert_contains "Links contain Telecom01 WS" "${node_links}" "#%E7%94%B5%E4%BF%A101_WS"
assert_contains "Links contain Telecom01 GRPC" "${node_links}" "#%E7%94%B5%E4%BF%A101_GRPC"
assert_contains "Links contain Unicom01 WS" "${node_links}" "#%E8%81%94%E9%80%9A01_WS"
assert_contains "Links contain Unicom01 GRPC" "${node_links}" "#%E8%81%94%E9%80%9A01_GRPC"
assert_contains "Links contain Mobile01 WS" "${node_links}" "#%E7%A7%BB%E5%8A%A801_WS"
assert_contains "Links contain Mobile01 GRPC" "${node_links}" "#%E7%A7%BB%E5%8A%A801_GRPC"

# Test Mihomo nodes: exactly 18 nodes
mihomo_nodes=$(build_mihomo_nodes)
node_count=$(grep -c '^[[:space:]]*- name:' <<<"${mihomo_nodes}")
assert_equal "Mihomo nodes count is exactly 18" "18" "${node_count}"

assert_contains "Mihomo renders 电信01_WS" "${mihomo_nodes}" '"电信01_WS"'
assert_contains "Mihomo renders 电信01_GRPC" "${mihomo_nodes}" '"电信01_GRPC"'
assert_contains "Mihomo renders 联通01_WS" "${mihomo_nodes}" '"联通01_WS"'
assert_contains "Mihomo renders 联通01_GRPC" "${mihomo_nodes}" '"联通01_GRPC"'
assert_contains "Mihomo renders 移动01_WS" "${mihomo_nodes}" '"移动01_WS"'
assert_contains "Mihomo renders 移动01_GRPC" "${mihomo_nodes}" '"移动01_GRPC"'
assert_not_contains "Mihomo nodes do not contain domain fallback" "${mihomo_nodes}" 'server: "node.example.com"'

# Test Mihomo proxy groups
groups_output=$(build_mihomo_proxy_groups)
assert_contains "Groups contain AUTO group" "${groups_output}" 'name: "AUTO"'
assert_contains "Groups contain 电信优选 group" "${groups_output}" 'name: "电信优选"'
assert_contains "Groups contain 联通优选 group" "${groups_output}" 'name: "联通优选"'
assert_contains "Groups contain 移动优选 group" "${groups_output}" 'name: "移动优选"'
assert_contains "Groups test url" "${groups_output}" 'url: https://cp.cloudflare.com/generate_204'
assert_not_contains "Groups do not contain domain fallback" "${groups_output}" 'DOMAIN'

# Test Mihomo proxy names under PROXY
names_output=$(build_mihomo_proxy_names)
assert_contains "Names contain AUTO" "${names_output}" '"AUTO"'
assert_contains "Names contain 电信优选" "${names_output}" '"电信优选"'
assert_contains "Names contain 联通优选" "${names_output}" '"联通优选"'
assert_contains "Names contain 移动优选" "${names_output}" '"移动优选"'
assert_contains "Names contain 电信01_WS" "${names_output}" '"电信01_WS"'
assert_contains "Names contain 电信01_GRPC" "${names_output}" '"电信01_GRPC"'

# Test Sing-box client subscription JSON
singbox_sub_json=$(build_singbox_subscription_json)
sb_outbound_count=$(jq '.outbounds | length' <<<"${singbox_sub_json}")
# 1 selector (PROXY) + 4 urltests (AUTO, 电信优选, 联通优选, 移动优选) + 18 node outbounds + 1 direct = 24
assert_equal "Sing-box subscription total outbounds" "24" "${sb_outbound_count}"
sb_ws_count=$(jq '[.outbounds[] | select(.type == "vless" and .transport.type == "ws")] | length' <<<"${singbox_sub_json}")
assert_equal "Sing-box subscription WS outbounds" "9" "${sb_ws_count}"
sb_grpc_count=$(jq '[.outbounds[] | select(.type == "vless" and .transport.type == "grpc")] | length' <<<"${singbox_sub_json}")
assert_equal "Sing-box subscription gRPC outbounds" "9" "${sb_grpc_count}"

# Test write_subscriptions
validate_subscription_runtime() { :; }
write_subscriptions

sub_base64="${TMP_DIR}/web/subscriptions/base64.txt"
sub_mihomo="${TMP_DIR}/web/subscriptions/mihomo.yaml"
sub_singbox="${TMP_DIR}/web/subscriptions/singbox.json"

[[ -s "${sub_base64}" ]] || fail "Base64 subscription file is missing or empty"
[[ -s "${sub_mihomo}" ]] || fail "Mihomo subscription file is missing or empty"
[[ -s "${sub_singbox}" ]] || fail "Sing-box subscription file is missing or empty"

mihomo_file_content=$(<"${sub_mihomo}")
assert_contains "Mihomo file contains WS nodes" "${mihomo_file_content}" 'network: ws'
assert_contains "Mihomo file contains gRPC nodes" "${mihomo_file_content}" 'network: grpc'
assert_contains "Mihomo file contains AUTO group" "${mihomo_file_content}" 'name: "AUTO"'
assert_contains "Mihomo file contains 电信优选 group" "${mihomo_file_content}" 'name: "电信优选"'
assert_contains "Mihomo file contains geosite:cn in fake-ip-filter" "${mihomo_file_content}" "'geosite:cn'"
assert_contains "Mihomo file contains 10jqka in fake-ip-filter" "${mihomo_file_content}" "'+.10jqka.com.cn'"

singbox_file_content=$(<"${sub_singbox}")
assert_contains "Sing-box subscription excludes 10jqka in dns" "${singbox_file_content}" '10jqka.com.cn'
assert_contains "Sing-box subscription has geosite-cn dns rule" "${singbox_file_content}" 'geosite-cn'

base64_decoded=$(openssl base64 -d -A <"${sub_base64}")
decoded_links=$(grep -c '^vless://' <<<"${base64_decoded}")
assert_equal "Decoded base64 contains exactly 18 links" "18" "${decoded_links}"

# 6. Test state save and load
actual_state_file="${TMP_DIR}/state/state.env"
EASY_ALL_STATE_FILE_OVERRIDE="${actual_state_file}" save_state
[[ -f "${actual_state_file}" ]] || fail "state file was not created"
state_content=$(<"${actual_state_file}")
assert_contains "State has PROTOCOL=singbox-cf" "${state_content}" "PROTOCOL=singbox-cf"
assert_contains "State has BACKEND=singbox" "${state_content}" "BACKEND=singbox"
assert_contains "State has CDN_PROVIDER=cloudflare" "${state_content}" "CDN_PROVIDER=cloudflare"
assert_contains "State has WS port" "${state_content}" "SINGBOX_VLESS_WS_LOOPBACK_PORT=10087"
assert_contains "State has gRPC port" "${state_content}" "SINGBOX_VLESS_GRPC_LOOPBACK_PORT=10086"

# Test load_state
PROTOCOL="" BACKEND="" CDN_PROVIDER=""
EASY_ALL_STATE_FILE_OVERRIDE="${actual_state_file}" load_state
assert_equal "load_state loads PROTOCOL" "singbox-cf" "${PROTOCOL}"
assert_equal "load_state loads BACKEND" "singbox" "${BACKEND}"
assert_equal "load_state loads CDN_PROVIDER" "cloudflare" "${CDN_PROVIDER}"

# 7. Test in-place migration check
legacy_state="${TMP_DIR}/legacy.env"
cat >"${legacy_state}" <<EOF
STATE_VERSION='7'
PROTOCOL='xhttp'
CDN_PROVIDER='cloudflare'
BACKEND='xray'
EOF
assert_equal "Can migrate from xhttp-cloudflare" "0" \
    "$(EASY_ALL_STATE_FILE_OVERRIDE="${legacy_state}" can_in_place_migrate_from_xhttp_cloudflare && echo 0 || echo 1)"

assert_equal "Cannot migrate from already singbox" "1" \
    "$(EASY_ALL_STATE_FILE_OVERRIDE="${STATE_FILE}" can_in_place_migrate_from_xhttp_cloudflare && echo 0 || echo 1)"

# 8. Test transport marker and validate_protocol_runtime CA handling
assert_equal "mihomo_transport_marker outputs network: ws" "network: ws" "$(mihomo_transport_marker)"

(
    systemctl() { return 0; }
    ss() { printf 'LISTEN 0 512 127.0.0.1:443\n'; }
    xhttp_validate_local_tls_curl_args() {
        XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https' --cacert "/etc/easy_all/cloudflare-origin-ca-ecc.pem")
    }
    curl() {
        printf '%s\n' "$*" >"${TMP_DIR}/captured_curl"
        printf 'easy_all ok\n'
    }
    validate_protocol_runtime
    captured_curl=$(<"${TMP_DIR}/captured_curl")
    assert_contains "validate_protocol_runtime passes --cacert to curl" "${captured_curl}" "--cacert /etc/easy_all/cloudflare-origin-ca-ecc.pem"
    assert_contains "validate_protocol_runtime passes Origin Key header" "${captured_curl}" "X-Easy-All-Origin-Key"
)

# 9. Test install_all execution flow with mocks (verifying all symbols resolve cleanly)
install_out=$(
    require_root() { :; }
    require_systemd() { :; }
    check_platform() { :; }
    check_install_conflicts() { :; }
    snapshot_fresh_install() { :; }
    install_packages() { :; }
    ensure_ssh_boot_service() { :; }
    configure_bbr_tcp() { :; }
    configure_daily_reboot() { :; }
    collect_install_inputs() {
        PROTOCOL="singbox-cf"
        BACKEND="singbox"
        CDN_PROVIDER="cloudflare"
        VLESS_UUID="11111111-2222-3333-4444-555555555555"
        VLESS_CDN_DOMAIN="cdn.example.com"
        CLOUDFLARE_ORIGIN_DOMAIN="cdn.example.com"
        XHTTP_ORIGIN_DOMAIN="cdn.example.com"
        WEBSOCKET_PATH="/ws-test"
        GRPC_SERVICE_NAME="grpc-test"
        SINGBOX_VLESS_WS_LOOPBACK_PORT="10087"
        SINGBOX_VLESS_GRPC_LOOPBACK_PORT="10086"
        ORIGIN_HEADER_SECRET="test-secret-12345678"
        SUBSCRIPTION_MODE="link"
        SUBSCRIPTION_DOMAIN="cdn.example.com"
        SUB_DOWNLOAD_NAME="TEST_SUB"
        ALLOWED_TOKENS=""
    }
    cloudflare_prepare_origin() { :; }
    configure_ufw() { :; }
    write_bootstrap_nginx_config() { :; }
    cloudflare_issue_origin_certificate() { :; }
    download_singbox() { :; }
    singbox_render_config() { :; }
    install_singbox_service() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cloudflare_configure_cdn() { :; }
    cloudflare_validate_cdn_health() { :; }
    cloudflare_finalize_certificate_rotation() { :; }
    persist_globalping_token() { :; }
    refresh_globalping_cache() { :; }
    write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    save_state() { :; }
    register_easy_all_command() { :; }
    install_quota_timer() { :; }
    install_globalping_refresh_timer() { :; }
    cloudflare_clear_api_token() { :; }
    show_subscription() { :; }
    show_bbrv3_status() { :; }
    prompt_bbrv3_reboot() { :; }

    rm -f -- "${STATE_FILE}"
    FORCE_INTERACTIVE=1 install_all
    printf '\nINSTALL_ALL_FINISHED_SUCCESSFULLY\n'
)
assert_contains "install_all pipeline runs to completion without unresolved symbols" "${install_out}" "INSTALL_ALL_FINISHED_SUCCESSFULLY"

# 10. Test apply_easy_all, apply_cloud_resources, update_subscription reset UPDATE_SUB_ROLLBACK_ON_EXIT
(
    require_root() { :; }
    collect_installed_state() { :; }
    configure_bbr_tcp() { :; }
    configure_ufw() { :; }
    finish_singbox_apply() { :; }
    install_globalping_refresh_timer() { :; }
    show_subscription() { :; }
    cloudflare_prepare_origin() { :; }
    cloudflare_issue_origin_certificate() { :; }
    cloudflare_configure_cdn() { :; }
    cloudflare_validate_cdn_health() { :; }
    cloudflare_finalize_certificate_rotation() { :; }
    cloudflare_clear_api_token() { :; }
    choose_subscription_mode() { :; }
    collect_subscription_link_domain() { :; }
    choose_subscription_download_name() { :; }
    choose_monthly_quota() { :; }
    ensure_allowed_tokens() { :; }
    cloudflare_cleanup_previous_subscription_host() { :; }

    apply_easy_all
    assert_equal "apply_easy_all leaves UPDATE_SUB_ROLLBACK_ON_EXIT=0" "0" "${UPDATE_SUB_ROLLBACK_ON_EXIT}"

    apply_cloud_resources
    assert_equal "apply_cloud_resources leaves UPDATE_SUB_ROLLBACK_ON_EXIT=0" "0" "${UPDATE_SUB_ROLLBACK_ON_EXIT}"

    update_subscription
    assert_equal "update_subscription leaves UPDATE_SUB_ROLLBACK_ON_EXIT=0" "0" "${UPDATE_SUB_ROLLBACK_ON_EXIT}"
)

printf 'ok - singbox cloudflare profile tests passed\n'

