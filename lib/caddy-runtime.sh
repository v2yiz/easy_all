#!/usr/bin/env bash

# 六模式 Caddy 站点：代理路径、订阅路由、公共响应头与服务管理（design §6、§8）。
# 依赖调用方提供 log.sh 的 die/warn/info/fail，以及模式字段：
# PROTOCOL、CF_NODE_DOMAIN、SUBSCRIPTION_DOMAIN、CF_ORIGIN_DOMAIN、VLESS_PATH、
# ORIGIN_HEADER_SECRET、ALLOWED_TOKENS、SUB_DOWNLOAD_NAME、CERT_FILE、KEY_FILE。
# 路径与套接字可用环境变量覆盖（测试隔离）：SUBSCRIPTION_DIR、CADDY_CONFIG、CADDY_ADMIN_SOCKET。

CADDY_RUNTIME_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib/caddy-core.sh
source "${CADDY_RUNTIME_LIB_DIR}/caddy-core.sh"

: "${SUBSCRIPTION_DIR:=/var/www/easy_all/subscriptions}"
# 模式 6 伪装站静态目录：只放 index.html，与订阅目录严格分离，防路径穿越。
: "${CAMOUFLAGE_DIR:=/var/www/easy_all/camouflage}"
: "${CADDY_ADMIN_SOCKET:=/run/easy_all-caddy/admin.sock}"

caddy_require_protocol() {
    case "${PROTOCOL:-}" in
    anytls | reality-self | cloudfront | cloudflare | combined-cloudfront | combined-cloudflare) return 0 ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

caddy_protocol_has_cdn() {
    case "${PROTOCOL:-}" in
    cloudfront | cloudflare | combined-cloudfront | combined-cloudflare | reality-self) return 0 ;;
    esac
    return 1
}

caddy_protocol_needs_origin_guard() {
    case "${PROTOCOL:-}" in
    cloudfront | combined-cloudfront | reality-self) return 0 ;;
    esac
    return 1
}

caddy_require_host() {
    local name=$1 value=${!1:-}
    [[ -n "${value}" ]] || die "缺少 ${name}，无法生成 Caddy 站点"
    [[ ${#value} -le 253 && "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "${name} 不是合法主机名：${value}"
    printf '%s\n' "${value}"
}

# 站点主机与端口由模式派生（design §2）：模式 1 订阅 8443、模式 2 节点域 443、
# 模式 4 源站 443、模式 3 节点域 8443、模式 5/6 源站 8443；不接受用户另设端口。
# 模式 6 与模式 5 同构：8443 源站（含订阅）+ 回环 9443 伪装站（见 caddy_reality_camouflage_port）。
caddy_site_host() {
    caddy_require_protocol
    case "${PROTOCOL}" in
    anytls)
        [[ "${SUBSCRIPTION_MODE:-deploy}" != "link" ]] \
            || die "模式 1 未部署订阅（link）时不生成 Caddy 站点"
        caddy_require_host SUBSCRIPTION_DOMAIN
        ;;
    cloudfront | combined-cloudfront | reality-self) caddy_require_host CF_ORIGIN_DOMAIN ;;
    cloudflare | combined-cloudflare) caddy_require_host CF_NODE_DOMAIN ;;
    esac
}

caddy_site_port() {
    case "${PROTOCOL:-}" in
    anytls | combined-cloudfront | combined-cloudflare | reality-self) printf '8443\n' ;;
    cloudfront | cloudflare) printf '443\n' ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

# Reality 回落目标：sing-box 入站与 Caddy 伪装站共用这个常量。
caddy_reality_camouflage_port() {
    printf '9443\n'
}

caddy_validate_vless_path() {
    [[ ${#1} -ge 9 && ${#1} -le 96 && "$1" =~ ^/[A-Za-z0-9._~-]+$ ]]
}

caddy_validate_origin_secret() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]]
}

caddy_validate_sub_download_name() {
    [[ "${1:-}" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

# Token 只允许既有的 URL 安全字符集：值直接成为 CEL 单引号字面量，
# 客户端文本永远不进入表达式源码。
caddy_subscription_token_list() {
    [[ -n "${ALLOWED_TOKENS:-}" ]] \
        || die "缺少订阅 Token 字典 ALLOWED_TOKENS，无法生成 Caddy 鉴权"
    jq -r '
        if type != "object" or length == 0 then
            error("ALLOWED_TOKENS 必须是非空 JSON object")
        elif any(.[]; (test("^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$") | not)) then
            error("ALLOWED_TOKENS 只能包含 URL 安全字符 A-Z a-z 0-9 . _ ~ -，长度 8-128，且首字符不能是 ~")
        else
            "[" + ([.[] | "\u0027" + . + "\u0027"] | join(",")) + "]"
        end
    ' <<<"${ALLOWED_TOKENS}" || die "订阅 Token 字典无法生成 Caddy 鉴权列表"
}

# 格式判定顺序由处理器里的 handle 顺序表达：显式 flag → 已确认的 sing-box UA → Clash UA → Base64。
# 每个表达式只看自己这一类输入，避免把“UA 兼 flag”的错误组合写进单一宽泛正则。
caddy_subscription_yaml_flag_expression() {
    printf '%s' "{query.flag}.lowerAscii() in ['clash','mihomo','meta','stash','yaml']"
}

caddy_subscription_base64_flag_expression() {
    printf '%s' "{query.flag}.lowerAscii() in ['base64','uri','v2ray','shadowrocket']"
}

# sing-box 官方客户端远程配置 UA 形态为 "<前缀> (sing-box <核心版本>; language <语言)"。
# 前缀溯源：SFA 见 sing-box-for-android 的 app/src/main/java/io/nekohasekai/sfa/utils/HTTPClient.kt；
# SFI/SFM/SFT（SFT 为 Apple TV 端）见 sing-box-for-apple 的 Library/Network/HTTPClient.swift
# 与 Library/Shared/Variant.swift；SFW/SFL 见 sing-box-for-desktop 的 src/main/userAgent.ts。
# 只按这六个前缀识别、不对任意 sing-box UA 通配；flag=singbox 可手动指定。
caddy_subscription_singbox_expression() {
    local client
    printf '%s' "{query.flag}.lowerAscii() in ['singbox','sing-box']"
    for client in sfa sfi sfm sft sfw sfl; do
        printf '%s' " || {http.request.header.User-Agent}.lowerAscii().startsWith('${client} (sing-box ')"
    done
}

caddy_subscription_yaml_ua_expression() {
    printf '%s' "{http.request.header.User-Agent}.lowerAscii().matches('.*(clash|mihomo|stash|flclash|verge|bettbox).*')"
}

caddy_subscription_ios_expression() {
    printf '%s' "{query.os}.lowerAscii() in ['ios','iphone','ipad']"
    printf '%s' " || {http.request.header.User-Agent}.lowerAscii().matches('.*(iphone|ipad|ipod|(^|[^a-z])ios([^a-z]|\$)).*')"
}

caddy_render_global_options() {
    printf '{\n'
    printf '\tadmin unix/%s\n' "${CADDY_ADMIN_SOCKET}"
    printf '\tauto_https off\n'
    printf '\tservers {\n'
    printf '\t\tprotocols h1 h2\n'
    printf '\t}\n'
    printf '}\n\n'
}

# YAML 分支（含 iOS 变体与 node=all）；显式 flag 与 Clash UA 两个入口共用同一段。
caddy_render_mihomo_handlers() {
    printf '\t\t\t\thandle %s {\n' "$1"
    printf '\t\t\t\theader Content-Disposition "attachment; filename=%s.yaml"\n' \
        "${SUB_DOWNLOAD_NAME}"
    printf '\t\t\t\thandle @easy_all_sub_ios {\n'
    printf '\t\t\t\t\thandle @easy_all_sub_all {\n'
    printf '\t\t\t\t\t\trewrite * /mihomo-ios-all.yaml\n'
    printf '\t\t\t\t\t}\n'
    printf '\t\t\t\t\thandle {\n'
    printf '\t\t\t\t\t\trewrite * /mihomo-ios.yaml\n'
    printf '\t\t\t\t\t}\n'
    printf '\t\t\t\t}\n'
    printf '\t\t\t\thandle @easy_all_sub_all {\n'
    printf '\t\t\t\t\trewrite * /mihomo-all.yaml\n'
    printf '\t\t\t\t}\n'
    printf '\t\t\t\thandle {\n'
    printf '\t\t\t\t\trewrite * /mihomo.yaml\n'
    printf '\t\t\t\t}\n'
    printf '\t\t\t\t}\n'
}

# JSON 分支：产物缺失时返回 503，不降级成其他格式，也不暴露 file_server。
caddy_render_singbox_handler() {
    printf '\t\t\t\thandle @easy_all_sub_singbox {\n'
    printf '\t\t\t\t\theader Content-Type "application/json; charset=utf-8"\n'
    printf '\t\t\t\t\theader Content-Disposition "attachment; filename=%s.json"\n' \
        "${SUB_DOWNLOAD_NAME}"
    printf '\t\t\t\t\thandle @easy_all_sub_all {\n'
    printf '\t\t\t\t\t\t@easy_all_sub_json_all_missing not file /singbox-all.json\n'
    printf '\t\t\t\t\t\trespond @easy_all_sub_json_all_missing 503\n'
    printf '\t\t\t\t\t\trewrite * /singbox-all.json\n'
    printf '\t\t\t\t\t}\n'
    printf '\t\t\t\t\thandle {\n'
    printf '\t\t\t\t\t\t@easy_all_sub_json_missing not file /singbox.json\n'
    printf '\t\t\t\t\t\trespond @easy_all_sub_json_missing 503\n'
    printf '\t\t\t\t\t\trewrite * /singbox.json\n'
    printf '\t\t\t\t\t}\n'
    printf '\t\t\t\t}\n'
}

caddy_subscription_userinfo_file() {
    printf '%s/subscription-userinfo\n' "$(dirname "${CADDY_CONFIG}")"
}

# 订阅处理器不区分阻断状态：CDN 超限时订阅必须保持可用（design §10）。
caddy_render_subscription_handler() {
    local subscription_ok=$1 tokens ios_expression
    tokens=$(caddy_subscription_token_list) || exit 1
    printf '\t\t@easy_all_sub path /subscribe /sub\n\n'
    printf '\t\thandle @easy_all_sub {\n'
    printf '\t\t\troute {\n'
    printf '\t\t\t\troot * %s\n' "${SUBSCRIPTION_DIR}"
    # 公共头必须先于任何终止响应：route 保持书写顺序，405/403/503 同样带这些头。
    printf '\t\t\t\theader Vary "User-Agent"\n'
    printf '\t\t\t\theader Cache-Control "no-store, no-cache, must-revalidate, max-age=0"\n'
    printf '\t\t\t\theader Pragma "no-cache"\n'
    printf '\t\t\t\theader X-Content-Type-Options "nosniff"\n'
    printf '\t\t\t\theader X-Robots-Tag "noindex, nofollow, noarchive"\n'
    printf '\t\t\t\t@easy_all_sub_bad_method not method GET HEAD\n'
    printf '\t\t\t\trespond @easy_all_sub_bad_method 405\n'
    printf '\t\t\t\t@easy_all_sub_denied expression !({query.token} in %s)\n' "${tokens}"
    printf '\t\t\t\trespond @easy_all_sub_denied 403\n'
    if caddy_protocol_needs_origin_guard; then
        printf '\t\t\t\theader Subscription-Userinfo "{file.%s}"\n' "$(caddy_subscription_userinfo_file)"
    fi
    if [[ "${subscription_ok}" != "1" ]]; then
        printf '\t\t\t\trespond 503\n'
        printf '\t\t\t}\n'
        printf '\t\t}\n\n'
        return 0
    fi
    ios_expression=$(caddy_subscription_ios_expression)
    # 重复参数由 Caddy 逗号拼接：拼出来的值不在精确列表里，因此重复 Token 403、
    # 重复 flag/os/node 都不命中显式分支（与 nginx $arg_* 取首值的行为有意不同）。
    printf '\t\t\t\t@easy_all_sub_yaml_flag expression %s\n' \
        "$(caddy_subscription_yaml_flag_expression)"
    printf '\t\t\t\t@easy_all_sub_base64_flag expression %s\n' \
        "$(caddy_subscription_base64_flag_expression)"
    printf '\t\t\t\t@easy_all_sub_singbox expression %s\n' \
        "$(caddy_subscription_singbox_expression)"
    printf '\t\t\t\t@easy_all_sub_yaml_ua expression %s\n' \
        "$(caddy_subscription_yaml_ua_expression)"
    printf '\t\t\t\t@easy_all_sub_ios expression %s\n' "${ios_expression}"
    printf '\t\t\t\t@easy_all_sub_all expression {query.node}.lowerAscii() == \x27all\x27\n'
    # 显式 flag 永远优先于 UA；JSON 分支必须早于所有 YAML 分支。
    caddy_render_mihomo_handlers @easy_all_sub_yaml_flag
    printf '\t\t\t\thandle @easy_all_sub_base64_flag {\n'
    printf '\t\t\t\t\thandle @easy_all_sub_all {\n'
    printf '\t\t\t\t\t\trewrite * /base64-all.txt\n'
    printf '\t\t\t\t\t}\n'
    printf '\t\t\t\t\thandle {\n'
    printf '\t\t\t\t\t\trewrite * /base64.txt\n'
    printf '\t\t\t\t\t}\n'
    printf '\t\t\t\t}\n'
    caddy_render_singbox_handler
    caddy_render_mihomo_handlers @easy_all_sub_yaml_ua
    printf '\t\t\t\thandle @easy_all_sub_all {\n'
    printf '\t\t\t\t\trewrite * /base64-all.txt\n'
    printf '\t\t\t\t}\n'
    printf '\t\t\t\thandle {\n'
    printf '\t\t\t\t\trewrite * /base64.txt\n'
    printf '\t\t\t\t}\n'
    printf '\t\t\t\tfile_server\n'
    printf '\t\t\t}\n'
    printf '\t\t}\n\n'
}

# 一个 https 站点块：模式相关的守卫/代理由 caddy_protocol_* 谓词决定，
# 模式 1 两者均为假（只有订阅站点的鉴权路由与 health）；模式 5/6 两者均为真。
caddy_render_https_site() {
    local host=$1 port=$2 bind_address=$3 blocked=$4 subscription_ok=$5
    printf 'https://%s:%s {\n' "${host}" "${port}"
    printf '\tbind %s\n' "${bind_address}"
    printf '\ttls %s %s\n\n' "${CERT_FILE}" "${KEY_FILE}"
    printf '\troute {\n'
    if caddy_protocol_needs_origin_guard; then
        caddy_validate_origin_secret "${ORIGIN_HEADER_SECRET:-}" \
            || die "源站头密钥格式无效，无法生成 Caddy 守卫"
        # 守卫必须是外层 route 的首个指令；客户端头值不拼进表达式源码。
        printf '\t\t@easy_all_bad_origin expression {http.request.header.X-Easy-All-Origin-Key} != \x27%s\x27\n' \
            "${ORIGIN_HEADER_SECRET}"
        printf '\t\tabort @easy_all_bad_origin\n\n'
    fi
    if caddy_protocol_has_cdn; then
        caddy_validate_vless_path "${VLESS_PATH:-}" \
            || die "VLESS_PATH 无效，无法生成精确代理路径：${VLESS_PATH:-空}"
        printf '\t\thandle %s {\n' "${VLESS_PATH}"
        if [[ "${blocked}" == "1" ]]; then
            printf '\t\t\trespond 503\n'
        else
            printf '\t\t\treverse_proxy 127.0.0.1:10086\n'
        fi
        printf '\t\t}\n\n'
    fi
    caddy_render_subscription_handler "${subscription_ok}"
    printf '\t\t@easy_all_health path /easy_all-health\n'
    printf '\t\trespond @easy_all_health "easy_all ok" 200\n\n'
    printf '\t\thandle {\n'
    printf '\t\t\trespond 404\n'
    printf '\t\t}\n'
    printf '\t}\n'
    printf '}\n'
}

# 模式 6 伪装站：只监听回环 9443，给 sing-box 的 Reality handshake 一个真实的
# TLS 1.3 目标。不提供 /easy_all-health、/subscribe、/sub 或源站头守卫（那是 8443 的事）。
caddy_render_camouflage_site() {
    local host
    host=$(caddy_require_host DIRECT_DOMAIN) || exit 1
    printf 'https://%s:%s {\n' "${host}" "$(caddy_reality_camouflage_port)"
    printf '\tbind 127.0.0.1\n'
    printf '\ttls %s %s\n\n' "${CERT_FILE}" "${KEY_FILE}"
    printf '\troute {\n'
    printf '\t\troot * %s\n' "${CAMOUFLAGE_DIR}"
    printf '\t\theader Cache-Control "no-store"\n'
    printf '\t\theader X-Frame-Options "DENY"\n'
    printf '\t\theader X-Content-Type-Options "nosniff"\n'
    printf '\t\theader Referrer-Policy "same-origin"\n'
    printf '\t\t@easy_all_camo_page {\n'
    printf '\t\t\tmethod GET HEAD\n'
    printf '\t\t\tpath / /login\n'
    printf '\t\t}\n'
    printf '\t\thandle @easy_all_camo_page {\n'
    printf '\t\t\trewrite * /index.html\n'
    printf '\t\t\tfile_server\n'
    printf '\t\t}\n'
    printf '\t\t@easy_all_camo_auth {\n'
    printf '\t\t\tmethod POST\n'
    printf '\t\t\tpath /login /api/auth/login\n'
    printf '\t\t}\n'
    printf '\t\trespond @easy_all_camo_auth "{\\"error\\":\\"Invalid email or password\\"}" 401\n'
    printf '\t\t@easy_all_camo_robots {\n'
    printf '\t\t\tmethod GET HEAD\n'
    printf '\t\t\tpath /robots.txt\n'
    printf '\t\t}\n'
    printf '\t\trespond @easy_all_camo_robots "User-agent: *\nDisallow: /\n" 200\n'
    printf '\t\t@easy_all_camo_favicon {\n'
    printf '\t\t\tmethod GET HEAD\n'
    printf '\t\t\tpath /favicon.ico\n'
    printf '\t\t}\n'
    printf '\t\trespond @easy_all_camo_favicon 204\n'
    printf '\t\thandle {\n'
    printf '\t\t\tredir * /login 302\n'
    printf '\t\t}\n'
    printf '\t}\n'
    printf '}\n'
}

# 外层 route 顺序：CloudFront 密钥守卫 → 精确代理路径 → 精确订阅入口 → health → 404。
render_caddy_config() {
    local dest=$1 blocked=${2:-0} subscription_ok=${3:-1}
    local host port
    [[ -n "${dest}" ]] || die "render_caddy_config 需要目标路径"
    [[ "${blocked}" == "0" || "${blocked}" == "1" ]] \
        || die "Caddy blocked 状态无效：${blocked}"
    [[ "${subscription_ok}" == "0" || "${subscription_ok}" == "1" ]] \
        || die "Caddy 订阅就绪状态无效：${subscription_ok}"
    host=$(caddy_site_host) || exit 1
    port=$(caddy_site_port) || exit 1
    caddy_validate_sub_download_name "${SUB_DOWNLOAD_NAME:-}" \
        || die "Mihomo 下载文件名无效：${SUB_DOWNLOAD_NAME:-空}"
    {
        caddy_render_global_options
        # 模式 6：回环伪装站（9443）+ CloudFront 源站/订阅站点（8443）同时渲染。
        if [[ "${PROTOCOL}" == "reality-self" ]]; then
            caddy_render_camouflage_site
        fi
        caddy_render_https_site "${host}" "${port}" 0.0.0.0 \
            "${blocked}" "${subscription_ok}"
    } >"${dest}" || die "生成 Caddy 配置失败：${dest}"
}

# 按端口提取顶层站点块（不含地址行与收尾括号行）：生成器固定用制表符缩进，
# 顶层块的收尾括号在行首，故 `^}$` 就是该块结束。
caddy_site_block_lines() { # $1=文件 $2=端口
    awk -v port=":$2" '
        inside && $0 == "}" { exit }
        !inside && index($0, "https://") == 1 && index($0, port " {") > 0 \
            && substr($0, length($0)) == "{" { inside = 1; next }
        inside { print }
    ' "$1"
}

# 结构断言：外层 route 在任何 handle 之前、file_server 只在鉴权后的订阅处理器里、
# 订阅入口是精确路径。模式 6 按顶层块分别校验伪装站与订阅站。
caddy_config_structure_ok() {
    local file=$1 route_line handle_line sub_line file_server_line file_server_count
    [[ -s "${file}" ]] || return 1
    grep -Fq 'auto_https off' "${file}" || return 1
    if [[ "${PROTOCOL:-}" == "reality-self" ]]; then
        caddy_reality_structure_ok "${file}"
        return
    fi
    grep -Fq 'bind 0.0.0.0' "${file}" || return 1
    route_line=$(grep -n '^[[:space:]]*route[[:space:]]*{[[:space:]]*$' "${file}" \
        | head -n 1 | cut -d: -f1)
    handle_line=$(grep -n '^[[:space:]]*handle' "${file}" | head -n 1 | cut -d: -f1)
    [[ -n "${route_line}" && -n "${handle_line}" ]] || return 1
    ((route_line < handle_line)) || return 1
    grep -Fq '@easy_all_sub path /subscribe /sub' "${file}" || return 1
    if grep -Eq 'handle /[^[:space:]]*\*|path /(subscribe|sub)\*' "${file}"; then
        return 1
    fi
    file_server_count=$(grep -c '^[[:space:]]*file_server[[:space:]]*$' "${file}" || true)
    ((file_server_count <= 1)) || return 1
    if ((file_server_count == 1)); then
        sub_line=$(grep -n '^[[:space:]]*handle @easy_all_sub {' "${file}" \
            | head -n 1 | cut -d: -f1)
        file_server_line=$(grep -n '^[[:space:]]*file_server[[:space:]]*$' "${file}" \
            | head -n 1 | cut -d: -f1)
        [[ -n "${sub_line}" ]] || return 1
        ((file_server_line > sub_line)) || return 1
    fi
    return 0
}

# 模式 6：伪装站（9443）与 CloudFront 源站/订阅站（8443）是两个独立站点，
# 各自断言自己的契约。
# 否定断言只看指令行并排除 `root *` 路径行，避免 CAMOUFLAGE_DIR 里的 `/sub` 子串误拒：
# `root *` 目录名与 `tls` 证书路径都可能合法地包含 subscribe/sub 子串，站点地址行同理。
caddy_site_route_directives() { # stdin=站点块行 → 输出路由/匹配器/处理器指令行
    grep -v -E '^[[:space:]]*(root \*|tls)([[:space:]]|$)' || true
}

caddy_site_has_subscription_entry() { # stdin=指令行 → 0 表示出现订阅入口或 health
    grep -Eq '@easy_all_sub|/subscribe|/sub([^a-zA-Z0-9_-]|$)|/easy_all-health'
}

# 9443 伪装块：只绑回环、只有登录门户，严禁任何订阅入口与源站头守卫。
caddy_reality_camouflage_structure_ok() { # $1=站点块行
    local camo=$1 directives page_line file_server_line file_server_count
    grep -Fq 'bind 127.0.0.1' <<<"${camo}" || return 1
    grep -Fq 'tls ' <<<"${camo}" || return 1
    grep -Eq '^[[:space:]]*route[[:space:]]*{[[:space:]]*$' <<<"${camo}" || return 1
    grep -Fq '@easy_all_camo_page {' <<<"${camo}" || return 1
    # 安全头必须齐备（只对伪装站页面生效）。
    for header in 'Cache-Control "no-store"' 'X-Frame-Options "DENY"' \
        'X-Content-Type-Options "nosniff"' 'Referrer-Policy "same-origin"'; do
        grep -Fq "${header}" <<<"${camo}" || return 1
    done
    directives=$(caddy_site_route_directives <<<"${camo}")
    if caddy_site_has_subscription_entry <<<"${directives}"; then
        return 1
    fi
    if grep -Eq '@easy_all_bad_origin|X-Easy-All-Origin-Key' <<<"${camo}"; then
        return 1
    fi
    file_server_count=$(grep -c '^[[:space:]]*file_server[[:space:]]*$' <<<"${camo}" || true)
    ((file_server_count == 1)) || return 1
    page_line=$(grep -n '^[[:space:]]*handle @easy_all_camo_page {' <<<"${camo}" \
        | head -n 1 | cut -d: -f1)
    file_server_line=$(grep -n '^[[:space:]]*file_server[[:space:]]*$' <<<"${camo}" \
        | head -n 1 | cut -d: -f1)
    [[ -n "${page_line}" && -n "${file_server_line}" ]] || return 1
    ((file_server_line > page_line)) || return 1
    return 0
}

# 8443 CloudFront 源站块：源站头守卫必须出现在任何 handle 之前（守卫晚于 handle
# 就是个可以绕过的空守卫），且必须提供精确订阅入口。
caddy_reality_origin_structure_ok() { # $1=站点块行
    local origin=$1 bad_origin_line abort_line handle_line sub_line file_server_line file_server_count
    grep -Fq 'bind 0.0.0.0' <<<"${origin}" || return 1
    grep -Fq '@easy_all_bad_origin expression' <<<"${origin}" || return 1
    grep -Fq 'abort @easy_all_bad_origin' <<<"${origin}" || return 1
    bad_origin_line=$(grep -n '@easy_all_bad_origin' <<<"${origin}" | head -n 1 | cut -d: -f1)
    abort_line=$(grep -n '^[[:space:]]*abort @easy_all_bad_origin[[:space:]]*$' <<<"${origin}" \
        | head -n 1 | cut -d: -f1)
    handle_line=$(grep -n '^[[:space:]]*handle' <<<"${origin}" | head -n 1 | cut -d: -f1)
    [[ -n "${bad_origin_line}" && -n "${abort_line}" && -n "${handle_line}" ]] || return 1
    ((bad_origin_line < handle_line && abort_line < handle_line)) || return 1
    grep -Fq '@easy_all_sub path /subscribe /sub' <<<"${origin}" || return 1
    grep -Fq '@easy_all_health path /easy_all-health' <<<"${origin}" || return 1
    if grep -Eq 'handle /[^[:space:]]*\*|path /(subscribe|sub)\*' <<<"${origin}"; then
        return 1
    fi
    # 订阅未就绪时会渲染成裸 503（没有产物路径，也就没有 file_server）：
    # 这种情况下 file_server 数量必须是 0，不能像就绪时那样必选。
    file_server_count=$(grep -c '^[[:space:]]*file_server[[:space:]]*$' <<<"${origin}" || true)
    ((file_server_count <= 1)) || return 1
    if ((file_server_count == 1)); then
        sub_line=$(grep -n '^[[:space:]]*handle @easy_all_sub {' <<<"${origin}" \
            | head -n 1 | cut -d: -f1)
        file_server_line=$(grep -n '^[[:space:]]*file_server[[:space:]]*$' <<<"${origin}" \
            | head -n 1 | cut -d: -f1)
        [[ -n "${sub_line}" && -n "${file_server_line}" ]] || return 1
        ((file_server_line > sub_line)) || return 1
    fi
    return 0
}

caddy_reality_structure_ok() {
    local file=$1 camo origin site_blocks
    camo=$(caddy_site_block_lines "${file}" "$(caddy_reality_camouflage_port)")
    origin=$(caddy_site_block_lines "${file}" "$(caddy_site_port)")
    [[ -n "${camo}" && -n "${origin}" ]] || return 1
    caddy_reality_camouflage_structure_ok "${camo}" || return 1
    caddy_reality_origin_structure_ok "${origin}" || return 1
    # 只允许这两个顶层站点块：多出来的块意味着渲染器把两种站点重复写入了。
    site_blocks=$(grep -Ec '^https://[^[:space:]]+:[0-9]+ \{$' "${file}")
    ((site_blocks == 2)) || return 1
    return 0
}

validate_caddy_config() {
    local file=$1 output status=0
    [[ -s "${file}" ]] || { fail "Caddy 配置不存在或为空"; return 1; }
    if [[ -x "${CADDY_BIN}" ]]; then
        # 候选配置只在本次运行内存在：失败时必须当场把 validator 的真实错误输出到 stderr，
        # 不能让用户去查看一个退出后就被删掉的文件。
        output=$("${CADDY_BIN}" validate --adapter caddyfile --config "${file}" 2>&1) \
            || status=$?
        if ((status != 0)); then
            [[ -z "${output}" ]] || printf '%s\n' "${output}" >&2
            fail "候选 Caddy 配置校验未通过（候选文件随本次运行结束删除）"
            return 1
        fi
        return 0
    fi
    caddy_config_structure_ok "${file}" \
        || { fail "Caddy 配置结构校验失败"; return 1; }
}

write_caddy_config() {
    local blocked=${1:-0} subscription_ok=${2:-1} candidate stage target_dir
    [[ -n "${RUNTIME_TMP:-}" ]] || die "运行时临时目录未初始化，无法写入 Caddy 配置"
    candidate="${RUNTIME_TMP}/Caddyfile.next"
    render_caddy_config "${candidate}" "${blocked}" "${subscription_ok}"
    validate_caddy_config "${candidate}" || die "候选 Caddy 配置校验失败（候选文件随本次运行结束删除）"
    target_dir=$(dirname "${CADDY_CONFIG}")
    install -d -m 0700 "${target_dir}" || die "创建 Caddy 配置目录失败：${target_dir}"
    stage=$(mktemp "${CADDY_CONFIG}.XXXXXX") \
        || die "创建 Caddy 配置暂存文件失败：${target_dir}"
    if ! { install -m 0600 "${candidate}" "${stage}" \
        && mv -f -- "${stage}" "${CADDY_CONFIG}"; }; then
        rm -f -- "${stage}"
        die "发布 Caddy 配置失败：${CADDY_CONFIG}"
    fi
}

# 只通过受限的管理套接字重载，不改动任何旧服务；服务未运行时不擅自启动。
# 证书轮换后配置内容不变（同路径替换证书文件），Caddy 可能跳过相同配置加载：
# 证书布署路径必须传 1 使用 --force，确保实际送出的是磁盘上的新证书。
reload_caddy() {
    local force=${1:-0}
    local -a args=(reload --address "unix/${CADDY_ADMIN_SOCKET}" --config "${CADDY_CONFIG}" --adapter caddyfile)
    [[ "${force}" != "1" ]] || args+=(--force)
    if ! command -v systemctl >/dev/null 2>&1; then
        warn "缺少 systemctl；未重载 Caddy（配置已写入 ${CADDY_CONFIG}）"
        return 0
    fi
    if ! systemctl is-active --quiet "${CADDY_SERVICE}" 2>/dev/null; then
        warn "Caddy 服务未运行；未重载（配置已写入 ${CADDY_CONFIG}）"
        return 0
    fi
    "${CADDY_BIN}" "${args[@]}" \
        || die "重载 Caddy 配置失败：${CADDY_CONFIG}"
}
