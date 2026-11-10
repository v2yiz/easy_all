#!/usr/bin/env bash

# 四模式 sing-box 本机配置与客户端节点（design §7、§12）。
# 依赖调用方提供 log.sh 的 die/warn/info/fail，以及模式字段：
# PROTOCOL、DIRECT_DOMAIN、DIRECT_NODE_NAME、ANYTLS_PASSWORD、VLESS_UUID、VLESS_PATH、
# CF_NODE_DOMAIN、CF_NODE_PREFIX。证书路径与核心路径可用环境变量覆盖（测试隔离）。

SINGBOX_RUNTIME_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib/singbox-core.sh
source "${SINGBOX_RUNTIME_LIB_DIR}/singbox-core.sh"

: "${CERT_DIR:=/etc/easy_all/certs}"
: "${CERT_FILE:=${CERT_DIR}/fullchain.pem}"
: "${KEY_FILE:=${CERT_DIR}/private.key}"
: "${DIRECT_NODE_NAME:=AnyTLS}"
: "${CF_NODE_PREFIX:=VLESS-WS}"

singbox_require_protocol() {
    case "${PROTOCOL:-}" in
    anytls | cloudfront | cloudflare | combined-cloudfront) return 0 ;;
    *) die "不支持的 PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

singbox_protocol_has_anytls() {
    case "${PROTOCOL:-}" in
    anytls | combined-cloudfront) return 0 ;;
    esac
    return 1
}

singbox_protocol_has_cdn() {
    case "${PROTOCOL:-}" in
    cloudfront | cloudflare | combined-cloudfront) return 0 ;;
    esac
    return 1
}

singbox_uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

# 与 lib/network.sh 的 xray_private_ranges_json 的 IPv4 部分逐项一致：阶段 2 统一清单前，
# sing-box 路由必须拒绝同一组私网/特殊地址（含回环、链路本地元数据、CGNAT、多播与保留段）。
singbox_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4"
    ]'
}

singbox_anytls_inbound_json() {
    singbox_protocol_has_anytls || { printf 'null'; return 0; }
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 AnyTLS 入站"
    [[ -n "${ANYTLS_PASSWORD:-}" ]] || die "缺少 ANYTLS_PASSWORD，无法生成 AnyTLS 入站"
    jq -cn --arg domain "${DIRECT_DOMAIN}" --arg password "${ANYTLS_PASSWORD}" \
        --arg cert "${CERT_FILE}" --arg key "${KEY_FILE}" '
        {
          type: "anytls",
          tag: "anytls-in",
          listen: "0.0.0.0",
          listen_port: 443,
          users: [{name: "easy_all", password: $password}],
          tls: {
            enabled: true,
            server_name: $domain,
            certificate_path: $cert,
            key_path: $key
          }
        }'
}

# blocked=1 时省略 CDN 入站：模式 4 保留 AnyTLS，重启核心即终止旧 CDN 长连接。
singbox_vless_inbound_json() {
    local blocked=$1
    singbox_protocol_has_cdn || { printf 'null'; return 0; }
    [[ "${blocked}" != "1" ]] || { printf 'null'; return 0; }
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 VLESS 入站"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 VLESS 入站"
    jq -cn --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" '
        {
          type: "vless",
          tag: "vless-cdn-in",
          listen: "127.0.0.1",
          listen_port: 10086,
          users: [{name: "easy_all", uuid: $uuid}],
          transport: {type: "ws", path: $path}
        }'
}

singbox_inbounds_json() {
    local blocked=$1
    jq -cn --argjson anytls "$(singbox_anytls_inbound_json)" \
        --argjson vless "$(singbox_vless_inbound_json "${blocked}")" \
        '[$anytls, $vless] | map(select(. != null))'
}

render_singbox_config() {
    local dest=$1 blocked=${2:-0}
    [[ -n "${dest}" ]] || die "render_singbox_config 需要目标路径"
    [[ "${blocked}" == "0" || "${blocked}" == "1" ]] \
        || die "sing-box blocked 状态无效：${blocked}"
    singbox_require_protocol
    jq -n \
        --argjson inbounds "$(singbox_inbounds_json "${blocked}")" \
        --argjson private "$(singbox_private_ranges_json)" '
        {
          log: {level: "warning", timestamp: true},
          dns: {
            servers: [
              {type: "udp", tag: "easy_all-ipv4-primary", server: "1.1.1.1"},
              {type: "udp", tag: "easy_all-ipv4-fallback", server: "8.8.8.8"}
            ],
            strategy: "ipv4_only"
          },
          inbounds: $inbounds,
          outbounds: [{type: "direct", tag: "direct"}],
          route: {
            default_domain_resolver: "easy_all-ipv4-primary",
            rules: [
              {ip_is_private: true, action: "reject"},
              {ip_cidr: $private, action: "reject"},
              {network: "udp", port: 443, action: "reject"}
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

build_anytls_link() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 AnyTLS 节点链接"
    [[ -n "${ANYTLS_PASSWORD:-}" ]] || die "缺少 ANYTLS_PASSWORD，无法生成 AnyTLS 节点链接"
    printf 'anytls://%s@%s:443/?sni=%s&insecure=0#%s' \
        "$(singbox_uri_encode "${ANYTLS_PASSWORD}")" \
        "${DIRECT_DOMAIN}" \
        "$(singbox_uri_encode "${DIRECT_DOMAIN}")" \
        "$(singbox_uri_encode "${DIRECT_NODE_NAME}")"
}

build_mihomo_anytls_node() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 AnyTLS 节点"
    [[ -n "${ANYTLS_PASSWORD:-}" ]] || die "缺少 ANYTLS_PASSWORD，无法生成 AnyTLS 节点"
    jq -nr --arg name "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" \
        --arg password "${ANYTLS_PASSWORD}" '
        "  - name: \($name|@json)\n    type: anytls\n    server: \($server|@json)\n    port: 443\n" +
        "    password: \($password|@json)\n    sni: \($server|@json)\n" +
        "    client-fingerprint: chrome\n    udp: true\n    skip-cert-verify: false\n"'
}

build_vless_ws_link() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 VLESS 节点链接"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 VLESS 节点链接"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 VLESS 节点链接"
    local encoded_host
    encoded_host=$(singbox_uri_encode "${CF_NODE_DOMAIN}")
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=ws&sni=%s&fp=chrome&host=%s&path=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${CF_NODE_DOMAIN}" "${encoded_host}" "${encoded_host}" \
        "$(singbox_uri_encode "${VLESS_PATH}")" \
        "$(singbox_uri_encode "${CF_NODE_PREFIX}")"
}

build_mihomo_ws_node() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 VLESS 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 VLESS 节点"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 VLESS 节点"
    jq -nr --arg name "${CF_NODE_PREFIX}" --arg server "${CF_NODE_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: ws\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($server|@json)\n" +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n" +
        "    ws-opts:\n      path: \($path|@json)\n      headers:\n        Host: \($server|@json)\n"'
}
