#!/usr/bin/env bash
# One-shot cleanup of easy_all-created Cloudflare resources. Works without local state.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"
readonly RECORD_COMMENT_PREFIX="easy_all"
# 新栈 Origin Rule 的 ref 前缀是 easy_all-<hex16>；保留旧前缀以支持清理历史资源。
readonly RULE_REF_PREFIX="easy_all"
readonly LEGACY_RULE_REF_PREFIX="easy_all_"
readonly RULESET_NAME_PREFIX="easy_all"
# --domain 下只接受本项目实际生成的单项表达式（允许外围/词间空白）；其它写法无法证明
# 作用范围，一律保留。完整匹配整条 expression，不存在“取第一个主机就猜语义”的降级路径。
readonly RULE_HOST_EXPRESSION_RE='^[[:space:]]*http\.host[[:space:]]+eq[[:space:]]+"([^"[:space:]]+)"[[:space:]]*$'

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/log.sh"

usage() {
    local status=${1:-2} fd=2
    ((status == 0)) && fd=1
    cat >&"${fd}" <<'EOF'
用法: easy_all purge-cloudflare [--domain <域名>[,<域名>...]] [--all] [--yes]

  --domain <域名>  清理这些域名所在 Zone 内由 easy_all 创建的资源
                   传 Zone 根域名（如 example.com）会覆盖其下全部相关记录；
                   传完整主机名（如 cf.example.com）只清理该域名及其直接关联对象
  --all            清理 Token 可见的所有 Zone 中的 easy_all 资源
  --yes            跳过确认（非交互模式必须显式给出）

环境变量：EASY_ALL_PURGE_MAX_PAGES  每个列表接口的分页上限（默认 100 页 × 100 条）

识别规则：DNS 记录注释以 easy_all 开头；
规则按 ref 以 easy_all_ 开头且表达式完整等于 http.host eq "待清理域名"（括号、or/and/not、集合等复杂表达式一律保留）；
ruleset 名称以 easy_all 开头且清空后才删除；
Origin CA 证书只在其全部 hostname 都属于 easy_all 记录或输入域名时删除。
Zone 内 easy_all DNS 记录已删除时，规则与证书需要传完整主机名才能识别。
不删除 Zone 本身。
EOF
    exit "${status}"
}

case "${1:-}" in
-h | --help) usage 0 ;;
esac
[[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行此脚本"
for _cmd in curl jq; do
    command -v "${_cmd}" >/dev/null 2>&1 \
        || die "执行清理需要 ${_cmd}，请先安装：apt-get install -y ${_cmd}"
done

PURGE_ALL=0
ASSUME_YES=0
DOMAIN_COUNT=0
DOMAINS=()
add_domains() {
    local input=$1 domain
    local -a list
    IFS=', ' read -r -a list <<<"${input}"
    for domain in "${list[@]}"; do
        [[ -n "${domain}" ]] || continue
        DOMAINS+=("$(tr '[:upper:]' '[:lower:]' <<<"${domain%.}")")
        DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
    done
}

while (($#)); do
    case "$1" in
    --domain) shift; [[ -n "${1:-}" ]] || usage; add_domains "$1" ;;
    --all) PURGE_ALL=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) usage ;;
    esac
    shift
done

if ((PURGE_ALL == 0)) && ((DOMAIN_COUNT == 0)); then
    [[ -t 0 ]] || usage
    printf '清理范围：\n  1. 指定域名所在 Zone 的 easy_all 资源\n  2. Token 可见的所有 Zone\n' >&2
    read_prompt '请选择 [1]: ' _scope
    case "${_scope:-1}" in
    1)
        read_prompt '域名（Zone 根域名清理其下全部；完整主机名只清理该域名）: ' _input
        add_domains "${_input}"
        ;;
    2) PURGE_ALL=1 ;;
    *) usage ;;
    esac
fi
if ((PURGE_ALL == 0)) && ((DOMAIN_COUNT == 0)); then
    usage
fi

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
    [[ -t 0 ]] || die "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
    read_prompt 'Cloudflare API Token（不落盘）: ' CLOUDFLARE_API_TOKEN 1
    printf '\n' >&2
fi
# Token 会写进 curl 的 header 文件，换行会注入额外请求头：长度与字符集必须与
# lib/cf-dns.sh 的 cloudflare_token_format_valid 同一口径。
[[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
    && "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]+$ ]] \
    || die "CLOUDFLARE_API_TOKEN 格式无效"

RUNTIME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/easy_all-cf-purge.XXXXXX") \
    || die "无法创建临时目录"
trap 'rm -rf -- "${RUNTIME_TMP}"' EXIT
if [[ -f "${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE:-/etc/easy_all/state.env}}" ]]; then
    warn "检测到本机已有 easy_all 安装；清理 Cloudflare 资源后需要重新安装或 apply-cloud"
fi

domain_equal() {
    local value=$1 domain
    ((DOMAIN_COUNT > 0)) || return 1
    for domain in "${DOMAINS[@]}"; do
        [[ "${value}" == "${domain}" ]] && return 0
    done
    return 1
}

# Zone 根域名才覆盖其下子域：只有输入精确等于当前 Zone name 时才做点分隔后缀匹配。
# 完整主机名只精确匹配，避免 cf.example.com 的处理范围波及 x.cf.example.com。
domain_scope() {
    local value=$1 zone domain
    zone=$(tr '[:upper:]' '[:lower:]' <<<"${2:-}")
    ((DOMAIN_COUNT > 0)) || return 1
    for domain in "${DOMAINS[@]}"; do
        [[ "${value}" == "${domain}" ]] && return 0
        [[ -n "${zone}" && "${domain}" == "${zone}" && "${value}" == *".${domain}" ]] && return 0
    done
    return 1
}

in_scope_host() {
    local host=$1
    [[ -n "${host}" ]] || return 1
    domain_equal "${host}" || grep -Fxq "${host}" "${RUNTIME_TMP}/allowed-names" 2>/dev/null
}

cf_api() {
    local method=$1 path=$2 body=${3:-} response code headers
    headers="${RUNTIME_TMP}/cf-headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
        "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    if [[ -n "${body}" ]]; then
        printf '%s' "${body}" >"${RUNTIME_TMP}/cf-body"
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "@${headers}" --data-binary "@${RUNTIME_TMP}/cf-body" -w $'\n%{http_code}' \
            "${CF_API_BASE}${path}") || return 1
    else
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
            -H "@${headers}" -w $'\n%{http_code}' "${CF_API_BASE}${path}") || return 1
    fi
    code=${response##*$'\n'}
    response=${response%$'\n'*}
    if [[ ! "${code}" =~ ^2[0-9][0-9]$ ]]; then
        printf '%s\n' "${response:-<empty>}" >&2
        return 1
    fi
    # 与 lib/cf-dns.sh 的 Cloudflare 客户端同宽：成功 DELETE 可以是 200/204 空体。
    # GET 空体、失败状态空体与带错误 JSON 的 DELETE 仍然算失败。
    if [[ "${method}" == "DELETE" && ( "${code}" == "200" || "${code}" == "204" ) \
        && -z "${response//[[:space:]]/}" ]]; then
        printf 'null\n'
        return 0
    fi
    if ! jq -e '.success == true' <<<"${response}" >/dev/null 2>&1; then
        jq -c '.errors? // []' <<<"${response}" >&2 || printf '%s\n' "${response}" >&2
        return 1
    fi
    jq -c '.result' <<<"${response}"
}

cf_list() {
    local path=$1 separator='?' page=1 batch all='[]' count prev_batch=""
    local max_pages=${EASY_ALL_PURGE_MAX_PAGES:-100}
    [[ "${max_pages}" =~ ^[1-9][0-9]*$ ]] \
        || die "EASY_ALL_PURGE_MAX_PAGES 必须是正整数：${max_pages}"
    [[ "${path}" != *\?* ]] || separator='&'
    while :; do
        batch=$(cf_api GET "${path}${separator}per_page=100&page=${page}") || return 1
        # jq 必须显式 -n：不传输入时它会读 stdin，在交互终端上会永久阻塞（现场：purge-cloudflare 挂起）。
        all=$(jq -nc --argjson all "${all}" --argjson batch "${batch}" '$all + $batch')
        count=$(jq 'length' <<<"${batch}")
        ((count == 100)) || break
        # 接口忽略 page 时每页完全相同，早点报错，不靠页数硬上限来发现。
        if [[ -n "${prev_batch}" && "${batch}" == "${prev_batch}" ]]; then
            die "接口疑似未按 page 分页（第 ${page} 页与上一页完全相同），已停止以免无限循环：${path}"
        fi
        prev_batch=${batch}
        page=$((page + 1))
        # 先多取一页作为“结束探测页”：恰好 max_pages 整页的数据也能正常结束。
        if ((page > max_pages + 1)); then
            die "扫描超过 ${max_pages} 页仍未结束（${path}）；如账户确实有更多数据，可用 EASY_ALL_PURGE_MAX_PAGES 调大上限"
        fi
    done
    printf '%s' "${all}"
}

: >"${RUNTIME_TMP}/zones.tsv"
if ((PURGE_ALL == 1)); then
    zones=$(cf_list "/zones?status=active&match=all&") || die "读取 Cloudflare Zone 失败"
    jq -r '.[] | [.id, .name, .account.id] | @tsv' <<<"${zones}" >>"${RUNTIME_TMP}/zones.tsv"
else
    for domain in "${DOMAINS[@]}"; do
        candidate=${domain}
        while [[ "${candidate}" == *.* ]]; do
            zone=$(cf_api GET "/zones?name=${candidate}&status=active&per_page=50") \
                || die "查询 Cloudflare Zone 失败：${candidate}"
            # 与 lib/cf-dns.sh 同口径：按 name 精确匹配（大小写不敏感）后要求唯一。
            # 盲取首个在 Token 可见多个同名 active Zone 时会清到错的 Zone。
            matches=$(jq -c --arg name "${candidate}" \
                '[.[]? | select((.name | ascii_downcase) == ($name | ascii_downcase))]' <<<"${zone}")
            match_count=$(jq 'length' <<<"${matches}")
            ((match_count <= 1)) || die "Token 可见多个同名 active Zone：${candidate}；请改用只授权目标 Zone 的 Token，或先在控制台处理重复 Zone"
            if ((match_count == 1)); then
                jq -r '.[0] | [.id, .name, .account.id] | @tsv' <<<"${matches}" \
                    >>"${RUNTIME_TMP}/zones.tsv"
                break
            fi
            candidate=${candidate#*.}
        done
    done
    sort -u -o "${RUNTIME_TMP}/zones.tsv" "${RUNTIME_TMP}/zones.tsv"
    [[ -s "${RUNTIME_TMP}/zones.tsv" ]] || die "没有找到包含这些域名的 active Zone"
fi

for file in dns rules rulesets certs allowed-names; do
    : >"${RUNTIME_TMP}/${file}.tsv"
done

zone_name_for() {
    awk -F'\t' -v id="$1" '$1 == id {print $2; exit}' "${RUNTIME_TMP}/zones.tsv"
}

# 1) DNS 记录：按 easy_all 注释识别，--domain 时按域名范围过滤
ruleset_warned=0
while IFS=$'\t' read -r zone_id zone_name account_id; do
    [[ -n "${zone_id}" ]] || continue
    records=$(cf_list "/zones/${zone_id}/dns_records?") || die "读取 DNS 记录失败：${zone_name}"
    while IFS=$'\t' read -r record_id name comment; do
        [[ -n "${record_id}" ]] || continue
        [[ "${comment}" == "${RECORD_COMMENT_PREFIX}"* ]] || continue
        if ((PURGE_ALL == 0)); then
            domain_scope "${name}" "${zone_name}" || continue
        fi
        printf '%s\t%s\t%s\n' "${zone_id}" "${record_id}" "${name}" >>"${RUNTIME_TMP}/dns.tsv"
        printf '%s\n' "${name}" >>"${RUNTIME_TMP}/allowed-names"
    done < <(jq -r '.[] | [.id, .name, (.comment // "")] | @tsv' <<<"${records}")


# 2) 规则：ref、表达式与域名范围都要匹配
    # 只授 DNS/证书权限的 Token 读 /rulesets 会 403：规则只是附带清理对象，不能因此中断整个清理，
    # 否则第 1 阶段收集的 DNS 记录与第 4 阶段的证书都不会被删除（与证书读取同宽）。
    rulesets=$(cf_list "/zones/${zone_id}/rulesets?") || {
        ((ruleset_warned == 1)) || warn "无法读取 ruleset（Token 可能缺少规则权限），跳过规则清理：${zone_name}"
        ruleset_warned=1
        rulesets="[]"
    }
    for ruleset_id in $(jq -r '.[].id' <<<"${rulesets}"); do
        detail=$(cf_api GET "/zones/${zone_id}/rulesets/${ruleset_id}") || continue
        rs_name=$(jq -r '.name // empty' <<<"${detail}")
        while IFS=$'\t' read -r rule_id rule_ref expression; do
            [[ -n "${rule_id}" ]] || continue
            [[ "${rule_ref}" == "${RULE_REF_PREFIX}-"* || "${rule_ref}" == "${LEGACY_RULE_REF_PREFIX}"* ]] || continue
            if ((PURGE_ALL == 0)); then
                # 表达式必须完整匹配，且任何非空残留都让该规则保留。
                [[ "${expression}" =~ ${RULE_HOST_EXPRESSION_RE} ]] || continue
                host=$(tr '[:upper:]' '[:lower:]' <<<"${BASH_REMATCH[1]}")
                in_scope_host "${host}" || continue
            fi
            printf '%s\t%s\t%s\t%s\n' "${zone_id}" "${ruleset_id}" "${rule_id}" "${rule_ref}" \
                >>"${RUNTIME_TMP}/rules.tsv"
        done < <(jq -r '.rules[]? | [.id, (.ref // ""), (.expression // "")] | @tsv' <<<"${detail}")
        if [[ "${rs_name}" == "${RULESET_NAME_PREFIX}"* ]]; then
            printf '%s\t%s\t%s\n' "${zone_id}" "${ruleset_id}" "${rs_name}" >>"${RUNTIME_TMP}/rulesets.tsv"
        fi
    done
done <"${RUNTIME_TMP}/zones.tsv"

# 4) Origin CA：按 Zone 查询（满足 Zone-scoped Token），全部 hostname 在范围内才删
: >"${RUNTIME_TMP}/cert-seen.tsv"
cert_warned=0
while IFS=$'\t' read -r zone_id zone_name account_id; do
    [[ -n "${zone_id}" ]] || continue
    certs=$(cf_list "/certificates?zone_id=${zone_id}&") || {
        ((cert_warned == 1)) || warn "无法读取 Origin CA 证书（Token 可能缺少证书权限），跳过证书"
        cert_warned=1
        continue
    }
    while IFS= read -r certificate; do
        [[ -n "${certificate}" ]] || continue
        cert_id=$(jq -r '.id // empty' <<<"${certificate}")
        [[ -n "${cert_id}" ]] || continue
        grep -Fqx "${cert_id}" "${RUNTIME_TMP}/cert-seen.tsv" && continue
        names=$(jq -r '.hostnames[]?' <<<"${certificate}" | tr '[:upper:]' '[:lower:]')
        [[ -n "${names}" ]] || continue
        covered=1
        while IFS= read -r cert_host; do
            [[ -n "${cert_host}" ]] || continue
            in_scope_host "${cert_host}" || covered=0
            ((covered == 1)) || break
        done <<<"${names}"
        if ((covered == 1)); then
            printf '%s\n' "${cert_id}" >>"${RUNTIME_TMP}/cert-seen.tsv"
            printf '%s\t%s\n' "${cert_id}" "$(tr '\n' ',' <<<"${names}" | sed 's/,$//')" \
                >>"${RUNTIME_TMP}/certs.tsv"
        fi
    done < <(jq -c '.[]' <<<"${certs}")
done <"${RUNTIME_TMP}/zones.tsv"

# 全部 Zone 收集完成后统一判断：逐 Zone 判断会在前面的 Zone 恰好没有 easy_all DNS 记录时误报，
# 多 Zone 时还会重复提示。--all 语义不变：不按域名范围过滤，也就没有这条提示。
if ((PURGE_ALL == 0)) && [[ ! -s "${RUNTIME_TMP}/allowed-names" ]]; then
    warn "没有匹配到 easy_all DNS 记录；规则与 Origin CA 需要传入完整主机名（如 cf.example.com,sub.example.com）才能识别"
fi

total=0
print_plan() {
    local label=$1 file=$2
    while IFS=$'\t' read -r a b c d; do
        [[ -n "${a}" ]] || continue
        total=$((total + 1))
        case "${label}" in
        "DNS 记录") printf '  %-11s %s %s\n' "${label}" "$(zone_name_for "${a}")" "${c}" ;;
        "规则") printf '  %-11s %s %s\n' "${label}" "$(zone_name_for "${a}")" "${d}" ;;
        "Ruleset") printf '  %-11s %s %s\n' "${label}" "$(zone_name_for "${a}")" "${c}" ;;
        "Origin CA") printf '  %-11s %s\n' "${label}" "${b}" ;;
        esac
    done <"${RUNTIME_TMP}/${file}.tsv"
}
print_plan "规则" rules
print_plan "Ruleset" rulesets
print_plan "Origin CA" certs
print_plan "DNS 记录" dns

if ((total == 0)); then
    info "没有匹配到 easy_all 创建的 Cloudflare 资源"
    exit 0
fi

info "以上 ${total} 个 Cloudflare 对象将被删除（不删除 Zone）"
if ((ASSUME_YES == 0)); then
    [[ -t 0 ]] || die "非交互模式必须加 --yes 才能删除"
    read_prompt '确认删除？[y/N]: ' _answer
    [[ "${_answer}" =~ ^[Yy]$ ]] || die "已取消"
fi

failures=0
purge() {
    local kind=$1 label=$2 path=$3
    if (cf_api DELETE "${path}" >/dev/null); then
        success "已删除 ${kind}：${label}"
    else
        warn "删除失败 ${kind}：${label}"
        failures=$((failures + 1))
    fi
}

while IFS=$'\t' read -r zone_id ruleset_id rule_id rule_ref; do
    [[ -n "${rule_id}" ]] || continue
    purge "规则" "${rule_ref}" "/zones/${zone_id}/rulesets/${ruleset_id}/rules/${rule_id}"
done <"${RUNTIME_TMP}/rules.tsv"
while IFS=$'\t' read -r zone_id ruleset_id rs_name; do
    [[ -n "${ruleset_id}" ]] || continue
    remaining=$(cf_api GET "/zones/${zone_id}/rulesets/${ruleset_id}" 2>/dev/null \
        | jq '.rules | length' 2>/dev/null || printf '')
    [[ "${remaining}" =~ ^[0-9]+$ ]] && ((remaining == 0)) || continue
    purge "Ruleset" "${rs_name}" "/zones/${zone_id}/rulesets/${ruleset_id}"
done <"${RUNTIME_TMP}/rulesets.tsv"
while IFS=$'\t' read -r cert_id hostnames; do
    [[ -n "${cert_id}" ]] || continue
    purge "Origin CA" "${hostnames}" "/certificates/${cert_id}"
done <"${RUNTIME_TMP}/certs.tsv"
while IFS=$'\t' read -r zone_id record_id name; do
    [[ -n "${record_id}" ]] || continue
    purge "DNS 记录" "${name}" "/zones/${zone_id}/dns_records/${record_id}"
done <"${RUNTIME_TMP}/dns.tsv"

((failures == 0)) || die "有 ${failures} 个对象删除失败；可修复后重试同一命令"
success "Cloudflare 清理完成：${total} 个对象"
