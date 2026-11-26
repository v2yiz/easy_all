#!/usr/bin/env bash
# 模式 1（cloudflare，纯 XHTTP）与模式 5（reality-cloudflare-xhttp）核心与渲染
# （design v2 §2.1 / §2.2）：锁定版本与摘要链、Xray 服务端配置结构、密钥对解析三形态、
# 客户端节点与私网阻断清单。外部边界（下载、二进制）用替身；断言只针对可观察产物与失败路径。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_xray_test.XXXXXX")
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
expect_fail() {
    local label=$1
    shift
    if ("$@") >/dev/null 2>&1; then
        fail "${label}: 必须失败"
    fi
}

XRAY_CORE="${ROOT_DIR}/lib/xray-core.sh"
XRAY_RUNTIME="${ROOT_DIR}/lib/xray-runtime.sh"
bash -n "${XRAY_CORE}" || fail "语法校验失败：${XRAY_CORE}"
bash -n "${XRAY_RUNTIME}" || fail "语法校验失败：${XRAY_RUNTIME}"

# 隔离环境：运行路径不得写系统目录。
export RUNTIME_TMP="${TMP_DIR}/runtime"
export XRAY_BIN="${TMP_DIR}/xray/xray"
export XRAY_CONFIG="${TMP_DIR}/xray/config.json"
export XRAY_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-xray.service"
mkdir -p "${RUNTIME_TMP}" "${XRAY_BIN%/*}"

# shellcheck source=lib/log.sh
source "${ROOT_DIR}/lib/log.sh"
# shellcheck source=lib/xray-core.sh
source "${XRAY_CORE}"
# shellcheck source=lib/xray-runtime.sh
source "${XRAY_RUNTIME}"

# --- 最新 Release 契约（不锁定版本与固定 SHA256） ----------------------------
[[ -z "${XRAY_VERSION:-}" ]] || fail "Xray 不应再定义锁定版本常量 XRAY_VERSION"
! declare -F xray_expected_sha256 >/dev/null 2>&1 || fail "Xray 不应再定义固定摘要函数 xray_expected_sha256"
assert_equal "amd64 映射" "amd64" "$(xray_arch x86_64)"
assert_equal "aarch64 映射" "arm64" "$(xray_arch aarch64)"
assert_equal "amd64 归档名" "Xray-linux-64.zip" "$(xray_archive_name amd64)"
assert_equal "arm64 归档名" "Xray-linux-arm64-v8a.zip" "$(xray_archive_name arm64)"
assert_equal "amd64 归档 URL" \
    "https://github.com/XTLS/Xray-core/releases/download/v26.12.1/Xray-linux-64.zip" \
    "$(xray_archive_url amd64 26.12.1)"
assert_equal "amd64 清单 URL" \
    "https://github.com/XTLS/Xray-core/releases/download/v26.12.1/Xray-linux-64.zip.dgst" \
    "$(xray_digest_url amd64 26.12.1)"
expect_fail "归档 URL 缺版本号必须失败" xray_archive_url amd64
expect_fail "清单 URL 缺版本号必须失败" xray_digest_url amd64
expect_fail "未知架构" xray_arch mips

# 最新版本标签解析：仅接受 /releases/tag/vX.Y(.Z)，拒绝预发布与异常跳转。
assert_equal "解析最新正式版标签" "26.12.1" "$(
    curl() { printf 'https://github.com/XTLS/Xray-core/releases/tag/v26.12.1\n'; }
    xray_latest_version
)"
assert_equal "解析最新标签自动去尾斜杠与查询串" "27.1" "$(
    curl() { printf 'https://github.com/XTLS/Xray-core/releases/tag/v27.1/?foo=bar\n'; }
    xray_latest_version
)"
expect_fail "预发布标签必须被拒绝" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"
    curl() { printf "https://github.com/XTLS/Xray-core/releases/tag/v26.12.1-rc1\n"; }
    xray_latest_version' _ "${ROOT_DIR}"
expect_fail "未跳转到 tag 页面必须被拒绝" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"
    curl() { printf "https://github.com/XTLS/Xray-core/releases\n"; }
    xray_latest_version' _ "${ROOT_DIR}"
expect_fail "查询最新版本失败必须中止" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"
    curl() { return 1; }
    xray_latest_version' _ "${ROOT_DIR}"

# 版本比较：MLKEM 门槛 26.9.8。
xray_version_at_least 26.11.9 26.9.8 || fail "26.11.9 应 >= 26.9.8"
xray_version_at_least 26.9.8 26.9.8 || fail "26.9.8 应 >= 26.9.8"
xray_version_at_least 26.9.7 26.9.8 && fail "26.9.7 必须 < 26.9.8"
xray_version_at_least 27.0.0 26.9.8 || fail "27.0.0 应 >= 26.9.8"
xray_version_at_least 26.10 26.9.8 || fail "缺失段按 0 处理（26.10 == 26.10.0）"
xray_version_at_least abc 26.9.8 && fail "非数字版本必须判为不满足"

# --- 私网阻断清单：与 sing-box 单一来源完全一致（模式 5 独立定义，不互相调用） ------
xray_ranges=$(xray_private_ranges_json)
singbox_ranges=$(
    bash -c 'set -Eeuo pipefail; source "$1/lib/singbox-runtime.sh"; singbox_private_ranges_json' \
        _ "${ROOT_DIR}"
) || fail "无法读取 sing-box 私网清单"
assert_equal "私网清单与 singbox_private_ranges_json 完全一致" "${singbox_ranges}" "${xray_ranges}"
assert_equal "私网清单恰为 11 条 IPv4 CIDR" "11" \
    "$(jq 'length' <<<"${xray_ranges}")"
assert_equal "私网清单不含 ::/0（由路由规则追加）" "0" \
    "$(jq '[.[] | select(. == "::/0")] | length' <<<"${xray_ranges}")"
assert_equal "私网清单不含非 IPv4 条目" "0" \
    "$(jq '[.[] | select(test("^[0-9.]+/[0-9]+$") | not)] | length' <<<"${xray_ranges}")"

# --- Reality 密钥对解析（真实三行形态：PrivateKey / 公钥 / Hash32） ----------
# Xray v25.8.31+（含锁定版本 v26.11.9）的 `xray x25519` 固定输出三行，第三行是 Hash32：
# 解析器必须跳过这一行，绝不把它当成公钥候选。
KEY_A=$(printf 'A%.0s' {1..43})
KEY_B=$(printf 'B%.0s' {1..43})
KEY_C=$(printf 'C%.0s' {1..43})
KEY_H=$(printf 'H%.0s' {1..43})

REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
xray_parse_reality_keypair "PrivateKey: ${KEY_A}
Password (PublicKey): ${KEY_B}
Hash32: ${KEY_H}" || fail "真实三行输出（Password (PublicKey)）必须可解析"
assert_equal "真实三行输出私钥" "${KEY_A}" "${REALITY_PRIVATE_KEY}"
assert_equal "真实三行输出公钥取 Password (PublicKey)" "${KEY_B}" "${REALITY_PUBLIC_KEY}"
[[ "${REALITY_PUBLIC_KEY}" != "${KEY_H}" ]] || fail "Hash32 绝不能被当作公钥"

REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
xray_parse_reality_keypair "PrivateKey: ${KEY_A}
Password: ${KEY_C}
Hash32: ${KEY_H}" || fail "Password 三行形态必须可解析"
assert_equal "Password 三行形态公钥" "${KEY_C}" "${REALITY_PUBLIC_KEY}"
[[ "${REALITY_PUBLIC_KEY}" != "${KEY_H}" ]] || fail "Hash32 绝不能被当作公钥"

REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
xray_parse_reality_keypair "PrivateKey: ${KEY_A}
PublicKey: ${KEY_B}
Hash32: ${KEY_H}" || fail "PublicKey 三行形态必须可解析"
assert_equal "PublicKey 三行形态公钥" "${KEY_B}" "${REALITY_PUBLIC_KEY}"
[[ "${REALITY_PUBLIC_KEY}" != "${KEY_H}" ]] || fail "Hash32 绝不能被当作公钥"

# 优先级：三种公钥行同时出现时取 Password (PublicKey)。
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
xray_parse_reality_keypair "PrivateKey: ${KEY_A}
PublicKey: ${KEY_B}
Password: ${KEY_C}
Password (PublicKey): ${KEY_A}
Hash32: ${KEY_H}" || fail "混合形态必须可解析"
assert_equal "公钥优先级 Password (PublicKey) > Password > PublicKey" \
    "${KEY_A}" "${REALITY_PUBLIC_KEY}"

# 只有私钥与 Hash32、没有任何公钥行：解析结果没有公钥，必须失败。
expect_fail "仅有私钥与 Hash32 而无公钥行时必须失败" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    xray_parse_reality_keypair "PrivateKey: $2
Hash32: $3"' _ "${ROOT_DIR}" "${KEY_A}" "${KEY_H}"
expect_fail "缺少私钥" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    xray_parse_reality_keypair "Password: $2"' _ "${ROOT_DIR}" "${KEY_B}"
expect_fail "私钥长度不合法" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    xray_parse_reality_keypair "PrivateKey: short
Password: $2"' _ "${ROOT_DIR}" "${KEY_B}"
expect_fail "空输出" bash -c '
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    xray_parse_reality_keypair ""' _ "${ROOT_DIR}"

# --- 服务端配置 -------------------------------------------------------------
FIXTURE_ENV=(
    CF_ZONE=example.com
    DIRECT_DOMAIN=direct.example.com
    DIRECT_NODE_NAME="🇺🇸直连"
    CF_NODE_DOMAIN=cf.example.com
    CF_NODE_PREFIX="🇺🇸CF"
    VLESS_UUID=11111111-2222-4333-8444-555555555555
    VLESS_PATH=/vless-0123456789ab
    REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
    REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
    REALITY_SHORT_ID=0123456789abcdef
    ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
)
render_fixture() { # $1=目标文件 $2=blocked
    env "${FIXTURE_ENV[@]}" bash -c '
        set -Eeuo pipefail
        source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
        RUNTIME_TMP=$2
        render_xray_config "$3" "$4"' _ "${ROOT_DIR}" "${RUNTIME_TMP}" "$1" "${2:-0}"
}

ready_config="${TMP_DIR}/xray-ready.json"
render_fixture "${ready_config}" 0 || fail "模式 5 服务端配置渲染失败"
jq empty "${ready_config}" >/dev/null 2>&1 || fail "配置不是合法 JSON"
xray_config_structure_ok "${ready_config}" 0 || fail "正式配置必须通过就绪态结构校验"

assert_equal "日志级别 warning" "warning" "$(jq -r '.log.loglevel' "${ready_config}")"
assert_equal "DNS 只用 8.8.8.8" '["8.8.8.8"]' "$(jq -c '.dns.servers' "${ready_config}")"
assert_equal "DNS 解析策略 UseIPv4" "UseIPv4" "$(jq -r '.dns.queryStrategy' "${ready_config}")"
assert_equal "Reality 入站 tag" "vless-reality-in" "$(jq -r '.inbounds[0].tag' "${ready_config}")"
assert_equal "Reality 监听 0.0.0.0" "0.0.0.0" "$(jq -r '.inbounds[0].listen' "${ready_config}")"
assert_equal "Reality 端口 443" "443" "$(jq -r '.inbounds[0].port' "${ready_config}")"
assert_equal "Reality 回落目标回环 9443" "127.0.0.1:9443" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.target' "${ready_config}")"
assert_equal "Reality xver 0" "0" "$(jq -r '.inbounds[0].streamSettings.realitySettings.xver' "${ready_config}")"
assert_equal "Reality maxTimeDiff 120000" "120000" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.maxTimeDiff' "${ready_config}")"
assert_equal "Reality 传输 raw" "raw" "$(jq -r '.inbounds[0].streamSettings.network' "${ready_config}")"
assert_equal "Reality vision 流控" "xtls-rprx-vision" \
    "$(jq -r '.inbounds[0].settings.clients[0].flow' "${ready_config}")"
assert_equal "XHTTP 回环 10086" "127.0.0.1:10086" \
    "$(jq -r '"\(.inbounds[1].listen):\(.inbounds[1].port)"' "${ready_config}")"
assert_equal "XHTTP 服务端 mode auto" "auto" \
    "$(jq -r '.inbounds[1].streamSettings.xhttpSettings.mode' "${ready_config}")"
assert_equal "xPaddingBytes 位于 extra" "100-1000" \
    "$(jq -r '.inbounds[1].streamSettings.xhttpSettings.extra.xPaddingBytes' "${ready_config}")"
assert_equal "scStreamUpServerSecs 位于 extra" "20-80" \
    "$(jq -r '.inbounds[1].streamSettings.xhttpSettings.extra.scStreamUpServerSecs' "${ready_config}")"
assert_equal "xPaddingBytes 不在 xhttpSettings 顶层" "0" \
    "$(jq '.inbounds[1].streamSettings.xhttpSettings | has("xPaddingBytes") | if . then 1 else 0 end' \
        "${ready_config}")"
assert_equal "scStreamUpServerSecs 不在 xhttpSettings 顶层" "0" \
    "$(jq '.inbounds[1].streamSettings.xhttpSettings | has("scStreamUpServerSecs") | if . then 1 else 0 end' \
        "${ready_config}")"
assert_equal "路由阻断 12 条（11 私网 + ::/0）" "12" \
    "$(jq -r '.routing.rules[0].ip | length' "${ready_config}")"
assert_equal "路由阻断含 ::/0" "1" \
    "$(jq '[.routing.rules[0].ip[] | select(. == "::/0")] | length' "${ready_config}")"
assert_equal "路由阻断指向 blackhole" "block" \
    "$(jq -r '.routing.rules[0].outboundTag' "${ready_config}")"
assert_equal "出站 freedom 走 UseIPv4" "UseIPv4" \
    "$(jq -r '.outbounds[] | select(.tag == "direct") | .settings.domainStrategy' "${ready_config}")"
assert_equal "出站 blackhole 存在" "1" \
    "$(jq '[.outbounds[] | select(.tag == "block" and .protocol == "blackhole")] | length' \
        "${ready_config}")"

blocked_config="${TMP_DIR}/xray-blocked.json"
render_fixture "${blocked_config}" 1 || fail "阻断态渲染失败"
xray_config_structure_ok "${blocked_config}" 1 || fail "阻断态配置必须通过阻断态结构校验"
assert_equal "阻断态省略 XHTTP 入站" "0" \
    "$(jq '[.inbounds[] | select(.tag == "vless-cdn-in")] | length' "${blocked_config}")"

# 结构校验负例：就绪/阻断态入站错配、extra 字段放顶层、缺少 ::/0、缺少 Reality 回落目标。
expect_fail "就绪态缺少 vless-cdn-in 必须被拒" xray_config_structure_ok "${blocked_config}" 0
expect_fail "阻断态包含 vless-cdn-in 必须被拒" xray_config_structure_ok "${ready_config}" 1
expect_fail "validate_xray_config 就绪态缺 vless-cdn-in 必须被拒" validate_xray_config "${blocked_config}" 0
jq '.inbounds[1].streamSettings.xhttpSettings.xPaddingBytes = "100-1000"
    | .inbounds[1].streamSettings.xhttpSettings |= del(.extra.xPaddingBytes)' \
    "${ready_config}" >"${TMP_DIR}/xray-bad-extra.json"
expect_fail "xPaddingBytes 放顶层必须被拒" xray_config_structure_ok "${TMP_DIR}/xray-bad-extra.json"
jq '.routing.rules[0].ip |= map(select(. != "::/0"))' "${ready_config}" \
    >"${TMP_DIR}/xray-no-ipv6.json"
expect_fail "缺少 ::/0 阻断必须被拒" xray_config_structure_ok "${TMP_DIR}/xray-no-ipv6.json"
jq '.inbounds[0].streamSettings.realitySettings.target = "127.0.0.1:8443"' "${ready_config}" \
    >"${TMP_DIR}/xray-bad-target.json"
expect_fail "Reality 回落目标错误必须被拒" xray_config_structure_ok "${TMP_DIR}/xray-bad-target.json"
jq 'del(.inbounds[0].settings.clients[0].flow)' "${ready_config}" \
    >"${TMP_DIR}/xray-no-flow.json"
expect_fail "缺少 vision 流控必须被拒" xray_config_structure_ok "${TMP_DIR}/xray-no-flow.json"

# --- 模式 1（cloudflare）：纯 XHTTP，无 Reality -------------------------------
MODE1_ENV=(
    PROTOCOL=cloudflare
    CF_NODE_DOMAIN=cf.example.com
    CF_NODE_PREFIX=CF
    VLESS_UUID=11111111-2222-4333-8444-555555555555
    VLESS_PATH=/vless-0123456789ab
)
render_mode1() { # $1=目标文件 $2=blocked
    env "${MODE1_ENV[@]}" bash -c '
        set -Eeuo pipefail
        source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
        RUNTIME_TMP=$2
        render_xray_config "$3" "$4"' _ "${ROOT_DIR}" "${RUNTIME_TMP}" "$1" "${2:-0}"
}
# 结构校验读 PROTOCOL：用子 shell 赋值，避免污染本进程后续的模式 5 断言。
mode1_structure_ok() { # $1=文件 $2=blocked
    ( PROTOCOL=cloudflare; xray_config_structure_ok "$1" "${2:-}" )
}

mode1_ready="${TMP_DIR}/xray-mode1.json"
render_mode1 "${mode1_ready}" 0 || fail "模式 1 服务端配置渲染失败"
assert_equal "模式 1 只有 XHTTP 入站" "vless-cdn-in" \
    "$(jq -r '[.inbounds[].tag] | join(",")' "${mode1_ready}")"
assert_equal "模式 1 XHTTP 回环 10086" "127.0.0.1:10086" \
    "$(jq -r '.inbounds[0] | "\(.listen):\(.port)"' "${mode1_ready}")"
assert_equal "模式 1 XHTTP 服务端 mode auto" "auto" \
    "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.mode' "${mode1_ready}")"
assert_equal "模式 1 xPaddingBytes 在 extra" "100-1000" \
    "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.extra.xPaddingBytes' "${mode1_ready}")"
assert_equal "模式 1 scStreamUpServerSecs 在 extra" "20-80" \
    "$(jq -r '.inbounds[0].streamSettings.xhttpSettings.extra.scStreamUpServerSecs' "${mode1_ready}")"
assert_equal "模式 1 不含 vless-reality-in" "0" \
    "$(jq '[.inbounds[] | select(.tag == "vless-reality-in")] | length' "${mode1_ready}")"
mode1_structure_ok "${mode1_ready}" 0 || fail "模式 1 就绪态必须通过结构校验"
# 把模式 5 的 Reality 入站拼进模式 1 配置：纯 XHTTP 模式下必须被结构校验拒绝。
jq --slurpfile r "${ready_config}" '.inbounds += [$r[0].inbounds[0]]' \
    "${mode1_ready}" >"${TMP_DIR}/xray-mode1-reality.json" \
    || fail "无法构造模式 1 混入 Reality 的负例"

mode1_blocked="${TMP_DIR}/xray-mode1-blocked.json"
render_mode1 "${mode1_blocked}" 1 || fail "模式 1 阻断态渲染失败"
assert_equal "模式 1 阻断态入站为空数组" "[]" "$(jq -c '.inbounds' "${mode1_blocked}")"
mode1_structure_ok "${mode1_blocked}" 1 || fail "模式 1 阻断态必须通过结构校验"
expect_fail "模式 1 阻断态按就绪态校验必须被拒" mode1_structure_ok "${mode1_blocked}" 0
expect_fail "模式 1 就绪态按阻断态校验必须被拒" mode1_structure_ok "${mode1_ready}" 1
expect_fail "模式 1 就绪态缺 vless-cdn-in 必须被拒" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    PROTOCOL=cloudflare jq ".inbounds = []" "$2" >"$3"
    PROTOCOL=cloudflare xray_config_structure_ok "$3" 0' \
    _ "${ROOT_DIR}" "${mode1_ready}" "${TMP_DIR}/xray-mode1-empty.json"
expect_fail "模式 1 混入 vless-reality-in 必须被拒" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    PROTOCOL=cloudflare xray_config_structure_ok "$2" 0' \
    _ "${ROOT_DIR}" "${TMP_DIR}/xray-mode1-reality.json"
expect_fail "未知 PROTOCOL 必须被拒" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    PROTOCOL=bogus xray_config_structure_ok "$2" 0' _ "${ROOT_DIR}" "${mode1_ready}"

# 模式 1 的客户端产物与模式 5 共用同一套 XHTTP 构造器，但不得带 Reality 字段。
mode1_link=$(env "${MODE1_ENV[@]}" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    build_xray_xhttp_link' _ "${ROOT_DIR}") || fail "模式 1 客户端链接渲染失败"
assert_contains "模式 1 链接 type=xhttp" "${mode1_link}" 'type=xhttp&'
assert_contains "模式 1 链接 mode=stream-up" "${mode1_link}" '&mode=stream-up&'
assert_contains "模式 1 链接 alpn=h2" "${mode1_link}" '&alpn=h2&'
assert_contains "模式 1 链接 host 为节点域名" "${mode1_link}" '&host=cf.example.com&'
assert_not_contains "模式 1 链接不带 Reality" "${mode1_link}" 'security=reality'
mode1_node=$(env "${MODE1_ENV[@]}" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    build_mihomo_xray_xhttp_node' _ "${ROOT_DIR}") || fail "模式 1 Mihomo 节点渲染失败"
assert_contains "模式 1 Mihomo 节点 network xhttp" "${mode1_node}" 'network: xhttp'
assert_contains "模式 1 Mihomo 节点 mode stream-up" "${mode1_node}" 'mode: stream-up'
assert_not_contains "模式 1 Mihomo 节点不带 reality-opts" "${mode1_node}" 'reality-opts:'

# --- 客户端节点 -------------------------------------------------------------
links=$(env "${FIXTURE_ENV[@]}" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    build_xray_reality_link; printf "\n"; build_xray_xhttp_link' _ "${ROOT_DIR}") \
    || fail "客户端链接渲染失败"
assert_contains "直连节点是 Reality vision" "${links}" \
    'security=reality&sni=direct.example.com&fp=chrome&pbk=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI'
assert_contains "直连节点 type=tcp" "${links}" 'type=tcp&packetEncoding=xudp'
assert_contains "橙云节点 type=xhttp + stream-up" "${links}" 'type=xhttp&'
assert_contains "橙云节点 mode=stream-up" "${links}" '&mode=stream-up&'
assert_contains "橙云节点 alpn=h2" "${links}" '&alpn=h2&'
assert_contains "橙云节点 host 为节点域名" "${links}" '&host=cf.example.com&path=%2Fvless-0123456789ab'
assert_contains "橙云节点 extra 含上行方法与 xmux" "${links}" 'uplinkHTTPMethod'
assert_contains "橙云节点 extra 含 hMaxRequestTimes" "${links}" 'hMaxRequestTimes'
assert_contains "橙云节点 extra 含 maxConnections=8" "${links}" 'maxConnections%22%3A8'
assert_contains "橙云节点 extra 含 hMaxReusableSecs=600-1200" "${links}" 'hMaxReusableSecs%22%3A%22600-1200%22'
assert_contains "橙云节点 extra 含 hKeepAlivePeriod=30" "${links}" 'hKeepAlivePeriod%22%3A30'
assert_not_contains "链接不泄露源站密钥" "${links}" '0123456789abcdef0123456789abcdef'

# 优选地址只替换连接地址，SNI/host 仍是节点域名。
edge_links=$(env "${FIXTURE_ENV[@]}" CF_EDGE_ADDRESS=edge9.cloudflare.182682.xyz bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    build_xray_xhttp_link' _ "${ROOT_DIR}") || fail "优选地址渲染失败"
assert_contains "cdnEdgeAddress 替换连接地址" "${edge_links}" '@edge9.cloudflare.182682.xyz:443?'
assert_contains "cdnEdgeAddress 不改变 SNI" "${edge_links}" '&sni=cf.example.com&'
assert_contains "cdnEdgeAddress 不改变 host" "${edge_links}" '&host=cf.example.com&'

nodes=$(env "${FIXTURE_ENV[@]}" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    build_mihomo_xray_reality_node; printf "\n"; build_mihomo_xray_xhttp_node' _ "${ROOT_DIR}") \
    || fail "Mihomo 节点渲染失败"
assert_contains "Mihomo 直连节点 network tcp" "${nodes}" 'network: tcp'
assert_contains "Mihomo 直连节点 ip-version ipv4" "${nodes}" 'ip-version: ipv4'
assert_contains "Mihomo 直连节点 vision" "${nodes}" 'flow: xtls-rprx-vision'
assert_contains "Mihomo 直连节点 reality-opts" "${nodes}" 'reality-opts:'
assert_contains "Mihomo 直连节点 MLKEM 开关（离线默认 >= 26.9.8）" "${nodes}" \
    'support-x25519mlkem768: true'
assert_contains "Mihomo 橙云节点 network xhttp" "${nodes}" 'network: xhttp'
assert_contains "Mihomo 橙云节点 no-grpc-header false" "${nodes}" 'no-grpc-header: false'
assert_contains "Mihomo 橙云节点 uplink-http-method POST" "${nodes}" 'uplink-http-method: POST'
assert_contains "Mihomo 橙云节点 reuse-settings" "${nodes}" 'reuse-settings:'
assert_contains "Mihomo 橙云节点 max-connections 8" "${nodes}" 'max-connections: 8'
assert_contains "Mihomo 橙云节点 h-max-request-times" "${nodes}" 'h-max-request-times: "300-600"'
assert_contains "Mihomo 橙云节点 h-max-reusable-secs" "${nodes}" 'h-max-reusable-secs: "600-1200"'
assert_contains "Mihomo 橙云节点 h-keep-alive-period 30" "${nodes}" 'h-keep-alive-period: 30'
assert_not_contains "Mihomo 节点不泄露源站密钥" "${nodes}" '0123456789abcdef0123456789abcdef'

# < 26.9.8：链接追加 mlkem=0，Mihomo 不写 PQ 开关。
legacy_links=$(env "${FIXTURE_ENV[@]}" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    xray_binary_version() { printf "26.9.7\n"; }
    build_xray_reality_link' _ "${ROOT_DIR}") || fail "旧版本链接渲染失败"
assert_contains "旧版本链接追加 mlkem=0" "${legacy_links}" '&mlkem=0#'
legacy_node=$(env "${FIXTURE_ENV[@]}" bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"; source "$1/lib/xray-core.sh"; source "$1/lib/xray-runtime.sh"
    xray_binary_version() { printf "26.9.7\n"; }
    build_mihomo_xray_reality_node' _ "${ROOT_DIR}") || fail "旧版本节点渲染失败"
assert_not_contains "旧版本不写 PQ 开关" "${legacy_node}" 'support-x25519mlkem768'

# --- 服务单元 ---------------------------------------------------------------
install_xray_service || fail "Xray 服务单元写入失败"
unit=$(<"${XRAY_SERVICE_FILE}")
assert_contains "单元以 root 运行" "${unit}" "User=root"
assert_contains "单元声明资源目录" "${unit}" "Environment=XRAY_LOCATION_ASSET=$(dirname "${XRAY_BIN}")"
assert_contains "单元启动命令" "${unit}" "ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}"
assert_contains "失败重启" "${unit}" "Restart=on-failure"
assert_contains "重启退避" "${unit}" "RestartSec=10s"
assert_contains "启动超时" "${unit}" "TimeoutStartSec=30s"
assert_contains "文件句柄上限" "${unit}" "LimitNOFILE=1048576"
assert_contains "启动限流窗口" "${unit}" "StartLimitIntervalSec=120"
assert_contains "启动限流次数" "${unit}" "StartLimitBurst=3"

# --- 下载与摘要校验（外部边界替身） ------------------------------------------
case "$(uname -m)" in
x86_64 | amd64) TEST_ARCH=amd64 ;;
aarch64 | arm64) TEST_ARCH=arm64 ;;
*) fail "测试机器架构不在锁定范围内：$(uname -m)" ;;
esac
archive_name=$(xray_archive_name "${TEST_ARCH}")
python3 - <<'PY' "${TMP_DIR}/zip"
import sys, os
os.makedirs(sys.argv[1], exist_ok=True)
src = os.path.join(sys.argv[1], 'xray')
with open(src, 'w', encoding='utf-8') as handle:
    handle.write('#!/usr/bin/env bash\n'
                 'if [[ "${1:-}" == "version" ]]; then\n'
                 '    printf "Xray 26.11.9 (Xray, Penetrates Everything.) test\\n"\n'
                 '    printf "A unified platform.\\n"\n'
                 '    exit 0\n'
                 'fi\n'
                 'exit 0\n')
os.chmod(src, 0o755)
PY
fake_archive="${TMP_DIR}/${archive_name}"
python3 -m zipfile -c "${fake_archive}" "${TMP_DIR}/zip/xray" >/dev/null \
    || fail "无法构造测试归档"
fake_sha=$(openssl dgst -sha256 "${fake_archive}" | awk '{print $NF}')
wrong_sha=$(printf '0%.0s' {1..64})
curl_log="${TMP_DIR}/xray-curl.log"
STUB_DIGEST_FILE="${TMP_DIR}/digest.txt"

xray_download_case() { # $1=.dgst 内容 $2=latest 跳转 URL（空=正常 v26.11.9） $3=版本替身（空=正确）
    local digest=$1 latest_url=${2:-https://github.com/XTLS/Xray-core/releases/tag/v26.11.9} bad_version=${3:-} status=0
    printf '%s\n' "${digest}" >"${STUB_DIGEST_FILE}"
    (
        : >"${curl_log}"
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
            printf '%s\n' "${url}" >>"${curl_log}"
            case "${url}" in
            */releases/latest)
                [[ "${latest_url}" != "FAIL" ]] || return 1
                printf '%s' "${latest_url}"
                return 0
                ;;
            *.zip.dgst) [[ -n "${out}" ]] || return 1; cp "${STUB_DIGEST_FILE}" "${out}" ;;
            *.zip) [[ -n "${out}" ]] || return 1; cp "${fake_archive}" "${out}" ;;
            *) return 1 ;;
            esac
        }
        # 归档解压只依赖 python3（zipfile），不额外要求 zip/unzip 命令行。
        unzip() {
            local archive="" dest=""
            while (($#)); do
                case "$1" in
                -d) dest=$2; shift 2 ;;
                -*) shift ;;
                *) archive=$1; shift ;;
                esac
            done
            python3 -m zipfile -e "${archive}" "${dest}"
        }
        if [[ -n "${bad_version}" ]]; then
            xray_binary_version() {
                if [[ -f "$1" ]]; then
                    printf '%s\n' "${bad_version}"
                    return 0
                fi
                return 1
            }
        fi
        download_xray
    ) >/dev/null 2>&1 || status=$?
    printf '%s' "${status}"
}

reset_old_xray() {
    printf 'old-xray\n' >"${XRAY_BIN}"
    chmod 0755 "${XRAY_BIN}"
}
assert_kept() {
    local label=$1 status=$2
    [[ "${status}" != "0" ]] || fail "${label}: 必须失败"
    assert_equal "${label}: 保留旧二进制" "old-xray" "$(<"${XRAY_BIN}")"
}

reset_old_xray
assert_equal "解析最新版本并校验 .dgst 一致时安装成功" "0" \
    "$(xray_download_case "MD5= x
SHA2-256= ${fake_sha}")"
[[ -x "${XRAY_BIN}" ]] || fail "下载后 xray 必须可执行"
assert_equal "安装后版本" "26.11.9" "$(xray_binary_version "${XRAY_BIN}")"
assert_contains "先查最新 release 跳转" "$(<"${curl_log}")" "/releases/latest"
assert_contains "再取对应版本 .dgst 清单" "$(<"${curl_log}")" "/v26.11.9/${archive_name}.dgst"
assert_contains "再取同版本本机架构归档" "$(<"${curl_log}")" "/v26.11.9/${archive_name}"

reset_old_xray
assert_kept "最新版本查询失败" \
    "$(xray_download_case "SHA2-256= ${fake_sha}" "FAIL")"
reset_old_xray
assert_kept "最新版本为预发布标签" \
    "$(xray_download_case "SHA2-256= ${fake_sha}" "https://github.com/XTLS/Xray-core/releases/tag/v26.12.0-rc1")"
reset_old_xray
assert_kept "归档与清单摘要不符" \
    "$(xray_download_case "SHA2-256= ${wrong_sha}")"
reset_old_xray
assert_kept "清单缺少 SHA2-256 行" \
    "$(xray_download_case "SHA256= ${fake_sha}")"
reset_old_xray
assert_kept "清单 SHA2-256 重复" \
    "$(xray_download_case "SHA2-256= ${fake_sha}
SHA2-256= ${fake_sha}")"
reset_old_xray
assert_kept "候选版本与解析标签不符" \
    "$(xray_download_case "SHA2-256= ${fake_sha}" "" "26.9.7")"

# --- 接线 -------------------------------------------------------------------
assert_contains "runtime.manifest 登记 xray 核心" "$(<"${ROOT_DIR}/runtime.manifest")" "lib/xray-core.sh"
assert_contains "runtime.manifest 登记 xray 运行时" "$(<"${ROOT_DIR}/runtime.manifest")" "lib/xray-runtime.sh"
assert_contains "runtime.manifest 登记模式 5 Profile" "$(<"${ROOT_DIR}/runtime.manifest")" \
    "profiles/reality-cloudflare-xhttp.sh"
assert_contains "npm test 串入 Xray 渲染测试" "$(<"${ROOT_DIR}/package.json")" "test/test_xray_render.sh"

printf 'ok - Xray 核心与模式 1/5 渲染测试通过\n'
