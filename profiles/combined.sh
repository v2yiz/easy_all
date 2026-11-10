#!/usr/bin/env bash
# Mode 4: AnyTLS direct entry (TCP 443) plus the CloudFront CDN entry
# (Caddy origin 8443 → sing-box loopback VLESS WebSocket on 10086).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/cloudfront-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/cloudfront-mode.sh"

PROTOCOL=combined-cloudfront
BACKEND=sing-box
CDN_PROVIDER=aws
DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-}
# 模式 4 的唯一键：模式选择、安装 marker、安装身份与 Profile 路由都用同一个值。
readonly CDN_PROFILE_KEY=combined-cloudfront
readonly CDN_EXPECTED_PROTOCOL=combined-cloudfront
readonly CDN_MODE_LABEL="直连+CDN（CloudFront）"
readonly CDN_ENTRY_SUMMARY="AnyTLS direct 443 + AWS CloudFront VLESS WebSocket"
CDN_INSTALL_PORTS=(443 8443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1

collect_install_inputs() {
    # 公共输入会校验本机节点名，此时直连节点名还不存在：先给出默认值，稍后以它为提示默认值。
    DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-🇺🇸直连}
    collect_cloudfront_install_inputs
    anytls_collect_direct_inputs
    cdn_validate_install_domains
    cdn_validate_install_owner_token
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
