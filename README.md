# easy_all.sh

`easy_all.sh` 是面向专用 Debian VPS 的统一安装脚本，一次只运行一种协议：

| 协议 | 服务端 | 端口模式 | Cloudflare DNS |
|---|---|---|---|
| VLESS TCP Reality Vision | Xray | 默认 `443`，可选 `dynamic` | 不要求代理 |
| AnyTLS | sing-box | 默认 `dynamic`，可选 `443` | 必须始终保持灰云 |
| VLESS XHTTP TLS (`packet-up`) | Xray + Nginx | 固定 `443` | 安装时灰云，成功后可开橙云 |

旧的 `easy_reality.sh`、`easy_anytls.sh` 和 `easy_vless_wss.sh` 已下线，也不提供旧状态迁移。检测到 `/etc/easy_reality`、`/etc/easy_anytls` 或 `/etc/easy_vless_wss` 时，新脚本会停止安装；请先用旧脚本的卸载命令清理。

## 安装前须知

- 只支持 Debian 12/13、amd64、systemd 和 root。
- 脚本适用于专用 VPS，会升级系统软件包、安装 XanMod LTS、启用 BBR、管理 root 每日重启任务，并接管完整 `/etc/nftables.conf`。
- 三种协议都使用 TCP 443，所以同一时间只能启用一种。
- Reality 和 AnyTLS 的 `dynamic` 是订阅端口：服务器仍监听 443，nftables 将 TCP `10000-65535` 转发到 443。
- 只有 Gemini 及其必要 Google 依赖会由每台 VPS 固定选择单一地址族；`auto` 模式实测 Gemini 的 IPv4/IPv6 后选择更快的一侧，避免 `IPv4 != IPv6` 且不牺牲速度。Claude、OpenAI、MEGA 及其他服务保持服务端默认双栈行为。
- AnyTLS 不是 WebSocket，普通 Cloudflare CDN 不能代理它；域名安装前后都要保持 DNS only / 灰云。
- VLESS XHTTP 适合源站 IP 被运营商阻断、必须经 Cloudflare CDN 接入的节点。安装成功前，域名 A 记录必须保持 DNS only / 灰云并指向 VPS 公网 IPv4；AAAA 若存在，也应保持灰云并指向 VPS 公网 IPv6。安装成功后使用 CDN 时，再将 A、AAAA 一起切为 Proxied / 橙云。SSL/TLS 模式建议使用 Full (Strict)。

## 快速安装

```bash
wget -qO /root/easy_all.sh.new "https://raw.githubusercontent.com/v2yiz/easy_all/main/easy_all.sh" && chmod 700 /root/easy_all.sh.new && mv -f /root/easy_all.sh.new /root/easy_all.sh && /root/easy_all.sh install
```

也可以直接指定协议：

```bash
/root/easy_all.sh install reality
/root/easy_all.sh install anytls
/root/easy_all.sh install vless-xhttp
```

安装成功后会注册 `/usr/local/bin/easy_all`。

## 常用命令

```bash
easy_all show
easy_all subscription
easy_all status
easy_all update-sub
easy_all update-core
easy_all renew-cert
easy_all switch reality
easy_all switch anytls
easy_all switch vless-xhttp
easy_all uninstall
```

`switch` 只支持由 `easy_all` 创建的安装。切换过程会先保存原协议的状态、服务配置、证书、核心和 nftables；新协议本机验收成功后才更新 Worker。若核心启动或 Worker API 上传失败，会自动恢复原协议。

Reality 或 AnyTLS 已安装后，可以直接切换订阅端口模式；`update-sub` 会从同一份 Worker 模板同步刷新服务端域名策略、nftables 和 Worker：

```bash
sudo SUB_PORT_MODE=dynamic easy_all update-sub
sudo SUB_PORT_MODE=443 easy_all update-sub
```

`uninstall` 默认就是完整本机 purge，不再需要 `--purge`：删除 easy_all 的服务、核心、配置、证书副本、状态、日志、命令入口和备份，尝试恢复安装前的 nftables，并从 root crontab 精确移除 easy_all 托管的重启任务。若 acme.sh 确认由 easy_all 安装且已无其他证书，也会一并清理；共享 acme.sh 会保留。XanMod、已安装软件包和系统级 BBR/IPv6 初始化不会降级。

远端 Cloudflare Worker 不属于卸载范围。每次自动安装或切换都以 replace 方式覆盖同名 Worker，因此保留远端 Worker 不影响下次安装。

## 协议参数

### Reality

```bash
sudo PROTOCOL=reality \
  NODE_HOST=203.0.113.10 \
  REALITY_TARGET=swdist.apple.com:443 \
  SUB_PORT_MODE=443 \
  ./easy_all.sh install
```

输出为 VLESS TCP Reality Vision，包含 `security=reality`、`type=tcp`、`flow=xtls-rprx-vision`、public key 和 short ID。

### AnyTLS

```bash
sudo PROTOCOL=anytls \
  ANYTLS_DOMAIN=anytls.example.com \
  CF_DNS_API_TOKEN=... \
  SUB_PORT_MODE=dynamic \
  ./easy_all.sh install
```

脚本通过 acme.sh、Let's Encrypt 和 Cloudflare DNS-01 签发证书。`ANYTLS_PASSWORD` 未指定时自动生成；sing-box 可通过 `SING_BOX_VERSION=latest|alpha|具体版本` 选择版本。

Mihomo 节点包含 `type: anytls`、TLS SNI、Chrome 指纹和 `udp: true`。`udp: true` 只表示客户端允许通过节点转发 UDP，不会把 AnyTLS 服务端监听改为 UDP。

三种协议的服务端都会嗅探 HTTP、TLS 和 QUIC 目标域名。相关域名在 Mihomo 客户端保留 Fake-IP，由代理把域名交给 VPS 解析，避免客户端先确定与所选 VPS 不匹配的目标地址。只有 Gemini 及其必要 Google 依赖进入固定地址族策略；ChatGPT、Claude 及其辅助域名直接使用普通 `direct` 的默认双栈行为。`GEMINI_IP_FAMILY=auto`（默认）会分别请求三次 `https://gemini.google.com/`，比较可用地址族的中位耗时后固定选择更快的一侧。Xray 使用 `ForceIPv4` 或 `ForceIPv6`，sing-box 使用 `ipv4_only` 或 `ipv6_only`，因此同一台 VPS 上的 Gemini 请求不会在 IPv4/IPv6 之间漂移。没有全局 IPv6 地址或默认 IPv6 路由的 VPS 不执行 IPv6 测试并固定使用 IPv4。

自动测速通常适合“RN 双栈、VM 只有 IPv4”的组合，也可以在安装或更新时用 `GEMINI_IP_FAMILY=ipv4 easy_all update` 或 `GEMINI_IP_FAMILY=ipv6 easy_all update` 显式覆盖。模式选择会写入 `/etc/easy_all/state.env`，后续更新继续沿用。MEGA 不包含显式域名规则或地址族策略，按通用规则和普通 `direct` 出口处理。

模板保留字节内网适配：相关域名使用 DHCP DNS、加入 Fake-IP 过滤并显式直连，同时从 TUN 自动路由中排除 `10.0.0.0/8` 和 `fdbd::/16`。因此模板使用 `strict-route: false`；这些设置会原样同步到生成的 Worker。

为确保 Fake-IP 和服务端统一出口生效，浏览器的“安全 DNS/使用安全 DNS”应设为“使用当前服务提供商”或关闭，不要指定自定义 DoH；Android 的“私人 DNS”也应关闭或设为自动。自定义 DoH/DoT 不经过 Mihomo 的 53 端口 DNS 劫持，可能把真实 IPv4/IPv6 目标直接交给代理，重新造成出口族漂移。

### VLESS XHTTP TLS

该模式面向必须经过 Cloudflare CDN 的线路。它使用普通 HTTPS 可代理的 XHTTP
`packet-up`：上行使用分块 POST、下行使用流式响应，并通过 HTTP/2/XMUX 复用连接，
避免 WSS 为浏览器大量并发请求频繁建立独立 TLS/WebSocket 连接。

```bash
sudo PROTOCOL=vless-xhttp \
  VLESS_XHTTP_DOMAIN=xhttp.example.com \
  XHTTP_PATH=/randompath \
  CF_DNS_API_TOKEN=... \
  ./easy_all.sh install
```

`XHTTP_PATH` 默认随机生成，也可显式设置为以 `/` 开头的路径。该协议固定走 443，不接受 `SUB_PORT_MODE=dynamic`。

安装或切换到 VLESS XHTTP 前，A 记录必须为 DNS only / 灰云并指向当前 VPS 公网 IPv4；AAAA 若存在，也应保持灰云并指向当前 VPS 公网 IPv6。安装成功后请将 A、AAAA 一起切为 Proxied / 橙云，避免 IPv6 绕过 CDN。`packet-up` 不要求在 Cloudflare 后台开启 gRPC 或 WebSockets。

Nginx 会为 XHTTP 响应添加 `Cache-Control: no-store`。如果 Cloudflare 上已有会强制缓存
所有内容的 Cache Rule，请为 `VLESS_XHTTP_DOMAIN/XHTTP_PATH*` 单独增加 Bypass Cache
规则，避免缓存 XHTTP 下行响应；默认 Cloudflare 缓存策略通常不需要额外修改。

输出同时包含 VLESS URI、Mihomo `network: xhttp`/`xhttp-opts` 节点以及 base64
订阅内容。Mihomo 节点显式启用 XHTTP `reuse-settings`、`alpn: [h2]`、
`packet-encoding: xudp` 和 `udp: true`；不会额外启用 `smux`，避免与 XHTTP 自带的
XMUX 叠加。连接池使用 `max-connections: "4-8"`，将浏览器并发分散到少量 H2 主连接，
避免高丢包线路把大量请求压在单条 TCP 上产生队头阻塞。FLClash 使用的 Mihomo 内核
需要至少 `v1.19.23`，建议更新到当前稳定版。

现有 `vless-wss` 安装执行 `easy_all update` 时会自动迁移为 `vless-xhttp`，复用原域名、
UUID、证书和路径，并同步改写 Xray、Nginx 与 Worker。命令行仍接受 `vless-wss`/`wss`
作为兼容别名，但新状态只保存 `vless-xhttp`、`VLESS_XHTTP_DOMAIN` 和 `XHTTP_PATH`。

## Worker 订阅

安装或 `update-sub` 时可选择：

1. `auto`：通过 Cloudflare API 自动 replace Worker。
2. `worker`：输出完整 Worker 源码，供手动部署。
3. `link`：只输出当前节点链接。

无人值守自动部署示例：

```bash
sudo SUBSCRIBE_MODE=auto \
  CF_ACCOUNT_ID=... \
  CF_WORKER_API_TOKEN=... \
  WORKER_NAME=easy-all \
  ./easy_all.sh install reality
```

默认 Worker 名称是 `easy-all`。API 请求会对网络错误、HTTP 408/429/5xx、Cloudflare `10007` 和 `10035` 做有限次数退避重试；Cloudflare 返回 `Retry-After` 响应头或结构化错误体中的 `retry_after` 时会优先遵守（单次最多等待 300 秒）。Worker 部署完成后会先等待 5 秒，再进行最多 6 次订阅 HTTP 验收；失败后的重试间隔随机为 1–3 秒。最近一次部署日志位于：

```text
/etc/easy_all/last-worker-deploy.log
```

日志权限为 `0600`，并对 UUID、密码、Token 和 Reality 密钥做脱敏。Worker API 上传成功但 workers.dev 公网验收暂时未通过时，脚本会保留新协议并给出警告，避免错误地回滚到与远端订阅不一致的旧协议。

Worker 支持：

- 默认 base64 节点订阅：`/subscribe?token=...`
- Mihomo/Clash YAML：`/subscribe?token=...&flag=clash`
- 下载文件名：`SUB_DOWNLOAD_NAME`

### Worker 模板与规则来源

`sample-worker.js` 是 Worker 模板、Mihomo 规则和 Gemini 地址族策略的唯一来源，`easy_all.sh` 不再保存第二份域名列表。脚本会从模板的 `EASY_ALL_GEMINI_DOMAINS_START/END` JSON 区块提取域名，并写入 Xray 或 sing-box 服务端配置。模板按以下顺序获取：

1. `SAMPLE_WORKER_SOURCE` 指定的本地文件或 HTTPS URL。
2. `SAMPLE_WORKER_URL`，默认读取本仓库 `main` 分支的 `sample-worker.js`。

模板不会缓存到安装目录。通过 `/usr/local/bin/easy_all` 运行安装、切换、`update` 或 `update-sub` 时，每次操作都会重新获取 `SAMPLE_WORKER_URL` 的最新内容，但一次操作只获取一次；服务端配置和 Worker 都复用这份已校验模板。现有 Token 和节点信息从状态文件重新注入。模板缺少配置、规则或 Gemini 域名边界，或者域名 JSON 非法、重复、未规范化时，脚本会立即停止，不会生成不一致的配置。

VPS 只保留单个脚本文件时，先确保仓库中的 `easy_all.sh` 与 `sample-worker.js` 已发布到 `main`，再执行一行命令：

```bash
wget -qO /root/easy_all.sh.new "https://raw.githubusercontent.com/v2yiz/easy_all/main/easy_all.sh" && chmod 700 /root/easy_all.sh.new && mv -f /root/easy_all.sh.new /root/easy_all.sh && /root/easy_all.sh update
```

`update` 会先把当前脚本注册为 `/usr/local/bin/easy_all`，然后调用与 `update-sub` 相同的同步更新流程：安全重写并验收当前 Xray/sing-box 服务端配置，再生成或部署 Worker。Worker replace 前若任何一步失败，会恢复旧服务端配置、本地 Worker、端口模式和 nftables；replace 已完成后则保留新服务端配置，避免远端订阅与 VPS 回滚后不一致。它会沿用状态文件中的 `ALLOWED_TOKENS`、节点信息和 `CF_ACCOUNT_ID`。原部署模式为 `auto` 时，若状态中没有 Account ID，脚本会先提示输入；随后会安全提示重新输入未保存的 Cloudflare Worker API Token。

需要固定自定义模板时，可以显式指定：

```bash
sudo SAMPLE_WORKER_SOURCE=/root/easy_all/sample-worker.js \
  easy_all update-sub
```

### 订阅访问 Token

`ALLOWED_TOKENS` 是 Worker 订阅入口的访问白名单，格式必须是 JSON object：key 是便于识别的用户名，value 才是订阅 URL 中使用的 token。

```bash
ALLOWED_TOKENS='{"owner":"owner-token-123","alice":"alice-token-456"}'
```

上面的配置会生成两组订阅地址：

```text
https://<worker>.workers.dev/subscribe?token=owner-token-123
https://<worker>.workers.dev/subscribe?token=owner-token-123&flag=clash
https://<worker>.workers.dev/subscribe?token=alice-token-456
https://<worker>.workers.dev/subscribe?token=alice-token-456&flag=clash
```

规则：

- 至少要包含一个用户；无人值守安装或 `update-sub` 必须显式设置 `ALLOWED_TOKENS`。
- 用户名只允许 `A-Z a-z 0-9 . _ -`，长度 `1-64`。
- token 只允许 URL 安全字符 `A-Z a-z 0-9 . _ ~ -`，长度 `8-128`。
- 用户名和 token 都会去掉首尾空白；不允许空值、重复用户名或重复 token。
- 订阅校验只匹配 token 值，不匹配用户名。访问 `/subscribe?token=owner` 不会通过，除非某个用户的 token 值正好是 `owner`。

可以用下面的命令生成一个 URL 安全 token：

```bash
openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
```

Cloudflare API Token、DNS Token 不写入状态文件；订阅访问用的 `ALLOWED_TOKENS` 字典会保存到权限为 `0600` 的 `/etc/easy_all/state.env`，并写入自动生成的 Worker。

## 无人值守变量

```text
PROTOCOL=reality|anytls|vless-xhttp
NODE_NAME=...
NODE_HOST=...
REALITY_TARGET=swdist.apple.com:443
ANYTLS_DOMAIN=...
ANYTLS_PASSWORD=...
VLESS_XHTTP_DOMAIN=...
XHTTP_PATH=/...
SUB_PORT_MODE=443|dynamic
REBOOT_SCHEDULE_MODE=default|custom|none
REBOOT_HOUR=0-23
SUBSCRIBE_MODE=auto|worker|link
ALLOWED_TOKENS='{"owner":"token1","alice":"token2"}'
SUB_DOWNLOAD_NAME=MY_SUB
CF_DNS_API_TOKEN=...
CF_ACCOUNT_ID=...
CF_WORKER_API_TOKEN=...
WORKER_NAME=easy-all
SAMPLE_WORKER_SOURCE=/path/to/sample-worker.js|https://...
SAMPLE_WORKER_URL=https://...
SING_BOX_VERSION=latest|alpha|具体版本
```

## 状态与验证

主要文件：

| 路径 | 用途 |
|---|---|
| `/etc/easy_all/state.env` | 当前协议及订阅状态，权限 `0600` |
| `/etc/easy_all/subscribe-worker.js` | 当前协议生成的 Worker |
| `/etc/easy_all/last-worker-deploy.log` | Worker 分阶段部署日志 |
| `/etc/easy_all/backups/` | 安装前与更新过程备份 |
| `/usr/local/bin/easy_all` | 注册命令 |

本地测试：

```bash
npm test
```

测试覆盖三个协议的节点链接、Mihomo 输出、Worker base64 输出、状态安全、协议切换/回滚守卫，以及 `sample-worker.js`。
