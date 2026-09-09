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
export CLOUDFLARE_WORKER_BUILD_FILE_OVERRIDE="${TMP_DIR}/worker.js"
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
export SUBSCRIPTION_DOMAIN="sub.example.com"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"
export CLOUDFLARE_ZONE_ID="test-zone-id"
export CLOUDFLARE_ZONE_NAME="example.com"
export CLOUDFLARE_ACCOUNT_ID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
export CLOUDFLARE_WORKER_NAME="EASYALL"
export CLOUDFLARE_WORKER_DOMAIN_ID="test-worker-domain-id"
export WORKER_SOURCE_SECRET="test-worker-source-secret-12345"
export WORKER_AGGREGATION_CONFIG='{"allowedTokens":{"owner":"config-override-token-12345"},"externalSubUrl":"https://extra.example.com/subscribe?token=extra-token","fallbackCdnNodes":[],"nodes":[{"type":"vless","security":"reality","network":"tcp","name":"Extra Reality","host":"extra.example.com","uuid":"33333333-3333-4333-8333-333333333333","sni":"www.example.com","pbk":"extra-public-key","sid":"0123456789abcdef","fp":"chrome","ipVersion":"ipv4","port":4443}]}'
export CLOUDFLARE_ORIGIN_CERT_ID="test-origin-cert-id"
export CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2035-01-01T00:00:00Z"
export GLOBALPING_CACHE_FILE_OVERRIDE="${STATE_DIR}/cloudflare-cdn-ips.json"
export XHTTP_NODE_NAME="TEST_NODE"
export CLOUDFLARE_CLIENT_IP_FAMILY="ipv4"
export GOOGLE_EGRESS_MODE="auto"
export GOOGLE_EGRESS_RESOLVED="ipv4"
export CLOUDFLARE_XHTTP_PROBE_ATTEMPTS_OVERRIDE=3
export CLOUDFLARE_XHTTP_PROBE_INTERVAL_OVERRIDE=0

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
assert_not_contains "Nginx does not expose the Worker subscription hostname" \
    "${nginx_conf}" "server_name sub.example.com;"
assert_contains "nginx config contains xhttp location" "${nginx_conf}" "location ^~ /xhttp-test-path"
assert_contains "nginx config contains xhttp grpc_pass" "${nginx_conf}" "grpc_pass grpc://127.0.0.1:10086;"
assert_contains "nginx config body size 0" "${nginx_conf}" "client_max_body_size 0;"
assert_contains "nginx config socket keepalive" "${nginx_conf}" "grpc_socket_keepalive on;"
assert_contains "nginx config checks origin key" "${nginx_conf}" 'if ($http_x_easy_all_origin_key != "test-origin-secret-12345678") { return 404; }'
assert_contains "nginx subscription source requires Worker secret" "${nginx_conf}" \
    'if ($http_x_easy_all_worker_source != "test-worker-source-secret-12345") { return 404; }'
assert_contains "nginx config has health endpoint" "${nginx_conf}" "location = /easy_all-health"
assert_not_contains "nginx config does not contain upstream" "${nginx_conf}" "upstream cf_xhttp_backend"
assert_not_contains "nginx config does not contain websocket location" "${nginx_conf}" "location = /ws-"
assert_not_contains "nginx config does not contain trojan location" "${nginx_conf}" "location = /tr-"
assert_equal "Origin CA only covers the Nginx node source hostname" \
    '["node.example.com"]' "$(cloudflare_origin_certificate_hosts)"

# Cover both the profile override and shared runtime renderer on old/new Nginx.
(
    for renderer in "${PROFILE}" "${ROOT_DIR}/lib/xhttp-runtime.sh"; do
        eval "$(awk '/^write_nginx_config\(\) \{/ {found=1} found && /^[a-z_]+\(\) \{/ && !/^write_nginx_config/ {exit} found {print}' "${renderer}")"
        for version in 1.24.0 1.25.0 1.25.1 1.26.3; do
            nginx() { [[ "${1:-}" != -v ]] || printf 'nginx version: nginx/%s\n' "${version}" >&2; }
            write_nginx_config
            config=$(<"${TMP_DIR}/nginx.conf")
            case "${version}" in
                1.24.0|1.25.0)
                    assert_contains "${renderer} ${version} legacy HTTP/2" "${config}" 'listen 443 ssl http2 '
                    assert_not_contains "${renderer} ${version} no unsupported directive" "${config}" 'http2 on;'
                    ;;
                *)
                    assert_contains "${renderer} ${version} enables HTTP/2" "${config}" 'http2 on;'
                    assert_not_contains "${renderer} ${version} no deprecated syntax" "${config}" 'listen 443 ssl http2 '
                    ;;
            esac
        done
    done
)

# 5. Test 6 curated nodes output with no domain fallback
# Set up a complete cache with 6 unique candidates (2 per carrier).
cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{
  "version": 7,
  "provider": "cloudflare",
  "domain": "node.example.com",
  "client_ip_family": "ipv4",
  "candidate_source": "cloudflare-official-ipv4-and-domain-ipv6",
  "measured_at_epoch": 1725500000,
  "packets": 10,
  "candidates": [
    {"ip": "104.16.1.1", "source_cidr": "104.16.0.0/13", "address_family": "ipv4", "label": "电信01", "carrier": "telecom", "carrier_asn": 4134, "avg_rtt_ms": 120, "tls_verified": true},
    {"ip": "104.16.1.2", "source_cidr": "104.16.0.0/13", "address_family": "ipv4", "label": "电信02", "carrier": "telecom", "carrier_asn": 4134, "avg_rtt_ms": 130, "tls_verified": true},
    {"ip": "104.16.2.1", "source_cidr": "104.16.0.0/13", "address_family": "ipv4", "label": "联通01", "carrier": "unicom", "carrier_asn": 4837, "avg_rtt_ms": 110, "tls_verified": true},
    {"ip": "104.16.2.2", "source_cidr": "104.16.0.0/13", "address_family": "ipv4", "label": "联通02", "carrier": "unicom", "carrier_asn": 4837, "avg_rtt_ms": 125, "tls_verified": true},
    {"ip": "104.16.3.1", "source_cidr": "104.16.0.0/13", "address_family": "ipv4", "label": "移动01", "carrier": "mobile", "carrier_asn": 9808, "avg_rtt_ms": 115, "tls_verified": true},
    {"ip": "104.16.3.2", "source_cidr": "104.16.0.0/13", "address_family": "ipv4", "label": "移动02", "carrier": "mobile", "carrier_asn": 9808, "avg_rtt_ms": 128, "tls_verified": true}
  ]
}
EOF
cp "${GLOBALPING_CACHE_FILE}" "${TMP_DIR}/valid-cloudflare-cache.json"
jq '.version = 6' "${GLOBALPING_CACHE_FILE}" >"${TMP_DIR}/legacy-cloudflare-cache.json"
cp "${TMP_DIR}/legacy-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"
if cloudflare_globalping_cache_compatible; then
    fail "Legacy v5 cache may contain loose-loss or synthetic-carrier entries and must be rejected"
fi
jq '(.candidates[] | select(.carrier == "mobile") | .carrier_asn) = 4134' \
    "${TMP_DIR}/valid-cloudflare-cache.json" >"${GLOBALPING_CACHE_FILE}"
if cloudflare_globalping_cache_compatible; then
    fail "Cache entries with rewritten carrier ownership must be rejected"
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

# Worker deployment source forwards the public token to the private Nginx source.
generated_worker="${CLOUDFLARE_WORKER_BUILD_FILE_OVERRIDE}"
cloudflare_build_subscription_worker
node --check "${generated_worker}"
generated_worker_content=$(<"${generated_worker}")
assert_contains "Generated Worker enables request-token forwarding" \
    "${generated_worker_content}" '"vpsCdnUseRequestToken":true'
assert_contains "Generated Worker delegates final Token validation to Nginx" \
    "${generated_worker_content}" '"delegateTokenValidation":true'
assert_contains "Generated Worker requires its dynamic source" \
    "${generated_worker_content}" '"requireDynamicCdn":true'
assert_contains "Generated Worker embeds the private source secret" \
    "${generated_worker_content}" '"sourceSecret":"test-worker-source-secret-12345"'
assert_contains "Generated Worker embeds optional extra nodes" \
    "${generated_worker_content}" '"name":"Extra Reality"'
assert_contains "Generated Worker preserves config.local externalSubUrl" \
    "${generated_worker_content}" \
    '"externalSubUrl":"https://extra.example.com/subscribe?token=extra-token"'
assert_contains "Generated Worker injects the locally generated vpsSubUrl" \
    "${generated_worker_content}" '"vpsSubUrl":"https://node.example.com/subscribe"'
assert_not_contains "Generated Worker does not embed public subscription Tokens" \
    "${generated_worker_content}" 'test-token-12345'
assert_not_contains "Generated Worker delegates rather than embedding config allowedTokens" \
    "${generated_worker_content}" 'config-override-token-12345'
assert_contains "Worker upload enables same-zone public fetch" \
    "$(<"${PROFILE}")" 'compatibility_flags:["global_fetch_strictly_public"]'
assert_contains "Worker deployment disables workers.dev and previews" \
    "$(<"${PROFILE}")" '{enabled:false,previews_enabled:false}'
assert_contains "Worker custom domain uses the account API" \
    "$(<"${PROFILE}")" '/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains'
install_input_body=$(sed -n '/^collect_install_inputs()/,/^}/p' "${PROFILE}")
install_token_line=$(grep -n 'ensure_allowed_tokens 1' <<<"${install_input_body}" | cut -d: -f1)
install_nodes_line=$(grep -n 'choose_worker_aggregation_config' <<<"${install_input_body}" | cut -d: -f1)
update_input_body=$(sed -n '/^update_subscription()/,/^}/p' "${PROFILE}")
update_token_line=$(grep -n 'ensure_allowed_tokens 1' <<<"${update_input_body}" | cut -d: -f1)
update_nodes_line=$(grep -n 'choose_worker_aggregation_config' <<<"${update_input_body}" | cut -d: -f1)
((install_token_line < install_nodes_line && update_token_line < update_nodes_line)) \
    || fail "Worker nodes prompt must run after user Token configuration"
assert_contains "Worker nodes prompt first asks whether aggregation is needed" \
    "$(<"${PROFILE}")" '是否需要进行订阅聚合？'
(
    unset CLOUDFLARE_WORKER_NAME
    choose_cloudflare_worker_name
    assert_equal "Worker name defaults to EASYALL" "EASYALL" \
        "${CLOUDFLARE_WORKER_NAME}"
)
assert_equal "Worker config normalizer keeps one Reality node" "1" \
    "$(normalize_worker_aggregation_config "${WORKER_AGGREGATION_CONFIG}" | jq '.nodes | length')"
ALLOWED_TOKENS='{"owner":"test-token-12345"}'
QUOTA_ENABLED=0
normalized_worker_config=$(normalize_worker_aggregation_config "${WORKER_AGGREGATION_CONFIG}")
apply_worker_allowed_tokens_override "${normalized_worker_config}"
assert_equal "config.local allowedTokens override installer tokens" \
    '{"owner":"config-override-token-12345"}' "${ALLOWED_TOKENS}"
if normalize_worker_aggregation_config '{"vpsSubUrl":"https://forbidden.example.com"}' \
    >/dev/null 2>&1; then
    fail "User Worker config must not accept vpsSubUrl"
fi
(
    api_calls="${TMP_DIR}/worker-domain-api-calls"
    : >"${api_calls}"
    CLOUDFLARE_WORKER_DOMAIN_ID=""
    cloudflare_api_request() {
        printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"${api_calls}"
        if [[ "$1 $2" == "GET /accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" ]]; then
            printf '[]\n'
        elif [[ "$1 $2" == GET\ /zones/${CLOUDFLARE_ZONE_ID}/dns_records* ]]; then
            printf '[]\n'
        elif [[ "$1 $2" == "PUT /accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" ]]; then
            printf '{"id":"new-worker-domain-id"}\n'
        else
            fail "Unexpected Worker domain API call: $1 $2"
        fi
    }
    cloudflare_attach_subscription_worker_domain
    assert_equal "Worker custom domain ID is persisted from API response" \
        "new-worker-domain-id" "${CLOUDFLARE_WORKER_DOMAIN_ID}"
    assert_contains "Worker custom domain binds the selected service" \
        "$(<"${api_calls}")" '"service":"EASYALL"'
)

# Dual mode keeps all IPv4 nodes and appends independently addressable IPv6 nodes.
jq '.client_ip_family = "dual"
    | .ipv6_candidate_count = 2
    | .candidates += [
        {"ip":"2606:4700::6810:101","source_cidr":"2606:4700::/32","address_family":"ipv6","label":"IPv6-1","carrier":"ipv6","carrier_asn":0,"avg_rtt_ms":95,"tls_verified":true},
        {"ip":"2606:4700::6810:102","source_cidr":"2606:4700::/32","address_family":"ipv6","label":"IPv6-2","carrier":"ipv6","carrier_asn":0,"avg_rtt_ms":98,"tls_verified":true}
      ]' "${TMP_DIR}/valid-cloudflare-cache.json" >"${GLOBALPING_CACHE_FILE}"
CLOUDFLARE_CLIENT_IP_FAMILY="dual"
dual_links=$(build_node_links)
assert_equal "Dual subscription keeps 6 IPv4 and adds 2 IPv6 links" "8" \
    "$(grep -c '^vless://' <<<"${dual_links}")"
assert_contains "IPv6 VLESS authority is bracketed" "${dual_links}" \
    '@[2606:4700::6810:101]:443'
dual_mihomo=$(build_mihomo_nodes)
assert_contains "Mihomo renders IPv6 server without URI brackets" "${dual_mihomo}" \
    'server: "2606:4700::6810:101"'
assert_contains "Mihomo pins IPv6 candidates" "${dual_mihomo}" 'ip-version: ipv6'
assert_contains "Mihomo labels IPv6 candidates separately" "${dual_mihomo}" '"优选IPv6-2"'
dual_groups=$(build_mihomo_proxy_groups)
assert_contains "AUTO group includes IPv6 candidates" "${dual_groups}" '"优选IPv6-2"'
jq '.ipv6_candidate_count = 4
    | .candidates += [
        {"ip":"2606:4700::6810:103","source_cidr":"2606:4700::/32","address_family":"ipv6","label":"IPv6-3","carrier":"ipv6","carrier_asn":0,"avg_rtt_ms":100,"tls_verified":true},
        {"ip":"2606:4700::6810:104","source_cidr":"2606:4700::/32","address_family":"ipv6","label":"IPv6-4","carrier":"ipv6","carrier_asn":0,"avg_rtt_ms":105,"tls_verified":true}
      ]' "${GLOBALPING_CACHE_FILE}" >"${TMP_DIR}/overflow-ipv6-cache.json"
cp "${TMP_DIR}/overflow-ipv6-cache.json" "${GLOBALPING_CACHE_FILE}"
if cloudflare_globalping_cache_compatible; then
    fail "Dual cache with more than 3 IPv6 candidates must be rejected"
fi
CLOUDFLARE_CLIENT_IP_FAMILY="ipv4"
cp "${TMP_DIR}/valid-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"

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
VPS_IP_FAMILY="dual"
VPS_PUBLIC_IPV6="2001:db8::10"

# Verify state save & load
save_state
[[ -f "${EASY_ALL_STATE_FILE_OVERRIDE}" ]] || fail "State file not created"
state_content=$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")
assert_contains "State file protocol is cloudflare-streamup" "${state_content}" 'PROTOCOL=cloudflare-streamup'
assert_contains "State file backend is xray" "${state_content}" 'BACKEND=xray'
assert_contains "State file cdn is cloudflare" "${state_content}" 'CDN_PROVIDER=cloudflare'
assert_contains "State file persists dual-stack mode" "${state_content}" 'VPS_IP_FAMILY=dual'
assert_contains "State file persists public IPv6" "${state_content}" 'VPS_PUBLIC_IPV6=2001:db8::10'
assert_contains "State file persists Cloudflare client family" "${state_content}" \
    'CLOUDFLARE_CLIENT_IP_FAMILY=ipv4'
assert_contains "State file persists Google egress mode" "${state_content}" \
    'GOOGLE_EGRESS_MODE=auto'
assert_contains "State file persists resolved Google family" "${state_content}" \
    'GOOGLE_EGRESS_RESOLVED=ipv4'
assert_contains "State file persists Worker name" "${state_content}" \
    'CLOUDFLARE_WORKER_NAME=EASYALL'
assert_contains "State file persists Worker domain ID" "${state_content}" \
    'CLOUDFLARE_WORKER_DOMAIN_ID=test-worker-domain-id'
assert_contains "State file persists Cloudflare Account ID" "${state_content}" \
    'CLOUDFLARE_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
assert_contains "State file persists private Worker source secret" "${state_content}" \
    'WORKER_SOURCE_SECRET=test-worker-source-secret-12345'
assert_contains "State file persists Worker aggregation config" "${state_content}" \
    'WORKER_AGGREGATION_CONFIG='

missing_policy_state="${TMP_DIR}/state_missing_policy.env"
grep -Ev '^(CLOUDFLARE_CLIENT_IP_FAMILY|GOOGLE_EGRESS_MODE|GOOGLE_EGRESS_RESOLVED)=' \
    "${EASY_ALL_STATE_FILE_OVERRIDE}" >"${missing_policy_state}"
missing_policy_err=$(
    bash -c 'source "$1"; EASY_ALL_STATE_FILE_OVERRIDE="$2" load_state' _ \
        "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" \
        "${missing_policy_state}" 2>&1 || true
)
assert_contains "load_state rejects state without the current family policy" \
    "${missing_policy_err}" "状态缺少有效的 Cloudflare 客户端入口 IP 族"

missing_worker_state="${TMP_DIR}/state_missing_worker.env"
grep -Ev '^(CLOUDFLARE_ACCOUNT_ID|CLOUDFLARE_WORKER_NAME|CLOUDFLARE_WORKER_DOMAIN_ID|WORKER_SOURCE_SECRET)=' \
    "${EASY_ALL_STATE_FILE_OVERRIDE}" >"${missing_worker_state}"
missing_worker_err=$(
    bash -c 'source "$1"; EASY_ALL_STATE_FILE_OVERRIDE="$2" load_state' _ \
        "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" \
        "${missing_worker_state}" 2>&1 || true
)
assert_contains "load_state rejects deployed subscriptions without Worker state" \
    "${missing_worker_err}" "状态缺少有效的 Cloudflare Account ID"

# Verify legacy states are rejected by load_state
legacy_singbox_state="${TMP_DIR}/state_singbox.env"
cat >"${legacy_singbox_state}" <<'EOF'
STATE_VERSION='9'
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
STATE_VERSION='9'
PROTOCOL='cloudflare-streamup'
BACKEND='xray'
CDN_PROVIDER='cloudflare'
CLOUDFLARE_CLIENT_IP_FAMILY='ipv4'
GOOGLE_EGRESS_MODE='auto'
GOOGLE_EGRESS_RESOLVED='ipv4'
CLOUDFLARE_ACCOUNT_ID='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
CLOUDFLARE_WORKER_NAME='EASYALL'
CLOUDFLARE_WORKER_DOMAIN_ID='test-worker-domain-id'
WORKER_SOURCE_SECRET='test-worker-source-secret-12345'
VLESS_UUID='11111111-2222-4111-8111-111111111111'
VLESS_CDN_DOMAIN='cdn.example.com'
SUBSCRIPTION_DOMAIN='sub.example.com'
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
assert_equal "load_state preserves Cloudflare client family" \
    "ipv4" "${CLOUDFLARE_CLIENT_IP_FAMILY}"
assert_equal "load_state preserves Google egress mode" \
    "auto" "${GOOGLE_EGRESS_MODE}"
assert_equal "load_state preserves the current detected VPS family" \
    "dual" "${VPS_IP_FAMILY}"
VPS_IP_FAMILY="ipv4"
VPS_PUBLIC_IPV6=""

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
        "$(<"${probe_curl_args}")" "https://www.gstatic.com/generate_204"
)

# The synthetic gRPC request is diagnostic only and recognizes a disabled
# dashboard setting without acting as an independent acceptance gate.
(
    curl() {
        printf '403\ttext/html'
    }
    if cloudflare_probe_grpc_edge "${VLESS_CDN_DOMAIN}"; then
        fail "Cloudflare gRPC diagnostic must reject a disabled setting"
    fi
    assert_equal "Cloudflare gRPC diagnostic reports the disabled setting" \
        "Cloudflare Zone 尚未开启 gRPC" "${CLOUDFLARE_GRPC_EDGE_ERROR}"
)

# The end-to-end probe tolerates short Cloudflare setting propagation delays.
(
    attempt_file="${TMP_DIR}/cloudflare-probe-attempts"
    printf '0\n' >"${attempt_file}"
    cloudflare_probe_xhttp() {
        local attempts
        attempts=$(( $(<"${attempt_file}") + 1 ))
        printf '%s\n' "${attempts}" >"${attempt_file}"
        if ((attempts < 3)); then
            CLOUDFLARE_XHTTP_PROBE_ERROR="transient"
            return 1
        fi
        return 0
    }
    cloudflare_probe_grpc_edge() {
        fail "A successful real XHTTP probe must not run the synthetic gRPC diagnostic"
    }
    sleep() { :; }
    cloudflare_wait_for_xhttp "${VLESS_UUID}"
    assert_equal "Cloudflare XHTTP validation retries transient failures" \
        "3" "$(<"${attempt_file}")"
)

# A synthetic 525 is attached as auxiliary evidence only after every real
# XHTTP attempt has failed.
grpc_525_err=$(
    (
        cloudflare_probe_xhttp() {
            CLOUDFLARE_XHTTP_PROBE_ERROR="curl=28,HTTP=000"
            return 1
        }
        cloudflare_probe_grpc_edge() {
            CLOUDFLARE_GRPC_EDGE_ERROR="HTTP=525,Content-Type=text/html"
            return 1
        }
        sleep() { :; }
        cloudflare_wait_for_xhttp "${VLESS_UUID}"
    ) 2>&1 || true
)
assert_contains "Cloudflare 525 is auxiliary evidence after XHTTP retries" \
    "${grpc_525_err}" "gRPC 边缘辅助诊断：HTTP=525"

# Fresh-install rollback only removes resources recorded as created by that run.
(
    rollback_calls="${TMP_DIR}/cloudflare-rollback-api-calls"
    : >"${rollback_calls}"
    printf 'new-ruleset-id\n' >"${RUNTIME_TMP}/cloudflare-created-rulesets"
    CLOUDFLARE_WORKER_CREATED=1
    CLOUDFLARE_WORKER_DOMAIN_ID="new-worker-domain-id"
    CLOUDFLARE_CREATED_RULE_REFS=$'existing-ruleset\tnew-rule-ref'
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID="new-origin-cert-id"
    CLOUDFLARE_CREATED_DNS_RECORD_ID="new-dns-record-id"
    cloudflare_delete_subscription_worker_resources() {
        printf 'worker\t%s\t%s\n' "$1" "$2" >>"${rollback_calls}"
    }
    cloudflare_delete_managed_rule() {
        printf 'rule\t%s\t%s\n' "$1" "$2" >>"${rollback_calls}"
    }
    cloudflare_api_request() {
        printf '%s\t%s\n' "$1" "$2" >>"${rollback_calls}"
        printf '{}\n'
    }
    cloudflare_rollback_fresh_install_resources
    rollback_output=$(<"${rollback_calls}")
    assert_contains "Rollback removes the newly created Worker" \
        "${rollback_output}" $'worker\tnew-worker-domain-id\tEASYALL'
    assert_contains "Rollback removes only a rule recorded during this run" \
        "${rollback_output}" $'rule\texisting-ruleset\tnew-rule-ref'
    assert_contains "Rollback removes the newly created ruleset" \
        "${rollback_output}" '/zones/test-zone-id/rulesets/new-ruleset-id'
    assert_contains "Rollback removes the newly created certificate" \
        "${rollback_output}" '/certificates/new-origin-cert-id'
    assert_contains "Rollback removes the newly created DNS record" \
        "${rollback_output}" '/dns_records/new-dns-record-id'
)

# Cloudflare configuration must not expose a zone-wide prefix cleanup hook.
if declare -F cloudflare_cleanup_stale_header_rules >/dev/null 2>&1; then
    fail "Cloudflare must not scan and delete rules owned by other deployments"
fi

printf 'ok - Cloudflare pure XHTTP stream-up (Mode 2) tests passed\n'
