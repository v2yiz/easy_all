# AWS 一次性准备指南

按本文顺序操作，可一次完成 AWS 账号确认、CloudFront 费用边界、Route 53 DNS 委派、
IAM 最小权限和 Access Key 创建，最终取得：

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

## 2. 确认 CloudFront 费用边界

CloudFront 按 AWS 账户汇总的免费额度为每月 **1 TB 向互联网传出的数据**，并包含每月
**1,000 万次 HTTP/HTTPS 请求**。该额度按账户汇总，不是每个分配、域名或 Region 分别计算。

这不代表整套部署一定零费用：服务器、域名、Route 53 Hosted Zone、超额 CloudFront
流量或请求仍可能产生费用。建议在 **Billing and Cost Management → Budgets** 创建预算和
邮件告警。

AWS 官方参考：[CloudFront 免费额度与按量计费](https://aws.amazon.com/cloudfront/faqs/)。

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

提交前检查 JSON 中不再出现 `REPLACE_`。该策略没有删除 CloudFront、ACM 或 Route 53
资源的权限；DNS 写入权限仅限定在指定 Hosted Zone。

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
