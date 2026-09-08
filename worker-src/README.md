# Worker 构建

在仓库根目录运行：

```sh
cp worker-src/config.example.json worker-src/config.local.json
# 填写 config.local.json 中的实际参数；已有配置时不要覆盖。
npm run build:worker
npm run test:worker
```

已迁移的环境直接执行 `npm run build:worker`，无需复制示例。
Node.js 18 或更新版本即可，无需安装 npm 依赖。

- `config.local.json`：用户 token、Reality 节点、VPS CF 订阅地址、CF 备用节点、XFLASH 订阅地址。Reality 端口继续按北京时间每三小时轮换。
- `index.js`：公共运行源码。节点在订阅请求时获取，构建时不联网。
- `../templates/mihomo.yaml`：模式 2 与 Worker 共用的 DNS、TUN、嗅探、规则集和分流配置。自定义模式 2 模板会与默认 Worker 配置不同。
- `worker.js`：生成后可直接部署到 Cloudflare 的模块 Worker。不要手工编辑。

本地配置和生成产物均被 Git 忽略，文件权限为 0600。构建先校验配置和产物语法，再原子替换旧产物；失败保留原文件。构建不会部署，也不清理 Git 历史。

Worker 保留 `/subscribe?token=...`，`flag=clash` 返回完整配置，`flag=base64` 返回节点 URI 订阅；无 flag 时沿用客户端 User-Agent 判断。默认隐藏标记为 `optional`、`allOnly` 或名称/主机包含 `vmiss` 的节点；追加 `node=all` 时显示全部节点。

Clash 上游仅提供 `proxies`。支持缩进的 YAML block list，节点以 `name` 开头，或以 `name` 为首字段的单行 flow map；不支持任意 YAML 文档、外部锚点或依赖已移除上游策略组的节点。获取失败、格式不支持或节点名称冲突时使用本地节点，响应带 `X-Easy-All-Warning: xflash-unavailable-local-only`。VPS 获取失败使用 `fallbackCdnNodes`。仅生成 PROXY 和备用优选两个策略组，PROXY 依次包含其他节点和备用优选，不重复列出 CF 备用节点。备用优选仅包含本次获取的最多六个 CF 备用节点（获取失败使用本地备用配置）。没有 CF 节点时备用优选使用 REJECT，避免自动切换到其他节点；DIRECT 仅用于直连分流规则。

公共模板保留已有国内 fake-ip 兼容性排除，是否直连仍由分流规则决定。全局 IPv6 固定关闭，所有节点统一输出 `ip-version: ipv4`。模板开头的明确直连域名（包括 Steam 下载域名）先匹配，其余 UDP/443 在代理规则前拒绝；不是放行所有国内 QUIC。国内集合仍在显式代理域名之后，避免覆盖 AI 等例外。修改公共模板后需重新构建 Worker，并在 VPS 重新生成模式 2 订阅，已部署产物不会自动更新。

版本由构建脚本按北京时间生成，例如 `2026-09-06-v0`。同一天根据现有 `worker.js` 的版本递增，跨日从 `v0` 开始；构建失败不消耗版本。删除产物后也会从 `v0` 开始，因此需要连续编号时请保留上次构建的文件。版本通过 `X-Easy-All-Version` 响应头返回。

### CF 聚合只出现兜底节点

动态 CF 获取或解析失败会使用 `fallbackCdnNodes`；这不代表 VPS 没有生成节点。Worker 请求 VPS 时固定追加 `flag=base64` 并使用 URI 客户端 UA，先解析有效节点再取最多六个，避免 Clash 格式或前面的不支持节点导致误降级。

部署重新构建的 `worker.js` 后，检查订阅响应头（不要公开含 token 的链接）：

- `X-Easy-All-Version`：确认线上已更新。
- `X-Easy-All-CDN-Nodes`：动态获取成功的节点数量。
- `X-Easy-All-CDN-Warning`：动态获取失败原因；HTTP 403 检查 Cloudflare Security Events，challenge 表示收到 Cloudflare 挑战，解析错误表示正文没有可用节点，超时检查 Worker 到订阅域名的连接。上游错误的 `Content-Type` 不代表正文无效，XFLASH 可能用 `text/html` 返回 Base64 或 YAML。
- `X-Easy-All-Warning`：独立的 XFLASH 上游状态，与 CF 获取结果不同。

Cloudflare 配置问题不能靠更换 UA 修复。[Bot Fight Mode 不能被 WAF Skip 规则跳过](https://developers.cloudflare.com/bots/get-started/bot-fight-mode/)；Super Bot Fight Mode 才支持该例外。[1042 表示同 Zone 的 Worker 子请求限制](https://developers.cloudflare.com/workers/observability/errors/)，仅在确实发生该错误时检查 `global_fetch_strictly_public` 及路由，避免请求递归回聚合 Worker 自身。
