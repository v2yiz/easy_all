# Worker 构建

Cloudflare XHTTP 模式选择“部署订阅服务”时，安装器会直接通过 Cloudflare API 生成并部署该 Worker，
默认名称为 `easyall`，无需手工执行本节命令。下面的本地构建流程只用于独立维护或聚合额外节点。

在仓库根目录运行：

```sh
cp worker-src/config.example.json worker-src/config.local.json
# 填写 config.local.json 中的实际参数；已有配置时不要覆盖。
npm run build:worker
npm run test:worker
```

已迁移的环境直接执行 `npm run build:worker`，无需复制示例。
Node.js 18 或更新版本即可，无需安装 npm 依赖。

- `config.local.json`：用户 Token、额外 Reality 节点、VPS 私有订阅源、外部订阅源和 CDN 兜底节点。独立构建时可填写完整字段；安装器聚合流程要求输入中不含 `vpsSubUrl`，再由本机自动注入。Reality 端口继续按北京时间每三小时轮换；只有节点域名 AAAA 已验证指向双栈 VPS 时，才把该 Reality 节点的 `ipVersion` 设为 `dual`。
- `index.js`：公共运行源码。节点在订阅请求时获取，构建时不联网。
- `../templates/mihomo.yaml`：模式 2 与 Worker 共用的 DNS、TUN、嗅探、规则集和分流配置。自定义模式 2 模板会与默认 Worker 配置不同。
- `worker.js`：生成后可直接部署到 Cloudflare 的模块 Worker。不要手工编辑。

本地配置和生成产物均被 Git 忽略，文件权限为 0600。构建先校验配置和产物语法，再原子替换旧产物；失败保留原文件。构建不会部署，也不清理 Git 历史。

Worker 保留 `/subscribe?token=...`，`flag=clash` 返回完整配置，`flag=base64` 返回节点 URI 订阅；无 flag 时沿用客户端 User-Agent 判断。默认隐藏标记为 `optional`、`allOnly` 或名称/主机包含 `vmiss` 的节点；追加 `node=all` 时显示全部节点。

安装器自动部署的 Worker 不依赖外部 `externalSubUrl`：它将公开请求的 Token 转发到节点域名上的
Nginx 私有源，并附加独立的 `X-Easy-All-Worker-Source` 密钥。Worker 显式启用
`global_fetch_strictly_public`、关闭 `workers.dev` 和 Preview URL，并只绑定独立订阅 Custom Domain。
自动部署脚本不内嵌公开用户 Token；Nginx 是用户与配额鉴权的唯一真源。订阅域名不得与节点域名相同；
动态源失败时返回 `502`，源明确拒绝 Token 时返回 `403`，不会使用静态节点绕过用户配额。
选择聚合时，安装器读取一份不含 `vpsSubUrl` 的 `config.local.json` JSON，保留其中的 `nodes`、
`externalSubUrl` 和 `fallbackCdnNodes`；其中的 `allowedTokens` 会覆盖安装器先前设置的 Token。
启用配额时用户名必须与配额用户一致。安装器再注入本机私有源 URL 与鉴权字段。
最终配置由 `../scripts/build-worker.mjs` 正式校验构建，不由 shell 直接拼接。

`externalSubUrl` 指向的 Clash 上游仅提供 `proxies`。支持缩进的 YAML block list，节点以 `name` 开头，或以 `name` 为首字段的单行 flow map；不支持任意 YAML 文档、外部锚点或依赖已移除上游策略组的节点。获取失败、格式不支持或节点名称冲突时使用本地节点，响应带 `X-Easy-All-Warning: xflash-unavailable-local-only`。`vpsSubUrl` 获取失败时使用 `fallbackCdnNodes`。动态与兜底 CDN 节点按地址族分别命名：IPv4 为 `优选1`～`优选6`，IPv6 为 `优选IPv6-1`～`优选IPv6-3`。仅生成 PROXY 和备用优选两个策略组，备用优选最多包含 6 个 IPv4 和 3 个 IPv6；没有 CDN 节点时使用 REJECT。

公共模板启用客户端 IPv4/IPv6 双栈，保留国内 fake-ip 兼容性排除，是否直连仍由分流规则决定。中国大陆域名使用阿里与 DNSPod DoH，其他域名通过 `PROXY` 使用 Cloudflare 与 Google DoH；代理节点域名仍由独立的直连 DoH 解析，避免启动循环。Reality 节点可显式选择 `ipv4` 或 `dual`，其中 `dual` 要求 VPS 公网 IPv6 和节点 AAAA 匹配。动态 Cloudflare 节点根据精选连接地址输出 `ipv4` 或 `ipv6`；Cloudflare 边缘 IPv6 不要求 VPS 有 IPv6，也不需要添加指向 VPS 的 AAAA。所有 Google 域名都进入代理，VPS 再按已持久化策略通过 `ForceIPv4` 或 `ForceIPv6` 固定出站。修改公共模板后需重新构建 Worker，并在 VPS 重新生成模式 2 订阅。

版本由构建脚本按北京时间生成，例如 `2026-09-06-v0`。同一天根据现有 `worker.js` 的版本递增，跨日从 `v0` 开始；构建失败不消耗版本。删除产物后也会从 `v0` 开始，因此需要连续编号时请保留上次构建的文件。版本通过 `X-Easy-All-Version` 响应头返回。

### Cloudflare 聚合只出现兜底节点

动态 VPS 节点获取或解析失败会使用 `fallbackCdnNodes`；这不代表 VPS 没有生成节点。Worker 请求 `vpsSubUrl` 时固定追加 `flag=base64` 并使用 URI 客户端 UA，解析后分别保留最多 6 个 IPv4 和 3 个 IPv6 节点。

部署重新构建的 `worker.js` 后，检查订阅响应头（不要公开含 token 的链接）：

- `X-Easy-All-Version`：确认线上已更新。
- `X-Easy-All-CDN-Nodes`：动态获取成功的节点数量。
- `X-Easy-All-CDN-Warning`：动态获取失败原因；HTTP 403 检查 Cloudflare Security Events，challenge 表示收到 Cloudflare 挑战，解析错误表示正文没有可用节点，超时检查 Worker 到订阅域名的连接。上游错误的 `Content-Type` 不代表正文无效，外部订阅服务可能用 `text/html` 返回 Base64 或 YAML。
- `X-Easy-All-Warning`：独立的 `externalSubUrl` 上游状态，与 VPS 动态节点获取结果不同。

Cloudflare 配置问题不能靠更换 UA 修复。[Bot Fight Mode 不能被 WAF Skip 规则跳过](https://developers.cloudflare.com/bots/get-started/bot-fight-mode/)；Super Bot Fight Mode 才支持该例外。[1042 表示同 Zone 的 Worker 子请求限制](https://developers.cloudflare.com/workers/observability/errors/)；自动部署固定启用 `global_fetch_strictly_public`，并将 Worker 与节点源绑定到不同主机名以避免递归。
