#!/usr/bin/env bash
# 四模式本机运行时渲染（design §2/§7/§8/§12）：配置文件与客户端节点都走 Phase 1 库，
# 端口、TLS、源站守卫与订阅产物由模式派生，不接受用户另设端口。
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-modes.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf '\033[31mnot ok - %s\033[0m\n' "$*" >&2
    exit 1
}
assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}

# 每个模式都在独立 bash 里渲染：Profile 常量是 readonly，不能在同一进程内切换。
render_mode() {
    local profile=$1 out_dir=$2 subscription_mode=${3:-deploy}
    RUNTIME_TMP_OVERRIDE="${out_dir}/runtime"
    mkdir -p "${RUNTIME_TMP_OVERRIDE}"
    (
        export RUNTIME_TMP="${RUNTIME_TMP_OVERRIDE}"
        export EASY_ALL_STATE_DIR_OVERRIDE="${out_dir}/state"
        export EASY_ALL_CERT_DIR_OVERRIDE="${out_dir}/certs"
        export SINGBOX_CONFIG="${out_dir}/config.json"
        export XRAY_CONFIG="${out_dir}/xray.json"
        export CADDY_CONFIG="${out_dir}/Caddyfile"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out_dir}/subscriptions"
        export CAMOUFLAGE_DIR="${out_dir}/camouflage"
        export CLOUDFLARE_UFW_PORT=443
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/${profile}.sh"
        CF_ZONE=example.com
        VPS_PUBLIC_IPV4=203.0.113.10
        SUB_DOWNLOAD_NAME=EASY_ALL
        ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
        SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
        CLOUDFLARE_ZONE_ID=zoneid
        if state_protocol_has_direct_entry "${PROTOCOL}"; then
            DIRECT_DOMAIN=direct.example.com
            DIRECT_NODE_NAME="🇺🇸直连"
        fi
        if state_protocol_has_reality_entry "${PROTOCOL}"; then
            VLESS_UUID=11111111-2222-3333-4444-555555555555
            REALITY_PRIVATE_KEY=$(printf 'A%.0s' {1..32} | base64 | tr '+/' '-_' | tr -d '=\n')
            REALITY_PUBLIC_KEY=$(printf 'B%.0s' {1..32} | base64 | tr '+/' '-_' | tr -d '=\n')
            REALITY_SHORT_ID=0123456789abcdef
        fi
        if state_protocol_has_cdn_entry "${PROTOCOL}"; then
            CF_NODE_DOMAIN=cf.example.com
            CF_NODE_PREFIX="🇺🇸CF"
            VLESS_UUID=11111111-2222-3333-4444-555555555555
            VLESS_PATH=/vless-0123456789ab
        fi
        if state_protocol_uses_cloudfront "${PROTOCOL}"; then
            CF_ORIGIN_DOMAIN=origin.example.com
            SUBSCRIPTION_DOMAIN=cf.example.com
            ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
            CDN_TRAFFIC_PROTECTION_GB=985
            AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
            AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
            AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
        fi
        if [[ "${PROTOCOL}" == "cloudflare" ]]; then
            CLOUDFLARE_ZONE_ID=zoneid
        fi
        if [[ "${PROTOCOL}" == "reality-cloudflare-xhttp" ]]; then
            ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
            CLOUDFLARE_TRANSFORM_RULESET_ID=rs1
            CLOUDFLARE_TRANSFORM_RULE_ID=rule1
        fi
        SUBSCRIPTION_MODE=deploy
        cdn_derive_runtime_fields || exit 1
        mkdir -p "${CERT_DIR}"
        : >"${CERT_DIR}/fullchain.pem"
        : >"${CERT_DIR}/private.key"
        if runtime_uses_xray; then
            render_xray_config "${XRAY_CONFIG}" 0
        else
            render_singbox_config "${SINGBOX_CONFIG}" 0
        fi
        if runtime_caddy_site_enabled; then
            render_caddy_config "${CADDY_CONFIG}" 0 1
        fi
        printf '%s\n' "${PROTOCOL}" >"${out_dir}/protocol"
        if state_protocol_uses_cloudfront "${PROTOCOL}"; then
            build_distribution_config "${out_dir}/distribution.json" "test-caller"
        fi
        build_node_links >"${out_dir}/links.txt"
        build_mihomo_nodes >"${out_dir}/nodes.yaml"
        build_mihomo_proxy_groups >"${out_dir}/groups.yaml"
        build_mihomo_proxy_names >"${out_dir}/names.yaml"
        printf '%s\n' "$(runtime_protocol_label)" >"${out_dir}/label.txt"
        runtime_base64_markers >"${out_dir}/markers-base64.txt"
        runtime_mihomo_markers >"${out_dir}/markers-mihomo.txt"
    ) || fail "${profile} 渲染失败"
}

assert_contains() {
    local name=$1 file=$2 pattern=$3
    grep -Fq -- "${pattern}" "${file}" || fail "${name}: 缺少 ${pattern}"
}

assert_not_contains() {
    local name=$1 file=$2 pattern=$3
    if grep -Fq -- "${pattern}" "${file}"; then
        fail "${name}: 不应包含 ${pattern}"
    fi
}

# --- 模式 2：CloudFront，源站 443 + 回环 10086 --------------------------------
out="${TMP_DIR}/cloudfront"
render_mode cloudfront "${out}"
assert_contains "模式 2 有回环 CDN 入站" "${out}/config.json" '"listen": "127.0.0.1"'
assert_contains "模式 2 CDN 入站端口 10086" "${out}/config.json" '"listen_port": 10086'
assert_contains "模式 2 传输是 ws" "${out}/config.json" '"type": "ws"'
assert_not_contains "模式 2 没有 AnyTLS 入站" "${out}/config.json" 'anytls-in'
assert_contains "模式 2 源站站点监听 443" "${out}/Caddyfile" 'https://origin.example.com:443 {'
assert_contains "模式 2 精确代理路径" "${out}/Caddyfile" 'handle /vless-0123456789ab {'
assert_contains "模式 2 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 2 源站守卫在最前" "${out}/Caddyfile" 'abort @easy_all_bad_origin'
assert_contains "模式 2 节点是 VLESS ws" "${out}/links.txt" 'type=ws'
assert_not_contains "模式 2 节点不泄露源站密钥" "${out}/links.txt" '0123456789abcdef0123456789abcdef'
assert_not_contains "模式 2 无 Reality 参数" "${out}/links.txt" 'security=reality'
assert_contains "模式 2 Mihomo ws 节点" "${out}/nodes.yaml" 'network: ws'
assert_equal "模式 2 回源 HTTPS 端口为 443" "443" \
    "$(jq -r '.Origins.Items[0].CustomOriginConfig.HTTPSPort' "${out}/distribution.json")"
assert_equal "模式 2 回源响应超时对齐官方上限" "120" \
    "$(jq -r '.Origins.Items[0].CustomOriginConfig.OriginReadTimeout' "${out}/distribution.json")"
assert_equal "模式 2 回源保活超时" "120" \
    "$(jq -r '.Origins.Items[0].CustomOriginConfig.OriginKeepaliveTimeout' "${out}/distribution.json")"
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 2 不应生成额外代理组"
assert_equal "模式 2 PROXY 成员只有 CDN 节点" $'        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# --- 模式 1：橙云单域名 443 + Origin CA（纯 Xray XHTTP 后端） -----------------
out="${TMP_DIR}/cloudflare"
render_mode cloudflare "${out}"
assert_contains "模式 1 站点是节点域名 443" "${out}/Caddyfile" 'https://cf.example.com:443 {'
assert_contains "模式 1 有订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
assert_not_contains "模式 1 没有 CloudFront 守卫" "${out}/Caddyfile" 'X-Easy-All-Origin-Key'
assert_contains "模式 1 代理路径是 XHTTP 匹配器" "${out}/Caddyfile" \
    '@easy_all_xhttp path /vless-0123456789ab /vless-0123456789ab/*'
assert_contains "模式 1 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 1 Caddy 反代走 h2c" "${out}/Caddyfile" 'versions h2c 2'
assert_contains "模式 1 Caddy 不缓冲" "${out}/Caddyfile" 'flush_interval -1'
assert_not_contains "模式 1 不写 default_sni" "${out}/Caddyfile" 'default_sni'
assert_contains "模式 1 XHTTP 回环入站" "${out}/xray.json" '"tag": "vless-cdn-in"'
assert_contains "模式 1 XHTTP 传输" "${out}/xray.json" '"network": "xhttp"'
assert_contains "模式 1 XHTTP mode auto" "${out}/xray.json" '"mode": "auto"'
assert_contains "模式 1 padding 在 extra 内" "${out}/xray.json" '"xPaddingBytes": "100-1000"'
assert_not_contains "模式 1 没有 Reality 入站" "${out}/xray.json" 'vless-reality-in'
[[ ! -e "${out}/config.json" ]] || fail "模式 1 不得渲染 sing-box 配置"
assert_contains "模式 1 节点用 XHTTP" "${out}/links.txt" 'type=xhttp&'
assert_contains "模式 1 节点 mode=stream-up" "${out}/links.txt" '&mode=stream-up&'
assert_contains "模式 1 Mihomo 节点 network xhttp" "${out}/nodes.yaml" 'network: xhttp'
assert_not_contains "模式 1 Mihomo 不写 v2ray-http-upgrade" "${out}/nodes.yaml" \
    'v2ray-http-upgrade'
assert_contains "模式 1 协议标签是 XHTTP" "${out}/label.txt" 'VLESS XHTTP over Cloudflare'
assert_equal "模式 1 Base64 标记" $'type=xhttp\nmode=stream-up' "$(<"${out}/markers-base64.txt")"
assert_equal "模式 1 Mihomo 标记" $'network: xhttp\nmode: stream-up' \
    "$(<"${out}/markers-mihomo.txt")"
assert_contains "模式 1 订阅域名由节点域名派生" "${out}/links.txt" 'host=cf.example.com&'
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 1 不应生成额外代理组"
assert_equal "模式 1 PROXY 成员只有 CDN 节点" $'        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# 节点名推荐默认值：必须在交互提示里出现（加载运行时库前由 Profile 赋值），
# 否则会被 singbox-runtime.sh 的 Reality / VLESS-WS 兜底值覆盖。
while IFS='|' read -r profile expected_direct expected_cdn; do
    # 清除父进程可能导出的同名变量：这里断言的是「未提供名称时」的默认值。
    defaults=$(env -u DIRECT_NODE_NAME -u CF_NODE_PREFIX bash -c '
        source "$1/profiles/$2.sh"
        printf "%s|%s\n" "${DIRECT_NODE_NAME}" "${CF_NODE_PREFIX}"
    ' _ "${ROOT_DIR}" "${profile}" 2>&1) || fail "${profile} 默认节点名读取失败"
    assert_equal "${profile} 默认节点名与文档一致" \
        "${expected_direct}|${expected_cdn}" "${defaults}"
    explicit=$(DIRECT_NODE_NAME=CustomDirect CF_NODE_PREFIX=CustomCDN bash -c '
        source "$1/profiles/$2.sh"
        printf "%s|%s\n" "${DIRECT_NODE_NAME}" "${CF_NODE_PREFIX}"
    ' _ "${ROOT_DIR}" "${profile}" 2>&1) || fail "${profile} 显式节点名读取失败"
    assert_equal "${profile} 显式节点名优先" "CustomDirect|CustomCDN" "${explicit}"
done <<'NODE_DEFAULTS'
cloudfront|Reality|🇺🇸AWS
cloudflare|Reality|🇺🇸CF
reality-cloudfront|🇺🇸Reality|🇺🇸AWS
reality-cloudflare|🇺🇸Reality|🇺🇸CF
NODE_DEFAULTS

for mode_out in cloudfront cloudflare; do
    out="${TMP_DIR}/${mode_out}"
    if [[ "${mode_out}" == "cloudflare" ]]; then
        mode1_core="${out}/xray.json"
    else
        mode1_core="${out}/config.json"
    fi
    assert_not_contains "${mode_out} 不占用 10085" "${mode1_core}" '10085'
    assert_not_contains "${mode_out} 不使用 v2ray_api" "${mode1_core}" 'v2ray_api'
done

# --- A7：订阅就绪判定必须进 Caddyfile（模式 1 的 write_runtime_config）----------
# 观测点选生成的 Caddyfile（对外契约），不依赖内部变量 subscription_ok：
#   subscription_ok != 1 → 订阅 handler 直接输出裸 `respond 503` 并提前返回；
#   == 1 → 输出显式 flag/UA 分支与 `rewrite * /mihomo.yaml` 等产物路径。
# 裸 503 只出现在这一处（JSON 分支的 503 带 matcher：`respond @easy_all_sub_json_missing 503`）。
a7_bare_503() { # $1=Caddyfile
    grep -cE '^[[:space:]]+respond 503$' "$1" || true
}
a7_mode1_render() { # $1=CDN_SUBSCRIPTION_CORRUPT $2=cdn_config_ready(yes|no) $3=out_dir
    local corrupt=$1 ready=$2 out_dir=$3
    mkdir -p "${out_dir}/runtime"
    (
        set -Eeuo pipefail
        export RUNTIME_TMP="${out_dir}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${out_dir}/state"
        export EASY_ALL_CERT_DIR_OVERRIDE="${out_dir}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out_dir}/subscriptions"
        export SINGBOX_CONFIG="${out_dir}/config.json"
        export XRAY_CONFIG="${out_dir}/xray.json"
        export CADDY_CONFIG="${out_dir}/Caddyfile"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/cloudflare.sh"
        CF_ZONE=example.com
        VPS_PUBLIC_IPV4=203.0.113.10
        SUB_DOWNLOAD_NAME=EASY_ALL
        ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
        SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
        CLOUDFLARE_ZONE_ID=zoneid
        CF_NODE_DOMAIN=cf.example.com
        CF_NODE_PREFIX=CF
        VLESS_UUID=aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee
        VLESS_PATH=/vless-0123456789ab
        SUBSCRIPTION_MODE=deploy
        CDN_SUBSCRIPTION_CORRUPT="${corrupt}"
        # A7 的判定依赖 cdn_config_ready（订阅产物是否已写盘）：测试内打桩，不改生产代码。
        cdn_config_ready() { [[ "${ready}" == "yes" ]]; }
        cdn_derive_runtime_fields || exit 1
        mkdir -p "${CERT_DIR}"
        # write_runtime_config 会走 write_caddy_config 的候选校验：CI 里 CADDY_BIN 指向真实 caddy，
        # 空的 PEM 会让 `caddy validate` 报 "failed to find any PEM data in certificate input"（
        # 本机无 caddy 时该步被跳过，所以本地不会暴露）。这里生成一对可解析且配对的真证书。
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${CF_NODE_DOMAIN}" \
            -keyout "${CERT_DIR}/private.key" -out "${CERT_DIR}/fullchain.pem" >/dev/null 2>&1 \
            || fail "无法生成 A7 测试证书（需要 openssl）"
        write_runtime_config
    ) || fail "模式 1 渲染失败（corrupt=${corrupt} ready=${ready}）"
}

# 变体 1：配置损坏 → 503 降级，且不再暴露任何订阅产物路径。
a7_corrupt="${TMP_DIR}/a7-corrupt"
a7_mode1_render 1 no "${a7_corrupt}"
assert_equal "A7: 订阅损坏时 Caddyfile 出现裸 503" "1" "$(a7_bare_503 "${a7_corrupt}/Caddyfile")"
assert_equal "A7: 订阅损坏时不暴露 mihomo.yaml 产物" "0" \
    "$(grep -c 'rewrite \* /mihomo.yaml' "${a7_corrupt}/Caddyfile" || true)"

# 变体 2：正常（未损坏 + 产物就绪）→ 无裸 503，产物路径齐全。
a7_ready="${TMP_DIR}/a7-ready"
a7_mode1_render 0 yes "${a7_ready}"
assert_equal "A7: 订阅就绪时不得出现裸 503" "0" "$(a7_bare_503 "${a7_ready}/Caddyfile")"
# flag 与 UA 两个入口各一条 rewrite，与既有「产物 /mihomo.yaml|2」断言一致。
assert_equal "A7: 订阅就绪时暴露 mihomo.yaml 产物" "2" \
    "$(grep -c 'rewrite \* /mihomo.yaml' "${a7_ready}/Caddyfile" || true)"

# 变体 3：安装早期调用点（产物尚未写盘 → cdn_config_ready 为假）只会产生**瞬时** 503，
# 同一次 apply 的后续调用会重算回 1；最终 Caddyfile 必须不含裸 503（否则装完仍 503）。
a7_early="${TMP_DIR}/a7-early"
a7_mode1_render 0 no "${a7_early}"
assert_equal "A7: 安装早期中间态确实是 503（承认该瞬态存在）" "1" \
    "$(a7_bare_503 "${a7_early}/Caddyfile")"
a7_mode1_render 0 yes "${a7_early}"
assert_equal "A7: 后续调用覆盖后最终 Caddyfile 不含裸 503" "0" \
    "$(a7_bare_503 "${a7_early}/Caddyfile")"
assert_equal "A7: 后续调用覆盖后产物路径恢复" "2" \
    "$(grep -c 'rewrite \* /mihomo.yaml' "${a7_early}/Caddyfile" || true)"

# --- 模式 3：Reality 443 + CloudFront 单 443 合一回环 9443（WP1-WP4） ---------
out="${TMP_DIR}/reality-cloudfront"
render_mode reality-cloudfront "${out}"
assert_contains "模式 3 Reality 入站" "${out}/config.json" '"tag": "vless-reality-in"'
assert_contains "模式 3 Reality 监听 0.0.0.0:443" "${out}/config.json" '"listen": "0.0.0.0"'
assert_contains "模式 3 Reality 端口 443" "${out}/config.json" '"listen_port": 443'
assert_contains "模式 3 启用 vision 流控" "${out}/config.json" '"flow": "xtls-rprx-vision"'
assert_contains "模式 3 握手目标回环 9443" "${out}/config.json" '"server_port": 9443'
assert_contains "模式 3 Reality 开启 2m 时间窗" "${out}/config.json" '"max_time_difference": "2m"'
assert_contains "模式 3 双入站保留回环 CDN" "${out}/config.json" '"tag": "vless-cdn-in"'
assert_not_contains "模式 3 没有 AnyTLS 入站" "${out}/config.json" 'anytls-in'
assert_contains "模式 3 单 443 合一回环站 9443" "${out}/Caddyfile" \
    'https://direct.example.com:9443, https://origin.example.com:9443 {'
assert_not_contains "模式 3 全新态不渲染 8443 块" "${out}/Caddyfile" ':8443 {'
assert_not_contains "模式 3 全新态不使用 abort 守卫" "${out}/Caddyfile" 'abort @easy_all_bad_origin'
assert_contains "模式 3 合一源站密钥分流" "${out}/Caddyfile" \
    "@easy_all_valid_origin expression {http.request.header.X-Easy-All-Origin-Key} == '0123456789abcdef0123456789abcdef'"
assert_contains "模式 3 源站反代回环" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 3 订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
camo_block=$(awk '/^https:\/\/.*:9443 \{$/{inside=1;next} inside&&/^\}$/{exit} inside' "${out}/Caddyfile")
[[ -n "${camo_block}" ]] || fail "模式 3 缺少 9443 合一回环块"
grep -Fq 'bind 127.0.0.1' <<<"${camo_block}" || fail "模式 3 合一站点必须只绑回环"
if grep -Fq 'bind 0.0.0.0' <<<"${camo_block}"; then
    fail "模式 3 合一站点不得绑定公网"
fi
grep -Fq 'header -Server' <<<"${camo_block}" || fail "模式 3 合一站点缺少 header -Server"
grep -Fq 'handle @easy_all_camo_page {' <<<"${camo_block}" \
    || fail "模式 3 合一站点缺少伪装静态页路由"
grep -Fq '@easy_all_camo_dotfiles path */.*' <<<"${camo_block}" \
    || fail "模式 3 合一站点缺少隐藏点文件拦截"
if grep -Fq 'redir * /login 302' <<<"${camo_block}"; then
    fail "模式 3 伪装站不得无差别 302 跳 /login"
fi
if grep -Eq '/easy_all-health|easy_all ok' <<<"${camo_block}"; then
    fail "模式 3 合一站点不得暴露 health"
fi
assert_equal "模式 3 CloudFront 回源 HTTPS 端口为 443" "443" \
    "$(jq -r '.Origins.Items[0].CustomOriginConfig.HTTPSPort' "${out}/distribution.json")"
assert_contains "模式 3 节点是 Reality" "${out}/links.txt" 'security=reality'
assert_contains "模式 3 节点含 VLESS ws" "${out}/links.txt" 'type=ws'
assert_not_contains "模式 3 节点不是 AnyTLS" "${out}/links.txt" 'anytls://'
assert_contains "模式 3 Mihomo reality-opts" "${out}/nodes.yaml" 'reality-opts:'
assert_contains "模式 3 Mihomo ws 节点" "${out}/nodes.yaml" 'network: ws'
assert_contains "模式 3 回环入站保持 ws" "${out}/config.json" '"type": "ws"'
assert_not_contains "模式 3 Mihomo 不写 v2ray-http-upgrade" "${out}/nodes.yaml" 'v2ray-http-upgrade'
assert_equal "模式 3 Base64 标记" $'security=reality\ntype=ws' "$(<"${out}/markers-base64.txt")"
assert_not_contains "模式 3 Mihomo 不写 PQ 开关" "${out}/nodes.yaml" 'support-x25519mlkem768'
assert_equal "模式 3 PROXY 成员是 Reality + CDN" \
    $'        - "🇺🇸直连"\n        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# --- 模式 4：Reality 443 + 橙云回源/订阅 8443 + 回环伪装站 9443（WP1-WP3/WP5） ---
out="${TMP_DIR}/reality-cloudflare"
render_mode reality-cloudflare "${out}"
assert_contains "模式 4 Reality 入站" "${out}/config.json" '"tag": "vless-reality-in"'
assert_contains "模式 4 Reality 端口 443" "${out}/config.json" '"listen_port": 443'
assert_contains "模式 4 启用 vision 流控" "${out}/config.json" '"flow": "xtls-rprx-vision"'
assert_contains "模式 4 握手目标回环 9443" "${out}/config.json" '"server_port": 9443'
assert_contains "模式 4 Reality 开启 2m 时间窗" "${out}/config.json" '"max_time_difference": "2m"'
assert_contains "模式 4 保留回环 CDN 入站" "${out}/config.json" '"tag": "vless-cdn-in"'
assert_not_contains "模式 4 没有 AnyTLS 入站" "${out}/config.json" 'anytls-in'
assert_contains "模式 4 伪装站 9443" "${out}/Caddyfile" 'https://direct.example.com:9443 {'
assert_contains "模式 4 橙云回源站点 8443" "${out}/Caddyfile" 'https://cf.example.com:8443 {'
assert_not_contains "模式 4 回源站点无源站头守卫" "${out}/Caddyfile" 'abort @easy_all_bad_origin'
assert_contains "模式 4 回源站点反代回环" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 4 订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
camo_block=$(awk '/^https:\/\/[^[:space:]]+:9443 \{$/{inside=1;next} inside&&/^\}$/{exit} inside' "${out}/Caddyfile")
origin_block=$(awk '/^https:\/\/[^[:space:]]+:8443 \{$/{inside=1;next} inside&&/^\}$/{exit} inside' "${out}/Caddyfile")
[[ -n "${camo_block}" ]] || fail "模式 4 缺少 9443 伪装站块"
[[ -n "${origin_block}" ]] || fail "模式 4 缺少 8443 橙云回源块"
grep -Fq 'bind 127.0.0.1' <<<"${camo_block}" || fail "模式 4 伪装站必须只绑回环"
grep -Fq "tls ${out}/certs/fullchain.pem ${out}/certs/private.key" <<<"${camo_block}" \
    || fail "模式 4 伪装站必须仅用直连主证书"
grep -Fq "tls ${out}/certs/cdn-fullchain.pem ${out}/certs/cdn-private.key" <<<"${origin_block}" \
    || fail "模式 4 8443 回源站必须使用独立 CDN 证书"
grep -Fq 'handle @easy_all_camo_page {' <<<"${camo_block}" \
    || fail "模式 4 伪装站缺少伪装静态页路由"
grep -Fq '@easy_all_camo_dotfiles path */.*' <<<"${camo_block}" \
    || fail "模式 4 伪装站缺少隐藏点文件拦截"
if grep -Fq 'redir * /login 302' <<<"${camo_block}"; then
    fail "模式 4 伪装站不得无差别 302 跳 /login"
fi
if grep -Eq '/easy_all-health|easy_all ok' <<<"${camo_block}"; then
    fail "模式 4 伪装站不得暴露 health"
fi
if grep -Fq '@easy_all_sub' <<<"${camo_block}"; then
    fail "模式 4 伪装站不得暴露订阅入口"
fi
assert_contains "模式 4 节点是 Reality" "${out}/links.txt" 'security=reality'
assert_contains "模式 4 节点含 VLESS httpupgrade" "${out}/links.txt" \
    'type=httpupgrade&alpn=http%2F1.1&'
assert_not_contains "模式 4 节点不是 AnyTLS" "${out}/links.txt" 'anytls://'
assert_contains "模式 4 Mihomo reality-opts" "${out}/nodes.yaml" 'reality-opts:'
assert_contains "模式 4 Mihomo ws 传输" "${out}/nodes.yaml" 'network: ws'
assert_contains "模式 4 Mihomo 开启 v2ray-http-upgrade" "${out}/nodes.yaml" \
    'v2ray-http-upgrade: true'
assert_contains "模式 4 回环入站用 httpupgrade" "${out}/config.json" '"type": "httpupgrade"'
assert_contains "模式 4 协议标签是 HTTPUpgrade" "${out}/label.txt" 'VLESS HTTPUpgrade over Cloudflare'
assert_equal "模式 4 Base64 标记" $'security=reality\ntype=httpupgrade' "$(<"${out}/markers-base64.txt")"
assert_not_contains "模式 4 不带 AnyTLS 节点" "${out}/nodes.yaml" 'type: anytls'
assert_equal "模式 4 PROXY 成员是 Reality + 橙云" \
    $'        - "🇺🇸直连"\n        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# --- 模式 5：Reality + Cloudflare XHTTP（纯 xray 后端，单 443 合一） ----------
out="${TMP_DIR}/reality-cloudflare-xhttp"
render_mode reality-cloudflare-xhttp "${out}"
assert_contains "模式 5 Reality 入站" "${out}/xray.json" '"tag": "vless-reality-in"'
assert_contains "模式 5 Reality 监听 0.0.0.0:443" "${out}/xray.json" '"listen": "0.0.0.0"'
assert_contains "模式 5 Reality 回落回环 9443" "${out}/xray.json" '"target": "127.0.0.1:9443"'
assert_contains "模式 5 vision 流控" "${out}/xray.json" '"flow": "xtls-rprx-vision"'
assert_contains "模式 5 XHTTP 回环入站" "${out}/xray.json" '"tag": "vless-cdn-in"'
assert_contains "模式 5 XHTTP 传输" "${out}/xray.json" '"network": "xhttp"'
assert_contains "模式 5 XHTTP mode auto" "${out}/xray.json" '"mode": "auto"'
assert_contains "模式 5 XHTTP padding 在 extra 内" "${out}/xray.json" '"xPaddingBytes": "100-1000"'
assert_contains "模式 5 XHTTP 保活间隔在 extra 内" "${out}/xray.json" \
    '"scStreamUpServerSecs": "20-80"'
assert_contains "模式 5 DNS 强制 IPv4" "${out}/xray.json" '"queryStrategy": "UseIPv4"'
[[ ! -e "${out}/config.json" ]] || fail "模式 5 不得渲染 sing-box 配置"
assert_not_contains "模式 5 不使用 sing-box 私网标记" "${out}/xray.json" '"ip_is_private"'
assert_contains "模式 5 全局 default_sni" "${out}/Caddyfile" "default_sni direct.example.com"
assert_contains "模式 5 橙云 XHTTP 站 9443" "${out}/Caddyfile" "https://cf.example.com:9443 {"
assert_contains "模式 5 直连伪装站 9443" "${out}/Caddyfile" "https://direct.example.com:9443 {"
assert_contains "模式 5 h2c 反代" "${out}/Caddyfile" "versions h2c 2"
assert_contains "模式 5 不缓冲" "${out}/Caddyfile" "flush_interval -1"
assert_not_contains "模式 5 不渲染 8443" "${out}/Caddyfile" ":8443 {"
assert_not_contains "模式 5 不下发 Subscription-Userinfo" "${out}/Caddyfile" "Subscription-Userinfo"
assert_contains "模式 5 直连节点是 Reality" "${out}/links.txt" 'security=reality'
assert_contains "模式 5 橙云节点是 XHTTP" "${out}/links.txt" 'type=xhttp&'
assert_contains "模式 5 橙云节点 mode=stream-up" "${out}/links.txt" '&mode=stream-up&'
assert_not_contains "模式 5 节点不泄露源站密钥" "${out}/links.txt" \
    '0123456789abcdef0123456789abcdef'
assert_contains "模式 5 Mihomo reality-opts" "${out}/nodes.yaml" 'reality-opts:'
assert_contains "模式 5 Mihomo XHTTP 传输" "${out}/nodes.yaml" 'network: xhttp'
assert_contains "模式 5 Mihomo MLKEM 开关" "${out}/nodes.yaml" 'support-x25519mlkem768: true'
assert_contains "模式 5 协议标签" "${out}/label.txt" 'XHTTP'
assert_equal "模式 5 Base64 标记" $'security=reality\ntype=xhttp\nmode=stream-up' \
    "$(<"${out}/markers-base64.txt")"
assert_equal "模式 5 Mihomo 标记" $'reality-opts:\nnetwork: xhttp\nmode: stream-up' \
    "$(<"${out}/markers-mihomo.txt")"
assert_equal "模式 5 PROXY 成员是 Reality + 橙云" \
    $'        - "🇺🇸直连"\n        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# 六产物订阅：不产出 singbox*.json；优选地址只换连接地址；iOS 变体去嗅探；不泄露源站密钥。
m5_subs="${TMP_DIR}/xhttp-subs"
mkdir -p "${m5_subs}/runtime" "${m5_subs}/out"
(
    export RUNTIME_TMP="${m5_subs}/runtime"
    export EASY_ALL_STATE_DIR_OVERRIDE="${m5_subs}/state"
    export EASY_ALL_CERT_DIR_OVERRIDE="${m5_subs}/certs"
    export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${m5_subs}/published"
    export XRAY_CONFIG="${m5_subs}/xray.json"
    export CADDY_CONFIG="${m5_subs}/Caddyfile"
    export CAMOUFLAGE_DIR="${m5_subs}/camouflage"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/profiles/reality-cloudflare-xhttp.sh"
    CF_ZONE=example.com
    VPS_PUBLIC_IPV4=203.0.113.10
    SUB_DOWNLOAD_NAME=EASY_ALL
    ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
    SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" \
        '{allowedTokens:$t,nodes:[],cdnEdgeAddress:"edge9.cloudflare.182682.xyz"}')
    CLOUDFLARE_ZONE_ID=zoneid
    DIRECT_DOMAIN=direct.example.com
    DIRECT_NODE_NAME="🇺🇸直连"
    VLESS_UUID=11111111-2222-4333-8444-555555555555
    REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
    REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
    REALITY_SHORT_ID=0123456789abcdef
    CF_NODE_DOMAIN=cf.example.com
    CF_NODE_PREFIX="🇺🇸CF"
    VLESS_PATH=/vless-0123456789ab
    ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
    CLOUDFLARE_TRANSFORM_RULESET_ID=rs1
    CLOUDFLARE_TRANSFORM_RULE_ID=rule1
    SUBSCRIPTION_MODE=deploy
    cdn_derive_runtime_fields || exit 1
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" || exit 1
    render_subscription_files "${m5_subs}/out" || exit 1
) || fail "模式 5 订阅渲染失败"
for artifact in base64.txt base64-all.txt mihomo.yaml mihomo-all.yaml \
    mihomo-ios.yaml mihomo-ios-all.yaml; do
    [[ -s "${m5_subs}/out/${artifact}" ]] || fail "模式 5 缺少订阅产物：${artifact}"
done
[[ ! -e "${m5_subs}/out/singbox.json" && ! -e "${m5_subs}/out/singbox-all.json" ]] \
    || fail "模式 5 不得生成 sing-box JSON 订阅"
openssl base64 -d -A <"${m5_subs}/out/base64.txt" >"${m5_subs}/out/base64.decoded" \
    || fail "模式 5 Base64 订阅无法解码"
assert_contains "模式 5 Base64 含 Reality 直连节点" "${m5_subs}/out/base64.decoded" \
    'security=reality'
assert_contains "模式 5 Base64 含 XHTTP 节点" "${m5_subs}/out/base64.decoded" 'type=xhttp&'
assert_contains "模式 5 Base64 使用 cdnEdgeAddress 连接" "${m5_subs}/out/base64.decoded" \
    '@edge9.cloudflare.182682.xyz:443?'
assert_contains "模式 5 Base64 的 SNI 仍是节点域名" "${m5_subs}/out/base64.decoded" \
    '&sni=cf.example.com&'
assert_contains "模式 5 Mihomo 含 XHTTP 节点" "${m5_subs}/out/mihomo.yaml" 'network: xhttp'
assert_contains "模式 5 Mihomo 含 reality-opts" "${m5_subs}/out/mihomo.yaml" 'reality-opts:'
assert_contains "模式 5 Mihomo 使用 cdnEdgeAddress" "${m5_subs}/out/mihomo.yaml" \
    'edge9.cloudflare.182682.xyz'
assert_equal "模式 5 iOS 变体剥离嗅探段" "0" \
    "$(grep -c '^sniffer:' "${m5_subs}/out/mihomo-ios.yaml" || true)"
for artifact in "${m5_subs}"/out/*; do
    if grep -Fq -- '0123456789abcdef0123456789abcdef' "${artifact}"; then
        fail "模式 5 订阅产物泄露源站密钥：${artifact##*/}"
    fi
done

# 模式 1 六产物订阅：纯 Xray 后端不产 singbox*.json；优选地址只换连接地址。
m1_subs="${TMP_DIR}/mode1-subs"
mkdir -p "${m1_subs}/runtime" "${m1_subs}/out"
(
    export RUNTIME_TMP="${m1_subs}/runtime"
    export EASY_ALL_STATE_DIR_OVERRIDE="${m1_subs}/state"
    export EASY_ALL_CERT_DIR_OVERRIDE="${m1_subs}/certs"
    export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${m1_subs}/published"
    export XRAY_CONFIG="${m1_subs}/xray.json"
    export CADDY_CONFIG="${m1_subs}/Caddyfile"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/profiles/cloudflare.sh"
    CF_ZONE=example.com
    VPS_PUBLIC_IPV4=203.0.113.10
    SUB_DOWNLOAD_NAME=EASY_ALL
    ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
    SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" \
        '{allowedTokens:$t,nodes:[],cdnEdgeAddress:"edge9.cloudflare.182682.xyz"}')
    CLOUDFLARE_ZONE_ID=zoneid
    CF_NODE_DOMAIN=cf.example.com
    CF_NODE_PREFIX="🇺🇸CF"
    VLESS_UUID=11111111-2222-4333-8444-555555555555
    VLESS_PATH=/vless-0123456789ab
    SUBSCRIPTION_MODE=deploy
    cdn_derive_runtime_fields || exit 1
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" || exit 1
    render_subscription_files "${m1_subs}/out" || exit 1
) || fail "模式 1 订阅渲染失败"
for artifact in base64.txt base64-all.txt mihomo.yaml mihomo-all.yaml \
    mihomo-ios.yaml mihomo-ios-all.yaml; do
    [[ -s "${m1_subs}/out/${artifact}" ]] || fail "模式 1 缺少订阅产物：${artifact}"
done
[[ ! -e "${m1_subs}/out/singbox.json" && ! -e "${m1_subs}/out/singbox-all.json" ]] \
    || fail "模式 1 不得生成 sing-box JSON 订阅"
openssl base64 -d -A <"${m1_subs}/out/base64.txt" >"${m1_subs}/out/base64.decoded" \
    || fail "模式 1 Base64 订阅无法解码"
assert_contains "模式 1 Base64 含 XHTTP 节点" "${m1_subs}/out/base64.decoded" 'type=xhttp&'
assert_contains "模式 1 Base64 含 stream-up" "${m1_subs}/out/base64.decoded" '&mode=stream-up&'
assert_contains "模式 1 Base64 使用 cdnEdgeAddress 连接" "${m1_subs}/out/base64.decoded" \
    '@edge9.cloudflare.182682.xyz:443?'
assert_contains "模式 1 Base64 的 SNI 仍是节点域名" "${m1_subs}/out/base64.decoded" \
    '&sni=cf.example.com&'
assert_not_contains "模式 1 Base64 不含 Reality" "${m1_subs}/out/base64.decoded" 'security=reality'
assert_contains "模式 1 Mihomo 含 XHTTP 节点" "${m1_subs}/out/mihomo.yaml" 'network: xhttp'
assert_contains "模式 1 Mihomo 使用 cdnEdgeAddress" "${m1_subs}/out/mihomo.yaml" \
    'edge9.cloudflare.182682.xyz'

# --- 全四模式公共反指纹断言（WP1） -------------------------------------------
for mode_out in cloudfront cloudflare reality-cloudfront reality-cloudflare \
    reality-cloudflare-xhttp; do
    out="${TMP_DIR}/${mode_out}"
    assert_contains "${mode_out} Caddy 去除 Server 响应头" "${out}/Caddyfile" 'header -Server'
    assert_not_contains "${mode_out} Caddy 禁止 /easy_all-health" "${out}/Caddyfile" '/easy_all-health'
    assert_not_contains "${mode_out} Caddy 禁止 easy_all ok 横幅" "${out}/Caddyfile" 'easy_all ok'
done

printf 'ok - 全部模式渲染测试通过\n'
