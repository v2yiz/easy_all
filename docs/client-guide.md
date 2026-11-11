# 客户端使用指南

easy_all 全模式支持 Debian 12/13 及 Ubuntu 22.04/24.04/26.04 LTS（bookworm / trixie / jammy / noble / resolute，支持 amd64 与 arm64 架构）；所有模式均保留现有 SSH 监听。


easy_all 生成标准 Mihomo（Clash Meta）、sing-box 完整 JSON 与通用 Base64 订阅。安装完成后运行：

```bash
sudo easy_all subscription
```

复制命令输出中的订阅地址，在客户端从 URL 导入并启用。服务端按客户端的请求选择 sing-box JSON、
Mihomo YAML 或 Base64；使用 sing-box 客户端时，请按下文选择[完整 JSON 的导入方式](#sing-box-客户端完整-json-订阅)。
订阅地址和 UUID 都是访问凭据，不要公开。

## 客户端选择

| 平台 | Mihomo（YAML） | sing-box（完整 JSON） |
| --- | --- | --- |
| Windows | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases) | [sing-box for Desktop（SFW）](https://sing-box.sagernet.org/clients/desktop/)，Windows 10+，安装包为 `SFW-*.exe` |
| macOS | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases) | [sing-box for Apple platforms（SFM）](https://sing-box.sagernet.org/clients/apple/#download-macos-standalone-version)，macOS 13+，安装包为 `SFM-*.pkg` |
| Android | [Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid/releases) | [sing-box for Android（SFA）](https://sing-box.sagernet.org/clients/android/)，手动安装时选 `SFA-*.apk` |
| iOS / iPadOS | [Clash Mi](https://clashmi.app/download) | [sing-box MT（SFI）](https://apps.apple.com/us/app/sing-box-mt/id6785326793)，iOS / iPadOS 15+，需使用中国大陆以外地区的 Apple 账户；Apple TV 用同一应用的 SFT（tvOS 17+） |
| Linux | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Clash Mi](https://clashmi.app/download)、[Bettbox](https://github.com/appshubcc/Bettbox/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Mihomo Core](https://github.com/MetaCubeX/mihomo/releases) | [sing-box for Desktop（SFL）](https://sing-box.sagernet.org/clients/desktop/)，按发行版选择 `SFL-*` 软件包 |

请从官方发布页或应用商店下载与操作系统、CPU 架构匹配的版本。桌面图形客户端请选上述前缀的安装包，
发布页的 `sing-box-*` 包是命令行内核。

本机节点只有两类：AnyTLS 直连（模式 1 / 4 / 5）与 VLESS WebSocket（模式 2 / 3 / 4 / 5）。两者端口都是 `443`，
都使用公信证书，`skip-cert-verify` 固定为 `false` —— 不要在客户端开启“跳过证书校验”。

**AnyTLS 直连（模式 1 / 4 / 5）** 的 Mihomo 字段固定为：

| 字段 | 值 |
| --- | --- |
| `type` | `anytls` |
| `server` / `sni` | 直连域名（如 `node.example.com`），不是 IP |
| `port` | `443` |
| `password` | 安装时生成的 AnyTLS 密码 |
| `client-fingerprint` / `udp` | `chrome` / `true` |
| `skip-cert-verify` | `false` |

分享链接形如
`anytls://<URL 编码后的密码>@node.example.com:443/?sni=node.example.com&insecure=0#<URL 编码后的节点名>`。

**VLESS WebSocket（模式 2 / 3 / 4 / 5）** 的本机 CDN 节点只有**一个**，名称默认 `🇺🇸AWS`（模式 2/4）
或 `🇺🇸CF`（模式 3/5），安装时可改；连接参数固定为：

- 节点地址（`server`）是连接地址，安装时若确认了 CDN 优选地址则是优选域名（如 `m3q8a1w7zr.cloudfront.182682.xyz`），否则是 CDN 节点域名（如 `cf.example.com`）；TLS `servername` 与 WebSocket `Host` 始终是 CDN 节点域名。地址都是域名，不是 IP；
- 端口 `443`、TLS 开启、`network: ws`、`skip-cert-verify: false`、`client-fingerprint: chrome`、`packet-encoding: xudp`；
- `ws-opts.path` 是安装时生成并精确匹配的随机路径，`ws-opts.headers.Host` 与 `servername` 相同。

分享链接形如
`vless://<uuid>@cf.example.com:443?encryption=none&security=tls&type=ws&sni=cf.example.com&fp=chrome&host=cf.example.com&path=%2Fvless-...&packetEncoding=xudp#<节点名>`。
启用 CDN 优选地址时只有 `@` 后换成优选域名（如 `m3q8a1w7zr.cloudfront.182682.xyz`），`sni` 与 `host` 仍是节点域名。

注意区分证书来源：客户端只校验 viewer / 直连 / 橙云边缘证书（模式 1/5 的直连是 Let's Encrypt 证书，模式 2/4 是 AWS ACM，
模式 3 是 Cloudflare 边缘证书）；源站侧的 Let's Encrypt 证书与 Cloudflare Origin CA 只在边缘到源站之间使用，
源站头密钥 `X-Easy-All-Origin-Key` 同样只存在于服务器与分发之间，都不会下发到订阅。

“能导入”不代表所有节点都能连接。客户端需要支持 AnyTLS 与 VLESS WebSocket（Mihomo 建议 ≥ 1.19.9）；
本版本不提供 `httpupgrade` 传输选项。旧版订阅里的 Cloudflare 优选 IP 节点已不再生成，升级或重装后请在客户端
**重新导入**新链接（重装会产生新的 AnyTLS 密码、UUID、路径与 Token）。

模式 2–5 的安装会生成一个 10 位随机前缀并拼成 CDN 优选连接地址（`*.cloudfront.182682.xyz` /
`*.cloudflare.182682.xyz`），它**只替换连接地址**（节点 `server` / Address）：SNI、WebSocket `Host`、
证书校验与订阅 URL 都不变。优选域名解析失效导致连不上时，用 `sudo easy_all edit-sub` 删除订阅配置里的
`cdnEdgeAddress` 并保存，客户端刷新订阅即回到直接连接 CDN 节点域名。

## 客户端分流与节点分组

日常使用“规则”模式即可。订阅会自动让中国大陆流量直连，境外网站和 AI 服务经 `PROXY`。
- **直连 AnyTLS（模式 1 / 4 / 5）**：部署订阅时 `PROXY` 分组依次是本机 AnyTLS 节点（默认 `🇺🇸直连`）与聚合配置 `nodes` 里的节点（名字原样使用）。默认只下发不带 `optional` 的聚合节点，在订阅链接后追加 `&node=all` 可显示全部；模式 1 选择“仅节点”（`link`）时不下发订阅，只输出本机节点信息。
- **纯 CDN（模式 2 / 3）**：没有直连节点。`PROXY` 分组按固定顺序包含「本机 CDN 节点 → 聚合节点（来自订阅配置 JSON 的 `nodes`，原顺序）」。CDN 节点在模式 2 是 CloudFront 节点（默认 `🇺🇸AWS`），在模式 3 是 Cloudflare 橙云节点（默认 `🇺🇸CF`），都不经过另一朵云的链路。
- **直连+CDN（模式 4 / 5）**：模式 4 的 `PROXY` 分组按固定顺序包含「本机直连节点（默认 `🇺🇸直连`）→ 本机 CDN 节点（默认 `🇺🇸AWS`）→ `AUTO` → `CDN-FALLBACK` → 聚合节点」。`PROXY` 仍是手动选择；另有两个自动组：`AUTO`（`url-test`）与 `CDN-FALLBACK`（`fallback`，顺序为直连 → CDN），探测地址固定 `https://www.gstatic.com/generate_204`（HTTPS 443）。
- **直连+CDN（模式 5）**：`PROXY` 分组按固定顺序包含「本机直连节点（默认 `🇺🇸直连`）→ 本机橙云节点（默认 `🇺🇸CF`）→ 聚合节点」；没有 `AUTO` / `CDN-FALLBACK` 自动组，由你手动切换。
- **Base64 订阅**：针对不支持策略组的通用客户端，自动下发平铺节点列表，顺序与 `PROXY` 成员一致：模式 1 是直连节点 → 聚合节点；模式 2/3 是 CDN 节点 → 聚合节点；模式 4/5 是直连节点 → CDN 节点 → 聚合节点。
- **外部聚合节点**：订阅 JSON 里指向外部服务器的节点保留原有 `host/port/portRange`，不会因为本机统一 443 而被改写；它们的传输格式由你填写的配置决定。
- **sing-box JSON 的分组差异**：`PROXY` 成员顺序与下发的 Mihomo 一致，但 JSON 没有 `CDN-FALLBACK`（官方 selector/urltest 无法保证“直连可用时始终优先”），模式 4 只有 `AUTO`（`urltest`，只含本机直连与 CDN，默认选择直连节点）。CDN 熔断时 JSON 里的 CDN 节点仍在，需要手动切到直连，`AUTO` 要等下一个探测周期（300 秒）才会换。
- **熔断期间的节点（仅模式 2/4，模式 5 没有熔断）**：CDN 用量达到阈值后节点**不会**从订阅里删除，订阅仍可正常下载，只是 CDN 连接被阻断（Caddy 代理路径返回 `503`，sing-box 省略 CDN 入站）。模式 4 此时切到直连节点（或 `CDN-FALLBACK` 自动回落）即可继续使用，直连会短暂重连一次；模式 2 只能等 UTC 次月或按运维指南收敛后再试。模式 1/3/5 没有这个熔断。
YouTube 与其他代理流量统一使用当前选择。
规则模式下，代理流量的 UDP/443 始终优先拒绝以回退 TCP，手动选择出口不会绕过这一策略。

订阅显式定义 `GLOBAL → PROXY`。切换到“全局”模式后，Mihomo 忽略域名和 GeoIP 分流规则，
所有被接管的流量使用 `PROXY` 当前选择，无需再操作 `GLOBAL`。TUN 排除的局域网 IPv4 地址
仍保持本地直连。

## sing-box 客户端（完整 JSON 订阅）

上表的官方 sing-box 客户端（SFA / SFI / SFM / SFT / SFW / SFL）均支持[远程配置（Remote Profile）](https://sing-box.sagernet.org/clients/general/#remote)。
在客户端新建远程配置，直接粘贴 `sudo easy_all subscription` 输出的链接，保存后选中该配置并启动。
服务端按 User-Agent 自动返回完整 JSON，也可在链接末尾追加 `&flag=singbox` 强制指定格式。

如果服务端是从旧版本升级的，更新代码后需执行 `sudo easy_all apply`，使 JSON 订阅和新的自动识别规则生效。
第三方客户端即使使用 sing-box 内核，也要确认它能从 URL 加载完整配置；如果只支持节点列表，请按它支持的格式导入。

- **配置内容**：混合代理 `127.0.0.1:1080`、TUN（`172.19.0.1/30`、MTU 1500、`auto_route` 开启）、本机节点与受支持的聚合节点、`PROXY` 手动选择器、Fake-IP DNS（`198.18.0.0/16`）与分流规则。控制接口（Clash API）只在 `127.0.0.1:9090` 监听，不暴露到局域网。
- **手动切换**：用客户端原生界面或 Clash API 在 `PROXY` 中选节点；规则模式按订阅内规则分流，`clash_mode=direct/global` 可整体直连或全局代理。
- **节点排除**：官方 sing-box 1.14.4 不支持 `xhttp` 传输与 `mieru` 协议，也会拒绝 1.14.4 uTLS 枚举之外的 `fp`（例如 `chromium`）。这两类聚合节点只从 JSON 中排除，`apply` / `edit-sub` 会打印被排除的节点名、原因与数量；Mihomo / Base64 订阅仍包含它们。Reality 节点的 `support-x25519mlkem768` 不影响能否导入（sing-box 的 Reality 客户端固定使用经典 X25519，不提供 MLKEM 混合密钥交换），但这类节点在本版本没有做过实际握手验证。本机节点始终可用，因此排除后 JSON 仍然有效。
- **首次启动需要能下载规则集**：订阅引用 MetaCubeX 的 sing-box SRS 规则集（`update_interval` 1 天，启用缓存）。没有任何缓存且首次下载失败时，客户端会报配置启动失败；等网络恢复后重新导入或重启即可。已有有效缓存时，离线重启与“更新失败保留旧缓存”都正常。
- **直连解析用本地 DNS**：订阅里的 `DIRECT` 出口固定走客户端本地解析，局域网/内部域名（`nas.lan` 等）与 Mihomo 订阅一致地由系统 DNS 解析；节点域名用独立的引导解析器，不经过代理 DNS。
- **TUN 行为按平台**：Linux 上以命令行运行 TUN 需要相应权限，能通过 `sing-box check` 不代表系统已允许接管网络；移动端请在 VPN 模式实测。首版只下发一份公共 JSON，不按 iOS/Android 拆分，也不剥离嗅探段（JSON 只用 `sniff` 规则嗅探 TCP 的 HTTP/TLS，不嗅探 QUIC）。
- **导入出错时先分清类型**：格式选错（加 `&flag=singbox`）、核心不支持某些字段、规则集首次下载失败、节点连接失败是不同问题；`flag` 只解决格式选择。

## 局域网 DNS 与直连覆盖

私有域名默认交给客户端系统 DNS 解析并返回真实 IP，本机 hosts 生效。COMMON 的 DNS、Fake-IP
例外和直连规则共用 `private-fallback` 与 `geosite-private`；其中 `.lan`、`.local`、`.internal`、
`.localdomain`、`.localhost`、`home.arpa` 和 `localhost` 内联，首次规则下载失败仍可用。
经典模板使用 `rule-set:geosite-private`（MRS 规则集）。若 `nas.lan` 等名称仍无法解析，在客户端 DNS 覆写中把
对应策略（COMMON 为 `rule-set:private-fallback,geosite-private`）指向实际局域网 DNS，如路由器地址；
不要使用 Mihomo 自己的 DNS 监听地址，避免解析循环。
Clash Meta for Android 可使用 `dhcp://system` 获取系统 DNS；其他客户端按其 DNS 覆写能力设置。
公共模板不写死网关地址，切换网络后应检查该覆盖是否仍适用。
只有带上述后缀或已收录的私有域名会自动使用系统 DNS；未带后缀的裸主机名（如 `http://nas/`）
按单标签规则直连，不再走代理；它不会为 GeoIP 兜底触发解析，请改用 `.lan` 等后缀、写入本机 hosts，
或在客户端 DNS 覆写中按名称指定，否则直连解析可能失败。

### 单标签主机与认证门户

没有点的单标签主机名（`getmobileredirecthost`、`wpad`、`isatap` 以及 `nas`、`router` 等裸设备名）
统一走 `DOMAIN-REGEX,^[^.]+$,DIRECT`，不再落入 `MATCH,PROXY`。它们不是公网域名，公网 DoH 无法解析；
直连是否成功取决于本机 hosts、局域网 DNS 或客户端 DNS 覆写。

连接性检测/认证门户域名共用内联集合 `captive-portal`：Android 的 `connectivitycheck.gstatic.com`、
`connectivitycheck.gstatic.cn`、`connectivitycheck.android.com`、`clients3.google.com`，华为
`connectivitycheck.platform.hicloud.com`，荣耀 `connectivitycheck.platform.hihonorcloud.com`，
小米 `connect.rom.miui.com`，OPPO `connectivitycheck.oppomobile.com`，vivo `wifi.vivo.com.cn`，
Apple `captive.apple.com`，Firefox `detectportal.firefox.com`，GNOME `nmcheck.gnome.org`，
Windows `www.msftconnecttest.com` 等。它们使用系统 DNS 并直连，并排在 `proxy-services` 之前；
这样认证门户能正常弹出，但受限网络下 Android 可能显示“无网络”而不是被代理掩盖。

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
三套模板的 LAN/CN GeoIP 兜底只使用已有真实目标 IP。CN 规则带 `no-resolve`，经典模板的国内
QUIC 子规则也带 `no-resolve`；未命中域名集合的未知域名不会仅为了 CN GeoIP 判断额外解析，
默认交给 `MATCH,PROXY`，未知 QUIC 则由后续 UDP/443 拒绝规则处理并要求应用回退 TCP。
这不是零 DNS 承诺：正常域名规则、应用自身 DoH 和 DNS 请求仍可能发生解析，也不承诺绝对无泄漏。
以首连等待和可预测性为优先的代价是未收录的国内域名默认代理；如需覆盖应扩充域名集合。
更新订阅后应重启代理内核以清除旧 Fake-IP 和 DNS 缓存；无需清除应用数据。

## Android 打开 App 才收到消息

Telegram 等 App 前台正常、后台不推送时，先检查 Google FCM 推送通道。模板让
FCM 域名返回真实 IP（COMMON 内联 12 个 mtalk 端点，经典模板使用 `rule-set:geosite-googlefcm`）；
进入代理内核的 TCP 5228–5230 流量走 `PROXY`
（局域网仍直连），避免无域名的推送连接落入国内 IP 直连规则。FCM 的 443 回退和注册请求
继续使用现有 Google 代理规则及代理 DNS。

更新服务器订阅规则后，在客户端刷新订阅并重启代理内核。安装器部署的订阅按[运维指南](operations-guide.md)
运行 `self-update` 和 `edit-sub` 即可重新渲染。

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

默认订阅模板 `templates/mihomo.yaml` 就是 COMMON 精简规则：小型内联集合加 国内域名库（约 11 万条）、
国内 SDK 域名库（约 5 千条）、Apple 国内调度、Google、私有域名、Telegram 和中国 IP 的七个 MRS 规则集。安装器与本机订阅都会直接使用它，
不需要任何额外参数。不加载整库 DAT，也不加载境外域名库。

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
三套模板默认都开启嗅探（`sniffer`，含 `override-destination`）：应用自行使用 DoH 或直接连接真实 IP 时，
内核可从 TLS/HTTP 握手恢复域名，分流仍按域名生效；不开启时这类连接只能按 IP、端口及最终兜底规则处理，
境外服务使用中国 IP 时可能直连。**嗅探刻意不覆盖 QUIC**：境外 UDP/443 由后续规则立即 `REJECT` 并要求应用回退 TCP，
先嗅探 QUIC 会把这次拒绝拖到握手解析之后，Android 上会表现为 Google Play 下载长期停在“等待中”
（只影响绕过本机 DNS 的客户端的 UDP/443 分类，TCP 仍按域名分流；国内 QUIC 直连不变）。
iOS 客户端（UA 命中 `iphone/ipad/ipod/ios`，或链接加 `&os=ios`）下发的 YAML
会自动剔除嗅探段（`sniffer`）。除 iOS 网络扩展严苛的常驻内存限制（防 Jetsam OOM 杀后台进程）外，剔除的核心工程依据还包括：
① 避免对 `push.apple.com` 等长连接重写目标而导致 APNs 推送断连、延迟或触发风控；
② 避免 `override-destination` 触发二次 DNS 解析破坏系统本地 CDN 就近调度；
③ 避免微信、金融与私有协议在等待嗅探解析时触发 1 秒首包超时卡顿；
④ 兼容 iOS 17+ 原生 ECH（防真实目标被伪装域名覆盖）。
嗅探会额外占用连接级内存与解析开销：下面的 50MB 目标与 RSS 基线都是在**未开启嗅探**时测得的，
桌面端开启后需按自己的设备复测。

50MB 是优化目标，不是 iOS 峰值保证。macOS RSS 与 iOS 网络扩展占用不能直接等同；节点数量、
客户端内核、TUN、DNS 缓存和并发连接都会影响实际峰值。旧款 iPhone 必须用实际客户端测试
冷启动、规则更新和并发流量；仅通过 `mihomo -t` 不能证明规则已加载或内存达标。

此前的本机基线：mihomo v1.19.32 darwin-arm64，加载真实 MRS，关闭 TUN，回环 DNS 与 REJECT
模拟出站，启动及分流探测期间每 50ms 采样 RSS；精简版观察到峰值约 39 MiB，完整版约 46 MiB。
该样本早于微信与 Steam 内联规则及 Apple 国内子集调整，也不是真实代理握手、长时间并发流量或 iPhone 网络扩展的峰值测试。

需要更多规则或换回旧设计时，在发布命令前加 `MIHOMO_TEMPLATE_SOURCE`：

| 模板 | 规则覆盖 | 内存取舍 |
| --- | --- | --- |
| `templates/mihomo.yaml`（默认） | 国内域名库、国内 SDK 域名与常用域名直接分流，已有目标 IP 再按 LAN/CN GeoIP 兜底 | 七个 MRS，内存仍以 50MB 为优化目标（不含嗅探开销） |
| `templates/mihomo-common.yaml` | 默认模板再加境外域名 MRS | 覆盖更全，但常驻内存高于默认模板 |
| `templates/mihomo-classic.yaml` | 经典分流（2.3.1 起全部改为 MRS 规则集，不再加载 geodata/.dat） | 十三个 MRS，另有 FCM 与微信真实 IP 例外 |

默认模板加载约 11 万条国内域名库与约 5 千条国内 SDK/推送域名库（含个推、极光、友盟等），绝大多数国内站点
（含 `.com`、`.org` 等非 `.cn` 域名）无需解析即可直连；不在库内的域名不会为 GeoIP 兜底额外解析，会直接走代理并在出口侧解析，可能得到境外 CDN。
远程中国 IP 规则不可用时，未命中域名集合的国内流量同样保守走代理，不承诺完整国内直连覆盖。
需要完整覆盖时选完整版或经典模板。FCM 端口兜底仍会影响其他 TCP 5228–5230 应用；共享的
Auth0、Stripe、Intercom 等服务仍整体代理，可按实际日志收窄 `proxy-services`。

实现参考：[Mihomo 示例](https://wiki.metacubex.one/example/conf/)、
[DNS 分流](https://wiki.metacubex.one/config/dns/)、
[规则集与 MRS](https://wiki.metacubex.one/config/rule-providers/)及
[Loyalsoldier 常用规则](https://github.com/Loyalsoldier/clash-rules)。与原始配置不是逐条等价：
移除了宽泛域名关键字，修正 JetBrains Grazie 拼写，取消 `ssl.gstatic.com` 单独直连，补充常用代理服务。

```bash
sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo-common.yaml easy_all edit-sub
```

改用 `sudo MIHOMO_TEMPLATE_SOURCE=... easy_all apply` 即可让所有客户端生效。五种模式的 `apply`
**只重建本机与订阅**，不访问云管理 API、不签发证书，也不需要 Cloudflare / AWS 凭据；要改云端请用
`apply-cloud`（它会自己按模式询问凭据）。自定义模板路径
同样通过 `MIHOMO_TEMPLATE_SOURCE` 传入（本地文件或 HTTPS URL）；仓库内置模板的结构校验（MRS/DNS/IPv4/sniffer、`PROXY` 成员与 `GLOBAL` 引用、无额外分组等）由 `npm test` 覆盖，但仓库 CI 没有安装 Mihomo 内核，**真实内核 `-t` 未在 CI 执行**：`validate_mihomo_template` 在 bundled/trusted 模板且无内核时直接成功，不能当作内核验收。如仍需验证真实内核，请在服务器上安装 `mihomo` 或设置 `MIHOMO_CHECK_BIN`（真实验证需另行准备内核与规则数据）。`sniffer` 段必须写成块映射
（`sniffer:` 独占一行），写成内联映射时安装会直接报错——iOS 下发需要按段剔除它。
`sniffer` 段可以放在任意顶层位置：剥离只删本段内容，其他段落与顶格注释都会保留。
选中的模板会保存在服务器上，后续 `apply`、`edit-sub` 与重启后的端口刷新沿用同一模板。

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

模式 2/3/4/5 的订阅只包含**一个**本机 CDN 节点（模式 2/4 经 CloudFront 分发调度，模式 3/5 经 Cloudflare 边缘调度），
连接地址可能是安装时确认的 CDN 优选域名（见上文），TLS SNI 与 WebSocket `Host` 仍是节点域名；没有聚合优选 IP 列表、测速组或额外兜底节点（模式 4 的 `AUTO` / `CDN-FALLBACK` 只是本机直连与 CDN 之间的自动选择）。订阅能够更新但节点无法连接时，先按上文用 `sudo easy_all edit-sub` 删除 `cdnEdgeAddress` 并刷新订阅排除优选域名问题，再按顺序排查：

1. 确认客户端支持 AnyTLS / VLESS WebSocket（建议内核 ≥ 1.19.9），且没有开启“跳过证书校验”；
2. 模式 4 先在 `PROXY` 里手动切到直连节点，确认是不是 CDN 入口单独不通；
3. 运行 `sudo easy_all status`：CDN 用量若已到 985 GB 或显示 `protection_offline`，节点会被阻断到 UTC 次月；
4. 仍不通再检查云端：模式 2/4 看节点域名 CNAME 是否指向分发、分发与 ACM 是否就绪（源站端口模式 2 为 `443`、模式 4 为 `8443`）；模式 3/5 看橙云 A 记录是否为 Proxied、SSL/TLS 是否 Full (strict)，模式 5 再看 Origin Rule 是否回源 `8443`（必要时 `sudo easy_all apply-cloud`）。
