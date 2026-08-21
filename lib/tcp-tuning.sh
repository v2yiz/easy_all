#!/usr/bin/env bash

# Shared Google BBR and conservative TCP tuning. Profiles configure only the
# legacy XanMod policy through BBR_ALLOW_EXISTING_XANMOD.

configure_bbr_tcp() {
    if [[ "$(uname -r)" == *xanmod* ]]; then
        case "${BBR_ALLOW_EXISTING_XANMOD:-0}" in
        1)
            [[ -f "${STATE_FILE}" ]] \
                || die "当前运行 XanMod 内核；全新安装前请切换到 Debian 官方内核并重启"
            warn "旧安装仍运行 XanMod；本次保留现有 BBR，切换到 Debian 官方内核后再次执行 update"
            return 0
            ;;
        0) die "当前仍在运行 XanMod 内核；请先切换到 Debian 官方内核并重启" ;;
        *) die "BBR_ALLOW_EXISTING_XANMOD 策略无效：${BBR_ALLOW_EXISTING_XANMOD}" ;;
        esac
    fi
    cat >"${RUNTIME_TMP}/bbr.conf" <<'EOF'
# BBR
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# TCP buffer
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 16384 16777216
net.ipv4.tcp_moderate_rcvbuf = 1

# PMTU
net.ipv4.tcp_mtu_probing = 1

# Idle connection
net.ipv4.tcp_slow_start_after_idle = 1

# Listen queue
net.core.somaxconn = 4096
EOF
    modprobe tcp_bbr >/dev/null 2>&1 \
        || die "当前 Debian 内核不支持 Google BBR (tcp_bbr)"
    grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control \
        || die "Google BBR 模块已加载，但内核未将其注册为可用拥塞控制算法"
    printf '%s\n' tcp_bbr >"${RUNTIME_TMP}/easy_all-bbr.conf"
    install -m 0644 "${RUNTIME_TMP}/easy_all-bbr.conf" "${BBR_MODULES_CONFIG}"
    install -m 0644 "${RUNTIME_TMP}/bbr.conf" "${SYSCTL_CONFIG}"
    sysctl -p "${SYSCTL_CONFIG}" >/dev/null || die "应用 BBR sysctl 配置失败"
    [[ "$(sysctl -n net.ipv4.tcp_congestion_control)" == "bbr" ]] \
        || die "拥塞控制算法未成功设置为 bbr"
    [[ -f "${BBR_MODULES_CONFIG}" && -f "${SYSCTL_CONFIG}" ]] \
        || die "Google BBR 开机配置写入失败"
}
