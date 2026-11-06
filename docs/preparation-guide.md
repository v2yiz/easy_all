# 前置准备手册

本手册介绍使用 `easy_all` 部署各个模式前，需要在域名注册商、Cloudflare 和 Globalping 准备的资源与凭证。

---

## 0. 各模式资源准备一览表

| 模式 | 必须准备的资源 | 核心凭据 / Token |
| :--- | :--- | :--- |
| **模式 1：直连 Reality** | - 纯节点（`link`）：仅需公网 IPv4 VPS，无其他要求<br>- 本机订阅（`deploy`）：需 1 个二级子域名（如 `sub.example.com`） | - 纯节点：无<br>- 订阅模式：具备 DNS/证书权限的 Cloudflare API Token |
| **模式 2：直连+CDN兜底** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可）<br>- 3 个二级子域名（直连、CF 节点、订阅）<br>- 控制台手动开启 **Network → gRPC** | - Cloudflare API Token（仅限 DNS/证书编辑最小权限；将保存至 root 受控文件）<br>- Globalping Access Token |

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

> **注意**：按各模式提示准备的子域名由 `easy_all` 安装时自动通过 API 创建，**请勿提前手动添加 A 记录或 CNAME**。

---

## 2. 获取 Globalping Access Token

直连+CDN兜底依赖 [Globalping](https://dash.globalping.io/) 从中国大陆三网测速探针筛选最佳 CDN 优选 IP。

1. 打开 [Globalping Dashboard](https://dash.globalping.io/)，点击 **Sign in with GitHub** 登录。
2. 进入 [Tokens 页面](https://dash.globalping.io/tokens)，点击 **Generate a new token**。
3. 填写备注名称（如 `easy_all_cdn`），创建后复制生成的 Token。
4. 在安装交互提示 `Globalping Access Token` 时填入该 Token。

---

## 3. 创建 Cloudflare API Token

进入 Cloudflare 控制台：**My Profile → API Tokens → Create Token → Custom Token**。

### 3.1 权限配置
按模式添加对应权限：

| 权限项 | 适用模式 | 作用 |
| :--- | :--- | :--- |
| `Zone / Zone / Read` | 全部需要 CF 的模式 | 读取并确认目标 Zone 状态 |
| `Zone / DNS / Edit` | 全部需要 CF 的模式 | 自动添加/管理节点与回源解析记录 |
| `Zone / SSL and Certificates / Edit` | 全部需要 CF 的模式 | 自动申请与签发 Origin CA 证书 |

### 3.2 作用范围（Zone Resources）
- **Zone Resources**：`Include → Specific zone → 你的域名 (example.com)`

创建后妥善保存 Token，在安装交互提示 `Cloudflare API Token` 时粘贴。

> [!IMPORTANT]
> **直连+CDN兜底 Token 最小权限与持久化说明**：直连+CDN兜底为了支持后续证书到期轮换与免交互运维，输入的 Token 会以 root 受控权限（`0600`）保存于 `/etc/easy_all/cloudflare.token`。请务必遵循最小权限原则，仅授予目标 Zone 的 `DNS / Edit` 与证书编辑权限，严禁使用全局 Global API Key 或授予未使用的额外权限。

---

## 4. 模式 2：直连+CDN兜底（Reality + Cloudflare）域名规划

直连+CDN兜底将「直连 Reality」与「Cloudflare CDN 优选」部署在同一台 VPS 上，共需同一个 Cloudflare Zone 下的 3 个二级子域：

| 子域名示例 | 代理状态（云朵） | 用途说明 |
| :--- | :--- | :--- |
| `node.example.com` | 灰云（DNS only） | 直连 Reality 节点入口（客户端直连 VPS `8443` 端口） |
| `cf.example.com` | 橙云（Proxied） | Cloudflare CDN 优选入口与回源（客户端连接优选 IP 并带此 SNI/Host） |
| `sub.example.com` | 橙云（Proxied） | 统一订阅下载域名（提供自适应 Mihomo / Base64 配置） |

安装时只需输入根域名，上述 3 个二级子域直接回车即可使用推荐默认值自动创建。
