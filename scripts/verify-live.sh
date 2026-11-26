#!/usr/bin/env bash
# 真核心 HTTP/代理链路门禁（design §13）：起真实 sing-box + Caddy，验证模式 2 的
# 源站守卫、订阅矩阵与 Caddy→VLESS WebSocket 代理链路；
# 提供 XRAY_BIN 时再起真实 Xray（CI 必传），验证模式 5 的双证书 SNI 隔离、橙云源站守卫
# 回落与 Caddy h2c → Xray XHTTP（stream-up）代理数据面。
# 模式 3/4 的 Reality 直连与单 443 回落需要额外的 Reality 客户端握手，其服务端与
# 订阅配置由 verify-cores.sh / test_core_e2e.mjs 用真实核心校验覆盖。
# 需要 root（绑定 443/10086）与锁定版本核心；缺核心/端口/进程失败即非零，不跳过。
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
SB=${SINGBOX_BIN:-/etc/easy_all/sing-box/sing-box}
XR=${XRAY_BIN:-}
CADDY=${CADDY_BIN:-/etc/easy_all/caddy/caddy}
[[ "$(id -u)" -eq 0 ]] || { printf 'verify-live 需要 root（端口 443）：请用 sudo 运行\n' >&2; exit 2; }
[[ -x "${SB}" ]] || { printf '缺少 sing-box：%s\n' "${SB}" >&2; exit 1; }
[[ -x "${CADDY}" ]] || { printf '缺少 Caddy：%s\n' "${CADDY}" >&2; exit 1; }
if [[ -n "${XR}" && ! -x "${XR}" ]]; then
    printf 'XRAY_BIN 不可执行：%s\n' "${XR}" >&2
    exit 1
fi

for port in 443 10086 18081 18082 18091 19090; do
    if command -v ss >/dev/null 2>&1 && ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
        printf 'verify-live: 端口 %s 已被占用；请先停止占用进程\n' "${port}" >&2
        exit 1
    fi
done
T=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-live.XXXXXX")
cleanup_fixtures() {
    local pid
    for pid in ${SBPID:-} ${XRAYPID:-} ${CADDYPID:-} ${CPID1:-} ${CPID2:-} ${CPID3:-} ${CPID4:-}; do
        [[ -n "${pid}" ]] && kill "${pid}" >/dev/null 2>&1 || true
    done
    sleep 0.3
    for pid in ${SBPID:-} ${XRAYPID:-} ${CADDYPID:-} ${CPID1:-} ${CPID2:-} ${CPID3:-} ${CPID4:-}; do
        [[ -n "${pid}" ]] && kill -9 "${pid}" >/dev/null 2>&1 || true
    done
    rm -rf -- "${T}"
}
mkdir -p "${T}/certs" "${T}/subs" "${T}/runtime" /run/easy_all-caddy
chmod 0700 /run/easy_all-caddy

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
# shellcheck source=profiles/cloudfront.sh
source "${ROOT_DIR}/profiles/cloudfront.sh"

PROTOCOL=cloudfront
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUB_DOWNLOAD_NAME=EASY_ALL
ALLOWED_TOKENS='{"owner":"tok-live-aaaaaaaa"}'
SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
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
    [[ "$(curl -sk --noproxy '*' --max-time 2 -o /dev/null -w '%{http_code}' \
        --resolve origin.example.com:443:127.0.0.1 -H "${HEADER}" \
        'https://origin.example.com/subscribe?token=invalid' 2>/dev/null || true)" == "403" ]] && break
    sleep 0.25
done

fail() { printf 'verify-live FAIL: %s\n' "$*" >&2; exit 1; }
code() { curl -sk --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' "$@"; }
BASE=(-H "${HEADER}" --resolve origin.example.com:443:127.0.0.1)
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

[[ "$(code "${BASE[@]}" https://origin.example.com/easy_all-health)" == 404 ]] || fail health_removed
[[ "$(code "${BASE[@]}" 'https://origin.example.com/subscribe?token=invalid')" == 403 ]] || fail invalid_token_403
[[ "$(curl -sk --noproxy '*' --max-time 3 -o /dev/null -w '%{http_code}' \
    --resolve origin.example.com:443:127.0.0.1 'https://origin.example.com/subscribe?token=invalid' || true)" == 000 ]] \
    || fail "缺少源站头未被 abort"
invalid_headers=$(curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null "${BASE[@]}" \
    'https://origin.example.com/subscribe?token=invalid' | tr -d '\r')
! grep -qi '^server:' <<<"${invalid_headers}" || fail server_header_present
[[ "$(code "${BASE[@]}" "https://origin.example.com/subscribe?token=${TOKEN}")" == 200 ]] || fail subscribe
[[ "$(code "${BASE[@]}" "https://origin.example.com/sub?token=${TOKEN}")" == 200 ]] || fail sub_alias
[[ "$(code "${BASE[@]}" "https://origin.example.com/subscribe?token=bad")" == 403 ]] || fail deny
[[ "$(code "${BASE[@]}" -X POST "https://origin.example.com/subscribe?token=${TOKEN}")" == 405 ]] || fail method
[[ "$(code "${BASE[@]}" "https://origin.example.com/subscribe/extra?token=${TOKEN}")" == 404 ]] || fail path_suffix
[[ "$(code "${BASE[@]}" "https://origin.example.com/mihomo.yaml")" == 404 ]] || fail bare_file
[[ "$(code "${BASE[@]}" "https://origin.example.com/singbox.json")" == 404 ]] || fail bare_json_file

# 格式协商：显式 flag > 已确认 sing-box UA > Clash UA > Base64。
sub_url="https://origin.example.com/subscribe?token=${TOKEN}"
body() { curl -sk --noproxy '*' --max-time 10 "${BASE[@]}" "$@"; }
json_headers=$(curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null "${BASE[@]}" \
    "${sub_url}&flag=singbox" | tr -d '\r')
grep -qi '^content-type: application/json' <<<"${json_headers}" || fail json_content_type
grep -qi 'filename=EASY_ALL.json' <<<"${json_headers}" || fail json_filename
grep -qi 'vary: user-agent' <<<"${json_headers}" || fail json_vary
grep -qi '^subscription-userinfo:[[:space:]]*$' <<<"${json_headers}" || fail userinfo_missing_empty
printf 'upload=0; download=123456789; total=985000000000; expire=1798761600' >"${T}/subscription-userinfo"
userinfo_headers=$(curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null "${BASE[@]}" "${sub_url}" | tr -d '\r')
grep -qiFx 'subscription-userinfo: upload=0; download=123456789; total=985000000000; expire=1798761600' \
    <<<"${userinfo_headers}" || fail userinfo_present
rm -f -- "${T}/subscription-userinfo"
json_body=$(body "${sub_url}&flag=singbox")
jq -e '.outbounds | map(.tag) | index("PROXY") != null' <<<"${json_body}" >/dev/null \
    || fail json_proxy_selector
jq -e '.outbounds | map(select(.type == "vless")) | length > 0' \
    <<<"${json_body}" >/dev/null || fail json_nodes
for client in SFA SFI SFM SFT SFW SFL; do
    ua="${client} (sing-box 1.14.4; language zh_CN)"
    [[ "$(body -A "${ua}" "${sub_url}")" == "${json_body}" ]] || fail "${client}_ua_autodetect"
    [[ "$(body -A "${ua}" "${sub_url}&flag=clash")" == "mihomo.yaml" ]] || fail "${client}_ua_flag_clash_override"
    [[ "$(body -A "${ua}" "${sub_url}&flag=base64")" == "base64.txt" ]] || fail "${client}_ua_flag_base64_override"
done
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
    "https://origin.example.com/subscribe?token=bad" | tr -d '\r' \
    | grep -qi 'cache-control: no-store' || fail denied_headers

cat >"${T}/client-ws.json" <<JSON
{"log":{"level":"warn"},"inbounds":[{"type":"mixed","listen":"127.0.0.1","listen_port":18081}],
"outbounds":[{"type":"vless","server":"127.0.0.1","server_port":443,"uuid":"${VLESS_UUID}","tls":{"enabled":true,"server_name":"origin.example.com","insecure":true},"transport":{"type":"ws","path":"${VLESS_PATH}","headers":{"Host":"origin.example.com","X-Easy-All-Origin-Key":"${ORIGIN_HEADER_SECRET}"}}}]}
JSON
"${SB}" run -c "${T}/client-ws.json" >"${T}/client-ws.log" 2>&1 & CPID2=$!
sleep 2
kill -0 "${CPID2}" 2>/dev/null || { tail -5 "${T}/client-ws.log" >&2; fail "WebSocket 客户端进程未存活"; }
proxy_status() {
    # 探测端点只验「请求真的穿过了代理并由目标站应答」：必须无未认证限流（api.github.com 对匿名
    # 请求会 403/429，CI 共享出口很容易被限流误判成代理不通），且响应体极小。
    # Cloudflare 的 /cdn-cgi/trace 是纯文本诊断端点，正常恒为 200。
    env -u NO_PROXY -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
        -u http_proxy -u https_proxy -u all_proxy \
        curl -sS --max-time 10 -x "http://127.0.0.1:$1" -o /dev/null -w '%{http_code}' \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null
}
for port in 18081; do
    status=""
    for _ in $(seq 1 10); do
        status=$(proxy_status "${port}" || true)
        [[ "${status}" == "200" ]] && break
        sleep 1
    done
    [[ "${status}" == "200" ]] || { tail -5 "${T}/client-ws.log" >&2; fail "proxy ${port} 返回 ${status:-无}"; }
done

# --- 模式 5：Reality + Cloudflare XHTTP（单 443 合一，纯 xray + Caddy） ----------
# 需要真实 Xray（CI 必传 XRAY_BIN）；本机自备 Xray 时同样运行，不提供时显式跳过。
if [[ -z "${XR}" ]]; then
    printf 'skip - 模式 5 live 冒烟（未提供 XRAY_BIN；CI 必须提供）\n'
else
    # 模式 2 的 sing-box/Caddy 占用 443 与 10086：先停掉再起模式 5。
    kill "${SBPID}" "${CADDYPID}" >/dev/null 2>&1 || true
    wait "${SBPID}" "${CADDYPID}" 2>/dev/null || true
    for _ in $(seq 1 40); do
        if command -v ss >/dev/null 2>&1 \
            && ! ss -H -ltn "sport = :443" 2>/dev/null | grep -q .; then
            break
        fi
        sleep 0.25
    done

    M5="${T}/m5"
    mkdir -p "${M5}/certs" "${M5}/subs" "${M5}/camo" "${M5}/runtime"
    M5_DIRECT=direct5.example.com
    M5_CDN=cf5.example.com
    M5_PATH=/vless-m5abcdef1234
    M5_UUID=11111111-2222-4333-8444-555555555555
    M5_SECRET=m5-origin-secret-0123456789abcdef
    M5_TOKEN=tok-live-m5-aaaaaaaa
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${M5_DIRECT}" \
        -addext "subjectAltName=DNS:${M5_DIRECT}" \
        -keyout "${M5}/certs/private.key" -out "${M5}/certs/fullchain.pem" >/dev/null 2>&1
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${M5_CDN}" \
        -addext "subjectAltName=DNS:${M5_CDN}" \
        -keyout "${M5}/certs/cdn-private.key" -out "${M5}/certs/cdn-fullchain.pem" >/dev/null 2>&1
    chmod 0600 "${M5}/certs/private.key" "${M5}/certs/cdn-private.key"
    printf 'camouflage-index\n' >"${M5}/camo/index.html"
    for f in base64.txt base64-all.txt mihomo.yaml mihomo-all.yaml mihomo-ios.yaml mihomo-ios-all.yaml; do
        printf '%s\n' "${f}" >"${M5}/subs/${f}"
    done

    # 正式渲染器生成服务端与 Caddy 配置（独立进程：Profile 常量是 readonly）。
    RUNTIME_TMP="${M5}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${M5}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${M5}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${M5}/subs" \
    CAMOUFLAGE_DIR="${M5}/camo" \
    XRAY_CONFIG="${M5}/xray.json" \
    CADDY_CONFIG="${M5}/Caddyfile" \
    XRAY_BIN="${XR}" CADDY_BIN="${CADDY}" \
        bash -c '
set -Eeuo pipefail
export RUNTIME_TMP EASY_ALL_STATE_DIR_OVERRIDE EASY_ALL_CERT_DIR_OVERRIDE \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE CAMOUFLAGE_DIR XRAY_CONFIG CADDY_CONFIG
source "$1/profiles/reality-cloudflare-xhttp.sh"
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUB_DOWNLOAD_NAME=EASY_ALL
ALLOWED_TOKENS="{\"owner\":\"$2\"}"
SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" "{allowedTokens:\$t,nodes:[]}")
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
DIRECT_DOMAIN=$3
DIRECT_NODE_NAME=direct
VLESS_UUID=$4
REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
REALITY_SHORT_ID=0123456789abcdef
CF_NODE_DOMAIN=$5
CF_NODE_PREFIX=CF
VLESS_PATH=$6
ORIGIN_HEADER_SECRET=$7
CLOUDFLARE_TRANSFORM_RULESET_ID=rs-easy-all-live
CLOUDFLARE_TRANSFORM_RULE_ID=rule-easy-all-live
cdn_derive_runtime_fields
render_xray_config "${XRAY_CONFIG}" 0
validate_xray_config "${XRAY_CONFIG}"
render_caddy_config "${CADDY_CONFIG}" 0 1
validate_caddy_config "${CADDY_CONFIG}"
' _ "${ROOT_DIR}" "${M5_TOKEN}" "${M5_DIRECT}" "${M5_UUID}" "${M5_CDN}" "${M5_PATH}" "${M5_SECRET}" \
        || fail "模式 5 配置渲染或核心校验失败"

    "${XR}" run -config "${M5}/xray.json" >"${M5}/xray.log" 2>&1 & XRAYPID=$!
    "${CADDY}" run --config "${M5}/Caddyfile" --adapter caddyfile >"${M5}/caddy.log" 2>&1 & CADDYPID=$!
    M5_HEADER="X-Easy-All-Origin-Key: ${M5_SECRET}"
    ready=0
    for _ in $(seq 1 40); do
        if [[ "$(curl -sk --noproxy '*' --max-time 2 -o /dev/null -w '%{http_code}' \
            --resolve "${M5_CDN}:9443:127.0.0.1" -H "${M5_HEADER}" \
            "https://${M5_CDN}:9443/subscribe?token=invalid" 2>/dev/null || true)" == "403" ]]; then
            ready=1
            break
        fi
        sleep 0.25
    done
    if [[ "${ready}" != "1" ]]; then
        tail -5 "${M5}/xray.log" >&2 || true
        tail -5 "${M5}/caddy.log" >&2 || true
        fail "模式 5 的 Xray 或 Caddy 未就绪"
    fi

    # ① 双证书 SNI 隔离：空 SNI 拿直连主证书，未知 SNI 拿不到任何证书，cf 主机拿到橙云证书，
    #    任何情况下都不得把 CDN_CERT_FILE 的 SAN 暴露给非 cf 主机名。
    m5_san() {
        timeout 10 openssl s_client -connect 127.0.0.1:9443 "$@" </dev/null 2>/dev/null \
            | openssl x509 -noout -ext subjectAltName 2>/dev/null || true
    }
    empty_san=$(m5_san)
    grep -Fq "DNS:${M5_DIRECT}" <<<"${empty_san}" || fail "空 SNI 未返回直连主证书"
    ! grep -Fq "DNS:${M5_CDN}" <<<"${empty_san}" || fail "空 SNI 泄露了橙云证书 SAN"
    unknown_san=$(m5_san -servername unknown.example.com)
    ! grep -Fq "DNS:${M5_CDN}" <<<"${unknown_san}" || fail "未知 SNI 泄露了橙云证书 SAN"
    ! grep -Fq "DNS:${M5_DIRECT}" <<<"${unknown_san}" || fail "未知 SNI 不应拿到直连主证书"
    cdn_san=$(m5_san -servername "${M5_CDN}")
    grep -Fq "DNS:${M5_CDN}" <<<"${cdn_san}" || fail "cf 主机名未拿到橙云证书"
    ! grep -Fq "DNS:${M5_DIRECT}" <<<"${cdn_san}" || fail "橙云证书泄露了直连证书 SAN"

    # ② 缺头/错头的公网 443（经 Xray Reality 回落）只能看到伪装站：无 403、无 Server 头。
    m5_code() { curl -sk --noproxy '*' --max-time 10 -o /dev/null -w '%{http_code}' "$@"; }
    for probe_path in "${M5_PATH}" "${M5_PATH}/probe" /subscribe; do
        [[ "$(m5_code --resolve "${M5_CDN}:443:127.0.0.1" "https://${M5_CDN}${probe_path}")" == "404" ]] \
            || fail "模式 5 缺头探测未落伪装站：${probe_path}"
    done
    [[ "$(m5_code --resolve "${M5_CDN}:443:127.0.0.1" \
        -H 'X-Easy-All-Origin-Key: wrong-secret-0123456789' "https://${M5_CDN}${M5_PATH}")" == "404" ]] \
        || fail "模式 5 错头探测未落伪装站"
    guard_headers=$(curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null \
        --resolve "${M5_CDN}:443:127.0.0.1" "https://${M5_CDN}${M5_PATH}" | tr -d '\r')
    ! grep -qi '^server:' <<<"${guard_headers}" || fail "模式 5 回落响应出现 Server 头"
    ! grep -qi '^subscription-userinfo:' <<<"${guard_headers}" \
        || fail "模式 5 不得下发 Subscription-Userinfo"

    # ③ 带正确源站头的回环 9443：订阅矩阵可用，flag=singbox 恒 503。
    m5_sub() { curl -sk --noproxy '*' --max-time 10 "${M5_BASE[@]}" "$@"; }
    M5_BASE=(--resolve "${M5_CDN}:9443:127.0.0.1" -H "${M5_HEADER}")
    [[ "$(m5_sub "https://${M5_CDN}:9443/subscribe?token=${M5_TOKEN}")" == "base64.txt" ]] \
        || fail "模式 5 Base64 订阅未下发"
    [[ "$(m5_sub "https://${M5_CDN}:9443/subscribe?flag=clash&token=${M5_TOKEN}")" == "mihomo.yaml" ]] \
        || fail "模式 5 Mihomo 订阅未下发"
    [[ "$(m5_sub "https://${M5_CDN}:9443/subscribe?flag=base64&token=${M5_TOKEN}")" == "base64.txt" ]] \
        || fail "模式 5 显式 flag=base64 未生效"
    [[ "$(m5_code "${M5_BASE[@]}" "https://${M5_CDN}:9443/subscribe?token=invalid")" == "403" ]] \
        || fail "模式 5 非法 Token 未返回 403"
    singbox_headers=$(curl -sk --noproxy '*' --max-time 10 -D - -o /dev/null "${M5_BASE[@]}" \
        "https://${M5_CDN}:9443/subscribe?flag=singbox&token=${M5_TOKEN}" | tr -d '\r')
    [[ "$(awk 'NR==1 {print $2}' <<<"${singbox_headers}")" == "503" ]] \
        || fail "模式 5 的 flag=singbox 必须返回 503"
    ! grep -qi '^subscription-userinfo:' <<<"${singbox_headers}" \
        || fail "模式 5 的 sing-box 分支不得下发 Subscription-Userinfo"

    # ④ 双 Xray 实例：Caddy h2c → Xray XHTTP（stream-up）代理数据面。
    # 客户端在 extra.headers 里模拟 Cloudflare 边缘注入的源站头（真实边缘由 Transform Rule 注入）。
    jq -n --arg uuid "${M5_UUID}" --arg host "${M5_CDN}" --arg path "${M5_PATH}" \
        --arg secret "${M5_SECRET}" '
        {
          log: {loglevel: "warning"},
          inbounds: [{tag: "socks-in", protocol: "socks", listen: "127.0.0.1", port: 18091,
                      settings: {udp: false}}],
          outbounds: [{
            protocol: "vless",
            settings: {vnext: [{address: "127.0.0.1", port: 9443,
                                users: [{id: $uuid, encryption: "none"}]}]},
            streamSettings: {
              network: "xhttp",
              security: "tls",
              tlsSettings: {serverName: $host, allowInsecure: true, alpn: ["h2"]},
              xhttpSettings: {
                path: $path, host: $host, mode: "stream-up",
                extra: {headers: {"X-Easy-All-Origin-Key": $secret},
                        noGRPCHeader: false, uplinkHTTPMethod: "POST"}
              }
            }
          }]
        }' >"${M5}/client.json"
    "${XR}" run -config "${M5}/client.json" >"${M5}/client.log" 2>&1 & CPID4=$!
    m5_proxy_status=""
    for _ in $(seq 1 20); do
        m5_proxy_status=$(env -u NO_PROXY -u no_proxy -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
            -u http_proxy -u https_proxy -u all_proxy \
            curl -sS --max-time 10 -x "socks5h://127.0.0.1:18091" \
            -o /dev/null -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null || true)
        [[ "${m5_proxy_status}" == "200" ]] && break
        sleep 1
    done
    if [[ "${m5_proxy_status}" != "200" ]]; then
        tail -5 "${M5}/client.log" >&2 || true
        tail -5 "${M5}/xray.log" >&2 || true
        tail -5 "${M5}/caddy.log" >&2 || true
        fail "模式 5 XHTTP 代理链路返回 ${m5_proxy_status:-无}"
    fi
    printf 'ok - 模式 5 真核心 live 冒烟（双证书 SNI 隔离 / 源站守卫回落 / 订阅矩阵 / Caddy h2c → Xray XHTTP）\n'
fi

printf 'ok - 真核心 HTTP/代理链路（Caddy→VLESS WebSocket / 模式 5 Xray XHTTP）\n'
