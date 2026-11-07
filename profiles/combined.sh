#!/usr/bin/env bash
# Mode 3: direct Reality + Cloudflare XHTTP.
set -Eeuo pipefail
umask 077

readonly COMBINED_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
XHTTP_LIB_DIR="${COMBINED_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="Cloudflare"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray direct/Cloudflare managed by easy_all"
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
source "${XHTTP_LIB_DIR}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/reality-target.sh
source "${XHTTP_LIB_DIR}/reality-target.sh"
# shellcheck source=lib/local-aggregation.sh
source "${XHTTP_LIB_DIR}/local-aggregation.sh"

readonly REALITY_PORT=8443
# XHTTP 侧的本机回环端口必须在这里定义：write_xray_config / write_nginx_config 都直接引用它，
# 缺了会在 set -u 下让首次安装崩在写配置阶段（该缺省来自 xhttp-runtime 的常量）。
# 这里刻意不接受环境覆盖：combined 没有针对该端口的校验与状态持久化，静默接受覆盖会出现
# "安装时用 A、之后 apply 又变回默认" 的隐性不一致；需要自定义端口时应先补校验、冲突检查与状态恢复。
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
readonly CDN_RECORD_COMMENT="easy_all combined"
readonly SUBSCRIPTION_OPTIONAL_VARIANTS=1

PROTOCOL=combined
BACKEND=xray
CDN_PROVIDER=cloudflare
XHTTP_NODE_NAME=easy_all

# lib/cloudflare-mode.sh 的 Profile 契约（见该文件头注释）。
readonly CDN_EXPECTED_PROTOCOL=combined
readonly CDN_MODE_LABEL="直连+CDN"
readonly CDN_ENTRY_SUMMARY="直连 + Cloudflare"
readonly CDN_REALITY_ENABLED=1
CDN_INSTALL_PORTS=(80 443 "${REALITY_PORT}")
CDN_STATE_VARIABLES=(
    PROTOCOL TCP_ACCELERATION
    VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
    DIRECT_DOMAIN CF_NODE_DOMAIN
    SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS SUBSCRIPTION_CONFIG VLESS_UUID
    DIRECT_NODE_NAME CF_NODE_PREFIX
    XHTTP_PATH REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
    CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
    SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
)

# shellcheck source=lib/cloudflare-mode.sh
source "${XHTTP_LIB_DIR}/cloudflare-mode.sh"

collect_install_inputs() {
    local domain index
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' '')")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"

    DIRECT_DOMAIN=$(normalize_domain "$(prompt_value '直连节点域名' "node.${CF_ZONE}")")
    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'Cloudflare 节点域名（橙云）' "cf.${CF_ZONE}")")
    SUBSCRIPTION_DOMAIN=$(normalize_domain "$(prompt_value '订阅域名（橙云）' "sub.${CF_ZONE}")")
    for domain in "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
        validate_domain "${domain}" || die "域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] || die "域名必须属于 ${CF_ZONE}：${domain}"
    done
    [[ "$(printf '%s\n' "${DIRECT_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" | sort -u | wc -l | tr -d ' ')" == "3" ]] \
        || die "三个域名必须互不相同"
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}

    CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（需 Zone 的 DNS 编辑 + SSL/证书 编辑权限）') \
        || die '缺少 Cloudflare API Token'
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,100}$ ]] || die "Cloudflare Token 格式无效"
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"

    REALITY_TARGET=$(prompt_value 'Reality 伪装目标（域名:端口）' 'swdist.apple.com:443')
    validate_reality_target "${REALITY_TARGET}" \
        || die "Reality 目标无效，需为 域名:端口：${REALITY_TARGET}"
    REALITY_TARGET="$(normalize_domain "${REALITY_TARGET%:*}"):${REALITY_TARGET##*:}"
    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP 路径无效"

    DIRECT_NODE_NAME=$(prompt_value '直连节点名' "${DIRECT_NODE_NAME:-🇺🇸直连}")
    CF_NODE_PREFIX=$(prompt_value 'Cloudflare 节点名前缀（自动追加 1~6 与官方兜底）' "${CF_NODE_PREFIX:-🇺🇸CF}")
    validate_node_name "${DIRECT_NODE_NAME}" \
        || die "直连节点名无效（1-64 字符，不能含换行）"
    # 订阅里本机节点与分组同名会让整个 Mihomo 配置解析失败。
    case "${DIRECT_NODE_NAME}" in
    AUTO | PROXY | GLOBAL | CDN-AUTO | CDN-FALLBACK | DIRECT | REJECT | PASS) die "直连节点名不能使用保留组名：${DIRECT_NODE_NAME}" ;;
    esac
    validate_node_name "${CF_NODE_PREFIX}" || die "Cloudflare 节点名前缀无效"
    for index in 1 2 3 4 5 6; do
        [[ "${CF_NODE_PREFIX}${index}" != "${DIRECT_NODE_NAME}" ]] \
            || die "Cloudflare 节点名 ${CF_NODE_PREFIX}${index} 与直连节点名重复"
    done
    [[ "$(cdn_cf_domain_node_name)" != "${DIRECT_NODE_NAME}" ]] \
        || die "Cloudflare 官方兜底节点名 $(cdn_cf_domain_node_name) 与直连节点名重复"
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

reality_mlkem_required() {
    local version major minor patch
    version=$(xray_installed_version)
    version=${version#v}
    IFS=. read -r major minor patch _ <<<"${version}"
    [[ "${major}" =~ ^[0-9]+$ && "${minor}" =~ ^[0-9]+$ && "${patch}" =~ ^[0-9]+$ ]] || return 1
    ((10#${major} * 10000 + 10#${minor} * 100 + 10#${patch} >= 260908))
}

build_reality_link() {
    local mlkem_param=""
    reality_mlkem_required || mlkem_param="&mlkem=0"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&packetEncoding=xudp%s#%s' \
        "${VLESS_UUID}" "${DIRECT_DOMAIN}" "${REALITY_PORT}" "${REALITY_TARGET%:*}" \
        "$(uri_encode "${REALITY_PUBLIC_KEY}")" "$(uri_encode "${REALITY_SHORT_ID}")" \
        "${mlkem_param}" "$(uri_encode "${DIRECT_NODE_NAME}")"
}

build_mihomo_reality_node() {
    local mlkem=""
    reality_mlkem_required && mlkem=$'      support-x25519mlkem768: true\n'
    jq -nr --arg name "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" --argjson port "${REALITY_PORT}" \
        --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
        --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" --arg mlkem "${mlkem}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: \($port)\n" +
        "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \($sni|@json)\n" +
        "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
        $mlkem +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n    ip-version: ipv4\n"'
}

update_reality_target() {
    local target=${1:-} current backup_config
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_valid_owner_token
    current=${REALITY_TARGET}
    if [[ -z "${target}" ]]; then
        [[ -t 0 ]] || die "非交互模式必须传入 域名:端口"
        target=$(prompt_value 'Reality 伪装目标（域名:端口）' "${current}")
    fi
    validate_reality_target "${target}" \
        || die "Reality 目标无效，需为 域名:端口：${target}"
    target="$(normalize_domain "${target%:*}"):${target##*:}"
    if [[ "${target}" == "${current}" ]]; then
        info "Reality 目标未变化：${current}"
        release_runtime_write_lock
        return 0
    fi
    REALITY_TARGET=${target}
    backup_config="$(make_temp_dir)/config.json"
    install -m 0600 "${XRAY_CONFIG}" "${backup_config}"
    if (
        validate_reality_target_runtime
        cdn_write_xray_config
        systemctl restart "${XRAY_SERVICE}"
        validate_protocol_runtime
    ); then
        save_state
        write_subscriptions
        save_state
        release_runtime_write_lock
        success "Reality 目标已更新：${current} → ${REALITY_TARGET}；请刷新客户端订阅"
        return 0
    fi
    warn "新运行时配置验收失败，正在恢复旧配置"
    REALITY_TARGET=${current}
    install -m 0600 "${backup_config}" "${XRAY_CONFIG}"
    systemctl restart "${XRAY_SERVICE}" || die "恢复旧配置后无法重启 ${XRAY_SERVICE}"
    validate_protocol_runtime
    die "运行时配置更新失败，已恢复旧配置"
}
