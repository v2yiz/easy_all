#!/usr/bin/env bash

# 模式 1（cloudflare）与模式 5（reality-cloudflare-xhttp）的 Xray 本机配置与
# 客户端节点（design §2.2 / v2 §3.2）。模式 1 只有回环 XHTTP 入站，模式 5 另有
# Reality 直连入站。
# 依赖调用方提供 log.sh 的 die/warn/info/fail，以及模式字段：
# PROTOCOL、DIRECT_DOMAIN、DIRECT_NODE_NAME、VLESS_UUID、VLESS_PATH、
# REALITY_PRIVATE_KEY、REALITY_PUBLIC_KEY、REALITY_SHORT_ID、
# CF_NODE_DOMAIN、CF_NODE_PREFIX。CF_EDGE_ADDRESS 可选：非空时只替换橙云节点的连接地址，
# SNI 与 XHTTP host 仍是 CF_NODE_DOMAIN（订阅配置里的 cdnEdgeAddress）。
# 路径与核心路径可用环境变量覆盖（测试隔离）。
#
# 本库独立实现私网阻断清单：模式 5 不调用 lib/singbox-runtime.sh 的任何函数，
# 因此 xray_private_ranges_json 与 singbox_private_ranges_json 是两份并列定义，
# 二者的一致性由 test/test_xray_render.sh 断言（design §2.2 / d3）。

XRAY_RUNTIME_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)
# shellcheck source=lib/xray-core.sh
source "${XRAY_RUNTIME_LIB_DIR}/xray-core.sh"

: "${CERT_DIR:=/etc/easy_all/certs}"
: "${CERT_FILE:=${CERT_DIR}/fullchain.pem}"
: "${KEY_FILE:=${CERT_DIR}/private.key}"
: "${DIRECT_NODE_NAME:=Reality}"
: "${CF_NODE_PREFIX:=CF}"

xray_uri_encode() {
    jq -rn --arg value "$1" '$value|@uri'
}

# 是否渲染 Reality 直连入站：模式 5 为真；模式 1（cloudflare）为假；空 PROTOCOL
# 按模式 5 处理，兼容直接调用渲染器的既有夹具。
xray_protocol_has_reality() {
    case "${PROTOCOL:-}" in
    reality-cloudflare-xhttp | "") return 0 ;;
    cloudflare) return 1 ;;
    *) die "不支持的 Xray PROTOCOL：${PROTOCOL:-空}" ;;
    esac
}

# 服务端出站私网与保留网段拦截清单（与 singbox_private_ranges_json 同一组 11 条 IPv4 CIDR）。
# 显式清单而非核心内置 geoip：SSRF 阻断语义不依赖未核验的核心默认行为。
xray_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4"
    ]'
}

# 直连 443：VLESS + raw/tcp + xtls-rprx-vision + Reality；非 Reality 握手透明回落到
# 127.0.0.1:9443 的 Caddy（端口常量见 caddy_reality_camouflage_port）。
xray_reality_inbound_json() {
    xray_protocol_has_reality || { printf 'null'; return 0; }
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 Reality 入站"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 Reality 入站"
    [[ -n "${REALITY_PRIVATE_KEY:-}" ]] || die "缺少 REALITY_PRIVATE_KEY，无法生成 Reality 入站"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 Reality 入站"
    jq -cn --arg uuid "${VLESS_UUID}" --arg domain "${DIRECT_DOMAIN}" \
        --arg key "${REALITY_PRIVATE_KEY}" --arg sid "${REALITY_SHORT_ID}" '
        {
          tag: "vless-reality-in",
          listen: "0.0.0.0",
          port: 443,
          protocol: "vless",
          settings: {
            clients: [{id: $uuid, email: "easy_all", flow: "xtls-rprx-vision"}],
            decryption: "none"
          },
          streamSettings: {
            network: "raw",
            security: "reality",
            realitySettings: {
              show: false,
              target: "127.0.0.1:9443",
              xver: 0,
              serverNames: [$domain],
              privateKey: $key,
              shortIds: [$sid],
              maxTimeDiff: 120000
            }
          }
        }'
}

# 回环 10086：VLESS + XHTTP（服务端 mode=auto）。blocked=1 时省略该入站，
# 重启核心即终止旧 CDN 长连接（与模式 3/4 的 blocked 语义一致）。
xray_xhttp_inbound_json() {
    local blocked=$1
    [[ "${blocked}" != "1" ]] || { printf 'null'; return 0; }
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 XHTTP 入站"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 XHTTP 入站"
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 XHTTP 入站"
    # xPaddingBytes / scStreamUpServerSecs 必须位于 xhttpSettings.extra：Xray 只从 extra 读这两个字段。
    jq -cn --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" --arg host "${CF_NODE_DOMAIN}" '
        {
          tag: "vless-cdn-in",
          listen: "127.0.0.1",
          port: 10086,
          protocol: "vless",
          settings: {
            clients: [{id: $uuid, email: "easy_all"}],
            decryption: "none"
          },
          streamSettings: {
            network: "xhttp",
            xhttpSettings: {
              path: $path,
              host: $host,
              mode: "auto",
              extra: {
                xPaddingBytes: "100-1000",
                scStreamUpServerSecs: "20-80"
              }
            }
          }
        }'
}

xray_inbounds_json() {
    local blocked=$1
    jq -cn --argjson reality "$(xray_reality_inbound_json)" \
        --argjson vless "$(xray_xhttp_inbound_json "${blocked}")" \
        '[$reality, $vless] | map(select(. != null))'
}

render_xray_config() {
    local dest=$1 blocked=${2:-0}
    [[ -n "${dest}" ]] || die "render_xray_config 需要目标路径"
    [[ "${blocked}" == "0" || "${blocked}" == "1" ]] \
        || die "Xray blocked 状态无效：${blocked}"
    # DNS 只用 8.8.8.8（支持 ECS，便于就近调度 YouTube/Google 边缘节点）且强制 IPv4：
    # 解析失败按错误终止连接，不回落到 direct。
    # 私网与 IPv6（::/0）全部打入 blackhole，阻断语义只由显式路由承载。
    jq -n \
        --argjson inbounds "$(xray_inbounds_json "${blocked}")" \
        --argjson private "$(xray_private_ranges_json)" '
        {
          log: {loglevel: "warning"},
          dns: {servers: ["8.8.8.8"], queryStrategy: "UseIPv4"},
          inbounds: $inbounds,
          outbounds: [
            {tag: "direct", protocol: "freedom", settings: {domainStrategy: "UseIPv4"}},
            {tag: "block", protocol: "blackhole", settings: {}}
          ],
          routing: {
            domainStrategy: "IPIfNonMatch",
            rules: [
              {type: "field", ip: ($private + ["::/0"]), outboundTag: "block"}
            ]
          }
        }' >"${dest}" || die "生成 Xray 配置失败：${dest}"
}

xray_config_structure_ok() {
    local file=$1 expected_blocked=${2:-} has_reality=0
    xray_protocol_has_reality && has_reality=1
    jq -e --arg blocked "${expected_blocked}" --arg has_reality "${has_reality}" '
        def vless_client: .settings.clients[0].id | type == "string" and length > 0;
        . as $config
        | ($config.log | type == "object" and (.loglevel | type == "string"))
        and ($config.dns | type == "object"
             and (.servers | type == "array" and length > 0)
             and .queryStrategy == "UseIPv4")
        and ($config.inbounds | type == "array")
        # 模式 5 恒有 Reality 入站；模式 1 的阻断态允许空入站数组（仅停 CDN 入站）。
        and (($config.inbounds | length) > 0
             or ($has_reality == "0" and $blocked == "1"))
        and (if $has_reality == "1" then
                 any($config.inbounds[];
                     .tag == "vless-reality-in"
                     and .listen == "0.0.0.0" and .port == 443 and .protocol == "vless"
                     and (. | vless_client)
                     and .settings.clients[0].flow == "xtls-rprx-vision"
                     and .settings.decryption == "none"
                     and .streamSettings.network == "raw"
                     and .streamSettings.security == "reality"
                     and .streamSettings.realitySettings.target == "127.0.0.1:9443"
                     and .streamSettings.realitySettings.xver == 0
                     and .streamSettings.realitySettings.maxTimeDiff == 120000
                     and (.streamSettings.realitySettings.serverNames | length) > 0
                     and (.streamSettings.realitySettings.shortIds | length) > 0
                     and (.streamSettings.realitySettings.privateKey | length) > 0)
             else
                 (any($config.inbounds[]; .tag == "vless-reality-in") | not)
             end)
        and (if $has_reality == "1" then
                 (if $blocked == "0" then any($config.inbounds[]; .tag == "vless-cdn-in")
                  elif $blocked == "1" then (any($config.inbounds[]; .tag == "vless-cdn-in") | not)
                  else true end)
             else
                 (if $blocked == "1" then (any($config.inbounds[]; .tag == "vless-cdn-in") | not)
                  else any($config.inbounds[]; .tag == "vless-cdn-in") end)
             end)
        and (all($config.inbounds[] | select(.tag == "vless-cdn-in");
                 .listen == "127.0.0.1" and .port == 10086 and .protocol == "vless"
                 and (. | vless_client)
                 and .settings.decryption == "none"
                 and .streamSettings.network == "xhttp"
                 and (.streamSettings.xhttpSettings.path | type == "string" and length > 0)
                 and (.streamSettings.xhttpSettings.host | type == "string" and length > 0)
                 and .streamSettings.xhttpSettings.mode == "auto"
                 and .streamSettings.xhttpSettings.extra.xPaddingBytes == "100-1000"
                 and .streamSettings.xhttpSettings.extra.scStreamUpServerSecs == "20-80"
                 # 严格 schema：两个字段只能在 extra 里，出现在 xhttpSettings 顶层即拒绝。
                 and (.streamSettings.xhttpSettings | has("xPaddingBytes") | not)
                 and (.streamSettings.xhttpSettings | has("scStreamUpServerSecs") | not)))
        and (any($config.outbounds[]; .tag == "direct" and .protocol == "freedom"
                                      and .settings.domainStrategy == "UseIPv4"))
        and (any($config.outbounds[]; .tag == "block" and .protocol == "blackhole"))
        and ($config.routing | type == "object" and .domainStrategy == "IPIfNonMatch")
        and (any($config.routing.rules[];
                 .type == "field" and .outboundTag == "block"
                 and (.ip | type == "array" and length > 0)
                 and (.ip | index("::/0")) != null
                 and (.ip | index("127.0.0.0/8")) != null))
    ' "${file}" >/dev/null 2>&1
}

# 有候选核心时用真实 `xray run -test -config`；否则只做 jq 结构断言。
# 传入第 2 参数 blocked（0/1）时额外校验就绪态存在/阻断态省略 vless-cdn-in。
validate_xray_config() {
    local file=$1 expected_blocked=${2:-}
    [[ -s "${file}" ]] || { fail "Xray 配置不存在或为空"; return 1; }
    if [[ -x "${XRAY_BIN:-}" ]]; then
        "${XRAY_BIN}" run -test -config "${file}" >/dev/null \
            || { fail "xray run -test 未通过"; return 1; }
        if [[ "${expected_blocked}" == "0" ]]; then
            jq -e 'any(.inbounds[]?; .tag == "vless-cdn-in")' "${file}" >/dev/null 2>&1 \
                || { fail "就绪态 Xray 配置缺少 vless-cdn-in 入站"; return 1; }
        elif [[ "${expected_blocked}" == "1" ]]; then
            ! jq -e 'any(.inbounds[]?; .tag == "vless-cdn-in")' "${file}" >/dev/null 2>&1 \
                || { fail "阻断态 Xray 配置不应包含 vless-cdn-in 入站"; return 1; }
        fi
        return 0
    fi
    xray_config_structure_ok "${file}" "${expected_blocked}" \
        || { fail "Xray 配置结构校验失败"; return 1; }
}

write_xray_config() {
    local blocked=${1:-0} candidate stage target_dir
    [[ -n "${RUNTIME_TMP:-}" ]] || die "运行时临时目录未初始化，无法写入 Xray 配置"
    candidate="${RUNTIME_TMP}/xray-config.next.json"
    render_xray_config "${candidate}" "${blocked}"
    validate_xray_config "${candidate}" "${blocked}" \
        || die "候选 Xray 配置校验失败（候选文件随本次运行结束删除）"
    target_dir=$(dirname "${XRAY_CONFIG}")
    install -d -m 0700 "${target_dir}" \
        || die "创建 Xray 配置目录失败：${target_dir}"
    stage=$(mktemp "${XRAY_CONFIG}.XXXXXX") \
        || die "创建 Xray 配置暂存文件失败：${target_dir}"
    if ! { install -m 0600 "${candidate}" "${stage}" \
        && mv -f -- "${stage}" "${XRAY_CONFIG}"; }; then
        rm -f -- "${stage}"
        die "发布 Xray 配置失败：${XRAY_CONFIG}"
    fi
}

# --- Reality 密钥对（design §2.2） --------------------------------------------

# 解析 `xray x25519` 输出。私有钥取 PrivateKey:；公钥按
# `Password (PublicKey):` → `Password:` → `PublicKey:` 的优先级取第一条命中。
# 真实 Xray（v25.8.31+）固定输出 `PrivateKey:`、
# `Password (PublicKey):` 与 `Hash32:` 三行：`Hash32:` 既不是公私钥也不是公钥候选，
# 必须显式跳过，绝不得误作公钥；若只有 `PrivateKey:` 与 `Hash32:` 而没有任何公钥行，
# 下面的行尾形态检查会因公钥为空而返回失败。
xray_parse_reality_keypair() {
    local output=${1:-} line private="" password_public="" password="" public_key=""
    local pattern='^[A-Za-z0-9_-]{42,44}=?$'
    [[ -n "${output}" ]] || return 1
    while IFS= read -r line; do
        if [[ "${line}" =~ ^Hash32:[[:space:]]* ]]; then
            continue
        fi
        if [[ -z "${private}" && "${line}" =~ ^PrivateKey:[[:space:]]*(.*)$ ]]; then
            private=${BASH_REMATCH[1]}
            continue
        fi
        if [[ -z "${password_public}" \
            && "${line}" =~ ^Password[[:space:]]*\(PublicKey\):[[:space:]]*(.*)$ ]]; then
            password_public=${BASH_REMATCH[1]}
            continue
        fi
        if [[ -z "${password}" && "${line}" =~ ^Password:[[:space:]]*(.*)$ ]]; then
            password=${BASH_REMATCH[1]}
            continue
        fi
        if [[ -z "${public_key}" && "${line}" =~ ^PublicKey:[[:space:]]*(.*)$ ]]; then
            public_key=${BASH_REMATCH[1]}
        fi
    done <<<"${output}"
    [[ -n "${password_public}" ]] || password_public=${password}
    [[ -n "${password_public}" ]] || password_public=${public_key}
    [[ "${private}" =~ ${pattern} && "${password_public}" =~ ${pattern} ]] || return 1
    REALITY_PRIVATE_KEY=${private}
    REALITY_PUBLIC_KEY=${password_public}
    return 0
}

# 密钥对必须在输入阶段之后、任何证书/配置写入之前生成并落盘：
# 续装与后续进程都复用同一对密钥，不会产生孤儿订阅。
xray_generate_reality_keypair() {
    [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]] || return 0
    local output
    [[ -x "${XRAY_BIN:-}" ]] \
        || die "缺少可执行的 xray（${XRAY_BIN:-未设置}）；无法生成 Reality 密钥对"
    output=$("${XRAY_BIN}" x25519 2>/dev/null) \
        || die "xray x25519 失败；已停止安装（未写入任何配置）"
    xray_parse_reality_keypair "${output}" \
        || die "xray x25519 输出缺少可识别的 PrivateKey/PublicKey；已停止安装"
    install -d -m 0700 "$(install_state_dir_path)" \
        || die "无法创建状态目录；已停止安装（避免续装更换密钥）"
    persist_install_identity \
        || die "无法落盘 Reality 密钥对；已停止安装（避免续装更换密钥）"
}

# --- 客户端节点（design §2.2） ------------------------------------------------

# 版本三元组比较：current >= required 时返回 0。缺失段按 0 处理（26.9 == 26.9.0）。
xray_version_at_least() {
    local current=${1:-} required=${2:-} c1 c2 c3 r1 r2 r3
    [[ -n "${current}" && -n "${required}" ]] || return 1
    IFS=. read -r c1 c2 c3 <<<"${current}"
    IFS=. read -r r1 r2 r3 <<<"${required}"
    c1=${c1:-0} c2=${c2:-0} c3=${c3:-0}
    r1=${r1:-0} r2=${r2:-0} r3=${r3:-0}
    [[ "${c1}" =~ ^[0-9]+$ && "${c2}" =~ ^[0-9]+$ && "${c3}" =~ ^[0-9]+$ ]] || return 1
    [[ "${r1}" =~ ^[0-9]+$ && "${r2}" =~ ^[0-9]+$ && "${r3}" =~ ^[0-9]+$ ]] || return 1
    ((c1 != r1)) && { ((c1 > r1)); return; }
    ((c2 != r2)) && { ((c2 > r2)); return; }
    ((c3 >= r3))
}

# Xray >= 26.9.8 默认启用 X25519MLKEM768，客户端必须同步声明，否则 Reality 握手失败。
# 优先读已安装核心的真实版本；核心尚未安装/离线渲染时默认按最新正式版（>= 26.9.8）处理。
xray_mlkem_required() {
    local version=""
    version=$(xray_binary_version "${XRAY_BIN:-}" 2>/dev/null || true)
    [[ -z "${version}" ]] && return 0
    xray_version_at_least "${version}" "26.9.8"
}

build_xray_reality_link() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 Reality 节点链接"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 Reality 节点链接"
    [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || die "缺少 REALITY_PUBLIC_KEY，无法生成 Reality 节点链接"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 Reality 节点链接"
    local mlkem=""
    xray_mlkem_required || mlkem="&mlkem=0"
    # 节点名可含空格/表情/分隔符，必须 URI 编码后才能出现在 # 片段。
    printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&packetEncoding=xudp%s#%s' \
        "${VLESS_UUID}" "${DIRECT_DOMAIN}" "${DIRECT_DOMAIN}" \
        "${REALITY_PUBLIC_KEY}" "${REALITY_SHORT_ID}" "${mlkem}" \
        "$(xray_uri_encode "${DIRECT_NODE_NAME}")"
}

build_mihomo_xray_reality_node() {
    [[ -n "${DIRECT_DOMAIN:-}" ]] || die "缺少 DIRECT_DOMAIN，无法生成 Reality 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 Reality 节点"
    [[ -n "${REALITY_PUBLIC_KEY:-}" ]] || die "缺少 REALITY_PUBLIC_KEY，无法生成 Reality 节点"
    [[ -n "${REALITY_SHORT_ID:-}" ]] || die "缺少 REALITY_SHORT_ID，无法生成 Reality 节点"
    local pq=""
    if xray_mlkem_required; then
        pq="true"
    fi
    jq -nr --arg name "${DIRECT_NODE_NAME}" --arg server "${DIRECT_DOMAIN}" \
        --arg uuid "${VLESS_UUID}" --arg pbk "${REALITY_PUBLIC_KEY}" \
        --arg sid "${REALITY_SHORT_ID}" --arg pq "${pq}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: tcp\n    tls: true\n    udp: true\n" +
        "    flow: xtls-rprx-vision\n    servername: \($server|@json)\n" +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n    ip-version: ipv4\n" +
        "    reality-opts:\n      public-key: \($pbk|@json)\n      short-id: \($sid|@json)\n" +
        (if $pq == "true" then "      support-x25519mlkem768: true\n" else "" end)'
}

# 客户端 xmux 与上行参数：与 render_xray_config 的 xhttpSettings.extra 配对。
xray_xhttp_extra_json() {
    jq -cn '{
        uplinkHTTPMethod: "POST",
        noGRPCHeader: false,
        xmux: {
          maxConnections: 8,
          cMaxReuseTimes: 0,
          hMaxRequestTimes: "300-600",
          hMaxReusableSecs: "600-1200",
          hKeepAlivePeriod: 30
        }
    }'
}

# 连接地址可用 cdnEdgeAddress 换成优选域名；SNI 与 XHTTP host 仍是 CF_NODE_DOMAIN。
build_xray_xhttp_link() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 XHTTP 节点链接"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 XHTTP 节点链接"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 XHTTP 节点链接"
    local server=${CF_EDGE_ADDRESS:-${CF_NODE_DOMAIN}} host encoded_host encoded_extra
    host=${CF_NODE_DOMAIN}
    encoded_host=$(xray_uri_encode "${host}")
    encoded_extra=$(xray_uri_encode "$(xray_xhttp_extra_json)")
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up&extra=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${encoded_host}" "${encoded_host}" \
        "$(xray_uri_encode "${VLESS_PATH}")" "${encoded_extra}" \
        "$(xray_uri_encode "${CF_NODE_PREFIX}")"
}

build_mihomo_xray_xhttp_node() {
    [[ -n "${CF_NODE_DOMAIN:-}" ]] || die "缺少 CF_NODE_DOMAIN，无法生成 XHTTP 节点"
    [[ -n "${VLESS_UUID:-}" ]] || die "缺少 VLESS_UUID，无法生成 XHTTP 节点"
    [[ -n "${VLESS_PATH:-}" ]] || die "缺少 VLESS_PATH，无法生成 XHTTP 节点"
    jq -nr --arg name "${CF_NODE_PREFIX}" --arg server "${CF_EDGE_ADDRESS:-${CF_NODE_DOMAIN}}" \
        --arg host "${CF_NODE_DOMAIN}" --arg uuid "${VLESS_UUID}" --arg path "${VLESS_PATH}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n" +
        "    client-fingerprint: chrome\n    packet-encoding: xudp\n    ip-version: ipv4\n" +
        "    alpn:\n      - h2\n" +
        "    xhttp-opts:\n      host: \($host|@json)\n      path: \($path|@json)\n" +
        "      mode: stream-up\n      no-grpc-header: false\n" +
        "      uplink-http-method: POST\n      reuse-settings:\n" +
        "        max-connections: 8\n        c-max-reuse-times: 0\n" +
        "        h-max-request-times: \"300-600\"\n        h-max-reusable-secs: \"600-1200\"\n" +
        "        h-keep-alive-period: 30\n"'
}
