# 客户端使用指南

安装完成后在服务器运行 `sudo easy_all subscription` 获取专属订阅链接，直接导入客户端即可使用。订阅链接会自动识别客户端类型并下发对应格式（亦可在链接末尾追加 `&flag=singbox|clash|base64` 强制指定）。

> **模式 1/5（Xray XHTTP）不提供 sing-box JSON 订阅**：只输出 Base64 与 Mihomo（含 `-all` 与 iOS 变体）共 6 份产物，请使用 FlClash / Mihomo / Stash 或 Shadowrocket / v2rayN；`flag=singbox` 在这些模式返回 503。

> 订阅链接与内部 UUID 属于敏感凭据，请勿泄露或公开分享。

---

## 1. 客户端推荐与下载

| 平台 | Mihomo / 通用推荐 | sing-box（完整 JSON） |
| :--- | :--- | :--- |
| **Windows** | **[FlClash](https://github.com/chen08209/FlClash/releases)**（优先推荐）、[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Bettbox](https://github.com/appshubcc/Bettbox/releases) | [sing-box for Desktop（SFW）](https://sing-box.sagernet.org/clients/desktop/)（Win 10+，选 `SFW-*.exe`） |
| **macOS** | **[FlClash](https://github.com/chen08209/FlClash/releases)**（优先推荐）、[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Bettbox](https://github.com/appshubcc/Bettbox/releases) | [sing-box for Apple（SFM）](https://sing-box.sagernet.org/clients/apple/#download-macos-standalone-version)（macOS 13+，选 `SFM-*.pkg`） |
| **Android** | **[FlClash](https://github.com/chen08209/FlClash/releases)**（优先推荐）、[Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid/releases)、[Bettbox](https://github.com/appshubcc/Bettbox/releases) | [sing-box for Android（SFA）](https://sing-box.sagernet.org/clients/android/)（选 `SFA-*.apk`） |
| **iOS / iPadOS**<br>（均需外区 Apple ID） | [Clash Mi](https://clashmi.app/download)、[Shadowrocket（小火箭）](https://apps.apple.com/us/app/shadowrocket/id932747118) | [sing-box MT（SFI）](https://apps.apple.com/us/app/sing-box-mt/id6785326793)（iOS 15+；tvOS 选 SFT） |
| **Linux** | **[FlClash](https://github.com/chen08209/FlClash/releases)**（优先推荐）、[Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[Mihomo Core](https://github.com/MetaCubeX/mihomo/releases) | [sing-box for Desktop（SFL）](https://sing-box.sagernet.org/clients/desktop/)（选对应架构的 `SFL-*`） |

> 内核要求：Mihomo 建议 **≥ 1.19.9**，官方 sing-box 需 **≥ 1.14.0**（仅适用模式 2–4；模式 1/5 是纯 Xray 后端，不支持 sing-box 客户端且不提供 JSON 订阅）。请从官方渠道下载对应架构版本，勿开启“跳过证书校验”。

---

## 2. 导入与使用

1. 复制 `sudo easy_all subscription` 输出的订阅链接，在客户端中新建远程订阅 / 远程配置（Remote Profile）并更新。
2. 日常保持**规则（Rule）模式**即可：大陆及局域网/公共 Wi-Fi 登录页自动直连，境外流量走 `PROXY` 分组。
3. 若部署了双链路模式（直连 + CDN），`PROXY` 分组内同时包含直连节点与 CDN 节点，日常可按网络情况手动切换（无自动测速切流）。模式 1/5 的 CDN 节点是 **VLESS XHTTP**（`mode=stream-up`、`alpn=h2`，Mihomo 侧为 `network: xhttp` + `xhttp-opts`），需要客户端支持 XHTTP。

---

## 3. 各客户端注意事项

- **模式 1（纯 CloudFlare，Xray 核心）**：只有一个橙云 XHTTP 节点（`type=xhttp&mode=stream-up&alpn=h2`，Mihomo 侧 `network: xhttp`）。需要 Cloudflare Zone 已开启 **Network → gRPC**；若订阅能下载但节点连不上，先确认该开关与 Zone 的 `Full (strict)`。`cdnEdgeAddress` 只替换连接地址，SNI 与 XHTTP `host` 仍是节点域名。
- **模式 3/4（VLESS Reality 直连 + CloudFront / CloudFlare）**：订阅同时下发两个本机节点——Reality 直连（`flow=xtls-rprx-vision` + `public-key` / `short-id`）与 CDN 节点（模式 3 为 CloudFront VLESS-WS，模式 4 为橙云 VLESS HTTPUpgrade）。Reality 节点在 Mihomo 侧**不写** `support-x25519mlkem768`（保持经典 X25519，与服务端 sing-box 1.14.4 握手一致）；sing-box 官方客户端使用自带的 Reality 实现，无需额外开关。**时钟同步要求**：服务端已开启 `max_time_difference: 2m` 抗重放校验，客户端设备必须开启系统自动校时；若本机与服务端时钟偏差超过 2 分钟，握手会静默回落到伪装站导致直连失败。直连不可用时可先切到 CDN 节点。
- **模式 5（VLESS Reality 直连 + 橙云 VLESS XHTTP，Xray 核心）**：订阅同时下发 Reality 直连节点与橙云 XHTTP 节点。Reality 侧需要客户端设备开启自动校时（服务端 `maxTimeDiff` 为 120000 ms）。服务端 Xray 默认追踪最新官方 Release（≥ 26.9.8），Mihomo 节点会写 `support-x25519mlkem768: true`；用更早版本服务端渲染时会改为链接追加 `mlkem=0` 且不写该开关。`cdnEdgeAddress` 只替换连接地址，SNI 与 XHTTP `host` 仍是节点域名，**不要**把 SNI 改成优选域名。
- **模式 1/5 的客户端要求**：CDN 节点是 XHTTP（HTTP/2 `stream-up`），请使用支持 XHTTP 的客户端（FlClash / Mihomo ≥ 1.19.9、Stash、Shadowrocket ≥ 2.2.x、v2rayN/v2rayNG 新版本）。sing-box 官方客户端不支持 XHTTP，且这两个模式不生成 sing-box JSON 订阅。
- **sing-box 官方客户端（SFA / SFI / SFM / SFT / SFW / SFL）**：
  - 内核必须 **≥ 1.14.0**（旧版本会报错无法启动）。
  - 首次启动需联网拉取内置规则集；官方 sing-box 不支持的协议（如 `xhttp`、`mieru`）会在生成订阅时自动跳过。
- **iOS 客户端**：
  - 使用 `Shadowrocket（小火箭）` 仅获取节点列表（不包含服务端下发的分流规则），需在客户端内选好分流规则/配置（通常保持默认即可）。
  - 使用 `Clash Mi` 获取 Mihomo 订阅时（或链接追加 `&os=ios`）会自动精简嗅探配置并关闭 `tcp-concurrent`（并发建连占内存更多），降低后台内存占用。
- **Android Google FCM 推送**：
  - 若前台正常但后台收不到推送，请在系统与客户端中：① 关闭“允许绕过 VPN”，确保 Google Play 服务走代理；② 允许代理客户端与 Google Play 服务无限制后台运行；③ 重启设备清理旧 DNS 缓存。

---

## 4. 常见客户端排查

- **订阅更新失败（`i/o timeout` / `no such host`）**：多为本地 DNS 污染，可在客户端设置中开启自定义 DNS 覆写，填写 `https://223.5.5.5/dns-query` 或 `https://1.1.1.1/dns-query` 后重试。
- **订阅正常但无法连接**：
  1. 确认客户端内核版本满足要求（Mihomo ≥ 1.19.9 / sing-box ≥ 1.14.0），且未开启“跳过证书校验”；
  2. **模式 3/4/5 Reality 直连无法连通**：检查客户端设备是否开启自动网络校时（服务端开启了 2 分钟时间窗校验，时钟偏差超过 2 分钟时握手会静默回落到伪装站；服务端也可按[运维指南](operations-guide.md#9-常见问题排查速查表)用 `timedatectl` 核对 NTP）；
  3. 若同时有直连与 CDN 节点，尝试在 `PROXY` 分组切换到另一节点确认是否为单条线路受阻；
  4. 如仍异常或需调整优选地址/检查服务端状态，请参阅[运维指南](operations-guide.md)。
