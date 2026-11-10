#!/usr/bin/env bash

# Mode 1: AnyTLS 直连入口（TCP 443）+ 可选订阅站点（Caddy 8443，仅 Cloudflare 回源段）。
#
# Profile 契约（由 profiles/anytls.sh 在本文件之前提供）：
#   CDN_PROFILE_KEY / CDN_EXPECTED_PROTOCOL / CDN_MODE_LABEL / CDN_ENTRY_SUMMARY /
#   CDN_INSTALL_PORTS
# 与 CloudFront 模式相同的命令契约（install/apply/apply-cloud/edit-sub/renew-cert/
# show/status/uninstall/cleanup-partial），但没有任何 AWS 资源与 985GB 熔断。
#
# 订阅是可选入口：SUBSCRIPTION_MODE=deploy 建立 SUBSCRIPTION_DOMAIN 橙云 A 记录 +
# 精确 http.host 的 Origin Rule（回源 8443）+ LE 证书；SUBSCRIPTION_MODE=link 只输出节点。

# 公网验收重试次数/间隔；测试可经 *_OVERRIDE 缩短，生产默认不变。
readonly CDN_PUBLIC_ACCEPT_ATTEMPTS="${CDN_PUBLIC_ACCEPT_ATTEMPTS_OVERRIDE:-6}"
readonly CDN_PUBLIC_ACCEPT_SECONDS="${CDN_PUBLIC_ACCEPT_SECONDS_OVERRIDE:-10}"

# --- 状态派生与订阅 -----------------------------------------------------------

cdn_derive_runtime_fields() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || return 1
    BACKEND=sing-box
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-deploy}") || return 1
    if subscription_enabled; then
        [[ -n "${SUBSCRIPTION_DOMAIN:-}" ]] || return 1
    else
        SUBSCRIPTION_DOMAIN=""
    fi
}

# 凭据只允许存在于内存：runtime-core 的 EXIT 钩子按该函数名回收 API 请求头。
# 与 cloudflare-mode.sh 同义：状态回滚失败保留 RUNTIME_TMP 时，Bearer Token 不留在目录里。
clear_profile_credentials() {
    unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" "${RUNTIME_TMP}/cloudflare-api-payload" \
        2>/dev/null || true
}

# 订阅 Token 与聚合节点在 link 模式下同样用于节点输出，但不需要 Caddy 就绪。
cdn_config_ready() {
    cdn_validate_local_node_names || return 1
    cdn_sync_config_tokens || return 1
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG:-}" >/dev/null 2>&1
}

# --- 安装输入 -----------------------------------------------------------------

collect_anytls_install_inputs() {
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' "${CF_ZONE:-}")")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"
    anytls_collect_direct_inputs
    choose_subscription_mode
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")")
    if subscription_enabled; then
        SUBSCRIPTION_DOMAIN=$(normalize_domain "$(prompt_value \
            '订阅域名（橙云代理，回源 8443）' "${SUBSCRIPTION_DOMAIN:-sub.${CF_ZONE}}")")
        validate_domain "${SUBSCRIPTION_DOMAIN}" || die "订阅域名无效：${SUBSCRIPTION_DOMAIN}"
        [[ "${SUBSCRIPTION_DOMAIN}" == *".${CF_ZONE}" ]] \
            || die "订阅域名必须属于 ${CF_ZONE}：${SUBSCRIPTION_DOMAIN}"
        [[ "${SUBSCRIPTION_DOMAIN}" != "${DIRECT_DOMAIN}" ]] \
            || die "订阅域名必须与直连域名不同（直连是灰云 A，订阅是橙云 A）"
    fi
    cdn_derive_runtime_fields || die "运行时字段派生失败：缺少直连域名或订阅域名"
    # Token 收集/校验/持久化是四模式共用的（lib/cf-dns.sh）：下一进程可直接复用已存值。
    cloudflare_collect_api_token 'Cloudflare API Token（Zone 只读 + DNS 编辑；deploy 还需 Zone Settings 只读 + Origin Rules 编辑）'
    ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(generate_secret)}
    SUBSCRIPTION_CONFIG=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}") \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes"
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" \
        || die "订阅配置无效：节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    cdn_validate_install_owner_token
    if [[ -z "${VPS_PUBLIC_IPV4:-}" ]]; then
        VPS_PUBLIC_IPV4=$(detect_public_ipv4) || die "无法自动探测本机公网 IPv4"
    fi
}

# --- Cloudflare 资源 ----------------------------------------------------------

anytls_ensure_zone_id() {
    cloudflare_collect_api_token
    if [[ -z "${CLOUDFLARE_ZONE_ID:-}" ]]; then
        CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}") \
            || die "Cloudflare 中没有 active Zone：${CF_ZONE}"
    fi
}

# 直连域名始终是灰云 A；订阅域名（deploy）是橙云 A，回源走 Origin Rule。
anytls_ensure_dns() {
    anytls_ensure_zone_id
    info "配置直连解析（灰云 A）：${DIRECT_DOMAIN} -> ${VPS_PUBLIC_IPV4}"
    dns_ensure_record "${DIRECT_DOMAIN}" A "${VPS_PUBLIC_IPV4}" false
    if subscription_enabled; then
        info "配置订阅解析（橙云 A）：${SUBSCRIPTION_DOMAIN} -> ${VPS_PUBLIC_IPV4}"
        dns_ensure_record "${SUBSCRIPTION_DOMAIN}" A "${VPS_PUBLIC_IPV4}" true
    fi
}

# 只对精确 http.host 生效的回源端口覆盖；ruleset/rule ID 落 state 供删改复用。
anytls_ensure_origin_rule() {
    local ids ruleset_id rule_id
    subscription_enabled || return 0
    anytls_ensure_zone_id
    ids=$(cloudflare_ensure_origin_rule "${CLOUDFLARE_ZONE_ID}" "${SUBSCRIPTION_DOMAIN}" 8443) \
        || die "创建/更新 Cloudflare Origin Rule 失败；未建立订阅回源"
    ruleset_id=$(printf '%s\n' "${ids}" | sed -n '1p')
    rule_id=$(printf '%s\n' "${ids}" | sed -n '2p')
    [[ -n "${ruleset_id}" && -n "${rule_id}" ]] \
        || die "Cloudflare 未返回 Origin Rule 的 ruleset/rule ID"
    CLOUDFLARE_ORIGIN_RULESET_ID=${ruleset_id}
    CLOUDFLARE_ORIGIN_RULE_ID=${rule_id}
}

anytls_remove_origin_rule() {
    [[ -n "${CLOUDFLARE_ORIGIN_RULESET_ID:-}" && -n "${CLOUDFLARE_ORIGIN_RULE_ID:-}" ]] \
        || return 0
    local zone_id=${CLOUDFLARE_ZONE_ID:-}
    [[ -n "${zone_id}" ]] \
        || zone_id=$(cloudflare_lookup_parent_zone "${CF_ZONE}" || true)
    [[ -n "${zone_id}" ]] || { warn "缺少 Zone ID；跳过 Origin Rule 清理"; return 1; }
    cloudflare_remove_origin_rule "${zone_id}" "${CLOUDFLARE_ORIGIN_RULESET_ID}" \
        "${CLOUDFLARE_ORIGIN_RULE_ID}"
}

# --- 证书 ---------------------------------------------------------------------

# 证书由 runtime-core 的 DNS-01 路径覆盖 certificate_required_hosts（direct + 已部署 sub）。
cdn_issue_certificate() {
    local force=${1:-0}
    install -d -m 0700 "${CERT_DIR}"
    if [[ "${force}" != "1" ]] \
        && certificate_covers_required_hosts "${CERT_FILE}" \
        && certificate_key_matches \
        && openssl x509 -in "${CERT_FILE}" -noout -checkend 2592000 >/dev/null 2>&1; then
        certificate_verify
        return 0
    fi
    certbot_write_cloudflare_credentials
    certbot_issue_certificate "${force}"
    certificate_deploy "" 0 || die "Certbot 未生成覆盖模式所需域名的有效证书"
}

# --- 运行配置与订阅渲染 -------------------------------------------------------

write_runtime_config() {
    local subscription_ok=0
    if subscription_enabled \
        && [[ "${CDN_SUBSCRIPTION_CORRUPT:-0}" == "0" ]] \
        && cdn_config_ready; then
        subscription_ok=1
    fi
    runtime_write_config 0 "${subscription_ok}"
}

build_node_links() {
    local extra
    build_anytls_link
    printf '\n'
    extra=$(aggregation_node_links)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
    return 0
}

build_mihomo_nodes() {
    local extra
    build_mihomo_anytls_node
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

build_mihomo_proxy_groups() {
    printf ''
    return 0
}

anytls_template_snapshot_file() {
    printf '%s/mihomo-template.yaml' "${STATE_DIR}"
}

RT_TEMPLATE_SNAPSHOT_PATH=$(anytls_template_snapshot_file)

anytls_prepare_subscription_template() {
    local snapshot
    snapshot=$(anytls_template_snapshot_file)
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

anytls_persist_subscription_template() {
    local snapshot temp
    [[ -n "${MIHOMO_TEMPLATE_FILE:-}" && -s "${MIHOMO_TEMPLATE_FILE}" ]] \
        || die "缺少可持久化的 Mihomo 模板"
    install -d -m 0700 "${STATE_DIR}"
    snapshot=$(anytls_template_snapshot_file)
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

anytls_write_subscriptions() {
    anytls_prepare_subscription_template
    write_subscriptions
    anytls_persist_subscription_template
}

anytls_render_subscription_files() {
    anytls_prepare_subscription_template
    render_subscription_files "$1"
}

refresh_runtime_subscription() {
    subscription_enabled || {
        save_state
        return 0
    }
    anytls_write_subscriptions
    save_state
}

anytls_subscription_artifacts_ready() {
    local render_dir name ready=1
    render_dir=$(mktemp -d "${RUNTIME_TMP}/subscription-ready.XXXXXX") || return 1
    cleanup_files+=("${render_dir}")
    if ! ( anytls_render_subscription_files "${render_dir}" ) >/dev/null 2>&1; then
        ready=0
    fi
    if ((ready == 1)); then
        for name in base64.txt mihomo.yaml mihomo-ios.yaml \
            base64-all.txt mihomo-all.yaml mihomo-ios-all.yaml; do
            if [[ ! -f "${SUBSCRIPTION_DIR}/${name}" ]] \
                || ! cmp -s "${render_dir}/${name}" "${SUBSCRIPTION_DIR}/${name}"; then
                ready=0
                break
            fi
        done
    fi
    rm -rf -- "${render_dir}"
    ((ready == 1))
}

anytls_subscription_ready() {
    subscription_enabled || return 0
    cdn_config_ready || return 1
    anytls_subscription_artifacts_ready || return 1
    ( validate_subscription_runtime ) >/dev/null 2>&1
}

# --- 公网验收 -----------------------------------------------------------------

anytls_public_curl() {
    curl -sS --proto '=https' --noproxy '*' --connect-timeout 5 --max-time 30 "$@"
}

# 订阅经橙云 → Origin Rule 8443 → Caddy：公网 200 是链路与 strict 的二次证据。
anytls_public_subscription_ok() {
    local token body decoded status
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS:-[]}") || return 1
    [[ -n "${token}" && "${token}" != "null" ]] || return 1
    body=$(anytls_public_curl --get --data-urlencode "token=${token}" \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    decoded=$(printf '%s' "${body}" | openssl base64 -d -A 2>/dev/null) || return 1
    [[ "${decoded}" == *"anytls://"* ]] || return 1
    body=$(anytls_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"type: anytls"* ]] || return 1
    status=$(anytls_public_curl -o /dev/null -w '%{http_code}' \
        --get --data-urlencode 'token=invalid' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${status}" == "403" ]]
}

anytls_validate_public_runtime() {
    local attempt
    subscription_enabled || return 0
    for ((attempt = 1; attempt <= CDN_PUBLIC_ACCEPT_ATTEMPTS; attempt++)); do
        anytls_public_subscription_ok && return 0
        ((attempt == CDN_PUBLIC_ACCEPT_ATTEMPTS)) || sleep "${CDN_PUBLIC_ACCEPT_SECONDS}"
    done
    die "订阅公网验收失败（已重试 ${CDN_PUBLIC_ACCEPT_ATTEMPTS} 次）：请确认 ${SUBSCRIPTION_DOMAIN} 为橙云 A、SSL 为 Full (strict)、Origin Rule 回源 8443 已生效；修复后执行 sudo easy_all apply-cloud"
}

# --- 命令 ---------------------------------------------------------------------

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
    printf '直连域名: %s（AnyTLS，TCP 443 公网）\n' "${DIRECT_DOMAIN}"
    if subscription_enabled; then
        printf '订阅域名: %s（橙云 A，Caddy 8443 仅 Cloudflare 回源段）\n' "${SUBSCRIPTION_DOMAIN}"
        printf 'Origin Rule: ruleset %s / rule %s\n' \
            "${CLOUDFLARE_ORIGIN_RULESET_ID:-未知}" "${CLOUDFLARE_ORIGIN_RULE_ID:-未知}"
    else
        printf '订阅: 未部署（link；仅输出节点）\n'
    fi
    if [[ -s "${CERT_FILE}" ]]; then
        cert_enddate=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        printf '证书到期: %s（覆盖 %s）\n' "${cert_enddate:-未知}" \
            "$(certificate_required_hosts | paste -sd, -)"
    else
        printf '证书: 缺失；请执行 sudo easy_all renew-cert\n'
    fi
    printf 'sing-box: '
    systemctl is-active --quiet "${SINGBOX_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'Caddy: '
    if subscription_enabled; then
        systemctl is-active --quiet "${CADDY_SERVICE}" 2>/dev/null \
            && printf 'active\n' || printf 'inactive\n'
    else
        printf '未部署（link）\n'
    fi
    if [[ "${CDN_SUBSCRIPTION_CORRUPT}" != "0" ]]; then
        printf '订阅: 配置损坏，当前不可用；请执行 sudo easy_all edit-sub\n'
    fi
}

cdn_commit_local_runtime() {
    register_easy_all_command
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
    if subscription_enabled; then
        anytls_write_subscriptions
        validate_subscription_runtime
    fi
    save_state
    cdn_commit_local_runtime
    commit_subscription_update
    success "本机配置与订阅已应用；未修改 Cloudflare 云端资源"
}

apply_cloud_phase() {
    cloudflare_collect_api_token
    persist_cloudflare_token
    # 只读查询 Zone ID 必须先于 strict 校验（design §9）：首装输入只有 Zone 名称。
    anytls_ensure_zone_id
    if subscription_enabled; then
        cloudflare_ensure_zone_ssl_strict
    fi
    anytls_ensure_dns
    certbot_write_cloudflare_credentials
    cdn_issue_certificate
    anytls_ensure_origin_rule
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
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    write_runtime_config
    runtime_apply_runtime_services
    validate_protocol_runtime
    if subscription_enabled; then
        anytls_write_subscriptions
        validate_subscription_runtime
        anytls_validate_public_runtime
    fi
    save_state
    cdn_commit_local_runtime
    commit_subscription_update
    success "本机配置、证书与 Cloudflare 资源已同步"
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
    CDN_SUBSCRIPTION_CORRUPT=0
    snapshot_subscription_update
    if subscription_enabled; then
        anytls_write_subscriptions
        write_runtime_config
        runtime_reload_caddy
        validate_subscription_runtime
    fi
    save_state
    commit_subscription_update
    show_subscription
    success "订阅已刷新"
}

renew_certificate() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cloudflare_collect_api_token
    snapshot_subscription_update
    install_certbot_deploy_hook
    certbot_write_cloudflare_credentials
    if certificate_lineage_is_newer; then
        certificate_deploy "" 0 || die "部署已签发的新证书失败"
    else
        cdn_issue_certificate 1
    fi
    certificate_verify
    write_runtime_config
    runtime_apply_runtime_services 1
    validate_protocol_runtime
    runtime_served_certificate_matches_disk \
        || die "本机 TLS 尚未使用新证书；已保留新 lineage，请修复后重试 renew-cert"
    if subscription_enabled; then
        validate_subscription_runtime
    fi
    save_state
    commit_subscription_update
    success "证书已更新（AnyTLS 与订阅入口使用同一 lineage）"
}

cdn_local_uninstall_common() {
    stop_maintenance_services || true
    stop_services
    remove_certbot_deploy_hook || true
    certificate_remove_lineage || true
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

cdn_print_cloud_inventory() {
    printf '云端资源清单（默认保留，需要时手动处置）：\n' >&2
    printf '  直连 A 记录（灰云）: %s -> %s\n' "${DIRECT_DOMAIN:-未知}" "${VPS_PUBLIC_IPV4:-未知}" >&2
    if subscription_enabled; then
        printf '  订阅 A 记录（橙云）: %s -> %s\n' "${SUBSCRIPTION_DOMAIN:-未知}" \
            "${VPS_PUBLIC_IPV4:-未知}" >&2
        printf '  Origin Rule: %s / %s\n' "${CLOUDFLARE_ORIGIN_RULESET_ID:-未知}" \
            "${CLOUDFLARE_ORIGIN_RULE_ID:-未知}" >&2
    fi
}

# 只删本工具创建的记录与规则：类型、注释、目标三者同时匹配才删。
anytls_purge_cloud_resources() {
    local failed=0 host proxied records count id comment current current_proxied spec
    local -a pairs=()
    anytls_ensure_zone_id || { warn "无法确定 Zone ID；跳过云端清理"; return 1; }
    pairs+=("${DIRECT_DOMAIN}|false")
    if subscription_enabled; then
        pairs+=("${SUBSCRIPTION_DOMAIN}|true")
    fi
    for spec in "${pairs[@]}"; do
        host=${spec%%|*}
        proxied=${spec#*|}
        [[ -n "${host}" ]] || continue
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
        if [[ "${comment}" != "${CDN_RECORD_COMMENT}" || "${current}" != "${VPS_PUBLIC_IPV4}" \
            || "${current_proxied}" != "${proxied}" ]]; then
            warn "Cloudflare ${host} 的 A 记录不是本链路创建的；保留"
            continue
        fi
        # 注释已在本工具安装时被改写：只有接管日志才能证明它原本属于第三方。
        if dns_record_taken_over "${host}"; then
            warn "Cloudflare ${host} 的 A 记录来自强制接管（原注释/指向见 $(dns_takeover_log_file)）；保留，如需删除请手工处理"
            continue
        fi
        (cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null) \
            || { warn "删除 Cloudflare 记录失败：${host}"; failed=1; }
    done
    if subscription_enabled; then
        (anytls_remove_origin_rule) \
            || { warn "删除 Origin Rule 未完成"; failed=1; }
    fi
    return "${failed}"
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
            read_bilingual '删除本机内容以及 easy_all 创建的 Cloudflare DNS 与 Origin Rule？[y/N]:' answer
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
        if (anytls_purge_cloud_resources); then
            :
        else
            warn "云端资源清理未完成；本机卸载继续，请按上方清单手动处置"
        fi
    else
        warn "Cloudflare DNS 与 Origin Rule 已保留；本机状态删除后无法再用 easy_all 清理"
    fi
    cdn_local_uninstall_common || return 1
    success "easy_all 本机内容已卸载"
}

cleanup_partial_install() {
    local failed=0 path
    cleanup_partial_install_local || return 1
    remove_certbot_deploy_hook || true
    certificate_remove_lineage || true
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
    warn "本次已创建的 Cloudflare 记录/规则按设计保留；easy_all 命令已随回滚移除，确认不再使用后可执行 bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) purge-cloudflare --domain <域名>，或直接在 Cloudflare 控制台清理"
    install_progress_clear
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
    prepare_fresh_install 443 8443
    install_progress_begin "${CDN_PROFILE_KEY}" anytls
    snapshot_fresh_install

    install_progress_stage packages
    install_packages
    install_certbot_deploy_hook
    install_progress_stage tcp
    choose_tcp_acceleration
    configure_tcp_acceleration
    if [[ "${INSTALL_RESUME:-0}" == "1" && -n "${SCHEDULED_REBOOT_ENABLED:-}" ]]; then
        refresh_saved_daily_reboot_schedule
    else
        configure_daily_reboot
    fi
    configure_ipv4_only
    install_progress_stage inputs
    collect_anytls_install_inputs
    anytls_prepare_runtime
    install_progress_stage core
    download_singbox
    download_caddy
    install_progress_stage services
    cloudflare_collect_api_token
    persist_cloudflare_token
    # 先只读取得 Zone ID，再校 strict；两者都在任何云资源创建之前。
    anytls_ensure_zone_id
    if subscription_enabled; then
        cloudflare_ensure_zone_ssl_strict
    fi
    configure_runtime_ufw
    anytls_ensure_dns
    certbot_write_cloudflare_credentials
    cdn_issue_certificate
    write_runtime_config
    # 首装先注册 easy_all：sing-box 的 ExecStartPre 依赖 /usr/local/bin/easy_all。
    register_easy_all_command
    runtime_apply_runtime_services
    validate_protocol_runtime
    anytls_ensure_origin_rule
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    install_progress_stage subscription
    if subscription_enabled; then
        anytls_write_subscriptions
        write_runtime_config
        runtime_reload_caddy
        validate_subscription_runtime
        anytls_validate_public_runtime
    fi
    install_progress_stage state
    save_state
    cdn_commit_local_runtime
    INSTALL_ROLLBACK_ON_EXIT=0
    install_progress_clear
    clear_profile_credentials
    INSTALL_FAILURE_ARMED=0
    show_subscription
    success "easy_all ${CDN_MODE_LABEL} 安装完成（${CDN_ENTRY_SUMMARY}）"
    show_tcp_acceleration_status
    prompt_kernel_reboot
}
