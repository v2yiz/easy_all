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
- XHTTP `stream-up` 参数。

“能导入”不代表所有节点都能连接。Shadowrocket 的更新记录虽然包含 XHTTP 和
`stream-up` 修复，但未逐项确认上述字段的完整兼容性，因此目前不把 Shadowrocket 列为
本项目的已验证客户端。

## Clash Mi 模式

日常使用“规则”模式即可。订阅会让中国大陆流量直连，境外网站和 AI 服务经 `PROXY`。

Clash Mi 的 `GLOBAL` 分组默认指向 `DIRECT`。切换到“全局”模式后，还必须进入“代理”页面，
点击 `GLOBAL` 并手动勾选 `PROXY`，否则流量仍然直连。

![Clash Mi 规则模式与全局模式设置](img/clashmi/clashmi-global-proxy.svg)

## 局域网 DNS 与直连覆盖

私有域名默认通过客户端系统 DNS 解析，并启用系统 hosts。若 `nas.lan` 等名称仍无法解析，
在客户端 DNS 覆写中将 `nameserver-policy` 的 `geosite:private` 指向实际局域网 DNS，
如路由器地址；不要使用 Mihomo 自己的 DNS 监听地址，避免解析循环。
Clash Meta for Android 可使用 `dhcp://system` 获取系统 DNS；其他客户端按其 DNS 覆写能力设置。
公共模板不写死网关地址，切换网络后应检查该覆盖是否仍适用。

订阅不再按 v2ray、xray、Surge 等进程名无条件直连。如需管理 VPS 或串联其他代理，
在客户端添加目标地址的精确直连规则；不要将所有 SSH 端口或下载器进程一律直连。

## Clash Party 与微信图片

模板使用 `fake-ip-filter-mode: blacklist`，避免 Clash Party 接管 DNS 后把内置的 `*`
过滤项误当成规则模式。微信的图片、头像和小程序资源域名会返回真实 IP，并使用国内 DNS
与直连出口。更新订阅后应重启代理内核以清除旧 Fake-IP 映射；无需清除微信数据。

## Android 打开 App 才收到消息

Telegram 等 App 前台正常、后台不推送时，先检查 Google FCM 推送通道。模板让
`geosite:googlefcm` 域名返回真实 IP；进入代理内核的 TCP 5228–5230 流量走 `PROXY`
（局域网仍直连），避免无域名的推送连接落入国内 IP 直连规则。FCM 的 443 回退和注册请求
继续使用现有 Google 代理规则及代理 DNS。

更新服务器订阅规则后，在客户端刷新订阅并重启代理内核。Worker 的模板在构建时内嵌，
仅修改仓库文件或刷新客户端不会更新云端；安装器部署的订阅按[运维指南](operations-guide.md#更新与应用)
运行 `self-update` 和 `update-sub`，独立 Worker 则重新构建并部署。

Bettbox 还需检查以下设置（订阅无法替客户端修改这些开关）：

- 关闭“允许绕过 VPN”，并让 Google Play 服务（`com.google.android.gms`）参与 VPN；
  仅代理 Telegram 的应用白名单不能覆盖系统推送。
- 如启用了智能启停或休眠，先关闭，确保锁屏后内核继续工作；允许 Bettbox 与 Google Play 服务后台运行。
- 如果启用了 DNS 覆写，确认最终配置保留 `geosite:googlefcm`。重新连接网络或重启手机，
  让旧 DNS 缓存和推送连接失效；不要清除 Google Play 服务的数据。

验收时把 Telegram 切到后台并锁屏，请另一台设备发送消息；在 Bettbox 连接记录中检查
`mtalk.google.com` / `alt*-mtalk.google.com` 或 TCP 5228–5230 是否经 `PROXY` 建立连接。
如没有连接记录，优先检查 VPN 绕过、应用分流和系统后台限制。

依据：[Google FCM 网络与 VPN 说明](https://firebase.google.com/docs/cloud-messaging/network-configuration)。

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
