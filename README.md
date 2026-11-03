# easy_all

当前源码版本：[2.1.1](CHANGELOG.md#211-更新说明2026-11-03)。

`easy_all` 是面向全新 Debian 12/13 VPS 的单节点交互安装器（所有模式支持 amd64，Bunny 另支持 arm64）。它统一配置 Xray、Nginx、
订阅、UFW、Fail2ban 和 TCP 加速（默认安装并启用 Skyline Speeder）。

只支持 IPv4。同一台 VPS 只能安装一种模式，并应作为不承载其他业务的专用服务器。

## 选择模式

| 模式 | 适用情况 | 协议与入口 |
| --- | --- | --- |
| **1. 直连 Reality** | VPS 公网 IP 可用且直连质量良好 | VLESS TCP Reality Vision，VPS `443` |
| **2. Cloudflare CDN** | 直连效果不佳、VPS 公网 IP 已被封，或明确需要纯 XHTTP | VLESS XHTTP `stream-up`，6 个 Cloudflare 精选 IPv4；可选独立纯 Worker 兜底 |
| **3. Bunny CDN** | 使用 Bunny 自动调度的 WS 域名入口 | 一个 VLESS WS/TLS 节点；同域 owner Token 通用/Mihomo 订阅；Nginx HTTPS 回源 |
| **4. Gcore CDN** | 追求多地区边缘入口与三网定向直连 | VLESS WebSocket / TLS，Gcore + Globalping IPv4（三网定向 1～6 个已验证节点，通常为 2 个） |
| **5. 组合** | 一台 VPS 同时要直连与两个 CDN 入口 | VLESS Reality（VPS `8443`）+ Cloudflare XHTTP（6 个优选 IPv4）+ Gcore WS 域名节点；单一订阅，含 AUTO 测速组 |

Bunny 模式使用 Cloudflare 根 Zone 内两个不同域名、Bunny Account API Key 与 Cloudflare
DNS API Token。`origin` 使用 DNS-only A，`cdn` 使用 DNS-only CNAME 指向 Pull Zone 的
`*.b-cdn.net`；Cloudflare 管理 `origin` A 与 `cdn` CNAME，Bunny 管理 Pull Zone。
Bunny DNS Zone 的子域委派步骤见指南的可选扩展章节。月流量限制用于控制数据传输量，
WS 连接分钟另按 Bunny 账单计费。安装、可选子域委派说明及卸载恢复见
[Bunny 前置准备与运维](docs/bunny-preparation-guide.md)。

Cloudflare 模式完全没有域名兜底，需要额外准备：

- 同一 Cloudflare Active Zone 下互不相同的节点域名和订阅域名；
- 具备 Zone 权限和账户级 Workers Scripts Write 权限的 API Token；
- Globalping Token；
- 在 Cloudflare 控制台手动开启 gRPC。

还可选择部署一个独立的纯 Worker TCP 兜底节点。它使用单独的 Worker 名称、UUID、路径和
同 Zone 一级域名，不经过 VPS，也不计入 VPS 用户配额。订阅仅发布 6 个探测成功的优选 IPv4，
不发布域名入口；Mihomo 订阅会将这些节点放入
`🇭🇰CF` URL-Test 组。PROXY 依次列出 US_VMISS、`🇺🇸白天首选`、`🇺🇸晚上首选`、`🇭🇰CF` 和其他已配置的节点。
白天首选和 🇭🇰CF 设置 `hidden: true`，在 PROXY 中可选，内部自动测速选优，不单独展示分组。
所有代理流量使用 PROXY 当前选择，不再单独分流 YouTube。
Mihomo 全局模式通过显式 `GLOBAL → PROXY` 复用 `PROXY` 当前选择，不再平铺所有节点。
纯 Worker 使用 XHTTP `stream-one` 和原生流背压，支持持续下载；全部上行位于单个 HTTP
请求体内，仍受 Cloudflare 套餐请求体大小限制（Free/Pro 通常为 100 MB），大文件上传应在
`PROXY` 中选择 VPS 节点。

Gcore 模式面向非优化线路，采用 Xray 服务端，结合 Nginx mTLS 客户端证书鉴权回源；通过中国大陆三网、中国香港、中国台北、日本、新加坡、美国西海岸及多公共解析器的 Globalping 视角解析账户 CDN 域名，跨小时保留 7 天内发现的真实入口，再经本机 SNI/WebSocket 和三网定向测速筛选，下发 1～6 个实际有效节点，通常为 2 个，节点连续命名为 `🇺🇸优选1`～`🇺🇸优选n`；订阅支持通用模式 (Base64) 与 Clash 模式 (flag=clash)，内置单一 AUTO 自动测速组。需要准备：
- 委派至 Gcore Managed DNS 的域名 Zone；
- 具备 CDN 与 DNS 权限的 Gcore API Token；
- Globalping Token。
以上是模式 4 的要求；组合模式（菜单 5）的 Gcore 入口是一个域名节点，不需要委派 Gcore Managed DNS，
也不需要 Cloudflare gRPC，准备要求见下方组合模式段落。
组合模式（菜单 `5`）使用一个 Cloudflare Zone 下的六个子域名：直连域名（灰云 A）、
Cloudflare 节点与回源域名（橙云 A）、Gcore 节点（灰云 CNAME 到账户 `*.gcdn.co`）与回源域名
（灰云 A）、订阅域名（橙云 A）。安装时需要 Cloudflare DNS Token、Gcore CDN Token 与
Globalping Token；`443` 只对 Cloudflare 与 Gcore 官方回源网段开放，直连走 `8443`，
SSH 保持现状不改。不启用用户配额，订阅只有一个 owner Token。

前置准备详见 [前置准备手册](docs/preparation-guide.md)。

直连 Reality 安装时会选择订阅输出，默认不部署订阅：

| 选项 | 适用情况 | 需要准备 |
| --- | --- | --- |
| **1. 仅节点（默认）** | 只需要节点链接，自己维护订阅 | 无 |
| **2. 本机订阅** | 只有当前这一台直连节点 | 一个 Cloudflare 一级订阅域名、API Token |
| **3. Worker 订阅聚合** | 多台直连 Reality 节点统一下发，仍希望走 Workers | 同 Zone 两个一级域名（公开订阅域名 + 私有节点源域名）、具备 Workers Scripts Write 的 API Token |

Worker 聚合只在其中一台 VPS 部署：公开订阅域名绑定 Worker，私有节点源域名由 Cloudflare 代理回
本机 `8443` 且仅允许 Cloudflare 回源，Nginx 继续是 Token 与配额的唯一真源；其余直连节点以
聚合 JSON 的 `nodes` 形式写入，节点名必须互不重复。Worker 按请求实时回源，源不可用时返回
`502`，不会用静态节点绕过配额。

Reality/Cloudflare 的完整步骤见[前置准备手册](docs/preparation-guide.md)。Reality 只有在选择本机订阅或 Worker 聚合时
才需要 Cloudflare 域名和 API Token。

## 安装要求

- Debian 12 或 13；
- amd64/x86_64/x64；Bunny 模式另支持 arm64/aarch64；
- 公网 IPv4；
- systemd 环境，不能是 Docker、LXC 等容器；
- 当前 SSH 登录方式和服务商 Console/VNC 均可用；
- 没有其他 Xray、Nginx 或代理面板占用端口。

Reality/Cloudflare/Bunny/Gcore 安装会修改内核、SSH、UFW、Fail2ban、时区和 systemd 任务；
组合模式（菜单 5）不改 SSH，也不配置 Fail2ban。Bunny 保留当前 SSH 监听；ARM64 使用原有内核，
暂不支持 Skyline Speeder。
建议先创建 VPS 快照，并保留当前
SSH 会话，直到重启后确认新会话可以登录。服务商的安全组或云防火墙还需自行放行当前 SSH 端口
以及业务所需的 TCP `443`；组合模式还需放行 TCP `8443`（直连 Reality）。Reality 使用动态端口时，
还需放行 TCP `10000-62703`；VPS 安装和
`apply` 会立即加载整段 NAT，重启后由 UFW 持久化规则和 `@reboot` 刷新任务恢复。

## 快速安装

先从自己的电脑登录 VPS：

```bash
ssh <登录用户>@<VPS公网IP> -p <SSH端口>
```

看到 VPS 的 shell 提示符后运行：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh)
```

请原样执行，不要改成 `curl ... | sudo bash`。安装器需要持续从当前终端读取选项，并在需要时
单独请求 `sudo` 权限。

首次单用户安装可按以下方式选择：

| 提示 | 建议 |
| --- | --- |
| 安装模式 | 直连良好选 `1`；IP 被封、直连不佳或需要纯 XHTTP 选 `2`；Bunny WS 自动调度域名选 `3`；Gcore CDN 边缘入口选 `4`；一台机器要直连与两个 CDN 入口选 `5` |
| TCP 加速 | 默认自动配置 Skyline Speeder（安装过程不再提示，amd64 自动完成） |
| 订阅输出 | 直接回车不部署订阅；单机自用选 `2` 部署本机订阅；多台直连节点统一走 Workers 下发选 `3` |
| 月度用户配额 | 选 `1` 或直接回车，不启用 |
| 独立 Worker 兜底 | 按需启用；必须使用区别于节点域名和订阅域名的同 Zone 一级域名 |
| 定时重启 | 接受每日 `04:00` 重启选 `1`；不需要则选 `3` |
| Reality SNI/目标 | 直接回车使用已验证默认值 |
| Reality 动态端口 | 直接回车 |

提示中的 `[值]` 是直接回车采用的默认值。Token 和密码输入时不会显示字符。

## 完成安装

安装末尾按提示选择是否立即重启。若选择跳过，再手动执行：

```bash
sudo reboot
```

重新登录后验证：

```bash
sudo easy_all status
sudo easy_all subscription
```

系统状态显示 `Skyline Speeder: active` 即表示已生效（内核未达到 6.12 时安装器会自动安装 6.12+ 内核并在重启后自动激活）。复制 `subscription` 输出中带
`flag=clash` 的 Mihomo 地址，在客户端通过 URL 导入。订阅地址与 UUID 都是访问凭据，不要公开。

客户端选择、Clash Mi 设置和订阅 DNS 排障见[客户端使用指南](docs/client-guide.md)。
默认订阅模板是 COMMON 精简规则（以低内存为目标，不保证 iPhone 峰值低于 50MB）；需要完整 COMMON 规则或经典
geodata 模板时用 `MIHOMO_TEMPLATE_SOURCE` 指定，见
[低内存客户端](docs/client-guide.md#低内存客户端旧款-iphone)。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `easy_all status` | 查看内核、服务、端口和订阅状态 |
| `easy_all show` | 显示当前模式的节点链接或客户端配置与 Mihomo 节点 |
| `easy_all subscription` | 显示每个用户的订阅地址或当前模式节点信息 |
| `easy_all self-update` | 从 `main` 更新项目代码，不修改应用配置 |
| `easy_all self-update --dev` | 从 `dev` 更新项目代码，用于验证待发布版本 |
| `easy_all apply` | 重新应用本机配置与订阅；Bunny 模式同时幂等同步云资源，组合模式不修改 DNS 与 Gcore 资源 |
| `easy_all reality-target [域名:端口]` | Reality 模式修改 SNI（伪装目标）并重新应用 |
| `easy_all renew-cert` | 轮换当前模式证书；Bunny 模式主动检查并续期 Let's Encrypt 证书；组合模式重签 Origin CA 与 Gcore 回源证书 |
| `easy_all update-core` | Reality/Cloudflare/Bunny/Gcore/组合 更新 Xray |
| `easy_all apply-cloud` | 同步云端资源：Cloudflare 的 Worker/DNS/规则；Bunny 幂等同步受管资源；组合模式写入 DNS、证书与 Gcore 资源 |
| `easy_all refresh-origin-ips` | Bunny 模式刷新官方回源 IPv4 防火墙池 |
| `easy_all purge-gcore [--domain <域名>…] [--all]` | 清理 easy_all 创建的 Gcore CDN 资源；可在未安装状态使用，不删除 DNS |
| `easy_all purge-cloudflare [--domain <域名>…] [--all]` | 清理 easy_all 创建的 Cloudflare 资源（Worker/DNS/规则/Origin CA）；不删除 Zone 与 Bunny 无注释记录 |
| `easy_all edit-sub` | 交互修改订阅设置（域名、模式、用户 Token 与配额） |
| `easy_all rotate-dynamic-ports` | Reality 模式刷新动态端口 NAT 规则 |
| `easy_all refresh-cdn-ips` | Cloudflare/Gcore/组合 模式重新筛选优选 IP |
| `easy_all uninstall` | 卸载本机资源 |
| `easy_all help` | 查看全部命令 |

系统默认使用 [Skyline Speeder](https://github.com/CYBERVERSE-Research/skyline-speeder) 加速。启用时要求当前已运行 Linux 6.12+，并具备内核 BTF 和 cgroup v2。

当前内核低于 6.12 时，安装器会自动安装兼容的 XanMod LTS 内核，暂不重启，先完成节点、订阅等其余安装，
期间暂用 BBR，状态显示 `Skyline Speeder: pending-reboot`。保存节点和订阅链接后，只需重启一次，
开机任务就会自动安装并启用 Skyline，无需再手动操作；安装期间显示 `pending-activation`。
状态会保留到后续 `apply` 和重启；Skyline 只加速这台 VPS 的发送方向，不影响独立 Worker 兜底节点。
开机安装需要联网；Debian 12 的旧 glibc 需要从源码编译 Rust/BPF，可能耗时较长，期间继续使用 BBR。
自动安装失败时 `status` 显示 `degraded`，可查看日志并修复后执行 `sudo easy_all apply` 重试。
以后更新项目代码并执行 `sudo easy_all apply`，会按项目固定的 Skyline 版本就地升级，无需卸载；
手工安装的更新版本也可能被降级到项目固定版本。
完整卸载随 `easy_all uninstall` 执行。

更新代码并应用配置：

```bash
sudo easy_all self-update
sudo easy_all apply
```

`self-update` 不会自动修改当前部署。Cloudflare 模式只有在需要同步云端 DNS、证书、规则或
Worker 时才使用 `sudo easy_all apply-cloud`。

已有 Cloudflare 部署要启用最新 Worker 聚合分组，执行：

```bash
sudo easy_all self-update
sudo easy_all apply-cloud
```

按提示输入 Cloudflare API Token，完成后在客户端刷新带 `flag=clash` 的 Mihomo 订阅。尚未
配置独立 Worker 兜底时，改用 `sudo easy_all edit-sub` 并在交互流程中启用。

全部命令、用户管理、配额、证书、状态文件和卸载规则见[运维指南](docs/operations-guide.md)。

## 安全边界

- Reality/Cloudflare/Gcore 成功安装或应用后，SSH 仅监听 TCP `65533`。先在云安全组放行 `65533`，以后使用 `ssh -p 65533 用户@服务器`；保留当前会话直到新连接验证成功。组合模式不改 SSH，保持安装前的监听端口。
- Bunny 保留现有 SSH 监听及检测到的全部 SSH 端口；探测失败或前置第三方阻断规则使放行无效时停止刷新并保留旧放行规则，不擅自删除第三方规则。
- UFW 默认拒绝其他入站流量；Reality/Cloudflare/Gcore 的 Fail2ban 保护 SSH `65533`；组合模式不配置 Fail2ban。[监听冲突和恢复规则](docs/technical-reference.md)见技术参考。
- Xray 阻断私网和云元数据地址，并让境外 QUIC 回退到 TCP。
- Cloudflare XHTTP 实时回源，不缓存隧道业务数据，也不承诺固定免费流量。
- 默认卸载只清理本机；`--purge-cloud` 仅删除所有权和值均匹配的 easy_all 云资源。

本项目不能承诺某条线路一定更快、更稳定或适合所有网络。请遵守所在地法律以及 VPS、
Cloudflare 和 Globalping 的服务条款。

## 文档

| 文档 | 内容 |
| --- | --- |
| [更新记录](CHANGELOG.md) | 版本标识与重要功能变化 |
| [前置准备手册](docs/preparation-guide.md) | 域名、Cloudflare、Token、gRPC 和 Globalping |
| [客户端使用指南](docs/client-guide.md) | Mihomo 客户端、导入、Clash Mi 和 DNS 排障 |
| [运维指南](docs/operations-guide.md) | 更新、用户、配额、Worker 聚合、证书、卸载和故障处理 |
| [技术参考](docs/technical-reference.md) | Reality、XHTTP、网络策略、BBRv3 和代码模块 |
| [Debian 初始化工具](docs/debian-init.md) | 独立的服务器初始化脚本 |

## 开发与测试

项目结构和运行原理见[技术参考](docs/technical-reference.md)。完整测试需要 Bash 4.1+ 和
GNU coreutils（`stat`、`date`），建议在 Linux 或容器环境中运行；入口会先检查这些要求：

```bash
npm test
```

macOS 默认 Bash 3.2 与 BSD 工具不满足完整测试要求，可单独运行 `npm run test:worker`。
Worker 测试需要 Node.js 18+ 和 Bash；未配置 Mihomo 内核时会明确跳过真实内核检查。
