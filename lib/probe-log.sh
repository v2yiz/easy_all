#!/usr/bin/env bash

# 直连 TCP 443 主动探测日志（design v3）：
#   * 固定资源名与所有权：iptables filter INPUT 的一条限速 LOG 规则、一个 oneshot unit、
#     一个 journald drop-in（全局 30 天保留上限）；
#   * 规则重放/查询/删除共用同一匹配口径：同一 `-A INPUT` 行内同时包含
#     `--dport 443` 与 `--log-prefix "GFW_CHK: "`；
#   * `run_hellogfw`：免 root 的严格 help 出口 + 需 root 的一次性分析。
#
# source 本文件不得要求 root、读取安装状态、创建临时目录或产生任何副作用：
# launcher 的免 root 帮助出口在任何安装/root 门禁之前就 source 它。

PROBE_LOG_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
PROBE_LOG_HELLOGFW_PY="${PROBE_LOG_LIB_DIR}/../scripts/hellogfw.py"

PROBE_LOG_SERVICE="easy_all-probe-log.service"
PROBE_LOG_DROPIN_NAME="99-easy_all-probe-retention.conf"
PROBE_LOG_DIRECT_PORT="443"
PROBE_LOG_LOG_PREFIX_MATCH='--log-prefix "GFW_CHK: "'
PROBE_LOG_USAGE='用法：easy_all hellogfw [--since <时间范围>] [--my-ip <IPv4> ...]'
PROBE_LOG_MODE_LIST='combined-cloudflare / combined-cloudfront / reality-cloudfront / reality-cloudflare'

# --- 固定资源路径 -------------------------------------------------------------
# SYSTEMD_SYSTEM_DIR 与 JOURNALD_CONF_DIR 是测试/隔离覆盖口；生产默认见 design §4.1。
# 每次调用重新求值，避免把宿主路径固化到 source 时刻。

probe_log_unit_dir() {
    printf '%s\n' "${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
}

probe_log_journald_dir() {
    printf '%s\n' "${JOURNALD_CONF_DIR:-/etc/systemd/journald.conf.d}"
}

probe_log_unit_file() {
    printf '%s/%s\n' "$(probe_log_unit_dir)" "${PROBE_LOG_SERVICE}"
}

probe_log_dropin_file() {
    printf '%s/%s\n' "$(probe_log_journald_dir)" "${PROBE_LOG_DROPIN_NAME}"
}

probe_log_command_path() {
    printf '%s\n' "${COMMAND_PATH:-/usr/local/bin/easy_all}"
}

# --- 内核规则：查询、匹配、计数、重放 -----------------------------------------
# 所有 iptables 子调用共享一个有界 -w，不新增第二把业务锁（父进程已持 runtime 锁，
# unit 内部入口刻意不取锁，避免等待同一把锁死锁）。

probe_log_iptables() {
    command -v iptables >/dev/null 2>&1 || return 1
    iptables -w 5 "$@"
}

# 同一 `-A INPUT` 行内同时含固定端口与固定 LOG 前缀才算本工具的规则；逐行判断，
# 不跨行拼接，也不只匹配前缀（否则会误删/误计第三方 443 LOG 规则）。
# 端口按 token 边界匹配：`--dport 4430` 不是本工具的 443 规则。
probe_log_line_is_owned() {
    local line=$1 padded
    [[ "${line}" == "-A INPUT "* ]] || return 1
    padded=" ${line} "
    [[ "${padded}" == *" --dport ${PROBE_LOG_DIRECT_PORT} "* ]] || return 1
    [[ "${line}" == *"${PROBE_LOG_LOG_PREFIX_MATCH}"* ]] || return 1
    return 0
}

probe_log_owned_rule_count() {
    local snapshot=$1 line count=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        probe_log_line_is_owned "${line}" || continue
        count=$((count + 1))
    done < <(printf '%s\n' "${snapshot}")
    printf '%s\n' "${count}"
}

# 按 shell 引号规则把 iptables -S 的一行拆成参数（只处理 `"` / `'` 与空白），
# 结果写入 PROBE_LOG_RULE_TOKENS。不经过 eval：规则文本来自 iptables 输出，仍按数据处理。
PROBE_LOG_RULE_TOKENS=()
probe_log_split_rule_line() {
    local line=$1 token="" quote="" char i
    PROBE_LOG_RULE_TOKENS=()
    for ((i = 0; i < ${#line}; i++)); do
        char=${line:i:1}
        if [[ -n "${quote}" ]]; then
            if [[ "${char}" == "${quote}" ]]; then
                quote=""
            else
                token+="${char}"
            fi
            continue
        fi
        case "${char}" in
        '"' | "'") quote=${char} ;;
        ' ' | $'\t')
            [[ -z "${token}" ]] || { PROBE_LOG_RULE_TOKENS+=("${token}"); token=""; }
            ;;
        *) token+="${char}" ;;
        esac
    done
    [[ -z "${token}" ]] || PROBE_LOG_RULE_TOKENS+=("${token}")
}

# 一条自有规则的精确删除：丢掉 `-A INPUT` 两个 token，其余作为规则规格交给 -D，
# 因此历史网卡形式（-i <iface> 与 ! -i lo）都能回收。
probe_log_delete_rule_line() {
    local -a spec
    probe_log_split_rule_line "$1"
    ((${#PROBE_LOG_RULE_TOKENS[@]} >= 3)) || return 1
    spec=("${PROBE_LOG_RULE_TOKENS[@]:2}")
    probe_log_iptables -D INPUT "${spec[@]}"
}

probe_log_delete_owned_rules() {
    local snapshot=$1 line failed=0
    while IFS= read -r line || [[ -n "${line}" ]]; do
        [[ -n "${line}" ]] || continue
        probe_log_line_is_owned "${line}" || continue
        probe_log_delete_rule_line "${line}" || failed=1
    done < <(printf '%s\n' "${snapshot}")
    return "${failed}"
}

# 默认公网网卡：取 `ip -4 route show default` 第一条带 dev 的默认路由。
probe_log_default_iface() {
    local output line rest iface found=""
    command -v ip >/dev/null 2>&1 || return 1
    output=$(ip -4 route show default 2>/dev/null) || return 1
    while IFS= read -r line; do
        [[ "${line}" == *" dev "* ]] || continue
        rest=${line#*dev }
        iface=${rest%% *}
        [[ -n "${iface}" ]] || continue
        found=${iface}
        break
    done <<<"${output}"
    [[ -n "${found}" ]] || return 1
    printf '%s\n' "${found}"
}

PROBE_LOG_RULE_LIMIT=(--syn -m limit --limit 30/min --limit-burst 60
    -j LOG --log-prefix "GFW_CHK: " --log-level 4)

# rule-only 重放：先成功读取快照（查询失败与「0 条」严格区分），再删除全部自有规则，
# 最后插入一条当前规则并校验恰一条。不写 unit/drop-in，也不取 runtime 锁。
probe_log_rules_replay() {
    local snapshot iface count
    snapshot=$(probe_log_iptables -S INPUT) || return 1
    probe_log_delete_owned_rules "${snapshot}" || return 1
    if iface=$(probe_log_default_iface); then
        probe_log_iptables -I INPUT 1 -i "${iface}" -p tcp --dport "${PROBE_LOG_DIRECT_PORT}" \
            "${PROBE_LOG_RULE_LIMIT[@]}" || return 1
    else
        # 无默认路由时保守记录所有非回环接口：不能退化成不限接口，也不能静默漏掉公网入口。
        probe_log_iptables -I INPUT 1 ! -i lo -p tcp --dport "${PROBE_LOG_DIRECT_PORT}" \
            "${PROBE_LOG_RULE_LIMIT[@]}" || return 1
    fi
    snapshot=$(probe_log_iptables -S INPUT) || return 1
    count=$(probe_log_owned_rule_count "${snapshot}")
    [[ "${count}" == "1" ]] || return 1
}

# rule-only 清理：只按固定规则签名删除，不读取也不猜测 PROTOCOL。
probe_log_rules_remove() {
    local snapshot
    snapshot=$(probe_log_iptables -S INPUT) || return 1
    probe_log_delete_owned_rules "${snapshot}" || return 1
    snapshot=$(probe_log_iptables -S INPUT) || return 1
    [[ "$(probe_log_owned_rule_count "${snapshot}")" == "0" ]]
}

# --- unit 与 journald drop-in -------------------------------------------------

probe_log_unit_content() {
    printf '[Unit]\n'
    printf 'Description=easy_all direct 443 active-probing kernel log\n'
    printf 'After=network-online.target ufw.service\n'
    printf 'Wants=network-online.target\n'
    printf '\n'
    printf '[Service]\n'
    printf 'Type=oneshot\n'
    printf 'RemainAfterExit=yes\n'
    printf 'ExecStart=%s internal-probe-log-apply\n' "$(probe_log_command_path)"
    printf 'ExecStop=%s internal-probe-log-remove-rules\n' "$(probe_log_command_path)"
    printf '\n'
    printf '[Install]\n'
    printf 'WantedBy=multi-user.target\n'
}

# drop-in 的完整有效内容只有这两行：不带 SystemMaxUse，避免额外触发基于容量的 vacuum。
probe_log_dropin_content() {
    printf '[Journal]\n'
    printf 'MaxRetentionSec=30day\n'
}

probe_log_write_file() {
    local target=$1 content=$2 tmp
    install -d -m 0755 "$(dirname -- "${target}")" || return 1
    tmp=$(mktemp "${target}.XXXXXX") || return 1
    if ! printf '%s\n' "${content}" >"${tmp}" || ! chmod 0644 "${tmp}"; then
        rm -f -- "${tmp}"
        return 1
    fi
    mv -f -- "${tmp}" "${target}" || { rm -f -- "${tmp}"; return 1; }
}

probe_log_retention_notice() {
    info "MaxRetentionSec=30day 是 systemd-journald 的全局保留上限（影响主机全部 journal，超时清理后无法恢复，不设容量上限）"
}

# 直连模式的探测同步：写 unit 与 drop-in，daemon-reload、enable 后必须 restart 强制重放，
# 并显式重启 journald 让 30 天上限立即生效。任一步失败都使调用方非零，不得报成功。
probe_log_enable_and_replay() {
    local unit_file dropin_file
    unit_file=$(probe_log_unit_file)
    dropin_file=$(probe_log_dropin_file)
    probe_log_write_file "${unit_file}" "$(probe_log_unit_content)" \
        || { warn "写入 ${unit_file} 失败；直连 TCP 443 探测日志未启用"; return 1; }
    probe_log_write_file "${dropin_file}" "$(probe_log_dropin_content)" \
        || { warn "写入 ${dropin_file} 失败；systemd-journald 全局 30 天保留上限未生效"; return 1; }
    systemctl daemon-reload >/dev/null 2>&1 \
        || { warn "systemctl daemon-reload 失败；直连 TCP 443 探测日志未启用"; return 1; }
    systemctl enable "${PROBE_LOG_SERVICE}" >/dev/null 2>&1 \
        || { warn "启用 ${PROBE_LOG_SERVICE} 失败；直连 TCP 443 探测日志未启用"; return 1; }
    systemctl restart systemd-journald >/dev/null 2>&1 \
        || { warn "已写入 ${dropin_file}，但重启 systemd-journald 失败：systemd-journald 全局 30 天保留上限可能尚未生效"; return 1; }
    # restart 的 ExecStop/ExecStart 就是强制重放机制：enable --now 或单纯写文件都不能代替。
    systemctl restart "${PROBE_LOG_SERVICE}" >/dev/null 2>&1 \
        || { warn "重启 ${PROBE_LOG_SERVICE} 失败；内核采集规则未重放，请执行 sudo easy_all apply 重试"; return 1; }
    systemctl is-active --quiet "${PROBE_LOG_SERVICE}" \
        || { warn "${PROBE_LOG_SERVICE} 未处于 active 状态；内核采集规则可能未生效"; return 1; }
    probe_log_assert_single_rule \
        || { warn "内核 TCP 443 GFW_CHK: 采集规则缺失或不唯一；请修复后执行 sudo easy_all apply"; return 1; }
    info "已启用直连 TCP 443 探测日志（iptables LOG，前缀 GFW_CHK:，限速 30/min）"
    probe_log_retention_notice
}

probe_log_assert_single_rule() {
    local snapshot
    snapshot=$(probe_log_iptables -S INPUT) || return 1
    [[ "$(probe_log_owned_rule_count "${snapshot}")" == "1" ]]
}

# 清理：确认可查询/删除 → 停用 unit → 显式 rule-only 删除 → 删 unit 与 drop-in →
# daemon-reload 与重启 journald → 复核 0 条。缺工具/查询失败/删除失败都不得当成已清理。
probe_log_resources_present() {
    if [[ -n "${STATE_FILE:-}" && -e "${STATE_FILE}" ]]; then
        return 0
    fi
    if [[ -e "$(probe_log_unit_file)" || -e "$(probe_log_dropin_file)" ]]; then
        return 0
    fi
    return 1
}

remove_probe_log() {
    local unit_file dropin_file snapshot count failed=0 had_unit=0 had_dropin=0
    unit_file=$(probe_log_unit_file)
    dropin_file=$(probe_log_dropin_file)
    if ! command -v iptables >/dev/null 2>&1; then
        # 缺工具不等于内核没有规则：已安装或有 unit/drop-in 证据时按「可能仍有规则」失败。
        if probe_log_resources_present; then
            warn "缺少 iptables，无法确认并清除 TCP 443 GFW_CHK: 采集规则；已保留本机状态与 easy_all 命令，安装 iptables 后重试"
            return 1
        fi
        return 0
    fi
    snapshot=$(probe_log_iptables -S INPUT) \
        || { warn "无法查询 iptables INPUT 规则，不能确认 TCP 443 GFW_CHK: 规则已清除；已保留本机状态与 easy_all 命令，修正后重试"; return 1; }
    [[ ! -e "${unit_file}" ]] || had_unit=1
    [[ ! -e "${dropin_file}" ]] || had_dropin=1
    if ((had_unit == 0 && had_dropin == 0)) \
        && [[ "$(probe_log_owned_rule_count "${snapshot}")" == "0" ]]; then
        return 0
    fi
    # unit 已不存在也尝试 disable/stop：清掉可能残留的 enable 符号链接，避免下次开机
    # 重跑旧单元。两者失败只告警继续——真正的判定交给随后的显式规则删除与复核。
    if ! systemctl disable --now "${PROBE_LOG_SERVICE}" >/dev/null 2>&1; then
        warn "停用 ${PROBE_LOG_SERVICE} 失败（unit 可能已不存在）；继续按固定规则签名清理"
    fi
    if ! systemctl stop "${PROBE_LOG_SERVICE}" >/dev/null 2>&1; then
        warn "停止 ${PROBE_LOG_SERVICE} 失败（unit 可能已不存在）；继续清理规则与文件"
    fi
    # ExecStop 可能已经删掉规则：按停用后的最新快照删除，避免按过期快照误删失败。
    snapshot=$(probe_log_iptables -S INPUT) \
        || { warn "停用 ${PROBE_LOG_SERVICE} 后无法查询 iptables INPUT 规则；已保留本机状态与 easy_all 命令"; return 1; }
    probe_log_delete_owned_rules "${snapshot}" \
        || { warn "删除 TCP 443 GFW_CHK: 采集规则失败；已保留本机状态与 easy_all 命令，修正后重试"; return 1; }
    if ((had_unit == 1 || had_dropin == 1)); then
        rm -f -- "${unit_file}" "${dropin_file}" \
            || { warn "删除 ${unit_file} 或 ${dropin_file} 失败"; failed=1; }
        systemctl daemon-reload >/dev/null 2>&1 || true
    fi
    if ((had_dropin == 1)) && [[ ! -e "${dropin_file}" ]]; then
        systemctl restart systemd-journald >/dev/null 2>&1 \
            || { warn "已删除 ${dropin_file}，但重启 systemd-journald 失败：运行中的 journald 可能仍在沿用全局保留上限"; failed=1; }
    fi
    snapshot=$(probe_log_iptables -S INPUT) \
        || { warn "无法复核 TCP 443 GFW_CHK: 采集规则是否已清除"; return 1; }
    count=$(probe_log_owned_rule_count "${snapshot}")
    if [[ "${count}" != "0" ]]; then
        warn "仍有 ${count} 条 TCP 443 GFW_CHK: 采集规则残留；已保留本机状态与 easy_all 命令，修正后重试"
        failed=1
    fi
    ((failed == 0))
}

# --- 分析前置校验 -------------------------------------------------------------
# 只证明「采集规则存在」这一件事：不启动分析、不在查询命令里自动修规则。
# 测试可用 HELLOGFW_IPTABLES_RULES_FILE 提供 iptables -S INPUT 快照；离线日志样本不能替代它。

probe_log_capture_rules_ok() {
    local snapshot
    if [[ -n "${HELLOGFW_IPTABLES_RULES_FILE:-}" ]]; then
        [[ -f "${HELLOGFW_IPTABLES_RULES_FILE}" && -r "${HELLOGFW_IPTABLES_RULES_FILE}" ]] || return 1
        snapshot=$(<"${HELLOGFW_IPTABLES_RULES_FILE}") || return 1
    else
        snapshot=$(probe_log_iptables -S INPUT) || return 1
    fi
    (($(probe_log_owned_rule_count "${snapshot}") > 0))
}

# --- hellogfw CLI -------------------------------------------------------------
# 只用 shell 内建与 printf：免 root 帮助出口在 log.sh 未加载时也会调用本函数。

run_hellogfw() {
    local -a python_args=()
    local arg help=0
    while (($# > 0)); do
        arg=$1
        case "${arg}" in
        -h | --help)
            help=1
            python_args+=("${arg}")
            shift
            ;;
        --since)
            if (($# < 2)) || [[ "$2" == -* ]]; then
                printf '%s\n' "${PROBE_LOG_USAGE}" >&2
                printf '%s\n' '错误：--since 需要一个不以 - 开头的时间范围值' >&2
                return 1
            fi
            python_args+=(--since "$2")
            shift 2
            ;;
        --my-ip)
            if (($# < 2)) || [[ "$2" == -* ]]; then
                printf '%s\n' "${PROBE_LOG_USAGE}" >&2
                printf '%s\n' '错误：--my-ip 需要一个 IPv4 地址' >&2
                return 1
            fi
            python_args+=(--my-ip "$2")
            shift 2
            ;;
        *)
            printf '%s\n' "${PROBE_LOG_USAGE}" >&2
            printf '错误：不支持参数 %s（直连端口固定 443，没有 --port）\n' "${arg}" >&2
            return 1
            ;;
        esac
    done
    # 前置检查顺序固定：先 python3，再分析脚本；不得把缺 Python 误报成运行时损坏。
    command -v python3 >/dev/null 2>&1 \
        || { printf '%s\n' '缺少 python3（请先安装 python3）' >&2; return 1; }
    [[ -f "${PROBE_LOG_HELLOGFW_PY}" ]] \
        || { printf '运行时脚本缺失：%s\n' "${PROBE_LOG_HELLOGFW_PY}" >&2; return 1; }
    # help 直接转交 Python 打印帮助，跳过规则与 journal 检查。
    ((help == 1)) || probe_log_capture_rules_ok \
        || {
            printf '%s\n' '无法确认采集规则（TCP 443，前缀 GFW_CHK:）；探测日志当前不可用。' >&2
            printf '%s\n' '请先修复采集：sudo easy_all apply 或 sudo systemctl restart easy_all-probe-log.service，然后重试。' >&2
            return 1
        }
    python3 "${PROBE_LOG_HELLOGFW_PY}" "${python_args[@]}"
}
