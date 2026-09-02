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
CDN_PROVIDER="cloudflare"
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

CLOUDFLARE_CDN_ENDPOINT_MODE=domain
cdn_optimization_enabled \
    || fail "Cloudflare optimization must not depend on the removed endpoint mode"

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
