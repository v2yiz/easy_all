# 客户端使用指南

安装完成后在服务器运行 `sudo easy_all subscription` 获取专属订阅链接，直接导入客户端即可使用。订阅链接会自动识别客户端类型并下发对应格式（亦可在链接末尾追加 `&flag=singbox|clash|base64` 强制指定）。

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

> 内核要求：Mihomo 建议 **≥ 1.19.9**，官方 sing-box 需 **≥ 1.14.0**。请从官方渠道下载对应架构版本，勿开启“跳过证书校验”。

---

## 2. 导入与使用

1. 复制 `sudo easy_all subscription` 输出的订阅链接，在客户端中新建远程订阅 / 远程配置（Remote Profile）并更新。
2. 日常保持**规则（Rule）模式**即可：大陆及局域网/公共 Wi-Fi 登录页自动直连，境外流量走 `PROXY` 分组。
3. 若部署了双链路模式（直连 + CDN），`PROXY` 分组内同时包含直连节点与 CDN 节点，日常可按网络情况手动切换（无自动测速切流）。

---

## 3. 各客户端注意事项

- **模式 6（VLESS Reality 直连 + CloudFront）**：订阅同时下发两个本机节点——Reality 直连（`flow=xtls-rprx-vision` + `public-key` / `short-id`）与 CloudFront VLESS-WS。Reality 节点在 Mihomo 侧**不写** `support-x25519mlkem768`（保持经典 X25519，与服务端 sing-box 1.14.4 握手一致）；sing-box 官方客户端使用自带的 Reality 实现，无需额外开关。直连不可用时切到 CDN 节点即可。
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
  2. 若同时有直连与 CDN 节点，尝试在 `PROXY` 分组切换到另一节点确认是否为单条线路受阻；
  3. 如仍异常或需调整优选地址/检查服务端状态，请参阅[运维指南](operations-guide.md)。
