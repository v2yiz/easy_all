# Gcore 一次性准备指南

> **当前状态：已实现 Gcore CDN XHTTP 安装链路。** 在 `easy_all install` 中选择第 3 项
> “Gcore CDN - XHTTP”。本指南只说明你在 Gcore 控制台和域名注册商需要完成的一次性准备；
> 安装器会处理 VPS 上的源站、DNS 记录、CDN、边缘证书和本机费用保护。

安装器只会要求你提供一项凭证：

```text
GCORE_API_TOKEN
```

不要将 Token 写入脚本、Git、截图或聊天记录。也不要使用日常个人管理员 Token。

## 1. 保持 Free CDN，并了解费用边界

在 Gcore 控制台的 **网络 → CDN** 中确认使用的是 **Free** 方案。当前 Free CDN 标注为
`€0/月`，包含每月 **1 TB** 流量和 **10 亿**请求；Gcore 说明 Free CDN 可以不绑卡开始使用。

| 项目 | Free 范围 | 超出或另行开通的边界 |
| --- | --- | --- |
| CDN 流量 | 1 TB/月 | 标价 `€0.030/GB`；100 GB 约 `€3.00` |
| CDN 请求 | 10 亿/月 | 标价 `€0.75/百万次请求` |
| Managed DNS | Free 套餐列为 `€0/月`、无限查询 | 不启用 Pro、健康检查、GeoDNS 等额外功能 |
| WAAP | 不使用 | 创建资源时出现的“免费 30 天试用”也不要勾选 |
| 税费与服务外成本 | 不包含 | 标价未含 VAT；VPS 和域名注册仍由你承担 |

安装器不绑定信用卡、不创建 WAAP、不切换付费 CDN 方案，也不调用充值或订阅 API。它会在 VPS
本机统计 Xray 用户流量，并在 **980 GB** 时阻断 Gcore CDN XHTTP 节点，给 1 TB 留出 20 GB
缓冲；账期按 UTC 自然月重置。这个保护不等于 Gcore 的精确账单，也不能按请求次数精确限额，
因此不能替代你在控制台保留 Free 方案和定期查看用量。

官方参考：[CDN 与 Managed DNS 定价](https://gcore.com/pricing/edge-network)、
[Free CDN](https://gcore.com/cdn)。

## 2. 委派整个主域名到 Gcore Managed DNS

为了让后续安装器只用一枚 Token 自动创建源站和 CDN 记录，本方案只采用**整个主域名**交给
Gcore Managed DNS 的方式；源站域名和 CDN 域名必须命中同一个 Gcore Managed DNS Zone，不提供
“仅委派一个子域名”的分支。可选的独立订阅链接域名也必须由 Gcore Managed DNS 托管；它可以位于
另一个已完成权威委派、且当前 Token 有权管理的 Gcore Zone，不能留在其他 DNS 服务商。

例如使用 `origin.example.com` 作为 VPS 源站、`node.example.com` 作为 CDN 节点：

1. 在 **网络 → Managed DNS → 所有区域 → 添加区域** 中添加 `example.com`。
2. 让向导扫描现有记录，并核对 A/AAAA/CNAME、MX/TXT、SPF、DKIM、DMARC 与 CAA 已完整保留。
3. 复制 Gcore 显示的权威名称服务器（NS）。
4. 到域名注册商的 Nameservers 页面，将 `example.com` 的现有 NS 完整替换为 Gcore 的 NS。
5. 等待委派生效后再安装；安装器会通过 Gcore API 验证它已是唯一权威 DNS。

主域名已启用 DNSSEC 时，先按注册商要求移除旧 DNS 服务商的 DS 记录；在 Gcore DNSSEC 链路
完全就绪后才重新启用。不要同时保留多个同名 Zone，也不要在原 DNS 与 Gcore DNS 分别维护同一记录。

> **手动一次，后续自动。** 委派完成后，安装器会先确认 `origin.example.com` 和
> `node.example.com` 都归属同一个 Gcore Zone，再创建或更新 `origin.example.com` 指向 VPS 公网
> IPv4 的 A 记录，并把 `node.example.com` 写为 Gcore CDN 分配目标的 CNAME；无需手动创建这些
> 节点记录。若选择独立订阅域名，安装器会把它加入同一 CDN 资源并处理对应 CNAME：已有且正确则
> 直接复用，完全缺失才新增，已有其他解析时停止。它不会创建 Zone、修改注册商 NS、迁移业务记录
> 或静默覆盖冲突记录。

节点域名必须是子域名，不能使用根域 `example.com`：Gcore CDN 为自定义域名分配 `*.gcdn.co`
目标，节点记录必须以 CNAME 指向该目标。官方参考：[创建和管理 DNS Zone](https://gcore.com/docs/dns/manage-a-dns-zone)、
[使用自定义域名创建 CDN 资源](https://gcore.com/learning/cut-egress-costs)。

## 3. 创建一枚最小权限 API Token

在个人资料中的 **API 令牌 → 创建** 为 easy_all 新建一枚专用 Token。建议名称
`easy_all_gcore`；描述可填“easy_all Gcore CDN + Managed DNS 部署”。

**权限边界：** 安装器只调用 Gcore 的 CDN 与 Managed DNS 接口，用于管理源组、CDN 资源、边缘证书、
DNS Zone 和节点记录；它不调用账户、用户、账单、Cloud、Storage 或 Streaming 接口。因此 Token 必须具备
CDN 资源的读取/创建/更新权限，以及 Managed DNS Zone 和记录的读取/写入权限；不需要 IAM 的用户或账户管理权限。

![Gcore 官方控制台：创建 API 令牌、有效期与权限展示](gcore/gcore-api-token-create.png)

按图操作：

1. 在左侧选择 **API 令牌**，点击右上角 **创建**。
2. 填写名称 `easy_all_gcore`。描述为可选项。
3. 有效期建议选“设置过期日期”，设为一年并在密码管理器中设置轮换提醒；仅在已有严格密钥轮换流程时才选择“永不过期”。
4. **不要尝试在此页勾选角色。** 控制台会根据当前登录身份已有的 IAM 权限自动带入角色；截图中的
   **IAM / CDN → 工程师** 与 **Managed DNS → 管理员** 是该账号当前的继承状态，单选项无法点击是正常现象。
   Gcore 未公开“工程师”与 CDN 写入 API 的逐接口对应表，**“工程师”并不等同于已验证的 CDN 写入权限**。
   创建前请让账户管理员确认该身份可管理 CDN 源组、CDN 资源和边缘证书，以及 Managed DNS 的 Zone 和记录。
5. 点击 **创建** 后，立即将完整 Token 保存进密码管理器。该值只会显示一次。

项目中所说的功能范围对应 CDN 与 DNS 的编辑权限：

| 角色 | 安装器用途 |
| --- | --- |
| `CDN Editor` | 读取、创建和更新源组、CDN 资源、源站 HTTPS、缓存规则和 Gcore 证书 |
| `DNS Editor` | 读取 Zone，创建或更新源站 A 与节点 CNAME |

不要通过授予整个 **IAM / CDN** 的“管理员”、WAAP、Cloud、Storage 或 Streaming 来绕过权限不足。
Token 页面不能提升权限；请让账户管理员在 **账户的用户/IAM 权限管理页面** 为专用身份授予 CDN
资源读写与 Managed DNS Zone/记录读写权限。重新登录或刷新“创建 API 令牌”页面后，所需角色会自动带入，再创建 Token。

安装器会先读取 `/cdn/resources` 与 `/dns/v2/zones` 验证 Token；后续还需要创建或更新
`/cdn/origin_groups`、`/cdn/resources`、`/cdn/sslData` 和 DNS 记录。因此只有这两个读取接口通过，仍不能证明
Token 具备全部部署权限；若需要在正式安装前确认角色范围，请由 Gcore 账户管理员或 Gcore 支持按这些 API
操作核对该身份的实际授权。

安装时输入 `GCORE_API_TOKEN` 后，它仅存在于当前进程，不会写入 `/etc/easy_all/state.env`。如设置有效期，
在到期前轮换即可。

官方参考：[API Token 与最小角色](https://gcore.com/docs/developer-tools/mcp-server/gcore-mcp-server-overview)、
[永久 API Token](https://gcore.com/blog/permanent-api-token-explained)。

## 4. 安装器实际会做什么

在选择 Gcore CDN XHTTP 后，安装器按以下边界工作：

| 阶段 | 安装器操作 | 所需角色 |
| --- | --- | --- |
| 预检 | 验证 Token 的 CDN/DNS 访问、定位覆盖源站域名的 Zone，确认整域名 NS 委派 | CDN Editor、DNS Editor |
| 源站 | 读取 VPS 公网 IPv4，写入源站 A；冲突 A/AAAA/CNAME 默认停止 | DNS Editor |
| CDN | 创建或更新专属源组和 CDN 资源；可选订阅域名写入 secondary hostname；强制 HTTPS 回源、源站 Host/SNI 和 Origin Key | CDN Editor |
| 节点与订阅域名 | 读取 CDN 目标；节点 CNAME 保持原有冲突策略，独立订阅 CNAME 仅在缺失时新增、正确时复用、冲突时拒绝覆盖 | CDN Editor、DNS Editor |
| TLS | 等待所有 CNAME 生效，预验证并启用覆盖当前 CDN 域名的 Gcore 免费 Let's Encrypt 边缘证书 | CDN Editor |
| 成本保护 | 在本机启用 980 GB、UTC 自然月的全局保护；不创建 WAAP、付费套餐或支付方式 | 本机 |
| 验收 | 验证 DNS、HTTPS 和带 Origin Key 的 CDN 回源健康检查 | CDN Editor、DNS Editor |

源站继续使用独立的 `origin.example.com` HTTPS 证书；Gcore 的边缘证书服务
`node.example.com` 以及可选的独立订阅域名。动态链路的边缘与浏览器缓存都设置为 `0s`，并保留
查询参数；源站只接受
包含 `X-Easy-All-Origin-Key` 的 CDN 请求。

生成的 Mihomo XHTTP 节点固定使用 `ip-version: ipv6-prefer`，优先连接 Gcore IPv6 边缘并在
IPv6 不可用时回退 IPv4；Mihomo 模板同时关闭 `unified-delay`，避免 XHTTP 上下行分离被统一延迟
探测误判。此策略与 VPS 是否有 IPv6 无关。Gcore CNAME 目标仍可发布 A/AAAA。源站回源继续使用
独立 IPv4 A 记录；VPS 到普通目标使用自动双栈，Gemini 相关域名保持固定 IPv4 出口。

## 5. 上线前的实际连通性检查

安装器可验证 DNS、边缘 HTTPS 和 HTTP 回源，但无法代替真实客户端网络的长期 XHTTP 测试。首次
上线后，请用目标客户端确认：

1. 节点可以连接，订阅可更新；节点使用 CDN 节点域名，订阅使用安装时选定的节点域名或独立订阅域名。
2. 正常使用、低速连接、网络切换和较长连接不会出现 CDN 超时或协议降级。
3. XHTTP 路径、订阅路径与健康检查没有被缓存、合并或裁剪。
4. 源站不会接受缺少 Origin Key 的直接请求。
5. 980 GB 阻断与下一个 UTC 自然月恢复符合预期；它仍与 Gcore 用量报表保留缓冲差异。

Gcore 的默认源站读取超时为 30 秒、HTTP/2 空闲超时为 15 秒，安装器会将该 Provider 的 XHTTP
`stream-up` 服务端窗口设为 `10-14` 秒，并把客户端 H2 PING 设为 10 秒，避免默认 45 秒 PING
晚于 Gcore 空闲断连。CDN 资源同时显式启用 gRPC passthrough。若任一项不稳定，应先停用该节点
进行排查，不要通过关闭 TLS、缓存动态请求或放宽 Origin Key 来“兼容”。

官方参考：[动态 CDN 缓存边界](https://gcore.com/learning/dynamic-cdn-cache-rules)、
[Gcore TLS on CDN](https://gcore.com/learning/tls-on-cdn)。

## 6. 非目标

- 不绑定信用卡，不创建 WAAP，不启用付费 CDN 或支付方式。
- 不要求你在 VPS 上手工创建 DNS/CDN/证书，也不接管仅一个子域名。
- 不复用 AWS Access Key、Route 53、ACM 或 CloudFront 资源。
- 不把本机 980 GB 统计宣称为 Gcore 侧的精确硬额度。
