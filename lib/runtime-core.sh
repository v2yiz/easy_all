#!/usr/bin/env bash

# Protocol-neutral runtime shared by the four easy_all profiles (sing-box + Caddy).
#
# 这里只放与协议无关的本机运行时职责：状态读写门禁、安装前置、UFW、证书部署、
# 订阅发布事务、服务启停、配置发布与核心事务。模式差异由 Profile 常量
# （PROTOCOL / SUBSCRIPTION_MODE / CDN_PROFILE_KEY）和 Phase 1 渲染库派生，
# 不在这里分支复制渲染逻辑。

readonly RUNTIME_LIB_DIR="${EASY_ALL_RUNTIME_LIB_DIR:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)}"
readonly SCRIPT_DIR="${RUNTIME_LIB_DIR}"

# shellcheck source=lib/state.sh
source "${RUNTIME_LIB_DIR}/state.sh"

readonly STATE_DIR="${EASY_ALL_STATE_DIR_OVERRIDE:-/etc/easy_all}"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly STATE_FILE="${STATE_DIR}/state.env"
readonly CERT_DIR="${EASY_ALL_CERT_DIR_OVERRIDE:-${STATE_DIR}/certs}"
readonly CERT_FILE="${CERT_DIR}/fullchain.pem"
readonly KEY_FILE="${CERT_DIR}/private.key"
readonly SUBSCRIPTION_DIR="${EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE:-/var/www/easy_all/subscriptions}"
readonly SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
readonly SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
readonly SUBSCRIPTION_MIHOMO_IOS_FILE="${SUBSCRIPTION_DIR}/mihomo-ios.yaml"
readonly SUBSCRIPTION_BASE64_ALL_FILE="${SUBSCRIPTION_DIR}/base64-all.txt"
readonly SUBSCRIPTION_MIHOMO_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-all.yaml"
readonly SUBSCRIPTION_MIHOMO_IOS_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-ios-all.yaml"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly ENTRY_COMMAND_NAME="easy_all"
readonly COMMAND_PATH="/usr/local/bin/${ENTRY_COMMAND_NAME}"
readonly UFW_RULE_COMMENT="easy_all-managed"
readonly UFW_DEFAULT_CONFIG="/etc/default/ufw"
readonly DEFAULT_SUB_DOWNLOAD_NAME="EASY_ALL"
readonly DEFAULT_MIHOMO_TEMPLATE_URL="https://raw.githubusercontent.com/v2yiz/easy_all/main/templates/mihomo.yaml"
readonly DEFAULT_REBOOT_HOUR="4"
readonly CRON_REBOOT_MARKER="# easy_all-managed-reboot"
readonly STATE_SCHEMA_VERSION="${EASY_ALL_STATE_SCHEMA_VERSION}"
readonly SUBSCRIPTION_DEPLOY_DESCRIPTION="Caddy"

# easy_all 专用 Certbot lineage（design §6）：DNS-01 签发，不使用 Caddy DNS 插件，
# 不开放 80 端口。凭据 0600 持久保存以便定时续期。
readonly CERTBOT_LINEAGE_NAME="easy_all"
readonly CERTBOT_LIVE_DIR="${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE:-/etc/letsencrypt/live/easy_all}"
readonly CERTBOT_DEPLOY_HOOK_FILE="${EASY_ALL_CERTBOT_HOOK_FILE_OVERRIDE:-/etc/letsencrypt/renewal-hooks/deploy/easy_all.sh}"
readonly CLOUDFLARE_CREDENTIALS_FILE="${EASY_ALL_CLOUDFLARE_CREDENTIALS_OVERRIDE:-/etc/easy_all/cloudflare.ini}"

# shellcheck source=lib/log.sh
source "${RUNTIME_LIB_DIR}/log.sh"
# shellcheck source=lib/platform.sh
source "${RUNTIME_LIB_DIR}/platform.sh"
# shellcheck source=lib/profile-common.sh
source "${RUNTIME_LIB_DIR}/profile-common.sh"
# shellcheck source=lib/network.sh
source "${RUNTIME_LIB_DIR}/network.sh"
# shellcheck source=lib/mihomo-template.sh
source "${RUNTIME_LIB_DIR}/mihomo-template.sh"
# shellcheck source=lib/firewall.sh
source "${RUNTIME_LIB_DIR}/firewall.sh"
# shellcheck source=lib/singbox-core.sh
source "${RUNTIME_LIB_DIR}/singbox-core.sh"
# shellcheck source=lib/caddy-core.sh
source "${RUNTIME_LIB_DIR}/caddy-core.sh"
# shellcheck source=lib/singbox-runtime.sh
source "${RUNTIME_LIB_DIR}/singbox-runtime.sh"
# shellcheck source=lib/singbox-subscription.sh
source "${RUNTIME_LIB_DIR}/singbox-subscription.sh"
# shellcheck source=lib/caddy-runtime.sh
source "${RUNTIME_LIB_DIR}/caddy-runtime.sh"
# shellcheck source=lib/cf-dns.sh
source "${RUNTIME_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/cf-origin-rule.sh
source "${RUNTIME_LIB_DIR}/cf-origin-rule.sh"
# shellcheck source=lib/local-aggregation.sh
source "${RUNTIME_LIB_DIR}/local-aggregation.sh"
# shellcheck source=lib/scheduled-maintenance.sh
source "${RUNTIME_LIB_DIR}/scheduled-maintenance.sh"
# shellcheck source=lib/subscription-auth.sh
source "${RUNTIME_LIB_DIR}/subscription-auth.sh"
# shellcheck source=lib/tcp-tuning.sh
source "${RUNTIME_LIB_DIR}/tcp-tuning.sh"

readonly RUNTIME_WRITE_LOCK_FILE="${RUNTIME_WRITE_LOCK_FILE_OVERRIDE:-/var/lib/easy_all/runtime-write.lock}"

RUNTIME_WRITE_LOCK_DEPTH=0
CDN_SUBSCRIPTION_CORRUPT=0

try_acquire_runtime_write_lock() {
    if ((RUNTIME_WRITE_LOCK_DEPTH > 0)); then
        RUNTIME_WRITE_LOCK_DEPTH=$((RUNTIME_WRITE_LOCK_DEPTH + 1))
        return 0
    fi
    command -v flock >/dev/null 2>&1 \
        || die "缺少 flock；无法保护 easy_all 运行时更新"
    install -d -m 0700 "$(dirname "${RUNTIME_WRITE_LOCK_FILE}")" \
        || die "无法创建 easy_all 运行时锁目录"
    exec 9>"${RUNTIME_WRITE_LOCK_FILE}" \
        || die "无法打开 easy_all 运行时锁：${RUNTIME_WRITE_LOCK_FILE}"
    if ! flock -w "${1:-0}" 9; then
        exec 9>&-
        return 1
    fi
    RUNTIME_WRITE_LOCK_DEPTH=1
}

acquire_runtime_write_lock() {
    try_acquire_runtime_write_lock "${1:-0}" \
        || die "另一个 easy_all 配置或运行时任务正在运行，请稍后重试"
}

release_runtime_write_lock() {
    ((RUNTIME_WRITE_LOCK_DEPTH > 0)) || return 0
    RUNTIME_WRITE_LOCK_DEPTH=$((RUNTIME_WRITE_LOCK_DEPTH - 1))
    ((RUNTIME_WRITE_LOCK_DEPTH == 0)) || return 0
    flock -u 9 >/dev/null 2>&1 || true
    exec 9>&-
}

# 允许调用方（测试或外部编排）注入隔离临时目录；只有自己创建时才登记清理，
# 否则退出时会删掉不属于 easy_all 的目录。
RUNTIME_TMP_CREATED=0
if [[ -z "${RUNTIME_TMP:-}" ]]; then
    # 显式模板：macOS 的 mktemp 在无模板时忽略 TMPDIR，直接落到系统临时目录，
    # 受限环境（沙箱/CI）会 EPERM；GNU mktemp 行为不变。
    RUNTIME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/easy_all-runtime.XXXXXXXX") \
        || die "无法创建运行时临时目录"
    RUNTIME_TMP_CREATED=1
fi
cleanup_files=()
((RUNTIME_TMP_CREATED == 0)) || cleanup_files=("${RUNTIME_TMP}")
INSTALL_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_ON_EXIT=0
UPDATE_SUB_ROLLBACK_NO_RESTART=0
UPDATE_SUB_BACKUP_DIR=""
MIHOMO_TEMPLATE_FILE=""
# 状态回滚失败时保留运行时临时目录（内含旧状态/证书/订阅备份），供人工恢复。
PRESERVE_RUNTIME_TMP=0

cleanup() {
    local status=$?
    # 交互确认阶段（install_cleanup_after_failure）可能被 Ctrl+C/TERM 直接终止：
    # 凭据与临时 API 请求头必须在任何报告与交互之前清掉，否则 Bearer Token 滞留磁盘。
    if declare -F clear_profile_credentials >/dev/null 2>&1; then
        clear_profile_credentials || true
    fi
    # trap 里再次收到 Ctrl+C/TERM 会重入 cleanup：只解除 EXIT 钩子防递归，INT/TERM
    # 保持上层处置——交互确认段仍可中断（130/143 退出并跳过本次退出清理的收尾），
    # 回滚执行段在下面单独屏蔽。
    trap - EXIT
    local path
    # 安装中途失败：先说明失败位置与阶段，再由用户决定是否清理本机残留。
    if [[ "${status}" != "0" ]] && declare -F install_failure_report >/dev/null 2>&1; then
        install_failure_report || true
    fi
    # 云端保留资源的点名必须早于可能 die 的回滚动作：回滚里的状态恢复失败会 exit，
    # 放在回滚之后就会漏报本次已签发的新证书。
    if [[ "${status}" != "0" ]] && declare -F profile_report_retained_resources >/dev/null 2>&1; then
        profile_report_retained_resources || true
    fi
    if [[ "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
        if [[ -n "${UPDATE_SUB_BACKUP_DIR:-}" ]]; then
            # 回滚执行段没有交互：屏蔽 INT/TERM，保证恢复状态、证书、订阅与收尾
            # 不被第二次 Ctrl+C 中断。
            trap '' INT TERM
            rollback_subscription_update || true
        else
            warn "订阅更新要求回滚，但备份目录为空"
        fi
    elif [[ "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" ]]; then
        INSTALL_ROLLBACK_ON_EXIT=0
        if [[ "${status}" != "0" ]] && declare -F install_cleanup_after_failure >/dev/null 2>&1; then
            install_cleanup_after_failure rollback || true
        else
            rollback_fresh_install || true
        fi
    elif [[ "${status}" != "0" && "${INSTALL_FAILURE_ARMED:-0}" == "1" ]] \
        && declare -F install_cleanup_after_failure >/dev/null 2>&1 \
        && [[ -n "$(install_progress_field PROFILE 2>/dev/null || true)" ]]; then
        # 安装流程在拍快照之前就失败了：仍可只清理本机残留。
        install_cleanup_after_failure partial || true
    fi
    if declare -F recover_pending_service_policy >/dev/null 2>&1; then
        recover_pending_service_policy \
            || warn "恢复 policy-rc.d 事务失败：事务已保留，下次运行安装/清理会自动重试"
    fi
    while ((RUNTIME_WRITE_LOCK_DEPTH > 0)); do
        release_runtime_write_lock || break
    done
    # 凭据只允许存在于内存：成功、失败、EXIT、INT/TERM 都走同一清理钩子。
    if declare -F clear_profile_credentials >/dev/null 2>&1; then
        clear_profile_credentials || true
    fi
    for path in "${cleanup_files[@]:-}"; do
        [[ -n "${path}" ]] || continue
        # 状态回滚失败时保留整个运行时目录：备份目录（part.*）与临时凭据都在其中，
        # 但凭据已先由 clear_profile_credentials 删除。
        if [[ "${PRESERVE_RUNTIME_TMP:-0}" == "1" && "${path}" == "${RUNTIME_TMP}" ]]; then
            continue
        fi
        rm -rf -- "${path}"
    done
    return 0
}
# INT/TERM 也统一走 EXIT 钩子：cleanup 里的 $? 拿到 130/143 后仍会回滚与清理。
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# One-shot maintenance units write runtime state on exit, so an uninstall must wait for
# any running job to finish (including its own rollback) before deleting files.
# 内部入口：easy_all-singbox.service 的 ExecStartPre（只取 counter，绝不取 runtime）。
internal_traffic_prepare() {
    declare -F cdn_traffic_prepare_counters >/dev/null 2>&1 \
        || die "当前模式没有 CDN 计量入口"
    # 首装时 state.env 尚未写入（它要等云端与订阅验收后才落盘），但安装身份已在
    # 创建资源前持久化；启动准备必须能从 state 或身份得到 PROTOCOL 与额度，
    # 否则保护会因变量为空而短路。
    if [[ -f "${STATE_FILE}" ]]; then
        collect_installed_state
    else
        local identity chain
        identity=$(install_identity_file)
        install_marker_chain_matches "${CDN_PROFILE_KEY:-}" \
            || die "安装进度标记缺少本模式要求的 CHAIN；拒绝启动 sing-box"
        case "${CDN_PROFILE_KEY:-}" in
        cloudfront | combined-cloudfront) chain=cloudfront ;;
        cloudflare) chain=cloudflare ;;
        *) die "当前模式没有可校验的 saas 链：${CDN_PROFILE_KEY:-空}" ;;
        esac
        install_identity_chain_matches "${identity}" "${CDN_PROFILE_KEY:-}" \
            "${PROTOCOL:-}" "${chain}" \
            || die "安装身份缺失或 profile/protocol/chain 与安装标记不一致；拒绝启动 sing-box"
        jq -e '.cdn_traffic_protection_gb == "985"' "${identity}" >/dev/null 2>&1 \
            || die "安装身份缺少固定 985GB 保护额度；拒绝启动 sing-box"
        load_install_identity \
            || die "安装身份无法读取；无法确认 CDN 计量契约，拒绝启动 sing-box"
    fi
    cdn_traffic_prepare_counters \
        || die "计量准备失败（规则/目录/锁/usage）；拒绝启动 sing-box"
    cdn_traffic_require_counters \
        || die "计量规则或 usage 校验失败；拒绝启动 sing-box"
    cdn_traffic_start_config_allowed "${SINGBOX_CONFIG}" \
        || die "持久阻断/保护性停机状态与开放 CDN 入站的候选配置冲突；拒绝启动 sing-box"
    success "计量规则与保护状态校验通过"
}

# 内部入口：Certbot 定时 hook。自行取 runtime 锁，只部署已签发证书（不再次签发）。
internal_cert_deploy() {
    local lineage=${RENEWED_LINEAGE:-}
    require_root
    [[ -n "${lineage}" ]] || die "缺少 RENEWED_LINEAGE；拒绝部署未知证书"
    [[ "$(cd -- "${lineage}" 2>/dev/null && pwd)" == "$(cd -- "${CERTBOT_LIVE_DIR}" 2>/dev/null && pwd)" ]] \
        || die "RENEWED_LINEAGE 不属于本工具：${lineage}"
    acquire_runtime_write_lock 30 \
        || die "证书部署未能取得运行时写锁；保留当前证书，请执行 sudo easy_all renew-cert"
    collect_installed_state
    certificate_deploy || die "无法部署并验收新证书；保留现用证书与 Certbot lineage"
    save_state
    release_runtime_write_lock
    success "证书已部署"
}

stop_maintenance_services() {
    command -v systemctl >/dev/null 2>&1 || return 0
    # 先停 timer 再停 oneshot service：否则 timer 可能在删除过程中重新拉起任务。
    systemctl stop easy_all-cdn-traffic-guard.timer 2>/dev/null || true
    systemctl stop easy_all-cdn-traffic-guard.service 2>/dev/null || true
}

uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

validate_vless_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
}

# 路径规范化：安装输入与 edit-sub 共用，任何 Profile 不得再定义第二份。
normalize_vless_path() {
    local path=${1:-}
    path=${path%/}
    if [[ -z "${path}" ]]; then
        printf '/vless-%s\n' "$(openssl rand -hex 12)"
        return 0
    fi
    [[ "${path}" == /vless-* ]] || path="/vless-${path#/}"
    printf '%s\n' "${path}"
}

# 对外发布的订阅链接必须用订阅域名：CloudFront 模式的站点主机是源站域名（只接受
# 带源站密钥头的 CloudFront 回源），不带该头也无法直连使用（design §2/§8）。
# 本机探活仍用 caddy_site_host：它才是本机实际监听的源站/订阅站点主机。
subscription_link_domain() {
    case "${PROTOCOL:-}" in
    anytls)
        subscription_enabled || die "模式 1 未部署订阅；没有可发布的订阅链接"
        caddy_require_host SUBSCRIPTION_DOMAIN
        ;;
    cloudfront | combined-cloudfront) caddy_require_host SUBSCRIPTION_DOMAIN ;;
    cloudflare | combined-cloudflare) caddy_require_host CF_NODE_DOMAIN ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

# --- 模式派生的运行参数 -------------------------------------------------------

runtime_protocol_label() {
    case "${PROTOCOL:-}" in
    anytls) printf 'AnyTLS（direct TCP 443）' ;;
    cloudfront) printf 'VLESS WebSocket over AWS CloudFront' ;;
    cloudflare) printf 'VLESS WebSocket over Cloudflare 橙云' ;;
    combined-cloudfront) printf 'AnyTLS（direct TCP 443）+ VLESS WebSocket over AWS CloudFront' ;;
    combined-cloudflare) printf 'AnyTLS（direct TCP 443）+ VLESS WebSocket over Cloudflare 橙云' ;;
    *) printf '%s\n' "${PROTOCOL:-未知}" ;;
    esac
}

runtime_has_direct_entry() {
    state_protocol_has_direct_entry "${PROTOCOL:-}"
}

runtime_has_cdn_entry() {
    state_protocol_has_cdn_entry "${PROTOCOL:-}"
}

# 公网 TCP 业务端口（design §2）。模式 3 的 443 与模式 1 的 8443 只对 Cloudflare 段开放。
runtime_public_tcp_ports() {
    case "${PROTOCOL:-}" in
    anytls) printf '443' ;;
    cloudfront) printf '443' ;;
    cloudflare) printf '' ;;
    combined-cloudfront) printf '443 8443' ;;
    combined-cloudflare) printf '443' ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

# 只允许 Cloudflare IPv4 段访问的业务端口；空表示本模式没有该端口。
runtime_cloudflare_only_port() {
    case "${PROTOCOL:-}" in
    cloudflare) printf '443' ;;
    anytls) subscription_enabled && printf '8443' ;;
    combined-cloudflare) printf '8443' ;;
    esac
    return 0
}

# 回环 CDN 入站端口：Caddy 只在此端口后转发，任何模式都不对公网监听。
runtime_cdn_loopback_port() {
    printf '10086\n'
}

runtime_caddy_site_enabled() {
    case "${PROTOCOL:-}" in
    anytls) subscription_enabled ;;
    cloudfront | cloudflare | combined-cloudfront | combined-cloudflare) return 0 ;;
    *) return 1 ;;
    esac
}

runtime_singbox_exec_start_pre() {
    case "${PROTOCOL:-}" in
    cloudfront | combined-cloudfront)
        printf '%s internal-traffic-prepare' "${COMMAND_PATH}"
        ;;
    *) printf '' ;;
    esac
}

# --- 状态契约与订阅配置（五模式共用） ---------------------------------------

# AnyTLS 直连身份（模式 1/4 共用）：域名、节点名与密码先落盘再创建任何资源。
anytls_collect_direct_inputs() {
    DIRECT_DOMAIN=$(normalize_domain "$(prompt_value \
        '直连节点域名（灰云 A 记录指向本机）' "${DIRECT_DOMAIN:-node.${CF_ZONE}}")")
    validate_domain "${DIRECT_DOMAIN}" || die "直连域名无效：${DIRECT_DOMAIN}"
    [[ "${DIRECT_DOMAIN}" == *".${CF_ZONE}" ]] \
        || die "直连域名必须属于 ${CF_ZONE}：${DIRECT_DOMAIN}"
    DIRECT_NODE_NAME=$(prompt_value '直连节点名' "${DIRECT_NODE_NAME:-🇺🇸直连}")
    validate_node_name "${DIRECT_NODE_NAME}" \
        || die "直连节点名无效（1-64 字符，不能含控制字符）"
    cdn_node_name_reserved "${DIRECT_NODE_NAME}" && die "直连节点名不能使用保留组名：${DIRECT_NODE_NAME}"
    return 0
}

anytls_prepare_runtime() {
    [[ -n "${DIRECT_DOMAIN:-}" && -n "${DIRECT_NODE_NAME:-}" ]] \
        || die "直连域名/节点名缺失；请先执行 sudo easy_all uninstall 后重新安装"
    ANYTLS_PASSWORD=${ANYTLS_PASSWORD:-$(generate_secret)}
    [[ ${#ANYTLS_PASSWORD} -ge 16 ]] || die "AnyTLS 密码长度不足 16"
    # 密码生成后立即落盘：中断续装必须复用同一身份，不能等最终 save_state。
    persist_install_identity \
        || die "无法落盘安装身份；在生成运行配置前停止"
}

# 交互确认是否可用：提示写 stderr、输入读 stdin，两者都必须是终端（非交互即 fail-closed 拒绝）。
# 不要求 stdout 也是终端：`| tee` 仍能在终端看到提示并作答；stderr 被重定向时拒绝，避免终端无提示却盲等输入。
# 自动化测试通过覆盖本函数模拟交互终端；生产不提供环境变量旁路。
dns_takeover_interactive() {
    [[ -t 0 && -t 2 ]]
}

# 来自云端记录的任意文本：去终端转义并压成单行（仅用于提示展示）。
dns_record_field_text() {
    strip_terminal_input "${1:-}" | tr '\t\r\n' '   '
}

# 接管是破坏性操作：改写前留一行审计记录（原注释/原指向/原代理/原 TTL）。
# 日志放在 /var/log/easy_all：安装状态目录会被失败清理整体删除，而云端改动会保留。
# 先落盘再改写：PATCH 已到云端但响应丢失时进程会退出，事后补写就再也拿不到原貌。
dns_takeover_log_file() {
    # override 只供测试隔离日志路径，生产不得设置：两侧取值不一致时读不到这份记录。
    printf '%s' "${EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE:-/var/log/easy_all/dns-takeover.log}"
}

# 单行 JSON：字段值可能含空格/引号/换行，空注释保持为 ""，不会与字面值或相邻字段混淆。
dns_takeover_record() {
    local host=$1 comment=$2 content=$3 proxied=$4 ttl=$5 log
    log=$(dns_takeover_log_file)
    install -d -m 0700 "$(dirname -- "${log}")" 2>/dev/null || true
    # 原貌落不了盘就不能改写云端记录：磁盘满/只读/EISDIR 下继续 PATCH 会直接破坏恢复承诺。
    # 历史日志保持原样，修好本机日志问题后重跑会重新确认并保存原貌。
    jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg host "${host}" \
        --arg comment "${comment}" --arg content "${content}" --arg proxied "${proxied}" \
        --arg ttl "${ttl}" \
        '{ts:$ts,host:$host,old_comment:$comment,old_content:$content,old_proxied:$proxied,old_ttl:$ttl}' \
        >>"${log}" 2>/dev/null \
        || die "无法写入接管审计日志：${log}；已取消接管（云端记录未改写）"
    chmod 0600 "${log}" 2>/dev/null || warn "无法设置接管审计日志权限：${log}"
}

# 清理时只看注释会把强制接管的第三方记录当成本工具资源删除：命中接管日志即保留。
# 按 host 匹配、不含 zone_id：跨 Zone 同名命中只会多保留（该删没删），方向安全。
dns_record_taken_over() {
    local log rc=0
    log=$(dns_takeover_log_file)
    [[ -f "${log}" ]] || return 1
    grep -Fq -- "\"host\":\"${1}\"" "${log}" || rc=$?
    if ((rc == 0)); then return 0; fi
    # rc=1 才是「未命中」；rc≥2 是日志不可读/IO 错误，无法证明未接管，按接管保守处理。
    if ((rc == 1)); then return 1; fi
    warn "无法读取接管审计日志：${log}；按接管处理，保留对应记录"
    return 0
}

dns_confirm_takeover() {
    local host=$1 comment=$2 current=$3 current_proxied=$4
    local answer="" safe_current safe_proxied
    safe_current=$(dns_record_field_text "${current}")
    safe_proxied=$(dns_record_field_text "${current_proxied}")
    dns_takeover_interactive \
        || die "Cloudflare ${host} 的同名记录不是本工具创建的（注释：${comment}）；拒绝接管（非交互：stdin/stderr 不是终端，未提示确认）"
    read_confirmation "Cloudflare ${host} 的同名记录不是本工具创建的（当前指向：${safe_current:-空}，代理：${safe_proxied:-未知}，注释：${comment}）；是否强制接管？[y/N]:" answer \
        || answer=""
    [[ "${answer}" =~ ^[Yy]$ ]] \
        || die "Cloudflare ${host} 的同名记录不是本工具创建的（注释：${comment}）；拒绝接管"
}

# DNS 记录的唯一写入入口（五模式共用）：先按名字读取全部记录，再校验类型/代理状态/目标/归属。
# 同名其他类型或多条同名记录一律阻止写入；非受管记录在交互终端下需确认是否强制接管。
dns_ensure_record() {
    local host=$1 type=$2 content=$3 proxied=$4
    local records conflicts count id comment current current_proxied current_ttl payload safe_comment
    local reread takeover=0
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" ]] || die "缺少 Cloudflare Zone ID；无法写入 DNS：${host}"
    [[ -n "${CDN_RECORD_COMMENT:-}" ]] \
        || die "缺少归属注释 CDN_RECORD_COMMENT；拒绝写入 DNS：${host}"
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" '' "${host}") \
        || die "查询 Cloudflare 记录失败：${host}"
    conflicts=$(jq -r --arg type "${type}" \
        '[.[] | select(.type != $type) | .type] | unique | join(",")' <<<"${records}") \
        || die "解析 Cloudflare 记录失败：${host}"
    [[ -z "${conflicts}" ]] \
        || die "Cloudflare ${host} 已有其他类型的记录（${conflicts}）；请先清理冲突记录后重试"
    count=$(jq 'length' <<<"${records}")
    payload=$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
        --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
        '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')
    if ((count == 0)); then
        cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${payload}" >/dev/null
        return 0
    fi
    ((count == 1)) \
        || die "Cloudflare 存在 ${count} 条同名记录，无法判断归属：${host}"
    id=$(jq -r '.[0].id' <<<"${records}")
    comment=$(jq -r '.[0].comment // empty' <<<"${records}")
    current=$(jq -r '.[0].content // empty' <<<"${records}")
    current_proxied=$(jq -r '.[0] | if has("proxied") then (.proxied|tostring) else "" end' <<<"${records}")
    current_ttl=$(jq -r '.[0].ttl // empty' <<<"${records}")
    if [[ "${comment}" == "${CDN_RECORD_COMMENT}" \
        && "${current}" == "${content}" && "${current_proxied}" == "${proxied}" ]]; then
        return 0
    fi
    if [[ "${comment}" != "${CDN_RECORD_COMMENT}" ]]; then
        safe_comment=$(dns_record_field_text "${comment}")
        dns_confirm_takeover "${host}" "${safe_comment:-空}" "${current}" "${current_proxied}"
        # 确认可能等几十秒：写入前重读并核对整条记录（id/type/content/proxied/comment/ttl）。
        # 任一项变了就说明期间被别人改过，此时覆盖它等于拿走未经验证的新值。
        reread=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" '' "${host}") \
            || die "重新读取 Cloudflare 记录失败：${host}；已取消接管"
        if [[ "$(jq -r 'length' <<<"${reread}")" != "1" ]] \
            || [[ "$(jq -r '.[0].id // empty' <<<"${reread}")" != "${id}" ]] \
            || [[ "$(jq -r '.[0].type // empty' <<<"${reread}")" != "${type}" ]] \
            || [[ "$(jq -r '.[0].content // empty' <<<"${reread}")" != "${current}" ]] \
            || [[ "$(jq -r '.[0] | if has("proxied") then (.proxied|tostring) else "" end' <<<"${reread}")" != "${current_proxied}" ]] \
            || [[ "$(jq -r '.[0].comment // empty' <<<"${reread}")" != "${comment}" ]] \
            || [[ "$(jq -r '.[0].ttl // empty' <<<"${reread}")" != "${current_ttl}" ]]; then
            die "Cloudflare ${host} 的记录在确认期间被修改或被替换；已取消接管，请重新执行"
        fi
        dns_takeover_record "${host}" "${comment}" "${current}" "${current_proxied}" "${current_ttl}"
        takeover=1
    fi
    cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" "${payload}" >/dev/null
    ((takeover == 0)) || warn "已强制接管 Cloudflare 记录：${host}"
}

validate_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *[[:cntrl:]]* ]]
}

cdn_node_name_reserved() {
    local name=$1 reserved
    for reserved in "${LOCAL_AGGREGATION_RESERVED_NAMES[@]}"; do
        [[ "${name}" != "${reserved}" ]] || return 0
    done
    return 1
}

cdn_local_node_names() {
    local names='[]'
    if runtime_has_direct_entry; then
        names=$(jq -cn --arg name "${DIRECT_NODE_NAME}" '[$name]')
    fi
    if runtime_has_cdn_entry; then
        names=$(jq -cn --argjson direct "${names}" --arg cloud "${CF_NODE_PREFIX}" \
            '$direct + [$cloud]')
    fi
    printf '%s\n' "${names}"
}

cdn_validate_local_node_names() {
    local names cloud name
    names=$(cdn_local_node_names) || return 1
    jq -e 'type == "array" and all(.[]; type == "string") and (length == (unique | length))' \
        <<<"${names}" >/dev/null || {
        printf '本机节点名无效或重复\n' >&2
        return 1
    }
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        validate_node_name "${name}" || {
            printf '节点名无效：%s\n' "${name}" >&2
            return 1
        }
        cdn_node_name_reserved "${name}" && {
            printf '节点名不能使用保留组名：%s\n' "${name}" >&2
            return 1
        }
    done < <(jq -r '.[]' <<<"${names}")
    return 0
}

cdn_apply_subscription_config() {
    apply_local_aggregation_config "${1:-}" "$(cdn_local_node_names)" || return 1
    OWNER_TOKEN=$(jq -er '.allowedTokens | to_entries[0].value' <<<"${SUBSCRIPTION_CONFIG}") || return 1
}

cdn_sync_config_tokens() {
    local configured
    [[ -n "${SUBSCRIPTION_CONFIG:-}" && -n "${ALLOWED_TOKENS:-}" ]] || return 0
    configured=$(jq -c '.allowedTokens // empty' <<<"${SUBSCRIPTION_CONFIG}" 2>/dev/null) || return 0
    [[ "${configured}" == "${ALLOWED_TOKENS}" ]] && return 0
    SUBSCRIPTION_CONFIG=$(jq -c --argjson t "${ALLOWED_TOKENS}" \
        '.allowedTokens = $t' <<<"${SUBSCRIPTION_CONFIG}") || return 1
}

cdn_config_ready() {
    cdn_validate_local_node_names || return 1
    cdn_sync_config_tokens || return 1
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG:-}" >/dev/null 2>&1
}

cdn_require_valid_subscription() {
    cdn_config_ready && return 0
    die "订阅配置无效（需 allowedTokens 与 nodes；节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru）；请先执行 sudo easy_all edit-sub 重新配置"
}

cdn_validate_install_owner_token() {
    cdn_validate_local_node_names || die "本机节点名与保留组名冲突"
    cdn_config_ready && return 0
    die "订阅配置无效：allowedTokens 需为 8-128 位 URL 安全字符的 {\"用户\":\"token\"} 字典；nodes 仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
}

state_variables_for_installed_protocol() {
    local protocol subscription_mode
    protocol=$(state_file_value "${STATE_FILE}" PROTOCOL || true)
    subscription_mode=$(state_file_value "${STATE_FILE}" SUBSCRIPTION_MODE || true)
    state_required_fields "${protocol}" "${subscription_mode:-deploy}"
}

cdn_validate_state_structure() {
    local protocol=${PROTOCOL:-} field value domain
    state_protocol_valid "${protocol}" \
        || die "状态协议无法识别：${protocol:-缺失}；请先执行 sudo easy_all uninstall 后重新安装"
    while IFS= read -r field; do
        declare -p "${field}" >/dev/null 2>&1 \
            || die "状态缺少必需字段：${field}；请先执行 sudo easy_all uninstall 后重新安装"
        value=${!field:-}
        [[ -n "${value}" ]] \
            || state_field_allows_empty "${protocol}" "${SUBSCRIPTION_MODE:-deploy}" \
                "${field}" "${SCHEDULED_REBOOT_ENABLED:-0}" \
            || die "状态缺少必需字段：${field}；请先执行 sudo easy_all uninstall 后重新安装"
    done < <(state_required_fields "${protocol}" "${SUBSCRIPTION_MODE:-deploy}")
    validate_domain "${CF_ZONE}" || die "状态中的 CF_ZONE 无效：${CF_ZONE}"
    [[ -n "${CLOUDFLARE_ZONE_ID}" && "${CLOUDFLARE_ZONE_ID}" != *[[:space:]]* ]] \
        || die "状态中的 Cloudflare Zone ID 无效"
    case "${SUBSCRIPTION_MODE}" in
    deploy | link) ;;
    *) die "状态中的 SUBSCRIPTION_MODE 无效：${SUBSCRIPTION_MODE}" ;;
    esac
    if runtime_has_direct_entry; then
        validate_domain "${DIRECT_DOMAIN}" || die "状态中的直连域名无效：${DIRECT_DOMAIN}"
        validate_node_name "${DIRECT_NODE_NAME}" || die "状态中的直连节点名无效：${DIRECT_NODE_NAME}"
        [[ ${#ANYTLS_PASSWORD} -ge 16 ]] || die "状态中的 AnyTLS 密码过短"
    fi
    if runtime_has_cdn_entry; then
        validate_domain "${CF_NODE_DOMAIN}" || die "状态中的节点域名无效：${CF_NODE_DOMAIN}"
        validate_uuid "${VLESS_UUID}" || die "状态中的 VLESS UUID 无效"
        validate_vless_path "${VLESS_PATH}" || die "状态中的 VLESS 路径无效：${VLESS_PATH}"
    fi
    if state_protocol_uses_cloudfront "${protocol}"; then
        [[ "${CDN_TRAFFIC_PROTECTION_GB}" == "985" ]] \
            || die "状态中的 CDN 保护额度不是固定 985GB；请先执行 sudo easy_all uninstall 后重新安装"
        [[ "${AWS_ACM_CERTIFICATE_ARN}" == arn:aws:acm:us-east-1:* ]] \
            || die "ACM 证书 ARN 必须位于 us-east-1：${AWS_ACM_CERTIFICATE_ARN}"
        [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            || die "状态中的源站头密钥无效"
        for domain in "${CF_ORIGIN_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
            validate_domain "${domain}" || die "状态中的域名无效：${domain}"
            [[ "${domain}" == *".${CF_ZONE}" ]] \
                || die "状态中的域名不属于 ${CF_ZONE}：${domain}"
        done
        [[ "${CF_ORIGIN_DOMAIN}" != "${CF_NODE_DOMAIN}" ]] \
            || die "状态中的源站域名不得等于节点域名"
        [[ "${CF_ORIGIN_DOMAIN}" != "${SUBSCRIPTION_DOMAIN}" ]] \
            || die "状态中的源站域名不得等于订阅域名"
    fi
    if [[ "${protocol}" == "anytls" ]]; then
        validate_domain "${DIRECT_DOMAIN}" || die "状态中的直连域名无效：${DIRECT_DOMAIN}"
        if subscription_enabled; then
            validate_domain "${SUBSCRIPTION_DOMAIN}" \
                || die "状态中的订阅域名无效：${SUBSCRIPTION_DOMAIN}"
        fi
    fi
    if [[ "${protocol}" == "combined-cloudflare" ]]; then
        validate_domain "${CF_NODE_DOMAIN}" || die "状态中的节点域名无效：${CF_NODE_DOMAIN}"
        [[ "${CF_NODE_DOMAIN}" == *".${CF_ZONE}" ]] \
            || die "状态中的节点域名不属于 ${CF_ZONE}：${CF_NODE_DOMAIN}"
        [[ "${CF_NODE_DOMAIN}" != "${DIRECT_DOMAIN}" ]] \
            || die "状态中的节点域名不得等于直连域名：${CF_NODE_DOMAIN}"
        [[ "${SUBSCRIPTION_MODE}" == "deploy" ]] \
            || die "状态中的订阅模式无效（模式 5 固定 deploy）：${SUBSCRIPTION_MODE}"
    fi
    cdn_derive_runtime_fields || die "状态缺少可用于派生运行时的字段"
}

load_state() {
    local variable protocol subscription_mode
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    protocol=$(state_file_value "${STATE_FILE}" PROTOCOL || true)
    subscription_mode=$(state_file_value "${STATE_FILE}" SUBSCRIPTION_MODE || true)
    if ! state_file_has_field "${STATE_FILE}" STATE_VERSION; then
        die "$(state_damaged_state_message "${STATE_FILE}")"
    fi
    unset STATE_VERSION
    while IFS= read -r variable; do
        unset "${variable}" 2>/dev/null || true
    done < <(state_required_fields "${protocol:-}" "${subscription_mode:-deploy}" 2>/dev/null || true)
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    state_schema_supported "${STATE_VERSION:-}" \
        || die "$(state_legacy_rejection_message "${STATE_VERSION:-缺失}")"
    [[ "${PROTOCOL:-}" == "${CDN_EXPECTED_PROTOCOL}" ]] \
        || die "状态协议不是 ${CDN_EXPECTED_PROTOCOL}；请先执行 sudo easy_all uninstall 后重新安装"
    cdn_validate_state_structure
    # 订阅配置损坏只告警：结构状态与 usage 仍可用于安全恢复、编辑与卸载。
    CDN_SUBSCRIPTION_CORRUPT=0
    if ! cdn_config_ready >/dev/null 2>&1; then
        CDN_SUBSCRIPTION_CORRUPT=1
        warn "状态文件中的订阅配置损坏；请执行 sudo easy_all edit-sub 重新配置"
    fi
}

collect_installed_state() {
    load_state
}

save_state() {
    local temp
    local -a fields
    install -d -m 0700 "${STATE_DIR}"
    cdn_sync_config_tokens || true
    while IFS= read -r field; do
        fields+=("${field}")
    done < <(state_required_fields "${PROTOCOL}" "${SUBSCRIPTION_MODE:-deploy}")
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") || die "创建状态暂存文件失败"
    cleanup_files+=("${temp}")
    state_render "${temp}" "${fields[@]}" || die "写入状态暂存文件失败"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${STATE_FILE}" || die "原子替换状态文件失败"
}

# --- 安装前置与本地安全 -------------------------------------------------------

check_install_conflicts() {
    prepare_fresh_install "$(runtime_public_tcp_ports)" "$(runtime_cloudflare_only_port)" \
        "$(runtime_cdn_loopback_port)"
}

install_packages() {
    local pkgs=(
        ca-certificates curl wget gnupg jq unzip openssl dnsutils ufw
        fail2ban python3-systemd socat cron iproute2 iputils-ping tzdata
        systemd-timesyncd tar util-linux sudo vim iptables certbot
        python3-certbot-dns-cloudflare
    )
    if packages_already_installed "${pkgs[@]}"; then
        info "系统基础依赖包已全部安装，跳过 APT 索引更新与包安装"
    else
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 upgrade -y
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends "${pkgs[@]}"
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

# 按模式放行公网端口；橙云与模式 1 的订阅端口只允许 Cloudflare 官方 IPv4 段。
configure_runtime_ufw() {
    local public_ports cf_port desired_ports
    snapshot_ufw_state
    snapshot_platform_security_state
    ensure_ssh_boot_service
    detect_ssh_ports strict
    verify_ssh_ufw_no_unmanaged_block "${SSH_PORTS}"
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null || die "设置 UFW 默认入站策略失败"
    ufw default allow outgoing >/dev/null || die "设置 UFW 默认出站策略失败"
    ufw default deny routed >/dev/null || die "设置 UFW 默认转发策略失败"
    public_ports=$(runtime_public_tcp_ports)
    desired_ports="$(printf '%s\n' "${SSH_PORTS}" ${public_ports} | tr '\n' ' ')"
    apply_ssh_ufw_policy "${desired_ports}" "${SSH_PORTS}"
    cf_port=$(runtime_cloudflare_only_port)
    if [[ -n "${cf_port}" ]]; then
        # 无有效白名单或缓存即停止（design §2 I），不扩大为公网放行。
        CLOUDFLARE_UFW_PORT=${cf_port}
        CLOUDFLARE_UFW_COMMENT="easy_all-cf-origin-${cf_port}"
        CLOUDFLARE_ORIGIN_IPS_FILE="${STATE_DIR}/cloudflare-origin-ipv4-${cf_port}.txt"
        cloudflare_configure_origin_firewall
    fi
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

# --- 证书（design §6） -------------------------------------------------------

certificate_required_hosts() {
    # 同一域名复用（如模式 4 的直连域名等于源站域名）只保留一个 -d；域名顺序不影响签发与展示。
    {
        if runtime_has_direct_entry; then
            printf '%s\n' "${DIRECT_DOMAIN}"
        fi
        if [[ "${PROTOCOL}" == "anytls" ]]; then
            if subscription_enabled; then
                printf '%s\n' "${SUBSCRIPTION_DOMAIN}"
            fi
        elif state_protocol_uses_cloudfront "${PROTOCOL}"; then
            printf '%s\n' "${CF_ORIGIN_DOMAIN}"
        elif [[ "${PROTOCOL}" == "combined-cloudflare" ]]; then
            # 模式 5 的橙云节点域名同时是订阅站点：同一个 LE 证书覆盖直连与回源。
            printf '%s\n' "${CF_NODE_DOMAIN}"
        fi
    } | sort -u
    # subscription_enabled 为假时上面的分支没有输出，显式返回成功（调用方 set -e）。
    return 0
}

certificate_san_hosts() {
    cloudflare_certificate_san_hosts "$1"
}

certificate_covers_host() {
    local cert=$1 host=$2 name
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        [[ "${name}" == "${host}" ]] && return 0
        if [[ "${name}" == "*."* ]] \
            && [[ "${host}" == *".${name#\*.}" ]] \
            && [[ "${host%".${name#\*.}"}" != *.* ]]; then
            return 0
        fi
    done < <(certificate_san_hosts "${cert}")
    return 1
}

certificate_covers_required_hosts() {
    local cert=$1 host
    [[ -s "${cert}" ]] || return 1
    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        certificate_covers_host "${cert}" "${host}" || return 1
    done < <(certificate_required_hosts)
}

certificate_key_matches() {
    local cert=${1:-${CERT_FILE}} key=${2:-${KEY_FILE}}
    local cert_pub key_pub
    [[ -s "${cert}" && -s "${key}" ]] || return 1
    # 直接比较公钥 PEM 并显式要求非空：拿管道结果哈希会把两侧命令同时失败的空输入
    # 判成同一个哈希，损坏/占位的证书与私钥会误判为匹配。
    cert_pub=$(openssl x509 -in "${cert}" -pubkey -noout 2>/dev/null) || return 1
    key_pub=$(openssl pkey -in "${key}" -pubout 2>/dev/null) || return 1
    [[ -n "${cert_pub}" && "${cert_pub}" == "${key_pub}" ]]
}

# 链校验必须是「leaf + 中间链 + 系统信任库」：Certbot 的 fullchain.pem 是
# leaf→intermediate 拼接，而 openssl verify 不会把目标文件后面的 PEM 当成链输入。
certificate_chain_valid() {
    local cert=${1:-${CERT_FILE}} bundle leaf intermediates workdir status=0
    [[ -s "${cert}" ]] || return 1
    bundle=${SSL_CERT_FILE:-}
    if [[ -z "${bundle}" ]]; then
        if [[ -f /etc/ssl/certs/ca-certificates.crt ]]; then
            bundle=/etc/ssl/certs/ca-certificates.crt
        elif [[ -f /etc/ssl/cert.pem ]]; then
            bundle=/etc/ssl/cert.pem
        fi
    fi
    [[ -n "${bundle}" ]] || return 1
    workdir=$(make_temp_dir) || return 1
    leaf="${workdir}/leaf.pem"
    intermediates="${workdir}/intermediates.pem"
    awk '/-----BEGIN CERTIFICATE-----/ {count++} count == 1' "${cert}" >"${leaf}" || status=1
    awk '/-----BEGIN CERTIFICATE-----/ {count++} count > 1' "${cert}" >"${intermediates}" || status=1
    if ((status == 0)); then
        chmod 0600 "${leaf}" "${intermediates}" 2>/dev/null || true
        [[ -s "${leaf}" ]] || status=1
    fi
    if ((status == 0)); then
        if [[ -s "${intermediates}" ]]; then
            openssl verify -CAfile "${bundle}" -untrusted "${intermediates}" "${leaf}" \
                >/dev/null 2>&1 || status=1
        else
            openssl verify -CAfile "${bundle}" "${leaf}" >/dev/null 2>&1 || status=1
        fi
    fi
    rm -rf -- "${workdir}"
    return "${status}"
}

certificate_check() {
    local cert=${1:-${CERT_FILE}} key=${2:-${KEY_FILE}}
    [[ -s "${cert}" ]] || { warn "证书不存在：${cert}"; return 1; }
    [[ -s "${key}" ]] || { warn "证书私钥不存在：${key}"; return 1; }
    openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1 \
        || { warn "证书已过期：${cert}"; return 1; }
    certificate_covers_required_hosts "${cert}" \
        || { warn "证书未覆盖模式所需域名：$(certificate_required_hosts | paste -sd, -)"; return 1; }
    certificate_key_matches "${cert}" "${key}" \
        || { warn "证书与私钥不配对"; return 1; }
    certificate_chain_valid "${cert}" || { warn "证书链验证失败"; return 1; }
}

certificate_verify() {
    certificate_check "${CERT_FILE}" "${KEY_FILE}" || die "本机证书验收失败；请执行 sudo easy_all renew-cert"
}

certbot_account_email_args() {
    # 基线使用无邮箱注册：保留同一行为，避免新增未记录的输入项。
    printf '%s\n' --register-unsafely-without-email
}

certbot_write_cloudflare_credentials() {
    local token=${CLOUDFLARE_API_TOKEN:-}
    [[ -n "${token}" ]] || die "缺少 Cloudflare API Token；无法执行 DNS-01 签发"
    install -d -m 0700 "${CERT_DIR}"
    install -d -m 0700 "$(dirname -- "${CLOUDFLARE_CREDENTIALS_FILE}")"
    (umask 077; printf 'dns_cloudflare_api_token = %s\n' "${token}" \
        >"${CLOUDFLARE_CREDENTIALS_FILE}") \
        || die "写入 Cloudflare DNS-01 凭据失败：${CLOUDFLARE_CREDENTIALS_FILE}"
    chmod 0600 "${CLOUDFLARE_CREDENTIALS_FILE}"
}

certbot_issue_certificate() {
    local force=${1:-0} host
    local -a args=(certonly --dns-cloudflare
        --dns-cloudflare-credentials "${CLOUDFLARE_CREDENTIALS_FILE}"
        --dns-cloudflare-propagation-seconds 30
        --cert-name "${CERTBOT_LINEAGE_NAME}"
        --non-interactive --agree-tos)
    command -v certbot >/dev/null 2>&1 || die "缺少 certbot；无法签发证书"
    [[ -s "${CLOUDFLARE_CREDENTIALS_FILE}" ]] \
        || die "缺少 Cloudflare DNS-01 凭据：${CLOUDFLARE_CREDENTIALS_FILE}"
    args+=("$(certbot_account_email_args)")
    [[ "${force}" != "1" ]] || args+=(--force-renewal)
    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        args+=(-d "${host}")
    done < <(certificate_required_hosts)
    info "通过 Cloudflare DNS-01 签发证书：$(certificate_required_hosts | paste -sd, -)"
    # 手动路径已持写锁：只让本次 certbot 子进程跳过自有 hook，由父命令在当前事务部署。
    EASY_ALL_CERTBOT_SKIP_DEPLOY=1 certbot "${args[@]}" \
        || die "Certbot DNS-01 证书签发失败；请确认 Cloudflare Token 具备 Zone:DNS:Edit 与 Zone:Zone:Read"
}

# --- 证书实际生效的运行时证据 ---------------------------------------------------

# 本机 TLS 握手里对端送达的证书 SHA256 指纹（小写）。握手失败返回非零。
runtime_tls_peer_fingerprint() {
    local host=$1 port=$2 output
    output=$(openssl s_client -connect "127.0.0.1:${port}" -servername "${host}" \
        </dev/null 2>/dev/null) || return 1
    output=$(printf '%s\n' "${output}" \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null) || return 1
    output=${output#*=}
    [[ "${output}" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    printf '%s\n' "${output}" | tr '[:upper:]' '[:lower:]'
}

runtime_certificate_fingerprint_on_disk() {
    local output
    output=$(openssl x509 -in "${CERT_FILE}" -noout -fingerprint -sha256 2>/dev/null) \
        || return 1
    output=${output#*=}
    [[ -n "${output}" ]] || return 1
    printf '%s\n' "${output}" | tr '[:upper:]' '[:lower:]'
}

# 需要验证的本机端点：AnyTLS 入站（443）与 Caddy 站点（存在时）。
runtime_served_certificate_endpoints() {
    if runtime_has_direct_entry; then
        printf '%s 443\n' "${DIRECT_DOMAIN:-}"
    fi
    if runtime_caddy_site_enabled; then
        printf '%s %s\n' "$(caddy_site_host 2>/dev/null)" "$(caddy_site_port 2>/dev/null)"
    fi
    return 0
}

# 服务实际送出的证书必须与磁盘一致：证书轮换只换文件、配置内容不变，
# Caddy/sing-box 可能仍持有旧证书；模式 3 的 Origin CA 吊销与 LE 续期都不得靠猜测。
runtime_served_certificate_matches_disk() {
    local host port expected actual attempt matched
    expected=$(runtime_certificate_fingerprint_on_disk) || return 1
    while IFS=' ' read -r host port; do
        [[ -n "${host}" && -n "${port}" ]] || continue
        matched=0
        for attempt in 1 2 3 4 5; do
            actual=$(runtime_tls_peer_fingerprint "${host}" "${port}" || true)
            if [[ "${actual}" == "${expected}" ]]; then
                matched=1
                break
            fi
            ((attempt == 5)) || sleep 1
        done
        ((matched == 1)) || {
            warn "TLS 对端未使用磁盘上的证书：${host}:${port}"
            return 1
        }
    done < <(runtime_served_certificate_endpoints)
    return 0
}

# 证书部署事务：先对候选文件做完整验收，再备份现用证书/私钥与运行配置，
# 安装后（apply_services=1 时）重启 sing-box、重载 Caddy 并跑可选验收；
# 任一步失败恢复备份并返回非零。首次安装传 0，由调用方在同一事务里启服务。
certificate_deploy() {
    local accept=${1:-} apply_services=${2:-1}
    local chain="${CERTBOT_LIVE_DIR}/fullchain.pem" key="${CERTBOT_LIVE_DIR}/privkey.pem"
    local backup had_cert=0 had_key=0
    [[ -s "${chain}" && -s "${key}" ]] || return 1
    install -d -m 0700 "${CERT_DIR}"
    backup=$(make_temp_dir) || return 1
    install -m 0644 "${chain}" "${backup}/fullchain.pem" || return 1
    install -m 0600 "${key}" "${backup}/privkey.pem" || return 1
    certificate_check "${backup}/fullchain.pem" "${backup}/privkey.pem" \
        || { warn "新证书未通过验收；保留现用证书与 Certbot lineage"; return 1; }
    if [[ -f "${CERT_FILE}" ]]; then
        had_cert=1
        install -m 0644 "${CERT_FILE}" "${backup}/previous-cert.pem" || return 1
    fi
    if [[ -f "${KEY_FILE}" ]]; then
        had_key=1
        install -m 0600 "${KEY_FILE}" "${backup}/previous-key.pem" || return 1
    fi
    if (
        install -m 0644 "${backup}/fullchain.pem" "${CERT_FILE}" || exit 1
        install -m 0600 "${backup}/privkey.pem" "${KEY_FILE}" || exit 1
        certificate_verify || exit 1
        # 首次安装时运行配置还没发布：由调用方在同一事务里启服务，这里不做服务动作。
        [[ "${apply_services}" != "1" ]] || runtime_apply_runtime_services 1 || exit 1
        # 新证书必须真的能被本机 TLS 握手送达，否则恢复旧副本（由调用方/此处回滚）。
        [[ "${apply_services}" != "1" ]] || runtime_served_certificate_matches_disk || exit 1
        [[ -z "${accept}" ]] || "${accept}" || exit 1
    ); then
        rm -rf -- "${backup}"
        return 0
    fi
    warn "证书部署失败，恢复部署前的证书与私钥"
    if ((had_cert == 1)); then
        install -m 0644 "${backup}/previous-cert.pem" "${CERT_FILE}" \
            || warn "恢复现用证书失败；请执行 sudo easy_all renew-cert"
    else
        rm -f -- "${CERT_FILE}"
    fi
    if ((had_key == 1)); then
        install -m 0600 "${backup}/previous-key.pem" "${KEY_FILE}" \
            || warn "恢复现用证书私钥失败；请执行 sudo easy_all renew-cert"
    else
        rm -f -- "${KEY_FILE}"
    fi
    [[ "${apply_services}" != "1" ]] \
        || runtime_apply_runtime_services 1 \
        || warn "恢复证书后未能重建服务；请执行 sudo easy_all apply"
    rm -rf -- "${backup}"
    return 1
}

certificate_lineage_is_newer() {
    local chain="${CERTBOT_LIVE_DIR}/fullchain.pem"
    [[ -s "${chain}" ]] || return 1
    certificate_check "${chain}" "${CERTBOT_LIVE_DIR}/privkey.pem" >/dev/null 2>&1 || return 1
    if [[ -s "${CERT_FILE}" ]] && cmp -s "${chain}" "${CERT_FILE}"; then
        return 1
    fi
    return 0
}

certbot_deploy_hook_script() {
    printf '#!/usr/bin/env bash\n'
    printf 'set -Eeuo pipefail\n'
    printf '# 手动 renew-cert/apply 持锁时由父命令完成部署，避免 hook 二次抢锁。\n'
    printf '[[ "${EASY_ALL_CERTBOT_SKIP_DEPLOY:-0}" == "1" ]] && exit 0\n'
    printf 'exec %q internal-cert-deploy\n' "${COMMAND_PATH}"
}

install_certbot_deploy_hook() {
    install -d -m 0700 "$(dirname -- "${CERTBOT_DEPLOY_HOOK_FILE}")"
    certbot_deploy_hook_script >"${RUNTIME_TMP}/easy-all-deploy-hook.sh" \
        || die "写入 Certbot 部署 hook 失败"
    install -m 0700 "${RUNTIME_TMP}/easy-all-deploy-hook.sh" "${CERTBOT_DEPLOY_HOOK_FILE}" \
        || die "安装 Certbot 部署 hook 失败：${CERTBOT_DEPLOY_HOOK_FILE}"
}

remove_certbot_deploy_hook() {
    rm -f -- "${CERTBOT_DEPLOY_HOOK_FILE}"
}

certificate_remove_lineage() {
    local etc_dir
    etc_dir=$(dirname -- "$(dirname -- "${CERTBOT_LIVE_DIR}")")
    rm -rf -- "${CERTBOT_LIVE_DIR}" \
        "${etc_dir}/archive/${CERTBOT_LINEAGE_NAME}" \
        "${etc_dir}/renewal/${CERTBOT_LINEAGE_NAME}.conf"
}

# --- 配置发布与服务 -----------------------------------------------------------

# 共享实现只以 runtime_write_config 命名：四个模式库各自提供同名包装器
# write_runtime_config，由包装器派生本模式的 blocked/订阅就绪状态后调用它。
runtime_write_config() {
    local blocked=${1:-0} subscription_ok=${2:-0}
    write_singbox_config "${blocked}"
    if runtime_caddy_site_enabled; then
        write_caddy_config "${blocked}" "${subscription_ok}"
    fi
}

runtime_ensure_singbox_service() {
    install_singbox_service "$(runtime_singbox_exec_start_pre)"
}

# 同步启动/重启只能在已释放计量锁的前提下调用（design §10 锁序）。
# 第一参数为 1 时 Caddy 使用 --force 重载：证书轮换只换文件、配置内容不变。
# 第二参数为 1 时重启 Caddy 进程：reload 只在运行中的进程内换配置，磁盘上的新二进制
# 必须重启才会被执行（update-core 的核心替换依赖这一点）。
runtime_apply_runtime_services() {
    local caddy_reload_force=${1:-1} caddy_restart=${2:-0}
    runtime_ensure_singbox_service
    if runtime_caddy_site_enabled; then
        install_caddy_service
    fi
    # 两个单元的写入都必须先于重读：daemon-reload 之后的单元改动 systemd 不会重读，
    # 它继续用内存里的旧定义——新增的 ExecStartPre 守卫会被静默跳过。
    systemctl daemon-reload || die "重新加载 systemd 单元失败"
    # 只 enable：紧随其后的 restart 就是启动。enable --now 会在毫秒内把同一单元启动两次，
    # 无意义地消耗 StartLimitBurst=3/120s。Caddy 冷启动同样先 enable，再单次 start。
    systemctl enable "${SINGBOX_SERVICE}" >/dev/null 2>&1 || true
    systemctl restart "${SINGBOX_SERVICE}" || die "重启 sing-box 服务失败"
    if runtime_caddy_site_enabled; then
        if [[ "${caddy_restart}" == "1" ]]; then
            systemctl enable "${CADDY_SERVICE}" >/dev/null 2>&1 || true
            systemctl restart "${CADDY_SERVICE}" || die "重启 Caddy 服务失败"
        elif systemctl is-active --quiet "${CADDY_SERVICE}" 2>/dev/null; then
            reload_caddy "${caddy_reload_force}"
        else
            # 冷启动只发一次启动请求：enable --now 会把同一单元立刻启动两次，
            # 一次故障就消耗掉 StartLimitBurst=3/120s 的两次机会。
            systemctl enable "${CADDY_SERVICE}" >/dev/null 2>&1 || true
            systemctl start "${CADDY_SERVICE}" >/dev/null 2>&1 || die "启动 Caddy 服务失败"
        fi
    else
        # link 模式不建立订阅站点：不启动 Caddy。
        systemctl disable --now "${CADDY_SERVICE}" >/dev/null 2>&1 || true
    fi
}

runtime_reload_caddy() {
    runtime_caddy_site_enabled || return 0
    reload_caddy
}

# --- 本机验收 -----------------------------------------------------------------

# 本机探活参数：模式可提供自有 CA（模式 3 的 Origin CA）与源站守卫头。
# 严格 TLS 校验始终保持，禁止 -k。
runtime_local_probe_context() {
    RUNTIME_PROBE_HOST=$(caddy_site_host 2>/dev/null || true)
    RUNTIME_PROBE_PORT=$(caddy_site_port 2>/dev/null || printf '443\n')
    RUNTIME_PROBE_HEADER_FILE=""
    RUNTIME_PROBE_ARGS=(--proto '=https' --noproxy '*' -s
        --connect-timeout 5 --max-time 20)
    if caddy_protocol_needs_origin_guard 2>/dev/null; then
        RUNTIME_PROBE_HEADER_FILE="${RUNTIME_TMP}/origin-header"
        install -d -m 0700 "${RUNTIME_TMP}"
        (umask 077; printf 'X-Easy-All-Origin-Key: %s\n' "${ORIGIN_HEADER_SECRET:-}" \
            >"${RUNTIME_PROBE_HEADER_FILE}")
        RUNTIME_PROBE_ARGS+=(--header "@${RUNTIME_PROBE_HEADER_FILE}")
    fi
    if declare -F runtime_probe_ca_file >/dev/null 2>&1; then
        local ca
        ca=$(runtime_probe_ca_file 2>/dev/null || true)
        [[ -z "${ca}" || ! -s "${ca}" ]] || RUNTIME_PROBE_ARGS+=(--cacert "${ca}")
    fi
}

# 额外参数（-D/-A/--head）由调用方追加，保持它们落在 URL 之前。
runtime_local_curl() {
    local path=$1
    shift
    curl "${RUNTIME_PROBE_ARGS[@]}" "$@" \
        --resolve "${RUNTIME_PROBE_HOST}:${RUNTIME_PROBE_PORT}:127.0.0.1" \
        "https://${RUNTIME_PROBE_HOST}:${RUNTIME_PROBE_PORT}${path}"
}

runtime_local_status() {
    local path=$1
    curl "${RUNTIME_PROBE_ARGS[@]}" -o /dev/null -w '%{http_code}' \
        --resolve "${RUNTIME_PROBE_HOST}:${RUNTIME_PROBE_PORT}:127.0.0.1" \
        "https://${RUNTIME_PROBE_HOST}:${RUNTIME_PROBE_PORT}${path}"
}

# 已发布的候选配置里是否还有 CDN 入站：blocked 时渲染器省略该入站（design §7）。
# 读不到配置时按模式要求（宁可验收更严格），不能因读失败就放宽验收。
runtime_config_has_cdn_inbound() {
    local config=${1:-${SINGBOX_CONFIG:-}}
    [[ -s "${config}" ]] || return 0
    jq -e 'any(.inbounds[]?; .tag == "vless-cdn-in")' "${config}" >/dev/null 2>&1
}

# 必需监听端口按候选配置派生：受限（blocked）时不要求 10086，模式 4 仍要求 443。
runtime_singbox_required_ports() {
    local ports=""
    runtime_has_direct_entry && ports="443"
    if runtime_has_cdn_entry && runtime_config_has_cdn_inbound; then
        ports="${ports} $(runtime_cdn_loopback_port)"
    fi
    printf '%s\n' "${ports# }"
}

# sing-box 入站与 Caddy 站点分别验收：Caddy health 不能替代核心入站断言。
validate_protocol_runtime() {
    local attempt port response
    for attempt in 1 2 3 4 5; do
        if systemctl is-active --quiet "${SINGBOX_SERVICE}" 2>/dev/null \
            && runtime_ports_listening; then
            if ! runtime_caddy_site_enabled; then
                return 0
            fi
            if systemctl is-active --quiet "${CADDY_SERVICE}" 2>/dev/null; then
                runtime_local_probe_context
                response=$(runtime_local_curl /easy_all-health || true)
                [[ "${response}" == "easy_all ok" ]] && return 0
            fi
        fi
        sleep 2
    done
    port=$(runtime_singbox_required_ports)
    warn "sing-box 必需监听端口：${port:-无}"
    die "本机运行时验收失败（sing-box ${SINGBOX_SERVICE} / Caddy ${CADDY_SERVICE}）"
}

runtime_ports_listening() {
    local port
    [[ -n "$(runtime_singbox_required_ports)" ]] || return 0
    for port in $(runtime_singbox_required_ports); do
        ss -H -ltn "sport = :${port}" 2>/dev/null | awk 'NR {found=1} END {exit !found}' \
            || return 1
    done
    return 0
}

runtime_base64_markers() {
    runtime_has_direct_entry && printf 'anytls://\n'
    runtime_has_cdn_entry && printf 'type=ws\n'
    return 0
}

runtime_mihomo_markers() {
    runtime_has_direct_entry && printf 'type: anytls\n'
    runtime_has_cdn_entry && printf 'network: ws\n'
    return 0
}

runtime_primary_node_name() {
    if runtime_has_direct_entry; then
        printf '%s\n' "${DIRECT_NODE_NAME:-AnyTLS}"
    else
        printf '%s\n' "${CF_NODE_PREFIX:-VLESS-WS}"
    fi
}

validate_subscription_runtime() {
    local token base64_response decoded mihomo_response status marker
    runtime_caddy_site_enabled || return 0
    runtime_local_probe_context
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}") || die "订阅 Token 字典为空"
    base64_response=$(runtime_local_curl "/subscribe?token=${token}") \
        || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    decoded=$(printf '%s' "${base64_response}" | openssl base64 -d -A 2>/dev/null) \
        || die "通用订阅响应不是有效的 Base64"
    while IFS= read -r marker; do
        [[ -n "${marker}" ]] || continue
        grep -Fq -- "${marker}" <<<"${decoded}" \
            || die "通用订阅响应缺少节点标记：${marker}"
    done < <(runtime_base64_markers)
    mihomo_response=$(runtime_local_curl "/subscribe?flag=clash&token=${token}") \
        || die "Mihomo 订阅本机验收失败"
    while IFS= read -r marker; do
        [[ -n "${marker}" ]] || continue
        grep -Fq -- "${marker}" <<<"${mihomo_response}" \
            || die "Mihomo 订阅响应缺少节点标记：${marker}"
    done < <(runtime_mihomo_markers)
    validate_subscription_token_rejection \
        "${RUNTIME_PROBE_HOST}:${RUNTIME_PROBE_PORT}:127.0.0.1" \
        "https://${RUNTIME_PROBE_HOST}:${RUNTIME_PROBE_PORT}/subscribe" \
        "${RUNTIME_PROBE_ARGS[@]}"
    status=$(runtime_local_status /easy_all-subscribd || true)
    [[ "${status}" == "404" ]] || die "未知订阅路径必须返回 404（HTTP ${status}）"
}

# sing-box 完整 JSON 订阅的本机验收：flag 与已确认客户端 UA 都必须拿到 JSON，
# 且显式 YAML flag 仍然优先。CDN 流量保护的既有六产物门禁不受它影响。
validate_singbox_subscription_runtime() {
    local token headers_file body ua_body all_body status disposition expected client
    runtime_caddy_site_enabled || return 0
    runtime_local_probe_context
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}") || die "订阅 Token 字典为空"
    headers_file="${RUNTIME_TMP}/singbox-subscription.headers"
    body=$(runtime_local_curl "/subscribe?flag=singbox&token=${token}" -D "${headers_file}") \
        || die "sing-box 订阅本机验收失败"
    jq -e . >/dev/null 2>&1 <<<"${body}" || die "sing-box 订阅响应不是有效 JSON"
    grep -Eqi '^content-type: application/json' "${headers_file}" \
        || die "sing-box 订阅 Content-Type 无效"
    disposition=$(grep -i '^content-disposition:' "${headers_file}" | tr -d '\r' || true)
    [[ "${disposition}" == *"filename=${SUB_DOWNLOAD_NAME}.json"* ]] \
        || die "sing-box 订阅下载文件名无效：${disposition:-空}"
    expected=$(cdn_local_node_names)
    jq -e --argjson expected "${expected}" '
        [.outbounds[].tag] as $tags
        | all($expected[]; . as $tag | $tags | index($tag) != null)
    ' >/dev/null <<<"${body}" || die "sing-box 订阅缺少本机节点：${expected}"
    jq -e '
        (.route.final | type) == "string" and (.route.rules | length) > 0
        and (.route.rule_set | length) > 0
        and (.dns.servers | length) > 0 and (.dns.rules | length) > 0
    ' >/dev/null <<<"${body}" || die "sing-box 订阅缺少 DNS 或分流规则"
    # 已核实的 SFA/SFI/SFM/SFT/SFW/SFL 请求形式必须在没有 flag 时逐家自动拿到同一份 JSON。
    for client in SFA SFI SFM SFT SFW SFL; do
        ua_body=$(runtime_local_curl "/subscribe?token=${token}" \
            -A "${client} (sing-box 1.14.4; language zh_CN)") \
            || die "sing-box ${client} UA 自动识别验收失败"
        [[ "${ua_body}" == "${body}" ]] \
            || die "${client} 的 sing-box 客户端 UA 未获得完整 JSON 订阅"
    done
    # 显式 flag 覆盖 UA：SFA UA 携带 flag=clash 必须仍是 YAML。
    ua_body=$(runtime_local_curl "/subscribe?flag=clash&token=${token}" \
        -A 'SFA (sing-box 1.14.4; language zh_CN)') || die "订阅 flag 覆盖验收失败"
    grep -Fq -- 'proxies:' <<<"${ua_body}" \
        || die "显式 flag=clash 未覆盖 sing-box 客户端 UA"
    if subscription_optional_variants; then
        expected=$(singbox_supported_optional_tags)
        all_body=$(runtime_local_curl "/subscribe?flag=singbox&node=all&token=${token}") \
            || die "sing-box node=all 订阅验收失败"
        jq -e --argjson expected "${expected}" '
            [.outbounds[].tag] as $tags
            | all($expected[]; . as $tag | $tags | index($tag) != null)
        ' >/dev/null <<<"${all_body}" \
            || die "node=all 未包含受支持的 optional 聚合节点：${expected}"
        jq -e --argjson expected "${expected}" '
            [.outbounds[].tag] as $tags
            | all($expected[]; . as $tag | $tags | index($tag) == null)
        ' >/dev/null <<<"${body}" || die "默认 sing-box 订阅不应包含 optional 聚合节点"
        # expected 为空时上面两条 all() 恒真，改为断言两份产物一致：没有可选节点时渲染结果必然相同。
        if [[ "${expected}" == "[]" ]]; then
            [[ "${all_body}" == "${body}" ]] \
                || die "无可选聚合节点时 node=all 订阅必须与默认订阅一致"
        fi
    fi
    runtime_local_curl "/subscribe?flag=singbox&token=${token}" --head \
        | grep -Eq '^HTTP/[0-9.]+ 200' || die "sing-box 订阅 HEAD 请求未返回 200"
    status=$(runtime_local_status /singbox.json || true)
    [[ "${status}" == "404" ]] || die "裸文件访问 sing-box 订阅必须返回 404（HTTP ${status}）"
}

# --- 订阅渲染与发布 -----------------------------------------------------------

runtime_require_subscription_hooks() {
    local hook
    for hook in build_node_links build_mihomo_nodes \
        build_mihomo_proxy_groups build_mihomo_proxy_names; do
        declare -F "${hook}" >/dev/null 2>&1 \
            || die "Profile 缺少订阅渲染钩子：${hook}"
    done
}

subscription_optional_variants() {
    [[ "${SUBSCRIPTION_OPTIONAL_VARIANTS:-0}" == "1" ]]
}

# 渲染六种 Mihomo/Base64 产物；发布与就绪验收复用同一渲染器，不生成 sing-box JSON。
render_mihomo_base64_files() {
    local output_dir=$1 template node_file group_file name_file
    local mihomo_file suffix include variants marker
    variants=0
    subscription_optional_variants && variants=1
    prepare_mihomo_template
    runtime_require_subscription_hooks
    template=${MIHOMO_TEMPLATE_FILE}
    node_file="${RUNTIME_TMP}/mihomo-node.yaml"
    group_file="${RUNTIME_TMP}/mihomo-groups.yaml"
    name_file="${RUNTIME_TMP}/mihomo-names.yaml"
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
            "$(runtime_primary_node_name)" "${group_file}" "${name_file}"
        while IFS= read -r marker; do
            [[ -n "${marker}" ]] || continue
            grep -Fq -- "${marker}" "${mihomo_file}" || die "Mihomo 订阅缺少有效节点：${marker}"
        done < <(runtime_mihomo_markers)
        strip_mihomo_sniffer "${mihomo_file}" >"${output_dir}/mihomo-ios${suffix}.yaml" \
            || die "暂存 iOS Mihomo 订阅失败"
    done
    EASY_ALL_INCLUDE_OPTIONAL=0
    chmod 0600 "${output_dir}"/*.txt "${output_dir}"/*.yaml
}

# 渲染八份订阅产物：六份 Mihomo/Base64 加 sing-box 完整 JSON；
# JSON 候选校验失败即中止发布，已发布的旧订阅保持不变。
render_subscription_files() {
    local output_dir=$1
    render_mihomo_base64_files "${output_dir}"
    render_singbox_subscription_files "${output_dir}"
}

write_subscriptions() {
    local stage_dir
    install -d -m 0700 "$(dirname -- "${SUBSCRIPTION_DIR}")"
    stage_dir=$(mktemp -d "${RUNTIME_TMP}/.subscriptions.stage.XXXXXX") \
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
    printf '%s\n' '  同一链接按客户端自动下发：sing-box（SFA/SFI/SFM/SFT/SFW/SFL）→ 完整 JSON；Clash/mihomo/Stash/FlClash → YAML；Shadowrocket/v2rayN/v2rayNG/NekoBox → Base64'
    printf '%s\n' '  如需强制格式：在链接后加 &flag=singbox、&flag=clash 或 &flag=base64'
    if [[ ! -s "${SUBSCRIPTION_DIR}/singbox.json" || ! -s "${SUBSCRIPTION_DIR}/singbox-all.json" ]]; then
        printf '%s\n' '  sing-box JSON 订阅不完整：请执行 sudo easy_all apply 后再导入'
    fi
    if subscription_optional_variants \
        && jq -e 'any(.[]; .optional == true)' <<<"${AGGREGATION_NODES:-[]}" >/dev/null 2>&1; then
        printf '%s\n' '  追加 &node=all 可显示标记为 optional 的聚合节点'
    fi
    printf '%s\n' '  iOS 客户端（UA 命中 iphone/ipad/ipod/ios，或链接加 &os=ios）下发的 YAML 不带嗅探段'
    printf '\n'
}

snapshot_subscription_update() {
    UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
    [[ -f "${STATE_FILE}" ]] && install -m 0600 "${STATE_FILE}" "${UPDATE_SUB_BACKUP_DIR}/state.env"
    if [[ -f "${SINGBOX_CONFIG}" ]]; then
        install -m 0600 "${SINGBOX_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/singbox.json"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/singbox.json.missing"
    fi
    if [[ -f "${CADDY_CONFIG}" ]]; then
        install -m 0600 "${CADDY_CONFIG}" "${UPDATE_SUB_BACKUP_DIR}/Caddyfile"
    else
        install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/Caddyfile.missing"
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
    # 模板快照属于本次事务：必须和 state/六产物一起回滚，否则下一进程会发布失败事务的新模板。
    if [[ -n "${RT_TEMPLATE_SNAPSHOT_PATH:-}" ]]; then
        if [[ -f "${RT_TEMPLATE_SNAPSHOT_PATH}" ]]; then
            install -m 0600 "${RT_TEMPLATE_SNAPSHOT_PATH}" \
                "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml"
        else
            install -m 0600 /dev/null "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml.missing"
        fi
    fi
    UPDATE_SUB_ROLLBACK_ON_EXIT=1
}

rollback_subscription_update() {
    warn "本机配置更新失败，正在恢复状态、配置与订阅文件"
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/state.env" ]]; then
        if ! restore_state_file "${UPDATE_SUB_BACKUP_DIR}/state.env" "${STATE_FILE}"; then
            # 状态恢复失败不能短路其余恢复：证书/私钥/订阅/模板仍要回到旧事务，
            # 并保留整个临时目录（内含 part.* 备份）供人工恢复。
            fail "状态文件回滚失败；已保留回滚备份 ${UPDATE_SUB_BACKUP_DIR}（随临时目录保留），请人工恢复" || true
            PRESERVE_RUNTIME_TMP=1
        fi
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/certificate.pem" ]]; then
        install -m 0644 "${UPDATE_SUB_BACKUP_DIR}/certificate.pem" "${CERT_FILE}"
    elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/certificate.missing" ]]; then
        rm -f -- "${CERT_FILE}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/private.key" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/private.key" "${KEY_FILE}"
    elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/private-key.missing" ]]; then
        rm -f -- "${KEY_FILE}"
    fi
    if [[ -d "${UPDATE_SUB_BACKUP_DIR}/subscriptions" ]]; then
        publish_subscription_files "${UPDATE_SUB_BACKUP_DIR}/subscriptions"
    else
        rm -rf -- "${SUBSCRIPTION_DIR}"
    fi
    if [[ -n "${RT_TEMPLATE_SNAPSHOT_PATH:-}" ]]; then
        if [[ -f "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml" ]]; then
            install -d -m 0700 "${RT_TEMPLATE_SNAPSHOT_PATH%/*}" \
                && install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml" \
                    "${RT_TEMPLATE_SNAPSHOT_PATH}" \
                || warn "恢复 Mihomo 模板快照失败：${RT_TEMPLATE_SNAPSHOT_PATH}"
        elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/mihomo-template.yaml.missing" ]]; then
            rm -f -- "${RT_TEMPLATE_SNAPSHOT_PATH}"
        fi
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/singbox.json" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/singbox.json" "${SINGBOX_CONFIG}"
    elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/singbox.json.missing" ]]; then
        rm -f -- "${SINGBOX_CONFIG}"
    fi
    if [[ -f "${UPDATE_SUB_BACKUP_DIR}/Caddyfile" ]]; then
        install -m 0600 "${UPDATE_SUB_BACKUP_DIR}/Caddyfile" "${CADDY_CONFIG}"
    elif [[ -f "${UPDATE_SUB_BACKUP_DIR}/Caddyfile.missing" ]]; then
        rm -f -- "${CADDY_CONFIG}"
    fi
    if [[ "${UPDATE_SUB_ROLLBACK_NO_RESTART:-0}" == "1" ]]; then
        warn "本次回滚不重启服务（旧进程可能仍在运行）；若保护待落实，请执行 sudo easy_all cdn-traffic-sync"
        return 0
    fi
    if declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1 \
        && ! cdn_traffic_protection_checkpoint; then
        warn "恢复前 CDN 流量采样未通过；先把运行时收敛到受限配置，再强制加载旧证书"
        local sub_ok=0 restored=0
        declare -F cdn_subscription_ready >/dev/null 2>&1 && cdn_subscription_ready && sub_ok=1 || true
        # 子 shell 捕获 die；配置发布、服务加载与指纹确认必须同时成功才算恢复。
        if ( runtime_write_config 1 "${sub_ok}" && runtime_apply_runtime_services 1 ); then
            if declare -F runtime_served_certificate_matches_disk >/dev/null 2>&1 \
                && ! runtime_served_certificate_matches_disk; then
                warn "受限回滚后实际服务证书与磁盘不一致；进入保护性停机并保留恢复材料"
            else
                restored=1
            fi
        else
            warn "受限回滚的配置发布或服务加载失败；进入保护性停机并保留恢复材料"
        fi
        if [[ "${restored}" == "1" ]]; then
            if declare -F cdn_traffic_mark_restricted_recovered >/dev/null 2>&1; then
                cdn_traffic_mark_restricted_recovered \
                    || warn "受限回滚已生效，但无法持久化保护状态；下一轮 sync 会重试"
            fi
            warn "回滚已恢复旧证书并保持 CDN 受限；定时器或 sudo easy_all cdn-traffic-sync 会收敛保护状态"
            return 0
        fi
        # 恢复失败：持久化保护意图、停止无法确认一致性的服务，并保留快照材料。
        declare -F cdn_traffic_mark_protection_offline >/dev/null 2>&1 \
            && cdn_traffic_mark_protection_offline || true
        systemctl stop "${SINGBOX_SERVICE:-easy_all-singbox.service}" >/dev/null 2>&1 || true
        systemctl stop "${CADDY_SERVICE:-easy_all-caddy.service}" >/dev/null 2>&1 || true
        if [[ -n "${UPDATE_SUB_BACKUP_DIR:-}" && -d "${UPDATE_SUB_BACKUP_DIR}" ]]; then
            local preserve="${STATE_DIR}/rollback-preserve-$(date +%s)"
            install -d -m 0700 "${STATE_DIR}" 2>/dev/null || true
            if cp -a -- "${UPDATE_SUB_BACKUP_DIR}" "${preserve}" 2>/dev/null; then
                chmod -R go-rwx "${preserve}" 2>/dev/null || true
                warn "回滚未完成；恢复材料已保留：${preserve}"
            else
                warn "回滚未完成，且复制恢复材料失败：${UPDATE_SUB_BACKUP_DIR}"
            fi
        fi
        return 1
    fi
    runtime_apply_runtime_services 1 >/dev/null 2>&1 \
        || warn "恢复订阅更新前运行配置失败；请执行 sudo easy_all apply"
    if declare -F runtime_served_certificate_matches_disk >/dev/null 2>&1; then
        runtime_served_certificate_matches_disk \
            || warn "回滚后实际服务证书与磁盘不一致；请执行 sudo easy_all renew-cert"
    fi
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
    if command -v ufw >/dev/null 2>&1; then
        for port in 443 8443; do
            delete_stale_ufw_rules "easy_all-cf-origin-${port}" \
                || warn "回收 Cloudflare 回源放行（TCP ${port}）未完成；请人工核对 ufw status"
        done
    fi
    ufw reload >/dev/null 2>&1 || true
}

# 状态不完整（schema 1 但字段不齐）：只清本机，云端资源一律保留并点名。
# 该路径不 source state，也不猜协议——渲染/服务名都由固定路径决定。
uninstall_incomplete() {
    local answer
    require_root
    (($# == 0)) || die "uninstall 不支持参数：$*"
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        read_bilingual '状态不完整，云端资源无法自动清理，需人工核对；仍删除 easy_all 本机内容？[y/N]:' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    printf '状态不完整；仅清理本机内容。云端资源无法自动清理，需人工核对分发、ACM、DNS、Origin Rule 与 Origin CA\n' >&2
    stop_maintenance_services || true
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    # 损坏/字段不齐的状态可能是 CloudFront 模式：该路径只 source 了中立运行时，
    # 计量库（lib/cdn-traffic-guard.sh，仅 cloudfront-mode.sh 会加载）从未加载。
    # 但定时器与 mangle 计数链可能仍在跑，所以模式库未加载也必须能回收计量链。
    if ! declare -F cdn_traffic_counters_remove >/dev/null 2>&1 \
        && [[ -f "${RUNTIME_LIB_DIR}/cdn-traffic-guard.sh" ]]; then
        # shellcheck source=lib/cdn-traffic-guard.sh
        source "${RUNTIME_LIB_DIR}/cdn-traffic-guard.sh"
    fi
    # 计量定时器与单元文件按固定单元名无条件回收：按 declare -F 判断会漏掉上面的
    # “库本可加载但当时未加载”场景，让 15 秒 timer 继续调用即将被删除的命令。
    local systemd_dir="${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}"
    systemctl disable --now easy_all-cdn-traffic-guard.timer >/dev/null 2>&1 || true
    systemctl stop easy_all-cdn-traffic-guard.service >/dev/null 2>&1 || true
    rm -f -- "${systemd_dir}/easy_all-cdn-traffic-guard.timer" \
        "${systemd_dir}/easy_all-cdn-traffic-guard.service"
    stop_services
    if declare -F cdn_traffic_counters_remove >/dev/null 2>&1; then
        cdn_traffic_counters_remove \
            || die "回收 mangle 计量规则失败；已保留本机状态与命令，修正后重试 uninstall"
    fi
    remove_certbot_deploy_hook || true
    certificate_remove_lineage || true
    restore_platform_security_state || warn "SSH 配置恢复失败；请通过服务商 Console 检查"
    restore_preinstall_firewall
    restore_preinstall_ipv6
    remove_daily_reboot_schedule || warn "移除 easy_all 定时重启任务失败；请检查 root crontab"
    rm -f -- "${SINGBOX_SERVICE_FILE}" "${CADDY_SERVICE_FILE}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${SUBSCRIPTION_DIR}" "$(dirname -- "${SUBSCRIPTION_DIR}")" \
        "${COMMAND_INSTALL_DIR}" "$(dirname -- "${SINGBOX_BIN}")" "$(dirname -- "${CADDY_BIN}")"
    success "本机内容已清理；云端资源无法自动清理，需人工核对"
}

stop_services() {
    systemctl disable --now "${SINGBOX_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now "${CADDY_SERVICE}" >/dev/null 2>&1 || true
}

# --- 核心事务（design §6 H） --------------------------------------------------

# update-core 无新增参数：重装/修复当前脚本支持的锁定版本，不追最新。
update_current_core() {
    (($# == 0)) || die "update-core 不接受参数"
    local backup_dir restart_allowed=1 blocked=0 have_singbox=0 have_caddy=0
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if declare -F cdn_traffic_needs_restricted_recovery >/dev/null 2>&1 \
        && cdn_traffic_needs_restricted_recovery; then
        die "CDN 流量保护仍待落实；请先执行 sudo easy_all cdn-traffic-sync 再更新核心"
    fi
    if declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1; then
        cdn_traffic_protection_checkpoint \
            || die "流量 checkpoint 产生待落实的 CDN 阻断状态；已中止核心更新"
    fi
    declare -F runtime_blocked_state >/dev/null 2>&1 && blocked=$(runtime_blocked_state)
    backup_dir="${RUNTIME_TMP}/core-backup"
    install -d -m 0700 "${backup_dir}"
    # 备份只用于回滚：核心文件缺失（正是 update-core 要修复的场景）时没有旧版本可备份，
    # 不能因此中止；已存在的二进制备份失败则仍按「无法回滚」中止。
    if [[ -f "${SINGBOX_BIN}" ]]; then
        install -m 0755 "${SINGBOX_BIN}" "${backup_dir}/sing-box" \
            || die "备份当前 sing-box 失败；已中止核心更新"
        have_singbox=1
    fi
    if [[ -f "${CADDY_BIN}" ]]; then
        install -m 0755 "${CADDY_BIN}" "${backup_dir}/caddy" \
            || die "备份当前 Caddy 失败；已中止核心更新"
        have_caddy=1
    fi
    [[ ! -f "${SINGBOX_CONFIG}" ]] \
        || install -m 0600 "${SINGBOX_CONFIG}" "${backup_dir}/singbox.json"
    [[ ! -f "${CADDY_CONFIG}" ]] \
        || install -m 0600 "${CADDY_CONFIG}" "${backup_dir}/Caddyfile"
    if ! ( download_singbox && download_caddy ); then
        restart_allowed=1
    elif declare -F cdn_traffic_protection_checkpoint >/dev/null 2>&1 \
        && ! cdn_traffic_protection_checkpoint; then
        restart_allowed=0
    elif (
        runtime_write_config "${blocked}" 1 || exit 1
        runtime_apply_runtime_services 1 1 || exit 1
        validate_protocol_runtime || exit 1
    ); then
        refresh_runtime_subscription_after_core_update
        release_runtime_write_lock
        success "sing-box $(singbox_version) 与 Caddy $(caddy_version) 已更新"
        return 0
    fi
    warn "核心更新失败，正在回滚配置与运行时"
    if ((have_singbox == 1)); then
        install -m 0755 "${backup_dir}/sing-box" "${SINGBOX_BIN}" \
            || die "恢复旧 sing-box 失败（本次核心更新未完成）"
    fi
    if ((have_caddy == 1)); then
        install -m 0755 "${backup_dir}/caddy" "${CADDY_BIN}" \
            || die "恢复旧 Caddy 失败（本次核心更新未完成）"
    fi
    if [[ -f "${backup_dir}/singbox.json" ]]; then
        install -m 0600 "${backup_dir}/singbox.json" "${SINGBOX_CONFIG}"
    fi
    if [[ -f "${backup_dir}/Caddyfile" ]]; then
        install -m 0600 "${backup_dir}/Caddyfile" "${CADDY_CONFIG}"
    fi
    if [[ "${restart_allowed}" != "1" ]]; then
        die "核心更新失败，已恢复旧版本；CDN 流量待落实，未重启旧服务，请运行 sudo easy_all cdn-traffic-sync"
    fi
    # 核心文件缺失时重建服务只会得到「重启失败」：先点名缺失，不把根因埋成服务错误。
    [[ -x "${SINGBOX_BIN}" && -x "${CADDY_BIN}" ]] \
        || die "核心更新失败；核心文件缺失，未重启服务；请重试 sudo easy_all update-core 重新下载"
    runtime_apply_runtime_services 1 1 || die "恢复旧核心后无法重建服务"
    if ((have_singbox == 0 || have_caddy == 0)); then
        die "核心更新失败；更新前缺失的核心没有可回滚的旧版本，已保留本次下载的二进制"
    fi
    die "核心更新失败，已恢复旧版本"
}

# Profiles whose local subscription content depends on the installed core define this
# hook. Failure must not abort the completed core swap.
refresh_runtime_subscription_after_core_update() {
    declare -F refresh_runtime_subscription >/dev/null 2>&1 || return 0
    (refresh_runtime_subscription) \
        || warn "核心已更新，但订阅未重新生成；请执行 sudo easy_all apply"
}
