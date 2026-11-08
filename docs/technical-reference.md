# 系统架构与技术参考

本文档记录 `easy_all` 的系统架构设计、网络拓扑、流控与安全策略以及模块职责划分。

---

## 1. 架构总览与网络拓扑

`easy_all` 支持在 Debian 12/13 与 Ubuntu 22.04/24.04 LTS 环境下以单机独占形式部署以下五种模式：

| 菜单 | Profile | `PROTOCOL` | `CDN_PROVIDER` | 入口 |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `reality` | `reality` | 保持原值 | Reality 直连（+ 可选订阅） |
| 2 | `cloudfront` | `cloudfront` | `aws` | 仅 CloudFront CDN |
| 3 | `cloudflare` | `cloudflare` | `cloudflare` | 仅 Cloudflare 橙云 CDN（单域名） |
| 4 | `combined` | `combined-cloudfront` | `aws` | Reality 直连 + CloudFront CDN |
| 5 | `combined-cloudflare` | `combined-cloudflare` | `cloudflare` | Reality 直连 + Cloudflare 橙云 CDN |

模式 2/4 共享 `lib/cloudfront-mode.sh`，模式 3/5 共享 `lib/cloudflare-mode.sh`；Profile 只声明模式常量、状态字段表与（模式 4/5 的）Reality 专属钩子。状态版本号仍为 `0`，五种模式之间没有迁移路径：换模式或从旧版 Cloudflare CDN 安装升级只能卸载重装。

### 1.1 模式 1：直连 Reality
- **协议栈**：VLESS TCP Reality Vision (`flow: xtls-rprx-vision`)
- **服务端端口**：Xray 监听 `0.0.0.0:443`。
- **伪装目标**：默认 `swdist.apple.com:443`，安装和修改时通过 `xray tls ping` 自动完成带 SNI 的 TLS 1.3 握手验收。
- **Short ID 格式约束**：`REALITY_SHORT_ID` 严格约束为 1–8 对（2–16 位）偶数位十六进制字符（`^([0-9a-fA-F]{2}){1,8}$`），写入 Xray 配置与下发前均经正则断言，防止奇数位破坏 Xray 配置解析。
- **动态端口（可选）**：通过 UFW `before.rules` 在 `PREROUTING` 链将 `10000-62703` 范围端口通过单条范围规则 NAT 重定向到实际入站端口（默认 `443`），客户端按时间槽位动态轮换；算法自动探测并避让系统实际的 SSH 监听端口。
- **证书与回源白名单（本模式独有）**：订阅部署时经 Cloudflare 代理回源，`sub.<zone>` 与回源端口 `8443` 使用 Cloudflare Origin CA ECC 证书（15 年有效期，由安装器自动签发/复用/轮换），`8443` 只对 Cloudflare 官方公布的 IPv4 回源网段开放。
- **订阅（可选）**：`deploy` 模式由本机 Nginx 经 Cloudflare 回源下发 Mihomo YAML / Base64，订阅配置与模式 4 共用同一份 `{"allowedTokens":{...},"nodes":[...]}`：`PROXY`（`select`）依次是本机 Reality 节点、聚合 JSON 的 `nodes`；标记 `optional` 的节点仅在 URL 追加 `&node=all` 时下发。`link` 模式只输出本机节点信息。

### 1.2 模式 2：纯 CloudFront
一台 VPS 只承载 CloudFront 入口，不监听直连 Reality：

```text
客户端 ── TLS(SNI=cf.<zone>) ──► CloudFront 分发（ACM viewer 证书，us-east-1）
                                       │ https-only 回源，SNI/Host=origin.<zone>
                                       ▼
公网 80/443  Nginx（Let's Encrypt 源站证书，校验 X-Easy-All-Origin-Key）
  ├─ ^~ ${XHTTP_PATH}/   → 127.0.0.1:10086 Xray VLESS XHTTP stream-up
  ├─ = /easy_all-health  → 固定 easy_all ok（无/错源站头 404）
  └─ = /subscribe        → 本机订阅分发（Mihomo YAML / Base64，Token 鉴权）
```

- **DNS**：Cloudflare 只作权威 DNS，全部记录灰云（DNS only）——源站 `A → VPS`，节点与订阅 `CNAME → 分发域名`。
- **证书**：两套独立证书——viewer 侧 AWS ACM（固定 `us-east-1`，SAN 为节点域名与订阅域名的去重集合）；源站侧 Let's Encrypt（只覆盖源站域名，通过 80 端口 HTTP-01 签发与续期）。
- **分发策略**：缓存关闭策略 `4135ea2d-6df8-44a3-9df3-4b5a84be39ad`、源站请求策略 `b689b0a8-53d0-40ab-baf2-68738e2966ac`（`AllViewerExceptHostHeader`，转发全部 query / User-Agent / Content-Type）、7 种方法与 gRPC、HTTP/2、`TLSv1.2_2021`、`sni-only`、viewer/origin 均 `https-only`，不启用 WAF、访问日志、Origin Shield 或 Route 53。
- **Host 重写**：分发不转发 viewer Host，因此 AWS 回源 SNI/Host 为源站域名（匹配 Let's Encrypt SAN）；Nginx 再把 gRPC `Host` 固定重写为**节点域名**，与 Xray `xhttpSettings.host` 一致。客户端侧的 server/SNI/Host 统一为节点域名。
- **订阅**：本机节点只有一个 CDN 节点（默认名 `🇺🇸AWS`，安装时可改），没有优选 IP、测速组或自动兜底节点。

### 1.3 模式 3 / 5：Cloudflare 橙云（单域名）

模式 3 只承载橙云入口；模式 5 在同一台机器上再加固定 `8443` 的 Reality 直连入口。两者共用同一套橙云核心：

```text
客户端 ── TLS(SNI=cf.<zone>) ──► Cloudflare 边缘（通用边缘证书，橙云代理）
                                       │ https-only 回源（Full strict），SNI/Host=cf.<zone>
                                       ▼
公网 443（仅 Cloudflare 官方回源 IPv4 段）Nginx（Origin CA 证书）
  ├─ ^~ ${XHTTP_PATH}/   → 127.0.0.1:10086 Xray VLESS XHTTP stream-up
  ├─ = /easy_all-health  → 固定 easy_all ok
  └─ = /subscribe        → 本机订阅分发（Mihomo YAML / Base64，Token 鉴权）
```

- **DNS**：节点域名一条 `proxied=true` 的 `A` 记录（→ VPS 公网 IPv4），注释为 `easy_all cloudflare`（模式 5 为 `easy_all combined-cloudflare`）；模式 5 的直连域名是灰云 `A`。节点域名必须是 Zone 的一级子域名。
- **证书**：只用 Cloudflare Origin CA（ECDSA P-256、5475 天、CN 与唯一 SAN 都是节点域名），本机不运行 Certbot、不开放 `80`；复用前除有效期/SAN/公私钥外还必须通过 `openssl verify` 链验证，非 Origin CA 签发的同名证书会被重新签发。
- **单 server 路由**：一个业务 `server` 块同时承载 health、XHTTP 与 `/subscribe`，`server_name` 只有节点域名；未知 SNI 由 `ssl_reject_handshake on` 的默认 server 拒绝。历史上节点/订阅分立的双 server 写法在同名时会互相遮蔽，因此不再使用。
- **无源站头、无熔断**：橙云链路没有 `X-Easy-All-Origin-Key`，也没有 StatsService、`cdn-traffic-sync` 与 985 GB 额度（这些只属于模式 2/4）。
- **`apply` 的外部访问**：只读取公开的 Cloudflare 回源 IPv4 段与 Origin CA 根证书，不需要账号凭据、不修改云端。

---

### 1.4 模式 4：直连+CloudFront
一台 VPS 独占承载直连与 CDN 两个入口：

```text
公网 8443  Xray VLESS Reality（直连入口，伪装目标另配 SNI）
公网 80/443 Nginx（与模式 2 相同）
  ├─ ^~ ${XHTTP_PATH}/   → 127.0.0.1:10086 Xray VLESS XHTTP stream-up
  ├─ = /easy_all-health  → 固定 easy_all ok（无/错源站头 404）
  └─ = /subscribe        → 本机订阅分发（Token 鉴权）
```

- **端口划分**：直连入站固定在 `8443`，CloudFront 回源与订阅共用 `80/443`。
- **证书**：与模式 2 完全一致（ACM viewer + Let's Encrypt 源站）。Reality 不使用源站证书，因此直连域名可以与源站域名复用同一条灰云 `A` 记录（端口不同、证书互不影响）。
- **订阅**：本机节点恰为两个——Reality 直连（默认名 `🇺🇸直连`）与 CloudFront CDN（默认名 `🇺🇸AWS`）；两者之间由用户在 `PROXY` 组里**手动切换**，没有自动测速或兜底组。

## 2. 防火墙、端口与安全边界

### 2.1 SSH 端口保持与保护
- **端口保持与防火墙策略**：
  - 各模式均保留系统原有 SSH 监听端口（默认 22），不强行迁移端口，避免因云安全组限制导致失联。
  - UFW 设置默认入站拒绝、默认转发拒绝，仅放行必要端口，未放行端口由默认策略阻断。
  - Fail2ban 自动配置 sshd jail 实时监控保护实际 SSH 端口。
- **常驻安全基线归初始化**：`scripts/debian-init.sh` 负责激活 UFW（SSH 端口、ICMP 回显与出站放行）并配置 Fail2ban；easy_all 安装只在此基础上追加业务端口。
- **规则规格删除防编号漂移**：业务端口与回源白名单的清理升级为规则规格删除（通过 `stale_ufw_rule_delete_specs` 生成规格并执行 `ufw delete`），替代易受并发插桩干扰的行号逆序删除，彻底规避了 Fail2ban 动态插入规则导致的编号漂移与误删。
- **卸载与回滚只回收业务端口**：各模式 `uninstall` 与安装失败回滚一律只删除自己注入的 `80`/`443`/`8443` 放行、动态端口 NAT 重定向与 CDN 回源白名单，保留 UFW 启用状态、默认策略、SSH 放行与 Fail2ban 配置，不再执行 `ufw disable`。
- **Fail2ban 助手脚本解耦**：CIDR 封禁助手安装到 `/usr/local/sbin/fail2ban-ufw-cidr.sh`（不再位于 `/usr/local/lib/easy_all`），卸载 easy_all 时保留，避免常驻 SSH 封禁动作因脚本缺失而失效。
- **重装跳过已就绪的初始化**：卸载后重装时，依赖包、Swap、内核与 TCP 加速已就绪就跳过重复安装；IPv4-only、定时重启与 UFW/Fail2ban 仍会幂等校验。
- **定时维护互斥与安全加固**：每日定时重启任务引入运行时写锁检测（`flock -n 8`），检测到后台有安装或更新进行时自动跳过重启并向 syslog 记录审计日志，防止并发维护造成半安装现场；模式 2/4 还会在取得最终写锁后只读复核流量保护状态（`protection_offline=false` 且 `blocked=enforced`），不满足则跳过重启。crontab 任务命令统一对 `%` 进行了转义。

### 2.2 各模式端口与监听

| 模式 | UFW 公网放行 | 仅回源白名单放行 | 仅本机回环监听 |
| :--- | :--- | :--- | :--- |
| 初始化（debian-init） | SSH 实际监听端口 | — | — |
| 1 直连 Reality | TCP `443` | 订阅部署时 TCP `8443`（Cloudflare 官方 IPv4 回源段） | — |
| 2 纯 CloudFront | TCP `80`、`443` | — | `127.0.0.1:10085`（StatsService API）、`127.0.0.1:10086`（XHTTP） |
| 3 纯 CloudFlare（单域名） | — | TCP `443`（Cloudflare 官方 IPv4 回源段） | `127.0.0.1:10086`（XHTTP） |
| 4 直连+CloudFront | TCP `80`、`443`、`8443` | — | 同模式 2 |
| 5 直连+CloudFlare | TCP `8443` | TCP `443`（Cloudflare 官方 IPv4 回源段） | `127.0.0.1:10086`（XHTTP） |

- `80` 只用于 Let's Encrypt HTTP-01（`/.well-known/acme-challenge/`），其他路径一律 `404`，不提供订阅或代理；云链路（3/5）不使用 `80`。
- 模式 1 的动态端口模式在 `PREROUTING` 注入 `10000:62703` → 实际入站端口（默认 `443`）的 NAT；模式 2/3/4/5 没有动态端口。
- `10085`/`10086` 永不对公网放行；端口预检会覆盖各模式实际使用的端口（模式 2/4：`80`、`443`、`10085`、`10086`，模式 4 另加 `8443`；模式 3/5：`443`、`10086`，模式 5 另加 `8443`）。
- 所有模式维持 IPv4-only、默认 incoming/routed deny、outgoing allow、SSH 预检与 Fail2ban。

### 2.3 源站暴露面（各链路差异）

- **模式 1 与模式 3/5** 保留 Cloudflare 回源白名单：安装器只向 Cloudflare 官方 IPv4 网段新增回源端口放行（模式 1 是订阅回源 `8443`，模式 3/5 是橙云回源 `443`）。在宿主没有其他公网放行、云安全组也未额外放通的前提下，外部扫描器直连该端口会被静默丢弃；宿主已有的无注释放行不在本工具管理范围。这是**公共回源网段**，不是账户级鉴权。
- **模式 5 的灰云直连域名**会公开 VPS 公网 IPv4（Reality 入口 `8443` 对公网开放）。
- **模式 2/4 不再有任何回源白名单**：CloudFront 回源没有可枚举的固定 IP 段，因此源站 `443` 对公网可达。实际防护依赖：
  - 公信 Let's Encrypt 源站证书（自签证书无法通过 CloudFront 的 HTTPS 回源验证）；
  - `443` 的默认 server 使用 `ssl_reject_handshake on`，未知 SNI 直接拒绝握手；
  - 随机 XHTTP 路径 + 精确前缀保护；
  - `X-Easy-All-Origin-Key` 源站头：健康检查无/错头 `404`，XHTTP 无/错头 `403`，订阅无/错头 `404`；
  - VLESS UUID 与订阅 Token 鉴权，以及内部订阅 alias 只能由 Nginx 内部跳转。
- 这些措施**不能**防御网络层 DDoS、TLS/HTTP 资源耗尽或密钥泄露。源站头密钥只存在于状态文件、Nginx 配置与 AWS 请求暂存 JSON（均 `0600`），不下发客户端、不进订阅、不写访问日志。

### 2.4 恶意出站与内部阻断
- Xray 服务端默认配置阻断私网地址（RFC 1918）、链路本地地址（169.254.0.0/16）、回环地址以及云厂商元数据接口。
- 拒绝境外 UDP/443 请求，强制 QUIC 连接降级回退至 TCP（服务端 Udp/443 也有独立 block 路由）。
  客户端 Mihomo 模板的嗅探（`sniffer`）同样不覆盖 QUIC：否则这次拒绝会被握手解析拖慢
  （Android 上表现为 Google Play 下载长期停在“等待中”）。

---

## 3. 订阅分发与渲染

- **原子渲染**：订阅文件在生成时先写入临时暂存目录，校验完整无缺后逐文件原子替换，防止高并发下载时读到半截内容（这是「单文件原子」而非整目录快照）。
- **六种产物**：`base64.txt`、`mihomo.yaml`、`mihomo-ios.yaml`（默认过滤 `optional` 节点）与 `base64-all.txt`、`mihomo-all.yaml`、`mihomo-ios-all.yaml`（`&node=all` 时附带 `optional` 节点）。iOS 变体只从 YAML 剥离以 `sniffer:` 开头的整段，其余规则不变。
- **客户端自适应**：
  - 根据 HTTP 请求头中的 `User-Agent` 自动识别客户端；
  - Clash / Mihomo 客户端自动返回格式合法的 YAML 订阅（采用最新 MRS 规则集）；
  - 通用客户端返回经过 Base64 编码的节点 URI 列表；
  - 亦支持在 URL 参数中追加 `flag=clash` 或 `flag=base64` 强制指定下发格式，`os=ios` 强制 iOS 变体，`node=all` 附带可选聚合节点。
- **平台自适应（嗅探段）**：默认模板开启 `sniffer`。UA 命中 `iphone|ipad|ipod|ios`（`ios` 需独立单词，避免 `Studios`/`Radios` 之类 UA 被误判）或在 URL 追加 `os=ios` 时，
  下发单独渲染的 YAML，剔除以 `sniffer:` 开头的整段配置（兼顾 iOS 内存预算、防 APNs 推送干扰、私有协议首包延迟与 CDN 调度劣化）；
  模板若把 `sniffer` 写成内联映射，安装会直接报错，不会静默下发未剔除的嗅探段。

### 3.1 节点与分组顺序

Base64 平铺顺序与 Mihomo `proxies` 顺序完全一致，`PROXY` 组的成员顺序也与之相同：

| 模式 | 平铺顺序 / `PROXY` 成员 |
| :--- | :--- |
| 2 纯 CloudFront | CloudFront 节点 → 聚合 `nodes`（原顺序） |
| 3 纯 CloudFlare | Cloudflare 橙云节点 → 聚合 `nodes`（原顺序） |
| 4 直连+CloudFront | 本机 Reality 节点 → CloudFront 节点 → 聚合 `nodes`（原顺序） |
| 5 直连+CloudFlare | 本机 Reality 节点 → Cloudflare 橙云节点 → 聚合 `nodes`（原顺序） |

- `PROXY` 为 `select`，默认第一项分别是 CDN 节点（模式 2/3）或直连节点（模式 4/5）；即使聚合节点为空也始终有有效成员。
- `GLOBAL` 维持 `select`，唯一成员是 `PROXY`；切换到「全局」后所有接管流量使用 `PROXY` 的当前选择。
- 不生成任何额外 CDN 测速组或兜底组，`build_mihomo_proxy_groups` 输出合法空文件，模板只保留 `PROXY` / `GLOBAL` 两个占位区。
- 聚合节点支持三类：`vless` + `reality/tcp`、`vless` + `tls/xhttp`、`mieru`；外部聚合 XHTTP 节点仍允许自有 IP/域名，不受「本机只有一个 CDN 节点」的限制。

---

## 4. CDN 流量计量与双层阻断

### 4.1 统计链路
- Xray 配置启用 `stats: {}`、`policy.system.statsInboundUplink/statsInboundDownlink = true`，并新增监听 `127.0.0.1:10085` 的 `dokodemo-door` API 入站（tag `easy-all-api`，`services: ["StatsService"]`）。routing 最前面把该入站交给 API tag，因此它不产生用户流量。
- guard 只读取 `inbound>>>vless-xhttp-in>>>traffic>>>uplink/downlink` 两个计数，**不对所有 `user>>>` 求和**，模式 4 的 Reality 流量因此不计入 CDN 用量。
- API 超时或返回不合法（缺字段、负数）视为失败，**不能默认为 0**；尚无流量时的真实零计数是合法读数。
- 阈值固定 `985 × 10⁹` 字节，双协议（模式 2/4）均启用；状态里的 `CDN_TRAFFIC_PROTECTION_GB` 必须恰为 `985`，不能用环境变量绕过。

### 4.2 用量文件与月度
- `/etc/easy_all/cdn-traffic-usage.json`（`0600`，同目录临时文件 + 原子 rename）字段白名单：`period` / `runtime_id` / `used_bytes` / `last_uplink` / `last_downlink` / `blocked` / `enforced` / `protection_offline`。
- 合法的旧七字段文件只在读取时把缺失的 `protection_offline` 解释为 `false`，下一次原子更新补齐；其他缺字段、类型错误或违反「`protection_offline=true` 必须同时满足 `blocked=true`、`enforced=false`」都判为损坏。损坏时拒绝操作并告警，不会创建替代文件或清零。
- `period` 按 **UTC 自然月**；只有 API 读数成功后才推进月份，跨月边界会把整段采样增量计入新月份后重新判阈值。systemd `InvocationID` 变化时把新进程读数叠加到已有 `used_bytes`，计数回退按重启处理，已持久用量不丢失。
- 用量与保护标记不参加本机配置事务回滚，旧快照不会覆盖新 usage。

### 4.3 双层阻断与恢复
达到阈值后 `blocked=true`，由 `rebuild_traffic_runtime` 落实：

1. **Nginx 层**：XHTTP 精确前缀位置直接 `return 503`，健康检查与订阅保持可用。
2. **Xray 层**：XHTTP 入站的 `clients` 置为空数组，并加一条最优先的 `vless-xhttp-in → block` 路由；模式 4 的 Reality clients/routing 不变。随后**重启 Xray**——只 reload Nginx 会保留旧 worker 的长连接，无法完成阻断。
3. 解封只在「成功采样确认 `blocked=false`」且订阅就绪后进行，成功验收才写 `enforced=false`。

待落实（`blocked != enforced`）由所有入口共用的同一个只读判定识别，并由同一个受限恢复函数收敛：先应用 XHTTP `503` 与受限 Nginx，再启动受限 Xray（`clients=[]` + block 路由 + API + 模式 4 Reality），必需验收（Nginx 503、受限配置与旧连接终止、严格源站 TLS/health、模式 4 的 `8443` 监听、真实 StatsService 两项非负计数）全部通过后，才原子写 `enforced=true`、`protection_offline=false` 并保留全部计数。必需验收失败会把 `protection_offline` 先落盘再停止 Xray，下一轮从同一入口重试；解封失败则恢复原来的受限配置并保留解封 pending，绝不恢复开放配置后报成功。

### 4.4 这是近似保护，不是账单保证
- 阈值来自**本机 Xray 入站计数**，不是 AWS 账单真源：HTTP/HTTPS 请求费、订阅下载、TLS/HTTP 自身开销、同一账号的其他分发或其他机器的用量、进程崩溃/关机期间缺失的最后一个采样窗口都不在统计内。
- 因此它只能降低超额风险，**不承诺零账单，也不是任何形式的账单保底**；CloudFront 的免费额度与计费标准以你 AWS 账号当前的条款和账单为准。

---

## 5. 目录结构与模块划分

```text
easy_all
├── bootstrap.sh                 # 远程一键安装拉取器
├── easy_all                     # CLI 统一管理入口与命令调度
├── runtime.manifest             # 运行时受管文件清单
├── profiles/
│   ├── reality.sh               # 模式 1：直连 Reality 业务编排
│   ├── cloudfront.sh            # 模式 2：纯 CloudFront 薄 Profile（仅常量与空直连钩子）
│   ├── combined.sh              # 模式 4：直连+CloudFront 薄 Profile（Reality 输入/密钥/入站/链接）
│   ├── cloudflare.sh            # 模式 3：纯 CloudFlare 薄 Profile（单域名，空直连钩子）
│   └── combined-cloudflare.sh   # 模式 5：直连+CloudFlare 薄 Profile
├── lib/
│   ├── log.sh                   # 日志与双语输出
│   ├── platform.sh              # 系统环境、Debian 探测与基础依赖
│   ├── runtime-core.sh          # 跨模式通用运行时（更新、自更新、命令注册、停机清理）
│   ├── profile-common.sh        # Profile 映射、安装身份与快照/续装/回滚
│   ├── network.sh               # 网络与 IPv4/域名基础校验
│   ├── reality-target.sh        # Reality 伪装目标校验与 ASN 探测
│   ├── reality-subscription.js  # 模式 1 本地自托管订阅生成器（动态端口槽位）
│   ├── cf-dns.sh                # Cloudflare API / DNS / Origin CA / 回源网段（模式 1 主用）
│   ├── cloudfront-state.sh      # CloudFront 状态字段单一来源与结构校验规则
│   ├── cloudfront-mode.sh       # 模式 2/4 唯一 CloudFront 业务核心
│   ├── cloudflare-state.sh      # Cloudflare 链路状态字段单一来源
│   ├── cloudflare-mode.sh       # 模式 3/5 唯一橙云业务核心（单域名 + Origin CA + 回源白名单）
│   ├── cdn-traffic-guard.sh     # CDN 入站计量、985 GB 阈值与 systemd timer
│   ├── cloudflare-purge.sh      # Cloudflare 远端托管资源识别与清理
│   ├── xhttp-runtime.sh         # XHTTP 运行时公共逻辑、订阅发布与证书挂载
│   ├── firewall.sh              # UFW 规则配置与状态快照
│   ├── subscription-auth.sh     # 订阅凭据、UA/flag/os/node 协商与 Nginx 订阅段
│   ├── local-aggregation.sh     # 本地聚合节点校验与渲染（全模式共用）
│   ├── scheduled-maintenance.sh # 定时重启与维护任务
│   ├── tcp-tuning.sh            # Skyline Speeder 与 Zabbly 6.12+ LTS 内核管理
│   ├── xray-core.sh             # Xray 官方二进制下载与校验
│   └── mihomo-template.sh       # Mihomo 订阅模板结构校验与渲染
├── templates/                   # 内置 Mihomo 订阅配置模板与聚合示例
│   ├── mihomo.yaml              # 默认 COMMON 精简规则模板
│   ├── mihomo-common.yaml       # 完整 COMMON 规则模板
│   ├── mihomo-classic.yaml      # 经典 MRS 规则集模板
│   └── aggregation.example.json # 聚合节点（三类）配置示例
└── scripts/                     # 辅助构建与系统初始化脚本
    └── debian-init.sh           # 独立系统初始化加固工具（Debian 12/13、Ubuntu 22.04/24.04）
```

### 5.1 模式 2/4 与 3/5 的模块边界
- **Profile 只声明、不复制**：`CDN_PROFILE_KEY`、`CDN_EXPECTED_PROTOCOL`、`CDN_MODE_LABEL`、`CDN_ENTRY_SUMMARY`、`CDN_INSTALL_PORTS`、`CDN_STATE_VARIABLES`，以及同名直连钩子（模式 2 返回空值）。
- **核心持有公共契约**：AWS 常量（`us-east-1`、两条策略 ID、回源时限、头名、DNS 注释）、状态白名单与校验、DNS/ACM/分发、源站证书、XHTTP/Nginx/UFW、订阅渲染、运维事务、熔断重建、安装与卸载。
- **共享运行时保持中立**：`xhttp-runtime.sh` 提供六产物发布与订阅验收；模式 1 的 Origin CA 回滚留在 `profiles/reality.sh` 自己的同名实现里，CloudFront 的云资源默认保留。
- **橙云核心并列而非抽象**：`cloudflare-mode.sh` 与 `cloudfront-mode.sh` 各自持有 Provider 语义（橙云 A 记录/Origin CA/回源白名单 vs ACM/分发/源站证书/源站头），共用 `cf-dns.sh` 的 Cloudflare API 层与同一套 Profile 钩子契约。每个进程只加载所选链路的 Profile 与核心，因此同名生命周期函数（`load_state`、`apply_easy_all`、`install_all` 等）不会冲突；不引入跨 Provider 抽象层。
