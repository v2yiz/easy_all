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

bash -n "${AGG_LIB}" "${PROFILE}"

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
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP_DIR}/runtime-write.lock"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress/install-progress.env"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"

mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" \
    "${WEB_ROOT}" "${SUBSCRIPTION_DIR}" "${COMMAND_INSTALL_DIR}" \
    "${TMP_DIR}/bin" "${XRAY_DIR}" "${TMP_DIR}/systemd"
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

printf 'ok - reality subscription aggregation rendering\n'
