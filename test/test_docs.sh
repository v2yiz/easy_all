#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
README_CONTENT=$(<"${ROOT_DIR}/README.md")
AWS_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/aws-guide.md")
GCORE_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/gcore-guide.md")
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
XHTTP_CONTENT=$(<"${ROOT_DIR}/lib/xhttp_aws.sh")

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local label=$1 haystack=$2 needle=$3
    [[ "${haystack}" == *"${needle}"* ]] || fail "${label}: missing '${needle}'"
}

assert_not_contains() {
    local label=$1 haystack=$2 needle=$3
    [[ "${haystack}" != *"${needle}"* ]] || fail "${label}: unexpected '${needle}'"
}

while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    assert_contains "README runtime module list" "${README_CONTENT}" "$(basename "${relative_path}")"
done < <(
    sed -n '/readonly -a EASY_ALL_RUNTIME_MODULES=(/,/^)/p' "${ROOT_DIR}/easy_all" \
        | sed -n 's/^[[:space:]]*"\(lib\/[^\"]*\)"/\1/p'
)

for command in show subscription self-update apply apply-cloud update-sub update-core \
    renew-cert quota-status quota-set quota-reset status uninstall help; do
    assert_contains "README public command ${command}" "${README_CONTENT}" "| \`${command}"
done

assert_contains "README Reality stage count" "${README_CONTENT}" \
    '保存最终状态 / 注册 easy_all / 配置配额任务'
assert_contains "README XHTTP stage count" "${README_CONTENT}" \
    '源站证书 / Xray / Nginx / 已选订阅输出验收'
assert_contains "README documents the third Gcore installation branch" "${README_CONTENT}" \
    'Gcore CDN XHTTP'
assert_contains "README documents Gcore as a token-only provider" "${README_CONTENT}" \
    'GCORE_API_TOKEN'
assert_contains "README documents Gcore's reduced XHTTP window" "${README_CONTENT}" \
    '`10-14` 秒'
assert_contains "Gcore guide documents the active XHTTP window" "${GCORE_GUIDE_CONTENT}" \
    '`10-14` 秒'
assert_contains "README documents the generic CDN traffic guard module" "${README_CONTENT}" \
    'cdn-traffic-guard.sh'
assert_contains "README documents legacy traffic guard artifact compatibility" "${README_CONTENT}" \
    'easy_all-cloudfront-fee.service'
assert_contains "README documents merged Profile helpers" "${README_CONTENT}" \
    'profile-common.sh'
assert_contains "README documents merged scheduled maintenance" "${README_CONTENT}" \
    'scheduled-maintenance.sh'
assert_contains "README dynamic ports describe NAT" "${README_CONTENT}" \
    'UFW 的 `before.rules` 受管 NAT 区块'
assert_contains "README dynamic ports reject per-port allows" "${README_CONTENT}" \
    '不会生成数万条'
assert_contains "README documents client-controlled Mihomo IP family" "${README_CONTENT}" \
    '生成的 Mihomo/Clash 节点不写入 `ip-version`'
assert_contains "README documents Gemini egress policy for all profiles" "${README_CONTENT}" \
    '三种模式都会从 Mihomo 模板顶部的 Gemini 域名元数据生成 VPS 端专用出站'
assert_contains "README documents client connection racing" "${README_CONTENT}" \
    '内置 Mihomo 模板启用 `tcp-concurrent`'
assert_contains "README documents idle slow-start tuning" "${README_CONTENT}" \
    '`tcp_slow_start_after_idle`'
assert_contains "README update-sub includes Xray" "${README_CONTENT}" \
    '同步重建本机 Xray、Nginx 和订阅文件'
assert_contains "XHTTP command message includes Xray" "${XHTTP_CONTENT}" \
    'update-sub 只更新本机 Xray、订阅与 Nginx'

if [[ "${XHTTP_CONTENT}" == *'AWS_USE_DEFAULT_CREDENTIAL_CHAIN'* ]]; then
    assert_contains "launcher guide documents AWS default chain" "${LAUNCHER_CONTENT}" \
        '也可用默认凭证链'
    assert_contains "README documents AWS default chain" "${README_CONTENT}" \
        'AWS_USE_DEFAULT_CREDENTIAL_CHAIN=1'
    assert_not_contains "Access Key guide excludes default-chain VPS usage" \
        "${AWS_GUIDE_CONTENT}" 'AWS_USE_DEFAULT_CREDENTIAL_CHAIN=1'
fi

assert_contains "Access Key guide names access key ID" "${AWS_GUIDE_CONTENT}" \
    'AWS_ACCESS_KEY_ID'
assert_contains "Access Key guide names secret access key" "${AWS_GUIDE_CONTENT}" \
    'AWS_SECRET_ACCESS_KEY'
for vps_marker in 'sudo ' 'dig +short' 'easy_all apply' './easy_all install'; do
    assert_not_contains "AWS guide excludes VPS marker ${vps_marker}" \
        "${AWS_GUIDE_CONTENT}" "${vps_marker}"
done
assert_contains "AWS guide includes Route 53 delegation" \
    "${AWS_GUIDE_CONTENT}" '这是 CDN XHTTP 的**必要条件**'
assert_contains "README clearly separates one-time delegation from automatic records" \
    "${README_CONTENT}" 'DNS 操作边界：手动一次，后续自动。'
assert_contains "AWS guide says the script writes node records automatically" \
    "${AWS_GUIDE_CONTENT}" '安装脚本会自动写入这些节点记录'
assert_not_contains "AWS guide omits the confusing subdomain-only delegation branch" \
    "${AWS_GUIDE_CONTENT}" '方式 B：只委派专用子域名'
assert_not_contains "README omits subdomain-only delegation guidance" \
    "${README_CONTENT}" '建议只委派专用子域名'
assert_contains "AWS guide includes CloudFront cost boundary" \
    "${AWS_GUIDE_CONTENT}" '100 GB + 100 万次请求'
assert_contains "AWS guide includes pay-as-you-go perpetual free usage" \
    "${AWS_GUIDE_CONTENT}" '1 TB + 1000 万次请求'
assert_contains "AWS guide estimates Route 53 standard queries" \
    "${AWS_GUIDE_CONTENT}" '$0.40/百万次'
assert_contains "AWS guide explains fixed-plan overage pricing" \
    "${AWS_GUIDE_CONTENT}" '超出费用估算仍为 `$0`'
assert_contains "AWS guide explains pay-as-you-go WAF behavior" \
    "${AWS_GUIDE_CONTENT}" '按量付费模式不创建 WAF'
assert_contains "README documents the pay-as-you-go global guard" \
    "${README_CONTENT}" '固定阈值为 `980 GB`'
assert_contains "README documents the AWS-aligned UTC reset" \
    "${README_CONTENT}" '每月 1 日 `00:00 UTC` 重置'
assert_contains "AWS guide documents the 980 GB safety buffer" \
    "${AWS_GUIDE_CONTENT}" '980 GB'
assert_contains "AWS guide says only two credentials are supplied to the script" \
    "${AWS_GUIDE_CONTENT}" '安装时你只需要向脚本提供'
assert_contains "AWS guide pins CloudFront control operations to us-east-1" \
    "${AWS_GUIDE_CONTENT}" 'AWS 控制区域：选择 `us-east-1`（美国·弗吉尼亚北部）'
assert_contains "AWS guide explains that the control region is not the traffic region" \
    "${AWS_GUIDE_CONTENT}" '这不是节点的落地位置选择'
assert_contains "Gcore guide documents the implemented third installation option" \
    "${GCORE_GUIDE_CONTENT}" '已实现 Gcore CDN XHTTP 安装链路'
assert_contains "Gcore guide accepts one API token" \
    "${GCORE_GUIDE_CONTENT}" 'GCORE_API_TOKEN'
assert_contains "Gcore guide records the Free CDN monthly allowance" \
    "${GCORE_GUIDE_CONTENT}" '1 TB'
assert_contains "Gcore guide records the Free CDN request allowance" \
    "${GCORE_GUIDE_CONTENT}" '10 亿'
assert_contains "Gcore guide documents the active 980 GB safety boundary" \
    "${GCORE_GUIDE_CONTENT}" '在 **980 GB** 时阻断'
assert_contains "Gcore guide uses only full-domain delegation" \
    "${GCORE_GUIDE_CONTENT}" '只采用**整个主域名**交给'
assert_contains "Gcore guide requires least-privilege CDN role" \
    "${GCORE_GUIDE_CONTENT}" 'CDN Editor'
assert_contains "Gcore guide requires least-privilege DNS role" \
    "${GCORE_GUIDE_CONTENT}" 'DNS Editor'
assert_contains "Gcore guide retains real-network XHTTP validation boundary" \
    "${GCORE_GUIDE_CONTENT}" '上线前的实际连通性检查'
assert_contains "Gcore guide documents no-card no-paid-resource boundary" \
    "${GCORE_GUIDE_CONTENT}" '不绑定信用卡'
for vps_marker in 'sudo ' 'dig +short' 'easy_all apply' './easy_all install'; do
    assert_not_contains "Gcore guide excludes VPS marker ${vps_marker}" \
        "${GCORE_GUIDE_CONTENT}" "${vps_marker}"
done
aws_markdown_count=$(find "${ROOT_DIR}/docs" -maxdepth 1 -type f -name 'aws*.md' | wc -l | tr -d ' ')
[[ "${aws_markdown_count}" == "1" ]] || fail "AWS user guidance must stay in one Markdown file"
gcore_markdown_count=$(find "${ROOT_DIR}/docs" -maxdepth 1 -type f -name 'gcore*.md' | wc -l | tr -d ' ')
[[ "${gcore_markdown_count}" == "1" ]] || fail "Gcore user guidance must stay in one Markdown file"

for action in \
    'sts:GetCallerIdentity' \
    'route53:ListHostedZones' \
    'route53:ListResourceRecordSets' \
    'route53:ChangeResourceRecordSets' \
    'acm:ListCertificates' \
    'acm:RequestCertificate' \
    'acm:DescribeCertificate' \
    'cloudfront:ListDistributions' \
    'cloudfront:GetDistribution' \
    'cloudfront:GetDistributionConfig' \
    'cloudfront:CreateDistribution' \
    'cloudfront:UpdateDistribution' \
    'freetier:GetAccountPlanState' \
    'freetier:UpgradeAccountPlan' \
    'wafv2:ListWebACLs' \
    'wafv2:GetWebACL' \
    'wafv2:CreateWebACL' \
    'pricingplanmanager:ListSubscriptions' \
    'pricingplanmanager:GetSubscription' \
    'pricingplanmanager:CreateSubscription' \
    'pricingplanmanager:AssociateResourcesToSubscription'; do
    assert_contains "AWS guide permission ${action}" "${AWS_GUIDE_CONTENT}" "${action}"
done
assert_not_contains "AWS guide excludes unused Route 53 lookup" \
    "${AWS_GUIDE_CONTENT}" 'route53:ListHostedZonesByName'
assert_not_contains "AWS guide excludes unused Route 53 waiter" \
    "${AWS_GUIDE_CONTENT}" 'route53:GetChange'
assert_contains "AWS guide refuses paid flat-rate approval" \
    "${AWS_GUIDE_CONTENT}" '不能批准 Pro、Business 或 Premium'

printf 'ok - documentation alignment tests passed\n'
