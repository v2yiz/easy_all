# 技术参考

Bunny 模式（`mode: bunny-ws`）使用独立 VLESS WS/TLS Profile、一个自动调度域名节点和 owner 订阅；
Cloudflare DNS-only CNAME、凭据、费用、命令及恢复边界见
[Bunny 前置准备与运维](bunny-preparation-guide.md)。
安装与 `apply` 对 Bunny 边缘只检查 CDN 域名 HTTP 是否可达，并不自动证明生产 WebSocket
`101` 或 VLESS `204` 数据面可用。本地 WS `101` 与完整的 SOCKS -> VLESS/WS/TLS ->
Nginx -> Xray -> 公网 HTTPS 链路属于独立真实数据面测试，不能由安装期边缘可达性结果替代。


## 共同边界

- 只支持 IPv4。
- 服务器为 Debian 12/13、systemd、非容器环境；Bunny 支持 amd64/arm64，其他模式仅支持 amd64。
- 同一台 VPS 只能安装一种模式，且应由 easy_all 独占 Xray、Nginx 和相关端口。
- amd64 平台默认配置 Skyline Speeder（当前内核低于 6.12 时自动安装 XanMod LTS，并在重启后全自动激活）；arm64 Bunny 使用原有内核且暂不支持 Skyline Speeder 内核加速。
- Xray 阻断私网、链路本地、回环、组播和保留地址，并拒绝境外 UDP/443，使 QUIC 回退 TCP。
- Mihomo 节点固定使用 `ip-version: ipv4`；普通出站使用 `ForceIPv4` + `UseIPv4`。

脚本全局禁用 IPv6。Reality 域名若发布 AAAA，安装或 `apply` 会停止；A 记录必须指向当前 VPS
公网 IPv4。

Reality/Cloudflare/Gcore 成功安装或应用后，SSH 收敛到 TCP `65533`；Bunny 与组合模式（`mode: combined`）
保留现有 SSH 监听及检测到的全部端口。收敛模式的 UFW 先添加并验证 `65533` 放行，再将
本工具的 TCP `22` deny 放到首位，优先于已有的 OpenSSH/22 allow；重复应用不累积 deny。
收敛模式 Fail2ban 的 SSH jail 端口固定为 `65533`；组合模式不配置 Fail2ban。旧连接中的端口仅用于诊断，
不进入最终放行集合。
订阅不按 SSH 端口或进程名强制直连；
如需绕过代理管理 VPS，请在客户端添加该 VPS 地址的精确直连规则。

Reality/Cloudflare/Gcore 执行安装或 `apply` 前，先在云安全组放行 TCP `65533`，保留当前 SSH 会话。
今后使用 `ssh -p 65533 用户@服务器`，另开终端验证成功后再关闭旧会话。组合模式不改 SSH，
只需放行 TCP `443` 与 `8443`。本工具不自动修改云防火墙。

SSH 使用单个受管 drop-in，先检查语法与有效 `ListenAddress`，重载后确认实际 SSH 监听
端点与其一致且仅含 IPv4 `65533`。目标端口必须有 `sshd` 持有；仅由 `systemd` 持有、无法
确认属于 SSH 的 socket 按占用冲突处理。主配置或其他 Include 显式保留 `22`/自定义监听、外部
socket activation 持续监听旧端口、或 `65533` 被其他服务占用，均会失败并尝试恢复受管配置和
原服务。请通过服务商 Console 检查冲突，本工具不会批量改写管理员 SSH 文件或关闭其他服务。

卸载或首次安装回滚会恢复安装前的 SSH 配置，并检查语法、reload 及实际监听。每个恢复端口
都必须有 `sshd` 持有者，未知的 systemd socket 不能作为 SSH 恢复成功的依据。随后先撤销并
验证本工具的 UFW deny22，成功后才允许移除 allow65533 和恢复原防火墙状态。因此恢复原状态
可能重新开放 `22`。SSH 恢复或 deny22 撤销失败时恢复当前 `65533` 配置，保留该端口放行、
状态及备份，明确返回失败，修正后重试。带网卡限定的早期 deny65533 同样会阻止关闭 `22`。

在支持的 Debian 主机上可手动核对（本仓库测试使用隔离命令替身）：

```bash
sudo sshd -t
sudo sshd -T | grep -E '^(port|listenaddress) '
sudo ss -ltnp
sudo ufw status numbered
sudo fail2ban-client get sshd actions
ssh -p 65533 用户@服务器
```

有效 `Port` 条目可能包含管理员配置的值；最终以有效 `ListenAddress` 与实际监听端点为准。
macOS 的 `npm test` 验证隔离行为；真实 Debian 的 sshd/systemd/socket/UFW 与外网
密钥登录仍需部署环境验收。

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

Xray 26.9.8 起，REALITY 服务端会拒绝不含 `X25519MLKEM768` key share 的 ClientHello，而 mihomo
默认会剥离该 key share。因此：自托管订阅在本机 Xray 版本不低于 26.9.8 时，于 `reality-opts`
下输出 `support-x25519mlkem768: true`（其它版本、或版本文件无法解析时不输出）；Worker 聚合的
YAML 订阅默认携带该字段，可用节点字段 `supportX25519Mlkem768: false` 关闭（仅对 `nodes`
里的 Reality 节点生效）。该字段需 mihomo 1.19.9 及以上才生效，更旧的 mihomo 内核会忽略；
`flag=base64` 的 URI 订阅不携带此参数，Xray 系客户端自行协商。

聚合配置里的 Reality 节点若指向 Xray 低于 26.9.8 的服务端，请为该节点设置
`supportX25519Mlkem768: false`；旧 REALITY 服务端拿到混合 key share 可能直接认证失败。
Reality 私有源下发的链接在本机核心低于 26.9.8 时携带 `mlkem=0`，Worker 解析后同样关闭该字段。

动态端口按上海时间每小时提供 6 个 `10000-62703` 范围内的共享端口（覆盖闰年 366 天，每次请求按时间从当前小时的 6 个端口中挑选下发），由
UFW 的 `before.rules` 受管 NAT 区块以单条范围规则转发到 Xray `443`（并对落在该范围内的 SSH 端口前置 `RETURN` 豁免），不会生成数万条单端口 allow 规则。
安装与正常 `apply` 立即生成并加载完整范围，`11:30` 安装同样立即生效。UFW 持久化规则并在开机加载；
受管 cron 的单个 `@reboot` 任务在重启后刷新完整范围，不再按小时刷新，也不在每日重启前刷新。
客户端仍按每次请求的时间从当前小时的 6 个端口中选择，独立于 cron。
云安全组必须允许原始目标 TCP `10000-62703` 到达 VPS；UFW 在重定向后按 `443` 放行，SSH `65533` 在范围之外。

聚合 JSON 的 `nodes` 允许三种直连节点：VLESS/Reality、Trojan/TLS 与 Mieru。Trojan 节点由
`trojanLink()` 渲染 base64 URI、由 `clashTrojanNode()` 渲染 Mihomo YAML，端口缺省 `443`，
`password` 限制为 8-64 位字母、数字或 `.` `_` `~` `-`，`alpn` 仅接受 `http/1.1` 或 `h2`。
Mieru 节点由 `mieruLink()` 渲染 `mierus://` URI、由 `clashMieruNode()` 渲染 `type: mieru`，
`port` 与 `portRange` 必须且只能提供一个（直连模式使用 `50000-50512`），`username`/`password`
分别为 1-64 与 8-64 位受限字符，`transport` 仅接受 `TCP`，
`multiplexing` 允许 `OFF`/`LOW`/`MIDDLE`/`HIGH`，可选 `trafficPattern` 必须是标准 base64，
可选 `mtu` 只进入 URI（Mihomo 的 mieru 出站没有 MTU 字段）。两种节点都在
`lib/worker-config.sh` 的结构校验与 `scripts/build-worker.mjs` 的字段校验中提前拒绝非法输入。
`fallbackCdnNodes` 仍然只接受 VLESS/CDN 兜底节点，Trojan 与 Mieru 只能出现在 `nodes`；所有
`host` 可以是公网 IPv4 或 DNS only 域名，IPv6 literal 仍被拒绝。直连节点保持原始名称进入
`PROXY`，不会像动态 CDN 节点那样被改名为 `🇺🇸优选N`。

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

Reality 的 Worker 订阅聚合复用同一套 Worker、聚合 JSON 校验和私有源 HTTP 契约，区别有两点：
公开订阅域名与私有节点源域名是两个同 Zone 一级子域，回源 URL 带 `8443`；节点源返回的是
Reality URI 订阅。Worker 解析 `security=reality&type=tcp` 的链接并保留其发布名和动态端口，
这些节点直接列入 `PROXY`，不改名为 `🇺🇸优选N`，也不进入 `🇭🇰白天首选`/`🇭🇰CF` 测速组；
CDN 源节点仍按原有命名和分组处理。源不可用时仍返回 `502`，Token 被源拒绝时返回 `403`。

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
实际 iOS 峰值仍需设备验证，下载体积限制不等于 50MB 内存保证。需要 FCM/微信真实 IP 与更细的 DNS 分流时，用
`MIHOMO_TEMPLATE_SOURCE` 选择经典模板 `templates/mihomo-classic.yaml`（2.3.1 起规则集全部为 MRS，
不再加载 geodata/.dat），其行为如下：

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

## Skyline Speeder

默认使用 `TCP_ACCELERATION=skyline`；安装过程直接配置，不提供交互提问与切换选项。`apply` / `apply-cloud` 沿用配置。

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
`degraded` 和实际拥塞控制，修复后可用 `sudo easy_all apply` 重试。兼容内核上没有开机任务但 Skyline 未启用时同样显示 `degraded`。任务不在旧内核上加载 BPF，
也不会再次升级内核或发起重启。

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
实际拥塞算法和 FQ 队列。安装回滚与卸载时会取消开机任务，停止并禁用两个服务，调用保留的官方卸载器，
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
│  ├─ ws-bunny.sh
│  ├─ xhttp-gcore.sh
│  └─ xhttp-cloudflare-streamup.sh
├─ lib/
│  ├─ log.sh
│  ├─ params.sh
│  ├─ runtime-core.sh
│  ├─ bunny-api.py
│  ├─ bunny-runtime.sh
│  ├─ lego-install.sh
│  ├─ xhttp-runtime.sh
│  ├─ worker-backup.sh
│  ├─ globalping-cdn.sh
│  ├─ cloudflare-ip-pool.sh
│  ├─ gcore-ip-pool.sh
│  ├─ quota.sh
│  ├─ platform.sh
│  ├─ profile-common.sh
│  ├─ network.sh
│  ├─ mihomo-template.sh
│  ├─ firewall.sh
│  ├─ xray-core.sh
│  ├─ scheduled-maintenance.sh
│  ├─ subscription-auth.sh
│  ├─ worker-config.sh
│  ├─ reality-subscription.js
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
实现；Bunny 的 API/schema/持久 ownership、TLS/WS 验收与回源防火墙由独立 Bunny 模块负责。
`lego-install.sh` 为 Bunny 模式提供固定版本下载和续期定时器。`xhttp-runtime.sh` 只保留 XHTTP/Nginx 数据面逻辑。`params.sh` 是安装参数层（JSON 加载、逐字段
校验与错误聚合、模板生成、成功后删除参数文件），`profile-common.sh` 提供公共字段校验、安装失败
诊断与确认交互，`scheduled-maintenance.sh` 管理定时重启，`network.sh` 管理 IPv4-only 与 Xray 出站，
`firewall.sh` 管理 UFW。

Reality 本机订阅与 Worker 聚合共用同一份私有节点源：token map → exact internal alias →
`reality-subscription.js`
读取 `$request_filename` → 单次时间戳选择六槽位端口 → 完整响应；njs 不读取 query 或状态文件。
每用户只发布 `base64.port-template`、`mihomo.port-template` 两个专用端口模板。
生成期间的数字文件只用于临时校验，运行时目录不保留数字快照。只在生成的 Reality 节点端口
插入唯一 `__EASY_ALL_REALITY_PORT__`；YAML 模板最后有唯一完整 EOF 注释标记，读取时验证并
剥离，保留合法占位行的尾部截断也返回通用 503。标记只验证受信生成器的终止边界，不检测保留
合法尾行的任意中间改写，不代替 YAML parser 或文件权限。

运行时源文件随 manifest 安装，再原子复制到 `/etc/nginx/easy_all-reality-subscription.js`
（root:root 0644）；用户模板为 root:www-data 0640，目录 0750。Reality 配额重建始终使用
同一 njs writer；正常更新失败时先恢复脚本、模板和证书，再恢复完整配置并校验、重载。
共享 XHTTP locations 默认保持 static。安装与诊断步骤见
[运维指南](operations-guide.md#证书与-reality-动态端口)。


关键状态字段：

```text
STATE_VERSION=0
PROTOCOL=reality|cloudflare-streamup|bunny-ws|gcore
CDN_PROVIDER=cloudflare
VPS_IP_FAMILY=ipv4
VPS_PUBLIC_IPV6=
SUBSCRIPTION_MODE=link|deploy|worker
SUBSCRIPTION_DOMAIN=公开订阅域名（Worker 模式下为 Worker Custom Domain）
SUB_SOURCE_DOMAIN=私有节点源域名（仅 Reality Worker 聚合）
CLOUDFLARE_ACCOUNT_ID/CLOUDFLARE_WORKER_NAME/CLOUDFLARE_WORKER_DOMAIN_ID
WORKER_SOURCE_SECRET/WORKER_AGGREGATION_CONFIG={...}
GOOGLE_EGRESS_MODE=ipv4
GOOGLE_EGRESS_RESOLVED=ipv4
```

安装输入全部来自参数文件（`--params` / 位置参数），安装期只有失败后的清理确认是交互；
`edit-sub`、`uninstall`、`reality-target` 等运维命令仍为交互，Token 输入不回显。

## 测试

完整测试需要 Node.js 18+、Bash 4.1+、GNU coreutils（`stat`、`date`）、`jq` 和 Python 3 `jsonschema`（Debian 包 `python3-jsonschema`），
建议在 Linux/容器中运行。`npm test` 首先检查 Bash 和 GNU 工具，环境不满足时立即给出明确提示。

```bash
npm test
npm run test:bunny  # 离线 Bunny API/ownership、订阅、续期回滚与防火墙行为测试
```

Bunny 定向测试使用已安装 jsonschema 的 Python，可在 macOS Bash 3.2 运行；LibreSSL 缺少的
`-checkhost` 仅在测试边界转换，真实 TLS/CA/WS 仍需 Debian 部署验收。
macOS 默认 Bash 3.2 和 BSD 工具不满足完整测试要求，可运行 `npm run test:worker`
验证 Worker 构建与离线逻辑；该命令需要 Node.js 18+ 和 Bash，未配置 Mihomo 时跳过真实内核检查。
`npm test` 使用 Node、Bash、jq 和 OpenSSL，在隔离 fixture 中验证真实 Shell
模板生成、njs handler、Worker 算法对照、截断错误及新装/配额/更新恢复；不安装宿主依赖。
这些测试使用伪请求对象，真实 Debian 12/13 包激活、alias+njs 权限、HTTP HEAD/Content-Length
和日志隔离仍需要完整 OS 隔离环境的 Nginx 集成验证，不能把本机模拟结果当成真实 HTTP 通过。

测试覆盖入口和模块完整性、Reality、
Cloudflare XHTTP、Gcore CDN、Globalping 筛选、配额、TCP 参数、订阅渲染、Token 鉴权、证书轮换、
Worker 构建、更新顺序。Worker 测试覆盖
`mieruLink()`/`clashMieruNode()` 与聚合字段校验。真实 Debian 上的安装与 systemd 服务仍需部署验收。

订阅模板的发布检查固定使用 Mihomo v1.19.32，GitHub Actions 同时校验完整 Reality 订阅及
Worker 正常、降级、全部节点输出。可在本机用已有内核和 Geo 数据运行同样检查：

```bash
MIHOMO_CHECK_BIN=/path/to/mihomo MIHOMO_CHECK_HOME=/path/to/geodata npm test
```

仓库内置模板（默认 `templates/mihomo.yaml`、`templates/mihomo-common.yaml`、
`templates/mihomo-classic.yaml`）随运行时清单安装，无需在 VPS 安装 Mihomo，在发布命令前用
`MIHOMO_TEMPLATE_SOURCE` 选择。Reality 自托管订阅把选中的模板保存为
`/etc/easy_all/mihomo-template.yaml`，后续发布沿用该文件；该快照在发布成功时原子替换，但不在
`edit-sub` 失败回滚范围内，回滚后可能比 `state.env` 新。Cloudflare 聚合订阅必须在
`edit-sub` 时传入模板才能重建 Worker。Reality Worker 聚合的源域名、Worker 名称和聚合 JSON
由 `lib/worker-config.sh` 与 `scripts/build-worker.mjs` 共同校验；Worker 名称安装后不能就地改名。
持久化快照在安装时已经验证过；`edit-sub` 重建 Worker 时通过
`MIHOMO_TEMPLATE_TRUSTED=1` 复用该快照，不要求 VPS 安装 `mihomo`。**新提供**的自定义
`MIHOMO_TEMPLATE_SOURCE` 仍须安装 `mihomo` 或设置 `MIHOMO_CHECK_BIN`，可用
`MIHOMO_CHECK_HOME` 指定包含 `geoip.dat`、`geosite.dat` 的缓存目录；没有内核或校验失败时停止发布。
模板结构校验由本机订阅与 Worker 构建共用，错误内容不会打印，以免泄露自定义模板中的凭据。

## Gcore CDN（模式 4）

- 数据面：Xray VLESS WebSocket 监听 `127.0.0.1:10087`，Nginx 在 `443` 终止 TLS 并校验 Gcore 回源
  客户端证书（mTLS），同时按 Gcore 官方回源网段做 UFW 白名单。
- DNS：整区委派给 Gcore Managed DNS；安装器写源站 A、节点 CNAME 与可选订阅 CNAME，写入前读取
  RRset，值不一致就停止，不覆盖别人的记录。
- 入口：Globalping 三网定向测速精选 1～6 个真实入口 IPv4，节点命名 `🇺🇸优选1`～`🇺🇸优选n`，
  订阅使用单一 `AUTO` 组。
- 证书：Gcore 边缘用免费证书；源站证书由本机 acme.sh 签发（HTTP-01）；本机另生成自建 CA 与由其签发的
  客户端证书，把客户端证书和 CA 上传到 Gcore，Nginx 按该 CA 校验 Gcore 回源的 mTLS 客户端证书。
- TLS 版本：CDN 资源下发 `options.tls_versions={enabled:true,value:["TLSv1.2","TLSv1.3"]}`，边缘拒绝 SSLv3/TLS 1.0/1.1。
- 与组合模式的差异：模式 4 必须委派 Gcore Managed DNS、输出 IP 精选节点；组合模式的 Gcore 入口是
  单个域名节点（`gcore.<zone>` 灰云 CNAME），DNS 全部由 Cloudflare 管理。

## 组合模式（`mode: combined`）

一台专用 VPS 同时提供三个入口，共用一套 Xray 与 Nginx：

```text
公网 8443  Xray VLESS Reality（直连，伪装目标另配 SNI）
公网 443   Nginx
  ├─ cf-origin.<zone>     → 127.0.0.1:10086 Xray VLESS XHTTP stream-up（Cloudflare 回源）
  ├─ gcore-origin.<zone>  → 127.0.0.1:10087 Xray VLESS WS（Gcore 回源，Nginx 校验 Gcore 客户端证书）
  └─ sub.<zone>           → 订阅文件（base64 / mihomo）
```

- DNS 全部由同一个 Cloudflare Zone 管理，不把域名委派给任何 CDN 的 DNS。
- `443` 只对 Cloudflare 与 Gcore 官方回源网段开放；直连入口走 `8443`；SSH 端口保持安装前状态，
  安装器不修改 sshd，也不回收 SSH 端口。
- 证书：`cf-origin` 与 `sub` 用一张 Cloudflare Origin CA（SAN 两个名字）；`gcore-origin` 用
  Let's Encrypt（Cloudflare DNS-01）；Gcore 边缘证书由 Gcore 免费签发，用 HTTP-01 通过
  `gcore.<zone>` 的灰云 CNAME 验证，只覆盖该节点域名（订阅域名用上面的 Origin CA 证书，
  `_acme-challenge` 不委派给 Gcore）。
- 边缘就绪：Gcore CDN 资源新建后处于 `processed` 状态约 15 分钟，期间边缘不接流量、HTTP-01 必然
  失败。安装器先轮询资源 `active` 且 `gcore.<zone>` 的 CNAME 解析到账户 CNAME（最多 30 分钟），
  再让 Gcore 签发；证书 `FAILED` 时最多通过 `force-retry` 重试 2 次（间隔 60 秒）。证书已激活时
  幂等重跑直接跳过这些等待。
- HTTP-01 规则：Gcore 不会默认在边缘应答 `/.well-known/acme-challenge/`，资源上必须有一条来自系统
  模板「Let's Encrypt HTTP-01 challenge」的规则；安装器会幂等创建（已有同名/同路径规则则复用），
  并用 `POST /cdn/resources/{id}/ssl/le/pre-validate` 探活后再重试签发。缺这条规则时挑战会回源，
  源站要求 mTLS，边缘只能返回 502。
- 组合模式不改 SSH、不配置 Fail2ban；卸载时按安装前快照恢复 UFW 回源白名单与 `8443` 放行。
- 组合模式安装时会用 `xray tls ping` 验收 Reality 伪装目标的 TLS 1.3 握手并比对 ASN（仅告警），
  `reality-target` 修改目标时先验收再落盘；Globalping Token 在应用参数阶段校验。
- TLS 版本：源站 Nginx 固定 `TLSv1.2 TLSv1.3`；Gcore CDN 资源同时下发
  `options.tls_versions={enabled:true,value:["TLSv1.2","TLSv1.3"]}`，拒绝客户端用 SSLv3/TLSv1.0/1.1 连接边缘。
- 订阅只有一个 owner Token，输出三类节点（直连 1、Cloudflare 优选 6、Gcore 1）与单一 `AUTO`
  测速组（8 个节点平铺，不再嵌套 CF 子测速组）；不启用用户配额。
- `apply` 只重建本机 Xray/Nginx/订阅（不需要 Gcore Token）；`apply-cloud` 才写 DNS、签发证书并
  同步 Gcore 资源，会重新询问 Gcore Token。
