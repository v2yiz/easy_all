#!/usr/bin/env bash
# 真核心 HTTP/代理链路门禁（design §13）：起真实 sing-box + Caddy，跑订阅矩阵、
# 源站守卫、AnyTLS 与 Caddy→VLESS WebSocket 代理链路。
# 需要 root（绑定 443/8443/10086）与锁定版本核心；缺核心/端口/进程失败即非零，不跳过。
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
SB=${SINGBOX_BIN:-/etc/easy_all/sing-box/sing-box}
CADDY=${CADDY_BIN:-/etc/easy_all/caddy/caddy}
[[ "$(id -u)" -eq 0 ]] || { printf 'verify-live 需要 root（端口 443/8443）：请用 sudo 运行\n' >&2; exit 2; }
[[ -x "${SB}" ]] || { printf '缺少 sing-box：%s\n' "${SB}" >&2; exit 1; }
[[ -x "${CADDY}" ]] || { printf '缺少 Caddy：%s\n' "${CADDY}" >&2; exit 1; }

for port in 443 8443 10086 18080 18081; do
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
        printf 'verify-live: 端口 %s 已被占用；请先停止占用进程\n' "${port}" >&2
        exit 1
    fi
done
T=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-live.XXXXXX")
cleanup_fixtures() {
    local pid
    for pid in ${SBPID:-} ${CADDYPID:-} ${CPID1:-} ${CPID2:-}; do
        [[ -n "${pid}" ]] && kill "${pid}" >/dev/null 2>&1 || true
    done
    sleep 0.3
    for pid in ${SBPID:-} ${CADDYPID:-} ${CPID1:-} ${CPID2:-}; do
        [[ -n "${pid}" ]] && kill -9 "${pid}" >/dev/null 2>&1 || true
    done
    rm -rf -- "${T}"
}
mkdir -p "${T}/certs" "${T}/subs" "${T}/runtime" /run/easy_all-caddy
chmod 0700 /run/easy_all-caddy

export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${T}/policy-state"
export EASY_ALL_POLICY_RC_OVERRIDE="${T}/policy-rc.d"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${T}/progress.env"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${T}/runtime-write.lock"
export XDG_DATA_HOME="${T}/xdg"
export RUNTIME_TMP="${T}/runtime"
export EASY_ALL_STATE_DIR_OVERRIDE="${T}/state"
export EASY_ALL_CERT_DIR_OVERRIDE="${T}/certs"
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${T}/subs"
export SINGBOX_CONFIG="${T}/config.json" CADDY_CONFIG="${T}/Caddyfile"
export SINGBOX_BIN="${SB}" CADDY_BIN="${CADDY}"
export CADDY_ADMIN_SOCKET=/run/easy_all-caddy/admin.sock

# shellcheck source=lib/log.sh
source "${ROOT_DIR}/lib/log.sh"
EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
# shellcheck source=profiles/combined.sh
source "${ROOT_DIR}/profiles/combined.sh"

PROTOCOL=combined-cloudfront
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUB_DOWNLOAD_NAME=EASY_ALL
ALLOWED_TOKENS='{"owner":"tok-live-aaaaaaaa"}'
SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
DIRECT_DOMAIN=direct.example.com DIRECT_NODE_NAME=direct ANYTLS_PASSWORD=live-test-password
CF_NODE_DOMAIN=cf.example.com CF_NODE_PREFIX=CF
VLESS_UUID=11111111-2222-4111-8111-111111111111 VLESS_PATH=/vless-abcdef123456
CF_ORIGIN_DOMAIN=origin.example.com SUBSCRIPTION_DOMAIN=cf.example.com
ORIGIN_HEADER_SECRET=live-origin-secret-0123456789
CDN_TRAFFIC_PROTECTION_GB=985
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
cdn_derive_runtime_fields
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=origin.example.com" \
    -addext "subjectAltName=DNS:origin.example.com,DNS:direct.example.com,DNS:cf.example.com,DNS:sub.example.com" \
    -keyout "${T}/certs/private.key" -out "${T}/certs/fullchain.pem" >/dev/null 2>&1
chmod 0600 "${T}/certs/private.key"
render_singbox_config "${SINGBOX_CONFIG}" 0
render_caddy_config "${CADDY_CONFIG}" 0 1
for f in base64.txt base64-all.txt mihomo.yaml mihomo-all.yaml mihomo-ios.yaml mihomo-ios-all.yaml; do
    printf '%s\n' "${f}" >"${T}/subs/${f}"
done

trap cleanup_fixtures EXIT
"${SB}" run -c "${SINGBOX_CONFIG}" >"${T}/singbox.log" 2>&1 & SBPID=$!
"${CADDY}" run --config "${CADDY_CONFIG}" --adapter caddyfile >"${T}/caddy.log" 2>&1 & CADDYPID=$!
HEADER='X-Easy-All-Origin-Key: live-origin-secret-0123456789'
for _ in $(seq 1 40); do
    curl -sk --noproxy '*' --max-time 2 --resolve origin.example.com:8443:127.0.0.1 \
        -H "${HEADER}" https://origin.example.com:8443/easy_all-health 2>/dev/null \
        | grep -q 'easy_all ok' && break
    sleep 0.25
done

fail() { printf 'verify-live FAIL: %s\n' "$*" >&2; exit 1; }
code() { curl -sk --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' "$@"; }
BASE=(-H "${HEADER}" --resolve origin.example.com:8443:127.0.0.1)
TOKEN=$(jq -r '.[]' <<<"${ALLOWED_TOKENS}")

[[ "$(code "${BASE[@]}" https://origin.example.com:8443/easy_all-health)" == 200 ]] || fail health
[[ "$(curl -sk --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' \
    --resolve origin.example.com:8443:127.0.0.1 https://origin.example.com:8443/easy_all-health || true)" == 000 ]] \
    || fail "缺少源站头未被 abort"
[[ "$(code "${BASE[@]}" "https://origin.example.com:8443/subscribe?token=${TOKEN}")" == 200 ]] || fail subscribe
[[ "$(code "${BASE[@]}" "https://origin.example.com:8443/sub?token=${TOKEN}")" == 200 ]] || fail sub_alias
[[ "$(code "${BASE[@]}" "https://origin.example.com:8443/subscribe?token=bad")" == 403 ]] || fail deny
[[ "$(code "${BASE[@]}" -X POST "https://origin.example.com:8443/subscribe?token=${TOKEN}")" == 405 ]] || fail method
[[ "$(code "${BASE[@]}" "https://origin.example.com:8443/subscribe/extra?token=${TOKEN}")" == 404 ]] || fail path_suffix
[[ "$(code "${BASE[@]}" "https://origin.example.com:8443/mihomo.yaml")" == 404 ]] || fail bare_file
curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null "${BASE[@]}" \
    "https://origin.example.com:8443/subscribe?token=bad" | tr -d '\r' \
    | grep -qi 'cache-control: no-store' || fail denied_headers

cat >"${T}/client-anytls.json" <<JSON
{"log":{"level":"warn"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":18080}],
"outbounds":[{"type":"anytls","server":"127.0.0.1","server_port":443,"password":"${ANYTLS_PASSWORD}","tls":{"enabled":true,"server_name":"direct.example.com","insecure":true}}]}
JSON
cat >"${T}/client-ws.json" <<JSON
{"log":{"level":"warn"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":18081}],
"outbounds":[{"type":"vless","server":"127.0.0.1","server_port":8443,"uuid":"${VLESS_UUID}","tls":{"enabled":true,"server_name":"origin.example.com","insecure":true},"transport":{"type":"ws","path":"${VLESS_PATH}","headers":{"Host":"origin.example.com","X-Easy-All-Origin-Key":"${ORIGIN_HEADER_SECRET}"}}}]}
JSON
"${SB}" run -c "${T}/client-anytls.json" >"${T}/client-anytls.log" 2>&1 & CPID1=$!
"${SB}" run -c "${T}/client-ws.json" >"${T}/client-ws.log" 2>&1 & CPID2=$!
sleep 2
kill -0 "${CPID1}" 2>/dev/null || { tail -5 "${T}/client-anytls.log" >&2; fail "AnyTLS 客户端进程未存活"; }
kill -0 "${CPID2}" 2>/dev/null || { tail -5 "${T}/client-ws.log" >&2; fail "WebSocket 客户端进程未存活"; }
proxy_status() {
    env -u NO_PROXY -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        -u http_proxy -u https_proxy -u all_proxy \
        curl -sS --max-time 10 -x "http://127.0.0.1:$1" -o /dev/null -w '%{http_code}' \
        https://api.github.com/zen 2>/dev/null
}
for port in 18080 18081; do
    status=""
    for _ in $(seq 1 10); do
        status=$(proxy_status "${port}")
        [[ "${status}" == "200" ]] && break
        sleep 1
    done
    [[ "${status}" == "200" ]] || { tail -5 "${T}/client-anytls.log" "${T}/client-ws.log" >&2; fail "proxy ${port} 返回 ${status:-无}"; }
done
printf 'ok - 真核心 HTTP/代理链路（AnyTLS + Caddy→VLESS WebSocket）\n'
