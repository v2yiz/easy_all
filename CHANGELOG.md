# 更新记录

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
