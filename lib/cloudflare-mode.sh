#!/usr/bin/env bash

# Cloudflare orange-cloud core for mode 3 (single proxied domain serving both the
# VLESS WebSocket node and the Token-protected subscription).
#
# Profile contract provided before this file is sourced:
#   CDN_PROFILE_KEY          install marker / profile key (cloudflare / combined-cloudflare)
#   CDN_EXPECTED_PROTOCOL    state PROTOCOL owned by the profile
#   CDN_MODE_LABEL           user-facing mode name
#   CDN_ENTRY_SUMMARY        entry summary used by the install success message
#   CDN_INSTALL_PORTS        TCP ports that must be free before a fresh install
#   CDN_STATE_VARIABLES      state.env fields persisted by the profile
#   CDN_RECORD_COMMENT       Cloudflare DNS ownership comment of this profile
# plus the hooks (empty results instead of guessing):
#   collect_install_inputs      collect this profile's inputs (calls the shared input collector)
#   cdn_prepare_direct_runtime  no-op: mode 3 has no direct entry
#   cdn_validate_direct_runtime no-op: mode 3 has no direct entry
#
# Cloudflare API/DNS/Origin CA/origin-firewall helpers come from lib/cf-dns.sh.
# 这一层只承载橙云单域名链路（一个域名同时提供 WebSocket 节点与订阅），没有优选 IP、
# 没有测速/兜底分组、没有 Globalping 与 CloudFront/AWS/流量熔断语义。

# 公网验收重试次数/间隔；测试可经 *_OVERRIDE 缩短，生产默认不变。
readonly CDN_PUBLIC_ACCEPT_ATTEMPTS="${CDN_PUBLIC_ACCEPT_ATTEMPTS_OVERRIDE:-6}"
readonly CDN_PUBLIC_ACCEPT_SECONDS="${CDN_PUBLIC_ACCEPT_SECONDS_OVERRIDE:-10}"
# 模式 3 的 DNS 归属注释：创建与删除必须使用同一常量（design §9）。
readonly CDN_RECORD_COMMENT="easy_all cloudflare"
CLOUDFLARE_ORIGIN_IPS_FILE="${STATE_DIR}/cloudflare-origin-ipv4-443.txt"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
readonly CF_CA_ROOT_FILE="${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
CLOUDFLARE_UFW_COMMENT="easy_all-cf-origin-443"
CLOUDFLARE_UFW_PORT=443

: "${CLOUDFLARE_API_BASE:=https://api.cloudflare.com/client/v4}"

# shellcheck source=lib/cf-dns.sh
source "${RUNTIME_LIB_DIR}/cf-dns.sh"

CDN_SUBSCRIPTION_CORRUPT=0

# --- Profile adapters ---------------------------------------------------------

# --- State contract -----------------------------------------------------------

# 运行时派生字段（不落盘）：load_state 与首装输入都必须派生，首装不经过 load_state。
# 单域名链路里 CF_NODE_DOMAIN 同时是 WebSocket Host、订阅域名与 Origin CA 的唯一名字。

# 云端已签发新证书但后续本机/公网验收失败：证书按设计保留，必须在退出前点名，
# 否则下一次卸载只知道旧 ID，长期有效的孤儿证书无人知晓。
# --- Profile adapters ---------------------------------------------------------

# 运行时派生字段（不落盘）：模式 3 的订阅域名就是橙云节点域名。
# 本机探活必须信任 Cloudflare Origin CA 根：回源证书由它签发。
runtime_probe_ca_file() {
    printf '%s\n' "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
}

cdn_derive_runtime_fields() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || return 1
    BACKEND=sing-box
    SUBSCRIPTION_MODE=deploy
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
}

profile_report_retained_resources() {
    local created=${CLOUDFLARE_CREATED_ORIGIN_CERT_ID:-} node=${CF_NODE_DOMAIN:-未知}
    [[ -n "${created}" ]] || return 0
    warn "本次已签发并保留 Cloudflare Origin CA 证书（ID ${created}，域名 ${node}）；云端按设计不回滚，本机正在恢复旧配置"
    warn "如需清理，只在 Cloudflare 控制台按该证书 ID 单独删除；不要用 purge-cloudflare 按域名清理，那会连当前实例仍在使用的 DNS 与旧证书一起删除"
}

# 凭据只允许存在于内存：runtime-core 的 EXIT 钩子按该函数名回收 API 请求头。
clear_profile_credentials() {
    unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" "${RUNTIME_TMP}/cloudflare-api-payload" \
        2>/dev/null || true
}

# --- Subscription configuration ----------------------------------------------

# --- Install inputs -----------------------------------------------------------

cdn_validate_install_domains() {
    local domain
    validate_domain "${CF_NODE_DOMAIN}" || die "节点域名无效：${CF_NODE_DOMAIN}"
    [[ "${CF_NODE_DOMAIN}" == *".${CF_ZONE}" ]] \
        || die "节点域名必须属于 ${CF_ZONE}：${CF_NODE_DOMAIN}"
    # 默认边缘证书只覆盖 Zone 的一级子域名；多级名字会装到最后才失败。
    [[ "${CF_NODE_DOMAIN%.${CF_ZONE}}" != *.* ]] \
        || die "节点域名必须是 ${CF_ZONE} 的一级子域名（如 cf.${CF_ZONE}）：${CF_NODE_DOMAIN}"
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        validate_domain "${domain}" || die "直连域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] \
            || die "直连域名必须属于 ${CF_ZONE}：${domain}"
        [[ "${domain}" != "${CF_NODE_DOMAIN}" ]] \
            || die "直连域名不得等于 CDN 节点域名：${domain}"
    done < <(cdn_direct_domains)
}

collect_cloudflare_install_inputs() {
    # 续装时续用从 install-identity.json 恢复的值做提示默认值，不得先生成新值再覆盖。
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' "${CF_ZONE:-}")")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"

    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'CDN 节点域名（橙云代理，同时提供 WebSocket 节点与订阅）' "${CF_NODE_DOMAIN:-cf.${CF_ZONE}}")")
    cdn_validate_install_domains
    # 首装不经过 load_state：订阅渲染前必须在输入校验处派生运行时字段。
    cdn_derive_runtime_fields || die "运行时字段派生失败：缺少节点域名"

    cloudflare_collect_api_token 'Cloudflare API Token（Zone 只读 + DNS 编辑 + SSL/证书 编辑权限）'

    VLESS_PATH=$(normalize_vless_path "${VLESS_PATH:-}")
    validate_vless_path "${VLESS_PATH}" || die "VLESS 路径无效：${VLESS_PATH}"

    CF_NODE_PREFIX=$(prompt_value 'CDN 节点名（完整单节点名）' "${CF_NODE_PREFIX:-🇺🇸CF}")
    validate_node_name "${CF_NODE_PREFIX}" || die "节点名无效（1-64 字符，不能含控制字符）"
    cdn_node_name_reserved "${CF_NODE_PREFIX}" && die "节点名不能使用保留组名：${CF_NODE_PREFIX}"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")")

    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"

    SUBSCRIPTION_CONFIG=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}") \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes"
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" \
        || die "订阅配置无效：节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    cdn_validate_install_owner_token

    if [[ -z "${VPS_PUBLIC_IPV4:-}" ]]; then
        VPS_PUBLIC_IPV4=$(detect_public_ipv4) || die "无法自动探测本机公网 IPv4"
    fi
}

# --- Cloudflare token and DNS -------------------------------------------------

# 收集、格式校验与 0600 持久化都在 lib/cf-dns.sh（四模式共用）。

cdn_record_belongs_to_easy_all() {
    [[ "${1:-}" == easy_all* ]]
}

cdn_ensure_zone_id() {
    cloudflare_collect_api_token
    if [[ -z "${CLOUDFLARE_ZONE_ID:-}" ]]; then
        CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}") \
            || die "Cloudflare 中没有 active Zone：${CF_ZONE}"
    fi
}

# 橙云节点域名一条 A 记录同时承载 WebSocket 节点与订阅。
cdn_ensure_dns() {
    local domain
    cdn_ensure_zone_id
    info "配置 CDN 节点解析（橙云代理）：${CF_NODE_DOMAIN} -> ${VPS_PUBLIC_IPV4}"
    dns_ensure_record "${CF_NODE_DOMAIN}" A "${VPS_PUBLIC_IPV4}" true
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        info "配置直连 A 记录（灰云直连）：${domain} -> ${VPS_PUBLIC_IPV4}"
        dns_ensure_record "${domain}" A "${VPS_PUBLIC_IPV4}" false
    done < <(cdn_direct_domains)
}

# --- Cloudflare Origin CA -----------------------------------------------------

cloudflare_origin_certificate_hosts() {
    jq -cn --arg host "${CLOUDFLARE_ORIGIN_DOMAIN}" '[$host]'
}

# 复用前必须验证证书链属于 Cloudflare Origin CA：仅比对有效期/SAN/公私钥会把
# 其他 CA 签发的同名证书当成可复用，随后只能在本机严格 TLS 验收处才失败。
cloudflare_origin_certificate_is_reusable() {
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" ]] \
        || return 1
    cloudflare_origin_certificate_is_current || return 1
    cloudflare_ensure_origin_ca_root
    openssl verify -CAfile "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" "${CERT_FILE}" >/dev/null 2>&1
}

cdn_issue_certificate() {
    local force=${1:-0}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}
    cloudflare_issue_origin_certificate "${force}"
}

# --- Xray ---------------------------------------------------------------------

# --- Subscription rendering ---------------------------------------------------

# 单节点链路没有测速组或兜底组；模板占位必须成功输出空内容。

# --- 运行配置与订阅渲染 -------------------------------------------------------

# 模式 3 没有 985GB 熔断：Caddy 代理路径始终可用，订阅始终可用。
write_runtime_config() {
    runtime_write_config 0 1
}

# 订阅渲染用 Phase 1 builder：节点与订阅同域，无需源站密钥。
build_node_links() {
    local extra
    build_vless_ws_link
    printf '\n'
    extra=$(aggregation_node_links)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
    return 0
}

build_mihomo_nodes() {
    local extra
    build_mihomo_ws_node
    printf '\n'
    extra=$(aggregation_mihomo_nodes)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
    return 0
}

build_mihomo_proxy_names() {
    local extra
    aggregation_node_names >/dev/null 2>&1 || true
    extra=$(aggregation_node_names) || extra='[]'
    jq -nr --argjson names "$(cdn_local_node_names)" --argjson extra "${extra}" \
        '($names + $extra)[] | "        - \(.|@json)"'
}

# 模式 3 没有额外 CDN 分组；模板占位必须成功输出空内容。
build_mihomo_proxy_groups() {
    printf ''
    return 0
}

cloudflare_template_snapshot_file() {
    printf '%s/mihomo-template.yaml' "${STATE_DIR}"
}

# 共享订阅事务按该路径把模板快照与 state、六种产物一起备份与回滚。
RT_TEMPLATE_SNAPSHOT_PATH=$(cloudflare_template_snapshot_file)

cloudflare_prepare_subscription_template() {
    local snapshot
    snapshot=$(cloudflare_template_snapshot_file)
    if [[ -n "${MIHOMO_TEMPLATE_SOURCE:-}" ]]; then
        MIHOMO_TEMPLATE_FILE=""
        prepare_mihomo_template
        return 0
    fi
    if [[ -s "${snapshot}" ]]; then
        MIHOMO_TEMPLATE_FILE=${snapshot}
        MIHOMO_TEMPLATE_TRUSTED=1
        prepare_mihomo_template
        return 0
    fi
    [[ "${MIHOMO_TEMPLATE_SNAPSHOT:-0}" != "1" ]] \
        || warn "Mihomo 模板快照缺失；已回退内置默认模板，自定义模板未保留"
    MIHOMO_TEMPLATE_FILE=""
    prepare_mihomo_template
}

cloudflare_persist_subscription_template() {
    local snapshot temp
    [[ -n "${MIHOMO_TEMPLATE_FILE:-}" && -s "${MIHOMO_TEMPLATE_FILE}" ]] \
        || die "缺少可持久化的 Mihomo 模板"
    install -d -m 0700 "${STATE_DIR}"
    snapshot=$(cloudflare_template_snapshot_file)
    if [[ "${MIHOMO_TEMPLATE_FILE}" != "${snapshot}" ]]; then
        temp=$(mktemp "${snapshot}.XXXXXX") || die "创建 Mihomo 模板快照暂存文件失败"
        cleanup_files+=("${temp}")
        install -m 0600 "${MIHOMO_TEMPLATE_FILE}" "${temp}" \
            || die "复制 Mihomo 模板快照失败"
        mv -f -- "${temp}" "${snapshot}" || die "原子替换 Mihomo 模板快照失败"
    fi
    MIHOMO_TEMPLATE_FILE=${snapshot}
    MIHOMO_TEMPLATE_SNAPSHOT=1
}

cloudflare_write_subscriptions() {
    cloudflare_prepare_subscription_template
    write_subscriptions
    cloudflare_persist_subscription_template
}

# 与发布路径完全一致的渲染，供订阅就绪判定使用。
cloudflare_render_subscription_files() {
    cloudflare_prepare_subscription_template
    render_subscription_files "$1"
}

refresh_runtime_subscription() {
    cloudflare_write_subscriptions
    save_state
}

# --- Public acceptance --------------------------------------------------------

# 本机验收（--resolve 127.0.0.1）不能证明橙云链路：DNS 指向、边缘证书与
# Full (strict) 回源都可能在这里才暴露。公网探测走真实域名 + 系统 CA，禁止 -k。
cdn_public_curl() {
    curl -sS --proto '=https' --noproxy '*' --connect-timeout 5 --max-time 30 "$@"
}

cdn_wait_for_node_dns() {
    local attempt answers
    for attempt in {1..30}; do
        answers=$(dig +short A "${CF_NODE_DOMAIN}" 2>/dev/null || true)
        [[ -n "${answers}" ]] && return 0
        sleep 2
    done
    die "Cloudflare 节点域名尚未解析：${CF_NODE_DOMAIN}；请检查橙云 A 记录后重试"
}

cdn_public_health_ok() {
    local body
    body=$(cdn_public_curl "https://${CF_NODE_DOMAIN}/easy_all-health") || return 1
    [[ "${body}" == "easy_all ok" ]]
}

cdn_public_subscription_ok() {
    local token body decoded
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS:-[]}") || return 1
    [[ -n "${token}" && "${token}" != "null" ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        "https://${CF_NODE_DOMAIN}/subscribe") || return 1
    decoded=$(printf '%s' "${body}" | openssl base64 -d -A 2>/dev/null) || return 1
    [[ "${decoded}" == *"type=ws"* ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' \
        "https://${CF_NODE_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"network: ws"* ]]
}

cdn_public_token_rejection_ok() {
    local status
    status=$(cdn_public_curl -o /dev/null -w '%{http_code}' \
        --get --data-urlencode 'token=invalid' \
        "https://${CF_NODE_DOMAIN}/subscribe") || return 1
    [[ "${status}" == "403" ]]
}

cdn_validate_public_runtime() {
    local attempt
    cdn_wait_for_node_dns
    for ((attempt = 1; attempt <= CDN_PUBLIC_ACCEPT_ATTEMPTS; attempt++)); do
        if cdn_public_health_ok \
            && cdn_public_subscription_ok \
            && cdn_public_token_rejection_ok; then
            return 0
        fi
        ((attempt == CDN_PUBLIC_ACCEPT_ATTEMPTS)) || sleep "${CDN_PUBLIC_ACCEPT_SECONDS}"
    done
    die "Cloudflare 公网验收失败（已重试 ${CDN_PUBLIC_ACCEPT_ATTEMPTS} 次）：请确认 ${CF_NODE_DOMAIN} 已开启橙云代理、SSL/TLS 为 Full (strict) 且边缘证书可用；修复后执行 sudo easy_all apply-cloud"
}

# --- Commands -----------------------------------------------------------------

# 云端同步阶段：任何 Cloudflare 管理调用前显式收集并校验凭据。

# 卸载与安装失败回滚都只回收业务端口：保留 UFW 启用状态、默认策略与 SSH 放行。

# --- Commands -----------------------------------------------------------------

show_node() {
    local extra
    collect_installed_state
    [[ "${CDN_SUBSCRIPTION_CORRUPT}" == "0" ]] \
        || warn "订阅配置损坏；节点列表可能不完整，请执行 sudo easy_all edit-sub"
    printf '\n协议: %s\n' "$(runtime_protocol_label)"
    printf '节点链接:\n'
    build_node_links
    printf '\nMihomo / Clash 节点配置:\n'
    build_mihomo_nodes
    printf '\n聚合节点（订阅内联）:\n'
    extra=$(aggregation_node_links 2>/dev/null || true)
    if [[ -n "${extra}" ]]; then
        printf '%s\n' "${extra}"
    else
        printf '无\n'
    fi
    printf '\n'
}

show_status() {
    local cert_enddate=""
    require_root
    collect_installed_state
    printf '模式: %s\n' "${CDN_MODE_LABEL}"
    printf '协议: %s\n' "$(runtime_protocol_label)"
    show_tcp_acceleration_status
    printf '节点/订阅域名: %s（橙云代理，TCP 443 仅 Cloudflare 回源段）\n' "${CF_NODE_DOMAIN}"
    printf '本机回环 CDN 入站: 127.0.0.1:%s\n' "$(runtime_cdn_loopback_port)"
    printf 'Cloudflare Origin CA: %s（到期 %s）\n' \
        "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}"
    if [[ -s "${CERT_FILE}" ]]; then
        cert_enddate=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        printf '回源证书到期: %s\n' "${cert_enddate:-未知}"
    else
        printf '回源证书: 缺失；请执行 sudo easy_all renew-cert\n'
    fi
    printf 'sing-box: '
    systemctl is-active --quiet "${SINGBOX_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'Caddy: '
    systemctl is-active --quiet "${CADDY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'UFW 443（Cloudflare 回源）: '
    if command -v ufw >/dev/null 2>&1 \
        && ufw_tcp_port_is_allowed 443 2>/dev/null; then
        printf '已放行\n'
    else
        printf '未放行或仅限指定来源\n'
    fi
    if [[ "${CDN_SUBSCRIPTION_CORRUPT}" != "0" ]]; then
        printf '订阅: 配置损坏，当前不可用；请执行 sudo easy_all edit-sub\n'
    fi
}

apply_easy_all() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_valid_subscription
    snapshot_subscription_update
    configure_tcp_acceleration
    configure_ipv4_only
    configure_runtime_ufw
    write_runtime_config
    runtime_apply_runtime_services
    validate_protocol_runtime
    cloudflare_write_subscriptions
    validate_subscription_runtime
    save_state
    register_easy_all_command
    commit_subscription_update
    success "本机配置与订阅已应用；未修改 DNS 与云端资源"
}

# 云端同步阶段：任何 Cloudflare 管理调用前显式收集并校验凭据。
apply_cloud_phase() {
    cloudflare_collect_api_token
    persist_cloudflare_token
    # 只读查询 Zone ID 必须先于 strict 校验（design §9）：创建任何资源前完成。
    cdn_ensure_zone_id
    cloudflare_ensure_zone_ssl_strict
    cdn_ensure_dns
    cdn_issue_certificate
}

apply_cloud_resources() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_valid_subscription
    snapshot_subscription_update
    configure_tcp_acceleration
    configure_ipv4_only
    configure_runtime_ufw
    apply_cloud_phase
    write_runtime_config
    runtime_apply_runtime_services
    validate_protocol_runtime
    cloudflare_write_subscriptions
    validate_subscription_runtime
    # 本机子流程完成后才能证明公网链路；失败时云端资源保留，可重试 apply-cloud。
    cdn_validate_public_runtime
    runtime_served_certificate_matches_disk \
        || die "本机 TLS 尚未使用新证书；已保留旧 Origin CA，请修复后重试 apply-cloud"
    save_state
    register_easy_all_command
    # 吊销不可逆，必须先关闭回滚再吊销，避免后续中断时恢复已吊销的旧证书。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    clear_profile_credentials
    success "本机配置、订阅与 Cloudflare 云端资源已同步"
}

update_subscription() {
    (($# == 0)) || die "edit-sub 不接受额外参数"
    local raw_config="" caller_config=${SUBSCRIPTION_CONFIG:-}
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if [[ -t 0 ]]; then
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME}")")
        raw_config=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}")
    else
        raw_config=${caller_config:-${SUBSCRIPTION_CONFIG:-}}
    fi
    cdn_apply_subscription_config "${raw_config}" \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes；节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    # 新配置已强校验：旧订阅的损坏标记必须清零，否则后续写配置仍判订阅不可用。
    CDN_SUBSCRIPTION_CORRUPT=0
    snapshot_subscription_update
    cloudflare_write_subscriptions
    write_runtime_config
    runtime_reload_caddy
    validate_subscription_runtime
    save_state
    commit_subscription_update
    show_subscription
    success "订阅已刷新"
}

renew_certificate() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_valid_subscription
    cloudflare_collect_api_token
    snapshot_subscription_update
    cdn_issue_certificate 1
    write_runtime_config
    runtime_apply_runtime_services 1
    # 新证书必须真的能完成本机 TLS/SNI 握手才允许吊销旧证书（吊销不可逆）。
    validate_protocol_runtime
    validate_subscription_runtime
    runtime_served_certificate_matches_disk \
        || die "本机 TLS 尚未使用新证书；已保留旧 Origin CA，请修复后重试 renew-cert"
    cdn_validate_public_runtime \
        || die "公网链路尚未使用新 Origin CA 证书；已保留旧证书，请修复后重试 renew-cert"
    save_state
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    clear_profile_credentials
    success "Cloudflare Origin CA 回源证书已更新"
}

cdn_local_uninstall_common() {
    stop_maintenance_services || true
    stop_services
    cloudflare_remove_origin_firewall_rules || true
    restore_platform_security_state || {
        warn "SSH 配置恢复失败；请通过服务商 Console 检查"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    if ! remove_daily_reboot_schedule; then
        warn "卸载未完成：移除 easy_all 定时重启任务失败，本机状态与命令已保留；修正 root crontab 后重试 uninstall"
        return 1
    fi
    rm -f -- "${SINGBOX_SERVICE_FILE}" "${CADDY_SERVICE_FILE}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${SUBSCRIPTION_DIR}" "$(dirname -- "${SUBSCRIPTION_DIR}")" \
        "${COMMAND_INSTALL_DIR}" "$(dirname -- "${SINGBOX_BIN}")" "$(dirname -- "${CADDY_BIN}")"
}

uninstall_all() {
    local mode=${1:-} answer
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        if [[ "${mode}" == "--purge-cloud" ]]; then
            read_bilingual '删除本机内容以及 easy_all 创建的 Cloudflare DNS 与 Origin CA？[y/N]:' answer
        else
            read_bilingual '删除 easy_all 本机服务、状态和证书（保留云端资源）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services || true
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    cdn_print_cloud_inventory
    if [[ "${mode}" == "--purge-cloud" ]]; then
        if (cdn_purge_cloud_resources); then
            :
        else
            warn "云端资源清理未完成；本机卸载继续，请按上方清单手动处置"
        fi
    else
        warn "Cloudflare DNS 与 Origin CA 已保留；本机状态删除后无法再用 easy_all 清理"
    fi
    cdn_local_uninstall_common || return 1
    success "easy_all 本机内容已卸载"
}

cleanup_partial_install() {
    local failed=0 path
    cleanup_partial_install_local || return 1
    remove_daily_reboot_schedule || true
    for path in "${SINGBOX_SERVICE_FILE}" "${CADDY_SERVICE_FILE}" "${COMMAND_PATH}" \
        "${SUBSCRIPTION_DIR}" "$(dirname -- "${SUBSCRIPTION_DIR}")" \
        "${COMMAND_INSTALL_DIR}" "$(dirname -- "${SINGBOX_BIN}")" "$(dirname -- "${CADDY_BIN}")"; do
        [[ -n "${path}" ]] || continue
        rm -rf -- "${path}" 2>/dev/null || { warn "删除残留失败：${path}"; failed=1; }
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ((failed == 1)); then
        warn "业务残留未完全删除；已保留安装进度标记与安装前快照，修正权限/挂载后重试 sudo easy_all cleanup-partial"
        return 1
    fi
    cleanup_partial_install_files "${STATE_DIR}"
}

rollback_fresh_install() {
    warn "${CDN_MODE_LABEL} 模式首次安装未完成，正在回滚本机服务、UFW 与 crontab 配置（保留前置初始化：SWAP、系统依赖与 TCP/Skyline 加速）"
    if ! cleanup_partial_install; then
        cdn_print_cloud_inventory
        warn "本机回滚未完成；已保留安装进度标记与安装前快照（${BACKUP_DIR}）。修正权限/挂载后重试 sudo easy_all cleanup-partial，云端资源仍按设计保留"
        return 1
    fi
    cdn_print_cloud_inventory
    warn "本次已创建的 Cloudflare DNS/Origin CA 按设计保留；easy_all 命令已随回滚移除，确认不再使用后可执行 bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) purge-cloudflare --domain <域名>，或直接在 Cloudflare 控制台清理"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    require_root
    acquire_runtime_write_lock
    require_systemd
    check_platform
    [[ ! -f "${STATE_FILE}" ]] || die "检测到已有 easy_all 安装；一台 VPS 只允许一种模式"
    report_host_init_state
    ensure_swap
    install_failure_begin "${CDN_PROFILE_KEY}"
    # 443 只对 Cloudflare 回源段开放，端口预检同时覆盖回环 CDN 入站。
    prepare_fresh_install "$(runtime_cloudflare_only_port)" "$(runtime_cdn_loopback_port)"
    install_progress_begin "${CDN_PROFILE_KEY}" cloudflare
    snapshot_fresh_install

    install_progress_stage packages
    install_packages
    install_progress_stage tcp
    choose_tcp_acceleration
    configure_tcp_acceleration
    # 续装必须复用身份里保存的重启选择，不能重新提示成默认值。
    if [[ "${INSTALL_RESUME:-0}" == "1" && -n "${SCHEDULED_REBOOT_ENABLED:-}" ]]; then
        refresh_saved_daily_reboot_schedule
    else
        configure_daily_reboot
    fi
    configure_ipv4_only
    install_progress_stage inputs
    collect_install_inputs
    persist_install_identity || die "无法落盘安装身份；在创建云端资源前停止安装"
    install_progress_stage core
    download_singbox
    download_caddy
    install_progress_stage services
    configure_runtime_ufw
    cloudflare_collect_api_token
    persist_cloudflare_token
    cdn_ensure_zone_id
    cloudflare_ensure_zone_ssl_strict
    cdn_ensure_dns
    cdn_issue_certificate
    # 证书已签发：立即落盘 ID/到期时间，续装可直接复用而不是重复 POST /certificates。
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    write_runtime_config
    # 首装先注册 easy_all：sing-box 的 ExecStartPre 依赖 /usr/local/bin/easy_all。
    register_easy_all_command
    runtime_apply_runtime_services
    validate_protocol_runtime
    install_progress_stage subscription
    cloudflare_write_subscriptions
    validate_subscription_runtime
    cdn_validate_public_runtime
    install_progress_stage state
    save_state
    register_easy_all_command
    # 状态已落盘：uninstall 可用，后续失败不再回滚本机。
    INSTALL_ROLLBACK_ON_EXIT=0
    install_progress_clear
    clear_profile_credentials
    INSTALL_FAILURE_ARMED=0
    show_subscription
    success "easy_all ${CDN_MODE_LABEL} 安装完成（${CDN_ENTRY_SUMMARY}）"
    show_tcp_acceleration_status
    prompt_kernel_reboot
}

cdn_print_cloud_inventory() {
    local domain
    printf '云端资源清单（默认保留，需要时手动处置）：\n' >&2
    printf '  节点 A 记录（橙云）: %s -> %s\n' "${CF_NODE_DOMAIN:-未知}" "${VPS_PUBLIC_IPV4:-未知}" >&2
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        printf '  直连 A 记录（灰云）: %s -> %s\n' "${domain}" "${VPS_PUBLIC_IPV4:-未知}" >&2
    done < <(cdn_direct_domains 2>/dev/null || true)
    printf '  Origin CA 证书: %s（到期 %s）\n' "${CLOUDFLARE_ORIGIN_CERT_ID:-未知}" \
        "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-未知}" >&2
}

# 只删本链路创建的 A 记录：类型、注释与目标三者同时匹配才删。
cdn_purge_cloudflare_dns() {
    local host proxied spec records count id comment current current_proxied failed=0 seen="|"
    local -a pairs=()
    pairs+=("${CF_NODE_DOMAIN}|true")
    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        pairs+=("${host}|false")
    done < <(cdn_direct_domains)
    for spec in "${pairs[@]}"; do
        host=${spec%%|*}
        proxied=${spec#*|}
        [[ -n "${host}" && "${seen}" != *"|${host}|"* ]] || continue
        seen="${seen}${host}|"
        records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${host}") \
            || { warn "查询 Cloudflare 记录失败：${host}"; failed=1; continue; }
        count=$(jq 'length' <<<"${records}")
        ((count == 0)) && continue
        if ((count > 1)); then
            warn "Cloudflare 存在 ${count} 条同名 A 记录，无法判断归属：${host}"
            failed=1
            continue
        fi
        id=$(jq -r '.[0].id' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        current=$(jq -r '.[0].content // empty' <<<"${records}")
        current_proxied=$(jq -r '.[0] | if has("proxied") then (.proxied | tostring) else "" end' <<<"${records}")
        if [[ "${comment}" != "${CDN_RECORD_COMMENT}" ]]; then
            warn "Cloudflare ${host} 的 A 记录不是本链路创建的（注释：${comment:-空}）；保留"
            continue
        fi
        # 注释已在本工具安装时被改写：只有接管日志才能证明它原本属于第三方。
        if dns_record_taken_over "${host}"; then
            warn "Cloudflare ${host} 的 A 记录来自强制接管（原注释/指向见 $(dns_takeover_log_file)）；保留，如需删除请手工处理"
            continue
        fi
        if [[ "${current}" != "${VPS_PUBLIC_IPV4}" ]]; then
            warn "Cloudflare ${host} 的 A 记录目标已变化（${current:-空}）；保留"
            continue
        fi
        # 代理状态也是归属的一部分：橙云被改成灰云（或反之）说明记录已被人改动，不猜删除。
        if [[ "${current_proxied}" != "${proxied}" ]]; then
            warn "Cloudflare ${host} 的 A 记录代理状态已变化（${current_proxied:-空} ≠ ${proxied}）；保留"
            continue
        fi
        (cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null) \
            || { warn "删除 Cloudflare 记录失败：${host}"; failed=1; }
    done
    return "${failed}"
}

cdn_purge_origin_certificate() {
    [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]] || return 0
    # cloudflare_api_request 失败会退出所在进程：放进子 shell 以免中断卸载。
    (cloudflare_api_request DELETE "/certificates/${CLOUDFLARE_ORIGIN_CERT_ID}" >/dev/null) \
        || { warn "吊销 Cloudflare Origin CA 证书失败：${CLOUDFLARE_ORIGIN_CERT_ID}；请到控制台手动删除"
             return 1; }
}

cdn_purge_cloud_resources() {
    local purge_failed=0
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]] || { warn "状态缺少 Zone ID，跳过云端清理"; return 1; }
    cloudflare_collect_api_token
    # DNS 失败不阻止吊销证书：证书生命周期很长，孤儿证书比孤儿记录更难清理。
    (cdn_purge_cloudflare_dns) || { warn "Cloudflare 记录清理未完成"; purge_failed=1; }
    (cdn_purge_origin_certificate) || { warn "Cloudflare Origin CA 证书吊销未完成"; purge_failed=1; }
    clear_profile_credentials
    return "${purge_failed}"
}

# 新协议但强制字段缺失/来自未完成实现：只清本机，云端一律保留。
