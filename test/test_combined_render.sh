#!/usr/bin/env bash
# 组合模式（profiles/combined.sh）单元与回归测试。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/combined.sh"
SUB_AUTH_LIB="${ROOT_DIR}/lib/subscription-auth.sh"

# 沙箱环境可能禁止写用户默认 TMPDIR，显式使用 /tmp 模板并为无参 mktemp -d 提供兜底。
TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_combined_test.XXXXXX")
mktemp() {
    if [[ $# -eq 1 && "$1" == "-d" ]]; then
        command mktemp -d 2>/dev/null || command mktemp -d "${TMP_DIR}/runtime.XXXXXX"
    else
        command mktemp "$@"
    fi
}
trap 'command rm -rf -- "${TMP_DIR}"' EXIT

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

# 1. 语法检查
bash -n "${SUB_AUTH_LIB}" "${PROFILE}"

# 2. 导出隔离路径并包装 readonly / install / rm / flock / nginx / systemctl
export STATE_DIR="${TMP_DIR}/state"
export BACKUP_DIR="${STATE_DIR}/backups"
export STATE_FILE="${STATE_DIR}/state.env"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/fullchain.pem"
export KEY_FILE="${CERT_DIR}/private.key"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
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

# 保留测试预导出的隔离路径，不让 xhttp-runtime.sh 的硬编码 /etc 覆盖
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
    local target="${args[${#args[@]}-1]}"
    if [[ "${target}" == /etc/easy_all/* || "${target}" == "/etc/easy_all" ]]; then
        target="${TMP_DIR}/state${target#/etc/easy_all}"
        args[${#args[@]}-1]="${target}"
    elif [[ "${target}" == "/etc/nginx/conf.d/easy_all.conf" ]]; then
        target="${TMP_DIR}/nginx.conf"
        args[${#args[@]}-1]="${target}"
    elif [[ "${target}" == /var/www/easy_all/* || "${target}" == "/var/www/easy_all" ]]; then
        target="${TMP_DIR}/web${target#/var/www/easy_all}"
        args[${#args[@]}-1]="${target}"
    fi
    if [[ " ${args[*]} " == *" -d "* ]]; then
        mkdir -p "${target}"
    elif [[ -n "${target}" ]]; then
        mkdir -p "$(dirname "${target}")"
    fi
    command install "${args[@]}"
}

rm() {
    local args=() arg
    for arg in "$@"; do
        if [[ "${arg}" == /etc/easy_all/* || "${arg}" == "/etc/easy_all" ]]; then
            args+=("${TMP_DIR}/state${arg#/etc/easy_all}")
        elif [[ "${arg}" == "/etc/nginx/conf.d/easy_all.conf" ]]; then
            args+=("${TMP_DIR}/nginx.conf")
        elif [[ "${arg}" == /var/www/easy_all/* || "${arg}" == "/var/www/easy_all" ]]; then
            args+=("${TMP_DIR}/web${arg#/var/www/easy_all}")
        else
            args+=("${arg}")
        fi
    done
    command rm "${args[@]}"
}

cat >"${XRAY_BIN}" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "x25519" ]]; then
    printf 'PrivateKey: test-private-key\nPublicKey: test-public-key\n'
    exit 0
fi
exit 0
EOF
chmod +x "${XRAY_BIN}"

flock() { :; }
nginx() { :; }
systemctl() { :; }
require_root() { :; }

# 在 source 之前清掉宿主环境里的同名变量：本测试要证明的是"端口由 profile 自己定义"，
# 继承值会掩盖"combined 未定义回环端口"这类缺陷（2.2.1 曾因此在首次安装时崩溃）。
unset XRAY_XHTTP_LOOPBACK_PORT
# shellcheck source=/dev/null
source "${PROFILE}"
unset -f readonly
require_root() { :; }
trap 'status=$?; cleanup; command rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

# 初始化组合模式 fixture
CF_ZONE="example.com"
CLOUDFLARE_ZONE_ID="zone-123456"
VPS_PUBLIC_IPV4="198.51.100.10"
DIRECT_DOMAIN="direct.example.com"
CF_NODE_DOMAIN="cf-node.example.com"
CF_ORIGIN_DOMAIN="cf-origin.example.com"
GCORE_NODE_DOMAIN="gcore-node.example.com"
GCORE_ORIGIN_DOMAIN="gcore-origin.example.com"
SUBSCRIPTION_DOMAIN="sub.example.com"
VLESS_CDN_DOMAIN="${CF_NODE_DOMAIN}"
XHTTP_ORIGIN_DOMAIN="${CF_ORIGIN_DOMAIN}"
SUB_DOWNLOAD_NAME="EASYALL"
OWNER_TOKEN="token-init-12345"
ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}')
VLESS_UUID="11111111-2222-4111-8111-111111111111"
DIRECT_NODE_NAME="🇺🇸直连"
CF_NODE_PREFIX="🇺🇸CF"
GCORE_NODE_NAME="🇺🇸GCore"
XHTTP_PATH="/xhttp-abcdef123456"
WEBSOCKET_PATH="/ws-abcdef1234567890"
REALITY_TARGET="swdist.apple.com:443"
REALITY_PRIVATE_KEY="test-private-key"
REALITY_PUBLIC_KEY="test-public-key"
REALITY_SHORT_ID="0123456789abcdef"
CLOUDFLARE_ORIGIN_CERT_ID="cert-old-111"
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2041-11-03 00:00:00 +0000 UTC"
SUBSCRIPTION_MODE="deploy"
TCP_ACCELERATION="bbr"
save_state

# 10a) cloudflare_origin_certificate_hosts 输出恰含 3 个名字且包含 CF_NODE_DOMAIN（节点名在前）
hosts_json=$(cloudflare_origin_certificate_hosts)
assert_equal "10a: cloudflare_origin_certificate_hosts count is 3" \
    "3" "$(jq 'length' <<<"${hosts_json}")"
assert_equal "10a: cloudflare_origin_certificate_hosts order is [CF_NODE_DOMAIN, CF_ORIGIN_DOMAIN, SUBSCRIPTION_DOMAIN]" \
    "$(jq -cn --arg n "${CF_NODE_DOMAIN}" --arg o "${CF_ORIGIN_DOMAIN}" --arg s "${SUBSCRIPTION_DOMAIN}" '[$n,$o,$s]')" \
    "$(jq -c '.' <<<"${hosts_json}")"
assert_contains "10a: cloudflare_origin_certificate_hosts includes CF_NODE_DOMAIN" \
    "${hosts_json}" "\"${CF_NODE_DOMAIN}\""

# 10b & 10c) combined_render_nginx_config 输出中 XHTTP 块 server_name 同时含 CF_NODE_DOMAIN 与 CF_ORIGIN_DOMAIN，
# 且包含 ssl_reject_handshake on、grpc_pass、订阅 server 块；Xray 配置 xhttpSettings.host 等于 CF_NODE_DOMAIN
rendered_modern=$(combined_render_nginx_config $'\n    http2 on;' "")
assert_contains "10b: XHTTP block server_name has both CF_NODE_DOMAIN and CF_ORIGIN_DOMAIN" \
    "${rendered_modern}" "server_name ${CF_NODE_DOMAIN} ${CF_ORIGIN_DOMAIN};"
assert_contains "10c: rendered nginx config has ssl_reject_handshake on" \
    "${rendered_modern}" "ssl_reject_handshake on;"
assert_contains "10c: rendered nginx config has grpc_pass with XRAY_XHTTP_LOOPBACK_PORT" \
    "${rendered_modern}" "grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};"
# 10c-1: 回环端口必须由 profile 自己定义（不能靠测试或环境提供），且与 WS 端口不冲突
[[ "${XRAY_XHTTP_LOOPBACK_PORT}" =~ ^[0-9]+$ ]] \
    || fail "10c-1: XRAY_XHTTP_LOOPBACK_PORT must be a numeric value defined by combined.sh"
((10#${XRAY_XHTTP_LOOPBACK_PORT} >= 1024 && 10#${XRAY_XHTTP_LOOPBACK_PORT} <= 65535)) \
    || fail "10c-1: XRAY_XHTTP_LOOPBACK_PORT out of range"
[[ "${XRAY_XHTTP_LOOPBACK_PORT}" != "${XRAY_WEBSOCKET_LOOPBACK_PORT}" ]] \
    || fail "10c-1: XHTTP and WebSocket loopback ports must differ"
assert_contains "10c: rendered nginx config has subscription server_name" \
    "${rendered_modern}" "server_name ${SUBSCRIPTION_DOMAIN};"
assert_contains "10c: rendered nginx config has /subscribe location" \
    "${rendered_modern}" "location = /subscribe {"

write_xray_config
assert_equal "10b-xray: Xray xhttpSettings.host equals CF_NODE_DOMAIN" \
    "${CF_NODE_DOMAIN}" \
    "$(jq -r '.inbounds[] | select(.tag=="vless-xhttp-in") | .streamSettings.xhttpSettings.host' "${XRAY_CONFIG}")"

# 10d) HTTP/2 两种分支都能渲染（分别强制 nginx_supports_http2_directive 返回真/假）
(
    nginx_supports_http2_directive() { return 0; }
    write_nginx_config
    conf_true=$(<"${NGINX_CONFIG}")
    assert_contains "10d-true: modern http2 directive present" "${conf_true}" "http2 on;"
    assert_not_contains "10d-true: legacy listen http2 absent" "${conf_true}" "listen 443 ssl http2 "
)
(
    nginx_supports_http2_directive() { return 1; }
    write_nginx_config
    conf_false=$(<"${NGINX_CONFIG}")
    assert_contains "10d-false: legacy listen http2 present" "${conf_false}" \
        "listen 443 ssl http2 backlog=4096 so_keepalive=15s:5s:3 default_server;"
    assert_contains "10d-false: legacy listen http2 on XHTTP server" "${conf_false}" "listen 443 ssl http2 backlog=4096"
    assert_not_contains "10d-false: modern http2 directive absent" "${conf_false}" "http2 on;"
)

# 10e) combined_apply_tokens 切换后 write_subscription_token_map 只含新值不含旧值
# 注：normalize_allowed_tokens（lib/subscription-auth.sh:113）要求 token 长度 8-128，故用 token-A-123456 / token-B-123456
ALLOWED_TOKENS='{"owner":"token-A-123456"}'
OWNER_TOKEN="token-A-123456"
combined_apply_tokens '{"owner":"token-B-123456"}' \
    || fail "10e: valid token should be accepted by combined_apply_tokens"
assert_equal "10e: OWNER_TOKEN updated to B" "token-B-123456" "${OWNER_TOKEN}"
assert_equal "10e: ALLOWED_TOKENS updated to B" '{"owner":"token-B-123456"}' "${ALLOWED_TOKENS}"
token_map_output=$(write_subscription_token_map)
assert_contains "10e: write_subscription_token_map contains token B" "${token_map_output}" '"token-B-123456" 1;'
assert_not_contains "10e: write_subscription_token_map does not contain token A" "${token_map_output}" "token-A-123456"

# 10f) 非法输入 {"owner":""}、{}、{"owner":1} 三种都返回非零，且 ALLOWED_TOKENS/OWNER_TOKEN/NGINX_CONFIG 内容不变
write_nginx_config
save_state
mkdir -p "${SUBSCRIPTION_DIR}"
printf 'sub-before\n' >"${SUBSCRIPTION_BASE64_FILE}"
expected_allowed_before="${ALLOWED_TOKENS}"
expected_owner_before="${OWNER_TOKEN}"
expected_nginx_before=$(<"${NGINX_CONFIG}")
expected_state_before=$(<"${STATE_FILE}")
expected_sub_before=$(<"${SUBSCRIPTION_BASE64_FILE}")

for invalid_json in '{"owner":""}' '{}' '{"owner":1}' '{"": "token-valid-1234"}' '"not-an-object"'; do
    if combined_apply_tokens "${invalid_json}" 2>/dev/null; then
        fail "10f: invalid token input ${invalid_json} must return non-zero"
    fi
    assert_equal "10f: ALLOWED_TOKENS unchanged after ${invalid_json}" \
        "${expected_allowed_before}" "${ALLOWED_TOKENS}"
    assert_equal "10f: OWNER_TOKEN unchanged after ${invalid_json}" \
        "${expected_owner_before}" "${OWNER_TOKEN}"
    assert_equal "10f: NGINX_CONFIG unchanged after ${invalid_json}" \
        "${expected_nginx_before}" "$(<"${NGINX_CONFIG}")"
    assert_equal "10f: STATE_FILE unchanged after ${invalid_json}" \
        "${expected_state_before}" "$(<"${STATE_FILE}")"
    assert_equal "10f: SUBSCRIPTION_BASE64_FILE unchanged after ${invalid_json}" \
        "${expected_sub_before}" "$(<"${SUBSCRIPTION_BASE64_FILE}")"
done

# 10g) 空 $arg_token 在 map 中落到 __denied__（default __denied__ 存在，且无 "" 1; 空键条目）
maps_output=$(write_subscription_nginx_maps)
assert_contains "10g: write_subscription_nginx_maps contains default __denied__;" \
    "${maps_output}" "default __denied__;"
assert_not_contains "10g: write_subscription_nginx_maps has no empty key entry" \
    "${maps_output}" '"" 1;'

# 附加验证 1: combined_validate_cf_node_sni 成功与失败分支（含故障注入 B：strict / lenient 模式）
(
    cloudflare_ensure_origin_ca_root() { :; }
    curl() {
        assert_contains "sni-check: curl resolves CF_NODE_DOMAIN to 127.0.0.1" \
            "$*" "--resolve ${CF_NODE_DOMAIN}:443:127.0.0.1"
        assert_contains "sni-check: curl targets CF_NODE_DOMAIN" \
            "$*" "https://${CF_NODE_DOMAIN}/easy_all-health"
        printf 'easy_all ok'
    }
    combined_validate_cf_node_sni
)
if (
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { return 35; }
    combined_validate_cf_node_sni
) >/dev/null 2>&1; then
    fail "sni-check: TLS handshake failure must fail combined_validate_cf_node_sni"
fi

# 故障注入 B：构造"证书不覆盖节点域名 + 探测失败"场景（模拟 OpenSSL 3 真实行为：不匹配时仍 exit 0）
printf 'legacy-cert-without-node-san\n' >"${CERT_FILE}"
helper_not_match_rc=0
(
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does NOT match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_certificate_covers_node_domain
) || helper_not_match_rc=$?
[[ "${helper_not_match_rc}" -ne 0 ]] \
    || fail "checkhost-not-match: combined_certificate_covers_node_domain must return non-zero on 'does NOT match certificate' (exit 0)"

lenient_rc=0
lenient_out=$(
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { return 60; }
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does NOT match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_validate_cf_node_sni lenient 2>&1
) || lenient_rc=$?
assert_equal "fault-B-lenient: returns 0 when cert does not cover CF_NODE_DOMAIN" "0" "${lenient_rc}"
assert_contains "fault-B-lenient: warns with apply-cloud guidance" "${lenient_out}" "apply-cloud"
assert_contains "fault-B-lenient: mentions uncovered CF_NODE_DOMAIN" "${lenient_out}" "未覆盖 ${CF_NODE_DOMAIN}"

strict_rc=0
strict_out=$(
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { return 60; }
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does NOT match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_validate_cf_node_sni strict 2>&1
) || strict_rc=$?
[[ "${strict_rc}" -ne 0 ]] || fail "fault-B-strict: strict mode must return non-zero on same uncovered scenario"
assert_contains "fault-B-strict: error message includes apply-cloud" "${strict_out}" "apply-cloud"

# 桩输出 does match certificate + exit 0：helper 返回 0；探测成功时 lenient / strict 均返回 0
helper_match_rc=0
(
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_certificate_covers_node_domain
) || helper_match_rc=$?
assert_equal "checkhost-match: combined_certificate_covers_node_domain returns 0 on 'does match certificate'" \
    "0" "${helper_match_rc}"

probe_ok_lenient_rc=0
(
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { printf 'easy_all ok'; }
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_validate_cf_node_sni lenient
) || probe_ok_lenient_rc=$?
assert_equal "checkhost-match-lenient: lenient returns 0 when covered and probe succeeds" \
    "0" "${probe_ok_lenient_rc}"

probe_ok_strict_rc=0
(
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { printf 'easy_all ok'; }
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_validate_cf_node_sni strict
) || probe_ok_strict_rc=$?
assert_equal "checkhost-match-strict: strict returns 0 when covered and probe succeeds" \
    "0" "${probe_ok_strict_rc}"

# 桩输出 unknown option -checkhost（LibreSSL）：helper 返回非零（保守判为未覆盖）
helper_libressl_rc=0
(
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'x509: unknown option -checkhost\n' >&2
            return 1
        fi
        command openssl "$@"
    }
    combined_certificate_covers_node_domain
) || helper_libressl_rc=$?
[[ "${helper_libressl_rc}" -ne 0 ]] \
    || fail "checkhost-libressl: combined_certificate_covers_node_domain must return non-zero on unknown option -checkhost"

covered_lenient_rc=0
covered_lenient_out=$(
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { return 35; }
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    combined_validate_cf_node_sni lenient 2>&1
) || covered_lenient_rc=$?
[[ "${covered_lenient_rc}" -ne 0 ]] \
    || fail "fault-B-covered: lenient mode must still die when cert covers CF_NODE_DOMAIN but probe fails"
assert_contains "fault-B-covered: error message mentions TLS/SNI failure" \
    "${covered_lenient_out}" "本机 TLS/SNI 验收失败"

apply_uncovered_rc=0
apply_uncovered_out=$(
    configure_tcp_acceleration() { :; }
    xhttp_configure_ufw() { :; }
    write_xray_config() { :; }
    install_xray_service() { :; }
    gcore_prepare_origin_validation_material() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cloudflare_ensure_origin_ca_root() { :; }
    curl() { return 60; }
    openssl() {
        if [[ "$*" == *-checkhost* ]]; then
            printf 'Hostname cfg-node.example.com does NOT match certificate\n'
            return 0
        fi
        command openssl "$@"
    }
    globalping_cache_valid() { return 0; }
    write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    register_easy_all_command() { :; }
    install_globalping_refresh_timer() { :; }
    apply_easy_all 2>&1
) || apply_uncovered_rc=$?
assert_equal "fault-B-apply: apply_easy_all succeeds on uncovered legacy cert" "0" "${apply_uncovered_rc}"
assert_contains "fault-B-apply: apply_easy_all output warns to run apply-cloud" "${apply_uncovered_out}" "apply-cloud"

# 附加验证 2: update_subscription 事务回滚一致性（写 Nginx 成功、write_subscriptions 失败时恢复全部文件）
OWNER_TOKEN="token-before-tx"
ALLOWED_TOKENS='{"owner":"token-before-tx"}'
save_state
write_nginx_config
mkdir -p "${SUBSCRIPTION_DIR}"
printf 'base64-before\n' >"${SUBSCRIPTION_BASE64_FILE}"
printf 'mihomo-before\n' >"${SUBSCRIPTION_MIHOMO_FILE}"
nginx_before_tx=$(<"${NGINX_CONFIG}")
state_before_tx=$(<"${STATE_FILE}")

if (
    cleanup_files=()
    trap cleanup EXIT
    ALLOWED_TOKENS='{"owner":"token-after-tx"}'
    write_subscriptions() { die "注入写订阅失败"; }
    update_subscription </dev/null
) >/dev/null 2>&1; then
    fail "tx-rollback: update_subscription must fail when write_subscriptions fails"
fi
assert_equal "tx-rollback: NGINX_CONFIG restored after failed update_subscription" \
    "${nginx_before_tx}" "$(<"${NGINX_CONFIG}")"
assert_equal "tx-rollback: STATE_FILE restored after failed update_subscription" \
    "${state_before_tx}" "$(<"${STATE_FILE}")"
assert_equal "tx-rollback: subscription base64 restored after failed update_subscription" \
    "base64-before" "$(<"${SUBSCRIPTION_BASE64_FILE}")"

# 附加验证 3: apply_cloud_resources 与 renew_certificate 的提交顺序与失败回滚
printf 'cert-old\n' >"${CERT_FILE}"
printf 'key-old\n' >"${KEY_FILE}"
CLOUDFLARE_ORIGIN_CERT_ID="cert-old-111"
save_state
state_before_cloud=$(<"${STATE_FILE}")
finalize_called=0

if (
    cleanup_files=()
    trap cleanup EXIT
    configure_tcp_acceleration() { :; }
    xhttp_configure_ufw() { :; }
    combined_ensure_dns() { :; }
    combined_issue_certificates() {
        printf 'cert-new\n' >"${CERT_FILE}"
        printf 'key-new\n' >"${KEY_FILE}"
        CLOUDFLARE_ORIGIN_CERT_ID="cert-new-222"
        CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID="cert-old-111"
    }
    write_xray_config() { :; }
    install_xray_service() { :; }
    gcore_prepare_origin_validation_material() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    combined_validate_cf_node_sni() { :; }
    combined_gcore_resource() { die "注入 Gcore 同步失败"; }
    cloudflare_finalize_certificate_rotation() {
        finalize_called=1
        printf 'finalized\n' >"${TMP_DIR}/finalized-flag"
    }
    apply_cloud_resources
) >/dev/null 2>&1; then
    fail "cloud-rollback: apply_cloud_resources must fail when Gcore step fails"
fi
[[ ! -f "${TMP_DIR}/finalized-flag" ]] \
    || fail "cloud-rollback: finalize must not be called before save_state"
assert_equal "cloud-rollback: CERT_FILE restored" "cert-old" "$(<"${CERT_FILE}")"
assert_equal "cloud-rollback: KEY_FILE restored" "key-old" "$(<"${KEY_FILE}")"
assert_equal "cloud-rollback: STATE_FILE restored" "${state_before_cloud}" "$(<"${STATE_FILE}")"

# renew_certificate 顺序：issue -> nginx -t -> reload -> save_state -> finalize -> commit
renew_seq=""
(
    cloudflare_collect_api_token() { :; }
    cloudflare_lookup_parent_zone() { printf 'zone-123456'; }
    combined_issue_certificates() { renew_seq+="issue:${1} "; }
    nginx() { [[ "${1:-}" == "-t" ]] && renew_seq+="nginx-t "; }
    systemctl() { [[ "${1:-}" == "reload" ]] && renew_seq+="reload "; }
    save_state() { renew_seq+="save "; }
    cloudflare_finalize_certificate_rotation() { renew_seq+="finalize "; }
    commit_subscription_update() {
        renew_seq+="commit "
        end_quota_maintenance
        UPDATE_SUB_ROLLBACK_ON_EXIT=0
    }
    success() { renew_seq+="success"; }
    renew_certificate
    assert_equal "renew-order: renew_certificate follows issue -> verify -> save -> finalize -> commit" \
        "issue:1 nginx-t reload save finalize commit success" "${renew_seq}"
)

# 故障注入 A：吊销旧证书（cloudflare_finalize_certificate_rotation）后步骤失败时，不得回滚到已吊销的旧证书
printf 'cert-old-revoked\n' >"${CERT_FILE}"
printf 'key-old-revoked\n' >"${KEY_FILE}"
CLOUDFLARE_ORIGIN_CERT_ID="cert-old-111"
save_state
rm -f -- "${TMP_DIR}/cloud-revoked-flag" "${TMP_DIR}/renew-revoked-flag"

fault_a_cloud_rc=0
fault_a_cloud_out=$(
    cleanup_files=()
    trap cleanup EXIT
    configure_tcp_acceleration() { :; }
    xhttp_configure_ufw() { :; }
    combined_ensure_dns() { :; }
    combined_issue_certificates() {
        printf 'cert-new-active\n' >"${CERT_FILE}"
        printf 'key-new-active\n' >"${KEY_FILE}"
        CLOUDFLARE_ORIGIN_CERT_ID="cert-new-222"
        CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID="cert-old-111"
    }
    write_xray_config() { :; }
    install_xray_service() { :; }
    gcore_prepare_origin_validation_material() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    combined_validate_cf_node_sni() { :; }
    combined_gcore_resource() { :; }
    combined_validate_gcore() { :; }
    persist_cloudflare_token() { :; }
    persist_globalping_token() { :; }
    refresh_globalping_cache() { :; }
    write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    register_easy_all_command() { :; }
    install_globalping_refresh_timer() { :; }
    cloudflare_finalize_certificate_rotation() {
        assert_equal "fault-A-cloud: rollback flag already disabled before finalize" \
            "0" "${UPDATE_SUB_ROLLBACK_ON_EXIT}"
        printf 'revoked\n' >"${TMP_DIR}/cloud-revoked-flag"
    }
    gcore_clear_api_token() {
        die "注入云端吊销后步骤失败"
    }
    apply_cloud_resources 2>&1
) || fault_a_cloud_rc=$?
[[ "${fault_a_cloud_rc}" -ne 0 ]] \
    || fail "fault-A-cloud: apply_cloud_resources must return non-zero when post-finalize step fails"
assert_contains "fault-A-cloud: error output contains injected failure" \
    "${fault_a_cloud_out}" "注入云端吊销后步骤失败"
assert_equal "fault-A-cloud: finalize recorded revoked" \
    "revoked" "$(<"${TMP_DIR}/cloud-revoked-flag")"
assert_equal "fault-A-cloud: CERT_FILE not rolled back to revoked old cert" \
    "cert-new-active" "$(<"${CERT_FILE}")"
assert_equal "fault-A-cloud: KEY_FILE not rolled back to revoked old key" \
    "key-new-active" "$(<"${KEY_FILE}")"

printf 'cert-old-revoked-2\n' >"${CERT_FILE}"
printf 'key-old-revoked-2\n' >"${KEY_FILE}"
CLOUDFLARE_ORIGIN_CERT_ID="cert-old-222"
save_state

fault_a_renew_rc=0
fault_a_renew_out=$(
    cleanup_files=()
    trap cleanup EXIT
    cloudflare_collect_api_token() { :; }
    cloudflare_lookup_parent_zone() { printf 'zone-123456'; }
    combined_issue_certificates() {
        printf 'cert-renew-active\n' >"${CERT_FILE}"
        printf 'key-renew-active\n' >"${KEY_FILE}"
        CLOUDFLARE_ORIGIN_CERT_ID="cert-renew-333"
        CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID="cert-old-222"
    }
    cloudflare_finalize_certificate_rotation() {
        assert_equal "fault-A-renew: rollback flag already disabled before finalize" \
            "0" "${UPDATE_SUB_ROLLBACK_ON_EXIT}"
        printf 'revoked\n' >"${TMP_DIR}/renew-revoked-flag"
    }
    commit_subscription_update() {
        die "注入续期吊销后步骤失败"
    }
    renew_certificate 2>&1
) || fault_a_renew_rc=$?
[[ "${fault_a_renew_rc}" -ne 0 ]] \
    || fail "fault-A-renew: renew_certificate must return non-zero when post-finalize step fails"
assert_contains "fault-A-renew: error output contains injected failure" \
    "${fault_a_renew_out}" "注入续期吊销后步骤失败"
assert_equal "fault-A-renew: finalize recorded revoked" \
    "revoked" "$(<"${TMP_DIR}/renew-revoked-flag")"
assert_equal "fault-A-renew: CERT_FILE not rolled back to revoked old cert" \
    "cert-renew-active" "$(<"${CERT_FILE}")"
assert_equal "fault-A-renew: KEY_FILE not rolled back to revoked old key" \
    "key-renew-active" "$(<"${KEY_FILE}")"

# 附加验证 4: show_status 证书覆盖检查、缺失/损坏兜底与 Nginx map 一致性检查
show_tcp_acceleration_status() { :; }
show_globalping_status() { :; }

# (a) 证书缺失与损坏时退出码为 0 且输出"未知"
rm -f -- "${CERT_FILE}"
status_missing=$(show_status)
assert_contains "status-missing: missing CERT_FILE prints 未知" \
    "${status_missing}" "Cloudflare 回源证书到期: 未知"

printf 'corrupted-cert-content\n' >"${CERT_FILE}"
status_corrupt=$(show_status)
assert_contains "status-corrupt: corrupted CERT_FILE prints 未知" \
    "${status_corrupt}" "Cloudflare 回源证书到期: 未知"

# (b) 证书有效但未覆盖 CF_NODE_DOMAIN（OpenSSL 3 输出 does NOT match certificate 且 exit 0）时退出码为 0 并提示未覆盖与 apply-cloud
printf 'valid-mock-cert\n' >"${CERT_FILE}"
(
    openssl() {
        case "$*" in
        *-enddate*) printf 'notAfter=Nov  3 00:00:00 2041 GMT\n'; return 0 ;;
        *-checkhost*) printf 'Hostname cfg-node.example.com does NOT match certificate\n'; return 0 ;;
        *) command openssl "$@" ;;
        esac
    }
    status_uncovered_rc=0
    status_uncovered=$(show_status) || status_uncovered_rc=$?
    assert_equal "status-uncovered: show_status exits 0 on uncovered cert" "0" "${status_uncovered_rc}"
    assert_contains "status-uncovered: reports uncovered node domain" \
        "${status_uncovered}" "未覆盖 ${CF_NODE_DOMAIN}"
    assert_contains "status-uncovered: hints sudo easy_all apply-cloud" \
        "${status_uncovered}" "sudo easy_all apply-cloud"
)

# (c) 证书已覆盖 CF_NODE_DOMAIN 且 Nginx 配置与状态一致
(
    openssl() {
        case "$*" in
        *-enddate*) printf 'notAfter=Nov  3 00:00:00 2041 GMT\n'; return 0 ;;
        *-checkhost*) printf 'Hostname cfg-node.example.com does match certificate\n'; return 0 ;;
        *) command openssl "$@" ;;
        esac
    }
    status_covered=$(show_status)
    assert_contains "status-covered: reports covered node domain" \
        "${status_covered}" "已覆盖 ${CF_NODE_DOMAIN}"
    assert_not_contains "status-covered: no inconsistency warning when in sync" \
        "${status_covered}" "运行中配置与状态不一致"
)

# (d) 人为制造 Nginx map 与状态不一致（模拟 SIGKILL 残留），断言 status 提示执行 apply
ALLOWED_TOKENS='{"owner":"stale-nginx-token-999"}'
write_nginx_config
load_state
(
    openssl() {
        case "$*" in
        *-enddate*) printf 'notAfter=Nov  3 00:00:00 2041 GMT\n'; return 0 ;;
        *-checkhost*) printf 'Hostname cfg-node.example.com does match certificate\n'; return 0 ;;
        *) command openssl "$@" ;;
        esac
    }
    status_drift=$(show_status)
    assert_contains "status-drift: detects Nginx map vs state mismatch" \
        "${status_drift}" "运行中配置与状态不一致，请执行 sudo easy_all apply"
)

# 11) 证书 reload 钩子：nginx 未启动时直接返回，不 reload、也不提前 restart
write_cert_reload_hook
hook_text=$(<"${COMMAND_INSTALL_DIR}/reload-tls-service.sh")
assert_contains "reload-hook: exits early when nginx is inactive" \
    "${hook_text}" "systemctl is-active --quiet nginx || exit 0"
legacy_hook=$'set -Eeuo pipefail\nnginx -t >/dev/null || exit 1'
assert_not_contains "reload-hook: no unguarded reload before nginx is started" \
    "${hook_text}" "${legacy_hook}"

# 12) 首次安装路径（不经过 load_state）必须能从 OWNER_TOKEN 派生出 Token 字典
token_map=$(
    unset ALLOWED_TOKENS
    OWNER_TOKEN="tok-first-install-123"
    combined_sync_allowed_tokens
    write_subscription_token_map
)
assert_contains "token-sync: fresh install derives ALLOWED_TOKENS from OWNER_TOKEN" \
    "${token_map}" '"tok-first-install-123" 1;'

# 13) Token 字典缺失时必须给出可操作提示，而不是 set -u 的 unbound variable
guard_out=$(
    unset ALLOWED_TOKENS OWNER_TOKEN
    QUOTA_ENABLED=0
    write_subscription_token_map 2>&1
) || true
assert_contains "token-sync: missing token map fails with actionable message" \
    "${guard_out}" "ALLOWED_TOKENS 未初始化"
assert_not_contains "token-sync: missing token map must not surface unbound variable" \
    "${guard_out}" "unbound variable"

# 14) 订阅格式协商：渲染结果必须含 UA 判断与 flag 覆盖，且默认回落到 Base64
write_nginx_config
nginx_text=$(<"${NGINX_CONFIG}")
# 按 map 块逐条断言：只看"某行存在"会被同文件其它 map 的相同行掩盖
map_block() {
    local head=$1
    awk -v head="${head}" '
        $0 == head { inside = 1; next }
        inside && /^}/ { exit }
        inside && /^[[:space:]]*#/ { next }
        inside { print }
    ' <<<"${nginx_text}"
}

ua_block=$(map_block 'map $http_user_agent $easy_all_subscription_ua_format {')
forced_block=$(map_block 'map $arg_flag $easy_all_subscription_forced_format {')
merged_block=$(map_block 'map $easy_all_subscription_forced_format $easy_all_subscription_format {')
format_block=$(map_block 'map $easy_all_subscription_format $easy_all_subscription_uri {')

assert_block_line() {
    local label=$1 block=$2 expected=$3
    grep -Fxq -- "${expected}" <<<"${block}" \
        || fail "${label}: missing effective line <${expected}> in <${block}>"
}

assert_contains "ua-negotiation: clash-family UA gets yaml" \
    "${ua_block}" '~*(clash|mihomo|stash|flclash|verge|bettbox) "mihomo"'
assert_block_line "ua-negotiation: unknown UA defaults to base64" \
    "${ua_block}" '    default "base64";'
assert_block_line "ua-negotiation: clash flag forces yaml" \
    "${forced_block}" '    clash        "mihomo";'
assert_block_line "ua-negotiation: base64 flag forces base64" \
    "${forced_block}" '    base64       "base64";'
assert_block_line "ua-negotiation: no flag adds no forced value" \
    "${forced_block}" '    default      "";'
assert_block_line "ua-negotiation: merged map defaults to UA result" \
    "${merged_block}" '    default  $easy_all_subscription_ua_format;'
assert_block_line "ua-negotiation: format map default routes to base64 file" \
    "${format_block}" '    default  /_easy_all_subscription/base64;'
assert_block_line "ua-negotiation: mihomo format routes to yaml file" \
    "${format_block}" '    "mihomo" /_easy_all_subscription/mihomo;'

# 15) 自定义订阅 Token 可选输入：合法值被采纳，非法值被拒绝（且不改动当前 Token）
(
    kept=${OWNER_TOKEN}
    combined_apply_tokens '{"owner":"custom-token-2026"}'
    [[ "${OWNER_TOKEN}" == "custom-token-2026" ]] \
        || fail "token-input: valid custom token not applied"
    if combined_apply_tokens '{"owner":"short"}' 2>/dev/null; then
        fail "token-input: too-short token must be rejected"
    fi
    [[ "${OWNER_TOKEN}" == "custom-token-2026" ]] \
        || fail "token-input: rejected input must not change current token"
    OWNER_TOKEN=${kept}
    combined_sync_allowed_tokens
)

# 16) 安装期零交互：参数声明里不得出现任何提示函数（交互安装已移除）
install_inputs_body=$(awk '/^collect_install_inputs\(\)/,/^}/' "${PROFILE}")
assert_not_contains "token-input: install inputs never prompt" \
    "${install_inputs_body}" "prompt_"
assert_not_contains "token-input: install inputs never read stdin" \
    "${install_inputs_body}" "read_bilingual"
assert_contains "token-input: install inputs declare the token fields" \
    "${install_inputs_body}" "params_declare OWNER_TOKEN"

# 17) 安装阶段 Token 校验：非法值必须在改动云端资源前就被拒绝
bad_install=$(
    ALLOWED_TOKENS=""
    OWNER_TOKEN="short"
    combined_validate_install_owner_token 2>&1
) || true
assert_contains "token-validate: short env token rejected before install" \
    "${bad_install}" "订阅 Token 无效"
assert_not_contains "token-validate: rejection mentions auto-generate fallback" \
    "${bad_install}" "unbound variable"
# 安装入口必须真的调用该校验（否则非法 Token 仍会一路跑到签发/写配置阶段）
apply_inputs_body=$(awk '/^apply_install_inputs\(\)/,/^}/' "${PROFILE}")
assert_contains "token-validate: install inputs call the validator" \
    "${apply_inputs_body}" "combined_validate_install_owner_token"
(
    ALLOWED_TOKENS=""
    OWNER_TOKEN="custom-token-2026"
    combined_validate_install_owner_token \
        || fail "token-validate: valid env token must pass"
)
bad_chars=$(
    ALLOWED_TOKENS=""
    OWNER_TOKEN='bad;token"x'
    combined_validate_install_owner_token 2>&1
) || true
assert_contains "token-validate: unsafe characters rejected" "${bad_chars}" "订阅 Token 无效"

# 18) edit-sub 入口同时接受纯字符串与单用户 JSON，多用户字典必须明确拒绝
plain_out=$(
    OWNER_TOKEN="placeholder-0000"
    combined_apply_tokens "my_plain_token_123"
    jq -r '.owner' <<<"${ALLOWED_TOKENS}"
)
assert_equal "token-input: plain string accepted in edit-sub" \
    "my_plain_token_123" "${plain_out}"

single_json_out=$(
    combined_apply_tokens '{"alice":"alice-token-123"}' >/dev/null 2>&1
    jq -r 'to_entries | map(.key + "=" + .value) | join(",")' <<<"${ALLOWED_TOKENS}"
)
assert_equal "token-input: single-user JSON keeps its user name" \
    "alice=alice-token-123" "${single_json_out}"

multi_out=$(
    combined_apply_tokens '{"user1":"token-aaaa-111","user2":"token-bbbb-222"}' >/dev/null 2>&1
    jq -r 'length' <<<"${ALLOWED_TOKENS}"
)
assert_equal "token-input: multi-user JSON keeps every user" "2" "${multi_out}"

multi_owner=$(
    combined_apply_tokens '{"user1":"token-aaaa-111","user2":"token-bbbb-222"}' >/dev/null 2>&1
    printf '%s' "${OWNER_TOKEN}"
)
assert_equal "token-input: OWNER_TOKEN follows the first dictionary entry" \
    "token-aaaa-111" "${multi_owner}"

# 19) 历史状态里的非法 Token：load_state 只告警（否则 edit-sub / uninstall 都进不去），写配置前才强校验
bad_state=$(
    OWNER_TOKEN="short"
    ALLOWED_TOKENS=""
    save_state
    load_state 2>&1
    printf 'load_rc=%s' "$?"
) || true
assert_contains "token-validate: invalid state token warns on load" \
    "${bad_state}" "状态文件中的订阅 Token 不符合"
assert_contains "token-validate: load_state still succeeds for recovery" \
    "${bad_state}" "load_rc=0"
blocked_write=$(
    OWNER_TOKEN="short"
    ALLOWED_TOKENS=""
    write_nginx_config 2>&1
) || true
assert_contains "token-validate: writing nginx config rejects invalid token" \
    "${blocked_write}" "订阅 Token 无效"

# 20) 恢复闭环：非法旧状态能通过 edit-sub 的路径换成合法 Token 并成功落盘
recovered=$(
    OWNER_TOKEN="short"
    ALLOWED_TOKENS=""
    save_state
    load_state >/dev/null 2>&1
    combined_apply_tokens "restored-token-4821" >/dev/null 2>&1 \
        || fail "token-recovery: valid replacement rejected"
    write_nginx_config >/dev/null 2>&1 || fail "token-recovery: write failed after replacement"
    save_state
    load_state >/dev/null 2>&1 || fail "token-recovery: reload after replacement failed"
    printf '%s' "${OWNER_TOKEN}"
)
assert_equal "token-recovery: invalid old state fixed through edit-sub path" \
    "restored-token-4821" "${recovered}"

# 21) 直接写订阅或状态的入口（定时刷新 / 续签 / 改 Reality 目标）在非法旧 Token 下也必须早退
(
    OWNER_TOKEN="short"
    ALLOWED_TOKENS=""
    save_state
)
for entry in refresh_combined_cdn_ips renew_certificate; do
    entry_out=$(
        load_state >/dev/null 2>&1
        "${entry}" 2>&1
    ) || true
    assert_contains "token-validate: ${entry} rejects invalid state token" \
        "${entry_out}" "订阅 Token 无效"
done
reality_out=$(
    load_state >/dev/null 2>&1
    update_reality_target "example.com:443" 2>&1
) || true
assert_contains "token-validate: update_reality_target rejects invalid state token" \
    "${reality_out}" "订阅 Token 无效"
# 恢复合法状态，避免影响后续用例
(
    OWNER_TOKEN="restored-token-4821"
    combined_sync_allowed_tokens
    save_state
)

# 22) nginx 判定（src/http/ngx_http.c:1351）：同一 addr:port 上两条 listen 只要都带套接字参数
#     （会置 lsopt.set=1 的 backlog/so_keepalive/reuseport/bind/ipv6only/deferred/fastopen/sndbuf/
#      rcvbuf/setfib/multipath/accept_filter），即报 "duplicate listen options"，与参数值是否相同无关。
#     因此套接字参数最多出现在一条 listen 上；所有 443 块都必须带 ssl。
#     Gcore 回源块只跑 WebSocket，现代 nginx 必须按 server 关掉 HTTP/2；旧版 listen http2 是
#     地址级联集（ngx_http.c:1343 取或），关不掉，所以旧版分支不得假称已隔离。
server_block_for() {   # $1 = server_name 里要精确匹配的域名
    # 只读真实 server_name 指令：剔除整行注释，逐字段去分号后做字符串相等比较。
    # 不能把域名拼进正则（`.` 会变成通配符），也不能对整块做正则匹配（注释里的域名会抢先命中）。
    awk -v dom="$1" '
        /^server \{/ { block=""; inblock=1; hit=0 }
        inblock {
            block = block $0 "\n"
            line = $0
            if (line ~ /^[[:space:]]*#/) next
            if (line ~ /^[[:space:]]*server_name[[:space:]]/) {
                n = split(line, f, /[[:space:]]+/)
                for (i = 1; i <= n; i++) {
                    g = f[i]; sub(/;$/, "", g)
                    if (g == dom) hit = 1
                }
            }
        }
        /^\}/ { if (inblock && hit) { printf "%s", block; exit } inblock=0 }
    ' "${NGINX_CONFIG}"
}

write_nginx_config
socket_opt_count=$(grep -E '^[[:space:]]*listen[[:space:]]+443' "${NGINX_CONFIG}" \
    | grep -Ec 'backlog=|so_keepalive|reuseport|ipv6only|deferred|fastopen|sndbuf|rcvbuf|setfib|multipath|accept_filter|\bbind\b' || true)
[[ "${socket_opt_count}" == "1" ]] \
    || fail "nginx-listen: socket options must appear on exactly one 443 listen (found ${socket_opt_count})"
missing_ssl=$(grep -E '^[[:space:]]*listen[[:space:]]+443' "${NGINX_CONFIG}" \
    | grep -Evc '\bssl\b' || true)
[[ "${missing_ssl}" == "0" ]] \
    || fail "nginx-listen: 每个 443 listen 都必须带 ssl（缺 ${missing_ssl} 处）"

# 现代分支（>= 1.25.1）：Gcore 块关 h2，Cloudflare 块必须留 h2（gRPC 依赖）
(
    nginx_supports_http2_directive() { return 0; }
    write_nginx_config
    cf_block=$(server_block_for "${CF_NODE_DOMAIN}")
    gcore_block=$(server_block_for "${GCORE_ORIGIN_DOMAIN}")
    [[ -n "${cf_block}" ]] || fail "nginx-listen: 未找到 Cloudflare 块"
    [[ -n "${gcore_block}" ]] || fail "nginx-listen: 未找到 Gcore 回源块"
    assert_contains "nginx-listen: Cloudflare 块保留 http2 指令" \
        "${cf_block}" $'\n    http2 on;'
    assert_not_contains "nginx-listen: Gcore 块不得启用 http2 指令" \
        "${gcore_block}" $'\n    http2 on;'
    gcore_listen_h2=$(printf '%s\n' "${gcore_block}" \
        | grep -E '^[[:space:]]*listen[[:space:]]+443' | grep -c 'http2' || true)
    [[ "${gcore_listen_h2}" == "0" ]] \
        || fail "nginx-listen: 现代分支的 Gcore 块 listen 不得带 http2（找到 ${gcore_listen_h2} 行）"
    assert_contains "nginx-listen: Gcore 块保持 HTTP/1.1 WebSocket 升级" \
        "${gcore_block}" "proxy_http_version 1.1;"
    assert_contains "nginx-listen: Gcore 块启用 mTLS 客户端校验" \
        "${gcore_block}" "ssl_verify_client on;"
)

# 旧版分支（< 1.25.1）：listen http2 是 socket 级，所有 443 块必须一致，不能出现无效隔离
(
    nginx_supports_http2_directive() { return 1; }
    write_nginx_config
    legacy_h2_count=$(grep -E '^[[:space:]]*listen[[:space:]]+443' "${NGINX_CONFIG}" \
        | grep -c 'http2 ' || true)
    legacy_443_count=$(grep -Ec '^[[:space:]]*listen[[:space:]]+443' "${NGINX_CONFIG}" || true)
    [[ "${legacy_h2_count}" == "${legacy_443_count}" ]] \
        || fail "nginx-listen: 旧版分支的 listen http2 必须对所有 443 块一致（${legacy_h2_count}/${legacy_443_count}）"
)

write_nginx_config   # 恢复默认渲染，供后续用例使用

# 23) 多用户 Token 字典必须能持久化并在重新加载后保持
multi_state=$(
    combined_apply_tokens '{"user1":"token-aaaa-111","user2":"token-bbbb-222"}' >/dev/null 2>&1 \
        || fail "multi-token: dictionary rejected"
    save_state
    ALLOWED_TOKENS=""
    OWNER_TOKEN=""
    load_state >/dev/null 2>&1 || fail "multi-token: reload failed"
    jq -r 'to_entries | map(.key + "=" + .value) | join(",")' <<<"${ALLOWED_TOKENS}"
)
assert_equal "multi-token: dictionary survives save/load" \
    "user1=token-aaaa-111,user2=token-bbbb-222" "${multi_state}"
multi_map=$(
    combined_apply_tokens '{"user1":"token-aaaa-111","user2":"token-bbbb-222"}' >/dev/null 2>&1
    write_nginx_config >/dev/null 2>&1 || fail "multi-token: nginx render failed"
    grep -c '^    "token-bbbb-222" 1;$' "${NGINX_CONFIG}"
)
assert_equal "multi-token: every token is published in the nginx map" "1" "${multi_map}"

# 24) JSON 内部空白必须保留：含空格的用户名要被拒绝，且原字典不被改写
space_out=$(
    combined_apply_tokens '{"keep1":"token-aaaa-111"}' >/dev/null 2>&1
    before=${ALLOWED_TOKENS}
    # 安装已无交互入口；直接验证 Token 解析本身只裁键首尾空白，不压内部空格
    if combined_apply_tokens '  {"user 1":"abcdefgh","user1":"ijklmnop"}  ' >/dev/null 2>&1; then
        printf 'accepted'
    else
        printf 'rejected:%s' "$([[ "${ALLOWED_TOKENS}" == "${before}" ]] && echo unchanged || echo changed)"
    fi
) || true
assert_equal "multi-token: user name with inner space is rejected" \
    "rejected:unchanged" "${space_out}"

pretty_out=$(
    combined_apply_tokens '{ "user1" : "alice-token-123" , "user2" : "token-bbbb-222" }' >/dev/null 2>&1 \
        || fail "multi-token: pretty-printed JSON rejected"
    jq -r 'length' <<<"${ALLOWED_TOKENS}"
)
assert_equal "multi-token: pretty-printed JSON still accepted" "2" "${pretty_out}"

# 25) 首次安装不经过 load_state，combined_gcore_resource 不能假设 SUBSCRIPTION_MODE / VLESS_CDN_DOMAIN 已定义
#     （2.3.4 现场：line 573 "SUBSCRIPTION_MODE: unbound variable"，set -u 下安装中断并触发回滚）
gcore_stub_fail=0
gcore_collect_api_token() { :; }
gcore_edge_certificate_id() { printf 'edge-cert-1'; }
gcore_ensure_origin_validation_certificates() { :; }
gcore_ensure_origin_group() { :; }
gcore_ensure_resource() { return "${gcore_stub_fail}"; }

fresh_gcore=$(
    unset SUBSCRIPTION_MODE VLESS_CDN_DOMAIN
    GCORE_NODE_DOMAIN="gcore.example.com"
    combined_gcore_resource || exit 3
    printf 'rc=0 sub=%s domain=%s' \
        "${SUBSCRIPTION_MODE-<unset>}" "${VLESS_CDN_DOMAIN-<unset>}"
) || fail "gcore-resource: 变量未定义时不应在 set -u 下崩溃（rc=$?）"
assert_equal "gcore-resource: 未定义的 SUBSCRIPTION_MODE 结束后仍是 unset" \
    "rc=0 sub=<unset> domain=<unset>" "${fresh_gcore}"

preserved_gcore=$(
    SUBSCRIPTION_MODE="worker"
    VLESS_CDN_DOMAIN="cf.example.com"
    GCORE_NODE_DOMAIN="gcore.example.com"
    combined_gcore_resource || exit 3
    printf 'sub=%s domain=%s' "${SUBSCRIPTION_MODE}" "${VLESS_CDN_DOMAIN}"
) || fail "gcore-resource: 已定义变量时应正常返回"
assert_equal "gcore-resource: 已定义的 SUBSCRIPTION_MODE 原样恢复" \
    "sub=worker domain=cf.example.com" "${preserved_gcore}"

# 已定义但为空串：必须还原成空串（不是 unset，也不是 link）
empty_gcore=$(
    SUBSCRIPTION_MODE=""
    VLESS_CDN_DOMAIN=""
    GCORE_NODE_DOMAIN="gcore.example.com"
    combined_gcore_resource || exit 3
    printf 'sub=[%s] set=%s domain=[%s] set=%s' \
        "${SUBSCRIPTION_MODE}" "$([[ -n "${SUBSCRIPTION_MODE+x}" ]] && echo y || echo n)" \
        "${VLESS_CDN_DOMAIN}" "$([[ -n "${VLESS_CDN_DOMAIN+x}" ]] && echo y || echo n)"
) || fail "gcore-resource: 空串值也应正常返回"
assert_equal "gcore-resource: 空串保持为空串且仍处于已定义状态" \
    "sub=[] set=y domain=[] set=y" "${empty_gcore}"

# 失败分支：真实捕获退出码，不写死 rc=1
gcore_stub_fail=1
failed_gcore=$(
    unset SUBSCRIPTION_MODE
    VLESS_CDN_DOMAIN="cf.example.com"
    GCORE_NODE_DOMAIN="gcore.example.com"
    if combined_gcore_resource; then rc=0; else rc=$?; fi
    printf 'rc=%s sub=%s domain=%s' "${rc}" \
        "${SUBSCRIPTION_MODE-<unset>}" "${VLESS_CDN_DOMAIN-<unset>}"
)
assert_equal "gcore-resource: ensure_resource 失败返回 1 并还原变量" \
    "rc=1 sub=<unset> domain=cf.example.com" "${failed_gcore}"

# 首个证书查询就失败时同样要还原
gcore_stub_fail=0
gcore_edge_certificate_id() { return 1; }
cert_failed_gcore=$(
    unset SUBSCRIPTION_MODE
    VLESS_CDN_DOMAIN="cf.example.com"
    GCORE_NODE_DOMAIN="gcore.example.com"
    if combined_gcore_resource; then rc=0; else rc=$?; fi
    printf 'rc=%s sub=%s domain=%s certid=%s' "${rc}" \
        "${SUBSCRIPTION_MODE-<unset>}" "${VLESS_CDN_DOMAIN-<unset>}" \
        "${GCORE_EDGE_CERTIFICATE_ID-<unset>}"
)
assert_equal "gcore-resource: 证书查询失败返回 1 并还原变量" \
    "rc=1 sub=<unset> domain=cf.example.com certid=" "${cert_failed_gcore}"
gcore_edge_certificate_id() { printf 'edge-cert-1'; }

# 25d) 组合模式的 Gcore 边缘证书必须走 HTTP-01，且只覆盖节点域名。
#      现场报错：`_acme-challenge.<域名> is not delegated to the Gcore nameservers`——组合模式的
#      Zone 留在 Cloudflare，没有向 Gcore 委派 `_acme-challenge`，DNS-01 必然失败。
#      订阅域名是橙云 A 指向 VPS，Gcore 也无法用 HTTP-01 验证它。
gcore_policy_out=$(
    # 上面的用例把 gcore_ensure_resource 等高层函数换成了 stub；这里恢复 lib 里的真实实现。
    source "${ROOT_DIR}/lib/gcore-cdn.sh"
    VLESS_CDN_DOMAIN="gcore-node.example.com"
    GCORE_ORIGIN_DOMAIN="gcore-origin.example.com"
    GCORE_ORIGIN_GROUP_ID=101
    GCORE_ORIGIN_CLIENT_CERT_ID=11223
    GCORE_ORIGIN_CA_ID=44556
    GCORE_EDGE_CERTIFICATE_ID=""
    GCORE_CDN_RESOURCE_ID=""
    bootstrap_out="${TMP_DIR}/gcore-policy-bootstrap.json"
    sleep() { :; }
    gcore_edge_certificate_id() { printf '303'; }
    gcore_api_request() {
        local call="$1 $2" payload=${3:-}
        if [[ "${call}" == "GET /cdn/resources" ]]; then
            printf '[]'
        elif [[ "${call}" == "POST /cdn/resources" ]]; then
            printf '%s' "${payload}" >"${bootstrap_out}"
            printf '{"id":202}'
        elif [[ "${call}" == "GET /cdn/sslData/303/status" ]]; then
            printf '{"active":true,"latest_status":{"status":"DONE"}}'
        elif [[ "${call}" == "PUT /cdn/resources/202" ]]; then
            :
        else
            return 1
        fi
    }
    gcore_ensure_resource >/dev/null 2>&1 || exit 3
    jq -c '{hosts: .secondaryHostnames, dns01: .options.use_dns01_le_challenge,
            redirect: .options.redirect_http_to_https}' "${bootstrap_out}"
) || fail "gcore-policy: ensure_resource failed"
assert_equal "gcore-policy: 组合模式边缘证书走 HTTP-01 且只覆盖节点域名" \
    '{"hosts":[],"dns01":{"enabled":false,"value":false},"redirect":{"enabled":false,"value":false}}' \
    "${gcore_policy_out}"

# 25e) 上次安装留下 FAILED 边缘证书时，重新安装必须先落新配置再强制重试一次，而不是立即终止。
gcore_retry_out=$(
    source "${ROOT_DIR}/lib/gcore-cdn.sh"
    VLESS_CDN_DOMAIN="gcore-node.example.com"
    GCORE_ORIGIN_DOMAIN="gcore-origin.example.com"
    GCORE_ORIGIN_GROUP_ID=101
    GCORE_ORIGIN_CLIENT_CERT_ID=11223
    GCORE_ORIGIN_CA_ID=44556
    GCORE_EDGE_CERTIFICATE_ID=""
    GCORE_CDN_RESOURCE_ID=""
    api_calls="${TMP_DIR}/gcore-retry-calls"
    full_out="${TMP_DIR}/gcore-retry-full.json"
    poll_file="${TMP_DIR}/gcore-retry-polls"
    : >"${api_calls}"
    : >"${poll_file}"
    sleep() { :; }
    gcore_api_raw() {
        local call="$1 $2"
        printf 'RAW %s\n' "${call}" >>"${api_calls}"
        if [[ "${call}" == "POST /cdn/sslData/303/force-retry" ]]; then
            printf '\n201'
        else
            printf '\n500'
        fi
    }
    gcore_api_request() {
        local call="$1 $2" payload=${3:-}
        printf '%s\n' "${call}" >>"${api_calls}"
        if [[ "${call}" == "GET /cdn/resources" ]]; then
            printf '[{"id":202,"cname":"gcore-node.example.com","sslData":303}]'
        elif [[ "${call}" == "GET /cdn/resources/202" ]]; then
            printf '{"id":202,"cname":"gcore-node.example.com","sslData":303}'
        elif [[ "${call}" == "PUT /cdn/resources/202" ]]; then
            if jq -e '.options.redirect_http_to_https.enabled' <<<"${payload}" >/dev/null; then
                printf 'PUT full\n' >>"${api_calls}"
                printf '%s' "${payload}" >"${full_out}"
            else
                printf 'PUT bootstrap\n' >>"${api_calls}"
            fi
            printf '{"id":202}'
        elif [[ "${call}" == "GET /cdn/sslData/303/status" ]]; then
            # 每次状态查询都在命令替换的子 shell 里执行，计数必须落盘。
            printf 'x' >>"${poll_file}"
            if (($(wc -c <"${poll_file}") <= 4)); then
                printf '{"latest_status":{"status":"FAILED","error":"ValidationIssue","details":"boom"}}'
            else
                printf '{"active":true,"latest_status":{"status":"DONE"}}'
            fi
        else
            return 1
        fi
    }
    gcore_ensure_resource >/dev/null 2>&1 || exit 3
    bootstrap_line=$(grep -n '^PUT bootstrap$' "${api_calls}" | cut -d: -f1)
    retry_line=$(grep -n '^RAW POST /cdn/sslData/303/force-retry$' "${api_calls}" | cut -d: -f1)
    full_line=$(grep -n '^PUT full$' "${api_calls}" | cut -d: -f1)
    order=bad
    if [[ -n "${bootstrap_line}" && -n "${retry_line}" && -n "${full_line}" ]] \
        && ((bootstrap_line < retry_line && retry_line < full_line)); then
        order=ok
    fi
    printf 'order=%s dns01=%s hosts=%s redirect=%s retries=%s' "${order}" \
        "$(jq -r '.options.use_dns01_le_challenge.value' "${full_out}")" \
        "$(jq -c '.secondaryHostnames' "${full_out}")" \
        "$(jq -r '.options.redirect_http_to_https.value' "${full_out}")" \
        "$(grep -c '^RAW POST /cdn/sslData/303/force-retry$' "${api_calls}")"
) || fail "gcore-retry: FAILED 证书重装路径失败"
assert_equal "gcore-retry: 先落新配置、强制重试一次、证书激活后再开 HTTPS 跳转" \
    "order=ok dns01=false hosts=[] redirect=true retries=1" "${gcore_retry_out}"

# 26) token 首字符不能是 ~（nginx map 把 ~ 开头的键当正则），中间 ~ 仍允许
tilde_out=$(
    if combined_apply_tokens '~token-aaaa-111' >/dev/null 2>&1; then
        printf 'accepted'
    else
        printf 'rejected'
    fi
)
assert_equal "token: leading tilde is rejected" "rejected" "${tilde_out}"

# JSON 字典分支走 lib/subscription-auth.sh 的 normalize_allowed_tokens，必须同样拒绝首 ~
tilde_json=$(
    if combined_apply_tokens '{"owner":"~token-aaaa-111"}' >/dev/null 2>&1; then
        printf 'accepted'
    else
        printf 'rejected'
    fi
)
assert_equal "token: leading tilde is rejected in JSON dictionary" "rejected" "${tilde_json}"
tilde_ok=$(
    combined_apply_tokens 'tok~en-inner-9931' >/dev/null 2>&1 || fail "token: inner tilde must stay valid"
    jq -r '.[]' <<<"${ALLOWED_TOKENS}"
)
assert_equal "token: inner tilde still accepted" "tok~en-inner-9931" "${tilde_ok}"

# 27) 本机回环探活必须绕过 http_proxy：--resolve 只改解析，不改代理语义
# 逐元素校验：必须存在相邻的 --noproxy 与 *，不能只靠展平后的子串匹配
(
    CF_CA_ROOT_FILE="/tmp/ca-root.pem"
    cloudflare_ensure_origin_ca_root() { :; }
    xhttp_validate_local_tls_curl_args
    noproxy_found=0
    for ((i = 0; i < ${#XHTTP_LOCAL_TLS_CURL_ARGS[@]}; i++)); do
        if [[ "${XHTTP_LOCAL_TLS_CURL_ARGS[i]}" == "--noproxy" \
            && "${XHTTP_LOCAL_TLS_CURL_ARGS[i + 1]:-}" == "*" ]]; then
            noproxy_found=1
        fi
    done
    [[ "${noproxy_found}" == "1" ]] \
        || fail "curl-args: local TLS probe must pass --noproxy '*'"
) || fail "curl-args: --noproxy assertion failed"

# 28) 安装参数模板：combined 的声明必须能生成合法模板，必填字段留空
template_json=$(
    params_template_begin combined
    collect_install_inputs >/dev/null 2>&1 || fail "template: declarations failed"
    params_finish 2>/dev/null
) || fail "template: combined template generation failed"
assert_equal "template: mode" "combined" "$(jq -r '.mode' <<<"${template_json}")"
assert_equal "template: required field empty" "" \
    "$(jq -r '.params.CF_ZONE' <<<"${template_json}")"
assert_equal "template: download name default" "EASY_ALL" \
    "$(jq -r '.params.SUB_DOWNLOAD_NAME' <<<"${template_json}")"
for key in CF_ZONE CLOUDFLARE_API_TOKEN GCORE_API_TOKEN GLOBALPING_TOKEN \
    DIRECT_DOMAIN SUBSCRIPTION_DOMAIN ALLOWED_TOKENS; do
    jq -e --arg k "${key}" '.params | has($k)' <<<"${template_json}" >/dev/null \
        || fail "template: missing field ${key}"
done

# 29) 完整参数预检：真实声明 + 默认值 + 跨字段校验 + 赋值一次跑通
cat >"${TMP_DIR}/params-ok.json" <<'JSON'
{
  "schema_version": 1,
  "mode": "combined",
  "params": {
    "CF_ZONE": "example.com",
    "CLOUDFLARE_API_TOKEN": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "GCORE_API_TOKEN": "gcore-token-value",
    "GLOBALPING_TOKEN": "globalping-token-value",
    "VPS_PUBLIC_IPV4": "203.0.113.10",
    "ALLOWED_TOKENS": {"owner": "abcdefgh-1234"}
  }
}
JSON
chmod 600 "${TMP_DIR}/params-ok.json"
preflight_out=$(
    params_begin combined "${TMP_DIR}/params-ok.json"
    collect_install_inputs
    params_finish 2>/dev/null
    printf '%s|%s|%s|%s|%s\n' \
        "${CF_ZONE}" "${DIRECT_DOMAIN}" "${CF_ORIGIN_DOMAIN}" "${XHTTP_PATH}" "${REBOOT_SCHEDULE_MODE}"
) || fail "preflight: valid combined params rejected"
assert_equal "preflight: defaults derived from zone" \
    "example.com|node.example.com|cf-origin.example.com" \
    "$(cut -d'|' -f1-3 <<<"${preflight_out}")"
assert_contains "preflight: xhttp path generated" "${preflight_out}" "/xhttp-"
assert_equal "preflight: reboot default" "1" "$(cut -d'|' -f5 <<<"${preflight_out}")"

# 30) 预检必须聚合错误：域名重复、域名不在 Zone 下、两个 Token 同时提供
jq '.params.CF_NODE_DOMAIN = "node.example.com"
    | .params.SUBSCRIPTION_DOMAIN = "elsewhere.invalid"
    | .params.OWNER_TOKEN = "abcdefgh-1234"' \
    "${TMP_DIR}/params-ok.json" >"${TMP_DIR}/params-bad.json"
chmod 600 "${TMP_DIR}/params-bad.json"
preflight_bad=$(
    exec 2>&1
    params_begin combined "${TMP_DIR}/params-bad.json"
    collect_install_inputs
    params_finish
) && fail "preflight: invalid combined params must be rejected"
assert_contains "preflight: duplicate domains" "${preflight_bad}" "六个域名必须互不相同"
assert_contains "preflight: domain outside zone" "${preflight_bad}" "域名必须属于 example.com"
assert_contains "preflight: mutually exclusive tokens" "${preflight_bad}" "不能同时提供"

printf 'ok - combined render\n'


