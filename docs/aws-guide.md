# AWS 一次性准备指南

按本文顺序操作，可一次完成 AWS 账号确认、CloudFront Free 固定套餐费用边界、Route 53 DNS
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

## 2. 确认账号升级与 CloudFront Free 固定套餐

这里使用的是 **CloudFront flat-rate Free plan**，不是 AWS 注册时选择的 **Free account
plan**。CloudFront 固定套餐要求账号为 Paid account plan。脚本读取两项 Access Key 后会：

1. 查询当前 AWS account plan；已经是 Paid 时直接继续。
2. 检测到 Free 时说明计费边界并要求确认，然后通过官方 API 升级为 Paid，不要求你回到 AWS
   控制台操作。
3. 创建独占且默认放行的 WAF Web ACL，创建或更新 CloudFront 分配。
4. 为该分配订阅每月 **US$0** 的 CloudFront Free 固定套餐，并把 CDN 域名所属 Route 53
   Hosted Zone 加入套餐。
5. 把 CDN 域名写成 CloudFront Alias A/AAAA；Route 53 不对指向 CloudFront 的 Alias 查询收费。

正常通过 Upgrade Plan/API 升级不会清空剩余 Free Tier Credit；Credit 会继续用于符合条件的
后续账单直至原到期日。不要为了升级而加入 AWS Organizations 或启用 Control Tower，这两种
路径会使剩余 Free Tier Credit 立即失效。

CloudFront Free 固定套餐包含每月 **100 GB 数据传输**和 **100 万次请求**的基准用量，并且
没有突发流量或攻击带来的超额费；每个 AWS 账号最多可有三个 Free 固定套餐。套餐还覆盖与该
分配绑定的 WAF，以及已加入套餐的 Route 53 Hosted Zone 的标准 Hosted Zone、记录和查询费用。

套餐不覆盖 VPS、域名注册、未加入套餐的第二个 Hosted Zone、Route 53 DNSSEC 的 KMS、Health
Check、DNS Query Logs、Lambda@Edge 等额外功能。若源站域名和 CDN 域名位于同一个 Hosted
Zone，脚本加入一次即可同时覆盖；位于两个 Zone 时，脚本只加入 CDN 域名所在 Zone，另一个仍按
Route 53 标准价格计费。套餐生效前已经记入的费用也不应视为必然追溯减免。

AWS 官方参考：
[CloudFront 固定套餐](https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/flat-rate-pricing-plan.html)、
[Free 与 Paid account plan](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/free-tier-FAQ.html)、
[Route 53 指向 CloudFront](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/routing-to-cloudfront-distribution.html)。

## 3. 配置 Route 53 权威 DNS

这是 CDN XHTTP 的**必要条件**。源站域名和 CDN 域名必须属于已正确委派的
**Route 53 Public Hosted Zone**；Private Hosted Zone 不能用于公网解析。域名注册商不必迁入 AWS，
需要交给 AWS 的只是节点域名的权威 DNS 区域。

### 方式 A：整个主域名交给 Route 53

例如准备使用 `origin.example.com` 和 `node.example.com`：

1. 在 **Route 53 → Hosted zones → Create hosted zone** 输入 `example.com`，选择
   **Public hosted zone** 后创建。
2. 复制新 Zone 的 NS 记录中显示的四条名称服务器。
3. 在当前域名注册商的 Nameservers 页面，将现有名称服务器完整替换为这四条。
4. 等待委派生效后，再继续后续步骤。

### 方式 B：只委派专用子域名

已有网站或邮箱时推荐该方式。例如主域名 `example.com` 保持原 DNS，仅将
`edge.example.com` 委派到 Route 53：

1. 在 Route 53 创建 `edge.example.com` Public Hosted Zone。
2. 复制其 NS 记录中的四条名称服务器。
3. 在原 DNS 服务商的 `example.com` Zone 中创建名为 `edge` 的 NS 记录集，值为上一步的四条
   名称服务器。不要更换 `example.com` 在注册商处的名称服务器。
4. 后续使用 `origin.edge.example.com` 和 `node.edge.example.com`。

### 委派前检查

1. 整个主域名迁入前，先复制现有 A/AAAA/CNAME、MX/TXT、SPF、DKIM、DMARC 和 CAA
   记录。easy_all 只管理节点和证书记录，不会迁移既有业务记录。
2. 主域名已启用 DNSSEC 时，先移除旧 DNS 服务商对应的 DS 记录；Route 53 DNSSEC 和新 DS
   链完成后再重新启用。
3. 不要创建同名的多个 Public Hosted Zone；父 Zone 或注册商的 NS 必须指向实际保存记录的
   那一个 Zone。

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
