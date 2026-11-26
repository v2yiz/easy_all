# 运维与排障指南

本文档介绍 `easy_all` 安装完成后的日常维护、配置应用、订阅管理、CDN 流量保护运维、卸载清理及常见故障排查。

安装模式对应关系：
- **1 纯 CloudFlare**：橙云单域名（TCP 443，仅 Cloudflare 回源段放行）同时提供 VLESS HTTPUpgrade 节点与订阅；
- **2 纯 CloudFront**：CloudFront CDN 节点（TCP 443），源站回源（TCP 443）；
- **3 Reality + CloudFront**：VLESS Reality 直连（TCP 443）+ CloudFront CDN 节点（TCP 443），采用单 `443` 合一架构经回环 `127.0.0.1:9443` 分流回源与伪装站（公网仅开放 TCP `443`）；
- **4 Reality + CloudFlare**：VLESS Reality 直连（TCP 443，回环 `127.0.0.1:9443` 伪装站）+ 橙云节点/订阅（TCP 8443 仅 Cloudflare 回源段放行）。

---

## 1. 软件更新与配置应用

### 1.1 更新 easy_all 脚本
```bash
sudo easy_all self-update
```
- 从 GitHub 获取最新脚本并安全替换本机代码。不重启服务、不修改配置与云端资源；兼容 `/tmp` 挂载 `noexec` 的加固系统。
- 默认跟随 `main` 分支；开发版可加 `--dev`（或 `--branch <分支>`）。
- 仅支持 `STATE_VERSION=1` 的环境；4.x（schema 0）不可直接升级，须先卸载后重装。

### 1.2 `apply`：纯本机重建配置
更新代码或修改本地配置后，刷新 sing-box / Caddy / 订阅：
```bash
sudo easy_all apply
```
- **仅本机重建**：重新渲染并应用 sing-box 配置、Caddyfile、UFW 端口与订阅产物（六份 Mihomo/Base64 + `singbox.json` / `singbox-all.json`），并平滑重启服务。
- **不调用云管理 API**：不改写 DNS，不请求证书签发。唯一外部网络访问为拉取公开的 Cloudflare 官方 IPv4 段（模式 1/4）与 Origin CA 根证书（模式 1），无需账号凭据。
- **模式 3/4（Reality）重建与伪装站保留**：没有 `link` 模式；模式 3 为单 `443` 合一架构，Caddy 仅监听回环 `127.0.0.1:9443` 同时承载伪装站与 CloudFront 回源/订阅（旧版 v5.5.0 升级后若尚未执行 `apply-cloud`，`apply` 会暂保留兼容 `8443` 站点与放行并提示迁移，避免线上回源 `502`）；模式 4 的 `8443` 橙云回源/订阅站点与 `127.0.0.1:9443` 伪装站始终一起重建。只要 `/var/www/easy_all/camouflage/index.html` 已非空，无论是首次生成的实例变体还是用户自行放置的自定义静态站点，`apply` 与 `renew-cert` 均不会覆盖。
- **模式 4 证书平滑兼容**：从旧版合并 SAN 证书升级后若仅运行 `apply` 尚未执行 `renew-cert`，`8443` 橙云回源会暂沿用现用证书并输出提示，建议随后执行 `sudo easy_all renew-cert` 完成双证书 SAN 隔离。
- 处于保护待落实状态（`blocked=true` 且 `enforced=false`）时，自动执行受限安全恢复，防止带着开放配置启动服务。

### 1.3 `apply-cloud`：同步云端资源
变更域名、凭据或需要收敛云端配置时执行：
```bash
sudo easy_all apply-cloud
```
- **模式 1（Cloudflare 橙云）**：校验 `Full (strict)` 与 `WebSockets` → 同步橙云节点 A 记录 → 签发/复用 Origin CA 证书 → 本机重建并验收 → 吊销旧证书。
- **模式 4（Reality 直连 + 橙云）**：校验 Zone SSL 为 `Full (strict)` 与 `WebSockets` → 同步直连灰云 A 记录与橙云节点 A 记录 → 通过双 Certbot DNS-01 lineage（`easy_all` 仅覆盖直连域名、`easy_all-cdn` 仅覆盖橙云节点域名，共用现有 Cloudflare Token 权限）签发/复用独立 Let's Encrypt 证书 → 配置 `8443` 端口 Origin Rule → 本机重建并验收。
- **模式 2/3（CloudFront）**：
  1. 读取 Cloudflare Token 与 AWS 凭据（凭据仅暂存内存）；
  2. 同步源站灰云 A 记录（模式 3 的源站域名复用直连域名，另含直连 A 记录）；
  3. 签发/复用源站 Let's Encrypt 证书；
  4. ACM 申请/复用证书（固定 `us-east-1`，自动写入 DNS 验证 CNAME 并等待颁发）；
  5. 创建或更新 CloudFront 分发（源站端口为 `443`），等待 `Deployed`（含目标 `HTTPSPort` 收敛）；
  6. 绑定节点 CNAME 至分发域名，并执行本机与公网连通性验收。
  - **v5.5.0 模式 3 升级至单 `443`**：旧版模式 3 升级代码后执行一次 `sudo easy_all apply-cloud` 即可零中断迁移——会先并行开启 `9443` 合一站点与兼容 `8443` 站点，待 CloudFront 切换回源端口至 `443` 并收敛 `Deployed` 后自动写入 `/etc/easy_all/mode3-single443.migrated`、切换为纯单 `443` 配置并回收旧 `8443` UFW 放行（云安全组随后可移除 `8443`）。
- 失败时本机配置安全回滚，已创建的云资源保留并打印清单供查验。

---

## 2. 常用管理命令速查表

| 命令 | 功能说明 |
| :--- | :--- |
| `sudo easy_all status` | 查看系统负载、TCP 加速、服务状态、证书与流量保护额度 |
| `sudo easy_all subscription` | 查看各节点的详细连接参数与用户专属订阅链接 |
| `sudo easy_all show` | 输出各节点详细参数、VLESS 分享链接与客户端配置片段 |
| `sudo easy_all apply` | **纯本机重建**：刷新服务配置与订阅产物（不请求云端 API） |
| `sudo easy_all apply-cloud` | **同步云端资源**：收敛 DNS 解析、证书、CloudFront 分发与 Origin Rule |
| `sudo easy_all edit-sub` | 交互式管理用户 Token 与外部聚合节点（可修改/删除 `cdnEdgeAddress` 优选地址） |
| `sudo easy_all renew-cert` | 重新签发或轮换 TLS 证书（模式 1 轮换 Origin CA；其余模式走 Certbot） |
| `sudo easy_all hellogfw` | （仅模式 3/4）分析直连 TCP 443 主动探测日志线索；`hellogfw -h` 免 root |
| `sudo easy_all cdn-traffic-sync` | （仅模式 2/3）手动采样 CDN 流量并同步落实熔断状态 |
| `sudo easy_all update-core` | 重新安装或修复锁定版本的 sing-box 与 Caddy 核心 |
| `sudo easy_all self-update` | 从 GitHub 更新 `easy_all` 脚本自身（`--dev` 切换开发分支） |
| `sudo easy_all cleanup-partial` | 清理安装中断留下的本机临时残留（未安装状态使用，不碰云端） |
| `sudo easy_all purge-cloud` | 独立清理当前域名下的 easy_all Cloudflare 与 CloudFront/ACM 资源 |
| `sudo easy_all uninstall` | 完整卸载本机服务并同步清理关联云端资源 |

---

## 3. TCP 加速（Skyline Speeder）

- 安装时自动配置并启用 [Skyline Speeder](https://github.com/CYBERVERSE-Research/skyline-speeder)；依赖 Linux 6.12+ 内核（若版本不足自动换装 Zabbly 6.12+ LTS 内核）。
- **低配服务器**：内存 ≤ 1GB 的小机建议预留 ≥ 1.5GB 根分区空间，脚本会自动创建 1GB Swap 避免编译期 OOM。
- **状态验证**：
  - 安装收尾可选把 SSH 端口迁移到新端口（默认 `22222`），迁移后原端口被禁用，按提示确认重启（或手动执行 `sudo reboot`）使新端口与内核生效；选择「不变更」则端口与防火墙不变，仅在需换内核时提示重启；
  - 重启后运行 `sudo easy_all status`，确认 `Skyline Speeder: active`；若显示 `degraded`，网络仍可正常连通，可运行 `sudo easy_all apply` 尝试重置修复。

> [!CAUTION]
> **SSH 端口提醒**：安装收尾会让你三选一（`1. 不变更` / `2. 修改为 22222`（默认） / `3. 自定义端口`）。选了变更时，新端口放行、旧端口被 UFW 与 Fail2ban 阻断，**请务必在选择重启后使用 `ssh -p <新端口> <用户>@<服务器 IP>` 登录**（若使用 AWS / GCP 等外部安全组，请先放行 **TCP 新端口**）；选「不变更」时 `sshd` 配置与防火墙均保持不变，仍用原端口登录，也不会弹出 SSH 端口重启提示。

---

## 4. 节点、服务与证书管理

### 4.1 服务单元与日志
| 服务单元 | 职能说明 |
| :--- | :--- |
| `easy_all-singbox.service` | 核心入站：VLESS Reality `0.0.0.0:443`（模式 3 转发非 Reality 握手与 CloudFront 回源流量到 `127.0.0.1:9443`，模式 4 转发非 Reality 握手到 `127.0.0.1:9443`）、VLESS CDN 入站 `127.0.0.1:10086`（模式 1/4 为 `httpupgrade`，模式 2/3 为 `ws`） |
| `easy_all-caddy.service` | 订阅与 CDN 回源站点（模式 1/2 监听 `443`；模式 3 仅监听回环 `127.0.0.1:9443` 按 `X-Easy-All-Origin-Key` 统一分流回源/订阅与伪装站，旧装未执行 `apply-cloud` 迁移前暂保留 `8443` 兼容；模式 4 监听 `8443` 并在 `127.0.0.1:9443` 提供独立伪装站） |
| `easy_all-cdn-traffic-guard.timer` | （仅模式 2/3）每 15 秒采样计量规则并落实流量阻断 |
| `easy_all-probe-log.service` | （仅模式 3/4）oneshot，重启/`apply` 时重放直连 TCP 443 的限速 `GFW_CHK:` 内核 LOG 规则 |

- **查看日志**：`sudo journalctl -u easy_all-singbox -u easy_all-caddy -u easy_all-cdn-traffic-guard -f`。
- **重启服务**：核心可用 `sudo systemctl restart easy_all-singbox`；Caddy 请统一通过 `sudo easy_all apply` 重载以保证配置校验完整。

### 4.2 节点域名与凭据变更
- **域名与节点名变更**：节点域名与节点名均与状态深度绑定，改名须执行 `sudo easy_all uninstall` 后重新安装并更新客户端订阅；若仅修改 CDN 优选连接地址，直接通过 `sudo easy_all edit-sub` 修改即可，无需重装。
- **凭据轮换**：VLESS UUID、VLESS 路径与 Reality 密钥对（`REALITY_PRIVATE_KEY`/`REALITY_PUBLIC_KEY`/`REALITY_SHORT_ID`）在安装时生成落盘，重装将生成全新凭据；用户 Token 可通过 `sudo easy_all edit-sub` 随时增删，被删 Token 即刻失效。

### 4.3 证书轮换（`renew-cert`）
```bash
sudo easy_all renew-cert
```
- **模式 1**：强制轮换 Cloudflare Origin CA 证书。先签发并部署新证书，通过本机严格 TLS 验收后才吊销旧证书。
- **模式 2/3**：通过 Cloudflare DNS-01 重新签发 `easy_all` lineage 的 Let's Encrypt 证书，通过本机证书指纹验收后平滑替换。
- **模式 4（双 Certbot DNS-01 隔离）**：分别维护两套独立 lineage——`easy_all` 仅覆盖直连域名（`/etc/easy_all/certs/fullchain.pem`，供 `443` 直连与模式 4 伪装站），`easy_all-cdn` 仅覆盖橙云节点域名（`/etc/easy_all/certs/cdn-fullchain.pem`，供 `8443` 橙云回源），彻底隔离证书 SAN；两套 lineage 共用现有 `/etc/easy_all/cloudflare.ini` 凭据，**无需额外 Cloudflare Token 权限**。**v5.5.0 升级拆分**：旧版合并 SAN 证书的节点执行一次 `sudo easy_all renew-cert`（或 `apply-cloud`）即可自动缩容重签并拆分为独立双证书。
- **模式 2/3 的 ACM viewer 证书**不归 `renew-cert` 管，由 AWS 自动续期；但证书处于 `FAILED`/`VALIDATION_TIMED_OUT`/`REVOKED`/`EXPIRED` 等终态时，安装与 `apply-cloud` 会直接失败并点名 ARN：重申请会被幂等 Token 取回同一张证书，需先到 AWS 控制台（`us-east-1`）删除后重试。

---

## 5. 订阅与多用户管理

```bash
sudo easy_all edit-sub
```
- **配置结构**：接收包含 `allowedTokens`（用户 Token 字典）与 `nodes`（外部聚合节点数组）的 JSON 配置，省略项即被移除。
- **CDN 优选地址配置**（模式 1–4）：顶层添加可选字段 `"cdnEdgeAddress": "优选域名"`（如 `"cdnEdgeAddress": "m3q8a1w7zr.cloudfront.182682.xyz"`），保存后订阅产物即刻更新生效，无需 `apply-cloud`。删除该字段则恢复为默认连接节点域名。
- **路径与鉴权**：Caddy 仅精准匹配 `/subscribe` 与 `/sub`，其余路径一律 `404`；带非法或重复 Token 的请求均返回 `403`。
- **熔断时修复**：若在流量熔断期间执行 `edit-sub`，脚本将自动在保持 CDN 阻断的状态下更新订阅，保障服务安全。

---

## 6. CDN 流量保护（985 GB 熔断，仅模式 2/3）

### 6.1 工作机制
1. **精准计量**：在 iptables `mangle` 表中基于回环 `127.0.0.1:10086` 进行无干扰计数：仅将下行出站流量（sing-box → Caddy）计入 `used_bytes` 以匹配 CloudFront 仅计出站口径（上行仅用于计数回退异常检测）；模式 3 的直连入口与订阅流量不经过该端口，不计入 CDN 配额。
2. **定时监控**：守护进程每 15 秒同步一次用量，原子写入 `/etc/easy_all/cdn-traffic-usage.json`（配额按 UTC 自然月累计），并同步更新 `/etc/easy_all/caddy/subscription-userinfo` 供订阅响应头 `Subscription-Userinfo`（按客户端 `1024^3` 显示口径等比例换算已用字节，`total=1057635696640` 对应 `985 GiB`，使客户端精确显示 `985 GB` 与下月 1 日 UTC 重置时间）实时下发。
3. **分层阻断**：当月用量达到 **985 GB（985×10⁹ 字节）** 时，自动触发双层阻断：
   - Caddy 代理路径立即拦截并返回 `503`；
   - sing-box 自动省略 CDN 入站配置并重载，终止存量长连接。
   - 模式 3 的直连入口（Reality 443）与 `127.0.0.1:9443` 伪装站不受影响（经历短暂重连后正常可用）；订阅仍可正常下载（仅在触发 `protection_offline=true` 保护性停机并停止 sing-box 时，模式 3 单 `443` 承接的直连、伪装站与 CloudFront 回源/订阅会一并暂下线，待 `cdn-traffic-sync` 完成受限恢复后恢复）。
4. **月度重置**：次月首日 UTC 零点用量自动清零并恢复 CDN 访问。

### 6.2 状态排查
运行 `sudo easy_all status` 查看保护状态：
- 若显示 `blocked=true`：说明当月配额耗尽，CDN 已熔断至次月；
- 若显示 `统计文件缺失或损坏`（`/etc/easy_all/cdn-traffic-usage.json`）：保护会立即 fail-closed 停机，且**不会自动清零、也不会自动重建**——`cdn-traffic-sync` 与 `apply` 只会告警并保持停机，反复运行不会有任何进展。恢复必须按受控步骤人工重建统计文件：
    1. `sudo systemctl stop easy_all-cdn-traffic-guard.timer`（先停 15 秒一次的巡检，避免反复停机）；
    2. 备份现有文件：`sudo cp /etc/easy_all/cdn-traffic-usage.json /root/cdn-traffic-usage.broken`（文件不存在时跳过）；
    3. 按下面的 8 键 schema 写入合法 JSON，其中 `used_bytes` 必须取**不低于真实累计**的保守值（写小了会让 985 GB 熔断滞后）：
    ```json
    {
      "period": "2026-11",
      "runtime_id": "mangle-easy_all-cdn-<当前开机 boot_id>",
      "used_bytes": 0,
      "last_uplink": 0,
      "last_downlink": 0,
      "blocked": false,
      "enforced": false,
      "protection_offline": false
    }
    ```
    字段含义：`period` 是 UTC 自然月（`YYYY-MM`）；`runtime_id` 是当前开机 epoch（`mangle-easy_all-cdn-` 加 `cat /proc/sys/kernel/random/boot_id` 的输出，换 epoch 即按新开机重采样基线）；`used_bytes` 是本月已用出站字节（仅统计下行，升级当月若含切换前的历史双向累计会保守偏高）；`last_uplink` / `last_downlink` 是上一次采样的 mangle 计数基线（填 0 会当作基线重置）；`blocked` / `enforced` / `protection_offline` 分别是「应熔断」「熔断已落实」「保护性停机」的布尔状态；
    4. `sudo systemctl start easy_all-cdn-traffic-guard.timer`，再运行 `sudo easy_all cdn-traffic-sync` 复核输出；
    5. 无法确定可信累计值（文件已被清空、也没有任何历史读数）时，改为卸载重装（`sudo easy_all uninstall` 后重新安装），由安装流程重建统计文件。
- 若 CDN 仍可访问但状态显示 `enforced=true`（重建后落盘失败、进程中途被杀等）：下一轮 timer 会按反向漂移强制收敛为阻断并告警，无需手工清空状态文件。
- 若日志出现 `mangle 计量规则数异常`：说明计量规则被重复插入，保护会保持现有阻断状态。`sudo easy_all cdn-traffic-sync` 会幂等修复（缺几条补几条、多几条删多余的），这是该入口的自愈路径；订阅未就绪时会安装返回 `503` 的降级站点并禁止解封，先执行 `sudo easy_all edit-sub`。
- 若日志出现 `计量计数在同一次开机内回退`：说明 mangle 计数被外部 `flush` 或重置，`cdn-traffic-sync` **不会**修复——它按计量异常拒绝回写低读数并保持停机（静默写 0 会漏计整月流量）。恢复方式是重启主机让计费 epoch（`runtime_id`）更新，下一轮采样按新基线重算，`used_bytes` 里的本月累计不受影响；同一 epoch 内再次被外部重置会重新停机，需同时排查是谁在 `flush` mangle 表。

---

## 7. 卸载与云端清理

### 7.1 本机卸载
```bash
sudo easy_all uninstall
```
- 自动清理 easy_all 本机服务、配置文件、证书、定时器与业务防火墙放行；保留系统内核、Swap、SSH 端口放行及 Fail2ban 基础防护。模式 3/4 卸载时仅按受管清单删除本工具生成的伪装站文件与空目录，保留用户在 `/var/www/easy_all/camouflage` 下自行放置的静态站点文件。
- 默认自动尝试清理关联的云端资源（DNS 记录、Origin Rule、CloudFront 分发与 ACM 证书）。

### 7.2 独立云端清理（`purge-cloud`）
若 VPS 已销毁或状态丢失，可使用独立命令清理账户内 easy_all 标记的残留资源：
```bash
sudo easy_all purge-cloud --domain example.com
```
- **Cloudflare**：根据注释与前缀自动清理 easy_all 相关的 DNS 记录、Origin Rule 及 Origin CA 证书。
- **CloudFront / ACM**：提供 AWS 凭据且已安装 aws CLI 时自动联动清理：安全禁用并删除对应 Comment 且别名严格匹配的分发，并删除对应未在用的 ACM 证书。计划阶段仍被分发占用的证书不会被放弃：分发删除后会逐个复核，确认已无 `InUseBy`、归属与域名均在范围内才删除；仍被其他分发占用的照旧保留。
- **分页上限**：环境变量 `EASY_ALL_PURGE_MAX_PAGES` 控制列表扫描上限（默认 100 页 × 100 条），超限安全中止。
- **收敛等待**：`EASY_ALL_PURGE_AWS_WAIT_ATTEMPTS`（默认 60）与 `EASY_ALL_PURGE_AWS_WAIT_SECONDS`（默认 10）控制分发禁用传播与证书 `InUseBy` 收敛的轮询次数与间隔；删除失败的分发不计入等待对象，仍被存活资源占用的证书会直接保留。

---

## 8. 直连主动探测日志分析（仅模式 3/4）

模式 3/4 的直连入口都监听公网 TCP `443`，安装与 `apply` 会在 iptables `filter INPUT` 的**第 1 条**插入一条限速 `LOG` 规则，把新建连接的来源记到内核日志（前缀 `GFW_CHK: `，`30/min`、burst `60`）。它只记 IPv4 的 SYN 包，不记 payload、TLS 内容或连接时长，也不改变 `ACCEPT`/`DROP` 判定。

```bash
# 默认时间窗（24 hours ago）
sudo easy_all hellogfw

# 指定时间窗（整体作为一个参数传给 journalctl --since）
sudo easy_all hellogfw --since "3 days ago"

# 已知正常客户端（可重复），避免自己的出口被当成候选
sudo easy_all hellogfw --since "7 days ago" --my-ip 203.0.113.10 --my-ip 198.51.100.20

# 免 root 查看用法（不读安装状态）
easy_all hellogfw --help
```

- **没有 `--port`**：直连端口固定 `443`；旧调用与未知参数直接非零退出。
- **输出内容**：时间窗、匹配的 SYN 记录数、独立来源数、正常客户端参照、同期 sing-box `WARN`/`ERROR` 条数（含 Reality 非授权回落条数 `REALITY: processed invalid connection`），以及「低频陌生连接候选」（正常客户端连接后 `1.0–120.0` 秒内出现、全窗不超过 2 次、且不在参照集合内）。**这只是基于时序与频次的候选线索，不构成 GFW 归因证明**；无候选也不等于未发生主动探测。**注**：模式 3（单 `443` 合一）下 CloudFront 回源流量（订阅刷新与应急 CDN）也共用 TCP `443`，其回源连接与 Reality 回落日志会自然混入统计。
- **规则缺失时先修采集**：`hellogfw` 会在分析前核对采集规则，缺失或无法查询时非零退出并提示 `sudo easy_all apply` 或 `sudo systemctl restart easy_all-probe-log.service`，绝**不**把“采不到”当成“没有探测”。
- **重放时机**：`easy_all-probe-log.service` 是 `oneshot` + `RemainAfterExit`，`ExecStart`/`ExecStop` 只重放/删除这一条规则；安装与 `apply` 会在**最后一次 UFW reload 之后**强制 `systemctl restart easy_all-probe-log.service`。管理员手工 `ufw` 操作或其他防火墙管理器仍可能在之后清掉它，重启本服务或执行 `apply` 即可恢复。
- **覆盖范围**：默认只记录当前默认路由的公网网卡；拿不到默认路由时回退为 `! -i lo`（记录所有非回环接口的 TCP 443 SYN，噪声更多但不会静默漏掉公网入口）。路由/网卡名变化后需重启、`apply` 或重启本服务重新选择。仅记录 IPv4。

> [!WARNING]
> **全局保留上限**：启用本功能时写入 `/etc/systemd/journald.conf.d/99-easy_all-probe-retention.conf`，内容只有 `[Journal]` 与 `MaxRetentionSec=30day`。这是 `systemd-journald` 的**全局**保留上限，**影响主机全部 journal（不限 easy_all 或 `GFW_CHK:`）**；启用后，超过上限的主机历史日志也可能被 vacuum 且**无法恢复**。easy_all 不设置容量上限（不写 `SystemMaxUse`），但主机既有容量限制仍可能让实际保留少于 30 天。

- **卸载与恢复**：`uninstall` / `cleanup-partial` 会删除该 drop-in 并显式 `systemctl restart systemd-journald`。删除只影响之后的保留行为，**不能找回已 vacuum 的历史日志**；删除成功但 journald 重启失败时命令非零，运行中的 journald 可能仍在沿用旧上限，需重试 `sudo systemctl restart systemd-journald`。
- **缺 `iptables` 时的卸载**：缺工具不等于内核没有规则。只要还有 state、unit 或 drop-in 证据，`uninstall` 会非零并**保留 state 与命令**；装回 `iptables` 后重试同一 `sudo easy_all uninstall` 即可，不要手工删 state。

---

## 9. 常见问题排查速查表

| 故障现象 | 排查方向与解决办法 |
| :--- | :--- |
| **SSH 断开后无法重连** | 检查云厂商安全组是否放通 SSH 端口；检查是否因密码多次输错被 Fail2ban 临时封禁。 |
| **安装提示端口占用** | 运行 `sudo easy_all cleanup-partial` 清理历史残留；若为第三方应用占用需先释放端口。 |
| **安装提示回源端口已被全局放行** | 机器上已有 `ufw allow 443/tcp` 或 `ufw allow 8443/tcp`（来源 `Anywhere` / `Any` / `0.0.0.0/0`）时，安装会在写入防火墙与云资源**之前**中止。运行 `sudo ufw status numbered` 找到该规则并 `sudo ufw delete <编号>` 移除后重试；否则回源端口对全网开放，Cloudflare-only 边界失效。 |
| **提示状态文件无法确定 schema 字段集 / 不是纯赋值** | `state.env` 被改写或损坏（`PROTOCOL` 缺失/无效，或含命令替换、反引号、`;`、`\|` 等非纯赋值内容）。先备份该文件，按提示行号人工核对或删除该行；若 `PROTOCOL` 已不可恢复，`detect_installed_mode` 会将其归为 `incomplete-*`，此时用 `sudo easy_all uninstall` 走**仅本机清理**通道，云端资源（分发 / ACM / DNS / Origin Rule / Origin CA）需人工核对。 |
| **命令报错 command not found** | 运行 `bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) help` 自动修复命令软链接。 |
| **CloudFront 返回 502** | 回源失败。检查云安全组是否放行回源端口（模式 2/3 为 `443`；旧版模式 3 升级后未执行 `sudo easy_all apply-cloud` 迁移前仍为 `8443`）；检查源站证书是否有效（`sudo easy_all renew-cert`）。 |
| **CloudFront 返回 503** | 触发了 985 GB 流量熔断保护。运行 `sudo easy_all status` 确认配额，模式 3 可手动切到直连节点继续使用。 |
| **模式 3/4 Reality 直连失败或静默回落到伪装站** | 服务端开启了 `max_time_difference: 2m` 抗重放校验，客户端与服务端时钟偏差超过 2 分钟会静默回落伪装站。在 VPS 上运行 `timedatectl status` 核对 `System clock synchronized: yes`（必要时 `sudo timedatectl set-ntp true && sudo systemctl enable --now systemd-timesyncd`），并确认客户端设备已开启自动网络校时；`sudo easy_all status` 在 NTP 未同步时也会给出警告。 |
| **客户端提示证书错误** | 区分证书链路：直连 Reality 与源站为 Let's Encrypt（模式 4 拆分为独立直连与橙云两张证书），CloudFront CDN 节点为 AWS ACM，Cloudflare 橙云为 CF 边缘证书。勿在客户端开启“跳过证书验证”。 |
| **订阅下载返回 403 / 404** | 403 为 Token 错误或 URL 携带重复参数；404 为路径错误（仅支持 `/subscribe` 与 `/sub`）。运行 `sudo easy_all subscription` 获取最新链接。 |
| **订阅可下载但节点无法连接** | 1. 确认客户端内核支持 VLESS Reality / VLESS WebSocket（CloudFront 模式 2/3）/ VLESS HTTPUpgrade（Cloudflare 模式 1/4）；<br>2. 检查云安全组业务端口是否放通（模式 2/3/4 公网放通 `443`；模式 1 的 `443` 与模式 4 的 `8443` 仅对 Cloudflare 回源段放通；旧版模式 3 未执行 `apply-cloud` 迁移前仍需放通 `8443`）；<br>3. 模式 3/4 直连异常时用 `timedatectl` 与客户端自动校时核对 2 分钟时间窗；<br>4. 若启用了 CDN 优选地址，运行 `edit-sub` 临时移除 `cdnEdgeAddress` 排除第三方域名故障。 |
| **提示状态 schema 不受支持** | 当前系统为旧版 4.x 安装，先使用旧版 `sudo easy_all uninstall` 彻底卸载后再安装新版。 |
