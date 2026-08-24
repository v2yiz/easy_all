#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

XRAY_CONFIG="${EASY_ALL_XRAY_CONFIG:-/etc/easy_all/xray/config.json}"
XRAY_BIN="${EASY_ALL_XRAY_BIN:-/etc/easy_all/xray/xray}"
XRAY_SERVICE="${EASY_ALL_XRAY_SERVICE:-easy_all-xray.service}"
STATE_DIR="${EASY_ALL_STATE_DIR:-/etc/easy_all}"
BACKUP_DIR="${EASY_ALL_WARP_SCOPE_BACKUP_DIR:-${STATE_DIR}/backups/warp-scope-test}"
TEST_PORT="${EASY_ALL_WARP_SCOPE_PORT:-18080}"

RUNTIME_TMP=$(mktemp -d)
XRAY_TEST_PID=""
RESTORE_ON_EXIT=0
RESTORE_BACKUP=""

RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
RESET='\033[0m'

info() { printf '%s\n' "$*"; }
success() { printf '%b%s%b\n' "${GREEN}" "$*" "${RESET}"; }
warn() { printf '%b%s%b\n' "${YELLOW}" "$*" "${RESET}" >&2; }
die() { printf '%b错误: %s%b\n' "${RED}" "$*" "${RESET}" >&2; exit 1; }

cleanup() {
    local status=$?
    if [[ -n "${XRAY_TEST_PID}" ]] && kill -0 "${XRAY_TEST_PID}" 2>/dev/null; then
        kill "${XRAY_TEST_PID}" >/dev/null 2>&1 || true
        wait "${XRAY_TEST_PID}" >/dev/null 2>&1 || true
    fi
    if [[ "${RESTORE_ON_EXIT}" == "1" && -n "${RESTORE_BACKUP}" && -f "${RESTORE_BACKUP}" ]]; then
        warn "脚本异常退出，正在恢复 hunt 开始前配置"
        install -m 0600 "${RESTORE_BACKUP}" "${XRAY_CONFIG}" >/dev/null 2>&1 || true
        systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
    fi
    rm -rf -- "${RUNTIME_TMP}"
    return "${status}"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

usage() {
    cat <<'EOF'
用法: sudo bash warp-scope-test.sh <命令> [范围或域名]

命令:
  list                         显示内置测试范围
  show                         显示当前 Xray 配置中的 WARP 域名
  probe [范围]                 临时启动本机 SOCKS 测试，不修改线上 Xray 服务
  apply <范围>                 将指定范围写入当前 Xray 配置并重启服务
  restore [备份文件]           恢复最近一次 apply/hunt 前的 Xray 配置
  hunt                         交互式逐步扩大范围，便于用真实客户端测试 Gemini

内置范围:
  base       原始 9 个 Gemini/AI Studio 域名
  current    base + waa-pa.clients6.google.com + signaler-pa.clients6.google.com + www.google.com
  login      current + accounts.google.com
  shell      login + ogs.google.com
  api        shell + apis.google.com + clients4.google.com
  antiabuse  api + ogads-pa.clients6.google.com
  session    antiabuse + www.google.com.hk

自定义:
  sudo bash warp-scope-test.sh apply custom gemini.google.com gemini.gstatic.com www.google.com

说明:
  这个脚本不依赖 easy_all 项目代码，不会修改 state.env、Nginx、订阅或云资源。
  apply/hunt 只会修改 XRAY_CONFIG 指向的 Xray 配置并重启 XRAY_SERVICE。
  默认 XRAY_CONFIG=/etc/easy_all/xray/config.json。
  每次修改前都会备份，restore 可回滚。所有内置范围都不包含 www.gstatic.com。
EOF
}

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "请使用 root 或 sudo 执行"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "缺少依赖命令：$1"
}

validate_loopback_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

validate_domain() {
    local domain=$1 label tld
    local -a labels
    [[ ${#domain} -ge 4 && ${#domain} -le 253 ]] || return 1
    [[ "${domain}" == *.* ]] || return 1
    [[ "${domain}" != \*.* ]] || return 1
    [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "${domain}" != .* && "${domain}" != *. ]] || return 1
    [[ "${domain}" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"${domain}"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    tld=${labels[$((${#labels[@]} - 1))]}
    [[ "${tld}" =~ ^[A-Za-z]{2,}$ ]]
}

normalize_domain() {
    local domain=$1
    domain=${domain#domain:}
    domain=${domain%.}
    tr '[:upper:]' '[:lower:]' <<<"${domain}" | tr -d '\n'
}

unique_domains() {
    awk 'NF && !seen[$0]++'
}

base_domains() {
    printf '%s\n' \
        gemini.google.com \
        bard.google.com \
        gemini.gstatic.com \
        generativeai.google \
        generativelanguage.googleapis.com \
        proactivebackend-pa.googleapis.com \
        alkalimakersuite-pa.clients6.google.com \
        makersuite.google.com \
        ai.google.dev
}

current_domains() {
    printf '%s\n' \
        gemini.google.com \
        bard.google.com \
        gemini.gstatic.com \
        www.google.com \
        generativeai.google \
        generativelanguage.googleapis.com \
        proactivebackend-pa.googleapis.com \
        alkalimakersuite-pa.clients6.google.com \
        waa-pa.clients6.google.com \
        signaler-pa.clients6.google.com \
        makersuite.google.com \
        ai.google.dev
}

login_domains() {
    {
        current_domains
        printf '%s\n' accounts.google.com
    } | unique_domains
}

shell_domains() {
    {
        login_domains
        printf '%s\n' ogs.google.com
    } | unique_domains
}

api_domains() {
    {
        shell_domains
        printf '%s\n' apis.google.com clients4.google.com
    } | unique_domains
}

antiabuse_domains() {
    {
        api_domains
        printf '%s\n' ogads-pa.clients6.google.com
    } | unique_domains
}

session_domains() {
    {
        antiabuse_domains
        printf '%s\n' www.google.com.hk
    } | unique_domains
}

custom_domains() {
    local raw domain part
    (($# > 0)) || die "custom 范围必须至少指定一个域名"
    for raw in "$@"; do
        raw=${raw//,/ }
        for part in ${raw}; do
            part=${part%,}
            [[ -n "${part}" ]] || continue
            domain=$(normalize_domain "${part}")
            validate_domain "${domain}" || die "无效域名：${part}"
            printf '%s\n' "${domain}"
        done
    done | unique_domains
}

scope_domains() {
    local scope=${1:-current}
    shift || true
    case "${scope}" in
    base | minimal) base_domains ;;
    current) current_domains ;;
    login) login_domains ;;
    shell) shell_domains ;;
    api) api_domains ;;
    antiabuse) antiabuse_domains ;;
    session) session_domains ;;
    custom) custom_domains "$@" ;;
    *) die "未知 WARP 测试范围：${scope}" ;;
    esac
}

scope_domains_json() {
    local scope=${1:-current}
    shift || true
    scope_domains "${scope}" "$@" \
        | jq -Rcs 'split("\n") | map(select(length > 0) | "domain:" + .)'
}

print_scope_domains() {
    local scope=${1:-current}
    shift || true
    scope_domains "${scope}" "$@" | sed 's/^/  - /'
}

backup_file_latest() {
    printf '%s/latest-before-test.json' "${BACKUP_DIR}"
}

require_runtime() {
    require_root
    require_command jq
    [[ -f "${XRAY_CONFIG}" ]] || die "Xray 配置不存在：${XRAY_CONFIG}"
    [[ -x "${XRAY_BIN}" ]] || die "Xray 可执行文件不存在或不可执行：${XRAY_BIN}"
    jq -e 'any(.outbounds[]?; .tag == "warp")' "${XRAY_CONFIG}" >/dev/null \
        || die "当前 Xray 配置没有 tag=warp 出站；请先启用 Gemini WARP"
    jq -e 'any(.routing.rules[]?; .outboundTag == "warp" and ((.domain? | type) == "array"))' \
        "${XRAY_CONFIG}" >/dev/null \
        || die "当前 Xray 配置没有 outboundTag=warp 的域名路由"
}

render_config() {
    local domains_json=$1 output=$2
    jq --argjson domains "${domains_json}" '
      (.routing.rules) |= map(
        if .outboundTag == "warp" and ((.domain? | type) == "array")
        then .domain = $domains
        else .
        end
      )
    ' "${XRAY_CONFIG}" >"${output}"
}

validate_config() {
    local config=$1
    "${XRAY_BIN}" run -test -config "${config}" >/dev/null \
        || die "Xray 测试配置校验失败，未修改当前服务"
}

restart_service() {
    systemctl restart "${XRAY_SERVICE}" \
        && systemctl is-active --quiet "${XRAY_SERVICE}"
}

backup_current_config() {
    local backup timestamp latest
    timestamp=$(date -u +%Y%m%dT%H%M%SZ)
    install -d -m 0700 "${BACKUP_DIR}"
    backup="${BACKUP_DIR}/config-${timestamp}-$$.json"
    latest=$(backup_file_latest)
    install -m 0600 "${XRAY_CONFIG}" "${backup}"
    install -m 0600 "${backup}" "${latest}"
    printf '%s\n' "${backup}"
}

restore_after_failed_apply() {
    local backup=$1
    warn "测试范围应用失败，正在恢复修改前配置"
    install -m 0600 "${backup}" "${XRAY_CONFIG}" || true
    systemctl restart "${XRAY_SERVICE}" >/dev/null 2>&1 || true
}

apply_config() {
    local config=$1
    install -m 0600 "${config}" "${XRAY_CONFIG}" || return 1
    restart_service
}

show_current() {
    require_root
    require_command jq
    [[ -f "${XRAY_CONFIG}" ]] || die "Xray 配置不存在：${XRAY_CONFIG}"
    local domains
    domains=$(jq -r '
      .routing.rules[]?
      | select(.outboundTag == "warp" and ((.domain? | type) == "array"))
      | .domain[]
      | sub("^domain:"; "")
    ' "${XRAY_CONFIG}")
    if [[ -z "${domains}" ]]; then
        info "当前配置没有 WARP 域名路由"
    else
        sed 's/^/  - /' <<<"${domains}"
    fi
}

list_scopes() {
    local scope
    for scope in base current login shell api antiabuse session; do
        printf '%s:\n' "${scope}"
        print_scope_domains "${scope}"
    done
}

apply_scope() {
    local scope=${1:-}
    [[ -n "${scope}" ]] || die "用法：sudo bash warp-scope-test.sh apply <范围>"
    shift || true
    local domains_json temp backup
    require_runtime
    require_command systemctl
    domains_json=$(scope_domains_json "${scope}" "$@")
    temp="${RUNTIME_TMP}/warp-scope-${scope}.json"
    render_config "${domains_json}" "${temp}"
    validate_config "${temp}"
    backup=$(backup_current_config)
    if ! apply_config "${temp}"; then
        restore_after_failed_apply "${backup}"
        die "重启 ${XRAY_SERVICE} 失败，已尝试恢复修改前配置"
    fi
    success "已应用 WARP 测试范围：${scope}"
    printf '备份文件: %s\n' "${backup}"
    printf '当前 WARP 域名:\n'
    print_scope_domains "${scope}" "$@"
}

restore_config() {
    local backup=${1:-$(backup_file_latest)}
    require_root
    require_command jq
    require_command systemctl
    [[ -x "${XRAY_BIN}" ]] || die "Xray 可执行文件不存在或不可执行：${XRAY_BIN}"
    [[ -f "${backup}" ]] || die "备份文件不存在：${backup}"
    validate_config "${backup}"
    install -m 0600 "${backup}" "${XRAY_CONFIG}"
    restart_service || die "重启 ${XRAY_SERVICE} 失败"
    success "已恢复 Xray 配置：${backup}"
}

probe_urls() {
    cat <<'EOF'
https://gemini.google.com/app
https://www.google.com/generate_204
https://www.gstatic.com/generate_204
https://generativelanguage.googleapis.com/$discovery/rest?version=v1beta
https://ai.google.dev/
EOF
}

expected_tag() {
    local host=$1 domains=$2
    if grep -Fxq "${host}" <<<"${domains}"; then
        printf 'warp'
    else
        printf 'direct'
    fi
}

last_access_tag() {
    local access_log=$1 line tag
    line=$(tail -n 1 "${access_log}" 2>/dev/null || true)
    tag=$(sed -n 's/.*\[[^]]*->[[:space:]]*\([^]]*\)\].*/\1/p' <<<"${line}" | tail -n 1)
    printf '%s' "${tag:-unknown}"
}

probe_scope() {
    local scope=${1:-current}
    shift || true
    local port=${TEST_PORT}
    local domains domains_json diag_dir diag_config access_log run_log pid url host expected
    local output status elapsed body error_log actual
    validate_loopback_port "${port}" || die "EASY_ALL_WARP_SCOPE_PORT 无效：${port}"
    port=$((10#${port}))
    require_runtime
    require_command curl
    domains=$(scope_domains "${scope}" "$@")
    domains_json=$(jq -Rcs 'split("\n") | map(select(length > 0) | "domain:" + .)' <<<"${domains}")
    diag_dir="${RUNTIME_TMP}/probe"
    install -d -m 0700 "${diag_dir}"
    diag_config="${diag_dir}/config.json"
    access_log="${diag_dir}/access.log"
    run_log="${diag_dir}/xray.log"
    touch "${access_log}"
    jq --argjson port "${port}" --arg access "${access_log}" --argjson domains "${domains_json}" '
      {
        log:{loglevel:"warning",access:$access},
        inbounds:[{
          tag:"diag-socks",
          listen:"127.0.0.1",
          port:$port,
          protocol:"socks",
          settings:{auth:"noauth",udp:false}
        }],
        outbounds:.outbounds,
        routing:{
          domainStrategy:"IPOnDemand",
          rules:[
            {type:"field",domain:$domains,outboundTag:"warp"},
            {type:"field",network:"tcp,udp",outboundTag:"direct"}
          ]
        }
      }
    ' "${XRAY_CONFIG}" >"${diag_config}"
    validate_config "${diag_config}"

    "${XRAY_BIN}" run -config "${diag_config}" >"${run_log}" 2>&1 &
    pid=$!
    XRAY_TEST_PID=${pid}
    sleep 1
    if ! kill -0 "${pid}" 2>/dev/null; then
        sed -n '1,80p' "${run_log}" >&2 || true
        die "临时 Xray SOCKS 启动失败"
    fi

    printf '临时 SOCKS: 127.0.0.1:%s\n' "${port}"
    printf '测试范围: %s\n' "${scope}"
    printf '提示: probe 只验证域名路由与单 URL 响应；Gemini 风控仍需用真实客户端浏览器确认。\n\n'
    while IFS= read -r url; do
        [[ -n "${url}" ]] || continue
        host=${url#*://}
        host=${host%%/*}
        host=${host%%:*}
        expected=$(expected_tag "${host}" "${domains}")
        body="${diag_dir}/body.$$"
        error_log="${diag_dir}/curl-error.$$"
        : >"${access_log}"
        if output=$(curl -sS -L --max-time 20 --connect-timeout 5 \
            --socks5-hostname "127.0.0.1:${port}" \
            -o "${body}" \
            -w 'http=%{http_code} time=%{time_total}s' \
            "${url}" 2>"${error_log}"); then
            status="ok"
        else
            status="fail"
            output=$(tr '\n' ' ' <"${error_log}" | sed 's/[[:space:]]\+/ /g')
        fi
        elapsed=$(grep -Eo 'time=[0-9.]+s' <<<"${output}" || true)
        actual=$(last_access_tag "${access_log}")
        printf '%-48s expected=%-6s actual=%-8s status=%s %s\n' \
            "${host}" "${expected}" "${actual}" "${status}" "${elapsed}"
    done < <(probe_urls)
}

hunt_scope() {
    [[ -t 0 ]] || die "hunt 需要交互终端"
    local scope answer temp domains_json
    local -a scopes=(current login shell api antiabuse session)
    require_runtime
    require_command systemctl
    RESTORE_BACKUP=$(backup_current_config)
    RESTORE_ON_EXIT=1
    for scope in "${scopes[@]}"; do
        domains_json=$(scope_domains_json "${scope}")
        temp="${RUNTIME_TMP}/warp-scope-hunt-${scope}.json"
        render_config "${domains_json}" "${temp}"
        validate_config "${temp}"
        if ! apply_config "${temp}"; then
            restore_after_failed_apply "${RESTORE_BACKUP}"
            RESTORE_ON_EXIT=0
            die "重启 ${XRAY_SERVICE} 失败，已恢复 hunt 开始前配置"
        fi
        printf '\n已应用测试范围：%s\n' "${scope}"
        print_scope_domains "${scope}"
        printf '\n请在客户端重连 XHTTP 节点并打开 https://gemini.google.com/app\n'
        printf '结果是否正常？[y=正常并保留当前范围 / n=继续扩大 / r=恢复原配置并退出]: '
        IFS= read -r answer
        case "${answer}" in
        y | Y | yes | YES)
            RESTORE_ON_EXIT=0
            success "已保留可用范围：${scope}"
            printf '原始备份文件: %s\n' "${RESTORE_BACKUP}"
            return 0
            ;;
        r | R)
            restore_config "${RESTORE_BACKUP}"
            RESTORE_ON_EXIT=0
            return 0
            ;;
        *)
            ;;
        esac
    done
    warn "所有内置范围都已测试完成，仍未确认可用；正在恢复原配置"
    restore_config "${RESTORE_BACKUP}"
    RESTORE_ON_EXIT=0
}

main() {
    local command=${1:-help}
    shift || true
    case "${command}" in
    list) list_scopes ;;
    show) show_current ;;
    probe) probe_scope "$@" ;;
    apply) apply_scope "$@" ;;
    restore) restore_config "$@" ;;
    hunt) hunt_scope ;;
    help | -h | --help) usage ;;
    *) usage; return 1 ;;
    esac
}

main "$@"
