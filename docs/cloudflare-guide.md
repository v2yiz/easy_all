# Cloudflare ID 与 API Token 获取指南

本指南只保留 Cloudflare 通用的 Account ID、Zone ID 和最小权限 API Token 获取方法。
项目已经不再提供 Cloudflare Worker VLESS 部署功能；本文不包含 Worker 部署、Custom Domain、
Placement 或代理节点配置。

## 凭证与标识的区别

| 项目 | 作用 | 是否敏感 |
| --- | --- | --- |
| Account ID | 标识 Cloudflare 账户，供账户级 API 使用 | 不是密码，但不必公开 |
| Zone ID | 标识一个已接入 Cloudflare 的域名 Zone | 不是密码，但不必公开 |
| API Token | 按权限和资源范围调用 Cloudflare API | 是，只显示一次 |
| Global API Key | 用户级全局密钥 | 是；不建议用于自动化 |

不要把 Account ID 和 Zone ID 混用。需要自动化时优先创建用途单一、资源范围受限的 API Token，
不要使用 Global API Key。

## 1. 获取 Account ID 与 Zone ID

### Account ID

1. 登录 [Cloudflare Dashboard](https://dash.cloudflare.com/)。
2. 在任意 Dashboard 页面按 `Command/Ctrl + K`。
3. 搜索并选择 **Copy account ID**。

也可以进入 **Workers & Pages**，在 **Account Details** 中复制 **Account ID**。

![Cloudflare Account ID 获取示意图](cloudflare/cloudflare-account-id.svg)

### Zone ID

1. 在 Dashboard 中打开目标域名。
2. 进入该域名的 **Overview** 页面。
3. 在页面底部 **API** 区域复制 **Zone ID**；同一区域通常也能复制 Account ID。

官方说明：[Find account and zone IDs](https://developers.cloudflare.com/fundamentals/account/find-account-and-zone-ids/)。

## 2. 创建 Workers Scripts API Token

只有需要通过 API 或自动化工具读取、上传或更新 Worker 脚本时，才创建这个 Token：

1. 打开 **My Profile → API Tokens**。
2. 选择 **Create Token → Create Custom Token**。
3. 使用能说明用途的名称，例如 `cloudflare-workers-script`。
4. 添加 **Account → Workers Scripts → Edit**。
5. 在 **Account Resources** 中选择 **Include → Specific account → 目标账户**。
6. 可按需要设置有效期和客户端 IP 限制。
7. 选择 **Continue to summary → Create Token**，立即将只显示一次的 Token Secret 保存到密码管理器。

![Cloudflare Worker Token 配置示意图](cloudflare/cloudflare-worker-token.svg)

`Workers Scripts Edit` 只覆盖 Worker 脚本管理。只有实际使用 KV、R2、Queues、Workers Routes
等功能时，才另外添加对应的最小权限。不要为了省事直接扩大到账户内全部资源。

## 3. 创建 DNS API Token

需要通过 API 读取或修改 DNS 记录时，为 DNS 单独创建 Token，不要复用 Worker Token：

1. 打开 **My Profile → API Tokens → Create Token**。
2. 需要修改记录时选择 **Edit zone DNS** 模板，或创建 Custom Token 并添加
   **Zone → DNS → Edit**；只读工具改用 **Zone → DNS → Read**。
3. 如果工具必须通过 API 枚举 Zone，再添加 **Zone → Zone → Read**。
4. 在 **Zone Resources** 中选择 **Include → Specific zone → 目标域名**。
5. 检查权限和资源范围后创建，并立即安全保存 Token Secret。

![Cloudflare DNS Token 配置示意图](cloudflare/cloudflare-dns-token.svg)

每个自动化用途应使用独立 Token。某个工具不再使用时，单独撤销对应 Token，不影响其他服务。

## 4. 验证与保管 Token

用户级 API Token 可以通过官方验证接口确认是否有效：

```bash
curl "https://api.cloudflare.com/client/v4/user/tokens/verify" \
    --header "Authorization: Bearer <API_TOKEN>"
```

安全边界：

- Token Secret 只显示一次，应存入密码管理器或专用 Secret Store。
- 不要把 Token 写入 Git、README、截图、shell 历史或长期保留的明文 `.env`。
- 为 Token 设置尽可能短的有效期和尽可能窄的 Account/Zone 范围。
- 怀疑泄露时立即撤销并重新创建，不要继续复用旧 Token。

官方参考：

- [Create API token](https://developers.cloudflare.com/fundamentals/api/get-started/create-token/)
- [API token permissions](https://developers.cloudflare.com/fundamentals/api/reference/permissions/)
- [API token templates](https://developers.cloudflare.com/fundamentals/api/reference/template/)
