# VPS 本机订阅聚合

`easy_all aggregate` 启动前台 HTTP 服务，仅监听 `127.0.0.1:8788`，通过现有 Nginx 的 `/aggregate` 对外服务。需要 Node.js 18+，无 npm 依赖。保留原 `/subscribe` 和优选刷新任务。

## 配置

将原 `worker-src/config.local.json` 的内容复制到 VPS 的 `/etc/easy_all/aggregate.json`，权限设为 `0600`。不要覆盖 `/etc/easy_all/state.env`。

也可以从本目录的 [aggregate.example.json](aggregate.example.json) 开始。安装或 self-update 后，示例位于 `/usr/local/lib/easy_all/aggregate/aggregate.example.json`。首次创建配置（已有文件时不要覆盖）：

```bash
sudo test -e /etc/easy_all/aggregate.json || sudo install -m 600 /usr/local/lib/easy_all/aggregate/aggregate.example.json /etc/easy_all/aggregate.json
sudo nano /etc/easy_all/aggregate.json
```

- `allowedTokens`：用户名到聚合令牌的映射，令牌至少 16 字符且不能重复。替换示例令牌，可用 `openssl rand -hex 24` 生成。
- `upstreamUrl`：替换成真实的 XFLASH HTTPS 订阅地址。
- `nodes`：额外的 Reality 节点，默认空数组，仅聚合本机 CF 节点和 XFLASH；需要原 Worker 的 Reality 节点时，把旧配置的 `nodes` 数组复制过来。

示例无需 `vpsCdnUrl` 或 `fallbackCdnNodes`。本机 CF 节点不需要填写到 JSON 中。

沿用 `allowedTokens`、`nodes`、`upstreamUrl`；其中 Reality 节点仍按原 Worker 规则生成，XFLASH 仍联网获取。`vpsCdnUrl` 和 `fallbackCdnNodes` 在 VPS 模式忽略，CF 节点直接读取 `/var/www/easy_all/subscriptions/base64.txt`。若没有共享文件，则读取对应 `allowedTokens` 用户名目录中的 `base64.txt`，不会回退到 owner。按用户配额部署必须保证 JSON 用户名与 VPS 账户一致；额外 Reality 和 XFLASH 节点仍按原配置共享，不受本机 CF 配额控制。

模板复用 `/usr/local/lib/easy_all/templates/mihomo.yaml`。JSON 和模板每次请求重新读取，修改无需重启；无效配置或本地订阅返回 503，避免继续下发旧凭据。XFLASH 失败保留原来的本地节点降级行为。执行 self-update 会更新模板，修改前请保留备份。

可指定其他配置路径：`sudo easy_all aggregate /etc/easy_all/other.json`。每台机器只能运行一个监听 8788 的实例。

## 已安装 Cloudflare 模式的部署步骤

先将配置安全复制到上述路径，然后在 VPS 执行：

```bash
sudo easy_all self-update
sudo apt-get install -y nodejs
sudo chmod 600 /etc/easy_all/aggregate.json
sudo install -m 644 /usr/local/lib/easy_all/aggregate/easy_all-aggregate.service /etc/systemd/system/easy_all-aggregate.service
sudo systemctl daemon-reload
sudo systemctl enable --now easy_all-aggregate
sudo easy_all apply-cloud
```

本次首次接入需要 `apply-cloud`：它生成 Nginx 新路径，并为 `/aggregate` 同步 Cloudflare 源站校验头规则，需要现有云端凭证，且会应用本机配置和托管云资源。之后只改聚合 JSON 不需要再运行 apply-cloud。新安装已包含路径和转换规则。

订阅地址使用现有 VPS 订阅域名和 `aggregate.json` 中的 token：

```text
https://你的VPS订阅域名/aggregate?token=你的聚合令牌
```

不要填写原 Worker 聚合域名。无需 flag；Clash/Mihomo/Stash UA 返回 YAML，其余默认 Base64。原 Worker 的 flag 与 node 参数仍兼容。

确认 `X-Easy-All-Version: vps-aggregate` 和 `X-Easy-All-CDN-Nodes`。进程状态查看 `sudo systemctl status easy_all-aggregate`，启动错误查看 `sudo journalctl -u easy_all-aggregate -n 30`；503 时检查 JSON、模板、本地订阅文件和用户映射。

卸载聚合服务先执行 `sudo systemctl disable --now easy_all-aggregate`，再移除对应 unit；配置保留供恢复。聚合可选服务独立于现有 Xray/Nginx 服务。
