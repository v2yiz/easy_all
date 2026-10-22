# 更新记录

## 1.6.7 更新说明（2026-10-22）

- 补充中国电信天翼账号/本机号码一键登录域名 `id6.me` 直连。该域名解析到中国电信云（`42.123.76.150`、`42.123.77.138`，PTR `mta.e.189.cn`），但不在 `cn`/`geolocation-cn` 集合中，fake-IP 下此前会落到 `MATCH,PROXY`；一键登录依赖运营商网关识别请求源，走代理会直接失败。
- 三套模板同步加入 `direct-services`/`direct-cdn`；`id6.me` 使用国内 DoH 并直连。其余运营商认证域名（`*.cmpassport.com`、`*.189.cn`、`*.wo.cn`、`*.wostore.cn`、`*.wosms.cn`、`mob.com`、`geetest.com`、`gepush.com` 等）已由 `direct-services` 的 `+.cn` 或 cn/geolocation-cn 集合覆盖。
- 新增 `id6.me` 的真实内核直连断言。
- 说明：这类域名涉及运营商取号；如不使用一键登录而想减少后台取号，可自行改为 REJECT，但会破坏相关 App 的一键登录。
- 兼容性：仅模板、文档与测试变化，Reality v7、Cloudflare v9 无需迁移；Worker 内嵌模板变化，Cloudflare 聚合订阅需重新构建。

源码版本标识为 `1.6.7`。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.6 更新说明（2026-10-22）

- 补充腾讯广点通图片域名 `ugdtimg.com` 直连（`pgdt.ugdtimg.com` 等子域）。该域名不在 `cn`/`geolocation-cn` 集合中（同源的 `gdtimg.com` 已在 `geolocation-cn`），fake-IP 下此前会落到 `MATCH,PROXY`。
- 三套模板同步加入 `direct-services`/`direct-cdn`；国内 DoH 会返回大陆腾讯边缘（实测阿里/腾讯 DoH 为 `112.16.242.130`），避免经代理走香港边缘。
- 新增 `pgdt.ugdtimg.com` 的真实内核直连断言。
- 说明：这是广告素材域名，本项目不做广告拦截；如需屏蔽请另加 REJECT 规则。
- 兼容性：仅模板、文档与测试变化，Reality v7、Cloudflare v9 无需迁移；Worker 内嵌模板变化，Cloudflare 聚合订阅需重新构建。

源码版本标识为 `1.6.6`。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.5 更新说明（2026-10-22）

- 补充国内认证、HTTPDNS 与 SDK 域名直连：`cmpassport.com`（中国移动认证，含 log2/config 子域）、`httpdns.pro`（HTTPDNS，含 kuaishou 子域）、`ctobsnssdk.com`（穿山甲/字节 SDK 日志）。三者不在 `cn`/`geolocation-cn` 集合中，fake-IP 下此前会落到 `MATCH,PROXY`。
- 三套模板同步加入 `direct-services`/`direct-cdn`；两套内联集合同时用于 `nameserver-policy`，因此这些域名使用国内 DoH 并直连。
- 新增 `log2.cmpassport.com`、`config.cmpassport.com`、`kuaishou.httpdns.pro`、`toblog.ctobsnssdk.com` 的真实内核路由断言。
- 说明：`ctobsnssdk.com` 属于广告/统计 SDK；本项目不做广告拦截，按国内域名直连；如需拦截应另加 REJECT 规则。`httpdns.pro` 是共享 HTTPDNS 域名，整域直连。
- 兼容性：仅模板、文档与测试变化，Reality v7、Cloudflare v9 无需迁移；Worker 内嵌模板变化，Cloudflare 聚合订阅需重新构建。

源码版本标识为 `1.6.5`。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.4 更新说明（2026-10-22）

- 单标签主机名（无点，如 `getmobileredirecthost`、`wpad`、`isatap` 及 `nas`、`router` 等裸设备名）改为 `DOMAIN-REGEX,^[^.]+$,DIRECT`，不再落到 `MATCH,PROXY`；这类名字不是公网域名，直连时依赖本机 hosts 或局域网 DNS。
- 新增内联 `captive-portal` 集合，覆盖 Android（gstatic/android/clients3）、华为、荣耀、小米、OPPO、vivo、Apple、Firefox、GNOME、KDE 与 Windows NCSI 的连接性检测域名；这些域名使用系统 DNS 并直连，避免被 `proxy-services` 送进代理后无法弹出认证门户或误判网络。
- `captive-portal` 在 `nameserver-policy` 与规则中都排在 `proxy-services` 之前；单标签规则排在代理规则之前。规则集数量与 MRS 内存预算不变（默认七个、完整版八个）。
- 新增 `connectivitycheck.gstatic.com`、`getmobileredirecthost`、`wpad` 的真实内核断言；更新 classic 内联集合计数与 8 KiB 预算；文档同步。
- 兼容性：仅模板、文档与测试变化，Reality v7、Cloudflare v9 无需迁移；Worker 内嵌模板变化，Cloudflare 聚合订阅需重新构建。

源码版本标识为 `1.6.4`。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.3 更新说明（2026-10-22）

- 默认与完整模板、经典模板新增国内 SDK 域名库 `geosite-geolocation-cn`（约 5 千条，覆盖个推、极光、友盟、GrowingIO、Sensors 等国内推送/统计域名），修复 `cm-10-134.getui.com` 这类域名因不在 `geosite-cn` 中而落到 `MATCH,PROXY`；`geosite-cn` 仍负责约 11 万条国内站点长尾。
- 默认模板规则集由六个增至七个（完整版八个）；`nameserver-policy` 把两套集合都归入国内 DoH，代理例外与 QUIC 回退顺序不变。
- 本机 TUN 关闭、真实 MRS、50ms 采样下默认模板峰值约 42 MiB（两套集合合计约 570 KB 下载），仍在 50MB 优化目标内；冷启动失败回退内联集合。
- 新增 `www.hxkba.com`、`cm-10-134.getui.com` 路由断言，覆盖默认/完整/经典模板的缓存与冷启动；文档同步为“默认加载国内与 SDK 域名库”。
- 兼容性：仅模板、文档与测试变化，Reality v7、Cloudflare v9 无需迁移；Worker 内嵌模板变化，Cloudflare 聚合订阅需重新构建。

源码版本标识为 `1.6.3`。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.2 更新说明（2026-10-22）

- 默认模板新增国内域名库 `geosite-cn`（约 11 万条，含 `.cn` 与大量 `.com`、`.org` 等国内站点），规则集由五个增至六个；此前默认模板不加载该集合，`www.hxkba.com` 这类未收录的国内站点会落到 `MATCH,PROXY`，而完整版与经典模板已经覆盖。
- `nameserver-policy` 同步把 `geosite-cn` 归入国内 DoH；代理例外 `proxy-services`/`geosite-google` 仍排在前面，`google.cn`、`services.googleapis.cn` 继续走代理，QUIC 回退顺序不变。
- 本机 TUN 关闭、真实 MRS、50ms 采样下默认模板峰值约 42.7 MiB，仍在 50MB 优化目标内；MRS 冷启动下载失败时回退内联集合，已收录域名之外的行为不变。
- 新增 `www.hxkba.com` 的 `geosite-cn` 路由断言，并补充默认模板缓存/冷启动、完整版与经典模板的回归覆盖；文档同步为“默认加载国内域名库，仍不加载境外域名库”。
- 兼容性：仅模板、文档与测试变化，Reality v7、Cloudflare v9 无需迁移；Worker 内嵌模板变化，Cloudflare 聚合订阅需重新构建。新增规则集意味着默认模板首次启动会下载约 535 KB 的 `geosite-cn.mrs`。

源码版本标识为 `1.6.2`。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.1 更新说明（2026-10-22）

- 三套 Mihomo 模板的 CN GeoIP 兜底改为只匹配已有目标 IP：默认与完整模板使用 `RULE-SET,geoip-cn,DIRECT,no-resolve`，经典模板的 `GEOIP,CN` 与国内 QUIC 子规则同步加上 `no-resolve`；未命中域名集合的域名不再为了 GeoIP 判断额外解析，直接交给 `MATCH,PROXY`。
- Telegram 的 QUIC 拒绝子规则与 ipcidr 集合改用 `no-resolve`，并删除默认与完整模板中重复的解析版 `GEOIP,LAN,DIRECT`；未带 `.lan` 等后缀的裸主机名不再由 GeoIP 兜底解析，需使用私有后缀、本机 hosts 或客户端 DNS 覆写。
- 私有域名与既有例外不变：`private-fallback`/`geosite-private` 继续用于 Fake-IP 例外、系统 DNS 与直连；微信、Steam、Apple 国内调度等直连集合、QUIC 回退顺序与最终 `MATCH,PROXY` 均保持原语义。
- 客户端指南、技术参考、Worker 说明与运维指南同步为「只匹配已有真实 IP、未收录域名在出口侧解析、未知 QUIC 回退 TCP」，并补充裸主机名边界与非零 DNS 声明。
- 测试新增 `unknown-cn-mapped.net` 用例：先让域名在国内 DNS 中解析出中国 IP，再验证域名连接不会命中 CN GeoIP 缓存，而是 TCP 走代理、UDP/443 被拒绝；同时增加模板与文档断言，锁定解析版兜底不得回归，真实内核矩阵由 CI 的固定 v1.19.32 执行。
- 测试脚本改为只面向 Debian 12/13：移除 `stat -f` 回退与 macOS Bash 3.2 的动态 fd 兼容，统一使用 GNU `stat -c` 与 Bash 4.1+ 的 `exec {fd}<`；本地 `.pi/` 配置目录不再进入版本控制。
- 兼容性：仅修改订阅模板规则、文档与测试，不改变协议、状态或数据结构；Reality 状态保持 v7、Cloudflare v9，无需迁移。默认/完整模板的规则集数量与内存预算不变（5/7 个 MRS），Worker 内嵌模板随本次变化，Cloudflare 聚合订阅需重新构建。

源码版本标识为 `1.6.1`（Git 标签 `1.6.1`）。升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-14

- 新增可选 Skyline Speeder TCP 加速，默认和旧状态仍使用 XanMod BBRv3。仅建议用于丢包率极高且确认为非拥塞随机丢包的线路；菜单、帮助和文档明确额外出站流量及适用范围。
- 旧内核选择 Skyline 时先安装或升级 XanMod LTS 并验收 Linux 6.12+，继续完成其余安装；结束后重启一次，开机任务自动安装并启用 Skyline。任务最多等待运行时写锁 60 秒，成功后移除自身，失败保留回退配置、日志及重试状态；Reality 的 TCP 应用步骤也纳入运行时锁。
- 固定 Skyline v0.5.1 源码提交和预编译包 SHA256；旧 glibc 明确提示后从源码编译 Rust/BPF。按源码提交、安装记录及二进制版本决定复用或就地升级，下载、检查及替换失败保留旧安装器，支持修复残留源码目录。
- 状态核对两个服务、实际拥塞控制及物理 FQ，失败时统一给出重试和切回 BBRv3 的命令；切回 BBRv3 只停用 Skyline，安装回滚和卸载清理开机任务及托管的 Skyline 安装。
- 开机等锁超时日志给出专用恢复命令，版本验收失败显示期望及实际输出；文档说明交互应用遇锁占用时重试，以及手工安装的更新版可能被固定版本覆盖。
- 补充版本升级、替换失败恢复、运行时锁等待、BBR 回退、开机任务生命周期和 README/CHANGELOG 版本一致性回归测试。状态版本保持 Reality v7、Cloudflare v9；本次不修改 Worker 运行源码，无需仅为此重建 Worker。

源码版本标识为 `2026-10-14`。已有部署执行 `sudo easy_all self-update` 后，可用 `sudo easy_all tcp skyline` 选择 Skyline；已选择 Skyline 的部署执行 `sudo easy_all apply` 更新到项目固定版本，无需先卸载。详见[运维指南](docs/operations-guide.md#tcp-加速选择)。

## 2026-10-13-v1

- 修复聚合订阅生成的 Worker 在编辑器中的三处类型诊断：XHTTP 与 WebSocket 节点直接输出固定的 `ip-version: ipv4`，移除仅返回常量的无参函数及多余参数；上游 HTTP 错误在构造时附带 `httpStatus`，消除标准 `Error` 不包含该属性的诊断。
- 保持订阅 IPv4 策略、上游失败提示及鉴权返回行为；补充生成 Worker 的 HTTP 403/429 状态码保留检查。
- 源码发布版本为 Git 标签 `2026-10-13-v1`；Worker 构建版本继续独立递增，现有 Worker 需重新构建并部署才能消除这些诊断。状态版本保持 Reality v7、Cloudflare v9，无需迁移。

升级执行 `sudo easy_all self-update`；Cloudflare 聚合订阅再执行 `sudo easy_all update-sub`，聚合配置选择“保留”。独立手工部署的 Worker 在其构建环境重新构建并部署。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-13

- 修复 Reality 自托管订阅的 Nginx HTTP/2 弃用告警：将已有版本检测移入通用模块，订阅引导与正式配置在 Nginx 1.25.1+ 使用 `listen ... ssl;` 和 `http2 on;`，旧版本保留 `listen ... ssl http2;`，兼容 Debian 12/13。Cloudflare 模式复用同一检测，配置行为不变。
- 完整测试入口增加 Bash 4.1+ 与 GNU coreutils（`stat`、`date`）前置检查；环境不满足时立即给出原因和 Linux/容器运行建议，macOS 可单独运行 `npm run test:worker`。补充 Reality 两种配置在新旧 Nginx 上的回归检查，以及 GNU 工具缺失时的提示检查。
- 源码发布版本为 Git 标签 `2026-10-13`；Worker 构建版本继续独立递增，本次无需重新部署 Worker。状态版本保持 Reality v7、Cloudflare v9，无需迁移。

升级执行 `sudo easy_all self-update`；Reality 自托管订阅再执行 `sudo easy_all apply`，生成适配当前 Nginx 版本的配置。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-12

- 修复状态保存、订阅更新回滚和 Globalping 优选缓存的原子替换依赖 GNU 专有选项 `mv -fT`：在非 GNU 环境（macOS/BSD 的 `mv`）会报 `mv: illegal option -- T`，使本机回滚在恢复 `state.env` 时中断。三处统一为与订阅发布等既有路径一致的 `mv -f --`；Debian 12/13 上仍是同目录重命名，行为不变。
- 同步 `test/test_cdn_runtime.sh` 的原子回滚桩：该桩此前固定要求 `mv` 首参数为 `-fT`，与上面的实现调整不一致导致 GitHub Actions 的测试中断；现断言与实现一致的首参数 `-f`，目标路径、`0600` 权限、同目录暂存与旧状态仍可读等校验不变。仅测试内容变化，不影响安装器运行时行为。
- 源码发布版本为 Git 标签 `2026-10-12`；Worker 的 `X-Easy-All-Version` 是独立构建版本，继续按北京时间自动递增。本次未修改 Worker 运行源码，无需仅为这些修复重新部署 Worker。状态版本保持 Reality v7、Cloudflare v9，无需迁移。

升级执行 `sudo easy_all self-update`；本次不涉及配置生成，无需再执行 `sudo easy_all apply`。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-11

- 修复 Reality 自托管订阅在交互安装时调用未定义的 `prompt_secret`：`reality_cloudflare_collect_api_token` 依赖仅由 XHTTP 模式加载的输入函数，选择部署订阅后 Token 输入必然失败。`prompt_secret` 上移至 `lib/profile-common.sh` 供两种模式共用。
- 修复 Cloudflare API 空响应及多文档校验：jq 1.6 对空输入的 `jq -e` 返回 0，原校验也未限制响应只能包含一份 JSON 文档。两种 Profile 的 API 请求改用 `jq -s` 要求恰好一份成功信封；Cloudflare 模式保留成功 DELETE 空响应的处理，本地测试套件在 jq 1.6 上恢复通过。
- 修复关闭或更换订阅域名时旧订阅 Worker 清理失败后身份丢失、无法重试：新增 `CLOUDFLARE_SUBSCRIPTION_RETIREMENTS` 持久化待清理身份，`apply-cloud` 与 `uninstall --purge-cloud` 自动重试；补齐切换回旧域名与关闭后重新启用同名 Worker 的接管校验，清理失败时保留身份，避免因丢失所有权记录而无法恢复。
- 修复 `state.env` 与 Globalping 优选缓存以 `install` 就地覆写：改用同目录暂存加 `mv -f` 原子替换，写入失败保留旧文件；状态写入逐步检查失败，不再发布不完整状态。
- 修复 Reality 订阅域名已有正确 A 记录时跳过 AAAA/CNAME 冲突检查：三类记录核对完成后才复用或修改 DNS，避免后续加入的 AAAA/CNAME 被静默接受。
- 修复配额安装提示输出全体用户 Token：改为仅输出用户数量。
- 修复 Worker 构建允许 Reality 节点占用 `🇭🇰CF1`–`🇭🇰CF6` 保留名：该名称由兜底 CDN 节点自动生成，重名会导致 Clash 订阅请求整体失败，构建期改为直接拒绝。
- 补充隐藏输入、空/多文档 API 响应、DNS 冲突、订阅 Worker 清理重试与重新接管、状态与缓存发布边界、保留名冲突的回归检查。
- 源码发布版本为 Git 标签 `2026-10-11`；Worker 的 `X-Easy-All-Version` 是独立构建版本，继续按北京时间自动递增。本次未修改 Worker 运行源码，无需仅为这些修复重新部署 Worker；构建期保留名检查在下次构建时生效。状态版本保持 Reality v7、Cloudflare v9，旧状态缺少待清理字段时按空列表加载。

升级执行 `sudo easy_all self-update`，再执行 `sudo easy_all apply`；详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-10-v1

- 修复 Cloudflare 每小时刷新先删除订阅目录造成的 502 窗口：全部渲染并校验后，逐文件原子替换；Reality 发布与本机订阅回滚共用该流程。
- 修复 Cloudflare 回源端口和 Reality 订阅端口在 UFW 刷新期间被临时全网放行的问题；保留 SSH 预放行，添加并验收新白名单后再清理旧来源。
- 补充渲染失败、发布中断、持续可读、配额模式切换和防火墙更新顺序的回归检查。
- 源码发布版本为 Git 标签 `2026-10-10-v1`；Worker 的 `X-Easy-All-Version` 继续在每次构建时按北京时间自动递增，本次服务端修复无需重建 Worker。

升级执行 `sudo easy_all self-update`，再执行 `sudo easy_all apply`；详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-10

- 默认 Mihomo 模板切换为 COMMON 精简规则；旧的 COMMON Lite 路径并入默认模板，经典 geodata 模板继续保留。
- Apple 分流收窄到 `apple-cn.mrs` 与精确国内调度域名；更换缓存路径，避免继续使用旧的全量 Apple 规则缓存。
- 三套模板将 `0.0.0.0/8` 拒绝规则移到 LAN 规则前，并补充 Apple 分流、缓存迁移和零地址回归测试。
- 聚合 Worker 的 `X-Easy-All-Version` 由构建脚本自动生成，格式为 `YYYY-MM-DD-vN`；日期按北京时间生成，同日递增。本次源码版本以 Git 提交标识，部署时生成的 Worker 版本号会在 `update-sub` 重建后显示。

Cloudflare 聚合订阅服务器更新步骤见[运维指南](docs/operations-guide.md#更新与应用)。
