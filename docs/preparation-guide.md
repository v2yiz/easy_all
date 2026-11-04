# 前置准备手册

本手册介绍使用 `easy_all` 部署各个模式前，需要在域名注册商、Cloudflare 和 Globalping 准备的资源与凭证。

> Bunny 模式的前置准备、Pull Zone 绑定与运维详见独立的 [Bunny 前置准备手册](bunny-preparation-guide.md)。

---

## 0. 各模式资源准备一览表

| 模式 | 必须准备的资源 | 核心凭据 / Token |
| :--- | :--- | :--- |
| **模式 1：直连 Reality** | - 纯节点（`link`）：仅需公网 IPv4 VPS，无其他要求<br>- 本机订阅（`deploy`）：需 1 个二级子域名（如 `sub.example.com`）<br>- Worker 聚合（`worker`）：需 2 个二级子域名（公开订阅域名 + 私有源域名） | - 纯节点：无<br>- 订阅模式：具备 DNS/证书权限的 Cloudflare API Token |
| **模式 2：Cloudflare CDN** | - 已托管至 Cloudflare 的域名 Zone（Free 方案即可）<br>- 2 个二级子域名（节点域名如 `node.example.com` + 订阅域名如 `sub.example.com`）<br>- 控制台手动开启 **Network → gRPC** | - Cloudflare API Token（含 Workers 编辑权限）<br>- Globalping Access Token |
| **组合模式** | - 已托管至 Cloudflare 的域名 Zone<br>- 3 个二级子域名（直连、CF 节点、订阅） | - Cloudflare API Token（DNS/证书编辑权限）<br>- Globalping Access Token |

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

> **注意**：子域名（如 `node.example.com`、`sub.example.com`）由 `easy_all` 安装时自动通过 API 创建，**请勿提前手动添加 A 记录或 CNAME**。

---

## 2. 获取 Globalping Access Token

Cloudflare 模式与组合模式依赖 [Globalping](https://dash.globalping.io/) 从中国大陆三网测速探针筛选最佳 CDN 优选 IP。

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
| `Zone / Config Rules / Edit` | 模式 2、组合模式 | 自动设置 SSL 为 Full (strict) |
| `Zone / Transform Rules / Edit` | 模式 2 | 管理 XHTTP 回源防探测密钥规则 |
| `Zone / Zone Settings / Edit` | 模式 2 | 自动开启 origin HTTP/2 |
| `Account / Workers Scripts / Edit` | 模式 2、模式 1 (worker 聚合) | 自动部署与管理订阅 Worker |

### 3.2 作用范围（Zone Resources）
- **Account Resources**：`Include → Specific account → 你的账号`
- **Zone Resources**：`Include → Specific zone → 你的域名 (example.com)`

创建后妥善保存 Token，在安装交互提示 `Cloudflare API Token` 时粘贴。

---

## 4. 组合模式（直连 Reality + Cloudflare）域名规划

组合模式将「直连 Reality」与「Cloudflare CDN 优选」部署在同一台 VPS 上，共需同一个 Cloudflare Zone 下的 3 个二级子域：

| 子域名示例 | 代理状态（云朵） | 用途说明 |
| :--- | :--- | :--- |
| `node.example.com` | 灰云（DNS only） | 直连 Reality 节点入口（客户端直连 VPS `8443` 端口） |
| `cf.example.com` | 橙云（Proxied） | Cloudflare CDN 优选入口与回源（客户端连接优选 IP 并带此 SNI/Host） |
| `sub.example.com` | 橙云（Proxied） | 统一订阅下载域名（提供自适应 Mihomo / Base64 配置） |

安装时只需输入根域名，上述 3 个二级子域直接回车即可使用推荐默认值自动创建。
