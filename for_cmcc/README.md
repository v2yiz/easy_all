# easy_cmcc

`easy_cmcc` 是面向中国移动网络的独立安装器，只部署 **VLESS gRPC TLS + Cloudflare CDN**。不提供 Reality、AnyTLS、XHTTP、WebSocket 或协议切换，也不迁移旧协议状态。

```text
Mihomo / FLClash -> Cloudflare CDN :443 -> Nginx :443 -> Xray gRPC 127.0.0.1:10085
```

公网接入为 TLS + HTTP/2 + TCP 443。客户端节点固定使用：

- `network: grpc`
- `alpn: [h2]`
- `packet-encoding: xudp`
- `grpc-opts.ping-interval: 0`
- `grpc-opts.max-connections: 1`
- `smux.enabled: false`

这些设置避免额外的 smux 层、周期性 gRPC ping 和多条并行底层连接，优先降低 Android 后台 CPU、网络唤醒和耗电。实际速度仍取决于中国移动到 Cloudflare 边缘、Cloudflare 回源和 VPS 线路。

## 准备清单

一套部署使用两个不同域名：

| 域名 | 用途 | 安装前 | 安装后 |
|---|---|---|---|
| `node.example.com` | gRPC 节点入口 | A 指向 VPS，保持 DNS only / 灰云 | 本机验收后切为 Proxied / 橙云 |
| `sub.example.com` | Worker 订阅入口 | 使用没有现有记录的新主机名 | 自动部署时由 Worker Custom Domain 创建 |

还需要：

- Debian 12/13 amd64 独立 VPS，root、systemd，TCP 80/443 未占用。
- VPS 公网 IPv4；只有确认 VPS IPv6 可用时才添加 AAAA。
- 已接入 Cloudflare 的 Active Zone。
- Cloudflare DNS API Token；自动部署 Worker 时还需要 Account ID 和 Worker API Token。
- 支持 VLESS gRPC TLS 的近期 Mihomo / Clash Meta 客户端。

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

协议固定为 gRPC，不再询问协议。为兼顾自动化和用户选择，交互安装仍保留以下菜单与输入：

| 交互项 | 推荐选择 |
|---|---|
| 定时重启 | `1`，每天凌晨 4 点 |
| VLESS CDN 域名 | `node.example.com` |
| Cloudflare DNS API Token | 输入 Zone Token，输入不回显 |
| 安装后 DNS 代理 | `1`，本机验收后自动把节点 A/AAAA 切为橙云 |
| 订阅输出方式 | `1`，自动部署 Worker |
| 订阅用户 Token 字典 | 使用自动生成值或自己的 JSON |
| Worker 名称 | 默认 `easy-cmcc` |
| Worker Custom Domain | `sub.example.com`，不得与节点域名相同 |
| Mihomo 下载文件名 | 默认 `EASY_CMCC`，不含 `.yaml` |
| Account ID / Worker Token | 自动部署时填写 |

可以通过环境变量减少交互，例如 `VLESS_CDN_DOMAIN`、`GRPC_SERVICE_NAME`、`CF_DNS_API_TOKEN`、`CF_PROXY_MODE=auto|manual`、`ALLOWED_TOKENS`、`CF_ACCOUNT_ID` 和 `CF_WORKER_API_TOKEN`。未指定 `GRPC_SERVICE_NAME` 时脚本会自动生成随机值。

安装完成并通过本机验收后：

1. 默认情况下脚本已把节点域名的 A、AAAA 一起切为橙云；若选择手动模式，请自行切换。
2. Cloudflare SSL/TLS 使用 Full (Strict)。
3. 确认 Network → gRPC 已开启；具备权限时脚本会自动开启。
4. 执行 `easy_cmcc status` 和 `easy_cmcc subscription`。
5. 将 Clash Meta 订阅导入 FLClash、Clash Verge 或其他 Mihomo 客户端。

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

- `show`：显示 gRPC 节点链接和 Mihomo 节点片段。
- `subscription`：显示节点与 Worker 订阅地址。
- `status`：显示域名、gRPC service name、Xray/Nginx 和 TCP 443 状态。
- `update`：重新应用省电参数并刷新 Xray、Nginx 和 Worker。
- `update-sub`：重新选择订阅部署方式并刷新订阅。
- `update-core`：更新 Xray，验收失败时恢复旧版本。
- `renew-cert`：强制续期证书并重载 Nginx。
- `uninstall`：删除本机服务、状态、证书、命令和备份，不删除远端 Worker。

`switch` 不可用。旧协议安装不做兼容迁移；如状态文件中的协议不是 `vless-grpc`，请先卸载旧安装，再用当前脚本安装。

## Cloudflare 权限

节点 Zone 的 `CF_DNS_API_TOKEN` 建议只授予：

- Zone → DNS → Edit：acme.sh DNS-01。
- Zone → Zone → Read：查询 Zone ID。
- Zone → Zone Settings → Edit：自动开启 gRPC。

不再需要 XHTTP Configuration Rules 权限。

自动部署 Worker 还需要：

- `CF_ACCOUNT_ID`：Cloudflare Account ID，不是 Zone ID。
- `CF_WORKER_API_TOKEN`：限制到目标 Account，只授予 Workers Scripts → Edit。

DNS Token 和 Worker Token 都不会写入 `/etc/easy_cmcc/state.env`。acme.sh 为自动续期可能在权限受限的 `/root/.acme-cmcc.sh/` 保存 DNS 凭据。

## Worker 与订阅

`update-sub` 提供三种选择：

1. 自动部署 Worker，并可绑定 Custom Domain。
2. 输出完整 Worker 源码供手动部署。
3. 只显示节点链接，不生成 Worker，也不询问 Token。

Clash Meta 配置仅包含一个 `VLESS_GRPC` 节点和一个 `PROXY` 选择组。它使用 `tcp-concurrent: false`、`find-process-mode: off`，日志为 `error`，关闭域名嗅探，TUN 使用 `system` 栈。局域网 IPv4/IPv6 地址绕过 TUN；国内常用服务直连，其余规则进入 `PROXY`。

YouTube 与 `googlevideo.com` 的 UDP/443 会先被拒绝，让客户端快速回退到 TCP，避免 QUIC/XUDP 套入 gRPC/H2/TCP 后产生嵌套重传。节点仍使用 `ip-version: dual`，应用 DNS 保持 `ipv6: false`，兼顾中国移动蜂窝 IPv6 与不完整 IPv6 网络。

## 故障排查

- 连接失败：确认节点域名已经橙云、SSL/TLS 为 Full (Strict)、Cloudflare gRPC 已开启、证书域名与 SNI 一致。
- 返回普通网页：核对订阅中的 `grpc-service-name` 与服务端 `GRPC_SERVICE_NAME`，并检查 Nginx 配置是否已更新。
- Android 仍耗电：确认实际导入的是最新 Clash Meta 订阅，节点包含 `ping-interval: 0`、`max-connections: 1`、`smux.enabled: false`，且没有被客户端合并配置覆盖。
- YouTube 慢：确认最终配置仍保留 UDP/443 拒绝规则，使浏览器回退到 TCP；同时测试不同 Cloudflare 边缘与 VPS 回源线路。
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
