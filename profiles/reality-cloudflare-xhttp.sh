#!/usr/bin/env bash
# Mode 5: Reality self-steal direct entry (TCP 443) plus the Cloudflare orange-cloud CDN entry
# (Caddy origin 127.0.0.1:9443 double site → Xray VLESS XHTTP on 127.0.0.1:10086), same
# single-443 shape as mode 3 but with a pure xray-core + Caddy backend (no sing-box).
#
# 443 是 vless + raw/tcp + xtls-rprx-vision + Reality 入站：任何非 Reality 握手（包括主动
# 探测）被透明交给 127.0.0.1:9443 的 Caddy，用只覆盖 DIRECT_DOMAIN 的 LE 证书给出真实
# TLS 1.3 握手与伪装站；9443 同时以只覆盖 CF_NODE_DOMAIN 的独立证书承载橙云回源站点，
# 首个指令按 X-Easy-All-Origin-Key 分流，缺头/错头静默落伪装站。
# 本模式不安装、不依赖、不下发 sing-box（BACKEND=xray）。
set -Eeuo pipefail
umask 077

readonly REALITY_CLOUDFLARE_XHTTP_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${REALITY_CLOUDFLARE_XHTTP_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# 两个节点名的推荐默认值：必须在加载运行时库之前赋值，否则会被其 Reality / VLESS 兜底值覆盖。
DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-🇺🇸Reality}
CF_NODE_PREFIX=${CF_NODE_PREFIX:-🇺🇸CF}

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/reality-cloudflare-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/reality-cloudflare-mode.sh"

PROTOCOL=reality-cloudflare-xhttp
BACKEND=xray
CDN_PROVIDER=cloudflare
readonly CDN_PROFILE_KEY=reality-cloudflare-xhttp
readonly CDN_EXPECTED_PROTOCOL=reality-cloudflare-xhttp
readonly CDN_MODE_LABEL="Reality + CloudFlare (Xray XHTTP)"
readonly CDN_ENTRY_SUMMARY="VLESS Reality direct 443 + 伪装站 127.0.0.1:9443 + Cloudflare 橙云 VLESS XHTTP (单 443 合一)"
# 声明性元数据：实际安装端口预检由 runtime_public_tcp_ports（443） /
# runtime_cloudflare_only_port（空） / runtime_cdn_loopback_port（10086）与
# caddy_reality_camouflage_port（9443）派生；模式 5 不开放 8443、不需要 CF 回源端口白名单。
CDN_INSTALL_PORTS=(443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1
# 橙云 A 记录与订阅/节点域名同一归属注释；purge-cloud 按 easy_all 前缀识别。
readonly CDN_RECORD_COMMENT="easy_all reality-cloudflare-xhttp"

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
    # 443 的 Reality 入站与回环伪装站闭环由 validate_protocol_runtime 覆盖；
    # 此处只复核身份与源站守卫密钥完整（Transform Rule 依赖它）。
    [[ -n "${DIRECT_DOMAIN:-}" && -n "${VLESS_UUID:-}" ]] \
        || die "Reality 直连身份缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] \
        || die "Reality 密钥对缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ -n "${REALITY_SHORT_ID:-}" ]] \
        || die "Reality short_id 缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ "${ORIGIN_HEADER_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "源站守卫密钥缺失或格式无效；请先执行 sudo easy_all uninstall 后重新安装"
}
