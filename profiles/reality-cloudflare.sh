#!/usr/bin/env bash
# Mode 4: Reality self-steal direct entry (TCP 443) plus the Cloudflare orange-cloud CDN
# entry (Caddy origin 8443 → sing-box loopback VLESS HTTPUpgrade on 10086), same shape as
# mode 6. 443 is a vless/xtls-rprx-vision/reality inbound: any non-Reality handshake
# (including active probing) is handed to Caddy on 127.0.0.1:9443 and gets a real TLS 1.3
# handshake with the camouflage site using a DIRECT_DOMAIN-only Let's Encrypt cert (no SAN
# overlap with CF_NODE_DOMAIN). 9443 is loopback only and never exposes subscription routes
# or an origin guard; 8443 只对 Cloudflare IPv4 回源段放行，使用独立的 CF_NODE_DOMAIN 证书。
set -Eeuo pipefail
umask 077

readonly REALITY_CLOUDFLARE_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${REALITY_CLOUDFLARE_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# 两个节点名的推荐默认值：必须在加载运行时库之前赋值，否则会被其 Reality / VLESS-WS
# 兜底值覆盖，交互提示与文档默认名不一致。
DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-🇺🇸Reality}
CF_NODE_PREFIX=${CF_NODE_PREFIX:-🇺🇸CF}

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/reality-cloudflare-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/reality-cloudflare-mode.sh"

PROTOCOL=reality-cloudflare
BACKEND=sing-box
CDN_PROVIDER=cloudflare
readonly CDN_PROFILE_KEY=reality-cloudflare
readonly CDN_EXPECTED_PROTOCOL=reality-cloudflare
readonly CDN_MODE_LABEL="Reality + CloudFlare"
readonly CDN_ENTRY_SUMMARY="VLESS Reality direct 443 + 伪装站 127.0.0.1:9443 + Cloudflare 橙云 VLESS HTTPUpgrade"
# 声明性元数据：实际安装端口预检由 runtime_public_tcp_ports（443） /
# runtime_cloudflare_only_port（8443） / runtime_cdn_loopback_port（10086）与
# caddy_reality_camouflage_port（9443）派生。
CDN_INSTALL_PORTS=(443 8443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1
# 橙云 A 记录与订阅/节点域名同一归属注释；purge-cloud 按 easy_all 前缀识别。
readonly CDN_RECORD_COMMENT="easy_all reality-cloudflare"

collect_install_inputs() {
    collect_direct_install_inputs
}

cdn_direct_domains() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] && printf '%s\n' "${DIRECT_DOMAIN}"
    return 0
}

cdn_prepare_direct_runtime() {
    reality_prepare_runtime
}

cdn_validate_direct_runtime() {
    # 443 的 Reality 入站与回环伪装站闭环由 validate_protocol_runtime 覆盖
    # （它对 Reality 模式额外探测 443 回落链路）；此处只复核身份完整。
    [[ -n "${DIRECT_DOMAIN:-}" && -n "${VLESS_UUID:-}" ]] \
        || die "Reality 直连身份缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] \
        || die "Reality 密钥对缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ -n "${REALITY_SHORT_ID:-}" ]] \
        || die "Reality short_id 缺失；请先执行 sudo easy_all uninstall 后重新安装"
}
