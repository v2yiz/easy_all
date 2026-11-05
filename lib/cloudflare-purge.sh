#!/usr/bin/env bash
# One-shot cleanup of easy_all-created Cloudflare resources. Works without local state.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"
readonly RECORD_COMMENT_PREFIX="easy_all"
readonly WORKER_NAME_PREFIX="easyall"
readonly RULE_REF_PREFIX="easy_all_"
readonly RULESET_NAME_PREFIX="easy_all"

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

识别规则：DNS 记录注释以 easy_all 开头；Worker 名称以 easyall 开头或绑定到待清理域名；
规则按 ref 以 easy_all_ 开头且表达式只涉及待清理域名；ruleset 名称以 easy_all 开头且清空后才删除；
Origin CA 证书只在其全部 hostname 都属于 easy_all 记录或输入域名时删除。
--all 只按 easyall 名称清理 Worker，不会按域名反查用户自己的 Worker。
Zone 内 easy_all DNS 记录已删除时，规则与证书需要传完整主机名才能识别。
不删除 Zone 本身，也不删除 Bunny 模式创建的无注释 DNS 记录。
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
[[ ${#CLOUDFLARE_API_TOKEN} -ge 20 ]] || die "CLOUDFLARE_API_TOKEN 格式无效"

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

# Zone 根域名覆盖其下子域；证书匹配仍用精确域名（见 in_scope_host）
domain_scope() {
    local value=$1 domain
    ((DOMAIN_COUNT > 0)) || return 1
    for domain in "${DOMAINS[@]}"; do
        [[ "${value}" == "${domain}" || "${value}" == *".${domain}" ]] && return 0
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
            id=$(jq -r '.[0].id // empty' <<<"${zone}")
            if [[ -n "${id}" ]]; then
                jq -r '.[0] | [.id, .name, .account.id] | @tsv' <<<"${zone}" >>"${RUNTIME_TMP}/zones.tsv"
                break
            fi
            candidate=${candidate#*.}
        done
    done
    sort -u -o "${RUNTIME_TMP}/zones.tsv" "${RUNTIME_TMP}/zones.tsv"
    [[ -s "${RUNTIME_TMP}/zones.tsv" ]] || die "没有找到包含这些域名的 active Zone"
fi

for file in dns rules rulesets workers wdomains certs allowed-names; do
    : >"${RUNTIME_TMP}/${file}.tsv"
done
: >"${RUNTIME_TMP}/worker-keep.tsv"

zone_name_for() {
    awk -F'\t' -v id="$1" '$1 == id {print $2; exit}' "${RUNTIME_TMP}/zones.tsv"
}

# 1) DNS 记录：按 easy_all 注释识别，--domain 时按域名范围过滤
while IFS=$'\t' read -r zone_id zone_name account_id; do
    [[ -n "${zone_id}" ]] || continue
    records=$(cf_list "/zones/${zone_id}/dns_records?") || die "读取 DNS 记录失败：${zone_name}"
    while IFS=$'\t' read -r record_id name comment; do
        [[ -n "${record_id}" ]] || continue
        [[ "${comment}" == "${RECORD_COMMENT_PREFIX}"* ]] || continue
        if ((PURGE_ALL == 0)); then
            domain_scope "${name}" || continue
        fi
        printf '%s\t%s\t%s\n' "${zone_id}" "${record_id}" "${name}" >>"${RUNTIME_TMP}/dns.tsv"
        printf '%s\n' "${name}" >>"${RUNTIME_TMP}/allowed-names"
    done < <(jq -r '.[] | [.id, .name, (.comment // "")] | @tsv' <<<"${records}")

    if ((PURGE_ALL == 0)) && [[ ! -s "${RUNTIME_TMP}/allowed-names" ]]; then
    warn "没有匹配到 easy_all DNS 记录；规则与 Origin CA 需要传入完整主机名（如 cf.example.com,sub.example.com）才能识别"
fi

# 2) 规则：ref、表达式与域名范围都要匹配
    rulesets=$(cf_list "/zones/${zone_id}/rulesets?") || die "读取 ruleset 失败：${zone_name}"
    for ruleset_id in $(jq -r '.[].id' <<<"${rulesets}"); do
        detail=$(cf_api GET "/zones/${zone_id}/rulesets/${ruleset_id}") || continue
        rs_name=$(jq -r '.name // empty' <<<"${detail}")
        while IFS=$'\t' read -r rule_id rule_ref expression; do
            [[ -n "${rule_id}" ]] || continue
            [[ "${rule_ref}" == "${RULE_REF_PREFIX}"* ]] || continue
            if ((PURGE_ALL == 0)); then
                host=$(grep -oE 'http\.host eq "[^"]+"' <<<"${expression}" | head -n1 \
                    | sed -E 's/.*"(.*)"/\1/' | tr '[:upper:]' '[:lower:]')
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

# 3) Worker：名称以 easyall 开头；--domain 时也接受绑定到输入域名的 Worker。
#    --all 不按域名反查，避免把用户自己的 Worker 一起选中。
cut -f3 "${RUNTIME_TMP}/zones.tsv" | sort -u >"${RUNTIME_TMP}/accounts"
while IFS= read -r account_id; do
    [[ -n "${account_id}" ]] || continue
    scripts=$(cf_list "/accounts/${account_id}/workers/scripts?") || {
        warn "无法读取账户 ${account_id} 的 Worker 列表（Token 可能缺少 Workers 权限），跳过 Worker"
        continue
    }
    domains=$(cf_list "/accounts/${account_id}/workers/domains?") || {
        warn "无法读取账户 ${account_id} 的 Worker 自定义域名，跳过 Worker"
        continue
    }
    while IFS= read -r worker_name; do
        [[ -n "${worker_name}" ]] || continue
        selected=0
        [[ "${worker_name}" == "${WORKER_NAME_PREFIX}"* ]] && selected=1
        if ((selected == 0)) && ((PURGE_ALL == 0)); then
            while IFS= read -r hostname; do
                [[ -n "${hostname}" ]] || continue
                lower=$(tr '[:upper:]' '[:lower:]' <<<"${hostname}")
                if domain_scope "${lower}"; then
                    selected=1
                    break
                fi
            done < <(jq -r --arg name "${worker_name}" \
                '.[] | select(.service == $name) | .hostname' <<<"${domains}")
        fi
        ((selected == 1)) || continue
        printf '%s\t%s\n' "${account_id}" "${worker_name}" >>"${RUNTIME_TMP}/workers.tsv"
        while IFS=$'\t' read -r domain_id hostname; do
            [[ -n "${domain_id}" ]] || continue
            lower=$(tr '[:upper:]' '[:lower:]' <<<"${hostname}")
            if ((PURGE_ALL == 1)) || domain_scope "${lower}"; then
                printf '%s\t%s\t%s\n' "${account_id}" "${domain_id}" "${hostname}" \
                    >>"${RUNTIME_TMP}/wdomains.tsv"
            else
                printf '%s\t%s\t%s\n' "${account_id}" "${worker_name}" "${hostname}" \
                    >>"${RUNTIME_TMP}/worker-keep.tsv"
            fi
        done < <(jq -r --arg name "${worker_name}" \
            '.[] | select(.service == $name) | [.id, .hostname] | @tsv' <<<"${domains}")
    done < <(jq -r '.[].id' <<<"${scripts}")
done <"${RUNTIME_TMP}/accounts"

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
        "Worker") printf '  %-11s %s\n' "${label}" "${b}" ;;
        "Worker 域名") printf '  %-11s %s\n' "${label}" "${c}" ;;
        "Origin CA") printf '  %-11s %s\n' "${label}" "${b}" ;;
        esac
    done <"${RUNTIME_TMP}/${file}.tsv"
}
print_plan "Worker 域名" wdomains
print_plan "Worker" workers
print_plan "规则" rules
print_plan "Ruleset" rulesets
print_plan "Origin CA" certs
print_plan "DNS 记录" dns

if ((total == 0)); then
    info "没有匹配到 easy_all 创建的 Cloudflare 资源"
    exit 0
fi

info "以上 ${total} 个 Cloudflare 对象将被删除（不删除 Zone，也不删除 Bunny 模式的无注释 DNS 记录）"
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

while IFS=$'\t' read -r account_id domain_id hostname; do
    [[ -n "${domain_id}" ]] || continue
    purge "Worker 域名" "${hostname}" "/accounts/${account_id}/workers/domains/${domain_id}"
done <"${RUNTIME_TMP}/wdomains.tsv"
while IFS=$'\t' read -r account_id worker_name; do
    [[ -n "${worker_name}" ]] || continue
    if grep -q "^${account_id}"$'\t'"${worker_name}"$'\t' "${RUNTIME_TMP}/worker-keep.tsv"; then
        warn "Worker ${worker_name} 仍绑定非本次范围的域名，保留"
        failures=$((failures + 1))
        continue
    fi
    purge "Worker" "${worker_name}" "/accounts/${account_id}/workers/scripts/${worker_name}"
done <"${RUNTIME_TMP}/workers.tsv"
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
