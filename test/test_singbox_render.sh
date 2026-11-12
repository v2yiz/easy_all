#!/usr/bin/env bash
# 阶段 1 基础库：sing-box 固定版本/摘要、五模式配置渲染、运行校验与安装。
# 用户视角：只通过公开接口与产物断言；外部边界（curl/tar 之外的下载、候选核心）用替身。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_singbox_test.XXXXXX")
fi
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
    [[ "${text}" == *"${expected}"* ]] \
        || fail "${label}: missing <${expected}> in <${text}>"
}
assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected <${unexpected}> in <${text}>"
}
assert_file_mode() {
    local label=$1 expected=$2 file=$3 actual
    # macOS 的 ls 会在权限位后追加扩展属性标记 @/+，只比较权限字符。
    actual=$(ls -ld -- "${file}" | awk '{print $1}' | sed 's/[^drwx-]//g')
    [[ "${actual}" == "${expected}" ]] \
        || fail "${label}: expected mode ${expected} but got ${actual}"
}

SINGBOX_CORE="${ROOT_DIR}/lib/singbox-core.sh"
SINGBOX_RUNTIME="${ROOT_DIR}/lib/singbox-runtime.sh"
for syntax_file in "${SINGBOX_CORE}" "${SINGBOX_RUNTIME}" \
    "${ROOT_DIR}/lib/caddy-core.sh" "${ROOT_DIR}/lib/caddy-runtime.sh" \
    "${ROOT_DIR}/lib/cf-origin-rule.sh"; do
    bash -n "${syntax_file}" || fail "语法校验失败：${syntax_file}"
done

# --- 隔离环境 ---------------------------------------------------------------
export RUNTIME_TMP="${TMP_DIR}/runtime"
mkdir -p "${RUNTIME_TMP}"
export SINGBOX_BIN="${TMP_DIR}/singbox/sing-box"
export SINGBOX_CONFIG="${TMP_DIR}/singbox/config.json"
export SINGBOX_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-singbox.service"
export CERT_DIR="${TMP_DIR}/certs"
export CERT_FILE="${CERT_DIR}/fullchain.pem"
export KEY_FILE="${CERT_DIR}/private.key"
mkdir -p "${SINGBOX_BIN%/*}" "${CERT_DIR}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/log.sh"
# 同时校验加载守卫：core 被 runtime 二次 source 不得因 readonly 常量失败。
# shellcheck source=/dev/null
source "${SINGBOX_CORE}"
# shellcheck source=/dev/null
source "${SINGBOX_RUNTIME}"

ANYTLS_PASSWORD="test-password-1234567890"
VLESS_UUID="11111111-2222-4111-8111-111111111111"
VLESS_PATH="/vless-abcdef123456"
DIRECT_DOMAIN="direct.example.com"
CF_NODE_DOMAIN="cf.example.com"
DIRECT_NODE_NAME="AnyTLS"
CF_NODE_PREFIX="CDN-WS"

# 设计/计划冻结的固定常量：期望值来自 design.md §6 与 plan.md，不由实现推导。
assert_equal "sing-box 锁定版本" "1.14.4" "${SINGBOX_VERSION}"
assert_equal "sing-box 版本接口" "1.14.4" "$(singbox_version)"
assert_equal "sing-box amd64 SHA256" \
    "699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968" \
    "$(singbox_expected_sha256 amd64)"
assert_equal "sing-box arm64 SHA256" \
    "436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26" \
    "$(singbox_expected_sha256 arm64)"
assert_equal "amd64 映射" "amd64" "$(singbox_arch x86_64)"
assert_equal "aarch64 映射" "arm64" "$(singbox_arch aarch64)"
assert_equal "arm64 映射" "arm64" "$(singbox_arch arm64)"
assert_equal "amd64 归档 URL" \
    "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-amd64.tar.gz" \
    "$(singbox_archive_url amd64)"
assert_equal "arm64 归档 URL" \
    "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-arm64.tar.gz" \
    "$(singbox_archive_url arm64)"
if (singbox_arch riscv64) >/dev/null 2>&1; then
    fail "未知架构必须失败"
fi

# --- 五模式渲染 -------------------------------------------------------------
render() { # $1=protocol $2=blocked -> stdout
    local out="${TMP_DIR}/render-${1}-${2}.json"
    rm -f -- "${out}"
    ( PROTOCOL=$1; render_singbox_config "${out}" "$2" ) \
        || fail "渲染失败：${1} blocked=$2"
    cat "${out}"
}

anytls_json=$(render anytls 0)
assert_equal "模式 1 只有 AnyTLS 入站" "anytls-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"${anytls_json}")"
assert_equal "AnyTLS 入站监听 0.0.0.0:443" "0.0.0.0 443" \
    "$(jq -r '.inbounds[0] | "\(.listen) \(.listen_port)"' <<<"${anytls_json}")"
assert_equal "AnyTLS 用户密码" "${ANYTLS_PASSWORD}" \
    "$(jq -r '.inbounds[0].users[0].password' <<<"${anytls_json}")"
assert_equal "AnyTLS TLS 使用直连域名与证书" \
    "direct.example.com ${CERT_FILE} ${KEY_FILE}" \
    "$(jq -r '.inbounds[0].tls | "\(.server_name) \(.certificate_path) \(.key_path)"' <<<"${anytls_json}")"
assert_equal "AnyTLS 入站不启用 CDN 传输" "null" \
    "$(jq -c '.inbounds[0].transport' <<<"${anytls_json}")"

cloudfront_json=$(render cloudfront 0)
assert_equal "模式 4 只有 VLESS 入站" "vless-cdn-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"${cloudfront_json}")"
assert_equal "VLESS 入站监听回环 10086" "127.0.0.1 10086" \
    "$(jq -r '.inbounds[0] | "\(.listen) \(.listen_port)"' <<<"${cloudfront_json}")"
assert_equal "VLESS 使用 ws 与精确路径" "ws ${VLESS_PATH}" \
    "$(jq -r '.inbounds[0].transport | "\(.type) \(.path)"' <<<"${cloudfront_json}")"
assert_equal "VLESS 用户 UUID" "${VLESS_UUID}" \
    "$(jq -r '.inbounds[0].users[0].uuid' <<<"${cloudfront_json}")"
assert_equal "回环 CDN 入站不启用 TLS" "null" \
    "$(jq -c '.inbounds[0].tls' <<<"${cloudfront_json}")"

cloudflare_json=$(render cloudflare 0)
assert_equal "模式 2 与模式 4 的本机入站一致" "${cloudfront_json}" "${cloudflare_json}"

combined_json=$(render combined-cloudfront 0)
assert_equal "模式 5 同时有 AnyTLS 与 VLESS" "anytls-in,vless-cdn-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"${combined_json}")"

combined_cf_json=$(render combined-cloudflare 0)
assert_equal "模式 3 同时有 AnyTLS 与 VLESS" "anytls-in,vless-cdn-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"${combined_cf_json}")"
assert_equal "模式 3 AnyTLS 监听 443" "443" \
    "$(jq -r '.inbounds[] | select(.tag == "anytls-in") | .listen_port' <<<"${combined_cf_json}")"
assert_equal "模式 3 回环 CDN 入站 10086" "127.0.0.1 10086" \
    "$(jq -r '.inbounds[] | select(.tag == "vless-cdn-in") | "\(.listen) \(.listen_port)"' <<<"${combined_cf_json}")"

# blocked 只省略 CDN 入站；模式 5 保留 AnyTLS。
for proto in cloudfront cloudflare; do
    blocked_json=$(render "${proto}" 1)
    assert_equal "${proto} blocked 省略 CDN 入站" "[]" \
        "$(jq -c '.inbounds' <<<"${blocked_json}")"
done
assert_equal "模式 1 blocked 仍保留 AnyTLS" "anytls-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"$(render anytls 1)")"
assert_equal "模式 5 blocked 只保留 AnyTLS" "anytls-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"$(render combined-cloudfront 1)")"
assert_equal "模式 3 blocked 只保留 AnyTLS" "anytls-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <<<"$(render combined-cloudflare 1)")"

# 公共结构：log/dns/outbounds/route 按 design §7。
for proto in anytls cloudfront cloudflare combined-cloudfront combined-cloudflare; do
    body=$(render "${proto}" 0)
    assert_equal "${proto}: log 级别 warning" "warning" "$(jq -r '.log.level' <<<"${body}")"
    assert_equal "${proto}: DNS 显式 IPv4-only" "ipv4_only" "$(jq -r '.dns.strategy' <<<"${body}")"
    assert_equal "${proto}: DNS 服务器全部是 IPv4" "0" \
        "$(jq -r '[.dns.servers[].server | select(test(":"))] | length' <<<"${body}")"
    assert_equal "${proto}: 默认域名解析器指向已声明服务器" "true" \
        "$(jq -r '.route.default_domain_resolver as $tag
            | any(.dns.servers[]; .tag == $tag)' <<<"${body}")"
    assert_equal "${proto}: 固定 IPv4 direct 出站" "direct" \
        "$(jq -r '.outbounds[0].tag' <<<"${body}")"
    assert_equal "${proto}: 默认出站 direct" "direct" "$(jq -r '.route.final' <<<"${body}")"
    assert_equal "${proto}: 首条规则先解析目标域名" '{"action":"resolve"}' \
        "$(jq -c '.route.rules[0]' <<<"${body}")"
    # 域名目标不解析就匹配不上 ip_is_private/ip_cidr：私网与元数据拦截会整体失效。
    assert_equal "${proto}: resolve 排在私网拒绝之前" "true" \
        "$(jq -r '(.route.rules | map(.action // "") | index("resolve")) < (.route.rules | map(.ip_is_private // false) | index(true))' <<<"${body}")"
    assert_equal "${proto}: 第二条规则拒绝私网" '{"ip_is_private":true,"action":"reject"}' \
        "$(jq -c '.route.rules[1]' <<<"${body}")"
    # 与 lib/network.sh 的 IPv4 私网/特殊地址清单逐项一致（design §7）。
    assert_equal "${proto}: 拒绝私网/特殊 CIDR" \
        '["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15","224.0.0.0/4","240.0.0.0/4"]' \
        "$(jq -c '.route.rules[2].ip_cidr' <<<"${body}")"
    assert_equal "${proto}: 拒绝 UDP/443" '{"network":"udp","port":443,"action":"reject"}' \
        "$(jq -c '.route.rules[3]' <<<"${body}")"
    assert_not_contains "${proto}: 不启用 v2ray_api" "${body}" "v2ray_api"
    assert_not_contains "${proto}: 不配置 experimental" "${body}" "experimental"
done

if (PROTOCOL=unknown-mode; render_singbox_config "${TMP_DIR}/x.json" 0) >/dev/null 2>&1; then
    fail "未知 PROTOCOL 必须失败"
fi
if (PROTOCOL=anytls; render_singbox_config "${TMP_DIR}/x.json" 2) >/dev/null 2>&1; then
    fail "非法 blocked 取值必须失败"
fi
if (PROTOCOL=anytls; DIRECT_DOMAIN=""; render_singbox_config "${TMP_DIR}/x.json" 0) >/dev/null 2>&1; then
    fail "缺少 DIRECT_DOMAIN 必须失败"
fi
if (PROTOCOL=cloudfront; VLESS_PATH=""; render_singbox_config "${TMP_DIR}/x.json" 0) >/dev/null 2>&1; then
    fail "缺少 VLESS_PATH 必须失败"
fi

# --- 客户端节点（design §12） -----------------------------------------------
DIRECT_NODE_NAME="AnyTLS"
CF_NODE_PREFIX="CDN-WS"
assert_equal "AnyTLS 链接格式" \
    "anytls://${ANYTLS_PASSWORD}@direct.example.com:443/?sni=direct.example.com&insecure=0#AnyTLS" \
    "$(build_anytls_link)"
assert_equal "AnyTLS 链接按组件编码" \
    "anytls://${ANYTLS_PASSWORD}@direct.example.com:443/?sni=direct.example.com&insecure=0#AnyTLS%20%E7%9B%B4%E8%BF%9E" \
    "$(DIRECT_NODE_NAME="AnyTLS 直连"; build_anytls_link)"
assert_equal "VLESS ws 链接格式" \
    "vless://${VLESS_UUID}@cf.example.com:443?encryption=none&security=tls&type=ws&sni=cf.example.com&fp=chrome&host=cf.example.com&path=%2Fvless-abcdef123456&packetEncoding=xudp#CDN-WS" \
    "$(build_vless_ws_link)"
vless_link=$(build_vless_ws_link)
assert_not_contains "VLESS 链接无 Reality flow" "${vless_link}" "flow="
assert_not_contains "VLESS 链接无 XHTTP 参数" "${vless_link}" "type=xhttp"
assert_not_contains "VLESS 链接无 alpn" "${vless_link}" "alpn="
assert_not_contains "VLESS 链接无源站密钥" "${vless_link}" "X-Easy-All-Origin-Key"

anytls_node=$(build_mihomo_anytls_node)
assert_contains "AnyTLS 节点名称" "${anytls_node}" 'name: "AnyTLS"'
assert_contains "AnyTLS 节点类型" "${anytls_node}" "type: anytls"
assert_contains "AnyTLS 节点服务器" "${anytls_node}" 'server: "direct.example.com"'
assert_contains "AnyTLS 节点端口 443" "${anytls_node}" "port: 443"
assert_contains "AnyTLS 节点密码" "${anytls_node}" 'password: "'"${ANYTLS_PASSWORD}"'"'
assert_contains "AnyTLS 节点 SNI" "${anytls_node}" 'sni: "direct.example.com"'
assert_contains "AnyTLS 客户端指纹" "${anytls_node}" "client-fingerprint: chrome"
assert_contains "AnyTLS 启用 UDP" "${anytls_node}" "udp: true"
assert_contains "AnyTLS 校验证书" "${anytls_node}" "skip-cert-verify: false"

ws_node=$(build_mihomo_ws_node)
assert_contains "VLESS 节点名称" "${ws_node}" 'name: "CDN-WS"'
assert_contains "VLESS 节点类型" "${ws_node}" "type: vless"
assert_contains "VLESS 节点服务器" "${ws_node}" 'server: "cf.example.com"'
assert_contains "VLESS 节点端口 443" "${ws_node}" "port: 443"
assert_contains "VLESS 节点 UUID" "${ws_node}" 'uuid: "'"${VLESS_UUID}"'"'
assert_contains "VLESS 节点 ws 传输" "${ws_node}" "network: ws"
assert_contains "VLESS 节点 TLS" "${ws_node}" "tls: true"
assert_contains "VLESS 节点 SNI" "${ws_node}" 'servername: "cf.example.com"'
assert_contains "VLESS 节点 ws 路径" "${ws_node}" 'path: "/vless-abcdef123456"'
assert_contains "VLESS 节点 ws Host" "${ws_node}" 'Host: "cf.example.com"'
assert_contains "VLESS 客户端指纹" "${ws_node}" "client-fingerprint: chrome"
assert_contains "VLESS xudp 编码" "${ws_node}" "packet-encoding: xudp"
assert_not_contains "VLESS 节点无源站密钥" "${ws_node}" "X-Easy-All-Origin-Key"
assert_not_contains "VLESS 节点无 httpupgrade" "${ws_node}" "httpupgrade"

if (PROTOCOL=cloudfront; CF_NODE_DOMAIN=""; build_vless_ws_link) >/dev/null 2>&1; then
    fail "缺少 CF_NODE_DOMAIN 必须失败"
fi
if (PROTOCOL=anytls; DIRECT_DOMAIN=""; build_anytls_link) >/dev/null 2>&1; then
    fail "缺少 DIRECT_DOMAIN 必须失败"
fi

# --- CDN 优选连接地址：只换连接地址，SNI 与 Host 仍是节点域名 -----------------
# 期望值来自 design §2 条 3 / §4.5：连接地址是 CF_EDGE_ADDRESS，SNI、servername、
# WebSocket Host 保持 CF_NODE_DOMAIN（证书校验、回源 Host 均按节点域名）。
assert_equal "优选地址只替换 VLESS 链接的连接地址" \
    "vless://${VLESS_UUID}@edge.example-cdn.com:443?encryption=none&security=tls&type=ws&sni=cf.example.com&fp=chrome&host=cf.example.com&path=%2Fvless-abcdef123456&packetEncoding=xudp#CDN-WS" \
    "$(CF_EDGE_ADDRESS="edge.example-cdn.com" build_vless_ws_link)"
edge_node=$(CF_EDGE_ADDRESS="edge.example-cdn.com" build_mihomo_ws_node)
assert_contains "优选地址替换 Mihomo server" "${edge_node}" 'server: "edge.example-cdn.com"'
assert_contains "优选地址不改 Mihomo servername" "${edge_node}" 'servername: "cf.example.com"'
assert_contains "优选地址不改 Mihomo ws Host" "${edge_node}" 'Host: "cf.example.com"'
assert_equal "优选地址只替换 sing-box server" \
    "edge.example-cdn.com cf.example.com cf.example.com" \
    "$(CF_EDGE_ADDRESS="edge.example-cdn.com" build_singbox_ws_outbound \
        | jq -r '"\(.server) \(.tls.server_name) \(.transport.headers.Host)"')"
# 空值与未设置都必须回落到节点域名：无字段的既有部署产物逐字节不变（验收条件 5）。
assert_equal "空优选地址不改变 VLESS 链接" "$(build_vless_ws_link)" \
    "$(CF_EDGE_ADDRESS="" build_vless_ws_link)"
assert_equal "空优选地址不改变 Mihomo 节点" "$(build_mihomo_ws_node)" \
    "$(CF_EDGE_ADDRESS="" build_mihomo_ws_node)"
assert_equal "空优选地址不改变 sing-box 节点" "$(build_singbox_ws_outbound)" \
    "$(CF_EDGE_ADDRESS="" build_singbox_ws_outbound)"

# --- 写入与校验 -------------------------------------------------------------
PROTOCOL=combined-cloudfront
write_singbox_config 0
assert_file_mode "配置权限 0600" "-rw-------" "${SINGBOX_CONFIG}"
assert_equal "写入后入站完整" "anytls-in,vless-cdn-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <"${SINGBOX_CONFIG}")"
write_singbox_config 1
assert_equal "写入 blocked 后省略 CDN 入站" "anytls-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' <"${SINGBOX_CONFIG}")"
assert_equal "写入目录权限 0700" "drwx------" \
    "$(ls -ld -- "${SINGBOX_CONFIG%/*}" | awk '{print $1}' | sed 's/[^drwx-]//g')"
[[ -z "$(find "${SINGBOX_CONFIG%/*}" -name 'config.json.*' -print -quit)" ]] \
    || fail "写入不得留下暂存文件"

PROTOCOL=anytls
write_singbox_config 0
validate_singbox_config "${SINGBOX_CONFIG}" \
    || fail "结构校验应接受生成的配置"

broken="${TMP_DIR}/broken.json"
jq '.route.rules = []' <"${SINGBOX_CONFIG}" >"${broken}"
if (validate_singbox_config "${broken}") >/dev/null 2>&1; then
    fail "缺少 route.rules 必须校验失败"
fi
if (validate_singbox_config "${TMP_DIR}/missing.json") >/dev/null 2>&1; then
    fail "缺少配置文件必须校验失败"
fi

# 候选校验失败的公开输出不得点名 RUNTIME_TMP 下即将删除的候选文件：
# 用户按提示去查看时文件已不存在，应依赖 validator 当场输出。
candidate="${RUNTIME_TMP}/singbox-config.next.json"
rm -f -- "${candidate}"
missing_candidate_output=$( (validate_singbox_config "${candidate}") 2>&1 ) \
    && fail "缺少候选配置必须校验失败"
assert_contains "缺少候选配置给出原因" "${missing_candidate_output}" "不存在或为空"
assert_not_contains "缺少候选配置不点名候选路径" \
    "${missing_candidate_output}" "singbox-config.next.json"
: >"${candidate}"
empty_candidate_output=$( (validate_singbox_config "${candidate}") 2>&1 ) \
    && fail "空候选配置必须校验失败"
assert_contains "空候选配置给出原因" "${empty_candidate_output}" "不存在或为空"
assert_not_contains "空候选配置不点名候选路径" \
    "${empty_candidate_output}" "singbox-config.next.json"
jq '.route.rules = []' <"${SINGBOX_CONFIG}" >"${candidate}"
structure_candidate_output=$( (validate_singbox_config "${candidate}") 2>&1 ) \
    && fail "结构损坏的候选必须校验失败"
assert_contains "结构损坏的候选给出原因" "${structure_candidate_output}" "结构校验失败"
assert_not_contains "结构损坏的候选不点名候选路径" \
    "${structure_candidate_output}" "singbox-config.next.json"
rm -f -- "${candidate}"

CHECK_LOG="${TMP_DIR}/singbox-check.log"
cat >"${SINGBOX_BIN}" <<'FAKE_SINGBOX'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SINGBOX_CHECK_LOG}"
case "${1:-}" in
check) exit "${FAKE_SINGBOX_CHECK_STATUS:-0}" ;;
version) printf 'sing-box version 1.14.4\n' ;;
esac
FAKE_SINGBOX
chmod +x "${SINGBOX_BIN}"
export FAKE_SINGBOX_CHECK_LOG="${CHECK_LOG}"
: >"${CHECK_LOG}"
validate_singbox_config "${SINGBOX_CONFIG}" || fail "候选核心通过时校验应成功"
assert_equal "调用真实核心 check" "check -c ${SINGBOX_CONFIG}" "$(<"${CHECK_LOG}")"
if (export FAKE_SINGBOX_CHECK_STATUS=1; validate_singbox_config "${SINGBOX_CONFIG}") >/dev/null 2>&1; then
    fail "候选核心驳回时必须失败"
fi

# 发布前必须过真实核心校验：驳回时写入失败且已发布配置字节不变。
published_bytes() {
    openssl dgst -sha256 "$1" | awk '{print $NF}'
}
PROTOCOL=anytls
printf '{"published":"previous"}
' >"${SINGBOX_CONFIG}"
previous_sha=$(published_bytes "${SINGBOX_CONFIG}")
: >"${CHECK_LOG}"
reject_output=$( (export FAKE_SINGBOX_CHECK_STATUS=1; write_singbox_config 0) 2>&1 ) \
    && fail "真实核心驳回时写入必须失败"
assert_contains "核心驳回时给出候选校验失败" "${reject_output}" \
    "候选 sing-box 配置校验失败"
assert_not_contains "核心驳回输出不点名候选路径" "${reject_output}" \
    "singbox-config.next.json"
assert_equal "驳回时已发布配置字节不变" "${previous_sha}" "$(published_bytes "${SINGBOX_CONFIG}")"
assert_equal "驳回时确实调用了核心 check" "1" "$(grep -c . "${CHECK_LOG}" || true)"
[[ -z "$(find "${SINGBOX_CONFIG%/*}" -name 'config.json.*')" ]] \
    || fail "驳回时不得留下暂存文件"

# 通过时调用恰好一次，且被检查的候选就是最终发布的配置。
: >"${CHECK_LOG}"
write_singbox_config 0 || fail "真实核心通过时写入应成功"
assert_equal "通过时只调用一次核心 check" "1" "$(grep -c . "${CHECK_LOG}" || true)"
checked_config=$(sed 's/^check -c //' "${CHECK_LOG}")
[[ -f "${checked_config}" ]] || fail "check 应指向实际候选文件：${checked_config}"
assert_equal "被检查的候选就是发布的配置" "$(<"${SINGBOX_CONFIG}")" "$(<"${checked_config}")"
assert_equal "已安装版本来自核心自报" "1.14.4" "$(singbox_installed_version)"
rm -f -- "${SINGBOX_BIN}"
assert_equal "缺少核心时版本未知" "unknown" "$(singbox_installed_version)"

# --- 下载校验 ---------------------------------------------------------------
# 下载按本机架构选择归档；测试在同一架构下构造归档，期望值直接来自 design 的归档命名规则。
case "$(uname -m)" in
x86_64 | amd64) TEST_ARCH=amd64 ;;
aarch64 | arm64) TEST_ARCH=arm64 ;;
*) fail "测试机器架构不在锁定范围内：$(uname -m)" ;;
esac
archive_root="${TMP_DIR}/archive"
mkdir -p "${archive_root}/sing-box-1.14.4-linux-${TEST_ARCH}"
make_archive() { # $1=版本文案 -> stdout 归档路径
    local version=$1 dir="${archive_root}/sing-box-1.14.4-linux-${TEST_ARCH}"
    cat >"${dir}/sing-box" <<FAKE_RELEASE
#!/usr/bin/env bash
if [[ "\${1:-}" == "version" ]]; then
    printf 'sing-box version ${version}\n'
    exit 0
fi
exit 0
FAKE_RELEASE
    chmod +x "${dir}/sing-box"
    tar -czf "${TMP_DIR}/sing-box-1.14.4-linux-${TEST_ARCH}.tar.gz" \
        -C "${archive_root}" "sing-box-1.14.4-linux-${TEST_ARCH}" \
        || fail "无法构造测试归档"
    printf '%s\n' "${TMP_DIR}/sing-box-1.14.4-linux-${TEST_ARCH}.tar.gz"
}
archive=$(make_archive 1.14.4)
archive_sha=$(openssl dgst -sha256 "${archive}" | awk '{print $NF}')
CURL_LOG="${TMP_DIR}/curl.log"

# 下载流程：curl 只负责把本地归档放到 -o 目标并记录请求的 URL；tar 使用真实实现。
run_download() { # $1=归档 $2=期望摘要 #3=是否覆盖摘要（1=覆盖为 $2）
    local archive_path=$1 sha=$2 override=$3 status=0
    (
        : >"${CURL_LOG}"
        curl() {
            local arg out="" expect_out=0 url=""
            for arg in "$@"; do
                if ((expect_out == 1)); then
                    out=${arg}
                    expect_out=0
                    continue
                fi
                if [[ "${arg}" == "-o" ]]; then
                    expect_out=1
                    continue
                fi
                case "${arg}" in
                https://*) url=${arg} ;;
                esac
            done
            printf '%s\n' "${url}" >>"${CURL_LOG}"
            [[ -n "${out}" ]] || return 1
            cp "${archive_path}" "${out}" || return 1
        }
        if [[ "${override}" == "1" ]]; then
            singbox_expected_sha256() { printf '%s\n' "${sha}"; }
        fi
        download_singbox
    ) >/dev/null 2>&1 || status=$?
    printf '%s' "${status}"
}

printf 'old-binary\n' >"${SINGBOX_BIN}"
chmod 0755 "${SINGBOX_BIN}"
assert_equal "摘要一致时安装成功" "0" "$(run_download "${archive}" "${archive_sha}" 1)"
assert_equal "安装后核心可执行" "1.14.4" "$(singbox_installed_version)"
[[ -x "${SINGBOX_BIN}" ]] || fail "下载后二进制必须可执行"
assert_file_mode "二进制权限 0755" "-rwxr-xr-x" "${SINGBOX_BIN}"
assert_equal "请求锁定版本的官方归档" \
    "https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box-1.14.4-linux-${TEST_ARCH}.tar.gz" \
    "$(<"${CURL_LOG}")"

printf 'old-binary\n' >"${SINGBOX_BIN}"
chmod 0755 "${SINGBOX_BIN}"
[[ "$(run_download "${archive}" "${archive_sha}" 0)" != "0" ]] \
    || fail "摘要不符必须拒绝安装"
assert_equal "摘要不符保留旧二进制" "old-binary" "$(<"${SINGBOX_BIN}")"

wrong_version=$(make_archive 1.14.5)
wrong_sha=$(openssl dgst -sha256 "${wrong_version}" | awk '{print $NF}')
[[ "$(run_download "${wrong_version}" "${wrong_sha}" 1)" != "0" ]] \
    || fail "候选版本自检失败必须拒绝安装"
assert_equal "版本自检失败保留旧二进制" "old-binary" "$(<"${SINGBOX_BIN}")"

# 生产路径必须比对代码内固定常量：期望值固定为真实发布摘要，假归档不得通过。
[[ "$(run_download "${archive}" "" 0)" != "0" ]] || fail "固定摘要不匹配必须失败"

# --- 服务单元 ---------------------------------------------------------------
SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"
systemctl() {
    printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
    return 0
}
: >"${SYSTEMCTL_LOG}"
install_singbox_service "easy_all-counter-prepare"
unit=$(<"${SINGBOX_SERVICE_FILE}")
assert_file_mode "单元权限 0644" "-rw-r--r--" "${SINGBOX_SERVICE_FILE}"
assert_contains "单元以 root 运行" "${unit}" "User=root"
assert_contains "单元前台运行" "${unit}" "Type=simple"
assert_contains "单元包含 ExecStartPre" "${unit}" "ExecStartPre=easy_all-counter-prepare"
assert_contains "单元启动核心" "${unit}" "ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}"
assert_contains "失败重启" "${unit}" "Restart=on-failure"
assert_contains "重启间隔 10s" "${unit}" "RestartSec=10s"
assert_contains "启动限流窗口" "${unit}" "StartLimitIntervalSec=120"
assert_contains "启动限流次数" "${unit}" "StartLimitBurst=3"
assert_contains "启动超时 30s" "${unit}" "TimeoutStartSec=30s"
assert_equal "安装单元不触发 systemctl" "" "$(<"${SYSTEMCTL_LOG}")"

install_singbox_service ""
assert_not_contains "ExecStartPre 可空" "$(<"${SINGBOX_SERVICE_FILE}")" "ExecStartPre="

# --- package.json 接线 -------------------------------------------------------
assert_contains "npm test 串入 sing-box 渲染测试" \
    "$(<"${ROOT_DIR}/package.json")" "test/test_singbox_render.sh"

printf 'ok - sing-box 基础库测试通过\n'
