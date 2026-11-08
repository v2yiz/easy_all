#!/usr/bin/env bash

# CloudFront-only CDN traffic protection.
#
# The guard owns one file (cdn-traffic-usage.json) and one systemd timer. It
# meters only the `vless-xhttp-in` inbound, never Reality, and converges the
# persisted desired state (`blocked`) into the applied state (`enforced`).
# protection_offline marks a persisted intent to stop the runtime when the
# restricted rebuild could not terminate existing CDN sessions.

readonly CDN_TRAFFIC_GUARD_USAGE_FILE="${STATE_DIR}/cdn-traffic-usage.json"
readonly CDN_TRAFFIC_GUARD_SERVICE_FILE="/etc/systemd/system/easy_all-cdn-traffic-guard.service"
readonly CDN_TRAFFIC_GUARD_TIMER_FILE="/etc/systemd/system/easy_all-cdn-traffic-guard.timer"
readonly CDN_TRAFFIC_GUARD_SERVICE="easy_all-cdn-traffic-guard.service"
readonly CDN_TRAFFIC_GUARD_TIMER="easy_all-cdn-traffic-guard.timer"
readonly DEFAULT_CDN_TRAFFIC_PROTECTION_GB="985"
readonly CDN_TRAFFIC_XHTTP_INBOUND="vless-xhttp-in"
readonly CDN_TRAFFIC_API_LISTEN="127.0.0.1:10085"
CDN_TRAFFIC_KEEP_BLOCKED=0

validate_cdn_traffic_protection_gb() {
    [[ "$1" == "${DEFAULT_CDN_TRAFFIC_PROTECTION_GB}" ]]
}

configure_cdn_traffic_protection() {
    if [[ -z "${CDN_TRAFFIC_PROTECTION_GB:-}" || "${CDN_TRAFFIC_PROTECTION_GB}" == "0" ]]; then
        CDN_TRAFFIC_PROTECTION_GB=${DEFAULT_CDN_TRAFFIC_PROTECTION_GB}
    fi
    validate_cdn_traffic_protection_gb "${CDN_TRAFFIC_PROTECTION_GB}" \
        || die "CloudFront 全局费用保护额度固定为 ${DEFAULT_CDN_TRAFFIC_PROTECTION_GB} GB"
}

cdn_traffic_protection_enabled() {
    [[ "${CDN_PROVIDER:-}" == "aws" ]] || return 1
    case "${PROTOCOL:-}" in
    cloudfront | combined-cloudfront) ;;
    *) return 1 ;;
    esac
    [[ "${CDN_TRAFFIC_PROTECTION_GB:-}" == "${DEFAULT_CDN_TRAFFIC_PROTECTION_GB}" ]]
}

cdn_traffic_provider_label() {
    printf 'CloudFront'
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

# Reads and normalizes the usage file. A legal legacy seven-field file is read
# as protection_offline=false; everything else that violates the whitelist or
# the offline invariant is corrupt. Never creates or resets a file.
cdn_traffic_read_usage() {
    [[ -s "${CDN_TRAFFIC_GUARD_USAGE_FILE}" ]] || return 1
    cdn_traffic_read_usage_from "$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
}

cdn_traffic_write_usage() {
    local usage=$1 temp
    local normalized
    normalized=$(cdn_traffic_read_usage_from "${usage}") || return 1
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/cdn-traffic-usage.json.XXXXXX") || return 1
    cleanup_files+=("${temp}")
    printf '%s\n' "${normalized}" >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
}

# Same normalization as cdn_traffic_read_usage but for a supplied document.
cdn_traffic_read_usage_from() {
    local usage=$1 normalized
    validate_cdn_traffic_usage "${usage}" || return 1
    normalized=$(jq -c '
        if has("protection_offline") then . else . + {protection_offline:false} end
    ' <<<"${usage}") || return 1
    jq -e '
        (.protection_offline|type == "boolean") and
        ((.protection_offline|not) or (.blocked == true and .enforced == false)) and
        ((keys | sort) == (["period","runtime_id","used_bytes","last_uplink","last_downlink","blocked","enforced","protection_offline"] | sort))
    ' <<<"${normalized}" >/dev/null || return 1
    printf '%s\n' "${normalized}"
}

cdn_traffic_require_usage() {
    local usage
    usage=$(cdn_traffic_read_usage) \
        || die "CDN 全局费用保护统计文件缺失或损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}；保护异常，请修复后重试（不会自动清零）"
    printf '%s\n' "${usage}"
}

initialize_cdn_traffic_usage() {
    local period
    cdn_traffic_protection_enabled || return 0
    install -d -m 0700 "${STATE_DIR}"
    if [[ -e "${CDN_TRAFFIC_GUARD_USAGE_FILE}" ]]; then
        cdn_traffic_read_usage >/dev/null \
            || die "CloudFront 全局费用保护统计文件损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        return 0
    fi
    period=$(cdn_traffic_current_period)
    cdn_traffic_write_usage "$(jq -cn --arg period "${period}" '
        {period:$period,runtime_id:"",used_bytes:0,
         last_uplink:0,last_downlink:0,blocked:false,enforced:false,
         protection_offline:false}')"
}

cdn_traffic_needs_restricted_recovery() {
    local usage
    usage=$(cdn_traffic_read_usage) || return 2
    jq -e '.blocked == true and .enforced == false' <<<"${usage}" >/dev/null
}

cdn_traffic_mark_enforced() {
    local usage
    cdn_traffic_protection_enabled || return 0
    usage=$(cdn_traffic_require_usage) || return 1
    usage=$(jq -c '.enforced=.blocked | if .blocked then . else .protection_offline=false end' <<<"${usage}")
    cdn_traffic_write_usage "${usage}"
}

cdn_traffic_mark_protection_offline() {
    local usage
    usage=$(cdn_traffic_read_usage) || return 1
    usage=$(jq -c '.blocked=true | .enforced=false | .protection_offline=true' <<<"${usage}")
    cdn_traffic_write_usage "${usage}"
}

cdn_traffic_mark_restricted_recovered() {
    local usage
    usage=$(cdn_traffic_read_usage) || return 1
    usage=$(jq -c '.blocked=true | .enforced=true | .protection_offline=false' <<<"${usage}")
    cdn_traffic_write_usage "${usage}"
}

cdn_traffic_stats_totals() {
    jq -er --arg inbound "${CDN_TRAFFIC_XHTTP_INBOUND}" '
        def counter($direction):
            [.stat[]? | select(.name == ("inbound>>>" + $inbound + ">>>traffic>>>" + $direction)) | .value];
        (counter("uplink")) as $up
        | (counter("downlink")) as $down
        | if (($up | length) == 0 or ($down | length) == 0
              or any(($up + $down)[]; (type != "number") or (. != floor) or (. < 0)))
          then error("缺少或损坏 CDN 入站计数")
          else "\($up | add)\t\($down | add)"
          end
    ' <<<"$1"
}

install_cdn_traffic_protection_timer() {
    if ! cdn_traffic_protection_enabled; then
        remove_cdn_traffic_protection_timer
        return 0
    fi
    cdn_traffic_read_usage >/dev/null \
        || die "CDN 全局费用保护统计文件缺失或损坏；拒绝安装定时器"
    cat >"${RUNTIME_TMP}/easy_all-cdn-traffic-guard.service" <<EOF
[Unit]
Description=easy_all CloudFront global traffic protection
After=${XRAY_SERVICE}

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} $(cdn_traffic_sync_command)
EOF
    cat >"${RUNTIME_TMP}/easy_all-cdn-traffic-guard.timer" <<EOF
[Unit]
Description=Check easy_all CloudFront traffic protection every 15 seconds

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
        || die "启用 CloudFront 全局费用保护定时器失败"
    systemctl is-active --quiet "${CDN_TRAFFIC_GUARD_TIMER}" \
        || die "CloudFront 全局费用保护定时器未处于 active 状态"
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
    local current_up current_down old_up old_down delta_up delta_down used blocked old_blocked
    local enforced offline threshold
    usage=$(cdn_traffic_require_usage) || return 1
    period=$(cdn_traffic_current_period)
    runtime_id=$(systemctl show "${XRAY_SERVICE}" -p InvocationID --value 2>/dev/null || true)
    stats=$("${XRAY_BIN}" api statsquery --server="${CDN_TRAFFIC_API_LISTEN}") \
        || { warn "读取 Xray CDN 入站统计失败；保留现有保护状态"; return 1; }
    IFS=$'\t' read -r current_up current_down \
        <<<"$(cdn_traffic_stats_totals "${stats}")" \
        || { warn "Xray 统计响应缺少 CDN 入站计数；保留现有保护状态"; return 1; }
    [[ "${current_up}" =~ ^[0-9]+$ && "${current_down}" =~ ^[0-9]+$ ]] \
        || { warn "Xray 统计响应不是非负整数；保留现有保护状态"; return 1; }
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
        # overcounts by at most one polling interval instead of risking an
        # unmetered gap at the AWS billing boundary.
        used=$((delta_up + delta_down))
    fi
    threshold=$((CDN_TRAFFIC_PROTECTION_GB * 1000 * 1000 * 1000))
    old_blocked=$(jq -r '.blocked' <<<"${usage}")
    enforced=$(jq -r '.enforced' <<<"${usage}")
    offline=$(jq -r '.protection_offline' <<<"${usage}")
    blocked=false
    ((used >= threshold)) && blocked=true
    # 订阅未就绪或已有阻断时不得解封：desired 状态继续保持在受限一侧。
    [[ "${CDN_TRAFFIC_KEEP_BLOCKED:-0}" != "1" ]] || blocked=true
    [[ "${blocked}" == "true" ]] || offline=false

    cdn_traffic_write_usage "$(jq -cn --arg period "${period}" --arg runtime_id "${runtime_id}" \
        --argjson used "${used}" --argjson up "${current_up}" \
        --argjson down "${current_down}" --argjson blocked "${blocked}" \
        --argjson enforced "${enforced}" --argjson offline "${offline}" '
        {period:$period,runtime_id:$runtime_id,used_bytes:$used,
         last_uplink:$up,last_downlink:$down,blocked:$blocked,enforced:$enforced,
         protection_offline:$offline}')" || return 1

    CDN_TRAFFIC_OLD_BLOCKED=${old_blocked}
    CDN_TRAFFIC_BLOCKED=${blocked}
    CDN_TRAFFIC_TRANSITION=0
    [[ "${blocked}" == "${old_blocked}" ]] || CDN_TRAFFIC_TRANSITION=1
    CDN_TRAFFIC_NEEDS_APPLY=0
    [[ "${blocked}" == "${enforced}" ]] || CDN_TRAFFIC_NEEDS_APPLY=1
}

cdn_traffic_probe_stats() {
    local stats
    stats=$("${XRAY_BIN}" api statsquery --server="${CDN_TRAFFIC_API_LISTEN}" 2>/dev/null) || return 1
    local up down
    IFS=$'\t' read -r up down <<<"$(cdn_traffic_stats_totals "${stats}")" || return 1
    [[ "${up}" =~ ^[0-9]+$ && "${down}" =~ ^[0-9]+$ ]]
}

cdn_traffic_protection_checkpoint() {
    cdn_traffic_protection_enabled || return 0
    try_acquire_runtime_write_lock || return 0
    if ! cdn_traffic_read_usage >/dev/null; then
        release_runtime_write_lock
        warn "CDN 流量保护统计缺失或损坏；未执行 checkpoint"
        return 1
    fi
    cdn_traffic_update_usage || { release_runtime_write_lock; return 1; }
    release_runtime_write_lock
    if [[ "${CDN_TRAFFIC_NEEDS_APPLY:-0}" == "1" ]]; then
        warn "checkpoint 已产生待落实的 CDN 阻断状态；请先运行 sudo easy_all cdn-traffic-sync"
        return 1
    fi
}

cdn_traffic_subscription_ready() {
    declare -F cdn_subscription_ready >/dev/null 2>&1 || return 0
    cdn_subscription_ready
}

# 已有阻断且订阅未就绪：/subscribe 必须降级为 503，不得继续提供旧产物。
cdn_traffic_deny_subscription_runtime() {
    declare -F cdn_deny_subscription_runtime >/dev/null 2>&1 || return 0
    cdn_deny_subscription_runtime
}

cdn_traffic_protection_sync() {
    local subscription_ready=1 usage
    require_root
    if ! try_acquire_runtime_write_lock; then
        info "运行时写锁正被占用；本轮跳过 CDN 流量同步"
        return 0
    fi
    collect_installed_state || { release_runtime_write_lock; return 1; }
    if ! cdn_traffic_protection_enabled; then
        release_runtime_write_lock
        return 0
    fi
    if ! usage=$(cdn_traffic_read_usage); then
        warn "CDN 全局费用保护统计文件缺失或损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}；不会自动清零"
        release_runtime_write_lock
        return 1
    fi

    # 统一准入：只有 blocked=true 且 enforced=false 才是待落实阻断。
    if jq -e '.blocked == true and .enforced == false' <<<"${usage}" >/dev/null; then
        warn "检测到 CDN 保护待落实（blocked=true, enforced=false）；先执行受限安全恢复"
        if ! (cdn_traffic_recover_restricted_runtime); then
            warn "受限安全恢复失败；保留保护待落实状态并等待下一轮重试"
            release_runtime_write_lock
            return 1
        fi
        usage=$(cdn_traffic_read_usage) || { release_runtime_write_lock; return 1; }
    fi

    cdn_traffic_subscription_ready || subscription_ready=0
    CDN_TRAFFIC_KEEP_BLOCKED=0
    # 实际仍在受限运行时的两种状态都必须保持阻断：已完成阻断（blocked）与解封 pending
    # （blocked=false/enforced=true）。订阅未就绪时既不重建开放配置，也不提供旧产物。
    if [[ "${subscription_ready}" == "0" ]] \
        && jq -e '.blocked == true or .enforced == true' <<<"${usage}" >/dev/null; then
        CDN_TRAFFIC_KEEP_BLOCKED=1
        cdn_traffic_deny_subscription_runtime \
            || warn "无法安装订阅 503 的降级配置；旧订阅产物可能仍可下载"
    fi

    if ! cdn_traffic_update_usage; then
        release_runtime_write_lock
        return 1
    fi

    if [[ "${CDN_TRAFFIC_NEEDS_APPLY}" == "1" ]]; then
        if ! (rebuild_traffic_runtime); then
            warn "应用 CloudFront 全局费用保护状态失败；保留待落实状态并等待下一轮重试"
            release_runtime_write_lock
            return 1
        fi
        if ! cdn_traffic_mark_enforced; then
            warn "无法落盘 CloudFront 保护已落实状态；下一轮将重试"
            release_runtime_write_lock
            return 1
        fi
    fi
    if [[ "${CDN_TRAFFIC_BLOCKED}" == "true" \
        && "${CDN_TRAFFIC_OLD_BLOCKED}" != "true" ]]; then
        printf 'CloudFront 全局费用保护已达到 %s GB，CDN 节点已阻断\n' \
            "${CDN_TRAFFIC_PROTECTION_GB}"
    elif [[ "${CDN_TRAFFIC_BLOCKED}" == "false" \
        && "${CDN_TRAFFIC_OLD_BLOCKED}" == "true" ]]; then
        printf 'CloudFront 已进入新的 UTC 自然月，CDN 节点已恢复\n'
    fi
    release_runtime_write_lock
    if [[ "${subscription_ready}" == "0" ]]; then
        warn "订阅未就绪（配置或验收失败）；禁止解封，请执行 sudo easy_all edit-sub"
        return 1
    fi
    return 0
}

show_cdn_traffic_protection_status() {
    local usage used remaining
    if ! cdn_traffic_protection_enabled; then
        printf 'CloudFront 全局费用保护: disabled\n'
        return 0
    fi
    if ! usage=$(cdn_traffic_read_usage); then
        printf 'CloudFront 全局费用保护: 异常（统计文件缺失或损坏：%s）\n' \
            "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        return 0
    fi
    used=$(jq -r '.used_bytes' <<<"${usage}")
    remaining=$((CDN_TRAFFIC_PROTECTION_GB * 1000 * 1000 * 1000 - used))
    ((remaining >= 0)) || remaining=0
    printf 'CloudFront 全局费用保护: enabled（UTC 自然月 %s，阈值 %s GB）\n' \
        "$(jq -r '.period' <<<"${usage}")" "${CDN_TRAFFIC_PROTECTION_GB}"
    printf '  已统计: %.3f GB，剩余保护空间: %.3f GB，blocked=%s，enforced=%s，protection_offline=%s\n' \
        "$(awk -v bytes="${used}" 'BEGIN{print bytes/1000000000}')" \
        "$(awk -v bytes="${remaining}" 'BEGIN{print bytes/1000000000}')" \
        "$(jq -r '.blocked' <<<"${usage}")" \
        "$(jq -r '.enforced' <<<"${usage}")" \
        "$(jq -r '.protection_offline' <<<"${usage}")"
}
