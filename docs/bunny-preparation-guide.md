# Bunny CDN 前置准备与运维

模式 `3` 使用 Bunny CDN 的全球边缘网络分发 VLESS WS/TLS 节点与 owner 订阅。VPS 端由 Nginx 终止 HTTPS 回源并校验私有 Header，内部反代至 Xray（监听 `127.0.0.1:10086`）。

---

## 1. 链路架构

```text
客户端 (VLESS WS/TLS 节点 & 订阅下载)
  │
  ▼
cdn.example.com (CDN 域名：Cloudflare DNS-only CNAME -> *.b-cdn.net)
  │
  ▼
Bunny CDN 边缘网络 (自动就近调度优选节点，强制 HTTPS 传输)
  │  (自动注入私有回源头 X-Easy-All-Origin-Key)
  ▼
https://origin.example.com (源站域名：Cloudflare DNS-only A -> VPS 公网 IPv4:443)
  │
  ▼
Nginx (终止 TLS，校验回源 Key，仅允许 Bunny 官方边缘 IP 入站)
  │
  ▼
127.0.0.1:10086 (Xray VLESS WebSocket)
```

---

## 2. 前置准备

在运行安装脚本前，需准备以下内容：

### 2.1 专用 VPS 与系统环境
- **系统要求**：Debian 12 / 13 amd64 或 arm64 纯净系统，须由 systemd 管理且非容器，仅支持 IPv4。其他模式仍只支持 amd64。
- **端口放行**：云厂商安全组放行 TCP `443` 及当前 SSH 端口。
- **SSH 与内核**：Bunny 保留现有 SSH 监听；刷新回源池也保留自定义及多个 SSH 端口。不能可靠检测监听或已有第三方阻断规则时会报错，保留旧放行规则。ARM64 使用原有内核，暂不支持 Skyline Speeder 内核加速。

### 2.2 Bunny 账户与 API Key
1. 登录 [Bunny Dashboard](https://dash.bunny.net/)。
2. 确保账户内有可用余额（CDN 流量计费及 WebSocket 连接计费）。
3. 进入 **Account Settings → API Key**，复制 **Account API Key**（注意是账户全局 Key，不是 Storage 或 Pull Zone 密码）。安装器会使用该 Key 自动创建 Pull Zone、配置 Edge Rule、绑定自定义域名及申请边缘证书。

### 2.3 域名规划与概念区分（核心）

需要两个子域名，安装器会自动在 Cloudflare 中配置，职责严格分离：

| 概念 | 示例（默认） | 角色与用途 | 解析记录类型 | 访问与安全策略 |
| :--- | :--- | :--- | :--- | :--- |
| **Cloudflare 根 Zone** | `example.com` | Cloudflare 托管的主域名。Cloudflare API 操作 DNS 记录必须绑定该域名的 `zone_id`。 | - | 不直接承载流量，仅作为云端 API 根作用域。 |
| **源站域名 (Origin)** | `origin.example.com`<br>（默认 `origin.<zone>`） | **VPS 本机 Nginx 专用**。<br>用于向 Let's Encrypt 签发源站 SSL 证书，并供 Bunny 边缘节点向 VPS 回源。 | **DNS-only A 记录**<br>指向真实 VPS 公网 IPv4 | **绝不暴露给客户端**。UFW 防火墙配置白名单，仅放行 Bunny 官方回源 IP 访问 443 端口，外网直连被丢弃。 |
| **CDN 域名 (CDN)** | `cdn.example.com`<br>（默认 `cdn.<zone>`） | **公开客户端与订阅入口**。<br>客户端连接代理及拉取订阅时填写的域名。 | **DNS-only CNAME 记录**<br>指向 Bunny 的 `<pull-zone>.b-cdn.net` | **公开给客户端使用**。流量首先进入 Bunny CDN 全球边缘网络调度优选节点，真实 VPS IP 完全隐藏。 |

> [!NOTE]
> 为什么要填根 Zone？
> 1. **Cloudflare API 规范**：Cloudflare API 操作 DNS 记录必须知道所在的 `zone_id`，而 `zone_id` 需通过账户托管的根域名反查。
> 2. **证书联系邮箱**：ACME 客户端（`lego`）通过 Cloudflare DNS-01 签发源站证书时，将该根域名作为注册联系人邮箱后缀（`admin@<zone>`）。
> 3. **智能默认前缀**：参数文件里只填 `CLOUDFLARE_ZONE`，`ORIGIN_DOMAIN`/`CDN_DOMAIN` 省略即按 `origin.<zone>`、`cdn.<zone>` 派生。

### 2.4 Cloudflare API Token
1. 进入 Cloudflare **My Profile → API Tokens → Create Token**，使用 **Create Custom Token**。
2. 配置以下两项权限：
   - `Zone` - `DNS` - `Edit`
   - `Zone` - `Zone` - `Read`
3. 资源范围（Zone Resources）选择 **Include → Specific zone**，选中你的根 Zone。

---

## 3. 安装参数示例

```bash
sudo easy_all install --print-params --mode bunny-ws > params.json
sudo easy_all params.json --check-params
sudo easy_all params.json
```

```json
{
  "schema_version": 1,
  "mode": "bunny-ws",
  "params": {
    "CLOUDFLARE_ZONE": "example.com",
    "BUNNY_API_KEY": "<Bunny Account API Key>",
    "CLOUDFLARE_DNS_TOKEN": "<Cloudflare DNS Token>"
  }
}
```

`ORIGIN_DOMAIN`、`CDN_DOMAIN`、`BUNNY_BANDWIDTH_GB` 可省略（默认 `origin.<Zone>`、`cdn.<Zone>`、
`500`）；两个 Token 必填。节点名与下载名固定 `EASY_ALL`。安装成功会自动删除参数文件。
所有模式的完整示例见 [params-examples.md](params-examples.md)。

### 安装器自动完成的编排工作
1. **云端联动**：
   - 在 Cloudflare 创建 `origin.example.com` 的 DNS-only A 记录（指向 VPS IPv4）。
   - 在 Bunny 创建 Type 1 Volume Pull Zone（命名如 `easyallxxxxxx`），配置源站地址为 `https://origin.example.com`，开启 WebSocket。
   - 在 Cloudflare 创建 `cdn.example.com` 的 DNS-only CNAME 记录（指向 `easyallxxxxxx.b-cdn.net`）。
   - 在 Bunny 绑定自定义主机名 `cdn.example.com`、申请免费边缘 SSL 证书，并设置回源私有请求头规则 `X-Easy-All-Origin-Key`。
2. **源站申请证书**：
   - 本地通过 `lego` 调用 Cloudflare DNS-01 API 为 `origin.example.com` 申请正式的 Let's Encrypt 证书并存入 `/etc/easy_all/certs/`。
3. **部署本地服务**：
   - 配置 Xray 监听 `127.0.0.1:10086`（VLESS WS 协议）。
   - 配置 Nginx 443 端口虚拟主机：使用 Let's Encrypt 证书，校验请求头 `X-Easy-All-Origin-Key`，反代 WebSocket 到 Xray，并提供 `/subscribe?token=...` 订阅端点。
4. **安全与自动化**：
   - 拉取 Bunny 官方边缘回源 IP 网段，在 UFW 防火墙配置入站限制规则（仅放行 Bunny 回源节点访问 443）。
   - 本机与订阅验收成功后，安装会尝试检查 CDN 域名 HTTP 可达性并提示结果；不可达仍继续本地安装，随后注册 `easy_all` 命令并启用 systemd 证书自动续期定时器（`easy_all-cert-renew.timer`）与回源 IP 白名单自动刷新定时器（`easy_all-bunny-ips.timer`），最后保存安装状态。边缘 HTTP 可达不代表生产 WebSocket `101` 或 VLESS 数据面已经验收。

---

## 4. 常用运维命令

安装完成后，可通过 `easy_all` CLI 管理本机与云端服务：

```bash
# 查看运行状态（Xray、Nginx、域名信息）
sudo easy_all status

# 查看节点链接与订阅地址（获取导入客户端的 URL）
sudo easy_all subscription
sudo easy_all show

# 幂等同步受管的 Bunny 与 DNS 资源（不重建本机服务）
sudo easy_all apply

# Bunny 模式下与 apply 相同
sudo easy_all apply-cloud

# 强制重新签发 Let's Encrypt 源站证书并重载 Nginx
sudo easy_all renew-cert

# 立即从官方刷新 Bunny 回源 IPv4 防火墙白名单
sudo easy_all refresh-origin-ips
```

开发测试使用现有 `npm run test:bunny` 和 `npm test`，外部命令与云端均使用隔离夹具。
运行前需准备 Node.js/npm、Python 3、Python `jsonschema`、Bash、`jq`、`unzip`、`tar`
和 `sha256sum`（Debian 的 coreutils）。
旧部署首次执行 Bunny `apply` 或 `uninstall --purge-cloud` 时，会在缺少依赖的情况下自动
安装 Debian 包 `python3-jsonschema`；`ips` 定时器不依赖该包。
全新 VM 应先安装测试依赖；缺少 `jq` 等工具导致的下载夹具失败不表示架构或摘要校验失败。
真实 UFW 回归只能在**专用、可丢弃的 Linux root 测试 VM** 中执行：

```bash
sudo env EASY_ALL_DEDICATED_TEST_VM=1 npm run test:bunny:ufw
```

该脚本在独立网络、挂载与进程命名空间中运行真实 UFW，并使用配置副本；不得在生产 VPS 或宿主执行。

Root 用户入口回归也在专用 Linux VM 中运行：

```bash
sudo env EASY_ALL_DEDICATED_TEST_VM=1 npm run test:bunny
```

该测试使用本地 HTTP 替身和隔离路径；成功卸载阶段只在自己的 mount namespace 中替换
`systemctl`，不会操作 VM 的真实服务。

---

## 5. 卸载

### 仅卸载本机服务
```bash
sudo easy_all uninstall
```
停止并删除 Xray、Nginx 站点配置、定时器与 `easy_all` 命令，移除 CDN 回源防火墙区块，并恢复
`/etc/default/ufw` 与 Nginx 默认站点；UFW 保持启用并保留 SSH 放行。云端 Pull Zone 与 DNS 记录保留
，相关配置保存在 `/etc/easy_all-bunny/`。

### 清理云端资源与彻底卸载
```bash
sudo easy_all uninstall --purge-cloud
```
在卸载本机服务的同时，按 v3 journal 删除有明确创建归属、且当前状态仍匹配的 Pull Zone、
Hostname、Edge Rule 与 DNS 记录。复用资源、用户修改过的资源和所有权不明的旧 journal
会保留；清理失败时本机状态与 journal 也会保留，以便使用同一命令重试。

---

## 6. 安全机制说明

- **私有回源鉴权**：Bunny 边缘向源站发起请求时会自动注入随机生成的 `X-Easy-All-Origin-Key` 请求头；Nginx 遇到该请求头不匹配的访问直接返回 404，防止扫描器绕过 CDN 直连源站。
- **防火墙 IP 白名单**：源站 443 端口受 UFW 保护，只对 Bunny 官方回源 IP 网段放行，且由定时器持续跟踪官方列表自动刷新。
- **凭据最小化存储**：API Key 与 Token 仅由 root 保存在 `/etc/easy_all-bunny/`（权限 `0600`），不写入公开日志、订阅链接或客户端配置。
