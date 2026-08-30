# Cloudflare CDN 精选 IP XHTTP 准备与架构

模式 2「Cloudflare CDN 精选 IP XHTTP」使用 Cloudflare 代理一个**单一的一级子域名**，例如
`node.example.com`。客户端连接精选 IPv4，TLS SNI 与 XHTTP Host 仍始终是
`node.example.com`；VPS 通过 Globalping 维护候选 IP 缓存，Mihomo 再在客户端网络中测速选优。

> Cloudflare 不是本项目旧 Worker 部署的兼容入口。本模式只使用 proxied DNS、Universal SSL、
> Origin CA、Full (strict)、HTTP/2/gRPC 与 Transform Rule，不创建 Worker。

## 架构与边界

```text
客户端 ── 精选 Cloudflare IPv4:443
          SNI / XHTTP Host: node.example.com
             │
             ▼
Cloudflare proxied DNS + Universal SSL + HTTP/2/gRPC
             │  Transform Rule: 固定 Origin Key
             ▼
VPS 防火墙（仅 Cloudflare IP 可到 443）
             │
             ▼
Nginx gRPC ── Xray 127.0.0.1:10086
```

安装器自动创建或更新唯一 proxied `A` 记录，使 `node.example.com` 指向 VPS 公网 IPv4；不要预先为
这个节点名创建 A、AAAA、CNAME 或第二个源站子域。客户端和订阅公开的是节点名或精选 IP，不能把 VPS
IP 当成客户端节点地址。

Cloudflare 边缘使用 Universal SSL；安装器为 `node.example.com` 自动签发并安装 15 年期
Cloudflare Origin CA 证书，之后可由 `easy_all renew-cert` 一站式轮换。它还为每个受管主机创建
host-scoped 的 **Full (strict)** 配置规则，不会覆盖其他
站点的 TLS 设置。不要使用 Flexible，也不要在源站回退 HTTP。Nginx 只接受带正确 `Host` 与 Origin
Key 的 Cloudflare 回源请求。

安装器自动将 origin HTTP/2 与 gRPC 设为启用，并创建精确匹配受管主机和 XHTTP 路径的 Transform
Rule，在回源请求中写入 `X-Easy-All-Origin-Key`。健康检查与订阅路径使用同一保护规则；Nginx 只接受
该值。此规则不是访问控制的替代：VPS 防火墙还必须按 Cloudflare 官方 IP 列表放行 TCP 443，并拒绝
其他来源直达 443。Cloudflare IP 范围更新时由 VPS 定期拉取并原子更新防火墙规则；不要手工长期维护
过期 CIDR。

## 1. 安装前只需准备 Zone 和名称

1. 在 Cloudflare 添加 `example.com` Zone，并在注册商把权威 NS 委派到 Cloudflare，等待 Zone 为
   **Active**。迁移前先保留现有网站和邮件所需的 DNS 记录。
2. 为节点选择 Zone 下的**一级子域名**，例如 `node.example.com`；独立订阅域名（如启用）也必须在
   同一个 Zone 下，且同样是一级子域名。
3. 仅创建下节的一枚 Zone-scoped API Token，然后运行安装器。

不要手工创建节点 A 记录、Origin CA 证书、Full (strict) 规则、gRPC/origin HTTP/2 设置或 Transform
Rule。安装器会创建或更新它们：DNS 中已有同名 AAAA 或 CNAME、多个同类型记录，或受管规则出现歧义
时会停止而不是猜测覆盖。它只按 easy_all 的稳定引用新增或更新对应规则，不会整体替换 phase ruleset，
因此会保留同一 ruleset 中的其他网站规则。

## 2. 一枚 Zone-scoped API Token

安装器只需要一枚限制到该 Zone 的 Token。打开 **My Profile → API Tokens → Create Token → Custom Token**，
资源选择 **Include → Specific zone → example.com**，并只授予：

| 权限 | 用途 |
| --- | --- |
| `Zone / Zone / Read` | 定位并验证目标 Zone |
| `Zone / DNS / Edit` | 创建或更新唯一 proxied A 记录 |
| `Zone / Transform Rules / Edit` | 创建或更新 Transform Rule（Origin Key） |
| `Zone / Config Rules / Edit` | 为受管主机设置 Full (strict) |
| `Zone / Zone Settings / Edit` | 启用 origin HTTP/2 和 gRPC |
| `Zone / SSL and Certificates / Edit` | 签发、轮换和撤销 Origin CA 证书 |

![Cloudflare API Token 的创建位置、六项最小权限与单 Zone 资源范围](cloudflare/cloudflare-api-token-easy-all.svg)

按图操作即可；图中的 `example.com` 要换成实际接入 Cloudflare 的根域名，而不是
`node.example.com`。创建流程如下：

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)，进入 **My Profile → API Tokens**，选择
   **Create Token**，再选择 **Custom Token**。
2. Token name 可填 `easy_all-cloudflare-zone`；在 **Permissions** 中逐项添加下表六项 `Zone` 权限，
   每项均选 `Edit`，只有 `Zone / Zone` 选 `Read`。
3. 在 **Zone Resources** 选择 **Include → Specific zone → 你的根域名**，不要选 **All zones**；不要添加
   Account、User、Billing、Workers 或 API Keys 权限。
4. 选择 **Continue to summary**，核对权限与 Zone 后选择 **Create Token**；立刻复制显示的 Token，回到
   安装器的 `Cloudflare API Token` 隐藏输入提示中粘贴。它不是 **Account ID**、**Zone ID**，也不是
   已弃用的 **Origin CA Key**。

这六项是该自动化所需的最小权限；不要改为 Account 范围、All zones 或 Global API Key。Token secret
只显示一次，安装器只在当前进程使用且不写入状态文件；应保存到密码管理器，不要写入脚本、Git、截图、
shell 历史或长期明文 `.env`。

## 3. Cloudflare 费用与 Free 计划边界

以 **2026-08-30** Cloudflare 公布的套餐和功能可用性为准：本模式所自动创建或启用的 Cloudflare
资源可以在 **Free** Zone 上使用，安装器本身不会开通付款方式、升级套餐或创建按量计费产品。

| 本模式实际使用的能力 | Free 是否可用 | 本项目的用量与注意事项 |
| --- | --- | --- |
| Full setup Zone、权威 DNS、proxied `A` 记录 | 是 | 需自有域名并把 NS 委派给 Cloudflare；**域名注册费不属于 Cloudflare Free Zone**。 |
| Universal SSL | 是 | 本项目只允许一级子域，正好处于 Free 全量接入 Zone 的 Universal SSL 覆盖范围。 |
| Cloudflare Origin CA、Full (strict) | 是 | Origin CA 仅供 Cloudflare 到 VPS 的回源 TLS，不能直接给浏览器使用。 |
| HTTP/2 to Origin、gRPC | 是 | gRPC 若同时主动启用 Argo、WAF/Bot Management 等付费附加产品，相关流量可能产生费用；本项目不启用它们。 |
| Request Header Transform Rule、Configuration Rule | 是 | Free 各最多 10 条；本项目通常各使用 1 条，启用独立订阅域名时最多各使用 2 条；不使用正则。 |
| Zone-scoped API Token、Cloudflare API 调用 | 是 | Token 不收费；本项目不授予 Billing 权限，无法通过该 Token 管理订阅或付款。 |

因此，按默认设计使用 Free Zone 时，Cloudflare 侧的上述功能**没有固定月费或按本项目流量自动计费项**。
仍可能发生的费用来自：域名注册/续费、VPS、用户自行升级 Pro/Business/Enterprise，或自行启用
Argo、Load Balancing、Advanced Certificate Manager、Cache Reserve、Workers、Spectrum 等付费产品。
Cloudflare 的服务条款、流量限制与风控仍独立适用，Free 并不等于保证任何流量形态都被接受。

官方参考：[套餐与价格](https://www.cloudflare.com/plans/)、
[Transform Rules 可用性](https://developers.cloudflare.com/rules/transform/)、
[Configuration Rules 可用性](https://developers.cloudflare.com/rules/configuration-rules/)、
[Origin CA 可用性](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)、
[gRPC 可用性与附加产品计费说明](https://developers.cloudflare.com/network/grpc-connections/)。

## 4. 精选 IP、缓存与回退

VPS 每小时以 Globalping 中国大陆探针对 `node.example.com` 进行 IPv4 TCP/443 测量；只保留完成且
`loss=0`、`drop=0`、`rcv=10` 的候选，随后以 `node.example.com` 作为 SNI/Host 请求健康检查复核。
结果按覆盖探针数和平均 RTT 排序，最多缓存 10 个。Mihomo 的 `url-test` 组再从客户端实际网络每
300 秒测速；候选比当前节点快至少 50 ms 时才切换，以减少来回抖动。切换仅影响后续新连接，不会
迁移已经建立的 XHTTP 会话，因此 VPS 的预筛不能替代客户端测速。

刷新失败时继续使用上次有效缓存；缓存超过 72 小时时订阅只输出原域名回退节点。缓存与 Token 均只应
保存在 root-only 本机文件中。精选 IP 只改变连接地址，绝不改变 SNI 或 XHTTP Host。

## 5. Cloudflare 使用限制与风险

Cloudflare 的服务条款、产品限制和可接受使用政策优先于本项目说明；部署前请自行确认自己的流量、
地区和账户适用性。不要把免费 CDN 当作无限制的通用 TCP 隧道服务。Free/Pro 计划的 proxied
请求上传体通常受 **100 MB** 限制（其他计划和功能的上限不同）；流式长连接、gRPC/XHTTP、空闲超时、异常高并发或持续
大流量都可能被边缘、网络策略或账户风控中断。

因此必须在目标客户端网络做连接、切网、低速和长连接测试，并保留自动重连能力。Origin Key、
Full (strict) 和只允许 Cloudflare IP 的防火墙是源站最低保护，不保证 Cloudflare 会接受任何特定用法。

官方参考：[代理状态](https://developers.cloudflare.com/dns/proxy-status/)、
[Origin CA](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)、
[Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)、
[gRPC](https://developers.cloudflare.com/network/grpc-connections/)、
[Transform Rules](https://developers.cloudflare.com/rules/transform/)、
[Cloudflare IP 地址](https://www.cloudflare.com/ips/)、
[连接和上传限制](https://developers.cloudflare.com/cache/concepts/default-cache-behavior/#limits)。
