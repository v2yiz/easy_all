#!/usr/bin/env bash
# CloudFront 模式 2 共享核心回归测试：状态契约、CLI/manifest 接线、ACM/分发、
# 源站证书与 bootstrap、Nginx/Xray 渲染、六种订阅产物、apply 不联网、
# 熔断状态机（protection_offline 不变量、先受限恢复再采样）与凭据生命周期。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/cloudfront.sh"
CORE="${ROOT_DIR}/lib/cloudfront-mode.sh"
GUARD="${ROOT_DIR}/lib/cdn-traffic-guard.sh"

# 子进程探针复用父测试目录（EASY_ALL_TEST_TMP_DIR）：只通过磁盘状态完成单步场景。
TMP_DIR=${EASY_ALL_TEST_TMP_DIR:-$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_cloudfront_test.XXXXXX")}
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
mode_of() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}
file_digest() {
    openssl dgst -sha256 "$1" | sed 's/^.*= //'
}

syntax_files=(
    "${PROFILE}" "${CORE}" "${GUARD}" "${ROOT_DIR}/easy_all"
    "${ROOT_DIR}/lib/xhttp-runtime.sh" "${ROOT_DIR}/lib/runtime-core.sh"
    "${ROOT_DIR}/lib/profile-common.sh" "${ROOT_DIR}/lib/scheduled-maintenance.sh"
)
for syntax_file in "${syntax_files[@]}"; do
    bash -n "${syntax_file}" || fail_test "语法校验失败：${syntax_file}"
done

# --- 1. CLI / manifest / package 接线 ---------------------------------------
launcher_body=$(<"${ROOT_DIR}/easy_all")
menu_body=$(awk '/^choose_install_mode\(\)/,/^}/' "${ROOT_DIR}/easy_all")
assert_contains "菜单 2 映射到 cloudfront" "${menu_body}" "2) printf 'cloudfront\\n' ;;"
assert_contains "菜单 4 映射到 combined" "${menu_body}" "4) printf 'combined\\n' ;;"
assert_contains "菜单 3 映射到 cloudflare" "${menu_body}" "3) printf 'cloudflare\\n' ;;"
assert_contains "菜单 5 映射到 combined-cloudflare" "${menu_body}" "5) printf 'combined-cloudflare\\n' ;;"
assert_not_contains "菜单不再提供模式 4" "${menu_body}" "4. CloudFront CDN"
assert_not_contains "菜单不再映射 cdn" "${menu_body}" "printf 'cdn\\n'"
assert_contains "detect 识别旧 cdn 以便拒绝" "${launcher_body}" "cdn|combined)"
assert_contains "detect 识别新协议" "${launcher_body}" "combined-cloudfront)"
assert_contains "旧 cdn/combined 的拒绝文案引导卸载" "${launcher_body}" \
    '检测到旧 Cloudflare CDN 安装（PROTOCOL=${mode}）'
assert_contains "旧状态拒绝文案指向 uninstall 后重装" "${launcher_body}" \
    '请先执行 sudo easy_all uninstall，再执行 sudo easy_all install 重新选择安装模式'
assert_contains "不完整 CloudFront 状态有专用文案" "${launcher_body}" \
    "CloudFront 状态不完整或来自未完成实现"
assert_contains "dispatch 注册 cdn-traffic-sync" "${launcher_body}" \
    "cdn-traffic-sync)"
assert_not_contains "refresh-cdn-ips 已从帮助与路由删除" "${launcher_body}" "refresh-cdn-ips"
assert_contains "apply-cloud 路由含 cloudfront" "${launcher_body}" \
    '"${mode}" == "cloudfront" || "${mode}" == "combined-cloudfront"'
assert_contains "renew-cert 路由含 cloudfront" "${launcher_body}" \
    "cloudfront | combined-cloudfront | cloudflare | combined-cloudflare) renew_certificate"

manifest_body=$(<"${ROOT_DIR}/runtime.manifest")
assert_contains "manifest 登记共享核心" "${manifest_body}" "lib/cloudfront-mode.sh"
assert_contains "manifest 登记状态字段单一来源" "${manifest_body}" "lib/cloudfront-state.sh"
assert_contains "manifest 保留 CloudFront profile" "${manifest_body}" "profiles/cloudfront.sh"
assert_not_contains "manifest 不再登记 profiles/cdn.sh" "${manifest_body}" "profiles/cdn.sh"
package_body=$(<"${ROOT_DIR}/package.json")
assert_contains "npm test 使用重写后的 CloudFront 测试" "${package_body}" \
    "bash test/test_cloudfront_render.sh"
assert_not_contains "npm test 不再引用 test_cdn_render" "${package_body}" "test_cdn_render.sh"
assert_contains "test:cloudfront 可直接调用" "${package_body}" '"test:cloudfront"'
assert_not_contains "test:cdn 已移除" "${package_body}" '"test:cdn"'

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
export FAKE_XRAY_RESTART_FAIL=0
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
x25519) printf 'PrivateKey: test-private\nPublicKey: test-public\n' ;;
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
require_root() { :; }
sysctl() { :; }

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
trap 'status=$?; cleanup; ((TMP_DIR_CREATED == 0)) || command rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

# --- 子进程探针 ---------------------------------------------------------------
# 以全新 bash 进程重新执行本测试文件，只依靠磁盘状态完成单个场景：首装渲染、
# 订阅事务回滚/提交、后续 apply 复用模板。父测试通过 EASY_ALL_TEST_SCENARIO 选择。
probe_fresh_install_render() {
    # 首装真实路径：从没有 VLESS_CDN_DOMAIN 的进程开始，先输入校验再渲染订阅。
    unset VLESS_CDN_DOMAIN
    [[ -z "${VLESS_CDN_DOMAIN:-}" ]] || fail_test "首装探针不得预先设置 VLESS_CDN_DOMAIN"
    VLESS_UUID=44444444-5555-4666-8777-888888888888
    ORIGIN_HEADER_SECRET=fresh-probe-origin-secret-0001
    prompt_value() {
        case "$1" in
        *Zone*) printf 'refresh.example.com' ;;
        *) printf '%s' "${2:-}" ;;
        esac
    }
    prompt_secret() { printf 'cfxkgt-rmhbsn-291395-oyw'; }
    collect_aws_credentials() {
        AWS_ACCESS_KEY_ID=AKIARESUMEPROBE0001
        AWS_SECRET_ACCESS_KEY=probe-vqkzl-284267914
    }
    detect_public_ipv4() { printf '198.51.100.77'; }
    choose_subscription_config() {
        printf '%s' '{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'
    }
    collect_cloudfront_install_inputs </dev/null
    [[ "${VLESS_CDN_DOMAIN:-}" == "${CF_NODE_DOMAIN}" ]] \
        || fail_test "输入校验必须派生 VLESS_CDN_DOMAIN"
    cloudfront_write_subscriptions
    openssl base64 -d -A <"${SUBSCRIPTION_BASE64_FILE}" | grep -Fq "@${CF_NODE_DOMAIN}:443?" \
        || fail_test "首装渲染的 base64 必须包含 CloudFront 节点域名"
    grep -Fq "server: \"${CF_NODE_DOMAIN}\"" "${SUBSCRIPTION_MIHOMO_FILE}" \
        || fail_test "首装渲染的 Mihomo 订阅必须包含节点域名"
    printf 'FRESH|%s|%s\n' "${CF_NODE_DOMAIN}" "${VLESS_CDN_DOMAIN}"
}

probe_dump_subscription_objects() {
    local file
    # 订阅事务快照包含 state、Xray 配置、Nginx 配置、现用证书/私钥、六产物与模板快照：
    # 回滚必须全部恢复，任何一项残留都算半更新。
    for file in "${STATE_FILE}" "${XRAY_CONFIG}" "${NGINX_CONFIG}" "${CERT_FILE}" \
        "${KEY_FILE}" "${STATE_DIR}/mihomo-template.yaml" \
        "${SUBSCRIPTION_BASE64_FILE}" "${SUBSCRIPTION_MIHOMO_FILE}" \
        "${SUBSCRIPTION_MIHOMO_IOS_FILE}" "${SUBSCRIPTION_BASE64_ALL_FILE}" \
        "${SUBSCRIPTION_MIHOMO_ALL_FILE}" "${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE}"; do
        if [[ -f "${file}" ]]; then
            printf 'DIGEST|%s|%s\n' "${file}" "$(file_digest "${file}")"
        else
            printf 'MISSING|%s\n' "${file}"
        fi
    done
}

# 只比对订阅相关对象（state/模板/六产物）：用于 deny 边界等不改订阅的场景，
# 这些场景下 Nginx 配置失败可能留下未加载的候选文件，不属于订阅事务范围。
probe_dump_subscription_products() {
    local file
    for file in "${STATE_FILE}" "${STATE_DIR}/mihomo-template.yaml" \
        "${SUBSCRIPTION_BASE64_FILE}" "${SUBSCRIPTION_MIHOMO_FILE}" \
        "${SUBSCRIPTION_MIHOMO_IOS_FILE}" "${SUBSCRIPTION_BASE64_ALL_FILE}" \
        "${SUBSCRIPTION_MIHOMO_ALL_FILE}" "${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE}"; do
        if [[ -f "${file}" ]]; then
            printf 'DIGEST|%s|%s\n' "${file}" "$(file_digest "${file}")"
        else
            printf 'MISSING|%s\n' "${file}"
        fi
    done
}

probe_assert_template_published() {
    grep -Fq "${EASY_ALL_TEST_TEMPLATE_MARKER:?}" "${STATE_DIR}/mihomo-template.yaml" \
        || fail_test "订阅发布后模板快照应已是新模板，否则回滚断言无意义"
}

probe_update_sub_template() {
    require_root() { :; }
    case "${EASY_ALL_TEST_SUB_RESULT:-success}" in
    failure)
        # 发布新模板与六产物之后验收失败：回滚必须恢复模板快照、六产物、Xray/Nginx 配置、
        # 证书/私钥与 state。
        validate_subscription_runtime() { probe_assert_template_published; return 1; }
        ;;
    save-failure)
        validate_subscription_runtime() { probe_assert_template_published; return 0; }
        save_state() { return 1; }
        ;;
    publish-failure)
        # 发布中途失败：新模板快照与部分产物已落盘、Nginx 配置已换新后进程退出，
        # 回滚必须把六产物与新建快照一起还原，不能留下半套文件。
        cloudfront_write_subscriptions() {
            cloudfront_prepare_subscription_template
            cloudfront_persist_subscription_template
            printf 'partial-product\n' >"${SUBSCRIPTION_MIHOMO_FILE}"
            printf 'partial-product\n' >"${SUBSCRIPTION_BASE64_FILE}"
            return 1
        }
        ;;
    *)
        validate_subscription_runtime() { return 0; }
        ;;
    esac
    update_subscription </dev/null
}

# 成功事务必须真正提交：新配置写入 state、Nginx 开放配置与模板快照替换为新模板。
probe_assert_subscription_commit() {
    collect_installed_state
    grep -Fq "${EASY_ALL_TEST_SUB_TOKEN:?}" "${STATE_FILE}" \
        || fail_test "提交后 state 必须包含新订阅 Token"
    local links
    links=$(openssl base64 -d -A <"${SUBSCRIPTION_BASE64_FILE}")
    [[ "$(grep -c '^vless://' <<<"${links}")" == "1" ]] \
        || fail_test "提交后的 base64 产物必须恰好一个本机节点"
    grep -Fq "@${CF_NODE_DOMAIN}:443?" <<<"${links}" \
        || fail_test "提交后的 base64 产物必须是本机 CloudFront 节点"
    grep -Fq "${EASY_ALL_TEST_TEMPLATE_MARKER:?}" "${STATE_DIR}/mihomo-template.yaml" \
        || fail_test "提交后模板快照必须为新模板"
    grep -Fq "${ORIGIN_HEADER_SECRET}" "${NGINX_CONFIG}" \
        || fail_test "提交后 Nginx 配置必须是开放的本链路配置"
    [[ "$(jq '.inbounds | length' "${XRAY_CONFIG}")" == "2" ]] \
        || fail_test "提交后 Xray 配置必须包含 API 与 XHTTP 两个入站"
    printf 'COMMITTED\n'
}

probe_apply_reuses_template() {
    require_root() { :; }
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    install_xray_service() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    validate_subscription_runtime() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    register_easy_all_command() { :; }
    install_cdn_traffic_protection_timer() { :; }
    apply_easy_all
    grep -Fq "${EASY_ALL_TEST_TEMPLATE_MARKER:?}" "${SUBSCRIPTION_MIHOMO_FILE}" \
        || fail_test "apply 必须复用事务提交后的新模板快照"
    printf 'APPLY|%s\n' "${EASY_ALL_TEST_TEMPLATE_MARKER}"
}

# apply-cloud 的云与本机步骤全部走 stub：只验证生命周期顺序与失败传播。
apply_cloud_stubs() {
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    collect_installed_state() { :; }
    cdn_traffic_admission() { :; }
    cdn_require_valid_subscription() { :; }
    snapshot_subscription_update() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    register_easy_all_command() { printf 'REGISTER\n'; }
    install_cdn_traffic_protection_timer() { printf 'TIMER\n'; }
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    cloudflare_collect_api_token() { CLOUDFLARE_API_TOKEN=stub-token-1234567890; }
    persist_cloudflare_token() { :; }
    cdn_prepare_origin_dns() { :; }
    cdn_wait_for_origin_dns() { :; }
    cdn_issue_origin_certificate() { :; }
    find_or_request_acm_certificate() {
        printf 'acm-key=%s\n' "${AWS_ACCESS_KEY_ID:-missing}"
    }
    configure_cloudfront_distribution() {
        printf 'dist-key=%s\n' "${AWS_ACCESS_KEY_ID:-missing}"
    }
    ensure_viewer_cnames() { :; }
    wait_for_cloudfront_distribution() { return 0; }
    persist_install_identity() { :; }
    write_xray_config() { :; }
    install_xray_service() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    cloudfront_write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    cdn_validate_public_runtime() { printf 'PUBLIC-ACCEPT\n'; }
    save_state() { :; }
    commit_subscription_update() { :; }
    prompt_secret() {
        local count=0
        [[ ! -f "${TMP_DIR}/prompt.counter" ]] || count=$(<"${TMP_DIR}/prompt.counter")
        count=$((count + 1))
        printf '%s\n' "${count}" >"${TMP_DIR}/prompt.counter"
        if [[ "${count}" == "1" ]]; then
            printf 'AKIAFAKEFAKEFAKEFAKE'
        else
            printf 'stub-secret-abcdefghij-1234567890'
        fi
    }
}

# 生命周期成功条件失败路径必须在真实 set -e 进程里复现：命令替换/&& 列表会关闭 errexit。
probe_apply_timer_failure() {
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    collect_installed_state() { :; }
    cdn_traffic_admission() { :; }
    cdn_require_valid_subscription() { :; }
    snapshot_subscription_update() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    write_xray_config() { :; }
    install_xray_service() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    cloudfront_write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    save_state() { :; }
    commit_subscription_update() { :; }
    register_easy_all_command() { :; }
    install_cdn_traffic_protection_timer() { return 1; }
    apply_easy_all
}

probe_apply_cloud_public_failure() {
    apply_cloud_stubs
    cdn_validate_public_runtime() { return 1; }
    apply_cloud_resources
}

# 坏 JSON 订阅配置：结构状态仍可加载，但必须标记为损坏。
probe_load_state_corrupt() {
    collect_installed_state
    printf 'CORRUPT|%s\n' "${CDN_SUBSCRIPTION_CORRUPT}"
}

# 探针内的 systemctl：Xray 开始为 active，stop 之后变 inactive（旧 CDN 会话已终止）。
probe_systemctl_active_until_stop() {
    printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
    if [[ "${1:-}" == "stop" ]]; then
        : >"${TMP_DIR}/probe-xray-stopped"
        return 0
    fi
    if [[ "${1:-}" == "is-active" ]]; then
        [[ ! -e "${TMP_DIR}/probe-xray-stopped" ]]
        return
    fi
    return 0
}

# 建立 deny 边界时 Nginx 写不进去：仍必须停旧 Xray、非零退出，且不发布订阅。
probe_edit_sub_boundary_failure() {
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    nginx() { return 1; }
    systemctl() { probe_systemctl_active_until_stop "$@"; }
    cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
    update_subscription </dev/null
}

# F9：保持阻断的订阅修复。本机 TLS 路由验收在离线环境不可用，用真实订阅可用性
# 判定替代（它读 CDN_SUBSCRIPTION_CORRUPT 与六产物），从而验证修复后的 /subscribe 可用。
probe_edit_sub_repair() {
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    systemctl() { probe_systemctl_active_until_stop "$@"; }
    validate_subscription_runtime() {
        cdn_subscription_available || fail_test "edit-sub 成功后订阅必须可用"
        grep -Fq 'internal;' "${NGINX_CONFIG}" || fail_test "修复后 /subscribe 必须可用"
    }
    cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
    update_subscription </dev/null
}

# 新进程按磁盘状态发布六产物：父测试进程内的模板缓存可能与持久快照不同，
# 发布与就绪验收必须在同样条件下（新进程 + 快照）比较。
probe_publish_subscriptions_from_state() {
    collect_installed_state
    cloudfront_write_subscriptions
    printf 'PUBLISHED\n'
}

# F9：修复后的新进程只看磁盘状态，六产物就绪必须成立。
probe_subscription_ready_new_process() {
    collect_installed_state
    [[ "${CDN_SUBSCRIPTION_CORRUPT}" == "0" ]] \
        || fail_test "新进程不得再把修复后的订阅判为损坏"
    validate_subscription_runtime() { cdn_subscription_available; }
    cdn_subscription_ready || fail_test "新进程订阅就绪必须成功"
    printf 'READY\n'
}

# F9：修复后的新进程 sync 不得再报订阅未就绪（安全恢复与采样用 stub 隔离）。
probe_sync_after_edit_sub() {
    require_root() { :; }
    cdn_traffic_recover_restricted_runtime() { cdn_traffic_mark_restricted_recovered; }
    validate_subscription_runtime() { cdn_subscription_available; }
    cdn_traffic_update_usage() {
        CDN_TRAFFIC_OLD_BLOCKED=true
        CDN_TRAFFIC_BLOCKED=true
        CDN_TRAFFIC_NEEDS_APPLY=0
        CDN_TRAFFIC_TRANSITION=0
    }
    cdn_traffic_protection_sync
}

# --- 临重启最后采样的外部夹具 -----------------------------------------------
# 用外部 InvocationID + 计数状态模拟“restart 清零计数”，checkpoint/update_usage 走真实实现。
meter_set_stats() {
    jq -cn --argjson up "${1}" --argjson down "${2}" '
        {stat:[
          {name:"inbound>>>vless-xhttp-in>>>traffic>>>uplink",value:$up},
          {name:"inbound>>>vless-xhttp-in>>>traffic>>>downlink",value:$down}
        ]}' >"${FAKE_STATS_FILE}"
}

meter_seed_baseline() {
    local used=${1:-0}
    printf 'run-1' >"${FAKE_INVOCATION_FILE}"
    cdn_traffic_write_usage "$(jq -cn --arg period "$(cdn_traffic_current_period)" \
        --argjson used "${used}" '
        {period:$period,runtime_id:"run-1",used_bytes:$used,last_uplink:0,last_downlink:0,
         blocked:false,enforced:false,protection_offline:false}')"
    meter_set_stats 0 0
}

meter_systemctl() {
    printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
    case "${1:-}" in
    show) command cat "${FAKE_INVOCATION_FILE}" 2>/dev/null || true ;;
    is-active) return 0 ;;
    restart)
        printf '%s' "${METER_RESTART_ID:-run-2}" >"${FAKE_INVOCATION_FILE}"
        meter_set_stats 0 0
        ;;
    *) return 0 ;;
    esac
}

meter_report() {
    printf '%s|%s|%s|%s\n' "$1" \
        "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")" \
        "$(jq -r '[.blocked, .enforced] | @tsv' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")" \
        "${RUNTIME_WRITE_LOCK_DEPTH}"
}

probe_meter_sample() {
    collect_installed_state || fail_test "新进程无法读取已安装状态"
    cdn_traffic_update_usage || fail_test "新进程采样失败"
    printf 'USED|%s\n' "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
}

# apply 的调优/配置阶段耗时期间旧进程继续计数：最后 checkpoint 必须计入，restart 后才清零。
probe_apply_long_stage_metering() {
    meter_seed_baseline 0
    require_root() { :; }
    systemctl() { meter_systemctl "$@"; }
    configure_tcp_acceleration() { meter_set_stats 100 50; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    write_xray_config() { :; }
    install_xray_service() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    cloudfront_write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    save_state() { :; }
    cdn_commit_local_runtime() { :; }
    commit_subscription_update() { :; }
    apply_easy_all
    meter_report APPLY
}

probe_apply_long_stage_refusal() {
    meter_seed_baseline $((985 * 1000 * 1000 * 1000 - 100))
    require_root() { :; }
    systemctl() { meter_systemctl "$@"; }
    configure_tcp_acceleration() { meter_set_stats 100 50; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    write_xray_config() { :; }
    install_xray_service() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    cloudfront_write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    save_state() { :; }
    cdn_commit_local_runtime() { :; }
    commit_subscription_update() { :; }
    apply_easy_all
    printf 'UNEXPECTED-SUCCESS\n'
}

apply_cloud_meter_stubs() {
    require_root() { :; }
    systemctl() { meter_systemctl "$@"; }
    cloudflare_collect_api_token() { CLOUDFLARE_API_TOKEN=stub-token-for-tests; }
    collect_aws_credentials() {
        AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
        AWS_SECRET_ACCESS_KEY=stub-secret
    }
    persist_cloudflare_token() { :; }
    cdn_wait_for_origin_dns() { :; }
    cdn_issue_origin_certificate() { :; }
    find_or_request_acm_certificate() { :; }
    configure_cloudfront_distribution() { :; }
    ensure_viewer_cnames() { :; }
    wait_for_cloudfront_distribution() { :; }
    clear_aws_credentials() { :; }
    persist_install_identity() { :; }
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    write_xray_config() { :; }
    install_xray_service() { :; }
    write_nginx_config() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    cloudfront_write_subscriptions() { :; }
    validate_subscription_runtime() { :; }
    cdn_validate_public_runtime() { :; }
    save_state() { :; }
    cdn_commit_local_runtime() { :; }
    commit_subscription_update() { :; }
}

probe_apply_cloud_long_stage_metering() {
    meter_seed_baseline 0
    apply_cloud_meter_stubs
    cdn_prepare_origin_dns() { meter_set_stats 100 50; }
    apply_cloud_resources
    meter_report APPLY-CLOUD
}

# 云阶段产生流量后失败：尚未到正常临重启 checkpoint 就进入 EXIT 回滚，
# 回滚 restart 前必须采样，否则 restart 清零后阶段增量永久丢失。
probe_apply_cloud_cloud_failure() {
    meter_seed_baseline 0
    apply_cloud_meter_stubs
    cdn_prepare_origin_dns() { meter_set_stats 100 50; return 1; }
    apply_cloud_resources
    printf 'UNEXPECTED-SUCCESS\n'
}

probe_apply_cloud_cloud_failure_over_threshold() {
    meter_seed_baseline $((985 * 1000 * 1000 * 1000 - 100))
    apply_cloud_meter_stubs
    cdn_prepare_origin_dns() { meter_set_stats 100 50; return 1; }
    apply_cloud_resources
    printf 'UNEXPECTED-SUCCESS\n'
}

case "${EASY_ALL_TEST_SCENARIO:-}" in
"") ;;
fresh-install-render) probe_fresh_install_render ;;
dump-subscription-objects) probe_dump_subscription_objects ;;
dump-subscription-products) probe_dump_subscription_products ;;
update-sub-template) probe_update_sub_template ;;
assert-subscription-commit) probe_assert_subscription_commit ;;
apply-reuses-template) probe_apply_reuses_template ;;
apply-timer-failure) probe_apply_timer_failure ;;
apply-cloud-public-failure) probe_apply_cloud_public_failure ;;
load-state-corrupt) probe_load_state_corrupt ;;
edit-sub-boundary-failure) probe_edit_sub_boundary_failure ;;
edit-sub-repair) probe_edit_sub_repair ;;
publish-subscriptions-from-state) probe_publish_subscriptions_from_state ;;
subscription-ready-new-process) probe_subscription_ready_new_process ;;
sync-after-edit-sub) probe_sync_after_edit_sub ;;
meter-sample) probe_meter_sample ;;
apply-long-stage-metering) probe_apply_long_stage_metering ;;
apply-long-stage-refusal) probe_apply_long_stage_refusal ;;
apply-cloud-long-stage-metering) probe_apply_cloud_long_stage_metering ;;
apply-cloud-cloud-failure) probe_apply_cloud_cloud_failure ;;
apply-cloud-cloud-failure-over-threshold) probe_apply_cloud_cloud_failure_over_threshold ;;
*) fail_test "未知子进程场景：${EASY_ALL_TEST_SCENARIO}" ;;
esac
if [[ -n "${EASY_ALL_TEST_SCENARIO:-}" ]]; then
    exit 0
fi

# --- 3. Profile 契约 ---------------------------------------------------------
assert_equal "安装只断言 80/443 空闲" "80 443" "${CDN_INSTALL_PORTS[*]}"
assert_equal "模式 2 没有直连域名" "" "$(cdn_direct_domains)"
assert_equal "模式 2 无直连入站" "[]" "$(cdn_direct_inbounds_json)"
assert_equal "模式 2 无直连节点名" "[]" "$(cdn_direct_node_names)"
assert_equal "模式 2 不启用 Reality 适配器" "1" \
    "$(cdn_reality_enabled && echo 0 || echo 1)"
assert_equal "模式 2 直连钩子输出空链接" "" "$(build_reality_link)"
assert_equal "模式 2 直连钩子输出空节点" "" "$(build_mihomo_reality_node)"
precheck_stmt=$(sed -n '/^install_all() {/,/^}/p' "${CORE}" \
    | grep -F 'prepare_fresh_install "${CDN_INSTALL_PORTS[@]}"' || true)
[[ -n "${precheck_stmt}" ]] || fail_test "install_all 必须调用 prepare_fresh_install"
assert_contains "安装预检包含回环端口与统计 API" "${precheck_stmt}" \
    '"${XRAY_XHTTP_LOOPBACK_PORT}" 10085'
assert_contains "状态字段登记模板快照" "${CDN_STATE_VARIABLES[*]}" "MIHOMO_TEMPLATE_SNAPSHOT"
assert_contains "状态字段登记额度" "${CDN_STATE_VARIABLES[*]}" "CDN_TRAFFIC_PROTECTION_GB"

# --- 4. 状态 roundtrip 与凭据不落盘 ----------------------------------------
CF_ZONE=example.com
CLOUDFLARE_ZONE_ID=zone-123
VPS_PUBLIC_IPV4=198.51.100.10
CF_ORIGIN_DOMAIN=origin.example.com
CF_NODE_DOMAIN=cf.example.com
SUBSCRIPTION_DOMAIN=sub.example.com
SUB_DOWNLOAD_NAME=EASYALL
OWNER_TOKEN=cdnwq-rtbke-3182
ALLOWED_TOKENS=$(jq -cn --arg t "${OWNER_TOKEN}" '{owner:$t}')
SUBSCRIPTION_CONFIG=$(jq -cn --arg t "${OWNER_TOKEN}" '{allowedTokens:{owner:$t},nodes:[]}')
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
AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
AWS_SECRET_ACCESS_KEY=fake-secret-access-key-000000000000
install_progress_begin cloudfront cloudfront
save_state
persist_install_identity || fail_test "identity must be writable"
state_content=$(<"${STATE_FILE}")
assert_not_contains "state 不落盘 AWS access key" "${state_content}" "${AWS_ACCESS_KEY_ID}"
assert_not_contains "state 不落盘 AWS secret" "${state_content}" "${AWS_SECRET_ACCESS_KEY}"
assert_not_contains "identity 不落盘 AWS 凭据" \
    "$(<"${STATE_DIR}/install-identity.json")" "${AWS_ACCESS_KEY_ID}"
(
    CLOUDFLARE_API_TOKEN=stub-ztnmay-kviqrq-730640729
    persist_install_identity || exit 1
    ! grep -Fq "${CLOUDFLARE_API_TOKEN}" "${STATE_DIR}/install-identity.json"
) || fail_test "identity 不得落盘 Cloudflare Token"
assert_equal "state 权限 0600" "600" "$(mode_of "${STATE_FILE}")"
assert_equal "identity 记录 CHAIN" "cloudfront" \
    "$(jq -r '.chain' "${STATE_DIR}/install-identity.json")"
assert_equal "identity 记录 profile" "cloudfront" \
    "$(jq -r '.profile' "${STATE_DIR}/install-identity.json")"
identity_body=$(<"${STATE_DIR}/install-identity.json")
assert_equal "identity 记录 Zone" "example.com" "$(jq -r '.cf_zone' <<<"${identity_body}")"
assert_equal "identity 记录源站/节点/订阅域名" \
    "origin.example.com|cf.example.com|sub.example.com" \
    "$(jq -r '[.cf_origin_domain,.cf_node_domain,.subscription_domain]|join("|")' <<<"${identity_body}")"
assert_equal "identity 记录源站头密钥" "${ORIGIN_HEADER_SECRET}" \
    "$(jq -r '.origin_header_secret' <<<"${identity_body}")"
assert_equal "identity 记录 VPS 公网 IPv4" "${VPS_PUBLIC_IPV4}" \
    "$(jq -r '.vps_public_ipv4' <<<"${identity_body}")"
assert_equal "identity 记录分发 ID/域名" \
    "${AWS_CLOUDFRONT_DISTRIBUTION_ID}|${AWS_CLOUDFRONT_DOMAIN}" \
    "$(jq -r '[.aws_cloudfront_distribution_id,.aws_cloudfront_domain]|join("|")' <<<"${identity_body}")"
assert_equal "identity 记录 ACM ARN" "${AWS_ACM_CERTIFICATE_ARN}" \
    "$(jq -r '.aws_acm_certificate_arn' <<<"${identity_body}")"
assert_equal "identity 记录额度与下载名/节点名" \
    "985|${SUB_DOWNLOAD_NAME}|${CF_NODE_PREFIX}" \
    "$(jq -r '[.cdn_traffic_protection_gb,.sub_download_name,.cf_node_prefix]|join("|")' <<<"${identity_body}")"
assert_not_contains "state 不落盘运行时派生的 VLESS_CDN_DOMAIN" "${state_content}" \
    "VLESS_CDN_DOMAIN"
unset CF_NODE_DOMAIN SUBSCRIPTION_DOMAIN CF_ORIGIN_DOMAIN CDN_PROVIDER CDN_TRAFFIC_PROTECTION_GB
load_state
assert_equal "load_state 回填节点域名" "cf.example.com" "${CF_NODE_DOMAIN}"
assert_equal "load_state 派生 VLESS_CDN_DOMAIN" "${CF_NODE_DOMAIN}" "${VLESS_CDN_DOMAIN}"
assert_equal "load_state 保持 aws provider" "aws" "${CDN_PROVIDER}"
assert_equal "load_state 保持固定额度" "985" "${CDN_TRAFFIC_PROTECTION_GB}"
assert_equal "load_state 强制 deploy 订阅" "deploy" "${SUBSCRIPTION_MODE}"
assert_equal "load_state 恢复源站头密钥" "${ORIGIN_HEADER_SECRET}" "${ORIGIN_HEADER_SECRET}"

# 凭据清理钩子不落盘任何内容
(
    AWS_ACCESS_KEY_ID=AKIACLEAR AWS_SECRET_ACCESS_KEY=clear-me-000000000
    CLOUDFLARE_API_TOKEN=token-value
    clear_profile_credentials
    [[ -z "${AWS_ACCESS_KEY_ID:-}" && -z "${CLOUDFLARE_API_TOKEN:-}" ]]
) || fail_test "clear_profile_credentials 必须清除内存凭据"

# --- 5. 安装输入校验 --------------------------------------------------------
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
            jq -cn --arg t "${1:-}" '{allowedTokens:{owner:"cdnwq-rtbke-3182"},nodes:[]}' >/dev/null
            printf '%s' '{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'
        }
        collect_cloudfront_install_inputs </dev/null || return 1
        printf 'RESULT|%s|%s|%s|%s|%s\n' "${CF_ZONE}" "${CF_ORIGIN_DOMAIN}" \
            "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" "${CDN_TRAFFIC_PROTECTION_GB}"
    )
}
out=$(run_inputs example.com "" "" "" "" "" 2>&1) || true
assert_contains "合法输入得到默认域名" "${out}" \
    "RESULT|example.com|origin.example.com|cf.example.com|cf.example.com|985"
out=$(run_inputs example.com origin.example.com origin.example.com sub.example.com "" "" 2>&1) || true
assert_contains "源站域名不得等于节点域名" "${out}" "源站域名必须与节点域名不同"
out=$(run_inputs example.com origin.example.com cf.example.com origin.example.com "" "" 2>&1) || true
assert_contains "源站域名不得等于订阅域名" "${out}" "源站域名必须与订阅域名不同"
out=$(run_inputs example.com origin.other.test cf.other.test sub.other.test "" "" 2>&1) || true
assert_contains "域名必须属于 Zone" "${out}" "域名必须属于"
out=$(run_inputs example.com "" "" "" "PROXY" "" 2>&1) || true
assert_contains "节点名不得使用保留组名" "${out}" "节点名不能使用保留组名"

# --- 5.1 首装派生 VLESS_CDN_DOMAIN（F4） -----------------------------------
# 真实子进程：未设置 VLESS_CDN_DOMAIN、不经过 load_state/save/load，直接走
# 「安装输入校验 → 六产物渲染」；首装曾在这里因 set -u 的 unbound variable 退出。
fresh_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=fresh-install-render \
    bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "首装输入校验→订阅渲染必须成功：${fresh_out}"
assert_contains "首装渲染派生节点域名" "${fresh_out}" \
    "FRESH|cf.refresh.example.com|cf.refresh.example.com"
assert_contains "首装 RSS 产物包含节点域名" \
    "$(openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt")" \
    "@cf.refresh.example.com:443?"

# --- 6. ACM / 分发 ----------------------------------------------------------
dist_json="${TMP_DIR}/dist.json"
build_distribution_config "${dist_json}" caller-1
assert_equal "SSL 必须 sni-only" "sni-only" \
    "$(jq -r '.ViewerCertificate.SSLSupportMethod' "${dist_json}")"
assert_equal "最低 TLS 版本" "TLSv1.2_2021" \
    "$(jq -r '.ViewerCertificate.MinimumProtocolVersion' "${dist_json}")"
assert_equal "绑定 ACM ARN" "${AWS_ACM_CERTIFICATE_ARN}" \
    "$(jq -r '.ViewerCertificate.ACMCertificateArn' "${dist_json}")"
assert_equal "别名去重后包含节点与订阅" "2" "$(jq '.Aliases.Quantity' "${dist_json}")"
assert_equal "WebACL 为空" "" "$(jq -r '.WebACLId' "${dist_json}")"
assert_equal "日志关闭" "false" "$(jq -r '.Logging.Enabled' "${dist_json}")"
assert_equal "回源 https-only" "https-only" \
    "$(jq -r '.Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy' "${dist_json}")"
assert_equal "回源域名是源站域名" "${CF_ORIGIN_DOMAIN}" \
    "$(jq -r '.Origins.Items[0].DomainName' "${dist_json}")"
assert_equal "回源注入源站头" "X-Easy-All-Origin-Key" \
    "$(jq -r '.Origins.Items[0].CustomHeaders.Items[0].HeaderName' "${dist_json}")"
assert_equal "回源头值来自状态" "${ORIGIN_HEADER_SECRET}" \
    "$(jq -r '.Origins.Items[0].CustomHeaders.Items[0].HeaderValue' "${dist_json}")"
assert_equal "支持 7 种方法" "7" \
    "$(jq -r '.DefaultCacheBehavior.AllowedMethods.Quantity' "${dist_json}")"
assert_equal "启用 gRPC" "true" \
    "$(jq -r '.DefaultCacheBehavior.GrpcConfig.Enabled' "${dist_json}")"
assert_equal "使用 cache-disabled 策略" "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" \
    "$(jq -r '.DefaultCacheBehavior.CachePolicyId' "${dist_json}")"
assert_equal "使用 AllViewerExceptHostHeader 转发 query/UA" \
    "b689b0a8-53d0-40ab-baf2-68738e2966ac" \
    "$(jq -r '.DefaultCacheBehavior.OriginRequestPolicyId' "${dist_json}")"
assert_equal "分发 comment 是精确 marker" "easy_all-cloudfront-cf.example.com" \
    "$(jq -r '.Comment' "${dist_json}")"

# 节点与订阅同名时 alias 只有一项
(
    SUBSCRIPTION_DOMAIN=${CF_NODE_DOMAIN}
    build_distribution_config "${TMP_DIR}/dist-same.json" caller-2
    [[ "$(jq '.Aliases.Quantity' "${TMP_DIR}/dist-same.json")" == "1" ]]
) || fail_test "同名节点/订阅域名必须只产生一个 alias"

acm_ok='{"Certificate":{"Status":"ISSUED","CertificateArn":"arn:aws:acm:us-east-1:1:certificate/x","DomainName":"cf.example.com","SubjectAlternativeNames":["cf.example.com","sub.example.com"]}}'
cdn_acm_certificate_reusable "${acm_ok}" || fail_test "ISSUED 且覆盖 alias 的 ACM 必须可复用"
(
    broken=$(jq -c '.Certificate.Status="PENDING_VALIDATION"' <<<"${acm_ok}")
    cdn_acm_certificate_reusable "${broken}" && exit 1
    exit 0
) || fail_test "未签发 ACM 不得复用"
(
    broken=$(jq -c '.Certificate.SubjectAlternativeNames=["cf.example.com"]' <<<"${acm_ok}")
    cdn_acm_certificate_reusable "${broken}" && exit 1
    exit 0
) || fail_test "SAN 未覆盖订阅域名的 ACM 不得复用"
(
    broken=$(jq -c '.Certificate.CertificateArn="arn:aws:acm:ap-southeast-1:1:certificate/x"' <<<"${acm_ok}")
    cdn_acm_certificate_reusable "${broken}" && exit 1
    exit 0
) || fail_test "非 us-east-1 ACM 不得复用"
(
    SUBSCRIPTION_DOMAIN=eu.sub.example.com
    broken=$(jq -c '.Certificate.SubjectAlternativeNames=["cf.example.com","*.example.com"]' <<<"${acm_ok}")
    certificate_covers_required_domains "${broken}" && exit 1
    exit 0
) || fail_test "通配符不得被当作覆盖更深层的子域"

# --- 7. 源站证书：bootstrap、校验、deploy hook ------------------------------
cdn_write_origin_bootstrap_nginx || fail_test "bootstrap nginx 渲染失败"
bootstrap_conf=$(<"${NGINX_CONFIG}")
assert_contains "bootstrap 只监听 80" "${bootstrap_conf}" "listen 80;"
assert_not_contains "bootstrap 不监听 IPv6（IPv4-only 策略）" "${bootstrap_conf}" "[::]"
assert_not_contains "bootstrap 不监听 443" "${bootstrap_conf}" "listen 443"
assert_contains "bootstrap 提供 HTTP-01 路径" "${bootstrap_conf}" ".well-known/acme-challenge"
assert_not_contains "bootstrap 不提供代理或订阅" "${bootstrap_conf}" "grpc_pass"
assert_not_contains "不再有自签兜底" "$(<"${CORE}")" "req -x509"

make_cert() { # $1=domain $2=keyfile $3=certfile
    local domain=$1 key=$2 cert=$3 csr="${TMP_DIR}/csr.$$.$RANDOM"
    openssl ecparam -name prime256v1 -genkey -noout -out "${key}" >/dev/null 2>&1
    openssl req -new -key "${key}" -subj "/CN=${domain}" -out "${csr}" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\n' "${domain}" >"${TMP_DIR}/san.ext"
    openssl x509 -req -in "${csr}" -CA "${TMP_DIR}/ca.pem" -CAkey "${TMP_DIR}/ca.key" \
        -CAcreateserial -days 30 -extfile "${TMP_DIR}/san.ext" -out "${cert}" >/dev/null 2>&1
}
openssl ecparam -name prime256v1 -genkey -noout -out "${TMP_DIR}/ca.key" >/dev/null 2>&1
openssl req -x509 -new -key "${TMP_DIR}/ca.key" -sha256 -days 30 \
    -subj "/CN=easy_all test CA" -out "${TMP_DIR}/ca.pem" >/dev/null 2>&1
make_cert "${CF_ORIGIN_DOMAIN}" "${KEY_FILE}" "${CERT_FILE}"
SSL_CERT_FILE="${TMP_DIR}/ca.pem"
export SSL_CERT_FILE
cdn_verify_origin_certificate || fail_test "受信 CA 签发的源站证书必须通过验收"
make_cert wrong.example.com "${TMP_DIR}/wrong.key" "${TMP_DIR}/wrong.pem"
if ( CERT_FILE="${TMP_DIR}/wrong.pem"; KEY_FILE="${TMP_DIR}/wrong.key"; cdn_verify_origin_certificate ) \
    >/dev/null 2>&1; then
    fail_test "未覆盖源站域名的证书必须验收失败"
fi
make_cert "${CF_ORIGIN_DOMAIN}" "${TMP_DIR}/other.key" "${TMP_DIR}/other.pem"
if ( CERT_FILE="${TMP_DIR}/other.pem"; KEY_FILE="${KEY_FILE}"; cdn_verify_origin_certificate ) \
    >/dev/null 2>&1; then
    fail_test "证书与私钥不配对必须验收失败"
fi

# --- 7.1 Let's Encrypt fullchain 链校验（F6） --------------------------------
# 离线生成 root→intermediate→leaf 三级链，复现 Certbot fullchain.pem 的真实形态。
chain_dir="${TMP_DIR}/chain-fixture"
mkdir -p "${chain_dir}/cadb"
: >"${chain_dir}/cadb/index.txt"
printf '2000\n' >"${chain_dir}/cadb/serial"
openssl ecparam -name prime256v1 -genkey -noout -out "${chain_dir}/root.key" >/dev/null 2>&1
openssl req -x509 -new -key "${chain_dir}/root.key" -sha256 -days 30 \
    -subj "/CN=easy_all chain root" -out "${chain_dir}/root.pem" >/dev/null 2>&1
openssl ecparam -name prime256v1 -genkey -noout -out "${chain_dir}/int.key" >/dev/null 2>&1
openssl req -new -key "${chain_dir}/int.key" -subj "/CN=easy_all chain intermediate" \
    -out "${chain_dir}/int.csr" >/dev/null 2>&1
cat >"${chain_dir}/int.ext" <<'CHAIN_EOF'
basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid
CHAIN_EOF
openssl x509 -req -in "${chain_dir}/int.csr" -CA "${chain_dir}/root.pem" \
    -CAkey "${chain_dir}/root.key" -CAcreateserial -days 30 \
    -extfile "${chain_dir}/int.ext" -out "${chain_dir}/int.pem" >/dev/null 2>&1

chain_sign_leaf() { # $1=domain $2=private key $3=cert
    local domain=$1 key=$2 cert=$3 csr="${chain_dir}/leaf.csr"
    openssl ecparam -name prime256v1 -genkey -noout -out "${key}" >/dev/null 2>&1
    openssl req -new -key "${key}" -subj "/CN=${domain}" -out "${csr}" >/dev/null 2>&1
    printf 'subjectAltName=DNS:%s\nbasicConstraints=CA:FALSE\n' "${domain}" \
        >"${chain_dir}/leaf.ext"
    openssl x509 -req -in "${csr}" -CA "${chain_dir}/int.pem" -CAkey "${chain_dir}/int.key" \
        -CAcreateserial -days 30 -extfile "${chain_dir}/leaf.ext" -out "${cert}" >/dev/null 2>&1
}
chain_sign_leaf "${CF_ORIGIN_DOMAIN}" "${chain_dir}/leaf.key" "${chain_dir}/leaf.pem"
cat "${chain_dir}/leaf.pem" "${chain_dir}/int.pem" >"${chain_dir}/fullchain.pem"

(
    CERT_FILE=${chain_dir}/fullchain.pem
    KEY_FILE=${chain_dir}/leaf.key
    SSL_CERT_FILE=${chain_dir}/root.pem
    cdn_verify_origin_certificate
) || fail_test "root→intermediate→leaf 的 LE 形态 fullchain 必须通过验收"

# 单证书（无 intermediate）仍要支持
(
    SSL_CERT_FILE=${chain_dir}/root.pem
    cdn_origin_certificate_chain_valid "${chain_dir}/root.pem"
) || fail_test "无 intermediate 的单证书链必须验证通过"

cat "${chain_dir}/leaf.pem" >"${chain_dir}/leaf-only.pem"
if ( SSL_CERT_FILE=${chain_dir}/root.pem; \
    cdn_origin_certificate_chain_valid "${chain_dir}/leaf-only.pem" ) >/dev/null 2>&1; then
    fail_test "缺少 intermediate 的 fullchain 必须验证失败"
fi

openssl ecparam -name prime256v1 -genkey -noout -out "${chain_dir}/other-root.key" >/dev/null 2>&1
openssl req -x509 -new -key "${chain_dir}/other-root.key" -sha256 -days 30 \
    -subj "/CN=easy_all other root" -out "${chain_dir}/other-root.pem" >/dev/null 2>&1
if ( CERT_FILE=${chain_dir}/fullchain.pem; KEY_FILE=${chain_dir}/leaf.key
    SSL_CERT_FILE=${chain_dir}/other-root.pem; cdn_verify_origin_certificate ) >/dev/null 2>&1; then
    fail_test "不受信任根证书签发的链必须验收失败"
fi

chain_sign_leaf wrong.example.com "${chain_dir}/wrong-domain.key" "${chain_dir}/wrong-domain.pem"
cat "${chain_dir}/wrong-domain.pem" "${chain_dir}/int.pem" \
    >"${chain_dir}/wrong-domain-fullchain.pem"
if ( CERT_FILE=${chain_dir}/wrong-domain-fullchain.pem; KEY_FILE=${chain_dir}/wrong-domain.key
    SSL_CERT_FILE=${chain_dir}/root.pem; cdn_verify_origin_certificate ) >/dev/null 2>&1; then
    fail_test "未覆盖源站域名的链必须验收失败"
fi

chain_sign_leaf "${CF_ORIGIN_DOMAIN}" "${chain_dir}/other-leaf.key" "${chain_dir}/other-leaf.pem"
cat "${chain_dir}/other-leaf.pem" "${chain_dir}/int.pem" >"${chain_dir}/other-leaf-fullchain.pem"
if ( CERT_FILE=${chain_dir}/other-leaf-fullchain.pem; KEY_FILE=${chain_dir}/leaf.key
    SSL_CERT_FILE=${chain_dir}/root.pem; cdn_verify_origin_certificate ) >/dev/null 2>&1; then
    fail_test "证书与私钥不配对必须验收失败"
fi

# 过期证书：用 openssl ca 指定过去有效区间（离线，不依赖系统时间伪造工具）。
cat >"${chain_dir}/ca.cnf" <<CA_EOF
[ ca ]
default_ca = CA_default
[ CA_default ]
dir = ${chain_dir}/cadb
database = \$dir/index.txt
new_certs_dir = \$dir
serial = \$dir/serial
certificate = ${chain_dir}/int.pem
private_key = ${chain_dir}/int.key
default_md = sha256
policy = policy_any
x509_extensions = leaf_ext
unique_subject = no
[ policy_any ]
commonName = supplied
[ leaf_ext ]
subjectAltName = DNS:${CF_ORIGIN_DOMAIN}
basicConstraints = CA:FALSE
CA_EOF
openssl ecparam -name prime256v1 -genkey -noout -out "${chain_dir}/expired.key" >/dev/null 2>&1
openssl req -new -key "${chain_dir}/expired.key" \
    -subj "/CN=${CF_ORIGIN_DOMAIN}" -out "${chain_dir}/expired.csr" >/dev/null 2>&1
openssl ca -config "${chain_dir}/ca.cnf" -batch -noemailDN -notext \
    -startdate 20200101000000Z -enddate 20200201000000Z \
    -in "${chain_dir}/expired.csr" -out "${chain_dir}/expired.pem" >/dev/null 2>&1
cat "${chain_dir}/expired.pem" "${chain_dir}/int.pem" >"${chain_dir}/expired-fullchain.pem"
if ( CERT_FILE=${chain_dir}/expired-fullchain.pem; KEY_FILE=${chain_dir}/expired.key
    SSL_CERT_FILE=${chain_dir}/root.pem; cdn_verify_origin_certificate ) >/dev/null 2>&1; then
    fail_test "过期证书必须验收失败"
fi

# --- 7.2 证书部署事务（F13） -------------------------------------------------
initialize_cdn_traffic_usage >/dev/null
lineage_dir="${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}"
install -d -m 0700 "${lineage_dir}"
live_digest=$(file_digest "${CERT_FILE}")

run_install_lineage() { # $1=替换函数名（可选）
    local override=${1:-}
    (
        [[ -z "${override}" ]] || eval "${override}"
        cdn_install_origin_lineage
    )
}
copy_lineage() { # $1=fullchain $2=key
    install -m 0644 "$1" "${lineage_dir}/fullchain.pem"
    install -m 0600 "$2" "${lineage_dir}/privkey.pem"
}

# 复制失败：lineage 私钥不可读，安装前就失败，现用证书不变
if [[ "$(id -u)" != "0" ]]; then
    copy_lineage "${chain_dir}/fullchain.pem" "${chain_dir}/leaf.key"
    chmod 000 "${lineage_dir}/privkey.pem"
    if run_install_lineage >/dev/null 2>&1; then
        fail_test "复制 lineage 失败必须返回非零"
    fi
    chmod 600 "${lineage_dir}/privkey.pem"
    assert_equal "复制失败不改写现用证书" "${live_digest}" "$(file_digest "${CERT_FILE}")"
fi

# 候选验证失败：lineage 域名不符，现用证书不变
copy_lineage "${chain_dir}/wrong-domain-fullchain.pem" "${chain_dir}/wrong-domain.key"
if run_install_lineage >/dev/null 2>&1; then
    fail_test "未覆盖源站域名的新 lineage 必须部署失败"
fi
assert_equal "候选验证失败不改写现用证书" "${live_digest}" "$(file_digest "${CERT_FILE}")"

# nginx -t 失败：安装后回滚现用证书与 Nginx 配置，新 lineage 保留供重试
nginx_digest=$(file_digest "${NGINX_CONFIG}")
copy_lineage "${chain_dir}/fullchain.pem" "${chain_dir}/leaf.key"
if run_install_lineage 'nginx() { return 1; }' >/dev/null 2>&1; then
    fail_test "nginx -t 失败必须让部署事务失败"
fi
assert_equal "nginx -t 失败恢复现用证书" "${live_digest}" "$(file_digest "${CERT_FILE}")"
assert_equal "nginx -t 失败恢复部署前 Nginx 配置" "${nginx_digest}" \
    "$(file_digest "${NGINX_CONFIG}")"
[[ -s "${lineage_dir}/fullchain.pem" && -s "${lineage_dir}/privkey.pem" ]] \
    || fail_test "部署失败必须保留新 LE lineage 供重试"

# 重载失败：安装后回滚现用证书
if run_install_lineage \
    'systemctl() { [[ "${1:-}" != reload && "${1:-}" != restart ]] || return 1; return 0; }' \
    >/dev/null 2>&1; then
    fail_test "Nginx 重载失败必须让部署事务失败"
fi
assert_equal "重载失败恢复现用证书" "${live_digest}" "$(file_digest "${CERT_FILE}")"
assert_equal "重载失败恢复部署前 Nginx 配置" "${nginx_digest}" \
    "$(file_digest "${NGINX_CONFIG}")"

# 事务成功：现用证书变为新 lineage
copy_lineage "${chain_dir}/fullchain.pem" "${chain_dir}/leaf.key"
(
    SSL_CERT_FILE=${chain_dir}/root.pem
    cdn_install_origin_lineage
) || fail_test "有效 lineage 必须部署成功"
assert_equal "部署成功后现用证书是新 lineage" \
    "$(file_digest "${chain_dir}/fullchain.pem")" "$(file_digest "${CERT_FILE}")"

# 手动 renew-cert：已有较新有效 lineage 时直接部署，不重复签发
certbot_log="${TMP_DIR}/certbot-renew.log"
: >"${certbot_log}"
cat "${TMP_DIR}/ca.pem" "${chain_dir}/root.pem" >"${chain_dir}/trust-bundle.pem"
run_renew() {
    (
        SSL_CERT_FILE=${chain_dir}/trust-bundle.pem
        export SSL_CERT_FILE
        certbot() { printf '%s\n' "$*" >>"${certbot_log}"; }
        install_certbot_deploy_hook() { :; }
        validate_protocol_runtime() { :; }
        validate_subscription_runtime() { :; }
        release_runtime_write_lock() { :; }
        acquire_runtime_write_lock() { :; }
        require_root() { :; }
        renew_certificate
    )
}
copy_lineage "${chain_dir}/fullchain.pem" "${chain_dir}/leaf.key"
# 先让现用副本回到另一份有效证书，lineage 才构成“较新、未部署”
make_cert "${CF_ORIGIN_DOMAIN}" "${TMP_DIR}/deployed.key" "${TMP_DIR}/deployed.pem"
install -m 0644 "${TMP_DIR}/deployed.pem" "${CERT_FILE}"
install -m 0600 "${TMP_DIR}/deployed.key" "${KEY_FILE}"
run_renew >/dev/null 2>&1 || fail_test "存在较新有效 lineage 时 renew-cert 必须成功"
[[ ! -s "${certbot_log}" ]] || fail_test "存在可部署的新 lineage 时不得重复签发：$(<"${certbot_log}")"
assert_equal "renew-cert 部署较新 lineage" \
    "$(file_digest "${chain_dir}/fullchain.pem")" "$(file_digest "${CERT_FILE}")"

# 没有可部署的新 lineage：必须带 --force-renewal 重新签发
copy_lineage "${CERT_FILE}" "${KEY_FILE}"
run_renew >/dev/null 2>&1 || fail_test "无新 lineage 时 renew-cert 必须调用 certbot"
assert_contains "手动续签使用 --force-renewal" "$(<"${certbot_log}")" "--force-renewal"

# renew-cert 的部署事务：验证→reload 任一步失败必须恢复现用证书与 Nginx 配置，
# 不得留下“证书已换、Nginx 未生效”的半部署。
run_renew_with_reload_failure() {
    (
        SSL_CERT_FILE=${chain_dir}/trust-bundle.pem
        export SSL_CERT_FILE
        certbot() { fail_test "已有有效新 lineage 时不得重复签发"; }
        install_certbot_deploy_hook() { :; }
        validate_protocol_runtime() { :; }
        validate_subscription_runtime() { :; }
        release_runtime_write_lock() { :; }
        acquire_runtime_write_lock() { :; }
        require_root() { :; }
        systemctl() { [[ "${1:-}" != reload && "${1:-}" != restart ]] || return 1; return 0; }
        renew_certificate
    )
}
copy_lineage "${chain_dir}/fullchain.pem" "${chain_dir}/leaf.key"
make_cert "${CF_ORIGIN_DOMAIN}" "${TMP_DIR}/renew-before.key" "${TMP_DIR}/renew-before.pem"
install -m 0644 "${TMP_DIR}/renew-before.pem" "${CERT_FILE}"
install -m 0600 "${TMP_DIR}/renew-before.key" "${KEY_FILE}"
cert_before_failure=$(file_digest "${CERT_FILE}")
nginx_before_failure=$(file_digest "${NGINX_CONFIG}")
if run_renew_with_reload_failure >"${TMP_DIR}/renew-reload-failure.log" 2>&1; then
    fail_test "renew-cert 部署后重载失败必须非零"
fi
assert_equal "renew-cert 重载失败恢复现用证书（禁止半部署）" \
    "${cert_before_failure}" "$(file_digest "${CERT_FILE}")"
assert_equal "renew-cert 重载失败恢复部署前 Nginx 配置" \
    "${nginx_before_failure}" "$(file_digest "${NGINX_CONFIG}")"
assert_contains "renew-cert 重载失败明确告警回滚" \
    "$(<"${TMP_DIR}/renew-reload-failure.log")" "源站证书部署失败"
[[ -s "${lineage_dir}/fullchain.pem" ]] \
    || fail_test "部署失败必须保留新 lineage 供 renew-cert 重试"

# apply-cloud：源站证书部署事务失败时整条命令非零，本机 state 与现用证书都不变。
cert_before_cloud=$(file_digest "${CERT_FILE}")
state_before_cloud=$(file_digest "${STATE_FILE}")
cloud_cert_out=$(
    apply_cloud_stubs
    collect_aws_credentials() {
        AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
        AWS_SECRET_ACCESS_KEY=stub-secret-abcdefghij-1234567890
    }
    cdn_issue_origin_certificate() {
        install -d -m 0700 "${lineage_dir}"
        install -m 0644 "${chain_dir}/fullchain.pem" "${lineage_dir}/fullchain.pem"
        install -m 0600 "${chain_dir}/leaf.key" "${lineage_dir}/privkey.pem"
        cdn_write_origin_bootstrap_nginx
        SSL_CERT_FILE=${chain_dir}/trust-bundle.pem cdn_install_origin_lineage
    }
    systemctl() { [[ "${1:-}" != reload && "${1:-}" != restart ]] || return 1; return 0; }
    apply_cloud_resources
) 2>&1 && fail_test "apply-cloud 证书部署事务失败必须非零"
assert_equal "apply-cloud 证书事务失败不改现用证书" \
    "${cert_before_cloud}" "$(file_digest "${CERT_FILE}")"
assert_equal "apply-cloud 证书事务失败不改 state" \
    "${state_before_cloud}" "$(file_digest "${STATE_FILE}")"
assert_not_contains "apply-cloud 证书事务失败不报同步成功" "${cloud_cert_out}" "已同步"
assert_not_contains "apply-cloud 证书事务失败不恢复定时器" "${cloud_cert_out}" "TIMER"

# 后续 hook 用例回到测试 CA 签发的现用证书（本节的升级链只在事务用例内验证）。
make_cert "${CF_ORIGIN_DOMAIN}" "${KEY_FILE}" "${CERT_FILE}"

# 受管 deploy hook 内容与跳过语义
install_certbot_deploy_hook
hook_body=$(<"${EASY_ALL_CERTBOT_HOOK_FILE_OVERRIDE}")
assert_contains "hook 识别手动抑制变量" "${hook_body}" "EASY_ALL_CERTBOT_SKIP_DEPLOY"
assert_contains "hook 由核心部署函数承担" "${hook_body}" "cloudfront_certbot_deploy_hook"
(
    EASY_ALL_CERTBOT_SKIP_DEPLOY=1
    rm() { fail_test "skip 路径不得删除或改写证书"; }
    cloudfront_certbot_deploy_hook
) || fail_test "EASY_ALL_CERTBOT_SKIP_DEPLOY=1 时 hook 必须直接返回"

# deploy hook 与手动续签共用同一部署事务：Nginx 重渲染失败必须回滚现用证书
make_cert "${CF_ORIGIN_DOMAIN}" "${TMP_DIR}/hook-new.key" "${TMP_DIR}/hook-new.pem"
copy_lineage "${TMP_DIR}/hook-new.pem" "${TMP_DIR}/hook-new.key"
hook_digest=$(file_digest "${CERT_FILE}")
if (
    collect_installed_state() { :; }
    write_nginx_config() { return 1; }
    cloudfront_certbot_deploy_hook
) >/dev/null 2>&1; then
    fail_test "hook 部署失败必须返回非零"
fi
assert_equal "hook 部署失败回滚现用证书" "${hook_digest}" "$(file_digest "${CERT_FILE}")"

# 手动签发路径抑制自有 hook，并由父命令完成部署
:
fake_certbot_log="${TMP_DIR}/certbot.log"
(
    certbot() {
        printf 'skip=%s\n' "${EASY_ALL_CERTBOT_SKIP_DEPLOY:-0}" >>"${fake_certbot_log}"
        install -d -m 0700 "${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}"
        command cp "${CERT_FILE}" "${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}/fullchain.pem"
        command cp "${KEY_FILE}" "${EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE}/privkey.pem"
    }
    cdn_issue_origin_certificate 1
) || fail_test "手动签发路径必须完成部署"
assert_contains "手动签发抑制本进程 hook" "$(<"${fake_certbot_log}")" "skip=1"
assert_equal "父命令部署后证书存在" "0" "$([[ -s "${CERT_FILE}" ]] && echo 0 || echo 1)"

# --- 8. Nginx / Xray 渲染 ---------------------------------------------------
cdn_render_nginx_config 0 1 >"${TMP_DIR}/nginx-final.conf"
final_conf=$(<"${TMP_DIR}/nginx-final.conf")
assert_contains "80 只为源站 HTTP-01" "${final_conf}" "server_name ${CF_ORIGIN_DOMAIN};"
assert_contains "最终配置监听 IPv4 80" "${final_conf}" "listen 80;"
assert_not_contains "最终配置不监听 IPv6（IPv4-only 策略）" "${final_conf}" "[::]"
assert_contains "443 默认 server 拒绝未知 SNI" "${final_conf}" "ssl_reject_handshake on;"
assert_contains "health 需要源站头" "${final_conf}" \
    'if ($http_x_easy_all_origin_key != "'"${ORIGIN_HEADER_SECRET}"'") { return 404; }'
assert_contains "XHTTP 缺/错源站头返回 403" "${final_conf}" \
    'if ($http_x_easy_all_origin_key != "'"${ORIGIN_HEADER_SECRET}"'") { return 403; }'
assert_contains "XHTTP 精确前缀保护" "${final_conf}" "location ^~ ${XHTTP_PATH}/ {"
assert_contains "回源 Host 重写为节点域名" "${final_conf}" \
    "grpc_set_header Host ${CF_NODE_DOMAIN};"
assert_contains "回源到本机 XHTTP 端口" "${final_conf}" \
    "grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};"
assert_contains "Token map 默认拒绝" "${final_conf}" "default __denied__;"
assert_contains "Token map 包含 owner token" "${final_conf}" "\"${OWNER_TOKEN}\" 1;"
assert_contains "订阅需要源站头" "${final_conf}" "location = /subscribe {"
assert_contains "internal alias 只允许内部跳转" "${final_conf}" "internal;"
assert_contains "内部订阅文件路径" "${final_conf}" "/_easy_all_subscription/base64"
assert_contains "未知路径 404" "${final_conf}" "location / { return 404; }"
assert_not_contains "最终配置不提供裸 XHTTP 路径" "${final_conf}" \
    "location ${XHTTP_PATH}/ {"

cdn_render_nginx_config 1 0 >"${TMP_DIR}/nginx-blocked.conf"
blocked_conf=$(<"${TMP_DIR}/nginx-blocked.conf")
assert_contains "阻断时 XHTTP 返回 503" "${blocked_conf}" "return 503;"
assert_contains "订阅不可用时 /subscribe 503" "${blocked_conf}" "location = /subscribe {"
assert_not_contains "阻断且订阅不可用时不发布 internal alias" "${blocked_conf}" "internal;"
assert_contains "阻断时 health 保留" "${blocked_conf}" "easy_all ok"

cdn_render_nginx_config 1 1 >"${TMP_DIR}/nginx-blocked-sub.conf"
blocked_sub_conf=$(<"${TMP_DIR}/nginx-blocked-sub.conf")
assert_contains "阻断但订阅可用时保持 /subscribe 可下载" "${blocked_sub_conf}" "internal;"
assert_contains "阻断仍保留 XHTTP 503" "${blocked_sub_conf}" "return 503;"

render_xray_config 0
xray_conf=$(<"${XRAY_CONFIG}")
assert_equal "模式 2 只有 API 与 XHTTP 两个入站" "2" "$(jq '.inbounds | length' <<<"${xray_conf}")"
assert_equal "API 只绑定回环" "easy-all-api" "$(jq -r '.inbounds[0].tag' <<<"${xray_conf}")"
assert_equal "API 端口 10085" "10085" "$(jq -r '.inbounds[0].port' <<<"${xray_conf}")"
assert_equal "API 服务只含 StatsService" "StatsService" \
    "$(jq -r '.api.services[0]' <<<"${xray_conf}")"
assert_equal "stats 启用" "{}" "$(jq -c '.stats' <<<"${xray_conf}")"
assert_equal "统计入站上下行" "true" \
    "$(jq -r '.policy.system.statsInboundUplink' <<<"${xray_conf}")"
assert_equal "XHTTP 入站 tag" "vless-xhttp-in" "$(jq -r '.inbounds[1].tag' <<<"${xray_conf}")"
assert_equal "XHTTP 只监听回环" "127.0.0.1" "$(jq -r '.inbounds[1].listen' <<<"${xray_conf}")"
assert_equal "XHTTP 转发 Host 为节点域名" "${CF_NODE_DOMAIN}" \
    "$(jq -r '.inbounds[1].streamSettings.xhttpSettings.host' <<<"${xray_conf}")"
assert_equal "正常运行包含一个 client" "1" \
    "$(jq '.inbounds[1].settings.clients | length' <<<"${xray_conf}")"
assert_not_contains "模式 2 不含 Reality 入站" "${xray_conf}" "vless-reality-in"
assert_equal "路由首条把 API 入站交给 API tag" "easy-all-api" \
    "$(jq -r '.routing.rules[0].outboundTag' <<<"${xray_conf}")"

render_xray_config 1
xray_blocked=$(<"${XRAY_CONFIG}")
assert_equal "阻断时 XHTTP clients 为空" "0" \
    "$(jq '.inbounds[1].settings.clients | length' <<<"${xray_blocked}")"
assert_equal "阻断时最优先 XHTTP block 路由" "block" \
    "$(jq -r '.routing.rules[1].outboundTag' <<<"${xray_blocked}")"
assert_equal "block 规则只针对 XHTTP 入站" "vless-xhttp-in" \
    "$(jq -r '.routing.rules[1].inboundTag[0]' <<<"${xray_blocked}")"
assert_equal "阻断不影响统计/API" "easy-all-api" \
    "$(jq -r '.routing.rules[0].inboundTag[0]' <<<"${xray_blocked}")"

# --- 9. 六种订阅产物与单节点 ------------------------------------------------
initialize_cdn_traffic_usage
cloudfront_write_subscriptions
for file in base64.txt mihomo.yaml mihomo-ios.yaml base64-all.txt mihomo-all.yaml mihomo-ios-all.yaml; do
    [[ -s "${SUBSCRIPTION_DIR}/${file}" ]] || fail_test "缺少订阅产物：${file}"
done
decoded_links=$(openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt")
assert_equal "base64 恰有一个 vless 节点" "1" \
    "$(grep -c '^vless://' <<<"${decoded_links}")"
assert_contains "节点连接 CloudFront 域名" "${decoded_links}" "@${CF_NODE_DOMAIN}:443?"
assert_contains "节点名使用完整单节点名" "${decoded_links}" "#%F0%9F%87%BA%F0%9F%87%B8AWS"
assert_not_contains "base64 不含 Reality 节点" "${decoded_links}" "security=reality"
mihomo_body=$(<"${SUBSCRIPTION_DIR}/mihomo.yaml")
assert_contains "mihomo 节点连接 CloudFront 域名" "${mihomo_body}" "server: \"${CF_NODE_DOMAIN}\""
assert_contains "mihomo 节点名是完整单节点名" "${mihomo_body}" "name: \"${CF_NODE_PREFIX}\""
assert_equal "mihomo 只有一个本机节点" "1" "$(grep -c '^  - name: ' <<<"${mihomo_body}")"
assert_not_contains "不再生成 CDN-AUTO 组" "${mihomo_body}" "CDN-AUTO"
assert_not_contains "不再生成 CDN-FALLBACK 组" "${mihomo_body}" "CDN-FALLBACK"
assert_contains "PROXY 是 select" "${mihomo_body}" "- name: PROXY"
assert_contains "GLOBAL 只引用 PROXY" "${mihomo_body}" "- name: GLOBAL"
assert_contains "模板快照持久化" "${MIHOMO_TEMPLATE_SNAPSHOT}" "1"
[[ -s "${STATE_DIR}/mihomo-template.yaml" ]] || fail_test "模板必须持久化到状态目录"
assert_equal "模板快照权限 0600" "600" "$(mode_of "${STATE_DIR}/mihomo-template.yaml")"
# iOS 变体剥掉 sniffer 段
assert_not_contains "iOS 产物不含 sniffer" "$(<"${SUBSCRIPTION_DIR}/mihomo-ios.yaml")" "sniffer:"
all_body=$(<"${SUBSCRIPTION_DIR}/mihomo-all.yaml")
assert_contains "all 变体保留同一节点" "${all_body}" "server: \"${CF_NODE_DOMAIN}\""
# 保护状态不删除订阅节点
(
    cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
    cloudfront_write_subscriptions
    openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt"
) | grep -Fq "@${CF_NODE_DOMAIN}:443?" \
    || fail_test "熔断阻断节点仍必须保留在有效订阅中"
cdn_traffic_write_usage "$(jq -c '.blocked=false | .enforced=false | .protection_offline=false' \
    "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"

# --- 9.1 订阅就绪：六产物逐字节对比与节点身份（F12） --------------------------
# validate_subscription_runtime 是实现依赖的本机 TLS 路由验收：这里只替换网络部分，
# 让六产物对比与节点身份校验（节点数量/UUID/path/顺序）走真实实现。
subscription_ready_local() {
    (
        validate_subscription_runtime() { return 0; }
        cdn_subscription_ready
    )
}
subscription_ready_local || fail_test "刚发布的六产物必须判为就绪"
cdn_subscription_local_nodes_ready "${SUBSCRIPTION_DIR}" \
    || fail_test "模式 2 的单一 CloudFront 节点必须通过节点身份验收"

restore_subscriptions() {
    ( cloudfront_write_subscriptions ) >/dev/null 2>&1 \
        || fail_test "重发六产物必须成功"
}
# 缺失任一产物（含 iOS/all 变体）不得判就绪
for missing in mihomo-all.yaml mihomo-ios.yaml base64-all.txt; do
    command rm -f -- "${SUBSCRIPTION_DIR}/${missing}"
    if subscription_ready_local; then
        fail_test "缺失 ${missing} 时不得判订阅就绪"
    fi
    restore_subscriptions
done
# 上一代 UUID 的产物：与当前 state 不一致即未就绪
old_uuid=00000000-1111-4111-8111-000000000000
openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt" \
    | sed "s/${VLESS_UUID}/${old_uuid}/" | openssl base64 -A >"${TMP_DIR}/old-base64.txt"
printf '\n' >>"${TMP_DIR}/old-base64.txt"
install -m 0640 "${TMP_DIR}/old-base64.txt" "${SUBSCRIPTION_DIR}/base64.txt"
if subscription_ready_local; then
    fail_test "旧 UUID 产物不得判为订阅就绪"
fi
cdn_subscription_local_nodes_ready "${SUBSCRIPTION_DIR}" \
    && fail_test "旧 UUID 的 CloudFront 节点不得通过节点身份验收"
restore_subscriptions
# 节点数量：模式 2 多一个本机节点不得通过
ready_dir="${TMP_DIR}/ready-check"
install -d -m 0700 "${ready_dir}"
install -m 0640 "${SUBSCRIPTION_DIR}"/*.txt "${SUBSCRIPTION_DIR}"/*.yaml "${ready_dir}/"
current_links=$(openssl base64 -d -A <"${ready_dir}/base64.txt")
{
    printf '%s\n' "${current_links}"
    printf '%s\n' "${current_links}"
} | openssl base64 -A >"${ready_dir}/base64.txt.duplicated"
printf '\n' >>"${ready_dir}/base64.txt.duplicated"
command mv -f -- "${ready_dir}/base64.txt.duplicated" "${ready_dir}/base64.txt"
cdn_subscription_local_nodes_ready "${ready_dir}" \
    && fail_test "模式 2 出现两个本机节点时不得判就绪"
# path 不符（上一代 XHTTP 路径）不得通过
current_path=$(uri_encode "$(xhttp_client_path)")
openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt" \
    | sed "s#path=${current_path}#path=%2Fxhttp-oldpath123456%2F#" \
    | openssl base64 -A >"${ready_dir}/base64.txt"
printf '\n' >>"${ready_dir}/base64.txt"
cdn_subscription_local_nodes_ready "${ready_dir}" \
    && fail_test "旧 XHTTP path 的节点不得通过节点身份验收"
subscription_ready_local || fail_test "恢复后的六产物必须重新判为就绪"

# --- 9.2 模板快照属于订阅事务（F14） ----------------------------------------
template_v2="${TMP_DIR}/template-v2.yaml"
{
    command cat "${ROOT_DIR}/templates/mihomo.yaml"
    printf '\n# EASY_ALL_TEST_TEMPLATE_V2\n'
} >"${template_v2}"
mihomo_check="${TMP_DIR}/fake-mihomo-check"
printf '#!/usr/bin/env bash\nexit 0\n' >"${mihomo_check}"
chmod +x "${mihomo_check}"

baseline=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=dump-subscription-objects \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "订阅对象基线导出必须成功：${baseline}"
[[ "${baseline}" != *MISSING* ]] || fail_test "基线缺少订阅对象：${baseline}"

for sub_result in failure save-failure publish-failure; do
    if EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=update-sub-template \
        EASY_ALL_TEST_SUB_RESULT="${sub_result}" MIHOMO_TEMPLATE_SOURCE="${template_v2}" \
        MIHOMO_CHECK_BIN="${mihomo_check}" \
        EASY_ALL_TEST_TEMPLATE_MARKER="# EASY_ALL_TEST_TEMPLATE_V2" \
        bash "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        fail_test "订阅事务失败（${sub_result}）必须非零"
    fi
    after=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=dump-subscription-objects \
        bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "回滚后订阅对象导出必须成功"
    assert_equal "订阅事务失败（${sub_result}）后 state/Xray/Nginx/证书/六产物/模板快照必须全部回到旧版本" \
        "${baseline}" "${after}"
done

# 原本不存在模板快照：失败事务不得留下新快照
command rm -f -- "${STATE_DIR}/mihomo-template.yaml"
missing_status=0
EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=update-sub-template \
    EASY_ALL_TEST_SUB_RESULT=failure MIHOMO_TEMPLATE_SOURCE="${template_v2}" \
    MIHOMO_CHECK_BIN="${mihomo_check}" \
    EASY_ALL_TEST_TEMPLATE_MARKER="# EASY_ALL_TEST_TEMPLATE_V2" \
    bash "${BASH_SOURCE[0]}" >/dev/null 2>&1 || missing_status=$?
assert_equal "无既有模板快照时订阅事务失败必须非零" "1" "${missing_status}"
[[ ! -e "${STATE_DIR}/mihomo-template.yaml" ]] \
    || fail_test "失败事务不得留下新建的模板快照"

# 成功路径：新模板提交后由后续 apply 复用
success_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=update-sub-template \
    MIHOMO_TEMPLATE_SOURCE="${template_v2}" MIHOMO_CHECK_BIN="${mihomo_check}" \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "指定新模板的 edit-sub 必须成功：${success_out}"
assert_contains "模板快照已原子替换为新模板" \
    "$(<"${STATE_DIR}/mihomo-template.yaml")" "# EASY_ALL_TEST_TEMPLATE_V2"
assert_equal "模板快照权限 0600" "600" "$(mode_of "${STATE_DIR}/mihomo-template.yaml")"
apply_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=apply-reuses-template \
    EASY_ALL_TEST_TEMPLATE_MARKER="# EASY_ALL_TEST_TEMPLATE_V2" \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "apply 必须复用新模板快照：${apply_out}"
assert_contains "后续 apply 复用新模板" "${apply_out}" "APPLY|# EASY_ALL_TEST_TEMPLATE_V2"
# 成功路径的提交断言：新订阅事务必须真正落盘（state + Nginx 开放配置 + 模板快照）。
commit_token="commit-$(openssl rand -hex 6)"
commit_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=update-sub-template \
    SUBSCRIPTION_CONFIG="{\"allowedTokens\":{\"owner\":\"${commit_token}\"},\"nodes\":[]}" \
    MIHOMO_TEMPLATE_SOURCE="${template_v2}" MIHOMO_CHECK_BIN="${mihomo_check}" \
    EASY_ALL_TEST_TEMPLATE_MARKER="# EASY_ALL_TEST_TEMPLATE_V2" \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "新订阅事务必须提交成功：${commit_out}"
commit_check=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=assert-subscription-commit \
    EASY_ALL_TEST_SUB_TOKEN="${commit_token}" \
    EASY_ALL_TEST_TEMPLATE_MARKER="# EASY_ALL_TEST_TEMPLATE_V2" \
    bash "${BASH_SOURCE[0]}" 2>&1) || fail_test "提交后产物必须生效：${commit_check}"
assert_contains "订阅事务提交后生效" "${commit_check}" "COMMITTED"

# --- 9.3 订阅修复闭环与 deny 边界（F9/F10） ---------------------------------
reset_protection_usage() {
    cdn_traffic_write_usage "$(jq -c '.blocked=false | .enforced=false | .protection_offline=false |
        .used_bytes=0 | .last_uplink=0 | .last_downlink=0' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
}
reset_protection_usage
# 本节的修复闭环用 ASCII 节点名：macOS 的 bash 3.2 在 %q 下会改写非 ASCII 字节（Linux 不受影响），
# 与本批要验证的订阅修复逻辑无关。状态备份与恢复同样整文件复制。
install -m 0600 "${STATE_FILE}" "${TMP_DIR}/valid-state.env"
install -m 0600 "${STATE_FILE}" "${TMP_DIR}/ascii-state.env"
printf '%s\n' "CF_NODE_PREFIX='US-AWS'" >>"${TMP_DIR}/ascii-state.env"
install -m 0600 "${TMP_DIR}/ascii-state.env" "${STATE_FILE}"
ascii_publish_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" \
    EASY_ALL_TEST_SCENARIO=publish-subscriptions-from-state bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "按 ASCII 节点名的状态发布订阅必须成功：${ascii_publish_out}"

# F10：deny 边界由 Nginx deny 与停旧 Xray 两个独立动作组成，任一步失败都不能跳过另一步。
# systemctl 桩：is-active 返回 0 表示仍 active；stop 后写标记。
fake_systemctl_active_until_stop() {
    printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
    if [[ "${1:-}" == "stop" ]]; then
        : >"${TMP_DIR}/xray-stopped"
        return 0
    fi
    if [[ "${1:-}" == "is-active" ]]; then
        [[ ! -e "${TMP_DIR}/xray-stopped" ]]
        return
    fi
    return 0
}
fake_systemctl_always_active() {
    printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG}"
    return 0
}
: >"${FAKE_SYSTEMCTL_LOG}"
command rm -f -- "${TMP_DIR}/xray-stopped"
if (
    nginx() { return 1; }
    systemctl() { fake_systemctl_active_until_stop "$@"; }
    cdn_establish_denied_boundary
) >"${TMP_DIR}/boundary-nginx-failure.log" 2>&1; then
    fail_test "Nginx deny 失败时边界不得返回 0"
fi
assert_contains "Nginx deny 失败仍尝试停止旧 Xray" "$(<"${FAKE_SYSTEMCTL_LOG}")" \
    "stop easy_all-xray.service"
assert_contains "Nginx deny 失败告警旧连接可能仍存活" \
    "$(<"${TMP_DIR}/boundary-nginx-failure.log")" "旧 CDN 连接可能仍存活"

: >"${FAKE_SYSTEMCTL_LOG}"
if (
    systemctl() { fake_systemctl_always_active "$@"; }
    cdn_establish_denied_boundary
) >"${TMP_DIR}/boundary-stop-failure.log" 2>&1; then
    fail_test "停不掉旧 Xray 时边界必须非零"
fi
assert_contains "stop 失败后告警旧连接可能仍存活" \
    "$(<"${TMP_DIR}/boundary-stop-failure.log")" "旧 CDN 连接可能仍存活"

: >"${FAKE_SYSTEMCTL_LOG}"
command rm -f -- "${TMP_DIR}/xray-stopped"
(
    systemctl() { fake_systemctl_active_until_stop "$@"; }
    cdn_establish_denied_boundary
) || fail_test "Nginx deny 与停 Xray 都成功时边界必须返回 0"
assert_contains "边界成功仍保留 XHTTP 503" "$(<"${NGINX_CONFIG}")" "return 503;"

# F10：边界失败时 edit-sub 不得发布新订阅
before_boundary_objects=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" \
    EASY_ALL_TEST_SCENARIO=dump-subscription-products bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "边界测试前订阅对象导出必须成功"
: >"${FAKE_SYSTEMCTL_LOG}"
if EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=edit-sub-boundary-failure \
    SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"nwokn-fixme-1234"},"nodes":[]}' \
    bash "${BASH_SOURCE[0]}" >"${TMP_DIR}/boundary-failure.log" 2>&1; then
    fail_test "deny 边界失败时 edit-sub 必须非零"
fi
assert_contains "边界失败仍尝试停止旧 Xray" "$(<"${FAKE_SYSTEMCTL_LOG}")" \
    "stop easy_all-xray.service"
assert_contains "edit-sub 报边界失败且告警旧连接" "$(<"${TMP_DIR}/boundary-failure.log")" \
    "旧 CDN 连接可能仍存活"
after_boundary_objects=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" \
    EASY_ALL_TEST_SCENARIO=dump-subscription-products bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "边界测试后订阅对象导出必须成功"
assert_equal "deny 边界失败不得发布订阅或改 state" \
    "${before_boundary_objects}" "${after_boundary_objects}"

# F9：损坏订阅经 edit-sub 修复后必须清零损坏标记，新进程能继续就绪/同步。
# state 由 source 读取，追加一行非法 JSON 覆盖原配置即可，不必重写整个文件。
install -m 0600 "${TMP_DIR}/ascii-state.env" "${STATE_FILE}"
printf '%s\n' "SUBSCRIPTION_CONFIG='{ not-json'" >>"${STATE_FILE}"
corrupt_state_check=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=load-state-corrupt \
    bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "损坏订阅配置的状态仍应可加载：${corrupt_state_check}"
assert_contains "坏 JSON 配置在 load_state 中标记为损坏" "${corrupt_state_check}" \
    "CORRUPT|1"
: >"${FAKE_SYSTEMCTL_LOG}"
repair_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=edit-sub-repair \
    SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"nwokn-fixme-1234"},"nodes":[]}' \
    bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "损坏订阅经 edit-sub 修复必须成功：${repair_out}"
repair_systemctl=$(<"${FAKE_SYSTEMCTL_LOG}")
assert_not_contains "修复阶段不启动 Xray" "${repair_systemctl}" "start easy_all-xray"
assert_not_contains "修复阶段不重启 Xray" "${repair_systemctl}" "restart easy_all-xray"
assert_contains "修复后 /subscribe 恢复可用" "$(<"${NGINX_CONFIG}")" "internal;"
assert_contains "修复后 state 写入新订阅配置" "$(<"${STATE_FILE}")" "nwokn-fixme-1234"
assert_contains "修复后 Token map 使用新 Token" "$(<"${NGINX_CONFIG}")" \
    '"nwokn-fixme-1234" 1;'
assert_not_contains "修复后旧 Token 不再被接受" "$(<"${NGINX_CONFIG}")" \
    '"cdnwq-rtbke-3182" 1;'
assert_contains "修复后六产物重新发布" \
    "$(openssl base64 -d -A <"${SUBSCRIPTION_BASE64_FILE}")" "@${CF_NODE_DOMAIN}:443?"
ready_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" \
    EASY_ALL_TEST_SCENARIO=subscription-ready-new-process bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "修复后新进程必须判订阅就绪：${ready_out}"
assert_contains "新进程订阅就绪" "${ready_out}" "READY"
sync_repaired_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=sync-after-edit-sub \
    bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "修复后新进程 sync 必须成功：${sync_repaired_out}"
assert_not_contains "修复后 sync 不再报订阅未就绪" "${sync_repaired_out}" "订阅未就绪"

# 恢复本测试的状态、节点名与使用量基线
install -m 0600 "${TMP_DIR}/valid-state.env" "${STATE_FILE}"
restore_publish_out=$(EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" \
    EASY_ALL_TEST_SCENARIO=publish-subscriptions-from-state bash "${BASH_SOURCE[0]}" 2>&1) \
    || fail_test "恢复基线状态后重发订阅必须成功：${restore_publish_out}"
reset_protection_usage

# --- 10. apply 纯本机、不访问云 API ----------------------------------------
net_log="${TMP_DIR}/network.log"
: >"${net_log}"
(
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    install_xray_service() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    validate_subscription_runtime() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    register_easy_all_command() { :; }
    install_cdn_traffic_protection_timer() { :; }
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    aws() { printf 'aws %s\n' "$*" >>"${net_log}"; return 1; }
    aws_cli() { printf 'aws_cli %s\n' "$*" >>"${net_log}"; return 1; }
    cloudflare_api_request() { printf 'cf %s\n' "$*" >>"${net_log}"; return 1; }
    curl() { printf 'curl %s\n' "$*" >>"${net_log}"; return 1; }
    apply_easy_all
) || fail_test "apply 必须成功重建本机配置"
[[ ! -s "${net_log}" ]] || fail_test "apply 不得访问 AWS/Cloudflare/网络：$(<"${net_log}")"

# blocked 状态下 apply 仍必须渲染受限运行时，不能借普通 apply 解封。
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=true' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
(
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    install_xray_service() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    validate_subscription_runtime() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    register_easy_all_command() { :; }
    install_cdn_traffic_protection_timer() { :; }
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    apply_easy_all
) || fail_test "blocked 状态下 apply 必须成功重建"
assert_equal "blocked 状态下 apply 保持受限 XHTTP" "0" \
    "$(jq '.inbounds[1].settings.clients | length' "${XRAY_CONFIG}")"
assert_contains "blocked 状态下 apply 保持 Nginx 503" "$(<"${NGINX_CONFIG}")" "return 503;"
cdn_traffic_write_usage "$(jq -c '.blocked=false | .enforced=false | .protection_offline=false' \
    "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"

# --- 10b. 成功提交条件：计量预检、公网验收与保护定时器恢复 -------------------
install_body=$(awk '/^install_all\(\)/,/^}/' "${CORE}")
assert_contains "安装写 state 前执行公网验收" "${install_body}" "cdn_validate_public_runtime"
assert_contains "安装 Xray 启动后立即校验计量接口" "${install_body}" "cdn_verify_traffic_api"
assert_contains "安装成功前注册命令并恢复定时器" "${install_body}" "cdn_commit_local_runtime"
apply_cloud_fn_body=$(awk '/^apply_cloud_resources\(\)/,/^}/' "${CORE}")
assert_contains "apply-cloud 执行公网验收" "${apply_cloud_fn_body}" "cdn_validate_public_runtime"
assert_contains "apply-cloud 成功前恢复定时器" "${apply_cloud_fn_body}" "cdn_commit_local_runtime"
apply_body=$(awk '/^apply_easy_all\(\)/,/^}/' "${CORE}")
assert_contains "apply 成功前恢复定时器" "${apply_body}" "cdn_commit_local_runtime"
# 定时器安装本身必须断言 active：apply/安装成功前不能只“启用”不校验。
timer_body=$(awk '/^install_cdn_traffic_protection_timer\(\)/,/^}/' "${GUARD}")
assert_contains "定时器启用后断言 active" "${timer_body}" \
    'systemctl is-active --quiet "${CDN_TRAFFIC_GUARD_TIMER}"'
# 公网验收必须在 save_state 之前：失败时不得落盘“已同步”的状态。
assert_equal "apply-cloud 公网验收在 save_state 之前" "cdn_validate_public_runtime
save_state" \
    "$(printf '%s\n' "${apply_cloud_fn_body}" | grep -A1 'cdn_validate_public_runtime' \
        | sed -n '1,2p' | sed 's/^[[:space:]]*//')"

# 计量预检：真实零流量（两项计数为 0）必须通过，缺计数/非法值必须失败。
CDN_TRAFFIC_API_VERIFY_ATTEMPTS=1
cd_traffic_api_ok() {
    printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":0},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":0}]}' \
        >"${FAKE_STATS_FILE}"
    (cdn_verify_traffic_api) 2>/dev/null
}
cd_traffic_api_ok || fail_test "零流量的真实计数必须通过计量预检"
printf '%s' '{"stat":[]}' >"${FAKE_STATS_FILE}"
(cdn_verify_traffic_api) >/dev/null 2>&1 && fail_test "缺少 CDN 入站计数时安装必须失败"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":-1},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":1}]}' \
    >"${FAKE_STATS_FILE}"
(cdn_verify_traffic_api) >/dev/null 2>&1 && fail_test "负数计数不得通过计量预检"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":1.5},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":1}]}' \
    >"${FAKE_STATS_FILE}"
(cdn_verify_traffic_api) >/dev/null 2>&1 && fail_test "非整数计数不得通过计量预检"
cd_traffic_api_ok || fail_test "合法计数应可重复读取"
assert_contains "计量失败提示可执行的修复方向" \
    "$( ( printf '%s' '{"stat":[]}' >"${FAKE_STATS_FILE}"; cdn_verify_traffic_api ) 2>&1 || true)" \
    "未返回"

# apply 成功路径：恢复保护定时器（记录调用标记）
timer_and_apply_out=$(
    configure_tcp_acceleration() { :; }
    configure_ipv4_only() { :; }
    xhttp_configure_ufw() { :; }
    install_xray_service() { :; }
    validate_protocol_runtime() { :; }
    cdn_validate_direct_runtime() { :; }
    validate_subscription_runtime() { :; }
    cdn_traffic_protection_checkpoint() { return 0; }
    require_root() { :; }
    acquire_runtime_write_lock() { :; }
    register_easy_all_command() { printf 'REGISTER\n'; }
    install_cdn_traffic_protection_timer() { printf 'TIMER\n'; }
    apply_easy_all
) || fail_test "apply 正常路径必须成功：${timer_and_apply_out}"
assert_contains "apply 恢复命令注册" "${timer_and_apply_out}" "REGISTER"
assert_contains "apply 恢复保护定时器" "${timer_and_apply_out}" "TIMER"

# 定时器 enable/active 失败：apply 必须非零且不得报成功。
# 在独立进程里跑：命令替换与 && 列表都会关闭 errexit，否则会误判为成功。
if EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=apply-timer-failure \
    bash "${BASH_SOURCE[0]}" >"${TMP_DIR}/apply-timer-failure.log" 2>&1; then
    fail_test "定时器启用失败时 apply 必须非零"
fi
apply_timer_out=$(<"${TMP_DIR}/apply-timer-failure.log")
assert_not_contains "定时器失败不报 apply 成功" "${apply_timer_out}" "已应用"

# edit-sub 保持阻断：回滚不得启动旧 Xray
update_body=$(awk '/^update_subscription\(\)/,/^}/' "${CORE}")
assert_contains "受限 edit-sub 关闭回滚重启" "${update_body}" "UPDATE_SUB_ROLLBACK_NO_RESTART=1"
assert_contains "共享回滚遵守不重启标记" \
    "$(awk '/^rollback_subscription_update\(\)/,/^}/' "${ROOT_DIR}/lib/xhttp-runtime.sh")" \
    "UPDATE_SUB_ROLLBACK_NO_RESTART"

# --- 11. 熔断状态机 ---------------------------------------------------------
usage_file="${CDN_TRAFFIC_GUARD_USAGE_FILE}"
reset_usage() {
    command rm -f -- "${usage_file}"
    initialize_cdn_traffic_usage
}
reset_usage
assert_equal "initial usage 有 8 个字段" "8" "$(jq 'keys | length' "${usage_file}")"
assert_equal "initial protection_offline=false" "false" \
    "$(jq -r '.protection_offline' "${usage_file}")"
assert_equal "usage 权限 0600" "600" "$(mode_of "${usage_file}")"

# 合法旧七字段：读取视为 offline=false，且不顺手改写文件
legacy_usage=$(jq -c 'del(.protection_offline)' "${usage_file}")
printf '%s\n' "${legacy_usage}" >"${usage_file}"
before_bytes=$(<"${usage_file}")
assert_equal "旧七字段读取为 protection_offline=false" "false" \
    "$(cdn_traffic_read_usage | jq -r '.protection_offline')"
assert_equal "读取不修改旧七字段文件" "${before_bytes}" "$(<"${usage_file}")"

# 违反 offline 不变量或字段白名单 → 损坏
printf '%s\n' "$(jq -c '.protection_offline=true' <<<"${legacy_usage}")" >"${usage_file}"
(cdn_traffic_read_usage >/dev/null) && fail_test "offline=true 但 blocked/enforced 不满足必须判为损坏"
printf '%s\n' "$(jq -c '.extra=1' <<<"${legacy_usage}")" >"${usage_file}"
(cdn_traffic_read_usage >/dev/null) && fail_test "白名单外字段必须判为损坏"
reset_usage

# 统一准入只认 blocked=true && enforced=false
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=true' "${usage_file}")"
(cdn_traffic_needs_restricted_recovery) && fail_test "已落实阻断不是受限恢复准入"
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${usage_file}")"
cdn_traffic_needs_restricted_recovery || fail_test "待落实阻断必须进入受限恢复准入"
cdn_traffic_mark_restricted_recovered
assert_equal "受限恢复只改 enforced/offline" "true,false" \
    "$(jq -r '[.enforced, .protection_offline] | @csv' "${usage_file}")"
assert_equal "受限恢复保留 blocked" "true" "$(jq -r '.blocked' "${usage_file}")"
cdn_traffic_mark_enforced
assert_equal "mark_enforced 对齐 desired" "true" "$(jq -r '.enforced' "${usage_file}")"
cdn_traffic_mark_protection_offline
assert_equal "offline 标记同时设置 trio" "true,true,false" \
    "$(jq -r '[.blocked, .protection_offline, .enforced] | @csv' "${usage_file}")"

# 统计只取 vless-xhttp-in 两个计数
stats_json='{"stat":[
 {"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":10},
 {"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":5},
 {"name":"inbound>>>vless-reality-in>>>traffic>>>uplink","value":999},
 {"name":"user>>>owner>>>traffic>>>uplink","value":777}]}'
assert_equal "只统计 CDN 入站上下行" "$(printf '10\t5')" \
    "$(cdn_traffic_stats_totals "${stats_json}")"
if cdn_traffic_stats_totals '{"stat":[{"name":"user>>>x>>>traffic>>>uplink","value":1}]}' \
    >/dev/null 2>&1; then
    fail_test "缺少 CDN 入站计数必须失败"
fi
if cdn_traffic_stats_totals '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":"10"}]}' \
    >/dev/null 2>&1; then
    fail_test "非整数计数必须失败"
fi

# 采样：同 InvocationID 累加 delta；换 InvocationID 累计新计数；跨月不丢失成功读数
printf 'run-1' >"${FAKE_INVOCATION_FILE}"
printf '%s' "${stats_json}" >"${FAKE_STATS_FILE}"
reset_usage
cdn_traffic_update_usage || fail_test "首次采样必须成功"
assert_equal "首次采样累计 15" "15" "$(jq -r '.used_bytes' "${usage_file}")"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":20},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":10}]}' >"${FAKE_STATS_FILE}"
cdn_traffic_update_usage || fail_test "第二次采样必须成功"
assert_equal "同进程按增量累计" "30" "$(jq -r '.used_bytes' "${usage_file}")"
printf 'run-2' >"${FAKE_INVOCATION_FILE}"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":5},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":5}]}' >"${FAKE_STATS_FILE}"
cdn_traffic_update_usage || fail_test "重启后采样必须成功"
assert_equal "重启后累计新进程计数且保留旧用量" "40" "$(jq -r '.used_bytes' "${usage_file}")"

# 达到阈值 → blocked；offline 保持 false
printf 'run-2' >"${FAKE_INVOCATION_FILE}"
cdn_traffic_write_usage "$(jq -c '.used_bytes=984999999990 | .last_uplink=0 | .last_downlink=0' "${usage_file}")"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":10},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":0}]}' >"${FAKE_STATS_FILE}"
cdn_traffic_update_usage || fail_test "阈值采样必须成功"
assert_equal "等于阈值即阻断" "true" "$(jq -r '.blocked' "${usage_file}")"
assert_equal "采样不设置 offline" "false" "$(jq -r '.protection_offline' "${usage_file}")"

# 跨月：只有 API 可读才推进 period，并把整个采样增量计入新月份
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":30},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":10}]}' >"${FAKE_STATS_FILE}"
cdn_traffic_write_usage "$(jq -c '.period="2000-01" | .used_bytes=123 | .last_uplink=0 | .last_downlink=0' "${usage_file}")"
cdn_traffic_update_usage || fail_test "跨月采样必须成功"
assert_equal "跨月写入新 period" "$(date -u +%Y-%m)" "$(jq -r '.period' "${usage_file}")"
assert_equal "跨月只计本次增量" "40" "$(jq -r '.used_bytes' "${usage_file}")"

# API 不可读时保留原文件，不推断额度恢复
printf '%s' '{"bad":true}' >"${FAKE_STATS_FILE}"
before_bytes=$(<"${usage_file}")
(cdn_traffic_update_usage) >/dev/null 2>&1 && fail_test "统计损坏必须失败"
assert_equal "统计失败不改写 usage" "${before_bytes}" "$(<"${usage_file}")"

# 订阅未就绪时禁止解封（KEEP_BLOCKED）
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=true | .used_bytes=0 | .last_uplink=0 | .last_downlink=0' "${usage_file}")"
printf 'run-3' >"${FAKE_INVOCATION_FILE}"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":1},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":1}]}' >"${FAKE_STATS_FILE}"
CDN_TRAFFIC_KEEP_BLOCKED=1 cdn_traffic_update_usage || fail_test "keep-blocked 采样必须成功"
assert_equal "订阅未就绪保持 blocked" "true" "$(jq -r '.blocked' "${usage_file}")"

# timer 顺序：先受限恢复，再采样；订阅降级只告警并保持阻断
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

: >"${sync_log}"
(
    require_root() { :; }
    collect_installed_state() { :; }
    try_acquire_runtime_write_lock() { return 0; }
    release_runtime_write_lock() { :; }
    cdn_traffic_subscription_ready() { return 1; }
    cdn_traffic_update_usage() {
        printf 'keep=%s\n' "${CDN_TRAFFIC_KEEP_BLOCKED:-unset}" >>"${sync_log}"
        CDN_TRAFFIC_OLD_BLOCKED=true
        CDN_TRAFFIC_BLOCKED=true
        CDN_TRAFFIC_NEEDS_APPLY=0
        return 0
    }
    cdn_traffic_protection_sync
) && fail_test "订阅未就绪时 sync 必须非零"
assert_equal "订阅未就绪传递 keep-blocked" "keep=1" "$(<"${sync_log}")"

# 锁忙：跳过本轮并返回 0
(
    require_root() { :; }
    try_acquire_runtime_write_lock() { return 1; }
    cdn_traffic_protection_sync
) || fail_test "锁忙必须返回 0 表示跳过"
sync_skip_out=$(
    require_root() { :; }
    try_acquire_runtime_write_lock() { return 1; }
    cdn_traffic_protection_sync 2>&1
)
assert_contains "锁忙明确说明跳过" "${sync_skip_out}" "跳过"

# 受限恢复：先 Nginx deny，再启动 Xray，验收后翻 enforced/offline
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${usage_file}")"
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
assert_equal "受限恢复顺序" "$(printf 'nginx-deny\nrender-restricted\nvalidate')" \
    "$(<"${recover_log}")"
assert_equal "受限恢复后 enforced=true/offline=false" "true,false" \
    "$(jq -r '[.enforced, .protection_offline] | @csv' "${usage_file}")"
assert_contains "受限恢复先停/重启 Xray" "$(<"${FAKE_SYSTEMCTL_LOG}")" "restart easy_all-xray.service"

# 受限恢复必需验收失败：持久 offline 并停止 Xray
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${usage_file}")"
: >"${FAKE_SYSTEMCTL_LOG}"
(
    write_nginx_config() { return 0; }
    render_xray_config() { return 0; }
    cdn_validate_restricted_runtime() { return 1; }
    cdn_traffic_recover_restricted_runtime
) && fail_test "受限恢复验收失败必须非零"
assert_equal "失败后 offline 持久化" "true,false" \
    "$(jq -r '[.protection_offline, .enforced] | @csv' "${usage_file}")"
assert_contains "失败后先标记再停 Xray" "$(<"${FAKE_SYSTEMCTL_LOG}")" "stop easy_all-xray.service"

# 阻断重建失败：保留 Nginx 503，不恢复开放配置
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false' "${usage_file}")"
: >"${FAKE_SYSTEMCTL_LOG}"
FAKE_XRAY_RESTART_FAIL=1
export FAKE_XRAY_RESTART_FAIL
if ( rebuild_traffic_runtime ) >/dev/null 2>&1; then
    fail_test "阻断重建失败必须返回非零"
fi
FAKE_XRAY_RESTART_FAIL=0
export FAKE_XRAY_RESTART_FAIL
assert_equal "阻断重建失败持久 offline" "true,false" \
    "$(jq -r '[.protection_offline, .enforced] | @csv' "${usage_file}")"
assert_equal "阻断重建失败保留 blocked" "true" "$(jq -r '.blocked' "${usage_file}")"
assert_contains "阻断重建失败仍保留 Nginx 503" "$(<"${NGINX_CONFIG}")" "return 503;"
assert_contains "阻断重建失败停止旧 CDN 会话" "$(<"${FAKE_SYSTEMCTL_LOG}")" \
    "stop easy_all-xray.service"

# 解封路径：blocked=false 时重建成功后由调用方标记 enforced
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=false | .enforced=true' "${usage_file}")"
(
    cdn_validate_restricted_runtime() { return 1; }
    validate_protocol_runtime() { return 0; }
    cdn_validate_direct_runtime() { return 0; }
    rebuild_traffic_runtime
) || fail_test "解封重建必须成功"
assert_not_contains "解封重建渲染开放 XHTTP" "$(<"${NGINX_CONFIG}")" "return 503;"

# 解封 pending（blocked=false/enforced=true）在订阅未就绪时不得开放 CDN（F11/F12）
reset_usage
cdn_traffic_write_usage "$(jq -c '.blocked=false | .enforced=true | .used_bytes=0 | .last_uplink=0 | .last_downlink=0' "${usage_file}")"
# 现场还原：解封 pending 之前运行时已经是受限状态（受限 Xray + XHTTP 503）
render_xray_config 1
cdn_write_nginx_config 1 0
printf 'run-pending' >"${FAKE_INVOCATION_FILE}"
printf '%s' '{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":5},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":5}]}' \
    >"${FAKE_STATS_FILE}"
pending_log="${TMP_DIR}/pending-unblock.log"
if (
    require_root() { :; }
    collect_installed_state() { :; }
    try_acquire_runtime_write_lock() { return 0; }
    release_runtime_write_lock() { :; }
    cdn_traffic_subscription_ready() { return 1; }
    validate_protocol_runtime() { :; }
    cdn_validate_restricted_runtime() { return 0; }
    cdn_validate_direct_runtime() { :; }
    cdn_traffic_protection_sync
) >"${pending_log}" 2>&1; then
    fail_test "订阅未就绪时解封 pending 必须非零"
fi
assert_equal "订阅未就绪不得写 enforced=false" "true,true" \
    "$(jq -r '[.blocked, .enforced] | @csv' "${usage_file}")"
assert_equal "订阅未就绪保持受限 Xray（无 CDN 客户端）" "0" \
    "$(jq '.inbounds[1].settings.clients | length' "${XRAY_CONFIG}")"
assert_contains "订阅未就绪保留 XHTTP 503" "$(<"${NGINX_CONFIG}")" "return 503;"
assert_contains "订阅未就绪时 /subscribe 降级 503" "$(<"${NGINX_CONFIG}")" "location = /subscribe {"
assert_not_contains "订阅未就绪不发布 internal 订阅别名" "$(<"${NGINX_CONFIG}")" "internal;"
assert_contains "订阅未就绪明确禁止解封" "$(<"${pending_log}")" "订阅未就绪"

# 订阅恢复就绪后，下一轮才允许解封
printf 'run-pending-2' >"${FAKE_INVOCATION_FILE}"
(
    require_root() { :; }
    collect_installed_state() { :; }
    try_acquire_runtime_write_lock() { return 0; }
    release_runtime_write_lock() { :; }
    cdn_traffic_subscription_ready() { return 0; }
    validate_protocol_runtime() { :; }
    cdn_validate_restricted_runtime() { return 0; }
    cdn_validate_direct_runtime() { :; }
    cdn_traffic_protection_sync
) >"${TMP_DIR}/pending-unblock-recovered.log" 2>&1 \
    || fail_test "订阅就绪后应在下一轮收敛解封"
assert_equal "订阅就绪后写回 blocked=false/enforced=false" "false,false" \
    "$(jq -r '[.blocked, .enforced] | @csv' "${usage_file}")"
assert_equal "解封后 Xray 恢复 CDN 客户端" "1" \
    "$(jq '.inbounds[1].settings.clients | length' "${XRAY_CONFIG}")"
assert_not_contains "解封后 Nginx 不再返回 503" "$(<"${NGINX_CONFIG}")" "return 503;"

# --- 11b. 临重启最后采样：长阶段增长必须计入，拒绝时不得恢复重启 ----------
meter_run() {
    EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO="$1" \
        bash "${BASH_SOURCE[0]}"
}
meter_restart_count() {
    grep -c -F 'restart easy_all-xray.service' "${FAKE_SYSTEMCTL_LOG}" 2>/dev/null || true
}
meter_new_process_used() {
    EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=meter-sample \
        bash "${BASH_SOURCE[0]}"
}

install -m 0600 "${TMP_DIR}/valid-state.env" "${STATE_FILE}"
reset_protection_usage
: >"${FAKE_SYSTEMCTL_LOG}"

# apply 正常路径：调优阶段旧进程持续计数，restart 前最后采样必须计入。
apply_meter_out=$(meter_run apply-long-stage-metering 2>&1) \
    || fail_test "apply 长阶段计量用例必须成功：${apply_meter_out}"
assert_contains "apply 最后采样计入长阶段流量" "${apply_meter_out}" \
    "APPLY|150|false	false|1"
printf 'run-2' >"${FAKE_INVOCATION_FILE}"
meter_set_stats 7 3
apply_used_out=$(meter_new_process_used 2>&1) \
    || fail_test "新进程累计采样必须成功：${apply_used_out}"
assert_contains "apply 后新进程累计包含旧进程最后计数且不重复" "${apply_used_out}" \
    "USED|160"

# apply 跨阈值：最后采样拒绝时必须非零、不重启、pending 保留。
install -m 0600 "${TMP_DIR}/valid-state.env" "${STATE_FILE}"
: >"${FAKE_SYSTEMCTL_LOG}"
apply_refusal_rc=0
apply_refusal_out=$(meter_run apply-long-stage-refusal 2>&1) || apply_refusal_rc=$?
((apply_refusal_rc != 0)) \
    || fail_test "apply 最后采样跨阈值时必须非零"
assert_not_contains "apply 拒绝时不得报成功" "${apply_refusal_out}" "已应用"
assert_equal "apply 拒绝时不执行该次 restart" "0" "$(meter_restart_count)"
assert_equal "apply 拒绝保留 pending" "true	false" \
    "$(jq -r '[.blocked, .enforced] | @tsv' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
[[ "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")" -ge 985000000000 ]] \
    || fail_test "apply 拒绝时用量必须保留（计入长阶段流量）"
assert_contains "apply 拒绝时明确提示手动同步" "${apply_refusal_out}" "cdn-traffic-sync"
assert_contains "apply 拒绝时回滚不重启 Xray（不声称已停机）" "${apply_refusal_out}" \
    "本次回滚不重启 Xray（旧进程可能仍在运行）"

# apply-cloud 正常路径：云阶段旧进程持续计数，restart 前最后采样必须计入。
install -m 0600 "${TMP_DIR}/valid-state.env" "${STATE_FILE}"
reset_protection_usage
: >"${FAKE_SYSTEMCTL_LOG}"
cloud_meter_out=$(meter_run apply-cloud-long-stage-metering 2>&1) \
    || fail_test "apply-cloud 长阶段计量用例必须成功：${cloud_meter_out}"
assert_contains "apply-cloud 最后采样计入云阶段流量" "${cloud_meter_out}" \
    "APPLY-CLOUD|150|false	false|1"
printf 'run-2' >"${FAKE_INVOCATION_FILE}"
meter_set_stats 5 5
cloud_used_out=$(meter_new_process_used 2>&1) \
    || fail_test "新进程累计采样必须成功：${cloud_used_out}"
assert_contains "apply-cloud 后新进程累计包含云阶段计数" "${cloud_used_out}" "USED|160"

# 云阶段失败（未到正常临重启 checkpoint）进入 EXIT 回滚：回滚 restart 前必须采样。
install -m 0600 "${TMP_DIR}/valid-state.env" "${STATE_FILE}"
reset_protection_usage
: >"${FAKE_SYSTEMCTL_LOG}"
cloud_fail_rc=0
cloud_fail_out=$(meter_run apply-cloud-cloud-failure 2>&1) || cloud_fail_rc=$?
((cloud_fail_rc != 0)) || fail_test "云阶段失败必须非零"
assert_not_contains "云阶段失败不得报成功" "${cloud_fail_out}" "已同步"
assert_equal "云阶段失败回滚前已记入增量" "150" \
    "$(jq -r '.used_bytes' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_equal "云阶段失败的回滚 restart 前已通过采样" "1" "$(meter_restart_count)"
printf 'run-2' >"${FAKE_INVOCATION_FILE}"
meter_set_stats 5 5
cloud_fail_used=$(meter_new_process_used 2>&1) \
    || fail_test "新进程累计采样必须成功：${cloud_fail_used}"
assert_contains "云阶段失败后累计包含阶段增量且不重复" "${cloud_fail_used}" "USED|160"

# 云阶段失败且跨阈值：回滚也不得重启旧开放运行时。
install -m 0600 "${TMP_DIR}/valid-state.env" "${STATE_FILE}"
: >"${FAKE_SYSTEMCTL_LOG}"
cloud_over_rc=0
cloud_over_out=$(meter_run apply-cloud-cloud-failure-over-threshold 2>&1) || cloud_over_rc=$?
((cloud_over_rc != 0)) || fail_test "云阶段失败跨阈值必须非零"
assert_not_contains "云阶段跨阈值不得报成功" "${cloud_over_out}" "已同步"
assert_equal "云阶段跨阈值回滚不执行 restart" "0" "$(meter_restart_count)"
assert_equal "云阶段跨阈值保留 pending" "true	false" \
    "$(jq -r '[.blocked, .enforced] | @tsv' "${CDN_TRAFFIC_GUARD_USAGE_FILE}")"
assert_contains "云阶段跨阈值明确提示手动同步" "${cloud_over_out}" "cdn-traffic-sync"

# 恢复重启 gate：公共 runtime 未定义 checkpoint 时仍按原逻辑重启（不得缺函数失败）。
command rm -rf -- "${TMP_DIR}/rollback-undefined"
install -d -m 0700 "${TMP_DIR}/rollback-undefined"
install -m 0600 "${STATE_FILE}" "${TMP_DIR}/rollback-undefined/state.env"
install -m 0600 "${XRAY_CONFIG}" "${TMP_DIR}/rollback-undefined/xray-config.json"
install -m 0600 "${NGINX_CONFIG}" "${TMP_DIR}/rollback-undefined/nginx.conf"
[[ ! -f "${CERT_FILE}" ]] || install -m 0644 "${CERT_FILE}" "${TMP_DIR}/rollback-undefined/certificate.pem"
[[ ! -f "${KEY_FILE}" ]] || install -m 0600 "${KEY_FILE}" "${TMP_DIR}/rollback-undefined/private.key"
cp -a "${SUBSCRIPTION_DIR}" "${TMP_DIR}/rollback-undefined/subscriptions"
: >"${TMP_DIR}/rollback-restart.log"
(
    UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/rollback-undefined"
    publish_subscription_files() { :; }
    systemctl() { printf '%s\n' "$*" >>"${TMP_DIR}/rollback-restart.log"; }
    nginx() { :; }
    unset -f cdn_traffic_protection_checkpoint
    rollback_subscription_update
) || fail_test "缺 checkpoint 时回滚必须成功"
assert_contains "缺 checkpoint 时仍重启到旧配置" "$(<"${TMP_DIR}/rollback-restart.log")" \
    "restart easy_all-xray.service"

# Reality 下 guard 可见但 protection_enabled 为假：不得新增 CDN 门禁。
: >"${TMP_DIR}/rollback-restart.log"
(
    PROTOCOL=reality
    CDN_PROVIDER=aws
    UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/rollback-undefined"
    publish_subscription_files() { :; }
    systemctl() { printf '%s\n' "$*" >>"${TMP_DIR}/rollback-restart.log"; }
    nginx() { :; }
    rollback_subscription_update
) || fail_test "Reality 下回滚必须成功"
assert_contains "Reality 下回滚仍重启旧服务" "$(<"${TMP_DIR}/rollback-restart.log")" \
    "restart easy_all-xray.service"

# --- 12. 定时重启的只读复核钩子 --------------------------------------------
locked_check=$(scheduled_reboot_profile_locked_check_command)
assert_contains "locked check 引用固定 usage 路径" "${locked_check}" "${usage_file}"
assert_contains "locked check 不另起 CLI" "${locked_check}" "jq -e"
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=false | .protection_offline=false' "${usage_file}")"
eval "${locked_check}" && fail_test "pending（blocked!=enforced）必须让复核失败"
cdn_traffic_write_usage "$(jq -c '.blocked=true | .enforced=true | .protection_offline=false' "${usage_file}")"
eval "${locked_check}" || fail_test "完整收敛的 usage 必须让复核通过"
assert_contains "pre-command 调用 cdn-traffic-sync" "$(scheduled_reboot_profile_pre_command)" \
    "cdn-traffic-sync"

# --- 13. 归属校验、无状态发现与云清理次序 -----------------------------------
# AWS stub 一律按真实响应结构返回：ListDistributions 的项是 DistributionSummary
# （Id/DomainName/Comment/Aliases.Items，没有 DistributionConfig），ACM 列表用 NextToken 分页。
AWS_STUB_DIR="${TMP_DIR}/aws-stub"
AWS_CALL_LOG="${TMP_DIR}/aws-calls.log"
AWS_STUB_ACCOUNT=123456789012
CF_FIXTURE="${TMP_DIR}/cloudflare-fixture.json"

aws_reset() {
    command rm -rf -- "${AWS_STUB_DIR}"
    mkdir -p "${AWS_STUB_DIR}/dist-pages" "${AWS_STUB_DIR}/acm-pages"
    : >"${AWS_CALL_LOG}"
    printf '{"certs":{},"tags":{}}' >"${AWS_STUB_DIR}/acm.json"
}
aws_calls() { command cat "${AWS_CALL_LOG}" 2>/dev/null || true; }
aws_write_calls() {
    grep -E '^(cloudfront (create|update|delete)-distribution|acm (request|delete)-certificate)' \
        "${AWS_CALL_LOG}" 2>/dev/null || true
}
aws_count() { grep -c -F -- "$1" "${AWS_CALL_LOG}" 2>/dev/null || true; }
aws_opt() {
    local want=$1
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "${want}" ]]; then
            printf '%s' "${2:-}"
            return 0
        fi
        shift
    done
    return 1
}
aws_stub_page() { # $1=分页目录 $2=缺省空页
    local dir=$1 empty=$2 index=0
    [[ ! -f "${dir}.index" ]] || index=$(<"${dir}.index")
    printf '%s\n' "$((index + 1))" >"${dir}.index"
    if [[ -f "${dir}/${index}.json" ]]; then
        command cat "${dir}/${index}.json"
    else
        printf '%s\n' "${empty}"
    fi
}

# 真实 AWS CLI 的错误形状：`An error occurred (<Code>) when calling the <Operation>
# operation: <message>` 写 stderr 且退出 254。测试可以同时断言退出码与错误码。
aws_stub_error() { # $1=错误码 $2=消息
    printf 'An error occurred (%s) when calling the operation: %s\n' "$1" "$2" >&2
    return 254
}

# 请求参数合法性校验：真实 API 会拒绝的输入，stub 必须同样拒绝，否则测试会放过
# 构造非法请求的回归（例如幂等 Token 含点/连字符、分发配置缺关键字段）。
aws_stub_assert_acm_request() {
    local token domain san tags
    token=$(aws_opt --idempotency-token "$@" || true)
    domain=$(aws_opt --domain-name "$@" || true)
    san=$(aws_opt --subject-alternative-names "$@" || true)
    tags=$*
    [[ -n "${domain}" && "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] \
        || { aws_stub_error ValidationException "DomainName 缺失或非法"; return 254; }
    [[ "${token}" =~ ^[A-Za-z0-9_]{1,32}$ ]] \
        || { aws_stub_error ValidationException \
            "1 validation error detected: Value at 'idempotencyToken' failed to satisfy constraint: Member must satisfy regular expression pattern: \\w+ (and be at most 32 characters): ${token}"; return 254; }
    [[ " ${tags} " == *" --validation-method DNS "* ]] \
        || { aws_stub_error ValidationException "ValidationMethod 必须是 DNS"; return 254; }
    [[ "${tags}" == *"Key=easy_all,Value=managed"* && "${tags}" == *"Key=easy_all-node,Value=${domain}"* ]] \
        || { aws_stub_error ValidationException "缺少 easy_all 归属标签"; return 254; }
    [[ -z "${san}" || ( "${san}" =~ ^[A-Za-z0-9.-]+$ && "${san}" != "${domain}" ) ]] \
        || { aws_stub_error ValidationException "SubjectAlternativeNames 非法：${san}"; return 254; }
    [[ " $* " == *" --query CertificateArn --output text "* ]] \
        || { aws_stub_error ParamValidationError "必须用 --query CertificateArn --output text 解析 ARN"; return 254; }
}

aws_stub_assert_distribution_config() { # $1=operation，其后为 CLI 参数
    local operation=$1
    shift
    local id config etag
    id=$(aws_opt --id "$@" || true)
    config=$(aws_opt --distribution-config "$@" || true)
    etag=$(aws_opt --if-match "$@" || true)
    [[ -n "${id}" ]] \
        || { aws_stub_error ValidationException "${operation} 缺少 --id"; return 254; }
    if [[ "${operation}" == "UpdateDistribution" || "${operation}" == "DeleteDistribution" ]]; then
        [[ "${etag}" =~ ^[A-Za-z0-9-]+$ ]] \
            || { aws_stub_error InvalidIfMatchVersion "缺少或非法的 --if-match（ETag）：${etag}"; return 254; }
    fi
    if [[ "${operation}" == "DeleteDistribution" ]]; then
        return 0
    fi
    local config_json=""
    if [[ "${config}" == file://* ]]; then
        [[ -f "${config#file://}" ]] \
            || { aws_stub_error InvalidArgumentException "分发配置文件不存在：${config#file://}"; return 254; }
        config_json=$(<"${config#file://}")
    elif [[ "${config}" == "{"* ]]; then
        # 清理路径用内联 JSON（真实 CLI 同样接受 --distribution-config '<json>'）。
        config_json=${config}
    else
        aws_stub_error InvalidArgumentException "缺少 --distribution-config"; return 254
    fi
    jq -e '
        (.Comment // "") | test("^easy_all-cloudfront-[A-Za-z0-9.-]+$")
    ' <<<"${config_json}" >/dev/null \
        || { aws_stub_error InvalidArgumentException "Comment 必须是精确 marker"; return 254; }
    jq -e '
        ((.Enabled | type) == "boolean") and
        (.HttpVersion == "http2") and
        ((.Aliases.Quantity // 0) >= 1) and
        ((.Aliases.Quantity // -1) == ((.Aliases.Items // []) | length)) and
        ((.Origins.Quantity // 0) == 1) and
        (((.Origins.Items // []) | length) == 1) and
        ((.Origins.Items[0].DomainName // "") | length > 0) and
        (((.Origins.Items[0].CustomHeaders.Items // []) | length) == 1) and
        (.Origins.Items[0].CustomHeaders.Items[0].HeaderName == "X-Easy-All-Origin-Key") and
        ((.Origins.Items[0].CustomHeaders.Items[0].HeaderValue // "") | length > 0) and
        (.ViewerCertificate.SSLSupportMethod == "sni-only") and
        ((.ViewerCertificate.ACMCertificateArn // "") | test("^arn:aws:acm:us-east-1:")) and
        (.DefaultCacheBehavior.CachePolicyId == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad") and
        (.DefaultCacheBehavior.OriginRequestPolicyId == "b689b0a8-53d0-40ab-baf2-68738e2966ac") and
        (.DefaultCacheBehavior.GrpcConfig.Enabled == true) and
        (.DefaultCacheBehavior.AllowedMethods.Quantity == 7) and
        ((.CallerReference // "") | length > 0)
    ' <<<"${config_json}" >/dev/null \
        || { aws_stub_error InvalidArgumentException "分发配置缺少关键字段"; return 254; }
}

aws() {
    # 跳过 CLOUDFRONT_AWS_CLI_ARGS 里的全局参数（布尔与带值参数混排）。
    while [[ $# -gt 0 ]]; do
        case "$1" in
        --no-cli-pager) shift ;;
        --cli-read-timeout | --cli-connect-timeout) shift 2 ;;
        *) break ;;
        esac
    done
    local service=${1:-} operation=${2:-} arn description
    shift 2 || true
    printf '%s %s %s\n' "${service}" "${operation}" "$*" >>"${AWS_CALL_LOG}"
    if [[ -f "${AWS_STUB_DIR}/fail-${service}-${operation}" ]]; then
        aws_stub_error AccessDenied "$(<"${AWS_STUB_DIR}/fail-${service}-${operation}")"
        return 254
    fi
    case "${service}-${operation}" in
    sts-get-caller-identity)
        printf '%s\n' "${AWS_STUB_ACCOUNT}"
        ;;
    cloudfront-list-distributions)
        aws_stub_page "${AWS_STUB_DIR}/dist-pages" \
            '{"DistributionList":{"IsTruncated":false,"MaxItems":100,"Quantity":0,"Items":[]}}'
        ;;
    cloudfront-get-distribution-config)
        [[ -n "$(aws_opt --id "$@" || true)" ]] \
            || { aws_stub_error ValidationException "GetDistributionConfig 缺少 --id"; return 254; }
        command cat "${AWS_STUB_DIR}/dist-config.json"
        ;;
    cloudfront-get-distribution)
        [[ -n "$(aws_opt --id "$@" || true)" ]] \
            || { aws_stub_error ValidationException "GetDistribution 缺少 --id"; return 254; }
        printf 'Deployed\n'
        ;;
    cloudfront-update-distribution)
        aws_stub_assert_distribution_config UpdateDistribution "$@" || return 254
        printf '{"Distribution":{"Id":"%s","DomainName":"d111.cloudfront.net","Status":"InProgress"}}\n' \
            "$(aws_opt --id "$@" || true)"
        ;;
    cloudfront-create-distribution)
        aws_stub_assert_distribution_config CreateDistribution "" --id EDFNEW "$@" || return 254
        printf '{"Distribution":{"Id":"EDFNEW","DomainName":"dnew.cloudfront.net","Status":"InProgress"}}\n'
        ;;
    cloudfront-delete-distribution)
        aws_stub_assert_distribution_config DeleteDistribution "$@" || return 254
        printf '{"Id":"deleted"}\n'
        ;;
    acm-list-certificates)
        aws_stub_page "${AWS_STUB_DIR}/acm-pages" '{"CertificateSummaryList":[]}'
        ;;
    acm-list-tags-for-certificate)
        arn=$(aws_opt --certificate-arn "$@" || true)
        jq -c --arg arn "${arn}" '.tags[$arn] // {"Tags":[]}' "${AWS_STUB_DIR}/acm.json"
        ;;
    acm-describe-certificate)
        arn=$(aws_opt --certificate-arn "$@" || true)
        description=$(jq -c --arg arn "${arn}" '.certs[$arn] // empty' "${AWS_STUB_DIR}/acm.json")
        if [[ -z "${description}" ]]; then
            printf 'stub: 未配置的 ACM 证书：%s\n' "${arn}" >&2
            return 254
        fi
        if [[ " $* " == *" --query "* ]]; then
            jq -r '.Certificate.Status' <<<"${description}"
        else
            printf '%s\n' "${description}"
        fi
        ;;
    acm-request-certificate)
        aws_stub_assert_acm_request "$@" || return 254
        # 调用方用 --query CertificateArn --output text，真实 CLI 只打印 ARN。
        printf 'arn:aws:acm:us-east-1:%s:certificate/new\n' "${AWS_STUB_ACCOUNT}"
        ;;
    acm-delete-certificate)
        printf '{"CertificateArn":"deleted"}\n'
        ;;
    *)
        printf 'stub: 未实现的 AWS 调用：%s %s\n' "${service}" "${operation}" >&2
        return 254
        ;;
    esac
}

# 真实 ListDistributions 的项：DistributionSummary，没有 DistributionConfig。
dist_summary() { # $1=id $2=domain $3=comment，其后为 aliases
    local id=$1 domain=$2 comment=$3
    shift 3
    jq -cn --arg id "${id}" --arg domain "${domain}" --arg comment "${comment}" --args '{
        Id:$id,
        ARN:("arn:aws:cloudfront::" + "123456789012" + ":distribution/" + $id),
        Status:"Deployed",
        DomainName:$domain,
        Comment:$comment,
        Aliases:{Quantity:($ARGS.positional|length), Items:$ARGS.positional}
    }' "$@"
}
dist_list_page() { # $1=IsTruncated $2=NextMarker，其后为 summary
    local truncated=$1 next=$2
    shift 2
    jq -cn --argjson truncated "${truncated}" --arg next "${next}" --args '{
        DistributionList: ({
            IsTruncated:$truncated,
            MaxItems:100,
            Quantity:($ARGS.positional|length),
            Items:($ARGS.positional|map(fromjson))
        } + (if $next == "" then {} else {NextMarker:$next} end))
    }' "$@"
}
acm_list_page() { # $1=NextToken，其后为 ARN
    local next=$1
    shift
    jq -cn --arg next "${next}" --args '{
        CertificateSummaryList:($ARGS.positional|map({CertificateArn:.}))
    } + (if $next == "" then {} else {NextToken:$next} end)' "$@"
}
stub_distribution_config() { # $1=输出文件 $2=对 get-distribution-config 响应的 jq 变换
    local out=$1 transform=${2:-.}
    build_distribution_config "${TMP_DIR}/stub-dist-config.json" caller-stub
    jq -cn --arg etag "ETAG-1" --slurpfile config "${TMP_DIR}/stub-dist-config.json" \
        '{ETag:$etag, DistributionConfig:$config[0]}' \
        | jq -c "${transform}" >"${out}"
}
stub_acm_certificate() { # $1=arn $2=describe JSON $3=tags JSON
    local arn=$1 description=$2 tags=$3
    jq -c --arg arn "${arn}" --argjson description "${description}" --argjson tags "${tags}" \
        '.certs[$arn] = $description | .tags[$arn] = $tags' "${AWS_STUB_DIR}/acm.json" \
        >"${AWS_STUB_DIR}/acm.json.new"
    mv -f -- "${AWS_STUB_DIR}/acm.json.new" "${AWS_STUB_DIR}/acm.json"
}
stub_acm_certificate_description() { # $1=arn $2=status $3=域名数组 JSON $4=InUseBy JSON
    jq -cn --arg arn "$1" --arg status "$2" --argjson domains "$3" --argjson in_use_by "$4" '{
        Certificate:{
            Status:$status,
            CertificateArn:$arn,
            DomainName:$domains[0],
            SubjectAlternativeNames:$domains,
            InUseBy:$in_use_by,
            DomainValidationOptions:[{
                ResourceRecord:{Name:"_acm.example.com.",Type:"CNAME",Value:"_x.acm-validations.aws."}
            }]
        }
    }'
}
stub_owned_acm() { # $1=arn
    stub_acm_certificate "$1" \
        "$(stub_acm_certificate_description "$1" ISSUED \
            "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" '[]')" \
        "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
            '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
}
dns_record_json() { # $1=type $2=name $3=id $4=content $5=comment
    jq -cn --arg type "$1" --arg name "$2" --arg id "$3" --arg content "$4" --arg comment "$5" \
        '{type:$type,name:$name,id:$id,content:$content,comment:$comment,proxied:false}'
}
write_dns_fixture() { # $1=输出文件，其后为 dns_record_json 的结果
    local out=$1
    shift
    jq -cn --args '{records:($ARGS.positional|map(fromjson))}' "$@" >"${out}"
}
line_of() { grep -n -F -- "$1" "${AWS_CALL_LOG}" 2>/dev/null | head -n 1 | cut -d: -f1; }
assert_order() { # $1=说明 $2=先出现的调用 $3=后出现的调用
    local first second
    first=$(line_of "$2")
    second=$(line_of "$3")
    [[ -n "${first}" && -n "${second}" && "${first}" -lt "${second}" ]] \
        || fail_test "$1（${2} 应先于 ${3}）"
}

OWNED_ACM_ARN="arn:aws:acm:us-east-1:${AWS_STUB_ACCOUNT}:certificate/owned"
OTHER_ACM_ARN="arn:aws:acm:us-east-1:${AWS_STUB_ACCOUNT}:certificate/other"
SECOND_NODE_ACM_ARN="arn:aws:acm:us-east-1:${AWS_STUB_ACCOUNT}:certificate/second"
NEW_ACM_ARN="arn:aws:acm:us-east-1:${AWS_STUB_ACCOUNT}:certificate/new"
FOREIGN_ACM_ARN="arn:aws:acm:ap-southeast-1:${AWS_STUB_ACCOUNT}:certificate/foreign"

# 与 uninstall 相同的隔离上下文：云清理在子 shell 中执行，AWS 调用全部走 stub。
run_purge() {
    (
        export AWS_ACCESS_KEY_ID=AKIAFAKEFAKEFAKEFAKE
        export AWS_SECRET_ACCESS_KEY=stub-secret-abcdefghij-1234567890
        export CLOUDFLARE_ZONE_ID=zone-123
        cdn_ensure_zone_id() { :; }
        # 模式 3 直连域名钩子（模式 2 下为空），用环境变量模拟。
        cdn_direct_domains() {
            [[ -n "${PURGE_DIRECT_DOMAINS:-}" ]] || return 0
            printf '%s\n' ${PURGE_DIRECT_DOMAINS}
        }
        wait_for_cloudfront_distribution() { return "${PURGE_WAIT_STATUS:-0}"; }
        cloudflare_record_list() {
            printf 'cf list %s %s\n' "$2" "$3" >>"${AWS_CALL_LOG}"
            jq -c --arg type "$2" --arg host "$3" \
                '[.records[] | select(.type == $type and .name == $host)]' "${CF_FIXTURE}"
        }
        cloudflare_api_request() {
            printf 'cf %s %s\n' "$1" "$2" >>"${AWS_CALL_LOG}"
            printf 'null\n'
        }
        cdn_purge_aws_resources
    )
}
purge_fixture() { # 源站 A + 节点/订阅 CNAME + 模式 3 直连 A + validation CNAME
    write_dns_fixture "${CF_FIXTURE}" \
        "$(dns_record_json A "${CF_ORIGIN_DOMAIN}" rec-origin "${VPS_PUBLIC_IPV4}" "${CDN_RECORD_COMMENT}")" \
        "$(dns_record_json CNAME "${CF_NODE_DOMAIN}" rec-node "${AWS_CLOUDFRONT_DOMAIN}" "${CDN_RECORD_COMMENT}")" \
        "$(dns_record_json CNAME "${SUBSCRIPTION_DOMAIN}" rec-sub "${AWS_CLOUDFRONT_DOMAIN}" "${CDN_RECORD_COMMENT}")" \
        "$(dns_record_json A direct.example.com rec-direct "${VPS_PUBLIC_IPV4}" "${CDN_RECORD_COMMENT}")" \
        "$(dns_record_json CNAME _acm.example.com rec-validation _x.acm-validations.aws. "${CDN_RECORD_COMMENT}")"
}

# --- 13.1 无状态发现：唯一候选复用（summary 结构 + 完整分页） ----------------
aws_reset
dist_list_page true "PAGE-2" \
    "$(dist_summary EDFOTHER d100.cloudfront.net "another deployment" api.example.net)" \
    >"${AWS_STUB_DIR}/dist-pages/0.json"
dist_list_page false "" \
    "$(dist_summary EDFOWNED d111.cloudfront.net "easy_all-cloudfront-${CF_NODE_DOMAIN}" \
        "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}")" \
    >"${AWS_STUB_DIR}/dist-pages/1.json"
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
(
    AWS_CLOUDFRONT_DISTRIBUTION_ID=""
    AWS_CLOUDFRONT_DOMAIN=""
    configure_cloudfront_distribution
    printf 'ID=%s\nDOMAIN=%s\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ID}" "${AWS_CLOUDFRONT_DOMAIN}"
) >"${TMP_DIR}/discovery-reuse.log" 2>&1 || fail_test "唯一 marker 候选必须复用成功"
assert_contains "复用候选的分发 ID" "$(<"${TMP_DIR}/discovery-reuse.log")" "ID=EDFOWNED"
assert_contains "复用候选的分发域名" "$(<"${TMP_DIR}/discovery-reuse.log")" \
    "DOMAIN=d111.cloudfront.net"
assert_equal "复用不创建新分发" "0" "$(aws_count 'cloudfront create-distribution')"
assert_equal "复用走一次 update" "1" "$(aws_count 'cloudfront update-distribution')"
assert_equal "发现前确认当前账号" "1" "$(aws_count 'sts get-caller-identity')"
assert_equal "两页分页都读完" "2" "$(aws_count 'cloudfront list-distributions')"
assert_equal "发现分发 ID 后立即落盘" "EDFOWNED|d111.cloudfront.net" \
    "$(jq -r '[.aws_cloudfront_distribution_id,.aws_cloudfront_domain]|join("|")' \
        "${STATE_DIR}/install-identity.json")"

# --- 13.2 零候选 → 新建 ------------------------------------------------------
aws_reset
dist_list_page false "" \
    "$(dist_summary EDFOTHER d100.cloudfront.net "another deployment" api.example.net)" \
    >"${AWS_STUB_DIR}/dist-pages/0.json"
(
    AWS_CLOUDFRONT_DISTRIBUTION_ID=""
    AWS_CLOUDFRONT_DOMAIN=""
    configure_cloudfront_distribution
    printf 'ID=%s\n' "${AWS_CLOUDFRONT_DISTRIBUTION_ID}"
) >"${TMP_DIR}/discovery-create.log" 2>&1 || fail_test "零候选必须新建分发"
assert_equal "零候选创建一次" "1" "$(aws_count 'cloudfront create-distribution')"
assert_equal "零候选不调用 update" "0" "$(aws_count 'cloudfront update-distribution')"
assert_contains "新建后记录新 ID" "$(<"${TMP_DIR}/discovery-create.log")" "ID=EDFNEW"

# --- 13.3 分页重复 marker / 多候选 / 权限失败 / alias 被占用 → die 且零 create ---
aws_reset
dist_list_page true "PAGE-2" \
    "$(dist_summary EDFOTHER d100.cloudfront.net "another deployment")" \
    >"${AWS_STUB_DIR}/dist-pages/0.json"
dist_list_page true "PAGE-2" \
    "$(dist_summary EDFOTHER2 d102.cloudfront.net "another deployment")" \
    >"${AWS_STUB_DIR}/dist-pages/1.json"
if (AWS_CLOUDFRONT_DISTRIBUTION_ID="" configure_cloudfront_distribution) \
    >"${TMP_DIR}/discovery-repeat.log" 2>&1; then
    fail_test "末页重复 marker 必须失败而不是继续创建"
fi
assert_contains "重复 marker 明确报错" "$(<"${TMP_DIR}/discovery-repeat.log")" "marker 重复"
assert_equal "重复 marker 零 create" "0" "$(aws_count 'cloudfront create-distribution')"

aws_reset
dist_list_page false "" \
    "$(dist_summary EDFA d111.cloudfront.net "easy_all-cloudfront-${CF_NODE_DOMAIN}" \
        "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}")" \
    "$(dist_summary EDFB d112.cloudfront.net "easy_all-cloudfront-${CF_NODE_DOMAIN}" \
        "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}")" \
    >"${AWS_STUB_DIR}/dist-pages/0.json"
if (AWS_CLOUDFRONT_DISTRIBUTION_ID="" configure_cloudfront_distribution) \
    >"${TMP_DIR}/discovery-multi.log" 2>&1; then
    fail_test "多个精确 marker 候选必须失败"
fi
assert_contains "多候选提示人工核对" "$(<"${TMP_DIR}/discovery-multi.log")" \
    "2 个 easy_all CloudFront 分发"
assert_equal "多候选零 create" "0" "$(aws_count 'cloudfront create-distribution')"

aws_reset
: >"${AWS_STUB_DIR}/fail-cloudfront-list-distributions"
if (AWS_CLOUDFRONT_DISTRIBUTION_ID="" configure_cloudfront_distribution) \
    >"${TMP_DIR}/discovery-denied.log" 2>&1; then
    fail_test "列举分发失败必须失败而不是降级为新建"
fi
assert_contains "权限失败明确报错" "$(<"${TMP_DIR}/discovery-denied.log")" \
    "列举 CloudFront 分发失败"
assert_equal "权限失败零 create" "0" "$(aws_count 'cloudfront create-distribution')"

aws_reset
dist_list_page false "" \
    "$(dist_summary EDFOTHER d100.cloudfront.net "another deployment" "${CF_NODE_DOMAIN}")" \
    >"${AWS_STUB_DIR}/dist-pages/0.json"
if (AWS_CLOUDFRONT_DISTRIBUTION_ID="" configure_cloudfront_distribution) \
    >"${TMP_DIR}/discovery-alias.log" 2>&1; then
    fail_test "别名已被他人占用时必须失败"
fi
assert_contains "alias 占用提示人工核对" "$(<"${TMP_DIR}/discovery-alias.log")" \
    "已被其他分发占用"
assert_equal "alias 占用零 create" "0" "$(aws_count 'cloudfront create-distribution')"

# --- 13.4 状态 ID 的归属校验：marker/alias/origin 任一不符 → 零写 API --------
for ownership_case in comment alias origin; do
    aws_reset
    case "${ownership_case}" in
    comment)
        ownership_transform='.DistributionConfig.Comment = "easy_all-cloudfront-other.example.com"'
        ;;
    alias)
        ownership_transform='.DistributionConfig.Aliases.Items = ["cf.example.com","sub.example.com","extra.example.com"]
            | .DistributionConfig.Aliases.Quantity = 3'
        ;;
    origin)
        ownership_transform='.DistributionConfig.Origins.Items[0].DomainName = "evil.example.com"'
        ;;
    esac
    stub_distribution_config "${AWS_STUB_DIR}/dist-config.json" "${ownership_transform}"
    if (AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
        configure_cloudfront_distribution) >"${TMP_DIR}/ownership.log" 2>&1; then
        fail_test "归属不符（${ownership_case}）必须拒绝更新"
    fi
    assert_contains "归属不符（${ownership_case}）说明原因" "$(<"${TMP_DIR}/ownership.log")" \
        "归属校验失败"
    assert_equal "归属不符（${ownership_case}）零写 API" "0" \
        "$(aws_write_calls | wc -l | tr -d ' ')"
done
# 唯一候选在 get-config 阶段归属不符同样零写（发现路径也要校验）
aws_reset
dist_list_page false "" \
    "$(dist_summary EDFOWNED d111.cloudfront.net "easy_all-cloudfront-${CF_NODE_DOMAIN}" \
        "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}")" \
    >"${AWS_STUB_DIR}/dist-pages/0.json"
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json" \
    '.DistributionConfig.Origins.Items[0].DomainName = "evil.example.com"'
if (AWS_CLOUDFRONT_DISTRIBUTION_ID="" configure_cloudfront_distribution) \
    >"${TMP_DIR}/discovery-ownership.log" 2>&1; then
    fail_test "发现的候选归属不符必须拒绝接管"
fi
assert_equal "发现路径归属不符零写 API" "0" "$(aws_write_calls | wc -l | tr -d ' ')"

# --- 13.5 云清理：分发校验/删除/等待失败 → 零 ACM、零 DNS，记 failed --------
aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json" \
    '.DistributionConfig.Comment = "easy_all-cloudfront-other.example.com"'
stub_owned_acm "${OWNED_ACM_ARN}"
purge_fixture
purge_status=0
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
    AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" run_purge >"${TMP_DIR}/purge-owner.log" 2>&1 \
    || purge_status=$?
assert_equal "归属不符的分发记清理失败" "1" "${purge_status}"
assert_equal "归属不符不删 ACM" "0" "$(aws_count 'acm delete-certificate')"
assert_equal "归属不符不删 DNS" "0" "$(aws_count 'cf DELETE')"
assert_equal "归属不符不改分发" "0" "$(aws_count 'cloudfront update-distribution')"

aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
stub_owned_acm "${OWNED_ACM_ARN}"
purge_fixture
: >"${AWS_STUB_DIR}/fail-cloudfront-delete-distribution"
purge_status=0
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
    AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" run_purge >"${TMP_DIR}/purge-delete.log" 2>&1 \
    || purge_status=$?
assert_equal "分发删除失败记清理失败" "1" "${purge_status}"
assert_equal "分发删除失败不删 ACM" "0" "$(aws_count 'acm delete-certificate')"
assert_equal "分发删除失败不删 CNAME/直连 DNS" "0" "$(aws_count 'cf DELETE')"

aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
stub_owned_acm "${OWNED_ACM_ARN}"
purge_fixture
purge_status=0
PURGE_WAIT_STATUS=1 AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 \
    AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" \
    run_purge >"${TMP_DIR}/purge-wait.log" 2>&1 || purge_status=$?
assert_equal "等待部署超时记清理失败" "1" "${purge_status}"
assert_equal "等待超时后不删分发" "0" "$(aws_count 'cloudfront delete-distribution')"
assert_equal "等待超时后不删 ACM" "0" "$(aws_count 'acm delete-certificate')"
assert_equal "等待超时后不删 DNS" "0" "$(aws_count 'cf DELETE')"

# --- 13.6 云清理成功次序：禁用→删除分发→ACM→CNAME，validation CNAME 不动 ----
aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
stub_owned_acm "${OWNED_ACM_ARN}"
purge_fixture
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
    AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" run_purge >"${TMP_DIR}/purge-ok.log" 2>&1 \
    || fail_test "归属正确的分发/证书/DNS 清理必须成功"
assert_equal "分发先禁用" "1" "$(aws_count 'cloudfront update-distribution')"
assert_order "顺序：禁用→删除分发" "cloudfront update-distribution" "cloudfront delete-distribution"
assert_order "顺序：删除分发→删除 ACM" "cloudfront delete-distribution" "acm delete-certificate"
assert_order "顺序：删除 ACM→删除节点 CNAME" "acm delete-certificate" \
    "cf DELETE /zones/zone-123/dns_records/rec-node"
assert_equal "节点/订阅 CNAME 与源站 A 各删一次" "3" "$(aws_count 'cf DELETE')"
assert_equal "validation CNAME 不在清理列表" "0" "$(aws_count '_acm.example.com')"

# --- 13.7 云清理：DNS 目标/注释不符不删；模式 3 直连与源站复用只删一次 ------
aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
stub_owned_acm "${OWNED_ACM_ARN}"
write_dns_fixture "${CF_FIXTURE}" \
    "$(dns_record_json A "${CF_ORIGIN_DOMAIN}" rec-origin "${VPS_PUBLIC_IPV4}" "${CDN_RECORD_COMMENT}")" \
    "$(dns_record_json CNAME "${CF_NODE_DOMAIN}" rec-node d-other.cloudfront.net "${CDN_RECORD_COMMENT}")" \
    "$(dns_record_json CNAME "${SUBSCRIPTION_DOMAIN}" rec-sub "${AWS_CLOUDFRONT_DOMAIN}" "手动记录")"
purge_status=0
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
    AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" run_purge >"${TMP_DIR}/purge-mismatch.log" 2>&1 \
    || purge_status=$?
assert_equal "目标/注释不符只告警不记失败" "0" "${purge_status}"
assert_equal "目标不符的 CNAME 不删" "0" "$(aws_count 'rec-node')"
assert_equal "注释不符的 CNAME 不删" "0" "$(aws_count 'rec-sub')"
assert_equal "源站 A 仍按精确匹配删除" "1" "$(aws_count 'rec-origin')"
assert_contains "目标变化写入告警" "$(<"${TMP_DIR}/purge-mismatch.log")" "目标已变化"
assert_contains "注释不符写入告警" "$(<"${TMP_DIR}/purge-mismatch.log")" "不是本链路创建的"

aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
stub_owned_acm "${OWNED_ACM_ARN}"
purge_fixture
PURGE_DIRECT_DOMAINS="${CF_ORIGIN_DOMAIN} direct.example.com" \
    AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
    AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" run_purge >"${TMP_DIR}/purge-direct.log" 2>&1 \
    || fail_test "模式 3 直连域的清理必须成功"
assert_equal "源站 A 与直连复用只删一次" "1" "$(aws_count 'rec-origin')"
assert_equal "额外直连域名进入清理" "1" "$(aws_count 'rec-direct')"
assert_equal "复用后共删 4 条 DNS" "4" "$(aws_count 'cf DELETE')"

# --- 13.8 ACM 删除的归属校验：标记/SAN/InUseBy/region 任一不符 → 零删除 -----
for acm_case in node-tag san in-use-by; do
    aws_reset
    stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
    purge_fixture
    case "${acm_case}" in
    node-tag)
        stub_acm_certificate "${OWNED_ACM_ARN}" \
            "$(stub_acm_certificate_description "${OWNED_ACM_ARN}" ISSUED \
                "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" '[]')" \
            '{"Tags":[{"Key":"easy_all","Value":"managed"},{"Key":"easy_all-node","Value":"other.example.com"}]}'
        ;;
    san)
        stub_acm_certificate "${OWNED_ACM_ARN}" \
            "$(stub_acm_certificate_description "${OWNED_ACM_ARN}" ISSUED \
                "[\"${CF_NODE_DOMAIN}\"]" '[]')" \
            "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
                '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
        ;;
    in-use-by)
        stub_acm_certificate "${OWNED_ACM_ARN}" \
            "$(stub_acm_certificate_description "${OWNED_ACM_ARN}" ISSUED \
                "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" \
                '["arn:aws:cloudfront::123456789012:distribution/EDFDIST123"]')" \
            "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
                '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
        ;;
    esac
    purge_status=0
    AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
        AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}" run_purge >"${TMP_DIR}/purge-acm.log" 2>&1 \
        || purge_status=$?
    assert_equal "ACM ${acm_case} 不符记清理失败" "1" "${purge_status}"
    assert_equal "ACM ${acm_case} 不符零删除" "0" "$(aws_count 'acm delete-certificate')"
    assert_contains "ACM ${acm_case} 不符保留并告警" "$(<"${TMP_DIR}/purge-acm.log")" \
        "ACM 证书未通过归属校验"
    assert_equal "ACM ${acm_case} 失败不阻止 CNAME 清理" "3" "$(aws_count 'cf DELETE')"
done

# 非 us-east-1 的 ARN：证书内容全部合格也不得删除
aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
purge_fixture
stub_acm_certificate "${FOREIGN_ACM_ARN}" \
    "$(stub_acm_certificate_description "${FOREIGN_ACM_ARN}" ISSUED \
        "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" '[]')" \
    "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
        '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
purge_status=0
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123 AWS_CLOUDFRONT_DOMAIN=d111.cloudfront.net \
    AWS_ACM_CERTIFICATE_ARN="${FOREIGN_ACM_ARN}" run_purge >"${TMP_DIR}/purge-acm-region.log" 2>&1 \
    || purge_status=$?
assert_equal "非 us-east-1 的 ACM 记清理失败" "1" "${purge_status}"
assert_equal "非 us-east-1 的 ACM 零删除" "0" "$(aws_count 'acm delete-certificate')"
assert_contains "非 us-east-1 的 ACM 保留并告警" "$(<"${TMP_DIR}/purge-acm-region.log")" \
    "ACM 证书未通过归属校验"

# --- 13.9 ACM 无状态发现：完整分页 + 标记/SAN/状态校验 ----------------------
aws_reset
stub_owned_acm "${OWNED_ACM_ARN}"
stub_acm_certificate "${OTHER_ACM_ARN}" \
    "$(stub_acm_certificate_description "${OTHER_ACM_ARN}" ISSUED \
        '["other.example.com"]' '[]')" '{"Tags":[]}'
acm_list_page "NEXT-2" "${OTHER_ACM_ARN}" >"${AWS_STUB_DIR}/acm-pages/0.json"
acm_list_page "" "${OWNED_ACM_ARN}" >"${AWS_STUB_DIR}/acm-pages/1.json"
(
    AWS_ACM_CERTIFICATE_ARN=""
    find_or_request_acm_certificate
    printf 'ARN=%s\n' "${AWS_ACM_CERTIFICATE_ARN}"
) >"${TMP_DIR}/acm-reuse.log" 2>&1 || fail_test "唯一带标记的 ISSUED 证书必须复用"
assert_contains "复用 ACM ARN" "$(<"${TMP_DIR}/acm-reuse.log")" "ARN=${OWNED_ACM_ARN}"
assert_equal "复用不新建证书" "0" "$(aws_count 'acm request-certificate')"
assert_equal "ACM 分页读完两页" "2" "$(aws_count 'acm list-certificates')"
assert_equal "两个候选都查过标签" "2" "$(aws_count 'acm list-tags-for-certificate')"

aws_reset
stub_acm_certificate "${OTHER_ACM_ARN}" \
    "$(stub_acm_certificate_description "${OTHER_ACM_ARN}" ISSUED \
        '["other.example.com"]' '[]')" '{"Tags":[]}'
stub_acm_certificate "${NEW_ACM_ARN}" \
    "$(stub_acm_certificate_description "${NEW_ACM_ARN}" ISSUED \
        "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" '[]')" \
    "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
        '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
acm_list_page "" "${OTHER_ACM_ARN}" >"${AWS_STUB_DIR}/acm-pages/0.json"
(
    AWS_ACM_CERTIFICATE_ARN=""
    find_or_request_acm_certificate
    printf 'ARN=%s\n' "${AWS_ACM_CERTIFICATE_ARN}"
) >"${TMP_DIR}/acm-create.log" 2>&1 || fail_test "零候选必须新建 ACM 证书"
assert_contains "新建 ACM ARN 落回状态" "$(<"${TMP_DIR}/acm-create.log")" "ARN=${NEW_ACM_ARN}"
assert_equal "零候选新建一次" "1" "$(aws_count 'acm request-certificate')"
create_token=$(grep -F 'acm request-certificate' "${AWS_CALL_LOG}" \
    | sed -n 's/.*--idempotency-token \([^ ]*\).*/\1/p')
assert_equal "新建证书使用确定性幂等 Token" "$(cloudfront_acm_idempotency_token)" "${create_token}"

# 两个都带本节点标记 → 歧义，零新建
aws_reset
for duplicate_arn in "${OWNED_ACM_ARN}" "${SECOND_NODE_ACM_ARN}"; do
    stub_acm_certificate "${duplicate_arn}" \
        "$(stub_acm_certificate_description "${duplicate_arn}" ISSUED \
            "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" '[]')" \
        "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
            '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
done
acm_list_page "" "${OWNED_ACM_ARN}" "${SECOND_NODE_ACM_ARN}" \
    >"${AWS_STUB_DIR}/acm-pages/0.json"
if (AWS_ACM_CERTIFICATE_ARN="" find_or_request_acm_certificate) \
    >"${TMP_DIR}/acm-multi.log" 2>&1; then
    fail_test "多个带标记的 ACM 证书必须判为歧义"
fi
assert_contains "ACM 歧义提示人工核对" "$(<"${TMP_DIR}/acm-multi.log")" "请先人工核对"
assert_equal "ACM 歧义零新建" "0" "$(aws_count 'acm request-certificate')"

# 标签查询失败 → die，零新建
aws_reset
stub_owned_acm "${OWNED_ACM_ARN}"
acm_list_page "" "${OWNED_ACM_ARN}" >"${AWS_STUB_DIR}/acm-pages/0.json"
: >"${AWS_STUB_DIR}/fail-acm-list-tags-for-certificate"
if (AWS_ACM_CERTIFICATE_ARN="" find_or_request_acm_certificate) \
    >"${TMP_DIR}/acm-tags-fail.log" 2>&1; then
    fail_test "标签查询失败必须退出而不是新建"
fi
assert_contains "标签查询失败明确报错" "$(<"${TMP_DIR}/acm-tags-fail.log")" "读取 ACM 证书标签失败"
assert_equal "标签查询失败零新建" "0" "$(aws_count 'acm request-certificate')"

# 带本节点标记但未签发（不可复用）→ die，零新建
aws_reset
stub_acm_certificate "${OWNED_ACM_ARN}" \
    "$(stub_acm_certificate_description "${OWNED_ACM_ARN}" PENDING_VALIDATION \
        "[\"${CF_NODE_DOMAIN}\",\"${SUBSCRIPTION_DOMAIN}\"]" '[]')" \
    "$(jq -cn --arg node "${CF_NODE_DOMAIN}" \
        '{Tags:[{Key:"easy_all",Value:"managed"},{Key:"easy_all-node",Value:$node}]}')"
acm_list_page "" "${OWNED_ACM_ARN}" >"${AWS_STUB_DIR}/acm-pages/0.json"
if (AWS_ACM_CERTIFICATE_ARN="" find_or_request_acm_certificate) \
    >"${TMP_DIR}/acm-pending.log" 2>&1; then
    fail_test "带标记但不可复用的证书必须退出而不是新建"
fi
assert_contains "不可复用证书提示人工核对" "$(<"${TMP_DIR}/acm-pending.log")" "不可复用"
assert_equal "不可复用证书零新建" "0" "$(aws_count 'acm request-certificate')"

# --- 13.10 ACM 幂等 Token：\w+ 且不超过 32 字符 ----------------------------
acm_token=$(cloudfront_acm_idempotency_token) || fail_test "必须能生成 ACM 幂等 Token"
[[ "${acm_token}" =~ ^[A-Za-z0-9_]{1,32}$ ]] \
    || fail_test "ACM 幂等 Token 必须匹配 ^[A-Za-z0-9_]{1,32}\$：${acm_token}"
assert_equal "幂等 Token 确定性" "${acm_token}" "$(cloudfront_acm_idempotency_token)"
(
    CF_NODE_DOMAIN="$(printf 'a%.0s' {1..40}).example.com"
    long_token=$(cloudfront_acm_idempotency_token) || exit 1
    [[ "${long_token}" =~ ^[A-Za-z0-9_]{1,32}$ ]] || exit 1
    [[ "${long_token}" != "${acm_token}" ]]
) || fail_test "长域名的幂等 Token 也不得超限或退化"


# --- 13.11 AWS 凭据：apply-cloud 显式收集并在结束时清除 ---------------------
command rm -f -- "${TMP_DIR}/prompt.counter"
(
    apply_cloud_stubs
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
    apply_cloud_resources
    printf 'after=%s\n' "${AWS_ACCESS_KEY_ID:-cleared}"
) >"${TMP_DIR}/apply-cloud-credentials.log" 2>&1 || fail_test "apply-cloud 必须成功"
apply_cloud_body=$(<"${TMP_DIR}/apply-cloud-credentials.log")
assert_equal "apply-cloud 无环境凭据时逐项收集" "2" "$(<"${TMP_DIR}/prompt.counter")"
assert_contains "AWS 调用时凭据已在内存" "${apply_cloud_body}" "acm-key=AKIAFAKEFAKEFAKEFAKE"
assert_contains "分发阶段仍持有凭据" "${apply_cloud_body}" "dist-key=AKIAFAKEFAKEFAKEFAKE"
assert_contains "apply-cloud 成功前执行公网验收" "${apply_cloud_body}" "PUBLIC-ACCEPT"
assert_contains "apply-cloud 成功前恢复命令注册" "${apply_cloud_body}" "REGISTER"
assert_contains "apply-cloud 成功前恢复保护定时器" "${apply_cloud_body}" "TIMER"
assert_contains "结束时清除内存凭据" "${apply_cloud_body}" "after=cleared"

# 公网验收失败：apply-cloud 必须非零且不得报同步成功（独立进程才有真 errexit）
if EASY_ALL_TEST_TMP_DIR="${TMP_DIR}" EASY_ALL_TEST_SCENARIO=apply-cloud-public-failure \
    bash "${BASH_SOURCE[0]}" >"${TMP_DIR}/apply-cloud-public-failure.log" 2>&1; then
    fail_test "公网验收失败时 apply-cloud 必须非零"
fi
apply_cloud_public_fail=$(<"${TMP_DIR}/apply-cloud-public-failure.log")
assert_not_contains "公网验收失败不报同步成功" "${apply_cloud_public_fail}" "已同步"
assert_not_contains "公网验收失败不恢复定时器" "${apply_cloud_public_fail}" "TIMER"

# --- 13.12 purge 缺凭据不得中止本机卸载 ------------------------------------
command rm -f -- "${TMP_DIR}/uninstall-local.log"
(
    require_root() { :; }
    stop_maintenance_services() { :; }
    acquire_runtime_write_lock() { :; }
    load_state() { :; }
    cdn_print_cloud_inventory() { :; }
    cdn_local_uninstall_common() { printf 'local-uninstall\n' >>"${TMP_DIR}/uninstall-local.log"; }
    collect_aws_credentials() { die '缺少 AWS Access Key ID'; }
    AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDIST123
    AWS_ACM_CERTIFICATE_ARN="${OWNED_ACM_ARN}"
    FORCE=1
    uninstall_all --purge-cloud
) >"${TMP_DIR}/uninstall.log" 2>&1 || fail_test "缺凭据的 --purge-cloud 不得中止本机卸载"
assert_contains "缺凭据时仍执行本机卸载" "$(<"${TMP_DIR}/uninstall-local.log")" "local-uninstall"
assert_contains "缺凭据时明确告警" "$(<"${TMP_DIR}/uninstall.log")" "本机卸载继续"

# --- 13.13 AWS stub 的真实性：非法请求被拒、错误响应可断言 --------------------
# stub 必须像真实 API 一样拒绝非法参数与错误响应，否则“绿色测试”会放过构造非法
# 请求的回归（例如幂等 Token 含点、分发配置缺关键字段、更新缺 ETag）。
aws_reset
set +e
bad_token_out=$(aws ${CLOUDFRONT_AWS_CLI_ARGS[@]} acm request-certificate \
    --region us-east-1 --domain-name cf.example.com --validation-method DNS \
    --idempotency-token "easy-all-cf.example.com-1" \
    --tags "Key=easy_all,Value=managed" "Key=easy_all-node,Value=cf.example.com" \
    --query CertificateArn --output text 2>&1)
bad_token_status=$?
set -e
assert_equal "非法幂等 Token 被 stub 拒绝" "254" "${bad_token_status}"
assert_contains "非法幂等 Token 的 AWS 错误码可断言" "${bad_token_out}" \
    "An error occurred (ValidationException)"
assert_contains "非法幂等 Token 指出 idempotencyToken" "${bad_token_out}" "idempotencyToken"
assert_not_contains "非法请求不得返回 ARN" "${bad_token_out}" "arn:aws:acm:"

set +e
missing_tags_out=$(aws ${CLOUDFRONT_AWS_CLI_ARGS[@]} acm request-certificate \
    --region us-east-1 --domain-name cf.example.com --validation-method DNS \
    --idempotency-token eacfdeadbeefdeadbeefdeadbeefdead \
    --query CertificateArn --output text 2>&1)
missing_tags_status=$?
set -e
assert_equal "缺归属标签的申请被 stub 拒绝" "254" "${missing_tags_status}"
assert_contains "缺归属标签的报错可断言" "${missing_tags_out}" "缺少 easy_all 归属标签"

write_valid_dist_config() { # $1=输出文件 $2=对配置的 jq 变换
    build_distribution_config "$1" caller-stub
    if [[ -n "${2:-}" ]]; then
        jq -c "${2}" "$1" >"$1.tmp" && mv -f -- "$1.tmp" "$1"
    fi
}
write_valid_dist_config "${TMP_DIR}/stub-bad-policy.json" \
    '.DefaultCacheBehavior.CachePolicyId = "00000000-0000-0000-0000-000000000000"'
set +e
bad_policy_out=$(aws ${CLOUDFRONT_AWS_CLI_ARGS[@]} cloudfront create-distribution \
    --distribution-config "file://${TMP_DIR}/stub-bad-policy.json" --output json 2>&1)
bad_policy_status=$?
set -e
assert_equal "错误缓存策略的分发配置被 stub 拒绝" "254" "${bad_policy_status}"
assert_contains "错误缓存策略的报错可断言" "${bad_policy_out}" "分发配置缺少关键字段"

set +e
missing_etag_out=$(aws ${CLOUDFRONT_AWS_CLI_ARGS[@]} cloudfront update-distribution \
    --id EDFDIST123 --distribution-config "${TMP_DIR}/stub-dist-config.json" \
    --output json 2>&1)
missing_etag_status=$?
set -e
assert_equal "缺少 --if-match 的更新被 stub 拒绝" "254" "${missing_etag_status}"
assert_contains "缺少 ETag 的报错可断言" "${missing_etag_out}" "InvalidIfMatchVersion"

# 服务端错误（限流）必须能让测试断言到 AWS 错误码与命令自身的失败信息。
aws_reset
stub_distribution_config "${AWS_STUB_DIR}/dist-config.json"
printf 'Rate exceeded\n' >"${AWS_STUB_DIR}/fail-cloudfront-create-distribution"
set +e
create_error_out=$( ( AWS_CLOUDFRONT_DISTRIBUTION_ID="" configure_cloudfront_distribution ) 2>&1 )
create_error_status=$?
set -e
assert_equal "创建分发遇到服务端错误必须非零" "1" "${create_error_status}"
assert_contains "保留 stub 的 AWS 错误码" "${create_error_out}" "An error occurred (AccessDenied)"
assert_contains "错误信息来自 stub 响应" "${create_error_out}" "Rate exceeded"
assert_contains "命令自身报告创建失败" "${create_error_out}" "创建 CloudFront 分发失败"
assert_equal "服务端错误不改写已记录的分发 ID" "EDFDIST123" \
    "$(jq -r '.aws_cloudfront_distribution_id' "${STATE_DIR}/install-identity.json")"
command rm -f -- "${AWS_STUB_DIR}/fail-cloudfront-create-distribution"

# --- 14. AWS CLI staging：archive/installer/包内程序都在安装区域（A10） ----------
(
    # 前面小节把 aws 桩成函数：本小节要考察真实 install_aws_cli，必须让 PATH 决定 aws。
    unset -f aws
    a10_root="${TMP_DIR}/a10"
    command rm -rf -- "${a10_root}"
    command mkdir -p "${a10_root}"
    export A10_LOG="${a10_root}/calls.log"
    # 旧实现把 staging 放在 RUNTIME_TMP：这里既不可写也不可执行，任何回退都会失败。
    export RUNTIME_TMP="${a10_root}/runtime-tmp"
    command mkdir -p "${RUNTIME_TMP}"
    command chmod 0500 "${RUNTIME_TMP}"
    export A10_BREAK_VERSION=0

    dpkg() { printf '%s\n' "${A10_DPKG_ARCH:-amd64}"; }
    curl() {
        local out="" url=""
        while (($# > 0)); do
            case "$1" in
            -o)
                out=$2
                shift 2
                ;;
            -*)
                shift
                ;;
            *)
                url=$1
                shift
                ;;
            esac
        done
        printf 'curl %s\n' "${url}" >>"${A10_LOG}"
        printf 'fake-awscliv2-zip\n' >"${out}"
    }
    # 离线 ZIP fixture：unzip 桩把 installer 与第二个包内程序展开到 -d 目录。
    unzip() {
        local dest="" archive=""
        while (($# > 0)); do
            case "$1" in
            -d)
                dest=$2
                shift 2
                ;;
            -*)
                shift
                ;;
            *)
                archive=$1
                shift
                ;;
            esac
        done
        [[ -n "${dest}" && -f "${archive}" ]] || return 1
        command mkdir -p "${dest}/aws/dist" || return 1
        cat >"${dest}/aws/install" <<'A10_INSTALLER'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'installer %s\n' "$*" >>"${A10_LOG}"
bin_dir=""
install_dir=""
while (($# > 0)); do
    case "$1" in
    --bin-dir)
        bin_dir=$2
        shift 2
        ;;
    --install-dir)
        install_dir=$2
        shift 2
        ;;
    *) shift ;;
    esac
done
self_dir=$(cd -- "$(dirname -- "$0")" && pwd)
# 真实 installer 也会拉起包内程序：这里执行包里的第二个程序。
"${self_dir}/dist/aws" --smoke || exit 1
install -d -m 0755 "${install_dir}/v2" "${bin_dir}" || exit 1
install -m 0755 "${self_dir}/dist/aws" "${install_dir}/v2/aws" || exit 1
ln -sfn "${install_dir}/v2/aws" "${bin_dir}/aws" || exit 1
A10_INSTALLER
        cat >"${dest}/aws/dist/aws" <<'A10_PACKAGE_PROGRAM'
#!/usr/bin/env bash
set -Eeuo pipefail
# 包内第二个程序：只有落在安装区域才能通过；/tmp 挂 noexec 时这里会失败。
case "$(cd -- "$(dirname -- "$0")" && pwd)" in
"${A10_INSTALL_PREFIX}"/*) ;;
*)
    printf '包内程序不在安装区域：%s\n' "$0" >&2
    exit 9
    ;;
esac
printf 'package-program %s\n' "$*" >>"${A10_LOG}"
[[ "${A10_BREAK_VERSION:-0}" != "1" || "${1:-}" != "--version" ]]
A10_PACKAGE_PROGRAM
        command chmod 0755 "${dest}/aws/install" "${dest}/aws/dist/aws"
    }
    a10_install() { # $1=安装区域前缀 $2=dpkg --print-architecture 的输出
        (
            export A10_INSTALL_PREFIX="$1" A10_DPKG_ARCH="$2"
            export EASY_ALL_AWS_CLI_PREFIX_OVERRIDE="$1"
            export PATH="$1/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            hash -r
            install_aws_cli
        )
    }

    # 14.1 arm64：URL 取 aarch64 包，installer 与包内第二个程序都从安装区域执行。
    : >"${A10_LOG}"
    a10_arm_prefix="${a10_root}/prefix-arm64"
    a10_arm_out=$(a10_install "${a10_arm_prefix}" arm64 2>&1) \
        || fail_test "AWS CLI 安装必须成功：${a10_arm_out}"
    a10_arm_log=$(<"${A10_LOG}")
    assert_contains "arm64 下载 aarch64 包" "${a10_arm_log}" \
        "curl https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip"
    assert_contains "installer 从安装区域执行并保留正式参数" "${a10_arm_log}" \
        "installer --bin-dir ${a10_arm_prefix}/bin --install-dir ${a10_arm_prefix}/aws-cli --update"
    assert_contains "包内第二个程序在安装区域执行" "${a10_arm_log}" "package-program --smoke"
    assert_contains "安装后用 aws --version 验证可执行" "${a10_arm_log}" "package-program --version"
    [[ -x "${a10_arm_prefix}/bin/aws" ]] || fail_test "AWS CLI 入口必须可执行"
    assert_equal "不残留私有 staging" "0" \
        "$(command find "${a10_arm_prefix}" -maxdepth 1 -name 'easy_all-aws-cli.*' | command wc -l | tr -d ' ')"
    assert_equal "RUNTIME_TMP（/tmp 侧）必须完全没用过" "0" \
        "$(command ls -A "${RUNTIME_TMP}" | command wc -l | tr -d ' ')"

    # 14.2 其他架构：URL 仍是官方 x86_64 包。
    : >"${A10_LOG}"
    a10_x86_prefix="${a10_root}/prefix-x86"
    a10_x86_out=$(a10_install "${a10_x86_prefix}" amd64 2>&1) \
        || fail_test "x86_64 上 AWS CLI 安装必须成功：${a10_x86_out}"
    assert_contains "amd64 下载 x86_64 包" "$(<"${A10_LOG}")" \
        "curl https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip"

    # 14.3 安装后入口不可执行：必须点名路径失败，不回退 /tmp。
    : >"${A10_LOG}"
    a10_bad_prefix="${a10_root}/prefix-broken"
    export A10_BREAK_VERSION=1
    a10_bad_rc=0
    a10_bad_out=$(a10_install "${a10_bad_prefix}" amd64 2>&1) || a10_bad_rc=$?
    export A10_BREAK_VERSION=0
    ((a10_bad_rc != 0)) || fail_test "入口无法执行时安装必须失败"
    assert_contains "失败点名不可执行的路径" "${a10_bad_out}" "${a10_bad_prefix}/bin/aws"
    assert_equal "失败后不在 /tmp 侧重试" "0" \
        "$(command ls -A "${RUNTIME_TMP}" | command wc -l | tr -d ' ')"
)

printf 'ok - cloudfront shared core\n'
