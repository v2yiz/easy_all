# easy_all

当前版本：[5.8.0](CHANGELOG.md#580-更新说明2026-11-26)

`easy_all` 是专为全新 **Debian 12/13 及 Ubuntu 22.04/24.04/26.04 LTS**（amd64 / arm64）设计的单节点代理一键安装工具。通过控制台交互引导，一键打通 sing-box（模式 5 为 Xray）节点核心、Caddy 订阅分发、UFW 防火墙、Fail2ban 及 Skyline Speeder TCP 加速（基于 Zabbly 6.12+ LTS 内核）。

仅支持 IPv4。一台 VPS 仅可部署一种模式，建议在无其他业务占用的纯净系统上安装。

---

## 📚 详细文档

- [前置准备手册](docs/preparation-guide.md)：Cloudflare API Token、AWS 访问密钥准备与域名规划
- [客户端使用指南](docs/client-guide.md)：主流客户端（Mihomo / sing-box）配置导入与分流排障
- [运维与排障指南](docs/operations-guide.md)：日常维护、配置同步、证书轮换、流量保护与卸载
- [系统技术参考](docs/technical-reference.md)：架构设计、回源链路、安全防护与底层实现原理

---

## 开始前准备

1. **服务器环境**：全新 Debian 12/13 或 Ubuntu 22.04/24.04/26.04 LTS（具备公网 IPv4 与 root 权限，`443`、回环 `10086`、伪装回环 `9443` 及所选模式回源端口未被占用）。
2. **内存与 Swap**：安装包含内核与网络优化，内存 ≤ 1GB 的机器请确保根分区剩余 ≥ 1.5GB 以便自动创建 Swap，避免编译 Skyline 时 OOM。
3. **安全组与防火墙**：
   - 放行 SSH 端口；
   - 公网仅需放行模式实际使用的业务端口：模式 2/3/4/5 放行 TCP `443`（模式 3 与模式 5 采用单 `443` 合一架构，仅放行公网 TCP `443`）；
   - 模式 1 的 `443` 以及模式 4 的 `8443` 仅对 Cloudflare 官方回源 IPv4 段放行（UFW 自动配置，云安全组需同步放行）；模式 2 的源站 `443` 及模式 3/5 经 `443` 回落至 `127.0.0.1:9443` 的源站对公网可达，由 `X-Easy-All-Origin-Key` 精确校验；模式 3/4/5 的伪装站仅监听本机回环 `127.0.0.1:9443`，模式 5 不开放 `8443`、也没有 Cloudflare 回源端口白名单。
   - **回源端口需严格限定来源**：机器上若已有 `ufw allow 443/tcp` 或 `ufw allow 8443/tcp`（来源 `Anywhere`、`Any` 或 `0.0.0.0/0`），安装会在写入防火墙规则与云资源**之前**中止，并提示先 `ufw status` 查明后移除，确保回源端口仅对 Cloudflare 官方回源 IPv4 段开放。
4. **云端凭据准备**：
   - **Cloudflare API Token**（全模式）：`Zone Read` + `DNS Edit`；模式 1/4/5 另需 `Zone Settings Read`（校验 `Full (strict)`），模式 4 另需 `Origin Rules Edit`，模式 5 另需 `Transform Rules Edit`，模式 1 另需 `SSL and Certificates Edit`。模式 5 还需在 Cloudflare 面板开启 `Network -> gRPC`（XHTTP 回源依赖，本工具只读校验不代改）。
   - **AWS IAM 密钥**（仅模式 2/3）：仅需 CloudFront 与 ACM（`us-east-1`）权限，仅在内存暂存不落盘。
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

## 模式选择

各模式共用同一套本机运行时（sing-box / Xray 节点入站 + Caddy 订阅与回源分发）。**客户端节点与订阅入口统一使用 443 端口**。

$\textcolor{red}{\textbf{模式推荐：}}$<br>
$\textcolor{red}{\textbf{线路一般+无可用信用卡，选模式 1}}$<br>
$\textcolor{red}{\textbf{线路一般+有可用信用卡，选模式 2}}$<br>
$\textcolor{red}{\textbf{线路好+有可用信用卡，选模式 3}}$<br>
$\textcolor{red}{\textbf{线路好+无可用信用卡，选模式 4}}$<br>
$\textcolor{red}{\textbf{线路好+无可用信用卡+不需要支持Sing-box客户端(多数人不需要)，选模式 5}}$<br>

| 模式 | 协议 | 所需凭据 |
| :--- | :--- | :--- |
| **1. 纯 CloudFlare** | VLESS HTTPUpgrade（橙云 CDN） | Cloudflare Token |
| **2. 纯 CloudFront** | VLESS WebSocket（AWS CloudFront） | Cloudflare Token + AWS 密钥 |
| **3. Reality + CloudFront** | VLESS Reality 直连 + VLESS WebSocket（AWS CloudFront） | Cloudflare Token + AWS 密钥 |
| **4. Reality + CloudFlare** | VLESS Reality 直连 + VLESS HTTPUpgrade（橙云 CDN） | Cloudflare Token |
| **5. Reality + CloudFlare（Xray）** | VLESS Reality 直连 + VLESS XHTTP（橙云 CDN，纯 Xray） | Cloudflare Token（需 Transform Rules Edit） |

> **核心约定**：
> - **域名规划**：全模式只需 **1 个根域名**（托管于同一 Cloudflare Zone），安装器会自动创建对应数量的一级子域名。
> - **端口规范**：客户端统一连接 `443`，全模式公网仅开放各自业务端口（证书统一走 DNS-01）。回源端口在模式 1（`443`）与模式 4（`8443`）仅对 Cloudflare 官方回源 IP 放行；模式 2 的源站 `443` 对公网可达；模式 3/5 采用单 `443` 合一架构，直连与 CDN 回源统一走公网 `443`，经核心透明回落至回环 `127.0.0.1:9443` 由 Caddy 按 `X-Easy-All-Origin-Key` 精确分流（模式 5 的该密钥由 Cloudflare Request Header Transform Rule 在边缘注入）。
> - **协议与证书**：CDN 节点传输按 CDN 家族区分：模式 1/4（橙云）为 **VLESS HTTPUpgrade**（HTTP/1.1 ALPN），模式 5（橙云 + Xray）为 **VLESS XHTTP**（`stream-up` + `h2`，经 Caddy `h2c` 反代到回环 `10086`），模式 2/3（CloudFront）为 **VLESS WebSocket**；模式 3/4/5 直连为 **VLESS Reality**（`xtls-rprx-vision`），非 Reality 握手透明回落到本机 `127.0.0.1:9443` 的伪装站（内置 4 套中性原型模板并按实例随机变异，支持在 `/var/www/easy_all/camouflage` 放入自定义静态站点且在 `apply`/`renew-cert`/`uninstall` 中自动保留）。模式 2/3 直连与源站使用 Let's Encrypt（DNS-01 自动签发），模式 4/5 通过两套独立 Certbot DNS-01 lineage（`easy_all` 仅覆盖直连域名、`easy_all-cdn` 仅覆盖橙云节点域名，无需额外 Cloudflare Token 权限）隔离证书 SAN；CloudFront 客户端证书由 AWS ACM 托管，模式 1 回源使用 Cloudflare Origin CA（客户端连接 CF 边缘证书）。
> - **Cloudflare SSL**：模式 1/4/5 要求目标 Zone 的 SSL/TLS 必须为 **Full (strict)**。
> - **升级提示**：不支持从 4.x 直接升级，请先执行旧版 `sudo easy_all uninstall` 后重新安装。
> - **旧 AnyTLS 模式已删除**：5.7.0 起不再提供 AnyTLS + CloudFront / AnyTLS + CloudFlare；已有该模式的安装请先用安装该版本的旧 easy_all 执行 `sudo easy_all uninstall`，再重新安装。
> - **模式 5 不可降级**：模式 5 安装后不能退回 5.7.0 及更早的脚本管理（旧版不认识 `easy_all-xray.service`）；需要人工脱离时按[运维指南的清理步骤](docs/operations-guide.md#10-模式-5xray-xhttp维护与不可降级说明)处理。

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

根据终端交互引导完成配置：
1. **选择模式**：输入 `1`–`5` 选择部署模式。
2. **填写参数**：根据提示输入域名、Cloudflare Token 及订阅配置（支持直接回车使用推荐默认值；模式 2/3 会提示输入 AWS 密钥）。所有模式都会提示 `CDN 优选前缀`（直接回车采用随机 10 位前缀，拼装成优选域名）。
3. **全自动部署**：自动配置 Swap、TCP 加速、申请证书、下发云端分发与解析，并完成可用性验收。

> [!CAUTION]
> **SSH 端口提醒（所有模式安装成功后询问，重启后生效）**
> - **三选一**：安装收尾让你选 SSH 端口变更方式——`1. 不变更`（保持当前检测到的端口）、`2. 修改为 22222`（直接回车即选它）、`3. 自定义端口`。
> - **选了变更**：迁移到新端口后旧端口被禁用（UFW 与 Fail2ban 同步生效），后续用 `ssh -p <新端口> <用户>@<服务器 IP>` 登录（默认 `ssh -p 22222 …`），并在提示确认后重启生效；初始就不是 `22` 的主机会把当时真正在用的端口一并采集并禁用。若使用 AWS / GCP 等外部安全组，请先放行 **TCP 新端口** 再重启。
> - **选了不变更**：`sshd` 配置与 UFW 都保持原样，安装收尾不会出现 SSH 端口警示；仅当需要换内核时才提示重启，之后仍用原端口登录。

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

- **客户端支持**：优先推荐使用 **FlClash**，也支持 **Mihomo (Clash Verge Rev / Clash Nyanpasu)**、**sing-box (SFA / SFI / SFM / SFT / SFW / SFL)**，iOS 端可使用 **Shadowrocket（小火箭，需使用外区 Apple ID）** 等主流客户端。
- **自动适配**：订阅接口按 User-Agent 自动分发 sing-box 完整 JSON、Mihomo 配置或通用 Base64。支持通过 `&flag=singbox|clash|base64` 强制格式，或追加 `&node=all` 携带外部聚合节点。
- **模式 5 不提供 sing-box JSON 订阅**：只输出 Base64 与 Mihomo（含 `-all` 与 iOS 变体）共 6 份产物，请使用 Mihomo/FlClash/Stash 或 Shadowrocket/v2rayN（`flag=singbox` 在该模式返回 503）。
- 更多客户端配置、规则分流与导入故障排查详见 [客户端使用指南](docs/client-guide.md)。

---

## 常用运维命令

安装后全局注册 `easy_all` 命令（需 root 权限运行，非 root 用户请加 `sudo`）：

| 命令 | 功能说明 |
| :--- | :--- |
| `easy_all status` | 查看系统负载、TCP 加速、服务运行状况、证书与流量保护额度 |
| `easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `easy_all show` | 打印各节点详细参数、VLESS 链接与客户端配置片段 |
| `easy_all apply` | **纯本机重建**：刷新服务配置与订阅产物（不请求云端 API） |
| `easy_all apply-cloud` | **同步云端资源**：重新收敛 DNS、证书、CloudFront 分发、Origin Rule 或 Transform Rule |
| `easy_all edit-sub` | 交互式管理用户 Token 与外部聚合节点<br>（也可改或删除 `cdnEdgeAddress` 优选连接地址） |
| `easy_all renew-cert` | 重新签发或轮换当前模式的 TLS 证书 |
| `easy_all hellogfw` | （仅模式 3/4/5）分析直连 TCP 443 主动探测日志线索；`hellogfw -h` 免 root<br>示例：`easy_all hellogfw --since "7 days ago" --my-ip 203.0.113.10 --my-ip 198.51.100.20`<br>`--my-ip` 非必选；不加时输出的 IP 也可能是你自己的客户端请求 |
| `easy_all cdn-traffic-sync` | （仅模式 2/3）手动采样 CDN 流量并同步熔断状态 |
| `easy_all update-core` | 重装或修复锁定版本的核心（sing-box 模式为 sing-box + Caddy，模式 5 为 Xray + Caddy） |
| `easy_all self-update` | 从 GitHub 更新 `easy_all` 脚本自身（`--dev` 切换开发分支） |
| `easy_all cleanup-partial` | 清理安装中断留下的本机临时残留（不改动云端资源） |
| `easy_all purge-cloud` | 独立清理当前域名下的 easy_all Cloudflare 与 CloudFront/ACM 资源 |
| `easy_all uninstall` | 完整卸载本机服务并同步清理关联云端资源 |

---

## 核心防护特性

- **端口隐蔽与防爆破**：全模式证书统一走 DNS-01（公网仅开放各自业务端口），安装收尾可选把 SSH 端口迁移到新端口（默认 `22222`，也可选保持当前端口不变），迁移后禁用原端口（重启后生效），由 Fail2ban 实时封禁恶意爆破 IP。
- **源站访问鉴权**：
  - 模式 1/4 回源端口在 UFW 层面仅放行 Cloudflare 官方回源网段；
  - 模式 2/3 源站注入 `X-Easy-All-Origin-Key` 密钥并由 Caddy 精确校验（模式 3 经单 `443` 合一回落至回环 `127.0.0.1:9443` 按密钥分流，公网仅开放 TCP `443`，无头/错头直落伪装站），防探测与未授权直连；
  - 模式 5 的同一密钥由 Cloudflare Request Header Transform Rule 在边缘注入，源站 Caddy 在 `127.0.0.1:9443` 的双证书双站点上精确校验，缺头/错头静默回落伪装站。
- **CloudFront 流量熔断保护（模式 2/3）**：本机内置 985 GB 近似流量计量监控，达到阈值自动熔断 CDN 访问（直连、订阅与模式 3 的伪装站不受影响），降低 AWS 超额账单风险（详见[运维指南](docs/operations-guide.md#6-cdn-流量保护985-gb-熔断仅模式-23)）。
- **内网与恶意流量阻断**：服务端核心（sing-box / Xray）显式路由拦截回环、私有网段、多播与保留段，并强制 IPv4 解析，防止节点被用于 SSRF 滥用。
- **直连主动探测日志（模式 3/4/5）**：安装或 `apply` 时落一条限速（30/min）的内核 LOG 规则（前缀 `GFW_CHK:`，只记 TCP 443 SYN），配合一个 oneshot systemd 单元在重启与 UFW reload 后重放；平时不跑常驻进程，用 `sudo easy_all hellogfw` 按需做启发式分析（`hellogfw -h` 免 root）。同一时机写入的 journald drop-in 设置 `MaxRetentionSec=30day`——**这是 systemd-journald 的全局保留上限，影响主机全部日志**，超出上限的主机历史日志可能被 vacuum 且无法恢复，详见[运维指南](docs/operations-guide.md#8-直连主动探测日志分析仅模式-345)。

完整架构设计与实现细节请参阅 [系统技术参考](docs/technical-reference.md)。
