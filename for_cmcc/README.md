# easy_cmcc

`easy_cmcc` 是面向中国移动网络的独立安装器，固定同时部署以下两个 Cloudflare CDN 节点：

- VLESS + WebSocket + TLS
- VLESS + XHTTP (`stream-one`) + TLS + HTTP/2

不再提供 Trojan、Reality、AnyTLS 或协议切换。两个节点共用一个 CDN 域名、TLS 证书和 VLESS UUID，但使用独立的随机路径和 Xray 本机端口。已有 v2 的 Trojan WebSocket 状态会在 `update` 时自动迁移：原路径的随机后缀会保留，但 `/trojan-` 前缀改为 `/xhttp-`；原本机端口用于新的 XHTTP 入站，认证改用现有 VLESS UUID。已经生成过 v3、但路径仍带旧前缀的状态也会在更新时自动修正。

```text
Mihomo / FLClash -> Cloudflare CDN :443 -> Nginx :443
                                               |-> VLESS WS  -> Xray 127.0.0.1:10085
                                               `-> VLESS XHTTP/H2 -> Xray 127.0.0.1:10086
```

## 省电与性能取舍

生成的 Mihomo 配置有一个 `AUTO` 自动测速组和一个 `PROXY` 选择组。`AUTO` 使用 `https://www.gstatic.com/generate_204`、`interval: 300` 与 `lazy: true`；`PROXY` 将 `AUTO` 置于首位，并保留两个节点供手动选择。

> **仅建议在电脑端使用。** 此配置启用 TUN，并包含 `AUTO` 的节点测速；手机端会因此产生持续的后台网络活动、CPU 唤醒和额外耗电。手机上如必须使用，应关闭 TUN 并在 `PROXY` 中手动选择节点，但这不属于本方案的推荐使用方式。

客户端固定使用：

- `tcp-concurrent: false`
- `find-process-mode: off`
- `sniffer.enable: false`
- `log-level: error`
- WebSocket：`max-early-data: 2560`、`early-data-header-name: Sec-WebSocket-Protocol`、`ip-version: ipv4`、`smux.enabled: false`、`alpn: [http/1.1]`
- XHTTP：`mode: stream-one`、`alpn: [h2]`，不配置 `extra` 或 XMUX

WebSocket 入站设置 `heartbeatPeriod: 0`。Early Data 是客户端功能：通用订阅在 WS 路径追加 `?ed=2560`，Mihomo 订阅下发对应的 `max-early-data` 和 `Sec-WebSocket-Protocol` 请求头，服务端和 Nginx 仍匹配不带查询参数的原始路径。XHTTP 使用精简的 `stream-one` 双向流，不下发 `extra`、XMUX 或连接复用参数；Nginx 仍通过 `grpc_pass` 回源，以匹配 HTTP/2 传输。系统侧启用 BBR、`fq`、MTU 探测和长连接拥塞窗口保持。这组配置减少额外复用层与连接调度，适用于上海移动经 Cloudflare 边缘回源 RackNerd DC2 的场景。

## 准备清单

一套部署使用两个不同域名：

| 域名 | 用途 | 安装前 | 安装后 |
|---|---|---|---|
| `node.example.com` | WS 与 XHTTP 节点入口 | A 指向 VPS，保持 DNS only / 灰云 | 本机验收后切为 Proxied / 橙云 |
| `sub.example.com` | Worker 订阅入口 | 使用没有现有记录的新主机名 | 自动部署时由 Worker Custom Domain 创建 |

还需要：

- Debian 12/13 amd64 独立 VPS，root、systemd，TCP 80/443 未占用。
- VPS 公网 IPv4；只有确认 VPS IPv6 可用时才添加 AAAA。
- 已接入 Cloudflare 的 Active Zone。
- Cloudflare DNS API Token；自动部署 Worker 时还需要 Account ID 和 Worker API Token。
- 支持 VLESS XHTTP 的近期 Mihomo 客户端。

脚本会升级系统包、安装 XanMod LTS、启用 BBR、管理 root 定时重启任务，并接管 `/etc/nftables.conf`。它适合专用 VPS，不应与根目录 `easy_all` 在同一台机器同时安装。

## 快速安装

先把节点域名切为灰云并指向 VPS，然后执行：

```bash
wget -qO /root/easy_cmcc.new \
  "https://raw.githubusercontent.com/v2yiz/easy_all/main/for_cmcc/easy_cmcc" \
  && chmod 700 /root/easy_cmcc.new \
  && mv -f /root/easy_cmcc.new /root/easy_cmcc \
  && /root/easy_cmcc install
```

协议固定为 VLESS WS + VLESS XHTTP/H2，不再询问协议。为兼顾自动执行与用户自选，交互安装仍保留以下菜单与输入：

| 交互项 | 推荐选择 |
|---|---|
| 定时重启 | `1`，每天凌晨 4 点 |
| Cloudflare CDN 域名 | `node.example.com` |
| Cloudflare DNS API Token | 输入 Zone Token，输入不回显 |
| 安装后 DNS 代理 | `1`，本机验收后自动把节点 A/AAAA 切为橙云 |
| 订阅输出方式 | `1`，自动部署 Worker |
| 订阅用户 Token 字典 | 使用自动生成值或自己的 JSON |
| Worker 名称 | 默认 `easy-cmcc` |
| Worker Custom Domain | `sub.example.com`，不得与节点域名相同 |
| Mihomo 下载文件名 | 默认 `EASY_CMCC`，不含 `.yaml` |
| Account ID / Worker Token | 自动部署时填写 |

可以通过环境变量减少交互，例如 `VLESS_CDN_DOMAIN`、`VLESS_WS_PATH`、`XHTTP_PATH`、`VLESS_UUID`、`CF_DNS_API_TOKEN`、`CF_PROXY_MODE=auto|manual`、`ALLOWED_TOKENS`、`CF_ACCOUNT_ID` 和 `CF_WORKER_API_TOKEN`。未指定的路径和 UUID 会自动随机生成。

安装完成并通过本机验收后：

1. 默认情况下脚本已把节点域名的 A、AAAA 一起切为橙云；若选择手动模式，请自行切换。
2. Cloudflare SSL/TLS 使用 Full (Strict)。
3. 确认 Network → WebSockets、HTTP/2、gRPC 均已开启；具备 Zone Settings 编辑权限时脚本会自动开启。
4. 执行 `easy_cmcc status` 和 `easy_cmcc subscription`。
5. 将 Clash Meta 订阅导入 FLClash、Clash Verge 或其他 Mihomo 客户端，在 `PROXY` 中手动选择节点。

## 常用命令

```bash
easy_cmcc help
easy_cmcc show
easy_cmcc subscription
easy_cmcc status
easy_cmcc update
easy_cmcc update-sub
easy_cmcc update-core
easy_cmcc renew-cert
easy_cmcc register-command
easy_cmcc uninstall
```

- `show`：同时显示两个节点链接和 Mihomo 节点片段。
- `subscription`：显示两个节点与 Worker 订阅地址。
- `status`：显示域名、WebSocket/XHTTP 路径、Xray/Nginx 和 TCP 443 状态。
- `update`：重新应用省电参数并刷新 Xray、Nginx 和 Worker。
- `update-sub`：重新选择订阅部署方式并刷新订阅。
- `update-core`：更新 Xray，验收失败时恢复旧版本。
- `renew-cert`：强制续期证书并重载 Nginx。
- `uninstall`：删除本机服务、状态、证书、命令和备份，不删除远端 Worker。

`switch` 不可用。状态格式已经升级为 v3；当前脚本会把本项目的 v2（VLESS WS + Trojan WS）状态迁移为 v3。其他旧协议安装不做兼容迁移。

从 v2 升级时，建议给这一次更新传入 Zone Token，让脚本同时打开 Cloudflare gRPC 与 HTTP/2：

```bash
CF_DNS_API_TOKEN='你的 Zone Token' easy_cmcc update
```

如果不传 Token，服务端与订阅仍会完成迁移，但必须先在 Cloudflare 控制台手动打开这两个 Network 开关，否则 XHTTP 会返回 403 或表现为超时。

## Cloudflare 权限

节点 Zone 的 `CF_DNS_API_TOKEN` 建议只授予：

- Zone → DNS → Edit：acme.sh DNS-01 和自动切换橙云。
- Zone → Zone → Read：查询 Zone ID。
- Zone → Zone Settings → Edit：自动开启 WebSockets、HTTP/2 和 gRPC。

自动部署 Worker 还需要：

- `CF_ACCOUNT_ID`：Cloudflare Account ID，不是 Zone ID。
- `CF_WORKER_API_TOKEN`：限制到目标 Account，只授予 Workers Scripts → Edit。

DNS Token 和 Worker Token 都不会写入 `/etc/easy_cmcc/state.env`。acme.sh 为自动续期可能在权限受限的 `/root/.acme-cmcc.sh/` 保存 DNS 凭据。

## Worker 与订阅

`update-sub` 提供三种选择：

1. 自动部署 Worker，并可绑定 Custom Domain。
2. 输出完整 Worker 源码供手动部署。
3. 只显示节点链接，不生成 Worker，也不询问 Token。

通用订阅和 Clash Meta 订阅都会同时输出 `VLESS_WS` 和 `VLESS_XHTTP_H2`。二者同时进入 `AUTO` 和 `PROXY`：默认 `PROXY → AUTO` 自动选择，也可在客户端菜单中改为任一节点。

局域网 IPv4/IPv6 地址绕过 TUN；紧随其后的规则拒绝所有公网 UDP/443，让应用快速回退到 TCP，避免在 WebSocket/H2 的 TCP 链路外再叠加 QUIC。国内常用服务直连，其余规则进入 `PROXY`。下发的 TUN 使用 `stack: system`、`auto-route: true`、`auto-detect-interface: true`、`strict-route: false` 和 `mtu: 1500`。国内 DNS 使用阿里与腾讯两家独立 DoH（`dns.alidns.com`、`doh.pub`），阿里/腾讯的 IPv4 公共 DNS 仅用于引导解析；已确认的境外域名则经 `PROXY` 使用境外 DoH。WS 节点固定使用 `ip-version: ipv4`，XHTTP 节点保留 `ip-version: dual`；顶层 `ipv6: true`，但应用 DNS 保持 `ipv6: false`。

## 故障排查

- 两个节点都连接失败：确认节点域名已经橙云、SSL/TLS 为 Full (Strict)、证书域名与 SNI 一致。
- XHTTP 返回 403 或超时：确认 Cloudflare Network 的 HTTP/2 和 gRPC 已开启，客户端版本支持 XHTTP，订阅中的 `mode` 为 `stream-one` 且 `alpn` 只有 `h2`。
- 只有一个节点失败：核对该节点订阅路径与 `VLESS_WS_PATH` 或 `XHTTP_PATH` 是否一致，确认客户端没有合并旧配置。
- Android 仍耗电：确认 `AUTO` 的周期测速是否符合预期；WebSocket 的 smux 已关闭，XHTTP 未启用 XMUX，且不存在 provider 健康检查。
- YouTube 慢：确认最终配置保留 UDP/443 拒绝规则，使浏览器回退到 TCP；同时测试不同 Cloudflare 边缘与 VPS 回源线路。
- Worker 自动部署失败：查看 `/etc/easy_cmcc/last-worker-deploy.log`，或执行 `easy_cmcc update-sub` 改用手动输出。

## 测试

```bash
cd for_cmcc
npm test
```

若要用真实 Mihomo 校验生成的 YAML：

```bash
MIHOMO_BIN=/path/to/mihomo REQUIRE_MIHOMO_TESTS=1 npm test
```
