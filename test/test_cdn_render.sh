#!/usr/bin/env bash
# 纯 CDN（profiles/cdn.sh + lib/cloudflare-mode.sh）回归测试。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/cdn.sh"
MODE_LIB="${ROOT_DIR}/lib/cloudflare-mode.sh"

# 沙箱环境可能禁止写用户默认 TMPDIR：无参 mktemp 一律落到本测试的 /tmp 目录。
TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_cdn_test.XXXXXX")
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

bash -n "${PROFILE}" "${MODE_LIB}"

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
export IPV6_SYSCTL_CONF="${TMP_DIR}/sysctl/99-enable-ipv6.conf"
export EASY_ALL_PROC_IPV6_DIR="${TMP_DIR}/proc-ipv6"
export EASY_ALL_NGINX_MAIN_CONF="${TMP_DIR}/nginx-main/nginx.conf"
export CLOUDFLARE_ENTERPRISE_DOMAINS_OVERRIDE=""
sysctl() { :; }

mkdir -p "${STATE_DIR}" "${BACKUP_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" \
    "${WEB_ROOT}" "${SUBSCRIPTION_DIR}" "${COMMAND_INSTALL_DIR}" \
    "${TMP_DIR}/bin" "${XRAY_DIR}" "${TMP_DIR}/systemd" \
    "$(dirname "${IPV6_SYSCTL_CONF}")" "${EASY_ALL_PROC_IPV6_DIR}" \
    "$(dirname "${EASY_ALL_NGINX_MAIN_CONF}")"
printf 'worker_processes auto;\n' >"${EASY_ALL_NGINX_MAIN_CONF}"

# 同 test_combined_render.sh：隔离 readonly 常量与系统写入，让 profile 能在 /tmp 下渲染。
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

unset XRAY_XHTTP_LOOPBACK_PORT
unset CLOUDFLARE_UFW_PORT CLOUDFLARE_UFW_COMMENT CLOUDFLARE_ORIGIN_CA_ROOT_FILE
# shellcheck source=/dev/null
source "${PROFILE}"
unset -f readonly
require_root() { :; }
# source 会级联加载 lib/runtime-core.sh 的 `trap cleanup EXIT`，覆盖上面的临时目录清理；
# 这里恢复测试自己的 trap，避免每次运行都把含证书/配置的目录留在 /tmp。
trap 'status=$?; cleanup; command rm -rf -- "${TMP_DIR}"; exit "${status}"' EXIT

assert_equal "profile: 纯 CDN 不复用直连入口" "0" "${CDN_REALITY_ENABLED}"
assert_equal "profile: 回源 UFW 端口固定 443" "443" "${CLOUDFLARE_UFW_PORT}"
assert_equal "profile: 回源 UFW 注释与直连+CDN共用（卸载按注释回收）" \
    "easy_all-cf-origin" "${CLOUDFLARE_UFW_COMMENT}"
assert_equal "profile: 安装只断言 80/443 空闲" "80 443" "${CDN_INSTALL_PORTS[*]}"

# 初始化纯 CDN fixture：没有直连域名/DIRECT/REALITY 变量。
CF_ZONE="example.com"
CLOUDFLARE_ZONE_ID="zone-123456"
VPS_PUBLIC_IPV4="198.51.100.10"
CF_NODE_DOMAIN="cf-node.example.com"
SUBSCRIPTION_DOMAIN="sub.example.com"
VLESS_CDN_DOMAIN="${CF_NODE_DOMAIN}"
SUB_DOWNLOAD_NAME="EASYALL"
OWNER_TOKEN="cdnwq-rtbke-3182"
ALLOWED_TOKENS=$(jq -cn --arg token "${OWNER_TOKEN}" '{owner:$token}')
VLESS_UUID="11111111-2222-4111-8111-111111111111"
CF_NODE_PREFIX="🇺🇸CF"
XHTTP_PATH="/xhttp-cdnabcdef123"
CLOUDFLARE_API_TOKEN="cloudflare-token-abcdefghijklmnop"
CLOUDFLARE_ORIGIN_CERT_ID="cert-cdn-111"
CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2041-11-03 00:00:00 +0000 UTC"
SUBSCRIPTION_MODE="deploy"
TCP_ACCELERATION="skyline"
save_state

# 1) 状态文件：纯 CDN 不携带直连/Reality 字段，load_state 能自洽回读。
state_content=$(<"${STATE_FILE}")
assert_contains "state: 记录 cdn 协议" "${state_content}" "PROTOCOL=cdn"
assert_not_contains "state: 不再落盘直连域名" "${state_content}" "DIRECT_DOMAIN"
assert_not_contains "state: 不再落盘 Reality 伪装目标" "${state_content}" "REALITY_TARGET"
assert_not_contains "state: 不再落盘 Reality 私钥" "${state_content}" "REALITY_PRIVATE_KEY"
unset CF_NODE_DOMAIN CF_ZONE SUBSCRIPTION_DOMAIN
load_state || fail_test "state: 纯 CDN 状态必须能被 load_state 读回"
assert_equal "state: load_state 回填 CDN 域名" "cf-node.example.com" "${CF_NODE_DOMAIN}"
assert_equal "state: load_state 派生 VLESS_CDN_DOMAIN" "${CF_NODE_DOMAIN}" "${VLESS_CDN_DOMAIN}"
assert_equal "state: load_state 强制 deploy 订阅" "deploy" "${SUBSCRIPTION_MODE}"

# 2) DNS：只管理 CDN 节点与订阅两个橙云域名。
assert_equal "dns: 纯 CDN 没有灰云直连域名" "" "$(cdn_dns_only_domains)"
assert_equal "dns: 环境残留 DIRECT_DOMAIN 也不得产生灰云记录" "" \
    "$(DIRECT_DOMAIN="direct.example.com"; cdn_dns_only_domains)"
assert_equal "dns: 两个橙云域名" "$(printf '%s\n' "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}")" \
    "$(cdn_proxied_domains)"

dns_log="${TMP_DIR}/dns.log"
(
    cloudflare_collect_api_token() { :; }
    cloudflare_lookup_parent_zone() { printf '%s' "${CLOUDFLARE_ZONE_ID}"; }
    dns_ensure_record() { printf '%s %s\n' "$1" "$4" >>"${dns_log}"; }
    cdn_ensure_dns
) || fail_test "dns: cdn_ensure_dns must succeed"
assert_equal "dns: 只创建两个橙云 A 记录" \
    "$(printf 'cf-node.example.com true\nsub.example.com true')" "$(<"${dns_log}")"

# 2.1) 内容一致但注释属于另一个 CDN 模式的记录：必须改注释为当前模式，卸载才能回收。
adopt_log="${TMP_DIR}/dns-adopt.log"
: >"${adopt_log}"
(
    cloudflare_record_list() {
        printf '[{"id":"rec-cf","content":"198.51.100.10","proxied":true,"comment":"easy_all combined"}]\n'
    }
    cloudflare_api_request() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${adopt_log}"; }
    dns_ensure_record "${CF_NODE_DOMAIN}" A "198.51.100.10" true
) || fail_test "dns: 跨模式复用记录必须成功"
adopt_call=$(<"${adopt_log}")
assert_contains "dns: 跨模式复用会 PATCH 记录" "${adopt_call}" "PATCH /zones/zone-123456/dns_records/rec-cf"
assert_contains "dns: 注释改写为当前模式" "${adopt_call}" '"comment":"easy_all cdn"'
: >"${adopt_log}"
(
    cloudflare_record_list() {
        printf '[{"id":"rec-cf","content":"198.51.100.10","proxied":true,"comment":"my own record"}]\n'
    }
    cloudflare_api_request() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${adopt_log}"; }
    dns_ensure_record "${CF_NODE_DOMAIN}" A "198.51.100.10" true
) || fail_test "dns: 第三方同内容记录按旧行为复用"
[[ ! -s "${adopt_log}" ]] || fail_test "dns: 第三方记录不得被接管改注释"

# 2.2) 换机/跨模式重装时 IP 变化：easy_all 记录允许更新，第三方记录仍拒绝覆盖。
: >"${adopt_log}"
(
    cloudflare_record_list() {
        printf '[{"id":"rec-cf","content":"203.0.113.9","proxied":true,"comment":"easy_all combined"}]\n'
    }
    cloudflare_api_request() { printf '%s %s %s\n' "$1" "$2" "$3" >>"${adopt_log}"; }
    dns_ensure_record "${CF_NODE_DOMAIN}" A "198.51.100.10" true
) || fail_test "dns: 换机重装必须能更新 easy_all 记录"
assert_contains "dns: 换机重装 PATCH 新 IP" "$(<"${adopt_log}")" '"content":"198.51.100.10"'
assert_contains "dns: 换机重装改写当前模式注释" "$(<"${adopt_log}")" '"comment":"easy_all cdn"'
if (
    cloudflare_record_list() {
        printf '[{"id":"rec-cf","content":"203.0.113.9","proxied":true,"comment":"my own record"}]\n'
    }
    cloudflare_api_request() { :; }
    dns_ensure_record "${CF_NODE_DOMAIN}" A "198.51.100.10" true
) >/dev/null 2>&1; then
    fail_test "dns: 第三方记录内容不同必须拒绝覆盖"
fi

# 2.3) Token 落盘必须 0600 且内容正确。
persist_cloudflare_token
assert_equal "token: 持久化文件权限 0600" "600" "$(stat -c '%a' "${CLOUDFLARE_TOKEN_FILE}" 2>/dev/null || stat -f '%Lp' "${CLOUDFLARE_TOKEN_FILE}")"
assert_equal "token: 持久化文件内容" "${CLOUDFLARE_API_TOKEN}" "$(<"${CLOUDFLARE_TOKEN_FILE}")"

# 2.9) P0 回归：模式 2 没有 REALITY_TARGET，渲染器不得直接展开它（Bash >= 4.4 + set -u 必崩）。
assert_not_contains "xray: 不得直接展开可能未定义的 REALITY_TARGET" \
    "$(<"${MODE_LIB}")" '--arg sni "${REALITY_TARGET%%'
assert_contains "xray: 先落到带默认值的局部变量" \
    "$(<"${MODE_LIB}")" 'local reality_target=${REALITY_TARGET:-}'

# 3) Xray 只有 XHTTP 入站，没有 Reality 入站。
cdn_write_xray_config || fail_test "xray: 纯 CDN 配置渲染失败"
xray_config=$(<"${XRAY_CONFIG}")
assert_equal "xray: 只有一个入站" "1" "$(jq '.inbounds | length' <<<"${xray_config}")"
assert_equal "xray: 入站是 XHTTP" "vless-xhttp-in" "$(jq -r '.inbounds[0].tag' <<<"${xray_config}")"
assert_equal "xray: XHTTP 只监听回环" "127.0.0.1" "$(jq -r '.inbounds[0].listen' <<<"${xray_config}")"
assert_not_contains "xray: 不含 Reality 入站" "${xray_config}" "vless-reality-in"

# 4) UFW：只放行 CDN 回源端口，不放行 8443。
ufw_log="${TMP_DIR}/ufw.log"
: >"${ufw_log}"
(
    snapshot_ufw_state() { :; }
    snapshot_platform_security_state() { :; }
    ensure_ssh_boot_service() { printf 'ssh-boot\n' >>"${ufw_log}"; }
    detect_ssh_ports() { SSH_PORTS="2222"; }
    verify_ssh_ufw_no_unmanaged_block() { :; }
    configure_ufw_ip_family() { :; }
    apply_ssh_ufw_policy() { printf 'ssh-policy %s\n' "$*" >>"${ufw_log}"; }
    cloudflare_configure_origin_firewall() { printf 'cf-origin\n' >>"${ufw_log}"; }
    ensure_ssh_fail2ban() { printf 'fail2ban\n' >>"${ufw_log}"; }
    ufw() {
        case "${1:-}" in
        status) printf 'Status: active\n' ;;
        allow) printf 'allow %s\n' "${2:-}" >>"${ufw_log}" ;;
        esac
    }
    xhttp_configure_ufw
) || fail_test "ufw: 纯 CDN 防火墙配置失败"
ufw_calls=$(<"${ufw_log}")
assert_contains "ufw: 保持 SSH 开机自启" "${ufw_calls}" "ssh-boot"
assert_contains "ufw: 保持 Fail2ban" "${ufw_calls}" "fail2ban"
assert_contains "ufw: 只向 Cloudflare 回源段放行 443" "${ufw_calls}" "cf-origin"
assert_not_contains "ufw: 纯 CDN 不放行 Reality 8443" "${ufw_calls}" "allow 8443/tcp"

# 4.5) 安装交互参数校验（纯 CDN 没有直连域名，也不允许两个域名相同）。
# 注意：prompt_value 在 Profile 里通过 $(...) 调用，子进程内的数组修改不会回传，
# 因此回答队列必须落在文件里按游标推进，否则每次都拿到第一个答案、负用例会被别的原因带红。
run_cdn_inputs() {
    local -a answers=("$@")
    printf '%s\n' "${answers[@]}" >"${TMP_DIR}/cdn-inputs.txt"
    printf '0\n' >"${TMP_DIR}/cdn-inputs.cursor"
    (
        prompt_value() {
            local cursor line
            cursor=$(<"${TMP_DIR}/cdn-inputs.cursor")
            cursor=$((cursor + 1))
            printf '%s\n' "${cursor}" >"${TMP_DIR}/cdn-inputs.cursor"
            line=$(sed -n "${cursor}p" "${TMP_DIR}/cdn-inputs.txt")
            printf '%s' "${line:-$2}"
        }
        prompt_secret() { printf '%s' "cloudflare-token-abcdefghijklmnop"; }
        collect_globalping_token() { :; }
        validate_globalping_access() { return 0; }
        detect_public_ipv4() { printf '198.51.100.10'; }
        collect_install_inputs </dev/null || return 1
        printf 'RESULT|%s|%s|%s|%s\n' \
            "${CF_ZONE}" "${CF_NODE_DOMAIN}" "${SUBSCRIPTION_DOMAIN}" "${CF_NODE_PREFIX}"
    )
}
zone_out=$(run_cdn_inputs "example.com" "cf.example.org" "sub.example.com" 2>&1) || true
assert_contains "inputs: 域名不属于当前 Zone 必须被拒绝" "${zone_out}" "域名必须属于"
dup_out=$(run_cdn_inputs "example.com" "cf.example.com" "cf.example.com" 2>&1) || true
assert_contains "inputs: 两个域名相同必须被拒绝" "${dup_out}" "两个域名必须互不相同"
ok_out=$(run_cdn_inputs "example.com" "cf.example.com" "sub.example.com" "" "") || \
    fail_test "inputs: 合法输入必须通过"
assert_contains "inputs: 合法输入得到默认前缀" "${ok_out}" "RESULT|example.com|cf.example.com|sub.example.com|🇺🇸CF"

# 5) Nginx 沿用同一回源结构（没有直连 server 块）。
rendered=$(cdn_render_nginx_config $'\n    http2 on;' "")
assert_contains "nginx: 回源 server_name 是 CDN 域名" "${rendered}" "server_name ${CF_NODE_DOMAIN};"
assert_contains "nginx: 订阅 server_name 是订阅域名" "${rendered}" "server_name ${SUBSCRIPTION_DOMAIN};"
assert_not_contains "nginx: 纯 CDN 没有 8443 监听" "${rendered}" "listen 8443"

# 6) 订阅分组：无直连节点，PROXY = 聚合节点 → CDN-FALLBACK；
#    官方域名节点只作 CDN-AUTO 全灭后的兜底，不参与测速。
cdn_cf_candidates() {
    printf '198.51.100.1\t1\n198.51.100.2\t2\n198.51.100.3\t3\n'
    printf '198.51.100.4\t4\n198.51.100.5\t5\n198.51.100.6\t6\n'
}
proxy_names=$(EASY_ALL_INCLUDE_OPTIONAL=0 build_mihomo_proxy_names)
assert_not_contains "groups: 环境残留 DIRECT_NODE_NAME 不得进入 PROXY" \
    "$(DIRECT_NODE_NAME="老直连节点"; EASY_ALL_INCLUDE_OPTIONAL=0 build_mihomo_proxy_names)" \
    "老直连节点"
assert_equal "groups: 纯 CDN 的 PROXY 以 CDN-FALLBACK 结尾" \
    "$(printf '%s' '        - "CDN-FALLBACK"')" \
    "$(printf '%s\n' "${proxy_names}" | tail -n 1)"
assert_not_contains "groups: 纯 CDN 没有直连节点" "${proxy_names}" "直连"
groups=$(build_mihomo_proxy_groups)
assert_contains "groups: CDN-AUTO 是测速组" "${groups}" "type: url-test"
assert_contains "groups: CDN-FALLBACK 是兜底组" "${groups}" "type: fallback"
cdn_auto_block=$(awk '/name: CDN-AUTO/{p=1}/name: CDN-FALLBACK/{p=0}p' <<<"${groups}")
assert_contains "groups: 测速组只含优选 IP 节点" "${cdn_auto_block}" "\"${CF_NODE_PREFIX}1\""
assert_not_contains "groups: 官方域名节点不参与测速" "${cdn_auto_block}" "${CF_NODE_PREFIX}官方"
fallback_block=$(awk '/name: CDN-FALLBACK/{p=1}p' <<<"${groups}")
assert_contains "groups: 兜底组先选测速组" "${fallback_block}" "\"CDN-AUTO\""
assert_contains "groups: 兜底组最后是 CDN 域名节点" "${fallback_block}" "\"${CF_NODE_PREFIX}官方\""
fallback_auto_line=$(grep -n 'CDN-AUTO' <<<"${fallback_block}" | cut -d: -f1)
fallback_official_line=$(grep -n "${CF_NODE_PREFIX}官方" <<<"${fallback_block}" | cut -d: -f1)
((fallback_auto_line < fallback_official_line)) \
    || fail_test "groups: CDN-AUTO 必须排在官方域名节点之前"

cdn_apply_subscription_config "$(jq -c . "${ROOT_DIR}/templates/aggregation.example.json")" \
    || fail_test "groups: 聚合示例配置校验失败"
ordered_names=$(EASY_ALL_INCLUDE_OPTIONAL=0 build_mihomo_proxy_names \
    | sed -n 's/^        - "\(.*\)"$/\1/p')
expected_names=$(EASY_ALL_INCLUDE_OPTIONAL=0 aggregation_node_names | jq -r '.[]')
assert_equal "groups: PROXY 顺序为聚合节点 → CDN-FALLBACK" \
    "$(printf '%s\n%s' "${expected_names}" "CDN-FALLBACK")" \
    "${ordered_names}"
cdn_apply_subscription_config "$(jq -cn --arg t "${OWNER_TOKEN}" '{allowedTokens:{owner:$t},nodes:[]}')" \
    || fail_test "groups: restore empty aggregation failed"

# 7) 节点：6 个优选 IP + 1 个官方调度域名节点；域名节点连接橙云域名本身。
mihomo_nodes=$(EASY_ALL_INCLUDE_OPTIONAL=0 build_mihomo_nodes)
assert_contains "nodes: 域名兜底节点连接 CDN 域名" \
    "${mihomo_nodes}" "server: \"${CF_NODE_DOMAIN}\""
assert_contains "nodes: 域名兜底节点名带前缀" \
    "${mihomo_nodes}" "name: \"${CF_NODE_PREFIX}官方\""
assert_contains "nodes: 优选节点仍然存在" "${mihomo_nodes}" "server: \"198.51.100.1\""
assert_equal "nodes: 6 个优选 IP + 1 个官方域名节点" "7" "$(grep -c '^  - name: ' <<<"${mihomo_nodes}")"
links=$(EASY_ALL_INCLUDE_OPTIONAL=0 build_node_links)
assert_contains "links: 域名兜底节点可用" "${links}" "@${CF_NODE_DOMAIN}:443?"
last_ip_line=$(grep -n '@198.51.100.6:443?' <<<"${links}" | cut -d: -f1)
domain_line=$(grep -n "@${CF_NODE_DOMAIN}:443?" <<<"${links}" | cut -d: -f1)
((last_ip_line < domain_line)) \
    || fail_test "links: 域名兜底节点必须排在 6 个优选 IP 之后"
assert_not_contains "links: 纯 CDN 不含 Reality 节点" "${links}" "security=reality"

# 8) 聚合节点不得与本机 CDN 节点或兜底组重名（首装无优选缓存时也要按命名规则校验）。
local_names_no_cache=$(cdn_cf_candidates() { return 1; }; cdn_local_node_names)
assert_equal "names: 首装无缓存也生成本机节点名" "7" "$(jq 'length' <<<"${local_names_no_cache}")"
local_names=$(cdn_local_node_names)
assert_equal "names: 本机节点名 = 6 个优选 + 官方兜底" "7" "$(jq 'length' <<<"${local_names}")"
assert_contains "names: 官方兜底节点在重名黑名单里" "${local_names}" "${CF_NODE_PREFIX}官方"
if cdn_apply_subscription_config "$(jq -cn --arg name "${CF_NODE_PREFIX}官方" \
    '{allowedTokens:{owner:"cdnwq-rtbke-3182"},nodes:[{type:"vless",security:"reality",network:"tcp",name:$name,host:"r.example.com",uuid:"22222222-2222-4222-8222-222222222222",sni:"s",pbk:"p",sid:"aabbccdd"}]}') \
    2>/dev/null; then
    fail_test "names: 聚合节点不得占用官方兜底节点名"
fi
if cdn_apply_subscription_config "$(jq -cn \
    '{allowedTokens:{owner:"cdnwq-rtbke-3182"},nodes:[{type:"vless",security:"reality",network:"tcp",name:"CDN-FALLBACK",host:"r.example.com",uuid:"22222222-2222-4222-8222-222222222222",sni:"s",pbk:"p",sid:"aabbccdd"}]}') \
    2>/dev/null; then
    fail_test "names: 聚合节点不得占用 CDN-FALLBACK 组名"
fi
cdn_apply_subscription_config "${SUBSCRIPTION_CONFIG}" || fail_test "names: restore config"

# 8.5) 真实订阅产物：YAML 带兜底组与域名节点，Base64 也能拿到域名节点。
SUBSCRIPTION_OPTIONAL_VARIANTS=0 write_subscriptions || fail_test "subscription: 纯 CDN 订阅渲染失败"
rendered_yaml=$(<"${SUBSCRIPTION_DIR}/mihomo.yaml")
assert_contains "subscription: YAML 含 CDN-FALLBACK 组" "${rendered_yaml}" "name: CDN-FALLBACK"
assert_contains "subscription: YAML 含官方域名节点" \
    "${rendered_yaml}" "name: \"${CF_NODE_PREFIX}官方\""
assert_contains "subscription: YAML 兜底节点连接 CDN 域名" \
    "${rendered_yaml}" "server: \"${CF_NODE_DOMAIN}\""
rendered_links=$(openssl base64 -d -A <"${SUBSCRIPTION_DIR}/base64.txt" 2>/dev/null || true)
assert_contains "subscription: Base64 也能拿到域名节点" \
    "${rendered_links}" "@${CF_NODE_DOMAIN}:443?"

# 8.6) 本机订阅验收：真实渲染产物能通过，缺 CDN-FALLBACK 时必须报错。
fake_curl() {
    local arg has_output=0 has_clash=0
    for arg in "$@"; do
        [[ "${arg}" == "-o" ]] && has_output=1
        [[ "${arg}" == "flag=clash" ]] && has_clash=1
    done
    if ((has_output)); then
        printf '403'
    elif ((has_clash)); then
        command cat "${FAKE_MIHOMO_FILE}"
    else
        command cat "${SUBSCRIPTION_DIR}/base64.txt"
    fi
}
(
    cloudflare_ensure_origin_ca_root() { :; }
    FAKE_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
    curl() { fake_curl "$@"; }
    validate_subscription_runtime
) || fail_test "subscription: 真实渲染产物必须通过本机订阅验收"
grep -v 'CDN-FALLBACK' "${SUBSCRIPTION_DIR}/mihomo.yaml" \
    >"${TMP_DIR}/mihomo-no-fallback.yaml"
if (
    cloudflare_ensure_origin_ca_root() { :; }
    FAKE_MIHOMO_FILE="${TMP_DIR}/mihomo-no-fallback.yaml"
    curl() { fake_curl "$@"; }
    validate_subscription_runtime
) >/dev/null 2>&1; then
    fail_test "subscription: 缺少 CDN-FALLBACK 的订阅必须验收失败"
fi

# 8.7) 验收必须按分组块结构校验，不能被聚合节点名里的同名子串掩盖。
awk '
    $0 == "    - name: CDN-FALLBACK" { inside = 1; next }
    inside && (/^[[:space:]]*- name: / || /^[^[:space:]]/) { inside = 0 }
    !inside { print }
' "${SUBSCRIPTION_DIR}/mihomo.yaml" \
    | awk '
        index($0, "官方") && /name: "/ {
            sub(/name: ".*"/, "name: \"name: CDN-FALLBACK\"")
        }
        { print }
    ' >"${TMP_DIR}/mihomo-masked.yaml"
grep -Fq 'name: CDN-FALLBACK' "${TMP_DIR}/mihomo-masked.yaml" \
    || fail_test "subscription: 构造的掩盖样本必须仍然包含该子串"
if (
    cloudflare_ensure_origin_ca_root() { :; }
    FAKE_MIHOMO_FILE="${TMP_DIR}/mihomo-masked.yaml"
    curl() { fake_curl "$@"; }
    validate_subscription_runtime
) >/dev/null 2>&1; then
    fail_test "subscription: 仅节点名命中同名子串时仍须验收失败"
fi

# 8.8) 节点名允许引号/反斜杠：渲染器用 @json 转义，验收不得把合法订阅判成缺组。
(
    CF_NODE_PREFIX='A"B\\C'
    write_subscriptions
    cloudflare_ensure_origin_ca_root() { :; }
    FAKE_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
    curl() { fake_curl "$@"; }
    validate_subscription_runtime
) || fail_test "subscription: 含引号/反斜杠的节点名必须通过验收"
# 恢复常规节点名产物，避免影响后续用例。
write_subscriptions || fail_test "subscription: 恢复常规订阅产物失败"

# 9) 卸载清理只覆盖 CDN 节点与订阅两个域名（没有直连域名）。
purge_log="${TMP_DIR}/purge.log"
: >"${purge_log}"
(
    cloudflare_record_list() {
        printf '[{"id":"rec-%s","comment":"easy_all cdn"}]\n' "$3"
    }
    cloudflare_api_request() { printf '%s %s\n' "$1" "$2" >>"${purge_log}"; }
    CLOUDFLARE_ZONE_ID="zone-123456"
    purge_cdn_dns
) || fail_test "purge: cdn DNS purge failed"
assert_equal "purge: 只删除 CDN 节点与订阅记录" \
    "$(printf 'DELETE /zones/zone-123456/dns_records/rec-cf-node.example.com\nDELETE /zones/zone-123456/dns_records/rec-sub.example.com')" \
    "$(<"${purge_log}")"

# 10) status 文案区分纯 CDN，且不输出直连入口。
status_out=$(
    show_tcp_acceleration_status() { :; }
    show_globalping_status() { :; }
    systemctl() { return 0; }
    show_status
) || fail_test "status: 纯 CDN 状态输出失败"
assert_contains "status: 标注纯 CDN 协议" "${status_out}" "协议: Cloudflare XHTTP（纯 CDN）"
assert_not_contains "status: 不输出直连入口" "${status_out}" "直连入口"
assert_contains "status: 输出 Cloudflare 域名" "${status_out}" "${CF_NODE_DOMAIN}"

# 11) uninstall --purge-cloud：云端 API 失败只能告警，本机卸载与防火墙回收必须继续。
uninstall_log="${TMP_DIR}/uninstall.log"
: >"${uninstall_log}"
uninstall_out=$(
    require_root() { :; }
    stop_maintenance_services() { :; }
    acquire_runtime_write_lock() { :; }
    stop_services() { printf 'stopped\n' >>"${uninstall_log}"; }
    remove_globalping_refresh_timer() { :; }
    cloudflare_remove_origin_firewall_rules() { :; }
    restore_platform_security_state() { :; }
    restore_preinstall_firewall() { printf 'firewall-restored\n' >>"${uninstall_log}"; }
    restore_preinstall_ipv6() { :; }
    restore_preinstall_nginx_default_site() { :; }
    remove_daily_reboot_schedule() { :; }
    systemctl() { :; }
    cloudflare_collect_api_token() { :; }
    cloudflare_lookup_parent_zone() { die "注入 Zone 查询失败"; }
    # 测试不得触网：任何 API 调用都视为缺陷（Zone 查询失败后不应再访问云端）。
    cloudflare_api_request() { printf 'api-call\n' >>"${TMP_DIR}/uninstall-api.log"; }
    cloudflare_record_list() { printf '[]'; }
    cloudflare_clear_api_token() { :; }
    FORCE=1
    uninstall_all --purge-cloud 2>&1
) || fail_test "uninstall: 云端清理失败不得让卸载失败"
[[ ! -s "${TMP_DIR}/uninstall-api.log" ]] \
    || fail_test "uninstall: Zone 查询失败后不得继续访问 Cloudflare API"
assert_contains "uninstall: 云端失败给出告警与补救命令" \
    "${uninstall_out}" "Cloudflare 资源清理未完成"
assert_contains "uninstall: 云端失败后本机服务仍被停止" "$(<"${uninstall_log}")" "stopped"
assert_contains "uninstall: 云端失败后 UFW/安全状态仍被回收" "$(<"${uninstall_log}")" "firewall-restored"
[[ ! -e "${STATE_DIR}" ]] || fail_test "uninstall: 本机状态目录必须删除"

printf 'ok - cdn-only render\n'
