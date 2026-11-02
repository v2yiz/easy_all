# Bunny CDN 前置准备与运维

模式 `5` 使用 Bunny 的自动边缘调度提供 VLESS WS/TLS 入口和 owner 订阅。VPS 上由
Nginx 终止回源 TLS，Xray 监听 `127.0.0.1:10086`。运行环境为 Debian 12/13 amd64、
IPv4 和专用 VPS。

## 主链路与执行顺序

```text
客户端
  -> cdn.example.com
  -> Cloudflare DNS-only CNAME
  -> <pull-zone>.b-cdn.net
  -> https://origin.example.com
  -> Cloudflare DNS-only A
  -> 洛杉矶 VPS:443（Nginx）
  -> 127.0.0.1:10086（Xray VLESS WS/TLS）
```

按以下顺序完成准备和安装：

1. 在 Bunny 账户中准备 Account API Key、余额和流量预算。
2. 在 Cloudflare 中准备 Active 根 Zone、DNS API Token，并选择两个不同主机名。
3. 在 VPS 上运行安装器。安装器使用 Bunny API 创建 Pull Zone 和自定义主机名，使用
   Cloudflare API 创建 `origin` A 记录与 `cdn` CNAME 记录。
4. 安装器申请边缘证书和源站 Let's Encrypt 证书，并执行真实 VLESS、WebSocket、TLS 和
   订阅验收。
5. 安装完成后，在 Bunny 控制台和 Cloudflare 控制台分别核对资源状态。

## 在 Bunny 执行

### 1. 准备账户与 API Key

1. 登录 [Bunny Dashboard](https://dash.bunny.net/cdn)。
2. 确认账户状态正常，并准备覆盖 CDN 流量和 WebSocket 连接分钟的余额。
3. 在账户设置的 API Key 区域生成 **Bunny Account API Key**。当前控制台的具体菜单名以
   登录后的界面为准。
4. 将 API Key 粘贴到安装器的隐藏输入提示。安装器把它保存为
   `/etc/easy_all-bunny/bunny-api.key`，目录权限为 `0700`，文件权限为 `0600`。

安装器使用该 Key 完成以下 Bunny 操作：

- 创建或核验 Type `1` Volume Pull Zone；
- 添加 `cdn.example.com` 自定义主机名；
- 对 `cdn.example.com` 和系统 `*.b-cdn.net` 主机强制 HTTPS；
- 写入随机回源头、关闭缓存、请求日志和智能缓存；
- 请求免费边缘证书；
- 保存 Pull Zone ID、操作状态和所有权校验信息。

### 2. 设置流量预算

安装时输入月流量限制，单位为十进制 GB（1 GB = 1,000,000,000 字节，默认 `500` GB）。
安装器将该值写入 Pull Zone 的 `MonthlyBandwidthLimit`，并设置
`MaxWebSocketConnections=500`。`500` 是同时连接容量；月流量限制用于控制数据传输量，
WebSocket 连接分钟按 Bunny 账单另行计费。

### 3. 安装后在 Bunny 核对

登录 Bunny Dashboard，打开本安装器创建的 Pull Zone，核对：

- Pull Zone 类型为 Volume；
- `cdn.example.com` 已出现在自定义 Hostnames 列表；
- 自定义域名显示证书可用并启用强制 HTTPS；
- 系统 `<pull-zone>.b-cdn.net` hostname 启用强制 HTTPS；
- Edge Rule 包含 `X-Easy-All-Origin-Key` 回源头规则；
- 缓存、日志和请求合并设置与安装器输出一致；
- 月流量限制显示为安装时填写的值。

## 在 Cloudflare 执行

### 1. 准备根 Zone

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com)。
2. 选择一个状态为 **Active** 的根 Zone，例如 `example.com`。
3. 在该 Zone 下选择两个不同主机名：

| 名称 | 安装器创建的记录 | 用途 |
| --- | --- | --- |
| `origin.example.com` | DNS-only A → VPS 公网 IPv4 | Nginx HTTPS 回源 |
| `cdn.example.com` | DNS-only CNAME → Pull Zone 的 `*.b-cdn.net` | 客户端节点和 owner 订阅 |

4. 保留这两个名称供安装器创建记录。`cdn` 使用子域名，记录类型为 CNAME，代理状态为
   DNS-only。

在主模式中，Cloudflare 管理 `origin` 和 `cdn` 两项业务记录；Bunny 管理 Pull Zone
及其边缘配置。Bunny DNS Zone 用于本指南后面的可选子域委派场景。

### 2. 创建 Cloudflare API Token

在 Cloudflare **My Profile → API Tokens → Create Token** 中创建自定义 Token：

- `Zone:Read`
- `Zone:DNS:Edit`
- Zone Resources 限制到目标根 Zone，例如 `example.com`

将 Token 粘贴到安装器的隐藏输入提示。安装器把它保存为
`/etc/easy_all-bunny/cloudflare-dns.token`，目录权限为 `0700`，文件权限为 `0600`。

安装器使用该 Token 完成以下 Cloudflare 操作：

- 核验目标 Zone；
- 创建 `origin.example.com` 的 DNS-only A 记录；
- 创建 `cdn.example.com` 的 DNS-only CNAME 记录；
- 检查 CNAME Flattening 和 CAA；
- 供 lego 通过 Cloudflare DNS-01 签发源站 Let's Encrypt 证书。

### 3. 检查 CAA

边缘 `cdn.example.com` 使用 HTTP-01，源站 `origin.example.com` 使用 DNS-01。安装前执行：

```bash
dig CAA cdn.example.com +short
dig CAA origin.example.com +short
dig CAA example.com +short
```

CAA 记录为空时，保持当前策略并继续安装。已有 CAA 时，将 Let's Encrypt 纳入域名所有者
允许的签发策略。基础授权项示例：

```text
example.com.  CAA  0 issue "letsencrypt.org"
```

使用 RFC 8657 `validationmethods` 参数时，同时覆盖边缘 HTTP-01 和源站 DNS-01：

```text
example.com.  CAA  0 issue "letsencrypt.org; validationmethods=http-01,dns-01"
```

修改 CAA 时保留域名所有者已有的其他限制。安装器对边缘证书执行完整 TLS 校验，并跟随
`cdn.example.com` 的 DNS-only CNAME 查询目标 DNS 区的真实权威服务器。

### 4. 安装后在 Cloudflare 核对

打开目标 Zone 的 **DNS → Records**，确认：

- `origin.example.com` 为 A 记录，内容为 VPS 公网 IPv4，代理状态为 DNS-only；
- `cdn.example.com` 为 CNAME 记录，内容以 `.b-cdn.net` 结尾，代理状态为 DNS-only；
- `cdn.example.com` 未被 CNAME Flattening 展平；
- CAA 允许 Let's Encrypt 的 HTTP-01 和 DNS-01 验证。

## 安装器执行的操作

在 VPS 上执行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh)
```

当前分支尚未发布到 `main` 时，在本 checkout 中运行：

```bash
sudo bash ./easy_all install
```

选择模式 `5` 后依次输入：

1. Cloudflare 根 Zone，例如 `example.com`；
2. 源站域名，默认 `origin.example.com`；
3. CDN 节点与订阅域名，默认 `cdn.example.com`；
4. Bunny 月流量限制，默认 `500` GB；
5. Bunny Account API Key；
6. Cloudflare DNS API Token。

安装器执行以下云和本机操作：

- 创建 Type `1` Volume Pull Zone，并使用随机五至五十位字母数字名称；
- 创建 `origin` A 与 `cdn` DNS-only CNAME；
- 绑定 `cdn.example.com` 自定义域并申请免费边缘证书；
- 对自定义域和系统 `b-cdn.net` 主机启用强制 HTTPS；
- 写入随机回源头，关闭缓存和请求日志，并要求源站 TLS 严格验证；
- 从 Bunny 官方 `edgeserverlist` 获取回源 IPv4 池，只允许该池和 loopback 访问源站
  `443`；
- 通过 Cloudflare DNS-01 签发 `origin.example.com` 的 Let's Encrypt 证书；
- 生成 Xray VLESS WS/TLS、Nginx 和 owner 订阅；
- 验证源站 served leaf、WebSocket `101`、真实 VLESS 代理访问
  `https://www.gstatic.com/generate_204 == 204`、订阅和错误 Token。

## 安装后联合验收

在 VPS 上执行：

```bash
dig A origin.example.com @1.1.1.1 +short
dig CNAME cdn.example.com @1.1.1.1 +short
sudo easy_all status
sudo easy_all show
sudo easy_all subscription
```

验收结果应满足：

- A 记录为本 VPS 公网 IPv4；
- CNAME 指向当前 Pull Zone 的 `.b-cdn.net` hostname；
- `easy_all status` 显示 Bunny、Nginx、Xray、订阅和证书服务正常；
- 通用与 `flag=clash` 订阅均包含预期 VLESS WS/TLS 节点；
- 真实客户端通过代理完成持续上传、下载和重连。

中国大陆三网质量取决于 Bunny 边缘调度、运营商路由和当时链路状态。当前实现使用 Bunny
自动调度；上线后使用多个运营商网络执行延迟、丢包和吞吐实测，并根据结果决定是否继续使用
当前入口。

## 可选扩展：在 Bunny 委派子域

Bunny 官方 DNS 文档支持把 `bunny.example.com` 作为独立 DNS Zone，并通过父区 NS 记录
完成标准 DNS 子域委派。这个能力用于确实需要由 Bunny DNS 托管独立子树的场景；主模式的
`origin` 和 `cdn` 记录继续由 Cloudflare 管理。

### Bunny 中的操作

1. 打开 **DNS → Add DNS Zone**，填写完整子域：

   ```text
   bunny.example.com
   ```

2. 创建成功后打开该 Zone 的 **Nameservers** 页面，完整记录实际显示的权威 NS。常见默认值
   为 `kiki.bunny.net` 和 `coco.bunny.net`，以控制台实际值为准。
3. 在 Bunny 子 Zone 添加验证记录：

   ```text
   名称：_delegation-check.bunny
   类型：TXT
   内容：easy-all-delegation-check
   ```

4. 普通委派验证完成后，在 Bunny 子 Zone 的可选 **DNSSEC** 页面启用 DNSSEC，并复制当前
   DS 记录。

### Cloudflare 中的操作

1. 在父 Zone `example.com` 的 **DNS → Records** 中查看 `bunny` 名称。
2. 将 `bunny` 名称下现有 A、AAAA、CNAME 和业务记录保存到备份，并按迁移计划移到 Bunny
   子 Zone 或新名称。
3. 在同一名称 `bunny` 添加 Bunny 显示的全部 NS 记录：

   ```text
   类型：NS    名称：bunny    内容：Bunny 实际 Nameserver 1
   类型：NS    名称：bunny    内容：Bunny 实际 Nameserver 2
   ```

4. 将 `bunny` 名称下的记录切换为用于委派的 NS 记录。Cloudflare 会将其显示为
   `bunny.example.com NS <Bunny nameserver>`；该名称的 Proxy 开关不参与委派。
5. 启用 DNSSEC 时，在 Cloudflare 父区 `bunny` 名称下添加 Bunny 当前显示的 DS 记录。

### 验证与生效时间

1. 查询 Cloudflare 父区权威服务器：

   ```bash
   dig NS bunny.example.com @<Cloudflare 父区权威 NS> +noall +answer
   ```

2. 查询 Bunny 权威服务器：

   ```bash
   dig SOA bunny.example.com @<Bunny 实际 Nameserver>
   dig TXT _delegation-check.bunny.example.com @<Bunny 实际 Nameserver>
   ```

3. 查询公共递归解析器：

   ```bash
   dig NS bunny.example.com @1.1.1.1 +noall +answer
   dig NS bunny.example.com @8.8.8.8 +noall +answer
   dig TXT _delegation-check.bunny.example.com @1.1.1.1 +short
   dig TXT _delegation-check.bunny.example.com @8.8.8.8 +short
   ```

Cloudflare 父区通常很快保存 NS 记录。公共递归结果受 NS TTL、负缓存、上游缓存和运营商
缓存影响，通常需要几分钟到数小时；旧 TTL 较长时按旧 TTL 等待。Bunny 返回子区 SOA 和
TXT，两个公共递归解析器返回相同结果后，委派完成。

启用 DNSSEC 后检查：

```bash
dig +dnssec DS bunny.example.com @1.1.1.1 +short
dig +dnssec TXT _delegation-check.bunny.example.com @1.1.1.1 +short
```

验证完成后，在 Bunny 子 Zone 删除临时 TXT。需要恢复 Cloudflare 管理时，先把子树业务记录
备份并迁回 Cloudflare，再删除父区 NS 和 DS，最后按业务需要重建 A、AAAA 或 CNAME 记录。

## 日常运维与失败恢复

```bash
sudo easy_all apply                  # 验证已有云资源所有权并重新应用本机
sudo easy_all apply-cloud            # 继续 pending 事务或核验已有资源后应用本机
sudo easy_all apply-cloud --claim-pull-zone <ID>
sudo easy_all apply-cloud --retry-certificate
sudo easy_all apply-cloud --retry-mutation <operation-id>
sudo easy_all renew-cert             # 重新签发源站证书，重载并验收 Nginx
sudo easy_all refresh-origin-ips     # 立即刷新官方回源 IPv4 池
```

恢复参数与运维提示一一对应。只有输出给出具体 `Pull Zone ID`、证书失败状态或
`operation-id` 时，才执行对应的恢复命令。

Bunny API 明确返回 4xx 时，对应操作记录为 `failed-safe`，当前运行停在 pending。修正
API Key 权限、Zone、套餐或字段后再次执行 `apply-cloud`，安装器会创建新的受控操作。
网络中断、超时和 5xx 属于结果未知，安装器按 journal 中的证据恢复。

systemd 每天两次运行 `cert-renew`。续期后重载 Nginx 并核对实际 served leaf；失败时恢复
旧证书、配置、Fail2ban 状态和防火墙。回滚失败时，私有快照保存在
`/etc/easy_all-bunny/local-rollback`。Bunny 官方回源池每六小时刷新；刷新失败时保留上一版
已验证规则，首次获取失败时保持源站 `443` 对 Bunny 回源池关闭。

云操作使用 flock、generation CAS 和 fsync 原子 journal。每步请求状态、已知资源 ID、
预期内容和 pending 恢复信息保存在 `/etc/easy_all-bunny/ownership.json`。API Key 与 Token
保存在独立的 root-only 文件中，不写入该 JSON 或订阅。

## 卸载

```bash
sudo easy_all uninstall
```

默认卸载本机服务并恢复安装前防火墙，保留云端资源与 `/etc/easy_all-bunny` 恢复数据。
在同一 VPS 和相同配置下重装时，安装器按保存的 ID 和内容验证后复用。owner UUID 与订阅
Token 会重新生成，客户端需要更新订阅。

同时清理安装器持有的云资源时，在本地安装完好时执行：

```bash
sudo easy_all uninstall --purge-cloud
```

该命令删除 journal 持有且内容仍匹配的两个 Cloudflare DNS 记录、Pull Zone 自定义主机名、
Edge Rule 和 Pull Zone。Bunny DNS Zone 与 Cloudflare 父区 NS 委派由用户按可选委派章节
单独管理。云清理失败时安装器保留 ownership 和凭据供续跑。

## 凭据与权限

API Key 和 Token 只输入安装器的隐藏提示，并仅保存在 root `0600` 文件中：

- `/etc/easy_all-bunny/bunny-api.key`
- `/etc/easy_all-bunny/cloudflare-dns.token`

命令行、仓库文件、截图和 Issue 使用占位符，真实凭据只通过上述私有文件传递。

## 官方依据

- [Bunny DNS 概览](https://bunny.net/docs/dns)
- [Bunny DNS Zone Quickstart 与 Nameservers](https://bunny.net/docs/dns/quickstart)
- [Bunny DNS 记录：NS 委派子域](https://bunny.net/docs/dns/records)
- [Bunny DNS：子域可作为独立 Zone](https://bunny.net/academy/dns/what-are-dns-zones-and-dns-records/)
- [Bunny Pull Zone 自定义主机名](https://bunny.net/docs/cdn/custom-hostname)
- [Bunny WebSocket](https://bunny.net/docs/cdn/websockets)
- [Bunny CDN 价格](https://bunny.net/pricing/cdn/)
- [Bunny Core API](https://bunny.net/docs/api-reference/core)
- [Bunny 回源头与源站 Host/SNI](https://bunny.net/docs/cdn/request-headers-to-origin)
