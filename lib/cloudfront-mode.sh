#!/usr/bin/env bash

# Shared AWS CloudFront core for mode 2 (CloudFront only) and mode 4
# (AnyTLS + CloudFront).
#
# Profile contract provided before this file is sourced:
#   CDN_PROFILE_KEY          install marker / profile key (cloudfront / combined)
#   CDN_EXPECTED_PROTOCOL    state PROTOCOL owned by the profile
#   CDN_MODE_LABEL           user-facing mode name
#   CDN_ENTRY_SUMMARY        entry summary used in the install success message
#   CDN_INSTALL_PORTS        TCP ports that must be free before a fresh install
# plus the hooks (empty results instead of guessing):
#   collect_install_inputs      collect this profile's inputs (calls the shared input collector)
#   cdn_direct_domains          direct A-record domains (empty for mode 2)
#   cdn_prepare_direct_runtime  persist the AnyTLS identity (no-op for mode 2)
#   cdn_validate_direct_runtime local acceptance of the direct entry (no-op for mode 2)
#
# AWS identity/ACM/distribution ownership, DNS, the 985GB protection state machine
# and the CloudFront lifecycle commands live here. sing-box/Caddy rendering, the
# DNS-01 certificate transaction, UFW and subscription publishing come from
# lib/runtime-core.sh with the Phase 1 renderers.

readonly AWS_CONTROL_REGION="us-east-1"
readonly CLOUDFRONT_CACHE_POLICY_ID="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
readonly CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID="b689b0a8-53d0-40ab-baf2-68738e2966ac"
readonly CLOUDFRONT_ORIGIN_ID="easy_all-cloudfront-origin"
readonly CLOUDFRONT_CONNECTION_ATTEMPTS="2"
readonly CLOUDFRONT_CONNECTION_TIMEOUT="3"
readonly CLOUDFRONT_ORIGIN_READ_TIMEOUT="120"
readonly CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT="120"
readonly CLOUDFRONT_DEPLOY_WAIT_ATTEMPTS="60"
readonly CLOUDFRONT_DEPLOY_WAIT_SECONDS="10"
readonly CDN_PUBLIC_ACCEPT_ATTEMPTS="${CDN_PUBLIC_ACCEPT_ATTEMPTS_OVERRIDE:-6}"
readonly CDN_PUBLIC_ACCEPT_SECONDS="${CDN_PUBLIC_ACCEPT_SECONDS_OVERRIDE:-10}"
readonly CDN_RECORD_COMMENT="easy_all cloudfront"
readonly ORIGIN_CERT_RENEW_SECONDS="2592000"
CLOUDFRONT_AWS_CLI_ARGS=(--no-cli-pager --cli-read-timeout 120 --cli-connect-timeout 60)

# shellcheck source=lib/cf-dns.sh
source "${RUNTIME_LIB_DIR}/cf-dns.sh"
# shellcheck source=lib/cdn-traffic-guard.sh
source "${RUNTIME_LIB_DIR}/cdn-traffic-guard.sh"

CDN_SUBSCRIPTION_CORRUPT=0
# 本轮已确认订阅未就绪且已有阻断：置 1 后本进程的 Nginx 渲染一律使用订阅 503 的最小配置，
# 否则后续 rebuild 会按“配置可解析”重新启用 /subscribe 并继续提供旧产物。
CDN_SUBSCRIPTION_DENIED=0

# --- Profile adapters ---------------------------------------------------------

# --- State contract -----------------------------------------------------------

# 运行时派生字段（不落盘）：load_state 与首装输入都必须派生，首装不经过 load_state。

# --- Subscription configuration ----------------------------------------------

# --- AWS credentials (memory only) -------------------------------------------

# --- Profile adapters ---------------------------------------------------------

# 运行时派生字段（不落盘）：首装不经过 load_state，安装输入处也必须派生。
cdn_derive_runtime_fields() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || return 1
    BACKEND=sing-box
    SUBSCRIPTION_MODE=deploy
    VLESS_CDN_DOMAIN=${CF_NODE_DOMAIN}
    [[ -n "${SUBSCRIPTION_DOMAIN:-}" ]] || SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
}

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
    local arch staging archive
    local prefix="${EASY_ALL_AWS_CLI_PREFIX_OVERRIDE:-/usr/local}"
    local bin_dir="${prefix}/bin" install_dir="${prefix}/aws-cli"
    case "$(dpkg --print-architecture 2>/dev/null || true)" in
    arm64) arch=aarch64 ;;
    *) arch=x86_64 ;;
    esac
    info "安装 AWS CLI v2"
    # /tmp 普遍被挂为 noexec：只给 installer 加 bash 前缀解决不了包内第二个程序，
    # 所以 archive 与整份解压结果都放在安装区域的私有 staging（创建后立即登记清理）。
    install -d -m 0755 "${prefix}" \
        || die "创建 AWS CLI 安装目录失败：${prefix}"
    staging=$(mktemp -d "${prefix}/easy_all-aws-cli.XXXXXX") \
        || die "创建 AWS CLI 临时安装目录失败：${prefix}"
    declare -p cleanup_files >/dev/null 2>&1 && cleanup_files+=("${staging}")
    archive="${staging}/awscliv2.zip"
    curl -fsSL --retry 3 "https://awscli.amazonaws.com/awscli-exe-linux-${arch}.zip" -o "${archive}" \
        || die "下载 AWS CLI v2 失败：${archive}"
    unzip -q "${archive}" -d "${staging}" || die "解压 AWS CLI v2 失败：${archive}"
    bash "${staging}/aws/install" \
        --bin-dir "${bin_dir}" --install-dir "${install_dir}" --update \
        || die "安装 AWS CLI v2 失败：${staging}/aws/install"
    hash -r
    command -v aws >/dev/null 2>&1 \
        || die "AWS CLI 安装后不在 PATH：${bin_dir}/aws（检查 ${prefix} 的挂载与执行权限）"
    # 除了查找与哈希，必须真的跑一次：安装区域本身 noexec 时这里才能报出来。
    aws --version >/dev/null 2>&1 \
        || die "AWS CLI 无法执行：${bin_dir}/aws（检查 ${prefix} 的挂载与执行权限）"
    rm -rf -- "${staging}"
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

# 域名输入按模式收敛：模式 4 的源站域名固定复用直连域名（443 直连与 8443 回源端口隔离、
# 共用一份 LE 证书与一条灰云 A），模式 2/4 的订阅域名固定复用节点域名（同一条分发别名与
# CNAME，订阅走 https://<节点域名>/subscribe）。同名复用不再提问，每条链路最多两个名字。
# 续装例外：沿用安装身份里已落盘的域名（旧版身份可能带独立源站/订阅域名）。
collect_cloudfront_domain_inputs() {
    if runtime_has_direct_entry; then
        anytls_collect_direct_inputs
        # 续装沿用身份里的源站域名：旧版身份可能带独立源站域名，改写会与已建分发/证书/DNS 冲突。
        [[ "${INSTALL_RESUME:-0}" == "1" && -n "${CF_ORIGIN_DOMAIN:-}" ]] \
            || CF_ORIGIN_DOMAIN=${DIRECT_DOMAIN}
    else
        CF_ORIGIN_DOMAIN=$(normalize_domain "$(prompt_value '源站域名（解析至 VPS，灰云直连）' "${CF_ORIGIN_DOMAIN:-origin.${CF_ZONE}}")")
    fi
    CF_NODE_DOMAIN=$(normalize_domain "$(prompt_value 'CloudFront 节点域名（CNAME 指向分发，灰云）' "${CF_NODE_DOMAIN:-cf.${CF_ZONE}}")")
    # 同理：续装沿用旧身份里的独立订阅域名，其余情况固定复用节点域名。
    [[ "${INSTALL_RESUME:-0}" == "1" && -n "${SUBSCRIPTION_DOMAIN:-}" ]] \
        || SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
}

collect_cloudfront_install_inputs() {
    # 续装时续用从 install-identity.json 恢复的值做提示默认值，不得先生成新值再覆盖。
    CF_ZONE=$(normalize_domain "$(prompt_value 'Cloudflare 根 Zone（如 example.com）' "${CF_ZONE:-}")")
    validate_domain "${CF_ZONE}" || die "Cloudflare Zone 无效：${CF_ZONE}"

    collect_cloudfront_domain_inputs
    cdn_validate_install_domains
    # 首装不经过 load_state：订阅渲染前必须在输入校验处派生运行时字段。
    cdn_derive_runtime_fields || die "运行时字段派生失败：缺少 CloudFront 节点域名"

    cloudflare_collect_api_token
    collect_aws_credentials

    VLESS_PATH=$(normalize_vless_path "${VLESS_PATH:-}")
    validate_vless_path "${VLESS_PATH}" || die "VLESS 路径无效：${VLESS_PATH}"

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
    collect_cdn_edge_address
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

# 收集、格式校验与 0600 持久化都在 lib/cf-dns.sh（五模式共用）。

cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN 2>/dev/null || true
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" \
        "${RUNTIME_TMP}/cloudflare-api-payload" 2>/dev/null || true
}

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

# 链校验必须是「leaf + 中间链 + 系统信任库」：Certbot 的 fullchain.pem 是
# leaf→intermediate 拼接，而 openssl verify 不会把目标文件后面的 PEM 当成链输入。
# 拆分首个 PEM 块为 leaf、其余为 intermediates，用 -untrusted 显式传入；单证书
# 部署（无 intermediate）仍按普通 verify 处理。

# 非致命验收：候选文件与现用副本共用同一套链/域名/有效期/配对检查。

# 证书部署事务：先用候选文件完成全部验收，再备份现用证书/私钥与 Nginx 配置，
# 安装后验收并重载；任一步失败恢复备份并返回非零，LE 新 lineage 保留供重试。

# 手动续签不是“到期待续”：certbot 默认会直接复用尚未到期的 lineage，必须显式
# --force-renewal 才能重新签发（仅 manual renew 传入；安装/自动 hook 不强制）。

# --- ACM ----------------------------------------------------------------------

# --- Origin Let's Encrypt certificate (design §6) ----------------------------

cdn_certificate_covers_origin() {
    certificate_covers_host "${1:-${CERT_FILE}}" "${CF_ORIGIN_DOMAIN}"
}

# 覆盖模式所需全部域名（模式 4 为 direct + origin）且仍在续期窗口内即复用。
cdn_issue_origin_certificate() {
    local force=${1:-0}
    install -d -m 0700 "${CERT_DIR}"
    if [[ "${force}" != "1" ]] \
        && certificate_covers_required_hosts "${CERT_FILE}" \
        && certificate_key_matches \
        && openssl x509 -in "${CERT_FILE}" -noout -checkend "${ORIGIN_CERT_RENEW_SECONDS}" >/dev/null 2>&1; then
        certificate_verify
        return 0
    fi
    certbot_write_cloudflare_credentials
    certbot_issue_certificate "${force}"
    certificate_deploy "" 0 || die "Certbot 未生成覆盖模式所需域名的有效证书"
}

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
    local destination=$1 caller=$2 origin_https_port
    # 回源端口由模式派生（design §2 F）：模式 2 的 Caddy 在 443，模式 4 在 8443。
    origin_https_port=$(caddy_site_port) || exit 1
    jq -n \
        --arg caller "${caller}" --arg alias "${CF_NODE_DOMAIN}" \
        --arg subscription "${SUBSCRIPTION_DOMAIN}" \
        --arg origin "${CF_ORIGIN_DOMAIN}" --arg origin_id "${CLOUDFRONT_ORIGIN_ID}" \
        --arg origin_key "${ORIGIN_HEADER_SECRET}" --arg comment "$(cloudfront_marker)" \
        --arg cache_policy "${CLOUDFRONT_CACHE_POLICY_ID}" \
        --arg origin_policy "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}" \
        --argjson origin_https_port "${origin_https_port}" \
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
            CustomOriginConfig:{HTTPPort:80,HTTPSPort:$origin_https_port,OriginProtocolPolicy:"https-only",
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
            GrpcConfig:{Enabled:false},
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

# 安装 services 阶段（Xray 刚启动）立即断言真实 StatsService 读数：timer 只是后续采样器，
# 计量接口不可用必须现在就让安装失败，而不是等 15 秒后的定时任务才发现。

# --- Public acceptance --------------------------------------------------------
#
# 本机验收（--resolve 127.0.0.1）不能证明真实公网链路：DNS 指向、CloudFront 已 Deployed、
# ACM 证书与源站头注入都可能在这里才暴露。公网探测一律走真实域名 + 系统 CA，禁止 -k。

# --- Local CDN acceptance -----------------------------------------------------

cdn_validate_cdn_blocked() {
    local status
    runtime_local_probe_context
    status=$(runtime_local_status "${VLESS_PATH}") || die "受限 CDN 阻断验收请求失败"
    [[ "${status}" == "503" ]] || die "受限 CDN 未返回 503（HTTP ${status}）"
}

# 安装 services 阶段立即断言 mangle 计量可用：timer 只是后续采样器，
# 计量不可用必须现在就让安装失败。
cdn_verify_traffic_counters() {
    cdn_traffic_require_counters \
        || die "无法建立或读取 mangle 计量规则（链 ${CDN_TRAFFIC_COUNTER_CHAIN}）；请检查 iptables 与 ${CDN_TRAFFIC_COUNTER_DIR}"
}

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
    local status origin_url
    # 源站端口由模式派生：直接把请求发到 Caddy 的站点端口，模式 4 的 443 是 sing-box，
    # 发到 443 只会被丢弃，把“连不上”误判成“守卫已拒绝”。
    origin_url="https://${CF_ORIGIN_DOMAIN}:$(caddy_site_port)${VLESS_PATH}"
    # Caddy 守卫对缺头/错头执行 abort：连接被关闭，curl 拿不到状态码。两者都算拒绝，
    # 但只要还能拿到 2xx 就说明守卫没生效。
    status=$(cdn_public_curl -o /dev/null -w '%{http_code}' \
        "${origin_url}" || true)
    case "${status}" in
    "" | 000 | 403 | 404) ;;
    *) return 1 ;;
    esac
    status=$(cdn_public_curl -o /dev/null -w '%{http_code}' \
        --header 'X-Easy-All-Origin-Key: wrong-origin-key' \
        "${origin_url}" || true)
    case "${status}" in
    "" | 000 | 403 | 404) return 0 ;;
    *) return 1 ;;
    esac
}

cdn_public_subscription_ok() {
    local token body decoded
    token=$(jq -r 'first(.[])' <<<"${ALLOWED_TOKENS:-[]}") || return 1
    [[ -n "${token}" && "${token}" != "null" ]] || return 1
    # 正确 Token：默认 Base64 必须含 WebSocket 节点，强制 clash 必须含 ws 传输。
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    decoded=$(printf '%s' "${body}" | openssl base64 -d -A 2>/dev/null) || return 1
    [[ "${decoded}" == *"type=ws"* ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"network: ws"* ]] || return 1
    # os=ios 走 Mihomo iOS 变体，node=all 走带 optional 节点的额外产物。
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'flag=clash' --data-urlencode 'os=ios' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    [[ "${body}" == *"network: ws"* ]] || return 1
    body=$(cdn_public_curl --get --data-urlencode "token=${token}" \
        --data-urlencode 'node=all' \
        "https://${SUBSCRIPTION_DOMAIN}/subscribe") || return 1
    decoded=$(printf '%s' "${body}" | openssl base64 -d -A 2>/dev/null) || return 1
    [[ "${decoded}" == *"type=ws"* ]]
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
    local attempt expected
    for ((attempt = 1; attempt <= CDN_PUBLIC_ACCEPT_ATTEMPTS; attempt++)); do
        if cdn_public_health_ok \
            && cdn_public_subscription_ok \
            && cdn_public_token_rejection_ok \
            && cdn_public_origin_header_guard_ok; then
            return 0
        fi
        ((attempt == CDN_PUBLIC_ACCEPT_ATTEMPTS)) || sleep "${CDN_PUBLIC_ACCEPT_SECONDS}"
    done
    expected=${CF_NODE_DOMAIN}
    [[ "${SUBSCRIPTION_DOMAIN}" == "${CF_NODE_DOMAIN}" ]] || expected+=" 与 ${SUBSCRIPTION_DOMAIN}"
    die "CloudFront 公网验收失败（已重试 ${CDN_PUBLIC_ACCEPT_ATTEMPTS} 次）：请确认 ${expected} 的 CNAME 已指向 ${AWS_CLOUDFRONT_DOMAIN:-CloudFront 分发域名}、分发已 Deployed、源站证书有效；修复后执行 sudo easy_all apply-cloud"
}

# --- Nginx --------------------------------------------------------------------

# 生成并应用指定的 Nginx 配置；失败用 die 报告，调用方需要在失败后继续后续边界时放进子 shell。

# 已有阻断且订阅未就绪：/subscribe 必须降级为 503，不得继续提供旧产物。

# --- Xray ---------------------------------------------------------------------

# --- UFW ----------------------------------------------------------------------

# --- Subscription rendering ---------------------------------------------------

# 新链路没有额外 CDN 分组；模板占位必须成功输出空文件。

cdn_subscription_available() {
    [[ "${CDN_SUBSCRIPTION_CORRUPT:-0}" == "0" ]] && cdn_config_ready
}

cdn_traffic_blocked_now() {
    local usage
    usage=$(cdn_traffic_read_usage) || return 1
    jq -e '.blocked == true' <<<"${usage}" >/dev/null
}

runtime_blocked_state() {
    local blocked=0
    cdn_traffic_blocked_now && blocked=1
    printf '%s\n' "${blocked}"
}

# blocked=1 时 sing-box 省略 CDN 入站、Caddy 代理路径 503；订阅始终可用。
write_runtime_config() {
    local blocked=${1:-} subscription_ok
    if [[ -z "${blocked}" ]]; then
        blocked=$(runtime_blocked_state)
    fi
    subscription_ok=0
    if [[ "${CDN_SUBSCRIPTION_DENIED:-0}" != "1" ]] && cdn_subscription_available; then
        subscription_ok=1
    fi
    runtime_write_config "${blocked}" "${subscription_ok}"
}

# 已有阻断且订阅未就绪：/subscribe 必须降级为 503，不得继续提供旧产物。
cdn_deny_subscription_runtime() {
    CDN_SUBSCRIPTION_DENIED=1
    ( runtime_write_config 1 0 && runtime_reload_caddy )
}

# --- Subscription rendering ---------------------------------------------------

build_node_links() {
    local extra
    if runtime_has_direct_entry; then
        build_anytls_link
        printf '\n'
    fi
    build_vless_ws_link
    printf '\n'
    extra=$(aggregation_node_links)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
    return 0
}

build_mihomo_nodes() {
    local extra
    if runtime_has_direct_entry; then
        build_mihomo_anytls_node
        printf '\n'
    fi
    build_mihomo_ws_node
    printf '\n'
    extra=$(aggregation_mihomo_nodes)
    [[ -z "${extra}" ]] || printf '%s\n' "${extra}"
    return 0
}

build_mihomo_proxy_names() {
    local extra groups='[]'
    aggregation_node_names >/dev/null 2>&1 || true
    extra=$(aggregation_node_names) || extra='[]'
    if [[ "${PROTOCOL}" == "combined-cloudfront" ]]; then
        groups=$(jq -cn '["AUTO","CDN-FALLBACK"]')
    fi
    jq -nr --argjson names "$(cdn_local_node_names)" --argjson extra "${extra}" \
        --argjson groups "${groups}" '
        ($names + $groups + $extra)[] | "        - \(.|@json)"'
}

# 模式 4 的自动组：AUTO url-test 与 CDN-FALLBACK（直连 → CDN），探测改用 HTTPS 443。
build_mihomo_proxy_groups() {
    if [[ "${PROTOCOL}" != "combined-cloudfront" ]]; then
        return 0
    fi
    jq -nr --arg direct "${DIRECT_NODE_NAME}" --arg cdn "${CF_NODE_PREFIX}" '
        "    - name: AUTO\n      type: url-test\n      url: https://www.gstatic.com/generate_204\n" +
        "      interval: 300\n      tolerance: 50\n      proxies:\n" +
        "        - \($direct|@json)\n        - \($cdn|@json)\n" +
        "    - name: CDN-FALLBACK\n      type: fallback\n" +
        "      url: https://www.gstatic.com/generate_204\n      interval: 300\n" +
        "      proxies:\n        - \($direct|@json)\n        - \($cdn|@json)\n"'
}

cloudfront_template_snapshot_file() {
    printf '%s/mihomo-template.yaml' "${STATE_DIR}"
}

# 共享订阅事务（snapshot/rollback_subscription_update）按该路径把模板快照与 state、
# 六种产物一起备份与回滚；模板不属于 mode 1 的事务。
RT_TEMPLATE_SNAPSHOT_PATH=$(cloudfront_template_snapshot_file)

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
# 供六产物就绪验收使用；sing-box JSON 不进入这个门禁（见 design §8.2）。
cloudfront_render_subscription_files() {
    cloudfront_prepare_subscription_template
    render_mihomo_base64_files "$1"
}

refresh_runtime_subscription() {
    cloudfront_write_subscriptions
    validate_singbox_subscription_runtime
    save_state
}

# --- Local acceptance ---------------------------------------------------------

# 本机节点必须来自当前身份且固定在列表头部：模式 2 只有 CloudFront，模式 3 只有 Cloudflare 橙云节点；
# 聚合节点可以跟在后面，但不得冒充本机节点。

# 六产物就绪：当前 state/模板重新渲染的结果必须与已发布文件逐字节一致，
# 缺失任一文件或内容来自上一代都算未就绪。

# --- Traffic runtime rebuild --------------------------------------------------

# --- Command admission --------------------------------------------------------

# --- Local acceptance ---------------------------------------------------------

# 六产物就绪：当前 state/模板重新渲染的结果必须与已发布文件逐字节一致，
# 缺失任一文件或内容来自上一代都算未就绪。
cdn_subscription_artifacts_ready() {
    local render_dir name ready=1
    render_dir=$(mktemp -d "${RUNTIME_TMP}/subscription-ready.XXXXXX") || return 1
    cleanup_files+=("${render_dir}")
    # 渲染用 die 报告失败：放进子 shell 只取退出码，模板/节点问题不得终止整条命令。
    if ! ( cloudfront_render_subscription_files "${render_dir}" ) >/dev/null 2>&1; then
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

cdn_subscription_ready() {
    cdn_config_ready || return 1
    cdn_subscription_artifacts_ready || return 1
    # 就绪判定必须可降级：validate_subscription_runtime 失败用 die 终止进程，
    # 裸调用会把“订阅不可用”变成整个命令静默退出，所以放进子 shell 只取其退出码。
    ( validate_subscription_runtime ) >/dev/null 2>&1
}

cdn_validate_restricted_runtime() {
    validate_protocol_runtime || return 1
    runtime_local_probe_context
    cdn_traffic_probe_counters || die "受限运行时无法读取 mangle 计量计数"
    cdn_validate_cdn_blocked
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
    warn "先应用受限 sing-box/Caddy 配置，再重启核心"
    if ! (
        write_runtime_config 1 || exit 1
        runtime_apply_runtime_services || exit 1
        cdn_validate_restricted_runtime || exit 1
    ); then
        warn "受限安全恢复未通过必需验收；持久化保护性停机标记并停止核心"
        cdn_traffic_mark_protection_offline \
            || warn "无法持久化保护性停机标记；只能人工修复 ${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        systemctl stop "${SINGBOX_SERVICE}" >/dev/null 2>&1 \
            || warn "停止 sing-box 失败：旧 CDN 连接可能仍存活"
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
    local target=${1:-} blocked=0 backup usage
    if [[ "${target}" == "true" ]]; then
        blocked=1
    elif [[ "${target}" != "false" ]]; then
        # 无显式目标（受限恢复入口）时才读取持久目标；sync 必须传本次采样目标。
        usage=$(cdn_traffic_read_usage) || { warn "CDN 保护统计缺失或损坏；拒绝重建运行时"; return 1; }
        jq -e '.blocked == true' <<<"${usage}" >/dev/null && blocked=1
    fi
    backup=$(make_temp_dir)
    [[ ! -f "${SINGBOX_CONFIG}" ]] || install -m 0600 "${SINGBOX_CONFIG}" "${backup}/singbox.json"
    [[ ! -f "${CADDY_CONFIG}" ]] || install -m 0600 "${CADDY_CONFIG}" "${backup}/Caddyfile"
    if (
        write_runtime_config "${blocked}" || exit 1
        runtime_apply_runtime_services || exit 1
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
        # 阻断失败不能恢复开放配置后标成功：保留已生效的 503，先持久化停机意图再停核心。
        warn "应用 CDN 阻断失败；保留 Caddy 503，持久化保护性停机标记后停止核心"
        cdn_traffic_mark_protection_offline \
            || warn "无法持久化保护性停机标记；只能人工修复 ${CDN_TRAFFIC_GUARD_USAGE_FILE}"
        systemctl stop "${SINGBOX_SERVICE}" >/dev/null 2>&1 \
            || warn "停止 sing-box 失败：旧 CDN 连接可能仍存活"
        return 1
    fi
    warn "解封失败；恢复原受限配置并保留解封 pending"
    if [[ -f "${backup}/singbox.json" ]]; then
        install -m 0600 "${backup}/singbox.json" "${SINGBOX_CONFIG}"
    fi
    if [[ -f "${backup}/Caddyfile" ]]; then
        install -m 0600 "${backup}/Caddyfile" "${CADDY_CONFIG}"
    fi
    if runtime_apply_runtime_services >/dev/null 2>&1 && validate_protocol_runtime >/dev/null 2>&1; then
        return 1
    fi
    warn "连原受限配置也无法恢复；持久化保护性停机标记并停止核心"
    cdn_traffic_mark_protection_offline \
        || warn "无法持久化保护性停机标记；只能人工修复 ${CDN_TRAFFIC_GUARD_USAGE_FILE}"
    systemctl stop "${SINGBOX_SERVICE}" >/dev/null 2>&1 \
        || warn "停止 sing-box 失败：旧 CDN 连接可能仍存活"
    return 1
}

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
    # 返回值由 internal_scheduled_reboot（即 cron 行里的 easy_all 内部入口）交给
    # `sh -c` 执行，不再拼进 crontab，所以不需要 `%` 转义（cron 已看不到这段文本）。
    # jq 表达式是固定字面量且不含单引号，单引号包裹即可；usage 路径用 %q 只是为
    # `sh -c` 执行时的引号稳妥（路径是固定字面量，%q 输出与原文一致）。
    printf "jq -e '%s' %q >/dev/null" \
        "$(cdn_traffic_locked_check_jq)" "${CDN_TRAFFIC_GUARD_USAGE_FILE}"
}

# --- Commands -----------------------------------------------------------------

# 成功提交本机运行时：注册命令 + 恢复云费用保护定时器。任一步失败即非零，
# 调用方不得报告成功（设计 §8.1 的安装/apply 成功条件）。

# 云端同步阶段：任何 AWS 调用前显式收集并校验凭据（已有环境变量则复用）。
# 成功离开该阶段由 apply_cloud_resources 显式清除；失败/中断由 runtime-core 的
# cleanup 钩子（clear_profile_credentials）清除——不用 if/|| 包裹，否则会关闭
# 整个阶段的 errexit，把中途失败当成继续执行。

# 保护性停机的安全边界：Nginx deny 与停旧 Xray 是两个独立的必须动作，
# 任一步失败都不能跳过另一步（旧 CDN 长连接会继续存活）。

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
    local cert_enddate="" usage_offline
    require_root
    collect_installed_state
    printf '模式: %s\n' "${CDN_MODE_LABEL}"
    printf '协议: %s\n' "$(runtime_protocol_label)"
    show_tcp_acceleration_status
    if runtime_has_direct_entry; then
        printf '直连域名: %s（AnyTLS，TCP 443）\n' "${DIRECT_DOMAIN}"
    fi
    if runtime_has_cdn_entry; then
        printf 'CDN 节点域名: %s（Caddy 回环 %s）\n' "${CF_NODE_DOMAIN}" \
            "$(runtime_cdn_loopback_port)"
    fi
    printf '订阅域名: %s\n' "$(subscription_link_domain)"
    if state_protocol_uses_cloudfront "${PROTOCOL}"; then
        printf '源站域名: %s（Caddy HTTPS %s）\n' "${CF_ORIGIN_DOMAIN}" "$(caddy_site_port)"
        printf 'CloudFront 分发: %s（%s）\n' \
            "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${AWS_CLOUDFRONT_DOMAIN}"
        printf 'ACM 证书: %s（%s）\n' "${AWS_ACM_CERTIFICATE_ARN}" "${AWS_CONTROL_REGION}"
    fi
    if state_protocol_uses_origin_ca "${PROTOCOL}"; then
        printf 'Cloudflare Origin CA: %s（到期 %s）\n' \
            "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}"
    fi
    if [[ -s "${CERT_FILE}" ]]; then
        cert_enddate=$(openssl x509 -in "${CERT_FILE}" -noout -enddate 2>/dev/null | sed -n 's/^notAfter=//p')
        if certificate_check "${CERT_FILE}" "${KEY_FILE}" >/dev/null 2>&1; then
            printf '证书到期: %s（覆盖 %s）\n' "${cert_enddate:-未知}" \
                "$(certificate_required_hosts | paste -sd, -)"
        else
            printf '证书异常：未覆盖所需域名、与私钥不配对或链无效；请执行 sudo easy_all renew-cert\n'
        fi
    elif state_protocol_uses_cloudfront "${PROTOCOL}" || [[ "${PROTOCOL}" == "anytls" ]]; then
        printf '证书: 缺失；请执行 sudo easy_all renew-cert\n'
    fi
    printf 'sing-box: '
    systemctl is-active --quiet "${SINGBOX_SERVICE}" 2>/dev/null \
        && printf 'active（%s）\n' "${SINGBOX_SERVICE}" || printf 'inactive\n'
    printf 'Caddy: '
    if runtime_caddy_site_enabled; then
        systemctl is-active --quiet "${CADDY_SERVICE}" 2>/dev/null \
            && printf 'active（%s）\n' "${CADDY_SERVICE}" || printf 'inactive\n'
    else
        printf '未部署（link）\n'
    fi
    if state_protocol_uses_cloudfront "${PROTOCOL}"; then
        printf 'CDN 计量规则: '
        if cdn_traffic_counters_ready 2>/dev/null; then
            printf 'ok（链 %s，锁 %s）\n' "${CDN_TRAFFIC_COUNTER_CHAIN}" "${CDN_TRAFFIC_COUNTER_LOCK}"
        else
            printf '缺失或损坏（请执行 sudo easy_all cdn-traffic-sync）\n'
        fi
        printf 'CDN 流量保护定时器: '
        systemctl is-active --quiet "${CDN_TRAFFIC_GUARD_TIMER}" 2>/dev/null \
            && printf 'active\n' || printf 'inactive\n'
        show_cdn_traffic_protection_status
    fi
    if [[ "${CDN_SUBSCRIPTION_CORRUPT}" != "0" ]]; then
        printf '订阅: 配置损坏，当前不可用；请执行 sudo easy_all edit-sub\n'
    fi
    if state_protocol_uses_cloudfront "${PROTOCOL}"; then
        usage_offline=$(cdn_traffic_read_usage 2>/dev/null | jq -r '.protection_offline // false' 2>/dev/null || true)
        if [[ "${usage_offline}" == "true" ]]; then
            printf '保护性停机: 是（运行时受限或已停止，等待 cdn-traffic-sync 收敛）\n'
        fi
    fi
}

# 成功提交本机运行时：注册命令 + 恢复云费用保护定时器。任一步失败即非零，
# 调用方不得报告成功。
cdn_commit_local_runtime() {
    register_easy_all_command
    if state_protocol_uses_cloudfront "${PROTOCOL}"; then
        install_cdn_traffic_protection_timer
    fi
}

apply_easy_all() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_traffic_admission
    cdn_require_valid_subscription
    snapshot_subscription_update
    if ! cdn_traffic_protection_checkpoint; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
        die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止应用，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    configure_tcp_acceleration
    configure_ipv4_only
    configure_runtime_ufw
    write_runtime_config "$(runtime_blocked_state)"
    # 最后一次采样必须紧贴 restart：中间的调优/UFW/配置写入期间旧进程仍在计数。
    if ! cdn_traffic_protection_checkpoint; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
        die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止应用，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    # enable --now 对已运行的 unit 是空操作：不重启的话新的 UUID/路径/证书不会生效。
    runtime_apply_runtime_services
    validate_protocol_runtime
    cdn_validate_direct_runtime
    cloudfront_write_subscriptions
    validate_subscription_runtime
    validate_singbox_subscription_runtime
    save_state
    cdn_commit_local_runtime
    commit_subscription_update
    success "本机配置与订阅已应用；未修改 DNS 与云端资源"
}

# 云端同步阶段：任何 AWS 调用前显式收集并校验凭据（已有环境变量则复用）。
# 成功离开该阶段由 apply_cloud_resources 显式清除；失败/中断由 runtime-core 的
# cleanup 钩子（clear_profile_credentials）清除。
apply_cloud_phase() {
    cloudflare_collect_api_token
    collect_aws_credentials
    persist_cloudflare_token
    cdn_prepare_origin_dns
    cdn_wait_for_origin_dns
    certbot_write_cloudflare_credentials
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
    if ! cdn_traffic_protection_checkpoint; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
        die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止云端同步，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    configure_tcp_acceleration
    configure_ipv4_only
    configure_runtime_ufw
    apply_cloud_phase
    clear_aws_credentials
    persist_install_identity || die "无法落盘安装身份；已保留云端资源"
    write_runtime_config "$(runtime_blocked_state)"
    # 云端阶段耗时长：最后一次采样紧贴 restart，计入云等待期间旧进程的流量。
    if ! cdn_traffic_protection_checkpoint; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
        die "流量 checkpoint 产生待落实的 CDN 阻断状态；已停止云端同步，请先运行 sudo easy_all cdn-traffic-sync"
    fi
    runtime_apply_runtime_services
    validate_protocol_runtime
    cdn_validate_direct_runtime
    cloudfront_write_subscriptions
    validate_subscription_runtime
    validate_singbox_subscription_runtime
    # 本机 apply 子流程完成后才能证明公网链路；失败时云端资源保留，可重试 apply-cloud。
    cdn_validate_public_runtime
    save_state
    cdn_commit_local_runtime
    commit_subscription_update
    success "本机配置、订阅与云端资源已同步"
}

# 保护性停机的安全边界：Caddy 代理路径 503 与停核心是两个独立的必须动作，
# 任一步失败都不能跳过另一步（旧 CDN 长连接会继续存活）。
cdn_establish_denied_boundary() {
    local failed=0
    if ! ( runtime_write_config 1 0 && runtime_reload_caddy ); then
        warn "无法确立 Caddy 代理路径 503；旧 CDN 连接可能仍存活，继续停止核心"
        failed=1
    fi
    if systemctl is-active --quiet "${SINGBOX_SERVICE}" 2>/dev/null; then
        systemctl stop "${SINGBOX_SERVICE}" >/dev/null 2>&1 || true
        if systemctl is-active --quiet "${SINGBOX_SERVICE}" 2>/dev/null; then
            warn "停止 sing-box 失败：旧 CDN 连接可能仍存活"
            failed=1
        fi
    fi
    return "${failed}"
}

update_subscription() {
    (($# == 0)) || die "edit-sub 不接受额外参数"
    local raw_config="" caller_config=${SUBSCRIPTION_CONFIG:-} restricted=0
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    cdn_require_traffic_usage
    if cdn_traffic_needs_restricted_recovery; then
        restricted=1
        warn "检测到 CDN 保护待落实；仅在保持 Caddy 503 与停止的核心前提下修复订阅"
        cdn_establish_denied_boundary \
            || die "无法确立 Caddy 503 的安全边界；已停止订阅修复"
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
    # 修复闭环：新配置已强校验并应用，旧订阅的损坏标记必须在此清零。
    CDN_SUBSCRIPTION_CORRUPT=0
    if [[ "${restricted}" == "1" ]]; then
        UPDATE_SUB_ROLLBACK_NO_RESTART=1
    fi
    snapshot_subscription_update
    cloudfront_write_subscriptions
    if [[ "${restricted}" == "1" ]]; then
        runtime_write_config 1 1
        runtime_apply_runtime_services
    else
        write_runtime_config "$(runtime_blocked_state)"
        runtime_apply_runtime_services
    fi
    validate_subscription_runtime
    validate_singbox_subscription_runtime
    save_state
    if [[ "${restricted}" == "1" ]]; then
        commit_subscription_update
        show_cdn_traffic_protection_status
        warn "订阅修复完成，保护仍 pending；核心保持停机，请执行 sudo easy_all cdn-traffic-sync 恢复"
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
    # 手动换证书必须纳入订阅事务：后续发布/重启/验收失败时同时恢复证书与配置。
    snapshot_subscription_update
    usage=$(cdn_traffic_read_usage)
    jq -e '.blocked == true and .enforced == false' <<<"${usage}" >/dev/null && restricted=1
    install_certbot_deploy_hook
    cloudflare_collect_api_token
    certbot_write_cloudflare_credentials
    if [[ "${restricted}" == "1" ]]; then
        warn "CDN 保护待落实：先只修复证书并保持 Caddy 503，再执行受限恢复"
        if certificate_lineage_is_newer; then
            certificate_deploy "" 0 || die "已有较新证书但部署失败"
        else
            certbot_issue_certificate 1
            certificate_deploy "" 0 || die "Certbot 未生成有效证书"
        fi
        certificate_verify
        runtime_write_config 1 1
        runtime_reload_caddy
        cdn_traffic_recover_restricted_runtime \
            || die "证书已部署，但受限运行时恢复失败；保留保护待落实状态"
        runtime_served_certificate_matches_disk \
            || die "受限恢复后本机 TLS 尚未使用新证书；保留保护待落实状态"
        cdn_subscription_ready \
            || die "证书已部署、受限运行时已恢复，但订阅未就绪；请执行 sudo easy_all edit-sub"
        save_state
        commit_subscription_update
        success "证书已更新，受限运行时已恢复"
        return 0
    fi
    if certificate_lineage_is_newer; then
        certificate_deploy "" 0 || die "部署已签发的新证书失败"
    else
        certbot_issue_certificate 1
        certificate_deploy "" 0 || die "Certbot 未生成有效证书"
    fi
    certificate_verify
    write_runtime_config "$(runtime_blocked_state)" 1
    runtime_apply_runtime_services 1
    validate_protocol_runtime
    runtime_served_certificate_matches_disk \
        || die "本机 TLS 尚未使用新证书；已保留新 lineage，请修复后重试 renew-cert"
    validate_subscription_runtime
    save_state
    commit_subscription_update
    success "证书已更新；CloudFront viewer 证书由 ACM 自动续期"
}

cdn_local_uninstall_common() {
    stop_maintenance_services || true
    remove_cdn_traffic_protection_timer || true
    stop_services
    # 先停核心再回收计量；失败时不删除 state/命令，保留重试依据。
    cdn_traffic_counters_remove \
        || { warn "回收 mangle 计量规则失败；已保留本机状态与命令，修正后重试 uninstall"; return 1; }
    remove_certbot_deploy_hook || true
    certificate_remove_lineage || true
    restore_platform_security_state || {
        warn "SSH 配置恢复失败；请通过服务商 Console 检查"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    if ! remove_daily_reboot_schedule; then
        # 不能把「root crontab 没改成功」当成卸载完成：否则命令链接、业务目录和状态一起被删，
        # 而标记任务仍会写入一个已不存在的环境。保留现场供修正后重试。
        warn "卸载未完成：移除 easy_all 定时重启任务失败，本机状态与命令已保留；修正 root crontab 后重试 uninstall"
        return 1
    fi
    rm -f -- "${SINGBOX_SERVICE_FILE}" "${CADDY_SERVICE_FILE}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${SUBSCRIPTION_DIR}" "$(dirname -- "${SUBSCRIPTION_DIR}")" \
        "${COMMAND_INSTALL_DIR}" "$(dirname -- "${SINGBOX_BIN}")" "$(dirname -- "${CADDY_BIN}")"
}

uninstall_all() {
    local answer cloud_failed=0
    require_root
    (($# == 0)) || die "uninstall 不支持参数：$*"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all 尚未安装"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    if [[ "${FORCE:-0}" != "1" ]]; then
        [[ -t 0 ]] || die "非交互卸载必须显式设置 FORCE=1"
        read_bilingual '删除 easy_all 本机服务、状态和证书，以及本工具创建的 CloudFront 分发、ACM 证书与业务 DNS（ACM validation CNAME 保留）？[y/N]:' answer
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services || true
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    [[ ! -f "${STATE_FILE}" ]] || load_state
    cdn_print_cloud_inventory
    printf '正在按上方清单尝试清理本工具创建的云端资源；因归属保护而未删除的条目会在下方点名。\n' >&2
    # 云端清理在可捕获的子 shell 中执行：缺凭据/任何 die 只告警，不终止本机卸载。
    if (cdn_purge_aws_resources); then
        :
    else
        warn "云端资源清理未完成；本机卸载继续。请保存上方资源清单并手动处置；本机状态删除后无法再按本次安装状态重试清理"
        cloud_failed=1
    fi
    cdn_local_uninstall_common || return 1
    success "easy_all 本机内容已卸载；云端清理结果见上方输出"
    warn "若有 ACM validation CNAME 残留，需核实无其他证书使用后人工删除"
    ((cloud_failed == 0)) || return 1
}

cleanup_partial_install() {
    cleanup_partial_install_local || return 1
    remove_cdn_traffic_protection_timer || true
    cdn_traffic_counters_remove \
        || { warn "回收 mangle 计量规则失败；已保留安装进度标记与状态，修正后重试 cleanup-partial"; return 1; }
    remove_certbot_deploy_hook || true
    # 只删本工具专属的 Certbot lineage；其他站点的证书/hook 不动。
    certificate_remove_lineage || true
    remove_daily_reboot_schedule || true
    cleanup_partial_install_files \
        "${SINGBOX_SERVICE_FILE}" "${CADDY_SERVICE_FILE}" "${COMMAND_PATH}" \
        "${STATE_DIR}" "${SUBSCRIPTION_DIR}" "$(dirname -- "${SUBSCRIPTION_DIR}")" \
        "${COMMAND_INSTALL_DIR}" "$(dirname -- "${SINGBOX_BIN}")" "$(dirname -- "${CADDY_BIN}")"
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
    warn "本次已创建的云端资源按设计保留；easy_all 命令已随回滚移除，确认不再使用后可执行 bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) purge-cloudflare --domain <域名> 清理 Cloudflare 资源；CloudFront 分发与 ACM 证书请在 AWS 控制台删除"
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
    prepare_fresh_install \
        "$(runtime_public_tcp_ports)" "$(runtime_cloudflare_only_port)" \
        "$(runtime_cdn_loopback_port)"
    install_progress_begin "${CDN_PROFILE_KEY}" cloudfront
    snapshot_fresh_install

    install_progress_stage packages
    install_packages
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
    download_singbox
    download_caddy
    cdn_prepare_direct_runtime
    install_progress_stage services
    cloudflare_collect_api_token
    persist_cloudflare_token
    configure_runtime_ufw
    cdn_prepare_origin_dns
    cdn_wait_for_origin_dns
    initialize_cdn_traffic_usage
    cdn_traffic_prepare_counters || die "无法建立 mangle 计量规则；已停止安装"
    certbot_write_cloudflare_credentials
    cdn_issue_origin_certificate
    write_runtime_config 0 0
    # sing-box 的 ExecStartPre 调用已注册的 easy_all；首装必须在启动服务前注册入口，
    # 否则新机器上第一次启动会找不到 /usr/local/bin/easy_all。
    register_easy_all_command
    runtime_apply_runtime_services
    # 核心刚启动：现在就断言 mangle 计数可读，不等 timer 才发现计量不可用。
    cdn_verify_traffic_counters
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
    runtime_write_config 0 1
    runtime_reload_caddy
    validate_subscription_runtime
    validate_singbox_subscription_runtime
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

cdn_print_cloud_inventory() {
    local domain dns_names
    printf '云端资源清单：\n' >&2
    printf '  CloudFront 分发: %s（%s）\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-未知}" \
        "${AWS_CLOUDFRONT_DOMAIN:-未知}" >&2
    printf '  ACM 证书 ARN: %s\n' "${AWS_ACM_CERTIFICATE_ARN:-未知}" >&2
    printf '  源站 A 记录: %s -> %s\n' "${CF_ORIGIN_DOMAIN:-未知}" "${VPS_PUBLIC_IPV4:-未知}" >&2
    while IFS= read -r domain; do
        [[ -n "${domain}" ]] || continue
        [[ "${domain}" != "${CF_ORIGIN_DOMAIN:-}" ]] || continue
        printf '  直连 A 记录: %s -> %s\n' "${domain}" "${VPS_PUBLIC_IPV4:-未知}" >&2
    done < <(cdn_direct_domains)
    dns_names=${CF_NODE_DOMAIN:-未知}
    [[ "${SUBSCRIPTION_DOMAIN:-}" == "${CF_NODE_DOMAIN:-}" ]] || dns_names+=",${SUBSCRIPTION_DOMAIN:-未知}"
    printf '  节点/订阅 CNAME: %s -> %s\n' "${dns_names}" "${AWS_CLOUDFRONT_DOMAIN:-未知}" >&2
    printf '  ACM validation CNAME 默认保留（同一验证记录可能被其他证书复用，需核实后手工删除）\n' >&2
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
        # 注释已在本工具安装时被改写：只有接管日志才能证明它原本属于第三方。
        if dns_record_taken_over "${host}"; then
            warn "Cloudflare ${host} 的 ${type} 记录来自强制接管（原注释/指向见 $(dns_takeover_log_file)）；保留，如需删除请手工处理"
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

# 旧链路按当时的归属注释删 DNS：只删同名单条且注释完全一致的 A 记录。

# 旧链路用 easy_all-cf-origin 注释放行 Cloudflare 回源段；新核心不声明该常量。

# 新协议但强制字段缺失/来自未完成实现：只清本机，云端一律保留。
