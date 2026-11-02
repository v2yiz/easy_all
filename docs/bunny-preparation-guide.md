# Bunny CDN 前置准备与运维

模式 `4` 使用 Bunny CDN 的全球边缘网络分发 VLESS WS/TLS 节点与 owner 订阅。VPS 端由 Nginx 终止 HTTPS 回源并校验私有 Header，内部反代至 Xray（监听 `127.0.0.1:10086`）。

---

## 1. 链路架构

```text
客户端 (VLESS WS/TLS)
  │
  ▼
cdn.example.com (Cloudflare DNS-only CNAME)
  │
  ▼
<pull-zone>.b-cdn.net (Bunny CDN 边缘，自动调度优选节点，强制 HTTPS)
  │  (携带私有请求头 X-Easy-All-Origin-Key)
  ▼
https://origin.example.com (Cloudflare DNS-only A -> VPS 公网 IPv4:443)
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
- **系统要求**：Debian 12 / 13 amd64 纯净系统，仅支持 IPv4。
- **端口放行**：云厂商安全组放行 TCP `443` 及当前 SSH 端口。

### 2.2 Bunny 账户与 API Key
1. 登录 [Bunny Dashboard](https://dash.bunny.net/)。
2. 确保账户内有可用余额（CDN 流量计费及 WebSocket 连接计费）。
3. 进入 **Account Settings → API Key**，复制 **Account API Key**（非 Pull Zone 密码）。安装器会使用该 Key 自动创建 Pull Zone、配置 Edge Rule、绑定自定义域名及申请边缘证书。

### 2.3 Cloudflare 域名与 API Token
1. 准备一个在 Cloudflare 处于 **Active** 状态的根域名（如 `example.com`）。
2. 规划两个子域名（安装器会自动创建 DNS 记录，无需提前手动添加）：
   - **源站域名**（如 `origin.example.com`）：解析为 VPS 公网 IPv4（DNS-only A 记录）。
   - **CDN 节点域名**（如 `cdn.example.com`）：指向 Bunny Pull Zone（DNS-only CNAME 记录），供客户端连接与订阅。
3. 进入 Cloudflare **My Profile → API Tokens → Create Token**，创建具备以下权限的自定义 Token：
   - 权限：`Zone - DNS - Edit`、`Zone - Zone - Read`
   - 资源范围：限制为包含上述域名的根 Zone。

---

## 3. 安装与配置

在 VPS 上执行一键安装：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh)
# 或源码安装：sudo ./easy_all install
```

在菜单中选择 **`4. Bunny CDN`**，依次输入：
1. **Cloudflare 根 Zone**（如 `example.com`）
2. **源站域名**（回车默认 `origin.<zone>`）
3. **CDN 节点/订阅域名**（回车默认 `cdn.<zone>`）
4. **Pull Zone 月流量限制（GB）**（默认 `500`）
5. **Bunny Account API Key**（隐藏输入）
6. **Cloudflare DNS API Token**（隐藏输入）

安装器会自动完成以下操作：
1. **云端联动**：调用 Cloudflare API 创建 DNS 记录；调用 Bunny API 创建 Type 1 Volume Pull Zone、绑定 CDN 域名、开启强制 HTTPS 并配置回源头规则。
2. **源站证书**：通过 `lego` 利用 Cloudflare DNS-01 验证为源站域名签发 Let's Encrypt 证书。
3. **服务部署**：配置 Xray（监听 `127.0.0.1:10086`）与 Nginx 反向代理，生成专属 owner 订阅（包含 Base64 链接与 Mihomo YAML）。
4. **防火墙加固**：拉取 Bunny 官方回源 IP 列表，配置 UFW 仅允许 Bunny 边缘节点访问源站 443 端口。
5. **定时任务**：注册证书自动续期定时器及每 6 小时自动更新 Bunny 回源 IP 白名单的定时器。

---

## 4. 常用运维命令

安装完成后，可通过 `easy_all` CLI 管理本机与云端服务：

```bash
# 查看运行状态（Xray、Nginx、域名信息）
sudo easy_all status

# 查看节点链接与订阅地址
sudo easy_all subscription
sudo easy_all show

# 重新应用本机配置并同步云端资源状态
sudo easy_all apply-cloud

# 重新应用本机服务配置
sudo easy_all apply

# 强制重新签发 Let's Encrypt 源站证书并重载 Nginx
sudo easy_all renew-cert

# 立即刷新 Bunny 官方回源 IPv4 防火墙白名单
sudo easy_all refresh-origin-ips

# 切换 TCP 加速算法（bbrv3 / skyline）
sudo easy_all tcp bbrv3
```

---

## 5. 卸载

### 仅卸载本机服务
```bash
sudo easy_all uninstall
```
停止并删除 Xray、Nginx 站点配置及定时器，恢复 UFW 防火墙设置。云端 Pull Zone 与 DNS 记录保留，相关配置保存在 `/etc/easy_all-bunny/`。

### 清理云端资源与彻底卸载
```bash
sudo easy_all uninstall --purge-cloud
```
在卸载本机服务的同时，自动调用 Bunny API 与 Cloudflare API 删除安装时创建的 Pull Zone 及相关 DNS 记录。

---

## 6. 安全机制说明

- **私有回源鉴权**：Bunny 边缘向源站发起请求时会自动注入随机生成的 `X-Easy-All-Origin-Key` 请求头；Nginx 遇到该请求头不匹配的访问直接返回 404，防止扫描器绕过 CDN 直连源站。
- **防火墙 IP 白名单**：源站 443 端口受 UFW 保护，只对 Bunny 官方回源 IP 网段放行，且由定时器持续跟踪官方列表自动刷新。
- **凭据最小化存储**：API Key 与 Token 仅由 root 保存在 `/etc/easy_all-bunny/`（权限 `0600`），不写入公开日志、订阅链接或客户端配置。
