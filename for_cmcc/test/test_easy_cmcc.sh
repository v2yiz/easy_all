#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    [[ "$2" == "$3" ]] || fail "$1: expected '$2', got '$3'"
}

assert_contains() {
    [[ "$2" == *"$3"* ]] || fail "$1: missing '$3'"
}

bash -n "${ROOT_DIR}/easy_cmcc"
installer=$(<"${ROOT_DIR}/easy_cmcc")
output=$("${ROOT_DIR}/easy_cmcc" help)
assert_contains "standalone executable exposes CMCC usage" "${output}" "XHTTP stream-up、stream-one 与 WSS"

assert_contains "CMCC uses fq" "${installer}" "net.core.default_qdisc = fq"
assert_contains "CMCC uses BBR" "${installer}" "net.ipv4.tcp_congestion_control = bbr"
assert_contains "CMCC bounds receive backlog" "${installer}" "net.core.netdev_max_backlog = 16384"
assert_contains "CMCC bounds receive buffers at 32 MiB" "${installer}" "net.core.rmem_max = 33554432"
assert_contains "CMCC bounds send buffers at 32 MiB" "${installer}" "net.core.wmem_max = 33554432"
assert_contains "CMCC tunes TCP receive buffers" "${installer}" "net.ipv4.tcp_rmem = 4096 131072 33554432"
assert_contains "CMCC tunes TCP send buffers" "${installer}" "net.ipv4.tcp_wmem = 4096 65536 33554432"
assert_contains "CMCC enables MTU probing" "${installer}" "net.ipv4.tcp_mtu_probing = 1"
assert_contains "CMCC keeps long-lived connection cwnd" "${installer}" "net.ipv4.tcp_slow_start_after_idle = 0"
assert_contains "Nginx backlog matches somaxconn" "${installer}" "listen 443 ssl http2 backlog=4096;"
[[ "${installer}" != *"net.ipv4.tcp_fastopen = 3"* ]] \
    || fail "CMCC must not enable unused server-side TCP Fast Open"
[[ "${installer}" != *"net.ipv4.tcp_notsent_lowat = 16384"* ]] \
    || fail "CMCC must not globally throttle unsent TCP data"
assert_contains "CMCC resets legacy TCP Fast Open overrides" "${installer}" \
    "sysctl -q -w net.ipv4.tcp_fastopen=1"
assert_contains "CMCC resets legacy unsent queue overrides" "${installer}" \
    "sysctl -q -w net.ipv4.tcp_notsent_lowat=4294967295"
assert_contains "CMCC update reapplies TCP tuning" "${installer}" \
    'info "刷新 BBR 与 TCP 参数"'

readme=$(<"${ROOT_DIR}/README.md")
assert_contains "README identifies the standalone installer" "${readme}" \
    "独立单文件安装器"
assert_contains "README downloads the CMCC monolith" "${readme}" \
    "main/for_cmcc/easy_cmcc"
assert_contains "README uses the aligned one-line install command" "${readme}" \
    'wget -qO /root/easy_cmcc.new "https://raw.githubusercontent.com/v2yiz/easy_all/main/for_cmcc/easy_cmcc" && chmod 700 /root/easy_cmcc.new && mv -f /root/easy_cmcc.new /root/easy_cmcc && /root/easy_cmcc install'
assert_contains "README documents optimized Gemini order" "${readme}" \
    '`AI_GEMINI`：`stream-up` → `stream-one` → WSS'
assert_contains "README documents optimized download order" "${readme}" \
    '`DOWNLOAD`：`stream-up` → WSS → `stream-one`'
assert_contains "README documents the DNS-only precondition" "${readme}" \
    "DNS only / 灰云"
assert_contains "README documents enabling the CDN after install" "${readme}" \
    "Proxied / 橙云"
assert_contains "README documents isolated state" "${readme}" \
    "/etc/easy_cmcc/state.env"
assert_contains "README documents that uninstall leaves the remote Worker" "${readme}" \
    "远端 Cloudflare Worker 不会删除"
[[ "${readme}" != *"无人值守"* ]] \
    || fail "README must omit unattended-operation documentation"

if bash -c 'source "$1"; choose_protocol reality' _ "${ROOT_DIR}/easy_cmcc" \
    >/dev/null 2>&1; then
    fail "standalone executable must reject Reality"
fi

(
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/easy_cmcc"

    assert_equal "entry points at the monolith" "${ROOT_DIR}/easy_cmcc" "${ENTRY_SCRIPT_FILE}"
    assert_equal "state directory is isolated" "/etc/easy_cmcc" "${STATE_DIR}"
    assert_equal "command library is isolated" "/usr/local/lib/easy_cmcc" "${COMMAND_INSTALL_DIR}"
    assert_equal "Xray service is isolated" "easy-cmcc-xray.service" "${XRAY_SERVICE}"
    assert_equal "Nginx config is isolated" "/etc/nginx/conf.d/easy_cmcc.conf" "${NGINX_CONFIG}"
    assert_equal "acme.sh home is isolated" "/root/.acme-cmcc.sh" "${ACME_HOME}"
    assert_equal "Worker name is isolated" "easy-cmcc" "${DEFAULT_WORKER_NAME}"
    assert_contains "Worker URL uses the CMCC subtree" "${DEFAULT_SAMPLE_WORKER_URL}" "/for_cmcc/sample-worker.js"

    choose_protocol vless-xhttp >/dev/null
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    VLESS_XHTTP_DOMAIN="cmcc.example.com"
    NODE_NAME="CMCC_XHTTP"
    XHTTP_PATH="/cmcc-xhttp"
    VLESS_WS_NODE_NAME="CMCC_WSS"
    VLESS_WS_PATH="/cmcc-wss"
    links=$(build_node_link)
    assert_contains "subscription contains XHTTP" "${links}" "type=xhttp"
    assert_contains "XHTTP prefers stream-up" "${links}" "mode=stream-up"
    assert_contains "XHTTP retains stream-one fallback" "${links}" "mode=stream-one"
    assert_contains "XHTTP fallback gets a distinct name" "${links}" "CMCC_XHTTP_STREAM_ONE"
    assert_contains "XHTTP forces HTTP/2" "${links}" "alpn=h2"
    assert_contains "subscription contains WSS" "${links}" "type=ws"
    assert_contains "both transports use TCP 443" "${links}" "@cmcc.example.com:443"

    ALLOWED_TOKENS='{"owner":"test-token"}'
    SUB_DOWNLOAD_NAME="CMCC_TEST"
    SAMPLE_WORKER_SOURCE="${ROOT_DIR}/sample-worker.js"
    WORKER_NAME="easy-cmcc"
    worker_output="${TMP_DIR}/subscribe-worker.js"
    write_worker "${worker_output}"
    grep -Fq '"network":"xhttp"' "${worker_output}" \
        || fail "rendered Worker must include XHTTP"
    [[ "$(grep -Fo '"network":"xhttp"' "${worker_output}" | wc -l | tr -d ' ')" == "2" ]] \
        || fail "rendered Worker must include stream-up and stream-one XHTTP nodes"
    grep -Fq '"mode":"stream-up"' "${worker_output}" \
        || fail "rendered Worker must prefer XHTTP stream-up"
    grep -Fq '"mode":"stream-one"' "${worker_output}" \
        || fail "rendered Worker must retain XHTTP stream-one fallback"
    grep -Fq '"network":"ws"' "${worker_output}" \
        || fail "rendered Worker must include WSS"
    grep -Fq 'const DEFAULT_NODE = [NODE_CONFIG, XHTTP_STREAM_ONE_NODE_CONFIG, WS_NODE_CONFIG]' "${worker_output}" \
        || fail "rendered Worker must publish all three optimized nodes"
    grep -Fq 'mode: "auto"' "${ROOT_DIR}/easy_cmcc" \
        || fail "Xray server must accept all XHTTP upload modes"
    mihomo_nodes=$(build_mihomo_node)
    assert_contains "Mihomo nodes race dual-stack CDN addresses" "${mihomo_nodes}" \
        "ip-version: dual"
)

printf 'ok - standalone CMCC monolith tests passed\n'
