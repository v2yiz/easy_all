#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected '${expected}', got '${actual}'"
}

STATE_DIR="${TMP_DIR}/state"
RUNTIME_TMP="${TMP_DIR}/runtime"
GLOBALPING_TOKEN_FILE_OVERRIDE="${STATE_DIR}/globalping.token"
GLOBALPING_CACHE_FILE_OVERRIDE="${STATE_DIR}/cloudflare-cdn-ips.json"
VLESS_CDN_DOMAIN="node.example.com"
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}"

warn() { :; }
info() { :; }
success() { :; }
die() { fail "$*"; }

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/profile-common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/globalping-cdn.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/cloudflare-ip-pool.sh"

# ==============================================================================
# Test 1: Priority CIDR Subnet Classification (per /24 subnet)
# ==============================================================================
ranges_file="${TMP_DIR}/test-ranges.txt"
cat <<'RANGE_EOF' >"${ranges_file}"
162.158.0.0/15
104.16.0.0/13
RANGE_EOF

pool_output=$(cloudflare_generate_candidate_pool "${ranges_file}" 72 1725500000)
candidate_count=$(wc -l <<<"${pool_output}" | tr -d ' ')
assert_equal "Total generated candidate count is 72" "72" "${candidate_count}"

# Priority CIDRs include 104.16.0.0/13 and 162.159.0.0/16 (which is inside 162.158.0.0/15).
# Candidates from 162.159.x.x must be tagged with 162.158.0.0/15 and classified into priority.
pri_162_count=0
oth_162_count=0
while IFS=$'\t' read -r ip cidr; do
    if [[ "${ip}" == 162.159.* ]]; then
        pri_162_count=$((pri_162_count + 1))
    elif [[ "${ip}" == 162.158.* ]]; then
        oth_162_count=$((oth_162_count + 1))
    fi
done <<<"${pool_output}"

if (( pri_162_count == 0 )); then
    fail "Priority pool must contain 162.159.x.x candidates (found 0)"
fi
if (( oth_162_count == 0 )); then
    fail "Other pool must contain 162.158.x.x candidates (found 0)"
fi

# ==============================================================================
# Test 2: Globalping Budget Calculation & Stratified Proportional Reduction
# ==============================================================================
mock_remaining=50
globalping_api_request() {
    local method=$1 path=$2
    if [[ "${path}" == "/limits" ]]; then
        printf '{"rateLimit":{"measurements":{"create":{"remaining":%d,"type":"user"}}}}\n' "${mock_remaining}"
        return 0
    fi
    return 1
}

# Source with 20 prevalidated candidates (14 priority, 6 other)
source_cands="${TMP_DIR}/source-candidates.tsv"
dest_cands="${TMP_DIR}/dest-candidates.tsv"
: >"${source_cands}"
for i in {1..14}; do
    printf '104.16.1.%d\t104.16.0.0/13\n' "$i" >>"${source_cands}"
done
for i in {1..6}; do
    printf '162.158.1.%d\t162.158.0.0/15\n' "$i" >>"${source_cands}"
done

# When remaining is 50:
# stage2_reserve = 15
# tcp_remaining = 35
# budget = 35 / 3 = 11 candidates
cloudflare_limit_pool_to_globalping_budget "${source_cands}" "${dest_cands}"
budgeted_count=$(wc -l <"${dest_cands}" | tr -d ' ')
assert_equal "Budgeted candidate count is 11 when remaining is 50" "11" "${budgeted_count}"

# Check that stratified reduction kept both priority and other candidates:
dest_pri=0
dest_oth=0
while IFS=$'\t' read -r ip cidr; do
    if [[ "${ip}" == 104.16.* ]]; then
        dest_pri=$((dest_pri + 1))
    else
        dest_oth=$((dest_oth + 1))
    fi
done <"${dest_cands}"
assert_equal "Stratified reduction keeps 7 priority candidates" "7" "${dest_pri}"
assert_equal "Stratified reduction keeps 4 other candidates" "4" "${dest_oth}"

# When remaining is <= 15 (e.g. 5), budget should be rejected
mock_remaining=5
if cloudflare_limit_pool_to_globalping_budget "${source_cands}" "${dest_cands}" 2>/dev/null; then
    fail "Budget calculation should fail when remaining is insufficient for Stage 2 reservation"
fi

# ==============================================================================
# Test 3: Probe Anchoring in Measurement Requests
# ==============================================================================
req_no_anchor=$(cloudflare_globalping_measurement_request "104.16.1.1")
assert_equal "Default request specifies 3 eyeball networks" "3" \
    "$(jq '.locations | length' <<<"${req_no_anchor}")"
assert_equal "Default request sends ten packets for a 10 percent loss threshold" "10" \
    "$(jq '.measurementOptions.packets' <<<"${req_no_anchor}")"

req_with_anchor=$(cloudflare_globalping_measurement_request "104.16.1.1" "base-meas-id-12345")
assert_equal "Anchored request specifies magic location" "base-meas-id-12345" \
    "$(jq -r '.locations[0].magic' <<<"${req_with_anchor}")"

# ==============================================================================
# Test 4: TLS Verification Gate & Result Parsing
# ==============================================================================
tls_mock_file="${TMP_DIR}/tls-mock.ndjson"
cat <<'TLS_EOF' >"${tls_mock_file}"
{"ip":"104.16.1.1","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":42.0,"measurement":{"results":[{"result":{"status":"finished","statusCode":200,"tls":{"protocol":"TLSv1.3","authorized":true}}}]}}
{"ip":"104.16.1.2","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":35.0,"measurement":{"results":[{"result":{"status":"finished","statusCode":403,"tls":{"protocol":"TLSv1.3","authorized":false,"error":"ERR_TLS_CERT_ALTNAME_INVALID"}}}]}}
{"ip":"104.16.1.3","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":30.0,"measurement":{"results":[{"result":{"status":"finished","statusCode":200,"tls":{"protocol":"TLSv1.3","authorized":false,"error":"UNABLE_TO_VERIFY_LEAF_SIGNATURE"}}}]}}
{"ip":"104.16.1.4","source_cidr":"104.16.0.0/13","carrier_asn":4837,"avg_rtt_ms":50.0,"measurement":{"results":[{"result":{"status":"failed","statusCode":0,"error":"connection timeout"}}]}}
{"ip":"104.16.1.5","source_cidr":"104.16.0.0/13","carrier_asn":4837,"avg_rtt_ms":48.0,"measurement":{"results":[{"result":{"status":"finished","statusCode":502,"tls":{"protocol":"TLSv1.3","authorized":true}}}]}}
TLS_EOF

parsed_tls=$(cloudflare_parse_tls_observations "${tls_mock_file}")
parsed_count=$(wc -l <<<"${parsed_tls}" | tr -d ' ')
assert_equal "2 valid edge results pass TLS parsing" "2" "${parsed_count}"

passing_ips=$(jq -r '.ip' <<<"${parsed_tls}" | tr '\n' ' ')
[[ "${passing_ips}" == *"104.16.1.1 "* ]] || fail "104.16.1.1 should pass TLS parsing"
[[ "${passing_ips}" == *"104.16.1.2 "* ]] || fail "104.16.1.2 should pass TLS parsing"
[[ "${passing_ips}" != *"104.16.1.3 "* ]] || fail "104.16.1.3 (UNABLE_TO_VERIFY_LEAF_SIGNATURE) must be rejected"
[[ "${passing_ips}" != *"104.16.1.4 "* ]] || fail "104.16.1.4 (failed) must be rejected"
[[ "${passing_ips}" != *"104.16.1.5 "* ]] || fail "104.16.1.5 (HTTP 502) must be rejected"

# ==============================================================================
# Test 5: Strict Cross-Carrier Deduplication & 6 Unique Candidates Output
# ==============================================================================
obs_file="${TMP_DIR}/test-obs.ndjson"
cat <<'OBS_EOF' >"${obs_file}"
{"ip":"104.16.1.1","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":30.0,"tls_verified":true}
{"ip":"104.16.1.1","source_cidr":"104.16.0.0/13","carrier_asn":9808,"avg_rtt_ms":20.0,"tls_verified":true}
{"ip":"104.16.1.2","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":35.0,"tls_verified":true}
{"ip":"104.16.2.1","source_cidr":"104.16.0.0/13","carrier_asn":4837,"avg_rtt_ms":40.0,"tls_verified":true}
{"ip":"104.16.2.2","source_cidr":"104.16.0.0/13","carrier_asn":4837,"avg_rtt_ms":45.0,"tls_verified":true}
{"ip":"104.16.3.1","source_cidr":"104.16.0.0/13","carrier_asn":9808,"avg_rtt_ms":25.0,"tls_verified":true}
{"ip":"104.16.3.2","source_cidr":"104.16.0.0/13","carrier_asn":9808,"avg_rtt_ms":28.0,"tls_verified":true}
{"ip":"104.16.9.9","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":10.0,"tls_verified":false}
OBS_EOF

selected_json=$(cloudflare_select_carrier_candidates "${obs_file}" 2 6)
selected_count=$(jq 'length' <<<"${selected_json}")
assert_equal "Selected count is strictly 6" "6" "${selected_count}"

unique_ip_count=$(jq '[.[].ip] | unique | length' <<<"${selected_json}")
assert_equal "All 6 selected candidate IPs are globally unique" "6" "${unique_ip_count}"

telecom_ips=$(jq -r '.[] | select(.carrier=="telecom") | .ip' <<<"${selected_json}")
mobile_ips=$(jq -r '.[] | select(.carrier=="mobile") | .ip' <<<"${selected_json}")
[[ "${telecom_ips}" == *"104.16.1.1"* ]] || fail "104.16.1.1 should be assigned to Telecom"
[[ "${mobile_ips}" != *"104.16.1.1"* ]] || fail "104.16.1.1 must NOT be reused by Mobile"

all_selected_ips=$(jq -r '.[].ip' <<<"${selected_json}")
[[ "${all_selected_ips}" != *"104.16.9.9"* ]] || fail "Unverified candidate must not be selected"

# ==============================================================================
# Test 6: Historical Candidate Retesting & Stability Margin (Anti-Churn)
# ==============================================================================
hist_file="${TMP_DIR}/test-history.tsv"
printf "104.16.2.2\t104.16.0.0/13\t4837\t45.0\tunicom\n" >"${hist_file}"

cat <<'OBS_HIST_EOF' >"${obs_file}"
{"ip":"104.16.1.1","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":30.0,"tls_verified":true}
{"ip":"104.16.1.2","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":35.0,"tls_verified":true}
{"ip":"104.16.2.1","source_cidr":"104.16.0.0/13","carrier_asn":4837,"avg_rtt_ms":42.0,"tls_verified":true}
{"ip":"104.16.2.2","source_cidr":"104.16.0.0/13","carrier_asn":4837,"avg_rtt_ms":45.0,"tls_verified":true}
{"ip":"104.16.3.1","source_cidr":"104.16.0.0/13","carrier_asn":9808,"avg_rtt_ms":25.0,"tls_verified":true}
{"ip":"104.16.3.2","source_cidr":"104.16.0.0/13","carrier_asn":9808,"avg_rtt_ms":28.0,"tls_verified":true}
OBS_HIST_EOF

selected_with_hist=$(cloudflare_select_carrier_candidates "${obs_file}" 2 6 "${hist_file}")
unicom_01=$(jq -r '.[] | select(.label=="联通01") | .ip' <<<"${selected_with_hist}")
assert_equal "Historical candidate is prioritized when new candidate is not >= 5ms faster" \
    "104.16.2.2" "${unicom_01}"

# ==============================================================================
# Test 7: Missing carriers never synthesize unverified candidates
# ==============================================================================
single_obs="${TMP_DIR}/test-single-obs.ndjson"
cat <<'SINGLE_EOF' >"${single_obs}"
{"ip":"104.16.1.1","source_cidr":"104.16.0.0/13","carrier_asn":4134,"avg_rtt_ms":30.0,"tls_verified":true}
SINGLE_EOF

backfilled=$(cloudflare_select_carrier_candidates "${single_obs}" 2 6)
backfilled_count=$(jq 'length' <<<"${backfilled}")
assert_equal "Missing carriers cannot be filled from another carrier" "0" "${backfilled_count}"

# ==============================================================================
# Test 8: Empty observations produce no synthetic fallback
# ==============================================================================
empty_obs="${TMP_DIR}/test-empty-obs.ndjson"
: >"${empty_obs}"
ultimate_fallback=$(cloudflare_select_carrier_candidates "${empty_obs}" 2 6)
ultimate_count=$(jq 'length' <<<"${ultimate_fallback}")
assert_equal "Empty observations produce no candidates" "0" "${ultimate_count}"

# ==============================================================================
# Test 9: Packet Loss Tolerance (loss <= 10%, rcv >= 9/10)
# ==============================================================================
meas_loss_file="${TMP_DIR}/test-meas-loss.ndjson"
cat <<'MEAS_EOF' >"${meas_loss_file}"
{"ip":"104.16.1.1","source_cidr":"104.16.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":4134,"tags":["eyeball-network"],"city":"Guangzhou","network":"China Telecom"},"result":{"status":"finished","resolvedAddress":"104.16.1.1","stats":{"loss":0,"rcv":10,"total":10,"drop":0,"avg":35.5}}}]}}
{"ip":"104.16.1.2","source_cidr":"104.16.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":4837,"tags":["eyeball-network"],"city":"Beijing","network":"China Unicom"},"result":{"status":"finished","resolvedAddress":"104.16.1.2","stats":{"loss":10,"rcv":9,"total":10,"drop":1,"avg":42.0}}}]}}
{"ip":"104.16.1.3","source_cidr":"104.16.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":9808,"tags":["eyeball-network"],"city":"Shanghai","network":"China Mobile"},"result":{"status":"finished","resolvedAddress":"104.16.1.3","stats":{"loss":20,"rcv":8,"total":10,"drop":2,"avg":50.0}}}]}}
MEAS_EOF

loss_obs=$(cloudflare_acceptable_loss_observations "${meas_loss_file}")
loss_obs_count=$(wc -l <<<"${loss_obs}" | tr -d ' ')
assert_equal "Ping filter accepts 0% and 10% loss, rejecting 20% loss" "2" "${loss_obs_count}"

passing_loss_ips=$(jq -r '.ip' <<<"${loss_obs}" | tr '\n' ' ')
[[ "${passing_loss_ips}" == *"104.16.1.1 "* ]] || fail "104.16.1.1 (0% loss) should pass"
[[ "${passing_loss_ips}" == *"104.16.1.2 "* ]] || fail "104.16.1.2 (10% loss) should pass"
[[ "${passing_loss_ips}" != *"104.16.1.3 "* ]] || fail "104.16.1.3 (20% loss) must be rejected"

printf 'ok - Cloudflare IP pool tests passed\n'
