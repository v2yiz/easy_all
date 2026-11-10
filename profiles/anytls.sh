#!/usr/bin/env bash
# Mode 1: AnyTLS direct entry (TCP 443) with an optional Cloudflare-proxied
# subscription site on 8443. No AWS resources and no 985GB protection.
set -Eeuo pipefail
umask 077

readonly ANYTLS_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${ANYTLS_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# 直连节点名的推荐默认值：必须在加载 singbox-runtime.sh 之前赋值，否则会被其
# AnyTLS / VLESS-WS 兜底值覆盖，交互提示与文档默认名不一致。
DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-🇺🇸直连}

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/anytls-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/anytls-mode.sh"

PROTOCOL=anytls
BACKEND=sing-box
readonly CDN_PROFILE_KEY=anytls
readonly CDN_EXPECTED_PROTOCOL=anytls
readonly CDN_MODE_LABEL="直连（AnyTLS）"
readonly CDN_ENTRY_SUMMARY="AnyTLS direct 443 + 可选订阅 8443"
readonly CDN_RECORD_COMMENT="easy_all anytls"
CDN_INSTALL_PORTS=(443 8443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1

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
    # AnyTLS 入站的监听与 TLS 已由 validate_protocol_runtime 覆盖（443）。
    return 0
}
