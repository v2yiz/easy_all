#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/xhttp-cloudflare.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
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
    [[ "${value}" == *"${expected}"* ]] \
        || fail "${label}: missing [${expected}]"
}

assert_not_contains() {
    local label=$1 value=$2 unexpected=$3
    [[ "${value}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected [${unexpected}]"
}

[[ -f "${PROFILE}" ]] || fail "Cloudflare XHTTP profile is missing"
bash -n "${PROFILE}"
if standalone_output=$(bash "${PROFILE}" 2>&1); then
    fail "Cloudflare profile must not be a standalone entry point"
fi
assert_contains "standalone profile directs users to unified entry" \
    "${standalone_output}" "easy_all install"

profile_content=$(<"${PROFILE}")
runtime_content=$(<"${XHTTP_RUNTIME}")
assert_contains "Cloudflare profile loads shared XHTTP runtime" \
    "${profile_content}" 'source "${XHTTP_PROFILE_ROOT}/xhttp-runtime.sh"'
assert_contains "Cloudflare profile loads Globalping discovery" \
    "${profile_content}" 'source "${XHTTP_PROFILE_ROOT}/globalping-cdn.sh"'
assert_contains "Cloudflare profile persists its provider" \
    "${profile_content}" 'CDN_PROVIDER)'
assert_contains "Cloudflare profile persists optimized endpoint mode" \
    "${profile_content}" 'CLOUDFLARE_CDN_ENDPOINT_MODE'
assert_contains "Cloudflare profile sets the optimized endpoint mode" \
    "${profile_content}" 'CLOUDFLARE_CDN_ENDPOINT_MODE=optimized'
assert_contains "Cloudflare profile uses bearer API authentication" \
    "${profile_content}" 'Authorization: Bearer %s'
assert_not_contains "Cloudflare token is not exposed in curl argv" \
    "${profile_content}" '-H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}"'
assert_contains "Cloudflare profile manages proxied DNS" \
    "${profile_content}" 'proxied:true'
assert_contains "Cloudflare profile requests an Origin CA certificate" \
    "${profile_content}" '/certificates'
assert_contains "Cloudflare Origin CA certificate is long-lived" \
    "${profile_content}" 'requested_validity'
assert_contains "Cloudflare profile selects strict origin TLS" \
    "${profile_content}" 'ssl:"strict"'
assert_contains "Cloudflare profile enables HTTP/2 to origin" \
    "${profile_content}" 'origin_max_http_version'
assert_contains "Cloudflare profile enables gRPC" \
    "${profile_content}" 'grpc'
assert_contains "Cloudflare profile manages stable reference rules" \
    "${profile_content}" '/rulesets'
assert_contains "Cloudflare rules use stable refs" \
    "${profile_content}" '.ref==$ref'
assert_contains "Cloudflare profile has its own stream-up timeout" \
    "${profile_content}" 'CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS="20-40"'
assert_contains "Xray stays in stream-up mode" \
    "${profile_content}${runtime_content}" 'mode:"stream-up"'
assert_not_contains "Cloudflare API token is never persisted in state" \
    "${profile_content}" 'CLOUDFLARE_API_TOKEN=%q'

(
    # The profile must be sourceable without calling external services.
    source "${PROFILE}"

    CLOUDFLARE_ZONE_ID='zone-test'
    VLESS_CDN_DOMAIN='node.example.com'
    CLOUDFLARE_ORIGIN_DOMAIN='node.example.com'
    XHTTP_PATH='/xhttp-test-path'
    ORIGIN_HEADER_SECRET='0123456789abcdef'

    # Mock the provider API: a missing DNS record must produce an orange-cloud
    # A record, never an unproxied origin record.
    dns_calls="${TMP_DIR}/dns-calls"
    : >"${dns_calls}"
    cloudflare_api_request() {
        printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"${dns_calls}"
        case "$2" in
        *'/dns_records?type=A'* | *'/dns_records?type=AAAA'* | *'/dns_records?type=CNAME'*) printf '[]\n' ;;
        */dns_records) printf '{"id":"new-a"}\n' ;;
        *) fail "unexpected Cloudflare DNS API path: $2" ;;
        esac
    }
    cloudflare_ensure_proxied_a "${CLOUDFLARE_ZONE_ID}" \
        "${CLOUDFLARE_ORIGIN_DOMAIN}" '198.51.100.10'
    dns_post=$(awk -F '\t' '$1 == "POST" {print $3}' "${dns_calls}")
    jq -e '.type == "A" and .name == "node.example.com" and .content == "198.51.100.10" and .ttl == 1 and .proxied == true' \
        <<<"${dns_post}" >/dev/null \
        || fail "Cloudflare origin DNS write must be proxied and automatic TTL"

    # A record previously marked by easy_all may be repaired in place, while
    # an unrelated user's conflicting record must never be overwritten.
    : >"${dns_calls}"
    cloudflare_api_request() {
        printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"${dns_calls}"
        case "$2" in
        *'/dns_records?type=A'*) printf '[{"id":"managed-a","content":"198.51.100.9","proxied":false,"comment":"easy_all xhttp origin"}]\n' ;;
        *'/dns_records?type=AAAA'* | *'/dns_records?type=CNAME'*) printf '[]\n' ;;
        */dns_records/managed-a) printf '{"id":"managed-a"}\n' ;;
        *) fail "unexpected managed Cloudflare DNS API path: $2" ;;
        esac
    }
    cloudflare_ensure_proxied_a "${CLOUDFLARE_ZONE_ID}" \
        "${CLOUDFLARE_ORIGIN_DOMAIN}" '198.51.100.10'
    managed_patch=$(awk -F '\t' '$1 == "PATCH" {print $3}' "${dns_calls}")
    jq -e '.content == "198.51.100.10" and .proxied == true and .comment == "easy_all xhttp origin"' \
        <<<"${managed_patch}" >/dev/null \
        || fail "Cloudflare must repair only its own marked proxied A record"

    cloudflare_api_request() {
        case "$2" in
        *'/dns_records?type=A'*) printf '[{"id":"customer-a","content":"198.51.100.9","proxied":true}]\n' ;;
        *'/dns_records?type=AAAA'* | *'/dns_records?type=CNAME'*) printf '[]\n' ;;
        *) fail "Cloudflare attempted to overwrite an unmanaged DNS record: $2" ;;
        esac
    }
    if (cloudflare_ensure_proxied_a "${CLOUDFLARE_ZONE_ID}" \
        "${CLOUDFLARE_ORIGIN_DOMAIN}" '198.51.100.10' >/dev/null 2>&1); then
        fail "Cloudflare must reject a conflicting unmanaged A record"
    fi

    # A ruleset can include user rules.  Updating the same easy_all ref must
    # PATCH only that rule ID; a full ruleset replacement would erase user rules.
    rule_calls="${TMP_DIR}/rule-calls"
    : >"${rule_calls}"
    header_ref=$(cloudflare_ref "header:${VLESS_CDN_DOMAIN}:${XHTTP_PATH}")
    strict_ref=$(cloudflare_ref "strict:${VLESS_CDN_DOMAIN}")
    cloudflare_api_request() {
        printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"${rule_calls}"
        case "$2" in
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets")
            printf '%s\n' '[{"id":"header-rules","name":"existing transform rules","kind":"zone","phase":"http_request_late_transform"},{"id":"strict-rules","name":"existing config rules","kind":"zone","phase":"http_config_settings"}]'
            ;;
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/header-rules")
            jq -cn --arg ref "${header_ref}" '{rules:[{id:"user-rule",ref:"customer_ref"},{id:"easy-header",ref:$ref}]}'
            ;;
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/strict-rules")
            jq -cn --arg ref "${strict_ref}" '{rules:[{id:"user-rule",ref:"customer_ref"},{id:"easy-strict",ref:$ref}]}'
            ;;
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/header-rules/rules/easy-header" | \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/strict-rules/rules/easy-strict")
            printf '{"id":"updated"}\n'
            ;;
        *) fail "unexpected Cloudflare rules API path: $2" ;;
        esac
    }
    cloudflare_configure_rules
    assert_equal "Cloudflare rules update only the matching stable refs" "2" \
        "$(awk -F '\t' '$1 == "PATCH" {count++} END {print count + 0}' "${rule_calls}")"
    if awk -F '\t' '$1 == "PUT" && $2 ~ /\/rulesets\/(header-rules|strict-rules)$/ {found=1} END {exit !found}' "${rule_calls}"; then
        fail "Cloudflare must not replace an entire ruleset containing user rules"
    fi
    assert_contains "header rule preserves the origin secret" "$(<"${rule_calls}")" \
        'X-Easy-All-Origin-Key'
    assert_contains "strict rule enforces strict TLS" "$(<"${rule_calls}")" '"ssl":"strict"'
)

printf 'easy_all Cloudflare CDN profile tests passed\n'
