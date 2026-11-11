#!/usr/bin/env bash
# sing-box 完整 JSON 订阅：八产物渲染、节点与策略组映射、排除提示、候选校验。
# 用户视角：只通过模式渲染入口与产物断言；真实核心存在时（CI 设置 SINGBOX_BIN）额外跑核心校验。
set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/easy-all-singbox-sub.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}
assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}
assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing <${expected}>"
}
assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected <${unexpected}>"
}
assert_file_mode() {
    local label=$1 expected=$2 file=$3 actual
    actual=$(ls -ld -- "${file}" | awk '{print $1}' | sed 's/[^drwx-]//g')
    [[ "${actual}" == "${expected}" ]] \
        || fail "${label}: expected mode ${expected} but got ${actual}"
}

for syntax_file in lib/singbox-subscription.sh lib/singbox-runtime.sh \
    lib/runtime-core.sh lib/caddy-runtime.sh; do
    bash -n "${ROOT_DIR}/${syntax_file}" || fail "语法校验失败：${syntax_file}"
done

ANYTLS_PASSWORD="sub-qegsmmsz-6348516949"
VLESS_UUID="11111111-2222-4111-8111-111111111111"
VLESS_PATH="/vless-abcdef123456"
REALITY_UUID="22222222-3333-4444-8555-666666666666"
REALITY_PBK="q1w2e3r4t5y6u7i8o9p0asdfghjklzxcvbnm1234567"
ORIGIN_SECRET="origin-secret-do-not-leak"
# 聚合节点：1 个可用 Reality，其余分别为关闭 MLKEM 的 Reality、xhttp 与 mieru。
AGGREGATION_NODES_FIXTURE=$(jq -cn --arg uuid "${REALITY_UUID}" --arg pbk "${REALITY_PBK}" '[
    {type: "vless", name: "R-可用", host: "reality.example.com", port: 8443,
     security: "reality", network: "tcp", uuid: $uuid, sni: "reality.example.com",
     pbk: $pbk, sid: "ab12cd34", fp: "chrome", supportX25519Mlkem768: true,
     udp: true, optional: true},
    {type: "vless", name: "R-仅TCP", host: "tcp-only.example.com", port: 443,
     security: "reality", network: "tcp", uuid: $uuid, sni: "tcp-only.example.com",
     pbk: $pbk, sid: "ab12cd34", fp: "chrome", supportX25519Mlkem768: true,
     udp: false, optional: false},
    # Reality 路径会过滤 X25519MLKEM768，这个节点验证 supportX25519Mlkem768=false 不被排除。
    {type: "vless", name: "R-无MLKEM", host: "old-reality.example.com", port: 443,
     security: "reality", network: "tcp", uuid: $uuid, sni: "old-reality.example.com",
     pbk: $pbk, sid: "ab12cd34", fp: "chrome", supportX25519Mlkem768: false,
     udp: true, optional: false},
    {type: "vless", name: "X-xhttp", host: "xhttp.example.com", port: 443,
     security: "tls", network: "xhttp", uuid: $uuid, sni: "xhttp.example.com",
     path: "/xhttp", mode: "stream-up", fp: "chrome",
     xhttpUplinkHttpMethod: "POST", xhttpNoGrpcHeader: false, udp: true, optional: false},
    {type: "mieru", name: "M-mieru", host: "mieru.example.com", port: 8964,
     username: "easyall", password: "mieru-pass-1234", transport: "TCP",
     multiplexing: "MULTIPLEXING_LOW", mtu: 1400, udp: true, optional: false},
    {type: "vless", name: "R-怪指纹", host: "odd.example.com", port: 443,
     security: "reality", network: "tcp", uuid: $uuid, sni: "odd.example.com",
     pbk: $pbk, sid: "ab12cd34", fp: "chromium", supportX25519Mlkem768: true,
     udp: true, optional: false}
]')

# 订阅配置校验/派生：Profile 常量是 readonly，每次在独立 bash 里加载。
normalize_config() { # $1=订阅配置 JSON -> stdout 规范化结果（stderr 原样透出）
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/combined.sh"
        normalize_subscription_config "$2" "[]"
    ' _ "${ROOT_DIR}" "$1"
}
derive_edge_address() { # $1=订阅配置 JSON -> stdout CF_EDGE_ADDRESS
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/combined.sh"
        apply_local_aggregation_config "$2" "[]" || exit 1
        printf "%s" "${CF_EDGE_ADDRESS}"
    ' _ "${ROOT_DIR}" "$1"
}
reject_config() { # $1=订阅配置 JSON -> stdout 为错误输出；非法时返回非零
    normalize_config "$1" 2>&1
}

# 每个模式都在独立 bash 里渲染：Profile 常量是 readonly，不能在同一进程内切换。
render_mode() { # $1=profile $2=输出目录（$3=可选的 cdnEdgeAddress）
    local profile=$1 out=$2 edge=${3:-}
    mkdir -p "${out}/runtime" "${out}/subs"
    (
        export RUNTIME_TMP="${out}/runtime"
        export EASY_ALL_STATE_DIR_OVERRIDE="${out}/state"
        export EASY_ALL_CERT_DIR_OVERRIDE="${out}/certs"
        export SINGBOX_CONFIG="${out}/config.json"
        export CADDY_CONFIG="${out}/Caddyfile"
        export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out}/subs"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/${profile}.sh"
        CF_ZONE=example.com
        VPS_PUBLIC_IPV4=203.0.113.10
        SUB_DOWNLOAD_NAME=EASY_ALL
        ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
        SUB_DOWNLOAD_NAME=EASY_ALL
        CLOUDFLARE_ZONE_ID=zoneid
        SUBSCRIPTION_MODE=deploy
        if state_protocol_has_direct_entry "${PROTOCOL}"; then
            DIRECT_DOMAIN=direct.example.com
            DIRECT_NODE_NAME="🇺🇸直连"
            ANYTLS_PASSWORD=${ANYTLS_PASSWORD}
        fi
        if state_protocol_has_cdn_entry "${PROTOCOL}"; then
            CF_NODE_DOMAIN=cf.example.com
            CF_NODE_PREFIX="🇺🇸CF"
            VLESS_UUID=${VLESS_UUID}
            VLESS_PATH=${VLESS_PATH}
        fi
        if state_protocol_uses_cloudfront "${PROTOCOL}"; then
            CF_ORIGIN_DOMAIN=origin.example.com
            SUBSCRIPTION_DOMAIN=cf.example.com
            ORIGIN_HEADER_SECRET=${ORIGIN_SECRET}
            CDN_TRAFFIC_PROTECTION_GB=985
            AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
            AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
            AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
        fi
        if [[ "${PROTOCOL}" == "anytls" ]]; then
            SUBSCRIPTION_DOMAIN=sub.example.com
            CLOUDFLARE_ORIGIN_RULESET_ID=rs
            CLOUDFLARE_ORIGIN_RULE_ID=rule
        elif [[ "${PROTOCOL}" == "combined-cloudflare" ]]; then
            CLOUDFLARE_ORIGIN_RULESET_ID=rs
            CLOUDFLARE_ORIGIN_RULE_ID=rule
        fi
        cdn_derive_runtime_fields || exit 1
        local names
        names=$(cdn_local_node_names)
        SUBSCRIPTION_CONFIG=$(jq -cn --argjson tokens "${ALLOWED_TOKENS}" \
            --argjson nodes "${AGGREGATION_NODES_FIXTURE}" --arg edge "${edge}" \
            '{allowedTokens: $tokens, nodes: $nodes}
             + (if $edge != "" then {cdnEdgeAddress: $edge} else {} end)')
        apply_local_aggregation_config "${SUBSCRIPTION_CONFIG}" "${names}" || exit 1
        render_subscription_files "${out}/subs"
    )
}

# --- 模式 4：八产物与策略组 ---------------------------------------------------
out="${TMP_DIR}/combined"
render_log="${TMP_DIR}/combined.log"
render_mode combined "${out}" >"${render_log}" 2>&1 || {
    cat "${render_log}" >&2
    fail "模式 4 订阅渲染失败"
}
default_json="${out}/subs/singbox.json"
all_json="${out}/subs/singbox-all.json"

for artifact in base64.txt mihomo.yaml mihomo-ios.yaml singbox.json \
    base64-all.txt mihomo-all.yaml mihomo-ios-all.yaml singbox-all.json; do
    [[ -s "${out}/subs/${artifact}" ]] || fail "缺少订阅产物：${artifact}"
done
assert_file_mode "sing-box 订阅权限" "-rw-------" "${default_json}"
assert_file_mode "sing-box all 订阅权限" "-rw-------" "${all_json}"
jq -e . "${default_json}" >/dev/null || fail "singbox.json 不是有效 JSON"

tags() { jq -c '[.outbounds[].tag]' "$1"; }
assert_equal "outbounds 顺序" \
    '["PROXY","AUTO","DIRECT","🇺🇸直连","🇺🇸CF","R-可用","R-仅TCP","R-无MLKEM"]' "$(tags "${all_json}")"
assert_equal "默认订阅不含 optional 聚合节点" \
    '["PROXY","AUTO","DIRECT","🇺🇸直连","🇺🇸CF","R-仅TCP","R-无MLKEM"]' "$(tags "${default_json}")"
assert_equal "PROXY 成员顺序（直连、CDN、AUTO、聚合）" \
    '["🇺🇸直连","🇺🇸CF","AUTO","R-可用","R-仅TCP","R-无MLKEM"]' \
    "$(jq -c '.outbounds[] | select(.tag == "PROXY") | .outbounds' "${all_json}")"
assert_equal "PROXY 默认选择直连节点" '"🇺🇸直连"' \
    "$(jq -c '.outbounds[] | select(.tag == "PROXY") | .default' "${all_json}")"
assert_equal "AUTO 只包含本机直连与 CDN" '["🇺🇸直连","🇺🇸CF"]' \
    "$(jq -c '.outbounds[] | select(.tag == "AUTO") | .outbounds' "${all_json}")"
assert_equal "AUTO 探测地址与间隔" "https://www.gstatic.com/generate_204 300s 50" \
    "$(jq -r '.outbounds[] | select(.tag == "AUTO") | "\(.url) \(.interval) \(.tolerance)"' "${all_json}")"
assert_not_contains "不生成虚假 CDN-FALLBACK" "$(tags "${all_json}")" "CDN-FALLBACK"
assert_equal "route 默认出口" '"PROXY"' "$(jq -c '.route.final' "${default_json}")"

# 本机节点参数
assert_equal "AnyTLS 节点字段" \
    "anytls direct.example.com 443 ${ANYTLS_PASSWORD} direct.example.com false chrome" \
    "$(jq -r '.outbounds[] | select(.tag == "🇺🇸直连") |
        "\(.type) \(.server) \(.server_port) \(.password) \(.tls.server_name) \(.tls.insecure // false) \(.tls.utls.fingerprint)"' "${default_json}")"
assert_equal "VLESS WS 节点字段" \
    "vless cf.example.com 443 ${VLESS_UUID} ws ${VLESS_PATH} cf.example.com xudp" \
    "$(jq -r '.outbounds[] | select(.tag == "🇺🇸CF") |
        "\(.type) \(.server) \(.server_port) \(.uuid) \(.transport.type) \(.transport.path) \(.transport.headers.Host) \(.packet_encoding)"' "${default_json}")"
assert_equal "Reality 节点字段" \
    "vless reality.example.com 8443 ${REALITY_UUID} xtls-rprx-vision reality.example.com ${REALITY_PBK} ab12cd34 chrome xudp" \
    "$(jq -r '.outbounds[] | select(.tag == "R-可用") |
        "\(.type) \(.server) \(.server_port) \(.uuid) \(.flow) \(.tls.server_name) \(.tls.reality.public_key) \(.tls.reality.short_id) \(.tls.utls.fingerprint) \(.packet_encoding)"' "${all_json}")"

# udp=false 的节点必须限制承载：sing-box 侧用 network="tcp" 表达，且不得再带 xudp 编码。
assert_equal "udp=false 节点只承载 TCP" 'tcp null' \
    "$(jq -r '.outbounds[] | select(.tag == "R-仅TCP") | "\(.network) \(.packet_encoding // "null")"' "${default_json}")"

# 不支持的节点只排除出 JSON，并给出名称与原因。
assert_contains "排除提示包含 xhttp 节点" "$(<"${render_log}")" "X-xhttp（xhttp 传输）"
assert_contains "排除提示包含 mieru 节点" "$(<"${render_log}")" "M-mieru（mieru 协议）"
assert_contains "排除提示包含不受支持的客户端指纹" "$(<"${render_log}")" \
    "R-怪指纹（客户端指纹不受支持）"
assert_contains "排除提示给出数量" "$(<"${render_log}")" "sing-box 订阅排除 3 个聚合节点"
assert_not_contains "JSON 不含 xhttp 节点" "$(tags "${all_json}")" "X-xhttp"
assert_not_contains "JSON 不含 mieru 节点" "$(tags "${all_json}")" "M-mieru"
# Reality 客户端强制走经典 X25519（过滤 MLKEM），所以该字段不影响可用性，节点必须保留。
assert_contains "关闭 MLKEM 的 Reality 节点仍在 JSON 里" "$(tags "${all_json}")" "R-无MLKEM"
assert_equal "Reality 节点不写曲线偏好" '[]' \
    "$(jq -c '[.outbounds[] | select(.tag == "R-无MLKEM") | .tls.curve_preferences // empty]' "${default_json}")"
assert_not_contains "JSON 不含指纹不受支持的节点" "$(tags "${all_json}")" "R-怪指纹"
assert_not_contains "JSON 不含源站密钥" "$(<"${all_json}")" "${ORIGIN_SECRET}"

# DNS 与分流规则必须随订阅下发
assert_equal "route.rule_set 数量" "16" \
    "$(jq -r '.route.rule_set | length' "${default_json}")"
assert_equal "dns final" '"dns-proxy"' "$(jq -c '.dns.final' "${default_json}")"
# sing-box 1.14 拒绝把 DNS 的 detour 指向空 direct 出口（启动即 FATAL）：直连只能用默认出口表达。
assert_equal "只有境外 DoH 带 detour" '["dns-proxy"]' \
    "$(jq -c '[.dns.servers[] | select(.detour != null) | .tag]' "${default_json}")"
assert_equal "境外 DoH detour 指向 PROXY" '"PROXY"' \
    "$(jq -c '.dns.servers[] | select(.tag == "dns-proxy") | .detour' "${default_json}")"
assert_equal "规则集 HTTP 客户端不带空 direct detour" '[{"tag":"ruleset-direct"}]' \
    "$(jq -c '.http_clients' "${default_json}")"
assert_equal "dns 策略 ipv4_only" '"ipv4_only"' "$(jq -c '.dns.strategy' "${default_json}")"
assert_equal "TUN 与 mixed 入口" '["mixed-in","tun-in"]' \
    "$(jq -c '[.inbounds[].tag]' "${default_json}")"
# DIRECT 直连必须用本地解析：route.default_domain_resolver 是节点引导解析器，
# sing-box 的传输级解析不经过 dns.rules，用引导解析器查局域网域名只会得到 NXDOMAIN。
assert_equal "DIRECT 出口使用本地解析" '"dns-local"' \
    "$(jq -c '.outbounds[] | select(.tag == "DIRECT") | .domain_resolver' "${default_json}")"
assert_equal "节点出口沿用引导解析器" '"dns-bootstrap"' \
    "$(jq -c '.route.default_domain_resolver' "${default_json}")"
# DNS 规则顺序（对齐 Mihomo nameserver-policy）：私有/本地 → 代理集合 → Fake-IP 例外 → 国内集合 → Fake-IP。
# 代理集合必须早于国内集合与 Fake-IP 例外：services.googleapis.cn 命中 .cn，mtalk.google.com 命中 Fake-IP 例外，
# 两者都属于代理集合、必须用代理 DNS 解析（禁 Fake-IP 不等于改用国内 DNS）。
assert_equal "DNS 规则 tag 顺序" \
    'private-fallback ^[^.]+$ captive-portal proxy-services fakeip-exceptions wechat-services steam-download apple-cn-fallback direct-services A' \
    "$(jq -r '[.dns.rules[] | (if .rule_set then .rule_set[0] elif .domain_regex then .domain_regex[0] else .query_type[0] end)] | join(" ")' "${default_json}")"
assert_contains "geosite-private 进入直连规则" \
    '["private-fallback","geosite-private"]' \
    "$(jq -c '[.route.rules[] | select(.rule_set != null and .outbound == "DIRECT") | .rule_set][0]' "${default_json}")"
assert_equal "TUN 地址、MTU、栈与自动路由" "172.19.0.1/30 1500 system true hijack" \
    "$(jq -r '.inbounds[] | select(.tag == "tun-in") | "\(.address[0]) \(.mtu) \(.stack) \(.auto_route) \(.dns_mode)"' "${default_json}")"
assert_equal "Fake-IP 网段不与 TUN 地址重叠" '"198.18.0.0/16"' \
    "$(jq -c '.dns.servers[] | select(.type == "fakeip") | .inet4_range' "${default_json}")"
assert_equal "规则集下载走显式 HTTP 客户端" '"ruleset-direct"' \
    "$(jq -c '.route.default_http_client' "${default_json}")"

# --- 模式 1/2/3/5：没有 AUTO 组，PROXY 默认选首个本机节点 ----------------------
# 模式 2/3 没有直连入口，成员里不得出现直连节点；模式 1/5 的首成员是直连节点。
# 只有模式 4 生成 AUTO（已在上面的主用例断言成员与探测参数）。
while IFS='|' read -r profile expected_default has_direct; do
    mode_out="${TMP_DIR}/${profile}"
    render_mode "${profile}" "${mode_out}" >"${mode_out}.log" 2>&1 || {
        cat "${mode_out}.log" >&2
        fail "${profile} 订阅渲染失败"
    }
    mode_json="${mode_out}/subs/singbox.json"
    assert_not_contains "${profile} 不生成 AUTO" "$(tags "${mode_json}")" "AUTO"
    assert_equal "${profile} PROXY 默认选择首个本机节点" "\"${expected_default}\"" \
        "$(jq -c '.outbounds[] | select(.tag == "PROXY") | .default' "${mode_json}")"
    if [[ "${has_direct}" == "no" ]]; then
        assert_equal "${profile} PROXY 成员不含直连节点" "false" \
            "$(jq -r '.outbounds[] | select(.tag == "PROXY") | .outbounds | index("🇺🇸直连") != null' "${mode_json}")"
        assert_equal "${profile} outbounds 不含直连节点" "false" \
            "$(jq -r '([.outbounds[].tag] | index("🇺🇸直连")) != null' "${mode_json}")"
    else
        assert_equal "${profile} PROXY 首成员是直连节点" '"🇺🇸直连"' \
            "$(jq -c '.outbounds[] | select(.tag == "PROXY") | .outbounds[0]' "${mode_json}")"
    fi
    assert_not_contains "${profile} 默认订阅不含 optional 节点" "$(tags "${mode_json}")" "R-可用"
    assert_contains "${profile} all 订阅包含 optional 节点" "$(tags "${mode_out}/subs/singbox-all.json")" "R-可用"
done <<'PROFILES'
anytls|🇺🇸直连|yes
cloudfront|🇺🇸CF|no
cloudflare|🇺🇸CF|no
combined-cloudflare|🇺🇸直连|yes
PROFILES

# --- 候选校验拒绝错误配置 -----------------------------------------------------
validate_with_lib() {
    local file=$1
    bash -c '
        set -Eeuo pipefail
        source "$1/lib/log.sh"
        source "$1/lib/singbox-subscription.sh"
        SCRIPT_DIR="$1/lib"
        validate_singbox_subscription_config "$2"
    ' _ "${ROOT_DIR}" "${file}" 2>/dev/null
}

validate_with_lib "${default_json}" || fail "合法订阅必须通过候选校验"
jq '.route.final = "MISSING"' "${default_json}" >"${TMP_DIR}/bad-final.json"
validate_with_lib "${TMP_DIR}/bad-final.json" && fail "默认出口缺失必须校验失败"
jq '.outbounds[0].outbounds += ["NOT-EXIST"]' "${default_json}" >"${TMP_DIR}/bad-member.json"
validate_with_lib "${TMP_DIR}/bad-member.json" && fail "策略组成员缺失必须校验失败"
jq '.outbounds += [.outbounds[1]]' "${default_json}" >"${TMP_DIR}/dup-tag.json"
validate_with_lib "${TMP_DIR}/dup-tag.json" && fail "重复 outbound tag 必须校验失败"
jq 'del(.outbounds[] | select(.tag == "DIRECT"))' "${default_json}" >"${TMP_DIR}/no-direct.json"
validate_with_lib "${TMP_DIR}/no-direct.json" && fail "规则引用的出口缺失必须校验失败"
jq '.dns.rules[0].server = "missing-dns"' "${default_json}" >"${TMP_DIR}/bad-dns.json"
validate_with_lib "${TMP_DIR}/bad-dns.json" && fail "DNS 服务器引用缺失必须校验失败"
# dns.rules 引用了 route.rule_set 里不存在的 tag：结构校验就要拦下，不依赖真实核心。
jq '.route.rule_set |= map(if .tag == "fakeip-exceptions" then .tag = "renamed-rs" else . end)' \
    "${default_json}" >"${TMP_DIR}/bad-dns-ruleset.json"
validate_with_lib "${TMP_DIR}/bad-dns-ruleset.json" && fail "dns.rules 引用缺失必须校验失败"
# selector 默认出口、默认域名解析器与默认 HTTP 客户端都必须是已定义的引用。
jq '.outbounds[0].default = "NOT-EXIST"' "${default_json}" >"${TMP_DIR}/bad-selector-default.json"
validate_with_lib "${TMP_DIR}/bad-selector-default.json" && fail "selector 默认出口缺失必须校验失败"
jq '.route.default_domain_resolver = "missing-resolver"' "${default_json}" \
    >"${TMP_DIR}/bad-default-resolver.json"
validate_with_lib "${TMP_DIR}/bad-default-resolver.json" && fail "默认域名解析器缺失必须校验失败"
jq '.route.default_http_client = "missing-client"' "${default_json}" \
    >"${TMP_DIR}/bad-default-client.json"
validate_with_lib "${TMP_DIR}/bad-default-client.json" && fail "默认 HTTP 客户端缺失必须校验失败"

# 本机节点生成失败时整份候选发布失败，不留下 JSON。
out_missing="${TMP_DIR}/no-password"
mkdir -p "${out_missing}/subs"
if (
    export RUNTIME_TMP="${out_missing}/runtime"
    export EASY_ALL_CERT_DIR_OVERRIDE="${out_missing}/certs"
    export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${out_missing}/subs"
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/profiles/anytls.sh"
    CF_ZONE=example.com
    SUB_DOWNLOAD_NAME=EASY_ALL
    ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
    SUBSCRIPTION_MODE=deploy
    DIRECT_DOMAIN=direct.example.com
    DIRECT_NODE_NAME="🇺🇸直连"
    ANYTLS_PASSWORD=""
    AGGREGATION_NODES='[]'
    mkdir -p "${RUNTIME_TMP}" "${CERT_DIR}"
    render_subscription_files "${out_missing}/subs"
) >/dev/null 2>&1; then
    fail "缺少 AnyTLS 密码时渲染必须失败"
fi
[[ ! -e "${out_missing}/subs/singbox.json" ]] || fail "渲染失败不得留下 sing-box 订阅"

# --- cdnEdgeAddress：订阅配置顶层可选字段（design §3.1/§4.3、§11 第 4-7 项）------
cfg_base='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
assert_equal "无字段输出逐字节不变" "${cfg_base}" "$(normalize_config "${cfg_base}")"
assert_equal "合法优选地址保留并小写化" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k2v8nq4zt6.cloudfront.182682.xyz"}' \
    "$(normalize_config '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"K2V8NQ4ZT6.CloudFront.182682.XYZ"}')"
assert_equal "null 字段等价于缺失" "${cfg_base}" \
    "$(normalize_config '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":null}')"

# 每类非法值都必须被拒绝，且具体原因（cdnEdgeAddress）必须能从 stderr 看到。
while IFS= read -r edge_bad; do
    edge_err=$(reject_config "{\"allowedTokens\":{\"owner\":\"token-abcdefgh\"},\"nodes\":[],\"cdnEdgeAddress\":${edge_bad}}") \
        && fail "非法 cdnEdgeAddress 必须被拒绝：${edge_bad}"
    assert_contains "拒绝 ${edge_bad} 时报错含 cdnEdgeAddress" "${edge_err}" "cdnEdgeAddress"
done <<'EDGE_BAD'
"*"
"https://a.com"
"a.com:443"
"a.com/x"
""
"203.0.113.1"
"localhost"
"a..b"
EDGE_BAD
edge_label63=$(printf 'a%.0s' {1..63})
edge_label62=$(printf 'b%.0s' {1..62})
edge_too_long="${edge_label63}.${edge_label63}.${edge_label63}.${edge_label62}"
assert_equal "超长用例恰为 254 字符" "254" "${#edge_too_long}"
edge_err=$(reject_config "{\"allowedTokens\":{\"owner\":\"token-abcdefgh\"},\"nodes\":[],\"cdnEdgeAddress\":\"${edge_too_long}\"}") \
    && fail "超过 253 字符的 cdnEdgeAddress 必须被拒绝"
assert_contains "超长值报错含 cdnEdgeAddress" "${edge_err}" "cdnEdgeAddress"

edge_err=$(reject_config '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"foo":1}') \
    && fail "多余顶层键必须被拒绝"
assert_contains "多余顶层键报错点明 cdnEdgeAddress 是合法键" "${edge_err}" "cdnEdgeAddress"
assert_not_contains "顶层键白名单文案不再写两个键" "${edge_err}" "两个键"

assert_equal "派生 CF_EDGE_ADDRESS 为小写值" "k2v8nq4zt6.cloudfront.182682.xyz" \
    "$(derive_edge_address '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"K2V8NQ4ZT6.CloudFront.182682.XYZ"}')"
assert_equal "无字段时 CF_EDGE_ADDRESS 为空" "" "$(derive_edge_address "${cfg_base}")"

# 端到端：三种产物的连接地址换成优选域名，SNI / Host 仍是节点域名。
edge_out="${TMP_DIR}/combined-edge"
render_mode combined "${edge_out}" "k2v8nq4zt6.cloudfront.182682.xyz" >"${edge_out}.log" 2>&1 || {
    cat "${edge_out}.log" >&2
    fail "带 cdnEdgeAddress 的模式 4 订阅渲染失败"
}
for edge_artifact in singbox.json singbox-all.json; do
    assert_equal "优选地址替换 ${edge_artifact} 本机 CDN 节点" \
        "k2v8nq4zt6.cloudfront.182682.xyz cf.example.com cf.example.com" \
        "$(jq -r '.outbounds[] | select(.tag == "🇺🇸CF") |
            "\(.server) \(.tls.server_name) \(.transport.headers.Host)"' \
            "${edge_out}/subs/${edge_artifact}")"
done
for edge_artifact in mihomo.yaml mihomo-all.yaml; do
    assert_contains "优选地址替换 ${edge_artifact} 连接地址" \
        "$(<"${edge_out}/subs/${edge_artifact}")" 'server: "k2v8nq4zt6.cloudfront.182682.xyz"'
    assert_contains "优选地址不改 ${edge_artifact} servername" \
        "$(<"${edge_out}/subs/${edge_artifact}")" 'servername: "cf.example.com"'
done

# --- 非法 cdnEdgeAddress 不替换已发布订阅（验收条件 4：行为断言）-----------------
cp -R "${out}/subs" "${TMP_DIR}/published-before"
edge_apply_err=$(
    RUNTIME_TMP="${TMP_DIR}/reject-runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/reject-state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${TMP_DIR}/reject-certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${TMP_DIR}/reject-subs" \
        bash -c '
            set -Eeuo pipefail
            source "$1/profiles/combined.sh"
            cdn_apply_subscription_config "$2"
        ' _ "${ROOT_DIR}" \
        '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"a.com:443"}' 2>&1
) && fail "非法 cdnEdgeAddress 必须被 cdn_apply_subscription_config 拒绝"
assert_contains "拒绝时 stderr 含 cdnEdgeAddress" "${edge_apply_err}" "cdnEdgeAddress"
diff -r "${TMP_DIR}/published-before" "${out}/subs" >/dev/null \
    || fail "非法配置不得改动已发布订阅产物"

printf 'ok - sing-box 订阅测试通过（%s）\n' \
    "$([[ -x "${SINGBOX_BIN:-}" ]] && printf '含真实核心校验' || printf '仅结构校验')"
