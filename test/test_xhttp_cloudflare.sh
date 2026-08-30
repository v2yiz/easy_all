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
assert_contains "Cloudflare prompt names the client CDN hostname" \
    "$(<"${PROFILE}")" '客户端连接的 CDN 节点域名'
assert_contains "Cloudflare explains the single-host architecture" \
    "$(<"${PROFILE}")" 'Cloudflare 模式采用单域名架构'
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
    "${profile_content}" 'Network → gRPC'
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
    GLOBALPING_CACHE_FILE_OVERRIDE="${TMP_DIR}/cloudflare-cdn-ips.json"
    source "${PROFILE}"

    CLOUDFLARE_ZONE_ID='zone-test'
    VLESS_CDN_DOMAIN='node.example.com'
    CLOUDFLARE_ORIGIN_DOMAIN='node.example.com'
    XHTTP_PATH='/xhttp-test-path'
    ORIGIN_HEADER_SECRET='0123456789abcdef'

    ranges_file="${TMP_DIR}/cloudflare-ranges.txt"
    printf '%s\n' '104.16.0.0/23' '173.245.48.0/24' >"${ranges_file}"
    candidate_pool=$(cloudflare_generate_candidate_pool \
        "${ranges_file}" 3 2000000000)
    assert_equal "Cloudflare samples one address from each available /24" \
        "3" "$(wc -l <<<"${candidate_pool}" | tr -d ' ')"
    assert_equal "Cloudflare /24 sampling does not emit duplicate addresses" \
        "3" "$(cut -f1 <<<"${candidate_pool}" | sort -u | wc -l | tr -d ' ')"
    while IFS=$'\t' read -r candidate_ip source_cidr; do
        cloudflare_ipv4_in_cidr "${candidate_ip}" "${source_cidr}" \
            || fail "Cloudflare candidate ${candidate_ip} is outside ${source_cidr}"
        [[ "${candidate_ip##*.}" != "0" && "${candidate_ip##*.}" != "255" ]] \
            || fail "Cloudflare candidate uses a network or broadcast address"
    done <<<"${candidate_pool}"

    measurement_request=$(cloudflare_globalping_measurement_request \
        '104.16.0.10')
    jq -e '
      .type == "ping"
      and .target == "104.16.0.10"
      and .timeout == 15
      and .measurementOptions == {
        packets:5, protocol:"TCP", port:443
      }
      and .locations == [
        {country:"CN",asn:4134,tags:["eyeball-network"],limit:1},
        {country:"CN",asn:4837,tags:["eyeball-network"],limit:1},
        {country:"CN",asn:9808,tags:["eyeball-network"],limit:1}
      ]
    ' <<<"${measurement_request}" >/dev/null \
        || fail "Cloudflare Globalping request must target three mainland eyeball carriers"

    measurements_file="${TMP_DIR}/cloudflare-measurements.ndjson"
    cat >"${measurements_file}" <<'EOF'
{"ip":"104.16.0.10","source_cidr":"104.16.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":4134,"city":"Shanghai","network":"Telecom","tags":["eyeball-network"]},"result":{"status":"finished","resolvedAddress":"104.16.0.10","stats":{"loss":0,"total":5,"rcv":5,"drop":0,"avg":20}}},{"probe":{"country":"CN","asn":4837,"city":"Beijing","network":"Unicom","tags":["eyeball-network"]},"result":{"status":"finished","resolvedAddress":"104.16.0.10","stats":{"loss":0,"total":5,"rcv":5,"drop":0,"avg":40}}}]}}
{"ip":"172.64.0.20","source_cidr":"172.64.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":9808,"city":"Guangzhou","network":"Mobile","tags":["eyeball-network"]},"result":{"status":"finished","resolvedAddress":"172.64.0.20","stats":{"loss":0,"total":5,"rcv":5,"drop":0,"avg":30}}},{"probe":{"country":"CN","asn":4134,"city":"Hangzhou","network":"Telecom","tags":["datacenter-network"]},"result":{"status":"finished","resolvedAddress":"172.64.0.20","stats":{"loss":0,"total":5,"rcv":5,"drop":0,"avg":1}}}]}}
EOF
    observations_file="${TMP_DIR}/cloudflare-observations.ndjson"
    cloudflare_zero_loss_observations \
        "${measurements_file}" >"${observations_file}"
    assert_equal "Cloudflare accepts only successful eyeball carrier observations" \
        "3" "$(wc -l <"${observations_file}" | tr -d ' ')"
    ranked=$(cloudflare_select_carrier_candidates \
        "${observations_file}" 3 9)
    assert_equal "Cloudflare aggregates the same IP across carriers" \
        "2" "$(jq -r '.[] | select(.ip == "104.16.0.10") | .carrier_count' \
            <<<"${ranked}")"

    generated_cache="${TMP_DIR}/cloudflare-generated-cache.json"
    (
        cloudflare_fetch_origin_ipv4_ranges() {
            printf '%s\n' '104.16.0.0/24'
        }
        cloudflare_collect_globalping_measurements() {
            local pool_file=$1 destination=$2 ip source_cidr
            IFS=$'\t' read -r ip source_cidr <"${pool_file}"
            jq -cn --arg ip "${ip}" --arg source_cidr "${source_cidr}" '{
              ip:$ip,
              source_cidr:$source_cidr,
              measurement:{results:[
                {
                  probe:{country:"CN",asn:4134,city:"Shanghai",network:"Telecom",tags:["eyeball-network"]},
                  result:{status:"finished",resolvedAddress:$ip,stats:{loss:0,total:5,rcv:5,drop:0,avg:20}}
                },
                {
                  probe:{country:"CN",asn:4837,city:"Beijing",network:"Unicom",tags:["eyeball-network"]},
                  result:{status:"finished",resolvedAddress:$ip,stats:{loss:0,total:5,rcv:5,drop:0,avg:30}}
                },
                {
                  probe:{country:"CN",asn:9808,city:"Guangzhou",network:"Mobile",tags:["eyeball-network"]},
                  result:{status:"finished",resolvedAddress:$ip,stats:{loss:0,total:5,rcv:5,drop:0,avg:40}}
                }
              ]}
            }' >"${destination}"
        }
        cloudflare_validate_pool_candidate() { return 0; }
        GLOBALPING_NOW_EPOCH=2000000000
        cloudflare_build_official_pool_cache "${generated_cache}"
    )
    jq -e '
      .version == 3
      and .provider == "cloudflare"
      and .candidate_source == "cloudflare-official-ipv4-cidrs"
      and .probe_type == "eyeball-network"
      and .carrier_asns == [4134,4837,9808]
      and .pool_sample_size == 1
      and .measurement_count == 1
      and (.candidates | length) == 1
      and .candidates[0].carrier_count == 3
    ' "${generated_cache}" >/dev/null \
        || fail "Cloudflare official-pool cache schema is invalid"

    validation_calls="${TMP_DIR}/cloudflare-validation-calls"
    curl() {
        printf '%s\n' "$*" >>"${validation_calls}"
        printf 'easy_all ok\n2'
    }
    cloudflare_validate_pool_candidate '104.16.0.10' \
        || fail "Cloudflare candidate health validation should pass"
    assert_contains "Cloudflare health validation requires HTTP/2" \
        "$(<"${validation_calls}")" '--http2'
    assert_contains "Cloudflare health validation pins the candidate with domain SNI" \
        "$(<"${validation_calls}")" \
        '--resolve node.example.com:443:104.16.0.10'
    unset -f curl

    GLOBALPING_NOW_EPOCH=2000000000
    CDN_PROVIDER="cloudflare"
    CLOUDFLARE_CDN_ENDPOINT_MODE="optimized"
    XHTTP_NODE_NAME="VLESS_XHTTP_H2"
    cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{"version":3,"provider":"cloudflare","domain":"node.example.com","candidate_source":"cloudflare-official-ipv4-cidrs","measured_at":"2033-05-18T03:33:20Z","measured_at_epoch":2000000000,"probe_type":"eyeball-network","carrier_asns":[4134,4837,9808],"candidates":[{"ip":"104.16.0.10","source_cidr":"104.16.0.0/13","observations":2,"carrier_count":2,"avg_rtt_ms":30,"asns":[4134,4837]}]}
EOF
    globalping_cache_valid \
        || fail "Cloudflare official-pool cache must be accepted"
    assert_equal "Cloudflare endpoints always retain the domain fallback" \
        $'node.example.com\n104.16.0.10' "$(cdn_client_endpoints)"
    assert_equal "Cloudflare fallback node has an explicit name" \
        "VLESS_XHTTP_H2_DOMAIN" "$(xhttp_node_name_for_endpoint 1)"
    assert_equal "Cloudflare optimized IP numbering starts after the fallback" \
        "VLESS_XHTTP_H2_IP_01" "$(xhttp_node_name_for_endpoint 2)"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    mihomo_nodes=$(build_mihomo_nodes)
    assert_contains "Cloudflare subscription renders the domain fallback node" \
        "${mihomo_nodes}" '"VLESS_XHTTP_H2_DOMAIN"'
    assert_contains "Cloudflare subscription renders an optimized IP node" \
        "${mihomo_nodes}" '"VLESS_XHTTP_H2_IP_01"'
    assert_contains "Cloudflare optimized IP keeps the CDN hostname as SNI" \
        "${mihomo_nodes}" 'servername: "node.example.com"'
    mihomo_group=$(build_mihomo_proxy_groups)
    assert_contains "Cloudflare URL test includes the domain fallback" \
        "${mihomo_group}" '- "VLESS_XHTTP_H2_DOMAIN"'
    assert_contains "Cloudflare URL test includes the optimized IP" \
        "${mihomo_group}" '- "VLESS_XHTTP_H2_IP_01"'
    assert_contains "Cloudflare URL test runs every 600 seconds" \
        "${mihomo_group}" 'interval: 600'
    assert_equal "Cloudflare keeps six final candidates per carrier" \
        "6" "${CLOUDFLARE_CANDIDATES_PER_CARRIER}"
    assert_equal "Cloudflare publishes at most eighteen optimized IPs" \
        "18" "${CLOUDFLARE_CANDIDATE_LIMIT}"

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

    # Zone-setting writes must send real JSON.  A shell-style object such as
    # {value:"2"} is rejected by Cloudflare with HTTP 400.
    setting_calls="${TMP_DIR}/setting-calls"
    : >"${setting_calls}"
    cloudflare_configure_rules() { :; }
    cloudflare_api_request() {
        printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >>"${setting_calls}"
        printf '{}\n'
    }
    cloudflare_configure_cdn
    origin_http_payload=$(awk -F '\t' '$2 ~ /origin_max_http_version/ {print $3}' "${setting_calls}")
    jq -e '.value == "2"' <<<"${origin_http_payload}" >/dev/null \
        || fail "Cloudflare origin HTTP/2 setting payload must be valid JSON"
    if grep -q '/settings/grpc' "${setting_calls}"; then
        fail "Cloudflare profile must not call the unavailable gRPC zone-setting API"
    fi
)

printf 'easy_all Cloudflare CDN profile tests passed\n'
