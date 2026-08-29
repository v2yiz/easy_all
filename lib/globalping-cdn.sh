#!/usr/bin/env bash

# AWS CloudFront endpoint discovery through mainland China Globalping probes.

readonly GLOBALPING_API_BASE="https://api.globalping.io/v1"
readonly GLOBALPING_TOKEN_FILE="${GLOBALPING_TOKEN_FILE_OVERRIDE:-${STATE_DIR}/globalping.token}"
readonly GLOBALPING_CACHE_FILE="${GLOBALPING_CACHE_FILE_OVERRIDE:-${STATE_DIR}/aws-cdn-ips.json}"
readonly GLOBALPING_REFRESH_SERVICE_FILE="${GLOBALPING_REFRESH_SERVICE_FILE_OVERRIDE:-/etc/systemd/system/easy_all-globalping-refresh.service}"
readonly GLOBALPING_REFRESH_TIMER_FILE="${GLOBALPING_REFRESH_TIMER_FILE_OVERRIDE:-/etc/systemd/system/easy_all-globalping-refresh.timer}"
readonly GLOBALPING_REFRESH_SERVICE="easy_all-globalping-refresh.service"
readonly GLOBALPING_REFRESH_TIMER="easy_all-globalping-refresh.timer"
readonly GLOBALPING_PACKET_COUNT=10
readonly GLOBALPING_PROBE_LIMIT=50
readonly GLOBALPING_CANDIDATE_LIMIT=10
readonly GLOBALPING_CACHE_MAX_AGE_SECONDS=259200
readonly GLOBALPING_POLL_ATTEMPTS=35

validate_aws_cdn_endpoint_mode() {
    [[ "$1" == "domain" || "$1" == "optimized" ]]
}

aws_cdn_optimization_enabled() {
    [[ "${AWS_CDN_ENDPOINT_MODE:-domain}" == "optimized" ]]
}

validate_globalping_token() {
    [[ ${#1} -ge 16 && ${#1} -le 512 && "$1" != *[[:space:]]* ]]
}

validate_public_ipv4() {
    local ip=$1 a b c d
    validate_ipv4 "${ip}" || return 1
    IFS=. read -r a b c d <<<"${ip}"
    a=$((10#${a})); b=$((10#${b})); c=$((10#${c})); d=$((10#${d}))
    ((a != 0 && a != 10 && a != 127 && a < 224)) || return 1
    ((a != 100 || b < 64 || b > 127)) || return 1
    ((a != 169 || b != 254)) || return 1
    ((a != 172 || b < 16 || b > 31)) || return 1
    ((a != 192 || b != 168)) || return 1
    ((a != 198 || b < 18 || b > 19)) || return 1
    ((a != 192 || b != 0 || c != 2)) || return 1
    ((a != 198 || b != 51 || c != 100)) || return 1
    ((a != 203 || b != 0 || c != 113)) || return 1
}

collect_globalping_token() {
    local token=${GLOBALPING_TOKEN:-}
    if [[ -z "${token}" && -s "${GLOBALPING_TOKEN_FILE}" ]]; then
        token=$(<"${GLOBALPING_TOKEN_FILE}")
    fi
    if [[ -z "${token}" ]]; then
        token=$(prompt_secret \
            "Globalping Access Token（仅保存到 VPS root-only 凭据文件）" \
            "Globalping access token (stored only in a root-only VPS credential file)") \
            || die "必须在交互终端中输入 GLOBALPING_TOKEN"
    fi
    validate_globalping_token "${token}" || die "Globalping Token 格式无效"
    GLOBALPING_TOKEN=${token}
}

persist_globalping_token() {
    local temp
    aws_cdn_optimization_enabled || return 0
    collect_globalping_token
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/globalping.token.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${GLOBALPING_TOKEN}" >"${temp}"
    install -o root -g root -m 0600 "${temp}" "${GLOBALPING_TOKEN_FILE}"
}

globalping_token_value() {
    if [[ -n "${GLOBALPING_TOKEN:-}" ]]; then
        printf '%s' "${GLOBALPING_TOKEN}"
        return 0
    fi
    [[ -s "${GLOBALPING_TOKEN_FILE}" ]] || return 1
    local token
    token=$(<"${GLOBALPING_TOKEN_FILE}")
    validate_globalping_token "${token}" || return 1
    printf '%s' "${token}"
}

globalping_measurement_request() {
    jq -cn --arg target "${VLESS_CDN_DOMAIN}" \
        --argjson packets "${GLOBALPING_PACKET_COUNT}" \
        --argjson limit "${GLOBALPING_PROBE_LIMIT}" '{
          type:"ping",
          target:$target,
          locations:[{country:"CN"}],
          limit:$limit,
          timeout:20,
          measurementOptions:{
            packets:$packets,
            protocol:"TCP",
            port:443,
            ipVersion:4
          }
        }'
}

globalping_api_request() {
    local method=$1 path=$2 body=${3:-} token headers
    token=$(globalping_token_value) || {
        warn "缺少 Globalping Token，无法刷新 AWS CDN 精选 IP"
        return 1
    }
    headers=$(make_temp_dir)/globalping-headers
    printf 'Authorization: Bearer %s\n' "${token}" >"${headers}"
    chmod 0600 "${headers}"
    if [[ "${method}" == "POST" ]]; then
        curl -fsS --connect-timeout 10 --max-time 25 \
            -X POST "${GLOBALPING_API_BASE}${path}" \
            -H "@${headers}" \
            -H 'Content-Type: application/json' \
            -H 'User-Agent: easy_all/globalping-cdn' \
            --data "${body}"
    else
        curl -fsS --connect-timeout 10 --max-time 25 \
            "${GLOBALPING_API_BASE}${path}" \
            -H "@${headers}" \
            -H 'Accept: application/json' \
            -H 'User-Agent: easy_all/globalping-cdn'
    fi
}

validate_globalping_access() {
    local limits
    limits=$(globalping_api_request GET "/limits") || return 1
    jq -e '.rateLimit.measurements.create.type == "user"' \
        <<<"${limits}" >/dev/null
}

globalping_run_measurement() {
    local created measurement_id result status attempt
    created=$(globalping_api_request POST "/measurements" \
        "$(globalping_measurement_request)") || return 1
    measurement_id=$(jq -er '.id | select(type == "string" and length > 0)' \
        <<<"${created}") || {
        warn "Globalping 未返回有效的测量 ID"
        return 1
    }

    for ((attempt = 1; attempt <= GLOBALPING_POLL_ATTEMPTS; attempt += 1)); do
        sleep 1
        result=$(globalping_api_request GET "/measurements/${measurement_id}") \
            || return 1
        status=$(jq -r '.status // empty' <<<"${result}")
        if [[ "${status}" != "in-progress" ]]; then
            [[ "${status}" == "finished" ]] || {
                warn "Globalping 测量未成功完成：${status:-未知状态}"
                return 1
            }
            printf '%s\n' "${result}"
            return 0
        fi
    done
    warn "Globalping 测量等待超过 ${GLOBALPING_POLL_ATTEMPTS} 秒"
    return 1
}

globalping_zero_loss_candidates() {
    jq -cer --argjson packets "${GLOBALPING_PACKET_COUNT}" \
        --argjson limit "${GLOBALPING_CANDIDATE_LIMIT}" '
      def ipv4:
        . as $ip
        | ($ip | type) == "string"
        and ($ip | test("^([0-9]{1,3}\\.){3}[0-9]{1,3}$"))
        and ($ip | split(".") | all(.[]; (tonumber >= 0 and tonumber <= 255)));
      [
        .results[]?
        | select(.probe.country == "CN")
        | select(.result.resolvedAddress | ipv4)
        | {
            ip:.result.resolvedAddress,
            status:.result.status,
            loss:.result.stats.loss,
            total:.result.stats.total,
            received:.result.stats.rcv,
            dropped:.result.stats.drop,
            avg_rtt_ms:.result.stats.avg,
            city:(.probe.city // ""),
            asn:(.probe.asn // 0),
            network:(.probe.network // "")
          }
      ]
      | sort_by(.ip)
      | group_by(.ip)
      | map(
          select(all(.[];
            .status == "finished"
            and .loss == 0
            and .total == $packets
            and .received == $packets
            and .dropped == 0
            and (.avg_rtt_ms | type) == "number"
          ))
          | {
              ip:.[0].ip,
              observations:length,
              avg_rtt_ms:((map(.avg_rtt_ms) | add) / length),
              cities:(map(.city) | map(select(length > 0)) | unique),
              asns:(map(.asn) | map(select(. > 0)) | unique),
              networks:(map(.network) | map(select(length > 0)) | unique)
            }
        )
      | sort_by([-.observations, .avg_rtt_ms, .ip])
      | .[0:$limit]
    ' <<<"$1"
}

validate_cloudfront_candidate() {
    local ip=$1 response
    validate_public_ipv4 "${ip}" || return 1
    response=$(curl -fsS --connect-timeout 4 --max-time 10 --noproxy '*' \
        --resolve "${VLESS_CDN_DOMAIN}:443:${ip}" \
        "https://${VLESS_CDN_DOMAIN}/easy_all-health" 2>/dev/null) || return 1
    [[ "${response}" == "easy_all ok" ]]
}

globalping_build_cache() {
    local measurement=$1 destination=$2 measurement_id measured_at measured_at_epoch
    local candidates_file candidate validated_file validation_dir part count index=0
    candidates_file=$(make_temp_dir)/candidates.json
    validated_file=$(make_temp_dir)/validated.ndjson
    validation_dir=$(make_temp_dir)
    : >"${validated_file}"
    globalping_zero_loss_candidates "${measurement}" >"${candidates_file}" \
        || return 1

    while IFS= read -r candidate; do
        index=$((index + 1))
        (
            validate_cloudfront_candidate "$(jq -r '.ip' <<<"${candidate}")" \
                && printf '%s\n' "${candidate}" >"${validation_dir}/${index}.json"
            true
        ) &
    done < <(jq -c '.[]' "${candidates_file}")
    wait
    for part in "${validation_dir}"/*.json; do
        [[ -f "${part}" ]] || continue
        cat "${part}" >>"${validated_file}"
    done

    count=$(wc -l <"${validated_file}" | tr -d ' ')
    ((count > 0)) || {
        warn "Globalping 没有返回通过 CloudFront 健康复核的零丢包 IPv4"
        return 1
    }
    measurement_id=$(jq -r '.id' <<<"${measurement}")
    measured_at=$(jq -r '.updatedAt // .createdAt // empty' <<<"${measurement}")
    measured_at_epoch=${GLOBALPING_NOW_EPOCH:-$(date +%s)}
    jq -n --arg domain "${VLESS_CDN_DOMAIN}" \
        --arg measurement_id "${measurement_id}" \
        --arg measured_at "${measured_at}" \
        --argjson measured_at_epoch "${measured_at_epoch}" \
        --argjson packets "${GLOBALPING_PACKET_COUNT}" \
        --argjson candidates \
            "$(jq -s --argjson limit "${GLOBALPING_CANDIDATE_LIMIT}" \
                'sort_by([-.observations, .avg_rtt_ms, .ip]) | .[0:$limit]' \
                "${validated_file}")" '{
          version:1,
          domain:$domain,
          measurement_id:$measurement_id,
          measured_at:$measured_at,
          measured_at_epoch:$measured_at_epoch,
          probe_country:"CN",
          protocol:"TCP",
          port:443,
          packets:$packets,
          candidates:$candidates
        }' >"${destination}"
}

globalping_cache_valid() {
    local now age ip
    [[ -s "${GLOBALPING_CACHE_FILE}" ]] || return 1
    jq -e --arg domain "${VLESS_CDN_DOMAIN}" \
        --argjson limit "${GLOBALPING_CANDIDATE_LIMIT}" '
          .version == 1
          and .domain == $domain
          and (.measured_at_epoch | type) == "number"
          and (.candidates | type) == "array"
          and (.candidates | length) > 0
          and (.candidates | length) <= $limit
          and all(.candidates[];
            (.ip | type) == "string"
            and (.observations | type) == "number"
            and (.avg_rtt_ms | type) == "number"
          )
        ' "${GLOBALPING_CACHE_FILE}" >/dev/null || return 1
    while IFS= read -r ip; do
        validate_public_ipv4 "${ip}" || return 1
    done < <(jq -r '.candidates[].ip' "${GLOBALPING_CACHE_FILE}")
    now=${GLOBALPING_NOW_EPOCH:-$(date +%s)}
    age=$((now - $(jq -r '.measured_at_epoch' "${GLOBALPING_CACHE_FILE}")))
    ((age >= 0 && age <= GLOBALPING_CACHE_MAX_AGE_SECONDS))
}

aws_cdn_client_endpoints() {
    if aws_cdn_optimization_enabled && globalping_cache_valid; then
        jq -r '.candidates[].ip' "${GLOBALPING_CACHE_FILE}"
    else
        printf '%s\n' "${VLESS_CDN_DOMAIN}"
    fi
}

refresh_globalping_cache() {
    local measurement temp
    collect_globalping_token
    measurement=$(globalping_run_measurement) || return 1
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/aws-cdn-ips.json.XXXXXX")
    cleanup_files+=("${temp}")
    globalping_build_cache "${measurement}" "${temp}" || return 1
    install -o root -g root -m 0600 "${temp}" "${GLOBALPING_CACHE_FILE}"
    success "Globalping 已更新 $(jq '.candidates | length' "${GLOBALPING_CACHE_FILE}") 个 AWS CDN 精选 IPv4"
}

install_globalping_refresh_timer() {
    if ! aws_cdn_optimization_enabled; then
        remove_globalping_refresh_timer
        return 0
    fi
    cat >"${RUNTIME_TMP}/easy_all-globalping-refresh.service" <<EOF
[Unit]
Description=Refresh easy_all AWS CDN endpoints with Globalping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} refresh-cdn-ips
EOF
    cat >"${RUNTIME_TMP}/easy_all-globalping-refresh.timer" <<EOF
[Unit]
Description=Refresh easy_all AWS CDN endpoints every six hours

[Timer]
OnBootSec=6h
OnUnitActiveSec=6h
Unit=${GLOBALPING_REFRESH_SERVICE}

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-globalping-refresh.service" \
        "${GLOBALPING_REFRESH_SERVICE_FILE}"
    install -m 0644 "${RUNTIME_TMP}/easy_all-globalping-refresh.timer" \
        "${GLOBALPING_REFRESH_TIMER_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${GLOBALPING_REFRESH_TIMER}" >/dev/null \
        || die "启用 Globalping 六小时刷新定时器失败"
}

remove_globalping_refresh_timer() {
    systemctl disable --now "${GLOBALPING_REFRESH_TIMER}" >/dev/null 2>&1 || true
    systemctl stop "${GLOBALPING_REFRESH_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${GLOBALPING_REFRESH_SERVICE_FILE}" "${GLOBALPING_REFRESH_TIMER_FILE}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

show_globalping_status() {
    if ! aws_cdn_optimization_enabled; then
        printf 'AWS CDN 精选 IP: disabled\n'
        return 0
    fi
    if globalping_cache_valid; then
        printf 'AWS CDN 精选 IP: enabled，%s 个，最近成功刷新 %s\n' \
            "$(jq '.candidates | length' "${GLOBALPING_CACHE_FILE}")" \
            "$(jq -r '.measured_at // "未知"' "${GLOBALPING_CACHE_FILE}")"
    else
        printf 'AWS CDN 精选 IP: 缓存缺失或超过 72 小时，当前回退 CDN 域名\n'
    fi
    printf 'Globalping 定时器: '
    systemctl is-active --quiet "${GLOBALPING_REFRESH_TIMER}" \
        && printf 'active\n' || printf 'inactive\n'
}
