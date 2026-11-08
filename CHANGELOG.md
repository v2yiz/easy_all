## 4.4.0 更新说明（2026-11-08）

- **模式编号与链路变更（破坏性）**：删除旧的模式 2（Cloudflare 橙云 XHTTP），CloudFront 模式改为**模式 2「纯 CDN（CloudFront）」**；模式 3 改为**「直连+CloudFront」**（内部标识 `PROTOCOL=combined-cloudfront`）。两种 CloudFront 模式共用同一条链路：Cloudflare 只作灰云权威 DNS → AWS ACM（固定 `us-east-1`）→ CloudFront 分发 → 源站 Let's Encrypt 证书 + `X-Easy-All-Origin-Key` 头校验 → Nginx → Xray XHTTP；模式 3 另有固定 `8443` 的 Reality 入站。状态版本号仍为 `0`，模式 2/3 的所有文案只称 CloudFront，Cloudflare 仅表示 DNS 服务。
- **旧状态不支持接管（破坏性）**：旧版 `PROTOCOL=cdn` 与旧版橙云 `combined` 安装不能被当前版本接管或迁移，任何应用、续签、更新核心、编辑订阅都会明确拒绝并提示 `sudo easy_all uninstall`；卸载本身仍可执行，默认保留云端资源。卸载重装会产生新的 UUID / XHTTP 路径 / Token（模式 3 还有新的 Reality 密钥），**客户端必须重新导入新订阅链接**；旧订阅里的节点名与分组不再兼容，自定义模板若写死旧组名会在模板校验阶段报错并提示换回内置模板。
- **删除 CDN 优选与本机测速能力（破坏性）**：删除 Globalping 优选 IP、Cloudflare 候选池抽样、`CDN-AUTO`（`url-test`）与 `CDN-FALLBACK`（`fallback`）分组、`refresh-cdn-ips` 命令及其定时器；`lib/globalping-cdn.sh`、`lib/cloudflare-ip-pool.sh` 连同旧 `lib/cloudflare-mode.sh`、`profiles/cdn.sh` 一并移除。本机 CDN 节点只剩一个 `${CF_NODE_PREFIX}`（语义改为完整单节点名，默认 `🇺🇸AWS`，不追加序号），订阅与 `PROXY` 顺序固定为「直连（仅模式 3）→ CDN → 聚合节点」，模式 3 的直连/CDN 切换改为手动。
- **新增 CloudFront 共享核心与双证书链**：新增 `lib/cloudfront-mode.sh` 承载模式 2/3 的状态与事务、DNS/ACM/分发、源站证书、XHTTP/Nginx/UFW、订阅、运维与卸载，`profiles/cloudfront.sh`、`profiles/combined.sh` 收敛为薄 Profile（同名直连钩子，模式 2 返回空值）。ACM 固定 `us-east-1`，SAN 只含节点域名与订阅域名，复用前必须 `ISSUED` 且覆盖全部 alias；源站证书固定 Let's Encrypt（HTTP-01，`80` 端口 bootstrap Nginx），只覆盖源站域名，不再有自签兜底。分发沿用 cache-disabled 与 `AllViewerExceptHostHeader` 策略（转发全部 query/UA/Content-Type），Nginx 把 gRPC `Host` 固定重写为节点域名以匹配 Xray `xhttpSettings.host`。
- **新增源站头校验与安全边界变化（破坏性）**：健康探针、XHTTP 与订阅入口统一校验 `X-Easy-All-Origin-Key`（无/错头分别 `404`/`403`/`404`），`443` 默认 server 使用 `ssl_reject_handshake on` 拒绝未知 SNI，内部订阅 alias 对外一律 `404`。**模式 2/3 的源站 `443` 不再有 Cloudflare 回源白名单**：CloudFront 回源没有可枚举网段，源站对公网可达，安全完全依赖公信 TLS、默认拒绝 SNI、随机路径、源站头与 VLESS/Token 鉴权，这些措施不能防御网络层 DDoS、TLS/HTTP 资源耗尽或密钥泄露。模式 1 的 Cloudflare 回源白名单、Origin CA 与动态端口业务保持不变。
- **新增 985 GB CDN 入站计量熔断**：Xray 额外监听 `127.0.0.1:10085` 暴露 StatsService，只统计 `vless-xhttp-in` 入站字节（模式 3 的 Reality 流量不计入），用量原子写入 `/etc/easy_all/cdn-traffic-usage.json`（`0600`，含 `protection_offline`）。达到 985×10⁹ 字节后执行双层阻断：Nginx XHTTP 返回 `503`，Xray 清空 XHTTP 入站 `clients` 并加 `block` 路由后重启以终止既有 CDN 长连接；模式 3 的 Reality 直连短暂重连后继续可用，订阅仍可下载。额度按 UTC 自然月重算，`apply`、`apply-cloud`、`update-core` 都不能绕过阻断。待落实阻断（`blocked=true`、`enforced=false`）由所有入口共用的同一判定与受限安全恢复收敛：先应用 `503` 与受限运行时，必需验收通过才写 `enforced=true`、`protection_offline=false`；失败先持久化 `protection_offline` 再停止 Xray，绝不恢复开放配置后报成功。这是本机近似计量，不是 AWS 账单真源，不承诺零账单。
- **新增 `cdn-traffic-sync` 命令与 timer**：`easy_all cdn-traffic-sync` 成为计量与阻断的同步入口；systemd 单元 `easy_all-cdn-traffic-guard.service` / `easy_all-cdn-traffic-guard.timer`（`OnBootSec=15s`、`OnUnitActiveSec=15s`）每 15 秒执行一次，安装成功前必须确认 timer 处于 active。准入规则：`apply`/`apply-cloud`/`reality-target`/`renew-cert` 先做受限安全恢复（证书故障优先 `renew-cert`），`edit-sub` 走保持 `503` 的订阅修复分支，`update-core` 直接拒绝并指向 `cdn-traffic-sync`，`status`/`show`/`subscription` 只读，`uninstall` 不要求统计可读；定时重启在取得最终写锁后还会只读复核 `protection_offline=false` 且 `blocked=enforced`。
- **卸载与云端清理**：默认卸载仍保留 AWS/CloudFront 与 Cloudflare 资源，并在删除本机状态前打印分发 ID/域名、ACM ARN、业务 DNS 与 validation CNAME 清单；`uninstall --purge-cloud` 先校验归属（`Comment=easy_all-cloudfront-<节点域名>` + alias 匹配 + `easy_all=managed` 标记），禁用分发 → 等待 `Deployed` → 最新 ETag 删除 → 确认 ACM 无 `InUseBy` 后删除 → 只删精确匹配的 DNS；**ACM validation CNAME 默认保留**并提示手工核实。云清理任一步失败只告警并输出残留 ID，本机卸载继续执行。
- **测试与文档**：新增/重写 `test/test_cloudfront_render.sh` 与 `test/test_combined_render.sh`，删除 `test/test_cdn_render.sh`，`npm test` 同步；README、前置准备手册、AWS 指南、运维指南、技术参考、客户端指南按三模式重写。仓库 `bash -n` 与 `npm test` 全绿；Mihomo 真实内核 `-t` 与受控 AWS 云联调不在本次 CI 覆盖范围，交付时不把它们记为已验证。

## 4.3.2 更新说明（2026-11-08）

- **安装与自更新加固（`/tmp noexec` 兼容）**：
  - `bootstrap.sh` 与 `easy_all` 的 `unified_self_update` 针对加固系统（`/tmp` 分区挂载 `noexec` 标志）的执行阻断问题，统一改由 `bash` 解释器显式执行临时脚本，彻底杜绝 `EACCES (Permission denied)`。
- **Cloudflare 远端清理容错与防孤儿解析**：
  - `lib/cloudflare-purge.sh` 读取 ruleset 遇 403（Token 仅授权 DNS 与证书权限）安全降级为单次告警并跳过规则清理，保证已收集的全部 DNS 记录与 Origin CA 证书正常删除；
  - `lib/cloudflare-mode.sh:purge_cdn_dns` 修复错误抑制问题，在 API 查询失败或同名 A 记录多于 1 条时不猜测删除并显式标记失败，防止卸载误判已清理而误删本机状态导致孤儿解析；
  - `cf-dns.sh` 与 `cloudflare-purge.sh` 补齐 Cloudflare API DELETE 返回 HTTP 200/204 空响应体的支持。
- **协议配置安全性与校验强化**：
  - `combined` 模式在生成 Xray 配置前追加 `REALITY_SHORT_ID` 偶数位十六进制（`^([0-9a-fA-F]{2}){1,8}$`）严格校验，与 Reality 独立模式对齐，拦截非法 Short ID 导致 Xray 启动崩溃与坏订阅下发；
  - `lib/xhttp-runtime.sh:validate_reality_port_listening` 调整为未就绪时返回 1 融入 5 次重试探测循环，避免 Xray 异步绑定晚于 Nginx 就绪时提前 `die` 导致误报失败与回滚。
- **防火墙规则删除升级为规格删除**：
  - `lib/firewall.sh` 废弃基于 `ufw status numbered` 行号的逆序删除，全面升级为规则规格删除（`stale_ufw_rule_delete_specs` + `delete_stale_ufw_rules`），彻底根治 Fail2ban 并发插入规则导致的编号漂移与误删问题；
  - 确认并对齐 UFW `delete` 带 `comment` 规格语法的合规性。
- **系统初始化加固与边界防御**：
  - `scripts/debian-init.sh` 写入 IPv6 sysctl 参数前动态检测 `/proc/sys/net/ipv6`，彻底解决在内核开启 `ipv6.disable=1` 时 `sysctl -p` 致命崩溃中断初始化的隐患；
  - `debian-init.sh` 移除 root 初始用户的 `sudo` 前缀，适配精简系统镜像；加固后断言 `sshd -T` 并调用 `systemctl reload`；
  - `lib/platform.sh:ensure_swap` 使用 `df -Pk` 防范长设备名折行，当磁盘剩余空间小于 1.5GB 时安全跳过；
  - `lib/scheduled-maintenance.sh` 生成的 daily reboot 定时任务引入运行时写锁检测（`flock -n 8`），防止维护重启与运行时安装/更新并发冲突，转义 cron `%` 字符。
- **订阅与模板健壮性提升**：
  - `lib/mihomo-template.sh` 采用 `awk` 动态计算 `dns:` 段的一级子键缩进（自适应 2/4 空格），排除行尾注释与深层嵌套；
  - `lib/reality-subscription.js` 与 `lib/subscription-auth.sh` 动态端口避让 SSH 端口逻辑与 `profiles/reality.sh` 对齐；Nginx 订阅 server 块追加 `location / { return 404; }` 兜底；
  - `lib/globalping-cdn.sh` 请求头采用原子替换，防范并发子进程读取截断空文件导致 401。

## 4.3.1 更新说明（2026-11-08）

- **全仓文档与实现完全对齐**：
  - `README.md` 与 `docs/operations-guide.md` 常用运维命令速查表补全 `easy_all cleanup-partial`（清理安装中断残留）与 `easy_all purge-cloudflare`（远端 Cloudflare 资源独立清理）；
  - `docs/operations-guide.md` 明确标注 `reality-target` 仅适用于直连 Reality 与直连+CDN 模式；
  - `docs/client-guide.md` 补充针对不支持策略组的通用客户端之 Base64 订阅平铺节点顺序说明（直连 Reality（仅模式 3）→ 6 个 Cloudflare 优选 IP → 官方域名调度兜底 → 外部聚合节点）。

## 4.3.0 更新说明（2026-11-08）

- **模式重新编号**：安装菜单改为「1 直连 Reality / 2 纯 CDN / 3 直连+CDN」。新增 `profiles/cdn.sh`（`PROTOCOL=cdn`）承载纯 CDN 链路：只部署 Cloudflare XHTTP 回源（Nginx `443` → 本机 Xray XHTTP `127.0.0.1:10086`）与订阅，没有 Reality 入站、没有 `8443` 放行、没有直连域名与 Reality 密钥；原「直连+CDN兜底」改为模式 3，内部标识仍为 `PROTOCOL=combined`，存量安装无需迁移。
- **两种 CDN 模式都新增「CDN 域名官方调度兜底」**：订阅除 6 个 Globalping 优选 IP 节点外，新增一个连接橙云域名 `cf.<zone>` 的节点（节点名 `${前缀}官方`），不写死 IP，由 Cloudflare 官方 Anycast 调度决定边缘。Mihomo 侧新增 `CDN-FALLBACK`（`fallback`）组：先选 `CDN-AUTO` 测速组，只有 6 个优选 IP 全部不可用时才落到该域名节点；`PROXY` 顺序改为「直连节点（仅模式 3）→ 聚合节点 → `CDN-FALLBACK`」。域名节点与 `CDN-FALLBACK` 一并进入保留名清单与本机节点重名黑名单，聚合配置不能占用。Base64 订阅（无分组语义）把域名节点平铺在 6 个优选 IP 之后。
- **抽取两种 CDN 模式的共享编排层 `lib/cloudflare-mode.sh`**：把 `profiles/combined.sh` 里与模式无关的 Cloudflare Token/DNS/Origin CA、XHTTP 入站与 Nginx、UFW 回源白名单、订阅渲染、apply/install/edit-sub/renew/uninstall/status 全部迁入共享层，函数统一以 `cdn_` 前缀命名；Profile 只保留常量、状态字段表、安装交互与（模式 3）Reality 密钥、链接与伪装目标更新。`combined.sh` 由 1097 行降到约 210 行，模式 2 不再复制一份 CDN 实现。回源 UFW 注释统一为 `easy_all-cf-origin`；DNS 注释按模式记录（模式 3 仍为 `easy_all combined`，模式 2 为 `easy_all cdn`），跨模式重装复用内容一致的记录时会把 `easy_all` 注释迁移到当前模式，`uninstall --purge-cloud` 仍能按注释回收，不会留下孤儿 A 记录（第三方或无注释记录保持原状，不接管所有权）。
- **模式注册与运维路径同步**：`easy_all` 的菜单、`detect_installed_mode`、`profile_file`、`profile_script_for`、`apply-cloud` / `refresh-cdn-ips` / `renew-cert` 路由都接受 `cdn`；`reality-target` 仍只对 Reality 与直连+CDN 开放；`prepare_fresh_install` 的断点续装分支对 `cdn` 与 `combined` 都生效。`runtime.manifest` 登记新 Profile 与共享层。
- **测试**：新增 `test/test_cdn_render.sh`（纯 CDN 的端口/Xray 入站/UFW/DNS/分组/节点/重名/订阅产物/卸载清理/状态文案）并接入 `npm test`；`test_combined_render.sh` 跟进函数改名并断言 `CDN-FALLBACK` 组、官方域名节点、`PROXY` 顺序与保留名；`test_install_guard.sh`、`test_audit_fixes.sh`、`test_cli_e2e.mjs` 跟进模式注册、菜单编号与命令门禁文案。
- **文档**：README、前置准备手册、系统技术参考、运维指南、客户端指南按三模式与 `CDN-FALLBACK` 兜底重写；客户端指南删除「没有域名兜底」的旧描述。
- **已安装机器升级**（模式 3）：执行 `sudo easy_all self-update && sudo easy_all apply` 即可重新渲染订阅、拿到 `CDN-FALLBACK` 组与官方域名节点；不需要改 DNS、证书或防火墙。
- **修复 Reality 订阅更新回滚误删未修改的 A 记录（原 4.2.1 修复）**：4.2.0 的更新回滚把「本次新签了 Origin CA 证书」误算作「动过云端」，导致 `edit-sub` 把订阅域名从 A 改到 B、而 B 的 proxied A 记录本来就存在且完全匹配（`reality_cloudflare_ensure_proxied_a` 走 no-op）时，一旦后续步骤失败，回滚会按注释标记误删这条更新前就存在的记录（实测请求序列：`DELETE /certificates` → `GET /dns_records?name=B` → `DELETE /dns_records/<既有记录>`）。现按资源分别判定：证书继续单独吊销；只有 `CLOUDFLARE_RESOURCES_TOUCHED=1`（本次确实 PATCH/POST 过回源记录）或 `CLOUDFLARE_STRICT_TLS_TOUCHED=1`（写过 Strict TLS 规则）才进入清理；`reality_cloudflare_purge_managed_resources` 新增第 5 个参数 `delete_dns`（默认 `1`，`uninstall --purge-cloud`、首装回滚与成功路径清理上一域名的语义不变），更新回滚只在写过 DNS 时传 `1`，只写过规则时传 `0`（连 DNS 的只读 GET 一起跳过），因此不会再误删既有记录。
- **回归测试补齐（Reality 回滚）**：修正原先「只新签证书却期望 purge」的错误用例；新增「只新签证书 + 换域名 → 只吊销证书、零 DNS 请求」「只写 Strict TLS + 换域名 → 只按 ruleset 删规则、零 DNS 请求」两条走真实回滚与真实 purge、只桩最底层 API 的用例（后者用 `reality_cloudflare_ref` 真值构造匹配规则并断言规则 DELETE）；`cf_update_rollback` 桩记录第 5 个参数。
- **发布前审计修复**：修复纯 CDN 模式在 `set -u` 下未定义 `REALITY_TARGET` 时展开 `${REALITY_TARGET%%:*}` 导致 Linux（Bash ≥ 4.4）安装/更新必崩的问题；纯 CDN 现在不会再因环境残留 `DIRECT_DOMAIN`/`DIRECT_NODE_NAME` 生成灰云记录或写入不存在的直连节点；`uninstall --purge-cloud` 的 Zone 查询、DNS/证书删除与每一条记录删除都改为失败可降级（云端清理失败只告警，本机卸载、安全状态恢复与 UFW 回收照常执行，且 Zone 查询失败后不会拿空 Zone 继续调用 API）；`renew-cert` 在吊销旧证书前增加本机 TLS/SNI 验收并去掉多余的 Zone 查询；DNS 记录内容变化时允许接管注释以 `easy_all` 开头的记录（换机/跨模式重装），第三方记录仍拒绝覆盖；`test_cdn_render.sh` 的 EXIT trap 在 source 后恢复，不再泄漏临时目录。文档补充 Cloudflare SSL/TLS 必须为 Full / Full (strict) 与 gRPC 开关步骤，运维命令表补齐 `apply` / `apply-cloud` / `self-update`。复审又补：订阅验收改为按分组块结构校验 `CDN-FALLBACK`（避免被聚合节点名里的同名子串掩盖）且官方节点成员用 `@json` 等值比对（引号/反斜杠节点名不再误判）；纯 CDN 安装输入测试改用文件游标回答队列，并补齐两个负用例的具体错误断言与合法输入成功用例。
- **存量状态防护**：模式 3 的 `DIRECT_NODE_NAME` 在 4.3.0 之前允许等于 `CDN-FALLBACK` 或 `${CF_NODE_PREFIX}官方`，升级后会与本机兜底节点/分组重名。现在 `cdn_require_valid_owner_token`、`cdn_config_ready` 与订阅渲染入口都会在发布前拒绝这类状态并给出改名/重装提示；`load_state` 与 `uninstall` 仍只告警，不会卡死卸载。

验证：`test_install_guard` / `test_purge_cloudflare` / `test_combined_render` / `test_cdn_render` / `test_reality_render` / `test_mihomo_template_lint` / `test_audit_fixes` / `test_subscription_port.mjs` 全绿，全仓 `bash -n` 通过；新增断言（兜底组与节点顺序、Base64 顺序、跨模式 DNS 注释迁移与换机接管、订阅验收正负用例、存量重名拒绝、续期吊销前 TLS 验收、纯 CDN 环境残留隔离、Token 落盘 0600、安装参数校验、Reality 回滚精准删除）均做「破坏实现即变红」反向验证。P0（未定义 `REALITY_TARGET`）在开发机的 Bash 3.2 上无法复现，按 POSIX / Bash ≥ 4.4 的 `set -u` 语义修复，并用静态断言锁住不得再直接展开；`test_cli_e2e` 仍受开发机沙箱限制（macOS `TMPDIR` 不可写，`mktemp` 报 `Operation not permitted`，与 4.2.0 基线相同）无法本地运行，以 CI 为准；`fallback` 组嵌 `url-test` 组在真实 Mihomo 核心上的解析未在本地验证（本机无 mihomo 二进制），订阅渲染只做了结构与文本断言。

## 4.2.0 更新说明（2026-11-07）

- **直连 Reality 的 Cloudflare 层并入 `lib/cf-dns.sh`**：删除 `profiles/reality.sh` 中与之并行的 API 客户端、Zone 查询、Origin CA 签发与复用判定、回源白名单与 UFW 规则等 230 余行重复实现，改为共用共享层；UFW 端口（模式 1 = `8443`、模式 2 = `443`）、UFW 注释、回源证书路径与回源域名改为由各 Profile 以常量提供，`lib/cf-dns.sh` 不再自赋默认值。删除共享层中已无调用方的 `cloudflare_ensure_proxied_a` / `cloudflare_require_single_record`。所有权标记（UFW 注释、DNS 注释、Strict TLS `ref` 前缀）与状态文件字段均未变，存量安装的规则/记录/证书继续可识别。
- **Cloudflare 凭据与域名约束前置到输入阶段**：安装第 4 步与 `edit-sub` 的输入阶段就收集 API Token，并校验「回源域名属于当前 Token 可见的 active Zone，且必须是 Zone 下一级子域名」，不再等到第 8 步 `deploy_subscription_service` 才提示输入；根域名与多级子域也不会再装到一半才失败回滚。Zone 解析结果按域名在进程内缓存，部署阶段不再重复两次只读 `GET`。
- **失败回滚按「本次是否写过云端 + 域名是否变化」精确回收**：首装只在本次确实 `PATCH`/`POST` 过回源 A 记录时才跑全量 purge（记录已就绪的 no-op 仍只吊销新证书），不会误删上一次部署留下的标记资源；`edit-sub` / `renew-cert` 的回滚先吊销本进程新签的 Origin CA 证书（成功后清空其 ID，失败保留并提示 `purge-cloudflare`），仅当回滚恢复出的是 `link` 模式或不同域名时才清理新域名的 DNS 与 Strict TLS 规则，且只有本次确实写过 Strict TLS 时才把 ruleset id 交给清理——跨 Zone 改域名或 Token 缺规则读权限时，那次 `GET` 的 404/403 会中断清理、把新域名 A 记录留在云端。清理失败只告警并给出 `easy_all purge-cloudflare --domain <域名>` 补救命令。
- **修正 `edit-sub` 的回滚窗口**：`UPDATE_SUB_ROLLBACK_ON_EXIT=0` 提前到 `cloudflare_finalize_certificate_rotation` 之前（与模式 2、与 `renew-cert` 一致）。旧证书已被不可逆吊销后再回滚，会把已吊销的旧证书恢复回去，并（配合回滚里的证书吊销）把刚生效的新证书也删掉。
- **证书复用判定不再依赖 OpenSSL 3 专有选项**：`cloudflare_origin_certificate_is_current` 去掉 `-checkhost` 逐域名循环（SAN 集合与期望集合的精确相等已严格强于逐域名覆盖），SAN 提取改为「`-ext subjectAltName` 优先、为空则解析 `-text` 的 X509v3 段」；`combined_certificate_covers_node_domain` 在 `-checkhost` 不可用时同样退回 SAN 集合判定。macOS 的 LibreSSL 3.3.6 两个选项都没有，原先会把有效证书判成不可复用（开发机反复重签）并误报「证书未覆盖节点域名」。
- **修复 Google Play 下载卡住（三套 Mihomo 模板）**：`sniffer.sniff` 删除 `QUIC` 嗅探，只保留 `HTTP` 与 `TLS`。境外 UDP/443 由规则立即 `REJECT` 并要求应用回退 TCP，先嗅探 QUIC 会把这次拒绝拖到握手解析之后，Android 客户端表现为下载长期停在「等待中」。分流结果不变：国内 QUIC 仍由 `geoip-cn` 直连，服务端 `lib/network.sh` 的 UDP/443 `block` 路由仍在。
- **测试**：`test_mihomo_template_lint.sh` 新增「sniffer 段不得嗅探 QUIC、必须保留 TLS」断言（剔注释、大小写无关）；`test_reality_render.sh` 新增输入阶段顺序与根域名/多级子域拒绝、Zone 缓存复用与换域名重解析、真实证书的可复用判定与无 `-ext` 兜底、首装/更新两条回滚的证书吊销与 ID 清空、新域名清理、清理失败隔离；`test_combined_render.sh` 新增 Profile 常量与 `-checkhost` 兜底断言；`test_audit_fixes.sh` 跟进函数改名并锁住「签发成功记录新证书 ID」与「`edit-sub` 在 finalize 前关闭回滚」。文档同步：客户端指南、系统技术参考的嗅探与端口说明。
- **已安装机器升级**：模板仍走 `state.env` 里的快照，需要显式换一次模板才会重发订阅：

```bash
sudo easy_all self-update
sudo MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo.yaml easy_all apply
# 部署订阅模式会再要一次 Cloudflare API Token（仍不落盘）；非交互执行时改用：
# sudo CLOUDFLARE_API_TOKEN=... MIHOMO_TEMPLATE_SOURCE=/usr/local/lib/easy_all/templates/mihomo.yaml easy_all apply
```

验证：`test_install_guard` / `test_purge_cloudflare` / `test_combined_render` / `test_reality_render` / `test_mihomo_template_lint` / `test_audit_fixes` / `test_subscription_port.mjs` 全绿，新增断言均做「破坏实现即变红」反向验证（退回 `-checkhost` + 只吃 `-ext`、去掉 Zone 缓存、不清空新证书 ID、去掉 combined 的 SAN 兜底、把 QUIC 嗅探塞回模板、删掉回滚清理块、条件忽略域名变化等）；全仓 `bash -n` 与 `node --check` 通过。`test_cli_e2e` 在开发机沙箱（macOS `TMPDIR` 不可写，`mktemp` 报 `Operation not permitted`，基线同样失败）无法运行，以 CI 结果为准。

## 4.1.0 更新说明（2026-11-06）

- **直连 Reality 的订阅也支持聚合节点**：`deploy` 订阅不再只下发本机节点，改为与直连+CDN兜底共用同一份 `{"allowedTokens":{...},"nodes":[...]}` 配置；`nodes` 支持 `vless`（`reality/tcp` 或 `tls/xhttp`）与 `mieru`，`optional: true` 仅在订阅 URL 追加 `&node=all` 时下发。Mihomo 的 `PROXY` 分组顺序为本机 Reality 节点 → 聚合节点（名字原样使用）；`link` 模式仍只输出本机节点信息。
- **直接复用模式 2 的聚合实现**：校验、节点链接/节点块渲染与配置输入继续由 `lib/local-aggregation.sh` 统一提供，只把「校验后派生运行期变量」抽成 `apply_local_aggregation_config`，两种模式各自传入本机节点名（Reality 用 `NODE_NAME`）做重名校验；旧状态/旧环境只有 Token 字典时的折叠也收敛为 `subscription_config_from_tokens`（直连模式的两处调用点）。Reality 专属部分留在 Profile：动态端口占位符只替换本机节点、iOS 嗅探段剔除，以及 `base64.port-template` / `mihomo.port-template` 文件命名与 `reality-subscription.js` 渲染。删除因 `edit-sub` 入口切换而失去调用方的 `ensure_allowed_tokens` / `apply_allowed_tokens_params`。
- **订阅渲染器支持多链接**：`lib/reality-subscription.js` 的 Base64 分支从「单条 Reality 链接」放宽为「多行链接（`vless` / `mierus`），其中恰好一条带 `__EASY_ALL_REALITY_PORT__` 且必须是本机 Reality 节点」；数量、协议或占位符任一不符仍返回 `503`。YAML 分支继续只替换唯一一处端口占位符。
- **状态与命令**：`state.env` 新增 `SUBSCRIPTION_CONFIG`，旧状态里的 `ALLOWED_TOKENS` 读取时自动折叠为 `nodes: []`（已安装机器无需迁移，升级后执行 `sudo easy_all apply` 或 `edit-sub` 即可启用聚合订阅；`self-update` 本身不改写 Nginx 与订阅文件）；直连模式的 `edit-sub` 在部署订阅时改为编辑统一 JSON；`subscription` / `show` 会列出聚合节点，并在存在聚合节点时提示 `&node=all`。
- **回归测试**：新增 `test/test_reality_render.sh`，覆盖配置校验与重名拒绝、`PROXY` 顺序、默认/`node=all` 两份订阅产物、聚合节点端口不被替换、iOS 终止标记、Nginx `node=all` 接线、重发时清理残留、旧 `state.env`（只有 `ALLOWED_TOKENS`）折叠、损坏状态的可自救与失败关闭；其中走交互分支的用例一律显式 `</dev/null`，避免在开发者的终端里被 `[[ -t 0 ]]` 带进 `read` 提示而挂死（与 `test_combined_render.sh` 的 `update_subscription </dev/null` 同一约定）。`test/test_subscription_port.mjs` 增加多链接渲染与 `503` 拒绝用例；`test/test_combined_render.sh` 新增 `node=all` 提示断言，原有聚合断言继续覆盖共用代码。
- **修复状态配置损坏时无法自救（自查发现的死锁）**：`load_state` 对 `SUBSCRIPTION_CONFIG` 校验失败从 `die` 改为 `warn`（与直连+CDN兜底一致）——否则 `edit-sub` 与 `uninstall` 都先经过 `load_state`，用户被锁在唯一修复入口之外；强校验改在 `install_static_subscriptions` 入口（`reality_require_valid_subscription_config`），写订阅前仍硬失败并提示 `edit-sub`；交互式 `edit-sub` 遇到非法存量配置时重生成默认值（不把它当默认值反复踩坑），非交互命令（如 `apply`）则直接失败关闭——不会静默把聚合节点清成 `nodes: []` 并落盘。
- **补齐同类阻断点与副作用入口**：旧状态只有 `ALLOWED_TOKENS` 且该字典本身损坏时，折叠失败也只告警（不再 `die`），`uninstall` 照常可用、发布仍被强校验拦住；`renew-cert` 在动任何 Cloudflare 调用前先校验订阅配置，避免白签一张 Origin CA 证书再报无关错误。
- **提示与折叠语义收敛**：`subscription show` 只在确实存在 `optional: true` 节点时才提示 `&node=all`（两种模式一致，`lib/xhttp-runtime.sh` 同步修正）；`subscription_config_from_tokens` 固定产出 `nodes: []`，不再隐式读取 `AGGREGATION_NODES`。
- **文档**：README 模式 1 与交互向导、系统技术参考、客户端指南、运维指南同步聚合配置与 `PROXY` 分组说明。

验证：`test_install_guard` / `test_purge_cloudflare` / `test_combined_render` / `test_reality_render` / `test_mihomo_template_lint` / `test_audit_fixes` / `test_cli_e2e` / `test_subscription_port` 全套通过；新增断言均做「破坏实现即变红」的反向验证（含：恢复 `load_state` 的 `die`、去掉写订阅前强校验、恢复旧的 `node=all` 提示判断、恢复隐式 `AGGREGATION_NODES` 折叠）；全仓 `bash -n` 与 `node --check` 通过。

## 4.0.0 更新说明（2026-11-06）

- **移除纯 Cloudflare CDN 模式（原模式 2），只保留直连与直连+CDN兜底**：删除 `profiles/xhttp-cloudflare-streamup.sh` 及其在 `runtime.manifest`、`lib/profile-common.sh` 模式映射中的登记；安装菜单改为「1 直连 Reality / 2 直连+CDN兜底」，`profile_file`、`detect_installed_mode` 与命令路由同步收敛。不存在需要迁移的旧纯 CDN 部署，因此不保留兼容分支。
- **组合模式更名为「直连+CDN兜底」**：菜单、帮助、安装/卸载提示与全部文档改用新名称；内部标识（`PROTOCOL=combined`、`profiles/combined.sh`、状态版本）保持不变，已安装的机器不需要任何迁移。
- **清理共享运行时里只服务该模式的代码**：`lib/xhttp-runtime.sh` 删除 `write_xray_config`、`renew_certificate`、`refresh_runtime`、`rebuild_traffic_runtime`、`finish_xhttp_apply`、`remove_subscriptions`、`validate_loopback_port`、`active_subscription_link_domain`（直连+CDN兜底各自覆盖或不再需要）。
- **模式专属命令收敛**：`apply-cloud` 与 `refresh-cdn-ips` 现在只接受直连+CDN兜底模式（提示改为「仅适用于直连+CDN兜底模式」），`renew-cert` 只剩 Reality 与该模式两条路径。
- **文档同步为两模式口径**：README、前置准备手册、系统技术参考、运维指南、客户端指南去掉纯 CDN 模式的拓扑与准备项，直连+CDN兜底序号改为模式 2；仅纯 CDN 需要的 Cloudflare 权限行（Config Rules / Transform Rules / Zone Settings）随之删除，gRPC 开关要求归到该模式。
- **回归测试**：`test_audit_fixes.sh` 第 13/14 节改为两模式断言（菜单 2 → 直连+CDN兜底、3 不再可用、`renew-cert` 事务顺序改查该模式实现）；`test_install_guard.sh` 回滚静态网只看 Reality；`test_purge_cloudflare.sh` 状态改用 `combined`；`test_cli_e2e.mjs` 更新命令边界与帮助文案断言。

验证：`test_combined_render` / `test_mihomo_template_lint` / `test_install_guard` / `test_purge_cloudflare` / `test_audit_fixes` / `test_subscription_port.mjs` / `test_cli_e2e.mjs` 全套通过，`easy_all verify-release` 通过，全仓 `bash -n` 与 `node --check` 通过。

## 3.1.0 更新说明（2026-11-06）

- **直连+CDN兜底订阅拆成 `PROXY` / `CDN-AUTO` 两个分组**：`PROXY` 不再是「所有节点平铺 + 单一 `AUTO` 测速组」，而是一个 `select` 组，顺序固定为「本机直连 → 聚合 JSON 的 `nodes` → `CDN-AUTO`」——聚合节点的名字原样取自字典里的 `name`，不额外加前缀或后缀；`CDN-AUTO` 是 `url-test` 组，只放 Cloudflare 优选 1～6。聚合节点不再参与测速，由用户在 `PROXY` 里手动切换；`optional` 节点仍只在 `node=all` 时下发。
- **直连节点名可自定义，但拒绝保留组名**：安装时 `直连节点名` 仍可任意填写，只是 `AUTO` / `PROXY` / `GLOBAL` / `CDN-AUTO` / `DIRECT` / `REJECT` / `PASS` 会被拒绝——本机节点与分组同名会让整份 Mihomo 配置解析失败。聚合配置的保留字列表同步加入 `CDN-AUTO`。
- **缺少优选 IP 时直接报错而不是发出坏订阅**：优选 IP 缓存缺失或版本不兼容时，`CDN-AUTO` 会变成空测速组，客户端加载整份订阅失败；现在 `write_subscriptions` 在渲染分组阶段就以明确提示中断（`sudo easy_all refresh-cdn-ips`）。
- **文档与回归测试**：`technical-reference` 与 `client-guide` 的订阅说明改为新分组结构并清理历史残留；`test_combined_render.sh` 新增 `PROXY` 顺序断言、`CDN-AUTO` 不含直连/聚合节点、空优选池/空名称拒绝渲染、直连节点名保留字校验。

验证：`test_combined_render` / `test_mihomo_template_lint` / `test_install_guard` / `test_purge_cloudflare` / `test_audit_fixes` / `test_subscription_port.mjs` / `test_cli_e2e.mjs` 全套通过，新增断言均做「破坏实现即变红」的反向验证；`bash -n` 通过。

## 3.0.1 更新说明（2026-11-06）

- **修复模式 2 `easy_all renew-cert` 崩溃（3.0.0 回归）**：3.0.0 在 `profiles/xhttp-cloudflare-streamup.sh` 新增的 `renew_certificate()` 覆盖丢掉了 `require_root` 与 `collect_installed_state`，续签在 `set -u` 下以 `VLESS_CDN_DOMAIN: unbound variable` 立即中断；若环境里恰好带该变量，随后无锁的 `save_state` 会把空 UUID、路径、Token 与 Zone ID 写回 `state.env`。现删除该覆盖，恢复 `lib/xhttp-runtime.sh` 的实现。
- **`renew-cert` 事务化（模式 2 与模式 1）**：两条路径统一为「写锁 → 读状态 → 拍快照 → 签发 → `nginx -t` → 重载 → 校验 → 写状态 → 关闭回滚 → 吊销旧证书」，失败时回滚状态、证书文件与 Nginx 配置；模式 2 的回滚还会删除本次新建的 Origin CA 证书，避免账户里留下无引用的长期证书。
- **订阅更新回滚清理本次新建证书**：`rollback_subscription_update` 删除 `CLOUDFLARE_CREATED_ORIGIN_CERT_ID`（原实现只有一个恒为空的 `declare -F` 守卫，实现体随 Worker 一起删除），删除失败只告警并提示 `easy_all purge-cloudflare`。
- **`self-update` 与运行时任务共用写锁**：`register-command` 整体替换运行时目录前先取写锁，避免正在运行的安装或定时任务在新旧版本文件之间交错。
- **安装菜单不再接受已删除的模式编号**：`4` / `5` 现在直接提示「不支持的安装模式」，不再静默安装组合模式。
- **清理删除模式留下的死代码**：删除 `disable_ufw_ipv6`（Bunny 独占）、`cloudflare_client_candidates`（Worker 独占）、模式映射的悬挂注释与空 Provider 回滚钩子。
- **Zone 名匹配双向忽略大小写**：`cloudflare_lookup_parent_zone` 的 jq 比较对入参也应用 `ascii_downcase`。
- **回归测试**：`test/test_audit_fixes.sh` 新增第 13、14 节，覆盖模式编号拒绝与死代码不再存在、回滚证书清理、`renew-cert` 入口加载状态与事务顺序。

验证：`test_install_guard` / `test_purge_cloudflare` / `test_combined_render` / `test_mihomo_template_lint` / `test_audit_fixes` / `test_subscription_port` 六套全绿，关键修复均做「回退即变红」反向验证；`bash -n` 与 `node --check` 通过。

## 3.0.0 更新说明（2026-11-06）

- **删除 Bunny 模式，模式 4 改为模式 3**：移除 `profiles/ws-bunny.sh`、`lib/bunny-api.py`、`lib/bunny-runtime.sh`、`lib/lego-install.sh`、Bunny 文档与测试；菜单、`--assume-mode`、命令路由、卸载清理与文档统一为「1 Reality / 2 Cloudflare / 3 组合」。数字只用于菜单与清理参数，状态文件与 Profile 标识不变。
- **全仓库移除 Cloudflare Worker 订阅**：删除 `worker-src/`、`scripts/build-worker.mjs`、`lib/worker-config.sh`、`lib/worker-backup.sh` 及其测试；模式 2 的订阅改由本机 Nginx 在节点域名 `https://node.<zone>/subscribe` 下发（Cloudflare 代理 + token 鉴权 + UA 协商），不再需要额外订阅域名、Workers 编辑权限或 Worker 部署/退役/兜底逻辑；模式 1 只保留 `deploy` / `link` 两种订阅输出。
- **组合模式统一订阅配置**：安装与 `easy_all edit-sub` 改为编辑同一份 JSON `{"allowedTokens":{...},"nodes":[...]}`；`nodes` 支持 `vless`（`reality/tcp` 或 `tls/xhttp`）与 `mieru`，支持 `optional: true`（仅在订阅 URL 追加 `&node=all` 时下发），聚合节点默认进入 `AUTO` 自动测速组。订阅产物按默认 / `node=all` 生成两份，并新增 `templates/aggregation.example.json` 示例。
- **Cloudflare API Token 权限收敛**：模式 2 不再要求 `Account / Workers Scripts / Edit`；组合模式仍只需目标 Zone 的 DNS、证书、规则与 Zone Settings 权限。
- **破坏性变更**：2.x 的 Worker 订阅链接不再可用，升级后请运行 `easy_all edit-sub` / `easy_all apply` 并重新导入本机订阅链接；旧 Worker 脚本与自定义域名需手工删除，或先用旧版本清理。
- **修复 iOS 客户端拿不到标记为 `optional` 的聚合节点**：订阅格式协商的 Nginx map 只写了 `base64:0:1`，iOS（Shadowrocket 等 UA 命中 iOS，或链接带 `&os=ios`）加 `&node=all` 时组合键是 `base64:1:1`，会命中 `default` 被降级到不含 optional 节点的 `base64.txt`；现补齐该行，iOS 与非 iOS 的 Base64 请求都落到 `base64-all.txt`。
- **修复 XHTTP 聚合节点的 HTTP `Host` 头被绑在连接地址上**：`nodes` 里的 `host` 允许填 CDN 优选 IP，原逻辑把 IP 同时写进 `Host` 头，请求到达 Cloudflare 边缘会被拒（403 Direct IP Access Denied）；现 `Host` 头改为跟随 `sni`，与本机生成的 Cloudflare 节点（`server` 用 IP、`Host` 用域名）保持一致。
- **清理 Worker 下线后的遗留**：`profiles/reality.sh` 不再校验与传递只服务于 Worker 的 `CLOUDFLARE_ACCOUNT_ID`；`profiles/xhttp-cloudflare-streamup.sh` 删除与 `lib/xhttp-runtime.sh` 重复的 `show_subscription` 覆盖（该副本漏掉了 iOS 嗅探剔除提示，`easy_all subscription` 在模式 2 下少打印一行）。
- **移除所有一次性迁移/清理代码**：旧机器已全部重装，删除 `legacy_local_uninstall`（旧状态版本卸载）、`cleanup-partial --assume-mode` 与无 marker 的旧版残留分支、旧版 Fail2ban helper 迁移与 self-update 保留副本、2.0.0 状态缺字段兜底、旧版 `deny 22/tcp` 规则回收；`cleanup-partial` 现在只按安装进度标记工作，缺标记直接拒绝。`STATE_VERSION` 校验保留为状态格式守卫。
- **订阅配置输入与校验收敛**：`easy_all edit-sub` 粘贴的 JSON 内部含空行时不再提前截断输入（空行只在已凑成完整 JSON 时才作为结束信号）；`reality` 聚合节点的 `sid` 由「非空且不超过 16 字符」收紧为「2-16 位偶数长度十六进制」，与 Xray 的实际要求对齐。

## 2.5.2 更新说明（2026-11-05）

- **TCP 加速只保留 Skyline Speeder 并原生支持 arm64**：删除 BBR/BBRv3/XanMod 路径与状态迁移逻辑，全模式只由 Skyline Speeder（fq + skyline_cc）提供拥塞控制；TCP 调优只写入缓冲区/队列等参数，不再写入 `tcp_congestion_control`，也不再生成 `/etc/modules-load.d` 配置（调优文件改为 `/etc/sysctl.d/99-easy_all-tcp.conf`）；全模式 Xray 安装依据系统架构自适应选择 amd64 与 arm64 官方二进制包，清理 Profile 写死的 amd64 常量。
- **Bunny 模式卸载与 IPv4/IPv6 行为对齐**：补齐 Bunny 安装时的 `snapshot_ipv6_state` 与 `configure_ipv4_only`，并在卸载时执行 `restore_preinstall_ipv6`；Cloudflare Stream-up 首次安装失败回滚同样补上 `restore_preinstall_ipv6`，不再在删除状态目录前漏掉 IPv6 还原。
- **卸载与回滚不再回收前置初始化**：内核、Swap、系统依赖、时区/NTP、SSH 开机与 TCP/Skyline 调优属于前置初始化，`uninstall` 与 `cleanup-partial` 一律不拆卸（`uninstall_tcp_acceleration`、`restore_tcp_runtime` 等回退代码已删除），避免卸载时把仍在使用的内核与加速配置一并拆掉。
- **增强 `easy_all apply` TCP 参数刷新与开机产物自愈能力**：当 Skyline Speeder 运行时，`apply` 持续刷新 TCP 调优参数，并在重启启用单元后校验 `skyline_cc` 是否真的生效（失效则报错而非静默降级）；若 `easy_all-fq.service` 或 helper 脚本被误删，`apply` 自动检测并自愈重建；在所有 Profile 的 `apply` 流程中统一保证全局 IPv4-only 策略生效。
- **防止卸载时误开启原本已禁用的 IPv6 与快照防覆盖保护**：`snapshot_ipv6_state` 增加重入保护，避免续装或重复初始化时将已生成的 IPv4-only 配置误当作初始快照；记录运行态 `net.ipv6.conf.*.disable_ipv6` 键值，`restore_preinstall_ipv6` 在原系统无特定配置文件时优先回写原始运行值，避免将管理员原本通过系统配置禁用的 IPv6 强制置为 0。
- **常驻与安装内存优化**：全模式 Xray 服务单元注入 `GOMEMLIMIT=128MiB` 与 `GODEBUG=madvdontneed=1`，促使 Go 运行时更平滑 GC 并尽快向操作系统归还物理内存页（实际降幅随负载变化，未做基准测试）；Nginx 主配置自动收敛为单 Worker (`worker_processes 1;`)，消除多核 VPS 进程内存冗余；针对 arm64 架构 Skyline 源码编译，依据物理内存自动限制 `CARGO_BUILD_JOBS` 并发度（物理内存 < 2GB 时限制单线程），降低安装期峰值内存与小内存机器的 OOM 风险。
- **配置与安装容错增强**：`timedatectl` 设置时区与网络时间同步失败由中断降为告警，防止受限 VPS 环境因 timesyncd 瞬态状态中断安装；清理开机 helper 脚本的迁移残留路径与重复定义；上游 Skyline 卸载脚本异常时输出友好警告。
- **文档与平台说明精确化**：精确规范支持的发行版代号（Debian 12/13 [bookworm / trixie]、Ubuntu 22.04/24.04 LTS [jammy / noble]）；`scripts/debian-init.sh` 改为复用 `check_platform`，支持范围与 easy_all 一致（Debian 12/13、Ubuntu 22.04/24.04，amd64/arm64），平台校验提前到任何系统改动之前，不再在 TCP 调优步骤才以 amd64 限制退出；补充未配置 Swap 时自动创建 1GB 交换文件（`/swapfile`）的说明；修复 Bunny 准备指南中对 BBR 的过时描述。
- **卸载与回滚只精确回收业务端口与回源白名单**：全模式卸载与安装失败回滚一律只移除业务端口（443/8443）、动态端口 NAT 重定向与 CDN 回源白名单，保留 UFW 启用状态、默认拒绝策略、SSH 放行与 Fail2ban 配置，不再执行 `ufw disable`；修复 Fail2ban 存在单 IP 封禁时 UFW 放行探测函数误判 SSH 不可达的问题。
- **Fail2ban CIDR 助手脚本与运行时目录解耦**：CIDR 封禁助手从 `/usr/local/lib/easy_all` 迁移至系统路径 `/usr/local/sbin/fail2ban-ufw-cidr.sh` 并保持常驻，卸载与安装失败回滚不删除 Fail2ban 配置与 helper，避免常驻 SSH 封禁动作失效；升级与旧版本卸载时自动平滑迁移 action 配置与运行中服务。
- **主机前置初始化跳过提示与幂等增强**：检测到系统已具备激活的 UFW、Fail2ban 与 Swap 等初始化状态时，安装各 Profile 时明确提示「已完成初始化：已就绪的依赖、内核与 TCP 加速将跳过重复安装；IPv4-only、定时重启与 UFW/Fail2ban 仍会幂等校验」；旧版本状态卸载（`legacy_local_uninstall`）修复 `warn`/`success` 未定义崩溃问题并安全迁移旧 helper。
- **Reality 动态端口 NAT 目标自适应**：NAT 重定向规则目标端口自适应 inbound 实际监听端口，不再硬编码 443。
- **系统初始化脚本（`debian-init.sh`）支持分支与镜像参数**：支持通过 `EASY_ALL_BRANCH` 指定拉取分支，及 `EASY_ALL_PLATFORM_MODULE_URL` / `EASY_ALL_FIREWALL_MODULE_URL` 指定镜像源。
- **组合模式 `uninstall --purge-cloud` 补上 Origin CA 证书吊销**：按状态文件中的 `CLOUDFLARE_ORIGIN_CERT_ID` 调用 `DELETE /certificates/{id}`，与「清理节点 DNS 解析、Origin CA 证书」的文档承诺一致，不再遗留 15 年长效的孤儿回源证书；缺少 ID 时不发请求，吊销失败只告警并给出证书 ID，不中断本机清理。
- **核心升级后自动重写组合模式订阅**：组合模式补上 `refresh_runtime_subscription` 钩子，`easy_all update-core` 升级 Xray 后按新核心版本重写 Reality 的 `support-x25519mlkem768` 开关，无需再手动 `easy_all apply`。
- **加固：`CRON_REBOOT_MARKER` 为空时拒绝改写 root crontab，且先过滤成功再提交**：`configure_daily_reboot` 与 `remove_daily_reboot_schedule` 都先校验标记非空再动 crontab（`awk index($0, "")` 会把所有行过滤掉），`configure_daily_reboot` 也不再直接把过滤结果喂给 `crontab -`，避免过滤中途失败时写入截断内容；当前会调用该函数的 Profile 均定义了该常量，因此属防御性加固而非线上故障。
- **Bunny 回源池过滤 IPv6 网段**：`lib/bunny-api.py` 的 `edge_ips` 只保留 IPv4 网段，避免混入的 IPv6 CIDR 写入 `/etc/ufw/before.rules` 后让 `iptables-restore --test` 失败、中断安装与动态刷新。
- **细节对齐**：帮助与提示中的组合模式编号统一为 `4`（仍接受 `5`）；Globalping 定时器失败提示改为「每 3 小时」；删除 `write_xray_config` 中声明后未使用的 `mlkem` 局部变量。
- **修复组合模式安装与 `apply` 在 services 阶段崩溃**：根因是 `profiles/combined.sh` 在 2.5.0 移除 `CF_ORIGIN_DOMAIN` 时漏掉 `XHTTP_ORIGIN_DOMAIN` 别名，而共享的 `validate_protocol_runtime` 按该变量做本机 TLS/健康探活，`set -u` 下的 `unbound variable` 会在探活前直接中断安装。当时以「状态装载与首次安装输入两条路径都从 `CF_NODE_DOMAIN` 派生该别名」作为过渡方案（并加了对应回归用例）；该过渡现已由本段最后一条 bullet 统一到各模式都必须提供的 `VLESS_CDN_DOMAIN`，组合模式不再派生该别名。
- **修复组合模式安装失败后的回滚中断**：`cleanup_partial_install` 仍在展开 2.5.0 已删除的 `CERT_RELOAD_HOOK`（对应 reload helper 已不存在），`set -u` 下回滚在删除残留之前抛 `unbound variable`，服务文件、配置、状态目录与安装进度标记全部残留；现移除组合模式与 Cloudflare 模式对该死变量的引用，回滚可跑完并清掉本机残留。新增回归用例：断言回滚在 `set -u` 下退出码为 0、输出不含 unbound、受管残留全部删除。
- **收敛隐式 Profile 契约与死代码**：删除 `lib/xhttp-runtime.sh` 中从未被选中的 `write_nginx_config`、`xhttp_server_keepalive_referer` 与 `XHTTP_SERVER_KEEPALIVE_PADDING_LENGTH`（三者都引用 Profile 专属变量，是 2.5.0 后两次线上崩溃的同源隐患），并把 `validate_protocol_runtime` / `validate_subscription_runtime` 的本机探活域名统一到各 Profile 都必须提供的 `VLESS_CDN_DOMAIN`（Cloudflare 模式本就断言两者相等），组合模式因此不再派生 `XHTTP_ORIGIN_DOMAIN`；删除 `lib/cf-dns.sh` 中从未被调用的 `cloudflare_validate_zones`（它调用的 `cloudflare_validate_universal_hostname` 只有 Cloudflare Profile 才有）；`lib/worker-config.sh` 对缺失的 `DEFAULT_CLOUDFLARE_WORKER_NAME` 改为可操作报错。行为不变，只消除「共享库静默依赖 Profile 变量」这一类隐患。

源码版本标识为 `2.5.2`。

## 2.5.1 更新说明（2026-11-04）

- **清理 65533 收敛后遗留的死代码**：删除 `ensure_additional_ssh_port` 及其独占的 `ssh_effective_listeners_are_exclusive`、`ssh_only_managed_port_is_listening`、`ssh_port_is_listening` 与 `EASY_ALL_ADDITIONAL_SSH_PORT`；同步移除从未被调用的 `cloudflare_uint32_to_ipv4`、`ufw_ssh22_deny_is_first`、`remove_certificate_renewal_timer`、`generate_xhttp_path`、`normalize_websocket_path`、`collect_subscription_link_domain`，以及模式 2 私有的 `read_state_field`，共约 180 行；行为不变——历史 deny22 规则仍由 `remove_managed_ssh22_ufw_deny` 清理，证书定时器仍由 Bunny 卸载流程 disable/stop 并删除。
- **修正 Bunny 订阅输出测试断言**：对齐 2.3.0 起的「同一链接按客户端自动下发」单链接输出（该断言自 2.3.0 起一直失败，因为 `test:bunny` 不在 `npm test` 与 CI 主链路内）；本地缺少 `python3-jsonschema` 时跳过 schema 与云端同步阶段并提示安装方式，避免整轮测试报 ImportError。
- **补全与更正说明**：目录结构补上 `bootstrap.sh`、缺失的 `lib/` 模块、`worker-src/` 与 `scripts/`；更正 `tcp-tuning` 里针对 65533 的端口注释，并清理 `platform.sh` 中指向 `allow65533` 的过时注释；`lib/cf-dns.sh` 补上 `CLOUDFLARE_API_BASE` 默认值（两个调用方均已自行定义，仅作为库默认）。

源码版本标识为 `2.5.1`。

## 2.5.0 更新说明（2026-11-04）

- **安装全面恢复交互式终端模式**：废弃 `params.json` 单文件安装机制，恢复用户在控制台终端的交互式问答菜单安装方式（带默认值回车确认），彻底删除 `lib/params.sh` 与参数相关测试。
- **完全移除模式 4（Gcore CDN）**：移除 `profiles/xhttp-gcore.sh`、`lib/gcore-*.sh` 及相关测试与文档，CLI 不再提供模式 4 安装与 `purge-gcore` 命令。
- **简化与精简组合模式**：组合模式收敛为「直连 Reality + Cloudflare XHTTP」双入口；彻底移除冗余的 `CF_ORIGIN_DOMAIN`（回源域名），收敛为 3 域名架构（`DIRECT_DOMAIN`, `CF_NODE_DOMAIN`, `SUBSCRIPTION_DOMAIN`）。
- **模块解耦与代码复用**：模式 2（Cloudflare CDN）接入并复用 `lib/cf-dns.sh`，清理 230 多行重复代码；清除无用变量与死代码。
- **模式 1（Reality 直连）链路审计**：核验并测试了伪装目标校验、Xray 服务端 JSON 配置生成、VLESS URI、Mihomo YAML 节点片段、动态端口 NAT 规则与订阅渲染全流程。
- **测试与文档**：对齐并精简全套文档指南，保留纯用户视角的端到端测试套件，测试全绿通过。

源码版本标识为 `2.5.0`。

## 2.4.18 更新说明（2026-11-04）

- **模式 5 Gcore 边缘 WebSocket 验收等待由 5 分钟延长到 15 分钟**：Gcore 官方说明配置/证书传播约需 15 分钟，
  现场 5 分钟时仍 502、之后自行恢复。现复用 `GCORE_EDGE_PROPAGATION_ATTEMPTS × INTERVAL`（90 × 10 秒，与模式 4 一致），
  返回 101 即结束；每 60 秒打印真实已等待秒数与上限。超时仅告警，不使安装失败。
- **诊断探针改为完整 WebSocket 握手**：此前本机源站直连不带 `Upgrade` 头，Xray 必回 400，会误导排障；
  现带 `Upgrade` 头与合法 16 字节随机 `Sec-WebSocket-Key`，正常应为 101。
- **Gcore 源站 Trusted CA 补齐自签信任根**（模式 4/5 同步）：旧逻辑去掉叶子证书后缺最后一张自签根，
  现用系统根库做真实 OpenSSL 校验后再上传（`lib/gcore-origin-validation.sh`），失败向上传播；需 `apply-cloud` 重新上传。
- **CF xhttp padding 默认改为 `100-1000`**：Bettbox/Mihomo 随机发送 100–1000 字节，服务端固定 100 会拒绝请求；
  仍可用 `CLOUDFLARE_XHTTP_PADDING_BYTES` 覆盖。
- 验证：`test:combined` 等快速检查见交付说明；Gcore 边缘 101 已在现场确认。

源码版本标识为 `2.4.18`。

## 2.4.17 更新说明（2026-11-03）

- **边缘 WebSocket 验收等待加长并带进度**：证书签发后 Gcore 还要把证书/配置下发到各边缘节点，这期间
  访问会 502。等待从 150 秒延长到 5 分钟，每 60 秒打印「已等待 N 秒…第 x/60 次」。
- **验收失败时给出可区分原因的诊断**：直连本机源站（带 mTLS 客户端证书）拿一次 HTTP 码，并打印资源关键项
  （`sslEnabled`/`sslData`/`proxy_ssl_*`/`sni`）；`000` 说明源站 mTLS 侧有问题，有码则多半是边缘还没生效。
- **收尾不再误导**：边缘未通过验收时，安装结束会额外提示「节点暂时不可用，边缘生效后执行
  `sudo easy_all apply` 复验」。
- 测试：按用户要求不新增离线单测；仓库现有测试全绿。

源码版本标识为 `2.4.17`。

## 2.4.16 更新说明（2026-11-03）

- **重建证书后最终 PUT 带着已删除的证书 ID**（现场：`Invalid pk "320598" - object does not exist.`）：
  等待签发期间证书对象被重建（旧对象删除、新对象 320672 附加），但 `payload` 在函数开头就固化了旧
  `sslData`。现在等待结束后会把 payload 的 `sslData` 换成当前证书 ID（`gcore_refresh_edge_certificate_in_payload`），
  再执行最终 PUT。
- **新证书刚附加时状态接口 400 不再终止安装**：`issuing is not started yet` / `not attached` 按 `PENDING`
  继续轮询；其它状态查询失败仍终止并打印原始信息。
- 测试：按用户要求不新增离线单测；重建→最终 PUT 使用新 ID 的路径用 /tmp 离线桩核对，仓库现有测试全绿。

源码版本标识为 `2.4.16`。

## 2.4.15 更新说明（2026-11-03）

- **Gcore 侧挑战区不存在时自动创建**：Managed DNS 已启用但 Zones 为空时，`ns1.gcorelabs.net` 会对
  `_acme-challenge.<节点域名>` 返回 REFUSED，DNS-01 必然失败。委派完 Cloudflare 的 NS 记录后，现在会用
  `dig` 探测一次权威应答；没有应答就调用 `POST /dns/v2/zones` 建区（已存在时忽略），再探测一次并给出
  明确日志。建区失败只提示，不阻断安装。
- 说明：Gcore 正常会在开始签发时按需建区；这一步是为“账号不会自动建区/区被手工删掉”兜底。
- 测试：按用户要求不新增离线单测；已有 combined 渲染测试覆盖组合模式 DNS 流程。

源码版本标识为 `2.4.15`。

## 2.4.14 更新说明（2026-11-03）

- **DNS-01 选项会被静默忽略**：账号未启用 Managed DNS 时，`use_dns01_le_challenge` 即使随 PUT 提交也会被
  丢掉（HTTP 200），证书继续走 HTTP-01，于是稳定复现 502。现在附加/重签证书前会单独
  `PATCH /cdn/resources/{id}` 保存该选项并**回读校验**；没保存成功直接报错并提示先去 Gcore 控制台启用
  Managed DNS，不再让安装器在 HTTP-01 上反复消耗重试与证书额度。
- 委派后若本机有 `dig`，会探一次 `_acme-challenge.<节点域名>` 是否能从 `ns1.gcorelabs.net` 权威应答；
  未就绪只提示（挑战区按需创建，通常几分钟）。
- 说明：Managed DNS 列表在首次签发前是空的属正常现象，挑战区由 Gcore 按需创建。
- 测试：按用户要求不新增离线单测；已有的 combined 渲染测试覆盖资源 payload 中的选项字段。

源码版本标识为 `2.4.14`。

## 2.4.13 更新说明（2026-11-03）

- **force-retry 被拒后 PATCH 同一张证书不会重签**（现场：`PATCH /cdn/resources/{id}` 返回 2xx，但状态仍是
  `FAILED`、错误仍是历史 502）：证书对象的签发进程一旦结束，Gcore 不会再为它开新一轮。现在改为**重建证书
  对象**：`POST /cdn/sslData`（`easy_all-edge-<域名>-r<时间戳>`）→ `PATCH /cdn/resources/{id}` 附加新证书
  （旧证书随之脱离，不中断 HTTPS）→ 尽力删除旧对象，然后按新 ID 继续轮询。
- 边缘证书查找改为**名称前缀** `easy_all-edge-<域名>` 并取最新 ID；`purge-gcore` 也按前缀清理残留在账号里的
  旧对象。
- 测试：按用户要求不新增离线单测；“FAILED → force-retry 被拒 → 重建对象 → DONE”路径用 /tmp 离线桩核对。

源码版本标识为 `2.4.13`。

## 2.4.12 更新说明（2026-11-03）

- **签发进程结束后 force-retry 被拒**（现场：`The certificate issuance process has already been completed.`）：
  Gcore 的 force-retry 只适用于仍在进行的签发进程；进程结束后（失败也算“完成”）会返回 400。现在
  force-retry 被拒时自动改用官方 Issue 接口 `PATCH /cdn/resources/{id}`（body `{sslData, sslEnabled:true}`）
  重新请求一轮签发，再继续轮询状态。
- 说明：2.4.11 的“删除规则前先停用”没有出现在这次运行里（日志仍是直接 `DELETE` 被 400），重跑前请确认
  已拉到本版本。
- 测试：按用户要求不新增离线单测；force-retry 被拒→PATCH 重新签发→转 DONE 的路径用 /tmp 离线桩核对。

源码版本标识为 `2.4.12`。

## 2.4.11 更新说明（2026-11-03）

- **修复 Gcore 挑战规则删不掉（HTTP 400）**：Gcore 不允许删除仍处于 `active` 的规则，官方 Delete rule
  文档要求先把 `active` 置为 `false`。安装器现在先 `PUT /cdn/resources/{id}/rules/{rid}` 发
  `{rule, ruleType, active:false}`，再 `DELETE`；规则已是非 active 时直接删除。删除失败只告警，
  不影响 DNS-01 签发（证书已经完成时规则也不再阻断）。
- 说明：`force-retry` 返回 `The certificate issuance process has already been completed` 表示上一轮
  签发已完成（通常是 ACTIVE），安装器会继续轮询并判定成功，不需要人工处理。
- 测试：按用户要求不新增离线单测；停用→删除的顺序与“已停用直接删”用 /tmp 离线桩核对。

源码版本标识为 `2.4.11`。

## 2.4.10 更新说明（2026-11-03）

- **修正组合模式 Gcore 边缘证书的挑战方式（2.4.8 方向错误）**：Gcore 支持邮件明确指出，资源上若存在
  匹配 `/.well-known/acme-challenge` 的规则会导致证书签发报 502，必须删除该规则。现在改回 **DNS-01**：
  安装器用 Cloudflare API 把 `_acme-challenge.<Gcore 节点域名>` 以 NS 委派给 Gcore 权威 NS（优先读
  `/dns/v2/platform/info`，取不到用 `ns1.gcorelabs.net` / `ns2.gcdn.services`），并在签发前删除资源上
  匹配挑战路径的遗留规则；`use_dns01_le_challenge` 重新置为 true。
- 委派记录按目标 NS 幂等补齐，带 `easy_all combined` 注释；卸载/`purge-cloudflare` 只删注释匹配的记录，
  不动用户自建的委派。Zone 仍由 Cloudflare 管理，只委派 `_acme-challenge` 子域。
- `force-retry` 间隔从 60 秒放宽到 120 秒，给 Gcore 准备挑战区留时间。
- 文档：组合模式不再宣称“不委派任何 CDN 的 DNS”；补充 DNS-01 委派与“资源上不要保留挑战规则”。
- 测试：按用户要求不新增离线单测；规则删除、NS 委派幂等与 NS 来源回退用 /tmp 离线桩核对。

源码版本标识为 `2.4.10`。

## 2.4.9 更新说明（2026-11-03）

- **组合模式支持「续装」**：安装中断后再跑，同一模式检测到残留时优先询问「继续上次安装（保留已完成的
  配置、证书与云端资源）？[Y/n]」，默认续装：
  - 只停掉残留的 `easy_all-xray`/`nginx` 释放端口，不删 `/etc/easy_all`、证书、Nginx 配置与云端资源；
  - **不重新拍安装前快照**，保留真正的安装前状态，后续再失败仍回滚到安装前而不是半成品；
  - 从 packages 阶段重跑，靠幂等逻辑复用已完成项：DNS 按注释复用、Cloudflare Origin CA / acme 证书
    复用、Gcore 资源与 HTTP-01 规则幂等、UFW 规则按自身注释收敛。
- **身份也复用**：安装过程中把 UUID、XHTTP/WebSocket 路径、订阅 Token、Reality 密钥与 Origin CA 的
  ID/到期时间原子落到 `${STATE_DIR}/install-identity.json`（`0600`）；续装时用它覆盖参数预检新生成
  的值，已写出的 Xray/Nginx 配置与已下发订阅不会失效。中断早于身份落盘时按新生成值继续并告警。
- **Gcore 回源 UFW 按实际状态修复**：每次对全部官方回源网段幂等执行 `ufw allow`，不再把缓存文件当作
  “规则还在”的证明（上次回滚删过规则、文件仍在时，续装会补回来）。
- 只有上次安装前快照完整（`pre-install-complete`）时才允许续装；上次是别的模式、旧版本无进度标记、
  或非交互执行时，仍走原来的清理/明确失败路径。续装假设仍用同一份参数；换域名/Zone/账户时请选清理重装
  （进度标记不记录参数内容）。
- 文档：README 与运维指南说明“中断后重跑默认续装，需要彻底重来再选清理”。

源码版本标识为 `2.4.9`。

## 2.4.8 更新说明（2026-11-03）

- **修复 Gcore 边缘证书 HTTP-01 报 502**（现场：`A 502 error occurred when attempting to connect to the
  validation URL`）：Gcore 不会默认在边缘应答 `/.well-known/acme-challenge/`，必须先在 CDN 资源上创建
  来自系统模板「Let's Encrypt HTTP-01 challenge」的规则；否则挑战请求会回源，组合模式源站要求 mTLS，
  边缘只能拿到 502。现在 `gcore_ensure_edge_certificate_ready` 会幂等创建该规则（已有同名或同路径
  规则就复用），并用 `POST /cdn/resources/{id}/ssl/le/pre-validate` 探活挑战路径，通过后再重试签发；
  预检接口不可用或超时只告警，不阻断。
- 规范：只有**用户角度的端到端用例**才值得沉淀为测试；这次只在本地用离线桩核对规则创建/复用/启用、
  预检 400→201/5xx/403 与就绪门顺序，没有新增离线单测（既有组合测试只补了必要 stub）。
- 文档：技术参考与前置准备补充「组合模式必须先在资源上有 HTTP-01 规则，安装器自动创建」。

源码版本标识为 `2.4.8`。

## 2.4.7 更新说明（2026-11-03）

- **Gcore 等待阶段有进度输出**：新建资源激活 + 证书签发可能合计十几分钟，之前只有首行提示，之后长时间
  静默，容易被误认为卡死（也容易撞上 SSH/NAT 空闲断开）。现在：
  - 等待资源就绪时每约 60 秒打印一行：`等待 Gcore 边缘就绪（已等待 N 秒；资源=processed；<域名> 的
    CNAME=… ，期望 …）：第 x/y 次`；
  - 等待证书签发时每约 60 秒打印一行：`等待 Gcore 边缘证书签发（状态=PENDING，已等待 N 秒）：第 x/y 次`；
  - 超时/失败信息同样带上已等待秒数。
  定时输出只能减少“看起来卡死”并少量帮助保活，SSH 长连接仍建议按 README 配置 `ServerAliveInterval`。
- 测试：等待函数的既有用例继续通过（新增日志不影响断言）。
- 文档：常见问题「等待 Gcore 边缘就绪」一条补充进度输出说明。

源码版本标识为 `2.4.7`。

## 2.4.6 更新说明（2026-11-03）

- **修复 `purge-cloudflare` 扫描阶段卡死**（现场：`purge-cloudflare --all` 输入 Token 后长时间无输出、
  什么都没清理）：`cf_list` 用 `jq -c ... '$all + $batch'` 聚合分页结果时没有传 `-n`，jq 会去读 stdin；
  在交互终端上就一直等输入。现在改为 `jq -nc`，不再读标准输入。
- **分页防护**：新增“重复页检测”：接口若忽略 `page`、每页返回同一批数据，立即报错而不是无限翻页；
  另外每个列表接口最多扫描 `EASY_ALL_PURGE_MAX_PAGES`（默认 100）页，并会多取一页作为结束探测页，
  恰好整页的数据也能正常结束；超过上限时提示可用该环境变量调大。
- 测试：新增 `test/test_purge_cloudflare.sh`，用假 Cloudflare API 离线验证分页聚合、按注释删除、
  用户记录不误删，以及“接口不分页时快速失败”；已加入 `npm test`。
- 文档：常见问题补充“purge 命令需要输入 Token（不回显）”与本次卡死说明。

源码版本标识为 `2.4.6`。

## 2.4.5 更新说明（2026-11-03）

- **重试不再重复消耗 Let's Encrypt 额度**（现场：组合模式第 6 次安装被拒，
  `too many certificates (5) already issued for this exact set of identifiers in the last 168h`）：
  限额按精确标识符集合计 5 张/168 小时。根因是每次安装都执行 `acme.sh --issue --force`：回滚虽然
  会 `acme.sh --uninstall`，但它只删脚本与续期任务，`/root/.acme-combined.sh` 里的证书和账户配置
  其实还在，`--force` 让 acme.sh 每次重签。现在首次安装与 `apply-cloud` 不再传 `--force`：缓存
  证书未到续期时间时 acme.sh 返回 `RENEW_SKIP`（2），安装器复用缓存并重新安装证书；只有
  `renew-cert` 仍强制重签。
- **复用 acme.sh 时补回续期任务与所有权标记**：安装前快照在 acme.sh 安装之前拍摄，回滚会用快照
  覆盖 root crontab，把首次安装写入的 `acme.sh --cron` 一起删掉。复用已有 acme.sh 时会执行
  `acme.sh --install-cronjob`（幂等）补回续期任务，并补写所有权标记；`uninstall` 仍按标记执行
  `acme.sh --uninstall`。注意该命令只删脚本与续期任务，证书与账户缓存仍保留在
  `/root/.acme-combined.sh`，要彻底清理需另行删除该目录。
- **续期 Token 跟随当前参数**：`--issue` 走 `RENEW_SKIP` 时 `dns_cf` 不会执行，也就不会把新的
  Cloudflare Token 写回 acme.sh 的 `account.conf`，而定时续期只读该文件。现在每次安装/
  `apply-cloud` 都在值与已保存不同时，把当前 Token 原子写回续期配置（权限保持 `0600`）。
- **Gcore 边缘证书先等资源激活**（现场：HTTP-01 报 `The connection could not be established`）：
  新建的 Gcore CDN 资源约 15 分钟才会在所有边缘生效，期间申请证书必然失败。现在申请前先等资源
  `active` 且节点 CNAME 解析到账户 CNAME（最多 30 分钟；证书已激活的幂等重跑直接跳过），失败时
  最多强制重试 2 次（间隔 60 秒），全部失败才中止并给出可操作提示。
- 测试：新增“不重签/`RENEW_SKIP`/`renew` 强制”“回滚不卸载 acme.sh”“复用缓存时补写标记、补回
  续期任务、同步 Token”“资源就绪等待与超时”“失败重试上限”“ACTIVE 时跳过就绪等待”用例。
- 文档：常见问题补充 Let's Encrypt 限额、acme.sh 缓存生命周期、Gcore 资源激活等待与 Token 轮换说明。

源码版本标识为 `2.4.5`。

## 2.4.4 更新说明（2026-11-03）

- **修复组合模式 Gcore 边缘证书签发失败**（现场：`The _acme-challenge.<域名> is not delegated to
  the Gcore nameservers`）：组合模式的 Zone 留在 Cloudflare、没有把 `_acme-challenge` 委派给 Gcore，
  但 CDN 资源却启用了 DNS-01 挑战，签发必然失败。现在改回 Gcore 默认的 HTTP-01，通过
  `gcore.<zone>` 的灰云 CNAME 验证，与文档「组合模式不把域名委派给任何 CDN 的 DNS」一致。
- **边缘证书只覆盖 Gcore 节点域名**：此前还把订阅域名放进了 `secondaryHostnames`，而订阅域名是
  橙云 A 指向 VPS，Gcore 无法用 HTTP-01 验证它。订阅域名继续用本机 Cloudflare Origin CA 证书。
- **失败的边缘证书不再卡住重装**：证书进入 FAILED 后 Gcore 不会自行重签，旧流程重新安装会读回
  同一个失败状态并立即终止。现在先落新配置，再调用 `POST /cdn/sslData/{id}/force-retry` 重试一次，
  仍失败才终止，并在错误信息里给出 `purge-gcore` 清理提示。
- 测试：组合模式新增边缘证书策略（HTTP-01、仅节点域名）与 FAILED 证书强制重试用例。

源码版本标识为 `2.4.4`。

## 2.4.3 更新说明（2026-11-03）

- **参数预检不再联网**：`VPS_PUBLIC_IPV4` 与 `NODE_HOST` 留空时，预检只按“未提供”处理，不再在预检
  阶段探测公网 IP。此前有两个坑：`--check-params` 会依赖外网；全新 VPS 上 `curl` 还没安装，探测可能
  直接报“无法生成默认值”。探测改到安装阶段（依赖装好后），失败时提示在参数文件里手填。`NODE_HOST`
  因此从必填改为可选（留空＝安装阶段自动探测）。
- `VLESS_UUID`、`XHTTP_PATH`、`WEBSOCKET_PATH` 留空仍在预检阶段本地生成随机值，不受影响。
- 文档：Reality 示例的必填列表去掉 `NODE_HOST` 并注明留空行为；文档示例守卫不再替换空 IP，直接验证
  `""` 原样可用。README 增加完整参数字段说明表（50 个字段，按通用/Token/订阅/域名/节点名与路径/
  Bunny 分类），并加守卫：声明字段与 README 表格必须一一对应，缺漏或多写都会让 `npm test` 失败。

源码版本标识为 `2.4.3`。

## 2.4.2 更新说明（2026-11-03）

- **安装成功后自动删除参数文件**：参数文件里有 API Token，安装成功即删除并提示；`--check-params`
  与标准输入（`-`）不删；安装失败则保留，并在失败报告里注明，便于排查后自行删除。
- **不再强制 `600`**：权限较宽时只提示一次（说明成功后会自动删除），不再拒绝安装；符号链接仍拒绝。
- **文档精简**：快速安装/安装参数合并为“生成 → 校验 → 安装”三步，去掉 `chmod` 步骤；安装失败
  说明收成一段；示例只保留必填字段（其余留空用默认值）。
- **完整参数示例**：新增 `docs/params-examples.md`，按模式给出可直接复制修改的完整字典
  （组合、Reality 的 deploy/worker/link、Cloudflare、Gcore、Bunny，附配额片段），README 改为链接。
- 测试：新增“安装成功删除 / `--check-params` 保留”用例；权限用例改为提示而非拒绝。

源码版本标识为 `2.4.2`。

## 2.4.1 更新说明（2026-11-03）

修复 2.4.0 参数化安装的易用性问题（首次真实安装反馈）：

- **最简安装形式**：`easy_all <参数文件>` 直接安装（`bootstrap.sh` 会原样透传，所以
  `bash <(curl ...) params.json` 即可），文件名任意、以 `.json` 结尾；`<参数文件> --check-params`
  只校验。`install <文件>`、`install --params <文件>` 继续可用，`--check-params` 也支持放在文件前。
  同一行给两个参数文件会被拒绝。
- **模板不再输出半成品默认值**：`--print-params` 里，派生默认值（如 `node.${CF_ZONE}`）在依赖为空时
  原本会输出 `"node."`、`"cf."`，用户容易误以为已经填好，随后只补 Token 就会被 10 项链式报错拦住。
  现在模板先规范化再校验，不通过就留空；静态默认值（节点名、`EASY_ALL`、`skyline`、`500` 等）保持。
- **失败位置修正**：失败报告里的“失败位置/失败命令”此前指向参数层包装函数（`lib/params.sh:39`
  的 `return 1`），现在跳过 `log.sh`/`params.sh` 帧，指向真正调用 `die` 的业务代码。
- 测试：CLI e2e 覆盖位置参数的正/负路径（缺文件、两个文件）与 `--check-params` 只校验；
  `test_params.sh` 增加“派生默认值依赖为空时模板必须留空”的断言。

源码版本标识为 `2.4.1`。

## 2.4.0 更新说明（2026-11-03）

**破坏性变更**：`easy_all install` 不再交互，全部参数由一个 JSON 字典一次提供，安装前集中校验，
安装期零提问。旧版的菜单式安装已移除，升级后请先用 `--print-params` 生成新的参数文件。

- **新增 `lib/params.sh` 参数层**：`--params <文件|->` 安装、`--check-params <文件|->` 只校验、
  `--print-params --mode <模式>` 输出模板。字典里的键就是安装流程使用的变量名，解析后直接赋值，
  下游代码无需改名。
- **校验聚合**：逐字段记录错误（必填、类型、格式、跨字段、拼写错误、当前配置下不适用的字段），
  最后一次性报告；修正后重跑 `--check-params` 即可，不会出现"填到一半才发现前面错了"。
- **安装期禁止取值交互**：`prompt_value`/`prompt_secret` 在参数模式下直接报内部错误（漏字段会立刻
  暴露，而不是装到一半再问）；确认类交互改走专用的 `read_confirmation`。内核加载提示改为打印
  `sudo reboot`，不再等待输入。
- **安装失败诊断与清理确认**：失败退出前打印模式、失败阶段（`packages`/`tcp`/`inputs`/`core`/
  `services`/`cloud`/`subscription`/`state` 及中文说明）、`文件:行号`、失败命令、退出码、错误信息
  与开始时间；写入安装进度标记后失败会询问“是否清理本次安装的本机残留（已拍快照时回滚到
  安装前状态）？[Y/n]”（默认清理；输入 `n` 保留现场并给出 `cleanup-partial` 指引；没有终端时
  自动清理）。快照未完成时退化为只清理本机残留，不会误用不完整快照回滚。
- **参数预检先于一切系统修改**：校验前只补装 `jq` 与 `ca-certificates`；校验失败不触碰其他文件、
  UFW、内核或云端资源。
- **密钥处理**：Token 直接写在字典里；参数文件必须是普通文件、权限 `600`、不接受符号链接，
  也可用 `--params - --mode <模式>` 从标准输入读取而不落盘；摘要与错误信息一律脱敏。
- **失败即停**：未启用配额时必须显式提供 `ALLOWED_TOKENS`；`REBOOT_SCHEDULE_MODE=2` 必须给
  `REBOOT_HOUR`；组合/Bunny 的域名互异性、订阅域名与节点域名冲突等在预检阶段报错。
- **测试**：新增 `test/test_params.sh`（加载、类型、聚合错误、脱敏、权限、stdin、模板、跨 Profile
  的"安装输入无 prompt"静态守卫）；`test_combined_render.sh` 增加模板生成用例。

升级提示：旧版 `easy_all install`（菜单交互）已移除；升级后请用 `--print-params` 生成新的参数文件。
参数文件里的键就是安装流程使用的变量名（`CF_ZONE`、`ALLOWED_TOKENS`、`SUB_DOWNLOAD_NAME` 等），
`--check-params` 会在不改动本机的前提下一次性报出全部错误。

源码版本标识为 `2.4.0`。

## 2.3.5 更新说明（2026-11-03）

针对"组合模式一次装成功"的全链路复审（Gemini 4 Argon 对渲染/验收与安装编排两部分逐行过）：

- **Gcore 回源块在现代 nginx 上不再启用 HTTP/2**。该块只承载 WebSocket，而 `Upgrade` 只能在
  HTTP/1.1 上完成。nginx ≥ 1.25.1 的 `http2` 指令按 server 生效，所以现代分支对它不输出该指令
  （Cloudflare 块保留，gRPC 依赖）。**旧版 nginx（1.22/1.24）的 `listen ... http2` 是地址级联集**
  （`ngx_http.c:1343` 取或、`1440` 写回），无法按 SNI 关闭，因此旧版分支保持与其它块一致——不为一个
  无效隔离制造 `protocol options redefined` 警告。旧版上该入口的 HTTP 版本由 Gcore 边缘的 ALPN 决定。
- **本机回环探活补 `--noproxy '*'`**。`--resolve` 只改解析不改代理语义，机器上若有
  `http_proxy`/`https_proxy`，`combined_validate_cf_node_sni` 与 `validate_protocol_runtime`
  的探活会被转发给代理而失败并触发回滚（订阅验收早已带该参数，此处补齐）。
- **订阅 Token 首字符不再允许 `~`**。nginx `map` 把 `~` 开头的键当正则，`~a.c` 这类 token 会匹配到
  别的 token。`combined_token_valid`（单 Token 输入）与 `lib/subscription-auth.sh` 的
  `normalize_allowed_tokens`（JSON 字典输入）同步收紧为 `^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$`，
  中间仍可含 `~`。**兼容性**：老状态里若有首字符为 `~` 的 token，`status` 会告警、写配置前会被拒绝，
  执行 `sudo easy_all edit-sub` 换一个 token 即可（卸载不受影响）。
- **状态落盘后立即关闭本机回滚**。`save_state` 之后紧跟 `INSTALL_ROLLBACK_ON_EXIT=0`：之后是
  吊销旧证书（不可逆）与收尾步骤，此时回滚反而会留下"证书已吊销但配置回退"的残局；状态已落盘，
  失败也能用 `easy_all uninstall` 收拾。
- 首装失败提示补上 `purge-gcore` 入口（此前只提 `purge-cloudflare --all`）。

测试：第 22 组拆成现代/旧版两个分支（现代：Gcore 块无 http2 指令、Cloudflare 块保留、`proxy_http_version 1.1`
与 mTLS 在位；旧版：所有 443 的 `listen http2` 必须一致），第 26 组覆盖单 Token 与 JSON 字典两条输入的
首 `~` 拒绝、中间 `~` 放行，第 27 组逐元素断言 `--noproxy` 后紧跟 `*`。以上均做过红绿验证。

源码版本标识为 `2.3.5`。

## 2.3.4 更新说明（2026-11-03）

- 修复组合模式**首次安装**在同步 Gcore CDN 资源时崩溃：`combined_gcore_resource` 直接读
  `${SUBSCRIPTION_MODE}` 保存现场，而该变量只在 `load_state` 里赋值（`apply-cloud`/`edit-sub` 会先
  读状态，所以只有首次安装会踩到），`set -u` 下报 `SUBSCRIPTION_MODE: unbound variable` 并触发回滚。
  现在改为"存在才保存、结束后原样恢复"（原本未定义就还原成未定义），失败分支同样还原
  `VLESS_CDN_DOMAIN`，不再让它滞留在 Gcore 节点域名上。
- 测试：新增"未定义/已定义/失败"三种情形下 `combined_gcore_resource` 的变量保存与还原断言；
  红测恢复旧写法即报 `unbound variable`。

源码版本标识为 `2.3.4`。

## 2.3.3 更新说明（2026-11-03）

- 修复组合模式安装到写 Nginx 配置时崩溃：四个 `0.0.0.0:443` 的 server 块里有三个带套接字参数
  （`backlog=4096` / `so_keepalive`），nginx 对同一 `addr:port` 上"两条 listen 都带套接字参数"直接报
  `duplicate listen options`——与参数值是否相同无关（`src/http/ngx_http.c:1351`）。现在套接字参数只保留
  在首块，其余三块为裸 `listen 443 ssl [http2];`，`default_server` 仍只留在首块。
- 组合模式支持**多用户 Token 字典**：安装提示与 `easy_all edit-sub` 都接受
  `{"user1":"token1","user2":"token2"}`；字典随状态持久化，Nginx 鉴权 map 会为每个 token 生成条目，
  `show-sub` 也按用户逐条输出。单个 Token 的输入方式保持不变（自动包装为 `{"owner": ...}`）；
  非交互可用 `ALLOWED_TOKENS='{"user1":"token1"}'` 直接注入。`OWNER_TOKEN` 继续表示字典中的第一个 token。
- 多用户字典的交互输入只裁首尾空白：JSON 内部空白原样交给校验，避免 `{"user 1":…,"user1":…}`
  被压成同名键而静默合并用户（非法用户名会按原样被拒绝，原字典不变）。
- 测试：新增"套接字参数只能出现在一条 443 listen 上"、"多用户字典持久化 + Nginx map 覆盖每个 token"、
  "含空格用户名被拒绝且字典不变"、"格式化 JSON 仍可接受"四组断言。

源码版本标识为 `2.3.3`。

## 2.3.2 更新说明（2026-11-03）

- 组合模式安装阶段统一校验订阅 Token：无论来自 `OWNER_TOKEN` 环境变量、交互确认还是自动生成，
  都会在**写入任何云端资源之前**按 8-128 位 URL 安全字符校验，非法值立即失败；此前非交互安装和
  "回车接受默认值"都会绕过校验，含引号/分号的 Token 会一路跑到写 Nginx 订阅映射时才炸。
  状态文件加载（`load_state`）对历史非法值只告警（否则 `edit-sub` 与 `uninstall` 都进不去），
  真正写 Nginx 配置/订阅前的强制拦截在 `combined_require_valid_owner_token`（`write_nginx_config`、
  定时刷新 CDN 优选 IP、证书续签、修改 Reality 目标四个入口都会先校验），因此可用 `edit-sub`
  换成合法 Token 后再落盘。
- 组合模式的 Token 输入模型统一：安装提示与 `easy_all edit-sub` 都接受 8-128 位字符串；
  单用户 JSON（如 `{"alice":"..."}`）也可接受（组合模式只存一个 Token，用户名会按 `owner` 记录并提示）；
  多用户字典改为**明确拒绝**，不再静默截断成第一个用户。
- 订阅响应补 `Vary: User-Agent`（Nginx 两个内部订阅 location 与 Reality 的 Worker）：同一 URL 现在按
  客户端下发 YAML 或 Base64，缺 `Vary` 时中间缓存可能串格式。
- 文档同步：安装引导、`README.md`、`docs/client-guide.md`、`docs/operations-guide.md`、
  `docs/technical-reference.md` 改为"一条订阅链接按客户端自动下发，`flag=` 仅作强制覆盖"，
  并说明经典模板自 2.3.1 起为 MRS 规则集、不再加载 geodata。
- 测试：组合模式新增 17-19 组断言（安装入口确实调用校验、非法环境变量被拒、状态文件非法 Token 被拒、
  纯字符串/单用户 JSON 接受、多用户字典拒绝且不改动现有 Token）。

源码版本标识为 `2.3.2`。

## 2.3.1 更新说明（2026-11-03）

- 可选模板 `mihomo-classic.yaml` 全部改为 MRS 规则集：删除 `geodata-mode` / `geodata-loader` /
  `geo-auto-update` / `geox-url`（不再下载并常驻 `geosite.dat`、`geoip.dat`），把 `GEOSITE` / `GEOIP`
  规则与 `geosite:` / `geoip:` 的 DNS 引用改为 14 个 `format: mrs` 的 rule-provider。
  客户端内存与磁盘占用随之下降；代价是该模板要求内核支持 `format: mrs`（mihomo 1.18+）。
  转换时保留了 `no-resolve` 语义（含逻辑规则里的 `AND,...(RULE-SET,geoip-cn,no-resolve)`），避免多出 DNS 解析。
- 核对 `nameserver-policy` 的写法并加了防误改断言：按 mihomo `config/config.go:parseNameServerPolicy`，
  键含逗号时只识别**第一个**前缀，并把该前缀套用到逗号分隔的每一段。因此既有写法
  `'rule-set:private-fallback,geosite-private'` 本来就正确；若给每段都加前缀，反而会得到
  `rule-set:rule-set:geosite-private` 这类永不匹配的键。模板保持原写法，测试新增"首段须带前缀、
  后续段须不带前缀"的断言。
- 新增 `test/test_mihomo_template_lint.sh`（已纳入 `npm test`）：校验三个模板不再依赖 geodata/.dat、
  所有 http 规则集必须是 mrs、不得残留 `geosite:`/`geoip:` 引用、`rule-set` 引用不得悬空、
  `nameserver-policy` 首段须带前缀且逗号后各段不得重复前缀，且这些逗号段本身也必须是已定义的
  rule-set；provider 属性行允许行尾注释（先剔除注释再判定 `type` / `format`）。

源码版本标识为 `2.3.1`。

## 2.3.0 更新说明（2026-11-03）

- 修复组合模式首次安装在订阅阶段崩溃：首次安装不经过 `load_state`，`ALLOWED_TOKENS` 从未初始化，
  `write_subscription_token_map` 在 `set -u` 下报
  `lib/subscription-auth.sh: line 154: ALLOWED_TOKENS: unbound variable` 并触发回滚。
  现由 `combined_sync_allowed_tokens` 从 `OWNER_TOKEN` 统一派生 `{owner: <token>}`，首次安装、
  `load_state`、`easy_all edit-sub` 三处共用同一入口。
- 订阅 Token 字典缺失时改为可操作提示（"请执行 sudo easy_all edit-sub 重新配置订阅 Token，或重新安装"），
  不再抛出裸的 `unbound variable`。
- 证书 reload 钩子在 nginx 未启动时直接返回：首次安装期间 nginx 尚未启动，此前会先打印
  `nginx.service is not active, cannot reload.` 再走 `restart`，既制造"reload 失败"的误解，
  又可能让配置尚未写全的 nginx 提前带着默认站点上线。现在只做停机检查，启动仍由安装流程负责。
- 测试加固：组合模式新增 reload 钩子、Token 派生、Token 缺失提示三组回归断言；缺少对应修复时
  分别转红（Token 缺失用例直接复现现场报文）。
- 订阅按客户端自动下发格式：收到订阅请求时按 `User-Agent` 判断——Clash/mihomo/Stash/FlClash/Verge
  等内核类客户端返回 Mihomo YAML，Shadowrocket/v2rayN/v2rayNG/NekoBox 等 URL 类客户端返回 Base64（v2ray 链接）。
  客户端只需配置一条订阅链接，不必再手工加 `&flag=clash`；需要强制时可加 `&flag=`，YAML 侧接受
  `clash` / `mihomo` / `meta` / `stash` / `yaml`，Base64 侧接受 `base64` / `v2ray` / `uri` / `shadowrocket`，
  Nginx 与 Reality 的 Cloudflare Worker 入口对这套别名完全一致。
- 识别范围覆盖 Bettbox（默认 UA 为 `FlClash/ClashMetaForAndroid/<版本>.Bettbox`，归入 YAML 分支）；Reality 的
  Cloudflare Worker 入口同步对齐：新增 `yaml` 别名，UA 判定补上 flclash / verge / bettbox。
- 组合模式首次安装支持自定义订阅 Token：默认值仍是自动生成的那个，直接回车即接受；输入不合法会提示并重试，
  三次失败后沿用自动生成值。非交互安装（stdin 不是终端）不追问，按 `OWNER_TOKEN` 环境变量或自动生成值处理。
- `show-sub` / 安装完成后的订阅输出改为只给一条链接，并附客户端识别说明与强制格式用法。

源码版本标识为 `2.3.0`。

## 2.2.2 更新说明（2026-11-03）

- 修复组合模式首次安装必然崩溃：`profiles/combined.sh` 从未定义 `XRAY_XHTTP_LOOPBACK_PORT`，而
  `write_xray_config` 与 `write_nginx_config` 都直接引用它，`set -u` 下会崩在写配置阶段
  （现场表现为签发 Gcore 回源证书后 `line 319: XRAY_XHTTP_LOOPBACK_PORT: unbound variable` 并触发回滚）。
  该缺陷自 2.1.x 起存在；回归测试此前自行补齐该变量，掩盖了问题。
- 该端口固定使用 `10086`（WebSocket 回环为 `10087`、Reality 为 `8443`，互不冲突），不接受环境覆盖：
  组合模式尚未提供该端口的校验与状态持久化，静默接受覆盖会造成"安装用 A、之后 `apply` 变回默认"的不一致。
- 安装端口守卫收紧：只有"仅存在 Debian 默认站点、且请求端口确实被 nginx 监听"时才询问是否停止 nginx。
  端口空闲时不再误报"端口被 nginx 占用"；被其它进程占用或占用者无法辨认时，交给端口守卫报告真实情况，
  不再栽给 nginx。
- 回滚时的 TCP 运行参数恢复改为逐项应用：此前用 `sysctl -p` 一次应用，单个内核不支持或只读的键会让整批
  恢复报"恢复安装前 TCP 运行参数失败，请检查 /etc/easy_all/backups/pre-install-tcp-runtime.conf"，而该文件
  紧接着就会被回滚删除。现在逐项恢复并只为失败项告警，其余参数照常还原。
- 测试加固：组合模式渲染测试不再替产品代码补齐端口变量，并在 source 前清除宿主同名环境变量；
  `test_install_guard.sh` 增加空闲 / 其它进程占用 / 占用者未知 / nginx 占用四态断言。

源码版本标识为 `2.2.2`。

## 2.2.1 更新说明（2026-11-03）

- `easy_all cleanup-partial --assume-mode` 现在接受用户最容易输入的写法：菜单序号 `1`～`5`、
  内部模式名（`reality`/`cloudflare-streamup`/`bunny-ws`/`gcore`/`combined`）以及 `直连`/`组合`/`cf`/`bunny`
  等别名；非法值会报错并列出可用写法，不再只认内部名。
- 修复旧版本残留（没有安装进度标记）时的交互死路：此前先问"先清理残留再继续安装？"、用户答 y 之后才
  发现"无法判断残留属于哪个模式"并退出。现在直接询问"若残留属于本次选择的 <模式>，输入 y 按该模式清理；
  否则回车退出后指定模式"，回车即取消，只有显式 `y` 才按当前模式清理；非交互安装仍直接拒绝并给出可用写法。
- 文档：运维指南"旧版本安装中断"一条补充序号/内部名/中文名三种写法。
- 测试隔离：CLI 用例不再继承宿主 `FORCE=1`，也不再把 `policy-rc.d`、`/var/lib/easy_all` 写锁与事务目录
  指向真实路径；新增用例按 root/非 root 断言真实拒绝点。

源码版本标识为 `2.2.1`。

## 2.2.0 更新说明（2026-11-03）

- 新增 `easy_all cleanup-partial [--assume-mode <模式>]`：清理上次中断安装留下的本机残留（未安装状态使用，
  不改动 Cloudflare/Gcore/Bunny 云端资源）。安装器现在写入安装进度标记
  （`/var/lib/easy_all/install-progress.env`），重跑 `install` 时按标记识别残留并交互清理；旧版本没有标记的
  残留需用 `--assume-mode` 显式指定模式。
- 安装更抗中断：nginx 改为单独安装，并在那次 `apt` 调用内用 `policy-rc.d` 抑制包脚本自启（事务化、锁感知、
  内容校验，失败自动重试），装完立即恢复；端口守卫区分"本次安装残留"与"第三方占用"并给出可执行指引，
  不再把自身残留误报成"仅支持专用 VPS"。
- 组合模式补首次安装回滚（`rollback_fresh_install`）：失败或中断时恢复本机服务、UFW、crontab 与 TCP 配置，
  云端已创建资源按设计保留并提示 `purge-cloudflare` / `purge-gcore`。
- 修复组合模式 Cloudflare 节点域名与回源 SNI/证书脱节：Origin CA 证书 SAN 与 Nginx `server_name` 同时覆盖
  节点域名，`install` / `apply-cloud` 增加本机 SNI 验收；`status` 显示证书是否覆盖节点域名。
- 修复组合模式 `edit-sub`：新 Token 立即生效（此前 Nginx 鉴权 map 仍使用旧值）；Token 输入统一走
  `normalize_allowed_tokens`，空 Token 不再可能通过鉴权；订阅更新、`apply-cloud` 与 `renew-cert` 纳入事务，
  可捕获失败会同时回滚证书、配置与状态，旧证书只在新状态落盘后才吊销。
- 修复 `remove_daily_reboot_schedule` 在缺少 `CRON_REBOOT_MARKER` 的 Profile（Bunny）下可能清空 root crontab。
- 写锁文件移至 `/var/lib/easy_all/runtime-write.lock`（不再随状态目录被清理删除），所有安装、卸载与清理入口
  统一持锁。
- 文档：建议在 `tmux`/`screen` 中执行安装；补充中断恢复、`TCP xx 已被占用`、旧版本无标记残留的排障步骤；
  组合模式升级后**必须执行一次 `sudo easy_all apply-cloud`**（重签含节点域名的 Origin CA 证书）。

已知限制：`SIGKILL`/OOM 不会回滚（仅 `die`/`SIGINT`/`SIGTERM`/`SIGHUP` 会），可执行 `easy_all status` 检查
鉴权或证书是否与状态不一致，并按提示运行 `apply` 或 `apply-cloud` 恢复。

源码版本标识为 `2.2.0`。

## 2.1.1 更新说明（2026-11-03）

- 修复安装与清理命令的交互输入：命令行编辑改用 bash `read -e`（readline），方向键与 Ctrl-U/Ctrl-A/E
  不再以 `^[[D`、`^U` 之类的字面文本进入输入；隐藏输入的 Token 提示额外剥离 ANSI 转义与控制字符，
  误按方向键不会污染凭据。
- 覆盖入口模式选择、所有 `prompt_value`/`prompt_secret`（订阅、配额、Worker、Bunny、Gcore、证书与
  重启提示）、`purge-gcore` / `purge-cloudflare` 的范围与确认提示，以及独立的 `scripts/debian-init.sh`。
- 非交互（管道）输入行为不变；`read -e` 只在 stdin 为终端时启用 readline。

源码版本标识为 `2.1.1`。

## 2.1.0 更新说明（2026-11-03）

- 新增 `easy_all purge-gcore` 与 `easy_all purge-cloudflare`：按所有权清理 easy_all 创建的
  Gcore CDN / Cloudflare 资源。两者不依赖本机安装状态，支持 `--domain <域名>`、`--all` 与
  `--yes`，删除前列出清单并要求确认，失败会计数并以非零退出。
- Gcore 识别：CDN Resource 按 cname 精确匹配；Origin Group、边缘证书、客户端证书、Trusted CA
  按 `easy_all-…` 固定命名匹配，或由命中资源关联带出。`--domain` 传节点域名即可精确清理一次安装；
  CDN Resource 已删除时需同时传源站域名或使用 `--all`，命令会给出提示。
- Cloudflare 识别：DNS 记录按 `easy_all` 注释、Worker 按 `easyall` 名称（或绑定到输入域名）、
  规则按 `easy_all_` ref 且表达式涉及待清理域名、ruleset 名称 `easy_all` 且清空后删除、
  Origin CA 要求全部 hostname 属于 easy_all 记录或输入域名。`--all` 只按名称清理 Worker，
  不会按域名反查用户自己的 Worker；仍绑定范围外域名的 Worker 会被保留并提示复核。
- 两个命令都不删除 Zone、Gcore Managed DNS Zone 和 DNS 记录，也不删除 Bunny 模式创建的无注释
  DNS 记录。Zone 内 easy_all DNS 记录已删除时，Cloudflare 规则与证书需要传完整主机名才能识别。
- `bootstrap.sh` 支持透传命令参数，未安装的机器可直接执行
  `bash <(curl ...) purge-cloudflare --domain example.com`。
- 两个清理脚本启动时检查 `curl`/`jq`、检测本机已有 easy_all 安装并提示；`--help` 输出到 stdout。
- 文档：新增清理章节与命令表；补齐 Gcore（模式 4）与组合模式的差异、`--domain` 语义说明。
- 修复：`purge-cloudflare --all` 在 Worker 自定义域名没有普通 DNS 记录时会误判为范围外并中断，
  现按 `easyall` 名称选择 Worker 并解除其域名绑定；Gcore 域名匹配改为精确/固定格式匹配，
  避免子串误伤同账户其他站点。

源码版本标识为 `2.1.0`。

## 2.0.1 更新说明（2026-11-03）

- 组合模式安装时可自定义 Mihomo 下载文件名（默认 `EASYALL`）与三类节点名（默认 `🇺🇸直连`、
  `🇺🇸CF1`～`🇺🇸CF6`、`🇺🇸GCore`）。Mihomo 代理与分组名统一按 JSON 转义，含引号或反斜杠的
  名称不再产生非法 YAML；直连、Gcore 与 Cloudflare 节点名做互斥校验，避免客户端因重名拒绝加载。
  读取 2.0.0 的组合模式状态时回退到当时的固定节点名，避免 `apply` 静默改名。
- 组合模式在输入阶段调用 Globalping `/limits` 校验 Token；对 Reality 伪装目标执行带 SNI 的
  TLS 1.3 握手与 ASN 提示，探测失败会输出 `xray tls ping` 诊断。
- `easy_all reality-target`（组合模式）先规范化域名与端口，目标未变化时直接返回；改写前备份
  运行时配置，重启或验收失败自动恢复旧配置并重启，成功后重发订阅。
- 组合模式安装顺序调整为「先下载核心并验收 Reality 目标，再写 DNS 与签发证书」，目标无效时
  不会遗留 Cloudflare 记录或消耗 Let's Encrypt 配额。
- Reality 目标校验与验收逻辑抽到 `lib/reality-target.sh`，Reality 与组合模式共用。
- 文档：组合模式补充节点名/下载文件名说明与互斥要求。

源码版本标识为 `2.0.1`。

## 2.0.0 更新说明（2026-11-03）

- 新增菜单 `5`「组合」模式：一次安装同时提供三个入口——直连 VLESS Reality（VPS `8443`）、
  Cloudflare XHTTP `stream-up`（6 个优选 IPv4）、Gcore VLESS WS/TLS（单个域名节点）。
- 组合模式只使用一个 Cloudflare Zone 的六个子域名，`443` 只对 Cloudflare 与 Gcore 官方回源网段
  开放，订阅由 Nginx 直接提供（单 owner Token），不启用用户配额，SSH 端口保持安装前状态。
- 组合模式订阅输出三类节点并平铺进单一 `AUTO` 测速组（直连、Gcore、Cloudflare 优选 1～6），
  不再嵌套 CF 子测速组。
- 组合模式命令分工：`apply` 只重建本机 Xray/Nginx 与订阅；`apply-cloud` 才写 DNS、签发证书并
  同步 Gcore 资源（会重新询问 Gcore Token）。
- 新增菜单 `4`「Gcore CDN」模式：Nginx mTLS 回源、Gcore Managed DNS、Globalping 三网定向精选。
  安装模式调整为 5 种：`1` Reality、`2` Cloudflare、`3` Bunny（原 `4`）、`4` Gcore（新）、
  `5` 组合（新）；移除 Mieru 直连模式。
- Gcore CDN 资源现在显式下发 `options.tls_versions`，边缘只接受 TLS 1.2/1.3，拒绝
  SSLv3/TLS 1.0/TLS 1.1。
- TCP 加速统一使用 Skyline Speeder（旧内核自动安装兼容内核），移除 `easy_all tcp` 子命令。
- 状态版本统一为 `0`。旧版本（2/6/8/9）执行 `sudo easy_all uninstall` 会走本机清理路径：只删除
  easy_all 的服务、配置与状态文件，SSH/UFW 与云端资源保持不变（`--purge-cloud` 会被拒绝），
  清理完成后重新安装。
- 修复：Bunny 补充 `show`、`apply` 重建本机配置、卸载恢复 `/etc/default/ufw` 与 Nginx 默认站点、
  Pull Zone 配置漂移改为告警、免费证书等待延长；Gcore 卸载清理 acme.sh、证书续期先保存状态、
  DNS 发现失败回退历史候选；Cloudflare `--purge-cloud` 处理兜底 Worker 退场记录、
  `renew-cert` 先保存状态。
- 文档同步：README 模式表与安全边界、前置准备 8.8 组合模式、技术参考组合模式章节、
  运维指南的命令与 SSH 收敛范围。

源码版本标识为 `2.0.0`。

## 1.9.0 更新说明（2026-11-02）

- 新增第四种安装模式「4 Bunny CDN」：使用 Bunny 自动调度域名接入与 VLESS WS/TLS 协议，
  由 Cloudflare 管理 `origin` A 记录与 `cdn` CNAME 记录；Bunny 终止客户端 TLS 并通过随机 Origin Header
  回源到 VPS Nginx，Nginx 校验回源头后转发至 Xray 本地监听；提供一个自动调度域名节点及 owner 订阅。
- 官方回源池安全加固：内置系统服务与定时器每 6 小时自动拉取并刷新 Bunny 官方 IPv4 回源列表，
  原子更新 UFW `before.rules`，仅允许官方回源 IP 访问 TCP 443；支持手动执行 `easy_all refresh-origin-ips`。
- 极简化与高内聚重构：彻底精简 Bunny 相关代码，移除过度设计的状态机与繁复校验，核心 API 逻辑缩减至 250 行；
  移除深入私有实现的白盒测试与大型 mock 服务，测试套件统一重构为关注用户视角的黑盒测试（`test/test_bunny.sh`）。
- 移除直连 Trojan 模式：彻底删除 Trojan Profile、回落伪装静态站点模板、证书钩子及专用测试代码；
  项目安装模式收敛为 4 种（1: Reality, 2: Cloudflare CDN, 3: Mieru 直连, 4: Bunny CDN）。
- 入口与运行时更新：更新交互菜单选择、`renew-cert`、`rotate-dynamic-ports` 与参数校验；
  同步清理文档与架构测试断言。

源码版本标识为 `1.9.0`。已有部署执行 `sudo easy_all self-update` 即可，不影响已有模式的状态和订阅；
全新安装时可选择「4 Bunny CDN」。

## 1.8.0 更新说明（2026-11-07）

- 新增第四种安装模式「4 直连 Mieru」：安装器从 GitHub 官方 Release 读取最新 mieru 版本，下载
  `mita_<版本>_amd64.deb` 与同一 Release 的 `.sha256.txt`，SHA256 校验通过后才用 `dpkg -i`
  安装官方 mita；随后用官方 `mita apply config` 写入内部 TCP 端口（默认 `2090`）、随机用户名与
  密码、`mtu=1400`、`dns.dualStack=PREFER_IPv4` 与随机 `seed` 的 `trafficPattern`，再执行
  `mita stop`/`mita start`，并要求 `mita status` 为 `RUNNING` 且内部端口正在监听。对外使用 TCP
  端口范围 `50000-50512`：UFW 用单条 NAT 规则转发到内部端口，mita 只监听一个端口，避免创建
  五万多个 listener；客户端拿到范围后每条新连接随机选择端口。
- `easy_all show`/`subscription` 输出三种导入材料：`mierus://` 分享链接、`/etc/easy_all/mieru/client_config.json`
  客户端配置（`0600`）以及带 `port-range: "50000-50512"`、`transport: TCP`、`udp: true`、
  `multiplexing: MULTIPLEXING_LOW`、`traffic-pattern` 的 Mihomo 节点片段。traffic-pattern 的 base64 由官方
  `mita export traffic-pattern` 导出，服务端与客户端使用同一份配置。
- Mieru 复用共享的 IPv4-only、BBRv3/Skyline、定时重启、SSH `65533` 收敛、UFW 与 Fail2ban 流程；
  UFW 过滤只额外放行内部端口，`before.rules` 新增 `50000:50512 → 内部端口` 的 REDIRECT，
  `rotate-dynamic-ports` 可立即刷新，受管 `@reboot` 任务在重启后恢复。云安全组需放行
  `50000-50512`。安装前如已存在 mita 软件包或 `/etc/mita/server.conf.pb` 会拒绝继续，避免覆盖
  其他部署。
- 本模式不部署在线订阅与 easy_all 配额：`update-sub`、`quota-*` 在入口层明确拒绝，`renew-cert`
  不适用。`update-core` 在 Mieru 模式下改为下载并校验最新官方 mita 包，
  重新应用配置后验收；失败时保留已升级的软件包并提示检查。`easy_all apply` 会备份旧配置，验收
  失败时恢复并重启；`uninstall` 与首次安装回滚都会 `dpkg --purge mita` 并恢复 SSH、UFW、IPv6、
  BBR 与 crontab 快照。
- Mieru 连接地址支持公网 IPv4 或 DNS only / 灰云域名：域名会归一化并校验，客户端 JSON 写入
  `domainName`，Mihomo 与 `mierus://` 链接直接使用该域名；仍拒绝 IPv6 literal 与不合规域名。
- Worker 聚合的 `nodes` 新增 Mieru 节点：字段为 `type: "mieru"`、`host`（IPv4 或域名）、
  `port` 或 `portRange`（必须且只能一个，直连模式为 `50000-50512`）、`username`、`password`、
  可选 `transport: TCP`、`multiplexing`、`trafficPattern`、`mtu`、`udp`。Worker 用 `mieruLink()` 生成 `mierus://<用户名>:<密码>@<host>?mtu=...&...`，
  用 `clashMieruNode()` 生成 `type: mieru`、`transport: TCP`、`udp`、`username`、`password`、
  `multiplexing` 与可选 `traffic-pattern`；节点名保持原样进入 `PROXY`，不参与 CDN 自动命名或
  测速组。Mieru 只能写入 `nodes`，不能写入 `fallbackCdnNodes`。
- `scripts/build-worker.mjs` 与 `lib/worker-config.sh` 在构建/输入阶段拒绝非法的 Mieru 凭据、
  端口/端口范围、传输协议、multiplexing、traffic-pattern 与 MTU；`worker-src/config.example.json` 新增
  Mieru 模板，`worker-src/README.md`、运维指南与技术参考同步说明。三份 Mihomo 模板在
  `proxies` 标记旁注明 Mieru 节点由订阅动态注入，模板本身不放置占位凭据。
- 新增 `test/test_mieru_direct.sh`，覆盖入口菜单与分派、端口范围/NAT/cron、凭据/seed 校验、
  域名与 IPv4 连接地址、官方包 URL 与 SHA256 校验、服务器与客户端配置渲染、traffic-pattern
  导出、Mihomo/分享链接输出、状态读写与运行时验收失败路径；架构与入口测试同步覆盖第四模式。
  Worker 构建/订阅测试新增 Mieru 节点校验与 base64/Mihomo 渲染。Mieru `STATE_VERSION=1`。

源码版本标识为 `1.8.0`。已有部署执行 `sudo easy_all self-update` 即可，不影响 Reality、Cloudflare
与 Trojan 的现有状态和订阅；全新安装时在交互菜单选择 `4`。

## 1.7.2 更新说明（2026-11-06）

- 修复 Trojan 直连在「[5/8] 下载并安装 Xray 核心」报 `XRAY_RELEASES_API: unbound variable`：
  `lib/xray-core.sh` 之前依赖 Profile 预先定义 Xray Release 常量，Trojan Profile 没有定义。共享核心现在
  自带默认值（`XRAY_RELEASES_API`、`XRAY_ARCHIVE`、`XRAY_DGST`），Profile 仍可覆盖，其它模式行为不变。
- 修复回滚/卸载恢复 SSH 时把 `[::]:22` 当作多余监听而误判失败（期望仅 IPv4、实际 IPv4+IPv6）：
  实际监听列表改为与期望一致只比较 IPv4 端点，失败提示标注“仅 IPv4”并去掉多余分隔符。
- 补充 Xray 下载默认常量与 IPv4/IPv6 双栈 SSH 恢复的测试（共 70 条 Trojan 断言）。
- 兼容性：状态版本、命令与聚合订阅格式不变。1.7.1 安装失败后可直接重新运行安装命令，回滚保留的
  `65533` 配置与备份会被复用；需要回到原 SSH 端口时安装成功后执行 `easy_all uninstall`。

## 1.7.1 更新说明（2026-11-06）

- 修复 Trojan 直连模式在签发证书前下载 lego 时 404：GitHub Release 下载地址缺少版本 tag，归档资产名
  又错误地省掉了 `v`。现在按
  `https://github.com/go-acme/lego/releases/download/v4.35.2/lego_v4.35.2_linux_amd64.tar.gz` 与
  `lego_4.35.2_checksums.txt` 下载，SHA256 与 Release 内 checksums 一致后才安装。
- 回滚或卸载恢复 SSH 时，若 `systemctl reload` 后监听未收敛到安装前端点，自动改用 `restart` 并重新
  校验；仍失败时输出期望/实际监听（仅端口）再进入原有保护分支，继续保留 `65533` 配置、防火墙与备份，
  不会提前删除放行规则。
- 补充 lego 下载 URL 与 SSH 恢复 restart 回退的测试。
- 兼容性：状态版本、命令与聚合订阅格式不变。1.7.0 安装失败后可原样重新运行安装命令（复用已有备份与
  `65533` 配置），成功后再按需 `uninstall` 即可恢复原 SSH 端口。

## 1.7.0 更新说明（2026-11-06）

- 新增第三种安装模式「3 直连 Trojan」：Xray 在 TCP `443` 终止 TLS，Trojan 认证通过后走代理，
  其余流量回落到 `127.0.0.1:8080` 的 Nginx 静态站点，浏览器直接访问节点域名看到的是一个自包含的
  企业官网（首页、产品、定价、文档、公司、联系、404、`robots.txt`、`sitemap.xml` 与
  `/.well-known/security.txt`，无外部字体或脚本）。
- Trojan 证书使用 Let's Encrypt + Cloudflare DNS-01，由固定版本 `v4.35.2` 的 lego 完成：归档与
  `checksums` 同源校验 SHA256 后才安装，`easy_all-cert-renew.timer` 每天两次自动续期，续期后校验
  私钥匹配并在服务已安装时重启 Xray。Cloudflare API Token 仅授予 `Zone / Zone / Read` 与
  `Zone / DNS / Edit`，保存在 `/etc/easy_all/acme/cloudflare-dns.env`（`0600`）供无人值守续期。
- 安装器通过同一 Token 自动创建/校验 DNS only 的 A 记录（带 `easy_all trojan direct node` 注释），
  同名 AAAA/CNAME 或他人记录一律拒绝覆盖；`easy_all renew-cert` 在 Trojan 模式下强制重签，
  `uninstall --purge-cloud` 删除受管 A 记录。
- 端口支持固定 `443` 与 `dynamic`：`dynamic` 用单条 UFW NAT 规则把 `10000-62703` REDIRECT 到
  `443`（范围内 SSH 端口前置 `RETURN`），安装/`apply` 立即加载，`@reboot` 任务恢复，
  `easy_all rotate-dynamic-ports` 可手工刷新。
- 本模式不部署在线订阅与月度配额：`easy_all show`/`subscription` 输出 `trojan://` 链接与 Mihomo
  片段，`update-sub` 明确拒绝。状态版本为 Trojan `STATE_VERSION=1`，`apply` 重新校验证书、DNS、
  回落站点、Nginx 与 UFW，失败时恢复旧 Xray/Nginx 配置。
- Worker 聚合订阅的 `nodes` 新增 Trojan 直连节点支持：`type: "trojan"`（`host`/`port`/`password`/
  `sni`/`alpn`），Mihomo 输出 `type: trojan`、base64 输出 `trojan://` URI，节点名保持原样进入 `PROXY`；
  `fallbackCdnNodes` 仍只接受 VLESS。`config.example.json`、`worker-config.sh`、构建校验、Worker
  测试与文档同步更新，可直接把 Trojan 节点与 Reality 节点一起聚合下发。
- 新增 `test/test_trojan_direct.sh`，覆盖站点渲染、Xray/回落配置、NAT 范围、状态读写、证书钩子、
  Token 读取与 A 记录保护；架构与入口测试同步覆盖第三模式。

源码版本标识为 `1.7.0`。已有部署执行 `sudo easy_all self-update` 即可，不影响 Reality 与
Cloudflare 模式的现有状态和订阅；全新安装时在交互菜单选择 `3`。

## 1.6.13 更新说明（2026-11-05）

- 直连 Reality 安装新增第三档订阅输出，安装菜单变为「1 仅节点（默认）」「2 本机订阅」「3 Worker 订阅聚合」。默认值与「多节点聚合或已有订阅服务器时推荐仅输出节点信息」的既有建议一致；升级不会改动已安装配置。
- Worker 订阅聚合复用 Cloudflare Worker 下发：公开订阅域名绑定 Worker Custom Domain，同 Zone 的私有节点源域名由 Cloudflare 代理回本机 `8443` 且仅允许 Cloudflare 回源；Nginx 继续是 Token 与配额的唯一真源，源不可用返回 `502`，Token 被拒返回 `403`。安装器自动注入 `vpsSubUrl`、`sourceSecret`，并保持不内嵌公开 Token。
- Worker 现在可以解析 Reality 私有源返回的 `security=reality&type=tcp` URI 订阅：保留节点名与动态端口，直接列入 `PROXY`，不改名为 `🇺🇸优选N`，也不放入 CDN/Worker 测速组；CDN 源节点行为不变。
- 聚合配置校验、Worker 名称与 prompt 提取到 `lib/worker-config.sh`，由两个 Profile 共享，避免 Reality 与 Cloudflare 各维护一套 JSON 解析。Reality 聚合会校验额外节点名不能与本机节点名重复。
- `update-sub` 支持在三种输出之间切换，并在新模式生效后清理上一模式的 Worker、Custom Domain、Origin CA、Strict TLS 规则和源站 DNS；`uninstall --purge-cloud` 同时删除 Worker 与其 Custom Domain。Worker 名称安装后不能就地改名。
- 补充 Reality 三种模式的分发、状态读写、域名约束、Worker 源解析与文档一致性测试。
- 兼容性：状态版本从 Reality v7 升到 v8（新增 `SUB_SOURCE_DOMAIN`、Worker 名称/Custom Domain/Account ID 与源密钥字段），旧状态自动升级；`link`/`deploy` 的订阅 URL 与行为不变，状态中的 `SUBSCRIPTION_MODE` 仍是这两个规范值。非交互脚本请使用 `link`/`deploy`/`worker` 名称，不再接受数字别名。

源码版本标识为 `1.6.13`。已有部署执行 `sudo easy_all self-update` 即可；本次不改变现有订阅内容，未切换订阅模式时无需重新执行 `apply` 或 `update-sub`。需要 Worker 聚合的部署执行 `sudo easy_all update-sub`，选择第 3 项并按提示准备两个同 Zone 一级子域名与 Workers Scripts Write 权限。

# 更新记录

## 1.7.0 更新说明（2026-11-06）

- 新增第三种安装模式「3 直连 Trojan」：Xray 在 TCP `443` 终止 TLS，Trojan 认证通过后走代理，
  其余流量回落到 `127.0.0.1:8080` 的 Nginx 静态站点，浏览器直接访问节点域名看到的是一个自包含的
  企业官网（首页、产品、定价、文档、公司、联系、404、`robots.txt`、`sitemap.xml` 与
  `/.well-known/security.txt`，无外部字体或脚本）。
- Trojan 证书使用 Let's Encrypt + Cloudflare DNS-01，由固定版本 `v4.35.2` 的 lego 完成：归档与
  `checksums` 同源校验 SHA256 后才安装，`easy_all-cert-renew.timer` 每天两次自动续期，续期后校验
  私钥匹配并在服务已安装时重启 Xray。Cloudflare API Token 仅授予 `Zone / Zone / Read` 与
  `Zone / DNS / Edit`，保存在 `/etc/easy_all/acme/cloudflare-dns.env`（`0600`）供无人值守续期。
- 安装器通过同一 Token 自动创建/校验 DNS only 的 A 记录（带 `easy_all trojan direct node` 注释），
  同名 AAAA/CNAME 或他人记录一律拒绝覆盖；`easy_all renew-cert` 在 Trojan 模式下强制重签，
  `uninstall --purge-cloud` 删除受管 A 记录。
- 端口支持固定 `443` 与 `dynamic`：`dynamic` 用单条 UFW NAT 规则把 `10000-62703` REDIRECT 到
  `443`（范围内 SSH 端口前置 `RETURN`），安装/`apply` 立即加载，`@reboot` 任务恢复，
  `easy_all rotate-dynamic-ports` 可手工刷新。
- 本模式不部署在线订阅与月度配额：`easy_all show`/`subscription` 输出 `trojan://` 链接与 Mihomo
  片段，`update-sub` 明确拒绝。状态版本为 Trojan `STATE_VERSION=1`，`apply` 重新校验证书、DNS、
  回落站点、Nginx 与 UFW，失败时恢复旧 Xray/Nginx 配置。
- 新增 `test/test_trojan_direct.sh`，覆盖站点渲染、Xray/回落配置、NAT 范围、状态读写、证书钩子、
  Token 读取与 A 记录保护；架构与入口测试同步覆盖第三模式。

源码版本标识为 `1.7.0`。已有部署执行 `sudo easy_all self-update` 即可，不影响 Reality 与
Cloudflare 模式的现有状态和订阅；全新安装时在交互菜单选择 `3`。

## 1.6.12 更新说明（2026-10-30）

- 修复直连（Reality）安装并部署订阅时验收偶发 404：Nginx 先写入只含 `location / { return 404; }` 的引导配置，再写入正式订阅配置并 `systemctl reload nginx`；reload 在所有 worker 切换完成前返回，随后的无效 Token 探测可能命中仍服务引导配置的 worker。共享验收函数现在对 404 短暂重试（最多 20 次 × 0.25s），命中 403 立即通过，其它状态仍然立即失败，不会放过真正的鉴权放宽或配置未生效。
- 修复 Origin CA 证书复用缺少云端元数据：磁盘证书仍然有效但状态中的 `CLOUDFLARE_ORIGIN_CERT_ID`/`CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON` 为空（例如 Reality 从 deploy 切到 link 再切回 deploy 会清空这两项）时改为重新签发，避免写下不完整状态、下次 `load_state` 直接失败「订阅状态不完整」。
- Cloudflare XHTTP 的源站证书复用采用同一规则，避免状态缺少证书 ID 后 `renew-cert` 与 `uninstall --purge-cloud` 无法定位云端资源。
- 补充订阅 Token 验收重试、两个 Profile 证书元数据门控与强制轮换不复用的测试。
- 已因上述问题写下不完整状态的部署无法用 `renew-cert` 修复（`load_state` 会先拒绝），需要重新安装订阅，或手工补齐状态文件中的 `CLOUDFLARE_ORIGIN_CERT_ID` 与 `CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON`。
- 兼容性：状态版本 Reality v7、Cloudflare v9 保持不变，无需迁移；订阅 URL 不变。

源码版本标识为 `1.6.12`。已有部署执行 `sudo easy_all self-update` 即可；本次不改变订阅内容与状态版本，无需重新执行 `apply` 或 `update-sub`。
详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.11 更新说明（2026-10-27）

- `update-core` 在核心验收通过后自动重新生成 Reality 自托管订阅：订阅是否携带 `support-x25519mlkem768` 取决于本机核心版本，升级核心后旧订阅会与新核心不一致，现不再需要额外执行 `apply`。
- 核心更新失败仍按原逻辑回滚二进制、版本文件与运行时配置，不触发订阅重发；订阅重发失败时核心保持新版本，并提示执行 `sudo easy_all apply`。
- 补充核心更新成功与失败两条路径的订阅重发测试。
- 兼容性：状态版本 Reality v7、Cloudflare v9 保持不变，无需迁移；订阅 URL 不变。

源码版本标识为 `1.6.11`。已有部署执行 `sudo easy_all self-update`；需要更新核心时执行
`sudo easy_all update-core`，升级到 26.9.8+ 后订阅会自动换成携带 `support-x25519mlkem768` 的版本。
详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.10 更新说明（2026-10-27）

- 修复 Xray 26.9.8 起 REALITY 服务端要求 ClientHello 携带 `X25519MLKEM768` key share、而 mihomo 默认剥离该 key share 导致的“握手成功但不走流量”：自托管订阅在本机 Xray 版本不低于 26.9.8 时于 `reality-opts` 下输出 `support-x25519mlkem768: true`，其它版本或版本文件无法解析时不输出。
- Worker 聚合订阅的 `flag=clash` 输出默认携带同一字段，可用节点字段 `supportX25519Mlkem768: false` 关闭；`flag=base64` 的 URI 订阅不携带该参数，Xray 系客户端（v2rayNG 等）自行协商。
- 该字段需 mihomo 1.19.9 及以上内核才生效；更旧的 mihomo 内核会忽略它，客户端侧不产生回归。聚合配置里的 Reality 节点若指向 Xray 低于 26.9.8 的服务端，请为该节点设置 `supportX25519Mlkem768: false`。
- 补充按核心版本门控、Worker 开关类型校验与两条渲染路径一致性的测试。
- 兼容性：状态版本 Reality v7、Cloudflare v9 保持不变，无需迁移；订阅 URL 不变。

源码版本标识为 `1.6.10`。已有部署执行 `sudo easy_all self-update`；Reality 自托管订阅再执行
`sudo easy_all apply` 重新生成订阅（是否带该字段取决于本机核心版本，低于 26.9.8 时不写入，
旧服务端不需要它；升级核心后请再执行一次 `apply`）；Cloudflare 聚合订阅再执行
`sudo easy_all update-sub` 重建 Worker。详见[运维指南](docs/operations-guide.md#更新与应用)。

## 1.6.9 更新说明（2026-10-27）

- 新增 `easy_all reality-target [域名:端口]`：安装后可修改 Reality SNI（伪装目标）与回源目标，无参数时交互输入，带参数可直接脚本化。该命令仅适用于 Reality 模式，Cloudflare 模式会明确拒绝。
- 新目标沿用安装期验收：带 SNI 的 TLS 1.3 握手与 ASN 比对；握手失败时恢复旧 `config.json`，状态文件保持旧值，不留下半改状态。
- 运行时就绪后立即落盘，部署自托管订阅时同步重写订阅文件；link 模式不生成订阅。同值重跑只进出维护锁、不重复切换，并提示用 `sudo easy_all apply` 补齐中断的订阅重发。
- 补充命令分派、模式守卫、执行序列与文档收录的测试。
- 使用聚合配置下发节点的部署，修改 SNI 后仍需同步聚合配置里的 `sni` 并重建 Worker。
- 兼容性：状态版本 Reality v7、Cloudflare v9 保持不变，无需迁移；订阅 URL 不变，但切换后客户端必须刷新订阅或重新导入节点。

源码版本标识为 `1.6.9`。本次为新增命令，存量部署无需重新执行 `apply`；需要更换伪装目标时执行 `sudo easy_all reality-target <域名:端口>`。详见[运维指南](docs/operations-guide.md#修改-reality-sni)。

## 1.6.8 更新说明（2026-10-22）

- 修复配额统计与 Xray `ExecStop` 钩子的写锁死锁竞争：当维护命令（`apply`、`update-sub`、`quota-set/reset`）持有运行时锁重启 Xray 时，`quota_sync_usage` 识别到维护标记立即让渡，不再因尝试跨进程获取锁而导致 15 秒死锁停顿。
- 修复服务停机/重启时流量同步被跳过导致数据丢失的缺陷：`quota_sync_usage` 兼容 systemd `deactivating` 状态，确保在正常关停与重启前完整统计并持久化当轮流量。
- 修复全员超额停用时 Xray 因客户端为空崩溃的边界问题，以及 Worker 委托鉴权模式下的源站 403 负向缓存收敛。
- 补充对应 systemd 状态感知与维护锁跳过的单元测试。
- 兼容性：状态版本 Reality v7、Cloudflare v9 保持不变，无需迁移。

源码版本标识为 `1.6.8`。升级执行 `sudo easy_all self-update` 并执行 `sudo easy_all apply`。详见[运维指南](docs/operations-guide.md#更新与应用)。

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
