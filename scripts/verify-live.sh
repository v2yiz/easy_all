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

for port in 443 8443 10086 18080 18081 18082 19090; do
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
        printf 'verify-live: 端口 %s 已被占用；请先停止占用进程\n' "${port}" >&2
        exit 1
    fi
done
T=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-live.XXXXXX")
cleanup_fixtures() {
    local pid
    for pid in ${SBPID:-} ${CADDYPID:-} ${CPID1:-} ${CPID2:-} ${CPID3:-}; do
        [[ -n "${pid}" ]] && kill "${pid}" >/dev/null 2>&1 || true
    done
    sleep 0.3
    for pid in ${SBPID:-} ${CADDYPID:-} ${CPID1:-} ${CPID2:-} ${CPID3:-}; do
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

# sing-box JSON 用正式渲染器生成：格式协商要与真实产物一起验收。
render_singbox_subscription_files "${T}/subs"

# 客户端 JSON 必须能被真实核心启动：只去掉需要 root 的 TUN 入口，规则与 DNS 段保持不变。
# `sing-box check` 不覆盖运行期初始化（例如 DNS detour 指向空 direct 出口会直接 FATAL）。
# clash_api 换成测试专用端口 19090，避免宿主已占用模板默认的 9090 时被误判为启动失败。
jq 'del(.inbounds[] | select(.type == "tun"))
    | .inbounds[0].listen_port = 18082
    | .outbounds = [{type: "selector", tag: "PROXY", outbounds: ["DIRECT"], default: "DIRECT"},
                    {type: "direct", tag: "DIRECT"}]
    | .experimental.cache_file.path = "'"${T}"'/client-cache.db"
    | .experimental.clash_api.external_controller = "127.0.0.1:19090"
    | .log.level = "info"' "${T}/subs/singbox.json" >"${T}/client-full.json"
"${SB}" run -c "${T}/client-full.json" >"${T}/client-full.log" 2>&1 & CPID3=$!
client_full_ok=0
for _ in $(seq 1 40); do
    if ! kill -0 "${CPID3}" 2>/dev/null; then
        break
    fi
    if grep -q "mixed-in" "${T}/client-full.log"; then
        client_full_ok=1
        break
    fi
    sleep 0.5
done
[[ "${client_full_ok}" == "1" ]] \
    || { tail -5 "${T}/client-full.log" >&2; fail "sing-box 订阅配置未通过真实核心启动校验"; }

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
[[ "$(code "${BASE[@]}" "https://origin.example.com:8443/singbox.json")" == 404 ]] || fail bare_json_file

# 格式协商：显式 flag > 已确认 sing-box UA > Clash UA > Base64。
sub_url="https://origin.example.com:8443/subscribe?token=${TOKEN}"
body() { curl -sk --noproxy '*' --max-time 10 "${BASE[@]}" "$@"; }
json_headers=$(curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null "${BASE[@]}" \
    "${sub_url}&flag=singbox" | tr -d '\r')
grep -qi '^content-type: application/json' <<<"${json_headers}" || fail json_content_type
grep -qi 'filename=EASY_ALL.json' <<<"${json_headers}" || fail json_filename
grep -qi 'vary: user-agent' <<<"${json_headers}" || fail json_vary
json_body=$(body "${sub_url}&flag=singbox")
jq -e '.outbounds | map(.tag) | index("PROXY") != null' <<<"${json_body}" >/dev/null \
    || fail json_proxy_selector
jq -e '.outbounds | map(select(.type == "anytls" or .type == "vless")) | length > 0' \
    <<<"${json_body}" >/dev/null || fail json_nodes
[[ "$(body -A 'SFA (sing-box 1.14.4; language zh_CN)' "${sub_url}")" == "${json_body}" ]] \
    || fail sfa_ua_autodetect
[[ "$(body -A 'SFA (sing-box 1.14.4; language zh_CN)' "${sub_url}&flag=clash")" == "mihomo.yaml" ]] \
    || fail sfa_ua_flag_clash_override
[[ "$(body -A 'SFA (sing-box 1.14.4; language zh_CN)' "${sub_url}&flag=base64")" == "base64.txt" ]] \
    || fail sfa_ua_flag_base64_override
[[ "$(body -A 'ClashX/1.20.0' "${sub_url}&flag=singbox")" == "${json_body}" ]] \
    || fail clash_ua_flag_singbox_override
[[ "$(body -A 'ClashX/1.20.0' "${sub_url}")" == "mihomo.yaml" ]] || fail clash_ua_yaml
[[ "$(body "${sub_url}")" == "base64.txt" ]] || fail default_base64
[[ "$(body -A 'NekoBox/1.3.3 sing-box/1.9.0' "${sub_url}")" == "base64.txt" ]] \
    || fail unconfirmed_ua_base64
[[ "$(body "${sub_url}&flag=singbox&node=all")" == "$(cat "${T}/subs/singbox-all.json")" ]] \
    || fail json_node_all
[[ "$(code "${BASE[@]}" -I "${sub_url}&flag=singbox")" == 200 ]] || fail json_head
# JSON 产物缺失只影响 JSON 请求，且返回 503 而不是其他格式。
mv "${T}/subs/singbox.json" "${T}/subs/singbox.json.off"
[[ "$(code "${BASE[@]}" "${sub_url}&flag=singbox")" == 503 ]] || fail json_missing_503
[[ "$(code "${BASE[@]}" "${sub_url}")" == 200 ]] || fail json_missing_base64_unaffected
mv "${T}/subs/singbox.json.off" "${T}/subs/singbox.json"
[[ "$(code "${BASE[@]}" "${sub_url}&flag=singbox")" == 200 ]] || fail json_restore
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
