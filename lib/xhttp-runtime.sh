#!/usr/bin/env bash

# Shared local runtime for CDN profiles.

readonly SCRIPT_DIR="${XHTTP_LIB_DIR:?XHTTP_LIB_DIR is required}"

readonly STATE_DIR="/etc/easy_all"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly CERT_DIR="${STATE_DIR}/certs"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly WEB_ROOT="${WEB_ROOT:-/var/www/easy_all}"
readonly SUBSCRIPTION_DIR="${SUBSCRIPTION_DIR:-${WEB_ROOT}/subscriptions}"
readonly SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
readonly SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
readonly SUBSCRIPTION_MIHOMO_IOS_FILE="${SUBSCRIPTION_DIR}/mihomo-ios.yaml"
readonly SUBSCRIPTION_BASE64_ALL_FILE="${SUBSCRIPTION_DIR}/base64-all.txt"
readonly SUBSCRIPTION_MIHOMO_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-all.yaml"
readonly SUBSCRIPTION_MIHOMO_IOS_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-ios-all.yaml"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly ENTRY_COMMAND_NAME="easy_all"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly XRAY_DIR="${STATE_DIR}/xray"
readonly XRAY_BIN="${XRAY_BIN:-${XRAY_DIR}/xray}"
readonly XRAY_CONFIG="${XRAY_DIR}/config.json"
readonly XRAY_SERVICE_FILE="/etc/systemd/system/easy_all-xray.service"
readonly XRAY_SERVICE="easy_all-xray.service"
readonly XRAY_SERVICE_DESCRIPTION="${XHTTP_SERVICE_DESCRIPTION_OVERRIDE:-Xray VLESS XHTTP managed by easy_all}"
readonly NGINX_CONFIG="/etc/nginx/conf.d/easy_all.conf"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly UFW_DEFAULT_CONFIG="/etc/default/ufw"
readonly DEFAULT_XRAY_XHTTP_LOOPBACK_PORT="10086"
readonly SERVICE_PORT="443"
readonly DEFAULT_XHTTP_NODE_NAME="VLESS_XHTTP_H2"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/templates/mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases/latest"
readonly STATE_SCHEMA_VERSION="0"
readonly XHTTP_NGINX_STREAM_TIMEOUT="1h"
readonly XHTTP_CDN_NAME="${XHTTP_CDN_NAME_OVERRIDE:-CloudFront}"
readonly SUBSCRIPTION_DEPLOY_DESCRIPTION="${SUBSCRIPTION_DEPLOY_DESCRIPTION_OVERRIDE:-${XHTTP_CDN_NAME} + Nginx}"

# shellcheck source=lib/runtime-core.sh
EASY_ALL_RUNTIME_LIB_DIR="${SCRIPT_DIR}"
source "${SCRIPT_DIR}/runtime-core.sh"
# Keep at least one element: Debian still ships Bash versions where expanding
# an empty array under `set -u` raises "unbound variable".  Restricting these
# local probes to HTTPS is also the intended behavior for every provider.
XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
# Explicit local probe context hook. Profiles that need another SNI/CA/header
# (CloudFront probes its origin name with the origin header) override this;
# the default keeps the domain shown to users.
XHTTP_LOCAL_PROBE_DOMAIN=""
XHTTP_LOCAL_PROBE_HEADER_FILE=""

xhttp_local_probe_context() {
    # Existing providers probe the CDN node domain; CloudFront overrides this
    # with its origin SNI + origin header.
    XHTTP_LOCAL_PROBE_DOMAIN=${VLESS_CDN_DOMAIN:-$(subscription_link_domain)}
    XHTTP_LOCAL_PROBE_HEADER_FILE=""
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https')
    # Providers that have not migrated to the explicit context hook keep their
    # own CA/proxy arguments here.
    if declare -F xhttp_validate_local_tls_curl_args >/dev/null 2>&1; then
        xhttp_validate_local_tls_curl_args
    fi
}

xhttp_local_probe_curl_args() {
    [[ -n "${XHTTP_LOCAL_PROBE_HEADER_FILE}" ]]         || return 0
    printf '%s\n' --header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}"
}

validate_xhttp_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
}

# 路径规范化由安装参数层与交互更新共用：各 Profile 不得再各自定义一份。
normalize_xhttp_path() {
    local path=${1:-}
    while [[ "${path}" =~ ^/(xhttp|vless)-/(xhttp|vless)- ]]; do
        path="/${path#/*-/}"
    done
    if [[ "${path}" =~ ^/(xhttp|vless)- ]]; then
        path="/xhttp-${path#/*-}"
    elif [[ -n "${path}" ]]; then
        path="/xhttp-${path#/}"
    else
        path="/xhttp-$(openssl rand -hex 12)"
    fi
    path="${path%/}"
    printf '%s\n' "${path}"
}

source_state_file() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all XHTTP 状态文件不存在：${STATE_FILE}"
    # The state file must declare its own version; clear any value left behind by
    # an earlier `source` so a missing STATE_VERSION fails loudly instead of passing.
    unset STATE_VERSION
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；当前版本为 ${STATE_SCHEMA_VERSION}"
}

subscription_link_domain() {
    printf '%s' "${SUBSCRIPTION_DOMAIN:-${VLESS_CDN_DOMAIN}}"
}

check_install_conflicts() {
    prepare_fresh_install 80 443
}

install_packages() {
    local pkgs=(
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw
        fail2ban python3-systemd socat cron iproute2 iputils-ping tzdata
        systemd-timesyncd tar util-linux sudo vim
    )
    local nginx_active_before=unknown
    command -v systemctl >/dev/null 2>&1 \
        && nginx_active_before=$(systemctl is-active nginx 2>/dev/null || true)

    if packages_already_installed "${pkgs[@]}" && nginx_package_installed; then
        info "系统基础依赖包与 Nginx 已全部安装，跳过 APT 索引更新与包安装"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 upgrade -y
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${pkgs[@]}"
        # nginx 单独安装：包脚本会立即启动默认站点，必须在这一个 apt 调用内抑制自启，
        # 否则 apt 期间的 SSH 断线就会把 80 端口留给下一次安装。
        if [[ "${nginx_active_before}" == "active" ]] || nginx_package_installed; then
            # 已安装且未运行：apt 不会再触发 postinst 启动，直接安装即可。
            apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends nginx
        else
            install_nginx_without_start nginx || die "安装 nginx 失败"
        fi
        quiet_freshly_installed_nginx "${nginx_active_before}"
    fi

    local current_tz current_ntp
    current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || true)
    if [[ "${current_tz}" != "Asia/Shanghai" ]]; then
        timedatectl set-timezone Asia/Shanghai || warn "设置时区为 Asia/Shanghai 失败"
    fi
    current_ntp=$(timedatectl show --property=NTP --value 2>/dev/null || true)
    if [[ "${current_ntp}" != "yes" ]]; then
        timedatectl set-ntp true || warn "无法启用网络时间同步"
    fi
}

snapshot_fresh_install() {
    # 续装（INSTALL_RESUME=1）不能重新拍快照：那会把回滚目标从“安装前”换成半成品。
    # 保留上次安装前的完整快照；快照不完整时 resume_partial_install 已拒绝续装。
    if [[ "${INSTALL_RESUME:-0}" == "1" && -f "${BACKUP_DIR}/pre-install-complete" ]]; then
        INSTALL_ROLLBACK_ON_EXIT=1
        info "续装：复用上次安装前的快照，不重新拍摄"
        return 0
    fi
    install -d -m 0700 "${BACKUP_DIR}"
    snapshot_ufw_state
    snapshot_platform_security_state
    snapshot_ipv6_state
    snapshot_preinstall_nginx_default_site
    if crontab -l >"${BACKUP_DIR}/pre-install-crontab" 2>/dev/null; then
        chmod 0600 "${BACKUP_DIR}/pre-install-crontab"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-crontab.missing"
    fi
    # 完整性标记：清理只在快照全部拍完后才允许逐项恢复，否则「还没拍到」会被误当成
    # 「安装前不存在」，把原有 fail2ban/SSH 配置删掉。
    install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-complete"
    INSTALL_ROLLBACK_ON_EXIT=1
}

snapshot_ufw_state() {
    # 卸载与回滚都不会关闭 UFW，只回写 /etc/default/ufw 的 IPv6 开关。
    [[ ! -e "${BACKUP_DIR}/pre-install-ufw-default" \
        && ! -e "${BACKUP_DIR}/pre-install-ufw-default.missing" ]] || return 0
    install -d -m 0700 "${BACKUP_DIR}"
    if [[ -f "${UFW_DEFAULT_CONFIG}" ]]; then
        install -m 0600 "${UFW_DEFAULT_CONFIG}" "${BACKUP_DIR}/pre-install-ufw-default"
    else
        install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-ufw-default.missing"
    fi
}

configure_ufw() {
    if declare -F xhttp_configure_ufw >/dev/null 2>&1; then
        xhttp_configure_ufw
        return
    fi
    local desired_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ufw
    fi
    ensure_ssh_boot_service
    detect_ssh_ports
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    desired_ports="${SSH_PORTS} 80 443"
    apply_managed_ufw_tcp_ports "${desired_ports}"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

write_bootstrap_nginx_config() {
    rm -f -- /etc/nginx/sites-enabled/default
}

xhttp_client_path() {
    printf '%s/' "${XHTTP_PATH%/}"
}

# 直连+CDN 在 443 之外还监听 Reality 端口；本函数只验 443 与 health，绑不上直连端口也会
# 验收通过。仅当 Profile 声明了 cdn_reality_enabled 且为真时追加断言，纯 CDN 行为不变。
# 端口尚未监听时返回 1 而不当场 die：Reality 入站可能比 443 与 health 晚几毫秒绑定，
# 交给调用方的重试循环等下一轮，只有轮完仍未监听才终止。
validate_reality_port_listening() {
    declare -F cdn_reality_enabled >/dev/null 2>&1 || return 0
    cdn_reality_enabled || return 0
    local port=${REALITY_PORT:-}
    [[ -n "${port}" ]] || die "直连 Reality 端口未定义（REALITY_PORT）"
    ss -H -ltn "sport = :${port}" 2>/dev/null \
        | awk 'NR {found=1} END {exit !found}'
}

validate_protocol_runtime() {
    local attempt response domain
    local -a probe_args=(-s)
    xhttp_local_probe_context
    domain=${XHTTP_LOCAL_PROBE_DOMAIN:-$(subscription_link_domain)}
    [[ -z "${XHTTP_LOCAL_PROBE_HEADER_FILE}" ]] \
        || probe_args+=(--header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}")
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${XRAY_SERVICE}" \
            && systemctl is-active --quiet nginx \
            && ss -H -ltn "sport = :443" 2>/dev/null \
                | awk 'NR {found=1} END {exit !found}'; then
            response=$(curl -fsS --connect-timeout 5 --max-time 20 \
                "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" "${probe_args[@]}" \
                --resolve "${domain}:443:127.0.0.1" \
                "https://${domain}/easy_all-health" || true)
            if [[ "${response}" == "easy_all ok" ]]; then
                validate_reality_port_listening && return 0
            fi
        fi
        sleep 2
    done
    # 轮完仍未通过：先给出 Reality 端口的具体原因，再回落到通用信息（纯 CDN 不受影响）。
    validate_reality_port_listening \
        || die "Reality 端口 ${REALITY_PORT} 未监听，直连入口不可用"
    die "VLESS XHTTP 本机运行时验收失败"
}

validate_subscription_runtime() {
    local token base64_response base64_decoded mihomo_response marker accounts domain
    local -a probe_args=(-s)
    xhttp_local_probe_context
    domain=${XHTTP_LOCAL_PROBE_DOMAIN:-$(subscription_link_domain)}
    [[ -z "${XHTTP_LOCAL_PROBE_HEADER_FILE}" ]] \
        || probe_args+=(--header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}")
    validate_subscription_token_rejection \
        "${domain}:443:127.0.0.1" \
        "https://${domain}/subscribe" \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" "${probe_args[@]}"
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    base64_response=$(printf '%s' "${token}" | curl -fsS --noproxy '*' \
        --connect-timeout 5 --max-time 20 "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" "${probe_args[@]}" \
        --resolve "${domain}:443:127.0.0.1" \
        --get --data-urlencode 'token@-' \
        "https://${domain}/subscribe") || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    base64_decoded=$(printf '%s' "${base64_response}" | openssl base64 -d -A 2>/dev/null) \
        || die "通用订阅响应不是有效的 Base64"
    grep -Fq "${SUBSCRIPTION_NODE_MARKER:-type=xhttp}" <<<"${base64_decoded}" \
        || die "通用订阅响应缺少节点：${SUBSCRIPTION_NODE_MARKER:-type=xhttp}"
    mihomo_response=$(printf '%s' "${token}" | curl -fsS --noproxy '*' \
        --connect-timeout 5 --max-time 20 "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" "${probe_args[@]}" \
        --resolve "${domain}:443:127.0.0.1" \
        --get --data-urlencode 'token@-' --data-urlencode "flag=clash" \
        "https://${domain}/subscribe") || die "Mihomo 订阅本机验收失败"
    marker='network: xhttp'
    declare -F mihomo_transport_marker >/dev/null 2>&1 \
        && marker=$(mihomo_transport_marker)
    grep -Fq "${marker}" <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
}

xhttp_require_subscription_hooks() {
    local hook
    for hook in build_node_links build_mihomo_nodes \
        build_mihomo_proxy_groups build_mihomo_proxy_names; do
        declare -F "${hook}" >/dev/null 2>&1 \
            || die "CDN Profile 缺少订阅渲染钩子：${hook}"
    done
}

# 渲染六种订阅产物到 output_dir；发布由调用方负责，当前 state 的就绪验收复用同一渲染器。
render_subscription_files() {
    local output_dir=$1 template node_file group_file name_file
    local mihomo_file suffix include variants marker
    variants=${SUBSCRIPTION_OPTIONAL_VARIANTS:-0}
    prepare_mihomo_template
    xhttp_require_subscription_hooks
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
    marker='network: xhttp'
    declare -F mihomo_transport_marker >/dev/null 2>&1 \
        && marker=$(mihomo_transport_marker)
    for suffix in "" "-all"; do
        if [[ "${suffix}" == "-all" ]]; then
            [[ "${variants}" == "1" ]] || continue
            include=1
        else
            include=0
        fi
        EASY_ALL_INCLUDE_OPTIONAL=${include}
        build_mihomo_nodes >"${node_file}"
        build_mihomo_proxy_groups >"${group_file}"
        build_mihomo_proxy_names >"${name_file}"
        build_node_links | openssl base64 -A >"${output_dir}/base64${suffix}.txt"
        printf '\n' >>"${output_dir}/base64${suffix}.txt"
        mihomo_file="${output_dir}/mihomo${suffix}.yaml"
        render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}" \
            "${XHTTP_NODE_NAME}" "${group_file}" "${name_file}"
        grep -Fq "${marker}" "${mihomo_file}" || die "Mihomo 订阅缺少有效节点"
        grep -Fq "${VLESS_CDN_DOMAIN}" "${mihomo_file}" || die "Mihomo 订阅缺少 CDN 域名"
        strip_mihomo_sniffer "${mihomo_file}" >"${output_dir}/mihomo-ios${suffix}.yaml" \
            || die "暂存 iOS Mihomo 订阅失败"
    done
    EASY_ALL_INCLUDE_OPTIONAL=0
    chmod 0640 "${output_dir}"/*.txt "${output_dir}"/*.yaml
}

write_subscriptions() {
    local stage_dir
    install -d -m 0755 "${WEB_ROOT}"
    stage_dir=$(mktemp -d "${WEB_ROOT}/.subscriptions.stage.XXXXXX") \
        || die "创建订阅暂存目录失败"
    cleanup_files+=("${stage_dir}")
    render_subscription_files "${stage_dir}"
    publish_subscription_files "${stage_dir}"
    rm -rf -- "${stage_dir}"
}

show_subscription() {
    collect_installed_state
    show_node
    if ! subscription_enabled; then
        printf '订阅服务: 未部署，仅输出节点信息\n\n'
        return 0
    fi
    printf 'Mihomo 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME}"
    local user token subscription_domain
    subscription_domain=$(subscription_link_domain)
    printf '订阅链接域名: %s\n' "${subscription_domain}"
    while IFS=$'\t' read -r user token; do
        printf '订阅 (%s): https://%s/subscribe?token=%s\n' \
            "${user}" "${subscription_domain}" "${token}"
    done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"${ALLOWED_TOKENS}")
    printf '%s\n' '  同一链接按客户端自动下发：Clash/mihomo/Stash/FlClash → YAML；Shadowrocket/v2rayN/v2rayNG/NekoBox → Base64'
    printf '%s\n' '  如需强制格式：在链接后加 &flag=clash 或 &flag=base64'
    if [[ "${SUBSCRIPTION_OPTIONAL_VARIANTS:-0}" == "1" ]] \
        && jq -e 'any(.[]; .optional == true)' <<<"${AGGREGATION_NODES:-[]}" >/dev/null 2>&1; then
        printf '%s\n' '  追加 &node=all 可显示标记为 optional 的聚合节点'
    fi
    printf '%s\n' '  iOS 客户端（UA 命中 iphone/ipad/ipod/ios，或链接加 &os=ios）下发的 YAML 不带嗅探段'
    printf '\n'
}

snapshot_subscription_update() {
    UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
    [[ -f "${STATE_FILE}" ]] && install -m 0600 "${STATE_FILE}" "${UPDATE_SUB_BACKUP_DIR}/state.env"
    if [[ -n "${XRAY_CONFIG:-}" && -f "${XRAY_CONFIG}" ]]; then
        install -m 0600 "${XRAY_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/xray-config.json"
    fi
    if [[ -f "${NGINX_CONFIG}" ]]; then
        install -m 0600 "${NGINX_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/nginx.conf"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/nginx.conf.missing"
    fi
    if [[ -f "${CERT_FILE}" ]]; then
        install -m 0644 "${CERT_FILE}" "${UPDATE_SUB_BACKUP_DIR}/certificate.pem"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/certificate.missing"
    fi
    if [[ -f "${KEY_FILE}" ]]; then
        install -m 0600 "${KEY_FILE}" "${UPDATE_SUB_BACKUP_DIR}/private.key"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/private-key.missing"
    fi
    if [[ -d "${SUBSCRIPTION_DIR}" ]]; then
        cp -a "${SUBSCRIPTION_DIR}" "${UPDATE_SUB_BACKUP_DIR}/subscriptions"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/subscriptions.missing"
    fi
    # 调用方（CloudFront 核心）声明了模板快照时，它是本次事务的一部分：
    # 快照必须和 state/六产物一起回滚，否则下一进程会发布失败事务的新模板。
    if [[ -n "${XHTTP_TEMPLATE_SNAPSHOT_PATH:-}" ]]; then
        if [[ -f "${XHTTP_TEMPLATE_SNAPSHOT_PATH}" ]]; then
            install -m 0600 "${XHTTP_TEMPLATE_SNAPSHOT_PATH}" \
                "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml"
        else
            install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml.missing"
        fi
    fi
    UPDATE_SUB_ROLLBACK_ON_EXIT=1
}

rollback_subscription_update() {
    warn "本机配置更新失败，正在恢复状态、Nginx 与订阅文件"
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/state.env" ]]; then
        restore_state_file "${UPDATE_SUB_BACKUP_DIR}/state.env" "${STATE_FILE}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/xray-config.json" && -n "${XRAY_CONFIG:-}" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/xray-config.json" "${XRAY_CONFIG}"
        # 本分支只恢复文件、绝不重启 Xray：保护性停机下的 edit-sub 如此，apply/apply-cloud/
        # reality-target 的最后 checkpoint 拒绝也如此。这里不声称服务是否在运行——后三条路径
        # 进入时旧 Xray 仍在运行（只是不重启），写“已停机”会误导运维。
        if [[ "${UPDATE_SUB_ROLLBACK_NO_RESTART:-0}" == "1" ]]; then
            warn "本次回滚不重启 Xray（旧进程可能仍在运行）；若保护待落实，请执行 sudo easy_all cdn-traffic-sync（定时器也会在约 15 秒内收敛）"
        elif declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1 \
            && ! cdn_traffic_protection_checkpoint; then
            # 恢复重启前也要采样：拒绝时文件仍已恢复，但不得重新放行旧的开放运行时。
            # 该分支没有重启也没有停服务：旧进程可能仍在以开放配置运行，停机会切断模式 4/5 的直连。
            warn "恢复前 CDN 流量采样未通过；未重启 Xray，旧进程可能仍在以开放配置运行；保护会在保护定时器下一轮（约 15 秒）收敛，也可立即执行 sudo easy_all cdn-traffic-sync"
        else
            systemctl restart "${XRAY_SERVICE:-easy_all-xray.service}" >/dev/null 2>&1 \
                || warn "恢复订阅更新前 Xray 配置失败"
        fi
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/nginx.conf" "${NGINX_CONFIG}"
    else
        rm -f -- "${NGINX_CONFIG}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/certificate.pem" ]]; then
        install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/certificate.pem" "${CERT_FILE}"
    else
        rm -f -- "${CERT_FILE}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/private.key" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/private.key" "${KEY_FILE}"
    else
        rm -f -- "${KEY_FILE}"
    fi
    if [[ -d "${UPDATE_SUB_BACKUP_DIR}/subscriptions" ]]; then
        publish_subscription_files "${UPDATE_SUB_BACKUP_DIR}/subscriptions"
    else
        rm -rf -- "${SUBSCRIPTION_DIR}"
    fi
    if [[ -n "${XHTTP_TEMPLATE_SNAPSHOT_PATH:-}" ]]; then
        if [[ -f "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml" ]]; then
            install -d -m 0700 "${XHTTP_TEMPLATE_SNAPSHOT_PATH%/*}" \
                && install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml" \
                    "${XHTTP_TEMPLATE_SNAPSHOT_PATH}" \
                || warn "恢复 Mihomo 模板快照失败：${XHTTP_TEMPLATE_SNAPSHOT_PATH}"
        elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml.missing" ]]; then
            rm -f -- "${XHTTP_TEMPLATE_SNAPSHOT_PATH}"
        fi
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 \
        || warn "恢复订阅更新前 Nginx 配置失败"
}

commit_subscription_update() {
    release_runtime_write_lock
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
}

# 卸载与安装失败回滚都只回收业务端口：保留 UFW 启用状态、默认策略与 SSH 放行。
restore_preinstall_firewall() {
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" "${UFW_DEFAULT_CONFIG}" \
            || warn "恢复 ${UFW_DEFAULT_CONFIG} 失败"
    reclaim_ufw_business_rules || warn "回收业务 UFW 放行未完成；请人工核对 ufw status"
    ufw reload >/dev/null 2>&1 || true
}

stop_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now nginx >/dev/null 2>&1 || true
}
