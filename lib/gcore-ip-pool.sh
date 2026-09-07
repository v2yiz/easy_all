#!/usr/bin/env bash

# Gcore CDN endpoint discovery and carrier-targeted Globalping measurement.
#
# Fetches official CDN edge IPs from Gcore API, maps them to regions
# (Hong Kong, Japan, Los Angeles) using Gcore RFC 8805 Geofeed,
# and probes them strictly with dedicated carriers:
#   China Mobile (9808) -> Hong Kong (all available)
#   China Unicom (4837) -> Japan (all available)
#   China Telecom (4134) -> Los Angeles (all available)
# Strictly outputs top 2 curated IPs per carrier (total 6 nodes, no domain fallback).

readonly GCORE_POOL_PUBLIC_IP_LIST_URL="https://api.gcore.com/cdn/public-ip-list"
readonly GCORE_POOL_GEOFEED_URL="https://geofeed.gcore.lu/IP-Range.csv"
readonly GCORE_GLOBALPING_PACKET_COUNT="${GCORE_GLOBALPING_PACKET_COUNT_OVERRIDE:-4}"
readonly GCORE_CANDIDATES_PER_CARRIER=2
readonly GCORE_CANDIDATE_LIMIT=6
readonly GCORE_CACHE_VERSION=1
readonly GCORE_LOCAL_VALIDATION_CONCURRENCY=12
readonly GLOBALPING_POLL_ATTEMPTS="${GLOBALPING_POLL_ATTEMPTS_OVERRIDE:-20}"

gcore_fetch_official_cdn_ips() {
    local response
    response=$(curl -fsS --retry 3 --connect-timeout 10 --max-time 30 \
        "${GCORE_POOL_PUBLIC_IP_LIST_URL}") || return 1
    jq -er '
        .addresses
        | select(type == "array" and length > 0)
        | unique[]
        | sub("/32$"; "")
        | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
    ' <<<"${response}" | sort -u
}

gcore_fetch_official_geofeed() {
    curl -fsS --retry 3 --connect-timeout 10 --max-time 30 \
        "${GCORE_POOL_GEOFEED_URL}" || return 1
}

# Extracts candidate IPs for Hong Kong, Japan, and Los Angeles by cross-referencing
# Gcore official public-ip-list with Gcore official RFC 8805 geofeed.
# Output format: <IP>\t<CARRIER_ASN>\t<CARRIER_NAME>\t<REGION_NAME>
gcore_generate_carrier_candidate_pool() {
    local cdn_ips_file geofeed_file
    cdn_ips_file=$(make_temp_dir)/gcore-cdn-ips.txt
    geofeed_file=$(make_temp_dir)/gcore-geofeed.csv

    gcore_fetch_official_cdn_ips >"${cdn_ips_file}" || return 1
    [[ -s "${cdn_ips_file}" ]] || return 1
    gcore_fetch_official_geofeed >"${geofeed_file}" || return 1
    [[ -s "${geofeed_file}" ]] || return 1

    python3 - "${cdn_ips_file}" "${geofeed_file}" <<'EOF'
import sys, ipaddress, csv

cdn_ips_path, geofeed_path = sys.argv[1], sys.argv[2]

with open(cdn_ips_path, "r", encoding="utf-8") as f:
    cdn_ips = [ipaddress.ip_address(line.strip()) for line in f if line.strip()]

hk_nets, jp_nets, la_nets, ca_nets = [], [], [], []

with open(geofeed_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        try:
            parts = list(csv.reader([line]))[0]
            if len(parts) < 2:
                continue
            cidr = parts[0].strip()
            country = parts[1].strip() if len(parts) > 1 else ""
            region = parts[2].strip() if len(parts) > 2 else ""
            city = parts[3].strip() if len(parts) > 3 else ""

            net = ipaddress.ip_network(cidr)
            if net.version != 4:
                continue

            if country == "HK" or "Hong Kong" in city:
                hk_nets.append(net)
            elif country == "JP" or "Tokyo" in city or "Osaka" in city:
                jp_nets.append(net)
            elif country == "US":
                if "Los Angeles" in city:
                    la_nets.append(net)
                elif region == "US-CA" or "San Jose" in city or "Santa Clara" in city or "Fremont" in city:
                    ca_nets.append(net)
        except Exception:
            continue

hk_ips = [ip for ip in cdn_ips if any(ip in net for net in hk_nets)]
jp_ips = [ip for ip in cdn_ips if any(ip in net for net in jp_nets)]
la_ips = [ip for ip in cdn_ips if any(ip in net for net in la_nets)]
ca_ips = [ip for ip in cdn_ips if any(ip in net for net in ca_nets)]
us_ips = [(ip, "LA") for ip in la_ips] + [(ip, "US-CA") for ip in ca_ips]

# 80% primary, 20% cross-exploration
# Mobile (9808): Primary HK (up to 20), Cross JP (up to 5)
for ip in hk_ips[:20]:
    print(f"{ip}\t9808\tmobile\tHK")
for ip in jp_ips[:5]:
    print(f"{ip}\t9808\tmobile\tJP")

# Unicom (4837): Primary JP (up to 20), Cross HK (up to 5)
for ip in jp_ips[:20]:
    print(f"{ip}\t4837\tunicom\tJP")
for ip in hk_ips[:5]:
    print(f"{ip}\t4837\tunicom\tHK")

# Telecom (4134): Primary US (LA/US-CA) (up to 20), Cross JP (up to 5)
for ip, reg in us_ips[:20]:
    print(f"{ip}\t4134\ttelecom\t{reg}")
for ip in jp_ips[:5]:
    print(f"{ip}\t4134\ttelecom\tJP")
EOF
}

# Pre-validates IP locally through TLS SNI and WebSocket handshake
gcore_validate_pool_candidate() {
    local ip=$1 ws_path=${WEBSOCKET_PATH:-/easy_all-ws} http_code curl_status
    validate_public_ipv4 "${ip}" || return 1
    http_code=$(curl -sS -o /dev/null -w '%{http_code}' \
        --connect-timeout 4 --max-time 10 --noproxy '*' \
        --resolve "${VLESS_CDN_DOMAIN}:443:${ip}" \
        -H "Host: ${VLESS_CDN_DOMAIN}" \
        -H "Upgrade: websocket" \
        -H "Connection: Upgrade" \
        -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" \
        -H "Sec-WebSocket-Version: 13" \
        "https://${VLESS_CDN_DOMAIN}${ws_path}" 2>/dev/null) || curl_status=$?
    [[ "${http_code}" == "101" || "${http_code}" == "200" ]]
}

gcore_prevalidate_candidate_pool() {
    local source=$1 destination=$2 validation_dir part
    local ip asn carrier region index=0 count=0
    validation_dir=$(make_temp_dir)
    : >"${destination}"

    while IFS=$'\t' read -r ip asn carrier region; do
        [[ -n "${ip}" ]] || continue
        index=$((index + 1))
        (
            if gcore_validate_pool_candidate "${ip}"; then
                printf '%s\t%s\t%s\t%s\n' "${ip}" "${asn}" "${carrier}" "${region}" \
                    >"${validation_dir}/$(printf '%06d' "${index}").tsv"
            fi
            true
        ) &
        if ((index % GCORE_LOCAL_VALIDATION_CONCURRENCY == 0)); then
            wait || true
        fi
    done <"${source}"
    wait || true

    for part in "${validation_dir}"/*.tsv; do
        [[ -f "${part}" ]] || continue
        cat "${part}" >>"${destination}"
        count=$((count + 1))
    done
    ((count > 0)) || {
        warn "Gcore 官方 IP 池没有通过本机 SNI 与健康检查预检的候选"
        return 1
    }
    info "Gcore 官方 IP 池本机预检通过 ${count} 个候选"
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
        warn "Gcore 官方 IP 池没有成功提交任何 Globalping 测量"
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
        warn "Gcore 官方 IP 池的 Globalping 测量均未完成"
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
          network:(.probe.network // "")
        }
    ' "${measurements_file}"
}

# Deep Globalping WebSocket/TLS probe to eliminate SNI blocking or fake-up IPs
gcore_globalping_tls_measurement_request() {
    local ip=$1 asn=$2 domain=$3 ws_path=${4:-${WEBSOCKET_PATH:-/easy_all-ws}}
    validate_public_ipv4 "${ip}" || return 1
    jq -cn --arg target "${ip}" \
        --argjson asn "${asn}" \
        --arg host "${domain}" \
        --arg path "${ws_path}" '{
          type: "http",
          target: $target,
          locations: [
            {country: "CN", asn: $asn, tags: ["eyeball-network"], limit: 1}
          ],
          timeout: 15,
          measurementOptions: {
            protocol: "HTTPS",
            port: 443,
            request: {
              method: "GET",
              path: $path,
              headers: {
                Host: $host,
                Upgrade: "websocket",
                Connection: "Upgrade",
                "Sec-WebSocket-Key": "dGhlIHNhbXBsZSBub25jZQ==",
                "Sec-WebSocket-Version": "13"
              }
            }
          }
        }'
}

gcore_collect_globalping_tls_measurements() {
    local candidates_file=$1 domain=$2 destination=$3 jobs_file
    local ip asn carrier region rtt created measurement_id result submitted=0 completed=0
    jobs_file=$(make_temp_dir)/gcore-globalping-tls-jobs.tsv
    : >"${jobs_file}"
    : >"${destination}"

    while IFS=$'\t' read -r ip asn carrier region rtt; do
        [[ -n "${ip}" ]] || continue
        created=$(globalping_api_request POST "/measurements" \
            "$(gcore_globalping_tls_measurement_request "${ip}" "${asn}" "${domain}")") \
            || continue
        measurement_id=$(jq -er \
            '.id | select(type == "string" and length > 0)' <<<"${created}") \
            || continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "${measurement_id}" "${ip}" "${asn}" "${carrier}" "${region}" "${rtt}" \
            >>"${jobs_file}"
        submitted=$((submitted + 1))
    done <"${candidates_file}"
    ((submitted > 0)) || return 0

    sleep 2
    while IFS=$'\t' read -r measurement_id ip asn carrier region rtt; do
        result=$(gcore_wait_globalping_measurement "${measurement_id}") \
            || continue
        jq -c --arg ip "${ip}" --argjson asn "${asn}" \
            --arg carrier "${carrier}" --arg region "${region}" --argjson rtt "${rtt}" \
            '{ip:$ip,carrier_asn:$asn,carrier:$carrier,region:$region,avg_rtt_ms:$rtt,measurement:.}' \
            <<<"${result}" >>"${destination}"
        completed=$((completed + 1))
    done <"${jobs_file}"
}

gcore_parse_tls_observations() {
    local tls_file=$1
    [[ -s "${tls_file}" ]] || return 0
    jq -c '
        select(
            .measurement.results[]?
            | select(.result.status == "finished")
            | select(.result.tls != null and .result.tls.protocol != null and .result.tls.protocol != "")
            | select(.result.tls.authorized == true or .result.tls.error == "ERR_TLS_CERT_ALTNAME_INVALID")
            | select((.result.statusCode // 0) > 0 and (.result.statusCode // 0) < 500)
        )
        | {
            ip: .ip,
            carrier_asn: .carrier_asn,
            carrier: .carrier,
            region: .region,
            avg_rtt_ms: .avg_rtt_ms,
            tls_verified: true
        }
    ' "${tls_file}"
}

# Selects top 2 candidates per carrier (Mobile->HK, Unicom->JP, Telecom->LA/US-CA)
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
        {asn: 9808, carrier: "mobile",  primary: ["HK"]},
        {asn: 4837, carrier: "unicom",  primary: ["JP"]},
        {asn: 4134, carrier: "telecom", primary: ["LA", "US-CA"]}
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

    local stage2_reserve=9
    if (( remaining <= 15 )); then
        stage2_reserve=3
    fi
    if (( remaining <= stage2_reserve )); then
        warn "Globalping 本小时免费测试额度不足（剩余 ${remaining}，需预留 Stage 2 深度验证额度 ${stage2_reserve}）"
        return 1
    fi
    local tcp_budget=$(( remaining - stage2_reserve ))
    (( tcp_budget > 0 )) || {
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

gcore_build_official_pool_cache() {
    local destination=$1 raw_pool_file pool_file budgeted_pool_file
    local measurements_file observations_file tcp_top_candidates_tsv
    local tls_measurements_file tls_observations_file preliminary_file
    local history_candidates_tsv hist_count
    local pool_size prevalidated_pool_size measurement_count count
    local measured_at measured_at_epoch

    raw_pool_file=$(make_temp_dir)/gcore-raw-candidates.tsv
    history_candidates_tsv=$(make_temp_dir)/gcore-history-candidates.tsv
    pool_file=$(make_temp_dir)/gcore-candidates.tsv
    budgeted_pool_file=$(make_temp_dir)/gcore-budgeted-candidates.tsv
    measurements_file=$(make_temp_dir)/gcore-measurements.ndjson
    observations_file=$(make_temp_dir)/gcore-observations.ndjson
    tcp_top_candidates_tsv=$(make_temp_dir)/gcore-tcp-top.tsv
    tls_measurements_file=$(make_temp_dir)/gcore-tls-measurements.ndjson
    tls_observations_file=$(make_temp_dir)/gcore-tls-observations.ndjson
    preliminary_file=$(make_temp_dir)/gcore-preliminary.json

    : >"${history_candidates_tsv}"
    if [[ -s "${GLOBALPING_CACHE_FILE}" ]]; then
        jq -r '
            .candidates[]?
            | [.ip, (.carrier_asn // 0), (.carrier // ""), (.region // ""), (.avg_rtt_ms // 0)]
            | @tsv
        ' "${GLOBALPING_CACHE_FILE}" 2>/dev/null >"${history_candidates_tsv}" || true
    fi
    hist_count=$(wc -l <"${history_candidates_tsv}" | tr -d ' ')

    info "正在从 Gcore 官方 API 与 Geofeed 检索香港、日本、加州边缘单播 IP"
    gcore_generate_carrier_candidate_pool >"${raw_pool_file}.new" \
        || { warn "无法从 Gcore 官方 API 生成候选池"; return 1; }

    {
        if (( hist_count > 0 )); then
            awk -F'\t' '{print $1 "\t" $2 "\t" $3 "\t" $4}' "${history_candidates_tsv}"
        fi
        cat "${raw_pool_file}.new"
    } | awk -F'\t' '!seen[$1,$2]++' >"${raw_pool_file}"

    pool_size=$(wc -l <"${raw_pool_file}" | tr -d ' ')
    ((pool_size > 0)) || { warn "未匹配到任何 Gcore 目标地区 IP"; return 1; }

    info "Gcore 官方池共匹配到 ${pool_size} 个候选 IP（含 ${hist_count} 个历史候选），正在执行本机 CDN 入口预检"
    gcore_prevalidate_candidate_pool "${raw_pool_file}" "${pool_file}" \
        || return 1
    prevalidated_pool_size=$(wc -l <"${pool_file}" | tr -d ' ')

    gcore_limit_pool_to_globalping_budget "${pool_file}" "${budgeted_pool_file}" \
        || return 1

    info "正在对 $(wc -l <"${budgeted_pool_file}" | tr -d ' ') 个可用入口执行三网定向测速"
    gcore_collect_globalping_measurements "${budgeted_pool_file}" "${measurements_file}" \
        || return 1
    measurement_count=$(wc -l <"${measurements_file}" | tr -d ' ')

    gcore_zero_loss_observations "${measurements_file}" >"${observations_file}"
    [[ -s "${observations_file}" ]] || {
        warn "Gcore 官方 IP 池没有零丢包候选"
        return 1
    }

    # Extract top 3 candidates per carrier for Stage 2 HTTP/TLS verification
    jq -s -r '
        group_by(.carrier_asn)
        | map(sort_by(.avg_rtt_ms) | .[0:3])
        | add
        | .[]?
        | [.ip, .carrier_asn, .carrier, .region, .avg_rtt_ms]
        | @tsv
    ' "${observations_file}" >"${tcp_top_candidates_tsv}"

    if [[ -s "${tcp_top_candidates_tsv}" ]]; then
        info "正在对候选执行 Globalping WebSocket/TLS 深度验证（防 SNI 假通与链路中断）"
        gcore_collect_globalping_tls_measurements \
            "${tcp_top_candidates_tsv}" "${VLESS_CDN_DOMAIN}" "${tls_measurements_file}" || true
        gcore_parse_tls_observations \
            "${tls_measurements_file}" >"${tls_observations_file}" || true
    fi

    gcore_select_carrier_candidates "${tls_observations_file}" \
        "${GCORE_CANDIDATES_PER_CARRIER}" \
        "${GCORE_CANDIDATE_LIMIT}" \
        "${history_candidates_tsv}" >"${preliminary_file}"

    count=$(jq 'length' "${preliminary_file}")
    if [[ -s "${GLOBALPING_CACHE_FILE}" ]]; then
        if (( count < GCORE_CANDIDATE_LIMIT )); then
            warn "Gcore 官方 IP 池未选满 ${GCORE_CANDIDATE_LIMIT} 个独立有效候选（实际 ${count} 个），保留现有缓存"
            return 1
        fi
    else
        if (( count == 0 )); then
            warn "Gcore 官方 IP 池没有通过 TLS/WebSocket 验证的有效候选"
            return 1
        fi
        if (( count < GCORE_CANDIDATE_LIMIT )); then
            warn "Gcore 官方 IP 池首次生成仅选出 ${count} 个独立有效候选（预期 ${GCORE_CANDIDATE_LIMIT} 个）"
        fi
    fi

    measured_at_epoch=${GLOBALPING_NOW_EPOCH:-$(date +%s)}
    measured_at=$(date -u -r "${measured_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d "@${measured_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ')

    jq -n --arg domain "${VLESS_CDN_DOMAIN}" \
        --arg measured_at "${measured_at}" \
        --argjson version "${GCORE_CACHE_VERSION}" \
        --argjson measured_at_epoch "${measured_at_epoch}" \
        --argjson packets "${GCORE_GLOBALPING_PACKET_COUNT}" \
        --argjson pool_sample_size "${pool_size}" \
        --argjson prevalidated_pool_size "${prevalidated_pool_size}" \
        --argjson measurement_count "${measurement_count}" \
        --argjson candidates "$(<"${preliminary_file}")" '{
          version:$version,
          provider:"gcore",
          domain:$domain,
          candidate_source:"gcore-official-public-ip-list",
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
    [[ -s "${GLOBALPING_CACHE_FILE}" ]] || return 1
    jq -e --arg domain "${VLESS_CDN_DOMAIN}" \
        --argjson version "${GCORE_CACHE_VERSION}" '
          .version == $version
          and .provider == "gcore"
          and .domain == $domain
          and .candidate_source == "gcore-official-public-ip-list"
          and .probe_type == "eyeball-network"
          and .carrier_asns == [9808,4837,4134]
          and (.measured_at_epoch | type) == "number"
          and (.candidates | type) == "array"
          and (.candidates | length) > 0
          and all(.candidates[];
            (.ip | type) == "string"
            and (.avg_rtt_ms | type) == "number"
            and (.carrier | type) == "string"
            and (.label | type) == "string"
          )
        ' "${GLOBALPING_CACHE_FILE}" >/dev/null || return 1
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
    gcore_build_official_pool_cache "${temp}" || return 1
    install -o root -g root -m 0600 "${temp}" "${GLOBALPING_CACHE_FILE}"
    success "Gcore 官方 IP 池已更新 $(jq '.candidates | length' \
        "${GLOBALPING_CACHE_FILE}") 个三网定向精选 IPv4"
}

refresh_globalping_cache() {
    refresh_gcore_globalping_cache "$@"
}

# Output the curated candidates (falls back to domain if no cache)
gcore_client_candidates() {
    if [[ -s "${GLOBALPING_CACHE_FILE}" ]] \
        && jq -e '.candidates | type == "array" and length > 0' "${GLOBALPING_CACHE_FILE}" >/dev/null 2>&1; then
        jq -r '
          .candidates[0:6]
          | to_entries[]
          | [.value.ip, ((.key + 1)|tostring), .value.carrier, (.value.region // "")]
          | @tsv
        ' "${GLOBALPING_CACHE_FILE}"
    fi
}
