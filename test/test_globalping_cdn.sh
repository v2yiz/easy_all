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
GLOBALPING_REFRESH_SERVICE_FILE_OVERRIDE="${TMP_DIR}/easy_all-globalping-refresh.service"
GLOBALPING_REFRESH_TIMER_FILE_OVERRIDE="${TMP_DIR}/easy_all-globalping-refresh.timer"
COMMAND_PATH="/usr/local/bin/easy_all"
VLESS_CDN_DOMAIN="node.example.com"
CDN_PROVIDER="cloudflare"
CLOUDFLARE_CDN_ENDPOINT_MODE="optimized"
GLOBALPING_NOW_EPOCH=2000000000
cleanup_files=()
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}"

warn() { :; }
success() { :; }
die() { fail "$*"; }
prompt_secret() { return 1; }

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/profile-common.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/globalping-cdn.sh"

validate_public_ipv4 13.32.10.10 || fail "public IPv4 must be accepted"
if validate_public_ipv4 127.0.0.1 || validate_public_ipv4 169.254.169.254 \
    || validate_public_ipv4 203.0.113.10; then
    fail "private, metadata, and documentation IPv4 ranges must be rejected"
fi

request=$(globalping_measurement_request)
jq -e '
  .type == "ping"
  and .target == "node.example.com"
  and .locations == [{country:"CN"}]
  and .limit == 50
  and .timeout == 20
  and .measurementOptions == {
    packets:10, protocol:"TCP", port:443, ipVersion:4
  }
' <<<"${request}" >/dev/null || fail "Globalping request contract is invalid"

(
    poll_count_file="${TMP_DIR}/poll-count"
    printf '0\n' >"${poll_count_file}"
    sleep() { :; }
    globalping_api_request() {
        if [[ "$1" == "POST" ]]; then
            printf '%s\n' '{"id":"measurement-1","probesCount":2}'
            return 0
        fi
        poll_count=$(<"${poll_count_file}")
        poll_count=$((poll_count + 1))
        printf '%s\n' "${poll_count}" >"${poll_count_file}"
        if ((poll_count == 1)); then
            printf '%s\n' '{"id":"measurement-1","status":"in-progress"}'
        else
            printf '%s\n' '{"id":"measurement-1","status":"finished","results":[]}'
        fi
    }
    result=$(globalping_run_measurement)
    assert_equal "synchronous measurement polling reaches the final response" \
        "finished" "$(jq -r '.status' <<<"${result}")"
    assert_equal "synchronous measurement polls until completion" "2" \
        "$(<"${poll_count_file}")"
)

measurement='{
  "id":"measurement-1",
  "status":"finished",
  "createdAt":"2033-05-18T03:33:20Z",
  "updatedAt":"2033-05-18T03:33:25Z",
  "results":[
    {
      "probe":{"country":"CN","city":"Shanghai","asn":9929,"network":"Unicom"},
      "result":{"status":"finished","resolvedAddress":"13.32.10.10","stats":{"loss":0,"total":10,"rcv":10,"drop":0,"avg":30}}
    },
    {
      "probe":{"country":"CN","city":"Beijing","asn":4134,"network":"Telecom"},
      "result":{"status":"finished","resolvedAddress":"13.32.10.10","stats":{"loss":0,"total":10,"rcv":10,"drop":0,"avg":50}}
    },
    {
      "probe":{"country":"CN","city":"Guangzhou","asn":9808,"network":"Mobile"},
      "result":{"status":"finished","resolvedAddress":"18.64.20.20","stats":{"loss":10,"total":10,"rcv":9,"drop":1,"avg":40}}
    },
    {
      "probe":{"country":"US","city":"Seattle","asn":16509,"network":"Amazon"},
      "result":{"status":"finished","resolvedAddress":"192.0.2.30","stats":{"loss":0,"total":10,"rcv":10,"drop":0,"avg":20}}
    },
    {
      "probe":{"country":"CN","city":"Shenzhen","asn":4134,"network":"Telecom"},
      "result":{"status":"finished","resolvedAddress":"999.1.1.1","stats":{"loss":0,"total":10,"rcv":10,"drop":0,"avg":10}}
    }
  ]
}'

candidates=$(globalping_zero_loss_candidates "${measurement}")
assert_equal "only one strict mainland zero-loss IPv4 remains" "1" \
    "$(jq 'length' <<<"${candidates}")"
assert_equal "duplicate observations are aggregated" "2" \
    "$(jq -r '.[0].observations' <<<"${candidates}")"
assert_equal "average RTT is aggregated" "40" \
    "$(jq -r '.[0].avg_rtt_ms' <<<"${candidates}")"

validate_cdn_candidate() {
    [[ "$1" == "13.32.10.10" ]]
}
cache_stage="${TMP_DIR}/cache-stage.json"
globalping_build_cache "${measurement}" "${cache_stage}"
install -m 0600 "${cache_stage}" "${GLOBALPING_CACHE_FILE}"
jq -e '
  .version == 2
  and .provider == "cloudflare"
  and .domain == "node.example.com"
  and .probe_country == "CN"
  and .protocol == "TCP"
  and .port == 443
  and .packets == 10
  and .candidates == [{
    ip:"13.32.10.10",
    observations:2,
    avg_rtt_ms:40,
    cities:["Beijing","Shanghai"],
    asns:[4134,9929],
    networks:["Telecom","Unicom"]
  }]
' "${GLOBALPING_CACHE_FILE}" >/dev/null || fail "Globalping cache schema is invalid"

globalping_cache_valid || fail "fresh Globalping cache must be valid"
assert_equal "fresh cache returns selected IPv4" "13.32.10.10" \
    "$(cdn_client_endpoints)"

GLOBALPING_NOW_EPOCH=$((2000000000 + GLOBALPING_CACHE_MAX_AGE_SECONDS + 1))
if globalping_cache_valid; then
    fail "cache older than 72 hours must not be used"
fi
assert_equal "stale cache falls back to CDN domain" "node.example.com" \
    "$(cdn_client_endpoints)"

GLOBALPING_NOW_EPOCH=2000000000
CDN_PROVIDER="cloudflare"
CLOUDFLARE_CDN_ENDPOINT_MODE="optimized"
jq '.provider = "cloudflare"' "${GLOBALPING_CACHE_FILE}" >"${cache_stage}"
install -m 0600 "${cache_stage}" "${GLOBALPING_CACHE_FILE}"
assert_equal "Cloudflare optimized mode reuses the provider-neutral candidates" \
    "13.32.10.10" "$(cdn_client_endpoints)"
CLOUDFLARE_CDN_ENDPOINT_MODE="domain"
assert_equal "Cloudflare domain mode ignores candidate cache" "node.example.com" \
    "$(cdn_client_endpoints)"
CLOUDFLARE_CDN_ENDPOINT_MODE="optimized"

printf 'test-globalping-token-value\n' >"${GLOBALPING_TOKEN_FILE}"
chmod 0600 "${GLOBALPING_TOKEN_FILE}"
unset GLOBALPING_TOKEN
assert_equal "token is loaded from the root-only file" \
    "test-globalping-token-value" "$(globalping_token_value)"

systemctl_calls="${TMP_DIR}/systemctl-calls"
: >"${systemctl_calls}"
systemctl() {
    printf '%s\n' "$*" >>"${systemctl_calls}"
    return 0
}
install_globalping_refresh_timer
grep -Fq 'ExecStart=/usr/local/bin/easy_all refresh-cdn-ips' \
    "${GLOBALPING_REFRESH_SERVICE_FILE}" \
    || fail "Globalping service must invoke the manual refresh command"
grep -Fq 'OnUnitActiveSec=1h' "${GLOBALPING_REFRESH_TIMER_FILE}" \
    || fail "Globalping timer must refresh every hour"
grep -Fq 'OnActiveSec=1h' "${GLOBALPING_REFRESH_TIMER_FILE}" \
    || fail "Globalping timer must wait one hour after registration"
if grep -Fq 'OnBootSec=' "${GLOBALPING_REFRESH_TIMER_FILE}"; then
    fail "Globalping timer must not trigger immediately when registered long after boot"
fi
grep -Fq 'enable easy_all-globalping-refresh.timer' "${systemctl_calls}" \
    || fail "Globalping refresh timer must be enabled"
grep -Fq 'restart easy_all-globalping-refresh.timer' "${systemctl_calls}" \
    || fail "Globalping refresh timer must restart after registration"
grep -Fq 'is-enabled --quiet easy_all-globalping-refresh.timer' "${systemctl_calls}" \
    || fail "Globalping refresh timer registration must verify enablement"
grep -Fq 'is-active --quiet easy_all-globalping-refresh.timer' "${systemctl_calls}" \
    || fail "Globalping refresh timer registration must verify activity"
remove_globalping_refresh_timer
[[ ! -e "${GLOBALPING_REFRESH_SERVICE_FILE}" \
    && ! -e "${GLOBALPING_REFRESH_TIMER_FILE}" ]] \
    || fail "Globalping timer removal must delete both units"

printf 'ok - Globalping CDN tests passed\n'
