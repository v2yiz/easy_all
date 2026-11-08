#!/usr/bin/env bash
# 直连+CloudFront（模式 4）回归测试：薄 Profile 钩子、状态 roundtrip、双入口节点顺序、
# 域名/订阅复用、两云失败、熔断双协议（Reality 仍可用）与受限安全恢复。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/combined.sh"
CORE="${ROOT_DIR}/lib/cloudfront-mode.sh"
GUARD="${ROOT_DIR}/lib/cdn-traffic-guard.sh"
XHTTP_LIB="${ROOT_DIR}/lib/xhttp-runtime.sh"

# 子进程探针（EASY_ALL_COMBINED_PROBE=1）复用父测试的隔离目录，只靠磁盘状态恢复。
TMP_DIR=${EASY_ALL_TEST_TMP_DIR:-$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_combined_test.XXXXXX")}
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
file_digest() {
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
}
mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

bash -n "${PROFILE}" "${CORE}" "${GUARD}" "${XHTTP_LIB}" \
    "${ROOT_DIR}/easy_all" "${ROOT_DIR}/lib/runtime-core.sh" \
    "${ROOT_DIR}/lib/profile-common.sh" "${ROOT_DIR}/lib/scheduled-maintenance.sh"

# --- 1. CLI / manifest 接线 --------------------------------------------------
launcher_body=$(<"${ROOT_DIR}/easy_all")
menu_body=$(awk '/^choose_install_mode\(\)/,/^}/' "${ROOT_DIR}/easy_all")
assert_contains "菜单 4 映射到 combined" "${menu_body}" "4) printf 'combined\\n' ;;"
assert_contains "detect 识别新模式 3 协议" "${launcher_body}" "combined-cloudfront)"
assert_contains "模式 4 键映射到 combined Profile" "${launcher_body}" \
    'combined|combined-cloudfront|incomplete-combined-cloudfront)'
assert_contains "模式 4（含不完整状态）复用 combined Profile" "${launcher_body}" \
    'candidate="${EASY_ALL_ROOT}/profiles/combined.sh"'
assert_contains "旧 combined 状态被拒绝" "${launcher_body}" \
    '检测到旧 Cloudflare CDN 安装（PROTOCOL=${mode}）'
assert_contains "reality-target 路由覆盖新模式" "${launcher_body}" \
    '"${mode}" == "reality" || "${mode}" == "combined-cloudfront"'
assert_contains "apply-cloud 按模式分派" "${launcher_body}" \
    "cloudfront | combined-cloudfront | cloudflare | combined-cloudflare) ;;"
assert_contains "cdn-traffic-sync 路由覆盖新模式" "${launcher_body}" \
    '"${mode}" == "cloudfront" || "${mode}" == "combined-cloudfront"'
assert_contains "renew-cert 路由覆盖新模式" "${launcher_body}" \
    "cloudfront | combined-cloudfront | cloudflare | combined-cloudflare) renew_certificate"
assert_not_contains "不再保留模式 3 未启用文案" "${launcher_body}" "下一阶段启用"

manifest_body=$(<"${ROOT_DIR}/runtime.manifest")
for legacy in lib/globalping-cdn.sh lib/cloudflare-ip-pool.sh; do
    assert_not_contains "manifest 不再登记 ${legacy}" "${manifest_body}" "${legacy}"
    [[ ! -e "${ROOT_DIR}/${legacy}" ]] || fail_test "旧链路文件必须删除：${legacy}"
done
assert_contains "manifest 登记模式 4 Profile" "${manifest_body}" "profiles/combined.sh"
assert_contains "manifest 登记共享核心" "${manifest_body}" "lib/cloudfront-mode.sh"

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
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
export SUBSCRIPTION_MIHOMO_IOS_FILE="${SUBSCRIPTION_DIR}/mihomo-ios.yaml"
export SUBSCRIPTION_BASE64_ALL_FILE="${SUBSCRIPTION_DIR}/base64-all.txt"
export SUBSCRIPTION_MIHOMO_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-all.yaml"
export SUBSCRIPTION_MIHOMO_IOS_ALL_FILE="${SUBSCRIPTION_DIR}/mihomo-ios-all.yaml"
export COMMAND_INSTALL_DIR="${TMP_DIR}/lib"
export XRAY_DIR="${STATE_DIR}/xray"
export XRAY_BIN="${TMP_DIR}/fake-xray"
export XRAY_CONFIG="${XRAY_DIR}/config.json"
export XRAY_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-xray.service"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP_DIR}/runtime-write.lock"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress/install-progress.env"
export EASY_ALL_CERTBOT_HOOK_FILE_OVERRIDE="${TMP_DIR}/certbot/deploy-hook.sh"
export EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE="${TMP_DIR}/letsencrypt/live/easy_all_origin"
export EASY_ALL_NGINX_MAIN_CONF="${TMP_DIR}/nginx-main/nginx.conf"
export FAKE_STATS_FILE="${TMP_DIR}/xray-stats.json"
export FAKE_SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"
export FAKE_INVOCATION_FILE="${TMP_DIR}/invocation-id"
export FAKE_CURL_LOG="${TMP_DIR}/curl.log"
FAKE_XRAY_RESTART_FAIL=0
mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" \
    "${WEB_ROOT}" "${SUBSCRIPTION_DIR}" "${COMMAND_INSTALL_DIR}" \
    "${XRAY_DIR}" "${TMP_DIR}/systemd" "$(dirname "${EASY_ALL_NGINX_MAIN_CONF}")" \
    "${TMP_DIR}/certbot" "${TMP_DIR}/letsencrypt/live/easy_all_origin"
printf 'worker_processes auto;\n' >"${EASY_ALL_NGINX_MAIN_CONF}"
: >"${FAKE_SYSTEMCTL_LOG}"

cat >"${XRAY_BIN}" <<'FAKE_XRAY'
#!/usr/bin/env bash
case "${1:-}" in
api) command cat "${FAKE_STATS_FILE:?}" ;;
x25519)
    if [[ "${2:-}" == "-i" ]]; then
        printf 'Private key: %s\nPassword: test-public\n' "${3:-}"
    else
        printf 'PrivateKey: test-private\nPassword: test-public\n'
    fi
    ;;
tls)
    printf 'Pinging with SNI: %s\nHandshake succeeded\nTLS Version: TLS 1.3\n' "${3:-}"
    ;;
*) exit 0 ;;
esac
FAKE_XRAY
chmod +x "${XRAY_BIN}"

systemctl() {
    printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
    case "${1:-}" in
    show) command cat "${FAKE_INVOCATION_FILE}" 2>/dev/null || true ;;
    is-active) [[ "${FAKE_INACTIVE:-}" != *"${!#}"* ]] ;;
    restart) [[ "${FAKE_XRAY_RESTART_FAIL:-0}" != "1" ]] ;;
    *) return 0 ;;
    esac
}
nginx() { return 0; }
flock() { :; }
# macOS 沙箱没有 timeout：只吃掉超时参数，被测逻辑不变。
timeout() { shift; "$@"; }
require_root() { :; }
sysctl() { :; }
# 本机监听与 HTTP 验收：只模拟 443/8443 监听和源站路由状态码。
ss() {
    case "$*" in
    *":443"*) printf 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:*\n' ;;
    *":8443"*) printf 'LISTEN 0 511 0.0.0.0:8443 0.0.0.0:*\n' ;;
    esac
}
curl() {
    printf '%s\n' "$*" >>"${FAKE_CURL_LOG}"
    local last="${!#}"
    if [[ " $* " == *" %{http_code} "* ]]; then
        case "${last}" in
        *"/easy_all-health") printf '200' ;;
        *"/subscribe"*) printf '403' ;;
        *) printf '503' ;;
        esac
        return 0
    fi
    case "${last}" in
    *"/easy_all-health") printf 'easy_all ok' ;;
    *"/subscribe"*) printf 'dmxlc3M6Ly90ZXN0' ;;
    *) printf '' ;;
    esac
}

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
    case "${target}" in
    /etc/* | /usr/* | /var/* | /opt/* | /srv/*)
        fail_test "test isolation: refusing to install into ${target}"
        ;;
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

unset XRAY_XHTTP_LOOPBACK_PORT
# shellcheck source=/dev/null
source "${PROFILE}"
unset -f readonly
trap 'status=$?; cleanup; command rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

# 新进程探针：不继承任何内存变量，只用磁盘上的 state.env/identity 恢复安装身份。
scenario_resume_fields() {
    require_root() { :; }
    resume_partial_install
    printf 'FIELDS|%s|%s|%s|%s|%s|%s|%s\n' "${ORIGIN_HEADER_SECRET}" "${VLESS_UUID}" \
        "${XHTTP_PATH}" "${REALITY_PRIVATE_KEY}" "${REALITY_PUBLIC_KEY}" \
        "${AWS_ACM_CERTIFICATE_ARN:-}" "${AWS_CLOUDFRONT_DISTRIBUTION_ID:-}"
}

scenario_resume_defaults() {
    require_root() { :; }
    resume_partial_install
    # 续装后的输入提示必须以恢复值为默认值，不得先生成新值再覆盖。
    prompt_value() { printf '%s' "${2:-}"; }
    prompt_secret() { printf 'resume-zone-token-0123456789abcd'; }
    collect_aws_credentials() {
        AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
        AWS_SECRET_ACCESS_KEY=resume-secret-0123456789abcd
    }
    detect_public_ipv4() { printf '203.0.113.77'; }
    choose_subscription_config() { printf '%s' "${SUBSCRIPTION_CONFIG}"; }
    collect_install_inputs </dev/null
    printf 'RESULT|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "${CF_ZONE}" "${CF_ORIGIN_DOMAIN}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" \
        "${DIRECT_DOMAIN}" "${DIRECT_NODE_NAME}" "${REALITY_TARGET}" \
        "${SUB_DOWNLOAD_NAME}" "${VPS_PUBLIC_IPV4}" \
        "${SCHEDULED_REBOOT_ENABLED:-}" "${SCHEDULED_REBOOT_HOUR:-}"
}

scenario_resume_plain() {
    require_root() { :; }
    resume_partial_install
    printf 'RESUMED\n'
}

if [[ -n "${EASY_ALL_COMBINED_SCENARIO:-}" ]]; then
    trap - EXIT
    case "${EASY_ALL_COMBINED_SCENARIO}" in
    resume-fields) scenario_resume_fields ;;
    resume-defaults) scenario_resume_defaults ;;
    resume-plain) scenario_resume_plain ;;
    *) fail_test "未知子进程场景：${EASY_ALL_COMBINED_SCENARIO}" ;;
    esac
    exit 0
fi

# 新进程探针：不继承任何内存变量，只用磁盘上的 state.env 与 usage 恢复受限运行时。
if [[ "${EASY_ALL_COMBINED_PROBE:-0}" == "1" ]]; then
    trap - EXIT
    collect_installed_state
    cdn_traffic_recover_restricted_runtime
    exit $?
fi

# 网络辅助一律隔离：ASN/公网 IP 查询不触网。
detect_public_ipv4() { printf '198.51.100.10'; }
lookup_ip_asns() { printf '64500'; }

# --- 3. Profile 契约 ---------------------------------------------------------
assert_equal "模式 3 协议" "combined-cloudfront" "${PROTOCOL}"
assert_equal "模式 3 Profile 键" "combined" "${CDN_PROFILE_KEY}"
assert_equal "模式 3 CloudFront provider" "aws" "${CDN_PROVIDER}"
assert_equal "Reality 固定 8443" "8443" "${REALITY_PORT}"
assert_equal "安装预检含 80/443/8443" "80 443 8443" "${CDN_INSTALL_PORTS[*]}"
assert_equal "UFW 业务端口含 8443" "8443" "$(cdn_direct_ufw_ports)"
assert_contains "状态字段登记直连域名" "${CDN_STATE_VARIABLES[*]}" "DIRECT_DOMAIN"
assert_contains "状态字段登记直连节点名" "${CDN_STATE_VARIABLES[*]}" "DIRECT_NODE_NAME"
assert_contains "状态字段登记 Reality 目标" "${CDN_STATE_VARIABLES[*]}" "REALITY_TARGET"
assert_contains "状态字段登记 Reality 私钥" "${CDN_STATE_VARIABLES[*]}" "REALITY_PRIVATE_KEY"
assert_contains "状态字段登记 Reality shortId" "${CDN_STATE_VARIABLES[*]}" "REALITY_SHORT_ID"
assert_contains "状态字段登记分发 ID" "${CDN_STATE_VARIABLES[*]}" "AWS_CLOUDFRONT_DISTRIBUTION_ID"
assert_contains "状态字段登记模板快照" "${CDN_STATE_VARIABLES[*]}" "MIHOMO_TEMPLATE_SNAPSHOT"
precheck_stmt=$(sed -n '/^install_all() {/,/^}/p' "${CORE}" \
    | grep -F 'prepare_fresh_install "${CDN_INSTALL_PORTS[@]}"' || true)
assert_contains "安装预检包含回环端口与统计 API" "${precheck_stmt}" \
    '"${XRAY_XHTTP_LOOPBACK_PORT}" 10085'
assert_contains "安装走 CloudFront 链路标记" \
    "$(sed -n '/^install_all() {/,/^}/p' "${CORE}")" \
    'install_progress_begin "${CDN_PROFILE_KEY}" cloudfront'

# --- 4. 状态 roundtrip -------------------------------------------------------
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zone-123
VPS_PUBLIC_IPV4=198.51.100.10
CF_ORIGIN_DOMAIN=origin.example.com
CF_NODE_DOMAIN=cf.example.com
SUBSCRIPTION_DOMAIN=sub.example.com
DIRECT_DOMAIN=node.example.com
DIRECT_NODE_NAME='🇺🇸直连'
SUB_DOWNLOAD_NAME=EASYALL
OWNER_TOKEN=cdnwq-rtbke-3182
ALLOWED_TOKENS=$(jq -cn --arg t "${OWNER_TOKEN}" '{owner:$t}')
AGG_NODE='{"type":"vless","name":"聚合节点","host":"r.example.com","port":8443,"security":"reality","network":"tcp","uuid":"22222222-2222-4222-8222-222222222222","sni":"www.example.com","pbk":"PUBKEY-abc_123","sid":"0123456789abcdef"}'
SUBSCRIPTION_CONFIG=$(jq -cn --arg t "${OWNER_TOKEN}" --argjson n "[${AGG_NODE}]" \
    '{allowedTokens:{owner:$t},nodes:$n}')
VLESS_UUID=11111111-2222-4111-8111-111111111111
CF_NODE_PREFIX='🇺🇸AWS'
XHTTP_PATH=/xhttp-abcdef123456
ORIGIN_HEADER_SECRET=test-origin-header-secret-1234
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123
AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net
AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/test
CDN_TRAFFIC_PROTECTION_GB=985
MIHOMO_TEMPLATE_SNAPSHOT=1
SCHEDULED_REBOOT_ENABLED=0
SCHEDULED_REBOOT_HOUR=""
TCP_ACCELERATION=skyline
REALITY_TARGET="swdist.apple.com:443"
REALITY_PRIVATE_KEY=test-private-key
REALITY_PUBLIC_KEY=test-public-key
REALITY_SHORT_ID=0123456789abcdef
AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
AWS_SECRET_ACCESS_KEY=fake-secret-access-key-000000000000
install_progress_begin combined cloudfront
save_state
persist_install_identity || fail_test "identity must be writable"
state_content=$(<"${STATE_FILE}")
assert_not_contains "state 不落盘 AWS access key" "${state_content}" "${AWS_ACCESS_KEY_ID}"
assert_contains "state 持久化直连域名" "${state_content}" "DIRECT_DOMAIN=node.example.com"
assert_equal "state 权限 0600" "600" "$(mode_of "${STATE_FILE}")"
identity_body=$(<"${STATE_DIR}/install-identity.json")
assert_equal "identity 记录 CHAIN" "cloudfront" "$(jq -r '.chain' <<<"${identity_body}")"
assert_equal "identity 记录 profile" "combined" "$(jq -r '.profile' <<<"${identity_body}")"
assert_equal "identity 记录 Reality 私钥用于续装" "test-private-key" \
    "$(jq -r '.reality_private_key' <<<"${identity_body}")"
unset DIRECT_DOMAIN DIRECT_NODE_NAME REALITY_TARGET REALITY_SHORT_ID CDN_PROVIDER PROTOCOL
load_state
assert_equal "load_state 回填直连域名" "node.example.com" "${DIRECT_DOMAIN}"
assert_equal "load_state 回填直连节点名" "🇺🇸直连" "${DIRECT_NODE_NAME}"
assert_equal "load_state 回填 Reality 目标" "swdist.apple.com:443" "${REALITY_TARGET}"
assert_equal "load_state 回填 shortId" "0123456789abcdef" "${REALITY_SHORT_ID}"
assert_equal "load_state 恢复协议" "combined-cloudfront" "${PROTOCOL}"
assert_equal "load_state 派生 VLESS_CDN_DOMAIN" "${CF_NODE_DOMAIN}" "${VLESS_CDN_DOMAIN}"
assert_equal "load_state 强制 deploy 订阅" "deploy" "${SUBSCRIPTION_MODE}"
assert_equal "load_state 保持固定额度" "985" "${CDN_TRAFFIC_PROTECTION_GB}"

(
    AWS_ACCESS_KEY_ID=AKIACLEAR AWS_SECRET_ACCESS_KEY=clear-me-000000000
    CLOUDFLARE_API_TOKEN=token-value
    clear_profile_credentials
    [[ -z "${AWS_ACCESS_KEY_ID:-}" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]
) || fail_test "clear_profile_credentials 必须清除内存凭据"

# 续装标记必须带 CHAIN=cloudfront（旧 combined 标记只能清理后重装）。
marker_chain=$(install_progress_field CHAIN)
assert_equal "marker 记录 CloudFront 链路" "cloudfront" "${marker_chain}"
resume_rule=$(awk '/^prepare_fresh_install\(\)/,/^}/' "${ROOT_DIR}/lib/profile-common.sh")
assert_contains "续装按 CHAIN 收紧" "${resume_rule}" 'install_marker_chain_matches "${current}"'
marker_rule=$(awk '/^install_marker_chain_matches\(\)/,/^}/' "${ROOT_DIR}/lib/profile-common.sh")
assert_contains "续装链路映射 CloudFront" "${marker_rule}" 'cloudfront | combined) expected=cloudfront'
assert_not_contains "不再无条件放行旧 combined 续装" "${resume_rule}" \
    '|| [[ "${current}" == "combined" ]]'

# --- 5. 安装输入 -------------------------------------------------------------
run_inputs() {
    local -a answers=("$@")
    printf '%s\n' "${answers[@]}" >"${TMP_DIR}/inputs.txt"
    printf '0\n' >"${TMP_DIR}/inputs.cursor"
    (
        # 首装输入阶段的这些字段还没有值：清掉父进程的已安装状态，才走真实默认值路径。
        unset CF_ZONE CF_ORIGIN_DOMAIN CF_NODE_DOMAIN SUBSCRIPTION_DOMAIN VPS_PUBLIC_IPV4
        prompt_value() {
            local cursor line
            cursor=$(<"${TMP_DIR}/inputs.cursor")
            cursor=$((cursor + 1))
            printf '%s\n' "${cursor}" >"${TMP_DIR}/inputs.cursor"
            line=$(sed -n "${cursor}p" "${TMP_DIR}/inputs.txt")
            printf '%s' "${line:-$2}"
        }
        prompt_secret() { printf '%s' "aws-secret-value-0000000000000"; }
        collect_aws_credentials() {
            AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
            AWS_SECRET_ACCESS_KEY=fake-secret-value-000000000
        }
        detect_public_ipv4() { printf '198.51.100.10'; }
        choose_subscription_config() {
            printf '%s' '{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'
        }
        collect_install_inputs </dev/null || return 1
        printf 'RESULT|%s|%s|%s|%s|%s\n' "${CF_ZONE}" "${CF_ORIGIN_DOMAIN}" \
            "${DIRECT_DOMAIN}" "${DIRECT_NODE_NAME}" "${REALITY_TARGET}"
    )
}
out=$(run_inputs example.com "" "" "" "" "" 2>&1) || true
assert_contains "合法输入得到直连默认域名与节点名" "${out}" \
    "RESULT|example.com|origin.example.com|node.example.com|🇺🇸直连|swdist.apple.com:443"
out=$(run_inputs example.com "" "" "" "" "" "origin.example.com" 2>&1) || true
assert_contains "直连域名允许复用源站域名" "${out}" \
    "RESULT|example.com|origin.example.com|origin.example.com|"
out=$(run_inputs example.com "" "cf.example.com" "" "" "" "cf.example.com" 2>&1) || true
assert_contains "直连域名不得等于节点域名" "${out}" "直连域名不得等于节点或订阅域名"
out=$(run_inputs example.com "" "" "node.example.com" "" "" "node.example.com" 2>&1) || true
assert_contains "直连域名不得等于订阅域名" "${out}" "直连域名不得等于节点或订阅域名"
out=$(run_inputs example.com "" "" "" "" "" "" "" "🇺🇸AWS" 2>&1) || true
assert_contains "直连节点名不得与 CloudFront 节点重名" "${out}" \
    "直连节点名无效、重复或与 CloudFront 节点重名"
out=$(run_inputs example.com "" "" "" "" "" "" "" "PROXY" 2>&1) || true
assert_contains "直连节点名不得使用保留组名" "${out}" "直连节点名不能使用保留组名"
out=$(run_inputs example.com "" "" "" "" "" "" "bad-target" 2>&1) || true
assert_contains "Reality 目标必须带端口" "${out}" "Reality 目标无效"

# 聚合节点与本机直连节点重名必须拒绝
(
    LOCAL_NAMES=$(cdn_local_node_names)
    [[ "$(jq -c '.' <<<"${LOCAL_NAMES}")" == '["🇺🇸直连","🇺🇸AWS"]' ]]
) || fail_test "本机节点顺序必须是 [直连, CloudFront]"
dup_config=$(jq -cn --arg t "${OWNER_TOKEN}" --argjson n "[${AGG_NODE}]" \
    '{allowedTokens:{owner:$t},nodes:$n}' | jq -c '.nodes[0].name="🇺🇸直连"')
cdn_apply_subscription_config "${dup_config}" >/dev/null 2>&1 \
    && fail_test "聚合节点与直连节点重名必须拒绝"

# --- 6. 直连运行时与密钥 -----------------------------------------------------
printf '26.9.8\n' >"${XRAY_DIR}/version"
unset REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID
cdn_prepare_direct_runtime || fail_test "直连运行时准备必须成功"
assert_equal "生成 Reality 私钥" "test-private" "${REALITY_PRIVATE_KEY}"
assert_equal "派生 Reality 公钥" "test-public" "${REALITY_PUBLIC_KEY}"
[[ "${REALITY_SHORT_ID}" =~ ^([0-9a-fA-F]{2}){1,8}$ ]] \
    || fail_test "默认 shortId 必须是偶数位十六进制"
for bad_sid in abc 0123456789abcdeg; do
    if ( REALITY_SHORT_ID="${bad_sid}"; cdn_prepare_direct_runtime ) >/dev/null 2>&1; then
        fail_test "非法 shortId 必须被拒绝：${bad_sid}"
    fi
done
# 密钥生成后立即落盘：中断续装必须复用同一 Reality 身份（不等最终 save_state）。
identity_generated=$(<"${STATE_DIR}/install-identity.json")
assert_equal "生成密钥后立即落盘 Reality 私钥" "${REALITY_PRIVATE_KEY}" \
    "$(jq -r '.reality_private_key' <<<"${identity_generated}")"
assert_equal "生成密钥后立即落盘 Reality 公钥" "${REALITY_PUBLIC_KEY}" \
    "$(jq -r '.reality_public_key' <<<"${identity_generated}")"
assert_equal "生成密钥后立即落盘 shortId" "${REALITY_SHORT_ID}" \
    "$(jq -r '.reality_short_id' <<<"${identity_generated}")"
assert_equal "identity 记录直连域名/节点名/target" \
    "${DIRECT_DOMAIN}|${DIRECT_NODE_NAME}|${REALITY_TARGET}" \
    "$(jq -r '[.direct_domain,.direct_node_name,.reality_target]|join("|")' <<<"${identity_generated}")"
REALITY_SHORT_ID=0123456789abcdef
persist_install_identity || fail_test "identity 必须可写"

# --- 7. ACM / 分发：SAN 不含直连与源站域名 ----------------------------------
dist_json="${TMP_DIR}/dist.json"
build_distribution_config "${dist_json}" caller-1
assert_equal "别名只含节点与订阅" '["cf.example.com","sub.example.com"]' \
    "$(jq -c '.Aliases.Items | sort' "${dist_json}")"
assert_not_contains "分发别名不含直连/源站域名" "$(jq -c '.Aliases.Items' "${dist_json}")" \
    "node.example.com"
assert_equal "回源域名是源站域名" "${CF_ORIGIN_DOMAIN}" \
    "$(jq -r '.Origins.Items[0].DomainName' "${dist_json}")"
assert_equal "回源 Host 由 Nginx 重写为节点域名（AWS 不转发 viewer Host）" "false" \
    "$(jq -r '.Origins.Items[0].CustomHeaders.Items[0].HeaderName == "Host"' "${dist_json}")"
assert_equal "订阅域名与节点域名相同时只有一个别名" "1" \
    "$(SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
       build_distribution_config "${TMP_DIR}/dist-same.json" caller-2
       jq '.Aliases.Quantity' "${TMP_DIR}/dist-same.json")"

acm_args="${TMP_DIR}/acm-args.log"
: >"${acm_args}"
(
    aws_cli() {
        case "$*" in
        *request-certificate*)
            printf '%s\n' "$*" >"${acm_args}"
            printf 'arn:aws:acm:us-east-1:123456789012:certificate/new'
            ;;
        *get-caller-identity*)
            printf '123456789012\n'
            ;;
        *describe-certificate*)
            jq -cn --arg node "${CF_NODE_DOMAIN}" --arg sub "${SUBSCRIPTION_DOMAIN}" '
                {Certificate:{Status:"ISSUED",
                  CertificateArn:"arn:aws:acm:us-east-1:123456789012:certificate/new",
                  DomainName:$node, SubjectAlternativeNames:[$node,$sub],
                  DomainValidationOptions:[{ResourceRecord:{Name:"_x",Type:"CNAME",Value:"_y"}}]}}'
            ;;
        *) printf '{}' ;;
        esac
    }
    AWS_ACM_CERTIFICATE_ARN=""
    find_or_request_acm_certificate >/dev/null 2>&1 || true
)
assert_contains "ACM 申请使用节点域名" "$(<"${acm_args}")" "--domain-name ${CF_NODE_DOMAIN}"
assert_contains "ACM SAN 只含订阅域名" "$(<"${acm_args}")" \
    "--subject-alternative-names ${SUBSCRIPTION_DOMAIN}"
assert_not_contains "ACM SAN 不含直连域名" "$(<"${acm_args}")" "node.example.com"
# 收到 ARN 后立即落盘，失败后仍可追踪已创建的云端证书。
assert_equal "收到 ACM ARN 后立即落盘" \
    "arn:aws:acm:us-east-1:123456789012:certificate/new" \
    "$(jq -r '.aws_acm_certificate_arn' "${STATE_DIR}/install-identity.json")"

# --- 8. DNS：源站/直连复用只建一条 A；订阅=节点只建一条 CNAME ----------------
dns_log="${TMP_DIR}/dns.log"
(
    cloudflare_collect_api_token() { :; }
    cdn_ensure_zone_id() { :; }
    dns_ensure_record() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${dns_log}"; }
    cdn_prepare_origin_dns
) || fail_test "源站/直连 DNS 配置必须成功"
assert_equal "源站与直连各建一条 A 记录" "2" "$(wc -l <"${dns_log}" | tr -d ' ')"
: >"${dns_log}"
(
    DIRECT_DOMAIN=${CF_ORIGIN_DOMAIN}
    cloudflare_collect_api_token() { :; }
    cdn_ensure_zone_id() { :; }
    dns_ensure_record() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${dns_log}"; }
    cdn_prepare_origin_dns
) || fail_test "直连复用源站域名时必须成功"
assert_equal "DIRECT=ORIGIN 不重复建 A 记录" "1" "$(wc -l <"${dns_log}" | tr -d ' ')"
: >"${dns_log}"
(
    cloudflare_collect_api_token() { :; }
    cdn_ensure_zone_id() { :; }
    dns_ensure_record() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${dns_log}"; }
    ensure_viewer_cnames
) || fail_test "viewer CNAME 配置必须成功"
assert_equal "节点与订阅域名不同时建两条 CNAME" "2" "$(wc -l <"${dns_log}" | tr -d ' ')"
: >"${dns_log}"
(
    SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
    cloudflare_collect_api_token() { :; }
    cdn_ensure_zone_id() { :; }
    dns_ensure_record() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${dns_log}"; }
    ensure_viewer_cnames
) || fail_test "订阅=节点时必须成功"
assert_equal "订阅=节点只建一条 CNAME" "1" "$(wc -l <"${dns_log}" | tr -d ' ')"

# --- 9. Xray 渲染：Reality + API + XHTTP -------------------------------------
render_xray_config 0
xray_conf=$(<"${XRAY_CONFIG}")
assert_equal "模式 3 三个入站（Reality/API/XHTTP）" "3" "$(jq '.inbounds | length' <<<"${xray_conf}")"
assert_equal "Reality 入站排第一" "vless-reality-in" "$(jq -r '.inbounds[0].tag' <<<"${xray_conf}")"
assert_equal "Reality 监听 8443" "8443" "$(jq -r '.inbounds[0].port' <<<"${xray_conf}")"
assert_equal "Reality 保留 Vision flow" "xtls-rprx-vision" \
    "$(jq -r '.inbounds[0].settings.clients[0].flow' <<<"${xray_conf}")"
assert_equal "Reality 使用状态中的私钥" "${REALITY_PRIVATE_KEY}" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.privateKey' <<<"${xray_conf}")"
assert_equal "Reality SNI 来自 target" "swdist.apple.com" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.serverNames[0]' <<<"${xray_conf}")"
assert_equal "Reality shortId 来自状态" "${REALITY_SHORT_ID}" \
    "$(jq -r '.inbounds[0].streamSettings.realitySettings.shortIds[0]' <<<"${xray_conf}")"
assert_equal "API 入站第二" "easy-all-api" "$(jq -r '.inbounds[1].tag' <<<"${xray_conf}")"
assert_equal "API 端口 10085" "10085" "$(jq -r '.inbounds[1].port' <<<"${xray_conf}")"
assert_equal "XHTTP 只监听回环" "127.0.0.1" "$(jq -r '.inbounds[2].listen' <<<"${xray_conf}")"
assert_equal "XHTTP 回环端口 10086" "10086" "$(jq -r '.inbounds[2].port' <<<"${xray_conf}")"
assert_equal "XHTTP 转发 Host 为节点域名" "${CF_NODE_DOMAIN}" \
    "$(jq -r '.inbounds[2].streamSettings.xhttpSettings.host' <<<"${xray_conf}")"
assert_equal "路由首条把 API 入站交给 API tag" "easy-all-api" \
    "$(jq -r '.routing.rules[0].outboundTag' <<<"${xray_conf}")"
assert_not_contains "UFW 口径不变：10085/10086 不放行" "$(cdn_direct_ufw_ports)" "1008"

# 阻断：XHTTP 关闭但 Reality/API 保持可用
render_xray_config 1
xray_blocked=$(<"${XRAY_CONFIG}")
assert_equal "阻断时 XHTTP clients 为空" "0" \
    "$(jq '.inbounds[2].settings.clients | length' <<<"${xray_blocked}")"
assert_equal "阻断时 Reality 仍有 client" "1" \
    "$(jq '.inbounds[0].settings.clients | length' <<<"${xray_blocked}")"
assert_equal "阻断时 Reality 监听保持不变" "8443" \
    "$(jq -r '.inbounds[0].port' <<<"${xray_blocked}")"
assert_equal "阻断时 API 保持可用" "easy-all-api" \
    "$(jq -r '.routing.rules[0].inboundTag[0]' <<<"${xray_blocked}")"
assert_equal "阻断时最优先 XHTTP block 路由" "block" \
    "$(jq -r '.routing.rules[1].outboundTag' <<<"${xray_blocked}")"
assert_equal "block 规则只针对 XHTTP 入站" "vless-xhttp-in" \
    "$(jq -r '.routing.rules[1].inboundTag[0]' <<<"${xray_blocked}")"

# --- 10. Nginx：源站 TLS + 阻断 503 ------------------------------------------
cdn_render_nginx_config 0 1 >"${TMP_DIR}/nginx-final.conf"
final_conf=$(<"${TMP_DIR}/nginx-final.conf")
assert_contains "443 默认 server 拒绝未知 SNI" "${final_conf}" "ssl_reject_handshake on;"
assert_contains "health 需要源站头" "${final_conf}" "x_easy_all_origin_key"
assert_contains "回源 Host 固定为节点域名" "${final_conf}" \
    "grpc_set_header Host ${CF_NODE_DOMAIN};"
assert_contains "回源到本机 XHTTP 端口" "${final_conf}" \
    "grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};"
assert_not_contains "不暴露裸 XHTTP 路径" "${final_conf}" "location ${XHTTP_PATH}/ {"
cdn_render_nginx_config 1 0 >"${TMP_DIR}/nginx-blocked.conf"
assert_contains "阻断时 XHTTP 返回 503" "$(<"${TMP_DIR}/nginx-blocked.conf")" "return 503;"
assert_contains "阻断时订阅降级 503" "$(<"${TMP_DIR}/nginx-blocked.conf")" \
    "location = /subscribe {"

# 受限安全验收只做本机检查，不调用含远端 target 探测的直连钩子。
restricted_body=$(awk '/^cdn_validate_restricted_runtime\(\)/,/^}/' "${CORE}" \
    | grep -v '^[[:space:]]*#')
assert_not_contains "受限验收不调用 cdn_validate_direct_runtime" "${restricted_body}" \
    "cdn_validate_direct_runtime"
assert_contains "受限验收复用统一本机验收（含 8443 监听）" "${restricted_body}" \
    "validate_protocol_runtime"

# --- 11. 订阅：节点顺序 Reality → CloudFront → 聚合 --------------------------
initialize_cdn_traffic_usage
cloudfront_write_subscriptions
for file in base64.txt mihomo.yaml mihomo-ios.yaml base64-all.txt mihomo-all.yaml mihomo-ios-all.yaml; do
    [[ -s "${SUBSCRIPTION_DIR}/${file}" ]] || fail_test "缺少订阅产物：${file}"
done
decoded_links=$(openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt")
assert_equal "base64 含两个本机节点 + 聚合节点" "3" "$(grep -c '^vless://' <<<"${decoded_links}")"
first_link=$(printf '%s\n' "${decoded_links}" | sed -n '1p')
second_link=$(printf '%s\n' "${decoded_links}" | sed -n '2p')
assert_contains "首个节点是直连 Reality" "${first_link}" "security=reality"
assert_contains "直连节点使用 8443" "${first_link}" "@${DIRECT_DOMAIN}:8443?"
assert_contains "占位符节点名已替换为直连名" "${first_link}" "#%F0%9F%87%BA%F0%9F%87%B8%E7%9B%B4%E8%BF%9E"
assert_contains "第二个节点是 CloudFront" "${second_link}" "@${CF_NODE_DOMAIN}:443?"
assert_not_contains "CloudFront 节点不带 Reality 参数" "${second_link}" "security=reality"
mlkem_version=$(xray_installed_version)
assert_equal "核心版本用于 ML-KEM 门控" "26.9.8" "${mlkem_version}"
assert_not_contains "新核心不需要 mlkem=0 提示" "${first_link}" "mlkem=0"
mihomo_body=$(<"${SUBSCRIPTION_DIR}/mihomo.yaml")
assert_equal "mihomo 两个本机节点 + 聚合节点" "3" "$(grep -c '^  - name: ' <<<"${mihomo_body}")"
assert_contains "mihomo 直连节点启用 ML-KEM" "${mihomo_body}" "support-x25519mlkem768: true"
assert_equal "mihomo 首个节点是直连 Reality" '  - name: "🇺🇸直连"' \
    "$(grep -m1 '^  - name: ' <<<"${mihomo_body}")"
assert_equal "mihomo 第二个节点是 CloudFront" '  - name: "🇺🇸AWS"' \
    "$(grep '^  - name: ' <<<"${mihomo_body}" | sed -n '2p')"
proxy_section=$(awk '/^proxy-groups:/,/^rules:/' <<<"${mihomo_body}")
assert_contains "PROXY 成员含直连节点" "${proxy_section}" '"🇺🇸直连"'
assert_contains "PROXY 成员含 CloudFront 节点" "${proxy_section}" '"🇺🇸AWS"'
assert_contains "模板快照持久化" "$(<"${STATE_DIR}/mihomo-template.yaml")" "# EASY_ALL_PROXY_NODE"
assert_equal "模板快照权限 0600" "600" "$(mode_of "${STATE_DIR}/mihomo-template.yaml")"
# 旧核心（< 26.9.8）必须回落到 mlkem=0 且不写 Mihomo 的 ML-KEM 开关
printf '25.1.1\n' >"${XRAY_DIR}/version"
old_link=$(build_reality_link)
old_node=$(build_mihomo_reality_node)
printf '26.9.8\n' >"${XRAY_DIR}/version"
assert_contains "旧核心下发 mlkem=0" "${old_link}" "mlkem=0"
assert_not_contains "旧核心不写 support-x25519mlkem768" "${old_node}" "support-x25519mlkem768"
# 熔断阻断不删除订阅中的节点
(
    cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
    cloudfront_write_subscriptions
    openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt"
) | grep -Fq "@${CF_NODE_DOMAIN}:443?" \
    || fail_test "熔断阻断节点仍必须保留在有效订阅中"
cdn_traffic_write_usage "$(jq -c '.blocked=false | .enforced=false | .protection_offline=false' \
    "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"

# --- 10.1 HTTP/2 两个渲染分支与模式 3 的 8443 验收 ---------------------------
# nginx 1.25.1 起 http2 是独立指令；更旧的版本只能写成 listen 参数。两个分支都必须
# 渲染出合法配置，且不能把两种写法混在同一份配置里（会触发 duplicate listen options）。
(
    nginx() { printf 'nginx version: nginx/1.26.1\n' >&2; }
    nginx_supports_http2_directive
) || fail_test "1.26.1 必须走 http2 on 指令分支"
(
    nginx() { printf 'nginx version: nginx/1.24.0\n' >&2; }
    nginx_supports_http2_directive && exit 1
    exit 0
) || fail_test "1.24.0 必须走 listen ... http2 分支"
modern_conf=$(cdn_render_nginx_config 0 1 $'\n    http2 on;' "")
assert_contains "现代分支使用 http2 on 指令" "${modern_conf}" "http2 on;"
assert_not_contains "现代分支 listen 不得再带 http2 参数" "${modern_conf}" \
    "listen 443 ssl http2"
assert_equal "现代分支只有 443 的 server 带 http2 指令" "1" \
    "$(grep -c 'http2 on;' <<<"${modern_conf}")"
legacy_conf=$(cdn_render_nginx_config 0 1 "" "http2 ")
assert_contains "旧分支把 h2 写在 listen 上（默认 server）" "${legacy_conf}" \
    "listen 443 ssl http2 default_server;"
assert_equal "旧分支把 h2 写在 listen 上（源站 server）" "1" \
    "$(grep -cE '^    listen 443 ssl http2 *;$' <<<"${legacy_conf}")"
assert_not_contains "旧分支不得混用 http2 on 指令" "${legacy_conf}" "http2 on;"
assert_equal "两种分支的 443 server 块数量一致" \
    "$(grep -c '^server {' <<<"${modern_conf}")" "$(grep -c '^server {' <<<"${legacy_conf}")"

# 模式 3：443 + health 通过也不等于直连入口可用，8443 未监听必须失败并指明端口。
probe_ss_443_only() { case "$*" in *":443"*) printf 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:*\n' ;; esac; }
no_8443_out=$( (
    sleep() { :; }
    ss() { probe_ss_443_only "$@"; }
    validate_protocol_runtime
) 2>&1 ) && fail_test "8443 未监听时模式 3 的运行时验收必须失败"
assert_contains "8443 未监听时明确指出端口" "${no_8443_out}" "Reality 端口 8443 未监听"
# Reality 端口比 443 晚一轮绑定：必须继续重试，不能首轮就终止。
command rm -f -- "${TMP_DIR}/reality-listen-probes"
reality_delayed_ss() {
    case "$*" in
    *":8443"*)
        local count=0
        [[ ! -f "${TMP_DIR}/reality-listen-probes" ]] \
            || count=$(<"${TMP_DIR}/reality-listen-probes")
        count=$((count + 1))
        printf '%s\n' "${count}" >"${TMP_DIR}/reality-listen-probes"
        ((count > 1)) && printf 'LISTEN 0 511 0.0.0.0:8443 0.0.0.0:*\n'
        ;;
    *":443"*) printf 'LISTEN 0 511 0.0.0.0:443 0.0.0.0:*\n' ;;
    esac
}
(
    sleep() { :; }
    ss() { reality_delayed_ss "$@"; }
    validate_protocol_runtime
) || fail_test "8443 延迟绑定时必须重试后通过，而不是首轮误报失败"
# 纯 CDN 模式不受 8443 影响：cdn_reality_enabled 为假时 8443 断言必须恒成立。
(
    ss() { probe_ss_443_only "$@"; }
    cdn_reality_enabled() { return 1; }
    validate_reality_port_listening
) || fail_test "纯 CDN 模式不得要求 8443 监听"

# --- 11.1 订阅就绪：模式 3 的本机节点数固定为 2（Reality 先、CloudFront 后）（F12）
# validate_subscription_runtime 是本机 TLS 路由验收：这里只替换网络部分，
# 六产物逐字节对比与节点身份校验走真实实现。
subscription_ready_local() {
    (
        validate_subscription_runtime() { return 0; }
        cdn_subscription_ready
    )
}
subscription_ready_local || fail_test "模式 3 的正常六产物必须判为就绪"
cdn_subscription_local_nodes_ready "${SUBSCRIPTION_DIR}" \
    || fail_test "模式 3 的 Reality + CloudFront 两个本机节点必须通过身份验收"
# 只剩一个本机节点（少了 Reality）不得判就绪
ready_dir="${TMP_DIR}/ready-check"
install -d -m 0700 "${ready_dir}"
install -m 0640 "${SUBSCRIPTION_DIR}"/*.txt "${SUBSCRIPTION_DIR}"/*.yaml "${ready_dir}/"
openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt" \
    | grep -v 'security=reality' | openssl base64 -A >"${ready_dir}/base64.txt"
printf '\n' >>"${ready_dir}/base64.txt"
cdn_subscription_local_nodes_ready "${ready_dir}" \
    && fail_test "模式 3 缺少 Reality 节点时不得判就绪"
# 节点顺序错位（CloudFront 在前）也不得判就绪
{
    openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt" | sed -n '2p'
    openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt" | sed -n '1p'
} | openssl base64 -A >"${ready_dir}/base64.txt"
printf '\n' >>"${ready_dir}/base64.txt"
cdn_subscription_local_nodes_ready "${ready_dir}" \
    && fail_test "模式 3 节点顺序必须是 Reality 先于 CloudFront"
# 缺失 ios 变体不得判就绪
command rm -f -- "${SUBSCRIPTION_DIR}/mihomo-ios-all.yaml"
if subscription_ready_local; then
    fail_test "缺失 mihomo-ios-all.yaml 时不得判订阅就绪"
fi
command rm -f -- "${SUBSCRIPTION_DIR}/mihomo-all.yaml"
cloudfront_write_subscriptions
subscription_ready_local || fail_test "重发六产物后必须重新判为就绪"

# --- 11.2 聚合节点：三类节点、optional、外部 XHTTP 的 host/SNI 分离 -------------
# 三类聚合（vless reality/tcp、vless tls/xhttp、mieru）都必须能渲染；host 是连接地址，
# 与 TLS 的 SNI/Host 头（sni）分离；optional 节点只进 node=all 的两份产物。
agg_config_three=$(jq -cn --arg token "${OWNER_TOKEN}" '
  {allowedTokens:{owner:$token},nodes:[
    {type:"vless",security:"reality",network:"tcp",name:"聚合Reality",host:"r.example.com",
     port:8443,uuid:"22222222-2222-4222-8222-222222222222",sni:"www.example.com",
     pbk:"PUBKEY-abc_123",sid:"0123456789abcdef"},
    {type:"vless",security:"tls",network:"xhttp",name:"聚合XHTTP",host:"x.example.com",
     port:443,uuid:"33333333-3333-4333-8333-333333333333",sni:"cdn.example.net",
     path:"/agg-path/",mode:"stream-up"},
    {type:"mieru",name:"备用Mieru",host:"m.example.com",portRange:"50000-50512",
     username:"agguser",password:"agg-password-12345",multiplexing:"MULTIPLEXING_LOW",
     optional:true}
  ]}')
(
    cdn_apply_subscription_config "${agg_config_three}" \
        || fail_test "三类聚合节点配置必须被接受"
    [[ "$(jq 'length' <<<"${AGGREGATION_NODES}")" == "3" ]] \
        || fail_test "三类聚合节点都必须进入规范化配置"
    cloudfront_write_subscriptions
) || fail_test "含三类聚合节点的订阅必须发布成功"

links_default=$(openssl base64 -d -A <"${SUBSCRIPTION_BASE64_FILE}")
links_all=$(openssl base64 -d -A <"${SUBSCRIPTION_BASE64_ALL_FILE}")
assert_equal "default 产物 = 2 本机 + 2 非 optional 聚合" "4" \
    "$(printf '%s\n' "${links_default}" | grep -c '^vless://')"
assert_equal "node=all 产物额外包含 optional 的 mieru" "5" \
    "$(grep -c '^[^[:space:]][^[:space:]]*$' <<<"${links_all}")"
assert_contains "default 包含聚合 Reality 节点" "${links_default}" "@r.example.com:8443?"
assert_contains "default 包含聚合 XHTTP 节点" "${links_default}" "@x.example.com:443?"
assert_not_contains "default 不下发 optional mieru" "${links_default}" "mierus://"
assert_contains "node=all 下发 optional mieru" "${links_all}" "mierus://"
agg_xhttp_link=$(grep -F '@x.example.com:443?' <<<"${links_default}")
assert_contains "外部 XHTTP 的 sni 是独立域名" "${agg_xhttp_link}" "sni=cdn.example.net"
assert_contains "外部 XHTTP 的 Host 头跟 sni 而不是 host" "${agg_xhttp_link}" \
    "host=cdn.example.net"
assert_not_contains "外部 XHTTP 不得把连接地址写进 Host 头" "${agg_xhttp_link}" \
    "host=x.example.com"
assert_contains "聚合 Reality 保留 Xray 侧 flow" "$(grep -F '@r.example.com:8443?' <<<"${links_default}")" \
    "flow=xtls-rprx-vision"

mihomo_default=$(<"${SUBSCRIPTION_MIHOMO_FILE}")
mihomo_all=$(<"${SUBSCRIPTION_MIHOMO_ALL_FILE}")
proxies_default=$(awk '/^proxies:/{inside=1} /^proxy-groups:/{inside=0} inside' <<<"${mihomo_default}")
proxies_all=$(awk '/^proxies:/{inside=1} /^proxy-groups:/{inside=0} inside' <<<"${mihomo_all}")
assert_contains "mihomo 聚合 XHTTP 连接地址是 host" "${proxies_default}" 'server: "x.example.com"'
assert_contains "mihomo 聚合 XHTTP 的 SNI 是 sni" "${proxies_default}" 'servername: "cdn.example.net"'
assert_contains "mihomo 聚合 XHTTP 的 Host 头跟 sni" "${proxies_default}" 'host: "cdn.example.net"'
assert_equal "mihomo default 不下发 optional mieru" "0" \
    "$(grep -cE '^    type: mieru$' <<<"${proxies_default}")"
assert_equal "mihomo node=all 下发 optional mieru" "1" \
    "$(grep -cE '^    type: mieru$' <<<"${proxies_all}")"
assert_contains "mihomo node=all 的 mieru 连接 m.example.com" "${proxies_all}" \
    'server: "m.example.com"' 
assert_equal "default 与 node=all 的产物不同" "1" \
    "$([[ "$(file_digest "${SUBSCRIPTION_MIHOMO_FILE}")" != "$(file_digest "${SUBSCRIPTION_MIHOMO_ALL_FILE}")" ]] && echo 1)"
proxy_names_default=$(sed -n '/^proxy-groups:/,/^rules:/p' <<<"${mihomo_default}" \
    | sed -n 's/^        - "\(.*\)"$/\1/p')
assert_equal "PROXY 顺序 = 直连 → CloudFront → 非 optional 聚合" \
    "$(printf '%s\n' "🇺🇸直连" "🇺🇸AWS" "聚合Reality" "聚合XHTTP")" "${proxy_names_default}"

# 拒绝：与本机节点重名、保留组名、非法类型都不得改变上一份有效配置。
(
    cdn_apply_subscription_config "${agg_config_three}" \
        || fail_test "有效聚合配置必须可重复应用"
    cdn_apply_subscription_config "$(jq -c '.nodes[0].name = "🇺🇸直连"' <<<"${agg_config_three}")" \
        >/dev/null 2>&1 && fail_test "聚合节点与直连节点重名必须拒绝"
    cdn_apply_subscription_config "$(jq -c '.nodes[0].name = "PROXY"' <<<"${agg_config_three}")" \
        >/dev/null 2>&1 && fail_test "聚合节点使用保留组名必须拒绝"
    cdn_apply_subscription_config "$(jq -c '.nodes[0].type = "trojan"' <<<"${agg_config_three}")" \
        >/dev/null 2>&1 && fail_test "不支持的聚合节点类型必须拒绝"
    # 失败不得破坏同一进程里上一份有效配置。
    [[ "$(jq 'length' <<<"${AGGREGATION_NODES}")" == "3" ]] \
        || fail_test "被拒绝的聚合配置改变了上一份有效节点"
) || fail_test "聚合节点拒绝用例失败"
# 恢复基线：重新按父进程的原始配置发布，避免影响后续章节。
( cloudfront_write_subscriptions ) || fail_test "恢复基线订阅必须成功"

# --- 12. apply 纯本机 --------------------------------------------------------
net_log="${TMP_DIR}/network.log"
: >"${net_log}"
(
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    install_xray_service() { :; }
    validate_subscription_runtime() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    register_easy_all_command() { :; }
    install_cdn_traffic_protection_timer() { :; }
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    aws() { printf 'aws %s\n' "$*" >>"${net_log}"; return 1; }
    aws_cli() { printf 'aws_cli %s\n' "$*" >>"${net_log}"; return 1; }
    cloudflare_api_request() { printf 'cf %s\n' "$*" >>"${net_log}"; return 1; }
    apply_easy_all
) || fail_test "apply 必须成功重建双入口本机配置"
[[ ! -s "${net_log}" ]] || fail_test "apply 不得访问 AWS/Cloudflare：$(<"${net_log}")"
assert_equal "apply 后 Xray 配置含 Reality 与 XHTTP" "3" \
    "$(jq '.inbounds | length' "${XRAY_CONFIG}")"
assert_contains "apply 后 Nginx 为开放配置" "$(<"${NGINX_CONFIG}")" \
    "grpc_pass grpc://127.0.0.1:10086;"

# --- 13. 熔断：blocked 下 Reality 仍可用，受限恢复按顺序收敛 ------------------
usage_file="${CDN_TRAFFIC_GUARD_USAGE_FILE}"
reset_usage() {
    command rm -f -- "${usage_file}"
    initialize_cdn_traffic_usage
}
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${usage_file}")"
printf 'run-1' >"${FAKE_INVOCATION_FILE}"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":1},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":1},{"name":"inbound>>>vless-reality-in>>>traffic>>>uplink","value":999}]}' \
    >"${FAKE_STATS_FILE}"
assert_equal "只统计 CDN 入站（Reality 大流量不计入）" "$(printf '1\t1')" \
    "$(cdn_traffic_stats_totals "$(<"${FAKE_STATS_FILE}")")"

: >"${FAKE_SYSTEMCTL_LOG}"
recover_log="${TMP_DIR}/recover-order.log"
: >"${recover_log}"
(
    write_nginx_config() { printf 'nginx-deny\n' >>"${recover_log}"; return 0; }
    render_xray_config() { printf 'render-restricted\n' >>"${recover_log}"; [[ "$1" == "1" ]]; }
    cdn_validate_restricted_runtime() { printf 'validate\n' >>"${recover_log}"; return 0; }
    cdn_subscription_ready() { return 1; }
    cdn_traffic_recover_restricted_runtime
) || fail_test "受限安全恢复必须成功"
assert_equal "受限恢复顺序：先 deny 再受限 Xray 再验收" \
    "$(printf 'nginx-deny\nrender-restricted\nvalidate')" "$(<"${recover_log}")"
assert_equal "受限恢复后 enforced=true/offline=false" "true,false" \
    "$(jq -r '[.enforced, .protection_offline] | @csv' "${usage_file}")"
assert_equal "受限恢复保留 blocked" "true" "$(jq -r '.blocked' "${usage_file}")"

# 保护失败：停 Xray、持久 offline，Reality 一并停机（优先保护收费链路）
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${usage_file}")"
: >"${FAKE_SYSTEMCTL_LOG}"
FAKE_XRAY_RESTART_FAIL=1
( rebuild_traffic_runtime ) >/dev/null 2>&1 \
    && fail_test "阻断重建失败必须返回非零"
FAKE_XRAY_RESTART_FAIL=0
assert_equal "阻断失败持久 offline" "true,false" \
    "$(jq -r '[.protection_offline, .enforced] | @csv' "${usage_file}")"
assert_contains "阻断失败保留 Nginx 503" "$(<"${NGINX_CONFIG}")" "return 503;"
assert_contains "阻断失败停止旧 CDN 会话" "$(<"${FAKE_SYSTEMCTL_LOG}")" \
    "stop easy_all-xray.service"

# 新 CLI 进程受限恢复：换一个 bash 进程只读磁盘状态，真实渲染受限 Xray（Reality 仍在 8443）
# 并翻 enforced/offline；不复用本进程任何变量。
: >"${FAKE_SYSTEMCTL_LOG}"
cdn_traffic_write_usage "$(jq -c '.used_bytes = 123456789 | .runtime_id = "run-1"' "${usage_file}")"
usage_before=$(jq -c '{period,runtime_id,used_bytes}' "${usage_file}")
probe_log="${TMP_DIR}/recover-probe.log"
EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_PROBE=1 bash "${BASH_SOURCE[0]}" \
    >"${probe_log}" 2>&1 \
    || fail_test "新进程必须从磁盘状态恢复受限运行时：$(<"${probe_log}")"
assert_contains "新进程不得声称订阅可用" "$(<"${probe_log}")" \
    "订阅未就绪/不可用；禁止解封"
assert_equal "恢复后 enforced=true/offline=false" "true,false" \
    "$(jq -r '[.enforced, .protection_offline] | @csv' "${usage_file}")"
assert_equal "恢复保留 blocked 与计数" "true" "$(jq -r '.blocked' "${usage_file}")"
assert_equal "恢复保留 period/runtime_id/used_bytes" "${usage_before}" \
    "$(jq -c '{period,runtime_id,used_bytes}' "${usage_file}")"
recovered_conf=$(<"${XRAY_CONFIG}")
assert_equal "恢复的受限 Xray 保留 Reality 入站" "vless-reality-in" \
    "$(jq -r '.inbounds[0].tag' <<<"${recovered_conf}")"
assert_equal "恢复的 Reality 仍在 8443 监听" "8443" \
    "$(jq -r '.inbounds[0].port' <<<"${recovered_conf}")"
assert_equal "恢复的受限 Xray 关闭 CDN client" "0" \
    "$(jq '.inbounds[2].settings.clients | length' <<<"${recovered_conf}")"
assert_contains "恢复的 Nginx 仍阻断 XHTTP" "$(<"${NGINX_CONFIG}")" "return 503;"
assert_contains "恢复过程重启受限 Xray" "$(<"${FAKE_SYSTEMCTL_LOG}")" \
    "restart easy_all-xray.service"

# timer 顺序：先受限恢复再采样
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false | .protection_offline=true' "${usage_file}")"
sync_log="${TMP_DIR}/sync-order.log"
: >"${sync_log}"
(
    require_root() { :; }
    collect_installed_state() { :; }
    try_acquire_runtime_write_lock() { return 0; }
    release_runtime_write_lock() { :; }
    cdn_traffic_recover_restricted_runtime() {
        printf 'recover\n' >>"${sync_log}"
        cdn_traffic_mark_restricted_recovered
        return 0
    }
    cdn_traffic_subscription_ready() { return 0; }
    cdn_traffic_update_usage() {
        printf 'sample\n' >>"${sync_log}"
        CDN_TRAFFIC_OLD_BLOCKED=true
        CDN_TRAFFIC_BLOCKED=true
        CDN_TRAFFIC_NEEDS_APPLY=0
        CDN_TRAFFIC_TRANSITION=0
        return 0
    }
    cdn_traffic_protection_sync
) || fail_test "安全恢复成功且采样成功应返回 0"
assert_equal "先受限恢复再采样" "$(printf 'recover\nsample')" "$(<"${sync_log}")"

# update-core 在待落实阻断时拒绝；edit-sub 允许保持阻断修复
update_core_body=$(awk '/^update_current_core\(\)/,/^}/' "${ROOT_DIR}/lib/runtime-core.sh")
assert_contains "update-core 待落实阻断时先拒绝" "${update_core_body}" \
    "cdn_traffic_needs_restricted_recovery"
update_sub_body=$(awk '/^update_subscription\(\)/,/^}/' "${CORE}")
assert_contains "edit-sub 保持阻断修复" "${update_sub_body}" "cdn_establish_denied_boundary"
assert_contains "edit-sub 受限时不得重启旧 Xray" "${update_sub_body}" \
    "UPDATE_SUB_ROLLBACK_NO_RESTART=1"
assert_contains "共享回滚遵守不重启标记" \
    "$(awk '/^rollback_subscription_update\(\)/,/^}/' "${XHTTP_LIB}")" \
    "UPDATE_SUB_ROLLBACK_NO_RESTART"

# --- 14. reality-target：先受限安全恢复再改 target ---------------------------
admission_body=$(awk '/^update_reality_target\(\)/,/^}/' "${PROFILE}")
assert_contains "reality-target 复用统一准入" "${admission_body}" "cdn_traffic_admission"
assert_contains "reality-target 强校验订阅" "${admission_body}" "cdn_require_valid_subscription"
assert_contains "reality-target 走核心本机事务" "${admission_body}" "cloudfront_write_subscriptions"
[[ "$(grep -n 'cdn_traffic_admission' <<<"${admission_body}" | cut -d: -f1)" \
    -lt "$(grep -n 'REALITY_TARGET=${target}' <<<"${admission_body}" | cut -d: -f1)" ]] \
    || fail_test "受限恢复必须早于 target 变更"
[[ "$(grep -n 'cdn_require_valid_subscription' <<<"${admission_body}" | cut -d: -f1)" \
    -lt "$(grep -n 'snapshot_subscription_update' <<<"${admission_body}" | cut -d: -f1)" ]] \
    || fail_test "强校验订阅必须早于快照/事务"

# --- 15. 两云失败：CF 冲突记录与 AWS 失败都明确失败且不破坏本机 ----------------
cloudflare_record_list() {
    printf '[{"id":"rec-1","type":"A","content":"203.0.113.9","proxied":false,"comment":"someone-else"}]'
}
cloudflare_api_request() { printf 'cf %s\n' "$*" >>"${TMP_DIR}/cf-calls"; return 0; }
: >"${TMP_DIR}/cf-calls"
(dns_ensure_record "${CF_ORIGIN_DOMAIN}" A "${VPS_PUBLIC_IPV4}" false) >/dev/null 2>&1 \
    && fail_test "第三方同名记录必须拒绝覆盖"
[[ ! -s "${TMP_DIR}/cf-calls" ]] || fail_test "拒绝覆盖时不得调用 Cloudflare 写 API"
cloudflare_record_list() {
    printf '[{"id":"rec-2","type":"A","content":"203.0.113.9","proxied":true,"comment":""}]'
}
if conflict_output=$(dns_ensure_record "${CF_NODE_DOMAIN}" CNAME "${AWS_CLOUDFRONT_DOMAIN}" false 2>&1); then
    fail_test "旧 A 记录不得自动转换成 CNAME"
fi
assert_contains "旧 A → CNAME 冲突必须提示清理" "${conflict_output}" \
    "已有其他类型的记录（A）；请先清理冲突记录后重装"
# 同名 AAAA/TXT 与 A 可以共存，跨类型检查不能过严而拒绝合法安装。
cloudflare_record_list() {
    printf '[{"id":"rec-3","type":"AAAA","content":"2001:db8::1","proxied":false,"comment":""}]'
}
: >"${TMP_DIR}/cf-calls"
(dns_ensure_record "${CF_ORIGIN_DOMAIN}" A "${VPS_PUBLIC_IPV4}" false) >/dev/null 2>&1 \
    || fail_test "同名 AAAA 不得阻止创建 A 记录"
assert_contains "A 与 AAAA 同名时创建 A 记录" "$(<"${TMP_DIR}/cf-calls")" "POST /zones/"
unset -f cloudflare_record_list cloudflare_api_request

before_ids="$(printf '%s|%s' "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${AWS_ACM_CERTIFICATE_ARN}")"
(
    aws_cli() { return 1; }
    aws() { return 1; }
    configure_cloudfront_distribution
) >/dev/null 2>&1 && fail_test "AWS 读取失败必须非零"
assert_equal "AWS 失败不改写已记录的分发/证书 ID" "${before_ids}" \
    "$(printf '%s|%s' "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${AWS_ACM_CERTIFICATE_ARN}")"
assert_contains "AWS 失败保留云端资源提示" \
    "$( ( aws_cli() { return 1; }; configure_cloudfront_distribution ) 2>&1 || true)" \
    "已保留现有云端资源"

# apply-cloud 在任一云失败时不得落盘新状态
state_bytes=$(<"${STATE_FILE}")
(
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    cloudflare_collect_api_token() { :; }
    persist_cloudflare_token() { :; }
    cdn_prepare_origin_dns() { return 1; }
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    apply_cloud_resources
) >/dev/null 2>&1 && fail_test "Cloudflare DNS 失败必须非零"
assert_equal "云失败不改写本机状态" "${state_bytes}" "$(<"${STATE_FILE}")"

# --- 16. 卸载通道 ------------------------------------------------------------
legacy_state="${TMP_DIR}/legacy-state.env"
cat >"${legacy_state}" <<EOF
STATE_VERSION="0"
PROTOCOL="combined"
CLOUDFLARE_ZONE_ID="zone-legacy"
CF_NODE_DOMAIN="cf-legacy.example.com"
SUBSCRIPTION_DOMAIN="sub-legacy.example.com"
DIRECT_DOMAIN="node-legacy.example.com"
CLOUDFLARE_ORIGIN_CERT_ID="cert-legacy"
EOF
state_file_before="${STATE_FILE}"
(
    STATE_FILE=${legacy_state}
    FORCE=1
    require_root() { :; }
    cdn_legacy_state_value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "${STATE_FILE}"; }
    cdn_local_uninstall_common() { printf 'LOCAL-CLEAN\n'; }
    cdn_legacy_reclaim_origin_firewall_rules() { printf 'UFW-ORIGIN\n'; }
    uninstall_legacy_cdn
) >"${TMP_DIR}/legacy-uninstall.log" 2>&1 || fail_test "旧 combined 卸载通道必须可执行"
assert_contains "旧 combined 卸载复用本机清理" "$(<"${TMP_DIR}/legacy-uninstall.log")" "LOCAL-CLEAN"
assert_contains "旧 combined 卸载回收回源 UFW" "$(<"${TMP_DIR}/legacy-uninstall.log")" "UFW-ORIGIN"
assert_contains "旧 combined 卸载提示重装" "$(<"${TMP_DIR}/legacy-uninstall.log")" "重新选择安装模式"
assert_contains "旧 combined 默认保留云端资源" "$(<"${TMP_DIR}/legacy-uninstall.log")" "已保留"
assert_equal "旧状态卸载不改写当前状态文件" "${state_file_before}" "${STATE_FILE}"
: >"${TMP_DIR}/cf-legacy-calls.log"
(
    STATE_FILE=${legacy_state}
    FORCE=1
    require_root() { :; }
    cdn_legacy_state_value() { sed -n "s/^$1=\"\(.*\)\"$/\1/p" "${STATE_FILE}"; }
    cloudflare_collect_api_token() { :; }
    cloudflare_clear_api_token() { :; }
    # 实现把 DELETE 的响应重定向到 /dev/null（避免打印云端响应），所以桩函数记到独立调用日志。
    cloudflare_api_request() { printf '%s\n' "$*" >>"${TMP_DIR}/cf-legacy-calls.log"; }
    cloudflare_record_list() {
        case "$3" in
        cf-legacy.example.com | sub-legacy.example.com | node-legacy.example.com)
            printf '[{"id":"r-%s","content":"x","comment":"easy_all combined"}]' "$3" ;;
        *) printf '[]' ;;
        esac
    }
    cdn_local_uninstall_common() { :; }
    cdn_legacy_reclaim_origin_firewall_rules() { :; }
    uninstall_legacy_cdn --purge-cloud
) >"${TMP_DIR}/legacy-purge.log" 2>&1 || fail_test "旧 combined --purge-cloud 必须可执行"
legacy_cf_calls=$(<"${TMP_DIR}/cf-legacy-calls.log")
assert_contains "旧按注释删除 DNS（含直连域名）" "${legacy_cf_calls}" \
    "dns_records/r-node-legacy.example.com"
assert_contains "旧按 ID 吊销 Origin CA" "${legacy_cf_calls}" \
    "DELETE /certificates/cert-legacy"

# --- 17. 断点续装身份：全新进程只读磁盘 --------------------------------
# 模拟中断：备份快照与 CHAIN=cloudfront marker 就位后，新 bash 进程只靠
# install-identity.json 续装。identity 必须恢复输入默认值与所有已提交字段。
install -m 0600 /dev/null "${BACKUP_DIR}/pre-install-complete"
install_progress_begin combined cloudfront
identity_before=$(<"${STATE_DIR}/install-identity.json")

resume_fields=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_SCENARIO=resume-fields \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "新进程续装必须成功：${resume_fields}"
assert_equal "续装恢复源站密钥/UUID/路径/Reality 密钥/ARN/分发 ID" \
    "FIELDS|${ORIGIN_HEADER_SECRET}|${VLESS_UUID}|${XHTTP_PATH}|${REALITY_PRIVATE_KEY}|${REALITY_PUBLIC_KEY}|arn:aws:acm:us-east-1:123456789012:certificate/new|${AWS_CLOUDFRONT_DISTRIBUTION_ID}" \
    "$(grep -F 'FIELDS|' <<<"${resume_fields}")"

resume_defaults=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_SCENARIO=resume-defaults \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "续装输入默认值必须成功：${resume_defaults}"
assert_contains "续装后的输入默认值来自恢复身份" "${resume_defaults}" \
    "RESULT|${CF_ZONE}|${CF_ORIGIN_DOMAIN}|${CF_NODE_DOMAIN}|${SUBSCRIPTION_DOMAIN}|${DIRECT_DOMAIN}|${DIRECT_NODE_NAME}|${REALITY_TARGET}|${SUB_DOWNLOAD_NAME}|${VPS_PUBLIC_IPV4}|${SCHEDULED_REBOOT_ENABLED}|${SCHEDULED_REBOOT_HOUR}"
# 续装不重新提示重启策略，直接复用身份里的选择。
install_body=$(awk '/^install_all\(\)/,/^}/' "${CORE}")
assert_contains "续装复用已保存的重启选择" "${install_body}" \
    "refresh_saved_daily_reboot_schedule"

# 中断在 core 之后、云端之前：ARN/分发 ID 为空也要恢复同一套本机身份
jq -c '.aws_acm_certificate_arn="" | .aws_cloudfront_distribution_id="" | .aws_cloudfront_domain=""' \
    <<<"${identity_before}" >"${STATE_DIR}/install-identity.json"
chmod 0600 "${STATE_DIR}/install-identity.json"
resume_core=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_SCENARIO=resume-fields \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "core 阶段中断后的续装必须成功：${resume_core}"
assert_equal "core 中断后续装仍复用同一套本机身份" \
    "FIELDS|${ORIGIN_HEADER_SECRET}|${VLESS_UUID}|${XHTTP_PATH}|${REALITY_PRIVATE_KEY}|${REALITY_PUBLIC_KEY}||" \
    "$(grep -F 'FIELDS|' <<<"${resume_core}")"

# identity 缺 chain / 协议不符：拒绝续装，而不是仅告警后继续
jq -c 'del(.chain)' <<<"${identity_before}" >"${STATE_DIR}/install-identity.json"
chmod 0600 "${STATE_DIR}/install-identity.json"
reject_chain=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_SCENARIO=resume-plain \
    bash "${BASH_SOURCE[0]}" 2>&1) && fail_test "identity 缺 chain 必须拒绝续装"
assert_contains "缺 chain 的 identity 明确拒绝续装" "${reject_chain}" "无法安全续装"

jq -c '.protocol="cloudfront"' <<<"${identity_before}" >"${STATE_DIR}/install-identity.json"
chmod 0600 "${STATE_DIR}/install-identity.json"
reject_protocol=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_SCENARIO=resume-plain \
    bash "${BASH_SOURCE[0]}" 2>&1) && fail_test "identity 协议不符必须拒绝续装"
assert_contains "协议不符的 identity 明确拒绝续装" "${reject_protocol}" "无法安全续装"

# 恢复完整身份，避免影响后续用例
printf '%s\n' "${identity_before}" >"${STATE_DIR}/install-identity.json"
chmod 0600 "${STATE_DIR}/install-identity.json"
EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_COMBINED_SCENARIO=resume-plain \
    bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || fail_test "完整身份必须可以续装"

printf 'ok - combined (direct Reality + CloudFront) profile\n'
