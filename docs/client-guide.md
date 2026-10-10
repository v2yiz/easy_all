# 客户端使用指南

easy_all 生成标准 Mihomo（Clash Meta）订阅。安装完成后运行：

```bash
sudo easy_all subscription
```

复制带 `flag=clash` 的 Mihomo 地址，在客户端的“从 URL 导入”位置添加并启用。
订阅地址和 UUID 都是访问凭据，不要公开。

## 客户端选择

| 平台 | 推荐客户端 |
| --- | --- |
| Windows | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases) |
| macOS | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases) |
| Android | [Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid/releases) |
| iOS / iPadOS | [Clash Mi](https://clashmi.app/download) |
| Linux | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Mihomo Core](https://github.com/MetaCubeX/mihomo/releases) |

请从官方发布页或应用商店下载与操作系统、CPU 架构匹配的版本。

Cloudflare 精选 IP 订阅按 Mihomo 的配置格式和 XHTTP 能力生成。客户端必须能分别保存：

- Cloudflare IPv4 节点地址；
- TLS SNI；
- HTTP Host；
- VPS 节点的 XHTTP `stream-up` 参数，以及可选纯 Worker 兜底节点的 `stream-one` 参数。

“能导入”不代表所有节点都能连接。Shadowrocket 的更新记录虽然包含 XHTTP 和
`stream-up` 修复，但未逐项确认上述字段和 `stream-one` 的完整兼容性，因此目前不把 Shadowrocket 列为
本项目的已验证客户端。

## Clash Mi 模式

日常使用“规则”模式即可。订阅会让中国大陆流量直连，境外网站和 AI 服务经 `PROXY`。
在 `PROXY` 中直接选择 US_VMISS、白天首选、晚上首选、🇭🇰CF 或其他已配置的节点。
白天首选和 🇭🇰CF 是隐藏的自动测速组，仍可作为 PROXY 选项；内部节点不平铺。
YouTube 与其他代理流量统一使用当前选择。纯 Worker 通过原生流背压支持持续下载，但
`stream-one` 的全部上行位于单个 HTTP 请求体内，仍受 Cloudflare 套餐请求体大小限制；
大文件上传应在 `PROXY` 中选择 VPS 节点。
规则模式下，代理流量的 UDP/443 始终优先拒绝以回退 TCP，手动选择出口不会绕过这一策略。

订阅显式定义 `GLOBAL → PROXY`。切换到“全局”模式后，Mihomo 忽略域名和 GeoIP 分流规则，
所有被接管的流量使用 `PROXY` 当前选择，无需再操作 `GLOBAL`。TUN 排除的局域网 IPv4 地址
仍保持本地直连。

## 局域网 DNS 与直连覆盖

私有域名默认交给客户端系统 DNS 解析并返回真实 IP，本机 hosts 生效。COMMON 的 DNS、Fake-IP
例外和直连规则共用 `private-fallback` 与 `geosite-private`；其中 `.lan`、`.local`、`.internal`、
`.localdomain`、`.localhost`、`home.arpa` 和 `localhost` 内联，首次规则下载失败仍可用。
经典模板使用 `geosite:private`。若 `nas.lan` 等名称仍无法解析，在客户端 DNS 覆写中把
对应策略（COMMON 为 `rule-set:private-fallback,geosite-private`）指向实际局域网 DNS，如路由器地址；
不要使用 Mihomo 自己的 DNS 监听地址，避免解析循环。
Clash Meta for Android 可使用 `dhcp://system` 获取系统 DNS；其他客户端按其 DNS 覆写能力设置。
公共模板不写死网关地址，切换网络后应检查该覆盖是否仍适用。

订阅不再按 v2ray、xray、Surge 等进程名无条件直连。如需管理 VPS 或串联其他代理，
在客户端添加目标地址的精确直连规则；不要将所有 SSH 端口或下载器进程一律直连。

## Clash Party 与微信图片

模板使用 `fake-ip-filter-mode: blacklist`，避免 Clash Party 接管 DNS 后把内置的 `*`
过滤项误当成规则模式。COMMON 与经典模板均让微信的图片、头像和小程序资源域名使用国内 DNS、
返回真实 IP 并直连。COMMON 的 `wechat-services` 同时用于这三处，包含 `qpic.cn`、`qlogo.cn`、
`servicewechat.com` 等精确后缀，不依赖远程规则下载。

COMMON 与经典模板均让未匹配策略且确需真实解析的公网域名使用经代理的海外 DNS，避免国内
DNS 返回的错误中国 IP 触发直连。COMMON 的国内常用服务和 Apple 使用国内 DoH；代理节点
单独使用国内 DoH 引导解析，不依赖代理本身。
更新订阅后应重启代理内核以清除旧 Fake-IP 和 DNS 缓存；无需清除应用数据。

## Android 打开 App 才收到消息

Telegram 等 App 前台正常、后台不推送时，先检查 Google FCM 推送通道。模板让
FCM 域名返回真实 IP（COMMON 内联 12 个 mtalk 端点，经典模板使用 `geosite:googlefcm`）；
进入代理内核的 TCP 5228–5230 流量走 `PROXY`
（局域网仍直连），避免无域名的推送连接落入国内 IP 直连规则。FCM 的 443 回退和注册请求
继续使用现有 Google 代理规则及代理 DNS。

更新服务器订阅规则后，在客户端刷新订阅并重启代理内核。Worker 的模板在构建时内嵌，
仅修改仓库文件或刷新客户端不会更新云端；安装器部署的订阅按[运维指南](operations-guide.md#更新与应用)
运行 `self-update` 和 `update-sub`，独立 Worker 则重新构建并部署。

Bettbox 还需检查以下设置（订阅无法替客户端修改这些开关）：

- 关闭“允许绕过 VPN”，并让 Google Play 服务（`com.google.android.gms`）参与 VPN；
  仅代理 Telegram 的应用白名单不能覆盖系统推送。
- 如启用了智能启停或休眠，先关闭，确保锁屏后内核继续工作；允许 Bettbox 与 Google Play 服务后台运行。
- 如果启用了 DNS 覆写，确认最终配置保留完整 FCM 真实 IP 例外。重新连接网络或重启手机，
  让旧 DNS 缓存和推送连接失效；不要清除 Google Play 服务的数据。

验收时把 Telegram 切到后台并锁屏，请另一台设备发送消息；在 Bettbox 连接记录中检查
`mtalk.google.com` / `alt*-mtalk.google.com` 或 TCP 5228–5230 是否经 `PROXY` 建立连接。
如没有连接记录，优先检查 VPN 绕过、应用分流和系统后台限制。

依据：[Google FCM 网络与 VPN 说明](https://firebase.google.com/docs/cloud-messaging/network-configuration)。

## 低内存客户端（旧款 iPhone）

默认订阅模板 `templates/mihomo.yaml` 就是 COMMON 精简规则：小型内联集合加 Apple 国内调度、Google、私有
域名、Telegram 和中国 IP 的五个 MRS 规则集。安装器、Worker 构建和本机订阅都会直接使用它，
不需要任何额外参数。不加载整库 DAT，也不加载大型国内/境外域名库。

代理服务、国内常用服务、Apple 国内调度、局域网和 Telegram IP 的基础规则内联，首次下载失败仍可用；
成功下载的 MRS 扩充覆盖，更新失败保留可用缓存。下载体积有上限，但它不是运行内存上限。
代理服务共用 DNS、路由和 QUIC 集合，QUIC 拒绝先于代理匹配，国内直连仍可使用 QUIC。
微信资源共用 DNS、真实 IP 与直连集合；Steam 仅下载域名 `steamcontent.com`、`cm.steampowered.com`、
`steamserver.net` 使用国内 DNS 并直连，`steamcommunity.com` 仍走代理。完整版中这些例外优先于通用境外域名集合。
Apple 仅国内调度集合与少量精确兜底域名使用国内 DNS 并直连，不再整域直连 Apple、iCloud 或 Apple CDN；
其他 Apple 域名按普通域名/IP 规则分流。`swcdn.apple.com` 属于国内调度集合，仍保持直连。
三套模板均在 LAN 规则之前以 `no-resolve` 拒绝 `0.0.0.0/8`，保护直接以零地址发起的连接。
COMMON 关闭 `tcp-concurrent` 以降低并发握手开销，并将 UDP NAT 空闲超时设为 60 秒以更早回收空闲映射；
空闲映射过期后，后续通信可能需要重建映射，不代表活跃 UDP 会话每分钟被强制中断。
保留 `store-fake-ip: true` 用于跨重启复用 Fake-IP 映射，不把持久化本身作为降低内存的手段。
COMMON 不启用嗅探：应用自行使用 DoH 或直接连接真实 IP 时，如果内核没有域名或 DNS 映射，
即使该域名已收录也无法按域名分流；此时按 IP、端口及最终兜底规则处理，境外服务使用中国 IP 时可能直连。
应结合客户端连接记录验证这类应用，是否启用嗅探需同时评估设备内存。

50MB 是优化目标，不是 iOS 峰值保证。macOS RSS 与 iOS 网络扩展占用不能直接等同；节点数量、
客户端内核、TUN、DNS 缓存和并发连接都会影响实际峰值。旧款 iPhone 必须用实际客户端测试
冷启动、规则更新和并发流量；仅通过 `mihomo -t` 不能证明规则已加载或内存达标。

此前的本机基线：mihomo v1.19.32 darwin-arm64，加载真实 MRS，关闭 TUN，回环 DNS 与 REJECT
模拟出站，启动及分流探测期间每 50ms 采样 RSS；精简版观察到峰值约 39 MiB，完整版约 46 MiB。
该样本早于微信与 Steam 内联规则及 Apple 国内子集调整，也不是真实代理握手、长时间并发流量或 iPhone 网络扩展的峰值测试。

需要更多规则或换回旧设计时，在发布命令前加 `MIHOMO_TEMPLATE_SOURCE`：

| 模板 | 规则覆盖 | 内存取舍 |
| --- | --- | --- |
| `templates/mihomo.yaml`（默认） | 国内常用域名直接分流，其余由中国 IP 兜底 | 最低规则开销，iOS 峰值待实测 |
| `templates/mihomo-common.yaml` | 精简版加国内域名、境外域名两套 MRS | 覆盖更全，但不作为 50MB 首选 |
| `templates/mihomo-classic.yaml` | 经典 geodata 模式与完整国内 DNS 分流 | 整库 Geo 数据开销更大 |

精简版的代价：未收录国内域名经海外 DNS 查询，可能得到境外 CDN 并走代理；远程中国 IP
规则不可用时，未命中基础域名集合的国内流量也保守走代理，不承诺完整国内直连覆盖。
需要完整覆盖时选完整版或经典模板。FCM 端口兜底仍会影响其他 TCP 5228–5230 应用；共享的
Auth0、Stripe、Intercom 等服务仍整体代理，可按实际日志收窄 `proxy-services`。

实现参考：[Mihomo 示例](https://wiki.metacubex.one/example/conf/)、
[DNS 分流](https://wiki.metacubex.one/config/dns/)、
[规则集与 MRS](https://wiki.metacubex.one/config/rule-providers/)及
[Loyalsoldier 常用规则](https://github.com/Loyalsoldier/clash-rules)。与原始配置不是逐条等价：
移除了宽泛域名关键字，修正 JetBrains Grazie 拼写，取消 `ssl.gstatic.com` 单独直连，补充常用代理服务。

```bash
sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo-common.yaml easy_all update-sub
```

Cloudflare 聚合 Worker 会重新构建并内嵌所选模板，改用
`sudo MIHOMO_TEMPLATE_SOURCE=... easy_all apply-cloud` 即可让所有客户端生效。自定义模板路径
同样通过 `MIHOMO_TEMPLATE_SOURCE` 传入（本地文件或 HTTPS URL）；仓库内置模板已在 CI 用固定
内核校验，其他来源仍须在服务器上安装 `mihomo` 或设置 `MIHOMO_CHECK_BIN`。

## 订阅更新失败

若导入或刷新订阅时出现 `i/o timeout`、`connection refused` 或 `no such host`，先检查当前
网络是否污染或阻断了订阅域名解析。可在客户端启用自定义 DNS，并优先尝试：

```text
https://223.5.5.5/dns-query
```

仍无法解析时，可临时改用：

```text
https://1.1.1.1/dns-query
```

常见客户端入口：

| 客户端 | 设置位置 |
| --- | --- |
| Clash Verge Rev | 设置 → DNS 设置 → 自定义 DNS |
| Clash Mi | 设置 → DNS 设置 → 自定义 DNS 覆写 |
| FlClash | 设置 → 网络 / DNS → 覆写 DNS |
| Clash Meta for Android | 设置 → 覆写 → DNS 覆写 |

Cloudflare 模式固定提供 6 个 IPv4 节点且没有域名兜底。订阅能够更新但节点无法连接时，先确认
客户端确实支持 Mihomo XHTTP，再检查 Cloudflare Zone 的 gRPC 开关。
