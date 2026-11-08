# AWS CloudFront + Cloudflare 一次性准备指南

本文档指导如何为 **模式 2（纯 CDN - CloudFront）** 与 **模式 3（直连+CloudFront）** 准备所需的 Cloudflare 与 AWS 凭据。模式 1（直连 Reality）不需要 AWS 账号。

---

## 0. 成本模型与边界（先读这一节）

- **Cloudflare 只作权威 DNS**：域名解析完全由 Cloudflare 免费计划提供，**不需要购买 AWS Route 53 托管区**，也没有任何橙云代理流量。模式 2/3 的所有业务记录都是灰云直出。
- **CloudFront 按账号条款计费**：AWS 对 CloudFront 通常提供每月一定额度的出站流量与请求数免费额度（例如 1 TB / 1000 万次量级），但具体额度、适用区域和计费单价**以你账号当前的 AWS 条款与账单为准**，可能随账号类型和 AWS 政策变化。超出免费额度的部分由 AWS 直接向账号绑定的支付方式收费。
- **本机 985 GB 近似计量保护**：VPS 上用 Xray 的 XHTTP 入站字节做本地计数，达到 985 GB（十进制 985×10⁹ 字节）就阻断 CDN 入口。这只是一个**本机近似计量保护**，不是 AWS 账单真源，不能承诺“零账单”，也不是任何形式的账单保底。

本机保护覆盖不到的费用包括但不限于：CloudFront 的 HTTP/HTTPS 请求费、订阅下载流量、TLS/HTTP 自身开销、同一账号其他分发或其他机器产生的用量、以及进程崩溃/关机期间缺失的最后一个采样窗口。免费额度还可能在同一 AWS 账号的多个使用方之间共享。

### 如何查看额度使用情况
1. 登录 [AWS Billing 控制台](https://console.aws.amazon.com/costmanagement/)。
2. 左侧菜单点击 **Free Tier（免费套餐）**，搜索 `CloudFront`，查看当月已用流量与请求数。
3. VPS 侧可随时执行 `sudo easy_all status` 查看本机统计的已用量、剩余保护空间与阻断状态。

---

## 1. 账号前提与控制区域

1. 使用 **AWS 全球商业区（aws 分区）** 账号，不要使用 AWS 中国区域账号（aws-cn 分区）。尚无账号可在 [AWS 全球官网](https://signin.aws.amazon.com/signup?request_type=register) 注册。
2. **控制区域选择**：控制台右上角区域务必选择 **美国东部（弗吉尼亚北部）`us-east-1`**。
   - **为什么必须是 us-east-1**：CloudFront 的自定义域名证书只能使用 `us-east-1` 的 AWS Certificate Manager (ACM) 证书，脚本固定在该区域申请与校验。
   - 这不影响节点延迟：CloudFront 是全球 Anycast 边缘网络，客户端会自动就近接入边缘节点。

---

## 2. 准备 Cloudflare API Token

域名需先添加到 Cloudflare（免费计划即可），状态为 **Active**。

1. 登录 Cloudflare 控制台 → 右上角头像 → **我的个人资料 (My Profile)** → **API 令牌 (API Tokens)**。
2. 点击 **创建令牌 (Create Token)** → 选择 **编辑区域 DNS (Edit zone DNS)** 模板。
3. 权限保持默认两项即可满足模式 2/3：
   - `区域 - 区域 - 读取`（Zone / Zone / Read）
   - `区域 - DNS - 编辑`（Zone / DNS / Edit）
4. **区域资源 (Zone Resources)**：选择 `包括 - 具体区域 - 你的域名`（例如 `example.com`）。
5. 点击继续并创建，复制生成的 Token。

脚本只会用这个 Token 做三件事：确认 Zone、为源站/直连域名写灰云 `A` 记录、为节点/订阅域名写灰云 `CNAME` 记录（以及 ACM 的 DNS 验证记录）。它**不需要**证书编辑、Rulesets 或账号级权限。Token 会以 `0600` 保存到 `/etc/easy_all/cloudflare.token` 供后续 `apply-cloud` / 卸载清理复用。

---

## 3. 创建最小权限 IAM 策略

脚本通过 AWS CLI 调用固定的几个接口，因此策略只需要 ACM（`us-east-1`）与 CloudFront 分发：

1. 登录 AWS 控制台，搜索进入 **IAM** 服务。
2. 左侧菜单点击 **策略 (Policies)** → **创建策略 (Create policy)**。
3. 切换到 **JSON** 选项卡，清空原有内容，粘贴以下内容：

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

4. 点击 **下一步**，策略名称填写：`EasyAllCloudFrontPolicy`，点击 **创建策略**。

### 权限说明（与脚本实际调用一致）

| 权限 | 使用场景 |
| :--- | :--- |
| `acm:RequestCertificate` / `acm:AddTagsToCertificate` | 申请 ACM 证书；申请时带 `easy_all` 归属标签，所以需要创建标签的权限 |
| `acm:ListCertificates` | 无本机状态时完整分页（`NextToken`）发现当前账号的候选证书；失败不得降级为新建 |
| `acm:DescribeCertificate` | 读取证书状态、域名/SAN 与 DNS 验证记录，判断是否可复用 |
| `acm:ListTagsForCertificate` / `acm:DeleteCertificate` | 发现阶段逐个核对归属标签；显式 `uninstall --purge-cloud` 时校验归属并删除证书，`InUseBy` 非空时不会删除 |
| `sts:GetCallerIdentity` | 任何无状态发现/创建前先固定“本次凭据所属账号”，失败即退出，不新建资源 |
| `cloudfront:ListDistributions` | 无本机状态时按精确 Comment 标记发现自有分发 |
| `cloudfront:CreateDistribution` / `cloudfront:UpdateDistribution` | 创建或更新分发（更新必须带 `ETag`） |
| `cloudfront:GetDistribution` / `cloudfront:GetDistributionConfig` | 等待 `Status=Deployed`、读取当前配置与 `ETag` |
| `cloudfront:DeleteDistribution` | 仅在显式 `uninstall --purge-cloud` 时先 `Enabled=false`、等待部署完成后再删除 |

策略**故意不含** Route 53、WAF、CloudFront 日志、IAM 或 Cloudflare 相关权限：本链路不使用这些服务，缺少它们不会影响安装。

**无状态云端发现的范围**：如果本机状态丢失（例如默认卸载保留云端资源后重新安装），脚本会先用 `sts:GetCallerIdentity` 固定“本次凭据所属账号”，再分别完整翻页读取 CloudFront `ListDistributions`（`DistributionSummary` + `NextMarker`）与 ACM `ListCertificates`（`NextToken`，固定 `us-east-1`），对每个 ACM 候选调用 `ListTagsForCertificate` 核对 `easy_all` 与 `easy_all-node` 标记，并用 `DescribeCertificate` 校验状态/region/SAN。分发候选只有 Comment 精确等于 `easy_all-cloudfront-<节点域名>` 且别名、源站拓扑与当前状态一致时才会接管（接管前用 `GetDistributionConfig` 再做一次归属校验）；只有唯一候选时才复用，完整分页确认零候选时才创建。多个候选、分页标记重复、标记/SAN/拓扑不符、别名被外部占用或任何查询/分页/标签失败都会直接报错退出，**不会创建新资源，也不会猜第一项**。脚本不切换账号、不跨角色枚举，也不做模糊搜索或交互式选择。

---

## 4. 创建专用 IAM 用户并生成 Access Key

### 第一步：创建 IAM 用户
1. 在 IAM 左侧菜单点击 **用户 (Users)** → **创建用户 (Create user)**。
2. 用户名填写：`easy_all-cloudfront-deployer`。
3. **不要勾选**“向用户提供 AWS 管理控制台的访问权限”（保持纯 API 用户）。
4. 下一步进入权限页：选择 **直接附加策略 (Attach policies directly)**，搜索并勾选 `EasyAllCloudFrontPolicy`。
5. 检查无误后点击右下角 **创建用户**。

### 第二步：生成访问密钥 (Access Key)
1. 点击刚创建的用户名进入详情页。
2. 切换到 **安全凭证 (Security credentials)** 标签页。
3. 在 **访问密钥 (Access keys)** 区域点击 **创建访问密钥 (Create access key)**。
4. 使用案例选择 **命令行界面 (CLI)**。
5. 勾选最下方的确认项并创建。
6. 当场复制保存：
   - **访问密钥 ID (Access Key ID)**
   - **私有访问密钥 (Secret Access Key)**（只展示一次）

---

## 5. 凭据如何被使用

安装时会依次隐藏输入：

```text
Cloudflare API Token        # 保存到 /etc/easy_all/cloudflare.token（0600）
AWS Access Key ID            # 仅当前进程内存
AWS Secret Access Key        # 仅当前进程内存
```

- 也支持提前在环境里导出 `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`（以及临时凭证的 `AWS_SESSION_TOKEN`），脚本会直接沿用，不再追问。
- 脚本**不调用** `aws configure`，不写 `~/.aws`，不把密钥写入 `state.env`、安装身份、systemd 单元、cron、订阅文件或任何调试输出；安装成功、失败、回滚与信号退出路径都会清空进程内的 AWS 与 Cloudflare 凭据。
- 不要使用 AWS 根（Root）用户密钥，也不要给该用户授予本链路的额外权限。

---

## 6. 域名、证书与分发

### 域名与记录
| 名字 | 记录 | 代理状态 |
| :--- | :--- | :--- |
| 源站（默认 `origin.<zone>`） | `A` → VPS 公网 IPv4 | 灰云 |
| CloudFront 节点（默认 `cf.<zone>`） | `CNAME` → CloudFront 分发域名 | 灰云 |
| 订阅（默认与节点同名） | 与节点同名时复用其 CNAME；不同则额外一条 `CNAME` → 分发域名 | 灰云 |
| 直连 Reality（仅模式 3，默认 `node.<zone>`） | `A` → VPS 公网 IPv4（可与源站同名复用） | 灰云 |

CNAME 指向的 CloudFront 分发域名只有在分发创建后才知道，所以不要提前手工建这些记录；如已有冲突记录，请先清理。

### 两套证书
- **Viewer 证书（AWS ACM，固定 `us-east-1`）**：主域名为 CloudFront 节点域名，SAN 覆盖订阅域名（两者同名时不重复）。复用已有 ARN 时必须同时满足：状态 `ISSUED`、region 为 `us-east-1`、覆盖全部别名。
- **源站证书（Let's Encrypt）**：只覆盖源站域名，由 Certbot 通过 **80 端口 HTTP-01** 验证；因此安全组必须放行 `80`（443 也需要）。证书签不下来时安装会失败，不会用自签证书假装成功。
- **ACM 的 DNS 验证记录默认保留**：即使执行 `uninstall --purge-cloud`，验证用 CNAME 也可能被同账号其他证书共享，脚本不会自动删除，需要你在控制台核实后手工清理。

### 手工清理顺序（如不使用 `--purge-cloud`）
1. 在 CloudFront 控制台把目标分发设为 **Disabled**（或执行 `aws cloudfront update-distribution` 关闭 `Enabled`），等待状态变为 `Deployed`。
2. 删除分发。
3. 确认 ACM 证书的 `InUseBy` 为空后再删除证书。
4. 最后清理节点/订阅/源站的 DNS 记录。

顺序颠倒会遇到 `DistributionInUse` / `ResourceInUse` 一类错误。

---

## 7. 启动安装

完成上述准备后，在 VPS 上运行：

```bash
sudo easy_all install
```

在交互菜单中选择：

```text
2. 纯 CDN - AWS CloudFront XHTTP（直连不佳、IP 被封或只要 CDN 入口时）
3. 直连+CDN：直连 Reality + CloudFront（一次部署两个入口）
```

按提示输入（模式 2 到「订阅配置 JSON」结束，模式 3 之后还有直连域名、Reality 目标与直连节点名）：

```text
Cloudflare 根 Zone            # 如 example.com
源站域名                       # 默认 origin.example.com（灰云 A → VPS）
CloudFront 节点域名            # 默认 cf.example.com（灰云 CNAME → 分发）
订阅域名                       # 默认与节点域名相同
Cloudflare API Token
AWS Access Key ID
AWS Secret Access Key
CloudFront 节点名              # 默认 🇺🇸AWS（完整单节点名）
Mihomo 下载文件名              # 默认 EASY_ALL
订阅配置 JSON                  # allowedTokens + nodes
```

脚本将自动完成：源站 `A` 记录、Let's Encrypt 源站证书、ACM 申请与 DNS 验证、CloudFront 分发创建/更新与 `Deployed` 等待、节点与订阅 `CNAME`、订阅产物生成与公网验收，最后确认流量保护定时器处于 active。

---

## 8. 安装后的流量保护

- 计时来源：Xray 的 `vless-xhttp-in` 入站计数（模式 3 的 Reality 流量不计入）。
- 阈值：**985 GB 十进制**（985×10⁹ 字节），固定不可调；每月按 **UTC 自然月** 重新计算。
- 达到阈值后只阻断 CDN：Nginx 对应路径返回 `503`、Xray 清空 XHTTP 客户端并重启以终止既有连接；模式 3 的 Reality 直连仍可用（重连后手动切换），订阅仍可下载。
- 定时器 `easy_all-cdn-traffic-guard.timer` 每 15 秒执行 `easy_all cdn-traffic-sync`；`apply`、`apply-cloud`、`update-core` 都不会绕过已生效的阻断。
- 如果 `sudo easy_all status` 显示流量保护异常（统计文件缺失/损坏、定时器 inactive），请先停用 CDN 入口再修复，不要删除 usage 文件来“清零”。
