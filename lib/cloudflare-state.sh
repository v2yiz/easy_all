#!/usr/bin/env bash

# 单一来源：Cloudflare 橙云链路（模式 3 / 5）的状态结构必需字段。
#
# 与 lib/cloudfront-state.sh 同一约束：launcher 要在加载任何 Profile 之前分类状态，
# 因此这里只放纯函数与字段清单，不依赖运行时库、日志、Profile 常量或 state 值。

# 两模式（cloudflare / combined-cloudflare）共同持久字段。缺任一项都不足以安全接管，
# 只能走仅本机的卸载通道。
CLOUDFLARE_STATE_COMMON_FIELDS=(
    PROTOCOL
    CDN_PROVIDER
    VPS_PUBLIC_IPV4
    CF_ZONE
    CLOUDFLARE_ZONE_ID
    CF_NODE_DOMAIN
    SUB_DOWNLOAD_NAME
    OWNER_TOKEN
    ALLOWED_TOKENS
    SUBSCRIPTION_CONFIG
    VLESS_UUID
    CF_NODE_PREFIX
    XHTTP_PATH
    CLOUDFLARE_ORIGIN_CERT_ID
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
)

# 仅模式 5 持久字段：直连 Reality 入口的身份与密钥。
CLOUDFLARE_STATE_DIRECT_FIELDS=(
    DIRECT_DOMAIN
    DIRECT_NODE_NAME
    REALITY_TARGET
    REALITY_PRIVATE_KEY
    REALITY_PUBLIC_KEY
    REALITY_SHORT_ID
)

cloudflare_state_protocol_has_direct_entry() {
    [[ "${1:-}" == "combined-cloudflare" ]]
}

# 输出某协议的结构必需字段（每行一个）。未知协议只输出共同字段：协议本身由调用方
# 先行校验，这里不猜测它有没有直连入口。
cloudflare_state_required_fields() {
    local field
    for field in "${CLOUDFLARE_STATE_COMMON_FIELDS[@]}"; do
        printf '%s\n' "${field}"
    done
    cloudflare_state_protocol_has_direct_entry "${1:-}" || return 0
    for field in "${CLOUDFLARE_STATE_DIRECT_FIELDS[@]}"; do
        printf '%s\n' "${field}"
    done
}
