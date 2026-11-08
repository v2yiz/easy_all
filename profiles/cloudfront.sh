#!/usr/bin/env bash
# Mode 2: CloudFront-only CDN (Cloudflare DNS → ACM/CloudFront → Let's Encrypt origin).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
XHTTP_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="CloudFront"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray CloudFront CDN managed by easy_all"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"

readonly XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}"
readonly SUBSCRIPTION_OPTIONAL_VARIANTS=1

PROTOCOL=cloudfront
BACKEND=xray
CDN_PROVIDER=aws
XHTTP_NODE_NAME=easy_all

readonly CDN_PROFILE_KEY=cloudfront
readonly CDN_EXPECTED_PROTOCOL=cloudfront
readonly CDN_MODE_LABEL="纯 CDN（CloudFront）"
readonly CDN_ENTRY_SUMMARY="AWS CloudFront XHTTP"
CDN_INSTALL_PORTS=(80 443)
CDN_STATE_VARIABLES=(
    PROTOCOL CDN_PROVIDER TCP_ACCELERATION
    VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
    CF_ORIGIN_DOMAIN CF_NODE_DOMAIN
    SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS SUBSCRIPTION_CONFIG VLESS_UUID
    CF_NODE_PREFIX XHTTP_PATH ORIGIN_HEADER_SECRET
    AWS_CLOUDFRONT_DISTRIBUTION_ID AWS_CLOUDFRONT_DOMAIN AWS_ACM_CERTIFICATE_ARN
    CDN_TRAFFIC_PROTECTION_GB MIHOMO_TEMPLATE_SNAPSHOT
    SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
)

# shellcheck source=lib/cloudfront-mode.sh
source "${XHTTP_LIB_DIR}/cloudfront-mode.sh"

collect_install_inputs() {
    collect_cloudfront_install_inputs
}

# Mode 2 has no direct entry: every direct hook returns an empty result.
cdn_direct_domains() { return 0; }
cdn_prepare_direct_runtime() { return 0; }
cdn_direct_inbounds_json() { printf '[]'; }
cdn_direct_node_names() { printf '[]'; }
build_reality_link() { return 0; }
build_mihomo_reality_node() { return 0; }
cdn_validate_direct_runtime() { return 0; }
