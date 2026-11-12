# 客户端使用指南

`easy_all` 支持自动分发标准 **Mihomo（Clash Meta）YAML**、**sing-box 完整 JSON** 与 **通用 Base64** 订阅。安装完成后运行：

```bash
sudo easy_all subscription
```

复制输出中的专属订阅链接，导入客户端即可使用。订阅服务端会根据客户端 User-Agent 自动分发对应格式（亦可通过 `&flag=singbox|clash|base64` 强制指定）。订阅链接与 UUID 均属敏感凭据，请妥善保管。

---

## 1. 客户端推荐与下载

| 平台 | Mihomo（YAML） | sing-box（完整 JSON） |
| :--- | :--- | :--- |
| **Windows** | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Bettbox](https://github.com/appshubcc/Bettbox/releases) | [sing-box for Desktop（SFW）](https://sing-box.sagernet.org/clients/desktop/)（Win 10+，选 `SFW-*.exe`） |
| **macOS** | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Bettbox](https://github.com/appshubcc/Bettbox/releases) | [sing-box for Apple（SFM）](https://sing-box.sagernet.org/clients/apple/#download-macos-standalone-version)（macOS 13+，选 `SFM-*.pkg`） |
| **Android** | [FlClash](https://github.com/chen08209/FlClash/releases)、[Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid/releases)、[Bettbox](https://github.com/appshubcc/Bettbox/releases) | [sing-box for Android（SFA）](https://sing-box.sagernet.org/clients/android/)（选 `SFA-*.apk`） |
| **iOS / iPadOS** | [Clash Mi](https://clashmi.app/download) | [sing-box MT（SFI）](https://apps.apple.com/us/app/sing-box-mt/id6785326793)（iOS 15+，外区 Apple ID；tvOS 选 SFT） |
| **Linux** | [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev/releases)、[FlClash](https://github.com/chen08209/FlClash/releases)、[Mihomo Core](https://github.com/MetaCubeX/mihomo/releases) | [sing-box for Desktop（SFL）](https://sing-box.sagernet.org/clients/desktop/)（选对应架构的 `SFL-*`） |

> 客户端内核需支持 AnyTLS 与 VLESS WebSocket（Mihomo 建议 ≥ 1.19.9）。请从官方渠道下载与 CPU 架构匹配的版本；勿在客户端开启“跳过证书校验”（`skip-cert-verify: false`）。

---

## 2. 节点参数与连接信息

本机节点统一使用 `443` 端口与公信 TLS 证书：
- **AnyTLS 直连（模式 1/3/5）**：`type: anytls`，`server/sni` 为直连域名，`port: 443`，`client-fingerprint: chrome`，`udp: true`。分享链接形如：`anytls://<密码>@<直连域名>:443/?sni=<直连域名>&insecure=0#<节点名>`。
- **VLESS WebSocket（模式 2/3/4/5）**：本机仅生成**一个** CDN 节点（模式 3/5 默认 `CDN备用`，模式 2 默认 `🇺🇸CF`，模式 4 默认 `🇺🇸AWS`）。`port: 443`，`tls: true`，`network: ws`，`packet-encoding: xudp`，`ws-opts.path` 为部署时生成的随机路径。若启用了 CDN 优选地址，连接地址替换为优选域名（如 `*.cloudfront.182682.xyz` / `*.cloudflare.182682.xyz`），而 SNI 与 WebSocket `Host` 保持原节点域名。分享链接形如：`vless://<uuid>@<连接地址>:443?encryption=none&security=tls&type=ws&sni=<节点域名>&fp=chrome&host=<节点域名>&path=<路径>&packetEncoding=xudp#<节点名>`。

> **证书校验分工**：客户端校验 viewer / 直连 / 橙云边缘证书（模式 1/3/5 直连为 Let's Encrypt，模式 4/5 CDN 为 AWS ACM，模式 2/3 CDN 为 Cloudflare 边缘证书）；源站 Let's Encrypt 与 Origin CA 仅在边缘到源站之间通信。
> **优选地址恢复**：若优选域名解析失效，执行 `sudo easy_all edit-sub` 删除 `cdnEdgeAddress` 字段并保存，客户端刷新订阅即可直接回退到直连 CDN 节点域名。

---

## 3. 客户端分流与策略组

日常使用**规则（Rule）模式**即可：大陆流量直连，境外流量走 `PROXY`。
- **直连 AnyTLS（模式 1/3/5）**：`PROXY` 分组按顺序包含本机直连节点（模式 3/5 默认 `主节点`，模式 1 默认 `🇺🇸直连`）与外部聚合节点（`nodes`）。模式 1 若选择 `link` 仅输出节点，不部署订阅。
- **纯 CDN（模式 2/4）**：无直连节点。`PROXY` 分组包含本机 CDN 节点（`🇺🇸AWS` 或 `🇺🇸CF`）与聚合节点。
- **直连+CDN（模式 5）**：`PROXY` 分组包含「直连节点 → CDN 节点 → 聚合节点」，无自动测速组与兜底组，与模式 3 一致，由用户手动切换。
- **直连+CDN（模式 3）**：`PROXY` 分组包含「直连节点 → 橙云节点 → 聚合节点」，无自动测速组，由用户手动切换。
- **Base64 订阅**：平铺节点列表，顺序与各模式 `PROXY` 成员一致。
- **sing-box JSON 的分组结构与 Mihomo 一致**：`PROXY` 成员顺序与 Mihomo 相同（直连节点 → CDN 节点 → 聚合节点），默认选中首个本机节点；不生成自动组（sing-box 无 `CDN-FALLBACK` 等价语义）。
- **985 GB 熔断表现（仅模式 4/5）**：达到阈值时 CDN 返回 `503`，模式 5 需手动切到直连节点继续使用（经历一次短暂重连）；模式 4 需等待次月或按运维指南处理。模式 1/2/3 无此熔断。

> 规则模式下，代理流量的 UDP/443（QUIC）默认优先拒绝并回退 TCP；全局（Global）模式下所有接管流量均强制走 `PROXY` 当前所选节点。

---

## 4. sing-box 客户端使用指南（完整 JSON）

官方 sing-box 客户端（SFA / SFI / SFM / SFT / SFW / SFL）均支持**远程配置（Remote Profile）**。
JSON 订阅使用 `domain_resolver`、`evaluate`/`respond` 等 1.14 才有的语法，**客户端内核需 sing-box ≥ 1.14.0**（1.11–1.13 会直接报错、配置无法启动）：
1. 打开客户端新建远程配置，粘贴 `sudo easy_all subscription` 输出的链接并保存（服务端自动分发完整 JSON，亦可在链接末尾加 `&flag=singbox`）。
2. 选中配置并启动即可。旧版本升级后需在服务端执行一次 `sudo easy_all apply` 激活 JSON 分发。

**特性与行为**：
- **入口与接口**：内置混合代理 `127.0.0.1:1080` 与 TUN（`198.19.0.1/30`，自动路由）；TUN 不接管私网、CGNAT（`100.64.0.0/10`，Tailscale 等）与链路本地（`169.254.0.0/16`）网段；Clash API 仅在本地 `127.0.0.1:9090` 监听，且只允许 `clash.razord.top` / `yacd.haishan.me` 面板的 **https** 地址跨域访问（同时放开私网访问许可，这两个面板从公网页面才能调到本机 API，其余网页的跨域预检仍不通过；用 `http://` 打开面板会被预检拦下，请改用 `https://`）。该 API **刻意不设 `secret`**：同机其他进程仍可直接读写 `127.0.0.1:9090`，多用户主机需自行限制访问，本项目不生成凭证。
- **DNS 与模式切换**：直连模式（`clash_mode=direct`）自动切至国内 DoH 并绕过 Fake-IP（节点故障时直连不中断）；全局模式（`clash_mode=global`）切至境外代理 DoH 防泄露；局域网与认证门户域名始终由本地 DNS 解析。国内（AliDNS + DNSPod）与境外（1.1.1.1 + 8.8.8.8）DoH 各有两个源并行查询，任一源故障不影响解析。
- **DNS 反向映射**：开启 `reverse_mapping: true`，先解析域名再以真实 IP 建连的应用（如微信、Steam 下载）仍能准确命中对应域名直连规则。
- **节点排除**：官方 sing-box 1.14 不支持 `xhttp` 与 `mieru`，亦不支持非标准 `fp`（如 `chromium`）；此类聚合节点会自动从 JSON 排除并在生成时打印提示，Mihomo / Base64 不受影响。
- **规则集更新**：内置 MetaCubeX SRS 规则集（每日更新并缓存）。首次启动需能下载规则集，离线重启自动复用可用缓存。

---

## 5. 局域网 DNS、门户认证与分流优化

- **局域网私网域名**：`.lan`、`.local`、`.internal`、`.localdomain`、`home.arpa` 及 `localhost` 默认内联使用客户端系统 DNS 并直连；无后缀裸设备名（如 `http://nas/`）命中单标签正则直连。如需自定义，可在客户端 DNS 覆写中将 `private-fallback` 指向路由器网关。
- **认证门户（Captive Portal）**：内置主流品牌（Android、Apple、Windows、华为、小米等）连网探测域名集合，始终直连解析，保障公共 Wi-Fi 登录页正常弹出。
- **微信与常用服务分流**：微信图片、朋友圈及小程序域名（`wechat-services`）内联国内 DoH 解析并直连；Steam 下载域名（`steamcontent.com` 等）直连，社区域名（`steamcommunity.com`）走代理；Apple 仅国内调度域名（如 `swcdn.apple.com`）直连，其余 Apple 服务按常规域名/IP 规则分流。
- **Google FCM 推送（Android）**：FCM 域名返回真实 IP，进入内核的 TCP 5228–5230 走 `PROXY` 代理以保证后台推送连通。若前台正常后台不弹窗，请检查：
  1. 关闭“允许绕过 VPN”，确保 Google Play 服务（`com.google.android.gms`）纳入代理；
  2. 关闭应用休眠，允许代理客户端与 Google Play 服务无限制后台运行；
  3. 重启设备清理旧 DNS 缓存。

---

## 6. 低内存客户端适配（iOS / 旧款设备）

默认订阅模板（`templates/mihomo.yaml`）已采用 COMMON 精简规则（7 个 MRS 规则集，无大体积 DAT，以 50MB 常驻内存为优化目标）：
- **iOS 嗅探自动剥离**：iOS 客户端（UA 命中 iOS 或链接追加 `&os=ios`）会自动移除 `sniffer`，避免内存超限被系统 Jetsam 杀后台，并保障 APNs 推送长连接与 ECH 兼容。
- **可选模板切换**：若需更全的境外规则库，服务端可通过环境变量指定并重跑：
  ```bash
  sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo-common.yaml easy_all edit-sub
  ```
  - `templates/mihomo.yaml`（默认）：国内域名/SDK库（约 11 万条）+ 常用域名，轻量低内存。
  - `templates/mihomo-common.yaml`：在默认基础上增加境外常用域名 MRS 规则集。
  - `templates/mihomo-classic.yaml`：全 MRS 规则集（13 个），包含完整 FCM 与微信独立分流。

---

## 7. 常见导入与连接故障排查

若订阅更新报错（`i/o timeout` / `no such host`），通常为本地网络污染导致订阅域名解析失败：
- 在客户端设置中开启**自定义 DNS 覆写**，优先填写 `https://223.5.5.5/dns-query` 或备用 `https://1.1.1.1/dns-query`。

若订阅可更新但节点连不上，按以下顺序排查：
1. **客户端与证书**：确认客户端支持 AnyTLS / VLESS WebSocket（内核 ≥ 1.19.9），且未勾选“跳过证书验证”；
2. **排除优选域名**：运行 `sudo easy_all edit-sub` 删除 `cdnEdgeAddress` 字段后保存并刷新订阅，确认是否为第三方优选地址解析失效；
3. **分流隔离验证**：模式 5 用户先在 `PROXY` 组手动切到直连节点，确认是否仅 CDN 入口受阻；
4. **配额与熔断状态**：运行 `sudo easy_all status` 查看是否达到 985 GB 流量熔断（`blocked=true` 会阻断 CDN 至次月）；
5. **云端状态收敛**：模式 4/5 检查 CloudFront 分发与 ACM 证书是否处于 `Deployed` / `ISSUED` 状态；模式 2/3 检查 Cloudflare DNS 是否为 Proxied 且 SSL/TLS 为 Full (strict)（必要时运行 `sudo easy_all apply-cloud` 收敛）。
