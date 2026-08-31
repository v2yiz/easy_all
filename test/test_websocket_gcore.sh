#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/websocket-gcore.sh"
RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
CONTENT="$(<"${PROFILE}")"$'\n'"$(<"${RUNTIME}")"

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing ${expected}"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected ${unexpected}"
}

bash -n "${PROFILE}" "${ROOT_DIR}/easy_all" "${ROOT_DIR}"/lib/*.sh

assert_contains "Gcore uses official WebSocket option" "${CONTENT}" \
    'websockets:{enabled:true,value:true}'
assert_not_contains "Gcore domain mode does not load Globalping" "${PROFILE}" \
    'globalping-cdn.sh'
assert_contains "Gcore persists domain endpoint mode" "${CONTENT}" \
    'GCORE_CDN_ENDPOINT_MODE="domain"'
assert_contains "Gcore migrates legacy optimized state to domain mode" "${CONTENT}" \
    'optimized) GCORE_CDN_ENDPOINT_MODE="domain"'
for obsolete_globalping_call in collect_globalping_token refresh_globalping_cache \
    persist_globalping_token install_globalping_refresh_timer show_globalping_status; do
    assert_not_contains "Gcore does not invoke ${obsolete_globalping_call}" \
        "${PROFILE}" "${obsolete_globalping_call}"
done
assert_contains "Gcore removes legacy Globalping runtime files" "${CONTENT}" \
    'remove_legacy_gcore_globalping_runtime'
assert_not_contains "Gcore omits unavailable gRPC passthrough option" "${PROFILE}" \
    'grpc_passthrough'
assert_contains "Gcore preserves query strings for early data" "${CONTENT}" \
    'ignoreQueryString:{enabled:true,value:false}'
assert_contains "Gcore cache payload does not combine value and default" "${CONTENT}" \
    'edge_cache_settings:{enabled:true,value:"0s"}'
assert_not_contains "Gcore cache payload omits invalid default combination" "${PROFILE}" \
    'value:"0s",default:"0s"'
assert_not_contains "Gcore does not force a WebSocket read timeout shorter than heartbeat" \
    "${PROFILE}" 'proxy_read_timeout:{enabled:true'
assert_contains "Gcore uses account-specific CNAME" "${CONTENT}" \
    "gcore_api_request GET '/cdn/clients/me'"
assert_contains "Gcore verifies delegation before provisioning" "${CONTENT}" \
    'GET "/dns/v2/analyze/${zone}/delegation-status"'
assert_contains "Gcore reports the delegation result before provisioning" "${CONTENT}" \
    'Gcore NS 委派已确认：${zone}'
assert_contains "Gcore delegation failure includes a local DNS self-check" "${CONTENT}" \
    'dig NS ${zone} +short'
assert_contains "Gcore CNAME propagation uses Cloudflare DNS" "${CONTENT}" \
    'dig +short CNAME "${domain}" @1.1.1.1'
assert_not_contains "Gcore CNAME propagation does not mix public resolvers" \
    "${PROFILE}" '@8.8.8.8'
assert_not_contains "Gcore never derives a custom-domain gcdn target" "${PROFILE}" \
    '${VLESS_CDN_DOMAIN}.gcdn.co'
assert_contains "Gcore enables DNS-01" "${CONTENT}" \
    'use_dns01_le_challenge:{enabled:true,value:true}'
assert_contains "origin validation requires both certificate IDs" "${CONTENT}" \
    'proxy_ssl_ca:$origin_ca'
assert_contains "origin validation supplies client certificate" "${CONTENT}" \
    'proxy_ssl_data:$client_cert'
assert_contains "Nginx requires the Gcore client certificate" "${CONTENT}" \
    'ssl_verify_client on;'
assert_contains "WebSocket heartbeat is balanced" "${CONTENT}" \
    'readonly GCORE_WS_HEARTBEAT_PERIOD="55"'
assert_contains "WebSocket early data uses the agreed threshold" "${CONTENT}" \
    'readonly GCORE_WS_EARLY_DATA="2560"'
assert_contains "Mihomo uses HTTP 1.1 ALPN" "${CONTENT}" \
    '      - http/1.1'
assert_contains "Mihomo enables early data header" "${CONTENT}" \
    'early-data-header-name: Sec-WebSocket-Protocol'
assert_contains "Gcore guard uses conservative accounting" "${CONTENT}" \
    'readonly GCORE_CDN_TRAFFIC_PROTECTION_GB="990"'
assert_contains "Gcore state uses a transport-neutral protocol name" "${CONTENT}" \
    'printf '\''PROTOCOL=%q\n'\'' "websocket"'
assert_contains "Gcore state persists WS path" "${CONTENT}" \
    'printf '\''WS_PATH=%q\n'\'''
assert_not_contains "Gcore state does not persist the API token" "${CONTENT}" \
    'printf '\''GCORE_API_TOKEN='
assert_contains "Gcore systemd service is transport-accurate" "${CONTENT}" \
    'XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray VLESS WebSocket managed by easy_all"'
assert_contains "Gcore API failures include the method and path" "${CONTENT}" \
    'Gcore API 请求失败（HTTP ${status}）：${method} ${path}'
assert_not_contains "Gcore never tries to replace immutable trusted CA content" "${PROFILE}" \
    'gcore_api_request PUT "/cdn/sslCertificates/'
assert_contains "Gcore trusted CA names include the issuer fingerprint" "${CONTENT}" \
    'fingerprint=${CURRENT_GCORE_ORIGIN_ISSUER_SHA256:-${GCORE_ORIGIN_ISSUER_SHA256:-}}'
assert_not_contains "Gcore DNS-01 flow skips the optional HTTP pre-validation request" \
    "${PROFILE}" '/ssl/le/pre-validate'
assert_contains "Gcore enables HTTP redirect only after attaching an edge certificate" \
    "${CONTENT}" 'gcore_attach_edge_certificate'
assert_contains "Gcore checks the Let's Encrypt issuance status" "${CONTENT}" \
    '"/cdn/sslData/${GCORE_SSL_CERT_ID}/status"'
assert_contains "Gcore fails fast when certificate issuance fails" "${CONTENT}" \
    'FAILED | CANCELLED)'
assert_contains "Gcore reports health check progress" "${CONTENT}" \
    'Resource=${status:-unknown}，Let'\''s Encrypt=${certificate_status}，HTTPS=${http_code:-000}'
assert_contains "purge preflights the attached edge certificate" "${CONTENT}" \
    'and .sslData == $edge'
assert_contains "purge preflights the attached origin CA" "${CONTENT}" \
    'and .proxy_ssl_ca == $ca'
assert_contains "purge preflights the attached client certificate" "${CONTENT}" \
    'and .proxy_ssl_data == $client'

(
    # shellcheck source=/dev/null
    source "${PROFILE}"
    [[ "${GCORE_WS_HEARTBEAT_PERIOD}" == "55" ]] || fail "heartbeat constant drifted"
    [[ "${GCORE_WS_EARLY_DATA}" == "2560" ]] || fail "early data constant drifted"

    GCORE_API_TOKEN=1234567890abcdef
    api_error_file=$(mktemp)
    curl() {
        printf '%s\n%s' '{"errors":{"cname":["invalid domain"]}}' '400'
    }
    if gcore_api_request POST '/cdn/resources' '{}' >/dev/null 2>"${api_error_file}"; then
        fail "Gcore API HTTP 400 must fail"
    fi
    api_error=$(<"${api_error_file}")
    rm -f -- "${api_error_file}"
    assert_contains "Gcore API error preserves the response body" "${api_error}" \
        '{"errors":{"cname":["invalid domain"]}}'
    assert_contains "Gcore API error identifies the failed endpoint" "${api_error}" \
        'Gcore API 请求失败（HTTP 400）：POST /cdn/resources'
    unset -f curl

    GCORE_ORIGIN_DOMAIN=origin.example.com
    CURRENT_GCORE_ORIGIN_ISSUER_SHA256=$(printf 'A%.0s' {1..64})
    first_ca_name=$(gcore_origin_ca_name)
    CURRENT_GCORE_ORIGIN_ISSUER_SHA256=$(printf 'B%.0s' {1..64})
    second_ca_name=$(gcore_origin_ca_name)
    [[ "${first_ca_name}" != "${second_ca_name}" \
        && "${first_ca_name}" == easy-all-origin-ca-*-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        && "${second_ca_name}" == easy-all-origin-ca-*-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]] \
        || fail "Gcore trusted CA names must change with the issuer fingerprint"

    GCORE_CDN_RESOURCE_ID=42
    GCORE_SSL_CERT_ID=43
    attach_call=0
    gcore_api_request() {
        [[ "$1 $2" == "PATCH /cdn/resources/42" ]] \
            || fail "unexpected Gcore edge certificate request: $1 $2"
        ((attach_call += 1))
        if ((attach_call == 1)); then
            jq -e '.sslEnabled == true and .sslData == 43 and (has("options") | not)' \
                <<<"$3" >/dev/null \
                || fail "Gcore must attach the edge certificate before enabling redirect"
        else
            jq -e '.options.redirect_http_to_https == {enabled:true,value:true}
                and (has("sslData") | not)' <<<"$3" >/dev/null \
                || fail "Gcore must enable redirect in a separate request"
        fi
    }
    gcore_attach_edge_certificate
    [[ "${attach_call}" == "2" ]] \
        || fail "Gcore edge certificate attachment must use two ordered requests"

    gcore_api_request() {
        case "$1 $2" in
        "GET /cdn/resources/42") printf '%s\n' '{"status":"processed"}' ;;
        "GET /cdn/sslData/43/status")
            printf '%s\n' '{"active":false,"latest_status":{"status":"DONE"}}'
            ;;
        *) return 1 ;;
        esac
    }
    curl() {
        local output_file=""
        while (($#)); do
            if [[ "$1" == "-o" ]]; then
                output_file=$2
                shift 2
            else
                shift
            fi
        done
        printf 'easy_all ok\n' >"${output_file}"
        printf '200'
    }
    sleep() { fail "Gcore must not wait after end-to-end HTTPS succeeds"; }
    gcore_wait_for_domain_health node.example.com CDN >/dev/null
    unset -f curl sleep

    CDN_PROVIDER=gcore
    PROTOCOL=websocket
    CDN_TRAFFIC_PROTECTION_GB=0
    configure_cdn_traffic_protection
    [[ "${CDN_TRAFFIC_PROTECTION_GB}" == "990" ]] \
        || fail "Gcore traffic guard must default to 990 GB"
    cdn_traffic_protection_enabled || fail "Gcore traffic guard must be enabled"

    VLESS_UUID=11111111-1111-4111-8111-111111111111
    VLESS_CDN_DOMAIN=node.example.com
    XHTTP_NODE_NAME=GCORE_WS
    XHTTP_PATH=/ws-0123456789abcdef
    [[ "$(xhttp_client_endpoints)" == "node.example.com" ]] \
        || fail "Gcore subscription must use only the CDN domain"
    ! xhttp_using_optimized_candidates \
        || fail "Gcore domain mode must not use optimized candidates"
    link=$(build_vless_xhttp_link 203.0.113.10 TEST)
    [[ "${link}" == *'type=ws'* \
        && "${link}" == *'alpn=http%2F1.1'* \
        && "${link}" == *'%3Fed%3D2560'* ]] \
        || fail "VLESS WebSocket URI does not contain the agreed settings"

    CDN_CLIENT_IP_FAMILY=ipv4
    mihomo=$(build_mihomo_node_for_endpoint 203.0.113.10 TEST)
    [[ "${mihomo}" == *'network: ws'* \
        && "${mihomo}" == *'max-early-data: 2560'* \
        && "${mihomo}" == *'early-data-header-name: Sec-WebSocket-Protocol'* \
        && "${mihomo}" == *'      - http/1.1'* ]] \
        || fail "Mihomo WebSocket output does not contain the agreed settings"

    GCORE_ORIGIN_DOMAIN=origin.example.com
    SUBSCRIPTION_DOMAIN=node.example.com
    SUBSCRIPTION_MODE=nodes-only
    ORIGIN_HEADER_SECRET=abcdefghijklmnop
    GCORE_ORIGIN_GROUP_ID=12
    GCORE_ORIGIN_CA_ID=13
    GCORE_ORIGIN_CLIENT_CERT_ID=14
    payload=$(gcore_resource_payload)
    jq -e '
        .name == "easy_all websocket node.example.com"
        and .originProtocol == "HTTPS"
        and .proxy_ssl_enabled == true
        and .proxy_ssl_ca == 13
        and .proxy_ssl_data == 14
        and .options.allowedHttpMethods.value == ["GET","HEAD"]
        and .options.websockets.value == true
        and (.options | has("grpc_passthrough") | not)
        and (.options | has("redirect_http_to_https") | not)
        and .options.edge_cache_settings.value == "0s"
        and (.options.edge_cache_settings | has("default") | not)
    ' <<<"${payload}" >/dev/null || fail "Gcore resource payload is invalid"

    gcore_api_request() {
        [[ "$1 $2" == "GET /cdn/clients/me" ]] || return 1
        printf '%s\n' '{"cname":"cl-12345.gcdn.co"}'
    }
    gcore_detect_cdn_target
    [[ "${GCORE_CDN_TARGET}" == "cl-12345.gcdn.co" ]] \
        || fail "account-specific Gcore CNAME was not selected"

    GCORE_CDN_RESOURCE_ID=""
    gcore_api_request() {
        case "$1 $2" in
        "GET /cdn/resources?limit=1000")
            printf '%s\n' '[{"id":99,"cname":"node.example.com","name":"foreign resource"}]'
            ;;
        *) return 1 ;;
        esac
    }
    if (gcore_ensure_resource) >/dev/null 2>&1; then
        fail "Gcore resource discovery must not take over a foreign resource"
    fi
)

printf 'ok - Gcore WebSocket profile tests passed\n'
