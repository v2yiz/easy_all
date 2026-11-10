#!/usr/bin/env bash
# Mode 3: Cloudflare orange-cloud single domain (one proxied A record serves both
# the VLESS WebSocket node and the Token-protected subscription on 443).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

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

# Mode 3 has no direct entry: every direct hook returns an empty result.
cdn_direct_domains() { return 0; }
cdn_prepare_direct_runtime() { return 0; }
cdn_validate_direct_runtime() { return 0; }
