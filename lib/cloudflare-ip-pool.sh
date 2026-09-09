#!/usr/bin/env bash

# Cloudflare-only endpoint discovery.

readonly CLOUDFLARE_POOL_SAMPLE_LIMIT="${CLOUDFLARE_POOL_SAMPLE_LIMIT_OVERRIDE:-120}"
readonly CLOUDFLARE_GLOBALPING_PACKET_COUNT="${CLOUDFLARE_GLOBALPING_PACKET_COUNT_OVERRIDE:-10}"
readonly CLOUDFLARE_CANDIDATES_PER_CARRIER="${CLOUDFLARE_CANDIDATES_PER_CARRIER_OVERRIDE:-2}"
readonly CLOUDFLARE_CANDIDATE_LIMIT=6
readonly CLOUDFLARE_CACHE_VERSION=8
readonly CLOUDFLARE_PROBES_PER_CANDIDATE=3
readonly CLOUDFLARE_LOCAL_VALIDATION_CONCURRENCY=12
readonly GLOBALPING_POLL_ATTEMPTS="${GLOBALPING_POLL_ATTEMPTS_OVERRIDE:-20}"

readonly CLOUDFLARE_PRIORITY_IPV4_CIDRS=(
    "104.16.0.0/13"
    "104.24.0.0/14"
    "172.64.0.0/13"
    "162.159.0.0/16"
    "198.41.128.0/17"
    "197.234.240.0/22"
    "188.114.96.0/20"
)

cloudflare_ipv4_to_uint32() {
    local ip=$1 a b c d
    validate_ipv4 "${ip}" || return 1
    IFS=. read -r a b c d <<<"${ip}"
    printf '%u' "$(((10#${a} << 24) | (10#${b} << 16) | (10#${c} << 8) | 10#${d}))"
}

cloudflare_uint32_to_ipv4() {
    local value=$1
    ((value >= 0 && value <= 4294967295)) || return 1
    printf '%d.%d.%d.%d' \
        "$(((value >> 24) & 255))" "$(((value >> 16) & 255))" \
        "$(((value >> 8) & 255))" "$((value & 255))"
}

cloudflare_ipv4_in_cidr() {
    local ip=$1 cidr=$2 network prefix ip_value network_value mask
    network=${cidr%/*}
    prefix=${cidr#*/}
    [[ "${prefix}" =~ ^[0-9]+$ ]] && ((prefix >= 8 && prefix <= 32)) \
        || return 1
    ip_value=$(cloudflare_ipv4_to_uint32 "${ip}") || return 1
    network_value=$(cloudflare_ipv4_to_uint32 "${network}") || return 1
    mask=$(((0xFFFFFFFF << (32 - prefix)) & 0xFFFFFFFF))
    (( (ip_value & mask) == (network_value & mask) ))
}

cloudflare_generate_candidate_pool() {
    local ranges_file=$1
    local sample_limit=${2:-${CLOUDFLARE_POOL_SAMPLE_LIMIT}}
    local epoch=${3:-${GLOBALPING_NOW_EPOCH:-$(date +%s)}}

    [[ -s "${ranges_file}" && "${sample_limit}" =~ ^[1-9][0-9]*$ ]] || return 1

    python3 - "${ranges_file}" "${sample_limit}" "${epoch}" "${CLOUDFLARE_PRIORITY_IPV4_CIDRS[@]}" <<'EOF'
import sys, ipaddress

ranges_file = sys.argv[1]
sample_limit = int(sys.argv[2])
epoch = int(sys.argv[3])
priority_cidrs = [ipaddress.ip_network(c) for c in sys.argv[4:]]
pri_ranges = [(int(net.network_address), int(net.broadcast_address)) for net in priority_cidrs]

pri_blocks = []
oth_blocks = []

with open(ranges_file, "r", encoding="utf-8") as f:
    for line in f:
        cidr = line.strip()
        if not cidr:
            continue
        try:
            net = ipaddress.ip_network(cidr)
            for sub in net.subnets(new_prefix=24):
                sub_start = int(sub.network_address)
                if any(r[0] <= sub_start <= r[1] for r in pri_ranges):
                    pri_blocks.append((sub_start, cidr))
                else:
                    oth_blocks.append((sub_start, cidr))
        except Exception:
            continue

if not pri_blocks and not oth_blocks:
    sys.exit(1)

if pri_blocks and oth_blocks:
    pri_limit = max(1, min(len(pri_blocks), sample_limit * 7 // 10))
    oth_limit = min(len(oth_blocks), sample_limit - pri_limit)
elif pri_blocks:
    pri_limit = min(len(pri_blocks), sample_limit)
    oth_limit = 0
else:
    pri_limit = 0
    oth_limit = min(len(oth_blocks), sample_limit)

hour = epoch // 3600
responsive_hosts = [1, 2, 3, 4, 8, 16, 24, 32, 64, 100, 128, 150, 172, 198, 200]

if pri_limit > 0:
    for i in range(pri_limit):
        idx = (hour + (i * len(pri_blocks) // pri_limit)) % len(pri_blocks)
        block_val, src_cidr = pri_blocks[idx]
        host = responsive_hosts[(hour * 7 + i * 11 + (block_val >> 8)) % len(responsive_hosts)]
        cand_ip = str(ipaddress.IPv4Address(block_val + host))
        print(f"{cand_ip}\t{src_cidr}")

if oth_limit > 0:
    for i in range(oth_limit):
        idx = (hour + (i * len(oth_blocks) // oth_limit)) % len(oth_blocks)
        block_val, src_cidr = oth_blocks[idx]
        host = responsive_hosts[(hour * 7 + i * 11 + (block_val >> 8)) % len(responsive_hosts)]
        cand_ip = str(ipaddress.IPv4Address(block_val + host))
        print(f"{cand_ip}\t{src_cidr}")
EOF
}

cloudflare_globalping_measurement_request() {
    local ip=$1 base_id=${2:-}
    validate_public_ipv4 "${ip}" || return 1
    if [[ -n "${base_id}" ]]; then
        jq -cn --arg target "${ip}" \
            --arg base "${base_id}" \
            --argjson packets "${CLOUDFLARE_GLOBALPING_PACKET_COUNT}" '{
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
            --argjson packets "${CLOUDFLARE_GLOBALPING_PACKET_COUNT}" '{
              type:"ping",
              target:$target,
              locations:[
                {country:"CN",asn:4134,tags:["eyeball-network"],limit:1},
                {country:"CN",asn:4837,tags:["eyeball-network"],limit:1},
                {country:"CN",asn:9808,tags:["eyeball-network"],limit:1}
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

cloudflare_wait_globalping_measurement() {
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

cloudflare_collect_globalping_measurements() {
    local pool_file=$1 destination=$2 jobs_file
    local ip source_cidr created measurement_id result submitted=0 completed=0
    jobs_file=$(make_temp_dir)/cloudflare-globalping-jobs.tsv
    : >"${jobs_file}"
    : >"${destination}"

    while IFS=$'\t' read -r ip source_cidr; do
        created=$(globalping_api_request POST "/measurements" \
            "$(cloudflare_globalping_measurement_request "${ip}")") \
            || continue
        measurement_id=$(jq -er \
            '.id | select(type == "string" and length > 0)' <<<"${created}") \
            || continue
        printf '%s\t%s\t%s\n' "${measurement_id}" "${ip}" "${source_cidr}" \
            >>"${jobs_file}"
        submitted=$((submitted + 1))
    done <"${pool_file}"
    ((submitted > 0)) || {
        warn "Cloudflare 官方 IP 池没有成功提交任何 Globalping 测量"
        return 1
    }

    sleep 2
    while IFS=$'\t' read -r measurement_id ip source_cidr; do
        result=$(cloudflare_wait_globalping_measurement "${measurement_id}") \
            || continue
        jq -c --arg ip "${ip}" --arg source_cidr "${source_cidr}" \
            '{ip:$ip,source_cidr:$source_cidr,address_family:"ipv4",measurement:.}' \
            <<<"${result}" >>"${destination}"
        completed=$((completed + 1))
    done <"${jobs_file}"
    ((completed > 0)) || {
        warn "Cloudflare 官方 IP 池的 Globalping 测量均未完成"
        return 1
    }
}

cloudflare_acceptable_loss_observations() {
    local measurements_file=$1
    jq -c --argjson packets "${CLOUDFLARE_GLOBALPING_PACKET_COUNT}" '
      . as $entry
      | .measurement.results[]?
      | select(.probe.country == "CN")
      | select((.probe.tags // []) | index("eyeball-network"))
      | select(.probe.asn == 4134 or .probe.asn == 4837 or .probe.asn == 9808)
      | select(.result.status == "finished")
      | select(.result.resolvedAddress == $entry.ip)
      | (($packets * 9 + 9) / 10 | floor) as $required_received
      | select(
          ((.result.stats.loss // 100) <= 10)
          and ((.result.stats.total // 0) == $packets)
          and ((.result.stats.rcv // 0) >= $required_received)
          and (.result.stats.avg | type) == "number"
        )
      | {
          ip:$entry.ip,
          source_cidr:$entry.source_cidr,
          address_family:($entry.address_family // "ipv4"),
          carrier_asn:.probe.asn,
          loss:(.result.stats.loss // 0),
          avg_rtt_ms:.result.stats.avg,
          city:(.probe.city // ""),
          network:(.probe.network // "")
        }
    ' "${measurements_file}"
}

cloudflare_select_carrier_candidates() {
    local observations_file=$1 per_carrier=$2 limit=$3 history_file=${4:-}

    python3 - "${observations_file}" "${per_carrier}" "${limit}" "${history_file}" <<'EOF'
import sys, json, os
from itertools import combinations

obs_file = sys.argv[1]
per_carrier = int(sys.argv[2])
limit = int(sys.argv[3])
hist_file = sys.argv[4] if len(sys.argv) > 4 else ""

hist_ips = set()
if hist_file and os.path.isfile(hist_file):
    with open(hist_file, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.strip().split("\t")
            if parts and parts[0]:
                hist_ips.add(parts[0])

all_items = []
if obs_file and os.path.isfile(obs_file):
    with open(obs_file, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    all_items.append(json.loads(line))
                except Exception:
                    pass

carriers = [
    {"asn": 4134, "carrier": "telecom", "prefix": "电信"},
    {"asn": 4837, "carrier": "unicom",  "prefix": "联通"},
    {"asn": 9808, "carrier": "mobile",  "prefix": "移动"}
]

carrier_items = []
for c in carriers:
    c_items = [
        it for it in all_items
        if it.get("carrier_asn") == c["asn"]
        and it.get("tls_verified") is True
        and it.get("address_family", "ipv4") == "ipv4"
    ]
    c_items.sort(key=lambda x: (
        (float(x.get("avg_rtt_ms", 999)) - 5.0) if x.get("ip") in hist_ips else float(x.get("avg_rtt_ms", 999)),
        float(x.get("avg_rtt_ms", 999)),
        x.get("ip", "")
    ))
    carrier_items.append((c, c_items))

def assign(index, selected_ips, picked):
    if index == len(carrier_items):
        return picked
    carrier, items = carrier_items[index]
    available = [item for item in items if item.get("ip") not in selected_ips]
    for choice in combinations(available, per_carrier):
        assigned = []
        for item in choice:
            item_copy = dict(item)
            item_copy["is_historical"] = item.get("ip") in hist_ips
            item_copy["carrier"] = carrier["carrier"]
            item_copy["address_family"] = "ipv4"
            assigned.append(item_copy)
        result = assign(
            index + 1,
            selected_ips | {item.get("ip") for item in choice},
            picked + assigned,
        )
        if result is not None:
            return result
    return None

results = assign(0, set(), []) or []

# Assign labels cleanly per carrier
carrier_counters = {c["carrier"]: 0 for c in carriers}
carrier_prefixes = {c["carrier"]: c["prefix"] for c in carriers}
for it in results:
    car = it["carrier"]
    carrier_counters[car] += 1
    it["label"] = f"{carrier_prefixes[car]}{carrier_counters[car]:02d}"

print(json.dumps(results[:limit]))
EOF
}

cloudflare_globalping_tls_measurement_request() {
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
              host: $host
            }
          }
        }'
}

cloudflare_collect_globalping_tls_measurements() {
    local candidates_file=$1 domain=$2 destination=$3 jobs_file
    local ip source_cidr asn rtt created measurement_id result submitted=0 completed=0
    jobs_file=$(make_temp_dir)/cloudflare-globalping-tls-jobs.tsv
    : >"${jobs_file}"
    : >"${destination}"

    while IFS=$'\t' read -r ip source_cidr asn rtt; do
        [[ -n "${ip}" ]] || continue
        created=$(globalping_api_request POST "/measurements" \
            "$(cloudflare_globalping_tls_measurement_request "${ip}" "${asn}" "${domain}")") \
            || continue
        measurement_id=$(jq -er \
            '.id | select(type == "string" and length > 0)' <<<"${created}") \
            || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "${measurement_id}" "${ip}" "${source_cidr}" "${asn}" "${rtt}" \
            >>"${jobs_file}"
        submitted=$((submitted + 1))
    done <"${candidates_file}"
    ((submitted > 0)) || return 0

    sleep 2
    while IFS=$'\t' read -r measurement_id ip source_cidr asn rtt; do
        result=$(cloudflare_wait_globalping_measurement "${measurement_id}") \
            || continue
        jq -c --arg ip "${ip}" --arg source_cidr "${source_cidr}" \
            --argjson asn "${asn}" --argjson rtt "${rtt}" \
            '{ip:$ip,source_cidr:$source_cidr,address_family:"ipv4",carrier_asn:$asn,avg_rtt_ms:$rtt,measurement:.}' \
            <<<"${result}" >>"${destination}"
        completed=$((completed + 1))
    done <"${jobs_file}"
}

cloudflare_parse_tls_observations() {
    local tls_file=$1
    [[ -s "${tls_file}" ]] || return 0
    jq -c '
        select(
            .measurement.results[]?
            | select(.result.status == "finished")
            | select(.result.tls != null and .result.tls.protocol != null and .result.tls.protocol != "")
            | select(.result.tls.authorized == true)
            | select(.result.statusCode == 200)
        )
        | {
            ip: .ip,
            source_cidr: .source_cidr,
            address_family: "ipv4",
            carrier_asn: .carrier_asn,
            avg_rtt_ms: .avg_rtt_ms,
            tls_verified: true
        }
    ' "${tls_file}"
}

cloudflare_validate_pool_candidate() {
    local ip=$1 body body_file http_version curl_status
    validate_public_ipv4 "${ip}" || return 1
    body_file=$(mktemp "${RUNTIME_TMP}/cloudflare-health-body.XXXXXX")
    if http_version=$(curl -fsS --http2 --proto '=https' --tlsv1.2 \
        --connect-timeout 4 --max-time 10 --noproxy '*' \
        --resolve "${VLESS_CDN_DOMAIN}:443:${ip}" \
        -o "${body_file}" \
        -w '%{http_version}' \
        "https://${VLESS_CDN_DOMAIN}/easy_all-health" 2>/dev/null); then
        curl_status=0
    else
        curl_status=$?
    fi
    body=$(<"${body_file}")
    rm -f -- "${body_file}"

    ((curl_status == 0)) \
        && [[ "${body}" == "easy_all ok" && "${http_version}" == "2" ]]
}

cloudflare_prevalidate_candidate_pool() {
    local source=$1 destination=$2 validation_dir part
    local ip source_cidr index=0 count=0
    validation_dir=$(make_temp_dir)
    : >"${destination}"

    while IFS=$'\t' read -r ip source_cidr; do
        index=$((index + 1))
        (
            if cloudflare_validate_pool_candidate "${ip}"; then
                printf '%s\t%s\n' "${ip}" "${source_cidr}" \
                    >"${validation_dir}/$(printf '%06d' "${index}").tsv"
            fi
            true
        ) &
        if ((index % CLOUDFLARE_LOCAL_VALIDATION_CONCURRENCY == 0)); then
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
        warn "Cloudflare 官方 IP 池没有通过 SNI、HTTP/2 与健康接口预检的候选"
        return 1
    }
    info "Cloudflare 官方 IP 池本机预检通过 ${count} 个候选"
}

cloudflare_limit_pool_to_globalping_budget() {
    local source=$1 destination=$2 limits remaining budget count
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

    local stage2_reserve=15
    if (( remaining <= 25 )); then
        stage2_reserve=6
    fi
    if (( remaining <= stage2_reserve )); then
        warn "Globalping 本小时剩余额度不足（剩余 ${remaining}，需预留 Stage 2 深度验证额度 ${stage2_reserve}）"
        return 1
    fi
    local tcp_remaining=$(( remaining - stage2_reserve ))
    budget=$(( tcp_remaining / CLOUDFLARE_PROBES_PER_CANDIDATE ))
    (( budget > 0 )) || {
        warn "Globalping 本小时免费测试额度不足，请在额度重置后重试"
        return 1
    }

    count=$(wc -l <"${source}" | tr -d ' ')
    if (( count > budget )); then
        warn "Globalping 剩余额度仅够测量 ${budget} 个 Cloudflare 候选，本轮已按 7:3 分层比例缩减"
        python3 - "${source}" "${destination}" "${budget}" "${CLOUDFLARE_PRIORITY_IPV4_CIDRS[@]}" <<'EOF'
import sys, ipaddress

source_path, dest_path, budget_str = sys.argv[1], sys.argv[2], sys.argv[3]
budget = int(budget_str)
priority_cidrs = [ipaddress.ip_network(c) for c in sys.argv[4:]]
pri_ranges = [(int(net.network_address), int(net.broadcast_address)) for net in priority_cidrs]

pri_lines = []
oth_lines = []

with open(source_path, "r", encoding="utf-8") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        parts = line.split("\t")
        ip = parts[0]
        try:
            ip_int = int(ipaddress.IPv4Address(ip))
            if any(r[0] <= ip_int <= r[1] for r in pri_ranges):
                pri_lines.append(line)
            else:
                oth_lines.append(line)
        except Exception:
            oth_lines.append(line)

pri_target = max(1, min(len(pri_lines), budget * 7 // 10))
oth_target = min(len(oth_lines), budget - pri_target)
if pri_target + oth_target < budget and len(pri_lines) > pri_target:
    pri_target = min(len(pri_lines), budget - oth_target)

selected = pri_lines[:pri_target] + oth_lines[:oth_target]
with open(dest_path, "w", encoding="utf-8") as f:
    for line in selected:
        f.write(line + "\n")
EOF
    else
        cat "${source}" >"${destination}"
    fi
}

cloudflare_build_official_pool_cache() {
    local destination=$1 ranges_file raw_pool_file pool_file budgeted_pool_file
    local measurements_file observations_file tcp_top_candidates_tsv
    local tls_measurements_file tls_observations_file preliminary_file
    local history_candidates_tsv hist_count new_sample_limit
    local count measured_at measured_at_epoch pool_size prevalidated_pool_size
    local measurement_count
    ranges_file=$(make_temp_dir)/cloudflare-official-ipv4.txt
    history_candidates_tsv=$(make_temp_dir)/cloudflare-history-candidates.tsv
    raw_pool_file=$(make_temp_dir)/cloudflare-raw-candidate-pool.tsv
    pool_file=$(make_temp_dir)/cloudflare-candidate-pool.tsv
    budgeted_pool_file=$(make_temp_dir)/cloudflare-budgeted-candidate-pool.tsv
    measurements_file=$(make_temp_dir)/cloudflare-measurements.ndjson
    observations_file=$(make_temp_dir)/cloudflare-observations.ndjson
    tcp_top_candidates_tsv=$(make_temp_dir)/cloudflare-tcp-top.tsv
    tls_measurements_file=$(make_temp_dir)/cloudflare-tls-measurements.ndjson
    tls_observations_file=$(make_temp_dir)/cloudflare-tls-observations.ndjson
    preliminary_file=$(make_temp_dir)/cloudflare-preliminary.json

    : >"${history_candidates_tsv}"
    if [[ -s "${GLOBALPING_CACHE_FILE}" ]]; then
        jq -r '
            .candidates[]?
            | select((.address_family // "ipv4") == "ipv4")
            | [.ip, .source_cidr, (.carrier_asn // 0), (.avg_rtt_ms // 0), (.carrier // "")]
            | @tsv
        ' "${GLOBALPING_CACHE_FILE}" 2>/dev/null >"${history_candidates_tsv}" || true
    fi
    hist_count=$(wc -l <"${history_candidates_tsv}" | tr -d ' ')

    cloudflare_fetch_origin_ipv4_ranges >"${ranges_file}" \
        || { warn "无法获取 Cloudflare 官方 IPv4 CIDR"; return 1; }

    new_sample_limit=$(( CLOUDFLARE_POOL_SAMPLE_LIMIT - hist_count ))
    (( new_sample_limit > 0 )) || new_sample_limit=${CLOUDFLARE_POOL_SAMPLE_LIMIT}

    cloudflare_generate_candidate_pool "${ranges_file}" "${new_sample_limit}" >"${raw_pool_file}.new" \
        || { warn "无法从 Cloudflare 官方 IPv4 CIDR 生成候选"; return 1; }

    {
        if (( hist_count > 0 )); then
            awk -F'\t' '{print $1 "\t" $2}' "${history_candidates_tsv}"
        fi
        cat "${raw_pool_file}.new"
    } | awk -F'\t' '!seen[$1]++' >"${raw_pool_file}"

    pool_size=$(wc -l <"${raw_pool_file}" | tr -d ' ')
    info "Cloudflare 官方 IP 池本轮抽样 ${pool_size} 个 /24 候选（含 ${hist_count} 个历史候选），正在执行本机 CDN 入口预检"
    cloudflare_prevalidate_candidate_pool "${raw_pool_file}" "${pool_file}" \
        || return 1
    prevalidated_pool_size=$(wc -l <"${pool_file}" | tr -d ' ')
    cloudflare_limit_pool_to_globalping_budget \
        "${pool_file}" "${budgeted_pool_file}" || return 1
    info "正在对 $(wc -l <"${budgeted_pool_file}" | tr -d ' ') 个可用入口执行三网探针预筛"

    cloudflare_collect_globalping_measurements \
        "${budgeted_pool_file}" "${measurements_file}" || return 1
    measurement_count=$(wc -l <"${measurements_file}" | tr -d ' ')
    cloudflare_acceptable_loss_observations \
        "${measurements_file}" >"${observations_file}"
    [[ -s "${observations_file}" ]] || {
        warn "Cloudflare 官方 IP 池没有丢包率不超过 10% 的候选"
        return 1
    }

    # Extract top 5 candidates per carrier for Stage 2 HTTP/TLS verification
    jq -s -r '
        group_by(.carrier_asn)
        | map(sort_by([.loss, .avg_rtt_ms]) | .[0:5])
        | add
        | .[]?
        | [.ip, .source_cidr, .carrier_asn, .avg_rtt_ms]
        | @tsv
    ' "${observations_file}" >"${tcp_top_candidates_tsv}"

    if [[ -s "${tcp_top_candidates_tsv}" ]]; then
        info "正在对候选执行 Globalping HTTP/TLS 深度验证（防 SNI 假通）"
        cloudflare_collect_globalping_tls_measurements \
            "${tcp_top_candidates_tsv}" "${VLESS_CDN_DOMAIN}" "${tls_measurements_file}" || true
        cloudflare_parse_tls_observations \
            "${tls_measurements_file}" >"${tls_observations_file}" || true
    fi

    cloudflare_select_carrier_candidates "${tls_observations_file}" \
        "${CLOUDFLARE_CANDIDATES_PER_CARRIER}" \
        "${CLOUDFLARE_CANDIDATE_LIMIT}" \
        "${history_candidates_tsv}" >"${preliminary_file}"

    count=$(jq 'length' "${preliminary_file}")
    if (( count < CLOUDFLARE_CANDIDATE_LIMIT )); then
        warn "Globalping HTTP/TLS 有效候选：$(jq -sr '
            [4134,4837,9808][] as $asn
            | "AS\($asn)=\([.[] | select(.carrier_asn == $asn) | .ip] | unique | length)"
        ' "${tls_observations_file}" | tr '\n' ' ')；需三网各 2 个且 IP 不重复"
        if [[ -s "${GLOBALPING_CACHE_FILE}" ]]; then
            warn "Cloudflare 官方 IP 池未选满 ${CLOUDFLARE_CANDIDATE_LIMIT} 个三网独立有效候选（实际 ${count} 个），保留现有缓存"
        else
            warn "Cloudflare 官方 IP 池未选满 ${CLOUDFLARE_CANDIDATE_LIMIT} 个三网独立有效候选（实际 ${count} 个），首次安装停止"
        fi
        return 1
    fi

    measured_at_epoch=${GLOBALPING_NOW_EPOCH:-$(date +%s)}
    measured_at=$(date -u -r "${measured_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
        || date -u -d "@${measured_at_epoch}" '+%Y-%m-%dT%H:%M:%SZ')
    jq -n --arg domain "${VLESS_CDN_DOMAIN}" \
        --arg measured_at "${measured_at}" \
        --argjson version "${CLOUDFLARE_CACHE_VERSION}" \
        --argjson measured_at_epoch "${measured_at_epoch}" \
        --argjson packets "${CLOUDFLARE_GLOBALPING_PACKET_COUNT}" \
        --argjson pool_sample_size "${pool_size}" \
        --argjson prevalidated_pool_size "${prevalidated_pool_size}" \
        --argjson measurement_count "${measurement_count}" \
        --argjson candidates "$(<"${preliminary_file}")" '{
          version:$version,
          provider:"cloudflare",
          domain:$domain,
          candidate_source:"cloudflare-official-ipv4",
          measured_at:$measured_at,
          measured_at_epoch:$measured_at_epoch,
          probe_country:"CN",
          probe_type:"eyeball-network",
          carrier_asns:[4134,4837,9808],
          protocol:"TCP+HTTPS",
          port:443,
          packets:$packets,
          pool_sample_size:$pool_sample_size,
          prevalidated_pool_size:$prevalidated_pool_size,
          measurement_count:$measurement_count,
          carriers:{
            telecom:([$candidates[] | select(.carrier=="telecom")]),
            unicom:([$candidates[] | select(.carrier=="unicom")]),
            mobile:([$candidates[] | select(.carrier=="mobile")])
          },
          candidates:$candidates
        }' >"${destination}"
}

cloudflare_globalping_cache_compatible() {
    local ip source_cidr
    [[ -s "${GLOBALPING_CACHE_FILE}" ]] || return 1
    jq -e --arg domain "${VLESS_CDN_DOMAIN}" \
        --argjson version "${CLOUDFLARE_CACHE_VERSION}" \
        --argjson packets "${CLOUDFLARE_GLOBALPING_PACKET_COUNT}" '
          .version == $version
          and .provider == "cloudflare"
          and .domain == $domain
          and .packets == $packets
          and .candidate_source == "cloudflare-official-ipv4"
          and (.measured_at_epoch | type) == "number"
          and (.candidates | type) == "array"
          and ([.candidates[].ip] | unique | length) == (.candidates | length)
          and ([.candidates[] | select(.address_family == "ipv4")] | length) == 6
          and ([.candidates[] | select(.address_family == "ipv4" and .carrier == "telecom" and .carrier_asn == 4134)] | length) == 2
          and ([.candidates[] | select(.address_family == "ipv4" and .carrier == "unicom" and .carrier_asn == 4837)] | length) == 2
          and ([.candidates[] | select(.address_family == "ipv4" and .carrier == "mobile" and .carrier_asn == 9808)] | length) == 2
          and all(.candidates[];
            (.ip | type) == "string"
            and .address_family == "ipv4"
          )
        ' "${GLOBALPING_CACHE_FILE}" >/dev/null || return 1
    while IFS=$'\t' read -r ip source_cidr; do
        validate_public_ipv4 "${ip}" || return 1
        [[ -z "${source_cidr}" ]] \
            || cloudflare_ipv4_in_cidr "${ip}" "${source_cidr}" || return 1
    done < <(jq -r '.candidates[] | [.ip, (.source_cidr // "")] | @tsv' \
        "${GLOBALPING_CACHE_FILE}")
}

globalping_cache_valid() {
    local now age
    cloudflare_globalping_cache_compatible || return 1
    now=${GLOBALPING_NOW_EPOCH:-$(date +%s)}
    age=$((now - $(jq -r '.measured_at_epoch' "${GLOBALPING_CACHE_FILE}")))
    ((age >= 0 && age <= GLOBALPING_CACHE_MAX_AGE_SECONDS))
}

refresh_globalping_cache() {
    local temp
    collect_globalping_token
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/cloudflare-cdn-ips.json.XXXXXX")
    cleanup_files+=("${temp}")
    cloudflare_build_official_pool_cache "${temp}" || return 1
    install -o root -g root -m 0600 "${temp}" "${GLOBALPING_CACHE_FILE}"
    success "Cloudflare IPv4 入口池已更新：$(jq '.candidates | length' \
        "${GLOBALPING_CACHE_FILE}") 个节点"
}

cloudflare_client_candidates() {
    if cdn_optimization_enabled && cloudflare_globalping_cache_compatible; then
        jq -r '.candidates[] | [.ip, .label, .carrier, .address_family] | @tsv' "${GLOBALPING_CACHE_FILE}"
    fi
}
