# Debian 初始化工具

`scripts/debian-init.sh` 是独立的个人服务器初始化工具，不是 easy_all 的安装前置步骤，也不会
安装、更新或卸载代理节点。

它应在本地管理机交互运行，用于初始化全新的 Debian 12/13 amd64、systemd、非容器服务器：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/scripts/debian-init.sh)
```

不要改成 `curl ... | bash`，脚本需要持续读取交互输入。本地需要 `ssh`、`scp` 和
`ssh-keygen`；安装 `sshpass` 后可自动提交首次 SSH 密码，否则按 SSH 提示输入。

## 执行内容

- 升级 APT 软件包并安装基础工具和 Fail2ban。
- 使用 Debian 官方内核的 BBR，不安装 XanMod。
- 配置 UFW，保留当前 SSH 端口并额外监听 `65533`。
- 设置 `Asia/Shanghai` 时区并启用时间同步。
- 创建或更新普通用户、sudo 密码和 SSH 公钥。
- 为普通用户安装 `uv` 和 Python 3.12。
- 写入受管 `sshd_config.d` 配置。
- 在本地 `~/.ssh/config` 写入 Host、连接重试和保活参数。

## 主要输入

| 输入 | 默认值 |
| --- | --- |
| 初始 SSH 用户 | `root` |
| 最终普通用户名 | 无，必须填写 |
| 本地 SSH Host 别名 | `<普通用户>-<服务器>` |
| 当前 SSH 端口 | `22` |
| 新增 SSH 端口 | 固定 `65533` |
| UFW 额外 TCP 端口 | 空 |
| SSH key | 默认生成新的 ed25519 key |

当前 SSH 端口不会删除。使用默认端口 `22` 时，sshd、UFW 和 Fail2ban 同时覆盖 `22` 与
`65533`。新端口经普通用户密钥登录验收后才写入本地 SSH 配置。

该工具没有完整卸载或系统回滚命令。执行前应确认服务器可由它接管 SSH、安全策略、软件包、时区
和用户配置，并保留当前 SSH 会话，直到新登录方式验证成功。
