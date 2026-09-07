#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $# == 0 ]]; then
    for profile in xhttp-gcore xhttp-cloudflare-streamup; do
        env -i PATH="$PATH" bash "$0" "${profile}" || exit "$?"
    done
    exit 0
fi
profile=$1
unset ORIGIN_HEADER_SECRET FULLCHAIN_FILE QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
source "${ROOT_DIR}/profiles/${profile}.sh"
trap 'status=$?; cleanup; exit "$status"' EXIT
EASY_ALL_STATE_FILE_OVERRIDE="${RUNTIME_TMP}/state.env"
VLESS_CDN_DOMAIN=node.example.com
XHTTP_ORIGIN_DOMAIN=origin.example.com
GCORE_ORIGIN_DOMAIN=${XHTTP_ORIGIN_DOMAIN}
VLESS_UUID=11111111-2222-4111-8111-111111111111
XHTTP_PATH=/xhttp-test-path
WEBSOCKET_PATH=/ws-test-path
SUBSCRIPTION_MODE=deploy
ALLOWED_TOKENS='{"owner":"test-token-12345"}'
XHTTP_NODE_NAME=test
if [[ "${profile}" == xhttp-cloudflare-streamup ]]; then
    CDN_PROVIDER=cloudflare
    CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${CLOUDFLARE_ORIGIN_DOMAIN}
    CLOUDFLARE_ZONE_ID=test-zone
    CLOUDFLARE_ZONE_NAME=example.com
    CLOUDFLARE_ORIGIN_CERT_ID=test-cert
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=2035-01-01T00:00:00Z
    ORIGIN_HEADER_SECRET=test-origin-secret-12345678
    cloudflare_ensure_origin_ca_root() { CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"; }
fi
systemctl() { :; }
ss() { printf 'LISTEN\n'; }
sleep() { :; }
curl() {
    local args=" $* "
    if [[ "${CDN_PROVIDER}" == gcore ]]; then
        [[ "${args}" == *" --cert ${GCORE_CLIENT_CERT_FILE} "* ]] &&
        [[ "${args}" == *" --key ${GCORE_CLIENT_CERT_KEY} "* ]] &&
        [[ "${args}" != *X-Easy-All-Origin-Key* ]]
    else
        [[ "${args}" == *" --cacert ${CLOUDFLARE_ORIGIN_CA_ROOT_FILE} "* ]] &&
        [[ "${args}" == *" -H X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET} "* ]]
    fi || exit 1
    printf '%s\n' "${args}" >>"${RUNTIME_TMP}/curl.log"
    case "${args}" in
        *token=invalid*) printf '403' ;;
        *flag=clash*)
            if [[ "${CDN_PROVIDER}" == gcore ]]; then printf 'network: ws'; else printf 'network: xhttp'; fi ;;
        *easy_all-health*) printf '%s' "${health_response:-easy_all ok}" ;;
        *) printf 'subscription' ;;
    esac
}
validate_protocol_runtime
validate_subscription_runtime
[[ $(wc -l <"${RUNTIME_TMP}/curl.log") -eq 4 ]]
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
[[ "${QUOTA_ENABLED}" == 1 && "${USER_ACCOUNTS}" == "${expected_accounts}" && "${QUOTA_START_DATE}" == 2026-01-01 ]]
QUOTA_ENABLED=0
save_state
load_state
[[ -z "${USER_ACCOUNTS}" && -z "${QUOTA_START_DATE}" ]]
printf 'ok - %s runtime authentication and state\n' "${profile}"
