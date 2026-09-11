# easy_all

`easy_all` 是面向全新 Debian 12/13 amd64 VPS 的单节点交互安装器。它统一配置 Xray、Nginx、
订阅、UFW、Fail2ban 和 XanMod BBRv3。

只支持 IPv4。同一台 VPS 只能安装一种模式，并应作为不承载其他业务的专用服务器。

## 选择模式

| 模式 | 适用情况 | 协议与入口 |
| --- | --- | --- |
| **1. 直连 Reality** | VPS 公网 IP 可用且直连质量良好 | VLESS TCP Reality Vision，VPS `443` |
| **2. Cloudflare CDN** | 直连效果不佳、VPS 公网 IP 已被封，或明确需要纯 XHTTP | VLESS XHTTP `stream-up`，6 个 Cloudflare 精选 IPv4 |

Cloudflare 模式完全没有域名兜底，需要额外准备：

- 同一 Cloudflare Active Zone 下互不相同的节点域名和订阅域名；
- 具备 Zone 权限和账户级 Workers Scripts Write 权限的 API Token；
- Globalping Token；
- 在 Cloudflare 控制台手动开启 gRPC。

完整步骤见[前置准备手册](docs/preparation-guide.md)。Reality 只有在选择自托管订阅时才需要
Cloudflare 域名和 API Token。

## 安装要求

- Debian 12 或 13；
- amd64/x86_64/x64；
- 公网 IPv4；
- systemd 环境，不能是 Docker、LXC 等容器；
- 当前 SSH 登录方式和服务商 Console/VNC 均可用；
- 没有其他 Xray、Nginx 或代理面板占用端口。

安装会修改内核、SSH、UFW、Fail2ban、时区和 systemd 任务。建议先创建 VPS 快照，并保留当前
SSH 会话，直到重启后确认新会话可以登录。服务商的安全组或云防火墙还需自行放行当前 SSH 端口
以及业务所需的 TCP `443`。

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
| 安装模式 | 直连良好选 `1`；IP 被封、直连不佳或需要纯 XHTTP 选 `2` |
| 订阅输出 | 选 `1` 或直接回车，在本机部署订阅 |
| 月度用户配额 | 选 `1` 或直接回车，不启用 |
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

`status` 显示 `BBRv3: active` 才表示新内核已经生效。复制 `subscription` 输出中带
`flag=clash` 的 Mihomo 地址，在客户端通过 URL 导入。订阅地址与 UUID 都是访问凭据，不要公开。

客户端选择、Clash Mi 设置和订阅 DNS 排障见[客户端使用指南](docs/client-guide.md)。

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `easy_all status` | 查看内核、服务、端口和订阅状态 |
| `easy_all show` | 显示 VLESS 链接和 Mihomo 节点 |
| `easy_all subscription` | 显示每个用户的订阅地址 |
| `easy_all self-update` | 从 `main` 更新项目代码，不修改应用配置 |
| `easy_all self-update --dev` | 从 `dev` 更新项目代码，用于验证待发布版本 |
| `easy_all apply` | 重新应用当前配置 |
| `easy_all update-sub` | 管理订阅、用户和配额 |
| `easy_all update-core` | 更新 Xray 核心 |
| `easy_all refresh-cdn-ips` | Cloudflare 模式重新筛选优选 IP |
| `easy_all uninstall` | 卸载本机资源 |
| `easy_all help` | 查看全部命令 |

更新代码并应用配置：

```bash
sudo easy_all self-update
sudo easy_all apply
```

`self-update` 不会自动修改当前部署。Cloudflare 模式只有在需要同步云端 DNS、证书、规则或
Worker 时才使用 `sudo easy_all apply-cloud`。

全部命令、用户管理、配额、证书、状态文件和卸载规则见[运维指南](docs/operations-guide.md)。

## 安全边界

- 两种模式都会保留已检测到的 SSH 端口，并额外监听 TCP `65533`。
- UFW 默认拒绝其他入站和转发流量；Fail2ban 保护实际 SSH 端口。
- Xray 阻断私网和云元数据地址，并让境外 QUIC 回退到 TCP。
- Cloudflare XHTTP 实时回源，不缓存隧道业务数据，也不承诺固定免费流量。
- 默认卸载只清理本机；`--purge-cloud` 仅删除所有权和值均匹配的 easy_all 云资源。

本项目不能承诺某条线路一定更快、更稳定或适合所有网络。请遵守所在地法律以及 VPS、
Cloudflare 和 Globalping 的服务条款。

## 文档

| 文档 | 内容 |
| --- | --- |
| [前置准备手册](docs/preparation-guide.md) | 域名、Cloudflare、Token、gRPC 和 Globalping |
| [客户端使用指南](docs/client-guide.md) | Mihomo 客户端、导入、Clash Mi 和 DNS 排障 |
| [运维指南](docs/operations-guide.md) | 更新、用户、配额、Worker 聚合、证书、卸载和故障处理 |
| [技术参考](docs/technical-reference.md) | Reality、XHTTP、网络策略、BBRv3 和代码模块 |
| [Debian 初始化工具](docs/debian-init.md) | 独立的服务器初始化脚本 |

## 开发与测试

项目结构和运行原理见[技术参考](docs/technical-reference.md)。运行完整测试：

```bash
npm test
```
