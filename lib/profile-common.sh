#!/usr/bin/env bash

# Shared Profile plumbing, input validation and state normalization.

make_temp_dir() {
    mktemp -d "${RUNTIME_TMP}/part.XXXXXX"
}

download_https_file() {
    local url=$1 destination=$2 description=${3:-文件}
    local -a wget_args=(
        --https-only
        --secure-protocol=TLSv1_2
        --timeout=20
        --read-timeout=45
        --tries=5
        --retry-connrefused
        --waitretry=2
        --max-redirect=10
        --output-file=/dev/stderr
        --show-progress
        -O "${destination}"
    )
    timeout 10m wget "${wget_args[@]}" "${url}" \
        || die "下载${description}失败：${url}"
    [[ -s "${destination}" ]] || die "下载${description}失败：返回空文件"
}

read_bilingual() {
    local label=$1 variable=$2 silent=${3:-0} input
    printf '%s\n' "${label}" >&2
    if [[ "${silent}" == "1" ]]; then
        read_prompt '> ' input 1
        printf '\n' >&2
    else
        read_prompt '> ' input
    fi
    printf -v "${variable}" '%s' "${input}"
}

prompt_value() {
    local label=$1 default=${2:-} value
    if [[ -n "${default}" ]]; then
        read_bilingual "${label} [${default}]（直接回车使用默认值）:" value
        printf '%s' "${value:-${default}}"
    else
        read_bilingual "${label}:" value
        printf '%s' "${value}"
    fi
}

# 静默读进目标变量：必须在调用方当前 shell 里直接调用，不得包进 $( )：
# 实测子 shell 里的终端读会不等输入就返回空（安装模式 4/5 的 Token/AWS 提示就卡在这里）。
# 无终端时返回非零，由调用方给出提示。
prompt_secret_into() {
    local variable=$1 label=$2
    [[ -t 0 ]] || return 1
    read_bilingual "${label}，粘贴后按回车键；输入过程不会显示任何字符:" "${variable}" 1
}

# 只用于“是否清理 / 是否继续”这类确认，不会读进参数值。
read_confirmation() {
    local label=$1 variable=$2 input
    printf '%s\n' "${label}" >&2
    read_prompt '> ' input
    input="${input#"${input%%[![:space:]]*}"}"
    input="${input%"${input##*[![:space:]]}"}"
    printf -v "${variable}" '%s' "${input}"
}

# --- CDN 优选连接地址（cdnEdgeAddress）的安装交互 -------------------------------
# 模式 4/5 拼 CloudFront 泛域名后缀，模式 2/3 拼 Cloudflare 泛域名后缀（由 WeTest 公布并解析）。
CDN_EDGE_CLOUDFRONT_SUFFIX="cloudfront.182682.xyz"
CDN_EDGE_CLOUDFLARE_SUFFIX="cloudflare.182682.xyz"
# 安装时生成的优选地址形态：10 位前缀 + 当前模式的泛域名后缀（首位字母，后九位字母或数字）。
CDN_EDGE_PREFIX_PATTERN='^([a-z][a-z0-9]{9})\.(cloudfront|cloudflare)\.182682\.xyz$'
CDN_EDGE_LETTERS="abcdefghijklmnopqrstuvwxyz"
CDN_EDGE_ALNUM="0123456789abcdefghijklmnopqrstuvwxyz"

cdn_edge_mode_suffix() {
    case "${PROTOCOL:-}" in
    cloudfront | combined-cloudfront) printf '%s' "${CDN_EDGE_CLOUDFRONT_SUFFIX}" ;;
    cloudflare | combined-cloudflare) printf '%s' "${CDN_EDGE_CLOUDFLARE_SUFFIX}" ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

# 纯展示用的随机前缀：openssl 取 10 个字节，首位映射到 a-z、其余映射到 0-9a-z。
# 模偏差（256 不能被 26/36 整除）只影响字面分布，不承担安全强度，不为此引额外依赖。
# openssl 不可用时直接 die：返回空默认值会让提示循环永远无法退出。
generate_cdn_edge_prefix() {
    local hex byte index out=""
    hex=$(openssl rand -hex 10) || die "生成 CDN 优选前缀失败：缺少可用的 openssl"
    for index in 0 1 2 3 4 5 6 7 8 9; do
        byte=$((16#${hex:$((index * 2)):2}))
        if ((index == 0)); then
            out+=${CDN_EDGE_LETTERS:$((byte % 26)):1}
        else
            out+=${CDN_EDGE_ALNUM:$((byte % 36)):1}
        fi
    done
    printf '%s' "${out}"
}

# 提示默认值：已有安装生成的前缀形态沿用原前缀，其余一律生成新随机前缀。
# 自定义优选域名与非法配置不会走到这里（由 collect_cdn_edge_address 先分流）。
cdn_edge_default_prefix() {
    local edge
    edge=$(jq -r '.cdnEdgeAddress // ""' <<<"${SUBSCRIPTION_CONFIG:-}" 2>/dev/null) || return 1
    edge=$(printf '%s' "${edge}" | tr '[:upper:]' '[:lower:]')
    if [[ "${edge}" =~ ${CDN_EDGE_PREFIX_PATTERN} ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    generate_cdn_edge_prefix
}

# 写入判定（不读 stdin）：10 位前缀拼当前模式后缀；其余输入返回非零且零副作用。
# jq 自身失败是配置已被改坏，不能退化成“输入非法”而陷入无限重填，直接 die。
cdn_edge_store_answer() {
    local answer=${1:-} updated
    if [[ "${answer}" =~ ^[a-z][a-z0-9]{9}$ ]]; then
        updated=$(jq -c --arg a "${answer}.$(cdn_edge_mode_suffix)" '.cdnEdgeAddress=$a' \
            <<<"${SUBSCRIPTION_CONFIG}") || die "更新订阅配置失败"
    else
        return 1
    fi
    SUBSCRIPTION_CONFIG=${updated}
}

# 循环读入：提示文案固定含默认值；非法输入用 warn（stdout）说明后重印同一提示。
cdn_edge_prompt_loop() {
    local default=${1:-} answer
    while :; do
        read_bilingual "CDN 优选前缀 [${default}]（回车采用）：" answer
        cdn_edge_store_answer "${answer:-${default}}" && return 0
        warn "CDN 优选前缀无效：只能输入 10 位前缀（首位字母，其后字母或数字）"
    done
}

# 交互终端判定：生产只认 stdin 终端；自动化测试通过覆盖本函数模拟交互终端。
# 生产不提供环境变量旁路（同 dns_takeover_interactive 惯例）。
cdn_edge_interactive() {
    [[ -t 0 ]]
}

# 安装收集器（模式 2-5）：把用户确认的优选地址写进 SUBSCRIPTION_CONFIG，
# 随后由调用方的 cdn_apply_subscription_config 强校验并派生 CF_EDGE_ADDRESS。
collect_cdn_edge_address() {
    local normalized edge default
    cdn_edge_interactive || return 0
    # 一次无副作用试运行：整份 JSON 不可解析、非对象 JSON、字段非法都落到这里。
    # 不提示也不改配置，交由随后的 cdn_apply_subscription_config 按既有路径拒绝。
    normalized=$(normalize_subscription_config "${SUBSCRIPTION_CONFIG:-}" \
        "$(cdn_local_node_names)" 2>/dev/null) || return 0
    edge=$(jq -r '.cdnEdgeAddress // ""' <<<"${normalized}") || return 1
    # 自定义优选域名（非安装生成的前缀形态）绝不提示、不被随机值覆盖。
    if [[ -n "${edge}" && ! "${edge}" =~ ${CDN_EDGE_PREFIX_PATTERN} ]]; then
        info "当前 CDN 优选地址 ${edge}；改地址或关闭请在安装后执行 sudo easy_all edit-sub"
        return 0
    fi
    # 命令替换里的 die 只结束子 shell：这里显式判空，避免空默认值进入提示循环。
    default=$(cdn_edge_default_prefix) || die "生成 CDN 优选前缀失败：缺少可用的 openssl"
    cdn_edge_prompt_loop "${default}"
}

restore_state_file() {
    local backup=$1 target=$2 temp
    temp=$(mktemp "$(dirname -- "${target}")/state.env.XXXXXX") || {
        fail "创建状态恢复暂存文件失败"
        return 1
    }
    cleanup_files+=("${temp}")
    if ! { install -m 0600 "${backup}" "${temp}" \
        && mv -f -- "${temp}" "${target}"; }; then
        fail "原子恢复状态文件失败：${target}"
        return 1
    fi
}

validate_domain() {
    local domain=$1 label tld
    local -a labels
    [[ ${#domain} -ge 4 && ${#domain} -le 253 ]] || return 1
    [[ "${domain}" == *.* ]] || return 1
    [[ "${domain}" != \*.* ]] || return 1
    [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "${domain}" != .* && "${domain}" != *. ]] || return 1
    [[ "${domain}" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"${domain}"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    tld=${labels[$((${#labels[@]} - 1))]}
    [[ "${tld}" =~ ^[A-Za-z0-9-]{2,}$ ]]
}

normalize_domain() {
    local domain=$1
    domain=${domain%.}
    tr '[:upper:]' '[:lower:]' <<<"${domain}" | tr -d '\n'
}

validate_ipv4() {
    local ip=$1 octet
    local -a octets
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"${ip}"
    for octet in "${octets[@]}"; do
        ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
    done
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_sub_download_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

normalize_sub_download_name() {
    local name=${1:-}
    name=${name%.[Yy][Aa][Mm][Ll]}
    name=${name%.[Yy][Mm][Ll]}
    if validate_sub_download_name "${name}"; then
        printf '%s' "${name}"
    else
        printf '%s' "${DEFAULT_SUB_DOWNLOAD_NAME}"
    fi
}

# 旧栈曾用 policy-rc.d 抑制 nginx 在 apt 窗口内自启；本版本仍用同一事务机制，
# 以避免任何被 APT 拉起的服务占用已检查过的端口。

# --- apt 窗口内的服务自启抑制 ---------------------------------------------------
# Debian 的 nginx 包在 postinst 里就把默认站点拉起来，`apt-get install` 还没返回 80 已经被
# 占住，而这正是 SSH 最容易断线的时段。用 Debian 官方 policy-rc.d(exit 101) 只抑制这一段。
EASY_ALL_SUSPEND_SERVICE_START=0

easy_all_policy_rc_file() {
    printf '%s' "${EASY_ALL_POLICY_RC_OVERRIDE:-/usr/sbin/policy-rc.d}"
}

# 事务状态放在稳定路径（不是 RUNTIME_TMP）：进程被 SIGKILL 时，下一次入口还能据此
# 恢复原策略，否则遗留的 exit 101 会永久阻止所有服务启动。
easy_all_policy_state_dir() {
    printf '%s' "${EASY_ALL_POLICY_STATE_DIR_OVERRIDE:-/var/lib/easy_all}"
}

easy_all_policy_pending_file() {
    printf '%s/policy-rc.pending' "$(easy_all_policy_state_dir)"
}

easy_all_policy_backup_file() {
    printf '%s/policy-rc.backup' "$(easy_all_policy_state_dir)"
}

# 幂等恢复。两条安全约束：
#   1) 事务内容必须完整合法（HAD_PREVIOUS 只能是 0/1），损坏时保留事务与备份，绝不把
#      “读不出来”当成“原来没有 policy”，否则会删掉安装前的系统策略。
#   2) 只允许事务持有者本人、或持写锁且确认原持有者已退出的进程去恢复；未持锁的进程
#      EXIT 时若拿不到锁就跳过，避免把另一个仍在进行的 apt 的抑制撤掉。
# kill -0 对 EPERM 也会失败（非 root 查 root 进程），需要区分“不存在”与“无权发信号”。
process_alive() {
    local pid=${1:-} err=""
    [[ "${pid}" =~ ^[0-9]+$ ]] || return 1
    [[ ! -d "/proc/${pid}" ]] || return 0
    kill -0 "${pid}" 2>/dev/null && return 0
    err=$(kill -0 "${pid}" 2>&1) || true
    [[ "${err}" == *ermitted* ]]
}

recover_pending_service_policy() {
    local pending backup target had_previous owner acquired=0
    pending=$(easy_all_policy_pending_file)
    backup=$(easy_all_policy_backup_file)
    target=$(easy_all_policy_rc_file)
    [[ -f "${pending}" ]] || { EASY_ALL_SUSPEND_SERVICE_START=0; return 0; }

    had_previous=$(sed -n 's/^HAD_PREVIOUS=//p' "${pending}" | tail -n 1)
    owner=$(sed -n 's/^OWNER_PID=//p' "${pending}" | tail -n 1)

    # 先校验内容：损坏的事务无论归属如何都不能被解释成“原来没有 policy”。
    case "${had_previous}" in
    0 | 1) ;;
    *)
        warn "事务 ${pending} 内容不完整（HAD_PREVIOUS=${had_previous:-空}）；已保留事务与备份，未改动 ${target}"
        return 1
        ;;
    esac

    if [[ "${owner}" != "$$" ]]; then
        if ((${RUNTIME_WRITE_LOCK_DEPTH:-0} == 0)); then
            declare -F try_acquire_runtime_write_lock >/dev/null 2>&1 || return 0
            try_acquire_runtime_write_lock 0 || return 0
            acquired=1
        fi
        if process_alive "${owner}"; then
            ((acquired == 0)) || release_runtime_write_lock
            return 0
        fi
    fi

    case "${had_previous}" in
    0)
        rm -f -- "${target}" || { ((acquired == 0)) || release_runtime_write_lock; return 1; }
        ;;
    1)
        [[ -s "${backup}" ]] || {
            warn "事务 ${pending} 显示安装前存在 policy，但备份缺失或为空：${backup}；已保留事务，请人工核对 ${target}"
            ((acquired == 0)) || release_runtime_write_lock
            return 1
        }
        cp -p -- "${backup}" "${target}" || { ((acquired == 0)) || release_runtime_write_lock; return 1; }
        ;;
    esac

    rm -f -- "${pending}" "${backup}" || { ((acquired == 0)) || release_runtime_write_lock; return 1; }
    EASY_ALL_SUSPEND_SERVICE_START=0
    ((acquired == 0)) || release_runtime_write_lock
    return 0
}

suspend_service_start() {
    local target dir had_previous=0
    target=$(easy_all_policy_rc_file)
    dir=$(easy_all_policy_state_dir)
    # 先自愈上一次遗留事务，再开始新事务。
    recover_pending_service_policy || return 1
    if [[ -f "$(easy_all_policy_pending_file)" ]]; then
        warn "存在未能恢复的 policy 事务（可能是 PID 复用），拒绝覆盖原备份：$(easy_all_policy_pending_file)"
        return 1
    fi
    install -d -m 0700 "${dir}" || return 1
    if [[ -e "${target}" ]]; then
        cp -p -- "${target}" "$(easy_all_policy_backup_file)" || return 1
        had_previous=1
    else
        rm -f -- "$(easy_all_policy_backup_file)" || return 1
    fi
    # 同目录 rename 发布：避免留下“文件已存在但内容未完”的半截事务。
    printf 'HAD_PREVIOUS=%s\nOWNER_PID=%s\n' "${had_previous}" "$$" \
        >"$(easy_all_policy_pending_file).tmp" \
        && mv -f -- "$(easy_all_policy_pending_file).tmp" \
            "$(easy_all_policy_pending_file)" \
        || { rm -f -- "$(easy_all_policy_pending_file).tmp"; return 1; }
    EASY_ALL_SUSPEND_SERVICE_START=1
    printf '#!/bin/sh\n# temporary: written by easy_all for one apt run\nexit 101\n' \
        >"${target}" || { recover_pending_service_policy || true; return 1; }
    chmod 0755 "${target}" || { recover_pending_service_policy || true; return 1; }
    return 0
}

restore_service_start_policy() {
    # 只有真正恢复成功才清掉事务记录与标志，失败保留给下一次入口重试。
    recover_pending_service_policy
}


# --- 中断安装的自愈：进度标记、残留识别与端口守卫 ------------------------------
#
# 一次安装被 SSH 断线打断后，本机可能同时留下「已写好的服务单元」「未完成的状态
# 目录」和「已写好的服务单元」。重跑时必须能区分这些自身残留与真正的第三方占用，否则
# 用户会永久卡在「仅支持专用 VPS」而没有任何自救手段。下面这组函数是唯一的判定入口。

install_progress_file() {
    printf '%s' "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE:-/var/lib/easy_all/install-progress.env}"
}

install_progress_field() {
    local key=$1 file line
    file=$(install_progress_file)
    [[ -f "${file}" ]] || return 1
    line=$(grep -E "^${key}=" "${file}" | tail -n 1) || return 1
    printf '%s' "${line#*=}"
}

install_progress_set() {
    local key=$1 value=$2 file dir stage tmp
    file=$(install_progress_file)
    dir=$(dirname -- "${file}")
    install -d -m 0700 "${dir}" 2>/dev/null || return 1
    tmp=$(mktemp "${dir}/.install-progress.XXXXXX") || return 1
    {
        [[ ! -f "${file}" ]] || grep -vE "^${key}=" "${file}" || true
        printf '%s=%s\n' "${key}" "${value}"
    } >"${tmp}" || { rm -f -- "${tmp}"; return 1; }
    # 同目录 rename：读者只会看到旧内容或完整新内容，不会读到半截标记。
    mv -f -- "${tmp}" "${file}" || { rm -f -- "${tmp}"; return 1; }
}

install_progress_begin() {
    local profile=$1 chain=${2:-} file dir
    file=$(install_progress_file)
    dir=$(dirname -- "${file}")
    if ! install -d -m 0700 "${dir}" 2>/dev/null; then
        warn "无法创建安装进度目录 ${dir}；中断后不会自动识别残留"
        return 0
    fi
    {
        printf 'SCHEMA=%s\n' "${EASY_ALL_STATE_SCHEMA_VERSION}"
        printf 'PROFILE=%s\n' "${profile}"
        [[ -z "${chain}" ]] || printf 'CHAIN=%s\n' "${chain}"
        printf 'STAGE=start\n'
        printf 'STARTED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'UPDATED_AT=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    } >"${file}.tmp" 2>/dev/null \
        && mv -f -- "${file}.tmp" "${file}" 2>/dev/null \
        || { rm -f -- "${file}.tmp"; warn "无法写入安装进度标记 ${file}；中断后不会自动识别残留"; }
}

install_progress_stage() {
    install_progress_set STAGE "$1" || true
    install_progress_set UPDATED_AT "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || true
}

install_progress_clear() {
    local file
    file=$(install_progress_file)
    rm -f -- "${file}" 2>/dev/null || true
    rmdir -- "$(dirname -- "${file}")" 2>/dev/null || true
}


# --- 安装失败诊断与清理确认 ------------------------------------------------
# 中途失败时要说清楚“哪个阶段、哪一行、什么命令”，并由用户决定是否清理。

INSTALL_FAILURE_ARMED=0
INSTALL_FAILURE_HANDLED=0
INSTALL_FAILURE_REPORTED=0
INSTALL_FAILURE_MODE=""
INSTALL_FAILURE_STATUS=""
INSTALL_FAILURE_FILE=""
INSTALL_FAILURE_LINE=""
INSTALL_FAILURE_COMMAND=""

install_stage_label() {
    case "$1" in
    start) printf '启动与系统检查' ;;
    packages) printf '安装系统依赖' ;;
    tcp) printf 'TCP 加速与内核' ;;
    inputs) printf '应用安装参数' ;;
    core) printf '准备协议核心' ;;
    services) printf '服务、证书与防火墙' ;;
    cloud) printf '云端资源' ;;
    subscription) printf '生成订阅' ;;
    state) printf '保存状态' ;;
    "") printf '尚未开始' ;;
    *) printf '%s' "$1" ;;
    esac
}

# 在 install_all 开头调用：未被 if/|| 捕获的错误会记下首个失败点。
install_failure_begin() {
    INSTALL_FAILURE_MODE=${1:-${PROTOCOL:-}}
    INSTALL_FAILURE_ARMED=1
    INSTALL_FAILURE_HANDLED=0
    INSTALL_FAILURE_REPORTED=0
    # 全部用默认值展开：set -u 下任何一项缺失都不该让陷阱本身报错（否则记录不到失败点）。
    trap 'install_failure_capture "$?" "${BASH_SOURCE[0]:-}" "${LINENO:-0}" "${BASH_COMMAND:-}"' ERR
}

install_failure_capture() {
    local status=$1 file=$2 line=$3 command=$4
    [[ "${INSTALL_FAILURE_ARMED:-0}" == "1" ]] || return 0
    if (( INSTALL_FAILURE_HANDLED != 0 )); then
        return 0
    fi
    INSTALL_FAILURE_HANDLED=1
    INSTALL_FAILURE_STATUS=${status:-}
    INSTALL_FAILURE_FILE=${file:-}
    INSTALL_FAILURE_LINE=${line:-0}
    INSTALL_FAILURE_COMMAND=${command:-}
    return 0
}

install_failure_report() {
    local stage stage_label started
    [[ "${INSTALL_FAILURE_ARMED:-0}" == "1" ]] || return 0
    [[ "${INSTALL_FAILURE_REPORTED:-0}" != "1" ]] || return 0
    INSTALL_FAILURE_REPORTED=1
    stage=$(install_progress_field STAGE 2>/dev/null || true)
    started=$(install_progress_field STARTED_AT 2>/dev/null || true)
    stage_label=$(install_stage_label "${stage}")
    printf '\n' >&2
    printf '=================== 安装失败 ===================\n' >&2
    printf '模式：%s\n' "${INSTALL_FAILURE_MODE:-$(install_current_mode)}" >&2
    if [[ -n "${stage}" ]]; then
        printf '失败阶段：%s（%s）\n' "${stage}" "${stage_label}" >&2
    else
        printf '失败阶段：尚未开始（环境检查或参数预检）\n' >&2
    fi
    local location="${EASY_ALL_LAST_ERROR_SOURCE:-}"
    if [[ -z "${location}" && -n "${INSTALL_FAILURE_FILE:-}" ]]; then
        location="${INSTALL_FAILURE_FILE}:${INSTALL_FAILURE_LINE:-0}"
    fi
    if [[ -n "${location}" ]]; then
        printf '失败位置：%s\n' "${location}" >&2
    fi
    if [[ -n "${INSTALL_FAILURE_COMMAND:-}" ]]; then
        printf '失败命令：%s\n' "${INSTALL_FAILURE_COMMAND}" >&2
    fi
    [[ -z "${INSTALL_FAILURE_STATUS:-}" ]] || printf '退出码：%s\n' "${INSTALL_FAILURE_STATUS}" >&2
    if [[ -n "${EASY_ALL_LAST_ERROR:-}" ]]; then
        printf '错误信息：%s\n' "${EASY_ALL_LAST_ERROR}" >&2
    fi
    [[ -z "${started}" ]] || printf '开始时间（UTC）：%s\n' "${started}" >&2
    printf '===============================================\n' >&2
}

install_cleanup_perform() {
    # 进入实际回滚执行段：不再接受 INT/TERM，避免第二次 Ctrl+C 中断恢复。
    # 交互确认在 install_cleanup_after_failure 完成，在此之前保持可中断。
    trap '' INT TERM
    case "$1" in
    # 已拍安装前快照：按快照回滚（同时移除本次新增文件）。
    rollback) rollback_fresh_install ;;
    # 快照未完成（或尚未拍）：只清理本次安装留下的本机残留。
    partial) cleanup_partial_install ;;
    esac
}

# 由用户决定是否清理；没有终端时保持原有自动清理（避免留下半配置机器）。
install_cleanup_after_failure() {
    local action=${1:-rollback} answer=""
    if [[ -t 0 ]]; then
        read_confirmation \
            '是否清理本次安装的本机残留（已拍快照时回滚到安装前状态）？[Y/n]' answer \
            || answer=""
        if [[ -z "${answer}" || "${answer}" =~ ^[Yy] ]]; then
            # 失败路径一律写 stderr：退出时可能仍带着上层命令的输出重定向。
            if install_cleanup_perform "${action}"; then
                printf '%s\n' '已清理本次安装的本机残留；修正问题后可重新运行安装' >&2
            else
                printf '%s\n' '本机残留未完全清理；已保留安装进度标记与安装前快照，修正后可重试 sudo easy_all cleanup-partial' >&2
                residue_recovery_hint >&2 || true
            fi
            return 0
        fi
        printf '%s\n' '已保留本次安装的本机改动（未清理）' >&2
        residue_recovery_hint >&2 || true
        return 0
    fi
    if install_cleanup_perform "${action}"; then
        printf '%s\n' '非交互环境（没有终端）：已自动清理本次安装的本机残留' >&2
    else
        printf '%s\n' '非交互环境（没有终端）：本机残留未完全清理；已保留安装进度标记与安装前快照，修正后可重试 sudo easy_all cleanup-partial' >&2
        residue_recovery_hint >&2 || true
    fi
}

install_state_dir_path() {
    printf '%s' "${EASY_ALL_GUARD_STATE_DIR:-${STATE_DIR:-/etc/easy_all}}"
}

install_state_file_path() {
    printf '%s' "${EASY_ALL_GUARD_STATE_FILE:-${STATE_FILE:-$(install_state_dir_path)/state.env}}"
}

install_service_file_path() {
    printf '%s' "${EASY_ALL_GUARD_SERVICE_FILE:-${SINGBOX_SERVICE_FILE:-/etc/systemd/system/easy_all-singbox.service}}"
}

install_caddy_config_path() {
    printf '%s' "${EASY_ALL_GUARD_CADDY_CONFIG:-${CADDY_CONFIG:-/etc/easy_all/caddy/Caddyfile}}"
}

# 目录项字节数：用 find 枚举后按字节计数，不解析 ls 文本。文件名里的换行不会被命令替换
# 吃掉（单个 LF 文件名也是 2 字节，不是“空”）；find 枚举失败返回非零，调用方必须拒绝豁免。
install_dir_entries_bytes() {
    local dir=$1 bytes
    bytes=$(
        set -o pipefail
        find "${dir}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null | wc -c
    ) || return 1
    printf '%s\n' "${bytes//[[:space:]]/}"
}

# 目录项行数：只用于“恰好 N 项”的判定。含换行的文件名只会多计行、不会少计，
# 因此不会把多项误判成一项；枚举失败返回非零。
install_dir_entry_count() {
    local dir=$1 count
    count=$(
        set -o pipefail
        find "${dir}" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l
    ) || return 1
    printf '%s\n' "${count//[[:space:]]/}"
}

# 旧 FQ helper 把开机队列快照固定在 STATE_DIR/backups/qdisc。卸载后只剩这条空链时
# 它是正常产物而不是未完成安装；只接受「runtime-write.lock + backups/qdisc 全空」，
# 隐藏项、symlink、pre-install 快照与任何 qdisc 文件/.apply 都不豁免。
install_state_dir_only_empty_fq_chain() {
    local state_dir=$1 entries expected=1
    [[ -d "${state_dir}" && ! -L "${state_dir}" ]] || return 1
    [[ -d "${state_dir}/backups" && ! -L "${state_dir}/backups" ]] || return 1
    [[ -d "${state_dir}/backups/qdisc" && ! -L "${state_dir}/backups/qdisc" ]] || return 1
    # 状态目录除运行时写锁外只能有 backups 一项；backups 只能有 qdisc；qdisc 必须完全为空。
    [[ ! -e "${state_dir}/runtime-write.lock" ]] || expected=2
    entries=$(install_dir_entry_count "${state_dir}") || return 1
    [[ "${entries}" == "${expected}" ]] || return 1
    entries=$(install_dir_entry_count "${state_dir}/backups") || return 1
    [[ "${entries}" == "1" ]] || return 1
    entries=$(install_dir_entries_bytes "${state_dir}/backups/qdisc") || return 1
    [[ "${entries}" == "0" ]]
}

# 已安装（存在状态文件）时返回 1：残留判定只服务于「未安装」场景。
install_residue_reason() {
    local state_dir state_file service_file caddy_config progress stage state_entries
    state_dir=$(install_state_dir_path)
    state_file=$(install_state_file_path)
    service_file=$(install_service_file_path)
    caddy_config=$(install_caddy_config_path)
    progress=$(install_progress_file)
    [[ ! -f "${state_file}" ]] || return 1
    local -a reasons=()
    if [[ -f "${progress}" ]]; then
        stage=$(install_progress_field STAGE || true)
        reasons+=("安装进度标记${stage:+（上次中断于 ${stage} 阶段）}")
    fi
    # 运行时写锁会先创建状态目录本身；只有锁文件时不算残留，否则每次全新安装都会误报。
    # 用命令替换而不是管道：pipefail 下 ls 可能因 grep 提前退出被判成失败。
    if [[ -d "${state_dir}" ]]; then
        state_entries=$(ls -A "${state_dir}" 2>/dev/null \
            | grep -vx 'runtime-write.lock' || true)
        if [[ -n "${state_entries}" ]] \
            && ! install_state_dir_only_empty_fq_chain "${state_dir}"; then
            reasons+=("未完成的状态目录 ${state_dir}")
        fi
    fi
    if [[ -f "${service_file}" ]]; then
        reasons+=("残留服务单元 ${service_file}")
    fi
    if [[ -f "${caddy_config}" ]]; then
        reasons+=("残留 Caddy 配置 ${caddy_config}")
    fi
    ((${#reasons[@]})) || return 1
    printf '%s\n' "${reasons[@]}"
}

tcp_port_listening() {
    local port=$1 ss_cmd=${EASY_ALL_SS_CMD_OVERRIDE:-ss}
    command -v "${ss_cmd}" >/dev/null 2>&1 || return 1
    "${ss_cmd}" -H -ltn "sport = :${port}" 2>/dev/null \
        | awk 'NR {found=1} END {exit !found}'
}

tcp_port_owner() {
    local port=$1 ss_cmd=${EASY_ALL_SS_CMD_OVERRIDE:-ss}
    command -v "${ss_cmd}" >/dev/null 2>&1 || return 1
    "${ss_cmd}" -H -ltnp "sport = :${port}" 2>/dev/null \
        | sed -n 's/.*users:((\"\([^"]*\)\".*/\1/p' \
        | sort -u | paste -sd ',' -
}

residue_recovery_hint() {
    # 不要在 sudo 后接 <(...)：sudo 会关闭额外 fd，提权后的 bash 打不开 /dev/fd/NN。
    # bootstrap.sh 自己会按需 sudo，所以直接 bash <(...) 即可。
    local bootstrap='bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh)'
    if [[ -f "$(install_progress_file)" ]]; then
        printf '%s\n' \
            '请先清理上次未完成安装的残留后重试：' \
            '  sudo easy_all cleanup-partial' \
            '命令尚未注册时（上次中断早于注册命令）：' \
            "  ${bootstrap} cleanup-partial"
    else
        printf '%s\n' \
            '这些残留没有安装进度标记，无法自动判断模式，请人工核对后清理：' \
            '  /etc/easy_all、/etc/easy_all/caddy/Caddyfile 与 easy_all*.service/.timer'
    fi
}

assert_install_ports_free() {
    local argument port owner reason_text
    local -a ports=()
    for argument in "$@"; do
        # 调用方把整串端口作为一个参数传入（模式 5 的 "443 8443"）：整串交给
        # ss 会拼出 sport = :443 8443 这种非法表达式，因此必须逐端口检查。
        read -r -a ports <<<"${argument}"
        ((${#ports[@]} > 0)) || continue
        for port in "${ports[@]}"; do
            [[ -n "${port}" ]] || continue
            tcp_port_listening "${port}" || continue
            if reason_text=$(install_residue_reason); then
                owner=$(tcp_port_owner "${port}" || true)
                die "$(printf 'TCP %s 被上次未完成的 easy_all 安装残留占用%s\n残留：%s\n%s' \
                    "${port}" "${owner:+（${owner}）}" \
                    "$(printf '%s' "${reason_text}" | paste -sd ';' -)" \
                    "$(residue_recovery_hint)")"
            fi
            owner=$(tcp_port_owner "${port}" || true)
            die "TCP ${port} 已被占用${owner:+（${owner}）}；easy_all 仅支持专用 VPS"
        done
    done
}

# 每个模式对应的 profile 文件：跨模式清理时按 marker 记录的旧模式恢复。
profile_script_for() {
    case "${1:-}" in
    anytls) printf 'anytls.sh' ;;
    cloudfront) printf 'cloudfront.sh' ;;
    cloudflare) printf 'cloudflare.sh' ;;
    combined-cloudfront) printf 'combined.sh' ;;
    combined-cloudflare) printf 'combined-cloudflare.sh' ;;
    *) return 1 ;;
    esac
}

install_current_mode() {
    printf '%s' "${EASY_ALL_SELECTED_MODE:-}"
}

# 按 marker 记录的旧模式清理。必须用独立 bash 进程：子 shell 会继承当前 profile 的
# readonly 常量（如 ACME_HOME）和已定义函数，重新 source 旧 profile 会赋值失败，
# 清理就会拿着当前模式的路径去删旧模式的残留。
run_recorded_profile_cleanup() {
    local recorded=$1 profiles_dir script status=0
    profiles_dir="${RUNTIME_LIB_DIR}/../profiles"
    script=$(profile_script_for "${recorded}") || {
        warn "无法识别上次安装的模式：${recorded}"
        return 1
    }
    [[ -f "${profiles_dir}/${script}" ]] || {
        warn "缺少 ${recorded} 模式模块：${profiles_dir}/${script}"
        return 1
    }
    EASY_ALL_SELECTED_MODE="${recorded}" bash -c '
        set -Eeuo pipefail
        # shellcheck source=/dev/null
        source "$1" || exit 1
        declare -F cleanup_partial_install >/dev/null || exit 2
        cleanup_partial_install
    ' _ "${profiles_dir}/${script}" || status=$?
    ((status == 0)) || {
        warn "按 ${recorded} 模式清理失败（退出码 ${status}）"
        return 1
    }
}

# 安装前置：清理自身残留 + 断言端口空闲。调用方须保持「已安装则提前 die」的语义。

# 本次安装生成的身份（UUID、路径、订阅 Token、Origin CA 元数据）。
# 落盘到状态目录，供中断续装复用；不含任何账号 Token 或私钥以外的凭据。
install_identity_file() {
    printf '%s/install-identity.json' "$(install_state_dir_path)"
}

# 安装身份 JSON 的 schema 与必需字段门禁：身份文件是继续装与恢复的唯一依据，
# 旧版本写下的同名文件不能按新结构解释（design §5）。
install_identity_schema_ok() {
    local file=$1
    [[ -s "${file}" ]] || return 1
    jq -e --argjson schema "${EASY_ALL_STATE_SCHEMA_VERSION}" '
        type == "object"
        and .schema == $schema
        and ((.profile // "") | length > 0)
        and ((.protocol // "") | length > 0)
    ' "${file}" >/dev/null 2>&1
}

persist_install_identity() {
    local file tmp chain
    file=$(install_identity_file)
    [[ -d "${file%/*}" ]] || return 0
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    chain=$(install_progress_field CHAIN 2>/dev/null || true)
    if jq -n \
        --argjson schema "${EASY_ALL_STATE_SCHEMA_VERSION}" \
        --arg profile "${CDN_PROFILE_KEY:-${EASY_ALL_SELECTED_MODE:-}}" \
        --arg protocol "${PROTOCOL:-}" \
        --arg subscription_mode "${SUBSCRIPTION_MODE:-}" \
        --arg chain "${chain}" \
        --arg vps_ipv4 "${VPS_PUBLIC_IPV4:-}" \
        --arg cf_zone "${CF_ZONE:-}" \
        --arg cf_origin "${CF_ORIGIN_DOMAIN:-}" \
        --arg cf_node "${CF_NODE_DOMAIN:-}" \
        --arg subscription_domain "${SUBSCRIPTION_DOMAIN:-}" \
        --arg origin_secret "${ORIGIN_HEADER_SECRET:-}" \
        --arg uuid "${VLESS_UUID:-}" \
        --arg vless_path "${VLESS_PATH:-}" \
        --arg anytls_password "${ANYTLS_PASSWORD:-}" \
        --arg node_prefix "${CF_NODE_PREFIX:-}" \
        --arg sub_name "${SUB_DOWNLOAD_NAME:-}" \
        --arg protection_gb "${CDN_TRAFFIC_PROTECTION_GB:-}" \
        --arg dist_id "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}" \
        --arg dist_domain "${AWS_CLOUDFRONT_DOMAIN:-}" \
        --arg acm_arn "${AWS_ACM_CERTIFICATE_ARN:-}" \
        --arg owner "${OWNER_TOKEN:-}" \
        --arg tokens "${ALLOWED_TOKENS:-}" \
        --arg subscription_config "${SUBSCRIPTION_CONFIG:-}" \
        --arg direct_domain "${DIRECT_DOMAIN:-}" \
        --arg direct_name "${DIRECT_NODE_NAME:-}" \
        --arg reboot_enabled "${SCHEDULED_REBOOT_ENABLED:-}" \
        --arg reboot_hour "${SCHEDULED_REBOOT_HOUR:-}" \
        --arg cf_cert "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
        --arg cf_expires "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" \
        --arg cf_ruleset "${CLOUDFLARE_ORIGIN_RULESET_ID:-}" \
        --arg cf_rule "${CLOUDFLARE_ORIGIN_RULE_ID:-}" \
        '{
            schema: $schema,
            profile: $profile,
            protocol: $protocol,
            subscription_mode: $subscription_mode,
            chain: $chain,
            vps_public_ipv4: $vps_ipv4,
            cf_zone: $cf_zone,
            cf_origin_domain: $cf_origin,
            cf_node_domain: $cf_node,
            subscription_domain: $subscription_domain,
            origin_header_secret: $origin_secret,
            vless_uuid: $uuid,
            vless_path: $vless_path,
            anytls_password: $anytls_password,
            cf_node_prefix: $node_prefix,
            sub_download_name: $sub_name,
            cdn_traffic_protection_gb: $protection_gb,
            aws_cloudfront_distribution_id: $dist_id,
            aws_cloudfront_domain: $dist_domain,
            aws_acm_certificate_arn: $acm_arn,
            owner_token: $owner,
            allowed_tokens: $tokens,
            subscription_config: $subscription_config,
            direct_domain: $direct_domain,
            direct_node_name: $direct_name,
            scheduled_reboot_enabled: $reboot_enabled,
            scheduled_reboot_hour: $reboot_hour,
            cloudflare_origin_cert_id: $cf_cert,
            cloudflare_origin_cert_expires_on: $cf_expires,
            cloudflare_origin_ruleset_id: $cf_ruleset,
            cloudflare_origin_rule_id: $cf_rule
        }' >"${tmp}"; then
        chmod 0600 "${tmp}"
        if mv -f -- "${tmp}" "${file}"; then
            return 0
        fi
    fi
    rm -f -- "${tmp}"
    return 1
}

# 续装时用上次写进配置的身份覆盖本次预检新生成的值，保证已下发的节点/订阅不失效。
# 只接受 schema 1 且带 profile/protocol 的 JSON 对象；文件不存在/损坏/旧 schema 返回 1。
load_install_identity() {
    local file name key value
    file=$(install_identity_file)
    install_identity_schema_ok "${file}" || return 1
    for pair in \
        VLESS_UUID:vless_uuid VLESS_PATH:vless_path ANYTLS_PASSWORD:anytls_password \
        VPS_PUBLIC_IPV4:vps_public_ipv4 CF_ZONE:cf_zone \
        CF_ORIGIN_DOMAIN:cf_origin_domain CF_NODE_DOMAIN:cf_node_domain \
        SUBSCRIPTION_DOMAIN:subscription_domain \
        SUBSCRIPTION_MODE:subscription_mode \
        ORIGIN_HEADER_SECRET:origin_header_secret CF_NODE_PREFIX:cf_node_prefix \
        SUB_DOWNLOAD_NAME:sub_download_name \
        CDN_TRAFFIC_PROTECTION_GB:cdn_traffic_protection_gb \
        AWS_CLOUDFRONT_DISTRIBUTION_ID:aws_cloudfront_distribution_id \
        AWS_CLOUDFRONT_DOMAIN:aws_cloudfront_domain \
        AWS_ACM_CERTIFICATE_ARN:aws_acm_certificate_arn \
        OWNER_TOKEN:owner_token ALLOWED_TOKENS:allowed_tokens \
        SUBSCRIPTION_CONFIG:subscription_config \
        DIRECT_DOMAIN:direct_domain DIRECT_NODE_NAME:direct_node_name \
        SCHEDULED_REBOOT_ENABLED:scheduled_reboot_enabled \
        SCHEDULED_REBOOT_HOUR:scheduled_reboot_hour \
        CLOUDFLARE_ORIGIN_CERT_ID:cloudflare_origin_cert_id \
        CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:cloudflare_origin_cert_expires_on \
        CLOUDFLARE_ORIGIN_RULESET_ID:cloudflare_origin_ruleset_id \
        CLOUDFLARE_ORIGIN_RULE_ID:cloudflare_origin_rule_id; do
        name=${pair%%:*}
        key=${pair#*:}
        value=$(jq -r --arg k "${key}" '.[$k] // empty' "${file}") || return 1
        [[ -n "${value}" ]] || continue
        printf -v "${name}" '%s' "${value}"
    done
    return 0
}

# 断点续装前置：identity 必须存在，且 profile/protocol/chain 与本次安装链路完全一致。
# 缺字段、错误 JSON 或跨链路身份一律返回非零，由调用方拒绝续装。
install_identity_chain_matches() {
    local file=$1 expected_profile=$2 expected_protocol=$3 expected_chain=$4
    [[ -s "${file}" ]] || return 1
    jq -e --argjson schema "${EASY_ALL_STATE_SCHEMA_VERSION}" \
        --arg profile "${expected_profile}" --arg protocol "${expected_protocol}" \
        --arg chain "${expected_chain}" '
        type == "object" and
        .schema == $schema and
        (.profile // "") == $profile and
        (.protocol // "") == $protocol and
        (.chain // "") == $chain
    ' "${file}" >/dev/null 2>&1
}

# 续装：只停服务释放端口，不删配置/证书/状态，也不重新拍快照
# （保留真正的安装前状态，后续再失败仍回滚到安装前，而不是回滚到半成品）。
resume_partial_install() {
    local backup_dir chain
    backup_dir="$(install_state_dir_path)/backups"
    [[ -f "${backup_dir}/pre-install-complete" ]] \
        || die "上次安装前的快照不完整，无法安全续装；请执行 sudo easy_all cleanup-partial 后重装"
    chain=$(install_progress_field CHAIN 2>/dev/null || true)
    if [[ "${chain}" == "cloudfront" || "${chain}" == "cloudflare" ]]; then
        # CloudFront 链路的分发/证书与已下发订阅都只存在于磁盘身份里：身份缺失或不
        # 一致时续装会用新值覆盖已创建资源，必须拒绝而不是仅告警。
        install_identity_chain_matches "$(install_identity_file)" \
            "${CDN_PROFILE_KEY:-${EASY_ALL_SELECTED_MODE:-}}" \
            "${CDN_EXPECTED_PROTOCOL:-}" "${chain}" \
            || die "上次 ${chain} 安装身份缺失或与链路不一致（profile/protocol/chain）；无法安全续装，请执行 sudo easy_all cleanup-partial 后重装"
        load_install_identity \
            || die "上次 ${chain} 安装身份无法读取；无法安全续装，请执行 sudo easy_all cleanup-partial 后重装"
    else
        # 参数预检可能已经重新生成了 UUID/路径/Token；用落盘身份覆盖回去，保证已写进配置和
        # 已下发订阅的节点参数不变。身份文件缺失（中断太早）时按新生成值继续。
        load_install_identity \
            || warn "没有可复用的安装身份（中断早于身份落盘），本次会使用新生成的值"
    fi
    systemctl stop "${SINGBOX_SERVICE:-easy_all-singbox.service}" >/dev/null 2>&1 || true
    systemctl stop "${CADDY_SERVICE:-easy_all-caddy.service}" >/dev/null 2>&1 || true
    INSTALL_RESUME=1
    export INSTALL_RESUME
    success "续装：保留上次安装的本机配置/证书与云端资源，只重建服务（失败仍回滚到安装前状态）"
}

# 安装标记的链路身份：链必须与当前模式一致；没有 CHAIN 的旧标记返回非零，只能清理后重装。
install_marker_chain_matches() {
    local current=$1 expected
    case "${current}" in
    anytls) expected=anytls ;;
    cloudfront | combined-cloudfront) expected=cloudfront ;;
    cloudflare | combined-cloudflare) expected=cloudflare ;;
    *) return 1 ;;
    esac
    [[ "$(install_progress_field CHAIN 2>/dev/null || true)" == "${expected}" ]]
}

prepare_fresh_install() {
    local reason_text stage answer recorded current
    if reason_text=$(install_residue_reason); then
        stage=$(install_progress_field STAGE || true)
        recorded=$(install_progress_field PROFILE || true)
        current=$(install_current_mode)
        warn "检测到上次未完成的 easy_all 安装${stage:+（中断于 ${stage} 阶段）}${recorded:+（${recorded} 模式）}，本机残留："
        printf '%s\n' "${reason_text}" | sed 's/^/  - /' >&2
        [[ -n "${recorded}" ]] \
            || die "安装进度标记缺少模式信息（$(install_progress_file)）；该标记无法判断模式，cleanup-partial 也无法接管，请核对标记内容或按上方残留清单人工清理后重装"
        if [[ "${recorded}" != "${current}" ]]; then
            # 模式不同无法续装：只能按旧模式清理后重装。
            if [[ -t 0 ]]; then
                read_confirmation "上次中断的是 ${recorded} 模式，当前选择 ${current:-未知}；清理旧模式残留后继续？[Y/n]:" answer
                [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]] \
                    || die "$(printf '已取消安装（未做任何改动）。\n%s' "$(residue_recovery_hint)")"
            else
                die "$(printf '非交互安装检测到残留（%s 模式）。\n%s' "${recorded}" "$(residue_recovery_hint)")"
            fi
            warn "按 ${recorded} 模式清理残留（当前选择：${current:-未知}）"
            run_recorded_profile_cleanup "${recorded}" \
                || die "按 ${recorded} 模式清理残留失败；请先执行 sudo easy_all cleanup-partial"
            success "残留已清理，继续安装"
        elif install_marker_chain_matches "${current}"; then
            # CDN 核心只接受与当前链路的 CHAIN 一致的同一键标记续装；旧 WIP 与旧橙云
            # 标记没有该字段，只能清理后重装。
            if [[ -t 0 ]]; then
                read_confirmation '继续上次安装（保留已完成的配置、证书与云端资源）？[Y/n]:' answer
                if [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]]; then
                    resume_partial_install
                    assert_install_ports_free "$@"
                    return 0
                fi
                read_confirmation '改为清理残留后重新安装？[Y/n]:' answer
                [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]] \
                    || die "$(printf '已取消安装（未做任何改动）。\n%s' "$(residue_recovery_hint)")"
            else
                die "$(printf '非交互安装检测到残留。\n%s' "$(residue_recovery_hint)")"
            fi
            cleanup_partial_install || die "清理残留失败；请按上方提示处理后重试"
            success "残留已清理，继续安装"
        else
            if [[ -t 0 ]]; then
                read_confirmation '现在清理残留并继续安装？[Y/n]（n=取消安装，不改动机器）:' answer
                [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]] \
                    || die "$(printf '已取消安装（未做任何改动）。\n%s' "$(residue_recovery_hint)")"
            else
                die "$(printf '非交互安装检测到残留。\n%s' "$(residue_recovery_hint)")"
            fi
            cleanup_partial_install || die "清理残留失败；请按上方提示处理后重试"
            success "残留已清理，继续安装"
        fi
    fi
    assert_install_ports_free "$@"
}

# 本机残留清理的公共主体。各 Profile 的 cleanup_partial_install 负责补齐自身文件清单。
cleanup_partial_install_local() {
    local state_dir backup_dir
    state_dir=$(install_state_dir_path)
    backup_dir="${state_dir}/backups"
    stop_maintenance_services || true
    if declare -F stop_services >/dev/null 2>&1; then
        stop_services
    elif declare -F stop_protocol_services >/dev/null 2>&1; then
        stop_protocol_services
    else
        systemctl disable --now "${SINGBOX_SERVICE:-easy_all-singbox.service}" >/dev/null 2>&1 || true
        systemctl disable --now "${CADDY_SERVICE:-easy_all-caddy.service}" >/dev/null 2>&1 || true
    fi
    if [[ -f "${backup_dir}/pre-install-complete" ]]; then
        if ! restore_install_snapshot; then
            warn "安装前快照未完全恢复；已停止残留服务，但未删除配置。请按上方提示核对后再重试"
            return 1
        fi
    else
        warn "未找到完整安装前快照（快照未完成或早于快照步骤）；只移除本机残留，不修改 UFW/SSH/IPv6 配置"
        remove_daily_reboot_schedule || true
    fi
}

# 删除本机残留：只删除调用方明确列出的路径，避免误伤未安装前就存在的文件。
cleanup_partial_install_files() {
    local path failed=0
    for path in "$@"; do
        [[ -n "${path}" ]] || continue
        rm -rf -- "${path}" 2>/dev/null || { warn "删除残留失败：${path}"; failed=1; }
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ((failed == 1)); then
        # 保留 marker：否则下次既无法判断模式，安装重入也会走无标记分支。
        warn "有残留未能删除；保留安装进度标记，修正权限/挂载后可重试 sudo easy_all cleanup-partial"
        return 1
    fi
    install_progress_clear
}

restore_install_snapshot() {
    # 只有声明了 Cloudflare 回源注释的 Profile 才回收回源放行；新 CloudFront 核心虽然
    # source cf-dns.sh，却没有旧回源常量，仅凭函数存在调用会在 set -u 下崩溃。
    if [[ -n "${CLOUDFLARE_UFW_COMMENT:-}" ]] \
        && declare -F cloudflare_remove_origin_firewall_rules >/dev/null 2>&1; then
        cloudflare_remove_origin_firewall_rules || true
    fi
    restore_platform_security_state || {
        warn "SSH 配置恢复失败；请通过服务商 Console 检查后再重试"
        return 1
    }
    if declare -F restore_preinstall_firewall >/dev/null 2>&1; then
        restore_preinstall_firewall || true
    fi
    if declare -F restore_preinstall_ipv6 >/dev/null 2>&1; then
        restore_preinstall_ipv6 || warn "恢复安装前 IPv6 配置失败"
    fi
    # 前置初始化（SWAP、系统依赖、TCP 加速、Skyline Speeder）不作回滚
    restore_preinstall_crontab || true
    remove_daily_reboot_schedule || true
}

# B1：初始化步骤本身已幂等；这里只把「已初始化、本次跳过重复安装」说清楚，便于排障。
host_already_initialized() {
    local swap_kb=0 meminfo="${EASY_ALL_MEMINFO_FILE:-/proc/meminfo}" status
    command -v ufw >/dev/null 2>&1 || return 1
    command -v fail2ban-client >/dev/null 2>&1 || return 1
    systemctl is-active --quiet fail2ban.service 2>/dev/null || return 1
    status=$(LC_ALL=C ufw status 2>/dev/null) || return 1
    [[ "${status}" == *'Status: active'* ]] || return 1
    swap_kb=$(awk '/SwapTotal:/ {print $2}' "${meminfo}" 2>/dev/null || echo 0)
    (( swap_kb > 0 ))
}

report_host_init_state() {
    if host_already_initialized; then
        info "检测到主机已完成初始化：已就绪的依赖、内核与 TCP 加速将跳过重复安装；IPv4-only、定时重启与 UFW/Fail2ban 仍会幂等校验"
    else
        info "首次安装：安装系统依赖并初始化服务器"
    fi
}
