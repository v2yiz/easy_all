# 运维与排障指南

本文档介绍 `easy_all` 安装完成后的日常维护、配置更新、用户管理、证书轮换及常见故障排查。

---

## 1. 软件更新与配置应用

### 1.1 更新 easy_all 脚本
```bash
sudo easy_all self-update
```
- `self-update` 仅从 GitHub 拉取并替换安装器自身的代码，不会擅自重启服务或修改现有配置。
- 默认跟随 `main` 分支；若需测试开发版可加 `--dev` 参数。

### 1.2 重新应用本地配置
当脚本更新后包含本地配置调整，或需要刷新 Xray / Nginx 运行时：
```bash
sudo easy_all apply
```
- 重新渲染并应用本机 Xray 配置、Nginx 站点、本地订阅与 UFW 规则。
- 不会重复向 Cloudflare 请求签发证书或修改 DNS。

### 1.3 同步云端资源（直连+CDN兜底）
如果更改了域名、需要同步云端解析或重新签发证书：
```bash
sudo easy_all apply-cloud
```
- 会重新校验并同步 Cloudflare 的云端 DNS 记录与 Origin CA 证书配置。

---

## 2. 常用管理命令速查表

| 命令 | 说明 |
| :--- | :--- |
| `sudo easy_all status` | 查看系统运行状况、TCP 加速激活状态、Xray/Nginx 服务及端口 |
| `sudo easy_all subscription` | 查看节点信息与所有用户的专属订阅链接 |
| `sudo easy_all show` | 打印当前节点链接（VLESS URI）与 Mihomo YAML 配置片段 |
| `sudo easy_all reality-target [域名:端口]` | （Reality / 直连+CDN兜底）修改伪装目标 SNI，带 TLS 1.3 自动握手验证 |
| `sudo easy_all rotate-dynamic-ports` | （Reality 模式）立即轮换并刷新动态端口 NAT 重定向规则 |
| `sudo easy_all refresh-cdn-ips` | （直连+CDN兜底）重新调用 Globalping 探针优选最新 CDN IP |
| `sudo easy_all edit-sub` | 交互式编辑订阅配置（用户 Token + 聚合节点）与订阅模板 |
| `sudo easy_all renew-cert` | 检查并重新签发当前模式的 TLS 证书 |
| `sudo easy_all update-core` | 在线升级 Xray 核心至官方最新版本，并自动重载服务 |
| `sudo easy_all cleanup-partial` | 清理安装中断留下的临时残留（不影响云端资源） |
| `sudo easy_all uninstall` | 卸载本机服务与配置；加 `--purge-cloud` 会同步清理云端资源。卸载只回收业务端口与回源白名单，保留 UFW 启用状态、默认策略、SSH 放行与 Fail2ban 配置 |

---

## 3. TCP 加速（Skyline Speeder）

- amd64 与 arm64 平台安装时前置配置并启用 [Skyline Speeder](https://github.com/CYBERVERSE-Research/skyline-speeder)；不再提供 BBR/XanMod 方案。
- **内核要求**：Skyline 要求 Linux 6.12+。若系统内核较低，安装器会自动升级 Zabbly 6.12+ LTS 内核。
- **状态确认**：
  - 安装后若提示重启，执行 `sudo reboot`；
  - 重启后运行 `sudo easy_all status`，显示 `Skyline Speeder: active` 即表示已成功加速。
  - 若显示 `degraded`，说明 Skyline 未生效（拥塞控制回落到内核默认值），网络连接不受影响。执行 `sudo easy_all apply` 可尝试修复；修复后仍会校验 `skyline_cc` 是否真的生效。

---

## 4. 节点与伪装目标管理

### 4.1 更换 Reality 伪装目标（SNI）
```bash
sudo easy_all reality-target swdist.apple.com:443
```
- 命令会自动通过 `xray tls ping` 验收新目标的 TLS 1.3 握手连通性与 ASN 归属，验证通过后原子替换配置并重载 Xray。
- 随后客户端刷新订阅即可获取新 SNI。

### 4.2 轮换 VLESS UUID
如需更换节点 UUID：
```bash
sudo env VLESS_UUID="$(cat /proc/sys/kernel/random/uuid)" easy_all apply
```
执行后旧 UUID 立即失效，请在客户端更新订阅。

---

## 5. 订阅与多用户管理

执行交互式管理（直连 Reality 的部署订阅与直连+CDN兜底共用同一份订阅配置）：
```bash
sudo easy_all edit-sub
```

- **订阅配置**：按提示输入一份 JSON，同时包含 `allowedTokens`（用户 Token 字典）与 `nodes`（聚合节点数组）。省略的用户或节点会被删除；完成后各用户的专属订阅链接可通过 `sudo easy_all subscription` 查看。
- **聚合节点**：`nodes` 支持 `vless`（`reality/tcp` 或 `tls/xhttp`）与 `mieru`；示例见 `templates/aggregation.example.json`。`optional: true` 的节点仅在订阅 URL 追加 `&node=all` 时下发。`tls/xhttp` 节点里 `host` 是客户端连接地址（可用 CDN 优选 IP），`sni` 同时作为 TLS SNI 与 HTTP `Host` 头，因此必须填代理域名的真实域名；`reality/tcp` 节点的 `sid` 需为 2-16 位偶数长度十六进制。
- **自定义模板**：支持交互式切换或重载 Mihomo 订阅模板。

---

## 6. 卸载与清理

### 6.1 仅卸载本机服务
```bash
sudo easy_all uninstall
```
停止 Xray 与 Nginx，删除 easy_all 自有配置、证书与定时任务，回收 easy_all 注入的业务端口（443/8443）与回源白名单，保留 UFW 启用状态、默认拒绝策略、SSH 放行与 Fail2ban 配置（`/usr/local/sbin/fail2ban-ufw-cidr.sh` 脚本保留），恢复安装前的 IPv6 配置，保留云端资源（若未加 `--purge-cloud`）。前置初始化不回收：Zabbly 内核与 APT 仓库、Skyline Speeder 及其 fq 服务、`/etc/sysctl.d/99-easy_all-tcp.conf`、1GB Swap、系统依赖与 Nginx `worker_processes 1;` 收敛均保留。

### 6.2 完整卸载（含云端资源清理）
```bash
sudo easy_all uninstall --purge-cloud
```
自动调用 API 清理本次安装在云端创建的托管资源（清理节点 DNS 解析与 Origin CA 证书）。

### 6.3 独立清理 Cloudflare 残留
若 VPS 已销毁或状态丢失，可使用独立命令清理账户内 easy_all 标记的资源：
```bash
sudo easy_all purge-cloudflare --domain example.com
```

---

## 7. 常见问题排查

| 现象 / 报错 | 常见根因与解决办法 |
| :--- | :--- |
| **SSH 断开后重连失败** | - 检查服务商后台云防火墙/安全组是否已放行 SSH 端口（默认 22）。<br>- 检查 UFW 状态及 Fail2ban 是否因多次认证失败暂时封禁了客户端 IP。 |
| **重跑提示 TCP 80/443 被占用** | 有 easy_all 残留时按提示执行 `sudo easy_all cleanup-partial`；只报了「easy_all 仅支持专用 VPS」说明占用者是第三方进程（多为本机自用 Nginx），先确认归属再处理。 |
| **安装中断提示「继续上次安装」** | 直连+CDN兜底支持断点续装，回车选择 `Y` 即可复用已生成的证书和密钥快速继续安装；选 `n` 则清理重装。 |
| **Cloudflare Zone 校验失败** | 域名在 Cloudflare 控制台必须处于 **Active**（已保护）状态，不能仅停留在待更名或待验证阶段。 |
| **提示未开启 gRPC** | 直连+CDN兜底必须在 Cloudflare 控制台手动开启：进入域名 Zone → **Network** → 将 **gRPC** 切换为 **On**。 |
| **Globalping 额度不足报错** | 免费额度耗尽时，脚本会自动保留上一版已验证的优选 IP 缓存继续工作；等下小时额度恢复后执行 `sudo easy_all refresh-cdn-ips` 即可。 |
| **订阅可下载但节点无法连接** | 1. 确认客户端内核版本是否过旧（Mihomo 建议 ≥ 1.19.9）；<br>2. 检查云服务商安全组是否放行了业务端口（443 / 8443）。 |
