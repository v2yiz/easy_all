# easy_all

当前版本：[5.2.2](CHANGELOG.md#522-更新说明2026-11-12)

`easy_all` 是专为全新 **Debian 12/13 及 Ubuntu 22.04/24.04/26.04 LTS**（amd64 / arm64）设计的单节点代理一键安装工具。通过控制台交互引导，一键打通 sing-box、Caddy 订阅分发、UFW 防火墙、Fail2ban 及 Skyline Speeder TCP 加速（基于 Zabbly 6.12+ LTS 内核）。

仅支持 IPv4。一台 VPS 仅可部署一种模式，建议在无其他业务占用的纯净系统上安装。

---

## 📚 详细文档

- [前置准备手册](docs/preparation-guide.md)：Cloudflare API Token、AWS 访问密钥准备与域名规划
- [客户端使用指南](docs/client-guide.md)：主流客户端（Mihomo / sing-box）配置导入与分流排障
- [运维与排障指南](docs/operations-guide.md)：日常维护、配置同步、证书轮换、流量保护与卸载
- [系统技术参考](docs/technical-reference.md)：架构设计、回源链路、安全防护与底层实现原理

---

## 模式选择

五种模式共用同一套本机运行时（sing-box 节点入站 + Caddy 订阅与回源分发）。**客户端节点与订阅入口统一使用 443 端口**。

| 模式 | 适用场景 | 客户端节点入口 | 订阅入口 | 所需凭据 | 域名数量 |
| :--- | :--- | :--- | :--- | :--- | :---: |
| **1. AnyTLS 直连** | VPS IP 纯净、直连质量优良 | `direct:443` | `sub:443` (deploy) 或无 (link) | Cloudflare Token | 1–2 |
| **2. 纯 CloudFlare** | 只要 CDN 入口且回源仅限 CF | `cf:443` (橙云 CDN) | `cf:443` | Cloudflare Token | 1 |
| **3. AnyTLS + CloudFlare** | 同时需要直连与橙云 CDN 节点 | `direct:443` + `cf:443` | `cf:443` | Cloudflare Token | 2 |
| **4. 纯 CloudFront** | 只要 CDN 入口隐藏源站 IP | `cf:443` (AWS CDN) | `cf:443` | Cloudflare Token + AWS 密钥 | 2 |
| **5. AnyTLS + CloudFront** | 同时需要直连与 CDN 节点 | `direct:443` + `cf:443` | `cf:443` | Cloudflare Token + AWS 密钥 | 2 |

> **核心约定**：
> - **端口规范**：客户端统一连接 `443`，全模式不开放 `80`。回源端口在模式 1 deploy、2 与 3 仅对 Cloudflare 官方回源 IP 放行（模式 1/3 为 `8443`，模式 2 为 `443`）；模式 5 源站 `8443` 对公网可达，由 `X-Easy-All-Origin-Key` 密钥精确校验。
> - **协议与证书**：CDN 节点均为 **VLESS WebSocket**。模式 1/3/5 直连与模式 4/5 源站使用 Let's Encrypt（DNS-01 自动签发），模式 4/5 的 CloudFront 客户端证书由 AWS ACM 托管，模式 2 回源使用 Cloudflare Origin CA（客户端连接 CF 边缘证书）。
> - **Cloudflare SSL**：模式 1 deploy、2、3 要求目标 Zone 的 SSL/TLS 必须为 **Full (strict)**。
> - **升级提示**：不支持从 4.x 直接升级，请先执行旧版 `sudo easy_all uninstall` 后重新安装。

> [!WARNING]
> **Cloudflare 提供免费套餐，但官方规则限制通过 CDN 代理翻墙流量，模式 2 与模式 3 存在潜在封禁风险，请自行评估使用。**
>
> **模式 4 与模式 5 使用 Cloudfront。注册 AWS 账号时需要绑定信用卡，使用 CloudFront 流量超过 1 TB 会产生费用。**
> Cloudflare注册简单，Cloudfront更稳定，晚高峰效果好。

---

## 开始前准备

1. **服务器环境**：全新 Debian 12/13 或 Ubuntu 22.04/24.04/26.04 LTS（具备公网 IPv4 与 root 权限，`443`、回环 `10086` 及所选模式回源端口未被占用）。
2. **内存与 Swap**：安装包含内核与网络优化，内存 ≤ 1GB 的机器请确保根分区剩余 ≥ 1.5GB 以便自动创建 Swap，避免编译 Skyline 时 OOM。
3. **安全组与防火墙**：
   - 放行 SSH 端口；
   - 模式 1/3/4/5 放行公网 TCP `443`（模式 5 另需放行 TCP `8443`）；
   - 模式 2 的 `443` 以及模式 1 deploy / 3 的 `8443` 仅对 Cloudflare 官方回源 IPv4 段放行（UFW 自动配置，云安全组需同步放行）。
   - **回源端口不得预先全局放行**：机器上若已有 `ufw allow 443/tcp` 或 `ufw allow 8443/tcp`（来源 `Anywhere`、`Any` 或 `0.0.0.0/0`），安装会在写入防火墙规则与云资源**之前**中止，并提示先 `ufw status` 查明后移除；否则回源端口仍对全网开放，绕过 Cloudflare-only 边界。
4. **云端凭据准备**：
   - **Cloudflare API Token**（全模式）：`Zone Read` + `DNS Edit`；模式 1 deploy / 2 / 3 另需 `Zone Settings Read`（校验 `Full (strict)`），模式 1 deploy / 3 另需 `Origin Rules Edit`，模式 2 另需 `SSL and Certificates Edit`。
   - **AWS IAM 密钥**（仅模式 4/5）：仅需 CloudFront 与 ACM（`us-east-1`）权限，仅在内存暂存不落盘。
   - 权限明细与域名规划详见 [前置准备手册](docs/preparation-guide.md)。

---

## 开始前：SSH 连接保活（建议配置）

安装过程包含系统更新、内核与网络优化（约 5~15 分钟），SSH 偶发空闲超时会导致安装半途中断。强烈建议在本地客户端配置保活（macOS/Linux 为 `~/.ssh/config`，Windows 为 `C:\Users\<用户名>\.ssh\config`；**务必追加在文件最底部**，避免通用匹配覆盖其他主机的特定配置）：

```sshconfig
# 追加到 ~/.ssh/config（Windows 为 C:\Users\<用户名>\.ssh\config）最底部（务必放最下面）
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
```

- **临时连接命令**（PowerShell / 终端通用）：`ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10 <用户>@<IP> -p <端口>`。
- **会话防中断**：强烈建议在 VPS 上的 `tmux` 或 `screen` 会话中执行安装；万一因切网中断，重新连接后再次运行安装命令即可无缝续装。

---

## 一键安装

登录 VPS 执行安装命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) install
```

根据终端交互引导完成配置：
1. **选择模式**：输入 `1`–`5` 选择部署模式。
2. **填写参数**：根据提示输入域名、Cloudflare Token 及订阅配置（支持直接回车使用推荐默认值；模式 4/5 会提示输入 AWS 密钥）。模式 2–5 还会提示 `CDN 优选前缀`（直接回车采用随机 10 位前缀，拼装成优选域名）。
3. **全自动部署**：自动配置 Swap、TCP 加速、申请证书、下发云端分发与解析，并完成可用性验收。

---

## 客户端导入

安装完成后，按提示重启系统使内核与加速生效：

```bash
sudo reboot
```

重启后查看服务状态与专属订阅地址：

```bash
sudo easy_all status
sudo easy_all subscription
```

- **客户端支持**：支持导入 **Mihomo (Clash Verge Rev / Clash Nyanpasu / FlClash)**、**sing-box (SFA / SFI / SFM / SFT / SFW / SFL)** 等主流客户端。
- **自动适配**：订阅接口按 User-Agent 自动分发 sing-box 完整 JSON、Mihomo 配置或通用 Base64。支持通过 `&flag=singbox|clash|base64` 强制格式，或追加 `&node=all` 携带外部聚合节点。
- 更多客户端配置、规则分流与导入故障排查详见 [客户端使用指南](docs/client-guide.md)。

---

## 常用运维命令

安装后全局注册 `easy_all` 命令：

| 命令 | 功能说明 |
| :--- | :--- |
| `sudo easy_all status` | 查看系统负载、TCP 加速、服务运行状况、证书与流量保护额度 |
| `sudo easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `sudo easy_all show` | 打印各节点详细参数、VLESS 链接与客户端配置片段 |
| `sudo easy_all apply` | **纯本机重建**：刷新服务配置与订阅产物（不请求云端 API） |
| `sudo easy_all apply-cloud` | **同步云端资源**：重新收敛 DNS、证书、CloudFront 分发或 Origin Rule |
| `sudo easy_all edit-sub` | 交互式管理用户 Token 与外部聚合节点（也可改或删除 `cdnEdgeAddress` 优选连接地址） |
| `sudo easy_all renew-cert` | 重新签发或轮换当前模式的 TLS 证书 |
| `sudo easy_all cdn-traffic-sync` | （仅模式 4/5）手动采样 CDN 流量并同步熔断状态 |
| `sudo easy_all update-core` | 重装或修复锁定版本的 sing-box 与 Caddy 核心 |
| `sudo easy_all self-update` | 从 GitHub 更新 `easy_all` 脚本自身（`--dev` 切换开发分支） |
| `sudo easy_all cleanup-partial` | 清理安装中断留下的本机临时残留（不改动云端资源） |
| `sudo easy_all purge-cloud` | 独立清理当前域名下的 easy_all Cloudflare 与 CloudFront/ACM 资源 |
| `sudo easy_all uninstall` | 完整卸载本机服务并同步清理关联云端资源 |

---

## 核心防护特性

- **端口隐蔽与防爆破**：全模式不开放 80 端口（证书走 DNS-01），保留现有 SSH 端口并由 Fail2ban 实时封禁恶意爆破 IP。
- **源站访问鉴权**：
  - 模式 1/2/3 回源端口在 UFW 层面仅放行 Cloudflare 官方回源网段；
  - 模式 4/5 源站注入 `X-Easy-All-Origin-Key` 密钥并由 Caddy 精确校验，防探测与未授权直连。
- **CloudFront 流量熔断保护（模式 4/5）**：本机内置 985 GB 近似流量计量监控，达到阈值自动熔断 CDN 访问（直连不受影响），降低 AWS 超额账单风险（详见[运维指南](docs/operations-guide.md#6-cdn-流量保护985-gb-熔断仅模式-45)）。
- **内网与恶意流量阻断**：sing-box 默认拦截回环、私有网段及元数据请求，防止节点被用于 SSRF 滥用。

完整架构设计与实现细节请参阅 [系统技术参考](docs/technical-reference.md)。
