#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

STATE_DIR="${TMP_DIR}/state"
SUBSCRIPTION_DIR="${TMP_DIR}/subscriptions"
SUB_DOWNLOAD_NAME="EASY_ALL"
XRAY_SERVICE="easy_all-xray.service"
COMMAND_PATH="/usr/local/bin/easy_all"
RUNTIME_TMP="${TMP_DIR}/runtime"
cleanup_files=()
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}"

die() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

prompt_value() {
    printf '%s' "$2"
}

generate_secret() {
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

info() { :; }

normalize_allowed_tokens() {
    local raw=$1
    jq -ce '
        if type == "object" and length > 0 and
          all(to_entries[];
            (.key|test("^[A-Za-z0-9._-]{1,64}$")) and
            (.value|type == "string" and test("^[A-Za-z0-9._~-]{8,128}$"))) and
          ([.[]]|length == (unique|length))
        then . else error("invalid tokens") end
    ' <<<"${raw}"
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/quota.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected [${expected}], got [${actual}]"
}

tokens='{"user1":"user1-token-123","owner":"owner-token-123"}'
quotas=$(normalize_monthly_quotas '{"owner":0,"user1":100}')
assert_equal "quota map is normalized" '{"owner":0,"user1":100}' "${quotas}"

if normalize_monthly_quotas '{}' >/dev/null 2>&1; then
    fail "quota map must contain at least one user"
fi

generated_tokens=$(build_quota_tokens "${quotas}" '{"owner":"owner-token-123"}')
assert_equal "existing owner token is preserved" "owner-token-123" \
    "$(jq -r '.owner' <<<"${generated_tokens}")"
[[ "$(jq -r '.user1' <<<"${generated_tokens}")" =~ ^[A-Za-z0-9._~-]{8,128}$ ]] \
    || fail "new quota user must receive an automatically generated token"
overridden_tokens=$(apply_quota_token_overrides "${generated_tokens}" "${quotas}" \
    '{"user1":"custom-user1-token"}')
assert_equal "token override changes only the selected user" "custom-user1-token" \
    "$(jq -r '.user1' <<<"${overridden_tokens}")"
assert_equal "token override preserves unspecified users" "owner-token-123" \
    "$(jq -r '.owner' <<<"${overridden_tokens}")"
if (apply_quota_token_overrides "${generated_tokens}" "${quotas}" \
    '{"unknown":"unknown-token-123"}') >/dev/null 2>&1; then
    fail "token override must reject unknown users"
fi

validate_quota_start_date "2024-02-29" "2026-08-19" \
    || fail "valid leap-day start date must be accepted"
if validate_quota_start_date "2025-02-29" "2026-08-19"; then
    fail "invalid calendar date must be rejected"
fi
if validate_quota_start_date "2027-01-01" "2026-08-19"; then
    fail "future start date must be rejected"
fi
QUOTA_START_DATE="2025-01-15"
assert_equal "billing cycle before anchor day" "2026-07-15/2026-08-15" \
    "$(quota_current_period "2026-08-14")"
assert_equal "billing cycle starts on anchor day" "2026-08-15/2026-09-15" \
    "$(quota_current_period "2026-08-15")"
QUOTA_START_DATE="2025-01-31"
assert_equal "month-end anchor clamps in February" "2026-02-28/2026-03-31" \
    "$(quota_current_period "2026-02-28")"

VLESS_UUID="00000000-0000-4000-8000-000000000001"
accounts=$(build_user_accounts "${tokens}" "${quotas}" '{}')
validate_user_accounts "${accounts}" || fail "generated user accounts must be valid"
assert_equal "owner preserves the original UUID" "${VLESS_UUID}" \
    "$(jq -r '.owner.uuid' <<<"${accounts}")"
[[ "$(jq -r '.user1.uuid' <<<"${accounts}")" != "${VLESS_UUID}" ]] \
    || fail "non-owner user must receive an independent UUID"

legacy_accounts='{"user1":{"token":"user1-token-123","uuid":"00000000-0000-4000-8000-000000000001","quota_gb":100}}'
accounts_with_new_owner=$(build_user_accounts "${tokens}" "${quotas}" "${legacy_accounts}")
assert_equal "a newly added owner claims the original UUID" "${VLESS_UUID}" \
    "$(jq -r '.owner.uuid' <<<"${accounts_with_new_owner}")"
[[ "$(jq -r '.user1.uuid' <<<"${accounts_with_new_owner}")" != "${VLESS_UUID}" ]] \
    || fail "existing non-owner must rotate away from the original UUID when owner is added"

QUOTA_ENABLED=1
USER_ACCOUNTS=${accounts}
ALLOWED_TOKENS=${tokens}
QUOTA_START_DATE="2025-01-15"
unset ENABLE_MONTHLY_QUOTA MONTHLY_QUOTAS_GB QUOTA_TOKEN_OVERRIDES
choose_monthly_quota 1
assert_equal "non-interactive update preserves enabled quota mode" "1" "${QUOTA_ENABLED}"
assert_equal "non-interactive update preserves an existing user quota" "100" \
    "$(jq -r '.user1.quota_gb' <<<"${USER_ACCOUNTS}")"
assert_equal "non-interactive update preserves billing anchor" "2025-01-15" \
    "${QUOTA_START_DATE}"
period=$(quota_current_period)
assert_equal "usage period follows the configured billing anchor" "${period}" \
    "$(quota_current_period)"
cat >"${QUOTA_USAGE_FILE}" <<'EOF'
{"period":"2026-08","users":{
  "owner":{"used_bytes":0,"last_uplink":0,"last_downlink":0,"disabled":false},
  "user1":{"used_bytes":100000000000,"last_uplink":0,"last_downlink":0,"disabled":true}
}}
EOF
active=$(quota_active_accounts_json)
assert_equal "disabled user is removed from active accounts" '["owner"]' \
    "$(jq -c 'keys' <<<"${active}")"
clients=$(quota_active_clients_json "xtls-rprx-vision")
assert_equal "only active user is emitted to Xray" '["easy_all.owner"]' \
    "$(jq -c 'map(.email)' <<<"${clients}")"

USER_ACCOUNTS='{"owner":{"token":"owner-token-123","uuid":"00000000-0000-4000-8000-000000000001","quota_gb":1}}'
cat >"${QUOTA_USAGE_FILE}" <<EOF
{"period":"${period}","users":{
  "owner":{"used_bytes":0,"last_uplink":0,"last_downlink":0,"disabled":false}
}}
EOF
XRAY_BIN="${TMP_DIR}/xray"
cat >"${XRAY_BIN}" <<'EOF'
#!/bin/sh
cat <<'JSON'
{"stat":[
  {"name":"user>>>easy_all.owner>>>traffic>>>uplink","value":600000000},
  {"name":"user>>>easy_all.owner>>>traffic>>>downlink","value":500000000}
]}
JSON
EOF
chmod 0755 "${XRAY_BIN}"
require_root() { :; }
collect_installed_state() { :; }
rebuild_traffic_runtime() { printf 'rebuilt\n' >"${TMP_DIR}/rebuilt"; }
quota_sync_usage
assert_equal "quota sync accumulates uplink and downlink" "1100000000" \
    "$(jq -r '.users.owner.used_bytes' "${QUOTA_USAGE_FILE}")"
assert_equal "quota sync disables an over-quota user" "true" \
    "$(jq -r '.users.owner.disabled' "${QUOTA_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] || fail "quota transition must rebuild the runtime"

cat >"${QUOTA_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"","users":{
  "owner":{"used_bytes":0,"last_uplink":0,"last_downlink":0,"disabled":false}
}}
EOF
rebuild_traffic_runtime() { return 1; }
if (quota_sync_usage) >/dev/null 2>&1; then
    fail "quota sync must fail when the runtime transition fails"
fi
assert_equal "failed runtime transition restores previous accounting state" "0" \
    "$(jq -r '.users.owner.used_bytes' "${QUOTA_USAGE_FILE}")"
rebuild_traffic_runtime() { printf 'rebuilt\n' >"${TMP_DIR}/rebuilt"; }

cat >"${QUOTA_USAGE_FILE}" <<'EOF'
{"period":"2000-01","runtime_id":"","users":{
  "owner":{"used_bytes":900000000,"last_uplink":600000000,"last_downlink":500000000,"disabled":true}
}}
EOF
rm -f -- "${TMP_DIR}/rebuilt"
quota_sync_usage
assert_equal "new month starts from zero instead of recounting old Xray counters" "0" \
    "$(jq -r '.users.owner.used_bytes' "${QUOTA_USAGE_FILE}")"
assert_equal "new month restores the user" "false" \
    "$(jq -r '.users.owner.disabled' "${QUOTA_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] || fail "month rollover must rebuild the runtime"

USER_ACCOUNTS='{"owner":{"token":"owner-token-123","uuid":"00000000-0000-4000-8000-000000000001","quota_gb":1}}'
cat >"${QUOTA_USAGE_FILE}" <<EOF
{"period":"${period}","runtime_id":"","users":{
  "owner":{"used_bytes":1100000000,"last_uplink":600000000,"last_downlink":500000000,"disabled":true}
}}
EOF
save_state() { :; }
success() { :; }
show_quota_status() { :; }
rebuild_traffic_runtime() { printf 'rebuilt\n' >"${TMP_DIR}/rebuilt"; }
rm -f -- "${TMP_DIR}/rebuilt"
quota_set_user owner 2
assert_equal "quota-set changes only the selected user quota" "2" \
    "$(jq -r '.owner.quota_gb' <<<"${USER_ACCOUNTS}")"
assert_equal "raising quota preserves current usage" "1100000000" \
    "$(jq -r '.users.owner.used_bytes' "${QUOTA_USAGE_FILE}")"
assert_equal "raising quota restores an eligible disabled user" "false" \
    "$(jq -r '.users.owner.disabled' "${QUOTA_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] || fail "quota-set status transition must rebuild runtime"

rm -f -- "${TMP_DIR}/rebuilt"
quota_reset_user owner
assert_equal "quota-reset clears current-month usage" "0" \
    "$(jq -r '.users.owner.used_bytes' "${QUOTA_USAGE_FILE}")"
assert_equal "quota-reset preserves configured quota" "2" \
    "$(jq -r '.owner.quota_gb' <<<"${USER_ACCOUNTS}")"
[[ ! -f "${TMP_DIR}/rebuilt" ]] \
    || fail "resetting an active user should not restart the runtime"

usage=$(jq -c '.users.owner.disabled=true | .users.owner.used_bytes=2000000000' \
    "${QUOTA_USAGE_FILE}")
printf '%s\n' "${usage}" >"${QUOTA_USAGE_FILE}"
quota_reset_user owner
assert_equal "quota-reset immediately restores a disabled user" "false" \
    "$(jq -r '.users.owner.disabled' "${QUOTA_USAGE_FILE}")"
[[ -f "${TMP_DIR}/rebuilt" ]] || fail "resetting a disabled user must rebuild runtime"

printf 'easy_all quota tests passed\n'
