#!/usr/bin/env bash
# Mode 3: AnyTLS direct entry (TCP 443) plus the Cloudflare orange-cloud entry:
# one proxied node domain serves the VLESS WebSocket node and the subscription via
# Caddy origin 8443 (Origin Rule), with sing-box loopback VLESS WebSocket on 10086.
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# 两个节点名必须在加载运行时库之前给出推荐默认值：singbox-runtime.sh 会在 source 时
# 用 AnyTLS / VLESS-WS 兜底，提前赋值才能让交互提示与文档默认名一致。
DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-主节点}
CF_NODE_PREFIX=${CF_NODE_PREFIX:-CDN备用}

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/anytls-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/anytls-mode.sh"

PROTOCOL=combined-cloudflare
BACKEND=sing-box
CDN_PROVIDER=cloudflare
readonly CDN_PROFILE_KEY=combined-cloudflare
readonly CDN_EXPECTED_PROTOCOL=combined-cloudflare
readonly CDN_MODE_LABEL="直连+CDN（CloudFlare）"
readonly CDN_ENTRY_SUMMARY="AnyTLS direct 443 + Cloudflare 橙云 VLESS WebSocket"
CDN_INSTALL_PORTS=(443 8443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1
# 橙云 A 记录与订阅/节点域名同一归属注释；purge-cloud 按 easy_all 前缀识别。
readonly CDN_RECORD_COMMENT="easy_all combined-cloudflare"

collect_install_inputs() {
    collect_anytls_install_inputs
}

cdn_direct_domains() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] && printf '%s\n' "${DIRECT_DOMAIN}"
    return 0
}

cdn_prepare_direct_runtime() {
    anytls_prepare_runtime
}

cdn_validate_direct_runtime() {
    # direct 入站（443）由 validate_protocol_runtime 断言；此处只复核身份完整。
    [[ -n "${DIRECT_DOMAIN:-}" && -n "${ANYTLS_PASSWORD:-}" ]] \
        || die "AnyTLS 身份缺失；请先执行 sudo easy_all uninstall 后重新安装"
}
