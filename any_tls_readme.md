# easy_anytls.sh 使用说明

`easy_anytls.sh` 是一个面向专用 Debian VPS 的 AnyTLS 一键安装脚本。它复用 `easy_reality.sh` 的服务器初始化、BBR、nftables、状态备份和失败回滚思路，但代理核心改为 sing-box，TLS 证书改为使用 `acme.sh + Let's Encrypt + Cloudflare DNS-01` 签发。

本脚本只支持用户输入的单个完整域名，不支持 IP 作为节点地址，也不支持泛域名证书。

## 与 easy_reality 的主要差异

| 项目 | easy_reality | easy_anytls |
| --- | --- | --- |
| 服务端核心 | Xray-core | sing-box |
| 协议 | VLESS Reality Vision | AnyTLS |
| TLS 身份 | Reality X25519 公私钥、Short ID | Let's Encrypt 公信证书 |
| 节点地址 | IPv4 或域名 | 只能是完整域名 |
| DNS 强制校验 | 不强制域名必须解析到本机 | A 记录不严格匹配本机公网 IPv4 就终止 |
| Cloudflare DNS | 不需要 | 申请和自动续期证书时必需 |
| 证书类型 | 无公信证书 | 仅用户输入的单域名证书 |
| 泛域名 | 不适用 | 明确不支持 |
| 服务端端口 | TCP 443，可选动态端口转发 | TCP 443，订阅默认使用动态端口转发 |
| 核心版本 | 最新 Xray release | 最新稳定版、最新 alpha 或指定 sing-box 版本 |
| 核心更新 | 始终更新到最新 Xray | 跟随 stable/alpha 通道；指定版本保持锁定 |
| 客户端链接 | `vless://` | `anytls://` |
| 客户端配置 | VLESS Reality 参数 | sing-box AnyTLS outbound JSON |
| Mihomo 节点类型 | `vless` | `anytls` |
| 防火墙 | SSH、80、443，可选动态范围 | SSH、TCP 443 和默认动态范围；DNS-01 不开放 80 |
| 自动续期 | 不适用 | acme.sh cron 自动续期并重启 sing-box |
| 状态目录 | `/etc/easy_reality` | `/etc/easy_anytls` |
| 系统命令 | `easy_reality` | `easy_anytls` |

AnyTLS 从 sing-box 1.12.0 开始提供，因此脚本拒绝安装更早的版本：

```text
https://sing-box.sagernet.org/configuration/inbound/anytls/
```

## 支持范围

- Debian 12 或 Debian 13
- amd64
- systemd
- root 权限
- 公网 IPv4
- 一个由 Cloudflare 托管 DNS 的完整域名
- 域名必须存在直接指向本机公网 IPv4 的 A 记录
- 专用 VPS

不支持：

- 容器环境
- ARM
- Ubuntu、CentOS 等非 Debian 系统
- IP 节点地址
- 泛域名证书
- Cloudflare 橙云代理
- 与占用 TCP 443 的 Xray、Nginx、Caddy 或其他 sing-box 实例共存
- 与同机 `easy_reality` 默认共存

脚本会接管整机 `/etc/nftables.conf`。请只在专用 VPS 上使用。

## 快速开始

以下命令默认当前 SSH 用户可以使用 `sudo`。如果已经是 root，可以删除命令中的 `sudo`。

### 一键下载并交互安装

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && sudo ./easy_anytls.sh install
```

脚本会依次询问域名、sing-box 版本、订阅方式、重启策略、ACME 邮箱及所需的 Cloudflare Token。

### root 用户一键执行

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && ./easy_anytls.sh install
```

### 指定 sing-box 通道

最新稳定版：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && sudo SING_BOX_VERSION=latest ./easy_anytls.sh install
```

最新 alpha：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && sudo SING_BOX_VERSION=alpha ./easy_anytls.sh install
```

指定版本：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && sudo SING_BOX_VERSION=1.13.12 ./easy_anytls.sh install
```

### 一键下载并无人值守安装

`sudo` 默认可能过滤环境变量，建议使用 `sudo env` 明确传入：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && \
chmod +x easy_anytls.sh && \
sudo env \
  ANYTLS_DOMAIN=node.example.com \
  SING_BOX_VERSION=latest \
  CF_DNS_API_TOKEN=your_dns_token \
  SUBSCRIBE_MODE=auto \
  CF_WORKER_API_TOKEN=your_worker_token \
  CF_ACCOUNT_ID=your_account_id \
  ./easy_anytls.sh install
```

真实 Token 直接写在命令行可能进入 shell 历史。更推荐只通过环境变量提供非敏感参数，在交互提示中输入 Token；输入不会回显。只有自动部署 Worker 模式才会询问第二个 Worker Token。

### 下载后先审查再执行

脚本会升级系统、安装内核并接管 nftables。生产服务器建议先下载和检查：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh
less easy_anytls.sh
chmod +x easy_anytls.sh
sudo ./easy_anytls.sh install
```

不建议使用 `curl URL | sudo bash`，因为这既不便于安装前审查，也会让交互输入、失败后的脚本留存和版本核对更困难。

脚本源文件：

```text
https://github.com/v2yiz/easy_reality/blob/main/easy_anytls.sh
```

安装成功后，脚本会把自身复制到固定目录并注册命令：

```text
/usr/local/bin/easy_anytls
```

因此后续不再依赖当前目录下载的 `easy_anytls.sh`：

```bash
sudo easy_anytls status
sudo easy_anytls subscription
```

## DNS 强校验

安装开始时，脚本先完成以下检查：

1. 验证输入是合法的完整域名。
2. 明确拒绝 `*.example.com` 和 IP。
3. 通过以下多个 HTTPS 服务使用 `curl -4` 探测本机公网 IPv4：
   - `api.ipify.org`
   - `ipv4.icanhazip.com`
   - `ifconfig.co`
4. 至少两个探测结果必须一致。
5. 使用 `dig` 分别查询：
   - 系统默认解析器
   - `1.1.1.1`
   - `8.8.8.8`
6. 每个解析器都必须返回至少一个 A 记录。
7. 返回的全部 A 记录都必须等于探测出的本机公网 IPv4。
8. 完成服务器初始化后、申请证书和启动 sing-box 前再次校验。

以下情况都会阻断安装：

- 域名没有 A 记录。
- DNS 尚未传播到全部检查解析器。
- A 记录指向其他服务器。
- 同一个域名配置了多个不同的 A 记录。
- Cloudflare 开启了代理。
- 多个公网 IP 探测服务无法形成一致结果。

Cloudflare DNS 记录必须设置为灰云 `DNS only`。橙云 `Proxied` 返回 Cloudflare Anycast IP，不是 VPS 公网 IP，因此会被阻断。

如果系统尚未安装 `dig`，脚本会先安装 `dnsutils` 和 CA 证书，再执行 DNS 门禁；DNS 不匹配时不会继续安装内核、sing-box 或申请证书。

## sing-box 版本选择

交互安装提供三种模式：

```text
1. 最新稳定版 release
2. 最新 alpha/pre-release
3. 指定具体版本号
```

无人值守变量：

```bash
SING_BOX_VERSION=latest
SING_BOX_VERSION=alpha
SING_BOX_VERSION=1.13.12
SING_BOX_VERSION=v1.14.0-alpha.26
```

### latest

从 GitHub `releases/latest` 获取最新稳定版。后续执行：

```bash
easy_anytls update-singbox
```

会继续更新到最新稳定版。

### alpha

从 GitHub releases 中过滤：

- `draft == false`
- `prerelease == true`
- tag 结尾匹配 `-alpha.N`

选择返回列表中的最新 alpha。后续 `update-singbox` 继续跟随 alpha 通道。

Alpha 可能包含尚未稳定的配置变化或回归，仅适合明确愿意承担预发布风险的用户。

### 指定版本

可以指定稳定版或预发布版本：

```bash
SING_BOX_VERSION=1.13.12 easy_anytls install
SING_BOX_VERSION=v1.14.0-alpha.26 easy_anytls install
```

指定版本会记录为 `pinned`。普通更新不会自动解除锁定：

```bash
easy_anytls update-singbox
```

会终止并提示显式指定新版本。更换锁定版本：

```bash
SING_BOX_VERSION_OVERRIDE=1.13.13 easy_anytls update-singbox
```

### 下载与校验

三种模式均通过 SagerNet/sing-box 官方 GitHub release API 解析：

```text
sing-box-VERSION-linux-amd64.tar.gz
```

安装前必须满足：

- release 存在。
- 不是草稿。
- 版本不低于 1.12.0。
- release 存在对应 amd64 资产。
- GitHub API 提供该资产的 `sha256:` digest。
- 本地 SHA-256 与 release digest 完全一致。
- 解压后的二进制版本与 release tag 一致。
- 新二进制能够通过当前配置的 `sing-box check`。

历史 release 如果没有可用 SHA-256 digest，会被安全阻断，不进行未校验安装。

更新失败时脚本恢复旧二进制并重启原服务。

## 单域名证书

脚本只申请用户输入的精确域名：

```text
node.example.com
```

等价签发范围：

```bash
acme.sh --issue \
  --server letsencrypt \
  --dns dns_cf \
  -d node.example.com \
  --keylength ec-256
```

不会添加：

```text
*.example.com
example.com
```

已完成安装后，重复执行 `install` 只能继续使用状态文件中的原域名。为避免遗留旧域名的 acme.sh 续期登记和订阅，脚本会阻断直接换域名；需要更换时先执行 `easy_anytls uninstall`，再用新域名安装。

证书申请完成后还会验证：

- 证书有效期至少剩余 24 小时。
- SAN 覆盖用户输入的精确域名。
- 证书公钥与私钥匹配。
- sing-box 配置能够加载证书。

证书生产路径：

```text
/etc/easy_anytls/certs/fullchain.pem
/etc/easy_anytls/certs/private.key
```

权限为 `0600`。不要让 sing-box 直接读取 acme.sh 的内部证书目录，因为 acme.sh 内部结构可能变化。

## Cloudflare Token

AnyTLS 脚本把 DNS 证书权限和 Worker 部署权限拆成两个变量：

```text
CF_DNS_API_TOKEN
CF_WORKER_API_TOKEN
```

这是与 `easy_reality` 中单一 `CF_API_TOKEN` 用法的重要差异。

### CF_DNS_API_TOKEN

用途：

- 添加和删除 `_acme-challenge` TXT 记录。
- 首次申请 Let's Encrypt 证书。
- 后续无人值守自动续期。

建议最小权限：

```text
Zone / DNS / Edit
```

资源范围应只包含 AnyTLS 域名所在的 Zone。

申请证书时只需要提供 DNS API Token，不需要填写 Zone ID、Account ID
或 Let's Encrypt 账户邮箱。acme.sh 会使用 Token 查询域名所属 Zone：

```bash
CF_DNS_API_TOKEN=... \
ANYTLS_DOMAIN=node.example.com \
easy_anytls install
```

脚本不会把 `CF_DNS_API_TOKEN` 写入：

```text
/etc/easy_anytls/state.env
```

但为了实现无人值守续期，脚本会在调用 acme.sh 时临时映射：

```text
CF_DNS_API_TOKEN -> CF_Token
```

acme.sh 会按其 DNS API 机制把所需凭据保存在 root 专用配置中，通常位于：

```text
/root/.acme.sh/account.conf
```

或对应域名的 acme.sh 配置中。这是自动续期所必需的持久化。该目录应只允许 root 读取，不应上传、分享或纳入普通备份。

### CF_WORKER_API_TOKEN

仅在以下模式需要：

```bash
SUBSCRIBE_MODE=auto
```

用途：

- 上传 Worker module。
- 写入 Worker 加密变量 `SUB_TOKEN`。
- 启用 `workers.dev` 子域名。

建议权限：

```text
Account / Workers Scripts / Edit
```

还需要：

```text
CF_ACCOUNT_ID
```

示例：

```bash
CF_WORKER_API_TOKEN=... \
CF_ACCOUNT_ID=... \
SUBSCRIBE_MODE=auto \
easy_anytls update-sub
```

`CF_WORKER_API_TOKEN`：

- 不传给 acme.sh。
- 不写入 `state.env`。
- 不写入 Worker 源码。
- 通过权限为 `0600` 的临时 header 文件传给 Cloudflare API。
- API 调用完成后从当前 shell 变量中清除。

### 是否可以复用一个 Token

技术上可以把同一个 Token 同时赋给：

```bash
CF_DNS_API_TOKEN=同一个值
CF_WORKER_API_TOKEN=同一个值
```

但该 Token 必须同时拥有 Zone DNS 编辑和 Workers Scripts 编辑权限。一旦泄漏，影响范围更大，因此不推荐。建议创建两个独立的最小权限 Token。

## acme.sh 与自动续期

脚本从官方入口安装 acme.sh：

```text
https://get.acme.sh
```

并明确设置默认 CA：

```text
Let's Encrypt
```

acme.sh 安装器会创建每日 cron 检查任务。安装流程会验证 root crontab 中确实存在 acme.sh。

安装重试时，如果 acme.sh 返回“域名未变化、尚未到续期时间”，脚本会把该
状态识别为可继续使用，并将已有有效证书重新安装到 AnyTLS 证书目录，不会将
正常的跳过续期误判为签发失败。

证书通过 `--install-cert` 复制到 easy_anytls 固定目录，并保存 reload command：

```bash
/usr/local/lib/easy_anytls/reload-sing-box.sh
```

首次签发时 sing-box 服务尚未创建，因此 reload hook 会在服务未运行时安全返回；证书实际续期成功且 sing-box 正在运行时，hook 会重启服务并让它加载新证书。重启失败会向 acme.sh 返回失败状态。

手动强制续期：

```bash
easy_anytls renew-cert
```

该命令会：

1. 执行 acme.sh `--renew --force --ecc`。
2. 重新验证证书域名、有效期及公私钥匹配。
3. 重启 sing-box。

查看证书和续期状态：

```bash
easy_anytls status
```

## sing-box 服务端配置

主要配置路径：

```text
/etc/sing-box/config.json
```

服务：

```text
sing-box.service
```

二进制：

```text
/usr/local/bin/sing-box
```

服务端包含：

- AnyTLS inbound。
- TCP 443。
- 随机生成的长密码。
- Let's Encrypt 证书。
- 严格证书验证所需的服务端域名。
- IPv6 全局地址存在时使用双栈监听，否则只监听 IPv4。
- direct outbound。
- 延续 `easy_reality` 的 AI 相关域名 IPv4-only 解析规则。

配置写入前必须通过：

```bash
sing-box check -c /etc/sing-box/config.json
```

服务启动后必须同时满足：

- systemd 状态为 active。
- TCP 443 存在监听。

脚本会等待最多 20 秒，不会在 `systemctl restart` 返回后立即把尚在初始化
socket 的 sing-box 误判为失败。启动或监听验收失败时，会先输出并保存
systemd 状态、服务日志、443 监听信息和配置检查结果，然后才执行安装回滚：

```text
/etc/easy_anytls/last-start-diagnostics.log
```

该诊断文件权限为 `0600`；下一次成功启动会自动删除，卸载 AnyTLS 时也会删除。

## 安装

```bash
chmod +x easy_anytls.sh
sudo ./easy_anytls.sh install
```

省略命令时默认执行 `install`：

```bash
sudo ./easy_anytls.sh
```

安装完成后注册：

```text
/usr/local/bin/easy_anytls
```

后续可以执行：

```bash
sudo easy_anytls status
```

## 交互流程

安装时依次收集：

1. AnyTLS 单域名。
2. sing-box 版本通道或具体版本。
3. 订阅输出方式。
4. 定时重启策略。
5. Cloudflare DNS API Token。
6. Cloudflare Account ID、Worker API Token 和 Worker 名称，仅自动部署订阅时需要。

密码、订阅 Token 等连接凭据默认随机生成。

## 订阅输出

安装完成后输出三类信息。

### sing-box 客户端 outbound

示例：

```json
{
  "type": "anytls",
  "tag": "MY_ANYTLS",
  "server": "node.example.com",
  "server_port": 443,
  "password": "生成的密码",
  "tls": {
    "enabled": true,
    "server_name": "node.example.com",
    "insecure": false,
    "utls": {
      "enabled": true,
      "fingerprint": "chrome"
    }
  }
}
```

### AnyTLS 纯链接

格式：

```text
anytls://PASSWORD@node.example.com:443/?sni=node.example.com&insecure=0#MY_ANYTLS
```

密码、SNI 和节点名称会进行 URI 百分号编码。脚本固定输出：

```text
insecure=0
```

不会因为配置方便而关闭证书验证。

### Worker 订阅

三种模式：

```text
auto
worker
link
```

`auto`：

- 自动部署 Cloudflare Worker。
- multipart 入口模块和上传文件名统一为 `worker.js`。
- 输出通用 base64 订阅 URL。
- 输出完整 Mihomo YAML 订阅 URL。

`worker`：

- 生成并打印/保存 Worker 文件。
- 用户手动部署。
- 用户必须把 `SUB_TOKEN` 设置为 Worker 加密变量。

`link`：

- 不生成可访问的订阅 URL。
- 只输出 sing-box 客户端 JSON 和标准 AnyTLS URI。

自动部署成功后的 URL 格式：

```text
https://WORKER.workers.dev/subscribe?token=SUB_TOKEN
https://WORKER.workers.dev/subscribe?token=SUB_TOKEN&flag=clash
```

通用订阅响应为 base64 编码的 AnyTLS URI。安装器只管理当前服务器的一个
AnyTLS 节点，因此不会自动合并仓库中手工维护的其他节点。

订阅暴露端口默认是 `dynamic`：Worker 和本机输出会按 UTC+8 当前小时在
TCP `10000-65535` 范围内生成动态端口，服务器用 nftables 转发到本机
AnyTLS 的 TCP 443。需要固定 443 时设置 `SUB_PORT_MODE=443`。

Mihomo 响应与 Reality 完整模板保持同类结构，包含：

- mixed 监听端口与运行模式。
- sniffer、TUN 和 Fake-IP DNS。
- 当前 AnyTLS 节点。
- `PROXY` 代理组。
- 局域网、国内高流量服务、AI、Apple、Microsoft、Google、Telegram、
  GEOSITE/GEOIP 及最终兜底规则。

国内高流量服务规则显式覆盖哔哩哔哩、知乎、抖音、爱奇艺、优酷、快手、
小红书、腾讯、百度、网易以及常见电商和静态资源域名。域名规则同时适用于
DNS A（IPv4）和 AAAA（IPv6）结果；纯 IP 连接继续由 `GEOIP,CN,DIRECT`
兜底，因此无需维护容易过期的国内 IPv4/IPv6 地址段。

节点部分示例：

```yaml
proxies:
  - name: "MY_ANYTLS"
    type: anytls
    server: "node.example.com"
    port: 443
    password: "生成的密码"
    sni: "node.example.com"
    client-fingerprint: chrome
    udp: true
    skip-cert-verify: false
```

Worker 使用 `SUB_TOKEN` 鉴权，并发送 `cache-control: no-store`。

## 命令

```bash
easy_anytls install
```

初始化服务器、校验 DNS、安装 sing-box、申请证书并配置订阅。

```bash
easy_anytls show
```

显示 sing-box 客户端 outbound JSON 和 AnyTLS 纯链接。

```bash
easy_anytls subscription
```

显示客户端配置、纯链接、Worker 文件、Token 和订阅 URL。

```bash
easy_anytls update-sub
```

重新选择自动 Worker、手动 Worker 或纯链接模式。

```bash
easy_anytls update-singbox
```

按保存的 stable 或 alpha 通道更新。指定版本锁定模式不会自动更新。

```bash
SING_BOX_VERSION_OVERRIDE=1.13.13 easy_anytls update-singbox
```

显式更新到指定版本。

```bash
easy_anytls renew-cert
```

立即强制续期证书并重启 sing-box。

```bash
easy_anytls status
```

显示：

- sing-box 服务状态和版本。
- 保存的版本通道。
- AnyTLS 域名。
- 当前 DNS A 记录。
- 当前公网 IPv4。
- 证书到期时间。
- acme.sh cron 状态。
- nftables 和 BBR 状态。
- Worker URL。

```bash
easy_anytls uninstall
```

默认只删除 AnyTLS 相关内容：

- sing-box systemd 服务。
- easy_anytls 安装的 sing-box 二进制。
- sing-box AnyTLS 配置。
- 本机 AnyTLS 状态。
- 本机生产证书副本。
- 本机 Worker 文件。
- `easy_anytls` 注册命令及安装副本。
- 证书续期使用的 sing-box reload hook。
- 当前 AnyTLS 域名在 acme.sh 中的续期登记。
- 当前域名的 acme.sh 内部证书目录。
- easy_anytls 配置的每日重启 cron。
- 如果 acme.sh 可确认由 easy_anytls 安装且不存在其他域名证书，删除
  acme.sh 本体、全局 cron、内部凭据和 shell profile 初始化行。

默认卸载明确不会改动：

- nftables 防火墙。
- BBR/sysctl 和 IPv6 配置。
- XanMod 内核。
- 时区、NTP 和系统软件包。
- 安装前已存在、来源无法确认或仍被其他域名共用的 acme.sh。
- 历史备份。
- 已部署的 Cloudflare Worker。

```bash
easy_anytls uninstall --purge
```

彻底清理只会在默认卸载基础上额外处理 AnyTLS 专属内容：

- 删除 sing-box 配置、服务、证书和私钥的历史备份。

如果 acme.sh 不是由当前版本 easy_anytls 安装、旧版状态无法确认归属，或其中还存在其他域名证书，默认卸载和 `--purge` 都不会删除共享 acme.sh。确实需要删除全部 acme.sh 数据时显式设置：

```bash
sudo PURGE_SHARED_ACME=1 easy_anytls uninstall --purge
```

远端 Cloudflare Worker 需要 Worker API Token，并且必须单独明确授权：

```bash
sudo DELETE_CLOUDFLARE_WORKER=1 \
  CF_WORKER_API_TOKEN=your_worker_token \
  easy_anytls uninstall --purge
```

`uninstall --restore-system` 仅作为旧命令兼容入口保留，现在不会恢复服务器初始化配置。卸载只会从 root crontab 删除 easy_anytls 识别的定时重启和 acme.sh 项；其他 cron 以及 nftables、sysctl 等初始化备份在默认卸载和 `--purge` 中都会保留。

## 无人值守变量

| 变量 | 说明 |
| --- | --- |
| `ANYTLS_DOMAIN` | 必需；单个完整域名，A 记录必须指向本机公网 IPv4 |
| `ANYTLS_PASSWORD` | 可选；至少 16 字符，不提供时随机生成 |
| `NODE_NAME` | 客户端节点显示名，默认 `MY_ANYTLS` |
| `SING_BOX_VERSION` | `latest`、`alpha` 或具体官方版本 |
| `SING_BOX_VERSION_OVERRIDE` | 指定版本更新时使用 |
| `CF_DNS_API_TOKEN` | Cloudflare DNS-01 Token |
| `CF_ACCOUNT_ID` | 仅自动部署 Worker 时必需 |
| `SUBSCRIBE_MODE` | `auto`、`worker` 或 `link` |
| `SUB_PORT_MODE` | 订阅暴露端口模式：`dynamic` 或 `443`，默认 `dynamic` |
| `CF_WORKER_API_TOKEN` | 自动部署 Worker 时使用 |
| `WORKER_NAME` | Worker 名称，默认 `easy-anytls` |
| `SUB_DOWNLOAD_NAME` | Mihomo 下载文件基础名称，默认 `MY_SUB` |
| `REBOOT_SCHEDULE_MODE` | `default`、`custom`、`none`，也支持数字 1/2/3 |
| `REBOOT_HOUR` | 自定义每日重启小时，范围 0-23 |
| `FORCE` | 无人值守卸载时设为 `1` |
| `DELETE_CLOUDFLARE_WORKER` | `--purge` 时设为 `1`，同时删除远端 Worker；必须提供 Worker Token |
| `PURGE_SHARED_ACME` | `--purge` 时设为 `1`，明确允许删除安装前已存在或来源未知的 acme.sh |

完整无人值守示例：

```bash
sudo ANYTLS_DOMAIN=node.example.com \
  SING_BOX_VERSION=latest \
  CF_DNS_API_TOKEN=your_dns_token \
  SUBSCRIBE_MODE=auto \
  CF_WORKER_API_TOKEN=your_worker_token \
  CF_ACCOUNT_ID=your_account_id \
  WORKER_NAME=easy-anytls \
  ./easy_anytls.sh install
```

## 状态与密钥保存

主状态文件：

```text
/etc/easy_anytls/state.env
```

权限：

```text
0600
```

其中会保存：

- AnyTLS 域名。
- AnyTLS 连接密码。
- sing-box 版本选择、通道和已安装版本。
- 节点名称。
- Worker URL、名称和订阅 Token。
- Cloudflare Account ID。
- acme.sh 是否由 easy_anytls 安装，用于卸载时避免误删共享 acme.sh。

脚本还会在安装 acme.sh 后立即写入所有权标记：

```text
/etc/easy_anytls/acme-installed-by-easy-anytls
```

即使安装在主状态文件写入前失败，之后重新执行卸载也能判断该 acme.sh
是否由 easy_anytls 创建。

不会保存：

- `CF_DNS_API_TOKEN`
- `CF_WORKER_API_TOKEN`

注意：AnyTLS 连接密码和订阅 Token 本身就是客户端凭据，因此 `state.env` 必须仅允许 root 读取。

Cloudflare DNS Token 会由 acme.sh 另行保存以支持自动续期，详见前面的 Cloudflare Token 章节。

## 安装失败与回滚

初始化前会快照：

- nftables。
- root crontab。
- BBR/sysctl。
- 已有 sing-box 二进制。
- 已有 sing-box 配置。
- 已有 sing-box systemd unit。
- 已有生产证书和私钥。
- sing-box 安装前是否处于 active。

安装流程在快照后的任一步失败时，会尽力恢复这些本机对象。

Cloudflare 外部状态具有不同边界：

- DNS-01 临时 TXT 记录由 acme.sh 管理。
- 已成功签发到 acme.sh 内部目录的证书不会自动删除。
- 已成功上传的远端 Worker不会在本机后续步骤失败时自动删除。

## 共存与端口冲突

首次安装时，如果检测到以下任一情况，脚本会终止：

- `/etc/easy_reality` 存在。
- `xray.service` 正在运行。
- TCP 443 已被其他服务监听。

这是为了防止覆盖 Reality、Nginx、Caddy 或用户已有的 sing-box 配置。脚本定位为专用 VPS 安装器，不提供反向代理、SNI 分流或多服务共享 443。

## 防火墙差异

`easy_anytls` 写入完整 `/etc/nftables.conf`：

- 放行当前 SSH 有效端口。
- 放行 TCP 443。
- 默认 `SUB_PORT_MODE=dynamic` 时，配置 TCP `10000-65535 -> 443` 动态端口转发。
- 放行 loopback。
- 放行 established/related。
- 放行 ICMP/ICMPv6。
- 默认丢弃其他入站和转发流量。

因为使用 Cloudflare DNS-01，不开放 TCP 80。

默认 `SUB_PORT_MODE=dynamic` 时，脚本会写入 `10000-65535 -> 443` 的动态端口转发；固定 443 可设置 `SUB_PORT_MODE=443`。旧版固定 443 安装后执行 `SUB_PORT_MODE=dynamic easy_anytls update-sub`，脚本会自动补充标准动态转发；若已有自定义 `table inet nat` 但缺少该规则，会停止并要求手动合并。

如果 VPS 供应商还有独立安全组或云防火墙，也必须放行 SSH、TCP 443，以及使用默认动态模式时的 TCP `10000-65535`。

## 测试

单独运行 AnyTLS shell 测试：

```bash
bash test/test_easy_anytls.sh
```

运行仓库全部测试：

```bash
npm test
```

测试覆盖：

- 域名、IPv4 和泛域名拒绝。
- DNS 空记录、不匹配记录和多 IP 阻断。
- sing-box stable、alpha、指定版本解析。
- 最低 AnyTLS 版本限制。
- URI 百分号编码。
- sing-box 客户端 JSON。
- sing-box 服务端 AnyTLS JSON。
- AI 域名 IPv4-only 规则。
- Worker 通用订阅和 Mihomo YAML。
- Worker Token 鉴权。
- Cloudflare Token 不写入主状态文件。
- 配置与状态文件权限。

## 官方参考

- sing-box AnyTLS：
  `https://sing-box.sagernet.org/configuration/inbound/anytls/`
- sing-box Releases：
  `https://github.com/SagerNet/sing-box/releases`
- AnyTLS URI：
  `https://github.com/anytls/anytls-go/blob/main/docs/uri_scheme.md`
- acme.sh：
  `https://github.com/acmesh-official/acme.sh`
- acme.sh Cloudflare DNS：
  `https://github.com/acmesh-official/acme.sh/wiki/dnsapi#dns_cf`
- Mihomo AnyTLS：
  `https://wiki.metacubex.one/en/config/proxies/anytls/`
