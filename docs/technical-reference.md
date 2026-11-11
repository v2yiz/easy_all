# 系统架构与技术参考

本文档记录 `easy_all` 的系统架构设计、网络拓扑、流控与安全策略以及模块职责划分。

---

## 1. 架构总览与网络拓扑

`easy_all` 支持在 Debian 12/13 与 Ubuntu 22.04/24.04 LTS 环境下以单机独占形式部署以下五种模式。本机运行时统一为官方 sing-box（节点入站）与官方 Caddy（订阅与 CDN 回源站点），一台 VPS 只能选择一种模式：

| 菜单 | Profile | `PROTOCOL` | `CDN_PROVIDER` | 客户端入口 |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `anytls` | `anytls` | 无 | AnyTLS 直连 `direct:443`（+ 可选订阅站点 `8443`） |
| 2 | `cloudfront` | `cloudfront` | `aws` | 仅 CloudFront CDN `cf:443`（+ 订阅） |
| 3 | `cloudflare` | `cloudflare` | `cloudflare` | 仅 Cloudflare 橙云 CDN `cf:443`（单域名，同时承载订阅） |
| 4 | `combined` | `combined-cloudfront` | `aws` | AnyTLS 直连 `direct:443` + CloudFront CDN `cf:443` |
| 5 | `combined-cloudflare` | `combined-cloudflare` | `cloudflare` | AnyTLS 直连 `direct:443` + Cloudflare 橙云 CDN `cf:443`（单域名，同时承载订阅） |

模式 1/5 由 `lib/anytls-mode.sh` 承载，模式 2/4 共用 `lib/cloudfront-mode.sh`，模式 3 由 `lib/cloudflare-mode.sh` 承载；Profile 只声明模式常量、状态字段表与 AnyTLS 直连钩子。

- **状态 schema 固定为 `1`**（`STATE_VERSION=1`）：`PROTOCOL` 同时是模式选择、安装进度 marker、安装身份与 Profile 路由的唯一键。schema `0`（4.x）不被接管也不自动迁移，必须先由旧版本 `uninstall`（需要时加 `--purge-cloud`）再用本版本重装。
- **本机节点与全部订阅入口统一 443**：AnyTLS 入站 443、CloudFront viewer 443、橙云边缘 443。模式 1 的订阅站点、模式 4 的源站与模式 5 的橙云回源监听 `8443`，那是 Cloudflare/CloudFront 的回源端口，不面向客户端。
- **唯一的 CDN 传输是 WebSocket**（sing-box `transport: {type: "ws"}`）；`httpupgrade` 不提供安装选项，也不在验收范围内。
- 用户订阅 JSON 里的外部聚合节点保留原有 `host/port/portRange`，不强制改写为 443。

### 1.1 模式 1：AnyTLS 直连
- **协议栈**：sing-box `anytls` 入站，`listen 0.0.0.0`、`listen_port 443`，单用户 `easy_all` + 随机密码；TLS 使用本机证书与 `DIRECT_DOMAIN` 作为 `server_name`。
- **证书**：Certbot + Cloudflare DNS-01 签发 Let's Encrypt 证书，SAN 覆盖直连域名与已部署的订阅域名；不开放 `80`。
- **`link` 与 `deploy`**：`link` 只输出 AnyTLS 链接与 Mihomo 节点，不建 Caddy 站点、不写 Origin Rule；`deploy` 才部署订阅站点。
- **订阅回源（deploy）**：Caddy 在 `0.0.0.0:8443` 提供 `https://<订阅域名>:8443`，UFW 只对该端口放行 Cloudflare 官方回源 IPv4 段（注释 `easy_all-cf-origin-8443`）。订阅域名是橙云 `A` 记录，Cloudflare 侧用一条 `http_request_origin` Origin Rule 把 `http.host eq <订阅域名>` 路由到 `origin.port 8443`。
- **Origin Rule 生命周期**：只用单规则端点——不存在该 phase 的 ruleset 时，创建请求直接携带本工具的单条规则；已有 ruleset 时用 `POST /zones/{zone_id}/rulesets/{ruleset_id}/rules` 追加，更新/删除使用带 `rule_id` 的单规则端点。`ref` 由规范化域名确定性派生，ruleset/rule ID 落盘到 state；禁止「GET 合并旧快照后整体 PUT」。
- 模式 1 没有 CloudFront 源站头，也没有 985 GB 计量保护。

### 1.2 模式 2：纯 CloudFront
一台 VPS 只承载 CloudFront 入口，不监听直连节点：

```text
客户端 ── TLS(SNI=cf.<zone>) ──► CloudFront 分发（ACM viewer 证书，us-east-1，viewer 443）
                                       │ https-only 回源 443，SNI/Host=origin.<zone>
                                       ▼
公网 443   Caddy（Let's Encrypt 源站证书；route 首位 CEL 精确校验 X-Easy-All-Origin-Key）
  ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS WebSocket，回环不启用 TLS）
  ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅
  ├─ = /easy_all-health    → 固定 easy_all ok
  └─ 其他路径              → 404
```

- **DNS**：Cloudflare 只作权威 DNS，全部记录灰云（DNS only）——源站 `A → VPS`，节点 `CNAME → 分发域名`。订阅域名固定复用节点域名，因此只有一条 CNAME。
- **证书**：两套独立证书——viewer 侧 AWS ACM（固定 `us-east-1`，SAN 为节点域名；订阅同域，去重后只有一项）；源站侧 Let's Encrypt（只覆盖源站域名，经 Cloudflare DNS-01 签发与续期，不开放 `80`）。旧装若已配置独立订阅域名，仍保留原 CNAME 与两项 SAN。
- **分发策略**：缓存策略 `CachingDisabled`（`4135ea2d-6df8-44a3-9df3-4b5a84be39ad`）、源站请求策略 `AllViewerExceptHostHeader`（`b689b0a8-53d0-40ab-baf2-68738e2966ac`，转发全部 query / User-Agent / Content-Type 与 WebSocket 升级所需头）、7 种方法、HTTP/2、`TLSv1.2_2021`、`sni-only`、viewer/origin 均 `https-only`、源站 TLS 1.2；`GrpcConfig` 关闭，不启用 WAF、访问日志、Origin Shield 或 Route 53。
- **Host 处理**：分发不转发 viewer Host，因此 AWS 回源 SNI/Host 就是源站域名（匹配 Let's Encrypt SAN）；Caddy 不再改写 Host，直接把 WebSocket 请求转给 `127.0.0.1:10086`。
- **订阅**：本机节点只有一个 CDN 节点（默认名 `🇺🇸AWS`，安装时可改），没有优选 IP、测速组或自动兜底节点。
- **暴露面**：源站 `443` 对公网可达（CloudFront 回源没有可枚举的固定 IP 段），源站安全依赖源站头、精确路径与业务鉴权。

### 1.3 模式 3：Cloudflare 橙云（单域名）

模式 3 只承载橙云入口，一个域名同时提供节点与订阅：

```text
客户端 ── TLS(SNI=cf.<zone>) ──► Cloudflare 边缘（通用边缘证书，橙云代理）
                                       │ https-only 回源（Full strict），SNI/Host=cf.<zone>
                                       ▼
公网 443（仅 Cloudflare 官方回源 IPv4 段）Caddy（Origin CA 证书）
  ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS WebSocket）
  ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅
  ├─ = /easy_all-health    → 固定 easy_all ok
  └─ 其他路径              → 404
```

- **DNS**：节点域名一条 `proxied=true` 的 `A` 记录（→ VPS 公网 IPv4），订阅域名由节点域名派生，不需要第二个名字。
- **证书**：只用 Cloudflare Origin CA（ECDSA P-256、5475 天、CN 与唯一 SAN 都是节点域名），本机不运行 Certbot、不开放 `80`；复用前除有效期/SAN/公私钥外还必须通过 `openssl verify` 链验证。
- **`Full (strict)` 门禁**：安装与 `apply-cloud` 在创建任何 DNS/证书资源前只读读取 Zone SSL 设置，只接受 `strict`；`full`/`flexible`/`off` 与 403 权限不足都在创建资源前停止，工具不会自动修改全区设置。
- **回源白名单**：VPS `443` 只对 Cloudflare 官方回源 IPv4 段放行（UFW 注释 `easy_all-cf-origin-443`）。这是公共回源网段，不是账户级鉴权。
- **无源站头、无熔断**：橙云链路没有 `X-Easy-All-Origin-Key`，也没有 mangle 计量与 985 GB 额度（这些只属于模式 2/4）。
- **`apply` 的外部访问**：只读取公开的 Cloudflare 回源 IPv4 段与 Origin CA 根证书，不需要账号凭据、不修改云端。

### 1.4 模式 4：AnyTLS + CloudFront
一台 VPS 独占承载直连与 CDN 两个入口：

```text
公网 443   sing-box AnyTLS（直连入口，TLS SNI=direct.<zone>）
公网 8443  Caddy（与模式 2 相同的源站与订阅站点，CloudFront 回源端口 8443）
  ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS WebSocket）
  ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅
  ├─ = /easy_all-health    → 固定 easy_all ok
  └─ 其他路径              → 404
```

- **端口划分**：直连入站固定在 `443`，CloudFront 源站与订阅站点固定在 `8443`，回环 CDN 入站固定在 `127.0.0.1:10086`；三者都由模式派生，不接受用户另设参数。
- **证书**：源站域名固定复用直连域名（一条灰云 `A`），Let's Encrypt 只需覆盖直连域名（DNS-01）；viewer 侧仍由 ACM 管理；订阅域名固定复用节点域名。AnyTLS 与 Caddy 共用同一份部署证书。旧装若已配置独立源站域名，仍保留原灰云 `A` 与 SAN。
- **分发端口**：CloudFront 源站 `HTTPSPort` 由模式派生为 `8443`（模式 2 是 `443`）；分发端口写错会在公网验收阶段失败。
- **订阅**：本机节点恰为两个——AnyTLS 直连（默认名 `🇺🇸直连`）与 CloudFront CDN（默认名 `🇺🇸AWS`），另附 `AUTO`（`url-test`）与 `CDN-FALLBACK`（`fallback`，顺序为直连 → CDN）两个自动组，探测地址固定 `https://www.gstatic.com/generate_204`；`PROXY` 仍是 `select`，可手动在直连与 CDN 之间切换。

### 1.5 模式 5：AnyTLS + CloudFlare
一台 VPS 同时承载直连与橙云两个入口，橙云域名同时提供节点与订阅：

```text
公网 443   sing-box AnyTLS（直连入口，TLS SNI=direct.<zone>）
公网 8443（仅 Cloudflare 回源 IPv4 段）Caddy（与模式 3 相同的单域站点，证书为 Let's Encrypt）
  ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS WebSocket）
  ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅
  ├─ = /easy_all-health    → 固定 easy_all ok
  └─ 其他路径              → 404
```

- **端口划分**：直连入站固定 `443`（公网），橙云回源与订阅站点固定 `8443`（只放行 Cloudflare 回源段），回环 CDN 入站固定 `127.0.0.1:10086`。
- **证书**：与模式 1/4 同一张 Let's Encrypt 证书（DNS-01），SAN 为直连域名与橙云节点域名；不使用 Origin CA——直连 AnyTLS 必须是公信证书，Caddy 回源复用同一份。
- **Origin Rule**：橙云边缘到 VPS 的连接默认打 `443`，因此用一条 `http_request_origin` 单规则把 `http.host eq <节点域名>` 路由到 `origin.port 8443`；生命周期与模式 1 的订阅回源完全相同，ruleset/rule ID 落盘到 state。
- **`Full (strict)` 门禁**：橙云回源前只读校验 Zone SSL 为 `strict`，与模式 3 同口径。
- **订阅**：与模式 3 一样只有一个橙云域名，但节点有两个（直连 + 橙云），`PROXY` 组不加自动测速或兜底组；没有优选 IP、没有源站头、没有 985 GB 计量。
- **运维**：`apply-cloud` 同步两条 A 记录、证书与 Origin Rule；`renew-cert` 走 Certbot（与模式 1 同路径）；`uninstall` 级联清理两条 A 记录与 Origin Rule。

## 2. 防火墙、端口与安全边界

### 2.1 SSH 端口保持与保护
- **端口保持与防火墙策略**：
  - 各模式均保留系统原有 SSH 监听端口（默认 22），不强行迁移端口，避免因云安全组限制导致失联。
  - UFW 设置默认入站拒绝、默认转发拒绝，仅放行必要端口，未放行端口由默认策略阻断。
  - Fail2ban 自动配置 sshd jail 实时监控保护实际 SSH 端口。
- **常驻安全基线归初始化**：`scripts/debian-init.sh` 负责激活 UFW（SSH 端口、ICMP 回显与出站放行）并配置 Fail2ban；easy_all 安装只在此基础上追加业务端口。
- **规则规格删除防编号漂移**：业务端口与 Cloudflare 回源白名单的清理升级为规则规格删除（通过 `stale_ufw_rule_delete_specs` 生成规格并执行 `ufw delete`），替代易受并发插桩干扰的行号逆序删除，彻底规避了 Fail2ban 动态插入规则导致的编号漂移与误删。
- **卸载与回滚只回收业务端口**：各模式 `uninstall` 与安装失败回滚一律只删除自己注入的 `443`/`8443` 放行与 Cloudflare 回源白名单，保留 UFW 启用状态、默认策略、SSH 放行与 Fail2ban 配置，不再执行 `ufw disable`。
- **Fail2ban 助手脚本解耦**：CIDR 封禁助手安装到 `/usr/local/sbin/fail2ban-ufw-cidr.sh`（不再位于 `/usr/local/lib/easy_all`），卸载 easy_all 时保留，避免常驻 SSH 封禁动作因脚本缺失而失效。
- **重装跳过已就绪的初始化**：卸载后重装时，依赖包、Swap、内核与 TCP 加速已就绪就跳过重复安装；IPv4-only、定时重启与 UFW/Fail2ban 仍会幂等校验。
- **定时维护互斥与安全加固**：每日定时重启任务引入运行时写锁检测（`flock -n 8`），检测到后台有安装或更新进行时自动跳过重启并向 syslog 记录审计日志，防止并发维护造成半安装现场；模式 2/4 还会在取得最终写锁后只读复核流量保护状态（`protection_offline=false` 且 `blocked=enforced`），不满足则跳过重启。cron 行本身只调用 `easy_all internal-scheduled-reboot` 内部入口，预命令、抢锁与流量复核都在该入口内完成，行长度固定、不再随逻辑增长，也无需 `%` 转义。

### 2.2 各模式端口与监听

| 模式 | UFW 公网放行 | 仅 Cloudflare 回源 IPv4 放行 | 本机回环监听 |
| :--- | :--- | :--- | :--- |
| 初始化（debian-init） | SSH 实际监听端口 | — | — |
| 1 AnyTLS 直连 | TCP `443` | `deploy` 时 TCP `8443`（订阅回源） | — |
| 2 纯 CloudFront | TCP `443` | — | `127.0.0.1:10086`（VLESS WebSocket） |
| 3 纯 CloudFlare（单域名） | — | TCP `443` | `127.0.0.1:10086`（VLESS WebSocket） |
| 4 AnyTLS + CloudFront | TCP `443`、`8443` | — | `127.0.0.1:10086`（VLESS WebSocket） |
| 5 AnyTLS + CloudFlare | TCP `443` | TCP `8443`（橙云节点/订阅回源） | `127.0.0.1:10086`（VLESS WebSocket） |

- **不开放 `80`**：所有公信证书都走 Cloudflare DNS-01，不需要在 `80` 上做域名校验，也没有 HTTP 重定向。
- `10086` 永不对公网放行；端口预检覆盖各模式实际使用的端口（模式 1：`443`，deploy 另加 `8443`；模式 2：`443`、`10086`；模式 3：`443`、`10086`；模式 4：`443`、`8443`、`10086`；模式 5：`443`、`8443`、`10086`）。
- 所有模式维持 IPv4-only、默认 incoming/routed deny、outgoing allow、SSH 预检与 Fail2ban。

### 2.3 源站暴露面（各链路差异）

- **模式 1 `deploy`、模式 3 与模式 5** 保留 Cloudflare 回源白名单：安装器只向 Cloudflare 官方 IPv4 网段新增回源端口放行（模式 1/5 是 `8443`，模式 3 是 `443`）。在宿主没有其他公网放行、云安全组也未额外放通的前提下，外部扫描器直连该端口会被静默丢弃；宿主已有的无注释放行不在本工具管理范围。
- **模式 1 的直连 `443` 对公网开放**，直连域名灰云 `A` 记录会公开 VPS 公网 IPv4。
- **模式 2/4 没有回源白名单**：CloudFront 回源没有可枚举的固定 IP 段，因此模式 2 的源站 `443`、模式 4 的源站 `8443` 对公网可达。实际防护依赖：
  - 公信 Let's Encrypt 源站证书（自签证书无法通过 CloudFront 的 HTTPS 回源验证）；
  - `X-Easy-All-Origin-Key` 源站头：它是 Caddy 外层 `route` 的首个指令，用 CEL 精确比较请求头与状态中的密钥，不相等即 `abort`；
  - 随机 VLESS 路径的精确匹配（`handle <VLESS_PATH>`）与 `VLESS UUID`；
  - 订阅只精确匹配 `/subscribe` 与 `/sub`，其余路径 `404`，并由 Token 鉴权。
- 这些措施**不能**防御网络层 DDoS、TLS/HTTP 资源耗尽或密钥泄露。源站头密钥只存在于 `0600` 的 state、`0600` 的 Caddy 配置与 AWS 请求暂存文件中，不下发客户端、不进订阅、不写访问日志。
- 公网验收会分别对**源站端口**（模式 2 `443`、模式 4 `8443`）发缺头与错头请求，只接受连接被拒或 `403/404`。探测必须打到 Caddy 站点端口：打到 `443` 时模式 4 连接的是 sing-box，结果会变成“连不上即通过”的假阳性。

### 2.4 恶意出站与内部阻断
- sing-box 配置使用显式 IPv4 DNS 服务器与 `ipv4_only` 策略，路由先拒绝私网地址，再拒绝与 `lib/network.sh` 一致的私网/特殊地址清单（回环、云厂商元数据、CGNAT、多播与保留段）。
- 保留 UDP/443 拒绝，强制 QUIC 连接降级回退至 TCP。
  客户端 Mihomo 模板的嗅探（`sniffer`）同样不覆盖 QUIC：否则这次拒绝会被握手解析拖慢
  （Android 上表现为 Google Play 下载长期停在“等待中”）。

---

## 3. 订阅分发与渲染

- **Caddy 路由顺序**：外层 `route` 固定为「CloudFront 密钥守卫 → 精确代理路径 → 精确订阅入口 → health → 404」；模式 1/3 没有源站密钥守卫，依赖回源白名单、`Full (strict)` 与业务鉴权。
- **订阅入口是精确路径**：matcher 精确列出 `/subscribe` 与 `/sub`，两者进入同一处理器并保留 query；`/subscribe/`、`/subscribed`、裸文件与其他路径一律 `404`，不重定向、不做前缀匹配。
- **订阅处理器内部顺序**：公共响应头（`Vary: User-Agent`、`Cache-Control: no-store, no-cache, must-revalidate, max-age=0`、`Pragma: no-cache`、`X-Content-Type-Options: nosniff`、`X-Robots-Tag: noindex, nofollow, noarchive`）先于任何终止响应；随后非 `GET`/`HEAD` 返回 `405`，Token 缺失/错误返回 `403`，订阅未就绪返回 `503`；全部响应都带上述公共头。
- **Token 比较**：`ALLOWED_TOKENS` 的值构成 CEL 的精确字符串集合，大小写敏感、不使用正则，客户端文本不拼进表达式源码；`file_server` 只出现在鉴权后的订阅处理器里，且只 rewrite 到八个固定文件。
- **重复 query 参数**：Caddy 把同名参数逗号拼接，因此重复 `token` 无法匹配合法值，一律 `403`；重复 `flag`/`os`/`node` 的拼接结果不命中显式分支，回落到 UA 等默认行为。这是相对旧版首值语义的有意收紧。
- **原子渲染**：订阅文件在生成时先写入临时暂存目录，校验完整无缺后逐文件原子替换，防止高并发下载时读到半截内容（这是「单文件原子」而非整目录快照）。
- **八种产物**：`base64.txt`、`mihomo.yaml`、`mihomo-ios.yaml`、`singbox.json`（默认过滤 `optional` 节点）与 `base64-all.txt`、`mihomo-all.yaml`、`mihomo-ios-all.yaml`、`singbox-all.json`（`&node=all` 时附带 `optional` 节点）。iOS 变体只从 YAML 剥离以 `sniffer:` 开头的整段，其余规则不变。两份 JSON 在没有 optional 支持节点时内容相同，文件仍总是生成。
- **客户端自适应**（判定顺序固定为「显式 flag → 已确认的 sing-box UA → Clash UA → Base64」，只选一种格式）：
  - 根据 HTTP 请求头中的 `User-Agent` 自动识别客户端；
  - 已核实的 sing-box Android 客户端（SFA，UA 形如 `SFA (sing-box 1.14.4; language zh_CN)`，按小写归一化后前缀匹配）返回完整 JSON 配置；不对任意位置出现 `sing-box` 的 UA 做通配匹配；
  - Clash / Mihomo 客户端自动返回格式合法的 YAML 订阅（采用最新 MRS 规则集）；
  - 通用客户端返回经过 Base64 编码的节点 URI 列表；
  - `flag=singbox|sing-box` 强制 JSON，`flag=clash|mihomo|meta|stash|yaml` 强制 YAML，`flag=base64|uri|v2ray|shadowrocket` 强制 Base64；显式 flag 覆盖 UA。`os=ios` 强制 iOS 变体，`node=all` 附带可选聚合节点；大小写不敏感。
- **JSON 分支的响应与失败路径**：`Content-Type: application/json; charset=utf-8`，下载名为 `<SUB_DOWNLOAD_NAME>.json`；HEAD 与 GET 同状态同头。已启用 JSON 分支但目标文件缺失时返回 `503`，不会切换成其他格式，也不影响 YAML / Base64 请求。
- **平台自适应（嗅探段）**：默认模板开启 `sniffer`。UA 命中 `iphone|ipad|ipod|ios`（`ios` 需独立单词，避免 `Studios`/`Radios` 之类 UA 被误判）或在 URL 追加 `os=ios` 时，
  下发单独渲染的 YAML，剔除以 `sniffer:` 开头的整段配置（兼顾 iOS 内存预算、防 APNs 推送干扰、私有协议首包延迟与 CDN 调度劣化）；
  模板若把 `sniffer` 写成内联映射，安装会直接报错，不会静默下发未剔除的嗅探段。

### 3.1 节点与分组顺序

Base64 平铺顺序与 Mihomo `proxies` 顺序完全一致；`PROXY` 组的成员只在模式 4 额外插入两个自动组：

| 模式 | Base64 / `proxies` 顺序 | `PROXY` 成员 |
| :--- | :--- | :--- |
| 1 AnyTLS 直连 | 本机 AnyTLS 节点 → 聚合 `nodes`（原顺序） | 同左 |
| 2 纯 CloudFront | CloudFront 节点 → 聚合 `nodes`（原顺序） | 同左 |
| 3 纯 CloudFlare | Cloudflare 橙云节点 → 聚合 `nodes`（原顺序） | 同左 |
| 4 AnyTLS + CloudFront | 本机 AnyTLS 节点 → CloudFront 节点 → 聚合 `nodes`（原顺序） | 本机 AnyTLS 节点 → CloudFront 节点 → `AUTO` → `CDN-FALLBACK` → 聚合 `nodes`（原顺序） |
| 5 AnyTLS + CloudFlare | 本机 AnyTLS 节点 → Cloudflare 橙云节点 → 聚合 `nodes`（原顺序） | 同左 |

- `PROXY` 为 `select`，默认第一项分别是直连节点（模式 1/4/5）或 CDN 节点（模式 2/3）；即使聚合节点为空也始终有有效成员。
- 模式 4 额外生成 `AUTO`（`url-test`）与 `CDN-FALLBACK`（`fallback`，直连 → CDN）两个自动组，探测地址固定 `https://www.gstatic.com/generate_204`；模式 1/2/3/5 没有自动测速或兜底组。
- `GLOBAL` 维持 `select`，唯一成员是 `PROXY`；切换到「全局」后所有接管流量使用 `PROXY` 的当前选择。
- 模板只保留 `PROXY` / `GLOBAL` 两个占位区，额外分组由 `build_mihomo_proxy_groups` 输出，`AUTO`、`CDN-AUTO`、`CDN-FALLBACK` 等名字属于保留组名，不能用于聚合节点。
- 聚合节点支持三类：`vless` + `reality/tcp`、`vless` + `tls/xhttp`、`mieru`；外部聚合节点的 `host/port/portRange` 原样保留，不受本机「全 443」约束，也不受「本机只有一个 CDN 节点」的限制。

### 3.2 sing-box 完整 JSON 订阅

- **合成方式**：`templates/singbox.json` 提供固定段（`log`、`dns`、`inbounds`、`route`、`rule_set`、`http_clients`、`experimental`），`lib/singbox-subscription.sh` 用 `jq` 注入 `outbounds` 与 `PROXY` 选择器。节点来自 `lib/local-aggregation.sh` 的结构化数据与本机身份字段，不反向解析 URI/YAML，也不做字符串替换拼接凭据。
- **入口**：混合代理 `127.0.0.1:1080` 与 TUN（`172.19.0.1/30`、MTU 1500、`auto_route`、`dns_mode=hijack`）；TUN 由客户端平台管理接口名，不硬编码内核路由排除项。
- **DNS**：`fakeip`（`198.18.0.0/16`）+ 独立 IPv4 引导解析器（UDP，默认直连出口）+ 国内解析（DoH，默认直连出口）+ 境外解析（DoH，`detour=PROXY`）；私有域名（`private-fallback` 内联集合 + `geosite-private`，覆盖路由器管理域名与反查区域）、单标签主机与认证门户走本地解析；NTP/STUN/推送/音乐等 Fake-IP 例外单独内联；全局 `ipv4_only`。解析路径分两类：TUN 劫持后的应用查询按 `dns.rules` 选服务器（**代理集合优先于国内集合**，与默认 Mihomo 模板的 `nameserver-policy` 同序，避免 `services.googleapis.cn`/`google.cn` 这类交集域名被国内解析抢先）；出站自身的域名解析不经过 `dns.rules`，因此 `DIRECT` 出口固定带 `domain_resolver=dns-local`（本地解析，局域网域名可解析），节点出口用 `route.default_domain_resolver=dns-bootstrap` 引导（不与待解析的代理节点互相依赖）。注意 sing-box 1.14 拒绝把 DNS/HTTP 客户端的 `detour` 指向**空 direct 出口**（启动期 FATAL），所以“直连”一律用不带 `detour` 的默认出口表达，只有境外 DoH 显式写 `detour=PROXY`。
- **分流顺序**与默认 Mihomo 模板逐条对应：DNS 接管 → 私网与零地址 → 单标签/认证门户/本地管理域名 → FCM `5228-5230` → 代理服务与 Google 的 UDP/443 拒绝与域名代理 → 微信/Steam/Apple 中国/国内服务 → 国内域名集合 → Telegram → CN IP 兜底 → 其余 UDP/443 拒绝 → `PROXY`。`clash_mode=direct/global` 规则优先于业务规则。
- **规则集**：小型内联集合（`private-fallback`、`captive-portal`、`fakeip-exceptions`、`proxy-services`、`wechat-services`、`steam-download`、`apple-cn-fallback`、`direct-services`、`telegram-fallback`）与 MetaCubeX 的 sing-box 分支 SRS（`geosite-*`、`geoip-*`，`update_interval=1d`）并存；下载走显式 `http_clients`（默认直连出口，不依赖待解析的代理节点）。冷启动时任一必需远程规则集下载失败会让客户端配置启动失败，少量内联规则只缩短影响面，不构成离线首次启动保证。
- **策略组差异**：`PROXY` 为 `select`，成员顺序与本机节点/聚合节点一致。模式 4 追加 `AUTO`（`urltest`，仅本机直连与 CDN），默认选择直连节点；官方 selector/urltest 无法保证与 Mihomo `CDN-FALLBACK` 语义等价，因此 JSON 不生成该组，Mihomo 订阅仍保留它。模式 1/2/3/5 只有 `PROXY` 与 `DIRECT`。
- **节点映射**：本机 AnyTLS（`password` + TLS + uTLS `chrome`）与 VLESS WebSocket（`transport.type=ws`、`headers.Host`、`packet_encoding=xudp`）；聚合 Reality 节点映射为 `flow=xtls-rprx-vision` + `tls.reality`（`public_key`、`short_id`），`udp=false` 时用 `network: "tcp"` 限制承载。1.14.4 的 Reality 客户端会从 ClientHello 里过滤 `X25519MLKEM768`（`common/tls/reality_client.go`），因此聚合节点的 `supportX25519Mlkem768` 在 sing-box 侧没有对应开关：`false` 与核心行为一致，`true` 的 PQ 扩展不会出现，两者都仍用经典 X25519 连接，所以都保留。源站密钥永不进入 JSON。
- **排除规则**：官方 1.14.4 没有 xhttp 传输与 mieru 协议，`fp` 不在 1.14.4 utls 枚举内的 Reality 节点会让核心拒绝整份配置，因此这两类节点只从 JSON 排除，`apply` 会输出节点名、原因与数量；Mihomo / Base64 输出不变。Reality 的 `supportX25519Mlkem768` 不参与排除（见上一条：核心固定过滤 MLKEM），但该行为的握手实测仍未进行。所有模式都至少有一个本机节点，因此排除后 JSON 仍有效；本机节点生成失败则整个候选发布失败。
- **候选校验**：发布前检查 JSON 可解析、outbound tag 唯一、selector/urltest 成员与路由/DNS 引用存在、默认出口存在、无源站密钥；存在锁定核心时再跑 `sing-box check`。`check` 不覆盖运行期初始化，因此 `scripts/verify-live.sh` 还会把客户端 JSON 去掉 TUN 入口后用真实核心启动一次（DNS detour 指向空 direct 出口这类问题只在启动阶段暴露）。校验失败即中止发布，已发布的旧订阅保持不变。
- **发布与流控边界**：JSON 与六份旧产物在同一暂存目录生成并沿用逐文件原子替换（单文件原子，不是整代快照）。`render_mihomo_base64_files` 保留六产物渲染，仅供 CDN 就绪判定与流控门禁复用；JSON 缺失或损坏不会改变 `blocked`/`pending` 状态，也不清零用量。

---

## 4. CDN 流量计量与双层阻断

### 4.1 统计链路
- 不依赖受测 sing-box 未编译的 `v2ray_api`，而是在 `mangle` 表用链首无 target 的纯计数规则统计回环 `10086` 的双向字节：`INPUT` 匹配 `lo` + `127.0.0.1` + TCP `10086` 计上行（Caddy → sing-box），`OUTPUT` 匹配同条件计下行（sing-box → Caddy），每方向每包只计一次。
- 用 mangle 而非 filter，是为了避免 UFW 早期 `ACCEPT lo` 让规则不可达；受管 UFW reload 后仍会复核规则，自定义规则也可能改写 mangle。
- 模式 4 的 AnyTLS 直连与全部订阅下载都不经过 `10086`，因此不计入 CDN 用量。
- 计数读取失败、规则缺失或修复失败一律按保护失败路径处理，**不清零、不放行**；阈值固定 `985 × 10⁹` 字节，state 里的 `CDN_TRAFFIC_PROTECTION_GB` 必须恰为 `985`，不能用环境变量绕过。

### 4.2 用量文件、锁与月度
- `/etc/easy_all/cdn-traffic-usage.json`（`0600`，同目录临时文件 + 原子 rename）字段白名单：`period` / `runtime_id` / `used_bytes` / `last_uplink` / `last_downlink` / `blocked` / `enforced` / `protection_offline`。
- 合法的旧七字段文件只在读取时把缺失的 `protection_offline` 解释为 `false`，下一次原子更新补齐；其他缺字段、类型错误或违反「`protection_offline=true` 必须同时满足 `blocked=true`、`enforced=false`」都判为损坏。损坏时拒绝操作并告警，不会创建替代文件或清零。
- 计量有独立的 counter 锁 `/run/easy_all/traffic-counter.lock`：规则检查/插入/唯一性清理、epoch 与基线、所有 usage 读写都必须在锁内完成，`iptables` 使用有界 `-w`。
- `period` 按 **UTC 自然月**；`used_bytes` 只在月切换时重置，核心重启、规则重建或回补都不会清零。`runtime_id` 是包含 `boot_id` 的计数 epoch：同 epoch 增量取 `max(0, current - previous)`，换 epoch 只重采样基线并保留累计，同时告警连续性丢失。`/proc/sys/kernel/random/boot_id` 不可读时采样直接失败并保留现有保护状态（不再用时间戳兑底）：每轮换 epoch 会让增量恒为 0，保护等于不存在。受支持的 Debian/Ubuntu 宿主默认提供该文件。
- 用量与保护标记不参加本机配置事务回滚，旧快照不会覆盖新 usage。

### 4.3 双层阻断与恢复
达到阈值后 `blocked=true`，阻断顺序固定：

1. **Caddy 层**：精确代理路径直接 `respond 503`，health 与订阅保持可用。
2. **sing-box 层**：省略 CDN 入站并重启核心，终止已建立的 CDN 长连接；模式 4 保留 AnyTLS 入站，因此直连只经历一次短暂重连。
3. 只有确认旧连接断开、新连接被拒绝后，才写 `enforced=true`。

状态语义：`blocked` 是期望的限额状态，`enforced` 是最后完成验收的应用状态，两者不一致即「待落实」；`protection_offline=true` 表示保护性停机意图已持久化（核心已停止或即将停止），它不表示允许解封，也无法通过环境变量或临时令牌绕过。无法安全收敛时保持 `protection_offline` 并说明直连同样受影响。

所有入口共用同一个只读判定与同一个受限恢复函数：先应用 `503` 与受限 Caddy，再启动受限核心（省略 CDN 入站、模式 4 保留 AnyTLS），必需验收（Caddy `503`、受限配置与旧连接终止、严格源站 TLS/health、模式 4 的 `443` 监听等）全部通过后才原子写 `enforced=true`、`protection_offline=false`。必需验收失败会把 `protection_offline` 先落盘再停止核心，下一轮从同一入口重试；解封失败则恢复受限配置并保留 pending，绝不恢复开放配置后报成功。

### 4.4 启动顺序与临界区预算
- 锁边界只有一把 counter 锁与一把 runtime 写锁，唯一允许的嵌套顺序是 **runtime → counter**；持有 counter 时禁止执行 `systemctl start/restart`、Caddy reload、下载、证书或网络动作。
- 管理事务：持 runtime，短取 counter 做 checkpoint 后释放，再保持 runtime 同步重启服务。ExecStartPre（`internal-traffic-prepare`）：只取 counter，准备规则并校验状态后释放，绝不取 runtime。timer 采样：只取 counter，写 usage/pending 后释放；收敛时先释放 counter 再非阻塞取 runtime。
- 单次 counter 临界区目标 ≤2 秒，**硬上限 5 秒**；ExecStartPre 等待 counter 的上限为 **15 秒**，systemd `TimeoutStartSec=30s` 容纳等待、准备与启动；`Restart=on-failure`、`RestartSec=10s`、`StartLimitIntervalSec=120`、`StartLimitBurst=3`，持续故障有界停止而不是无限启动环。
- 首次开放、受管 UFW reload 与重启前后都会检查计量；运行中发现规则丢失时先持久化保护意图，再按锁序收敛受限边界，最后修复规则。

### 4.5 这是近似保护，不是账单保证
- 阈值来自**本机 mangle 回环计数**，不是 AWS 账单真源：HTTP/HTTPS 请求费、订阅下载、TLS/HTTP 自身开销、同一账号的其他分发或其他机器的用量、进程崩溃/关机期间缺失的采样窗口都不在统计内，计数本身还包含 TCP/IP 开销。
- 因此它只能降低超额风险，**不承诺零账单，也不是任何形式的账单保底**；CloudFront 的免费额度与计费标准以你 AWS 账号当前的条款和账单为准。

---

## 5. 目录结构与模块划分

```text
easy_all
├── bootstrap.sh                 # 远程一键安装拉取器
├── easy_all                     # CLI 统一管理入口与命令调度
├── runtime.manifest             # 运行时受管文件清单
├── profiles/
│   ├── anytls.sh                # 模式 1：AnyTLS 直连 + 可选订阅站点
│   ├── cloudfront.sh            # 模式 2：纯 CloudFront 薄 Profile（仅常量与空直连钩子）
│   ├── combined.sh              # 模式 4：AnyTLS + CloudFront 薄 Profile
│   ├── combined-cloudflare.sh   # 模式 5：AnyTLS + CloudFlare 薄 Profile
│   └── cloudflare.sh            # 模式 3：纯 CloudFlare 薄 Profile（单域名，空直连钩子）
├── lib/
│   ├── log.sh                   # 日志与双语输出
│   ├── state.sh                 # 状态 schema、五模式字段集与 launcher 分类的单一来源
│   ├── platform.sh              # 系统环境、Debian 探测与基础依赖
│   ├── runtime-core.sh          # 跨模式通用运行时（证书事务、订阅发布、核心事务、停机清理）
│   ├── profile-common.sh        # Profile 映射、安装身份与快照/续装/回滚
│   ├── network.sh               # 网络与 IPv4/域名基础校验
│   ├── cf-dns.sh                # Cloudflare API / DNS / Origin CA / 回源网段与持久 Token
│   ├── cf-origin-rule.sh        # Origin Rule 单规则生命周期（ref/归属/追加/删除）
│   ├── cloudfront-mode.sh       # 模式 2/4 唯一 CloudFront 业务核心
│   ├── cloudflare-mode.sh       # 模式 3 唯一橙云业务核心（单域名 + Origin CA + 回源白名单）
│   ├── anytls-mode.sh           # 模式 1/5 业务编排（AnyTLS 入站、订阅站点与 Origin Rule）
│   ├── cdn-traffic-guard.sh     # mangle 计量、985 GB 阈值、保护状态机与 systemd timer
│   ├── cloudflare-purge.sh      # Cloudflare 远端托管资源识别与清理
│   ├── singbox-core.sh          # 锁定 sing-box 版本、官方归档与固定 SHA256
│   ├── singbox-runtime.sh       # 五模式 sing-box JSON、客户端节点与运行验收
│   ├── caddy-core.sh            # 锁定 Caddy 版本、官方归档与 SHA512 清单校验
│   ├── caddy-runtime.sh         # Caddyfile、订阅路由、服务与重载
│   ├── firewall.sh              # UFW 规则配置与状态快照
│   ├── subscription-auth.sh     # 订阅凭据、UA/flag/os/node 协商与产物发布事务
│   ├── local-aggregation.sh     # 本地聚合节点校验与渲染（全模式共用）
│   ├── scheduled-maintenance.sh # 定时重启与维护任务
│   ├── tcp-tuning.sh            # Skyline Speeder 与 Zabbly 6.12+ LTS 内核管理
│   └── mihomo-template.sh       # Mihomo 订阅模板结构校验与渲染
├── templates/                   # 内置 Mihomo 订阅配置模板与聚合示例
│   ├── mihomo.yaml              # 默认 COMMON 精简规则模板
│   ├── mihomo-common.yaml       # 完整 COMMON 规则模板
│   ├── mihomo-classic.yaml      # 经典 MRS 规则集模板
│   └── aggregation.example.json # 聚合节点（三类）配置示例
└── scripts/                     # 辅助构建与系统初始化脚本
    ├── debian-init.sh           # 独立系统初始化加固工具（Debian 12/13、Ubuntu 22.04/24.04）
    └── verify-cores.sh          # 真核心校验入口（`npm run test:cores`）
```

### 5.1 模式库的模块边界
- **Profile 只声明、不复制**：`CDN_PROFILE_KEY`、`CDN_EXPECTED_PROTOCOL`、`CDN_MODE_LABEL`、`CDN_ENTRY_SUMMARY`、`CDN_INSTALL_PORTS`，以及同名直连钩子（模式 2/3 返回空值）。
- **模式库持有本模式契约**：AWS 常量（`us-east-1`、缓存/源站请求策略 ID、回源时限、头名、分发 Comment）、Cloudflare 常量（来源白名单注释、Origin CA、Origin Rule phase）、状态白名单与校验、本机 UFW、订阅渲染、运维事务、熔断重建、安装与卸载。
- **共享运行时保持中立**：`runtime-core.sh` 提供证书事务（DNS-01 签发、hook、部署与验收）、订阅发布与验收（完整发布八份产物，流控门禁只用六份 Mihomo/Base64）、核心事务与停机清理；它不持有任何云 Provider 语义。
- **渲染与路由分离**：`singbox-runtime.sh` 只产出 sing-box JSON 与客户端节点；`caddy-runtime.sh` 只产出 Caddyfile（站点主机与端口由模式派生）并负责 reload。两者都用「候选文件 → 校验 → `0600` 同目录原子 rename」发布。
- **橙云核心并列而非抽象**：`cloudflare-mode.sh` 与 `cloudfront-mode.sh` 各自持有 Provider 语义（橙云 A 记录/Origin CA/回源白名单 vs ACM/分发/源站证书/源站头），共用 `cf-dns.sh` 的 Cloudflare API 层与同一套 Profile 钩子契约。每个进程只加载所选链路的 Profile 与核心，因此同名生命周期函数（`load_state`、`apply_easy_all`、`install_all` 等）不会冲突；不引入跨 Provider 抽象层。

---

## 6. 证书、核心下载与运行时目录

### 6.1 证书双路径
- **公信证书**使用 easy_all 专用 Certbot lineage `easy_all`（`/etc/letsencrypt/live/easy_all`），经发行版 Certbot + Cloudflare DNS 插件走 DNS-01：模式 1 覆盖 direct/已部署 sub，模式 2 覆盖 origin，模式 4 覆盖 direct/origin，模式 5 覆盖 direct/橙云节点域名。凭据 `dns_cloudflare_api_token` 以 `0600` 保存在 `/etc/easy_all/cloudflare.ini` 供定时续期；不使用 Caddy DNS 插件，不开放 `80`。
- **两条部署路径**：
  1. 安装、`renew-cert`、`apply-cloud` 已持 runtime 写锁：只对本次 Certbot 子进程设置 `EASY_ALL_CERTBOT_SKIP_DEPLOY=1`，自有 hook 立即退出，由父进程在当前事务里部署。
  2. 定时 hook（`/etc/letsencrypt/renewal-hooks/deploy/easy_all.sh` → `easy_all internal-cert-deploy`）：自行取得 runtime 锁，确认 `RENEWED_LINEAGE` 属于本工具，只部署已签发证书，不再次签发；有界等待，失败非零并保留 lineage。
- **部署验收**：检查 SAN、有效期、公私钥匹配与完整信任链后才替换 `/etc/easy_all/certs/fullchain.pem` 与 `private.key`；随后重启 sing-box 并**强制** Caddy reload（`--force`，因为证书是同路径替换、配置内容不变），再用本机 TLS 握手比对磁盘指纹。任一步失败恢复旧部署副本并保留新 lineage。
- **模式 3** 使用 Cloudflare Origin CA（ECDSA P-256、5475 天），`renew-cert` 先签发部署、本机 TLS 验收通过才吊销旧证书；`renew-cert` 从不操作 ACM 自动续期。

### 6.2 核心下载与 `update-core`
- 固定 sing-box `1.14.4`（代码内审查过的 SHA256 常量，无官方 checksums 清单可用）与 Caddy `2.11.9`（读取官方 `caddy_2.11.9_checksums.txt` 中精确文件名的 SHA512 条目）。
- 一律只通过 HTTPS 下载，先校验摘要再解压、再跑候选版本/配置检查，最后同目录原子替换；失败保留旧二进制与旧配置。darwin 归档只用于开发验证。
- `update-core` 没有新增参数，含义是**重装/修复当前脚本支持的锁定版本**，不追最新：更新前备份现存二进制与运行配置，下载校验失败或候选验收失败即恢复旧版本；二进制已缺失时按修复处理（没有可回滚的旧版本）；保护待落实时直接拒绝。
- 发布顺序固定为「写单元 → `systemctl daemon-reload` → 启停服务」：不重新加载时 systemd 继续使用内存里的旧单元，新增的 `ExecStartPre` 计量守卫会被静默跳过。替换 Caddy 二进制后必须**重启** Caddy 进程——`reload` 只在现有进程内换配置，不会执行磁盘上的新二进制。

### 6.3 `/run` 目录与两把锁
- 计量目录 `/run/easy_all` 在打开锁前显式创建（root `0700`，锁文件 `0600`）；sing-box 的 `RuntimeDirectory` 生命周期不回收这个共享目录，停启服务不 unlink counter 锁，避免 timer 与启动进程锁到不同 inode。目录或锁准备失败即拒绝启动。
- Caddy 单元使用 `RuntimeDirectory=easy_all-caddy`、`RuntimeDirectoryMode=0700`，管理套接字固定在 `/run/easy_all-caddy/admin.sock`，`caddy reload` 只经由该 Unix 套接字，不暴露 TCP 管理端口。
- 运行时写锁覆盖配置/state/模板/订阅/服务变更；counter 锁覆盖规则、usage、epoch 与基线。唯一嵌套顺序为 **runtime → counter**，反序等待会把启动准备与 timer 采样卷成死锁（预算见 §4.4）。
