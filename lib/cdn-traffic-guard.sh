#!/usr/bin/env bash

# CloudFront 985GB 近似保护：mangle 双向计数 + 保护状态机（design §10）。
#
# 计量不再依赖核心 StatsService（受测版本未编译 v2ray_api），而是在 mangle 表用
# 链首无 target 的纯计数规则统计回环 10086 的双向字节：
#   INPUT  dport 10086 → 上行（Caddy → sing-box）
#   OUTPUT sport 10086 → 下行（sing-box → Caddy）
# 计数异常、锁/目录不可用、超时或规则修复失败一律拒绝放行，绝不清零或解封。
#
# 锁边界：计量有独立的 counter 锁（/run/easy_all/traffic-counter.lock）。唯一允许的
# 嵌套顺序是 runtime → counter；持 counter 时不做网络、下载、证书或服务动作。

readonly CDN_TRAFFIC_GUARD_USAGE_FILE="${STATE_DIR}/cdn-traffic-usage.json"
readonly CDN_TRAFFIC_GUARD_SERVICE_FILE="/etc/systemd/system/easy_all-cdn-traffic-guard.service"
readonly CDN_TRAFFIC_GUARD_TIMER_FILE="/etc/systemd/system/easy_all-cdn-traffic-guard.timer"
readonly CDN_TRAFFIC_GUARD_SERVICE="easy_all-cdn-traffic-guard.service"
readonly CDN_TRAFFIC_GUARD_TIMER="easy_all-cdn-traffic-guard.timer"
readonly DEFAULT_CDN_TRAFFIC_PROTECTION_GB="985"
readonly CDN_TRAFFIC_COUNTER_TABLE="mangle"
readonly CDN_TRAFFIC_COUNTER_CHAIN="${CDN_TRAFFIC_COUNTER_CHAIN_OVERRIDE:-easy_all-cdn}"
readonly CDN_TRAFFIC_COUNTER_DIR="${CDN_TRAFFIC_COUNTER_DIR_OVERRIDE:-/run/easy_all}"
readonly CDN_TRAFFIC_COUNTER_LOCK="${CDN_TRAFFIC_COUNTER_DIR}/traffic-counter.lock"
readonly CDN_TRAFFIC_COUNTER_WAIT="15"
readonly CDN_TRAFFIC_IPTABLES_WAIT="5"
CDN_TRAFFIC_KEEP_BLOCKED=0
CDN_TRAFFIC_COUNTER_LOCK_DEPTH=0
CDN_TRAFFIC_DEADLINE=0

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
    state_protocol_uses_cloudfront "${PROTOCOL:-}" || return 1
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

# --- counter 锁与运行目录 -----------------------------------------------------
#
# /run 是 tmpfs：每个可能先跑的入口都在打开锁前显式建立 root 0700 目录与 0600 锁文件，
# 创建失败即拒绝准备/启动；运行中不 unlink 锁文件，避免不同 inode 互不相干。

cdn_traffic_counter_dir_ensure() {
    install -d -o 0 -g 0 -m 0700 "${CDN_TRAFFIC_COUNTER_DIR}" 2>/dev/null \
        || return 1
    [[ -d "${CDN_TRAFFIC_COUNTER_DIR}" ]] || return 1
    if [[ ! -e "${CDN_TRAFFIC_COUNTER_LOCK}" ]]; then
        (umask 077; : >"${CDN_TRAFFIC_COUNTER_LOCK}") || return 1
    fi
    chmod 0600 "${CDN_TRAFFIC_COUNTER_LOCK}" 2>/dev/null || return 1
    return 0
}

cdn_traffic_counter_acquire() {
    local wait=${1:-${CDN_TRAFFIC_COUNTER_WAIT}}
    if ((CDN_TRAFFIC_COUNTER_LOCK_DEPTH > 0)); then
        CDN_TRAFFIC_COUNTER_LOCK_DEPTH=$((CDN_TRAFFIC_COUNTER_LOCK_DEPTH + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 || return 1
    cdn_traffic_counter_dir_ensure || return 1
    exec 8>"${CDN_TRAFFIC_COUNTER_LOCK}" || return 1
    if ! flock -w "${wait}" 8; then
        exec 8>&-
        return 1
    fi
    CDN_TRAFFIC_COUNTER_LOCK_DEPTH=1
    # 整个临界区共享一个 5 秒 deadline（所有 iptables 子调用服从剩余预算）。
    CDN_TRAFFIC_DEADLINE=$(( $(date +%s) + CDN_TRAFFIC_IPTABLES_WAIT ))
}

cdn_traffic_counter_release() {
    ((CDN_TRAFFIC_COUNTER_LOCK_DEPTH > 0)) || return 0
    CDN_TRAFFIC_COUNTER_LOCK_DEPTH=$((CDN_TRAFFIC_COUNTER_LOCK_DEPTH - 1))
    ((CDN_TRAFFIC_COUNTER_LOCK_DEPTH == 0)) || return 0
    flock -u 8 >/dev/null 2>&1 || true
    exec 8>&-
    CDN_TRAFFIC_DEADLINE=0
}

# --- usage 文档 ---------------------------------------------------------------

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

# 读取并规范化 usage。合法旧文件按 protection_offline=false 兼容读入；
# 违反白名单或离线不变量的文件一律视为损坏，绝不自动创建或清零。
cdn_traffic_read_usage() {
    [[ -s "${CDN_TRAFFIC_GUARD_USAGE_FILE}" ]] || return 1
    cdn_traffic_read_usage_from "$(<"${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
}

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

cdn_traffic_write_usage() {
    local usage=$1 temp normalized
    normalized=$(cdn_traffic_read_usage_from "${usage}") || return 1
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/cdn-traffic-usage.json.XXXXXX") || return 1
    cleanup_files+=("${temp}")
    printf '%s\n' "${normalized}" >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
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
    local applied=${1:-} usage rc=0
    cdn_traffic_protection_enabled || return 0
    [[ "${applied}" == "true" || "${applied}" == "false" ]] || return 1
    cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}" || return 1
    usage=$(cdn_traffic_require_usage) || rc=$?
    if ((rc == 0)); then
        # 只记录本次实际应用的 blocked 目标；期间新产生的 pending 不被旧结果覆盖。
        usage=$(jq -c --argjson applied "${applied}" '.enforced=$applied | if .enforced then . else .protection_offline=false end' <<<"${usage}")
        cdn_traffic_write_usage "${usage}" || rc=$?
    fi
    cdn_traffic_counter_release
    return "${rc}"
}

cdn_traffic_mark_protection_offline() {
    local usage rc=0
    cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}" || return 1
    usage=$(cdn_traffic_read_usage) || rc=$?
    if ((rc == 0)); then
        usage=$(jq -c '.blocked=true | .enforced=false | .protection_offline=true' <<<"${usage}")
        cdn_traffic_write_usage "${usage}" || rc=$?
    fi
    cdn_traffic_counter_release
    return "${rc}"
}

cdn_traffic_mark_restricted_recovered() {
    local usage rc=0
    cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}" || return 1
    usage=$(cdn_traffic_read_usage) || rc=$?
    if ((rc == 0)); then
        usage=$(jq -c '.blocked=true | .enforced=true | .protection_offline=false' <<<"${usage}")
        cdn_traffic_write_usage "${usage}" || rc=$?
    fi
    cdn_traffic_counter_release
    return "${rc}"
}

# --- mangle 计数规则 ----------------------------------------------------------

cdn_traffic_iptables() {
    command -v iptables >/dev/null 2>&1 || return 1
    local wait=${CDN_TRAFFIC_IPTABLES_WAIT} remain
    # 单次临界区硬上限 5 秒：所有子调用共享同一 deadline，不能每步各等 5 秒。
    if ((CDN_TRAFFIC_DEADLINE > 0)); then
        remain=$((CDN_TRAFFIC_DEADLINE - $(date +%s)))
        if ((remain <= 0)); then
            return 1
        fi
        ((remain < wait)) && wait=${remain}
    fi
    iptables -w "${wait}" -t "${CDN_TRAFFIC_COUNTER_TABLE}" "$@"
}

cdn_traffic_chain_exists() {
    cdn_traffic_iptables -S "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1
}

# 幂等：先 -C 检查，缺失才插入；只清理明确自有的重复跳转规则。
cdn_traffic_rule_count() {
    local chain=$1 expected=$2 count
    count=$(cdn_traffic_iptables -S "${chain}" 2>/dev/null | grep -Fxc -- "${expected}" || true)
    printf '%s\n' "${count:-0}"
}

# 幂等：0 条则添加（链内追加、内建链插链首），多于 1 条则只删自有重复。
cdn_traffic_ensure_unique_rule() {
    local chain=$1 expected=$2 insert=$3 count
    shift 3
    count=$(cdn_traffic_rule_count "${chain}" "${expected}")
    if ((count == 0)); then
        if [[ "${insert}" == "append" ]]; then
            cdn_traffic_iptables -A "$@" || return 1
        else
            # 插入形式把链名重复了一次（删除分支要用未截断的 $@），这里只丢掉重复的链名：
            # -I 的规则编号必须紧跟链名：-I INPUT 1 ...（-I 1 INPUT 是非法语法）。
            shift
            cdn_traffic_iptables -I "${chain}" 1 "$@" || return 1
        fi
    fi
    while ((count > 1)); do
        cdn_traffic_iptables -D "$@" || return 1
        count=$((count - 1))
    done
    return 0
}

cdn_traffic_counters_install() {
    local port
    port=$(runtime_cdn_loopback_port)
    cdn_traffic_chain_exists || cdn_traffic_iptables -N "${CDN_TRAFFIC_COUNTER_CHAIN}" || return 1
    # 方向由挂接点决定：INPUT 跳转已限制 -i lo --dport，OUTPUT 跳转已限制 -o lo --sport；
    # 链内规则不能再要求 -i lo -o lo（INPUT 没有出接口、OUTPUT 没有入接口，会两边都不匹配）。
    cdn_traffic_ensure_unique_rule "${CDN_TRAFFIC_COUNTER_CHAIN}" \
        "-A ${CDN_TRAFFIC_COUNTER_CHAIN} -p tcp -m tcp --dport ${port}" \
        append "${CDN_TRAFFIC_COUNTER_CHAIN}" -p tcp -m tcp --dport "${port}" || return 1
    cdn_traffic_ensure_unique_rule "${CDN_TRAFFIC_COUNTER_CHAIN}" \
        "-A ${CDN_TRAFFIC_COUNTER_CHAIN} -p tcp -m tcp --sport ${port}" \
        append "${CDN_TRAFFIC_COUNTER_CHAIN}" -p tcp -m tcp --sport "${port}" || return 1
    cdn_traffic_ensure_unique_rule INPUT \
        "-A INPUT -i lo -p tcp -m tcp --dport ${port} -j ${CDN_TRAFFIC_COUNTER_CHAIN}" \
        insert INPUT -i lo -p tcp -m tcp --dport "${port}" -j "${CDN_TRAFFIC_COUNTER_CHAIN}" || return 1
    cdn_traffic_ensure_unique_rule OUTPUT \
        "-A OUTPUT -o lo -p tcp -m tcp --sport ${port} -j ${CDN_TRAFFIC_COUNTER_CHAIN}" \
        insert OUTPUT -o lo -p tcp -m tcp --sport "${port}" -j "${CDN_TRAFFIC_COUNTER_CHAIN}" || return 1
    cdn_traffic_counters_ready
}

cdn_traffic_counters_ready() {
    local port
    port=$(runtime_cdn_loopback_port)
    cdn_traffic_chain_exists || return 1
    cdn_traffic_iptables -C INPUT -i lo -p tcp -m tcp --dport "${port}" \
        -j "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1 || return 1
    cdn_traffic_iptables -C OUTPUT -o lo -p tcp -m tcp --sport "${port}" \
        -j "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1 || return 1
    return 0
}

# 卸载/回滚只回收本工具自有的跳转与链；共享锁文件/inode 不删。
cdn_traffic_counters_remove() {
    local port rc=0 snapshot
    # 缺 iptables 工具不等于内核没有规则：已安装/有 usage 且内核 mangle 表存在时拒绝清理。
    if ! command -v iptables >/dev/null 2>&1; then
        # 缺工具时无法可靠查询 nft/legacy 后端；已有安装或 usage 就按“可能仍有规则”失败，
        # 保留 state/命令供恢复工具后重试。只有安装尚未进入计量阶段（无 state/usage）才放行。
        if [[ -e "${CDN_TRAFFIC_GUARD_USAGE_FILE}" || -e "${STATE_FILE}" ]]; then
            return 1
        fi
        return 0
    fi
    port=$(runtime_cdn_loopback_port 2>/dev/null || printf '10086')
    cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}" || return 1
    # 先读完整 -S：查询本身失败（xtables 锁/预算耗尽）与“规则不存在”必须区分。
    if ! snapshot=$(cdn_traffic_iptables -S 2>/dev/null); then
        cdn_traffic_counter_release
        return 1
    fi
    if grep -Fq -- "-A INPUT -i lo -p tcp -m tcp --dport ${port} -j ${CDN_TRAFFIC_COUNTER_CHAIN}" <<<"${snapshot}"; then
        cdn_traffic_iptables -D INPUT -i lo -p tcp -m tcp --dport "${port}" \
            -j "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1 || rc=1
    fi
    if grep -Fq -- "-A OUTPUT -o lo -p tcp -m tcp --sport ${port} -j ${CDN_TRAFFIC_COUNTER_CHAIN}" <<<"${snapshot}"; then
        cdn_traffic_iptables -D OUTPUT -o lo -p tcp -m tcp --sport "${port}" \
            -j "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1 || rc=1
    fi
    if grep -Fq -- "-N ${CDN_TRAFFIC_COUNTER_CHAIN}" <<<"${snapshot}"; then
        cdn_traffic_iptables -F "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1 || rc=1
        cdn_traffic_iptables -X "${CDN_TRAFFIC_COUNTER_CHAIN}" >/dev/null 2>&1 || rc=1
    fi
    cdn_traffic_counter_release
    return "${rc}"
}

# 输出 "上行 TAB 下行"（字节，非负整数）；链或规则缺失即失败，绝不返回 0 值兜底。
cdn_traffic_read_counters() {
    local output port up down
    port=$(runtime_cdn_loopback_port)
    output=$(cdn_traffic_iptables -v -x -n -L "${CDN_TRAFFIC_COUNTER_CHAIN}" 2>/dev/null) || return 1
    # -L 的前两行是链说明与列头；按规则文本里的 dport/sport 精确取字节列，
    # 不依赖行号或 target 列（纯计数规则没有 target）。
    up=$(awk -v p="${port}" '$2 ~ /^[0-9]+$/ && $0 ~ ("tcp dpt:" p "$") {print $2; exit}' <<<"${output}")
    down=$(awk -v p="${port}" '$2 ~ /^[0-9]+$/ && $0 ~ ("tcp spt:" p "$") {print $2; exit}' <<<"${output}")
    [[ "${up}" =~ ^[0-9]+$ && "${down}" =~ ^[0-9]+$ ]] || return 1
    printf '%s\t%s\n' "${up}" "${down}"
}

cdn_traffic_epoch_id() {
    local boot_id_file=${EASY_ALL_BOOT_ID_FILE_OVERRIDE:-/proc/sys/kernel/random/boot_id} boot_id
    boot_id=$(cat "${boot_id_file}" 2>/dev/null || true)
    # 没有 boot_id 就无法区分「重启」与「同一次开机」：不返回不稳定值（每轮新 epoch 会把
    # 增量永远置 0，985GB 保护形同不存在），由调用方按采样失败处理。
    [[ -n "${boot_id}" ]] || return 1
    printf 'mangle-%s-%s\n' "${CDN_TRAFFIC_COUNTER_CHAIN}" "${boot_id}"
}

# ExecStartPre 与所有管理入口共用的幂等准备：建目录/锁 → 持 counter → 修规则、
# 校验 usage 与基线 → 释放。返回非零即拒绝启动/继续。
cdn_traffic_prepare_counters() {
    local usage
    cdn_traffic_protection_enabled || return 0
    cdn_traffic_counter_dir_ensure \
        || { warn "无法创建计量运行目录或锁文件：${CDN_TRAFFIC_COUNTER_DIR}"; return 1; }
    cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}" \
        || { warn "等待计量锁超时（${CDN_TRAFFIC_COUNTER_WAIT}s）：${CDN_TRAFFIC_COUNTER_LOCK}"; return 1; }
    if ! cdn_traffic_counters_install; then
        cdn_traffic_counter_release
        warn "无法建立 mangle 计量规则（链 ${CDN_TRAFFIC_COUNTER_CHAIN}）"
        return 1
    fi
    if ! usage=$(cdn_traffic_read_usage); then
        cdn_traffic_counter_release
        warn "CDN 保护统计缺失或损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        return 1
    fi
    cdn_traffic_counter_release
    return 0
}

cdn_traffic_require_counters() {
    cdn_traffic_protection_enabled || return 0
    cdn_traffic_counters_ready || return 1
    cdn_traffic_read_counters >/dev/null || return 1
    cdn_traffic_read_usage >/dev/null || return 1
}

# 候选配置不得在持久阻断/保护性停机时开放 CDN 入站（无环境变量或临时令牌绕过）。
cdn_traffic_start_config_allowed() {
    local config=${1:-${SINGBOX_CONFIG}}
    local usage
    cdn_traffic_protection_enabled || return 0
    usage=$(cdn_traffic_read_usage) || return 1
    jq -e '.blocked == true or .protection_offline == true' <<<"${usage}" >/dev/null || return 0
    [[ -s "${config}" ]] || return 1
    jq -e '[.inbounds[]? | select(.tag == "vless-cdn-in")] | length == 0' "${config}" >/dev/null
}

cdn_traffic_probe_counters() {
    local up down
    IFS=$'\t' read -r up down <<<"$(cdn_traffic_read_counters)" || return 1
    [[ "${up}" =~ ^[0-9]+$ && "${down}" =~ ^[0-9]+$ ]]
}

# --- 定时器 -------------------------------------------------------------------

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
After=${SINGBOX_SERVICE}

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

# 必须在持 counter 锁时调用：采样 → 计算增量 → 写 usage 与 pending 目标。
cdn_traffic_update_usage() {
    local period stats usage runtime_id previous_runtime_id
    local current_up current_down old_up old_down delta_up delta_down used blocked old_blocked
    local enforced offline threshold
    usage=$(cdn_traffic_require_usage) || return 1
    period=$(cdn_traffic_current_period)
    runtime_id=$(cdn_traffic_epoch_id) \
        || { warn "无法确定计费 epoch（缺少 /proc/sys/kernel/random/boot_id）；保留现有保护状态"; return 1; }
    stats=$(cdn_traffic_read_counters) \
        || { warn "读取 mangle 计量规则失败；保留现有保护状态"; return 1; }
    IFS=$'\t' read -r current_up current_down <<<"${stats}" \
        || { warn "mangle 计量输出无效；保留现有保护状态"; return 1; }
    [[ "${current_up}" =~ ^[0-9]+$ && "${current_down}" =~ ^[0-9]+$ ]] \
        || { warn "mangle 计量不是非负整数；保留现有保护状态"; return 1; }
    old_up=$(jq -r '.last_uplink' <<<"${usage}")
    old_down=$(jq -r '.last_downlink' <<<"${usage}")
    previous_runtime_id=$(jq -r '.runtime_id' <<<"${usage}")

    if [[ "${runtime_id}" != "${previous_runtime_id}" ]]; then
        # 换 epoch（重启、规则重建）：只重采样基线，不把新读数当成完整历史。
        delta_up=0
        delta_down=0
    else
        ((current_up >= old_up)) && delta_up=$((current_up - old_up)) || delta_up=0
        ((current_down >= old_down)) && delta_down=$((current_down - old_down)) || delta_down=0
    fi

    if [[ "$(jq -r '.period' <<<"${usage}")" == "${period}" ]]; then
        used=$(jq -r '.used_bytes' <<<"${usage}")
        used=$((used + delta_up + delta_down))
    else
        # 跨 00:00 UTC 的整个区间计入新月：最多多算一个采样间隔，不留未计量缺口。
        used=$((delta_up + delta_down))
    fi
    threshold=$((CDN_TRAFFIC_PROTECTION_GB * 1000 * 1000 * 1000))
    old_blocked=$(jq -r '.blocked' <<<"${usage}")
    enforced=$(jq -r '.enforced' <<<"${usage}")
    offline=$(jq -r '.protection_offline' <<<"${usage}")
    blocked=false
    ((used >= threshold)) && blocked=true
    [[ "${CDN_TRAFFIC_KEEP_BLOCKED:-0}" != "1" ]] || blocked=true
    # 已持久化的待落实阻断与保护性停机不能被一次低额度采样抹掉：
    # 未完成受限恢复前保持 blocked=true，让 sync 先恢复再决定是否解封。
    [[ "${old_blocked}" == "true" && "${enforced}" != "true" ]] && blocked=true
    [[ "${offline}" == "true" ]] && blocked=true
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

# 管理事务已持 runtime：短取 counter 采样后立刻释放；持 counter 期间不做服务动作。
cdn_traffic_protection_checkpoint() {
    cdn_traffic_protection_enabled || return 0
    if ! cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}"; then
        warn "等待计量锁超时；未执行流量 checkpoint"
        return 1
    fi
    if ! cdn_traffic_read_usage >/dev/null; then
        cdn_traffic_counter_release
        warn "CDN 流量保护统计缺失或损坏；未执行 checkpoint"
        return 1
    fi
    if ! cdn_traffic_counters_ready; then
        cdn_traffic_counters_install || {
            cdn_traffic_counter_release
            warn "无法修复 mangle 计量规则；未执行 checkpoint"
            return 1
        }
    fi
    cdn_traffic_update_usage || { cdn_traffic_counter_release; return 1; }
    cdn_traffic_counter_release
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

# 运行中计量失效（规则无法修复/计数或 usage 不可读）时不能继续开放 CDN：
# 先持久化保护意图，再按锁序尝试受限重建；无法重建则停核心（保护性停机）。
cdn_traffic_fail_closed() {
    cdn_traffic_protection_enabled || return 0
    cdn_traffic_mark_protection_offline || true
    if try_acquire_runtime_write_lock; then
        if declare -F cdn_traffic_recover_restricted_runtime >/dev/null 2>&1; then
            cdn_traffic_recover_restricted_runtime || systemctl stop "${SINGBOX_SERVICE:-easy_all-singbox.service}" >/dev/null 2>&1 || true
        else
            systemctl stop "${SINGBOX_SERVICE:-easy_all-singbox.service}" >/dev/null 2>&1 || true
        fi
        release_runtime_write_lock
    else
        systemctl stop "${SINGBOX_SERVICE:-easy_all-singbox.service}" >/dev/null 2>&1 || true
    fi
    warn "CDN 计量已失效：已持久化保护意图并进入受限/停机状态"
}

# timer 与服务启动前入口都走这里：先 counter（只采样/写 pending），释放后才取 runtime。
cdn_traffic_protection_sync() {
    local subscription_ready=1 usage
    require_root
    # timer 可能在管理事务持 runtime 时运行：先用只读状态文件恢复 PROTOCOL/额度，
    # 否则 cdn_traffic_protection_enabled 会因变量为空而短路采样。
    if [[ -f "${STATE_FILE}" ]]; then
        collect_installed_state || return 1
    fi
    if ! cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}"; then
        warn "等待计量锁超时；保留现有 usage 与 pending，下一轮重试"
        return 1
    fi
    if ! cdn_traffic_counters_install; then
        cdn_traffic_counter_release
        warn "无法建立 mangle 计量规则；转入受限/停机保护"
        cdn_traffic_fail_closed || true
        return 1
    fi
    if ! usage=$(cdn_traffic_read_usage); then
        cdn_traffic_counter_release
        warn "CDN 全局费用保护统计文件缺失或损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}；不会自动清零"
        cdn_traffic_fail_closed || true
        return 1
    fi
    if ! cdn_traffic_update_usage; then
        cdn_traffic_counter_release
        cdn_traffic_fail_closed || true
        return 1
    fi
    # 状态漂移自愈：usage 声称开放但实际配置已无 CDN 入站（例如回滚 fallback 后
    # 保护状态未能落盘）时强制收敛，避免 false/false 永久跳过重建。
    if [[ "${CDN_TRAFFIC_NEEDS_APPLY:-0}" != "1" ]] && [[ -s "${SINGBOX_CONFIG}" ]] \
        && jq -e '.blocked == false and .enforced == false' <<<"${usage}" >/dev/null 2>&1 \
        && ! jq -e '[.inbounds[]? | select(.tag == "vless-cdn-in")] | length > 0' "${SINGBOX_CONFIG}" >/dev/null 2>&1; then
        warn "检测到实际配置受限但 usage 为开放：强制收敛保护状态"
        CDN_TRAFFIC_DRIFT_REPAIR=1
        CDN_TRAFFIC_BLOCKED=false
        CDN_TRAFFIC_NEEDS_APPLY=1
    fi
    cdn_traffic_counter_release

    # counter 已释放：现在才允许尝试 runtime。
    if ! try_acquire_runtime_write_lock; then
        info "运行时写锁正被占用；本轮跳过 CDN 流量同步"
        return 0
    fi
    collect_installed_state || { release_runtime_write_lock; return 1; }
    if ! cdn_traffic_protection_enabled; then
        release_runtime_write_lock
        return 0
    fi
    usage=$(cdn_traffic_read_usage) || { release_runtime_write_lock; return 1; }

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
        && { jq -e '.blocked == true or .enforced == true' <<<"${usage}" >/dev/null \
             || [[ "${CDN_TRAFFIC_DRIFT_REPAIR:-0}" == "1" ]]; }; then
        CDN_TRAFFIC_KEEP_BLOCKED=1
        CDN_TRAFFIC_BLOCKED=true
        cdn_traffic_deny_subscription_runtime \
            || warn "无法安装订阅 503 的降级配置；旧订阅产物可能仍可下载"
    fi

    if [[ "${CDN_TRAFFIC_NEEDS_APPLY}" == "1" ]]; then
        # 重建前用短临界区重读最新目标（期间可能又超限/换月）。
        if cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}"; then
            if ! cdn_traffic_update_usage; then
                cdn_traffic_counter_release
                warn "重建前二次采样失败；保持受限并保留 pending"
                cdn_traffic_fail_closed || true
                release_runtime_write_lock
                return 1
            fi
            cdn_traffic_counter_release
        else
            warn "等待计量锁超时；本轮不重建运行时"
            release_runtime_write_lock
            return 1
        fi
        if [[ "${CDN_TRAFFIC_DRIFT_REPAIR:-0}" == "1" ]]; then
            CDN_TRAFFIC_NEEDS_APPLY=1
        fi
        if [[ "${CDN_TRAFFIC_NEEDS_APPLY:-0}" != "1" ]]; then
            release_runtime_write_lock
            return 0
        fi
        # 持 runtime 的重建：启动子进程只会取 counter，不构成锁环。
        if ! (rebuild_traffic_runtime "${CDN_TRAFFIC_BLOCKED}"); then
            warn "应用 CloudFront 全局费用保护状态失败；保留待落实状态并等待下一轮重试"
            release_runtime_write_lock
            return 1
        fi
        # 仍持 runtime 时短取 counter：只标记实际应用的目标。
        if cdn_traffic_counter_acquire "${CDN_TRAFFIC_COUNTER_WAIT}"; then
            if ! cdn_traffic_mark_enforced "${CDN_TRAFFIC_BLOCKED}"; then
                warn "无法落盘 CloudFront 保护已落实状态；下一轮将重试"
                cdn_traffic_counter_release
                release_runtime_write_lock
                return 1
            fi
            cdn_traffic_counter_release
        else
            warn "等待计量锁超时；未标记 enforced，下一轮重试"
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
