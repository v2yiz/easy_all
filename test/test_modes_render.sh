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

# --- 模式 3：橙云单域名 443 + Origin CA ---------------------------------------
out="${TMP_DIR}/cloudflare"
render_mode cloudflare "${out}"
assert_contains "模式 3 站点是节点域名 443" "${out}/Caddyfile" 'https://cf.example.com:443 {'
assert_contains "模式 3 有订阅入口" "${out}/Caddyfile" '@easy_all_sub path /subscribe /sub'
assert_not_contains "模式 3 没有 CloudFront 守卫" "${out}/Caddyfile" 'X-Easy-All-Origin-Key'
assert_contains "模式 3 回环转发" "${out}/Caddyfile" 'reverse_proxy 127.0.0.1:10086'
assert_contains "模式 3 订阅域名由节点域名派生" "${out}/links.txt" 'type=ws'

# --- 模式 4：AnyTLS 443 + 源站 8443 + 自动组 ---------------------------------
out="${TMP_DIR}/combined"
render_mode combined "${out}"
assert_contains "模式 4 同时有 AnyTLS 与 VLESS" "${out}/config.json" '"type": "anytls"'
assert_contains "模式 4 CDN 入站在回环" "${out}/config.json" '"listen_port": 10086'
assert_contains "模式 4 源站站点监听 8443" "${out}/Caddyfile" 'https://origin.example.com:8443 {'
assert_contains "模式 4 节点含直连" "${out}/links.txt" 'anytls://'
assert_contains "模式 4 节点含 CDN" "${out}/links.txt" 'type=ws'
assert_contains "模式 4 有 AUTO 组" "${out}/groups.yaml" 'name: AUTO'
assert_contains "模式 4 有 CDN-FALLBACK 组" "${out}/groups.yaml" 'name: CDN-FALLBACK'
assert_contains "模式 4 fallback 探测 HTTPS 443" "${out}/groups.yaml" \
    'https://www.gstatic.com/generate_204'
assert_not_contains "模式 4 不使用 httpupgrade" "${out}/config.json" 'httpupgrade'

for mode_out in anytls cloudfront cloudflare combined; do
    out="${TMP_DIR}/${mode_out}"
    assert_not_contains "${mode_out} 不占用 10085" "${out}/config.json" '10085'
    assert_not_contains "${mode_out} 不使用 v2ray_api" "${out}/config.json" 'v2ray_api'
done

printf 'ok - 四模式渲染测试通过\n'
