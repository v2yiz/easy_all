# 系统架构与技术参考

本文档记录 `easy_all` 的系统架构设计、网络拓扑、流控与安全策略以及模块职责划分。

---

## 1. 架构总览与网络拓扑

`easy_all` 支持在 Debian 12/13 与 Ubuntu 22.04/24.04/26.04 LTS 环境下以单机独占形式部署以下五种模式。本机运行时为官方 sing-box（模式 2/3/4 的节点入站）或官方 Xray-core（模式 1/5）与官方 Caddy（订阅与回源站点），一台 VPS 只能选择一种模式：

| 菜单 | Profile | `PROTOCOL` | `CDN_PROVIDER` | 客户端入口 |
| :--- | :--- | :--- | :--- | :--- |
| 1 | `cloudflare` | `cloudflare` | `cloudflare` | 仅 Cloudflare 橙云 CDN `cf:443`（单域名，同时承载订阅；纯 Xray 后端） |
| 2 | `cloudfront` | `cloudfront` | `aws` | 仅 CloudFront CDN `cf:443`（+ 订阅） |
| 3 | `reality-cloudfront` | `reality-cloudfront` | `aws` | VLESS Reality 直连 `direct:443` + CloudFront CDN `cf:443`（单 `443` 合一回源至回环 `127.0.0.1:9443`） |
| 4 | `reality-cloudflare` | `reality-cloudflare` | `cloudflare` | VLESS Reality 直连 `direct:443`（+ 回环 `127.0.0.1:9443` 伪装站）+ Cloudflare 橙云 CDN `cf:443`（单域名同时承载订阅） |
| 5 | `reality-cloudflare-xhttp` | `reality-cloudflare-xhttp` | `cloudflare` | VLESS Reality 直连 `direct:443` + 橙云 VLESS XHTTP `cf:443`（单 `443` 合一，纯 Xray 后端） |

模式 4/5 由 `lib/reality-cloudflare-mode.sh` 承载（按 `runtime_uses_xray` 在同一套编排里分派后端），模式 2/3 共用 `lib/cloudfront-mode.sh`，模式 1 由 `lib/cloudflare-mode.sh` 承载；Profile 只声明模式常量（含 `BACKEND`：模式 2/3/4 为 `sing-box`，模式 1/5 为 `xray`）、状态字段表与直连钩子。

- **状态 schema 固定为 `1`**（`STATE_VERSION=1`）：`PROTOCOL` 同时是模式选择、安装进度 marker、安装身份与 Profile 路由的唯一键。schema `0`（4.x）不被接管也不自动迁移，必须先由旧版本 `uninstall`（需要时加 `--purge-cloud`）再用本版本重装。
- **本机节点与全部订阅入口统一 443**：Reality 入站 443、CloudFront viewer 443、橙云边缘 443。回源端口在模式 4 监听 `8443`（橙云回源，仅 Cloudflare 官方回源段放行），在模式 2 监听公网 `443`（由 `X-Easy-All-Origin-Key` 精确校验），在模式 1 监听 `443`（仅放行 Cloudflare 官方回源段）；模式 3 与模式 5 采用单 `443` 合一架构，直连与 CDN 回源统一经公网 `443` 透明回落至回环 `127.0.0.1:9443` 的 Caddy 按 `X-Easy-All-Origin-Key` 精确分流（模式 5 为双证书双站点隔离与全局 `default_sni`）。模式 3/4/5 的 `127.0.0.1:9443` 仅绑定本机回环。
- **CDN 传输按模式与后端区分**：模式 1/5（橙云 + Xray）用 `xhttp`（服务端 `mode=auto` + `extra`，客户端 `mode=stream-up` + `alpn: ["h2"]`）；模式 4（橙云 + sing-box）用 `httpupgrade`（服务端 `transport: {type: "httpupgrade", path}`，客户端 `alpn: ["http/1.1"]`）；模式 2/3（CloudFront）保持 `ws`（`transport: {type: "ws"}`）——CloudFront 会把 `Connection` 改写为 `Keep-Alive` 并剔除非完整 WebSocket 握手的 `Upgrade`，只透传带 `Sec-WebSocket-Key` 的真实 WebSocket 握手。
- 用户订阅 JSON 里的外部聚合节点保留原有 `host/port/portRange`，不强制改写为 443。

### 1.1 模式 1：Cloudflare 橙云（单域名，纯 Xray XHTTP）

模式 1 只承载橙云入口，一个域名同时提供节点与订阅：

```text
客户端 ── TLS(SNI=cf.<zone>) ──► Cloudflare 边缘（通用边缘证书，橙云代理）
                                       │ https-only 回源（Full strict），SNI/Host=cf.<zone>
                                       ▼
公网 443（仅 Cloudflare 官方回源 IPv4 段）Caddy（Origin CA 证书，header -Server）
  ├─ <VLESS_PATH>、<VLESS_PATH>/* → 127.0.0.1:10086（h2c 反代，flush_interval -1）
  │                                   └─ Xray vless-cdn-in（xhttp，mode=auto）
  ├─ = /subscribe、= /sub  → Token 鉴权的六产物订阅（非法 Token 返回 403；flag=singbox → 503）
  └─ 其他路径              → 404
```

- **后端**：纯 `xray-core`（追踪最新官方 Release）+ Caddy 2.11.9，服务单元 `easy_all-xray.service`，配置 `/etc/easy_all/xray/config.json`；**不下载、不安装、不启动 sing-box**，也不生成 `singbox*.json`。
- **DNS**：节点域名一条 `proxied=true` 的 `A` 记录（→ VPS 公网 IPv4），订阅域名由节点域名派生，不需要第二个名字。
- **证书**：只用 Cloudflare Origin CA（ECDSA P-256、5475 天、CN 与唯一 SAN 都是节点域名），直接签发与复用（仅使用 `443` 端口）；复用前除有效期/SAN/公私钥外还必须通过 `openssl verify` 链验证。
- **`Full (strict)` 门禁**：安装与 `apply-cloud` 在创建任何 DNS/证书资源前只读读取 Zone SSL 设置，只接受 `strict`；`full`/`flexible`/`off` 与 403 权限不足都在创建资源前停止，工具不会自动修改全区设置。XHTTP 走 HTTP/2 回源，**不再**预检 `Network -> WebSockets`，改为只读提示需在面板开启 `Network -> gRPC`。
- **回源白名单**：VPS `443` 只对 Cloudflare 官方回源 IPv4 段放行（UFW 注释 `easy_all-cf-origin-443`）。这是公共回源网段，不是账户级鉴权。
- **反指纹与探活**：站点剥离 `Server` 响应头（`header -Server`），仅开放精确代理路径与 `/subscribe`、`/sub`；本机与边缘探活通过 `/subscribe?token=invalid → 403`（本机兼查 `X-Robots-Tag` 与无 `Server` 头）完成。
- **无源站头、无熔断**：橙云链路没有 `X-Easy-All-Origin-Key`，也没有 mangle 计量与 985 GB 额度（这些只属于模式 2/3）。
- **订阅**：本机节点只有一个橙云 CDN 节点（默认名 `🇺🇸CF`，安装时可改），没有聚合优选 IP 列表或测速组；连接地址可用订阅配置的 `cdnEdgeAddress` 换成 CDN 优选域名（`*.cloudflare.182682.xyz`），TLS SNI 与 XHTTP `host` 仍是节点域名。订阅只产出六份 Base64/Mihomo 产物（不生成 `singbox*.json`，`flag=singbox` 返回 503）。
- **旧版 sing-box 模式 1 不支持原地换核**：`apply` / `apply-cloud` / `renew-cert` / `edit-sub` / `update-core` 在检测到旧版 sing-box 残留且缺 Xray 核心时于任何副作用前阻断，需用旧版 `uninstall` 后重装；`uninstall` 与 `cleanup-partial` 同时回收 `sing-box` 与 `xray` 两侧服务单元和二进制目录。
- **`apply` 的外部访问**：只读取公开的 Cloudflare 回源 IPv4 段与 Origin CA 根证书，不需要账号凭据、不修改云端。

### 1.2 模式 2：纯 CloudFront
一台 VPS 只承载 CloudFront 入口，不监听直连节点：

```text
客户端 ── TLS(SNI=cf.<zone>) ──► CloudFront 分发（ACM viewer 证书，us-east-1，viewer 443）
                                       │ https-only 回源 443，SNI/Host=origin.<zone>
                                       ▼
公网 443   Caddy（Let's Encrypt 源站证书，header -Server；route 首位 CEL 精确校验 X-Easy-All-Origin-Key）
  ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS WebSocket，回环不启用 TLS）
  ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅（非法 Token 返回 403）
  └─ 其他路径              → 404
```

- **DNS**：Cloudflare 只作权威 DNS，全部记录灰云（DNS only）——源站 `A → VPS`，节点 `CNAME → 分发域名`。订阅域名固定复用节点域名，因此只有一条 CNAME。
- **证书**：两套独立证书——viewer 侧 AWS ACM（固定 `us-east-1`，SAN 为节点域名；订阅同域，去重后只有一项）；源站侧 Let's Encrypt（只覆盖源站域名，经 Cloudflare DNS-01 签发与续期，公网仅使用业务端口 `443`）。旧装若已配置独立订阅域名，仍保留原 CNAME 与两项 SAN。
- **分发策略**：缓存策略 `CachingDisabled`（`4135ea2d-6df8-44a3-9df3-4b5a84be39ad`）、源站请求策略 `AllViewerExceptHostHeader`（`b689b0a8-53d0-40ab-baf2-68738e2966ac`，转发全部 query / User-Agent / Content-Type 与 WebSocket 升级所需头）、7 种方法、HTTP/2、`TLSv1.2_2021`、`sni-only`、viewer/origin 均 `https-only`、源站 TLS 1.2；`GrpcConfig` 关闭，不启用 WAF、访问日志、Origin Shield 或 Route 53。回源超时固定 `OriginReadTimeout=120`（官方上限，范围 1–120）、`OriginKeepaliveTimeout=120`（官方范围 1–300 之内）：两者同时约束「转发后等响应」与「两个响应包之间的间隔」，因此也是 WebSocket 空闲静默的容忍度。
- **Host 处理**：分发不转发 viewer Host，因此 AWS 回源 SNI/Host 就是源站域名（匹配 Let's Encrypt SAN）；Caddy 不再改写 Host，直接把 WebSocket 请求转给 `127.0.0.1:10086`。
- **反指纹与探活**：站点剥离 `Server` 响应头（`header -Server`），仅开放精确代理路径与 `/subscribe`、`/sub`；本机与边缘探活均使用 `/subscribe?token=invalid → 403`。
- **订阅**：本机节点只有一个 CDN 节点（默认名 `🇺🇸AWS`，安装时可改），没有聚合优选 IP 列表、测速组或自动兜底节点；连接地址可用订阅配置的 `cdnEdgeAddress` 换成 CDN 优选域名（如 `m3q8a1w7zr.cloudfront.182682.xyz`），TLS SNI 与 WebSocket `Host` 仍是节点域名。
- **暴露面**：源站 `443` 对公网可达（CloudFront 回源没有可枚举的固定 IP 段），源站安全依赖源站头、精确路径与业务鉴权。

### 1.3 模式 3：Reality + CloudFront

采用**单 `443` 合一架构**的「直连 + CloudFront」双入口：公网仅开放 TCP `443`（由 sing-box 独占），所有非 Reality 握手（普通浏览器、主动探测以及 CloudFront HTTPS 回源）均由 sing-box 透明转发到回环 `127.0.0.1:9443` 的 Caddy 合一站点，按 `X-Easy-All-Origin-Key` 精确分流：

```text
客户端 ── VLESS Reality (SNI=direct.<zone>) ──► 公网 443 sing-box (flow=xtls-rprx-vision, max_time_difference=2m)
客户端 ── TLS(SNI=cf.<zone>) ──► CloudFront 分发 (ACM us-east-1) ── https-only 回源 443 (SNI/Host=origin.<zone>, 注入 X-Easy-All-Origin-Key) ──► 公网 443 sing-box
                                                                                                                                              │ 非 Reality 握手透明回落
                                                                                                                                              ▼
回环 127.0.0.1:9443  Caddy 合一站点（header -Server；route 首位 CEL 精确匹配 X-Easy-All-Origin-Key）
  ├─ X-Easy-All-Origin-Key 匹配（CloudFront 回源分支）
  │    ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS WebSocket，阻断时 503）
  │    ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅（非法 Token 返回 403）
  │    └─ 其他路径              → 404
  └─ 其他流量（无头/错头/浏览器/主动探测 → 伪装站分支）
       ├─ */.*                  → 404（屏蔽隐藏点文件）
       ├─ POST /login、/api/auth/login → 401 JSON
       ├─ GET/HEAD 命中磁盘文件（try_files {path} {path}/index.html）→ 静态站点（实例变异页或自定义站点）
       ├─ GET/HEAD /favicon.ico → 204
       ├─ 非 GET/HEAD           → 405
       └─ 其他路径              → 404
```

- **协议栈与抗重放**：sing-box `vless` 入站 + `xtls-rprx-vision` + `tls.reality`，`listen 0.0.0.0`、`listen_port 443`，`server_name` 为自有直连域名，`tls.reality.max_time_difference: "2m"`（防范延迟重放探测，客户端与服务端时钟偏差超过 2 分钟时静默回落至伪装站）；Reality 的 `handshake` 指向本机回环 `127.0.0.1:9443`。
- **单 `443` 合一路由与反指纹**：Caddy 仅在 `127.0.0.1:9443` 监听（`CF_ORIGIN_DOMAIN != DIRECT_DOMAIN` 时站点地址同时列明两个主机名），剥离 `Server` 响应头（`header -Server`）并仅开放代理、订阅与伪装站路由。`route` 首位以 `@easy_all_valid_origin` 精确校验 `X-Easy-All-Origin-Key`：仅命中时进入代理/订阅分支，无头或错头请求全部落入伪装站分支（直连 `<VLESS_PATH>` 或 `/subscribe` 返回伪装站 `404`）；站点结构由 `caddy_reality_unified_structure_ok` 校验。本机/边缘探活使用 `/subscribe?token=invalid → 403`（本机兼查 `X-Robots-Tag` 与无 `Server` 头），`443` 回落验收以 `cmp -s` 逐字节比对 `https://<DIRECT_DOMAIN>:443/` 响应体与 `${CAMOUFLAGE_DIR}/index.html` 且断言无 `Server` 头。
- **伪装站防指纹与自定义站点保留**：由 `lib/camouflage.sh` 负责，内置 4 套中性原型模板（`templates/camouflage-{login,status,docs,studio}.html`，默认 `studio`，可用环境变量 `EASY_ALL_CAMOUFLAGE_TEMPLATE` 指定为 `login|status|docs|studio|random`）。首次部署时按实例随机变异品牌名、配色与圆角、CSS 自定义属性前缀（`--ui-<hex>`）、构建标识、联系邮箱与副标题文案，生成 `assets/site.css`、`favicon.svg`、`robots.txt`、`404.html`（`login` 原型额外生成 `assets/auth.js` 与 `login/index.html`），并写入受管清单 `/etc/easy_all/camouflage-managed.list`（`0600`）。部署具幂等非破坏性：每次写 Caddy 配置前（安装/`apply`/阻断/受限恢复/`renew-cert`）只要 `/var/www/easy_all/camouflage/index.html` 已非空即原样跳过，**保留已有实例变体或用户自行放置的自定义静态站点**（仅当无受管清单且哈希精确匹配 v5.5.0 未改动旧版默认页时自动清理并升级为当前默认变异站）；卸载与中断清理仅按受管清单删除本工具文件与空目录，不删除用户文件。
- **v5.5.0 平滑零中断迁移**：旧版（`443` + `8443`）升级代码后，只要 `state.env` 存在且 `/etc/easy_all/mode3-single443.migrated` 尚未生成，`caddy_mode3_needs_legacy_8443` 为真：纯本机 `apply` 暂保留 `8443` 兼容站点块与 UFW 放行防线上 CloudFront 回源 `502`。执行 `sudo easy_all apply-cloud` 时，先发布「`9443` 合一 + 兼容 `8443`」双通配置 → 更新 CloudFront 分发 `HTTPSPort=443` 并等待 `Deployed` 且目标 `HTTPSPort=443` 收敛 → 写入 `mode3-single443.migrated` 标记 → 切换为纯单 `443` 配置并回收旧 `8443` UFW 放行。
- **两个入口都是固定部署**：没有 `link` 变体，`SUBSCRIPTION_MODE` 恒为 `deploy`，回环 `9443` 的订阅分支与 `10086` 入站随之部署。
- **域名与证书**：源站域名复用直连域名（同一条灰云 `A`、同一份 LE 证书，`certificate_required_hosts` 去重后只输出 `{DIRECT_DOMAIN, CF_ORIGIN_DOMAIN}`）；订阅域名复用 CloudFront 节点域名（ACM `us-east-1` 证书）。
- **985 GB 熔断与 `protection_offline=true` 语义**：与模式 2 共用同一条 `cloudfront` 链：`sing-box` 的 `ExecStartPre` 挂 `internal-traffic-prepare`。正常超限熔断（`blocked=true, enforced=true, protection_offline=false`）只省略 `vless-cdn-in`（`10086`）并使 `9443` 回源分支的 `${VLESS_PATH}` 返回 `503`，**保留 `443` Reality 直连、`127.0.0.1:9443` 伪装站与经 CloudFront 的订阅访问**；但在受限恢复失败或计量失效触发 fail-closed 保护性停机（`protection_offline=true`）并停止 `sing-box` 时，由于模式 3 的全部公网 `443` 流量（含 CloudFront 回源与伪装回落）均经 `sing-box` 承接，TCP `443` 直连、伪装站与 CloudFront 回源/订阅将一并下线，直至 `cdn-traffic-sync` 完成受限恢复（`enforced=true, protection_offline=false`）。
- **凭据**：`sing-box generate reality-keypair` 在 `core` 阶段（核心已安装、证书与配置写入之前）生成并立即落盘到安装身份，保证中断续装复用同一对密钥；`REALITY_SHORT_ID` 由 `openssl rand -hex 8` 在输入阶段生成；客户端订阅只含公钥。
- **端口预检**：新装首轮检查公网 `443`、回环 `10086` 与 `9443`（含只绑 `127.0.0.1` 的监听）。
- **客户端**：Base64 / Mihomo / sing-box 三种格式同时包含 **Reality 直连节点 + CloudFront VLESS-WS 节点**。Reality 链接带 `security=reality`、`flow=xtls-rprx-vision`、`pbk`、`sid`；Mihomo 写 `reality-opts`，**不写** `support-x25519mlkem768`（保持经典 X25519，与服务端 1.14.4 握手一致）；sing-box 订阅写 `tls.reality` 与 `packet_encoding=xudp`。

### 1.4 模式 4：Reality + CloudFlare

「直连 + 橙云」双入口，直连入口为 Reality 自偷（与模式 3 的直连同构）。由 `lib/reality-cloudflare-mode.sh` 承载橙云业务编排（`cdn_prepare_direct_runtime` 钩子接 `reality_prepare_runtime`）：

```text
公网 443   sing-box VLESS Reality（自偷直连，SNI=direct.<zone>，flow=xtls-rprx-vision，max_time_difference=2m）
               非 Reality 握手 → 127.0.0.1:9443 Caddy 伪装站
回环 9443  Caddy 纯伪装站（仅 127.0.0.1，header -Server，仅用直连主证书 CERT_FILE；仅提供静态站/点文件 404/登录 401/favicon 204/非 GET|HEAD 405/未知 404）
公网 8443  Caddy（橙云回源，仅 Cloudflare 官方回源 IPv4 段，header -Server，使用独立橙云证书 CDN_CERT_FILE；节点域名同时承载订阅）
  ├─ <VLESS_PATH>          → reverse_proxy 127.0.0.1:10086（VLESS HTTPUpgrade）
  ├─ = /subscribe、= /sub  → Token 鉴权的八产物订阅（非法 Token 返回 403）
  └─ 其他路径              → 404
```

- **单域名**：`CF_NODE_DOMAIN` 同时是橙云节点域名、订阅域名与橙云回源证书名；Cloudflare 侧一条精确 `http.host` 的 Origin Rule 回源 `8443`。
- **伪装站与抗重放**：`tls.reality.max_time_difference` 同样为 `"2m"`；与模式 3 共用 `lib/camouflage.sh` 四原型实例随机变异、自定义静态站保留机制以及 `cmp -s` 回落首页逐字节验收。不同在于模式 4 的 `9443` 仅承载纯伪装站（由 `caddy_reality_camouflage_structure_ok` 校验），两个站点均剥离 `Server` 头且仅开放各自明确路由。
- **双证书 SAN 隔离**：Certbot DNS-01（Cloudflare）维护两套独立 lineage，共用同一份 `/etc/easy_all/cloudflare.ini`（无需额外 Cloudflare Token 权限）：主 lineage `easy_all` **仅**覆盖 `DIRECT_DOMAIN`（`/etc/easy_all/certs/fullchain.pem`，供 `9443` 伪装站与 `443` 握手，防直连证书 SAN 泄露橙云域名）；独立回源 lineage `easy_all-cdn` **仅**覆盖 `CF_NODE_DOMAIN`（`/etc/easy_all/certs/cdn-fullchain.pem`，供 `8443` 橙云回源）。v5.5.0 旧版合并证书升级后，执行 `sudo easy_all renew-cert`（或 `apply-cloud`）会自动触发 `--force-renewal` 缩容重签并拆分两张独立证书；拆分前仅执行 `apply` 时 `8443` 会平滑回退沿用旧 `CERT_FILE` 并告警。
- **无源站头、无熔断**：橙云回源没有 `X-Easy-All-Origin-Key`（防护依赖 UFW 的 Cloudflare 回源白名单），也没有 mangle 计量与 985 GB 额度。
- **状态与链路**：`CHAIN=cloudflare`；状态字段集为 `COMMON + DIRECT + REALITY + CDN + CLOUDFLARE_ORIGIN_RULE`，**不含** `AWS_*` 与 `CLOUDFLARE_ORIGIN_CERT_*`。
- **凭据**：`REALITY_SHORT_ID` 在输入阶段生成，密钥对在 `core` 阶段用已下载的核心生成；输入阶段先落盘一次安装身份，保证 `inputs`/`core` 之间中断仍可续装。
- **端口预检**：首轮同时检查 `443`、`8443`、回环 `10086` 与 `9443`（含只绑 `127.0.0.1` 的监听）。
- **客户端**：Base64 / Mihomo / sing-box 三种格式同时包含 **Reality 直连节点 + 橙云 VLESS HTTPUpgrade 节点**，节点构造与模式 3 相同，只把 CDN 链路换成橙云并改用 `httpupgrade`。


### 1.5 模式 5：Reality + CloudFlare（Xray XHTTP）

「直连 + 橙云」双入口，架构与模式 3 的单 `443` 合一一致，但后端换成纯 `xray-core`（不安装、不依赖、不下发 sing-box），由 `lib/reality-cloudflare-mode.sh` 承载业务编排、`lib/xray-core.sh` / `lib/xray-runtime.sh` 承载核心与渲染：

```text
公网 443   xray VLESS Reality（raw/tcp + xtls-rprx-vision，SNI=direct.<zone>，maxTimeDiff=120000）
               非 Reality 握手 → 127.0.0.1:9443 Caddy
回环 9443  Caddy 双站点（均 bind 127.0.0.1，header -Server，全局 default_sni direct.<zone>）
  ├─ https://direct.<zone>:9443   仅伪装站（TLS 用 CERT_FILE / KEY_FILE）
  └─ https://cf.<zone>:9443       独立橙云证书（CDN_CERT_FILE / CDN_KEY_FILE）
        外层 route 首位：@easy_all_valid_origin 精确校验 X-Easy-All-Origin-Key
          命中 → @easy_all_xhttp path <VLESS_PATH> <VLESS_PATH>/* → reverse_proxy 127.0.0.1:10086（h2c + flush_interval -1）
                 与精确订阅入口 /subscribe /sub
          未命中 → 伪装站（静默回落，不 abort）
回环 10086 xray VLESS XHTTP（mode=auto，extra.xPaddingBytes=100-1000、extra.scStreamUpServerSecs=20-80）
```

- **公网单 `443`**：模式 5 只开放 SSH 与 TCP `443`，不开放 `80`/`8443`，不配置 Cloudflare 回源端口白名单，也不使用 Cloudflare Origin Rule。
- **守卫头的来源**：Cloudflare Request Header Transform Rule（`http_request_late_transform`，单规则端点创建/更新/删除）在边缘为精确 `http.host` 注入 `X-Easy-All-Origin-Key`；密钥与 Transform Rule 的 ruleset/rule ID 一并落 `state.env`（`ORIGIN_HEADER_SECRET`、`CLOUDFLARE_TRANSFORM_RULESET_ID`、`CLOUDFLARE_TRANSFORM_RULE_ID`）。`lib/cf-transform-rule.sh` 只用单规则端点、按确定性 `ref` 与归属校验更新/删除，且任何日志都不打印密钥。
- **双证书 SAN 隔离 + default_sni**：沿用模式 4 的两套 Certbot lineage，但两块站点都在 `9443`：直连主机只返回 `easy_all` 证书，橙云主机只返回 `easy_all-cdn` 证书；全局 `default_sni ${DIRECT_DOMAIN}` 让空 SNI / 裸 IP 探测只拿到直连证书，未知 SNI 无通配站点块因而握手失败，`CDN_CERT_FILE` 的 SAN 永不外泄。
- **服务端配置**：`log.loglevel=warning`；DNS 只有 `1.1.1.1` 且 `queryStrategy=UseIPv4`；路由 `domainStrategy=IPIfNonMatch`，首条规则把 11 条私网/保留 IPv4 CIDR 与 `::/0` 打入 `blackhole`；出站为 `direct`（freedom，`UseIPv4`）与 `block`（blackhole）。零 `geoip.dat` 依赖。
- **客户端**：Base64 与 Mihomo 六产物包含 **Reality 直连节点 + 橙云 VLESS XHTTP 节点**（`mode=stream-up`、`alpn: h2`、`no-grpc-header: false`、`uplink-http-method: POST`、`reuse-settings`/`xmux`、`cdnEdgeAddress` 分离连接地址）。Xray ≥ 26.9.8 时 Reality 链接与 Mihomo 节点都声明 `support-x25519mlkem768`（更早版本链接追加 `mlkem=0` 且不写该开关）。**不生成 `singbox*.json`**。
- **状态与链路**：`CHAIN=cloudflare`；字段集为 `COMMON + DIRECT + REALITY + CDN + CLOUDFLARE_TRANSFORM_RULE`，`SUBSCRIPTION_MODE` 固定 `deploy`，订阅域名由节点域名派生。
- **端口预检**：首轮检查 `443`、回环 `10086` 与 `9443`（不预检 `8443`）。
- **不可降级**：`STATE_VERSION` 仍为 `1`（存量模式 2/3/4 升级零破坏），但模式 5 不能退回 5.7.0 及更早脚本管理，模式 1 不能退回 5.8.0 及更早脚本管理（旧版会把模式 1 当 sing-box 后端渲染），详见运维指南。

## 2. 防火墙、端口与安全边界

### 2.1 SSH 端口迁移与保护

> [!CAUTION]
> **所有模式安装成功后，可选把 SSH 端口迁移到安装收尾选定的新端口（默认 `22222`）：迁移后原端口被禁用（重启后生效），选「不变更」则配置与防火墙全部保持原样**。安装收尾不重启 `sshd`/`ssh.socket`；迁移后**请务必在提示确认时选择重启服务器**（AWS / GCP 等外部安全组请先放行 **TCP 新端口**，默认 `22222`），后续用新端口登录。

- **端口迁移与防火墙策略**：
  - 安装成功后（五种模式、三个 `install_all` 入口）先采集当前真正在用的 SSH 端口（有效配置、实际监听、当前登录端口与 `ssh.socket`），再以三选一菜单询问变更方式：`1. 不变更`（保持采集到的端口，不改 `sshd` 配置、不写受管片段、不动 UFW）、`2. 修改为 22222`（直接回车即选它）、`3. 自定义端口`（可输入 `1..65535`）；非交互环境可用 `EASY_ALL_TARGET_SSH_PORT` 预设。非法值（非 `1..65535`、与 `80`/`443`/`8443` 或其他业务端口冲突、已被第三方进程监听）会提示后重输。
  - 写入受管片段 `/etc/ssh/sshd_config.d/00-easy-all-ports.conf`（`Port <目标端口>`），把其他未注释的 `Port` 行注释为 `# easy_all-disabled-port: <原行>`；显式带端口的 `ListenAddress 203.0.113.10:2200` 则就地替换端口为 `ListenAddress 203.0.113.10:<目标端口>`，保留原绑定地址而不注释放宽监听范围。
  - **不重启 `sshd` / `ssh.socket`**，当前安装会话不会断连；`sshd -t`、`sshd -T` 端口集合（`port` 与 IPv4 `listenaddress`）与 `ssh.socket` 的 `Listen` 校验通过后只执行 `systemctl daemon-reload`，新端口**重启后生效**。
  - `sshd -t`/`sshd -T` 报 `Missing privilege separation directory: /run/sshd`（容器与精简镜像常见）时，自动 `install -d -m 0755` 建立该目录（可用 `EASY_ALL_SSHD_PRIVSEP_DIR` 覆盖）后重试一次。
  - UFW 同步放行目标端口，并在第 1 条插入受管 `deny <旧端口>/tcp`（所有采集到的旧端口，而不是只算 `22`），原有旧端口 `allow` 保留但被首条 deny 覆盖；Fail2ban 的 `sshd` jail 同步改为 `port = <目标端口>`。
  - UFW 设置默认入站拒绝、默认转发拒绝，仅放行必要端口，未放行端口由默认策略阻断。
  - Fail2ban 自动配置 sshd jail 实时监控保护安装收尾选定的 SSH 端口（选「不变更」时即当前端口）。
  - 收尾以红字提示「ssh端口已经修改为<目标端口>，原<旧端口>端口禁用」，提醒云厂商安全组先放行 TCP 目标端口，再用纯交互确认是否重启（重启前关闭当前会话将无法再从旧端口连接）；选「不变更」时该 SSH 提醒与强制询问整体跳过，仅在内核待切换时提示重启。
- **维护与卸载**：`apply` / `apply-cloud` / `edit-sub` 不删除受管 `00-easy-all-ports.conf`；在「已迁移未重启」窗口内按受管片段里的目标端口校验放行（新进程拿不到 `EASY_ALL_TARGET_SSH_PORT` 也成立），不会因旧端口已被禁用而失败。`uninstall` 按规则规格扫描删除所有受管 `deny <旧端口>/tcp`、还原迁移前的 `sshd` 配置，并确保恢复后的 SSH 端口（如 `22`）在 UFW 中仍有有效放行。
- **常驻安全基线归初始化**：`scripts/debian-init.sh` 负责激活 UFW（SSH 端口、ICMP 回显与出站放行）并配置 Fail2ban；easy_all 安装只在此基础上追加业务端口。
- **规则规格删除防编号漂移**：业务端口与 Cloudflare 回源白名单的清理升级为规则规格删除（通过 `stale_ufw_rule_delete_specs` 生成规格并执行 `ufw delete`），替代易受并发插桩干扰的行号逆序删除，彻底规避了 Fail2ban 动态插入规则导致的编号漂移与误删。
- **卸载与回滚只回收业务端口**：各模式 `uninstall` 与安装失败回滚一律只删除自己注入的 `443`/`8443` 放行与 Cloudflare 回源白名单，保留 UFW 启用状态、默认策略、SSH 放行与 Fail2ban 配置，不再执行 `ufw disable`。
- **Fail2ban 助手脚本解耦**：CIDR 封禁助手安装到 `/usr/local/sbin/fail2ban-ufw-cidr.sh`（不再位于 `/usr/local/lib/easy_all`），卸载 easy_all 时保留，避免常驻 SSH 封禁动作因脚本缺失而失效。
- **重装跳过已就绪的初始化**：卸载后重装时，依赖包、Swap、内核与 TCP 加速已就绪就跳过重复安装；IPv4-only、定时重启与 UFW/Fail2ban 仍会幂等校验。
- **定时维护互斥与安全加固**：每日定时重启任务引入运行时写锁检测（`flock -n 8`），检测到后台有安装或更新进行时自动跳过重启并向 syslog 记录审计日志，防止并发维护造成半安装现场；模式 2/3 还会在取得最终写锁后只读复核流量保护状态（`protection_offline=false` 且 `blocked=enforced`），不满足则跳过重启。cron 行本身只调用 `easy_all internal-scheduled-reboot` 内部入口，预命令、抢锁与流量复核都在该入口内完成，行长度固定、不再随逻辑增长，也无需 `%` 转义。

### 2.2 各模式端口与监听

| 模式 | UFW 公网放行 | 仅 Cloudflare 回源 IPv4 放行 | 本机回环监听 |
| :--- | :--- | :--- | :--- |
| 初始化（debian-init） | SSH 实际监听端口（安装收尾可选迁移到目标端口，默认 `22222`；迁移后旧端口被受管 `deny <旧端口>/tcp` 覆盖，选「不变更」则保持原端口与原放行） | — | — |
| 1 纯 CloudFlare（Xray XHTTP） | — | TCP `443` | `127.0.0.1:10086`（VLESS XHTTP） |
| 2 纯 CloudFront | TCP `443` | — | `127.0.0.1:10086`（VLESS WebSocket） |
| 3 Reality + CloudFront | TCP `443`（旧装未执行 `apply-cloud` 迁移前暂保留 `8443`） | — | `127.0.0.1:10086`（VLESS WebSocket）、`127.0.0.1:9443`（伪装站 + CloudFront 合一回源） |
| 4 Reality + CloudFlare | TCP `443` | TCP `8443`（橙云节点/订阅回源） | `127.0.0.1:10086`（VLESS HTTPUpgrade）、`127.0.0.1:9443`（伪装站） |
| 5 Reality + CloudFlare（Xray XHTTP） | TCP `443` | — | `127.0.0.1:10086`（VLESS XHTTP）、`127.0.0.1:9443`（伪装站 + 橙云 XHTTP 回源双站点） |

- **证书走 DNS-01**：所有公信证书均通过 Cloudflare DNS-01 自动签发与续期，公网仅开放各模式实际使用的业务端口。
- `10086` 与 `9443` 仅监听本机回环 `127.0.0.1`；端口预检覆盖各模式实际使用的端口（模式 1：`443`、`10086`；模式 2：`443`、`10086`；模式 3：`443`、`10086`、`9443`；模式 4：`443`、`8443`、`10086`、`9443`；模式 5：`443`、`10086`、`9443`）。
- 所有模式维持 IPv4-only、默认 incoming/routed deny、outgoing allow、SSH 预检与 Fail2ban。

### 2.3 源站暴露面（各链路差异）

- **模式 1、模式 4** 保留 Cloudflare 回源白名单：安装器只向 Cloudflare 官方 IPv4 网段新增回源端口放行（模式 1 是 `443`，模式 4 是 `8443`）。在宿主没有其他公网放行、云安全组也未额外放通的前提下，外部扫描器直连该端口会被静默丢弃；宿主已有的无注释放行不在本工具管理范围。
- **模式 3/4/5 的直连 `443` 对公网开放**，直连域名灰云 `A` 记录会公开 VPS 公网 IPv4。
- **模式 5 没有回源端口白名单**：橙云默认回源公网 `443`，源站守卫头由 Cloudflare Transform Rule 在边缘注入。公网验收在订阅链路之外追加直连 `443` 的守卫行为探测：缺头与错头访问 `<VLESS_PATH>`、`<VLESS_PATH>/probe`、`/subscribe` 必须与伪装站路由返回同一状态码（`404`）、无 `Server` 头、不出现订阅标记，`/` 返回 `200` 且与 `${CAMOUFLAGE_DIR}/index.html` 逐字节一致。
- **模式 2/3 没有回源白名单**：CloudFront 回源没有可枚举的固定 IP 段，因此模式 2 的源站 `443` 以及模式 3 经 `443` 回落至 `127.0.0.1:9443` 的合一源站对公网可达（模式 3 公网仅开放 TCP `443`）。实际防护依赖：
  - 公信 Let's Encrypt 源站证书（自签证书无法通过 CloudFront 的 HTTPS 回源验证）；
  - `X-Easy-All-Origin-Key` 源站头：模式 2 在 Caddy 外层 `route` 首位用 CEL 精确比较请求头与状态中的密钥，不相等即 `abort`；模式 3 在 `127.0.0.1:9443` 合一站点首位以 `@easy_all_valid_origin` 精确匹配该头，命中才进入代理/订阅分支，缺头或错头落入伪装站；
  - 随机 VLESS 路径的精确匹配（`handle <VLESS_PATH>`）与 `VLESS UUID`；
  - 订阅只精确匹配 `/subscribe` 与 `/sub`，其余路径 `404`，并由 Token 鉴权。
- 这些措施**不能**防御网络层 DDoS、TLS/HTTP 资源耗尽或密钥泄露。源站头密钥只存在于 `0600` 的 state、`0600` 的 Caddy 配置与 AWS 请求暂存文件中，不下发客户端、不进订阅、不写访问日志。
- 公网验收会分别对**源站端口**（模式 2/3 的 `443`）发缺头与错头请求：模式 2 只接受连接被拒或 `403/404`；模式 3 分别探测 `<VLESS_PATH>` 与 `/subscribe`，要求缺头与错头均严格落入伪装站返回 `404`。
- 公网验收的 DNS 判定走外部公共 DNS，且只在验收阶段这样用：域名等待同时查询 `1.1.1.1` 与 `8.8.8.8`，**任一命中即判定解析生效**，两侧状态不一致时输出一条告警（点名哪个解析器未命中或不可达）；两个公共解析器都没给出记录且至少一方不可达时，回退系统默认 DNS 取第三个意见（需命中才通过）；两个都可达且都无记录时继续等待。节点与订阅探测按公共解析结果注入 `--resolve`（按序查询 `1.1.1.1`、`8.8.8.8`，用首个命中者返回的 IP；两个都拿不到才回退系统 DNS），源站守卫探测直接钉本机公网 IPv4。安装与云端同步阶段的源站 `A` 记录等待只用系统默认 DNS。每次探测前会用两个公共解析器各查一次（单次上限 2 秒），因此公共 DNS 不可达时验收失败路径会明显变慢。

### 2.4 恶意出站与内部阻断
- 模式 1/5 的 Xray 配置显式声明私网/保留 IPv4 CIDR（与 sing-box 清单同一组 11 条）加 `::/0` 的 `blackhole` 路由，DNS 只有 `1.1.1.1` 且 `queryStrategy=UseIPv4`、出站 `domainStrategy=UseIPv4`，解析失败即终止连接；不依赖 `geoip.dat` 等外置数据。`lib/xray-runtime.sh` 的 `xray_private_ranges_json` 是独立定义（模式 1/5 不调用 `lib/singbox-runtime.sh`），一致性由 `test/test_xray_render.sh` 逐条断言。
- sing-box 配置使用显式 IPv4 DNS 服务器与 `ipv4_only` 策略，路由首条规则 `action: resolve` 先把目标域名解析成 IP，再拒绝私网地址及
  与 `lib/network.sh` 一致的私网/特殊地址清单（回环、云厂商元数据、CGNAT、多播与保留段）；不解析时域名目标匹配不上 IP 规则，私网与元数据拦截会整体失效。
  解析失败（含 NXDOMAIN、超时与空结果）时 `resolve` 会以错误终止该连接，不会继续向下匹配到 `final: direct`；
  以域名形式访问 `localhost`、单标签主机名或云厂商内部域名因此是连接被拒，而不是回落到直连。
- 不再拦截 UDP/443：直连流量原生走 QUIC，代理流量则以 `UDP-over-TCP`（`xudp`）承载穿过代理隧道；
  聚合节点标记 `udp: false` 时客户端侧表达为 `network: "tcp"`，UDP/443 由出站不支持 UDP 报错后回退 TCP。
  客户端 Mihomo 模板的嗅探（`sniffer`）仍不覆盖 QUIC：嗅探要解析握手，只会给 UDP 首包白加等待与内存开销，
  没有域名信息的 QUIC 由 GeoIP 与 `MATCH` 按已有目标 IP 兜底分流。

---

### 2.5 状态文件只读加载的完整性校验

`state.env` 由 `save_state` 用 `printf '%q'` 原子写入，读取时 `load_state` 必须 `source` 它——因此**文件内容本身**必须先证明无副作用。`lib/state.sh` 的 `state_validate_pure_assignments` 在 `source` 之前逐行卡两道：

- **纯赋值形态**：只接受 `KEY=`（裸空）、`KEY=''`、`KEY=""`、`$'…'`（ANSI-C 引串）与裸串 + 反斜杠转义五种形态。凡含未转义的 `$(…)`、反引号、`;`、`|`、`&`、`<`、`>`、圆括号或非空双引号的行一律拒绝；行尾孤立反斜杠拒绝（否则 `\`+换行 会把下一行拼进来）；换行以外的控制字符形态（如带 `\r` 的 CRLF 行）同样拒绝。
- **键名白名单**：允许出现的键 = `STATE_VERSION` + 该文件 `PROTOCOL`/`SUBSCRIPTION_MODE` 对应的 `state_required_fields` 字段集。白名单与写入方同源派生（不写死字段名），白名单**无法派生时直接拒绝**（fail-closed），不退化为只校验形态。

门失败时 `load_state` 直接拒绝加载并点名文件与行号，不执行任何一行内容。协议缺失或写坏的状态不再走本通道：`detect_installed_mode` 会将其归为 `incomplete-unknown`，由 `uninstall_incomplete` 做仅本机清理（该路径不加载 `state.env`，云端资源需人工核对）。

---

### 2.6 直连 443 主动探测日志（仅模式 3/4/5）

- **模式矩阵**（唯一判定，与 `lib/state.sh` 的模式字段集同源）：

  | 菜单 | `PROTOCOL` | 直连 443 入口 | 探测日志 |
  | :--- | :--- | :--- | :--- |
  | 1 | `cloudflare` | 无 | 不启用，安装/apply 无条件 remove |
  | 2 | `cloudfront` | 无 | 不启用，`cloudfront-mode.sh` 的 else remove |
  | 3 | `reality-cloudfront` | VLESS Reality | 启用（`cloudfront-mode.sh` 的显式守卫） |
  | 4 | `reality-cloudflare` | VLESS Reality | 启用（`reality-cloudflare-mode.sh` 无条件 apply） |
  | 5 | `reality-cloudflare-xhttp` | VLESS Reality | 启用（同一模式库无条件 apply） |

  `cloudfront-mode.sh` 的守卫严格为 `[[ "${PROTOCOL}" == "reality-cloudfront" ]]`；不得用「是否 CloudFront」「是否有 443 监听」代替。`hellogfw` 与内部 apply 的模式门禁用同一份 3/4/5 白名单。
- **固定资源与所有权**：systemd unit `${SYSTEMD_SYSTEM_DIR:-/etc/systemd/system}/easy_all-probe-log.service`、journald drop-in `${JOURNALD_CONF_DIR:-/etc/systemd/journald.conf.d}/99-easy_all-probe-retention.conf`、filter `INPUT` 里恰好一条自有规则。`SYSTEMD_SYSTEM_DIR` 与 `JOURNALD_CONF_DIR` 只给测试/隔离用。
- **规则签名**：`-I INPUT 1 -i <默认公网网卡> -p tcp --dport 443 --syn -m limit --limit 30/min --limit-burst 60 -j LOG --log-prefix "GFW_CHK: " --log-level 4`。`LOG` 不改变 `ACCEPT`/`DROP`，插到链首是为了记录后续可能被 UFW 拒绝的直连尝试。
- **匹配口径（查询 / 存在性 / 去重计数 / 清理共用）**：只接受**同一 `-A INPUT` 行内**同时含字面量 `--dport 443` 与 `--log-prefix "GFW_CHK: "` 的行；逐行匹配，不跨行拼接，也不只匹配前缀。对 `iptables-nft` 与 `iptables-legacy` 的 `-S` 输出等价。删除时把该行按 shell 引号规则拆成参数后交给 `-D INPUT`（不经 `eval`），因此历史网卡形式（`-i <iface>` 与 `! -i lo`）都能回收。
- **网卡取舍**：`ip -4 route show default` 取第一条带 `dev` 的默认路由网卡；拿不到默认路由或网卡名时回退为 `! -i lo`（不退化成不限接口）。默认路由模式只覆盖当前公网接口，多 WAN 的非默认接口不记录；路由/网卡变化不触发自适应，需重启、`apply` 或 restart 本服务。仅记录 IPv4。
- **每次 rule-only 重放都先成功读取 `-S INPUT` 快照**（查询失败与「0 条」严格区分，查询失败不盲插），再删全部自有规则，最后插一条并复核恰一条。
- **unit 契约**：`Type=oneshot` + `RemainAfterExit=yes`，`After=network-online.target ufw.service`，`ExecStart=<COMMAND_PATH> internal-probe-log-apply`，`ExecStop=<COMMAND_PATH> internal-probe-log-remove-rules`，`WantedBy=multi-user.target`。两个内部入口**不取 runtime 写锁**（父进程已持锁，再等同一把锁会死锁），iptables 子调用只用有界 `-w`；内部 apply 要求完整安装状态且 `PROTOCOL` 属于 3/4/5，内部 remove 只要求 root、不读也不猜 `PROTOCOL`。
- **UFW 顺序**：`configure_runtime_ufw → 既有核心/云端/订阅步骤 → save_state 与命令注册 → configure_post_install_ssh_port（可能再 reload 一次 UFW）→ 按 `PROTOCOL` apply/remove 探测日志`，且同步内部必须 `systemctl restart easy_all-probe-log.service`（`enable --now` 或仅写文件不能代替）。`apply_easy_all` / `apply_cloud_resources` 的收敛点在 `commit_subscription_update` 之后、`success` 之前：探测日志是观测能力，失败不能让已提交的配置回滚。
- **清理所有权**：`remove_probe_log` 的顺序为「先确认可查询 → disable/stop unit → 按最新快照删除规则 → 删 unit 与 drop-in → `daemon-reload` 与 `systemctl restart systemd-journald` → 复核 0 条」。三种 `cleanup_partial_install` 与 `uninstall_incomplete` 都按固定资源名无条件回收。缺 `iptables` 时，只要 state、unit 或 drop-in 任一存在就非零退并保留 state/命令（与 `cdn_traffic_counters_remove` 同口径）；只有三者都不存在才可放行。
- **journald drop-in**：完整内容只有 `[Journal]` 与 `MaxRetentionSec=30day`，整文件覆盖，**不写 `SystemMaxUse`**（避免额外触发基于容量的 vacuum）。它是 `systemd-journald` 的全局保留上限，影响主机全部 journal；写入与删除后均显式 `systemctl restart systemd-journald`（不用 `reload-or-restart`）。启用/失败文案与本文档必须同样保留「全局」表述；已 vacuum 的历史日志不可恢复。
- **CLI 契约**：公开参数只有 `--since <值>`、可重复的 `--my-ip <IPv4>` 与单独使用的 `-h`/`--help`；直连端口固定 `443`（无 `--port`）。`dispatch_validate_arguments` 只放行严格形式——`hellogfw --help --port 8443`、`hellogfw --since x --help` 等夹带形式一律非零拒绝。免 root 帮助出口固定在 `main` 的 `shift` 之前：仅当原始 `$1 == hellogfw`、`$# == 2` 且 `$2` 为 `-h`/`--help` 时，直接 source 无副作用的 `lib/probe-log.sh` 后调 `run_hellogfw`，不读 state、不要求 root、不加载 Profile/`log.sh`/runtime-core，也不创建 runtime 临时目录；`lib/probe-log.sh` 本身缺失时该出口报「运行时文件不完整」并非零退。
- **脚本路径与调用方式**：`lib/probe-log.sh` 在 source 时按自身 `BASH_SOURCE[0]` 推导 `PROBE_LOG_HELLOGFW_PY`（`<lib>/../scripts/hellogfw.py`），不依赖 `EASY_ALL_ROOT`，因此 `set -u` 且未定义该变量时直接 source 也能工作。`runtime.manifest` 把 `scripts/hellogfw.py` 与 shell 库同登记，注册器按 `0644` 安装，所以**不能直接执行**，统一用 `python3 "${PROBE_LOG_HELLOGFW_PY}" "$@"`。
- **分析前置校验**：非 help 调用先证明采集规则存在（生产读 `iptables -S INPUT`，测试可设 `HELLOGFW_IPTABLES_RULES_FILE`）；命令缺失、查询非零、快照不可读或规则不存在时输出「无法确认采集规则」与 `sudo easy_all apply` / `sudo systemctl restart easy_all-probe-log.service` 修复提示并非零退，不启动分析。
- **分析输入与措辞**：内核日志取 `journalctl -k --since <since> -o short-iso --no-pager`，只接受含 `GFW_CHK:` 且 `DPT=443` 的记录；核心日志按当前后端取 `journalctl -u easy_all-singbox`（模式 3/4）或 `journalctl -u easy_all-xray`（模式 5；`run_hellogfw` 按 `BACKEND` 传入 `HELLOGFW_CORE_UNIT`/`HELLOGFW_CORE_LABEL`），统计同期 `WARN`/`ERROR`/`[Warning]`/`[Error]`，并单独统计含 `REALITY: processed invalid connection` 的 Reality 非授权回落条数（该匹配不再要求行内先出现 WARN/ERROR；输出标注「含主动探测及模式 3/5 回源流量」）。`--help` 与分析说明同时提示：**模式 3（Single-443）与模式 5 下 CDN 回源流量（订阅刷新与应急 CDN）也共用 TCP 443**，其回源 SYN 与 Reality 回落日志会自然混入统计。测试分别用 `HELLOGFW_KERNEL_LOG_FILE` / `HELLOGFW_CORE_LOG_FILE` 替代（`HELLOGFW_SINGBOX_LOG_FILE` 保留为兼容别名；只替代日志，不替代规则校验）。journalctl 非零、样本不可读、匹配行关键字段无法解析都显式报错或标为「不完整」，绝不静默当成零记录。自动参照取出现次数 `>=3` 的前 2 个来源；候选定义为「参照连接后 `1.0–120.0` 秒内出现、全窗次数 `<=2`、不在参照集合内」，只是候选线索，不是连接时长测量，也不构成 GFW 归因证明。
- **测试隔离**：`test/test_probe_log.sh` 用 `mktemp -d`，把写入全部限制在 `SYSTEMD_SYSTEM_DIR` / `JOURNALD_CONF_DIR` / `HELLOGFW_*_FILE` 等临时路径，并把 `ip`、`iptables`、`systemctl`、`journalctl`、`ufw`、`sshd`、`fail2ban-client`、`crontab`、`ss`、`curl` 全部换成 PATH stub（未预设的调用直接失败）；不接触真实 `/etc`、真实 systemd、真实 iptables 或真实 journal。

---

## 3. 订阅分发与渲染

- **订阅配置 JSON**：`SUBSCRIPTION_CONFIG` 的顶层只有三个键——`allowedTokens`（用户 Token 字典，必需）、`nodes`（外部聚合节点数组，必需）与可选的 `cdnEdgeAddress`（CDN 优选连接地址，只存完整主机名）。`cdnEdgeAddress` 只影响五种模式各自的本机 CDN 节点（五种模式都带 CDN 入口）：接受并持久化该字段；字段缺失或为 `null` 等同于不启用，删除字段即回退到节点域名（安装期必定写入且不提供关闭选项，删除只用于排障）。形状校验只发生在一处（`lib/local-aggregation.sh` 的 `normalize_subscription_config`，install / `edit-sub` / `apply` 全经它），拒绝 `*`、URL、端口、路径、空白、IP 字面量与单标签主机名，通过后按小写规范化存储；校验失败时 `update_subscription` 在写快照之前就退出，已发布的订阅产物与状态不变。该字段随 `SUBSCRIPTION_CONFIG` 原样写入安装身份的 `subscription_config`，续装据此沿用原优选地址，不会重新随机（身份里没有该字段时按新规则生成）。
- **连接地址与 SNI/Host 分离**：本机 CDN 节点的连接地址（VLESS URI 的 `@host`、Mihomo `server`、sing-box `server`）取运行期变量 `CF_EDGE_ADDRESS`（由 `cdnEdgeAddress` 在 `apply_local_aggregation_config` 中派生，为空即用 `CF_NODE_DOMAIN`）；TLS SNI（`sni=`、`servername`、`tls.server_name`）、证书校验与 transport `Host`（`ws` 的 `headers.Host`、`httpupgrade` 与 `xhttp` 的 `host`）始终是节点域名，订阅 URL 域名、云端 DNS、回源与 Reality 直连都不受影响。
- **Caddy 路由顺序与反指纹**：外层 `route` 固定为「源站密钥守卫/分流（模式 2 首位 `abort` 守卫；模式 3 在 `127.0.0.1:9443` 首位按密钥进入回源分支、未命中走伪装站；模式 5 在 `127.0.0.1:9443` 的橙云回源站点首位按密钥分流、未命中静默走伪装站且设全局 `default_sni`）→ 精确代理路径 → 精确订阅入口 → 404」；全模式站点块剥离 `Server` 响应头（`header -Server`）并仅开放上述明确路由，本机与边缘探活统一走 `/subscribe?token=invalid → 403`（本机兼查 `X-Robots-Tag` 与无 `Server` 头）；模式 1/4 依赖回源白名单、`Full (strict)` 与业务鉴权（模式 1 的代理路径是 `@easy_all_xhttp` + `h2c` 反代，无源站头守卫）。
- **订阅入口是精确路径**：matcher 精确列出 `/subscribe` 与 `/sub`，两者进入同一处理器并保留 query；`/subscribe/`、`/subscribed`、裸文件与其他路径一律 `404`，不重定向、不做前缀匹配。
- **订阅处理器内部顺序**：公共响应头（`Vary: User-Agent`、`Cache-Control: no-store, no-cache, must-revalidate, max-age=0`、`Pragma: no-cache`、`X-Content-Type-Options: nosniff`、`X-Robots-Tag: noindex, nofollow, noarchive`）先于任何终止响应；随后非 `GET`/`HEAD` 返回 `405`，Token 缺失/错误返回 `403`，订阅未就绪返回 `503`；全部响应都带上述公共头。
- **Token 比较**：`ALLOWED_TOKENS` 的值构成 CEL 的精确字符串集合，大小写敏感、不使用正则，客户端文本不拼进表达式源码；`file_server` 只出现在鉴权后的订阅处理器里，且只 rewrite 到对应模式生成的一组固定文件（模式 2/3/4 为 8 份，模式 1/5 为 6 份）。
- **重复 query 参数**：Caddy 把同名参数逗号拼接，因此重复 `token` 无法匹配合法值，一律 `403`；重复 `flag`/`os`/`node` 的拼接结果不命中显式分支，回落到 UA 等默认行为。这是相对旧版首值语义的有意收紧。
- **原子渲染**：订阅文件在生成时先写入临时暂存目录，校验完整无缺后逐文件原子替换，防止高并发下载时读到半截内容（这是「单文件原子」而非整目录快照）。
- **八种产物（模式 1/5 为六种）**：`base64.txt`、`mihomo.yaml`、`mihomo-ios.yaml`、`singbox.json`（默认过滤 `optional` 节点）与 `base64-all.txt`、`mihomo-all.yaml`、`mihomo-ios-all.yaml`、`singbox-all.json`（`&node=all` 时附带 `optional` 节点）。iOS 变体从 YAML 剥离以 `sniffer:` 开头的整段，并把顶层 `tcp-concurrent` 由 `true` 改为 `false`（桌面端开启并发建连，iOS 受后台内存红线限制），其余规则不变；sing-box JSON 没有 iOS 变体（嗅探只读首包、最长等 300ms，不像 Mihomo 那样需要为内存剥离）。两份 JSON 在模式 2/3/4 没有 optional 支持节点时内容相同，文件仍总是生成；模式 1/5 是纯 Xray 后端，不生成 `singbox*.json`（`flag=singbox` 返回 503）。
- **客户端自适应**（判定顺序固定为「显式 flag → 已确认的 sing-box UA → Clash UA → Base64」，只选一种格式）：
  - 根据 HTTP 请求头中的 `User-Agent` 自动识别客户端；
  - 官方 sing-box 客户端 SFA / SFI / SFM / SFT / SFW / SFL 的远程配置请求返回完整 JSON。按小写归一化后匹配 UA 前缀（例如 `sfi (sing-box `）；仅含 `sing-box` 字样的其他 UA 不命中；
  - Clash / Mihomo 客户端自动返回格式合法的 YAML 订阅（采用最新 MRS 规则集）；
  - 通用客户端返回经过 Base64 编码的节点 URI 列表；
  - `flag=singbox|sing-box` 强制 JSON，`flag=clash|mihomo|meta|stash|yaml` 强制 YAML，`flag=base64|uri|v2ray|shadowrocket` 强制 Base64；显式 flag 覆盖 UA。`os=ios` 只在 YAML 分支（Clash 家族 UA 或 `flag=clash`）选 iOS 变体，JSON 与 Base64 分支不受影响；`node=all` 附带可选聚合节点；大小写不敏感。
- **JSON 分支的响应与失败路径**：`Content-Type: application/json; charset=utf-8`，下载名为 `<SUB_DOWNLOAD_NAME>.json`；HEAD 与 GET 同状态同头。已启用 JSON 分支但目标文件缺失时返回 `503`，不会切换成其他格式，也不影响 YAML / Base64 请求。
- **平台自适应（嗅探段）**：默认模板开启 `sniffer`。UA 命中 `iphone|ipad|ipod|ios`（`ios` 需独立单词，避免 `Studios`/`Radios` 之类 UA 被误判）或在 URL 追加 `os=ios` 时，
  下发单独渲染的 YAML，剔除以 `sniffer:` 开头的整段配置（兼顾 iOS 内存预算、防 APNs 推送干扰、私有协议首包延迟与 CDN 调度劣化）；
  模板若把 `sniffer` 写成内联映射，安装会直接报错，不会静默下发未剔除的嗅探段。

### 3.1 节点与分组顺序

Base64 平铺顺序与 Mihomo `proxies` 顺序完全一致；`PROXY` 组的成员只在本机节点之后追加聚合节点：

| 模式 | Base64 / `proxies` 顺序 | `PROXY` 成员 |
| :--- | :--- | :--- |
| 1 纯 CloudFlare | Cloudflare 橙云节点 → 聚合 `nodes`（原顺序） | 同左 |
| 2 纯 CloudFront | CloudFront 节点 → 聚合 `nodes`（原顺序） | 同左 |
| 3 Reality + CloudFront | 本机 Reality 节点 → CloudFront 节点 → 聚合 `nodes`（原顺序） | 同左 |
| 4 Reality + CloudFlare | 本机 Reality 节点 → 橙云节点 → 聚合 `nodes`（原顺序） | 同左 |
| 5 Reality + CloudFlare（Xray XHTTP） | 本机 Reality 节点 → 橙云 XHTTP 节点 → 聚合 `nodes`（原顺序） | 同左 |

- `PROXY` 为 `select`，默认第一项分别是直连节点（模式 3/4/5）或 CDN 节点（模式 1/2）；即使聚合节点为空也始终有有效成员。
- 模式 4/5 与模式 3 结构一致：`PROXY` 由用户手动在直连节点与 CDN 节点之间切换，没有自动测速或兜底组。
- 模式 1/5 只有六份 Base64/Mihomo 产物（`base64{, -all}.txt`、`mihomo{, -all}.yaml`、`mihomo-ios{, -all}.yaml`）：`render_subscription_files` 经 `runtime_supports_singbox_subscription` 跳过 sing-box JSON 生成，`flag=singbox` 因产物缺失返回 503。
- 模式 1 的 `PROXY` 只有橙云 XHTTP 一个本机节点（无 Reality 直连），分组结构与模式 2 相同。
- `GLOBAL` 维持 `select`，唯一成员是 `PROXY`；切换到「全局」后所有接管流量使用 `PROXY` 的当前选择。
- 模板只保留 `PROXY` / `GLOBAL` 两个占位区；`build_mihomo_proxy_groups` 由各模式库提供，当前三个模式库（`reality-cloudflare-mode.sh` 同时服务模式 4 与模式 5）均输出空内容（不注入额外分组），`AUTO`、`CDN-AUTO`、`CDN-FALLBACK` 等名字属于保留组名，不能用于聚合节点。
- 聚合节点支持三类：`vless` + `reality/tcp`、`vless` + `tls/xhttp`、`mieru`；外部聚合节点的 `host/port/portRange` 原样保留，不受本机「全 443」约束，也不受「本机只有一个 CDN 节点」的限制。

### 3.2 sing-box 完整 JSON 订阅

- **适用范围**：仅模式 2/3/4（sing-box 后端）生成；模式 1/5 是纯 Xray 后端，不生成 `singbox*.json`，`flag=singbox` 返回 503。

- **合成方式**：`templates/singbox.json` 提供固定段（`log`、`dns`、`inbounds`、`route`、`rule_set`、`http_clients`、`experimental`），`lib/singbox-subscription.sh` 用 `jq` 注入 `outbounds` 与 `PROXY` 选择器。节点来自 `lib/local-aggregation.sh` 的结构化数据与本机身份字段，不反向解析 URI/YAML，也不做字符串替换拼接凭据。
- **入口**：混合代理 `127.0.0.1:1080` 与 TUN（`198.19.0.1/30`、MTU 1500、`auto_route`、`dns_mode=hijack`）；TUN 地址取 RFC 2544 基准网段并避开 Fake-IP `198.18.0.0/16`，不与下面被排除的私网段重叠（原 `172.19.0.1/30` 落在 `172.16/12` 内，属于“自己排除自己”，按排除表裁路由的平台会让 TUN 自身地址不可达）；TUN 由客户端平台管理接口名；`route_exclude_address` 排除 `10/8`、`172.16/12`、`192.168/16`、`169.254/16`、`100.64/10`（与 Mihomo 模板的 `route-exclude-address` 一致），私网、CGNAT（Tailscale/ZeroTier）与链路本地流量不进 TUN，漏进来的也由路由规则直连（`ip_is_private` 既不含 `100.64.0.0/10` 也不含 `169.254.0.0/16`，因此单独有一条 `ip_cidr` 规则同时列出这两段，云元数据 `169.254.169.254` 与经 `mixed-in` 的同类访问都不会落到 `PROXY`）；这些网段被排除后，指向内网 DNS（如路由器 `192.168.x.1:53`）的查询也不再进入 TUN、不被 `hijack-dns` 接管，这类客户端拿不到 Fake-IP 与反向映射，只能按 IP 分流（与 Mihomo 同行为）。嗅探规则只对 `tun-in` 生效、且端口不设上限（官方客户端示例的 `{"action":"sniff"}` 是全入站嗅探，但对 `mixed-in`（`127.0.0.1:1080`）也嗅探只会给本地工具的非 Web 协议白加 300ms，而这类入站本来就从 SOCKS5/HTTP CONNECT 拿到域名），只嗅探 TCP 的 HTTP/TLS，不嗅探 QUIC（嗅探要解析握手，只会给 UDP 首包白加等待与内存开销，QUIC 由 GeoIP 与 `MATCH` 按已有目标 IP 兜底；Mihomo 同样不嗅探）；不设端口上限的代价是非 HTTP/TLS 的 TCP 连接（SSH、MySQL 等，尤其服务端先发数据的协议）首包最多多等 300ms（核心只在 `common/sniff/sniff.go:Skip` 里硬编码跳过邮件端口 `25`/`465`/`587`、`143`/`993`、`110`/`995`，其他服务端先发协议照旧等满超时；Mihomo 用 `80,8080-8880 / 443,8443` 的端口上限规避这一点）。`clash_api` 仅监听 `127.0.0.1:9090`，`access_control_allow_origin` 只放行内置直连的 `clash.razord.top` 与 `yacd.haishan.me` 的 **https** 来源（不放行 `http://`：面板域名在规则里直连，明文 HTTP 面板可被局域网中间人注入脚本，而注入的脚本又能借 `access_control_allow_private_network` 过预检、读写本机 API），其余网页的跨域预检不会通过，避免任意网页改写本机模式与节点；未设 `secret`，同机其他进程仍可直接读写该 API（多用户主机需自行限制，本项目不生成凭证）。
- **DNS**：`fakeip`（`198.18.0.0/16`）+ 独立 IPv4 引导解析器（UDP，默认直连出口，现仅用于 `doh.pub` 的引导）+ 国内解析（DoH，默认直连出口，AliDNS `223.5.5.5` 直连 IP + DNSPod `doh.pub` 域名，后者必须带 `domain_resolver=dns-bootstrap`——1.14 起 DNS 传输自己就是 dialer，域名型 server 缺这个字段会在启动期报错）+ 境外解析（DoH，`detour=PROXY`，`1.1.1.1` + `8.8.8.8`）+ 节点引导解析（DNSPod 纯 IP DoH `1.12.12.12`，默认直连出口，不带 `detour`，只用于 `route.default_domain_resolver`，不参与上面两组竞速）；国内/境外各两个源，对齐 Mihomo 的双 `nameserver`：每个分组用两条并行 `evaluate` 加两条 `race` 的 `respond`（先到且 `NOERROR` 者胜），再加两条不限 rcode 的 `respond` 兜底（两源都是 NXDOMAIN 时原样返回，不会被 Fake-IP 掩盖）；只有两源都无应答（超时或传输失败）时才落到后面的规则（最终是 Fake-IP），两源都返回错误 rcode（如 SERVFAIL）时把该 rcode 原样回给客户端；规则游标停在前面的竞速规则上，不带 `race` 的兜底 `respond` 即使已匹配也要等竞速组决议完（两源都没给 NOERROR）才生效，所以快源先返回 NXDOMAIN/SERVFAIL 不会截杀稍后到达的 NOERROR；私有域名（`private-fallback` 内联集合 + `geosite-private`，覆盖路由器管理域名与反查区域）、单标签主机与认证门户走本地解析；NTP/STUN/推送/音乐等 Fake-IP 例外单独内联；全局 `ipv4_only`；`reverse_mapping` 开启。解析路径分两类：TUN 劫持后的应用查询按 `dns.rules` 选服务器（**代理集合优先于国内集合**，与默认 Mihomo 模板的 `nameserver-policy` 同序，避免 `services.googleapis.cn`/`google.cn` 这类交集域名被国内解析抢先）；出站自身的域名解析不经过 `dns.rules`，因此 `DIRECT` 出口固定带 `domain_resolver=dns-local`（本地解析，局域网域名可解析），节点出口用 `route.default_domain_resolver=dns-dnspod` 引导（DNSPod 纯 IP DoH，自身不需要解析器也不带 `detour`，不与待解析的代理节点互相依赖，并避开阿里云 `223.5.5.5` 对部分节点域名返回 SERVFAIL、以及蜂窝网络下明文 UDP 53 被拦截或返回 SERVFAIL）。注意 sing-box 1.14 拒绝把 DNS/HTTP 客户端的 `detour` 指向**空 direct 出口**（启动期 FATAL），所以“直连”一律用不带 `detour` 的默认出口表达，只有境外 DoH（两个源）显式写 `detour=PROXY`。`clash_mode` 同样出现在 DNS 规则里，位置在私有/单标签/认证门户之后、代理集合之前：`direct` 模式其余查询改用国内 DoH（不再依赖代理节点，也不再返回 Fake-IP），`global` 模式其余查询改用境外 DoH；局域网与认证门户的解析在任何模式下不变。
- **反向映射**：`dns.reverse_mapping` 把已应答的 IP 反查到域名，使「应用直接连接真实 IP（未命中 `geoip-cn`、没有 Fake-IP 映射）」的连接仍能命中域名规则（微信、Steam 下载、国内直连集合的 UDP 与 TCP），对应 Mihomo 模板的 `force-dns-mapping` / `parse-pure-ip`。它依赖应用先把域名交给 sing-box 解析，系统 DNS 被代持并缓存的平台（如 macOS）可能拿不到映射，此时按原 IP 规则分流；共享 IP 上的多个域名仍按已解析的那个域名归类。
- **分流顺序**与默认 Mihomo 模板逐条对应：DNS 接管 → 私网、CGNAT、链路本地与零地址 → 单标签/认证门户/本地管理域名 → FCM `5228-5230` → 代理服务与 Google 域名代理 → 微信/Steam/Apple 中国/国内服务 → 国内域名集合 → Telegram IP 代理 → CN IP 兜底 → `PROXY`。`UDP/443` 不再有任何拦截规则，三份 Mihomo 模板顶层为 `tcp-concurrent: true`（iOS 变体下发时改为 `false`）。`clash_mode=direct/global` 在路由与 DNS 两处都优先于业务规则。
- **规则集**：小型内联集合（`private-fallback`、`captive-portal`、`fakeip-exceptions`、`proxy-services`、`wechat-services`、`steam-download`、`apple-cn-fallback`、`direct-services`、`telegram-fallback`）与 MetaCubeX 的 sing-box 分支 SRS（`geosite-*`、`geoip-*`，`update_interval=1d`）并存；下载走显式 `http_clients`（默认直连出口，不依赖待解析的代理节点）。冷启动时任一必需远程规则集下载失败会让客户端配置启动失败，少量内联规则只缩短影响面，不构成离线首次启动保证。内联集合的 `domain_suffix` 不写前导点：锁定核心对无点后缀按「裸域 + 各级子域」匹配（等价 Mihomo 的 `+.` 写法），带点后缀只匹配子域，因此 `wechat.com`、`steamcontent.com` 这类裸域与子域都会被同一个条目覆盖。
- **策略组差异**：`PROXY` 为 `select`，成员顺序与本机节点/聚合节点一致，默认选中首个本机节点；全模式都只有 `PROXY` 与 `DIRECT`，不生成自动测速或兜底组。
- **节点映射**：本机 Reality（`uuid` + `flow=xtls-rprx-vision` + `tls.reality`，客户端只写公钥与 short_id）与 VLESS CDN 节点（模式 2/3：`transport.type=ws` + `headers.Host`；模式 4：`transport.type=httpupgrade` + `transport.host` + `tls.alpn=["http/1.1"]`；模式 1/5 的 Mihomo 节点为 `network: xhttp` + `xhttp-opts`（`mode: stream-up`、`alpn: [h2]`、`reuse-settings`）；两者 `packet_encoding=xudp`）；聚合 Reality 节点映射为 `flow=xtls-rprx-vision` + `tls.reality`（`public_key`、`short_id`），`udp=false` 时用 `network: "tcp"` 限制承载。1.14.4 的 Reality 客户端会从 ClientHello 里过滤 `X25519MLKEM768`（`common/tls/reality_client.go`），因此聚合节点的 `supportX25519Mlkem768` 在 sing-box 侧没有对应开关：`false` 与核心行为一致，`true` 的 PQ 扩展不会出现，两者都仍用经典 X25519 连接，所以都保留。源站密钥永不进入 JSON。
- **排除规则**：官方 1.14.4 没有 xhttp 传输与 mieru 协议，`fp` 不在 1.14.4 utls 枚举内的 Reality 节点会让核心拒绝整份配置，因此这两类节点只从 JSON 排除，`apply` 会输出节点名、原因与数量；Mihomo / Base64 输出不变。Reality 的 `supportX25519Mlkem768` 不参与排除（见上一条：核心固定过滤 MLKEM），但该行为的握手实测仍未进行。所有模式都至少有一个本机节点，因此排除后 JSON 仍有效；本机节点生成失败则整个候选发布失败。
- **候选校验**：发布前检查 JSON 可解析、outbound tag 唯一、策略组成员与路由/DNS 引用存在、默认出口存在、无源站密钥；存在锁定核心时再跑 `sing-box check`。`check` 不覆盖运行期初始化，因此 `scripts/verify-live.sh` 还会把客户端 JSON 去掉 TUN 入口后用真实核心启动一次（DNS detour 指向空 direct 出口这类问题只在启动阶段暴露）。校验失败即中止发布，已发布的旧订阅保持不变。
- **发布与流控边界**：JSON 与六份旧产物在同一暂存目录生成并沿用逐文件原子替换（单文件原子，不是整代快照）。`render_mihomo_base64_files` 保留六产物渲染，仅供 CDN 就绪判定与流控门禁复用；JSON 缺失或损坏不会改变 `blocked`/`pending` 状态，也不清零用量。

---

## 4. CDN 流量计量与双层阻断

### 4.1 统计链路
- 不依赖受测 sing-box 未编译的 `v2ray_api`，而是在 `mangle` 表用链首无 target 的纯计数规则统计回环 `10086` 的双向字节：`INPUT` 匹配 `lo` + `127.0.0.1` + TCP `10086` 计上行（Caddy → sing-box，用于计数回退异常检测），`OUTPUT` 匹配同条件计下行（sing-box → Caddy，作为 `used_bytes` 累计值以匹配 CloudFront 仅计出站口径），每方向每包只计一次；上行（Data Transfer to Origin）不再计入 985 GB 熔断额度，订阅响应头 `Subscription-Userinfo` 通过 Caddy `{file.<CADDY_CONFIG_DIR>/subscription-userinfo}` 占位符实时读取下月 1 日 `00:00:00 UTC` 重置时间与按客户端 GiB 口径换算后的出站用量。
- 用 mangle 而非 filter，是为了避免 UFW 早期 `ACCEPT lo` 让规则不可达；受管 UFW reload 后仍会复核规则，自定义规则也可能改写 mangle。
- 模式 3 的直连入口（Reality）、模式 3 的伪装站与全部订阅下载都不经过 `10086`，因此不计入 CDN 用量。
- 计数读取失败、规则缺失或修复失败一律按保护失败路径处理，**不清零、不放行**；阈值固定 `985 × 10⁹` 字节，state 里的 `CDN_TRAFFIC_PROTECTION_GB` 必须恰为 `985`，不能用环境变量绕过。

### 4.2 用量文件、锁与月度
- `/etc/easy_all/cdn-traffic-usage.json`（`0600`，同目录临时文件 + 原子 rename）字段白名单：`period` / `runtime_id` / `used_bytes` / `last_uplink` / `last_downlink` / `blocked` / `enforced` / `protection_offline`。
- 合法的旧七字段文件只在读取时把缺失的 `protection_offline` 解释为 `false`，下一次原子更新补齐；其他缺字段、类型错误或违反「`protection_offline=true` 必须同时满足 `blocked=true`、`enforced=false`」都判为损坏。损坏时拒绝操作并告警，不会创建替代文件或清零。
- 计量有独立的 counter 锁 `/run/easy_all/traffic-counter.lock`：规则检查/插入/唯一性清理、epoch 与基线、所有 usage 写入及熔断判定都必须在锁内完成，`iptables` 使用有界 `-w`；`subscription-userinfo` 同步在释放 counter 锁后仅作为原子替换后 `cdn-traffic-usage.json` 的只读快照消费方读取。
- `period` 按 **UTC 自然月**；`used_bytes` 只在月切换时重置，核心重启、规则重建或回补都不会清零（升级当月若存在切换口径前累计的历史 `used_bytes`，可能包含此前上行字节，属保守偏高，不回溯扣减）。`runtime_id` 是包含 `boot_id` 的计数 epoch：同 epoch 增量取 `max(0, current - previous)`，换 epoch 只重采样基线并保留累计，同时告警连续性丢失。`/proc/sys/kernel/random/boot_id` 不可读时采样直接失败并保留现有保护状态（不再用时间戳兑底）：每轮换 epoch 会让增量恒为 0，保护等于不存在。受支持的 Debian/Ubuntu 宿主默认提供该文件。
- `/etc/easy_all/caddy/subscription-userinfo`（`0600`，同目录临时文件 + 原子 rename，无结尾换行，内容未变时跳过重写）：由 `cdn-traffic-sync` 与 `write_runtime_config` 同步写入 `upload=0; download=<换算后字节>; total=1057635696640; expire=<下月1日UTC时间戳>`（按 `1024^3/1000^3` 等比例映射，使按 GiB 显示的客户端精确展示 `985 GB` 与十进制已用量），供 Caddy `{file.*}` 运行时占位符在订阅响应中实时下发 `Subscription-Userinfo`。
- 用量与保护标记不参加本机配置事务回滚，旧快照不会覆盖新 usage。

### 4.3 双层阻断与恢复
达到阈值后 `blocked=true`，阻断顺序固定：

1. **Caddy 层**：精确代理路径直接 `respond 503`，订阅（及模式 3 的伪装站）保持可用。
2. **sing-box 层**：省略 CDN 入站并重启核心，终止已建立的 CDN 长连接；模式 3 保留直连入站（Reality），因此直连只经历一次短暂重连。
3. 只有确认旧连接断开、新连接被拒绝后，才写 `enforced=true`。

状态语义：`blocked` 是期望的限额状态，`enforced` 是最后完成验收的应用状态，两者不一致即「待落实」；`protection_offline=true` 表示 fail-closed 保护性停机意图已持久化（核心已停止或即将停止），它不表示允许解封，也无法通过环境变量或临时令牌绕过。无法安全收敛时保持 `protection_offline=true` 并停止核心：模式 3 因单 `443` 合一由 sing-box 承接全部 `443` 流量，停止核心后直连、伪装站与经 CloudFront 的回源/订阅会一并下线，直到 `cdn-traffic-sync` 完成受限恢复。

**fail-closed 自愈与幂等**：

- **反向漂移**：`usage` 声称 `enforced=true` 但 live 配置仍开放 CDN 入站（重建后落盘失败、进程中断）时强制收敛为阻断，不因「`blocked==enforced` 即无需重建」而永久 fail-open。
- **正向漂移**：`usage` 为 `blocked=false/enforced=false` 但 live 配置已无 CDN 入站（回滚后状态未落盘）时强制补状态。
- **订阅未就绪**：目标为保持阻断时安装返回 `503` 的降级 Caddy 配置，live 仍开放 CDN 入站则强制重建，配置已受限则不重复重建（幂等）；解封一律拒绝并提示 `edit-sub`。
- **计量异常**：同一次开机内计数回退（规则被外部 flush）与 `iptables -S` 查询失败都按计量异常处理（告警 + 保留现有保护状态）：前者静默写 0 增量会漏计整月流量，后者被当成「0 条」会导致重复插入与双倍计量；插入后还会复检条数。

所有入口共用同一个只读判定与同一个受限恢复函数：先应用 `503` 与受限 Caddy，再启动受限核心（省略 CDN 入站、模式 3 保留直连入站），必需验收（Caddy `503`、受限配置与旧连接终止、严格源站 TLS 与 `/subscribe?token=invalid → 403` 探活、模式 3 的 `443` 回落验收与 `443` 监听等）全部通过后才原子写 `enforced=true`、`protection_offline=false`。必需验收失败会把 `protection_offline` 先落盘再停止核心，下一轮从同一入口重试；解封失败则恢复受限配置并保留 pending，绝不恢复开放配置后报成功。

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
│   ├── cloudflare.sh            # 模式 1：纯 CloudFlare 薄 Profile（单域名，纯 Xray 后端，空直连钩子）
│   ├── cloudfront.sh            # 模式 2：纯 CloudFront 薄 Profile（仅常量与空直连钩子）
│   ├── reality-cloudfront.sh    # 模式 3：Reality + CloudFront 薄 Profile
│   ├── reality-cloudflare.sh    # 模式 4：Reality + CloudFlare 薄 Profile
│   └── reality-cloudflare-xhttp.sh # 模式 5：Reality + CloudFlare Xray XHTTP 薄 Profile（BACKEND=xray）
├── lib/
│   ├── log.sh                   # 日志与双语输出
│   ├── state.sh                 # 状态 schema、五模式字段集与 launcher 分类的单一来源
│   ├── platform.sh              # 系统环境、Debian 探测与基础依赖
│   ├── runtime-core.sh          # 跨模式通用运行时（后端分派、单/双 lineage 证书事务、订阅发布、核心事务、停机清理）
│   ├── profile-common.sh        # Profile 映射、安装身份与快照/续装/回滚
│   ├── network.sh               # IPv6 校验、公网 IPv4 探测与 Google 出站策略
│   ├── cf-dns.sh                # Cloudflare API / DNS / Origin CA / 回源网段与持久 Token
│   ├── cf-origin-rule.sh        # Origin Rule 单规则生命周期（ref/归属/追加/删除）
│   ├── cloudfront-mode.sh       # 模式 2/3 唯一 CloudFront 业务核心
│   ├── cloudflare-mode.sh       # 模式 1 唯一橙云业务核心（单域名 + XHTTP 反代 + Origin CA + 回源白名单）
│   ├── reality-cloudflare-mode.sh # 模式 4/5 业务编排（直连入站、橙云订阅站点、Origin Rule / Transform Rule）
│   ├── cdn-traffic-guard.sh     # mangle 计量、985 GB 阈值、保护状态机与 systemd timer
│   ├── cloud-purge.sh           # Cloudflare 与 CloudFront/ACM 远端托管资源识别与清理
│   ├── singbox-core.sh          # 锁定 sing-box 版本、官方归档与固定 SHA256
│   ├── singbox-runtime.sh       # 模式 2/3/4 sing-box JSON、客户端节点与运行验收
│   ├── singbox-subscription.sh  # sing-box 完整 JSON 客户端订阅（模板 + 结构化节点合成）
│   ├── xray-core.sh             # Xray-core 最新官方 Release 下载、.dgst SHA2-256 校验与服务单元
│   ├── xray-runtime.sh          # 模式 1/5 的 Xray 服务端配置、Reality 密钥对解析与客户端节点
│   ├── cf-transform-rule.sh     # Cloudflare Request Header Transform Rule 单规则生命周期（模式 5）
│   ├── caddy-core.sh            # 锁定 Caddy 版本、官方归档与 SHA512 清单校验
│   ├── caddy-runtime.sh         # Caddyfile、订阅路由、单 443 合一/伪装站路由、服务与重载
│   ├── camouflage.sh            # Reality 伪装站四原型随机变异生成与受管清单回收
│   ├── firewall.sh              # UFW 规则配置与状态快照
│   ├── probe-log.sh             # 直连 443 探测日志的规则/unit/drop-in 生命周期与 hellogfw 入口
│   ├── subscription-auth.sh     # 订阅凭据、UA/flag/os/node 协商与产物发布事务
│   ├── local-aggregation.sh     # 本地聚合节点校验与渲染（全模式共用）
│   ├── scheduled-maintenance.sh # 定时重启与维护任务
│   ├── tcp-tuning.sh            # Skyline Speeder 与 Zabbly 6.12+ LTS 内核管理
│   └── mihomo-template.sh       # Mihomo 订阅模板结构校验与渲染
├── templates/                   # 内置订阅模板、Reality 伪装原型与聚合示例
│   ├── mihomo.yaml              # 默认 COMMON 精简规则模板
│   ├── mihomo-common.yaml       # 完整 COMMON 规则模板
│   ├── mihomo-classic.yaml      # 经典 MRS 规则集模板
│   ├── singbox.json             # sing-box 客户端订阅 JSON 模板（fakeip 与分流骨架）
│   ├── camouflage-login.html    # 模式 3/4 伪装站原型：工作台登录页
│   ├── camouflage-status.html   # 模式 3/4 伪装站原型：系统状态页
│   ├── camouflage-docs.html     # 模式 3/4 伪装站原型：开发者文档页
│   ├── camouflage-studio.html   # 模式 3/4 伪装站原型：基础设施/工作室主页
│   └── aggregation.example.json # 聚合节点（三类）配置示例
└── scripts/                     # 辅助构建与系统初始化脚本
    ├── debian-init.sh           # 独立系统初始化加固工具（Debian 12/13、Ubuntu 22.04/24.04/26.04）
    ├── hellogfw.py              # `easy_all hellogfw` 的离线/在线日志启发式分析（纯标准库，按 0644 安装）
    ├── verify-live.sh           # 真核心 CDN→WS / 模式 5 Xray XHTTP 链路门禁（`npm run test:live`）
    ├── verify-linux-metering.sh # Linux 内核 mangle 计量门禁（`npm run test:metering`）
    └── verify-cores.sh          # 真核心校验入口（`npm run test:cores`）
```

### 5.1 模式库的模块边界
- **Profile 只声明、不复制**：`CDN_PROFILE_KEY`、`CDN_EXPECTED_PROTOCOL`、`CDN_MODE_LABEL`、`CDN_ENTRY_SUMMARY`、`CDN_INSTALL_PORTS`，`BACKEND`（模式 2/3/4 为 `sing-box`，模式 1/5 为 `xray`），以及同名直连钩子（模式 1/2 返回空值）。
- **模式库持有本模式契约**：AWS 常量（`us-east-1`、缓存/源站请求策略 ID、回源时限、头名、分发 Comment）、Cloudflare 常量（来源白名单注释、Origin CA、Origin Rule / Transform Rule phase）、状态白名单与校验、本机 UFW、订阅渲染、运维事务、熔断重建、安装与卸载。`reality-cloudflare-mode.sh` 通过 `runtime_uses_xray` 按后端分派模式 4 与模式 5。
- **共享运行时保持中立**：`runtime-core.sh` 提供后端分派、证书事务（DNS-01 签发、hook、部署与验收）、订阅发布与验收（模式 2/3/4 发布八份产物，模式 1/5 跳过 JSON 仅发布六份；流控门禁只用六份 Mihomo/Base64）、核心事务与停机清理；它不持有任何云 Provider 语义。
- **渲染与路由分离**：`singbox-runtime.sh`（模式 2/3/4）与 `xray-runtime.sh`（模式 1/5）各自产出对应核心的 JSON 配置与客户端节点；`caddy-runtime.sh` 只产出 Caddyfile（站点主机与端口由模式派生）并负责 reload。两者都用「候选文件 → 校验 → `0600` 同目录原子 rename」发布。
- **橙云核心并列而非抽象**：`cloudflare-mode.sh`、`reality-cloudflare-mode.sh` 与 `cloudfront-mode.sh` 各自持有 Provider 语义，共用 `cf-dns.sh` 的 Cloudflare API 层与同一套 Profile 钩子契约。每个进程只加载所选链路的 Profile 与核心，因此同名生命周期函数（`load_state`、`apply_easy_all`、`install_all` 等）不会冲突；不引入跨 Provider 抽象层。

---

## 6. 证书、核心下载与运行时目录

### 6.1 证书双路径
- **公信证书（Certbot DNS-01）**：经发行版 Certbot + Cloudflare DNS 插件签发，凭据 `dns_cloudflare_api_token` 以 `0600` 保存在 `/etc/easy_all/cloudflare.ini` 供定时续期，全程经 API 验证域名所有权（公网仅使用业务端口）。
  - **模式 2/3（单 lineage）**：使用 `easy_all`（`/etc/letsencrypt/live/easy_all` → `/etc/easy_all/certs/fullchain.pem`、`private.key`），模式 2 覆盖 `origin`，模式 3 覆盖 `direct/origin`（同域去重）。
  - **模式 4/5（双 lineage SAN 隔离）**：维护两套独立 Certbot DNS-01 lineage，共用同一份 `/etc/easy_all/cloudflare.ini`（**无需额外 Cloudflare Token 权限**）：
    1. 主 lineage `easy_all`（`/etc/letsencrypt/live/easy_all` → `CERT_FILE` `/etc/easy_all/certs/fullchain.pem`、`KEY_FILE` `/etc/easy_all/certs/private.key`）**仅**覆盖 `DIRECT_DOMAIN`（供 `443` 直连与模式 4/5 的 `9443` 伪装站，防止直连握手 SAN 泄露橙云节点域名）；
    2. 独立回源 lineage `easy_all-cdn`（`/etc/letsencrypt/live/easy_all-cdn` → `CDN_CERT_FILE` `/etc/easy_all/certs/cdn-fullchain.pem`、`CDN_KEY_FILE` `/etc/easy_all/certs/cdn-private.key`）**仅**覆盖 `CF_NODE_DOMAIN`（模式 4 供 `8443` 橙云回源，模式 5 供 `127.0.0.1:9443` 的橙云回源站点并配合全局 `default_sni`）。
    - 签发与续签均以 `certificate_covers_exact_hosts` 校验精确 SAN 集合；从 v5.5.0 旧版合并 SAN 证书升级时，执行 `sudo easy_all renew-cert`（或 `apply-cloud`）会自动对仍含串域 SAN 的旧 lineage 追加 `--force-renewal` 重签拆分，拆分前仅运行 `apply` 时 `8443` 会平滑回退沿用旧 `CERT_FILE` 并输出提示。
- **两条部署路径**：
  1. 安装、`renew-cert`、`apply-cloud` 已持 runtime 写锁：只对本次 Certbot 子进程设置 `EASY_ALL_CERTBOT_SKIP_DEPLOY=1`，自有 hook 立即退出，由父进程在当前事务里部署。
  2. 定时 hook（`/etc/letsencrypt/renewal-hooks/deploy/easy_all.sh` → `easy_all internal-cert-deploy`）：自行取得 runtime 锁，按 `RENEWED_LINEAGE` 识别属于本工具的主 lineage（`easy_all` → `certificate_deploy`）或橙云回源 lineage（`easy_all-cdn` → `certificate_deploy_cdn`，非双证模式拒绝），只部署已签发证书，不再次签发；有界等待，失败非零并保留 lineage。
- **部署验收**：检查 SAN、有效期、公私钥匹配与完整信任链后才替换目标证书与私钥（主证书或橙云回源证书）；随后重启代理核心（`sing-box` / `xray`）并**强制** Caddy reload（`--force`，因为证书是同路径替换、配置内容不变），再用 `runtime_served_certificate_endpoints` 对各端口分别执行本机 TLS 握手比对各自磁盘指纹（直连 `443` 比对 `CERT_FILE`，Caddy 站点比对 `caddy_origin_cert_file`）。任一步失败恢复旧部署副本并保留新 lineage。
- **模式 1** 使用 Cloudflare Origin CA（ECDSA P-256、5475 天），`renew-cert` 先签发部署、本机 TLS 验收通过才吊销旧证书；`renew-cert` 从不操作 ACM 自动续期。
- **模式 2/3 的 ACM viewer 证书**由 AWS 自动续期，本工具只负责申请、复用与删除：只复用 `ISSUED` 且 SAN 覆盖节点域名的证书；处于 `FAILED`/`VALIDATION_TIMED_OUT`/`REVOKED`/`EXPIRED` 等终态时立即失败并点名 ARN（`RequestCertificate` 的幂等 Token 只会取回同一张证书，只能到控制台删除后重试）；删除分发后 `InUseBy` 需要时间收敛，按 60×10 秒有界退避重试后再按归属口径保留（卸载路径的 `ACM_IN_USE_WAIT_ATTEMPTS` / `ACM_IN_USE_WAIT_SECONDS`）。

### 6.2 核心下载与 `update-core`
- sing-box 与 Caddy 保持锁定版本：sing-box `1.14.4`（规避不兼容配置变更；代码内审查过的 SHA256 常量，无官方 checksums 清单可用）、Caddy `2.11.9`（读取官方 `caddy_2.11.9_checksums.txt` 中精确文件名的 SHA512 条目）；**Xray-core 追踪最新官方 Release**（通过 GitHub `/releases/latest` 302 跳转解析正式版标签，再从同一版本路径下载 `<asset>.dgst` 与归档，校验 `SHA2-256` 条目与候选二进制版本号后原子安装）。
- 一律只通过 HTTPS 下载，先校验摘要再解压、再跑候选版本/配置检查，最后同目录原子替换；失败保留旧二进制与旧配置。darwin 归档只用于开发验证。
- `update-core` 没有新增参数，含义是**sing-box/Caddy 重装或修复锁定版本，Xray 更新到最新官方 Release**：更新前备份现存二进制与运行配置（模式 1/5 备份 `xray` 与 `XRAY_CONFIG`，模式 2/3/4 备份 `sing-box` 与 `SINGBOX_CONFIG`，两者都备份 Caddy），下载校验失败或候选验收失败即恢复旧版本；二进制已缺失时按修复处理（没有可回滚的旧版本）；保护待落实时直接拒绝；检测到旧版 sing-box 残留且缺 Xray 核心时将拒绝换核并提示先重装。
- 发布顺序固定为「写单元 → `systemctl daemon-reload` → 启停服务」：不重新加载时 systemd 继续使用内存里的旧单元，新增的 `ExecStartPre` 计量守卫会被静默跳过。替换 Caddy 二进制后必须**重启** Caddy 进程——`reload` 只在现有进程内换配置，不会执行磁盘上的新二进制。

### 6.3 `/run` 目录与两把锁
- 计量目录 `/run/easy_all` 在打开锁前显式创建（root `0700`，锁文件 `0600`）；sing-box 的 `RuntimeDirectory` 生命周期不回收这个共享目录，停启服务不 unlink counter 锁，避免 timer 与启动进程锁到不同 inode。目录或锁准备失败即拒绝启动。
- Caddy 单元使用 `RuntimeDirectory=easy_all-caddy`、`RuntimeDirectoryMode=0700`，管理套接字固定在 `/run/easy_all-caddy/admin.sock`，`caddy reload` 仅经由该 Unix 套接字通信。
- 运行时写锁覆盖配置/state/模板/订阅/服务变更；counter 锁覆盖规则、usage、epoch 与基线。唯一嵌套顺序为 **runtime → counter**，反序等待会把启动准备与 timer 采样卷成死锁（预算见 §4.4）。
