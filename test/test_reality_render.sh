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
export CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"

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

# shellcheck source=/dev/null
source "${PROFILE}"
unset -f readonly
require_root() { :; }
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
    reality_cloudflare_api_request() { printf 'called\n' >>"${cf_marker}"; }
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

# link 模式不残留聚合配置
COLLECT_STUB=$(
    SUBSCRIPTION_MODE="deploy"
    collect_link_subscription_inputs
    printf '%s|%s|%s\n' "${SUBSCRIPTION_MODE}" "${ALLOWED_TOKENS}" "${SUBSCRIPTION_CONFIG}"
)
assert_equal "link: aggregation config cleared" "link||" "${COLLECT_STUB}"

printf 'ok - reality subscription aggregation rendering\n'
