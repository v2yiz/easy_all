#!/usr/bin/env bash
# 真核心门禁（design §6 H / §13）：用锁定的真实 sing-box 与 Caddy 校验正式生成的配置。
# 缺核心、版本不符、配置校验或端口监听失败都失败——不跳过。
#
# 本脚本只做核心级校验（sing-box check / caddy validate / 真实监听冒烟）；
# 完整 HTTP 矩阵由 test/test_core_e2e.mjs 在同一组核心上覆盖。
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-cores.XXXXXX")
# 只在脚本自建时登记清理：外部注入的 RUNTIME_TMP 属调用方，不能随本脚本删除。
cleanup_paths=("${WORK_DIR}")
cleanup() {
    local path
    for path in "${cleanup_paths[@]:-}"; do
        [[ -n "${path}" ]] && rm -rf -- "${path}"
    done
}
trap cleanup EXIT

die() {
    printf '\033[31mverify-cores: %s\033[0m\n' "$*" >&2
    exit 1
}

SINGBOX_BIN=${SINGBOX_BIN:-/etc/easy_all/sing-box/sing-box}
CADDY_BIN=${CADDY_BIN:-/etc/easy_all/caddy/caddy}
export SINGBOX_BIN CADDY_BIN

# CI 无系统安装的核心：EASY_ALL_DOWNLOAD_CORES=1 时按 design §6 下载并校验锁定版本，
# 摘要/清单不符同样失败（不降级为“跳过”）。
if [[ "${EASY_ALL_DOWNLOAD_CORES:-0}" == "1" ]]; then
    if [[ -z "${RUNTIME_TMP:-}" ]]; then
        RUNTIME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-core-dl.XXXXXX")
        # 自建目录随退出清理；外部预设的 RUNTIME_TMP 不入清理清单。
        cleanup_paths+=("${RUNTIME_TMP}")
    fi
    export RUNTIME_TMP
    # shellcheck source=lib/log.sh
    source "${ROOT_DIR}/lib/log.sh"
    # shellcheck source=lib/singbox-core.sh
    source "${ROOT_DIR}/lib/singbox-core.sh"
    # shellcheck source=lib/caddy-core.sh
    source "${ROOT_DIR}/lib/caddy-core.sh"
    download_singbox || die "下载/校验锁定 sing-box 失败"
    download_caddy || die "下载/校验锁定 Caddy 失败"
    SINGBOX_BIN=${SINGBOX_BIN}
    CADDY_BIN=${CADDY_BIN}
    export SINGBOX_BIN CADDY_BIN
fi

[[ -x "${SINGBOX_BIN}" ]] || die "缺少真实 sing-box 可执行文件（${SINGBOX_BIN}）；本门禁不跳过"
[[ -x "${CADDY_BIN}" ]] || die "缺少真实 Caddy 可执行文件（${CADDY_BIN}）；本门禁不跳过"
export SINGBOX_BIN CADDY_BIN

# shellcheck source=lib/log.sh
source "${ROOT_DIR}/lib/log.sh"
# shellcheck source=lib/state.sh
source "${ROOT_DIR}/lib/state.sh"
# shellcheck source=lib/singbox-core.sh
source "${ROOT_DIR}/lib/singbox-core.sh"
# shellcheck source=lib/caddy-core.sh
source "${ROOT_DIR}/lib/caddy-core.sh"

[[ "$(singbox_binary_version "${SINGBOX_BIN}")" == "$(singbox_version)" ]] \
    || die "sing-box 版本不是锁定版本 $(singbox_version)"
[[ "$(caddy_binary_version "${CADDY_BIN}")" == "v$(caddy_version)" ]] \
    || die "Caddy 版本不是锁定版本 v$(caddy_version)"

render_mode() {
    local profile=$1 out=$2
    mkdir -p "${out}"
    (
        export RUNTIME_TMP="${out}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${out}/state"
        export EASY_ALL_CERT_DIR_OVERRIDE="${out}/certs"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out}/subscriptions"
        export SINGBOX_CONFIG="${out}/config.json"
        export CADDY_CONFIG="${out}/Caddyfile"
        mkdir -p "${RUNTIME_TMP}"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/${profile}.sh"
        CF_ZONE=example.com
        VPS_PUBLIC_IPV4=203.0.113.10
        SUB_DOWNLOAD_NAME=EASY_ALL
        ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
        SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
        CLOUDFLARE_ZONE_ID=zoneid
        SUBSCRIPTION_MODE=deploy
        if state_protocol_has_direct_entry "${PROTOCOL}"; then
            DIRECT_DOMAIN=direct.example.com
            DIRECT_NODE_NAME=direct
            ANYTLS_PASSWORD=0123456789abcdefaaaabbbb
        fi
        if state_protocol_has_cdn_entry "${PROTOCOL}"; then
            CF_NODE_DOMAIN=cf.example.com
            CF_NODE_PREFIX=CF
            VLESS_UUID=11111111-2222-3333-4444-555555555555
            VLESS_PATH=/vless-0123456789ab
        fi
        if state_protocol_uses_cloudfront "${PROTOCOL}"; then
            CF_ORIGIN_DOMAIN=origin.example.com
            SUBSCRIPTION_DOMAIN=cf.example.com
            ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
            CDN_TRAFFIC_PROTECTION_GB=985
            AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
            AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
            AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
        fi
        if [[ "${PROTOCOL}" == "anytls" ]]; then
            SUBSCRIPTION_DOMAIN=sub.example.com
            CLOUDFLARE_ORIGIN_RULESET_ID=rs
            CLOUDFLARE_ORIGIN_RULE_ID=rule
        fi
        cdn_derive_runtime_fields || exit 1
        # 真实核心校验 TLS 证书与私钥：这里用一次性自签材料，只验证配置可被核心接受。
        install -d -m 0700 "${CERT_DIR}"
        openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=${CF_ZONE}" \
            -keyout "${KEY_FILE}" -out "${CERT_FILE}" >/dev/null 2>&1 || exit 1
        chmod 0600 "${KEY_FILE}"
        render_singbox_config "${SINGBOX_CONFIG}" 0
        validate_singbox_config "${SINGBOX_CONFIG}" || exit 1
        if runtime_caddy_site_enabled; then
            render_caddy_config "${CADDY_CONFIG}" 0 1
            validate_caddy_config "${CADDY_CONFIG}" || exit 1
        fi
    ) || die "${profile} 的正式配置未通过真实核心校验"
    printf 'ok - %s 配置通过真实核心校验\n' "${profile}"
}

for profile in anytls cloudfront cloudflare combined combined-cloudflare; do
    render_mode "${profile}" "${WORK_DIR}/${profile}"
done

printf 'ok - verify-cores 完成（sing-box %s / Caddy %s）\n' \
    "$(singbox_version)" "$(caddy_version)"
