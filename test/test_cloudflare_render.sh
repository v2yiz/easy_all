#!/usr/bin/env bash
# Cloudflare 橙云链路（模式 3 / 5）回归测试：状态契约、launcher 接线、
# 单域名 Nginx 渲染、Xray 入站、六种订阅产物（单 CDN 节点、无优选分组）、
# Origin CA 复用需链验证、云端清理的归属判定与清理顺序。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
MODE3_PROFILE="${ROOT_DIR}/profiles/cloudflare.sh"
MODE5_PROFILE="${ROOT_DIR}/profiles/combined-cloudflare.sh"
CORE="${ROOT_DIR}/lib/cloudflare-mode.sh"
STATE_LIB="${ROOT_DIR}/lib/cloudflare-state.sh"

TMP_DIR=${EASY_ALL_TEST_TMP_DIR:-$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_cloudflare_test.XXXXXX")}
TMP_DIR_CREATED=1
[[ -z "${EASY_ALL_TEST_TMP_DIR:-}" ]] || TMP_DIR_CREATED=0
mktemp() {
    if [[ $# -eq 0 ]]; then
        command mktemp "${TMP_DIR}/file.XXXXXX"
    elif [[ $# -eq 1 && "$1" == "-d" ]]; then
        command mktemp -d "${TMP_DIR}/dir.XXXXXX"
    else
        command mktemp "$@"
    fi
}
trap '((TMP_DIR_CREATED == 0)) || command rm -rf -- "${TMP_DIR}"' EXIT

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
assert_count() {
    local label=$1 text=$2 needle=$3 expected=$4 actual
    actual=$(grep -cF -- "${needle}" <<<"${text}" || true)
    [[ "${actual}" == "${expected}" ]] \
        || fail_test "${label}: expected ${expected} <${needle}> but got ${actual}"
}

bash -n "${MODE3_PROFILE}" "${MODE5_PROFILE}" "${CORE}" "${STATE_LIB}" "${ROOT_DIR}/easy_all"

# --- 1. launcher / manifest / 状态字段单一来源 -------------------------------
launcher_body=$(<"${ROOT_DIR}/easy_all")
menu_body=$(awk '/^choose_install_mode\(\)/,/^}/' "${ROOT_DIR}/easy_all")
assert_contains "菜单 3 映射到 cloudflare" "${menu_body}" "3) printf 'cloudflare\\n' ;;"
assert_contains "菜单 5 映射到 combined-cloudflare" "${menu_body}" "5) printf 'combined-cloudflare\\n' ;;"
assert_contains "detect 识别 cloudflare" "${launcher_body}" "cloudflare)"
assert_contains "detect 识别 combined-cloudflare" "${launcher_body}" "combined-cloudflare)"
assert_contains "状态字段来自 cloudflare-state.sh" "${launcher_body}" "cloudflare_state_required_fields"
assert_contains "Cloudflare 状态完整性不分派 985GB 熔断" "${launcher_body}" \
    "launcher_cloudflare_state_complete"
assert_contains "profile_file 映射模式 3" "${launcher_body}" \
    "profiles/cloudflare.sh"
assert_contains "profile_file 映射模式 5" "${launcher_body}" \
    "profiles/combined-cloudflare.sh"
assert_contains "不完整 Cloudflare 状态走本机卸载" "${launcher_body}" \
    "uninstall_incomplete_cloudflare"
assert_contains "Cloudflare 不走 cdn-traffic-sync" "${launcher_body}" \
    "cdn-traffic-sync 仅适用于 CloudFront 模式"

manifest_body=$(<"${ROOT_DIR}/runtime.manifest")
for entry in lib/cloudflare-state.sh lib/cloudflare-mode.sh \
    profiles/cloudflare.sh profiles/combined-cloudflare.sh; do
    assert_contains "manifest 登记 ${entry}" "${manifest_body}" "${entry}"
done
assert_not_contains "manifest 仍不登记优选库" "${manifest_body}" "lib/cloudflare-ip-pool.sh"
assert_not_contains "manifest 仍不登记 Globalping" "${manifest_body}" "lib/globalping-cdn.sh"

package_body=$(<"${ROOT_DIR}/package.json")
assert_contains "npm test 接入 Cloudflare 测试" "${package_body}" "test_cloudflare_render.sh"

# --- 2. 隔离运行环境 ---------------------------------------------------------
export STATE_DIR="${TMP_DIR}/state"
export BACKUP_DIR="${STATE_DIR}/backups"
export STATE_FILE="${STATE_DIR}/state.env"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/fullchain.pem"
export KEY_FILE="${CERT_DIR}/private.key"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export COMMAND_INSTALL_DIR="${TMP_DIR}/lib"
export XRAY_DIR="${STATE_DIR}/xray"
export XRAY_BIN="${TMP_DIR}/fake-xray"
export XRAY_CONFIG="${XRAY_DIR}/config.json"
export XRAY_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-xray.service"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP_DIR}/runtime-write.lock"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress/install-progress.env"
export EASY_ALL_NGINX_MAIN_CONF="${TMP_DIR}/nginx-main/nginx.conf"
export FAKE_SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"
export FAKE_UFW_LOG="${TMP_DIR}/ufw.log"
export EASY_ALL_TEST_TMP_DIR="${TMP_DIR}"

mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" \
    "${SUBSCRIPTION_DIR}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}" "${TMP_DIR}/systemd" \
    "${TMP_DIR}/nginx-main"
printf 'worker_processes auto;\n' >"${EASY_ALL_NGINX_MAIN_CONF}"
: >"${FAKE_SYSTEMCTL_LOG}"
: >"${FAKE_UFW_LOG}"

cat >"${XRAY_BIN}" <<'FAKE_XRAY'
#!/usr/bin/env bash
case "${1:-}" in
x25519) printf 'PrivateKey: test-private\nPublicKey: test-public\n' ;;
*) exit 0 ;;
esac
FAKE_XRAY
chmod +x "${XRAY_BIN}"
printf '26.9.8\n' >"${XRAY_DIR}/version"

systemctl() {
    printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
    return 0
}
nginx() { return 0; }
ufw() {
    printf '%s\n' "$*" >>"${FAKE_UFW_LOG}"
    [[ "${1:-}" == "status" ]] && printf 'Status: active\n'
    return 0
}
flock() { :; }
require_root() { :; }
sysctl() { :; }
dig() { printf '203.0.113.9\n'; }
curl() { return 1; }

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
    case "${target}" in
    /etc/easy_all*) target="${STATE_DIR}${target#/etc/easy_all}"; args[${#args[@]}-1]="${target}" ;;
    /etc/nginx/conf.d/easy_all.conf) target="${NGINX_CONFIG}"; args[${#args[@]}-1]="${target}" ;;
    /var/www/easy_all*) target="${WEB_ROOT}${target#/var/www/easy_all}"; args[${#args[@]}-1]="${target}" ;;
    esac
    case "${target}" in
    /etc/* | /usr/* | /var/*) fail_test "test isolation: refusing to install into ${target}" ;;
    esac
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
        case "${arg}" in
        /etc/easy_all*) args+=("${STATE_DIR}${arg#/etc/easy_all}") ;;
        /etc/nginx/conf.d/easy_all.conf) args+=("${NGINX_CONFIG}") ;;
        /var/www/easy_all*) args+=("${WEB_ROOT}${arg#/var/www/easy_all}") ;;
        *) args+=("${arg}") ;;
        esac
    done
    command rm "${args[@]}"
}

# shellcheck source=/dev/null
source "${MODE3_PROFILE}"

# --- 3. 状态契约 -------------------------------------------------------------
cat >"${STATE_FILE}" <<'EOF'
STATE_VERSION="0"
PROTOCOL="cloudflare"
CDN_PROVIDER="cloudflare"
TCP_ACCELERATION="skyline"
VPS_PUBLIC_IPV4="198.51.100.10"
CF_ZONE="example.com"
CLOUDFLARE_ZONE_ID="zone-123"
CF_NODE_DOMAIN="cf.example.com"
SUB_DOWNLOAD_NAME="EASYALL"
OWNER_TOKEN="cdnwq-rtbke-3182"
ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'
VLESS_UUID="11111111-2222-4111-8111-111111111111"
CF_NODE_PREFIX="CF"
XHTTP_PATH="/xhttp-abcdef123456"
CLOUDFLARE_ORIGIN_CERT_ID="cert-123"
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2039-01-01T00:00:00Z"
EOF

collect_installed_state
assert_equal "单域名：订阅域名等于节点域名" "cf.example.com" "${SUBSCRIPTION_DOMAIN}"
assert_equal "单域名：VLESS_CDN_DOMAIN 等于节点域名" "cf.example.com" "${VLESS_CDN_DOMAIN}"
assert_equal "Origin CA 域名等于节点域名" "cf.example.com" "${CLOUDFLARE_ORIGIN_DOMAIN}"
assert_equal "模式 3 无直连域名" "" "$(cdn_direct_domains)"
assert_equal "模式 3 无直连入站" "[]" "$(cdn_direct_inbounds_json)"
assert_equal "模式 3 回环 XHTTP 端口" "10086" "${XRAY_XHTTP_LOOPBACK_PORT}"
assert_equal "模式 3 端口预检只含 443" "443" "${CDN_INSTALL_PORTS[*]}"

cdn_validate_local_node_names || fail_test "合法单节点名必须通过校验"
CF_NODE_PREFIX="CDN-AUTO"
if cdn_validate_local_node_names 2>/dev/null; then
    fail_test "保留组名必须被拒绝"
fi
CF_NODE_PREFIX="CF"

# 状态里出现 AWS 字段不影响新模式，但 CDN_PROVIDER 必须是 cloudflare。
CDN_PROVIDER=aws
if ( CDN_PROVIDER=aws; cdn_validate_state_structure ) >/dev/null 2>&1; then
    fail_test "CDN_PROVIDER 不是 cloudflare 时必须拒绝"
fi
CDN_PROVIDER=cloudflare

# --- 4. 单域名 Nginx 渲染 ----------------------------------------------------
nginx_body=$(cdn_render_nginx_config)
assert_contains "默认 server 拒绝未知 SNI" "${nginx_body}" "ssl_reject_handshake on;"
assert_count "只有一个业务 server_name" "${nginx_body}" "server_name cf.example.com;" 1
assert_not_contains "不再有独立订阅 server" "${nginx_body}" "server_name sub.example.com"
assert_not_contains "橙云链路不使用源站头" "${nginx_body}" "X-Easy-All-Origin-Key"
assert_contains "health 探针存在" "${nginx_body}" 'return 200 "easy_all ok\n";'
assert_contains "XHTTP 转发到回环" "${nginx_body}" "grpc_pass grpc://127.0.0.1:10086;"
assert_contains "XHTTP Host 固定为节点域名" "${nginx_body}" "grpc_set_header Host cf.example.com;"
assert_contains "订阅入口存在" "${nginx_body}" "location = /subscribe {"
assert_contains "订阅 Token 门禁存在" "${nginx_body}" "if (\$easy_all_subscription_allowed = __denied__) { return 403; }"
assert_contains "内部订阅不可直接访问" "${nginx_body}" "location = /_easy_all_subscription/base64 {"
assert_contains "未知路径兜底 404" "${nginx_body}" "location / { return 404; }"
assert_not_contains "不再提供 80 端口 server" "${nginx_body}" "listen 80;"

# --- 5. Xray 渲染 -----------------------------------------------------------
render_xray_config
xray_config=$(<"${XRAY_CONFIG}")
assert_count "只有一个 XHTTP 入站" "${xray_config}" '"tag": "vless-xhttp-in"' 1
assert_contains "XHTTP 只监听回环" "${xray_config}" '"listen": "127.0.0.1"'
assert_contains "XHTTP Host 为节点域名" "${xray_config}" '"host": "cf.example.com"'
assert_contains "stream-up 模式" "${xray_config}" '"mode": "stream-up"'
assert_not_contains "橙云链路没有 StatsService" "${xray_config}" "StatsService"
assert_not_contains "橙云链路没有 Reality 入站" "${xray_config}" "vless-reality-in"

# --- 6. 订阅产物：单 CDN 节点、无优选/兜底分组 -------------------------------
cloudflare_write_subscriptions
decoded=$(openssl base64 -d -A <"${SUBSCRIPTION_BASE64_FILE}")
assert_count "Base64 只有一个本机 CDN 节点" "${decoded}" "vless://11111111-2222-4111-8111-111111111111@cf.example.com:443" 1
assert_contains "CDN 节点走 XHTTP" "${decoded}" "type=xhttp"
mihomo_body=$(<"${SUBSCRIPTION_MIHOMO_FILE}")
assert_not_contains "没有 CDN-AUTO 测速组" "${mihomo_body}" "name: CDN-AUTO"
assert_not_contains "没有 CDN-FALLBACK 兜底组" "${mihomo_body}" "name: CDN-FALLBACK"
assert_contains "PROXY 组包含 CDN 节点" "${mihomo_body}" '- "CF"'
for product in base64.txt mihomo.yaml mihomo-ios.yaml base64-all.txt mihomo-all.yaml mihomo-ios-all.yaml; do
    [[ -s "${SUBSCRIPTION_DIR}/${product}" ]] || fail_test "缺少订阅产物：${product}"
done

# --- 7. UFW：443 只对 Cloudflare 回源段放行 ---------------------------------
origin_rules_called=0
cloudflare_configure_origin_firewall() { origin_rules_called=1; }
UFW_DESIRED_PORTS=""
snapshot_ufw_state() { :; }
snapshot_platform_security_state() { :; }
ensure_ssh_boot_service() { :; }
detect_ssh_ports() { SSH_PORTS="22"; }
verify_ssh_ufw_no_unmanaged_block() { :; }
configure_ufw_ip_family() { :; }
apply_ssh_ufw_policy() { UFW_DESIRED_PORTS=$1; }
ensure_ssh_fail2ban() { :; }
xhttp_configure_ufw
assert_equal "业务放行只含 SSH" "22" "${UFW_DESIRED_PORTS// /}"
assert_equal "调用 Cloudflare 回源白名单" "1" "${origin_rules_called}"
assert_not_contains "不添加公网 443 放行" "$(<"${FAKE_UFW_LOG}")" 'allow 443/tcp'
assert_not_contains "不添加公网 80 放行" "$(<"${FAKE_UFW_LOG}")" 'allow 80/tcp'

# --- 8. Origin CA 复用：可信链必须复用，不可信链必须重签 ---------------------
ca_dir="${TMP_DIR}/ca"
mkdir -p "${ca_dir}"
openssl ecparam -name prime256v1 -genkey -noout -out "${ca_dir}/ca.key" \
    || fail_test "生成测试 CA 私钥失败"
openssl req -new -x509 -sha256 -key "${ca_dir}/ca.key" -days 3650 \
    -subj "/CN=Test Origin CA" -out "${ca_dir}/ca.pem" || fail_test "生成测试 CA 失败"
openssl ecparam -name prime256v1 -genkey -noout -out "${KEY_FILE}" \
    || fail_test "生成节点私钥失败"
openssl req -new -sha256 -key "${KEY_FILE}" -subj "/CN=cf.example.com" \
    -addext "subjectAltName=DNS:cf.example.com" -out "${ca_dir}/node.csr" \
    || fail_test "生成节点 CSR 失败"
printf 'subjectAltName=DNS:cf.example.com\n' >"${ca_dir}/ext.cnf"
openssl x509 -req -sha256 -in "${ca_dir}/node.csr" -CA "${ca_dir}/ca.pem" \
    -CAkey "${ca_dir}/ca.key" -CAcreateserial -days 3000 -extfile "${ca_dir}/ext.cnf" \
    -out "${CERT_FILE}" 2>/dev/null || fail_test "签发可复用测试证书失败"
CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${ca_dir}/ca.pem"
cloudflare_ensure_origin_ca_root() { :; }
CLOUDFLARE_ORIGIN_CERT_ID="cert-123"
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2039-01-01T00:00:00Z"
cloudflare_origin_certificate_is_reusable \
    || fail_test "可信链且 SAN/有效期/公私钥都匹配时必须复用"
# 同私钥、同 SAN，但由自签证书冒充：链验证必须判为不可复用（否则只能拖到本机 TLS 验收才失败）
openssl req -new -x509 -sha256 -key "${KEY_FILE}" -days 3000 \
    -subj "/CN=cf.example.com" -addext "subjectAltName=DNS:cf.example.com" \
    -out "${CERT_FILE}" || fail_test "生成自签测试证书失败"
if cloudflare_origin_certificate_is_reusable; then
    fail_test "非 Origin CA 链签发的证书不得被判为可复用"
fi

# --- 9. 凭据清理与云端清理归属 ---------------------------------------------
mkdir -p "${RUNTIME_TMP}"
printf 'Authorization: Bearer test-token-value\n' >"${RUNTIME_TMP}/cloudflare-api-headers"
CLOUDFLARE_API_TOKEN="test-token-value"
clear_profile_credentials
[[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] || fail_test "clear_profile_credentials 必须清除 Token"
[[ ! -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] \
    || fail_test "clear_profile_credentials 必须删除 API 请求头文件"

cloudflare_record_list() {
    local type=$2 host=$3
    case "${host}" in
    cf.example.com)
        printf '%s\n' '[{"id":"rec-ok","type":"A","content":"198.51.100.10","proxied":true,"comment":"easy_all cloudflare"}]'
        ;;
    keep.example.com)
        printf '%s\n' '[{"id":"rec-third","type":"A","content":"198.51.100.10","proxied":false,"comment":"other-tool"}]'
        ;;
    flipped.example.com)
        printf '%s\n' '[{"id":"rec-flipped","type":"A","content":"198.51.100.10","proxied":true,"comment":"easy_all cloudflare"}]'
        ;;
    missing-proxied.example.com)
        printf '%s\n' '[{"id":"rec-noproxied","type":"A","content":"198.51.100.10","comment":"easy_all cloudflare"}]'
        ;;
    *) printf '%s\n' '[]' ;;
    esac
}
cloudflare_api_request() {
    printf '%s\n' "$*" >>"${TMP_DIR}/api.log"
}
: >"${TMP_DIR}/api.log"
CF_NODE_DOMAIN="cf.example.com"
cdn_direct_domains() {
    printf 'keep.example.com\nflipped.example.com\nmissing-proxied.example.com\n'
}
cdn_purge_cloudflare_dns
api_log=$(<"${TMP_DIR}/api.log")
assert_contains "删除注释/目标/代理状态都匹配的记录" "${api_log}" "DELETE /zones/zone-123/dns_records/rec-ok"
assert_not_contains "第三方记录不得删除" "${api_log}" "rec-third"
assert_not_contains "代理状态被改动（橙云→灰云）的记录不得删除" "${api_log}" "rec-flipped"
assert_not_contains "缺少代理状态字段的记录不得猜测删除" "${api_log}" "rec-noproxied"

# --- 10. 清理：业务路径失败时保留状态目录与安装前快照，修正后可重试 ---------
mkdir -p "${STATE_DIR}/backups" "${WEB_ROOT}" "${XRAY_DIR}" "${TMP_DIR}/progress" \
    "${TMP_DIR}/bin" "${TMP_DIR}/lib"
printf 'pre-install\n' >"${STATE_DIR}/backups/pre-install-complete"
printf 'identity\n' >"${STATE_DIR}/install-identity.json"
printf 'PROFILE=cloudflare\nCHAIN=cloudflare\nSTAGE=services\n' \
    >"${TMP_DIR}/progress/install-progress.env"
mkdir -p "${TMP_DIR}/replay/${WEB_ROOT#/}"
cleanup_partial_install_local() { :; }
cloudflare_remove_origin_firewall_rules() { :; }
remove_daily_reboot_schedule() { :; }
rm_fail_target="${WEB_ROOT}"
rm() {
    local args=() arg
    for arg in "$@"; do
        case "${arg}" in
        /etc/easy_all*) args+=("${STATE_DIR}${arg#/etc/easy_all}") ;;
        /etc/nginx/conf.d/easy_all.conf) args+=("${NGINX_CONFIG}") ;;
        /var/www/easy_all*) args+=("${WEB_ROOT}${arg#/var/www/easy_all}") ;;
        /usr/local/bin/easy_all) args+=("${TMP_DIR}/bin/easy_all") ;;
        /usr/local/lib/easy_all*) args+=("${TMP_DIR}/lib${arg#/usr/local/lib/easy_all}") ;;
        *) args+=("${arg}") ;;
        esac
    done
    if [[ -n "${rm_fail_target}" && "${args[${#args[@]}-1]}" == "${rm_fail_target}" ]]; then
        return 1
    fi
    command rm "${args[@]}"
}
if cleanup_partial_install >"${TMP_DIR}/cleanup-fail.log" 2>&1; then
    fail_test "业务路径删除失败时清理必须非零退出"
fi
[[ -f "${STATE_DIR}/backups/pre-install-complete" ]] \
    || fail_test "业务路径删除失败时必须保留安装前快照"
[[ -f "${STATE_DIR}/install-identity.json" ]] \
    || fail_test "业务路径删除失败时必须保留安装身份"
[[ -f "${TMP_DIR}/progress/install-progress.env" ]] \
    || fail_test "业务路径删除失败时必须保留安装进度标记"
assert_contains "失败提示说明可重试" "$(<"${TMP_DIR}/cleanup-fail.log")" "cleanup-partial"
assert_not_contains "失败时不得声称已清理" "$(<"${TMP_DIR}/cleanup-fail.log")" "本机内容已卸载"
# 解除故障后重试：清理完成并清除 marker。
rm_fail_target=""
cleanup_partial_install || fail_test "解除故障后 cleanup-partial 必须成功"
[[ ! -e "${STATE_DIR}" ]] || fail_test "重试成功后状态目录必须删除"
[[ ! -e "${WEB_ROOT}" ]] || fail_test "重试成功后 web 根目录必须删除"
[[ ! -e "${TMP_DIR}/progress/install-progress.env" ]] \
    || fail_test "重试成功后安装进度标记必须清除"

# --- 10.1 同名 AAAA 冲突必须拒绝，零 DNS 写入 ------------------------------
cat >"${TMP_DIR}/aaaa-conflict.sh" <<'AAAA_SCRIPT'
set -Eeuo pipefail
source "${MODE3_PROFILE}"
CLOUDFLARE_ZONE_ID=zone-123
cloudflare_record_list() { printf '%s\n' '[{"id":"aaaa-1","type":"AAAA","content":"2001:db8::1"}]'; }
cloudflare_api_request() { printf 'API %s\n' "$*" >>"${AAAA_LOG}"; }
dns_ensure_record cf.example.com A 198.51.100.10 true
AAAA_SCRIPT
: >"${TMP_DIR}/aaaa.log"
if MODE3_PROFILE="${MODE3_PROFILE}" AAAA_LOG="${TMP_DIR}/aaaa.log" \
    bash "${TMP_DIR}/aaaa-conflict.sh" >"${TMP_DIR}/aaaa.out" 2>&1; then
    fail_test "同名 AAAA 存在时必须拒绝配置 A 记录"
fi
assert_contains "AAAA 冲突必须点名记录类型" "$(<"${TMP_DIR}/aaaa.out")" "AAAA"
[[ ! -s "${TMP_DIR}/aaaa.log" ]] || fail_test "AAAA 冲突时不得发起任何 DNS 写入"

# --- 10.2 跨模式残留清理必须能按新 Profile key 定位 ------------------------
assert_equal "cloudflare 映射到 cloudflare.sh" "cloudflare.sh" "$(profile_script_for cloudflare)"
assert_equal "combined-cloudflare 映射到 combined-cloudflare.sh" \
    "combined-cloudflare.sh" "$(profile_script_for combined-cloudflare)"
assert_equal "combined 仍映射到 combined.sh" "combined.sh" "$(profile_script_for combined)"

# --- 10.3 非零退出：凭据清理与保留证书清单必须经真实 EXIT 钩子生效 ----------
cat >"${TMP_DIR}/exit-hook.sh" <<'EXIT_SCRIPT'
set -Eeuo pipefail
source "${MODE3_PROFILE}"
CLOUDFLARE_API_TOKEN="test-exit-token"
printf 'Authorization: Bearer test-exit-token\n' >"${RUNTIME_TMP}/cloudflare-api-headers"
CLOUDFLARE_CREATED_ORIGIN_CERT_ID="cert-retained-456"
CF_NODE_DOMAIN="cf.example.com"
exit 1
EXIT_SCRIPT
if MODE3_PROFILE="${MODE3_PROFILE}" bash "${TMP_DIR}/exit-hook.sh" \
    >"${TMP_DIR}/exit.out" 2>&1; then
    fail_test "退出钩子用例必须保持非零退出"
fi
assert_contains "失败退出时点名保留的新证书" "$(<"${TMP_DIR}/exit.out")" "cert-retained-456"
[[ ! -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] \
    || fail_test "失败退出时 EXIT 钩子必须删除 API 请求头文件"

# --- 11. 模式 5：直连 + 橙云（子进程，避免 readonly 常量冲突） ---------------
mode5_dir="${TMP_DIR}/mode5"
mkdir -p "${mode5_dir}/state/certs" "${mode5_dir}/state/xray" "${mode5_dir}/web/subscriptions" \
    "${mode5_dir}/runtime" "${mode5_dir}/lib" "${mode5_dir}/nginx-main"
printf 'worker_processes auto;\n' >"${mode5_dir}/nginx-main/nginx.conf"
cat >"${mode5_dir}/profile.sh" <<'MODE5_SCRIPT'
set -Eeuo pipefail
export STATE_DIR="${MODE5_DIR}/state"
export BACKUP_DIR="${STATE_DIR}/backups"
export STATE_FILE="${STATE_DIR}/state.env"
export RUNTIME_TMP="${MODE5_DIR}/runtime"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/fullchain.pem"
export KEY_FILE="${CERT_DIR}/private.key"
export WEB_ROOT="${MODE5_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export COMMAND_INSTALL_DIR="${MODE5_DIR}/lib"
export XRAY_DIR="${STATE_DIR}/xray"
export XRAY_BIN="${MODE5_DIR}/fake-xray"
export XRAY_CONFIG="${XRAY_DIR}/config.json"
export XRAY_SERVICE_FILE="${MODE5_DIR}/systemd/easy_all-xray.service"
export NGINX_CONFIG="${MODE5_DIR}/nginx.conf"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${MODE5_DIR}/runtime-write.lock"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${MODE5_DIR}/policy-state"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${MODE5_DIR}/progress/install-progress.env"
export EASY_ALL_NGINX_MAIN_CONF="${MODE5_DIR}/nginx-main/nginx.conf"
mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" \
    "${SUBSCRIPTION_DIR}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}" "${MODE5_DIR}/systemd"
cat >"${XRAY_BIN}" <<'FAKE_XRAY'
#!/usr/bin/env bash
case "${1:-}" in
x25519) printf 'PrivateKey: test-private\nPublicKey: test-public\n' ;;
*) exit 0 ;;
esac
FAKE_XRAY
chmod +x "${XRAY_BIN}"
printf '26.9.8\n' >"${XRAY_DIR}/version"
systemctl() { return 0; }
nginx() { return 0; }
require_root() { :; }
sysctl() { :; }
curl() { return 1; }
readonly() {
    local arg name val
    for arg in "$@"; do
        [[ "${arg}" == -* ]] && continue
        if [[ "${arg}" == *=* ]]; then
            name=${arg%%=*}
            val=${arg#*=}
            if [[ -z "${!name+x}" ]]; then printf -v "${name}" '%s' "${val}"; fi
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
    case "${target}" in
    /etc/easy_all*) target="${STATE_DIR}${target#/etc/easy_all}"; args[${#args[@]}-1]="${target}" ;;
    /var/www/easy_all*) target="${WEB_ROOT}${target#/var/www/easy_all}"; args[${#args[@]}-1]="${target}" ;;
    esac
    if [[ " ${args[*]} " == *" -d "* ]]; then mkdir -p "${target}"; else mkdir -p "$(dirname "${target}")"; fi
    command install "${args[@]}"
}
rm() {
    local args=() arg
    for arg in "$@"; do
        case "${arg}" in
        /etc/easy_all*) args+=("${STATE_DIR}${arg#/etc/easy_all}") ;;
        /var/www/easy_all*) args+=("${WEB_ROOT}${arg#/var/www/easy_all}") ;;
        *) args+=("${arg}") ;;
        esac
    done
    command rm "${args[@]}"
}
source "${MODE5_PROFILE}"
cat >"${STATE_FILE}" <<'EOF'
STATE_VERSION="0"
PROTOCOL="combined-cloudflare"
CDN_PROVIDER="cloudflare"
VPS_PUBLIC_IPV4="198.51.100.10"
CF_ZONE="example.com"
CLOUDFLARE_ZONE_ID="zone-123"
CF_NODE_DOMAIN="cf.example.com"
SUB_DOWNLOAD_NAME="EASYALL"
OWNER_TOKEN="cdnwq-rtbke-3182"
ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'
VLESS_UUID="11111111-2222-4111-8111-111111111111"
CF_NODE_PREFIX="CF"
XHTTP_PATH="/xhttp-abcdef123456"
CLOUDFLARE_ORIGIN_CERT_ID="cert-123"
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2039-01-01T00:00:00Z"
DIRECT_DOMAIN="node.example.com"
DIRECT_NODE_NAME="direct-node"
REALITY_TARGET="swdist.apple.com:443"
REALITY_PRIVATE_KEY="test-private"
REALITY_PUBLIC_KEY="test-public"
REALITY_SHORT_ID="0123456789abcdef"
EOF
collect_installed_state
render_xray_config
cloudflare_write_subscriptions
MODE5_SCRIPT
MODE5_DIR="${mode5_dir}" MODE5_PROFILE="${MODE5_PROFILE}" \
    bash "${mode5_dir}/profile.sh" || fail_test "模式 5 渲染失败"

mode5_xray=$(<"${mode5_dir}/state/xray/config.json")
assert_contains "模式 5 含 Reality 入站" "${mode5_xray}" '"tag": "vless-reality-in"'
assert_contains "模式 5 Reality 监听 8443" "${mode5_xray}" '"port": 8443'
assert_contains "模式 5 含 XHTTP 入站" "${mode5_xray}" '"tag": "vless-xhttp-in"'
mode5_base64=$(openssl base64 -d -A <"${mode5_dir}/web/subscriptions/base64.txt")
assert_count "模式 5 两个本机节点" "${mode5_base64}" "vless://11111111-2222-4111-8111-111111111111@" 2
first_link=$(grep -o 'vless://[^ ]*' <<<"${mode5_base64}" | head -n 1)
assert_contains "模式 5 直连节点排在前面" "${first_link}" "@node.example.com:8443"
mode5_mihomo=$(<"${mode5_dir}/web/subscriptions/mihomo.yaml")
assert_not_contains "模式 5 同样没有优选分组" "${mode5_mihomo}" "name: CDN-AUTO"

# --- 12. 状态 lib 与 core 的必需字段一致 ------------------------------------
state_lib_body=$(<"${STATE_LIB}")
assert_contains "模式 5 需要直连字段" "${state_lib_body}" "combined-cloudflare"
core_body=$(<"${CORE}")
assert_not_contains "core 不引用 Globalping" "${core_body}" "globalping"
# 保留名清单继续保留 CDN-AUTO/CDN-FALLBACK 只用于拒绝聚合节点重名，不得生成测速/兜底组。
assert_not_contains "core 不生成测速组" "${core_body}" "type: url-test"
assert_not_contains "core 不生成兜底组" "${core_body}" "type: fallback"
assert_not_contains "core 不引入 AWS CLI" "${core_body}" "aws_cli"
assert_not_contains "core 不引入 ACM" "${core_body}" "AWS_ACM"
assert_not_contains "core 不引入 CloudFront 分发" "${core_body}" "CLOUDFRONT_DISTRIBUTION"

echo "ok - Cloudflare 模式渲染与契约测试通过"
