#!/usr/bin/env bash

# Cloudflare Request Header Transform Rule 单规则生命周期（design §2.3）。
# 形态对齐 lib/cf-origin-rule.sh：只用单规则端点（POST /rulesets/{id}/rules、
# PATCH/DELETE .../rules/{rule_id}），禁止 GET 后合并旧快照整体 PUT 回写。
# 依赖调用方提供 log.sh 的 die/warn/info/success 与 cf-dns.sh 的 cloudflare_api_request。
#
# 安全约束：ORIGIN_HEADER_SECRET 只允许出现在发往 Cloudflare 的请求体里，
# 任何本文件的日志/warn/die 都不得打印密钥或完整规则 JSON（避免终端与 journal 泄漏）。

CF_TRANSFORM_RULESET_NAME="easy_all-transform-rules"
CF_TRANSFORM_RULESET_PHASE="http_request_late_transform"
CF_TRANSFORM_RULE_REF_PREFIX="easy_all-"
CF_TRANSFORM_ORIGIN_HEADER="X-Easy-All-Origin-Key"
CF_TRANSFORM_ORIGIN_SECRET_PATTERN='^[A-Za-z0-9._~-]{16,128}$'

# ref 只由规范化域名决定：同一域名重跑得到同一 ref，便于识别、复用与 cloud-purge 发现
# （cloud-purge 按 `easy_all-` 前缀 + 精确 http.host 表达式识别本工具的规则）。
cloudflare_transform_normalize_domain() {
    local domain
    domain=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    domain=${domain%.}
    [[ ${#domain} -ge 4 && ${#domain} -le 253 ]] \
        || die "Transform Rule 域名长度无效：$1"
    [[ "${domain}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "Transform Rule 域名含非法字符：$1"
    [[ "${domain}" == *.* ]] || die "Transform Rule 域名缺少点号：$1"
    printf '%s\n' "${domain}"
}

cloudflare_transform_rule_ref() {
    local domain digest
    domain=$(cloudflare_transform_normalize_domain "$1") || return 1
    digest=$(printf '%s' "${domain}" | openssl dgst -sha256 2>/dev/null \
        | awk '{print $NF}' | tr '[:upper:]' '[:lower:]') || digest=""
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] \
        || die "无法计算 Transform Rule ref 摘要：${domain}"
    printf '%s%s\n' "${CF_TRANSFORM_RULE_REF_PREFIX}" "${digest:0:16}"
}

cloudflare_transform_rule_json() {
    local domain=$1 secret=$2 ref
    [[ "${secret:-}" =~ ${CF_TRANSFORM_ORIGIN_SECRET_PATTERN} ]] \
        || die "Transform Rule 源站头密钥格式无效；拒绝写入"
    ref=$(cloudflare_transform_rule_ref "${domain}") || return 1
    jq -cn --arg ref "${ref}" --arg domain "${domain}" --arg secret "${secret}" \
        --arg header "${CF_TRANSFORM_ORIGIN_HEADER}" '
        {
          ref: $ref,
          expression: ("http.host eq " + ($domain | @json)),
          action: "rewrite",
          action_parameters: {
            headers: {($header): {operation: "set", value: $secret}}
          }
        }'
}

# 唯一命中 kind=zone + phase=http_request_late_transform 的 ruleset。
# 调用方在命令替换里无法被 die 终止，因此用返回码区分全部情形：
#   0 → stdout 给出唯一 ruleset ID；1 → 没有该 phase 的 ruleset；
#   2 → 存在多个，禁止写入；3 → 读取或解析失败（不得当成“不存在”而创建）。
cloudflare_transform_ruleset_id() {
    local zone_id=$1 rulesets matched count
    [[ -n "${zone_id}" ]] || die "Transform Rule 操作需要 Zone ID"
    if ! rulesets=$(cloudflare_api_request GET "/zones/${zone_id}/rulesets"); then
        printf '读取 Cloudflare ruleset 列表失败：%s\n' "${zone_id}" >&2
        return 3
    fi
    if ! matched=$(jq -r --arg phase "${CF_TRANSFORM_RULESET_PHASE}" \
        '.[]? | select(.kind == "zone" and .phase == $phase) | .id' <<<"${rulesets}"); then
        printf '解析 Cloudflare ruleset 列表失败：%s\n' "${zone_id}" >&2
        return 3
    fi
    count=$(printf '%s\n' "${matched}" | grep -c . || true)
    case "${count}" in
    0) return 1 ;;
    1) printf '%s\n' "${matched}" ;;
    *) return 2 ;;
    esac
}

# 同 ref 规则只有归属可证明时才允许 PATCH：ref 由域名确定性派生，因此必须同时满足
# 精确域名表达式、rewrite 动作与带本工具头名的 headers 参数。
cloudflare_transform_rule_owned() {
    local detail=$1 rule_id=$2 domain=$3 header=${CF_TRANSFORM_ORIGIN_HEADER}
    jq -e --arg id "${rule_id}" --arg domain "${domain}" --arg header "${header}" '
        [.rules[]? | select(.id == $id)][0]
        | . != null
          and .action == "rewrite"
          and .expression == ("http.host eq " + ($domain | @json))
          and ((.action_parameters.headers // {}) | has($header))
    ' <<<"${detail}" >/dev/null 2>&1
}

cloudflare_transform_rule_id_by_ref() {
    local detail=$1 ref=$2
    jq -r --arg ref "${ref}" '(.rules // [])[] | select(.ref == $ref) | .id' <<<"${detail}"
}

# 成功后向 stdout 输出两行：ruleset ID、rule ID（供 state 持久化）。
cloudflare_ensure_transform_rule() {
    local zone_id=$1 domain=$2 secret=$3
    local ref rule ruleset_id ruleset_status detail rule_id existing
    domain=$(cloudflare_transform_normalize_domain "${domain}") || exit 1
    [[ "${secret:-}" =~ ${CF_TRANSFORM_ORIGIN_SECRET_PATTERN} ]] \
        || die "Transform Rule 源站头密钥格式无效；拒绝写入"
    ref=$(cloudflare_transform_rule_ref "${domain}") || exit 1
    rule=$(cloudflare_transform_rule_json "${domain}" "${secret}") || exit 1
    ruleset_status=0
    ruleset_id=$(cloudflare_transform_ruleset_id "${zone_id}") || ruleset_status=$?
    case "${ruleset_status}" in
    0) ;;
    1) ;; # 没有该 phase 的 ruleset：创建时直接携带本规则
    2) die "Zone 内存在多个 ${CF_TRANSFORM_RULESET_PHASE} ruleset，拒绝写入：${zone_id}" ;;
    *) die "读取 Cloudflare ruleset 列表失败（状态 ${ruleset_status}），未创建任何规则：${zone_id}" ;;
    esac
    if [[ "${ruleset_status}" == "1" ]]; then
        detail=$(cloudflare_api_request POST "/zones/${zone_id}/rulesets" \
            "$(jq -cn --arg name "${CF_TRANSFORM_RULESET_NAME}" \
                --arg phase "${CF_TRANSFORM_RULESET_PHASE}" --argjson rule "${rule}" \
                '{name: $name, kind: "zone", phase: $phase, rules: [$rule]}')") \
            || die "创建 Cloudflare Transform Rules ruleset 失败：${zone_id}"
        ruleset_id=$(jq -r '.id // empty' <<<"${detail}")
        rule_id=$(cloudflare_transform_rule_id_by_ref "${detail}" "${ref}")
        [[ -n "${ruleset_id}" && -n "${rule_id}" ]] \
            || die "Cloudflare 未返回新建 Transform Rule 的 ruleset/rule ID"
        printf '%s\n%s\n' "${ruleset_id}" "${rule_id}"
        return 0
    fi
    detail=$(cloudflare_api_request GET "/zones/${zone_id}/rulesets/${ruleset_id}") \
        || die "读取 Transform Rules ruleset 失败：${ruleset_id}"
    existing=$(jq -r --arg ref "${ref}" \
        '[(.rules // [])[] | select(.ref == $ref)] | length' <<<"${detail}") \
        || die "解析 Transform Rules ruleset 失败：${ruleset_id}"
    if [[ "${existing}" == "0" ]]; then
        # 追加单条规则：不触碰 ruleset 里的其他规则。
        cloudflare_api_request POST "/zones/${zone_id}/rulesets/${ruleset_id}/rules" "${rule}" >/dev/null \
            || die "追加 Transform Rule 失败：${ruleset_id}"
        # 追加端点返回整个 ruleset（根级 .id 是 ruleset ID），新规则 ID 只能回读按 ref 定位。
        detail=$(cloudflare_api_request GET "/zones/${zone_id}/rulesets/${ruleset_id}") \
            || die "读取 Transform Rules ruleset 失败：${ruleset_id}"
        rule_id=$(cloudflare_transform_rule_id_by_ref "${detail}" "${ref}")
        [[ -n "${rule_id}" ]] || die "Cloudflare 未返回新建 Transform Rule 的规则 ID"
        printf '%s\n%s\n' "${ruleset_id}" "${rule_id}"
        return 0
    fi
    [[ "${existing}" == "1" ]] \
        || die "ruleset ${ruleset_id} 内存在 ${existing} 条同 ref 规则，拒绝覆盖"
    rule_id=$(cloudflare_transform_rule_id_by_ref "${detail}" "${ref}")
    [[ -n "${rule_id}" ]] || die "无法定位 ruleset ${ruleset_id} 内的同 ref 规则"
    cloudflare_transform_rule_owned "${detail}" "${rule_id}" "${domain}" \
        || die "Transform Rule ${ref} 的归属无法证明（域名 ${domain}），拒绝覆盖"
    cloudflare_api_request PATCH \
        "/zones/${zone_id}/rulesets/${ruleset_id}/rules/${rule_id}" "${rule}" >/dev/null \
        || die "更新 Transform Rule 失败：${rule_id}"
    printf '%s\n%s\n' "${ruleset_id}" "${rule_id}"
}

# 只删本工具的单条规则，绝不删除 ruleset（它可能被其他人的规则共用）。
cloudflare_remove_transform_rule() {
    local zone_id=$1 ruleset_id=$2 rule_id=$3
    local detail ref host expected_ref header=${CF_TRANSFORM_ORIGIN_HEADER}
    [[ -n "${zone_id}" && -n "${ruleset_id}" && -n "${rule_id}" ]] \
        || die "删除 Transform Rule 需要 Zone ID、ruleset ID 与 rule ID"
    detail=$(cloudflare_api_request GET "/zones/${zone_id}/rulesets/${ruleset_id}") \
        || die "读取 Transform Rules ruleset 失败：${ruleset_id}"
    ref=$(jq -r --arg id "${rule_id}" \
        '[(.rules // [])[] | select(.id == $id) | .ref][0] // empty' <<<"${detail}") \
        || die "解析 Transform Rules ruleset 失败：${ruleset_id}"
    [[ -n "${ref}" ]] || die "ruleset ${ruleset_id} 中找不到待删除规则：${rule_id}"
    [[ "${ref}" =~ ^easy_all-[0-9a-f]{16}$ ]] \
        || die "拒绝删除非本工具 Transform Rule：${ref}"
    jq -e --arg id "${rule_id}" --arg header "${header}" '
        [(.rules // [])[] | select(.id == $id)][0]
        | . != null
          and .action == "rewrite"
          and ((.action_parameters.headers // {}) | has($header))
    ' <<<"${detail}" >/dev/null 2>&1 \
        || die "Transform Rule ${rule_id} 不是本工具生成的改写规则，拒绝删除"
    host=$(jq -r --arg id "${rule_id}" '
        [(.rules // [])[] | select(.id == $id)][0]
        | .expression
        | capture("^http\\.host eq \"(?<host>[A-Za-z0-9.-]+)\"$").host
    ' <<<"${detail}" 2>/dev/null) || host=""
    [[ -n "${host}" ]] \
        || die "Transform Rule ${rule_id} 的表达式不是本工具生成的精确域名匹配，拒绝删除"
    expected_ref=$(cloudflare_transform_rule_ref "${host}") || exit 1
    [[ "${ref}" == "${expected_ref}" ]] \
        || die "Transform Rule ${rule_id} 的 ref 与表达式域名不一致，拒绝删除"
    cloudflare_api_request DELETE \
        "/zones/${zone_id}/rulesets/${ruleset_id}/rules/${rule_id}" >/dev/null \
        || die "删除 Transform Rule 失败：${rule_id}"
}
