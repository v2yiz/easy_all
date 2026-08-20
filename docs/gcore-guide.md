# Gcore 一次性准备指南（评审稿，尚未实现）

> **当前状态：仅供评审，不可用于部署。** easy_all 当前只实现了 AWS CloudFront CDN XHTTP
> 链路；本文件定义未来 Gcore Provider 的账号准备、权限边界与实现验收标准，不会启用或修改
> 任何 Gcore 资源。

本指南的目标是让未来的安装脚本只接收一项凭证：

```text
GCORE_API_TOKEN
```

源站、CDN 资源、HTTPS、DNS 记录与本机全局费用保护均应由脚本处理。用户仍需在域名注册商完成一次
权威 DNS 委派；这是 API Token 无法代替的外部权限边界。

> 不要把 API Token 写入脚本、Git、截图或聊天。不要使用拥有整个账号管理员权限的日常个人 Token。

## 1. 账号、Free 套餐与费用边界

在 Gcore 控制台左侧打开 **网络 → CDN**，确认侧栏显示 **方案：Free**。当前 Free CDN 套餐为
`€0/月`，包含每月 **1 TB** 流量和 **10 亿**请求；Gcore 当前说明 Free CDN 无需绑卡即可开始。

| 项目 | Free 范围 | 超出或额外启用后的边界 |
| --- | --- | --- |
| CDN 流量 | 1 TB/月 | `€0.030/GB`；100 GB 约 `€3.00` |
| CDN 请求 | 10 亿/月 | 超过后 `€0.75/百万次请求` |
| Managed DNS | Free 套餐列为 `€0/月`、无限查询 | 不启用 Pro、健康检查、GeoDNS 等付费能力 |
| WAAP | 不使用 | 创建 CDN 资源时出现的“免费 30 天试用”也不要勾选；试用结束后可能产生费用 |
| 税费与服务外成本 | 不包含 | Gcore 标价未含 VAT；VPS 和域名注册费用也不包含 |

因此，**不绑卡、保持 CDN/DNS Free 且不超额时，Gcore 侧预计为 €0**；它不是“无限量且永远零费用”。
不要手动切换到付费 CDN 方案、开通 WAAP 或保存支付方式来允许超额。

未来实现会沿用当前 AWS 方案的保守思路：默认在 VPS 本机累计 Xray 用户流量，并在 **980 GB**
时阻断 CDN XHTTP 节点，给 1 TB 留出 20 GB 缓冲。该保护尚未实现，且本机统计不能等同于 Gcore
账单；在实现、测试并验证前，不能把它视为 Gcore 侧的硬性消费上限。

Gcore 官方参考：
[CDN 与 Managed DNS 定价](https://gcore.com/pricing/edge-network)、
[Free CDN 无需绑卡](https://gcore.com/cdn)。

## 2. 一次性委派整个主域名 DNS

为了让后续脚本能通过同一枚 Token 自动创建源站和 CDN 记录，本方案只采用**整个主域名**交给
Gcore Managed DNS 的方式；不提供“仅委派一个子域名”的第二条流程。

以 `origin.example.com`（VPS 源站）和 `node.example.com`（Gcore CDN 节点）为例：

1. 在 **网络 → Managed DNS → 所有区域 → 添加区域** 输入 `example.com`。
2. 向导会依次显示“输入域 → 正在扫描记录 → 检查记录 → 更改域名服务器”。先让它扫描现有记录，
   并核对 A/AAAA/CNAME、MX/TXT、SPF、DKIM、DMARC 与 CAA 均被保留。
3. 从最后一步复制 Gcore 提供的权威名称服务器（NS）。
4. 在域名注册商的 Nameservers 页面，将 `example.com` 的现有 NS 完整替换为这些 Gcore NS。
5. 等待委派生效，再进行未来的脚本安装。

主域名已启用 DNSSEC 时，先按注册商要求移除旧 DNS 服务商对应的 DS 记录；在 Gcore 的 DNSSEC
链路完全就绪后再重新启用。不要同时保留多个同名 Zone，也不要在原 DNS 和 Gcore DNS 分别维护
相同记录。

> **手动一次，后续自动。** 委派完成后，未来脚本应写入 `origin.example.com` 的源站 A 记录、
> `node.example.com` 指向 Gcore 分配域名的 CNAME，以及 Gcore 托管的证书验证所需记录。无需手动
> 创建这些节点记录；脚本也不迁移、删除或接管既有业务记录。

Gcore 控制台当前在创建 CDN 资源时提供“将您的 DNS 区域委托给 Gcore”和“不委托”两个选项；本设计
只选择前者。`node.example.com` 必须是子域名，因为 CDN 会为其分配 CNAME 目标；不要将根域名
`example.com` 用作该 CNAME。

Gcore 官方参考：
[创建和管理 DNS Zone](https://gcore.com/docs/dns/manage-a-dns-zone)、
[使用自定义域名创建 CDN 资源](https://gcore.com/learning/cut-egress-costs)。

## 3. 创建最小权限 API Token

在个人资料中的 **API tokens → Create token** 创建专用于 easy_all 的永久 API Token。建议名称为
`easy_all_gcore`，为其所属自动化身份只分配以下可写角色：

| 角色 | 未来脚本用途 |
| --- | --- |
| `CDN Editor` | 读取、创建和更新源组、CDN 资源、缓存规则、源站 HTTPS 与 Gcore 证书设置 |
| `DNS Editor` | 读取 Zone、创建或更新源站 A 与节点 CNAME 记录 |

不要授予 `Account Administrator`、`WAAP Editor`、Cloud、Storage 或 Streaming 权限。Viewer 角色只可读，
不能完成资源创建或更新。若控制台将权限分配给身份而非单枚 Token，应先把上述两个角色赋给专用身份，
再为它创建 Token；不要为了“只用一枚 Token”而放宽为全账号管理员。

Token 只会在创建时完整显示一次。立即存入密码管理器，未来仅向安装脚本提供：

```text
GCORE_API_TOKEN
```

如设置有效期，应在到期前轮换；不要把个人登录密码、刷新 Token、充值信息或项目 ID 交给脚本。

Gcore 官方参考：
[API Token 与最小角色](https://gcore.com/docs/developer-tools/mcp-server/gcore-mcp-server-overview)、
[创建永久 API Token](https://gcore.com/blog/permanent-api-token-explained)。

## 4. 未来脚本的受限自动化范围

以下是待实现的目标流程，用于评审权限是否足够；它**不是当前版本已具备的功能**。

| 阶段 | 未来脚本应执行的操作 | 需要的角色 |
| --- | --- | --- |
| 预检 | 验证 Token、确认 CDN 和 DNS 均为 Free、定位已委派的 Public Zone | CDN Editor、DNS Editor |
| 源站 | 读取 VPS 公网 IPv4，创建或更新 `origin.example.com` 的 A 记录 | DNS Editor |
| CDN | 创建专属源组和 CDN 资源；源站使用 HTTPS，Host 覆盖为 `origin.example.com` | CDN Editor |
| 节点域名 | 读取 Gcore 分配的 `*.gcdn.co` 目标，创建或更新 `node.example.com` CNAME | CDN Editor、DNS Editor |
| TLS | 为 `node.example.com` 启用 Gcore 免费 Let's Encrypt 证书，并等待证书与资源可用 | CDN Editor |
| 成本保护 | 开启本机 980 GB、UTC 自然月重置的全局保护；不创建 WAAP、付费套餐或支付方式 | 本机，不调用付费 API |
| 验收 | 验证 DNS、HTTPS、回源、订阅和 XHTTP 连通性；失败时恢复本机配置，不删除用户既有 DNS 记录 | CDN Editor、DNS Editor |

源站必须继续使用 HTTPS 和独立的 `origin.example.com` 证书；Gcore 的边缘证书只服务
`node.example.com`。Gcore 免费 Let's Encrypt 证书依赖自定义域名 CNAME 已生效，证书由 Gcore
托管并自动续期。

Gcore 官方参考：
[Gcore 免费 Let's Encrypt 证书](https://gcore.com/learning/tls-on-cdn)、
[源站协议和 Host Header](https://gcore.com/docs/cdn/cdn-resource-options/general/specify-an-origin-and-the-origin-pull-protocol)。

## 5. XHTTP 兼容性：实现前必须通过的门槛

Gcore 公开资料说明 CDN 支持 HTTP/2，也提供 V2Ray over WebSocket 的示例；这**不足以证明**它适合
本项目的 VLESS XHTTP stream-up/H2 回源链路。当前没有可作为结论依据的 Gcore 官方 XHTTP 或
gRPC 兼容性说明，因此在下面的真实测试通过前，不应开始 Provider 实现或把 Gcore 用于生产节点。

必须在独立测试域名上验证：

1. `node` 自定义域名 CNAME、生效的免费边缘证书，以及到 `origin` 的 HTTPS/SNI/Host Header。
2. XHTTP `stream-up` 长连接在正常使用、低速和网络切换时均能稳定工作，不出现 CDN 超时或协议降级。
3. XHTTP 路径、订阅路径和健康检查均**禁止缓存**；请求参数、必要请求头和响应不会被 CDN 合并、裁剪或
   复用。Gcore 明确提醒动态请求若缓存配置错误可能返回错误内容。
4. CDN 回源不会暴露源站 IP，且源站仍拒绝没有 easy_all Origin Key 的直接访问。
5. 980 GB 保护、UTC 月初恢复和 Gcore 流量报表的偏差处于预期缓冲范围内。

任一项失败即停止该 Provider 方案，不以更宽泛的权限、关闭 TLS 或绕开访问控制来“兼容”。

Gcore 官方参考：
[CDN 动态内容缓存边界](https://gcore.com/learning/dynamic-cdn-cache-rules)、
[Gcore HTTP/2 与 WebSocket 能力](https://gcore.com/cdn)、
[Gcore 的 V2Ray WebSocket 示例](https://gcore.com/learning/v2ray-websocket)。

## 6. 评审结论与非目标

选择这条路线后，用户手动完成的只有：注册 Gcore、保持 Free、委派整个主域名，以及创建最小权限
Token。后续脚本才会负责节点记录和 CDN 配置。

本设计明确不做以下事情：

- 不绑信用卡，不变更 CDN 到付费方案，不接受 WAAP 试用，也不允许脚本调用充值或订阅 API。
- 不接管仅一个子域名，不要求用户手动写节点 A/CNAME 或证书记录。
- 不复用 AWS Access Key、Route 53、ACM 或 CloudFront 资源。
- 在 XHTTP 兼容性实测前，不宣称 Gcore 已被 easy_all 支持。
