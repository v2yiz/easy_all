# 运维与排障指南

本文档介绍 `easy_all` 安装完成后的日常维护、配置应用、订阅管理、CDN 流量保护运维、卸载清理及常见故障排查。

安装模式对应关系：
- **1 AnyTLS 直连**：纯 AnyTLS 直连入口（TCP 443），订阅可选（deploy / link）；
- **2 纯 CloudFlare**：橙云单域名（TCP 443）同时提供 VLESS WebSocket 节点与订阅；
- **3 AnyTLS + CloudFlare**：直连节点（TCP 443）+ 橙云节点/订阅（TCP 8443 回源）；
- **4 纯 CloudFront**：CloudFront CDN 节点（TCP 443），源站回源（TCP 443）；
- **5 AnyTLS + CloudFront**：直连节点（TCP 443）+ CloudFront 节点（TCP 443），源站回源（TCP 8443）。

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
- **不调用云管理 API**：不改写 DNS，不请求证书签发。唯一外部网络访问为拉取公开的 Cloudflare 官方 IPv4 段（模式 1 deploy / 2 / 3）与 Origin CA 根证书（模式 2），无需账号凭据。
- 模式 1 的 `link` 模式不部署 Caddy 订阅站点，仅重建 AnyTLS 入口。
- 处于保护待落实状态（`blocked=true` 且 `enforced=false`）时，自动执行受限安全恢复，防止带着开放配置启动服务。

### 1.3 `apply-cloud`：同步云端资源
变更域名、凭据或需要收敛云端配置时执行：
```bash
sudo easy_all apply-cloud
```
- **模式 1（AnyTLS）**：校验 Zone SSL 为 `Full (strict)` → 同步直连灰云 A 记录（deploy 另加订阅橙云 A）→ DNS-01 签发/复用 Let's Encrypt 证书 → deploy 时配置 8443 端口 Origin Rule → 本机重建并验收。
- **模式 2（Cloudflare 橙云）**：校验 `Full (strict)` → 同步橙云节点 A 记录 → 签发/复用 Origin CA 证书 → 本机重建并验收 → 吊销旧证书。
- **模式 3（AnyTLS + CloudFlare）**：校验 `Full (strict)` → 同步直连 A 与橙云 A 记录 → DNS-01 签发/复用 Let's Encrypt 证书 → 配置 8443 Origin Rule → 本机重建并验收。
- **模式 4/5（CloudFront）**：
  1. 读取 Cloudflare Token 与 AWS 凭据（凭据仅暂存内存）；
  2. 同步源站灰云 A 记录（模式 5 另含直连 A 记录）；
  3. 签发/复用源站 Let's Encrypt 证书；
  4. ACM 申请/复用证书（固定 `us-east-1`，自动写入 DNS 验证 CNAME 并等待颁发）；
  5. 创建或更新 CloudFront 分发（源站端口模式 4 为 443、模式 5 为 8443），等待 `Deployed`；
  6. 绑定节点 CNAME 至分发域名，并执行本机与公网连通性验收。
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
| `sudo easy_all renew-cert` | 重新签发或轮换 TLS 证书（模式 2 轮换 Origin CA；其余模式走 Certbot） |
| `sudo easy_all cdn-traffic-sync` | （仅模式 4/5）手动采样 CDN 流量并同步落实熔断状态 |
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
  - 安装后若提示重启，执行 `sudo reboot`；
  - 重启后运行 `sudo easy_all status`，确认 `Skyline Speeder: active`；若显示 `degraded`，网络仍可正常连通，可运行 `sudo easy_all apply` 尝试重置修复。

---

## 4. 节点、服务与证书管理

### 4.1 服务单元与日志
| 服务单元 | 职能说明 |
| :--- | :--- |
| `easy_all-singbox.service` | 核心入站：AnyTLS `0.0.0.0:443`、VLESS WebSocket `127.0.0.1:10086` |
| `easy_all-caddy.service` | 订阅与 CDN 回源站点（模式 1 deploy / 3 / 5 监听 `8443`，模式 2 / 4 监听 `443`） |
| `easy_all-cdn-traffic-guard.timer` | （仅模式 4/5）每 15 秒采样计量规则并落实流量阻断 |

- **查看日志**：`sudo journalctl -u easy_all-singbox -u easy_all-caddy -u easy_all-cdn-traffic-guard -f`。
- **重启服务**：核心可用 `sudo systemctl restart easy_all-singbox`；Caddy 请统一通过 `sudo easy_all apply` 重载以保证配置校验完整。

### 4.2 节点域名与凭据变更
- **域名与节点名变更**：节点域名与节点名均与状态深度绑定，改名须执行 `sudo easy_all uninstall` 后重新安装并更新客户端订阅；若仅修改 CDN 优选连接地址，直接通过 `sudo easy_all edit-sub` 修改即可，无需重装。
- **凭据轮换**：AnyTLS 密码、VLESS UUID 与 WebSocket 路径在安装时生成落盘，重装将生成全新凭据；用户 Token 可通过 `sudo easy_all edit-sub` 随时增删，被删 Token 即刻失效。

### 4.3 证书轮换（`renew-cert`）
```bash
sudo easy_all renew-cert
```
- **模式 2**：强制轮换 Cloudflare Origin CA 证书。先签发并部署新证书，通过本机严格 TLS 验收后才吊销旧证书。
- **模式 1/3/4/5**：通过 Cloudflare DNS-01 重新签发 Let's Encrypt 证书，通过本机证书指纹验收后平滑替换。
- **模式 4/5 的 ACM viewer 证书**不归 `renew-cert` 管，由 AWS 自动续期；但证书处于 `FAILED`/`VALIDATION_TIMED_OUT`/`REVOKED`/`EXPIRED` 等终态时，安装与 `apply-cloud` 会直接失败并点名 ARN：重申请会被幂等 Token 取回同一张证书，需先到 AWS 控制台（`us-east-1`）删除后重试。

---

## 5. 订阅与多用户管理

```bash
sudo easy_all edit-sub
```
- **配置结构**：接收包含 `allowedTokens`（用户 Token 字典）与 `nodes`（外部聚合节点数组）的 JSON 配置，省略项即被移除。
- **CDN 优选地址配置**（模式 2–5）：顶层添加可选字段 `"cdnEdgeAddress": "优选域名"`（如 `"cdnEdgeAddress": "m3q8a1w7zr.cloudfront.182682.xyz"`），保存后订阅产物即刻更新生效，无需 `apply-cloud`。删除该字段则恢复为默认连接节点域名。
- **路径与鉴权**：Caddy 仅精准匹配 `/subscribe` 与 `/sub`，其余路径一律 `404`；带非法或重复 Token 的请求均返回 `403`。
- **熔断时修复**：若在流量熔断期间执行 `edit-sub`，脚本将自动在保持 CDN 阻断的状态下更新订阅，保障服务安全。

---

## 6. CDN 流量保护（985 GB 熔断，仅模式 4/5）

### 6.1 工作机制
1. **精准计量**：在 iptables `mangle` 表中基于回环 `127.0.0.1:10086` 上下行数据包进行无干扰计数；模式 5 的 AnyTLS 直连与订阅流量不经过该端口，不计入 CDN 配额。
2. **定时监控**：守护进程每 15 秒同步一次用量，原子写入 `/etc/easy_all/cdn-traffic-usage.json`（配额按 UTC 自然月累计）。
3. **分层阻断**：当月用量达到 **985 GB（985×10⁹ 字节）** 时，自动触发双层阻断：
   - Caddy 代理路径立即拦截并返回 `503`；
   - sing-box 自动省略 CDN 入站配置并重载，终止存量长连接。
   - 模式 5 的 AnyTLS 直连不受影响（经历短暂重连后正常可用）；订阅仍可正常下载。
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
    字段含义：`period` 是 UTC 自然月（`YYYY-MM`）；`runtime_id` 是当前开机 epoch（`mangle-easy_all-cdn-` 加 `cat /proc/sys/kernel/random/boot_id` 的输出，换 epoch 即按新开机重采样基线）；`used_bytes` 是本月已用字节；`last_uplink` / `last_downlink` 是上一次采样的 mangle 计数基线（填 0 会当作基线重置）；`blocked` / `enforced` / `protection_offline` 分别是「应熔断」「熔断已落实」「保护性停机」的布尔状态；
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
- 自动清理 easy_all 本机服务、配置文件、证书、定时器与业务防火墙放行；保留系统内核、Swap、SSH 端口放行及 Fail2ban 基础防护。
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

## 8. 常见问题排查速查表

| 故障现象 | 排查方向与解决办法 |
| :--- | :--- |
| **SSH 断开后无法重连** | 检查云厂商安全组是否放通 SSH 端口；检查是否因密码多次输错被 Fail2ban 临时封禁。 |
| **安装提示端口占用** | 运行 `sudo easy_all cleanup-partial` 清理历史残留；若为第三方应用占用需先释放端口。 |
| **安装提示回源端口已被全局放行** | 机器上已有 `ufw allow 443/tcp` 或 `ufw allow 8443/tcp`（来源 `Anywhere` / `Any` / `0.0.0.0/0`）时，安装会在写入防火墙与云资源**之前**中止。运行 `sudo ufw status numbered` 找到该规则并 `sudo ufw delete <编号>` 移除后重试；否则回源端口对全网开放，Cloudflare-only 边界失效。 |
| **提示状态文件无法确定 schema 字段集 / 不是纯赋值** | `state.env` 被改写或损坏（`PROTOCOL` 缺失/无效，或含命令替换、反引号、`;`、`\|` 等非纯赋值内容）。先备份该文件，按提示行号人工核对或删除该行；若 `PROTOCOL` 已不可恢复，`detect_installed_mode` 会将其归为 `incomplete-*`，此时用 `sudo easy_all uninstall` 走**仅本机清理**通道，云端资源（分发 / ACM / DNS / Origin Rule / Origin CA）需人工核对。 |
| **命令报错 command not found** | 运行 `bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) help` 自动修复命令软链接。 |
| **CloudFront 返回 502** | 回源失败。检查云安全组是否放行回源端口（模式 4 为 443，模式 5 为 8443）；检查源站证书是否有效（`sudo easy_all renew-cert`）。 |
| **CloudFront 返回 503** | 触发了 985 GB 流量熔断保护。运行 `sudo easy_all status` 确认配额，模式 5 可手动切到直连节点继续使用。 |
| **客户端提示证书错误** | 区分证书链路：直连 AnyTLS 与源站为 Let's Encrypt，CloudFront CDN 节点为 AWS ACM，Cloudflare 橙云为 CF 边缘证书。勿在客户端开启“跳过证书验证”。 |
| **订阅下载返回 403 / 404** | 403 为 Token 错误或 URL 携带重复参数；404 为路径错误（仅支持 `/subscribe` 与 `/sub`）。运行 `sudo easy_all subscription` 获取最新链接。 |
| **订阅可下载但节点无法连接** | 1. 确认客户端内核支持 AnyTLS / VLESS WebSocket；<br>2. 检查云安全组业务端口是否放通（全模式放通 443，模式 1 deploy / 3 / 5 另需放通 8443）；<br>3. 若启用了 CDN 优选地址，运行 `edit-sub` 临时移除 `cdnEdgeAddress` 排除第三方域名故障。 |
| **提示状态 schema 不受支持** | 当前系统为旧版 4.x 安装，先使用旧版 `sudo easy_all uninstall` 彻底卸载后再安装新版。 |
