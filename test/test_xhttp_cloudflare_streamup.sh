#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh"
CORE_LIB="${ROOT_DIR}/lib/xray-core.sh"
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
export XRAY_DIR="${TMP_DIR}/xray"
export XRAY_BIN="${TMP_DIR}/xray/xray"
export XRAY_CONFIG="${TMP_DIR}/xray/config.json"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/cert.pem"
export KEY_FILE="${CERT_DIR}/key.pem"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export STATE_FILE="${STATE_DIR}/state.env"
export EASY_ALL_STATE_FILE_OVERRIDE="${STATE_DIR}/state.env"
export VLESS_CDN_DOMAIN="node.example.com"
export CLOUDFLARE_ORIGIN_DOMAIN="node.example.com"
export XHTTP_ORIGIN_DOMAIN="node.example.com"
export VLESS_UUID="11111111-2222-4111-8111-111111111111"
export XHTTP_PATH="/xhttp-test-path"
export XRAY_XHTTP_LOOPBACK_PORT=10086
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
export XHTTP_NODE_NAME="TEST_NODE"

mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" "${TMP_DIR}/xray"
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

# shellcheck source=profiles/xhttp-cloudflare-streamup.sh
source "${PROFILE}"

# 3. Test xhttp_render_xray_config
xhttp_render_xray_config
xray_conf=$(<"${TMP_DIR}/state/xray/config.json")

assert_contains "xray config contains vless-xhttp-h2-in" "${xray_conf}" '"tag": "vless-xhttp-h2-in"'
assert_contains "xray config xhttp port" "${xray_conf}" '"port": 10086'
assert_contains "xray config xhttp path" "${xray_conf}" '"path": "/xhttp-test-path"'
assert_contains "xray config mode stream-up" "${xray_conf}" '"mode": "stream-up"'
assert_contains "xray config padding bytes" "${xray_conf}" '"xPaddingBytes": "100-1000"'
assert_contains "xray config keepalive server secs" "${xray_conf}" '"scStreamUpServerSecs": "20-40"'
assert_contains "xray config uuid" "${xray_conf}" '"id": "11111111-2222-4111-8111-111111111111"'
assert_not_contains "xray config does not contain websocket" "${xray_conf}" 'vless-websocket-in'
assert_not_contains "xray config does not contain trojan" "${xray_conf}" 'trojan'

# 4. Test write_nginx_config
nginx() { :; }
systemctl() { :; }
write_nginx_config
nginx_conf=$(<"${TMP_DIR}/nginx.conf")

assert_contains "nginx config contains domain" "${nginx_conf}" "server_name node.example.com;"
assert_contains "nginx config contains xhttp location" "${nginx_conf}" "location ^~ /xhttp-test-path"
assert_contains "nginx config contains xhttp grpc_pass" "${nginx_conf}" "grpc_pass grpc://127.0.0.1:10086;"
assert_contains "nginx config body size 0" "${nginx_conf}" "client_max_body_size 0;"
assert_contains "nginx config socket keepalive" "${nginx_conf}" "grpc_socket_keepalive on;"
assert_contains "nginx config checks origin key" "${nginx_conf}" 'if ($http_x_easy_all_origin_key != "test-origin-secret-12345678") { return 404; }'
assert_contains "nginx config has health endpoint" "${nginx_conf}" "location = /easy_all-health"
assert_not_contains "nginx config does not contain upstream" "${nginx_conf}" "upstream cf_xhttp_backend"
assert_not_contains "nginx config does not contain websocket location" "${nginx_conf}" "location = /ws-"
assert_not_contains "nginx config does not contain trojan location" "${nginx_conf}" "location = /tr-"

# 5. Test 6 curated nodes output with no domain fallback
# Set up mock Globalping cache with 9 candidates (3 telecom, 3 unicom, 3 mobile)
cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{
  "version": 5,
  "provider": "cloudflare",
  "domain": "node.example.com",
  "candidate_source": "cloudflare-official-ipv4-cidrs",
  "measured_at_epoch": 1725500000,
  "candidates": [
    {"ip": "104.16.1.1", "label": "电信01", "carrier": "telecom", "avg_rtt_ms": 120, "tls_verified": true},
    {"ip": "104.16.1.2", "label": "电信02", "carrier": "telecom", "avg_rtt_ms": 130, "tls_verified": true},
    {"ip": "104.16.1.3", "label": "电信03", "carrier": "telecom", "avg_rtt_ms": 140, "tls_verified": true},
    {"ip": "104.16.2.1", "label": "联通01", "carrier": "unicom", "avg_rtt_ms": 110, "tls_verified": true},
    {"ip": "104.16.2.2", "label": "联通02", "carrier": "unicom", "avg_rtt_ms": 125, "tls_verified": true},
    {"ip": "104.16.2.3", "label": "联通03", "carrier": "unicom", "avg_rtt_ms": 135, "tls_verified": true},
    {"ip": "104.16.3.1", "label": "移动01", "carrier": "mobile", "avg_rtt_ms": 115, "tls_verified": true},
    {"ip": "104.16.3.2", "label": "移动02", "carrier": "mobile", "avg_rtt_ms": 128, "tls_verified": true},
    {"ip": "104.16.3.3", "label": "移动03", "carrier": "mobile", "avg_rtt_ms": 145, "tls_verified": true}
  ]
}
EOF
cp "${GLOBALPING_CACHE_FILE}" "${TMP_DIR}/valid-cloudflare-cache.json"
jq '.version = 4' "${GLOBALPING_CACHE_FILE}" >"${TMP_DIR}/legacy-cloudflare-cache.json"
cp "${TMP_DIR}/legacy-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"
if cloudflare_globalping_cache_compatible; then
    fail "Legacy v4 cache may contain synthetic fallback IPs and must be rejected"
fi
cp "${TMP_DIR}/valid-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"

# Mock validation functions
cdn_optimization_enabled() { return 0; }

candidates_output=$(cloudflare_xhttp_streamup_client_candidates)
assert_equal "Candidates count is exactly 6" "6" "$(wc -l <<<"${candidates_output}" | tr -d ' ')"

# Test node links: exactly 6 links (6 VLESS XHTTP stream-up)
node_links=$(build_node_links)
vless_link_count=$(grep -c '^vless://' <<<"${node_links}")
assert_equal "Total VLESS node links is 6" "6" "${vless_link_count}"

# Verify all links have type=xhttp and mode=stream-up
assert_contains "Links contain type=xhttp" "${node_links}" "type=xhttp"
assert_contains "Links contain mode=stream-up" "${node_links}" "mode=stream-up"
assert_contains "Links contain alpn=h2" "${node_links}" "alpn=h2"
assert_contains "Links contain path with trailing slash" "${node_links}" "path=%2Fxhttp-test-path%2F"
assert_contains "Links contain extra parameter" "${node_links}" "extra="
assert_contains "Links contain packetEncoding" "${node_links}" "packetEncoding=xudp"

# Verify NO domain fallback link
assert_not_contains "Node links do not contain domain as server" "${node_links}" "@node.example.com:443"

# Verify XHTTP node links
assert_contains "Links contain 优选1" "${node_links}" "#$(jq -nr --arg v '优选1' '$v|@uri')"
assert_contains "Links contain 优选6" "${node_links}" "#$(jq -nr --arg v '优选6' '$v|@uri')"
assert_not_contains "Links do not contain 优选7" "${node_links}" "#$(jq -nr --arg v '优选7' '$v|@uri')"

# Test Mihomo nodes: exactly 6 nodes
mihomo_nodes=$(build_mihomo_nodes)
node_count=$(grep -c '^[[:space:]]*- name:' <<<"${mihomo_nodes}")
assert_equal "Mihomo nodes count is exactly 6" "6" "${node_count}"

assert_contains "Mihomo renders 优选1" "${mihomo_nodes}" '"优选1"'
assert_contains "Mihomo renders 优选6" "${mihomo_nodes}" '"优选6"'
assert_contains "Mihomo renders network: xhttp" "${mihomo_nodes}" "network: xhttp"
assert_contains "Mihomo renders mode: stream-up" "${mihomo_nodes}" "mode: stream-up"
assert_contains "Mihomo renders alpn h2" "${mihomo_nodes}" "- h2"
assert_contains "Mihomo renders path with trailing slash" "${mihomo_nodes}" 'path: "/xhttp-test-path/"'
assert_contains "Mihomo renders no-grpc-header false" "${mihomo_nodes}" "no-grpc-header: false"
assert_not_contains "Mihomo nodes do not contain domain fallback" "${mihomo_nodes}" 'server: "node.example.com"'

# Test Mihomo proxy groups: only AUTO group, no carrier groups
groups_output=$(build_mihomo_proxy_groups)
assert_contains "Groups contain AUTO group" "${groups_output}" 'name: "AUTO"'
assert_contains "AUTO group contains 优选1" "${groups_output}" '"优选1"'
assert_contains "AUTO group contains 优选6" "${groups_output}" '"优选6"'
assert_not_contains "Groups do not contain 电信优选 group" "${groups_output}" 'name: "电信优选"'
assert_not_contains "Groups do not contain 联通优选 group" "${groups_output}" 'name: "联通优选"'
assert_not_contains "Groups do not contain 移动优选 group" "${groups_output}" 'name: "移动优选"'
assert_contains "Groups test url" "${groups_output}" 'url: https://cp.cloudflare.com/generate_204'
assert_contains "Groups tolerance is 30" "${groups_output}" 'tolerance: 30'
assert_not_contains "Groups do not contain domain fallback" "${groups_output}" 'DOMAIN'

# Test Mihomo proxy names under PROXY
names_output=$(build_mihomo_proxy_names)
assert_contains "Names contain AUTO" "${names_output}" '"AUTO"'
assert_not_contains "Names do not contain 优选1" "${names_output}" '"优选1"'
assert_not_contains "Names do not contain 电信优选" "${names_output}" '"电信优选"'

# Test write_subscriptions: supports Universal (Base64) and Clash (Mihomo)
validate_subscription_runtime() { :; }
write_subscriptions

sub_base64="${TMP_DIR}/web/subscriptions/base64.txt"
sub_mihomo="${TMP_DIR}/web/subscriptions/mihomo.yaml"

[[ -s "${sub_base64}" ]] || fail "Base64 subscription file is missing or empty"
[[ -s "${sub_mihomo}" ]] || fail "Mihomo subscription file is missing or empty"

# Verify Base64 content decodes to 6 vless links
decoded_base64=$(openssl base64 -d -A <"${sub_base64}")
decoded_link_count=$(grep -c '^vless://' <<<"${decoded_base64}")
assert_equal "Universal Base64 decodes to 6 links" "6" "${decoded_link_count}"

# Verify Mihomo YAML content
mihomo_file_content=$(<"${sub_mihomo}")
assert_contains "Mihomo file contains XHTTP nodes" "${mihomo_file_content}" 'network: xhttp'
assert_contains "Mihomo file contains stream-up mode" "${mihomo_file_content}" 'mode: stream-up'
assert_contains "Mihomo file contains AUTO group" "${mihomo_file_content}" 'name: "AUTO"'
assert_contains "Mihomo file contains 优选1" "${mihomo_file_content}" '"优选1"'
# A stale but compatible cache remains usable while refresh is retried.
write_subscriptions
assert_contains "Expired cache still renders XHTTP nodes" "$(cat "${sub_mihomo}")" 'network: xhttp'

# Missing cache must fail instead of publishing an unverified hostname fallback.
rm -f "${GLOBALPING_CACHE_FILE}"
if (write_subscriptions) >/dev/null 2>&1; then
    fail "Missing cache must not generate a domain fallback subscription"
fi
cp "${TMP_DIR}/valid-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"

# Shared subscription rendering must preserve per-user UUIDs in quota mode.
QUOTA_ENABLED=1
QUOTA_START_DATE=2026-01-01
USER_ACCOUNTS='{"owner":{"uuid":"11111111-2222-4111-8111-111111111111","token":"owner-token-123","quota_gb":10},"friend":{"uuid":"22222222-2222-4222-8222-222222222222","token":"friend-token-123","quota_gb":20}}'
ALLOWED_TOKENS='{"owner":"owner-token-123","friend":"friend-token-123"}'
xhttp_render_xray_config
jq -e '
    .inbounds[0].settings.clients | length == 2
    and all(.[]; has("flow") | not)
' "${TMP_DIR}/state/xray/config.json" >/dev/null \
    || fail "Cloudflare quota clients must not contain a VLESS flow"
write_subscriptions
[[ -s "${TMP_DIR}/web/subscriptions/friend/base64.txt" ]] \
    || fail "Quota subscription must render a per-user Base64 file"
friend_links=$(openssl base64 -d -A <"${TMP_DIR}/web/subscriptions/friend/base64.txt")
assert_contains "Quota subscription uses the user's UUID" \
    "${friend_links}" "22222222-2222-4222-8222-222222222222"
QUOTA_ENABLED=0
USER_ACCOUNTS=""
QUOTA_START_DATE=""
ALLOWED_TOKENS='{"owner":"test-token-12345"}'

# Verify state save & load
save_state
[[ -f "${EASY_ALL_STATE_FILE_OVERRIDE}" ]] || fail "State file not created"
state_content=$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")
assert_contains "State file protocol is cloudflare-streamup" "${state_content}" 'PROTOCOL=cloudflare-streamup'
assert_contains "State file backend is xray" "${state_content}" 'BACKEND=xray'
assert_contains "State file cdn is cloudflare" "${state_content}" 'CDN_PROVIDER=cloudflare'

# Verify legacy states are rejected by load_state
legacy_singbox_state="${TMP_DIR}/state_singbox.env"
cat >"${legacy_singbox_state}" <<'EOF'
STATE_VERSION='7'
CDN_PROVIDER='cloudflare'
PROTOCOL='singbox-cf'
BACKEND='singbox'
EOF
legacy_load_err=$(
    bash -c 'source "$1"; EASY_ALL_STATE_FILE_OVERRIDE="$2" load_state' _ \
        "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" "${legacy_singbox_state}" 2>&1 || true
)
assert_contains "load_state rejects legacy singbox-cf state" "${legacy_load_err}" "状态不是 Cloudflare XHTTP Stream-up"

# Verify normalize_xhttp_path idempotency and double-prefix recovery
assert_equal "normalize_xhttp_path cleans double /xhttp- prefix" \
    "/xhttp-0123456789abcdef" "$(normalize_xhttp_path "/xhttp-/xhttp-0123456789abcdef")"
assert_equal "normalize_xhttp_path converts /vless- prefix" \
    "/xhttp-0123456789abcdef" "$(normalize_xhttp_path "/vless-0123456789abcdef")"
assert_equal "normalize_xhttp_path keeps clean /xhttp- intact" \
    "/xhttp-0123456789abcdef" "$(normalize_xhttp_path "/xhttp-0123456789abcdef")"

# Verify load_state successfully recovers from double-prefixed XHTTP_PATH in state
corrupted_state="${TMP_DIR}/state_corrupted.env"
cat >"${corrupted_state}" <<EOF
STATE_VERSION='7'
PROTOCOL='cloudflare-streamup'
BACKEND='xray'
CDN_PROVIDER='cloudflare'
CDN_CLIENT_IP_FAMILY='ipv6-prefer'
VLESS_UUID='11111111-2222-4111-8111-111111111111'
VLESS_CDN_DOMAIN='cdn.example.com'
CLOUDFLARE_ORIGIN_DOMAIN='cdn.example.com'
CLOUDFLARE_ZONE_ID='test-zone-id'
CLOUDFLARE_ZONE_NAME='example.com'
CLOUDFLARE_ORIGIN_CERT_ID='test-origin-cert-id'
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON='2035-01-01T00:00:00Z'
XRAY_XHTTP_LOOPBACK_PORT='10086'
XHTTP_PATH='/xhttp-/xhttp-0123456789abcdef'
ORIGIN_HEADER_SECRET='test-origin-secret-12345678'
SUBSCRIPTION_MODE='deploy'
EOF
EASY_ALL_STATE_FILE_OVERRIDE="${corrupted_state}" load_state
assert_equal "load_state normalizes corrupted XHTTP_PATH" \
    "/xhttp-0123456789abcdef" "${XHTTP_PATH}"
assert_equal "load_state discards legacy CDN IPv6 preference" \
    "" "${CDN_CLIENT_IP_FAMILY:-}"

# Edge validation must run a real XHTTP client path instead of posting to the
# static health endpoint.
(
    XHTTP_PATH="/xhttp-test-path"
    probe_started="${TMP_DIR}/cloudflare-probe-started"
    probe_curl_args="${TMP_DIR}/cloudflare-probe-curl-args"
    cat >"${XRAY_BIN}" <<EOF
#!/bin/sh
case " \$* " in
*" -test "*) exit 0 ;;
*) touch "${probe_started}"; exec /usr/bin/tail -f /dev/null ;;
esac
EOF
    chmod +x "${XRAY_BIN}"
    ss() {
        [[ -f "${probe_started}" ]] && printf 'LISTEN\n'
    }
    curl() {
        printf '%s\n' "$*" >"${probe_curl_args}"
        printf '\n204'
    }
    cloudflare_probe_xhttp "${VLESS_UUID}"
    jq -e '
        .outbounds[0].streamSettings.network == "xhttp"
        and .outbounds[0].streamSettings.xhttpSettings.mode == "stream-up"
        and .outbounds[0].streamSettings.xhttpSettings.path == "/xhttp-test-path/"
    ' "${RUNTIME_TMP}/cloudflare-xhttp-probe/config.json" >/dev/null \
        || fail "Cloudflare probe must use the deployed XHTTP settings"
    assert_contains "Cloudflare probe sends traffic through local SOCKS" \
        "$(<"${probe_curl_args}")" "--proxy socks5h://127.0.0.1:"
    assert_contains "Cloudflare probe validates external traffic" \
        "$(<"${probe_curl_args}")" "https://cp.cloudflare.com/generate_204"
)

# Cloudflare configuration must not expose a zone-wide prefix cleanup hook.
if declare -F cloudflare_cleanup_stale_header_rules >/dev/null 2>&1; then
    fail "Cloudflare must not scan and delete rules owned by other deployments"
fi

printf 'ok - Cloudflare pure XHTTP stream-up (Mode 2) tests passed\n'
