#!/usr/bin/env bash

# Provider-neutral XHTTP CDN global traffic safety guard.

readonly CDN_TRAFFIC_GUARD_USAGE_FILE="${STATE_DIR}/cdn-traffic-usage.json"
readonly CDN_TRAFFIC_GUARD_SERVICE_FILE="/etc/systemd/system/easy_all-cdn-traffic-guard.service"
readonly CDN_TRAFFIC_GUARD_TIMER_FILE="/etc/systemd/system/easy_all-cdn-traffic-guard.timer"
readonly CDN_TRAFFIC_GUARD_SERVICE="easy_all-cdn-traffic-guard.service"
readonly CDN_TRAFFIC_GUARD_TIMER="easy_all-cdn-traffic-guard.timer"
readonly DEFAULT_CDN_TRAFFIC_PROTECTION_GB="980"

validate_cdn_traffic_protection_gb() {
    [[ "$1" =~ ^[0-9]+$ && ${#1} -le 4 ]] \
        && ((10#$1 >= 1 && 10#$1 <= 1000))
}

configure_cdn_traffic_protection() {
    if [[ "${CDN_PROVIDER:-}" == "gcore" \
        || "${AWS_CLOUDFRONT_BILLING_MODE:-}" == "payg" ]]; then
        if [[ -z "${CDN_TRAFFIC_PROTECTION_GB:-}" \
            || "${CDN_TRAFFIC_PROTECTION_GB}" == "0" ]]; then
            CDN_TRAFFIC_PROTECTION_GB=${DEFAULT_CDN_TRAFFIC_PROTECTION_GB}
        fi
        validate_cdn_traffic_protection_gb "${CDN_TRAFFIC_PROTECTION_GB}" \
            || die "CDN 全局费用保护额度必须是 1-1000 的整数 GB"
        CDN_TRAFFIC_PROTECTION_GB=$((10#${CDN_TRAFFIC_PROTECTION_GB}))
        [[ "${CDN_TRAFFIC_PROTECTION_GB}" == "${DEFAULT_CDN_TRAFFIC_PROTECTION_GB}" ]] \
            || die "CDN 全局费用保护额度固定为 ${DEFAULT_CDN_TRAFFIC_PROTECTION_GB} GB"
    else
        CDN_TRAFFIC_PROTECTION_GB=0
    fi
}

cdn_traffic_protection_enabled() {
    [[ "${PROTOCOL:-}" == "xhttp" \
        && ( "${CDN_PROVIDER:-}" == "gcore" \
            || "${AWS_CLOUDFRONT_BILLING_MODE:-}" == "payg" ) \
        && "${CDN_TRAFFIC_PROTECTION_GB:-0}" =~ ^[0-9]+$ ]] \
        && ((10#${CDN_TRAFFIC_PROTECTION_GB:-0} > 0))
}

cdn_traffic_provider_label() {
    [[ "${CDN_PROVIDER:-}" == "gcore" ]] && printf 'Gcore' || printf 'CloudFront'
}

cdn_traffic_sync_command() {
    printf 'cdn-traffic-sync'
}

cdn_traffic_current_period() {
    local value=${1:-}
    if [[ -z "${value}" ]]; then
        date -u +%Y-%m
    elif [[ "${value}" =~ ^[0-9]{4}-(0[1-9]|1[0-2])(-[0-9]{2})?$ ]]; then
        printf '%s\n' "${value:0:7}"
    else
        return 1
    fi
}

validate_cdn_traffic_usage() {
    jq -e '
        type == "object" and
        (.period|type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])$")) and
        (.runtime_id|type == "string") and
        (.used_bytes|type == "number" and floor == . and . >= 0) and
        (.last_uplink|type == "number" and floor == . and . >= 0) and
        (.last_downlink|type == "number" and floor == . and . >= 0) and
        (.blocked|type == "boolean") and
        (.enforced|type == "boolean")
    ' <<<"$1" >/dev/null
}

initialize_cdn_traffic_usage() {
    local period usage
    cdn_traffic_protection_enabled || return 0
    period=$(cdn_traffic_current_period)
    install -d -m 0700 "${STATE_DIR}"
    if [[ -s "${CDN_TRAFFIC_GUARD_USAGE_FILE}" ]]; then
        usage=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
        validate_cdn_traffic_usage "${usage}" \
            || die "$(cdn_traffic_provider_label) 全局费用保护统计文件损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        return 0
    fi
    jq -n --arg period "${period}" '
        {period:$period,runtime_id:"",used_bytes:0,
         last_uplink:0,last_downlink:0,blocked:false,enforced:false}' \
        >"${RUNTIME_TMP}/cdn-traffic-usage.json"
    install -m 0600 "${RUNTIME_TMP}/cdn-traffic-usage.json" \
        "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
}

cdn_traffic_protection_blocked() {
    local usage
    cdn_traffic_protection_enabled || return 1
    [[ -s "${CDN_TRAFFIC_GUARD_USAGE_FILE}" ]] || return 1
    usage=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
    validate_cdn_traffic_usage "${usage}" \
        || die "$(cdn_traffic_provider_label) 全局费用保护统计文件损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}"
    jq -e '.blocked == true' <<<"${usage}" >/dev/null
}

cdn_traffic_protection_needs_apply() {
    local usage
    cdn_traffic_protection_enabled || return 1
    [[ -s "${CDN_TRAFFIC_GUARD_USAGE_FILE}" ]] || return 1
    usage=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
    validate_cdn_traffic_usage "${usage}" \
        || die "$(cdn_traffic_provider_label) 全局费用保护统计文件损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}"
    jq -e '.blocked != .enforced' <<<"${usage}" >/dev/null
}

cdn_traffic_mark_enforced() {
    local usage temp
    cdn_traffic_protection_enabled || return 0
    initialize_cdn_traffic_usage
    usage=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
    usage=$(jq -c '.enforced=.blocked' <<<"${usage}")
    temp=$(mktemp "${STATE_DIR}/cdn-traffic-enforced.json.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${usage}" >"${temp}"
    install -m 0600 "${temp}" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
}

cdn_traffic_stats_totals() {
    jq -r '
        ([.stat[]? |
          select(.name|startswith("user>>>")) |
          select(.name|endswith(">>>traffic>>>uplink")) |
          .value] | add // 0) as $uplink |
        ([.stat[]? |
          select(.name|startswith("user>>>")) |
          select(.name|endswith(">>>traffic>>>downlink")) |
          .value] | add // 0) as $downlink |
        [$uplink,$downlink] | @tsv
    ' <<<"$1"
}

install_cdn_traffic_protection_timer() {
    if ! cdn_traffic_protection_enabled; then
        remove_cdn_traffic_protection_timer
        return 0
    fi
    initialize_cdn_traffic_usage
    cat >"${RUNTIME_TMP}/easy_all-cdn-traffic-guard.service" <<EOF
[Unit]
Description=easy_all $(cdn_traffic_provider_label) global traffic protection
After=${XRAY_SERVICE}

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} $(cdn_traffic_sync_command)
EOF
    cat >"${RUNTIME_TMP}/easy_all-cdn-traffic-guard.timer" <<EOF
[Unit]
Description=Check easy_all $(cdn_traffic_provider_label) traffic protection every 15 seconds

[Timer]
OnBootSec=15s
OnUnitActiveSec=15s
AccuracySec=1s
Unit=easy_all-cdn-traffic-guard.service

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-cdn-traffic-guard.service" \
        "${CDN_TRAFFIC_GUARD_SERVICE_FILE}"
    install -m 0644 "${RUNTIME_TMP}/easy_all-cdn-traffic-guard.timer" \
        "${CDN_TRAFFIC_GUARD_TIMER_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${CDN_TRAFFIC_GUARD_TIMER}" >/dev/null \
        || die "启用 $(cdn_traffic_provider_label) 全局费用保护定时器失败"
}

remove_cdn_traffic_protection_timer() {
    systemctl disable --now "${CDN_TRAFFIC_GUARD_TIMER}" >/dev/null 2>&1 || true
    systemctl stop "${CDN_TRAFFIC_GUARD_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${CDN_TRAFFIC_GUARD_SERVICE_FILE}" "${CDN_TRAFFIC_GUARD_TIMER_FILE}"
    command -v systemctl >/dev/null 2>&1 \
        && systemctl daemon-reload >/dev/null 2>&1 || true
}

cdn_traffic_update_usage() {
    local period stats usage runtime_id previous_runtime_id
    local current_up current_down old_up old_down delta_up delta_down used blocked old_blocked enforced
    local threshold temp
    initialize_cdn_traffic_usage
    usage=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
    period=$(cdn_traffic_current_period)
    runtime_id=$(systemctl show "${XRAY_SERVICE}" -p InvocationID --value 2>/dev/null || true)
    stats=$("${XRAY_BIN}" api statsquery --server="${QUOTA_API_LISTEN}") \
        || die "读取 Xray 全局流量统计失败"
    IFS=$'\t' read -r current_up current_down \
        <<<"$(cdn_traffic_stats_totals "${stats}")"
    old_up=$(jq -r '.last_uplink' <<<"${usage}")
    old_down=$(jq -r '.last_downlink' <<<"${usage}")
    previous_runtime_id=$(jq -r '.runtime_id' <<<"${usage}")

    if [[ -n "${runtime_id}" && "${runtime_id}" != "${previous_runtime_id}" ]]; then
        delta_up=${current_up}
        delta_down=${current_down}
    else
        ((current_up >= old_up)) && delta_up=$((current_up - old_up)) || delta_up=${current_up}
        ((current_down >= old_down)) \
            && delta_down=$((current_down - old_down)) || delta_down=${current_down}
    fi

    if [[ "$(jq -r '.period' <<<"${usage}")" == "${period}" ]]; then
        used=$(jq -r '.used_bytes' <<<"${usage}")
        used=$((used + delta_up + delta_down))
    else
        # Assign the complete interval crossing 00:00 UTC to the new month. This
        # intentionally overcounts by at most one polling interval rather than
        # risking an unmetered gap at the AWS billing boundary.
        used=$((delta_up + delta_down))
    fi
    threshold=$((CDN_TRAFFIC_PROTECTION_GB * 1000 * 1000 * 1000))
    old_blocked=$(jq -r '.blocked' <<<"${usage}")
    enforced=$(jq -r '.enforced' <<<"${usage}")
    blocked=false
    ((used >= threshold)) && blocked=true

    usage=$(jq -cn --arg period "${period}" --arg runtime_id "${runtime_id}" \
        --argjson used "${used}" --argjson up "${current_up}" \
        --argjson down "${current_down}" --argjson blocked "${blocked}" \
        --argjson enforced "${enforced}" '
        {period:$period,runtime_id:$runtime_id,used_bytes:$used,
         last_uplink:$up,last_downlink:$down,blocked:$blocked,enforced:$enforced}')
    temp=$(mktemp "${STATE_DIR}/cdn-traffic-usage.json.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${usage}" >"${temp}"
    install -m 0600 "${temp}" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"

    CDN_TRAFFIC_OLD_BLOCKED=${old_blocked}
    CDN_TRAFFIC_BLOCKED=${blocked}
    CDN_TRAFFIC_TRANSITION=0
    [[ "${blocked}" == "${old_blocked}" ]] || CDN_TRAFFIC_TRANSITION=1
    CDN_TRAFFIC_NEEDS_APPLY=0
    [[ "${blocked}" == "${enforced}" ]] || CDN_TRAFFIC_NEEDS_APPLY=1
}

cdn_traffic_protection_checkpoint() {
    cdn_traffic_protection_enabled || return 0
    try_acquire_runtime_write_lock || return 0
    initialize_cdn_traffic_usage
    cdn_traffic_update_usage
    release_runtime_write_lock
}

cdn_traffic_protection_sync() {
    require_root
    try_acquire_runtime_write_lock || return 0
    collect_installed_state
    if ! cdn_traffic_protection_enabled; then
        release_runtime_write_lock
        return 0
    fi
    initialize_cdn_traffic_usage
    cdn_traffic_update_usage

    if [[ "${CDN_TRAFFIC_NEEDS_APPLY}" == "1" ]] \
        && ! (rebuild_traffic_runtime); then
        release_runtime_write_lock
        die "应用 $(cdn_traffic_provider_label) 全局费用保护状态失败；已保留待执行状态并将在下次重试"
    fi
    [[ "${CDN_TRAFFIC_NEEDS_APPLY}" != "1" ]] || cdn_traffic_mark_enforced
    if [[ "${CDN_TRAFFIC_BLOCKED}" == "true" \
        && "${CDN_TRAFFIC_OLD_BLOCKED}" != "true" ]]; then
        printf '%s 全局费用保护已达到 %s GB，XHTTP 节点已阻断\n' \
            "$(cdn_traffic_provider_label)" \
            "${CDN_TRAFFIC_PROTECTION_GB}"
    elif [[ "${CDN_TRAFFIC_BLOCKED}" == "false" \
        && "${CDN_TRAFFIC_OLD_BLOCKED}" == "true" ]]; then
        printf '%s 已进入新的 UTC 自然月，XHTTP 节点已恢复\n' "$(cdn_traffic_provider_label)"
    fi
    release_runtime_write_lock
}

show_cdn_traffic_protection_status() {
    local usage used remaining
    if ! cdn_traffic_protection_enabled; then
        printf '%s 全局费用保护: disabled（仅 AWS 按量付费或 Gcore Free CDN 启用）\n' \
            "$(cdn_traffic_provider_label)"
        return 0
    fi
    initialize_cdn_traffic_usage
    usage=$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")
    used=$(jq -r '.used_bytes' <<<"${usage}")
    remaining=$((CDN_TRAFFIC_PROTECTION_GB * 1000 * 1000 * 1000 - used))
    ((remaining >= 0)) || remaining=0
    printf '%s 全局费用保护: enabled（UTC 自然月 %s，阈值 %s GB）\n' \
        "$(cdn_traffic_provider_label)" "$(jq -r '.period' <<<"${usage}")" \
        "${CDN_TRAFFIC_PROTECTION_GB}"
    printf '  已统计: %.3f GB，剩余保护空间: %.3f GB，blocked=%s，enforced=%s\n' \
        "$(awk -v bytes="${used}" 'BEGIN{print bytes/1000000000}')" \
        "$(awk -v bytes="${remaining}" 'BEGIN{print bytes/1000000000}')" \
        "$(jq -r '.blocked' <<<"${usage}")" \
        "$(jq -r '.enforced' <<<"${usage}")"
}
