#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

STATE_DIR="${TMP_DIR}/state"
RUNTIME_TMP="${TMP_DIR}/runtime"
XRAY_SERVICE="easy_all-xray.service"
COMMAND_PATH="/usr/local/bin/easy_all"
QUOTA_API_LISTEN="127.0.0.1:10085"
QUOTA_MAINTENANCE_FILE="${STATE_DIR}/quota-maintenance"
cleanup_files=()
TEST_RUNTIME_LOCK_BUSY=0
TEST_RUNTIME_LOCK_DEPTH=0
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}"

try_acquire_runtime_write_lock() {
    [[ "${TEST_RUNTIME_LOCK_BUSY}" == "0" ]] || return 1
    TEST_RUNTIME_LOCK_DEPTH=$((TEST_RUNTIME_LOCK_DEPTH + 1))
}

release_runtime_write_lock() {
    ((TEST_RUNTIME_LOCK_DEPTH > 0)) || return 0
    TEST_RUNTIME_LOCK_DEPTH=$((TEST_RUNTIME_LOCK_DEPTH - 1))
}

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected [${expected}], got [${actual}]"
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/cdn-traffic-guard.sh"

validate_cdn_traffic_protection_gb 980 \
    || fail "980 GB protection threshold must be valid"
if validate_cdn_traffic_protection_gb 0; then
    fail "zero must not disable the mandatory pay-as-you-go protection"
fi
assert_equal "UTC calendar month extraction" "2026-08" \
    "$(cdn_traffic_current_period "2026-08-20")"

PROTOCOL="xhttp"
CDN_PROVIDER="aws"
AWS_CLOUDFRONT_BILLING_MODE="payg"
CDN_TRAFFIC_PROTECTION_GB=""
configure_cdn_traffic_protection
assert_equal "pay-as-you-go protection defaults to 980 GB" "980" \
    "${CDN_TRAFFIC_PROTECTION_GB}"
cdn_traffic_protection_enabled \
    || fail "pay-as-you-go XHTTP must enable global fee protection"
if (
    CDN_TRAFFIC_PROTECTION_GB=979
    configure_cdn_traffic_protection
) >/dev/null 2>&1; then
    fail "pay-as-you-go protection threshold must stay fixed at 980 GB"
fi

totals=$(cdn_traffic_stats_totals '{"stat":[
  {"name":"user>>>easy_all.owner>>>traffic>>>uplink","value":100},
  {"name":"user>>>easy_all.owner>>>traffic>>>downlink","value":200},
  {"name":"user>>>easy_all.friend>>>traffic>>>uplink","value":300},
  {"name":"inbound>>>api>>>traffic>>>uplink","value":999}
]}')
assert_equal "global protection sums every Xray user uplink and downlink" $'400\t200' \
    "${totals}"

XRAY_BIN="${TMP_DIR}/xray"
cat >"${XRAY_BIN}" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"stat":[
  {"name":"user>>>easy_all.owner>>>traffic>>>uplink","value":60000000},
  {"name":"user>>>easy_all.owner>>>traffic>>>downlink","value":50000000}
]}
JSON
EOF
chmod 0755 "${XRAY_BIN}"

systemctl() {
    if [[ "${1:-}" == "show" ]]; then
        printf 'runtime-1\n'
    fi
    return 0
}
require_root() { :; }
collect_installed_state() { :; }
rebuild_traffic_runtime() {
    [[ "${TEST_RUNTIME_LOCK_DEPTH}" == "1" ]] \
        || fail "CDN guard must hold the shared runtime write lock while rebuilding"
    printf 'rebuilt\n' >"${TMP_DIR}/rebuilt"
}

period=$(cdn_traffic_current_period)
cat >"${CDN_TRAFFIC_GUARD_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"runtime-1","used_bytes":979900000000,
 "last_uplink":0,"last_downlink":0,"blocked":false,"enforced":false}
EOF
cdn_traffic_protection_sync
assert_equal "980 GB threshold blocks the complete XHTTP chain" "true" \
    "$(jq -r '.blocked' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_equal "successful rebuild records that the block is enforced" "true" \
    "$(jq -r '.enforced' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_equal "global accounting includes both traffic directions" "980010000000" \
    "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] \
    || fail "crossing the global threshold must rebuild the Xray runtime"
cdn_traffic_protection_blocked \
    || fail "blocked state must be visible to Xray config generation"

cat >"${CDN_TRAFFIC_GUARD_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"runtime-1","used_bytes":100000000,
 "last_uplink":0,"last_downlink":0,"blocked":false,"enforced":false}
EOF
rm -f -- "${TMP_DIR}/rebuilt"
cdn_traffic_protection_checkpoint
assert_equal "pre-restart checkpoint persists unflushed traffic" "210000000" \
    "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
[[ ! -f "${TMP_DIR}/rebuilt" ]] \
    || fail "a checkpoint records traffic without recursively rebuilding Xray"

cat >"${CDN_TRAFFIC_GUARD_USAGE_FILE}" <<'EOF'
{"period":"2000-01","runtime_id":"runtime-1","used_bytes":980010000000,
 "last_uplink":60000000,"last_downlink":50000000,"blocked":true,"enforced":true}
EOF
rm -f -- "${TMP_DIR}/rebuilt"
cdn_traffic_protection_sync
assert_equal "UTC natural month rollover resets protected bytes" "0" \
    "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_equal "UTC natural month rollover restores XHTTP" "false" \
    "$(jq -r '.blocked' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] \
    || fail "month rollover must rebuild the runtime to restore clients"

cat >"${CDN_TRAFFIC_GUARD_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"runtime-1","used_bytes":979900000000,
 "last_uplink":0,"last_downlink":0,"blocked":false,"enforced":false}
EOF
rebuild_traffic_runtime() { return 1; }
if (cdn_traffic_protection_sync) >/dev/null 2>&1; then
    fail "a failed blocking transition must fail closed"
fi
assert_equal "failed runtime transition keeps the desired block for retry" "true" \
    "$(jq -r '.blocked' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_equal "failed runtime transition remains visibly unenforced" "false" \
    "$(jq -r '.enforced' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_equal "failed runtime transition preserves newly accounted bytes" "980010000000" \
    "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"

AWS_CLOUDFRONT_BILLING_MODE="flat-free"
configure_cdn_traffic_protection
assert_equal "flat-rate mode disables the pay-as-you-go guard" "0" \
    "${CDN_TRAFFIC_PROTECTION_GB}"
if cdn_traffic_protection_enabled; then
    fail "flat-rate mode must not enable the pay-as-you-go guard"
fi

before_busy_sync=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
TEST_RUNTIME_LOCK_BUSY=1
cdn_traffic_protection_sync
TEST_RUNTIME_LOCK_BUSY=0
assert_equal "busy shared runtime lock skips the concurrent CDN guard run" \
    "${before_busy_sync}" "$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")"

module_content=$(<"${ROOT_DIR}/lib/cdn-traffic-guard.sh")
[[ "${module_content}" == *'OnUnitActiveSec=15s'* \
    && "${module_content}" == *'AccuracySec=1s'* ]] \
    || fail "global fee protection must poll within the 20 GB safety buffer"

printf 'easy_all CDN traffic guard tests passed\n'
