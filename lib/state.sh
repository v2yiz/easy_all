#!/usr/bin/env bash

# 单一来源：状态 schema、五模式字段集与持久变量清单。
#
# launcher 在加载任何 Profile 之前就要分类状态并做 schema 门禁，因此本文件只放纯函数
# 与常量清单：不得依赖运行时库、日志、Profile 常量或任何已加载的 state 值。
#
# STATE_VERSION=1 是唯一受支持的 schema：schema 0 由旧版本卸载，本版本不接管、
# 不迁移、不为旧字段保留兼容分支（design §3 D / §5）。

if [[ "${EASY_ALL_STATE_LIB_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || exit 0
fi
EASY_ALL_STATE_LIB_LOADED=1

readonly EASY_ALL_STATE_SCHEMA_VERSION="1"

# 五模式全部持久字段（design §5）。
EASY_ALL_STATE_COMMON_FIELDS=(
    PROTOCOL
    TCP_ACCELERATION
    VPS_PUBLIC_IPV4
    CF_ZONE
    CLOUDFLARE_ZONE_ID
    SUBSCRIPTION_MODE
    SUB_DOWNLOAD_NAME
    OWNER_TOKEN
    ALLOWED_TOKENS
    SUBSCRIPTION_CONFIG
    MIHOMO_TEMPLATE_SNAPSHOT
    SCHEDULED_REBOOT_ENABLED
    SCHEDULED_REBOOT_HOUR
)
# 模式 1/3/5：AnyTLS 直连入口（443）。
EASY_ALL_STATE_DIRECT_FIELDS=(
    DIRECT_DOMAIN
    DIRECT_NODE_NAME
    ANYTLS_PASSWORD
)
# 模式 2/3/4/5：CDN 入口（本机回环 10086 + Caddy 站点主机）。
EASY_ALL_STATE_CDN_FIELDS=(
    CF_NODE_DOMAIN
    CF_NODE_PREFIX
    VLESS_UUID
    VLESS_PATH
)
# 模式 4/5：CloudFront、ACM、源站与 985GB 保护。
EASY_ALL_STATE_CLOUDFRONT_FIELDS=(
    SUBSCRIPTION_DOMAIN
    CF_ORIGIN_DOMAIN
    ORIGIN_HEADER_SECRET
    AWS_CLOUDFRONT_DISTRIBUTION_ID
    AWS_CLOUDFRONT_DOMAIN
    AWS_ACM_CERTIFICATE_ARN
    CDN_TRAFFIC_PROTECTION_GB
)
# 模式 1 deploy：订阅站点与 Origin Rule；link 模式没有这些字段。
EASY_ALL_STATE_ANYTLS_DEPLOY_FIELDS=(
    SUBSCRIPTION_DOMAIN
    CLOUDFLARE_ORIGIN_RULESET_ID
    CLOUDFLARE_ORIGIN_RULE_ID
)
# 模式 2：Cloudflare Origin CA（订阅域名由节点域名派生，不落盘）。
EASY_ALL_STATE_ORIGIN_CA_FIELDS=(
    CLOUDFLARE_ORIGIN_CERT_ID
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
)
# 模式 3：节点域名橙云回源到 8443 的 Origin Rule（订阅域名由节点域名派生，不落盘）。
EASY_ALL_STATE_CLOUDFLARE_ORIGIN_RULE_FIELDS=(
    CLOUDFLARE_ORIGIN_RULESET_ID
    CLOUDFLARE_ORIGIN_RULE_ID
)

state_protocol_valid() {
    case "${1:-}" in
    anytls | cloudfront | cloudflare | combined-cloudfront | combined-cloudflare) return 0 ;;
    *) return 1 ;;
    esac
}

state_protocol_has_direct_entry() {
    case "${1:-}" in
    anytls | combined-cloudfront | combined-cloudflare) return 0 ;;
    *) return 1 ;;
    esac
}

state_protocol_has_cdn_entry() {
    case "${1:-}" in
    cloudfront | cloudflare | combined-cloudfront | combined-cloudflare) return 0 ;;
    *) return 1 ;;
    esac
}

state_protocol_uses_cloudfront() {
    case "${1:-}" in
    cloudfront | combined-cloudfront) return 0 ;;
    *) return 1 ;;
    esac
}

state_protocol_uses_origin_ca() {
    [[ "${1:-}" == "cloudflare" ]]
}

# 模式 1 的订阅字段取决于 SUBSCRIPTION_MODE（deploy/link）；其他模式不区分。
state_protocol_has_subscription_site() {
    local protocol=${1:-} subscription_mode=${2:-deploy}
    case "${protocol}" in
    anytls) [[ "${subscription_mode}" != "link" ]] ;;
    cloudfront | cloudflare | combined-cloudfront | combined-cloudflare) return 0 ;;
    *) return 1 ;;
    esac
}

# 输出某模式（+订阅模式）的结构必需字段，每行一个。未知协议不猜测，直接返回 1。
state_required_fields() {
    local protocol=${1:-} subscription_mode=${2:-deploy} field
    state_protocol_valid "${protocol}" || return 1
    for field in "${EASY_ALL_STATE_COMMON_FIELDS[@]}"; do
        printf '%s\n' "${field}"
    done
    if state_protocol_has_direct_entry "${protocol}"; then
        for field in "${EASY_ALL_STATE_DIRECT_FIELDS[@]}"; do
            printf '%s\n' "${field}"
        done
    fi
    if state_protocol_has_cdn_entry "${protocol}"; then
        for field in "${EASY_ALL_STATE_CDN_FIELDS[@]}"; do
            printf '%s\n' "${field}"
        done
    fi
    if state_protocol_uses_cloudfront "${protocol}"; then
        for field in "${EASY_ALL_STATE_CLOUDFRONT_FIELDS[@]}"; do
            printf '%s\n' "${field}"
        done
    fi
    if state_protocol_uses_origin_ca "${protocol}"; then
        for field in "${EASY_ALL_STATE_ORIGIN_CA_FIELDS[@]}"; do
            printf '%s\n' "${field}"
        done
    fi
    if [[ "${protocol}" == "combined-cloudflare" ]]; then
        for field in "${EASY_ALL_STATE_CLOUDFLARE_ORIGIN_RULE_FIELDS[@]}"; do
            printf '%s\n' "${field}"
        done
    fi
    if [[ "${protocol}" == "anytls" ]] \
        && state_protocol_has_subscription_site "${protocol}" "${subscription_mode}"; then
        for field in "${EASY_ALL_STATE_ANYTLS_DEPLOY_FIELDS[@]}"; do
            printf '%s\n' "${field}"
        done
    fi
}

# state.env 只是 = 分隔的 shell 赋值；这里只取值，不 source，避免旧/外部文件执行代码。
state_file_value() {
    local file=$1 key=$2 line value
    [[ -f "${file}" ]] || return 1
    line=$(grep -E "^${key}=" "${file}" | tail -n 1) || return 1
    value=${line#*=}
    value=${value#\'}
    value=${value%\'}
    value=${value#\"}
    value=${value%\"}
    printf '%s\n' "${value}"
}

state_file_schema() {
    state_file_value "$1" STATE_VERSION
}

# 只判断键是否存在（不看去值）：与 state_missing_fields 的 grep 口径一致。
# 缺行与「行存在但值为空」必须分开处理：后者仍属旧 schema 提示。
state_file_has_field() {
    local file=$1 field=$2
    [[ -f "${file}" ]] || return 1
    grep -Eq "^${field}=" "${file}" 2>/dev/null
}

state_schema_supported() {
    [[ "${1:-}" == "${EASY_ALL_STATE_SCHEMA_VERSION}" ]]
}

# 允许“键存在但值为空”的字段（design §5）。
# 关闭定时重启时 SCHEDULED_REBOOT_HOUR 合法地为空；不发布订阅站点的模式（模式 1 link）
# 不写模板快照。除这两类条件字段外，其余必需字段必须非空。
# 参数：协议、订阅模式、字段名、SCHEDULED_REBOOT_ENABLED 的当前值。
state_field_allows_empty() {
    local protocol=${1:-} subscription_mode=${2:-} field=${3:-} reboot_enabled=${4:-0}
    case "${field}" in
    SCHEDULED_REBOOT_HOUR) [[ "${reboot_enabled}" != "1" ]] ;;
    MIHOMO_TEMPLATE_SNAPSHOT)
        ! state_protocol_has_subscription_site "${protocol}" "${subscription_mode}"
        ;;
    *) return 1 ;;
    esac
}

# 打印缺失字段；字段齐全时无输出并返回 0。未知协议一律视为不完整。
# “缺失”包括键本身不存在：合法空值仍然要求键存在，否则无法区分旧文件与空值。
state_missing_fields() {
    local file=$1 protocol subscription_mode field value missing=0 reboot_enabled
    protocol=$(state_file_value "${file}" PROTOCOL || true)
    subscription_mode=$(state_file_value "${file}" SUBSCRIPTION_MODE || true)
    reboot_enabled=$(state_file_value "${file}" SCHEDULED_REBOOT_ENABLED || true)
    if ! state_protocol_valid "${protocol}"; then
        printf 'PROTOCOL\n'
        return 1
    fi
    while IFS= read -r field; do
        if ! grep -Eq "^${field}=" "${file}" 2>/dev/null; then
            printf '%s\n' "${field}"
            missing=1
            continue
        fi
        value=$(state_file_value "${file}" "${field}" || true)
        if [[ -z "${value}" ]] && ! state_field_allows_empty \
            "${protocol}" "${subscription_mode:-deploy}" "${field}" "${reboot_enabled}"; then
            printf '%s\n' "${field}"
            missing=1
        fi
    done < <(state_required_fields "${protocol}" "${subscription_mode:-deploy}")
    return "${missing}"
}

# 追加原子写的候选文件内容：调用方按 state_required_fields 逐项准备变量后调用。
state_render() {
    local destination=$1 field
    shift
    [[ -n "${destination}" ]] || return 1
    {
        printf 'STATE_VERSION=%q\n' "${EASY_ALL_STATE_SCHEMA_VERSION}"
        for field in "$@"; do
            printf '%s=%q\n' "${field}" "${!field:-}"
        done
    } >"${destination}"
}

# 缺 STATE_VERSION 只可能来自截断/改坏：所有历史写出者都会写这一行。旧版本 loader
# 同样要求版本行，因此不能照搬「用旧版本卸载」；提示按原安装版本给出可执行的恢复步骤。
state_damaged_state_message() {
    printf '检测到状态文件缺少 STATE_VERSION（easy_all 各版本都会写这一行；缺失说明文件被截断或改坏）：%s。请先确认本机原来的安装版本再处置：5.x 安装 → 备份后在该文件首行补回 STATE_VERSION=1，再执行 sudo easy_all uninstall；4.x 安装 → 补回 STATE_VERSION=0 后用 4.x 的 sudo easy_all uninstall（两代 loader 都要求版本行，不能直接卸载）；原版本不明时请保留现场核实，不要修改该文件。\n' \
        "${1:-状态文件}"
}

# schema 门禁文案：旧状态只能由写它的旧版本卸载，本版本不做自动转换。
state_legacy_rejection_message() {
    printf '检测到旧版（schema %s）easy_all 状态；当前版本只支持 schema %s，不能接管或自动迁移。请先用安装该状态的旧版本执行 sudo easy_all uninstall（必要时追加 --purge-cloud 清理云端资源），再重新安装。\n' \
        "${1:-未知}" "${EASY_ALL_STATE_SCHEMA_VERSION}"
}
