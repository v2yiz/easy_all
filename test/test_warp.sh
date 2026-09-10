#!/usr/bin/env bash

set -Eeuo pipefail
umask 077
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT
STATE_DIR="${TMP_DIR}/state"
RUNTIME_TMP="${TMP_DIR}/runtime"
XRAY_DIR="${TMP_DIR}/xray"
XRAY_CONFIG="${XRAY_DIR}/config.json"
XRAY_BIN="${XRAY_TEST_BIN:-${TMP_DIR}/missing-xray}"
WARP_RECOVERY_FILE_OVERRIDE="${TMP_DIR}/warp-recovery.json"
WARP_PENDING_DELETE_FILE_OVERRIDE="${TMP_DIR}/warp-pending-delete.json"
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}" "${XRAY_DIR}"
source "${ROOT_DIR}/lib/profile-common.sh"
source "${ROOT_DIR}/lib/network.sh"
source "${ROOT_DIR}/lib/xray-core.sh"
source "${ROOT_DIR}/lib/warp.sh"
die() { printf '%s\n' "$*" >&2; exit 1; }
info() { :; }
success() { :; }
warn() { :; }
fail() { die "not ok - $*"; }

PROTOCOL=cloudflare-streamup
VPS_IP_FAMILY=dual
VPS_PUBLIC_IPV6=2001:db8::2
GOOGLE_EGRESS_MODE=ipv6
GOOGLE_EGRESS_RESOLVED=ipv6
WARP_SCOPE=off

# Fixture is synthetic, including high reserved bytes to catch UTF-8 decoding.
printf '%s\n' 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' >"${TMP_DIR}/private.key"
jq -n '{
  id:"test-device",token:"test-secret-token",
  config:{
    client_id:"AYD/",
    interface:{addresses:{v4:"172.16.0.2",v6:"2606:4700:110::2"}},
    peers:[{public_key:"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
      endpoint:{host:"engage.cloudflareclient.com:2408"}}]
  }
}' >"${TMP_DIR}/response.json"
mkdir -p "$(dirname "${WARP_ACCOUNT_FILE}")"
warp_account_from_response "${TMP_DIR}/response.json" "${TMP_DIR}/private.key" "${WARP_ACCOUNT_FILE}"
warp_validate_account || fail "valid registration rejected"
jq -e '.reserved == [1,128,255]' "${WARP_ACCOUNT_FILE}" >/dev/null \
    || fail "reserved bytes were corrupted"
warp_ensure_account </dev/null || fail "existing device should be reused without prompts/network"
jq -e '.settings.noKernelTun == true and .settings.mtu == 1420 and
  .settings.domainStrategy == "ForceIPv4v6" and
  .settings.address == ["172.16.0.2/32","2606:4700:110::2/128"]' \
  <<<"$(warp_outbound_json)" >/dev/null || fail "WireGuard settings differ from expected"

for scope in off gemini google all; do
    for family in ipv4 dual; do
        WARP_SCOPE=${scope}
        VPS_IP_FAMILY=${family}
        GOOGLE_EGRESS_MODE=auto
        GOOGLE_EGRESS_RESOLVED=ipv4
        outbounds=$(xray_xhttp_outbounds_json)
        routing=$(xray_xhttp_routing_json)
        jq -e '.rules[0].outboundTag == "block" and .rules[0].ip[0] == "0.0.0.0/8" and
          .rules[1].outboundTag == "block" and .rules[1].network == "udp" and
          .rules[1].port == "443"' <<<"${routing}" >/dev/null || fail "safety rule order"
        case "${scope}" in
        off)
            jq -e 'all(.[]; .tag != "warp")' <<<"${outbounds}" >/dev/null || fail "off emits WARP"
            ;;
        gemini)
            jq -e '.rules[2].domain == ["geosite:google-gemini"] and .rules[2].outboundTag == "warp"
              and .rules[-1].outboundTag == "direct"' <<<"${routing}" >/dev/null || fail "AI scope"
            xray_geosite_required || fail "AI scope requires geodata even on IPv4"
            if [[ "${family}" == dual ]]; then
                jq -e '.rules[3].outboundTag == "direct-google-ipv4"' <<<"${routing}" >/dev/null \
                    || fail "AI override must precede native Google"
            fi
            ;;
        google | all)
            jq -e 'all(.[]; (.tag | startswith("direct-google-")) | not)' \
                <<<"${outbounds}" >/dev/null || fail "inactive native Google outbound"
            jq -e 'all(.rules[]; (.outboundTag | startswith("direct-google-")) | not)' \
                <<<"${routing}" >/dev/null || fail "inactive native Google rules"
            if [[ "${scope}" == google ]]; then
                jq -e '.rules[2].domain == ["geosite:google"] and
                  .rules[3].ip == ["geoip:google"] and .rules[-1].outboundTag == "direct"' \
                    <<<"${routing}" >/dev/null || fail "Google scope"
                xray_geosite_required || fail "Google scope requires geodata"
            else
                jq -e '.[0].tag == "warp"' <<<"${outbounds}" >/dev/null || fail "default outbound must be WARP"
                jq -e '.rules[-1].outboundTag == "warp"' <<<"${routing}" >/dev/null || fail "all scope"
                if xray_geosite_required; then fail "all-WARP does not need unused geodata"; fi
            fi
            ;;
        esac
        # Every routing tag must have a matching outbound, in all eight configurations.
        jq -en --argjson out "${outbounds}" --argjson route "${routing}" \
            '($out | map(.tag)) as $tags | all($route.rules[]; .outboundTag as $tag | $tags | index($tag) != null)' \
            >/dev/null || fail "dangling outbound tag"
        if [[ -x "${XRAY_TEST_BIN:-}" ]]; then
            jq -n --argjson out "${outbounds}" --argjson route "${routing}" \
                '{log:{loglevel:"warning"},inbounds:[],outbounds:$out,routing:$route}' \
                >"${TMP_DIR}/core-test.json"
            XRAY_LOCATION_ASSET="${XRAY_TEST_ASSET_DIR:?}" \
                "${XRAY_TEST_BIN}" run -test -config "${TMP_DIR}/core-test.json" >/dev/null \
                || fail "real Xray rejected ${scope}/${family}"
        fi
    done
done

google_egress_probe_family() { printf 'called\n' >>"${TMP_DIR}/native-probes"; return 1; }
for scope in google all; do
    WARP_SCOPE=${scope}
    VPS_IP_FAMILY=ipv4
    GOOGLE_EGRESS_MODE=ipv6
    GOOGLE_EGRESS_RESOLVED=ipv6
    choose_google_egress_mode </dev/null
    refresh_google_egress_selection
    validate_google_egress_policy_state || fail "inactive native IPv6 policy should be preserved"
    [[ "${GOOGLE_EGRESS_MODE}:${GOOGLE_EGRESS_RESOLVED}" == "ipv6:ipv6" ]] || fail "saved native policy changed"
    xray_xhttp_outbounds_json >/dev/null
    [[ ! -e "${TMP_DIR}/native-probes" ]] || fail "WARP-only Google must never probe native egress"
done
WARP_SCOPE=gemini
VPS_IP_FAMILY=dual
if (refresh_google_egress_selection) 2>/dev/null; then fail "AI-only must retain native Google probe"; fi
[[ -e "${TMP_DIR}/native-probes" ]] || fail "native Google probe skipped for AI-only"
WARP_SCOPE=off
if (refresh_google_egress_selection) 2>/dev/null; then fail "disabled WARP must restore native probe"; fi

PROTOCOL=reality
WARP_SCOPE=all
native_google_egress_enabled || fail "Reality must ignore WARP scope"
if warp_enabled; then fail "Reality must not enable WARP"; fi
jq -e 'map(.tag) == ["direct","direct-google-ipv6","block"]' \
    <<<"$(xray_xhttp_outbounds_json)" >/dev/null || fail "Reality outbound changed"
PROTOCOL=cloudflare-streamup
WARP_SCOPE=bad
if validate_warp_scope; then fail "invalid scope accepted"; fi
unset WARP_SCOPE
validate_warp_scope || fail "missing scope must mean off"
if warp_enabled; then fail "missing scope enabled WARP"; fi

WARP_SCOPE=gemini
write_xray_asset_test_config "${TMP_DIR}/asset-test.json"
jq -e '.routing.rules[-1].domain == ["geosite:google-gemini"]' \
    "${TMP_DIR}/asset-test.json" >/dev/null || fail "missing AI category verification"
WARP_SCOPE=google
write_xray_asset_test_config "${TMP_DIR}/asset-test.json"
jq -e '.routing.rules | length == 2' "${TMP_DIR}/asset-test.json" >/dev/null || fail "unused AI category"

mkdir -p "${TMP_DIR}/backup"
warp_snapshot "${TMP_DIR}/backup"
rm "${WARP_ACCOUNT_FILE}"
warp_restore "${TMP_DIR}/backup"
cmp "${TMP_DIR}/backup/warp-account.json" "${WARP_ACCOUNT_FILE}" || fail "account rollback"
mkdir -p "${TMP_DIR}/missing-backup"
rm "${WARP_ACCOUNT_FILE}"
warp_snapshot "${TMP_DIR}/missing-backup"
cp "${TMP_DIR}/backup/warp-account.json" "${WARP_ACCOUNT_FILE}"
warp_restore "${TMP_DIR}/missing-backup"
[[ -f "${WARP_ACCOUNT_FILE}" ]] || fail "rollback loses a newly registered device"
mv "${WARP_ACCOUNT_FILE}" "${WARP_RECOVERY_FILE}"
warp_ensure_account </dev/null
[[ -f "${WARP_ACCOUNT_FILE}" && -f "${WARP_RECOVERY_FILE}" ]] \
    || fail "saved registration was not recovered"
warp_finalize_recovery
[[ ! -f "${WARP_RECOVERY_FILE}" ]] || fail "successful recovery was not finalized"
rm "${WARP_ACCOUNT_FILE}"
if (warp_ensure_account </dev/null) 2>/dev/null; then fail "registration without consent"; fi
cp "${TMP_DIR}/backup/warp-account.json" "${WARP_ACCOUNT_FILE}"

jq '.reserved = [1,2,999]' "${WARP_ACCOUNT_FILE}" >"${TMP_DIR}/bad-account.json"
if warp_validate_account "${TMP_DIR}/bad-account.json"; then fail "out-of-range reserved byte"; fi
jq '.peer.endpoint = "bad.example:999999"' "${WARP_ACCOUNT_FILE}" >"${TMP_DIR}/bad-account.json"
if warp_validate_account "${TMP_DIR}/bad-account.json"; then fail "invalid endpoint"; fi
jq '.addresses = ["not-an-ip/32"]' "${WARP_ACCOUNT_FILE}" >"${TMP_DIR}/bad-account.json"
if warp_validate_account "${TMP_DIR}/bad-account.json"; then fail "invalid address"; fi
jq '.config.client_id = "!!!!"' "${TMP_DIR}/response.json" >"${TMP_DIR}/bad-response.json"
warp_capture_pending_registration "${TMP_DIR}/bad-response.json"
if (warp_account_from_response "${TMP_DIR}/bad-response.json" "${TMP_DIR}/private.key" \
    "${TMP_DIR}/bad-account.json") 2>/dev/null; then fail "malformed client_id"; fi
[[ -f "${WARP_PENDING_REGISTRATION_FILE}" ]] \
    || fail "parse failure lost registration cleanup credentials"

# Registration failures retain method/path/status and the response structure,
# while credentials are redacted and no silent curl retry is requested.
curl() {
    local output=""
    while (($#)); do
        [[ "$1" != "--retry" ]] || fail "registration must not silently retry"
        if [[ "$1" == "-o" ]]; then output=$2; shift; fi
        shift
    done
    jq -n '{errors:[{code:123,message:"registration denied"}],token:"must-not-print"}' >"${output}"
    printf 429
}
if (warp_register_request "${TMP_DIR}/response.json" "${TMP_DIR}/http-error.json") \
    2>"${TMP_DIR}/http-error.log"; then fail "HTTP error accepted"; fi
grep -q 'POST /reg（HTTP 429）' "${TMP_DIR}/http-error.log" || fail "error context"
grep -q 'registration denied' "${TMP_DIR}/http-error.log" || fail "error body"
if grep -q 'must-not-print' "${TMP_DIR}/http-error.log"; then fail "token leaked"; fi
unset -f curl

warp_capture_pending_registration "${TMP_DIR}/response.json"
jq -e '.device_id == "test-device" and .access_token == "test-secret-token" and
  (has("private_key") | not)' "${WARP_PENDING_REGISTRATION_FILE}" >/dev/null \
    || fail "registration cleanup credentials were not captured immediately"
curl() {
    local output="" headers=""
    while (($#)); do
        if [[ "$1" == "-o" ]]; then output=$2; shift; fi
        if [[ "$1" == "-H" ]]; then headers=$2; shift; fi
        shift
    done
    [[ "${headers}" == @* ]] || fail "unregister token exposed in argv"
    grep -q '^Authorization: Bearer test-secret-token$' "${headers#@}" \
        || fail "unregister authorization missing"
    : >"${output}"
    printf '%s' "${UNREGISTER_STATUS:-204}"
}
cp "${TMP_DIR}/backup/warp-account.json" "${TMP_DIR}/unregister-account.json"
warp_unregister_account "${TMP_DIR}/unregister-account.json" \
    || fail "valid registration was not unregistered"
[[ ! -f "${TMP_DIR}/unregister-account.json" ]] || fail "unregistered credential remains"
cp "${TMP_DIR}/backup/warp-account.json" "${WARP_ACCOUNT_FILE}"
WARP_ACCOUNT_CREATED=1
UNREGISTER_STATUS=500
warp_rollback_fresh_registration
[[ -f "${WARP_RECOVERY_FILE}" ]] || fail "failed unregister did not preserve recovery credentials"
rm "${WARP_RECOVERY_FILE}"
rm "${WARP_ACCOUNT_FILE}"
warp_rollback_fresh_registration
[[ -f "${WARP_PENDING_DELETE_FILE}" ]] \
    || fail "failed cleanup of malformed registration was not queued"
cp "${TMP_DIR}/backup/warp-account.json" "${WARP_ACCOUNT_FILE}"
UNREGISTER_STATUS=204
warp_ensure_account </dev/null
[[ ! -f "${WARP_PENDING_DELETE_FILE}" ]] || fail "pending unregister was not drained"
warp_finalize_recovery
unset -f curl

# Exercise temporary probe orchestration without registering a real device.
(
    WARP_SCOPE=gemini
    VPS_IP_FAMILY=ipv4
    GOOGLE_EGRESS_MODE=auto
    GOOGLE_EGRESS_RESOLVED=ipv4
    jq -n --argjson out "$(xray_xhttp_outbounds_json)" \
        --argjson route "$(xray_xhttp_routing_json)" \
        '{outbounds:$out,routing:$route,api:{},stats:{},policy:{}}' >"${XRAY_CONFIG}"
    fake_xray() {
        if [[ "$2" == "-test" ]]; then
            jq -e '.inbounds[0].listen == "127.0.0.1" and
              .routing.rules[2].outboundTag == "warp" and
              .routing.rules[3].domain == ["geosite:google-gemini"] and
              (.log.access | endswith("/access.log")) and
              (has("api") | not)' "$4" >/dev/null || return 1
            printf '%s' "${4%/*}" >"${TMP_DIR}/probe-stage"
            jq -r '.log.access' "$4" >"${TMP_DIR}/probe-access-path"
            return 0
        fi
        touch "${TMP_DIR}/probe-started"
        exec sleep 30
    }
    XRAY_BIN=fake_xray
    ss() { [[ ! -f "${TMP_DIR}/probe-started" ]] || printf 'LISTEN\n'; }
    curl() {
        [[ "$*" == *'socks5h://127.0.0.1:'* ]] || fail "probe bypasses Xray"
        if [[ "$*" == *'/cdn-cgi/trace'* ]]; then
            printf 'ip=203.0.113.1\nloc=US\nwarp=%s\r\n\n200' "${TRACE_WARP:-on}"
        else
            printf 'from tcp:127.0.0.1:12345 accepted tcp:gemini.google.com:443 [warp-check -> %s]\n' \
                "${GEMINI_ROUTE:-warp}" \
                >"$(<"${TMP_DIR}/probe-access-path")"
            printf 403
        fi
    }
    warp_validate_runtime >"${TMP_DIR}/probe-output"
    [[ ! -d "$(<"${TMP_DIR}/probe-stage")" ]] || fail "probe directory leaked"
    grep -q 'WARP 出站验证通过' "${TMP_DIR}/probe-output" || fail "trace result missing"
    rm "${TMP_DIR}/probe-started"
    TRACE_WARP=off
    if warp_validate_runtime >/dev/null 2>&1; then fail "warp=off accepted"; fi
    [[ ! -d "$(<"${TMP_DIR}/probe-stage")" ]] || fail "failed probe directory leaked"
    TRACE_WARP=on
    GEMINI_ROUTE=direct
    if warp_validate_runtime >/dev/null 2>&1; then fail "Gemini direct route accepted"; fi
)

# Check orchestration uses the guarded Google functions and preserves current
# in-memory policy rather than reloading an older state during apply.
for func in install_all apply_easy_all apply_cloud_resources update_subscription update_warp; do
    body=$(sed -n "/^${func}()/,/^}/p" "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")
    [[ "${body}" == *warp_validate_runtime* ]] || fail "${func} lacks WARP validation"
done
for func in apply_cloud_resources update_subscription; do
    body=$(sed -n "/^${func}()/,/^}/p" "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")
    before_cloud=${body%%cloudflare_prepare_origin*}
    [[ "${before_cloud}" == *xhttp_render_xray_config* \
        && "${before_cloud}" == *warp_validate_runtime* ]] \
        || fail "${func} validates WARP after Cloudflare writes"
done
body=$(sed -n '/^apply_easy_all()/,/^}/p' "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")
[[ "${body}" == *'finish_xhttp_apply 1'* ]] || fail "apply reloads stale policy"
for file in easy_all bootstrap.sh; do
    grep -q 'lib/warp.sh' "${ROOT_DIR}/${file}" || fail "missing packaged module"
done
if grep -q 'source .*warp.sh' "${ROOT_DIR}/profiles/reality.sh"; then fail "Reality loads WARP module"; fi
printf 'ok - WARP scope, registration, routing, probe guards and rollback tests passed\n'
