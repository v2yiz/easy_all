#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/xhttp-gcore.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT
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
assert_contains "Gcore profile persists the managed subscription hostname" \
    "${profile_content}" "SUBSCRIPTION_DOMAIN=%q"
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
assert_not_contains "Gcore profile omits the fixed CDN client family" \
    "${profile_content}" 'CDN_CLIENT_IP_FAMILY=%q'
assert_contains "Gcore cloud apply preserves freshly synced provider state" \
    "${profile_content}" 'finish_xhttp_apply 1'
assert_contains "shared XHTTP runtime can refresh without reloading stale state" \
    "${profile_content}" 'XHTTP_RUNTIME_STATE_CURRENT'
assert_contains "Gcore uses the shared XHTTP outbound policy" \
    "${XRAY_RENDER_CONTENT}" 'xray_xhttp_outbounds_json'
assert_contains "Gcore uses the shared XHTTP routing policy" \
    "${XRAY_RENDER_CONTENT}" 'xray_xhttp_routing_json'
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
    assert_equal "CDN traffic protection default" "980" "${DEFAULT_CDN_TRAFFIC_PROTECTION_GB}"
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
    CDN_TRAFFIC_PROTECTION_GB=""
    configure_cdn_traffic_protection
    assert_equal "Gcore always enables the 980 GB local guard" "980" \
        "${CDN_TRAFFIC_PROTECTION_GB}"
    cdn_traffic_protection_enabled \
        || fail "Gcore CDN XHTTP must enable the global guard"
    assert_equal "Gcore guard uses provider name" "Gcore" "$(cdn_traffic_provider_label)"
    assert_equal "Gcore timer invokes the correct unified command" "cdn-traffic-sync" \
        "$(cdn_traffic_sync_command)"

    VLESS_CDN_DOMAIN="node.example.com"
    GCORE_ORIGIN_DOMAIN="origin.example.com"
    GCORE_ORIGIN_GROUP_ID="42"
    ORIGIN_HEADER_SECRET="0123456789abcdef"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    XHTTP_NODE_NAME="GCORE_XHTTP_TEST"
    XHTTP_PATH="/xhttp-test-path"
    CDN_CLIENT_IP_FAMILY="auto"
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
    assert_equal "resource omits a secondary hostname when subscription reuses the CDN domain" \
        "[]" "$(jq -c '.secondaryHostnames' <<<"${resource_payload}")"
    SUBSCRIPTION_MODE="deploy"
    SUBSCRIPTION_DOMAIN="subscribe.other.net"
    resource_payload=$(gcore_resource_payload)
    assert_equal "resource adds the complete subscription hostname as a secondary hostname" \
        '["subscribe.other.net"]' \
        "$(jq -c '.secondaryHostnames' <<<"${resource_payload}")"
    unset SUBSCRIPTION_DOMAIN

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

    GCORE_DNS_ZONE="example.com"
    GCORE_ORIGIN_DOMAIN="origin.example.com"
    VLESS_CDN_DOMAIN="node.example.com"
    gcore_validate_dns_zones
    if (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VLESS_CDN_DOMAIN="node.example.com"
        SUBSCRIPTION_MODE="deploy"
        SUBSCRIPTION_DOMAIN="subscribe.other.net"
        gcore_api_request() {
            case "$2" in
            '/dns/v2/zones?limit=1000')
                printf '%s\n' '[{"name":"example.com"}]'
                ;;
            *) fail "unexpected mocked Gcore API path: $2" ;;
            esac
        }
        gcore_validate_dns_zones
    ) >/dev/null 2>&1; then
        fail "Gcore custom subscription domains must be hosted by Gcore Managed DNS"
    fi
    (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VLESS_CDN_DOMAIN="node.example.com"
        SUBSCRIPTION_MODE="deploy"
        SUBSCRIPTION_DOMAIN="subscribe.other.net"
        gcore_api_request() {
            case "$2" in
            '/dns/v2/zones?limit=1000')
                printf '%s\n' '[{"name":"example.com"},{"name":"other.net"}]'
                ;;
            *) fail "unexpected mocked Gcore API path: $2" ;;
            esac
        }
        gcore_validate_dns_zones
        assert_equal "Gcore accepts a subscription domain in another managed zone" \
            "other.net" "${GCORE_SUBSCRIPTION_DNS_ZONE}"
    )
    if (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VLESS_CDN_DOMAIN="node.other.com"
        gcore_api_request() {
            case "$2" in
            '/dns/v2/zones?limit=1000')
                printf '%s\n' '[{"name":"example.com"},{"name":"other.com"}]'
                ;;
            *) fail "unexpected mocked Gcore API path: $2" ;;
            esac
        }
        gcore_validate_dns_zones
    ) >/dev/null 2>&1; then
        fail "Gcore CDN domain must belong to the same managed DNS zone"
    fi
    if (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VLESS_CDN_DOMAIN="example.com"
        gcore_validate_dns_zones
    ) >/dev/null 2>&1; then
        fail "Gcore CDN domain must not use the zone apex CNAME"
    fi

    origin_calls_file="${TMP_DIR}/gcore-origin-calls"
    : >"${origin_calls_file}"
    (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VPS_PUBLIC_IPV4="203.0.113.10"
        gcore_api_get_optional() {
            case "$1" in
            */origin.example.com/A)
                printf '%s\n' '{"resource_records":[{"content":["203.0.113.10"]}]}'
                ;;
            */origin.example.com/AAAA | */origin.example.com/CNAME)
                return 1
                ;;
            *) fail "unexpected mocked Gcore DNS lookup: $1" ;;
            esac
        }
        gcore_api_request() { printf '%s %s\n' "$1" "$2" >>"${origin_calls_file}"; }
        gcore_ensure_origin_a_record
    )
    assert_equal "Gcore source A is idempotent when already exact" "" \
        "$(<"${origin_calls_file}")"

    if (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VPS_PUBLIC_IPV4="203.0.113.10"
        unset GCORE_DNS_REPLACE
        gcore_api_get_optional() {
            case "$1" in
            */origin.example.com/A | */origin.example.com/CNAME)
                return 1
                ;;
            */origin.example.com/AAAA)
                printf '%s\n' '{"resource_records":[{"content":["2001:db8::1"]}]}'
                ;;
            *) fail "unexpected mocked Gcore DNS lookup: $1" ;;
            esac
        }
        gcore_api_request() { fail "Gcore source A conflict must not mutate DNS"; }
        gcore_ensure_origin_a_record
    ) >/dev/null 2>&1; then
        fail "Gcore source A must reject AAAA conflicts by default"
    fi

    : >"${origin_calls_file}"
    (
        GCORE_DNS_ZONE="example.com"
        GCORE_ORIGIN_DOMAIN="origin.example.com"
        VPS_PUBLIC_IPV4="203.0.113.10"
        GCORE_DNS_REPLACE=1
        gcore_api_get_optional() {
            case "$1" in
            */origin.example.com/A)
                printf '%s\n' '{"resource_records":[{"content":["198.51.100.7"]}]}'
                ;;
            */origin.example.com/AAAA)
                printf '%s\n' '{"resource_records":[{"content":["2001:db8::1"]}]}'
                ;;
            */origin.example.com/CNAME)
                return 1
                ;;
            *) fail "unexpected mocked Gcore DNS lookup: $1" ;;
            esac
        }
        gcore_api_request() { printf '%s %s\n' "$1" "$2" >>"${origin_calls_file}"; }
        gcore_ensure_origin_a_record
    )
    origin_replace_calls=$(<"${origin_calls_file}")
    assert_contains "Gcore source A replacement deletes stale A" \
        "${origin_replace_calls}" "DELETE /dns/v2/zones/example.com/origin.example.com/A"
    assert_contains "Gcore source A replacement deletes stale AAAA" \
        "${origin_replace_calls}" "DELETE /dns/v2/zones/example.com/origin.example.com/AAAA"
    assert_contains "Gcore source A replacement writes current A" \
        "${origin_replace_calls}" "PUT /dns/v2/zones/example.com/origin.example.com/A"

    cname_calls_file="${TMP_DIR}/gcore-cname-calls"
    : >"${cname_calls_file}"
    (
        GCORE_CDN_TARGET="node.example.com.gcdn.co"
        gcore_api_get_optional() {
            case "$1" in
            */subscribe.example.net/A | */subscribe.example.net/AAAA)
                return 1
                ;;
            */subscribe.example.net/CNAME)
                printf '%s\n' '{"resource_records":[{"content":["node.example.com.gcdn.co."]}]}'
                ;;
            *) fail "unexpected mocked Gcore DNS lookup: $1" ;;
            esac
        }
        gcore_api_request() { printf '%s %s\n' "$1" "$2" >>"${cname_calls_file}"; }
        gcore_ensure_domain_cname_record "subscribe.example.net" "example.net"
    )
    assert_equal "Gcore reuses an exact existing subscription CNAME without a write" \
        "" "$(<"${cname_calls_file}")"

    : >"${cname_calls_file}"
    (
        GCORE_CDN_TARGET="node.example.com.gcdn.co"
        gcore_api_get_optional() { return 1; }
        gcore_api_request() { printf '%s %s\n' "$1" "$2" >>"${cname_calls_file}"; }
        gcore_ensure_domain_cname_record "subscribe.example.net" "example.net"
    )
    assert_contains "Gcore creates a subscription CNAME only when it is missing" \
        "$(<"${cname_calls_file}")" \
        "PUT /dns/v2/zones/example.net/subscribe.example.net/CNAME"
    if (
        GCORE_CDN_TARGET="node.example.com.gcdn.co"
        GCORE_DNS_REPLACE=1
        gcore_api_get_optional() {
            case "$1" in
            */subscribe.example.net/A | */subscribe.example.net/AAAA)
                return 1
                ;;
            */subscribe.example.net/CNAME)
                printf '%s\n' '{"resource_records":[{"content":["other.gcdn.co"]}]}'
                ;;
            *) fail "unexpected mocked Gcore DNS lookup: $1" ;;
            esac
        }
        gcore_api_request() { fail "a conflicting custom subscription record must never be mutated"; }
        gcore_ensure_domain_cname_record "subscribe.example.net" "example.net" 0
    ) >/dev/null 2>&1; then
        fail "Gcore custom subscription DNS conflicts must be rejected even with replacement enabled"
    fi

    certificate_calls_file="${TMP_DIR}/gcore-certificate-calls"
    : >"${certificate_calls_file}"
    (
        GCORE_CDN_RESOURCE_ID="77"
        GCORE_SSL_CERT_ID="88"
        gcore_api_request() {
            printf '%s %s %s\n' "$1" "$2" "${3:-}" >>"${certificate_calls_file}"
            case "$1 $2" in
            'GET /cdn/sslData/88')
                printf '%s\n' '{"id":88,"automated":true}'
                ;;
            esac
        }
        gcore_ensure_edge_certificate
    )
    certificate_calls=$(<"${certificate_calls_file}")
    assert_contains "Gcore reuses the existing automated certificate after adding a hostname" \
        "${certificate_calls}" 'GET /cdn/sslData/88'
    assert_contains "Gcore keeps the existing certificate attached to the CDN resource" \
        "${certificate_calls}" 'PATCH /cdn/resources/77 {"sslEnabled":true,"sslData":88}'
    assert_not_contains "Gcore does not create a competing certificate for a secondary hostname" \
        "${certificate_calls}" 'POST /cdn/sslData '

    add_custom_subscription_calls=$(
        require_root() { :; }
        begin_quota_maintenance() { :; }
        end_quota_maintenance() { :; }
        collect_installed_state() {
            SUBSCRIPTION_MODE="link"
            VLESS_CDN_DOMAIN="node.example.com"
            SUBSCRIPTION_DOMAIN="node.example.com"
            SUB_DOWNLOAD_NAME="EASY_ALL_TEST"
            QUOTA_ENABLED=0
        }
        snapshot_subscription_update() { UPDATE_SUB_ROLLBACK_ON_EXIT=1; }
        choose_subscription_mode() { SUBSCRIPTION_MODE="deploy"; }
        collect_subscription_link_domain() { SUBSCRIPTION_DOMAIN="subscribe.example.net"; }
        choose_subscription_download_name() { :; }
        choose_monthly_quota() { QUOTA_ENABLED=0; }
        ensure_allowed_tokens() { ALLOWED_TOKENS='{"owner":"owner-token-123"}'; }
        validate_cdn_client_ip_family_runtime() { :; }
        gcore_collect_api_token() { printf 'token\n'; }
        gcore_validate_dns_zones() { GCORE_SUBSCRIPTION_DNS_ZONE="example.net"; printf 'zones\n'; }
        gcore_verify_zone_delegation() { printf 'delegation\n'; }
        gcore_apply_cdn() { printf 'cloud\n'; }
        gcore_clear_api_token() { :; }
        write_subscriptions() { printf 'write\n'; }
        save_state() { :; }
        refresh_runtime() { :; }
        install_quota_timer() { :; }
        install_cdn_traffic_protection_timer() { :; }
        validate_subscription_runtime() { :; }
        show_subscription() { :; }
        success() { :; }
        update_subscription
    )
    assert_contains "adding a custom Gcore subscription hostname synchronizes cloud resources" \
        "${add_custom_subscription_calls}" $'token\nzones\ndelegation\ncloud\nwrite'
)

printf 'easy_all Gcore CDN profile tests passed\n'
