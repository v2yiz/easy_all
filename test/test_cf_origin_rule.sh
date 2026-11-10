#!/usr/bin/env bash
# 阶段 1 基础库：Cloudflare Origin Rule 单规则生命周期（design §9）。
# 外部边界替身：cloudflare_api_request 记录方法与路径并返回预置 JSON；
# 断言只针对对外可观察的请求序列与请求体，不复制实现内部计算。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_cf_rule_test.XXXXXX")
fi
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}
assert_match() {
    local label=$1 text=$2 pattern=$3
    [[ "${text}" =~ ${pattern} ]] \
        || fail "${label}: <${text}> does not match <${pattern}>"
}
expect_fail() { # $1=label, 其余为待验证命令
    local label=$1
    shift
    if ("$@") >/dev/null 2>&1; then
        fail "${label}: 必须失败"
    fi
}

CF_RULE_LIB="${ROOT_DIR}/lib/cf-origin-rule.sh"
bash -n "${CF_RULE_LIB}" || fail "语法校验失败：${CF_RULE_LIB}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/log.sh"
# shellcheck source=/dev/null
source "${CF_RULE_LIB}"

API_LOG="${TMP_DIR}/cloudflare-api.log"
API_RULESETS='[]'
API_DETAIL='{}'
API_RULESET_CREATE='{}'
API_RULE_POST='{}'
API_RULE_PATCH='{}'
API_FAIL_MATCH=''

cloudflare_api_request() {
    local method=$1 path=$2 payload=${3:-}
    printf '%s\t%s\t%s\n' "${method}" "${path}" \
        "$(printf '%s' "${payload}" | tr '\n' ' ')" >>"${API_LOG}"
    if [[ -n "${API_FAIL_MATCH}" && "${method} ${path}" == *"${API_FAIL_MATCH}"* ]]; then
        printf 'Cloudflare API 不可用：%s %s\n' "${method}" "${path}" >&2
        return 1
    fi
    case "${method}" in
    GET)
        case "${path}" in
        */rulesets) printf '%s\n' "${API_RULESETS}" ;;
        */rulesets/*) printf '%s\n' "${API_DETAIL}" ;;
        *) return 1 ;;
        esac
        ;;
    POST)
        case "${path}" in
        */rulesets) printf '%s\n' "${API_RULESET_CREATE}" ;;
        */rules)
            # 真实 API 的单规则端点返回整个 ruleset（根级 .id 是 ruleset ID），新规则在 .rules 里。
            API_DETAIL=$(jq -c --argjson rule "${payload}" \
                '.rules = ((.rules // []) + [$rule + {id: "rule-added"}])' <<<"${API_DETAIL}")
            printf '%s\n' "${API_DETAIL}"
            ;;
        *) return 1 ;;
        esac
        ;;
    PATCH) printf '%s\n' "${API_RULE_PATCH}" ;;
    DELETE) printf 'null\n' ;;
    *) return 1 ;;
    esac
}

api_reset() {
    : >"${API_LOG}"
    API_RULESETS='[]'
    API_DETAIL='{}'
    API_RULESET_CREATE='{}'
    API_RULE_POST='{}'
    API_RULE_PATCH='{}'
    API_FAIL_MATCH=''
}
api_payloads() { # $1=method $2=path -> 每次请求体一行
    awk -F'\t' -v m="$1" -v p="$2" '$1 == m && $2 == p {print $3}' "${API_LOG}"
}
api_count() { # $1=method $2=path
    awk -F'\t' -v m="$1" -v p="$2" '$1 == m && $2 == p {c++} END {print c + 0}' "${API_LOG}"
}
api_method_count() {
    awk -F'\t' -v m="$1" '$1 == m {c++} END {print c + 0}' "${API_LOG}"
}
rule_json_for() { # $1=domain $2=port -> 期望的规则体（来自 design §9）
    jq -cn --arg domain "$1" --argjson port "$2" \
        --arg ref "$(cloudflare_origin_rule_ref "$1")" \
        '{ref: $ref, expression: ("http.host eq " + ($domain | @json)),
          action: "route", action_parameters: {origin: {port: $port}}}'
}

DOMAIN="sub.example.com"
PORT=8443
REF=$(cloudflare_origin_rule_ref "${DOMAIN}")

# --- ref 确定性 -------------------------------------------------------------
assert_match "ref 格式" "${REF}" '^easy_all-[0-9a-f]{16}$'
expected_digest=$(printf '%s' "${DOMAIN}" | openssl dgst -sha256 | awk '{print $NF}')
assert_equal "ref 取域名 SHA256 前 16 位" "easy_all-${expected_digest:0:16}" "${REF}"
assert_equal "ref 对大小写与尾点规范化" "${REF}" "$(cloudflare_origin_rule_ref 'SUB.Example.com.')"
[[ "$(cloudflare_origin_rule_ref other.example.com)" != "${REF}" ]] \
    || fail "不同域名必须得到不同 ref"

# --- 无 ruleset：创建请求直接携带规则 --------------------------------------
api_reset
API_RULESET_CREATE=$(jq -cn --arg ref "${REF}" '{id: "rs-new", rules: [{id: "rule-new", ref: $ref}]}')
ids=$(cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}")
assert_equal "输出 ruleset 与 rule ID" "rs-new rule-new" "$(printf '%s' "${ids}" | tr '\n' ' ' | sed 's/ $//')"
assert_equal "创建 ruleset 只发一次 POST" "1" "$(api_count POST /zones/zone1/rulesets)"
creation=$(api_payloads POST /zones/zone1/rulesets)
assert_equal "创建 kind=zone" "zone" "$(jq -r '.kind' <<<"${creation}")"
assert_equal "创建 phase=http_request_origin" "http_request_origin" "$(jq -r '.phase' <<<"${creation}")"
assert_equal "创建带上本工具的单条规则" "$(rule_json_for "${DOMAIN}" "${PORT}" | jq -c .)" \
    "$(jq -c '.rules[0]' <<<"${creation}")"
assert_equal "创建规则动作是 route" "route" "$(jq -r '.rules[0].action' <<<"${creation}")"
assert_equal "创建规则带 origin 端口" "${PORT}" \
    "$(jq -r '.rules[0].action_parameters.origin.port' <<<"${creation}")"
assert_equal "创建规则表达式精确匹配域名" "http.host eq \"${DOMAIN}\"" \
    "$(jq -r '.rules[0].expression' <<<"${creation}")"
assert_equal "创建规则 ref 确定性" "${REF}" "$(jq -r '.rules[0].ref' <<<"${creation}")"
assert_equal "全程不使用整体 PUT" "0" "$(api_method_count PUT)"

# --- 已有 ruleset：单规则端点追加 ------------------------------------------
api_reset
API_RULESETS=$(jq -cn '[{id: "rs1", name: "shared", kind: "zone", phase: "http_request_origin"}]')
API_DETAIL=$(jq -cn '{id: "rs1", rules: [
    {id: "foreign", ref: "someone-else", expression: "http.host eq \"x.example.com\"", action: "route"}
]}')
ids=$(cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}")
assert_equal "追加后输出 ruleset 与新规则 ID（不能把 ruleset ID 当成规则 ID）" "rs1 rule-added" \
    "$(printf '%s' "${ids}" | tr '\n' ' ' | sed 's/ $//')"
assert_equal "只走单规则端点追加" "1" "$(api_count POST /zones/zone1/rulesets/rs1/rules)"
assert_equal "追加后回读 ruleset 按 ref 定位新规则" "2" \
    "$(api_count GET /zones/zone1/rulesets/rs1)"
assert_equal "追加请求体是单条规则对象" "$(rule_json_for "${DOMAIN}" "${PORT}" | jq -c .)" \
    "$(api_payloads POST /zones/zone1/rulesets/rs1/rules | jq -c .)"
assert_equal "追加不改动他人规则" "0" "$(api_method_count PATCH)"
assert_equal "追加不整体提交 ruleset" "0" "$(api_method_count PUT)"

api_reset
API_RULESETS='[{"id":"rs1","kind":"zone","phase":"http_request_origin"}]'
API_DETAIL='{"id":"rs1","rules":[]}'
API_FAIL_MATCH="GET /zones/zone1/rulesets/rs1"
expect_fail "追加后回读 ruleset 失败" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "回读失败时不整体 PUT" "0" "$(api_method_count PUT)"

# --- 已有同 ref 规则：PATCH 更新 -------------------------------------------
api_reset
API_RULESETS='[{"id":"rs1","kind":"zone","phase":"http_request_origin"}]'
API_DETAIL=$(jq -cn --arg ref "${REF}" '{id: "rs1", rules: [
    {id: "rule1", ref: $ref, expression: "http.host eq \"sub.example.com\"",
     action: "route", action_parameters: {origin: {port: 8443}}}
]}')
API_RULE_PATCH=$(jq -cn --arg ref "${REF}" '{id: "rule1", ref: $ref}')
ids=$(cloudflare_ensure_origin_rule zone1 "${DOMAIN}" 8444)
assert_equal "更新时输出既有 ID" "rs1 rule1" \
    "$(printf '%s' "${ids}" | tr '\n' ' ' | sed 's/ $//')"
assert_equal "走单规则 PATCH" "1" "$(api_count PATCH /zones/zone1/rulesets/rs1/rules/rule1)"
assert_equal "PATCH 使用新端口与同 ref" "8444 ${REF}" \
    "$(api_payloads PATCH /zones/zone1/rulesets/rs1/rules/rule1 \
        | jq -r '"\(.action_parameters.origin.port) \(.ref)"')"
assert_equal "更新不新增规则" "0" "$(api_count POST /zones/zone1/rulesets/rs1/rules)"

# --- 冲突与不可用：不覆盖、不整体 PUT --------------------------------------
api_reset
API_RULESETS='[{"id":"rs1","kind":"zone","phase":"http_request_origin"}]'
API_DETAIL=$(jq -cn --arg ref "${REF}" '{id: "rs1", rules: [
    {id: "rule1", ref: $ref, expression: "http.host eq \"other.example.com\"",
     action: "route", action_parameters: {origin: {port: 8443}}}
]}')
expect_fail "同 ref 但表达式不一致" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "冲突时不 PATCH 他人规则" "0" "$(api_method_count PATCH)"
assert_equal "冲突时不整体 PUT" "0" "$(api_method_count PUT)"

api_reset
API_RULESETS='[{"id":"rs1","kind":"zone","phase":"http_request_origin"}]'
API_DETAIL=$(jq -cn --arg ref "${REF}" '{id: "rs1", rules: [
    {id: "rule1", ref: $ref, expression: "http.host eq \"sub.example.com\"", action: "route",
     action_parameters: {origin: {port: 8443}}},
    {id: "rule2", ref: $ref, expression: "http.host eq \"sub.example.com\"", action: "route",
     action_parameters: {origin: {port: 8443}}}
]}')
expect_fail "重复 ref 规则" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "重复 ref 不做写操作" "0" "$(api_method_count POST)"

api_reset
API_RULESETS=$(jq -cn '[
    {id: "rs1", kind: "zone", phase: "http_request_origin"},
    {id: "rs2", kind: "zone", phase: "http_request_origin"}
]')
expect_fail "多个 phase ruleset" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "多个 ruleset 不写入" "0" "$(api_method_count POST)"

api_reset
API_FAIL_MATCH="GET /zones/zone1/rulesets"
expect_fail "读取 ruleset 列表失败" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "读取失败时不创建 ruleset" "0" "$(api_count POST /zones/zone1/rulesets)"
assert_equal "读取失败时不写任何规则" "0" "$(api_method_count POST)"
assert_equal "读取失败时不整体 PUT" "0" "$(api_method_count PUT)"

api_reset
API_RULESETS='not-json'
expect_fail "ruleset 列表解析失败" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "解析失败时不创建 ruleset" "0" "$(api_count POST /zones/zone1/rulesets)"

api_reset
API_FAIL_MATCH="POST /zones/zone1/rulesets"
expect_fail "创建规则集端点不可用" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "端点不可用时不整体 PUT" "0" "$(api_method_count PUT)"

api_reset
API_RULESETS='[{"id":"rs1","kind":"zone","phase":"http_request_origin"}]'
API_DETAIL='{"id":"rs1","rules":[]}'
API_FAIL_MATCH="POST /zones/zone1/rulesets/rs1/rules"
expect_fail "单规则追加端点不可用" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${PORT}"
assert_equal "追加失败时不整体 PUT" "0" "$(api_method_count PUT)"

# --- 输入校验 ---------------------------------------------------------------
for bad_port in 0 70000 abc; do
    api_reset
    expect_fail "非法端口 ${bad_port}" cloudflare_ensure_origin_rule zone1 "${DOMAIN}" "${bad_port}"
    assert_equal "非法端口 ${bad_port} 不发起请求" "0" "$(api_count GET /zones/zone1/rulesets)"
done
api_reset
expect_fail "域名含引号" cloudflare_ensure_origin_rule zone1 'bad"domain.com' "${PORT}"
expect_fail "域名缺根域" cloudflare_ensure_origin_rule zone1 nodot "${PORT}"
assert_equal "非法域名不发起请求" "0" "$(api_count GET /zones/zone1/rulesets)"

# --- 删除：只删本工具的单条规则 --------------------------------------------
api_reset
API_DETAIL=$(jq -cn --arg ref "${REF}" '{id: "rs1", rules: [
    {id: "rule1", ref: $ref, expression: "http.host eq \"sub.example.com\"",
     action: "route", action_parameters: {origin: {port: 8443}}},
    {id: "foreign", ref: "someone-else", expression: "http.host eq \"x.example.com\"", action: "route"}
]}')
cloudflare_remove_origin_rule zone1 rs1 rule1 || fail "删除自有规则应成功"
assert_equal "删除走单规则端点" "1" "$(api_count DELETE /zones/zone1/rulesets/rs1/rules/rule1)"
assert_equal "不删除共享 ruleset" "0" "$(api_count DELETE /zones/zone1/rulesets/rs1)"
assert_equal "不删除他人规则" "0" "$(api_count DELETE /zones/zone1/rulesets/rs1/rules/foreign)"

api_reset
API_DETAIL=$(jq -cn '{id: "rs1", rules: [
    {id: "rule1", ref: "someone-else", expression: "http.host eq \"sub.example.com\"", action: "route"}
]}')
expect_fail "非本工具 ref" cloudflare_remove_origin_rule zone1 rs1 rule1
assert_equal "非本工具 ref 不删除" "0" "$(api_method_count DELETE)"

api_reset
API_DETAIL=$(jq -cn --arg ref "${REF}" '{id: "rs1", rules: [
    {id: "rule1", ref: $ref, expression: "http.host eq \"other.example.com\"", action: "route"}
]}')
expect_fail "ref 与表达式域名不一致" cloudflare_remove_origin_rule zone1 rs1 rule1
assert_equal "ref 不一致不删除" "0" "$(api_method_count DELETE)"

api_reset
API_DETAIL=$(jq -cn --arg ref "${REF}" '{id: "rs1", rules: [
    {id: "rule1", ref: $ref, expression: "(http.host eq \"sub.example.com\") or (true)", action: "route"}
]}')
expect_fail "复合表达式不删除" cloudflare_remove_origin_rule zone1 rs1 rule1
assert_equal "复合表达式不删除规则" "0" "$(api_method_count DELETE)"

api_reset
API_DETAIL='{"id":"rs1","rules":[]}'
expect_fail "规则不存在" cloudflare_remove_origin_rule zone1 rs1 rule1
assert_equal "规则不存在不删除" "0" "$(api_method_count DELETE)"

# --- package.json 接线 -------------------------------------------------------
grep -Fq 'test/test_cf_origin_rule.sh' "${ROOT_DIR}/package.json" \
    || fail "npm test 必须串入 Origin Rule 测试"

printf 'ok - Cloudflare Origin Rule 测试通过\n'
