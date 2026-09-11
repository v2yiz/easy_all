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

只更新订阅规则时：

```bash
sudo easy_all self-update
sudo easy_all update-sub
```

Cloudflare 模式选择保留现有 Worker 聚合配置即可，不需要再执行 `apply-cloud`。最后在客户端
刷新订阅并重启代理内核。

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
| `status` | 显示 BBRv3、协议、服务、端口和订阅状态。 |
| `self-update [--dev\|--branch <分支>]` | 更新项目代码；默认 `main`，`--dev` 使用 `dev`。 |
| `apply` | 重新应用当前配置。 |
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
