#!/usr/bin/env bash

# Shared optional per-user monthly traffic quota support.

readonly QUOTA_USAGE_FILE="${STATE_DIR}/quota-usage.json"
readonly QUOTA_API_LISTEN="127.0.0.1:10085"
readonly QUOTA_SERVICE_FILE="/etc/systemd/system/easy_all-quota.service"
readonly QUOTA_TIMER_FILE="/etc/systemd/system/easy_all-quota.timer"
readonly QUOTA_SERVICE="easy_all-quota.service"
readonly QUOTA_TIMER="easy_all-quota.timer"
readonly QUOTA_MAINTENANCE_FILE="${STATE_DIR}/quota-maintenance"
readonly RUNTIME_WRITE_LOCK_FILE="${STATE_DIR}/runtime-write.lock"

RUNTIME_WRITE_LOCK_DEPTH=0
QUOTA_MAINTENANCE_ACTIVE=0

quota_enabled() {
    [[ "${QUOTA_ENABLED:-0}" == "1" ]]
}

traffic_stats_enabled() {
    quota_enabled && return 0
    if declare -F cdn_traffic_protection_enabled >/dev/null 2>&1; then
        cdn_traffic_protection_enabled && return 0
    fi
    return 1
}

try_acquire_runtime_write_lock() {
    if ((RUNTIME_WRITE_LOCK_DEPTH > 0)); then
        RUNTIME_WRITE_LOCK_DEPTH=$((RUNTIME_WRITE_LOCK_DEPTH + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 \
        || die "缺少 flock；无法保护 easy_all 运行时更新"
    install -d -m 0700 "${STATE_DIR}"
    exec 9>"${RUNTIME_WRITE_LOCK_FILE}" \
        || die "无法打开 easy_all 运行时锁：${RUNTIME_WRITE_LOCK_FILE}"
    if ! flock -n 9; then
        exec 9>&-
        return 1
    fi
    RUNTIME_WRITE_LOCK_DEPTH=1
    [[ "${QUOTA_MAINTENANCE_ACTIVE}" == "1" ]] \
        || rm -f -- "${QUOTA_MAINTENANCE_FILE}"
}

acquire_runtime_write_lock() {
    try_acquire_runtime_write_lock \
        || die "另一个 easy_all 配置或流量统计任务正在运行，请稍后重试"
}

release_runtime_write_lock() {
    ((RUNTIME_WRITE_LOCK_DEPTH > 0)) || return 0
    RUNTIME_WRITE_LOCK_DEPTH=$((RUNTIME_WRITE_LOCK_DEPTH - 1))
    ((RUNTIME_WRITE_LOCK_DEPTH == 0)) || return 0
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
}

begin_quota_maintenance() {
    acquire_runtime_write_lock
    install -d -m 0700 "${STATE_DIR}"
    install -m 0600 /dev/null "${QUOTA_MAINTENANCE_FILE}"
    QUOTA_MAINTENANCE_ACTIVE=1
}

end_quota_maintenance() {
    if [[ "${QUOTA_MAINTENANCE_ACTIVE}" == "1" ]]; then
        rm -f -- "${QUOTA_MAINTENANCE_FILE}"
        QUOTA_MAINTENANCE_ACTIVE=0
    fi
    release_runtime_write_lock
}

validate_user_accounts() {
    local accounts=${1:-} user uuid token quota
    jq -e '
        type == "object" and length > 0 and
        all(to_entries[];
            (.key|test("^[A-Za-z0-9._-]{1,64}$")) and
            (.key != "__denied__") and
            (.value|type == "object") and
            (.value.token|type == "string" and test("^[A-Za-z0-9._~-]{8,128}$")) and
            (.value.uuid|type == "string") and
            (.value.quota_gb as $quota |
              ($quota|type) == "number" and ($quota|floor) == $quota and
              $quota >= 0 and $quota <= 1000000)) and
        ([.[].token]|length == (unique|length)) and
        ([.[].uuid]|length == (unique|length))
    ' <<<"${accounts}" >/dev/null || return 1
    while IFS=$'\t' read -r user uuid token quota; do
        validate_uuid "${uuid}" || return 1
        [[ -n "${user}" && -n "${token}" && "${quota}" =~ ^[0-9]+$ ]] || return 1
    done < <(jq -r 'to_entries[] | [.key,.value.uuid,.value.token,(.value.quota_gb|tostring)] | @tsv' \
        <<<"${accounts}")
}

normalize_monthly_quotas() {
    local raw=$1
    jq -ce '
        if type != "object" then error("配额必须是 JSON object") else . end |
        with_entries(.key |= gsub("^\\s+|\\s+$"; "")) |
        if length > 0 and all(to_entries[];
            (.key|test("^[A-Za-z0-9._-]{1,64}$")) and
            (.key != "__denied__") and
            (.value as $quota |
              ($quota|type) == "number" and ($quota|floor) == $quota and
              $quota >= 0 and $quota <= 1000000))
        then . else error("配额必须是 0-1000000 的整数 GB") end
    ' <<<"${raw}"
}

generate_user_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        uuidgen 2>/dev/null || {
            local hex
            hex=$(openssl rand -hex 16)
            printf '%s-%s-4%s-8%s-%s\n' \
                "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
        }
    fi
}

build_user_accounts() {
    local tokens=$1 quotas=$2 existing=${3:-'{}'} result='{}'
    local user token quota uuid first=1 has_owner=0
    jq -e 'has("owner")' <<<"${tokens}" >/dev/null && has_owner=1
    while IFS=$'\t' read -r user token quota; do
        uuid=$(jq -r --arg user "${user}" '.[$user].uuid // empty' <<<"${existing}")
        if [[ "${has_owner}" == "1" && "${user}" != "owner" \
            && "${uuid}" == "${VLESS_UUID}" ]]; then
            uuid=""
        fi
        if [[ -z "${uuid}" ]]; then
            if [[ "${user}" == "owner" || ( "${has_owner}" == "0" && "${first}" == "1" ) ]]; then
                uuid=${VLESS_UUID}
            else
                uuid=$(generate_user_uuid)
            fi
        fi
        result=$(jq -c --arg user "${user}" --arg token "${token}" --arg uuid "${uuid}" \
            --argjson quota "${quota}" \
            '. + {($user):{token:$token,uuid:$uuid,quota_gb:$quota}}' <<<"${result}")
        first=0
    done < <(jq -r --argjson quotas "${quotas}" \
        'to_entries[] | [.key,.value,($quotas[.key]|tostring)] | @tsv' <<<"${tokens}")
    validate_user_accounts "${result}" || die "生成的月度配额用户状态无效"
    printf '%s\n' "${result}"
}

quota_default_map() {
    local existing_accounts=${1:-'{}'} existing_tokens=${2:-'{}'}
    jq -cn --argjson accounts "${existing_accounts}" --argjson tokens "${existing_tokens}" '
        (($accounts|keys) + ($tokens|keys) | unique) as $users |
        if ($users|length) == 0 then {"owner":0}
        else reduce $users[] as $user ({};
            .[$user] = ($accounts[$user].quota_gb //
              (if $user == "owner" then 0 else 100 end)))
        end'
}

build_quota_tokens() {
    local quotas=$1 existing_tokens=${2:-'{}'} result='{}' user token
    while IFS= read -r user; do
        token=$(jq -r --arg user "${user}" '.[$user] // empty' <<<"${existing_tokens}")
        [[ -n "${token}" ]] || token=$(generate_secret)
        result=$(jq -c --arg user "${user}" --arg token "${token}" \
            '. + {($user):$token}' <<<"${result}")
    done < <(jq -r 'keys[]' <<<"${quotas}")
    printf '%s\n' "${result}"
}

apply_quota_token_overrides() {
    local tokens=$1 quotas=$2 overrides=${3:-'{}'} merged
    jq -e --argjson quotas "${quotas}" '
        type == "object" and
        ((keys - ($quotas|keys))|length == 0) and
        all(to_entries[];
          (.value|type == "string" and test("^[A-Za-z0-9._~-]{8,128}$")))
    ' <<<"${overrides}" >/dev/null \
        || die "Token 覆盖必须是只包含现有用户的 {\"用户\":\"Token\"} JSON"
    merged=$(jq -c --argjson overrides "${overrides}" '. * $overrides' <<<"${tokens}")
    normalize_allowed_tokens "${merged}" \
        || die "Token 覆盖后存在格式错误或重复 Token"
}

quota_days_in_month() {
    local year=$((10#$1)) month=$((10#$2))
    case "${month}" in
    1 | 3 | 5 | 7 | 8 | 10 | 12) printf '31\n' ;;
    4 | 6 | 9 | 11) printf '30\n' ;;
    2)
        if ((year % 400 == 0 || (year % 4 == 0 && year % 100 != 0))); then
            printf '29\n'
        else
            printf '28\n'
        fi
        ;;
    *) return 1 ;;
    esac
}

validate_quota_start_date() {
    local value=$1 today=${2:-$(date -u +%Y-%m-%d)} year month day max_day
    [[ "${value}" =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]] || return 1
    year=${BASH_REMATCH[1]}
    month=${BASH_REMATCH[2]}
    day=${BASH_REMATCH[3]}
    ((10#${year} >= 1970 && 10#${month} >= 1 && 10#${month} <= 12)) || return 1
    max_day=$(quota_days_in_month "${year}" "${month}") || return 1
    ((10#${day} >= 1 && 10#${day} <= max_day)) || return 1
    [[ "${value}" > "${today}" ]] && return 1
    return 0
}

quota_shift_month() {
    local year=$((10#$1)) month=$((10#$2)) delta=$3
    month=$((month + delta))
    while ((month < 1)); do month=$((month + 12)); year=$((year - 1)); done
    while ((month > 12)); do month=$((month - 12)); year=$((year + 1)); done
    printf '%04d-%02d\n' "${year}" "${month}"
}

quota_boundary_for_month() {
    local year=$1 month=$2 anchor_day=$3 max_day day
    max_day=$(quota_days_in_month "${year}" "${month}")
    day=$((10#${anchor_day}))
    ((day <= max_day)) || day=${max_day}
    printf '%04d-%02d-%02d\n' "$((10#${year}))" "$((10#${month}))" "${day}"
}

quota_current_period() {
    local today=${1:-$(date -u +%Y-%m-%d)} anchor=${QUOTA_START_DATE}
    local year=${today:0:4} month=${today:5:2} anchor_day=${anchor:8:2}
    local boundary start_month end_month start end
    boundary=$(quota_boundary_for_month "${year}" "${month}" "${anchor_day}")
    if [[ "${today}" < "${boundary}" ]]; then
        start_month=$(quota_shift_month "${year}" "${month}" -1)
        end_month=$(printf '%04d-%02d' "$((10#${year}))" "$((10#${month}))")
    else
        start_month=$(printf '%04d-%02d' "$((10#${year}))" "$((10#${month}))")
        end_month=$(quota_shift_month "${year}" "${month}" 1)
    fi
    start=$(quota_boundary_for_month "${start_month%-*}" "${start_month#*-}" "${anchor_day}")
    end=$(quota_boundary_for_month "${end_month%-*}" "${end_month#*-}" "${anchor_day}")
    printf '%s/%s\n' "${start}" "${end}"
}

choose_monthly_quota() {
    local enabled=${1:-1} choice current default_quotas raw quotas
    local generated_tokens token_overrides default_start_date
    if [[ "${enabled}" != "1" ]]; then
        QUOTA_ENABLED=0
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
        return 0
    fi
    current=${QUOTA_ENABLED:-0}
    choice=${ENABLE_MONTHLY_QUOTA:-}
    if [[ -z "${choice}" && -t 0 ]]; then
        printf '是否启用按用户月度流量配额（按 VPS 开通日计算 UTC 月度账期）？\n'
        printf 'Enable per-user monthly traffic quotas (UTC billing cycle based on the VPS start date)?\n'
        printf '  1. 不启用（共用单个节点 UUID）\n'
        printf '     Disable (all users share one node UUID)\n'
        printf '  2. 启用（每个订阅用户使用独立 UUID，超额自动停用）\n'
        printf '     Enable (each subscription user gets a separate UUID and is disabled after exceeding the quota)\n'
        [[ "${current}" == "1" ]] && choice=2 || choice=1
        read_bilingual \
            "请选择 [${choice}]（直接回车使用默认值）:" \
            "Choose [${choice}] (press Enter to use the default):" raw
        choice=${raw:-${choice}}
    fi
    if [[ -z "${choice}" ]]; then
        [[ "${current}" == "1" ]] && choice=2 || choice=1
    fi
    case "${choice}" in
    1 | no | off | disabled)
        QUOTA_ENABLED=0
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
        ;;
    2 | yes | on | enabled)
        QUOTA_ENABLED=1
        default_quotas=$(quota_default_map "${USER_ACCOUNTS:-}" "${ALLOWED_TOKENS:-}")
        quotas=${MONTHLY_QUOTAS_GB:-}
        if [[ -z "${quotas}" && -t 0 ]]; then
            quotas=$(prompt_value \
                "用户与月度配额 JSON（GB，0 表示不限量；Token、UUID、email 自动生成）" \
                "${default_quotas}" \
                "User and monthly quota JSON (GB; 0 means unlimited; Token, UUID and email are generated automatically)")
        fi
        quotas=${quotas:-${default_quotas}}
        quotas=$(normalize_monthly_quotas "${quotas}") \
            || die "MONTHLY_QUOTAS_GB 无效"
        generated_tokens=$(build_quota_tokens "${quotas}" "${ALLOWED_TOKENS:-}")
        info "已生成或复用用户 Token：${generated_tokens}"
        token_overrides=${QUOTA_TOKEN_OVERRIDES:-}
        if [[ -z "${token_overrides}" && -t 0 ]]; then
            token_overrides=$(prompt_value \
                "可选 Token 覆盖 JSON（仅填写要覆盖的用户，直接回车不覆盖）" "{}" \
                "Optional Token override JSON (enter only users to override; press Enter to keep generated Tokens)")
        fi
        token_overrides=${token_overrides:-'{}'}
        ALLOWED_TOKENS=$(apply_quota_token_overrides "${generated_tokens}" "${quotas}" \
            "${token_overrides}")
        USER_ACCOUNTS=$(build_user_accounts "${ALLOWED_TOKENS}" "${quotas}" \
            "${USER_ACCOUNTS:-}")
        default_start_date=${QUOTA_START_DATE:-$(date -u +%Y-%m-%d)}
        if [[ -z "${QUOTA_START_DATE:-}" && -t 0 ]]; then
            QUOTA_START_DATE=$(prompt_value \
                "VPS 开通日期（YYYY-MM-DD，作为每月配额周期起点）" \
                "${default_start_date}" \
                "VPS start date (YYYY-MM-DD; start of each monthly quota cycle)")
        else
            QUOTA_START_DATE=${QUOTA_START_DATE:-${default_start_date}}
        fi
        validate_quota_start_date "${QUOTA_START_DATE}" \
            || die "VPS 开通日期无效、晚于今天或不是 YYYY-MM-DD：${QUOTA_START_DATE}"
        ;;
    *) die "月度流量配额选项无效：${choice}" ;;
    esac
}

quota_active_clients_json() {
    local flow=${1:-} accounts
    accounts=$(quota_active_accounts_json)
    jq -cn --argjson accounts "${accounts}" --arg flow "${flow}" '
        [$accounts|to_entries[] |
          {id:.value.uuid,email:("easy_all." + .key)}
          + (if $flow == "" then {} else {flow:$flow} end)]'
}

quota_active_accounts_json() {
    local disabled='[]'
    if [[ -s "${QUOTA_USAGE_FILE}" ]]; then
        disabled=$(jq -c '[.users|to_entries[]?|select(.value.disabled == true)|.key]' \
            "${QUOTA_USAGE_FILE}" 2>/dev/null || printf '[]')
    fi
    jq -cn --argjson accounts "${USER_ACCOUNTS}" --argjson disabled "${disabled}" '
        reduce (($accounts|to_entries[]) as $item |
          select(($disabled|index($item.key)) == null) | $item) as $item
          ({}; .[$item.key]=$item.value)'
}

initialize_quota_usage() {
    local period
    quota_enabled || return 0
    period=$(quota_current_period)
    install -d -m 0700 "${STATE_DIR}"
    if [[ ! -s "${QUOTA_USAGE_FILE}" ]]; then
        jq -n --arg period "${period}" --argjson accounts "${USER_ACCOUNTS}" '
            {period:$period,runtime_id:"",users:
              (reduce ($accounts|keys[]) as $user ({};
                .[$user]={used_bytes:0,last_uplink:0,last_downlink:0,disabled:false}))}' \
            >"${RUNTIME_TMP}/quota-usage.json"
        install -m 0600 "${RUNTIME_TMP}/quota-usage.json" "${QUOTA_USAGE_FILE}"
    fi
}

install_quota_timer() {
    if ! quota_enabled; then
        remove_quota_timer
        return 0
    fi
    initialize_quota_usage
    cat >"${RUNTIME_TMP}/easy_all-quota.service" <<EOF
[Unit]
Description=easy_all monthly per-user traffic quota accounting
After=${XRAY_SERVICE}

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} quota-sync
EOF
    cat >"${RUNTIME_TMP}/easy_all-quota.timer" <<'EOF'
[Unit]
Description=Run easy_all traffic quota accounting every minute

[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
AccuracySec=10s
Unit=easy_all-quota.service

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-quota.service" "${QUOTA_SERVICE_FILE}"
    install -m 0644 "${RUNTIME_TMP}/easy_all-quota.timer" "${QUOTA_TIMER_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${QUOTA_TIMER}" >/dev/null \
        || die "启用月度流量配额定时器失败"
}

validate_quota_api() {
    local attempt
    traffic_stats_enabled || return 0
    for attempt in 1 2 3 4 5; do
        if "${XRAY_BIN}" api statsquery --server="${QUOTA_API_LISTEN}" \
            >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    die "Xray 流量统计 API 验收失败：${QUOTA_API_LISTEN}"
}

remove_quota_timer() {
    systemctl disable --now "${QUOTA_TIMER}" >/dev/null 2>&1 || true
    systemctl stop "${QUOTA_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${QUOTA_SERVICE_FILE}" "${QUOTA_TIMER_FILE}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

quota_sync_usage() {
    local period stats usage original_usage user quota current_up current_down old_up old_down
    local delta_up delta_down used disabled old_disabled changed=0 temp
    local runtime_id previous_runtime_id
    local period_reset=0
    require_root
    try_acquire_runtime_write_lock || return 0
    if [[ "${QUOTA_MAINTENANCE_ACTIVE}" == "1" ]]; then
        release_runtime_write_lock
        return 0
    fi
    collect_installed_state
    if ! quota_enabled; then
        release_runtime_write_lock
        return 0
    fi
    initialize_quota_usage
    period=$(quota_current_period)
    usage=$(<"${QUOTA_USAGE_FILE}")
    original_usage=${usage}
    if [[ "$(jq -r '.period' <<<"${usage}")" != "${period}" ]]; then
        usage=$(jq -n --arg period "${period}" --argjson accounts "${USER_ACCOUNTS}" '
            {period:$period,runtime_id:"",users:
              (reduce ($accounts|keys[]) as $user ({};
                .[$user]={used_bytes:0,last_uplink:0,last_downlink:0,disabled:false}))}')
        changed=1
        period_reset=1
    fi
    runtime_id=$(systemctl show "${XRAY_SERVICE}" -p InvocationID --value 2>/dev/null || true)
    previous_runtime_id=$(jq -r '.runtime_id // ""' <<<"${usage}")
    if [[ -n "${runtime_id}" && "${runtime_id}" != "${previous_runtime_id}" ]]; then
        usage=$(jq --arg runtime_id "${runtime_id}" '
            .runtime_id=$runtime_id |
            .users |= with_entries(.value.last_uplink=0 | .value.last_downlink=0)' <<<"${usage}")
    fi
    stats=$("${XRAY_BIN}" api statsquery --server="${QUOTA_API_LISTEN}") \
        || die "读取 Xray 用户流量统计失败"
    while IFS=$'\t' read -r user quota; do
        current_up=$(jq -r --arg name "user>>>easy_all.${user}>>>traffic>>>uplink" \
            '[.stat[]?|select(.name==$name)|.value][0] // 0' <<<"${stats}")
        current_down=$(jq -r --arg name "user>>>easy_all.${user}>>>traffic>>>downlink" \
            '[.stat[]?|select(.name==$name)|.value][0] // 0' <<<"${stats}")
        old_up=$(jq -r --arg user "${user}" '.users[$user].last_uplink // 0' <<<"${usage}")
        old_down=$(jq -r --arg user "${user}" '.users[$user].last_downlink // 0' <<<"${usage}")
        if [[ "${period_reset}" == "1" ]]; then
            delta_up=0
            delta_down=0
        else
            ((current_up >= old_up)) && delta_up=$((current_up - old_up)) || delta_up=${current_up}
            ((current_down >= old_down)) && delta_down=$((current_down - old_down)) || delta_down=${current_down}
        fi
        used=$(jq -r --arg user "${user}" '.users[$user].used_bytes // 0' <<<"${usage}")
        used=$((used + delta_up + delta_down))
        old_disabled=$(jq -r --arg user "${user}" '.users[$user].disabled // false' <<<"${usage}")
        disabled=false
        ((quota > 0 && used >= quota * 1000 * 1000 * 1000)) && disabled=true
        [[ "${disabled}" == "${old_disabled}" ]] || changed=1
        usage=$(jq -c --arg user "${user}" --argjson used "${used}" \
            --argjson up "${current_up}" --argjson down "${current_down}" \
            --argjson disabled "${disabled}" '
            .users[$user]={used_bytes:$used,last_uplink:$up,last_downlink:$down,
              disabled:$disabled}' <<<"${usage}")
    done < <(jq -r 'to_entries[] | [.key,(.value.quota_gb|tostring)] | @tsv' \
        <<<"${USER_ACCOUNTS}")
    temp=$(mktemp "${STATE_DIR}/quota-usage.json.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${usage}" >"${temp}"
    install -m 0600 "${temp}" "${QUOTA_USAGE_FILE}"
    if [[ "${changed}" == "1" ]]; then
        if ! (rebuild_traffic_runtime); then
            printf '%s\n' "${original_usage}" >"${temp}"
            install -m 0600 "${temp}" "${QUOTA_USAGE_FILE}"
            release_runtime_write_lock
            die "应用月度流量配额状态失败，已恢复旧统计状态并将在下次重试"
        fi
    fi
    release_runtime_write_lock
}

show_quota_status() {
    local usage user quota used disabled
    if ! quota_enabled; then
        printf '月度流量配额: disabled\n'
        return 0
    fi
    initialize_quota_usage
    usage=$(<"${QUOTA_USAGE_FILE}")
    printf '月度流量配额: enabled（UTC 账期 %s，锚定开通日 %s）\n' \
        "$(jq -r '.period' <<<"${usage}")" "${QUOTA_START_DATE}"
    while IFS=$'\t' read -r user quota; do
        used=$(jq -r --arg user "${user}" '.users[$user].used_bytes // 0' <<<"${usage}")
        disabled=$(jq -r --arg user "${user}" '.users[$user].disabled // false' <<<"${usage}")
        if [[ "${quota}" == "0" ]]; then
            printf '  %s: %.3f GB / unlimited, disabled=%s\n' \
                "${user}" "$(awk -v bytes="${used}" 'BEGIN{print bytes/1000000000}')" "${disabled}"
        else
            printf '  %s: %.3f GB / %s GB, disabled=%s\n' \
                "${user}" "$(awk -v bytes="${used}" 'BEGIN{print bytes/1000000000}')" \
                "${quota}" "${disabled}"
        fi
    done < <(jq -r 'to_entries[] | [.key,(.value.quota_gb|tostring)] | @tsv' \
        <<<"${USER_ACCOUNTS}")
}

validate_quota_user() {
    local user=$1
    [[ "${user}" =~ ^[A-Za-z0-9._-]{1,64}$ ]] \
        || die "配额用户名无效：${user}"
    jq -e --arg user "${user}" 'has($user)' <<<"${USER_ACCOUNTS}" >/dev/null \
        || die "配额用户不存在：${user}"
}

quota_set_user() {
    local user=${1:-} quota=${2:-} old_accounts old_usage usage used
    local old_disabled new_disabled temp
    (($# == 2)) || die "用法：easy_all quota-set <用户名> <整数GB；0表示不限量>"
    require_root
    collect_installed_state
    quota_enabled || die "当前未启用月度用户流量配额"
    validate_quota_user "${user}"
    [[ "${quota}" =~ ^[0-9]+$ && ${#quota} -le 7 ]] \
        && ((10#${quota} <= 1000000)) \
        || die "月度配额必须是 0-1000000 的整数 GB"
    quota=$((10#${quota}))
    quota_sync_usage
    begin_quota_maintenance
    initialize_quota_usage
    old_accounts=${USER_ACCOUNTS}
    old_usage=$(<"${QUOTA_USAGE_FILE}")
    used=$(jq -r --arg user "${user}" '.users[$user].used_bytes // 0' <<<"${old_usage}")
    old_disabled=$(jq -r --arg user "${user}" '.users[$user].disabled // false' <<<"${old_usage}")
    new_disabled=false
    ((quota > 0 && used >= quota * 1000 * 1000 * 1000)) && new_disabled=true
    USER_ACCOUNTS=$(jq -c --arg user "${user}" --argjson quota "${quota}" \
        '.[$user].quota_gb=$quota' <<<"${USER_ACCOUNTS}")
    usage=$(jq -c --arg user "${user}" --argjson disabled "${new_disabled}" '
        .users[$user] = ((.users[$user] //
          {used_bytes:0,last_uplink:0,last_downlink:0,disabled:false}) |
          .disabled=$disabled)' <<<"${old_usage}")
    temp=$(mktemp "${STATE_DIR}/quota-command.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${usage}" >"${temp}"
    install -m 0600 "${temp}" "${QUOTA_USAGE_FILE}"
    save_state
    if [[ "${old_disabled}" != "${new_disabled}" ]] && ! (rebuild_traffic_runtime); then
        USER_ACCOUNTS=${old_accounts}
        save_state
        printf '%s\n' "${old_usage}" >"${temp}"
        install -m 0600 "${temp}" "${QUOTA_USAGE_FILE}"
        end_quota_maintenance
        die "修改用户配额后应用运行时状态失败，已恢复原配置"
    fi
    end_quota_maintenance
    success "用户 ${user} 的月度配额已设置为 ${quota} GB；本月已用量未清零"
    show_quota_status
}

quota_reset_user() {
    local user=${1:-} old_usage usage old_disabled current_up=0 current_down=0 stats temp
    (($# == 1)) || die "用法：easy_all quota-reset <用户名>"
    require_root
    collect_installed_state
    quota_enabled || die "当前未启用月度用户流量配额"
    validate_quota_user "${user}"
    quota_sync_usage
    begin_quota_maintenance
    initialize_quota_usage
    old_usage=$(<"${QUOTA_USAGE_FILE}")
    old_disabled=$(jq -r --arg user "${user}" '.users[$user].disabled // false' <<<"${old_usage}")
    if [[ "${old_disabled}" != "true" ]]; then
        stats=$("${XRAY_BIN}" api statsquery --server="${QUOTA_API_LISTEN}") \
            || die "读取 Xray 用户流量统计失败"
        current_up=$(jq -r --arg name "user>>>easy_all.${user}>>>traffic>>>uplink" \
            '[.stat[]?|select(.name==$name)|.value][0] // 0' <<<"${stats}")
        current_down=$(jq -r --arg name "user>>>easy_all.${user}>>>traffic>>>downlink" \
            '[.stat[]?|select(.name==$name)|.value][0] // 0' <<<"${stats}")
    fi
    usage=$(jq -c --arg user "${user}" --argjson up "${current_up}" \
        --argjson down "${current_down}" '
        .users[$user]={used_bytes:0,last_uplink:$up,last_downlink:$down,disabled:false}' \
        <<<"${old_usage}")
    temp=$(mktemp "${STATE_DIR}/quota-command.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${usage}" >"${temp}"
    install -m 0600 "${temp}" "${QUOTA_USAGE_FILE}"
    if [[ "${old_disabled}" == "true" ]] && ! (rebuild_traffic_runtime); then
        printf '%s\n' "${old_usage}" >"${temp}"
        install -m 0600 "${temp}" "${QUOTA_USAGE_FILE}"
        end_quota_maintenance
        die "重置用户流量后恢复运行时状态失败，已恢复原统计状态"
    fi
    end_quota_maintenance
    success "用户 ${user} 的本月已用流量已清零；月度额度和凭据保持不变"
    show_quota_status
}
