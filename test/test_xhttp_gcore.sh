#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/xhttp_gcore.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
XRAY_RENDER_CONTENT=$(sed -n '/^xhttp_render_xray_config()/,/^}/p' "${PROFILE}")
MIHOMO_RENDER_CONTENT=$(sed -n '/^build_mihomo_node()/,/^}/p' "${XHTTP_RUNTIME}")

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
    [[ "${value}" == *"${expected}"* ]] \
        || fail "${label}: missing [${expected}]"
}

assert_not_contains() {
    local label=$1 value=$2 unexpected=$3
    [[ "${value}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected [${unexpected}]"
}

bash -n "${PROFILE}"
if standalone_output=$(bash "${PROFILE}" 2>&1); then
    fail "Gcore profile must not be a standalone entry point"
fi
assert_contains "standalone profile directs users to unified entry" \
    "${standalone_output}" "easy_all install"

profile_content="$(<"${PROFILE}")"$'\n'"$(<"${XHTTP_RUNTIME}")"
assert_contains "Gcore profile uses permanent API token authentication" \
    "${profile_content}" "Authorization: APIKey"
assert_contains "Gcore profile manages DNS zones" \
    "${profile_content}" "/dns/v2/zones"
assert_contains "Gcore profile manages origin groups" \
    "${profile_content}" "/cdn/origin_groups"
assert_contains "Gcore profile manages CDN resources" \
    "${profile_content}" "/cdn/resources"
assert_contains "Gcore profile requests edge certificates" \
    "${profile_content}" "/cdn/sslData"
assert_contains "Gcore profile validates Let's Encrypt before issuing" \
    "${profile_content}" "/ssl/le/pre-validate"
assert_contains "Gcore profile limits XHTTP stream-up for its origin timeout" \
    "${profile_content}" 'readonly GCORE_XHTTP_STREAM_UP_SERVER_SECS="10-14"'
assert_contains "Gcore profile persists its CDN provider" \
    "${profile_content}" "CDN_PROVIDER=%q\\n' \"gcore\""
assert_contains "Gcore profile persists the CDN client family" \
    "${profile_content}" 'CDN_CLIENT_IP_FAMILY=%q'
assert_contains "Gcore uses the shared IPv4 direct outbound policy" \
    "${XRAY_RENDER_CONTENT}" 'xray_direct_outbounds_json'
assert_contains "Gcore client family resolution stays in the shared XHTTP runtime" \
    "${profile_content}" 'resolve_cdn_client_ip_family'
assert_not_contains "Gcore Xray egress does not depend on the client family" \
    "${XRAY_RENDER_CONTENT}" "CDN_CLIENT_IP_FAMILY"
assert_contains "Gcore profile enables an origin-only secret header" \
    "${profile_content}" '"X-Easy-All-Origin-Key"'
assert_contains "Gcore profile enables explicit gRPC pass-through" \
    "${profile_content}" 'grpc_passthrough:{enabled:true,value:true}'
assert_not_contains "Gcore profile never persists the API token" \
    "${profile_content}" "GCORE_API_TOKEN=%q"

(
    # shellcheck source=/dev/null
    source "${PROFILE}"

    assert_equal "Gcore reuses the XHTTP runtime" "xhttp" "${EASY_ALL_PROFILE}"
    assert_equal "Gcore fee protection default" "980" "${DEFAULT_GCORE_FEE_PROTECTION_GB}"
    assert_equal "Gcore stream-up stays below HTTP/2 idle timeout" \
        "10-14" "${GCORE_XHTTP_STREAM_UP_SERVER_SECS}"
    assert_equal "Gcore client H2 ping stays below HTTP/2 idle timeout" \
        "10" "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}"
    ! declare -F install_aws_cli >/dev/null \
        || fail "Gcore profile must not load the AWS provider"
    ! declare -F configure_aws_cdn >/dev/null \
        || fail "Gcore profile must not expose CloudFront operations"

    GCORE_API_TOKEN='gcore$token-with-a-special-character'
    gcore_collect_api_token

    PROTOCOL="xhttp"
    CDN_PROVIDER="gcore"
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    GCORE_FEE_PROTECTION_GB=""
    CLOUDFRONT_FEE_PROTECTION_GB=""
    configure_gcore_fee_protection
    assert_equal "Gcore always enables the 980 GB local guard" "980" \
        "${CLOUDFRONT_FEE_PROTECTION_GB}"
    cloudfront_fee_protection_enabled \
        || fail "Gcore CDN XHTTP must enable the global guard"
    assert_equal "Gcore guard uses provider name" "Gcore" "$(cdn_fee_provider_label)"
    assert_equal "Gcore timer invokes the correct unified command" "gcore-fee-sync" \
        "$(cdn_fee_sync_command)"

    VLESS_CDN_DOMAIN="node.example.com"
    GCORE_ORIGIN_DOMAIN="origin.example.com"
    GCORE_ORIGIN_GROUP_ID="42"
    ORIGIN_HEADER_SECRET="0123456789abcdef"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    XHTTP_NODE_NAME="GCORE_XHTTP_TEST"
    XHTTP_PATH="/xhttp-test-path"
    CDN_CLIENT_IP_FAMILY="ipv4"
    CDN_CLIENT_IP_FAMILY_RESOLVED=""
    mihomo=$(build_mihomo_node)
    assert_contains "Gcore Mihomo node pings before the edge H2 idle timeout" \
        "${mihomo}" "h-keep-alive-period: 10"
    resource_payload=$(gcore_resource_payload)
    assert_equal "resource is HTTPS-to-origin" "HTTPS" \
        "$(jq -r '.originProtocol' <<<"${resource_payload}")"
    assert_equal "resource disables edge cache" "0s" \
        "$(jq -r '.options.edge_cache_settings.value' <<<"${resource_payload}")"
    assert_equal "resource enables gRPC pass-through" "true" \
        "$(jq -r '.options.grpc_passthrough.enabled and .options.grpc_passthrough.value' \
            <<<"${resource_payload}")"
    assert_equal "resource keeps request queries" "false" \
        "$(jq -r '.options.ignoreQueryString.value' <<<"${resource_payload}")"
    assert_equal "resource protects origin requests" "0123456789abcdef" \
        "$(jq -r '.options.staticRequestHeaders.value["X-Easy-All-Origin-Key"]' <<<"${resource_payload}")"
    assert_equal "resource refresh never disables an existing edge certificate" "null" \
        "$(jq -r '.sslEnabled' <<<"${resource_payload}")"

    gcore_api_request() {
        case "$2" in
        '/dns/v2/zones?limit=1000')
            printf '%s\n' '[{"name":"example.com"},{"name":"sub.example.com"}]'
            ;;
        '/dns/v2/analyze/sub.example.com/delegation-status')
            printf '%s\n' '{"zone_exists":true,"gcore_authorized_count":2,"non_gcore_authorized_count":0}'
            ;;
        *) fail "unexpected mocked Gcore API path: $2" ;;
        esac
    }
    assert_equal "Gcore chooses the most-specific managed DNS zone" "sub.example.com" \
        "$(gcore_find_zone_for_domain node.sub.example.com)"
    gcore_verify_zone_delegation "sub.example.com"
)

printf 'easy_all Gcore CDN profile tests passed\n'
