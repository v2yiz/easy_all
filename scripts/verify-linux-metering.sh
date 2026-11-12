#!/usr/bin/env bash
# Linux 内核计量门禁（design §10）：用真实 iptables 验证 mangle 双向计数、规则唯一、
# blocked 配置拒绝与卸载回收。需要 root 与 iptables；失败即非零，不跳过。
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
[[ "$(id -u)" -eq 0 ]] || { printf 'verify-linux-metering 需要 root（iptables）：请用 sudo 运行\n' >&2; exit 2; }
command -v iptables >/dev/null 2>&1 || { printf '缺少 iptables\n' >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { printf '缺少 python3\n' >&2; exit 1; }
if iptables -t mangle -S 2>/dev/null | grep -Fq -- "easy-all-test-$$"; then
    printf 'verify-linux-metering: 测试链 easy-all-test-%s 已存在；拒绝污染/复用\n' "$$" >&2
    exit 1
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-metering.XXXXXX")
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${T}/progress.env"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${T}/runtime-write.lock"
export XDG_DATA_HOME="${T}/xdg"
export RUNTIME_TMP="${T}/runtime"
export EASY_ALL_STATE_DIR_OVERRIDE="${T}/state"
export EASY_ALL_CERT_DIR_OVERRIDE="${T}/certs"
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${T}/subs"
export CDN_TRAFFIC_COUNTER_DIR_OVERRIDE="${T}/run"
export SINGBOX_CONFIG="${T}/config.json"
export CDN_TRAFFIC_COUNTER_CHAIN_OVERRIDE="easy-all-test-$$"
mkdir -p "${RUNTIME_TMP}" "${EASY_ALL_STATE_DIR_OVERRIDE}" "${EASY_ALL_CERT_DIR_OVERRIDE}" \
    "${EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE}" "${T}/run"

metering_cleanup() {
    cdn_traffic_counters_remove >/dev/null 2>&1 || true
    terminate_fixtures
    rm -rf -- "${T}"
}
terminate_fixtures() {
    [[ -n "${SERVER_PID:-}" ]] && kill "${SERVER_PID}" >/dev/null 2>&1 || true
    sleep 0.3
    [[ -n "${SERVER_PID:-}" ]] && kill -9 "${SERVER_PID}" >/dev/null 2>&1 || true
}

# shellcheck source=lib/log.sh
source "${ROOT_DIR}/lib/log.sh"
EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
# shellcheck source=profiles/cloudfront.sh
source "${ROOT_DIR}/profiles/cloudfront.sh"

PROTOCOL=cloudfront
CDN_TRAFFIC_PROTECTION_GB=985
CF_ZONE=example.com
CF_ORIGIN_DOMAIN=origin.example.com CF_NODE_DOMAIN=cf.example.com
SUBSCRIPTION_DOMAIN=cf.example.com
VLESS_UUID=11111111-2222-4111-8111-111111111111
VLESS_PATH=/vless-abcdef123456
ORIGIN_HEADER_SECRET=live-origin-secret-0123456789
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x

fail() { printf 'verify-linux-metering FAIL: %s\n' "$*" >&2; exit 1; }
if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :10086" 2>/dev/null | grep -q .; then
    fail "回环 10086 已被占用；请先停止占用进程再运行（不能把别人的进程当成计数器夹具）"
fi

trap metering_cleanup EXIT
initialize_cdn_traffic_usage >/dev/null
cdn_traffic_prepare_counters || fail "准备计量规则失败"
cdn_traffic_counters_ready || fail "受管跳转/链不完整"
[[ "$(iptables -t mangle -S "${CDN_TRAFFIC_COUNTER_CHAIN}" | grep -c "^\-A ${CDN_TRAFFIC_COUNTER_CHAIN} ")" == 2 ]] \
    || fail "计数规则不是两条"
iptables -t mangle -S INPUT | grep -q -- "-i lo -p tcp -m tcp --dport 10086 -j ${CDN_TRAFFIC_COUNTER_CHAIN}" \
    || fail "INPUT 跳转缺少或无 lo/dport 方向"
iptables -t mangle -S OUTPUT | grep -q -- "-o lo -p tcp -m tcp --sport 10086 -j ${CDN_TRAFFIC_COUNTER_CHAIN}" \
    || fail "OUTPUT 跳转缺少或无 lo/sport 方向"

python3 - <<'PY' &
import socket
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", 10086))
s.listen(1)
c, _ = s.accept()
n = 0
while n < 200000:
    b = c.recv(65536)
    if not b:
        break
    n += len(b)
c.sendall(b"x" * 200000)
c.close()
s.close()
PY
SERVER_PID=$!
sleep 0.5
python3 - <<'PY'
import socket
s = socket.socket()
s.connect(("127.0.0.1", 10086))
s.sendall(b"x" * 200000)
n = 0
while n < 200000:
    b = s.recv(65536)
    if not b:
        break
    n += len(b)
s.close()
PY
wait "${SERVER_PID}" || true
unset SERVER_PID
IFS=$'\t' read -r up down < <(cdn_traffic_read_counters)
[[ "${up}" =~ ^[0-9]+$ && "${down}" =~ ^[0-9]+$ ]] || fail "计数不可读"
((up > 0 && down > 0)) || fail "双向计数未增长（up=${up} down=${down}）"

printf '{"inbounds":[{"tag":"vless-cdn-in"}]}' >"${SINGBOX_CONFIG}"
cdn_traffic_start_config_allowed "${SINGBOX_CONFIG}" || fail "开放配置被错误拒绝"
jq -c '.blocked=true | .enforced=true' <"${CDN_TRAFFIC_GUARD_USAGE_FILE}" >"${T}/usage.blocked"
chmod 0600 "${T}/usage.blocked"
cp "${T}/usage.blocked" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
cdn_traffic_start_config_allowed "${SINGBOX_CONFIG}" && fail "blocked 状态仍允许开放 CDN 入站"
printf '{"inbounds":[]}' >"${SINGBOX_CONFIG}"
cdn_traffic_start_config_allowed "${SINGBOX_CONFIG}" || fail "受限配置被错误拒绝"

cdn_traffic_counters_remove || fail "回收计量规则失败"
iptables -t mangle -S | grep -q "${CDN_TRAFFIC_COUNTER_CHAIN}" && fail "卸载后仍残留受管链/跳转"
printf 'ok - Linux mangle 双向计数/blocked/回收\n'
