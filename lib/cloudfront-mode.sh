#!/usr/bin/env bash

# Shared AWS CloudFront XHTTP core for mode 2 (CloudFront only) and mode 3
# (direct Reality + CloudFront).
#
# Profile contract provided before this file is sourced:
#   CDN_PROFILE_KEY          install marker / profile key (cloudfront / combined)
#   CDN_EXPECTED_PROTOCOL    state PROTOCOL owned by the profile
#   CDN_MODE_LABEL           user-facing mode name
#   CDN_ENTRY_SUMMARY        entry summary used in the install success message
#   CDN_INSTALL_PORTS        TCP ports that must be free before a fresh install
#   CDN_STATE_VARIABLES      state.env fields persisted by the profile
#   XRAY_XHTTP_LOOPBACK_PORT loopback port of the XHTTP inbound
# plus the hooks (all mandatory, empty results instead of guessing):
#   collect_install_inputs      collect this profile's inputs (calls the shared input collector)
#   cdn_direct_domains          direct A-record domains (empty for mode 2)
#   cdn_prepare_direct_runtime  validate/generate direct runtime material (no-op for mode 2)
#   cdn_direct_inbounds_json    direct inbound JSON array ([] for mode 2)
#   cdn_direct_node_names       direct node name JSON array ([] for mode 2)
#   build_reality_link / build_mihomo_reality_node   direct link/node renderers (empty for mode 2)
#   cdn_validate_direct_runtime local acceptance of the direct entry (no-op for mode 2)
#   update_reality_target       direct target update (not routed for mode 2)
#
# CloudFront constants, AWS/ACM/DNS handling, origin TLS, Xray/Nginx, UFW,
# subscription hooks, operations and lifecycle commands live here only.

readonly AWS_CONTROL_REGION="us-east-1"
readonly CLOUDFRONT_CACHE_POLICY_ID="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
readonly CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID="b689b0a8-53d0-40ab-baf2-68738e2966ac"
readonly CLOUDFRONT_ORIGIN_ID="easy_all-cloudfront-origin"
readonly CLOUDFRONT_CONNECTION_ATTEMPTS="2"
readonly CLOUDFRONT_CONNECTION_TIMEOUT="3"
readonly CLOUDFRONT_ORIGIN_READ_TIMEOUT="120"
readonly CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT="120"
readonly CLOUDFRONT_XHTTP_STREAM_UP_SERVER_SECS="20-40"
readonly CLOUDFRONT_XHTTP_PADDING_BYTES="100-1000"
readonly CLOUDFRONT_DEPLOY_WAIT_ATTEMPTS="60"
readonly CLOUDFRONT_DEPLOY_WAIT_SECONDS="10"
readonly CDN_TRAFFIC_API_VERIFY_ATTEMPTS="5"
readonly CDN_TRAFFIC_API_VERIFY_SECONDS="1"
readonly CDN_PUBLIC_ACCEPT_ATTEMPTS="6"
readonly CDN_PUBLIC_ACCEPT_SECONDS="10"
readonly CDN_RECORD_COMMENT="easy_all cloudfront"
readonly CLOUDFLARE_TOKEN_FILE="${STATE_DIR}/cloudflare.token"
readonly CDN_TRAFFIC_API_INBOUND_TAG="easy-all-api"
readonly CERTBOT_LINEAGE_NAME="easy_all_origin"
readonly CERTBOT_LIVE_DIR="${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE:-/etc/letsencrypt/live/easy_all_origin}"
readonly CERTBOT_DEPLOY_HOOK_FILE="${EASY_ALL_CERTBOT_HOOK_FILE_OVERRIDE:-/etc/letsencrypt/renewal-hooks/deploy/easy_all-origin.sh}"
readonly ORIGIN_CERT_RENEW_SECONDS="2592000"
CLOUDFRONT_AWS_CLI_ARGS=(--no-cli-pager --cli-read-timeout 120 --cli-connect-timeout 60)

readonly CLOUDFRONT_RESERVED_NODE_NAMES="AUTO CDN-AUTO CDN-FALLBACK PROXY GLOBAL DIRECT REJECT PASS"

# shellcheck source=lib/cloudfront-state.sh
source "${XHTTP_LIB_DIR}/cloudfront-state.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/cdn-traffic-guard.sh
source "${XHTTP_LIB_DIR}/cdn-traffic-guard.sh"
# shellcheck source=lib/local-aggregation.sh
source "${XHTTP_LIB_DIR}/local-aggregation.sh"

CDN_SUBSCRIPTION_CORRUPT=0
# 本轮已确认订阅未就绪且已有阻断：置 1 后本进程的 Nginx 渲染一律使用订阅 503 的最小配置，
# 否则后续 rebuild 会按“配置可解析”重新启用 /subscribe 并继续提供旧产物。
CDN_SUBSCRIPTION_DENIED=0

# --- Profile adapters ---------------------------------------------------------

cdn_reality_enabled() {
    [[ "$(cdn_direct_node_names)" != "[]" ]]
}

cdn_direct_ufw_ports() {
    local port
    for port in "${CDN_INSTALL_PORTS[@]}"; do
        case "${port}" in
        80 | 443) ;;
        *) printf '%s\n' "${port}" ;;
        esac
    done
}

validate_node_name() {
    [[ -n "$1" && ${#1} -le 64 && "$1" != *[[:cntrl:]]* ]]
}

cdn_node_name_reserved() {
    local name=$1 reserved
    for reserved in ${CLOUDFRONT_RESERVED_NODE_NAMES}; do
        [[ "${name}" != "${reserved}" ]] || return 0
    done
    return 1
}

# --- State contract -----------------------------------------------------------

# 运行时派生字段（不落盘）：load_state 与首装输入都必须派生，首装不经过 load_state。
cdn_derive_runtime_fields() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || return 1
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    BACKEND=xray
    SUBSCRIPTION_MODE=deploy
}

cdn_validate_state_structure() {
    local variable domain field missing=0
    # 必需字段清单只有 lib/cloudfront-state.sh 一处；模式 3 的直连字段同样参与结构校验。
    while IFS= read -r field; do
        [[ -n "${!field:-}" ]] || { warn "状态缺少必需字段：${field}"; missing=1; }
    done < <(cloudfront_state_required_fields "${PROTOCOL}")
    ((missing == 0)) || die "状态不完整；请先执行 sudo easy_all uninstall 后重新安装"

    [[ "${CDN_PROVIDER}" == "aws" ]] || die "状态 CDN_PROVIDER 不是 aws；请先执行 sudo easy_all uninstall 后重新安装"
    [[ "${CDN_TRAFFIC_PROTECTION_GB}" == "985" ]] \
        || die "状态中的 CDN 保护额度不是固定 985GB；请先执行 sudo easy_all uninstall 后重新安装"
    [[ "${AWS_ACM_CERTIFICATE_ARN}" == arn:aws:acm:us-east-1:* ]] \
        || die "ACM 证书 ARN 必须位于 us-east-1：${AWS_ACM_CERTIFICATE_ARN}"
    for variable in CF_ORIGIN_DOMAIN CF_NODE_DOMAIN SUBSCRIPTION_DOMAIN; do
        validate_domain "${!variable}" || die "状态中的域名无效：${variable}=${!variable}"
        [[ "${!variable}" == *".${CF_ZONE}" ]] \
            || die "状态中的域名不属于 ${CF_ZONE}：${!variable}"
    done
    [[ "${CF_ORIGIN_DOMAIN}" != "${CF_NODE_DOMAIN}" ]] \
        || die "状态中的源站域名不得等于节点域名"
    [[ "${CF_ORIGIN_DOMAIN}" != "${SUBSCRIPTION_DOMAIN}" ]] \
        || die "状态中的源站域名不得等于订阅域名"
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "状态中的源站头密钥无效"
    validate_xhttp_path "${XHTTP_PATH}" || die "状态中的 XHTTP 路径无效：${XHTTP_PATH}"
    validate_uuid "${VLESS_UUID}" || die "状态中的 VLESS UUID 无效"
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        validate_domain "${domain}" || die "状态中的直连域名无效：${domain}"
        [[ "${domain}" != "${CF_NODE_DOMAIN}" && "${domain}" != "${SUBSCRIPTION_DOMAIN}" ]] \
            || die "直连域名不得等于节点或订阅域名：${domain}"
    done < <(cdn_direct_domains)
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

# --- Subscription configuration ----------------------------------------------

cdn_local_node_names() {
    jq -cn --arg cloud "${CF_NODE_PREFIX}" --argjson direct "$(cdn_direct_node_names)" \
        '$direct + [$cloud]'
}

cdn_validate_local_node_names() {
    local cloud=${CF_NODE_PREFIX:-} direct
    validate_node_name "${cloud}" || {
        printf 'CloudFront 节点名无效：%s\n' "${cloud}" >&2
        return 1
    }
    cdn_node_name_reserved "${cloud}" && {
        printf 'CloudFront 节点名不能使用保留组名：%s\n' "${cloud}" >&2
        return 1
    }
    direct=$(cdn_direct_node_names)
    jq -e --arg cloud "${cloud}" '
        type == "array" and all(.[]; type == "string") and
        (index($cloud) | not) and (length == (unique | length))
    ' <<<"${direct}" >/dev/null || {
        printf '直连节点名无效、重复或与 CloudFront 节点重名\n' >&2
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

# --- AWS credentials (memory only) -------------------------------------------

collect_aws_credentials() {
    if [[ -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
        AWS_ACCESS_KEY_ID=$(prompt_secret 'AWS Access Key ID（仅限当前进程使用，不落盘）') \
            || die '缺少 AWS Access Key ID'
    fi
    [[ "${AWS_ACCESS_KEY_ID}" =~ ^[A-Za-z0-9]{16,128}$ ]] \
        || die "AWS Access Key ID 格式无效"
    if [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]]; then
        AWS_SECRET_ACCESS_KEY=$(prompt_secret 'AWS Secret Access Key（仅限当前进程使用，不落盘）') \
            || die '缺少 AWS Secret Access Key'
    fi
    [[ ${#AWS_SECRET_ACCESS_KEY} -ge 20 && ${#AWS_SECRET_ACCESS_KEY} -le 128 ]] \
        || die "AWS Secret Access Key 格式无效"
    [[ -z "${AWS_SESSION_TOKEN:-}" || ${#AWS_SESSION_TOKEN} -le 4096 ]] \
        || die "AWS Session Token 格式无效"
    export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_DEFAULT_REGION="${AWS_CONTROL_REGION}" AWS_PAGER=""
    [[ -z "${AWS_SESSION_TOKEN:-}" ]] || export AWS_SESSION_TOKEN
}

clear_aws_credentials() {
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_DEFAULT_REGION AWS_PAGER 2>/dev/null || true
}

clear_profile_credentials() {
    clear_aws_credentials
    unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" \
        "${RUNTIME_TMP}/cloudflare-api-payload" \
        "${RUNTIME_TMP}/origin-header" 2>/dev/null || true
}

aws_cli() {
    aws "${CLOUDFRONT_AWS_CLI_ARGS[@]}" "$@"
}

install_aws_cli() {
    command -v aws >/dev/null 2>&1 && return 0
    local arch temp_dir archive
    case "$(dpkg --print-architecture 2>/dev/null || true)" in
    arm64) arch=aarch64 ;;
    *) arch=x86_64 ;;
    esac
    info "安装 AWS CLI v2"
    temp_dir=$(make_temp_dir)
    archive="${temp_dir}/awscliv2.zip"
    curl -fsSL --retry 3 "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "${archive}" \
        || die "下载 AWS CLI v2 失败"
    unzip -q "${archive}" -d "${temp_dir}" || die "解压 AWS CLI v2 失败"
    "${temp_dir}/aws/install" --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli --update \
        || die "安装 AWS CLI v2 失败"
    hash -r
    command -v aws >/dev/null 2>&1 || die "AWS CLI 安装失败"
}

install_certbot() {
    command -v certbot >/dev/null 2>&1 && return 0
    export DEBIAN_FRONTEND=noninteractive
    apt-get -o DPkg::Lock::Timeout=300 update >/dev/null
    apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends certbot >/dev/null \
        || die "安装 certbot 失败"
    command -v certbot >/dev/null 2>&1 || die "certbot 安装失败"
}

# --- Install inputs -----------------------------------------------------------

cdn_validate_install_domains() {
    local domain
    for domain in "${CF_ORIGIN_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}"; do
        validate_domain "${domain}" || die "域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] || die "域名必须属于 ${CF_ZONE}：${domain}"
    done
    [[ "${CF_ORIGIN_DOMAIN}" != "${CF_NODE_DOMAIN}" ]] || die "源站域名必须与节点域名不同"
    [[ "${CF_ORIGIN_DOMAIN}" != "${SUBSCRIPTION_DOMAIN}" ]] || die "源站域名必须与订阅域名不同"
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        validate_domain "${domain}" || die "域名无效：${domain}"
        [[ "${domain}" == *".${CF_ZONE}" ]] || die "域名必须属于 ${CF_ZONE}：${domain}"
        [[ "${domain}" != "${CF_NODE_DOMAIN}" && "${domain}" != "${SUBSCRIPTION_DOMAIN}" ]] \
            || die "直连域名不得等于节点或订阅域名：${domain}"
    done < <(cdn_direct_domains | sort -u)
}

collect_cloudfront_install_inputs() {
    # 续装时续用从 install-identity.json 恢复的值做提示默认值，不得先生成新值再覆盖。
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' "${CF_ZONE:-}")")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"

    CF_ORIGIN_DOMAIN=$(normalize_domain "$(prompt_value '源站域名（解析至 VPS，灰云直连）' "${CF_ORIGIN_DOMAIN:-origin.${CF_ZONE}}")")
    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'CloudFront 节点域名（CNAME 指向分发，灰云）' "${CF_NODE_DOMAIN:-cf.${CF_ZONE}}")")
    SUBSCRIPTION_DOMAIN=$(normalize_domain "$(prompt_value '订阅域名（可与节点域名相同）' "${SUBSCRIPTION_DOMAIN:-${CF_NODE_DOMAIN}}")")
    cdn_validate_install_domains
    # 首装不经过 load_state：订阅渲染前必须在输入校验处派生运行时字段。
    cdn_derive_runtime_fields || die "运行时字段派生失败：缺少 CloudFront 节点域名"

    CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（Zone 只读 + DNS 编辑权限）') \
        || die '缺少 Cloudflare API Token'
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,100}$ ]] || die "Cloudflare Token 格式无效"
    collect_aws_credentials

    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP 路径无效"

    CF_NODE_PREFIX=$(prompt_value 'CloudFront 节点名（完整单节点名）' "${CF_NODE_PREFIX:-🇺🇸AWS}")
    validate_node_name "${CF_NODE_PREFIX}" || die "节点名无效（1-64 字符，不能含控制字符）"
    cdn_node_name_reserved "${CF_NODE_PREFIX}" && die "节点名不能使用保留组名：${CF_NODE_PREFIX}"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
        "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")")

    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"
    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "源站头密钥格式无效"

    SUBSCRIPTION_CONFIG=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}") \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes"
    cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" \
        || die "订阅配置无效：节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    cdn_validate_install_owner_token

    if [[ -z "${VPS_PUBLIC_IPV4:-}" ]]; then
        VPS_PUBLIC_IPV4=$(detect_public_ipv4) \
            || die "无法自动探测本机公网 IPv4"
    fi
    configure_cdn_traffic_protection
}

# --- Cloudflare token and DNS -------------------------------------------------

cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" && -s "${CLOUDFLARE_TOKEN_FILE}" ]]; then
        CLOUDFLARE_API_TOKEN=$(<"${CLOUDFLARE_TOKEN_FILE}")
    fi
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret 'Cloudflare API Token（Zone 只读 + DNS 编辑权限）') \
            || die '缺少 Cloudflare API Token'
    fi
    [[ "${CLOUDFLARE_API_TOKEN}" =~ ^[A-Za-z0-9_-]{20,512}$ ]] \
        || die "Cloudflare Token 格式无效"
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

cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" \
        "${RUNTIME_TMP}/cloudflare-api-payload" 2>/dev/null || true
}

cdn_record_belongs_to_easy_all() {
    [[ "${1:-}" == easy_all* ]]
}

dns_ensure_record() {
    local host=$1 type=$2 content=$3 proxied=$4 records same_type count record id current current_proxied comment conflict payload
    # 必须按名字查全部类型：同名 A 与目标 CNAME 的冲突只有放开类型过滤才看得见。
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" '' "${host}")
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
        cdn_record_belongs_to_easy_all "${comment}" \
            || die "Cloudflare ${host} 的 ${type} 记录与目标不一致；拒绝覆盖"
        cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" \
            "$(jq -cn --arg name "${host}" --arg type "${type}" --arg content "${content}" \
                --argjson proxied "${proxied}" --arg comment "${CDN_RECORD_COMMENT}" \
                '{type:$type,name:$name,content:$content,ttl:1,proxied:$proxied,comment:$comment}')" >/dev/null
        return 0
    fi
    # Cloudflare 不允许 CNAME 与其他记录同名共存；A 只与同名 CNAME 冲突。跨类型不自动转换。
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

cdn_wait_for_origin_dns() {
    local attempt answers
    for attempt in {1..30}; do
        answers=$(dig +short A "${CF_ORIGIN_DOMAIN}" 2>/dev/null || true)
        if [[ -n "${answers}" ]] && grep -Fxq "${VPS_PUBLIC_IPV4}" <<<"${answers}"; then
            return 0
        fi
        sleep 2
    done
    die "源站 A 记录尚未生效：${CF_ORIGIN_DOMAIN} -> ${VPS_PUBLIC_IPV4}；请检查灰云 DNS 后重试"
}

cdn_prepare_origin_dns() {
    local domain
    cdn_ensure_zone_id
    info "配置源站 A 记录（灰云直连）：${CF_ORIGIN_DOMAIN} -> ${VPS_PUBLIC_IPV4}"
    dns_ensure_record "${CF_ORIGIN_DOMAIN}" A "${VPS_PUBLIC_IPV4}" false
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        [[ "${domain}" != "${CF_ORIGIN_DOMAIN}" ]] || continue
        info "配置直连 A 记录（灰云直连）：${domain} -> ${VPS_PUBLIC_IPV4}"
        dns_ensure_record "${domain}" A "${VPS_PUBLIC_IPV4}" false
    done < <(cdn_direct_domains)
}

cdn_ensure_dns() {
    cdn_prepare_origin_dns
    if [[ -n "${AWS_CLOUDFRONT_DOMAIN:-}" ]]; then
        ensure_viewer_cnames
    fi
}

ensure_viewer_cnames() {
    [[ -n "${AWS_CLOUDFRONT_DOMAIN:-}" ]] || die "缺少 CloudFront 分发域名，无法创建 viewer 记录"
    cdn_ensure_zone_id
    info "配置节点域名解析（CNAME 灰云直出）：${CF_NODE_DOMAIN} -> ${AWS_CLOUDFRONT_DOMAIN}"
    dns_ensure_record "${CF_NODE_DOMAIN}" CNAME "${AWS_CLOUDFRONT_DOMAIN}" false
    if [[ "${SUBSCRIPTION_DOMAIN}" != "${CF_NODE_DOMAIN}" ]]; then
        info "配置订阅域名解析（CNAME 灰云直出）：${SUBSCRIPTION_DOMAIN} -> ${AWS_CLOUDFRONT_DOMAIN}"
        dns_ensure_record "${SUBSCRIPTION_DOMAIN}" CNAME "${AWS_CLOUDFRONT_DOMAIN}" false
    fi
}

# --- Origin Let's Encrypt certificate ----------------------------------------

cdn_certificate_san_hosts() {
    cloudflare_certificate_san_hosts "$@"
}

cdn_origin_certificate_covers() {
    local cert=${1:-${CERT_FILE}}
    [[ -s "${cert}" ]] || return 1
    cdn_certificate_san_hosts "${cert}" | grep -Fxq "${CF_ORIGIN_DOMAIN}"
}

cdn_origin_key_matches_certificate() {
    local cert=${1:-${CERT_FILE}} key=${2:-${KEY_FILE}}
    [[ -s "${cert}" && -s "${key}" ]] || return 1
    [[ "$(openssl x509 -in "${cert}" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | openssl dgst -sha256)" \
        == "$(openssl pkey -in "${key}" -pubout -outform DER 2>/dev/null \
            | openssl dgst -sha256)" ]]
}

# 链校验必须是「leaf + 中间链 + 系统信任库」：Certbot 的 fullchain.pem 是
# leaf→intermediate 拼接，而 openssl verify 不会把目标文件后面的 PEM 当成链输入。
# 拆分首个 PEM 块为 leaf、其余为 intermediates，用 -untrusted 显式传入；单证书
# 部署（无 intermediate）仍按普通 verify 处理。
cdn_origin_certificate_chain_valid() {
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
    awk '/-----BEGIN CERTIFICATE-----/ {count++} count == 1' "${cert}" >"${leaf}" \
        || status=1
    awk '/-----BEGIN CERTIFICATE-----/ {count++} count > 1' "${cert}" >"${intermediates}" \
        || status=1
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

# 非致命验收：候选文件与现用副本共用同一套链/域名/有效期/配对检查。
cdn_origin_certificate_check() {
    local cert=${1:-${CERT_FILE}} key=${2:-${KEY_FILE}}
    [[ -s "${cert}" ]] || { warn "源站证书不存在：${cert}"; return 1; }
    [[ -s "${key}" ]] || { warn "源站证书私钥不存在：${key}"; return 1; }
    openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1 \
        || { warn "源站证书已过期：${cert}"; return 1; }
    cdn_origin_certificate_covers "${cert}" \
        || { warn "源站证书未覆盖 ${CF_ORIGIN_DOMAIN}"; return 1; }
    cdn_origin_key_matches_certificate "${cert}" "${key}" \
        || { warn "源站证书与私钥不配对"; return 1; }
    cdn_origin_certificate_chain_valid "${cert}" \
        || { warn "源站证书链验证失败；自签或未受信任证书不能用于 CloudFront 回源"; return 1; }
}

cdn_verify_origin_certificate() {
    cdn_origin_certificate_check "${CERT_FILE}" "${KEY_FILE}" \
        || die "源站证书验收失败"
}

# 证书部署事务：先用候选文件完成全部验收，再备份现用证书/私钥与 Nginx 配置，
# 安装后验收并重载；任一步失败恢复备份并返回非零，LE 新 lineage 保留供重试。
# 可选参数为安装后验收函数（如 deploy hook 的 write_nginx_config）。
cdn_install_origin_lineage() {
    local accept=${1:-}
    local chain="${CERTBOT_LIVE_DIR}/fullchain.pem" key="${CERTBOT_LIVE_DIR}/privkey.pem"
    local workdir candidate_cert candidate_key backup had_cert=0 had_key=0 had_nginx=0
    [[ -s "${chain}" && -s "${key}" ]] || return 1
    install -d -m 0700 "${CERT_DIR}"
    workdir=$(make_temp_dir) || return 1
    candidate_cert="${workdir}/fullchain.pem"
    candidate_key="${workdir}/privkey.pem"
    backup="${workdir}/previous"
    install -d -m 0700 "${backup}"
    install -m 0644 "${chain}" "${candidate_cert}" || return 1
    install -m 0600 "${key}" "${candidate_key}" || return 1
    cdn_origin_certificate_check "${candidate_cert}" "${candidate_key}" \
        || { warn "新源站证书未通过验收；保留现用证书与 LE lineage"; return 1; }
    if [[ -f "${CERT_FILE}" ]]; then
        had_cert=1
        install -m 0644 "${CERT_FILE}" "${backup}/fullchain.pem" || return 1
    fi
    if [[ -f "${KEY_FILE}" ]]; then
        had_key=1
        install -m 0600 "${KEY_FILE}" "${backup}/private.key" || return 1
    fi
    if [[ -f "${NGINX_CONFIG}" ]]; then
        had_nginx=1
        install -m 0600 "${NGINX_CONFIG}" "${backup}/nginx.conf" || return 1
    fi
    if (
        install -m 0644 "${candidate_cert}" "${CERT_FILE}" || exit 1
        install -m 0600 "${candidate_key}" "${KEY_FILE}" || exit 1
        cdn_verify_origin_certificate || exit 1
        nginx -t >/dev/null 2>&1 || exit 1
        systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 || exit 1
        [[ -z "${accept}" ]] || "${accept}" || exit 1
    ); then
        rm -rf -- "${workdir}"
        return 0
    fi
    warn "源站证书部署失败，恢复部署前的现用证书、私钥与 Nginx 配置"
    if ((had_cert == 1)); then
        install -m 0644 "${backup}/fullchain.pem" "${CERT_FILE}" \
            || warn "恢复现用证书失败；请执行 sudo easy_all renew-cert"
    else
        rm -f -- "${CERT_FILE}"
    fi
    if ((had_key == 1)); then
        install -m 0600 "${backup}/private.key" "${KEY_FILE}" \
            || warn "恢复现用证书私钥失败；请执行 sudo easy_all renew-cert"
    else
        rm -f -- "${KEY_FILE}"
    fi
    if ((had_nginx == 1)); then
        install -m 0600 "${backup}/nginx.conf" "${NGINX_CONFIG}" \
            || warn "恢复 Nginx 配置失败；请检查 ${NGINX_CONFIG}"
    else
        rm -f -- "${NGINX_CONFIG}"
    fi
    nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 \
        || warn "恢复部署前 Nginx 配置后重载失败；请人工核对 nginx -t"
    rm -rf -- "${workdir}"
    return 1
}

cdn_origin_lineage_is_newer() {
    local chain="${CERTBOT_LIVE_DIR}/fullchain.pem"
    [[ -s "${chain}" ]] || return 1
    cdn_origin_certificate_covers "${chain}" || return 1
    cdn_origin_certificate_chain_valid "${chain}" || return 1
    openssl x509 -in "${chain}" -noout -checkend 0 >/dev/null 2>&1 || return 1
    if [[ -s "${CERT_FILE}" ]] && cmp -s "${chain}" "${CERT_FILE}"; then
        return 1
    fi
    return 0
}

cdn_write_origin_bootstrap_nginx() {
    install -d -m 0700 "${CERT_DIR}"
    install -d -m 0755 "${WEB_ROOT}"
    cat >"${RUNTIME_TMP}/easy_all-bootstrap.conf" <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CF_ORIGIN_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        try_files \$uri =404;
    }

    location / { return 404; }
}
EOF
    install -m 0600 "${RUNTIME_TMP}/easy_all-bootstrap.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "HTTP-01 引导 Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null 2>&1 || systemctl start nginx >/dev/null 2>&1 \
        || die "启动引导 Nginx 失败"
    systemctl reload nginx >/dev/null 2>&1 || systemctl restart nginx >/dev/null 2>&1 \
        || die "重载引导 Nginx 失败"
}

# 手动续签不是“到期待续”：certbot 默认会直接复用尚未到期的 lineage，必须显式
# --force-renewal 才能重新签发（仅 manual renew 传入；安装/自动 hook 不强制）。
cdn_run_certbot() {
    local skip_deploy=${1:-0} force=${2:-0}
    local -a certbot_args=(certonly --webroot -w "${WEB_ROOT}"
        -d "${CF_ORIGIN_DOMAIN}" --non-interactive --agree-tos
        --register-unsafely-without-email --cert-name "${CERTBOT_LINEAGE_NAME}")
    command -v certbot >/dev/null 2>&1 || die "缺少 certbot；无法申请源站证书"
    [[ "${force}" != "1" ]] || certbot_args+=(--force-renewal)
    if [[ "${skip_deploy}" == "1" ]]; then
        # 手动路径已持写锁：只让本次 certbot 子进程跳过自有 hook，由父命令部署。
        EASY_ALL_CERTBOT_SKIP_DEPLOY=1 certbot "${certbot_args[@]}" \
            || die "Certbot 源站证书申请失败"
    else
        certbot "${certbot_args[@]}" || die "Certbot 源站证书申请失败"
    fi
}

install_certbot_deploy_hook() {
    install -d -m 0700 "$(dirname -- "${CERTBOT_DEPLOY_HOOK_FILE}")"
    cat >"${RUNTIME_TMP}/easy-all-origin-deploy-hook.sh" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
# 手动 renew-cert/apply 持锁时由父命令完成部署，避免 hook 二次抢锁。
[[ "\${EASY_ALL_CERTBOT_SKIP_DEPLOY:-0}" == "1" ]] && exit 0
source "${COMMAND_INSTALL_DIR}/profiles/${CDN_PROFILE_KEY}.sh"
cloudfront_certbot_deploy_hook
EOF
    install -m 0700 "${RUNTIME_TMP}/easy-all-origin-deploy-hook.sh" "${CERTBOT_DEPLOY_HOOK_FILE}"
}

remove_certbot_deploy_hook() {
    rm -f -- "${CERTBOT_DEPLOY_HOOK_FILE}"
}

cdn_remove_origin_lineage() {
    local etc_dir
    etc_dir=$(dirname -- "$(dirname -- "${CERTBOT_LIVE_DIR}")")
    rm -rf -- "${CERTBOT_LIVE_DIR}" \
        "${etc_dir}/archive/${CERTBOT_LINEAGE_NAME}" \
        "${etc_dir}/renewal/${CERTBOT_LINEAGE_NAME}.conf"
}

cloudfront_certbot_deploy_hook() {
    [[ "${EASY_ALL_CERTBOT_SKIP_DEPLOY:-0}" == "1" ]] && return 0
    command -v flock >/dev/null 2>&1 || { warn "缺少 flock；拒绝在无锁状态部署证书"; return 1; }
    exec 9>"${RUNTIME_WRITE_LOCK_FILE}" || return 1
    if ! flock -w 30 9; then
        warn "证书部署 hook 未能取得运行时写锁；保留当前证书副本，请执行 sudo easy_all renew-cert"
        return 1
    fi
    collect_installed_state
    cdn_traffic_read_usage >/dev/null || {
        warn "无法校验 CDN 流量保护统计；拒绝部署源站证书"
        return 1
    }
    cdn_install_origin_lineage write_nginx_config || {
        warn "证书部署 hook 无法安装并验收有效的源站证书"
        return 1
    }
    success "源站证书已部署"
}

cdn_issue_origin_certificate() {
    local force=${1:-0}
    install -d -m 0700 "${CERT_DIR}"
    if [[ "${force}" != "1" ]] \
        && cdn_origin_certificate_covers "${CERT_FILE}" \
        && cdn_origin_key_matches_certificate \
        && openssl x509 -in "${CERT_FILE}" -noout -checkend "${ORIGIN_CERT_RENEW_SECONDS}" >/dev/null 2>&1; then
        cdn_verify_origin_certificate
        return 0
    fi
    info "为源站申请 Let's Encrypt 证书：${CF_ORIGIN_DOMAIN}"
    cdn_write_origin_bootstrap_nginx
    install_certbot_deploy_hook
    cdn_run_certbot 1
    cdn_install_origin_lineage || die "Certbot 未生成覆盖 ${CF_ORIGIN_DOMAIN} 的有效证书"
}

# --- ACM ----------------------------------------------------------------------

certificate_covers_required_domains() {
    local description=$1
    jq -e --arg primary "${CF_NODE_DOMAIN}" \
        --arg subscription "${SUBSCRIPTION_DOMAIN}" '
        def covers($name; $domain):
            $name == $domain or
            ($name|startswith("*.") and ($domain|endswith($name[1:])) and
             (($domain|split(".")|length) == ($name|split(".")|length)));
        ([.Certificate.DomainName] + (.Certificate.SubjectAlternativeNames // [])) as $names
        | all([$primary, $subscription] | unique[];
            . as $domain | any($names[]; covers(.; $domain)))
    ' <<<"${description}" >/dev/null
}

cdn_acm_certificate_reusable() {
    local description=${1:-}
    [[ -n "${description}" ]] || return 1
    [[ "$(jq -r '.Certificate.Status // empty' <<<"${description}")" == "ISSUED" ]] || return 1
    [[ "$(jq -r '.Certificate.CertificateArn // empty' <<<"${description}")" \
        == "arn:aws:acm:${AWS_CONTROL_REGION}:"* ]] || return 1
    certificate_covers_required_domains "${description}"
}

cdn_describe_acm_certificate() {
    local arn=$1 description
    description=$(aws_cli acm describe-certificate --region "${AWS_CONTROL_REGION}" \
        --certificate-arn "${arn}" --output json 2>/dev/null) || return 1
    printf '%s\n' "${description}"
}

# 管理标记：新建证书同时写 easy_all=managed 与 easy_all-node=<节点域名>。
acm_certificate_managed_by_easy_all() {
    jq -e --arg node "${CF_NODE_DOMAIN}" '
        ([.Tags[]? | select(.Key == "easy_all" and .Value == "managed")] | length) >= 1 and
        ([.Tags[]? | select(.Key == "easy_all-node" and .Value == $node)] | length) >= 1
    ' <<<"${1:-}" >/dev/null 2>&1
}

# ACM 可删除前提：us-east-1、InUseBy 为空、SAN 覆盖本链路，且两个管理标记都在。
acm_certificate_owned_by_easy_all() {
    local description=$1 tags=$2
    [[ "${AWS_ACM_CERTIFICATE_ARN:-}" == "arn:aws:acm:${AWS_CONTROL_REGION}:"* ]] || return 1
    [[ "$(jq '.Certificate.InUseBy // [] | length' <<<"${description}" 2>/dev/null)" == "0" ]] || return 1
    certificate_covers_required_domains "${description}" || return 1
    acm_certificate_managed_by_easy_all "${tags}"
}

# RequestCertificate 的 IdempotencyToken 只接受 \w+ 且不超过 32 字符：取节点 marker 的
# sha256 摘要前 28 位加固定前缀，确定性与域名长度无关，也不含点/连字符。
cloudfront_acm_idempotency_token() {
    local digest
    digest=$(printf '%s' "$(cloudfront_marker)" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')
    [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf 'eacf%s' "${digest:0:28}"
}

# ACM 无状态发现：固定 us-east-1、完整 NextToken 分页、逐个核对管理标记。
# 0=唯一候选（stdout 输出 ARN）；1=完整分页确认零候选；其余异常 die（错误不得进入新建）。
find_existing_acm_certificate() {
    local next="" page arn description tags candidate="" matches=0 pages=0 seen="|"
    local -a arns=()
    while :; do
        local -a page_args=(acm list-certificates --region "${AWS_CONTROL_REGION}" --output json)
        [[ -z "${next}" ]] || page_args+=(--next-token "${next}")
        page=$(aws_cli "${page_args[@]}") || die "列举 ACM 证书失败或权限不足；未创建新证书"
        while IFS= read -r arn; do
            [[ -n "${arn}" ]] || continue
            arns+=("${arn}")
        done < <(jq -r '.CertificateSummaryList[]?.CertificateArn // empty' <<<"${page}")
        next=$(jq -r '.NextToken // empty' <<<"${page}")
        [[ -n "${next}" ]] || break
        [[ "${seen}" != *"|${next}|"* ]] || die "ACM 分页 NextToken 重复（${next}）；未创建新证书"
        seen="${seen}${next}|"
        pages=$((pages + 1))
        ((pages <= 200)) || die "ACM 分页超过上限（${pages} 页）；未创建新证书"
    done
    if ((${#arns[@]} == 0)); then
        return 1
    fi
    for arn in "${arns[@]}"; do
        tags=$(aws_cli acm list-tags-for-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${arn}" --output json 2>/dev/null) \
            || die "读取 ACM 证书标签失败（${arn}）；未创建新证书"
        acm_certificate_managed_by_easy_all "${tags}" || continue
        matches=$((matches + 1))
        candidate=${arn}
    done
    ((matches <= 1)) \
        || die "当前 AWS 账号存在 ${matches} 个 ${CF_NODE_DOMAIN} 的 easy_all ACM 证书；请先人工核对并清理重复资源"
    ((matches == 1)) || return 1
    description=$(cdn_describe_acm_certificate "${candidate}") \
        || die "读取 ACM 证书失败（${candidate}）；未创建新证书"
    cdn_acm_certificate_reusable "${description}" \
        || die "ACM 证书 ${candidate} 带本节点管理标记但不可复用（状态/SAN/region 不符）；请人工核对后重试"
    printf '%s\n' "${candidate}"
}

find_or_request_acm_certificate() {
    local arn="" description="" status attempt token
    local discovered="${RUNTIME_TMP}/acm-discovery.txt"
    local discovery_status=0
    local -a request_arguments
    info "检查并申请 AWS ACM 证书（us-east-1）"
    if [[ -n "${AWS_ACM_CERTIFICATE_ARN:-}" ]]; then
        description=$(cdn_describe_acm_certificate "${AWS_ACM_CERTIFICATE_ARN}" || true)
        if cdn_acm_certificate_reusable "${description}"; then
            arn=${AWS_ACM_CERTIFICATE_ARN}
        else
            warn "现有 ACM 证书不可复用（状态/region/SAN 不满足）；将申请新证书"
        fi
    else
        # 无状态发现只作用于当前显式凭据所属账号；发现失败不得降级为新建。
        cloudfront_verify_caller_identity
        find_existing_acm_certificate >"${discovered}" || discovery_status=$?
        case "${discovery_status}" in
        0)
            arn=$(<"${discovered}")
            [[ -n "${arn}" ]] || die "发现的 ACM 证书 ARN 为空；未创建新证书"
            AWS_ACM_CERTIFICATE_ARN=${arn}
            info "复用当前账号的 easy_all ACM 证书：${arn}"
            ;;
        1) ;;
        *) die "ACM 证书发现失败（退出码 ${discovery_status}）；未创建新证书" ;;
        esac
    fi
    if [[ -z "${arn}" ]]; then
        token=$(cloudfront_acm_idempotency_token) || die "生成 ACM 证书幂等 Token 失败"
        request_arguments=(acm request-certificate --region "${AWS_CONTROL_REGION}"
            --domain-name "${CF_NODE_DOMAIN}" --validation-method DNS
            --idempotency-token "${token}"
            --tags "Key=easy_all,Value=managed" "Key=easy_all-node,Value=${CF_NODE_DOMAIN}"
            --query CertificateArn --output text)
        if [[ "${SUBSCRIPTION_DOMAIN}" != "${CF_NODE_DOMAIN}" ]]; then
            request_arguments+=(--subject-alternative-names "${SUBSCRIPTION_DOMAIN}")
        fi
        arn=$(aws_cli "${request_arguments[@]}") || die "申请 ACM 证书失败"
        AWS_ACM_CERTIFICATE_ARN=${arn}
    fi
    # 每收到 ARN 立即落盘：失败后仍可追踪已创建的云端证书。
    persist_install_identity \
        || die "无法落盘安装身份；已保留 ACM 证书，请修复后重试"

    for attempt in {1..20}; do
        description=$(aws_cli acm describe-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" --output json 2>/dev/null || true)
        if [[ -n "${description}" ]] \
            && [[ "$(jq '[.Certificate.DomainValidationOptions[]?|select(.ResourceRecord)]|length' <<<"${description}")" -ge 1 ]]; then
            break
        fi
        sleep 2
    done
    [[ -n "${description}" ]] || die "无法读取 ACM 证书验证信息"

    status=$(jq -r '.Certificate.Status // empty' <<<"${description}")
    if [[ "${status}" != "ISSUED" ]]; then
        info "自动在 Cloudflare 添加 ACM DNS 验证记录"
        while IFS=$'\t' read -r record_name record_type record_value; do
            [[ -n "${record_name}" && -n "${record_value}" ]] || continue
            dns_ensure_record "${record_name%.}" "${record_type}" "${record_value%.}" false
        done < <(jq -r '.Certificate.DomainValidationOptions[]?|select(.ResourceRecord)|
            [.ResourceRecord.Name,.ResourceRecord.Type,.ResourceRecord.Value]|@tsv' <<<"${description}")

        info "等待 ACM 证书通过验证并签发（通常约 1~3 分钟）..."
        for attempt in {1..60}; do
            status=$(aws_cli acm describe-certificate --region "${AWS_CONTROL_REGION}" \
                --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" --query Certificate.Status \
                --output text 2>/dev/null || true)
            if [[ "${status}" == "ISSUED" ]]; then
                success "ACM 证书验证通过并已成功颁发"
                return 0
            fi
            sleep 5
        done
        die "等待 ACM 证书签发超时；请检查 Cloudflare validation CNAME"
    fi
}

# --- CloudFront distribution --------------------------------------------------

cloudfront_marker() {
    printf 'easy_all-cloudfront-%s' "${CF_NODE_DOMAIN}"
}

build_distribution_config() {
    local destination=$1 caller=$2
    jq -n \
        --arg caller "${caller}" --arg alias "${CF_NODE_DOMAIN}" \
        --arg subscription "${SUBSCRIPTION_DOMAIN}" \
        --arg origin "${CF_ORIGIN_DOMAIN}" --arg origin_id "${CLOUDFRONT_ORIGIN_ID}" \
        --arg origin_key "${ORIGIN_HEADER_SECRET}" --arg comment "$(cloudfront_marker)" \
        --arg cache_policy "${CLOUDFRONT_CACHE_POLICY_ID}" \
        --arg origin_policy "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}" \
        --argjson connection_attempts "${CLOUDFRONT_CONNECTION_ATTEMPTS}" \
        --argjson connection_timeout "${CLOUDFRONT_CONNECTION_TIMEOUT}" \
        --argjson origin_read_timeout "${CLOUDFRONT_ORIGIN_READ_TIMEOUT}" \
        --argjson origin_keepalive_timeout "${CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT}" \
        --arg certificate "${AWS_ACM_CERTIFICATE_ARN}" '
        {
          CallerReference:$caller,
          Aliases:(([$alias,$subscription]|unique) as $items |
            {Quantity:($items|length),Items:$items}),
          DefaultRootObject:"",
          Origins:{Quantity:1,Items:[{
            Id:$origin_id,DomainName:$origin,OriginPath:"",
            CustomHeaders:{Quantity:1,Items:[{HeaderName:"X-Easy-All-Origin-Key",HeaderValue:$origin_key}]},
            CustomOriginConfig:{HTTPPort:80,HTTPSPort:443,OriginProtocolPolicy:"https-only",
              OriginSslProtocols:{Quantity:1,Items:["TLSv1.2"]},
              OriginReadTimeout:$origin_read_timeout,OriginKeepaliveTimeout:$origin_keepalive_timeout},
            ConnectionAttempts:$connection_attempts,ConnectionTimeout:$connection_timeout,
            OriginShield:{Enabled:false}
          }]},
          OriginGroups:{Quantity:0},
          DefaultCacheBehavior:{
            TargetOriginId:$origin_id,
            TrustedSigners:{Enabled:false,Quantity:0},TrustedKeyGroups:{Enabled:false,Quantity:0},
            ViewerProtocolPolicy:"https-only",
            AllowedMethods:{Quantity:7,Items:["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"],
              CachedMethods:{Quantity:2,Items:["GET","HEAD"]}},
            GrpcConfig:{Enabled:true},
            SmoothStreaming:false,Compress:false,
            LambdaFunctionAssociations:{Quantity:0},FunctionAssociations:{Quantity:0},
            FieldLevelEncryptionId:"",CachePolicyId:$cache_policy,OriginRequestPolicyId:$origin_policy
          },
          CacheBehaviors:{Quantity:0},CustomErrorResponses:{Quantity:0},
          Comment:$comment,Logging:{Enabled:false,IncludeCookies:false,Bucket:"",Prefix:""},
          PriceClass:"PriceClass_All",Enabled:true,
          ViewerCertificate:{CloudFrontDefaultCertificate:false,ACMCertificateArn:$certificate,
            SSLSupportMethod:"sni-only",MinimumProtocolVersion:"TLSv1.2_2021"},
          Restrictions:{GeoRestriction:{RestrictionType:"none",Quantity:0}},
          WebACLId:"",HttpVersion:"http2",IsIPV6Enabled:true,Staging:false,
          ContinuousDeploymentPolicyId:""
        }' >"${destination}"
}

cloudfront_verify_caller_identity() {
    local account
    account=$(aws_cli sts get-caller-identity --query Account --output text 2>/dev/null) \
        || die "无法确认当前 AWS 账号（sts get-caller-identity 失败）；未创建新资源"
    [[ "${account}" =~ ^[0-9]{12}$ ]] \
        || die "当前 AWS 账号 ID 无效（${account}）；未创建新资源"
}

# 状态 ID 不等于所有权：marker、去重后的 alias 集合与源站拓扑都必须与当前状态一致。
cloudfront_distribution_owned_by_easy_all() {
    local distribution=$1
    jq -e --arg comment "$(cloudfront_marker)" \
        --arg node "${CF_NODE_DOMAIN}" --arg subscription "${SUBSCRIPTION_DOMAIN}" \
        --arg origin "${CF_ORIGIN_DOMAIN}" '
        (.DistributionConfig.Comment // "") == $comment and
        ([.DistributionConfig.Aliases.Items[]?] | unique | sort) == ([$node,$subscription] | unique | sort) and
        ((.DistributionConfig.Origins.Items // []) | length) == 1 and
        (.DistributionConfig.Origins.Items[0].DomainName // "") == $origin
    ' <<<"${distribution}" >/dev/null 2>&1
}

# 任何 update/disable/delete 前的统一归属校验：读取 get-distribution-config，通过时把
# 完整响应（含 ETag）写入 $2；失败不写文件并返回 1，调用方不得再写云端。
cloudfront_read_owned_distribution() {
    local id=$1 output=$2 description
    description=$(aws_cli cloudfront get-distribution-config --id "${id}" --output json 2>/dev/null) \
        || { warn "读取 CloudFront 分发失败（ID：${id}）"; return 1; }
    cloudfront_distribution_owned_by_easy_all "${description}" \
        || { warn "CloudFront 分发归属校验失败（marker/alias/源站不匹配；ID：${id}）"; return 1; }
    printf '%s\n' "${description}" >"${output}"
    chmod 0600 "${output}"
}

# 无本地状态时的云端复用：只读 DistributionSummary（Id/DomainName/Comment/Aliases.Items，
# 没有 DistributionConfig），完成全部分页并顺手核对 alias 是否已被外部占用。
# 0=唯一候选（stdout 输出 {Id,DomainName}）；1=完整分页确认零候选；其余异常 die。
cloudfront_find_existing_distribution() {
    local marker next="" page truncated summary comment aliases count foreign_alias=0 pages=0 seen="|"
    marker=$(cloudfront_marker)
    local -a collected=()
    while :; do
        local -a page_args=(cloudfront list-distributions --output json)
        [[ -z "${next}" ]] || page_args+=(--marker "${next}")
        page=$(aws_cli "${page_args[@]}") \
            || die "列举 CloudFront 分发失败或权限不足；未创建新资源"
        while IFS= read -r summary; do
            [[ -n "${summary}" ]] || continue
            comment=$(jq -r '.Comment // empty' <<<"${summary}")
            if [[ "${comment}" == "${marker}" ]]; then
                collected+=("${summary}")
                continue
            fi
            aliases=$(jq -c '[.Aliases.Items[]?]' <<<"${summary}")
            if jq -e --arg node "${CF_NODE_DOMAIN}" --arg subscription "${SUBSCRIPTION_DOMAIN}" '
                any(.[]; . == $node or . == $subscription)
            ' <<<"${aliases}" >/dev/null 2>&1; then
                # 发现函数的 stdout 只输出候选 JSON，诊断信息一律走 stderr。
                warn "CloudFront 别名已被其他分发占用（$(jq -r '.Id // "?"' <<<"${summary}")）：${CF_NODE_DOMAIN}/${SUBSCRIPTION_DOMAIN}" >&2
                foreign_alias=1
            fi
        done < <(jq -c '.DistributionList.Items[]?' <<<"${page}")
        truncated=$(jq -r '.DistributionList.IsTruncated // false' <<<"${page}")
        next=$(jq -r '.DistributionList.NextMarker // empty' <<<"${page}")
        if [[ -z "${next}" ]]; then
            [[ "${truncated}" != "true" ]] \
                || die "CloudFront 分页不完整（IsTruncated=true 但缺少 NextMarker）；未创建新资源"
            break
        fi
        [[ "${truncated}" == "true" ]] \
            || die "CloudFront 分页标记与 IsTruncated 不一致（${next}）；未创建新资源"
        [[ "${seen}" != *"|${next}|"* ]] \
            || die "CloudFront 分页 marker 重复（${next}）；未创建新资源"
        seen="${seen}${next}|"
        pages=$((pages + 1))
        ((pages <= 200)) || die "CloudFront 分页超过上限（${pages} 页）；未创建新资源"
    done
    if ((foreign_alias != 0)); then
        die "CloudFront 别名 ${CF_NODE_DOMAIN}/${SUBSCRIPTION_DOMAIN} 已被其他分发占用；请人工核对后重试"
    fi
    count=${#collected[@]}
    ((count <= 1)) \
        || die "当前 AWS 账号存在 ${count} 个 easy_all CloudFront 分发；请先人工核对并清理重复资源"
    ((count == 1)) || return 1
    jq -c '{Id:(.Id // ""), DomainName:(.DomainName // "")}' <<<"${collected[0]}"
}

wait_for_cloudfront_distribution() {
    local id=$1 attempt status
    for attempt in $(seq 1 "${CLOUDFRONT_DEPLOY_WAIT_ATTEMPTS}"); do
        status=$(aws_cli cloudfront get-distribution --id "${id}" \
            --query 'Distribution.Status' --output text 2>/dev/null || true)
        [[ "${status}" == "Deployed" ]] && return 0
        sleep "${CLOUDFRONT_DEPLOY_WAIT_SECONDS}"
    done
    return 1
}

configure_cloudfront_distribution() {
    local config existing etag caller response distribution
    local discovered="${RUNTIME_TMP}/cloudfront-discovery.json"
    local fetched="${RUNTIME_TMP}/cloudfront-owned-config.json"
    local discovery_status=0
    config="${RUNTIME_TMP}/cloudfront-distribution.json"
    info "配置 CloudFront 分发..."
    if [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}" ]]; then
        # 状态 ID 不等于所有权：update 之前必须完成统一归属校验。
        cloudfront_read_owned_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${fetched}" \
            || die "读取 CloudFront 分发失败或归属不符（ID：${AWS_CLOUDFRONT_DISTRIBUTION_ID}）；已保留现有云端资源，未写入云端"
        existing=$(<"${fetched}")
    else
        # 无状态发现：先确认当前账号可用，再用完整分页的 summary 找唯一候选。
        cloudfront_verify_caller_identity
        cloudfront_find_existing_distribution >"${discovered}" || discovery_status=$?
        case "${discovery_status}" in
        0)
            AWS_CLOUDFRONT_DISTRIBUTION_ID=$(jq -r '.Id // empty' "${discovered}")
            AWS_CLOUDFRONT_DOMAIN=$(jq -r '.DomainName // empty' "${discovered}")
            [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" && -n "${AWS_CLOUDFRONT_DOMAIN}" ]] \
                || die "发现的 CloudFront 分发缺少 ID 或域名；未创建新资源"
            # 已知分发 ID/domain 就先落盘，后续 update 失败仍能追踪该云端资源。
            persist_install_identity \
                || die "无法落盘安装身份；已保留云端资源（ID：${AWS_CLOUDFRONT_DISTRIBUTION_ID}）"
            cloudfront_read_owned_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${fetched}" \
                || die "发现的 CloudFront 分发未通过归属校验；已保留云端资源，未写入云端"
            existing=$(<"${fetched}")
            ;;
        1) existing="" ;;
        *) die "CloudFront 分发发现失败（退出码 ${discovery_status}）；未创建新资源" ;;
        esac
    fi
    if [[ -n "${existing}" ]]; then
        etag=$(jq -r '.ETag' <<<"${existing}")
        caller=$(jq -r '.DistributionConfig.CallerReference' <<<"${existing}")
        build_distribution_config "${config}" "${caller}"
        response=$(aws_cli cloudfront update-distribution --id "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" \
            --if-match "${etag}" --distribution-config "file://${config}" --output json) \
            || die "更新 CloudFront 分发失败；已保留现有云端资源"
    else
        caller="easy_all-cf-$(date +%s)-$(openssl rand -hex 4)"
        build_distribution_config "${config}" "${caller}"
        response=$(aws_cli cloudfront create-distribution \
            --distribution-config "file://${config}" --output json) \
            || die "创建 CloudFront 分发失败；请核对账号限制后重试"
    fi
    distribution=$(jq -c '.Distribution' <<<"${response}")
    AWS_CLOUDFRONT_DISTRIBUTION_ID=$(jq -r '.Id' <<<"${distribution}")
    AWS_CLOUDFRONT_DOMAIN=$(jq -r '.DomainName' <<<"${distribution}")
    [[ -n "${AWS_CLOUDFRONT_DOMAIN}" && "${AWS_CLOUDFRONT_DOMAIN}" != "null" ]] \
        || die "未能获取 CloudFront 分发域名"
    # 每收到 ARN/分发 ID/domain 立即落盘，失败后仍可追踪云端资源。
    persist_install_identity || die "无法落盘安装身份；已保留云端资源，请修复后重试"
    success "CloudFront 分发配置成功：${AWS_CLOUDFRONT_DOMAIN}"
}

# --- Local probe context ------------------------------------------------------

cdn_origin_probe_header_file() {
    local header_file="${RUNTIME_TMP}/origin-header"
    install -d -m 0700 "${RUNTIME_TMP}"
    printf 'X-Easy-All-Origin-Key: %s\n' "${ORIGIN_HEADER_SECRET:-}" >"${header_file}"
    chmod 0600 "${header_file}"
    printf '%s\n' "${header_file}"
}

xhttp_local_probe_context() {
    XHTTP_LOCAL_PROBE_DOMAIN=${CF_ORIGIN_DOMAIN}
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https' --noproxy '*')
    XHTTP_LOCAL_PROBE_HEADER_FILE=$(cdn_origin_probe_header_file)
}

cdn_local_curl() {
    local path=$1
    local -a probe_args=(-s)
    [[ -z "${XHTTP_LOCAL_PROBE_HEADER_FILE:-}" ]] \
        || probe_args+=(--header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}")
    curl --noproxy '*' --connect-timeout 5 --max-time 20 \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" "${probe_args[@]}" \
        --resolve "${XHTTP_LOCAL_PROBE_DOMAIN}:443:127.0.0.1" \
        "https://${XHTTP_LOCAL_PROBE_DOMAIN}${path}"
}

cdn_xhttp_request_status() {
    local status
    local -a probe_args=(-o /dev/null -w '%{http_code}')
    [[ -z "${XHTTP_LOCAL_PROBE_HEADER_FILE:-}" ]] \
        || probe_args+=(--header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}")
    status=$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 20 \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" "${probe_args[@]}" \
        --resolve "${XHTTP_LOCAL_PROBE_DOMAIN}:443:127.0.0.1" \
        "https://${XHTTP_LOCAL_PROBE_DOMAIN}${XHTTP_PATH}/") || return 1
    printf '%s\n' "${status}"
}

cdn_validate_xhttp_blocked() {
    local status
    xhttp_local_probe_context
    status=$(cdn_xhttp_request_status) || die "受限 XHTTP 阻断验收请求失败"
    [[ "${status}" == "503" ]] || die "受限 XHTTP 未返回 503（HTTP ${status}）"
}

# 安装 services 阶段（Xray 刚启动）立即断言真实 StatsService 读数：timer 只是后续采样器，
# 计量接口不可用必须现在就让安装失败，而不是等 15 秒后的定时任务才发现。
cdn_verify_traffic_api() {
    local attempt stats up down
    for ((attempt = 1; attempt <= CDN_TRAFFIC_API_VERIFY_ATTEMPTS; attempt++)); do
        if stats=$("${XRAY_BIN}" api statsquery --server="${CDN_TRAFFIC_API_LISTEN}" 2>/dev/null) \
            && IFS=$'\t' read -r up down <<<"$(cdn_traffic_stats_totals "${stats}" 2>/dev/null)" \
            && [[ "${up}" =~ ^[0-9]+$ && "${down}" =~ ^[0-9]+$ ]]; then
            return 0
        fi
        ((attempt == CDN_TRAFFIC_API_VERIFY_ATTEMPTS)) || sleep "${CDN_TRAFFIC_API_VERIFY_SECONDS}"
    done
    die "Xray 计量接口 ${CDN_TRAFFIC_API_LISTEN} 未返回 ${CDN_TRAFFIC_XHTTP_INBOUND} 的 uplink/downlink 计数（必须为合法非负整数，零流量即 0）；请检查 Xray 是否运行、API 入站与 stats 配置是否完整（systemctl status ${XRAY_SERVICE}），修复后重试 apply"
}

# --- Public acceptance --------------------------------------------------------
#
# 本机验收（--resolve 127.0.0.1）不能证明真实公网链路：DNS 指向、CloudFront 已 Deployed、
# ACM 证书与源站头注入都可能在这里才暴露。公网探测一律走真实域名 + 系统 CA，禁止 -k。

cdn_public_curl() {
    curl -sS --proto '=https' --noproxy '*' --connect-timeout 5 --max-time 30 "$@"
}

# 节点 alias 返回固定 health 文本：能返回完整证据 CloudFront 已注入源站头并回源成功。
cdn_public_health_ok() {
    local body
    body=$(cdn_public_curl "https://${CF_NODE_DOMAIN}/easy_all-health") || return 1
    [[ "${body}" == "easy_all ok" ]]
}

# 源站域名是公网可见的 A 记录，也是源站头校验真正生效的地方（CloudFront 总会注入配置好的
# 头，因此无法用节点域名探测“缺头/错头”）。无头与错头都必须被拒。
cdn_public_origin_header_guard_ok() {
    local status
    status=$(cdn_public_curl -o /dev/null -w '%{http_code}' \
        "https://${CF_ORIGIN_DOMAIN}${XHTTP_PATH}/") || return 1
    [[ "${status}" == "403" || "${status}" == "404" ]] || return 1
    status=$(cdn_public_curl -o /dev/null -w '%{http_code}' \
        --header 'X-Easy-All-Origin-Key: wrong-origin-key' \
        "https://${CF_ORIGIN_DOMAIN}${XHTTP_PATH}/") || return 1
    [[ "${status}" == "403" || "${status}" == "404" ]]
}

cdn_public_subscription_ok() {
    local token body decoded
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS:-[]}") || return 1
    [[ -n "${token}" && "${token}" != "null" ]] || return 1
    # 正确 Token：默认 Base64 必须含 type=xhttp，强制 clash 必须含 network: xhttp。
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    decoded=$(printf '%s' "${body}" | openssl base64 -d -A 2>/dev/null) || return 1
    [[ "${decoded}" == *"type=xhttp"* ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"network: xhttp"* ]] || return 1
    # os=ios 走 Mihomo iOS 变体，node=all 走带 optional 节点的额外产物。
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' --data-urlencode 'os=ios' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"network: xhttp"* ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'node=all' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    decoded=$(printf '%s' "${body}" | openssl base64 -d -A 2>/dev/null) || return 1
    [[ "${decoded}" == *"type=xhttp"* ]]
}

cdn_public_token_rejection_ok() {
    local status
    status=$(cdn_public_curl -o /dev/null -w '%{http_code}' \
        --get --data-urlencode 'token=invalid' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${status}" == "403" ]]
}

# 公网验收：DNS 与分发传播有有限重试；任一必需项持续失败则非零，调用方不得报成功。
cdn_validate_public_runtime() {
    local attempt
    for ((attempt = 1; attempt <= CDN_PUBLIC_ACCEPT_ATTEMPTS; attempt++)); do
        if cdn_public_health_ok \
            && cdn_public_subscription_ok \
            && cdn_public_token_rejection_ok \
            && cdn_public_origin_header_guard_ok; then
            return 0
        fi
        ((attempt == CDN_PUBLIC_ACCEPT_ATTEMPTS)) || sleep "${CDN_PUBLIC_ACCEPT_SECONDS}"
    done
    die "CloudFront 公网验收失败（已重试 ${CDN_PUBLIC_ACCEPT_ATTEMPTS} 次）：请确认 ${CF_NODE_DOMAIN} 与 ${SUBSCRIPTION_DOMAIN} 的 CNAME 已指向 ${AWS_CLOUDFRONT_DOMAIN:-CloudFront 分发域名}、分发已 Deployed、源站证书有效；修复后执行 sudo easy_all apply-cloud"
}

# --- Nginx --------------------------------------------------------------------

cdn_subscription_available() {
    [[ "${CDN_SUBSCRIPTION_CORRUPT:-0}" == "0" ]] && cdn_config_ready
}

cdn_render_nginx_config() {
    local blocked=${1:-0} subscription_ok=${2:-1}
    local http2_directive="" listen_h2="http2 "
    if (($# >= 3)); then
        http2_directive=$3
        listen_h2=$4
    elif nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    if [[ "${subscription_ok}" == "1" ]]; then
        write_subscription_nginx_maps 1
    fi
    cat <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${CF_ORIGIN_DOMAIN};

    location /.well-known/acme-challenge/ {
        root ${WEB_ROOT};
        try_files \$uri =404;
    }

    location / { return 404; }
}

server {
    listen 443 ssl ${listen_h2}default_server;
    server_name _;
    ssl_reject_handshake on;
}

server {
    listen 443 ssl ${listen_h2};
    server_name ${CF_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;${http2_directive}
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        return 200 "easy_all ok";
    }

    location ^~ ${XHTTP_PATH}/ {
        access_log off;
        client_max_body_size 0;
        client_body_timeout ${XHTTP_NGINX_STREAM_TIMEOUT};
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 403; }
EOF
    if [[ "${blocked}" == "1" ]]; then
        cat <<EOF
        return 503;
    }
EOF
    else
        cat <<EOF
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
    fi
    cat <<EOF

    location / { return 404; }
EOF
    if [[ "${subscription_ok}" == "1" ]]; then
        write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}" static 1
    else
        cat <<EOF

    location = /subscribe {
        access_log off;
        return 503;
    }
EOF
    fi
    cat <<EOF
}
EOF
}

cdn_traffic_blocked_now() {
    local usage
    usage=$(cdn_traffic_read_usage) || return 1
    jq -e '.blocked == true' <<<"${usage}" >/dev/null
}

# 生成并应用指定的 Nginx 配置；失败用 die 报告，调用方需要在失败后继续后续边界时放进子 shell。
cdn_write_nginx_config() {
    local blocked=$1 subscription_ok=$2
    cdn_render_nginx_config "${blocked}" "${subscription_ok}" >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null 2>&1 || true
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

write_nginx_config() {
    local blocked=${1:-} subscription_ok
    install -d -m 0755 "${WEB_ROOT}"
    if [[ -z "${blocked}" ]]; then
        blocked=0
        cdn_traffic_blocked_now && blocked=1
    fi
    subscription_ok=0
    if [[ "${CDN_SUBSCRIPTION_DENIED:-0}" != "1" ]] && cdn_subscription_available; then
        subscription_ok=1
    fi
    cdn_write_nginx_config "${blocked}" "${subscription_ok}"
}

# 已有阻断且订阅未就绪：/subscribe 必须降级为 503，不得继续提供旧产物。
cdn_deny_subscription_runtime() {
    CDN_SUBSCRIPTION_DENIED=1
    install -d -m 0755 "${WEB_ROOT}"
    # 写入失败用 die 报告：放进子 shell 只取退出码，调用方仍要继续记账并保持阻断。
    ( cdn_write_nginx_config 1 0 )
}

# --- Xray ---------------------------------------------------------------------

cdn_xhttp_clients_json() {
    local blocked=$1
    if [[ "${blocked}" == "1" ]]; then
        printf '[]'
    else
        jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" '[{id:$id,email:$email}]'
    fi
}

cdn_xray_routing_json() {
    local blocked=$1 managed_routing
    managed_routing=$(xray_xhttp_routing_json)
    jq -c --argjson blocked "${blocked}" \
        --arg api "${CDN_TRAFFIC_API_INBOUND_TAG}" --arg xhttp "vless-xhttp-in" '
        .rules = ([{type:"field",inboundTag:[$api],outboundTag:$api}]
          + (if $blocked == 1 then [{type:"field",inboundTag:[$xhttp],outboundTag:"block"}] else [] end)
          + (.rules // []))
    ' <<<"${managed_routing}"
}

render_xray_config() {
    local blocked=${1:-0} clients direct_inbounds managed_outbounds managed_routing inbound_sockopt
    local api_port=${CDN_TRAFFIC_API_LISTEN##*:}
    install -d -m 0755 "${XRAY_DIR}"
    clients=$(cdn_xhttp_clients_json "${blocked}")
    direct_inbounds=$(cdn_direct_inbounds_json)
    [[ -n "${direct_inbounds}" ]] || direct_inbounds='[]'
    managed_outbounds=$(xray_xhttp_outbounds_json)
    managed_routing=$(cdn_xray_routing_json "${blocked}")
    inbound_sockopt=$(xray_inbound_sockopt_json)
    jq -n \
        --argjson direct_inbounds "${direct_inbounds}" \
        --argjson clients "${clients}" \
        --argjson xhttp_port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson api_port "${api_port}" \
        --arg api_tag "${CDN_TRAFFIC_API_INBOUND_TAG}" \
        --arg xhttp_path "${XHTTP_PATH}" --arg xhttp_host "${CF_NODE_DOMAIN}" \
        --arg x_padding_bytes "${CLOUDFRONT_XHTTP_PADDING_BYTES}" \
        --arg stream_up_server_secs "${CLOUDFRONT_XHTTP_STREAM_UP_SERVER_SECS}" \
        --argjson inbound_sockopt "${inbound_sockopt}" \
        --argjson managed_outbounds "${managed_outbounds}" \
        --argjson managed_routing "${managed_routing}" '
        {
          log: {loglevel: "warning"},
          stats: {},
          api: {tag: $api_tag, services: ["StatsService"]},
          policy: {system: {statsInboundUplink: true, statsInboundDownlink: true}},
          inbounds: ($direct_inbounds + [
            {
              tag: $api_tag,
              listen: "127.0.0.1",
              port: $api_port,
              protocol: "dokodemo-door",
              settings: {address: "127.0.0.1"}
            },
            {
              tag: "vless-xhttp-in",
              listen: "127.0.0.1",
              port: $xhttp_port,
              protocol: "vless",
              settings: {clients: $clients, decryption: "none"},
              streamSettings: {
                network: "xhttp",
                xhttpSettings: {
                  path: $xhttp_path,
                  host: $xhttp_host,
                  mode: "stream-up",
                  scMaxEachPostBytes: 1000000,
                  scMinPostsIntervalMs: 30,
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
    local blocked=${1:-}
    if [[ -z "${blocked}" ]]; then
        blocked=0
        cdn_traffic_blocked_now && blocked=1
    fi
    render_xray_config "${blocked}"
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
    desired_ports="$(printf '%s\n' "${SSH_PORTS}" 80 443 $(cdn_direct_ufw_ports) | tr '\n' ' ')"
    apply_ssh_ufw_policy "${desired_ports}" "${SSH_PORTS}"
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
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
    aggregation_node_names >/dev/null 2>&1 || true
    extra=$(aggregation_node_names)
    jq -nr --argjson direct "$(cdn_direct_node_names)" --arg cloud "${CF_NODE_PREFIX}" \
        --argjson extra "${extra}" '
        ($direct + [$cloud] + $extra)[] | "        - \(.|@json)"'
}

# 新链路没有额外 CDN 分组；模板占位必须成功输出空文件。
build_mihomo_proxy_groups() {
    printf ''
}

cloudfront_template_snapshot_file() {
    printf '%s/mihomo-template.yaml' "${STATE_DIR}"
}

# 共享订阅事务（snapshot/rollback_subscription_update）按该路径把模板快照与 state、
# 六种产物一起备份与回滚；模板不属于 mode 1 的事务。
XHTTP_TEMPLATE_SNAPSHOT_PATH=$(cloudfront_template_snapshot_file)

cloudfront_prepare_subscription_template() {
    local snapshot
    snapshot=$(cloudfront_template_snapshot_file)
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

cloudfront_persist_subscription_template() {
    local snapshot temp
    [[ -n "${MIHOMO_TEMPLATE_FILE:-}" && -s "${MIHOMO_TEMPLATE_FILE}" ]] \
        || die "缺少可持久化的 Mihomo 模板"
    install -d -m 0700 "${STATE_DIR}"
    snapshot=$(cloudfront_template_snapshot_file)
    if [[ "${MIHOMO_TEMPLATE_FILE}" != "${snapshot}" ]]; then
        # 与 state/订阅一致：临时文件 0600 + 同目录原子 rename，不留半截快照。
        temp=$(mktemp "${snapshot}.XXXXXX") || die "创建 Mihomo 模板快照暂存文件失败"
        cleanup_files+=("${temp}")
        install -m 0600 "${MIHOMO_TEMPLATE_FILE}" "${temp}" \
            || die "复制 Mihomo 模板快照失败"
        mv -f -- "${temp}" "${snapshot}" || die "原子替换 Mihomo 模板快照失败"
    fi
    MIHOMO_TEMPLATE_FILE=${snapshot}
    MIHOMO_TEMPLATE_SNAPSHOT=1
}

cloudfront_write_subscriptions() {
    cloudfront_prepare_subscription_template
    write_subscriptions
    cloudfront_persist_subscription_template
}

# 把当前 state 渲染到指定目录：模板解析与发布路径完全一致（显式源 > 快照 > 内置默认），
# 供订阅就绪验收与真实发布比对使用。
cloudfront_render_subscription_files() {
    cloudfront_prepare_subscription_template
    render_subscription_files "$1"
}

refresh_runtime_subscription() {
    cloudfront_write_subscriptions
    save_state
}

# --- Local acceptance ---------------------------------------------------------

validate_subscription_runtime() {
    local token base64_response base64_decoded mihomo_response status
    xhttp_local_probe_context
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS}")
    base64_response=$(cdn_local_curl "/subscribe?token=${token}") \
        || die "通用订阅本机验收失败"
    [[ -n "${base64_response}" ]] || die "通用订阅响应为空"
    base64_decoded=$(printf '%s' "${base64_response}" | openssl base64 -d -A 2>/dev/null) \
        || die "通用订阅响应不是有效的 Base64"
    grep -Fq 'type=xhttp' <<<"${base64_decoded}" || die "通用订阅响应缺少 CloudFront 节点"
    mihomo_response=$(cdn_local_curl "/subscribe?flag=clash&token=${token}") \
        || die "Mihomo 订阅本机验收失败"
    grep -Fq 'network: xhttp' <<<"${mihomo_response}" || die "Mihomo 订阅响应无效"
    grep -Fq "${CF_NODE_DOMAIN}" <<<"${mihomo_response}" \
        || die "Mihomo 订阅响应缺少 CloudFront 域名"
    validate_subscription_token_rejection \
        "${CF_ORIGIN_DOMAIN}:443:127.0.0.1" "https://${CF_ORIGIN_DOMAIN}/subscribe" \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" --header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}"
    status=$(curl -sS --noproxy '*' --connect-timeout 5 --max-time 20 \
        "${XHTTP_LOCAL_TLS_CURL_ARGS[@]}" -o /dev/null -w '%{http_code}' \
        --header "@${XHTTP_LOCAL_PROBE_HEADER_FILE}" \
        --resolve "${CF_ORIGIN_DOMAIN}:443:127.0.0.1" \
        "https://${CF_ORIGIN_DOMAIN}/_easy_all_subscription/base64" || true)
    [[ "${status}" == "404" ]] \
        || die "内部订阅路径必须对外返回 404（HTTP ${status}）"
}

# 本机节点必须来自当前身份且固定在列表头部：模式 2 只有 CloudFront，模式 3 先 Reality 再 CloudFront；
# 聚合节点可以跟在后面，但不得冒充本机节点。
cdn_subscription_local_nodes_ready() {
    local decoded link cloud_link reality_link="" expected=1 cloud_count=0 reality_count=0
    local -a links=()
    decoded=$(openssl base64 -d -A <"$1/base64.txt" 2>/dev/null) || return 1
    while IFS= read -r link; do
        if [[ "${link}" == vless://* ]]; then
            links+=("${link}")
        fi
    done <<<"${decoded}"
    if cdn_reality_enabled; then
        expected=2
        reality_link="vless://${VLESS_UUID}@${DIRECT_DOMAIN}:"
    fi
    ((${#links[@]} >= expected)) || return 1
    cloud_link=${links[expected - 1]}
    [[ "${cloud_link}" == "vless://${VLESS_UUID}@${CF_NODE_DOMAIN}:443?"* ]] || return 1
    [[ "${cloud_link}" == *"type=xhttp"* && "${cloud_link}" == *"security=tls"* ]] || return 1
    [[ "${cloud_link}" == *"path=$(uri_encode "$(xhttp_client_path)")"* ]] || return 1
    for link in "${links[@]}"; do
        if [[ "${link}" == "vless://${VLESS_UUID}@${CF_NODE_DOMAIN}:443?"* ]]; then
            cloud_count=$((cloud_count + 1))
        fi
        if [[ -n "${reality_link}" && "${link}" == "${reality_link}"* ]]; then
            reality_count=$((reality_count + 1))
        fi
    done
    ((cloud_count == 1)) || return 1
    [[ "${expected}" == "2" ]] || return 0
    ((reality_count == 1)) || return 1
    [[ "${links[0]}" == "${reality_link}"* && "${links[0]}" == *"security=reality"* ]]
}

# 六产物就绪：当前 state/模板重新渲染的结果必须与已发布文件逐字节一致，
# 缺失任一文件或内容来自上一代都算未就绪。
cdn_subscription_artifacts_ready() {
    local render_dir name published ready=1
    render_dir=$(mktemp -d "${RUNTIME_TMP}/subscription-ready.XXXXXX") || return 1
    cleanup_files+=("${render_dir}")
    # 渲染用 die 报告失败：放进子 shell 只取退出码，模板/节点问题不得终止整条命令。
    if ! ( cloudfront_render_subscription_files "${render_dir}" ) >/dev/null 2>&1; then
        ready=0
    fi
    if ((ready == 1)); then
        for name in base64.txt mihomo.yaml mihomo-ios.yaml \
            base64-all.txt mihomo-all.yaml mihomo-ios-all.yaml; do
            published="${SUBSCRIPTION_DIR}/${name}"
            if [[ ! -f "${published}" ]] || ! cmp -s "${render_dir}/${name}" "${published}"; then
                ready=0
                break
            fi
        done
    fi
    if ((ready == 1)); then
        cdn_subscription_local_nodes_ready "${render_dir}" || ready=0
    fi
    rm -rf -- "${render_dir}"
    ((ready == 1))
}

cdn_subscription_ready() {
    cdn_config_ready || return 1
    cdn_subscription_artifacts_ready || return 1
    # 就绪判定必须可降级：validate_subscription_runtime 失败用 die 终止进程，
    # 裸调用会把"订阅不可用"变成整个命令静默退出，所以放进子 shell 只取其退出码。
    ( validate_subscription_runtime ) >/dev/null 2>&1
}

cdn_validate_restricted_runtime() {
    # 受限恢复只做本机验收：validate_protocol_runtime 已覆盖 443/health 与模式 3 的 8443 监听；
    # 不调用含远端 target 探测的 cdn_validate_direct_runtime，避免旧 target 不可达挡住 reality-target 修复。
    validate_protocol_runtime || return 1
    xhttp_local_probe_context
    cdn_traffic_probe_stats || die "受限运行时无法读取真实 Xray StatsService 计数"
    cdn_validate_xhttp_blocked
}

# --- Traffic runtime rebuild --------------------------------------------------

cdn_traffic_recover_restricted_runtime() {
    local usage
    usage=$(cdn_traffic_read_usage) || {
        warn "CDN 保护统计缺失或损坏；无法执行受限恢复"
        return 1
    }
    jq -e '.blocked == true and .enforced == false' <<<"${usage}" >/dev/null || {
        warn "当前状态不是待落实的 CDN 阻断；跳过受限恢复"
        return 1
    }
    warn "先应用 XHTTP 503 与受限 Nginx，再启动受限 Xray"
    if ! (
        write_nginx_config 1 || exit 1
        render_xray_config 1 || exit 1
        systemctl restart "${XRAY_SERVICE}" || exit 1
        cdn_validate_restricted_runtime || exit 1
    ); then
        warn "受限安全恢复未通过必需验收；保持 XHTTP deny 并持久化保护性停机标记"
        cdn_traffic_mark_protection_offline \
            || warn "无法持久化保护性停机标记；只能人工修复 ${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        systemctl stop "${XRAY_SERVICE}" >/dev/null 2>&1 \
            || warn "停止 Xray 失败：旧 CDN 连接可能仍存活"
        return 1
    fi
    cdn_traffic_mark_restricted_recovered \
        || { warn "无法落盘受限恢复结果（enforced=true, protection_offline=false）"; return 1; }
    if ! cdn_subscription_ready; then
        warn "运行时已受限恢复，但订阅未就绪/不可用；禁止解封，请执行 sudo easy_all edit-sub"
    fi
    return 0
}

rebuild_traffic_runtime() {
    local blocked=0 backup usage
    usage=$(cdn_traffic_read_usage) || { warn "CDN 保护统计缺失或损坏；拒绝重建运行时"; return 1; }
    jq -e '.blocked == true' <<<"${usage}" >/dev/null && blocked=1
    backup=$(make_temp_dir)
    [[ ! -f "${XRAY_CONFIG}" ]] || install -m 0600 "${XRAY_CONFIG}" "${backup}/xray.json"
    [[ ! -f "${NGINX_CONFIG}" ]] || install -m 0600 "${NGINX_CONFIG}" "${backup}/nginx.conf"
    if (
        render_xray_config "${blocked}" || exit 1
        write_nginx_config "${blocked}" || exit 1
        systemctl restart "${XRAY_SERVICE}" || exit 1
        if [[ "${blocked}" == "1" ]]; then
            cdn_validate_restricted_runtime || exit 1
        else
            validate_protocol_runtime || exit 1
            cdn_validate_direct_runtime || exit 1
        fi
    ); then
        return 0
    fi
    if [[ "${blocked}" == "1" ]]; then
        # 阻断失败不能恢复开放配置后标成功：保留已生效的 Nginx 503，先持久化停机
        # 意图再停止 Xray，终止旧 CDN 会话。
        warn "应用 CDN 阻断失败；保留 XHTTP 503，持久化保护性停机标记后停止 Xray"
        cdn_traffic_mark_protection_offline \
            || warn "无法持久化保护性停机标记；只能人工修复 ${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        systemctl stop "${XRAY_SERVICE}" >/dev/null 2>&1 \
            || warn "停止 Xray 失败：旧 CDN 连接可能仍存活"
        return 1
    fi
    warn "解封失败；恢复原受限配置并保留解封 pending"
    if [[ -f "${backup}/xray.json" ]]; then
        install -m 0600 "${backup}/xray.json" "${XRAY_CONFIG}"
    fi
    if [[ -f "${backup}/nginx.conf" ]]; then
        install -m 0600 "${backup}/nginx.conf" "${NGINX_CONFIG}"
    fi
    if nginx -t >/dev/null 2>&1 && systemctl reload nginx >/dev/null 2>&1 \
        && systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 \
        && validate_protocol_runtime; then
        return 1
    fi
    warn "连原受限配置也无法恢复；持久化保护性停机标记并停止 Xray"
    cdn_traffic_mark_protection_offline \
        || warn "无法持久化保护性停机标记；只能人工修复 ${CDN_TRAFFIC_GUARD_USAGE_FILE}"
    systemctl stop "${XRAY_SERVICE}" >/dev/null 2>&1 \
        || warn "停止 Xray 失败：旧 CDN 连接可能仍存活"
    return 1
}

# --- Command admission --------------------------------------------------------

cdn_require_traffic_usage() {
    cdn_traffic_protection_enabled || die "CloudFront 流量保护未启用；状态不完整"
    cdn_traffic_read_usage >/dev/null \
        || die "CDN 全局费用保护统计文件缺失或损坏：${CDN_TRAFFIC_GUARD_USAGE_FILE}；保护异常，请修复后重试"
}

cdn_traffic_admission() {
    cdn_require_traffic_usage
    if cdn_traffic_needs_restricted_recovery; then
        cdn_traffic_recover_restricted_runtime \
            || die "CDN 保护待落实；受限安全恢复失败，已停止后续操作"
    fi
}

# --- Scheduled maintenance hooks ---------------------------------------------

scheduled_reboot_profile_pre_command() {
    printf '%s %s' "${COMMAND_PATH}" "$(cdn_traffic_sync_command)"
}

cdn_traffic_locked_check_jq() {
    printf '%s' 'type == "object" and (.period|type == "string" and test("^[0-9]{4}-(0[1-9]|1[0-2])$")) and (.runtime_id|type == "string") and (.used_bytes|type == "number" and floor == . and . >= 0) and (.last_uplink|type == "number" and floor == . and . >= 0) and (.last_downlink|type == "number" and floor == . and . >= 0) and (.blocked|type == "boolean") and (.enforced|type == "boolean") and (.protection_offline|type == "boolean") and (.protection_offline == false) and (.blocked == .enforced)'
}

scheduled_reboot_profile_locked_check_command() {
    printf 'jq -e %q %q >/dev/null' \
        "$(cdn_traffic_locked_check_jq)" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
}

# --- Commands -----------------------------------------------------------------

show_node() {
    local extra
    collect_installed_state
    [[ "${CDN_SUBSCRIPTION_CORRUPT}" == "0" ]] \
        || warn "订阅配置损坏；节点列表可能不完整，请执行 sudo easy_all edit-sub"
    printf '\n协议: VLESS XHTTP stream-up/H2 over AWS CloudFront\n'
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
    local cert_enddate="" usage_offline
    require_root
    collect_installed_state
    printf '模式: %s\n' "${CDN_MODE_LABEL}"
    printf '协议: CloudFront XHTTP（%s）\n' "${CDN_ENTRY_SUMMARY}"
    show_tcp_acceleration_status
    printf '源站域名: %s\n' "${CF_ORIGIN_DOMAIN}"
    printf 'CloudFront 节点域名: %s\n' "${CF_NODE_DOMAIN}"
    printf '订阅域名: %s\n' "${SUBSCRIPTION_DOMAIN}"
    printf 'CloudFront 分发: %s（%s）\n' \
        "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${AWS_CLOUDFRONT_DOMAIN}"
    printf 'ACM 证书: %s（%s）\n' "${AWS_ACM_CERTIFICATE_ARN}" "${AWS_CONTROL_REGION}"
    if [[ -s "${CERT_FILE}" ]]; then
        cert_enddate=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        if cdn_origin_certificate_covers "${CERT_FILE}" \
            && cdn_origin_key_matches_certificate; then
            printf '源站证书到期: %s（已覆盖 %s）\n' "${cert_enddate:-未知}" "${CF_ORIGIN_DOMAIN}"
        else
            printf '源站证书异常：未覆盖 %s 或与私钥不配对；请执行 sudo easy_all renew-cert\n' "${CF_ORIGIN_DOMAIN}"
        fi
    else
        printf '源站证书: 缺失；请执行 sudo easy_all renew-cert\n'
    fi
    printf 'Xray: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'Nginx: '
    systemctl is-active --quiet nginx 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf 'CDN 流量保护定时器: '
    systemctl is-active --quiet "${CDN_TRAFFIC_GUARD_TIMER}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    show_cdn_traffic_protection_status
    if [[ "${CDN_SUBSCRIPTION_CORRUPT}" != "0" ]]; then
        printf '订阅: 配置损坏，当前不可用；请执行 sudo easy_all edit-sub\n'
    fi
    usage_offline=$(cdn_traffic_read_usage 2>/dev/null | jq -r '.protection_offline // false' 2>/dev/null || true)
    if [[ "${usage_offline}" == "true" ]]; then
        printf '保护性停机: 是（运行时受限或已停止，等待 cdn-traffic-sync 收敛）\n'
    fi
}

# 成功提交本机运行时：注册命令 + 恢复云费用保护定时器。任一步失败即非零，
# 调用方不得报告成功（设计 §8.1 的安装/apply 成功条件）。
cdn_commit_local_runtime() {
    register_easy_all_command
    install_cdn_traffic_protection_timer
}

apply_easy_all() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_traffic_admission
    cdn_require_valid_subscription
    snapshot_subscription_update
    cdn_traffic_protection_checkpoint \
        || die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止应用，请先运行 sudo easy_all cdn-traffic-sync"
    configure_tcp_acceleration
    configure_ipv4_only
    xhttp_configure_ufw
    write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
    cloudfront_write_subscriptions
    validate_subscription_runtime
    save_state
    cdn_commit_local_runtime
    commit_subscription_update
    success "本机配置与订阅已应用；未修改 DNS 与云端资源"
}

# 云端同步阶段：任何 AWS 调用前显式收集并校验凭据（已有环境变量则复用）。
# 成功离开该阶段由 apply_cloud_resources 显式清除；失败/中断由 runtime-core 的
# cleanup 钩子（clear_profile_credentials）清除——不用 if/|| 包裹，否则会关闭
# 整个阶段的 errexit，把中途失败当成继续执行。
apply_cloud_phase() {
    cloudflare_collect_api_token
    collect_aws_credentials
    persist_cloudflare_token
    cdn_prepare_origin_dns
    cdn_wait_for_origin_dns
    cdn_issue_origin_certificate
    find_or_request_acm_certificate
    configure_cloudfront_distribution
    ensure_viewer_cnames
    wait_for_cloudfront_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" \
        || die "等待 CloudFront 分发部署超时；云端资源与 DNS 已保留，可稍后重试 apply-cloud"
}

apply_cloud_resources() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_traffic_admission
    cdn_require_valid_subscription
    snapshot_subscription_update
    cdn_traffic_protection_checkpoint \
        || die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止云端同步，请先运行 sudo easy_all cdn-traffic-sync"
    configure_tcp_acceleration
    configure_ipv4_only
    xhttp_configure_ufw
    apply_cloud_phase
    clear_aws_credentials
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    write_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
    cloudfront_write_subscriptions
    validate_subscription_runtime
    # 本机 apply 子流程完成后才能证明公网链路；失败时云端资源保留，可重试 apply-cloud。
    cdn_validate_public_runtime
    save_state
    cdn_commit_local_runtime
    commit_subscription_update
    success "本机配置、订阅与云端资源已同步"
}

# 保护性停机的安全边界：Nginx deny 与停旧 Xray 是两个独立的必须动作，
# 任一步失败都不能跳过另一步（旧 CDN 长连接会继续存活）。
cdn_establish_denied_boundary() {
    local failed=0
    # write_nginx_config 用 die 报告渲染/校验/重载失败：放进子 shell 才能捕获并继续停旧 Xray。
    if ! ( write_nginx_config 1 ); then
        warn "无法确立 XHTTP 503 的 Nginx deny；旧 CDN 连接可能仍存活，继续停止旧 Xray"
        failed=1
    fi
    if systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null; then
        systemctl stop "${XRAY_SERVICE}" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null; then
            warn "停止旧 Xray 失败：旧 CDN 连接可能仍存活"
            failed=1
        fi
    fi
    return "${failed}"
}

update_subscription() {
    local raw_config="" caller_config=${SUBSCRIPTION_CONFIG:-} restricted=0
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_traffic_usage
    if cdn_traffic_needs_restricted_recovery; then
        restricted=1
        warn "检测到 CDN 保护待落实；仅在保持 XHTTP 503 与停止的 Xray 前提下修复订阅"
        cdn_establish_denied_boundary \
            || die "无法确立 XHTTP 503 的安全边界；已停止订阅修复"
    fi
    if [[ -t 0 ]]; then
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "$(prompt_value 'Mihomo 下载文件名（不含 .yaml）' "${SUB_DOWNLOAD_NAME}")")
        raw_config=$(choose_subscription_config "${SUBSCRIPTION_CONFIG:-}")
    else
        raw_config=${caller_config:-${SUBSCRIPTION_CONFIG:-}}
    fi
    cdn_apply_subscription_config "${raw_config}" \
        || die "订阅配置无效：需包含 allowedTokens 与 nodes；节点仅支持 vless reality/tcp、vless tls/xhttp 与 mieru"
    # 修复闭环：新配置已强校验并应用，旧订阅的损坏标记必须在此清零，
    # 否则本进程及新进程的 write_nginx_config/cdn_subscription_ready 会一直判订阅不可用。
    CDN_SUBSCRIPTION_CORRUPT=0
    if [[ "${restricted}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
    fi
    snapshot_subscription_update
    cloudfront_write_subscriptions
    if [[ "${restricted}" == "1" ]]; then
        # 保持受阻：Nginx 仍为 XHTTP 503；订阅配置有效时仅恢复 /subscribe。
        write_nginx_config 1
    else
        write_nginx_config
    fi
    validate_subscription_runtime
    save_state
    if [[ "${restricted}" == "1" ]]; then
        commit_subscription_update
        show_cdn_traffic_protection_status
        warn "订阅修复完成，保护仍 pending；Xray 保持停机，请执行 sudo easy_all cdn-traffic-sync 恢复"
        return 0
    fi
    commit_subscription_update
    show_subscription
    success "订阅已刷新"
}

renew_certificate() {
    local restricted=0 usage
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_traffic_usage
    usage=$(cdn_traffic_read_usage)
    jq -e '.blocked == true and .enforced == false' <<<"${usage}" >/dev/null && restricted=1
    install_certbot_deploy_hook
    if [[ "${restricted}" == "1" ]]; then
        warn "CDN 保护待落实：先只修复证书并保持 XHTTP 503，再执行受限恢复"
        if cdn_origin_lineage_is_newer; then
            cdn_install_origin_lineage || die "已有较新源站证书但部署失败"
        else
            cdn_run_certbot 1 1
            cdn_install_origin_lineage || die "Certbot 未生成有效源站证书"
        fi
        cdn_verify_origin_certificate
        write_nginx_config 1
        nginx -t >/dev/null || die "证书修复后 Nginx 配置校验失败"
        systemctl reload nginx >/dev/null 2>&1 || die "证书修复后 Nginx 重载失败"
        cdn_traffic_recover_restricted_runtime \
            || die "证书已部署，但受限运行时恢复失败；保留保护待落实状态"
        cdn_subscription_ready \
            || die "证书已部署、受限运行时已恢复，但订阅未就绪；请执行 sudo easy_all edit-sub"
        save_state
        release_runtime_write_lock
        success "源站证书已更新，受限运行时已恢复"
        return 0
    fi
    if cdn_origin_lineage_is_newer; then
        cdn_install_origin_lineage || die "部署已签发的新源站证书失败"
    else
        cdn_run_certbot 1 1
        cdn_install_origin_lineage || die "Certbot 未生成有效源站证书"
    fi
    cdn_verify_origin_certificate
    write_nginx_config
    nginx -t >/dev/null || die "证书更新后 Nginx 配置校验失败"
    systemctl reload nginx >/dev/null 2>&1 || die "证书更新后 Nginx 重载失败"
    validate_protocol_runtime
    validate_subscription_runtime
    save_state
    release_runtime_write_lock
    success "源站证书已更新；ACM 自动续期依赖保留的 validation DNS CNAME"
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
    printf '云端资源清单（默认保留，需要时手动处置）：\n' >&2
    printf '  CloudFront 分发: %s（%s）\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-未知}" \
        "${AWS_CLOUDFRONT_DOMAIN:-未知}" >&2
    printf '  ACM 证书 ARN: %s\n' "${AWS_ACM_CERTIFICATE_ARN:-未知}" >&2
    printf '  源站 A 记录: %s -> %s\n' "${CF_ORIGIN_DOMAIN:-未知}" "${VPS_PUBLIC_IPV4:-未知}" >&2
    printf '  节点/订阅 CNAME: %s,%s -> %s\n' "${CF_NODE_DOMAIN:-未知}" \
        "${SUBSCRIPTION_DOMAIN:-未知}" "${AWS_CLOUDFRONT_DOMAIN:-未知}" >&2
    printf '  ACM validation CNAME 默认保留（可由控制台核实后手工删除）\n' >&2
}

cdn_purge_cloudflare_dns() {
    local spec type host expected rest domain records count id comment current failed=0
    local seen="|"
    local -a pairs=()
    cdn_ensure_zone_id || return 1
    pairs+=("A|${CF_ORIGIN_DOMAIN}|${VPS_PUBLIC_IPV4}")
    if [[ -n "${AWS_CLOUDFRONT_DOMAIN:-}" ]]; then
        pairs+=("CNAME|${CF_NODE_DOMAIN}|${AWS_CLOUDFRONT_DOMAIN}")
        pairs+=("CNAME|${SUBSCRIPTION_DOMAIN}|${AWS_CLOUDFRONT_DOMAIN}")
    else
        warn "缺少 CloudFront 分发域名；跳过节点/订阅 CNAME 清理"
    fi
    # 模式 3 直连 A 与源站 A 可能复用同一域名，同一 type+host 只处理一次。
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        pairs+=("A|${domain}|${VPS_PUBLIC_IPV4}")
    done < <(cdn_direct_domains)
    for spec in "${pairs[@]}"; do
        type=${spec%%|*}
        rest=${spec#*|}
        host=${rest%%|*}
        expected=${rest#*|}
        [[ "${seen}" != *"|${type}|${host}|"* ]] || continue
        seen="${seen}${type}|${host}|"
        records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" "${type}" "${host}") \
            || { warn "查询 Cloudflare 记录失败：${host}"; failed=1; continue; }
        count=$(jq 'length' <<<"${records}")
        if ((count == 0)); then
            continue
        fi
        if ((count > 1)); then
            warn "Cloudflare 存在 ${count} 条同名 ${type} 记录，无法判断归属：${host}"
            failed=1
            continue
        fi
        id=$(jq -r '.[0].id' <<<"${records}")
        comment=$(jq -r '.[0].comment // empty' <<<"${records}")
        current=$(jq -r '.[0].content // empty' <<<"${records}")
        # 类型、注释、目标三者同时匹配才删；任一不符只告警保留。
        if [[ "${comment}" != "${CDN_RECORD_COMMENT}" ]]; then
            warn "Cloudflare ${host} 的 ${type} 记录不是本链路创建的（注释：${comment:-空}）；保留"
            continue
        fi
        if [[ "${current}" != "${expected}" ]]; then
            warn "Cloudflare ${host} 的 ${type} 记录目标已变化（${current:-空}）；保留"
            continue
        fi
        (cloudflare_api_request DELETE "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null) \
            || { warn "删除 Cloudflare 记录失败：${host}"; failed=1; }
    done
    return "${failed}"
}

cdn_purge_aws_resources() {
    local config etag acm tags failed=0
    local fetched="${RUNTIME_TMP}/cloudfront-purge-config.json"
    local owned="${RUNTIME_TMP}/cloudfront-purge-owned.json"
    [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}" || -n "${AWS_ACM_CERTIFICATE_ARN:-}" ]] || return 0
    # 环境已注入的凭据同样逐项校验；缺凭据只记失败，不阻断本机卸载。
    collect_aws_credentials \
        || { warn "缺少 AWS 凭据，无法清理云端资源；本机卸载继续"; return 1; }
    if [[ -n "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}" ]]; then
        # 严格门控：分发禁用+删除确认成功后才处理 ACM 与节点/订阅 DNS。
        cloudfront_read_owned_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${fetched}" || {
            warn "分发未通过归属校验；保留 ${AWS_CLOUDFRONT_DISTRIBUTION_ID}，跳过 ACM 与 DNS 清理"
            rm -f -- "${fetched}" "${owned}"
            return 1
        }
        etag=$(jq -r '.ETag // empty' "${fetched}")
        if [[ -z "${etag}" ]]; then
            warn "缺少分发 ETag；保留 ${AWS_CLOUDFRONT_DISTRIBUTION_ID}，跳过 ACM 与 DNS 清理"
            rm -f -- "${fetched}" "${owned}"
            return 1
        fi
        config=$(jq -c '.DistributionConfig | .Enabled=false' "${fetched}")
        if ! aws_cli cloudfront update-distribution --id "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" \
            --if-match "${etag}" --distribution-config "${config}" --output json >/dev/null 2>&1; then
            warn "禁用 CloudFront 分发失败；保留 ${AWS_CLOUDFRONT_DISTRIBUTION_ID}，跳过 ACM 与 DNS 清理"
            rm -f -- "${fetched}" "${owned}"
            return 1
        fi
        if ! wait_for_cloudfront_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}"; then
            warn "等待 CloudFront 分发禁用生效超时；保留 ${AWS_CLOUDFRONT_DISTRIBUTION_ID}，跳过 ACM 与 DNS 清理"
            rm -f -- "${fetched}" "${owned}"
            return 1
        fi
        # 删除前重新校验归属并取最新 ETag。
        cloudfront_read_owned_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${owned}" || {
            warn "分发删除前归属校验失败；保留 ${AWS_CLOUDFRONT_DISTRIBUTION_ID}，跳过 ACM 与 DNS 清理"
            rm -f -- "${fetched}" "${owned}"
            return 1
        }
        etag=$(jq -r '.ETag // empty' "${owned}")
        if [[ -z "${etag}" ]] \
            || ! aws_cli cloudfront delete-distribution --id "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" \
                --if-match "${etag}" >/dev/null 2>&1; then
            warn "删除 CloudFront 分发失败；保留 ${AWS_CLOUDFRONT_DISTRIBUTION_ID}，跳过 ACM 与 DNS 清理"
            rm -f -- "${fetched}" "${owned}"
            return 1
        fi
        rm -f -- "${fetched}" "${owned}"
        success "CloudFront 分发已删除：${AWS_CLOUDFRONT_DISTRIBUTION_ID}"
    fi
    if [[ -n "${AWS_ACM_CERTIFICATE_ARN:-}" ]]; then
        acm=$(aws_cli acm describe-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" --output json 2>/dev/null || true)
        tags=$(aws_cli acm list-tags-for-certificate --region "${AWS_CONTROL_REGION}" \
            --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" --output json 2>/dev/null || true)
        if [[ -z "${acm}" ]]; then
            warn "读取 ACM 证书失败；保留 ${AWS_ACM_CERTIFICATE_ARN}"
            failed=1
        elif ! acm_certificate_owned_by_easy_all "${acm}" "${tags}"; then
            warn "ACM 证书未通过归属校验（管理标记/SAN/InUseBy/us-east-1 任一不符）；保留 ${AWS_ACM_CERTIFICATE_ARN}"
            failed=1
        else
            aws_cli acm delete-certificate --region "${AWS_CONTROL_REGION}" \
                --certificate-arn "${AWS_ACM_CERTIFICATE_ARN}" >/dev/null 2>&1 \
                || { warn "删除 ACM 证书失败：${AWS_ACM_CERTIFICATE_ARN}"; failed=1; }
        fi
    fi
    # 分发已确认删除（或本就没有分发 ID）：ACM 失败不阻止 CNAME 清理。
    (cdn_purge_cloudflare_dns) || { warn "Cloudflare DNS 清理未完成"; failed=1; }
    return "${failed}"
}

cdn_cleanup_legacy_globalping_artifacts() {
    local unit
    for unit in easy_all-globalping-refresh.timer easy_all-globalping-refresh.service; do
        systemctl disable --now "${unit}" >/dev/null 2>&1 || true
        rm -f -- "/etc/systemd/system/${unit}"
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -f -- "${STATE_DIR}/globalping.token" "${STATE_DIR}/cdn-ips.json" \
        "${STATE_DIR}/cloudflare-cdn-ips.json"
}

cdn_local_uninstall_common() {
    stop_maintenance_services || true
    cdn_cleanup_legacy_globalping_artifacts
    remove_cdn_traffic_protection_timer || true
    stop_services
    remove_certbot_deploy_hook || true
    cdn_remove_origin_lineage || true
    restore_platform_security_state || {
        warn "SSH 配置恢复失败；请通过服务商 Console 检查"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_preinstall_nginx_default_site || warn "恢复安装前 Nginx 默认站点失败"
    remove_daily_reboot_schedule
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
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
            read_bilingual '删除本机内容以及 easy_all 创建的 CloudFront/ACM/DNS 资源？[y/N]:' answer
        else
            read_bilingual '删除 easy_all 本机服务、状态和证书（保留 AWS/Cloudflare 云端资源）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services || true
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    cdn_print_cloud_inventory
    if [[ "${mode}" == "--purge-cloud" ]]; then
        # 云端清理在可捕获的子 shell 中执行：缺凭据/任何 die 只告警，不终止本机卸载。
        if (cdn_purge_aws_resources); then
            :
        else
            warn "云端资源清理未完成；本机卸载继续，请按上方清单手动处置"
        fi
    else
        warn "AWS/Cloudflare 云端资源已保留；本机状态删除后无法再用 easy_all 清理"
    fi
    cdn_local_uninstall_common || return 1
    if [[ "${mode}" == "--purge-cloud" ]]; then
        success "easy_all 本机内容已卸载；云端清理结果见上方输出"
    else
        success "easy_all 本机内容已卸载；云端资源已保留"
    fi
}

cdn_legacy_state_value() {
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

cdn_legacy_dns_hosts() {
    local protocol=$1 host
    local -a hosts=()
    if [[ "${protocol}" == "combined" ]]; then
        hosts+=("$(cdn_legacy_state_value DIRECT_DOMAIN || true)")
    fi
    hosts+=("$(cdn_legacy_state_value CF_NODE_DOMAIN || true)")
    hosts+=("$(cdn_legacy_state_value SUBSCRIPTION_DOMAIN || true)")
    for host in "${hosts[@]}"; do
        [[ -n "${host}" ]] || continue
        printf '%s\n' "${host}"
    done | awk '!seen[$0]++'
}

# 旧链路按当时的归属注释删 DNS：只删同名单条且注释完全一致的 A 记录。
cdn_legacy_purge_dns() {
    local protocol=$1 zone=$2 comment host type=A records count id failed=0
    case "${protocol}" in
    cdn) comment="easy_all cdn" ;;
    combined) comment="easy_all combined" ;;
    *) return 1 ;;
    esac
    while IFS= read -r host; do
        [[ -n "${host}" ]] || continue
        records=$(cloudflare_record_list "${zone}" "${type}" "${host}") \
            || { warn "查询 Cloudflare 记录失败：${host}"; failed=1; continue; }
        count=$(jq 'length' <<<"${records}")
        if ((count == 0)); then continue; fi
        if ((count != 1)); then
            warn "Cloudflare 存在 ${count} 条同名 A 记录，无法判断归属：${host}"
            failed=1
            continue
        fi
        id=$(jq -r '.[0].id' <<<"${records}")
        [[ "$(jq -r '.[0].comment // empty' <<<"${records}")" == "${comment}" ]] || continue
        (cloudflare_api_request DELETE "/zones/${zone}/dns_records/${id}" >/dev/null) \
            || { warn "删除 Cloudflare 记录失败：${host}"; failed=1; }
    done < <(cdn_legacy_dns_hosts "${protocol}")
    return "${failed}"
}

# 旧链路用 easy_all-cf-origin 注释放行 Cloudflare 回源段；新核心不声明该常量。
cdn_legacy_reclaim_origin_firewall_rules() {
    command -v ufw >/dev/null 2>&1 || return 0
    delete_stale_ufw_rules "easy_all-cf-origin" \
        || { warn "删除旧 Cloudflare 回源 UFW 规则未完成；请人工核对 ufw status"; return 1; }
    ufw reload >/dev/null 2>&1 || true
}

# 旧 PROTOCOL=cdn / combined 状态：AWS/CloudFront 新核心不接管，只提供卸载。
# 默认仅清本机；显式 --purge-cloud 保持旧语义：按归属注释删 DNS、按 ID 吊销 Origin CA。
uninstall_legacy_cdn() {
    local mode=${1:-} answer protocol version zone cert_id
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    protocol=$(cdn_legacy_state_value PROTOCOL || true)
    version=$(cdn_legacy_state_value STATE_VERSION || true)
    case "${protocol}" in
    cdn | combined) ;;
    *) die "旧状态协议不是 cdn/combined，拒绝处理" ;;
    esac
    [[ "${version}" == "0" ]] || die "旧状态版本不匹配，已停止卸载"
    zone=$(cdn_legacy_state_value CLOUDFLARE_ZONE_ID || true)
    cert_id=$(cdn_legacy_state_value CLOUDFLARE_ORIGIN_CERT_ID || true)
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        read_bilingual '删除旧 Cloudflare CDN 安装的本机内容？云端记录默认保留。[y/N]:' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    printf '检测到旧 Cloudflare CDN 安装（PROTOCOL=%s）；AWS/CloudFront 新核心不接管该链路。\n' \
        "${protocol}" >&2
    if [[ "${mode}" == "--purge-cloud" ]]; then
        cdn_legacy_reclaim_origin_firewall_rules || true
        if [[ -n "${zone}" ]]; then
            (
                cloudflare_collect_api_token
                purge_failed=0
                (cdn_legacy_purge_dns "${protocol}" "${zone}") \
                    || { warn "旧 Cloudflare DNS 清理未完成"; purge_failed=1; }
                if [[ -n "${cert_id}" ]]; then
                    (cloudflare_api_request DELETE "/certificates/${cert_id}" >/dev/null) \
                        || { warn "吊销旧 Cloudflare Origin CA 证书失败：${cert_id}"; purge_failed=1; }
                fi
                cloudflare_clear_api_token
                exit "${purge_failed}"
            ) || warn "旧 Cloudflare 云端资源清理未完成；本机卸载继续（可在控制台手动清理）"
        else
            warn "旧状态缺少 Zone ID，仅清理本机"
        fi
    else
        warn "旧 Cloudflare DNS 与 Origin CA 证书已保留"
    fi
    # 旧链路不写 state.env 的新字段，回源放行需在删状态目录前按旧注释回收。
    cdn_legacy_reclaim_origin_firewall_rules || true
    cdn_local_uninstall_common || return 1
    success "旧 Cloudflare CDN 本机内容已卸载；请重新执行 sudo easy_all install 选择模式 2 或 3"
}

# 新协议但强制字段缺失/来自未完成实现：只清本机，云端一律保留。
uninstall_incomplete_cloudfront() {
    local mode=${1:-} answer protocol version
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    protocol=$(cdn_legacy_state_value PROTOCOL || true)
    version=$(cdn_legacy_state_value STATE_VERSION || true)
    case "${protocol}" in
    cloudfront | combined-cloudfront) ;;
    *) die "状态协议不是 CloudFront 新链路，拒绝处理" ;;
    esac
    [[ "${version}" == "0" ]] || die "状态版本不匹配，已停止卸载"
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        read_bilingual '状态不完整；仅清理本机内容并保留云端资源？[y/N]:' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    printf 'CloudFront 状态不完整或来自未完成实现；仅清理本机，云端资源保留：\n' >&2
    printf '  分发 ID: %s\n' "$(cdn_legacy_state_value AWS_CLOUDFRONT_DISTRIBUTION_ID || printf '未知')" >&2
    printf '  ACM ARN: %s\n' "$(cdn_legacy_state_value AWS_ACM_CERTIFICATE_ARN || printf '未知')" >&2
    cdn_local_uninstall_common || return 1
    success "本机内容已清理；云端资源已保留"
}

cleanup_partial_install() {
    cleanup_partial_install_local || return 1
    cdn_cleanup_legacy_globalping_artifacts || true
    # 旧 cdn/combined 链路曾用 easy_all-cf-origin 放行 Cloudflare 回源段；新链路没有这些规则。
    cdn_legacy_reclaim_origin_firewall_rules || true
    remove_cdn_traffic_protection_timer || true
    remove_certbot_deploy_hook || true
    # 只删本模式专属的 certbot lineage（CERTBOT_LINEAGE_NAME）；其他站点的证书/hook 不动。
    cdn_remove_origin_lineage || true
    remove_daily_reboot_schedule || true
    cleanup_partial_install_files \
        "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" \
        "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
}

rollback_fresh_install() {
    warn "${CDN_MODE_LABEL} 模式首次安装未完成，正在回滚本机服务、UFW 与 crontab 配置（保留前置初始化：SWAP、系统依赖与 TCP/Skyline 加速）"
    # 回滚未完成时必须保留安装进度标记与安装前快照：丢标记后既无法判断模式，
    # 也没法再用 cleanup-partial 重试。
    if ! cleanup_partial_install; then
        cdn_print_cloud_inventory
        warn "本机回滚未完成；已保留安装进度标记与安装前快照（${BACKUP_DIR}）。修正权限/挂载后重试 sudo easy_all cleanup-partial，云端资源仍按设计保留"
        return 1
    fi
    cdn_print_cloud_inventory
    warn "本次已创建的 AWS/Cloudflare 云端资源按设计保留；确认不再使用后可执行 uninstall --purge-cloud 或控制台清理"
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
    prepare_fresh_install "${CDN_INSTALL_PORTS[@]}" "${XRAY_XHTTP_LOOPBACK_PORT}" 10085
    install_progress_begin "${CDN_PROFILE_KEY}" cloudfront
    snapshot_fresh_install

    install_progress_stage packages
    install_packages
    install_certbot
    install_aws_cli
    install_certbot_deploy_hook
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
    cdn_prepare_origin_dns
    cdn_wait_for_origin_dns
    initialize_cdn_traffic_usage
    cdn_issue_origin_certificate
    write_xray_config
    install_xray_service
    # Xray 刚启动：现在就断言真实 StatsService 读数，不等 timer 才发现计量不可用。
    cdn_verify_traffic_api
    write_nginx_config
    validate_protocol_runtime
    cdn_validate_direct_runtime
    install_progress_stage cloud
    find_or_request_acm_certificate
    configure_cloudfront_distribution
    ensure_viewer_cnames
    wait_for_cloudfront_distribution "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" \
        || die "等待 CloudFront 分发部署超时；云端资源已保留，可修复后执行 apply-cloud"
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    install_progress_stage subscription
    cloudfront_write_subscriptions
    validate_subscription_runtime
    cdn_validate_public_runtime
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
