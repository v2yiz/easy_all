# 前置准备手册

本手册覆盖 Cloudflare + Globalping CDN XHTTP 部署所需的域名、账号、DNS 和 Token 准备。

本手册把域名、Cloudflare 和 Globalping 的一次性准备合并在一起，供 Cloudflare CDN 精选 IP XHTTP
模式（模式 2）使用；Globalping 账号和 Token 也适用于 AWS/Gcore 精选 IP 模式（模式 4/5）。
手册只覆盖注册、DNS、账号权限和 Token 准备，不包含 VPS 命令。完成后再回到
[README 的安装说明](../README.md) 执行安装。

## 1. 先注册域名并交给 Cloudflare 托管

### 1.1 注册域名

域名注册商可以自行选择。参考文章使用 [Spaceship](https://www.spaceship.com/) 演示购买
`.xyz` 域名；本项目并不要求使用 Spaceship 或 `.xyz`，也不保证文章中的活动价格。注册前请同时
确认首年价格、续费价格、隐私保护、付款方式以及是否满足你所在地区的合规要求。

按参考文章第 1 节整理后的通用流程如下：

1. 打开 [Spaceship](https://www.spaceship.com/) 或你选定的注册商，注册账号并完成邮箱验证。
   如果注册商当前要求手机号、实名或其他验证，以注册商页面为准。
2. 搜索一个自己能长期使用的根域名，例如 `example.com`。本项目需要根域名控制权，后续会在
   它下面使用 `node.example.com` 这样的一级子域名。
3. 对比首年和续费价格后再下单。若需要长期使用，可以在注册商允许的范围内一次续费多年；不要
   只根据首年促销价判断长期成本。
4. 保存注册商账号、域名到期日和恢复邮箱。不要把注册商密码、付款信息或后续 API Token 写入
   仓库。

下面的截图是参考文章中的界面示例；Spaceship 的页面、价格和中文文案可能已经变化。

![Spaceship 注册账号示例](preparation/spaceship-signup.png)

![Spaceship 搜索可注册域名示例](preparation/spaceship-domain-search.png)

### 1.2 在 Cloudflare 注册账号并添加域名

1. 打开 [Cloudflare 注册页](https://dash.cloudflare.com/sign-up)，使用邮箱和密码创建账号，并按提示
   完成邮箱验证。
2. 进入 [Cloudflare Dashboard](https://dash.cloudflare.com/)，选择 **Add a domain**，输入刚注册的
   根域名，例如 `example.com`。
3. 选择 **Free** 计划即可。本项目的 Cloudflare 配置不要求购买付费计划。

![Cloudflare 添加域名示例](preparation/cloudflare-add-domain.png)

Cloudflare 会为这个 Zone 分配两条名称服务器（Nameservers）。先完整复制并保存这两条值；不要把
`node.example.com` 的 DNS 记录提前建好，安装器需要检查并创建唯一的 proxied `A` 记录。

### 1.3 在注册商修改名称服务器

回到域名注册商的 DNS/Nameservers 页面，把根域名现有的权威名称服务器完整替换为 Cloudflare 显示的
两条名称服务器，然后保存。

![Cloudflare 名称服务器示例](preparation/cloudflare-nameservers.png)

等待注册商和公共 DNS 更新，直到 Cloudflare 中该 Zone 的状态变为 **Active**。名称服务器切换期间，
如果域名还承载网站或邮件，请先记录原有的 `A`、`AAAA`、`CNAME`、`MX`、`TXT`、SPF、DKIM、DMARC
和 CAA 记录；遗漏邮件记录可能导致收发信中断。

参考文章：[48元撸10年xyz域名，搭配Cloudflare有N王炸玩法](https://post.smzdm.com/p/ae5rg7nk/)
（第 1、2 节）。文中截图仅用于说明操作位置，最终以注册商和 Cloudflare 当前页面为准。

### 1.4 本项目对域名的要求

- Cloudflare 模式使用一个 Zone 和一个一级子域名，例如 `node.example.com`；根域名本身只用于
  托管 Zone，不作为客户端节点名。
- `node.example.com` 不要预先创建 DNS 记录；独立订阅域名（如使用）也必须位于同一个 Zone 下。
- 注册商可以留在原处；Cloudflare 需要的是整个根域名的权威 DNS 委派，而不是把域名所有权转入
  Cloudflare。
- 如果 Cloudflare Zone 尚未 **Active**，先完成名称服务器切换，不要继续创建 Token 或运行安装器。

## 2. 注册 Globalping 并创建 Access Token

Globalping 用于从中国大陆的电信、联通和移动探针筛选可用的 CDN IPv4。注册 Globalping 不需要
单独填写一套账号密码：打开 [Globalping Dashboard](https://dash.globalping.io/)，点击
**Sign in with GitHub**；如果还没有 GitHub 账号，可先在 [GitHub 注册页](https://github.com/signup)
创建账号。

### 2.1 注册/登录

1. 打开 [Globalping Dashboard](https://dash.globalping.io/)。
2. 选择 **Sign in with GitHub**，在 GitHub 页面完成登录和授权。
3. 返回 Dashboard，确认能够看到自己的账号和用量信息。

### 2.2 创建 Access Token

1. 登录后打开 [Dashboard Tokens](https://dash.globalping.io/tokens)。
2. 选择 **Generate a new token**，填写用途名称，例如 `easy_all_cloudflare_cdn`。
3. 创建后立即复制 Token；完整 Token 通常只在创建时显示。
4. 安装 Cloudflare 精选 IP 模式时，把它粘贴到安装器的 `Globalping Token` 输入框。

### 2.3 安全保管

- 不要把 Token 提交到 Git、写进 README、截图或公开日志。
- 不要在聊天、Issue 或其他公开渠道发送 Token。
- 怀疑泄露时，立即在 [Globalping Tokens](https://dash.globalping.io/tokens) 撤销并重新创建。

## 3. Cloudflare 安装前准备

1. 在已经 **Active** 的 Zone 下准备客户端连接的 CDN 节点域名，例如 `node.example.com`。不要预先创建这个名称的 DNS 记录。
2. 进入目标 Zone 的 **Network → gRPC**，将 **gRPC** 手动切换为 **On**。这是 XHTTP
   `stream-up` 的必需条件，Cloudflare 当前没有可用于该开关的 Zone Settings API，安装器无法代办。
3. 如果部署独立订阅域名，它也必须是同一 Zone 下的一级子域名。

安装、`apply-cloud` 和 `refresh-cdn-ips` 会主动发送 gRPC 形态的边缘请求检查该开关。若收到
`403 text/html`，命令会停止并明确提示开启 gRPC。普通 `/easy_all-health` 返回 HTTP 200
不能证明 gRPC 已开启；若订阅可以下载、所有 XHTTP 节点却同时超时，应首先复查此开关。

## 4. 只创建一个 Cloudflare API Token

进入 **My Profile → API Tokens → Create Token → Custom Token**，资源选择：

```text
Include → Specific zone → example.com
```

仅添加以下六项权限：

| 权限 | 用途 |
| --- | --- |
| `Zone / Zone / Read` | 识别并验证目标 Zone |
| `Zone / DNS / Edit` | 管理节点和订阅 DNS 记录 |
| `Zone / Transform Rules / Edit` | 管理回源密钥规则 |
| `Zone / Config Rules / Edit` | 设置 Full (strict) |
| `Zone / Zone Settings / Edit` | 启用 origin HTTP/2 |
| `Zone / SSL and Certificates / Edit` | 签发、轮换和吊销 Origin CA 证书 |

![Cloudflare API Token 的六项最小权限与单 Zone 资源范围](cloudflare/cloudflare-api-token-easy-all.svg)

创建后立即复制 Token，并粘贴到安装器的 `Cloudflare API Token` 输入框。Token 只在当前进程使用，
不会写入状态文件；请勿选择所有 Zone，也不要添加其他权限。

## 5. 安装器会自动完成的事项

- 创建唯一的 proxied `A` 记录，指向 VPS 公网 IPv4。
- 签发 15 年 Origin CA 证书并配置 Full (strict)。
- 开启 origin HTTP/2，并写入 XHTTP 回源密钥规则。
- 验收 Cloudflare gRPC 边缘请求；开关未开启时立即停止并提示前往控制台处理。
- 仅允许 Cloudflare 官方 IPv4 段访问 VPS 的 TCP 443。
- 每小时读取 Cloudflare 官方 IPv4 CIDR，拆分为 `/24` 后轮换抽样 120 个地址。
- VPS 先并发验证候选的 SNI、HTTPS、HTTP/2 和 `/easy_all-health`，排除官方地址范围中未提供
  CDN 入口的地址；再按 Globalping 当前剩余免费额度限制本轮测量规模，避免耗尽额度。
- 使用中国电信 `AS4134`、中国联通 `AS4837`、中国移动 `AS9808` 的 Globalping
  `eyeball-network` 探针执行 TCP/443 零丢包预筛，每个运营商最多保留 6 个候选。
- 最终最多发布 18 个 IP 节点。
- 订阅始终额外保留一个原始域名兜底节点。客户端 Mihomo 每 600 秒测速，候选快至少
  50 ms 才切换；所有节点的 SNI 和 XHTTP Host 始终使用节点域名。
- 测量失败继续使用上次有效缓存；缓存超过 72 小时则回退到节点域名。

安装器不会覆盖其他 DNS 记录或规则。发现同名记录、规则歧义或权限不足时会停止并保留本机状态。

## 6. 费用与使用边界

上述能力可在 Cloudflare Free Zone 使用；域名注册费和 VPS 费用另计。本项目不会自动启用任何
按量计费的增值产品，也不承诺固定的月度 CDN 流量额度。

| 项目 | 说明 |
| --- | --- |
| 基础 CDN 费用 | Free Zone 本身无月费；Token、proxied DNS、Universal SSL、Origin CA、HTTP/2、gRPC 和规则配置不单独收费。 |
| 可用流量 | 没有可据此保证的固定 GB 上限；实际受 Cloudflare 服务条款、账户风控、VPS 带宽和连接质量共同限制。 |
| 单次请求 | Free/Pro 的请求体上限为 **100 MB**；长连接或大流量不等于获得无限制隧道能力。 |
| 额外费用 | 只有自行启用 Argo、WAF、Bot Management 等增值产品时，相关流量才可能产生额外费用；本项目不启用它们。 |

本链路是实时 XHTTP 转发，数据不会因为 CDN 缓存而减少 VPS 出口流量。建议先按目标用户数、峰值并发、
VPS 出口带宽和每用户配额估算容量，再进行低速、长连接和持续传输测试。Cloudflare 的条款、流量限制
和风控优先于本说明。

## 7. 卸载

`sudo easy_all uninstall` 只清理本机。`sudo easy_all uninstall --purge-cloud` 会先使用同一枚
Token 吊销 Origin CA 证书，成功后才清理本机；远端 DNS 和规则仍需按需在控制台处理。

官方参考：[Origin CA](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/)、
[Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)、
[gRPC](https://developers.cloudflare.com/network/grpc-connections/)、
[Transform Rules](https://developers.cloudflare.com/rules/transform/)、
[Cloudflare IP 地址](https://www.cloudflare.com/ips/)。
