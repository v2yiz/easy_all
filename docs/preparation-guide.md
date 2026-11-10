# 前置准备手册

本手册介绍使用 `easy_all` 部署各个模式前，需要在域名注册商、Cloudflare、AWS 准备的资源与凭证。

---

## 0. 各模式资源准备一览表

| 模式 | 必须准备的资源 | 核心凭据 / Token |
| :--- | :--- | :--- |
| **模式 1：AnyTLS 直连** | - 纯节点（`link`）：仅需公网 IPv4 VPS 与 1 个灰云直连子域名（如 `node.example.com`）<br>- 本机订阅（`deploy`）：再加 1 个橙云订阅子域名（如 `sub.example.com`） | - Cloudflare API Token（`Zone Read` + `DNS Edit`；`deploy` 另加 `Zone Settings Read` + `Origin Rules Edit`；`0600` 保存）<br>- 无 AWS |
| **模式 2：纯 CloudFront** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可，仅作权威 DNS）<br>- 2 个二级子域名（源站、CloudFront 节点；订阅域名默认复用节点域名）<br>- AWS 全球商业区账号（可用于 CloudFront 与 us-east-1 ACM） | - Cloudflare API Token（仅 `Zone Read` + `DNS Edit`；`0600` 保存至 root 受控文件）<br>- AWS Access Key ID / Secret Access Key（仅当前进程内存使用，不落盘；见 [AWS 准备指南](aws-guide.md)） |
| **模式 3：纯 CloudFlare（单域名）** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可）<br>- 1 个二级子域名（橙云 `A` → VPS；同时提供节点与订阅） | - Cloudflare API Token（`Zone Read` + `DNS Edit` + `Zone Settings Read` + `SSL and Certificates Edit`；`0600` 保存至 root 受控文件） |
| **模式 4：AnyTLS + CloudFront** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可，仅作权威 DNS）<br>- 默认 3 个二级子域名（直连、源站、CloudFront 节点；直连域名可与源站复用，订阅域名默认复用节点域名）<br>- AWS 全球商业区账号（可用于 CloudFront 与 us-east-1 ACM） | - Cloudflare API Token（仅 `Zone Read` + `DNS Edit`；`0600` 保存至 root 受控文件）<br>- AWS Access Key ID / Secret Access Key（仅当前进程内存使用，不落盘；见 [AWS 准备指南](aws-guide.md)） |

> [!IMPORTANT]
> **4.x 安装需要先卸载**：`STATE_VERSION=1` 是唯一受支持的 schema。4.x 的 `state.env` 与安装标记（schema 0）不会被当前版本接管，请先用 4.x 的 `sudo easy_all uninstall`（需要时加 `--purge-cloud`）卸载，再用 5.x 重新安装，客户端需重新导入订阅。

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

> **注意**：按各模式提示准备的子域名由 `easy_all` 安装时自动通过 API 创建，**请勿提前手动添加 A 记录或 CNAME**。如果这些名字上已有旧记录（例如上一轮安装留下的 `A` 记录、或指向别处的 CNAME），请先手工清理冲突记录，安装过程不会把旧 `A` 自动转换成 `CNAME`；遇到类型冲突会直接报错并保留现状；非受管记录在非交互环境下直接报错，在 stdin 与 stderr 都是终端时会提示确认是否强制接管。强制接管会改写注释与指向（TTL 统一为自动），原注释、原指向、原代理与原 TTL 写入 `/var/log/easy_all/dns-takeover.log`（写入失败则不改写记录）；卸载或 `purge-cloudflare` 时这类 DNS 记录会被保留而不是删除，需要时按本机日志手工恢复或清理。

### 1.3 SSL/TLS 与 Origin CA（模式 1 `deploy` / 模式 3）
模式 1 的订阅域名、模式 3 的节点域名都经 Cloudflare 橙云代理回源，因此：

- 进入 Zone → **SSL/TLS** → **Overview**，把加密模式设为 **Full (strict)**。工具在创建任何 DNS/证书/规则资源前会只读校验该设置（需要 `Zone Settings Read` 权限）：
  - **strict**：继续；
  - **full / flexible / off**：直接停止并点名当前值。默认的 **Flexible** 会用 HTTP（80 端口）回源，而 easy_all 的 Caddy 只在 `443`/`8443` 上提供 HTTPS，结果必然是 521/525 或重定向失败。工具**不会**自动改全区设置。
  - 读取返回 403：提示权限不足，需补 `Zone Settings Read` 后重试。
- easy_all 自己签发的证书满足 strict 校验：模式 1 `deploy` 订阅站点用 Let's Encrypt（DNS-01），模式 3 用 Cloudflare Origin CA。
- 注意端口用途区别：模式 1 的 AnyTLS **直连**入口是 `443`（对客户端开放），订阅是橙云 `A` 记录 + Origin Rule 回源 `8443`（只对 Cloudflare 回源 IPv4 段开放）。

模式 2/4 **不使用橙云代理**：源站、节点与订阅域名全部是灰云记录（回源由 AWS CloudFront 完成，CloudFront 直接访问 VPS 的 `443`（模式 2）或 `8443`（模式 4），不经过 Cloudflare），因此 Zone 的 SSL/TLS 加密模式与 Origin CA 与这两个模式无关，也不需要在 Cloudflare 控制台做任何额外开关（本版本不使用 gRPC，不需要开启 Network → gRPC）。

---

## 2. 模式 2：纯 CloudFront 域名规划

模式 2 使用「Cloudflare 权威 DNS → AWS ACM → CloudFront → 源站 Let's Encrypt → Caddy → sing-box VLESS WebSocket」链路，需要同一个 Cloudflare Zone 下的 2 个二级子域名（订阅默认复用节点域名）：

| 子域名示例 | 记录类型与代理状态 | 用途说明 |
| :--- | :--- | :--- |
| `origin.example.com` | `A` → VPS 公网 IPv4，**灰云（DNS only）** | 源站域名：Let's Encrypt 证书与 CloudFront 回源目标（回源端口 `443`）；必须与节点、订阅域名都不同 |
| `cf.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | CloudFront 节点域名：客户端连接的 server/SNI/Host |
| `sub.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | 订阅下载域名；**直接回车即复用节点域名**，不重复建记录 |

- 安装时只需输入根域名，源站与节点域名直接回车即可使用推荐默认值；分发域名要等 CloudFront 创建完成后才存在，由脚本自动写入 CNAME。
- 源站域名上不能已有指向其他机器的 `AAAA` 或其他冲突记录，否则 CloudFront 回源会落到错误的目标。

---

## 3. 模式 3：Cloudflare 橙云域名规划

模式 3 只需要 1 个二级子域名，同一个名字同时承载节点与订阅：

| 子域名示例 | 记录类型与代理状态 | 用途说明 |
| :--- | :--- | :--- |
| `cf.example.com` | `A` → VPS 公网 IPv4，**橙云（Proxied）** | 节点域名：同时承载 VLESS WebSocket 入站与 `/subscribe`、`/sub` 订阅；Origin CA 证书只有这一个 SAN，订阅域名由它派生 |

- 橙云节点域名必须是 Zone 的**一级**子域名（如 `cf.example.com`），多级名字不在默认边缘证书覆盖范围内，脚本会在输入阶段拒绝。
- 橙云链路不使用 `80` 端口、不运行 Certbot：回源证书是 Cloudflare Origin CA（15 年），不需要在 `80` 上做域名校验。
- Zone 的 **SSL/TLS 必须是 Full (strict)**：安装与 `apply-cloud` 在创建资源前只读校验，`full`/`flexible`/`off` 会直接停止。
- 节点域名的 `443` 只对 Cloudflare 官方回源 IPv4 段放行（UFW 注释 `easy_all-cf-origin-443`）。
- **同名 AAAA 必须先清理**：该域名上若已有指向其他地址的 `AAAA` 记录，脚本会拒绝配置对应 `A` 记录（不猜测、也不会替你删除第三方记录），请在安装前手工清理。

---

## 4. 模式 4：AnyTLS + CloudFront 域名规划

模式 4 在模式 2 的 CloudFront 链路之外增加一个固定 `443` 的 AnyTLS 直连入口，默认需要同一个 Cloudflare Zone 下的 3 个二级子域名：

| 子域名示例 | 记录类型与代理状态 | 用途说明 |
| :--- | :--- | :--- |
| `node.example.com` | `A` → VPS 公网 IPv4，**灰云（DNS only）** | 直连 AnyTLS 节点入口（客户端直连 VPS `443`）；**可与源站域名复用**（填同一个名字时不会重复建记录） |
| `origin.example.com` | `A` → VPS 公网 IPv4，**灰云（DNS only）** | 源站域名：CloudFront 回源（端口 `8443`）与 Let's Encrypt 证书 |
| `cf.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | CloudFront 节点域名：客户端连接的 server/SNI/Host |
| `sub.example.com` | `CNAME` → CloudFront 分发域名，**灰云（DNS only）** | 订阅下载域名；**直接回车即复用节点域名** |

- 直连域名不得等于节点或订阅域名；与源站复用会让两个入口共用一个名字（端口不同、证书互不影响），此时只需 2 个名字。
- 所有业务域名都必须是同一 active Zone 下的子域名，不支持根域名（apex）、通配符或跨 Zone。

---

## 5. 创建 Cloudflare API Token

进入 Cloudflare 控制台 **My Profile → API Tokens**，在 **User API Tokens** 区域点击 **Create Token**。Cloudflare 另有独立的 **Account API Tokens**；只有在凭据不应绑定用户、且所用 API endpoint 支持 Account Token 时才选择它。本指南按 User API Token 配置。

### 5.1 新版控制台操作步骤

截至 2026-11-10，创建页已改为模板与策略流程，旧版单独的 **Custom Token** 入口不再是起点：

1. 在 **Create Token** 页填写 Token 名称。
2. 选择 **Start from scratch → Start with a Zone policy**。不要选 Account 或 User policy；下表的权限都属于 Zone scope。
3. 在策略中设置 **Rule action = Include**、**Resource type = Specific zone**，再选本次部署使用的域名 Zone。当前下拉还提供 **All zones** 和 **All zones from an account**；按最小权限原则不要选这两项。
4. 在权限区展开分类，或使用 **Search for permission groups...** 搜索权限组；按下表勾选需要的 `Read` / `Edit`。当前界面把权限分在 **DNS & Zones**、**Rules & Configuration**、**Cache & Performance** 等分类中。
5. 需要限制 Token 时，设置 **Token expiration** 或 **Client IP address filtering**。这两项是可选限制，不代替权限与 Zone scope。
6. 点击 **Continue to summary**，核对 Zone 和权限后再创建。Token secret 只显示一次，创建后立即复制并妥善保管。

![easy_all 的 Cloudflare Token 新版 Zone policy 配置示意图](img/cloudflare/cloudflare-api-token-easy-all.svg)

上图是按各部署模式整理的本地配置示意。下面两张 Cloudflare 官方截图展示新版表单和权限摘要的位置；官方模板截图使用了 **All zones**，摘要图也显示了全 Zone 范围，仅供识别界面，请按上面的步骤改为 **Specific zone**，并按模式勾选权限。

![Cloudflare 官方 API Token 权限配置表单示例](https://github.com/cloudflare/cloudflare-docs/raw/refs/heads/production/src/assets/images/fundamentals/api/template-customize.png)

![Cloudflare 官方 API Token 权限摘要页示例](https://github.com/cloudflare/cloudflare-docs/raw/refs/heads/production/src/assets/images/fundamentals/api/token-summary.png)

Cloudflare 官方[创建 API Token 指南](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)标注更新于 2026-11-06，完整权限名称见[官方权限列表](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)。

### 5.2 权限配置（按模式分列）

| 当前控制台分类 → 权限项 | 模式 1 `link` | 模式 1 `deploy` | 模式 2 / 4 | 模式 3 | 作用 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **DNS & Zones** → `Zone / Zone / Read` | 需要 | 需要 | 需要 | 需要 | 读取并确认目标 Zone 状态与 ID |
| **DNS & Zones** → `DNS / Zone / Edit` | 需要 | 需要 | 需要 | 需要 | 自动管理直连/订阅/源站 `A` 记录、节点 `CNAME` 与 ACM 验证记录 |
| **DNS & Zones** → `Zone Settings / Zone / Read` | 不需要 | 需要 | **不需要** | 需要 | 只读校验 Zone SSL/TLS 是否为 `Full (strict)`（只读，不修改全区设置） |
| **Rules & Configuration** → `Origin Rules / Zone / Edit` | 不需要 | 需要 | **不需要** | **不需要** | 为订阅域名维护精确 `http.host` 的 Origin Rule，回源 `8443` |
| **Cache & Performance** → `SSL and Certificates / Zone / Edit` | 不需要 | 不需要 | **不需要** | 需要 | 申请、轮换与吊销 Cloudflare Origin CA 证书 |

- 模式 1 `deploy` 与模式 3 的 `strict` 检查需要 `Zone Settings Read`；缺这项会在创建任何资源前以 403 停止并点名权限。
- 模式 2/4 的 TLS 由 AWS ACM（viewer）与 Let's Encrypt（源站）负责，Cloudflare 只做 DNS，因此**不要**给这两个模式的 Token 授予证书、Zone Settings 或 Rulesets 权限。
- 只有模式 1 `deploy` 需要 Origin Rules；模式 1 `link` 不建订阅站点、也不写 Origin Rule。

### 5.3 创建后保存

上表权限都应添加到同一个目标 Zone 的 Zone policy。创建后妥善保存 Token，在安装交互提示 `Cloudflare API Token` 时粘贴。

> [!IMPORTANT]
> **Cloudflare Token 最小权限与持久化说明**：模式 1/2/3/4 为了支持后续 DNS/证书/Origin Rule 变更与免交互运维，输入的 Token 会以 root 受控权限（`0600`）保存于 `/etc/easy_all/cloudflare.token`；DNS-01 用的凭据另外以 `0600` 保存到 `/etc/easy_all/cloudflare.ini` 供 Certbot 定时续期。请务必遵循最小权限原则，仅授予目标 Zone 与所选模式真正需要的权限，严禁使用全局 Global API Key 或授予未使用的额外权限；`easy_all purge-cloudflare` 清理工具已对无 Rulesets 权限的 Token 做了平滑容错，不会阻断云端 DNS 记录的清理。

---

## 6. 准备 AWS 账号与访问密钥（仅模式 2/4）

1. **账号**：使用 **AWS 全球商业区（aws 分区）** 账号，不要使用 AWS 中国区域账号（aws-cn 分区）；CloudFront 的自定义域名证书必须来自 `us-east-1` 的 ACM。
2. **最小权限 IAM**：创建一个仅允许 ACM（`us-east-1`）与 CloudFront 分发读写的专用 IAM 用户，不要使用根用户密钥，也不需要 Route 53、WAF 或 Cloudflare 相关权限。
3. **访问密钥**：为该用户生成 Access Key ID + Secret Access Key。安装时隐藏输入，**只存在于当前进程内存**：不写入 `state.env`、身份文件、systemd 单元、cron、日志或订阅产物；进程退出后不保留。
4. **免费额度与计费**：CloudFront 的免费额度、请求计费与账号条款以 AWS 当前政策为准；easy_all 内置的是本机近似计量保护（985 GB，mangle 回环计数，模式 4 的直连流量不计入），用于降低超额风险，不构成零账单保证。

完整的控制台操作步骤、可直接粘贴的 IAM 策略 JSON 与密钥创建流程见 [AWS 准备指南](aws-guide.md)。

---

## 7. 端口、安全组与源站暴露面

| 模式 | 需在安全组/防火墙放行的 TCP 端口 | 说明 |
| :--- | :--- | :--- |
| 1 AnyTLS 直连 | 直连 `443`；**订阅部署需另加回源 `8443`**（仅 Cloudflare 官方回源 IPv4 段） | `443` 是 AnyTLS 直连入口；`8443` 是订阅域名橙云回源端口 |
| 2 纯 CloudFront | `443` | CloudFront 源站端口，公网可达（回源无固定 IP 段） |
| 3 纯 CloudFlare（单域名） | `443` | 橙云回源端口，只对 Cloudflare 官方回源 IPv4 段；不需要 `80` |
| 4 AnyTLS + CloudFront | `443` + `8443` | `443` 是直连入口与 CloudFront viewer；`8443` 是 CloudFront 源站端口（公网可达） |

> [!IMPORTANT]
> **本版本不需要 `80`**：所有公信证书都走 Cloudflare DNS-01（Certbot + Cloudflare 插件，凭据 `0600`），不需要在 `80` 上做域名校验，也没有 HTTP 重定向。只放行上表中的端口即可，多开 `80` 不会带来任何功能。

> [!WARNING]
> **模式 2/4 的源站端口对公网可达**：CloudFront 回源没有可枚举的固定 IP 段，因此这两个模式**不使用 Cloudflare 回源 IPv4 白名单**，任何扫描器都能连到源站（模式 2 `443`、模式 4 `8443`）。实际防护依赖公信 TLS 证书、`X-Easy-All-Origin-Key` 源站头（Caddy 外层 `route` 首位精确比较，不等即 `abort`）、随机 VLESS 路径与 VLESS/Token 鉴权；这些不能防网络层 DDoS、TLS/HTTP 资源耗尽或密钥泄露。模式 1 的订阅回源 `8443` 与模式 3 的橙云 `443` 白名单不受影响。
