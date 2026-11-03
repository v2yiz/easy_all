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
XRAY_XHTTP_LOOPBACK_PORT="${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}"
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
    assert_contains "10d-false: legacy listen http2 present" "${conf_false}" "listen 443 ssl http2 default_server;"
    assert_contains "10d-false: legacy listen http2 on XHTTP server" "${conf_false}" "listen 443 ssl http2 backlog=4096"
    assert_not_contains "10d-false: modern http2 directive absent" "${conf_false}" "http2 on;"
)

# 10e) combined_apply_owner_token 切换后 write_subscription_token_map 只含新值不含旧值
# 注：normalize_allowed_tokens（lib/subscription-auth.sh:113）要求 token 长度 8-128，故用 token-A-123456 / token-B-123456
ALLOWED_TOKENS='{"owner":"token-A-123456"}'
OWNER_TOKEN="token-A-123456"
combined_apply_owner_token '{"owner":"token-B-123456"}' \
    || fail "10e: valid token should be accepted by combined_apply_owner_token"
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
    if combined_apply_owner_token "${invalid_json}" 2>/dev/null; then
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

printf 'ok - combined render\n'
