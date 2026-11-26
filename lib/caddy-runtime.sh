#!/usr/bin/env bash

# 四模式 Caddy 站点：代理路径、订阅路由、公共响应头与服务管理（design §6、§8）。
# 依赖调用方提供 log.sh 的 die/warn/info/fail，以及模式字段：
# PROTOCOL、CF_NODE_DOMAIN、SUBSCRIPTION_DOMAIN、CF_ORIGIN_DOMAIN、VLESS_PATH、
# ORIGIN_HEADER_SECRET、ALLOWED_TOKENS、SUB_DOWNLOAD_NAME、CERT_FILE、KEY_FILE。
# 路径与套接字可用环境变量覆盖（测试隔离）：SUBSCRIPTION_DIR、CADDY_CONFIG、CADDY_ADMIN_SOCKET。

CADDY_RUNTIME_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib/caddy-core.sh
source "${CADDY_RUNTIME_LIB_DIR}/caddy-core.sh"

: "${STATE_DIR:=/etc/easy_all}"
: "${SUBSCRIPTION_DIR:=/var/www/easy_all/subscriptions}"
# 模式 3/4 伪装站静态目录：与订阅目录严格分离，防路径穿越。
: "${CAMOUFLAGE_DIR:=/var/www/easy_all/camouflage}"
: "${CADDY_ADMIN_SOCKET:=/run/easy_all-caddy/admin.sock}"

caddy_require_protocol() {
    case "${PROTOCOL:-}" in
    reality-cloudfront | reality-cloudflare | reality-cloudflare-xhttp \
        | cloudfront | cloudflare)
        return 0
        ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

caddy_protocol_has_cdn() {
    case "${PROTOCOL:-}" in
    cloudfront | cloudflare | reality-cloudfront | reality-cloudflare \
        | reality-cloudflare-xhttp)
        return 0
        ;;
    esac
    return 1
}

caddy_protocol_needs_origin_guard() {
    case "${PROTOCOL:-}" in
    cloudfront | reality-cloudfront | reality-cloudflare-xhttp) return 0 ;;
    esac
    return 1
}

# 下发 Subscription-Userinfo 响应头的只有 CloudFront 链路（模式 2/3）。
# 橙云模式（1/4/5）没有 985GB 计量，不得输出空的 Userinfo 头。
caddy_protocol_has_subscription_userinfo() {
    case "${PROTOCOL:-}" in
    cloudfront | reality-cloudfront) return 0 ;;
    esac
    return 1
}

# XHTTP 路由谓词（模式 1/5）：代理路径用 `@easy_all_xhttp` + `h2c` 反代。
# 与模式 5 独有的双 9443 站点/`default_sni` 分开：后者需同时满足 has_reality。
caddy_protocol_uses_xhttp() {
    case "${PROTOCOL:-}" in
    cloudflare | reality-cloudflare-xhttp) return 0 ;;
    esac
    return 1
}

# Reality 自偷入口（模式 3/4/5）：只有这三个模式提供 9443 伪装站。
# 本文件会被测试直接 source（不经 runtime-core），因此不调用 runtime_has_reality_entry。
caddy_protocol_has_reality() {
    case "${PROTOCOL:-}" in
    reality-cloudfront | reality-cloudflare | reality-cloudflare-xhttp) return 0 ;;
    esac
    return 1
}

# 模式 3 采用单 443 合一架构：Caddy 仅在回环 9443 按 X-Easy-All-Origin-Key 分流。
caddy_protocol_uses_unified_reality_site() {
    [[ "${PROTOCOL:-}" == "reality-cloudfront" ]]
}

# 双证书 SAN 隔离：模式 4 的橙云 8443 回源与模式 5 的橙云 9443 双站点都使用独立证书。
caddy_protocol_uses_split_cdn_cert() {
    case "${PROTOCOL:-}" in
    reality-cloudflare | reality-cloudflare-xhttp) return 0 ;;
    esac
    return 1
}

caddy_mode3_migration_marker() {
    printf '%s/mode3-single443.migrated\n' "${STATE_DIR}"
}

# 旧版 v5.5.0 模式 3 升级过渡检测：已有 state.env 但尚未跑完 apply-cloud 迁移到单 443 时，
# 临时保留 8443 兼容块与 UFW 放行，避免纯本机 apply 导致线上 CloudFront 回源 502。
caddy_mode3_needs_legacy_8443() {
    caddy_protocol_uses_unified_reality_site || return 1
    [[ "${EASY_ALL_MODE3_KEEP_LEGACY_8443:-0}" != "1" ]] || return 0
    local state_file=${STATE_FILE:-${STATE_DIR}/state.env}
    [[ -f "${state_file}" && ! -f "$(caddy_mode3_migration_marker)" ]]
}

caddy_origin_cert_file() {
    if caddy_protocol_uses_split_cdn_cert; then
        local cdn_cert=${CDN_CERT_FILE:-$(dirname -- "${CERT_FILE}")/cdn-fullchain.pem}
        # v5.5.0 升级后仅运行 apply 尚未 renew-cert：旧合并证书在磁盘而新 CDN 证书尚未签发时平滑回退。
        if [[ -s "${CERT_FILE:-}" && ! -s "${cdn_cert}" ]]; then
            printf '%s\n' "${CERT_FILE}"
            return 0
        fi
        printf '%s\n' "${cdn_cert}"
        return 0
    fi
    printf '%s\n' "${CERT_FILE}"
}

caddy_origin_key_file() {
    if caddy_protocol_uses_split_cdn_cert; then
        local cdn_cert=${CDN_CERT_FILE:-$(dirname -- "${CERT_FILE}")/cdn-fullchain.pem}
        local cdn_key=${CDN_KEY_FILE:-$(dirname -- "${KEY_FILE}")/cdn-private.key}
        if [[ -s "${CERT_FILE:-}" && ! -s "${cdn_cert}" ]]; then
            printf '%s\n' "${KEY_FILE}"
            return 0
        fi
        printf '%s\n' "${cdn_key}"
        return 0
    fi
    printf '%s\n' "${KEY_FILE}"
}

caddy_require_host() {
    local name=$1 value=${!1:-}
    [[ -n "${value}" ]] || die "缺少 ${name}，无法生成 Caddy 站点"
    [[ ${#value} -le 253 && "${value}" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] \
        || die "${name} 不是合法主机名：${value}"
    printf '%s\n' "${value}"
}

# 站点主机与本机监听端口由模式派生：模式 1/2 为 443、模式 3 为回环 9443（单 443 合一）、
# 模式 4 为 8443；不接受用户另设端口。
caddy_site_host() {
    caddy_require_protocol
    case "${PROTOCOL}" in
    cloudfront | reality-cloudfront) caddy_require_host CF_ORIGIN_DOMAIN ;;
    cloudflare | reality-cloudflare | reality-cloudflare-xhttp) caddy_require_host CF_NODE_DOMAIN ;;
    esac
}

caddy_site_port() {
    case "${PROTOCOL:-}" in
    reality-cloudfront) printf '9443\n' ;;
    reality-cloudflare-xhttp) printf '9443\n' ;;
    reality-cloudflare) printf '8443\n' ;;
    cloudfront | cloudflare) printf '443\n' ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

# CloudFront 云端分发配置的外部回源 HTTPS 端口（与本机 Caddy 监听端口解耦：模式 3 外部为 443，
# 经 sing-box Reality 回落至本机 127.0.0.1:9443）。
cloudfront_origin_https_port() {
    case "${PROTOCOL:-}" in
    cloudfront | reality-cloudfront) printf '443\n' ;;
    *) die "非 CloudFront 模式无外部回源端口：${PROTOCOL:-空}" ;;
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
    # 模式 5：空 SNI / 裸 IP 探测只拿到直连主证书；两个站点块都是精确主机名，
    # 未知 SNI 无通配块故直接拒绝，绝不向外暴露 CDN_CERT_FILE 的 SAN。
    # 模式 1 的 Caddy 直接监听公网 443（只有一个站点块），不得写 default_sni。
    if caddy_protocol_uses_xhttp && caddy_protocol_has_reality; then
        printf '\tdefault_sni %s\n' "$(caddy_require_host DIRECT_DOMAIN)"
    fi
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
    if caddy_protocol_has_subscription_userinfo; then
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

# 源站业务路由片段（VLESS 代理路径 + 订阅路由 + 兜底 404）；不提供 /easy_all-health。
# 模式 1/5 的代理路径改为 XHTTP（h2c 反代 + 不缓冲），模式 2/3/4 保持原有 HTTP 反代。
caddy_render_origin_routes() {
    local blocked=$1 subscription_ok=$2 indent=${3:-$'\t\t'}
    if caddy_protocol_has_cdn; then
        caddy_validate_vless_path "${VLESS_PATH:-}" \
            || die "VLESS_PATH 无效，无法生成精确代理路径：${VLESS_PATH:-空}"
        if caddy_protocol_uses_xhttp; then
            printf '%s@easy_all_xhttp path %s %s/*\n' "${indent}" "${VLESS_PATH}" "${VLESS_PATH}"
            printf '%shandle @easy_all_xhttp {\n' "${indent}"
            if [[ "${blocked}" == "1" ]]; then
                printf '%s\trespond 503\n' "${indent}"
            else
                printf '%s\treverse_proxy 127.0.0.1:10086 {\n' "${indent}"
                printf '%s\t\ttransport http {\n' "${indent}"
                printf '%s\t\t\tversions h2c 2\n' "${indent}"
                printf '%s\t\t}\n' "${indent}"
                printf '%s\t\tflush_interval -1\n' "${indent}"
                printf '%s\t}\n' "${indent}"
            fi
            printf '%s}\n\n' "${indent}"
        else
            printf '%shandle %s {\n' "${indent}" "${VLESS_PATH}"
            if [[ "${blocked}" == "1" ]]; then
                printf '%s\trespond 503\n' "${indent}"
            else
                printf '%s\treverse_proxy 127.0.0.1:10086\n' "${indent}"
            fi
            printf '%s}\n\n' "${indent}"
        fi
    fi
    caddy_render_subscription_handler "${subscription_ok}"
    printf '%shandle {\n' "${indent}"
    printf '%s\trespond 404\n' "${indent}"
    printf '%s}\n' "${indent}"
}

# 伪装站路由片段：托管 CAMOUFLAGE_DIR 静态站点（支持实例变异模板与用户自定义多文件目录），
# 屏蔽隐藏点文件、为登录原型提供显式 JSON 401，并对未知路径/非法方法返回真实 404/405。
caddy_render_camouflage_routes() {
    local indent=${1:-$'\t\t'}
    printf '%sroot * %s\n' "${indent}" "${CAMOUFLAGE_DIR}"
    printf '%sheader Cache-Control "no-store"\n' "${indent}"
    printf '%sheader X-Frame-Options "DENY"\n' "${indent}"
    printf '%sheader X-Content-Type-Options "nosniff"\n' "${indent}"
    printf '%sheader Referrer-Policy "same-origin"\n' "${indent}"
    printf '%s@easy_all_camo_dotfiles path */.*\n' "${indent}"
    printf '%srespond @easy_all_camo_dotfiles 404\n' "${indent}"
    printf '%s@easy_all_camo_auth {\n' "${indent}"
    printf '%s\tmethod POST\n' "${indent}"
    printf '%s\tpath /login /api/auth/login\n' "${indent}"
    printf '%s}\n' "${indent}"
    printf '%shandle @easy_all_camo_auth {\n' "${indent}"
    printf '%s\theader Content-Type "application/json; charset=utf-8"\n' "${indent}"
    printf '%s\trespond "{\\"error\\":\\"Invalid email or password\\"}" 401\n' "${indent}"
    printf '%s}\n' "${indent}"
    printf '%s@easy_all_camo_page {\n' "${indent}"
    printf '%s\tmethod GET HEAD\n' "${indent}"
    printf '%s\tfile {\n' "${indent}"
    printf '%s\t\ttry_files {path} {path}/index.html\n' "${indent}"
    printf '%s\t}\n' "${indent}"
    printf '%s}\n' "${indent}"
    printf '%shandle @easy_all_camo_page {\n' "${indent}"
    printf '%s\tfile_server\n' "${indent}"
    printf '%s}\n' "${indent}"
    printf '%s@easy_all_camo_favicon {\n' "${indent}"
    printf '%s\tmethod GET HEAD\n' "${indent}"
    printf '%s\tpath /favicon.ico\n' "${indent}"
    printf '%s}\n' "${indent}"
    printf '%srespond @easy_all_camo_favicon 204\n' "${indent}"
    printf '%s@easy_all_camo_bad_method not method GET HEAD\n' "${indent}"
    printf '%srespond @easy_all_camo_bad_method 405\n' "${indent}"
    printf '%shandle {\n' "${indent}"
    printf '%s\trespond 404\n' "${indent}"
    printf '%s}\n' "${indent}"
}

# 一个公网 https 站点块：模式相关的守卫/代理由 caddy_protocol_* 谓词决定；
# 源站头守卫只属于 CloudFront 链路（模式 2 及模式 3 旧装兼容期），橙云模式（模式 1/4）没有。
caddy_render_https_site() {
    local host=$1 port=$2 bind_address=$3 blocked=$4 subscription_ok=$5
    local cert_file key_file
    cert_file=$(caddy_origin_cert_file)
    key_file=$(caddy_origin_key_file)
    printf 'https://%s:%s {\n' "${host}" "${port}"
    printf '\tbind %s\n' "${bind_address}"
    printf '\ttls %s %s\n' "${cert_file}" "${key_file}"
    printf '\theader -Server\n\n'
    printf '\troute {\n'
    if caddy_protocol_needs_origin_guard; then
        caddy_validate_origin_secret "${ORIGIN_HEADER_SECRET:-}" \
            || die "源站头密钥格式无效，无法生成 Caddy 守卫"
        # 守卫必须是外层 route 的首个指令；客户端头值不拼进表达式源码。
        printf '\t\t@easy_all_bad_origin expression {http.request.header.X-Easy-All-Origin-Key} != \x27%s\x27\n' \
            "${ORIGIN_HEADER_SECRET}"
        printf '\t\tabort @easy_all_bad_origin\n\n'
    fi
    caddy_render_origin_routes "${blocked}" "${subscription_ok}" $'\t\t'
    printf '\t}\n'
    printf '}\n'
}

# 模式 4 伪装站：只监听回环 9443，给 sing-box 的 Reality handshake 一个真实的
# TLS 1.3 目标（仅使用直连主证书 CERT_FILE）。不提供订阅或源站头守卫。
caddy_render_camouflage_site() {
    local host
    host=$(caddy_require_host DIRECT_DOMAIN) || exit 1
    printf 'https://%s:%s {\n' "${host}" "$(caddy_reality_camouflage_port)"
    printf '\tbind 127.0.0.1\n'
    printf '\ttls %s %s\n' "${CERT_FILE}" "${KEY_FILE}"
    printf '\theader -Server\n\n'
    printf '\troute {\n'
    caddy_render_camouflage_routes $'\t\t'
    printf '\t}\n'
    printf '}\n'
}

# 模式 3 单 443 合一回环站：监听 127.0.0.1:9443，接收 sing-box Reality 的全部非 Reality 回落。
# 携带精确 X-Easy-All-Origin-Key 的 CloudFront 回源进入代理/订阅分支，其余全部流量落入伪装站。
caddy_render_unified_reality_site() {
    local blocked=$1 subscription_ok=$2
    local direct_host origin_host port address
    direct_host=$(caddy_require_host DIRECT_DOMAIN) || exit 1
    origin_host=$(caddy_require_host CF_ORIGIN_DOMAIN) || exit 1
    port=$(caddy_reality_camouflage_port)
    caddy_validate_origin_secret "${ORIGIN_HEADER_SECRET:-}" \
        || die "源站头密钥格式无效，无法生成 Caddy 守卫"
    if [[ "${origin_host}" == "${direct_host}" ]]; then
        address="https://${direct_host}:${port}"
    else
        address="https://${direct_host}:${port}, https://${origin_host}:${port}"
    fi
    printf '%s {\n' "${address}"
    printf '\tbind 127.0.0.1\n'
    printf '\ttls %s %s\n' "${CERT_FILE}" "${KEY_FILE}"
    printf '\theader -Server\n\n'
    printf '\troute {\n'
    printf '\t\t@easy_all_valid_origin expression {http.request.header.X-Easy-All-Origin-Key} == \x27%s\x27\n' \
        "${ORIGIN_HEADER_SECRET}"
    printf '\t\thandle @easy_all_valid_origin {\n'
    caddy_render_origin_routes "${blocked}" "${subscription_ok}" $'\t\t\t'
    printf '\t\t}\n'
    printf '\t\thandle {\n'
    caddy_render_camouflage_routes $'\t\t\t'
    printf '\t\t}\n'
    printf '\t}\n'
    printf '}\n'
}

# 模式 5 橙云回源站：监听 127.0.0.1:9443，使用只覆盖 CF_NODE_DOMAIN 的独立证书。
# 外层 route 首位按精确 X-Easy-All-Origin-Key 分流（命中进业务，未命中静默落伪装站，
# 严禁 abort）：缺头/错头的主动探测只能看到一个真实 TLS 站点。
caddy_render_split_origin_reality_site() {
    local blocked=$1 subscription_ok=$2
    local host port
    host=$(caddy_require_host CF_NODE_DOMAIN) || exit 1
    port=$(caddy_reality_camouflage_port)
    caddy_validate_origin_secret "${ORIGIN_HEADER_SECRET:-}" \
        || die "源站头密钥格式无效，无法生成 Caddy 守卫"
    printf 'https://%s:%s {\n' "${host}" "${port}"
    printf '\tbind 127.0.0.1\n'
    printf '\ttls %s %s\n' "$(caddy_origin_cert_file)" "$(caddy_origin_key_file)"
    printf '\theader -Server\n\n'
    printf '\troute {\n'
    printf '\t\t@easy_all_valid_origin expression {http.request.header.X-Easy-All-Origin-Key} == \x27%s\x27\n' \
        "${ORIGIN_HEADER_SECRET}"
    printf '\t\thandle @easy_all_valid_origin {\n'
    caddy_render_origin_routes "${blocked}" "${subscription_ok}" $'\t\t\t'
    printf '\t\t}\n'
    printf '\t\thandle {\n'
    caddy_render_camouflage_routes $'\t\t\t'
    printf '\t\t}\n'
    printf '\t}\n'
    printf '}\n'
}

# 外层 route 顺序：源站密钥守卫 → 精确代理路径 → 精确订阅入口 → 404（无 /easy_all-health）。
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
        if caddy_protocol_uses_xhttp && caddy_protocol_has_reality; then
            # 模式 5：两个回环 9443 站点块（直连伪装站 + 橙云 XHTTP 回源站），无公网 Caddy 端口。
            caddy_render_camouflage_site
            printf '\n'
            caddy_render_split_origin_reality_site "${blocked}" "${subscription_ok}"
        elif caddy_protocol_uses_unified_reality_site; then
            caddy_render_unified_reality_site "${blocked}" "${subscription_ok}"
            if caddy_mode3_needs_legacy_8443; then
                printf '\n'
                caddy_render_https_site "${host}" 8443 0.0.0.0 \
                    "${blocked}" "${subscription_ok}"
            fi
        elif caddy_protocol_has_reality; then
            caddy_render_camouflage_site
            printf '\n'
            caddy_render_https_site "${host}" "${port}" 0.0.0.0 \
                "${blocked}" "${subscription_ok}"
        else
            caddy_render_https_site "${host}" "${port}" 0.0.0.0 \
                "${blocked}" "${subscription_ok}"
        fi
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

# 按 host + port 精确提取站点块：模式 5 的两个块都在回环 9443，只能靠主机名区分。
caddy_site_block_lines_for_host() { # $1=文件 $2=host $3=端口
    awk -v address="https://$2:$3 {" '
        inside && $0 == "}" { exit }
        !inside && $0 == address { inside = 1; next }
        inside { print }
    ' "$1"
}

# 结构断言：外层 route 在任何 handle 之前、file_server 只在鉴权后的订阅处理器里、
# 订阅入口是精确路径、全模式禁止 /easy_all-health 且去除 Server 响应头。
caddy_config_structure_ok() {
    local file=$1 route_line handle_line sub_line file_server_line file_server_count
    [[ -s "${file}" ]] || return 1
    grep -Fq 'auto_https off' "${file}" || return 1
    grep -Fq 'header -Server' "${file}" || return 1
    if grep -Eq '/easy_all-health|easy_all ok' "${file}"; then
        return 1
    fi
    if caddy_protocol_has_reality; then
        caddy_reality_structure_ok "${file}"
        return
    fi
    grep -Fq 'bind 0.0.0.0' "${file}" || return 1
    if caddy_protocol_uses_xhttp; then
        # 模式 1：代理路径必须是 h2c XHTTP，且不得出现模式 5 独有的 default_sni/源站守卫/伪装站与
        # CloudFront 计量头。就绪态必须声明 h2c 且不缓冲；阻断态只允许 respond 503。
        grep -Fq "@easy_all_xhttp path ${VLESS_PATH:-} ${VLESS_PATH:-}/*" "${file}" || return 1
        if grep -Fq 'reverse_proxy 127.0.0.1:10086' "${file}"; then
            grep -Fq 'versions h2c 2' "${file}" || return 1
            grep -Fq 'flush_interval -1' "${file}" || return 1
        else
            grep -Fq 'respond 503' "${file}" || return 1
        fi
        if grep -Eq 'default_sni|X-Easy-All-Origin-Key|abort @easy_all_bad_origin|Subscription-Userinfo' \
            "${file}"; then
            return 1
        fi
    fi
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

# 否定断言只看指令行并排除 `root *` 路径行，避免 CAMOUFLAGE_DIR 里的 `/sub` 子串误拒：
# `root *` 目录名与 `tls` 证书路径都可能合法地包含 subscribe/sub 子串，站点地址行同理。
caddy_site_route_directives() { # stdin=站点块行 → 输出路由/匹配器/处理器指令行
    grep -v -E '^[[:space:]]*(root \*|tls)([[:space:]]|$)' || true
}

caddy_site_has_subscription_entry() { # stdin=指令行 → 0 表示出现订阅入口或 health
    grep -Eq '@easy_all_sub|/subscribe|/sub([^a-zA-Z0-9_-]|$)|/easy_all-health'
}

# 模式 4 的 9443 伪装块：只绑回环、只有伪装站，严禁任何订阅入口与源站头守卫。
caddy_reality_camouflage_structure_ok() { # $1=站点块行
    local camo=$1 directives page_line file_server_line file_server_count header
    grep -Fq 'bind 127.0.0.1' <<<"${camo}" || return 1
    grep -Fq 'tls ' <<<"${camo}" || return 1
    grep -Fq 'header -Server' <<<"${camo}" || return 1
    grep -Eq '^[[:space:]]*route[[:space:]]*{[[:space:]]*$' <<<"${camo}" || return 1
    grep -Fq '@easy_all_camo_page {' <<<"${camo}" || return 1
    grep -Fq '@easy_all_camo_dotfiles path */.*' <<<"${camo}" || return 1
    for header in 'Cache-Control "no-store"' 'X-Frame-Options "DENY"' \
        'X-Content-Type-Options "nosniff"' 'Referrer-Policy "same-origin"'; do
        grep -Fq "${header}" <<<"${camo}" || return 1
    done
    directives=$(caddy_site_route_directives <<<"${camo}")
    if caddy_site_has_subscription_entry <<<"${directives}"; then
        return 1
    fi
    if grep -Eq '@easy_all_bad_origin|@easy_all_valid_origin|X-Easy-All-Origin-Key' <<<"${camo}"; then
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

# 模式 3 单 443 合一的 9443 回环块：只绑回环，外层以精确 X-Easy-All-Origin-Key 隔离
# 业务回源分支与伪装站分支；禁止 /easy_all-health 与 0.0.0.0 绑定。
caddy_reality_unified_structure_ok() { # $1=站点块行
    local unified=$1 valid_line valid_handle_line sub_line page_line file_server_count header
    grep -Fq 'bind 127.0.0.1' <<<"${unified}" || return 1
    if grep -Fq 'bind 0.0.0.0' <<<"${unified}"; then
        return 1
    fi
    grep -Fq 'tls ' <<<"${unified}" || return 1
    grep -Fq 'header -Server' <<<"${unified}" || return 1
    grep -Eq '^[[:space:]]*route[[:space:]]*{[[:space:]]*$' <<<"${unified}" || return 1
    if grep -Eq '/easy_all-health|easy_all ok' <<<"${unified}"; then
        return 1
    fi
    grep -Fq "@easy_all_valid_origin expression {http.request.header.X-Easy-All-Origin-Key} == '" <<<"${unified}" || return 1
    grep -Fq '@easy_all_sub path /subscribe /sub' <<<"${unified}" || return 1
    grep -Fq '@easy_all_camo_page {' <<<"${unified}" || return 1
    grep -Fq '@easy_all_camo_dotfiles path */.*' <<<"${unified}" || return 1
    if grep -Eq 'handle /[^[:space:]]*\*|path /(subscribe|sub)\*' <<<"${unified}"; then
        return 1
    fi
    for header in 'Cache-Control "no-store"' 'X-Frame-Options "DENY"' \
        'X-Content-Type-Options "nosniff"' 'Referrer-Policy "same-origin"'; do
        grep -Fq "${header}" <<<"${unified}" || return 1
    done
    valid_line=$(grep -n '@easy_all_valid_origin expression' <<<"${unified}" | head -n 1 | cut -d: -f1)
    valid_handle_line=$(grep -n '^[[:space:]]*handle @easy_all_valid_origin {' <<<"${unified}" | head -n 1 | cut -d: -f1)
    sub_line=$(grep -n '^[[:space:]]*handle @easy_all_sub {' <<<"${unified}" | head -n 1 | cut -d: -f1)
    page_line=$(grep -n '^[[:space:]]*handle @easy_all_camo_page {' <<<"${unified}" | head -n 1 | cut -d: -f1)
    [[ -n "${valid_line}" && -n "${valid_handle_line}" && -n "${sub_line}" && -n "${page_line}" ]] || return 1
    ((valid_line < valid_handle_line && valid_handle_line < sub_line && sub_line < page_line)) || return 1
    # 伪装站恒含 1 个 file_server；订阅就绪时再加 1 个（合计 2），未就绪时为 1。
    file_server_count=$(grep -c '^[[:space:]]*file_server[[:space:]]*$' <<<"${unified}" || true)
    ((file_server_count == 1 || file_server_count == 2)) || return 1
    return 0
}

# 8443 回源块（模式 4 橙云回源，或模式 3 旧装过渡期 8443 兼容块）。
caddy_reality_origin_structure_ok() { # $1=站点块行
    local origin=$1 bad_origin_line abort_line handle_line sub_line file_server_line file_server_count
    grep -Fq 'bind 0.0.0.0' <<<"${origin}" || return 1
    grep -Fq 'header -Server' <<<"${origin}" || return 1
    if grep -Eq '/easy_all-health|easy_all ok' <<<"${origin}"; then
        return 1
    fi
    if caddy_protocol_needs_origin_guard; then
        grep -Fq '@easy_all_bad_origin expression' <<<"${origin}" || return 1
        grep -Fq 'abort @easy_all_bad_origin' <<<"${origin}" || return 1
    fi
    bad_origin_line=$(grep -n '@easy_all_bad_origin' <<<"${origin}" | head -n 1 | cut -d: -f1)
    abort_line=$(grep -n '^[[:space:]]*abort @easy_all_bad_origin[[:space:]]*$' <<<"${origin}" \
        | head -n 1 | cut -d: -f1)
    handle_line=$(grep -n '^[[:space:]]*handle' <<<"${origin}" | head -n 1 | cut -d: -f1)
    if caddy_protocol_needs_origin_guard; then
        [[ -n "${bad_origin_line}" && -n "${abort_line}" && -n "${handle_line}" ]] || return 1
        ((bad_origin_line < handle_line && abort_line < handle_line)) || return 1
    fi
    grep -Fq '@easy_all_sub path /subscribe /sub' <<<"${origin}" || return 1
    if grep -Eq 'handle /[^[:space:]]*\*|path /(subscribe|sub)\*' <<<"${origin}"; then
        return 1
    fi
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

# 模式 5 直连主机站点块：只挂伪装站，仅用直连主证书，无源站守卫/代理/订阅入口。
caddy_xhttp_direct_site_structure_ok() { # $1=站点块行（直连主机）
    local camo=$1
    caddy_reality_camouflage_structure_ok "${camo}" || return 1
    grep -Fq "tls ${CERT_FILE} ${KEY_FILE}" <<<"${camo}" || return 1
    return 0
}

# 模式 5 橙云主机站点块：回环绑定 + 独立橙云证书 + 首位源站密钥守卫 + h2c XHTTP 反代。
caddy_xhttp_origin_site_structure_ok() { # $1=站点块行（橙云主机）
    local origin=$1 valid_line valid_handle_line xhttp_line sub_line page_line file_server_count header
    grep -Fq 'bind 127.0.0.1' <<<"${origin}" || return 1
    if grep -Fq 'bind 0.0.0.0' <<<"${origin}"; then
        return 1
    fi
    grep -Fq "tls ${CDN_CERT_FILE} ${CDN_KEY_FILE}" <<<"${origin}" || return 1
    grep -Fq 'header -Server' <<<"${origin}" || return 1
    grep -Fq "@easy_all_valid_origin expression {http.request.header.X-Easy-All-Origin-Key} == '" \
        <<<"${origin}" || return 1
    grep -Fq '@easy_all_sub path /subscribe /sub' <<<"${origin}" || return 1
    grep -Fq '@easy_all_camo_page {' <<<"${origin}" || return 1
    grep -Fq "@easy_all_xhttp path ${VLESS_PATH} ${VLESS_PATH}/*" <<<"${origin}" || return 1
    # 就绪态必须声明 h2c 且不缓冲；阻断态只允许 respond 503，不得留下反代与 h2c 声明。
    if grep -Fq 'reverse_proxy 127.0.0.1:10086' <<<"${origin}"; then
        grep -Fq 'versions h2c 2' <<<"${origin}" || return 1
        grep -Fq 'flush_interval -1' <<<"${origin}" || return 1
    else
        grep -Fq 'respond 503' <<<"${origin}" || return 1
    fi
    if grep -Eq '/easy_all-health|easy_all ok' <<<"${origin}"; then
        return 1
    fi
    if grep -Eq 'abort @easy_all_bad_origin|handle /[^[:space:]]*\*|path /(subscribe|sub)\*' \
        <<<"${origin}"; then
        return 1
    fi
    for header in 'Cache-Control "no-store"' 'X-Frame-Options "DENY"' \
        'X-Content-Type-Options "nosniff"' 'Referrer-Policy "same-origin"'; do
        grep -Fq "${header}" <<<"${origin}" || return 1
    done
    valid_line=$(grep -n '@easy_all_valid_origin expression' <<<"${origin}" | head -n 1 | cut -d: -f1)
    valid_handle_line=$(grep -n '^[[:space:]]*handle @easy_all_valid_origin {' <<<"${origin}" \
        | head -n 1 | cut -d: -f1)
    xhttp_line=$(grep -n '^[[:space:]]*@easy_all_xhttp path ' <<<"${origin}" | head -n 1 | cut -d: -f1)
    sub_line=$(grep -n '^[[:space:]]*handle @easy_all_sub {' <<<"${origin}" | head -n 1 | cut -d: -f1)
    page_line=$(grep -n '^[[:space:]]*handle @easy_all_camo_page {' <<<"${origin}" | head -n 1 | cut -d: -f1)
    [[ -n "${valid_line}" && -n "${valid_handle_line}" && -n "${xhttp_line}" \
        && -n "${sub_line}" && -n "${page_line}" ]] || return 1
    ((valid_line < valid_handle_line && valid_handle_line < xhttp_line \
        && xhttp_line < sub_line && sub_line < page_line)) || return 1
    # 伪装站恒含 1 个 file_server；订阅就绪时再加 1 个（合计 2），未就绪时为 1。
    file_server_count=$(grep -c '^[[:space:]]*file_server[[:space:]]*$' <<<"${origin}" || true)
    ((file_server_count == 1 || file_server_count == 2)) || return 1
    return 0
}

caddy_reality_structure_ok() {
    local file=$1 camo origin site_blocks
    site_blocks=$(grep -Ec '^https://.*:[0-9]+ \{$' "${file}")
    # 本函数只在 caddy_protocol_has_reality 为真时调用，因此内部的 uses_xhttp 仍唯一指代模式 5。
    if caddy_protocol_uses_xhttp; then
        # 模式 5：两个回环 9443 站点块（直连伪装站 + 橙云 XHTTP 回源站），全局 default_sni 锁定直连证书。
        grep -Fq "default_sni ${DIRECT_DOMAIN}" "${file}" || return 1
        if grep -Fq 'bind 0.0.0.0' "${file}"; then
            return 1
        fi
        if grep -Fq 'Subscription-Userinfo' "${file}"; then
            return 1
        fi
        camo=$(caddy_site_block_lines_for_host "${file}" "${DIRECT_DOMAIN}" \
            "$(caddy_reality_camouflage_port)")
        origin=$(caddy_site_block_lines_for_host "${file}" "${CF_NODE_DOMAIN}" \
            "$(caddy_reality_camouflage_port)")
        [[ -n "${camo}" && -n "${origin}" ]] || return 1
        caddy_xhttp_direct_site_structure_ok "${camo}" || return 1
        caddy_xhttp_origin_site_structure_ok "${origin}" || return 1
        ((site_blocks == 2)) || return 1
        return 0
    fi
    if caddy_protocol_uses_unified_reality_site; then
        camo=$(caddy_site_block_lines "${file}" "$(caddy_reality_camouflage_port)")
        [[ -n "${camo}" ]] || return 1
        caddy_reality_unified_structure_ok "${camo}" || return 1
        if caddy_mode3_needs_legacy_8443; then
            origin=$(caddy_site_block_lines "${file}" 8443)
            [[ -n "${origin}" ]] || return 1
            caddy_reality_origin_structure_ok "${origin}" || return 1
            ((site_blocks == 2)) || return 1
        else
            ((site_blocks == 1)) || return 1
        fi
        return 0
    fi
    camo=$(caddy_site_block_lines "${file}" "$(caddy_reality_camouflage_port)")
    origin=$(caddy_site_block_lines "${file}" "$(caddy_site_port)")
    [[ -n "${camo}" && -n "${origin}" ]] || return 1
    caddy_reality_camouflage_structure_ok "${camo}" || return 1
    caddy_reality_origin_structure_ok "${origin}" || return 1
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
