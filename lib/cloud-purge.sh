#!/usr/bin/env bash
# One-shot cleanup of easy_all-created Cloudflare and CloudFront/ACM resources. Works without local state.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly CF_API_BASE="https://api.cloudflare.com/client/v4"
readonly RECORD_COMMENT_PREFIX="easy_all"
# 接管把第三方记录的注释改写成本工具前缀，所以删除前必须查这本日志，与 lib/runtime-core.sh
# 读写同一个文件；override 只给测试把路径映射到临时目录，生产不得设置。
readonly DNS_TAKEOVER_LOG="${EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE:-/var/log/easy_all/dns-takeover.log}"
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
用法: easy_all purge-cloud [--domain <域名>[,<域名>...]] [--all] [--yes]

  --domain <域名>  清理这些域名下的 easy_all 资源（Cloudflare 与 CloudFront/ACM）
                   传 Zone 根域名（如 example.com）会覆盖其下全部相关记录；
                   传完整主机名（如 cf.example.com）只清理该域名及其直接关联对象
  --all            清理 Token 可见的所有 Zone 中的 easy_all 资源
  --yes            跳过确认（非交互模式必须显式给出）

环境变量：EASY_ALL_PURGE_MAX_PAGES            每个列表接口的分页上限（默认 100 页 × 100 条）
          EASY_ALL_PURGE_AWS_WAIT_ATTEMPTS  单个分发禁用/证书收敛的轮询次数（默认 60）
          EASY_ALL_PURGE_AWS_WAIT_SECONDS   轮询间隔秒数（默认 10）

识别规则：DNS 记录注释以 easy_all 开头（命中本机接管日志 /var/log/easy_all/dns-takeover.log 的记录
视为强制接管而来的第三方记录，一律保留，原配置按日志手工处理）；
规则按 ref 以 easy_all- 开头（历史资源兼容 easy_all_ 前缀）且表达式完整等于 http.host eq "待清理域名"（括号、or/and/not、集合等复杂表达式一律保留）；
ruleset 名称以 easy_all 开头且清空后才删除；
Origin CA 证书只在其全部 hostname 都属于 easy_all 记录或输入域名时删除。
Zone 内 easy_all DNS 记录已删除时，规则与证书需要传完整主机名才能识别。
不删除 Zone 本身。

CloudFront/ACM：仅在同时提供 AWS 凭据（AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY，
可选 AWS_SESSION_TOKEN）且已安装 aws CLI 时执行，否则跳过并提示。只删除
Comment 以 easy_all-cloudfront- 开头且别名全部落在本次域名范围内的分发（先禁用、等 Deployed、再删），
以及打有 easy_all=managed 标记且域名全部在范围内的 us-east-1 ACM 证书。
计划阶段仍被分发引用的证书会在确认提示里单独计数：分发删除后逐个复核，已无 InUseBy 的会被删除，
仍被其他分发占用的保留；InUseBy 仍指向本次已删除分发时按有界重试等待收敛
（EASY_ALL_PURGE_AWS_WAIT_ATTEMPTS 默认 60 次 × EASY_ALL_PURGE_AWS_WAIT_SECONDS 默认 10 秒），
等待期后仍被引用或读取失败会告警并计入失败。任一 ACM 证书在计划阶段无法读取或解析时，
无法确认归属，将整体取消清理（不删除任何对象）。
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

# 接管把第三方记录的注释改写成本工具前缀：命中本机接管日志的记录必须保留，
# 原配置见日志。本脚本不加载 runtime-core，所以只重复这两行最小判定。
dns_record_taken_over() {
    local rc=0
    [[ -f "${DNS_TAKEOVER_LOG}" ]] || return 1
    grep -Fq -- "\"host\":\"${1}\"" "${DNS_TAKEOVER_LOG}" || rc=$?
    if ((rc == 0)); then return 0; fi
    # rc=1 才是「未命中」；rc≥2 是日志不可读/IO 错误，无法证明未接管，按接管保守处理。
    if ((rc == 1)); then return 1; fi
    warn "无法读取接管审计日志：${DNS_TAKEOVER_LOG}；按接管处理，保留对应记录"
    return 0
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
    # 429 有界固定退避（共 2 次、合计 15s）：不解析响应体/响应头——cf_api 没有 -D 拿不到
    # Retry-After，Cloudflare 的 429 响应体也不带 retry_after。仍 429 则放弃。
    if [[ "${code}" == "429" ]]; then
        local backoff
        for backoff in 5 10; do
            # 退避秒数可被测试注入（仓库既有 *_OVERRIDE 惯例）：默认值不变，仍是 5s/10s。
            sleep "${EASY_ALL_CF_RETRY_SLEEP_OVERRIDE:-${backoff}}"
            if [[ -n "${body}" ]]; then
                response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
                    -H "@${headers}" --data-binary "@${RUNTIME_TMP}/cf-body" -w $'\n%{http_code}' \
                    "${CF_API_BASE}${path}") || return 1
            else
                response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" \
                    -H "@${headers}" -w $'\n%{http_code}' "${CF_API_BASE}${path}") || return 1
            fi
            code=${response##*$'\n'}
            response=${response%$'\n'*}
            [[ "${code}" == "429" ]] || break
        done
    fi
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

# 每个列表接口的分页上限（usage 承诺）：非法值在任何扫描之前就拒绝。
purge_max_pages() {
    local max_pages=${EASY_ALL_PURGE_MAX_PAGES:-100}
    [[ "${max_pages}" =~ ^[1-9][0-9]*$ ]] \
        || die "EASY_ALL_PURGE_MAX_PAGES 必须是正整数：${max_pages}"
    printf '%s' "${max_pages}"
}

cf_list() {
    local path=$1 separator='?' page=1 batch all='[]' count prev_batch=""
    local max_pages
    max_pages=$(purge_max_pages)
    [[ "${path}" != *\?* ]] || separator='&'
    while :; do
        batch=$(cf_api GET "${path}${separator}per_page=100&page=${page}") || return 1
        # jq 必须显式 -n：不传输入时它会读 stdin，在交互终端上会永久阻塞（现场：purge-cloud 挂起）。
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
        # 先把名字记为“本工具在用的主机”：接管记录不再进 DNS 删除计划，
        # 但其上本工具创建的规则与 Origin CA 仍须能按名字识别出来。
        printf '%s\n' "${name}" >>"${RUNTIME_TMP}/allowed-names"
        if dns_record_taken_over "${name}"; then
            warn "Cloudflare ${name} 的 DNS 记录来自强制接管（原注释/指向见 ${DNS_TAKEOVER_LOG}）；保留，如需删除请手工处理"
            continue
        fi
        printf '%s\t%s\t%s\n' "${zone_id}" "${record_id}" "${name}" >>"${RUNTIME_TMP}/dns.tsv"
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

# --- CloudFront / ACM（AWS） ---------------------------------------------------
# 本脚本不加载 Profile：AWS 侧同样只按归属标记识别；凭据或 aws CLI 缺失时整段跳过。
aws_cli_ready() {
    command -v aws >/dev/null 2>&1 \
        && [[ -n "${AWS_ACCESS_KEY_ID:-}" && -n "${AWS_SECRET_ACCESS_KEY:-}" ]]
}
aws_cli() { aws --no-cli-pager --cli-read-timeout 120 --cli-connect-timeout 60 "$@"; }

# 输入恰好等于已解析的 Zone 名时才覆盖点分隔子域，与 Cloudflare 侧 domain_scope 同口径。
aws_domain_is_zone_root() {
    awk -F'\t' -v name="$1" \
        'tolower($2) == tolower(name) { found = 1; exit } END { exit !found }' \
        "${RUNTIME_TMP}/zones.tsv"
}

# --domain 的语义与 Cloudflare 侧一致：等于输入，或输入是 Zone 根域名时的点分隔子域。
# AWS 返回的名字先小写归一，与 Cloudflare 侧（解析时已小写）同口径。
aws_name_in_scope() {
    local name domain
    ((PURGE_ALL == 1)) && return 0
    ((DOMAIN_COUNT > 0)) || return 1
    name=$(tr '[:upper:]' '[:lower:]' <<<"$1")
    for domain in "${DOMAINS[@]}"; do
        [[ "${name}" == "${domain}" ]] && return 0
        [[ "${name}" == *".${domain}" ]] && aws_domain_is_zone_root "${domain}" && return 0
    done
    return 1
}

aws_collect_distributions() {
    local marker="" next page input pages=0 max_pages acc_file
    max_pages=$(purge_max_pages)
    acc_file="${RUNTIME_TMP}/cloudfront-pages.jsonl"
    : >"${acc_file}"
    while :; do
        pages=$((pages + 1))
        # --no-paginate 关掉 AWS CLI 的自动分页，否则 CLI 在内部取完全部页并丢掉
        # IsTruncated/NextMarker，外层永远只看到一页，页数上限形同虚设。
        # 页大小与 token 都走服务端入参（CloudFront 的 MaxItems 是字符串）。
        if [[ -n "${marker}" ]]; then
            input=$(jq -cn --arg marker "${marker}" '{MaxItems:"100", Marker:$marker}') || return 1
        else
            input=$(jq -cn '{MaxItems:"100"}') || return 1
        fi
        page=$(aws_cli cloudfront list-distributions --no-paginate \
            --cli-input-json "${input}" --output json) || return 1
        # 逐页只投影清理要用的字段：整页对象的 Origins.CustomHeaders.HeaderValue 是源站密钥。
        jq -c '[(.DistributionList.Items // [])[]
            | {Id, Comment: (.Comment // ""), Aliases: (.Aliases.Items // [])}]' \
            <<<"${page}" >>"${acc_file}" || return 1
        truncated=$(jq -r '.DistributionList.IsTruncated // false' <<<"${page}") || return 1
        [[ "${truncated}" == "true" ]] || break
        next=$(jq -r '.DistributionList.NextMarker // empty' <<<"${page}")
        [[ -n "${next}" && "${next}" != "${marker}" ]] \
            || die "CloudFront 分页标记异常；已取消清理"
        ((pages <= max_pages)) \
            || die "扫描超过 ${max_pages} 页仍未结束（cloudfront list-distributions）；如账户确实有更多数据，可用 EASY_ALL_PURGE_MAX_PAGES 调大上限"
        marker=${next}
    done
    # 每行是一页的投影数组；-s 把逐行文档 slurp 成数组，add 把它们连接成扁平对象数组。
    jq -s -c 'add // []' "${acc_file}"
}

# 分发归属：Comment 必须带 easy_all-cloudfront- 前缀，且全部别名都落在本次范围内。
aws_plan_distributions() {
    local items id comment aliases alias ok
    local -a alias_list
    items=$(aws_collect_distributions) \
        || { warn "列举 CloudFront 分发失败；已取消清理"; return 1; }
    while IFS=$'\t' read -r id comment aliases; do
        [[ -n "${id}" ]] || continue
        ok=1
        [[ -n "${aliases}" ]] || ok=0
        IFS=',' read -r -a alias_list <<<"${aliases}"
        for alias in "${alias_list[@]}"; do
            [[ -n "${alias}" ]] || continue
            aws_name_in_scope "${alias}" || ok=0
        done
        ((ok == 1)) || continue
        printf '%s\t%s\t%s\n' "${id}" "${comment}" "${aliases}" >>"${RUNTIME_TMP}/cloudfront.tsv"
    done < <(jq -r '
        .[]
        | select((.Comment // "") | startswith("easy_all-cloudfront-"))
        | [.Id, (.Comment // ""), (.Aliases | join(","))]
        | @tsv
    ' <<<"${items}")
}

aws_collect_certificates() {
    local next="" page input pages=0 seen="|" max_pages acc_file
    max_pages=$(purge_max_pages)
    acc_file="${RUNTIME_TMP}/acm-pages.jsonl"
    : >"${acc_file}"
    while :; do
        pages=$((pages + 1))
        # 同 CloudFront：关闭 CLI 自动分页，页大小与 token 走服务端入参（ACM 的 MaxItems 是整数）。
        if [[ -n "${next}" ]]; then
            input=$(jq -cn --arg token "${next}" '{MaxItems:100, NextToken:$token}') || return 1
        else
            input=$(jq -cn '{MaxItems:100}') || return 1
        fi
        page=$(aws_cli acm list-certificates --region us-east-1 --no-paginate \
            --cli-input-json "${input}" --output json) || return 1
        jq -c '[(.CertificateSummaryList // [])[] | {CertificateArn}]' \
            <<<"${page}" >>"${acc_file}" || return 1
        next=$(jq -r '.NextToken // empty' <<<"${page}") || return 1
        [[ -n "${next}" ]] || break
        # 响应异常时反复返回同一 token 会让计划阶段在 root 会话里无限循环。
        [[ "${seen}" != *"|${next}|"* ]] \
            || die "ACM 列举接口重复返回同一分页标记（${next}）；已取消清理以免无限循环"
        seen+="${next}|"
        ((pages <= max_pages)) \
            || die "扫描超过 ${max_pages} 页仍未结束（acm list-certificates）；如账户确实有更多数据，可用 EASY_ALL_PURGE_MAX_PAGES 调大上限"
    done
    jq -s -c 'add // []' "${acc_file}"
}

# ACM 归属：us-east-1、easy_all=managed 标记，且域名全部落在本次范围内。归属确认后，
# InUseBy 为空者直接进删除计划，非空者记入复核清单（分发删除后再判定能不能回收）。
# 读取/解析失败无法证明资格：点名 ARN 并 return 1（aws_plan_failed → 整体取消），
# 与「完整枚举失败则删除前取消」同口径；成功读取但不符合归属的证书静默保留。
aws_plan_certificates() {
    local items arn detail tags names name ok
    local -a name_list
    items=$(aws_collect_certificates) \
        || { warn "列举 ACM 证书失败；已取消清理"; return 1; }
    while IFS= read -r arn; do
        [[ -n "${arn}" ]] || continue
        if ! detail=$(aws_cli acm describe-certificate --region us-east-1 \
            --certificate-arn "${arn}" --output json 2>/dev/null) \
            || ! jq -e '.Certificate' <<<"${detail}" >/dev/null 2>&1; then
            warn "无法读取/解析 ACM 证书（describe-certificate：${arn}），无法确认归属；已取消清理"
            return 1
        fi
        if ! tags=$(aws_cli acm list-tags-for-certificate --region us-east-1 \
            --certificate-arn "${arn}" --output json 2>/dev/null) \
            || ! jq -e '.Tags' <<<"${tags}" >/dev/null 2>&1; then
            warn "无法读取/解析 ACM 证书（list-tags-for-certificate：${arn}），无法确认归属；已取消清理"
            return 1
        fi
        jq -e '(.Tags // []) | any(.Key == "easy_all" and .Value == "managed")' \
            <<<"${tags}" >/dev/null 2>&1 || continue
        if ! names=$(jq -r '[.Certificate.DomainName] + (.Certificate.SubjectAlternativeNames // [])
            | map(select(. != null)) | unique | .[]' <<<"${detail}"); then
            warn "无法解析 ACM 证书（域名列表：${arn}），无法确认归属；已取消清理"
            return 1
        fi
        ok=1
        IFS=$'\n' read -r -d '' -a name_list <<<"${names}" || true
        ((${#name_list[@]} > 0)) || ok=0
        for name in "${name_list[@]}"; do
            aws_name_in_scope "${name}" || ok=0
        done
        ((ok == 1)) || continue
        # 归属（管理标记）与域名范围确认之后才记录占用：账号里其他业务证书无论是否在用都不进
        # 复核清单，确认提示的数量与随后的复核调用只覆盖真正可能被删的证书。
        if ! jq -e '(.Certificate.InUseBy // []) | length == 0' <<<"${detail}" >/dev/null 2>&1; then
            # 此刻被分发占用、不可删；但分发删除后可能变成可删。先记下 ARN，删除分发后再判定，
            # 否则这类证书会永久滞留为孤儿资产。
            printf '%s\n' "${arn}" >>"${RUNTIME_TMP}/acm-inuse.txt"
            continue
        fi
        printf '%s\t%s\n' "${arn}" "$(tr '\n' ',' <<<"${names}" | sed 's/,$//')" \
            >>"${RUNTIME_TMP}/acm.tsv"
    done < <(jq -r '.[] | .CertificateArn // empty' <<<"${items}")
}

# 证书删除前复核：managed 标签、InUseBy 为空、全部域名在范围内。任一读取失败或不符返回 1。
# 读取失败（节流/IAM）与「不归属」在调用方有不同后果：置 ACM_OWNERSHIP_UNREADABLE=1 供区分。
# ACM 的 InUseBy 在 delete-distribution 返回后才收敛，单次读取会把「还没收敛」当成「仍被占用」。
# 输出 0 = 只剩本次已删除的分发在引用（尚未收敛，值得重试）；1 = 已无占用或仍被其他资源占用；
# 2 = 读不到状态。与 lib/cloudfront-mode.sh 的收敛重试同一口径，但只对本次删掉的分发重试。
aws_acm_in_use_only_deleted() {
    local arn=$1 detail ids id
    detail=$(aws_cli acm describe-certificate --region us-east-1 \
        --certificate-arn "${arn}" --output json) || return 2
    ids=$(jq -r '(.Certificate.InUseBy // [])[]' <<<"${detail}") || return 2
    [[ -n "${ids}" ]] || return 1
    while IFS= read -r id; do
        id=${id##*/}
        # 整行精确匹配（分发 ID 不含换行/通配符）；一次性比对集合，避免 cut|grep 在 pipefail 下被 SIGPIPE 误判。
        [[ $'\n'"${DELETED_DISTRIBUTION_IDS}"$'\n' == *$'\n'"${id}"$'\n'* ]] || return 1
    done <<<"${ids}"
    return 0
}

aws_certificate_still_owned() {
    local arn=$1 detail tags names name ok=1
    local -a name_list
    ACM_OWNERSHIP_UNREADABLE=0
    detail=$(aws_cli acm describe-certificate --region us-east-1 \
        --certificate-arn "${arn}" --output json) \
        || { ACM_OWNERSHIP_UNREADABLE=1; return 1; }
    tags=$(aws_cli acm list-tags-for-certificate --region us-east-1 \
        --certificate-arn "${arn}" --output json) \
        || { ACM_OWNERSHIP_UNREADABLE=1; return 1; }
    jq -e '(.Certificate.InUseBy // []) | length == 0' <<<"${detail}" >/dev/null 2>&1 \
        || return 1
    jq -e '(.Tags // []) | any(.Key == "easy_all" and .Value == "managed")' \
        <<<"${tags}" >/dev/null 2>&1 || return 1
    names=$(jq -r '[.Certificate.DomainName] + (.Certificate.SubjectAlternativeNames // [])
        | map(select(. != null)) | unique | .[]' <<<"${detail}") || return 1
    IFS=$'\n' read -r -d '' -a name_list <<<"${names}" || true
    ((${#name_list[@]} > 0)) || return 1
    for name in "${name_list[@]}"; do
        aws_name_in_scope "${name}" || ok=0
    done
    ((ok == 1))
}

# 破坏性请求前复核：Comment 前缀 + 非空别名且全部在范围内。任一读取失败或不符返回 1。
aws_distribution_still_owned() {
    local fetched=$1 comment aliases alias ok=1
    local -a alias_list
    comment=$(jq -r '.DistributionConfig.Comment // empty' <<<"${fetched}") || return 1
    [[ "${comment}" == "easy_all-cloudfront-"* ]] || return 1
    aliases=$(jq -r '(.DistributionConfig.Aliases.Items // []) | join(",")' <<<"${fetched}") || return 1
    # 与计划阶段同口径：空别名集合证明不了分发仍属于本次清理范围，不能只靠循环零次执行就放行。
    [[ -n "${aliases}" ]] || return 1
    IFS=',' read -r -a alias_list <<<"${aliases}"
    for alias in "${alias_list[@]}"; do
        [[ -n "${alias}" ]] || continue
        aws_name_in_scope "${alias}" || ok=0
    done
    ((ok == 1)) || return 1
}

aws_disable_and_delete_distribution() {
    local id=$1 fetched etag config status attempt description enabled
    local attempts=${EASY_ALL_PURGE_AWS_WAIT_ATTEMPTS:-60}
    local seconds=${EASY_ALL_PURGE_AWS_WAIT_SECONDS:-10}
    # 配置读取用 get-distribution-config（真实响应的配置在根对象 .DistributionConfig）；
    # Status 只存在于 get-distribution 的 .Distribution 下，轮询继续用它。
    fetched=$(aws_cli cloudfront get-distribution-config --id "${id}" --output json) || return 1
    aws_distribution_still_owned "${fetched}" \
        || { warn "CloudFront 分发 ${id} 的归属/范围已变化，保留不删"; return 1; }
    etag=$(jq -r '.ETag // empty' <<<"${fetched}")
    [[ -n "${etag}" ]] || return 1
    config="${RUNTIME_TMP}/cloudfront-disable-${id}.json"
    # 配置里含源站头密钥（X-Easy-All-Origin-Key）：落 0600 临时文件走 file://，不进 argv/ps。
    jq -c '.DistributionConfig | .Enabled=false' <<<"${fetched}" >"${config}" || return 1
    aws_cli cloudfront update-distribution --id "${id}" --if-match "${etag}" \
        --distribution-config "file://${config}" --output json >/dev/null || return 1
    status=""
    enabled=""
    # 传播期 get-distribution 仍可能报告上一次的 Deployed：只按 Status 判定会拿着未生效的
    # 禁用去 delete-distribution 而被服务端拒绝（DistributionNotDisabled）。必须同时看到
    # Enabled=false 才算完成，与 lib/cloudfront-mode.sh 的等待口径一致。
    for ((attempt = 1; attempt <= attempts; attempt++)); do
        description=$(aws_cli cloudfront get-distribution --id "${id}" --output json 2>/dev/null || true)
        status=$(jq -r '.Distribution.Status // empty' <<<"${description}" 2>/dev/null || true)
        enabled=$(jq -r '.Distribution.DistributionConfig.Enabled | tostring' \
            <<<"${description}" 2>/dev/null || true)
        [[ "${status}" == "Deployed" && "${enabled}" == "false" ]] && break
        sleep "${seconds}"
    done
    [[ "${status}" == "Deployed" && "${enabled}" == "false" ]] || return 1
    # 禁用生效后重新读取，取最新 ETag 再删；删除前同样复核归属/范围。
    fetched=$(aws_cli cloudfront get-distribution-config --id "${id}" --output json) || return 1
    aws_distribution_still_owned "${fetched}" \
        || { warn "CloudFront 分发 ${id} 的归属/范围已变化，保留不删"; return 1; }
    etag=$(jq -r '.ETag // empty' <<<"${fetched}")
    [[ -n "${etag}" ]] || return 1
    aws_cli cloudfront delete-distribution --id "${id}" --if-match "${etag}" >/dev/null
}

total=0
aws_total=0
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

# AWS 侧计划同样在确认前收集：一次确认覆盖两种云。凭据/CLI 缺失时只提示跳过。
aws_requested=0
aws_plan_failed=0
: >"${RUNTIME_TMP}/cloudfront.tsv"
: >"${RUNTIME_TMP}/acm.tsv"
: >"${RUNTIME_TMP}/acm-inuse.txt"
if aws_cli_ready; then
    aws_requested=1
    if ! { aws_plan_distributions && aws_plan_certificates; }; then
        aws_plan_failed=1
    else
        while IFS=$'\t' read -r aws_id _aws_comment aws_aliases; do
            [[ -n "${aws_id}" ]] || continue
            aws_total=$((aws_total + 1))
            printf '  %-11s %s %s\n' "CloudFront" "${aws_id}" "${aws_aliases}"
        done <"${RUNTIME_TMP}/cloudfront.tsv"
        while IFS=$'\t' read -r aws_arn aws_names; do
            [[ -n "${aws_arn}" ]] || continue
            aws_total=$((aws_total + 1))
            printf '  %-11s %s %s\n' "ACM" "${aws_arn}" "${aws_names}"
        done <"${RUNTIME_TMP}/acm.tsv"
        # 确认范围必须覆盖实际破坏范围：这些证书在分发删除后才可能可删，数量要提前告知。
        if [[ -s "${RUNTIME_TMP}/acm-inuse.txt" ]]; then
            info "另有 $(awk 'END {print NR}' "${RUNTIME_TMP}/acm-inuse.txt") 张被分发占用的 ACM 证书将在分发删除后复核：不再被占用的会被一并删除，仍被占用的保留"
        fi
    fi
else
    info "未提供 AWS 凭据或缺 aws CLI：跳过 CloudFront/ACM 清理（Cloudflare 侧照常执行）"
fi

# 枚举失败时不能假装“没有资源”：在删除任何对象之前整体停止，避免只清一半。
if ((aws_plan_failed == 1)); then
    die "列举 CloudFront/ACM 资源失败；已取消清理（未删除任何对象），请修复 AWS 权限后重试"
fi

if ((total == 0 && aws_total == 0)); then
    info "没有匹配到 easy_all 创建的 Cloudflare、CloudFront 或 ACM 资源"
    exit 0
fi

if ((aws_total > 0)); then
    info "以上 ${total} 个 Cloudflare 对象与 ${aws_total} 个 CloudFront/ACM 对象将被删除（不删除 Zone）"
else
    info "以上 ${total} 个 Cloudflare 对象将被删除（不删除 Zone）"
fi
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

if ((total > 0)); then
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
((failures == 0)) || warn "Cloudflare 侧有 ${failures} 个对象删除失败"
success "Cloudflare 清理完成：$((total - failures)) 个对象"
fi

if ((aws_total > 0)); then
    aws_failures=0
    aws_kept=0
    deleted_distribution_ids=()
    while IFS=$'\t' read -r aws_id _aws_comment aws_aliases; do
        [[ -n "${aws_id}" ]] || continue
        if aws_disable_and_delete_distribution "${aws_id}"; then
            success "已删除 CloudFront 分发：${aws_id}（${aws_aliases}）"
            deleted_distribution_ids+=("${aws_id}")
        else
            warn "删除 CloudFront 分发失败：${aws_id}"
            aws_failures=$((aws_failures + 1))
        fi
    done <"${RUNTIME_TMP}/cloudfront.tsv"
    # 计划阶段因 InUseBy 非空被排除的证书，分发删除后才可能可删：逐个复核归属/范围后追加到
    # 待删列表（仍被其他分发占用的照旧保留），否则这些证书会永久滞留为孤儿资产。
    cp -- "${RUNTIME_TMP}/acm.tsv" "${RUNTIME_TMP}/acm-planned.tsv" \
        || die "保存 ACM 清理计划失败"
    attempts=${EASY_ALL_PURGE_AWS_WAIT_ATTEMPTS:-60}
    ((attempts > 0)) || attempts=1
    seconds=${EASY_ALL_PURGE_AWS_WAIT_SECONDS:-10}
    settled=0
    unreadable=0
    rc=0
    # 只把实际删除成功的分发算作收敛等待对象：删除失败的分发仍然存活，它的 InUseBy 不会收敛，
    # 按计划表全量匹配会让关联证书白等满额重试（默认 60×10 秒）后才报失败。
    DELETED_DISTRIBUTION_IDS=$(printf '%s\n' "${deleted_distribution_ids[@]+"${deleted_distribution_ids[@]}"}")
    while IFS= read -r aws_arn; do
        [[ -n "${aws_arn}" ]] || continue
        settled=0
        unreadable=0
        for ((attempt = 1; attempt <= attempts; attempt++)); do
            rc=0
            aws_acm_in_use_only_deleted "${aws_arn}" || rc=$?
            case "${rc}" in
            0)
                # InUseBy 仍指向本次删掉的分发：等传播收敛后重试，不把「还没收敛」当结果。
                sleep "${seconds}"
                ;;
            2)
                unreadable=1
                break
                ;;
            *)
                settled=1
                break
                ;;
            esac
        done
        if ((settled == 1)); then
            if aws_certificate_still_owned "${aws_arn}"; then
                printf '  %-11s %s\n' "ACM+1" "${aws_arn}"
                printf '%s\t\n' "${aws_arn}" >>"${RUNTIME_TMP}/acm-planned.tsv"
                aws_total=$((aws_total + 1))
            elif ((ACM_OWNERSHIP_UNREADABLE == 1)); then
                warn "无法读取 ACM 证书状态，保留不删：${aws_arn}"
                aws_kept=$((aws_kept + 1))
            fi
            continue
        fi
        if ((unreadable == 1)); then
            warn "无法读取 ACM 证书状态，保留不删：${aws_arn}"
        else
            warn "ACM 证书在等待期内仍被已删除的分发引用，保留不删：${aws_arn}"
        fi
        aws_kept=$((aws_kept + 1))
    done <"${RUNTIME_TMP}/acm-inuse.txt"
    while IFS=$'\t' read -r aws_arn aws_names; do
        [[ -n "${aws_arn}" ]] || continue
        if aws_certificate_still_owned "${aws_arn}"; then
            if (aws_cli acm delete-certificate --region us-east-1 \
                --certificate-arn "${aws_arn}" >/dev/null); then
                success "已删除 ACM 证书：${aws_arn}${aws_names:+（${aws_names}）}"
            else
                warn "删除 ACM 证书失败：${aws_arn}"
                aws_failures=$((aws_failures + 1))
            fi
        else
            warn "ACM 证书 ${aws_arn} 的归属/状态已变化，保留不删"
            aws_kept=$((aws_kept + 1))
        fi
    done <"${RUNTIME_TMP}/acm-planned.tsv"
    # 汇总始终同时输出两个计数：失败数为 0 时也不能把「合法保留」隐藏起来。
    if ((aws_failures == 0)); then
        success "CloudFront/ACM 清理完成：${aws_total} 个对象，${aws_kept} 个合法保留"
    else
        warn "CloudFront/ACM 侧有 ${aws_failures} 个对象删除失败，${aws_kept} 个合法保留"
    fi
    failures=$((failures + aws_failures))
fi

((failures == 0)) || die "有 ${failures} 个对象删除失败；可修复后重试同一命令"
