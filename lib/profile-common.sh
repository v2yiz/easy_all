#!/usr/bin/env bash

# Shared Profile plumbing, input validation and state normalization.

make_temp_dir() {
    mktemp -d "${RUNTIME_TMP}/part.XXXXXX"
}

nginx_supports_http2_directive() {
    command -v nginx >/dev/null 2>&1 || return 1
    local ver major minor patch
    ver=$(nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n1)
    [[ -n "${ver}" ]] || return 1
    IFS=. read -r major minor patch <<<"${ver}"
    patch=${patch:-0}
    if (( major > 1 || (major == 1 && minor > 25) || (major == 1 && minor == 25 && patch >= 1) )); then
        return 0
    fi
    return 1
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

prompt_secret() {
    local label=$1 value
    [[ -t 0 ]] || return 1
    read_bilingual "${label}，粘贴后按回车键；输入过程不会显示任何字符:" value 1
    printf '%s' "${value}"
}

restore_state_file() {
    local backup=$1 target=$2 temp
    temp=$(mktemp "$(dirname -- "${target}")/state.env.XXXXXX") \
        || die "创建状态恢复暂存文件失败"
    cleanup_files+=("${temp}")
    install -m 0600 "${backup}" "${temp}" \
        && mv -f -- "${temp}" "${target}" \
        || die "原子恢复状态文件失败：${target}"
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

# Debian 的 nginx 包一装好就会启动默认站点占住 :80/443。若不停掉，这次安装本身就会
# 锁死刚检查过的端口，中断后重跑必然撞上「已被占用」，用户无从自救。
# 只停止并取消开机自启，不删除 Debian 的默认站点文件：占用端口的是运行中的进程，
# 而默认站点文件本身是卸载时需要还原的安装前状态。
nginx_package_installed() {
    local status
    command -v dpkg-query >/dev/null 2>&1 || return 1
    status=$(dpkg-query -W -f='${Status}' nginx 2>/dev/null || true)
    # dpkg 的第一列可能是 install / hold / deinstall 等，只有状态列是 installed 才算装好；
    # 只看完整串 "install ok installed" 会把 hold 的包误判成未安装。
    case "${status}" in
    *" ok installed"*) return 0 ;;
    *) return 1 ;;
    esac
}

quiet_freshly_installed_nginx() {
    local nginx_active_before=${1:-unknown}
    [[ "${nginx_active_before}" != "active" ]] || return 0
    systemctl disable --now nginx >/dev/null 2>&1 || true
}

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

# 安装 nginx 的专用入口：装完后立刻恢复策略并停掉刚被拉起的默认站点。
install_nginx_without_start() {
    local status=0
    if ! suspend_service_start; then
        # 没有抑制手段时 apt 期间默认站点仍会自启，等于没关窗口；宁可停下让用户先装包，
        # 也不能假装保住契约。
        die "$(printf '无法临时暂停服务自启（%s 不可写或存在未恢复的残留事务）。\n请先手工执行 sudo apt-get install -y nginx，再重新运行安装；安装器会在写最终配置前保持 nginx 停止。' "$(easy_all_policy_rc_file)")"
    fi
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "$@" \
        || status=$?
    restore_service_start_policy \
        || warn "恢复 $(easy_all_policy_rc_file) 失败；事务已保留，请修正后重试（否则服务无法自启）"
    ((status == 0)) || return "${status}"
    systemctl disable --now nginx >/dev/null 2>&1 || true
}

# --- 中断安装的自愈：进度标记、残留识别与端口守卫 ------------------------------
#
# 一次安装被 SSH 断线打断后，本机可能同时留下「已安装的 nginx 默认站点」「未完成的状态
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
    local profile=$1 file dir
    file=$(install_progress_file)
    dir=$(dirname -- "${file}")
    if ! install -d -m 0700 "${dir}" 2>/dev/null; then
        warn "无法创建安装进度目录 ${dir}；中断后不会自动识别残留"
        return 0
    fi
    {
        printf 'PROFILE=%s\n' "${profile}"
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

install_state_dir_path() {
    printf '%s' "${EASY_ALL_GUARD_STATE_DIR:-${STATE_DIR:-/etc/easy_all}}"
}

install_state_file_path() {
    printf '%s' "${EASY_ALL_GUARD_STATE_FILE:-${STATE_FILE:-$(install_state_dir_path)/state.env}}"
}

install_service_file_path() {
    printf '%s' "${EASY_ALL_GUARD_SERVICE_FILE:-${XRAY_SERVICE_FILE:-/etc/systemd/system/easy_all-xray.service}}"
}

install_nginx_config_path() {
    printf '%s' "${EASY_ALL_GUARD_NGINX_CONFIG:-${NGINX_CONFIG:-/etc/nginx/conf.d/easy_all.conf}}"
}

# 已安装（存在状态文件）时返回 1：残留判定只服务于「未安装」场景。
install_residue_reason() {
    local state_dir state_file service_file nginx_config progress stage state_entries
    state_dir=$(install_state_dir_path)
    state_file=$(install_state_file_path)
    service_file=$(install_service_file_path)
    nginx_config=$(install_nginx_config_path)
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
        [[ -z "${state_entries}" ]] || reasons+=("未完成的状态目录 ${state_dir}")
    fi
    if [[ -f "${service_file}" ]]; then
        reasons+=("残留服务单元 ${service_file}")
    fi
    if [[ -f "${nginx_config}" ]]; then
        reasons+=("残留 Nginx 配置 ${nginx_config}")
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

# 旧版本安装器没有进度标记：中断后留下的 nginx 只会表现为「端口被 nginx 占用」。
# 这种情况下我们自己都没写 conf.d 配置，而 Debian 默认站点还在，基本可以确定是残留，
# 于是保留「仅支持专用 VPS」的判定，但附上可执行的恢复动作。
nginx_leftover_hint() {
    local nginx_config default_site
    nginx_config=$(install_nginx_config_path)
    default_site=${EASY_ALL_GUARD_NGINX_DEFAULT_SITE:-/etc/nginx/sites-enabled/default}
    [[ ! -f "${nginx_config}" ]] || return 1
    [[ -f "${default_site}" ]] || return 1
    # 这里没有进度标记，cleanup-partial 无从判断模式，只能给人工动作。
    printf '%s\n' \
        '检测到 Debian 默认站点仍占用该端口；若这是上次 easy_all 安装中断留下的 nginx，执行：' \
        '  sudo systemctl disable --now nginx' \
        '然后重新运行安装（新版安装器会自行识别并继续）。'
}

# 旧版本安装器（无 marker）中断后只剩 Debian 默认站点在监听。只有在「没有任何其他
# 站点配置」时才把它当作可自动清理的候选，避免误停用户自己的 nginx 站点。
legacy_nginx_residue_candidate() {
    local default_site sites_dir conf_dir
    default_site=${EASY_ALL_GUARD_NGINX_DEFAULT_SITE:-/etc/nginx/sites-enabled/default}
    sites_dir=${EASY_ALL_GUARD_NGINX_SITES_DIR:-$(dirname -- "${default_site}")}
    conf_dir=${EASY_ALL_GUARD_NGINX_CONF_DIR:-/etc/nginx/conf.d}
    [[ -f "${default_site}" ]] || return 1
    [[ ! -f "$(install_nginx_config_path)" ]] || return 1
    [[ ! -f "$(install_state_file_path)" ]] || return 1
    if [[ -d "${sites_dir}" ]]; then
        [[ -z "$(ls -A "${sites_dir}" 2>/dev/null | grep -vx 'default' || true)" ]] \
            || return 1
    fi
    if [[ -d "${conf_dir}" ]]; then
        [[ -z "$(ls -A "${conf_dir}" 2>/dev/null | grep -vx 'easy_all.conf' || true)" ]] \
            || return 1
    fi
    return 0
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
            '这些残留没有安装进度标记（旧版本遗留），无法自动判断模式：' \
            '  1) 先人工核对 /etc/easy_all、/etc/nginx/conf.d/easy_all.conf 与 easy_all* 服务；' \
            '  2) 确认模式后指定清理：' \
            "     ${bootstrap} cleanup-partial --assume-mode <reality|cloudflare-streamup|gcore|combined|bunny-ws>"
    fi
}

assert_install_ports_free() {
    local port owner reason_text leftover
    for port in "$@"; do
        tcp_port_listening "${port}" || continue
        if reason_text=$(install_residue_reason); then
            owner=$(tcp_port_owner "${port}" || true)
            die "$(printf 'TCP %s 被上次未完成的 easy_all 安装残留占用%s\n残留：%s\n%s' \
                "${port}" "${owner:+（${owner}）}" \
                "$(printf '%s' "${reason_text}" | paste -sd ';' -)" \
                "$(residue_recovery_hint)")"
        fi
        owner=$(tcp_port_owner "${port}" || true)
        if [[ "${owner}" == *nginx* ]] && leftover=$(nginx_leftover_hint); then
            die "$(printf 'TCP %s 已被占用%s；easy_all 仅支持专用 VPS\n%s' \
                "${port}" "（${owner}）" "${leftover}")"
        fi
        die "TCP ${port} 已被占用${owner:+（${owner}）}；easy_all 仅支持专用 VPS"
    done
}

# 每个模式对应的 profile 文件：跨模式清理时按 marker 记录的旧模式恢复。
profile_script_for() {
    case "${1:-}" in
    reality) printf 'reality.sh' ;;
    cloudflare-streamup) printf 'xhttp-cloudflare-streamup.sh' ;;
    gcore) printf 'xhttp-gcore.sh' ;;
    combined) printf 'combined.sh' ;;
    bunny-ws) printf 'ws-bunny.sh' ;;
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
prepare_fresh_install() {
    local reason_text stage answer recorded
    if reason_text=$(install_residue_reason); then
        stage=$(install_progress_field STAGE || true)
        recorded=$(install_progress_field PROFILE || true)
        warn "检测到上次未完成的 easy_all 安装${stage:+（中断于 ${stage} 阶段）}${recorded:+（${recorded} 模式）}，本机残留："
        printf '%s\n' "${reason_text}" | sed 's/^/  - /' >&2
        if [[ -t 0 ]]; then
            read_bilingual '先清理残留再继续安装？[Y/n]:' answer
            [[ -z "${answer}" || "${answer}" =~ ^[Yy]$ ]] \
                || die "已取消；稍后可执行 sudo easy_all cleanup-partial 清理"
        else
            die "非交互安装检测到残留；请先执行 sudo easy_all cleanup-partial"
        fi
        if [[ -z "${recorded}" ]]; then
            # 没有 marker 就没有归属证据；按当前选择清理可能漏掉旧模式的规则/服务。
            die "$(printf '没有安装进度标记，无法判断残留属于哪个模式，已停止安装。请先执行：\n  sudo easy_all cleanup-partial --assume-mode <reality|cloudflare-streamup|gcore|combined|bunny-ws>\n命令未注册时：\n  bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) cleanup-partial --assume-mode <模式>')"
        elif [[ "${recorded}" != "$(install_current_mode)" ]]; then
            warn "上次中断的是 ${recorded} 模式，按该模式清理（当前选择：$(install_current_mode)）"
            run_recorded_profile_cleanup "${recorded}" \
                || die "按 ${recorded} 模式清理残留失败；请先执行 sudo easy_all cleanup-partial"
        else
            cleanup_partial_install || die "清理残留失败；请按上方提示处理后重试"
        fi
        success "残留已清理，继续安装"
    elif legacy_nginx_residue_candidate; then
        # 无 marker 时无法证明这份 nginx 属于 easy_all：不声称是残留，默认不处理。
        warn "端口被 nginx 占用，且只启用了 Debian 默认站点（没有任何 easy_all 安装标记）。"
        warn "无法确认它属于上次 easy_all 安装，还是你改作自用的默认站点。"
        if [[ -t 0 ]]; then
            read_bilingual '确认这是上次安装残留、停止 nginx 并继续安装？[y/N]:' answer
            [[ "${answer}" =~ ^[Yy]$ ]] \
                || die "已取消；若确认是残留可执行 sudo systemctl disable --now nginx 后重试"
        else
            die "非交互安装无法确认 nginx 归属；请先人工确认后执行 sudo systemctl disable --now nginx"
        fi
        systemctl disable --now nginx >/dev/null 2>&1 \
            || warn "停止 nginx 失败；若端口仍被占用请手工处理"
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
        systemctl disable --now "${XRAY_SERVICE:-easy_all-xray.service}" >/dev/null 2>&1 || true
        systemctl disable --now nginx >/dev/null 2>&1 || true
    fi
    if declare -F remove_quota_timer >/dev/null 2>&1; then
        remove_quota_timer || true
    fi
    if declare -F remove_globalping_refresh_timer >/dev/null 2>&1; then
        remove_globalping_refresh_timer || true
    fi
    if [[ -f "${backup_dir}/pre-install-complete" ]]; then
        if ! restore_install_snapshot; then
            warn "安装前快照未完全恢复；已停止残留服务，但未删除配置。请按上方提示核对后再重试"
            return 1
        fi
    else
        warn "未找到完整安装前快照（快照未完成或早于快照步骤）；只移除本机残留，不修改 UFW/SSH/BBR 配置"
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
    if declare -F cloudflare_remove_origin_firewall_rules >/dev/null 2>&1; then
        cloudflare_remove_origin_firewall_rules || true
    fi
    if declare -F gcore_remove_origin_firewall_rules >/dev/null 2>&1; then
        gcore_remove_origin_firewall_rules || true
    fi
    if declare -F reality_cloudflare_remove_subscription_firewall_rules >/dev/null 2>&1; then
        reality_cloudflare_remove_subscription_firewall_rules || true
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
    restore_bbr_tcp_install_state 1 || warn "恢复安装前 TCP/内核状态失败"
    restore_preinstall_crontab || true
    remove_daily_reboot_schedule || true
}
