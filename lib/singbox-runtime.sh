#!/usr/bin/env bash

# 三模式 sing-box 本机配置与客户端节点（模式 2/3/4；模式 1/5 走 lib/xray-runtime.sh）（design §7、§12）。
# 依赖调用方提供 log.sh 的 die/warn/info/fail，以及模式字段：
# PROTOCOL、DIRECT_DOMAIN、DIRECT_NODE_NAME、VLESS_UUID、VLESS_PATH、
# REALITY_PRIVATE_KEY、REALITY_PUBLIC_KEY、REALITY_SHORT_ID、
# CF_NODE_DOMAIN、CF_NODE_PREFIX。CF_EDGE_ADDRESS 可选：非空时只替换本机 CDN 节点的
# 连接地址，SNI 与 transport Host 仍是 CF_NODE_DOMAIN（订阅配置里的 cdnEdgeAddress）。
# 证书路径与核心路径可用环境变量覆盖（测试隔离）。

SINGBOX_RUNTIME_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib/singbox-core.sh
source "${SINGBOX_RUNTIME_LIB_DIR}/singbox-core.sh"

: "${CERT_DIR:=/etc/easy_all/certs}"
: "${CERT_FILE:=${CERT_DIR}/fullchain.pem}"
: "${KEY_FILE:=${CERT_DIR}/private.key}"
: "${DIRECT_NODE_NAME:=Reality}"
: "${CF_NODE_PREFIX:=VLESS-WS}"

singbox_require_protocol() {
    case "${PROTOCOL:-}" in
    reality-cloudfront | reality-cloudflare | cloudfront) return 0 ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

singbox_protocol_has_reality() {
    case "${PROTOCOL:-}" in
    reality-cloudfront | reality-cloudflare) return 0 ;;
    esac
    return 1
}

singbox_protocol_has_cdn() {
    case "${PROTOCOL:-}" in
    cloudfront | reality-cloudfront | reality-cloudflare) return 0 ;;
    esac
    return 1
}

# CDN 传输按 CDN 家族区分：CloudFront 会改写 Connection 并剥离非完整 WebSocket 握手
# 的 Upgrade 头，只有模式 4（reality-cloudflare）能用 httpupgrade；其余一律 ws。
# 模式 1 已改为纯 Xray XHTTP 后端，不再进入本库。
singbox_cdn_transport_type() {
    case "${PROTOCOL:-}" in
    reality-cloudflare) printf 'httpupgrade\n' ;;
    *) printf 'ws\n' ;;
    esac
}

singbox_uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

# 服务端 sing-box 出站私网与保留网段拦截清单单一来源：
# sing-box 路由必须拒绝同一组私网/特殊地址（含回环、链路本地元数据、CGNAT、多播与保留段）。
singbox_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4"
    ]'
}

# Reality 自偷入站：443 上完成 REALITY 握手，非 Reality 探测由 sing-box 透明转发到
# 127.0.0.1:9443 的 Caddy 伪装站（端口常量见 caddy_reality_camouflage_port）。
singbox_reality_inbound_json() {
    singbox_protocol_has_reality || { printf 'null'; return 0; }
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 Reality 入站"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 Reality 入站"
    [[ -n "${REALITY_PRIVATE_KEY:-}" ]] || die "缺少 REALITY_PRIVATE_KEY，无法生成 Reality 入站"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 Reality 入站"
    jq -cn --arg uuid "${VLESS_UUID}" --arg domain "${DIRECT_DOMAIN}" \
        --arg key "${REALITY_PRIVATE_KEY}" --arg sid "${REALITY_SHORT_ID}" '
        {
          type: "vless",
          tag: "vless-reality-in",
          listen: "0.0.0.0",
          listen_port: 443,
          users: [{name: "easy_all", uuid: $uuid, flow: "xtls-rprx-vision"}],
          tls: {
            enabled: true,
            server_name: $domain,
            reality: {
              enabled: true,
              handshake: {server: "127.0.0.1", server_port: 9443},
              private_key: $key,
              short_id: [$sid],
              max_time_difference: "2m"
            }
          }
        }'
}

# blocked=1 时省略 CDN 入站：模式 3/4 保留直连入站，重启核心即终止旧 CDN 长连接。
singbox_vless_inbound_json() {
    local blocked=$1
    singbox_protocol_has_cdn || { printf 'null'; return 0; }
    [[ "${blocked}" != "1" ]] || { printf 'null'; return 0; }
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 VLESS 入站"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 VLESS 入站"
    jq -cn --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" \
        --arg transport "$(singbox_cdn_transport_type)" '
        {
          type: "vless",
          tag: "vless-cdn-in",
          listen: "127.0.0.1",
          listen_port: 10086,
          users: [{name: "easy_all", uuid: $uuid}],
          transport: {type: $transport, path: $path}
        }'
}

singbox_inbounds_json() {
    local blocked=$1
    jq -cn --argjson reality "$(singbox_reality_inbound_json)" \
        --argjson vless "$(singbox_vless_inbound_json "${blocked}")" \
        '[$reality, $vless] | map(select(. != null))'
}

render_singbox_config() {
    local dest=$1 blocked=${2:-0}
    [[ -n "${dest}" ]] || die "render_singbox_config 需要目标路径"
    [[ "${blocked}" == "0" || "${blocked}" == "1" ]] \
        || die "sing-box blocked 状态无效：${blocked}"
    singbox_require_protocol
    # 首条 resolve 是 SSRF 阻断的前提，也是「解析失败不等于放行」的依据：sing-box 在解析出错
    # （NXDOMAIN、超时、NOERROR 无地址）时以错误终止连接，不会回落到 final: direct。
    # 已对上游 1.12.0 与 master 核验 route/route.go（RuleActionResolve 的错误为 fatal）与
    # dns/router.go（Lookup 把「无地址」改写为 error）；锁定核心升级时需复核这两处。
    # 引导解析只有单源 1.1.1.1：不配 fallback 条目（配了也不会被使用，属死配置），
    # 1.1.1.1 不可达时按 fail 显式失败，不做静默降级。
    jq -n \
        --argjson inbounds "$(singbox_inbounds_json "${blocked}")" \
        --argjson private "$(singbox_private_ranges_json)" '
        {
          log: {level: "warning", timestamp: true},
          dns: {
            servers: [
              {type: "udp", tag: "easy_all-ipv4-primary", server: "1.1.1.1"}
            ],
            strategy: "ipv4_only"
          },
          inbounds: $inbounds,
          outbounds: [{type: "direct", tag: "direct"}],
          route: {
            default_domain_resolver: "easy_all-ipv4-primary",
            rules: [
              {action: "resolve"},
              {ip_is_private: true, action: "reject"},
              {ip_cidr: $private, action: "reject"}
            ],
            final: "direct"
          }
        }' >"${dest}" || die "生成 sing-box 配置失败：${dest}"
}

singbox_config_structure_ok() {
    jq -e '
        type == "object"
        and (.log | type == "object" and (.level | type == "string"))
        and (.dns | type == "object"
             and (.servers | type == "array" and length > 0)
             and .strategy == "ipv4_only")
        and (.inbounds | type == "array")
        and (all(.inbounds[];
                 (.type | type == "string")
                 and (.listen | type == "string")
                 and (.listen_port | type == "number")))
        and (.outbounds | type == "array" and length > 0)
        and (.route | type == "object"
             and (.default_domain_resolver | type == "string")
             and (.final | type == "string")
             and (.rules | type == "array" and length > 0))
    ' "$1" >/dev/null 2>&1
}

# 有候选核心时用真实 `sing-box check`；否则只做结构校验（缺 jq 字段即失败）。
# 候选文件在 RUNTIME_TMP 下随运行结束删除：失败文案不点名路径，validator 的
# stderr 仍原样交给调用方。
validate_singbox_config() {
    local file=$1
    [[ -s "${file}" ]] || { fail "sing-box 配置不存在或为空"; return 1; }
    if [[ -x "${SINGBOX_BIN}" ]]; then
        "${SINGBOX_BIN}" check -c "${file}" >/dev/null \
            || { fail "sing-box check 未通过"; return 1; }
        return 0
    fi
    singbox_config_structure_ok "${file}" \
        || { fail "sing-box 配置结构校验失败"; return 1; }
}

write_singbox_config() {
    local blocked=${1:-0} candidate stage target_dir
    [[ -n "${RUNTIME_TMP:-}" ]] || die "运行时临时目录未初始化，无法写入 sing-box 配置"
    candidate="${RUNTIME_TMP}/singbox-config.next.json"
    render_singbox_config "${candidate}" "${blocked}"
    # 发布前必须过校验：候选核心存在时跑真实 `sing-box check`，否则退回结构断言；
    # 校验失败即中止，已发布的旧配置保持不变。
    validate_singbox_config "${candidate}" \
        || die "候选 sing-box 配置校验失败（候选文件随本次运行结束删除）"
    target_dir=$(dirname "${SINGBOX_CONFIG}")
    install -d -m 0700 "${target_dir}" \
        || die "创建 sing-box 配置目录失败：${target_dir}"
    stage=$(mktemp "${SINGBOX_CONFIG}.XXXXXX") \
        || die "创建 sing-box 配置暂存文件失败：${target_dir}"
    if ! { install -m 0600 "${candidate}" "${stage}" \
        && mv -f -- "${stage}" "${SINGBOX_CONFIG}"; }; then
        rm -f -- "${stage}"
        die "发布 sing-box 配置失败：${SINGBOX_CONFIG}"
    fi
}

# --- 客户端节点（design §12） -------------------------------------------------

build_reality_link() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 Reality 节点链接"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 Reality 节点链接"
    [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || die "缺少 REALITY_PUBLIC_KEY，无法生成 Reality 节点链接"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 Reality 节点链接"
    # 节点名可含空格/表情/分隔符，必须 URI 编码后才能出现在 # 片段。
    printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${DIRECT_DOMAIN}" "${DIRECT_DOMAIN}" \
        "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}" \
        "$(singbox_uri_encode "${DIRECT_NODE_NAME}")"
}

# 不开 support-x25519mlkem768：保持经典 X25519，与服务端 sing-box 1.14.4 握手一致。
build_mihomo_reality_node() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 Reality 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 Reality 节点"
    [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || die "缺少 REALITY_PUBLIC_KEY，无法生成 Reality 节点"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 Reality 节点"
    jq -nr --arg name "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" --arg pbk "${REALITY_PUBLIC_KEY}" \
        --arg sid "${REALITY_SHORT_ID}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    tls: true\n    udp: true\n" +
        "    flow: xtls-rprx-vision\n    servername: \($server|@json)\n" +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n" +
        "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n"'
}

build_vless_ws_link() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 VLESS 节点链接"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 VLESS 节点链接"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 VLESS 节点链接"
    local encoded_host transport
    encoded_host=$(singbox_uri_encode "${CF_NODE_DOMAIN}")
    # httpupgrade 必须显式锁 ALPN http/1.1：h2 协商下客户端发不出 Upgrade 握手。
    if [[ "$(singbox_cdn_transport_type)" == "httpupgrade" ]]; then
        transport='type=httpupgrade&alpn=http%2F1.1'
    else
        transport='type=ws'
    fi
    # 连接地址可用 cdnEdgeAddress 换成优选域名；sni/host 仍是分发域名（证书与分发按它选）。
    printf 'vless://%s@%s:443?encryption=none&security=tls&%s&sni=%s&fp=chrome&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${CF_EDGE_ADDRESS:-${CF_NODE_DOMAIN}}" "${transport}" \
        "${encoded_host}" "${encoded_host}" \
        "$(singbox_uri_encode "${VLESS_PATH}")" \
        "$(singbox_uri_encode "${CF_NODE_PREFIX}")"
}

# server 是连接地址（可为优选域名），servername 与 transport Host 必须是节点域名。
# Mihomo 的 HTTPUpgrade 仍是 network: ws + ws-opts.v2ray-http-upgrade。
build_mihomo_ws_node() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 VLESS 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 VLESS 节点"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 VLESS 节点"
    local alpn='' upgrade=''
    if [[ "$(singbox_cdn_transport_type)" == "httpupgrade" ]]; then
        alpn=$'    alpn:\n      - http/1.1\n'
        upgrade=$'      v2ray-http-upgrade: true\n'
    fi
    jq -nr --arg name "${CF_NODE_PREFIX}" --arg server "${CF_EDGE_ADDRESS:-${CF_NODE_DOMAIN}}" \
        --arg host "${CF_NODE_DOMAIN}" --arg alpn "${alpn}" --arg upgrade "${upgrade}" \
        --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: ws\n    tls: true\n    udp: true\n" + $alpn +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n" +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n" +
        "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($host|@json)\n" +
        $upgrade'
}

# --- sing-box 客户端订阅节点 -------------------------------------------------

build_singbox_reality_outbound() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 sing-box Reality 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 sing-box Reality 节点"
    [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || die "缺少 REALITY_PUBLIC_KEY，无法生成 sing-box Reality 节点"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 sing-box Reality 节点"
    jq -cn --arg tag "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" --arg pbk "${REALITY_PUBLIC_KEY}" \
        --arg sid "${REALITY_SHORT_ID}" '
        {type: "vless", tag: $tag, server: $server, server_port: 443, uuid: $uuid,
         flow: "xtls-rprx-vision",
         tls: {enabled: true, server_name: $server,
               utls: {enabled: true, fingerprint: "chrome"},
               reality: {enabled: true, public_key: $pbk, short_id: $sid}},
         packet_encoding: "xudp"}'
}

# 本机 CDN 节点：连接地址可用 cdnEdgeAddress 换成优选域名；SNI 与 transport Host
# 仍是节点域名，源站头永不进入客户端。httpupgrade 用标准 host 字段承载 Host。
build_singbox_ws_outbound() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 sing-box VLESS 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 sing-box VLESS 节点"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 sing-box VLESS 节点"
    local transport alpn='null'
    transport=$(singbox_cdn_transport_type)
    [[ "${transport}" != "httpupgrade" ]] || alpn='["http/1.1"]'
    jq -cn --arg tag "${CF_NODE_PREFIX}" --arg server "${CF_EDGE_ADDRESS:-${CF_NODE_DOMAIN}}" \
        --arg host "${CF_NODE_DOMAIN}" --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" \
        --arg transport "${transport}" --argjson alpn "${alpn}" '
        {type: "vless", tag: $tag, server: $server, server_port: 443, uuid: $uuid,
         tls: ({enabled: true, server_name: $host,
                utls: {enabled: true, fingerprint: "chrome"}}
               + (if $alpn then {alpn: $alpn} else {} end)),
         transport: (if $transport == "httpupgrade"
                     then {type: "httpupgrade", path: $path, host: $host}
                     else {type: "ws", path: $path, headers: {Host: $host}} end),
         packet_encoding: "xudp"}'
}
