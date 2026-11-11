# 运维与排障指南

本文档介绍 `easy_all` 安装完成后的日常维护、配置应用、订阅管理、CDN 流量保护运维、卸载清理及常见故障排查。

安装菜单有五个模式：**1 AnyTLS 直连**、**2 纯 CloudFront**、**3 纯 CloudFlare（单域名）**、**4 AnyTLS + CloudFront**、**5 AnyTLS + CloudFlare**。所有模式共用同一套本机运行时（官方 sing-box 提供节点入站，官方 Caddy 提供订阅与 CDN 回源站点），本机节点与全部订阅入口统一使用 `443`。下文标注「模式 2/4」的命令只适用于 CloudFront 链路（含 985 GB 计量保护），标注「模式 1/3/5」的只适用于 AnyTLS / Cloudflare 橙云链路（没有该计量保护）。

---

## 1. 软件更新与配置应用

### 1.1 更新 easy_all 脚本
```bash
sudo easy_all self-update
```
- `self-update` 仅从 GitHub 拉取并替换安装器自身的代码，不会擅自重启服务、应用配置或修改云端资源；脚本显式经由系统 Bash 执行，兼容 `/tmp` 挂载有 `noexec` 安全标志的加固系统。
- 默认跟随 `main` 分支；若需测试开发版可加 `--dev` 参数（或 `--branch <分支>`）。
- 覆盖代码前会先拒绝 `STATE_VERSION` 不是 `1` 的状态与安装标记：4.x（schema 0）安装不能接管，必须先卸载重装，见 [§7.4](#74-旧版本状态与不完整新状态只能卸载重装)。

### 1.2 `apply`：纯本机重建配置
当脚本更新后需要重新渲染运行时，或需要刷新 sing-box / Caddy / 订阅文件：
```bash
sudo easy_all apply
```
- 五种模式都**只在本机重建**：重新渲染并应用 sing-box 配置（含 CDN 阻断状态）、Caddyfile（站点主机与端口由模式派生）、UFW 业务端口与八个订阅产物（六份 Mihomo/Base64 + `singbox.json` / `singbox-all.json`），并重建服务。
- **不访问云管理 API，不签发或续签证书，不改 DNS**。唯一的外部访问是读取公开的 Cloudflare 官方回源 IPv4 段与 Origin CA 根证书（模式 1/3 需要），不需要账号凭据。
- 模式 1 的 `link` 不部署订阅站点，`apply` 只重建 AnyTLS 入站与节点输出，提示 `Caddy: 未部署（link）`。
- 保护待落实（`blocked=true` 且 `enforced=false`）时先做[受限安全恢复](#63-各命令在保护停机时的准入)，恢复失败直接非零停止，不会带着开放配置启动 sing-box。
- 订阅配置损坏时普通 `apply` 会失败并提示 `sudo easy_all edit-sub`，不会静默把聚合节点清空。
- 证书缺失或异常（`status` 显示「证书异常/缺失」）应执行 `sudo easy_all renew-cert`；ACM 证书或 CloudFront 分发需要重建时用 `apply-cloud`。
- 订阅发布验收同时覆盖六份旧产物与 sing-box JSON：JSON 候选结构或 `sing-box check` 失败会让整次发布失败并保留旧订阅，不会留下半份 JSON。首装、`apply`、`apply-cloud`、`edit-sub` 在写入后都会做一次本机 HTTP 验收（`flag=singbox`、SFA UA 自动识别、显式 flag 覆盖、`node=all`、HEAD 与裸文件 `404`）。
- **升级后要执行一次 `apply` 才会出现 JSON**：`self-update` 只替换代码，不重建 Caddyfile 与订阅。执行 `apply` 之前，线上仍是旧 Caddyfile（没有 JSON 分支），`flag=singbox` 与 SFA UA 会按旧规则回落到 Base64 订阅（`200`，客户端会导入一份平铺列表）；只有 Caddy 配置已更新（`apply` 已写入）而 JSON 产物缺失时才返回 `503`。两种情况都不影响原有的 YAML 客户端；`sudo easy_all subscription` 在缺少 JSON 产物时会提示先执行 `apply`。
- **JSON 故障不影响 CDN 流量保护**：定时计量与 `cdn-traffic-sync` 只使用原来的六产物门禁，JSON 缺失或损坏不会放开或封锁 CDN，也不会清零用量；修复方式是运行 `sudo easy_all apply`。

### 1.3 `apply-cloud`：同步云端资源
改过域名、换了凭据或需要重新收敛云端资源时：
```bash
sudo easy_all apply-cloud
```

**模式 1（AnyTLS）**：读取 Token（优先复用 `/etc/easy_all/cloudflare.token`）→ 只读查询 Zone ID → `deploy` 时校验 Zone SSL 为 `Full (strict)` → 收敛直连灰云 `A` 记录（`deploy` 另加订阅橙云 `A`）→ 以 `0600` 写入 DNS-01 凭据并签发/复用 Let's Encrypt 证书 → `deploy` 再收敛精确 `http.host` 的 Origin Rule（回源 `8443`）→ 本机重建与公网验收。`link` 不建订阅站点、不建 Origin Rule。

**模式 3（Cloudflare 橙云）**：读取 Token → 只读查询 Zone ID 并校验 `Full (strict)` → 收敛橙云节点 `A` 记录 → 复用或签发 Origin CA 证书（只覆盖节点域名）→ 本机重建、严格本机验收 → 公网验收（health、订阅、无效 Token 拒绝）→ 核对本机 TLS 实际送达的证书指纹 → 落盘状态后吊销旧证书。失败时本机回滚、云端 DNS 与已签发证书保留并打印清单；修正后重跑即可收敛。

**模式 5（AnyTLS + CloudFlare）**：读取 Token → 只读查询 Zone ID 并校验 `Full (strict)` → 收敛直连灰云 `A` 与橙云节点 `A`（同一域名承载节点与订阅）→ 以 `0600` 写入 DNS-01 凭据并签发/复用覆盖直连与节点域名的 Let's Encrypt 证书 → 收敛精确 `http.host` 的 Origin Rule（回源 `8443`）→ 本机重建、严格本机验收 → 公网验收（health、订阅、两个节点标记与无效 Token 拒绝）。失败时本机回滚，云端 DNS、证书与 Origin Rule 保留并打印清单；修正后重跑即可收敛。

**模式 2/4（CloudFront）**：一次执行会按固定顺序完成：

1. 读取 Cloudflare API Token（优先复用 `/etc/easy_all/cloudflare.token`，否则隐藏输入后原子写入 `0600`），以及 AWS 凭据（仅当前进程内存）。
2. 保守同步灰云 DNS 的源站（及模式 4 直连）`A` → VPS 公网 IPv4；同名第三方/多条冲突记录不会被抢占。
3. 复用或续签**源站 Let's Encrypt 证书**（Cloudflare DNS-01，不开放 `80`）。
4. 复用或申请 **AWS ACM 证书**（固定 `us-east-1`，SAN 覆盖节点域名；订阅同域，去重后只有一项；旧装保留原两项 SAN），自动写入 DNS validation `CNAME` 并等待 `ISSUED`。
5. 创建或更新 **CloudFront 分发**（`Comment=easy_all-cloudfront-<节点域名>`，源站 `HTTPSPort` 模式 2 为 `443`、模式 4 为 `8443`），等待 `Status=Deployed`。
6. 收敛节点（同时承载订阅；旧装含独立订阅域名）`CNAME` → 分发域名，然后执行 §1.2 的本机重建、严格本机验收与公网验收。

- 失败时：**本机配置回滚，云端资源保留**并输出分发 ID 与 ACM ARN；修正后再次 `apply-cloud` 收敛，必要时到控制台处置。不会因为一次 API 查询失败就再创建一个重复分发，也不会用自签证书顶替失败的 Let's Encrypt。
- 云端与本机不是跨云事务：部分云端变更成功、本机失败是允许的结果，重跑同一条命令即可收敛。

---

## 2. 常用管理命令速查表

| 命令 | 说明 |
| :--- | :--- |
| `sudo easy_all install` | 交互选择 1 AnyTLS 直连 / 2 纯 CloudFront / 3 纯 CloudFlare / 4 AnyTLS + CloudFront / 5 AnyTLS + CloudFlare 并安装 |
| `sudo easy_all show` | 打印当前节点参数（AnyTLS / VLESS WebSocket 链接与 Mihomo YAML 片段） |
| `sudo easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `sudo easy_all self-update` | 从 GitHub 更新 easy_all 脚本体（`--dev` 使用开发分支） |
| `sudo easy_all apply` | 应用已安装配置；只重建本机与订阅，不访问云管理 API |
| `sudo easy_all apply-cloud` | 同步云端资源：模式 1 是直连/订阅 DNS、证书与 Origin Rule；模式 2/4 是 DNS + ACM + CloudFront 分发 + 源站证书；模式 3 是橙云 A 记录与 Origin CA 证书；模式 5 是直连/橙云 A 记录、证书与 Origin Rule |
| `sudo easy_all edit-sub` | 交互式编辑订阅配置（用户 Token + 聚合节点）与订阅模板 |
| `sudo easy_all cdn-traffic-sync` | （仅模式 2/4）采样 mangle 计量并落实流量阻断；其他模式会明确拒绝 |
| `sudo easy_all purge-cloudflare` | 清理 easy_all 创建的 Cloudflare 远端资源（可在未安装或状态丢失时使用） |
| `sudo easy_all update-core` | 重装/修复当前锁定版本的核心（sing-box 1.14.4 + Caddy 2.11.9），不追最新 |
| `sudo easy_all renew-cert` | 重新签发 / 部署当前模式的 TLS 证书（模式 3 轮换 Cloudflare Origin CA；其他证书模式走 Certbot） |
| `sudo easy_all status` | 查看模式、域名、分发/ACM（模式 2/4）、Origin CA（模式 3）或 Origin Rule（模式 5）、服务与监听、证书、CDN 计量规则与 985 GB 保护状态（仅模式 2/4） |
| `sudo easy_all cleanup-partial` | 清理安装中断留下的本机残留（未安装状态使用；不改云端资源） |
| `sudo easy_all uninstall` | 卸载当前模式的本机内容，并清理本工具创建的云端资源 |
| `sudo easy_all help` | 显示帮助 |

> `apply`、`edit-sub` 都不调用云管理 API，需要改云端时用 `apply-cloud`。`renew-cert` 在模式 1/2/4/5 走 Cloudflare DNS-01，在模式 3 轮换 Origin CA，都不操作 ACM 自动续期。
> 已删除的命令：`reality-target`（Reality 伪装目标）、`rotate-dynamic-ports`（动态端口轮换）；本版本没有这两条路径的替代参数。

---

## 3. TCP 加速（Skyline Speeder）

- amd64 与 arm64 平台安装时前置配置并启用 [Skyline Speeder](https://github.com/CYBERVERSE-Research/skyline-speeder)；不再提供 BBR/XanMod 方案。
- **内核要求**：Skyline 要求 Linux 6.12+。若系统内核较低，安装器会自动升级 Zabbly 6.12+ LTS 内核。
- **状态确认**：
  - 安装后若提示重启，执行 `sudo reboot`；
  - 重启后运行 `sudo easy_all status`，显示 `Skyline Speeder: active` 即表示已成功加速。
  - 若显示 `degraded`，说明 Skyline 未生效（拥塞控制回落到内核默认值），网络连接不受影响。执行 `sudo easy_all apply` 可尝试修复；修复后仍会校验 `skyline_cc` 是否真的生效。

---

## 4. 节点、服务与证书管理

### 4.1 服务单元与重启
| 单元 | 作用 |
| :--- | :--- |
| `easy_all-singbox.service` | 节点入站：AnyTLS `0.0.0.0:443`、VLESS WebSocket `127.0.0.1:10086`。模式 2/4 的 `ExecStartPre` 是 `easy_all internal-traffic-prepare`，先校验计量规则与保护状态，失败则拒绝启动 |
| `easy_all-caddy.service` | 订阅站点与 CDN 回源站点（模式 1 `deploy` 与模式 5 在 `8443`，模式 2/3 在 `443`，模式 4 在 `8443`）；管理套接字只在 `/run/easy_all-caddy/admin.sock`，不暴露 TCP 管理端口 |
| `easy_all-cdn-traffic-guard.timer` / `.service` | （仅模式 2/4）每 15 秒采样 mangle 计量并落实阻断 |

- 手工重启核心：`sudo systemctl restart easy_all-singbox`（模式 2/4 会先跑计量准备）。Caddy 请用 `sudo easy_all apply` 重建，不要直接 `systemctl restart`，否则会跳过配置校验与订阅验收。
- 日志：`sudo journalctl -u easy_all-singbox -u easy_all-caddy -u easy_all-cdn-traffic-guard`。
- `/etc/easy_all`（state、证书、Caddyfile、sing-box 配置、订阅、模板快照）与 `/var/www/easy_all/subscriptions`（八份产物：六份 Mihomo/Base64 + `singbox.json` / `singbox-all.json`）都是受管文件，手工编辑会在下一次 `apply` 被覆盖；请用命令修改。

### 4.2 节点域名与节点名（需要重装）
五种模式的本机域名与节点名都是落盘状态的一部分，没有「只改名」的入口：改直连域名、CDN 节点域名或节点名都需要 `sudo easy_all uninstall` 后重新安装，并在客户端重新导入订阅。新装模式 4 的源站域名由直连域名派生、新装模式 2/4 的订阅域名由节点域名派生，因此这两项没有单独的改名入口。

### 4.3 凭据轮换
- 本版本**没有**独立的密码 / UUID / 路径轮换命令：AnyTLS 密码、VLESS UUID、VLESS 路径都在安装时生成并落盘，重装会生成全新的一组，客户端必须重新导入订阅。
- 订阅侧的用户 Token 用 `sudo easy_all edit-sub` 增删：被删 Token 立即失效，新增 Token 在发布验收通过后可用；失败会恢复旧 state、模板、产物与 Caddy 鉴权配置。

### 4.4 CDN 单节点名称（模式 2/3/4/5）
四种 CDN 模式的本机 CDN 节点都只有一个，名称由安装时输入的节点名决定（模式 2/4 默认 `🇺🇸AWS`，模式 3/5 默认 `🇺🇸CF`；1–64 个字符，不得使用 `PROXY`、`GLOBAL`、`AUTO`、`CDN-AUTO`、`CDN-FALLBACK` 等保留名，也不得与直连节点或聚合节点重名）。它不会自动追加序号，也没有额外的测速/兜底节点（模式 4 的 `AUTO`/`CDN-FALLBACK` 是自动组，不是额外节点）。改名需要重新安装并重新导入订阅。

### 4.5 Cloudflare Origin CA 证书（模式 3）
```bash
sudo easy_all renew-cert
```
强制轮换 Origin CA 证书：先签发并部署新证书，通过本机严格 TLS/SNI 验收并用真实握手核对磁盘证书指纹后，才吊销旧证书；任一步失败都保留旧证书并恢复本机配置。证书是 15 年有效期的 Cloudflare 私有 CA 证书，只覆盖节点域名。

模式 1/2/4/5 不使用 Origin CA：`renew-cert` 走 Cloudflare DNS-01 重新签发 Let's Encrypt 证书（模式 4 新装只覆盖直连域名（源站同域；旧装另含源站域名）；模式 5 的 SAN 同时覆盖直连域名与橙云节点域名），同样先通过本机 TLS 指纹验收再替换。

---

## 5. 订阅与多用户管理

需要订阅入口的链路（模式 1 `deploy`、模式 2/4、模式 3/5）共用同一份订阅配置：
```bash
sudo easy_all edit-sub
```

- **订阅配置**：按提示输入一份 JSON，同时包含 `allowedTokens`（用户 Token 字典）与 `nodes`（聚合节点数组）。省略的用户或节点会被删除；完成后各用户的专属订阅链接可通过 `sudo easy_all subscription` 查看。
- **订阅入口**：Caddy 只精确匹配 `/subscribe` 与 `/sub`，两者进入同一处理器；`/subscribe/`、`/subscribed` 与其他路径返回 `404`。重复 `token` 参数会被 Caddy 逗号拼接，无法匹配合法 Token，一律 `403`。
- **聚合节点**：`nodes` 支持三种类型——`vless` + `reality/tcp`、`vless` + `tls/xhttp`、`mieru`；示例见 `templates/aggregation.example.json`。`optional: true` 的节点仅在订阅 URL 追加 `&node=all` 时下发。外部聚合节点的 `host/port/portRange` 原样保留，不会被改写成 443；`tls/xhttp` 节点的 `host` 是客户端连接地址，`sni` 同时作为 TLS SNI 与 HTTP `Host` 头；`reality/tcp` 节点的 `sid` 需为 2–16 位偶数长度十六进制。
- **自定义模板**：支持交互式切换或重载 Mihomo 订阅模板（也可用 `MIHOMO_TEMPLATE_SOURCE` 传入本地文件或 HTTPS URL）。选中的模板会以 `0600` 快照保存在 `/etc/easy_all/mihomo-template.yaml`，后续 `apply`、`edit-sub` 与重装后的发布沿用同一份快照；快照缺失会告警并回退内置默认模板。
- **失败回滚**：订阅配置校验、发布或验收任一步失败都会恢复旧的订阅状态、模板与全部订阅产物（快照按整目录复制）。

### 5.1 保护停机时的 `edit-sub`
当 CDN 用量达到阈值且阻断尚未落实（`blocked=true`、`enforced=false`）时，`edit-sub` 仍可执行，但走**保持阻断**的修复分支：

1. 先把 Caddy 代理路径收敛为 `503` 并停掉当前核心（旧 CDN 长连接随之终止）；这一步失败即停止，不进入订阅修复。
2. 在安全边界确立后接收新的完整订阅配置，只更新订阅相关状态、模板与全部订阅产物。
3. 随后以**受限配置**（省略 CDN 入站；模式 4 保留 AnyTLS `443`）重建运行时并验收订阅就绪；不采样、不改写用量文件、不解封。
4. 成功返回 0 只表示「订阅修复完成，保护仍 pending」，输出 `blocked` / `enforced` / `protection_offline` 原值，并提示执行 `sudo easy_all cdn-traffic-sync`。

修复失败会保留已生效的 `503` 与受限运行时，只回滚订阅对象，不会恢复旧的开放配置。

---

## 6. CDN 流量保护（985 GB 熔断）运维（仅模式 2/4）

### 6.1 工作原理
1. 计量在 `mangle` 表用链首无 target 的纯计数规则完成：`INPUT` 匹配 `lo` + `127.0.0.1` + TCP `10086` 计上行，`OUTPUT` 同条件计下行。模式 4 的 AnyTLS 直连与订阅下载都不经过 `10086`，因此不计入。
2. systemd 定时器 `easy_all-cdn-traffic-guard.timer`（`OnBootSec=15s`、`OnUnitActiveSec=15s`）每 15 秒执行一次 `easy_all cdn-traffic-sync`。
3. 累计用量原子写入 `/etc/easy_all/cdn-traffic-usage.json`（`0600`），字段为 `period` / `runtime_id` / `used_bytes` / `last_uplink` / `last_downlink` / `blocked` / `enforced` / `protection_offline`。
4. 阈值固定为 **985×10⁹ 字节（十进制 985 GB）**；月度按 **UTC 自然月** 划分，`period` 形如 `2026-11`。`runtime_id` 是包含 `boot_id` 的计数 epoch：重启或规则重建会重采样基线并保留累计，月切换才重置 `used_bytes`。
5. 触发阻断时先让 Caddy 的代理路径返回 `503`，再由 sing-box 省略 CDN 入站并重启以终止已建立的 CDN 长连接。模式 4 的 AnyTLS 直连会短暂重连但继续可用；订阅链接仍可下载，节点不会被从订阅里删除。
6. `blocked` 是期望的限额状态，`enforced` 是最后完成验收的应用状态；两者不一致即为「待落实」（pending），`protection_offline=true` 表示保护性停机意图已持久化（核心已停止或即将停止），它不表示允许解封。
7. 计数读取失败、usage 损坏或规则修复失败一律拒绝放行；计量规则缺失时不会开放 CDN，也不会清零历史用量。

### 6.2 `status` 解读
```bash
sudo easy_all status
# CloudFront 全局费用保护: enabled（UTC 自然月 2026-11，阈值 985 GB）
#   已统计: 12.345 GB，剩余保护空间: 972.655 GB，blocked=false，enforced=false，protection_offline=false
```
- `CloudFront 全局费用保护: 异常（统计文件缺失或损坏：/etc/easy_all/cdn-traffic-usage.json）`：不要手工删文件或清零，先停用 CDN 入口再修复；命令不会自动重建或清零已安装用量。
- `CDN 计量规则: 缺失或损坏`：规则或 counter 锁不可用时同样拒绝放行，按 §6.4 顺序收敛。
- `保护性停机: 是`：运行时受限或已停止，等待 `cdn-traffic-sync` 收敛（订阅已不可用时还会额外提示 `edit-sub`）。
- `CDN 流量保护定时器: inactive`：保护已失效，先修复定时器（`sudo easy_all apply` 会重装并校验其为 active）再使用 CDN。

### 6.3 各命令在保护停机时的准入

| 入口 | 待落实阻断（`blocked=true`、`enforced=false`）时的行为 |
| :--- | :--- |
| `cdn-traffic-sync`（timer 同源） | 先做受限安全恢复（`503` + 受限核心可启动、计量规则与 usage 可读），验收通过才采样、才可能解封；失败保留 pending 并返回 1 |
| `apply` / `apply-cloud` | 先做同一受限安全恢复，成功后再强校验订阅并继续本机（或云端）事务；重启前紧贴一次 checkpoint，若产生新的待落实状态则停止并提示先 `cdn-traffic-sync` |
| `renew-cert` | 先只验证/部署证书并保持 `503`（不动核心），证书阶段完成后才做受限恢复；源站证书故障优先用它修复 |
| `edit-sub` | 走 §5.1 的保持阻断修复分支（受限运行时，不改用量、不解封） |
| `update-core` | 先非零拒绝（不下载、不替换、不重启），提示先 `cdn-traffic-sync`（订阅损坏先 `edit-sub`，证书故障先 `renew-cert`） |
| `status` / `show` / `subscription` | 只读，不清算、不启动服务 |
| `uninstall` | 不需要统计文件可读，照常卸载 |
| 定时重启 | 任务入口为 `easy_all internal-scheduled-reboot`（原语义不变：前置 `cdn-traffic-sync` 非零即不重启；取锁后再只读复核 usage（结构合法、`protection_offline=false` 且 `blocked=enforced`），不满足则跳过重启并告警） |

### 6.4 故障后的收敛顺序
1. 证书导致受限启动失败：`sudo easy_all renew-cert`。
2. 订阅配置/产物损坏：`sudo easy_all edit-sub`。
3. 其余情况：`sudo easy_all cdn-traffic-sync`（或等下一轮 15 秒 timer 自动收敛）。

反复失败时 `journalctl -u easy_all-cdn-traffic-guard.service` 会给出阶段与原因；持续失败的机器会保持阻断与停机，不会自动解封，也不会把错误当作「额度已恢复」。开机时 `easy_all-singbox.service` 的 `ExecStartPre` 同样会校验计量与保护状态，规则缺失或 usage 损坏会拒绝启动；持续失败由 `StartLimitBurst=3`（120 秒窗口）有界终止，修复后显式 `sudo easy_all apply` 恢复。

### 6.5 不要做的事
- 不要手工编辑或删除 `/etc/easy_all/cdn-traffic-usage.json` 来「恢复」CDN：缺失或损坏会被判为保护异常并拒绝操作。
- 不要指望 `apply`、`apply-cloud` 或 `update-core` 绕过阻断：它们同样受同一准入约束。
- 本机计数是**近似保护**，不是 AWS 账单真源：订阅下载、HTTP/TLS 开销与请求费、其他分发或其他机器的用量不在统计内，进程崩溃/关机窗口也可能漏计，因此不承诺零账单。

---

## 7. 卸载与清理

### 7.1 卸载本机与云端资源
```bash
sudo easy_all uninstall
```
`uninstall` 不接受参数：它固定先尝试清理本工具创建的云端资源，再清理本机内容。旧脚本里的 `uninstall --purge-cloud` 已删除，请直接执行 `sudo easy_all uninstall`。

停止并删除 sing-box、Caddy 服务与 easy_all 自有配置、证书（含 easy_all 专用的 Certbot lineage 与 deploy hook）、CDN 流量保护定时器与计量规则、定时任务，回收业务端口放行与 Cloudflare 回源白名单，保留 UFW 启用状态、默认拒绝策略、SSH 放行与 Fail2ban 配置（`/usr/local/sbin/fail2ban-ufw-cidr.sh` 脚本保留），恢复安装前的 IPv6 配置。模式 1 `deploy`/模式 3 还会回收各自的回源放行注释（`easy_all-cf-origin-8443` / `easy_all-cf-origin-443`）；模式 1 `deploy` 与模式 5 的 Origin Rule 默认随卸载清理。

- **默认清理云端资源**：先打印一次资源清单（模式 1：直连/订阅 A 记录、Origin Rule ID；模式 2/4：分发 ID/域名、ACM ARN、源站 A 记录、节点/订阅 CNAME、validation CNAME（模式 4 另含直连 A 记录）；模式 3：橙云 A 记录与 Origin CA 证书 ID/到期时间），再按 §7.2 的顺序尝试删除；因归属保护而未删除的条目会逐条点名。
- **云端清理失败会告警且命令以非零退出，本机卸载照常完成**：本机状态删除后无法再按本次安装状态重试清理，请保存输出中的清单并人工处置残留。
- 前置初始化不回收：Zabbly 内核与 APT 仓库、Skyline Speeder 及其 fq 服务、`/etc/sysctl.d/99-easy_all-tcp.conf`、1GB Swap 与系统依赖均保留。
- **旧版 fq helper 迁移**：`self-update` 只替换代码，不会刷新已生成的 `/usr/local/lib/easy_all-tcp` helper（其 qdisc 快照不再写进 `/etc/easy_all`）。存量机器建议按 `sudo easy_all self-update` → `sudo easy_all apply` → `sudo easy_all uninstall` 操作；如果旧 helper 只留下「`backups/qdisc` 空目录」的严格空链，新版安装守卫会放行，不必手工删目录。
- 保护停机（`protection_offline=true`、核心已停止）不阻挡卸载，也不要求统计文件可读。

### 7.2 云端清理顺序与安全例外
在 §7.1 的本机卸载之前，先尝试清理 easy_all 自己创建的云端资源。

**模式 1（AnyTLS）**：只删除注释、类型与目标（VPS 公网 IPv4）都匹配的直连/订阅 `A` 记录，并按持久 ID 删除本工具的 Origin Rule（不删除共享 ruleset 中他人的规则）；失败只告警并打印残留。

**模式 3（Cloudflare 橙云）**：只删除注释、类型与目标（VPS 公网 IPv4）三者都匹配的 `A` 记录，并按持久 ID 吊销 Origin CA 证书；DNS 查询/删除失败不阻止吊销证书，任一步失败只告警并打印残留。不猜测删除第三方记录或多条同名记录。

**模式 5（AnyTLS + Cloudflare）**：先删除直连灰云 `A` 记录与橙云节点域名 `A` 记录（注释、类型与目标三者同时匹配才删），再按持久 ID 删除本工具的 Origin Rule；不删除共享 ruleset 中他人的规则，失败只告警并打印残留。

**模式 2/4（CloudFront）**：

1. **归属校验**：CloudFront 必须同时满足 `Comment=easy_all-cloudfront-<节点域名>`、aliases 与本状态一致、ID 与状态一致；ACM 必须带 `easy_all=managed` 标记且状态/region/SAN 匹配。查询失败或归属不匹配一律保留并告警。
2. **分发**：先置 `Enabled=false`，等待部署完成，再用最新 ETag 删除。
3. **ACM**：确认 `InUseBy` 为空且带管理标记后才删除；分发删除失败时不会继续删证书。
4. **DNS**：只删注释、类型和目标都精确匹配的 A/CNAME 记录；复用第三方或无标记记录不删。
5. **ACM validation CNAME 默认保留**，输出会明确提示可由控制台核实后手工删除（同一验证记录可能被其他证书复用）。

- **云清理失败不阻挡本机卸载**：任一步失败只告警并打印残留 ID，本机卸载照常继续；命令以非零退出（沿用 `1`），交互与 `FORCE=1` 语义一致，便于自动化发现残留，也不会声称「云端已全部清理完成」。
- 缺少 AWS 凭据时会要求交互输入；仍无凭据则云端清理记为失败，本机照常卸载。

### 7.3 独立清理 Cloudflare 残留
若 VPS 已销毁或状态丢失，可使用独立命令清理账户内 easy_all 标记的 Cloudflare 资源：
```bash
sudo easy_all purge-cloudflare --domain example.com
```
- 只处理 Cloudflare，**不会触碰 AWS**；正在运行的 CDN 链路若清掉节点/订阅 DNS 会中断，需要随后 `apply-cloud` 恢复。模式 1/5 的 Origin Rule 与模式 3/5 的 `A` 记录都带有本工具注释，能被该工具识别。
- Token 需为 20–512 位 URL 安全字符（A-Z a-z 0-9 _ -）：Token 会写进 curl 的请求头文件，长度或字符集不符（含换行）一律拒绝，与 `lib/cf-dns.sh` 同一口径。
- Token 可见多个同名 active Zone 时，`--domain` 的 Zone 查询会显式报错并停止，不会猜一个：改用只授权目标 Zone 的 Token，或先在控制台处理重复 Zone。
- 支持平滑容错降级：Token 缺少 Rulesets 权限时会安全跳过规则清理并告警一次，已收集的 DNS 记录与 Cloudflare Origin CA 证书仍会正常清理。

### 7.4 旧版本状态与不完整新状态只能卸载重装
- **4.x（schema 0）安装不被接管**：`STATE_VERSION` 不是 `1` 时，`install`、`self-update`、命令注册与 bootstrap 在覆盖任何文件前就拒绝，并提示先用 4.x 的 `sudo easy_all uninstall`（需要时加 `--purge-cloud`）卸载。本版本不做自动迁移，也不保留 Xray/Nginx/Reality/动态端口/XHTTP/4.x Reality 版模式 5 的兼容实现。
- **schema 1 但字段不完整**（例如安装中途被中断、缺强制字段）的状态同样不能安全接管：只允许 `sudo easy_all uninstall` 做仅本机清理，云元数据缺归属证明时保留并告警。
- **schema 1 但协议不可识别**（`PROTOCOL` 缺失或写坏）的状态分类为 `incomplete-unknown`，同样不能安全接管：`install`、`apply`、`status` 等仍被拒绝并要求先卸载，只保留本机卸载通道——`sudo easy_all uninstall` 仍可执行，只做仅本机清理，不猜协议、不碰云端资源，云端元数据需人工核对。
- 重装会产生新的 AnyTLS 密码、VLESS UUID、路径与 Token，客户端必须重新导入订阅。不要通过手改 `state.env` 的协议值来「升级」或「回退」。

---

## 8. 常见问题排查

| 现象 / 报错 | 常见根因与解决办法 |
| :--- | :--- |
| **SSH 断开后重连失败** | - 检查服务商后台云防火墙/安全组是否已放行 SSH 端口（默认 22）。<br>- 检查 UFW 状态及 Fail2ban 是否因多次认证失败暂时封禁了客户端 IP。 |
| **重跑提示 TCP 端口被占用** | 有 easy_all 残留时按提示执行 `sudo easy_all cleanup-partial`；只报了「easy_all 仅支持专用 VPS」说明占用者是第三方进程，先确认归属再处理。 |
| **`easy_all: command not found` / 命令突然不可用** | `self-update` 在替换安装目录与命令链接之间被中断（两次相邻 `mv` 之间的窗口）。重跑 bootstrap 即可恢复运行时代码与命令链接，例如 `bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) help`；自愈要求安装状态合法可读、`/usr/local/lib/easy_all` 缺失而命令链接仍指向它、同父目录存在 `easy_all.previous.*`，任一条件不满足只提示人工处理并保留备份。它只恢复代码与链接，不改 `/etc/easy_all` 业务状态、云资源或防火墙；也不承诺崩溃期间命令始终可用。 |
| **安装中断提示「继续上次安装」** | 续装要求同一模式且安装标记、链路身份与安装前快照一致（`SCHEMA=1` + `PROTOCOL` 匹配）。回车选择 `Y` 可复用已生成的证书、分发 ID/ACM ARN（模式 2/4）、Origin CA 身份（模式 3）与 Origin Rule ID（模式 5）；模式 1（AnyTLS）不参与续装，选 `n` 或遇到模式 1 残留时清理重装。旧版标记与不匹配的残留不参与续装。 |
| **CloudFront 返回 502** | 回源失败：源站端口不可达（安全组未放行、Caddy 未运行；模式 2 是 `443`，模式 4 是 `8443`），或 CloudFront 无法校验源站证书（过期/未覆盖源站域名）。先用 `sudo easy_all status` 看证书与服务状态，再用 `sudo easy_all renew-cert`、`sudo easy_all apply-cloud` 修复。 |
| **CloudFront 返回 503** | 多半是 CDN 用量达到 985 GB 触发的阻断，或 `protection_offline` 状态下的受限运行时。查看 `sudo easy_all status` 的 `blocked` / `enforced` / `protection_offline`；按 §6.4 顺序收敛，不要清空用量文件。 |
| **CloudFront 返回 403 / 404（订阅或健康检查）** | `403` 是订阅 Token 缺失/错误或重复 `token` 参数；`404` 是路径不精确（只有 `/subscribe`、`/sub` 与 `/easy_all-health`）或源站头缺失。确认分发行为仍转发自定义头 `X-Easy-All-Origin-Key`，且没有人手工改过 Caddy 站点。 |
| **TLS 正常但节点没有流量** | 代理路径或源站头链路被打断：VLESS 路径必须精确匹配 `handle <VLESS_PATH>`，分发行为必须保留源站头、且不要改成转发 viewer Host。恢复配置执行 `sudo easy_all apply`。 |
| **客户端提示证书错误** | 分清两套证书：**viewer 侧**用 AWS ACM（`us-east-1`，SAN 覆盖节点与订阅域名），**源站侧**用 Let's Encrypt（模式 1 覆盖直连/订阅，模式 2 覆盖源站，模式 4 覆盖直连（新装源站同域；旧装另含源站域名），模式 5 覆盖直连与橙云节点）。客户端只校验 ACM / 橙云边缘 / 直连证书；源站证书错误表现为 CloudFront 502 或橙云 5xx 而不是客户端报错。不要在客户端加 `allowInsecure`/跳验证。 |
| **订阅下载失败或返回 403** | Token 失效（`edit-sub` 删掉了该用户）、URL 里重复了 `token` 参数，或订阅域名 CNAME/橙云记录未收敛。用 `sudo easy_all subscription` 取最新链接；必要时 `sudo easy_all apply-cloud` 收敛 DNS。禁止用 `-k` 或跳过验证绕过证书问题。 |
| **`apply` / `apply-cloud` 报订阅配置损坏** | 状态里的 `SUBSCRIPTION_CONFIG` 无法解析。执行 `sudo easy_all edit-sub` 粘贴完整新配置；`uninstall` 与 `cleanup-partial` 仍可执行。 |
| **`update-core` 被拒绝** | 提示「CDN 流量保护仍待落实」时先执行 `sudo easy_all cdn-traffic-sync`；订阅损坏先 `edit-sub`，证书故障先 `renew-cert`。核心更新后订阅若刷新失败，会保留告警并提示 `apply`。 |
| **`renew-cert` 后仍提示证书问题** | 检查 `/etc/letsencrypt/live/easy_all/` 是否已签发新 lineage（模式 3 则是 Cloudflare Origin CA API 是否成功）；手动续签会抑制内置 deploy hook，由命令自身完成部署、强制 Caddy reload 与本机 TLS 指纹验收。锁忙导致 hook 跳过时，重跑 `renew-cert` 会优先部署已有新 lineage，不重复申请。 |
| **服务器重启后 sing-box 起不来** | 模式 2/4 的 `ExecStartPre` 要求计量目录/锁/规则与 usage 均可读；`journalctl -u easy_all-singbox` 会指出是哪一项。修复后 `sudo easy_all cdn-traffic-sync` 或 `sudo easy_all apply` 恢复；不要把 `Restart=` 或 `StartLimit` 调大来掩盖持续故障。 |
| **订阅可下载但节点无法连接** | 1. 确认客户端内核版本是否过旧（Mihomo 建议 ≥ 1.19.9）；<br>2. 检查云服务商安全组是否放行了业务端口（模式 1/2/3/5：`443`，模式 1 `deploy`、模式 4 与模式 5 另含 `8443`）；<br>3. 模式 4 可在 `PROXY` 组里手动切换直连与 CDN 节点，或选择 `AUTO` / `CDN-FALLBACK` 自动组；模式 5 在 `PROXY` 组里直接切换直连与橙云节点。 |
| **升级后仍看到旧节点名/旧分组** | 旧订阅缓存或自定义模板写死了已删除的组名。在客户端刷新订阅并重新选择 `PROXY` 下的实际节点；模板问题用 `sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo.yaml easy_all edit-sub` 换回内置模板。 |
| **提示状态 schema 不受支持** | 当前目录是 4.x（schema 0）安装。按 §7.4 先用旧版本 `sudo easy_all uninstall`（需要时 `--purge-cloud`），再用 5.x 安装。 |
| **所有命令报状态文件缺少 `STATE_VERSION`** | 状态文件被截断或改坏（所有 5.x 都会写这一行）。先确认本机原来的安装版本：5.x 安装 → 备份后在该文件首行补回 `STATE_VERSION=1`，再执行 `sudo easy_all uninstall`；4.x 安装 → 补回 `STATE_VERSION=0` 后用 4.x 的 `sudo easy_all uninstall`；原版本不明则保留现场，不要修改该文件。 |
