# 安装参数示例（可直接复制）

把示例复制到你自己的编辑器，改掉域名与 `<...>` 占位符，再粘贴到 VPS 上即可。参数文件不需要
`chmod`，安装成功后会**自动删除**它（里面有 Token）；中途失败会保留，排查后自行删除。

```bash
# 在本机改好后，整段粘贴进 VPS 终端（heredoc 会原样写入 params.json）
cat > params.json <<'JSON'
{ ...粘贴上面的 JSON... }
JSON
sudo easy_all params.json --check-params   # 先校验，一次报出全部错误
sudo easy_all params.json                  # 校验通过后安装
```

- `<...>` 必须替换成真实值；空字符串 `""` 表示"留空自动生成/探测"。
- 除本文件列出的字段外没有别的输入项；字段清单可用 `--print-params --mode <模式>` 随手查
  （会打印全部字段，含不同订阅模式的条件字段）。
- 只填必填项也能装：其余字段删掉即用默认值。

## 组合模式（combined）

`CF_ZONE`、`CLOUDFLARE_API_TOKEN`、`GLOBALPING_TOKEN` 与订阅 Token 必填，其余域名按 `example.com` 自动派生。单用户可把
`ALLOWED_TOKENS` 换成 `"OWNER_TOKEN": "<订阅 Token>"`（两者二选一）。

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
    "CLOUDFLARE_API_TOKEN": "<Cloudflare API Token>",
    "GLOBALPING_TOKEN": "<Globalping Token>",
    "REALITY_TARGET": "swdist.apple.com:443",
    "XHTTP_PATH": "",
    "DIRECT_NODE_NAME": "🇺🇸直连",
    "CF_NODE_PREFIX": "🇺🇸CF",
    "SUB_DOWNLOAD_NAME": "EASY_ALL",
    "VLESS_UUID": "",
    "ALLOWED_TOKENS": {
      "owner": "<订阅 Token（8-128 位 URL 安全字符）>"
    },
    "VPS_PUBLIC_IPV4": "",
    "TCP_ACCELERATION": "skyline",
    "REBOOT_SCHEDULE_MODE": "1",
    "REBOOT_HOUR": ""
  }
}
```

## 直连 Reality（reality）

### 本机订阅（`SUBSCRIPTION_MODE: deploy`）

必填：`SUBSCRIPTION_DOMAIN`、`CLOUDFLARE_API_TOKEN`、`ALLOWED_TOKENS`；`NODE_HOST` 留空会在安装
阶段自动探测公网 IPv4（`VPS_PUBLIC_IPV4` 同样留空即自动探测）。

```json
{
  "schema_version": 1,
  "mode": "reality",
  "params": {
    "NODE_HOST": "",
    "NODE_NAME": "MY_REALITY",
    "VLESS_UUID": "",
    "REALITY_TARGET": "swdist.apple.com:443",
    "SUB_PORT_MODE": "dynamic",
    "SUBSCRIPTION_MODE": "deploy",
    "SUB_DOWNLOAD_NAME": "EASY_ALL",
    "SUBSCRIPTION_DOMAIN": "sub.example.com",
    "CLOUDFLARE_API_TOKEN": "<Cloudflare API Token>",
    "ENABLE_MONTHLY_QUOTA": "0",
    "ALLOWED_TOKENS": {
      "owner": "<订阅 Token（8-128 位 URL 安全字符）>"
    },
    "VPS_PUBLIC_IPV4": "",
    "TCP_ACCELERATION": "skyline",
    "REBOOT_SCHEDULE_MODE": "1",
    "REBOOT_HOUR": ""
  }
}
```

### Worker 聚合订阅（`SUBSCRIPTION_MODE: worker`）

额外需要 `SUB_SOURCE_DOMAIN`（私有节点源域名）与 Worker 名称；`WORKER_AGGREGATION_CONFIG`
里填其他节点的聚合信息（没有就留 `{}`）。

```json
{
  "schema_version": 1,
  "mode": "reality",
  "params": {
    "NODE_HOST": "",
    "NODE_NAME": "MY_REALITY",
    "VLESS_UUID": "",
    "REALITY_TARGET": "swdist.apple.com:443",
    "SUB_PORT_MODE": "dynamic",
    "SUBSCRIPTION_MODE": "worker",
    "SUB_DOWNLOAD_NAME": "EASY_ALL",
    "SUBSCRIPTION_DOMAIN": "sub.example.com",
    "CLOUDFLARE_API_TOKEN": "<Cloudflare API Token>",
    "CLOUDFLARE_WORKER_NAME": "easyall-reality",
    "SUB_SOURCE_DOMAIN": "src.example.com",
    "WORKER_SOURCE_SECRET": "",
    "WORKER_AGGREGATION_CONFIG": {
      "nodes": [],
      "fallbackCdnNodes": []
    },
    "ENABLE_MONTHLY_QUOTA": "0",
    "ALLOWED_TOKENS": {
      "owner": "<订阅 Token（8-128 位 URL 安全字符）>"
    },
    "VPS_PUBLIC_IPV4": "",
    "TCP_ACCELERATION": "skyline",
    "REBOOT_SCHEDULE_MODE": "1",
    "REBOOT_HOUR": ""
  }
}
```

### 仅节点（`SUBSCRIPTION_MODE: link`）

在 deploy 示例基础上：`SUBSCRIPTION_MODE` 改成 `"link"`，删除 `SUBSCRIPTION_DOMAIN`、
`CLOUDFLARE_API_TOKEN`、`ALLOWED_TOKENS` 三个字段即可（不需要订阅与 Token）。

## Cloudflare CDN（cloudflare-streamup）

必填：`CLOUDFLARE_API_TOKEN`、`VLESS_CDN_DOMAIN`、`GLOBALPING_TOKEN`、`SUBSCRIPTION_DOMAIN`（Worker
订阅域名，需与节点域名不同）、`ALLOWED_TOKENS`。`WORKER_BACKUP_DOMAIN` 留空表示不部署兜底 Worker。

```json
{
  "schema_version": 1,
  "mode": "cloudflare-streamup",
  "params": {
    "XHTTP_NODE_NAME": "VLESS_XHTTP_H2",
    "VLESS_UUID": "",
    "CLOUDFLARE_API_TOKEN": "<Cloudflare API Token>",
    "VLESS_CDN_DOMAIN": "node.example.com",
    "GLOBALPING_TOKEN": "<Globalping Token>",
    "XHTTP_PATH": "",
    "XRAY_XHTTP_LOOPBACK_PORT": "10086",
    "ORIGIN_HEADER_SECRET": "",
    "SUBSCRIPTION_MODE": "deploy",
    "SUBSCRIPTION_DOMAIN": "sub.example.com",
    "CLOUDFLARE_WORKER_NAME": "easyall",
    "SUB_DOWNLOAD_NAME": "EASY_ALL",
    "WORKER_SOURCE_SECRET": "",
    "WORKER_AGGREGATION_CONFIG": {
      "nodes": [],
      "fallbackCdnNodes": []
    },
    "ENABLE_MONTHLY_QUOTA": "0",
    "ALLOWED_TOKENS": {
      "owner": "<订阅 Token（8-128 位 URL 安全字符）>"
    },
    "WORKER_BACKUP_DOMAIN": "",
    "WORKER_BACKUP_PLACEMENT": "off",
    "VPS_PUBLIC_IPV4": "",
    "TCP_ACCELERATION": "skyline",
    "REBOOT_SCHEDULE_MODE": "1",
    "REBOOT_HOUR": ""
  }
}
```

仅节点（`link`）：`SUBSCRIPTION_MODE` 改成 `"link"`，删除 `SUBSCRIPTION_DOMAIN`、
`CLOUDFLARE_WORKER_NAME`、`WORKER_SOURCE_SECRET`、`WORKER_AGGREGATION_CONFIG`、`ALLOWED_TOKENS`。

## Bunny CDN（bunny-ws）

必填：`CLOUDFLARE_ZONE`、`BUNNY_API_KEY`、`CLOUDFLARE_DNS_TOKEN`；两个域名默认
`origin.<Zone>`、`cdn.<Zone>`。节点名与下载名固定 `EASY_ALL`。

```json
{
  "schema_version": 1,
  "mode": "bunny-ws",
  "params": {
    "CLOUDFLARE_ZONE": "example.com",
    "ORIGIN_DOMAIN": "origin.example.com",
    "CDN_DOMAIN": "cdn.example.com",
    "BUNNY_API_KEY": "<Bunny Account API Key>",
    "CLOUDFLARE_DNS_TOKEN": "<Cloudflare DNS Token>",
    "BUNNY_PULL_NAME": "",
    "BUNNY_BANDWIDTH_GB": "500",
    "ORIGIN_HEADER_SECRET": "",
    "VLESS_UUID": "",
    "OWNER_TOKEN": "<订阅 Token>",
    "WEBSOCKET_PATH": "",
    "VPS_PUBLIC_IPV4": "",
    "TCP_ACCELERATION": "skyline"
  }
}
```

## 按用户月度配额（可选）

任一订阅模式把 `ENABLE_MONTHLY_QUOTA` 改成 `"1"`，再加：

```json
"MONTHLY_QUOTAS_GB": {"owner": 0, "user2": 100},
"QUOTA_TOKEN_OVERRIDES": {},
"QUOTA_START_DATE": "2026-01-01"
```

`MONTHLY_QUOTAS_GB` 的值是 GB（`0` 不限量）；`QUOTA_START_DATE` 是每月账期起点，留空用今天。
启用配额后 `ALLOWED_TOKENS` 可以省略（会自动生成并打印）。
