#!/usr/bin/env bash
# Mode 3: direct Reality + CloudFront XHTTP (Cloudflare DNS → ACM/CloudFront →
# Let's Encrypt origin, plus the fixed 8443 Reality inbound).
set -Eeuo pipefail
umask 077

readonly CDN_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
XHTTP_LIB_DIR="${CDN_PROFILE_ROOT}/../lib"
XHTTP_CDN_NAME_OVERRIDE="CloudFront"
XHTTP_SERVICE_DESCRIPTION_OVERRIDE="Xray direct/CloudFront managed by easy_all"

# shellcheck source=lib/xhttp-runtime.sh
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
# shellcheck source=lib/reality-target.sh
source "${XHTTP_LIB_DIR}/reality-target.sh"

readonly REALITY_PORT=8443
readonly XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}"
readonly SUBSCRIPTION_OPTIONAL_VARIANTS=1

PROTOCOL=combined-cloudfront
BACKEND=xray
CDN_PROVIDER=aws
XHTTP_NODE_NAME=easy_all

readonly CDN_PROFILE_KEY=combined
readonly CDN_EXPECTED_PROTOCOL=combined-cloudfront
readonly CDN_MODE_LABEL="直连+CDN（CloudFront）"
readonly CDN_ENTRY_SUMMARY="直连 Reality + AWS CloudFront XHTTP"
CDN_INSTALL_PORTS=(80 443 "${REALITY_PORT}")
CDN_STATE_VARIABLES=(
    PROTOCOL CDN_PROVIDER TCP_ACCELERATION
    VPS_PUBLIC_IPV4 CF_ZONE CLOUDFLARE_ZONE_ID
    CF_ORIGIN_DOMAIN CF_NODE_DOMAIN
    SUBSCRIPTION_DOMAIN SUB_DOWNLOAD_NAME OWNER_TOKEN ALLOWED_TOKENS SUBSCRIPTION_CONFIG VLESS_UUID
    CF_NODE_PREFIX XHTTP_PATH ORIGIN_HEADER_SECRET
    AWS_CLOUDFRONT_DISTRIBUTION_ID AWS_CLOUDFRONT_DOMAIN AWS_ACM_CERTIFICATE_ARN
    CDN_TRAFFIC_PROTECTION_GB MIHOMO_TEMPLATE_SNAPSHOT
    DIRECT_DOMAIN DIRECT_NODE_NAME
    REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
    SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
)

# shellcheck source=lib/cloudfront-mode.sh
source "${XHTTP_LIB_DIR}/cloudfront-mode.sh"

# 直连入口的身份字段由本 Profile 持有；CloudFront 部分全部走共享核心。
cdn_require_direct_state() {
    local variable
    for variable in DIRECT_DOMAIN DIRECT_NODE_NAME REALITY_TARGET \
        REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID; do
        [[ -n "${!variable:-}" ]] \
            || die "状态缺少模式 4 必需字段：${variable}；请先执行 sudo easy_all uninstall 后重新安装"
    done
}

# --- Install inputs -----------------------------------------------------------

collect_reality_install_inputs() {
    DIRECT_DOMAIN=$(normalize_domain "$(prompt_value \
        "直连节点域名（可与源站域名相同：${CF_ORIGIN_DOMAIN}）" "${DIRECT_DOMAIN:-node.${CF_ZONE}}")")
    REALITY_TARGET=$(prompt_value 'Reality 伪装目标（域名:端口）' \
        "${REALITY_TARGET:-swdist.apple.com:443}")
    validate_reality_target "${REALITY_TARGET}" \
        || die "Reality 目标无效，需为 域名:端口：${REALITY_TARGET}"
    REALITY_TARGET="$(normalize_domain "${REALITY_TARGET%:*}"):${REALITY_TARGET##*:}"
    DIRECT_NODE_NAME=$(prompt_value '直连节点名' "${DIRECT_NODE_NAME:-🇺🇸直连}")
    validate_node_name "${DIRECT_NODE_NAME}" \
        || die "直连节点名无效（1-64 字符，不能含控制字符）"
    cdn_node_name_reserved "${DIRECT_NODE_NAME}" \
        && die "直连节点名不能使用保留组名：${DIRECT_NODE_NAME}"
    # 非常用名时上一行的 && 列表整体返回 1，set -e 会把函数判成失败。
    return 0
}

collect_install_inputs() {
    # 公共输入会校验本机节点名，此时直连节点名还不存在：先给出默认值，稍后以它为提示默认值。
    DIRECT_NODE_NAME=${DIRECT_NODE_NAME:-🇺🇸直连}
    collect_cloudfront_install_inputs
    collect_reality_install_inputs
    # 直连域名与直连节点名是在公共输入之后才有的：补齐域名关系、聚合重名与保留名检查。
    cdn_validate_install_domains
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" \
        || die "订阅配置无效：节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    cdn_validate_install_owner_token
}

# --- Direct hooks -------------------------------------------------------------

cdn_direct_domains() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || return 0
    printf '%s\n' "${DIRECT_DOMAIN}"
}

cdn_prepare_direct_runtime() {
    local pair
    [[ -n "${DIRECT_DOMAIN:-}" && -n "${DIRECT_NODE_NAME:-}" ]] \
        || die "直连域名/节点名缺失；请先执行 sudo easy_all uninstall 后重新安装"
    validate_reality_target "${REALITY_TARGET:-}" \
        || die "Reality 目标无效，需为 域名:端口：${REALITY_TARGET:-空}"
    REALITY_TARGET="$(normalize_domain "${REALITY_TARGET%:*}"):${REALITY_TARGET##*:}"
    if [[ -z "${REALITY_PRIVATE_KEY:-}" ]]; then
        pair=$("${XRAY_BIN}" x25519) || die "生成 Reality X25519 密钥失败"
        REALITY_PRIVATE_KEY=$(awk '/PrivateKey/ {print $NF}' <<<"${pair}")
    fi
    [[ -n "${REALITY_PRIVATE_KEY}" ]] || die "生成 Reality X25519 密钥失败"
    REALITY_SHORT_ID=${REALITY_SHORT_ID:-$(openssl rand -hex 8)}
    # 与 profiles/reality.sh 同一约束：shortId 是字节串的十六进制写法，
    # 奇数位/非十六进制会让 Xray 拒绝启动。
    [[ "${REALITY_SHORT_ID}" =~ ^([0-9a-fA-F]{2}){1,8}$ ]] \
        || die "Reality Short ID 无效：只允许偶数位十六进制（2–16 位，即 1–8 对）"
    REALITY_PUBLIC_KEY=$("${XRAY_BIN}" x25519 -i "${REALITY_PRIVATE_KEY}" \
        | awk '/Password|PublicKey/ {print $NF; exit}')
    [[ -n "${REALITY_PUBLIC_KEY}" ]] || die "生成 Reality X25519 密钥失败"
    # 密钥生成后立即落盘：中断续装必须复用同一 Reality 身份，不能等最终 save_state。
    persist_install_identity \
        || die "无法落盘安装身份；在写出包含 Reality 密钥的运行配置前停止安装"
    validate_reality_target_runtime
}

cdn_direct_inbounds_json() {
    local clients sockopt
    cdn_require_direct_state
    clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" \
        '[{id:$id,email:$email,flow:"xtls-rprx-vision"}]')
    sockopt=$(xray_inbound_sockopt_json)
    jq -cn --argjson clients "${clients}" --argjson port "${REALITY_PORT}" \
        --arg target "${REALITY_TARGET}" --arg sni "${REALITY_TARGET%:*}" \
        --arg private_key "${REALITY_PRIVATE_KEY}" --arg short_id "${REALITY_SHORT_ID}" \
        --argjson sockopt "${sockopt}" '
        [{
          tag: "vless-reality-in",
          listen: "0.0.0.0",
          port: $port,
          protocol: "vless",
          settings: {clients: $clients, decryption: "none"},
          streamSettings: {
            network: "raw",
            security: "reality",
            sockopt: $sockopt,
            realitySettings: {
              show: false, target: $target, xver: 0,
              serverNames: [$sni], privateKey: $private_key, shortIds: [$short_id]
            }
          },
          sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
        }]'
}

cdn_direct_node_names() {
    jq -cn --arg name "${DIRECT_NODE_NAME:-}" '[$name]'
}

cdn_validate_direct_runtime() {
    cdn_require_direct_state
    validate_reality_port_listening \
        || die "Reality 端口 ${REALITY_PORT} 未监听，直连入口不可用"
    validate_reality_target_runtime
}

# --- Direct rendering ---------------------------------------------------------

reality_mlkem_required() {
    local version major minor patch
    version=$(xray_installed_version)
    version=${version//[[:space:]]/}
    version=${version#v}
    IFS=. read -r major minor patch _ <<<"${version}"
    if [[ ! "${major}" =~ ^[0-9]+$ || ! "${minor}" =~ ^[0-9]+$ || ! "${patch}" =~ ^[0-9]+$ ]]; then
        warn "无法确定 Xray 核心版本，Reality 订阅未下发 support-x25519mlkem768；执行 sudo easy_all update-core 可恢复" >&2
        return 1
    fi
    ((10#${major} * 10000 + 10#${minor} * 100 + 10#${patch} >= 260908))
}

build_reality_link() {
    local mlkem_param=""
    cdn_require_direct_state
    reality_mlkem_required || mlkem_param="&mlkem=0"
    printf 'vless://%s@%s:%s?encryption=none&security=reality&type=tcp&sni=%s&fp=chrome&pbk=%s&sid=%s&flow=xtls-rprx-vision&packetEncoding=xudp%s#%s' \
        "${VLESS_UUID}" "${DIRECT_DOMAIN}" "${REALITY_PORT}" "${REALITY_TARGET%:*}" \
        "$(uri_encode "${REALITY_PUBLIC_KEY}")" "$(uri_encode "${REALITY_SHORT_ID}")" \
        "${mlkem_param}" "$(uri_encode "${DIRECT_NODE_NAME}")"
}

build_mihomo_reality_node() {
    local mlkem=""
    cdn_require_direct_state
    reality_mlkem_required && mlkem=$'      support-x25519mlkem768: true\n'
    jq -nr --arg name "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" \
        --argjson port "${REALITY_PORT}" \
        --arg uuid "${VLESS_UUID}" --arg sni "${REALITY_TARGET%:*}" \
        --arg pbk "${REALITY_PUBLIC_KEY}" --arg sid "${REALITY_SHORT_ID}" --arg mlkem "${mlkem}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: \($port)\n" +
        "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \($sni|@json)\n" +
        "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
        $mlkem +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n    ip-version: ipv4\n"'
}

# Reality target 更新：Profile 负责改 target，本机事务与重新发布复用核心实现。
# 受限安全恢复（§7.3）与强校验订阅都在改动 target 之前，失败时按订阅事务回滚旧配置。
update_reality_target() {
    local target=${1:-} current
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_traffic_admission
    cdn_require_valid_subscription
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
    validate_reality_target_runtime
    snapshot_subscription_update
    if ! cdn_traffic_protection_checkpoint; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
        die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止更新 Reality 目标，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    configure_tcp_acceleration
    configure_ipv4_only
    xhttp_configure_ufw
    write_xray_config
    install_xray_service
    # 最后一次采样紧贴 restart：准备阶段旧进程仍在计数。
    if ! cdn_traffic_protection_checkpoint; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
        die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止更新 Reality 目标，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    # enable --now 对已运行 unit 是空操作：不改 target 不重启，新 SNI 不会生效。
    systemctl restart "${XRAY_SERVICE}" || die "重启 Xray 服务失败"
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
    cloudfront_write_subscriptions
    validate_subscription_runtime
    save_state
    commit_subscription_update
    success "Reality 目标已更新：${current} → ${REALITY_TARGET}；请刷新客户端订阅"
}
