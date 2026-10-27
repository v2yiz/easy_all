# 技术参考

## 共同边界

- 只支持 IPv4。
- 服务器为 Debian 12/13、amd64、systemd、非容器环境。
- 同一台 VPS 只能安装一种模式，且应由 easy_all 独占 Xray、Nginx 和相关端口。
- 两种模式默认安装 XanMod LTS 内核并使用 `fq + BBRv3`，可选 Skyline Speeder；均关闭
  `tcp_slow_start_after_idle`。
- Xray 阻断私网、链路本地、回环、组播和保留地址，并拒绝境外 UDP/443，使 QUIC 回退 TCP。
- Mihomo 节点固定使用 `ip-version: ipv4`；普通出站使用 `ForceIPv4` + `UseIPv4`。

脚本全局禁用 IPv6。Reality 域名若发布 AAAA，安装或 `apply` 会停止；A 记录必须指向当前 VPS
公网 IPv4。

两种模式都会保留已检测到的 SSH 端口，并额外监听 TCP `65533`。UFW 在拒绝其他入站流量前
放行这些端口，Fail2ban 监控实际 SSH 端口列表。订阅不按 SSH 端口或进程名强制直连；
如需绕过代理管理 VPS，请在客户端添加该 VPS 地址的精确直连规则。

订阅先在暂存目录完整渲染、校验，再通过同目录候选文件逐文件原子替换；正常回滚使用相同发布流程。
同一订阅布局刷新期间保留现有路径，渲染失败不改动线上文件。发布途中被强制终止时，可能同时保留
完整的旧版和新版文件，不保证所有用户与格式属于同一批次；下一次成功刷新会统一更新。
切换配额模式时会清理旧布局，移除用户的文件在新文件发布完成后清理。

UFW 更新先放行并验证 SSH 与必要的直连端口，回源端口始终仅添加 Cloudflare 官方 IPv4 CIDR
规则，不再添加临时全网规则。新增来源重载并验收成功后才删除过期来源；中断时保留已有白名单。

## 直连 Reality

Reality 使用 VLESS TCP Reality Vision，Xray 监听 TCP `443`：

```text
security=reality
flow=xtls-rprx-vision
type=tcp
```

默认伪装目标为 `swdist.apple.com:443`。安装器会执行带 SNI 的 TLS 1.3 握手，并通过 RIPE
Stat 尝试比较 VPS 与目标 IPv4 的 ASN；ASN 不同或查询不可用只告警，握手失败会停止应用。
安装后修改该值使用 `sudo easy_all reality-target <域名:端口>`，它把 SNI 与回源目标一起替换并重新
访问同样的验收；切换完成后服务端 `serverNames` 与客户端链接里的 `sni` 指向同一个域名。

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
独立纯 Worker 节点仅发布最多 6 个经 VLESS 转发探测成功的优选 IPv4，依次命名为
`🇭🇰CF1` 至 `🇭🇰CF6`，不发布域名入口。这些节点归入 `🇭🇰CF` URL-Test 组；测速目标使用
Google 的 `generate_204`，避免 Cloudflare Socket 禁止回连 Cloudflare 地址而产生误判。
两类 URL-Test 组的测速超时均为 `5000` ms，间隔和容差保持 `300` 秒、`30` ms。
白天首选和 🇭🇰CF 均设置 `hidden: true`，作为 PROXY 内的选项，内部自动选择低延迟节点。
PROXY 依次包含已配置的 US_VMISS、白天首选、晚上首选、🇭🇰CF 和其他已配置的节点。
所有代理流量（包括 YouTube）统一使用 PROXY 当前选择，没有额外模式或专用分流。
规则模式下，代理服务的 UDP/443 拒绝规则优先于手动分组选择，与自建 Xray 的拒绝策略一致；
国内直连 QUIC 仍保留。订阅不自动为第三方节点开放代理 QUIC。
模板显式定义 `GLOBAL` 且只包含 `PROXY`。全局模式因此统一复用 `PROXY` 当前选择，不暴露
Mihomo 自动生成的 `DIRECT`、`REJECT` 与节点平铺列表；局域网 IPv4 继续由 TUN 路由排除。
全局模式不执行客户端规则，UDP/443 由自建 Xray 的服务端策略拒绝。

纯 Worker 节点全面采用 XHTTP stream-one。首包解析和目标连接完成后，请求体与 TCP 上行、
TCP 下行与 `IdentityTransformStream` 分别通过原生 `pipeTo()` 直通，由底层流传递背压，
无需单连接 8 MiB 下行限制。连接建立阶段限制为 10 秒，后续生命周期由 HTTP、TCP 与客户端共同管理。
stream-one 的全部上行位于单个 HTTP 请求体内，仍受 Cloudflare 套餐请求体大小限制；
Free/Pro 通常为 100 MB，因此大文件上传应选择 VPS 节点。Worker 客户端 XMUX 使用
`maxConnections=4`，将并发代理请求分散到最多 4 条底层 HTTP/2 连接；单条 TCP 流仍保持有序，
不会拆分为多路传输。客户端路径统一规范为单个尾斜杠，Worker 下行使用
`Content-Type: text/event-stream` 并禁用缓存和代理缓冲。
部署验收和优选 IP 刷新会启动临时 Xray SOCKS 入站，以与订阅相同的候选 IP、SNI、Host、
HTTP/2 和 stream-one 参数访问 Google `generate_204`，避免普通 HTTP 请求产生误判。
新配置默认 `WORKER_BACKUP_PLACEMENT=off`，使用 Cloudflare 默认就近执行，避免无条件定向香港。
已有显式 `aws:ap-east-1` 设置继续保留；`🇭🇰CF` 是分组名称，不保证实际出口位于香港。

公开订阅只经过独立域名绑定的 Worker。Worker 使用 `global_fetch_strictly_public`，
转发同一 Token 和私有 `X-Easy-All-Worker-Source` 密钥，Nginx 执行最终鉴权；直接访问私有源
返回 `404`。

该模式使用 Cloudflare 官方 IPv4 CIDR，实现全链路固定 IPv4。API Token 需要目标 Zone 的
读取、DNS、Transform Rules、Config Rules、Zone Settings、SSL 权限，以及目标 Account 的
Workers Scripts Write。Worker 默认名称为 `easyall`。

Cloudflare XHTTP 是实时回源，不缓存隧道业务数据。若 VPS 仅统计出站流量，用户上下行载荷之和
会消耗 VPS 出站额度；协议开销、重传、Cloudflare 服务规则和账户风控会进一步限制实际容量。

## DNS 与分流

默认内置模板是 COMMON 精简版（`templates/mihomo.yaml`）：小型内联集合加七个 MRS 规则集，
国内域名库、国内 SDK 域名与常用域名优先直连；已有真实目标 IP 的其余连接按 LAN/CN GeoIP 兜底，未知域名不会仅因该兜底
额外解析，未命中时回落 `MATCH,PROXY`。国内常用服务和
Apple 国内调度域名使用国内 DoH，未知公网域名及代理服务使用经代理的海外 DoH，节点引导解析独立直连。
Apple 使用 `apple-cn.mrs` 加少量精确域名兜底，不强制整个 Apple/iCloud/CDN 直连；DNS 与路由共用
同一集合，其余 Apple 域名继续按普通域名/IP 规则分流。新的 `geosite-apple-cn.mrs` 缓存路径避免复用
旧全量 Apple 缓存；规则集数量仍为默认七个、完整版八个，不引入 DAT。
三套模板的 `0.0.0.0/8` 拒绝均优先于 LAN 规则，包含会被 LAN 识别为本地地址的 `0.0.0.0`。
COMMON 的 UDP NAT 空闲超时有意从 300 秒缩短为 60 秒，以更早回收空闲映射；后续通信可能需要
重建映射，而不是活跃会话定时断开。保留 `store-fake-ip: true` 用于跨重启复用映射，不承诺降低内存。
COMMON 不启用嗅探；没有域名或 DNS 映射的真实 IP 连接无法应用域名规则，即使对应域名已在内联集合中；
这些连接按 IP、端口及最终兜底规则分流。
境外服务使用中国 IP 时仍可能直连，是否开启嗅探应通过实际客户端连接记录与内存峰值验证。
私有域名的系统 DNS、真实 IP 例外和直连共用内联基础集合与私有域名 MRS；`.internal`、`.localdomain`
在无缓存且下载失败时仍受保护。微信资源共用内联集合完成国内 DNS、真实 IP 和直连；Steam 下载域名
显式使用国内 DNS 并直连，社区保持代理。这些例外优先于完整版的通用境外域名集合。
基础规则不依赖首次下载，MRS 更新失败保留可用缓存；默认加载 cn 与 geolocation-cn 域名库，不加载 geolocation-!cn 域名库。
单标签主机名（无点）使用 `DOMAIN-REGEX,^[^.]+$,DIRECT`；认证门户与连接性检测域名共用 `captive-portal`
内联集合，`fake-ip-filter` 返回真实 IP、`nameserver-policy` 使用系统 DNS、路由直连，并排在
`proxy-services` 之前，因此 `connectivitycheck.gstatic.*` 不再走代理。
`test/test_mihomo_common.mjs` 同时验证默认/完整模板的 Worker 输出及真实内核的 DNS、FCM、微信与内网真实 IP、
Apple 国内/境外分流、旧 Apple 缓存隔离、零地址拒绝、TCP/UDP 分流、重叠规则优先级、冷启动下载失败、缓存更新失败；
没有 `MIHOMO_CHECK_BIN` 时明确报告跳过真实内核
测试，CI 提供固定内核并生成小型 MRS 测试样本，无需在线下载规则才能运行这些回归。
实际 iOS 峰值仍需设备验证，下载体积限制不等于 50MB 内存保证。需要 geodata 模式与更细的 DNS 分流时，用
`MIHOMO_TEMPLATE_SOURCE` 选择经典模板 `templates/mihomo-classic.yaml`，其行为如下：

- 启用 `tcp-concurrent` 和 fake-IP 持久化，Fake-IP 例外使用传统 `blacklist` 格式，兼容
  Clash Party 等会接管 DNS 列表的客户端；
- Google、OpenAI、Anthropic、Copilot 依赖项走代理 DNS 和代理出口；
- `services.googleapis.cn`、`r.bing.com`、`in.appcenter.ms`、`aka.ms`、`1drv.ms`
  不被通用国内规则抢先；
- 未匹配策略且确需真实解析的公网域名默认使用经代理的海外 DoH，不再先查询国内 DNS 或使用
  GeoIP fallback；
- Apple、微软国内 CDN、Steam 下载、微信图片资源和其他中国大陆域名使用国内 DoH 并直连；
- 国内路由、DNS 与 Fake-IP 过滤统一使用完整 `cn` 集合，覆盖高德、微信、豆包等服务；
- `.ms` 在代理服务集合中优先匹配；Google、GitHub、OpenAI、Anthropic 和代理服务的 DNS 策略优先于 `cn`；
- CN GeoIP 兜底只匹配已有目标 IP：`RULE-SET,geoip-cn,DIRECT,no-resolve` 与
  `GEOIP,CN,DIRECT,no-resolve` 均不触发解析；国内 QUIC 子规则同样使用 `no-resolve`，
  未知 QUIC 由后续全局 UDP/443 拒绝处理并由应用回退 TCP；
- 这是首连等待与可预测性优先的取舍：未收录的国内域名默认代理，如需覆盖应使用更完整的域名集合；
  规则不承诺零 DNS，也不构成绝对无泄漏保证；
- `kimi.com`、`minimaxi.com` 等国内入口维持直连；国际入口按实际集合与 GeoIP 分流；
- 私有域名使用系统 DNS，本机 hosts 生效；代理节点域名由两个独立的国内 DoH 解析；移动端的覆盖
  方式见客户端指南。

服务器 TCP keepalive 默认使用 `300/30/5`，用于回收半开连接，不能替代 XHTTP 的应用层保活。
临时端口范围为 `13000-60999`，避开 Reality 动态入口和本机服务端口。

TCP 未发送数据阈值 `tcp_notsent_lowat` 为 `32768`（32 KiB）。FQ 应用和状态检查会读取
默认 IPv4 出口的实际 qdisc；多队列网卡保留 `mq` 类型，叶子队列切换为 `fq`。
内核默认的 `mq 0:` 无法通过 `parent :N` 修改子队列，会在保存配置后重建为 `mq ea00:`，
并映射子队列 parent；应用失败时恢复本次应用前的叶子参数。开机服务使用相同逻辑。
首次接管前保存 `fq_codel` / `pfifo_fast` 配置，重复 apply 与开机服务不会覆盖备份；
卸载和安装回滚会恢复并验收原参数。已有 `fq` 保持不变，自定义或无法可靠恢复的队列拒绝接管。
恢复叶子参数后保留可寻址的非零 mq handle；混合已有 FQ 的零 handle mq 拒绝重建，以免丢失自定义参数。
恢复失败会停止清理并保留备份。旧版安装未保存过原队列，升级只能记录升级时的状态，无法追溯安装前配置。

## BBRv3

XanMod 的 `tcp_bbr` 已包含 BBRv3，算法名仍显示为 `bbr`。安装器校验 XanMod APT 公钥，并按
CPU 能力选择 `linux-xanmod-lts-x64v1/v2/v3`；这里的 v1/v2/v3 是 CPU 指令集等级。

安装后不会自动重启。执行 `sudo reboot` 并重新登录后，只有
`sudo easy_all status` 显示 `BBRv3: active` 才表示新内核已生效。检测到 UEFI Secure Boot
时安装会提前停止。

## Skyline Speeder（可选）

默认和旧状态文件均使用 `TCP_ACCELERATION=bbrv3`；选择 Skyline 时保存为
`TCP_ACCELERATION=skyline`。首次安装提供菜单，安装后用 `easy_all tcp [bbrv3|skyline]` 切换，
`apply` / `apply-cloud` 沿用已保存的选择。

**仅在丢包率极高且确认为非拥塞随机丢包时选择 Skyline Speeder**；它不适合拥塞瓶颈，也不保证
与其他流公平分享带宽，默认冗余会额外消耗出站流量。作用范围为 VPS 新建 TCP 连接的发送方向，
已有连接保留原算法，独立 Worker 节点不受影响。

启用要求当前运行 Linux 6.12+、内核 BTF 和统一 cgroup v2。旧内核上选择 Skyline 时复用
XanMod LTS 安装流程，已有旧元包但内核不足 6.12 时也会刷新 APT 并升级，安装后验收内核版本
及 vmlinuz/initrd。暂不重启，写入 `bbr` 回退和重启标记，注册一次性开机任务
`easy_all-skyline-setup.service`，继续完成其余安装并保存 Skyline 选择，状态显示 `pending-reboot`。
安装结束只需重启一次；任务在网络、sysctl 和物理 FQ 就绪后，通过内部 `tcp-resume` 命令
读取已保存的选择，最多等待运行时写锁 60 秒，自动安装并启用 Skyline，期间显示 `pending-activation`。开机安装需要联网，
允许较长的源码编译时间。成功后删除任务和标记；失败时保留 BBR 回退、任务和日志，显示
`degraded` 和实际拥塞控制，修复后可用 `sudo easy_all tcp skyline` 重试，或用 `sudo easy_all tcp bbrv3` 切回 BBRv3。兼容内核上没有开机任务但 Skyline 未启用时同样显示 `degraded`。任务不在旧内核上加载 BPF，
也不会再次升级内核或发起重启；已切回 BBRv3 的状态不会被旧任务覆盖。

首次接入校验固定 v0.5.1 源码的 SHA256，再调用[官方安装器](https://github.com/CYBERVERSE-Research/skyline-speeder)
执行平台、BPF verifier 与服务检查。glibc 2.38+ 使用固定版本的预编译包，先在本地按固定
SHA256 验证，再把已验证的本地包交给安装器；下载或校验失败均停止，不降级为仅信任 TLS。
Debian 12 的旧 glibc 会明确提示后由官方安装器从固定源码构建 Rust/BPF，可能需要较长时间、
额外编译依赖及 CPU/内存/磁盘资源。源码目录记录 `.easy-all-commit`，成功安装后记录
`.easy-all-installed`；后续应用同时核对记录、二进制版本和两个服务文件，匹配时复用，
否则就地安装项目固定版本，包括将手工安装的更新版本降级。更新源码先下载、校验并检查新安装器，再替换旧目录；替换失败恢复
旧安装器，残留的不完整目录不会导致嵌套。旧安装没有记录时会重新校验安装一次。
GitHub 源码归档的压缩字节可能变化；SHA256 不匹配时停止，维护者核实提交内容后再更新固定值。

共用现有 TCP 参数及物理出口 FQ 备份；sysctl 保留 `bbr` 作为开机回退，官方
`skyline-speeder-enable.service` 在守护进程就绪后附加 `skyline_cc`。状态检查同时验证两个服务、
实际拥塞算法和 FQ 队列。切回 BBRv3 先取消开机安装任务，再停止并禁用 Skyline 两个服务，
防止 drift guard 抢回算法，此切换仅停用、不卸载 Skyline；安装回滚与卸载也会取消任务，调用保留的官方卸载器，
再恢复 easy_all 的 TCP/FQ 备份。

## 月度配额

配额统计任务每分钟读取 Xray 的用户计数并累加。它与配置更新、核心更新共用同一把运行时写锁：
锁被占用时本轮最多等待 15 秒，超时则跳过并写入 `/etc/easy_all/quota-sync-pending` 标记；Xray
进程未重启时，后续定时任务会在锁释放后补算已累计的计数。

`quota-usage.json` 损坏时拒绝继续发布配置，命令直接失败并提示从备份恢复或重新启用配额，
不会把用户当作新账期清零或重新启用。丢失窗口取决于是否重启：持锁的长任务（如 `update-core`
下载后重启 Xray）期间统计会连续跳过，若长任务结束后 Xray 进程已重启，自上次成功统计以来的
整个未同步窗口都可能丢失，因为新进程的 Xray 计数从零开始；卸载同样会丢弃未同步的尾部计数。

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
│  ├─ worker-backup.sh
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
│  ├─ mihomo.yaml
│  ├─ mihomo-common.yaml
│  └─ mihomo-classic.yaml
├─ worker-src/
│  ├─ index.js
│  └─ backup.js
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

完整测试需要 Node.js 18+、Bash 4.1+、GNU coreutils（`stat`、`date`）及 `jq`，
建议在 Linux/容器中运行。`npm test` 首先检查 Bash 和 GNU 工具，环境不满足时立即给出明确提示。

```bash
npm test
```

macOS 默认 Bash 3.2 和 BSD 工具不满足完整测试要求，可运行 `npm run test:worker`
验证 Worker 构建与离线逻辑；该命令需要 Node.js 18+ 和 Bash，未配置 Mihomo 时跳过真实内核检查。

测试覆盖入口和模块完整性、Reality、Cloudflare XHTTP、Globalping 筛选、配额、TCP 参数、
订阅渲染、Token 鉴权、证书轮换、Worker 构建和更新顺序。

订阅模板的发布检查固定使用 Mihomo v1.19.32，GitHub Actions 同时校验完整 Reality 订阅及
Worker 正常、降级、全部节点输出。可在本机用已有内核和 Geo 数据运行同样检查：

```bash
MIHOMO_CHECK_BIN=/path/to/mihomo MIHOMO_CHECK_HOME=/path/to/geodata npm test
```

仓库内置模板（默认 `templates/mihomo.yaml`、`templates/mihomo-common.yaml`、
`templates/mihomo-classic.yaml`）随运行时清单安装，无需在 VPS 安装 Mihomo，在发布命令前用
`MIHOMO_TEMPLATE_SOURCE` 选择。Reality 自托管订阅把选中的模板保存为
`/etc/easy_all/mihomo-template.yaml`，后续发布沿用该文件；该快照在发布成功时原子替换，但不在
`update-sub` 失败回滚范围内，回滚后可能比 `state.env` 新。Cloudflare 聚合订阅必须在
`update-sub` 时传入模板才能重建 Worker。其他自定义模板须安装 `mihomo` 或设置 `MIHOMO_CHECK_BIN`，
可用 `MIHOMO_CHECK_HOME` 指定包含 `geoip.dat`、`geosite.dat` 的缓存目录；没有内核或校验失败时停止发布。
模板结构校验由本机订阅与 Worker 构建共用，错误内容不会打印，以免泄露自定义模板中的凭据。
