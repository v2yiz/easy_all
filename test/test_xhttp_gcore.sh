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
export GCORE_SUBSCRIPTION_DNS_ZONE="example.com"
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
export GCORE_DNS_PROPAGATION_ATTEMPTS_OVERRIDE=3
export GCORE_DNS_PROPAGATION_INTERVAL_OVERRIDE=0
export GCORE_EDGE_PROPAGATION_ATTEMPTS_OVERRIDE=3
export GCORE_EDGE_PROPAGATION_INTERVAL_OVERRIDE=0
export GCORE_PRECHECK_READY_ATTEMPTS_OVERRIDE=3
export GCORE_PRECHECK_READY_INTERVAL_OVERRIDE=0
export GCORE_DNS_PROBES_PER_REGION_OVERRIDE=2
export GCORE_DNS_AUX_PROBES_PER_REGION_OVERRIDE=1
export GCORE_DNS_CARRIER_PROBES_OVERRIDE=1
export GCORE_DNS_RESOLVER_PROBES_PER_REGION_OVERRIDE=1
export GCORE_DNS_HISTORY_MAX_AGE_SECONDS_OVERRIDE=7200

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
trap 'status=$?; cleanup; command rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

# Regional DNS discovery must use real CDN hostname answers, not origin ACL IPs.
dns_request=$(gcore_globalping_dns_measurement_request "${VLESS_CDN_DOMAIN}")
assert_equal "Gcore DNS discovery targets the CDN hostname" "${VLESS_CDN_DOMAIN}" \
    "$(jq -r '.target' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery uses the DNS measurement type" "dns" \
    "$(jq -r '.type' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery requests A records" "A" \
    "$(jq -r '.measurementOptions.query.type' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery covers requested regional and China-carrier perspectives" "14" \
    "$(jq '.locations | length' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery uses more core probes" "true" \
    "$(jq '[.locations[] | select(
        .country=="HK" or .country=="TW" or .country=="JP"
        or .country=="SG" or .city=="Los Angeles"
      ) | .limit] == [2,2,2,2,2]' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery is restricted to the requested countries" \
    '["CN","HK","JP","SG","TW","US"]' \
    "$(jq -c '[.locations[].country] | unique' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery covers the US west coast" \
    '["Fremont","Los Angeles","Portland","San Francisco","San Jose","Santa Clara","Seattle"]' \
    "$(jq -c '[.locations[] | select(.country=="US") | .city] | sort' <<<"${dns_request}")"
assert_equal "Gcore DNS discovery includes all China carrier ASNs" \
    '[4134,4837,9808]' \
    "$(jq -c '[.locations[] | select(.country=="CN") | .asn] | sort' <<<"${dns_request}")"
resolver_request=$(gcore_globalping_dns_measurement_request \
    "${VLESS_CDN_DOMAIN}" "1.1.1.1" core)
assert_equal "Resolver-specific discovery uses Cloudflare DNS" "1.1.1.1" \
    "$(jq -r '.measurementOptions.resolver' <<<"${resolver_request}")"
assert_equal "Resolver-specific discovery uses compact core locations" "7" \
    "$(jq '.locations | length' <<<"${resolver_request}")"

dns_measurement="${TMP_DIR}/gcore-dns-measurement.json"
cat >"${dns_measurement}" <<'EOF'
{
  "status": "finished",
  "results": [
    {
      "probe": {"country": "HK", "city": "Hong Kong"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [
          {"type": "CNAME", "value": "cl-test.gcdn.co."},
          {"type": "A", "value": "92.223.76.20"},
          {"type": "A", "value": "92.223.76.22"},
          {"type": "A", "value": "10.0.0.1"}
        ]
      }
    },
    {
      "probe": {"country": "JP", "city": "Tokyo"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [
          {"type": "A", "value": "31.184.207.6"},
          {"type": "A", "value": "31.184.207.8"}
        ]
      }
    },
    {
      "probe": {"country": "US", "state": "CA", "city": "Los Angeles"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [
          {"type": "A", "value": "92.223.120.132"},
          {"type": "A", "value": "92.223.120.138"}
        ]
      }
    },
    {
      "probe": {"country": "JP", "city": "Osaka"},
      "result": {
        "status": "failed",
        "statusCode": 2,
        "answers": [{"type": "A", "value": "31.184.207.9"}]
      }
    },
    {
      "probe": {"country": "KR", "city": "Seoul"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [{"type": "A", "value": "92.223.120.140"}]
      }
    },
    {
      "probe": {"country": "TW", "city": "Taipei"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [{"type": "A", "value": "92.223.120.141"}]
      }
    },
    {
      "probe": {"country": "SG", "city": "Singapore"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [{"type": "A", "value": "92.223.120.142"}]
      }
    },
    {
      "probe": {"country": "US", "state": "WA", "city": "Seattle"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [{"type": "A", "value": "92.223.120.144"}]
      }
    },
    {
      "probe": {"country": "CN", "asn": 9808, "city": "Guangzhou"},
      "result": {
        "status": "finished",
        "statusCode": 0,
        "answers": [{"type": "A", "value": "92.223.120.143"}]
      }
    }
  ]
}
EOF
dns_candidates=$(gcore_parse_globalping_dns_candidates "$(<"${dns_measurement}")")
assert_equal "Regional DNS parsing keeps ten unique public ingress IPs" "10" \
    "$(cut -f1 <<<"${dns_candidates}" | sort -u | wc -l | tr -d ' ')"
assert_equal "Hong Kong answers feed all three carrier checks" "3" \
    "$(awk -F'\t' '$1=="92.223.76.20"{c++} END{print c+0}' <<<"${dns_candidates}")"
assert_equal "Japan answers feed all three carrier checks" "3" \
    "$(awk -F'\t' '$1=="31.184.207.6"{c++} END{print c+0}' <<<"${dns_candidates}")"
assert_equal "China Mobile DNS answers retain their dedicated view" "CN-CM" \
    "$(awk -F'\t' '$1=="92.223.120.143" && $2=="9808"{print $4}' <<<"${dns_candidates}")"
assert_equal "Taiwan answers feed all three carrier checks" "3" \
    "$(awk -F'\t' '$1=="92.223.120.141"{c++} END{print c+0}' <<<"${dns_candidates}")"
assert_equal "Singapore answers feed all three carrier checks" "3" \
    "$(awk -F'\t' '$1=="92.223.120.142"{c++} END{print c+0}' <<<"${dns_candidates}")"
assert_equal "US west answers feed all three carrier checks" "3" \
    "$(awk -F'\t' '$1=="92.223.120.144"{c++} END{print c+0}' <<<"${dns_candidates}")"
assert_not_contains "Unrequested Korea answers are rejected" \
    "${dns_candidates}" "92.223.120.140"
assert_not_contains "Private DNS answers are rejected" "${dns_candidates}" "10.0.0.1"
assert_not_contains "Failed DNS probe answers are rejected" "${dns_candidates}" "31.184.207.9"

(
    dns_submissions="${TMP_DIR}/gcore-dns-submissions"
    : >"${dns_submissions}"
    globalping_api_request() {
        assert_equal "DNS discovery submits one measurement" \
            "POST /measurements" "$1 $2"
        assert_equal "Submitted discovery payload targets the CDN hostname" \
            "${VLESS_CDN_DOMAIN}" "$(jq -r '.target' <<<"$3")"
        resolver=$(jq -r '.measurementOptions.resolver // "probe-default"' <<<"$3")
        printf '%s\n' "${resolver}" >>"${dns_submissions}"
        jq -cn --arg id "dns-${resolver}" '{id:$id}'
    }
    gcore_wait_globalping_measurement() {
        cat "${dns_measurement}"
    }
    generated=$(gcore_generate_carrier_candidate_pool)
    assert_equal "DNS discovery orchestration returns parsed candidates" \
        "${dns_candidates}" "${generated}"
    assert_equal "DNS discovery submits default and two public resolver views" \
        $'probe-default\n1.1.1.1\n8.8.8.8' "$(<"${dns_submissions}")"
)

# DNS candidates survive hourly refreshes for the configured retention window.
history_now=100000
retained_dns="${TMP_DIR}/gcore-retained-dns.tsv"
cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{
  "version": 2,
  "provider": "gcore",
  "candidate_source": "gcore-globalping-regional-dns",
  "measured_at_epoch": 99000,
  "candidates": [
    {"ip":"92.223.76.20","carrier_asn":9808,"carrier":"mobile","region":"HK"}
  ]
}
EOF
gcore_load_retained_dns_candidates "${retained_dns}" "${history_now}"
assert_equal "Version 2 DNS cache migrates selected endpoints into history" \
    $'92.223.76.20\t9808\tmobile\tHK\t99000' "$(<"${retained_dns}")"

cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{
  "version": 3,
  "provider": "gcore",
  "candidate_source": "gcore-globalping-regional-dns",
  "measured_at_epoch": 100000,
  "discovered_candidates": [
    {"ip":"92.223.76.20","carrier_asn":9808,"carrier":"mobile","region":"HK","last_seen_epoch":99000},
    {"ip":"31.184.207.6","carrier_asn":4837,"carrier":"unicom","region":"JP","last_seen_epoch":92799},
    {"ip":"92.223.120.140","carrier_asn":4837,"carrier":"unicom","region":"KR","last_seen_epoch":99000}
  ]
}
EOF
gcore_load_retained_dns_candidates "${retained_dns}" "${history_now}"
assert_contains "Fresh DNS history is retained across hours" \
    "$(<"${retained_dns}")" $'92.223.76.20\t9808\tmobile\tHK\t99000'
assert_not_contains "Expired DNS history is removed" \
    "$(<"${retained_dns}")" "31.184.207.6"
assert_not_contains "Unrequested DNS regions are removed from history" \
    "$(<"${retained_dns}")" "92.223.120.140"

current_dns="${TMP_DIR}/gcore-current-dns.tsv"
merged_dns="${TMP_DIR}/gcore-merged-dns.tsv"
cat >"${current_dns}" <<'EOF'
92.223.76.20	9808	mobile	HK
92.223.120.132	4134	telecom	LA
EOF
gcore_merge_dns_candidate_history \
    "${current_dns}" "${retained_dns}" "${merged_dns}" "${history_now}"
assert_equal "Current DNS observations refresh their history timestamp" \
    "100000" "$(awk -F'\t' '$1=="92.223.76.20"{print $5}' "${merged_dns}")"
assert_equal "New DNS observations are added to rolling history" \
    "100000" "$(awk -F'\t' '$1=="92.223.120.132"{print $5}' "${merged_dns}")"
rm -f -- "${GLOBALPING_CACHE_FILE}"

# API wrappers must reject non-2xx responses even when the body lacks error/errors keys.
if (
    gcore_api_raw() { printf '{"message":"forbidden"}\n403'; }
    gcore_api_request GET "/cdn/resources"
) >/dev/null 2>&1; then
    fail "HTTP 403 must not be treated as a successful Gcore API response"
fi
(
    gcore_api_raw() { printf '{"items":[]}\n200'; }
    assert_equal "HTTP 200 returns only the response body" \
        '{"items":[]}' "$(gcore_api_request GET "/cdn/resources")"
)

# Delegation failure is a hard stop before provisioning.
if (
    gcore_api_request() {
        printf '{"zone_exists":true,"gcore_authorized_count":1,"non_gcore_authorized_count":1}'
    }
    gcore_verify_zone_delegation example.com
) >/dev/null 2>&1; then
    fail "Mixed authoritative DNS must fail delegation validation"
fi
(
    gcore_api_request() {
        printf '{"zone_exists":true,"gcore_authorized_count":2,"non_gcore_authorized_count":0}'
    }
    gcore_verify_zone_delegation example.com
)

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
# Mock globalping_api_request with enough budget for the complete prevalidated pool.
globalping_api_request() {
    if [[ "$1" == "GET" && "$2" == "/limits" ]]; then
        printf '{"rateLimit":{"measurements":{"create":{"remaining":9}}}}'
        return 0
    fi
    return 1
}
gcore_limit_pool_to_globalping_budget "${pool_file}" "${budgeted_pool}"
mobile_count=$(awk -F'\t' '$2=="9808"{c++} END{print c+0}' "${budgeted_pool}")
unicom_count=$(awk -F'\t' '$2=="4837"{c++} END{print c+0}' "${budgeted_pool}")
telecom_count=$(awk -F'\t' '$2=="4134"{c++} END{print c+0}' "${budgeted_pool}")
assert_equal "Available budget keeps all mobile candidates" "4" "${mobile_count}"
assert_equal "Available budget keeps all unicom candidates" "3" "${unicom_count}"
assert_equal "Multi-carrier budget balanced: telecom has 2 candidates" "2" "${telecom_count}"
unset -f globalping_api_request

# 3d. Zero-loss observations retain the local TLS/WebSocket verification marker.
sample_measurements_file="${TMP_DIR}/sample-measurements.ndjson"
cat >"${sample_measurements_file}" <<'EOF'
{"ip":"10.1.1.1","carrier_asn":9808,"carrier":"mobile","region":"HK","measurement":{"results":[{"probe":{"country":"CN","tags":["eyeball-network"],"asn":9808,"city":"Guangzhou","network":"CMCC"},"result":{"status":"finished","resolvedAddress":"10.1.1.1","stats":{"loss":0,"total":4,"rcv":4,"drop":0,"avg":40.0}}}]}}
{"ip":"10.1.1.2","carrier_asn":9808,"carrier":"mobile","region":"HK","measurement":{"results":[{"probe":{"country":"CN","tags":["eyeball-network"],"asn":9808},"result":{"status":"finished","resolvedAddress":"10.1.1.2","stats":{"loss":25,"total":4,"rcv":3,"drop":1,"avg":42.0}}}]}}
EOF
observations=$(gcore_zero_loss_observations "${sample_measurements_file}")
assert_equal "Zero-loss candidate retains local TLS verification" "true" \
    "$(jq -r 'select(.ip == "10.1.1.1") | .tls_verified' <<<"${observations}")"
assert_equal "Lossy candidate is filtered out" "" \
    "$(jq -r 'select(.ip == "10.1.1.2") | .ip' <<<"${observations}")"

# Local WebSocket candidate validation must force HTTP/1.1.
(
    curl_args_file="${TMP_DIR}/gcore-candidate-curl-args"
    curl() {
        printf '%s\n' "$*" >"${curl_args_file}"
        printf '101'
        return 28
    }
    gcore_validate_pool_candidate "92.223.76.20" \
        || fail "HTTP 101 must pass even when curl times out on the upgraded connection"
    assert_contains "WebSocket candidate validation forces HTTP/1.1" \
        "$(<"${curl_args_file}")" "--http1.1"
)

# Failed candidate probes must preserve curl's concrete TLS error.
(
    curl() {
        printf 'curl: (35) OpenSSL SSL_connect: SSL_ERROR_SYSCALL\n' >&2
        printf '000'
        return 35
    }
    if failed_probe=$(gcore_probe_pool_candidate "31.184.207.6"); then
        fail "TLS handshake failure must reject the candidate"
    fi
    assert_contains "Candidate probe classifies TLS handshake failures" \
        "${failed_probe}" $'35\t000\tTLS 握手失败'
    assert_contains "Candidate probe preserves curl error details" \
        "${failed_probe}" "SSL_ERROR_SYSCALL"
)

# Candidate prevalidation keeps successful records and summarizes failures.
(
    precheck_source="${TMP_DIR}/gcore-precheck-source.tsv"
    precheck_output="${TMP_DIR}/gcore-precheck-output.tsv"
    cat >"${precheck_source}" <<'EOF'
92.223.76.20	9808	mobile	HK
31.184.207.6	4837	unicom	JP
92.223.120.132	4134	telecom	LA
EOF
    gcore_probe_pool_candidate() {
        case "$1" in
        92.223.76.20) printf '28\t101\n'; return 0 ;;
        31.184.207.6) printf '35\t000\tTLS 握手失败：mock ssl error\n'; return 1 ;;
        *) printf '0\t403\tWebSocket 握手返回未接受的 HTTP 状态\n'; return 1 ;;
        esac
    }
    warn() { printf '%s\n' "$*"; }
    precheck_log=$(gcore_prevalidate_candidate_pool \
        "${precheck_source}" "${precheck_output}")
    assert_equal "Candidate prevalidation keeps only successful ingress records" \
        $'92.223.76.20\t9808\tmobile\tHK' "$(<"${precheck_output}")"
    assert_contains "Candidate prevalidation reports TLS/connect failures" \
        "${precheck_log}" "curl=35,HTTP=000:1"
    assert_contains "Candidate prevalidation reports rejected HTTP responses" \
        "${precheck_log}" "curl=0,HTTP=403:1"
    assert_contains "Candidate prevalidation reports the failed IP and curl detail" \
        "${precheck_log}" \
        "31.184.207.6：curl=35，HTTP=000，原因=TLS 握手失败：mock ssl error"
    assert_contains "Candidate prevalidation explains rejected HTTP status" \
        "${precheck_log}" \
        "92.223.120.132：curl=0，HTTP=403，原因=WebSocket 握手返回未接受的 HTTP 状态"
)

# 3e. Edge propagation accepts end-to-end success even while Resource is processed.
(
    QUOTA_ENABLED=0
    SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
    GCORE_CDN_RESOURCE_ID=202
    GCORE_EDGE_CERTIFICATE_ID=303
    probe_calls=0
    gcore_api_request() {
        case "$1 $2" in
        "GET /cdn/resources/202") printf '{"status":"processed"}' ;;
        "GET /cdn/sslData/303/status")
            printf '{"active":false,"latest_status":{"status":"DONE"}}'
            ;;
        *) return 1 ;;
        esac
    }
    curl() {
        printf 'easy_all ok\n' >"${RUNTIME_TMP}/gcore-edge-health-body"
        printf '200'
    }
    gcore_probe_xhttp() { probe_calls=$((probe_calls + 1)); }
    gcore_probe_websocket() { probe_calls=$((probe_calls + 1)); }
    sleep() { fail "Propagation wait must stop after end-to-end success"; }
    gcore_wait_for_cdn_health >/dev/null
    assert_equal "Both Gcore transports are verified" "2" "${probe_calls}"
)

# XHTTP failure must not suppress the WebSocket probe or its diagnostic.
(
    transport_probe_calls="${TMP_DIR}/gcore-transport-probe-calls"
    : >"${transport_probe_calls}"
    QUOTA_ENABLED=0
    SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
    GCORE_CDN_RESOURCE_ID=202
    GCORE_EDGE_CERTIFICATE_ID=303
    gcore_api_request() {
        case "$1 $2" in
        "GET /cdn/resources/202") printf '{"status":"active"}' ;;
        "GET /cdn/sslData/303/status")
            printf '{"active":true,"latest_status":{"status":"DONE"}}'
            ;;
        *) return 1 ;;
        esac
    }
    curl() {
        printf 'easy_all ok\n' >"${RUNTIME_TMP}/gcore-edge-health-body"
        printf '200'
    }
    gcore_probe_xhttp() {
        printf 'xhttp\n' >>"${transport_probe_calls}"
        GCORE_XHTTP_PROBE_ERROR="mock xhttp failure"
        return 1
    }
    gcore_probe_websocket() {
        printf 'websocket\n' >>"${transport_probe_calls}"
        return 0
    }
    sleep() { fail "Single-attempt validation must not sleep"; }
    if transport_error=$(gcore_wait_for_cdn_health 1 0 2>&1); then
        fail "A failed XHTTP transport must fail CDN validation"
    fi
    assert_equal "Both transport probes run independently" \
        $'xhttp\nwebsocket' "$(<"${transport_probe_calls}")"
    assert_contains "Transport diagnostics identify XHTTP failure" \
        "${transport_error}" "XHTTP=failed(mock xhttp failure)"
    assert_contains "Transport diagnostics identify WebSocket success" \
        "${transport_error}" "WebSocket=ok"
)

# Unchanged resources use one validation attempt; changed resources allow propagation.
(
    health_args="${TMP_DIR}/gcore-health-args"
    gcore_ensure_origin_group() { :; }
    gcore_ensure_origin_validation_certificates() { :; }
    gcore_wait_for_cdn_health() { printf '%s\t%s\n' "${1:-default}" "${2:-default}" >"${health_args}"; }

    gcore_ensure_resource() { GCORE_CDN_RESOURCE_CHANGED=0; }
    gcore_apply_cdn >/dev/null
    assert_equal "Unchanged resource uses one immediate health check" \
        $'1\t0' "$(<"${health_args}")"

    gcore_ensure_resource() { GCORE_CDN_RESOURCE_CHANGED=1; }
    gcore_apply_cdn >/dev/null
    assert_equal "Changed resource uses the default propagation window" \
        $'default\tdefault' "$(<"${health_args}")"
)

# Quota mode uses an active account UUID and skips transport probes if all users are disabled.
(
    QUOTA_ENABLED=1
    SUBSCRIPTION_DOMAIN="sub.example.com"
    selected_uuid="22222222-2222-4222-8222-222222222222"
    USER_ACCOUNTS=$(jq -cn --arg uuid "${selected_uuid}" \
        '{owner:{uuid:$uuid,token:"owner-token-123",quota_gb:100}}')
    probe_args="${TMP_DIR}/gcore-quota-probe-args"
    gcore_wait_for_domain_health() {
        printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "${4:-}" >>"${probe_args}"
    }
    quota_active_accounts_json() { printf '%s\n' "${USER_ACCOUNTS}"; }
    gcore_wait_for_cdn_health
    assert_equal "Quota propagation uses an active account UUID" "${selected_uuid}" \
        "$(awk -F'\t' 'NR==1 {print $4}' "${probe_args}")"
    assert_equal "Quota propagation keeps transport verification enabled" "1" \
        "$(awk -F'\t' 'NR==1 {print $3}' "${probe_args}")"
    assert_equal "Custom subscription domain is also health checked" \
        "${SUBSCRIPTION_DOMAIN}" "$(awk -F'\t' 'NR==2 {print $1}' "${probe_args}")"
    assert_equal "Subscription-domain health check does not run transport twice" "0" \
        "$(awk -F'\t' 'NR==2 {print $3}' "${probe_args}")"

    : >"${probe_args}"
    quota_active_accounts_json() { printf '{}\n'; }
    gcore_wait_for_cdn_health
    assert_equal "All-disabled quota skips transport verification" "0" \
        "$(awk -F'\t' 'NR==1 {print $3}' "${probe_args}")"
)

# Certificate failures stop before any public or transport probe.
if (
    QUOTA_ENABLED=0
    SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
    GCORE_CDN_RESOURCE_ID=202
    GCORE_EDGE_CERTIFICATE_ID=303
    gcore_api_request() {
        case "$1 $2" in
        "GET /cdn/resources/202") printf '{"status":"processed"}' ;;
        "GET /cdn/sslData/303/status")
            printf '{"latest_status":{"status":"FAILED","error":"dns","details":"challenge failed"}}'
            ;;
        *) return 1 ;;
        esac
    }
    curl() { fail "Public probe must not run after certificate failure"; }
    gcore_probe_xhttp() { fail "XHTTP probe must not run after certificate failure"; }
    gcore_probe_websocket() { fail "WebSocket probe must not run after certificate failure"; }
    gcore_wait_for_cdn_health
) >/dev/null 2>&1; then
    fail "Failed edge certificate must stop propagation wait"
fi

# 3f. Candidate scanning waits for the public CDN health endpoint first.
(
    curl_calls_file="${TMP_DIR}/gcore-readiness-curl-calls"
    printf '0\n' >"${curl_calls_file}"
    sleep_calls=0
    curl() {
        local curl_calls
        curl_calls=$(<"${curl_calls_file}")
        curl_calls=$((curl_calls + 1))
        printf '%s\n' "${curl_calls}" >"${curl_calls_file}"
        if ((curl_calls == 1)); then
            printf 'not ready\n' >"${RUNTIME_TMP}/gcore-precheck-health-body"
            printf '503'
        else
            printf 'easy_all ok\n' >"${RUNTIME_TMP}/gcore-precheck-health-body"
            printf '200'
        fi
    }
    sleep() { sleep_calls=$((sleep_calls + 1)); }
    gcore_wait_for_precheck_readiness >/dev/null
    assert_equal "Public edge readiness retries before candidate scanning" \
        "2" "$(<"${curl_calls_file}")"
    assert_equal "Public edge readiness waits between attempts" "1" "${sleep_calls}"
)

(
    sequence_file="${TMP_DIR}/gcore-precheck-sequence"
    : >"${sequence_file}"
    gcore_generate_carrier_candidate_pool() {
        printf '92.223.76.20\t9808\tmobile\tHK\n'
    }
    gcore_wait_for_precheck_readiness() {
        printf 'ready\n' >>"${sequence_file}"
    }
    gcore_prevalidate_candidate_pool() {
        printf 'prevalidate\n' >>"${sequence_file}"
        return 1
    }
    if gcore_build_dns_pool_cache "${TMP_DIR}/unused-cache.json"; then
        fail "Mocked candidate prevalidation must stop the cache build"
    fi
    assert_equal "Public edge wait runs before candidate prevalidation" \
        $'ready\nprevalidate' "$(<"${sequence_file}")"
)

# 4. Legacy origin-ACL caches must not be served after the discovery upgrade.
now_epoch=$(date +%s)
cat >"${GLOBALPING_CACHE_FILE}" <<EOF
{
  "version": 1,
  "provider": "gcore",
  "domain": "${VLESS_CDN_DOMAIN}",
  "candidate_source": "gcore-official-public-ip-list",
  "measured_at_epoch": ${now_epoch},
  "probe_type": "eyeball-network",
  "carrier_asns": [9808, 4837, 4134],
  "candidates": ${candidates_json}
}
EOF
if gcore_globalping_cache_compatible; then
    fail "Legacy origin-ACL cache must not be treated as a compatible ingress cache"
fi
assert_equal "Legacy origin-ACL cache is not emitted to clients" \
    "" "$(gcore_client_candidates)"

# Write valid regional-DNS cache and test cache validation.
cat >"${GLOBALPING_CACHE_FILE}" <<EOF
{
  "version": 4,
  "provider": "gcore",
  "domain": "${VLESS_CDN_DOMAIN}",
  "candidate_source": "gcore-globalping-regional-dns",
  "measured_at": "2026-09-07T00:00:00Z",
  "measured_at_epoch": ${now_epoch},
  "probe_country": "CN",
  "probe_type": "eyeball-network",
  "carrier_asns": [9808, 4837, 4134],
  "discovered_candidates": [
    {
      "ip": "92.223.76.20",
      "carrier_asn": 9808,
      "carrier": "mobile",
      "region": "HK",
      "last_seen_epoch": ${now_epoch}
    }
  ],
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
assert_contains "Xray XHTTP server uses the managed padding range" \
    "${xray_cfg}" '"xPaddingBytes": "100-1000"'

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
export GCORE_SUBSCRIPTION_DNS_ZONE="example.com"
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
assert_contains "State file has subscription DNS zone" "${state_content}" 'GCORE_SUBSCRIPTION_DNS_ZONE=example.com'

# Reset vars and load_state
unset VLESS_CDN_DOMAIN GCORE_ORIGIN_DOMAIN GCORE_SUBSCRIPTION_DNS_ZONE GCORE_CDN_TARGET
load_state
assert_equal "load_state restored VLESS_CDN_DOMAIN" "node.example.com" "${VLESS_CDN_DOMAIN}"
assert_equal "load_state restored GCORE_ORIGIN_DOMAIN" "origin.example.com" "${GCORE_ORIGIN_DOMAIN}"
assert_equal "load_state restored GCORE_CDN_TARGET" "cl-test.gcdn.co" "${GCORE_CDN_TARGET}"
assert_equal "load_state restored GCORE_SUBSCRIPTION_DNS_ZONE" \
    "example.com" "${GCORE_SUBSCRIPTION_DNS_ZONE}"
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
# 12. Test gcore_ensure_origin_a_record and gcore_ensure_domain_cname_record payload
recorded_calls=()
gcore_api_request() {
    recorded_calls+=("$1 $2 $3")
    return 0
}
dig() { return 1; }

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
SUBSCRIPTION_MODE=deploy
SUBSCRIPTION_DOMAIN="sub.1988088.xyz"
GCORE_SUBSCRIPTION_DNS_ZONE="${GCORE_DNS_ZONE}"
GCORE_CDN_TARGET="cl-test.gcdn.co"
gcore_ensure_cdn_cname_records

assert_equal "Total record calls" "3" "${#recorded_calls[@]}"
cname_call="${recorded_calls[1]}"
assert_contains "CNAME record method and url" "${cname_call}" "PUT /dns/v2/zones/1988088.xyz/node.1988088.xyz/CNAME"
cname_payload="${cname_call#PUT /dns/v2/zones/1988088.xyz/node.1988088.xyz/CNAME }"
assert_equal "CNAME record payload target" "cl-test.gcdn.co" "$(jq -r '.resource_records[0].content[0]' <<<"${cname_payload}")"
assert_equal "CNAME record payload TTL" "300" "$(jq -r '.ttl' <<<"${cname_payload}")"
subscription_cname_call="${recorded_calls[2]}"
assert_contains "Subscription CNAME method and url" "${subscription_cname_call}" \
    "PUT /dns/v2/zones/1988088.xyz/sub.1988088.xyz/CNAME"

dig() {
    case "$*" in
    *" A ${GCORE_ORIGIN_DOMAIN} "*) printf '%s\n' "${VPS_PUBLIC_IPV4}" ;;
    *" CNAME ${VLESS_CDN_DOMAIN} "*|*" CNAME ${SUBSCRIPTION_DOMAIN} "*)
        printf '%s.\n' "${GCORE_CDN_TARGET}"
        ;;
    esac
}
gcore_ensure_origin_a_record
gcore_ensure_cdn_cname_records
assert_equal "Matching public DNS records skip redundant API writes" \
    "3" "${#recorded_calls[@]}"

unset -f dig gcore_api_request

# DNS propagation checks use only 1.1.1.1 and require exact records.
(
    dig_calls="${TMP_DIR}/gcore-dig-calls"
    : >"${dig_calls}"
    dig() {
        printf '%s\n' "$*" >>"${dig_calls}"
        case "$*" in
        *"${GCORE_ORIGIN_DOMAIN}"*) printf '%s\n' "${VPS_PUBLIC_IPV4}" ;;
        *"${VLESS_CDN_DOMAIN}"*) printf '%s.\n' "${GCORE_CDN_TARGET}" ;;
        *"${SUBSCRIPTION_DOMAIN}"*) printf '%s.\n' "${GCORE_CDN_TARGET}" ;;
        esac
    }
    sleep() { fail "DNS propagation must return on the first matching response"; }
    gcore_wait_for_origin_dns
    gcore_wait_for_cdn_dns
    assert_equal "All DNS propagation checks ran" "3" "$(wc -l <"${dig_calls}" | tr -d ' ')"
    assert_equal "DNS propagation uses only 1.1.1.1" "3" \
        "$(grep -c '@1.1.1.1' "${dig_calls}")"
)

# Request contracts checked against G-Core/gcore-python OpenAPI-generated CDN types.
(
    api_calls="${TMP_DIR}/cdn-api-calls"
    SUBSCRIPTION_MODE=deploy
    SUBSCRIPTION_DOMAIN="sub.1988088.xyz"
    existing=false
    reject_update=false
    bound_certificate=404
    expected_certificate=303
    empty_certificate_response=false
    reject_certificate=false
    resource_matches=false
    certificate_created="${TMP_DIR}/edge-certificate-created"
    resource_payload="${TMP_DIR}/gcore-resource-payload.json"
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
        'GET /cdn/sslData')
            if [[ -f "${certificate_created}" ]]; then
                jq -cn --arg name "easy_all-edge-${VLESS_CDN_DOMAIN}" '[{id:303,name:$name,automated:true}]'
            else printf '[]'; fi ;;
        'POST /cdn/sslData')
            [[ "${reject_certificate}" == false ]] || return 1
            jq -e --arg name "easy_all-edge-${VLESS_CDN_DOMAIN}" '
                . == {name:$name,automated:true}
            ' <<<"$3" >/dev/null || return 1
            touch "${certificate_created}"
            if [[ "${empty_certificate_response}" == false ]]; then printf '{"id":303}'; fi ;;
        'GET /cdn/resources')
            if [[ "${existing}" == true ]]; then
                jq -cn --arg cname "${VLESS_CDN_DOMAIN}" --argjson cert "${bound_certificate}" '[{id:202,cname:$cname,sslData:$cert}]'
            else printf '[]'; fi ;;
        'GET /cdn/resources/202')
            if [[ "${resource_matches}" == true && -s "${resource_payload}" ]]; then
                cat "${resource_payload}"
            else
                printf '{"id":202,"active":false}'
            fi ;;
        'POST /cdn/resources'|'PUT /cdn/resources/202')
            [[ "${reject_update}" == false ]] || return 1
            [[ "${expected_certificate}" == 404 || -f "${certificate_created}" ]] || return 1
            jq -e --arg origin "${GCORE_ORIGIN_DOMAIN}" \
                --arg subscription "${SUBSCRIPTION_DOMAIN}" \
                --argjson cert "${expected_certificate}" '
                .active == true and .sslEnabled == true and
                .sslData == $cert and .sslData != .proxy_ssl_data and
                .secondaryHostnames == [$subscription] and
                .options.use_dns01_le_challenge == {enabled:true,value:true} and
                .originGroup == 101 and .originProtocol == "HTTPS" and
                .proxy_ssl_enabled == true and .proxy_ssl_data == 11223 and .proxy_ssl_ca == 44556 and
                .options.allowedHttpMethods == {enabled:true,value:["GET","HEAD","POST"]} and
                .options.websockets == {enabled:true,value:true} and
                .options.hostHeader == {enabled:true,value:$origin} and
                .options.sni == {enabled:true,sni_type:"custom",custom_hostname:$origin} and
                .options.proxy_connect_timeout == {enabled:true,value:"5s"} and
                .options.redirect_http_to_https == {enabled:true,value:true} and
                .options.ignoreQueryString == {enabled:true,value:false} and
                .options.slice == {enabled:true,value:false} and
                .options.edge_cache_settings.value == "0s" and
                (.options | has("origin_ssl_validation") or has("force_ssl") or has("proxy_cache") or has("ignore_query_string")) == false
            ' <<<"$3" >/dev/null || return 1
            printf '%s\n' "$3" >"${resource_payload}"
            printf '{"id":202}' ;;
        *) return 1 ;;
        esac
    }
    gcore_ensure_origin_group
    assert_equal "Created origin group ID" 101 "${GCORE_ORIGIN_GROUP_ID}"
    gcore_ensure_resource
    assert_equal "Created resource ID" 202 "${GCORE_CDN_RESOURCE_ID}"
    assert_equal "Created resource retains edge certificate ID for propagation checks" \
        303 "${GCORE_EDGE_CERTIFICATE_ID}"
    existing=true
    expected_certificate=404
    gcore_ensure_origin_group
    gcore_ensure_resource
    assert_equal "Existing group is reused" 1 "$(grep -c '^POST /cdn/origin_groups$' "${api_calls}")"
    assert_equal "Existing resource is updated" 1 "$(grep -c '^PUT /cdn/resources/202$' "${api_calls}")"
    resource_matches=true
    gcore_ensure_resource
    assert_equal "Unchanged resource skips PUT" 1 \
        "$(grep -c '^PUT /cdn/resources/202$' "${api_calls}")"
    assert_equal "Unchanged resource exposes no propagation change" 0 \
        "${GCORE_CDN_RESOURCE_CHANGED}"
    resource_matches=false
    reject_update=true
    if gcore_ensure_resource; then fail "Resource update failure must propagate"; fi
    reject_update=false
    assert_equal "Bound certificate avoids certificate lookup" 1 "$(grep -c '^GET /cdn/sslData$' "${api_calls}")"
    bound_certificate=null
    expected_certificate=303
    gcore_ensure_resource
    assert_equal "Unbound resource reuses managed edge certificate" 1 "$(grep -c '^POST /cdn/sslData$' "${api_calls}")"
    rm -f "${certificate_created}"
    empty_certificate_response=true
    gcore_ensure_resource
    assert_equal "Empty create response resolves certificate by name" 2 "$(grep -c '^POST /cdn/sslData$' "${api_calls}")"
    rm -f "${certificate_created}"
    reject_certificate=true
    requests_before=$(grep -c '^PUT /cdn/resources/202$' "${api_calls}")
    if gcore_ensure_resource; then fail "Certificate failure must stop resource update"; fi
    assert_equal "No resource mutation after certificate failure" "${requests_before}" "$(grep -c '^PUT /cdn/resources/202$' "${api_calls}")"
)

# Changing the active subscription domain synchronizes Gcore before saving state.
(
    calls=""
    require_root() { :; }
    begin_quota_maintenance() { :; }
    collect_installed_state() {
        VLESS_CDN_DOMAIN="node.example.com"
        SUBSCRIPTION_DOMAIN="${VLESS_CDN_DOMAIN}"
        SUBSCRIPTION_MODE=deploy
        QUOTA_ENABLED=0
    }
    snapshot_subscription_update() { :; }
    choose_subscription_mode() { SUBSCRIPTION_MODE=deploy; }
    collect_subscription_link_domain() { SUBSCRIPTION_DOMAIN="sub.example.com"; }
    choose_subscription_download_name() { :; }
    choose_monthly_quota() { QUOTA_ENABLED=0; }
    ensure_allowed_tokens() { :; }
    write_subscriptions() { :; }
    validate_cdn_client_ip_family_runtime() { :; }
    refresh_runtime() { calls+="local "; }
    install_quota_timer() { :; }
    validate_subscription_runtime() { :; }
    gcore_prepare_origin() { calls+="prepare "; }
    gcore_apply_cdn() { calls+="cloud "; }
    gcore_clear_api_token() { calls+="clear "; }
    save_state() { calls+="save "; }
    end_quota_maintenance() { :; }
    show_subscription() { :; }
    success() { :; }
    update_subscription
    assert_equal "Subscription domain changes synchronize Gcore before state save" \
        "local prepare cloud clear save " "${calls}"
)

# apply-cloud refreshes optimized IPs before rebuilding subscriptions and does not print twice.
(
    calls=""
    require_root() { :; }
    collect_installed_state() { :; }
    snapshot_subscription_update() { :; }
    configure_bbr_tcp() { :; }
    configure_ufw() { :; }
    gcore_prepare_origin() { calls+="prepare "; }
    refresh_runtime() { calls+="runtime "; }
    gcore_apply_cdn() { calls+="cloud "; }
    collect_globalping_token() { calls+="token "; }
    validate_globalping_access() { calls+="validate "; }
    persist_globalping_token() { calls+="persist "; }
    refresh_gcore_globalping_cache() { calls+="refresh "; }
    finish_xhttp_apply() { calls+="finish:$1:$2 "; }
    install_globalping_refresh_timer() { calls+="timer "; }
    gcore_clear_api_token() { calls+="clear "; }
    show_subscription() { calls+="show "; }
    success() { calls+="success "; }
    apply_cloud_resources
    assert_equal "apply-cloud refreshes IPs before one subscription render" \
        "prepare runtime cloud token validate persist refresh finish:1:1 timer clear success " "${calls}"
)

# Execute the real upload flow with temporary certificate paths in a fresh shell.
{
    declare -f gcore_uploaded_certificate_id gcore_ensure_origin_validation_certificates \
        gcore_origin_ca_name gcore_json_items fail die assert_equal
    cat <<'EOF'
set -Eeuo pipefail
RED="" RESET=""
RUNTIME_TMP=$1
GCORE_ORIGIN_DOMAIN=origin.example.com
GCORE_CLIENT_CERT_FILE="$1/client.crt"
GCORE_CLIENT_CERT_KEY="$1/client.key"
CERT_FILE="$1/fullchain.pem"
store="$1/uploaded-certificates.json"
printf '[]' >"${store}"
printf 'client-certificate' >"${GCORE_CLIENT_CERT_FILE}"
printf 'first-key' >"${GCORE_CLIENT_CERT_KEY}"
printf '%s\n' '-----BEGIN CERTIFICATE-----' leaf '-----END CERTIFICATE-----' \
    '-----BEGIN CERTIFICATE-----' issuer '-----END CERTIFICATE-----' >"${CERT_FILE}"
gcore_prepare_origin_validation_material() { :; }
reject_update=false
gcore_api_request() {
    local method=$1 endpoint=$2 payload=${3:-} next id
    case "${method}" in
    GET) jq --arg endpoint "${endpoint}" '[.[] | select(.endpoint == $endpoint)]' "${store}" ;;
    POST)
        # Model the API uniqueness rule, including retries after local state loss.
        jq -e --arg endpoint "${endpoint}" --argjson p "${payload}" \
            'all(.[]; .endpoint != $endpoint or .name != $p.name)' "${store}" >/dev/null || return 1
        id=$(jq 'length + 1' "${store}")
        next=$(jq --arg endpoint "${endpoint}" --argjson id "${id}" --argjson p "${payload}" \
            '. + [$p + {id:$id,endpoint:$endpoint}]' "${store}")
        printf '%s' "${next}" >"${store}"
        # Exercise the documented empty create response as well.
        ;;
    PUT)
        [[ "${reject_update}" == false ]] || return 1
        [[ "${endpoint}" == /cdn/sslData/* ]] || return 1
        id=${endpoint##*/}
        next=$(jq --argjson id "${id}" --argjson p "${payload}" \
            'map(if .id == $id then . + $p else . end)' "${store}")
        printf '%s' "${next}" >"${store}" ;;
    *) return 1 ;;
    esac
}
gcore_ensure_origin_validation_certificates
assert_equal "first upload creates client and CA" 2 "$(jq length "${store}")"
unset GCORE_ORIGIN_CLIENT_CERT_ID GCORE_ORIGIN_CA_ID
gcore_ensure_origin_validation_certificates
assert_equal "retry creates no duplicate certificates" 2 "$(jq length "${store}")"
assert_equal "retry restores client ID" 1 "${GCORE_ORIGIN_CLIENT_CERT_ID}"
assert_equal "retry restores CA ID" 2 "${GCORE_ORIGIN_CA_ID}"
printf 'replacement-key' >"${GCORE_CLIENT_CERT_KEY}"
gcore_ensure_origin_validation_certificates
assert_equal "reinstallation updates client key" replacement-key "$(jq -r '.[0].sslPrivateKey' "${store}")"
printf 'new-issuer\n' >>"${CERT_FILE}"
gcore_ensure_origin_validation_certificates
assert_equal "changed issuer chain creates a new CA" 3 "${GCORE_ORIGIN_CA_ID}"
gcore_ensure_origin_validation_certificates
assert_equal "changed CA is reused on retry" 3 "$(jq length "${store}")"
reject_update=true
if gcore_ensure_origin_validation_certificates; then fail "client update failure must propagate"; fi
EOF
} | bash -s -- "${TMP_DIR}"

printf 'ok - Gcore Mode 3 unit tests passed\n'
