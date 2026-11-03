#!/usr/bin/env bash
# 安装参数层（lib/params.sh）单元测试：加载、类型、聚合错误、密钥脱敏、权限与模板。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >&2 && pwd)
PARAMS_LIB="${ROOT_DIR}/lib/params.sh"

# 受限环境可能禁止写用户默认 TMPDIR：显式模板 + /tmp 兜底（与其他测试一致）。
TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_params_test.XXXXXX")
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

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] \
        || fail "${label}: missing <${expected}> in <${text}>"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected <${unexpected}> in <${text}>"
}

command -v jq >/dev/null 2>&1 || fail "test_params 需要 jq"

write_params() { # $1=文件名 $2=内容；始终 0600
    printf '%s\n' "$2" >"${TMP_DIR}/$1"
    chmod 600 "${TMP_DIR}/$1"
}

# 每个用例都在独立子 shell 中执行：params 层状态（数组/变量）互不影响。
capture() { # $1=用例函数名；合并 stdout+stderr，返回用例退出码
    local status=0 out
    out=$("$1" 2>&1) || status=$?
    printf '%s' "${out}"
    return "${status}"
}

bash -n "${PARAMS_LIB}"

# 1. 空文件必须被拒绝（不能把空参数当成"全部用默认值"）
case_empty() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin reality "${TMP_DIR}/empty.json"
}

# 2. 完整参数：类型转换、赋值、默认值、校验全部通过
case_ok() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    validate_ipv4() { [[ "$1" =~ ^[0-9.]+$ ]]; }
    validate_uuid() { [[ "$1" =~ ^[0-9a-f-]{36}$ ]]; }
    params_when_never() { return 1; }
    normalize_subscription_mode() {
        case "$1" in
        link) printf 'link\n' ;;
        *) return 1 ;;
        esac
    }
    params_cross_reality() { :; }
    params_begin reality "${TMP_DIR}/ok.json"
    params_declare NODE_HOST --required --check validate_ipv4
    params_declare NODE_NAME --required --default fallback
    params_declare VLESS_UUID --check validate_uuid
    params_declare SUBSCRIPTION_MODE --required --default deploy \
        --normalize normalize_subscription_mode
    params_declare MONTHLY_QUOTAS_GB --type json_object
    params_declare CHECK_INTERVAL --check params_check_nonnegative_int
    params_declare NOT_APPLICABLE --when params_when_never
    params_finish >/dev/null
    printf '%s|%s|%s|%s|%s|%s\n' \
        "${NODE_HOST}" "${NODE_NAME}" "${VLESS_UUID}" "${SUBSCRIPTION_MODE}" \
        "${MONTHLY_QUOTAS_GB}" "${CHECK_INTERVAL}"
}

# 3. 错误必须一次报全
case_bad() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    validate_ipv4() { [[ "$1" =~ ^[0-9.]+$ ]]; }
    params_when_never() { return 1; }
    params_cross_reality() { params_error '跨字段：六个域名必须互不相同'; }
    params_begin reality "${TMP_DIR}/bad.json"
    params_declare NODE_HOST --required --label '节点地址' --check validate_ipv4
    params_declare NODE_ENV --when params_when_never --label '环境'
    params_declare SUBSCRIPTION_MODE --required --default deploy
    params_declare VLESS_UUID --required --label '节点 UUID'
    params_finish
}

# 4. json_object 字段拿到字符串时必须报类型错误
case_type() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_cross_reality() { :; }
    params_begin reality "${TMP_DIR}/type.json"
    params_declare ALLOWED_TOKENS --type json_object
    params_finish
}

# 5. 密钥必须脱敏
case_secret() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_cross_reality() { :; }
    params_begin reality "${TMP_DIR}/secret.json"
    params_declare CLOUDFLARE_API_TOKEN --required --secret --label 'CF Token'
    params_finish
}

# 5b. 密钥校验失败时不得把明文带进错误信息
case_secret_invalid() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_cross_reality() { :; }
    params_begin reality "${TMP_DIR}/secret-bad.json"
    params_declare CLOUDFLARE_API_TOKEN --required --secret --label 'CF Token' \
        --check params_check_cf_token
    params_finish
}

case_permissions() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin reality "${TMP_DIR}/loose.json"
}

case_symlink() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin reality "${TMP_DIR}/link.json"
}

# 7. 标准输入（--params -）：不需要磁盘文件，也跳过权限检查
case_stdin() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_cross_reality() { :; }
    params_begin reality -
    params_declare NODE_NAME --required
    params_finish >/dev/null
    printf '%s' "${NODE_NAME}"
}

case_mode_mismatch() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin combined "${TMP_DIR}/ok.json"
}

case_envelope() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin reality "${TMP_DIR}/envelope.json"
}

case_version() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin reality "${TMP_DIR}/version.json"
}

# 9. 模板模式
case_template() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    validate_domain() { [[ "$1" == *.* ]]; }
    normalize_domain() { printf '%s\n' "${1%.}"; }
    params_template_begin gcore
    params_declare CLOUDFLARE_ZONE --required --label 'Zone'
    params_declare DIRECT_DOMAIN --default "node.${CLOUDFLARE_ZONE}" \
        --normalize normalize_domain --check validate_domain --label '派生域名'
    params_declare SUB_DOWNLOAD_NAME --default 'EASY_ALL' --label '文件名'
    params_declare ALLOWED_TOKENS --type json_object --label 'Token 字典'
    params_declare WORKER_AGGREGATION_CONFIG --type json_object --default '{}' --label '聚合'
    # 字段说明写到 stderr；只比较 stdout 里的 JSON。
    params_finish 2>/dev/null
}

# 10. 重复声明是内部错误
case_duplicate() {
    # shellcheck source=/dev/null
    source "${PARAMS_LIB}"
    params_begin reality -
    params_declare NODE_HOST
    params_declare NODE_HOST
}

write_params empty.json ''
empty_out=$(capture case_empty) && fail "empty params must be rejected"
assert_contains "empty params rejected" "${empty_out}" "参数内容为空"

write_params ok.json '{
  "schema_version": 1,
  "mode": "reality",
  "params": {
    "NODE_HOST": "203.0.113.10",
    "SUBSCRIPTION_MODE": "link",
    "NODE_NAME": "节点一",
    "VLESS_UUID": "0f8fad5b-d9cb-469f-a165-70867728950e",
    "MONTHLY_QUOTAS_GB": {"owner": 0},
    "CHECK_INTERVAL": 30
  }
}'
ok_out=$(capture case_ok) || fail "valid params rejected: ${ok_out}"
# 摘要写到 stderr 且被 capture 合并进来了；只比较最后一行的解析结果。
assert_equal "valid params resolved" \
    '203.0.113.10|节点一|0f8fad5b-d9cb-469f-a165-70867728950e|link|{"owner":0}|30' \
    "$(printf '%s\n' "${ok_out}" | tail -n 1)"

write_params bad.json '{
  "schema_version": 1,
  "mode": "reality",
  "params": {
    "SUBSCRIPTION_MODE": "link",
    "NODE_HOST": "not-an-ip",
    "NODE_NAME": "x",
    "TYPO_FIELD": "oops",
    "NODE_ENV": "production"
  }
}'
bad_out=$(capture case_bad) && fail "invalid params must be rejected"
assert_contains "aggregated: required field" "${bad_out}" "缺少必填项：VLESS_UUID"
assert_contains "aggregated: invalid value" "${bad_out}" "NODE_HOST（节点地址）：取值无效：not-an-ip"
assert_contains "aggregated: unknown field" "${bad_out}" "未知字段：TYPO_FIELD"
assert_contains "aggregated: inapplicable field" "${bad_out}" "NODE_ENV（环境）：当前配置下不适用"
assert_contains "aggregated: cross-field error" "${bad_out}" "跨字段：六个域名必须互不相同"
assert_contains "aggregated: counts all errors" "${bad_out}" "共 6 项错误"
assert_contains "aggregated: points to --check-params" "${bad_out}" "--check-params）"

write_params type.json '{"schema_version": 1, "mode": "reality", "params": {"ALLOWED_TOKENS": "owner=token"}}'
type_out=$(capture case_type) && fail "string value for json_object must be rejected"
assert_contains "type: json_object needs object" "${type_out}" "类型无效，需要 JSON object"

write_params secret.json \
    '{"schema_version": 1, "mode": "reality", "params": {"CLOUDFLARE_API_TOKEN": "abcdefghijklmnopqrstuvwxyz0123456789"}}'
secret_out=$(capture case_secret) || fail "secret params rejected: ${secret_out}"
assert_contains "secret: masked" "${secret_out}" '*** (36 字符)'
assert_not_contains "secret: plaintext never printed" "${secret_out}" 'abcdefghijklmnopqrstuvwxyz0123456789'

write_params secret-bad.json \
    '{"schema_version": 1, "mode": "reality", "params": {"CLOUDFLARE_API_TOKEN": "short-secret-value"}}'
secret_bad_out=$(capture case_secret_invalid) && fail "invalid secret must be rejected"
assert_contains "secret: invalid value reported" "${secret_bad_out}" "取值无效（密钥内容不显示）"
assert_not_contains "secret: invalid value not echoed" "${secret_bad_out}" "short-secret-value"

cp "${TMP_DIR}/secret.json" "${TMP_DIR}/loose.json"
chmod 644 "${TMP_DIR}/loose.json"
perm_out=$(capture case_permissions) && fail "world-readable params must be rejected"
assert_contains "permissions: refuses loose mode" "${perm_out}" "参数文件权限过宽（644）"
assert_contains "permissions: suggests chmod" "${perm_out}" "chmod 600"

ln -s "${TMP_DIR}/secret.json" "${TMP_DIR}/link.json"
link_out=$(capture case_symlink) && fail "symlink params must be rejected"
assert_contains "permissions: refuses symlink" "${link_out}" "不能是符号链接"

stdin_out=$(capture case_stdin <<'EOF'
{"schema_version": 1, "mode": "reality", "params": {"NODE_NAME": "stdin-node"}}
EOF
) || fail "stdin params rejected"
assert_equal "stdin: params read from -" "stdin-node" \
    "$(printf '%s\n' "${stdin_out}" | tail -n 1)"

mismatch_out=$(capture case_mode_mismatch) && fail "mode mismatch must be rejected"
assert_contains "mode: mismatch rejected" "${mismatch_out}" "参数文件 mode=reality 与本次安装模式 combined 不一致"

write_params envelope.json '{"schema_version": 2, "mode": "reality", "params": {}, "extra": true}'
envelope_out=$(capture case_envelope) && fail "bad envelope must be rejected"
assert_contains "envelope: unknown top-level key" "${envelope_out}" "未知顶层字段：extra"

write_params version.json '{"schema_version": 9, "mode": "reality", "params": {}}'
version_out=$(capture case_version) && fail "bad schema_version must be rejected"
assert_contains "envelope: schema_version pinned" "${version_out}" "schema_version 必须为 1"

template_out=$(capture case_template) || fail "template mode failed"
assert_equal "template: valid JSON" "gcore" "$(jq -r '.mode' <<<"${template_out}")"
assert_equal "template: required empty" "" "$(jq -r '.params.CLOUDFLARE_ZONE' <<<"${template_out}")"
assert_equal "template: default kept" "EASY_ALL" "$(jq -r '.params.SUB_DOWNLOAD_NAME' <<<"${template_out}")"
assert_equal "template: object without default is null" "null" \
    "$(jq -r '.params.ALLOWED_TOKENS | if . == null then "null" else "value" end' <<<"${template_out}")"
assert_equal "template: object default kept" "{}" \
    "$(jq -c '.params.WORKER_AGGREGATION_CONFIG' <<<"${template_out}")"
# 派生默认值依赖为空时（这里是 CLOUDFLARE_ZONE）不能输出 "node." 这类半成品
assert_equal "template: derived default dropped when invalid" "" \
    "$(jq -r '.params.DIRECT_DOMAIN' <<<"${template_out}")"

duplicate_out=$(capture case_duplicate <<'EOF'
{"schema_version": 1, "mode": "reality", "params": {}}
EOF
) && fail "duplicate declaration must be rejected"
assert_contains "declare: duplicate rejected" "${duplicate_out}" "字段 NODE_HOST 被重复声明"

# 11. 所有 Profile 的安装输入必须是声明的参数，且安装前调用预检
for profile in "${ROOT_DIR}"/profiles/*.sh; do
    name=$(basename "${profile}")
    body=$(awk '/^collect_install_inputs\(\)/,/^}/' "${profile}")
    [[ -n "${body}" ]] || fail "${name}: missing collect_install_inputs"
    assert_contains "${name}: install inputs declare params" "${body}" "params_declare"
    assert_not_contains "${name}: install inputs must not prompt" "${body}" "prompt_value"
    assert_not_contains "${name}: install inputs must not prompt" "${body}" "prompt_secret"
    assert_not_contains "${name}: install inputs must not prompt" "${body}" "read_bilingual"
    [[ "$(printf '%s\n' "${body}" | grep -c 'params_declare')" -ge 5 ]] \
        || fail "${name}: collect_install_inputs declares too few fields"
    grep -q 'install_params_preflight' "${profile}" \
        || fail "${name}: install pipeline must call install_params_preflight"
    grep -q '^apply_install_inputs()' "${profile}" \
        || fail "${name}: missing apply_install_inputs"
done

# 12. 声明里引用的校验/规范化/默认值函数必须真实存在（防拼写错误）
all_text=$(
    cat "${ROOT_DIR}"/lib/*.sh "${ROOT_DIR}"/profiles/*.sh
)
for profile in "${ROOT_DIR}"/profiles/*.sh; do
    name=$(basename "${profile}")
    for hook in $(grep -oE '\--(check|normalize|default-fn|when) [A-Za-z0-9_]+' "${profile}" \
        | awk '{print $2}' | sort -u); do
        grep -qE "^${hook}\(\)" <<<"${all_text}" \
            || fail "${name}: hook function ${hook} does not exist"
    done
done

printf 'ok - install params\n'
