#!/usr/bin/env bash
# Mode 3: Cloudflare orange-cloud XHTTP (one proxied domain serves both the XHTTP
# inbound and the Token-protected subscription).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
XHTTP_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="Cloudflare"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray Cloudflare CDN managed by easy_all"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"

readonly XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}"
readonly SUBSCRIPTION_OPTIONAL_VARIANTS=1

PROTOCOL=cloudflare
BACKEND=xray
CDN_PROVIDER=cloudflare
XHTTP_NODE_NAME=easy_all

readonly CDN_PROFILE_KEY=cloudflare
readonly CDN_EXPECTED_PROTOCOL=cloudflare
readonly CDN_MODE_LABEL="纯 CloudFlare（单域名）"
readonly CDN_ENTRY_SUMMARY="Cloudflare XHTTP"
readonly CDN_RECORD_COMMENT="easy_all cloudflare"
CDN_INSTALL_PORTS=(443)
CDN_STATE_VARIABLES=(
    PROTOCOL CDN_PROVIDER TCP_ACCELERATION
    VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
    CF_NODE_DOMAIN
    SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS SUBSCRIPTION_CONFIG VLESS_UUID
    CF_NODE_PREFIX XHTTP_PATH
    CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
    MIHOMO_TEMPLATE_SNAPSHOT
    SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
)

# shellcheck source=lib/cloudflare-mode.sh
source "${XHTTP_LIB_DIR}/cloudflare-mode.sh"

collect_install_inputs() {
    collect_cloudflare_install_inputs
}

# Mode 3 has no direct entry: every direct hook returns an empty result.
cdn_direct_domains() { return 0; }
cdn_prepare_direct_runtime() { return 0; }
cdn_direct_inbounds_json() { printf '[]'; }
cdn_direct_node_names() { printf '[]'; }
build_reality_link() { return 0; }
build_mihomo_reality_node() { return 0; }
cdn_validate_direct_runtime() { return 0; }
