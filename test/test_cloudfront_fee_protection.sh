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
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}"

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
source "${ROOT_DIR}/lib/cloudfront-fee-protection.sh"

validate_cloudfront_fee_protection_gb 980 \
    || fail "980 GB protection threshold must be valid"
if validate_cloudfront_fee_protection_gb 0; then
    fail "zero must not disable the mandatory pay-as-you-go protection"
fi
assert_equal "UTC calendar month extraction" "2026-08" \
    "$(cloudfront_fee_current_period "2026-08-20")"

PROTOCOL="xhttp"
CDN_PROVIDER="aws"
AWS_CLOUDFRONT_BILLING_MODE="payg"
CLOUDFRONT_FEE_PROTECTION_GB=""
configure_cloudfront_fee_protection
assert_equal "pay-as-you-go protection defaults to 980 GB" "980" \
    "${CLOUDFRONT_FEE_PROTECTION_GB}"
cloudfront_fee_protection_enabled \
    || fail "pay-as-you-go XHTTP must enable global fee protection"
if (
    CLOUDFRONT_FEE_PROTECTION_GB=979
    configure_cloudfront_fee_protection
) >/dev/null 2>&1; then
    fail "pay-as-you-go protection threshold must stay fixed at 980 GB"
fi

totals=$(cloudfront_fee_stats_totals '{"stat":[
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
rebuild_traffic_runtime() { printf 'rebuilt\n' >"${TMP_DIR}/rebuilt"; }

period=$(cloudfront_fee_current_period)
cat >"${CLOUDFRONT_FEE_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"runtime-1","used_bytes":979900000000,
 "last_uplink":0,"last_downlink":0,"blocked":false,"enforced":false}
EOF
cloudfront_fee_protection_sync
assert_equal "980 GB threshold blocks the complete XHTTP chain" "true" \
    "$(jq -r '.blocked' "${CLOUDFRONT_FEE_USAGE_FILE}")"
assert_equal "successful rebuild records that the block is enforced" "true" \
    "$(jq -r '.enforced' "${CLOUDFRONT_FEE_USAGE_FILE}")"
assert_equal "global accounting includes both traffic directions" "980010000000" \
    "$(jq -r '.used_bytes' "${CLOUDFRONT_FEE_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] \
    || fail "crossing the global threshold must rebuild the Xray runtime"
cloudfront_fee_protection_blocked \
    || fail "blocked state must be visible to Xray config generation"

cat >"${CLOUDFRONT_FEE_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"runtime-1","used_bytes":100000000,
 "last_uplink":0,"last_downlink":0,"blocked":false,"enforced":false}
EOF
rm -f -- "${TMP_DIR}/rebuilt"
cloudfront_fee_protection_checkpoint
assert_equal "pre-restart checkpoint persists unflushed traffic" "210000000" \
    "$(jq -r '.used_bytes' "${CLOUDFRONT_FEE_USAGE_FILE}")"
[[ ! -f "${TMP_DIR}/rebuilt" ]] \
    || fail "a checkpoint records traffic without recursively rebuilding Xray"

cat >"${CLOUDFRONT_FEE_USAGE_FILE}" <<'EOF'
{"period":"2000-01","runtime_id":"runtime-1","used_bytes":980010000000,
 "last_uplink":60000000,"last_downlink":50000000,"blocked":true,"enforced":true}
EOF
rm -f -- "${TMP_DIR}/rebuilt"
cloudfront_fee_protection_sync
assert_equal "UTC natural month rollover resets protected bytes" "0" \
    "$(jq -r '.used_bytes' "${CLOUDFRONT_FEE_USAGE_FILE}")"
assert_equal "UTC natural month rollover restores XHTTP" "false" \
    "$(jq -r '.blocked' "${CLOUDFRONT_FEE_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] \
    || fail "month rollover must rebuild the runtime to restore clients"

cat >"${CLOUDFRONT_FEE_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"runtime-1","used_bytes":979900000000,
 "last_uplink":0,"last_downlink":0,"blocked":false,"enforced":false}
EOF
rebuild_traffic_runtime() { return 1; }
if (cloudfront_fee_protection_sync) >/dev/null 2>&1; then
    fail "a failed blocking transition must fail closed"
fi
assert_equal "failed runtime transition keeps the desired block for retry" "true" \
    "$(jq -r '.blocked' "${CLOUDFRONT_FEE_USAGE_FILE}")"
assert_equal "failed runtime transition remains visibly unenforced" "false" \
    "$(jq -r '.enforced' "${CLOUDFRONT_FEE_USAGE_FILE}")"
assert_equal "failed runtime transition preserves newly accounted bytes" "980010000000" \
    "$(jq -r '.used_bytes' "${CLOUDFRONT_FEE_USAGE_FILE}")"

AWS_CLOUDFRONT_BILLING_MODE="flat-free"
configure_cloudfront_fee_protection
assert_equal "flat-rate mode disables the pay-as-you-go guard" "0" \
    "${CLOUDFRONT_FEE_PROTECTION_GB}"
if cloudfront_fee_protection_enabled; then
    fail "flat-rate mode must not enable the pay-as-you-go guard"
fi

CDN_PROVIDER="gcore"
AWS_CLOUDFRONT_BILLING_MODE="flat-free"
CLOUDFRONT_FEE_PROTECTION_GB=""
configure_cloudfront_fee_protection
assert_equal "Gcore Free CDN enables the same 980 GB global guard" "980" \
    "${CLOUDFRONT_FEE_PROTECTION_GB}"
cloudfront_fee_protection_enabled \
    || fail "Gcore Free CDN must enable the global guard independently of AWS billing"
assert_equal "Gcore guard labels its operator output" "Gcore" "$(cdn_fee_provider_label)"
assert_equal "Gcore guard uses its private sync command" "gcore-fee-sync" \
    "$(cdn_fee_sync_command)"

module_content=$(<"${ROOT_DIR}/lib/cloudfront-fee-protection.sh")
[[ "${module_content}" == *'OnUnitActiveSec=15s'* \
    && "${module_content}" == *'AccuracySec=1s'* ]] \
    || fail "global fee protection must poll within the 20 GB safety buffer"

printf 'easy_all CloudFront fee protection tests passed\n'
