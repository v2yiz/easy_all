# AWS 一次性准备指南

按本文顺序操作，可一次完成 AWS 账号确认、CloudFront 两种计费模式的费用边界、Route 53 DNS
委派、IAM 最小权限和 Access Key 创建。安装时你只需要向脚本提供：

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

> 不要为 AWS 根用户创建访问密钥，也不要把任何密钥提交到 Git、写入脚本、
> 截图或发送到聊天中。

## 1. 账号前提

使用 AWS 全球商业区（`aws` 分区）账号，不要使用 AWS 中国区域账号（`aws-cn` 分区）。
两个分区的账号与 IAM 凭证不能互用。尚无账号时，先在
[AWS 全球商业区注册页](https://signin.aws.amazon.com/signup?request_type=register)
完成注册，并为根用户启用 MFA。

### AWS 控制区域：选择 `us-east-1`（美国·弗吉尼亚北部）

控制台右上角的区域请选择截图中的 **美国（弗吉尼亚北部）`us-east-1`**。本项目所有 AWS
控制面调用均固定使用该区域；尤其是 CloudFront 的自定义域名证书必须在这个区域申请或导入 ACM，
否则 CloudFront 无法关联它。

这不是节点的落地位置选择：Route 53 和 CloudFront 是全球服务，用户会由 CloudFront 的边缘站点接入，
再回源到你的 VPS。因此不要为了降低延迟改选东京、新加坡或其他区域；本项目没有创建 EC2 等区域型
AWS 计算资源，实际延迟主要取决于用户到 CloudFront 边缘的网络，以及边缘到 VPS 的回源链路。

AWS 官方参考：
[CloudFront 的 ACM 证书区域要求](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/cnames-and-https-requirements.html)、
[Route 53 的全球服务边界](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/disaster-recovery-resiliency.html)。

## 2. 确认账号升级与 CloudFront 计费模式

AWS 注册时选择的 **Free account plan** 与 CloudFront 计费方式不是一回事。脚本支持
**CloudFront flat-rate Free plan** 和 **CloudFront pay-as-you-go**，并在安装时让用户选择。
脚本读取两项 Access Key 后会：

1. 查询当前 AWS account plan；已经是 Paid 时直接继续。
2. 检测到 Free 时说明计费边界并要求确认，然后通过官方 API 升级为 Paid，不要求你回到 AWS
   控制台操作。
3. 选择 Free 固定套餐时，创建默认放行的独占 WAF、CloudFront 分配和每月 **US$0** 的固定
   套餐，并把 CDN 域名所属 Route 53 Hosted Zone 加入套餐。
4. 选择按量付费时，创建不关联 WAF 和固定套餐的 CloudFront 分配，使用按量付费永久免费额度，
   并在 VPS 上自动启用 `980 GB` 全局费用保护。
5. 把 CDN 域名写成 CloudFront Alias A；Route 53 不对直接指向 CloudFront 的 Alias 查询收费。

重要：AWS **升级为 Paid account plan 的动作本身不收费，也没有固定月费**；它不是购买
CloudFront 付费套餐。升级只是解除 Free account plan 的服务限制并开启标准按量计费。只要仍在
剩余 Free Tier Credit/适用免费额度内，通常不会产生 CloudFront 账单；超出 Credit/免费额度，或
使用不适用 credit 的资源时，AWS 仍会按标准价格计费。安装菜单中的 `2 按量付费` 是多数用户的默认推荐，
表示使用每月 1 TB + 1000 万请求免费额度，并由本机 980 GB 安全阀提前阻断节点流量；它不表示
升级瞬间就会扣费。

CloudFront 分配关闭 IPv6，安装器仅创建 Alias A，生成的 Mihomo 节点固定使用
`ip-version: ipv4`。CloudFront 到源站以及 VPS 到目标网站也全部固定为 IPv4。

正常通过 Upgrade Plan/API 升级不会清空剩余 Free Tier Credit；Credit 会继续用于符合条件的
后续账单直至原到期日。不要为了升级而加入 AWS Organizations 或启用 Control Tower，这两种
路径会使剩余 Free Tier Credit 立即失效。

两种模式的月度估算如下；这也是安装菜单显示的计费边界：

| 模式 | CloudFront 额度及超出估算 | Route 53 与 WAF 估算 |
| --- | --- | --- |
| Free 固定套餐 | `$0/月`，基准 **100 GB + 100 万次请求**。超过基准仍无超额费，因此超出费用估算仍为 `$0`；若长期明显超额，AWS 可能调整边缘交付性能。 | 套餐覆盖对应 WAF，以及加入套餐的 CDN Hosted Zone、记录和额度内查询。源站若位于另一个 Hosted Zone，该 Zone 另约 `$0.50/月 + $0.40/百万次标准查询`。 |
| 按量付费（脚本默认） | 每月免费 **1 TB + 1000 万次请求**。脚本按 UTC 自然月累计 Xray 上下行总流量并在 **980 GB** 阻断；超过 1 TB 后按边缘区域计价，每多 100 GB 约 `$8.50-$12.00`，超额请求另计。 | 不创建 WAF。每个 Public Hosted Zone 约 `$0.50/月`；CloudFront Alias A 查询免费，其他标准 DNS 查询约 `$0.04/10万次`、`$0.40/百万次`。一个 Zone 通常约 `$0.50/月`，两个 Zone 约 `$1.00/月`，再加少量普通查询费。 |

固定套餐不能与按量付费的 1 TB 免费额度叠加。Free 固定套餐每个 AWS 账号最多可有三个；其
基准额度不是硬性断流上限，但不适合作为长期 1 TB 性能保证。按量付费模式不创建 WAF，因为
WAF 在该模式下会产生独立的 Web ACL 和请求费用。

按量付费保护只使用 VPS 本机 Xray 统计，不需要保存 AWS Access Key。它独立于每用户配额，
按 UTC 每月 1 日 `00:00` 重置，并以 15 秒周期检查。该数值不等同于 CloudFront 精确账单，不能
统计未到达 Xray 的请求及协议开销，因此 20 GB 是安全缓冲而不是 AWS 侧硬上限。

Free 固定套餐不覆盖 VPS、域名注册、未加入套餐的第二个 Hosted Zone、Route 53 DNSSEC 的 KMS、Health
Check、DNS Query Logs、Lambda@Edge 等额外功能。若源站域名和 CDN 域名位于同一个 Hosted
Zone，脚本加入一次即可同时覆盖；位于两个 Zone 时，脚本只加入 CDN 域名所在 Zone，另一个仍按
Route 53 标准价格计费。套餐生效前已经记入的费用也不应视为必然追溯减免。

AWS 官方参考：
[CloudFront 固定套餐](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html)、
[CloudFront 按量付费与永久免费额度](https://aws.amazon.com/cloudfront/faqs/)、
[Route 53 定价](https://aws.amazon.com/route53/pricing/)、
[Free 与 Paid account plan](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-FAQ.html)、
[Route 53 指向 CloudFront](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-to-cloudfront-distribution.html)。

## 3. 配置 Route 53 权威 DNS

这是 CDN XHTTP 的**必要条件**。源站域名和 CDN 域名必须属于已正确委派的
**Route 53 Public Hosted Zone**；Private Hosted Zone 不能用于公网解析。域名注册商不必迁入 AWS，
需要交给 AWS 的是整个主域名的权威 DNS 区域。本指南只保留这一种流程，避免同时维护多个
委派方案。

完成上述委派后，不需要手动创建 `origin` 的 A 记录、ACM 验证记录或 `node` 的
CloudFront Alias A：安装脚本会自动写入该节点记录。脚本不会替你创建 Hosted Zone、修改
注册商的 NS，或接管已有 DNS 记录；这一步仍需在 AWS 和当前 DNS 服务商处完成。

例如准备使用 `origin.example.com` 和 `node.example.com`，统一将 `example.com` 交给 Route 53：

1. 在 **Route 53 → Hosted zones → Create hosted zone** 输入 `example.com`，选择
   **Public hosted zone** 后创建。
2. 复制新 Zone 的 NS 记录中显示的四条名称服务器。
3. 在当前域名注册商的 Nameservers 页面，将现有名称服务器完整替换为这四条。
4. 等待委派生效后，再继续后续步骤。

### 委派前检查

1. 整个主域名迁入前，先复制现有 A/AAAA/CNAME、MX/TXT、SPF、DKIM、DMARC 和 CAA
   记录。easy_all 只管理节点和证书记录，不会迁移既有业务记录。
2. 主域名已启用 DNSSEC 时，先移除旧 DNS 服务商对应的 DS 记录；Route 53 DNSSEC 和新 DS
   链完成后再重新启用。
3. 不要创建同名的多个 Public Hosted Zone；注册商的 NS 必须指向实际保存记录的那一个 Zone。

AWS 官方参考：
[Route 53 Public Hosted Zone](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingHostedZone.html)、
[DNS 迁移到 Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/migrate-dns-domain-in-use.html)。

## 4. 创建最小权限策略

先在 **Route 53 → Hosted zones** 复制源站域名和 CDN 域名所属 Public Hosted Zone
的 Zone ID。

在 **IAM → 访问管理 → 策略 → 创建策略 → JSON** 中粘贴以下策略。将
`REPLACE_WITH_YOUR_ROUTE53_HOSTED_ZONE_ID` 替换为实际 Zone ID；不要填域名、完整 ARN
或 CloudFront ID。策略名称建议使用 `easy_all_deploy_policy`。

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IdentityCheck",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    },
    {
      "Sid": "UpgradeAccountPlanForCloudFrontFreePlan",
      "Effect": "Allow",
      "Action": [
        "freetier:GetAccountPlanState",
        "freetier:UpgradeAccountPlan"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DiscoverRoute53",
      "Effect": "Allow",
      "Action": "route53:ListHostedZones",
      "Resource": "*"
    },
    {
      "Sid": "Route53HostedZoneRecords",
      "Effect": "Allow",
      "Action": [
        "route53:ListResourceRecordSets",
        "route53:ChangeResourceRecordSets"
      ],
      "Resource": "arn:aws:route53:::hostedzone/REPLACE_WITH_YOUR_ROUTE53_HOSTED_ZONE_ID"
    },
    {
      "Sid": "ManageViewerCertificate",
      "Effect": "Allow",
      "Action": [
        "acm:ListCertificates",
        "acm:RequestCertificate",
        "acm:DescribeCertificate"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFrontDistribution",
      "Effect": "Allow",
      "Action": [
        "cloudfront:ListDistributions",
        "cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig",
        "cloudfront:CreateDistribution",
        "cloudfront:UpdateDistribution"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFrontDedicatedWebACL",
      "Effect": "Allow",
      "Action": [
        "wafv2:ListWebACLs",
        "wafv2:GetWebACL",
        "wafv2:CreateWebACL"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFrontFreeFlatRatePlan",
      "Effect": "Allow",
      "Action": [
        "pricingplanmanager:ListSubscriptions",
        "pricingplanmanager:GetSubscription",
        "pricingplanmanager:CreateSubscription",
        "pricingplanmanager:AssociateResourcesToSubscription"
      ],
      "Resource": "*"
    }
  ]
}
```

若两个域名位于不同的 Public Hosted Zone，将 `Route53HostedZoneRecords` 的
`Resource` 改为两个 ARN：

```json
"Resource": [
  "arn:aws:route53:::hostedzone/REPLACE_WITH_YOUR_FIRST_ROUTE53_HOSTED_ZONE_ID",
  "arn:aws:route53:::hostedzone/REPLACE_WITH_YOUR_SECOND_ROUTE53_HOSTED_ZONE_ID"
]
```

提交前检查 JSON 中不再出现 `REPLACE_`。该策略没有删除 CloudFront、WAF、ACM、固定套餐或
Route 53 资源的权限；DNS 写入权限仅限定在指定 Hosted Zone。策略也故意不授予
`pricingplanmanager:ApprovePaidSubscription`，脚本只能激活免费的 CloudFront `FREE` 套餐，
不能批准 Pro、Business 或 Premium 的付费套餐。

## 5. 创建 IAM 用户

1. 在 **IAM → 访问管理 → 用户组** 创建用户组，例如 `easy_all_deployers`。
2. 将 `easy_all_deploy_policy` 附加到该用户组。
3. 在 **IAM → 访问管理 → 用户** 创建用户，例如 `easy_all_deployer`。
4. 不要启用 AWS 管理控制台访问；在“设置权限”中选择“添加用户到组”，并加入
   `easy_all_deployers`。

## 6. 创建 Access Key

1. 打开刚创建的 IAM 用户 → **安全凭证**。
2. 在“访问密钥”区域选择 **创建访问密钥**。
3. 用例选择 **命令行界面（CLI）**，确认并创建。
4. 立即复制或下载以下两项：

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

`AWS_SECRET_ACCESS_KEY` 只会显示一次。若遗失，应停用旧密钥后重新创建，不要尝试恢复或
共享旧密钥。两项凭证应分别保存在受保护的密码管理器中。

AWS 官方参考：
[IAM 用户访问密钥](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)。
