# 技术参考

## 共同边界

- 只支持 IPv4。
- 服务器为 Debian 12/13、amd64、systemd、非容器环境。
- 同一台 VPS 只能安装一种模式，且应由 easy_all 独占 Xray、Nginx 和相关端口。
- 两种模式都安装 XanMod LTS 内核，使用 `fq + BBRv3`，并关闭
  `tcp_slow_start_after_idle`。
- Xray 阻断私网、链路本地、回环、组播和保留地址，并拒绝境外 UDP/443，使 QUIC 回退 TCP。
- Mihomo 节点固定使用 `ip-version: ipv4`；普通出站使用 `ForceIPv4` + `UseIPv4`。

脚本全局禁用 IPv6。Reality 域名若发布 AAAA，安装或 `apply` 会停止；A 记录必须指向当前 VPS
公网 IPv4。

两种模式都会保留已检测到的 SSH 端口，并额外监听 TCP `65533`。UFW 在拒绝其他入站流量前
放行这些端口，Fail2ban 监控实际 SSH 端口列表。生成的 Mihomo 配置将 TCP `22` 和 `65533`
直连规则置顶，避免 TUN 把管理流量送回代理。

## 直连 Reality

Reality 使用 VLESS TCP Reality Vision，Xray 监听 TCP `443`：

```text
security=reality
flow=xtls-rprx-vision
type=tcp
```

默认伪装目标为 `swdist.apple.com:443`。安装器会执行带 SNI 的 TLS 1.3 握手，并通过 RIPE
Stat 尝试比较 VPS 与目标 IPv4 的 ASN；ASN 不同或查询不可用只告警，握手失败会停止应用。

动态端口按上海时间每 3 小时生成一个 `10000-12927` 范围内的共享端口，由
UFW 的 `before.rules` 受管 NAT 区块转发到 Xray `443`。规则保留近期历史窗口并预开放当天和
次日凌晨，不会生成数万条单端口 allow 规则。

自托管订阅使用独立的 Cloudflare 一级子域：

```text
客户端 -> Cloudflare Universal SSL -> VPS:8443 Origin CA -> Nginx
```

Reality 数据链路仍然直连 VPS，不经过 Cloudflare。VPS `8443` 只允许 Cloudflare 官方 IPv4
回源段。

## Cloudflare XHTTP

模式 2 使用 VLESS XHTTP `stream-up`。Xray 后端监听 `10086`，Nginx 作为私有源，Cloudflare
Universal SSL 终止客户端 TLS，Origin CA 保护回源。

节点筛选流程：

1. 从 Cloudflare 官方 IPv4 CIDR 生成候选。
2. 使用 Globalping 的电信、联通、移动探针测量并做 TLS 校验。
3. 每个运营商选择 2 个节点，共固定输出 6 个 IPv4。
4. 不使用域名或内置 IP 兜底。
5. systemd timer 每小时刷新；失败时只复用与当前入口策略兼容的缓存。

客户端节点的 `server` 是精选 IPv4，`servername` 与 `xhttp-opts.host` 是节点域名。因此精选 IP
订阅按 Mihomo 的配置格式和 XHTTP 能力生成，客户端必须支持 IP、SNI、Host 分离。

公开订阅只经过独立域名绑定的 Worker。Worker 使用 `global_fetch_strictly_public`，
转发同一 Token 和私有 `X-Easy-All-Worker-Source` 密钥，Nginx 执行最终鉴权；直接访问私有源
返回 `404`。

该模式使用 Cloudflare 官方 IPv4 CIDR，实现全链路固定 IPv4。API Token 需要目标 Zone 的
读取、DNS、Transform Rules、Config Rules、Zone Settings、SSL 权限，以及目标 Account 的
Workers Scripts Write。Worker 默认名称为 `easyall`。

Cloudflare XHTTP 是实时回源，不缓存隧道业务数据。若 VPS 仅统计出站流量，用户上下行载荷之和
会消耗 VPS 出站额度；协议开销、重传、Cloudflare 服务规则和账户风控会进一步限制实际容量。

## DNS 与分流

内置 Mihomo 模板启用 `tcp-concurrent` 和 fake-IP 持久化。业务例外先于宽泛分类：

- Google、OpenAI、Anthropic、Copilot 依赖项走代理 DNS 和代理出口；
- `services.googleapis.cn`、`r.bing.com`、`in.appcenter.ms`、`aka.ms`、`1drv.ms`
  不被通用中国大陆规则抢先；
- Apple、微软国内 CDN、Steam 下载和其他中国大陆域名使用国内 DoH；
- Kimi、MiniMax 等与国内集合重叠的服务维持直连优先。

服务器 TCP keepalive 默认使用 `300/30/5`，用于回收半开连接，不能替代 XHTTP 的应用层保活。
临时端口范围为 `13000-60999`，避开 Reality 动态入口和本机服务端口。

## BBRv3

XanMod 的 `tcp_bbr` 已包含 BBRv3，算法名仍显示为 `bbr`。安装器校验 XanMod APT 公钥，并按
CPU 能力选择 `linux-xanmod-lts-x64v1/v2/v3`；这里的 v1/v2/v3 是 CPU 指令集等级。

安装后不会自动重启。执行 `sudo reboot` 并重新登录后，只有
`sudo easy_all status` 显示 `BBRv3: active` 才表示新内核已生效。检测到 UEFI Secure Boot
时安装会提前停止。

## 模块边界

依赖方向为“统一入口 → Profile → 公共模块”：

```text
easy_all
├─ runtime.manifest
├─ profiles/
│  ├─ reality.sh
│  └─ xhttp-cloudflare-streamup.sh
├─ lib/
│  ├─ log.sh
│  ├─ runtime-core.sh
│  ├─ xhttp-runtime.sh
│  ├─ globalping-cdn.sh
│  ├─ cloudflare-ip-pool.sh
│  ├─ quota.sh
│  ├─ platform.sh
│  ├─ profile-common.sh
│  ├─ network.sh
│  ├─ mihomo-template.sh
│  ├─ firewall.sh
│  ├─ xray-core.sh
│  ├─ scheduled-maintenance.sh
│  ├─ subscription-auth.sh
│  └─ tcp-tuning.sh
├─ templates/
│  └─ mihomo.yaml
├─ worker-src/
│  └─ index.js
└─ scripts/
   ├─ build-worker.mjs
   └─ debian-init.sh
```

入口负责模式选择、命令分发和按 `runtime.manifest` 注册运行时。Profile 负责协议编排；
`runtime-core.sh` 统一日志、公共模块加载、退出回滚和 Xray 核心更新事务，协议验收由 Profile hook
实现；`xhttp-runtime.sh` 只保留 XHTTP/Nginx 数据面逻辑。`profile-common.sh` 提供公共交互和字段
校验，`scheduled-maintenance.sh` 管理定时重启，`network.sh` 管理 IPv4-only 与 Xray 出站，
`firewall.sh` 管理 UFW。

关键状态字段：

```text
STATE_VERSION=7  # Reality
STATE_VERSION=9  # Cloudflare XHTTP
PROTOCOL=reality|cloudflare-streamup
CDN_PROVIDER=cloudflare
VPS_IP_FAMILY=ipv4
VPS_PUBLIC_IPV6=
WORKER_AGGREGATION_CONFIG={...}
GOOGLE_EGRESS_MODE=ipv4
GOOGLE_EGRESS_RESOLVED=ipv4
```

所有需要用户输入的交互提示仅显示中文，密码和 Token 隐藏输入。

## 测试

```bash
npm test
```

测试覆盖入口和模块完整性、Reality、Cloudflare XHTTP、Globalping 筛选、配额、TCP 参数、
订阅渲染、Token 鉴权、证书轮换、Worker 构建和更新顺序。
