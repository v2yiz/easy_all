# 更新记录

## 2026-10-10

- 默认 Mihomo 模板切换为 COMMON 精简规则；旧的 COMMON Lite 路径并入默认模板，经典 geodata 模板继续保留。
- Apple 分流收窄到 `apple-cn.mrs` 与精确国内调度域名；更换缓存路径，避免继续使用旧的全量 Apple 规则缓存。
- 三套模板将 `0.0.0.0/8` 拒绝规则移到 LAN 规则前，并补充 Apple 分流、缓存迁移和零地址回归测试。
- 聚合 Worker 的 `X-Easy-All-Version` 由构建脚本自动生成，格式为 `YYYY-MM-DD-vN`；日期按北京时间生成，同日递增。本次源码版本以 Git 提交标识，部署时生成的 Worker 版本号会在 `update-sub` 重建后显示。

Cloudflare 聚合订阅服务器更新步骤见[运维指南](docs/operations-guide.md#更新与应用)。
