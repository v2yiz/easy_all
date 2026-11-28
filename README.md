# easy_all

当前版本：[5.10.2](CHANGELOG.md#5102-更新说明2026-11-28)

`easy_all` 是专为全新 **Debian 12/13 及 Ubuntu 22.04/24.04/26.04 LTS**（amd64 / arm64）设计的单节点代理一键安装工具。通过交互引导一键部署节点核心（sing-box / Xray）、Caddy 订阅分发、UFW 防火墙、Fail2ban 与 Skyline Speeder TCP 加速（基于 Zabbly 6.12+ LTS 内核）。

仅支持 IPv4。一台 VPS 仅可部署一种模式，建议在无其他业务占用的纯净系统上安装。

---

## 📚 详细文档

- [前置准备手册](docs/preparation-guide.md)：Cloudflare API Token、AWS 访问密钥准备与域名规划
- [客户端使用指南](docs/client-guide.md)：主流客户端（Mihomo / sing-box）配置导入与分流排障
- [运维与排障指南](docs/operations-guide.md)：日常维护、配置同步、证书轮换、流量保护与卸载
- [系统技术参考](docs/technical-reference.md)：架构设计、回源链路、安全防护与底层实现原理

---

## 开始前准备

1. **服务器环境**：全新 Debian 12/13 或 Ubuntu 22.04/24.04/26.04 LTS（具备公网 IPv4 与 root 权限，`443`、回环 `10086` / `9443` 及所选模式回源端口未被占用）。
2. **内存与 Swap**：内存 ≤ 1GB 的机器请确保根分区剩余 ≥ 1.5GB 以便自动创建 Swap，避免编译 Skyline 时 OOM。
3. **安全组与防火墙**：
   - 放行 SSH 端口，并按模式放行公网业务端口：模式 2/3/5 放行 TCP `443`；模式 1 放行 `443`、模式 4 放行 `443` 与 `8443`（其中模式 1 的 `443` 与模式 4 的 `8443` 仅对 Cloudflare 官方回源 IPv4 段开放，UFW 会自动配置，云安全组需同步放行）。
   - **回源端口需严格限定来源**：若机上已有 `ufw allow 443/tcp` 或 `ufw allow 8443/tcp`（`Anywhere` / `Any` / `0.0.0.0/0`），安装前会中止并提示先清理，避免绕过回源白名单。
4. **云端凭据准备**（权限明细见 [前置准备手册](docs/preparation-guide.md)）：
   - **Cloudflare API Token**（全模式）：`Zone Read` + `DNS Edit`；模式 1/4/5 另需 `Zone Settings Read`（校验 `Full (strict)`），模式 1 另需 `SSL and Certificates Edit`，模式 4 另需 `Origin Rules Edit`，模式 5 另需 `Transform Rules Edit`。使用模式 1/5 时，还需在 Cloudflare 面板开启 `Network -> gRPC`（本工具只读提示，不代改）。
   - **AWS IAM 密钥**（仅模式 2/3）：仅需 CloudFront 与 ACM（`us-east-1`）权限，仅在内存暂存不落盘。

---

## 开始前：SSH 连接保活（建议配置）

安装包含系统更新、内核与网络优化（约 5~15 分钟），建议在本地客户端配置保活（macOS/Linux 为 `~/.ssh/config`，Windows 为 `C:\Users\<用户名>\.ssh\config`；**务必追加在文件最底部**，避免通用匹配覆盖特定主机配置）：

```sshconfig
# 追加到 ~/.ssh/config（Windows 为 C:\Users\<用户名>\.ssh\config）最底部（务必放最下面）
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 10
    TCPKeepAlive yes
```

- **临时连接命令**（PowerShell / 终端通用）：`ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=10 <用户>@<IP> -p <端口>`。
- **会话防中断**：建议在 VPS 的 `tmux` 或 `screen` 中执行安装；如因断网中断，重连后再次运行安装命令即可无缝续装。

---

## 模式选择

各模式客户端节点与订阅入口统一使用 **443 端口**。

$\textcolor{red}{\textbf{模式推荐：}}$<br>
$\textcolor{red}{\textbf{(注意，XHTTP协议不支持Sing-box客户端，所以模式1和模式5只能使用小火箭或者Mihomo核心的客户端)}}$<br>
$\textcolor{red}{\textbf{线路一般+无可用信用卡，选模式 1(纯Xray)}}$<br>
$\textcolor{red}{\textbf{线路一般+有可用信用卡，选模式 2}}$<br>
$\textcolor{red}{\textbf{线路好+有可用信用卡，选模式 3}}$<br>
$\textcolor{red}{\textbf{线路好+无可用信用卡，选模式 4}}$<br>
$\textcolor{red}{\textbf{线路好+无可用信用卡，选模式 5(纯Xray)}}$<br>

| 模式 | 核心 | 协议 | 所需凭据 |
| :--- | :--- | :--- | :--- |
| **1. 纯 CloudFlare** | Xray | VLESS XHTTP | Cloudflare Token |
| **2. 纯 CloudFront** | sing-box | VLESS WebSocket | Cloudflare Token + AWS 密钥 |
| **3. Reality + CloudFront** | sing-box | VLESS Reality + WebSocket | Cloudflare Token + AWS 密钥 |
| **4. Reality + CloudFlare** | sing-box | VLESS Reality + HTTPUpgrade | Cloudflare Token |
| **5. Reality + CloudFlare** | Xray | VLESS Reality + XHTTP | Cloudflare Token |

> **核心约定**：
> - **域名规划**：全模式只需 **1 个根域名**（托管于同一 Cloudflare Zone），安装器自动创建所需一级子域名。
> - **架构与证书**：全模式证书统一走 DNS-01。模式 3/4/5 直连采用 VLESS Reality（`xtls-rprx-vision`），非 Reality 握手透明回落至本机 `127.0.0.1:9443` 伪装站（支持在 `/var/www/easy_all/camouflage` 放入自定义静态站点，维护与卸载均自动保留）；模式 3/5 采用单 `443` 合一架构，按 `X-Easy-All-Origin-Key` 精确分流（模式 5 由 Transform Rule 在边缘注入）；模式 1/4/5 要求 Zone 的 SSL/TLS 为 **Full (strict)**。
> - **升级与兼容性**：不支持从 4.x 或旧 AnyTLS 模式直接升级，请先用旧版执行 `sudo easy_all uninstall` 后重装；模式 1 安装后不可退回 5.8.0 及更早版本管理，模式 5 安装后不可退回 5.7.0 及更早版本管理，脱离步骤见[运维指南](docs/operations-guide.md#10-模式-15xray-xhttp维护与不可降级说明)。

> [!WARNING]
> **Cloudflare 提供免费套餐，但官方规则限制通过 CDN 代理翻墙流量，模式 1、4、5 存在潜在封禁风险，请自行评估使用。**
>
> **模式 2 与 3 使用 CloudFront。注册 AWS 账号时需要绑定信用卡，使用 CloudFront 流量超过 1 TB 会产生费用。**
>
> **Cloudflare注册简单，CloudFront更稳定，晚高峰效果好。**

---

## 一键安装

登录 VPS 执行安装命令：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) install
```

按交互提示完成配置：
1. **选择模式**：输入 `1`–`5`。
2. **填写参数**：输入域名、Cloudflare Token、订阅配置及 `CDN 优选前缀`（直接回车采用默认值；模式 2/3 另需 AWS 密钥）。
3. **全自动部署**：自动完成 Swap、TCP 加速、证书签发、云端配置下发与可用性验收。

> [!CAUTION]
> **SSH 端口提醒（安装收尾询问，重启后生效）**
> - **三选一**：`1. 不变更`（保持原端口）、`2. 修改为 22222`（默认回车）、`3. 自定义端口`。
> - **若选择变更**：新端口启用同时旧端口将被 UFW 与 Fail2ban 禁用，请使用 `ssh -p <新端口> <用户>@<IP>` 登录；使用 AWS / GCP 等外部安全组时，请先放行新端口再重启。

---

## 客户端导入

安装完成后重启系统使内核与加速生效，再查看状态与订阅地址：

```bash
sudo reboot
```

```bash
sudo easy_all status
sudo easy_all subscription
```

- **Mihomo 内核客户端（全模式，推荐）**：**FlClash**（优先推荐）、**Clash Verge Rev**、**Clash Mi**（iOS 需外区 Apple ID）、**Clash Meta for Android**、**Bettbox**、**Stash** 等（内核建议 ≥ 1.19.9）。自动下发含分流规则的 Mihomo YAML 配置（iOS 自动适配低内存配置）。
- **通用 / Xray 客户端（全模式）**：**Shadowrocket（小火箭，iOS 需外区 Apple ID）**、**v2rayN / v2rayNG** 等（默认下发通用 Base64 节点列表，不含服务端分流规则；模式 1/5 需客户端版本支持 XHTTP）。
- **sing-box 官方客户端（仅模式 2/3/4）**：**SFA / SFI / SFM / SFT / SFW / SFL**（内核需 ≥ 1.14.0）。由于官方 sing-box 不支持 XHTTP，**模式 1/5 无法使用**（不生成 `singbox.json`，指定 `&flag=singbox` 返回 `503`）。
- **订阅自动识别与手动参数**：按客户端 `User-Agent` 自动分发对应格式；也可追加 `&flag=clash|base64|singbox` 强制指定格式，或追加 `&node=all` 附带外部聚合节点。
- 下载链接、各系统安装与分流排障详见 [客户端使用指南](docs/client-guide.md)。

---

## 常用运维命令

安装后全局注册 `easy_all` 命令（需 root 权限运行，非 root 用户请加 `sudo`）：

| 命令 | 功能说明 |
| :--- | :--- |
| `easy_all status` | 查看系统负载、TCP 加速、服务状态、证书与流量保护额度 |
| `easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `easy_all show` | 打印节点详细参数、VLESS 链接与客户端配置片段 |
| `easy_all apply` | **纯本机重建**：刷新服务配置与订阅产物（不请求云端 API） |
| `easy_all apply-cloud` | **同步云端资源**：重新收敛 DNS、证书、CloudFront 分发、Origin Rule 或 Transform Rule |
| `easy_all edit-sub` | 交互式管理用户 Token、外部聚合节点与 `cdnEdgeAddress` 优选地址 |
| `easy_all renew-cert` | 重新签发或轮换当前模式的 TLS 证书 |
| `easy_all hellogfw` | （仅模式 3/4/5）分析直连 TCP 443 主动探测日志；`hellogfw -h` 免 root<br>示例：`easy_all hellogfw --since "7 days ago" --my-ip 203.0.113.10`（未传 `--my-ip` 时结果可能包含自用客户端 IP） |
| `easy_all cdn-traffic-sync` | （仅模式 2/3）手动采样 CDN 流量并同步熔断状态 |
| `easy_all update-core` | 重装或更新核心（sing-box / Caddy 锁定版本，Xray 跟踪最新官方 Release） |
| `easy_all self-update` | 从 GitHub 更新 `easy_all` 脚本自身（`--dev` 切换开发分支） |
| `easy_all cleanup-partial` | 清理安装中断留下的本机临时残留（不改动云端资源） |
| `easy_all purge-cloud` | 独立清理当前域名下的 Cloudflare 与 CloudFront / ACM 资源 |
| `easy_all uninstall` | 完整卸载本机服务并同步清理关联云端资源 |

---

## 核心防护特性

- **防爆破与源站隔离**：Fail2ban 实时封禁 SSH 爆破；模式 1/4 回源端口仅放行 Cloudflare 官方回源网段，模式 2/3/5 通过 `X-Easy-All-Origin-Key` 精确校验，无头或错头请求在模式 3/5 静默回落伪装站。
- **CloudFront 流量熔断（模式 2/3）**：内置 985 GB 近似流量计量监控，超阈值自动熔断 CDN 访问（直连、订阅与伪装站不受影响），详见[运维指南](docs/operations-guide.md#6-cdn-流量保护985-gb-熔断仅模式-23)。
- **SSRF 与保留网段阻断**：服务端显式路由拦截回环、私网、多播与保留段并强制 IPv4 解析，防止节点被用于内网探测。
- **直连主动探测日志（模式 3/4/5）**：仅以限速内核 LOG 规则记录 TCP 443 SYN 线索（无常驻分析进程），按需用 `sudo easy_all hellogfw` 启发式分析。该功能会设置 systemd-journald 全局保留上限 `MaxRetentionSec=30day`，**影响主机全部日志**（超期历史日志会被清理且不可恢复），详见[运维指南](docs/operations-guide.md#8-直连主动探测日志分析仅模式-345)。

完整架构设计与实现细节请参阅 [系统技术参考](docs/technical-reference.md)。
