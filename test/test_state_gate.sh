#!/usr/bin/env bash
# 状态 schema 与字段集的单一来源（design §5）。
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-state.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf '\033[31mnot ok - %s\033[0m\n' "$*" >&2
    exit 1
}
assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing <${expected}> in <${text}>"
}
assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected <${unexpected}> in <${text}>"
}

# shellcheck source=lib/state.sh
source "${ROOT_DIR}/lib/state.sh"

[[ "${EASY_ALL_STATE_SCHEMA_VERSION}" == "1" ]] || fail "schema 必须为 1"
for protocol in anytls cloudfront cloudflare combined-cloudfront; do
    state_protocol_valid "${protocol}" || fail "协议应受支持：${protocol}"
done
for legacy in reality cdn combined combined-cloudflare ""; do
    state_protocol_valid "${legacy}" && fail "旧/空协议不得通过：${legacy}"
done

fields=$(state_required_fields anytls deploy)
grep -Fxq DIRECT_DOMAIN <<<"${fields}" || fail "模式 1 deploy 需要 DIRECT_DOMAIN"
grep -Fxq ANYTLS_PASSWORD <<<"${fields}" || fail "模式 1 deploy 需要 ANYTLS_PASSWORD"
grep -Fxq SUBSCRIPTION_DOMAIN <<<"${fields}" || fail "模式 1 deploy 需要 SUBSCRIPTION_DOMAIN"
assert_absent() {
    local list=$1 name=$2
    if grep -Fxq "${name}" <<<"${list}"; then
        fail "$3"
    fi
}
assert_absent "${fields}" CF_NODE_DOMAIN "模式 1 不得要求 CDN 节点域名"
assert_absent "$(state_required_fields anytls link)" SUBSCRIPTION_DOMAIN \
    "模式 1 link 不得要求订阅域名"
assert_absent "$(state_required_fields anytls link)" CLOUDFLARE_ORIGIN_RULE_ID \
    "模式 1 link 不得要求 Origin Rule"

fields=$(state_required_fields cloudfront deploy)
grep -Fxq AWS_ACM_CERTIFICATE_ARN <<<"${fields}" || fail "模式 2 需要 ACM ARN"
grep -Fxq CDN_TRAFFIC_PROTECTION_GB <<<"${fields}" || fail "模式 2 需要 985GB 字段"
assert_absent "${fields}" DIRECT_DOMAIN "模式 2 不得要求直连域名"
assert_absent "${fields}" REALITY_TARGET "模式 2 不得保留 Reality 字段"
grep -Fxq CLOUDFLARE_ORIGIN_CERT_ID <<<"$(state_required_fields cloudflare deploy)" \
    || fail "模式 3 需要 Origin CA 字段"
assert_absent "$(state_required_fields cloudflare deploy)" ORIGIN_HEADER_SECRET \
    "模式 3 不得要求源站头密钥"
fields=$(state_required_fields combined-cloudfront deploy)
grep -Fxq DIRECT_DOMAIN <<<"${fields}" || fail "模式 4 需要直连域名"
grep -Fxq VLESS_PATH <<<"${fields}" || fail "模式 4 需要 VLESS 路径"

state_required_fields nope >/dev/null && fail "未知协议必须返回非零"

state_file="${TMP_DIR}/state.env"
cat >"${state_file}" <<STATE
STATE_VERSION=1
PROTOCOL=anytls
SUBSCRIPTION_MODE=deploy
DIRECT_DOMAIN=node.example.com
DIRECT_NODE_NAME=direct
ANYTLS_PASSWORD=0123456789abcdef
STATE
missing=$(state_missing_fields "${state_file}" || true)
grep -Fxq TCP_ACCELERATION <<<"${missing}" || fail "缺失字段必须点名 TCP_ACCELERATION"
grep -Fxq SUBSCRIPTION_DOMAIN <<<"${missing}" || fail "缺失字段必须点名 SUBSCRIPTION_DOMAIN"

cat >"${state_file}" <<'STATE'
STATE_VERSION=0
PROTOCOL=reality
STATE
[[ "$(state_file_schema "${state_file}")" == "0" ]] || fail "应读到 schema 0"
state_schema_supported "$(state_file_schema "${state_file}")" && fail "schema 0 不得被接受"
state_protocol_valid "$(state_file_value "${state_file}" PROTOCOL)" \
    && fail "PROTOCOL=reality 不得被接受"

# 完整状态：按字段集写满后必须判定为完整。
render="${TMP_DIR}/rendered.env"
cd_fields=()
while IFS= read -r field; do
    cd_fields+=("${field}")
    case "${field}" in
    PROTOCOL) printf -v "${field}" 'cloudfront' ;;
    SUBSCRIPTION_MODE) printf -v "${field}" 'deploy' ;;
    CDN_TRAFFIC_PROTECTION_GB) printf -v "${field}" '985' ;;
    *) printf -v "${field}" 'value' ;;
    esac
done < <(state_required_fields cloudfront deploy)
SUBSCRIPTION_MODE=deploy
state_render "${render}" "${cd_fields[@]}" || fail "state_render 失败"
[[ -z "$(state_missing_fields "${render}")" ]] || fail "写满字段后不应再报缺失"

case "$(state_legacy_rejection_message 0)" in
*"旧版（schema 0）"*"uninstall"*) ;;
*) fail "旧 schema 提示必须点名旧版本卸载" ;;
esac

# 缺 STATE_VERSION 只可能来自截断/改坏：提示必须与「旧 schema」分开，并给出按原安装
# 版本的恢复步骤（旧版本 loader 也要求版本行，直接让用户用旧版本卸载不可执行）。
damaged_dir="${TMP_DIR}/damaged"
mkdir -p "${damaged_dir}"
write_state_without_version() { # $1=file $2=protocol
    local file=$1 protocol=$2 field
    local -a fields=()
    while IFS= read -r field; do fields+=("${field}"); done \
        < <(state_required_fields "${protocol}" deploy)
    for field in "${fields[@]}"; do
        case "${field}" in
        PROTOCOL) printf -v "${field}" '%s' "${protocol}" ;;
        SUBSCRIPTION_MODE) printf -v "${field}" 'deploy' ;;
        CDN_TRAFFIC_PROTECTION_GB) printf -v "${field}" '985' ;;
        SCHEDULED_REBOOT_ENABLED) printf -v "${field}" '0' ;;
        SCHEDULED_REBOOT_HOUR) printf -v "${field}" '4' ;;
        *) printf -v "${field}" 'value' ;;
        esac
    done
    state_render "${file}" "${fields[@]}"
    grep -v '^STATE_VERSION=' "${file}" >"${file}.tmp"
    mv -- "${file}.tmp" "${file}"
}
write_state_with_version_line() { # $1=file $2=STATE_VERSION 行（可为空值）
    local file=$1 line=$2
    write_state_without_version "${file}" anytls
    { printf '%s\n' "${line}"; cat "${file}"; } >"${file}.tmp"
    mv -- "${file}.tmp" "${file}"
}

damaged_state="${damaged_dir}/state.env"
write_state_without_version "${damaged_state}" anytls
damaged_launcher=$(
    EASY_ALL_STATE_FILE_OVERRIDE="${damaged_state}" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
        bash -c 'source "$1"; detect_installed_mode' _ "${ROOT_DIR}/easy_all" 2>&1
) && fail "缺少 STATE_VERSION 的状态必须被拒绝"
assert_contains "缺版本提示点名 STATE_VERSION" "${damaged_launcher}" "缺少 STATE_VERSION"
assert_contains "缺版本提示给出 5.x 补 1" "${damaged_launcher}" "STATE_VERSION=1"
assert_contains "缺版本提示给出 4.x 补 0" "${damaged_launcher}" "STATE_VERSION=0"
assert_contains "缺版本提示保留不明版本现场" "${damaged_launcher}" "保留现场"
assert_not_contains "缺版本不再误报旧 schema" "${damaged_launcher}" "旧版（schema"

damaged_launcher_gate=$(
    EASY_ALL_STATE_FILE_OVERRIDE="${damaged_state}" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
        bash -c 'source "$1"; launcher_require_current_schema' _ "${ROOT_DIR}/easy_all" 2>&1
) && fail "launcher 覆盖前门禁必须拒绝缺少 STATE_VERSION 的状态"
assert_contains "launcher 门禁使用损坏提示" "${damaged_launcher_gate}" "缺少 STATE_VERSION"
assert_not_contains "launcher 门禁不再误报旧 schema" "${damaged_launcher_gate}" "旧版（schema"

mkdir -p "${damaged_dir}/load-state"
cp "${damaged_state}" "${damaged_dir}/load-state/state.env"
damaged_load=$(
    RUNTIME_TMP="${damaged_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${damaged_dir}/load-state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${damaged_dir}/load-subscriptions" \
        bash -c 'source "$1/profiles/anytls.sh"; load_state' _ "${ROOT_DIR}" 2>&1
) && fail "load_state 必须拒绝缺少 STATE_VERSION 的状态"
assert_contains "load_state 使用损坏提示" "${damaged_load}" "缺少 STATE_VERSION"
assert_not_contains "load_state 不再误报旧 schema" "${damaged_load}" "旧版（schema"

# 6b. 源文件还带语法噪声（未闭合引号）：load_state 必须在 source 之前给出恢复指引，
# 而不是先抛 bash 语法错误。
syntax_state_dir="${damaged_dir}/load-syntax"
mkdir -p "${syntax_state_dir}"
cp "${damaged_state}" "${syntax_state_dir}/state.env"
printf "BROKEN='unterminated\n" >>"${syntax_state_dir}/state.env"
syntax_load=$(
    RUNTIME_TMP="${damaged_dir}/runtime-syntax" \
    EASY_ALL_STATE_DIR_OVERRIDE="${syntax_state_dir}" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${damaged_dir}/load-syntax-subs" \
        bash -c 'source "$1/profiles/anytls.sh"; load_state' _ "${ROOT_DIR}" 2>&1
) && fail "语法损坏且缺 STATE_VERSION 的状态必须被 load_state 拒绝"
assert_contains "load_state 先给缺版本恢复指引" "${syntax_load}" "缺少 STATE_VERSION"
assert_not_contains "load_state 不得先抛 bash 语法错误" "${syntax_load}" "syntax error"
assert_not_contains "语法损坏不得误报旧 schema" "${syntax_load}" "旧版（schema"

# bootstrap 的门禁在 sudo 子 shell 用 declare -f 运行，不能 source lib/state.sh：
# 只抽取两个纯函数验证文案与判定一致。
bootstrap_gate_script=$(awk '/^die\(\) \{/,/^}/' "${ROOT_DIR}/bootstrap.sh")
bootstrap_gate_script+=$'\n'
bootstrap_gate_script+=$(awk '/^require_current_schema\(\)/,/^}/' "${ROOT_DIR}/bootstrap.sh")
bootstrap_gate_script+=$'\nrequire_current_schema'
bootstrap_gate=$(
    EASY_ALL_STATE_FILE_OVERRIDE="${damaged_state}" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
        bash -c "${bootstrap_gate_script}" 2>&1
) && fail "bootstrap 门禁必须拒绝缺少 STATE_VERSION 的状态"
assert_contains "bootstrap 使用损坏提示" "${bootstrap_gate}" "缺少 STATE_VERSION"
assert_contains "bootstrap 给出 4.x 补 0" "${bootstrap_gate}" "STATE_VERSION=0"
assert_not_contains "bootstrap 不再误报旧 schema" "${bootstrap_gate}" "旧版（schema"

# 版本行存在但值为空：仍属「存在且 ≠1」，必须继续给出原有旧 schema 提示；
# 否则用户按「补 STATE_VERSION=1」修改后，最后一条空赋值仍会覆盖修复值。
empty_index=0
for empty_line in 'STATE_VERSION=' "STATE_VERSION=''"; do
    empty_index=$((empty_index + 1))
    empty_state="${damaged_dir}/state-empty-${empty_index}.env"
    write_state_with_version_line "${empty_state}" "${empty_line}"

    empty_detect=$(
        EASY_ALL_STATE_FILE_OVERRIDE="${empty_state}" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
            bash -c 'source "$1"; detect_installed_mode' _ "${ROOT_DIR}/easy_all" 2>&1
    ) && fail "空版本值必须被拒绝（detect: ${empty_line}）"
    assert_contains "空版本值走旧 schema 提示（detect）" "${empty_detect}" "旧版（schema 缺失）"
    assert_not_contains "空版本值不误报缺行（detect）" "${empty_detect}" "缺少 STATE_VERSION"

    empty_launcher_gate=$(
        EASY_ALL_STATE_FILE_OVERRIDE="${empty_state}" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
            bash -c 'source "$1"; launcher_require_current_schema' _ "${ROOT_DIR}/easy_all" 2>&1
    ) && fail "空版本值必须被拒绝（launcher gate: ${empty_line}）"
    assert_contains "空版本值走旧 schema 提示（launcher gate）" "${empty_launcher_gate}" "旧版（schema 缺失）"
    assert_not_contains "空版本值不误报缺行（launcher gate）" "${empty_launcher_gate}" "缺少 STATE_VERSION"

    empty_load_dir="${damaged_dir}/load-empty-${empty_index}"
    mkdir -p "${empty_load_dir}"
    cp "${empty_state}" "${empty_load_dir}/state.env"
    empty_load=$(
        RUNTIME_TMP="${damaged_dir}/runtime-empty-${empty_index}" \
        EASY_ALL_STATE_DIR_OVERRIDE="${empty_load_dir}" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${damaged_dir}/load-empty-subs-${empty_index}" \
            bash -c 'source "$1/profiles/anytls.sh"; load_state' _ "${ROOT_DIR}" 2>&1
    ) && fail "空版本值必须被拒绝（load_state: ${empty_line}）"
    assert_contains "空版本值走旧 schema 提示（load_state）" "${empty_load}" "旧版（schema 缺失）"
    assert_not_contains "空版本值不误报缺行（load_state）" "${empty_load}" "缺少 STATE_VERSION"

    empty_bootstrap=$(
        EASY_ALL_STATE_FILE_OVERRIDE="${empty_state}" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
            bash -c "${bootstrap_gate_script}" 2>&1
    ) && fail "空版本值必须被拒绝（bootstrap: ${empty_line}）"
    assert_contains "空版本值走旧 schema 提示（bootstrap）" "${empty_bootstrap}" "旧版（schema 缺失）"
    assert_not_contains "空版本值不误报缺行（bootstrap）" "${empty_bootstrap}" "缺少 STATE_VERSION"
done

# 控制组：版本行存在但为 0 仍是旧 schema 提示；协议已删除仍给旧协议提示。
{ printf 'STATE_VERSION=0\n'; cat "${damaged_state}"; } >"${damaged_dir}/state-v0.env"
schema_zero=$(
    EASY_ALL_STATE_FILE_OVERRIDE="${damaged_dir}/state-v0.env" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
        bash -c 'source "$1"; detect_installed_mode' _ "${ROOT_DIR}/easy_all" 2>&1
) && fail "schema 0 必须被拒绝"
assert_contains "schema 0 仍是旧 schema 提示" "${schema_zero}" "旧版（schema 0）"
assert_not_contains "schema 0 不误报缺版本" "${schema_zero}" "缺少 STATE_VERSION"
{
    printf 'STATE_VERSION=1\nPROTOCOL=reality\n'
} >"${damaged_dir}/state-reality.env"
reality_state=$(
    EASY_ALL_STATE_FILE_OVERRIDE="${damaged_dir}/state-reality.env" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/no-marker" \
        bash -c 'source "$1"; detect_installed_mode' _ "${ROOT_DIR}/easy_all" 2>&1
) && fail "已删除协议必须被拒绝"
assert_contains "已删除协议提示" "${reality_state}" "已删除的旧协议"

printf 'ok - 状态 schema 门禁测试通过\n'
