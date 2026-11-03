# easy_all

当前源码版本：[2.4.8](CHANGELOG.md#248-更新说明2026-11-03)。

`easy_all` 是面向全新 Debian 12/13 VPS 的单节点安装器（所有模式支持 amd64，Bunny 另支持 arm64）。它统一配置 Xray、Nginx、
订阅、UFW、Fail2ban 和 TCP 加速（默认安装并启用 Skyline Speeder）。

安装参数由一份 JSON 字典一次性提供（见 [安装参数](#安装参数)），安装过程中不再提问。

只支持 IPv4。同一台 VPS 只能安装一种模式，并应作为不承载其他业务的专用服务器。

## 开始前：先配置 SSH 保活

安装会连续跑十几分钟 `apt`、内核与 TCP 加速，SSH 空闲断开会直接中断安装，甚至把机器留在半配置状态。

```bash
# 本机 ~/.ssh/config（写一次，对所有 VPS 生效）
Host *
    ServerAliveInterval 30
    ServerAliveCountMax 6
    TCPKeepAlive yes
```

临时用法：`ssh -o ServerAliveInterval=30 -o ServerAliveCountMax=6 <用户>@<IP> -p <端口>`。
服务器侧也可以加 `/etc/ssh/sshd_config`：`ClientAliveInterval 60`、`ClientAliveCountMax 3`，
再 `systemctl reload ssh`。

仍然建议在 `tmux` 里执行；万一断开，重连后先 `sudo easy_all cleanup-partial`，再按原参数重跑。

这组参数**不限制会话总时长**：每 30 秒的探测只要被 sshd 应答就会一直续下去，等 Gcore 激活那 30 分钟
不会因为“空闲”被断。`ServerAliveCountMax 6` 只是“连续 6 次收不到应答（约 3 分钟）才断开”的故障容忍；
路径真断（切网、VPN 掉线、休眠）超过这个窗口仍会断，所以还是建议 `tmux`。

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

Gcore 模式面向非优化线路，采用 Xray 服务端，结合 Nginx mTLS 客户端证书鉴权回源；通过中国大陆三网、中国香港、中国台北、日本、新加坡、美国西海岸及多公共解析器的 Globalping 视角解析账户 CDN 域名，跨小时保留 7 天内发现的真实入口，再经本机 SNI/WebSocket 和三网定向测速筛选，下发 1～6 个实际有效节点，通常为 2 个，节点连续命名为 `🇺🇸优选1`～`🇺🇸优选n`；订阅为一条链接，按客户端 User-Agent 自动下发 Mihomo YAML 或 Base64（`flag=` 可强制），内置单一 AUTO 自动测速组。需要准备：
- 委派至 Gcore Managed DNS 的域名 Zone；
- 具备 CDN 与 DNS 权限的 Gcore API Token；
- Globalping Token。
以上是模式 4 的要求；组合模式（`mode: combined`）的 Gcore 入口是一个域名节点，不需要委派 Gcore Managed DNS，
也不需要 Cloudflare gRPC，准备要求见下方组合模式段落。
组合模式（`mode: combined`）使用一个 Cloudflare Zone 下的六个子域名：直连域名（灰云 A）、
Cloudflare 节点与回源域名（橙云 A）、Gcore 节点（灰云 CNAME 到账户 `*.gcdn.co`）与回源域名
（灰云 A）、订阅域名（橙云 A）。安装时需要 Cloudflare DNS Token、Gcore CDN Token 与
Globalping Token；`443` 只对 Cloudflare 与 Gcore 官方回源网段开放，直连走 `8443`，
SSH 保持现状不改。不启用用户配额，订阅只有一个 owner Token。

前置准备详见 [前置准备手册](docs/preparation-guide.md)。

直连 Reality 用 `SUBSCRIPTION_MODE` 选择订阅输出，默认 `link`（不部署订阅）：

| `SUBSCRIPTION_MODE` | 适用情况 | 需要准备 |
| --- | --- | --- |
| **`link`（默认）** | 只需要节点链接，自己维护订阅 | 无 |
| **`deploy`** | 只有当前这一台直连节点 | `SUBSCRIPTION_DOMAIN`、`CLOUDFLARE_API_TOKEN` |
| **`worker`** | 多台直连 Reality 节点统一下发，仍希望走 Workers | 同 Zone 两个一级域名（`SUBSCRIPTION_DOMAIN` + `SUB_SOURCE_DOMAIN`）、具备 Workers Scripts Write 的 API Token |

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
组合模式（`mode: combined`）不改 SSH，也不配置 Fail2ban。Bunny 保留当前 SSH 监听；ARM64 使用原有内核，
暂不支持 Skyline Speeder。
建议先创建 VPS 快照，并保留当前
SSH 会话，直到重启后确认新会话可以登录。服务商的安全组或云防火墙还需自行放行当前 SSH 端口
以及业务所需的 TCP `443`；组合模式还需放行 TCP `8443`（直连 Reality）。Reality 使用动态端口时，
还需放行 TCP `10000-62703`；VPS 安装和
`apply` 会立即加载整段 NAT，重启后由 UFW 持久化规则和 `@reboot` 刷新任务恢复。

## 快速安装

```bash
ssh <登录用户>@<VPS公网IP> -p <SSH端口>

# 1. 把下面「安装参数」里的完整示例复制到本机编辑器，改域名与 <...>
# 2. 粘贴到 VPS 上（heredoc 原样写入），然后校验、安装
cat > params.json <<'JSON'
{ ...粘贴改好的示例... }
JSON
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) params.json --check-params
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) params.json
```

- bootstrap 会克隆代码并把参数原样转给 `easy_all`；请原样执行，不要写成 `curl ... | sudo bash`。
- 组合模式只改 `CF_ZONE` 与三个 Token，其余字段留空即用默认值。**安装成功会自动删除参数文件**；
  中途失败会保留，排查后请自行删除。
- 安装约十几分钟（`apt`、内核、TCP 加速），建议在 `tmux` 里执行；中断后先 `sudo easy_all cleanup-partial`
  再重试（命令未注册时用 `... bootstrap.sh cleanup-partial`）。

## 安装参数

安装只有一条路径：参数来自一份 JSON，安装前一次性校验，安装期不提问。

```bash
sudo easy_all params.json                          # 安装（最简形式，文件名任意 .json）
sudo easy_all params.json --check-params           # 只校验，不改本机
```

`install params.json`、`install --params params.json` 与 `params.json` 等价；从标准输入读取用
`sudo easy_all - --mode combined < params.json`。`""`、`null` 或缺省表示未提供，必填项缺省会报错。

组合模式完整示例（复制后改域名与 `<...>` 即可粘贴；`""` 表示留空自动生成/探测）：

```json
{
  "schema_version": 1,
  "mode": "combined",
  "params": {
    "CF_ZONE": "example.com",
    "DIRECT_DOMAIN": "node.example.com",
    "CF_NODE_DOMAIN": "cf.example.com",
    "CF_ORIGIN_DOMAIN": "cf-origin.example.com",
    "GCORE_NODE_DOMAIN": "gcore.example.com",
    "GCORE_ORIGIN_DOMAIN": "gcore-origin.example.com",
    "SUBSCRIPTION_DOMAIN": "sub.example.com",
    "CLOUDFLARE_API_TOKEN": "<Cloudflare API Token>",
    "GCORE_API_TOKEN": "<Gcore API Token>",
    "GLOBALPING_TOKEN": "<Globalping Token>",
    "REALITY_TARGET": "swdist.apple.com:443",
    "XHTTP_PATH": "",
    "WEBSOCKET_PATH": "",
    "DIRECT_NODE_NAME": "🇺🇸直连",
    "CF_NODE_PREFIX": "🇺🇸CF",
    "GCORE_NODE_NAME": "🇺🇸GCore",
    "SUB_DOWNLOAD_NAME": "EASY_ALL",
    "VLESS_UUID": "",
    "ALLOWED_TOKENS": {
      "owner": "<订阅 Token（8-128 位 URL 安全字符）>"
    },
    "VPS_PUBLIC_IPV4": "",
    "TCP_ACCELERATION": "skyline",
    "REBOOT_SCHEDULE_MODE": "1",
    "REBOOT_HOUR": ""
  }
}
```

其余四个模式（Reality 的 deploy/worker、Cloudflare、Gcore、Bunny）见
[docs/params-examples.md](docs/params-examples.md)。

模式写成 `reality` / `cloudflare-streamup` / `bunny-ws` / `gcore` / `combined`（或 `1`~`5`）。

### 参数字段

表里 `R`=reality，`CF`=cloudflare-streamup，`GC`=gcore，`B`=bunny-ws，`组合`=combined。
“必填”指缺省直接报错；“否”表示有默认值或会自动生成/探测。

#### 通用

| 字段 | 模式 | 必填 | 默认 / 留空 | 说明 |
| --- | --- | --- | --- | --- |
| `VLESS_UUID` | 全部 | 否 | 自动生成 | 节点 UUID；手填会校验格式 |
| `VPS_PUBLIC_IPV4` | 全部 | 否 | 安装阶段自动探测 | 写 DNS A 记录用的公网 IPv4；NAT 或多 IP 场景建议手填 |
| `TCP_ACCELERATION` | 全部 | 否 | `skyline` | `skyline` 或 `bbrv3`（Bunny 仅 amd64 生效） |
| `REBOOT_SCHEDULE_MODE` | 全部 | 否 | `1` | `1` 每天 04:00，`2` 自定义小时，`3` 不配置 |
| `REBOOT_HOUR` | 全部 | 否 | 空 | 仅 `REBOOT_SCHEDULE_MODE: "2"` 时必填，`0`~`23` |
| `SUB_DOWNLOAD_NAME` | R/CF/GC/组合 | 否 | `EASY_ALL` | 订阅下载文件名（不含 `.yaml`）；Bunny 固定 `EASY_ALL` |

#### Token

| 字段 | 模式 | 必填 | 默认 / 留空 | 说明 |
| --- | --- | --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | R/CF/组合 | 是 | — | DNS 与 Origin CA 权限；R 仅 `deploy`/`worker` 需要，CF 必填 |
| `GCORE_API_TOKEN` | GC/组合 | 是 | — | Gcore CDN（GC 另需 Managed DNS）权限 |
| `GLOBALPING_TOKEN` | CF/GC/组合 | 是 | — | 优选 IP 探测；安装后保存到 root-only 凭据文件 |
| `BUNNY_API_KEY` | B | 是 | — | Bunny Account API Key |
| `CLOUDFLARE_DNS_TOKEN` | B | 是 | — | Bunny 模式写 Cloudflare DNS 的 Token |
| `ALLOWED_TOKENS` | R/CF/GC/组合 | 条件 | — | 订阅用户字典 `{"用户":"token"}`；未启用配额且非 `link` 时必填，组合模式可省略（自动生成 owner） |
| `OWNER_TOKEN` | 组合/B | 否 | 自动生成 | 单用户 Token；与 `ALLOWED_TOKENS` 二选一，B 固定单用户 |

#### 订阅

| 字段 | 模式 | 必填 | 默认 / 留空 | 说明 |
| --- | --- | --- | --- | --- |
| `SUBSCRIPTION_MODE` | R/CF/GC | 否 | `deploy` | R：`link`/`deploy`/`worker`；CF：`link`/`deploy`；GC：`link`/`deploy` |
| `SUBSCRIPTION_DOMAIN` | R/CF/GC/组合 | R·GC 是 / CF·组合 否 | CF：`sub.<节点域名的父域>`；组合：`sub.<CF_ZONE>` | R/GC 在非 `link` 时必须手填 |
| `SUB_SOURCE_DOMAIN` | R | 条件 | — | `worker` 时必填：Worker 回源用的私有节点源域名 |
| `CLOUDFLARE_WORKER_NAME` | R/CF | 否 | `easyall-reality` / `easyall` | Worker 名称；下单 Worker 订阅时使用 |
| `WORKER_SOURCE_SECRET` | R/CF | 否 | 自动生成 | Nginx 与 Worker 之间的回源密钥 |
| `WORKER_AGGREGATION_CONFIG` | R/CF | 否 | `{}` | 其他节点的聚合 JSON（不得含 `vpsSubUrl`）；`allowedTokens` 会覆盖用户 Token |
| `ENABLE_MONTHLY_QUOTA` | R/CF/GC | 否 | `0` | `1` 启用按用户月度配额 |
| `MONTHLY_QUOTAS_GB` | R/CF/GC | 否 | `{"owner":0}` | 仅启用配额时：`{"用户":GB}`，`0` 不限量 |
| `QUOTA_TOKEN_OVERRIDES` | R/CF/GC | 否 | `{}` | 仅启用配额时：覆盖指定用户的 Token |
| `QUOTA_START_DATE` | R/CF/GC | 否 | 今天 | 仅启用配额时：账期起点 `YYYY-MM-DD` |

#### 域名

| 字段 | 模式 | 必填 | 默认 / 留空 | 说明 |
| --- | --- | --- | --- | --- |
| `CF_ZONE` | 组合 | 是 | — | Cloudflare 根 Zone，其余五个域名默认由它派生 |
| `CLOUDFLARE_ZONE` | B | 是 | — | Cloudflare 根 Zone，两个域名默认由它派生 |
| `DIRECT_DOMAIN` | 组合 | 否 | `node.<CF_ZONE>` | 直连节点域名（灰云 A） |
| `CF_NODE_DOMAIN` | 组合 | 否 | `cf.<CF_ZONE>` | Cloudflare 节点域名（橙云） |
| `CF_ORIGIN_DOMAIN` | 组合 | 否 | `cf-origin.<CF_ZONE>` | Cloudflare 回源域名（橙云） |
| `GCORE_NODE_DOMAIN` | 组合 | 否 | `gcore.<CF_ZONE>` | Gcore 节点域名（灰云 CNAME） |
| `GCORE_ORIGIN_DOMAIN` | GC/组合 | GC 是 / 组合 否 | 组合：`gcore-origin.<CF_ZONE>` | Gcore 侧回源解析的源站域名；GC 模式必须手填 |
| `VLESS_CDN_DOMAIN` | CF/GC | 是 | — | 客户端连接的 CDN 节点域名（Zone 下一级子域名） |
| `ORIGIN_DOMAIN` | B | 否 | `origin.<CLOUDFLARE_ZONE>` | Bunny 源站域名（DNS only A） |
| `CDN_DOMAIN` | B | 否 | `cdn.<CLOUDFLARE_ZONE>` | Bunny 节点/订阅域名（DNS only CNAME） |
| `WORKER_BACKUP_DOMAIN` | CF | 否 | 空 = 不部署 | 独立 Worker 兜底节点域名，需在节点所属 Zone 下 |
| `WORKER_BACKUP_PLACEMENT` | CF | 否 | `off` | 兜底 Worker Placement：`off` 或 `aws:ap-east-1` |

#### 节点名与路径

| 字段 | 模式 | 必填 | 默认 / 留空 | 说明 |
| --- | --- | --- | --- | --- |
| `NODE_NAME` | R | 否 | `MY_REALITY` | 客户端展示名 |
| `XHTTP_NODE_NAME` | CF/GC | 否 | `VLESS_XHTTP_H2` | 客户端展示名 |
| `DIRECT_NODE_NAME` | 组合 | 否 | `🇺🇸直连` | 直连节点名 |
| `CF_NODE_PREFIX` | 组合 | 否 | `🇺🇸CF` | Cloudflare 节点名前缀，实际下发 `🇺🇸CF1`~`🇺🇸CF6` |
| `GCORE_NODE_NAME` | 组合 | 否 | `🇺🇸GCore` | Gcore 节点名 |
| `NODE_HOST` | R | 否 | 安装阶段自动探测 | 客户端连接的 IPv4 或灰云域名 |
| `REALITY_TARGET` | R/组合 | 否 | `swdist.apple.com:443` | Reality SNI / 伪装目标（域名:端口） |
| `SUB_PORT_MODE` | R | 否 | `dynamic` | 订阅端口模式：`443` 或 `dynamic` |
| `XHTTP_PATH` | CF/组合 | 否 | 自动生成 | XHTTP 路径，默认 `/xhttp-<随机>` |
| `WEBSOCKET_PATH` | GC/B/组合 | 否 | 自动生成 | WebSocket 路径，默认 `/ws-<随机>` |
| `XRAY_XHTTP_LOOPBACK_PORT` | CF | 否 | `10086` | 本机回环端口 |
| `XRAY_WEBSOCKET_LOOPBACK_PORT` | GC | 否 | `10087` | 本机回环端口 |
| `ORIGIN_HEADER_SECRET` | CF/B | 否 | 自动生成 | 回源校验密钥 |

#### Bunny 专属

| 字段 | 模式 | 必填 | 默认 / 留空 | 说明 |
| --- | --- | --- | --- | --- |
| `BUNNY_PULL_NAME` | B | 否 | 自动生成 | Pull Zone 名称（小写字母、数字、短横线，5~50 位） |
| `BUNNY_BANDWIDTH_GB` | B | 否 | `500` | Pull Zone 月流量限制（GB，`0` 不限） |

### 安装失败时

退出前打印失败阶段、`文件:行`、失败命令、退出码与错误信息（如
`失败阶段：services（服务、证书与防火墙）`）。写入安装进度标记后失败会询问：
`是否清理本次安装的本机残留（已拍快照时回滚到安装前状态）？[Y/n]`——回车/`y` 清理并回滚（默认），
`n` 保留现场并按提示执行 `sudo easy_all cleanup-partial`；无终端时自动清理。参数文件会保留，
排查后自行删除。

## 完成安装

安装末尾会打印重启提示（不再询问是否立即重启）。需要重启时手动执行：

```bash
sudo reboot
```

重新登录后验证：

```bash
sudo easy_all status
sudo easy_all subscription
```

系统状态显示 `Skyline Speeder: active` 即表示已生效（内核未达到 6.12 时安装器会自动安装 6.12+ 内核并在重启后自动激活）。复制 `subscription`
输出的订阅地址，在客户端通过 URL 导入：同一个地址会按客户端自动下发 Mihomo YAML 或 Base64，无需挑选或手工加
`flag=clash`。订阅地址与 UUID 都是访问凭据，不要公开。

客户端选择、Clash Mi 设置和订阅 DNS 排障见[客户端使用指南](docs/client-guide.md)。
默认订阅模板是 COMMON 精简规则（以低内存为目标，不保证 iPhone 峰值低于 50MB）；需要完整 COMMON 规则或经典
模板（2.3.1 起改用 MRS 规则集，不再加载 geodata）时用 `MIHOMO_TEMPLATE_SOURCE` 指定，见
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
Worker 时才使用 `sudo easy_all apply-cloud`；组合模式升级到本版本后必须执行一次
`sudo easy_all apply-cloud`（重签含节点域名的 Origin CA 证书），只跑 `apply` 不会重签证书，
`status` 会显示证书未覆盖节点域名。组合模式的 `edit-sub`、`apply-cloud` 与 `renew-cert` 在可捕获终止（`die`、`SIGINT`、`SIGTERM`、`SIGHUP`）时会回滚本机配置、证书与状态；`SIGKILL`/OOM 不会回滚，可能留下“运行中鉴权/证书比状态文件新”的偏差。中断后请执行 `sudo easy_all status` 查看是否提示不一致：Token 偏差按提示执行 `sudo easy_all apply`，证书轮换后偏差执行 `sudo easy_all apply-cloud` 复核。

已有 Cloudflare 部署要启用最新 Worker 聚合分组，执行：

```bash
sudo easy_all self-update
sudo easy_all apply-cloud
```

该命令会按提示输入 Cloudflare API Token，完成后在客户端刷新该订阅（同一链接会按客户端自动下发 YAML）。
独立 Worker 兜底可在安装参数里用 `WORKER_BACKUP_DOMAIN` 指定，或之后用 `sudo easy_all edit-sub` 启用。

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
