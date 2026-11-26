#!/usr/bin/env bash
# 阶段 2 修复轮 A：Cloudflare 凭据持久化、strict 校验顺序、DNS 归属常量与证书实际生效。
# 外部边界（Cloudflare API、systemctl、服务动作）用可编程替身；TLS 握手用真实 openssl。
set -Eeuo pipefail

# A31 阶段一：断言计数器，防止整个文件静默空跑（fixture 出错时最容易全绿）。
TESTS_ASSERTED=0

# A17/A32：skip 必须同时可见（stdout）并计入文件尾「未验证项」汇总——只写 stderr 的 skip
# 在 CI 日志里会消失，读者会以为覆盖完整。
SKIPPED_ITEMS=()
skip_case() { # $1=用例名 $2=原因
    SKIPPED_ITEMS+=("$1：$2")
    printf 'skip - %s：%s\n' "$1" "$2"
}

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_cloud_safety.XXXXXX")
fi
# 测试用 TLS 服务与其 watchdog 的生命周期收口：先停 watchdog，再 SIGTERM 服务，不退则升级 SIGKILL。
TLS_SERVER_PID=""
TLS_WATCHDOG_PID=""
stop_tls_server() {
    [[ -z "${TLS_WATCHDOG_PID}" ]] || kill "${TLS_WATCHDOG_PID}" 2>/dev/null || true
    TLS_WATCHDOG_PID=""
    [[ -z "${TLS_SERVER_PID}" ]] || kill -TERM "${TLS_SERVER_PID}" 2>/dev/null || true
    if [[ -n "${TLS_SERVER_PID}" ]] && kill -0 "${TLS_SERVER_PID}" 2>/dev/null; then
        sleep 0.2
        kill -KILL "${TLS_SERVER_PID}" 2>/dev/null || true
    fi
    TLS_SERVER_PID=""
}
cleanup_test() {
    stop_tls_server
    rm -rf -- "${TMP_DIR}"
}
trap cleanup_test EXIT
# SIGKILL 拦不住：那种情况靠 spawn_background 里的 ulimit -t 与 wall-time watchdog 兜底。
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
assert_equal() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}
assert_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] \
        || fail "${label}: missing <${expected}> in <${text}>"
}
assert_not_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected <${unexpected}> in <${text}>"
}
assert_file_mode() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
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
for profile in cloudfront cloudflare reality-cloudfront reality-cloudflare; do
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
for lib in cloudfront-mode.sh cloudflare-mode.sh reality-cloudflare-mode.sh; do
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
        source "$1/profiles/reality-cloudflare.sh"
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
run_strict_case() { # $1=ssl 值或 403 $2=profile 名 $3=订阅模式 $4=websockets 值或 403
    local ssl=$1 profile=$2 subscription_mode=${3:-deploy} websockets=${4:-on}
    local case_tag="${websockets//\//_}"
    local log="${TMP_DIR}/strict-${profile}-${ssl//\//_}-ws${case_tag}.log"
    local script="${TMP_DIR}/strict-${profile}-${ssl//\//_}-ws${case_tag}.sh"
    local runtime="${TMP_DIR}/strict-runtime-${profile}-${ssl//\//_}-ws${case_tag}"
    local state="${TMP_DIR}/strict-state-${profile}-${ssl//\//_}-ws${case_tag}"
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
    "GET /zones/zoneid/settings/websockets")
        [[ $(printf '%q' "${websockets}") == "403" ]] && return 1
        printf '{"value":"%s"}\n' $(printf '%q' "${websockets}") ;;
    *) return 1 ;;
    esac
}
persist_cloudflare_token() { :; }
dns_ensure_record() { printf 'DNS %s\n' "\$1" >>$(printf '%q' "${log}"); }
certbot_write_cloudflare_credentials() { :; }
cdn_issue_certificate() { printf 'CERT\n' >>$(printf '%q' "${log}"); }
direct_ensure_origin_rule() { printf 'RULE\n' >>$(printf '%q' "${log}"); }
apply_cloud_phase
STRICT
    bash "${script}" >/dev/null 2>&1 || status=$?
    printf 'STATUS=%s\n' "${status}" >>"${log}"
    cat "${log}"
}

for ssl in strict full flexible off 403; do
    log=$(run_strict_case "${ssl}" cloudflare)
    assert_contains "模式 1 ${ssl}：先只读查询 Zone ID" "${log}" \
        "GET /zones?name=example.com&status=active&per_page=50"
    zone_line=$(grep -n 'GET /zones?name=' <<<"${log}" | head -n 1 | cut -d: -f1)
    ssl_line=$(grep -n 'settings/ssl' <<<"${log}" | head -n 1 | cut -d: -f1)
    [[ -n "${zone_line}" && -n "${ssl_line}" ]] \
        || fail "模式 1 ${ssl}：必须同时查询 Zone ID 与 SSL 设置"
    ((zone_line < ssl_line)) || fail "模式 1 ${ssl}：Zone ID 查询必须早于 SSL 设置查询"
    if [[ "${ssl}" == "strict" ]]; then
        assert_contains "模式 1 strict：继续创建 DNS" "${log}" "DNS cf.example.com"
        assert_contains "模式 1 strict：执行到证书签发" "${log}" "CERT"
        assert_contains "模式 1 strict：成功结束" "${log}" "STATUS=0"
    else
        assert_not_contains "模式 1 ${ssl}：不创建 DNS" "${log}" "DNS "
        assert_not_contains "模式 1 ${ssl}：不签发证书" "${log}" "CERT"
        assert_not_contains "模式 1 ${ssl}：非零退出" "${log}" "STATUS=0"
    fi
    assert_not_contains "模式 1 ${ssl}：没有写请求" "${log}" "POST "
    assert_not_contains "模式 1 ${ssl}：没有删除请求" "${log}" "DELETE "
done

# 模式 1 已改为纯 Xray XHTTP（HTTP/2 回源）：不再预检 WebSockets，
# 即使 Zone 把 WebSockets 置为 off/403 或读取失败也不得阻断，且不得发该设置请求。
for ws in off 403 on; do
    log=$(run_strict_case strict cloudflare deploy "${ws}")
    assert_not_contains "模式 1 websockets ${ws}：不请求 WebSockets 设置" "${log}" \
        "GET /zones/zoneid/settings/websockets"
    assert_contains "模式 1 websockets ${ws}：继续创建 DNS" "${log}" "DNS cf.example.com"
    assert_contains "模式 1 websockets ${ws}：执行到证书签发" "${log}" "CERT"
    assert_contains "模式 1 websockets ${ws}：成功结束" "${log}" "STATUS=0"
    assert_not_contains "模式 1 websockets ${ws}：没有写请求" "${log}" "POST "
done
# SSL 校验仍然保留，且仍早于 DNS 与证书。
ssl_only_log=$(run_strict_case strict cloudflare)
ssl_line=$(grep -n 'settings/ssl' <<<"${ssl_only_log}" | head -n 1 | cut -d: -f1)
dns_line=$(grep -n 'DNS cf.example.com' <<<"${ssl_only_log}" | head -n 1 | cut -d: -f1)
[[ -n "${ssl_line}" && -n "${dns_line}" ]] \
    || fail "模式 1：必须同时查询 SSL 设置并创建 DNS 记录"
((ssl_line < dns_line)) || fail "模式 1：SSL 校验必须早于 DNS 写入"

# 模式 4：橙云节点同样依赖 WebSockets，关闭或读取失败必须在任何 DNS/证书/Origin Rule 写入前阻断。
for ws in off 403; do
    log=$(run_strict_case strict reality-cloudflare deploy "${ws}")
    assert_contains "模式 4 websockets ${ws}：查询了 WebSockets 设置" "${log}" \
        "GET /zones/zoneid/settings/websockets"
    assert_not_contains "模式 4 websockets ${ws}：不创建 DNS" "${log}" "DNS "
    assert_not_contains "模式 4 websockets ${ws}：不签发证书" "${log}" "CERT"
    assert_not_contains "模式 4 websockets ${ws}：不写 Origin Rule" "${log}" "RULE"
    assert_not_contains "模式 4 websockets ${ws}：非零退出" "${log}" "STATUS=0"
    assert_not_contains "模式 4 websockets ${ws}：没有写请求" "${log}" "POST "
    assert_not_contains "模式 4 websockets ${ws}：没有删除请求" "${log}" "DELETE "
done
mode4_ws_on_log=$(run_strict_case strict reality-cloudflare deploy on)
assert_contains "模式 4 websockets on：继续创建直连 DNS" "${mode4_ws_on_log}" "DNS node.example.com"
assert_contains "模式 4 websockets on：继续创建节点/订阅 DNS" "${mode4_ws_on_log}" "DNS sub.example.com"
assert_contains "模式 4 websockets on：执行到证书签发" "${mode4_ws_on_log}" "CERT"
assert_contains "模式 4 websockets on：执行到 Origin Rule" "${mode4_ws_on_log}" "RULE"
assert_contains "模式 4 websockets on：成功结束" "${mode4_ws_on_log}" "STATUS=0"



# 模式 4 仍走 HTTPUpgrade（握手发 Upgrade: websocket）：交互终端下预检失败时给 1 次重试机会：
# 首次 off → 提示后回车 → 变为 on 则通过，仍 off 则阻断。
run_interactive_ws_retry_case() {
    local second_value=$1
    local case_dir="${TMP_DIR}/ws-retry-${second_value}"
    local log="${case_dir}/run.log"
    local script="${case_dir}/run.sh"
    local count_file="${case_dir}/ws.count"
    mkdir -p "${case_dir}/runtime" "${case_dir}/state"
    cat >"${script}" <<RETRY
set -Eeuo pipefail
export RUNTIME_TMP=$(printf '%q' "${case_dir}/runtime")
export EASY_ALL_STATE_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state")
export EASY_ALL_CERT_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state/certs")
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state/subscriptions")
source $(printf '%q' "${ROOT_DIR}/profiles/reality-cloudflare.sh")
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
CF_NODE_DOMAIN=cf.example.com
DIRECT_DOMAIN=node.example.com
SUBSCRIPTION_DOMAIN=cf.example.com
ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
SUBSCRIPTION_MODE=deploy
CLOUDFLARE_API_TOKEN=$(printf '%q' "${TOKEN}")
COUNT_FILE=$(printf '%q' "${count_file}")
cloudflare_api_request() {
    printf '%s %s\n' "\$1" "\$2" >>$(printf '%q' "${log}")
    case "\$1 \$2" in
    "GET /zones?name=example.com&status=active&per_page=50")
        printf '[{"name":"example.com","id":"zoneid"}]\n' ;;
    "GET /zones/zoneid/settings/ssl")
        printf '{"value":"strict"}\n' ;;
    "GET /zones/zoneid/settings/websockets")
        local n=0
        [[ -f "\${COUNT_FILE}" ]] && n=\$(<"\${COUNT_FILE}")
        n=\$((n + 1))
        printf '%s\n' "\${n}" >"\${COUNT_FILE}"
        if ((n == 1)); then
            printf '{"value":"off"}\n'
        else
            printf '{"value":"%s"}\n' $(printf '%q' "${second_value}")
        fi ;;
    *) return 1 ;;
    esac
}
persist_cloudflare_token() { :; }
dns_ensure_record() { printf 'DNS %s\n' "\$1" >>$(printf '%q' "${log}"); }
certbot_write_cloudflare_credentials() { :; }
cdn_issue_certificate() { printf 'CERT\n' >>$(printf '%q' "${log}"); }
direct_ensure_origin_rule() { printf 'RULE\n' >>$(printf '%q' "${log}"); }
apply_cloud_phase
RETRY
    local status=0
    python3 - "${script}" <<'PY' >"${case_dir}/tty.out" 2>&1 || status=$?
import os, pty, select, subprocess, sys
master, slave = pty.openpty()
proc = subprocess.Popen(["bash", sys.argv[1]], stdin=slave, stdout=slave, stderr=slave, close_fds=True)
os.close(slave)
sent = False
buf = b""
while True:
    r, _, _ = select.select([master], [], [], 5.0)
    if not r:
        break
    try:
        chunk = os.read(master, 4096)
    except OSError:
        break
    if not chunk:
        break
    buf += chunk
    if not sent and "按回车重试".encode("utf-8") in buf:
        os.write(master, b"\n")
        sent = True
os.close(master)
sys.stdout.buffer.write(buf)
sys.exit(proc.wait())
PY
    printf 'STATUS=%s\n' "${status}" >>"${log}"
    cat "${log}"
}

# 无 pty 的环境（容器、受限沙箱）无法驱交互重试：记未验证项，不静默当作通过。
if python3 -c 'import pty; pty.openpty()' >/dev/null 2>&1; then
    retry_pass_log=$(run_interactive_ws_retry_case on)
    assert_contains "交互重试后变为 on：成功结束" "${retry_pass_log}" "STATUS=0"
    assert_contains "交互重试后变为 on：继续创建 DNS" "${retry_pass_log}" "DNS cf.example.com"
    assert_equal "交互重试后变为 on：恰查询 2 次 WebSockets" "2" \
        "$(grep -c 'settings/websockets' <<<"${retry_pass_log}")"

    retry_fail_log=$(run_interactive_ws_retry_case off)
    assert_not_contains "交互重试后仍 off：非零阻断" "${retry_fail_log}" "STATUS=0"
    assert_not_contains "交互重试后仍 off：不创建 DNS" "${retry_fail_log}" "DNS "
    assert_equal "交互重试后仍 off：恰查询 2 次 WebSockets（仅 1 次重试机会）" "2" \
        "$(grep -c 'settings/websockets' <<<"${retry_fail_log}")"
else
    skip_case "WebSockets 交互重试（on/off）" "当前环境没有可用 pty（pty.openpty 失败）"
fi

# --- 3. 模式 1 的 DNS 归属常量：创建、复用与 purge 使用同一契约 -----------------
run_dns_case() { # $1=create|reuse|purge|purge-takeover|foreign
    local case_name=$1 case_status=0
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
    ) </dev/null >"${log}.out" 2>"${log}.err" || case_status=$?
    # 用例在 $( ) 里跑（要捕获 API 日志），变量带不出来：调用方按返回值取退出码。
    RUN_DNS_CASE_STATUS=${case_status}
    cat "${log}"
    return "${case_status}"
}

# 用例退出码：$( ) 里的赋值传不回来，所以用「调用失败时赋值」的形态留在调用方。
RUN_DNS_CASE_STATUS=0
create_log=$(run_dns_case create) || RUN_DNS_CASE_STATUS=$?
assert_equal "模式 1 创建用例退出 0" "0" "${RUN_DNS_CASE_STATUS}"
assert_contains "模式 1 创建记录使用模式专属注释" "${create_log}" "easy_all cloudflare"
assert_contains "模式 1 创建记录是 POST" "${create_log}" "POST /zones/zoneid/dns_records"

RUN_DNS_CASE_STATUS=0
reuse_log=$(run_dns_case reuse) || RUN_DNS_CASE_STATUS=$?
assert_equal "模式 1 复用用例退出 0" "0" "${RUN_DNS_CASE_STATUS}"
assert_not_contains "模式 1 复用受管记录不写入" "${reuse_log}" "POST "
assert_not_contains "模式 1 复用受管记录不改写" "${reuse_log}" "PATCH "
# 正向锚点：复用路径必须先读到现有记录；否则「没有 POST/PATCH」会被「什么都没做」伪通过。
assert_contains "模式 1 复用路径确实读取了记录" "${reuse_log}" "GET /zones/zoneid/dns_records"
[[ ! -s "${TMP_DIR}/dns-reuse.log.err" ]] \
    || fail "模式 1 复用路径不得向 stderr 输出：$(<"${TMP_DIR}/dns-reuse.log.err")"

RUN_DNS_CASE_STATUS=0
purge_log=$(run_dns_case purge) || RUN_DNS_CASE_STATUS=$?
assert_equal "模式 1 purge 用例退出 0" "0" "${RUN_DNS_CASE_STATUS}"
assert_contains "模式 1 purge 删除受管记录" "${purge_log}" \
    "DELETE /zones/zoneid/dns_records/rec1"
assert_not_contains "模式 1 purge 不修改记录" "${purge_log}" "PATCH "

purge_takeover_log=$(run_dns_case purge-takeover) || true
assert_not_contains "强制接管的记录在 purge 时不得删除" "${purge_takeover_log}" "DELETE "
assert_contains "强制接管的记录在 purge 时说明保留原因" \
    "$(cat "${TMP_DIR}/dns-purge-takeover.log.out" 2>/dev/null || true)" "来自强制接管"

foreign_log=$(run_dns_case foreign) || true
assert_not_contains "第三方注释的记录不被接管" "${foreign_log}" "POST "
assert_not_contains "第三方注释的记录不被改写" "${foreign_log}" "PATCH "
assert_not_contains "第三方注释的记录不被删除" "${foreign_log}" "DELETE "

# --- 3.5 A2：cloudfront 卸载的 NoSuchDistribution 语义（入口 / 禁用等待后 / 归属不符 / 正常）---
# 假 aws 按官方响应形状回放（ETag + DistributionConfig、禁用后 Enabled=false、Deployed），
# 形态借用 test_cloud_purge.sh 的「功能版假 aws」，但只保留卸载路径实际用到的子命令。
aws_case_bin="${TMP_DIR}/aws-bin"
mkdir -p "${aws_case_bin}"
cat >"${aws_case_bin}/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${AWS_CALLS}"
args=("$@")
service="" op="" id="" arn=""
for i in "${!args[@]}"; do
    case "${args[$i]}" in
    cloudfront | acm) service=${args[$i]}; op=${args[$((i + 1))]:-}; break ;;
    esac
done
for i in "${!args[@]}"; do
    case "${args[$i]}" in
    --id) id=${args[$((i + 1))]:-} ;;
    --certificate-arn) arn=${args[$((i + 1))]:-} ;;
    esac
done
n=$(cat "${AWS_STATE}/count-${service}-${op}" 2>/dev/null || printf '0')
n=$((n + 1))
printf '%s' "${n}" >"${AWS_STATE}/count-${service}-${op}"

no_such_distribution() {
    printf 'An error occurred (NoSuchDistribution) when calling the GetDistributionConfig operation: The specified distribution does not exist.\n' >&2
    exit 254
}
distribution_config() { # $1=Enabled
    printf '{"ETag":"ETAG1-D1","DistributionConfig":{"Comment":"%s","Enabled":%s,"Aliases":{"Quantity":2,"Items":["%s","%s"]},"Origins":{"Quantity":1,"Items":[{"Id":"o1","DomainName":"%s"}]}}}\n' \
        "${AWS_COMMENT}" "$1" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" "${CF_ORIGIN_DOMAIN}"
}
case "${service} ${op}" in
"cloudfront get-distribution-config")
    case "${AWS_MODE:-normal}" in
    entry-gone) no_such_distribution ;;
    gone-after-disable)
        # 入口那次成功；删除前复校那一次（第 2 次）已不存在。
        ((n == 1)) || no_such_distribution
        distribution_config true
        ;;
    read-error)
        printf 'An error occurred (AccessDenied) when calling the GetDistributionConfig operation: not authorized\n' >&2
        exit 254
        ;;
    stderr-noise)
        # 成功但 stderr 带告警（真实 CLI 的配置/凭据提示就是这样）：stdout 的 JSON 不得被污染。
        printf 'Warning: config file /root/.aws/config contains an invalid profile section\n' >&2
        distribution_config true
        ;;
    foreign) # 分发存在但 Comment 不是本链路的 marker → 归属校验失败
        printf '{"ETag":"ETAG1-D1","DistributionConfig":{"Comment":"hand-managed","Enabled":true,"Aliases":{"Quantity":2,"Items":["%s","%s"]},"Origins":{"Quantity":1,"Items":[{"Id":"o1","DomainName":"%s"}]}}}\n' \
            "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" "${CF_ORIGIN_DOMAIN}"
        ;;
    *) distribution_config true ;;
    esac
    ;;
"cloudfront update-distribution")
    printf '{}\n'
    ;;
"cloudfront get-distribution")
    # 真实服务要等禁用传播完成；这里直接回放已 Deployed + Enabled=false。
    printf '{"Distribution":{"Status":"Deployed","DistributionConfig":{"Enabled":false}}}\n'
    ;;
"cloudfront delete-distribution")
    printf '{}\n'
    ;;
"acm describe-certificate")
    printf '{"Certificate":{"DomainName":"%s","Status":"ISSUED","CertificateArn":"%s","SubjectAlternativeNames":["%s"],"InUseBy":[],"DomainValidationOptions":[]}}\n' \
        "${CF_NODE_DOMAIN}" "${arn}" "${SUBSCRIPTION_DOMAIN}"
    ;;
"acm list-tags-for-certificate")
    printf '{"Tags":[{"Key":"easy_all","Value":"managed"},{"Key":"easy_all-node","Value":"%s"}]}\n' "${CF_NODE_DOMAIN}"
    ;;
"acm delete-certificate")
    printf '{}\n'
    ;;
*)
    printf 'fake aws: unexpected call: %s\n' "$*" >&2
    exit 254
    ;;
esac
FAKE_AWS
chmod +x "${aws_case_bin}/aws"

run_aws_uninstall_case() { # $1=模式名；输出 aws 调用日志与退出码行
    local mode=$1
    local root="${TMP_DIR}/aws-case-${mode}"
    rm -rf "${root}"
    mkdir -p "${root}/runtime" "${root}/state" "${root}/aws"
    : >"${root}/aws.calls"
    : >"${root}/dns.calls"
    (
        set -Eeuo pipefail
        export PATH="${aws_case_bin}:${PATH}"
        export AWS_CALLS="${root}/aws.calls"
        export AWS_STATE="${root}/aws"
        export AWS_MODE="${mode}"
        export RUNTIME_TMP="${root}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${root}/state"
        export EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${root}/takeover.log"
        source "${ROOT_DIR}/profiles/cloudfront.sh"
        # 假 aws 是独立进程：这些上下文必须 export，否则子进程 set -u 直接报错。
        export CF_NODE_DOMAIN=cf.example.com
        export SUBSCRIPTION_DOMAIN=sub.cf.example.com
        export CF_ORIGIN_DOMAIN=origin.example.com
        export AWS_COMMENT="easy_all-cloudfront-cf.example.com"
        CLOUDFLARE_ZONE_ID=zoneid
        CLOUDFLARE_API_TOKEN="fake-token-abcdefghijklmnop"
        VPS_PUBLIC_IPV4=203.0.113.10
        AWS_CLOUDFRONT_DISTRIBUTION_ID=D1
        AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:${AWS_CONTROL_REGION}:123456789012:certificate/C1"
        AWS_ACCESS_KEY_ID=AKIAFAKEEXAMPLE0
        AWS_SECRET_ACCESS_KEY=fake-secret-key-value
        # DNS 侧只验「删除被调用」，记录形状用最简受管记录。
        cloudflare_record_list() {
            printf '[{"id":"rec1","type":"A","name":"%s","content":"%s","proxied":false,"comment":"easy_all cloudfront","ttl":300}]\n' \
                "$3" "${VPS_PUBLIC_IPV4}"
        }
        cloudflare_api_request() {
            local method=$1 path=$2
            printf '%s %s\n' "${method}" "${path}" >>"${root}/dns.calls"
            printf 'null\n'
        }
        status=0
        cdn_purge_aws_resources || status=$?
        printf 'PURGE_STATUS=%s\n' "${status}"
    ) </dev/null >"${root}/out" 2>"${root}/err" || true
    printf 'STATUS_LINE=%s\n' "$(grep -o 'PURGE_STATUS=[0-9]*' "${root}/out" | tail -n 1)"
}

# (a) 入口处分发已不存在：仍清理 ACM 与 DNS，退出 0。
run_aws_uninstall_case entry-gone >/dev/null
entry_gone_calls=$(<"${TMP_DIR}/aws-case-entry-gone/aws.calls")
entry_gone_dns=$(<"${TMP_DIR}/aws-case-entry-gone/dns.calls")
assert_contains "A2(a) 入口分发已不存在仍删除 ACM 证书" "${entry_gone_calls}" "acm delete-certificate"
assert_contains "A2(a) 入口分发已不存在仍删除 Cloudflare DNS" "${entry_gone_dns}" "DELETE /zones/zoneid/dns_records/rec1"
assert_contains "A2(a) 说明分发已不存在" "$(<"${TMP_DIR}/aws-case-entry-gone/out")" "云端分发已不存在"
assert_not_contains "A2(a) 不再尝试禁用分发" "${entry_gone_calls}" "cloudfront update-distribution"

# (b) 禁用等待期内分发被删：删除前复校命中 NoSuchDistribution，仍清理 ACM 与 DNS。
run_aws_uninstall_case gone-after-disable >/dev/null
after_calls=$(<"${TMP_DIR}/aws-case-gone-after-disable/aws.calls")
after_dns=$(<"${TMP_DIR}/aws-case-gone-after-disable/dns.calls")
assert_contains "A2(b) 等待期内被删仍删除 ACM 证书" "${after_calls}" "acm delete-certificate"
assert_contains "A2(b) 等待期内被删仍删除 Cloudflare DNS" "${after_dns}" "DELETE /zones/zoneid/dns_records/rec1"
assert_contains "A2(b) 说明等待期内已被删除" "$(<"${TMP_DIR}/aws-case-gone-after-disable/out")" "禁用等待期内已被删除"
assert_not_contains "A2(b) 不再调用 delete-distribution" "${after_calls}" "cloudfront delete-distribution"

# (c) 归属不符：分发存在但 Comment 不匹配 → 跳过 ACM 与 DNS，且有告警。
run_aws_uninstall_case foreign >/dev/null
foreign_calls=$(<"${TMP_DIR}/aws-case-foreign/aws.calls")
foreign_dns=$(<"${TMP_DIR}/aws-case-foreign/dns.calls")
assert_contains "A2(c) 归属不符要告警" \
    "$(<"${TMP_DIR}/aws-case-foreign/out")$(<"${TMP_DIR}/aws-case-foreign/err")" "分发未通过归属校验"
assert_equal "A2(c) 归属不符不调用 ACM 删除" "0" \
    "$(grep -c 'acm delete-certificate' "${TMP_DIR}/aws-case-foreign/aws.calls" || true)"
assert_equal "A2(c) 归属不符不发起 DNS DELETE" "0" "$(grep -c '^DELETE ' "${TMP_DIR}/aws-case-foreign/dns.calls" || true)"
assert_equal "A2(c) 归属不符不删除分发" "0" \
    "$(grep -c 'cloudfront delete-distribution' "${TMP_DIR}/aws-case-foreign/aws.calls" || true)"

# (e) 成功但 stderr 有噪音：stdout 独占 description，ETag 必须照常解析（否则跳过清理留孤儿）。
run_aws_uninstall_case stderr-noise >/dev/null
noise_calls=$(<"${TMP_DIR}/aws-case-stderr-noise/aws.calls")
noise_dns=$(<"${TMP_DIR}/aws-case-stderr-noise/dns.calls")
noise_out=$(<"${TMP_DIR}/aws-case-stderr-noise/out")
assert_not_contains "A2(e) stderr 噪音不得导致「缺少分发 ETag」" "${noise_out}" "缺少分发 ETag"
assert_contains "A2(e) stderr 噪音下仍禁用分发" "${noise_calls}" "cloudfront update-distribution"
assert_contains "A2(e) stderr 噪音下仍删除分发" "${noise_calls}" "cloudfront delete-distribution"
assert_contains "A2(e) stderr 噪音下仍清理 ACM" "${noise_calls}" "acm delete-certificate"
assert_contains "A2(e) stderr 噪音下仍清理 DNS" "${noise_dns}" "DELETE /zones/zoneid/dns_records/rec1"

# (f) 读取失败：告警必须带出真实原因（stderr 首行），而不是只有固定文案。
run_aws_uninstall_case read-error >/dev/null
assert_contains "A2(f) 读取失败要点名 ID" \
    "$(<"${TMP_DIR}/aws-case-read-error/out")$(<"${TMP_DIR}/aws-case-read-error/err")" \
    "读取 CloudFront 分发失败（ID：D1）"
assert_contains "A2(f) 读取失败要带出 stderr 首行原因" \
    "$(<"${TMP_DIR}/aws-case-read-error/out")$(<"${TMP_DIR}/aws-case-read-error/err")" \
    "AccessDenied"

# (d) 正常路径：禁用 → 等 Deployed → 删除 → 再清理 ACM 与 DNS。
run_aws_uninstall_case normal >/dev/null
normal_calls=$(<"${TMP_DIR}/aws-case-normal/aws.calls")
normal_dns=$(<"${TMP_DIR}/aws-case-normal/dns.calls")
assert_contains "A2(d) 先禁用分发" "${normal_calls}" "cloudfront update-distribution"
assert_contains "A2(d) 等待禁用传播" "${normal_calls}" "cloudfront get-distribution"
assert_contains "A2(d) 删除分发" "${normal_calls}" "cloudfront delete-distribution"
assert_contains "A2(d) 删除后清理 ACM" "${normal_calls}" "acm delete-certificate"
assert_contains "A2(d) 删除后清理 Cloudflare DNS" "${normal_dns}" "DELETE /zones/zoneid/dns_records/rec1"
assert_contains "A2(d) 报告分发已删除" "$(<"${TMP_DIR}/aws-case-normal/out")" "CloudFront 分发已删除"

# --- 3.3 A40：CloudFront 卸载的阶段进度与 ACM validation CNAME 安全清理 ------------------
# 假 aws 回放真实服务形状：分发首轮 InProgress/Disabled → 次轮 Deployed/Disabled；ACM 首轮带
# InUseBy → 次轮收敛；验证记录名/值带末尾点号（Cloudflare 上存的是去点后的值）。
validation_bin="${TMP_DIR}/validation-bin"
mkdir -p "${validation_bin}"
cat >"${validation_bin}/aws" <<'FAKE_AWS_VALIDATION'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${V_AWS_LOG}"
args=("$@")
service=""
op=""
arn=""
for i in "${!args[@]}"; do
    case "${args[$i]}" in
    cloudfront | acm)
        service=${args[$i]}
        op=${args[$((i + 1))]:-}
        break
        ;;
    esac
done
for i in "${!args[@]}"; do
    [[ "${args[$i]}" != "--certificate-arn" ]] || arn=${args[$((i + 1))]:-}
done
record_json() { # $1=DomainName $2=ResourceRecord 名 $3=ResourceRecord 值
    printf '{"DomainName":"%s","ResourceRecord":{"Name":"%s","Type":"CNAME","Value":"%s"}}' \
        "$1" "$2" "$3"
}
case "${service} ${op}" in
"cloudfront get-distribution-config")
    printf '{"ETag":"ETAG-V1","DistributionConfig":{"Comment":"%s","Enabled":true,"Aliases":{"Quantity":2,"Items":["%s","%s"]},"Origins":{"Quantity":1,"Items":[{"Id":"o1","DomainName":"%s"}]}}}\n' \
        "${V_DIST_COMMENT}" "${V_NODE_DOMAIN}" "${V_SUB_DOMAIN}" "${V_ORIGIN_DOMAIN}"
    ;;
"cloudfront update-distribution") printf '{}\n' ;;
"cloudfront get-distribution")
    n=$(cat "${V_STATE}/dist-calls" 2>/dev/null || printf '0')
    n=$((n + 1))
    printf '%s' "${n}" >"${V_STATE}/dist-calls"
    # 首轮回放上一次部署值：只按 Status 判定的实现会拿过期配置去 delete。
    if ((n == 1)); then
        printf '{"Distribution":{"Status":"InProgress","DistributionConfig":{"Enabled":false}}}\n'
    else
        printf '{"Distribution":{"Status":"Deployed","DistributionConfig":{"Enabled":false}}}\n'
    fi
    ;;
"cloudfront delete-distribution") printf '{}\n' ;;
"acm list-certificates")
    [[ "${V_OTHER}" != "list-fail" ]] \
        || { printf 'AccessDenied: acm:ListCertificates\n' >&2; exit 254; }
    printf '{"CertificateSummaryList":[{"CertificateArn":"%s"},{"CertificateArn":"%s"}]}\n' \
        "${V_OWN_ARN}" "${V_OTHER_ARN}"
    ;;
"acm list-tags-for-certificate")
    node=${V_NODE_DOMAIN}
    [[ "${V_TAGS}" != "foreign" ]] || node="someone-else.example.com"
    printf '{"Tags":[{"Key":"easy_all","Value":"managed"},{"Key":"easy_all-node","Value":"%s"}]}\n' \
        "${node}"
    ;;
"acm describe-certificate")
    if [[ "${arn}" == "${V_OWN_ARN}" ]]; then
        m=$(cat "${V_STATE}/inuse-calls" 2>/dev/null || printf '0')
        m=$((m + 1))
        printf '%s' "${m}" >"${V_STATE}/inuse-calls"
        inuse='["EDFDVBD6EXAMPLE"]'
        if [[ "${V_INUSE}" == "settle" ]] && ((m >= 2)); then
            inuse='[]'
        fi
        printf '{"Certificate":{"DomainName":"%s","Status":"ISSUED","CertificateArn":"%s","SubjectAlternativeNames":["%s"],"InUseBy":%s,"DomainValidationOptions":[%s,%s]}}\n' \
            "${V_NODE_DOMAIN}" "${arn}" "${V_SUB_DOMAIN}" "${inuse}" \
            "$(record_json "${V_NODE_DOMAIN}" "_x1.${V_NODE_DOMAIN}." "_v1.acm-validations.aws.")" \
            "$(record_json "${V_SUB_DOMAIN}" "_x2.${V_SUB_DOMAIN}." "_v2.acm-validations.aws.")"
    else
        # 其他证书：reuse 时引用同一条 _x1 验证记录，否则是另一个域名的记录。
        if [[ "${V_OTHER}" == "reuse" ]]; then
            printf '{"Certificate":{"DomainName":"%s","Status":"ISSUED","CertificateArn":"%s","InUseBy":[],"DomainValidationOptions":[%s]}}\n' \
                "${V_NODE_DOMAIN}" "${arn}" \
                "$(record_json "${V_NODE_DOMAIN}" "_x1.${V_NODE_DOMAIN}." "_v1.acm-validations.aws.")"
        else
            printf '{"Certificate":{"DomainName":"other.example.com","Status":"ISSUED","CertificateArn":"%s","InUseBy":[],"DomainValidationOptions":[%s]}}\n' \
                "${arn}" \
                "$(record_json "other.example.com" "_x9.other.example.com." "_v9.acm-validations.aws.")"
        fi
    fi
    ;;
"acm delete-certificate")
    [[ "${V_DELETE_FAIL}" != "1" ]] \
        || { printf 'AccessDenied: acm:DeleteCertificate\n' >&2; exit 254; }
    printf '{}\n'
    ;;
*)
    printf 'fake aws: unexpected call: %s\n' "$*" >&2
    exit 254
    ;;
esac
FAKE_AWS_VALIDATION
chmod +x "${validation_bin}/aws"

# 调用方参数：$1=用例名 $2=其他证书(none|reuse|list-fail) $3=delete 失败(0|1)
# $4=业务记录注释(managed|foreign) $5=验证记录被接管(0|1) $6=ACM 管理标记(managed|foreign)
run_validation_purge_case() {
    local name=$1 other=$2 delete_fail=$3 comment=$4 takeover=$5 tags=$6
    local root="${TMP_DIR}/validation-${name}"
    rm -rf -- "${root}"
    mkdir -p "${root}/runtime" "${root}/state" "${root}/aws"
    : >"${root}/aws.calls"
    : >"${root}/dns.calls"
    if [[ "${takeover}" == "1" ]]; then
        printf '{"ts":"2025-01-01T00:00:00Z","host":"_x1.cf.example.com","old_comment":"foreign","old_content":"198.51.100.20","old_proxied":"false","old_ttl":"300"}\n' \
            >"${root}/takeover.log"
    fi
    (
        set -Eeuo pipefail
        export PATH="${validation_bin}:${PATH}"
        export V_AWS_LOG="${root}/aws.calls"
        export V_STATE="${root}/aws"
        export V_OTHER="${other}"
        export V_DELETE_FAIL="${delete_fail}"
        export V_TAGS="${tags}"
        export V_INUSE="settle"
        export RUNTIME_TMP="${root}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${root}/state"
        export EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${root}/takeover.log"
        source "${ROOT_DIR}/profiles/cloudfront.sh"
        export V_OWN_ARN="arn:aws:acm:${AWS_CONTROL_REGION}:123456789012:certificate/C1"
        export V_OTHER_ARN="arn:aws:acm:${AWS_CONTROL_REGION}:123456789012:certificate/C2"
        export V_NODE_DOMAIN=cf.example.com
        export V_SUB_DOMAIN=sub.cf.example.com
        export V_ORIGIN_DOMAIN=origin.example.com
        export V_DIST_COMMENT="easy_all-cloudfront-cf.example.com"
        export CF_NODE_DOMAIN="${V_NODE_DOMAIN}"
        export SUBSCRIPTION_DOMAIN="${V_SUB_DOMAIN}"
        export CF_ORIGIN_DOMAIN="${V_ORIGIN_DOMAIN}"
        export AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
        CLOUDFLARE_ZONE_ID=zoneid
        CLOUDFLARE_API_TOKEN="fake-token-abcdefghijklmnop"
        VPS_PUBLIC_IPV4=203.0.113.10
        AWS_CLOUDFRONT_DISTRIBUTION_ID=D1
        AWS_ACM_CERTIFICATE_ARN="${V_OWN_ARN}"
        AWS_ACCESS_KEY_ID=AKIAVALIDATIONCNAME01
        AWS_SECRET_ACCESS_KEY=validation-cname-secret
        record_comment="easy_all cloudfront"
        [[ "${comment}" != "foreign" ]] || record_comment="hand-managed"
        # Cloudflare 上存的是去点号后的值；注释与内容都可按用例变化。
        cloudflare_record_list() {
            local type=$2 host=$3 content
            case "${host}" in
            _x1.cf.example.com) content=_v1.acm-validations.aws ;;
            _x2.sub.cf.example.com) content=_v2.acm-validations.aws ;;
            *)
                if [[ "${type}" == "A" ]]; then
                    content=203.0.113.10
                else
                    content=d111111abcdef8.cloudfront.net
                fi
                ;;
            esac
            printf '[{"id":"rec-%s-%s","type":"%s","name":"%s","content":"%s","proxied":false,"comment":"%s","ttl":300}]\n' \
                "${host}" "${type}" "${type}" "${host}" "${content}" "${record_comment}"
        }
        cloudflare_api_request() {
            local method=$1 path=$2
            printf '%s %s\n' "${method}" "${path}" >>"${root}/dns.calls"
            printf 'null\n'
        }
        sleep() { :; }
        status=0
        cdn_purge_aws_resources || status=$?
        printf 'PURGE_STATUS=%s\n' "${status}"
    ) </dev/null >"${root}/out" 2>"${root}/err" || true
}

purge_case_status() { # $1=用例名
    sed -n 's/^PURGE_STATUS=//p' "${TMP_DIR}/validation-$1/out" | tail -n 1
}

# (a) 正常路径：分发禁用等待 + ACM 占用等待 + 证书删除 + 验证记录一并清理，全阶斵有进度。
run_validation_purge_case clean none 0 managed 0 managed
clean_out=$(<"${TMP_DIR}/validation-clean/out")
clean_err=$(<"${TMP_DIR}/validation-clean/err")
clean_aws=$(<"${TMP_DIR}/validation-clean/aws.calls")
clean_dns=$(<"${TMP_DIR}/validation-clean/dns.calls")
assert_equal "A40(a) 清理退出 0" "0" "$(purge_case_status clean)"
assert_contains "A40(a) 输出分发校验进度" "${clean_out}" "正在校验 CloudFront 分发归属：D1"
assert_contains "A40(a) 输出禁用进度" "${clean_out}" "正在禁用 CloudFront 分发：D1"
assert_contains "A40(a) 输出分发状态轮询进度" "${clean_out}" \
    "正在等待 CloudFront 分发状态收敛（目标 Enabled=false，当前 Status=InProgress"
assert_contains "A40(a) 输出分发删除进度" "${clean_out}" "正在删除 CloudFront 分发：D1"
assert_contains "A40(a) 输出分发删除结果" "${clean_out}" "CloudFront 分发已删除：D1"
assert_contains "A40(a) 输出 ACM 校验进度" "${clean_out}" "正在校验 ACM 证书归属与占用状态"
assert_contains "A40(a) 输出 ACM 删除进度" "${clean_out}" \
    "正在删除 ACM 证书：arn:aws:acm:us-east-1:123456789012:certificate/C1"
assert_contains "A40(a) ACM 删除结果点名 ARN" "${clean_out}" \
    "ACM 证书已删除：arn:aws:acm:us-east-1:123456789012:certificate/C1"
assert_contains "A40(a) 输出 DNS 清理入口" "${clean_out}" "正在清理 Cloudflare DNS 记录"
assert_contains "A40(a) 每条删除有结果" "${clean_out}" \
    "已删除 Cloudflare CNAME 记录：_x1.cf.example.com -> _v1.acm-validations.aws"
assert_contains "A40(a) 无保留时汇总为完成" "${clean_out}" "Cloudflare DNS 清理完成"
assert_contains "A40(a) 校验同账号其他证书" "${clean_aws}" "acm list-certificates"
assert_contains "A40(a) 删除节点域名验证记录" "${clean_dns}" \
    "DELETE /zones/zoneid/dns_records/rec-_x1.cf.example.com-CNAME"
assert_contains "A40(a) 删除订阅域名验证记录" "${clean_dns}" \
    "DELETE /zones/zoneid/dns_records/rec-_x2.sub.cf.example.com-CNAME"
assert_not_contains "A40(a) 分发阶段进度仍走 stdout（日志契约不变）" "${clean_err}" "正在禁用 CloudFront 分发"

# 等待 ACM 解除占用的进度必须走 stderr：该函数的 stdout 就是返回给调用方的 JSON。
run_acm_settle_stdout_case() {
    local root="${TMP_DIR}/validation-acm-stdout"
    rm -rf -- "${root}"
    mkdir -p "${root}/runtime" "${root}/state" "${root}/aws"
    (
        set -Eeuo pipefail
        export PATH="${validation_bin}:${PATH}"
        export V_AWS_LOG="${root}/aws.calls"
        export V_STATE="${root}/aws"
        export V_OTHER="none"
        export V_DELETE_FAIL="0"
        export V_TAGS="managed"
        export V_INUSE="settle"
        export RUNTIME_TMP="${root}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${root}/state"
        source "${ROOT_DIR}/profiles/cloudfront.sh"
        export V_OWN_ARN="arn:aws:acm:${AWS_CONTROL_REGION}:123456789012:certificate/C1"
        export V_OTHER_ARN="arn:aws:acm:${AWS_CONTROL_REGION}:123456789012:certificate/C2"
        export V_NODE_DOMAIN=cf.example.com
        export V_SUB_DOMAIN=sub.cf.example.com
        export V_ORIGIN_DOMAIN=origin.example.com
        export V_DIST_COMMENT="easy_all-cloudfront-cf.example.com"
        sleep() { :; }
        describe_settled_acm_certificate "${V_OWN_ARN}"
    ) </dev/null >"${root}/out" 2>"${root}/err" || true
}
run_acm_settle_stdout_case
jq -e '.Certificate.DomainName == "cf.example.com"' "${TMP_DIR}/validation-acm-stdout/out" >/dev/null 2>&1 \
    || fail "A40(b) 等待进度污染了 describe_settled_acm_certificate 的 JSON 返回值：$(<"${TMP_DIR}/validation-acm-stdout/out")"
assert_contains "A40(b) ACM 占用等待进度走 stderr" \
    "$(<"${TMP_DIR}/validation-acm-stdout/err")" "正在等待 ACM 证书解除分发占用"
assert_not_contains "A40(b) ACM 占用等待进度不进 stdout" \
    "$(<"${TMP_DIR}/validation-acm-stdout/out")" "正在等待"

# (b) 同账号其他证书引用同一条验证记录：保留 _x1，仍清理 _x2，汇总不得误报为完成。
run_validation_purge_case reuse reuse 0 managed 0 managed
reuse_out=$(<"${TMP_DIR}/validation-reuse/out")
reuse_dns=$(<"${TMP_DIR}/validation-reuse/dns.calls")
assert_equal "A40(c) 复用保护下仍退出 0" "0" "$(purge_case_status reuse)"
assert_not_contains "A40(c) 被其他证书引用的验证记录不得删除" "${reuse_dns}" \
    "dns_records/rec-_x1.cf.example.com-CNAME"
assert_contains "A40(c) 未被引用的验证记录仍然删除" "${reuse_dns}" \
    "dns_records/rec-_x2.sub.cf.example.com-CNAME"
assert_contains "A40(c) 点名引用该记录的证书 ARN" "${reuse_out}" \
    "仍被同账号其他 ACM 证书引用（arn:aws:acm:us-east-1:123456789012:certificate/C2）；保留"
assert_contains "A40(c) 有保留时汇总不得声称完成" "${reuse_out}" \
    "Cloudflare DNS 清理结束（部分记录按归属或复用保护规则保留，见上方告警）"
assert_not_contains "A40(c) 不得同时输出清理完成" "${reuse_out}" "Cloudflare DNS 清理完成"

# (c) 枚举失败（权限不足）：保守保留全部验证记录，业务 DNS 照常清理。
run_validation_purge_case list-fail list-fail 0 managed 0 managed
list_fail_out=$(<"${TMP_DIR}/validation-list-fail/out")
list_fail_dns=$(<"${TMP_DIR}/validation-list-fail/dns.calls")
assert_equal "A40(d) 枚举失败不阻断卸载" "0" "$(purge_case_status list-fail)"
assert_not_contains "A40(d) 枚举失败时保留 _x1 验证记录" "${list_fail_dns}" \
    "rec-_x1.cf.example.com-CNAME"
assert_not_contains "A40(d) 枚举失败时保留 _x2 验证记录" "${list_fail_dns}" \
    "rec-_x2.sub.cf.example.com-CNAME"
assert_contains "A40(d) 枚举失败要告警" "${list_fail_out}" \
    "无法完整枚举同账号其他 ACM 证书（权限或接口失败）；保守保留 ACM validation CNAME"
assert_contains "A40(d) 业务 DNS 仍被清理" "${list_fail_dns}" \
    "DELETE /zones/zoneid/dns_records/rec-origin.example.com-A"
assert_contains "A40(d) 保守保留时汇总不得声称完成" "${list_fail_out}" \
    "Cloudflare DNS 清理结束（部分记录按归属或复用保护规则保留，见上方告警）"

# (d) 删除证书失败：验证记录必须留存，且不必再去枚举其他证书。
run_validation_purge_case delete-fail none 1 managed 0 managed
delete_fail_out=$(<"${TMP_DIR}/validation-delete-fail/out")
delete_fail_dns=$(<"${TMP_DIR}/validation-delete-fail/dns.calls")
assert_equal "A40(e) 删除证书失败退出非零" "1" "$(purge_case_status delete-fail)"
assert_contains "A40(e) 说明验证记录随证书保留" "${delete_fail_out}" \
    "删除 ACM 证书失败：arn:aws:acm:us-east-1:123456789012:certificate/C1；保留其 ACM validation CNAME"
assert_not_contains "A40(e) 不得删除验证记录" "${delete_fail_dns}" "acm-validations"
assert_equal "A40(e) 证书未删时不做复用枚举" "0" \
    "$(grep -c 'acm list-certificates' "${TMP_DIR}/validation-delete-fail/aws.calls" || true)"

# (e) ACM 归属校验失败：不删证书，也不删验证记录。
run_validation_purge_case tags-foreign none 0 managed 0 foreign
tags_foreign_out=$(<"${TMP_DIR}/validation-tags-foreign/out")
assert_equal "A40(f) 归属不符退出非零" "1" "$(purge_case_status tags-foreign)"
assert_contains "A40(f) 归属不符要告警并声明保留验证记录" "${tags_foreign_out}" \
    "跳过其 validation CNAME 清理"
assert_not_contains "A40(f) 归属不符不删验证记录" \
    "$(<"${TMP_DIR}/validation-tags-foreign/dns.calls")" "acm-validations"
assert_equal "A40(f) 归属不符不调用删除证书" "0" \
    "$(grep -c 'acm delete-certificate' "${TMP_DIR}/validation-tags-foreign/aws.calls" || true)"

# (f) 验证记录来自强制接管：即使证书已删、归属匹配也保留。
run_validation_purge_case takeover none 0 managed 1 managed
takeover_dns=$(<"${TMP_DIR}/validation-takeover/dns.calls")
assert_not_contains "A40(g) 接管来的验证记录不得删除" "${takeover_dns}" \
    "rec-_x1.cf.example.com-CNAME"
assert_contains "A40(g) 说明保留原因" "$(<"${TMP_DIR}/validation-takeover/out")" "来自强制接管"
assert_contains "A40(g) 未接管的验证记录仍删除" "${takeover_dns}" \
    "rec-_x2.sub.cf.example.com-CNAME"

# (g) 注释不符：验证记录不是本工具写的，保留。
run_validation_purge_case comment-foreign none 0 foreign 0 managed
comment_dns=$(<"${TMP_DIR}/validation-comment-foreign/dns.calls")
assert_not_contains "A40(h) 注释不符的验证记录不得删除" "${comment_dns}" "acm-validations"
assert_contains "A40(h) 注释不符要点名保留" "$(<"${TMP_DIR}/validation-comment-foreign/out")" \
    "不是本链路创建的"

# --- 3.35 A8：marker 发现路径上的 PENDING_VALIDATION 必须放行（不得 die）-------------
# find_existing_acm_certificate 是「无状态复用」路径：证书带本节点管理标记但还在等待签发，
# 必须交下游「写验证记录 → 轮询签发」，而不是 die 掉（否则重装死锁永远解不开）。
acm_bin="${TMP_DIR}/acm-bin"
mkdir -p "${acm_bin}"
cat >"${acm_bin}/aws" <<'FAKE_AWS'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${ACM_CALLS}"
case " $* " in
*" acm list-certificates "*)
    printf '{"CertificateSummaryList":[{"CertificateArn":"%s"}]}\n' "${ACM_ARN}"
    ;;
*" acm list-tags-for-certificate "*)
    printf '{"Tags":[{"Key":"easy_all","Value":"managed"},{"Key":"easy_all-node","Value":"%s"}]}\n' \
        "${CF_NODE_DOMAIN}"
    ;;
*" acm describe-certificate "*)
    printf '{"Certificate":{"DomainName":"%s","Status":"%s","CertificateArn":"%s","SubjectAlternativeNames":["%s"],"InUseBy":[]}}\n' \
        "${CF_NODE_DOMAIN}" "${ACM_STATUS}" "${ACM_ARN}" "${SUBSCRIPTION_DOMAIN}"
    ;;
*) printf '{}\n' ;;
esac
FAKE_AWS
chmod +x "${acm_bin}/aws"

run_acm_discovery_case() { # $1=Status；输出发现结果与状态行
    local status=$1
    local root="${TMP_DIR}/acm-${status}"
    rm -rf "${root}"
    mkdir -p "${root}/runtime"
    (
        set -Eeuo pipefail
        export PATH="${acm_bin}:${PATH}"
        export RUNTIME_TMP="${root}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${root}/state"
        export ACM_CALLS="${root}/aws.calls"
        export ACM_ARN="arn:aws:acm:${AWS_CONTROL_REGION:-us-east-1}:123456789012:certificate/C1"
        export ACM_STATUS="${status}"
        export CF_NODE_DOMAIN=cf.example.com
        export SUBSCRIPTION_DOMAIN=sub.cf.example.com
        source "${ROOT_DIR}/profiles/cloudfront.sh"
        # 强制走 marker 发现路径（不设 AWS_ACM_CERTIFICATE_ARN）。
        unset AWS_ACM_CERTIFICATE_ARN
        status_rc=0
        found=$(find_existing_acm_certificate) || status_rc=$?
        printf 'DISCOVERY_RC=%s\nFOUND=%s\n' "${status_rc}" "${found}"
    ) </dev/null >"${root}/out" 2>"${root}/err" || true
    cat "${root}/out"
}

# 等待态：必须放行（输出 ARN、退出 0），不得 die。
acm_pending_out=$(run_acm_discovery_case PENDING_VALIDATION)
acm_pending_rc=$(sed -n 's/^DISCOVERY_RC=//p' <<<"${acm_pending_out}")
assert_equal "A8: marker 发现路径的 PENDING_VALIDATION 放行（退出 0）" "0" "${acm_pending_rc}"
assert_contains "A8: 放行后输出候选 ARN" "${acm_pending_out}" \
    "arn:aws:acm:${AWS_CONTROL_REGION:-us-east-1}:123456789012:certificate/C1"
assert_not_contains "A8: 放行时不得 die" \
    "$(<"${TMP_DIR}/acm-PENDING_VALIDATION/err")" "不可复用"

# 终态：仍然要 die（不放宽归属与终态判定）。
run_acm_discovery_case FAILED >/dev/null
assert_contains "A8: 终态仍然 die" "$(<"${TMP_DIR}/acm-FAILED/err")" "已进入终态"

# --- 3.36 A9：多域名验证记录必须全部写入（旧条件 -ge 1 只会写第一条）---------------
# 判别力来自**响应内容**：入口那次 describe 与轮询第 1 轮都只带 1 条 ResourceRecord，第 2 轮才带 2 条。
# 旧条件 `records -ge 1` 在轮询第 1 轮就 break → 只写第一个域名；新条件要求 `records == total`
# → 必须等到第 2 轮，两个域名的验证记录才都写进 Cloudflare。
acm_dv_bin="${TMP_DIR}/acm-dv-bin"
mkdir -p "${acm_dv_bin}"
cat >"${acm_dv_bin}/aws" <<'FAKE_AWS_DV'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${ACM_DV_CALLS}"
case " $* " in
*" acm request-certificate "*)
    printf '%s\n' "${ACM_DV_ARN}"
    ;;
*" acm describe-certificate "*"--query Certificate.Status"*)
    # 签发轮询：直接回 ISSUED，避免 60 次 × 5s 的空等。
    printf 'ISSUED\n'
    ;;
*" acm describe-certificate "*)
    n=$(cat "${ACM_DV_STATE}/json-calls" 2>/dev/null || printf 0)
    n=$((n + 1))
    printf '%s' "${n}" >"${ACM_DV_STATE}/json-calls"
    if [[ "${ACM_DV_MODE}" == "empty" ]]; then
        printf '{"Certificate":{"DomainName":"%s","Status":"PENDING_VALIDATION","CertificateArn":"%s","SubjectAlternativeNames":["%s"],"InUseBy":[],"DomainValidationOptions":[]}}\n' \
            "${CF_NODE_DOMAIN}" "${ACM_DV_ARN}" "${SUBSCRIPTION_DOMAIN}"
    elif ((n >= 3)); then
        # 轮询第 2 轮起：2 条 ResourceRecord（records == total，循环可以 break）。
        printf '{"Certificate":{"DomainName":"%s","Status":"PENDING_VALIDATION","CertificateArn":"%s","SubjectAlternativeNames":["%s"],"InUseBy":[],"DomainValidationOptions":[
{"DomainName":"%s","ResourceRecord":{"Name":"_x1.%s.","Type":"CNAME","Value":"_v1.acm-validations.aws."}},
{"DomainName":"%s","ResourceRecord":{"Name":"_x2.%s.","Type":"CNAME","Value":"_v2.acm-validations.aws."}}]}}\n' \
            "${CF_NODE_DOMAIN}" "${ACM_DV_ARN}" "${SUBSCRIPTION_DOMAIN}" \
            "${CF_NODE_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"
    else
        # n=1 是入口那次 describe（只用于 status/SAN），n=2 是轮询第 1 轮：两次都只有 1/2 带记录。
        printf '{"Certificate":{"DomainName":"%s","Status":"PENDING_VALIDATION","CertificateArn":"%s","SubjectAlternativeNames":["%s"],"InUseBy":[],"DomainValidationOptions":[
{"DomainName":"%s","ResourceRecord":{"Name":"_x1.%s.","Type":"CNAME","Value":"_v1.acm-validations.aws."}},
{"DomainName":"%s"}]}}\n' \
            "${CF_NODE_DOMAIN}" "${ACM_DV_ARN}" "${SUBSCRIPTION_DOMAIN}" \
            "${CF_NODE_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"
    fi
    ;;
*) printf '{}\n' ;;
esac
FAKE_AWS_DV
chmod +x "${acm_dv_bin}/aws"

run_acm_dv_case() { # $1=staged|empty
    local mode=$1
    local root="${TMP_DIR}/acm-dv-${mode}"
    rm -rf "${root}"
    mkdir -p "${root}/runtime" "${root}/state"
    (
        set -Eeuo pipefail
        export PATH="${acm_dv_bin}:${PATH}"
        export RUNTIME_TMP="${root}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${root}/state"
        export ACM_DV_CALLS="${root}/aws.calls"
        export ACM_DV_STATE="${root}/aws-state"
        export ACM_DV_MODE="${mode}"
        export ACM_DV_ARN="arn:aws:acm:${AWS_CONTROL_REGION:-us-east-1}:123456789012:certificate/C9"
        export CF_NODE_DOMAIN=cf.example.com
        export SUBSCRIPTION_DOMAIN=sub.cf.example.com
        mkdir -p "${ACM_DV_STATE}"
        source "${ROOT_DIR}/profiles/cloudfront.sh"
        # 预置 ARN 跳过“申请新证书”之前的发现分支；幂等 request 由假 aws 回放。
        AWS_ACM_CERTIFICATE_ARN=${ACM_DV_ARN}
        # 外部动作全部桩掉并记录真实调用：落盘、DNS 写入、退避等待。
        persist_install_identity() { :; }
        dns_ensure_record() { printf '%s %s\n' "$1" "$2" >>"${root}/dns.calls"; }
        sleep() { :; }
        rc=0
        find_or_request_acm_certificate || rc=$?
        printf 'ACCEPT_RC=%s\n' "${rc}"
    ) </dev/null >"${root}/out" 2>"${root}/err" || true
}

# 1/2 → 2/2：两个域名的验证记录都必须写入（旧条件只会写 1 条）。
run_acm_dv_case staged
acm_dv_dns=$(<"${TMP_DIR}/acm-dv-staged/dns.calls")
assert_equal "A9: 两个域名的验证记录都被写入（调用 2 次）" "2" \
    "$(grep -c . "${TMP_DIR}/acm-dv-staged/dns.calls" || true)"
assert_contains "A9: 写入节点域名的验证记录" "${acm_dv_dns}" "_x1.cf.example.com"
assert_contains "A9: 写入订阅域名的验证记录" "${acm_dv_dns}" "_x2.sub.cf.example.com"
assert_contains "A9: 整条流程走通" "$(<"${TMP_DIR}/acm-dv-staged/out")" "ACCEPT_RC=0"

# DomainValidationOptions 整体为空：继续等（不 break），最终不写任何记录也不 die。
run_acm_dv_case empty
acm_dv_empty_dns=$(cat "${TMP_DIR}/acm-dv-empty/dns.calls" 2>/dev/null | grep -c . || true)
assert_equal "A9: DV 为空时不写任何验证记录" "0" "${acm_dv_empty_dns}"
assert_contains "A9: DV 为空时流程仍走通（未 break 也未 die）" \
    "$(<"${TMP_DIR}/acm-dv-empty/out")" "ACCEPT_RC=0"

# --- 3.4 purge 的云端清理入口：状态缺 Zone ID 不得提前放弃，Origin CA 吊销必须无条件独立执行 ----
# 状态里没有 CLOUDFLARE_ZONE_ID 时必须先补查（cdn_ensure_zone_id）；查不到也只能跳过 DNS 记录，
# 不能连 account 级的 Origin CA 证书（DELETE /certificates/{id}）一起放弃。
run_purge_cloud_resources_case() { # $1=yes|no：状态里是否已带 Zone ID
    local zone_mode=$1 case_status=0
    local log="${TMP_DIR}/purge-resources-${zone_mode}.log"
    local runtime="${TMP_DIR}/purge-resources-runtime-${zone_mode}"
    local state="${TMP_DIR}/purge-resources-state-${zone_mode}"
    mkdir -p "${runtime}" "${state}"
    (
        set -Eeuo pipefail
        export RUNTIME_TMP="${runtime}"
        export EASY_ALL_STATE_DIR_OVERRIDE="${state}"
        export EASY_ALL_CERT_DIR_OVERRIDE="${state}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state}/subscriptions"
        export EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TMP_DIR}/purge-resources-${zone_mode}-takeover.log"
        source "${ROOT_DIR}/profiles/cloudflare.sh"
        if [[ "${zone_mode}" == "yes" ]]; then
            CLOUDFLARE_ZONE_ID=zoneid
        fi
        CLOUDFLARE_API_TOKEN="${TOKEN}"
        CLOUDFLARE_ORIGIN_CERT_ID=cert1
        VPS_PUBLIC_IPV4=203.0.113.10
        CF_ZONE=cf.example.com
        CF_NODE_DOMAIN=cf.example.com
        SUBSCRIPTION_MODE=deploy
        cloudflare_api_request() {
            local method=$1 path=$2
            printf '%s %s\n' "${method}" "${path}" >>"${log}"
            case "${method} ${path}" in
            "GET /zones?name="*)
                # zone-missing：补查拿不到 active Zone，cdn_ensure_zone_id 会 die。
                if [[ "${zone_mode}" == "zone-missing" ]]; then
                    printf '[]\n'
                else
                    printf '[{"name":"cf.example.com","id":"zoneid"}]\n'
                fi ;;
            "GET "*dns_records*)
                printf '[{"id":"rec1","type":"A","name":"cf.example.com","content":"203.0.113.10","proxied":true,"comment":"easy_all cloudflare","ttl":300}]\n' ;;
            *) printf 'null\n' ;;
            esac
        }
        cdn_purge_cloud_resources
    ) </dev/null >"${log}.out" 2>"${log}.err" || case_status=$?
    cat "${log}" 2>/dev/null || true
    return "${case_status}"
}

if ! purge_with_zone_log=$(run_purge_cloud_resources_case yes); then
    fail "purge 云端清理应成功退出：$(<"${TMP_DIR}/purge-resources-yes.log.err")"
fi
assert_contains "purge 云端清理删除受管 DNS 记录" "${purge_with_zone_log}" \
    "DELETE /zones/zoneid/dns_records/rec1"
assert_contains "purge 云端清理吊销 Origin CA" "${purge_with_zone_log}" "DELETE /certificates/cert1"

# Zone 补查失败（cdn_ensure_zone_id die）：DNS 记录随之保留，但 account 级的 Origin CA
# 吊销必须已经在 Zone 依赖块之前执行过（重排后的执行顺序）。
run_purge_cloud_resources_case zone-missing >/dev/null || true
zone_die_log=$(<"${TMP_DIR}/purge-resources-zone-missing.log")
zone_die_err=$(<"${TMP_DIR}/purge-resources-zone-missing.log.err")
assert_contains "P2-2: Zone 补查失败时 Origin CA 吊销仍被调用" "${zone_die_log}" \
    "DELETE /certificates/cert1"
assert_equal "P2-2: Zone 补查失败时不发起 DNS 记录删除" "0" \
    "$(grep -c 'dns_records' "${TMP_DIR}/purge-resources-zone-missing.log" || true)"
assert_contains "P2-2: 补查失败如实报错（无 active Zone）" "${zone_die_err}" "active Zone"

if ! purge_no_zone_log=$(run_purge_cloud_resources_case no); then
    fail "状态缺 Zone ID 时补查后应成功退出：$(<"${TMP_DIR}/purge-resources-no.log.err")"
fi
assert_contains "状态缺 Zone ID 时先补查 Zone" "${purge_no_zone_log}" \
    "GET /zones?name=cf.example.com"
assert_contains "状态缺 Zone ID 时不提前放弃 DNS 清理" "${purge_no_zone_log}" \
    "DELETE /zones/zoneid/dns_records/rec1"
assert_contains "状态缺 Zone ID 时 Origin CA 吊销仍被调用" "${purge_no_zone_log}" \
    "DELETE /certificates/cert1"


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

# --- 3b. 模式 3：直连域名可与源站域名复用 -------------------------------------
# 依据：docs/preparation-guide.md §域名清单：直连域名可与源站域名复用（填同一个名字时
# 两个入口共用一个灰云 A 记录，端口不同、证书互不影响，部署只需 2 个名字）。
# 因此本段是两个方向的正向契约：等于源站域名必须放行，等于节点/订阅域名必须拒绝。
run_install_domain_case() { # $1=DIRECT_DOMAIN
    RUNTIME_TMP="${TMP_DIR}/domains-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/domains-state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/domains-state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/domains-subscriptions" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
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

write_reality_cf_front_state() { # $1=DIRECT_DOMAIN $2=输出文件
    cat >"$2" <<STATE
STATE_VERSION=1
PROTOCOL=reality-cloudfront
TCP_ACCELERATION=off
VPS_PUBLIC_IPV4=203.0.113.10
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
SUB_DOWNLOAD_NAME=EASY_ALL
OWNER_TOKEN=token-abcdefgh
ALLOWED_TOKENS=\{\"owner\":\"token-abcdefgh\"\}
SUBSCRIPTION_CONFIG=\{\"allowedTokens\":\{\"owner\":\"token-abcdefgh\"\}\,\"nodes\":\[\]\}
MIHOMO_TEMPLATE_SNAPSHOT=1
SCHEDULED_REBOOT_ENABLED=0
SCHEDULED_REBOOT_HOUR=4
DIRECT_DOMAIN=$1
DIRECT_NODE_NAME=US-direct
REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
REALITY_SHORT_ID=0123456789abcdef
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
    local state_dir="${TMP_DIR}/reality-cf-front-state-${1//./_}"
    mkdir -p "${state_dir}"
    write_reality_cf_front_state "$1" "${state_dir}/state.env"
    RUNTIME_TMP="${state_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${state_dir}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${state_dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state_dir}/subscriptions" \
        bash -c 'source "$1/profiles/reality-cloudfront.sh"; load_state' _ "${ROOT_DIR}" 2>&1
}

run_state_domain_case "direct.example.com" >/dev/null \
    || fail "状态中直连域名与源站域名不同时必须通过"
# 状态期与安装期同口径：复用源站域名的已装状态必须能被 load_state 正常加载。
run_state_domain_case "origin.example.com" >/dev/null \
    || fail "状态中直连域名等于源站域名时必须通过（文档允许与源站域名复用）"

# --- 3b-2. 模式 2/3 安装输入提示面：域名输入收敛为每条链路两个名字 -----------------
# 模式 3 不再询问源站域名（固定复用直连域名）、模式 2/3 不再询问订阅域名（固定复用节点域名）。
# 输入由共享核心派生，这里直接观察用户可见的提示文案与派生结果。
run_inputs_case() { # $1=profile（reality-cloudfront|cloudfront） $2=resume（可选：模拟跨版本续装并预设旧身份域名）
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
            prompt_secret_into() { printf -v "$1" "%s" "0123456789abcdef0123456789abcdef"; }
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

reality_inputs=$(run_inputs_case reality-cloudfront) || fail "模式 3 安装输入收集失败：${reality_inputs}"
reality_prompts=$(cat "${TMP_DIR}/inputs-prompts-reality-cloudfront.log")
assert_contains "模式 3 仍询问直连节点域名" "${reality_prompts}" "直连节点域名"
assert_contains "模式 3 仍询问 CloudFront 节点域名" "${reality_prompts}" "CloudFront 节点域名"
assert_not_contains "模式 3 不再询问源站域名" "${reality_prompts}" "源站域名"
assert_not_contains "模式 3 不再询问订阅域名" "${reality_prompts}" "订阅域名"
assert_equal "模式 3 域名提示恰为两条" "2" "$(printf '%s\n' "${reality_prompts}" | grep -c '域名')"
assert_contains "模式 3 源站域名复用直连域名" "${reality_inputs}" "ORIGIN=node.example.com"
assert_contains "模式 3 直连域名用默认值" "${reality_inputs}" "DIRECT=node.example.com"
assert_contains "模式 3 节点域名用默认值" "${reality_inputs}" "NODE=cf.example.com"
assert_contains "模式 3 订阅域名复用节点域名" "${reality_inputs}" "SUB=cf.example.com"
assert_contains "模式 3 CDN 域名派生为节点域名" "${reality_inputs}" "VLESS_CDN=cf.example.com"
assert_contains "模式 3 证书只需一个域名" "${reality_inputs}" "HOSTS=1"

cloudfront_inputs=$(run_inputs_case cloudfront) || fail "模式 2 安装输入收集失败：${cloudfront_inputs}"
cloudfront_prompts=$(cat "${TMP_DIR}/inputs-prompts-cloudfront.log")
assert_contains "模式 2 仍询问源站域名" "${cloudfront_prompts}" "源站域名"
assert_contains "模式 2 仍询问 CloudFront 节点域名" "${cloudfront_prompts}" "CloudFront 节点域名"
assert_not_contains "模式 2 不再询问订阅域名" "${cloudfront_prompts}" "订阅域名"
assert_equal "模式 2 域名提示恰为两条" "2" "$(printf '%s\n' "${cloudfront_prompts}" | grep -c '域名')"
assert_contains "模式 2 源站域名用默认值" "${cloudfront_inputs}" "ORIGIN=origin.example.com"
assert_contains "模式 2 节点域名用默认值" "${cloudfront_inputs}" "NODE=cf.example.com"
assert_contains "模式 2 订阅域名复用节点域名" "${cloudfront_inputs}" "SUB=cf.example.com"
assert_equal "模式 2 没有直连域名" "DIRECT=" \
    "$(printf '%s\n' "${cloudfront_inputs}" | grep '^DIRECT=')"

# 3b-3. 安装输入顺序：先把域名问完，再把两个节点名排在一起（模式 3/4 同规）。
run_prompt_order() { # $1=profile -> 逐行输出 prompt_value 的提示文案
    local prompts="${TMP_DIR}/order-$1.log"
    : >"${prompts}"
    RUNTIME_TMP="${TMP_DIR}/order-runtime-$1" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/order-state-$1" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/order-state-$1/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/order-subs-$1" \
    PROMPTS="${prompts}" \
        bash -c '
            source "$1/profiles/$2.sh"
            prompt_value() { printf "%s\n" "$1" >>"${PROMPTS}"; printf "%s" "${2:-}"; }
            prompt_secret_into() { printf "%s\n" "$2" >>"${PROMPTS}"; printf -v "$1" "%s" "0123456789abcdef0123456789abcdef"; }
            choose_subscription_config() {
                printf "%s\n" "订阅配置" >>"${PROMPTS}"
                printf "%s" "{\"allowedTokens\":{\"owner\":\"token-abcdefgh\"},\"nodes\":[]}"
            }
            collect_cdn_edge_address() { printf "%s\n" "CDN 优选前缀" >>"${PROMPTS}"; }
            CF_ZONE=example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            VLESS_UUID=11111111-2222-4333-8444-555555555555
            collect_install_inputs >/dev/null
        ' _ "${ROOT_DIR}" "$1" 2>/dev/null || true
    cat "${prompts}"
}
reality_cf_order=$(run_prompt_order reality-cloudflare)
assert_equal "模式 4 第 2 条是直连域名" "直连节点域名（灰云 A 记录指向本机）" \
    "$(printf '%s\n' "${reality_cf_order}" | sed -n 2p)"
assert_equal "模式 4 域名先问完，第 3 条才是 CDN 节点域名" \
    "CDN 节点域名（橙云代理，同时提供 HTTPUpgrade 节点与订阅）" \
    "$(printf '%s\n' "${reality_cf_order}" | sed -n 3p)"
assert_equal "模式 4 两个节点名相邻（直连后紧接 CDN）" "CDN 节点名（完整单节点名）" \
    "$(printf '%s\n' "${reality_cf_order}" | sed -n 5p)"
assert_equal "模式 4 提示总数固定" "9" \
    "$(printf '%s\n' "${reality_cf_order}" | grep -c .)"
assert_not_contains "模式 4 不询问订阅域名（由节点域名派生）" "${reality_cf_order}" "订阅域名"
assert_not_contains "模式 4 Token 提示不含过时 deploy 字样" "${reality_cf_order}" "deploy 还需"
reality_cf_xhttp_order=$(run_prompt_order reality-cloudflare-xhttp)
assert_equal "模式 5 第 3 条是橙云 XHTTP CDN 节点域名" \
    "CDN 节点域名（橙云代理，同时提供 XHTTP 节点与订阅）" \
    "$(printf '%s\n' "${reality_cf_xhttp_order}" | sed -n 3p)"
assert_not_contains "模式 5 提示文案不得残留 HTTPUpgrade" "${reality_cf_xhttp_order}" "HTTPUpgrade"
assert_equal "模式 5 第 7 条是 Transform Rules Token 提示" \
    "Cloudflare API Token（Zone 只读 + DNS 编辑 + Zone Settings 只读 + Transform Rules 编辑）" \
    "$(printf '%s\n' "${reality_cf_xhttp_order}" | sed -n 7p)"
# 3b-4. 优选前缀与订阅配置的新顺序：前缀先问并暂存，配置落定后再写进 cdnEdgeAddress。
apply_prefix_case() { # $1=初始订阅配置 $2=暂存前缀 $3=PROTOCOL -> 最终订阅配置
    bash -c '
        source "$1/lib/log.sh"
        source "$1/lib/profile-common.sh"
        PROTOCOL=$4
        SUBSCRIPTION_CONFIG=$2
        CDN_EDGE_PREFIX=$3
        apply_cdn_edge_prefix
        printf "%s" "${SUBSCRIPTION_CONFIG}"
    ' _ "${ROOT_DIR}" "$1" "$2" "$3" 2>/dev/null
}
assert_contains "前缀写入 reality-cloudfront 配置" \
    "$(apply_prefix_case '{"allowedTokens":{"owner":"t"},"nodes":[]}' k7m2qp4x9d reality-cloudfront)" \
    '"cdnEdgeAddress":"k7m2qp4x9d.cloudfront.182682.xyz"'
assert_contains "前缀写入 reality-cloudflare 配置（橙云后缀）" \
    "$(apply_prefix_case '{"allowedTokens":{"owner":"t"},"nodes":[]}' k7m2qp4x9d reality-cloudflare)" \
    '"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"'
assert_contains "前缀覆盖安装生成的旧前缀" \
    "$(apply_prefix_case '{"allowedTokens":{"owner":"t"},"nodes":[],"cdnEdgeAddress":"aa11bb22cc.cloudflare.182682.xyz"}' k7m2qp4x9d reality-cloudflare)" \
    '"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"'
assert_contains "无条件覆盖粘贴 JSON 里的优选地址" \
    "$(apply_prefix_case '{"allowedTokens":{"owner":"t"},"nodes":[],"cdnEdgeAddress":"edge.example.com"}' k7m2qp4x9d cloudfront)" \
    '"cdnEdgeAddress":"k7m2qp4x9d.cloudfront.182682.xyz"'

# 3b-5. 结构断言：安装收集器里「问前缀 → 问订阅配置 → 写前缀 → 强校验」的顺序不得错位。
install_edge_order_check() { # $1=模式库 $2=安装收集函数
    local body
    body=$(awk -v fn="$2" '$0 ~ "^" fn "\\(\\) \\{" { on = 1 } on { print } on && /^\}/ { exit }' \
        "${ROOT_DIR}/lib/$1")
    printf '%s\n' "${body}" | awk '
        /collect_cdn_edge_address/ { if (!c) c = NR }
        /choose_subscription_config/ { if (!s) s = NR }
        /apply_cdn_edge_prefix/ { if (!a) a = NR }
        /cdn_apply_subscription_config/ { if (!v) v = NR }
        END { exit !(c && s && a && v && c < s && s < a && a < v) }
    ' || fail "$1 的 $2 必须按「问前缀 → 问订阅配置 → 写前缀 → 强校验」排列"
}
install_edge_order_check cloudflare-mode.sh collect_cloudflare_install_inputs
install_edge_order_check cloudfront-mode.sh collect_cloudfront_install_inputs
install_edge_order_check reality-cloudflare-mode.sh collect_direct_install_inputs
# 订阅配置不可解析时要报错，而不是被 errexit 静默带走。
bad_apply=$(bash -c '
    source "$1/lib/log.sh"
    source "$1/lib/profile-common.sh"
    PROTOCOL=cloudfront
    SUBSCRIPTION_CONFIG=not-json
    CDN_EDGE_PREFIX=k7m2qp4x9d
    apply_cdn_edge_prefix
    printf "SHOULD-NOT-REACH\n"
' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "订阅配置不可解析时报错而不是静默退出" "${bad_apply}" "更新订阅配置失败"
assert_not_contains "订阅配置不可解析时不继续执行" "${bad_apply}" "SHOULD-NOT-REACH"
# 另一半失败语义：PROTOCOL 无 CDN 后缀时不静默返回 1，而是报错点名后缀；配置逐字节不变。
bogus_config='{"allowedTokens":{"owner":"t"},"nodes":[]}'
if bogus_apply=$(bash -c '
    source "$1/lib/log.sh"
    source "$1/lib/profile-common.sh"
    show_config() { printf "CONFIG=%s\n" "${SUBSCRIPTION_CONFIG}"; }
    trap show_config EXIT
    PROTOCOL=bogus
    SUBSCRIPTION_CONFIG=$2
    CDN_EDGE_PREFIX=k7m2qp4x9d
    apply_cdn_edge_prefix
    printf "SHOULD-NOT-REACH\n"
' _ "${ROOT_DIR}" "${bogus_config}" 2>&1); then
    bogus_apply_status=0
else
    bogus_apply_status=$?
fi
assert_equal "不支持的 PROTOCOL 下写入退出非零" "1" "${bogus_apply_status}"
assert_contains "不支持的 PROTOCOL 下报错点名后缀" "${bogus_apply}" \
    "无法解析 bogus 的 CDN 优选后缀"
assert_equal "不支持的 PROTOCOL 下订阅配置逐字节不变" "${bogus_config}" \
    "$(sed -n 's/^CONFIG=//p' <<<"${bogus_apply}")"
assert_not_contains "不支持的 PROTOCOL 下不继续执行" "${bogus_apply}" "SHOULD-NOT-REACH"

# 跨版本续装：旧版身份里源站/订阅域名可能是独立填写的，续装不得改写已建资源用的域名。
resume_inputs=$(run_inputs_case reality-cloudfront resume) || fail "模式 3 续装输入收集失败：${resume_inputs}"
resume_prompts=$(cat "${TMP_DIR}/inputs-prompts-reality-cloudfront-resume.log")
assert_contains "续装仍询问直连节点域名" "${resume_prompts}" "直连节点域名"
assert_contains "续装仍询问 CloudFront 节点域名" "${resume_prompts}" "CloudFront 节点域名"
assert_not_contains "续装不再询问源站域名" "${resume_prompts}" "源站域名"
assert_not_contains "续装不再询问订阅域名" "${resume_prompts}" "订阅域名"
assert_equal "续装域名提示恰为两条" "2" "$(printf '%s\n' "${resume_prompts}" | grep -c '域名')"
assert_contains "续装沿用旧身份的源站域名" "${resume_inputs}" "ORIGIN=origin.example.com"
assert_contains "续装沿用旧身份的订阅域名" "${resume_inputs}" "SUB=sub.example.com"

# 模式 2 续装同理：源站域名照旧提问，订阅域名沿用旧身份里的独立值。
resume_cf_inputs=$(run_inputs_case cloudfront resume) || fail "模式 2 续装输入收集失败：${resume_cf_inputs}"
resume_cf_prompts=$(cat "${TMP_DIR}/inputs-prompts-cloudfront-resume.log")
assert_contains "模式 2 续装仍询问源站域名" "${resume_cf_prompts}" "源站域名"
assert_not_contains "模式 2 续装不再询问订阅域名" "${resume_cf_prompts}" "订阅域名"
assert_equal "模式 2 续装域名提示恰为两条" "2" "$(printf '%s\n' "${resume_cf_prompts}" | grep -c '域名')"
assert_contains "模式 2 续装沿用旧身份的订阅域名" "${resume_cf_inputs}" "SUB=sub.example.com"

# --- 3c. 模式 4：直连 + 橙云节点/订阅（回源 8443）------------------------------
write_reality_cf_state() { # $1=DIRECT_DOMAIN $2=CF_NODE_DOMAIN $3=SUBSCRIPTION_MODE $4=输出
    cat >"$4" <<STATE
STATE_VERSION=1
PROTOCOL=reality-cloudflare
TCP_ACCELERATION=off
VPS_PUBLIC_IPV4=203.0.113.10
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=$3
SUB_DOWNLOAD_NAME=EASY_ALL
OWNER_TOKEN=token-abcdefgh
ALLOWED_TOKENS=\{\"owner\":\"token-abcdefgh\"\}
SUBSCRIPTION_CONFIG=\{\"allowedTokens\":\{\"owner\":\"token-abcdefgh\"\}\,\"nodes\":\[\]\}
MIHOMO_TEMPLATE_SNAPSHOT=1
SCHEDULED_REBOOT_ENABLED=0
SCHEDULED_REBOOT_HOUR=4
DIRECT_DOMAIN=$1
DIRECT_NODE_NAME=US-direct
REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
REALITY_SHORT_ID=0123456789abcdef
CF_NODE_DOMAIN=$2
CF_NODE_PREFIX=CF
VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
VLESS_PATH=/vless-0123456789ab
CLOUDFLARE_ORIGIN_RULESET_ID=rs1
CLOUDFLARE_ORIGIN_RULE_ID=rule1
STATE
}

run_reality_cf_state_case() { # $1=DIRECT_DOMAIN $2=CF_NODE_DOMAIN $3=SUBSCRIPTION_MODE
    local state_dir
    state_dir="${TMP_DIR}/reality-cf-state-${1//./_}-${2//./_}-${3}"
    mkdir -p "${state_dir}"
    write_reality_cf_state "$1" "$2" "$3" "${state_dir}/state.env"
    RUNTIME_TMP="${state_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${state_dir}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${state_dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${state_dir}/subscriptions" \
        bash -c 'source "$1/profiles/reality-cloudflare.sh"; load_state; \
            printf "PUBLIC=%s CFONLY=%s SITE=%s\n" "$(runtime_public_tcp_ports)" \
                "$(runtime_cloudflare_only_port)" "$(runtime_caddy_site_enabled && echo 1 || echo 0)"' \
        _ "${ROOT_DIR}" 2>&1
}

reality_cf_state=$(run_reality_cf_state_case direct.example.com cf.example.com deploy) \
    || fail "模式 4 完整状态必须能加载"
assert_contains "模式 4 仅公网 443" "${reality_cf_state}" "PUBLIC=443"
assert_contains "模式 4 回源 8443 只对 Cloudflare" "${reality_cf_state}" "CFONLY=8443"
assert_contains "模式 4 始终部署 Caddy 站点" "${reality_cf_state}" "SITE=1"
reality_cf_same_domain=$(run_reality_cf_state_case cf.example.com cf.example.com deploy) \
    && fail "模式 4 节点域名等于直连域名时必须拒绝"
assert_contains "模式 4 节点域名不得等于直连域名" "${reality_cf_same_domain}" \
    "节点域名不得等于直连域名"
run_reality_cf_state_case direct.example.com other.example.net deploy >/dev/null \
    && fail "模式 4 节点域名不属于 Zone 时必须拒绝"
run_reality_cf_state_case direct.example.com cf.example.com link >/dev/null \
    && fail "模式 4 固定 deploy，link 状态必须拒绝"

# --- 3d. WP5：模式 4 双证书 SAN 隔离、缩容重签、hook 分槽与三列指纹校验 --------
for split_profile in reality-cloudflare; do
    split_hosts=$(
        RUNTIME_TMP="${TMP_DIR}/split-cert-${split_profile}-runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/split-cert-${split_profile}-state" \
            bash -c '
                source "$1/profiles/$2.sh"
                DIRECT_DOMAIN=direct.example.com
                CF_NODE_DOMAIN=cf.example.com
                printf "PRIMARY=%s\nCDN=%s\n" \
                    "$(certificate_required_hosts | paste -sd, -)" \
                    "$(certificate_cdn_required_hosts | paste -sd, -)"
            ' _ "${ROOT_DIR}" "${split_profile}" 2>&1
    ) || fail "${split_profile} 证书域名调用失败：${split_hosts}"
    assert_contains "${split_profile} 主证书仅覆盖直连域名（防 SAN 泄露橙云域名）" \
        "${split_hosts}" "PRIMARY=direct.example.com"
    assert_contains "${split_profile} 独立 CDN 证书仅覆盖橙云节点域名" \
        "${split_hosts}" "CDN=cf.example.com"
done

# 精确 SAN 校验：旧版合并证书（同时含 direct + cf）必须被 exact 检查拒掉。
make_san_cert() { # $1=目录 $2=CN $3=subjectAltName(如 DNS:a,DNS:b)
    mkdir -p "$1"
    openssl req -x509 -newkey rsa:2048 -nodes -days 60 -subj "/CN=$2" \
        -addext "subjectAltName=$3" \
        -keyout "$1/private.key" -out "$1/fullchain.pem" >/dev/null 2>&1 \
        || fail "无法生成带 SAN 的测试证书：$3"
}
san_direct_dir="${TMP_DIR}/san-direct"
san_cdn_dir="${TMP_DIR}/san-cdn"
san_combined_dir="${TMP_DIR}/san-combined"
make_san_cert "${san_direct_dir}" direct.example.com "DNS:direct.example.com"
make_san_cert "${san_cdn_dir}" cf.example.com "DNS:cf.example.com"
make_san_cert "${san_combined_dir}" direct.example.com "DNS:direct.example.com,DNS:cf.example.com"

san_exact_out=$(
    RUNTIME_TMP="${TMP_DIR}/san-exact-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/san-exact-state" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            certificate_covers_exact_hosts "$2/fullchain.pem" direct.example.com && echo DIRECT_OK || echo DIRECT_FAIL
            certificate_covers_exact_hosts "$3/fullchain.pem" cf.example.com && echo CDN_OK || echo CDN_FAIL
            certificate_covers_exact_hosts "$4/fullchain.pem" direct.example.com && echo COMBINED_PASS || echo COMBINED_REJECT
        ' _ "${ROOT_DIR}" "${san_direct_dir}" "${san_cdn_dir}" "${san_combined_dir}" 2>&1
) || fail "certificate_covers_exact_hosts 执行失败：${san_exact_out}"
assert_contains "单域名直连证书通过 exact 校验" "${san_exact_out}" "DIRECT_OK"
assert_contains "单域名 CDN 证书通过 exact 校验" "${san_exact_out}" "CDN_OK"
assert_contains "旧版合并双 SAN 证书被 exact 校验拒绝" "${san_exact_out}" "COMBINED_REJECT"

# 模式 4 cdn_issue_certificate：分别签发 easy_all（direct）与 easy_all-cdn（cf），
# 且检测到旧版合并 SAN 时即使 force=0 也必须传 --force-renewal 缩容 SAN。
split_issue_dir="${TMP_DIR}/split-issue"
mkdir -p "${split_issue_dir}/bin" "${split_issue_dir}/state" "${split_issue_dir}/certs" \
    "${split_issue_dir}/runtime" \
    "${split_issue_dir}/live/easy_all" "${split_issue_dir}/live/easy_all-cdn"
: >"${split_issue_dir}/certbot.log"
cat >"${split_issue_dir}/bin/certbot" <<'FAKE_CERTBOT'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CERTBOT_LOG}"
cert_name=""
while (($#)); do
    case "$1" in
    --cert-name) cert_name=$2; shift 2 ;;
    *) shift ;;
    esac
done
if [[ "${cert_name}" == "easy_all" ]]; then
    install -m 0644 "${SAN_DIRECT_DIR}/fullchain.pem" "${FAKE_LIVE_PRIMARY}/fullchain.pem"
    install -m 0600 "${SAN_DIRECT_DIR}/private.key" "${FAKE_LIVE_PRIMARY}/privkey.pem"
elif [[ "${cert_name}" == "easy_all-cdn" ]]; then
    install -m 0644 "${SAN_CDN_DIR}/fullchain.pem" "${FAKE_LIVE_CDN}/fullchain.pem"
    install -m 0600 "${SAN_CDN_DIR}/private.key" "${FAKE_LIVE_CDN}/privkey.pem"
fi
FAKE_CERTBOT
chmod +x "${split_issue_dir}/bin/certbot"
# 预置旧版合并证书在主 live 目录与现用证书路径，验证缩容触发 --force-renewal。
install -m 0644 "${san_combined_dir}/fullchain.pem" "${split_issue_dir}/live/easy_all/fullchain.pem"
install -m 0600 "${san_combined_dir}/private.key" "${split_issue_dir}/live/easy_all/privkey.pem"
install -m 0644 "${san_combined_dir}/fullchain.pem" "${split_issue_dir}/certs/fullchain.pem"
install -m 0600 "${san_combined_dir}/private.key" "${split_issue_dir}/certs/private.key"

split_issue_out=$(
    PATH="${split_issue_dir}/bin:${PATH}" \
    FAKE_CERTBOT_LOG="${split_issue_dir}/certbot.log" \
    FAKE_LIVE_PRIMARY="${split_issue_dir}/live/easy_all" \
    FAKE_LIVE_CDN="${split_issue_dir}/live/easy_all-cdn" \
    SAN_DIRECT_DIR="${san_direct_dir}" \
    SAN_CDN_DIR="${san_cdn_dir}" \
    RUNTIME_TMP="${split_issue_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${split_issue_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${split_issue_dir}/certs" \
    EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all" \
    EASY_ALL_CERTBOT_CDN_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all-cdn" \
    EASY_ALL_CLOUDFLARE_CREDENTIALS_OVERRIDE="${split_issue_dir}/state/cloudflare.ini" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            DIRECT_DOMAIN=direct.example.com
            CF_NODE_DOMAIN=cf.example.com
            CLOUDFLARE_API_TOKEN=test-cf-token-1234567890
            certificate_chain_valid() { return 0; }
            cdn_issue_certificate 0
            printf "PRIMARY_SAN=%s\nCDN_SAN=%s\n" \
                "$(certificate_san_hosts "${CERT_FILE}" | paste -sd, -)" \
                "$(certificate_san_hosts "${CDN_CERT_FILE}" | paste -sd, -)"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 4 双证书签发/缩容测试失败：${split_issue_out}"
certbot_calls=$(<"${split_issue_dir}/certbot.log")
assert_contains "主证书走 easy_all lineage 且仅签 direct" "${certbot_calls}" "--cert-name easy_all"
assert_contains "主证书缩容旧合并 SAN 时强制 --force-renewal" "${certbot_calls}" "--force-renewal -d direct.example.com"
assert_contains "回源证书走独立 easy_all-cdn lineage 且仅签 cf" "${certbot_calls}" "--cert-name easy_all-cdn"
assert_contains "回源证书包含 -d cf.example.com" "${certbot_calls}" "-d cf.example.com"
assert_contains "落盘主证书 SAN 仅含 direct" "${split_issue_out}" "PRIMARY_SAN=direct.example.com"
assert_contains "落盘回源证书 SAN 仅含 cf" "${split_issue_out}" "CDN_SAN=cf.example.com"

# internal_cert_deploy：按 RENEWED_LINEAGE 分槽部署主证书或回源证书，非拆证模式拒绝 cdn lineage。
cert_hook_out=$(
    RUNTIME_TMP="${split_issue_dir}/hook-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${split_issue_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${split_issue_dir}/certs" \
    EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all" \
    EASY_ALL_CERTBOT_CDN_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all-cdn" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            require_root() { :; }
            acquire_runtime_write_lock() { :; }
            release_runtime_write_lock() { :; }
            collect_installed_state() { :; }
            save_state() { :; }
            certificate_deploy() { printf "DEPLOY_PRIMARY\n"; }
            certificate_deploy_cdn() { printf "DEPLOY_CDN\n"; }
            RENEWED_LINEAGE="${CERTBOT_LIVE_DIR}" internal_cert_deploy >/dev/null
            RENEWED_LINEAGE="${CERTBOT_CDN_LIVE_DIR}" internal_cert_deploy >/dev/null
            if (RENEWED_LINEAGE="/etc/letsencrypt/live/foreign" internal_cert_deploy) >/dev/null 2>&1; then
                printf "FOREIGN_ACCEPTED\n"
            else
                printf "FOREIGN_REJECTED\n"
            fi
        ' _ "${ROOT_DIR}" 2>&1
) || fail "internal_cert_deploy 分槽测试失败：${cert_hook_out}"
assert_contains "hook 正确拒绝未知 lineage" "${cert_hook_out}" "FOREIGN_REJECTED"
cert_hook_calls=$(
    RUNTIME_TMP="${split_issue_dir}/hook-runtime-2" \
    EASY_ALL_STATE_DIR_OVERRIDE="${split_issue_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${split_issue_dir}/certs" \
    EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all" \
    EASY_ALL_CERTBOT_CDN_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all-cdn" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            require_root() { :; }
            acquire_runtime_write_lock() { :; }
            release_runtime_write_lock() { :; }
            collect_installed_state() { :; }
            save_state() { :; }
            success() { :; }
            certificate_deploy() { printf "DEPLOY_PRIMARY\n"; }
            certificate_deploy_cdn() { printf "DEPLOY_CDN\n"; }
            RENEWED_LINEAGE="${CERTBOT_LIVE_DIR}" internal_cert_deploy
            RENEWED_LINEAGE="${CERTBOT_CDN_LIVE_DIR}" internal_cert_deploy
        ' _ "${ROOT_DIR}" 2>&1
) || fail "internal_cert_deploy 双槽调用失败"
assert_equal "hook 按 lineage 分派 primary 与 cdn 槽位" \
    $'DEPLOY_PRIMARY\nDEPLOY_CDN' "${cert_hook_calls}"
if (
    RUNTIME_TMP="${split_issue_dir}/hook-runtime-3" \
    EASY_ALL_STATE_DIR_OVERRIDE="${split_issue_dir}/state" \
    EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all" \
    EASY_ALL_CERTBOT_CDN_LIVE_DIR_OVERRIDE="${split_issue_dir}/live/easy_all-cdn" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            require_root() { :; }
            acquire_runtime_write_lock() { :; }
            collect_installed_state() { :; }
            RENEWED_LINEAGE="${CERTBOT_CDN_LIVE_DIR}" internal_cert_deploy
        ' _ "${ROOT_DIR}"
) >/dev/null 2>&1; then
    fail "非双证书模式不得接受 easy_all-cdn lineage"
fi

# 三列端点契约（<host> <port> <cert_file>）与逐端点指纹校验：
# 模式 4 必须分别比对 443↔CERT_FILE 与 8443↔CDN_CERT_FILE；8443 错送主证书必须失败。
endpoints_check_dir="${TMP_DIR}/endpoints-check"
mkdir -p "${endpoints_check_dir}/certs"
install -m 0644 "${san_direct_dir}/fullchain.pem" "${endpoints_check_dir}/certs/fullchain.pem"
install -m 0644 "${san_cdn_dir}/fullchain.pem" "${endpoints_check_dir}/certs/cdn-fullchain.pem"
endpoints_out=$(
    RUNTIME_TMP="${endpoints_check_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${endpoints_check_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${endpoints_check_dir}/certs" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            DIRECT_DOMAIN=direct.example.com
            CF_NODE_DOMAIN=cf.example.com
            runtime_served_certificate_endpoints
            fp_primary=$(runtime_certificate_fingerprint_on_disk "${CERT_FILE}")
            fp_cdn=$(runtime_certificate_fingerprint_on_disk "${CDN_CERT_FILE}")
            runtime_tls_peer_fingerprint() {
                if [[ "$2" == "443" ]]; then printf "%s\n" "${fp_primary}"; else printf "%s\n" "${fp_cdn}"; fi
            }
            runtime_served_certificate_matches_disk && printf "MATCH_OK\n"
            # 模拟 8443 仍送出旧主证书（未切至 CDN 证书）：必须判失败。
            runtime_tls_peer_fingerprint() { printf "%s\n" "${fp_primary}"; }
            sleep() { :; }
            if runtime_served_certificate_matches_disk >/dev/null 2>&1; then
                printf "MISMATCH_MISSED\n"
            else
                printf "MISMATCH_CAUGHT\n"
            fi
        ' _ "${ROOT_DIR}" 2>&1
) || fail "三列端点与双证书指纹校验失败：${endpoints_out}"
assert_contains "模式 4 直连端点绑定主证书" "${endpoints_out}" \
    "direct.example.com 443 ${endpoints_check_dir}/certs/fullchain.pem"
assert_contains "模式 4 回源端点绑定独立 CDN 证书" "${endpoints_out}" \
    "cf.example.com 8443 ${endpoints_check_dir}/certs/cdn-fullchain.pem"
assert_contains "两端口各送对应证书时指纹校验通过" "${endpoints_out}" "MATCH_OK"
assert_contains "8443 误送主证书时指纹校验失败" "${endpoints_out}" "MISMATCH_CAUGHT"

# v5.5.0 升级未拆证前（有 CERT_FILE、无 CDN_CERT_FILE）：8443 端点平滑回退到 CERT_FILE。
rm -f -- "${endpoints_check_dir}/certs/cdn-fullchain.pem"
endpoints_fallback=$(
    RUNTIME_TMP="${endpoints_check_dir}/runtime-fb" \
    EASY_ALL_STATE_DIR_OVERRIDE="${endpoints_check_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${endpoints_check_dir}/certs" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            DIRECT_DOMAIN=direct.example.com
            CF_NODE_DOMAIN=cf.example.com
            runtime_served_certificate_endpoints
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 4 回退端点输出失败"
assert_contains "v5.5.0 回退态 8443 端点指向旧主证书" "${endpoints_fallback}" \
    "cf.example.com 8443 ${endpoints_check_dir}/certs/fullchain.pem"

# 模式 3 端点：443 + 9443（单 443 合一回环，不再是 8443）。
mode3_endpoints=$(
    RUNTIME_TMP="${endpoints_check_dir}/runtime-m3" \
    EASY_ALL_STATE_DIR_OVERRIDE="${endpoints_check_dir}/state-m3" \
    EASY_ALL_CERT_DIR_OVERRIDE="${endpoints_check_dir}/certs" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            DIRECT_DOMAIN=direct.example.com
            CF_ORIGIN_DOMAIN=origin.example.com
            runtime_served_certificate_endpoints
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 3 端点输出失败"
assert_contains "模式 3 直连 443 端点" "${mode3_endpoints}" \
    "direct.example.com 443 ${endpoints_check_dir}/certs/fullchain.pem"
assert_contains "模式 3 合一 9443 端点" "${mode3_endpoints}" \
    "origin.example.com 9443 ${endpoints_check_dir}/certs/fullchain.pem"
assert_not_contains "模式 3 端点不含 8443" "${mode3_endpoints}" " 8443 "

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
        bash -c 'source "$1/profiles/reality-cloudflare.sh"; certificate_key_matches "$2" "$3"' \
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
    key_fn_body=$(bash -c 'source "$1/profiles/reality-cloudflare.sh"; declare -f "$2"' \
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
# ulimit -t 与封闭 stdin 是强杀兜底：测试进程被 SIGKILL 后 trap 不执行，由内核在 30 秒 CPU 后终止子进程。
spawn_background() { # 其余参数为命令；成功时向 stdout 输出 PID
    local pid_file
    pid_file=$(mktemp "${TMP_DIR}/pid.XXXXXX") || return 1
    (
        (
            ulimit -t 30
            exec "$@" </dev/null >/dev/null 2>&1
        ) &
        printf '%s' "$!" >"${pid_file}"
    )
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

# 证书部署事务用例：强制重载 + 握手校验，失败必须恢复旧副本。
# 全程 stub runtime_served_certificate_matches_disk，不依赖真实 TLS 握手——因此**不受**
# LibreSSL 的门限制，无条件执行（这是「证书部署失败必须恢复旧证书」在开发机上的唯一覆盖）。
run_certificate_deploy_cases() {
# 证书部署事务：强制重载 + 握手校验；校验失败恢复旧副本（覆盖主证书与独立 CDN 证书两槽位）。
certificate_deploy_case() { # $1=1 表示握手校验失败 [$2=primary|cdn]
    local handshake_fail=$1 slot=${2:-primary}
    EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${TMP_DIR}/lineage-${slot}-${handshake_fail}" \
    EASY_ALL_CERTBOT_CDN_LIVE_DIR_OVERRIDE="${TMP_DIR}/lineage-cdn-${slot}-${handshake_fail}" \
    RUNTIME_TMP="${TMP_DIR}/deploy-runtime-${slot}-${handshake_fail}" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/deploy-state-${slot}-${handshake_fail}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/deploy-certs-${slot}-${handshake_fail}" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/deploy-subscriptions" \
        bash -c '
            handshake_target=$4
            slot=$5
            source "$1/profiles/reality-cloudflare.sh"
            PROTOCOL=reality-cloudflare
            DIRECT_DOMAIN=node.example.com
            CF_NODE_DOMAIN=cf.example.com
            SUBSCRIPTION_MODE=deploy
            if [[ "${slot}" == "cdn" ]]; then
                live_dir=${CERTBOT_CDN_LIVE_DIR}
                dest_cert=${CDN_CERT_FILE}
                dest_key=${CDN_KEY_FILE}
            else
                live_dir=${CERTBOT_LIVE_DIR}
                dest_cert=${CERT_FILE}
                dest_key=${KEY_FILE}
            fi
            install -d -m 0700 "${CERT_DIR}" "${live_dir}" "${RUNTIME_TMP}"
            install -m 0644 "$2/fullchain.pem" "${dest_cert}"
            install -m 0600 "$2/private.key" "${dest_key}"
            install -m 0644 "$3/fullchain.pem" "${live_dir}/fullchain.pem"
            install -m 0600 "$3/private.key" "${live_dir}/privkey.pem"
            certificate_check_for_hosts() { return 0; }
            certificate_check() { return 0; }
            certificate_verify() { return 0; }
            runtime_apply_runtime_services() { printf "APPLY %s\n" "$1"; }
            runtime_served_certificate_matches_disk() { [[ "${handshake_target}" == "0" ]]; }
            status=0
            if [[ "${slot}" == "cdn" ]]; then
                certificate_deploy_cdn "" 1 || status=$?
            else
                certificate_deploy "" 1 || status=$?
            fi
            printf "STATUS=%s\n" "${status}"
            printf "SERVED=%s\n" "$(cat "${dest_cert}")"
        ' _ "${ROOT_DIR}" "${first_dir}" "${second_dir}" "${handshake_fail}" "${slot}" 2>&1
}
deploy_ok=$(certificate_deploy_case 0 primary) || fail "证书部署成功路径失败：${deploy_ok}"
assert_contains "部署成功时强制重载" "${deploy_ok}" "APPLY 1"
assert_contains "部署成功时状态为 0" "${deploy_ok}" "STATUS=0"
assert_contains "部署成功后磁盘是新证书" "${deploy_ok}" "$(<"${second_dir}/fullchain.pem")"

deploy_fail=$(certificate_deploy_case 1 primary) || true
assert_contains "握手校验失败时部署失败" "${deploy_fail}" "STATUS=1"
assert_contains "握手校验失败后恢复旧证书" "${deploy_fail}" "$(<"${first_dir}/fullchain.pem")"
force_applies=$(grep -c 'APPLY 1' <<<"${deploy_fail}" || true)
assert_equal "旧证书恢复也走强制重载" "2" "${force_applies}"

deploy_cdn_ok=$(certificate_deploy_case 0 cdn) || fail "CDN 证书部署成功路径失败：${deploy_cdn_ok}"
assert_contains "CDN 证书部署成功时强制重载" "${deploy_cdn_ok}" "APPLY 1"
assert_contains "CDN 证书部署成功状态为 0" "${deploy_cdn_ok}" "STATUS=0"
assert_contains "CDN 证书部署成功后磁盘是新证书" "${deploy_cdn_ok}" "$(<"${second_dir}/fullchain.pem")"

deploy_cdn_fail=$(certificate_deploy_case 1 cdn) || true
assert_contains "CDN 证书握手失败时部署失败" "${deploy_cdn_fail}" "STATUS=1"
assert_contains "CDN 证书握手失败后恢复旧证书" "${deploy_cdn_fail}" "$(<"${first_dir}/fullchain.pem")"
assert_equal "CDN 旧证书恢复也走强制重载" "2" "$(grep -c 'APPLY 1' <<<"${deploy_cdn_fail}" || true)"
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
                # 空闲占端口不烧 CPU 时 ulimit -t 打不着，另起 wall-time watchdog 按秒兜底。
                TLS_WATCHDOG_PID=$(spawn_background bash -c \
                    'sleep "$1"; kill -TERM "$2" 2>/dev/null || true; sleep 1; kill -KILL "$2" 2>/dev/null || true' \
                    _ "${TLS_WATCHDOG_TIMEOUT:-120}" "${TLS_SERVER_PID}") || true
                TLS_PORT=${port}
                return 0
            fi
            stop_tls_server
        done
        return 1
    }
    # LibreSSL（macOS 自带）的 s_client 在 stdin EOF 后可能不退出（或探测偶发通过而后续挂起），
    # 握手用例在这些宿主上无法稳定完成：提前判掉，连 s_server 都不启动，避免白白留下服务进程。
    if openssl version 2>/dev/null | grep -qi 'LibreSSL'; then
        skip_case "真实 TLS 握手与证书部署" "本机 openssl 在握手后不返回（LibreSSL）"
        return 0
    fi
    # 起不了 TLS 服务是宿主环境问题，不是产品缺陷：跳过而不是把套件判成回归。
    if ! start_tls_server "${first_dir}"; then
        skip_case "真实 TLS 握手与证书部署" "无法在空闲端口启动测试用 TLS 服务"
        return 0
    fi
    if ! tls_probe "${TLS_PORT}"; then
        stop_tls_server
        skip_case "真实 TLS 握手与证书部署" "本机 openssl 在握手后不返回（探测超时）"
        return 0
    fi

    handshake_output=$(
        RUNTIME_TMP="${TMP_DIR}/cert-runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cert-state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${first_dir}" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/cert-subscriptions" \
            bash -c '
                source "$1/profiles/reality-cloudflare.sh"
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
                source "$1/profiles/reality-cloudflare.sh"
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
                source "$1/profiles/reality-cloudflare.sh"
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
                source "$1/profiles/reality-cloudflare.sh"
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

    # 用例结束就收口，不把后台服务拖到整个脚本退出。
    stop_tls_server
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
        source "$1/profiles/reality-cloudflare.sh"
        PROTOCOL=reality-cloudflare
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
            source "$1/profiles/reality-cloudflare.sh"
            PROTOCOL=reality-cloudflare
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
            source "$1/profiles/reality-cloudfront.sh"
            PROTOCOL=reality-cloudfront
            DIRECT_DOMAIN=$2
            CF_ORIGIN_DOMAIN=$3
            certificate_required_hosts
        ' _ "${ROOT_DIR}" "$1" "$2" 2>&1
}
reused_hosts=$(certificate_hosts_case origin.example.com origin.example.com) \
    || fail "证书域名复用场景调用失败"
assert_equal "模式 3 复用同一域名时只输出一行" "origin.example.com" "${reused_hosts}"
distinct_hosts=$(certificate_hosts_case direct.example.com origin.example.com) \
    || fail "证书域名不同场景调用失败"
assert_equal "模式 3 不同域名仍输出两行" \
    $'direct.example.com\norigin.example.com' "${distinct_hosts}"
# --- 6. 源站守卫公网探测：必须打 Caddy 站点端口（模式 2 是 443，而不是回环 10086） ---
# curl 是外部边界，用替身记录被请求的 URL；连接被丢弃的情况统一返回 000。
origin_guard_case() { # $1=profile 名
    local profile=$1
    local stub_dir="${TMP_DIR}/curl-stub-${profile}"
    local url_log="${TMP_DIR}/origin-guard-${profile}.log"
    mkdir -p "${stub_dir}"
    : >"${url_log}"
    cat >"${stub_dir}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORIGIN_GUARD_LOG}"
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
            VPS_PUBLIC_IPV4=203.0.113.10
            VLESS_PATH=/vless-0123456789ab
            cdn_public_origin_header_guard_ok || exit 9
        ' _ "${ROOT_DIR}" "${profile}" >/dev/null 2>&1 \
        || fail "源站守卫探测失败（${profile}）"
    printf '%s' "${url_log}"
}
mode2_urls=$(<"$(origin_guard_case cloudfront)")
assert_contains "模式 2 探测 Caddy 443" "${mode2_urls}" "https://origin.example.com:443/vless-0123456789ab"
assert_contains "模式 2 守卫探测钉本机公网 IP 与 Caddy 443" "${mode2_urls}" \
    "--resolve origin.example.com:443:203.0.113.10"

# --- 6b. WP4 模式 3 源站守卫公网探测：单 443 落入伪装站必须恒为 404 -------------
mode3_guard_case() { # $1=stub HTTP 状态码
    local code=$1
    local stub_dir="${TMP_DIR}/curl-stub-m3-${code}"
    local url_log="${TMP_DIR}/origin-guard-m3-${code}.log"
    mkdir -p "${stub_dir}"
    : >"${url_log}"
    cat >"${stub_dir}/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ORIGIN_GUARD_LOG}"
printf '%s' "${FAKE_HTTP_CODE}"
FAKE_CURL
    chmod 0755 "${stub_dir}/curl"
    PATH="${stub_dir}:${PATH}" ORIGIN_GUARD_LOG="${url_log}" FAKE_HTTP_CODE="${code}" \
    RUNTIME_TMP="${TMP_DIR}/guard-runtime-m3-${code}" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/guard-state-m3-${code}" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/guard-subscriptions" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            CF_ORIGIN_DOMAIN=origin.example.com
            DIRECT_DOMAIN=origin.example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            VLESS_PATH=/vless-0123456789ab
            ALLOWED_TOKENS="{\"owner\":\"tok-abcdefgh\"}"
            cdn_public_origin_header_guard_ok
        ' _ "${ROOT_DIR}" >/dev/null 2>&1
}
mode3_guard_case 404 || fail "模式 3 源站守卫在全部 404 时必须通过"
mode3_guard_urls=$(<"${TMP_DIR}/origin-guard-m3-404.log")
assert_equal "模式 3 源站守卫共发 4 次探测（代理+订阅 × 无头+错头）" "4" \
    "$(grep -c . "${TMP_DIR}/origin-guard-m3-404.log" || true)"
assert_contains "模式 3 源站守卫探测 443 代理路径" "${mode3_guard_urls}" \
    "https://origin.example.com:443/vless-0123456789ab"
assert_contains "模式 3 源站守卫探测 443 订阅路径" "${mode3_guard_urls}" \
    "https://origin.example.com:443/subscribe?token=tok-abcdefgh"
assert_contains "模式 3 源站守卫包含错头探测" "${mode3_guard_urls}" \
    "X-Easy-All-Origin-Key: wrong-origin-key"
assert_contains "模式 3 源站守卫钉 443 与本机公网 IP" "${mode3_guard_urls}" \
    "--resolve origin.example.com:443:203.0.113.10"
assert_not_contains "模式 3 源站守卫不再探测 8443" "${mode3_guard_urls}" ":8443"
for bad_m3_code in 000 200 403 503; do
    if mode3_guard_case "${bad_m3_code}"; then
        fail "模式 3 源站守卫在返回 ${bad_m3_code} 时不得通过（必须严格 404）"
    fi
done

# --- 6c. WP4 CloudFront 分发收敛门禁：必须匹配 CustomOriginConfig.HTTPSPort ----
cf_wait_dir="${TMP_DIR}/cf-wait"
mkdir -p "${cf_wait_dir}"
cf_wait_count="${cf_wait_dir}/count"
printf '0\n' >"${cf_wait_count}"
cf_wait_ok=$(
    CF_WAIT_COUNT="${cf_wait_count}" \
    RUNTIME_TMP="${cf_wait_dir}/runtime-ok" \
    EASY_ALL_STATE_DIR_OVERRIDE="${cf_wait_dir}/state-ok" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            sleep() { :; }
            aws_cli() {
                local c
                c=$(<"${CF_WAIT_COUNT}")
                c=$((c + 1))
                printf "%s\n" "${c}" >"${CF_WAIT_COUNT}"
                case "${c}" in
                1) printf "{\"Distribution\":{\"Status\":\"Deployed\",\"DistributionConfig\":{\"Enabled\":true,\"Origins\":{\"Items\":[{\"CustomOriginConfig\":{\"HTTPSPort\":8443}}]}}}}\n" ;;
                2) printf "{\"Distribution\":{\"Status\":\"InProgress\",\"DistributionConfig\":{\"Enabled\":true,\"Origins\":{\"Items\":[{\"CustomOriginConfig\":{\"HTTPSPort\":443}}]}}}}\n" ;;
                *) printf "{\"Distribution\":{\"Status\":\"Deployed\",\"DistributionConfig\":{\"Enabled\":true,\"Origins\":{\"Items\":[{\"CustomOriginConfig\":{\"HTTPSPort\":443}}]}}}}\n" ;;
                esac
            }
            wait_for_cloudfront_distribution EDFDVBD6EXAMPLE
            printf "POLLS=%s\n" "$(<"${CF_WAIT_COUNT}")"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 3 分发收敛等待应在 HTTPSPort=443 Deployed 后通过：${cf_wait_ok}"
assert_contains "旧 8443 Deployed 与 443 InProgress 均继续等待，第 3 轮通过" "${cf_wait_ok}" "POLLS=3"

# 若全程停留在旧 8443 Deployed 而未收敛至 443，必须超时失败（防止提前撤 8443 导致 502）。
if (
    RUNTIME_TMP="${cf_wait_dir}/runtime-stale" \
    EASY_ALL_STATE_DIR_OVERRIDE="${cf_wait_dir}/state-stale" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            sleep() { :; }
            aws_cli() {
                printf "{\"Distribution\":{\"Status\":\"Deployed\",\"DistributionConfig\":{\"Enabled\":true,\"Origins\":{\"Items\":[{\"CustomOriginConfig\":{\"HTTPSPort\":8443}}]}}}}\n"
            }
            wait_for_cloudfront_distribution EDFDVBD6EXAMPLE
        ' _ "${ROOT_DIR}"
) >/dev/null 2>&1; then
    fail "CloudFront 停留在旧 HTTPSPort=8443 时 wait_for_cloudfront_distribution 必须失败"
fi

# 卸载禁用等待不限制 HTTPSPort（仅校验 Deployed + Enabled=false）。
cf_wait_disabled=$(
    RUNTIME_TMP="${cf_wait_dir}/runtime-dis" \
    EASY_ALL_STATE_DIR_OVERRIDE="${cf_wait_dir}/state-dis" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            sleep() { :; }
            aws_cli() {
                printf "{\"Distribution\":{\"Status\":\"Deployed\",\"DistributionConfig\":{\"Enabled\":false,\"Origins\":{\"Items\":[{\"CustomOriginConfig\":{\"HTTPSPort\":8443}}]}}}}\n"
            }
            wait_for_cloudfront_distribution_disabled EDFDVBD6EXAMPLE && printf "DISABLED_OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "禁用态分发等待应通过：${cf_wait_disabled}"
assert_contains "禁用态分发等待不因旧 8443 失败" "${cf_wait_disabled}" "DISABLED_OK"

# --- 6d. WP1/WP3 本机探活与公网边缘探活：无 /easy_all-health、禁 Server 头、按盘比对 ---
for mode_lib in lib/cloudfront-mode.sh lib/cloudflare-mode.sh lib/reality-cloudflare-mode.sh lib/runtime-core.sh; do
    assert_not_contains "${mode_lib} 已移除 cdn_public_health_ok" "$(<"${ROOT_DIR}/${mode_lib}")" \
        "cdn_public_health_ok"
done

probe_case_dir="${TMP_DIR}/wp1-probes"
mkdir -p "${probe_case_dir}/camo" "${probe_case_dir}/runtime" "${probe_case_dir}/state"
printf '<!doctype html><title>Custom Ops Status</title><h1>All Systems Operational</h1>\n' \
    >"${probe_case_dir}/camo/index.html"

run_caddy_probe_case() { # $1=HTTP code $2=headers $3=fallback_code $4=fallback_headers $5=fallback_body
    PROBE_CODE=$1 PROBE_HEADERS=$2 FB_CODE=$3 FB_HEADERS=$4 FB_BODY=$5 \
    PROBE_LOG="${probe_case_dir}/probe.log" \
    CAMOUFLAGE_DIR="${probe_case_dir}/camo" \
    RUNTIME_TMP="${probe_case_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${probe_case_dir}/state" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            DIRECT_DOMAIN=direct.example.com
            CF_ORIGIN_DOMAIN=direct.example.com
            ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
            systemctl() { return 0; }
            curl() {
                local arg d_file="" o_file="" url="" expect=""
                printf "%s\n" "$*" >>"${PROBE_LOG}"
                for arg in "$@"; do
                    case "${expect}" in
                    d) d_file=${arg}; expect=""; continue ;;
                    o) o_file=${arg}; expect=""; continue ;;
                    esac
                    case "${arg}" in
                    -D) expect=d ;;
                    -o) expect=o ;;
                    https://*) url=${arg} ;;
                    esac
                done
                if [[ "${url}" == *"/subscribe?token=invalid" ]]; then
                    [[ -z "${d_file}" ]] || printf "%b" "${PROBE_HEADERS}" >"${d_file}"
                    printf "%s" "${PROBE_CODE}"
                else
                    [[ -z "${d_file}" ]] || printf "%b" "${FB_HEADERS}" >"${d_file}"
                    [[ -z "${o_file}" || "${o_file}" == "/dev/null" ]] || printf "%s\n" "${FB_BODY}" >"${o_file}"
                    printf "%s" "${FB_CODE}"
                fi
            }
            runtime_caddy_probe_ok
        ' _ "${ROOT_DIR}" >/dev/null 2>&1
}

camo_html=$(<"${probe_case_dir}/camo/index.html")
: >"${probe_case_dir}/probe.log"
run_caddy_probe_case 403 'HTTP/2 403\r\nX-Robots-Tag: noindex, nofollow, noarchive\r\n\r\n' \
    200 'HTTP/2 200\r\nContent-Type: text/html\r\n\r\n' "${camo_html}" \
    || fail "403+noindex+无Server头 且 443 回落逐字节匹配自定义首页时探活应通过"
probe_log_text=$(<"${probe_case_dir}/probe.log")
assert_contains "Caddy 探活访问 /subscribe?token=invalid" "${probe_log_text}" "/subscribe?token=invalid"
assert_not_contains "Caddy 探活不再访问 /easy_all-health" "${probe_log_text}" "/easy_all-health"
assert_contains "Reality 回落探测本机 443" "${probe_log_text}" "https://direct.example.com:443/"

if run_caddy_probe_case 200 'HTTP/2 200\r\nX-Robots-Tag: noindex\r\n\r\n' \
    200 'HTTP/2 200\r\n\r\n' "${camo_html}"; then
    fail "Caddy 探活状态码非 403 时必须失败"
fi
if run_caddy_probe_case 403 'HTTP/2 403\r\n\r\n' \
    200 'HTTP/2 200\r\n\r\n' "${camo_html}"; then
    fail "Caddy 探活缺少 X-Robots-Tag noindex 时必须失败"
fi
if run_caddy_probe_case 403 'HTTP/2 403\r\nServer: Caddy\r\nX-Robots-Tag: noindex\r\n\r\n' \
    200 'HTTP/2 200\r\n\r\n' "${camo_html}"; then
    fail "Caddy 探活出现 Server 响应头时必须失败"
fi
if run_caddy_probe_case 403 'HTTP/2 403\r\nX-Robots-Tag: noindex\r\n\r\n' \
    200 'HTTP/2 200\r\nServer: Caddy\r\n\r\n' "${camo_html}"; then
    fail "Reality 回落出现 Server 响应头时必须失败"
fi
if run_caddy_probe_case 403 'HTTP/2 403\r\nX-Robots-Tag: noindex\r\n\r\n' \
    200 'HTTP/2 200\r\n\r\n' '<html>mismatch</html>'; then
    fail "Reality 回落响应体与磁盘 index.html 不一致时必须失败"
fi

# CloudFront 公网节点边缘探测：访问 /subscribe?token=invalid 返回 403。
edge_probe_log="${probe_case_dir}/edge-probe.log"
run_edge_probe_case() { # $1=HTTP status
    : >"${edge_probe_log}"
    EDGE_STATUS=$1 EDGE_LOG="${edge_probe_log}" \
    RUNTIME_TMP="${probe_case_dir}/runtime-edge" \
    EASY_ALL_STATE_DIR_OVERRIDE="${probe_case_dir}/state-edge" \
        bash -c '
            source "$1/profiles/cloudfront.sh"
            CF_NODE_DOMAIN=cf.example.com
            public_dns_curl() {
                printf "%s\n" "$*" >>"${EDGE_LOG}"
                printf "%s" "${EDGE_STATUS}"
            }
            cdn_public_node_edge_ok
        ' _ "${ROOT_DIR}" >/dev/null 2>&1
}
run_edge_probe_case 403 || fail "cdn_public_node_edge_ok 在 403 时应通过"
assert_contains "边缘探测走 /subscribe + token=invalid" "$(<"${edge_probe_log}")" "token=invalid"
assert_contains "边缘探测指向节点域名 /subscribe" "$(<"${edge_probe_log}")" "https://cf.example.com/subscribe"
assert_not_contains "边缘探测不再访问 /easy_all-health" "$(<"${edge_probe_log}")" "/easy_all-health"
for bad_edge_code in 200 404 502; do
    if run_edge_probe_case "${bad_edge_code}"; then
        fail "cdn_public_node_edge_ok 在 ${bad_edge_code} 时必须失败"
    fi
done

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
ALLOWED_TOKENS=\{\"owner\":\"token-abcdefgh\"\}
SUBSCRIPTION_CONFIG=\{\"allowedTokens\":\{\"owner\":\"token-abcdefgh\"\}\,\"nodes\":\[\]\}
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
# 终审 P1：状态 schema 1 但协议不可识别时只 source profiles/reality-cloudflare.sh，计量库
# （lib/cdn-traffic-guard.sh，仅 cloudfront-mode.sh 加载）根本没加载；旧实现用
# declare -F 守卫，于是 timer 与 mangle 计数链残留，timer 每 15 秒调用即将被删除的命令。
# systemctl/iptables/flock 是外部边界，用 PATH 替身记录；计量锁目录要求的 0:0 属主
# 是 root 边界，非 root 测试用 install 替身忽略 -o/-g，其余参数原样透传。
incomplete_uninstall_case() {
    local case_dir="${TMP_DIR}/incomplete-uninstall"
    local real_install
    real_install=$(command -v install)
    mkdir -p "${case_dir}/state" "${case_dir}/bin" "${case_dir}/systemd" \
        "${case_dir}/counter" "${case_dir}/subs/subscriptions" "${case_dir}/subs/camouflage"
    printf 'sub-data\n' >"${case_dir}/subs/subscriptions/base64.txt"
    printf '<html>managed</html>\n' >"${case_dir}/subs/camouflage/index.html"
    printf '<html>user custom site</html>\n' >"${case_dir}/subs/camouflage/user-custom.html"
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
    CAMOUFLAGE_DIR="${case_dir}/subs/camouflage" \
    SINGBOX_BIN="${case_dir}/core/sing-box/sing-box" \
    XRAY_BIN="${case_dir}/core/xray/xray" \
    CADDY_BIN="${case_dir}/core/caddy/caddy" \
    SINGBOX_SERVICE=easy_all-singbox.service \
    XRAY_SERVICE=easy_all-xray.service \
    CADDY_SERVICE=easy_all-caddy.service \
    SINGBOX_SERVICE_FILE="${case_dir}/units/easy_all-singbox.service" \
    XRAY_SERVICE_FILE="${case_dir}/units/easy_all-xray.service" \
    CADDY_SERVICE_FILE="${case_dir}/units/easy_all-caddy.service" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
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
[[ ! -e "${TMP_DIR}/incomplete-uninstall/subs/subscriptions" ]] \
    || fail "不完整状态卸载必须删除订阅目录"
[[ ! -e "${TMP_DIR}/incomplete-uninstall/subs/camouflage/index.html" ]] \
    || fail "不完整状态卸载必须回收受管伪装页"
[[ -s "${TMP_DIR}/incomplete-uninstall/subs/camouflage/user-custom.html" ]] \
    || fail "不完整状态卸载不得通过 rm -rf 父目录误删用户的自定义站点文件"

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
source "${EASY_ALL_TEST_ROOT}/profiles/reality-cloudflare.sh"
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

# 9a. 五个 CDN 模式的安装入口都调用收集器并拼出该模式的后缀；模式 1 不调用。
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
            prompt_secret_into() { printf -v "$1" "%s" "0123456789abcdef0123456789abcdef"; }
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
reality-cloudfront cloudfront.182682.xyz
cloudflare cloudflare.182682.xyz
reality-cloudflare cloudflare.182682.xyz
reality-cloudflare-xhttp cloudflare.182682.xyz
EDGE_PROFILES
# 9b. 真实非终端 stdin：收集器整体 no-op（不提示也不改配置；验收条件 6）。
edge_cfg_none='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
edge_cfg_upper='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"E6G7GS3V1G.Cloudflare.182682.XYZ"}'
for edge_noop_cfg in "${edge_cfg_upper}" "${edge_cfg_none}"; do
    edge_noop=$(
        RUNTIME_TMP="${TMP_DIR}/edge-noop/runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/edge-noop/state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/edge-noop/certs" \
            bash -c '
                source "$1/profiles/reality-cloudflare.sh"
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
            source "$1/profiles/reality-cloudflare.sh"
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
            printf "CONFIG=%s\nPREFIX=%s\n" "${SUBSCRIPTION_CONFIG}" "${CDN_EDGE_PREFIX:-}"
        ' _ "${ROOT_DIR}" >"${dir}/log" 2>&1 || true
    status_line=$(sed -n 's/^STATUS=//p' "${dir}/log" 2>/dev/null)
    config_line=$(sed -n 's/^CONFIG=//p' "${dir}/log" 2>/dev/null)
    prefix_line=$(sed -n 's/^PREFIX=//p' "${dir}/log" 2>/dev/null)
    printf 'STATUS=%s\nCONFIG=%s\nPREFIX=%s\nSTDOUT:\n%s\nSTDERR:\n%s\n' \
        "${status_line:-0}" "${config_line}" "${prefix_line}" \
        "$(cat "${dir}/stdout" 2>/dev/null)" "$(cat "${dir}/stderr" 2>/dev/null)"
}
stream_of() { # $1=edge_case 块 $2=STDOUT|STDERR
    printf '%s\n' "$1" | awk -v want="$2" '
        /^STDOUT:$/ { section = "STDOUT"; next }
        /^STDERR:$/ { section = "STDERR"; next }
        /^STATUS=/ || /^CONFIG=/ || /^PREFIX=/ { section = ""; next }
        section == want { print }
    '
}
config_of() { sed -n 's/^CONFIG=//p' <<<"$1"; }
prefix_of() { sed -n 's/^PREFIX=//p' <<<"$1"; }
status_of() { sed -n 's/^STATUS=//p' <<<"$1"; }

# 分支 1：字段是生成的 10 位前缀形态 → 提示默认前缀，回车后值不变（验收条件 2）。
edge_cfg_prefix='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k7m2qp4x9d.cloudflare.182682.xyz"}'
edge_branch1=$(edge_case "${edge_cfg_prefix}" 1 collect_cdn_edge_address "" "" "")
assert_contains "分支 1 提示默认前缀" "$(stream_of "${edge_branch1}" STDERR)" \
    "CDN 优选前缀 [k7m2qp4x9d]（回车采用）："
assert_equal "分支 1 回车后配置不变" "${edge_cfg_prefix}" "$(config_of "${edge_branch1}")"
assert_equal "分支 1 记下沿用前缀" "k7m2qp4x9d" "$(prefix_of "${edge_branch1}")"
assert_not_contains "提示文案不用 prompt_value 的默认值后缀" \
    "${edge_branch1}" "直接回车使用默认值"

# 分支 1 的两个边角：大写生成值（规范化后仍按前缀形态处理）与历史后缀跨模式（回车按当前模式重写）。
edge_cfg_upper_prefix='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"K7M2QP4X9D.Cloudfront.182682.XYZ"}'
edge_branch1_upper=$(edge_case "${edge_cfg_upper_prefix}" 0 collect_cdn_edge_address "" "" "")
assert_contains "大写生成值仍按前缀形态提示" "$(stream_of "${edge_branch1_upper}" STDERR)" \
    "CDN 优选前缀 [k7m2qp4x9d]（回车采用）："
assert_equal "大写生成值回车后前缀规范化为小写" "k7m2qp4x9d" "$(prefix_of "${edge_branch1_upper}")"
assert_equal "大写生成值不改动配置" "${edge_cfg_upper_prefix}" "$(config_of "${edge_branch1_upper}")"

edge_branch1_cross=$(edge_case "${edge_cfg_prefix}" 0 collect_cdn_edge_address "" "cloudfront" "")
assert_contains "跨模式续装仍提示原前缀" "$(stream_of "${edge_branch1_cross}" STDERR)" \
    "CDN 优选前缀 [k7m2qp4x9d]（回车采用）："
assert_equal "跨模式续装沿用原前缀" "k7m2qp4x9d" "$(prefix_of "${edge_branch1_cross}")"

# 分支 3：续装且无字段 → 不再允许关闭，默认新随机前缀，回车后按模式写入。
edge_branch3=$(edge_case "${edge_cfg_none}" 1 collect_cdn_edge_address "" "" "")
edge_branch3_default=$(sed -n 's/.*CDN 优选前缀 \[\([^]]*\)\].*/\1/p' \
    <<<"$(stream_of "${edge_branch3}" STDERR)")
[[ "${edge_branch3_default}" =~ ^[a-z][a-z0-9]{9}$ ]] \
    || fail "分支 3 必须给出 10 位随机前缀（不允许 off），实际 <${edge_branch3_default}>"
assert_equal "分支 3 记下新前缀" "${edge_branch3_default}" "$(prefix_of "${edge_branch3}")"

# 分支 4：全新首装且无字段 → 默认是新的 10 位前缀，回车后拼上当前模式后缀。
edge_branch4=$(edge_case "${edge_cfg_none}" 0 collect_cdn_edge_address "" "" "")
edge_branch4_default=$(sed -n 's/.*CDN 优选前缀 \[\([^]]*\)\].*/\1/p' \
    <<<"$(stream_of "${edge_branch4}" STDERR)")
[[ "${edge_branch4_default}" =~ ^[a-z][a-z0-9]{9}$ ]] \
    || fail "分支 4 默认值必须是 10 位随机前缀，实际 <${edge_branch4_default}>"
assert_equal "分支 4 记下新前缀" "${edge_branch4_default}" "$(prefix_of "${edge_branch4}")"

# 9d. 交互原语：写入判定零副作用、提示循环文案与重填（§11 第 11 项）。
edge_store_prefix=$(edge_case "${edge_cfg_none}" 0 cdn_edge_store_answer k7m2qp4x9d "" "")
assert_equal "合法前缀被记住" "k7m2qp4x9d" "$(prefix_of "${edge_store_prefix}")"
assert_equal "写入判定不改配置" "${edge_cfg_none}" "$(config_of "${edge_store_prefix}")"
edge_store_cf=$(edge_case "${edge_cfg_none}" 0 cdn_edge_store_answer k7m2qp4x9d cloudfront "")
assert_equal "写入判定与模式无关，只记前缀" "k7m2qp4x9d" "$(prefix_of "${edge_store_cf}")"
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
assert_equal "重填后记住第二次输入" "k2v8nq4zt6" "$(prefix_of "${edge_loop}")"
edge_loop_off=$(edge_case "${edge_cfg_prefix}" 0 cdn_edge_prompt_loop k7m2qp4x9d "" "off" "k2v8nq4zt6")
assert_equal "off 不再关闭而是重填" "2" \
    "$(stream_of "${edge_loop_off}" STDERR | grep -c 'CDN 优选前缀 \[k7m2qp4x9d\]（回车采用）：')"
assert_equal "off 后的重新输入被记住" "k2v8nq4zt6" "$(prefix_of "${edge_loop_off}")"
edge_loop_enter=$(edge_case "${edge_cfg_none}" 0 cdn_edge_prompt_loop k7m2qp4x9d "" "")
assert_equal "空输入采用默认值" "k7m2qp4x9d" "$(prefix_of "${edge_loop_enter}")"

# 9d-2. 串联：模式 3 的收集器按 cloudfront 后缀落盘，并经形状校验原样通过。
edge_chain_case() { # $1=订阅配置 -> stdout: CONFIG=<写后配置> / EDGE=<校验后 cdnEdgeAddress>
    local dir
    dir=$(mktemp -d "${TMP_DIR}/edge-chain.XXXXXX")
    mkdir -p "${dir}/state/certs" "${dir}/runtime"
    RUNTIME_TMP="${dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${dir}/state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${dir}/subs" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            SUBSCRIPTION_CONFIG=$2
            # 模拟交互终端：回车采用默认前缀（同 9c 的 stub 手法）。
            cdn_edge_interactive() { return 0; }
            read_bilingual() { printf -v "$2" "%s" ""; }
            collect_cdn_edge_address
            apply_cdn_edge_prefix
            normalized=$(normalize_subscription_config "${SUBSCRIPTION_CONFIG}" "[]")
            printf "CONFIG=%s\nEDGE=%s\n" "${SUBSCRIPTION_CONFIG}" \
                "$(jq -r .cdnEdgeAddress <<<"${normalized}")"
        ' _ "${ROOT_DIR}" "$1" 2>&1
}
edge_chain_cfg='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
edge_chain=$(edge_chain_case "${edge_chain_cfg}") \
    || fail "reality-cloudfront 串联收集/写入/校验失败：${edge_chain}"
edge_chain_addr=$(sed -n 's/^EDGE=//p' <<<"${edge_chain}")
edge_chain_shape=no
[[ "${edge_chain_addr}" =~ ^[a-z][a-z0-9]{9}\.cloudfront\.182682\.xyz$ ]] && edge_chain_shape=yes
assert_equal "reality-cloudfront 串联后的优选地址形状：<${edge_chain_addr}>" "yes" "${edge_chain_shape}"
assert_contains "reality-cloudfront 串联把地址写进订阅配置" \
    "$(sed -n 's/^CONFIG=//p' <<<"${edge_chain}")" "\"cdnEdgeAddress\":\"${edge_chain_addr}\""

# 9d-3. 串联：模式 4 按 cloudflare 后缀落盘（与模式 1 同形）。
edge_cf_chain_case() { # $1=订阅配置 -> stdout: CONFIG=<写后配置> / EDGE=<校验后 cdnEdgeAddress>
    local dir
    dir=$(mktemp -d "${TMP_DIR}/edge-cf-chain.XXXXXX")
    mkdir -p "${dir}/state/certs" "${dir}/runtime"
    RUNTIME_TMP="${dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${dir}/state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${dir}/subs" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            SUBSCRIPTION_CONFIG=$2
            cdn_edge_interactive() { return 0; }
            read_bilingual() { printf -v "$2" "%s" ""; }
            collect_cdn_edge_address
            apply_cdn_edge_prefix
            normalized=$(normalize_subscription_config "${SUBSCRIPTION_CONFIG}" "[]")
            printf "CONFIG=%s\nEDGE=%s\n" "${SUBSCRIPTION_CONFIG}" \
                "$(jq -r .cdnEdgeAddress <<<"${normalized}")"
        ' _ "${ROOT_DIR}" "$1" 2>&1
}
edge_cf_chain=$(edge_cf_chain_case "${edge_chain_cfg}") \
    || fail "reality-cloudflare 串联收集/写入/校验失败：${edge_cf_chain}"
edge_cf_chain_addr=$(sed -n 's/^EDGE=//p' <<<"${edge_cf_chain}")
edge_cf_chain_shape=no
[[ "${edge_cf_chain_addr}" =~ ^[a-z][a-z0-9]{9}\.cloudflare\.182682\.xyz$ ]] && edge_cf_chain_shape=yes
assert_equal "reality-cloudflare 串联后的优选地址形状：<${edge_cf_chain_addr}>" "yes" "${edge_cf_chain_shape}"
assert_contains "reality-cloudflare 串联把地址写进订阅配置" \
    "$(sed -n 's/^CONFIG=//p' <<<"${edge_cf_chain}")" "\"cdnEdgeAddress\":\"${edge_cf_chain_addr}\""

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
assert_equal "订阅事务模式库清单" "cloudflare-mode.sh cloudfront-mode.sh reality-cloudflare-mode.sh" \
    "${edge_mode_libs}"

# 9f. 交互读取原语：括号粘贴标记与控制字符不得混进读到的值；
# 静默读必须是“一次性整行读”（逐字符 read -n 会丢字节挂死，实测见 CHANGELOG）。
prompt_read_case() { # $1=输入（printf %b 解释转义） $2=silent(0|1) -> 读到的值
    printf '%b' "$1" \
        | bash -c 'source "$1/lib/log.sh"; read_prompt "> " got "$2"; printf "%s" "${got}"' \
            _ "${ROOT_DIR}" "$2" 2>/dev/null
}
prompt_token="tok-abcdefgh1234567890"
assert_equal "静默读取读到整行" "${prompt_token}" \
    "$(prompt_read_case "${prompt_token}\n" 1)"
assert_equal "静默读取剥离括号粘贴标记" "${prompt_token}" \
    "$(prompt_read_case "\033[200~${prompt_token}\033[201~\n" 1)"
assert_equal "静默读取剔除行尾 \\r" "${prompt_token}" \
    "$(prompt_read_case "${prompt_token}\r\n" 1)"
assert_equal "普通读取剔除括号粘贴标记" "5" \
    "$(prompt_read_case '\033[200~5\033[201~\n' 0)"
# 静默读必须一次性读：源文件里不得再出现逐字符读。
assert_not_contains "静默读取不再逐字符读" "$(<"${ROOT_DIR}/lib/log.sh")" "read -r -s -n 1"
# 凭据提示必须直接读进目标变量，不得包进 $( )（子 shell 的终端读会不等输入就返回空）。
assert_not_contains "Token 提示不用命令替换读入" "$(<"${ROOT_DIR}/lib/cf-dns.sh")" "prompt_secret "
assert_contains "Token 提示读进目标变量" "$(<"${ROOT_DIR}/lib/cf-dns.sh")" \
    "prompt_secret_into CLOUDFLARE_API_TOKEN"
assert_contains "AWS 凭据读进目标变量" "$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")" \
    "prompt_secret_into AWS_ACCESS_KEY_ID"
assert_not_contains "AWS 凭据不用命令替换读入" "$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")" "prompt_secret '"
# 命令替换形态本身也要守住：$(prompt_secret_into …) 这种回归在上面的断言下会漏网。
assert_not_contains "Token 提示不包进命令替换" "$(<"${ROOT_DIR}/lib/cf-dns.sh")" '$(prompt_secret'
assert_not_contains "AWS 凭据不包进命令替换" "$(<"${ROOT_DIR}/lib/cloudfront-mode.sh")" '$(prompt_secret'
assert_not_contains "debian-init 密码不包进命令替换" "$(<"${ROOT_DIR}/scripts/debian-init.sh")" '$(prompt_secret'
assert_not_contains "debian-init 密码不用命令替换读入" "$(<"${ROOT_DIR}/scripts/debian-init.sh")" '$(read_secret_into' 
# 内核重启提示曾用裸 read：raw 会话下会在安装最后一步挂住。
reboot_prompt_body=$(sed -n '/^prompt_kernel_reboot() {/,/^}/p' "${ROOT_DIR}/lib/tcp-tuning.sh")
assert_contains "内核重启提示走共享读取原语" "${reboot_prompt_body}" "read_prompt '"
assert_not_contains "内核重启提示不再用裸 read" "${reboot_prompt_body}" "read -r choice"
# SSH 端口迁移收尾提示：红字 + 会话风险 + 纯交互确认重启（无跳过分支）。
assert_not_contains "迁移提示无 EASY_ALL_NO_REBOOT 跳过分支" \
    "${reboot_prompt_body}" "EASY_ALL_NO_REBOOT"
assert_not_contains "迁移提示无 PARAMS_LOADED 跳过分支" "${reboot_prompt_body}" "PARAMS_LOADED"
assert_not_contains "迁移提示无非交互 else 分支" "${reboot_prompt_body}" '[[ -t 0 ]]'
assert_contains "迁移提示红字告知端口已迁移" "${reboot_prompt_body}" \
    'ssh端口已经修改为${target_port}，原${old_ports}端口禁用'
assert_contains "迁移提示告知会话风险" "${reboot_prompt_body}" "一旦断开"
printf '#!/usr/bin/env bash\nprintf "REBOOT-CALLED\\n"\n' >"${TMP_DIR}/fake-reboot"
chmod +x "${TMP_DIR}/fake-reboot"
mkdir -p "${TMP_DIR}/prompt-state"
: >"${TMP_DIR}/prompt-state/kernel-reboot-required"
prompt_ssh_case() { # $1=用户输入 $2=running_kernel_supported 返回值 [额外 VAR=值 ...]
    local answer=$1 kernel_ok=$2
    shift 2
    env ANSWER="${answer}" KERNEL_OK="${kernel_ok}" \
        STATE_DIR="${TMP_DIR}/prompt-state" \
        REBOOT_COMMAND="${TMP_DIR}/fake-reboot" \
        "$@" \
        bash -c '
            set -Eeuo pipefail
            source "$1/lib/log.sh"
            source "$1/lib/tcp-tuning.sh"
            running_kernel_supported() { [[ "${KERNEL_OK}" == "1" ]]; }
            printf "%s\n" "${ANSWER}" | prompt_kernel_reboot ssh-port
        ' _ "${ROOT_DIR}" 2>&1
}
prompt_reject_out=$(prompt_ssh_case n 1)
assert_contains "迁移提示使用红字" "${prompt_reject_out}" $'\033[31m'
assert_contains "迁移提示点名 22222" "${prompt_reject_out}" "22222"
assert_contains "迁移提示告知原 22 端口禁用" "${prompt_reject_out}" "原22端口禁用"
assert_contains "拒绝重启时提示 sudo reboot" "${prompt_reject_out}" "sudo reboot"
assert_not_contains "拒绝重启时不执行重启命令" "${prompt_reject_out}" "REBOOT-CALLED"
assert_not_contains "无内核需求时不提新内核" "${prompt_reject_out}" "Skyline"
prompt_accept_out=$(prompt_ssh_case y 1)
assert_contains "确认重启时执行重启命令" "${prompt_accept_out}" "REBOOT-CALLED"
assert_contains "确认重启时提示框也渲染红字" "${prompt_accept_out}" $'\033[31m'
assert_not_contains "确认重启时提示框不打印字面量转义" "${prompt_accept_out}" '\033[31m'
assert_contains "拒绝重启时提示框也渲染红字" "${prompt_reject_out}" $'\033[31m'
assert_not_contains "拒绝重启时提示框不打印字面量转义" "${prompt_reject_out}" '\033[31m'
prompt_kernel_out=$(prompt_ssh_case n 0)
assert_contains "需载入新内核时同一提示框合并" "${prompt_kernel_out}" "Skyline"
assert_equal "迁移提示与内核提示合并为一次询问" "1" \
    "$(grep -c 'ssh端口已经修改为22222' <<<"${prompt_kernel_out}")"
# 自定义迁移端口：提示文案、登录命令与安全组提醒都必须跟着目标端口走。
prompt_custom_out=$(prompt_ssh_case n 0 \
    EASY_ALL_TARGET_SSH_PORT=23456 EASY_ALL_MIGRATED_FROM_SSH_PORTS=2200)
assert_contains "自定义端口的迁移提示" "${prompt_custom_out}" \
    "ssh端口已经修改为23456，原2200端口禁用"
assert_contains "自定义端口的登录命令" "${prompt_custom_out}" "ssh -p 23456 root@<服务器 IP>"
assert_contains "自定义端口的云安全组提醒" "${prompt_custom_out}" "请先放行 TCP 23456"
assert_not_contains "自定义端口时不再提 22222" "${prompt_custom_out}" "22222"
prompt_noop_out=$(STATE_DIR="${TMP_DIR}/prompt-state" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"
    source "$1/lib/tcp-tuning.sh"
    running_kernel_supported() { return 0; }
    prompt_kernel_reboot
' _ "${ROOT_DIR}" 2>&1)
assert_equal "无内核需求且无参数时直接返回" "" "${prompt_noop_out}"

# 安装收尾选了「1. 不变更」：收尾降级为内核模式，不得出现任何 SSH 端口警示。
# prompt_ssh_case 的第二参数是 running_kernel_supported 的返回值：1=内核已兼容（无需重启）、0=待换内核。
prompt_unchanged_out=$(prompt_ssh_case n 1 EASY_ALL_SSH_PORT_CHANGED=0)
assert_equal "不变更且无需换内核时收尾无输出" "" "${prompt_unchanged_out}"
prompt_unchanged_kernel_out=$(prompt_ssh_case n 0 EASY_ALL_SSH_PORT_CHANGED=0)
assert_contains "不变更时仍提示载入新内核" "${prompt_unchanged_kernel_out}" "Skyline"
assert_contains "不变更且需换内核时走内核提示框" "${prompt_unchanged_kernel_out}" "载入新内核"
assert_not_contains "不变更时不提 SSH 端口已改" "${prompt_unchanged_kernel_out}" "ssh端口已经修改为"
assert_not_contains "不变更时不出现默认端口 22222" "${prompt_unchanged_kernel_out}" "22222"
assert_not_contains "不变更时不提示 ssh -p 登录" "${prompt_unchanged_kernel_out}" "ssh -p"
assert_not_contains "不变更时不提示安全组放行新端口" "${prompt_unchanged_kernel_out}" "放行 TCP"
assert_not_contains "不变更且拒绝重启时不提端口生效" "${prompt_unchanged_kernel_out}" \
    "端口与新配置才会生效"
assert_contains "不变更且拒绝重启时用通用提示" "${prompt_unchanged_kernel_out}" "sudo reboot"

# 部署事务用例不依赖真实 TLS：无条件先跑，TLS 门只影响真实握手那一段。
run_certificate_deploy_cases
run_tls_certificate_cases

# --- 8. 四模式 DNS 等待：清本机缓存 + 180 轮 × 2 秒轮询 + 拒绝 dig 超时文本误判 ---------
dns_wait_log="${TMP_DIR}/dns-wait.log"
dns_wait_bin="${TMP_DIR}/dns-wait-bin"
mkdir -p "${dns_wait_bin}"
cat >"${dns_wait_bin}/resolvectl" <<EOF
#!/usr/bin/env bash
printf 'FLUSH %s\n' "\$*" >>$(printf '%q' "${dns_wait_log}")
EOF
chmod +x "${dns_wait_bin}/resolvectl"

# 8.1 默认轮询上限为 180 轮 × 2 秒（每轮另计 dig 超时；public 作用域最多 3 次 dig）
dns_defaults=$(bash -c 'source "$1/lib/runtime-core.sh"; printf "%s:%s\n" "${DNS_WAIT_ATTEMPTS}" "${DNS_WAIT_SECONDS}"' _ "${ROOT_DIR}")
assert_contains "默认 DNS 轮询上限为 180 轮 × 2 秒" "${dns_defaults}" "180:2"

# 8.2 模式 2/5 安装阶段：先清缓存再 dig（只用系统解析），第 2 次返回目标 IP 时通过
: >"${dns_wait_log}"
dns_wait_count_file="${TMP_DIR}/dns-wait-count"
printf '0\n' >"${dns_wait_count_file}"
dns_cf_ok=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=3 DNS_WAIT_SECONDS_OVERRIDE=0 \
        DNS_WAIT_TEST_LOG="${dns_wait_log}" DNS_WAIT_TEST_COUNT="${dns_wait_count_file}" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            CF_ORIGIN_DOMAIN=stat.example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            dig() {
                local c
                c=$(<"${DNS_WAIT_TEST_COUNT}")
                c=$((c + 1))
                printf "%s\n" "${c}" >"${DNS_WAIT_TEST_COUNT}"
                printf "DIG#%s %s\n" "${c}" "$*" >>"${DNS_WAIT_TEST_LOG}"
                if ((c == 1)); then
                    printf ";; connection timed out; no servers could be reached\n"
                else
                    printf "203.0.113.10\n"
                fi
            }
            cdn_wait_for_origin_dns
            printf "OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 2/5 DNS 重试应成功：${dns_cf_ok}"
assert_contains "模式 2/5 等待前先清本机缓存" "$(<"${dns_wait_log}")" "FLUSH flush-caches"
assert_contains "模式 2/5 第 2 轮命中目标 IP 后成功" "${dns_cf_ok}" "OK"
flush_line=$(grep -n '^FLUSH ' "${dns_wait_log}" | head -n 1 | cut -d: -f1)
dig_line=$(grep -n '^DIG#' "${dns_wait_log}" | head -n 1 | cut -d: -f1)
((flush_line < dig_line)) || fail "清缓存必须早于第一次 dig"

# 8.3 模式 1：dig 返回超时错误文本时不得误判为成功；返回合法 IPv4 才通过
: >"${dns_wait_log}"
dns_cf2_fail=0
dns_cf2_out=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=2 DNS_WAIT_SECONDS_OVERRIDE=0 \
        DNS_WAIT_TEST_LOG="${dns_wait_log}" \
        bash -c '
            source "$1/profiles/cloudflare.sh"
            CF_NODE_DOMAIN=cf.example.com
            dig() {
                printf "DIG %s\n" "$*" >>"${DNS_WAIT_TEST_LOG}"
                printf ";; connection timed out; no servers could be reached\n"
            }
            cdn_wait_for_node_dns
        ' _ "${ROOT_DIR}" 2>&1
) || dns_cf2_fail=$?
((dns_cf2_fail != 0)) || fail "模式 1 dig 超时文本不能被当成解析成功"
assert_contains "模式 1 失败提示清晰" "${dns_cf2_out}" "Cloudflare 节点域名尚未解析"
assert_contains "模式 1 等待前先清本机缓存" "$(<"${dns_wait_log}")" "FLUSH flush-caches"

# 8.4 模式 4：公网订阅验收前先清缓存并等待订阅域名解析
: >"${dns_wait_log}"
dns_direct_fail=0
dns_direct_out=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=2 DNS_WAIT_SECONDS_OVERRIDE=0 \
        DNS_WAIT_TEST_LOG="${dns_wait_log}" \
        bash -c '
            source "$1/profiles/reality-cloudflare.sh"
            SUBSCRIPTION_MODE=deploy
            SUBSCRIPTION_DOMAIN=sub.example.com
            dig() {
                printf "DIG %s\n" "$*" >>"${DNS_WAIT_TEST_LOG}"
                return 0
            }
            direct_validate_public_runtime
        ' _ "${ROOT_DIR}" 2>&1
) || dns_direct_fail=$?
((dns_direct_fail != 0)) || fail "模式 4 订阅域名未解析时应阻断"
assert_contains "模式 4 失败提示清晰" "${dns_direct_out}" "订阅域名尚未解析"
assert_contains "模式 4 等待前先清本机缓存" "$(<"${dns_wait_log}")" "FLUSH flush-caches"

# 8.5 公网验收入口（模式 1）两个都查：仅一方命中即通过，但必须留下判定不一致的告警
: >"${dns_wait_log}"
dns_partial_hit=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
        DNS_WAIT_TEST_LOG="${dns_wait_log}" \
        bash -c '
            source "$1/profiles/cloudflare.sh"
            CF_NODE_DOMAIN=cf.example.com
            dig() {
                printf "DIG %s\n" "$*" >>"${DNS_WAIT_TEST_LOG}"
                if [[ "$*" == *"@1.1.1.1"* ]]; then
                    printf "203.0.113.10\n"
                fi
                return 0
            }
            cdn_wait_for_node_dns
            printf "PARTIAL_HIT_OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "仅 1.1.1.1 命中而 8.8.8.8 为空时应按命中方通过：${dns_partial_hit}"
assert_contains "部分命中后仍通过验收" "${dns_partial_hit}" "PARTIAL_HIT_OK"
assert_contains "部分命中时告警点名未命中的解析器" "${dns_partial_hit}" \
    "公共 DNS 判定不一致（1.1.1.1=已命中，8.8.8.8=尚未返回该记录）"
assert_contains "检查同时查询了 1.1.1.1 与 8.8.8.8" "$(<"${dns_wait_log}")" "@1.1.1.1"
assert_contains "检查同时查询了 8.8.8.8" "$(<"${dns_wait_log}")" "@8.8.8.8"

dns_both_ok=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
        bash -c '
            source "$1/profiles/cloudflare.sh"
            CF_NODE_DOMAIN=cf.example.com
            dig() {
                if [[ "$*" == *"@1.1.1.1"* || "$*" == *"@8.8.8.8"* ]]; then
                    printf "203.0.113.10\n"
                fi
                return 0
            }
            cdn_wait_for_node_dns
            printf "BOTH_OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "1.1.1.1 与 8.8.8.8 均命中时应通过：${dns_both_ok}"
assert_contains "双公共 DNS 均命中后通过" "${dns_both_ok}" "BOTH_OK"
[[ "${dns_both_ok}" != *"判定不一致"* ]] || fail "双解析器一致时不应产生不一致告警：${dns_both_ok}"

# 8.6 两个公共 DNS 都未给出记录且至少一方不可达时，用系统默认 DNS 取第三个意见
dns_fallback_ok=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
        bash -c '
            source "$1/profiles/cloudflare.sh"
            CF_NODE_DOMAIN=cf.example.com
            dig() {
                if [[ "$*" == *"@1.1.1.1"* || "$*" == *"@8.8.8.8"* ]]; then
                    printf ";; connection timed out; no servers could be reached\n"
                    return 9
                fi
                printf "203.0.113.10\n"
            }
            cdn_wait_for_node_dns
            printf "FALLBACK_OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "公共 DNS 均不可达时应回退系统 DNS 并通过：${dns_fallback_ok}"
assert_contains "公共 DNS 均不可达时回退系统 DNS" "${dns_fallback_ok}" "FALLBACK_OK"
assert_contains "回退系统 DNS 时留告警证据" "${dns_fallback_ok}" \
    "公共 DNS 未给出该记录（1.1.1.1=不可达，8.8.8.8=不可达），已按系统默认 DNS 判定解析生效"

dns_fallback_sys_fail=0
PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
    bash -c '
        source "$1/profiles/cloudflare.sh"
        CF_NODE_DOMAIN=cf.example.com
        dig() {
            printf ";; connection timed out; no servers could be reached\n"
            return 9
        }
        cdn_wait_for_node_dns
    ' _ "${ROOT_DIR}" >/dev/null 2>&1 || dns_fallback_sys_fail=$?
((dns_fallback_sys_fail != 0)) || fail "公共 DNS 与系统 DNS 均无应答时不得判为通过"

# 8.7 一方未命中（1.1.1.1 无记录）、另一方不可达（8.8.8.8 超时）：系统 DNS 命中则通过并告警
dns_partial_fallback_ok=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
        bash -c '
            source "$1/profiles/cloudflare.sh"
            CF_NODE_DOMAIN=cf.example.com
            dig() {
                if [[ "$*" == *"@1.1.1.1"* ]]; then
                    return 0
                fi
                if [[ "$*" == *"@8.8.8.8"* ]]; then
                    printf ";; connection timed out; no servers could be reached\n"
                    return 9
                fi
                printf "203.0.113.10\n"
            }
            cdn_wait_for_node_dns
            printf "PARTIAL_FALLBACK_OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "一方公共 DNS 未命中、一方不可达时应用系统 DNS 兜底通过：${dns_partial_fallback_ok}"
assert_contains "部分命中兜底后通过" "${dns_partial_fallback_ok}" "PARTIAL_FALLBACK_OK"
assert_contains "兜底告警点名两侧状态" "${dns_partial_fallback_ok}" \
    "公共 DNS 未给出该记录（1.1.1.1=尚未返回该记录，8.8.8.8=不可达）"

# 8.8 两个公共解析器都可达且都无记录时继续等待，不得由系统默认 DNS 提前通过
dns_public_both_empty_fail=0
PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
    bash -c '
        source "$1/profiles/cloudflare.sh"
        CF_NODE_DOMAIN=cf.example.com
        dig() {
            if [[ "$*" == *"@1.1.1.1"* || "$*" == *"@8.8.8.8"* ]]; then
                return 0
            fi
            printf "203.0.113.10\n"
        }
        cdn_wait_for_node_dns
    ' _ "${ROOT_DIR}" >/dev/null 2>&1 || dns_public_both_empty_fail=$?
((dns_public_both_empty_fail != 0)) || fail "两个公共解析器都可达但都无记录时不得由系统 DNS 绕过"

# 8.9 安装/云端同步的源站 A 记录等待只用系统解析：公共 DNS 的污染与不可达都不影响结论
: >"${dns_wait_log}"
dns_origin_system_only=$(
    PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
        DNS_WAIT_TEST_LOG="${dns_wait_log}" \
        bash -c '
            source "$1/profiles/reality-cloudfront.sh"
            CF_ORIGIN_DOMAIN=stat.example.com
            VPS_PUBLIC_IPV4=203.0.113.10
            dig() {
                printf "DIG %s\n" "$*" >>"${DNS_WAIT_TEST_LOG}"
                if [[ "$*" == *"@1.1.1.1"* ]]; then
                    printf "198.51.100.9\n"
                    return 0
                fi
                if [[ "$*" == *"@8.8.8.8"* ]]; then
                    printf ";; connection timed out; no servers could be reached\n"
                    return 9
                fi
                printf "203.0.113.10\n"
            }
            cdn_wait_for_origin_dns
            printf "SYSTEM_ONLY_OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "安装期源站等待应只依赖系统解析：${dns_origin_system_only}"
assert_contains "安装期源站等待通过" "${dns_origin_system_only}" "SYSTEM_ONLY_OK"
[[ "$(<"${dns_wait_log}")" != *"@1.1.1.1"* && "$(<"${dns_wait_log}")" != *"@8.8.8.8"* ]] \
    || fail "安装期源站等待不得查询公共 DNS：$(<"${dns_wait_log}")"

dns_origin_mismatch_fail=0
PATH="${dns_wait_bin}:${PATH}" DNS_WAIT_ATTEMPTS_OVERRIDE=1 DNS_WAIT_SECONDS_OVERRIDE=0 \
    bash -c '
        source "$1/profiles/reality-cloudfront.sh"
        CF_ORIGIN_DOMAIN=stat.example.com
        VPS_PUBLIC_IPV4=203.0.113.10
        dig() {
            printf "198.51.100.9\n"
        }
        cdn_wait_for_origin_dns
    ' _ "${ROOT_DIR}" >/dev/null 2>&1 || dns_origin_mismatch_fail=$?
((dns_origin_mismatch_fail != 0)) || fail "安装期源站等待仍须精确匹配系统解析结果"

# 8.10 公网验收 curl 优先通过 1.1.1.1 / 8.8.8.8 解析并注入 --resolve；都拿不到时才回退默认 DNS
curl_resolve_out=$(
    bash -c '
        source "$1/profiles/reality-cloudfront.sh"
        dig() {
            if [[ "$*" == *"@1.1.1.1"* ]]; then
                printf "198.51.100.42\n"
                return 0
            fi
            if [[ "$*" == *"@8.8.8.8"* ]]; then
                printf "198.51.100.43\n"
                return 0
            fi
            return 9
        }
        curl() {
            printf "CURL %s\n" "$*"
        }
        public_dns_curl "https://edge.example.com:8443/subscribe?token=invalid"
    ' _ "${ROOT_DIR}" 2>&1
) || fail "公网验收 curl 注入 --resolve 失败：${curl_resolve_out}"
assert_contains "公网验收 curl 注入 --resolve host:port:ip" "${curl_resolve_out}" "--resolve edge.example.com:8443:198.51.100.42"

curl_half_propagated_out=$(
    bash -c '
        source "$1/profiles/reality-cloudfront.sh"
        dig() {
            if [[ "$*" == *"@1.1.1.1"* ]]; then
                printf "198.51.100.42\n"
            fi
            return 0
        }
        curl() {
            printf "CURL %s\n" "$*"
        }
        public_dns_curl "https://edge.example.com/subscribe?token=invalid"
    ' _ "${ROOT_DIR}" 2>&1
) || fail "仅一方公共 DNS 命中时应仍用命中方的 IP 钉 --resolve：${curl_half_propagated_out}"
assert_contains "半传播时仍钉命中方返回的 IP" "${curl_half_propagated_out}" \
    "--resolve edge.example.com:443:198.51.100.42"

curl_fallback_out=$(
    bash -c '
        source "$1/profiles/reality-cloudflare.sh"
        dig() {
            printf ";; connection timed out; no servers could be reached\n"
            return 9
        }
        curl() {
            printf "CURL %s\n" "$*"
        }
        public_dns_curl "https://sub.example.com/subscribe"
    ' _ "${ROOT_DIR}" 2>&1
) || fail "公共 DNS 不可达时 public_dns_curl 应回退默认解析：${curl_fallback_out}"
[[ "${curl_fallback_out}" != *"--resolve"* ]] || fail "公共 DNS 不可达时不应注入 --resolve：${curl_fallback_out}"
assert_contains "公共 DNS 不可达时仍正常调用 curl" "${curl_fallback_out}" "https://sub.example.com/subscribe"

# --- 12. 模式 5（reality-cloudflare-xhttp）：云端阶段、状态门禁与端口派生 ---------
# design §2.5.4：模式 5 跳过 WebSockets 预检、用 Transform Rule 取代 Origin Rule，
# 状态门禁校验源站头密钥与 Transform Rule 标识，端口预检不包含 8443。

# 12a. apply_cloud_phase：strict 失败必须在任何 DNS/证书/Rule 写入前中止；
#      strict 通过后只创建 Transform Rule，不查询 WebSockets、不调用 Origin Rule。
run_xhttp_cloud_phase_case() { # $1=ssl 值或 403 -> stdout: 日志
    local ssl=$1
    local tag="${ssl//\//_}"
    local log="${TMP_DIR}/xhttp-cloud-${tag}.log"
    local script="${TMP_DIR}/xhttp-cloud-${tag}.sh"
    local runtime="${TMP_DIR}/xhttp-cloud-runtime-${tag}"
    local state="${TMP_DIR}/xhttp-cloud-state-${tag}"
    local status=0
    mkdir -p "${runtime}" "${state}"
    cat >"${script}" <<XHTTP
set -Eeuo pipefail
export RUNTIME_TMP=$(printf '%q' "${runtime}")
export EASY_ALL_STATE_DIR_OVERRIDE=$(printf '%q' "${state}")
export EASY_ALL_CERT_DIR_OVERRIDE=$(printf '%q' "${state}/certs")
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE=$(printf '%q' "${state}/subscriptions")
source $(printf '%q' "${ROOT_DIR}/profiles/reality-cloudflare-xhttp.sh")
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUBSCRIPTION_MODE=deploy
SUBSCRIPTION_DOMAIN=cf.example.com
DIRECT_DOMAIN=direct.example.com
CF_NODE_DOMAIN=cf.example.com
ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
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
direct_ensure_origin_rule() { printf 'ORIGIN-RULE\n' >>$(printf '%q' "${log}"); }
direct_ensure_transform_rule() { printf 'TRANSFORM-RULE\n' >>$(printf '%q' "${log}"); }
apply_cloud_phase
XHTTP
    bash "${script}" >/dev/null 2>&1 || status=$?
    printf 'STATUS=%s\n' "${status}" >>"${log}"
    cat "${log}"
}

xhttp_strict_log=$(run_xhttp_cloud_phase_case strict)
assert_contains "模式 5 strict：先只读查询 Zone ID" "${xhttp_strict_log}" \
    "GET /zones?name=example.com&status=active&per_page=50"
assert_contains "模式 5 strict：创建 DNS 记录" "${xhttp_strict_log}" "DNS cf.example.com"
assert_contains "模式 5 strict：签发证书" "${xhttp_strict_log}" "CERT"
assert_contains "模式 5 strict：创建 Transform Rule" "${xhttp_strict_log}" "TRANSFORM-RULE"
assert_not_contains "模式 5 不创建 Origin Rule" "${xhttp_strict_log}" "ORIGIN-RULE"
assert_not_contains "模式 5 不预检 WebSockets 开关" "${xhttp_strict_log}" \
    "settings/websockets"
assert_contains "模式 5 strict：成功结束" "${xhttp_strict_log}" "STATUS=0"
ssl_line=$(grep -n 'settings/ssl' <<<"${xhttp_strict_log}" | head -n 1 | cut -d: -f1)
dns_line=$(grep -n 'DNS cf.example.com' <<<"${xhttp_strict_log}" | head -n 1 | cut -d: -f1)
[[ -n "${ssl_line}" && -n "${dns_line}" ]] || fail "模式 5 必须同时有 SSL 校验与 DNS 创建"
((ssl_line < dns_line)) || fail "模式 5 的 SSL 校验必须早于任何写请求"

for xhttp_ssl in full flexible off 403; do
    xhttp_bad_log=$(run_xhttp_cloud_phase_case "${xhttp_ssl}")
    assert_not_contains "模式 5 ${xhttp_ssl}：不创建 DNS" "${xhttp_bad_log}" "DNS "
    assert_not_contains "模式 5 ${xhttp_ssl}：不签发证书" "${xhttp_bad_log}" "CERT"
    assert_not_contains "模式 5 ${xhttp_ssl}：不创建 Transform Rule" "${xhttp_bad_log}" \
        "TRANSFORM-RULE"
    assert_not_contains "模式 5 ${xhttp_ssl}：非零退出" "${xhttp_bad_log}" "STATUS=0"
done

# 12b. cdn_validate_state_structure：模式 5 的源站头密钥与 Transform Rule 标识必须有效。
run_xhttp_state_gate() { # $1=覆盖的行（name=value；空=合法）
    local override=${1:-}
    local dir="${TMP_DIR}/xhttp-state-$RANDOM"
    mkdir -p "${dir}/runtime"
    {
        printf '%s\n' \
            'STATE_VERSION=1' \
            'PROTOCOL=reality-cloudflare-xhttp' \
            'TCP_ACCELERATION=off' \
            'VPS_PUBLIC_IPV4=203.0.113.10' \
            'CF_ZONE=example.com' \
            'CLOUDFLARE_ZONE_ID=zoneid' \
            'SUBSCRIPTION_MODE=deploy' \
            'SUB_DOWNLOAD_NAME=EASY_ALL' \
            'OWNER_TOKEN=token-abcdefgh' \
            'ALLOWED_TOKENS=\{\"owner\":\"token-abcdefgh\"\}' \
            'SUBSCRIPTION_CONFIG=\{\"allowedTokens\":\{\"owner\":\"token-abcdefgh\"\}\,\"nodes\":\[\]\}' \
            'MIHOMO_TEMPLATE_SNAPSHOT=1' \
            'SCHEDULED_REBOOT_ENABLED=0' \
            'SCHEDULED_REBOOT_HOUR=4' \
            'DIRECT_DOMAIN=direct.example.com' \
            'DIRECT_NODE_NAME=Reality' \
            'VLESS_UUID=11111111-2222-4333-8444-555555555555' \
            'REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE' \
            'REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI' \
            'REALITY_SHORT_ID=0123456789abcdef' \
            'CF_NODE_DOMAIN=cf.example.com' \
            'CF_NODE_PREFIX=CF' \
            'VLESS_PATH=/vless-0123456789ab' \
            'ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef' \
            'CLOUDFLARE_TRANSFORM_RULESET_ID=rs1' \
            'CLOUDFLARE_TRANSFORM_RULE_ID=rule1'
        [[ -z "${override}" ]] || printf '%s\n' "${override}"
    } >"${dir}/state.env"
    RUNTIME_TMP="${dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${dir}" \
    EASY_ALL_CERT_DIR_OVERRIDE="${dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${dir}/subscriptions" \
        bash -c '
            source "$1/profiles/reality-cloudflare-xhttp.sh"
            load_state
            printf "STATE-OK\n"
        ' _ "${ROOT_DIR}" 2>&1
}
xhttp_state_ok=$(run_xhttp_state_gate "") || fail "模式 5 合法状态必须通过：${xhttp_state_ok}"
assert_contains "模式 5 合法状态通过门禁" "${xhttp_state_ok}" "STATE-OK"
# override 行追加在末尾会覆盖同名变量（state.env 逐行 source）。
xhttp_state_bad_secret=$(run_xhttp_state_gate "ORIGIN_HEADER_SECRET=short") || true
assert_not_contains "模式 5 源站头密钥过短必须被拒" "${xhttp_state_bad_secret}" "STATE-OK"
assert_contains "模式 5 源站头密钥错误点名" "${xhttp_state_bad_secret}" "源站头密钥无效"
xhttp_state_bad_ruleset=$(run_xhttp_state_gate "CLOUDFLARE_TRANSFORM_RULESET_ID=") || true
assert_not_contains "模式 5 缺少 ruleset ID 必须被拒" "${xhttp_state_bad_ruleset}" "STATE-OK"
assert_contains "模式 5 缺少 ruleset ID 点名" "${xhttp_state_bad_ruleset}" \
    "必需字段：CLOUDFLARE_TRANSFORM_RULESET_ID"
xhttp_state_bad_rule=$(run_xhttp_state_gate "CLOUDFLARE_TRANSFORM_RULE_ID=bad rule") || true
assert_not_contains "模式 5 非法 rule ID 必须被拒" "${xhttp_state_bad_rule}" "STATE-OK"

# 12c. 端口预检：模式 5 只预检 443 + 回环 10086 + 伪装回环 9443，不预检 8443。
xhttp_ports=$(
    bash -c '
        source "$1/profiles/reality-cloudflare-xhttp.sh"
        prepare_fresh_install() { printf "%s\n" "PORTS: $*"; }
        cdn_prepare_install_ports
    ' _ "${ROOT_DIR}" 2>&1
) || fail "模式 5 端口预检失败：${xhttp_ports}"
assert_contains "模式 5 端口预检包含 443" "${xhttp_ports}" "443"
assert_contains "模式 5 端口预检包含回环 10086" "${xhttp_ports}" "10086"
assert_contains "模式 5 端口预检包含伪装回环 9443" "${xhttp_ports}" "9443"
assert_not_contains "模式 5 端口预检不包含 8443" "${xhttp_ports}" "8443"

# --- 14. 模式 1 纯 Xray 后端：旧版 sing-box 残留拦截 ---------------------------
# 旧装（仅有 sing-box）不得被任何写配置/重载/CDN 重载命令接管：一律在副作用前阻断。
run_legacy_singbox_case() { # $1=guard-xray|guard|edit-sub|update-core
    local case_name=$1 case_dir="${TMP_DIR}/cf-legacy-${1}"
    local script="${case_dir}/run.sh" log="${case_dir}/run.log" status=0
    mkdir -p "${case_dir}/runtime" "${case_dir}/state"
    cat >"${script}" <<LEGACY
set -Eeuo pipefail
export RUNTIME_TMP=$(printf '%q' "${case_dir}/runtime")
export EASY_ALL_STATE_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state")
export EASY_ALL_CERT_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state/certs")
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state/subscriptions")
export XRAY_BIN=$(printf '%q' "${case_dir}/xray/xray")
export SINGBOX_BIN=$(printf '%q' "${case_dir}/singbox/sing-box")
export SINGBOX_SERVICE_FILE=$(printf '%q' "${case_dir}/systemd/easy_all-singbox.service")
export CADDY_CONFIG=$(printf '%q' "${case_dir}/Caddyfile")
source $(printf '%q' "${ROOT_DIR}/profiles/cloudflare.sh")
CF_ZONE=example.com
CF_NODE_DOMAIN=cf.example.com
SUBSCRIPTION_MODE=deploy
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
require_root() { :; }
acquire_runtime_write_lock() { :; }
collect_installed_state() { :; }
snapshot_subscription_update() { printf 'SNAPSHOT\\n'; }
cloudflare_write_subscriptions() { printf 'SUBS-WRITE\\n'; }
write_runtime_config() { printf 'CONFIG-WRITE\\n'; }
runtime_reload_caddy() { printf 'CADDY-RELOAD\\n'; }
runtime_download_proxy_core() { printf 'DOWNLOAD-XRAY\\n'; }
download_caddy() { printf 'DOWNLOAD-CADDY\\n'; }
systemctl() { printf 'SYSTEMCTL %s\\n' "\$*"; }
case $(printf '%q' "${case_name}") in
guard-xray)
    install -d "\${XRAY_BIN%/*}"
    printf '#!/bin/sh\\n' >"\${XRAY_BIN}"
    chmod 0755 "\${XRAY_BIN}"
    cloudflare_require_xray_binary ;;
guard)
    install -d "\${SINGBOX_BIN%/*}"
    : >"\${SINGBOX_BIN}"
    cloudflare_require_xray_binary ;;
edit-sub)
    install -d "\${SINGBOX_BIN%/*}"
    : >"\${SINGBOX_BIN}"
    update_subscription ;;
update-core)
    install -d "\${SINGBOX_BIN%/*}"
    : >"\${SINGBOX_BIN}"
    update_current_core ;;
esac
printf 'REACHED\\n'
LEGACY
    bash "${script}" >"${log}" 2>&1 || status=$?
    printf 'STATUS=%s\n' "${status}" >>"${log}"
    cat "${log}"
}

legacy_guard_xray=$(run_legacy_singbox_case guard-xray)
assert_contains "Xray 二进制存在时维护命令不拦截" "${legacy_guard_xray}" "REACHED"
assert_equal "Xray 二进制存在时退出 0" "STATUS=0" \
    "$(grep '^STATUS=' <<<"${legacy_guard_xray}")"
legacy_guard=$(run_legacy_singbox_case guard)
assert_contains "旧版 sing-box 残留必须阻断" "${legacy_guard}" "旧版 sing-box 模式 1"
assert_not_contains "旧版残留阻断不引导 update-core" "${legacy_guard}" "update-core"
assert_not_contains "旧版残留阻断不继续执行" "${legacy_guard}" "REACHED"
assert_contains "旧版残留阻断非零退出" "${legacy_guard}" "STATUS=1"

legacy_edit_sub=$(run_legacy_singbox_case edit-sub)
assert_contains "edit-sub 在旧版残留时阻断" "${legacy_edit_sub}" "旧版 sing-box 模式 1"
assert_not_contains "edit-sub 阻断后不写订阅" "${legacy_edit_sub}" "SUBS-WRITE"
assert_not_contains "edit-sub 阻断后不改配置" "${legacy_edit_sub}" "CONFIG-WRITE"
assert_not_contains "edit-sub 阻断后不重载 Caddy" "${legacy_edit_sub}" "CADDY-RELOAD"
assert_contains "edit-sub 阻断非零退出" "${legacy_edit_sub}" "STATUS=1"

legacy_update_core=$(run_legacy_singbox_case update-core)
assert_contains "update-core 在旧版残留时阻断" "${legacy_update_core}" "旧版 sing-box 安装残留"
assert_not_contains "update-core 阻断后不下载 Xray" "${legacy_update_core}" "DOWNLOAD-XRAY"
assert_not_contains "update-core 阻断后不换核" "${legacy_update_core}" "REACHED"
assert_contains "update-core 阻断非零退出" "${legacy_update_core}" "STATUS=1"

# 纯 Xray 安装但二进制意外丢失：必须引导 update-core 修复，而不是要求重装。
missing_dir="${TMP_DIR}/cf-legacy-missing"
mkdir -p "${missing_dir}/runtime"
missing_output=$(
    RUNTIME_TMP="${missing_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${missing_dir}/state" \
    XRAY_BIN="${missing_dir}/xray/xray" \
    SINGBOX_BIN="${missing_dir}/singbox/sing-box" \
    SINGBOX_SERVICE_FILE="${missing_dir}/systemd/easy_all-singbox.service" \
        bash -c '
            source "$1/profiles/cloudflare.sh"
            CF_ZONE=example.com
            CF_NODE_DOMAIN=cf.example.com
            cloudflare_require_xray_binary
        ' _ "${ROOT_DIR}" 2>&1
) && fail "纯 Xray 安装缺二进制时维护命令必须失败"
assert_contains "纯 Xray 缺二进制引导 update-core" "${missing_output}" "update-core"
assert_not_contains "纯 Xray 缺二进制不点名旧版 sing-box" "${missing_output}" "旧版 sing-box"
legacy_apply_body=$(sed -n '/^apply_easy_all() {/,/^}/p' "${ROOT_DIR}/lib/cloudflare-mode.sh")
assert_contains "apply 调用旧装拦截" "${legacy_apply_body}" "cloudflare_require_xray_binary"
apply_guard_line=$(grep -n 'cloudflare_require_xray_binary' <<<"${legacy_apply_body}" | head -n 1 | cut -d: -f1)
apply_snapshot_line=$(grep -n 'snapshot_subscription_update' <<<"${legacy_apply_body}" | head -n 1 | cut -d: -f1)
[[ -n "${apply_guard_line}" && -n "${apply_snapshot_line}" ]] \
    || fail "apply 缺少拦截或快照定位行"
((apply_guard_line < apply_snapshot_line)) || fail "apply 的拦截必须早于订阅快照"
legacy_apply_cloud_body=$(sed -n '/^apply_cloud_resources() {/,/^}/p' "${ROOT_DIR}/lib/cloudflare-mode.sh")
assert_contains "apply-cloud 调用旧装拦截" "${legacy_apply_cloud_body}" \
    "cloudflare_require_xray_binary"
legacy_renew_body=$(sed -n '/^renew_certificate() {/,/^}/p' "${ROOT_DIR}/lib/cloudflare-mode.sh")
assert_contains "renew-cert 调用旧装拦截" "${legacy_renew_body}" "cloudflare_require_xray_binary"
legacy_edit_body=$(sed -n '/^update_subscription() {/,/^}/p' "${ROOT_DIR}/lib/cloudflare-mode.sh")
edit_guard_line=$(grep -n 'cloudflare_require_xray_binary' <<<"${legacy_edit_body}" | head -n 1 | cut -d: -f1)
edit_prompt_line=$(grep -n 'prompt_value' <<<"${legacy_edit_body}" | head -n 1 | cut -d: -f1)
[[ -n "${edit_guard_line}" && -n "${edit_prompt_line}" ]] \
    || fail "edit-sub 缺少拦截或提示定位行"
((edit_guard_line < edit_prompt_line)) || fail "edit-sub 的拦截必须早于交互提示"

# --- 15. 模式 1 公网订阅验收标记：只能是 XHTTP stream-up ----------------------
run_public_subscription_case() { # $1=ready|httpupgrade|no-mode
    local case_dir="${TMP_DIR}/cf-public-$1"
    local script="${case_dir}/run.sh" log="${case_dir}/run.log" status=0
    mkdir -p "${case_dir}/runtime"
    cat >"${script}" <<PUBLIC
set -Eeuo pipefail
export RUNTIME_TMP=$(printf '%q' "${case_dir}/runtime")
export EASY_ALL_STATE_DIR_OVERRIDE=$(printf '%q' "${case_dir}/state")
source $(printf '%q' "${ROOT_DIR}/profiles/cloudflare.sh")
CF_ZONE=example.com
CF_NODE_DOMAIN=cf.example.com
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
cdn_derive_runtime_fields
link='vless://uuid@cf.example.com:443?encryption=none&security=tls&type=xhttp&sni=cf.example.com&mode=stream-up#CF'
yaml=\$(printf 'network: xhttp\\nmode: stream-up\\n')
case $(printf '%q' "$1") in
httpupgrade)
    link='vless://uuid@cf.example.com:443?encryption=none&security=tls&type=httpupgrade&alpn=http%2F1.1&sni=cf.example.com#CF'
    yaml=\$(printf 'network: ws\\nv2ray-http-upgrade: true\\n') ;;
no-mode)
    link='vless://uuid@cf.example.com:443?encryption=none&security=tls&type=xhttp&sni=cf.example.com#CF' ;;
esac
public_dns_curl() {
    case "\$*" in
    *flag=clash*) printf '%s\\n' "\${yaml}" ;;
    *) printf '%s' "\$(printf '%s' "\${link}" | openssl base64 -A)" ;;
    esac
}
cdn_public_subscription_ok && printf 'PUBLIC-OK\\n'
PUBLIC
    bash "${script}" >"${log}" 2>&1 || status=$?
    printf 'STATUS=%s\n' "${status}" >>"${log}"
    cat "${log}"
}

public_ready=$(run_public_subscription_case ready)
assert_contains "XHTTP 订阅产物通过公网验收" "${public_ready}" "PUBLIC-OK"
assert_contains "XHTTP 订阅公网验收退出 0" "${public_ready}" "STATUS=0"
public_old=$(run_public_subscription_case httpupgrade)
assert_not_contains "旧 httpupgrade 产物不得通过公网验收" "${public_old}" "PUBLIC-OK"
assert_contains "旧 httpupgrade 产物公网验收非零退出" "${public_old}" "STATUS=1"
public_no_mode=$(run_public_subscription_case no-mode)
assert_not_contains "缺少 mode=stream-up 不得通过公网验收" "${public_no_mode}" "PUBLIC-OK"

printf 'ok - 凭据、strict 顺序、DNS 归属、证书生效与服务编排测试通过\n'

# A17/A32：文件尾汇总本轮未验证的用例。
if ((${#SKIPPED_ITEMS[@]} > 0)); then
    printf '未验证项（%s 条）：\n' "${#SKIPPED_ITEMS[@]}"
    printf '  - %s\n' "${SKIPPED_ITEMS[@]}"
fi

# A31 阶段一：本文件必须真的跑过断言（不校验条数，只拦「一个都没跑」）。
(( TESTS_ASSERTED > 0 )) || fail "无断言执行：本文件一个断言都没跑，fixture/前置条件出错时会静默全绿"
printf 'ok - asserted %s\n' "${TESTS_ASSERTED}"
