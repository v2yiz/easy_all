#!/usr/bin/env bash

# Gcore CDN endpoint discovery and carrier-targeted Globalping measurement.
#
# Resolves this account's CDN hostname from mainland China, Hong Kong, Taiwan,
# Japan, Singapore, and US west coast DNS perspectives, keeps a rolling history
# of verified ingress addresses, and probes them with China carrier probes.
# Outputs up to 2 curated IPs per carrier (up to 6 nodes).

readonly GCORE_GLOBALPING_PACKET_COUNT="${GCORE_GLOBALPING_PACKET_COUNT_OVERRIDE:-4}"
readonly GCORE_DNS_PROBES_PER_REGION="${GCORE_DNS_PROBES_PER_REGION_OVERRIDE:-12}"
readonly GCORE_DNS_AUX_PROBES_PER_REGION="${GCORE_DNS_AUX_PROBES_PER_REGION_OVERRIDE:-4}"
readonly GCORE_DNS_CARRIER_PROBES="${GCORE_DNS_CARRIER_PROBES_OVERRIDE:-8}"
readonly GCORE_DNS_RESOLVER_PROBES_PER_REGION="${GCORE_DNS_RESOLVER_PROBES_PER_REGION_OVERRIDE:-3}"
readonly GCORE_DNS_HISTORY_MAX_AGE_SECONDS="${GCORE_DNS_HISTORY_MAX_AGE_SECONDS_OVERRIDE:-604800}"
readonly GCORE_DNS_HISTORY_MAX_IPS="${GCORE_DNS_HISTORY_MAX_IPS_OVERRIDE:-60}"
readonly GCORE_CANDIDATES_PER_CARRIER=2
readonly GCORE_CANDIDATE_LIMIT=6
readonly GCORE_CACHE_VERSION=4
readonly GCORE_LOCAL_VALIDATION_CONCURRENCY=12
readonly GLOBALPING_POLL_ATTEMPTS="${GLOBALPING_POLL_ATTEMPTS_OVERRIDE:-20}"
readonly GCORE_PRECHECK_READY_ATTEMPTS="${GCORE_PRECHECK_READY_ATTEMPTS_OVERRIDE:-90}"
readonly GCORE_PRECHECK_READY_INTERVAL="${GCORE_PRECHECK_READY_INTERVAL_OVERRIDE:-10}"

gcore_globalping_dns_measurement_request() {
    local domain=$1 resolver=${2:-} scope=${3:-full}
    validate_domain "${domain}" || return 1
    [[ "${GCORE_DNS_PROBES_PER_REGION}" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "${GCORE_DNS_AUX_PROBES_PER_REGION}" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "${GCORE_DNS_CARRIER_PROBES}" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ "${GCORE_DNS_RESOLVER_PROBES_PER_REGION}" =~ ^[1-9][0-9]*$ ]] || return 1
    jq -cn --arg target "${domain}" \
        --arg resolver "${resolver}" \
        --arg scope "${scope}" \
        --argjson probes "${GCORE_DNS_PROBES_PER_REGION}" \
        --argjson aux_probes "${GCORE_DNS_AUX_PROBES_PER_REGION}" \
        --argjson carrier_probes "${GCORE_DNS_CARRIER_PROBES}" \
        --argjson resolver_probes "${GCORE_DNS_RESOLVER_PROBES_PER_REGION}" '{
          type:"dns",
          target:$target,
          locations:
            (if $scope == "full" then [
              {country:"HK",limit:$probes},
              {country:"TW",limit:$probes},
              {country:"JP",limit:$probes},
              {country:"SG",limit:$probes},
              {country:"US",city:"Los Angeles",limit:$probes},
              {country:"US",city:"San Jose",limit:$aux_probes},
              {country:"US",city:"Santa Clara",limit:$aux_probes},
              {country:"US",city:"Fremont",limit:$aux_probes},
              {country:"US",city:"San Francisco",limit:$aux_probes},
              {country:"US",city:"Seattle",limit:$aux_probes},
              {country:"US",city:"Portland",limit:$aux_probes},
              {country:"CN",asn:9808,tags:["eyeball-network"],limit:$carrier_probes},
              {country:"CN",asn:4837,tags:["eyeball-network"],limit:$carrier_probes},
              {country:"CN",asn:4134,tags:["eyeball-network"],limit:$carrier_probes}
            ] else [
              {country:"HK",limit:$resolver_probes},
              {country:"TW",limit:$resolver_probes},
              {country:"JP",limit:$resolver_probes},
              {country:"SG",limit:$resolver_probes},
              {country:"US",city:"Los Angeles",limit:$resolver_probes},
              {country:"US",city:"San Jose",limit:$resolver_probes},
              {country:"US",city:"Seattle",limit:$resolver_probes}
            ] end),
          timeout:15,
          measurementOptions:
            ({query:{type:"A"}}
             + if $resolver == "" then {} else {resolver:$resolver} end)
        }'
}

# Output format: <IP>\t<DNS_VIEW>
gcore_parse_globalping_dns_endpoints() {
    local measurement=$1
    jq -r '
      .results[]?
      | select(.result.status == "finished" and .result.statusCode == 0)
      | (
          if .probe.country == "CN" and .probe.asn == 9808 then "CN-CM"
          elif .probe.country == "CN" and .probe.asn == 4837 then "CN-CU"
          elif .probe.country == "CN" and .probe.asn == 4134 then "CN-CT"
          elif .probe.country == "HK" then "HK"
          elif .probe.country == "TW" then "TW"
          elif .probe.country == "JP" then "JP"
          elif .probe.country == "SG" then "SG"
          elif .probe.country == "US"
            and (.probe.city // "") == "Los Angeles"
          then "LA"
          elif .probe.country == "US"
            and (
              (.probe.city // "") == "San Jose"
              or (.probe.city // "") == "Santa Clara"
              or (.probe.city // "") == "Fremont"
              or (.probe.city // "") == "San Francisco"
              or (.probe.city // "") == "Seattle"
              or (.probe.city // "") == "Portland"
            )
          then "US-WEST"
          else empty
          end
        ) as $region
      | .result.answers[]?
      | select(.type == "A")
      | [.value, $region]
      | @tsv
    ' <<<"${measurement}"
}

gcore_emit_dns_candidates_for_carrier() {
    local endpoints_file=$1 asn=$2 carrier=$3 region
    shift 3
    for region in "$@"; do
        awk -F'\t' -v asn="${asn}" -v carrier="${carrier}" -v region="${region}" '
            $2 == region {print $1 "\t" asn "\t" carrier "\t" region}
        ' "${endpoints_file}"
    done
}

# Output format: <IP>\t<CARRIER_ASN>\t<CARRIER_NAME>\t<DNS_VIEW>
gcore_expand_dns_endpoints_for_carriers() {
    local source=$1 valid_file ip region
    valid_file=$(make_temp_dir)/gcore-dns-valid-addresses.tsv
    : >"${valid_file}"
    while IFS=$'\t' read -r ip region; do
        validate_public_ipv4 "${ip}" || continue
        case "${region}" in
        CN-CM | CN-CU | CN-CT | HK | TW | JP | SG | LA | US-WEST)
            printf '%s\t%s\n' "${ip}" "${region}" >>"${valid_file}"
            ;;
        esac
    done <"${source}"
    [[ -s "${valid_file}" ]] || return 1
    sort -u -o "${valid_file}" "${valid_file}"

    {
        gcore_emit_dns_candidates_for_carrier "${valid_file}" \
            9808 mobile CN-CM HK TW JP SG CN-CU CN-CT LA US-WEST
        gcore_emit_dns_candidates_for_carrier "${valid_file}" \
            4837 unicom CN-CU JP TW HK SG CN-CM CN-CT US-WEST LA
        gcore_emit_dns_candidates_for_carrier "${valid_file}" \
            4134 telecom CN-CT LA US-WEST JP TW HK SG CN-CM CN-CU
    } | awk -F'\t' '!seen[$1,$2]++'
}

gcore_parse_globalping_dns_candidates() {
    local measurement=$1 endpoints_file
    endpoints_file=$(make_temp_dir)/gcore-parsed-dns-endpoints.tsv
    gcore_parse_globalping_dns_endpoints "${measurement}" >"${endpoints_file}" \
        || return 1
    gcore_expand_dns_endpoints_for_carriers "${endpoints_file}"
}

gcore_discover_dns_endpoint_pool() {
    local destination=$1 resolver scope created measurement_id measurement
    local completed=0
    : >"${destination}"
    while read -r resolver scope; do
        [[ "${resolver}" == "probe-default" ]] && resolver=""
        created=$(globalping_api_request POST "/measurements" \
            "$(gcore_globalping_dns_measurement_request \
                "${VLESS_CDN_DOMAIN}" "${resolver}" "${scope}")") \
            || {
                warn "无法提交 Gcore DNS 候选发现测量（resolver=${resolver:-probe-default}）"
                continue
            }
        measurement_id=$(jq -er \
            '.id | select(type == "string" and length > 0)' <<<"${created}") \
            || continue
        measurement=$(gcore_wait_globalping_measurement "${measurement_id}") \
            || {
                warn "Gcore DNS 候选发现测量未完成（resolver=${resolver:-probe-default}）"
                continue
            }
        gcore_parse_globalping_dns_endpoints "${measurement}" >>"${destination}" \
            || continue
        completed=$((completed + 1))
    done <<'EOF'
probe-default full
1.1.1.1 core
8.8.8.8 core
EOF
    ((completed > 0)) || return 1
    sort -u -o "${destination}" "${destination}"
    [[ -s "${destination}" ]]
}

gcore_generate_carrier_candidate_pool() {
    local endpoints_file
    endpoints_file=$(make_temp_dir)/gcore-current-dns-endpoints.tsv
    gcore_discover_dns_endpoint_pool "${endpoints_file}" || return 1
    gcore_expand_dns_endpoints_for_carriers "${endpoints_file}"
}

gcore_wait_for_precheck_readiness() {
    local attempt body http_code curl_status=0 curl_error
    local body_file="${RUNTIME_TMP}/gcore-precheck-health-body"
    local error_file="${RUNTIME_TMP}/gcore-precheck-health-error"
    info "候选 IP 预检前等待 Gcore CDN 公网健康接口就绪"
    for ((attempt = 1; attempt <= GCORE_PRECHECK_READY_ATTEMPTS; attempt += 1)); do
        : >"${body_file}"
        : >"${error_file}"
        if http_code=$(curl -sS --proto '=https' --noproxy '*' \
            --connect-timeout 5 --max-time 15 -o "${body_file}" \
            -w '%{http_code}' "https://${VLESS_CDN_DOMAIN}/easy_all-health" \
            2>"${error_file}"); then
            curl_status=0
        else
            curl_status=$?
        fi
        body=$(<"${body_file}")
        if ((curl_status == 0)) && [[ "${http_code}" == "200" && "${body}" == "easy_all ok" ]]; then
            info "Gcore CDN 公网健康接口已就绪，开始候选 IP 预检"
            return 0
        fi
        if ((attempt == 1 || attempt % 3 == 0)); then
            curl_error=$(tr '\n' ' ' <"${error_file}")
            info "Gcore CDN 公网健康等待：attempt=${attempt}/${GCORE_PRECHECK_READY_ATTEMPTS}，curl=${curl_status}，HTTP=${http_code:-000}，body=${body:-<empty>}${curl_error:+，error=${curl_error}}"
        fi
        sleep "${GCORE_PRECHECK_READY_INTERVAL}"
    done
    warn "Gcore CDN 公网健康接口等待超时：curl=${curl_status}，HTTP=${http_code:-000}，body=${body:-<empty>}；停止候选 IP 预检"
    return 1
}

# Pre-validates IP locally through TLS SNI and an HTTP/1.1 WebSocket handshake.
gcore_probe_pool_candidate() {
    local ip=$1 ws_path=${WEBSOCKET_PATH:-/easy_all-ws} http_code="" curl_status=0
    validate_public_ipv4 "${ip}" || return 1
    http_code=$(curl --http1.1 -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 4 --max-time 10 --noproxy '*' \
        --resolve "${VLESS_CDN_DOMAIN}:443:${ip}" \
        -H "Host: ${VLESS_CDN_DOMAIN}" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        -H "Sec-WebSocket-Version: 13" \
        "https://${VLESS_CDN_DOMAIN}${ws_path}" 2>/dev/null) || curl_status=$?
    printf '%s\t%s\n' "${curl_status}" "${http_code:-000}"
    [[ "${http_code}" == "101" || "${http_code}" == "200" ]]
}

gcore_validate_pool_candidate() {
    gcore_probe_pool_candidate "$1" >/dev/null
}

gcore_prevalidate_candidate_pool() {
    local source=$1 destination=$2 validation_dir part failures_file failure_summary
    local unique_ips_file passed_ips_file ip index=0 record_count=0 passed_count=0
    local probe_result
    validation_dir=$(make_temp_dir)
    failures_file="${validation_dir}/failures"
    unique_ips_file="${validation_dir}/unique-ips"
    passed_ips_file="${validation_dir}/passed-ips"
    : >"${destination}"
    : >"${failures_file}"
    : >"${passed_ips_file}"
    cut -f1 "${source}" | awk 'NF && !seen[$0]++' >"${unique_ips_file}"

    while IFS= read -r ip; do
        [[ -n "${ip}" ]] || continue
        index=$((index + 1))
        (
            if probe_result=$(gcore_probe_pool_candidate "${ip}"); then
                printf '%s\n' "${ip}" \
                    >"${validation_dir}/$(printf '%06d' "${index}").ok"
            else
                printf '%s\t%s\n' "${ip}" "${probe_result:-1	000}" \
                    >"${validation_dir}/$(printf '%06d' "${index}").fail"
            fi
            true
        ) &
        if ((index % GCORE_LOCAL_VALIDATION_CONCURRENCY == 0)); then
            wait || true
        fi
    done <"${unique_ips_file}"
    wait || true

    for part in "${validation_dir}"/*.ok; do
        [[ -f "${part}" ]] || continue
        cat "${part}" >>"${passed_ips_file}"
        passed_count=$((passed_count + 1))
    done
    awk -F'\t' 'NR==FNR {passed[$1]=1; next} passed[$1]' \
        "${passed_ips_file}" "${source}" >"${destination}"
    record_count=$(wc -l <"${destination}" | tr -d ' ')
    for part in "${validation_dir}"/*.fail; do
        [[ -f "${part}" ]] || continue
        cat "${part}" >>"${failures_file}"
    done
    if [[ -s "${failures_file}" ]]; then
        failure_summary=$(awk -F'\t' '
            {key="curl=" $2 ",HTTP=" $3; counts[key]++}
            END {
                sep=""
                for (key in counts) {
                    printf "%s%s:%d", sep, key, counts[key]
                    sep="；"
                }
            }
        ' "${failures_file}")
        warn "Gcore DNS 入口预检淘汰 $((index - passed_count)) 个唯一 IP（${failure_summary}）"
    fi
    ((passed_count > 0)) || {
        warn "Gcore DNS 入口池没有通过本机 SNI 与 WebSocket 预检的候选"
        return 1
    }
    info "Gcore DNS 入口池本机预检通过 ${passed_count} 个唯一 IP（${record_count} 条运营商候选记录）"
}

# Globalping measurement request targeting ONLY the carrier designated for that IP
gcore_globalping_measurement_request() {
    local ip=$1 asn=$2 base_id=${3:-}
    validate_public_ipv4 "${ip}" || return 1
    if [[ -n "${base_id}" ]]; then
        jq -cn --arg target "${ip}" \
            --arg base "${base_id}" \
            --argjson packets "${GCORE_GLOBALPING_PACKET_COUNT}" '{
              type:"ping",
              target:$target,
              locations:[
                {magic:$base}
              ],
              timeout:15,
              measurementOptions:{
                packets:$packets,
                protocol:"TCP",
                port:443
              }
            }'
    else
        jq -cn --arg target "${ip}" \
            --argjson asn "${asn}" \
            --argjson packets "${GCORE_GLOBALPING_PACKET_COUNT}" '{
              type:"ping",
              target:$target,
              locations:[
                {country:"CN",asn:$asn,tags:["eyeball-network"],limit:1}
              ],
              timeout:15,
              measurementOptions:{
                packets:$packets,
                protocol:"TCP",
                port:443
              }
            }'
    fi
}

gcore_wait_globalping_measurement() {
    local measurement_id=$1 result status attempt
    for ((attempt = 1; attempt <= GLOBALPING_POLL_ATTEMPTS; attempt += 1)); do
        result=$(globalping_api_request GET "/measurements/${measurement_id}") \
            || return 1
        status=$(jq -r '.status // empty' <<<"${result}")
        if [[ "${status}" != "in-progress" ]]; then
            [[ "${status}" == "finished" ]] || return 1
            printf '%s\n' "${result}"
            return 0
        fi
        sleep 1
    done
    return 1
}

# Submits and collects Globalping TCP ping measurements
gcore_collect_globalping_measurements() {
    local pool_file=$1 destination=$2 jobs_file
    local ip asn carrier region created measurement_id result submitted=0 completed=0
    local base_id_9808="" base_id_4837="" base_id_4134="" base_id=""
    jobs_file=$(make_temp_dir)/gcore-globalping-jobs.tsv
    : >"${jobs_file}"
    : >"${destination}"

    while IFS=$'\t' read -r ip asn carrier region; do
        [[ -n "${ip}" && -n "${asn}" ]] || continue
        base_id=""
        case "${asn}" in
            9808) base_id="${base_id_9808}" ;;
            4837) base_id="${base_id_4837}" ;;
            4134) base_id="${base_id_4134}" ;;
        esac

        created=""
        if [[ -n "${base_id}" ]]; then
            created=$(globalping_api_request POST "/measurements" \
                "$(gcore_globalping_measurement_request "${ip}" "${asn}" "${base_id}")") \
                || created=""
        fi
        if [[ -z "${created}" ]]; then
            created=$(globalping_api_request POST "/measurements" \
                "$(gcore_globalping_measurement_request "${ip}" "${asn}")") \
                || continue
        fi
        measurement_id=$(jq -er \
            '.id | select(type == "string" and length > 0)' <<<"${created}") \
            || continue

        case "${asn}" in
            9808) [[ -z "${base_id_9808}" ]] && base_id_9808="${measurement_id}" ;;
            4837) [[ -z "${base_id_4837}" ]] && base_id_4837="${measurement_id}" ;;
            4134) [[ -z "${base_id_4134}" ]] && base_id_4134="${measurement_id}" ;;
        esac

        printf '%s\t%s\t%s\t%s\t%s\n' "${measurement_id}" "${ip}" "${asn}" "${carrier}" "${region}" \
            >>"${jobs_file}"
        submitted=$((submitted + 1))
    done <"${pool_file}"
    ((submitted > 0)) || {
        warn "Gcore DNS 入口池没有成功提交任何 Globalping 测量"
        return 1
    }

    sleep 2
    while IFS=$'\t' read -r measurement_id ip asn carrier region; do
        result=$(gcore_wait_globalping_measurement "${measurement_id}") \
            || continue
        jq -c --arg ip "${ip}" --argjson asn "${asn}" \
            --arg carrier "${carrier}" --arg region "${region}" \
            '{ip:$ip,carrier_asn:$asn,carrier:$carrier,region:$region,measurement:.}' \
            <<<"${result}" >>"${destination}"
        completed=$((completed + 1))
    done <"${jobs_file}"
    ((completed > 0)) || {
        warn "Gcore DNS 入口池的 Globalping 测量均未完成"
        return 1
    }
}

gcore_zero_loss_observations() {
    local measurements_file=$1
    jq -c --argjson packets "${GCORE_GLOBALPING_PACKET_COUNT}" '
      . as $entry
      | .measurement.results[]?
      | select(.probe.country == "CN")
      | select((.probe.tags // []) | index("eyeball-network"))
      | select(.probe.asn == $entry.carrier_asn)
      | select(.result.status == "finished")
      | select(.result.resolvedAddress == $entry.ip)
      | select(
          .result.stats.loss == 0
          and .result.stats.total == $packets
          and .result.stats.rcv == $packets
          and .result.stats.drop == 0
          and (.result.stats.avg | type) == "number"
        )
      | {
          ip:$entry.ip,
          carrier_asn:$entry.carrier_asn,
          carrier:$entry.carrier,
          region:$entry.region,
          avg_rtt_ms:.result.stats.avg,
          city:(.probe.city // ""),
          network:(.probe.network // ""),
          tls_verified:true
        }
    ' "${measurements_file}"
}

# Selects top 2 candidates per carrier from the configured regional views.
# Output 6 candidates flattened with sequential labels 1..6
gcore_select_carrier_candidates() {
    local observations_file=$1 per_carrier=${2:-${GCORE_CANDIDATES_PER_CARRIER}} limit=${3:-${GCORE_CANDIDATE_LIMIT}} history_file=${4:-}
    local history_ips_json="[]"
    if [[ -n "${history_file}" && -s "${history_file}" ]]; then
        if jq -e . "${history_file}" >/dev/null 2>&1; then
            history_ips_json=$(jq -c '[.candidates[]?.ip // .[]?.ip // empty]' "${history_file}" 2>/dev/null || echo "[]")
        else
            history_ips_json=$(jq -R -s -c 'split("\n") | map(split("\t")[0] | select(length > 0))' "${history_file}")
        fi
    elif [[ -n "${GLOBALPING_CACHE_FILE:-}" && -s "${GLOBALPING_CACHE_FILE}" ]]; then
        history_ips_json=$(jq -c '[.candidates[]?.ip // empty]' "${GLOBALPING_CACHE_FILE}" 2>/dev/null || echo "[]")
    fi

    jq -sc --argjson per_carrier "${per_carrier}" \
           --argjson limit "${limit}" \
           --argjson hist "${history_ips_json}" '
      . as $all_items |
      [
        {asn: 9808, carrier: "mobile",  primary: ["CN-CM", "HK", "TW", "SG"]},
        {asn: 4837, carrier: "unicom",  primary: ["CN-CU", "JP", "TW"]},
        {asn: 4134, carrier: "telecom", primary: ["CN-CT", "LA", "US-WEST"]}
      ] as $carriers |
      reduce $carriers[] as $c (
        {selected_ips: [], results: []};
        . as $state |
        (
          [ $all_items[]
            | select(.carrier_asn == $c.asn and .tls_verified == true)
            | . as $item
            | select($state.selected_ips | index($item.ip) | not)
            | . + {
                is_historical: ($hist | index($item.ip) != null),
                is_primary: (. as $cand | ($c.primary | index($cand.region) != null))
              }
          ]
          | sort_by([
              (if .is_historical == true then (.avg_rtt_ms - 5) else .avg_rtt_ms end)
              - (if .is_primary == true then 10 else 0 end),
              .avg_rtt_ms,
              .ip
            ])
          | .[0:$per_carrier]
        ) as $picked |
        {
          selected_ips: ($state.selected_ips + ($picked | map(.ip))),
          results: ($state.results + $picked)
        }
      ) | .results | to_entries | map(.value + {label: ((.key + 1)|tostring)}) | .[0:$limit]
    ' "${observations_file}"
}

gcore_limit_pool_to_globalping_budget() {
    local source=$1 destination=$2 limits remaining count
    limits=$(globalping_api_request GET "/limits") || {
        warn "无法读取 Globalping 剩余额度"
        return 1
    }
    remaining=$(jq -er '
        .rateLimit.measurements.create.remaining
        | select(type == "number" and . >= 0)
        | floor
    ' <<<"${limits}") || {
        warn "Globalping 未返回有效的剩余额度"
        return 1
    }

    local tcp_budget=${remaining}
    ((tcp_budget > 0)) || {
        warn "Globalping 本小时免费测试额度不足，请在额度重置后重试"
        return 1
    }

    count=$(wc -l <"${source}" | tr -d ' ')
    if (( count > tcp_budget )); then
        warn "Globalping 剩余额度仅剩 ${tcp_budget}，候选总量 ${count} 已按三网均衡缩减"
        python3 - "${source}" "${destination}" "${tcp_budget}" <<'EOF'
import sys

source_path, dest_path, budget_str = sys.argv[1], sys.argv[2], sys.argv[3]
budget = int(budget_str)

groups = {"9808": [], "4837": [], "4134": []}
others = []

with open(source_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        asn = parts[1] if len(parts) > 1 else ""
        if asn in groups:
            groups[asn].append(line)
        else:
            others.append(line)

per_group = max(1, budget // 3)
selected = []
for asn in ["9808", "4837", "4134"]:
    selected.extend(groups[asn][:per_group])

leftover = []
for asn in ["9808", "4837", "4134"]:
    leftover.extend(groups[asn][per_group:])
leftover.extend(others)

needed = budget - len(selected)
if needed > 0:
    selected.extend(leftover[:needed])

with open(dest_path, "w", encoding="utf-8") as f:
    for line in selected[:budget]:
        f.write(line + "\n")
EOF
    else
        cat "${source}" >"${destination}"
    fi
}

gcore_load_retained_dns_candidates() {
    local destination=$1 now=$2
    : >"${destination}"
    [[ -s "${GLOBALPING_CACHE_FILE}" ]] || return 0
    jq -r --argjson now "${now}" \
        --argjson max_age "${GCORE_DNS_HISTORY_MAX_AGE_SECONDS}" '
      . as $root
      | (
          if .candidate_source != "gcore-globalping-regional-dns" then empty
          elif (.discovered_candidates | type) == "array" then
            .discovered_candidates[]
          else
            .candidates[]?
            | {
                ip,
                carrier_asn,
                carrier,
                region,
                last_seen_epoch:$root.measured_at_epoch
              }
          end
        )
      | select(
          (.ip | type) == "string"
          and (.carrier_asn | type) == "number"
          and (.carrier | type) == "string"
          and (.region | type) == "string"
          and (
            .region == "CN-CM" or .region == "CN-CU" or .region == "CN-CT"
            or .region == "HK" or .region == "TW" or .region == "JP"
            or .region == "SG" or .region == "LA" or .region == "US-WEST"
          )
          and (.last_seen_epoch | type) == "number"
          and ($now - .last_seen_epoch) >= 0
          and ($now - .last_seen_epoch) <= $max_age
        )
      | [.ip, .carrier_asn, .carrier, .region, .last_seen_epoch]
      | @tsv
    ' "${GLOBALPING_CACHE_FILE}" 2>/dev/null >"${destination}" || : >"${destination}"
}

gcore_merge_dns_candidate_history() {
    local current=$1 history=$2 destination=$3 now=$4
    [[ "${GCORE_DNS_HISTORY_MAX_IPS}" =~ ^[1-9][0-9]*$ ]] || return 1
    {
        awk -F'\t' -v now="${now}" 'NF >= 4 {
            print $1 "\t" $2 "\t" $3 "\t" $4 "\t" now
        }' "${current}"
        cat "${history}"
    } | awk -F'\t' -v max_ips="${GCORE_DNS_HISTORY_MAX_IPS}" '
        NF < 5 {next}
        !known_ip[$1] {
            if (ip_count >= max_ips) next
            known_ip[$1]=1
            ip_count++
        }
        known_ip[$1] && !seen[$1,$2]++
    ' >"${destination}"
}

gcore_globalping_cache_compatible() {
    [[ -s "${GLOBALPING_CACHE_FILE}" ]] || return 1
    jq -e --arg domain "${VLESS_CDN_DOMAIN}" \
        --argjson version "${GCORE_CACHE_VERSION}" '
          .version == $version
          and .provider == "gcore"
          and .domain == $domain
          and .candidate_source == "gcore-globalping-regional-dns"
          and .probe_type == "eyeball-network"
          and .carrier_asns == [9808,4837,4134]
          and (.measured_at_epoch | type) == "number"
          and (.discovered_candidates | type) == "array"
          and (.discovered_candidates | length) > 0
          and all(.discovered_candidates[];
            (.ip | type) == "string"
            and (.carrier_asn | type) == "number"
            and (.carrier | type) == "string"
            and (.region | type) == "string"
            and (.last_seen_epoch | type) == "number"
          )
          and (.candidates | type) == "array"
          and (.candidates | length) > 0
          and all(.candidates[];
            (.ip | type) == "string"
            and (.avg_rtt_ms | type) == "number"
            and (.carrier | type) == "string"
            and (.label | type) == "string"
          )
        ' "${GLOBALPING_CACHE_FILE}" >/dev/null
}

gcore_build_dns_pool_cache() {
    local destination=$1 raw_pool_file current_pool_file pool_file budgeted_pool_file
    local measurements_file observations_file preliminary_file discovered_candidates_file
    local history_candidates_tsv retained_dns_file discovery_history_file hist_count
    local pool_size unique_pool_size prevalidated_pool_size measurement_count count
    local existing_count=0 discovered_candidates_json
    local measured_at measured_at_epoch

    measured_at_epoch=${GLOBALPING_NOW_EPOCH:-$(date +%s)}

    raw_pool_file=$(make_temp_dir)/gcore-raw-candidates.tsv
    current_pool_file=$(make_temp_dir)/gcore-current-candidates.tsv
    history_candidates_tsv=$(make_temp_dir)/gcore-history-candidates.tsv
    retained_dns_file=$(make_temp_dir)/gcore-retained-dns-candidates.tsv
    discovery_history_file=$(make_temp_dir)/gcore-discovery-history.tsv
    pool_file=$(make_temp_dir)/gcore-candidates.tsv
    budgeted_pool_file=$(make_temp_dir)/gcore-budgeted-candidates.tsv
    measurements_file=$(make_temp_dir)/gcore-measurements.ndjson
    observations_file=$(make_temp_dir)/gcore-observations.ndjson
    preliminary_file=$(make_temp_dir)/gcore-preliminary.json
    discovered_candidates_file=$(make_temp_dir)/gcore-discovered-candidates.tsv

    : >"${history_candidates_tsv}"
    if [[ -s "${GLOBALPING_CACHE_FILE}" ]]; then
        jq -r '
            .candidates[]?
            | [.ip, (.carrier_asn // 0), (.carrier // ""), (.region // ""), (.avg_rtt_ms // 0)]
            | @tsv
        ' "${GLOBALPING_CACHE_FILE}" 2>/dev/null >"${history_candidates_tsv}" || true
    fi
    gcore_load_retained_dns_candidates "${retained_dns_file}" "${measured_at_epoch}"
    hist_count=$(wc -l <"${retained_dns_file}" | tr -d ' ')

    info "正在通过中国大陆三网、中国香港、中国台北、日本、新加坡、美国西海岸及多公共解析器发现 Gcore CDN 域名入口"
    gcore_generate_carrier_candidate_pool >"${current_pool_file}" \
        || { warn "无法从 Gcore 多地区 DNS 解析生成入口候选池"; return 1; }
    gcore_merge_dns_candidate_history \
        "${current_pool_file}" "${retained_dns_file}" \
        "${discovery_history_file}" "${measured_at_epoch}"
    cut -f1-4 "${discovery_history_file}" >"${raw_pool_file}"

    pool_size=$(wc -l <"${raw_pool_file}" | tr -d ' ')
    ((pool_size > 0)) || { warn "未匹配到任何 Gcore 目标地区 IP"; return 1; }
    unique_pool_size=$(cut -f1 "${raw_pool_file}" | sort -u | wc -l | tr -d ' ')

    gcore_wait_for_precheck_readiness || return 1
    info "Gcore 多地区 DNS 汇总 ${pool_size} 条运营商候选记录（${unique_pool_size} 个唯一入口 IP，含 ${hist_count} 条历史记录），正在执行本机 CDN 入口预检"
    gcore_prevalidate_candidate_pool "${raw_pool_file}" "${pool_file}" \
        || return 1
    prevalidated_pool_size=$(wc -l <"${pool_file}" | tr -d ' ')
    awk -F'\t' '
        NR==FNR {passed[$1 SUBSEP $2]=1; next}
        passed[$1 SUBSEP $2]
    ' "${pool_file}" "${discovery_history_file}" >"${discovered_candidates_file}"

    gcore_limit_pool_to_globalping_budget "${pool_file}" "${budgeted_pool_file}" \
        || return 1

    info "正在对 $(wc -l <"${budgeted_pool_file}" | tr -d ' ') 个可用入口执行三网定向测速"
    gcore_collect_globalping_measurements "${budgeted_pool_file}" "${measurements_file}" \
        || return 1
    measurement_count=$(wc -l <"${measurements_file}" | tr -d ' ')

    gcore_zero_loss_observations "${measurements_file}" >"${observations_file}"
    [[ -s "${observations_file}" ]] || {
        warn "Gcore DNS 入口池没有三网零丢包候选"
        return 1
    }

    gcore_select_carrier_candidates "${observations_file}" \
        "${GCORE_CANDIDATES_PER_CARRIER}" \
        "${GCORE_CANDIDATE_LIMIT}" \
        "${history_candidates_tsv}" >"${preliminary_file}"

    count=$(jq 'length' "${preliminary_file}")
    if gcore_globalping_cache_compatible; then
        existing_count=$(jq '.candidates | length' "${GLOBALPING_CACHE_FILE}")
    fi
    if (( count == 0 )); then
        warn "Gcore DNS 入口池没有通过本机 TLS/WebSocket 与三网零丢包验证的有效候选"
        return 1
    fi
    if (( existing_count > count )); then
        warn "Gcore DNS 入口池本轮仅选出 ${count} 个独立有效候选，少于现有缓存 ${existing_count} 个，保留现有缓存"
        return 1
    fi
    if (( count < GCORE_CANDIDATE_LIMIT )); then
        warn "Gcore DNS 入口池本轮选出 ${count} 个独立有效候选（预期 ${GCORE_CANDIDATE_LIMIT} 个）"
    fi

    measured_at=$(date -u -r "${measured_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d "@${measured_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ')
    discovered_candidates_json=$(jq -Rn '
      [
        inputs
        | split("\t")
        | select(length >= 5)
        | {
            ip:.[0],
            carrier_asn:(.[1] | tonumber),
            carrier:.[2],
            region:.[3],
            last_seen_epoch:(.[4] | tonumber)
          }
      ]
    ' <"${discovered_candidates_file}")

    jq -n --arg domain "${VLESS_CDN_DOMAIN}" \
        --arg measured_at "${measured_at}" \
        --argjson version "${GCORE_CACHE_VERSION}" \
        --argjson measured_at_epoch "${measured_at_epoch}" \
        --argjson packets "${GCORE_GLOBALPING_PACKET_COUNT}" \
        --argjson pool_sample_size "${pool_size}" \
        --argjson prevalidated_pool_size "${prevalidated_pool_size}" \
        --argjson measurement_count "${measurement_count}" \
        --argjson dns_history_max_age_seconds "${GCORE_DNS_HISTORY_MAX_AGE_SECONDS}" \
        --argjson discovered_candidates "${discovered_candidates_json}" \
        --argjson candidates "$(<"${preliminary_file}")" '{
          version:$version,
          provider:"gcore",
          domain:$domain,
          candidate_source:"gcore-globalping-regional-dns",
          measured_at:$measured_at,
          measured_at_epoch:$measured_at_epoch,
          probe_country:"CN",
          probe_type:"eyeball-network",
          carrier_asns:[9808,4837,4134],
          protocol:"TCP+HTTPS",
          port:443,
          packets:$packets,
          pool_sample_size:$pool_sample_size,
          prevalidated_pool_size:$prevalidated_pool_size,
          measurement_count:$measurement_count,
          dns_history_max_age_seconds:$dns_history_max_age_seconds,
          discovered_candidates:$discovered_candidates,
          carriers:{
            mobile:([$candidates[] | select(.carrier=="mobile")]),
            unicom:([$candidates[] | select(.carrier=="unicom")]),
            telecom:([$candidates[] | select(.carrier=="telecom")])
          },
          candidates:$candidates
        }' >"${destination}"
}

gcore_globalping_cache_valid() {
    local now age
    gcore_globalping_cache_compatible || return 1
    now=${GLOBALPING_NOW_EPOCH:-$(date +%s)}
    age=$((now - $(jq -r '.measured_at_epoch' "${GLOBALPING_CACHE_FILE}")))
    ((age >= 0 && age <= GLOBALPING_CACHE_MAX_AGE_SECONDS))
}

refresh_gcore_globalping_cache() {
    local temp
    collect_globalping_token
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/gcore-cdn-ips.json.XXXXXX")
    cleanup_files+=("${temp}")
    gcore_build_dns_pool_cache "${temp}" || return 1
    install -o root -g root -m 0600 "${temp}" "${GLOBALPING_CACHE_FILE}"
    success "Gcore 多地区 DNS 入口池已更新 $(jq '.candidates | length' \
        "${GLOBALPING_CACHE_FILE}") 个三网定向精选 IPv4"
}

globalping_cache_valid() {
    gcore_globalping_cache_valid "$@"
}

refresh_globalping_cache() {
    refresh_gcore_globalping_cache "$@"
}

# Output only compatible curated candidates; Gcore mode has no domain fallback.
gcore_client_candidates() {
    if gcore_globalping_cache_compatible; then
        jq -r '
          .candidates[0:6]
          | to_entries[]
          | [.value.ip, ((.key + 1)|tostring), .value.carrier, (.value.region // "")]
          | @tsv
        ' "${GLOBALPING_CACHE_FILE}"
    fi
}
