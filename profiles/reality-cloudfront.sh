#!/usr/bin/env bash
# Mode 3: Reality self-steal direct entry (TCP 443) + single-port 443 CloudFront origin
# consolidation. Public TCP 443 is owned exclusively by sing-box vless/xtls-rprx-vision/reality:
# any non-Reality handshake (browsers, active probes, and CloudFront origin HTTPS) is transparently
# forwarded to Caddy on 127.0.0.1:9443, which routes exact X-Easy-All-Origin-Key requests to
# VLESS WebSocket (127.0.0.1:10086) / subscription routes and serves the camouflage site to all
# other traffic. No public 8443 port is exposed on fresh installs.
set -Eeuo pipefail
umask 077

readonly REALITY_CLOUDFRONT_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
EASY_ALL_RUNTIME_LIB_DIR="${REALITY_CLOUDFRONT_PROFILE_ROOT}/../lib"
export EASY_ALL_RUNTIME_LIB_DIR

# 两个节点名的推荐默认值：必须在加载 singbox-runtime.sh 之前赋值，否则会被其
# AnyTLS / VLESS-WS 兜底值覆盖，交互提示与文档默认名不一致。
DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-🇺🇸Reality}
CF_NODE_PREFIX=${CF_NODE_PREFIX:-🇺🇸AWS}

# shellcheck source=lib/runtime-core.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/runtime-core.sh"
# shellcheck source=lib/cloudfront-mode.sh
source "${EASY_ALL_RUNTIME_LIB_DIR}/cloudfront-mode.sh"

PROTOCOL=reality-cloudfront
BACKEND=sing-box
CDN_PROVIDER=aws
readonly CDN_PROFILE_KEY=reality-cloudfront
readonly CDN_EXPECTED_PROTOCOL=reality-cloudfront
readonly CDN_MODE_LABEL="Reality + CloudFront"
readonly CDN_ENTRY_SUMMARY="VLESS Reality direct 443 + 回环 127.0.0.1:9443 伪装站与 AWS CloudFront 单 443 合一回源"
# 声明性元数据：实际安装端口预检由 runtime_public_tcp_ports（443） /
# runtime_cloudflare_only_port（本模式为空） /
# runtime_cdn_loopback_port（10086）与 caddy_reality_camouflage_port（9443）派生。
CDN_INSTALL_PORTS=(443)
SUBSCRIPTION_OPTIONAL_VARIANTS=1

collect_install_inputs() {
    collect_cloudfront_install_inputs
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
    # （它对本模式额外探测 443 回落链路）；此处只复核身份完整。
    [[ -n "${DIRECT_DOMAIN:-}" && -n "${VLESS_UUID:-}" ]] \
        || die "Reality 直连身份缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ -n "${REALITY_PRIVATE_KEY:-}" && -n "${REALITY_PUBLIC_KEY:-}" ]] \
        || die "Reality 密钥对缺失；请先执行 sudo easy_all uninstall 后重新安装"
    [[ -n "${REALITY_SHORT_ID:-}" ]] \
        || die "Reality short_id 缺失；请先执行 sudo easy_all uninstall 后重新安装"
}
