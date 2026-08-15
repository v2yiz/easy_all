# easy_cmcc

`easy_cmcc` 是面向中国移动网络的独立安装器，固定同时部署三个节点：

- VLESS + WebSocket + TLS
- Trojan + WebSocket + TLS
- Mieru + TCP（默认直连 VPS `8443`）

不再提供 gRPC、Reality、AnyTLS、XHTTP 或协议切换。两个 WebSocket 节点共用一个 CDN 域名和 TLS 证书，但使用独立的随机路径、认证信息和 Xray 本机端口；Mieru 由独立的 `mita` 服务提供，使用 VPS 公网 IPv4 或独立灰云域名直连，不经过 Nginx 或 Cloudflare CDN。已有双 WebSocket v2 状态执行 `easy_cmcc update` 或 `update-sub` 时会自动补齐 Mieru。

```text
Mihomo / FLClash -> Cloudflare CDN :443 -> Nginx :443
                                               |-> VLESS WS  -> Xray 127.0.0.1:10085
                                               `-> Trojan WS -> Xray 127.0.0.1:10086
Mihomo / FLClash ----------------> VPS :8443  -> mita (Mieru TCP)
```

## 省电与性能取舍

生成的 Mihomo 配置有一个 `AUTO` 自动测速组和一个 `PROXY` 选择组。`AUTO` 使用 `https://www.gstatic.com/generate_204`、`interval: 300` 与 `lazy: true`；`PROXY` 将 `AUTO` 置于首位，并保留三个节点供手动选择。

> **仅建议在电脑端使用。** 此配置启用 TUN，并包含 `AUTO` 的节点测速；手机端会因此产生持续的后台网络活动、CPU 唤醒和额外耗电。手机上如必须使用，应关闭 TUN 并在 `PROXY` 中手动选择节点，但这不属于本方案的推荐使用方式。

客户端固定使用：

- `tcp-concurrent: false`
- `find-process-mode: off`
- `sniffer.enable: false`
- `log-level: error`
- `smux.enabled: false`
- `alpn: [http/1.1]`
- Mieru `transport: TCP`
- Mieru `multiplexing: MULTIPLEXING_LOW`
- Mieru `handshake-mode: HANDSHAKE_STANDARD`

Xray 的两个入站均设置 `heartbeatPeriod: 0`，不主动发送 WebSocket Ping。服务端使用同一个 Xray 进程，Nginx 关闭代理缓冲和请求缓冲，并保留一小时读写超时；系统侧启用 BBR、`fq`、MTU 探测、NTP 和长连接拥塞窗口保持。

Mieru 参数针对“中国移动直连 RackNerd DC2/洛杉矶”以稳定和有效吞吐优先：使用官方对大多数场景推荐的 TCP，复用级别采用 `LOW`，握手采用非 0-RTT 的 `STANDARD`；`udp: true` 允许 UDP 业务封装在 Mieru TCP 传输中，因此服务端只需开放 TCP `8443`。不启用额外 traffic pattern、TCP fragmentation 或 low-entropy 扩展，避免在长 RTT 链路上人为增加休眠、带宽膨胀和 CPU 开销。不同移动省份和时段路由会变化，这组参数是保守默认值，不代表所有线路的理论峰值。

## 准备清单

一套部署使用两个不同的 Cloudflare 域名；Mieru 默认直接使用自动探测到的 VPS 公网 IPv4：

| 域名 | 用途 | 安装前 | 安装后 |
|---|---|---|---|
| `node.example.com` | 两个 WebSocket 节点入口 | A 指向 VPS，保持 DNS only / 灰云 | 本机验收后切为 Proxied / 橙云 |
| `sub.example.com` | Worker 订阅入口 | 使用没有现有记录的新主机名 | 自动部署时由 Worker Custom Domain 创建 |

若不想在 Mieru 订阅中写公网 IP，可另设 `direct.example.com`，A 记录指向 VPS 并**始终保持 DNS only / 灰云**。不得复用安装后会变成橙云的 `node.example.com`；Cloudflare 普通代理的 `8443` 只承载 HTTPS，不承载 Mieru 原始 TCP。

还需要：

- Debian 12/13 amd64 独立 VPS，root、systemd，TCP 80/443/8443 未占用。
- VPS 公网 IPv4；只有确认 VPS IPv6 可用时才添加 AAAA。
- 已接入 Cloudflare 的 Active Zone。
- Cloudflare DNS API Token；自动部署 Worker 时还需要 Account ID 和 Worker API Token。
- 支持 VLESS、Trojan 和 Mieru 的近期 Mihomo / Clash Meta 客户端。

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

协议固定为双 WebSocket CDN + Mieru 直连，不再询问协议。为兼顾自动执行与用户自选，交互安装仍保留以下菜单与输入：

| 交互项 | 推荐选择 |
|---|---|
| 定时重启 | `1`，每天凌晨 4 点 |
| Cloudflare CDN 域名 | `node.example.com` |
| Mieru 直连地址 | 默认自动探测到的 VPS 公网 IPv4；若使用域名，必须是独立灰云域名 |
| Cloudflare DNS API Token | 输入 Zone Token，输入不回显 |
| 安装后 DNS 代理 | `1`，本机验收后自动把节点 A/AAAA 切为橙云 |
| 订阅输出方式 | `1`，自动部署 Worker |
| 订阅用户 Token 字典 | 使用自动生成值或自己的 JSON |
| Worker 名称 | 默认 `easy-cmcc` |
| Worker Custom Domain | `sub.example.com`，不得与节点域名相同 |
| Mihomo 下载文件名 | 默认 `EASY_CMCC`，不含 `.yaml` |
| Account ID / Worker Token | 自动部署时填写 |

可以通过环境变量减少交互，例如 `VLESS_CDN_DOMAIN`、`VLESS_WS_PATH`、`TROJAN_WS_PATH`、`VLESS_UUID`、`TROJAN_PASSWORD`、`MIERU_NODE_NAME`、`MIERU_SERVER`、`MIERU_PORT`、`MIERU_USERNAME`、`MIERU_PASSWORD`、`MIERU_MULTIPLEXING`、`MIERU_HANDSHAKE_MODE`、`CF_DNS_API_TOKEN`、`CF_PROXY_MODE=auto|manual`、`ALLOWED_TOKENS`、`CF_ACCOUNT_ID` 和 `CF_WORKER_API_TOKEN`。未指定时，Mieru 地址自动使用 VPS 公网 IPv4，端口使用 `8443`，用户名使用 `easycmcc`，密码随机生成；不建议为当前线路覆盖默认的 `MULTIPLEXING_LOW` 与 `HANDSHAKE_STANDARD`。

安装完成并通过本机验收后：

1. 默认情况下脚本已把节点域名的 A、AAAA 一起切为橙云；若选择手动模式，请自行切换。
2. Cloudflare SSL/TLS 使用 Full (Strict)。
3. 确认 Network → WebSockets 已开启；具备权限时脚本会自动开启 WebSockets。
4. 执行 `easy_cmcc status` 和 `easy_cmcc subscription`。
5. 将 Clash Meta 订阅导入 FLClash、Clash Verge 或其他近期 Mihomo 客户端，在 `PROXY` 中手动选择节点。
6. Mieru 使用域名时，确认该域名仍为灰云；只有两个 WebSocket 节点域名应切换橙云。

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

- `show`：同时显示三个节点链接和 Mihomo 节点片段。
- `subscription`：显示三个节点与 Worker 订阅地址。
- `status`：显示域名、WebSocket 路径、Mieru 参数、Xray/Nginx/mita 和 TCP 443/8443 状态。
- `update`：重新应用网络参数并刷新 Xray、mita、Nginx 和 Worker；旧双节点状态会在这里升级。
- `update-sub`：重新选择订阅部署方式并刷新订阅。
- `update-core`：同时更新 Xray 与 mita，验收失败时恢复两个旧版本。
- `renew-cert`：强制续期证书并重载 Nginx。
- `uninstall`：删除本机服务、状态、证书、命令和备份，不删除远端 Worker。

`switch` 不可用。状态格式保持 v2 并向后兼容本项目当前的双 WebSocket 状态；旧 gRPC 或其他协议安装仍不做兼容迁移，请先卸载旧安装，再用当前脚本安装。

## Cloudflare 权限

节点 Zone 的 `CF_DNS_API_TOKEN` 建议只授予：

- Zone → DNS → Edit：acme.sh DNS-01 和自动切换橙云。
- Zone → Zone → Read：查询 Zone ID。
- Zone → Zone Settings → Edit：自动开启 WebSockets。

自动部署 Worker 还需要：

- `CF_ACCOUNT_ID`：Cloudflare Account ID，不是 Zone ID。
- `CF_WORKER_API_TOKEN`：限制到目标 Account，只授予 Workers Scripts → Edit。

DNS Token 和 Worker Token 都不会写入 `/etc/easy_cmcc/state.env`。acme.sh 为自动续期可能在权限受限的 `/root/.acme-cmcc.sh/` 保存 DNS 凭据。

## Worker 与订阅

`update-sub` 提供三种选择：

1. 自动部署 Worker，并可绑定 Custom Domain。
2. 输出完整 Worker 源码供手动部署。
3. 只显示节点链接，不生成 Worker，也不询问 Token。

通用订阅同时输出 `vless://`、`trojan://` 和 `mierus://`；Clash Meta 订阅输出默认名为 `VLESS_WS`、`TROJAN_WS` 和 `MIERU` 的三个原生 Mihomo 节点。三者同时进入 `AUTO` 和 `PROXY`：默认 `PROXY → AUTO` 自动选择，也可在客户端菜单中改为任一节点。Worker 只负责下发 Mieru 参数，Mieru 数据流不会经过 Worker 或 Cloudflare。

局域网 IPv4/IPv6 地址绕过 TUN，国内常用服务直连，其余规则进入 `PROXY`。下发的 TUN 使用 `stack: system`、`auto-route: true`、`auto-detect-interface: true`、`strict-route: false` 和 `mtu: 1500`。国内 DNS 使用阿里与腾讯两家独立 DoH（`dns.alidns.com`、`doh.pub`），阿里/腾讯的 IPv4 公共 DNS 仅用于引导解析；已确认的境外域名则经 `PROXY` 使用境外 DoH。YouTube 与 `googlevideo.com` 的 UDP/443 会先被拒绝，让客户端快速回退到 TCP，避免 WebSocket/TCP 外再叠加 QUIC 重传。节点使用 `ip-version: dual`，顶层 `ipv6: true`，但应用 DNS 保持 `ipv6: false`，兼顾中国移动蜂窝 IPv6 与不完整 IPv6 网络。

## 故障排查

- 两个 WebSocket 节点都连接失败：确认节点域名已经橙云、SSL/TLS 为 Full (Strict)、Cloudflare WebSockets 已开启、证书域名与 SNI 一致。
- 只有一个节点失败：核对该节点订阅路径与 `VLESS_WS_PATH` 或 `TROJAN_WS_PATH` 是否一致，确认客户端没有合并旧配置。
- Mieru 单独失败：执行 `easy_cmcc status`，确认 mita active、TCP 8443 listening；检查 VPS/上游防火墙，并确认 `MIERU_SERVER` 是公网 IP 或始终灰云的独立域名。不要把它指向橙云地址。
- Mieru 提示认证或握手失败：确认客户端时间正确；协议密钥依赖客户端和服务端系统时间，服务端已启用 NTP。
- Android 仍耗电：确认 `AUTO` 的周期测速是否符合预期；两个 WebSocket 节点均为 `smux.enabled: false`，且不存在 provider 健康检查。
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
