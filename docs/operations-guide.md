# 运维指南

本文面向已经完成安装的用户。首次安装请从[项目首页](../README.md)开始。

## 更新与应用

更新 easy_all 项目代码：

```bash
sudo easy_all self-update
```

`self-update` 只替换已安装的项目代码，不修改 Xray、Nginx、订阅、系统参数或云端资源。
默认从 `main` 更新；验证待发布版本使用 `sudo easy_all self-update --dev`，其他分支使用
`sudo easy_all self-update --branch <分支>`。
代码包含配置生成变化时，再执行：

```bash
sudo easy_all apply
```

安装或 `apply` 会将 SSH 收敛到仅监听 TCP `65533`，并在 UFW 优先阻断 `22`。执行前先在
云安全组放行 `65533`，保留当前会话，另开终端使用 `ssh -p 65533 用户@服务器` 验证。
监听冲突、检查命令与恢复规则见[技术参考](technical-reference.md)。

`apply` 遇到配额统计或其他配置任务占用运行时锁时会立即报错；等待该任务结束后重新执行原命令即可。

`1.6.13` 为直连 Reality 增加第三档订阅输出：安装时可以选择「仅节点（默认）」「本机订阅」或
「Worker 订阅聚合」。Worker 聚合把公开订阅域名绑定到 Cloudflare Worker，另用同 Zone 的私有
节点源域名由 Cloudflare 代理回本机 `8443`，Nginx 仍是 Token 与配额的唯一真源；其余直连节点
写入聚合 JSON 的 `nodes`，Worker 按请求实时回源并在源不可用时返回 `502`。Reality 自托管订阅的
默认选项改为仅节点，与「多节点聚合」场景保持一致。已有部署执行 `sudo easy_all self-update`
即可，未主动执行 `update-sub` 的部署保持原模式与订阅 URL；状态版本升到 8，旧状态自动升级。

`1.6.12` 修复 Reality 部署订阅时验收偶发的 404：Nginx reload 未覆盖全部 worker 时，无效 Token 探测可能落到仍服务引导配置的旧 worker，现已对 404 短暂重试并在命中 403 后立即通过；源站证书复用同时要求状态中存在 Cloudflare 证书 ID 与到期时间，Reality 与 XHTTP 两个 Profile 一致。已有部署执行 `sudo easy_all self-update` 即可，无需重新执行 `apply` 或 `update-sub`。状态版本与订阅 URL 不变。

`1.6.11` 让 `update-core` 在核心验收通过后自动重新生成 Reality 自托管订阅，不再需要额外执行 `apply`；核心更新失败仍按原逻辑回滚，订阅重发失败时核心保持新版本并提示执行 `sudo easy_all apply`。已有部署执行 `sudo easy_all self-update`；状态版本与订阅 URL 不变。

`1.6.10` 修复 Xray 26.9.8 起 REALITY 服务端要求 `X25519MLKEM768` key share、而 mihomo 默认剥离导致的“握手成功但不走流量”：自托管订阅在本机 Xray ≥ 26.9.8 时写入 `support-x25519mlkem768: true`，Worker 聚合默认写入并可用 `supportX25519Mlkem768: false` 关闭。该字段需 mihomo 1.19.9+，旧 mihomo 内核会忽略。已有部署执行 `sudo easy_all self-update` 后 Reality 自托管订阅执行 `sudo easy_all apply`（核心低于 26.9.8 请先 `update-core`），Cloudflare 聚合订阅执行 `sudo easy_all update-sub` 重建 Worker。状态版本与订阅 URL 不变。

`1.6.9` 新增 `sudo easy_all reality-target <域名:端口>`，安装后可修改 Reality SNI 与回源目标；新目标沿用带 SNI 的 TLS 1.3 验收，失败自动恢复旧配置。存量部署无需重新执行 `apply`，需要更换伪装目标时再执行该命令并刷新客户端订阅；状态版本与订阅 URL 不变。

`1.6.8` 修复配额统计与 Xray `ExecStop` 写锁竞争导致的 15 秒死锁停顿，并兼容 systemd `deactivating` 状态避免服务关机/重启时流量统计丢失。已有部署执行 `sudo easy_all self-update` 并执行 `sudo easy_all apply`。状态版本与订阅 URL 不变。

`1.6.7` 补充中国电信天翼账号 `id6.me` 直连，本机号码一键登录不再因代理出口无法取号。
已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建内嵌模板。状态版本与订阅 URL 不变。

`1.6.6` 补充腾讯广点通图片域名 `ugdtimg.com` 直连，`pgdt.ugdtimg.com` 不再落入代理。
已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建内嵌模板。状态版本与订阅 URL 不变。

`1.6.5` 补充中国移动认证、HTTPDNS 与字节 SDK 域名的直连，避免这些国内服务在 fake-IP 下落入代理。
已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建内嵌模板。状态版本与订阅 URL 不变。

`1.6.4` 让单标签主机名与认证门户/连接性检测域名直连，并使用系统 DNS；单标签主机名不再落入代理。
已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建内嵌模板。认证门户检测域名（含 `connectivitycheck.gstatic.*`）改为直连后，
受限网络下 Android 可能显示“无网络”，这是本地探测的真实结果。

`1.6.3` 让默认与完整模板、经典模板补上国内 SDK 域名库，`cm-10-134.getui.com` 这类推送/统计域名不再落入代理。
已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建内嵌模板。首次启动会额外下载约 34 KB 的 `geosite-geolocation-cn.mrs`，失败时仍使用内联集合。

`1.6.2` 让默认模板加载国内域名库（约 11 万条），未收录的国内站点不再直接落入代理。已有部署执行
`sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建内嵌模板。状态版本与订阅 URL 不变；首次启动会下载约 535 KB 的
`geosite-cn.mrs`，失败时仍使用内联集合。

`1.6.1` 把 CN/LAN GeoIP 兜底改为只匹配已有真实 IP，未收录域名不再为 GeoIP 判断额外解析。
已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，
Cloudflare 聚合订阅再执行 `sudo easy_all update-sub` 重新构建内嵌模板。状态版本（Reality v7、
Cloudflare v9）与订阅 URL 不变，无需迁移。

`2026-10-14` 新增可选 Skyline Speeder，默认和旧状态继续使用 BBRv3。已有部署更新代码后执行
`sudo easy_all tcp skyline` 选择；已选择 Skyline 时执行 `sudo easy_all apply`，会核对并更新到项目
固定的 Skyline 版本。本次无需重建 Worker，现有订阅 URL、用户配置和状态（Reality v7、Cloudflare v9）均无需迁移。

此前的 `2026-10-13-v1` 修复聚合 Worker 的三处编辑器类型诊断，保持现有 IPv4 策略、上游错误提示和鉴权行为。若尚未应用该历史版本的 Worker 修复，执行 `sudo easy_all self-update` 后，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`，聚合配置选择“保留”，重新构建并部署 Worker；独立手工部署的 Worker 在其构建环境重新构建并部署。
源码版本使用 Git 标签标识；Worker 的 `X-Easy-All-Version` 是独立的构建版本，`apply` 不改变此响应头。
该历史版本修改了 Worker 运行源码，单独执行 `self-update` 不会更新线上 Worker；安装器与独立聚合构建均使用修复后的同一份公共源码。

从 `2026-10-11` 起，关闭或更换订阅后未能清理的旧 Worker 身份会保存在状态文件中。若提示旧资源尚未清理，恢复 API 权限或网络后运行 `sudo easy_all apply-cloud` 重试；`uninstall --purge-cloud` 也会重试，清理失败会停止卸载并保留本机状态。普通 `apply` 不执行该云端清理。旧版本已经丢失身份的孤立资源无法由该升级自动追溯，仍需在 Cloudflare 控制台核对并手工清理。

只更新订阅规则时：

```bash
sudo easy_all self-update
sudo easy_all update-sub
```

Cloudflare 模式保留现有订阅模式、Worker 名称、订阅域名、用户 Token 和配额；出现 Worker
聚合配置选项时选择 `1. 保留`。此命令会重新构建并部署 Worker，并更新本机订阅，
不需要再执行 `apply-cloud`。最后在客户端刷新订阅并重启代理内核。

默认发布的模板是 `templates/mihomo.yaml`（COMMON 精简规则），不需要额外参数。改用仓库内置的其他
模板（`templates/mihomo-common.yaml`、`templates/mihomo-classic.yaml`）或自定义模板时，在命令前
传入 `MIHOMO_TEMPLATE_SOURCE=<模板绝对路径或 HTTPS URL>`；Cloudflare 模式会重新构建并内嵌所选
模板。模板差异与内存实测见[客户端使用指南](client-guide.md#低内存客户端旧款-iphone)。

升级迁移：旧版默认是经典 geodata 模板，新版不传参数会使用 COMMON 精简版。旧路径
`templates/mihomo-common-lite.yaml` 已并入 `templates/mihomo.yaml`；从旧脚本或任务中删除该
`MIHOMO_TEMPLATE_SOURCE` 设置即可使用新默认，也可以把路径改为 `templates/mihomo.yaml`。
保留或回退经典规则时执行：

```bash
sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo-classic.yaml easy_all update-sub
```

Reality 自托管订阅会把选中的模板持久化到 `/etc/easy_all/mihomo-template.yaml`，之后的
`apply`、`update-sub` 和重启后的端口刷新都沿用该模板；更换模板时在命令前传入新的
`MIHOMO_TEMPLATE_SOURCE`，安装器会用新模板覆盖上述文件。该快照随发布原子替换，但不在
`update-sub` 失败回滚的恢复范围内：回滚只恢复 `state.env`、运行配置、订阅、证书、UFW 与
crontab，快照可能比回滚后的状态新（后续 `apply` 或重启刷新会使用新模板）。Cloudflare 聚合订阅仍需在
`update-sub` 时传入模板，以重建并内嵌所选规则的 Worker。客户端使用同一聚合订阅时，只需在管理该
Worker 的服务器更新一次，再让各客户端刷新订阅并重启内核；其他独立订阅需要分别更新。

若代码推送在 `dev`，第一条命令改为 `sudo easy_all self-update --dev`。`self-update` 或
`apply` 单独执行都不会更新 Cloudflare Worker 内嵌的规则。独立手工部署的 Worker 则需要
在其构建环境重新构建并部署；VPS 无法自动更新未由安装器管理的 Worker。

更新 Xray 核心：

```bash
sudo easy_all update-core
```

Reality 自托管订阅的内容取决于本机核心版本（26.9.8 起才写入 `support-x25519mlkem768`），
因此 `update-core` 在验收通过后会自动重新生成订阅。仅当重发失败时才会提示再执行
`sudo easy_all apply`；核心更新本身失败时会回滚二进制、版本文件与运行时配置，不重发订阅。

### `apply` 与 `apply-cloud`

`apply` 读取 `/etc/easy_all/state.env`，按现有模式和参数重新生成本机配置。它不会改变模式、
UUID、节点域名或传输路径，也不会重新询问订阅模式。

- Reality：同步本机系统、Xray、订阅、UFW 和 Fail2ban；自托管订阅时也同步其 Cloudflare
  DNS、Origin CA 与 Strict TLS。
- Cloudflare：同步本机 Xray、Nginx、订阅、UFW、Fail2ban 和精选 IP 缓存，不修改 Worker。
- Trojan：重新校验证书（必要时续期并重启 Xray）、重建回落站点与 Nginx 配置、同步 UFW/NAT、
  DNS 与续期定时器；失败时恢复旧 Xray 与 Nginx 配置。
- 所有模式都会在失败时恢复已备份的本机配置。

`apply-cloud` 仅适用于 Cloudflare 模式。它在应用本机配置后同步 DNS、Origin CA、边缘规则和
Worker。已成功变更的云资源不会自动回滚，只应在确实需要同步云端配置时使用。

配置更新、核心更新和配额统计共用一把写锁；另一个写操作运行时，新操作会立即停止。

## 命令

| 命令 | 作用 |
| --- | --- |
| `show` | 显示当前 VLESS 链接和 Mihomo 节点片段。 |
| `subscription` | 显示订阅部署状态和每个用户的订阅地址。 |
| `status` | 显示当前 TCP 加速、协议、服务、端口和订阅状态。 |
| `self-update [--dev\|--branch <分支>]` | 更新项目代码；默认 `main`，`--dev` 使用 `dev`。 |
| `apply` | 重新应用当前配置。 |
| `tcp [bbrv3\|skyline]` | 选择 TCP 加速；无参数时显示交互菜单，默认 BBRv3。 |
| `reality-target [域名:端口]` | 修改 Reality SNI（伪装目标）并重新应用，仅 Reality 模式；无参数时交互输入。 |
| `apply-cloud` | Cloudflare 模式下同步本机和云端资源。 |
| `update-sub` | 管理订阅、用户、配额和 Worker 聚合配置。 |
| `refresh-cdn-ips` | Cloudflare 模式重新筛选优选 IP 并更新订阅。 |
| `update-core` | 更新当前模式核心：Reality/Cloudflare 更新 Xray，Mieru 更新官方 mita。 |
| `rotate-dynamic-ports` | 立即刷新直连模式的 NAT 规则（Mieru 使用 `50000-50512` → 内部端口）。 |
| `renew-cert` | 轮换当前模式证书；Trojan 模式强制重新签发 Let's Encrypt 证书。 |
| `cert-renew` | 内部命令：由 `easy_all-cert-renew.timer` 调用，仅 Trojan 模式。 |
| `quota-status` | 查看每个用户的月度配额和流量。 |
| `quota-set <用户> <GB>` | 修改已有用户额度，`0` 表示不限量。 |
| `quota-reset <用户>` | 清零指定用户本月流量。 |
| `uninstall` | 卸载本机资源；`--purge-cloud` 同时清理本工具创建的云资源。 |
| `help` | 显示命令帮助。 |

## TCP 加速选择

首次安装直接回车使用 BBRv3。已有部署可用 `sudo easy_all tcp` 打开选择菜单，或明确指定：

```bash
sudo easy_all tcp skyline
sudo easy_all tcp bbrv3
```

**只有在丢包率极高且确认为非拥塞随机丢包时才选择 Skyline Speeder。** 拥塞、队列溢出造成的
丢包不适用，普通线路继续使用 BBRv3。默认首段冗余会增加出站流量；计费线路需评估成本。
Skyline 是服务器发送端加速，客户端不需要额外安装，独立 Worker 节点不会受益。

Skyline 启用时要求当前运行 Linux 6.12+、可读的 `/sys/kernel/btf/vmlinux` 和统一 cgroup v2。
当前内核低于 6.12 时，会先安装或升级兼容的 XanMod LTS；即使已有旧版元包也会尝试升级，
并验收实际安装的内核版本。此时暂不重启，继续完成节点、订阅等安装，期间暂用 BBR，状态显示
`Skyline Speeder: pending-reboot`。保存链接后重启一次，开机任务会自动安装并启用 Skyline，
不必重新输入命令，也不会再次自动升级内核或重启。自动安装期间显示 `pending-activation`，
完成后应显示 `Skyline Speeder: active`。开机安装需要联网；Debian 12 会从源码编译 Rust/BPF，
可能耗时较长并占用 CPU、内存和磁盘，期间继续使用 BBR。可查看进度：

```bash
sudo journalctl -u easy_all-skyline-setup.service -b -f
```

开机任务遇到配额统计等任务占用运行时锁时，最多等待 60 秒。等待超时、缺少 BTF、cgroup v2，
或其他安装/启用失败时，任务会停止，保留 BBR 回退及重试状态；`status` 显示 `degraded` 和
当前实际拥塞控制。根据日志修复后执行 `sudo easy_all tcp skyline` 重试，或执行
`sudo easy_all tcp bbrv3` 切回 BBRv3。
切回 BBRv3 会取消待执行的开机安装任务，并停用 Skyline 两个服务及其开机启动，
后续 `apply` 保留选择；此操作不会卸载 Skyline。

Skyline 版本跟随 easy_all 的固定版本。更新项目代码后执行 `sudo easy_all apply` 即可就地升级，
无需先卸载；手工安装的其他版本也会被替换，更新版本可能被降级到项目固定版本。
版本及安装记录匹配时复用已有二进制。旧安装缺少版本记录时，首次应用会重新校验
并安装一次；Debian 12 可能再次编译源码。升级失败保留已验证的安装器供重试和卸载。
卸载 easy_all 时会调用官方卸载器清理托管的 Skyline 安装。

## 轮换 UUID

`apply` 默认保留 UUID。需要轮换时：

```bash
sudo env VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)" easy_all apply
```

旧 UUID 会立即失效。随后运行 `easy_all show`，或让客户端重新拉取订阅。

## 管理订阅用户

统一使用：

```bash
sudo easy_all update-sub
```

Reality 模式会先让你选择订阅输出（`1` 仅节点、`2` 本机订阅、`3` Worker 聚合，默认保持当前值）；
Cloudflare 模式仍是 `1` 部署 Worker / `2` 不部署。

该命令接收的是完整用户清单：保留的用户必须继续填写，新增用户名会创建用户，省略已有用户名
会删除用户。完成后运行 `sudo easy_all subscription` 查看最终地址。

用户名只能包含字母、数字、点、下划线和短横线，长度为 `1-64`。Token 只能使用 URL 安全字符，
长度为 `8-128`，且必须唯一。

### 未启用月度配额

`ALLOWED_TOKENS` 只维护订阅访问 Token；用户名是管理标签，不是 Xray 用户身份。先运行
`sudo easy_all subscription` 找到要保留的 Token，再提交完整字典。例如保留 `owner` 并新增
`user1`：

```bash
sudo env ALLOWED_TOKENS='{"owner":"existing-owner-token","user1":"new-user1-token"}' \
  easy_all update-sub
```

所有 Token 映射到同一份订阅和同一个 `VLESS_UUID`，不区分 Xray 用户、流量统计或超额停用。
删除 Token 只阻止继续下载订阅，不会使已经下发的 UUID 失效。需要逐用户独立 UUID 和流量统计时，
应启用月度配额。

### 已启用月度配额

配额 JSON 同时定义完整用户清单。`0` 表示不限量：

```bash
sudo env ENABLE_MONTHLY_QUOTA=2 \
  MONTHLY_QUOTAS_GB='{"owner":0,"user1":100,"user2":50}' \
  easy_all update-sub
```

脚本会为新增用户生成独立 Token、UUID 和 `easy_all.<用户名>` 格式的 Xray `email`；同名用户
复用现有凭据。覆盖某个 Token 时：

```bash
sudo env ENABLE_MONTHLY_QUOTA=2 \
  MONTHLY_QUOTAS_GB='{"owner":0,"user1":100}' \
  QUOTA_TOKEN_OVERRIDES='{"user1":"my-user1-token"}' \
  easy_all update-sub
```

Token 用于下载对应订阅，UUID 用于 VLESS 鉴权，`email` 用于 Xray 流量计数。托管 Nginx 对
`/subscribe` 关闭访问日志，避免查询参数中的 Token 写入日志。

启用配额时还需设置 VPS 开通日期，完整日期保存在状态中，其中“日”作为以后每个月的 UTC
账期边界。开通日为 29、30 或 31 而某个月没有该日期时，使用该月最后一天。

查看和调整已有用户：

```bash
sudo easy_all quota-status
sudo easy_all quota-set user1 200
sudo easy_all quota-reset user1
```

`quota-set` 不清零已用量；新额度不高于已用量时用户立即停用，调高后可立即恢复。
`quota-reset` 只清零指定用户当前账期的用量，不修改额度和凭据。

配额任务每分钟累计 Xray 看到的上下行载荷，属于近实时控制，不是精确计费系统。写锁被其他任务
占用时本轮统计最多等待 15 秒后跳过，并在锁释放后由定时任务补算（未重启 Xray 时）；
`quota-status` 会提示统计暂停。若持锁的长任务结束后 Xray 已重启，自上次成功统计以来的整个
未同步窗口可能丢失。用户分享自己的 UUID 或订阅地址后，相关流量仍计入该用户。

## Worker 聚合

Reality 直连模式也可以选择 Worker 聚合（安装菜单第 `3` 项）。它会占用同 Zone 两个一级域名：

- 公开订阅域名：绑定 Worker 的 Custom Domain，客户端只访问 `https://<公开域名>/subscribe`；
- 私有节点源域名：Cloudflare 代理到本机 `8443`，仅放行 Cloudflare 回源，
  路径 `/subscribe` 还要求独立的 `X-Easy-All-Worker-Source` 密钥，因此不能当公开订阅地址分发。

Nginx 仍负责 Token 校验和配额，所以 Worker 只是下发入口，不缓存节点、不绕过配额。源不可达时
Worker 返回 `502`；Token 被源拒绝时返回 `403`。本机 Reality 节点来自私有源，其余直连节点写在
聚合 JSON 的 `nodes` 中（名称必须互不重复，且不能与本机节点同名）。直连节点（Reality、Trojan 与
Mieru）的展示名保持原样并直接列在 `PROXY`，不会被改名成 `🇺🇸优选N` 或放进隐藏测速组。

`nodes` 支持三种直连节点，`fallbackCdnNodes` 只接受 VLESS/CDN 兜底节点；所有 `host` 都可填
公网 IPv4 或 DNS only 域名，但不支持 IPv6 literal：

```json
{
  "nodes": [
    {
      "type": "vless",
      "security": "reality",
      "network": "tcp",
      "name": "Reality example",
      "host": "reality.example.com",
      "uuid": "00000000-0000-4000-8000-000000000001",
      "sni": "www.example.com",
      "pbk": "Reality 公钥",
      "sid": "0123456789abcdef",
      "fp": "chrome"
    },
    {
      "type": "trojan",
      "name": "Trojan example",
      "host": "trojan.example.com",
      "port": 443,
      "password": "replace-with-a-trojan-password",
      "sni": "trojan.example.com",
      "alpn": ["http/1.1"],
      "fp": "chrome"
    },
    {
      "type": "mieru",
      "name": "Mieru example",
      "host": "mieru.example.com",
      "portRange": "50000-50512",
      "username": "example-mieru-user",
      "password": "replace-with-a-long-mieru-password",
      "transport": "TCP",
      "multiplexing": "MULTIPLEXING_LOW",
      "trafficPattern": "CLlgEAA="
    }
  ]
}
```

Trojan 节点规则：

- 只允许写在 `nodes`；写进 `fallbackCdnNodes` 会被直接拒绝，避免被改名成 `🇺🇸优选N` 并塞进隐藏测速组。
- `password` 必须是 8-64 位字母、数字或 `.` `_` `~` `-`；`sni` 缺省等于 `host`；端口缺省 `443`；
  均不支持 IPv6 literal，`ipVersion` 强制 `ipv4`。
- `alpn` 只能是 `http/1.1` 或 `h2`，可写成数组或逗号分隔字符串，省略时不输出（由客户端和服务端协商）。
- Mihomo 输出固定 `type: trojan`、`network: tcp`、`udp: true`、`skip-cert-verify: false`；
  base64 输出为 `trojan://<密码>@<域名>:<端口>?security=tls&type=tcp&sni=...#名称`。
- 从 Trojan 节点服务器执行 `easy_all show` 复制密码、域名和端口，填入任意一台已部署 Worker 聚合的
  Reality/Cloudflare 节点即可统一分发；Trojan 模式本身不部署 Worker 与在线订阅。

Mieru 节点规则：

- 只允许写在 `nodes`；写进 `fallbackCdnNodes` 会被直接拒绝。`host` 可为 IPv4 或 DNS only 域名。
- `port` 与 `portRange` 必须且只能提供一个：`port` 为单个端口（1-65535），`portRange` 形如
  `50000-50512`；直连模式推荐 `portRange: "50000-50512"`。`username` 与 `password` 必填，分别限制为
  1-64 与 8-64 位字母、数字或 `.` `_` `~` `-`；`transport` 只能是 `TCP`；`multiplexing` 可省略
  （`MULTIPLEXING_OFF`/`LOW`/`MIDDLE`/`HIGH`，默认 `LOW`）。
- `trafficPattern` 可省略，取 `easy_all show` 中 `traffic-pattern:` 的值（`mita export traffic-pattern`
  导出的标准 base64）；`mtu` 可省略（1280-1500，默认 1400，只写入 `mierus://` 链接，Mihomo 节点不输出）；
  `udp` 默认 `true`。
- Mihomo 输出 `type: mieru`、`transport: TCP`、`udp`、`username`、`password`、`multiplexing` 与可选
  `traffic-pattern`；base64 输出
  `mierus://<用户名>:<密码>@<host>?mtu=1400&multiplexing=...&port=50000-50512&profile=default&protocol=TCP`。
- 从 Mieru 节点服务器执行 `easy_all show` 复制用户名、密码、域名或 IPv4、端口范围与可选 traffic-pattern，
  填入任意一台已部署 Worker 聚合的 `nodes` 即可统一分发；Mieru 模式本身不部署 Worker 与在线订阅，
  也不参与 CDN 自动命名或测速组。

切换订阅输出或更换域名时，`update-sub` 会先部署新模式，再清理上一模式的 Worker、Custom Domain、
Origin CA、Strict TLS 规则和源站 DNS。Worker 名称在安装后不能就地改名，需要重新安装。
本机订阅的橙云记录与 Worker Custom Domain 不能共用同一个主机名，因此在本机订阅与 Worker 聚合
之间切换时，`update-sub` 会要求重新输入未被占用的公开订阅域名和私有节点源域名。

Cloudflare 模式部署订阅时，Worker 使用与节点域名不同的同 Zone 一级子域。选择聚合后输入一份
不含 `vpsSubUrl` 的 Worker 聚合 JSON；结构参考
[`worker-src/config.example.json`](../worker-src/config.example.json)。

安装器保留其中的 `nodes` 和 `fallbackCdnNodes`，并自动注入本机私有源。
若配置包含 `allowedTokens`，它会覆盖前一步设置的 Token。启用配额时，其用户名必须与配额用户
完全一致。

Cloudflare 模式还可部署独立的纯 Worker TCP 兜底节点。Mihomo 订阅将 6 个 XHTTP 节点放入
`🇺🇸白天首选`，将最多 6 个经独立探测成功的纯 Worker 优选 IPv4 放入 `🇭🇰CF`；两个组都使用
URL-Test 自动测速并设置 `hidden: true`，作为 PROXY 内的选项，不单独展示。
所有代理流量（包括 YouTube）统一使用 PROXY 当前选择。纯 Worker 不发布域名入口，
其流量不经过 VPS，也不计入 VPS 用户配额。
测速超时统一为 5 秒。规则模式下，代理流量的 QUIC 拒绝不受手动节点选择影响。
纯 Worker 节点全面使用 XHTTP stream-one 原生流传输，TCP 两端通过原生 Stream `pipeTo()`
传递背压，支持超过 8 MiB 的持续大文件下载，不保留旧 WebSocket 模式。stream-one 的全部上行
位于单个 HTTP POST 请求体内，因此仍受 Cloudflare 套餐的请求体大小限制（Free/Pro 通常为
100 MB）；大文件上传应改用 VPS 节点。客户端 XMUX 最多建立 4 条底层 HTTP/2 连接，
避免多个并发代理请求全部挤在同一条 TCP 连接上。
新配置的纯 Worker 默认就近运行（`WORKER_BACKUP_PLACEMENT=off`）。已有香港定向配置不会自动覆盖；
如需比较就近执行与香港定向的速度，在 `/etc/easy_all/state.env` 将该项改为 `off`，然后运行
`sudo easy_all apply-cloud` 重新部署。保留原值 `aws:ap-east-1` 可恢复香港定向；两者均不保证固定出口 IP。
仅刷新客户端订阅不会更新 Worker 转发代码；更新 VPS 上的项目代码后，需重新部署纯 Worker。

停用或更换兜底 Worker 时，旧资源先记入 `state.env` 的 `WORKER_BACKUP_RETIREMENTS`，
等新订阅和状态提交后才删除。部分删除失败不会回滚到已失效的旧节点，
下次 `apply-cloud` 会按账户、名称和域名 ID 重试清理。
若更新失败且旧 Worker 部署也无法恢复，部署版本快照保存在
`/etc/easy_all/recovery/backup-worker-deployment.*`（权限 `0600`），退出清理不会删除。

已有部署只需同步这一订阅逻辑时执行：

```bash
sudo easy_all self-update
sudo easy_all apply-cloud
```

尚未启用独立 Worker 时，运行 `sudo easy_all update-sub`，在交互流程中启用并提供一个区别于
节点域名和订阅域名的同 Zone 一级域名。

## 证书与 Reality 动态端口

Reality 数据流量直连 VPS `443`，只有订阅回源 HTTPS 使用 Cloudflare Origin CA 和 VPS
`8443`：本机订阅模式的回源域名就是公开订阅域名，Worker 聚合模式则是私有节点源域名。
证书仍匹配回源域名且剩余至少 30 天时，`apply` 不重复签发；需要强制轮换时执行
`sudo easy_all renew-cert`。

Reality 动态端口范围为 `10000-62703`（覆盖整年 366 天），每小时提供 6 个端口并在每次订阅请求时按时间挑选下发。
UFW NAT 通过单条端口范围规则整段转发到 `443`（并对落在该范围内的 SSH 端口前置 `RETURN` 豁免），不会生成数万条单端口 allow 规则。
安装和正常 `apply` 会立即生成并加载整段规则；即使在 `11:30` 安装，也无需等待整点。
UFW 持久化这些规则并在开机时加载，受管 cron 使用单个 `@reboot` 任务再次刷新整段范围，替换旧的每小时任务。
每日定时重启前不再刷新 NAT 或订阅，避免刷新失败阻止重启。固定 `443` 模式会移除受管动态端口任务。
云安全组或服务商防火墙必须额外放行原始目标 TCP `10000-62703`；只放行 `443` 无法让动态端口到达 VPS。
VPS 上的 UFW 在 NAT 重定向后按 `443` 规则放行，SSH `65533` 不在动态范围内。

Reality 自托管订阅通过 Nginx njs 在每次 GET/HEAD 中读取当前用户模板，并按与 Worker 相同的
上海时间算法选择端口；这是时间决定的六槽位选择，重复时间可以选中同一端口。固定 `443` 模式
始终下发 `443`。DNS 监听、其他节点等模板端口保持原值。开机刷新仍会重新生成已部署的订阅模板，
每次请求的六槽位端口选择独立于 cron，不依赖模板重发。

全新安装的 Debian 12/13 Reality 自托管订阅使用系统仓库 `libnginx-mod-http-js`。
安装与正常 `apply` 原子安装本服务脚本和两个端口模板，再运行 `nginx -t` 和本机
Base64、YAML、HEAD 验收；模块缺失或未加载会使操作失败。配额重建使用同一 njs 配置及
已安装依赖。

模板读取或结构校验失败时，订阅返回纯文本 `503 Subscription unavailable`。
订阅三个 locations 同时关闭访问及错误日志，避免 query 中的凭据进入日志；诊断时检查无凭据的
`/easy_all-health`、`sudo nginx -t` 和文件权限，再运行 apply 重新生成。不要使用带 token 的 verbose
请求或把订阅正文贴到日志中。

apply 失败会恢复原完整 Nginx 配置、订阅文件、证书及 njs 脚本（原先缺失则删除），然后校验并
重载；系统共享的 njs 包保留。link 模式、新装失败和卸载会先撤销引用配置，再清理本服务脚本，
保留共享包。恢复时使用完整事务备份；不能只删除脚本而保留 Nginx import。


### 修改 Reality SNI

Reality 的 SNI 与回源目标由同一个值决定，安装后可用 `reality-target` 修改：

```bash
sudo easy_all reality-target                      # 交互输入，默认显示当前值
sudo easy_all reality-target www.example.com:443  # 直接指定
```

新目标先接受带 SNI 的 TLS 1.3 握手和 ASN 比对，再重写 Xray 配置、重启服务；部署自托管
订阅时再重新生成订阅。握手验收失败时自动恢复旧配置，状态文件保持旧值。订阅重发失败或中断
时服务端已是新目标，重跑同一条命令不会重复切换，并会提示执行 `sudo easy_all apply` 补齐订阅。
修改后必须让客户端刷新订阅或重新导入节点：旧配置仍带旧 SNI，服务端 `serverNames` 不认，
表现是 TCP 与 TLS 都正常但不走流量。使用聚合配置下发节点的部署，还需同步该配置里的 `sni`
并重新构建 Worker。

目标域名必须支持 TLS 1.3，建议同时支持 HTTP/2，且不能套 CDN 代理；目标在大陆的可达性需自
行确认，因为客户端 TLS ClientHello 里的 SNI 就是它。

## Trojan 直连

模式 3 的入口只有 TCP `443`：Xray 在 TLS 上接收 Trojan，其余流量交给
`127.0.0.1:8080` 的 Nginx 静态站点。Nginx 不监听公网地址，UFW 只需要放行 `443` 与 SSH。
直接用浏览器访问 `https://节点域名` 会看到站点首页，这是预期行为，而不是“被墙”或“配置错误”。

端口模式：

- 固定 `443`：只开放 `443`。
- `dynamic`（默认）：UFW NAT 用单条规则把 `10000-62703` REDIRECT 到 `443`，范围内任意端口都能
  连接；安装、`apply` 与受管 `@reboot` 任务都会刷新整段规则，也可手工执行
  `sudo easy_all rotate-dynamic-ports`。云安全组同样要放行这段原始目标端口，只放行 `443`
  时只有 `443` 可用。

证书：

- 签发与续期都走 Cloudflare DNS-01，客户端是固定版本 lego，归档经 Release 内的 SHA256
  校验后安装到 `/etc/easy_all/acme/`。
- 证书与私钥发布到 `/etc/easy_all/certs/fullchain.pem`、`private.key`（`0600`）。
  `easy_all-cert-renew.timer` 每天两次运行 `easy_all cert-renew`，未到续期时间不重启服务。
- Cloudflare API Token 保存在 `/etc/easy_all/acme/cloudflare-dns.env`（`0600`），只用于
  DNS-01 挑战；卸载会删除该文件，`--purge-cloud` 还会删除安装器托管的 A 记录。
- 需要强制重签时执行 `sudo easy_all renew-cert`；如果 Token 已失效，先重新安装或手工更新
  该文件。

诊断顺序：`sudo easy_all status` 查看服务、监听、证书到期与回落站点是否 `200 OK`；
`sudo nginx -t` 校验回落站点配置；`ss -ltn 'sport = :8080'` 确认 Nginx 只监听回环地址；
`journalctl -u easy_all-xray -n 100` 检查 Xray 日志；`systemctl status easy_all-cert-renew.timer`
查看续期计划。`dynamic` 模式还可用 `sudo iptables -t nat -L PREROUTING -n -v` 确认整段
REDIRECT 已加载。

## Mieru 直连

模式 4 使用上游 [mieru](https://github.com/enfein/mieru) 的官方服务端 `mita`，不引入证书、Nginx
或订阅（域名可选，使用 DNS only）：

- 安装器从 GitHub Release 读取最新版本，下载 `mita_<版本>_amd64.deb` 与同目录
  `.sha256.txt`，校验 SHA256 后才用 `dpkg -i` 安装；已有 mita 软件包或
  `/etc/mita/server.conf.pb` 时拒绝安装，避免覆盖其他部署。
- 服务器配置由官方 `mita apply config` 写入：内部 TCP 端口（默认 `2090`）、随机用户名与密码、
  `mtu=1400`、`dns.dualStack=PREFER_IPv4`，以及随机 `seed` 的 `trafficPattern`。随后
  `mita stop`/`mita start` 重启代理。
- 对外端口范围为 TCP `50000-50512`：UFW 在 `before.rules` 用单条
  `-A PREROUTING -p tcp --dport 50000:50512 -j REDIRECT --to-ports 2090` 把整段转发到内部端口，
  mita 只监听一个端口，避免创建五万多个 listener。客户端拿到范围后每条新连接随机选端口；
  云安全组必须放行 `50000-50512`，UFW 过滤规则只需放行内部端口与 SSH。
  `easy_all rotate-dynamic-ports` 只重建并刷新这条 NAT 规则，不做定时换端口；`@reboot` 任务在
  重启后自动刷新。
- 连接地址默认自动探测公网 IPv4，也可输入 DNS only / 灰云域名；客户端 JSON 相应写入
  `domainName`，Mihomo 与 `mierus://` 直接使用该域名，仍拒绝 IPv6 literal。
- 运行验收要求 `mita status` 为 `RUNNING` 且端口处于监听；`easy_all apply` 会重新渲染配置并
  重启，失败时恢复上一份 `server_config.json`。
- 客户端材料保存在 `/etc/easy_all/mieru/client_config.json`（`0600`）；Mihomo 片段与
  `mierus://` 链接中的 `traffic-pattern` 由 `mita export traffic-pattern` 生成，与服务端配置一致。
- 本模式不部署在线订阅和 easy_all 配额，`update-sub` 与 `quota-*` 会明确拒绝；需要在线订阅或配额
  请使用 Reality 模式。`rotate-dynamic-ports` 只刷新 NAT 范围，不做定时换端口；`renew-cert` 不适用。
- `easy_all update-core` 会重新下载并校验最新官方 mita 包，升级后重新应用配置并验收；升级失败时
  保留软件包升级结果并提示检查，不会回滚到旧 mita 版本。
- 卸载会先恢复安装前 SSH 与防火墙状态，再 `dpkg --purge mita`，并按官方卸载步骤删除 `/etc/mita`、
  `/var/lib/mita`、`/var/run/mita` 与 mita 用户/组，最后删除 `/etc/easy_all`。如果只想保留 mita 数据，请先备份 `/etc/mita`。

日常诊断：`sudo easy_all status` 查看 mita 服务、版本、状态与端口；`sudo mita describe config`
查看已生效的服务器配置；`sudo mita describe effective-traffic-pattern` 查看实际 traffic-pattern；
`journalctl -u mita -n 100` 查看服务日志；`ss -ltn 'sport = :2090'` 确认内部监听；
`sudo iptables -t nat -L PREROUTING -n -v` 确认 `50000:50512` 的 REDIRECT 已加载。
客户端与服务端时间必须同步，偏差超过数分钟会无法解密。端口范围较大时，客户端会展开全部
端点用于随机选择；建议在桌面客户端使用，移动端如感内存压力可改用单个 `port`。

## 卸载

默认只删除本机资源：

```bash
sudo easy_all uninstall
```

卸载须先恢复并验证安装前 SSH 监听，再撤销并验证受管 deny22，之后才移除65533放行和本地
状态；原配置使用 `22` 时，成功恢复会重新允许 `22`。SSH 恢复或 deny22 撤销失败会中止清理，
恢复 `65533` 配置并保留其放行及备份，请通过 Console 检查后重试，不能视为卸载成功。

同时清理本工具创建的远端资源：

```bash
sudo easy_all uninstall --purge-cloud
```

远端清理会校验资源所有权与当前值，永不删除 DNS Zone，也不触碰没有 easy_all 标记的 DNS
或包含其他规则的 ruleset。Zone 级 HTTP/2 和 gRPC 开关不会自动还原，操作完成后仍应到
Cloudflare 控制台复核。

## 状态文件

主要路径：

```text
/etc/easy_all/state.env
/etc/easy_all/quota-usage.json
/etc/easy_all/globalping.token
/etc/easy_all/cloudflare-cdn-ips.json
/etc/easy_all/xray/config.json
/etc/easy_all/certs/
/var/www/easy_all/subscriptions/
/etc/nginx/conf.d/easy_all.conf
/etc/easy_all/acme/             # Trojan：lego、Token 与证书安装钩子
/var/www/easy_all/site/         # Trojan：回落静态站点
/etc/easy_all/mieru/            # Mieru：server_config.json 与 client_config.json
/etc/mita/                      # Mieru：mita 守护进程配置
```

Globalping Token 单独保存在 `/etc/easy_all/globalping.token`，权限为 `root:root 0600`。
`WORKER_AGGREGATION_CONFIG={...}`、`SUB_SOURCE_DOMAIN`、Worker 名称与 Custom Domain ID 保存在
root-only 状态中，`/etc/easy_all/worker.js` 是已构建的 Worker 产物（同样 `0600`），不要提交或公开。
状态文件由安装器维护，不应手工修改。

## 常见问题

| 现象 | 处理 |
| --- | --- |
| 本机运行后提示系统不支持 | 命令必须在 VPS 的 SSH 或网页终端运行。 |
| SSH 断开或重启后无法登录 | 使用服务商 Console/VNC 检查 SSH 端口、UFW 和安全组。 |
| Zone 不是 Active | 等待 Cloudflare Zone 生效并检查名称服务器。 |
| 提示未开启 gRPC | 在 Zone 的 Network → gRPC 手动开启后重试。 |
| API Token 权限不足或 DNS 冲突 | 按[前置准备手册](preparation-guide.md)核对权限并换用未占用的一级子域。 |
| Globalping 额度不足 | 等额度恢复后执行 `sudo easy_all refresh-cdn-ips`；与当前入口策略兼容的缓存会继续使用。 |
| `status` 显示 `pending-reboot` | 执行 `sudo reboot`，重新登录后确认 `BBRv3: active`。 |
| 想更换伪装目标（SNI） | 执行 `sudo easy_all reality-target <域名:端口>`，再按部署方式刷新订阅或重新导入节点。 |
| 浏览器打开节点域名显示正常站点 | Trojan 模式的预期行为：非 Trojan 流量回落到静态站点。 |
| Trojan 节点握手成功但不走流量 | 确认客户端密码、SNI 与 `alpn` 和 `easy_all show` 输出一致；证书过期会让所有客户端失败，先看 `sudo easy_all status` 的证书到期时间。 |
| Trojan 证书续期失败 | 检查 `/etc/easy_all/acme/cloudflare-dns.env` 中的 Token 是否仍有 Zone:DNS:Edit 权限，再执行 `sudo easy_all renew-cert`。 |
| 订阅能下载但节点无法连接 | 先看[客户端指南](client-guide.md)，再检查 Cloudflare gRPC 和 Xray/Nginx 日志。 |
| Reality 节点握手正常但不走流量 | 确认服务端核心与客户端内核版本：Xray ≥ 26.9.8 需订阅带 `support-x25519mlkem768`（mihomo ≥ 1.19.9 生效），并检查订阅是否为最新生成的。 |
