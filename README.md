# easy_all

当前源码版本：[2.5.0](CHANGELOG.md#250-更新说明2026-11-04)。

`easy_all` 是专为全新 Debian 12/13 VPS 设计的单节点代理一键安装工具。通过一份 JSON 参数文件一次性完成配置，安装过程全自动免交互，统一打通 Xray、Nginx、订阅分发、UFW 防火墙、Fail2ban 以及 TCP 加速（默认自动启用 Skyline Speeder / BBR）。

仅支持 IPv4。一台 VPS 只能选择安装一种模式，建议在无其他业务占用的纯净 VPS 上部署。

---

## 模式选择

| 模式 | 适用场景 | 核心架构与入口 |
| :--- | :--- | :--- |
| **1. 直连 Reality** | VPS IP 纯净、直连网络良好 | VLESS TCP Reality Vision（VPS `443` 或动态端口轮换） |
| **2. Cloudflare CDN** | VPS 直连受阻、IP 被墙或需要防封 | VLESS XHTTP `stream-up` + 6 个 Cloudflare 优选 IPv4；可选独立 Worker 兜底 |
| **3. Bunny CDN** | 追求多地区边缘与自动调度 | VLESS WS/TLS（Pull Zone 自动调度域名 + Nginx HTTPS 回源） |
| **5. 组合模式** | 一台机器同时拥有直连与 CDN 节点 | **直连 Reality（VPS `8443`） + Cloudflare XHTTP（443 回源）**，统一订阅自动测速优选 |

> **注**：原模式 4（Gcore CDN）已彻底移除；原模式 5 中的 Gcore 节点也已完全剥离，组合模式现专注于**直连 + Cloudflare**。

---

## 开始前准备

### 1. SSH 保活与防止中断
安装过程包含系统更新、内核编译与网络优化，耗时约 5~15 分钟。为防止 SSH 偶发空闲断开导致安装半途终止：
- **强烈建议在 `tmux` 或 `screen` 会话中执行**。
- 本机客户端配置保活（写入本机 `~/.ssh/config`）：
  ```sshconfig
  Host *
      ServerAliveInterval 30
      ServerAliveCountMax 6
      TCPKeepAlive yes
  ```
- 万一中途连接断开，重新连接后再次运行安装命令即可：程序会自动检测安装断点并提示**继续上次安装**（保留已生成的证书与密钥配置）。

### 2. 服务器与端口要求
- **操作系统**：全新 Debian 12 / 13（amd64；Bunny 额外支持 arm64）；
- **网络与权限**：具备公网 IPv4，root 权限，未运行其他占用 80/443 的 Nginx/Xray；
- **防火墙/安全组**：云厂商安全组放行 SSH 端口与 TCP `443`（组合模式另需放行 TCP `8443`；直连动态端口模式另需放行 `10000-62703`）。

---

## 快速安装流程

### 步骤 1：准备参数文件 `params.json`
在本地编辑器中根据需求配置参数。以最常用的**组合模式**为例（直连 + Cloudflare 双入口）：

```json
{
  "schema_version": 1,
  "mode": "combined",
  "params": {
    "CF_ZONE": "example.com",
    "DIRECT_DOMAIN": "node.example.com",
    "CF_NODE_DOMAIN": "cf.example.com",
    "CF_ORIGIN_DOMAIN": "cf-origin.example.com",
    "SUBSCRIPTION_DOMAIN": "sub.example.com",
    "CLOUDFLARE_API_TOKEN": "<填入 Cloudflare API Token>",
    "GLOBALPING_TOKEN": "<填入 Globalping Access Token>",
    "REALITY_TARGET": "swdist.apple.com:443",
    "DIRECT_NODE_NAME": "🇺🇸直连",
    "CF_NODE_PREFIX": "🇺🇸CF",
    "SUB_DOWNLOAD_NAME": "EASY_ALL",
    "ALLOWED_TOKENS": {
      "owner": "<自定义 8-128 位订阅 Token>"
    }
  }
}
```
> 其他模式（直连 Reality、Cloudflare XHTTP、Bunny）完整参数模版详见 [参数示例手册](docs/params-examples.md)。

#### 核心参数字段速查

| 字段 | 适用模式 | 必填 | 默认 / 留空 | 说明 |
| :--- | :--- | :--- | :--- | :--- |
| `VLESS_UUID` | 全部 | 否 | 自动生成 | 节点 UUID，留空自动生成符合规范的 UUIDv4 |
| `VPS_PUBLIC_IPV4` | 全部 | 否 | 自动探测 | VPS 真实公网 IPv4，NAT 或多 IP 环境建议手动指定 |
| `TCP_ACCELERATION` | 全部 | 否 | `skyline` | TCP 拥塞控制算法：`skyline` 或 `bbrv3` |
| `REBOOT_SCHEDULE_MODE` | 全部 | 否 | `1` | 定时重启计划：`1` 每天 04:00，`2` 自定义小时，`3` 不配置 |
| `REBOOT_HOUR` | 全部 | 否 | 空 | 自定义重启小时（0~23），仅在 `REBOOT_SCHEDULE_MODE: "2"` 时必填 |
| `SUB_DOWNLOAD_NAME` | 直连/CF/组合 | 否 | `EASY_ALL` | 客户端订阅文件下载名（不含扩展名） |
| `CLOUDFLARE_API_TOKEN` | 直连/CF/组合 | 条件 | — | Cloudflare API Token（需 Zone.DNS 与 SSL/TLS 权限）；直连 deploy/worker、CF、组合模式必填 |
| `GLOBALPING_TOKEN` | CF/组合 | 是 | — | Globalping API Token，用于探测筛选当下最佳优选 IP |
| `BUNNY_API_KEY` | Bunny | 是 | — | Bunny 账户 API Key |
| `CLOUDFLARE_DNS_TOKEN` | Bunny | 是 | — | 用于配置 Bunny 节点 DNS 解析的 Cloudflare Token |
| `ALLOWED_TOKENS` | 直连/CF/组合 | 条件 | — | 订阅用户字典 `{"用户":"token"}`；组合模式若不填会自动生成 owner |
| `OWNER_TOKEN` | 组合/Bunny | 否 | 自动生成 | 单用户订阅 Token；与 `ALLOWED_TOKENS` 二选一，Bunny 固定单用户 |
| `SUBSCRIPTION_MODE` | 直连/CF | 否 | `deploy` | 订阅部署方式：直连支持 `link`/`deploy`/`worker`；CF 支持 `link`/`deploy` |
| `SUBSCRIPTION_DOMAIN` | 直连/CF/组合 | 条件 | 自动派生 | 订阅服务域名；CF 与组合模式默认派生 `sub.<域名>`，直连 deploy 模式需手填 |
| `SUB_SOURCE_DOMAIN` | 直连 | 条件 | — | 直连 worker 订阅模式下，Worker 回源 VPS 所用的私有域名 |
| `CLOUDFLARE_WORKER_NAME` | 直连/CF | 否 | 自动命名 | 部署订阅 Worker 的自定义名称 |
| `WORKER_SOURCE_SECRET` | 直连/CF | 否 | 自动生成 | Worker 与 VPS Nginx 回源鉴权密钥 |
| `WORKER_AGGREGATION_CONFIG` | 直连/CF | 否 | `{}` | 聚合其他节点订阅的配置 JSON |
| `ENABLE_MONTHLY_QUOTA` | 直连/CF | 否 | `0` | 是否开启月度流量配额：`1` 启用，`0` 关闭 |
| `MONTHLY_QUOTAS_GB` | 直连/CF | 否 | `{"owner":0}` | 各用户配额限额（GB），`0` 表示不限流量 |
| `QUOTA_TOKEN_OVERRIDES` | 直连/CF | 否 | `{}` | 开启配额时各用户的独立 Token 映射 |
| `QUOTA_START_DATE` | 直连/CF | 否 | 当天日期 | 月度流量计费起始日期（`YYYY-MM-DD`） |
| `CF_ZONE` | 组合 | 是 | — | Cloudflare 托管的主域名（如 `example.com`） |
| `CLOUDFLARE_ZONE` | Bunny | 是 | — | Cloudflare 托管的主域名 |
| `DIRECT_DOMAIN` | 组合 | 否 | `node.<CF_ZONE>` | 组合模式直连节点域名（DNS 灰云 A 记录） |
| `CF_NODE_DOMAIN` | 组合 | 否 | `cf.<CF_ZONE>` | 组合模式 Cloudflare 节点外部域名（DNS 橙云） |
| `CF_ORIGIN_DOMAIN` | 组合 | 否 | `cf-origin.<CF_ZONE>` | 组合模式源站真实域名（DNS 橙云） |
| `VLESS_CDN_DOMAIN` | CF | 是 | — | Cloudflare 模式客户端连接域名（DNS 橙云） |
| `ORIGIN_DOMAIN` | Bunny | 否 | `origin.<CLOUDFLARE_ZONE>` | Bunny 源站域名（DNS 灰云 A 记录） |
| `CDN_DOMAIN` | Bunny | 否 | `cdn.<CLOUDFLARE_ZONE>` | Bunny 节点对外域名（DNS CNAME 到 Bunny Pull Zone） |
| `WORKER_BACKUP_DOMAIN` | CF | 否 | 空 | Cloudflare 独立 Worker 兜底节点域名（留空不部署） |
| `WORKER_BACKUP_PLACEMENT` | CF | 否 | `off` | 兜底 Worker 智能调度：`off` 或 `aws:ap-east-1` |
| `NODE_NAME` | 直连 | 否 | `MY_REALITY` | 客户端展示的直连节点名称 |
| `XHTTP_NODE_NAME` | CF | 否 | `VLESS_XHTTP_H2` | 客户端展示的 CF 节点名称 |
| `DIRECT_NODE_NAME` | 组合 | 否 | `🇺🇸直连` | 组合模式中直连节点的客户端展示名称 |
| `CF_NODE_PREFIX` | 组合 | 否 | `🇺🇸CF` | 组合模式中 CF 优选节点前缀（自动生成 6 个优选节点） |
| `NODE_HOST` | 直连 | 否 | 自动探测 | 直连节点连接地址（VPS IPv4 或解析到该 IP 的灰云域名） |
| `REALITY_TARGET` | 直连/组合 | 否 | `swdist.apple.com:443` | Reality 伪装目标（`域名:端口`），需支持 TLS 1.3 |
| `SUB_PORT_MODE` | 直连 | 否 | `dynamic` | 直连端口工作模式：`443` 单端口或 `dynamic` 动态端口轮换 |
| `XHTTP_PATH` | CF/组合 | 否 | 自动生成 | VLESS XHTTP 传输路径 |
| `WEBSOCKET_PATH` | Bunny | 否 | 自动生成 | VLESS WebSocket 传输路径 |
| `XRAY_XHTTP_LOOPBACK_PORT` | CF | 否 | `10086` | 本机 Xray XHTTP 回环监听端口 |
| `ORIGIN_HEADER_SECRET` | CF/Bunny | 否 | 自动生成 | CDN 回源私有鉴权密钥 |
| `BUNNY_PULL_NAME` | Bunny | 否 | 自动生成 | Bunny Pull Zone 名称 |
| `BUNNY_BANDWIDTH_GB` | Bunny | 否 | `500` | Bunny Pull Zone 月度流量限制（GB，`0` 不限） |

### 步骤 2：登录 VPS 校验并执行安装
```bash
# 1. 登录 VPS 并在终端写入参数文件
cat > params.json <<'EOF'
{ ... 粘贴上面的完整 JSON ... }
EOF

# 2. 预检参数（只校验合法性与网络要求，不改动系统）
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) params.json --check-params

# 3. 开始一键安装
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/bootstrap.sh) params.json
```
安装成功后，系统会自动清理包含敏感 Token 的 `params.json` 文件。

---

## 完成与客户端导入

安装结束后按提示重启服务器使内核与网络优化生效：
```bash
sudo reboot
```
重启后登录，查看服务状态与订阅地址：
```bash
sudo easy_all status
sudo easy_all subscription
```

- 将 `easy_all subscription` 输出的订阅链接填入客户端（如 **Mihomo / Clash Verge Rev / Clash Nyanpasu / Box4 / 影** 等）。
- 订阅支持客户端自适应：同一条链接自动识别 UA 下发 Mihomo 规则集配置或通用 Base64。
- 更多客户端配置、规则分流与导入故障排查详见 [客户端使用指南](docs/client-guide.md)。

---

## 常用运维命令

安装完成后，全局注册了 `easy_all` 管理命令：

| 命令 | 用途说明 |
| :--- | :--- |
| `easy_all status` | 查看系统负载、TCP 加速状态、Xray/Nginx 运行状况及订阅地址 |
| `easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `easy_all show` | 输出各节点详细参数、VLESS 链接及 Mihomo 代理配置块 |
| `easy_all apply` | 刷新并重新应用本机配置与订阅（不重复修改云端 DNS 与证书） |
| `easy_all apply-cloud` | 同步云端资源（更新 Cloudflare DNS、重新签发 Origin CA 证书或同步 Worker） |
| `easy_all reality-target [域名:端口]` | 修改 Reality 伪装目标（自动带 SNI 验证 TLS 1.3 连通性并热更新） |
| `easy_all rotate-dynamic-ports` | （Reality 模式）立即轮换并刷新动态端口 NAT 规则 |
| `easy_all refresh-cdn-ips` | 重新调用 Globalping 测试并筛选当期最佳优选 IP |
| `easy_all edit-sub` | 交互式管理用户 Token、配额以及 Worker 聚合订阅设置 |
| `easy_all renew-cert` | 检查并重新签发当前模式的 TLS 证书 |
| `easy_all update-core` | 在线升级 Xray 核心至官方最新稳定版 |
| `easy_all self-update` | 从 GitHub 更新 easy_all 脚本自身至最新主线版本 |
| `easy_all uninstall` | 卸载本机服务与配置（可选 `--purge-cloud` 同步清理 Cloudflare 远端解析与证书） |

---

## 安全机制与防护边界

1. **SSH 自动防护**：
   - 模式 1（Reality）与模式 2（Cloudflare）：安装完成后 SSH 端口自动收敛迁移至 TCP `65533`，UFW 首位阻断 22 端口，并由 Fail2ban 实时监控保护 `65533`。
   - 模式 3（Bunny）与模式 5（组合模式）：保持现有 SSH 监听端口不变。
2. **回源白名单与防扫网**：
   - CDN 模式与组合模式的源站 443 端口仅对 Cloudflare 官方公布的回源 IPv4 网段开放，外部探测无法触达。
3. **恶意流量阻断**：
   - Xray 内部路由自动丢弃局域网私有地址、云厂商元数据网段（如 169.254.169.254）以及异常回环访问。

---

## 文档索引

- [前置准备手册](docs/preparation-guide.md)：域名购买、Cloudflare Zone 解析、API Token 与 Globalping 获取教程
- [安装参数示例](docs/params-examples.md)：各模式的完整 JSON 模板及字段对照表
- [客户端使用指南](docs/client-guide.md)：主流 Mihomo 客户端导入、配置与分流排障
- [运维与排障指南](docs/operations-guide.md)：节点管理、配额控制、证书轮换及疑难解答
- [系统技术参考](docs/technical-reference.md)：架构设计、流控机制与网络实现原理
