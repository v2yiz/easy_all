#!/usr/bin/env bash

setup_aggregate() {
    local config=/etc/easy_all/aggregate.json check_only=0
    [[ $# -eq 0 || ( $# -eq 1 && $1 == --check ) ]] || launcher_die "用法：easy_all aggregate [--check]"
    [[ ${1:-} != --check ]] || check_only=1
    [[ $(id -u) == 0 ]] || launcher_die "请使用 sudo easy_all aggregate"
    [[ -s ${config} ]] || launcher_die "请先配置 ${config}；示例位于 ${EASY_ALL_ROOT}/aggregate/aggregate.example.json"
    [[ $(detect_installed_mode) == cloudflare-streamup ]] || launcher_die "自动聚合配置目前适用于已安装 Cloudflare 模式"
    if ! command -v node >/dev/null 2>&1; then
        ((check_only == 0)) || launcher_die "校验需要 Node.js 18+；执行 easy_all aggregate 可自动安装"
        apt-get update || return 1
        apt-get install -y nodejs || return 1
    fi
    node -e 'if(Number(process.versions.node.split(".")[0])<18)process.exit(1)' || launcher_die "需要 Node.js 18+"
    node "${EASY_ALL_ROOT}/aggregate/aggregate.mjs" --check "${config}" || return 1
    ((check_only == 0)) || return 0
    # Reuse the existing transactional runtime apply instead of editing nginx in-place.
    "${EASY_ALL_ROOT}/easy_all" apply-cloud || return 1
    chmod 600 "${config}" || return 1
    install -m 644 "${EASY_ALL_ROOT}/aggregate/easy_all-aggregate.service" /etc/systemd/system/easy_all-aggregate.service || return 1
    systemctl daemon-reload || return 1
    systemctl enable easy_all-aggregate || return 1
    systemctl restart easy_all-aggregate || return 1
    systemctl is-active --quiet easy_all-aggregate || return 1
    printf '聚合服务已配置。订阅地址：https://你的VPS订阅域名/aggregate?token=你的聚合令牌\n'
}
