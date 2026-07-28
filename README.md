# easy_all.sh

`easy_all.sh` 是面向专用 Debian VPS 的统一安装脚本，一次只运行一种协议：

| 协议 | 服务端 | 端口模式 | Cloudflare DNS |
|---|---|---|---|
| VLESS TCP Reality Vision | Xray | 默认 `443`，可选 `dynamic` | 不要求代理 |
| AnyTLS | sing-box | 默认 `dynamic`，可选 `443` | 必须始终保持灰云 |
| VLESS WebSocket TLS（仅推荐移动宽带选择） | Xray + Nginx | 固定 `443` | 安装时灰云，成功后可开橙云 |

旧的 `easy_reality.sh`、`easy_anytls.sh` 和 `easy_vless_wss.sh` 已下线，也不提供旧状态迁移。检测到 `/etc/easy_reality`、`/etc/easy_anytls` 或 `/etc/easy_vless_wss` 时，新脚本会停止安装；请先用旧脚本的卸载命令清理。

## 安装前须知

- 只支持 Debian 12/13、amd64、systemd 和 root。
- 脚本适用于专用 VPS，会升级系统软件包、安装 XanMod LTS、启用 BBR、管理 root 每日重启任务，并接管完整 `/etc/nftables.conf`。
- 三种协议都使用 TCP 443，所以同一时间只能启用一种。
- Reality 和 AnyTLS 的 `dynamic` 是订阅端口：服务器仍监听 443，nftables 将 TCP `10000-65535` 转发到 443。
- AnyTLS 不是 WebSocket，普通 Cloudflare CDN 不能代理它；域名安装前后都要保持 DNS only / 灰云。
- VLESS WSS 仅推荐移动宽带用户选择。安装成功前，域名 A 记录必须保持 DNS only / 灰云并指向 VPS 公网 IPv4；AAAA 若存在，也应保持灰云并指向 VPS 公网 IPv6。安装成功后使用 Cloudflare CDN 时，再将 A、AAAA 一起切为 Proxied / 橙云。SSL/TLS 模式建议使用 Full (Strict)。

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/easy_all.sh -o easy_all.sh
chmod +x easy_all.sh
sudo ./easy_all.sh install
```

也可以直接指定协议：

```bash
sudo ./easy_all.sh install reality
sudo ./easy_all.sh install anytls
sudo ./easy_all.sh install vless-wss
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
easy_all switch vless-wss
easy_all uninstall
```

`switch` 只支持由 `easy_all` 创建的安装。切换过程会先保存原协议的状态、服务配置、证书、核心和 nftables；新协议本机验收成功后才更新 Worker。若核心启动或 Worker API 上传失败，会自动恢复原协议。

Reality 或 AnyTLS 已安装后，可以直接切换订阅端口模式；`update-sub` 会同步更新 nftables 和 Worker：

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

### VLESS WebSocket TLS

> 该协议仅推荐移动宽带用户选择。

```bash
sudo PROTOCOL=vless-wss \
  VLESS_WSS_DOMAIN=wss.example.com \
  CF_DNS_API_TOKEN=... \
  ./easy_all.sh install
```

`WS_PATH` 默认随机生成，也可显式设置为以 `/` 开头的路径。该协议固定走 443，不接受 `SUB_PORT_MODE=dynamic`。

安装或切换到 VLESS WSS 前，A 记录必须为 DNS only / 灰云并指向当前 VPS 公网 IPv4；AAAA 若存在，也应保持灰云并指向当前 VPS 公网 IPv6。安装成功后若使用 Cloudflare CDN，请将 A、AAAA 一起切为 Proxied / 橙云，避免 IPv6 绕过 CDN。

输出同时包含 VLESS URI、Mihomo `network: ws`/`ws-opts` 节点以及 base64 订阅内容。

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

默认 Worker 名称是 `easy-all`。API 请求会对网络错误、HTTP 408/429/5xx、Cloudflare `10007` 和 `10035` 做有限次数退避重试。Worker 部署完成后会先等待 5 秒，再进行最多 6 次订阅 HTTP 验收；失败后的重试间隔随机为 1–3 秒。最近一次部署日志位于：

```text
/etc/easy_all/last-worker-deploy.log
```

日志权限为 `0600`，并对 UUID、密码、Token 和 Reality 密钥做脱敏。Worker API 上传成功但 workers.dev 公网验收暂时未通过时，脚本会保留新协议并给出警告，避免错误地回滚到与远端订阅不一致的旧协议。

Worker 支持：

- 默认 base64 节点订阅：`/subscribe?token=...`
- Mihomo/Clash YAML：`/subscribe?token=...&flag=clash`
- 下载文件名：`SUB_DOWNLOAD_NAME`

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
PROTOCOL=reality|anytls|vless-wss
NODE_NAME=...
NODE_HOST=...
REALITY_TARGET=swdist.apple.com:443
ANYTLS_DOMAIN=...
ANYTLS_PASSWORD=...
VLESS_WSS_DOMAIN=...
WS_PATH=/...
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
