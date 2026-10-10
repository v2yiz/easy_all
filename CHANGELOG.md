# 更新记录

## 2026-10-10-v1

- 修复 Cloudflare 每小时刷新先删除订阅目录造成的 502 窗口：全部渲染并校验后，逐文件原子替换；Reality 发布与本机订阅回滚共用该流程。
- 修复 Cloudflare 回源端口和 Reality 订阅端口在 UFW 刷新期间被临时全网放行的问题；保留 SSH 预放行，添加并验收新白名单后再清理旧来源。
- 补充渲染失败、发布中断、持续可读、配额模式切换和防火墙更新顺序的回归检查。
- 源码发布版本为 Git 标签 `2026-10-10-v1`；Worker 的 `X-Easy-All-Version` 继续在每次构建时按北京时间自动递增，本次服务端修复无需重建 Worker。

升级执行 `sudo easy_all self-update`，再执行 `sudo easy_all apply`；详见[运维指南](docs/operations-guide.md#更新与应用)。

## 2026-10-10

- 默认 Mihomo 模板切换为 COMMON 精简规则；旧的 COMMON Lite 路径并入默认模板，经典 geodata 模板继续保留。
- Apple 分流收窄到 `apple-cn.mrs` 与精确国内调度域名；更换缓存路径，避免继续使用旧的全量 Apple 规则缓存。
- 三套模板将 `0.0.0.0/8` 拒绝规则移到 LAN 规则前，并补充 Apple 分流、缓存迁移和零地址回归测试。
- 聚合 Worker 的 `X-Easy-All-Version` 由构建脚本自动生成，格式为 `YYYY-MM-DD-vN`；日期按北京时间生成，同日递增。本次源码版本以 Git 提交标识，部署时生成的 Worker 版本号会在 `update-sub` 重建后显示。

Cloudflare 聚合订阅服务器更新步骤见[运维指南](docs/operations-guide.md#更新与应用)。
