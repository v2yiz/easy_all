#!/usr/bin/env bash
set -Eeuo pipefail

# `[[ ... ]]` as a top-level list item is not fatal under `set -e` (not even in
# bash 5), so a failing assertion would leave the test reporting "ok" while the
# behavior under test is broken.  Evaluate the condition inside this helper, which
# refuses to return success on a mismatch:
#     assert_true "<description>" '<condition>'
assert_true() {
    local description=$1 condition=$2
    if ! eval "[[ ${condition} ]]"; then
        printf 'not ok - %s\n' "${description}" >&2
        exit 1
    fi
}

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $# == 0 ]]; then
    exec env -i PATH="$PATH" bash "$0" xhttp-cloudflare-streamup
fi
profile=$1
unset ORIGIN_HEADER_SECRET FULLCHAIN_FILE QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
source "${ROOT_DIR}/profiles/${profile}.sh"
trap 'status=$?; cleanup; exit "$status"' EXIT
EASY_ALL_STATE_FILE_OVERRIDE="${RUNTIME_TMP}/state.env"
VLESS_CDN_DOMAIN=node.example.com
XHTTP_ORIGIN_DOMAIN=origin.example.com
VLESS_UUID=11111111-2222-4111-8111-111111111111
XHTTP_PATH=/xhttp-test-path
WEBSOCKET_PATH=/ws-test-path
SUBSCRIPTION_MODE=deploy
ALLOWED_TOKENS='{"owner":"test-token-12345"}'
XHTTP_NODE_NAME=test
CDN_PROVIDER=cloudflare
GOOGLE_EGRESS_MODE=ipv4
GOOGLE_EGRESS_RESOLVED=ipv4
CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
XHTTP_ORIGIN_DOMAIN=${CLOUDFLARE_ORIGIN_DOMAIN}
CLOUDFLARE_ACCOUNT_ID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
CLOUDFLARE_WORKER_NAME=easyall
CLOUDFLARE_WORKER_DOMAIN_ID=test-worker-domain-id
CLOUDFLARE_ZONE_ID=test-zone
CLOUDFLARE_ZONE_NAME=example.com
CLOUDFLARE_ORIGIN_CERT_ID=test-cert
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=2035-01-01T00:00:00Z
ORIGIN_HEADER_SECRET=test-origin-secret-12345678
WORKER_SOURCE_SECRET=test-worker-source-secret-12345
WORKER_AGGREGATION_CONFIG='{"nodes":[],"externalSubUrl":"","fallbackCdnNodes":[]}'
SUBSCRIPTION_DOMAIN=sub.example.com
cloudflare_ensure_origin_ca_root() { CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"; }
systemctl() { :; }
ss() { printf 'LISTEN\n'; }
sleep() { :; }
curl() {
    local args=" $* "
    local arg previous="" header_file=""
    for arg in "$@"; do
        if [[ "${previous}" == "-H" && "${arg}" == @* ]]; then
            header_file=${arg#@}
        fi
        previous=${arg}
    done
    [[ "${args}" == *" --cacert ${CLOUDFLARE_ORIGIN_CA_ROOT_FILE} "* ]] &&
    [[ -s "${header_file}" ]] &&
    grep -Fqx "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}" "${header_file}" \
        || exit 1
    printf '%s\n' "${args}" >>"${RUNTIME_TMP}/curl.log"
    case "${args}" in
        *token=invalid*) printf '403' ;;
        *flag=clash*) printf 'network: xhttp' ;;
        *easy_all-health*) printf '%s' "${health_response:-easy_all ok}" ;;
        # The generic subscription endpoint is validated as base64 whose decoded
        # body carries an XHTTP node, so the fixture has to be encoded like the
        # real endpoint instead of returning a plain string.
        *) printf '%s' 'type=xhttp' | openssl base64 -A ;;
    esac
}
validate_protocol_runtime
validate_subscription_runtime
assert_true "运行时验收产生的 curl 调用次数应为 4" '$(wc -l <"${RUNTIME_TMP}/curl.log") -eq 4'
if (health_response=broken; validate_protocol_runtime) >/dev/null 2>&1; then
    printf 'not ok - invalid health response accepted\n' >&2
    exit 1
fi

# Reload from disk after clearing process state, as a later apply/quota command does.
QUOTA_ENABLED=1
QUOTA_START_DATE=2026-01-01
USER_ACCOUNTS='{"owner":{"uuid":"11111111-2222-4111-8111-111111111111","token":"test-token-12345","quota_gb":10}}'
expected_accounts=${USER_ACCOUNTS}
save_state
unset QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
load_state
assert_true "重新载入后应恢复 QUOTA_ENABLED / USER_ACCOUNTS / QUOTA_START_DATE" '"${QUOTA_ENABLED}" == 1 && "${USER_ACCOUNTS}" == "${expected_accounts}" && "${QUOTA_START_DATE}" == 2026-01-01'
QUOTA_ENABLED=0
save_state
load_state
assert_true "关闭配额后不应残留 USER_ACCOUNTS / QUOTA_START_DATE" '-z "${USER_ACCOUNTS}" && -z "${QUOTA_START_DATE}"'
printf 'ok - %s runtime authentication and state\n' "${profile}"
