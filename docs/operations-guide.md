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

`apply` 遇到配额统计或其他配置任务占用运行时锁时会立即报错；等待该任务结束后重新执行原命令即可。

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

模板选择不持久化，后续重新生成订阅时仍须传入相同参数。客户端使用同一聚合订阅时，只需在管理该
Worker 的服务器更新一次，再让各客户端刷新订阅并重启内核；其他独立订阅需要分别更新。

若代码推送在 `dev`，第一条命令改为 `sudo easy_all self-update --dev`。`self-update` 或
`apply` 单独执行都不会更新 Cloudflare Worker 内嵌的规则。独立手工部署的 Worker 则需要
在其构建环境重新构建并部署；VPS 无法自动更新未由安装器管理的 Worker。

更新 Xray 核心：

```bash
sudo easy_all update-core
```

### `apply` 与 `apply-cloud`

`apply` 读取 `/etc/easy_all/state.env`，按现有模式和参数重新生成本机配置。它不会改变模式、
UUID、节点域名或传输路径，也不会重新询问订阅模式。

- Reality：同步本机系统、Xray、订阅、UFW 和 Fail2ban；自托管订阅时也同步其 Cloudflare
  DNS、Origin CA 与 Strict TLS。
- Cloudflare：同步本机 Xray、Nginx、订阅、UFW、Fail2ban 和精选 IP 缓存，不修改 Worker。
- 两种模式都会在失败时恢复已备份的本机配置。

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
| `apply-cloud` | Cloudflare 模式下同步本机和云端资源。 |
| `update-sub` | 管理订阅、用户、配额和 Worker 聚合配置。 |
| `refresh-cdn-ips` | Cloudflare 模式重新筛选优选 IP 并更新订阅。 |
| `update-core` | 更新 Xray，失败时恢复旧版本。 |
| `renew-cert` | 强制轮换当前模式的 Origin CA 证书。 |
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

配额任务每分钟累计 Xray 看到的上下行载荷，属于近实时控制，不是精确计费系统。用户分享自己的
UUID 或订阅地址后，相关流量仍计入该用户。

## Worker 聚合

Cloudflare 模式部署订阅时，Worker 使用与节点域名不同的同 Zone 一级子域。选择聚合后输入一份
不含 `vpsSubUrl` 的 Worker 聚合 JSON；结构参考
[`worker-src/config.example.json`](../worker-src/config.example.json)。

安装器保留其中的 `nodes`、`externalSubUrl` 和 `fallbackCdnNodes`，并自动注入本机私有源。
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

Reality 数据流量直连 VPS `443`，只有自托管订阅 HTTPS 使用 Cloudflare Origin CA 和 VPS
`8443`。证书仍匹配域名且剩余至少 30 天时，`apply` 不重复签发；需要强制轮换时执行
`sudo easy_all renew-cert`。

Reality 动态端口范围为 `10000-12927`，每 3 小时固定生成一个端口。UFW NAT 会保留近期窗口，
并预开放当天和次日凌晨所需端口；不会生成数万条单端口 allow 规则。

## 卸载

默认只删除本机资源：

```bash
sudo easy_all uninstall
```

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
```

Globalping Token 单独保存在 `/etc/easy_all/globalping.token`，权限为 `root:root 0600`。
`WORKER_AGGREGATION_CONFIG={...}` 保存在 root-only 状态中。状态文件由安装器维护，不应手工修改。

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
| 订阅能下载但节点无法连接 | 先看[客户端指南](client-guide.md)，再检查 Cloudflare gRPC 和 Xray/Nginx 日志。 |
