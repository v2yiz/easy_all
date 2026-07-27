# easy_reality.sh 使用说明

`easy_reality.sh` 是一个 Debian VPS 一键安装脚本，用于初始化服务器、安装 VLESS Reality Vision 节点，并按需自动部署 Cloudflare Worker、输出 Worker 内容或只输出完整 VLESS 参数。

安装流程会接管整机防火墙配置，生成完整 `/etc/nftables.conf`。请只在专用 VPS 上使用。

仓库另提供基于 sing-box 的单域名 AnyTLS 安装脚本 `easy_anytls.sh`。它会强制校验域名 A 记录、通过 Cloudflare DNS-01 申请和自动续期 Let's Encrypt 证书，并支持 stable、alpha 或指定 sing-box 版本。完整差异、Token 权限与使用说明见 [`any_tls_readme.md`](any_tls_readme.md)。

AnyTLS 一键下载并执行：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_anytls.sh -o easy_anytls.sh && chmod +x easy_anytls.sh && sudo ./easy_anytls.sh install
```

## 功能

- 支持 Debian 12/13 amd64 系统
- 安装基础依赖、XanMod LTS 内核、BBR 和保守 TCP 优化参数
- 安装并配置 Xray VLESS Reality Vision
- 下载 Xray-core 后校验官方 `.dgst` 中的 SHA256，校验失败即中止
- 自动识别 SSH 端口并写入 nftables 放行规则
- 尽力启用 IPv6 配置；没有全局 IPv6 地址时不阻断安装
- 选择每日定时重启策略，使用 `flock` 避免重复执行
- 安装过程中创建系统配置快照；快照完成后的失败会回滚 nftables、crontab 和 BBR/sysctl 配置
- 支持订阅端口模式：
  - `443`：订阅直接暴露 443，默认模式
  - `dynamic`：订阅暴露 `10000-65535` 动态端口；脚本会配置 nftables 转发到本机 443
- 支持三种订阅输出方式：
  - `auto`：自动部署 Cloudflare Worker
  - `worker`：输出 Worker 内容，手动部署
  - `vless`：只输出完整 VLESS 节点参数
- Worker 订阅仅生成 VLESS Reality 节点，支持普通 base64 订阅和 Clash Meta / Mihomo 配置
- Worker 节点使用 `defineNode({...})` 自动注册，手动扩展多节点时不需要维护单独的节点数组
- 支持更新订阅、更新 Xray、查看状态和卸载

## 环境要求

- Debian 12 或 Debian 13
- amd64 架构
- systemd 环境
- root 权限
- 专用 VPS，脚本会管理整机 nftables 防火墙
- 可选：一个解析到本机 VPS 的域名，用作 `NODE_HOST`；不提供时脚本会默认使用当前机器公网 IPv4

不支持容器环境，因为脚本需要安装内核和配置系统级网络。

## 兼容性与测试范围

脚本的系统检查会限制为 Debian 12 及以上 amd64，但目前只在以下环境做过实际测试：

- BandwagonHost（BWG）
- VMISS
- CloudCone
- RackNerd
- Debian 12
- Debian 13

其他 VPS 供应商或其他 Debian 版本未验证，不确定是否支持。非 Debian 系统不支持。

## 快速开始

以下命令默认按非 root 用户写法展示；如果当前已经是 root 用户，可以省略命令开头的 `sudo`。

一键下载并执行：

```bash
curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_reality/main/easy_reality.sh -o easy_reality.sh && chmod +x easy_reality.sh && sudo ./easy_reality.sh install
```

脚本源文件：

```text
https://github.com/v2yiz/easy_reality/blob/main/easy_reality.sh
```

本地已有脚本时执行：

```bash
chmod +x easy_reality.sh
sudo ./easy_reality.sh
```

安装成功后脚本会注册系统命令，后续可直接使用 `sudo easy_reality <命令>`。root 用户可直接执行 `easy_reality <命令>`。

脚本会依次询问：

- 订阅输出方式：自动部署 Worker、输出 Worker 内容手动部署，或只输出完整 VLESS 参数
- 订阅暴露端口模式：`443` 或 `dynamic`；选择只输出 VLESS 参数时固定为 `443`
- 每日定时重启策略：默认每天 4 点、自定义小时，或不配置定时重启
- Reality 目标域名和端口，默认 `swdist.apple.com:443`
- 节点公网地址：可直接回车使用当前机器公网 IPv4；如需 IPv4/IPv6 双栈访问，请填写已配置 A 和 AAAA 记录的域名
- Clash 下载基础名称，默认 `MY_SUB`；仅 Worker 输出模式需要
- Worker 名称和 Cloudflare API 信息；仅自动部署 Worker 时需要

交互提示中如果显示 `[默认值]（回车使用默认值）`，直接回车会把该默认值写入当前变量。

安装完成后，脚本会输出：

- 完整 VLESS 节点链接
- Worker 文件路径、订阅 Token 和手动部署命令；仅 Worker 模式或自动部署失败时输出
- Worker 内容；仅选择输出 Worker 内容时直接打印
- 通用订阅 URL 和 Clash Meta 订阅 URL；仅自动部署成功后输出

脚本自动生成的单节点名称默认为 `MY_VLESS`；手动维护 Worker 多节点时由各节点配置中的 `name` 控制。Clash Meta 订阅下载显示名可通过 `SUB_DOWNLOAD_NAME` 配置，默认 `MY_SUB`，响应内容格式仍是 YAML。

## 命令

首次安装需要使用本地脚本路径；安装成功后会自动注册 `easy_reality` 系统命令，后续示例统一使用注册命令。示例中的 `sudo` 仅用于非 root 用户，root 用户可以省略。

```bash
sudo ./easy_reality.sh install
```

一键初始化系统、安装 Reality，并配置订阅。省略命令时默认执行 `install`。

```bash
sudo easy_reality update-sub
```

重新配置订阅输出。可选择自动部署 Worker、输出 Worker 内容手动部署，或只输出完整 VLESS 参数。

```bash
sudo easy_reality update-xray
```

更新 Xray-core，失败时会恢复原 Xray 二进制。

```bash
sudo easy_reality show
```

显示本机 Reality 节点直连链接。

```bash
sudo easy_reality subscription
```

显示当前订阅信息，包括完整 VLESS 节点链接、通用订阅 URL 和 Clash Meta 订阅 URL。

```bash
sudo easy_reality status
```

显示 Xray、nftables、内核、BBR 和 Worker URL 状态。

```bash
sudo ./easy_reality.sh register-command
```

注册系统命令 `easy_reality`。安装流程成功后会自动注册；这个命令主要用于手动补注册。

```bash
sudo easy_reality uninstall
```

默认删除 Reality/Xray 相关的本机服务、核心、当前配置、日志、状态文件、注册命令和本机 Worker 文件，同时删除 easy_reality 托管的每日重启 cron。使用动态订阅端口时，还会从 nftables 中精确移除 `10000-65535 → 443` 的 Reality 专属转发规则；其他 nftables 规则及 BBR、IPv6、XanMod、时区、NTP、系统软件包均不改动，也不会删除远端 Cloudflare Worker。

```bash
sudo easy_reality uninstall --purge
```

在默认卸载基础上额外删除 `xray-config.*.bak` 等 Reality/Xray 专属历史备份。nftables、sysctl 和 crontab 等服务器初始化备份仍会保留。

远端 Worker 必须单独明确授权，并临时提供 Token：

```bash
sudo DELETE_CLOUDFLARE_WORKER=1 \
  CF_API_TOKEN=your_cloudflare_api_token \
  easy_reality uninstall --purge
```

`uninstall --restore-system` 仅作为旧命令兼容入口保留，现在不会恢复服务器初始化配置。它与默认卸载相同，只清理 Reality 专属动态转发和 easy_reality 定时重启，不处理其他系统配置。

## 无人值守运行

常用变量：

```bash
sudo NODE_HOST=node.example.com \
  SUB_PORT_MODE=443 \
  SUBSCRIBE_MODE=worker \
  ./easy_reality.sh install
```

自动部署 Cloudflare Worker：

```bash
sudo NODE_HOST=node.example.com \
  SUB_PORT_MODE=443 \
  SUBSCRIBE_MODE=auto \
  CF_ACCOUNT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  CF_API_TOKEN=your_cloudflare_api_token \
  WORKER_NAME=easy-reality \
  ./easy_reality.sh install
```

可用变量：

| 变量 | 说明 |
| --- | --- |
| `NODE_HOST` | 客户端连接本机 Reality 节点使用的公网 IPv4 或域名；不提供时默认探测当前机器公网 IPv4。若需要 IPv4/IPv6 双栈访问，必须填写已正确解析 A 和 AAAA 记录的域名 |
| `REALITY_TARGET` | Reality 回落目标，格式为 `域名:端口`，默认 `swdist.apple.com:443`。域名按 DNS label 规则校验，非法连字符位置会被拒绝 |
| `SUB_PORT_MODE` | 订阅暴露端口模式：`443` 或 `dynamic`，默认 `443` |
| `SUB_DOWNLOAD_NAME` | Clash Meta 订阅下载显示名，默认 `MY_SUB`；内容格式仍是 YAML |
| `SUBSCRIBE_MODE` | 订阅输出方式：`auto` 自动部署 Worker；`worker` 输出 Worker 内容供手动部署；`vless` 只输出完整 VLESS 参数。兼容旧值 `manual`，等同 `worker` |
| `CF_ACCOUNT_ID` | Cloudflare Account ID，自动部署时使用 |
| `CF_API_TOKEN` | Cloudflare API Token，自动部署时使用 |
| `WORKER_NAME` | Cloudflare Worker 名称，默认 `easy-reality`。Cloudflare Worker 名称不支持下划线 |
| `REBOOT_SCHEDULE_MODE` | 定时重启策略：`1` 或 `default` 为每天 4 点；`2` 或 `custom` 为自定义小时；`3`、`none`、`off`、`disable` 或 `disabled` 为不配置 |
| `REBOOT_HOUR` | `REBOOT_SCHEDULE_MODE=2` 或 `custom` 时使用，范围 `0-23` |
| `FORCE` | 无人值守卸载时设置为 `1`，跳过交互确认 |
| `DELETE_CLOUDFLARE_WORKER` | `--purge` 时设为 `1`，同时删除远端 Worker；必须提供 `CF_API_TOKEN` |

## 订阅端口模式

默认模式：

```bash
SUB_PORT_MODE=443
```

订阅中直接输出 443 端口。Xray 监听 443，nftables 不写 `10000-65535` 动态端口转发规则。

动态端口模式：

```bash
SUB_PORT_MODE=dynamic
```

订阅中输出 `10000-65535` 动态端口。Xray 仍只监听 443，服务器 nftables 会写入转发规则：

```text
tcp dport 10000-65535 redirect to :443
```

仅重新生成订阅输出时可指定端口模式：

```bash
sudo SUB_PORT_MODE=443 easy_reality update-sub
sudo SUB_PORT_MODE=dynamic easy_reality update-sub
```

`update-sub` 只更新订阅输出和 Worker 状态，不重写 nftables。若从 `443` 切换到 `dynamic`，脚本会先检查本机 nftables 配置或当前 ruleset 是否已有 TCP `10000-65535` 到 443 的转发规则；缺失时会终止，避免生成不可用订阅。

如果 VPS 供应商有独立安全组或云防火墙：

- `SUB_PORT_MODE=443`：只需要放行 TCP 443
- `SUB_PORT_MODE=dynamic`：需要放行 TCP 443 和 TCP `10000-65535`

## Cloudflare Worker 部署

### 自动部署

选择自动部署时，脚本通过 Cloudflare API 上传 module Worker，并写入 `SUB_TOKEN` 加密变量。默认 Worker 名称为 `easy-reality`；重复部署同名 Worker 会覆盖更新，不会创建 `easy-reality-1` 这类新 Worker。

建议 API Token 最小权限：

- Account / Workers Scripts / Edit

脚本会保存 `CF_ACCOUNT_ID` 作为下次默认值，但不会把 `CF_API_TOKEN` 写入状态文件，也不会把它保存为下次默认值。调用 Cloudflare API 时，脚本使用权限为 `0600` 的临时 header 文件传递 Token，避免 Token 出现在 `curl` 命令行参数中。

### 获取 Cloudflare Account ID 和 API Token

自动部署需要两个值：

```text
CF_ACCOUNT_ID
CF_API_TOKEN
```

获取 Account ID：

1. 登录 Cloudflare Dashboard：`https://dash.cloudflare.com`
2. 进入任意域名，或进入 `Workers & Pages`
3. 在右侧概览区域找到 `Account ID`
4. 复制该值，填入脚本提示的 `Cloudflare Account ID`

获取 API Token：

1. 打开 `My Profile` → `API Tokens`
2. 点击 `Create Token`
3. 选择 `Create Custom Token`
4. 设置 Token 名称，例如 `easy-reality-worker`
5. 权限选择：

```text
Account / Workers Scripts / Edit
```

6. Account Resources 选择目标账号，建议只选当前账号
7. 继续确认并创建 Token
8. 复制生成的 Token，填入脚本提示的 `Cloudflare API Token`

无人值守示例：

```bash
sudo NODE_HOST=node.example.com \
  SUBSCRIBE_MODE=auto \
  CF_ACCOUNT_ID=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx \
  CF_API_TOKEN=your_cloudflare_api_token \
  WORKER_NAME=easy-reality \
  easy_reality update-sub
```

注意：

- API Token 只会在本次自动部署请求中使用，不会写入 `/etc/easy_reality/state.env`
- 交互模式下 `Cloudflare API Token` 不会保存为默认值；下次自动部署需要重新粘贴，或用 `CF_API_TOKEN` 环境变量临时传入
- 传入 `CF_API_TOKEN` 后，脚本会取消该变量的 export 属性，并使用临时 header 文件调用 Cloudflare API，降低本机进程参数和子进程环境泄露风险
- 不要使用 Global API Key
- 如果 Token 创建后提示权限不足，优先检查是否选中了正确的 Account Resources
- 自动部署失败时，脚本会保留 `/etc/easy_reality/subscribe-worker.js`，并降级输出手动部署提示

最小配置总结：

```text
权限：
账户 / Workers 脚本 / 编辑

账户资源：
包括 / 你的 Cloudflare Account

区域资源：
不需要

客户端 IP 地址筛选：
留空
```

不需要额外添加 `Workers KV 存储`、`Workers R2 存储`、`Cloudflare Pages`、`Workers 路由`、`账户设置` 等权限。

### 输出 Worker 内容并手动部署

选择 `SUBSCRIBE_MODE=worker` 时，脚本会生成并直接输出 Worker 内容：

```text
/etc/easy_reality/subscribe-worker.js
```

同时输出类似命令：

```bash
npx wrangler deploy /etc/easy_reality/subscribe-worker.js --name easy-reality
npx wrangler secret put SUB_TOKEN --name easy-reality
```

`SUB_TOKEN` 的具体值由脚本输出。执行 `wrangler secret put SUB_TOKEN` 时粘贴该值。

部署完成后的订阅 URL 形如：

```text
https://easy-reality.<你的 workers.dev 子域>.workers.dev/subscribe?token=<订阅 Token>
https://easy-reality.<你的 workers.dev 子域>.workers.dev/subscribe?token=<订阅 Token>&flag=clash
https://easy-reality.<你的 workers.dev 子域>.workers.dev/subscribe?token=<订阅 Token>&node=all
https://easy-reality.<你的 workers.dev 子域>.workers.dev/subscribe?token=<订阅 Token>&node=all&flag=clash
```

默认情况下，Worker 只输出 `DEFAULT_NODE` 指向的节点。追加 `node=all` 后会输出 `CONFIGS` 中自动注册的全部节点；普通订阅返回多条 VLESS 链接的 base64 内容，`flag=clash` 返回 Clash Meta / Mihomo YAML。

### Worker 多节点维护

生成的 Worker 模板使用自动注册模式：

```js
const CONFIGS = [];

function defineNode(config) {
    CONFIGS.push(config);
    return config;
}

const NODE_A_CONFIG = defineNode({
    type: 'vless',
    uuid: '...',
    host: 'node-a.example.com',
    name: 'NODE_A',
    fp: 'chrome',
    sni: 'www.example.com',
    pbk: '...',
    sid: '0123456789abcdef'
});

const DEFAULT_NODE = NODE_A_CONFIG;
```

新增节点时只需要继续调用 `defineNode({...})`。`DEFAULT_NODE` 决定不带 `node=all` 时默认输出哪个节点；`node=all` 会输出所有已注册节点。

仓库中的 `sample-worker.js` 是脱敏样例，保留了多节点、普通订阅、`flag=clash` 和 `node=all` 逻辑。公开分享或二次修改时建议以该文件为起点，不要直接发布包含真实 Token、UUID、Reality 公钥或域名的 Worker。
样例同时演示了 `security: 'reality'` 的 VLESS Reality Vision 和 `security: 'tls'` 的 VLESS TCP TLS Vision 节点；TLS Vision 节点需要使用已配置证书的域名和 443 端口。

### 使用自定义域名、Worker 路由和 DNS

如果已经在 Cloudflare 托管域名，并希望使用自己的域名访问订阅地址，例如：

```text
https://sub.example.com/subscribe?token=<订阅 Token>
https://sub.example.com/subscribe?token=<订阅 Token>&flag=clash
https://sub.example.com/subscribe?token=<订阅 Token>&node=all
https://sub.example.com/subscribe?token=<订阅 Token>&node=all&flag=clash
```

需要在 Cloudflare Dashboard 中额外配置 DNS 和 Worker 路由。脚本只负责生成或部署 Worker，不会自动创建自定义域名、DNS 记录或 Worker Route。

推荐做法：

1. 在 Cloudflare DNS 中添加订阅域名记录，例如 `sub.example.com`
2. 记录类型可以使用 `CNAME`，目标填任意占位主机名，例如 `workers.dev`
3. 确认该 DNS 记录开启代理，即橙色云朵 `Proxied`
4. 进入 `Workers & Pages` → 选择已部署的 Worker，例如 `easy-reality`
5. 打开 `Settings` → `Triggers` → `Routes`，添加路由：

```text
sub.example.com/*
```

6. 保存后，用自定义域名访问订阅路径：

```text
https://sub.example.com/subscribe?token=<订阅 Token>
https://sub.example.com/subscribe?token=<订阅 Token>&flag=clash
https://sub.example.com/subscribe?token=<订阅 Token>&node=all
https://sub.example.com/subscribe?token=<订阅 Token>&node=all&flag=clash
```

注意：

- Worker Route 必须匹配完整访问域名和路径。若只希望订阅路径进入 Worker，也可以配置为 `sub.example.com/subscribe*`
- DNS 记录必须开启 Cloudflare 代理；如果是灰色云朵 `DNS only`，请求不会进入 Worker
- 自定义域名只影响订阅入口，不改变客户端连接 Reality 节点使用的 `NODE_HOST`
- 如果 `NODE_HOST` 也使用域名，请确保它解析到 VPS；订阅域名和节点域名可以相同，也可以分开

### 只输出 VLESS 参数

选择 `SUBSCRIBE_MODE=vless` 时，脚本只输出完整 VLESS 节点链接，不生成 Worker 内容，也不部署 Cloudflare Worker。

## 文件位置

| 路径 | 说明 |
| --- | --- |
| `/etc/easy_reality/state.env` | 本机状态，包含 `NODE_HOST`、`SUB_TOKEN`、`WORKER_NAME`、`WORKER_URL`、`CF_ACCOUNT_ID`、`DEPLOY_MODE`、`SUB_PORT_MODE`、`SUB_DOWNLOAD_NAME` |
| `/etc/easy_reality/subscribe-worker.js` | 生成的 Worker 文件 |
| `/etc/easy_reality/backups/` | 安装和更新过程中的备份 |
| `/etc/v2ray-agent/xray/xray` | Xray 二进制 |
| `/etc/v2ray-agent/xray/config.json` | Xray 配置 |
| `/etc/systemd/system/xray.service` | Xray systemd 服务 |
| `/etc/nftables.conf` | 整机 nftables 防火墙配置 |
| `/etc/sysctl.d/99-bbrv3.conf` | BBR/sysctl 配置 |
| `/etc/sysctl.d/99-enable-ipv6.conf` | IPv6 兼容配置 |
| `/usr/local/lib/easy_reality/easy_reality.sh` | 注册系统命令时安装的脚本副本 |
| `/usr/local/bin/easy_reality` | 系统命令入口 |

仓库内还提供脱敏样例：

| 路径 | 说明 |
| --- | --- |
| `sample-worker.js` | 脱敏 Worker 样例，适合公开参考或作为多节点手动维护模板 |

## 防火墙说明

脚本会生成整机 nftables 配置，并启用 `nftables.service`，重启后自动加载。

放行内容：

- loopback
- established/related 连接
- ICMP/ICMPv6
- 自动识别到的 SSH 端口
- TCP 80
- TCP 443
- `SUB_PORT_MODE=dynamic` 时额外转发 TCP `10000-65535` 到 443

安装流程会生成完整 nftables 配置。`update-sub` 不重写 nftables，只负责重新配置订阅输出；切换到 `SUB_PORT_MODE=dynamic` 时会校验动态端口转发规则是否已存在。

SSH 端口来源会合并：

- 当前 `SSH_CONNECTION`
- `sshd -T`
- `/etc/ssh/sshd_config`
- `/etc/ssh/sshd_config.d/*.conf`

## TCP 参数说明

脚本会写入 `/etc/sysctl.d/99-bbrv3.conf`，并通过 `sysctl -p` 立即应用。

核心参数：

```text
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
```

保守增强参数：

```text
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 4096
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
```

这些参数用于提升监听队列、突发包处理、长连接空闲后恢复和发送队列控制。脚本没有默认修改 `tcp_tw_reuse`、`tcp_fin_timeout`、`tcp_syn_retries` 等更激进或更依赖场景的参数。

## 安装回滚与完整性校验

安装流程会在基础包安装和系统时间配置完成后创建失败回滚快照。快照完成后的任一步失败，脚本会在退出前尝试恢复：

- `/etc/nftables.conf`
- 当前用户的 `crontab`
- `/etc/sysctl.d/99-bbrv3.conf`

Xray-core 下载流程会同时下载官方发布的 `.dgst` 文件，并校验 zip 文件的 SHA256。校验文件下载失败、SHA256 解析失败或校验不一致时，脚本会停止安装或更新，不会安装该二进制。

## 敏感信息处理

- `CF_API_TOKEN` 不会写入 `/etc/easy_reality/state.env`，也不会保存为下次默认值。
- `CF_API_TOKEN` 调用 Cloudflare API 时通过权限为 `0600` 的临时 header 文件传递；临时文件会随脚本退出清理。
- `SUB_TOKEN` 是订阅访问凭据，会保存到 `/etc/easy_reality/state.env`，该文件权限为 `0600`。
- Reality 私钥保存在 `/etc/v2ray-agent/xray/config.json`，该文件权限为 `0600`。
- 手动部署 Worker 时，脚本会在终端输出 `SUB_TOKEN` 和 Worker 内容；请只在可信终端中执行，并避免把终端输出发布到公开位置。

## 验证

查看服务状态：

```bash
sudo easy_reality status
```

查看 nftables：

```bash
sudo nft list ruleset
```

查看 Xray：

```bash
sudo systemctl status xray --no-pager
```

查看订阅：

```bash
sudo easy_reality subscription
```

查看 TCP 参数：

```bash
sysctl net.core.default_qdisc
sysctl net.ipv4.tcp_congestion_control
sysctl net.core.netdev_max_backlog
sysctl net.core.somaxconn
sysctl net.ipv4.tcp_fastopen
sysctl net.ipv4.tcp_slow_start_after_idle
sysctl net.ipv4.tcp_notsent_lowat
```

## 故障排查

### 脚本提示需要重启

XanMod 内核安装后需要重启才会进入新内核：

```bash
sudo reboot
```

重启后检查：

```bash
uname -r
sysctl net.ipv4.tcp_congestion_control
```

### 订阅能打开但节点不可用

检查：

```bash
sudo systemctl status xray --no-pager
sudo nft list ruleset
sudo easy_reality show
```

确认：

- 使用域名作为 `NODE_HOST` 时，确认已解析到 VPS；双栈访问需要同时配置 A 和 AAAA 记录
- VPS 供应商安全组放行 443
- 使用动态端口时安全组也放行 `10000-65535`
- 如果通过 `update-sub` 从 `443` 切换到 `dynamic`，确认脚本没有提示缺少 `tcp dport 10000-65535 redirect to :443`

### 自动部署失败

脚本会保留 Worker 文件，可切换手动部署：

```bash
sudo SUBSCRIBE_MODE=worker easy_reality update-sub
```

如果 Cloudflare 返回权限错误，优先检查：

- API Token 是否完整复制
- 权限是否包含 `Account / Workers Scripts / Edit`
- Account Resources 是否选中了正确账号
- 客户端 IP 地址筛选是否留空，或是否包含当前 VPS 出口 IP

### 安装或 nftables 配置失败

安装流程会先校验候选 `/etc/nftables.conf`，再覆盖系统配置并重启 `nftables.service`。如果快照完成后的安装步骤失败，脚本会尝试恢复安装前的 nftables、crontab 和 BBR/sysctl 配置并终止安装。

修复防火墙问题后重新执行：

```bash
sudo ./easy_reality.sh install
```

## 注意事项

- 本脚本适合全新或专用 Debian VPS，不建议在已有复杂防火墙规则的机器上使用。
- `SUB_TOKEN` 是订阅访问凭据，请不要公开。
- `CF_API_TOKEN` 不会写入状态文件，但自动部署时会传给 Cloudflare API；建议优先使用交互输入，避免把真实 Token 写入 shell 历史。
- `WORKER_TEMPLATE_SHA256` 是脚本内置 Worker 模板完整性校验值，不是用户配置项。
- `uninstall` 和 `uninstall --purge` 不会恢复服务器初始化配置，只会额外清理可精确识别的 easy_reality 定时重启和 Reality 动态端口转发。
- `uninstall --purge` 只额外清理 Reality/Xray 专属备份；远端 Worker 仍需显式设置 `DELETE_CLOUDFLARE_WORKER=1`。

## 个人服务器初始化脚本

仓库中同时提供 `debian_init.sh`，这是个人使用的 Debian 服务器初始化脚本，和 Reality / Xray / Worker 部署流程无关。

它面向新 Debian 服务器的基础加固和日常环境准备，主要做：

- 使用初始 SSH 用户连接服务器，默认 `root`
- 创建或更新用户输入的普通用户，并配置需要密码的 `sudo`
- 写入同一把 SSH 公钥，让最终 `ssh_config` 默认以普通用户登录
- 执行 `apt update` / `apt upgrade`
- 安装基础包，包括 `vim`、`tmux`、`curl`、`wget`、`git`、`build-essential`、`sudo`、`ufw`、`systemd-timesyncd`
- 按个人偏好安装 XanMod LTS、BBRv3 和 TCP 参数
- 设置时区为 `Asia/Shanghai` 并启用时间同步
- 为普通用户安装 `uv` 和 Python 3.12
- 放行 TCP `80`、`443`、`8080`、`8443`、`8888`，以及当前和最终 SSH 端口
- 禁用 SSH 密码登录，保留密钥登录

使用方式：

```bash
chmod +x debian_init.sh
./debian_init.sh
```

注意：`debian_init.sh` 是个人初始化脚本，不会安装 Reality 节点，不会生成订阅，不会部署 Cloudflare Worker。需要安装 Reality 时仍使用 `easy_reality.sh`。

### 换电脑后的 SSH 处理

如果新电脑还能拿到原来的 SSH 私钥，把私钥和 `~/.ssh/config` 恢复到新电脑即可。私钥权限需要保持为 `0600`：

```bash
mkdir -p ~/.ssh
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
```

如果原私钥丢失，但旧电脑还有已登录的服务器会话，可以在新电脑生成新密钥，把新公钥追加到服务器普通用户的 `~/.ssh/authorized_keys`。

如果原私钥丢失，也没有任何已登录会话，因为脚本会禁用 SSH 密码登录，需要通过 VPS 厂商控制台、VNC 或 Rescue Mode 进入系统，再把新公钥写入普通用户：

```bash
install -d -m 0700 -o v2yiz -g v2yiz /home/v2yiz/.ssh
echo '你的新公钥内容' >> /home/v2yiz/.ssh/authorized_keys
chown v2yiz:v2yiz /home/v2yiz/.ssh/authorized_keys
chmod 0600 /home/v2yiz/.ssh/authorized_keys
```

建议把 SSH 私钥做加密离线备份。不要只保存在一台电脑上。
