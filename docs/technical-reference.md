# 系统架构与技术参考

本文档记录 `easy_all` 的系统架构设计、网络拓扑、流控与安全策略以及模块职责划分。

---

## 1. 架构总览与网络拓扑

`easy_all` 支持在 Debian 12/13 与 Ubuntu 22.04/24.04 LTS 环境下以单机独占形式部署以下模式：

### 1.1 模式 1：直连 Reality
- **协议栈**：VLESS TCP Reality Vision (`flow: xtls-rprx-vision`)
- **服务端端口**：Xray 监听 `0.0.0.0:443`。
- **伪装目标**：默认 `swdist.apple.com:443`，安装和修改时通过 `xray tls ping` 自动完成带 SNI 的 TLS 1.3 握手验收。
- **动态端口（可选）**：通过 UFW `before.rules` 在 `PREROUTING` 链将 `10000-62703` 范围端口通过单条范围规则 NAT 重定向到实际入站端口（默认 `443`），客户端按时间槽位动态轮换。

### 1.2 模式 2：Cloudflare CDN（纯 XHTTP）
- **数据面拓扑**：
  ```text
  客户端 -> Cloudflare 优选 IPv4 -> Cloudflare 边缘 -> Nginx (TCP 443) -> Xray (127.0.0.1:10086 XHTTP stream-up)
  ```
- **优选机制**：利用 Globalping 从三网探针每 3 小时动态筛选 6 个经过 HTTP/TLS 握手校验的优选节点。

### 1.3 模式 3：Bunny CDN
- **数据面拓扑**：
  ```text
  客户端 -> Bunny CDN 自动调度边缘 -> Nginx (TCP 443 HTTPS) -> Xray (127.0.0.1 WS)
  ```
- **调度特点**：通过 Bunny Pull Zone 自带的 Anycast 边缘网络调度，无需本地筛选 IP。

### 1.4 组合模式（Reality + Cloudflare XHTTP）
一台 VPS 独占承载直连与 CDN 两个入口：
```text
公网 8443  Xray VLESS Reality（直连入口，伪装目标另配 SNI）
公网 443   Nginx
  ├─ cf.<zone>            → 127.0.0.1:10086 Xray VLESS XHTTP stream-up（Cloudflare 官方回源）
  └─ sub.<zone>           → 本地订阅分发（Mihomo YAML / Base64）
```
- **端口划分**：直连入站固定在 `8443`，CDN 回源与订阅共用 `443`。
- **证书管理**：`cf` 与 `sub` 共用一张 15 年有效期的 Cloudflare Origin CA ECC 证书。
- **单一订阅**：订阅下发「直连 1 个」+「Cloudflare 优选 6 个」，并在 Mihomo 中平铺进单一 `AUTO` 自动测速选优组。

---

## 2. 防火墙与安全边界

### 2.1 SSH 端口保持与保护
- **端口保持与防火墙策略**：
  - 各模式均保留系统原有 SSH 监听端口（默认 22），不强行迁移端口，避免因云安全组限制导致失联。
  - UFW 设置默认入站拒绝，仅放行必要端口，未放行端口由默认策略阻断。
  - Fail2ban 自动配置 sshd jail 实时监控保护实际 SSH 端口。
- **常驻安全基线归初始化**：`scripts/debian-init.sh` 负责激活 UFW（SSH 端口、ICMP 回显与出站放行）并配置 Fail2ban；easy_all 安装只在此基础上追加业务端口。
- **卸载与回滚只回收业务端口**：各模式 `uninstall` 与安装失败回滚一律只删除自己注入的 443/8443 放行、动态端口 NAT 重定向与 CDN 回源白名单，保留 UFW 启用状态、默认策略、SSH 放行与 Fail2ban 配置，不再执行 `ufw disable`。
- **Fail2ban 助手脚本解耦**：CIDR 封禁助手安装到 `/usr/local/sbin/fail2ban-ufw-cidr.sh`（不再位于 `/usr/local/lib/easy_all`），卸载 easy_all 时保留，避免常驻 SSH 封禁动作因脚本缺失而失效。
- **重装跳过已就绪的初始化**：卸载后重装时，依赖包、Swap、内核与 TCP 加速已就绪就跳过重复安装；IPv4-only、定时重启与 UFW/Fail2ban 仍会幂等校验。

### 2.1.1 各模式开放端口

| 模式 | 全局放行 | 仅回源白名单放行 | 其他 |
| --- | --- | --- | --- |
| 初始化（debian-init） | SSH 实际监听端口 | — | ICMP 回显（UFW 默认）与全部出站；UFW 默认入站拒绝 |
| 1 直连 Reality | TCP 443 | TCP 8443（仅订阅模式非 `link` 时，Cloudflare 订阅回源） | 动态端口模式在 `PREROUTING` 注入 `10000:62703` → 实际入站端口（默认 443）NAT |
| 2 Cloudflare CDN | — | TCP 443（Cloudflare 官方 IPv4 回源段） | 外网直连 443 被丢弃 |
| 3 Bunny CDN | — | TCP 443（Bunny 官方回源 IPv4 池） | 白名单由 `easy_all-bunny-ips.timer` 持续刷新 |
| 4 组合模式 | TCP 8443（Reality 直连） | TCP 443（Cloudflare 官方 IPv4 回源段） | 两入口共用同一套 UFW/Fail2ban 基线 |

### 2.2 回源白名单与防扫描
- 在涉及 Cloudflare 的模式中，本地 Nginx 与防火墙严格限制：
  - UFW 仅向 Cloudflare 官方公布的 IPv4 网段开放 TCP `443`；
  - 外部扫描器直接探测源站 IP 443 端口会被防火墙静默丢弃（DROP）。

### 2.3 恶意出站与内部阻断
- Xray 服务端默认配置阻断私网地址（RFC 1918）、链路本地地址（169.254.0.0/16）、回环地址以及云厂商元数据接口。
- 拒绝境外 UDP/443 请求，强制 QUIC 连接降级回退至 TCP。

---

## 3. 订阅分发与自适应机制

- **原子渲染**：订阅文件在生成时先写入临时暂存目录，校验完整无缺后原子替换，防止高并发下载时读到半截内容。
- **客户端自适应**：
  - 根据 HTTP 请求头中的 `User-Agent` 自动识别客户端；
  - Clash / Mihomo 客户端自动返回格式合法的 YAML 订阅（采用最新 MRS 规则集）；
  - 通用客户端返回经过 Base64 编码的节点 URI 列表；
  - 亦支持在 URL 参数中追加 `flag=clash` 或 `flag=base64` 强制指定下发格式。
- **平台自适应（嗅探段）**：默认模板开启 `sniffer`。UA 命中 `iphone|ipad|ipod|ios`（`ios` 需独立单词，避免 `Studios`/`Radios` 之类 UA 被误判）或在 URL 追加 `os=ios` 时，
  下发单独渲染的 YAML（`mihomo-ios.yaml` / `mihomo-ios.port-template`），剔除以 `sniffer:` 开头的整段配置（兼顾 iOS 内存预算、防 APNs 推送干扰、私有协议首包延迟与 CDN 调度劣化）；
  模板若把 `sniffer` 写成内联映射，安装与 Worker 构建会直接报错，不会静默下发未剔除的嗅探段。

---

## 4. 目录结构与模块划分

```text
easy_all
├── bootstrap.sh                 # 远程一键安装拉取器
├── easy_all                     # CLI 统一管理入口与命令调度
├── runtime.manifest             # 运行时受管文件清单
├── profiles/
│   ├── reality.sh               # 模式 1：直连 Reality 业务编排
│   ├── xhttp-cloudflare-streamup.sh # 模式 2：Cloudflare CDN 业务编排
│   ├── ws-bunny.sh              # 模式 3：Bunny CDN 业务编排
│   └── combined.sh              # 模式 4：组合模式业务编排
├── lib/
│   ├── log.sh                   # 日志与双语输出
│   ├── platform.sh              # 系统环境、Debian 探测与基础依赖
│   ├── runtime-core.sh          # 跨模式通用运行时
│   ├── profile-common.sh        # Profile 通用流程、状态持久化与回滚
│   ├── network.sh               # 网络与 IPv4/域名基础校验
│   ├── reality-target.sh        # Reality 伪装目标校验与 ASN 探测
│   ├── reality-subscription.js  # 本地自托管订阅生成器
│   ├── cloudflare-ip-pool.sh    # Cloudflare 候选 IP 池与抽样验证
│   ├── globalping-cdn.sh        # Globalping 探针调用与三网优选
│   ├── cf-dns.sh                # Cloudflare API 封装（DNS/Origin CA/Rules）
│   ├── cloudflare-purge.sh      # Cloudflare 远端托管资源识别与清理
│   ├── bunny-api.py             # Bunny API 与 Cloudflare DNS-01/Pull Zone 调度
│   ├── bunny-runtime.sh         # Bunny 模式专属运行时与回源白名单
│   ├── lego-install.sh          # Lego Let's Encrypt 证书签发与安装
│   ├── xhttp-runtime.sh         # XHTTP 运行时公共逻辑与证书挂载
│   ├── firewall.sh              # UFW 规则配置与状态快照
│   ├── subscription-auth.sh     # 订阅凭据生成与校验
│   ├── scheduled-maintenance.sh # 定时重启与维护任务
│   ├── tcp-tuning.sh            # Skyline Speeder 与 Zabbly 6.12+ LTS 内核管理
│   ├── xray-core.sh             # Xray 官方二进制下载与校验
│   ├── worker-config.sh         # Cloudflare Worker 订阅聚合配置与发布
│   ├── worker-backup.sh         # 独立 Worker 兜底节点配置与部署
│   └── mihomo-template.sh       # Mihomo 订阅模板结构校验与渲染
├── worker-src/                  # Cloudflare Worker 订阅聚合与兜底源码
│   ├── index.js                 # 订阅聚合 Worker 源码
│   └── backup.js                # 独立节点 Worker 源码
├── templates/                   # 内置 Mihomo 订阅配置模板
│   ├── mihomo.yaml              # 默认 COMMON 精简规则模板
│   ├── mihomo-common.yaml       # 完整 COMMON 规则模板
│   └── mihomo-classic.yaml      # 经典 MRS 规则集模板
└── scripts/                     # 辅助构建与系统初始化脚本
    ├── build-worker.mjs         # Worker 打包编译脚本
    └── debian-init.sh           # 独立系统初始化加固工具（Debian 12/13、Ubuntu 22.04/24.04）
```
