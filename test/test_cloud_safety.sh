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
    assert_contains "模式 3 ${ssl}：先只读查询 Zone ID" "${log}" \
        "GET /zones?name=example.com&status=active&per_page=50"
    zone_line=$(grep -n 'GET /zones?name=' <<<"${log}" | head -n 1 | cut -d: -f1)
    ssl_line=$(grep -n 'settings/ssl' <<<"${log}" | head -n 1 | cut -d: -f1)
    [[ -n "${zone_line}" && -n "${ssl_line}" ]] \
        || fail "模式 3 ${ssl}：必须同时查询 Zone ID 与 SSL 设置"
    ((zone_line < ssl_line)) || fail "模式 3 ${ssl}：Zone ID 查询必须早于 SSL 设置查询"
    if [[ "${ssl}" == "strict" ]]; then
        assert_contains "模式 3 strict：继续创建 DNS" "${log}" "DNS cf.example.com"
        assert_contains "模式 3 strict：执行到证书签发" "${log}" "CERT"
        assert_contains "模式 3 strict：成功结束" "${log}" "STATUS=0"
    else
        assert_not_contains "模式 3 ${ssl}：不创建 DNS" "${log}" "DNS "
        assert_not_contains "模式 3 ${ssl}：不签发证书" "${log}" "CERT"
        assert_not_contains "模式 3 ${ssl}：非零退出" "${log}" "STATUS=0"
    fi
    assert_not_contains "模式 3 ${ssl}：没有写请求" "${log}" "POST "
    assert_not_contains "模式 3 ${ssl}：没有删除请求" "${log}" "DELETE "
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

# --- 3. 模式 3 的 DNS 归属常量：创建、复用与 purge 使用同一契约 -----------------
run_dns_case() { # $1=create|reuse|purge|foreign
    local case_name=$1
    local log="${TMP_DIR}/dns-${case_name}.log"
    local runtime="${TMP_DIR}/dns-runtime-${case_name}"
    local state="${TMP_DIR}/dns-state-${case_name}"
    mkdir -p "${runtime}" "${state}"
    (
        set -Eeuo pipefail
        export RUNTIME_TMP="${runtime}"
        export EASY_ALL_STATE_DIR_OVERRIDE="${state}"
        export EASY_ALL_CERT_DIR_OVERRIDE="${state}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state}/subscriptions"
        source "${ROOT_DIR}/profiles/cloudflare.sh"
        CLOUDFLARE_ZONE_ID=zoneid
        VPS_PUBLIC_IPV4=203.0.113.10
        CF_NODE_DOMAIN=cf.example.com
        SUBSCRIPTION_MODE=deploy
        existing_record='[{"id":"rec1","type":"A","name":"cf.example.com","content":"203.0.113.10","proxied":true,"comment":"easy_all cloudflare"}]'
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
        case "${case_name}" in
        purge) cdn_purge_cloudflare_dns ;;
        *) dns_ensure_record cf.example.com A "${VPS_PUBLIC_IPV4}" true ;;
        esac
    ) >/dev/null 2>&1 || true
    cat "${log}"
}

create_log=$(run_dns_case create)
assert_contains "模式 3 创建记录使用模式专属注释" "${create_log}" "easy_all cloudflare"
assert_contains "模式 3 创建记录是 POST" "${create_log}" "POST /zones/zoneid/dns_records"

reuse_log=$(run_dns_case reuse)
assert_not_contains "模式 3 复用受管记录不写入" "${reuse_log}" "POST "
assert_not_contains "模式 3 复用受管记录不改写" "${reuse_log}" "PATCH "

purge_log=$(run_dns_case purge)
assert_contains "模式 3 purge 删除受管记录" "${purge_log}" \
    "DELETE /zones/zoneid/dns_records/rec1"
assert_not_contains "模式 3 purge 不修改记录" "${purge_log}" "PATCH "

foreign_log=$(run_dns_case foreign)
assert_not_contains "第三方注释的记录不被接管" "${foreign_log}" "POST "
assert_not_contains "第三方注释的记录不被删除" "${foreign_log}" "DELETE "

# --- 3b. 模式 4：直连域名可与源站域名复用 -------------------------------------
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
assert_equal "模式 4 复用同一域名时只输出一行" "origin.example.com" "${reused_hosts}"
distinct_hosts=$(certificate_hosts_case direct.example.com origin.example.com) \
    || fail "证书域名不同场景调用失败"
assert_equal "模式 4 不同域名仍输出两行" \
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

# --- 6. 源站守卫公网探测：必须打 Caddy 站点端口（模式 4 是 8443，不是 sing-box 的 443） ---
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
assert_contains "模式 4 探测 Caddy 8443" "${mode4_urls}" "https://origin.example.com:8443/vless-0123456789ab"
assert_not_contains "模式 4 不把探测发到 443" "${mode4_urls}" "https://origin.example.com/vless"
mode2_urls=$(<"$(origin_guard_case cloudfront)")
assert_contains "模式 2 探测 Caddy 443" "${mode2_urls}" "https://origin.example.com:443/vless-0123456789ab"

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

run_tls_certificate_cases

printf 'ok - 凭据、strict 顺序、DNS 归属、证书生效与服务编排测试通过\n'
