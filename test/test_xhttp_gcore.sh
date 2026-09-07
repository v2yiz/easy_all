#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/xhttp-gcore.sh"
IP_POOL_LIB="${ROOT_DIR}/lib/gcore-ip-pool.sh"
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
bash -n "${PROFILE}" "${IP_POOL_LIB}" "${CORE_LIB}"

# 2. Source modules in isolated environment
export STATE_DIR="${TMP_DIR}/state"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export XRAY_DIR="${TMP_DIR}/xray"
export XRAY_BIN="${TMP_DIR}/xray/xray"
export XRAY_CONFIG="${TMP_DIR}/xray/config.json"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/cert.pem"
export KEY_FILE="${CERT_DIR}/key.pem"
unset FULLCHAIN_FILE
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export STATE_FILE="${STATE_DIR}/state.env"
export EASY_ALL_STATE_FILE_OVERRIDE="${STATE_DIR}/state.env"
export VLESS_CDN_DOMAIN="node.example.com"
export GCORE_ORIGIN_DOMAIN="origin.example.com"
export VLESS_UUID="11111111-2222-4111-8111-111111111111"
export WEBSOCKET_PATH="/ws-test-path"
export XHTTP_PATH="/xhttp-test-path"
export XRAY_WEBSOCKET_LOOPBACK_PORT=10087
export XRAY_XHTTP_LOOPBACK_PORT=10086
export ALLOWED_TOKENS='{"owner":"test-token-12345"}'
export SUB_DOWNLOAD_NAME="TEST_SUB"
export SUBSCRIPTION_MODE="deploy"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"
export GLOBALPING_CACHE_FILE_OVERRIDE="${STATE_DIR}/gcore-cdn-ips.json"
export CDN_CLIENT_IP_FAMILY="ipv4"
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

cat >"${XRAY_BIN}" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "${XRAY_BIN}"

# shellcheck source=/dev/null
source "${PROFILE}"

# Certificate installation must use the same full chain as Nginx, without FULLCHAIN_FILE.
(
    write_cert_reload_hook() { :; }
    install_acme() { :; }
    install() { :; }
    chmod() { :; }
    acme_install_args=""
    run_acme() {
        if [[ "$1" == "--install-cert" ]]; then
            acme_install_args="$*"
        fi
    }
    issue_origin_certificate
    assert_contains "ACME installs Nginx full chain" "${acme_install_args}" "--fullchain-file ${CERT_FILE}"
    assert_contains "ACME installs private key" "${acme_install_args}" "--key-file ${KEY_FILE}"
    assert_not_contains "Leaf certificate must not overwrite full chain" "${acme_install_args}" "--cert-file"
)

# 3. Test gcore_select_carrier_candidates ranking and label assignment
observations_file="${TMP_DIR}/observations.ndjson"
cat >"${observations_file}" <<'EOF'
{"ip":"92.223.76.20","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":45.2,"tls_verified":true}
{"ip":"92.223.76.22","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":38.5,"tls_verified":true}
{"ip":"92.223.76.26","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":55.1,"tls_verified":false}
{"ip":"31.184.207.6","carrier_asn":4837,"carrier":"unicom","region":"JP","avg_rtt_ms":62.1,"tls_verified":true}
{"ip":"31.184.207.8","carrier_asn":4837,"carrier":"unicom","region":"JP","avg_rtt_ms":58.3,"tls_verified":true}
{"ip":"31.184.207.9","carrier_asn":4837,"carrier":"unicom","region":"JP","avg_rtt_ms":70.0,"tls_verified":true}
{"ip":"92.223.120.132","carrier_asn":4134,"carrier":"telecom","region":"LA","avg_rtt_ms":135.2,"tls_verified":true}
{"ip":"92.223.120.138","carrier_asn":4134,"carrier":"telecom","region":"LA","avg_rtt_ms":140.5,"tls_verified":true}
{"ip":"92.223.120.143","carrier_asn":4134,"carrier":"telecom","region":"LA","avg_rtt_ms":128.0,"tls_verified":true}
EOF

candidates_json=$(gcore_select_carrier_candidates "${observations_file}" 2 6)
assert_equal "6 candidates selected (2 per carrier)" "6" "$(jq 'length' <<<"${candidates_json}")"

# Verify mobile candidates (HK)
assert_equal "Candidate 1 is 92.223.76.22 (lowest latency 38.5ms)" "92.223.76.22" \
    "$(jq -r '.[] | select(.label == "1") | .ip' <<<"${candidates_json}")"
assert_equal "Candidate 2 is 92.223.76.20 (45.2ms)" "92.223.76.20" \
    "$(jq -r '.[] | select(.label == "2") | .ip' <<<"${candidates_json}")"

# Verify unicom candidates (JP)
assert_equal "Candidate 3 is 31.184.207.8 (58.3ms)" "31.184.207.8" \
    "$(jq -r '.[] | select(.label == "3") | .ip' <<<"${candidates_json}")"
assert_equal "Candidate 4 is 31.184.207.6 (62.1ms)" "31.184.207.6" \
    "$(jq -r '.[] | select(.label == "4") | .ip' <<<"${candidates_json}")"

# Verify telecom candidates (LA)
assert_equal "Candidate 5 is 92.223.120.143 (128.0ms)" "92.223.120.143" \
    "$(jq -r '.[] | select(.label == "5") | .ip' <<<"${candidates_json}")"
assert_equal "Candidate 6 is 92.223.120.132 (135.2ms)" "92.223.120.132" \
    "$(jq -r '.[] | select(.label == "6") | .ip' <<<"${candidates_json}")"

# 3b. Test historical bonus and primary region advantage
obs_advanced="${TMP_DIR}/obs_adv.ndjson"
cat >"${obs_advanced}" <<'EOF'
{"ip":"1.1.1.1","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":48.0,"tls_verified":true}
{"ip":"1.1.1.2","carrier_asn":9808,"carrier":"mobile","region":"JP","avg_rtt_ms":40.0,"tls_verified":true}
{"ip":"2.2.2.1","carrier_asn":4837,"carrier":"unicom","region":"JP","avg_rtt_ms":55.0,"tls_verified":true}
{"ip":"2.2.2.2","carrier_asn":4837,"carrier":"unicom","region":"JP","avg_rtt_ms":52.0,"tls_verified":true}
{"ip":"3.3.3.1","carrier_asn":4134,"carrier":"telecom","region":"LA","avg_rtt_ms":130.0,"tls_verified":true}
{"ip":"3.3.3.2","carrier_asn":4134,"carrier":"telecom","region":"LA","avg_rtt_ms":135.0,"tls_verified":true}
EOF

# For mobile:
# 1.1.1.1 is HK (primary): effective score = 48.0
# 1.1.1.2 is JP (cross): raw 40.0, but penalized +10ms = 50.0
# Therefore 1.1.1.1 (score 48.0) should beat 1.1.1.2 (score 50.0) despite higher raw latency
adv_json=$(gcore_select_carrier_candidates "${obs_advanced}" 2 6)
assert_equal "Primary region advantage: 1.1.1.1 (HK, raw 48ms) beats 1.1.1.2 (JP cross, raw 40ms + 10ms penalty)" \
    "1.1.1.1" "$(jq -r '.[] | select(.label == "1") | .ip' <<<"${adv_json}")"

# Now test historical winner 5ms bonus:
# 2.2.2.1 is historical winner in previous cache:
hist_cache="${TMP_DIR}/hist_cache.json"
cat >"${hist_cache}" <<'EOF'
{
  "candidates": [
    {"ip": "2.2.2.1", "label": "3", "carrier": "unicom"}
  ]
}
EOF
# 2.2.2.1 raw = 55.0, with -5ms bonus => 50.0
# 2.2.2.2 raw = 52.0 => 52.0
# With bonus, 2.2.2.1 should be ranked #3 ahead of 2.2.2.2
adv_hist_json=$(gcore_select_carrier_candidates "${obs_advanced}" 2 6 "${hist_cache}")
assert_equal "Historical winner bonus: 2.2.2.1 gets -5ms bonus and beats 2.2.2.2" \
    "2.2.2.1" "$(jq -r '.[] | select(.label == "3") | .ip' <<<"${adv_hist_json}")"

# 3c. Test gcore_limit_pool_to_globalping_budget balancing
pool_file="${TMP_DIR}/test_pool.tsv"
budgeted_pool="${TMP_DIR}/budgeted_pool.tsv"
cat >"${pool_file}" <<'EOF'
10.0.1.1	9808	mobile	HK
10.0.1.2	9808	mobile	HK
10.0.1.3	9808	mobile	HK
10.0.1.4	9808	mobile	HK
10.0.2.1	4837	unicom	JP
10.0.2.2	4837	unicom	JP
10.0.2.3	4837	unicom	JP
10.0.3.1	4134	telecom	LA
10.0.3.2	4134	telecom	LA
EOF
# Mock globalping_api_request to return remaining=12 (reserve 3 => tcp_budget=9 => 3 per carrier)
globalping_api_request() {
    if [[ "$1" == "GET" && "$2" == "/limits" ]]; then
        printf '{"rateLimit":{"measurements":{"create":{"remaining":9}}}}'
        return 0
    fi
    return 1
}
# Remaining 9, reserve 3 => tcp_budget 6 => 2 per carrier
gcore_limit_pool_to_globalping_budget "${pool_file}" "${budgeted_pool}"
mobile_count=$(awk -F'\t' '$2=="9808"{c++} END{print c+0}' "${budgeted_pool}")
unicom_count=$(awk -F'\t' '$2=="4837"{c++} END{print c+0}' "${budgeted_pool}")
telecom_count=$(awk -F'\t' '$2=="4134"{c++} END{print c+0}' "${budgeted_pool}")
assert_equal "Multi-carrier budget balanced: mobile has 2 candidates" "2" "${mobile_count}"
assert_equal "Multi-carrier budget balanced: unicom has 2 candidates" "2" "${unicom_count}"
assert_equal "Multi-carrier budget balanced: telecom has 2 candidates" "2" "${telecom_count}"
unset -f globalping_api_request

# 3d. Test gcore_parse_tls_observations status code and TLS authorized requirements
sample_tls_file="${TMP_DIR}/sample_tls.ndjson"
cat >"${sample_tls_file}" <<'EOF'
{"ip":"10.1.1.1","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":40.0,"measurement":{"status":"finished","results":[{"result":{"status":"finished","statusCode":101,"tls":{"protocol":"TLSv1.3","authorized":true}}}]}}
{"ip":"10.1.1.2","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":42.0,"measurement":{"status":"finished","results":[{"result":{"status":"finished","statusCode":502,"tls":{"protocol":"TLSv1.3","authorized":true}}}]}}
{"ip":"10.1.1.3","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":44.0,"measurement":{"status":"finished","results":[{"result":{"status":"finished","statusCode":101,"tls":{"protocol":"TLSv1.3","authorized":false,"error":"UNABLE_TO_VERIFY_LEAF_SIGNATURE"}}}]}}
{"ip":"10.1.1.4","carrier_asn":9808,"carrier":"mobile","region":"HK","avg_rtt_ms":46.0,"measurement":{"status":"finished","results":[{"result":{"status":"finished","statusCode":200,"tls":{"protocol":"TLSv1.3","authorized":false,"error":"ERR_TLS_CERT_ALTNAME_INVALID"}}}]}}
EOF
parsed_tls=$(gcore_parse_tls_observations "${sample_tls_file}")
assert_equal "10.1.1.1 with 101 and authorized TLS is selected" "10.1.1.1" \
    "$(jq -r 'select(.ip == "10.1.1.1") | .ip' <<<"${parsed_tls}")"
assert_equal "10.1.1.4 with ALTNAME_INVALID probe error is selected" "10.1.1.4" \
    "$(jq -r 'select(.ip == "10.1.1.4") | .ip' <<<"${parsed_tls}")"
assert_equal "10.1.1.2 with 502 is filtered out" "" \
    "$(jq -r 'select(.ip == "10.1.1.2") | .ip' <<<"${parsed_tls}")"
assert_equal "10.1.1.3 with unauthorized cert is filtered out" "" \
    "$(jq -r 'select(.ip == "10.1.1.3") | .ip' <<<"${parsed_tls}")"


# 4. Write valid cache file and test cache validation
now_epoch=$(date +%s)
cat >"${GLOBALPING_CACHE_FILE}" <<EOF
{
  "version": 1,
  "provider": "gcore",
  "domain": "${VLESS_CDN_DOMAIN}",
  "candidate_source": "gcore-official-public-ip-list",
  "measured_at": "2026-09-07T00:00:00Z",
  "measured_at_epoch": ${now_epoch},
  "probe_country": "CN",
  "probe_type": "eyeball-network",
  "carrier_asns": [9808, 4837, 4134],
  "candidates": ${candidates_json}
}
EOF

gcore_globalping_cache_valid || fail "gcore_globalping_cache_valid should succeed for valid cache"
globalping_cache_valid || fail "shared cache hook should recognize valid Gcore cache"
systemctl() { :; }
assert_contains "Shared status recognizes Gcore cache" "$(show_globalping_status)" 'enabled，6 个'

# 5. Verify NO domain fallback in client candidates
candidates_output=$(gcore_client_candidates)
assert_not_contains "gcore_client_candidates must never emit fallback domain" \
    "${candidates_output}" "${VLESS_CDN_DOMAIN}"
candidate_lines=$(wc -l <<<"${candidates_output}" | tr -d ' ')
assert_equal "Strictly 6 candidate lines" "6" "${candidate_lines}"

# 6. Test build_node_links and build_mihomo_nodes
links_output=$(build_node_links)
assert_contains "Links output contains 优选1" "${links_output}" "#$(jq -nr --arg v '优选1' '$v|@uri')"
assert_contains "Links output contains 优选6" "${links_output}" "#$(jq -nr --arg v '优选6' '$v|@uri')"
assert_not_contains "Links output does not contain 优选7" "${links_output}" "#$(jq -nr --arg v '优选7' '$v|@uri')"
assert_contains "Links output uses websocket protocol" "${links_output}" "type=ws"
assert_not_contains "Links output has no domain fallback" "${links_output}" "fallback"

mihomo_nodes_output=$(build_mihomo_nodes)
assert_contains "Mihomo nodes contain 优选1" "${mihomo_nodes_output}" '"优选1"'
assert_contains "Mihomo nodes contain 优选6" "${mihomo_nodes_output}" '"优选6"'
assert_contains "Mihomo nodes contain ws network" "${mihomo_nodes_output}" "network: ws"
assert_contains "Mihomo nodes contain path" "${mihomo_nodes_output}" "path: \"${WEBSOCKET_PATH}\""
assert_contains "Mihomo nodes contain host header" "${mihomo_nodes_output}" "Host: \"${VLESS_CDN_DOMAIN}\""

# 7. Test write_subscriptions
write_subscriptions
sub_base64="${TMP_DIR}/web/subscriptions/base64.txt"
sub_mihomo="${TMP_DIR}/web/subscriptions/mihomo.yaml"
[[ -s "${sub_base64}" ]] || fail "Base64 subscription file missing"
[[ -s "${sub_mihomo}" ]] || fail "Mihomo subscription file missing"

base64_decoded=$(base64 -d <"${sub_base64}")
assert_contains "Base64 subscription has 优选1" "${base64_decoded}" "#$(jq -nr --arg v '优选1' '$v|@uri')"
assert_contains "Base64 subscription has 优选6" "${base64_decoded}" "#$(jq -nr --arg v '优选6' '$v|@uri')"
assert_not_contains "Base64 subscription has NO domain fallback" "${base64_decoded}" "${VLESS_CDN_DOMAIN}#"

mihomo_content=$(<"${sub_mihomo}")
assert_contains "Mihomo subscription has AUTO proxy group" "${mihomo_content}" 'name: "AUTO"'
assert_contains "Mihomo subscription AUTO group contains 优选1" "${mihomo_content}" '"优选1"'
assert_contains "Mihomo subscription AUTO group contains 优选6" "${mihomo_content}" '"优选6"'
assert_not_contains "Mihomo subscription has NO domain node" "${mihomo_content}" 'server: "node.example.com"'

# 8. Test Xray and Nginx config generation
xhttp_render_xray_config
xray_conf_file="${TMP_DIR}/state/xray/config.json"
[[ -s "${xray_conf_file}" ]] || fail "Xray config not generated"
xray_cfg=$(<"${xray_conf_file}")
assert_contains "Xray has WebSocket inbound" "${xray_cfg}" '"tag": "vless-websocket-in"'
assert_contains "Xray has XHTTP packet-up inbound" "${xray_cfg}" '"tag": "vless-xhttp-h2-in"'
assert_contains "Xray XHTTP uses packet-up mode" "${xray_cfg}" '"mode": "packet-up"'

nginx() { :; }
systemctl() { :; }
write_nginx_config
nginx_conf_file="${TMP_DIR}/nginx.conf"
[[ -s "${nginx_conf_file}" ]] || fail "Nginx config not generated"
nginx_cfg=$(<"${nginx_conf_file}")
assert_contains "Nginx verifies Gcore client cert" "${nginx_cfg}" "ssl_verify_client on;"
assert_contains "Nginx has easy_all-health location" "${nginx_cfg}" "location = /easy_all-health"
assert_contains "Nginx proxies WebSocket backend" "${nginx_cfg}" "proxy_pass http://gcore_websocket_backend;"
assert_contains "Nginx proxies XHTTP backend" "${nginx_cfg}" "proxy_pass http://gcore_xhttp_backend;"

# 9. Test path normalizers
assert_equal "normalize_websocket_path cleans double /ws- prefix" \
    "/ws-0123456789abcdef" "$(normalize_websocket_path "/ws-/ws-0123456789abcdef")"
assert_equal "normalize_websocket_path keeps clean /ws- intact" \
    "/ws-0123456789abcdef" "$(normalize_websocket_path "/ws-0123456789abcdef")"
assert_equal "normalize_xhttp_path cleans double /xhttp- prefix" \
    "/xhttp-0123456789abcdef" "$(normalize_xhttp_path "/xhttp-/xhttp-0123456789abcdef")"
assert_equal "normalize_xhttp_path keeps clean /xhttp- intact" \
    "/xhttp-0123456789abcdef" "$(normalize_xhttp_path "/xhttp-0123456789abcdef")"

# 10. Test save_state and load_state
export GCORE_DNS_ZONE="example.com"
export GCORE_CDN_TARGET="cl-test.gcdn.co"
export GCORE_CDN_RESOURCE_ID="12345"
export GCORE_ORIGIN_GROUP_ID="67890"
export GCORE_ORIGIN_CLIENT_CERT_ID="11223"
export GCORE_ORIGIN_CA_ID="44556"
export VPS_PUBLIC_IPV4="198.51.100.1"

save_state
[[ -s "${EASY_ALL_STATE_FILE_OVERRIDE}" ]] || fail "State file was not saved"
state_content=$(<"${EASY_ALL_STATE_FILE_OVERRIDE}")
assert_contains "State file protocol is gcore" "${state_content}" 'PROTOCOL=gcore'
assert_contains "State file backend is xray" "${state_content}" 'BACKEND=xray'
assert_contains "State file cdn is gcore" "${state_content}" 'CDN_PROVIDER=gcore'
assert_contains "State file has origin domain" "${state_content}" 'GCORE_ORIGIN_DOMAIN=origin.example.com'
assert_contains "State file has CDN domain" "${state_content}" 'VLESS_CDN_DOMAIN=node.example.com'
assert_contains "State file has CNAME target" "${state_content}" 'GCORE_CDN_TARGET=cl-test.gcdn.co'

# Reset vars and load_state
unset VLESS_CDN_DOMAIN GCORE_ORIGIN_DOMAIN GCORE_CDN_TARGET
load_state
assert_equal "load_state restored VLESS_CDN_DOMAIN" "node.example.com" "${VLESS_CDN_DOMAIN}"
assert_equal "load_state restored GCORE_ORIGIN_DOMAIN" "origin.example.com" "${GCORE_ORIGIN_DOMAIN}"
assert_equal "load_state restored GCORE_CDN_TARGET" "cl-test.gcdn.co" "${GCORE_CDN_TARGET}"
assert_equal "load_state restored XHTTP_ORIGIN_DOMAIN" "origin.example.com" "${XHTTP_ORIGIN_DOMAIN}"

# Verify mihomo_transport_marker
assert_equal "mihomo_transport_marker is network: ws" "network: ws" "$(mihomo_transport_marker)"

# Verify xhttp_validate_local_tls_curl_args
xhttp_validate_local_tls_curl_args
assert_equal "curl args include client cert" "${GCORE_CLIENT_CERT_FILE}" "${XHTTP_LOCAL_TLS_CURL_ARGS[3]}"
assert_equal "curl args include client key" "${GCORE_CLIENT_CERT_KEY}" "${XHTTP_LOCAL_TLS_CURL_ARGS[5]}"

# 11. Test gcore_find_zone_for_domain with envelope formats
gcore_api_request() {
    if [[ "$1" == "GET" && "$2" == "/dns/v2/zones" ]]; then
        printf '{"zones":[{"name":"1988088.xyz","id":123}],"total_amount":1}'
        return 0
    fi
    return 1
}
found_zone=$(gcore_find_zone_for_domain "origin.1988088.xyz")
assert_equal "gcore_find_zone_for_domain matches zone with zones envelope" "1988088.xyz" "${found_zone}"
found_sub_zone=$(gcore_find_zone_for_domain "deep.sub.1988088.xyz")
assert_equal "gcore_find_zone_for_domain matches deep sub-domain" "1988088.xyz" "${found_sub_zone}"
# 12. Test gcore_ensure_origin_a_record and gcore_ensure_cdn_cname_record payload
recorded_calls=()
gcore_api_request() {
    recorded_calls+=("$1 $2 $3")
    return 0
}

GCORE_DNS_ZONE="1988088.xyz"
GCORE_ORIGIN_DOMAIN="origin.1988088.xyz"
VPS_PUBLIC_IPV4="192.129.209.51"
gcore_ensure_origin_a_record

assert_equal "A record call count" "1" "${#recorded_calls[@]}"
a_call="${recorded_calls[0]}"
assert_contains "A record method and url" "${a_call}" "PUT /dns/v2/zones/1988088.xyz/origin.1988088.xyz/A"
a_payload="${a_call#PUT /dns/v2/zones/1988088.xyz/origin.1988088.xyz/A }"
assert_equal "A record payload IP" "192.129.209.51" "$(jq -r '.resource_records[0].content[0]' <<<"${a_payload}")"
assert_equal "A record payload TTL" "300" "$(jq -r '.ttl' <<<"${a_payload}")"

VLESS_CDN_DOMAIN="node.1988088.xyz"
GCORE_CDN_TARGET="cl-test.gcdn.co"
gcore_ensure_cdn_cname_record

assert_equal "Total record calls" "2" "${#recorded_calls[@]}"
cname_call="${recorded_calls[1]}"
assert_contains "CNAME record method and url" "${cname_call}" "PUT /dns/v2/zones/1988088.xyz/node.1988088.xyz/CNAME"
cname_payload="${cname_call#PUT /dns/v2/zones/1988088.xyz/node.1988088.xyz/CNAME }"
assert_equal "CNAME record payload target" "cl-test.gcdn.co" "$(jq -r '.resource_records[0].content[0]' <<<"${cname_payload}")"
assert_equal "CNAME record payload TTL" "300" "$(jq -r '.ttl' <<<"${cname_payload}")"

unset -f gcore_api_request

# Request contracts checked against G-Core/gcore-python OpenAPI-generated CDN types.
(
    api_calls="${TMP_DIR}/cdn-api-calls"
    existing=false
    reject_update=false
    gcore_api_request() {
        printf '%s %s\n' "$1" "$2" >>"${api_calls}"
        case "$1 $2" in
        'GET /cdn/origin_groups')
            if [[ "${existing}" == true ]]; then
                jq -cn --arg name "$(gcore_origin_group_name)" '[{id:101,name:$name}]'
            else printf '[]'; fi ;;
        'POST /cdn/origin_groups')
            jq -e --arg origin "${GCORE_ORIGIN_DOMAIN}" '
                has("origins") == false and .use_next == false and
                .sources == [{source:$origin,enabled:true,backup:false}]
            ' <<<"$3" >/dev/null || return 1
            printf '{"id":101}' ;;
        'GET /cdn/resources')
            if [[ "${existing}" == true ]]; then
                jq -cn --arg cname "${VLESS_CDN_DOMAIN}" '[{id:202,cname:$cname}]'
            else printf '[]'; fi ;;
        'POST /cdn/resources'|'PUT /cdn/resources/202')
            [[ "${reject_update}" == false ]] || return 1
            jq -e --arg origin "${GCORE_ORIGIN_DOMAIN}" '
                .originGroup == 101 and .originProtocol == "HTTPS" and
                .proxy_ssl_enabled == true and .proxy_ssl_data == 11223 and .proxy_ssl_ca == 44556 and
                .options.websockets == {enabled:true,value:true} and
                .options.sni == {enabled:true,sni_type:"custom",custom_hostname:$origin} and
                .options.redirect_http_to_https == {enabled:true,value:true} and
                .options.ignoreQueryString == {enabled:true,value:false} and
                .options.slice == {enabled:true,value:false} and
                .options.edge_cache_settings.value == "0s" and
                (.options | has("origin_ssl_validation") or has("force_ssl") or has("proxy_cache") or has("ignore_query_string")) == false
            ' <<<"$3" >/dev/null || return 1
            printf '{"id":202}' ;;
        *) return 1 ;;
        esac
    }
    gcore_ensure_origin_group
    assert_equal "Created origin group ID" 101 "${GCORE_ORIGIN_GROUP_ID}"
    gcore_ensure_resource
    assert_equal "Created resource ID" 202 "${GCORE_CDN_RESOURCE_ID}"
    existing=true
    gcore_ensure_origin_group
    gcore_ensure_resource
    assert_equal "Existing group is reused" 1 "$(grep -c '^POST /cdn/origin_groups$' "${api_calls}")"
    assert_equal "Existing resource is updated" 1 "$(grep -c '^PUT /cdn/resources/202$' "${api_calls}")"
    reject_update=true
    if gcore_ensure_resource; then fail "Resource update failure must propagate"; fi
)

printf 'ok - Gcore Mode 3 unit tests passed\n'
