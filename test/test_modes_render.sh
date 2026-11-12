#!/usr/bin/env bash
# 五模式本机运行时渲染（design §2/§7/§8/§12）：配置文件与客户端节点都走 Phase 1 库，
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
    local profile=$1 out_dir=$2
    RUNTIME_TMP_OVERRIDE="${out_dir}/runtime"
    mkdir -p "${RUNTIME_TMP_OVERRIDE}"
    (
        export RUNTIME_TMP="${RUNTIME_TMP_OVERRIDE}"
        export EASY_ALL_STATE_DIR_OVERRIDE="${out_dir}/state"
        export EASY_ALL_CERT_DIR_OVERRIDE="${out_dir}/certs"
        export SINGBOX_CONFIG="${out_dir}/config.json"
        export CADDY_CONFIG="${out_dir}/Caddyfile"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out_dir}/subscriptions"
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
            ANYTLS_PASSWORD=0123456789abcdefaaaabbbb
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
        if [[ "${PROTOCOL}" == "cloudflare" ]] || [[ "${PROTOCOL}" == "anytls" ]]; then
            CLOUDFLARE_ZONE_ID=zoneid
        fi
        if [[ "${PROTOCOL}" == "anytls" ]]; then
            SUBSCRIPTION_DOMAIN=sub.example.com
            SUBSCRIPTION_MODE=deploy
            CLOUDFLARE_ORIGIN_RULESET_ID=rs
            CLOUDFLARE_ORIGIN_RULE_ID=rule
        elif [[ "${PROTOCOL}" == "combined-cloudflare" ]]; then
            SUBSCRIPTION_MODE=deploy
            CLOUDFLARE_ORIGIN_RULESET_ID=rs
            CLOUDFLARE_ORIGIN_RULE_ID=rule
        else
            SUBSCRIPTION_MODE=deploy
        fi
        cdn_derive_runtime_fields || exit 1
        mkdir -p "${CERT_DIR}"
        : >"${CERT_DIR}/fullchain.pem"
        : >"${CERT_DIR}/private.key"
        render_singbox_config "${SINGBOX_CONFIG}" 0
        if runtime_caddy_site_enabled; then
            render_caddy_config "${CADDY_CONFIG}" 0 1
        fi
        printf '%s\n' "${PROTOCOL}" >"${out_dir}/protocol"
        build_node_links >"${out_dir}/links.txt"
        build_mihomo_nodes >"${out_dir}/nodes.yaml"
        build_mihomo_proxy_groups >"${out_dir}/groups.yaml"
        build_mihomo_proxy_names >"${out_dir}/names.yaml"
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

# --- 模式 1：AnyTLS 443 + 订阅站点 8443 --------------------------------------
out="${TMP_DIR}/anytls"
render_mode anytls "${out}"
assert_contains "模式 1 sing-box 有 AnyTLS 入站" "${out}/config.json" '"type": "anytls"'
assert_contains "模式 1 AnyTLS 监听 443" "${out}/config.json" '"listen_port": 443'
assert_not_contains "模式 1 没有 CDN 入站" "${out}/config.json" 'vless-cdn-in'
assert_contains "模式 1 Caddy 站点监听 8443" "${out}/Caddyfile" 'https://sub.example.com:8443 {'
assert_contains "模式 1 Caddy 持有订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
assert_not_contains "模式 1 没有源站守卫" "${out}/Caddyfile" 'X-Easy-All-Origin-Key'
assert_not_contains "模式 1 没有回环代理" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 1 节点是 AnyTLS 443" "${out}/links.txt" 'anytls://'
assert_contains "模式 1 Mihomo 节点" "${out}/nodes.yaml" 'type: anytls'
assert_contains "AnyTLS 节点端口 443" "${out}/nodes.yaml" 'port: 443'
assert_contains "AnyTLS 关闭证书跳过" "${out}/nodes.yaml" 'skip-cert-verify: false'
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 1 不应生成额外代理组"
assert_equal "模式 1 PROXY 成员只有直连节点" $'        - "🇺🇸直连"' "$(<"${out}/names.yaml")"

# --- 模式 4：CloudFront，源站 443 + 回环 10086 --------------------------------
out="${TMP_DIR}/cloudfront"
render_mode cloudfront "${out}"
assert_contains "模式 4 有回环 CDN 入站" "${out}/config.json" '"listen": "127.0.0.1"'
assert_contains "模式 4 CDN 入站端口 10086" "${out}/config.json" '"listen_port": 10086'
assert_contains "模式 4 传输是 ws" "${out}/config.json" '"type": "ws"'
assert_not_contains "模式 4 没有 AnyTLS 入站" "${out}/config.json" 'anytls-in'
assert_contains "模式 4 源站站点监听 443" "${out}/Caddyfile" 'https://origin.example.com:443 {'
assert_contains "模式 4 精确代理路径" "${out}/Caddyfile" 'handle /vless-0123456789ab {'
assert_contains "模式 4 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 4 源站守卫在最前" "${out}/Caddyfile" 'abort @easy_all_bad_origin'
assert_contains "模式 4 节点是 VLESS ws" "${out}/links.txt" 'type=ws'
assert_not_contains "模式 4 节点不泄露源站密钥" "${out}/links.txt" '0123456789abcdef0123456789abcdef'
assert_not_contains "模式 4 无 Reality 参数" "${out}/links.txt" 'security=reality'
assert_contains "模式 4 Mihomo ws 节点" "${out}/nodes.yaml" 'network: ws'
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 4 不应生成额外代理组"
assert_equal "模式 4 PROXY 成员只有 CDN 节点" $'        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# --- 模式 2：橙云单域名 443 + Origin CA ---------------------------------------
out="${TMP_DIR}/cloudflare"
render_mode cloudflare "${out}"
assert_contains "模式 2 站点是节点域名 443" "${out}/Caddyfile" 'https://cf.example.com:443 {'
assert_contains "模式 2 有订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
assert_not_contains "模式 2 没有 CloudFront 守卫" "${out}/Caddyfile" 'X-Easy-All-Origin-Key'
assert_contains "模式 2 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 2 订阅域名由节点域名派生" "${out}/links.txt" 'host=cf.example.com&'
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 2 不应生成额外代理组"
assert_equal "模式 2 PROXY 成员只有 CDN 节点" $'        - "🇺🇸CF"' "$(<"${out}/names.yaml")"

# --- 模式 5：AnyTLS 443 + 源站 8443（无自动组，PROXY 手动选择）--------------
out="${TMP_DIR}/combined"
render_mode combined "${out}"
assert_contains "模式 5 同时有 AnyTLS 与 VLESS" "${out}/config.json" '"type": "anytls"'
assert_contains "模式 5 CDN 入站在回环" "${out}/config.json" '"listen_port": 10086'
assert_contains "模式 5 源站站点监听 8443" "${out}/Caddyfile" 'https://origin.example.com:8443 {'
assert_contains "模式 5 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 5 节点含直连" "${out}/links.txt" 'anytls://'
assert_contains "模式 5 节点含 CDN" "${out}/links.txt" 'type=ws'
assert_not_contains "模式 5 无 AUTO 组" "${out}/groups.yaml" 'AUTO'
assert_not_contains "模式 5 无 CDN-FALLBACK 组" "${out}/groups.yaml" 'CDN-FALLBACK'
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 5 不应生成额外代理组"
assert_equal "模式 5 PROXY 成员顺序" \
    $'        - "🇺🇸直连"\n        - "🇺🇸CF"' "$(<"${out}/names.yaml")"
assert_not_contains "模式 5 PROXY 不含 AUTO" "${out}/names.yaml" "AUTO"
assert_not_contains "模式 5 PROXY 不含 CDN-FALLBACK" "${out}/names.yaml" "CDN-FALLBACK"
assert_not_contains "模式 5 不使用 httpupgrade" "${out}/config.json" 'httpupgrade'

# 节点名推荐默认值：必须在交互提示里出现（加载运行时库前由 Profile 赋值），
# 否则会被 singbox-runtime.sh 的 AnyTLS / VLESS-WS 兜底值覆盖。
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
anytls|🇺🇸直连|VLESS-WS
cloudfront|AnyTLS|🇺🇸AWS
cloudflare|AnyTLS|🇺🇸CF
combined|主节点|CDN备用
combined-cloudflare|主节点|CDN备用
NODE_DEFAULTS

# --- 模式 3：AnyTLS 443 + 橙云节点/订阅 8443（Origin Rule）------------------

out="${TMP_DIR}/combined-cloudflare"
render_mode combined-cloudflare "${out}"
assert_contains "模式 3 有 AnyTLS 入站" "${out}/config.json" '"type": "anytls"'
assert_contains "模式 3 AnyTLS 监听 443" "${out}/config.json" '"listen_port": 443'
assert_contains "模式 3 CDN 入站在回环" "${out}/config.json" '"listen_port": 10086'
assert_contains "模式 3 站点是节点域名 8443" "${out}/Caddyfile" 'https://cf.example.com:8443 {'
assert_contains "模式 3 有订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
assert_contains "模式 3 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_not_contains "模式 3 没有 Caddy 源站守卫" "${out}/Caddyfile" 'X-Easy-All-Origin-Key'
assert_contains "模式 3 节点含直连" "${out}/links.txt" 'anytls://'
assert_contains "模式 3 节点含橙云 CDN" "${out}/links.txt" 'type=ws'
assert_contains "模式 3 Mihomo 含 AnyTLS" "${out}/nodes.yaml" 'type: anytls'
assert_contains "模式 3 Mihomo 含 ws" "${out}/nodes.yaml" 'network: ws'
assert_not_contains "模式 3 无 Reality 参数" "${out}/links.txt" 'security=reality'
assert_equal "模式 3 PROXY 成员顺序" \
    $'        - "🇺🇸直连"\n        - "🇺🇸CF"' "$(<"${out}/names.yaml")"
assert_not_contains "模式 3 PROXY 不含 AUTO" "${out}/names.yaml" "AUTO"
assert_not_contains "模式 3 PROXY 不含 CDN-FALLBACK" "${out}/names.yaml" "CDN-FALLBACK"
[[ ! -s "${out}/groups.yaml" ]] || fail "模式 3 不应生成额外代理组"

for mode_out in anytls cloudfront cloudflare combined combined-cloudflare; do
    out="${TMP_DIR}/${mode_out}"
    assert_not_contains "${mode_out} 不占用 10085" "${out}/config.json" '10085'
    assert_not_contains "${mode_out} 不使用 v2ray_api" "${out}/config.json" 'v2ray_api'
done

# --- A7：订阅就绪判定必须进 Caddyfile（模式 2 的 write_runtime_config）----------
# 观测点选生成的 Caddyfile（对外契约），不依赖内部变量 subscription_ok：
#   subscription_ok != 1 → 订阅 handler 直接输出裸 `respond 503` 并提前返回；
#   == 1 → 输出显式 flag/UA 分支与 `rewrite * /mihomo.yaml` 等产物路径。
# 裸 503 只出现在这一处（JSON 分支的 503 带 matcher：`respond @easy_all_sub_json_missing 503`）。
a7_bare_503() { # $1=Caddyfile
    grep -cE '^[[:space:]]+respond 503$' "$1" || true
}
a7_mode2_render() { # $1=CDN_SUBSCRIPTION_CORRUPT $2=cdn_config_ready(yes|no) $3=out_dir
    local corrupt=$1 ready=$2 out_dir=$3
    mkdir -p "${out_dir}/runtime"
    (
        set -Eeuo pipefail
        export RUNTIME_TMP="${out_dir}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${out_dir}/state"
        export EASY_ALL_CERT_DIR_OVERRIDE="${out_dir}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out_dir}/subscriptions"
        export SINGBOX_CONFIG="${out_dir}/config.json"
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
        : >"${CERT_DIR}/fullchain.pem"
        : >"${CERT_DIR}/private.key"
        write_runtime_config
    ) || fail "模式 2 渲染失败（corrupt=${corrupt} ready=${ready}）"
}

# 变体 1：配置损坏 → 503 降级，且不再暴露任何订阅产物路径。
a7_corrupt="${TMP_DIR}/a7-corrupt"
a7_mode2_render 1 no "${a7_corrupt}"
assert_equal "A7: 订阅损坏时 Caddyfile 出现裸 503" "1" "$(a7_bare_503 "${a7_corrupt}/Caddyfile")"
assert_equal "A7: 订阅损坏时不暴露 mihomo.yaml 产物" "0" \
    "$(grep -c 'rewrite \* /mihomo.yaml' "${a7_corrupt}/Caddyfile" || true)"

# 变体 2：正常（未损坏 + 产物就绪）→ 无裸 503，产物路径齐全。
a7_ready="${TMP_DIR}/a7-ready"
a7_mode2_render 0 yes "${a7_ready}"
assert_equal "A7: 订阅就绪时不得出现裸 503" "0" "$(a7_bare_503 "${a7_ready}/Caddyfile")"
# flag 与 UA 两个入口各一条 rewrite，与既有「产物 /mihomo.yaml|2」断言一致。
assert_equal "A7: 订阅就绪时暴露 mihomo.yaml 产物" "2" \
    "$(grep -c 'rewrite \* /mihomo.yaml' "${a7_ready}/Caddyfile" || true)"

# 变体 3：安装早期调用点（产物尚未写盘 → cdn_config_ready 为假）只会产生**瞬时** 503，
# 同一次 apply 的后续调用会重算回 1；最终 Caddyfile 必须不含裸 503（否则装完仍 503）。
a7_early="${TMP_DIR}/a7-early"
a7_mode2_render 0 no "${a7_early}"
assert_equal "A7: 安装早期中间态确实是 503（承认该瞬态存在）" "1" \
    "$(a7_bare_503 "${a7_early}/Caddyfile")"
a7_mode2_render 0 yes "${a7_early}"
assert_equal "A7: 后续调用覆盖后最终 Caddyfile 不含裸 503" "0" \
    "$(a7_bare_503 "${a7_early}/Caddyfile")"
assert_equal "A7: 后续调用覆盖后产物路径恢复" "2" \
    "$(grep -c 'rewrite \* /mihomo.yaml' "${a7_early}/Caddyfile" || true)"

printf 'ok - 五模式渲染测试通过\n'
