#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/xhttp-gcore.sh"
CONTENT="$(<"${PROFILE}")"

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
assert_contains() { [[ "$2" == *"$3"* ]] || fail "$1: missing $3"; }
assert_not_contains() { [[ "$2" != *"$3"* ]] || fail "$1: unexpected $3"; }

bash -n "${PROFILE}" "${ROOT_DIR}/easy_all" "${ROOT_DIR}"/lib/*.sh

assert_contains "Gcore enables its documented WebSocket option" "${CONTENT}" \
    'websockets:{enabled:true,value:true}'
assert_contains "Gcore only needs WebSocket HTTP methods" "${CONTENT}" \
    'allowedHttpMethods:{enabled:true,value:["GET","HEAD"]}'
assert_contains "Xray server uses WebSocket" "${CONTENT}" \
    'streamSettings:{network:"ws"'
assert_contains "Nginx forwards WebSocket upgrade" "${CONTENT}" \
    'proxy_set_header Upgrade \$http_upgrade;'
assert_contains "Nginx forwards WebSocket connection upgrade" "${CONTENT}" \
    'proxy_set_header Connection "upgrade";'
assert_contains "VLESS URI uses WebSocket" "${CONTENT}" 'security=tls&type=ws'
assert_contains "Mihomo uses WebSocket" "${CONTENT}" 'network: ws'
assert_contains "Mihomo emits ws options" "${CONTENT}" 'ws-opts:'
assert_contains "Gcore probe uses WebSocket" "${CONTENT}" 'gcore_probe_websocket'
assert_not_contains "Gcore transport no longer uses packet-up" "${CONTENT}" 'mode:"packet-up"'
assert_contains "legacy installs require an atomic cloud migration" "${CONTENT}" \
    '请执行 easy_all apply-cloud，一次性启用 Gcore WebSocket 并迁移本机配置'
assert_contains "migration switches the local runtime before WebSocket validation" "${CONTENT}" \
    'gcore_apply_cdn 1'
assert_contains "Gcore uses account-specific CNAME" "${CONTENT}" \
    "gcore_api_request GET '/cdn/clients/me'"
assert_contains "Gcore verifies delegation" "${CONTENT}" \
    'GET "/dns/v2/analyze/${zone}/delegation-status"'
assert_contains "origin validation supplies the CA" "${CONTENT}" \
    'proxy_ssl_ca:$origin_ca'
assert_contains "origin validation supplies the client certificate" "${CONTENT}" \
    'proxy_ssl_data:$client_cert'
assert_contains "Nginx requires the Gcore client certificate" "${CONTENT}" \
    'ssl_verify_client on;'
assert_not_contains "Gcore token is not persisted" "${CONTENT}" \
    "printf 'GCORE_API_TOKEN="

(
    # shellcheck source=/dev/null
    source "${PROFILE}"
    VLESS_UUID=11111111-1111-4111-8111-111111111111
    VLESS_CDN_DOMAIN=node.example.com
    XHTTP_NODE_NAME=GCORE_WS
    XHTTP_PATH=/ws-0123456789abcdef
    CDN_CLIENT_IP_FAMILY=ipv4

    link=$(build_vless_xhttp_link 203.0.113.10 TEST)
    [[ "${link}" == *'type=ws'* \
        && "${link}" == *'alpn=http%2F1.1'* \
        && "${link}" == *'host=node.example.com'* \
        && "${link}" == *'path=%2Fws-0123456789abcdef'* \
        && "${link}" != *'type=xhttp'* ]] \
        || fail "VLESS WebSocket URI is invalid"

    mihomo=$(build_mihomo_node_for_endpoint 203.0.113.10 TEST)
    [[ "${mihomo}" == *'network: ws'* \
        && "${mihomo}" == *'ws-opts:'* \
        && "${mihomo}" == *'path: "/ws-0123456789abcdef"'* \
        && "${mihomo}" == *'Host: "node.example.com"'* \
        && "${mihomo}" != *'xhttp-opts:'* ]] \
        || fail "Mihomo WebSocket node is invalid"

    GCORE_ORIGIN_DOMAIN=origin.example.com
    SUBSCRIPTION_DOMAIN=node.example.com
    SUBSCRIPTION_MODE=nodes-only
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
        and .options.websockets == {enabled:true,value:true}
        and .options.edge_cache_settings.value == "0s"
    ' <<<"${payload}" >/dev/null || fail "Gcore WebSocket resource payload is invalid"

    GCORE_API_TOKEN=1234567890abcdef
    error_file=$(mktemp)
    curl() { printf '%s\n%s' '{"errors":{"cname":["invalid domain"]}}' '400'; }
    if gcore_api_request POST '/cdn/resources' '{}' >/dev/null 2>"${error_file}"; then
        fail "Gcore API HTTP 400 must fail"
    fi
    error=$(<"${error_file}")
    rm -f -- "${error_file}"
    assert_contains "API error preserves body" "${error}" \
        '{"errors":{"cname":["invalid domain"]}}'
    assert_contains "API error identifies endpoint" "${error}" \
        'Gcore API 请求失败（HTTP 400）：POST /cdn/resources'
)

printf 'ok - Gcore WebSocket profile tests passed\n'
