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
