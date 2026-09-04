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
assert_not_contains "Cloudflare profile has no endpoint mode flag" \
    "${profile_content}" 'CLOUDFLARE_CDN_ENDPOINT_MODE'
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
    "${profile_content}${runtime_content}" 'stream-up'
assert_contains "Cloudflare profile configures WebSocket inbound" \
    "${profile_content}" 'vless-websocket-in'
assert_contains "Cloudflare profile configures XHTTP inbound" \
    "${profile_content}" 'vless-xhttp-h2-in'
assert_not_contains "Cloudflare API token is never persisted in state" \
    "${profile_content}" 'CLOUDFLARE_API_TOKEN=%q'
assert_contains "Cloudflare purge prompt names all managed remote resources" \
    "${profile_content}" 'easy_all 托管的 Cloudflare DNS、规则和 Origin CA 证书'
assert_contains "Cloudflare purge removes managed DNS records" \
    "${profile_content}" 'cloudflare_purge_managed_dns_record'
assert_contains "Cloudflare purge removes stable-ref rules" \
    "${profile_content}" 'cloudflare_purge_managed_rule'

(
    # The profile must be sourceable without calling external services.
    GLOBALPING_CACHE_FILE_OVERRIDE="${TMP_DIR}/cloudflare-cdn-ips.json"
    XRAY_BIN=true
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
        packets:4, protocol:"TCP", port:443
      }
      and .locations == [
        {country:"CN",asn:4134,tags:["eyeball-network"],limit:1},
        {country:"CN",asn:4837,tags:["eyeball-network"],limit:1},
        {country:"CN",asn:9808,tags:["eyeball-network"],limit:1}
      ]
    ' <<<"${measurement_request}" >/dev/null \
        || fail "Cloudflare Globalping request must target three mainland eyeball carriers"

    tls_measurement_request=$(cloudflare_globalping_tls_measurement_request \
        '104.16.0.10' 4134 'node.example.com')
    jq -e '
      .type == "http"
      and .target == "104.16.0.10"
      and .timeout == 15
      and .locations == [{country:"CN",asn:4134,tags:["eyeball-network"],limit:1}]
      and .measurementOptions == {
        protocol:"HTTPS", port:443,
        request:{method:"HEAD",path:"/easy_all-health",headers:{Host:"node.example.com"}}
      }
    ' <<<"${tls_measurement_request}" >/dev/null \
        || fail "Cloudflare Globalping TLS verification request must target HEAD /easy_all-health with Host"

    measurements_file="${TMP_DIR}/cloudflare-measurements.ndjson"
    cat >"${measurements_file}" <<'EOF'
{"ip":"104.16.0.10","source_cidr":"104.16.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":4134,"city":"Shanghai","network":"Telecom","tags":["eyeball-network"]},"result":{"status":"finished","resolvedAddress":"104.16.0.10","stats":{"loss":0,"total":4,"rcv":4,"drop":0,"avg":20}}},{"probe":{"country":"CN","asn":4837,"city":"Beijing","network":"Unicom","tags":["eyeball-network"]},"result":{"status":"finished","resolvedAddress":"104.16.0.10","stats":{"loss":0,"total":4,"rcv":4,"drop":0,"avg":40}}}]}}
{"ip":"172.64.0.20","source_cidr":"172.64.0.0/13","measurement":{"results":[{"probe":{"country":"CN","asn":9808,"city":"Guangzhou","network":"Mobile","tags":["eyeball-network"]},"result":{"status":"finished","resolvedAddress":"172.64.0.20","stats":{"loss":0,"total":4,"rcv":4,"drop":0,"avg":30}}},{"probe":{"country":"CN","asn":4134,"city":"Hangzhou","network":"Telecom","tags":["datacenter-network"]},"result":{"status":"finished","resolvedAddress":"172.64.0.20","stats":{"loss":0,"total":4,"rcv":4,"drop":0,"avg":1}}}]}}
EOF
    observations_file="${TMP_DIR}/cloudflare-observations.ndjson"
    cloudflare_zero_loss_observations \
        "${measurements_file}" >"${observations_file}"
    assert_equal "Cloudflare accepts only successful eyeball carrier observations" \
        "3" "$(wc -l <"${observations_file}" | tr -d ' ')"
    ranked=$(cloudflare_select_carrier_candidates \
        "${observations_file}" 3 9)
    assert_equal "Cloudflare assigns carrier label for Telecom" \
        "电信01" "$(jq -r '.[] | select(.carrier == "telecom") | .label' <<<"${ranked}")"
    assert_equal "Cloudflare selects candidates for each carrier" \
        "3" "$(jq 'length' <<<"${ranked}")"

    overlapping_observations="${TMP_DIR}/cloudflare-overlapping-observations.ndjson"
    : >"${overlapping_observations}"
    for candidate_index in $(seq 1 18); do
        for carrier_asn in 4134 4837 9808; do
            jq -cn --arg ip "104.16.1.${candidate_index}" \
                --argjson asn "${carrier_asn}" \
                --argjson rtt "$((10 + candidate_index))" '{
                  ip:$ip,
                  source_cidr:"104.16.0.0/13",
                  carrier_asn:$asn,
                  avg_rtt_ms:$rtt,
                  city:"test",
                  network:"test"
                }' >>"${overlapping_observations}"
        done
    done
    overlapping_ranked=$(cloudflare_select_carrier_candidates \
        "${overlapping_observations}" 3 9)
    assert_equal "Cloudflare takes each carrier top three" \
        "9" "$(jq 'length' <<<"${overlapping_ranked}")"

    disjoint_observations="${TMP_DIR}/cloudflare-disjoint-observations.ndjson"
    : >"${disjoint_observations}"
    carrier_index=0
    for carrier_asn in 4134 4837 9808; do
        carrier_index=$((carrier_index + 1))
        for candidate_index in $(seq 1 10); do
            jq -cn --arg ip "104.16.${carrier_index}.${candidate_index}" \
                --argjson asn "${carrier_asn}" \
                --argjson rtt "$((10 + candidate_index))" '{
                  ip:$ip,
                  source_cidr:"104.16.0.0/13",
                  carrier_asn:$asn,
                  avg_rtt_ms:$rtt,
                  city:"test",
                  network:"test"
                }' >>"${disjoint_observations}"
        done
    done
    disjoint_ranked=$(cloudflare_select_carrier_candidates \
        "${disjoint_observations}" 3 9)
    assert_equal "Cloudflare caps candidates at limit" \
        "9" "$(jq 'length' <<<"${disjoint_ranked}")"

    raw_pool_file="${TMP_DIR}/cloudflare-raw-pool.tsv"
    prevalidated_pool_file="${TMP_DIR}/cloudflare-prevalidated-pool.tsv"
    printf '%s\n' \
        $'104.16.0.10\t104.16.0.0/13' \
        $'104.16.0.11\t104.16.0.0/13' \
        $'104.16.0.12\t104.16.0.0/13' >"${raw_pool_file}"
    (
        cloudflare_validate_pool_candidate() {
            [[ "$1" == "104.16.0.10" || "$1" == "104.16.0.12" ]]
        }
        cloudflare_prevalidate_candidate_pool \
            "${raw_pool_file}" "${prevalidated_pool_file}"
    )
    assert_equal "Cloudflare prevalidation removes inactive official-range IPs" \
        $'104.16.0.10\t104.16.0.0/13\n104.16.0.12\t104.16.0.0/13' \
        "$(<"${prevalidated_pool_file}")"

    budgeted_pool_file="${TMP_DIR}/cloudflare-budgeted-pool.tsv"
    (
        globalping_api_request() {
            [[ "$1" == "GET" && "$2" == "/limits" ]] \
                || fail "unexpected Globalping budget API request"
            printf '%s\n' \
                '{"rateLimit":{"measurements":{"create":{"remaining":6}}}}'
        }
        cloudflare_limit_pool_to_globalping_budget \
            "${raw_pool_file}" "${budgeted_pool_file}"
    )
    assert_equal "Cloudflare limits submissions to the current free probe budget" \
        "2" "$(wc -l <"${budgeted_pool_file}" | tr -d ' ')"

    (
        globalping_api_request() {
            printf '{"status":"finished","id":"test1"}\n'
        }
        wait_res=$(cloudflare_wait_globalping_measurement "test1")
        assert_contains "cloudflare_wait_globalping_measurement succeeds" \
            "${wait_res}" '"finished"'
    )

    generated_cache="${TMP_DIR}/cloudflare-generated-cache.json"
    (
        cloudflare_fetch_origin_ipv4_ranges() {
            printf '%s\n' '104.16.0.0/24'
        }
        cloudflare_limit_pool_to_globalping_budget() {
            cp "$1" "$2"
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
                  result:{status:"finished",resolvedAddress:$ip,stats:{loss:0,total:4,rcv:4,drop:0,avg:20}}
                },
                {
                  probe:{country:"CN",asn:4837,city:"Beijing",network:"Unicom",tags:["eyeball-network"]},
                  result:{status:"finished",resolvedAddress:$ip,stats:{loss:0,total:4,rcv:4,drop:0,avg:30}}
                },
                {
                  probe:{country:"CN",asn:9808,city:"Guangzhou",network:"Mobile",tags:["eyeball-network"]},
                  result:{status:"finished",resolvedAddress:$ip,stats:{loss:0,total:4,rcv:4,drop:0,avg:40}}
                }
              ]}
            }' >"${destination}"
        }
        cloudflare_collect_globalping_tls_measurements() {
            local candidates_file=$1 domain=$2 destination=$3
            while IFS=$'\t' read -r ip source_cidr asn rtt; do
                jq -cn --arg ip "${ip}" --arg source_cidr "${source_cidr}" \
                    --argjson asn "${asn}" --argjson rtt "${rtt}" '{
                      ip:$ip,source_cidr:$source_cidr,carrier_asn:$asn,avg_rtt_ms:$rtt,
                      measurement:{results:[{result:{status:"finished",statusCode:200,tls:{protocol:"TLSv1.3"}}}]}
                    }' >>"${destination}"
            done <"${candidates_file}"
        }
        cloudflare_validate_pool_candidate() { return 0; }
        GLOBALPING_NOW_EPOCH=2000000000
        cloudflare_build_official_pool_cache "${generated_cache}"
    )
    jq -e '
      .version == 4
      and .provider == "cloudflare"
      and .candidate_source == "cloudflare-official-ipv4-cidrs"
      and .probe_type == "eyeball-network"
      and .carrier_asns == [4134,4837,9808]
      and .pool_sample_size == 1
      and .prevalidated_pool_size == 1
      and .measurement_count == 1
      and (.candidates | length) == 3
      and .carriers.telecom[0].label == "电信01"
      and .carriers.unicom[0].label == "联通01"
      and .carriers.mobile[0].label == "移动01"
    ' "${generated_cache}" >/dev/null \
        || fail "Cloudflare official-pool cache schema is invalid"

    validation_calls="${TMP_DIR}/cloudflare-validation-calls"
    curl() {
        local output_file=""
        printf '%s\n' "$*" >>"${validation_calls}"
        while (($# > 0)); do
            if [[ "$1" == "-o" ]]; then
                output_file=$2
                shift 2
            else
                shift
            fi
        done
        [[ -n "${output_file}" ]] \
            || fail "Cloudflare validation must separate body from metadata"
        printf 'easy_all ok\n' >"${output_file}"
        printf '2'
    }
    cloudflare_validate_pool_candidate '104.16.0.10' \
        || fail "Cloudflare candidate health validation should pass"
    assert_contains "Cloudflare health validation requires HTTP/2" \
        "$(<"${validation_calls}")" '--http2'
    assert_contains "Cloudflare health validation pins the candidate with domain SNI" \
        "$(<"${validation_calls}")" \
        '--resolve node.example.com:443:104.16.0.10'
    unset -f curl

    if (
        curl() {
            local output_file=""
            while (($# > 0)); do
                if [[ "$1" == "-o" ]]; then
                    output_file=$2
                    shift 2
                else
                    shift
                fi
            done
            : >"${output_file}"
            printf '403\ttext/html'
        }
        cloudflare_validate_grpc_edge "${VLESS_CDN_DOMAIN}"
    ); then
        fail "Cloudflare gRPC validation must reject a disabled zone"
    fi
    (
        curl() {
            local output_file=""
            while (($# > 0)); do
                if [[ "$1" == "-o" ]]; then
                    output_file=$2
                    shift 2
                else
                    shift
                fi
            done
            : >"${output_file}"
            printf '200\ttext/plain'
        }
        cloudflare_validate_grpc_edge "${VLESS_CDN_DOMAIN}"
    ) || fail "Cloudflare gRPC validation must accept an enabled zone"
    assert_contains "Cloudflare refresh validates gRPC before candidate discovery" \
        "${profile_content}" \
        'cloudflare_validate_grpc_edge "${VLESS_CDN_DOMAIN}"'
    refresh_function=$(sed -n \
        '/^refresh_cloudflare_cdn_ips()/,/^}/p' "${PROFILE}")
    assert_contains "Cloudflare manual refresh repairs the hourly timer" \
        "${refresh_function}" 'install_globalping_refresh_timer'

    GLOBALPING_NOW_EPOCH=2000000000
    CDN_PROVIDER="cloudflare"
    XHTTP_NODE_NAME="VLESS_XHTTP_H2"
    WEBSOCKET_PATH="/ws-test"
    XRAY_WEBSOCKET_LOOPBACK_PORT=10087
    XRAY_XHTTP_LOOPBACK_PORT=10086
    cat >"${GLOBALPING_CACHE_FILE}" <<'EOF'
{"version":4,"provider":"cloudflare","domain":"node.example.com","candidate_source":"cloudflare-official-ipv4-cidrs","measured_at":"2033-05-18T03:33:20Z","measured_at_epoch":2000000000,"probe_type":"eyeball-network","carrier_asns":[4134,4837,9808],"carriers":{"telecom":[{"ip":"104.16.0.10","source_cidr":"104.16.0.0/13","avg_rtt_ms":20,"carrier":"telecom","label":"电信01"}],"unicom":[{"ip":"104.16.0.11","source_cidr":"104.16.0.0/13","avg_rtt_ms":30,"carrier":"unicom","label":"联通01"}],"mobile":[{"ip":"104.16.0.12","source_cidr":"104.16.0.0/13","avg_rtt_ms":40,"carrier":"mobile","label":"移动01"}]},"candidates":[{"ip":"104.16.0.10","source_cidr":"104.16.0.0/13","avg_rtt_ms":20,"carrier":"telecom","label":"电信01"},{"ip":"104.16.0.11","source_cidr":"104.16.0.0/13","avg_rtt_ms":30,"carrier":"unicom","label":"联通01"},{"ip":"104.16.0.12","source_cidr":"104.16.0.0/13","avg_rtt_ms":40,"carrier":"mobile","label":"移动01"}]}
EOF
    globalping_cache_valid \
        || fail "Cloudflare official-pool cache must be accepted"
    assert_equal "Cloudflare endpoints output only optimized candidate IPs without domain fallback" \
        $'104.16.0.10\n104.16.0.11\n104.16.0.12' "$(cdn_client_endpoints)"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    node_links=$(build_node_links)
    assert_contains "Cloudflare node links include Telecom XHTTP link" \
        "${node_links}" '#%E7%94%B5%E4%BF%A101_XHTTP'
    assert_contains "Cloudflare node links include Telecom WS link" \
        "${node_links}" '#%E7%94%B5%E4%BF%A101_WS'
    assert_contains "Cloudflare node links include Mobile XHTTP link" \
        "${node_links}" '#%E7%A7%BB%E5%8A%A801_XHTTP'
    assert_contains "Cloudflare node links include Mobile WS link" \
        "${node_links}" '#%E7%A7%BB%E5%8A%A801_WS'
    assert_not_contains "Cloudflare valid cache does not output domain fallback links" \
        "${node_links}" 'node.example.com:443'
    mihomo_nodes=$(build_mihomo_nodes)
    assert_contains "Cloudflare subscription renders Telecom XHTTP node" \
        "${mihomo_nodes}" '"电信01_XHTTP"'
    assert_contains "Cloudflare subscription renders Telecom WS node" \
        "${mihomo_nodes}" '"电信01_WS"'
    assert_contains "Cloudflare subscription renders Mobile XHTTP node" \
        "${mihomo_nodes}" '"移动01_XHTTP"'
    assert_contains "Cloudflare subscription renders Mobile WS node" \
        "${mihomo_nodes}" '"移动01_WS"'
    assert_not_contains "Cloudflare subscription does not render domain fallback node" \
        "${mihomo_nodes}" '"VLESS_XHTTP_H2_DOMAIN"'
    assert_contains "Cloudflare optimized IP keeps the CDN hostname as SNI" \
        "${mihomo_nodes}" 'servername: "node.example.com"'
    mihomo_group=$(build_mihomo_proxy_groups)
    mihomo_proxy_names=$(build_mihomo_proxy_names)
    assert_contains "Cloudflare URL-test group uses the concise AUTO name" \
        "${mihomo_group}" 'name: "AUTO"'
    assert_contains "Cloudflare URL-test group includes carrier groups" \
        "${mihomo_group}" 'name: "移动优选"'
    assert_contains "Cloudflare PROXY selects AUTO group" \
        "${mihomo_proxy_names}" '"AUTO"'
    assert_contains "Cloudflare PROXY selects carrier groups" \
        "${mihomo_proxy_names}" '"移动优选"'
    assert_not_contains "Cloudflare URL test does not include domain fallback" \
        "${mihomo_group}" 'DOMAIN'
    assert_contains "Cloudflare URL test includes Telecom WS node" \
        "${mihomo_group}" '- "电信01_WS"'
    assert_contains "Cloudflare URL test runs every 300 seconds" \
        "${mihomo_group}" 'interval: 300'
    assert_contains "Cloudflare URL test uses Cloudflare 204 endpoint" \
        "${mihomo_group}" 'url: https://cp.cloudflare.com/generate_204'
    assert_equal "Cloudflare takes 3 final candidates per carrier" \
        "3" "${CLOUDFLARE_CANDIDATES_PER_CARRIER}"
    assert_equal "Cloudflare publishes at most 9 optimized IPs" \
        "9" "${CLOUDFLARE_CANDIDATE_LIMIT}"

    # Verify Xray config rendering includes dual links
    (
        install() { :; }
        xhttp_render_xray_config
        jq -e '
          (.inbounds | map(.tag)) == ["vless-xhttp-h2-in", "vless-websocket-in"]
          and (.inbounds[] | select(.tag == "vless-websocket-in") | .streamSettings.wsSettings.path) == "/ws-test"
        ' "${RUNTIME_TMP}/xray-config.json" >/dev/null || fail "Xray config must contain both xhttp and websocket inbounds"
    )

    # Verify Nginx config rendering includes WebSocket proxy and XHTTP grpc pass
    (
        install() { :; }
        nginx() { :; }
        systemctl() { :; }
        SUBSCRIPTION_MODE=none
        ALLOWED_TOKENS=""
        XHTTP_ORIGIN_DOMAIN="${VLESS_CDN_DOMAIN}"
        write_nginx_config
        nginx_conf_content=$(<"${RUNTIME_TMP}/easy_all.conf")
        assert_contains "Nginx config includes websocket location" \
            "${nginx_conf_content}" 'location = /ws-test'
        assert_contains "Nginx config includes websocket backend pass" \
            "${nginx_conf_content}" 'proxy_pass http://127.0.0.1:10087;'
        assert_contains "Nginx config includes xhttp location" \
            "${nginx_conf_content}" 'location ^~ /xhttp-test-path/'
        assert_contains "Nginx config includes xhttp grpc pass" \
            "${nginx_conf_content}" 'grpc_pass grpc://127.0.0.1:10086;'
    )

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
    assert_contains "strict rule disables security challenge" "$(<"${rule_calls}")" '"security_level":"essentially_off"'
    assert_contains "strict rule disables browser integrity check" "$(<"${rule_calls}")" '"bic":false'

    # --purge-cloud must remove every easy_all-owned Cloudflare resource while
    # identifying rules by stable ref and DNS records by their managed comment.
    purge_calls="${TMP_DIR}/purge-calls"
    header_reads="${TMP_DIR}/purge-header-reads"
    strict_reads="${TMP_DIR}/purge-strict-reads"
    : >"${purge_calls}"
    : >"${header_reads}"
    : >"${strict_reads}"
    SUBSCRIPTION_MODE=deploy
    SUBSCRIPTION_DOMAIN='sub.example.com'
    CLOUDFLARE_HEADER_RULESET_ID='header-rules'
    CLOUDFLARE_STRICT_RULESET_ID='strict-rules'
    CLOUDFLARE_ORIGIN_CERT_ID='origin-cert'
    UNINSTALL_PURGE_CLOUD=1
    node_header_ref=$(cloudflare_ref "header:${VLESS_CDN_DOMAIN}:${XHTTP_PATH}")
    sub_header_ref=$(cloudflare_ref 'header:sub.example.com:/subscribe')
    node_strict_ref=$(cloudflare_ref "strict:${VLESS_CDN_DOMAIN}")
    sub_strict_ref=$(cloudflare_ref 'strict:sub.example.com')
    cloudflare_collect_api_token() { :; }
    cloudflare_api_request() {
        local method=$1 path=$2 reads
        printf '%s\t%s\n' "${method}" "${path}" >>"${purge_calls}"
        case "${method} ${path}" in
        "GET /zones/${CLOUDFLARE_ZONE_ID}/rulesets/header-rules")
            printf 'x\n' >>"${header_reads}"
            reads=$(wc -l <"${header_reads}" | tr -d ' ')
            if ((reads <= 2)); then
                jq -cn --arg first "${node_header_ref}" --arg second "${sub_header_ref}" \
                    '{name:"easy_all xhttp headers node.example.com",kind:"zone",phase:"http_request_late_transform",rules:[{id:"node-header",ref:$first},{id:"sub-header",ref:$second}]}'
            else
                printf '%s\n' '{"name":"easy_all xhttp headers node.example.com","kind":"zone","phase":"http_request_late_transform","rules":[]}'
            fi
            ;;
        "GET /zones/${CLOUDFLARE_ZONE_ID}/rulesets/strict-rules")
            printf 'x\n' >>"${strict_reads}"
            reads=$(wc -l <"${strict_reads}" | tr -d ' ')
            if ((reads <= 2)); then
                jq -cn --arg first "${node_strict_ref}" --arg second "${sub_strict_ref}" \
                    '{name:"easy_all xhttp strict node.example.com",kind:"zone",phase:"http_config_settings",rules:[{id:"node-strict",ref:$first},{id:"sub-strict",ref:$second}]}'
            else
                printf '%s\n' '{"name":"easy_all xhttp strict node.example.com","kind":"zone","phase":"http_config_settings","rules":[]}'
            fi
            ;;
        *'/dns_records?type=A&name=node.example.com&per_page=100')
            printf '%s\n' '[{"id":"node-dns","comment":"easy_all xhttp origin"}]'
            ;;
        *'/dns_records?type=A&name=sub.example.com&per_page=100')
            printf '%s\n' '[{"id":"sub-dns","comment":"easy_all xhttp origin"}]'
            ;;
        DELETE*) printf '{}\n' ;;
        *) fail "unexpected Cloudflare purge API path: ${method} ${path}" ;;
        esac
    }
    purge_cloudflare_resources_before_uninstall >/dev/null
    assert_equal "Cloudflare purge removes four stable-ref rules" "4" \
        "$(awk -F '\t' '$1 == "DELETE" && $2 ~ /\/rulesets\/.*\/rules\// {count++} END {print count + 0}' "${purge_calls}")"
    assert_equal "Cloudflare purge removes two empty owned rulesets" "2" \
        "$(awk -F '\t' '$1 == "DELETE" && $2 ~ /\/rulesets\/(header-rules|strict-rules)$/ {count++} END {print count + 0}' "${purge_calls}")"
    assert_equal "Cloudflare purge removes two managed DNS records" "2" \
        "$(awk -F '\t' '$1 == "DELETE" && $2 ~ /\/dns_records\// {count++} END {print count + 0}' "${purge_calls}")"
    assert_contains "Cloudflare purge revokes the Origin CA certificate" \
        "$(<"${purge_calls}")" $'DELETE\t/certificates/origin-cert'

    preserved_dns_calls="${TMP_DIR}/preserved-dns-calls"
    : >"${preserved_dns_calls}"
    cloudflare_api_request() {
        printf '%s\t%s\n' "$1" "$2" >>"${preserved_dns_calls}"
        case "$1 $2" in
        GET*'/dns_records?type=A&name=customer.example.com&per_page=100')
            printf '%s\n' '[{"id":"customer-dns","comment":"customer owned"}]'
            ;;
        DELETE*) fail "Cloudflare purge attempted to delete an unmarked DNS record" ;;
        *) fail "unexpected preserved Cloudflare DNS API path: $1 $2" ;;
        esac
    }
    cloudflare_purge_managed_dns_record 'customer.example.com' >/dev/null
    assert_equal "Cloudflare purge preserves unmarked DNS records" "0" \
        "$(awk -F '\t' '$1 == "DELETE" {count++} END {print count + 0}' "${preserved_dns_calls}")"

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
