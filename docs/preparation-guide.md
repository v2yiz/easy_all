# 前置准备手册

本手册介绍使用 `easy_all` 部署各个模式前，需要在域名注册商、Cloudflare、AWS 准备的资源与凭证。

---

## 0. 各模式资源准备一览表

| 模式 | 必须准备的资源 | 核心凭据 / Token |
| :--- | :--- | :--- |
| **模式 1：直连 Reality** | - 纯节点（`link`）：仅需公网 IPv4 VPS，无其他要求<br>- 本机订阅（`deploy`）：需 1 个二级子域名（如 `sub.example.com`） | - 纯节点：无<br>- 订阅模式：具备 DNS 与证书权限的 Cloudflare API Token |
| **模式 2：纯 CDN（CloudFront）** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可，仅作权威 DNS）<br>- 2 个二级子域名（源站、CloudFront 节点；订阅域名默认复用节点域名）<br>- AWS 全球商业区账号（可用于 CloudFront 与 us-east-1 ACM） | - Cloudflare API Token（仅 `Zone Read` + `DNS Edit`；`0600` 保存至 root 受控文件）<br>- AWS Access Key ID / Secret Access Key（仅当前进程内存使用，不落盘；见 [AWS 准备指南](aws-guide.md)） |
| **模式 3：直连+CloudFront** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可，仅作权威 DNS）<br>- 默认 3 个二级子域名（直连、源站、CloudFront 节点；直连域名可与源站复用，订阅域名默认复用节点域名）<br>- AWS 全球商业区账号（可用于 CloudFront 与 us-east-1 ACM） | - Cloudflare API Token（仅 `Zone Read` + `DNS Edit`；`0600` 保存至 root 受控文件）<br>- AWS Access Key ID / Secret Access Key（仅当前进程内存使用，不落盘；见 [AWS 准备指南](aws-guide.md)） |

> [!IMPORTANT]
> **旧版本状态需要卸载重装**：旧版 `PROTOCOL=cdn`（橙云 XHTTP）与旧版橙云 `combined` 安装不能被当前版本接管，请先执行 `sudo easy_all uninstall`（默认保留云端资源）后重新安装，客户端需重新导入订阅。

---

## 1. 域名注册与 Cloudflare 托管

### 1.1 域名注册
购买一个可长期使用的顶级域名（如在 Spaceship、Namesilo、Namecheap 等注册商购买 `.xyz`、`.com`、`.net` 等）。

### 1.2 托管至 Cloudflare
1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)，点击 **Add a domain**，输入你购买的根域名（如 `example.com`）。
2. 选择 **Free** 免费计划。
3. Cloudflare 会给出两条专属 Nameservers（例如 `ns1.cloudflare.com` 和 `ns2.cloudflare.com`）。
4. 登录你的域名注册商控制面板，将域名的权威 DNS 服务器替换为 Cloudflare 给出的这两条。
5. 等待 DNS 传播生效，直到 Cloudflare 控制台显示域名状态为 **Active**（已保护）。

> **注意**：按各模式提示准备的子域名由 `easy_all` 安装时自动通过 API 创建，**请勿提前手动添加 A 记录或 CNAME**。如果这些名字上已有旧记录（例如上一轮安装留下的 `A` 记录、或指向别处的 CNAME），请先手工清理冲突记录，安装过程不会把旧 `A` 自动转换成 `CNAME`，遇到归属不明或类型冲突会直接报错并保留现状。

### 1.3 SSL/TLS 与 Origin CA（仅模式 1）
模式 1 的订阅域名经 Cloudflare 橙云代理回源，因此：

- 进入 Zone → **SSL/TLS** → **Overview**，把加密模式设为 **Full** 或 **Full (strict)**。默认的 **Flexible** 会让 Cloudflare 用 HTTP（80 端口）回源，而 easy_all 的订阅源站只在 `8443` 上提供 Cloudflare Origin CA 证书，结果会是 521/525 握手失败或重定向死循环（注意：模式 1 的 Reality 直连入口是 `443` 或动态端口，与这里的订阅回源 `8443` 是两个不同用途的端口）。
- **Full (strict)** 会校验源站证书，easy_all 自动签发的 Origin CA 证书正好满足要求。

模式 2/3 **不使用橙云代理**：源站、节点与订阅域名全部是灰云记录（回源由 AWS CloudFront 完成，CloudFront 直接访问 VPS 的 443，不经过 Cloudflare），因此 Zone 的 SSL/TLS 加密模式与 Origin CA 与这两个模式无关，也不需要在 Cloudflare 控制台做任何额外开关。

---

## 2. 模式 2：纯 CDN（CloudFront）域名规划

模式 2 使用「Cloudflare 权威 DNS → AWS ACM → CloudFront → 源站 Let's Encrypt → Nginx → Xray XHTTP」链路，需要同一个 Cloudflare Zone 下的 2 个二级子域名（订阅默认复用节点域名）：

| 子域名示例 | 记录类型与代理状态 | 用途说明 |
| :--- | :--- | :--- |
| `origin.example.com` | `A` → VPS 公网 IPv4，**灰云（DNS only）** | 源站域名：Let's Encrypt 证书与 CloudFront 回源目标；必须与节点、订阅域名都不同 |
| `cf.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | CloudFront 节点域名：客户端连接的 server/SNI/Host |
| `sub.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | 订阅下载域名；**直接回车即复用节点域名**，不重复建记录 |

- 安装时只需输入根域名，源站与节点域名直接回车即可使用推荐默认值；分发域名要等 CloudFront 创建完成后才存在，由脚本自动写入 CNAME。
- 源站域名上不能已有指向其他机器的 `AAAA` 或其他冲突记录，否则 HTTP-01 验证或 CloudFront 回源会落到错误的目标。

---

## 3. 模式 3：直连+CloudFront 域名规划

模式 3 在模式 2 的 CloudFront 链路之外增加一个固定 `8443` 的 Reality 直连入口，默认需要同一个 Cloudflare Zone 下的 3 个二级子域名：

| 子域名示例 | 记录类型与代理状态 | 用途说明 |
| :--- | :--- | :--- |
| `node.example.com` | `A` → VPS 公网 IPv4，**灰云（DNS only）** | 直连 Reality 节点入口（客户端直连 VPS `8443`）；**可与源站域名复用**（填同一个名字时不会重复建记录） |
| `origin.example.com` | `A` → VPS 公网 IPv4，**灰云（DNS only）** | 源站域名：CloudFront 回源与 Let's Encrypt 证书 |
| `cf.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | CloudFront 节点域名：客户端连接的 server/SNI/Host |
| `sub.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | 订阅下载域名；**直接回车即复用节点域名** |

- 直连域名不得等于节点或订阅域名；与源站复用会让两个入口共用一个名字（端口不同、证书互不影响），此时只需 2 个名字。
- 所有业务域名都必须是同一 active Zone 下的子域名，不支持根域名（apex）、通配符或跨 Zone。

---

## 4. 创建 Cloudflare API Token

进入 Cloudflare 控制台：**My Profile → API Tokens → Create Token → Custom Token**。

### 4.1 权限配置（按模式分列）

| 权限项 | 模式 1（订阅部署） | 模式 2 / 3 | 作用 |
| :--- | :--- | :--- | :--- |
| `Zone / Zone / Read` | 需要 | 需要 | 读取并确认目标 Zone 状态 |
| `Zone / DNS / Edit` | 需要 | 需要 | 自动添加/管理源站 A、节点与订阅 CNAME 记录 |
| `Zone / SSL and Certificates / Edit` | 需要 | **不需要** | 仅模式 1 申请与轮换 Cloudflare Origin CA 证书 |

模式 2/3 的 TLS 由 AWS ACM（viewer）与 Let's Encrypt（源站）负责，Cloudflare 只做 DNS，因此**不要**给这两个模式的 Token 授予证书或 Rulesets 权限。

### 4.2 作用范围（Zone Resources）
- **Zone Resources**：`Include → Specific zone → 你的域名 (example.com)`

创建后妥善保存 Token，在安装交互提示 `Cloudflare API Token` 时粘贴。

> [!IMPORTANT]
> **Cloudflare Token 最小权限与持久化说明**：模式 2/3 为了支持后续 DNS 变更与免交互运维，输入的 Token 会以 root 受控权限（`0600`）保存于 `/etc/easy_all/cloudflare.token`。请务必遵循最小权限原则，仅授予目标 Zone 的 `Zone Read` 与 `DNS Edit`，严禁使用全局 Global API Key 或授予未使用的额外权限；`easy_all purge-cloudflare` 清理工具已对无 Rulesets 权限的 Token 做了平滑容错，不会阻断云端 DNS 记录的清理。

---

## 5. 准备 AWS 账号与访问密钥（模式 2/3）

1. **账号**：使用 **AWS 全球商业区（aws 分区）** 账号，不要使用 AWS 中国区域账号（aws-cn 分区）；CloudFront 的自定义域名证书必须来自 `us-east-1` 的 ACM。
2. **最小权限 IAM**：创建一个仅允许 ACM（`us-east-1`）与 CloudFront 分发读写的专用 IAM 用户，不要使用根用户密钥，也不需要 Route 53、WAF 或 Cloudflare 相关权限。
3. **访问密钥**：为该用户生成 Access Key ID + Secret Access Key。安装时隐藏输入，**只存在于当前进程内存**：不写入 `state.env`、身份文件、systemd 单元、cron、日志或订阅产物；进程退出后不保留。
4. **免费额度与计费**：CloudFront 的免费额度、请求计费与账号条款以 AWS 当前政策为准；easy_all 内置的是本机近似计量保护（985 GB），用于降低超额风险，不构成零账单保证。

完整的控制台操作步骤、可直接粘贴的 IAM 策略 JSON 与密钥创建流程见 [AWS 准备指南](aws-guide.md)。

---

## 6. 端口、安全组与源站暴露面

| 模式 | 需在安全组/防火墙放行的 TCP 端口 | 说明 |
| :--- | :--- | :--- |
| 1 直连 Reality | Reality 直连 `443`（固定端口）或 `10000-62703`（动态端口）；**订阅部署需另加回源 `8443`**（仅 Cloudflare 官方回源 IPv4 段） | 订阅部署时订阅域名经 Cloudflare 橙云代理回源到 `8443`；Reality 直连入口不使用该端口 |
| 2 纯 CDN（CloudFront） | `80` + `443` | `80` 仅供 Let's Encrypt HTTP-01 |
| 3 直连+CloudFront | `80` + `443` + Reality 直连 `8443` | 同上，另加 Reality 直连端口 |

> [!WARNING]
> **`80` 端口必须放行**：模式 2/3 的源站证书由 Let's Encrypt 通过 HTTP-01 验证签发，首次安装和后续自动续期都依赖 `http://<源站域名>/.well-known/acme-challenge/...`。安全组或上游防火墙拦截 `80` 会直接导致证书申请失败，安装会明确报错并停止，不会用自签证书顶替。

> [!WARNING]
> **模式 2/3 的源站 443 对公网可达**：CloudFront 回源没有可枚举的固定 IP 段，因此这两个模式**不再使用 Cloudflare 回源 IPv4 白名单**，任何扫描器都能连到 `origin` 的 443。实际防护依赖公信 TLS 证书、443 默认拒绝未知 SNI、随机 XHTTP 路径、`X-Easy-All-Origin-Key` 源站头校验与 VLESS/Token 鉴权；这些不能防网络层 DDoS、TLS/HTTP 资源耗尽或密钥泄露。模式 1 的订阅回源 `8443` 白名单不受影响。
