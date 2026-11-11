# 系统初始化工具

`scripts/debian-init.sh` 是独立的个人服务器初始化工具，不是 easy_all 的安装前置步骤，也不会
安装、更新或卸载代理节点。

它应在本地管理机交互运行，用于初始化全新的 Debian 12/13 或 Ubuntu 22.04/24.04/26.04 LTS、
amd64/arm64、systemd、非容器服务器（平台校验与 easy_all 共用 `lib/platform.sh` 的 `check_platform`，
在任何系统改动之前执行；发行版代号必须与 `/etc/os-release` 的 `VERSION_ID` 一致，缺失或不一致直接拒绝）：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/main/scripts/debian-init.sh)
```

不要改成 `curl ... | bash`，脚本需要持续读取交互输入。本地需要 `ssh`、`scp` 和
`ssh-keygen`；安装 `sshpass` 后可自动提交首次 SSH 密码，否则按 SSH 提示输入。

脚本会从仓库拉取 `lib/platform.sh` 与 `lib/firewall.sh` 复用 easy_all 的平台与防火墙实现。
默认跟随 `main` 分支；开发分支测试可用 `EASY_ALL_BRANCH` 指定分支，受限网络可用
`EASY_ALL_PLATFORM_MODULE_URL` / `EASY_ALL_FIREWALL_MODULE_URL` 指向镜像或完整 URL：

```bash
EASY_ALL_BRANCH=dev bash <(curl -fsSL https://raw.githubusercontent.com/v2yiz/easy_all/dev/scripts/debian-init.sh)
```

## 执行内容

- 升级 APT 软件包并安装基础工具和 Fail2ban。
- 写入与 easy_all 一致的 TCP 调优参数（fq、缓冲区、keepalive 等），不设置拥塞控制算法、不安装或加载 BBR，也不依赖特定内核；写入前自动检查 `/proc/sys/net/ipv6`，在内核开启 `ipv6.disable=1` 时跳过 IPv6 sysctl 参数写入，防止 `sysctl -p` 致命报错。
- 保持 SSH 现有监听端口，UFW 放行该端口并由默认入站策略阻断其余端口，Fail2ban 实时监控保护。
  这套 UFW/Fail2ban 基线是常驻安全底座：后续 `easy_all uninstall` 只回收业务端口，不会关闭 UFW 或删除 Fail2ban 配置。
- 设置 `Asia/Shanghai` 时区并启用时间同步。
- 创建或更新普通用户、sudo 密码和 SSH 公钥；root 初始连接时不依赖预装 sudo，适配精简系统镜像。
- 为普通用户安装 `uv` 和 Python 3.12。
- 写入受管 `sshd_config.d` 配置，关闭 SSH 密码登录，并限制 root 只能使用密钥登录；通过 `sshd -T` 语法验收后执行 `systemctl reload` 平滑生效。
- 在本地 `~/.ssh/config` 写入 Host、连接重试和保活参数。

## 主要输入

| 输入 | 默认值 |
| --- | --- |
| 初始 SSH 用户 | `root` |
| 最终普通用户名 | 无，必须填写 |
| 本地 SSH Host 别名 | `<普通用户>-<服务器>` |
| 当前 SSH 端口 | `22` |
| 最终 SSH 端口 | 与当前端口一致（默认 `22`） |
| UFW 额外 TCP 端口 | 空 |
| SSH key | 默认生成新的 ed25519 key |

当前端口用于初始连接与最终登录，保持原有端口不变。

只有远端策略命令明确成功且普通用户通过密钥登录验收后，才写入本地 SSH 配置并
报告完成。远端非零或连接中断即失败；密钥登录失败不写新的 Host 配置。恢复规则见
[技术参考](technical-reference.md)。

该工具没有完整卸载或系统回滚命令。执行前应确认服务器可由它接管 SSH、安全策略、软件包、时区
和用户配置，并保留当前 SSH 会话，直到新登录方式验证成功。
