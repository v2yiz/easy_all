#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
README_CONTENT=$(<"${ROOT_DIR}/README.md")
AWS_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/aws-guide.md")
PREPARATION_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/preparation-guide.md")
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
XHTTP_CONTENT=$(<"${ROOT_DIR}/profiles/xhttp-aws.sh")
GCORE_CONTENT=$(<"${ROOT_DIR}/profiles/websocket-gcore.sh")

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
        | sed -n 's/^[[:space:]]*"\(\(lib\|profiles\)\/[^\"]*\)"/\1/p'
)

for command in show subscription self-update apply apply-cloud update-sub \
    refresh-cdn-ips update-core \
    renew-cert quota-status quota-set quota-reset status uninstall help; do
    assert_contains "README public command ${command}" "${README_CONTENT}" "| \`${command}"
done

assert_contains "README Reality stage count" "${README_CONTENT}" \
    '保存最终状态 / 注册 easy_all / 配置配额任务'
assert_contains "README XHTTP stage count" "${README_CONTENT}" \
    '源站证书 / Xray / Nginx / 本机运行时验收'
assert_contains "README documents the third optimized AWS installation mode" \
    "${README_CONTENT}" 'AWS CDN 精选 IP - XHTTP'
assert_contains "README documents four installation modes" "${README_CONTENT}" \
    '四种安装模式'
assert_contains "README documents Gcore WebSocket mode" "${README_CONTENT}" \
    'Gcore CDN 精选 IP - WebSocket'
assert_not_contains "README does not list a separate Gcore guide" "${README_CONTENT}" \
    'docs/gcore-guide.md'
assert_contains "Preparation guide documents official Gcore WebSocket" "${PREPARATION_GUIDE_CONTENT}" \
    'VLESS + WebSocket + TLS'
assert_contains "Preparation guide embeds the Gcore API token screenshot" "${PREPARATION_GUIDE_CONTENT}" \
    'gcore/gcore-api-token-create.png'
assert_contains "Preparation guide documents the balanced Gcore heartbeat" "${PREPARATION_GUIDE_CONTENT}" \
    '`heartbeatPeriod` | `55` 秒'
assert_contains "Preparation guide documents Gcore early data" "${PREPARATION_GUIDE_CONTENT}" \
    'Early Data | `2560`'
assert_contains "Preparation guide documents Gcore HTTP 1.1 ALPN" "${PREPARATION_GUIDE_CONTENT}" \
    'ALPN | `http/1.1`'
assert_contains "Preparation guide documents Gcore Origin SSL Validation" "${PREPARATION_GUIDE_CONTENT}" \
    'Origin SSL Validation 与 mTLS'
assert_contains "Preparation guide documents the Gcore Managed DNS console path" \
    "${PREPARATION_GUIDE_CONTENT}" '网络 → Managed DNS → 所有区域 → 添加区域'
assert_contains "Preparation guide documents Gcore zone creation stages" \
    "${PREPARATION_GUIDE_CONTENT}" '输入域 → 正在扫描记录 → 检查记录 → 更改域名服务器'
assert_contains "Preparation guide tells users to scan Gcore DNS records" \
    "${PREPARATION_GUIDE_CONTENT}" 'Skip scanning'
assert_contains "Preparation guide requires complete Gcore NS replacement" \
    "${PREPARATION_GUIDE_CONTENT}" '完整替换当前 NS'
assert_contains "Preparation guide documents the Gcore pre-provisioning delegation check" \
    "${PREPARATION_GUIDE_CONTENT}" '第 4/9 步、创建源站 A 记录之前'
assert_contains "Preparation guide documents Gcore delegation success criteria" \
    "${PREPARATION_GUIDE_CONTENT}" '`zone_exists=true`'
assert_contains "Preparation guide documents public resolver NS verification" \
    "${PREPARATION_GUIDE_CONTENT}" 'dig @1.1.1.1 NS 1988088.xyz +short'
assert_contains "Preparation guide documents DNS delegation tracing" \
    "${PREPARATION_GUIDE_CONTENT}" 'dig +trace NS 1988088.xyz'
assert_contains "Preparation guide verifies public DNSSEC resolution after Gcore delegation" \
    "${PREPARATION_GUIDE_CONTENT}" 'dig @1.1.1.1 SOA 1988088.xyz +dnssec'
assert_contains "Preparation guide prevents stale DNSSEC DS records during Gcore migration" \
    "${PREPARATION_GUIDE_CONTENT}" '删除旧的 `DS` 记录'
assert_contains "Preparation guide documents DNSSEC DS self-check" \
    "${PREPARATION_GUIDE_CONTENT}" 'dig DS example.com +short'
assert_contains "Gcore profile never persists its API token" "${GCORE_CONTENT}" \
    'unset GCORE_API_TOKEN'
assert_contains "README documents the CDN cost boundary" "${README_CONTENT}" \
    '只有非优化线路才推荐使用 CDN'
assert_contains "README documents free Cloudflare and Gcore modes" "${README_CONTENT}" \
    'Cloudflare Free 和 Gcore Free'
assert_contains "README documents the typical AWS monthly cost" "${README_CONTENT}" \
    '常规预期约 `$0.60/月`'
assert_contains "README links the preparation guide" "${README_CONTENT}" \
    'docs/preparation-guide.md'
assert_contains "Preparation guide has the expected title" \
    "${PREPARATION_GUIDE_CONTENT}" '# 前置准备手册'
assert_contains "Preparation guide has a per-route checklist" \
    "${PREPARATION_GUIDE_CONTENT}" '## 0. 按链路选择准备内容'
for mode in '模式 1：Reality 直连' '模式 2：Cloudflare XHTTP' \
    '模式 3：AWS CloudFront XHTTP' '模式 4：Gcore WebSocket'; do
    assert_contains "Preparation guide documents prerequisites for ${mode}" \
        "${PREPARATION_GUIDE_CONTENT}" "${mode}"
done
assert_contains "Preparation guide explains exclusive DNS delegation" \
    "${PREPARATION_GUIDE_CONTENT}" '不能同时托管同一个 Zone'
assert_contains "Preparation guide documents domain registration" \
    "${PREPARATION_GUIDE_CONTENT}" 'https://www.spaceship.com/'
assert_contains "Preparation guide recommends the Spaceship 1-plus-9-year plan" \
    "${PREPARATION_GUIDE_CONTENT}" '先注册 **1 年**，再续费 **9 年**'
assert_contains "Preparation guide documents Cloudflare sign-up" \
    "${PREPARATION_GUIDE_CONTENT}" 'https://dash.cloudflare.com/sign-up'
assert_contains "Preparation guide embeds the registrar Nameservers illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'preparation/spaceship-nameservers.png'
assert_contains "Preparation guide embeds the Cloudflare gRPC illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'preparation/cloudflare-grpc.svg'
assert_contains "Preparation guide documents Globalping GitHub sign-in" \
    "${PREPARATION_GUIDE_CONTENT}" 'Sign in with GitHub'
assert_contains "Preparation guide documents the Globalping token page" \
    "${PREPARATION_GUIDE_CONTENT}" 'https://dash.globalping.io/tokens'
assert_contains "README documents root-only Globalping token storage" \
    "${README_CONTENT}" '/etc/easy_all/globalping.token'
assert_contains "README documents the hourly Globalping refresh" \
    "${README_CONTENT}" '每小时'
assert_contains "README documents the 72-hour Globalping fallback" \
    "${README_CONTENT}" '超过 72 小时'
assert_contains "README links the renamed preparation guide" "${README_CONTENT}" \
    'docs/preparation-guide.md'
assert_contains "Preparation guide documents the optimized XHTTP mode" \
    "${PREPARATION_GUIDE_CONTENT}" 'Cloudflare CDN 精选 IP XHTTP'
assert_contains "Preparation guide requires one first-level hostname" \
    "${PREPARATION_GUIDE_CONTENT}" '一级子域名'
assert_contains "Preparation guide requires an active Zone" \
    "${PREPARATION_GUIDE_CONTENT}" '**Active**'
assert_contains "Preparation guide documents proxied A automation" \
    "${PREPARATION_GUIDE_CONTENT}" '创建唯一的 proxied `A` 记录'
assert_contains "Preparation guide documents automatic Origin CA" \
    "${PREPARATION_GUIDE_CONTENT}" '签发 15 年 Origin CA 证书'
assert_contains "Preparation guide documents one-stop Origin CA rotation" \
    "${PREPARATION_GUIDE_CONTENT}" '轮换和吊销 Origin CA 证书'
assert_contains "Preparation guide identifies the Origin CA certificate" \
    "${PREPARATION_GUIDE_CONTENT}" 'Origin CA 证书'
assert_contains "Preparation guide documents host-scoped strict TLS" \
    "${PREPARATION_GUIDE_CONTENT}" '配置 Full (strict)'
assert_contains "Preparation guide documents automatic origin HTTP/2" \
    "${PREPARATION_GUIDE_CONTENT}" '开启 origin HTTP/2'
assert_contains "Preparation guide documents the manual gRPC toggle" \
    "${PREPARATION_GUIDE_CONTENT}" 'Network → gRPC'
assert_contains "Preparation guide makes the gRPC toggle a prerequisite" \
    "${PREPARATION_GUIDE_CONTENT}" '必需条件'
assert_contains "Preparation guide documents automatic gRPC verification" \
    "${PREPARATION_GUIDE_CONTENT}" '会主动发送 gRPC 形态的边缘请求检查该开关'
assert_contains "Preparation guide documents automatic Transform Rule" \
    "${PREPARATION_GUIDE_CONTENT}" 'Transform Rule'
assert_contains "Preparation guide documents origin firewall boundary" \
    "${PREPARATION_GUIDE_CONTENT}" 'Cloudflare 官方 IPv4 段访问 VPS 的 TCP 443'
assert_contains "Preparation guide token grants Zone read" \
    "${PREPARATION_GUIDE_CONTENT}" '`Zone / Zone / Read`'
assert_contains "Preparation guide token grants DNS edit" \
    "${PREPARATION_GUIDE_CONTENT}" '`Zone / DNS / Edit`'
assert_contains "Preparation guide token grants Transform Rules edit" \
    "${PREPARATION_GUIDE_CONTENT}" '`Zone / Transform Rules / Edit`'
assert_contains "Preparation guide token grants Config Rules edit" \
    "${PREPARATION_GUIDE_CONTENT}" '`Zone / Config Rules / Edit`'
assert_contains "Preparation guide token grants Zone Settings edit" \
    "${PREPARATION_GUIDE_CONTENT}" '`Zone / Zone Settings / Edit`'
assert_contains "Preparation guide token grants SSL and Certificates edit" \
    "${PREPARATION_GUIDE_CONTENT}" '`Zone / SSL and Certificates / Edit`'
assert_contains "Preparation guide embeds the API token walkthrough" \
    "${PREPARATION_GUIDE_CONTENT}" 'cloudflare/cloudflare-api-token-easy-all.svg'
[[ -s "${ROOT_DIR}/docs/cloudflare/cloudflare-api-token-easy-all.svg" ]] \
    || fail "Cloudflare API token walkthrough asset is missing"
assert_contains "Preparation guide documents Globalping fallback" \
    "${PREPARATION_GUIDE_CONTENT}" '超过 72 小时'
assert_contains "Preparation guide documents the official IPv4 pool" \
    "${PREPARATION_GUIDE_CONTENT}" 'Cloudflare 官方 IPv4 CIDR'
assert_contains "Preparation guide documents carrier-specific eyeball probes" \
    "${PREPARATION_GUIDE_CONTENT}" '`AS4134`、中国联通 `AS4837`、中国移动 `AS9808`'
assert_contains "Preparation guide keeps the hostname fallback" \
    "${PREPARATION_GUIDE_CONTENT}" '原始域名兜底节点'
assert_contains "Preparation guide documents ten candidates per carrier" \
    "${PREPARATION_GUIDE_CONTENT}" '每个运营商先按 RTT 取前 10'
assert_contains "Preparation guide documents its longer client test interval" \
    "${PREPARATION_GUIDE_CONTENT}" '每 600 秒测速'
assert_contains "Preparation guide documents the 100 MB request boundary" \
    "${PREPARATION_GUIDE_CONTENT}" '**100 MB**'
assert_not_contains "Preparation guide does not instruct manual proxied record creation" \
    "${PREPARATION_GUIDE_CONTENT}" '在 **DNS → Records** 创建'
for aws_asset in \
    aws-architecture.svg \
    aws-cloudfront-settings.svg \
    aws-iam-policy.svg \
    aws-iam-access-key.svg; do
    assert_contains "AWS guide references ${aws_asset}" \
        "${AWS_GUIDE_CONTENT}" "aws/${aws_asset}"
    [[ -s "${ROOT_DIR}/docs/aws/${aws_asset}" ]] \
        || fail "AWS guide asset is missing: ${aws_asset}"
done
assert_contains "README documents the generic CDN traffic guard module" "${README_CONTENT}" \
    'cdn-traffic-guard.sh'
assert_contains "README documents the provider-neutral traffic guard service" "${README_CONTENT}" \
    'easy_all-cdn-traffic-guard.service'
assert_contains "README documents merged Profile helpers" "${README_CONTENT}" \
    'profile-common.sh'
assert_contains "README documents merged scheduled maintenance" "${README_CONTENT}" \
    'scheduled-maintenance.sh'
assert_contains "README dynamic ports describe NAT" "${README_CONTENT}" \
    'UFW 的 `before.rules` 受管 NAT 区块'
assert_contains "README dynamic ports reject per-port allows" "${README_CONTENT}" \
    '不会生成数万条'
assert_contains "README documents the IPv4 CDN client default" "${README_CONTENT}" \
    '`ip-version: ipv4`'
assert_contains "AWS guide documents the IPv4 CDN client default" "${AWS_GUIDE_CONTENT}" \
    '`ip-version: ipv4`'
assert_contains "README documents the automatic Reality endpoint family" "${README_CONTENT}" \
    'VPS 公网 IPv6 与节点域名 AAAA 完整匹配时使用 `dual`'
assert_contains "README documents Reality target TLS validation" "${README_CONTENT}" \
    '带 SNI 的 TLS 1.3 握手验收'
assert_contains "README documents Reality private destination blocking" "${README_CONTENT}" \
    '避免订阅凭据泄露后被用于访问 VPS 内网或云元数据'
assert_contains "README documents dual-stack egress with fixed Gemini IPv4" "${README_CONTENT}" \
    '静态资源使用的 Google 域名保留独立的 `ForceIPv4` 出站'
assert_contains "README documents bilingual interactive prompts" "${README_CONTENT}" \
    '所有需要用户输入的交互提示都会先显示中文，再在下一行显示英文'
assert_contains "README documents the unified CDN XMUX configuration" "${README_CONTENT}" \
    '`maxConnections: 4`'
assert_contains "README documents client connection racing" "${README_CONTENT}" \
    '内置 Mihomo 模板启用 `tcp-concurrent`'
assert_contains "README documents idle slow-start tuning" "${README_CONTENT}" \
    '`tcp_slow_start_after_idle`'
assert_contains "README distinguishes TCP keepalive from XHTTP keepalive" "${README_CONTENT}" \
    '不能替代 XHTTP'
assert_contains "README documents Xray inbound TCP keepalive" "${README_CONTENT}" \
    '四种 Xray 入站'
assert_contains "README documents the managed ephemeral port range" "${README_CONTENT}" \
    '`13000-60999`'
assert_contains "README documents XanMod LTS BBRv3 for every profile" \
    "${README_CONTENT}" '四种模式统一安装 XanMod LTS 内核'
assert_contains "README distinguishes the BBR algorithm from the sysctl name" \
    "${README_CONTENT}" '不能仅凭该名称把 Debian 官方内核的 BBRv1 当成 BBRv3'
assert_contains "README documents the BBRv3 reboot boundary" "${README_CONTENT}" \
    '`BBRv3: active`'
assert_contains "README clarifies that the AWS account-plan upgrade itself is free" \
    "${README_CONTENT}" '这个升级动作本身没有固定费用'
assert_contains "AWS guide clarifies the account-plan upgrade boundary" \
    "${AWS_GUIDE_CONTENT}" '升级为 Paid account plan 的动作本身不收费'
assert_contains "README keeps the independent Debian initializer out of proxy chains" \
    "${README_CONTENT}" '`scripts/debian-init.sh` 是独立的个人服务器初始化工具'
assert_contains "README documents the Debian initializer implementation path" \
    "${README_CONTENT}" 'scripts/debian-init.sh'
assert_contains "README update-sub includes Xray" "${README_CONTENT}" \
    '同步重建本机 Xray、Nginx 和订阅文件'
assert_contains "XHTTP command message includes Xray" "${XHTTP_CONTENT}" \
    'update-sub 会更新本机 Xray、订阅与 Nginx'

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
    "${AWS_GUIDE_CONTENT}" '安装脚本会自动写入该节点记录'
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
aws_markdown_count=$(find "${ROOT_DIR}/docs" -maxdepth 1 -type f -name 'aws*.md' | wc -l | tr -d ' ')
[[ "${aws_markdown_count}" == "1" ]] || fail "AWS user guidance must stay in one Markdown file"

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
