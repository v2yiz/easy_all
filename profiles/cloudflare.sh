#!/usr/bin/env bash
# Mode 2: Cloudflare orange-cloud single domain (one proxied A record serves both
# the VLESS WebSocket node and the Token-protected subscription on 443).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# CDN 节点名的推荐默认值：必须在加载 singbox-runtime.sh 之前赋值，否则会被其
# AnyTLS / VLESS-WS 兜底值覆盖，交互提示与文档默认名不一致。
CF_NODE_PREFIX=${CF_NODE_PREFIX:-🇺🇸CF}

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/cloudflare-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/cloudflare-mode.sh"

PROTOCOL=cloudflare
BACKEND=sing-box
CDN_PROVIDER=cloudflare
readonly CDN_PROFILE_KEY=cloudflare
readonly CDN_EXPECTED_PROTOCOL=cloudflare
readonly CDN_MODE_LABEL="纯 CloudFlare（单域名）"
readonly CDN_ENTRY_SUMMARY="Cloudflare 橙云 + VLESS WebSocket"
CDN_INSTALL_PORTS=(443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1

collect_install_inputs() {
    collect_cloudflare_install_inputs
}

# Mode 2 has no direct entry: every direct hook returns an empty result.
cdn_direct_domains() { return 0; }
cdn_prepare_direct_runtime() { return 0; }
cdn_validate_direct_runtime() { return 0; }
