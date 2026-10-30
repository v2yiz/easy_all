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
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP_DIR}/runtime-write.lock"
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
export CLOUDFLARE_WORKER_NAME="easyall"
export CLOUDFLARE_WORKER_DOMAIN_ID="test-worker-domain-id"
export WORKER_SOURCE_SECRET="test-worker-source-secret-12345"
export WORKER_AGGREGATION_CONFIG='{"allowedTokens":{"owner":"config-override-token-12345"},"externalSubUrl":"https://extra.example.com/subscribe?token=extra-token","fallbackCdnNodes":[],"nodes":[{"type":"vless","security":"reality","network":"tcp","name":"Extra Reality","host":"extra.example.com","uuid":"33333333-3333-4333-8333-333333333333","sni":"www.example.com","pbk":"extra-public-key","sid":"0123456789abcdef","fp":"chrome","ipVersion":"ipv4","port":4443}]}'
export CLOUDFLARE_ORIGIN_CERT_ID="test-origin-cert-id"
export CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2035-01-01T00:00:00Z"
export GLOBALPING_CACHE_FILE_OVERRIDE="${STATE_DIR}/cloudflare-cdn-ips.json"
export XHTTP_NODE_NAME="TEST_NODE"
export GOOGLE_EGRESS_MODE="ipv4"
export GOOGLE_EGRESS_RESOLVED="ipv4"
export CLOUDFLARE_WORKER_READY_ATTEMPTS_OVERRIDE=2
export CLOUDFLARE_WORKER_READY_INTERVAL_OVERRIDE=0
export CLOUDFLARE_WORKER_AUTH_ATTEMPTS_OVERRIDE=3
export CLOUDFLARE_XHTTP_PROBE_ATTEMPTS_OVERRIDE=3
export CLOUDFLARE_XHTTP_PROBE_INTERVAL_OVERRIDE=0

mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" "${TMP_DIR}/xray"
touch "${CERT_FILE}" "${KEY_FILE}"
mkdir -p "${TMP_DIR}/profiles"
cp -R "${ROOT_DIR}/lib" "${TMP_DIR}/lib"
sed -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${STATE_DIR}\"|" \
    -e "s|^readonly WEB_ROOT=.*|readonly WEB_ROOT=\"${WEB_ROOT}\"|" \
    -e "s|^readonly NGINX_CONFIG=.*|readonly NGINX_CONFIG=\"${NGINX_CONFIG}\"|" \
    -e "s|^readonly UFW_DEFAULT_CONFIG=.*|readonly UFW_DEFAULT_CONFIG=\"${TMP_DIR}/ufw-default\"|" \
    "${ROOT_DIR}/lib/xhttp-runtime.sh" >"${TMP_DIR}/lib/xhttp-runtime.sh"
sed -e "s|^readonly CLOUDFLARE_ORIGIN_IPS_FILE=.*|readonly CLOUDFLARE_ORIGIN_IPS_FILE=\"${STATE_DIR}/cloudflare-origin-ipv4.txt\"|" \
    "${PROFILE}" >"${TMP_DIR}/profiles/xhttp-cloudflare-streamup.sh"
for directory in templates scripts worker-src; do
    ln -s "${ROOT_DIR}/${directory}" "${TMP_DIR}/${directory}"
done

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
source "${TMP_DIR}/profiles/xhttp-cloudflare-streamup.sh"
trap 'status=$?; cleanup; rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

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
  "version": 8,
  "provider": "cloudflare",
  "domain": "node.example.com",
  "candidate_source": "cloudflare-official-ipv4",
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
jq '.version = 7' "${GLOBALPING_CACHE_FILE}" >"${TMP_DIR}/legacy-cloudflare-cache.json"
cp "${TMP_DIR}/legacy-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"
if cloudflare_globalping_cache_compatible; then
    fail "Legacy Cloudflare cache must be rejected"
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
assert_contains "Links contain 🇺🇸优选1" "${node_links}" "#$(jq -nr --arg v '🇺🇸优选1' '$v|@uri')"
assert_contains "Links contain 🇺🇸优选6" "${node_links}" "#$(jq -nr --arg v '🇺🇸优选6' '$v|@uri')"
assert_not_contains "Links do not contain 🇺🇸优选7" "${node_links}" "#$(jq -nr --arg v '🇺🇸优选7' '$v|@uri')"

# Test Mihomo nodes: exactly 6 nodes
mihomo_nodes=$(build_mihomo_nodes)
node_count=$(grep -c '^[[:space:]]*- name:' <<<"${mihomo_nodes}")
assert_equal "Mihomo nodes count is exactly 6" "6" "${node_count}"

assert_contains "Mihomo renders 🇺🇸优选1" "${mihomo_nodes}" '"🇺🇸优选1"'
assert_contains "Mihomo renders 🇺🇸优选6" "${mihomo_nodes}" '"🇺🇸优选6"'
assert_contains "Mihomo renders network: xhttp" "${mihomo_nodes}" "network: xhttp"
assert_contains "Mihomo renders mode: stream-up" "${mihomo_nodes}" "mode: stream-up"
assert_contains "Mihomo renders alpn h2" "${mihomo_nodes}" "- h2"
assert_contains "Mihomo renders path with trailing slash" "${mihomo_nodes}" 'path: "/xhttp-test-path/"'
assert_contains "Mihomo renders no-grpc-header false" "${mihomo_nodes}" "no-grpc-header: false"
assert_not_contains "Mihomo nodes do not contain domain fallback" "${mihomo_nodes}" 'server: "node.example.com"'

# Test Mihomo proxy groups: only AUTO group, no carrier groups
groups_output=$(build_mihomo_proxy_groups)
assert_contains "Groups contain AUTO group" "${groups_output}" 'name: "AUTO"'
assert_contains "AUTO group contains 🇺🇸优选1" "${groups_output}" '"🇺🇸优选1"'
assert_contains "AUTO group contains 🇺🇸优选6" "${groups_output}" '"🇺🇸优选6"'
assert_not_contains "Groups do not contain 电信优选 group" "${groups_output}" 'name: "电信优选"'
assert_not_contains "Groups do not contain 联通优选 group" "${groups_output}" 'name: "联通优选"'
assert_not_contains "Groups do not contain 移动优选 group" "${groups_output}" 'name: "移动优选"'
assert_contains "Groups test url" "${groups_output}" 'url: https://cp.cloudflare.com/generate_204'
assert_contains "Groups tolerance is 30" "${groups_output}" 'tolerance: 30'
assert_not_contains "Groups do not contain domain fallback" "${groups_output}" 'DOMAIN'

# Worker fallback nodes use their own automatic latency-test group.
(
    WORKER_BACKUP_DOMAIN=backup.example.com
    WORKER_BACKUP_NAME=easyall-backup-test
    WORKER_BACKUP_DOMAIN_ID=test-backup-domain-id
    WORKER_BACKUP_UUID=11111111-2222-4333-8444-555555555555
    WORKER_BACKUP_PATH=/vless-test
    WORKER_BACKUP_IPS='["104.16.1.1","104.16.2.2","104.16.3.3","104.16.4.4","104.16.5.5","104.16.6.6"]'
    worker_groups=$(build_mihomo_proxy_groups)
    worker_names=$(build_mihomo_proxy_names)
    worker_rules=$(build_mihomo_worker_rules)
    assert_contains "Worker groups contain HK CF" "${worker_groups}" 'name: "🇭🇰CF"'
    assert_contains "HK CF uses url-test" "${worker_groups}" 'type: url-test'
    assert_contains "HK CF avoids Cloudflare-owned probe targets" \
        "${worker_groups}" 'url: https://www.gstatic.com/generate_204'
    assert_not_contains "HK CF omits domain entry" "${worker_groups}" "${WORKER_BACKUP_DOMAIN}"
    assert_contains "HK CF contains first optimized entry" "${worker_groups}" '"🇭🇰CF1"'
    assert_contains "HK CF contains sixth optimized entry" "${worker_groups}" '"🇭🇰CF6"'
    assert_contains "PROXY includes HK CF" "${worker_names}" '"🇭🇰CF"'
    assert_not_contains "PROXY omits raw Worker nodes" "${worker_names}" '"🇭🇰CF1"'
    assert_contains "Automatic groups are hidden" "${worker_groups}" 'hidden: true'
    assert_equal "No special Worker routing" "" "${worker_rules}"
    WORKER_BACKUP_IPS='[]'
    assert_equal "Worker rules are omitted without published Worker nodes" "" "$(build_mihomo_worker_rules)"
)

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
    choose_cloudflare_worker_name </dev/null
    assert_equal "Worker name defaults to easyall" "easyall" \
        "${CLOUDFLARE_WORKER_NAME}"
)
for name in easyall a worker-123 "$(printf '%063d' 0)"; do
    validate_cloudflare_worker_name "${name}" || fail "Valid Worker name rejected: ${name}"
done
for name in EASYALL EasyAll worker_name 'worker name' -worker worker- '' "$(printf '%064d' 0)"; do
    if validate_cloudflare_worker_name "${name}"; then
        fail "Invalid Worker name accepted: ${name}"
    fi
done

assert_equal "Worker config normalizer keeps one Reality node" "1" \
    "$(normalize_worker_aggregation_config "${WORKER_AGGREGATION_CONFIG}" | jq '.nodes | length')"
assert_equal "Worker config migrates the legacy preferred node name" "🇺🇸晚上首选" \
    "$(normalize_worker_aggregation_config \
        '{"nodes":[{"name":"🇺🇸自建首选750G"}],"externalSubUrl":"","fallbackCdnNodes":[]}' \
        | jq -r '.nodes[0].name')"
assert_equal "Worker config adds the country marker to the preferred node" "🇺🇸晚上首选" \
    "$(normalize_worker_aggregation_config \
        '{"nodes":[{"name":"晚上首选"}],"externalSubUrl":"","fallbackCdnNodes":[]}' \
        | jq -r '.nodes[0].name')"
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
        "$(<"${api_calls}")" '"service":"easyall"'
    assert_equal "New domain is tracked for rollback" new-worker-domain-id "${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID}"
    unset CLOUDFLARE_CREATED_WORKER_DOMAIN_ID
    cloudflare_api_request() {
        [[ "$1" == GET ]] || fail "Existing domain must not be recreated"
        printf '[{"id":"existing-domain","hostname":"sub.example.com","service":"easyall"}]\n'
    }
    cloudflare_attach_subscription_worker_domain
    assert_equal "Matching domain is reused" existing-domain "${CLOUDFLARE_WORKER_DOMAIN_ID}"
    assert_equal "Reused domain is not marked as new" '' "${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID:-}"
)

# Existing scripts require a saved ownership record; owned scripts are snapshotted.
(
    CLOUDFLARE_WORKER_DOMAIN_ID=""
    CLOUDFLARE_API_TOKEN=test-api-token-placeholder
    CLOUDFLARE_WORKER_BUILD_CURRENT=1
    mock_scripts='[{"id":"easyall"}]'
    cloudflare_api_request() { printf '%s\n' "${mock_scripts}"; }
    curl() { printf '{"success":true}\n'; }
    if (cloudflare_validate_worker_access >/dev/null 2>&1); then
        fail "Unowned existing Worker must not be overwritten"
    fi
    CLOUDFLARE_WORKER_DOMAIN_ID=test-worker-domain-id
    cloudflare_api_request() {
        case "$2" in
        */workers/domains)
            printf '[{"id":"test-worker-domain-id","hostname":"sub.example.com","service":"easyall"}]\n'
            ;;
        */deployments)
            printf '{"deployments":[{"versions":[{"version_id":"11111111-1111-4111-8111-111111111111","percentage":100}]}]}\n'
            ;;
        *) printf '%s\n' "${mock_scripts}" ;;
        esac
    }
    CLOUDFLARE_WORKER_DOMAIN_ID=wrong-worker-domain-id
    if (cloudflare_validate_worker_access >/dev/null 2>&1); then
        fail "Mismatched Worker domain ownership must not authorize overwrite"
    fi
    CLOUDFLARE_WORKER_DOMAIN_ID=test-worker-domain-id
    for mock_scripts in '[{"id":"easyall"}]' '[]'; do
        unset CLOUDFLARE_WORKER_CREATED
        rm -f -- "${RUNTIME_TMP}/subscription-worker-deployment-prev.json"
        if [[ "${mock_scripts}" == '[]' ]]; then
            CLOUDFLARE_WORKER_DOMAIN_ID=""
        else
            CLOUDFLARE_WORKER_DOMAIN_ID=test-worker-domain-id
        fi
        cloudflare_validate_worker_access
        cloudflare_upload_subscription_worker
        if [[ "${mock_scripts}" == '[]' ]]; then
            assert_equal "New Worker is tracked for rollback" 1 "${CLOUDFLARE_WORKER_CREATED:-0}"
        else
            assert_equal "Owned Worker is retained on rollback" 0 "${CLOUDFLARE_WORKER_CREATED:-0}"
            [[ -s "${RUNTIME_TMP}/subscription-worker-deployment-prev.json" ]] \
                || fail "Owned Worker deployment must be snapshotted"
        fi
    done
)

jq '.candidates += [
      {"ip":"2606:4700::6810:101","source_cidr":"2606:4700::/32","address_family":"ipv6","label":"IPv6-1","carrier":"ipv6","carrier_asn":0,"avg_rtt_ms":95,"tls_verified":true}
    ]' "${TMP_DIR}/valid-cloudflare-cache.json" >"${GLOBALPING_CACHE_FILE}"
if cloudflare_globalping_cache_compatible; then
    fail "Cloudflare cache containing an IPv6 edge candidate must be rejected"
fi
cp "${TMP_DIR}/valid-cloudflare-cache.json" "${GLOBALPING_CACHE_FILE}"

# The node hostname must be exactly one label below the active Cloudflare Zone.
(
    cloudflare_lookup_parent_zone() { printf 'test-zone-id'; }
    cloudflare_api_request() { printf '{"name":"example.com"}\n'; }

    if cloudflare_validate_node_domain_input example.com; then
        fail "Cloudflare Zone root must not be accepted as the node domain"
    fi
    assert_contains "Root-domain rejection explains the required node hostname" \
        "${CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR}" "node.example.com"
    cloudflare_validate_node_domain_input node.example.com \
        || fail "A first-level node subdomain should be accepted"
    if cloudflare_validate_node_domain_input deep.node.example.com; then
        fail "A nested node hostname must not be accepted"
    fi

    prompt_calls="${TMP_DIR}/node-domain-prompt-calls"
    : >"${prompt_calls}"
    VLESS_CDN_DOMAIN=example.com
    prompt_value() {
        printf 'prompt\n' >>"${prompt_calls}"
        printf 'node.example.com'
    }
    collect_cloudflare_node_domain
    assert_equal "Root domain is replaced by a prompted node subdomain" \
        "node.example.com" "${VLESS_CDN_DOMAIN}"
    assert_equal "Invalid root domain triggers one new prompt" \
        "1" "$(wc -l <"${prompt_calls}" | tr -d ' ')"
)

# Test Mihomo proxy names under PROXY
names_output=$(build_mihomo_proxy_names)
assert_contains "Names contain AUTO" "${names_output}" '"AUTO"'
assert_not_contains "Names do not contain 🇺🇸优选1" "${names_output}" '"🇺🇸优选1"'
assert_not_contains "Names do not contain 电信优选" "${names_output}" '"电信优选"'

# Test write_subscriptions: supports Universal (Base64) and Clash (Mihomo)
original_validate_subscription_runtime=$(declare -f validate_subscription_runtime)
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
assert_contains "Mihomo file contains 🇺🇸优选1" "${mihomo_file_content}" '"🇺🇸优选1"'
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

# Every old file remains readable during rendering and each publication rename.
(
    eval "$(declare -f render_mihomo_subscription | sed '1s/render_mihomo_subscription/original_render/')"
    render_mihomo_subscription() {
        [[ -s "${SUBSCRIPTION_DIR}/owner/base64.txt" && -s "${SUBSCRIPTION_DIR}/friend/mihomo.yaml" ]] \
            || fail "Quota rendering removed live subscriptions"
        original_render "$@"
    }
    mv() {
        local file
        for file in owner/base64.txt owner/mihomo.yaml friend/base64.txt friend/mihomo.yaml; do
            [[ -s "${SUBSCRIPTION_DIR}/${file}" ]] || fail "Publication removed ${file}"
        done
        command mv "$@"
        printf 'rename\n' >>"${TMP_DIR}/subscription-renames"
    }
    write_subscriptions
    assert_equal "Quota refresh atomically replaces all four files" 4 \
        "$(wc -l <"${TMP_DIR}/subscription-renames" | tr -d ' ')"
)
cp -a "${SUBSCRIPTION_DIR}" "${TMP_DIR}/subscriptions-before-failure"
if (
    render_mihomo_subscription() { die "injected rendering failure"; }
    write_subscriptions
) >/dev/null 2>&1; then
    fail "Injected rendering failure must stop publication"
fi
diff -r "${TMP_DIR}/subscriptions-before-failure" "${SUBSCRIPTION_DIR}" \
    || fail "Rendering failure changed live subscriptions"
if (
    trap - EXIT
    mv() {
        command mv "$@"
        command bash -c 'kill -KILL "$PPID"'
    }
    write_subscriptions
) >/dev/null 2>&1; then
    fail "Interrupted publication must fail"
else
    assert_equal "Publication was interrupted by SIGKILL" 137 "$?"
fi
diff -r "${TMP_DIR}/subscriptions-before-failure" "${SUBSCRIPTION_DIR}" \
    || fail "Interrupted publication removed or truncated a live subscription"

# Switching modes still handles usernames that collide with shared filenames.
USER_ACCOUNTS='{"base64.txt":{"uuid":"11111111-2222-4111-8111-111111111111","token":"owner-token-123","quota_gb":10}}'
write_subscriptions
[[ -s "${SUBSCRIPTION_DIR}/base64.txt/base64.txt" && ! -e "${SUBSCRIPTION_DIR}/friend" ]] \
    || fail "Quota publication must remove retired users and support filename-like usernames"
QUOTA_ENABLED=0
USER_ACCOUNTS=""
QUOTA_START_DATE=""
ALLOWED_TOKENS='{"owner":"test-token-12345"}'
write_subscriptions
[[ -f "${SUBSCRIPTION_BASE64_FILE}" && -f "${SUBSCRIPTION_MIHOMO_FILE}" && ! -e "${SUBSCRIPTION_DIR}/owner" ]] \
    || fail "Switching off quota must publish shared files and remove per-user files"
VPS_IP_FAMILY="dual"
VPS_PUBLIC_IPV6="2001:db8::10"

# Verify state save & load
WORKER_BACKUP_RETIREMENTS='[{"account":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","name":"old-backup","id":"old-domain"}]'
expected_retirements=${WORKER_BACKUP_RETIREMENTS}
CLOUDFLARE_SUBSCRIPTION_RETIREMENTS='[{"account":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","host":"old-sub.example.com","name":"old-sub","id":"old-sub-domain","delete_script":true}]'
expected_subscription_retirements=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
save_state
[[ -f "${EASY_ALL_STATE_FILE_OVERRIDE}" ]] || fail "State file not created"
state_content=$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")
assert_contains "State file protocol is cloudflare-streamup" "${state_content}" 'PROTOCOL=cloudflare-streamup'
assert_contains "State file backend is xray" "${state_content}" 'BACKEND=xray'
assert_contains "State file cdn is cloudflare" "${state_content}" 'CDN_PROVIDER=cloudflare'
assert_contains "State defaults to BBRv3" "${state_content}" 'TCP_ACCELERATION=bbrv3'
assert_contains "State file normalizes legacy dual-stack mode" "${state_content}" 'VPS_IP_FAMILY=ipv4'
assert_contains "State file clears public IPv6" "${state_content}" 'VPS_PUBLIC_IPV6='
assert_not_contains "State file omits removed Cloudflare client family" "${state_content}" \
    'CLOUDFLARE_CLIENT_IP_FAMILY='
assert_contains "State file persists Google egress mode" "${state_content}" \
    'GOOGLE_EGRESS_MODE=ipv4'
assert_contains "State file persists resolved Google family" "${state_content}" \
    'GOOGLE_EGRESS_RESOLVED=ipv4'
assert_contains "State file persists Worker name" "${state_content}" \
    'CLOUDFLARE_WORKER_NAME=easyall'
assert_contains "State file persists Worker domain ID" "${state_content}" \
    'CLOUDFLARE_WORKER_DOMAIN_ID=test-worker-domain-id'
assert_contains "State file persists Cloudflare Account ID" "${state_content}" \
    'CLOUDFLARE_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
assert_contains "State file persists private Worker source secret" "${state_content}" \
    'WORKER_SOURCE_SECRET=test-worker-source-secret-12345'
assert_contains "State file persists Worker aggregation config" "${state_content}" \
    'WORKER_AGGREGATION_CONFIG='

TCP_ACCELERATION=skyline
save_state
unset TCP_ACCELERATION
load_state
assert_equal "Cloudflare preserves Skyline across save and reload" skyline "${TCP_ACCELERATION}"
TCP_ACCELERATION=bbrv3
save_state

missing_policy_state="${TMP_DIR}/state_missing_policy.env"
grep -Ev '^(GOOGLE_EGRESS_MODE|GOOGLE_EGRESS_RESOLVED|TCP_ACCELERATION)=' \
    "${EASY_ALL_STATE_FILE_OVERRIDE}" >"${missing_policy_state}"
load_state_env_calls="${TMP_DIR}/load-state-env-calls"
: >"${load_state_env_calls}"
env() {
    printf 'x' >>"${load_state_env_calls}"
    command env "$@"
}
WORKER_BACKUP_RETIREMENTS=""
CLOUDFLARE_SUBSCRIPTION_RETIREMENTS=""
EASY_ALL_STATE_FILE_OVERRIDE="${missing_policy_state}" load_state
unset -f env
assert_equal "Retirements survive a real state save and reload" "${expected_retirements}" "${WORKER_BACKUP_RETIREMENTS}"
assert_equal "Subscription retirements survive a real state save and reload" \
    "${expected_subscription_retirements}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
assert_equal "load_state uses one isolated subprocess" "1" \
    "$(wc -c <"${load_state_env_calls}" | tr -d ' ')"
assert_equal "Missing Google mode defaults to IPv4" ipv4 "${GOOGLE_EGRESS_MODE}"
assert_equal "Missing Google family defaults to IPv4" ipv4 "${GOOGLE_EGRESS_RESOLVED}"
assert_equal "Legacy Cloudflare state defaults to BBRv3" bbrv3 "${TCP_ACCELERATION}"

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
GOOGLE_EGRESS_MODE='auto'
GOOGLE_EGRESS_RESOLVED='ipv4'
CLOUDFLARE_ACCOUNT_ID='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
CLOUDFLARE_WORKER_NAME='easyall'
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
assert_equal "v9 states without subscription retirements default to an empty list" \
    '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
assert_equal "load_state normalizes corrupted XHTTP_PATH" \
    "/xhttp-0123456789abcdef" "${XHTTP_PATH}"
assert_equal "load_state normalizes Google egress mode" \
    "ipv4" "${GOOGLE_EGRESS_MODE}"
assert_equal "load_state normalizes the current VPS family" \
    "ipv4" "${VPS_IP_FAMILY}"
assert_equal "load_state clears legacy VPS IPv6" "" "${VPS_PUBLIC_IPV6}"
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

# API success requires a valid envelope, except successful empty DELETE responses.
(
    CLOUDFLARE_API_TOKEN=test-api-token-placeholder
    curl() { printf '%s' "${mock_response}"; }
    for mock_response in $'\n204' $'\n200' $' \n\n200'; do
        assert_equal "Successful empty DELETE succeeds without JSON" null "$(cloudflare_api_request DELETE /test)"
    done
    mock_response=$'{"success":true,"result":{"id":"ok"}}\n200'
    assert_equal "JSON API response remains supported" '{"id":"ok"}' "$(cloudflare_api_request GET /test)"
    for mock_response in $'\n403' $'\n500' $'\n202' $'{"success":false}\n200'; do
        if (cloudflare_api_request DELETE /test) >/dev/null 2>&1; then
            fail "Failed or ambiguous API response must not pass"
        fi
    done
    for method in GET POST PUT PATCH HEAD; do
        for mock_response in $'\n200' $'\n204' $' \n\t\n200' \
            $'{"success":true}\n{"success":true}\n200' \
            $'{"success":false}\n{"success":true}\n200' \
            $'[{"success":true}]\n200' $'true\n200'; do
            if (cloudflare_api_request "${method}" /test) >/dev/null 2>&1; then
                fail "${method} must require exactly one successful object envelope"
            fi
        done
    done
    mock_response=$'{"success":true}\n{"success":true}\n200'
    if (cloudflare_api_request DELETE /test) >/dev/null 2>&1; then
        fail "Nonempty DELETE must also reject multiple envelopes"
    fi
)

# Exercise real update/apply/purge orchestration and state I/O against a local API.
(
    trap - EXIT
    retirement_dir="${TMP_DIR}/subscription-retirement"
    mkdir -p "${retirement_dir}"
    EASY_ALL_STATE_FILE_OVERRIDE="${retirement_dir}/state.env"
    domains_file="${retirement_dir}/domains.json"
    scripts_file="${retirement_dir}/scripts.json"
    api_calls="${retirement_dir}/api-calls"
    : >"${api_calls}"
    fail_delete=""
    next_mode=link
    next_host=new-sub.example.com
    CLOUDFLARE_HEADER_RULESET_ID=test-header-ruleset
    CLOUDFLARE_STRICT_RULESET_ID=test-strict-ruleset
    WORKER_BACKUP_RETIREMENTS='[]'
    WORKER_BACKUP_DOMAIN=""
    WORKER_BACKUP_NAME=""
    WORKER_BACKUP_DOMAIN_ID=""
    WORKER_BACKUP_DECOMMISSION=0
    VPS_PUBLIC_IPV4=203.0.113.10
    QUOTA_ENABLED=0
    FORCE=1
    real_snapshot_subscription_update=$(declare -f snapshot_subscription_update)
    for stub in require_root begin_quota_maintenance snapshot_subscription_update \
        choose_google_egress_mode choose_subscription_download_name choose_monthly_quota \
        ensure_allowed_tokens choose_worker_aggregation_config cloudflare_build_subscription_worker \
        collect_worker_backup_inputs xhttp_render_xray_config cloudflare_validate_zones \
        cloudflare_ensure_proxied_a cloudflare_snapshot_worker_deployment \
        cloudflare_issue_origin_certificate cloudflare_configure_cdn cloudflare_deploy_backup_worker \
        finish_xhttp_apply cloudflare_validate_subscription_worker cloudflare_validate_cdn_health \
        cloudflare_prepare_backup_retirement install_globalping_refresh_timer \
        cloudflare_finalize_certificate_rotation cloudflare_finalize_backup_worker \
        cloudflare_commit_provider_subscription_update cloudflare_clear_api_token \
        show_subscription configure_bbr_tcp refresh_google_egress_selection configure_ufw \
        cloudflare_collect_api_token cloudflare_purge_managed_rule \
        cloudflare_purge_empty_owned_ruleset cloudflare_purge_managed_dns_record; do
        eval "${stub}() { :; }"
    done
    globalping_cache_valid() { return 0; }
    collect_installed_state() { load_state; }
    choose_subscription_mode() { SUBSCRIPTION_MODE=${next_mode}; }
    collect_cloudflare_worker_inputs() {
        SUBSCRIPTION_DOMAIN=${next_host}
        CLOUDFLARE_WORKER_NAME=${CLOUDFLARE_WORKER_NAME:-easyall}
        WORKER_SOURCE_SECRET=test-worker-source-secret-12345
        ALLOWED_TOKENS='{"owner":"test-token-12345"}'
    }
    cloudflare_deploy_subscription_worker() {
        subscription_enabled || return 0
        cloudflare_validate_worker_access
        if [[ "${CLOUDFLARE_WORKER_EXISTS}" == 0 ]]; then
            printf '[{"id":"easyall"}]\n' >"${scripts_file}"
            CLOUDFLARE_WORKER_CREATED=1
        fi
        cloudflare_attach_subscription_worker_domain
    }
    commit_subscription_update() {
        # Every pending change must be durable when the transaction commits.
        durable=$(env -i bash -c 'source "$1"; printf "%s" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"' \
            _ "${EASY_ALL_STATE_FILE_OVERRIDE}")
        assert_equal "Pending ownership is persisted before commit" \
            "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}" "${durable}"
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
    }
    cloudflare_record_list() { printf '[]\n'; }
    cloudflare_api_request() {
        printf '%s %s\n' "$1" "$2" >>"${api_calls}"
        case "$1 $2" in
            "GET /accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains") cat "${domains_file}" ;;
            "GET /accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts") cat "${scripts_file}" ;;
            "PUT /accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains")
                binding=$(jq -c '. + {id:"new-domain"}' <<<"$3")
                jq --argjson binding "${binding}" '. + [$binding]' \
                    "${domains_file}" >"${domains_file}.new"
                mv "${domains_file}.new" "${domains_file}"
                printf '%s\n' "${binding}"
                ;;
            DELETE*)
                [[ "$2" != "${fail_delete}" ]] || die "mock DELETE failed"
                case "$2" in
                    */workers/domains/*)
                        jq --arg id "${2##*/}" 'map(select(.id != $id))' "${domains_file}" >"${domains_file}.new"
                        mv "${domains_file}.new" "${domains_file}" ;;
                    */workers/scripts/*)
                        jq --arg id "${2##*/}" 'map(select(.id != $id))' "${scripts_file}" >"${scripts_file}.new"
                        mv "${scripts_file}.new" "${scripts_file}" ;;
                    /certificates/*) : ;;
                    *) fail "Unexpected DELETE: $2" ;;
                esac
                ;;
            *) fail "Unexpected retirement API call: $1 $2" ;;
        esac
    }
    reset_subscription_fixture() {
        SUBSCRIPTION_MODE=deploy
        SUBSCRIPTION_DOMAIN=old-sub.example.com
        CLOUDFLARE_WORKER_NAME=easyall
        CLOUDFLARE_WORKER_DOMAIN_ID=old-domain
        WORKER_SOURCE_SECRET=test-worker-source-secret-12345
        ALLOWED_TOKENS='{"owner":"test-token-12345"}'
        CLOUDFLARE_SUBSCRIPTION_RETIREMENTS='[]'
        CLOUDFLARE_WORKER_CREATED=0
        CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=""
        fail_delete=""
        next_host=new-sub.example.com
        printf '[{"id":"old-domain","hostname":"old-sub.example.com","service":"easyall"}]\n' >"${domains_file}"
        printf '[{"id":"easyall"}]\n' >"${scripts_file}"
        : >"${api_calls}"
        save_state
    }

    reset_subscription_fixture
    # Deleting the binding succeeds, deleting the script exits via die.
    fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/easyall"
    update_subscription
    load_state
    assert_equal "Disabled subscription remains disabled after cleanup exits" link "${SUBSCRIPTION_MODE}"
    assert_equal "Disabled active Worker identity is cleared" '' "${CLOUDFLARE_WORKER_NAME}"
    assert_equal "Old script identity survives partial deletion" easyall \
        "$(jq -r '.[0].name' <<<"${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}")"
    assert_equal "Old hostname survives partial deletion" old-sub.example.com \
        "$(jq -r '.[0].host' <<<"${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}")"
    assert_equal "The binding really was deleted before failure" '[]' "$(jq -c . "${domains_file}")"
    fail_delete=""
    apply_cloud_resources
    load_state
    assert_equal "apply-cloud retries and clears completed retirements" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    assert_equal "apply-cloud deletes the old script after its binding is gone" '[]' "$(jq -c . "${scripts_file}")"

    reset_subscription_fixture
    next_mode=deploy
    fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/old-domain"
    update_subscription
    load_state
    assert_equal "Switch commits the new domain despite cleanup exiting" new-sub.example.com "${SUBSCRIPTION_DOMAIN}"
    assert_equal "Switch only retires the old binding" false \
        "$(jq -r '.[0].delete_script' <<<"${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}")"
    assert_equal "Switch persists the old binding ID" old-domain \
        "$(jq -r '.[0].id' <<<"${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}")"
    fail_delete=""
    cloudflare_finalize_subscription_worker_retirements
    load_state
    assert_equal "Domain retry clears the completed record" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    assert_equal "Domain retry preserves the active script" '[{"id":"easyall"}]' "$(jq -c . "${scripts_file}")"
    assert_equal "Domain retry preserves the new binding" new-domain "$(jq -r '.[0].id' "${domains_file}")"
    assert_not_contains "Switch must never delete its shared script" "$(<"${api_calls}")" 'DELETE /accounts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/workers/scripts/'

    # A -> B with failed A deletion -> A must cancel A's pending identity.
    reset_subscription_fixture
    next_mode=deploy
    fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/old-domain"
    update_subscription
    next_host=old-sub.example.com
    fail_delete=""
    : >"${api_calls}"
    update_subscription
    load_state
    assert_equal "Switching back reuses A's binding" old-domain "${CLOUDFLARE_WORKER_DOMAIN_ID}"
    assert_equal "Reclaimed active binding has no pending retirement" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    assert_equal "Switching back preserves A's cloud binding" old-domain "$(jq -r '.[0].id' "${domains_file}")"
    assert_not_contains "Reclaimed A is never retired" "$(<"${api_calls}")" 'DELETE /accounts/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/workers/domains/old-domain'
    assert_not_contains "Shared active script is never retired" "$(<"${api_calls}")" '/workers/scripts/easyall'
    UNINSTALL_PURGE_CLOUD=1 purge_cloudflare_resources_before_uninstall
    assert_equal "Purge is not blocked by reclaimed pending ownership" '[]' "$(jq -c . "${domains_file}")"
    assert_equal "Purge deletes the active script normally" '[]' "$(jq -c . "${scripts_file}")"

    # Both partial disable failures can re-enable the same Worker name.
    for failed_resource in domains/old-domain scripts/easyall; do
        reset_subscription_fixture
        next_mode=link
        fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/${failed_resource}"
        update_subscription
        load_state
        pending=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
        assert_equal "Partial disable clears active identity (${failed_resource})" '' "${CLOUDFLARE_WORKER_DOMAIN_ID}"
        [[ "${pending}" != '[]' ]] || fail "Partial disable must retain ownership"
        next_mode=deploy
        next_host=old-sub.example.com
        if (update_subscription) >"${retirement_dir}/reenable-error" 2>&1; then
            fail "Re-enable must stop while retirement still fails (${failed_resource})"
        fi
        load_state
        assert_equal "Failed re-enable preserves pending (${failed_resource})" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
        assert_equal "Failed re-enable preserves disabled state (${failed_resource})" link "${SUBSCRIPTION_MODE}"
        fail_delete=""
        update_subscription
        load_state
        assert_equal "Re-enable succeeds after partial deletion (${failed_resource})" deploy "${SUBSCRIPTION_MODE}"
        assert_equal "Re-enable commits completed retirement (${failed_resource})" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
        assert_equal "Re-enable creates a fresh binding (${failed_resource})" new-domain "${CLOUDFLARE_WORKER_DOMAIN_ID}"
        assert_equal "Re-enable recreates the same owned script (${failed_resource})" '[{"id":"easyall"}]' "$(jq -c . "${scripts_file}")"
    done

    # Pending ownership does not authorize deleting a rebound/foreign resource.
    for mismatch in service hostname rebound-host extra-domain account active-backup; do
        reset_subscription_fixture
        next_mode=link
        fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/old-domain"
        update_subscription
        load_state
        case "${mismatch}" in
            service) printf '[{"id":"old-domain","hostname":"old-sub.example.com","service":"foreign"}]' >"${domains_file}" ;;
            hostname) printf '[{"id":"old-domain","hostname":"foreign.example.com","service":"easyall"}]' >"${domains_file}" ;;
            rebound-host) printf '[{"id":"foreign-domain","hostname":"old-sub.example.com","service":"foreign"}]' >"${domains_file}" ;;
            extra-domain) printf '[{"id":"old-domain","hostname":"old-sub.example.com","service":"easyall"},{"id":"foreign-domain","hostname":"foreign.example.com","service":"easyall"}]' >"${domains_file}" ;;
            account) CLOUDFLARE_SUBSCRIPTION_RETIREMENTS=$(jq -c '.[0].account = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' <<<"${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"); save_state ;;
            active-backup) WORKER_BACKUP_DOMAIN=backup.example.com; WORKER_BACKUP_NAME=easyall ;;
        esac
        fail_delete=""
        next_mode=deploy
        pending=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
        : >"${api_calls}"
        if (
            # collect_installed_state only reloads persistent state; leave the
            # simulated active backup guard in place for this access attempt.
            collect_installed_state() { :; }
            update_subscription
        ) >"${retirement_dir}/ownership-error" 2>&1; then
            fail "Re-enable must reject ${mismatch} pending ownership"
        fi
        assert_not_contains "Re-enable ${mismatch} issues no DELETE" "$(<"${api_calls}")" 'DELETE '
        load_state
        assert_equal "Re-enable ${mismatch} retains pending ownership" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
        WORKER_BACKUP_DOMAIN=""
        WORKER_BACKUP_NAME=""
    done

    # Completed pre-access cleanup must not save tentative enable state. A later
    # failure uses the real transaction rollback and restores the disabled state.
    (
        reset_subscription_fixture
        next_mode=link
        fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/easyall"
        update_subscription
        load_state
        pending=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
        cp "${EASY_ALL_STATE_FILE_OVERRIDE}" "${STATE_FILE}"
        expected_old_state=$(<"${STATE_FILE}")
        eval "${real_snapshot_subscription_update}"
        fail_delete=""
        next_mode=deploy
        cloudflare_issue_origin_certificate() {
            assert_equal "Pre-access cleanup leaves previous durable state intact" \
                "${expected_old_state}" "$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")"
            die "mock failure after pending cleanup"
        }
        if (
            trap 'if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == 1 ]]; then rollback_subscription_update; fi' EXIT
            update_subscription
        ) >"${retirement_dir}/rollback-error" 2>&1; then
            fail "Later update failure must roll back"
        fi
        assert_equal "Rollback restores the previous state exactly" "${expected_old_state}" "$(<"${STATE_FILE}")"
        EASY_ALL_STATE_FILE_OVERRIDE="${STATE_FILE}" load_state
        assert_equal "Rollback retains pending identity for idempotent retry" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
        assert_equal "Rollback retains disabled mode" link "${SUBSCRIPTION_MODE}"
    )

    # Repeated switching then disabling must detach retired bindings first.
    reset_subscription_fixture
    next_mode=deploy
    fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/old-domain"
    update_subscription
    next_mode=link
    fail_delete=""
    update_subscription
    load_state
    assert_equal "Disable drains earlier domain and script retirements" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    assert_equal "Disable deletes the script after all owned bindings" '[]' "$(jq -c . "${scripts_file}")"

    reset_subscription_fixture
    next_mode=link
    fail_delete="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/old-domain"
    update_subscription
    load_state
    pending=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
    stop_services() { printf 'stopped\n' >"${retirement_dir}/stopped"; }
    if (uninstall_all --purge-cloud) >"${retirement_dir}/uninstall-error" 2>&1; then
        fail "Failed retirement must stop uninstall --purge-cloud"
    fi
    [[ -f "${EASY_ALL_STATE_FILE_OVERRIDE}" && ! -e "${retirement_dir}/stopped" ]] \
        || fail "Failed purge must preserve state and local services"
    load_state
    assert_equal "Failed purge retains old ownership" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    fail_delete=""
    UNINSTALL_PURGE_CLOUD=1 purge_cloudflare_resources_before_uninstall
    load_state
    assert_equal "Purge retries old subscription ownership while mode is link" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"

    # A busy runtime writer must stop uninstall before any purge or local change.
    reset_subscription_fixture
    stop_services() { printf 'stopped\n' >"${retirement_dir}/stopped-services"; }
    stop_maintenance_services() { printf 'stopped\n' >"${retirement_dir}/stopped-maintenance"; }
    if (
        acquire_runtime_write_lock() { die "mock busy runtime lock"; }
        uninstall_all --purge-cloud
    ) >"${retirement_dir}/lock-error" 2>&1; then
        fail "Uninstall must abort when the runtime lock cannot be taken"
    fi
    [[ -f "${EASY_ALL_STATE_FILE_OVERRIDE}" ]] \
        || fail "A failed lock wait must preserve local state"
    [[ -f "${retirement_dir}/stopped-maintenance" ]] \
        || fail "Uninstall must stop maintenance units before the lock wait"
    [[ ! -e "${retirement_dir}/stopped-services" ]] \
        || fail "A failed lock wait must not stop local services"
    [[ ! -e "${retirement_dir}/stopped" ]] \
        || fail "A failed lock wait must not purge anything else"
    if command -v flock >/dev/null 2>&1; then
        exec {held_lock_fd}>"${RUNTIME_WRITE_LOCK_FILE}"
        flock -w 5 "${held_lock_fd}" || fail "Unable to hold the runtime write lock for the test"
        if (UNINSTALL_LOCK_WAIT_OVERRIDE=1 uninstall_all --purge-cloud) \
            >"${retirement_dir}/lock-error" 2>&1; then
            fail "A busy runtime lock must stop uninstall"
        fi
        flock -u "${held_lock_fd}"
        exec {held_lock_fd}>&-
        [[ -f "${EASY_ALL_STATE_FILE_OVERRIDE}" ]] \
            || fail "A failed lock wait must preserve local state"
        [[ -f "${retirement_dir}/stopped-maintenance" ]] \
            || fail "Uninstall must stop maintenance units before waiting for the lock"
        [[ ! -e "${retirement_dir}/stopped-services" ]] \
            || fail "A failed lock wait must not stop local services"
        [[ ! -e "${retirement_dir}/stopped" ]] \
            || fail "A failed lock wait must not purge anything else"
    fi

    # Missing bindings are already clean, and failed result persistence keeps ownership.
    reset_subscription_fixture
    SUBSCRIPTION_MODE=link
    cloudflare_prepare_subscription_worker_retirement \
        "${CLOUDFLARE_ACCOUNT_ID}" old-sub.example.com old-domain easyall
    save_state
    pending=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
    printf '[]\n' >"${domains_file}"
    printf '[]\n' >"${scripts_file}"
    (
        save_state() { die "mock state save failed"; }
        cloudflare_finalize_subscription_worker_retirements
        assert_equal "Failed save retains in-memory retirement" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    )
    load_state
    assert_equal "Failed save retains durable retirement" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    (
        mv() { return 1; }
        cloudflare_finalize_subscription_worker_retirements
        assert_equal "Failed atomic replacement retains retirement" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    )
    load_state
    assert_equal "Failed atomic replacement leaves the previous state readable" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    expected_old_state=$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")
    for save_failure in mktemp printf-first printf-middle printf-last invalid-temp chmod; do
        (
            case "${save_failure}" in
                mktemp) mktemp() { return 1; } ;;
                printf-*)
                    printf() {
                        if [[ "$1" == '%s=%q\n' ]]; then
                            case "${save_failure}:$2" in
                                printf-first:STATE_VERSION | printf-middle:CLOUDFLARE_SUBSCRIPTION_RETIREMENTS | printf-last:QUOTA_START_DATE)
                                    # Leave partial bytes, then simulate a failed write.
                                    builtin printf '%s=' "$2"
                                    return 1
                                    ;;
                            esac
                        fi
                        builtin printf "$@"
                    }
                    ;;
                invalid-temp) mktemp() { builtin printf '%s\n' "${retirement_dir}"; } ;;
                chmod) chmod() { return 1; } ;;
            esac
            if (save_state) >"${retirement_dir}/save-error" 2>&1; then
                fail "save_state must propagate ${save_failure} even in a conditional"
            fi
            cloudflare_finalize_subscription_worker_retirements
            assert_equal "${save_failure} retains in-memory ownership" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
            assert_equal "${save_failure} leaves durable state byte-for-byte unchanged" \
                "${expected_old_state}" "$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")"
            load_state
            assert_equal "${save_failure} leaves the previous state readable" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
        )
    done
    cloudflare_finalize_subscription_worker_retirements
    load_state
    assert_equal "Missing cloud resources complete retirement idempotently" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
    assert_not_contains "Missing resources require no DELETE" "$(<"${api_calls}")" 'DELETE '

    SUBSCRIPTION_MODE=deploy
    CLOUDFLARE_SUBSCRIPTION_RETIREMENTS='[{"account":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","host":"old-sub.example.com","name":"easyall","id":"old-domain","delete_script":false}]'
    printf '[{"id":"new-domain","hostname":"new-sub.example.com","service":"easyall"}]\n' >"${domains_file}"
    SUBSCRIPTION_DOMAIN=new-sub.example.com
    CLOUDFLARE_WORKER_DOMAIN_ID=new-domain
    cloudflare_finalize_subscription_worker_retirements
    assert_equal "An absent retired binding also completes domain-only cleanup" '[]' "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"

    # API ownership mismatches must retain records and issue no DELETE.
    for mismatch in service hostname extra-domain rebound-host account active-script active-backup; do
        reset_subscription_fixture
        SUBSCRIPTION_MODE=link
        cloudflare_prepare_subscription_worker_retirement \
            "${CLOUDFLARE_ACCOUNT_ID}" old-sub.example.com old-domain easyall
        case "${mismatch}" in
            service) printf '[{"id":"old-domain","hostname":"old-sub.example.com","service":"foreign"}]' >"${domains_file}" ;;
            hostname) printf '[{"id":"old-domain","hostname":"foreign.example.com","service":"easyall"}]' >"${domains_file}" ;;
            extra-domain) printf '[{"id":"old-domain","hostname":"old-sub.example.com","service":"easyall"},{"id":"foreign-domain","hostname":"foreign.example.com","service":"easyall"}]' >"${domains_file}" ;;
            rebound-host) printf '[{"id":"foreign-domain","hostname":"old-sub.example.com","service":"foreign"}]' >"${domains_file}" ;;
            account) CLOUDFLARE_SUBSCRIPTION_RETIREMENTS=$(jq -c '.[0].account = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"' <<<"${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}") ;;
            active-script) SUBSCRIPTION_MODE=deploy; SUBSCRIPTION_DOMAIN=new-sub.example.com; CLOUDFLARE_WORKER_DOMAIN_ID=new-domain ;;
            active-backup) WORKER_BACKUP_DOMAIN=backup.example.com; WORKER_BACKUP_NAME=easyall ;;
        esac
        pending=${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}
        cloudflare_finalize_subscription_worker_retirements
        assert_equal "${mismatch} preserves retirement" "${pending}" "${CLOUDFLARE_SUBSCRIPTION_RETIREMENTS}"
        assert_not_contains "${mismatch} refuses deletion" "$(<"${api_calls}")" 'DELETE '
        WORKER_BACKUP_DOMAIN=""
        WORKER_BACKUP_NAME=""
    done
)

# Worker acceptance exposes upstream failures while redacting the subscription token.
worker_error=$(
    (
        quota_enabled() { return 1; }
        ALLOWED_TOKENS='{"owner":"private-test-token"}'
        curl() {
            local header_file=""
            while (($#)); do
                if [[ "$1" == -D ]]; then
                    header_file=$2; shift
                elif [[ "$1" == --max-time ]]; then
                    [[ "$2" == 30 ]] || exit 99
                    shift
                fi
                shift
            done
            printf 'X-Easy-All-CDN-Warning: CDN subscription returned HTTP 404 private-test-token\r\n' >"${header_file}"
            printf 502
        }
        cloudflare_validate_subscription_worker
    ) 2>&1 || true
)
assert_contains "Worker failure includes response status" "${worker_error}" 'curl=0,HTTP=502'
assert_contains "Worker failure includes upstream reason" "${worker_error}" 'CDN subscription returned HTTP 404'
assert_not_contains "Worker diagnostics redact token" "${worker_error}" 'private-test-token'

# During install/update, an upstream acceptance failure keeps the deployment
# and emits a standalone Worker without weakening dynamic-source requirements.
(
    trap - EXIT
    quota_enabled() { return 1; }
    INSTALL_ROLLBACK_ON_EXIT=1
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    ALLOWED_TOKENS='{"owner":"recovery-test-token"}'
    WORKER_AGGREGATION_CONFIG='{"nodes":[],"externalSubUrl":"https://extra.example.com/subscribe","fallbackCdnNodes":[]}'
    CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE="${TMP_DIR}/home/worker.js"
    mkdir -p "$(dirname "${CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE}")"
    curl() {
        local header_file="" body_file=""
        while (($#)); do
            case "$1" in
                -D) header_file=$2; shift ;;
                -o) body_file=$2; shift ;;
            esac
            shift
        done
        printf 'X-Easy-All-CDN-Warning: CDN subscription returned HTTP 530\r\n' >"${header_file}"
        printf 'vless://fallback-node' | openssl base64 -A >"${body_file}"
        printf 200
    }
    cloudflare_validate_subscription_worker
    [[ -s "${CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE}" ]] \
        || fail "Worker acceptance recovery must write a manual deployment artifact"
    assert_equal "Worker acceptance recovery is marked for final reporting" \
        "1" "${CLOUDFLARE_WORKER_MANUAL_DEPLOY_REQUIRED:-0}"
    recovery_worker=$(<"${CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE}")
    assert_contains "Recovery Worker embeds local Token validation" \
        "${recovery_worker}" '"delegateTokenValidation":false'
    assert_contains "Recovery Worker embeds the current Token set" \
        "${recovery_worker}" '"owner":"recovery-test-token"'
    assert_contains "Recovery Worker still requires the dynamic CDN source" \
        "${recovery_worker}" '"requireDynamicCdn":true'
    assert_contains "Recovery Worker retains private source authentication" \
        "${recovery_worker}" '"sourceSecret":"test-worker-source-secret-12345"'
    expected_vps_source=$(printf '"vpsSubUrl":"https://%s/subscribe"' "${VLESS_CDN_DOMAIN}")
    assert_contains "Recovery Worker targets the current VPS source" \
        "${recovery_worker}" "${expected_vps_source}"
)

# Quota mode must not emit a fallback-capable Worker that bypasses Nginx accounting.
quota_recovery_error=$(
    (
        trap - EXIT
        quota_enabled() { return 0; }
        INSTALL_ROLLBACK_ON_EXIT=1
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE="${TMP_DIR}/home/quota-worker.js"
        curl() {
            local header_file="" body_file=""
            while (($#)); do
                if [[ "$1" == "-D" ]]; then
                    header_file=$2
                    shift
                elif [[ "$1" == "-o" ]]; then
                    body_file=$2
                    shift
                fi
                shift
            done
            printf 'X-Easy-All-CDN-Warning: CDN subscription returned HTTP 530\r\n' >"${header_file}"
            : >"${body_file}"
            printf 502
        }
        cloudflare_validate_subscription_worker
    ) 2>&1 || true
)
assert_contains "Quota mode refuses the fallback-capable recovery Worker" \
    "${quota_recovery_error}" '配额模式不能生成绕过 Nginx 配额校验的手工 Worker'
assert_contains "Quota mode keeps strict acceptance failure" \
    "${quota_recovery_error}" 'Cloudflare Worker 订阅验收失败'
[[ ! -e "${TMP_DIR}/home/quota-worker.js" ]] \
    || fail "Quota mode must not create a manual recovery Worker"

# A stale local resolver can use public DNS without changing TLS SNI or skipping auth checks.
(
    quota_enabled() { return 1; }
    dig() {
        [[ " $* " == *" @1.1.1.1 "* ]] || return 98
        printf 'not-an-ip\n127.0.0.1\n104.16.1.1\n'
    }
    curl() {
        local header_file="" body_file="" resolved=0 source=0 request_token=""
        while (($#)); do
            case "$1" in
                --resolve) [[ "$2" == "${SUBSCRIPTION_DOMAIN}:443:104.16.1.1" ]] || return 99; resolved=1; shift ;;
                -D) header_file=$2; shift ;;
                -o) body_file=$2; shift ;;
                --data-urlencode) [[ "$2" != "token@-" ]] || request_token=$(cat); shift ;;
                "https://${VLESS_CDN_DOMAIN}/subscribe") source=1 ;;
            esac
            shift
        done
        if ((source)); then printf 404; return; fi
        if (( ! resolved )); then printf 000; return 6; fi
        # The token arrives on stdin (never in argv); an unknown token must be rejected.
        if [[ -z "${request_token}" ]] \
            || ! jq -e --arg token "${request_token}" 'any(.[]; . == $token)' \
                <<<"${ALLOWED_TOKENS}" >/dev/null 2>&1; then
            printf 403
            return
        fi
        : >"${header_file}"
        printf 'vless://test-node' | openssl base64 -A >"${body_file}"
        printf 200
    }
    cloudflare_validate_subscription_worker
)

# A transient transport failure during invalid-token validation is retried
# through the same public-DNS fallback instead of being reported as an auth bug.
(
    quota_enabled() { return 1; }
    ALLOWED_TOKENS='{"owner":"retry-test-token"}'
    invalid_attempts_file="${TMP_DIR}/invalid-token-attempts"
    printf '0\n' >"${invalid_attempts_file}"
    dig() {
        [[ " $* " == *" @1.1.1.1 "* ]] || return 98
        printf '104.16.1.1\n'
    }
    sleep() { :; }
    curl() {
        local body_file="" invalid=0 source=0 resolved=0 attempts
        while (($#)); do
            case "$1" in
                --resolve) resolved=1; shift ;;
                -o) body_file=$2; shift ;;
                *token=invalid*) invalid=1 ;;
                "https://${VLESS_CDN_DOMAIN}/subscribe") source=1 ;;
            esac
            shift
        done
        if ((source)); then
            printf 404
        elif ((invalid)); then
            attempts=$(( $(<"${invalid_attempts_file}") + 1 ))
            printf '%s\n' "${attempts}" >"${invalid_attempts_file}"
            if ((attempts == 1)); then
                printf 000
                return 28
            fi
            ((resolved == 1)) || return 97
            printf 403
        else
            printf 'vless://test-node' | openssl base64 -A >"${body_file}"
            printf 200
        fi
    }
    cloudflare_validate_subscription_worker
    assert_equal "Invalid-token transport failure is retried once" \
        "2" "$(<"${invalid_attempts_file}")"
)

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
        "${rollback_output}" $'worker\tnew-worker-domain-id\teasyall'
    assert_contains "Rollback removes only a rule recorded during this run" \
        "${rollback_output}" $'rule\texisting-ruleset\tnew-rule-ref'
    assert_contains "Rollback removes the newly created ruleset" \
        "${rollback_output}" '/zones/test-zone-id/rulesets/new-ruleset-id'
    assert_contains "Rollback removes the newly created certificate" \
        "${rollback_output}" '/certificates/new-origin-cert-id'
    assert_contains "Rollback removes the newly created DNS record" \
        "${rollback_output}" '/dns_records/new-dns-record-id'
    : >"${rollback_calls}"
    CLOUDFLARE_WORKER_CREATED=0
    CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=new-domain-on-existing-worker
    cloudflare_rollback_fresh_install_resources
    assert_contains "Rollback detaches only the new domain on a reused Worker" \
        "$(<"${rollback_calls}")" '/workers/domains/new-domain-on-existing-worker'
    assert_not_contains "Rollback never deletes the reused Worker" "$(<"${rollback_calls}")" $'worker\t'
    unset CLOUDFLARE_CREATED_WORKER_DOMAIN_ID
    : >"${rollback_calls}"
    cloudflare_rollback_fresh_install_resources
    assert_not_contains "Existing Worker domain survives rollback" "$(<"${rollback_calls}")" '/workers/domains/'
    CLOUDFLARE_WORKER_CREATED=1
    : >"${rollback_calls}"
    cloudflare_delete_subscription_worker_resources() { exit 1; }
    if cloudflare_rollback_fresh_install_resources >"${TMP_DIR}/rollback-failure" 2>&1; then
        fail "Incomplete rollback must report failure"
    fi
    assert_contains "Rollback continues after Worker deletion exits" \
        "$(<"${rollback_calls}")" '/dns_records/new-dns-record-id'
    assert_not_contains "Incomplete rollback must not claim success" \
        "$(<"${TMP_DIR}/rollback-failure")" '资源已回滚'
)

# Cloudflare configuration must not expose a zone-wide prefix cleanup hook.
if declare -F cloudflare_cleanup_stale_header_rules >/dev/null 2>&1; then
    fail "Cloudflare must not scan and delete rules owned by other deployments"
fi

version_dir="${TMP_DIR}/version-test"
mkdir -p "${version_dir}"
printf 'v25.9.30\n' >"${version_dir}/version"
installed_version=$(env XRAY_DIR="${version_dir}" bash -c \
    'source "$1"; xray_installed_version' _ "${CORE_LIB}")
assert_equal "Xray version helper reads the installed version" "v25.9.30" "${installed_version}"
status_output=$(
    require_root() { :; }
    collect_installed_state() { :; }
    show_bbrv3_status() { printf 'BBRv3: active\n'; }
    show_globalping_status() { printf 'Globalping: active\n'; }
    show_quota_status() { printf '配额: active\n'; }
    xray_installed_version() { printf 'v25.9.30\n'; }
    worker_backup_enabled() { return 1; }
    systemctl() { [[ "${1:-}" == "is-active" ]]; }
    ss() { printf 'LISTEN\n'; }
    show_status
)
assert_contains "Cloudflare status reports the installed Xray version" \
    "${status_output}" '后端: Xray (v25.9.30)'
assert_contains "Cloudflare status reports BBRv3" "${status_output}" 'BBRv3: active'
assert_contains "Cloudflare status reports Xray health" "${status_output}" '核心服务: active'
assert_contains "Cloudflare status reports backend listener health" \
    "${status_output}" '后端 TCP 10086: listening'
assert_contains "Cloudflare status reports Nginx health" "${status_output}" 'Nginx: active'
assert_contains "Cloudflare status reports quota health" "${status_output}" '配额: active'

# Subscription acceptance must fail closed when the quota usage file cannot be read
# instead of treating the failure as "all quota users are disabled".
if (
    eval "${original_validate_subscription_runtime}"
    xhttp_validate_local_tls_curl_args() { :; }
    validate_subscription_token_rejection() { :; }
    quota_enabled() { return 0; }
    quota_active_accounts_json() { return 1; }
    die() { exit 1; }
    XHTTP_ORIGIN_DOMAIN=x
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    validate_subscription_runtime
); then
    fail "subscription acceptance must fail when quota accounts cannot be read"
fi

# Origin CA reuse must keep the Cloudflare metadata that save_state persists,
# otherwise the state loses the certificate ID that renew and uninstall resolve.
origin_certificate_body=$(sed -n '/^cloudflare_issue_origin_certificate()/,/^}/p' "${PROFILE}")
assert_contains "Cloudflare certificate reuse consults the metadata-aware predicate" \
    "${origin_certificate_body}" 'cloudflare_origin_certificate_is_reusable; then'
# Reaching the API token lookup proves the certificate is being reissued.
if ! (
    CLOUDFLARE_ORIGIN_CERT_ID="test-origin-cert-id"
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2035-01-01T00:00:00Z"
    cloudflare_ensure_origin_ca_root() { :; }
    cloudflare_origin_certificate_is_current() { return 0; }
    cloudflare_collect_api_token() { exit 9; }
    cloudflare_issue_origin_certificate 0
); then
    fail "a current certificate with stored metadata must be reused without an API call"
fi
if (
    CLOUDFLARE_ORIGIN_CERT_ID=""
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=""
    cloudflare_ensure_origin_ca_root() { :; }
    cloudflare_origin_certificate_is_current() { return 0; }
    cloudflare_collect_api_token() { exit 9; }
    cloudflare_issue_origin_certificate 0
); then
    fail "a current certificate without stored Cloudflare metadata must be reissued"
fi
if (
    CLOUDFLARE_ORIGIN_CERT_ID="test-origin-cert-id"
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2035-01-01T00:00:00Z"
    cloudflare_ensure_origin_ca_root() { :; }
    cloudflare_origin_certificate_is_current() { return 0; }
    cloudflare_collect_api_token() { exit 9; }
    cloudflare_issue_origin_certificate 1
); then
    fail "forced rotation must not reuse the current certificate"
fi

printf 'ok - Cloudflare pure XHTTP stream-up (Mode 2) tests passed\n'
