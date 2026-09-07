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

- `config.local.json`：用户 token、Reality 节点、VPS CF 订阅地址、CF 备用节点、XFLASH 订阅地址。`nodes` 中的节点全部平铺显示；端口继续按北京时间每三小时轮换。
- `index.js`：公共运行源码。节点在订阅请求时获取，构建时不联网。
- `../templates/mihomo.yaml`：模式 2 与 Worker 共用的 DNS、TUN、嗅探、规则集和分流配置。自定义模式 2 模板会与默认 Worker 配置不同。
- `worker.js`：生成后可直接部署到 Cloudflare 的模块 Worker。不要手工编辑。

本地配置和生成产物均被 Git 忽略，文件权限为 0600。构建先校验配置和产物语法，再原子替换旧产物；失败保留原文件。构建不会部署，也不清理 Git 历史。

Worker 保留 `/subscribe?token=...`，`flag=clash` 返回完整配置，`flag=base64` 返回节点 URI 订阅；无 flag 时沿用客户端 User-Agent 判断。所有节点默认显示，旧链接的 `node` 参数不再影响节点列表。

Clash 上游仅提供 `proxies`。支持缩进的 YAML block list，节点以 `name` 开头，或以 `name` 为首字段的单行 flow map；不支持任意 YAML 文档、外部锚点或依赖已移除上游策略组的节点。获取失败、格式不支持或节点名称冲突时使用本地节点，响应带 `X-Easy-All-Warning: xflash-unavailable-local-only`。VPS 获取失败使用 `fallbackCdnNodes`。仅生成 PROXY 和备用优选两个策略组，PROXY 依次包含其他节点和备用优选，不重复列出 CF 备用节点。备用优选仅包含本次获取的最多六个 CF 备用节点（获取失败使用本地备用配置）。没有 CF 节点时备用优选使用 REJECT，避免自动切换到其他节点；DIRECT 仅用于直连分流规则。

公共模板保留已有国内 fake-ip 兼容性排除，是否直连仍由分流规则决定。全局 IPv6 默认关闭，节点 IP 统一输出 ipv4。模板开头的明确直连域名（包括 Steam 下载域名）先匹配，其余 UDP/443 在代理规则前拒绝；不是放行所有国内 QUIC。国内集合仍在显式代理域名之后，避免覆盖 AI 等例外。修改公共模板后需重新构建 Worker，并在 VPS 重新生成模式 2 订阅，已部署产物不会自动更新。

版本由构建脚本按北京时间生成，例如 `2026-09-06-v0`。同一天根据现有 `worker.js` 的版本递增，跨日从 `v0` 开始；构建失败不消耗版本。删除产物后也会从 `v0` 开始，因此需要连续编号时请保留上次构建的文件。版本通过 `X-Easy-All-Version` 响应头返回。
