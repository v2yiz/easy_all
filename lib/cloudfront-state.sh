#!/usr/bin/env bash

# 单一来源：CloudFront 状态的结构必需字段。
#
# 同时被 launcher（easy_all，在加载任何 Profile 之前分类状态）与新核心
# （lib/cloudfront-mode.sh 的结构校验）使用，因此这里只放纯函数与字段清单，
# 不得依赖运行时库、日志、Profile 常量或任何 state 值。

# 两模式（cloudfront / combined-cloudfront）共同持久字段。这是设计 §3.2 与核心
# 原校验列表的并集：缺任一字段都不足以安全接管，只能走仅本机卸载通道。
CLOUDFRONT_STATE_COMMON_FIELDS=(
    PROTOCOL
    CDN_PROVIDER
    VPS_PUBLIC_IPV4
    CF_ZONE
    CLOUDFLARE_ZONE_ID
    CF_ORIGIN_DOMAIN
    CF_NODE_DOMAIN
    SUBSCRIPTION_DOMAIN
    SUB_DOWNLOAD_NAME
    OWNER_TOKEN
    ALLOWED_TOKENS
    SUBSCRIPTION_CONFIG
    VLESS_UUID
    CF_NODE_PREFIX
    XHTTP_PATH
    ORIGIN_HEADER_SECRET
    AWS_CLOUDFRONT_DISTRIBUTION_ID
    AWS_CLOUDFRONT_DOMAIN
    AWS_ACM_CERTIFICATE_ARN
    CDN_TRAFFIC_PROTECTION_GB
)

# 仅模式 3 持久字段：直连 Reality 入口的身份与密钥。缺任一项时模式 3 的渲染、
# 订阅与 target 更新都无法进行，必须与共同字段同等判为结构不完整。
CLOUDFRONT_STATE_DIRECT_FIELDS=(
    DIRECT_DOMAIN
    DIRECT_NODE_NAME
    REALITY_TARGET
    REALITY_PRIVATE_KEY
    REALITY_PUBLIC_KEY
    REALITY_SHORT_ID
)

cloudfront_state_protocol_has_direct_entry() {
    [[ "${1:-}" == "combined-cloudfront" ]]
}

# 输出某协议的结构必需字段（每行一个）。未知协议只输出共同字段：协议本身由调用方
# 先行校验，这里不猜测它有直连入口。
cloudfront_state_required_fields() {
    local field
    for field in "${CLOUDFRONT_STATE_COMMON_FIELDS[@]}"; do
        printf '%s\n' "${field}"
    done
    cloudfront_state_protocol_has_direct_entry "${1:-}" || return 0
    for field in "${CLOUDFRONT_STATE_DIRECT_FIELDS[@]}"; do
        printf '%s\n' "${field}"
    done
}
