# 前置准备手册

本手册介绍部署 `easy_all` 所需准备的云端凭据：**Cloudflare API Token**（所有模式）与 **AWS 访问密钥**（仅模式 2 纯 CloudFront 与模式 4 AnyTLS + CloudFront）。模式 5（AnyTLS + CloudFlare）只需要 Cloudflare API Token。

---

## 1. Cloudflare API Token 准备（全模式）

部署时需提供已托管目标域名的 Cloudflare API Token，用于自动化 DNS 解析、SSL 证书签发与回源规则配置。

### 1.1 权限需求（按模式划分）

创建 Token 时请遵循最小权限原则，仅授予目标 Zone（`Specific zone`）所需的权限：

| 权限分类与项目 | 模式 1 `link` | 模式 1 `deploy` | 模式 2 / 4 | 模式 3 | 模式 5 | 作用说明 |
| :--- | :---: | :---: | :---: | :---: | :---: | :--- |
| **DNS & Zones** → `Zone / Zone / Read` | ✔ | ✔ | ✔ | ✔ | ✔ | 读取并确认目标 Zone 状态与 ID |
| **DNS & Zones** → `DNS / Zone / Edit` | ✔ | ✔ | ✔ | ✔ | ✔ | 自动管理 A、CNAME 及 ACM/Certbot 验证记录 |
| **DNS & Zones** → `Zone Settings / Zone / Read` | - | ✔ | - | ✔ | ✔ | 校验 Zone SSL/TLS 是否为 `Full (strict)` |
| **Rules & Configuration** → `Origin Rules / Zone / Edit` | - | ✔ | - | - | ✔ | 维护订阅（模式 5 为节点与订阅）回源 8443 的 Origin Rule |
| **Cache & Performance** → `SSL and Certificates / Zone / Edit` | - | - | - | ✔ | - | 申请与管理 Cloudflare Origin CA 证书 |

> [!NOTE]
> - **模式 2 / 4** 的边缘 TLS 由 AWS ACM 托管，Cloudflare 仅作权威 DNS，因此**只需 Zone Read 与 DNS Edit**，切勿授予额外权限。
> - **模式 5** 不需要 Origin CA 权限：回源与直连共用 Let's Encrypt 证书（DNS-01），但需要 Origin Rules Edit 把橙云节点域名回源到 8443。
> - Token 在安装时输入，会以 `0600` 权限保存于 VPS `/etc/easy_all/cloudflare.token`，Certbot DNS-01 凭据保存于 `/etc/easy_all/cloudflare.ini`。

### 1.2 控制台创建步骤

1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，点击右上角头像 → **My Profile** → **API Tokens**。
2. 点击 **Create Token**。
3. 选择 **Start from scratch** → 点击 **Start with a Zone policy**。
4. **Scope 配置**：
   - **Rule action**：`Include`
   - **Resource type**：`Specific zone`
   - 选择本次部署使用的域名 Zone（切勿选 `All zones`）。
5. **Permissions 配置**：展开分类或使用搜索框，按上表勾选所选模式所需的权限项。
6. 点击 **Continue to summary** 核对无误后创建，复制并妥善保存生成的 Token。

![Cloudflare Token Zone policy 配置示意图](img/cloudflare/cloudflare-api-token-easy-all.svg)

---

## 2. AWS 凭证准备（仅模式 2 / 模式 4）

模式 2（纯 CloudFront）与模式 4（AnyTLS + CloudFront）需要利用 AWS CloudFront CDN 分发与 AWS Certificate Manager (ACM) 证书。模式 1、模式 3 与模式 5 无需 AWS 凭据。

### 2.1 账号与区域要求

- **全球商业区账号**：使用 AWS 全球标准账号（`aws` 分区），不支持 AWS 中国区（`aws-cn` 分区）。
- **控制区域**：CloudFront 的自定义域名证书必须位于 **美国东部（弗吉尼亚北部）`us-east-1`** 区域，脚本固定在此区域调用 ACM 申请与校验。
- **新账号需先开通 CloudFront 生产访问**：2021 年 12 月后注册的 AWS 账号需通过人工账号验证才能创建 CloudFront 资源，否则模式 2 / 4 安装会在「配置 CloudFront 分发」一步失败；处理步骤见 §2.5。

### 2.2 创建最小权限 IAM 策略

1. 登录 AWS 控制台，进入 **IAM** 服务。
2. 左侧菜单点击 **Policies（策略）** → **Create policy（创建策略）**。
3. 切换至 **JSON** 标签页，清空原有内容并粘贴以下策略：

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ACMCertificateManagement",
      "Effect": "Allow",
      "Action": [
        "acm:RequestCertificate",
        "acm:DescribeCertificate",
        "acm:AddTagsToCertificate",
        "acm:ListCertificates",
        "acm:ListTagsForCertificate",
        "acm:DeleteCertificate"
      ],
      "Resource": "*",
      "Condition": {
        "StringEquals": {
          "aws:RequestedRegion": "us-east-1"
        }
      }
    },
    {
      "Sid": "CallerIdentity",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudFrontDistributionManagement",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateDistribution",
        "cloudfront:GetDistribution",
        "cloudfront:GetDistributionConfig",
        "cloudfront:UpdateDistribution",
        "cloudfront:ListDistributions",
        "cloudfront:DeleteDistribution"
      ],
      "Resource": "*"
    }
  ]
}
```

4. 点击 **Next**，策略命名为 `EasyAllCloudFrontPolicy`，点击 **Create policy** 完成创建。

> [!NOTE]
> 该策略仅包含 ACM 证书和 CloudFront 分发的必要操作，不包含 Route 53、WAF 或其他额外服务的权限。

### 2.3 创建专用 IAM 用户并生成 Access Key

1. 在 IAM 左侧菜单点击 **Users（用户）** → **Create user（创建用户）**。
2. 用户名填写 `easy_all-cloudfront-deployer`，**切勿勾选**“提供 AWS 管理控制台访问权限”（保持纯 API 用户）。
3. 权限选项选择 **Attach policies directly（直接附加策略）**，搜索并勾选刚刚创建的 `EasyAllCloudFrontPolicy`。
4. 点击 **Next** 并完成创建。
5. 进入该用户详情页，切换到 **Security credentials（安全凭证）** 标签页。
6. 在 **Access keys（访问密钥）** 区域点击 **Create access key**，使用场景选择 **Command Line Interface (CLI)**。
7. 勾选确认项后创建，当场复制并保存：
   - **Access Key ID**
   - **Secret Access Key**（仅此一次可见）

### 2.4 凭据安全与计费说明

- **仅内存使用，不落盘**：安装交互时输入的 AWS Access Key 仅存于安装进程内存中，用于云端资源编排，不写入磁盘、`state.env`、日志或订阅文件。也可预先通过环境变量 `AWS_ACCESS_KEY_ID` 和 `AWS_SECRET_ACCESS_KEY` 传入。
- **流量保护机制**：CloudFront 免费套餐一般提供每月 1 TB 出站流量及 1000 万次 HTTP/HTTPS 请求（以 AWS 账号当前条款为准）。`easy_all` 本机内置 985 GB 近似计量保护，达到阈值后自动阻断 CDN 入口以降低超额风险。

### 2.5 开通 CloudFront 生产访问（新账号首次部署模式 2 / 模式 4）

2021 年 12 月起，新注册的 AWS 账号需先通过 AWS 人工账号验证，才能创建 CloudFront 资源；未完成验证时安装会在「检查并申请 AWS ACM 证书」之后、「配置 CloudFront 分发」一步失败：

```
aws: [ERROR] An error occurred (AccessDenied) when calling the CreateDistribution operation: Your account
must be verified before you can add new CloudFront resources. To verify your account, please contact
AWS Support (https://console.aws.amazon.com/support/home#/) and include this error message.
```

处理步骤：

1. 直接登录并打开 [https://console.aws.amazon.com/support/home](https://console.aws.amazon.com/support/home)（用根账号登录；账号验证类工单与支持计划档位无关，不会产生费用）。
2. 新账号默认落在「人工智能支持」（AI 助手）对话页：按页面提示升级到支持计划对话入口（或由 AI 助手转接人工），直到能创建正式工单为止。
3. 创建工单时选择：类别 **Account and billing** → 子类 **Account verification**；正文附上上面报错原文，说明用途（自建代理/CDN 分发）并请求开通 CloudFront 生产访问。
4. 等待 AWS 人工批准（一般 24 小时内，常见几分钟到几小时），结果以邮件通知。
5. 批准后重跑 `sudo easy_all install`（模式 2 / 4）。此前已签发的 ACM（us-east-1）证书与 Cloudflare DNS 验证记录不会报冲突，安装会复用或幂等校验；本机侧在失败时已回滚，重装无碍。

> [!NOTE]
> 失败时云端已产生的资源（ACM 证书、DNS 验证记录）由 easy_all 落盘追踪，不会被重复创建；若 Support 回复要求补充账号资料，按邮件指引回复后等待即可。
