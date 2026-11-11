#!/usr/bin/env bash
# 阶段 2 修复轮 A：Cloudflare 凭据持久化、strict 校验顺序、DNS 归属常量与证书实际生效。
# 外部边界（Cloudflare API、systemctl、服务动作）用可编程替身；TLS 握手用真实 openssl。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_cloud_safety.XXXXXX")
fi
cleanup_test() {
    [[ -z "${TLS_SERVER_PID:-}" ]] || kill "${TLS_SERVER_PID}" 2>/dev/null || true
    rm -rf -- "${TMP_DIR}"
}
trap cleanup_test EXIT

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
assert_file_mode() {
    local label=$1 expected=$2 file=$3 actual
    actual=$(ls -ld -- "${file}" | awk '{print $1}' | sed 's/[^drwx-]//g')
    [[ "${actual}" == "${expected}" ]] \
        || fail "${label}: expected mode ${expected} but got ${actual}"
}

for syntax_file in "${ROOT_DIR}"/lib/*.sh "${ROOT_DIR}"/profiles/*.sh; do
    bash -n "${syntax_file}" || fail "语法校验失败：${syntax_file}"
done

TOKEN="abcdefghijklmnopqrstuvwxyz0123456789"

# --- 1. Cloudflare Token：共享的 0600 原子保存与读取 ---------------------------
# 修复前模式 1 的加载链没有 persist_cloudflare_token，安装必然 command not found。
for profile in anytls cloudfront cloudflare combined; do
    token_path=$(EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/token-${profile}" \
        bash -c '
            source "$1/profiles/$2.sh"
            declare -F persist_cloudflare_token >/dev/null || exit 3
            declare -F cloudflare_collect_api_token >/dev/null || exit 4
            cloudflare_token_file
        ' _ "${ROOT_DIR}" "${profile}" 2>&1) \
        || fail "${profile} 加载链缺少共享 Token 函数：${token_path}"
    assert_equal "${profile} 的 Token 路径在状态目录" \
        "${TMP_DIR}/token-${profile}/cloudflare.token" "${token_path}"
done
for lib in cloudfront-mode.sh cloudflare-mode.sh anytls-mode.sh; do
    assert_not_contains "${lib} 不再保留重复的 Token 实现" \
        "$(<"${ROOT_DIR}/lib/${lib}")" "persist_cloudflare_token() {"
done

token_dir="${TMP_DIR}/token-state"
persist_output=$(
    EASY_ALL_STATE_DIR_OVERRIDE="${token_dir}" \
        bash -c '
            source "$1/profiles/cloudfront.sh"
            CLOUDFLARE_API_TOKEN=$2
            persist_cloudflare_token
            printf "%s\n" "$(cloudflare_token_file)"
        ' _ "${ROOT_DIR}" "${TOKEN}" 2>&1
) || fail "首次保存 Token 失败：${persist_output}"
assert_equal "保存路径" "${token_dir}/cloudflare.token" "${persist_output}"
[[ -f "${token_dir}/cloudflare.token" ]] || fail "Token 文件必须存在"
assert_file_mode "Token 文件权限 0600" "-rw-------" "${token_dir}/cloudflare.token"
assert_equal "Token 内容" "${TOKEN}" "$(<"${token_dir}/cloudflare.token")"
[[ ! -e "${token_dir}/state.env" ]] || fail "Token 不得写入 state.env"

read_back=$(
    EASY_ALL_STATE_DIR_OVERRIDE="${token_dir}" bash -c '
        source "$1/profiles/anytls.sh"
        unset CLOUDFLARE_API_TOKEN
        cloudflare_collect_api_token
        printf "%s\n" "${CLOUDFLARE_API_TOKEN}"
    ' _ "${ROOT_DIR}" 2>&1
) || fail "下一进程读取已保存 Token 失败：${read_back}"
assert_equal "下一进程复用已保存的 Token" "${TOKEN}" "${read_back}"

# 失败不得泄露或覆盖：格式无效时拒绝落盘，原文件保持原值。
invalid_output=$(
    EASY_ALL_STATE_DIR_OVERRIDE="${token_dir}" bash -c '
        source "$1/profiles/cloudflare.sh"
        CLOUDFLARE_API_TOKEN="too-short"
        persist_cloudflare_token
    ' _ "${ROOT_DIR}" 2>&1
) && fail "格式无效的 Token 必须拒绝落盘"
assert_not_contains "失败信息不回显 Token 值" "${invalid_output}" "too-short"
assert_equal "失败的保存不覆盖已保存 Token" "${TOKEN}" "$(<"${token_dir}/cloudflare.token")"

# --- 2. strict 校验顺序：先只读查 Zone ID，再在任何资源创建前判定 ----------------
run_strict_case() { # $1=ssl 值或 403 $2=profile 名 $3=订阅模式
    local ssl=$1 profile=$2 subscription_mode=${3:-deploy}
    local log="${TMP_DIR}/strict-${profile}-${ssl//\//_}.log"
    local script="${TMP_DIR}/strict-${profile}-${ssl//\//_}.sh"
    local runtime="${TMP_DIR}/strict-runtime-${profile}-${ssl//\//_}"
    local state="${TMP_DIR}/strict-state-${profile}-${ssl//\//_}"
    local status=0
    mkdir -p "${runtime}" "${state}"
    # 独立进程执行：strict 失败必须靠 errexit 中止阶段，shell 函数里的 || 会关掉它。
    cat >"${script}" <<STRICT
set -Eeuo pipefail
export RUNTIME_TMP=$(printf '%q' "${runtime}")
export EASY_ALL_STATE_DIR_OVERRIDE=$(printf '%q' "${state}")
export EASY_ALL_CERT_DIR_OVERRIDE=$(printf '%q' "${state}/certs")
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE=$(printf '%q' "${state}/subscriptions")
source $(printf '%q' "${ROOT_DIR}/profiles/${profile}.sh")
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUBSCRIPTION_MODE=$(printf '%q' "${subscription_mode}")
SUBSCRIPTION_DOMAIN=sub.example.com
DIRECT_DOMAIN=node.example.com
CF_NODE_DOMAIN=cf.example.com
CLOUDFLARE_API_TOKEN=$(printf '%q' "${TOKEN}")
cloudflare_api_request() {
    printf '%s %s\n' "\$1" "\$2" >>$(printf '%q' "${log}")
    case "\$1 \$2" in
    "GET /zones?name=example.com&status=active&per_page=50")
        printf '[{"name":"example.com","id":"zoneid"}]\n' ;;
    "GET /zones/zoneid/settings/ssl")
        [[ $(printf '%q' "${ssl}") == "403" ]] && return 1
        printf '{"value":"%s"}\n' $(printf '%q' "${ssl}") ;;
    *) return 1 ;;
    esac
}
persist_cloudflare_token() { :; }
dns_ensure_record() { printf 'DNS %s\n' "\$1" >>$(printf '%q' "${log}"); }
certbot_write_cloudflare_credentials() { :; }
cdn_issue_certificate() { printf 'CERT\n' >>$(printf '%q' "${log}"); }
anytls_ensure_origin_rule() { printf 'RULE\n' >>$(printf '%q' "${log}"); }
apply_cloud_phase
STRICT
    bash "${script}" >/dev/null 2>&1 || status=$?
    printf 'STATUS=%s\n' "${status}" >>"${log}"
    cat "${log}"
}

for ssl in strict full flexible off 403; do
    log=$(run_strict_case "${ssl}" cloudflare)
    assert_contains "模式 2 ${ssl}：先只读查询 Zone ID" "${log}" \
        "GET /zones?name=example.com&status=active&per_page=50"
    zone_line=$(grep -n 'GET /zones?name=' <<<"${log}" | head -n 1 | cut -d: -f1)
    ssl_line=$(grep -n 'settings/ssl' <<<"${log}" | head -n 1 | cut -d: -f1)
    [[ -n "${zone_line}" && -n "${ssl_line}" ]] \
        || fail "模式 2 ${ssl}：必须同时查询 Zone ID 与 SSL 设置"
    ((zone_line < ssl_line)) || fail "模式 2 ${ssl}：Zone ID 查询必须早于 SSL 设置查询"
    if [[ "${ssl}" == "strict" ]]; then
        assert_contains "模式 2 strict：继续创建 DNS" "${log}" "DNS cf.example.com"
        assert_contains "模式 2 strict：执行到证书签发" "${log}" "CERT"
        assert_contains "模式 2 strict：成功结束" "${log}" "STATUS=0"
    else
        assert_not_contains "模式 2 ${ssl}：不创建 DNS" "${log}" "DNS "
        assert_not_contains "模式 2 ${ssl}：不签发证书" "${log}" "CERT"
        assert_not_contains "模式 2 ${ssl}：非零退出" "${log}" "STATUS=0"
    fi
    assert_not_contains "模式 2 ${ssl}：没有写请求" "${log}" "POST "
    assert_not_contains "模式 2 ${ssl}：没有删除请求" "${log}" "DELETE "
done

for ssl in strict full; do
    log=$(run_strict_case "${ssl}" anytls deploy)
    assert_contains "模式 1 ${ssl}：先只读查询 Zone ID" "${log}" \
        "GET /zones?name=example.com&status=active&per_page=50"
    if [[ "${ssl}" == "strict" ]]; then
        assert_contains "模式 1 strict：继续创建直连 DNS" "${log}" "DNS node.example.com"
        assert_contains "模式 1 strict：继续创建订阅 DNS" "${log}" "DNS sub.example.com"
        assert_contains "模式 1 strict：执行到 Origin Rule" "${log}" "RULE"
        assert_contains "模式 1 strict：成功结束" "${log}" "STATUS=0"
    else
        assert_not_contains "模式 1 ${ssl}：不创建 DNS" "${log}" "DNS "
        assert_not_contains "模式 1 ${ssl}：非零退出" "${log}" "STATUS=0"
    fi
done

# 模式 1 link：不调用 Zone Settings 接口（design §9）。
link_runtime="${TMP_DIR}/link-runtime"
link_state="${TMP_DIR}/link-state"
mkdir -p "${link_runtime}" "${link_state}"
link_log=$(
    RUNTIME_TMP="${link_runtime}" EASY_ALL_STATE_DIR_OVERRIDE="${link_state}" \
        EASY_ALL_CERT_DIR_OVERRIDE="${link_state}/certs" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${link_state}/subscriptions" \
        bash -c '
            source "$1/profiles/anytls.sh"
            mkdir -p "${RUNTIME_TMP}"
            CF_ZONE=example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            DIRECT_DOMAIN=node.example.com
            SUBSCRIPTION_MODE=link
            CLOUDFLARE_API_TOKEN=$2
            cloudflare_api_request() {
                # 日志必须走 stderr：stdout 是 API 的 JSON 响应。
                printf "%s %s\n" "$1" "$2" >&2
                case "$1 $2" in
                "GET /zones?name=example.com&status=active&per_page=50")
                    printf "[{\"name\":\"example.com\",\"id\":\"zoneid\"}]\n" ;;
                *) return 1 ;;
                esac
            }
            persist_cloudflare_token() { :; }
            dns_ensure_record() { printf "DNS %s\n" "$1"; }
            certbot_write_cloudflare_credentials() { :; }
            cdn_issue_certificate() { printf "CERT\n"; }
            apply_cloud_phase
        ' _ "${ROOT_DIR}" "${TOKEN}" 2>&1
) || fail "模式 1 link 的云同步失败：${link_log}"
assert_not_contains "模式 1 link 不查询 Zone SSL 设置" "${link_log}" "settings/ssl"
assert_contains "模式 1 link 仍配置直连 DNS" "${link_log}" "DNS node.example.com"
assert_not_contains "模式 1 link 不创建订阅 DNS" "${link_log}" "DNS sub.example.com"

# --- 3. 模式 2 的 DNS 归属常量：创建、复用与 purge 使用同一契约 -----------------
run_dns_case() { # $1=create|reuse|purge|purge-takeover|foreign
    local case_name=$1
    local log="${TMP_DIR}/dns-${case_name}.log"
    local runtime="${TMP_DIR}/dns-runtime-${case_name}"
    local state="${TMP_DIR}/dns-state-${case_name}"
    local audit="${TMP_DIR}/dns-${case_name}-takeover.log"
    mkdir -p "${runtime}" "${state}"
    rm -f "${audit}"
    (
        set -Eeuo pipefail
        export RUNTIME_TMP="${runtime}"
        export EASY_ALL_STATE_DIR_OVERRIDE="${state}"
        export EASY_ALL_CERT_DIR_OVERRIDE="${state}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state}/subscriptions"
        export EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${audit}"
        source "${ROOT_DIR}/profiles/cloudflare.sh"
        CLOUDFLARE_ZONE_ID=zoneid
        VPS_PUBLIC_IPV4=203.0.113.10
        CF_NODE_DOMAIN=cf.example.com
        SUBSCRIPTION_MODE=deploy
        existing_record='[{"id":"rec1","type":"A","name":"cf.example.com","content":"203.0.113.10","proxied":true,"comment":"easy_all cloudflare","ttl":300}]'
        cloudflare_api_request() {
            local method=$1 path=$2 payload=${3:-}
            printf '%s %s %s\n' "${method}" "${path}" "${payload}" >>"${log}"
            case "${method} ${path}" in
            "GET "*dns_records*)
                case "${case_name}" in
                create) printf '[]\n' ;;
                foreign)
                    printf '%s\n' "$(printf '%s' "${existing_record}" \
                        | sed 's/easy_all cloudflare/easy_all/')" ;;
                *) printf '%s\n' "${existing_record}" ;;
                esac
                ;;
            *) printf 'null\n' ;;
            esac
        }
        # 接管过的记录：安装时已把第三方注释改成本模式注释，只有接管日志能证明原归属。
        if [[ "${case_name}" == "purge-takeover" ]]; then
            printf '{"ts":"2025-01-01T00:00:00Z","host":"cf.example.com","old_comment":"foreign","old_content":"198.51.100.20","old_proxied":"false","old_ttl":"300"}\n' >"${audit}"
        fi
        case "${case_name}" in
        purge | purge-takeover) cdn_purge_cloudflare_dns ;;
        *) dns_ensure_record cf.example.com A "${VPS_PUBLIC_IPV4}" true ;;
        esac
    ) </dev/null >"${log}.out" 2>"${log}.err" || true
    cat "${log}"
}

create_log=$(run_dns_case create)
assert_contains "模式 2 创建记录使用模式专属注释" "${create_log}" "easy_all cloudflare"
assert_contains "模式 2 创建记录是 POST" "${create_log}" "POST /zones/zoneid/dns_records"

reuse_log=$(run_dns_case reuse)
assert_not_contains "模式 2 复用受管记录不写入" "${reuse_log}" "POST "
assert_not_contains "模式 2 复用受管记录不改写" "${reuse_log}" "PATCH "

purge_log=$(run_dns_case purge)
assert_contains "模式 2 purge 删除受管记录" "${purge_log}" \
    "DELETE /zones/zoneid/dns_records/rec1"
assert_not_contains "模式 2 purge 不修改记录" "${purge_log}" "PATCH "

purge_takeover_log=$(run_dns_case purge-takeover)
assert_not_contains "强制接管的记录在 purge 时不得删除" "${purge_takeover_log}" "DELETE "
assert_contains "强制接管的记录在 purge 时说明保留原因" \
    "$(cat "${TMP_DIR}/dns-purge-takeover.log.out" 2>/dev/null || true)" "来自强制接管"

foreign_log=$(run_dns_case foreign)
assert_not_contains "第三方注释的记录不被接管" "${foreign_log}" "POST "
assert_not_contains "第三方注释的记录不被改写" "${foreign_log}" "PATCH "
assert_not_contains "第三方注释的记录不被删除" "${foreign_log}" "DELETE "

run_dns_case_input() { # $1=y|n  $2=id|replaced|updated|ttl|spaced|empty|patchfail（重读时返回的变体）
    local input_char=$1 reread_mode=$2
    local log="${TMP_DIR}/dns-in-${input_char}-${reread_mode}.log"
    local out="${TMP_DIR}/dns-in-${input_char}-${reread_mode}.out"
    local runtime="${TMP_DIR}/dns-in-runtime-${input_char}-${reread_mode}"
    local state="${TMP_DIR}/dns-in-state-${input_char}-${reread_mode}"
    local audit="${TMP_DIR}/dns-in-audit-${input_char}-${reread_mode}.log"
    local first_marker="${TMP_DIR}/dns-in-first-${input_char}-${reread_mode}.marker"
    mkdir -p "${runtime}" "${state}"
    rm -f "${first_marker}" "${audit}"
    (
        set -Eeuo pipefail
        export RUNTIME_TMP="${runtime}"
        export EASY_ALL_STATE_DIR_OVERRIDE="${state}"
        export EASY_ALL_CERT_DIR_OVERRIDE="${state}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state}/subscriptions"
        export EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${audit}"
        source "${ROOT_DIR}/profiles/cloudflare.sh"
        CLOUDFLARE_ZONE_ID=zoneid
        VPS_PUBLIC_IPV4=203.0.113.10
        CF_NODE_DOMAIN=cf.example.com
        SUBSCRIPTION_MODE=deploy
        # 函数注入：模拟交互终端与用户输入；不依赖 pty，也不引入环境变量旁路。
        STUB_ANSWER="${input_char}"
        dns_takeover_interactive() { return 0; }
        read_confirmation() {
            local label=$1 variable=$2 input="${STUB_ANSWER}"
            input="${input#"${input%%[![:space:]]*}"}"
            input="${input%"${input##*[![:space:]]}"}"
            printf 'PROMPT:%s\n' "${label:-}"
            printf -v "${variable}" '%s' "${input}"
        }
        cloudflare_api_request() {
            local method=$1 path=$2 payload=${3:-}
            printf '%s %s %s\n' "${method}" "${path}" "${payload}" >>"${log}"
            case "${method} ${path}" in
            "GET "*dns_records*)
                local comment=foreign stable=0
                case "${reread_mode}" in
                spaced) comment="my work vps" ;;
                empty) comment="" ;;
                esac
                case "${reread_mode}" in
                id | spaced | empty | patchfail) stable=1 ;;
                esac
                # 计数不能放在子 shell 变量里（每次 GET 自带命令替换子 shell）：用标记文件区分首次/重读。
                if ((stable == 1)) || [[ ! -f "${first_marker}" ]]; then
                    : >"${first_marker}"
                    printf '[{"id":"rec1","type":"A","name":"cf.example.com","content":"203.0.113.10","proxied":true,"comment":"%s","ttl":300}]\n' "${comment}"
                elif [[ "${reread_mode}" == "updated" ]]; then
                    # 同 id、同 comment，但确认期间目标与代理被改。
                    printf '[{"id":"rec1","type":"A","name":"cf.example.com","content":"198.51.100.20","proxied":false,"comment":"foreign","ttl":300}]\n'
                elif [[ "${reread_mode}" == "ttl" ]]; then
                    # 同 id、同指向，但确认期间 TTL 被改。
                    printf '[{"id":"rec1","type":"A","name":"cf.example.com","content":"203.0.113.10","proxied":true,"comment":"foreign","ttl":60}]\n'
                else
                    printf '[{"id":"rec2","type":"A","name":"cf.example.com","content":"203.0.113.10","proxied":true,"comment":"foreign","ttl":300}]\n'
                fi
                ;;
            "PATCH "*)
                # 模拟 PATCH 已到达云端但响应丢失：进程在这里直接退出（真实调用会 die）。
                [[ "${reread_mode}" != "patchfail" ]] || exit 9
                printf 'null\n'
                ;;
            *) printf 'null\n' ;;
            esac
        }
        dns_ensure_record cf.example.com A "${VPS_PUBLIC_IPV4}" true
    ) </dev/null >"${out}" 2>&1 || true
    printf 'CALLS=%s\n' "$(tr '\n' '|' <"${log}")"
    printf 'OUT=%s\n' "$(tr '\n' '|' <"${out}")"
    if [[ -s "${audit}" ]]; then
        printf 'AUDIT_EXISTS=yes AUDIT=%s\n' "$(tr '\n' '|' <"${audit}")"
    else
        printf 'AUDIT_EXISTS=no\n'
    fi
}

takeover_case=$(run_dns_case_input y id)
assert_contains "确认接管时改写记录" "${takeover_case}" "PATCH /zones/zoneid/dns_records/rec1"
assert_contains "接管写入完整记录载荷（含 ttl 与模式专属注释）" "${takeover_case}" \
    'PATCH /zones/zoneid/dns_records/rec1 {"type":"A","name":"cf.example.com","content":"203.0.113.10","ttl":1,"proxied":true,"comment":"easy_all cloudflare"}'
assert_contains "提示展示将被覆盖的现有指向" "${takeover_case}" "当前指向：203.0.113.10"
assert_contains "接管改写前写入审计日志" "${takeover_case}" "AUDIT_EXISTS=yes"
assert_contains "审计日志记录原注释与原指向" "${takeover_case}" \
    '"old_comment":"foreign","old_content":"203.0.113.10","old_proxied":"true","old_ttl":"300"'

reject_case=$(run_dns_case_input n id)
assert_not_contains "拒绝接管时不改写记录" "${reject_case}" "PATCH "
assert_contains "拒绝接管时不写审计日志" "${reject_case}" "AUDIT_EXISTS=no"

yes_case=$(run_dns_case_input yes id)
assert_contains "输入 yes 同样确认接管" "${yes_case}" "PATCH /zones/zoneid/dns_records/rec1"

space_y_case=$(run_dns_case_input " y" id)
assert_contains "输入前导空格 y 同样确认接管" "${space_y_case}" "PATCH /zones/zoneid/dns_records/rec1"

race_case=$(run_dns_case_input y replaced)
assert_not_contains "确认期间记录被替换时不得改写" "${race_case}" "PATCH "
assert_contains "确认期间记录被替换时明确报错" "${race_case}" "确认期间被修改或被替换"
assert_contains "确认期间记录被替换时不写审计日志" "${race_case}" "AUDIT_EXISTS=no"

updated_case=$(run_dns_case_input y updated)
assert_not_contains "确认期间同 id 记录被改内容时不得改写" "${updated_case}" "PATCH "
assert_contains "确认期间同 id 记录被改内容时明确报错" "${updated_case}" "确认期间被修改或被替换"

ttl_case=$(run_dns_case_input y ttl)
assert_not_contains "确认期间 TTL 被改时不得改写" "${ttl_case}" "PATCH "
assert_contains "确认期间 TTL 被改时明确报错" "${ttl_case}" "确认期间被修改或被替换"

spaced_case=$(run_dns_case_input y spaced)
assert_contains "含空格的注释在审计日志中整体转义" "${spaced_case}" \
    '"old_comment":"my work vps","old_content":'

empty_case=$(run_dns_case_input y empty)
assert_contains "空注释在审计日志中落为空串" "${empty_case}" '"old_comment":"","old_content":'

patchfail_case=$(run_dns_case_input y patchfail)
assert_contains "PATCH 结果未知时审计日志已先落盘" "${patchfail_case}" "AUDIT_EXISTS=yes"
assert_contains "PATCH 结果未知前已记录原注释" "${patchfail_case}" '"old_comment":"foreign"'

# 非交互（没有终端）：直接拒绝并说明原因，不提示、不改写。
noninteractive_err=$(cat "${TMP_DIR}/dns-foreign.log.err")
assert_contains "非交互拒绝时说明原因" "${noninteractive_err}" "非交互"
assert_not_contains "非交互时不提示接管" "${noninteractive_err}" "是否强制接管"

# --- 3b. 模式 5：直连域名可与源站域名复用 -------------------------------------
# 依据：docs/preparation-guide.md §域名清单：直连域名可与源站域名复用（填同一个名字时
# 两个入口共用一个灰云 A 记录，端口不同、证书互不影响，部署只需 2 个名字）。
# 因此本段是两个方向的正向契约：等于源站域名必须放行，等于节点/订阅域名必须拒绝。
run_install_domain_case() { # $1=DIRECT_DOMAIN
    RUNTIME_TMP="${TMP_DIR}/domains-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/domains-state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/domains-state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/domains-subscriptions" \
        bash -c '
            source "$1/profiles/combined.sh"
            CF_ZONE=example.com
            CF_ORIGIN_DOMAIN=origin.example.com
            CF_NODE_DOMAIN=cf.example.com
            SUBSCRIPTION_DOMAIN=cf.example.com
            DIRECT_DOMAIN=$2
            cdn_validate_install_domains
        ' _ "${ROOT_DIR}" "$1" 2>&1
}

run_install_domain_case "direct.example.com" >/dev/null \
    || fail "安装期直连域名与源站域名不同时必须通过"
# 反向回归：曾把「直连域名 == 源站域名」判为缺陷并 die，会让文档给的 2 名字部署安装失败。
run_install_domain_case "origin.example.com" >/dev/null \
    || fail "安装期直连域名等于源站域名时必须通过（文档允许与源站域名复用）"
install_domain_output=$(run_install_domain_case "cf.example.com") \
    && fail "安装期直连域名等于节点域名时必须拒绝"
assert_contains "安装期直连域名不得等于节点或订阅域名" "${install_domain_output}" \
    "直连域名不得等于节点或订阅域名"

write_combined_state() { # $1=DIRECT_DOMAIN $2=输出文件
    cat >"$2" <<STATE
STATE_VERSION=1
PROTOCOL=combined-cloudfront
TCP_ACCELERATION=off
VPS_PUBLIC_IPV4=203.0.113.10
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
SUB_DOWNLOAD_NAME=EASY_ALL
OWNER_TOKEN=token-abcdefgh
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
MIHOMO_TEMPLATE_SNAPSHOT=1
SCHEDULED_REBOOT_ENABLED=0
SCHEDULED_REBOOT_HOUR=4
DIRECT_DOMAIN=$1
DIRECT_NODE_NAME=US-direct
ANYTLS_PASSWORD=0123456789abcdefaaaabbbb
CF_NODE_DOMAIN=cf.example.com
CF_NODE_PREFIX=CF
VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
VLESS_PATH=/vless-0123456789ab
SUBSCRIPTION_DOMAIN=cf.example.com
CF_ORIGIN_DOMAIN=origin.example.com
ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
CDN_TRAFFIC_PROTECTION_GB=985
STATE
}

run_state_domain_case() { # $1=DIRECT_DOMAIN
    local state_dir="${TMP_DIR}/combined-state-${1//./_}"
    mkdir -p "${state_dir}"
    write_combined_state "$1" "${state_dir}/state.env"
    RUNTIME_TMP="${state_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${state_dir}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${state_dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state_dir}/subscriptions" \
        bash -c 'source "$1/profiles/combined.sh"; load_state' _ "${ROOT_DIR}" 2>&1
}

run_state_domain_case "direct.example.com" >/dev/null \
    || fail "状态中直连域名与源站域名不同时必须通过"
# 状态期与安装期同口径：复用源站域名的已装状态必须能被 load_state 正常加载。
run_state_domain_case "origin.example.com" >/dev/null \
    || fail "状态中直连域名等于源站域名时必须通过（文档允许与源站域名复用）"

# --- 3b-2. 模式 4/5 安装输入提示面：域名输入收敛为每条链路两个名字 -----------------
# 模式 5 不再询问源站域名（固定复用直连域名）、模式 4/5 不再询问订阅域名（固定复用节点域名）。
# 输入由共享核心派生，这里直接观察用户可见的提示文案与派生结果。
run_inputs_case() { # $1=profile（combined|cloudfront） $2=resume（可选：模拟跨版本续装并预设旧身份域名）
    local prompts="${TMP_DIR}/inputs-prompts-$1${2:+-$2}.log"
    : >"${prompts}"
    RUNTIME_TMP="${TMP_DIR}/inputs-runtime-$1${2:+-$2}" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/inputs-state-$1${2:+-$2}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/inputs-state-$1${2:+-$2}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/inputs-subscriptions-$1${2:+-$2}" \
    INPUTS_PROMPTS="${prompts}" \
        bash -c '
            source "$1/profiles/$2.sh"
            # 交互面：记录提示文案，返回值一律取默认值（Zone 预置，故默认非空）。
            prompt_value() { printf "%s\n" "$1" >>"${INPUTS_PROMPTS}"; printf "%s" "${2:-}"; }
            prompt_secret() { printf "%s" "0123456789abcdef0123456789abcdef"; }
            cloudflare_collect_api_token() { :; }
            CF_ZONE=example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            VLESS_UUID=11111111-2222-4333-8444-555555555555
            if [[ -n "${3:-}" ]]; then
                # 模拟旧版中断安装的续装身份：当年源站/订阅域名是独立填写的。
                INSTALL_RESUME=1
                DIRECT_DOMAIN=node.example.com
                CF_ORIGIN_DOMAIN=origin.example.com
                SUBSCRIPTION_DOMAIN=sub.example.com
            fi
            collect_install_inputs
            printf "ORIGIN=%s\nNODE=%s\nSUB=%s\nDIRECT=%s\nVLESS_CDN=%s\nHOSTS=%s\n" \
                "${CF_ORIGIN_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" \
                "${DIRECT_DOMAIN:-}" "${VLESS_CDN_DOMAIN:-}" \
                "$(printf "%s\n" "$(certificate_required_hosts)" | wc -l | tr -d " ")"
        ' _ "${ROOT_DIR}" "$1" "${2:-}" 2>&1
}

combined_inputs=$(run_inputs_case combined) || fail "模式 5 安装输入收集失败：${combined_inputs}"
combined_prompts=$(cat "${TMP_DIR}/inputs-prompts-combined.log")
assert_contains "模式 5 仍询问直连节点域名" "${combined_prompts}" "直连节点域名"
assert_contains "模式 5 仍询问 CloudFront 节点域名" "${combined_prompts}" "CloudFront 节点域名"
assert_not_contains "模式 5 不再询问源站域名" "${combined_prompts}" "源站域名"
assert_not_contains "模式 5 不再询问订阅域名" "${combined_prompts}" "订阅域名"
assert_equal "模式 5 域名提示恰为两条" "2" "$(printf '%s\n' "${combined_prompts}" | grep -c '域名')"
assert_contains "模式 5 源站域名复用直连域名" "${combined_inputs}" "ORIGIN=node.example.com"
assert_contains "模式 5 直连域名用默认值" "${combined_inputs}" "DIRECT=node.example.com"
assert_contains "模式 5 节点域名用默认值" "${combined_inputs}" "NODE=cf.example.com"
assert_contains "模式 5 订阅域名复用节点域名" "${combined_inputs}" "SUB=cf.example.com"
assert_contains "模式 5 CDN 域名派生为节点域名" "${combined_inputs}" "VLESS_CDN=cf.example.com"
assert_contains "模式 5 证书只需一个域名" "${combined_inputs}" "HOSTS=1"

cloudfront_inputs=$(run_inputs_case cloudfront) || fail "模式 4 安装输入收集失败：${cloudfront_inputs}"
cloudfront_prompts=$(cat "${TMP_DIR}/inputs-prompts-cloudfront.log")
assert_contains "模式 4 仍询问源站域名" "${cloudfront_prompts}" "源站域名"
assert_contains "模式 4 仍询问 CloudFront 节点域名" "${cloudfront_prompts}" "CloudFront 节点域名"
assert_not_contains "模式 4 不再询问订阅域名" "${cloudfront_prompts}" "订阅域名"
assert_equal "模式 4 域名提示恰为两条" "2" "$(printf '%s\n' "${cloudfront_prompts}" | grep -c '域名')"
assert_contains "模式 4 源站域名用默认值" "${cloudfront_inputs}" "ORIGIN=origin.example.com"
assert_contains "模式 4 节点域名用默认值" "${cloudfront_inputs}" "NODE=cf.example.com"
assert_contains "模式 4 订阅域名复用节点域名" "${cloudfront_inputs}" "SUB=cf.example.com"
assert_equal "模式 4 没有直连域名" "DIRECT=" \
    "$(printf '%s\n' "${cloudfront_inputs}" | grep '^DIRECT=')"

# 跨版本续装：旧版身份里源站/订阅域名可能是独立填写的，续装不得改写已建资源用的域名。
resume_inputs=$(run_inputs_case combined resume) || fail "模式 5 续装输入收集失败：${resume_inputs}"
resume_prompts=$(cat "${TMP_DIR}/inputs-prompts-combined-resume.log")
assert_contains "续装仍询问直连节点域名" "${resume_prompts}" "直连节点域名"
assert_contains "续装仍询问 CloudFront 节点域名" "${resume_prompts}" "CloudFront 节点域名"
assert_not_contains "续装不再询问源站域名" "${resume_prompts}" "源站域名"
assert_not_contains "续装不再询问订阅域名" "${resume_prompts}" "订阅域名"
assert_equal "续装域名提示恰为两条" "2" "$(printf '%s\n' "${resume_prompts}" | grep -c '域名')"
assert_contains "续装沿用旧身份的源站域名" "${resume_inputs}" "ORIGIN=origin.example.com"
assert_contains "续装沿用旧身份的订阅域名" "${resume_inputs}" "SUB=sub.example.com"

# 模式 4 续装同理：源站域名照旧提问，订阅域名沿用旧身份里的独立值。
resume_cf_inputs=$(run_inputs_case cloudfront resume) || fail "模式 4 续装输入收集失败：${resume_cf_inputs}"
resume_cf_prompts=$(cat "${TMP_DIR}/inputs-prompts-cloudfront-resume.log")
assert_contains "模式 4 续装仍询问源站域名" "${resume_cf_prompts}" "源站域名"
assert_not_contains "模式 4 续装不再询问订阅域名" "${resume_cf_prompts}" "订阅域名"
assert_equal "模式 4 续装域名提示恰为两条" "2" "$(printf '%s\n' "${resume_cf_prompts}" | grep -c '域名')"
assert_contains "模式 4 续装沿用旧身份的订阅域名" "${resume_cf_inputs}" "SUB=sub.example.com"

# --- 3c. 模式 3：直连 + 橙云节点/订阅（回源 8443）------------------------------
write_combined_cf_state() { # $1=DIRECT_DOMAIN $2=CF_NODE_DOMAIN $3=SUBSCRIPTION_MODE $4=输出
    cat >"$4" <<STATE
STATE_VERSION=1
PROTOCOL=combined-cloudflare
TCP_ACCELERATION=off
VPS_PUBLIC_IPV4=203.0.113.10
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=$3
SUB_DOWNLOAD_NAME=EASY_ALL
OWNER_TOKEN=token-abcdefgh
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
MIHOMO_TEMPLATE_SNAPSHOT=1
SCHEDULED_REBOOT_ENABLED=0
SCHEDULED_REBOOT_HOUR=4
DIRECT_DOMAIN=$1
DIRECT_NODE_NAME=US-direct
ANYTLS_PASSWORD=0123456789abcdefaaaabbbb
CF_NODE_DOMAIN=$2
CF_NODE_PREFIX=CF
VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
VLESS_PATH=/vless-0123456789ab
CLOUDFLARE_ORIGIN_RULESET_ID=rs1
CLOUDFLARE_ORIGIN_RULE_ID=rule1
STATE
}

run_combined_cf_state_case() { # $1=DIRECT_DOMAIN $2=CF_NODE_DOMAIN $3=SUBSCRIPTION_MODE
    local state_dir
    state_dir="${TMP_DIR}/combined-cf-state-${1//./_}-${2//./_}-${3}"
    mkdir -p "${state_dir}"
    write_combined_cf_state "$1" "$2" "$3" "${state_dir}/state.env"
    RUNTIME_TMP="${state_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${state_dir}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${state_dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state_dir}/subscriptions" \
        bash -c 'source "$1/profiles/combined-cloudflare.sh"; load_state; \
            printf "PUBLIC=%s CFONLY=%s SITE=%s\n" "$(runtime_public_tcp_ports)" \
                "$(runtime_cloudflare_only_port)" "$(runtime_caddy_site_enabled && echo 1 || echo 0)"' \
        _ "${ROOT_DIR}" 2>&1
}

combined_cf_state=$(run_combined_cf_state_case direct.example.com cf.example.com deploy) \
    || fail "模式 3 完整状态必须能加载"
assert_contains "模式 3 仅公网 443" "${combined_cf_state}" "PUBLIC=443"
assert_contains "模式 3 回源 8443 只对 Cloudflare" "${combined_cf_state}" "CFONLY=8443"
assert_contains "模式 3 始终部署 Caddy 站点" "${combined_cf_state}" "SITE=1"
combined_cf_same_domain=$(run_combined_cf_state_case cf.example.com cf.example.com deploy) \
    && fail "模式 3 节点域名等于直连域名时必须拒绝"
assert_contains "模式 3 节点域名不得等于直连域名" "${combined_cf_same_domain}" \
    "节点域名不得等于直连域名"
run_combined_cf_state_case direct.example.com other.example.net deploy >/dev/null \
    && fail "模式 3 节点域名不属于 Zone 时必须拒绝"
run_combined_cf_state_case direct.example.com cf.example.com link >/dev/null \
    && fail "模式 3 固定 deploy，link 状态必须拒绝"

# 证书覆盖直连与橙云节点两个名字（模式 3 不使用 Origin CA，回源与直连共用 LE 证书）。
combined_cf_cert_hosts=$(
    RUNTIME_TMP="${TMP_DIR}/combined-cf-cert-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/combined-cf-cert-state" \
        bash -c '
            source "$1/profiles/combined-cloudflare.sh"
            PROTOCOL=combined-cloudflare
            DIRECT_DOMAIN=direct.example.com
            CF_NODE_DOMAIN=cf.example.com
            certificate_required_hosts
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 3 证书域名调用失败"
assert_equal "模式 3 证书覆盖直连与节点域名" \
    $'cf.example.com\ndirect.example.com' "${combined_cf_cert_hosts}"

# --- 4. 证书：强制重载，并以本机真实 TLS 握手确认磁盘证书已生效 ----------------
first_dir="${TMP_DIR}/certs-first"
second_dir="${TMP_DIR}/certs-second"
mkdir -p "${first_dir}" "${second_dir}"
make_cert() { # $1=输出目录 $2=CN
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=$2" \
        -keyout "$1/private.key" -out "$1/fullchain.pem" >/dev/null 2>&1 \
        || fail "无法生成测试证书 ${2}"
}
make_cert "${first_dir}" first.example.com
make_cert "${second_dir}" second.example.com

# --- 4b. 证书/私钥配对：无法解析的占位内容必须判为不配对 -----------------------
# 修复前两边都走 `openssl ... | sha256sum`：两侧命令同时失败时得到同一个空输入哈希，
# 损坏的证书与私钥会被误判为“配对”。
key_match() { # $1=证书 $2=私钥
    RUNTIME_TMP="${TMP_DIR}/keymatch-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/keymatch-state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/keymatch-certs" \
        bash -c 'source "$1/profiles/anytls.sh"; certificate_key_matches "$2" "$3"' \
        _ "${ROOT_DIR}" "$1" "$2" 2>&1
}

# 真实 openssl 现场生成的匹配 EC 私钥 + 自签证书必须判为配对。
ec_dir="${TMP_DIR}/keymatch-ec"
mkdir -p "${ec_dir}"
openssl ecparam -name prime256v1 -genkey -noout -out "${ec_dir}/private.key" 2>/dev/null \
    || openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 \
        -out "${ec_dir}/private.key" 2>/dev/null \
    || fail "无法生成测试用 EC 私钥"
openssl req -x509 -new -key "${ec_dir}/private.key" -days 2 \
    -subj "/CN=origin.example.com" -out "${ec_dir}/fullchain.pem" 2>/dev/null \
    || fail "无法生成测试用 EC 自签证书"
key_match "${ec_dir}/fullchain.pem" "${ec_dir}/private.key" >/dev/null 2>&1 \
    || fail "匹配的 EC 私钥与自签证书必须判为配对"
key_match "${first_dir}/fullchain.pem" "${second_dir}/private.key" >/dev/null 2>&1 \
    && fail "不匹配的证书与私钥必须判为不配对"

placeholder_dir="${TMP_DIR}/keymatch-placeholder"
mkdir -p "${placeholder_dir}"
printf '%s\n' 'placeholder certificate content' >"${placeholder_dir}/fullchain.pem"
printf '%s\n' 'placeholder private key content' >"${placeholder_dir}/private.key"
key_match "${placeholder_dir}/fullchain.pem" "${placeholder_dir}/private.key" \
    >/dev/null 2>&1 \
    && fail "无法解析的占位证书与私钥必须判为不配对（不得比较空输入哈希）"
key_match "${placeholder_dir}/fullchain.pem" "${ec_dir}/private.key" >/dev/null 2>&1 \
    && fail "无法解析的证书必须判为不配对"
key_match "${ec_dir}/fullchain.pem" "${placeholder_dir}/private.key" >/dev/null 2>&1 \
    && fail "无法解析的私钥必须判为不配对"

# 两处实现同一口径：比较公钥 PEM，不得回退到哈希比较。
for key_fn in certificate_key_matches cloudflare_origin_certificate_is_current; do
    key_fn_body=$(bash -c 'source "$1/profiles/anytls.sh"; declare -f "$2"' \
        _ "${ROOT_DIR}" "${key_fn}")
    assert_contains "${key_fn} 比较证书公钥 PEM" "${key_fn_body}" '-pubkey -noout'
    assert_contains "${key_fn} 比较私钥公钥 PEM" "${key_fn_body}" '-pubout'
    assert_not_contains "${key_fn} 不得比空输入哈希（sha256sum）" \
        "${key_fn_body}" 'sha256sum'
    assert_not_contains "${key_fn} 不得比空输入哈希（dgst）" "${key_fn_body}" 'dgst'
done

fingerprint() { # $1=证书文件 -> 小写 sha256 指纹
    openssl x509 -in "$1" -noout -fingerprint -sha256 \
        | sed 's/^.*=//' | tr '[:upper:]' '[:lower:]'
}

# 后台进程放在子 shell 里启动：主 shell 不持有作业，结束时不打印 "Terminated" 噪音。
spawn_background() { # 其余参数为命令；成功时向 stdout 输出 PID
    local pid_file
    pid_file=$(mktemp "${TMP_DIR}/pid.XXXXXX") || return 1
    ( "$@" >/dev/null 2>&1 & printf '%s' "$!" >"${pid_file}" )
    cat "${pid_file}"
    rm -f -- "${pid_file}"
}

# 端口不写死：并行测试或残留进程占用固定端口时，测试会在启动 TLS 服务处卡死。
# 有界探测：宿主 openssl 能否在握手后自行返回（无 GNU timeout 的宿主同样适用）。
tls_probe() { # $1=端口；0 表示可以
    (
        local pid watchdog status=0
        openssl s_client -connect "127.0.0.1:$1" -servername node.example.com \
            </dev/null >/dev/null 2>&1 &
        pid=$!
        ( sleep 10; kill -TERM "${pid}" 2>/dev/null || true ) &
        watchdog=$!
        wait "${pid}" || status=$?
        kill -TERM "${watchdog}" 2>/dev/null || true
        wait "${watchdog}" 2>/dev/null || true
        exit "${status}"
    ) 2>/dev/null
}

run_tls_certificate_cases() {
    TLS_PORT=""
    start_tls_server() { # $1=证书目录；成功后设置 TLS_PORT 与 TLS_SERVER_PID
        local attempt port
        for attempt in 1 2 3 4 5 6 7 8 9 10; do
            port=$((20000 + RANDOM % 20000))
            TLS_SERVER_PID=$(spawn_background openssl s_server -accept "${port}" \
                -cert "$1/fullchain.pem" -key "$1/private.key" -quiet) \
                || fail "无法启动测试用 TLS 服务"
            sleep 1
            # 能建立 TCP 连接才能证明监听成功；失败说明端口被占用，换下一个候选。
            if (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
                TLS_PORT=${port}
                return 0
            fi
            kill "${TLS_SERVER_PID}" 2>/dev/null || true
            TLS_SERVER_PID=""
        done
        return 1
    }
    # 起不了 TLS 服务是宿主环境问题，不是产品缺陷：跳过而不是把套件判成回归。
    if ! start_tls_server "${first_dir}"; then
        printf 'skip - 无法在空闲端口启动测试用 TLS 服务；跳过 TLS 握手与证书部署断言\n' >&2
        return 0
    fi
    # LibreSSL（macOS 自带）的 s_client 在 stdin EOF 后不会退出，握手用例在这些宿主上
    # 无法完成：有界探测一次，不可用就明确跳过，避免把整个套件卡死。
    if ! tls_probe "${TLS_PORT}"; then
        printf 'skip - 本机 openssl 在握手后不返回（LibreSSL）；跳过 TLS 握手与证书部署断言\n' >&2
        return 0
    fi

    handshake_output=$(
        RUNTIME_TMP="${TMP_DIR}/cert-runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cert-state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${first_dir}" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/cert-subscriptions" \
            bash -c '
                source "$1/profiles/anytls.sh"
                DIRECT_DOMAIN=node.example.com
                runtime_tls_peer_fingerprint 127.0.0.1 "$2" || exit 4
            ' _ "${ROOT_DIR}" "${TLS_PORT}" 2>&1
    ) || fail "本机 TLS 握手读取证书指纹失败：${handshake_output}"
    assert_equal "握手返回的指纹与磁盘证书一致" "$(fingerprint "${first_dir}/fullchain.pem")" \
        "${handshake_output}"

    serve_check=$(
        RUNTIME_TMP="${TMP_DIR}/cert-runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cert-state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${first_dir}" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/cert-subscriptions" \
            bash -c '
                local_port=$2
                source "$1/profiles/anytls.sh"
                DIRECT_DOMAIN=node.example.com
                # 只验证指纹比较逻辑本身：端点由测试直接给出。
                runtime_served_certificate_endpoints() { printf "127.0.0.1 %s\n" "${local_port}"; }
                runtime_served_certificate_matches_disk || exit 5
                exit 0
            ' _ "${ROOT_DIR}" "${TLS_PORT}" 2>&1
    ) || fail "磁盘证书与服务证书一致时必须通过：${serve_check}"

    serve_mismatch=$(
        RUNTIME_TMP="${TMP_DIR}/cert-runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cert-state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${second_dir}" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/cert-subscriptions" \
            bash -c '
                local_port=$2
                source "$1/profiles/anytls.sh"
                DIRECT_DOMAIN=node.example.com
                runtime_served_certificate_endpoints() { printf "127.0.0.1 %s\n" "${local_port}"; }
                if runtime_served_certificate_matches_disk; then exit 6; fi
                exit 0
            ' _ "${ROOT_DIR}" "${TLS_PORT}" 2>&1
    ) || fail "服务仍用旧证书时必须判定不一致：${serve_mismatch}"

    # 强制重载：证书仅替换文件，Caddy 会跳过相同配置加载。
    reload_output=$(
        RUNTIME_TMP="${TMP_DIR}/reload-runtime" \
        CADDY_ADMIN_SOCKET="${TMP_DIR}/reload-runtime/admin.sock" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/reload-state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${first_dir}" \
            bash -c '
                mkdir -p "${RUNTIME_TMP}"
                source "$1/profiles/anytls.sh"
                CADDY_BIN="${RUNTIME_TMP}/fake-caddy"
                systemctl() { [[ "$1" == "is-active" ]]; }
                printf "#!/usr/bin/env bash\nprintf \"%%s\\\\n\" \"\$*\"\n" >"${CADDY_BIN}"
                chmod 0755 "${CADDY_BIN}"
                reload_caddy 1
                reload_caddy
            ' _ "${ROOT_DIR}" 2>&1
    ) || fail "重载 Caddy 失败：${reload_output}"
    assert_contains "证书部署路径强制重载" "${reload_output}" "--force"
    assert_contains "普通重载不带 --force" "${reload_output}" \
        "reload --address unix/${TMP_DIR}/reload-runtime/admin.sock"

    # 证书部署事务：强制重载 + 握手校验；校验失败恢复旧副本。
    deploy_case() { # $1=1 表示握手校验失败
        local handshake_fail=$1
        EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${TMP_DIR}/lineage" \
        RUNTIME_TMP="${TMP_DIR}/deploy-runtime-${handshake_fail}" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/deploy-state-${handshake_fail}" \
        EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/deploy-certs-${handshake_fail}" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/deploy-subscriptions" \
            bash -c '
                handshake_target=$4
                source "$1/profiles/anytls.sh"
                PROTOCOL=anytls
                DIRECT_DOMAIN=node.example.com
                SUBSCRIPTION_MODE=link
                install -d -m 0700 "${CERT_DIR}" "${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}" "${RUNTIME_TMP}"
                install -m 0644 "$2/fullchain.pem" "${CERT_FILE}"
                install -m 0600 "$2/private.key" "${KEY_FILE}"
                install -m 0644 "$3/fullchain.pem" "${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}/fullchain.pem"
                install -m 0600 "$3/private.key" "${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}/privkey.pem"
                certificate_check() { return 0; }
                certificate_verify() { return 0; }
                runtime_apply_runtime_services() { printf "APPLY %s\n" "$1"; }
                runtime_served_certificate_matches_disk() { [[ "${handshake_target}" == "0" ]]; }
                status=0
                certificate_deploy "" 1 || status=$?
                printf "STATUS=%s\n" "${status}"
                printf "SERVED=%s\n" "$(cat "${CERT_FILE}")"
            ' _ "${ROOT_DIR}" "${first_dir}" "${second_dir}" "${handshake_fail}" 2>&1
    }
    deploy_ok=$(deploy_case 0) || fail "证书部署成功路径失败：${deploy_ok}"
    assert_contains "部署成功时强制重载" "${deploy_ok}" "APPLY 1"
    assert_contains "部署成功时状态为 0" "${deploy_ok}" "STATUS=0"
    assert_contains "部署成功后磁盘是新证书" "${deploy_ok}" "$(<"${second_dir}/fullchain.pem")"

    deploy_fail=$(deploy_case 1) || true
    assert_contains "握手校验失败时部署失败" "${deploy_fail}" "STATUS=1"
    assert_contains "握手校验失败后恢复旧证书" "${deploy_fail}" "$(<"${first_dir}/fullchain.pem")"
    force_applies=$(grep -c 'APPLY 1' <<<"${deploy_fail}" || true)
    assert_equal "旧证书恢复也走强制重载" "2" "${force_applies}"
}

# --- 5. 服务编排：单元重新加载与核心替换后的重启 ---------------------------
# systemctl 与 Caddy 二进制是外部边界，用替身记录调用序列；断言对外可观察的服务动作。
orchestration_case() { # $1=额外参数（空表示只重载配置）
    local extra_arg=${1:-}
    SYSTEMCTL_LOG="${TMP_DIR}/systemctl-${extra_arg:-reload}.log"
    CADDY_CALL_LOG="${TMP_DIR}/caddy-call-${extra_arg:-reload}.log"
    SYSTEMCTL_SNAPSHOT="${TMP_DIR}/caddy-unit-at-reload-${extra_arg:-reload}.unit"
    : >"${SYSTEMCTL_LOG}"
    : >"${CADDY_CALL_LOG}"
    : >"${SYSTEMCTL_SNAPSHOT}"
    SYSTEMCTL_LOG="${SYSTEMCTL_LOG}" CADDY_CALL_LOG="${CADDY_CALL_LOG}" \
    SYSTEMCTL_SNAPSHOT="${SYSTEMCTL_SNAPSHOT}" \
    RUNTIME_TMP="${TMP_DIR}/orch-runtime-${extra_arg:-reload}" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/orch-state-${extra_arg:-reload}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${first_dir}" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/orch-subscriptions" \
    SINGBOX_BIN="${TMP_DIR}/orch-singbox/sing-box" \
    SINGBOX_CONFIG="${TMP_DIR}/orch-singbox/config.json" \
    SINGBOX_SERVICE_FILE="${TMP_DIR}/orch-systemd/easy_all-singbox.service" \
    CADDY_BIN="${TMP_DIR}/orch-caddy/caddy" \
    CADDY_CONFIG="${TMP_DIR}/orch-caddy/Caddyfile" \
    CADDY_SERVICE_FILE="${TMP_DIR}/orch-systemd/easy_all-caddy.service" \
    CADDY_ADMIN_SOCKET="${TMP_DIR}/orch-run/admin.sock" \
    bash -c '
        source "$1/profiles/anytls.sh"
        PROTOCOL=anytls
        SUBSCRIPTION_MODE=deploy
        SUBSCRIPTION_DOMAIN=sub.example.com
        DIRECT_DOMAIN=node.example.com
        systemctl() {
            printf "%s\n" "$*" >>"${SYSTEMCTL_LOG}"
            # daemon-reload 时把 Caddy 单元当前内容留档：用来证明单元写入先于重读。
            [[ "$1" != "daemon-reload" ]] || cat "${CADDY_SERVICE_FILE}" >"${SYSTEMCTL_SNAPSHOT}"
            return 0
        }
        install -d -m 0755 "${CADDY_BIN%/*}" "${SINGBOX_BIN%/*}" "${CADDY_SERVICE_FILE%/*}"
        printf "# stale unit\\n" >"${CADDY_SERVICE_FILE}"
        cat >"${CADDY_BIN}" <<CADDY_STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${CADDY_CALL_LOG}"
CADDY_STUB
        chmod 0755 "${CADDY_BIN}"
        runtime_apply_runtime_services 1 $2
    ' _ "${ROOT_DIR}" "${extra_arg}" >/dev/null 2>&1 \
        || fail "服务编排调用失败（参数=${extra_arg:-空}）"
}

orchestration_case
systemd_calls=$(<"${SYSTEMCTL_LOG}")
assert_contains "发布单元后重新加载 systemd" "${systemd_calls}" "daemon-reload"
daemon_reload_line=$(grep -n 'daemon-reload' "${SYSTEMCTL_LOG}" | cut -d: -f1 || true)
singbox_restart_line=$(grep -n 'restart easy_all-singbox.service' "${SYSTEMCTL_LOG}" \
    | cut -d: -f1 || true)
[[ -n "${daemon_reload_line}" && -n "${singbox_restart_line}" \
    && ${daemon_reload_line} -lt ${singbox_restart_line} ]] \
    || fail "daemon-reload 必须先于服务启停发生"
assert_contains "配置变更只重载 Caddy" "$(<"${CADDY_CALL_LOG}")" "reload --address"
# 单元写入必须早于 daemon-reload：否则 systemd 继续用内存里的旧单元。
assert_contains "Caddy 单元在 daemon-reload 时已是新内容" "$(<"${SYSTEMCTL_SNAPSHOT}")" \
    "ExecStart=${TMP_DIR}/orch-caddy/caddy run --config"
assert_not_contains "配置变更不重启 Caddy" "${systemd_calls}" "restart easy_all-caddy.service"

orchestration_case 1
assert_contains "核心替换后重启 Caddy 进程" "$(<"${SYSTEMCTL_LOG}")" \
    "restart easy_all-caddy.service"
assert_equal "核心替换后不再热重载配置" "" "$(<"${CADDY_CALL_LOG}")"

# --- 5b. Caddy 冷启动：失败时只发一次启动请求 -------------------------------
# 单元 StartLimitBurst=3/120s：enable --now 失败后再 start 会一次故障消耗两次配额。
caddy_cold_dir="${TMP_DIR}/caddy-cold-start"
mkdir -p "${caddy_cold_dir}/state" "${caddy_cold_dir}/subs" "${caddy_cold_dir}/runtime"
: >"${caddy_cold_dir}/systemctl.log"
caddy_cold_output=$(
    SYSTEMCTL_LOG="${caddy_cold_dir}/systemctl.log" \
    RUNTIME_TMP="${caddy_cold_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${caddy_cold_dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${caddy_cold_dir}/subs" \
        bash -c '
            source "$1/profiles/anytls.sh"
            PROTOCOL=anytls
            SUBSCRIPTION_MODE=deploy
            SUBSCRIPTION_DOMAIN=sub.example.com
            DIRECT_DOMAIN=node.example.com
            install_singbox_service() { :; }
            install_caddy_service() { :; }
            runtime_caddy_site_enabled() { return 0; }
            systemctl() {
                printf "%s\n" "$*" >>"${SYSTEMCTL_LOG}"
                case "$1" in
                is-active) return 1 ;;
                enable)
                    [[ "${2:-}" == "--now" ]] && return 1
                    return 0
                    ;;
                start) return 1 ;;
                esac
                return 0
            }
            status=0
            ( runtime_apply_runtime_services ) || status=$?
            printf "STATUS=%s\n" "${status}"
        ' _ "${ROOT_DIR}" 2>&1
) || true
caddy_cold_calls=$(<"${caddy_cold_dir}/systemctl.log")
assert_contains "Caddy 冷启动失败必须报错退出" "${caddy_cold_output}" "STATUS=1"
assert_contains "Caddy 冷启动先 enable 单元" "${caddy_cold_calls}" "enable easy_all-caddy.service"
assert_not_contains "Caddy 冷启动不再用 enable --now" "${caddy_cold_calls}" \
    "enable --now easy_all-caddy.service"
assert_equal "Caddy 冷启动只发一次启动请求" "1" \
    "$(grep -Ec '^(enable --now|start) easy_all-caddy\.service$' "${caddy_cold_dir}/systemctl.log" || true)"

# --- 5c. 证书域名去重：同一域名只给 certbot 一个 -d --------------------------
certificate_hosts_case() { # $1=DIRECT_DOMAIN $2=CF_ORIGIN_DOMAIN
    RUNTIME_TMP="${TMP_DIR}/cert-hosts-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cert-hosts-state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/cert-hosts-subs" \
        bash -c '
            source "$1/profiles/combined.sh"
            PROTOCOL=combined-cloudfront
            DIRECT_DOMAIN=$2
            CF_ORIGIN_DOMAIN=$3
            certificate_required_hosts
        ' _ "${ROOT_DIR}" "$1" "$2" 2>&1
}
reused_hosts=$(certificate_hosts_case origin.example.com origin.example.com) \
    || fail "证书域名复用场景调用失败"
assert_equal "模式 5 复用同一域名时只输出一行" "origin.example.com" "${reused_hosts}"
distinct_hosts=$(certificate_hosts_case direct.example.com origin.example.com) \
    || fail "证书域名不同场景调用失败"
assert_equal "模式 5 不同域名仍输出两行" \
    $'direct.example.com\norigin.example.com' "${distinct_hosts}"
anytls_link_hosts=$(
    RUNTIME_TMP="${TMP_DIR}/cert-hosts-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cert-hosts-state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/cert-hosts-subs" \
        bash -c '
            source "$1/profiles/anytls.sh"
            PROTOCOL=anytls
            SUBSCRIPTION_MODE=link
            DIRECT_DOMAIN=node.example.com
            status=0
            certificate_required_hosts || status=$?
            printf "STATUS=%s\n" "${status}"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 1 link 的证书域名调用失败"
assert_contains "模式 1 link 仍输出直连域名" "${anytls_link_hosts}" "node.example.com"
assert_contains "模式 1 link 无订阅时返回值仍为 0" "${anytls_link_hosts}" "STATUS=0"

# --- 6. 源站守卫公网探测：必须打 Caddy 站点端口（模式 5 是 8443，不是 sing-box 的 443） ---
# curl 是外部边界，用替身记录被请求的 URL；连接被丢弃的情况统一返回 000。
origin_guard_case() { # $1=profile 名
    local profile=$1
    local stub_dir="${TMP_DIR}/curl-stub-${profile}"
    local url_log="${TMP_DIR}/origin-guard-${profile}.log"
    mkdir -p "${stub_dir}"
    : >"${url_log}"
    cat >"${stub_dir}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
last=""
for arg in "$@"; do last=${arg}; done
printf '%s\n' "${last}" >>"${ORIGIN_GUARD_LOG}"
printf '000'
FAKE_CURL
    chmod 0755 "${stub_dir}/curl"
    PATH="${stub_dir}:${PATH}" ORIGIN_GUARD_LOG="${url_log}" \
    RUNTIME_TMP="${TMP_DIR}/guard-runtime-${profile}" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/guard-state-${profile}" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/guard-subscriptions" \
        bash -c '
            source "$1/profiles/$2.sh"
            CF_ORIGIN_DOMAIN=origin.example.com
            VLESS_PATH=/vless-0123456789ab
            cdn_public_origin_header_guard_ok || exit 9
        ' _ "${ROOT_DIR}" "${profile}" >/dev/null 2>&1 \
        || fail "源站守卫探测失败（${profile}）"
    printf '%s' "${url_log}"
}
mode4_urls=$(<"$(origin_guard_case combined)")
assert_contains "模式 5 探测 Caddy 8443" "${mode4_urls}" "https://origin.example.com:8443/vless-0123456789ab"
assert_not_contains "模式 5 不把探测发到 443" "${mode4_urls}" "https://origin.example.com/vless"
mode2_urls=$(<"$(origin_guard_case cloudfront)")
assert_contains "模式 4 探测 Caddy 443" "${mode2_urls}" "https://origin.example.com:443/vless-0123456789ab"

# --- 7. update-core：核心缺失时按“重装修复”处理，并在替换二进制后重启 Caddy ---
# 该入口要求 root，且下载核心、systemd 与 iptables 计量都是本机外部能力：这里只替身这些
# 边界（root 门禁、下载、systemctl、flock、计量检查），备份/回滚/发布顺序保持真实。
update_core_case() { # $1=预置核心（none|singbox） $2=候选验收是否失败（0/1）
    local preset=$1 validate_fail=$2
    local case_dir="${TMP_DIR}/update-core-${preset}-${validate_fail}"
    mkdir -p "${case_dir}/state" "${case_dir}/core" "${case_dir}/bin" "${case_dir}/systemd"
    printf '#!/usr/bin/env bash\nexit 0\n' >"${case_dir}/bin/flock"
    chmod 0700 "${case_dir}/bin/flock"
    if [[ "${preset}" == "singbox" ]]; then
        printf '#!/bin/sh\nexit 0\n' >"${case_dir}/core/sing-box"
        chmod 0755 "${case_dir}/core/sing-box"
    fi
    cat >"${case_dir}/state/state.env" <<'STATE'
STATE_VERSION=1
PROTOCOL=cloudfront
TCP_ACCELERATION=off
VPS_PUBLIC_IPV4=203.0.113.10
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
SUB_DOWNLOAD_NAME=EASY_ALL
OWNER_TOKEN=token-abcdefgh
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
MIHOMO_TEMPLATE_SNAPSHOT=1
SCHEDULED_REBOOT_ENABLED=0
SCHEDULED_REBOOT_HOUR=4
CF_NODE_DOMAIN=cf.example.com
CF_NODE_PREFIX=CF
VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
VLESS_PATH=/vless-0123456789ab
SUBSCRIPTION_DOMAIN=cf.example.com
CF_ORIGIN_DOMAIN=origin.example.com
ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
CDN_TRAFFIC_PROTECTION_GB=985
STATE
    PATH="${case_dir}/bin:${PATH}" CASE_DIR="${case_dir}" VALIDATE_FAIL="${validate_fail}" \
    RUNTIME_TMP="${case_dir}/runtime" \
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${case_dir}/runtime-write.lock" \
    EASY_ALL_STATE_FILE_OVERRIDE="${case_dir}/state/state.env" \
    EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${case_dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/subscriptions" \
    EASY_ALL_CLOUDFLARE_CREDENTIALS_OVERRIDE="${case_dir}/cloudflare.ini" \
    SINGBOX_BIN="${case_dir}/core/sing-box" \
    SINGBOX_CONFIG="${case_dir}/core/config.json" \
    SINGBOX_SERVICE_FILE="${case_dir}/systemd/easy_all-singbox.service" \
    CADDY_BIN="${case_dir}/core/caddy" \
    CADDY_CONFIG="${case_dir}/core/Caddyfile" \
    CADDY_SERVICE_FILE="${case_dir}/systemd/easy_all-caddy.service" \
    CADDY_ADMIN_SOCKET="${case_dir}/run/admin.sock" \
        bash -c '
            source "$1"/profiles/cloudfront.sh
            install -d -m 0700 "${RUNTIME_TMP}" "${CADDY_BIN%/*}" "${CADDY_CONFIG%/*}" \
                "${SINGBOX_SERVICE_FILE%/*}"
            require_root() { :; }
            systemctl() { printf "%s\n" "$*" >>"${CASE_DIR}/systemctl.log"; return 0; }
            download_singbox() {
                printf "#!/bin/sh\nexit 0\n" >"${SINGBOX_BIN}"
                chmod 0755 "${SINGBOX_BIN}"
            }
            download_caddy() {
                printf "#!/bin/sh\nexit 0\n" >"${CADDY_BIN}"
                chmod 0755 "${CADDY_BIN}"
            }
            validate_protocol_runtime() { [[ "${VALIDATE_FAIL}" != "1" ]]; }
            refresh_runtime_subscription_after_core_update() { :; }
            cdn_traffic_protection_checkpoint() { return 0; }
            cdn_traffic_needs_restricted_recovery() { return 1; }
            cdn_traffic_requirements_ok() { return 0; }
            # die 会退出所在 shell：用子 shell 包住才能拿到退出码并继续断言。
            status=0
            ( update_current_core ) || status=$?
            printf "STATUS=%s\n" "${status}"
        ' _ "${ROOT_DIR}" 2>&1 || true
}

repair_output=$(update_core_case none 0)
assert_contains "核心缺失时仍能重装修复" "${repair_output}" "STATUS=0"
assert_contains "修复成功后报告核心版本" "${repair_output}" "已更新"
assert_contains "核心替换后重启 Caddy 进程" "$(<"${TMP_DIR}/update-core-none-0/systemctl.log")" \
    "restart easy_all-caddy.service"
assert_equal "修复后 sing-box 二进制就位" "存在" \
    "$([[ -x "${TMP_DIR}/update-core-none-0/core/sing-box" ]] && echo 存在 || echo 缺失)"

rollback_output=$(update_core_case singbox 1)
assert_contains "缺核心时验收失败仍如实报告" "${rollback_output}" "STATUS=1"
assert_contains "缺失的核心没有旧版本可回滚时明说" "${rollback_output}" \
    "更新前缺失的核心没有可回滚的旧版本"
assert_not_contains "不再虚报已恢复旧版本" "${rollback_output}" "已恢复旧版本"

# --- 8. 不完整状态卸载：CloudFront 模式的计量残留也必须回收 -------------------
# 终审 P1：状态 schema 1 但协议不可识别时只 source profiles/anytls.sh，计量库
# （lib/cdn-traffic-guard.sh，仅 cloudfront-mode.sh 加载）根本没加载；旧实现用
# declare -F 守卫，于是 timer 与 mangle 计数链残留，timer 每 15 秒调用即将被删除的命令。
# systemctl/iptables/flock 是外部边界，用 PATH 替身记录；计量锁目录要求的 0:0 属主
# 是 root 边界，非 root 测试用 install 替身忽略 -o/-g，其余参数原样透传。
incomplete_uninstall_case() {
    local case_dir="${TMP_DIR}/incomplete-uninstall"
    local real_install
    real_install=$(command -v install)
    mkdir -p "${case_dir}/state" "${case_dir}/bin" "${case_dir}/systemd" \
        "${case_dir}/counter" "${case_dir}/subs"
    # 损坏/字段不齐：schema 1、PROTOCOL=cloudfront，但 CloudFront 字段全部缺失。
    cat >"${case_dir}/state/state.env" <<'STATE'
STATE_VERSION=1
PROTOCOL=cloudfront
STATE
    : >"${case_dir}/systemd/easy_all-cdn-traffic-guard.timer"
    : >"${case_dir}/systemd/easy_all-cdn-traffic-guard.service"
    cat >"${case_dir}/bin/systemctl" <<SYSCTL
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${case_dir}/systemctl.log"
SYSCTL
    cat >"${case_dir}/bin/iptables" <<IPTABLES
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${case_dir}/iptables.log"
last=""
for arg in "\$@"; do last=\${arg}; done
if [[ "\${last}" == "-S" ]]; then
    printf '%s\n' '-N easy_all-cdn' \\
        '-A INPUT -i lo -p tcp -m tcp --dport 10086 -j easy_all-cdn' \\
        '-A OUTPUT -o lo -p tcp -m tcp --sport 10086 -j easy_all-cdn'
fi
exit 0
IPTABLES
    cat >"${case_dir}/bin/install" <<INSTALL
#!/usr/bin/env bash
args=()
while ((\$#)); do
    case "\$1" in
    -o | --owner | -g | --group) shift 2 ;;
    *) args+=("\$1"); shift ;;
    esac
done
exec "${real_install}" "\${args[@]}"
INSTALL
    printf '#!/usr/bin/env bash\nexit 0\n' >"${case_dir}/bin/flock"
    chmod 0755 "${case_dir}/bin/systemctl" "${case_dir}/bin/iptables" \
        "${case_dir}/bin/install" "${case_dir}/bin/flock"
    : >"${case_dir}/systemctl.log"
    : >"${case_dir}/iptables.log"
    PATH="${case_dir}/bin:${PATH}" \
    SYSTEMD_SYSTEM_DIR="${case_dir}/systemd" \
    CDN_TRAFFIC_COUNTER_DIR_OVERRIDE="${case_dir}/counter" \
    RUNTIME_TMP="${case_dir}/runtime" \
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${case_dir}/runtime-write.lock" \
    EASY_ALL_STATE_FILE_OVERRIDE="${case_dir}/state/state.env" \
    EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/subs/subscriptions" \
    SINGBOX_BIN="${case_dir}/core/sing-box/sing-box" \
    CADDY_BIN="${case_dir}/core/caddy/caddy" \
    SINGBOX_SERVICE=easy_all-singbox.service \
    CADDY_SERVICE=easy_all-caddy.service \
    SINGBOX_SERVICE_FILE="${case_dir}/units/easy_all-singbox.service" \
    CADDY_SERVICE_FILE="${case_dir}/units/easy_all-caddy.service" \
        bash -c '
            source "$1/profiles/anytls.sh"
            require_root() { :; }
            # SSH/UFW/crontab/certbot 是宿主边界：本用例只验证本机清理顺序，不触碰它们。
            remove_certbot_deploy_hook() { :; }
            certificate_remove_lineage() { :; }
            restore_platform_security_state() { :; }
            restore_preinstall_firewall() { :; }
            restore_preinstall_ipv6() { :; }
            remove_daily_reboot_schedule() { :; }
            FORCE=1
            status=0
            ( uninstall_incomplete ) || status=$?
            printf "STATUS=%s\n" "${status}"
        ' _ "${ROOT_DIR}" 2>&1 || true
}

incomplete_output=$(incomplete_uninstall_case)
incomplete_calls=$(<"${TMP_DIR}/incomplete-uninstall/systemctl.log")
incomplete_iptables=$(<"${TMP_DIR}/incomplete-uninstall/iptables.log")
assert_contains "不完整状态的卸载仍能成功" "${incomplete_output}" "STATUS=0"
assert_contains "不完整状态卸载停用云流量保护定时器" "${incomplete_calls}" \
    "disable --now easy_all-cdn-traffic-guard.timer"
[[ ! -e "${TMP_DIR}/incomplete-uninstall/systemd/easy_all-cdn-traffic-guard.timer" ]] \
    && [[ ! -e "${TMP_DIR}/incomplete-uninstall/systemd/easy_all-cdn-traffic-guard.service" ]] \
    || fail "不完整状态卸载必须删除两个云流量保护单元文件"
# 计量链回收证明计量库在模式库未加载时也被按需 source 了。
assert_contains "不完整状态卸载回收 mangle 计量链" "${incomplete_iptables}" \
    "-D INPUT -i lo -p tcp -m tcp --dport 10086 -j easy_all-cdn"
assert_contains "不完整状态卸载删除 mangle 计量链本身" "${incomplete_iptables}" \
    "-X easy_all-cdn"

# --- 8b. 回滚执行段屏蔽 INT/TERM：在前台保护段内向自身发信号 ------------------
# 非交互 bash 的 `cmd &` 会继承“忽略 SIGINT/SIGQUIT”，后台进程无法为启动时已忽略
# 的信号建立有效 trap，kill -INT 会恒真。这里改为前台运行被测脚本，在回滚替身
# （两个入口的真实 trap '' 已生效）内 `kill -INT/-TERM $$`，随后再写存活标记并
# 继续清理收尾：只有信号确实被忽略才能走到 DONE/AFTER。
rollback_signal_case() { # $1=install|update $2=INT|TERM
    local entry=$1 sig=$2 dir="${TMP_DIR}/rollback-signal-${1}-${2}" status=0
    mkdir -p "${dir}/state" "${dir}/subs" "${dir}/runtime"
    cat >"${dir}/signal.sh" <<'SCRIPT'
set -Eeuo pipefail
source "${EASY_ALL_TEST_ROOT}/profiles/anytls.sh"
write_done() { : >"${SIGNAL_DONE}"; }
clear_profile_credentials() { : >"${SIGNAL_AFTER}"; }
send_signal() {
    if [[ "${SIGNAL_NAME}" == "INT" ]]; then
        kill -INT "$$"
    else
        kill -TERM "$$"
    fi
}
if [[ "${SIGNAL_ENTRY}" == "update" ]]; then
    rollback_subscription_update() { send_signal; write_done; }
    UPDATE_SUB_ROLLBACK_ON_EXIT=1
    UPDATE_SUB_BACKUP_DIR="${RUNTIME_TMP}/part.keep"
    mkdir -p "${UPDATE_SUB_BACKUP_DIR}"
    exit 143
else
    rollback_fresh_install() { send_signal; write_done; }
    INSTALL_ROLLBACK_ON_EXIT=1
    exit 1
fi
SCRIPT
    EASY_ALL_TEST_ROOT="${ROOT_DIR}" \
    SIGNAL_DONE="${dir}/done" SIGNAL_AFTER="${dir}/after" \
    SIGNAL_ENTRY="${entry}" SIGNAL_NAME="${sig}" \
    RUNTIME_TMP="${dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${dir}/subs" \
        bash "${dir}/signal.sh" </dev/null >"${dir}/log" 2>&1 || status=$?
    printf 'STATUS=%s DONE=%s AFTER=%s\n' "${status}" \
        "$([[ -e "${dir}/done" ]] && echo yes || echo no)" \
        "$([[ -e "${dir}/after" ]] && echo yes || echo no)"
}
for signal_name in INT TERM; do
    signal_output=$(rollback_signal_case install "${signal_name}")
    assert_contains "安装回滚执行段屏蔽 ${signal_name}：回滚完成" \
        "${signal_output}" "DONE=yes"
    assert_contains "安装回滚执行段屏蔽 ${signal_name}：收尾继续" \
        "${signal_output}" "AFTER=yes"
    assert_contains "安装回滚执行段屏蔽 ${signal_name}：退出码保持 1" \
        "${signal_output}" "STATUS=1"
    signal_output=$(rollback_signal_case update "${signal_name}")
    assert_contains "订阅更新回滚执行段屏蔽 ${signal_name}：回滚完成" \
        "${signal_output}" "DONE=yes"
    assert_contains "订阅更新回滚执行段屏蔽 ${signal_name}：收尾继续" \
        "${signal_output}" "AFTER=yes"
    assert_contains "订阅更新回滚执行段屏蔽 ${signal_name}：退出码保持 143" \
        "${signal_output}" "STATUS=143"
done

# --- 9. CDN 优选连接地址（cdnEdgeAddress）：安装交互与订阅事务顺序 ---------------
# design §2 条 1/2/4/6、§11 第 8-12 项。

# 9a. 四个 CDN 模式的安装入口都调用收集器并拼出该模式的后缀；模式 1 不调用。
run_edge_collector_case() { # $1=profile -> stdout: 收集器被调用时记录的 "<模式后缀>"
    local out="${TMP_DIR}/edge-inputs-$1"
    mkdir -p "${out}/state/certs" "${out}/runtime" "${out}/subs"
    RUNTIME_TMP="${out}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${out}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${out}/state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out}/subs" \
    EDGE_CALLS="${out}/calls.log" \
        bash -c '
            source "$1/profiles/$2.sh"
            prompt_value() { printf "%s" "${2:-}"; }
            prompt_secret() { printf "%s" "0123456789abcdef0123456789abcdef"; }
            cloudflare_collect_api_token() { :; }
            collect_cdn_edge_address() { printf "%s\n" "$(cdn_edge_mode_suffix)" >>"${EDGE_CALLS}"; }
            CF_ZONE=example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            SUBSCRIPTION_MODE=deploy
            VLESS_UUID=11111111-2222-4333-8444-555555555555
            collect_install_inputs
        ' _ "${ROOT_DIR}" "$1" >"${out}/log" 2>&1 || {
        cat "${out}/log" >&2
        return 1
    }
    cat "${out}/calls.log" 2>/dev/null || true
}
while read -r edge_profile edge_suffix; do
    edge_calls=$(run_edge_collector_case "${edge_profile}") \
        || fail "${edge_profile} 安装输入收集失败"
    assert_equal "${edge_profile} 安装调用 CDN 优选收集器" "${edge_suffix}" "${edge_calls}"
done <<'EDGE_PROFILES'
cloudfront cloudfront.182682.xyz
combined cloudfront.182682.xyz
cloudflare cloudflare.182682.xyz
combined-cloudflare cloudflare.182682.xyz
EDGE_PROFILES
edge_anytls_calls=$(run_edge_collector_case anytls) || fail "模式 1 安装输入收集失败"
assert_equal "模式 1 不调用 CDN 优选收集器" "" "${edge_anytls_calls}"

# 9b. 真实非终端 stdin：收集器整体 no-op（不提示也不改配置；验收条件 6）。
edge_cfg_none='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
edge_cfg_upper='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"E6G7GS3V1G.Cloudflare.182682.XYZ"}'
for edge_noop_cfg in "${edge_cfg_upper}" "${edge_cfg_none}"; do
    edge_noop=$(
        RUNTIME_TMP="${TMP_DIR}/edge-noop/runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/edge-noop/state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/edge-noop/certs" \
            bash -c '
                source "$1/profiles/combined-cloudflare.sh"
                CF_ZONE=example.com
                DIRECT_DOMAIN=direct.example.com
                DIRECT_NODE_NAME="US-direct"
                CF_NODE_DOMAIN=cf.example.com
                CF_NODE_PREFIX=CF
                VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
                VLESS_PATH=/vless-0123456789ab
                cdn_derive_runtime_fields
                SUBSCRIPTION_CONFIG=$2
                read_bilingual() { printf "PROMPT\n"; }
                collect_cdn_edge_address
                [[ "${SUBSCRIPTION_CONFIG}" == "$2" ]] && printf "UNCHANGED\n"
            ' _ "${ROOT_DIR}" "${edge_noop_cfg}" 2>&1
    )
    assert_contains "非终端下收集器不改订阅配置（${edge_noop_cfg}）" "${edge_noop}" "UNCHANGED"
    assert_not_contains "非终端下收集器不提示（${edge_noop_cfg}）" "${edge_noop}" "PROMPT"
done

# 9c. 交互收集器：stub tty 判定与读入原语（与既有 prompt_value stub 同手法）。
# 输出分块：STATUS= / CONFIG= / STDOUT: / STDERR:，供 stream_of 与 config_of 分开断言。
edge_case() { # $1=订阅配置 $2=INSTALL_RESUME $3=被测函数 $4=函数参数 $5=PROTOCOL 覆盖；其后为依次读入的答案
    local dir config=$1 resume=$2 fn=$3 fn_arg=$4 protocol=$5 status_line config_line
    shift 5
    dir=$(mktemp -d "${TMP_DIR}/edge-case.XXXXXX")
    mkdir -p "${dir}/state/certs" "${dir}/runtime"
    : >"${dir}/answers"
    while (($# > 0)); do
        printf '%s\n' "$1" >>"${dir}/answers"
        shift
    done
    RUNTIME_TMP="${dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${dir}/state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${dir}/subs" \
    EDGE_ANSWERS="${dir}/answers" EDGE_STDOUT="${dir}/stdout" EDGE_STDERR="${dir}/stderr" \
    EDGE_CONFIG="${config}" EDGE_RESUME="${resume}" EDGE_FN="${fn}" \
    EDGE_FN_ARG="${fn_arg}" EDGE_PROTOCOL="${protocol}" \
        bash -c '
            source "$1/profiles/combined-cloudflare.sh"
            CF_ZONE=example.com
            DIRECT_DOMAIN=direct.example.com
            DIRECT_NODE_NAME="US-direct"
            CF_NODE_DOMAIN=cf.example.com
            CF_NODE_PREFIX=CF
            VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
            VLESS_PATH=/vless-0123456789ab
            cdn_derive_runtime_fields
            [[ -z "${EDGE_PROTOCOL}" ]] || PROTOCOL=${EDGE_PROTOCOL}
            SUBSCRIPTION_CONFIG=${EDGE_CONFIG}
            INSTALL_RESUME=${EDGE_RESUME}
            # 测试通过覆盖 tty 判定模拟交互终端（同 dns_takeover_interactive 惯例）。
            cdn_edge_interactive() { return 0; }
            read_bilingual() {
                printf "%s\n" "$1" >&2
                local next=""
                if [[ -s "${EDGE_ANSWERS}" ]]; then
                    next=$(head -n 1 "${EDGE_ANSWERS}")
                    tail -n +2 "${EDGE_ANSWERS}" >"${EDGE_ANSWERS}.next"
                    mv -f "${EDGE_ANSWERS}.next" "${EDGE_ANSWERS}"
                fi
                printf -v "$2" "%s" "${next}"
            }
            "${EDGE_FN}" "${EDGE_FN_ARG}" >"${EDGE_STDOUT}" 2>"${EDGE_STDERR}" \
                || printf "STATUS=%s\n" "$?"
            printf "CONFIG=%s\n" "${SUBSCRIPTION_CONFIG}"
        ' _ "${ROOT_DIR}" >"${dir}/log" 2>&1 || true
    status_line=$(sed -n 's/^STATUS=//p' "${dir}/log" 2>/dev/null)
    config_line=$(sed -n 's/^CONFIG=//p' "${dir}/log" 2>/dev/null)
    printf 'STATUS=%s\nCONFIG=%s\nSTDOUT:\n%s\nSTDERR:\n%s\n' \
        "${status_line:-0}" "${config_line}" \
        "$(cat "${dir}/stdout" 2>/dev/null)" "$(cat "${dir}/stderr" 2>/dev/null)"
}
stream_of() { # $1=edge_case 块 $2=STDOUT|STDERR
    printf '%s\n' "$1" | awk -v want="$2" '
        /^STDOUT:$/ { section = "STDOUT"; next }
        /^STDERR:$/ { section = "STDERR"; next }
        /^STATUS=/ || /^CONFIG=/ { section = ""; next }
        section == want { print }
    '
}
config_of() { sed -n 's/^CONFIG=//p' <<<"$1"; }
status_of() { sed -n 's/^STATUS=//p' <<<"$1"; }

# 分支 1：字段是生成的 10 位前缀形态 → 提示默认前缀，回车后值不变（验收条件 2）。
edge_cfg_prefix='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"}'
edge_branch1=$(edge_case "${edge_cfg_prefix}" 1 collect_cdn_edge_address "" "" "")
assert_contains "分支 1 提示默认前缀" "$(stream_of "${edge_branch1}" STDERR)" \
    "CDN 优选前缀 [k7m2qp4x9d]（回车采用）："
assert_equal "分支 1 回车后配置不变" "${edge_cfg_prefix}" "$(config_of "${edge_branch1}")"
assert_not_contains "提示文案不用 prompt_value 的默认值后缀" \
    "${edge_branch1}" "直接回车使用默认值"

# 分支 1 的两个边角：大写生成值（规范化后仍按前缀形态处理）与历史后缀跨模式（回车按当前模式重写）。
edge_cfg_upper_prefix='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"K7M2QP4X9D.Cloudfront.182682.XYZ"}'
edge_branch1_upper=$(edge_case "${edge_cfg_upper_prefix}" 0 collect_cdn_edge_address "" "" "")
assert_contains "大写生成值仍按前缀形态提示" "$(stream_of "${edge_branch1_upper}" STDERR)" \
    "CDN 优选前缀 [k7m2qp4x9d]（回车采用）："
assert_equal "大写生成值回车后规范化为小写" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_branch1_upper}")"

edge_branch1_cross=$(edge_case "${edge_cfg_prefix}" 0 collect_cdn_edge_address "" "cloudfront" "")
assert_contains "跨模式续装仍提示原前缀" "$(stream_of "${edge_branch1_cross}" STDERR)" \
    "CDN 优选前缀 [k7m2qp4x9d]（回车采用）："
assert_equal "跨模式回车按当前模式重写后缀" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudfront.182682.xyz"}' \
    "$(config_of "${edge_branch1_cross}")"

# 分支 2：自定义合法优选域名 → 不提示、原样保留，并在 stdout 告知改法（验收条件 2）。
edge_cfg_custom='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"edge.mycdn.example"}'
edge_branch2=$(edge_case "${edge_cfg_custom}" 0 collect_cdn_edge_address "" "" "")
assert_equal "分支 2 不提示" "" "$(stream_of "${edge_branch2}" STDERR)"
assert_equal "分支 2 原样保留自定义优选域名" "${edge_cfg_custom}" "$(config_of "${edge_branch2}")"
assert_contains "分支 2 stdout 打印当前优选地址" "$(stream_of "${edge_branch2}" STDOUT)" \
    "edge.mycdn.example"
assert_contains "分支 2 指向 edit-sub" "$(stream_of "${edge_branch2}" STDOUT)" "edit-sub"

# 分支 3：续装且无字段 → 不再允许关闭，默认新随机前缀，回车后按模式写入。
edge_branch3=$(edge_case "${edge_cfg_none}" 1 collect_cdn_edge_address "" "" "")
edge_branch3_default=$(sed -n 's/.*CDN 优选前缀 \[\([^]]*\)\].*/\1/p' \
    <<<"$(stream_of "${edge_branch3}" STDERR)")
[[ "${edge_branch3_default}" =~ ^[a-z][a-z0-9]{9}$ ]] \
    || fail "分支 3 必须给出 10 位随机前缀（不允许 off），实际 <${edge_branch3_default}>"
assert_equal "分支 3 续装回车后写入优选地址" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"'"${edge_branch3_default}"'.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_branch3}")"

# 分支 4：全新首装且无字段 → 默认是新的 10 位前缀，回车后拼上当前模式后缀。
edge_branch4=$(edge_case "${edge_cfg_none}" 0 collect_cdn_edge_address "" "" "")
edge_branch4_default=$(sed -n 's/.*CDN 优选前缀 \[\([^]]*\)\].*/\1/p' \
    <<<"$(stream_of "${edge_branch4}" STDERR)")
[[ "${edge_branch4_default}" =~ ^[a-z][a-z0-9]{9}$ ]] \
    || fail "分支 4 默认值必须是 10 位随机前缀，实际 <${edge_branch4_default}>"
assert_equal "分支 4 回车后按模式拼完整地址" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"'"${edge_branch4_default}"'.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_branch4}")"

# 试运行失败家族：不可解析 / 非对象 JSON / 无关非法节点 / 非法优选值 → 零副作用。
while IFS= read -r edge_bad_config; do
    edge_failed=$(edge_case "${edge_bad_config}" 0 collect_cdn_edge_address "" "" "")
    assert_equal "试运行失败不提示：${edge_bad_config}" "" "$(stream_of "${edge_failed}" STDERR)"
    assert_equal "试运行失败无 info 行：${edge_bad_config}" "" "$(stream_of "${edge_failed}" STDOUT)"
    assert_equal "试运行失败不改配置：${edge_bad_config}" "${edge_bad_config}" \
        "$(config_of "${edge_failed}")"
    assert_equal "试运行失败仍返回 0：${edge_bad_config}" "0" "$(status_of "${edge_failed}")"
done <<'EDGE_BAD_CONFIGS'
[1]
{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[{"type":"vless"}]}
{bad
{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"a b"}
EDGE_BAD_CONFIGS

# 9d. 交互原语：写入判定零副作用、提示循环文案与重填（§11 第 11 项）。
edge_store_prefix=$(edge_case "${edge_cfg_none}" 0 cdn_edge_store_answer k7m2qp4x9d "" "")
assert_equal "合法前缀按模式拼完整地址" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_store_prefix}")"
edge_store_cf=$(edge_case "${edge_cfg_none}" 0 cdn_edge_store_answer k7m2qp4x9d cloudfront "")
assert_equal "CloudFront 模式拼 cloudfront 后缀" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudfront.182682.xyz"}' \
    "$(config_of "${edge_store_cf}")"
while IFS= read -r edge_bad_answer; do
    edge_store_bad=$(edge_case "${edge_cfg_prefix}" 0 cdn_edge_store_answer "${edge_bad_answer}" "" "")
    assert_equal "非法答案零副作用：<${edge_bad_answer}>" "${edge_cfg_prefix}" \
        "$(config_of "${edge_store_bad}")"
    assert_equal "非法答案返回非零：<${edge_bad_answer}>" "1" "$(status_of "${edge_store_bad}")"
done <<'EDGE_BAD_ANSWERS'
K7M2QP4X9D
ab
abcdefghijk
k7m2qp4x9d 
 off
off
off 
OFF
EDGE_BAD_ANSWERS

edge_loop=$(edge_case "${edge_cfg_prefix}" 0 cdn_edge_prompt_loop k7m2qp4x9d "" "ab" "k2v8nq4zt6")
assert_equal "重填前只打印同一提示两次" "2" \
    "$(stream_of "${edge_loop}" STDERR | grep -c 'CDN 优选前缀 \[k7m2qp4x9d\]（回车采用）：')"
assert_equal "非法输入后的说明行落 stdout（仓库 warn 惯例）" "1" \
    "$(stream_of "${edge_loop}" STDOUT | grep -c .)"
assert_equal "stderr 只有提示行" "0" \
    "$(stream_of "${edge_loop}" STDERR | grep -vc 'CDN 优选前缀 \[k7m2qp4x9d\]（回车采用）：')"
assert_equal "重填后写入第二次输入" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k2v8nq4zt6.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_loop}")"
edge_loop_off=$(edge_case "${edge_cfg_prefix}" 0 cdn_edge_prompt_loop k7m2qp4x9d "" "off" "k2v8nq4zt6")
assert_equal "off 不再关闭而是重填" "2" \
    "$(stream_of "${edge_loop_off}" STDERR | grep -c 'CDN 优选前缀 \[k7m2qp4x9d\]（回车采用）：')"
assert_equal "off 后的重新输入被写入" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k2v8nq4zt6.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_loop_off}")"
edge_loop_enter=$(edge_case "${edge_cfg_none}" 0 cdn_edge_prompt_loop k7m2qp4x9d "" "")
assert_equal "空输入采用默认值" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"}' \
    "$(config_of "${edge_loop_enter}")"

# 9e. 结构断言：每个「定义 update_subscription 且渲染订阅」的模式库，
# 都必须在快照与写运行配置之前校验订阅配置（验收条件 4 结构证据）。
edge_mode_libs=""
for edge_mode_file in "${ROOT_DIR}"/lib/*-mode.sh; do
    grep -q '^update_subscription() {' "${edge_mode_file}" || continue
    grep -q 'write_subscriptions' "${edge_mode_file}" || continue
    edge_mode_libs="${edge_mode_libs}${edge_mode_libs:+ }$(basename "${edge_mode_file}")"
    edge_mode_body=$(awk '/^update_subscription\(\) \{/,/^\}/' "${edge_mode_file}")
    printf '%s\n' "${edge_mode_body}" | awk '
        /cdn_apply_subscription_config/ { apply = NR }
        /snapshot_subscription_update/ { snapshot = NR }
        /write_runtime_config/ { write = NR }
        END { exit !(apply && snapshot && write && apply < snapshot && apply < write) }
    ' || fail "${edge_mode_file} 的 update_subscription 必须在快照与写运行配置前校验订阅配置"
done
assert_equal "订阅事务模式库清单" "anytls-mode.sh cloudflare-mode.sh cloudfront-mode.sh" \
    "${edge_mode_libs}"

run_tls_certificate_cases

printf 'ok - 凭据、strict 顺序、DNS 归属、证书生效与服务编排测试通过\n'
