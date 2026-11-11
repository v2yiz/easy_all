# 前置准备手册

本手册介绍使用 `easy_all` 部署各个模式前，需要在域名注册商、Cloudflare 和 AWS 准备的资源与凭据：**域名注册与 Cloudflare 托管**、**Cloudflare API Token**（全模式）与 **AWS 访问密钥**（仅模式 4/5）。

## 凭据需求一览

| 部署模式 | Cloudflare API Token 权限要求 | AWS 访问密钥（IAM） |
| :--- | :--- | :---: |
| **模式 1 AnyTLS 直连** | `link`: Zone Read + DNS Edit<br>`deploy`: Zone Read + DNS Edit + Zone Settings Read + Origin Rules Edit | 不需要 |
| **模式 2 纯 CloudFlare** | Zone Read + DNS Edit + Zone Settings Read + SSL and Certificates Edit | 不需要 |
| **模式 3 AnyTLS + CloudFlare** | Zone Read + DNS Edit + Zone Settings Read + Origin Rules Edit | 不需要 |
| **模式 4 纯 CloudFront** | Zone Read + DNS Edit | **需要** |
| **模式 5 AnyTLS + CloudFront** | Zone Read + DNS Edit | **需要** |

---

## 1. 域名注册与 Cloudflare 托管

### 1.1 域名注册（Spaceship）

部署代理服务需要一个由你控制的顶级域名（根域名，例如 `example.xyz`），推荐使用 [Spaceship](https://www.spaceship.com/) 注册：

> [!TIP]
> **核心技巧：6 位数字及以上 `.xyz`（注册首年 + 续费 9 年）**
> - **特别强调：必须是 6 位数字及以上纯数字**（例如 `123456.xyz`、`891234.xyz`、`987654321.xyz` 等）。这是 `.xyz` 注册局的专属特惠规则，**字母、英文单词或 5 位及以下数字不享受该优惠**（续费会恢复常规原价每年约 $10+）。
> - **购买策略：注册首年，续费 9 年**。在 Spaceship 搜索未被注册的 6 位及以上纯数字 `.xyz`，加入购物车后，**选择注册 1 年并直接续费 9 年（一次性购满 10 年）**。
> - 这样平均每年成本仅需几元人民币，10 年总价仅约几十元，是性价比最高的域名方案。下单前在结算页面核对首年价与续费总额即可。

注册完成后，保存好 Spaceship 账号、到期日与恢复邮箱。

![Spaceship 注册账号示例](img/spaceship/spaceship-signup.svg)

![Spaceship 搜索可注册域名示例](img/spaceship/spaceship-domain-search.svg)

### 1.2 在 Cloudflare 添加域名

`easy_all` 依赖 Cloudflare 权威 DNS 自动化管理解析记录及签发证书（免费计划即可满足全模式需求）：

1. 打开 [Cloudflare 注册页](https://dash.cloudflare.com/sign-up)，注册并登录账号。
2. 进入 [Cloudflare Dashboard](https://dash.cloudflare.com/)，点击 **Add a domain**，输入刚注册的根域名（例如 `example.com`）。
3. 方案选择 **Free**（免费计划即可）。

![Cloudflare 添加域名示例](img/cloudflare/cloudflare-add-domain.svg)

4. Cloudflare 会自动为该域名分配两条专属权威名称服务器（Nameservers，例如 `ns1.cloudflare.com` 与 `ns2.cloudflare.com`），复制这两条服务器地址。

![Cloudflare 名称服务器示例](img/cloudflare/cloudflare-nameservers.svg)

### 1.3 在域名注册商修改名称服务器（DNS 委派）

1. 回到你的域名注册商控制面板，找到域名的 **DNS / Nameservers** 管理页面。
2. 将默认的名称服务器修改为自定义，完整填入 Cloudflare 给出的两条名称服务器并保存。

![Spaceship 域名管理器中修改名称服务器示例](img/spaceship/spaceship-nameservers.svg)

3. 等待全球 DNS 传播生效（通常数分钟到数小时），刷新 Cloudflare 控制台，直到域名状态出现绿色勾选并显示 **Active**（或提示 **Your domain is now protected by Cloudflare**）。必须确认状态变为 Active 后再继续后续步骤。

![Cloudflare 域名托管成功标记](img/cloudflare/cloudflare-domain-protected.svg)

### 1.4 本项目对域名的规划与要求

- **全模式使用二级子域名**：所有模式都使用同一个 Zone 下的一级/二级子域名（如 `node.example.com`、`cf.example.com`），根域名（apex）本身只用于托管 Zone，不作为客户端节点名。
- **切勿提前在控制台手动添加子域名 DNS 记录**：安装器会在运行期间通过 API 自动检查、创建和绑定对应的 A 记录或 CNAME。
- **旧记录冲突清理**：若域名此前使用过并留有同名 A、AAAA 或 CNAME 记录，建议在安装前先在 Cloudflare 控制台手动清理冲突记录。

---

## 2. Cloudflare API Token 准备（全模式）

部署时需提供已托管目标域名的 Cloudflare API Token，用于自动化 DNS 解析、证书签发与回源规则配置。

### 2.1 权限明细对照

请遵循最小权限原则，仅授予目标 Zone（`Specific zone`）所需的权限：

| 权限分类与项目 | 适用模式 | 作用说明 |
| :--- | :--- | :--- |
| `Zone / Zone / Read` | 全模式 (1-5) | 读取目标 Zone 状态与 ID |
| `DNS / Zone / Edit` | 全模式 (1-5) | 自动管理 A、CNAME 及 ACM/Certbot DNS 验证记录 |
| `Zone Settings / Zone / Read` | 模式 1 deploy / 模式 2 / 模式 3 | 校验 Zone SSL/TLS 是否为 `Full (strict)` |
| `Origin Rules / Zone / Edit` | 模式 1 deploy / 模式 3 | 维护订阅/节点回源 8443 端口的 Origin Rule |
| `SSL and Certificates / Zone / Edit` | 模式 2 | 签发与管理 Cloudflare Origin CA 证书 |

> [!NOTE]
> - **模式 4/5** 边缘证书由 AWS ACM 托管，Cloudflare 仅作权威 DNS，**只需 Zone Read 与 DNS Edit**。
> - Token 在安装时输入，以 `0600` 权限安全保存于 VPS 本机 `/etc/easy_all/cloudflare.token`。

### 2.2 控制台创建步骤

1. 登录 [Cloudflare 控制台](https://dash.cloudflare.com/)，进入右上角头像 → **My Profile** → **API Tokens** → **Create Token**。
2. 选择 **Start with a Zone policy**（或 Create Custom Token）。
3. **Scope 范围**：`Zone Resources` 选 `Include` → `Specific zone` → 选择本次部署使用的域名 Zone。
4. **Permissions 权限**：根据上表添加所选模式需要的权限项。
5. 点击 **Continue to summary** 并创建，妥善保存生成的 Token。

![Cloudflare Token Zone policy 配置示意图](img/cloudflare/cloudflare-api-token-easy-all.svg)

---

## 3. AWS 凭证准备（仅模式 4/5）

模式 4 与模式 5 使用 AWS CloudFront 分发与 AWS Certificate Manager (ACM) viewer 证书。模式 1、2、3 无需 AWS 凭据。

### 3.1 账号与区域要求

- **全球商业区账号**：使用 AWS 全球标准账号（不支持中国区）。
- **证书固定区域**：CloudFront 的 viewer 证书必须位于 **`us-east-1`（弗吉尼亚北部）**，脚本固定在此区域调用 ACM 申请与校验。
- **内存安全使用**：AWS 密钥在安装时输入，**仅暂存于当前进程内存，不落盘**（不写入 state、日志或订阅）；亦可通过环境变量 `AWS_ACCESS_KEY_ID` 与 `AWS_SECRET_ACCESS_KEY` 预先传入。
- **费用保护**：本机内置 985 GB 近似流量计量保护，达到阈值自动阻断 CDN 入口，降低超额扣费风险。

### 3.2 创建 IAM 策略与专用用户

#### 第一步：创建最小权限策略

1. 登录 AWS 控制台，进入 **IAM** → **Policies（策略）** → **Create policy**。
2. 切换到 **JSON** 标签页，粘贴以下策略并命名为 `EasyAllCloudFrontPolicy`：

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
      "Action": ["sts:GetCallerIdentity"],
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

#### 第二步：创建用户并生成 Access Key

1. 在 IAM 中进入 **Users（用户）** → **Create user**，用户名填写 `easy_all-cloudfront-deployer`（**切勿勾选**提供控制台访问权限）。
2. 在权限选项中选择 **Attach policies directly**，勾选刚刚创建的 `EasyAllCloudFrontPolicy` 并完成创建。
3. 进入该用户详情页，切换到 **Security credentials** 标签页。
4. 在 **Access keys** 区域点击 **Create access key**，场景选择 **CLI**，完成创建并妥善保存：
   - **Access Key ID**
   - **Secret Access Key**（仅显示一次）

> [!TIP]
> **新 AWS 账号开通提示**：若账号注册于 2021 年末之后，首次创建 CloudFront 分发时若报 `Your account must be verified`，前往 [AWS Support](https://console.aws.amazon.com/support/home) 提交工单（类别 `Account and billing` → `Account verification`）申请开通 CloudFront 生产访问。工单通常需要 24 小时以上才有人处理；批准后重新运行安装将自动幂等复用已创建的证书与 DNS。
