#!/usr/bin/env bash

# Shared Cloudflare orange-cloud XHTTP core for mode 3 (Cloudflare only) and
# mode 5 (direct Reality + Cloudflare).
#
# Profile contract provided before this file is sourced:
#   CDN_PROFILE_KEY          install marker / profile key (cloudflare / combined-cloudflare)
#   CDN_EXPECTED_PROTOCOL    state PROTOCOL owned by the profile
#   CDN_MODE_LABEL           user-facing mode name
#   CDN_ENTRY_SUMMARY        entry summary used by the install success message
#   CDN_INSTALL_PORTS        TCP ports that must be free before a fresh install
#   CDN_STATE_VARIABLES      state.env fields persisted by the profile
#   CDN_RECORD_COMMENT       Cloudflare DNS ownership comment of this profile
#   XRAY_XHTTP_LOOPBACK_PORT loopback port of the XHTTP inbound
# plus the hooks (all mandatory, empty results instead of guessing):
#   collect_install_inputs      collect this profile's inputs (calls the shared input collector)
#   cdn_direct_domains          direct grey-cloud A-record domains (empty for mode 3)
#   cdn_prepare_direct_runtime  validate/generate direct runtime material (no-op for mode 3)
#   cdn_direct_inbounds_json    direct inbound JSON array ([] for mode 3)
#   cdn_direct_node_names       direct node name JSON array ([] for mode 3)
#   build_reality_link / build_mihomo_reality_node   direct link/node renderers (empty for mode 3)
#   cdn_validate_direct_runtime local acceptance of the direct entry (no-op for mode 3)
#   update_reality_target       direct target update (not routed for mode 3)
#
# Cloudflare API/DNS/Origin CA/origin-firewall helpers come from lib/cf-dns.sh.
# 这一层只承载橙云单域名链路（一个域名同时提供 XHTTP 与订阅），没有优选 IP、
# 没有测速/兜底分组、没有 Globalping 与 CloudFront/AWS/流量熔断语义。

readonly CLOUDFLARE_XHTTP_PADDING_BYTES="100-1000"
readonly CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS="600"
# 公网验收重试次数/间隔；测试可经 *_OVERRIDE 缩短，生产默认不变。
readonly CDN_PUBLIC_ACCEPT_ATTEMPTS="${CDN_PUBLIC_ACCEPT_ATTEMPTS_OVERRIDE:-6}"
readonly CDN_PUBLIC_ACCEPT_SECONDS="${CDN_PUBLIC_ACCEPT_SECONDS_OVERRIDE:-10}"
readonly CLOUDFLARE_TOKEN_FILE="${STATE_DIR}/cloudflare.token"
readonly CLOUDFLARE_ORIGIN_IPS_FILE="${STATE_DIR}/cloudflare-origin-ipv4.txt"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
readonly CF_CA_ROOT_FILE="${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
readonly CLOUDFLARE_UFW_COMMENT="easy_all-cf-origin"
readonly CLOUDFLARE_UFW_PORT=443
readonly CLOUDFLARE_RESERVED_NODE_NAMES="AUTO CDN-AUTO CDN-FALLBACK PROXY GLOBAL DIRECT REJECT PASS"

: "${CLOUDFLARE_API_BASE:=https://api.cloudflare.com/client/v4}"

# shellcheck source=lib/cloudflare-state.sh
source "${XHTTP_LIB_DIR}/cloudflare-state.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/local-aggregation.sh
source "${XHTTP_LIB_DIR}/local-aggregation.sh"

CDN_SUBSCRIPTION_CORRUPT=0

# --- Profile adapters ---------------------------------------------------------

cdn_reality_enabled() {
    [[ "$(cdn_direct_node_names)" != "[]" ]]
}

cdn_direct_ufw_ports() {
    local port
    for port in "${CDN_INSTALL_PORTS[@]}"; do
        case "${port}" in
        443) ;;
        *) printf '%s\n' "${port}" ;;
        esac
    done
}

validate_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *[[:cntrl:]]* ]]
}

cdn_node_name_reserved() {
    local name=$1 reserved
    for reserved in ${CLOUDFLARE_RESERVED_NODE_NAMES}; do
        [[ "${name}" != "${reserved}" ]] || return 0
    done
    return 1
}

# --- State contract -----------------------------------------------------------

# 运行时派生字段（不落盘）：load_state 与首装输入都必须派生，首装不经过 load_state。
# 单域名链路里 CF_NODE_DOMAIN 同时是 XHTTP Host、订阅域名与 Origin CA 的唯一名字。
cdn_derive_runtime_fields() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || return 1
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
    CLOUDFLARE_ORIGIN_DOMAIN=${CF_NODE_DOMAIN}
    BACKEND=xray
    SUBSCRIPTION_MODE=deploy
}

cdn_validate_state_structure() {
    local field domain missing=0
    while IFS= read -r field; do
        [[ -n "${!field:-}" ]] || { warn "状态缺少必需字段：${field}"; missing=1; }
    done < <(cloudflare_state_required_fields "${PROTOCOL}")
    ((missing == 0)) || die "状态不完整；请先执行 sudo easy_all uninstall 后重新安装"

    [[ "${CDN_PROVIDER}" == "cloudflare" ]] \
        || die "状态 CDN_PROVIDER 不是 cloudflare；请先执行 sudo easy_all uninstall 后重新安装"
    validate_domain "${CF_NODE_DOMAIN}" || die "状态中的节点域名无效：${CF_NODE_DOMAIN}"
    [[ "${CF_NODE_DOMAIN}" == *".${CF_ZONE}" ]] \
        || die "状态中的节点域名不属于 ${CF_ZONE}：${CF_NODE_DOMAIN}"
    [[ "${CF_NODE_DOMAIN%.${CF_ZONE}}" != *.* ]] \
        || die "状态中的节点域名不是 ${CF_ZONE} 的一级子域名：${CF_NODE_DOMAIN}"
    validate_xhttp_path "${XHTTP_PATH}" || die "状态中的 XHTTP 路径无效：${XHTTP_PATH}"
    validate_uuid "${VLESS_UUID}" || die "状态中的 VLESS UUID 无效"
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        validate_domain "${domain}" || die "状态中的直连域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] \
            || die "状态中的直连域名不属于 ${CF_ZONE}：${domain}"
        [[ "${domain}" != "${CF_NODE_DOMAIN}" ]] \
            || die "直连域名不得等于 CDN 节点域名：${domain}"
    done < <(cdn_direct_domains)
    if cdn_reality_enabled; then
        [[ "${REALITY_SHORT_ID}" =~ ^([0-9a-fA-F]{2}){1,8}$ ]] \
            || die "状态中的 Reality Short ID 无效：只允许偶数位十六进制（2–16 位）"
        validate_reality_target "${REALITY_TARGET:-}" \
            || die "状态中的 Reality 目标无效：${REALITY_TARGET:-空}"
    fi
    cdn_derive_runtime_fields || die "状态缺少节点域名，无法派生运行时字段"
}

load_state() {
    local variable
    [[ -f "${STATE_FILE}" ]] || die "easy_all 尚未安装"
    unset STATE_VERSION
    for variable in "${CDN_STATE_VARIABLES[@]}"; do
        unset "${variable}" 2>/dev/null || true
    done
    # shellcheck source=/dev/null
    source "${STATE_FILE}"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 easy_all 状态版本：${STATE_VERSION:-缺失}；请先执行 sudo easy_all uninstall 后重新安装"
    [[ "${PROTOCOL:-}" == "${CDN_EXPECTED_PROTOCOL}" ]] \
        || die "状态协议不是 ${CDN_EXPECTED_PROTOCOL}；请先执行 sudo easy_all uninstall 后重新安装"
    cdn_validate_state_structure
    # 订阅配置损坏只告警：结构状态仍可用于修复与卸载，实际发布入口仍先强校验。
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
    local temp variable
    install -d -m 0700 "${STATE_DIR}"
    cdn_sync_config_tokens || true
    temp=$(mktemp "${STATE_DIR}/state.env.XXXXXX") || die "创建状态暂存文件失败"
    cleanup_files+=("${temp}")
    {
        printf 'STATE_VERSION=%q\n' "${STATE_SCHEMA_VERSION}"
        for variable in "${CDN_STATE_VARIABLES[@]}"; do
            printf '%s=%q\n' "${variable}" "${!variable:-}"
        done
    } >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${STATE_FILE}"
}

# 云端已签发新证书但后续本机/公网验收失败：证书按设计保留，必须在退出前点名，
# 否则下一次卸载只知道旧 ID，长期有效的孤儿证书无人知晓。
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

cdn_local_node_names() {
    jq -cn --arg cloud "${CF_NODE_PREFIX}" --argjson direct "$(cdn_direct_node_names)" \
        '$direct + [$cloud]'
}

cdn_validate_local_node_names() {
    local cloud=${CF_NODE_PREFIX:-} direct
    validate_node_name "${cloud}" || {
        printf 'Cloudflare 节点名无效：%s\n' "${cloud}" >&2
        return 1
    }
    cdn_node_name_reserved "${cloud}" && {
        printf 'Cloudflare 节点名不能使用保留组名：%s\n' "${cloud}" >&2
        return 1
    }
    direct=$(cdn_direct_node_names)
    jq -e --arg cloud "${cloud}" '
        type == "array" and all(.[]; type == "string") and
        (index($cloud) | not) and (length == (unique | length))
    ' <<<"${direct}" >/dev/null || {
        printf '直连节点名无效、重复或与 CDN 节点重名\n' >&2
        return 1
    }
    while IFS= read -r name; do
        [[ -n "${name}" ]] || continue
        validate_node_name "${name}" || {
            printf '直连节点名无效：%s\n' "${name}" >&2
            return 1
        }
        cdn_node_name_reserved "${name}" && {
            printf '直连节点名不能使用保留组名：%s\n' "${name}" >&2
            return 1
        }
    done < <(jq -r '.[]' <<<"${direct}")
    # 循环正常跑完时最后一条命令是 cdn_node_name_reserved（非常用名返回 1），
    # 不显式返回 0 会被误判成校验失败。
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

    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'CDN 节点域名（橙云代理，同时提供 XHTTP 与订阅）' "${CF_NODE_DOMAIN:-cf.${CF_ZONE}}")")
    cdn_validate_install_domains
    # 首装不经过 load_state：订阅渲染前必须在输入校验处派生运行时字段。
    cdn_derive_runtime_fields || die "运行时字段派生失败：缺少节点域名"

    CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（Zone 只读 + DNS 编辑 + SSL/证书 编辑权限）') \
        || die '缺少 Cloudflare API Token'
    cdn_validate_api_token_format || die "Cloudflare Token 格式无效"

    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP 路径无效"

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

# Token 格式：20–512 位 URL 安全字符。不用 {20,512} 区间——bash 3.2（macOS）的
# 正则把超过 255 的区间当字面量，会让本机测试与校验结果不一致。
cdn_validate_api_token_format() {
    [[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
        && "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]+$ ]]
}

cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -s "${CLOUDFLARE_TOKEN_FILE}" ]]; then
        CLOUDFLARE_API_TOKEN=$(<"${CLOUDFLARE_TOKEN_FILE}")
    fi
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（Zone 只读 + DNS 编辑 + SSL/证书 编辑权限）') \
            || die '缺少 Cloudflare API Token'
    fi
    cdn_validate_api_token_format || die "Cloudflare Token 格式无效"
}

persist_cloudflare_token() {
    install -d -m 0700 "${STATE_DIR}"
    local temp
    temp=$(mktemp "${STATE_DIR}/cloudflare.token.XXXXXX") \
        || die "创建 Cloudflare Token 暂存文件失败"
    cleanup_files+=("${temp}")
    printf '%s\n' "${CLOUDFLARE_API_TOKEN}" >"${temp}"
    chmod 0600 "${temp}"
    mv -f -- "${temp}" "${CLOUDFLARE_TOKEN_FILE}"
}

cdn_record_belongs_to_easy_all() {
    [[ "${1:-}" == easy_all* ]]
}

dns_ensure_record() {
    local host=$1 type=$2 content=$3 proxied=$4 records same_type count record id current current_proxied comment conflict payload other_address
    # 必须按名字查全部类型：同名 CNAME/AAAA 与 A 的冲突只有放开类型过滤才看得见。
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" '' "${host}")
    # 同名 AAAA 指向另一个源站时，只配置 A 会留下第二个回源目标；拒绝猜测并要求先清理。
    other_address=$(jq -r '[.[] | select(.type == "AAAA") | .type] | first // empty' <<<"${records}")
    [[ -z "${other_address}" ]] \
        || die "Cloudflare ${host} 已有同名 AAAA 记录；请先清理该记录后重装（不自动删除非本链路记录）"
    same_type=$(jq -c --arg type "${type}" '[.[] | select(.type == $type)]' <<<"${records}")
    count=$(jq 'length' <<<"${same_type}")
    ((count <= 1)) || die "Cloudflare ${host} 存在多条 ${type} 记录，拒绝覆盖"
    if ((count == 1)); then
        record=$(jq -c '.[0]' <<<"${same_type}")
        id=$(jq -r '.id' <<<"${record}")
        current=$(jq -r '.content' <<<"${record}")
        current_proxied=$(jq -r '.proxied' <<<"${record}")
        comment=$(jq -r '.comment // empty' <<<"${record}")
        if [[ "${current}" == "${content}" && "${current_proxied}" == "${proxied}" ]]; then
            # 复用第三方同内容记录时只借用，不改归属注释。
            cdn_record_belongs_to_easy_all "${comment}" || return 0
            [[ "${comment}" == "${CDN_RECORD_COMMENT}" ]] && return 0
            cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" \
                "$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
                    --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
                    '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')" >/dev/null
            return 0
        fi
        # 内容或代理状态不一致时只接管 easy_all 自己的记录（允许换机重装更新 IP）。
        cdn_record_belongs_to_easy_all "${comment}" \
            || die "Cloudflare ${host} 的 ${type} 记录与目标不一致；拒绝覆盖"
        cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" \
            "$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
                --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
                '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')" >/dev/null
        return 0
    fi
    conflict=$(jq -r --arg type "${type}" \
        '[.[] | select(.type == "CNAME" or $type == "CNAME") | .type] | first // empty' <<<"${records}")
    [[ -z "${conflict}" ]] \
        || die "Cloudflare ${host} 已有其他类型的记录（${conflict}）；请先清理冲突记录后重装"
    payload=$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
        --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
        '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')
    cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/dns_records" "${payload}" >/dev/null
}

cdn_ensure_zone_id() {
    cloudflare_collect_api_token
    if [[ -z "${CLOUDFLARE_ZONE_ID:-}" ]]; then
        CLOUDFLARE_ZONE_ID=$(cloudflare_lookup_parent_zone "${CF_ZONE}") \
            || die "Cloudflare 中没有 active Zone：${CF_ZONE}"
    fi
}

# 橙云节点域名一条 A 记录同时承载 XHTTP 与订阅；模式 5 另加灰云直连 A。
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

render_xray_config() {
    local direct_inbounds managed_outbounds managed_routing inbound_sockopt
    install -d -m 0755 "${XRAY_DIR}"
    direct_inbounds=$(cdn_direct_inbounds_json)
    [[ -n "${direct_inbounds}" ]] || direct_inbounds='[]'
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(xray_xhttp_routing_json)
    inbound_sockopt=$(xray_inbound_sockopt_json)
    jq -n \
        --argjson direct_inbounds "${direct_inbounds}" \
        --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --arg xhttp_path "${XHTTP_PATH}" --arg xhttp_host "${CF_NODE_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" \
        --arg x_padding_bytes "${CLOUDFLARE_XHTTP_PADDING_BYTES}" \
        --arg stream_up_server_secs "${CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS}" \
        --argjson inbound_sockopt "${inbound_sockopt}" \
        --argjson managed_outbounds "${managed_outbounds}" \
        --argjson managed_routing "${managed_routing}" '
        {
          log: {loglevel: "warning"},
          inbounds: ($direct_inbounds + [
            {
              tag: "vless-xhttp-in",
              listen: "127.0.0.1",
              port: $xhttp_port,
              protocol: "vless",
              settings: {clients: [{id: $uuid, email: $email}], decryption: "none"},
              streamSettings: {
                network: "xhttp",
                xhttpSettings: {
                  path: $xhttp_path,
                  host: $xhttp_host,
                  mode: "stream-up",
                  xPaddingBytes: $x_padding_bytes,
                  scStreamUpServerSecs: $stream_up_server_secs
                },
                sockopt: $inbound_sockopt
              },
              sniffing: {enabled: true, destOverride: ["http","tls","quic"], routeOnly: false}
            }
          ]),
          outbounds: $managed_outbounds,
          routing: $managed_routing
        }' >"${RUNTIME_TMP}/xray-config.json"
    "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null \
        || die "Xray 配置校验失败"
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

write_xray_config() {
    render_xray_config
}

# 写配置并重启 Xray：`systemctl enable --now` 对已运行的 unit 是空操作，
# 不显式 restart 的话新 UUID/路径/Reality 目标不会生效（客户端握手会全部失败）。
write_xray_runtime() {
    write_xray_config
    install_xray_service
    systemctl restart "${XRAY_SERVICE}" || die "重启 Xray 服务失败"
}

# --- UFW ----------------------------------------------------------------------

xhttp_configure_ufw() {
    local desired_ports
    snapshot_ufw_state
    snapshot_platform_security_state
    ensure_ssh_boot_service
    detect_ssh_ports strict
    verify_ssh_ufw_no_unmanaged_block "${SSH_PORTS}"
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null || die "设置 UFW 默认入站策略失败"
    ufw default allow outgoing >/dev/null || die "设置 UFW 默认出站策略失败"
    ufw default deny routed >/dev/null || die "设置 UFW 默认转发策略失败"
    # 443 只对 Cloudflare 官方回源段放行，不添加公网通用放行。
    desired_ports="$(printf '%s\n' "${SSH_PORTS}" $(cdn_direct_ufw_ports) | tr '\n' ' ')"
    apply_ssh_ufw_policy "${desired_ports}" "${SSH_PORTS}"
    cloudflare_configure_origin_firewall
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

# --- Nginx --------------------------------------------------------------------

# 单域名：同一个 server 块同时承载 health、XHTTP 与 /subscribe；未知 SNI 由默认
# server 拒绝握手。历史实现把节点与订阅分别写成两个 server，改成单域名后会冲突，
# 因此这里只渲染一个业务 server。
cdn_render_nginx_config() {
    local http2_directive="" listen_h2="http2 "
    if (($# >= 2)); then
        http2_directive=$1
        listen_h2=$2
    elif nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    write_subscription_nginx_maps 1
    cat <<EOF
server {
    listen 443 ssl ${listen_h2}default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen 443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3;
    server_name ${CF_NODE_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;${http2_directive}
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "easy_all ok\n";
    }

    location ^~ ${XHTTP_PATH}/ {
        access_log off;
        client_max_body_size 0;
        client_body_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_set_header Host ${CF_NODE_DOMAIN};
        grpc_set_header X-Real-IP \$remote_addr;
        grpc_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        grpc_set_header X-Forwarded-Proto https;
        grpc_socket_keepalive on;
        grpc_read_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_send_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};
    }

EOF
    write_subscription_nginx_locations "" static 1
    cat <<EOF

    location / { return 404; }
}
EOF
}

write_nginx_config() {
    optimize_nginx_system_config
    local http2_directive="" listen_h2="http2 "
    cdn_require_valid_subscription
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    install -d -m 0755 "${WEB_ROOT}"
    cdn_render_nginx_config "${http2_directive}" "${listen_h2}" >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

# 本机探活信任 Cloudflare Origin CA 根：回源证书由它签发，且 HTTPS 严格校验。
xhttp_validate_local_tls_curl_args() {
    cloudflare_ensure_origin_ca_root
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https' --noproxy '*' --cacert "${CF_CA_ROOT_FILE}")
}

cdn_certificate_covers_node_domain() {
    local out=""
    [[ -s "${CERT_FILE}" ]] || return 1
    out=$(openssl x509 -in "${CERT_FILE}" -checkhost "${CF_NODE_DOMAIN}" -noout 2>/dev/null || true)
    # macOS/LibreSSL 没有 -checkhost（报 unknown option）：退回按证书 SAN 集合判定。
    [[ -n "${out}" ]] \
        || { cloudflare_certificate_san_hosts "${CERT_FILE}" | grep -Fxq "${CF_NODE_DOMAIN}"; return; }
    [[ "${out}" == *"does match certificate"* && "${out}" != *"does NOT match"* ]]
}

# --- Subscription rendering ---------------------------------------------------

build_vless_xhttp_link() {
    local server=$1 node_name=$2 client_path extra
    client_path=$(xhttp_client_path)
    extra=$(jq -cn '{uplinkHTTPMethod:"POST",noGRPCHeader:false,xmux:{maxConnections:4,cMaxReuseTimes:0,hMaxRequestTimes:"300-600",hMaxReusableSecs:"900-1800",hKeepAlivePeriod:0}}')
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up&extra=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${CF_NODE_DOMAIN}" "${CF_NODE_DOMAIN}" \
        "$(uri_encode "${client_path}")" "$(uri_encode "${extra}")" "$(uri_encode "${node_name}")"
}

build_mihomo_xhttp_node() {
    local server=$1 node_name=$2 client_path
    client_path=$(xhttp_client_path)
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${CF_NODE_DOMAIN}" --arg uuid "${VLESS_UUID}" --arg path "${client_path}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: ipv4\n    alpn:\n      - h2\n" +
        "    xhttp-opts:\n      host: \($host|@json)\n      path: \($path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n        max-connections: 4\n" +
        "        c-max-reuse-times: 0\n        h-max-request-times: 300-600\n        h-max-reusable-secs: 900-1800\n        h-keep-alive-period: 0\n"'
}

build_node_links() {
    local direct extra
    direct=$(build_reality_link || true)
    [[ -z "${direct}" ]] || printf '%s\n' "${direct}"
    build_vless_xhttp_link "${CF_NODE_DOMAIN}" "${CF_NODE_PREFIX}"
    printf '\n'
    extra=$(aggregation_node_links)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
}

build_mihomo_nodes() {
    local direct extra
    direct=$(build_mihomo_reality_node || true)
    [[ -z "${direct}" ]] || printf '%s\n' "${direct}"
    build_mihomo_xhttp_node "${CF_NODE_DOMAIN}" "${CF_NODE_PREFIX}"
    extra=$(aggregation_mihomo_nodes)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
}

build_mihomo_proxy_names() {
    local extra
    extra=$(aggregation_node_names)
    jq -nr --argjson direct "$(cdn_direct_node_names)" --arg cloud "${CF_NODE_PREFIX}" \
        --argjson extra "${extra}" '
        ($direct + [$cloud] + $extra)[] | "        - \(.|@json)"'
}

# 单节点链路没有测速组或兜底组；模板占位必须成功输出空内容。
build_mihomo_proxy_groups() {
    printf ''
}

cloudflare_template_snapshot_file() {
    printf '%s/mihomo-template.yaml' "${STATE_DIR}"
}

# 共享订阅事务按该路径把模板快照与 state、六种产物一起备份与回滚。
XHTTP_TEMPLATE_SNAPSHOT_PATH=$(cloudflare_template_snapshot_file)

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
    [[ "${decoded}" == *"type=xhttp"* ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' \
        "https://${CF_NODE_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"network: xhttp"* ]]
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
    die "Cloudflare 公网验收失败（已重试 ${CDN_PUBLIC_ACCEPT_ATTEMPTS} 次）：请确认 ${CF_NODE_DOMAIN} 已开启橙云代理、SSL/TLS 为 Full (strict)、边缘证书可用且 gRPC 已开启；修复后执行 sudo easy_all apply-cloud"
}

# --- Commands -----------------------------------------------------------------

show_node() {
    local extra
    collect_installed_state
    [[ "${CDN_SUBSCRIPTION_CORRUPT}" == "0" ]] \
        || warn "订阅配置损坏；节点列表可能不完整，请执行 sudo easy_all edit-sub"
    printf '\n协议: VLESS XHTTP stream-up/H2 over Cloudflare\n'
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
    printf '协议: Cloudflare XHTTP（%s）\n' "${CDN_ENTRY_SUMMARY}"
    show_tcp_acceleration_status
    if cdn_reality_enabled; then
        printf '直连域名: %s（端口 %s）\n' "${DIRECT_DOMAIN}" "${REALITY_PORT}"
    fi
    printf 'CDN 节点域名（橙云，同时提供订阅）: %s\n' "${CF_NODE_DOMAIN}"
    if [[ -s "${CERT_FILE}" ]]; then
        cert_enddate=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        if cdn_certificate_covers_node_domain; then
            printf 'Origin CA 回源证书到期: %s（已覆盖 %s）\n' "${cert_enddate:-未知}" "${CF_NODE_DOMAIN}"
        else
            printf 'Origin CA 回源证书异常：未覆盖 %s；请执行 sudo easy_all renew-cert\n' "${CF_NODE_DOMAIN}"
        fi
    else
        printf 'Origin CA 回源证书: 缺失；请执行 sudo easy_all renew-cert\n'
    fi
    printf 'Xray: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '
    systemctl is-active --quiet nginx 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
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
    xhttp_configure_ufw
    cdn_prepare_direct_runtime
    write_xray_runtime
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
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
    xhttp_configure_ufw
    apply_cloud_phase
    write_xray_runtime
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
    cloudflare_write_subscriptions
    validate_subscription_runtime
    # 本机子流程完成后才能证明公网链路；失败时云端资源保留，可重试 apply-cloud。
    cdn_validate_public_runtime
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
    write_nginx_config
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
    nginx -t >/dev/null || die "证书更新后 Nginx 配置校验失败"
    systemctl reload nginx || die "证书更新后 Nginx 重载失败"
    # 新证书必须真的能完成本机 TLS/SNI 握手才允许吊销旧证书（吊销不可逆）。
    validate_protocol_runtime
    save_state
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cloudflare_finalize_certificate_rotation
    commit_subscription_update
    clear_profile_credentials
    success "Cloudflare Origin CA 回源证书已更新"
}

stop_services() {
    systemctl disable --now "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    systemctl disable --now nginx >/dev/null 2>&1 || true
}

# 卸载与安装失败回滚都只回收业务端口：保留 UFW 启用状态、默认策略与 SSH 放行。
restore_preinstall_firewall() {
    [[ ! -f "${BACKUP_DIR}/pre-install-ufw-default" ]] \
        || install -m 0644 "${BACKUP_DIR}/pre-install-ufw-default" "${UFW_DEFAULT_CONFIG}" \
            || warn "恢复 ${UFW_DEFAULT_CONFIG} 失败"
    reclaim_ufw_business_rules || warn "回收业务 UFW 放行未完成；请人工核对 ufw status"
    ufw reload >/dev/null 2>&1 || true
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

cdn_local_uninstall_common() {
    stop_services
    restore_platform_security_state || {
        warn "SSH 配置恢复失败；请通过服务商 Console 检查"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_preinstall_nginx_default_site || warn "恢复安装前 Nginx 默认站点失败"
    if ! remove_daily_reboot_schedule; then
        # 不能把“crontab 没改成”当成卸载完成：否则命令链接、业务目录和状态一起被删，
        # 而标记任务仍会写入一个已不存在的环境。保留现场供修正后重试。
        warn "卸载未完成：移除 easy_all 定时重启任务失败，本机状态与命令已保留；修正 root crontab 后重试 uninstall"
        return 1
    fi
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}" "${STATE_DIR}"
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
            read_bilingual '删除本机内容以及 easy_all 创建的 Cloudflare 记录与 Origin CA 证书？[y/N]:' answer
        else
            read_bilingual '删除 easy_all 本机服务、状态和证书（保留 Cloudflare 云端资源）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services || true
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    # 先打印清单再删本机状态，否则删除后失去资源定位信息。
    cdn_print_cloud_inventory
    if [[ "${mode}" == "--purge-cloud" ]]; then
        if (cdn_purge_cloud_resources); then
            :
        else
            warn "云端资源清理未完成；本机卸载继续，请按上方清单手动处置"
        fi
    else
        warn "Cloudflare 云端资源已保留；本机状态删除后无法再用 easy_all 清理"
    fi
    # 回源放行按本链路注释回收；失败只告警，不中断卸载。
    cloudflare_remove_origin_firewall_rules || true
    cdn_local_uninstall_common || return 1
    if [[ "${mode}" == "--purge-cloud" ]]; then
        success "easy_all 本机内容已卸载；云端清理结果见上方输出"
    else
        success "easy_all 本机内容已卸载；云端资源已保留"
    fi
}

cloudflare_state_raw_value() {
    local key=$1 line
    [[ -f "${STATE_FILE}" ]] || return 1
    line=$(grep -E "^${key}=" "${STATE_FILE}" | tail -n 1) || return 1
    line=${line#*=}
    line=${line#\'}
    line=${line%\'}
    line=${line#\"}
    line=${line%\"}
    printf '%s\n' "${line}"
}

# 新协议但强制字段缺失/来自未完成实现：只清本机，云端一律保留。
uninstall_incomplete_cloudflare() {
    local mode=${1:-} answer protocol version
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    protocol=$(cloudflare_state_raw_value PROTOCOL || true)
    version=$(cloudflare_state_raw_value STATE_VERSION || true)
    case "${protocol}" in
    cloudflare | combined-cloudflare) ;;
    *) die "状态协议不是 Cloudflare 新链路，拒绝处理" ;;
    esac
    [[ "${version}" == "0" ]] || die "状态版本不匹配，已停止卸载"
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        read_bilingual '状态不完整；仅清理本机内容并保留云端资源？[y/N]:' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    printf 'Cloudflare 状态不完整或来自未完成实现；仅清理本机，云端资源保留：\n' >&2
    printf '  节点域名: %s\n' "$(cloudflare_state_raw_value CF_NODE_DOMAIN || printf '未知')" >&2
    printf '  Origin CA 证书: %s\n' \
        "$(cloudflare_state_raw_value CLOUDFLARE_ORIGIN_CERT_ID || printf '未知')" >&2
    cloudflare_remove_origin_firewall_rules || true
    cdn_local_uninstall_common || return 1
    success "本机内容已清理；云端资源已保留"
}

cleanup_partial_install() {
    local path failed=0
    cleanup_partial_install_local || return 1
    cloudflare_remove_origin_firewall_rules || true
    remove_daily_reboot_schedule || true
    # 先删业务路径；任一失败就保留状态目录（含安装前快照、身份与 marker），
    # 修正挂载/权限后还能重试 cleanup-partial。
    for path in "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" \
        "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"; do
        [[ -n "${path}" ]] || continue
        rm -rf -- "${path}" 2>/dev/null || { warn "删除残留失败：${path}"; failed=1; }
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    if ((failed == 1)); then
        warn "业务残留未完全删除；已保留安装进度标记与安装前快照，修正权限/挂载后重试 sudo easy_all cleanup-partial"
        return 1
    fi
    # 业务路径已清空：最后删除状态目录并清除 marker。
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
    warn "本次已创建的 Cloudflare DNS/Origin CA 按设计保留；确认不再使用后可执行 uninstall --purge-cloud 或控制台清理"
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
    # 443 是橙云回源入口，端口预检同时覆盖回环 XHTTP 端口。
    prepare_fresh_install "${CDN_INSTALL_PORTS[@]}" "${XRAY_XHTTP_LOOPBACK_PORT}"
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
    download_xray
    cdn_prepare_direct_runtime
    install_progress_stage services
    xhttp_configure_ufw
    cloudflare_collect_api_token
    persist_cloudflare_token
    cdn_ensure_dns
    cdn_issue_certificate
    # 证书已签发：立即落盘 ID/到期时间，续装可直接复用而不是重复 POST /certificates。
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    write_xray_runtime
    write_bootstrap_nginx_config
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
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
