#!/usr/bin/env bash
# Mode 2: Cloudflare XHTTP CDN only (no direct entry).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XHTTP_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="Cloudflare"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray Cloudflare CDN managed by easy_all"
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
source "${XHTTP_LIB_DIR}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/local-aggregation.sh
source "${XHTTP_LIB_DIR}/local-aggregation.sh"

# 与直连+CDN模式一致：回环端口只由本 Profile 常量决定，不接受环境覆盖。
readonly XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}"
readonly CLOUDFLARE_API_BASE="${CLOUDFLARE_API_BASE_OVERRIDE:-https://api.cloudflare.com/client/v4}"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
readonly CF_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CF_CA_ROOT_FILE}"
readonly CLOUDFLARE_UFW_COMMENT="easy_all-cf-origin"
readonly CLOUDFLARE_UFW_PORT=443
readonly CLOUDFLARE_ORIGIN_IPS_FILE="${STATE_DIR}/cloudflare-origin-ipv4.txt"
readonly CLOUDFLARE_TOKEN_FILE="${STATE_DIR}/cloudflare.token"
readonly CDN_RECORD_COMMENT="easy_all cdn"
readonly SUBSCRIPTION_OPTIONAL_VARIANTS=1

PROTOCOL=cdn
BACKEND=xray
CDN_PROVIDER=cloudflare
XHTTP_NODE_NAME=easy_all

# lib/cloudflare-mode.sh 的 Profile 契约（见该文件头注释）。
readonly CDN_EXPECTED_PROTOCOL=cdn
readonly CDN_MODE_LABEL="纯 CDN"
readonly CDN_ENTRY_SUMMARY="Cloudflare XHTTP"
readonly CDN_REALITY_ENABLED=0
CDN_INSTALL_PORTS=(80 443)
CDN_STATE_VARIABLES=(
    PROTOCOL TCP_ACCELERATION
    VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
    CF_NODE_DOMAIN
    SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS SUBSCRIPTION_CONFIG VLESS_UUID
    CF_NODE_PREFIX
    XHTTP_PATH
    CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
    SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
)

# shellcheck source=lib/cloudflare-mode.sh
source "${XHTTP_LIB_DIR}/cloudflare-mode.sh"

collect_install_inputs() {
    local domain
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' '')")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"

    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'Cloudflare 节点域名（橙云）' "cf.${CF_ZONE}")")
    SUBSCRIPTION_DOMAIN=$(normalize_domain "$(prompt_value '订阅域名（橙云）' "sub.${CF_ZONE}")")
    for domain in "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
        validate_domain "${domain}" || die "域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] || die "域名必须属于 ${CF_ZONE}：${domain}"
    done
    [[ "${CF_NODE_DOMAIN}" != "${SUBSCRIPTION_DOMAIN}" ]] || die "两个域名必须互不相同"
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}

    CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（需 Zone 的 DNS 编辑 + SSL/证书 编辑权限）') \
        || die '缺少 Cloudflare API Token'
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,100}$ ]] || die "Cloudflare Token 格式无效"
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"

    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP 路径无效"

    CF_NODE_PREFIX=$(prompt_value 'Cloudflare 节点名前缀（自动追加 1~6 与官方兜底）' "${CF_NODE_PREFIX:-🇺🇸CF}")
    validate_node_name "${CF_NODE_PREFIX}" || die "Cloudflare 节点名前缀无效"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")")

    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"
    if [[ -z "${SUBSCRIPTION_CONFIG:-}" ]] \
        && [[ -n "${ALLOWED_TOKENS:-}" || -n "${OWNER_TOKEN:-}" ]]; then
        cdn_sync_allowed_tokens \
            || die "订阅 Token 无效：需 8-128 位 URL 安全字符（A-Z a-z 0-9 . _ ~ -）"
    fi
    SUBSCRIPTION_CONFIG=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}") \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes"
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" \
        || die "订阅配置无效：节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    cdn_validate_install_owner_token

    if [[ -z "${VPS_PUBLIC_IPV4:-}" ]]; then
        VPS_PUBLIC_IPV4=$(detect_public_ipv4) \
            || die "无法自动探测本机公网 IPv4"
    fi
}
