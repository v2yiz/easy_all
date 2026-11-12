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
for protocol in anytls cloudfront cloudflare combined-cloudfront combined-cloudflare; do
    state_protocol_valid "${protocol}" || fail "协议应受支持：${protocol}"
done
for legacy in reality cdn combined ""; do
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
grep -Fxq AWS_ACM_CERTIFICATE_ARN <<<"${fields}" || fail "模式 4 需要 ACM ARN"
grep -Fxq CDN_TRAFFIC_PROTECTION_GB <<<"${fields}" || fail "模式 4 需要 985GB 字段"
assert_absent "${fields}" DIRECT_DOMAIN "模式 4 不得要求直连域名"
assert_absent "${fields}" REALITY_TARGET "模式 4 不得保留 Reality 字段"
grep -Fxq CLOUDFLARE_ORIGIN_CERT_ID <<<"$(state_required_fields cloudflare deploy)" \
    || fail "模式 2 需要 Origin CA 字段"
assert_absent "$(state_required_fields cloudflare deploy)" ORIGIN_HEADER_SECRET \
    "模式 2 不得要求源站头密钥"
fields=$(state_required_fields combined-cloudfront deploy)
grep -Fxq DIRECT_DOMAIN <<<"${fields}" || fail "模式 5 需要直连域名"
grep -Fxq VLESS_PATH <<<"${fields}" || fail "模式 5 需要 VLESS 路径"

fields=$(state_required_fields combined-cloudflare deploy)
grep -Fxq DIRECT_DOMAIN <<<"${fields}" || fail "模式 3 需要直连域名"
grep -Fxq ANYTLS_PASSWORD <<<"${fields}" || fail "模式 3 需要 AnyTLS 密码"
grep -Fxq CF_NODE_DOMAIN <<<"${fields}" || fail "模式 3 需要 CDN 节点域名"
grep -Fxq VLESS_PATH <<<"${fields}" || fail "模式 3 需要 VLESS 路径"
grep -Fxq CLOUDFLARE_ORIGIN_RULE_ID <<<"${fields}" || fail "模式 3 需要 Origin Rule"
assert_absent "${fields}" SUBSCRIPTION_DOMAIN "模式 3 的订阅域名由节点域名派生，不应落盘"
assert_absent "${fields}" CLOUDFLARE_ORIGIN_CERT_ID "模式 3 不使用 Origin CA"
assert_absent "${fields}" ORIGIN_HEADER_SECRET "模式 3 不要求源站头密钥"

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

# --- 安装菜单编号：1 AnyTLS / 2 纯 CloudFlare / 3 AnyTLS+CloudFlare / 4 纯 CloudFront / 5 AnyTLS+CloudFront
# 编号只影响交互菜单与文档，落盘状态用 PROTOCOL 字符串；这里锁住菜单文案顺序与选择映射。
install_menu_body=$(awk '/^choose_install_mode\(\) \{/,/^\}/' "${ROOT_DIR}/easy_all")
[[ -n "${install_menu_body}" ]] || fail "easy_all 缺少 choose_install_mode"
while IFS=$'\t' read -r menu_number menu_text menu_profile; do
    assert_contains "菜单 ${menu_number} 文案" "${install_menu_body}" "${menu_number}. ${menu_text}"
    assert_contains "菜单 ${menu_number} 映射" "${install_menu_body}" "${menu_number}) printf '${menu_profile}\\n'"
done <<'MENU'
1	AnyTLS 直连	anytls
2	纯 CloudFlare	cloudflare
3	AnyTLS + CloudFlare	combined-cloudflare
4	纯 CloudFront	cloudfront
5	AnyTLS + CloudFront	combined-cloudfront
MENU
[[ $(printf '%s\n' "${install_menu_body}" | grep -n "  2\. 纯 CloudFlare" | cut -d: -f1) \
    -lt $(printf '%s\n' "${install_menu_body}" | grep -n "  4\. 纯 CloudFront" | cut -d: -f1) ]] \
    || fail "菜单编号顺序错误：2 应为纯 CloudFlare、4 应为纯 CloudFront"

# --- A6/A23：state.env 纯赋值语法门（load_state 会 source 该文件）-----------------
# 判据＝printf %q 的五形态：① KEY= ② KEY='' ③ KEY="" ⑤ KEY=$'…' ⑥ 裸串+反斜杠转义。
source "${ROOT_DIR}/lib/log.sh"
gate_dir="${TMP_DIR}/gate"
mkdir -p "${gate_dir}"
gate_status() { # $1=文件 → 0（通过）/1（拒绝）
    local status=0
    state_validate_pure_assignments "$1" >/dev/null 2>&1 || status=1
    printf '%s' "${status}"
}
expect_gate() { # $1=标签 $2=期望(0/1) $3=文件内容
    local label=$1 expected=$2 content=$3 file="${gate_dir}/case.env" actual
    # 白名单要求能从 PROTOCOL 派生字段集：统一补合法头，payload 只验形态。
    printf 'STATE_VERSION=1\nPROTOCOL=anytls\n%s' "${content}" >"${file}"
    actual=$(gate_status "${file}")
    [[ "${actual}" == "${expected}" ]] || fail "语法门 ${label}：期望 ${expected}，实际 ${actual}"
}

# 合法形态：全部来自 printf %q 的真实产出（+ 设计允许的两个空值形态）。
expect_gate "① 裸空" 0 "TCP_ACCELERATION=
"
expect_gate "② %q 空值" 0 "$(printf 'TCP_ACCELERATION=%q\n' '')"
expect_gate "③ 空双引号" 0 'TCP_ACCELERATION=""'$'\n'
expect_gate "两个空值字段共存" 0 "$(printf 'TCP_ACCELERATION=%q\nCF_ZONE=""\n' '')"
expect_gate "⑤ 制表符（ANSI-C）" 0 "$(printf 'TCP_ACCELERATION=%q\n' $'a\tb')"
expect_gate "⑥ 含空格" 0 "$(printf 'TCP_ACCELERATION=%q\n' 'a b')"
expect_gate "⑥ 含单引号" 0 "$(printf 'TCP_ACCELERATION=%q\n' "a'b")"
expect_gate "⑥ 含反斜杠" 0 "$(printf 'TCP_ACCELERATION=%q\n' 'a\b')"
expect_gate "⑥ JSON 对象" 0 "$(printf 'TCP_ACCELERATION=%q\n' '{"k":"v"}')"

# 对抗形态：全部必须拒绝（形态④ KEY='abc' 已由设计删除，无生产者）。
expect_gate "④ KEY='abc' 必须拒绝" 1 "TCP_ACCELERATION='abc'"$'\n'
expect_gate "④ 多段拼接注入必须拒绝" 1 "TCP_ACCELERATION='a'\$(touch ${TMP_DIR}/pwned-concat)'cd'"$'\n'
expect_gate "命令替换必须拒绝" 1 "TCP_ACCELERATION=\$(touch ${TMP_DIR}/pwned-subst)"$'\n'
expect_gate "反引号必须拒绝" 1 'TCP_ACCELERATION=`touch '"${TMP_DIR}"'/pwned-tick`'$'\n'
expect_gate "分号必须拒绝" 1 'TCP_ACCELERATION=a;b'$'\n'
expect_gate "管道必须拒绝" 1 'TCP_ACCELERATION=a|b'$'\n'
expect_gate "非空双引号含 \$ 必须拒绝" 1 'TCP_ACCELERATION="a$b"'$'\n'
expect_gate "行尾孤立反斜杠必须拒绝（否则拼接下一行）" 1 'TCP_ACCELERATION=a\'$'\n'
expect_gate "空白值必须拒绝" 1 'TCP_ACCELERATION= a'$'\n'

# 拒绝不等于执行：上面所有 payload 都没有被 source，标记文件不得出现。
for marker in pwned-concat pwned-subst pwned-tick; do
    [[ ! -e "${TMP_DIR}/${marker}" ]] || fail "语法门泄漏执行：${marker} 被创建"
done

# 门必须在 load_state 的 source 之前调用：顺序反了等于门没生效。
load_state_body=$(awk '/^load_state\(\) \{/,/^\}/' "${ROOT_DIR}/lib/runtime-core.sh")
gate_line=$(printf '%s\n' "${load_state_body}" | grep -n 'state_validate_pure_assignments' | cut -d: -f1)
source_line=$(printf '%s\n' "${load_state_body}" | grep -n 'source "${STATE_FILE}"' | cut -d: -f1)
[[ -n "${gate_line}" && -n "${source_line}" ]] || fail "load_state 缺少语法门或 source STATE_FILE"
(( gate_line < source_line )) || fail "语法门必须早于 source STATE_FILE"

# --- A23：%q 读回只还原 \' 与 \\，不得擅自解码 C 控制字符转义 --------------------
a23_state="${gate_dir}/a23-state.env"
printf 'QUOTE=%q\nBACKSLASH=%q\nTAB=%q\n' "a'b" 'a\b' $'a\tb' >"${a23_state}"
a23_quote=$(state_file_value "${a23_state}" QUOTE)
a23_backslash=$(state_file_value "${a23_state}" BACKSLASH)
a23_tab=$(state_file_value "${a23_state}" TAB)
[[ "${a23_quote}" == "a'b" ]] || fail "A23: 单引号形态应读回 a'b，实际 <${a23_quote}>"
[[ "${a23_backslash}" == 'a\b' ]] || fail "A23: 反斜杠形态应读回 a\b，实际 <${a23_backslash}>"
[[ "${a23_tab}" == 'a\tb' ]] \
    || fail "A23: 控制字符转义应保持字面 a\tb（不得解码成真实 TAB），实际 <${a23_tab}>"

# --- 增量 1：键名白名单（阻止 PATH= / IFS= 这类键被 source 进加载方 shell）------------
build_state_env() { # $1=protocol $2=目标文件；用生产同一套 state_render 生成完整状态
    local protocol=$1 file=$2 field
    local -a fields=()
    while IFS= read -r field; do
        fields+=("${field}")
    done < <(state_required_fields "${protocol}" deploy)
    STATE_VERSION=${EASY_ALL_STATE_SCHEMA_VERSION}
    PROTOCOL=${protocol}
    SUBSCRIPTION_MODE=deploy
    for field in "${fields[@]}"; do
        # PROTOCOL / SUBSCRIPTION_MODE 已按参数设好，不能被通用填充值覆盖（否则协议变无效）。
        case "${field}" in
        PROTOCOL | SUBSCRIPTION_MODE) continue ;;
        esac
        printf -v "${field}" 'value-%s' "${field}"
    done
    state_render "${file}" "${fields[@]}"
}

# 在子 shell 里模拟 load_state 的关键顺序：门 → （通过才）source，并回显 PATH 是否被改。
gate_run_case() { # $1=state.env 路径；输出 GATE_RC 与 PATH_AFTER
    (
        source "${ROOT_DIR}/lib/log.sh"
        source "${ROOT_DIR}/lib/state.sh"
        rc=0
        state_validate_pure_assignments "$1" 2>/dev/null || rc=$?
        if ((rc == 0)); then
            # shellcheck source=/dev/null
            source "$1"
        fi
        printf 'GATE_RC=%s\nPATH_AFTER=%s\n' "${rc}" "${PATH}"
    ) 2>/dev/null
}

# 1) 合法完整状态：必须通过。
legal_state="${gate_dir}/whitelist-legal.env"
build_state_env anytls "${legal_state}"
legal_out=$(gate_run_case "${legal_state}")
[[ "$(sed -n 's/^GATE_RC=//p' <<<"${legal_out}")" == "0" ]] \
    || fail "白名单不得误杀合法状态：${legal_out}"

# 2) 追加 PATH=/tmp/evil：必须拒绝，且 PATH 未被改变（证明 source 根本没执行）。
evil_state="${gate_dir}/whitelist-evil.env"
cp "${legal_state}" "${evil_state}"
printf 'PATH=/tmp/evil-path\n' >>"${evil_state}"
evil_out=$(gate_run_case "${evil_state}")
[[ "$(sed -n 's/^GATE_RC=//p' <<<"${evil_out}")" != "0" ]] \
    || fail "含 PATH= 的状态必须被白名单拒绝：${evil_out}"
[[ "$(sed -n 's/^PATH_AFTER=//p' <<<"${evil_out}")" != "/tmp/evil-path" ]] \
    || fail "PATH 被注入的状态不得被 source：${evil_out}"

# 3) IFS 同理（影响加载方分词行为，是最容易漏的一类）。
ifs_state="${gate_dir}/whitelist-ifs.env"
cp "${legal_state}" "${ifs_state}"
printf 'IFS=,\n' >>"${ifs_state}"
ifs_out=$(gate_run_case "${ifs_state}")
[[ "$(sed -n 's/^GATE_RC=//p' <<<"${ifs_out}")" != "0" ]] \
    || fail "含 IFS= 的状态必须被白名单拒绝：${ifs_out}"

# 4) PROTOCOL 无效：白名单算不出来 → 门**硬拒**（不再退化放行），报错点名文件与原因。
bad_proto_state="${gate_dir}/whitelist-badproto.env"
build_state_env anytls "${bad_proto_state}"
sed -i '' 's/^PROTOCOL=.*/PROTOCOL=reality/' "${bad_proto_state}" 2>/dev/null \
    || sed -i 's/^PROTOCOL=.*/PROTOCOL=reality/' "${bad_proto_state}"
bad_out=$(gate_run_case "${bad_proto_state}")
[[ "$(sed -n 's/^GATE_RC=//p' <<<"${bad_out}")" != "0" ]] \
    || fail "协议无效时门必须硬拒（不得退化放行）：${bad_out}"
bad_msg=$(state_validate_pure_assignments "${bad_proto_state}" 2>&1 || true)
assert_contains "协议无效时硬拒并说明原因" "${bad_msg}" "无法确定 schema 字段集"
assert_contains "硬拒消息点名状态文件" "${bad_msg}" "${bad_proto_state}"

# 5) 白名单不得误杀存量：五个协议的完整状态都要通过。
for whitelist_proto in anytls cloudfront cloudflare combined-cloudfront combined-cloudflare; do
    whitelist_state="${gate_dir}/whitelist-${whitelist_proto}.env"
    build_state_env "${whitelist_proto}" "${whitelist_state}"
    whitelist_out=$(gate_run_case "${whitelist_state}")
    [[ "$(sed -n 's/^GATE_RC=//p' <<<"${whitelist_out}")" == "0" ]] \
        || fail "白名单误杀合法状态（${whitelist_proto}）：${whitelist_out}"
done

printf 'ok - 安装菜单编号测试通过\n'
