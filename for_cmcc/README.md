# easy_cmcc

`easy_cmcc` 是面向中国移动访问美西普通线路、需要经过 Cloudflare CDN 的独立单文件安装器。它固定安装 VLESS XHTTP + WSS，不提供 Reality、AnyTLS 或协议切换；客户端发布三个节点，在性能和兼容性之间按以下顺序取舍：

| 客户端节点 | 定位 | 公网链路 | Cloudflare 要求 |
|---|---|---|---|
| XHTTP `stream-up` | 默认主节点，兼顾交互与下载 | HTTPS / HTTP/2 / TCP 443 | gRPC 开启，XHTTP 路径双向不缓冲 |
| XHTTP `stream-one` | 旧客户端或特殊网络的兼容回退 | HTTPS / HTTP/2 / TCP 443 | 与主节点共用配置 |
| WSS | CDN/客户端兼容回退，下载组第二选择 | HTTPS / WebSocket / TCP 443 | WebSockets 开启 |

三个客户端节点共用同一个域名、UUID、证书和 Cloudflare CDN。两个 XHTTP 节点共用随机 XHTTP 路径，WSS 使用另一个随机路径；服务端 XHTTP 使用 `auto`，可同时接受两种模式。`stream-up` 作为主节点，WSS 保留更广的 CDN/客户端兼容性。实际速度仍取决于中国移动到 Cloudflare 边缘、Cloudflare 回源和 VPS 当时的线路质量，不存在对所有时段都固定最快的单一协议。

```text
客户端 -> Cloudflare CDN -> Nginx :443
                            |- XHTTP auto -> Xray 127.0.0.1:10085
                            `- WSS   -> Xray 127.0.0.1:10086
```

公网接入始终是 TLS/TCP，不依赖 QUIC。订阅中的 `udp: true` 和 `packet-encoding: xudp` 表示代理内部可以承载 UDP，不代表客户端使用 UDP 连接 Cloudflare。

## 安装前须知

- 只支持 Debian 12/13、amd64、systemd 和 root，不支持容器。
- 脚本面向专用 VPS，会升级系统软件包、安装 XanMod LTS、启用 BBR、管理 root 每日重启任务，并接管完整 `/etc/nftables.conf`。
- TCP 使用 `fq + BBR`，收发自动调优上限为 32 MiB，接收积压为 16384，并启用 MTU 黑洞探测；Nginx TCP 443 的监听 backlog 与 `somaxconn=4096` 对齐。
- TCP 80 和 443 必须可用。80 用于 Nginx 伪装站点，443 用于 XHTTP 与 WSS 的统一 TLS 入口。
- 安装前，节点域名的 A 记录必须为 DNS only / 灰云并直接指向 VPS 公网 IPv4；脚本会使用本机 DNS、`1.1.1.1` 和 `8.8.8.8` 强制校验。
- 如果存在 AAAA，安装前也必须保持灰云并指向当前 VPS 公网 IPv6。安装成功后应将 A、AAAA 一起切为 Proxied / 橙云，避免 IPv6 绕过 CDN。
- Cloudflare SSL/TLS 模式必须使用 Full 或 Full (Strict)，推荐 Full (Strict)，不能使用 Flexible。
- Cloudflare Network 必须开启 gRPC 和 WebSockets；XHTTP 路径还需要 Request/Response body buffering 均为 `None`。
- `easy_cmcc` 与根目录的 `easy_all` 使用不同状态、服务和命令，但仍会争用 Nginx、TCP 80/443 和 `/etc/nftables.conf`，不能在同一台 VPS 上同时安装。

## 快速安装

先把域名切为灰云并指向 VPS，然后下载单文件：

```bash
wget -qO /root/easy_cmcc.new "https://raw.githubusercontent.com/v2yiz/easy_all/main/for_cmcc/easy_cmcc" && chmod 700 /root/easy_cmcc.new && mv -f /root/easy_cmcc.new /root/easy_cmcc && /root/easy_cmcc install
```

交互安装会询问节点域名、Cloudflare DNS Token、订阅 Token 和 Worker 部署方式。安装成功后会注册 `/usr/local/bin/easy_cmcc`。

安装和本机验收成功后，再回到 Cloudflare 将节点域名的 A、AAAA 一起切为橙云。

## 常用命令

```bash
easy_cmcc show
easy_cmcc subscription
easy_cmcc status
easy_cmcc update
easy_cmcc update-sub
easy_cmcc update-core
easy_cmcc renew-cert
easy_cmcc register-command
easy_cmcc uninstall
```

- `show`：显示 XHTTP `stream-up`、XHTTP `stream-one`、WSS 节点链接和 Mihomo 节点片段。
- `subscription`：同时显示节点、Worker 名称和订阅地址。
- `status`：显示域名、两个路径、Gemini 出口地址族、Xray/Nginx 和 TCP 443 状态。
- `update`：注册当前单文件，重新应用 BBR/TCP 参数，并刷新 Xray、Nginx、Worker 模板和 `easy-cmcc` Worker；该命令强制使用自动部署模式。
- `update-sub`：刷新服务端策略和订阅，可选择自动部署、输出 Worker 或只输出链接。
- `update-core`：更新 Xray；新版本启动验收失败时自动恢复旧版本。
- `renew-cert`：强制续期当前域名证书并重载服务。
- `uninstall`：彻底删除 easy_cmcc 管理的本机服务、状态、证书、命令和备份，不删除远端 Worker。

`easy_cmcc update` 使用当前单文件更新配置，不会下载新版安装器。安装器本身有更新时，请重新执行上面的原子下载命令，并把最后的 `install` 改为 `update`：

```bash
wget -qO /root/easy_cmcc.new \
  "https://raw.githubusercontent.com/v2yiz/easy_all/main/for_cmcc/easy_cmcc" \
  && chmod 700 /root/easy_cmcc.new \
  && mv -f /root/easy_cmcc.new /root/easy_cmcc \
  && /root/easy_cmcc update
```

## 最优兼容模式与分流

XHTTP 主节点使用：

- `network: xhttp`
- `mode: stream-up`
- `alpn: [h2]`
- `packet-encoding: xudp`
- `smux.enabled: false`

同一入口额外发布 `mode: stream-one` 的兼容节点；Xray 服务端为 `mode: auto`，无需增加端口或路径。WSS 回退节点使用：

- `network: ws`
- 独立的随机 WebSocket 路径
- TLS SNI 和 Host 均为节点域名
- `packet-encoding: xudp`
- `smux.enabled: false`

Mihomo 订阅提供四个手动选择组，列表第一项为默认值：

- `AI_GEMINI`：`stream-up` → `stream-one` → WSS；Gemini 和必要的 Google 域名进入该组。
- `DOWNLOAD`：`stream-up` → WSS → `stream-one`；GitHub 及相关下载域名进入该组。
- `AI`：三个节点均可选，供 ChatGPT、Claude 等非 Gemini AI 服务使用。
- `PROXY`：三个节点均可选，承接其余代理流量。

这里不使用自动延迟测试切换：XHTTP `stream-up` 的健康检查在部分 Mihomo 版本或链路上可能超时，自动组可能把可用且更快的节点误判为不可用。若现场网络中 WSS 下载持续更快，可在 `DOWNLOAD` 组手动切换，不影响其他流量。

CDN 拨号使用双栈竞速：Mihomo 顶层启用 `ipv6: true`、`tcp-concurrent: true`，三个 CDN 节点使用 `ip-version: dual`，让客户端同时利用当时更快的 Cloudflare IPv4/IPv6 边缘。应用侧 DNS 仍保持 `dns.ipv6: false`，避免 Windows TUN 在不完整 IPv6 网络上向浏览器下发不可达的 Fake IPv6。

服务端只为 Gemini 及其必要 Google 依赖固定一个出口地址族。默认会分别测速 IPv4/IPv6，并固定选择更快且可用的一侧。ChatGPT、Claude、MEGA 及其他服务保持 VPS 默认双栈行为。

浏览器“安全 DNS”建议使用当前服务提供商或关闭；自定义 DoH/DoT 可能绕过 Mihomo 的 DNS 劫持。

## Cloudflare 节点域名配置

### 安装前：灰云直连源站

节点域名例如 `rn.example.com`：

1. A 记录填写低价无优化VPSVPS 公网 IPv4，代理状态设为 DNS only。
2. 只有 VPS 确实拥有可用公网 IPv6 时才添加 AAAA；它也必须为 DNS only。
3. 等待本地 DNS、`1.1.1.1` 和 `8.8.8.8` 都解析到源站后再安装。

脚本使用 Cloudflare DNS-01 申请 Let's Encrypt EC-256 证书，因此证书申请不依赖 HTTP-01，但安装阶段仍会校验 A 记录必须直连源站。

### 安装后：橙云 CDN

本机服务验收成功后：

1. 将 A、AAAA 一起切为 Proxied。
2. SSL/TLS 设为 Full (Strict)。
3. Network 页面开启 gRPC 和 WebSockets。
4. 为 XHTTP 路径创建 Configuration Rule：
   - Hostname 等于 `VLESS_XHTTP_DOMAIN`。
   - URI Path 以 `XHTTP_PATH` 开头。
   - Request body buffering 为 `None`。
   - Response body buffering 为 `None`。

WSS 路径不需要 body-buffering Configuration Rule。脚本会为 XHTTP 和 WSS 响应写入 `Cache-Control: no-store`；如果 Zone 已有“缓存所有内容”的 Cache Rule，还应为两个节点路径单独配置 Bypass Cache。

安装时提供具备相应权限的 Cloudflare DNS Token，脚本会尝试自动开启 gRPC、WebSockets，并创建或更新引用名为 `easy_cmcc_xhttp_streaming` 的双向无缓冲规则。权限不足只会提示警告，仍可在 Cloudflare 控制台手动完成。

## Cloudflare 凭据

自动配置和部署需要一个 Account ID，以及两个用途不同的 API Token。Token Secret 创建后通常只显示一次，不要写入仓库、截图或长期日志。

### CF_ACCOUNT_ID

这是 Cloudflare 账户的 Account ID，不是域名的 Zone ID。它用于部署 Worker，会保存到权限为 `0600` 的状态文件中，供后续更新复用。

### CF_DNS_API_TOKEN

资源建议限制到节点域名所在的单个 Zone，并授予：

- Zone → DNS → Edit
- Zone → Zone → Read
- Zone → Zone Settings → Edit
- Zone → Config Rules → Edit

DNS Edit 和 Zone Read 用于 acme.sh DNS-01；Zone Settings Edit 用于开启 gRPC/WebSockets；Config Rules Edit 用于配置 XHTTP 双向无缓冲。

### CF_WORKER_API_TOKEN

资源建议限制到实际使用的单个 Account，只授予：

- Account → Workers Scripts → Edit

脚本使用它 replace Worker module、启用 workers.dev 并读取账户子域名。`easy_cmcc` 不会把两个 API Token 写入 `/etc/easy_cmcc/state.env`；为自动续期证书，acme.sh 的 `dns_cf` 插件可能把 DNS 凭据保存在权限受限的 `/root/.acme-cmcc.sh/` 中。Worker Token 不会持久保存，交互更新时会重新提示输入。

## Worker 订阅

安装或 `update-sub` 支持三种模式：

1. 自动部署：通过 Cloudflare API replace Worker。
2. 手动部署：输出完整 Worker 源码。
3. 只输出三个 XHTTP/WSS 节点链接。

默认 Worker 名称为 `easy-cmcc`，默认 Clash 下载文件名为 `EASY_CMCC`。自动部署成功后提供：

```text
https://easy-cmcc.<account-subdomain>.workers.dev/subscribe?token=owner-token-123
https://easy-cmcc.<account-subdomain>.workers.dev/subscribe?token=owner-token-123&flag=clash
```

第一条返回 base64 节点订阅，第二条返回 Mihomo/Clash YAML。

Cloudflare API 请求会对网络错误、HTTP 408/429/5xx 和 Cloudflare `10007`、`10035` 做有限次数退避重试。Worker 部署完成后先等待 10 秒，再进行最多 12 次 base64 与 Clash HTTP 验收；每轮两个请求使用同一个 Worker 版本亲和键并附带防缓存参数，避免发布传播期间命中不同版本。最近一次部署日志位于：

```text
/etc/easy_cmcc/last-worker-deploy.log
```

日志权限为 `0600`，UUID、订阅 Token 和 Cloudflare Token 会脱敏。Worker module 已 replace、但后续 workers.dev 查询或公网验收暂时失败时，脚本会优先保留已经与远端 Worker 匹配的新本机配置，避免错误回滚造成订阅与服务器不一致。

### Worker 模板与规则来源

`easy_cmcc` 单文件包含安装核心，但不内嵌整份 Worker 规则。`sample-worker.js` 是 CMCC Worker、Mihomo 规则和 Gemini 域名策略的唯一来源，默认从下列地址获取：

```text
https://raw.githubusercontent.com/v2yiz/easy_all/main/for_cmcc/sample-worker.js
```

模板不会安装到命令目录。每次安装、`update` 或 `update-sub` 都会重新获取并校验一次模板，再由同一份内容生成 Xray 的 Gemini 地址族策略和 Worker，避免服务端与订阅规则不一致。

### 订阅访问 Token

Worker `/subscribe` 入口使用 Token 字典作为访问白名单，格式必须是 JSON object；key 是用户名，value 才是 URL 中使用的 token：

```json
{"owner":"owner-token-123","alice":"alice-token-456"}
```

规则：

- 至少包含一个用户，后续更新可以沿用状态文件中的字典。
- 用户名只允许 `A-Z a-z 0-9 . _ -`，长度 `1-64`。
- token 只允许 URL 安全字符 `A-Z a-z 0-9 . _ ~ -`，长度 `8-128`。
- 不允许空值、重复用户名或重复 token。
- 订阅校验匹配 token 值，不匹配用户名。

生成 URL 安全 token：

```bash
openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
```

Token 字典会保存到 `/etc/easy_cmcc/state.env` 并写入生成的 Worker，因此该状态文件和 Worker 文件权限均为 `0600`。

### 自定义订阅域名

默认 workers.dev 地址可以直接使用。如果需要 `https://sub.example.com/subscribe?...`，可在 Cloudflare 为 `easy-cmcc` Worker 配置 Custom Domain；或者创建一个橙云 DNS 记录后，再添加匹配 `sub.example.com/*` 的 Worker Route。订阅域名与节点域名可以不同，不要把 token 或查询参数写入 Route pattern。

## 状态、隔离与卸载

主要落盘位置：

| 路径 | 用途 |
|---|---|
| `/etc/easy_cmcc/state.env` | 当前节点和订阅状态，权限 `0600` |
| `/etc/easy_cmcc/subscribe-worker.js` | 根据模板生成的当前 Worker，权限 `0600` |
| `/etc/easy_cmcc/last-worker-deploy.log` | Worker 分阶段部署日志 |
| `/etc/easy_cmcc/backups/` | 安装前及更新过程备份 |
| `/etc/easy_cmcc/xray/` | Xray 二进制、版本与配置 |
| `/etc/easy_cmcc/certs/` | 当前域名证书副本 |
| `/usr/local/lib/easy_cmcc/easy_cmcc` | 注册后的单文件安装器 |
| `/usr/local/bin/easy_cmcc` | 命令软链接 |
| `/etc/systemd/system/easy-cmcc-xray.service` | 独立 Xray 服务 |
| `/etc/nginx/conf.d/easy_cmcc.conf` | 独立 Nginx 配置 |
| `/var/www/easy_cmcc/` | 伪装站点 |
| `/root/.acme-cmcc.sh/` | 独立 acme.sh 目录 |

`update-sub` 会先备份状态、Xray、Nginx、Worker 和 nftables。Worker replace 前发生错误时自动恢复；Worker 已 replace 后则保留新本机配置，以远端订阅一致性为优先。

`uninstall` 默认就是完整本机 purge，不需要 `--purge`：它停止并移除 easy_cmcc 服务、恢复未被用户再次修改的安装前 nftables、删除专属定时重启任务、状态、证书、命令和备份。XanMod、已安装软件包及系统级 BBR/IPv6 初始化不会降级，远端 Cloudflare Worker 不会删除。

旧版 CMCC 若仍使用 `/etc/easy_all`、`easy-all-xray.service` 或旧入口，本套件不会自动接管。迁移前先保存订阅和 Cloudflare 凭据，使用旧入口卸载，再安装当前 `easy_cmcc`，避免两套服务争用 TCP 443 和 `/etc/nftables.conf`。

## 本地测试

```bash
cd for_cmcc
npm test
```

测试覆盖单文件入口、隔离路径、固定协议守卫、XHTTP/WSS 三节点输出、双栈 CDN 拨号、Cloudflare 配置、订阅 Token、Worker base64/Mihomo 输出及策略顺序。
若本机已安装 Mihomo，可额外执行真实配置校验：

```bash
MIHOMO_BIN=/path/to/mihomo MIHOMO_DATA_DIR=/path/to/mihomo-data npm run test:mihomo
```

`MIHOMO_DATA_DIR` 应包含 Mihomo 校验 `GEOSITE`、`GEOIP` 规则所需的 `GeoSite.dat` 与 `Country.mmdb`；若省略，Mihomo 会按自身配置尝试下载。
