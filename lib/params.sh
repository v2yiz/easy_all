#!/usr/bin/env bash

# 安装参数层：一个 JSON 字典进，聚合校验一次，安装期零交互。
#
# 约定：
# - 字段名就是安装流程使用的 shell 变量名（大写）；解析成功后直接赋值，下游代码不需要
#   改名，也就不会出现"字典键名与变量名两套事实"。
# - 校验失败不立即退出：逐字段记录错误，最后一次性报告全部问题。
# - Token/Key 只来自参数字典本身，不读环境变量、不读独立文件；摘要与错误信息一律脱敏。
# - 安装流程只有一条路径：没有交互模式，也没有额外的无人值守开关。
#
# 兼容性：本文件在 bash 3.2（macOS 自带）下也必须能运行，禁止使用关联数组等 4.x 特性。

# launcher 与 lib/runtime-core.sh 都会 source 本文件：重复加载时保留已解析的参数状态。
if [[ "${EASY_ALL_PARAMS_LIB_LOADED:-0}" == "1" ]]; then
    return 0
fi
EASY_ALL_PARAMS_LIB_LOADED=1

PARAMS_LOADED=0
PARAMS_MODE=""
PARAMS_JSON=""
PARAMS_SOURCE=""
PARAMS_TEMPLATE_MODE=0
PARAMS_ERRORS=()
PARAMS_WARNINGS=()
PARAMS_DECLARED=()
PARAMS_LABELS=()
PARAMS_SECRET_KEYS=()
PARAMS_TEMPLATE_KEYS=()
PARAMS_TEMPLATE_VALUES=()
PARAMS_TEMPLATE_TYPES=()
PARAMS_TEMPLATE_SECRETS=()
PARAMS_TEMPLATE_REQUIRED=()
PARAMS_TEMPLATE_LABELS=()

params_die() {
    if declare -F die >/dev/null 2>&1; then
        die "$@"
    fi
    printf '%s\n' "$*" >&2
    exit 1
}

params_error() {
    PARAMS_ERRORS[${#PARAMS_ERRORS[@]}]="$1"
}

params_warn() {
    PARAMS_WARNINGS[${#PARAMS_WARNINGS[@]}]="$1"
}

params_supported_modes() {
    printf 'reality cloudflare-streamup bunny-ws gcore combined'
}

params_file_permissions() {
    local file=$1 mode
    mode=$(stat -c %a -- "${file}" 2>/dev/null) \
        || mode=$(stat -f %Lp -- "${file}" 2>/dev/null) \
        || mode=""
    printf '%s' "${mode}"
}

# 读取参数来源：普通文件（要求不含 group/other 权限位）或标准输入。
params_read_source() {
    local file=$1 content perm
    if [[ "${file}" == "-" ]]; then
        content=$(cat) || params_die "从标准输入读取参数失败"
        PARAMS_SOURCE="<stdin>"
    else
        [[ -n "${file}" ]] || params_die "参数文件路径为空"
        [[ ! -L "${file}" ]] \
            || params_die "参数文件不能是符号链接：${file}；请直接提供普通文件，或改用 --params - 从标准输入读取"
        [[ -f "${file}" ]] || params_die "参数文件不存在或不是普通文件：${file}"
        [[ -r "${file}" ]] || params_die "参数文件不可读：${file}"
        content=$(<"${file}") || params_die "读取参数文件失败：${file}"
        PARAMS_SOURCE=${file}
    fi
    [[ -n "${content//[[:space:]]/}" ]] || params_die "参数内容为空"
    PARAMS_JSON=${content}
}

params_validate_envelope() {
    local bad version
    jq -e 'type == "object"' <<<"${PARAMS_JSON}" >/dev/null 2>&1 \
        || params_die "参数文件顶层必须是 JSON object，且需要 mode 与 params 两个字段"
    bad=$(jq -r \
        '[keys[] | select(. != "schema_version" and . != "mode" and . != "params")] | join(", ")' \
        <<<"${PARAMS_JSON}") || params_die "参数文件不是合法 JSON"
    [[ -z "${bad}" ]] \
        || params_die "参数文件包含未知顶层字段：${bad}（只允许 schema_version、mode、params）"
    version=$(jq -r '.schema_version // empty' <<<"${PARAMS_JSON}")
    [[ "${version}" == "1" ]] || params_die "schema_version 必须为 1（当前：${version:-缺失}）"
    jq -e '.mode | type == "string"' <<<"${PARAMS_JSON}" >/dev/null 2>&1 \
        || params_die "mode 必须是字符串"
    jq -e '.params | type == "object"' <<<"${PARAMS_JSON}" >/dev/null 2>&1 \
        || params_die "params 必须是 JSON object"
}

params_mode_value() {
    local mode
    mode=$(jq -r '.mode // empty' <<<"${PARAMS_JSON}")
    case " $(params_supported_modes) " in
    *" ${mode} "*) ;;
    *) params_die "mode 无效：${mode:-缺失}；可用：$(params_supported_modes)" ;;
    esac
    printf '%s\n' "${mode}"
}

# 只读取 mode，用于在选择 Profile 之前确定安装模式。
params_peek_mode() {
    params_read_source "$1"
    params_validate_envelope
    params_mode_value
}

params_begin() {
    local mode=$1 file=$2 actual
    PARAMS_MODE=${mode}
    if [[ "${PARAMS_TEMPLATE_MODE}" == "1" ]]; then
        return 0
    fi
    params_read_source "${file}"
    params_validate_envelope
    actual=$(params_mode_value)
    [[ "${actual}" == "${mode}" ]] \
        || params_die "参数文件 mode=${actual} 与本次安装模式 ${mode} 不一致"
    params_warn_loose_permissions
    # 从这里开始安装期禁止任何交互：任何残留的提示函数都会立刻失败，而不是悄悄重新提问。
    PARAMS_LOADED=1
    # 安装成功后会删掉参数文件（含 Token）；--check-params 只校验，不删。
    params_schedule_cleanup
}

params_warn_loose_permissions() {
    local perm
    [[ "${PARAMS_SOURCE}" != "<stdin>" && -n "${PARAMS_SOURCE:-}" ]] || return 0
    perm=$(params_file_permissions "${PARAMS_SOURCE}")
    [[ -n "${perm}" ]] || return 0
    if (( (8#${perm} & 077) != 0 )); then
        printf '提示：参数文件权限较宽（%s），其中含 API Token；安装成功后会删除它，中断时请自行清理：%s\n' \
            "${perm}" "${PARAMS_SOURCE}" >&2
    fi
}

# 安装成功才删：--check-params 与 --print-params 不动文件；stdin 没有文件可删。
params_schedule_cleanup() {
    INSTALL_PARAMS_DELETE=0
    [[ "${EASY_ALL_PARAMS_KEEP:-0}" != "1" ]] || return 0
    [[ -n "${PARAMS_SOURCE:-}" && "${PARAMS_SOURCE}" != "<stdin>" ]] || return 0
    INSTALL_PARAMS_DELETE=1
}

params_cleanup_on_success() {
    [[ "${INSTALL_PARAMS_DELETE:-0}" == "1" ]] || return 0
    [[ -n "${PARAMS_SOURCE:-}" && "${PARAMS_SOURCE}" != "<stdin>" ]] || return 0
    if rm -f -- "${PARAMS_SOURCE}" 2>/dev/null; then
        printf '已删除参数文件（含 API Token）：%s\n' "${PARAMS_SOURCE}" >&2
    else
        printf '参数文件删除失败，请手工删除：%s\n' "${PARAMS_SOURCE}" >&2
    fi
}

params_has_key() {
    jq -e --arg k "$1" \
        '.params as $p | ($p | has($k)) and ($p[$k] != null) and ($p[$k] != "")' \
        >/dev/null <<<"${PARAMS_JSON}"
}

params_json_value() {
    local key=$1 type=$2
    case "${type}" in
    str)
        jq -er --arg k "${key}" '
            .params[$k]
            | if type == "string" then .
              elif (type == "number" or type == "boolean") then tostring
              else error("需要字符串") end
        ' <<<"${PARAMS_JSON}" 2>/dev/null
        ;;
    json_object)
        jq -cer --arg k "${key}" '
            .params[$k]
            | if type == "object" then . else error("需要 JSON object") end
        ' <<<"${PARAMS_JSON}" 2>/dev/null
        ;;
    *)
        return 1
        ;;
    esac
}

params_type_label() {
    case "$1" in
    json_object) printf 'JSON object' ;;
    *) printf '字符串' ;;
    esac
}

# 声明一个安装字段。默认值在声明处直接用 bash 展开，因此可以引用已声明的字段：
#   params_declare DIRECT_DOMAIN --default "node.${CF_ZONE}" ...
params_declare() {
    local key=$1
    shift
    local type=str required=0 secret=0 when="" label="" default="" default_fn="" normalize="" check=""
    local provided=0 active=1 value="" normalized="" out status index
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --type)
            type=$2
            shift 2
            ;;
        --required)
            required=1
            shift
            ;;
        --secret)
            secret=1
            shift
            ;;
        --when)
            when=$2
            shift 2
            ;;
        --label)
            label=$2
            shift 2
            ;;
        --default)
            default=$2
            shift 2
            ;;
        --default-fn)
            default_fn=$2
            shift 2
            ;;
        --normalize)
            normalize=$2
            shift 2
            ;;
        --check)
            check=$2
            shift 2
            ;;
        *)
            params_die "内部错误：params_declare ${key} 收到未知选项 $1"
            ;;
        esac
    done
    case "${key}" in
    [A-Z]*)
        [[ "${key}" =~ ^[A-Z][A-Z0-9_]*$ ]] \
            || params_die "内部错误：字段名只能使用大写字母、数字与下划线：${key}"
        ;;
    *)
        params_die "内部错误：字段名必须以大写字母开头：${key}"
        ;;
    esac
    case "${type}" in
    str | json_object) ;;
    *) params_die "内部错误：字段 ${key} 的类型无效：${type}" ;;
    esac
    [[ -z "${label}" ]] || label=${label//$'\n'/ }
    [[ -n "${label}" ]] || label=${key}
    # bash 3.2 下空数组会被 set -u 判成 unbound variable，必须显式兜底。
    for index in ${PARAMS_DECLARED[@]+"${PARAMS_DECLARED[@]}"}; do
        [[ "${index}" != "${key}" ]] \
            || params_die "内部错误：字段 ${key} 被重复声明"
    done

    if [[ "${PARAMS_TEMPLATE_MODE}" == "1" ]]; then
        # 模板只给“单独也成立”的静态默认值：随机值/探测值在安装时生成，派生默认值（如
        # node.${CF_ZONE}）在依赖为空时会产出 "node." 这类半成品，曾让用户误以为已填好。
        # 这里先规范化再校验，不通过就留空，等用户自己填。
        local template_value=${default}
        if [[ -n "${template_value}" && -n "${normalize}" ]] \
            && declare -F "${normalize}" >/dev/null 2>&1; then
            template_value=$("${normalize}" "${template_value}" 2>/dev/null) \
                || template_value=""
        fi
        if [[ -n "${template_value}" && -n "${check}" ]] \
            && declare -F "${check}" >/dev/null 2>&1; then
            "${check}" "${template_value}" || template_value=""
        fi
        printf -v "${key}" '%s' "${template_value}"
        PARAMS_TEMPLATE_KEYS[${#PARAMS_TEMPLATE_KEYS[@]}]=${key}
        PARAMS_TEMPLATE_VALUES[${#PARAMS_TEMPLATE_VALUES[@]}]=${template_value}
        PARAMS_TEMPLATE_TYPES[${#PARAMS_TEMPLATE_TYPES[@]}]=${type}
        PARAMS_TEMPLATE_SECRETS[${#PARAMS_TEMPLATE_SECRETS[@]}]=${secret}
        PARAMS_TEMPLATE_REQUIRED[${#PARAMS_TEMPLATE_REQUIRED[@]}]=${required}
        PARAMS_TEMPLATE_LABELS[${#PARAMS_TEMPLATE_LABELS[@]}]=${label}
        return 0
    fi

    if params_has_key "${key}"; then
        provided=1
        if ! value=$(params_json_value "${key}" "${type}"); then
            params_error "${key}（${label}）：类型无效，需要 $(params_type_label "${type}")"
            value=""
        fi
    fi

    if [[ -n "${when}" ]]; then
        if ! declare -F "${when}" >/dev/null 2>&1; then
            params_die "内部错误：字段 ${key} 的 --when 条件函数不存在：${when}"
        fi
        "${when}" || active=0
    fi
    if [[ "${active}" == "0" ]]; then
        if [[ "${provided}" == "1" ]]; then
            params_error "${key}（${label}）：当前配置下不适用，请从参数文件中删除该字段"
        fi
        printf -v "${key}" '%s' ""
        # 不适用字段仍然算已声明：否则错误报告会额外把它当成拼写错误。
        PARAMS_DECLARED[${#PARAMS_DECLARED[@]}]=${key}
        PARAMS_LABELS[${#PARAMS_LABELS[@]}]=${label}
        PARAMS_SECRET_KEYS[${#PARAMS_SECRET_KEYS[@]}]=${secret}
        return 0
    fi

    if [[ "${provided}" == "0" ]]; then
        if [[ -n "${default_fn}" ]]; then
            if ! declare -F "${default_fn}" >/dev/null 2>&1; then
                params_die "内部错误：字段 ${key} 的 --default-fn 不存在：${default_fn}"
            fi
            value=$("${default_fn}") \
                || params_error "${key}（${label}）：无法生成默认值（${default_fn} 失败）"
        else
            value=${default}
        fi
    fi

    if [[ -n "${value}" && -n "${normalize}" ]]; then
        if ! declare -F "${normalize}" >/dev/null 2>&1; then
            params_die "内部错误：字段 ${key} 的 --normalize 函数不存在：${normalize}"
        fi
        # 规范化函数在失败时把原因写到 stderr；成功时只输出值，因此合并捕获即可。
        out=$("${normalize}" "${value}" 2>&1) && status=0 || status=$?
        if [[ "${status}" == "0" && -n "${out}" ]]; then
            value=${out}
        else
            params_error "${key}（${label}）：${out:-取值无效}"
            value=""
        fi
    fi

    if [[ -n "${value}" && -n "${check}" ]]; then
        if ! declare -F "${check}" >/dev/null 2>&1; then
            params_die "内部错误：字段 ${key} 的 --check 函数不存在：${check}"
        fi
        if ! "${check}" "${value}"; then
            if [[ "${secret}" == "1" ]]; then
                # 密钥校验失败时不能把明文带进终端或日志。
                params_error "${key}（${label}）：取值无效（密钥内容不显示）"
            else
                params_error "${key}（${label}）：取值无效：${value}"
            fi
        fi
    fi

    if [[ "${required}" == "1" && -z "${value}" && "${provided}" == "0" ]]; then
        params_error "缺少必填项：${key}（${label}）"
    fi

    printf -v "${key}" '%s' "${value}"
    PARAMS_DECLARED[${#PARAMS_DECLARED[@]}]=${key}
    PARAMS_LABELS[${#PARAMS_LABELS[@]}]=${label}
    PARAMS_SECRET_KEYS[${#PARAMS_SECRET_KEYS[@]}]=${secret}
}

params_check_unknown() {
    local key found declared
    while IFS= read -r key; do
        [[ -n "${key}" ]] || continue
        found=0
        for declared in "${PARAMS_DECLARED[@]}"; do
            if [[ "${declared}" == "${key}" ]]; then
                found=1
                break
            fi
        done
        if [[ "${found}" == "0" ]]; then
            params_error "未知字段：${key}（拼写错误？用 --print-params 查看 ${PARAMS_MODE} 模式的全部字段）"
        fi
    done < <(jq -r '.params | keys[]' <<<"${PARAMS_JSON}")
}

params_print_errors() {
    local index total=${#PARAMS_ERRORS[@]}
    printf '参数校验失败：共 %d 项错误\n' "${total}" >&2
    for ((index = 0; index < total; index++)); do
        printf '  %d) %s\n' "$((index + 1))" "${PARAMS_ERRORS[${index}]}" >&2
    done
}

params_print_summary() {
    local index key label secret value
    printf '\n参数来源：%s（mode=%s）\n' "${PARAMS_SOURCE}" "${PARAMS_MODE}" >&2
    for ((index = 0; index < ${#PARAMS_DECLARED[@]}; index++)); do
        key=${PARAMS_DECLARED[${index}]}
        label=${PARAMS_LABELS[${index}]}
        secret=${PARAMS_SECRET_KEYS[${index}]}
        value=${!key:-}
        if [[ "${secret}" == "1" ]]; then
            if [[ -n "${value}" ]]; then
                printf '  %-28s *** (%d 字符)\n' "${key}" "${#value}" >&2
            else
                printf '  %-28s (未设置)\n' "${key}" >&2
            fi
        elif [[ -z "${value}" ]]; then
            printf '  %-28s (未设置)\n' "${key}" >&2
        else
            printf '  %-28s %s\n' "${key}" "${value}" >&2
        fi
    done
    printf '\n' >&2
}

# 结束声明阶段：检查未知字段、跨字段约束，然后一次性报告全部错误。
params_finish() {
    local cross
    if [[ "${PARAMS_TEMPLATE_MODE}" == "1" ]]; then
        params_template_emit
        return 0
    fi
    params_check_unknown
    cross="params_cross_${PARAMS_MODE//-/_}"
    if declare -F "${cross}" >/dev/null 2>&1; then
        "${cross}"
    fi
    if [[ ${#PARAMS_WARNINGS[@]} -gt 0 ]]; then
        local index
        for ((index = 0; index < ${#PARAMS_WARNINGS[@]}; index++)); do
            printf '警告：%s\n' "${PARAMS_WARNINGS[${index}]}" >&2
        done
    fi
    if [[ ${#PARAMS_ERRORS[@]} -gt 0 ]]; then
        params_print_errors
        local retry_hint=${PARAMS_SOURCE}
        [[ "${retry_hint}" == "<stdin>" ]] && retry_hint="- --mode ${PARAMS_MODE}"
        params_die "安装未开始：请修正参数后重试（示例：easy_all ${retry_hint} --check-params）"
    fi
    params_print_summary
}

params_template_begin() {
    PARAMS_TEMPLATE_MODE=1
    PARAMS_MODE=$1
}

# --- 各模式共用的默认值与校验函数 ---

params_default_uuid() {
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
        return 0
    fi
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-Z' 'a-z'
        return 0
    fi
    local hex
    hex=$(openssl rand -hex 16) || return 1
    printf '%s-%s-4%s-8%s-%s\n' \
        "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
}

params_default_secret() {
    if declare -F generate_secret >/dev/null 2>&1; then
        generate_secret
        return 0
    fi
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

params_default_xhttp_path() {
    printf '/xhttp-%s\n' "$(openssl rand -hex 12)"
}

params_default_websocket_path() {
    printf '/ws-%s\n' "$(openssl rand -hex 16)"
}

params_default_worker_backup_path() {
    printf '/vless-%s\n' "$(openssl rand -hex 12)"
}

# 订阅 Token 单值格式（与 normalize_allowed_tokens 的约束保持一致）。
params_check_token() {
    [[ "$1" =~ ^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$ ]]
}

params_normalize_allowed_tokens() {
    local normalized
    normalized=$(normalize_allowed_tokens "$1") || return 1
    printf '%s\n' "${normalized}"
}

params_check_no_space() {
    [[ -n "$1" && "$1" != *[[:space:]]* ]]
}

# 各模式通用的条件字段判定（安装期变量在 params_declare 中按声明顺序赋值）。
params_when_subscription_enabled() {
    [[ "${SUBSCRIPTION_MODE:-}" != "link" ]]
}

params_when_quota_enabled() {
    [[ "${ENABLE_MONTHLY_QUOTA:-}" == "1" ]]
}

params_check_worker_name() {
    validate_cloudflare_worker_name "$1"
}

params_check_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *[[:cntrl:]]* ]]
}

params_check_quota_toggle() {
    [[ "$1" == "0" || "$1" == "1" ]]
}

params_check_worker_secret() {
    [[ "$1" =~ ^[A-Za-z0-9._~-]{16,128}$ ]]
}

params_check_backup_placement() {
    case "$1" in
    off | aws:ap-east-1) return 0 ;;
    esac
    return 1
}

params_check_nonnegative_int() {
    [[ "$1" =~ ^[0-9]{1,7}$ ]]
}

params_default_bunny_pull_name() {
    printf 'easyall%s\n' "$(openssl rand -hex 6)"
}

params_check_bunny_pull_name() {
    [[ "$1" =~ ^[a-z0-9-]{5,50}$ ]]
}

params_normalize_sub_port_mode() {
    case "$1" in
    1 | 443) printf '443\n' ;;
    2 | dynamic) printf 'dynamic\n' ;;
    *) return 1 ;;
    esac
}

params_check_reality_node_host() {
    validate_domain "$1" || validate_ipv4 "$1"
}

params_check_websocket_path() {
    [[ "$1" =~ ^/[A-Za-z0-9/_-]{4,120}$ ]]
}

params_check_reboot_mode() {
    case "$1" in
    1 | 2 | 3) return 0 ;;
    esac
    return 1
}

params_check_hour() {
    [[ "$1" =~ ^[0-9]{1,2}$ ]] && ((10#$1 <= 23))
}

params_check_cf_token() {
    [[ "$1" =~ ^[A-Za-z0-9_-]{20,100}$ ]]
}

params_check_gcore_token() {
    params_check_no_space "$1"
}

params_normalize_reality_target() {
    printf '%s:%s\n' "$(normalize_domain "${1%:*}")" "${1##*:}"
}

# 方案 A：校验前只安装参数校验必需的最小依赖（jq、ca-certificates）。
# 除这一步外，参数校验失败不会对系统做任何修改。
params_install_dependencies() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    if [[ "$(id -u)" != "0" ]]; then
        params_die "缺少 jq，且当前不是 root；请先安装：sudo apt-get install -y jq"
    fi
    export DEBIAN_FRONTEND=noninteractive
    # stdin 重定向到 /dev/null：--params - 时参数要从标准输入读，不能被 apt 抢走。
    apt-get -o DPkg::Lock::Timeout=300 update </dev/null >/dev/null \
        || params_die "更新软件包索引失败；参数校验需要 jq"
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends \
        jq ca-certificates </dev/null >/dev/null \
        || params_die "安装参数校验依赖（jq、ca-certificates）失败"
}

# --print-params：stdout 输出可直接保存为参数文件的 JSON，stderr 输出字段说明。
params_template_emit() {
    local index key value type secret required label entries='[]'
    for ((index = 0; index < ${#PARAMS_TEMPLATE_KEYS[@]}; index++)); do
        key=${PARAMS_TEMPLATE_KEYS[${index}]}
        value=${PARAMS_TEMPLATE_VALUES[${index}]}
        type=${PARAMS_TEMPLATE_TYPES[${index}]}
        secret=${PARAMS_TEMPLATE_SECRETS[${index}]}
        required=${PARAMS_TEMPLATE_REQUIRED[${index}]}
        label=${PARAMS_TEMPLATE_LABELS[${index}]}
        entries=$(jq -c \
            --arg key "${key}" --arg value "${value}" --arg type "${type}" \
            --argjson secret "${secret}" --argjson required "${required}" --arg label "${label}" \
            '. + [{key:$key,value:$value,type:$type,secret:$secret,required:$required,label:$label}]' \
            <<<"${entries}")
    done
    jq -n --arg mode "${PARAMS_MODE}" --argjson entries "${entries}" '
        {
          schema_version: 1,
          mode: $mode,
          params: (reduce $entries[] as $e ({};
            .[$e.key] = (
              if $e.type == "json_object" then
                (if $e.value == "" then null else ($e.value | fromjson) end)
              else $e.value end)))
        }'
    printf '\n%s 模式字段说明（必填字段必须填写；留空表示不启用该可选功能）：\n' \
        "${PARAMS_MODE}" >&2
    for ((index = 0; index < ${#PARAMS_TEMPLATE_KEYS[@]}; index++)); do
        key=${PARAMS_TEMPLATE_KEYS[${index}]}
        secret=${PARAMS_TEMPLATE_SECRETS[${index}]}
        required=${PARAMS_TEMPLATE_REQUIRED[${index}]}
        label=${PARAMS_TEMPLATE_LABELS[${index}]}
        local flags=""
        [[ "${required}" == "1" ]] && flags="必填"
        [[ "${secret}" == "1" ]] && flags="${flags:+${flags}、}密钥"
        [[ -n "${flags}" ]] || flags="可选"
        printf '  %-30s %s  %s\n' "${key}" "${flags}" "${label}" >&2
    done
    printf '\n提示：填好后用 easy_all <文件> --check-params 校验，再用 easy_all <文件> 安装（成功后会删除该文件）。\n' >&2
}
