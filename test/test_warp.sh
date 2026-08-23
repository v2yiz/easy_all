#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected [${expected}], got [${actual}]"
}

assert_contains() {
    local label=$1 value=$2 expected=$3
    [[ "${value}" == *"${expected}"* ]] || fail "${label}: missing [${expected}]"
}

STATE_DIR="${TMP_DIR}/state"
RUNTIME_TMP="${TMP_DIR}/runtime"
XRAY_BIN="${TMP_DIR}/xray"
GEMINI_OUTBOUND_DOMAIN_STRATEGY="ForceIPv4"
GEMINI_DOMAIN_SUFFIXES_JSON='["google.com","googleapis.com","gstatic.com"]'
AI_WARP_DOMAIN_SUFFIXES_JSON='["google.com","googleapis.com","gstatic.com","openai.com","chatgpt.com","anthropic.com","claude.ai"]'
install -d -m 0700 "${STATE_DIR}" "${RUNTIME_TMP}"

die() {
    fail "$*"
}

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/warp.sh"

assert_equal "default WARP mode" "ai" "${DEFAULT_WARP_MODE}"
(
    unset WARP_MODE
    choose_warp_mode
    assert_equal "fresh non-interactive choice defaults to AI WARP" "ai" "${WARP_MODE}"
)
(
    unset WARP_MODE
    configure_loaded_warp_mode
    assert_equal "legacy state migrates with WARP disabled" "off" "${WARP_MODE}"
)
assert_equal "numeric AI mode normalization" "ai" "$(normalize_warp_mode 2)"
assert_equal "global mode normalization" "global" "$(normalize_warp_mode global)"
if normalize_warp_mode unexpected >/dev/null 2>&1; then
    fail "unknown WARP modes must be rejected"
fi

install -d -m 0700 "${WARP_DIR}"
printf '%s\n' \
    '[Interface]' \
    'PrivateKey = YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=' \
    'Address = 172.16.0.2/32, 2606:4700:110:8765::2/128' \
    'MTU = 1280' \
    '' \
    '[Peer]' \
    'PublicKey = YmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmI=' \
    'AllowedIPs = 0.0.0.0/0, ::/0' \
    'Endpoint = engage.cloudflareclient.com:2408' >"${WARP_PROFILE_FILE}"
chmod 0600 "${WARP_PROFILE_FILE}"

validate_warp_profile || fail "valid wgcf profile must be accepted"
profile_json=$(warp_profile_values_json)
jq -e '
    .endpoint == "engage.cloudflareclient.com:2408"
    and .addresses == ["172.16.0.2/32","2606:4700:110:8765::2/128"]
    and .allowed_ips == ["0.0.0.0/0","::/0"]
    and .mtu == 1280
' <<<"${profile_json}" >/dev/null || fail "wgcf profile parsing is invalid"

WARP_MODE="ai"
outbounds=$(warp_xray_outbounds_json)
routing=$(warp_xray_routing_json)
jq -e '
    map(.tag) == ["direct","warp","block"]
    and .[1].protocol == "wireguard"
    and .[1].settings.noKernelTun == true
    and .[1].settings.mtu == 1280
    and .[1].settings.domainStrategy == "ForceIPv4"
    and .[1].settings.peers[0].keepAlive == 25
' <<<"${outbounds}" >/dev/null || fail "AI WARP outbound is invalid"
jq -e '
    .domainStrategy == "IPOnDemand"
    and .rules[0].outboundTag == "block"
    and (.rules[0].ip | index("169.254.0.0/16"))
    and .rules[1].outboundTag == "warp"
    and (.rules[1].domain | index("domain:openai.com"))
    and (.rules[1].domain | index("domain:claude.ai"))
    and (.rules[1].domain | index("domain:gstatic.com"))
    and .rules[2] == {type:"field",network:"tcp,udp",outboundTag:"direct"}
' <<<"${routing}" >/dev/null || fail "AI WARP routing policy is invalid"

WARP_MODE="global"
routing=$(warp_xray_routing_json)
jq -e '
    (.rules | length) == 2
    and .rules[0].outboundTag == "block"
    and .rules[1] == {type:"field",network:"tcp,udp",outboundTag:"warp"}
' <<<"${routing}" >/dev/null || fail "Global WARP routing policy is invalid"

WARP_MODE="off"
outbounds=$(warp_xray_outbounds_json)
routing=$(warp_xray_routing_json)
jq -e '
    map(.tag) == ["direct","gemini-family","block"]
    and .[1].settings.domainStrategy == "ForceIPv4"
' <<<"${outbounds}" >/dev/null || fail "disabled WARP must preserve the Gemini IPv4 policy"
jq -e '
    .domainStrategy == "IPOnDemand"
    and .rules[0].outboundTag == "block"
    and (.rules[0].ip | index("169.254.0.0/16"))
    and (.rules[1].domain | index("domain:google.com"))
    and (.rules[1].domain | index("domain:gstatic.com"))
    and .rules[2].outboundTag == "direct"
' <<<"${routing}" >/dev/null || fail "disabled WARP routing policy is invalid"

module_content=$(<"${ROOT_DIR}/lib/warp.sh")
assert_contains "WARP registration accepts the service terms explicitly" \
    "${module_content}" 'register --accept-tos'
assert_contains "wgcf download verifies SHA256" "${module_content}" \
    'sha256sum "${destination}"'
[[ "${module_content}" != *'wg-quick'* \
    && "${module_content}" != *'ip route'* \
    && "${module_content}" != *'warp-cli'* ]] \
    || fail "Xray WARP must not mutate the host network"

printf 'invalid\n' >"${WARP_PROFILE_FILE}"
if validate_warp_profile; then
    fail "invalid WARP profiles must be rejected"
fi

printf 'ok - WARP shell tests passed\n'
