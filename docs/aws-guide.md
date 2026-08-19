# AWS 账户与 IAM 凭证准备

CDN XHTTP 安装时需要 AWS IAM 程序化访问凭证。本文只说明如何注册 AWS 全球商业区账号、创建
受限 IAM 用户，以及获取 `AWS_ACCESS_KEY_ID` 和 `AWS_SECRET_ACCESS_KEY`。

> 不要为 AWS 根用户创建访问密钥，也不要把任何密钥提交到 Git、写入脚本、截图或发送到聊天中。

## 1. 注册 AWS 全球商业区账号

本项目使用 AWS 全球商业区（`aws` 分区）的 CloudFront、Route 53 和 ACM，**不要注册或使用
AWS 中国区域账号（`aws-cn`）**。中国区域与全球商业区是独立分区，账号和 IAM 凭证不能互用。
这通常被称为“注册 AWS 海外区账号”，但不等于必须手工选择美国 Region；一个全球商业区账号可
使用多个商业区域，脚本会自行处理 CloudFront 和 ACM 所需的控制区域。

1. 打开 [AWS 全球商业区注册页](https://signin.aws.amazon.com/signup?request_type=register)，按页面完成邮箱、手机号、地址、支付方式和身份验证。
2. 注册需要一张可通过 AWS 验证的信用卡或借记卡。中国大陆用户建议准备已开通境外线上支付的
   双币或全币种信用卡；实际可用性仍取决于注册页面和发卡行授权结果。
3. 使用根用户首次登录后，立即在 **IAM → Dashboard** 为根用户启用多重验证（MFA）。
4. 根用户仅用于账户、账单和安全设置；日常部署使用下面创建的 IAM 用户。

AWS 官方参考：[全球与中国区域账号边界](https://docs.aws.amazon.com/global-infrastructure/latest/regions/aws-regions.html)、
[注册条件与信用卡要求](https://aws.amazon.com/cn/free/complete-signup/)、
[根用户安全最佳实践](https://docs.aws.amazon.com/IAM/latest/UserGuide/root-user-best-practices.html)。

## 2. CloudFront 免费额度与费用边界

CloudFront 按 AWS 账户汇总的永久免费额度为每月 **1 TB 向互联网传出的数据**，并包含每月
**1,000 万次 HTTP/HTTPS 请求**。该额度适用于 CloudFront 的全球边缘节点，不是每个分配、
每个域名或每个 Region 各有 1 TB；超出后按按量付费标准计费。

这 1 TB 仅是 CloudFront 的传出流量额度，**不代表整套部署一定零费用**：VPS、域名、Route 53
Hosted Zone、超额 CloudFront 流量或请求，以及其他未包含服务都可能产生费用。部署前请在
**Billing and Cost Management → Budgets** 创建预算和邮件告警。

中国区域与全球商业区的账户和计费独立；本项目使用全球商业区 CloudFront。CloudFront 中国
边缘节点的优惠和计费不应按本指南的 1 TB 额度推断。

AWS 官方参考：[CloudFront 免费额度与按量计费说明](https://aws.amazon.com/cloudfront/faqs/)、
[CloudFront 中文活动页](https://aws.amazon.com/cn/campaigns/goglobal-mall/access-acceleration-and-content-distribution/cloudfront/)。

## 3. 必做：为节点域名配置 Route 53 DNS

这是 CDN XHTTP 的**必要条件**。脚本会调用 Route 53 API 自动创建和更新源站 A、ACM 验证及
CloudFront CNAME 记录；因此，安装时填写的源站域名和 CDN 域名必须归属某个已正确委派的
**Route 53 Public Hosted Zone**。Private Hosted Zone 不能用于公网解析。

域名的**注册商不必迁入 AWS**：可以继续在原注册商续费。需要交给 AWS 的只是用于节点的权威 DNS
区域。根据现有业务选择以下一种方式。

### 方式 A：整个主域名交给 Route 53

适合没有现有网站或邮件业务的域名。例如安装时准备使用 `origin.example.com` 和
`node.example.com`：

1. 在 **Route 53 → Hosted zones → Create hosted zone** 输入 `example.com`，选择
   **Public hosted zone** 后创建。
2. 打开新 Zone 的 **NS** 记录，复制其中显示的四条 `ns-...awsdns-...` 名称服务器。
3. 在当前域名注册商的“Nameservers / DNS 服务器”页面，选择自定义名称服务器，**完整替换为这四条
   Route 53 名称服务器**。不要只在旧 DNS 服务商添加一条普通 NS 记录。
4. 等待委派生效后，再安装并填写上述两个子域名；脚本会自行写入它们的 A、CNAME 和证书验证记录。

### 方式 B：仅将专用子域名交给 Route 53（已有网站/邮箱时推荐）

这样不会改变主域名当前的网站和邮件解析。例如主域名 `example.com` 继续由原 DNS 服务商管理，而
节点专用 `edge.example.com` 由 Route 53 管理：

1. 在 Route 53 创建名称为 `edge.example.com` 的 **Public hosted zone**。
2. 记录其 **NS** 记录中的四条 Route 53 名称服务器。
3. 回到原 DNS 服务商的 `example.com` Zone，创建一条名称为 `edge`（完整域名
   `edge.example.com`）的 **NS 记录集**，值为上一步的四条名称服务器。它是对子域的委派，**不要**
   更换 `example.com` 在注册商处的名称服务器。
4. 安装时使用该 Zone 下的两个不同主机名，例如 `origin.edge.example.com` 与
   `node.edge.example.com`。

### 迁移前检查与验证

1. 若采用方式 A，先导出或记录现有 DNS；在切换名称服务器前，将网站所需的 A/AAAA/CNAME、邮件
   所需的 MX/TXT（包括 SPF、DKIM、DMARC）及 CAA 记录复制到 Route 53。脚本只管理自己使用的
   节点、证书记录，**不会迁移或补齐既有业务记录**。
2. 若主域名已启用 DNSSEC 且采用方式 A，先按注册商要求移除旧 DNS 服务商对应的 DS 记录；待
   Route 53 DNSSEC 签名和新的 DS 链配置完成后再重新启用。保留旧 DS 而直接换 NS 会导致解析校验
   失败。
3. 不要创建同名的多个 Public Hosted Zone；若已有多个，注册商或父 Zone 的 NS 必须指向实际保存
   记录的那一个 Zone。
4. 委派变更可能需要传播时间。以下命令中的 NS 应与目标 Route 53 Zone 的四条记录一致后，再运行
   安装器：

   ```bash
   dig +short NS edge.example.com
   dig +short NS edge.example.com @1.1.1.1
   ```

   采用方式 A 时，将上面的 `edge.example.com` 换成主域名。安装器创建源站 A 记录后，可再检查：

   ```bash
   dig +short A origin.edge.example.com @1.1.1.1
   ```

AWS 官方参考：[创建 Public Hosted Zone](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/CreatingHostedZone.html)、
[将既有域名的 DNS 迁入 Route 53](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/migrate-dns-domain-in-use.html)。

## 4. 创建最小权限策略

脚本会读取 Route 53 Hosted Zone、写入所选 Zone 的 DNS 记录、申请 ACM 证书并创建或更新
CloudFront 分配。先在 **Route 53 → Hosted zones** 复制将用于安装时两个域名的 Public Hosted
Zone ID。

在 **IAM → 访问管理 → 策略 → 创建策略 → JSON** 中粘贴以下策略。

> **创建前必须修改：不能直接原样提交下面的 JSON。** 使用编辑器搜索
> `REPLACE_WITH_YOUR_ROUTE53_HOSTED_ZONE_ID`，将它替换为 Route 53 控制台复制的实际 Hosted
> Zone ID。实际值通常以 `Z` 开头；不要填域名、完整 ARN 或 CloudFront ID。

策略名称建议填写 `easy_all_deploy_policy`：

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
      "Action": [
        "route53:ListHostedZones",
        "route53:ListHostedZonesByName",
        "route53:GetChange"
      ],
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

若两个域名位于不同的 Public Hosted Zone，将该策略中 `Route53HostedZoneRecords` 的 `Resource`
改为两个 ARN 的数组，并分别替换两个 `REPLACE_...` 占位符：

```json
"Resource": [
  "arn:aws:route53:::hostedzone/REPLACE_WITH_YOUR_FIRST_ROUTE53_HOSTED_ZONE_ID",
  "arn:aws:route53:::hostedzone/REPLACE_WITH_YOUR_SECOND_ROUTE53_HOSTED_ZONE_ID"
]
```

提交前检查 JSON 中不再出现 `REPLACE_`。例如正确的 ARN 结构为：

```text
arn:aws:route53:::hostedzone/Z0123456789ABCDEFGHI
```

该策略没有删除 CloudFront、ACM 或 Route 53 资源的权限。部分 AWS 的查询和创建操作无法限定到
尚不存在的资源，因此需要 `Resource: "*"`；DNS 写入权限仍限定在指定 Hosted Zone。

## 5. 创建 IAM 用户

1. 在 **IAM → 访问管理 → 用户组** 创建用户组，例如 `easy_all_deployers`。
2. 将 `easy_all_deploy_policy` 附加到该用户组。
3. 在 **IAM → 访问管理 → 用户** 创建用户，例如 `easy_all_deployer`。
4. 不要勾选 AWS 管理控制台访问权限；在“设置权限”中选择“添加用户到组”，并加入
   `easy_all_deployers`。

使用用户组可使权限来源和撤销操作更清晰，也避免把权限直接散落在个人用户上。

## 6. 获取 Access Key

1. 打开刚创建的 IAM 用户 → **安全凭证**。
2. 在“访问密钥”区域选择 **创建访问密钥**。
3. 用例选择 **命令行界面（CLI）**，确认并创建。
4. 立即复制或下载以下两项：

```text
AWS_ACCESS_KEY_ID
AWS_SECRET_ACCESS_KEY
```

`AWS_SECRET_ACCESS_KEY` 只会显示一次。若遗失，停用旧密钥后重新创建，不要尝试恢复或共享旧密钥。
安装器会在当前终端以不回显方式询问两项值，不会将它们写入 `/etc/easy_all/state.env`。

AWS 官方参考：[IAM 用户访问密钥](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_credentials_access-keys.html)。
