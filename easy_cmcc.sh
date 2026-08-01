#!/usr/bin/env bash

# CMCC-focused entrypoint: VLESS XHTTP for Gemini and WSS for downloads.

set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly SCRIPT_FILE="${SCRIPT_DIR}/$(basename -- "${BASH_SOURCE[0]}")"
readonly COMMAND_INSTALL_DIR="/usr/local/lib/easy_all"
readonly COMMAND_PATH="/usr/local/bin/easy_cmcc"
readonly DEFAULT_WORKER_NAME="easy-cmcc"

die() {
    printf 'easy_cmcc: %s\n' "$*" >&2
    exit 1
}

resolve_core_script() {
    local candidate
    for candidate in \
        "${EASY_CMCC_CORE:-}" \
        "${SCRIPT_DIR}/easy_all.sh" \
        "${COMMAND_INSTALL_DIR}/easy_all.sh"; do
        [[ -n "${candidate}" && -f "${candidate}" ]] || continue
        printf '%s\n' "${candidate}"
        return 0
    done
    die "未找到 easy_all.sh；请将 easy_cmcc.sh 与 easy_all.sh 放在同一目录后重试"
}

register_cmcc_command() {
    [[ "${EASY_CMCC_REGISTER_COMMAND:-1}" != "0" ]] || return 0
    [[ "$(id -u)" -eq 0 ]] || return 0
    install -d -m 0755 "${COMMAND_INSTALL_DIR}" "$(dirname "${COMMAND_PATH}")"
    if [[ "${SCRIPT_FILE}" == "${COMMAND_INSTALL_DIR}/easy_cmcc.sh" ]]; then
        chmod 0755 "${SCRIPT_FILE}"
    elif [[ ! -f "${COMMAND_INSTALL_DIR}/easy_cmcc.sh" ]] \
        || ! cmp -s "${SCRIPT_FILE}" "${COMMAND_INSTALL_DIR}/easy_cmcc.sh"; then
        install -m 0755 "${SCRIPT_FILE}" "${COMMAND_INSTALL_DIR}/easy_cmcc.sh"
    fi
    ln -sfn "${COMMAND_INSTALL_DIR}/easy_cmcc.sh" "${COMMAND_PATH}"
    printf '已注册命令：%s\n' "${COMMAND_PATH}"
}

usage() {
    cat <<'EOF'
用法: easy_cmcc [命令]

  install       安装 RackNerd/移动专用 VLESS XHTTP + WSS
  update        刷新 RN 双传输配置并自动部署 easy-cmcc Worker
  update-sub    刷新服务端与订阅（沿用已保存的订阅方式）
  show|subscription|status|update-core|renew-cert|uninstall
                交由共享核心执行，仅管理 VLESS XHTTP + WSS

该入口固定 Worker 名称为 easy-cmcc。BWG/VM 的 Reality 或 AnyTLS 请使用 easy_all。
EOF
}

run_core() {
    local core=$1
    shift
    env EASY_ALL_PROFILE=cmcc \
        WORKER_NAME="${DEFAULT_WORKER_NAME}" \
        "${core}" "$@"
}

main() {
    local command=${1:-install} core
    core=$(resolve_core_script)
    case "${command}" in
    install)
        [[ $# -eq 1 || $# -eq 0 ]] || die "easy_cmcc install 不接受协议参数"
        run_core "${core}" install vless-xhttp
        register_cmcc_command
        ;;
    update | update-sub | show | subscription | status | update-core | renew-cert)
        run_core "${core}" "${command}"
        register_cmcc_command
        ;;
    register-command)
        run_core "${core}" register-command
        register_cmcc_command
        ;;
    uninstall)
        run_core "${core}" uninstall
        ;;
    switch)
        die "easy_cmcc 固定使用 VLESS XHTTP + WSS；BWG/VM 协议切换请使用 easy_all switch"
        ;;
    help | -h | --help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
    esac
}

main "$@"
