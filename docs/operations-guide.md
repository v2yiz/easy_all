# 运维与排障指南

本文档介绍 `easy_all` 安装完成后的日常维护、配置应用、订阅管理、CDN 流量保护运维、卸载清理及常见故障排查。

安装菜单只有三个模式：**1 直连 Reality**、**2 纯 CDN（CloudFront）**、**3 直连+CloudFront**。下文标注「模式 2/3」的命令只适用于 CloudFront 链路。

---

## 1. 软件更新与配置应用

### 1.1 更新 easy_all 脚本
```bash
sudo easy_all self-update
```
- `self-update` 仅从 GitHub 拉取并替换安装器自身的代码，不会擅自重启服务、应用配置或修改云端资源；脚本显式经由系统 Bash 执行，兼容 `/tmp` 挂载有 `noexec` 安全标志的加固系统。
- 默认跟随 `main` 分支；若需测试开发版可加 `--dev` 参数（或 `--branch <分支>`）。
- 旧版 Cloudflare CDN 安装（`PROTOCOL=cdn` 或旧 `combined`）不能接管，必须先卸载重装，见 [§7.4](#74-旧版本状态与不完整新状态只能卸载重装)。

### 1.2 `apply`：纯本机重建配置
当脚本更新后需要重新渲染运行时，或需要刷新 Xray / Nginx / 订阅文件：
```bash
sudo easy_all apply
```
- 模式 2/3：**只在 VPS 本机重建**——重新渲染并应用 Xray 配置（含 StatsService 与阻断状态）、Nginx 站点、UFW 业务端口与六个订阅产物。**不访问 Cloudflare / AWS API，不签发 ACM 或源站证书，不改 DNS**。
- 模式 1 例外：`deploy` 订阅仍要一次 Cloudflare API Token 以签发或复用 Cloudflare Origin CA 回源证书（Token 不落盘），同样不改 DNS。
- 保护待落实（`blocked=true` 且 `enforced=false`）时先做[受限安全恢复](#63-各命令在保护停机时的准入)，恢复失败直接非零停止，不会带着开放配置启动 Xray。
- 订阅配置损坏时普通 `apply` 会失败并提示 `sudo easy_all edit-sub`，不会静默把聚合节点清空。
- 源站证书缺失或异常（`status` 显示「源站证书异常/缺失」）应执行 `sudo easy_all renew-cert`；ACM 证书或分发需要重建时用 `apply-cloud`。

### 1.3 `apply-cloud`：同步云端资源（模式 2/3）
改过域名、换了 AWS 凭据或需要重新收敛云端资源时：
```bash
sudo easy_all apply-cloud
```
一次执行会按固定顺序完成：

1. 读取 Cloudflare API Token（优先复用 `/etc/easy_all/cloudflare.token`，否则隐藏输入后原子写入 `0600`）。
2. 保守同步灰云 DNS 的源站（及模式 3 直连）`A` → VPS 公网 IPv4；同名第三方/多条冲突记录不会被抢占。
3. 复用或续签**源站 Let's Encrypt 证书**（HTTP-01，只覆盖源站域名）。
4. 复用或申请 **AWS ACM 证书**（固定 `us-east-1`，SAN 只含节点域名与订阅域名），自动写入 DNS validation `CNAME` 并等待 `ISSUED`。
5. 创建或更新 **CloudFront 分发**（`Comment=easy_all-cloudfront-<节点域名>`），等待 `Status=Deployed`。
6. 收敛节点与订阅 `CNAME` → 分发域名，然后执行 §1.2 的本机重建、严格本机验收与公网验收。

- 失败时：**本机配置回滚，云端资源保留**并输出分发 ID 与 ACM ARN；修正后再次 `apply-cloud` 收敛，必要时到控制台处置。不会因为一次 API 查询失败就再创建一个重复分发，也不会用自签证书顶替失败的 Let's Encrypt。
- 云端与本机不是跨云事务：部分云端变更成功、本机失败是允许的结果，重跑同一条命令即可收敛。

---

## 2. 常用管理命令速查表

| 命令 | 说明 |
| :--- | :--- |
| `sudo easy_all install` | 交互选择 Reality、纯 CDN（CloudFront）或直连+CDN 并安装 |
| `sudo easy_all show` | 打印当前节点链接（VLESS URI）与 Mihomo YAML 配置片段 |
| `sudo easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `sudo easy_all self-update` | 从 GitHub 更新 easy_all 脚本体（`--dev` 使用开发分支） |
| `sudo easy_all apply` | 应用已安装配置；模式 2/3 只重建本机与订阅，不访问云 API |
| `sudo easy_all reality-target [域名:端口]` | （Reality / 直连+CDN）修改伪装目标 SNI，带 TLS 1.3 自动握手验证 |
| `sudo easy_all rotate-dynamic-ports` | （仅 Reality 模式）立即轮换并刷新动态端口 NAT 重定向规则 |
| `sudo easy_all apply-cloud` | （模式 2/3）同步云端资源：Cloudflare DNS、AWS ACM 与 CloudFront 分发、源站证书 |
| `sudo easy_all edit-sub` | 交互式编辑订阅配置（用户 Token + 聚合节点）与订阅模板 |
| `sudo easy_all cdn-traffic-sync` | （模式 2/3）同步 CloudFront CDN 用量并落实流量阻断 |
| `sudo easy_all purge-cloudflare` | 清理 easy_all 创建的 Cloudflare 远端资源（可在未安装或状态丢失时使用） |
| `sudo easy_all update-core` | 在线升级 Xray 核心至官方最新版本，并自动重载服务 |
| `sudo easy_all renew-cert` | 重新签发 / 部署当前模式的 TLS 证书 |
| `sudo easy_all status` | 查看模式、域名、分发/ACM、源站证书、服务状态与 985 GB 流量保护额度 |
| `sudo easy_all cleanup-partial` | 清理安装中断留下的本机残留（未安装状态使用；不改云端资源） |
| `sudo easy_all uninstall` | 卸载当前模式；加 `--purge-cloud` 一并清理托管的远端资源 |
| `sudo easy_all help` | 显示帮助 |

> 模式 1 的 `apply` / `edit-sub` / `renew-cert` 会用到 Cloudflare API（订阅回源证书），模式 2/3 的这三条命令**都不访问 AWS / Cloudflare**；需要改云端时用 `apply-cloud`。

---

## 3. TCP 加速（Skyline Speeder）

- amd64 与 arm64 平台安装时前置配置并启用 [Skyline Speeder](https://github.com/CYBERVERSE-Research/skyline-speeder)；不再提供 BBR/XanMod 方案。
- **内核要求**：Skyline 要求 Linux 6.12+。若系统内核较低，安装器会自动升级 Zabbly 6.12+ LTS 内核。
- **状态确认**：
  - 安装后若提示重启，执行 `sudo reboot`；
  - 重启后运行 `sudo easy_all status`，显示 `Skyline Speeder: active` 即表示已成功加速。
  - 若显示 `degraded`，说明 Skyline 未生效（拥塞控制回落到内核默认值），网络连接不受影响。执行 `sudo easy_all apply` 可尝试修复；修复后仍会校验 `skyline_cc` 是否真的生效。

---

## 4. 节点与伪装目标管理

### 4.1 更换 Reality 伪装目标（SNI，适用于模式 1 与模式 3）
```bash
sudo easy_all reality-target swdist.apple.com:443
```
- 命令会先通过统一准入确认没有待落实的 CDN 阻断（有则先做受限安全恢复，恢复失败不改 target），随后用 `xray tls ping` 验收新目标的 TLS 1.3 握手连通性与 ASN 归属，验证通过后原子替换配置并重载 Xray。
- 随后客户端刷新订阅即可获取新 SNI；失败会恢复旧 target、旧配置与旧订阅，用量统计不回滚。

### 4.2 轮换动态端口（仅模式 1）
```bash
sudo easy_all rotate-dynamic-ports
```
仅 Reality 模式的动态端口模式支持。模式 2/3 的 CDN 入口固定走 CloudFront 的 443，模式 3 的直连入口固定 `8443`，因此这两条模式下执行该命令会明确报错。

### 4.3 轮换 VLESS UUID（模式 1）
```bash
sudo env VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)" easy_all apply
```
执行后旧 UUID 立即失效，请在客户端更新订阅。模式 2/3 的 UUID 是落盘状态的一部分，没有单独轮换入口；重装会生成新的 UUID、路径与 Token，客户端必须重新导入。

### 4.4 CloudFront 单节点名称（模式 2/3）
模式 2/3 的本机 CDN 节点只有一个，名称由安装时输入的「CloudFront 节点名」决定（默认 `🇺🇸AWS`，1–64 个字符，不得使用 `PROXY`、`GLOBAL`、`AUTO` 等保留名，也不得与直连节点或聚合节点重名）。它不会自动追加序号，也没有额外的测速/兜底节点。改名需要重新安装并重新导入订阅。

---

## 5. 订阅与多用户管理

三个模式的 `deploy` 订阅共用同一份订阅配置：
```bash
sudo easy_all edit-sub
```

- **订阅配置**：按提示输入一份 JSON，同时包含 `allowedTokens`（用户 Token 字典）与 `nodes`（聚合节点数组）。省略的用户或节点会被删除；完成后各用户的专属订阅链接可通过 `sudo easy_all subscription` 查看。
- **聚合节点**：`nodes` 支持三种类型——`vless` + `reality/tcp`、`vless` + `tls/xhttp`、`mieru`；示例见 `templates/aggregation.example.json`。`optional: true` 的节点仅在订阅 URL 追加 `&node=all` 时下发。`tls/xhttp` 节点的 `host` 是客户端连接地址，`sni` 同时作为 TLS SNI 与 HTTP `Host` 头；`reality/tcp` 节点的 `sid` 需为 2–16 位偶数长度十六进制。
- **自定义模板**：支持交互式切换或重载 Mihomo 订阅模板（也可用 `MIHOMO_TEMPLATE_SOURCE` 传入本地文件或 HTTPS URL）。选中的模板会以 `0600` 快照保存在 `/etc/easy_all/mihomo-template.yaml`，后续 `apply`、`edit-sub` 与重装后的发布沿用同一份快照；快照缺失会告警并回退内置默认模板。
- **失败回滚**：订阅配置校验、发布或验收任一步失败都会恢复旧的订阅状态、模板与六个产物文件。

### 5.1 保护停机时的 `edit-sub`
当 CDN 用量达到阈值且阻断尚未落实（`blocked=true`、`enforced=false`）时，`edit-sub` 仍可执行，但走**保持阻断**的修复分支：

1. 先应用 XHTTP `503` 的受限 Nginx，并停止旧 Xray（旧 CDN 长连接随之终止）；
2. 在安全边界确立后接收新的完整订阅配置，只更新订阅相关状态、模板、六个产物与受限 Nginx；
3. 不启动/重启 Xray、不采样、不改写用量文件；
4. 成功返回 0 只表示「订阅修复完成，保护仍 pending」，输出 `blocked` / `enforced` / `protection_offline` 原值，并提示执行 `sudo easy_all cdn-traffic-sync`。

修复失败会保留已生效的 `503` 与停止的 Xray，只回滚订阅对象，不会恢复旧的开放 Nginx。

---

## 6. CDN 流量保护（985 GB 熔断）运维

### 6.1 工作原理
1. Xray 额外监听 `127.0.0.1:10085` 暴露 StatsService，**只统计 XHTTP 入站**（`vless-xhttp-in`）的上行/下行字节；模式 3 的 Reality 流量不计入。
2. systemd 定时器 `easy_all-cdn-traffic-guard.timer`（`OnBootSec=15s`、`OnUnitActiveSec=15s`）每 15 秒执行一次 `easy_all cdn-traffic-sync`。
3. 累计用量原子写入 `/etc/easy_all/cdn-traffic-usage.json`（`0600`），字段为 `period` / `runtime_id` / `used_bytes` / `last_uplink` / `last_downlink` / `blocked` / `enforced` / `protection_offline`。
4. 阈值固定为 **985×10⁹ 字节（十进制 985 GB）**；月度按 **UTC 自然月** 划分，`period` 形如 `2026-11`。
5. 触发阻断时是**双层阻断**：Nginx 的 XHTTP 位置直接返回 `503`，Xray 清空 XHTTP 入站客户端、加上 `block` 路由并重启以终止已建立的 CDN 长连接。模式 3 的 Reality 直连会短暂重连但继续可用；订阅链接仍可下载，节点不会被从订阅里删除。
6. `blocked` 是期望的限额状态，`enforced` 是最后完成验收的应用状态；两者不一致即为「待落实」（pending），`protection_offline=true` 表示保护性停机意图已持久化（Xray 已停止或即将停止），它不表示允许解封。

### 6.2 `status` 解读
```bash
sudo easy_all status
# CloudFront 全局费用保护: enabled（UTC 自然月 2026-11，阈值 985 GB）
#   已统计: 12.345 GB，剩余保护空间: 972.655 GB，blocked=false，enforced=false，protection_offline=false
```
- `CloudFront 全局费用保护: 异常（统计文件缺失或损坏：/etc/easy_all/cdn-traffic-usage.json）`：不要手工删文件或清零，先停用 CDN 入口再修复；命令不会自动重建或清零已安装用量。
- `保护性停机: 是`：运行时受限或已停止，等待 `cdn-traffic-sync` 收敛（订阅已不可用时还会额外提示 `edit-sub`）。
- `CDN 流量保护定时器: inactive`：保护已失效，先修复定时器（`sudo easy_all apply` 会重装并校验其为 active）再使用 CDN。

### 6.3 各命令在保护停机时的准入

| 入口 | 待落实阻断（`blocked=true`、`enforced=false`）时的行为 |
| :--- | :--- |
| `cdn-traffic-sync`（timer 同源） | 先做受限安全恢复（XHTTP 503 + 受限 Xray + 真实 StatsService 可读），验收通过才采样、才可能解封；失败保留 pending 并返回 1 |
| `apply` / `apply-cloud` / `reality-target` | 先做同一受限安全恢复，成功后再强校验订阅并继续本机（或云端）事务；恢复失败非零停止。订阅损坏只让订阅降级为 `503`，不阻挡安全恢复，但整条命令仍报错并提示 `edit-sub` |
| `renew-cert` | 先只验证/部署证书并保持 `503`（不动 Xray），证书阶段完成后才做受限恢复；源站证书故障优先用它修复 |
| `edit-sub` | 走 §5.1 的保持阻断修复分支（不启动 Xray、不改用量） |
| `update-core` | 先非零拒绝（不下载、不替换、不重启），提示先 `cdn-traffic-sync`（订阅损坏先 `edit-sub`，证书故障先 `renew-cert`） |
| `status` / `show` / `subscription` | 只读，不清算、不启动服务 |
| `uninstall` | 不需要统计文件可读，照常卸载 |
| 定时重启 | 前置 `cdn-traffic-sync` 非零即不重启；cron 最终取锁后再只读复核 usage（结构合法、`protection_offline=false` 且 `blocked=enforced`），不满足则跳过重启并告警 |

### 6.4 故障后的收敛顺序
1. 证书导致受限启动失败：`sudo easy_all renew-cert`。
2. 订阅配置/产物损坏：`sudo easy_all edit-sub`。
3. 其余情况：`sudo easy_all cdn-traffic-sync`（或等下一轮 15 秒 timer 自动收敛）。

反复失败时 `journalctl -u easy_all-cdn-traffic-guard.service` 会给出阶段与原因；持续失败的机器会保持阻断与停机，不会自动解封，也不会把错误当作「额度已恢复」。

### 6.5 不要做的事
- 不要手工编辑或删除 `/etc/easy_all/cdn-traffic-usage.json` 来「恢复」CDN：缺失或损坏会被判为保护异常并拒绝操作。
- 不要指望 `apply`、`apply-cloud` 或 `update-core` 绕过阻断：它们同样受同一准入约束。
- 本机计数是**近似保护**，不是 AWS 账单真源：订阅下载、HTTP/TLS 开销与请求费、其他分发或其他机器的用量不在统计内，进程崩溃/关机窗口也可能漏计，因此不承诺零账单。

---

## 7. 卸载与清理

### 7.1 仅卸载本机（默认保留云端）
```bash
sudo easy_all uninstall
```
停止并删除 Xray、Nginx 站点、easy_all 自有配置、证书（含 easy_all 专用的 Certbot lineage 与 deploy hook）、CDN 流量保护定时器和定时任务，回收业务端口放行（`80`、`443`，模式 3 另含 `8443`），保留 UFW 启用状态、默认拒绝策略、SSH 放行与 Fail2ban 配置（`/usr/local/sbin/fail2ban-ufw-cidr.sh` 脚本保留），恢复安装前的 IPv6 配置。

- **默认保留云端资源**：CloudFront 分发、ACM 证书与 DNS 记录都不动，并先打印可识别的资源清单（分发 ID/域名、ACM ARN、源站 A 记录、节点/订阅 CNAME、validation CNAME）。本机状态删除后无法再用 easy_all 清理这些资源，只能到控制台处置。
- 前置初始化不回收：Zabbly 内核与 APT 仓库、Skyline Speeder 及其 fq 服务、`/etc/sysctl.d/99-easy_all-tcp.conf`、1GB Swap、系统依赖与 Nginx `worker_processes 1;` 收敛均保留。
- 保护停机（`protection_offline=true`、Xray 已停止）不阻挡卸载，也不要求统计文件可读。

### 7.2 完整卸载（含云端资源清理）
```bash
sudo easy_all uninstall --purge-cloud
```
在 §7.1 的本机卸载之前，先尝试清理 easy_all 自己创建的云端资源：

1. **归属校验**：CloudFront 必须同时满足 `Comment=easy_all-cloudfront-<节点域名>`、aliases 与本状态一致、ID 与状态一致；ACM 必须带 `easy_all=managed` 标记且状态/region/SAN 匹配。查询失败或归属不匹配一律保留并告警。
2. **分发**：先置 `Enabled=false`，等待部署完成，再用最新 ETag 删除。
3. **ACM**：确认 `InUseBy` 为空且带管理标记后才删除；分发删除失败时不会继续删证书。
4. **DNS**：只删注释、类型和目标都精确匹配的 A/CNAME 记录；复用第三方或无标记记录不删。
5. **ACM validation CNAME 默认保留**，输出会明确提示可由控制台核实后手工删除（同一验证记录可能被其他证书复用）。

- **云清理失败不阻挡本机卸载**：任一步失败只告警并打印残留 ID，本机卸载照常继续；命令不会声称「云端已全部清理完成」。
- 缺少 AWS 凭据时会要求交互输入；仍无凭据则云端清理记为失败，本机照常卸载。

### 7.3 独立清理 Cloudflare 残留
若 VPS 已销毁或状态丢失，可使用独立命令清理账户内 easy_all 标记的 Cloudflare 资源：
```bash
sudo easy_all purge-cloudflare --domain example.com
```
- 只处理 Cloudflare，**不会触碰 AWS**；正在运行的 CloudFront 链路若清掉节点/订阅 DNS 会中断，需要随后 `apply-cloud` 恢复。
- 支持平滑容错降级：Token 缺少 Rulesets 权限时会安全跳过规则清理并告警一次，已收集的 DNS 记录与 Cloudflare Origin CA 证书仍会正常清理。

### 7.4 旧版本状态与不完整新状态只能卸载重装
- 旧版 Cloudflare CDN 安装（`PROTOCOL=cdn` 或旧 `combined`，Cloudflare 代理回源链路）不被当前版本接管：任何应用、续签、更新核心、编辑订阅都会明确报错并提示 `sudo easy_all uninstall`，默认卸载保留云端资源。
- `PROTOCOL=cloudfront` 或 `combined-cloudfront` 但缺少新强制字段（例如旧 WIP 未落盘的 `CDN_PROVIDER`）同样不能安全接管；这类状态只允许**仅本机**清理，云元数据缺归属证明时保留并告警。
- 重装会产生新的 UUID、路径与 Token（模式 3 还有新的 Reality 密钥），客户端必须重新导入订阅。不要通过手改 `state.env` 的协议值来「升级」或「回退」。

---

## 8. 常见问题排查

| 现象 / 报错 | 常见根因与解决办法 |
| :--- | :--- |
| **SSH 断开后重连失败** | - 检查服务商后台云防火墙/安全组是否已放行 SSH 端口（默认 22）。<br>- 检查 UFW 状态及 Fail2ban 是否因多次认证失败暂时封禁了客户端 IP。 |
| **重跑提示 TCP 80/443 被占用** | 有 easy_all 残留时按提示执行 `sudo easy_all cleanup-partial`；只报了「easy_all 仅支持专用 VPS」说明占用者是第三方进程（多为本机自用 Nginx），先确认归属再处理。 |
| **安装中断提示「继续上次安装」** | 模式 2/3 的续装要求同一 Profile 且安装标记里 `CHAIN=cloudfront`，回车选择 `Y` 可复用已生成的源站证书、分发 ID、ACM ARN 与 Reality 密钥；选 `n` 则清理重装。旧版标记不参与续装。 |
| **CloudFront 返回 502** | 回源失败：源站 443 不可达（安全组未放行、Nginx 未运行），或 CloudFront 无法校验源站证书（源站证书过期/未覆盖源站域名）。先用 `sudo easy_all status` 看证书与服务状态，再用 `sudo easy_all renew-cert`、`sudo easy_all apply-cloud` 修复。 |
| **CloudFront 返回 503** | 多半是 CDN 用量达到 985 GB 触发的阻断，或 `protection_offline` 状态下的受限运行时。查看 `sudo easy_all status` 的 `blocked` / `enforced` / `protection_offline`；按 §6.4 顺序收敛，不要清空用量文件。 |
| **CloudFront 返回 403 / 404（订阅或健康检查）** | 源站头缺失或错误：XHTTP 位置返回 403，`/easy_all-health` 与 `/subscribe` 返回 404。确认分发行为仍转发自定义头 `X-Easy-All-Origin-Key`，且没有人手工改过 Nginx 站点。 |
| **TLS 正常但节点没有流量** | Host 重写链路被打断：Nginx 必须把 gRPC `Host` 固定重写为 CloudFront 节点域名（对应 Xray 的 `xhttpSettings.host`）。手工改过 Nginx、或分发行为被改成转发 viewer Host 都会导致 Xray 拒绝请求；恢复配置执行 `sudo easy_all apply`。 |
| **客户端提示证书错误** | 分清两套证书：**viewer 侧**用 AWS ACM（`us-east-1`，SAN 覆盖节点与订阅域名），**源站侧**用 Let's Encrypt（只覆盖源站域名）。客户端只校验 ACM；源站证书错误表现为 CloudFront 502 而不是客户端报错。不要在客户端加 `allowInsecure`/跳验证。 |
| **订阅下载失败或返回 403** | Token 失效（`edit-sub` 删掉了该用户）、UA 与实际下发格式不符，或订阅域名 CNAME 未指向分发。用 `sudo easy_all subscription` 取最新链接；必要时 `sudo easy_all apply-cloud` 收敛 DNS。CloudFront 模式下禁止用 `-k` 或跳过验证绕过证书问题。 |
| **`apply` / `apply-cloud` 报订阅配置损坏** | 状态里的 `SUBSCRIPTION_CONFIG` 无法解析。执行 `sudo easy_all edit-sub` 粘贴完整新配置；`uninstall` 与 `cleanup-partial` 仍可执行。 |
| **`update-core` 被拒绝** | 提示「CDN 流量保护仍待落实」时先执行 `sudo easy_all cdn-traffic-sync`；订阅损坏先 `edit-sub`，证书故障先 `renew-cert`。核心更新后订阅若刷新失败，会保留告警并提示 `apply`。 |
| **`renew-cert` 后仍提示证书问题** | 检查 `/etc/letsencrypt/live/easy_all_origin/` 是否已签发新 lineage；手动续签会抑制内置 deploy hook，由命令自身完成部署与验收。锁忙导致 hook 跳过时，重跑 `renew-cert` 会优先部署已有新 lineage，不重复申请。 |
| **订阅可下载但节点无法连接** | 1. 确认客户端内核版本是否过旧（Mihomo 建议 ≥ 1.19.9）；<br>2. 检查云服务商安全组是否放行了业务端口（`80` / `443`，模式 3 另含 `8443`）；<br>3. 模式 3 需在 `PROXY` 组里**手动**在直连与 CDN 节点之间切换，没有自动测速或兜底组。 |
| **升级后仍看到旧节点名/旧分组** | 旧订阅缓存或自定义模板写死了已删除的组名。在客户端刷新订阅并重新选择 `PROXY` 下的实际节点；模板问题用 `sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo.yaml easy_all edit-sub` 换回内置模板。 |
| **提示 CloudFront 状态不完整** | `PROTOCOL=cloudfront` / `combined-cloudfront` 缺强制字段（例如旧 WIP 状态）。当前版本只提供仅本机卸载：`sudo easy_all uninstall` 后重新安装，云端资源按需保留。 |
