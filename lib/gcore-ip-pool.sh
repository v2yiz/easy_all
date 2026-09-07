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

hk_nets, jp_nets, la_nets = [], [], []

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
            elif country == "US" and ("Los Angeles" in city or region == "US-CA"):
                la_nets.append(net)
        except Exception:
            continue

# Map each CDN IP to its matching region and target carrier:
# Mobile: 9808 -> Hong Kong
# Unicom: 4837 -> Japan
# Telecom: 4134 -> Los Angeles
for ip in cdn_ips:
    if any(ip in net for net in hk_nets):
        print(f"{ip}\t9808\tmobile\tHK")
    elif any(ip in net for net in jp_nets):
        print(f"{ip}\t4837\tunicom\tJP")
    elif any(ip in net for net in la_nets):
        print(f"{ip}\t4134\ttelecom\tLA")
EOF
}

# Pre-validates IP locally through TLS SNI and health endpoint
gcore_validate_pool_candidate() {
    local ip=$1 body body_file curl_status
    validate_public_ipv4 "${ip}" || return 1
    body_file=$(mktemp "${RUNTIME_TMP}/gcore-health-body.XXXXXX")
    if curl -fsS --proto '=https' --tlsv1.2 \
        --connect-timeout 4 --max-time 10 --noproxy '*' \
        --resolve "${VLESS_CDN_DOMAIN}:443:${ip}" \
        -o "${body_file}" \
        "https://${VLESS_CDN_DOMAIN}/easy_all-health" 2>/dev/null; then
        curl_status=0
    else
        curl_status=$?
    fi
    body=$(<"${body_file}")
    rm -f -- "${body_file}"

    ((curl_status == 0)) && [[ "${body}" == "easy_all ok" ]]
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
    local ip=$1 asn=$2
    validate_public_ipv4 "${ip}" || return 1
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
    jobs_file=$(make_temp_dir)/gcore-globalping-jobs.tsv
    : >"${jobs_file}"
    : >"${destination}"

    while IFS=$'\t' read -r ip asn carrier region; do
        [[ -n "${ip}" && -n "${asn}" ]] || continue
        created=$(globalping_api_request POST "/measurements" \
            "$(gcore_globalping_measurement_request "${ip}" "${asn}")") \
            || continue
        measurement_id=$(jq -er \
            '.id | select(type == "string" and length > 0)' <<<"${created}") \
            || continue
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

# Deep Globalping HTTPS/TLS probe to eliminate SNI blocking or fake-up IPs
gcore_globalping_tls_measurement_request() {
    local ip=$1 asn=$2 domain=$3
    validate_public_ipv4 "${ip}" || return 1
    jq -cn --arg target "${ip}" \
        --argjson asn "${asn}" \
        --arg host "${domain}" '{
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
              method: "HEAD",
              path: "/easy_all-health",
              headers: {
                Host: $host
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
            | select(.result.tls.protocol != null and .result.tls.protocol != "")
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

# Selects top 2 candidates per carrier (Mobile->HK, Unicom->JP, Telecom->LA)
# Output 6 candidates flattened with sequential labels 1..6
gcore_select_carrier_candidates() {
    local observations_file=$1 per_carrier=${2:-${GCORE_CANDIDATES_PER_CARRIER}} limit=${3:-${GCORE_CANDIDATE_LIMIT}}
    jq -sc --argjson per_carrier "${per_carrier}" --argjson limit "${limit}" '
      [
        {asn: 9808, carrier: "mobile",  target_region: "HK"},
        {asn: 4837, carrier: "unicom",  target_region: "JP"},
        {asn: 4134, carrier: "telecom", target_region: "LA"}
      ] as $carriers |
      [
        $carriers[] as $c |
        ([ .[] | select(.carrier_asn == $c.asn) ]
         | group_by(.ip)
         | map(sort_by([(if .tls_verified == true then 0 else 1 end), .avg_rtt_ms])[0])
         | sort_by([(if .tls_verified == true then 0 else 1 end), .avg_rtt_ms, .ip])
         | .[0:$per_carrier]) as $matched |
        $matched[] |
        . + {
          carrier: $c.carrier,
          region: .region
        }
      ] | .[0:$limit]
      | to_entries
      | map(.value + {label: ((.key + 1)|tostring)})
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
    ((remaining > 10)) || {
        warn "Globalping 本小时免费测试额度不足（剩余 ${remaining}），请在额度重置后重试"
        return 1
    }

    count=$(wc -l <"${source}" | tr -d ' ')
    if ((count > remaining)); then
        warn "Globalping 剩余额度仅剩 ${remaining}，候选总量 ${count} 已自动缩减"
        head -n "${remaining}" "${source}" >"${destination}"
    else
        cat "${source}" >"${destination}"
    fi
}

gcore_build_official_pool_cache() {
    local destination=$1 raw_pool_file pool_file budgeted_pool_file
    local measurements_file observations_file tcp_top_candidates_tsv
    local tls_measurements_file tls_observations_file all_observations_file preliminary_file
    local pool_size prevalidated_pool_size measurement_count count
    local measured_at measured_at_epoch

    raw_pool_file=$(make_temp_dir)/gcore-raw-candidates.tsv
    pool_file=$(make_temp_dir)/gcore-candidates.tsv
    budgeted_pool_file=$(make_temp_dir)/gcore-budgeted-candidates.tsv
    measurements_file=$(make_temp_dir)/gcore-measurements.ndjson
    observations_file=$(make_temp_dir)/gcore-observations.ndjson
    tcp_top_candidates_tsv=$(make_temp_dir)/gcore-tcp-top.tsv
    tls_measurements_file=$(make_temp_dir)/gcore-tls-measurements.ndjson
    tls_observations_file=$(make_temp_dir)/gcore-tls-observations.ndjson
    all_observations_file=$(make_temp_dir)/gcore-all-observations.ndjson
    preliminary_file=$(make_temp_dir)/gcore-preliminary.json

    info "正在从 Gcore 官方 API 与 Geofeed 检索香港、日本、洛杉矶边缘单播 IP"
    gcore_generate_carrier_candidate_pool >"${raw_pool_file}" \
        || { warn "无法从 Gcore 官方 API 生成候选池"; return 1; }
    pool_size=$(wc -l <"${raw_pool_file}" | tr -d ' ')
    ((pool_size > 0)) || { warn "未匹配到任何 Gcore 目标地区 IP"; return 1; }

    info "Gcore 官方池共匹配到 ${pool_size} 个候选 IP，正在执行本机 CDN 入口预检"
    gcore_prevalidate_candidate_pool "${raw_pool_file}" "${pool_file}" \
        || return 1
    prevalidated_pool_size=$(wc -l <"${pool_file}" | tr -d ' ')

    gcore_limit_pool_to_globalping_budget "${pool_file}" "${budgeted_pool_file}" \
        || return 1

    info "正在对 $(wc -l <"${budgeted_pool_file}" | tr -d ' ') 个可用入口执行三网定向测速（移动->HK 联通->JP 电信->LA）"
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
        info "正在对候选执行 Globalping HTTP/TLS 深度验证（防 SNI 假通）"
        gcore_collect_globalping_tls_measurements \
            "${tcp_top_candidates_tsv}" "${VLESS_CDN_DOMAIN}" "${tls_measurements_file}" || true
        gcore_parse_tls_observations \
            "${tls_measurements_file}" >"${tls_observations_file}" || true
    fi

    cat "${tls_observations_file}" "${observations_file}" >"${all_observations_file}"

    gcore_select_carrier_candidates "${all_observations_file}" \
        "${GCORE_CANDIDATES_PER_CARRIER}" \
        "${GCORE_CANDIDATE_LIMIT}" >"${preliminary_file}"
    count=$(jq 'length' "${preliminary_file}")
    ((count > 0)) || return 1

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
        --argjson version "${GCORE_CACHE_VERSION}" \
        --argjson limit "${GCORE_CANDIDATE_LIMIT}" '
          .version == $version
          and .provider == "gcore"
          and .domain == $domain
          and .candidate_source == "gcore-official-public-ip-list"
          and .probe_type == "eyeball-network"
          and .carrier_asns == [9808,4837,4134]
          and (.measured_at_epoch | type) == "number"
          and (.candidates | type) == "array"
          and (.candidates | length) > 0
          and (.candidates | length) <= $limit
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

# Strictly output the curated candidates (NO fallback domain)
gcore_client_candidates() {
    if gcore_globalping_cache_valid; then
        jq -r '
          .candidates[0:6]
          | to_entries[]
          | [.value.ip, ((.key + 1)|tostring), .value.carrier, (.value.region // "")]
          | @tsv
        ' "${GLOBALPING_CACHE_FILE}"
    fi
}
