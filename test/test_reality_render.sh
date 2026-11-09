#!/usr/bin/env bash
# 直连 Reality（profiles/reality.sh）订阅聚合的渲染与发布测试。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/reality.sh"
AGG_LIB="${ROOT_DIR}/lib/local-aggregation.sh"

# 沙箱环境可能禁止写用户默认 TMPDIR：无参 mktemp 一律落到本测试的 /tmp 目录。
TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_reality_test.XXXXXX")
mktemp() {
    if [[ $# -eq 0 ]]; then
        command mktemp "${TMP_DIR}/file.XXXXXX"
    elif [[ $# -eq 1 && "$1" == "-d" ]]; then
        command mktemp -d "${TMP_DIR}/dir.XXXXXX"
    else
        command mktemp "$@"
    fi
}
trap 'command rm -rf -- "${TMP_DIR}"' EXIT

fail_test() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail_test "${label}: expected <${expected}> but got <${actual}>"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] \
        || fail_test "${label}: missing <${expected}> in <${text}>"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail_test "${label}: unexpected <${unexpected}> in <${text}>"
}

syntax_files=("${AGG_LIB}" "${PROFILE}")
for syntax_file in "${syntax_files[@]}"; do
    bash -n "${syntax_file}" || fail_test "语法校验失败：${syntax_file}"
done

export STATE_DIR="${TMP_DIR}/state"
export BACKUP_DIR="${STATE_DIR}/backups"
export STATE_FILE="${STATE_DIR}/state.env"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/fullchain.pem"
export KEY_FILE="${CERT_DIR}/private.key"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.port-template"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.port-template"
export SUBSCRIPTION_MIHOMO_IOS_FILE="${SUBSCRIPTION_DIR}/mihomo-ios.port-template"
export SUBSCRIPTION_BASE64_ALL_FILE="${SUBSCRIPTION_DIR}/base64-all.port-template"
export SUBSCRIPTION_MIHOMO_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-all.port-template"
export SUBSCRIPTION_MIHOMO_IOS_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-ios-all.port-template"
export COMMAND_INSTALL_DIR="${TMP_DIR}/lib"
export COMMAND_PATH="${TMP_DIR}/bin/easy_all"
export XRAY_DIR="${STATE_DIR}/xray"
export XRAY_BIN="${XRAY_DIR}/xray"
export XRAY_CONFIG="${XRAY_DIR}/config.json"
export XRAY_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-xray.service"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export REALITY_SUBSCRIPTION_JS="${TMP_DIR}/easy_all-reality-subscription.js"
export UFW_BEFORE_RULES="${TMP_DIR}/ufw/before.rules"
export UFW_BEFORE6_RULES="${TMP_DIR}/ufw/before6.rules"
export UFW_DEFAULT_CONFIG="${TMP_DIR}/ufw/default"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP_DIR}/runtime-write.lock"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress/install-progress.env"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"

mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" \
    "${WEB_ROOT}" "${SUBSCRIPTION_DIR}" "${COMMAND_INSTALL_DIR}" \
    "${TMP_DIR}/bin" "${XRAY_DIR}" "${TMP_DIR}/systemd" "${TMP_DIR}/ufw"
: >"${CERT_FILE}"
: >"${KEY_FILE}"
printf '26.9.8\n' >"${XRAY_DIR}/version"

# 保留测试预导出的隔离路径，不让 profile 的硬编码 /etc 覆盖
readonly() {
    local arg name val
    for arg in "$@"; do
        [[ "${arg}" == -* ]] && continue
        if [[ "${arg}" == *=* ]]; then
            name=${arg%%=*}
            val=${arg#*=}
            if [[ -z "${!name+x}" ]]; then
                printf -v "${name}" '%s' "${val}"
            fi
        fi
    done
}

# 订阅发布以 root:www-data 安装文件；测试只验证内容与路径，不碰宿主用户组。
install() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o | -g) shift 2 ;;
        *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
chown() { :; }
flock() { :; }
nginx() { :; }
systemctl() { :; }
require_root() { :; }

# reference 必须来自 profile 自己：先清掉宿主环境里的同名变量（含 cf-dns 共享常量），
# 否则 profile 漏定义时会被继承值掩盖成假绿。
unset CLOUDFLARE_UFW_PORT CLOUDFLARE_UFW_COMMENT CLOUDFLARE_ORIGIN_CA_ROOT_FILE
# shellcheck source=/dev/null
source "${PROFILE}"
unset -f readonly

# cf-dns.sh 的共享函数靠 Profile 常量区分模式：回源 UFW 注释决定存量安装的规则能否被识别与回收，
# 端口必须跟订阅 HTTPS 端口一致，否则卸载/回滚漏删、回源白名单加到错误端口。
assert_equal "profile: 回源 UFW 注释保持兼容" \
    "easy_all-reality-cloudflare-subscription" "${CLOUDFLARE_UFW_COMMENT}"
assert_equal "profile: 回源 UFW 端口为订阅端口" "8443" "${CLOUDFLARE_UFW_PORT}"
assert_equal "profile: 回源证书路径指向 profile 常量" \
    "${CERT_DIR}/cloudflare-origin-ca-ecc.pem" "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
require_root() { :; }
# 渲染测试不启动真实 sshd/ss：固定 SSH 端口快照，才能断言注入 nginx 的变量值。
detect_ssh_ports() { SSH_PORTS="22"; }
trap 'status=$?; cleanup; command rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

NODE_NAME="MY_REALITY"
NODE_HOST="198.51.100.10"
VLESS_UUID="11111111-2222-4111-8111-111111111111"
REALITY_TARGET="swdist.apple.com:443"
REALITY_PRIVATE_KEY="test-private-key"
REALITY_PUBLIC_KEY="test-public-key"
REALITY_SHORT_ID="0123456789abcdef"
SUB_PORT_MODE="443"
SUBSCRIPTION_MODE="deploy"
SUBSCRIPTION_DOMAIN="sub.example.com"
SUB_DOWNLOAD_NAME="EASYALL"

OWNER_TOKEN="token-init-12345"
agg_config='{"allowedTokens":{"owner":"token-init-12345"},"nodes":[
  {"type":"vless","security":"reality","network":"tcp","name":"另一台Reality","host":"r.example.com","port":8443,"uuid":"22222222-2222-4222-8222-222222222222","sni":"www.example.com","pbk":"PUBKEY-abc_123","sid":"0123456789abcdef","fp":"chrome"},
  {"type":"vless","security":"tls","network":"xhttp","name":"另一台XHTTP","host":"x.example.com","port":443,"uuid":"33333333-3333-4333-8333-333333333333","sni":"x.example.com","path":"/agg-path/","mode":"stream-up"},
  {"type":"mieru","name":"备用Mieru","host":"m.example.com","portRange":"50000-50512","username":"agguser","password":"agg-password-12345","multiplexing":"MULTIPLEXING_LOW","optional":true}
]}'

reality_apply_subscription_config "${agg_config}" \
    || fail_test "aggregation: valid config rejected"
assert_equal "aggregation: token dictionary applied" "1" "$(jq 'length' <<<"${ALLOWED_TOKENS}")"
assert_equal "aggregation: nodes parsed" "3" "$(jq 'length' <<<"${AGGREGATION_NODES}")"
assert_equal "aggregation: config normalized into state" \
    "${AGGREGATION_NODES}" "$(jq -c '.nodes' <<<"${SUBSCRIPTION_CONFIG}")"

for invalid in \
    '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[],"fallbackCdnNodes":[]}' \
    '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"trojan","name":"t","host":"t.example.com","password":"abcdefgh"}]}' \
    '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"vless","security":"reality","network":"tcp","name":"MY_REALITY","host":"r.example.com","uuid":"22222222-2222-4222-8222-222222222222","sni":"s","pbk":"p","sid":"aabbccdd"}]}' \
    '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"vless","security":"reality","network":"tcp","name":"PROXY","host":"r.example.com","uuid":"22222222-2222-4222-8222-222222222222","sni":"s","pbk":"p","sid":"aabbccdd"}]}' \
    '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"vless","security":"reality","network":"tcp","name":"dupe","host":"r.example.com","uuid":"22222222-2222-4222-8222-222222222222","sni":"s","pbk":"p","sid":"aabbccdd"},{"type":"vless","security":"reality","network":"tcp","name":"dupe","host":"r.example.com","uuid":"22222222-2222-4222-8222-222222222222","sni":"s","pbk":"p","sid":"aabbccdd"}]}'; do
    if reality_apply_subscription_config "${invalid}" >/dev/null 2>&1; then
        fail_test "aggregation: invalid config accepted: ${invalid}"
    fi
done
# 失败不得破坏上一份有效配置
assert_equal "aggregation: rejected config keeps previous nodes" "3" \
    "$(jq 'length' <<<"${AGGREGATION_NODES}")"

# 走真实发布路径：默认与 node=all 两份模板一起生成并发布。
install_static_subscriptions || fail_test "publish: install_static_subscriptions failed"

for file in \
    "${SUBSCRIPTION_BASE64_FILE}" "${SUBSCRIPTION_MIHOMO_FILE}" \
    "${SUBSCRIPTION_MIHOMO_IOS_FILE}" "${SUBSCRIPTION_BASE64_ALL_FILE}" \
    "${SUBSCRIPTION_MIHOMO_ALL_FILE}" "${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE}"; do
    [[ -s "${file}" ]] || fail_test "publish: missing ${file}"
done

decode_base64() {
    printf '%s' "$(<"$1")" | openssl base64 -d -A
}

links_default=$(decode_base64 "${SUBSCRIPTION_BASE64_FILE}")
links_all=$(decode_base64 "${SUBSCRIPTION_BASE64_ALL_FILE}")
placeholder=__EASY_ALL_REALITY_PORT__

# 本机 Reality 节点必须始终在第一条，且只有它带端口占位符。
assert_equal "base64: default links = own + non-optional nodes" "3" \
    "$(grep -c '[^[:space:]]' <<<"${links_default}")"
assert_equal "base64: node=all links include optional node" "4" \
    "$(grep -c '[^[:space:]]' <<<"${links_all}")"
first_default=${links_default%%$'\n'*}
assert_contains "base64: own reality node is first" "${first_default}" \
    "vless://${VLESS_UUID}@${NODE_HOST}:${placeholder}?"
assert_equal "base64: exactly one port placeholder in the default template" "1" \
    "$(grep -o "${placeholder}" <<<"${links_default}" | wc -l | tr -d ' ')"
assert_contains "base64: default links include aggregated reality node" \
    "${links_default}" "@r.example.com:8443?"
assert_contains "base64: default links include aggregated xhttp node" \
    "${links_default}" "@x.example.com:443?"
assert_not_contains "base64: default links hide optional mieru node" \
    "${links_default}" "m.example.com"
assert_contains "base64: node=all links include optional mieru node" \
    "${links_all}" "mierus://"
assert_not_contains "base64: aggregated node keeps its literal port (no placeholder)" \
    "${links_all#*$'\n'}" "${placeholder}"

# PROXY 顺序：本机节点 → 聚合节点（字典名字原样）→ optional 仅 node=all。
proxy_names_default=$(sed -n '/^proxy-groups:/,/^rule-providers:/p' "${SUBSCRIPTION_MIHOMO_FILE}" \
    | sed -n 's/^        - "\(.*\)"$/\1/p')
proxy_names_all=$(sed -n '/^proxy-groups:/,/^rule-providers:/p' "${SUBSCRIPTION_MIHOMO_ALL_FILE}" \
    | sed -n 's/^        - "\(.*\)"$/\1/p')
assert_equal "mihomo: PROXY order is own then aggregated nodes" \
    "$(printf '%s\n' "${NODE_NAME}" "另一台Reality" "另一台XHTTP")" \
    "${proxy_names_default}"
assert_contains "mihomo: node=all PROXY includes optional node" \
    "${proxy_names_all}" "备用Mieru"

proxies_default=$(sed -n '/^proxies:/,/^proxy-groups:/p' "${SUBSCRIPTION_MIHOMO_FILE}")
proxies_all=$(sed -n '/^proxies:/,/^proxy-groups:/p' "${SUBSCRIPTION_MIHOMO_ALL_FILE}")
assert_equal "mihomo: default proxy count" "3" \
    "$(grep -c '^  - name: ' <<<"${proxies_default}" || true)"
assert_equal "mihomo: node=all proxy count" "4" \
    "$(grep -c '^  - name: ' <<<"${proxies_all}" || true)"
assert_equal "mihomo: exactly one port placeholder line" "1" \
    "$(grep -c "^    port: ${placeholder}$" "${SUBSCRIPTION_MIHOMO_FILE}" || true)"
assert_contains "mihomo: aggregated reality node keeps literal port" \
    "${proxies_default}" "    port: 8443"
assert_contains "mihomo: aggregated xhttp node keeps xhttp opts" \
    "${proxies_default}" 'path: "/agg-path/"'
assert_not_contains "mihomo: default proxies hide optional mieru" \
    "${proxies_default}" "type: mieru"
assert_contains "mihomo: node=all proxies include mieru" "${proxies_all}" "type: mieru"

for template in "${SUBSCRIPTION_MIHOMO_FILE}" "${SUBSCRIPTION_MIHOMO_IOS_FILE}" \
    "${SUBSCRIPTION_MIHOMO_ALL_FILE}" "${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE}"; do
    assert_equal "template: ${template##*/} keeps one end marker" "1" \
        "$(grep -Fc 'EASY_ALL_REALITY_TEMPLATE_END_V1' "${template}")"
    assert_equal "template: ${template##*/} ends with the marker" \
        "# EASY_ALL_REALITY_TEMPLATE_END_V1" "$(tail -n 1 "${template}")"
done

# 重新发布必须清掉上一代的残留文件。
: >"${SUBSCRIPTION_DIR}/stale.yaml"
install_static_subscriptions || fail_test "publish: republish failed"
[[ ! -e "${SUBSCRIPTION_DIR}/stale.yaml" ]] \
    || fail_test "publish: stale subscription file must be removed"

# Nginx 必须把 node=all 与 -all 变体都接到发布出来的文件上。
write_subscription_nginx_config || fail_test "nginx: config generation failed"
nginx_config=$(<"${NGINX_CONFIG}")
assert_contains "nginx: node=all map is rendered" "${nginx_config}" \
    'map $arg_node $easy_all_subscription_show_all'
assert_contains "nginx: base64-all alias points at the published file" "${nginx_config}" \
    "alias ${SUBSCRIPTION_BASE64_ALL_FILE};"
assert_contains "nginx: mihomo-all alias points at the published file" "${nginx_config}" \
    "alias ${SUBSCRIPTION_MIHOMO_ALL_FILE};"
assert_contains "nginx: mihomo-ios-all alias points at the published file" "${nginx_config}" \
    "alias ${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE};"
assert_contains "nginx: subscribe route keeps token auth" "${nginx_config}" \
    '$easy_all_subscription_allowed = __denied__'
# 订阅下发的动态端口必须避开 SSH 端口：SSH 端口快照要进入每个 Reality 订阅 location。
assert_contains "nginx: 注入归一化后的 SSH 端口列表" "${nginx_config}" \
    'set $easy_all_ssh_ports "22";'
assert_equal "nginx: 每个 Reality 订阅 location 都注入 SSH 端口快照" \
    "$(grep -c 'set \$easy_all_reality_port_mode' <<<"${nginx_config}")" \
    "$(grep -c 'set \$easy_all_ssh_ports' <<<"${nginx_config}")"
# 订阅 server 块的兜底 404 由 Reality 自己在共享渲染函数之后输出；共享函数（订阅域名 server
# 块之外的调用方）不得再补一份，否则 nginx -t 会因重复 location 失败。
reality_server_block=$(awk '/^server \{/ { inside = 1 } inside' <<<"${nginx_config}")
assert_equal "nginx: Reality 订阅 server 块只有一个兜底 404" "1" \
    "$(grep -cF 'location / { return 404; }' <<<"${reality_server_block}")"

# 旧状态升级：只有 ALLOWED_TOKENS 时，load_state 自动折叠成 nodes 为空的订阅配置。
cat >"${STATE_FILE}" <<'EOF'
STATE_VERSION='0'
PROTOCOL='reality'
NODE_NAME='MY_REALITY'
NODE_HOST='198.51.100.10'
SUBSCRIPTION_MODE='deploy'
SUB_DOWNLOAD_NAME='EASYALL'
SUBSCRIPTION_DOMAIN='sub.example.com'
ALLOWED_TOKENS='{"owner":"token-init-12345"}'
CLOUDFLARE_ZONE_ID='zone-1'
CLOUDFLARE_ZONE_NAME='example.com'
CLOUDFLARE_ORIGIN_CERT_ID='cert-1'
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON='2041-11-03 00:00:00 +0000 UTC'
CLOUDFLARE_STRICT_RULESET_ID='ruleset-1'
EOF
load_state --reload || fail_test "legacy state: load_state failed"
assert_equal "legacy state: tokens folded into the subscription config" \
    '{"owner":"token-init-12345"}' "$(jq -c '.allowedTokens' <<<"${SUBSCRIPTION_CONFIG}")"
assert_equal "legacy state: folded config starts without aggregated nodes" \
    '[]' "$(jq -c '.nodes' <<<"${SUBSCRIPTION_CONFIG}")"
assert_equal "legacy state: runtime aggregation list stays empty" "[]" "${AGGREGATION_NODES}"

# 折叠是纯函数：环境里残留的 AGGREGATION_NODES 不得渗进旧状态折叠结果。
folded_with_ambient=$(
    AGGREGATION_NODES='[{"type":"mieru","name":"残留节点"}]'
    subscription_config_from_tokens '{"owner":"token-init-12345"}'
)
assert_equal "fold: ambient aggregation nodes never leak into the folded config" \
    '[]' "$(jq -c '.nodes' <<<"${folded_with_ambient}")"

# 状态里的订阅配置损坏时，load_state 只告警；edit-sub / uninstall 仍能进入，
# 但写订阅前必须停止（不能把错节点发布出去）。
cat >"${STATE_FILE}" <<'EOF'
STATE_VERSION='0'
PROTOCOL='reality'
NODE_NAME='MY_REALITY'
NODE_HOST='198.51.100.10'
VLESS_UUID='11111111-2222-4111-8111-111111111111'
REALITY_TARGET='swdist.apple.com:443'
REALITY_PRIVATE_KEY='test-private-key'
REALITY_PUBLIC_KEY='test-public-key'
REALITY_SHORT_ID='0123456789abcdef'
SUBSCRIPTION_MODE='deploy'
SUB_DOWNLOAD_NAME='EASYALL'
SUBSCRIPTION_DOMAIN='sub.example.com'
ALLOWED_TOKENS='{"owner":"token-init-12345"}'
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"trojan","name":"坏节点","host":"t.example.com","password":"abcdefgh"}]}'
CLOUDFLARE_ZONE_ID='zone-1'
CLOUDFLARE_ZONE_NAME='example.com'
CLOUDFLARE_ORIGIN_CERT_ID='cert-1'
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON='2041-11-03 00:00:00 +0000 UTC'
CLOUDFLARE_STRICT_RULESET_ID='ruleset-1'
EOF
load_out=$(load_state --reload 2>&1) || fail_test "broken state: load_state must not abort the CLI"
assert_contains "broken state: load_state warns instead of dying" "${load_out}" "订阅配置无效"
# 同一份状态在真实 CLI 里的完整闭环：edit-sub / uninstall 的入口能进，写订阅被拦住。
# 新起一个子 shell：本进程内存里的旧配置会被 load_state 的环境回填拾回去，测不到状态文件。
broken_rc=0
broken_out=$(
    unset SUBSCRIPTION_CONFIG AGGREGATION_NODES ALLOWED_TOKENS
    collect_installed_state >/dev/null 2>&1 || exit 41
    if ( install_static_subscriptions ) 2>&1; then exit 42; fi
    printf 'publish-blocked\n'
) || broken_rc=$?
assert_equal "broken state: entries stay usable while publishing fails closed" "0" "${broken_rc}"
assert_contains "broken state: publish stops before writing any file" "${broken_out}" "publish-blocked"
assert_contains "broken state: publish points at edit-sub" "${broken_out}" "easy_all edit-sub"

# 带副作用的入口必须在动任何云端资源前拦住：否则会白签一张证书再报无关错误。
cf_marker="${TMP_DIR}/cloudflare-called"
renew_out=$(
    unset SUBSCRIPTION_CONFIG AGGREGATION_NODES ALLOWED_TOKENS
    cloudflare_api_request() { printf 'called\n' >>"${cf_marker}"; }
    renew_subscription_certificate 2>&1
) && fail_test "renew-cert: must fail closed on a broken subscription config"
assert_contains "renew-cert: failure points at the subscription config" "${renew_out}" "订阅配置无效（需 allowedTokens"
[[ ! -e "${cf_marker}" ]] || fail_test "renew-cert: must not touch Cloudflare before validating the config"

# 旧状态里连 Token 字典都是坏的：仍然只能告警，uninstall 必须能进。
cat >"${STATE_FILE}" <<'EOF'
STATE_VERSION='0'
PROTOCOL='reality'
NODE_NAME='MY_REALITY'
NODE_HOST='198.51.100.10'
VLESS_UUID='11111111-2222-4111-8111-111111111111'
REALITY_TARGET='swdist.apple.com:443'
REALITY_PRIVATE_KEY='test-private-key'
REALITY_PUBLIC_KEY='test-public-key'
REALITY_SHORT_ID='0123456789abcdef'
SUBSCRIPTION_MODE='deploy'
SUB_DOWNLOAD_NAME='EASYALL'
SUBSCRIPTION_DOMAIN='sub.example.com'
ALLOWED_TOKENS='{"owner":'
CLOUDFLARE_ZONE_ID='zone-1'
CLOUDFLARE_ZONE_NAME='example.com'
CLOUDFLARE_ORIGIN_CERT_ID='cert-1'
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON='2041-11-03 00:00:00 +0000 UTC'
CLOUDFLARE_STRICT_RULESET_ID='ruleset-1'
EOF
legacy_broken_out=$(
    unset SUBSCRIPTION_CONFIG AGGREGATION_NODES ALLOWED_TOKENS
    load_state --reload 2>&1
) || fail_test "broken legacy tokens: load_state must not abort uninstall"
assert_contains "broken legacy tokens: load_state warns" "${legacy_broken_out}" "订阅令牌无效"
legacy_publish_out=$(
    unset SUBSCRIPTION_CONFIG AGGREGATION_NODES ALLOWED_TOKENS
    load_state --reload >/dev/null 2>&1
    ( install_static_subscriptions ) 2>&1
) || true
assert_contains "broken legacy tokens: publishing stays blocked with a usable hint" \
    "${legacy_publish_out}" "easy_all edit-sub"

# edit-sub（交互）遇到非法存量配置时重生成完整默认值，而不是把非法 JSON 当默认值。
# 这里必须显式重定向 stdin：开发者在终端里直接跑测试时 [[ -t 0 ]] 为真，
# choose_subscription_config 会打印提示符并 read 等待键盘输入，整条 npm test 无限挂起。
recover_out=$(
    SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"trojan","name":"坏节点","host":"t.example.com","password":"abcdefgh"}]}'
    ALLOWED_TOKENS='{"owner":"token-init-12345"}'
    SUBSCRIPTION_DOMAIN="sub.example.com"
    SUB_DOWNLOAD_NAME="EASYALL"
    collect_deployed_subscription_inputs 1 0 </dev/null || exit 1
    jq -c '[.nodes, (.allowedTokens | length)]' <<<"${SUBSCRIPTION_CONFIG}"
)
recover_out=${recover_out##*$'\n'}
assert_equal "recovery: edit-sub rebuilds a usable default config" '[[],1]' "${recover_out}"

# 旧 Token 字典「JSON 合法但语义非法」时，edit-sub 的默认值也必须可用（不能回车即失败）。
invalid_token_out=$(
    SUBSCRIPTION_CONFIG=""
    ALLOWED_TOKENS='{"owner":"short"}'
    AGGREGATION_NODES="[]"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    SUB_DOWNLOAD_NAME="EASYALL"
    collect_deployed_subscription_inputs 1 0 </dev/null || exit 1
    jq -r '.allowedTokens.owner | length' <<<"${SUBSCRIPTION_CONFIG}"
)
invalid_token_out=${invalid_token_out##*$'\n'}
[[ "${invalid_token_out}" -ge 8 ]] \
    || fail_test "recovery: edit-sub default token must pass validation, got <${invalid_token_out}>"

# 非交互 apply 必须失败关闭：默默清空会把用户的聚合节点变成 nodes: [] 并落盘。
noninteractive_rc=0
noninteractive_out=$(
    SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-init-12345"},"nodes":[{"type":"trojan","name":"坏节点","host":"t.example.com","password":"abcdefgh"}]}'
    ALLOWED_TOKENS='{"owner":"token-init-12345"}'
    collect_deployed_subscription_inputs 0 0 2>&1
) || noninteractive_rc=$?
assert_equal "apply: a broken stored config fails instead of self-healing silently" "1" "${noninteractive_rc}"
assert_contains "apply: the failure points at edit-sub" "${noninteractive_out}" "easy_all edit-sub"

# show_subscription 只在实际存在 optional 节点时提示 node=all。
base_hint_out=$(
    collect_installed_state() { :; }
    show_node() { :; }
    SUBSCRIPTION_MODE="deploy" SUBSCRIPTION_DOMAIN="sub.example.com" SUB_DOWNLOAD_NAME="EASYALL"
    ALLOWED_TOKENS='{"owner":"token-init-12345"}'
    AGGREGATION_NODES='[{"type":"vless","name":"聚合节点","host":"r.example.com","port":8443,"security":"reality","network":"tcp","uuid":"22222222-2222-4222-8222-222222222222","sni":"www.example.com","pbk":"PUBKEY-abc_123","sid":"0123456789abcdef"}]'
    show_subscription
)
assert_not_contains "hint: no node=all hint without optional nodes" \
    "${base_hint_out}" "node=all"
optional_hint_out=$(
    collect_installed_state() { :; }
    show_node() { :; }
    SUBSCRIPTION_MODE="deploy" SUBSCRIPTION_DOMAIN="sub.example.com" SUB_DOWNLOAD_NAME="EASYALL"
    ALLOWED_TOKENS='{"owner":"token-init-12345"}'
    AGGREGATION_NODES='[{"type":"mieru","name":"备用Mieru","host":"m.example.com","portRange":"50000-50512","username":"agguser","password":"agg-password-12345","optional":true}]'
    show_subscription
)
assert_contains "hint: node=all is advertised when an optional node exists" \
    "${optional_hint_out}" "node=all"

# 非交互安装/edit-sub 只提供 ALLOWED_TOKENS 时，收集阶段也要折叠成 nodes 为空的配置。
collect_out=$(
    SUBSCRIPTION_CONFIG=""
    AGGREGATION_NODES=""
    ALLOWED_TOKENS='{"owner":"token-init-12345"}'
    SUBSCRIPTION_DOMAIN="sub.example.com"
    SUB_DOWNLOAD_NAME="EASYALL"
    SUBSCRIPTION_MODE="deploy"
    collect_deployed_subscription_inputs 0 0 || exit 1
    jq -c '.allowedTokens, .nodes' <<<"${SUBSCRIPTION_CONFIG}"
    printf '%s\n' "${SUBSCRIPTION_MODE}" "${AGGREGATION_NODES}"
)
assert_equal "collect: token-only input folds into an empty-node config" \
    "$(printf '%s\n' '{"owner":"token-init-12345"}' '[]' 'deploy' '[]')" "${collect_out}"

# 部署模式的 Cloudflare Token 必须在输入阶段（安装的第 4 步）就问完：拖到第 8 步才停下来
# 等输入，或在输入错误后触发半装回滚，都是从现场回到代码的两类真实投诉。
collect_cf_order=$(
    local_order_file="${TMP_DIR}/cloudflare-order"
    SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-init-12345"},"nodes":[]}'
    SUBSCRIPTION_DOMAIN="sub.example.com"
    SUB_DOWNLOAD_NAME="EASYALL"
    SUBSCRIPTION_MODE="deploy"
    PROMPT_SUBSCRIPTION_MODE=0
    cloudflare_collect_api_token() { printf 'token ' >>"${local_order_file}"; CLOUDFLARE_API_TOKEN=dummy; }
    cloudflare_find_parent_zone() { printf 'zone ' >>"${local_order_file}"; printf 'zone-1'; }
    cloudflare_api_request() { printf '{"id":"zone-1","name":"example.com"}'; }
    collect_subscription_inputs 0 0 >/dev/null 2>&1 || exit 1
    printf '%s%s' "$(<"${local_order_file}")" "${CLOUDFLARE_ZONE_ID}"
)
assert_equal "collect: deploy 输入阶段先收 Cloudflare Token 再校验 Zone" \
    'token zone zone-1' "${collect_cf_order}"

# 根域名与多级子域必须在输入阶段就失败：否则第 5-7 步已改过系统，第 8 步才报错触发半装回滚。
for invalid_sub_domain in "example.com" "a.b.example.com"; do
    cf_invalid_out=$(
        SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-init-12345"},"nodes":[]}'
        SUBSCRIPTION_DOMAIN="${invalid_sub_domain}"
        SUB_DOWNLOAD_NAME="EASYALL"
        SUBSCRIPTION_MODE="deploy"
        PROMPT_SUBSCRIPTION_MODE=0
        cloudflare_collect_api_token() { CLOUDFLARE_API_TOKEN=dummy; }
        cloudflare_find_parent_zone() { printf 'zone-1'; }
        cloudflare_api_request() { printf '{"id":"zone-1","name":"example.com"}'; }
        collect_subscription_inputs 0 0 2>&1
    ) || true
    assert_contains "collect: ${invalid_sub_domain} 在输入阶段被拒" \
        "${cf_invalid_out}" "下一级子域名"
done

# 首次安装失败回滚会按 CLOUDFLARE_RESOURCES_TOUCHED 决定要不要清云端：回源记录已就绪的 no-op
# 不算动过云端，否则会把上一次部署留下的（状态已删、云端保留）资源当本次残留删掉。
cf_touched_noop=$(
    unset CLOUDFLARE_RESOURCES_TOUCHED
    VPS_PUBLIC_IPV4="198.51.100.10"
    cloudflare_collect_api_token() { CLOUDFLARE_API_TOKEN=dummy; }
    cloudflare_find_parent_zone() { printf 'zone-1'; }
    cloudflare_api_request() {
        if [[ "$1" == GET ]]; then printf '{"id":"zone-1","name":"example.com"}'; return 0; fi
        printf 'WRITE %s\n' "$1" >>"${TMP_DIR}/cf-writes"
        printf '{"id":"rec-1"}'
    }
    cloudflare_record_list() {
        [[ "$2" == A ]] \
            && jq -cn --arg ip "${VPS_PUBLIC_IPV4}" '[{id:"rec-1",content:$ip,proxied:true}]' \
            || printf '[]'
    }
    reality_cloudflare_prepare_subscription >/dev/null
    printf '%s' "${CLOUDFLARE_RESOURCES_TOUCHED:-0}"
)
assert_equal "rollback: 回源记录无需改动时不算动过云端" '0' "${cf_touched_noop}"

cf_touched_create=$(
    unset CLOUDFLARE_RESOURCES_TOUCHED
    rm -f "${TMP_DIR}/cf-writes"
    VPS_PUBLIC_IPV4="198.51.100.10"
    cloudflare_collect_api_token() { CLOUDFLARE_API_TOKEN=dummy; }
    cloudflare_find_parent_zone() { printf 'zone-1'; }
    cloudflare_api_request() {
        if [[ "$1" == GET ]]; then printf '{"id":"zone-1","name":"example.com"}'; return 0; fi
        printf 'WRITE %s\n' "$1" >>"${TMP_DIR}/cf-writes"
        printf '{"id":"rec-1"}'
    }
    cloudflare_record_list() { printf '[]'; }
    reality_cloudflare_prepare_subscription >/dev/null
    printf '%s/%s' "${CLOUDFLARE_RESOURCES_TOUCHED:-0}" \
        "$(grep -c . "${TMP_DIR}/cf-writes" 2>/dev/null || printf 0)"
)
assert_equal "rollback: 新建回源记录才算动过云端" '1/1' "${cf_touched_create}"

# link 模式不残留聚合配置
COLLECT_STUB=$(
    SUBSCRIPTION_MODE="deploy"
    collect_link_subscription_inputs
    printf '%s|%s|%s\n' "${SUBSCRIPTION_MODE}" "${ALLOWED_TOKENS}" "${SUBSCRIPTION_CONFIG}"
)
assert_equal "link: aggregation config cleared" "link||" "${COLLECT_STUB}"

# 回源记录已就绪（本次未动 DNS）但本次新签了 Origin CA（状态已删、云端保留后的重装）：回滚只能
# 吊销这张新证书，不得删除上一次部署留下的回源记录/Strict TLS 规则。本用例同时充当
# 「未动云端时不得跑全量 purge」的回归。
cf_rollback_log="${TMP_DIR}/cf-rollback-log"
cf_rollback_out=$(
    unset CLOUDFLARE_RESOURCES_TOUCHED
    CLOUDFLARE_API_TOKEN=dummy
    CLOUDFLARE_ZONE_ID="zone-1"
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID="cert-new"
    stop_protocol_services() { :; }
    cloudflare_remove_origin_firewall_rules() { :; }
    restore_platform_security_state() { return 0; }
    restore_preinstall_firewall() { :; }
    restore_preinstall_ipv6() { :; }
    restore_preinstall_nginx_default_site() { return 0; }
    restore_preinstall_crontab() { :; }
    install_progress_clear() { :; }
    reality_cloudflare_purge_managed_resources() { printf 'PURGE\n' >>"${cf_rollback_log}"; }
    cloudflare_api_request() { printf '%s %s\n' "$1" "$2" >>"${cf_rollback_log}"; }
    rollback_fresh_install
) >/dev/null 2>&1
cf_rollback_log_content=""
[[ ! -f "${cf_rollback_log}" ]] || cf_rollback_log_content=$(<"${cf_rollback_log}")
assert_equal "rollback: 本次未动 DNS 时只吊销新签的 Origin CA" \
    'DELETE /certificates/cert-new' "${cf_rollback_log_content}"

# 反向：本次确实改过云端时走全量 purge，且不会再额外发一次证书 DELETE。
cf_purge_log="${TMP_DIR}/cf-purge-log"
cf_purge_out=$(
    CLOUDFLARE_RESOURCES_TOUCHED=1
    CLOUDFLARE_API_TOKEN=dummy
    CLOUDFLARE_ZONE_ID="zone-1"
    CLOUDFLARE_STRICT_RULESET_ID="ruleset-1"
    CLOUDFLARE_STRICT_TLS_TOUCHED=1
    CLOUDFLARE_ORIGIN_CERT_ID="cert-1"
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID="cert-1"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    stop_protocol_services() { :; }
    cloudflare_remove_origin_firewall_rules() { :; }
    restore_platform_security_state() { return 0; }
    restore_preinstall_firewall() { :; }
    restore_preinstall_ipv6() { :; }
    restore_preinstall_nginx_default_site() { return 0; }
    restore_preinstall_crontab() { :; }
    install_progress_clear() { :; }
    reality_cloudflare_purge_managed_resources() { printf 'PURGE %s\n' "$*" >>"${cf_purge_log}"; }
    cloudflare_api_request() { printf '%s %s\n' "$1" "$2" >>"${cf_purge_log}"; }
    rollback_fresh_install
) >/dev/null 2>&1
cf_purge_log_content=""
[[ ! -f "${cf_purge_log}" ]] || cf_purge_log_content=$(<"${cf_purge_log}")
assert_equal "rollback: 本次改过云端时只跑全量 purge" \
    'PURGE sub.example.com zone-1 ruleset-1 cert-1' "${cf_purge_log_content}"

# 首装分支同样只能把「本次写过的」ruleset id 交给 purge：没写过 Strict TLS 时（例如证书签发就失败）
# 带着一个旧/无效 id 去 GET 会 404/403 中断，反而把 A 记录留着。
cf_purge_log2="${TMP_DIR}/cf-purge-log-no-strict"
(
    CLOUDFLARE_RESOURCES_TOUCHED=1
    CLOUDFLARE_API_TOKEN=dummy
    CLOUDFLARE_ZONE_ID="zone-1"
    CLOUDFLARE_STRICT_RULESET_ID="ruleset-unknown"
    unset CLOUDFLARE_STRICT_TLS_TOUCHED
    CLOUDFLARE_ORIGIN_CERT_ID=""
    SUBSCRIPTION_DOMAIN="sub.example.com"
    stop_protocol_services() { :; }
    cloudflare_remove_origin_firewall_rules() { :; }
    restore_platform_security_state() { return 0; }
    restore_preinstall_firewall() { :; }
    restore_preinstall_ipv6() { :; }
    restore_preinstall_nginx_default_site() { return 0; }
    restore_preinstall_crontab() { :; }
    install_progress_clear() { :; }
    reality_cloudflare_purge_managed_resources() {
        printf 'PURGE %s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" >>"${cf_purge_log2}"
    }
    cloudflare_api_request() { printf '%s %s\n' "$1" "$2" >>"${cf_purge_log2}"; }
    rollback_fresh_install
) >/dev/null 2>&1
cf_purge_log2_content=""
[[ ! -f "${cf_purge_log2}" ]] || cf_purge_log2_content=$(<"${cf_purge_log2}")
assert_equal "rollback: 首装未写过 Strict TLS 时不带 ruleset id" \
    'PURGE sub.example.com|zone-1||' "${cf_purge_log2_content}"

# 订阅更新回滚（renew-cert / edit-sub 失败）必须吊销本进程新签的证书；若回滚恢复的域名不同，
# 本次为新域名写过的 DNS 记录/Strict TLS 规则也不被任何状态引用，必须一并清理（第 5 个参数
# delete_dns 表示是否真的写过回源 A 记录）。
cf_update_rollback() {
    local log=$1 created=${2:-} failed_domain=${3:-} restored_mode=${4:-deploy} restored_domain=${5:-}
    local strict_touched=${6:-1} dns_touched=${7:-0} purge_mode=${8:-ok}
    (
        if [[ -n "${created}" ]]; then
            CLOUDFLARE_CREATED_ORIGIN_CERT_ID=${created}
        else
            unset CLOUDFLARE_CREATED_ORIGIN_CERT_ID
        fi
        unset CLOUDFLARE_RESOURCES_TOUCHED CLOUDFLARE_STRICT_TLS_TOUCHED
        [[ "${dns_touched}" != "1" ]] || CLOUDFLARE_RESOURCES_TOUCHED=1
        [[ "${strict_touched}" != "1" ]] || CLOUDFLARE_STRICT_TLS_TOUCHED=1
        CLOUDFLARE_ZONE_ID="zone-1"
        CLOUDFLARE_STRICT_RULESET_ID="ruleset-old-zone"
        SUBSCRIPTION_DOMAIN="${failed_domain}"
        UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/cf-update-backup"
        install -d -m 0700 "${UPDATE_SUB_BACKUP_DIR}"
        restore_state_file() { :; }
        source_state_file() {
            SUBSCRIPTION_MODE="${restored_mode}"
            SUBSCRIPTION_DOMAIN="${restored_domain}"
        }
        restore_dynamic_port_rotation_schedule() { return 0; }
        configure_ufw() { :; }
        reality_cloudflare_purge_managed_resources() {
            [[ "${purge_mode}" != "fail" ]] || die "注入的回滚清理失败"
            printf 'PURGE %s|%s|%s|%s|%s\n' "$1" "$2" "$3" "${4:-}" "${5:-}" >>"${log}"
        }
        cloudflare_api_request() { printf '%s %s\n' "$1" "$2" >>"${log}"; }
        rollback_subscription_update
    ) >"${log}.out" 2>&1
}

cf_update_log() {
    local path=$1
    [[ ! -f "${path}" ]] || cat "${path}"
}

# 同域名：只吊销本次新签的证书，DNS/规则仍是当前配置，不能删。
cf_log_a="${TMP_DIR}/cf-update-rollback-a"
cf_update_rollback "${cf_log_a}" "cert-new" "sub.example.com" "deploy" "sub.example.com"
assert_equal "rollback: 订阅更新失败时只吊销本进程新签的证书" \
    'DELETE /certificates/cert-new' "$(cf_update_log "${cf_log_a}")"

# 没有任何云端写入（例如部署前就失败）：不得发任何请求。
cf_log_b="${TMP_DIR}/cf-update-rollback-b"
cf_update_rollback "${cf_log_b}" "" "sub.example.com" "deploy" "sub.example.com" 0
[[ ! -f "${cf_log_b}" ]] \
    || fail_test "rollback: 未新签证书时订阅更新回滚不得发 Cloudflare 请求"

# 只改过回源记录（VPS IP 变化后 PATCH），域名没变：同样不得 purge，否则会删掉回滚后仍要用的记录。
cf_log_c="${TMP_DIR}/cf-update-rollback-c"
cf_update_rollback "${cf_log_c}" "" "sub.example.com" "deploy" "sub.example.com" 0 1
[[ ! -f "${cf_log_c}" ]] \
    || fail_test "rollback: 同域名只 PATCH 过 DNS 时不得 purge"

# link → deploy 中途失败：回滚后没有订阅域名，新域名的 Strict TLS 规则必须清掉；本次没写过
# 回源记录（delete_dns=0），所以跳过 DNS 段。
cf_log_d="${TMP_DIR}/cf-update-rollback-d"
cf_update_rollback "${cf_log_d}" "cert-new" "new.example.com" "link" ""
assert_equal "rollback: link→deploy 失败时只按 ruleset 清理规则（未写过 DNS）" \
    "$(printf '%s\n' 'DELETE /certificates/cert-new' 'PURGE new.example.com|zone-1|ruleset-old-zone||0')" \
    "$(cf_update_log "${cf_log_d}")"

# deploy 改域名后失败：恢复的是旧域名，本次为新域名写的资源不被任何状态引用。
cf_log_e="${TMP_DIR}/cf-update-rollback-e"
cf_update_rollback "${cf_log_e}" "cert-new" "new.example.com" "deploy" "old.example.com"
assert_equal "rollback: 改域名失败时清理新域名的 Strict TLS 规则" \
    "$(printf '%s\n' 'DELETE /certificates/cert-new' 'PURGE new.example.com|zone-1|ruleset-old-zone||0')" \
    "$(cf_update_log "${cf_log_e}")"

# 证书复用（未新签）但 DNS 被 PATCH 过，且域名发生变化：仍然要清掉新域名的资源（delete_dns=1）。
cf_log_f="${TMP_DIR}/cf-update-rollback-f"
cf_update_rollback "${cf_log_f}" "" "new.example.com" "deploy" "old.example.com" 1 1
assert_equal "rollback: 只改过 DNS 时也要清理新域名资源" \
    'PURGE new.example.com|zone-1|ruleset-old-zone||1' "$(cf_update_log "${cf_log_f}")"

# 本次没跑 Strict TLS（例如证书签发就失败）：不得把（跨 Zone 时已过期的）ruleset id 交给 purge。
# 且本次只写过 Strict TLS、没写过回源记录时 delete_dns=0，DNS 段整个跳过。
cf_log_g="${TMP_DIR}/cf-update-rollback-g"
cf_update_rollback "${cf_log_g}" "" "new.example.com" "deploy" "old.example.com" 1 0
assert_equal "rollback: 只写过 Strict TLS 时只按 ruleset 清规则、不发 DNS 请求" \
    'PURGE new.example.com|zone-1|ruleset-old-zone||0' "$(cf_update_log "${cf_log_g}")"

# 只新签了证书（本次没写 DNS、也没写 Strict TLS）而换了域名：不得 purge。新域名的回源记录在
# 更新前就存在，ensure_proxied_a 因此 no-op；按「新签证书」触发 purge 会删掉这条既有记录。
cf_log_g2="${TMP_DIR}/cf-update-rollback-g2"
cf_update_rollback "${cf_log_g2}" "cert-new" "new.example.com" "deploy" "old.example.com" 0 0
assert_equal "rollback: 只新签证书时只吊销证书、不跑 purge" \
    'DELETE /certificates/cert-new' "$(cf_update_log "${cf_log_g2}")"

# 云端清理失败只能 warn，不能中断回滚（否则恢复 UFW/状态的后续步骤全被跳过）。
cf_log_h="${TMP_DIR}/cf-update-rollback-h"
cf_update_rollback "${cf_log_h}" "cert-new" "new.example.com" "deploy" "old.example.com" 1 0 fail \
    || true
assert_contains "rollback: 清理失败只告警并给出补救命令" \
    "$(<"${cf_log_h}.out")" "回滚未能清理本次为 new.example.com 新建的 Cloudflare 资源"
assert_contains "rollback: 清理失败的告警指向 purge-cloudflare" \
    "$(<"${cf_log_h}.out")" "purge-cloudflare --domain"

# 上面几个用例把 purge 桩掉了，只能证明参数；这里用真实的
# reality_cloudflare_purge_managed_resources（只桩 API）跑一遍回滚，锁住「到底有没有发 DNS 请求」：
# 新域名的回源记录在更新前就存在（comment 带 easy_all 标记），ensure_proxied_a 因此 no-op。
cf_update_rollback_real() {
    local log=$1 created=${2:-} dns_touched=${3:-0} strict_touched=${4:-0}
    local strict_rule_ref
    # ruleset 里预置本次新域名（固定为 new.example.com）的受管规则，让真实 purge 走到 DELETE 分支。
    strict_rule_ref=$(reality_cloudflare_ref "reality-strict:new.example.com")
    (
        if [[ -n "${created}" ]]; then
            CLOUDFLARE_CREATED_ORIGIN_CERT_ID=${created}
        else
            unset CLOUDFLARE_CREATED_ORIGIN_CERT_ID
        fi
        unset CLOUDFLARE_RESOURCES_TOUCHED CLOUDFLARE_STRICT_TLS_TOUCHED
        [[ "${dns_touched}" != "1" ]] || CLOUDFLARE_RESOURCES_TOUCHED=1
        [[ "${strict_touched}" != "1" ]] || CLOUDFLARE_STRICT_TLS_TOUCHED=1
        CLOUDFLARE_ZONE_ID="zone-1"
        CLOUDFLARE_STRICT_RULESET_ID="ruleset-old-zone"
        SUBSCRIPTION_DOMAIN="new.example.com"
        UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/cf-update-backup-real"
        install -d -m 0700 "${UPDATE_SUB_BACKUP_DIR}"
        restore_state_file() { :; }
        source_state_file() { SUBSCRIPTION_MODE=deploy; SUBSCRIPTION_DOMAIN="old.example.com"; }
        restore_dynamic_port_rotation_schedule() { return 0; }
        configure_ufw() { :; }
        cloudflare_collect_api_token() { :; }
        cloudflare_api_request() {
            printf '%s %s\n' "$1" "$2" >>"${log}"
            [[ "$1" == GET ]] || return 0
            if [[ "$2" == "/zones/zone-1/rulesets/ruleset-old-zone" ]]; then
                jq -cn --arg ref "${strict_rule_ref}" '{rules:[{id:"rule-1",ref:$ref}]}'
            else
                jq -cn '[{id:"record-existing",comment:"easy_all reality subscription origin"}]'
            fi
        }
        rollback_subscription_update
    ) >"${log}.out" 2>&1
}

# 只新签了证书：除吊销证书外不得发任何请求，否则会删掉更新前就存在的 A 记录。
cf_real_a="${TMP_DIR}/cf-update-rollback-real-a"
cf_update_rollback_real "${cf_real_a}" "cert-new" 0
assert_equal "rollback: 只新签证书时真实 purge 不发 DNS 请求" \
    'DELETE /certificates/cert-new' "$(cf_update_log "${cf_real_a}")"

# 本次 PATCH 过 DNS：新域名的记录是本次写的，真实 purge 要能删掉它。
cf_real_b="${TMP_DIR}/cf-update-rollback-real-b"
cf_update_rollback_real "${cf_real_b}" "" 1
assert_equal "rollback: 本次 PATCH 过 DNS 时真实 purge 删掉新域名的 A 记录" \
    "$(printf '%s\n' \
        'GET /zones/zone-1/dns_records?type=A&name=new.example.com&per_page=100' \
        'DELETE /zones/zone-1/dns_records/record-existing')" \
    "$(cf_update_log "${cf_real_b}")"

# 本次只写过 Strict TLS：真实 purge 按 ruleset 里匹配 ref 的规则发 DELETE，DNS 段（含只读 GET）
# 整个跳过。
cf_real_c="${TMP_DIR}/cf-update-rollback-real-c"
cf_update_rollback_real "${cf_real_c}" "" 0 1
assert_equal "rollback: 真实 purge 在 delete_dns=0 时只发规则 DELETE、不发 DNS 请求" \
    "$(printf '%s\n' \
        'GET /zones/zone-1/rulesets/ruleset-old-zone' \
        'DELETE /zones/zone-1/rulesets/ruleset-old-zone/rules/rule-1')" \
    "$(cf_update_log "${cf_real_c}")"

# 证书可复用判定必须与 OpenSSL 版本无关：macOS 的 LibreSSL 既没有 -ext 也没有 -checkhost，
# 任何一处早退都会把有效证书判成不可复用并在开发机上反复重签。这里用真实证书验证 SAN 集合比对。
cf_cert_rc=0
(
    install -d -m 0700 "${CERT_DIR}"
    openssl ecparam -name prime256v1 -genkey -noout -out "${KEY_FILE}" 2>/dev/null
    openssl req -new -x509 -sha256 -key "${KEY_FILE}" -days 3650 -subj "/CN=sub.example.com" \
        -addext "subjectAltName=DNS:sub.example.com" -out "${CERT_FILE}" 2>/dev/null
    CLOUDFLARE_ORIGIN_DOMAIN="sub.example.com"
    cloudflare_origin_certificate_is_current
) || cf_cert_rc=$?
assert_equal "cert: 有效证书判为可复用（跨 OpenSSL 版本）" "0" "${cf_cert_rc}"

cf_cert_other_rc=0
(
    install -d -m 0700 "${CERT_DIR}"
    openssl ecparam -name prime256v1 -genkey -noout -out "${KEY_FILE}" 2>/dev/null
    openssl req -new -x509 -sha256 -key "${KEY_FILE}" -days 3650 -subj "/CN=other.example.com" \
        -addext "subjectAltName=DNS:other.example.com" -out "${CERT_FILE}" 2>/dev/null
    CLOUDFLARE_ORIGIN_DOMAIN="sub.example.com"
    cloudflare_origin_certificate_is_current
) || cf_cert_other_rc=$?
assert_equal "cert: 域名不匹配的证书判为不可复用" "1" "${cf_cert_other_rc}"

# CI（OpenSSL 3）上 -ext 永远成功，awk 兜底分支走不到；用桩把 -ext 变成 unknown option，
# 强制走 LibreSSL 路径，锁住 -text 解析逻辑（否则该分支只有 macOS 开发者才会碰到问题）。
cf_cert_fallback_rc=0
(
    install -d -m 0700 "${CERT_DIR}"
    openssl ecparam -name prime256v1 -genkey -noout -out "${KEY_FILE}" 2>/dev/null
    openssl req -new -x509 -sha256 -key "${KEY_FILE}" -days 3650 -subj "/CN=sub.example.com" \
        -addext "subjectAltName=DNS:sub.example.com" -out "${CERT_FILE}" 2>/dev/null
    openssl() {
        if [[ "$*" == *-ext* ]]; then
            printf 'x509: unknown option -ext\n' >&2
            return 1
        fi
        command openssl "$@"
    }
    CLOUDFLARE_ORIGIN_DOMAIN="sub.example.com"
    cloudflare_origin_certificate_is_current
) || cf_cert_fallback_rc=$?
assert_equal "cert: 无 -ext 时退回解析 -text（LibreSSL 路径）" "0" "${cf_cert_fallback_rc}"

# Zone 解析结果按域名缓存：输入阶段解析过后，部署阶段不再重复两次只读 GET；换域名则必须重解析。
cf_zone_calls="${TMP_DIR}/cf-zone-calls"
cf_zone_cache=$(
    rm -f "${cf_zone_calls}"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    cloudflare_find_parent_zone() { printf 'x' >>"${cf_zone_calls}"; printf 'zone-1'; }
    cloudflare_api_request() { printf '{"id":"zone-1","name":"example.com"}'; }
    reality_cloudflare_resolve_zone
    reality_cloudflare_resolve_zone
    printf '%s|%s|%s' "$(wc -c <"${cf_zone_calls}" | tr -d ' ')" \
        "${CLOUDFLARE_ZONE_ID}" "${CLOUDFLARE_ZONE_NAME}"
)
assert_equal "resolve_zone: 同域名复用解析结果" "1|zone-1|example.com" "${cf_zone_cache}"

cf_zone_switch=$(
    rm -f "${cf_zone_calls}"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    cloudflare_find_parent_zone() { printf 'x' >>"${cf_zone_calls}"; printf 'zone-1'; }
    cloudflare_api_request() { printf '{"id":"zone-1","name":"example.com"}'; }
    reality_cloudflare_resolve_zone
    SUBSCRIPTION_DOMAIN="other.example.com"
    reality_cloudflare_resolve_zone
    wc -c <"${cf_zone_calls}" | tr -d ' '
)
assert_equal "resolve_zone: 换域名重新解析" "2" "${cf_zone_switch}"

# 吊销成功必须清空新证书 ID；失败则保留（留给 purge-cloudflare / 人工跟进）。
cf_cert_cleared=$(
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID="cert-new"
    CLOUDFLARE_ZONE_ID="zone-1"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/cf-update-backup"
    install -d -m 0700 "${UPDATE_SUB_BACKUP_DIR}"
    restore_state_file() { :; }
    source_state_file() { SUBSCRIPTION_MODE=deploy; SUBSCRIPTION_DOMAIN="sub.example.com"; }
    restore_dynamic_port_rotation_schedule() { return 0; }
    configure_ufw() { :; }
    cloudflare_api_request() { :; }
    rollback_subscription_update >/dev/null 2>&1
    if [[ -z "${CLOUDFLARE_CREATED_ORIGIN_CERT_ID:-}" ]]; then
        printf 'cleared'
    else
        printf 'kept:%s' "${CLOUDFLARE_CREATED_ORIGIN_CERT_ID}"
    fi
)
assert_equal "rollback: 吊销成功后清空新证书 ID" "cleared" "${cf_cert_cleared}"

cf_cert_kept=$(
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID="cert-new"
    CLOUDFLARE_ZONE_ID="zone-1"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/cf-update-backup"
    install -d -m 0700 "${UPDATE_SUB_BACKUP_DIR}"
    restore_state_file() { :; }
    source_state_file() { SUBSCRIPTION_MODE=deploy; SUBSCRIPTION_DOMAIN="sub.example.com"; }
    restore_dynamic_port_rotation_schedule() { return 0; }
    configure_ufw() { :; }
    cloudflare_api_request() { return 1; }
    rollback_subscription_update >/dev/null 2>&1
    printf '%s' "${CLOUDFLARE_CREATED_ORIGIN_CERT_ID:-}"
)
assert_equal "rollback: 吊销失败时保留新证书 ID" "cert-new" "${cf_cert_kept}"

########################################################################
# A12 / A13 / A14 / A15：Reality 订阅事务、动态端口刷新与保留本机名
#
# 所有用例都在真实新进程里跑 set -Eeuo pipefail + 真实 Profile：只有外部边界
# （crontab / systemctl / nginx / ufw / iptables-restore / Xray 二进制 / 公网探测 /
# Cloudflare API）可桩；状态保存、订阅渲染、事务与回滚走真实实现，退出码由父测试获取。
########################################################################

export TMP_DIR PROFILE
CRONTAB_STORE="${TMP_DIR}/child-crontab"
CRONTAB_FAIL="${TMP_DIR}/child-crontab-fail"
SYSTEMCTL_LOG="${TMP_DIR}/child-systemctl.log"
UFW_LOG="${TMP_DIR}/child-ufw.log"
PACKAGE_LOG="${TMP_DIR}/child-package.log"
CLOUDFLARE_LOG="${TMP_DIR}/child-cloudflare.log"
REALITY_CHILD_ENV="${TMP_DIR}/reality-child-env.sh"
A13_T2_TEMPLATE="${ROOT_DIR}/templates/mihomo.yaml"
export CRONTAB_STORE CRONTAB_FAIL SYSTEMCTL_LOG UFW_LOG PACKAGE_LOG CLOUDFLARE_LOG \
    A13_T2_TEMPLATE

cat >"${REALITY_CHILD_ENV}" <<'CHILD'
#!/usr/bin/env bash
# 子进程夹具：只桩外部边界，业务保存/渲染/事务/回滚全部走真实实现。
set -Eeuo pipefail
readonly() {
    local arg name val
    for arg in "$@"; do
        [[ "${arg}" == -* ]] && continue
        if [[ "${arg}" == *=* ]]; then
            name=${arg%%=*}
            val=${arg#*=}
            if [[ -z "${!name+x}" ]]; then
                printf -v "${name}" '%s' "${val}"
            fi
        fi
    done
}
install() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o | -g) shift 2 ;;
        *) args+=("$1"); shift ;;
        esac
    done
    command install "${args[@]}"
}
chown() { :; }
flock() { :; }
nginx() { :; }
ss() { printf 'LISTEN 0 4096 0.0.0.0:443 0.0.0.0:*\n'; }
timeout() { shift; "$@"; }
iptables-restore() { :; }
ip6tables-restore() { :; }
systemctl() { printf 'systemctl %s\n' "$*" >>"${SYSTEMCTL_LOG}"; }
ufw() { printf 'ufw %s\n' "$*" >>"${UFW_LOG}"; }
apt-get() { printf 'apt-get %s\n' "$*" >>"${PACKAGE_LOG}"; }
swapon() { printf 'swapon %s\n' "$*" >>"${PACKAGE_LOG}"; }
fallocate() { printf 'fallocate %s\n' "$*" >>"${PACKAGE_LOG}"; }
sysctl() { printf 'sysctl %s\n' "$*" >>"${PACKAGE_LOG}"; }
crontab() {
    case "${1:-}" in
    -l)
        if [[ -f "${CRONTAB_FAIL}" ]]; then
            printf 'crontab: cannot open %s\n' "${CRONTAB_STORE}" >&2
            return 1
        fi
        if [[ ! -f "${CRONTAB_STORE}" ]]; then
            printf 'no crontab for root\n' >&2
            return 1
        fi
        cat "${CRONTAB_STORE}"
        ;;
    -) cat >"${CRONTAB_STORE}" ;;
    -r) rm -f "${CRONTAB_STORE}" ;;
    *) cat "${1}" >"${CRONTAB_STORE}" ;;
    esac
}
detect_public_ipv4() { return 1; }
cloudflare_api_request() {
    printf 'cloudflare %s %s\n' "${1:-}" "${2:-}" >>"${CLOUDFLARE_LOG}"
    return 1
}
# 系统版本探测是可覆盖的输入文件：预检通过后的控制组用“无法识别系统版本”停在第一层，
# 不触碰 Swap / APT / 内核。
export EASY_ALL_OS_RELEASE_FILE="${TMP_DIR}/no-such-os-release"
source "${PROFILE}"
unset -f readonly
require_root() { :; }
require_systemd() { :; }
detect_ssh_ports() { SSH_PORTS="${TEST_SSH_PORT:-22}"; }
# Xray 二进制是网络/内核边界：桩掉真实 TLS 探测，但仍用 jq 校验写入的配置可解析。
# 隔离 PATH（没有 jq/install 之外的工具）的场景设 REALITY_CHILD_NO_XRAY=1 跳过。
if [[ "${REALITY_CHILD_NO_XRAY:-0}" != "1" ]]; then
install -d -m 0755 "${XRAY_DIR}"
cat >"${XRAY_BIN}" <<'XRAY'
#!/usr/bin/env bash
case "${1:-}" in
x25519)
    if [[ "${2:-}" == "-i" ]]; then
        printf 'Password: pubkey-test\n'
    else
        printf 'PrivateKey: privkey-test\nPassword: pubkey-test\n'
    fi
    ;;
run)
    jq -e . "${4:-}" >/dev/null
    ;;
tls)
    printf 'Pinging with SNI: %s\n' "${3:-}"
    printf 'Handshake succeeded\n'
    printf 'TLS Version: TLS 1.3\n'
    ;;
*)
    exit 1
    ;;
esac
XRAY
chmod 0755 "${XRAY_BIN}"
fi
# ufw 应用是外部边界；本文件里的 NAT 规则写入（write_ufw_nat_rules）仍走真实实现。
configure_ufw() { printf 'configure_ufw\n' >>"${UFW_LOG}"; }

reality_fixture_state() {
    local target=$1 mode=$2 port_mode=$3 node_name=${4:-MY_REALITY}
    {
        printf "STATE_VERSION='0'\n"
        printf "PROTOCOL='reality'\n"
        printf "TCP_ACCELERATION='skyline'\n"
        printf "NODE_NAME='%s'\n" "${node_name}"
        printf "NODE_HOST='198.51.100.10'\n"
        printf "VLESS_UUID='11111111-2222-4111-8111-111111111111'\n"
        printf "REALITY_TARGET='%s'\n" "${target}"
        printf "REALITY_PRIVATE_KEY='test-private-key'\n"
        printf "REALITY_PUBLIC_KEY='test-public-key'\n"
        printf "REALITY_SHORT_ID='0123456789abcdef'\n"
        printf "VPS_IP_FAMILY='ipv4'\n"
        printf "VPS_PUBLIC_IPV6=''\n"
        printf "GOOGLE_EGRESS_MODE='ipv4'\n"
        printf "GOOGLE_EGRESS_RESOLVED='ipv4'\n"
        printf "SUB_PORT_MODE='%s'\n" "${port_mode}"
        printf "ALLOWED_TOKENS='{\"owner\":\"token-init-12345\"}'\n"
        printf "SUBSCRIPTION_CONFIG='{\"allowedTokens\":{\"owner\":\"token-init-12345\"},\"nodes\":[]}'\n"
        printf "MIHOMO_TEMPLATE_SNAPSHOT='1'\n"
        printf "SUBSCRIPTION_MODE='%s'\n" "${mode}"
        printf "SUB_DOWNLOAD_NAME='EASYALL'\n"
        if [[ "${mode}" != "link" ]]; then
            printf "SUBSCRIPTION_DOMAIN='sub.example.com'\n"
            printf "CLOUDFLARE_ZONE_ID='zone-1'\n"
            printf "CLOUDFLARE_ZONE_NAME='example.com'\n"
            printf "CLOUDFLARE_ORIGIN_CERT_ID='cert-1'\n"
            printf "CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON='2041-11-03 00:00:00 +0000 UTC'\n"
            printf "CLOUDFLARE_STRICT_RULESET_ID='ruleset-1'\n"
        fi
        printf "SCHEDULED_REBOOT_ENABLED='0'\n"
        printf "SCHEDULED_REBOOT_HOUR=''\n"
    } >"${STATE_FILE}"
}
CHILD

reality_file_hash() {
    openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}'
}

reality_hash_tree() {
    local out=$1 file
    : >"${out}"
    for file in "${STATE_FILE}" "${XRAY_CONFIG}" "${NGINX_CONFIG}" \
        "${REALITY_SUBSCRIPTION_JS}" "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" \
        "${SUBSCRIPTION_BASE64_FILE}" "${SUBSCRIPTION_MIHOMO_FILE}" \
        "${SUBSCRIPTION_MIHOMO_IOS_FILE}" "${SUBSCRIPTION_BASE64_ALL_FILE}" \
        "${SUBSCRIPTION_MIHOMO_ALL_FILE}" "${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE}" \
        "${UFW_BEFORE_RULES}"; do
        if [[ -f "${file}" ]]; then
            printf '%s %s\n' "$(reality_file_hash "${file}")" "${file##*/}" >>"${out}"
        else
            printf 'missing %s\n' "${file##*/}" >>"${out}"
        fi
    done
}

reality_scenario_file() {
    local name=$1
    {
        printf 'set -Eeuo pipefail\n'
        printf 'source "%s"\n' "${REALITY_CHILD_ENV}"
        cat
    } >"${TMP_DIR}/scenario-${name}.sh"
}

reality_run_scenario() {
    local name=$1 rc=0
    REALITY_SCENARIO_OUT="${TMP_DIR}/scenario-${name}.out"
    bash "${TMP_DIR}/scenario-${name}.sh" >"${REALITY_SCENARIO_OUT}" 2>&1 || rc=$?
    REALITY_SCENARIO_RC=${rc}
}

reality_fixture_reset() {
    local target=${1:-swdist.apple.com:443} mode=${2:-deploy} port_mode=${3:-443}
    local node_name=${4:-MY_REALITY}
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${XRAY_DIR}" "${RUNTIME_TMP}" \
        "${NGINX_CONFIG}" "${REALITY_SUBSCRIPTION_JS}" "${TMP_DIR}/ufw" \
        "${CRONTAB_STORE}" "${CRONTAB_FAIL}" "${SYSTEMCTL_LOG}" "${UFW_LOG}" \
        "${PACKAGE_LOG}" "${CLOUDFLARE_LOG}" "${RUNTIME_WRITE_LOCK_FILE_OVERRIDE}"
    install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}" "${XRAY_DIR}" "${CERT_DIR}"
    install -d -m 0755 "${WEB_ROOT}" "${SUBSCRIPTION_DIR}" "${RUNTIME_TMP}" "${TMP_DIR}/ufw"
    : >"${CERT_FILE}"
    : >"${KEY_FILE}"
    printf '26.9.8\n' >"${XRAY_DIR}/version"
    printf '{"oldTarget":"%s"}\n' "${target}" >"${XRAY_CONFIG}"
    printf 'server { listen 8443 ssl; # 旧订阅配置 }\n' >"${NGINX_CONFIG}"
    printf '// 旧渲染脚本\n' >"${REALITY_SUBSCRIPTION_JS}"
    printf '*filter\n:PREROUTING ACCEPT [0:0]\nCOMMIT\n' >"${UFW_BEFORE_RULES}"
    {
        printf '0 4 * * * /usr/local/bin/easy_all cdn-traffic-sync # 管理员任务\n'
        printf '@reboot "/usr/local/bin/easy_all" rotate-dynamic-ports >/dev/null 2>&1 %s\n' \
            "${CRON_DYNAMIC_PORT_MARKER}"
    } >"${CRONTAB_STORE}"
    export FIXTURE_TARGET=${target} FIXTURE_MODE=${mode} \
        FIXTURE_PORT_MODE=${port_mode} FIXTURE_NODE_NAME=${node_name}
    if [[ "${mode}" == "deploy" ]]; then
        reality_scenario_file fixture <<'EOF'
reality_fixture_state "${FIXTURE_TARGET}" "${FIXTURE_MODE}" "${FIXTURE_PORT_MODE}" \
    "${FIXTURE_NODE_NAME}"
load_state --reload
install_static_subscriptions
save_state
EOF
    else
        reality_scenario_file fixture <<'EOF'
reality_fixture_state "${FIXTURE_TARGET}" "${FIXTURE_MODE}" "${FIXTURE_PORT_MODE}" \
    "${FIXTURE_NODE_NAME}"
load_state --reload
save_state
EOF
    fi
    reality_run_scenario fixture
    [[ "${REALITY_SCENARIO_RC}" == "0" ]] \
        || fail_test "fixture: 初始状态准备失败（rc=${REALITY_SCENARIO_RC}）：$(<"${REALITY_SCENARIO_OUT}")"
}

# ---- A12：update_reality_target 全程 armed 的事务 ----
reality_fixture_reset
reality_scenario_file a12-success <<'EOF'
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a12-success
assert_equal "A12: 新 target 事务成功退出" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A12: 成功信息只在提交之后" "$(<"${REALITY_SCENARIO_OUT}")" "Reality 目标已更新"
assert_contains "A12: state 落盘新 target" "$(<"${STATE_FILE}")" "REALITY_TARGET=www.example.org:443"
assert_contains "A12: Xray 运行时使用新 SNI" "$(<"${XRAY_CONFIG}")" '"target": "www.example.org:443"'
assert_contains "A12: Mihomo 产物使用新 SNI" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" 'servername: "www.example.org"'
assert_contains "A12: base64 产物使用新 SNI" \
    "$(decode_base64 "${SUBSCRIPTION_BASE64_FILE}")" "sni=www.example.org"
assert_equal "A12: 发布继续走 install_static_subscriptions（不重装渲染脚本）" "1" \
    "$(grep -c '旧渲染脚本' "${REALITY_SUBSCRIPTION_JS}" || true)"
[[ ! -e "${CLOUDFLARE_LOG}" ]] || fail_test "A12: target 修改不得访问 Cloudflare API"
assert_contains "A12: 运行时被重启" "$(<"${SYSTEMCTL_LOG}")" \
    "systemctl restart easy_all-xray.service"

reality_fixture_reset
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a12-save1 <<'EOF'
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function save_state real_save_state
save_state_calls=0
save_state() {
    save_state_calls=$((save_state_calls + 1))
    [[ "${save_state_calls}" != "1" ]] || return 1
    real_save_state
}
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a12-save1
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A12: 第一次保存失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_not_contains "A12: 第一次保存失败不得报成功" "$(<"${REALITY_SCENARIO_OUT}")" "Reality 目标已更新"
assert_equal "A12: 第一次保存失败后 state/Xray/六产物/模板回旧代" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"

reality_fixture_reset
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a12-save2 <<'EOF'
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function save_state real_save_state
save_state_calls=0
save_state() {
    save_state_calls=$((save_state_calls + 1))
    [[ "${save_state_calls}" != "2" ]] || return 1
    real_save_state
}
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a12-save2
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A12: 第二次保存失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_not_contains "A12: 第二次保存失败不得报成功" "$(<"${REALITY_SCENARIO_OUT}")" "Reality 目标已更新"
assert_equal "A12: 第二次保存失败后 state/Xray/六产物/模板回旧代" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
assert_contains "A12: 回滚保留受管动态端口行" "$(<"${CRONTAB_STORE}")" \
    "${CRON_DYNAMIC_PORT_MARKER}"
assert_contains "A12: 回滚保留管理员 crontab" "$(<"${CRONTAB_STORE}")" "cdn-traffic-sync # 管理员任务"
# 后续 apply 不得再下发新 SNI：独立进程按恢复后的 state 重新发布。
reality_scenario_file a12-republish <<'EOF'
collect_installed_state
install_static_subscriptions
EOF
reality_run_scenario a12-republish
assert_equal "A12: 回滚后独立进程重新发布成功" "0" "${REALITY_SCENARIO_RC}"
assert_not_contains "A12: 回滚后 base64 不再下发新 SNI" \
    "$(decode_base64 "${SUBSCRIPTION_BASE64_FILE}")" "www.example.org"
assert_not_contains "A12: 回滚后 Mihomo 不再下发新 SNI" \
    "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" "www.example.org"

reality_fixture_reset
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a12-publish <<'EOF'
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function publish_subscription_files real_publish_subscription_files
publish_calls=0
publish_subscription_files() {
    publish_calls=$((publish_calls + 1))
    [[ "${publish_calls}" != "1" ]] || return 1
    real_publish_subscription_files "$@"
}
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a12-publish
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A12: 发布中途失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_not_contains "A12: 发布中途失败不得报成功" "$(<"${REALITY_SCENARIO_OUT}")" "Reality 目标已更新"
assert_equal "A12: 发布中途失败后 state/Xray/六产物/模板回旧代" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"

reality_fixture_reset "swdist.apple.com:443" link 443
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a12-link <<'EOF'
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function save_state real_save_state
save_state_calls=0
save_state() {
    save_state_calls=$((save_state_calls + 1))
    [[ "${save_state_calls}" != "1" ]] || return 1
    real_save_state
}
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a12-link
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A12: link 模式保存失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_equal "A12: link 模式失败后 state/Xray 回旧代" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
assert_contains "A12: link 模式恢复旧 target" "$(<"${STATE_FILE}")" "REALITY_TARGET=swdist.apple.com:443"

reality_fixture_reset
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a12-same <<'EOF'
update_reality_target 'swdist.apple.com:443'
EOF
reality_run_scenario a12-same
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A12: 同 target 无操作退出 0" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A12: 同 target 提示未变化" "$(<"${REALITY_SCENARIO_OUT}")" "目标未变化"
assert_equal "A12: 同 target 不发布、不保存" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
[[ ! -s "${SYSTEMCTL_LOG}" ]] || fail_test "A12: 同 target 不得重启服务"

reality_fixture_reset
: >"${CRONTAB_FAIL}"
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a12-crontab-fail <<'EOF'
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a12-crontab-fail
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A12: crontab 真读取失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_contains "A12: crontab 读取失败点名原因" "$(<"${REALITY_SCENARIO_OUT}")" \
    "读取 root crontab 失败"
assert_equal "A12: crontab 读取失败不得开始任何业务修改" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
[[ ! -s "${SYSTEMCTL_LOG}" ]] || fail_test "A12: crontab 读取失败不得重启服务"
[[ ! -s "${UFW_LOG}" ]] || fail_test "A12: crontab 读取失败不得改动防火墙"
[[ ! -e "${CLOUDFLARE_LOG}" ]] || fail_test "A12: crontab 读取失败不得访问 Cloudflare"
assert_contains "A12: crontab 读取失败保留受管动态端口行" "$(<"${CRONTAB_STORE}")" \
    "${CRON_DYNAMIC_PORT_MARKER}"

reality_fixture_reset
rm -f "${CRONTAB_STORE}"
reality_scenario_file a12-crontab-none <<'EOF'
update_reality_target 'www.example.org:443'
printf 'CRON_BACKUP_BYTES=%s\n' "$(wc -c <"${UPDATE_SUB_BACKUP_DIR}/root.crontab" | tr -d ' ')"
EOF
reality_run_scenario a12-crontab-none
assert_equal "A12: 没有 crontab 时事务仍可完成" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A12: 没有 crontab 时保存空备份" "$(<"${REALITY_SCENARIO_OUT}")" "CRON_BACKUP_BYTES=0"
assert_contains "A12: 没有 crontab 时新 target 生效" "$(<"${STATE_FILE}")" \
    "REALITY_TARGET=www.example.org:443"

# ---- A13：Reality 事务把 Mihomo 模板快照纳入备份集 ----
reality_fixture_reset "swdist.apple.com:443" link 443
reality_hash_tree "${TMP_DIR}/hash-link"
assert_equal "A13: 事务前没有模板快照" "missing mihomo-template.yaml" \
    "$(grep 'mihomo-template' "${TMP_DIR}/hash-link")"
reality_fixture_reset
cp "${ROOT_DIR}/templates/mihomo.yaml" "${TMP_DIR}/template-t1.yaml"
printf '# T1 模板标记\n' >>"${TMP_DIR}/template-t1.yaml"
cp "${TMP_DIR}/template-t1.yaml" "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}"
reality_scenario_file a13-publish-t1 <<'EOF'
collect_installed_state
install_static_subscriptions
EOF
reality_run_scenario a13-publish-t1
assert_equal "A13: T1 模板可发布" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A13: T1 模板进入产物" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" "# T1 模板标记"
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a13-rollback <<'EOF'
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function save_state real_save_state
save_state_calls=0
save_state() {
    save_state_calls=$((save_state_calls + 1))
    [[ "${save_state_calls}" != "2" ]] || return 1
    real_save_state
}
export MIHOMO_TEMPLATE_SOURCE="${A13_T2_TEMPLATE}"
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a13-rollback
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A13: 事务失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_equal "A13: 失败后模板与六产物一起回旧代" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
assert_equal "A13: 回滚恢复 T1 模板内容" \
    "$(reality_file_hash "${TMP_DIR}/template-t1.yaml")" \
    "$(reality_file_hash "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}")"
assert_contains "A13: 模板快照权限 0600" "$(ls -l "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}")" "rw-------"
reality_scenario_file a13-republish <<'EOF'
collect_installed_state
install_static_subscriptions
EOF
reality_run_scenario a13-republish
assert_equal "A13: 回滚后独立进程重新发布成功" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A13: 回滚后发布仍使用 T1 模板" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" "# T1 模板标记"
reality_scenario_file a13-commit <<'EOF'
export MIHOMO_TEMPLATE_SOURCE="${A13_T2_TEMPLATE}"
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a13-commit
assert_equal "A13: 提交 T2 事务成功" "0" "${REALITY_SCENARIO_RC}"
assert_equal "A13: 提交后模板快照是 T2" "$(reality_file_hash "${A13_T2_TEMPLATE}")" \
    "$(reality_file_hash "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}")"
reality_scenario_file a13-reuse <<'EOF'
collect_installed_state
install_static_subscriptions
EOF
reality_run_scenario a13-reuse
assert_equal "A13: 提交后新进程可重新发布" "0" "${REALITY_SCENARIO_RC}"
assert_not_contains "A13: 新进程复用已提交的 T2" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" "# T1 模板标记"

# A13/A12：模板已持久化为 T2、且正常发布与回滚发布都失败时，模板恢复不得被前序失败跳过。
# 订阅目录不可写用 mktemp 在订阅目录内失败来模拟（publish 会先 install -d 把 chmod 改回来，
# 只有真正写候选文件这一步能稳定代表“不可写”），模板快照路径仍保持可写。
reality_fixture_reset
cp "${ROOT_DIR}/templates/mihomo.yaml" "${TMP_DIR}/template-t1.yaml"
printf '# T1 模板标记\n' >>"${TMP_DIR}/template-t1.yaml"
cp "${TMP_DIR}/template-t1.yaml" "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}"
reality_scenario_file a13-t1-baseline <<'EOF'
collect_installed_state
install_static_subscriptions
EOF
reality_run_scenario a13-t1-baseline
assert_equal "A13: 回滚用例的 T1 基线发布成功" "0" "${REALITY_SCENARIO_RC}"
A13_T1_HASH=$(reality_file_hash "${TMP_DIR}/template-t1.yaml")
reality_scenario_file a13-publish-blocked <<'EOF'
mktemp() {
    case "${1:-}" in
    "${SUBSCRIPTION_DIR}"/*) return 1 ;;
    esac
    command mktemp "$@"
}
# 证明失败事务确实把 T2 落过盘：回滚前记录模板 hash，回滚后再由父测试比较。
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function rollback_subscription_update real_rollback_subscription_update
rollback_subscription_update() {
    printf 'PRE_ROLLBACK_TEMPLATE=%s\n' \
        "$(openssl dgst -sha256 "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" 2>/dev/null | awk '{print $NF}')"
    real_rollback_subscription_update
}
export MIHOMO_TEMPLATE_SOURCE="${A13_T2_TEMPLATE}"
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a13-publish-blocked
assert_equal "A13: 发布持续失败时命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_not_contains "A13: 发布持续失败不得报成功" "$(<"${REALITY_SCENARIO_OUT}")" "Reality 目标已更新"
assert_contains "A13: 报告订阅恢复失败" "$(<"${REALITY_SCENARIO_OUT}")" "订阅资产或 Nginx 恢复失败"
assert_equal "A13: 订阅恢复失败时模板仍回到 T1" "${A13_T1_HASH}" \
    "$(reality_file_hash "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}")"
assert_contains "A13: 订阅恢复失败时 state 回到旧 target" "$(<"${STATE_FILE}")" \
    "REALITY_TARGET=swdist.apple.com:443"
assert_equal "A13: 失败事务确实持久化过 T2 模板" "$(reality_file_hash "${A13_T2_TEMPLATE}")" \
    "$(sed -n 's/^PRE_ROLLBACK_TEMPLATE=//p' "${REALITY_SCENARIO_OUT}" | head -n 1)"
# 恢复可写后由新进程重新发布：仍使用回滚后的 T1，不下发失败事务的 target。
reality_scenario_file a13-after-recover <<'EOF'
collect_installed_state
install_static_subscriptions
EOF
reality_run_scenario a13-after-recover
assert_equal "A13: 恢复可写后新进程发布成功" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A13: 新进程仍使用回滚后的 T1" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" "# T1 模板标记"
assert_not_contains "A13: 新进程不下发失败事务的 target" \
    "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" "www.example.org"

# 原先没有模板快照：事务失败后本次新建的快照必须被删除。
reality_fixture_reset
rm -f "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}"
reality_scenario_file a13-missing-blocked <<'EOF'
mktemp() {
    case "${1:-}" in
    "${SUBSCRIPTION_DIR}"/*) return 1 ;;
    esac
    command mktemp "$@"
}
copy_function() { eval "$2() $(declare -f "$1" | tail -n +2)"; }
copy_function rollback_subscription_update real_rollback_subscription_update
rollback_subscription_update() {
    printf 'PRE_ROLLBACK_TEMPLATE=%s\n' \
        "$(openssl dgst -sha256 "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" 2>/dev/null | awk '{print $NF}')"
    real_rollback_subscription_update
}
export MIHOMO_TEMPLATE_SOURCE="${A13_T2_TEMPLATE}"
update_reality_target 'www.example.org:443'
EOF
reality_run_scenario a13-missing-blocked
assert_equal "A13: 无快照时发布失败命令非零" "1" "${REALITY_SCENARIO_RC}"
assert_contains "A13: 无快照时同样报告订阅恢复失败" "$(<"${REALITY_SCENARIO_OUT}")" \
    "订阅资产或 Nginx 恢复失败"
assert_equal "A13: 无快照分支确实新建过 T2 快照" "$(reality_file_hash "${A13_T2_TEMPLATE}")" \
    "$(sed -n 's/^PRE_ROLLBACK_TEMPLATE=//p' "${REALITY_SCENARIO_OUT}" | head -n 1)"
[[ ! -e "${MIHOMO_TEMPLATE_SNAPSHOT_FILE}" ]] \
    || fail_test "A13: 原先无模板快照时，失败后必须删除本次新建的快照"
assert_contains "A13: 无快照分支 state 回到旧 target" "$(<"${STATE_FILE}")" \
    "REALITY_TARGET=swdist.apple.com:443"

# ---- A14：rotate-dynamic-ports 同步刷新 NAT、六产物与 Nginx SSH 快照 ----
reality_fixture_reset "swdist.apple.com:443" deploy dynamic
# 时间必须固定：被排除的 SSH 端口取「当前槽位」——不传排除列表时渲染器恰好会选中它，
# 因此断言只在真的尊重排除列表时才会通过（不再依赖“当时槽位恰好不同”）。
reality_scenario_file a14-rotate <<'EOF'
A14_NOW=$(date +%s)
A14_DAY=$(TZ=Asia/Shanghai date -r "${A14_NOW}" +%j 2>/dev/null \
    || TZ=Asia/Shanghai date -d "@${A14_NOW}" +%j)
A14_HOUR=$(TZ=Asia/Shanghai date -r "${A14_NOW}" +%H 2>/dev/null \
    || TZ=Asia/Shanghai date -d "@${A14_NOW}" +%H)
A14_ROTATION=$(( (10#${A14_DAY} - 1) * 24 + 10#${A14_HOUR} ))
A14_HOUR_BASE=$((PORT_BASE + A14_ROTATION * DYNAMIC_PORTS_PER_HOUR))
A14_SLOT=$((A14_NOW % DYNAMIC_PORTS_PER_HOUR))
TEST_SSH_PORT=$((A14_HOUR_BASE + A14_SLOT))
printf 'SSH_PORT=%s\nNOW_MS=%s\nEXPECTED_PORT=%s\n' \
    "${TEST_SSH_PORT}" "$((A14_NOW * 1000))" \
    "$((A14_HOUR_BASE + (A14_SLOT + 1) % DYNAMIC_PORTS_PER_HOUR))"
rotate_dynamic_ports
EOF
reality_run_scenario a14-rotate
assert_equal "A14: dynamic rotate 成功" "0" "${REALITY_SCENARIO_RC}"
A14_SSH_PORT=$(sed -n 's/^SSH_PORT=//p' "${REALITY_SCENARIO_OUT}" | head -n 1)
[[ "${A14_SSH_PORT}" =~ ^[0-9]+$ ]] || fail_test "A14: 场景未给出 SSH 端口：$(<"${REALITY_SCENARIO_OUT}")"
assert_contains "A14: NAT 为池内 SSH 端口写 RETURN" "$(<"${UFW_BEFORE_RULES}")" \
    "-A PREROUTING -p tcp --dport ${A14_SSH_PORT} -j RETURN"
assert_contains "A14: Nginx 注入新的 SSH 端口快照" "$(<"${NGINX_CONFIG}")" \
    "set \$easy_all_ssh_ports \"${A14_SSH_PORT}\";"
assert_contains "A14: 成功信息" "$(<"${REALITY_SCENARIO_OUT}")" "动态端口 NAT 与订阅快照已刷新"
assert_contains "A14: Nginx 被重载" "$(<"${SYSTEMCTL_LOG}")" "systemctl reload nginx"
# 实际生成的 nginx 变量必须进入既有 Node 渲染器，所有订阅格式都避让该端口。
A14_RENDER_JS="${TMP_DIR}/a14-render.mjs"
cat >"${A14_RENDER_JS}" <<'JS'
// 只固定时钟（测试缝在测试自己的入口里）：渲染器仍用真实 Date.now()，因此冻结时刻与
// bash 侧算出的端口必须一致，断言才不是靠“当时槽位恰好不同”通过。
const frozen = Number(process.env.A14_NOW_MS);
if (Number.isFinite(frozen) && frozen > 0) Date.now = () => frozen;
const { default: subscription } = await import(process.env.REALITY_SUBSCRIPTION_MODULE);
const [kind, file] = process.argv.slice(2);
const result = { code: 0, body: '' };
subscription[kind]({
    method: 'GET',
    variables: {
        easy_all_reality_port_mode: 'dynamic',
        easy_all_ssh_ports: process.env.A14_SSH_PORTS || '',
        request_filename: file,
    },
    headersOut: {},
    return(code, body) { result.code = code; result.body = body; },
});
if (result.code !== 200) {
    console.error(`render ${kind} failed: ${result.code}`);
    process.exit(1);
}
let port;
if (kind === 'base64') {
    const first = Buffer.from(result.body, 'base64').toString('utf8').split('\n')[0];
    const match = first.match(/@[^:@]+:(\d+)\?/);
    if (!match) { console.error('own node port missing'); process.exit(1); }
    port = Number(match[1]);
} else {
    const match = result.body.match(/^ {4}port: (\d+)$/m);
    if (!match) { console.error('own node port missing'); process.exit(1); }
    port = Number(match[1]);
}
console.log(port);
JS
A14_SSH_PORTS=$(sed -n 's/^ *set \$easy_all_ssh_ports "\(.*\)";$/\1/p' "${NGINX_CONFIG}" | head -n 1)
A14_NOW_MS=$(sed -n 's/^NOW_MS=//p' "${REALITY_SCENARIO_OUT}" | head -n 1)
A14_EXPECTED_PORT=$(sed -n 's/^EXPECTED_PORT=//p' "${REALITY_SCENARIO_OUT}" | head -n 1)
assert_equal "A14: nginx 变量就是池内 SSH 端口" "${A14_SSH_PORT}" "${A14_SSH_PORTS}"
[[ "${A14_NOW_MS}" =~ ^[0-9]+$ ]] \
    || fail_test "A14: 场景未给出冻结时刻：$(<"${REALITY_SCENARIO_OUT}")"
[[ "${A14_EXPECTED_PORT}" =~ ^[0-9]+$ ]] \
    || fail_test "A14: 场景未给出期望端口：$(<"${REALITY_SCENARIO_OUT}")"
# 反证：同一冻结时刻不传排除列表时，渲染器恰好选中被排除的 SSH 端口。
A14_SSH_PORTS="" A14_NOW_MS="${A14_NOW_MS}" \
    REALITY_SUBSCRIPTION_MODULE="${ROOT_DIR}/lib/reality-subscription.js" \
    node "${A14_RENDER_JS}" base64 "${SUBSCRIPTION_BASE64_FILE}" \
    >"${TMP_DIR}/a14-port-noexclude" 2>&1 \
    || fail_test "A14: 无排除列表的渲染失败：$(<"${TMP_DIR}/a14-port-noexclude")"
assert_equal "A14: 断言非空转（不传排除列表就会命中被排除端口）" "${A14_SSH_PORT}" \
    "$(<"${TMP_DIR}/a14-port-noexclude")"
# 渲染器只有 base64 与 mihomo 两个入口；iOS 变体走 mihomo 渲染器配 -ios 文件。
for a14_case in "base64:${SUBSCRIPTION_BASE64_FILE}" "mihomo:${SUBSCRIPTION_MIHOMO_FILE}" \
    "mihomo:${SUBSCRIPTION_MIHOMO_IOS_FILE}"; do
    a14_kind=${a14_case%%:*}
    a14_file=${a14_case#*:}
    A14_SSH_PORTS="${A14_SSH_PORTS}" A14_NOW_MS="${A14_NOW_MS}" \
        REALITY_SUBSCRIPTION_MODULE="${ROOT_DIR}/lib/reality-subscription.js" \
        node "${A14_RENDER_JS}" "${a14_kind}" "${a14_file}" \
        >"${TMP_DIR}/a14-port-${a14_file##*/}" 2>&1 \
        || fail_test "A14: ${a14_file##*/} 渲染失败：$(<"${TMP_DIR}/a14-port-${a14_file##*/}")"
    a14_port=$(<"${TMP_DIR}/a14-port-${a14_file##*/}")
    [[ "${a14_port}" =~ ^[0-9]+$ ]] || fail_test "A14: ${a14_file##*/} 未渲染出端口：${a14_port}"
    [[ "${a14_port}" != "${A14_SSH_PORT}" ]] \
        || fail_test "A14: ${a14_file##*/} 下发了 SSH 端口 ${a14_port}"
    assert_equal "A14: ${a14_file##*/} 选中排除后的下一个槽位" "${A14_EXPECTED_PORT}" "${a14_port}"
    ((a14_port >= PORT_BASE && a14_port <= DYNAMIC_PORT_MAX)) \
        || fail_test "A14: ${a14_file##*/} 端口 ${a14_port} 不在动态端口范围"
done

reality_fixture_reset "swdist.apple.com:443" deploy dynamic
: >"${CRONTAB_FAIL}"
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a14-crontab-fail <<'EOF'
rotate_dynamic_ports
EOF
reality_run_scenario a14-crontab-fail
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A14: crontab 真读取失败时 rotate 非零" "1" "${REALITY_SCENARIO_RC}"
assert_contains "A14: rotate 的 crontab 读取失败点名原因" "$(<"${REALITY_SCENARIO_OUT}")" \
    "读取 root crontab 失败"
assert_equal "A14: crontab 读取失败不得改 NAT/订阅/state" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
[[ ! -s "${SYSTEMCTL_LOG}" ]] || fail_test "A14: crontab 读取失败不得重载 Nginx"

reality_fixture_reset "swdist.apple.com:443" deploy 443
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a14-fixed <<'EOF'
rotate_dynamic_ports
EOF
reality_run_scenario a14-fixed
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A14: fixed 443 保持无操作" "0" "${REALITY_SCENARIO_RC}"
assert_equal "A14: fixed 443 不触碰任何资产" \
    "$(<"${TMP_DIR}/hash-baseline")" "$(<"${TMP_DIR}/hash-after")"
[[ ! -s "${SYSTEMCTL_LOG}" ]] || fail_test "A14: fixed 443 不得重载服务"
[[ ! -s "${UFW_LOG}" ]] || fail_test "A14: fixed 443 不得改防火墙"

reality_fixture_reset "swdist.apple.com:443" link dynamic
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a14-link <<'EOF'
rotate_dynamic_ports
EOF
reality_run_scenario a14-link
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A14: link 模式 rotate 成功" "0" "${REALITY_SCENARIO_RC}"
A14_NAT_BASELINE=$(grep ' before.rules$' "${TMP_DIR}/hash-baseline" | awk '{print $1}')
[[ "$(reality_file_hash "${UFW_BEFORE_RULES}")" != "${A14_NAT_BASELINE}" ]] \
    || fail_test "A14: link 模式仍应刷新 NAT 规则"
assert_equal "A14: link 模式不重写 Nginx 与订阅" \
    "$(grep -v ' before.rules$' "${TMP_DIR}/hash-baseline")" \
    "$(grep -v ' before.rules$' "${TMP_DIR}/hash-after")"

# ---- A15：保留组名单一来源 + 安装前置本机名校验 ----
assert_contains "A15: 保留名以 bash 数组为唯一来源" \
    "$(declare -p LOCAL_AGGREGATION_RESERVED_NAMES 2>&1)" "declare -a"
for a15_reserved in AUTO CDN-AUTO CDN-FALLBACK PROXY GLOBAL DIRECT REJECT PASS; do
    if (
        NODE_NAME="正常节点"
        reality_apply_subscription_config \
            "{\"allowedTokens\":{\"owner\":\"token-init-12345\"},\"nodes\":[{\"type\":\"vless\",\"security\":\"reality\",\"network\":\"tcp\",\"name\":\"${a15_reserved}\",\"host\":\"r.example.com\",\"uuid\":\"22222222-2222-4222-8222-222222222222\",\"sni\":\"s\",\"pbk\":\"p\",\"sid\":\"aabbccdd\"}]}"
    ) >/dev/null 2>&1; then
        fail_test "A15: 聚合节点使用保留组名 ${a15_reserved} 必须被拒绝"
    fi
    if (
        NODE_NAME="${a15_reserved}"
        reality_apply_subscription_config \
            '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[]}'
    ) >/dev/null 2>&1; then
        fail_test "A15: 本机节点名 ${a15_reserved} 必须被发布边界拒绝"
    fi
done
# 普通 ASCII / 中文 / 大小写变体都是合法本机名。
for a15_valid in MY_REALITY "中文节点" proxy AUTO_ 有效名称2; do
    (
        NODE_NAME="${a15_valid}"
        reality_apply_subscription_config \
            '{"allowedTokens":{"owner":"token-init-12345"},"nodes":[]}'
    ) >/dev/null 2>&1 \
        || fail_test "A15: 合法本机名 ${a15_valid} 被误拒"
done

reality_fixture_reset "swdist.apple.com:443" link 443
rm -f "${RUNTIME_WRITE_LOCK_FILE_OVERRIDE}" "${PACKAGE_LOG}"
reality_scenario_file a15-install-precheck <<'EOF'
NODE_NAME=PROXY
run_reality_install_pipeline reality 0
EOF
reality_run_scenario a15-install-precheck
assert_equal "A15: 保留本机名的安装入口非零" "1" "${REALITY_SCENARIO_RC}"
assert_contains "A15: 安装入口拒绝文案点明本机名" "$(<"${REALITY_SCENARIO_OUT}")" \
    "本机节点名无效：PROXY"
assert_contains "A15: 拒绝文案给出环境覆盖修复" "$(<"${REALITY_SCENARIO_OUT}")" \
    "sudo env NODE_NAME="
assert_not_contains "A15: 拒绝发生在系统初始化之前" "$(<"${REALITY_SCENARIO_OUT}")" \
    "检查系统"
[[ ! -e "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] \
    || fail_test "A15: 拒绝前不得写安装 marker"
[[ ! -e "${BACKUP_DIR}/pre-install-complete" ]] \
    || fail_test "A15: 拒绝前不得拍安装快照"
[[ ! -s "${PACKAGE_LOG}" ]] || fail_test "A15: 拒绝前不得调用 APT/Swap 等外部命令"
[[ ! -e "${RUNTIME_WRITE_LOCK_FILE_OVERRIDE}" ]] \
    || fail_test "A15: 拒绝前不得获取运行时写锁"

# 控制组：未提供 NODE_NAME 时现有默认名通过预检，安装流程继续到下一步。
reality_scenario_file a15-default-name <<'EOF'
unset NODE_NAME
rm -f "${STATE_FILE}"
run_reality_install_pipeline reality 0
EOF
reality_run_scenario a15-default-name
assert_not_contains "A15: 默认本机名通过预检" "$(<"${REALITY_SCENARIO_OUT}")" "本机节点名无效"
assert_contains "A15: 默认本机名预检后流程继续" "$(<"${REALITY_SCENARIO_OUT}")" "检查系统"

# 隔离 PATH（没有 jq）下加载 Profile 并执行前置预检：不依赖 jq/APT/网络。
NOJQ_BIN="${TMP_DIR}/nojq-bin"
install -d -m 0755 "${NOJQ_BIN}"
ln -sf "$(command -v dirname)" "${NOJQ_BIN}/dirname"
{
    printf 'set -Eeuo pipefail\n'
    # 必须在加载夹具之前设好：隔离 PATH 里没有 chmod/jq，跳过 Xray 二进制桩。
    printf 'REALITY_CHILD_NO_XRAY=1\n'
    printf 'source "%s"\n' "${REALITY_CHILD_ENV}"
    cat <<'EOF'
command -v jq >/dev/null 2>&1 && { printf 'JQ_PRESENT\n'; exit 3; }
NODE_NAME="有效名称"
validate_reality_local_node_name "${NODE_NAME}" && printf 'VALID_ACCEPTED\n'
NODE_NAME=PROXY
run_reality_install_pipeline reality 0
EOF
} >"${TMP_DIR}/scenario-a15-nojq.sh"
A15_NOJQ_OUT="${TMP_DIR}/scenario-a15-nojq.out"
A15_NOJQ_RC=0
env PATH="${NOJQ_BIN}" /bin/bash "${TMP_DIR}/scenario-a15-nojq.sh" \
    >"${A15_NOJQ_OUT}" 2>&1 || A15_NOJQ_RC=$?
assert_equal "A15: 无 jq 的隔离 PATH 下坏本机名被拒绝" "1" "${A15_NOJQ_RC}"
assert_contains "A15: 无 jq 时预检不依赖 jq" "$(<"${A15_NOJQ_OUT}")" "VALID_ACCEPTED"
assert_contains "A15: 无 jq 时准确拒绝保留名" "$(<"${A15_NOJQ_OUT}")" "本机节点名无效：PROXY"
assert_not_contains "A15: 无 jq 时预检不出现 command not found" \
    "$(<"${A15_NOJQ_OUT}")" "command not found"

# 历史坏本机名分三种契约：link 只读展示可用；deploy 写订阅被拒绝并给出环境覆盖提示；
# 覆盖有效名后可修复且不再自引用。
reality_fixture_reset "swdist.apple.com:443" link 443 PROXY
reality_scenario_file a15-history-link <<'EOF'
unset SUBSCRIPTION_CONFIG AGGREGATION_NODES ALLOWED_TOKENS
load_state --reload
printf 'LOAD_OK\n'
show_node >/dev/null
printf 'SHOW_OK\n'
build_node_link 443
EOF
reality_run_scenario a15-history-link
assert_equal "A15: link 历史坏本机名仍可读状态并只读展示" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A15: load_state 对历史坏名只告警" "$(<"${REALITY_SCENARIO_OUT}")" \
    "状态文件中的本机节点名无效：PROXY"
assert_contains "A15: 告警给出 NODE_NAME 环境覆盖修复" "$(<"${REALITY_SCENARIO_OUT}")" \
    "sudo env NODE_NAME="
assert_contains "A15: 坏名下 load_state 不阻断入口" "$(<"${REALITY_SCENARIO_OUT}")" "LOAD_OK"
assert_contains "A15: 坏名下只读展示可用" "$(<"${REALITY_SCENARIO_OUT}")" "SHOW_OK"
assert_contains "A15: 只读展示仍显示当前节点名" "$(<"${REALITY_SCENARIO_OUT}")" "#PROXY"

reality_fixture_reset
reality_hash_tree "${TMP_DIR}/hash-baseline"
reality_scenario_file a15-history-deploy <<'EOF'
reality_fixture_state "swdist.apple.com:443" deploy 443 PROXY
load_state --reload >/dev/null 2>&1
save_state
install_static_subscriptions
EOF
reality_run_scenario a15-history-deploy
reality_hash_tree "${TMP_DIR}/hash-after"
assert_equal "A15: deploy 历史坏本机名下写订阅被拒绝" "1" "${REALITY_SCENARIO_RC}"
assert_contains "A15: 写订阅拒绝点明本机名" "$(<"${REALITY_SCENARIO_OUT}")" \
    "本机节点名无效：PROXY"
assert_contains "A15: 写订阅拒绝指向 NODE_NAME 覆盖" "$(<"${REALITY_SCENARIO_OUT}")" \
    "sudo env NODE_NAME="
assert_equal "A15: 拒绝前不得改写六产物与模板快照" \
    "$(grep -v ' state.env$' "${TMP_DIR}/hash-baseline")" \
    "$(grep -v ' state.env$' "${TMP_DIR}/hash-after")"

reality_scenario_file a15-history-fix <<'EOF'
unset SUBSCRIPTION_CONFIG AGGREGATION_NODES ALLOWED_TOKENS
load_state --reload >/dev/null 2>&1
NODE_NAME="修好的节点"
install_static_subscriptions
EOF
reality_run_scenario a15-history-fix
assert_equal "A15: 环境覆盖有效名后发布成功" "0" "${REALITY_SCENARIO_RC}"
assert_contains "A15: 修复后订阅使用新的本机名" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" 'name: "修好的节点"'
assert_not_contains "A15: 修复后订阅不再自引用保留名" "$(<"${SUBSCRIPTION_MIHOMO_FILE}")" 'name: "PROXY"'

printf 'ok - reality subscription aggregation rendering\n'
