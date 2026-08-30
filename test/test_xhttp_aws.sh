#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/xhttp-aws.sh"
XHTTP_RUNTIME="${ROOT_DIR}/lib/xhttp-runtime.sh"
PLATFORM_MODULE="${ROOT_DIR}/lib/platform.sh"
SCHEDULED_MAINTENANCE_MODULE="${ROOT_DIR}/lib/scheduled-maintenance.sh"
SUBSCRIPTION_MODULE="${ROOT_DIR}/lib/subscription-auth.sh"
XHTTP_CONTENT="$(<"${PROFILE}")"$'\n'"$(<"${XHTTP_RUNTIME}")"$'\n'"$(<"${SUBSCRIPTION_MODULE}")"
XRAY_RENDER_CONTENT=$(sed -n '/^xhttp_render_xray_config()/,/^}/p' "${PROFILE}")
MIHOMO_RENDER_CONTENT=$(sed -n '/^build_mihomo_node()/,/^}/p' "${XHTTP_RUNTIME}")
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected [${expected}], got [${actual}]"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing [${expected}]"
}

assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected [${unexpected}]"
}

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}"/lib/*.sh
assert_contains "installer refuses root credentials" "${XHTTP_CONTENT}" \
    "拒绝使用 AWS 根用户访问密钥"
route53_notice_line=$(grep -n '仅提示，非错误：源站域名与 CDN 域名都必须位于 AWS Route 53 Public Hosted Zone。' "${PROFILE}" \
    | head -n1 | cut -d: -f1)
origin_domain_prompt_line=$(grep -n 'AWS Route 53 源站域名' "${PROFILE}" \
    | head -n1 | cut -d: -f1)
[[ -n "${route53_notice_line}" && -n "${origin_domain_prompt_line}" \
    && "${route53_notice_line}" -lt "${origin_domain_prompt_line}" ]] \
    || fail "Route 53 hosted-zone notice must appear before domain input"
assert_contains "Xray XHTTP inbound" "${XHTTP_CONTENT}" \
    'tag:"vless-xhttp-h2-in"'
assert_contains "Xray fixes XHTTP to stream-up" "${XHTTP_CONTENT}" \
    'mode:"stream-up"'
assert_contains "traffic accounting exposes Stats API only on loopback" "${XHTTP_CONTENT}" \
    'api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]}'
assert_contains "XHTTP state persists the quota start date" "${XHTTP_CONTENT}" \
    'QUOTA_START_DATE=%q'
assert_contains "XHTTP state persists the configurable client family" "${XHTTP_CONTENT}" \
    'CDN_CLIENT_IP_FAMILY=%q'
assert_contains "CloudFront uses the shared XHTTP outbound policy" \
    "${XRAY_RENDER_CONTENT}" 'xray_xhttp_outbounds_json'
assert_contains "CloudFront uses the shared XHTTP routing policy" \
    "${XRAY_RENDER_CONTENT}" 'xray_xhttp_routing_json'
assert_contains "CloudFront Xray inbound uses shared TCP keepalive" \
    "${XRAY_RENDER_CONTENT}" 'xray_inbound_sockopt_json'
assert_not_contains "CloudFront Xray egress does not depend on the client family" \
    "${XRAY_RENDER_CONTENT}" "CDN_CLIENT_IP_FAMILY"
assert_contains "Xray keepalive stays below CloudFront response timeout" "${XHTTP_CONTENT}" \
    'readonly XHTTP_STREAM_UP_SERVER_SECS="20-40"'
assert_not_contains "XHTTP client output omits client-side padding settings" "${XHTTP_CONTENT}" \
    'XHTTP_X_PADDING_BYTES'
assert_contains "Xray accepts the server-side keepalive marker padding" "${XHTTP_CONTENT}" \
    'xPaddingBytes:$x_padding_bytes'
assert_contains "Nginx guarantees that Xray activates stream-up keepalive" "${XHTTP_CONTENT}" \
    'grpc_set_header Referer "${keepalive_referer}"'
assert_contains "Nginx stream timeout covers long-lived XHTTP requests" "${XHTTP_CONTENT}" \
    'readonly XHTTP_NGINX_STREAM_TIMEOUT="1h"'
assert_contains "Nginx proxies XHTTP over gRPC" "${XHTTP_CONTENT}" \
    'grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT}'
assert_contains "Nginx validates subscription tokens" "${XHTTP_CONTENT}" \
    'map $arg_token $easy_all_subscription_allowed'
assert_contains "Nginx protects direct-origin subscription access" "${XHTTP_CONTENT}" \
    'if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }'
assert_contains "Nginx serves internal Mihomo subscription" "${XHTTP_CONTENT}" \
    'mihomo_alias="${SUBSCRIPTION_MIHOMO_FILE}"'
assert_contains "installer validates sshd before scheduled reboot" "$(<"${PLATFORM_MODULE}")" \
    '"${sshd_bin}" -t'
assert_contains "installer adds the shared SSH port" "$(<"${PLATFORM_MODULE}")" \
    'readonly EASY_ALL_ADDITIONAL_SSH_PORT="65533"'
assert_contains "installer keeps detected SSH ports" "$(<"${PLATFORM_MODULE}")" \
    'for port in ${SSH_PORTS}'
assert_contains "installer verifies the new SSH listener" "$(<"${PLATFORM_MODULE}")" \
    'ssh_managed_port_is_listening "${EASY_ALL_ADDITIONAL_SSH_PORT}"'
assert_contains "AWS and Gcore installs include Fail2ban" "${XHTTP_CONTENT}" \
    'fail2ban python3-systemd'
assert_contains "AWS and Gcore enable shared Fail2ban after UFW" "${XHTTP_CONTENT}" \
    'ensure_ssh_fail2ban'
assert_contains "shared Fail2ban enables incremental bans" "$(<"${PLATFORM_MODULE}")" \
    'bantime.increment = true'
assert_contains "installer enables SSH at boot" "$(<"${PLATFORM_MODULE}")" \
    'systemctl enable --now "${unit}"'
assert_contains "installer verifies SSH boot enablement" "$(<"${PLATFORM_MODULE}")" \
    'systemctl is-enabled --quiet "${unit}"'
assert_contains "installer verifies ACME renewal cron" "$(<"${SCHEDULED_MAINTENANCE_MODULE}")" \
    'die "未找到 acme.sh 自动续期定时任务"'
assert_contains "XHTTP repairs a missing ACME renewal cron job" "$(<"${SCHEDULED_MAINTENANCE_MODULE}")" \
    'run_acme --install-cronjob'
assert_contains "XHTTP writes a managed cron fallback when acme.sh does not" "$(<"${SCHEDULED_MAINTENANCE_MODULE}")" \
    "easy_all-acme-renewal"
assert_contains "installer verifies renewal reload hook" "${XHTTP_CONTENT}" \
    '源站证书、私钥或续期重载钩子安装不完整'
assert_contains "subscription updates enable rollback" "${XHTTP_CONTENT}" \
    'UPDATE_SUB_ROLLBACK_ON_EXIT=1'
assert_contains "CloudFront health failures are fatal" "${XHTTP_CONTENT}" \
    'die "CloudFront ${label}域名 ${domain} 公网验收失败'
assert_contains "CloudFront alias conflicts require explicit resource cleanup" \
    "${XHTTP_CONTENT}" '脚本不会接管该资源，请先删除该分配或解除别名'
assert_contains "CloudFront billing mode is persisted" "${XHTTP_CONTENT}" \
    'AWS_CLOUDFRONT_BILLING_MODE=%q'
assert_contains "AWS CDN endpoint mode is persisted" "${XHTTP_CONTENT}" \
    'AWS_CDN_ENDPOINT_MODE=%q'
assert_contains "CloudFront fee protection threshold is persisted" "${XHTTP_CONTENT}" \
    'CDN_TRAFFIC_PROTECTION_GB=%q'
assert_contains "global fee protection can remove every Xray client" "${XHTTP_CONTENT}" \
    "cdn_traffic_protection_blocked && clients='[]'"
assert_contains "pay-as-you-go clears WAF association" "${XHTTP_CONTENT}" \
    'AWS_WAF_WEB_ACL_ARN=""'
assert_contains "non-interactive uninstall requires FORCE" "${XHTTP_CONTENT}" \
    '非交互卸载必须显式设置 FORCE=1'
assert_contains "AWS purge option deletes ACM before local cleanup" "${XHTTP_CONTENT}" \
    'purge_aws_certificate_before_uninstall'

(
    # shellcheck source=/dev/null
    source "${PROFILE}"

    assert_equal "unified state" "/etc/easy_all" "${STATE_DIR}"
    unset CDN_CLIENT_IP_FAMILY
    CDN_CLIENT_IP_FAMILY_RESOLVED=""
    configure_cdn_client_ip_family
    assert_equal "CDN client family defaults to IPv6 preference" \
        "ipv6-prefer" "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
    if (
        CDN_CLIENT_IP_FAMILY="auto"
        configure_cdn_client_ip_family
    ) >/dev/null 2>&1; then
        fail "non-current CDN client family must be rejected"
    fi
    if (
        CDN_CLIENT_IP_FAMILY="invalid"
        configure_cdn_client_ip_family
    ) >/dev/null 2>&1; then
        fail "unsupported CDN client family must be rejected"
    fi
    unset CDN_CLIENT_IP_FAMILY
    assert_equal "unified service" "easy_all-xray.service" "${XRAY_SERVICE}"
    assert_equal "unified nginx config" "/etc/nginx/conf.d/easy_all.conf" "${NGINX_CONFIG}"
    assert_equal "schema" "7" "${STATE_SCHEMA_VERSION}"
    assert_equal "AWS control region" "us-east-1" "${AWS_CONTROL_REGION}"
    assert_equal "default CloudFront billing mode" "payg" \
        "${DEFAULT_AWS_CLOUDFRONT_BILLING_MODE}"
    validate_cloudfront_billing_mode flat-free \
        || fail "flat-free CloudFront billing mode must be valid"
    validate_cloudfront_billing_mode payg \
        || fail "payg CloudFront billing mode must be valid"
    if validate_cloudfront_billing_mode invalid; then
        fail "unknown CloudFront billing modes must be rejected"
    fi
    AWS_CLOUDFRONT_BILLING_MODE=1
    choose_cloudfront_billing_mode
    assert_equal "CloudFront billing choice 1 selects flat-free" "flat-free" \
        "${AWS_CLOUDFRONT_BILLING_MODE}"
    assert_equal "flat-free mode disables global fee protection" "0" \
        "${CDN_TRAFFIC_PROTECTION_GB}"
    AWS_CLOUDFRONT_BILLING_MODE=2
    choose_cloudfront_billing_mode
    assert_equal "CloudFront billing choice 2 selects pay-as-you-go" "payg" \
        "${AWS_CLOUDFRONT_BILLING_MODE}"
    assert_equal "pay-as-you-go enables the 980 GB global fee protection" "980" \
        "${CDN_TRAFFIC_PROTECTION_GB}"
    assert_equal "caching disabled policy" \
        "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" "${CLOUDFRONT_CACHE_POLICY_ID}"
    assert_equal "all viewer except host policy" \
        "b689b0a8-53d0-40ab-baf2-68738e2966ac" "${CLOUDFRONT_ORIGIN_REQUEST_POLICY_ID}"
    assert_equal "stream-up server keepalive" "20-40" "${XHTTP_STREAM_UP_SERVER_SECS}"
    assert_equal "server keepalive padding range" "100-1000" \
        "${XHTTP_SERVER_PADDING_BYTES}"
    assert_equal "server keepalive marker length" "100" \
        "${XHTTP_SERVER_KEEPALIVE_PADDING_LENGTH}"
    assert_equal "Nginx XHTTP stream timeout" "1h" "${XHTTP_NGINX_STREAM_TIMEOUT}"
    assert_equal "XMUX maximum connections" "2" "${XHTTP_XMUX_MAX_CONNECTIONS}"
    assert_equal "XMUX connection reuse times" "0" "${XHTTP_XMUX_C_MAX_REUSE_TIMES}"
    assert_equal "XMUX request reuse range" "300-600" "${XHTTP_XMUX_H_MAX_REQUEST_TIMES}"
    assert_equal "XMUX connection lifetime range" "900-1800" \
        "${XHTTP_XMUX_H_MAX_REUSABLE_SECS}"
    assert_equal "XMUX keepalive period" "0" "${XHTTP_XMUX_H_KEEP_ALIVE_PERIOD}"
    assert_equal "CloudFront origin response timeout" "120" "${CLOUDFRONT_ORIGIN_READ_TIMEOUT}"
    assert_equal "CloudFront origin keepalive timeout" "120" \
        "${CLOUDFRONT_ORIGIN_KEEPALIVE_TIMEOUT}"

    (
        EASY_ALL_SSH_PORT_CONFIG="${TMP_DIR}/sshd_config.d/00-easy-all-ports.conf"
        reload_marker="${TMP_DIR}/ssh-reloaded"
        reload_count="${TMP_DIR}/ssh-reload-count"
        printf '0\n' >"${reload_count}"
        sshd() {
            case "${1:-}" in
            -t) return 0 ;;
            -T)
                printf 'addressfamily any\n'
                if [[ -f "${EASY_ALL_SSH_PORT_CONFIG}" ]]; then
                    awk '
                        $1 == "Port" {print "port " $2}
                        $1 == "ListenAddress" {print "listenaddress " $2}
                    ' "${EASY_ALL_SSH_PORT_CONFIG}"
                else
                    printf 'port 22\nlistenaddress 0.0.0.0:22\n'
                fi
                ;;
            *) return 1 ;;
            esac
        }
        ss() {
            if [[ -f "${reload_marker}" && "$*" == *':65533'* ]]; then
                printf 'LISTEN 0 128 0.0.0.0:65533 0.0.0.0:* users:(("sshd",pid=10,fd=3))\n'
            fi
        }
        systemctl() {
            if [[ "${1:-}" == "reload" ]]; then
                printf '%s\n' "$(( $(<"${reload_count}") + 1 ))" >"${reload_count}"
                : >"${reload_marker}"
            fi
            return 0
        }
        ensure_additional_ssh_port sshd ssh.service
        assert_contains "shared SSH config retains port 22" \
            "$(<"${EASY_ALL_SSH_PORT_CONFIG}")" "Port 22"
        assert_contains "shared SSH config adds port 65533" \
            "$(<"${EASY_ALL_SSH_PORT_CONFIG}")" "Port 65533"
        assert_contains "shared SSH config binds the new IPv4 listener" \
            "$(<"${EASY_ALL_SSH_PORT_CONFIG}")" "ListenAddress 0.0.0.0:65533"
        ensure_additional_ssh_port sshd ssh.service
        assert_equal "shared SSH configuration is idempotent" "1" "$(<"${reload_count}")"
    )

    (
        EASY_ALL_FAIL2BAN_CONFIG="${TMP_DIR}/fail2ban/jail.d/99-easy-all-sshd.local"
        EASY_ALL_FAIL2BAN_ACTION_CONFIG="${TMP_DIR}/fail2ban/action.d/easy-all-ufw-cidr.conf"
        EASY_ALL_FAIL2BAN_CIDR_HELPER="${TMP_DIR}/fail2ban/bin/fail2ban-ufw-cidr.sh"
        EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${TMP_DIR}/fail2ban/state"
        fail2ban_active="${TMP_DIR}/fail2ban-active"
        restart_count="${TMP_DIR}/fail2ban-restart-count"
        status_attempt_count="${TMP_DIR}/fail2ban-status-attempt-count"
        install -d -m 0755 "$(dirname -- "${EASY_ALL_FAIL2BAN_CONFIG}")"
        printf '0\n' >"${restart_count}"
        printf '0\n' >"${status_attempt_count}"
        install_fail2ban_dependencies() { return 0; }
        detect_ssh_ports() { SSH_PORTS="22 65533"; }
        ufw() { return 0; }
        fail2ban-client() {
            local attempts
            [[ "${1:-}" == "-t" ]] && return 0
            if [[ "${1:-} ${2:-}" == "status sshd" ]]; then
                attempts=$(( $(<"${status_attempt_count}") + 1 ))
                printf '%s\n' "${attempts}" >"${status_attempt_count}"
                [[ "${attempts}" -ge 3 ]]
                return
            fi
            return 1
        }
        systemctl() {
            case "${1:-}" in
            enable) return 0 ;;
            restart)
                printf '%s\n' "$(( $(<"${restart_count}") + 1 ))" >"${restart_count}"
                : >"${fail2ban_active}"
                ;;
            is-enabled | is-active) [[ -f "${fail2ban_active}" ]] ;;
            *) return 1 ;;
            esac
        }
        ensure_ssh_fail2ban
        assert_equal "shared Fail2ban waits for the sshd jail after restart" \
            "3" "$(<"${status_attempt_count}")"
        assert_contains "shared Fail2ban monitors both SSH ports" \
            "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")" "port = 22,65533"
        assert_contains "shared Fail2ban uses the CIDR-aware UFW action" \
            "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")" "banaction = easy-all-ufw-cidr"
        assert_contains "shared Fail2ban action delegates IPv4 CIDR bans to its helper" \
            "$(<"${EASY_ALL_FAIL2BAN_ACTION_CONFIG}")" "ban <ip> ${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}"
        [[ -x "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" ]] \
            || fail "shared Fail2ban CIDR helper is not executable"
        assert_contains "shared Fail2ban uses the requested retry window" \
            "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")" "findtime = 3m"
        assert_contains "shared Fail2ban starts at a three-hour ban" \
            "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")" "bantime = 3h"
        assert_contains "shared Fail2ban enables incremental bans" \
            "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")" "bantime.increment = true"
        assert_contains "shared Fail2ban caps bans at one week" \
            "$(<"${EASY_ALL_FAIL2BAN_CONFIG}")" "bantime.maxtime = 1w"
        ensure_ssh_fail2ban
        assert_equal "shared Fail2ban configuration is idempotent" \
            "1" "$(<"${restart_count}")"

        fake_ufw="${TMP_DIR}/fake-ufw"
        fake_ufw_log="${TMP_DIR}/fake-ufw.log"
        printf '%s\n' '#!/usr/bin/env bash' \
            'printf "%s\\n" "$*" >>"${EASY_ALL_TEST_UFW_LOG:?}"' >"${fake_ufw}"
        chmod 0755 "${fake_ufw}"
        : >"${fake_ufw_log}"
        EASY_ALL_TEST_UFW_LOG="${fake_ufw_log}" \
            EASY_ALL_FAIL2BAN_UFW_BIN="${fake_ufw}" \
            "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" ban 198.51.100.19 "${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}"
        EASY_ALL_TEST_UFW_LOG="${fake_ufw_log}" \
            EASY_ALL_FAIL2BAN_UFW_BIN="${fake_ufw}" \
            "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" ban 198.51.100.77 "${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}"
        EASY_ALL_TEST_UFW_LOG="${fake_ufw_log}" \
            EASY_ALL_FAIL2BAN_UFW_BIN="${fake_ufw}" \
            "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" unban 198.51.100.19 "${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}"
        assert_equal "shared Fail2ban manages IPv4 addresses independently" \
            $'insert 1 deny from 198.51.100.19/32 to any comment easy_all-fail2ban-cidr\ninsert 1 deny from 198.51.100.77/32 to any comment easy_all-fail2ban-cidr\n--force delete deny from 198.51.100.19/32 to any' \
            "$(<"${fake_ufw_log}")"
        EASY_ALL_TEST_UFW_LOG="${fake_ufw_log}" \
            EASY_ALL_FAIL2BAN_UFW_BIN="${fake_ufw}" \
            "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" unban 198.51.100.77 "${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}"
        assert_equal "shared Fail2ban removes only the matching IPv4 address" \
            $'insert 1 deny from 198.51.100.19/32 to any comment easy_all-fail2ban-cidr\ninsert 1 deny from 198.51.100.77/32 to any comment easy_all-fail2ban-cidr\n--force delete deny from 198.51.100.19/32 to any\n--force delete deny from 198.51.100.77/32 to any' \
            "$(<"${fake_ufw_log}")"
        EASY_ALL_TEST_UFW_LOG="${fake_ufw_log}" \
            EASY_ALL_FAIL2BAN_UFW_BIN="${fake_ufw}" \
            "${EASY_ALL_FAIL2BAN_CIDR_HELPER}" ban 2001:db8::1 "${EASY_ALL_FAIL2BAN_CIDR_STATE_DIR}"
        assert_contains "shared Fail2ban retains exact-address IPv6 bans" \
            "$(<"${fake_ufw_log}")" "insert 1 deny from 2001:db8::1 to any"
    )

    fail2ban_rollback_config="${TMP_DIR}/fail2ban-rollback/99-easy-all-sshd.local"
    install -d -m 0755 "$(dirname -- "${fail2ban_rollback_config}")"
    printf 'previous-config\n' >"${fail2ban_rollback_config}"
    if (
        EASY_ALL_FAIL2BAN_CONFIG="${fail2ban_rollback_config}"
        EASY_ALL_FAIL2BAN_ACTION_CONFIG="${TMP_DIR}/fail2ban-rollback/action.d/easy-all-ufw-cidr.conf"
        EASY_ALL_FAIL2BAN_CIDR_HELPER="${TMP_DIR}/fail2ban-rollback/bin/fail2ban-ufw-cidr.sh"
        EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${TMP_DIR}/fail2ban-rollback/state"
        install_fail2ban_dependencies() { return 0; }
        detect_ssh_ports() { SSH_PORTS="22 65533"; }
        ufw() { return 0; }
        fail2ban-client() { return 1; }
        systemctl() { return 1; }
        ensure_ssh_fail2ban
    ) >/dev/null 2>&1; then
        fail "shared Fail2ban accepted an invalid generated configuration"
    fi
    assert_equal "shared Fail2ban validation failure restores the previous config" \
        "previous-config" "$(<"${fail2ban_rollback_config}")"

    ufw_state="${TMP_DIR}/xhttp-ufw-state"
    cat >"${ufw_state}" <<'EOF'
22/tcp|ALLOW IN|Anywhere|easy_all-managed
8443/tcp|ALLOW IN|Anywhere|easy_all-managed
80/tcp|ALLOW IN|Anywhere|debian-init-managed
9999/tcp|ALLOW IN|Anywhere|user-rule
EOF
    ufw() {
        local endpoint number temp="${ufw_state}.new"
        if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
            printf 'Status: active\n'
            awk -F'|' '{printf "[ %d] %s %s %s # %s\n", NR, $1, $2, $3, $4}' "${ufw_state}"
            return 0
        fi
        if [[ "${1:-}" == "allow" ]]; then
            endpoint=$2
            if awk -F'|' -v endpoint="${endpoint}" \
                '$1 == endpoint && $2 == "ALLOW IN" {found=1} END {exit(found ? 0 : 1)}' \
                "${ufw_state}"; then
                return 0
            fi
            printf '%s|ALLOW IN|Anywhere|%s\n' "${endpoint}" "${4:-}" >>"${ufw_state}"
            return 0
        fi
        if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
            number=$3
            awk -v number="${number}" 'NR != number' "${ufw_state}" >"${temp}"
            mv "${temp}" "${ufw_state}"
            return 0
        fi
        [[ "${1:-}" == "--force" && "${2:-}" == "enable" ]] && return 0
        [[ "${1:-}" == "reload" ]] && return 0
        return 1
    }
    apply_managed_ufw_tcp_ports "22 80 443"
    apply_managed_ufw_tcp_ports "22 80 443"
    ufw_state_text=$(<"${ufw_state}")
    xhttp_ssh_count=$(awk -F'|' '$1 == "22/tcp" && $2 == "ALLOW IN" {count++} END {print count+0}' "${ufw_state}")
    assert_equal "XHTTP UFW reapply keeps exactly one SSH allow rule" "1" "${xhttp_ssh_count}"
    assert_contains "XHTTP UFW reapply keeps the existing managed SSH rule" \
        "${ufw_state_text}" "22/tcp|ALLOW IN|Anywhere|easy_all-managed"
    assert_contains "XHTTP UFW accepts an existing external HTTP allow rule" \
        "${ufw_state_text}" "80/tcp|ALLOW IN|Anywhere|debian-init-managed"
    assert_contains "XHTTP UFW adds a missing HTTPS rule" \
        "${ufw_state_text}" "443/tcp|ALLOW IN|Anywhere|easy_all-managed"
    assert_not_contains "XHTTP UFW removes only a stale managed rule" \
        "${ufw_state_text}" "8443/tcp|ALLOW IN|Anywhere|easy_all-managed"
    assert_contains "XHTTP UFW preserves unrelated user rules" \
        "${ufw_state_text}" "9999/tcp|ALLOW IN|Anywhere|user-rule"
    unset -f ufw

    assert_contains "XHTTP prompts for the Mihomo download filename" \
        "${XHTTP_CONTENT}" 'Mihomo 下载文件名（不含 .yaml）'
    assert_contains "XHTTP default prompts explain the enter default" \
        "$(<"${ROOT_DIR}/lib/profile-common.sh")" \
        '[${default}]（直接回车使用默认值）'
    assert_contains "XHTTP subscription prompt recommends self-hosting for one server" \
        "${XHTTP_CONTENT}" "只有当前服务器时推荐"
    assert_contains "XHTTP subscription prompt recommends node output for aggregation" \
        "${XHTTP_CONTENT}" "多节点聚合或已有订阅服务器时推荐"

    SUB_DOWNLOAD_NAME="CUSTOM_SUB.yaml"
    choose_subscription_download_name
    assert_equal "XHTTP normalizes a custom download filename" \
        "CUSTOM_SUB" "${SUB_DOWNLOAD_NAME}"
    SUB_DOWNLOAD_NAME=""

    CDN_PROVIDER="aws"
    VLESS_CDN_DOMAIN="node.example.com"
    AWS_ORIGIN_DOMAIN="origin.example.com"
    SUBSCRIPTION_DOMAIN="Subscribe.Example.Com."
    collect_subscription_link_domain
    assert_equal "XHTTP normalizes the complete subscription hostname" \
        "subscribe.example.com" "${SUBSCRIPTION_DOMAIN}"
    unset SUBSCRIPTION_DOMAIN

    SUBSCRIPTION_MODE="1"
    choose_subscription_mode
    assert_equal "subscription choice 1 deploys the service" "deploy" "${SUBSCRIPTION_MODE}"
    SUBSCRIPTION_MODE="2"
    choose_subscription_mode
    assert_equal "subscription choice 2 outputs links only" "link" "${SUBSCRIPTION_MODE}"
    SUBSCRIPTION_MODE="link"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    assert_equal "update-sub keeps the current link mode by default" \
        "link" "${SUBSCRIPTION_MODE}"
    PROMPT_SUBSCRIPTION_MODE=0

    dig() {
        case "$*" in
            *"@1.1.1.1"*) return 0 ;;
            *"@8.8.8.8"*) printf '%s\n' '198.51.100.10' ;;
        esac
    }
    AWS_ORIGIN_DOMAIN="origin.example.com"
    VPS_PUBLIC_IPV4="198.51.100.10"
    verify_origin_dns

    (
        crontab() {
            printf '17 2 * * * "%s" --cron --home "%s"\n' "${ACME_BIN}" "${ACME_HOME}"
        }
        systemctl() { return 0; }
        verify_acme_renewal_setup
    )
    if (
        crontab() { printf '17 2 * * * /usr/local/bin/unrelated-job\n'; }
        systemctl() { return 0; }
        verify_acme_renewal_setup
    ) >/dev/null 2>&1; then
        fail "ACME renewal verification must reject a missing cron entry"
    fi

    (
        source_state_file() {
            STATE_VERSION="7"
            PROTOCOL="xhttp"
            CDN_PROVIDER="aws"
            AWS_CDN_ENDPOINT_MODE="domain"
            AWS_CLOUDFRONT_BILLING_MODE="flat-free"
            VLESS_UUID="00000000-0000-4000-8000-000000000001"
            VLESS_CDN_DOMAIN="node.example.com"
            XHTTP_NODE_NAME="STORED_XHTTP"
            XHTTP_PATH="/xhttp-stored-suffix"
            AWS_ORIGIN_DOMAIN="origin.example.com"
            XRAY_XHTTP_LOOPBACK_PORT="10086"
            SUB_DOWNLOAD_NAME="EASY_ALL"
            SUBSCRIPTION_MODE="link"
            SUBSCRIPTION_DOMAIN="node.example.com"
            QUOTA_ENABLED="0"
        }
        VLESS_UUID="00000000-0000-4000-8000-000000000002"
        XHTTP_NODE_NAME="UPDATED_XHTTP"
        XHTTP_PATH="/xhttp-updated-suffix"
        AWS_CDN_ENDPOINT_MODE=""
        load_state
        assert_equal "AWS domain state uses IPv6 preference" "ipv6-prefer" \
            "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
        assert_equal "UUID environment override wins during update" \
            "00000000-0000-4000-8000-000000000002" "${VLESS_UUID}"
        assert_equal "node name environment override wins during update" \
            "UPDATED_XHTTP" "${XHTTP_NODE_NAME}"
        assert_equal "XHTTP path environment override wins during update" \
            "/xhttp-updated-suffix" "${XHTTP_PATH}"
    )
    (
        source_state_file() {
            STATE_VERSION="7"
            PROTOCOL="xhttp"
            CDN_PROVIDER="aws"
            AWS_CDN_ENDPOINT_MODE="optimized"
            AWS_CLOUDFRONT_BILLING_MODE="flat-free"
            CDN_CLIENT_IP_FAMILY="ipv6-prefer"
            VLESS_UUID="00000000-0000-4000-8000-000000000001"
            VLESS_CDN_DOMAIN="node.example.com"
            XHTTP_NODE_NAME="STORED_XHTTP"
            XHTTP_PATH="/xhttp-stored-suffix"
            AWS_ORIGIN_DOMAIN="origin.example.com"
            XRAY_XHTTP_LOOPBACK_PORT="10086"
            SUB_DOWNLOAD_NAME="EASY_ALL"
            SUBSCRIPTION_MODE="link"
            SUBSCRIPTION_DOMAIN="node.example.com"
            QUOTA_ENABLED="0"
        }
        load_state
        assert_equal "optimized AWS state forces IPv4 candidates" "ipv4" \
            "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
    )
    zones='{"HostedZones":[{"Id":"/hostedzone/ZBASE","Name":"example.com.","Config":{"PrivateZone":false}},{"Id":"/hostedzone/ZPRIVATE","Name":"node.example.com.","Config":{"PrivateZone":true}},{"Id":"/hostedzone/ZBOUNDARY","Name":"notexample.com.","Config":{"PrivateZone":false}}]}'
    assert_equal "Route 53 public parent zone" $'/hostedzone/ZBASE\texample.com.' \
        "$(find_route53_zone_for_domain node.example.com "${zones}")"
    assert_equal "Route 53 boundary-safe matching" $'/hostedzone/ZBOUNDARY\tnotexample.com.' \
        "$(find_route53_zone_for_domain node.notexample.com "${zones}")"

    if (
        AWS_ORIGIN_DOMAIN="origin.example.com"
        VLESS_CDN_DOMAIN="node.example.com"
        SUBSCRIPTION_MODE="deploy"
        SUBSCRIPTION_DOMAIN="subscribe.other.net"
        aws() {
            printf '%s\n' '{"HostedZones":[{"Id":"/hostedzone/ZBASE","Name":"example.com.","Config":{"PrivateZone":false}}]}'
        }
        find_route53_zones
    ) >/dev/null 2>&1; then
        fail "AWS custom subscription domains must be hosted by Route 53"
    fi

    (
        AWS_ORIGIN_DOMAIN="origin.example.com"
        VLESS_CDN_DOMAIN="node.example.com"
        SUBSCRIPTION_MODE="deploy"
        SUBSCRIPTION_DOMAIN="subscribe.other.net"
        aws() {
            printf '%s\n' '{"HostedZones":[
              {"Id":"/hostedzone/ZBASE","Name":"example.com.","Config":{"PrivateZone":false}},
              {"Id":"/hostedzone/ZSUB","Name":"other.net.","Config":{"PrivateZone":false}}
            ]}'
        }
        find_route53_zones
        assert_equal "AWS accepts a subscription domain in another Route 53 public zone" \
            "ZSUB" "${AWS_SUBSCRIPTION_ROUTE53_ZONE_ID}"
    )

    VLESS_CDN_DOMAIN="node.example.com"
    CDN_CLIENT_IP_FAMILY="ipv4"
    CDN_CLIENT_IP_FAMILY_RESOLVED=""
    certificates='{"CertificateSummaryList":[
      {"CertificateArn":"arn:pending-exact","DomainName":"node.example.com","Status":"PENDING_VALIDATION"},
      {"CertificateArn":"arn:issued-wildcard","DomainName":"*.example.com","Status":"ISSUED"},
      {"CertificateArn":"arn:unrelated","DomainName":"other.example.net","Status":"ISSUED"},
      {"CertificateArn":"arn:issued-san","DomainName":"service.example.net","Status":"ISSUED",
       "SubjectAlternativeNameSummaries":["san.example.org"]}
    ]}'
    assert_equal "ACM reuse prefers an issued covering certificate" "arn:issued-wildcard" \
        "$(select_reusable_acm_certificate "${certificates}")"
    VLESS_CDN_DOMAIN="deep.node.example.com"
    assert_equal "ACM wildcard reuse is limited to one label" "" \
        "$(select_reusable_acm_certificate "${certificates}")"
    VLESS_CDN_DOMAIN="san.example.org"
    assert_equal "ACM reuse considers certificate SANs" "arn:issued-san" \
        "$(select_reusable_acm_certificate "${certificates}")"

    VLESS_CDN_DOMAIN="node.example.com"
    SUBSCRIPTION_MODE="deploy"
    SUBSCRIPTION_DOMAIN="subscribe.other.net"
    dual_domain_certificates='{"CertificateSummaryList":[
      {"CertificateArn":"arn:node-only","DomainName":"node.example.com","Status":"ISSUED"},
      {"CertificateArn":"arn:node-and-subscription","DomainName":"node.example.com","Status":"ISSUED",
       "SubjectAlternativeNameSummaries":["subscribe.other.net"]}
    ]}'
    assert_equal "ACM reuse requires one certificate to cover both CDN aliases" \
        "arn:node-and-subscription" \
        "$(select_reusable_acm_certificate "${dual_domain_certificates}")"
    unset SUBSCRIPTION_DOMAIN

    VLESS_CDN_DOMAIN="node.example.com"
    aws() {
        printf '%s\n' '{"DistributionList":{"Items":[
          {"Id":"EASYALL123","Comment":"easy_all:xhttp:node.example.com"},
          {"Id":"OTHER123","Comment":"unrelated"}
        ]}}'
    }
    assert_equal "reinstall discovers the managed CloudFront distribution" "EASYALL123" \
        "$(find_managed_distribution)"
    aws() {
        printf '%s\n' '{"DistributionList":{"Items":[
          {"Id":"EASYALL123","Comment":"easy_all:xhttp:node.example.com"},
          {"Id":"EASYALL456","Comment":"easy_all:xhttp:node.example.com"}
        ]}}'
    }
    if (find_managed_distribution) >/dev/null 2>&1; then
        fail "duplicate managed CloudFront distributions must be rejected"
    fi
    unset -f aws

    AWS_ACCOUNT_ID="111122223333"
    AWS_ACCOUNT_PLAN_UPGRADE=1
    account_plan_counter_file="${TMP_DIR}/account-plan-counter"
    printf '0\n' >"${account_plan_counter_file}"
    aws() {
        local count
        if [[ "$*" == *"freetier get-account-plan-state"* ]]; then
            count=$(<"${account_plan_counter_file}")
            count=$((count + 1))
            printf '%s\n' "${count}" >"${account_plan_counter_file}"
            if ((count == 1)); then
                printf '%s\n' '{"accountPlanType":"FREE","accountPlanStatus":"ACTIVE"}'
            else
                printf '%s\n' '{"accountPlanType":"PAID","accountPlanStatus":"ACTIVE"}'
            fi
        elif [[ "$*" == *"freetier upgrade-account-plan"* ]]; then
            printf '%s\n' '{"accountPlanType":"PAID","accountPlanStatus":"ACTIVE"}'
        else
            return 1
        fi
    }
    paid_upgrade_output=$(ensure_aws_paid_account_plan)
    assert_contains "Free AWS accounts are upgraded through the API" \
        "${paid_upgrade_output}" "已升级为 Paid"
    unset -f aws
    unset AWS_ACCOUNT_PLAN_UPGRADE

    PROTOCOL="xhttp"
    XHTTP_NODE_NAME="EASY_ALL_XHTTP_TEST"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    VLESS_CDN_DOMAIN="node.example.com"
    AWS_ORIGIN_DOMAIN="origin.example.com"
    AWS_CDN_ENDPOINT_MODE="domain"
    CDN_CLIENT_IP_FAMILY="ipv6-prefer"
    XHTTP_PATH="/xhttp-test-path"
    XRAY_XHTTP_LOOPBACK_PORT="10086"
    ORIGIN_HEADER_SECRET="test-origin-header-secret"
    AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:111122223333:certificate/test"
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    AWS_WAF_WEB_ACL_ARN="arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test"
    ALLOWED_TOKENS='{"owner":"owner-token-123"}'
    SUB_DOWNLOAD_NAME="EASY_ALL_TEST"

    keepalive_referer=$(xhttp_server_keepalive_referer)
    keepalive_padding=${keepalive_referer##*x_padding=}
    assert_equal "server keepalive Referer path" \
        "https://node.example.com/xhttp-test-path/?x_padding=${keepalive_padding}" \
        "${keepalive_referer}"
    assert_equal "server keepalive padding has the configured length" "100" \
        "${#keepalive_padding}"
    assert_equal "server keepalive padding contains only valid marker bytes" \
        "${keepalive_padding}" "${keepalive_padding//[^X]/}"

    link=$(build_node_link)
    assert_contains "VLESS scheme" "${link}" "vless://"
    assert_contains "CloudFront hostname" "${link}" "@node.example.com:443"
    assert_contains "XHTTP transport" "${link}" "type=xhttp"
    assert_contains "XHTTP stream-up" "${link}" "mode=stream-up"
    assert_contains "XHTTP path keeps the Nginx location suffix" "${link}" "path=%2Fxhttp-test-path%2F"
    assert_contains "XHTTP XMUX extra" "${link}" "extra="
    assert_contains "XHTTP link uses the supported uplink method key" "${link}" "uplinkHTTPMethod"
    assert_not_contains "XHTTP link omits the unsupported uplink key" "${link}" "uplinkMethod"
    encoded_extra=$(sed -n 's/.*[?&]extra=\([^&]*\).*/\1/p' <<<"${link}")
    extra_json=$(printf '%b' "${encoded_extra//%/\\x}")
    jq -e '
        .noGRPCHeader == false and
        (has("xPaddingBytes") | not) and
        (has("xPaddingObfsMode") | not) and
        .uplinkHTTPMethod == "POST" and
        .xmux == {
            maxConnections: 2,
            cMaxReuseTimes: 0,
            hMaxRequestTimes: "300-600",
            hMaxReusableSecs: "900-1800",
            hKeepAlivePeriod: 0
        }
    ' <<<"${extra_json}" >/dev/null || fail "XHTTP URI extra is invalid"
    assert_not_contains "XHTTP XMUX omits incompatible max concurrency" \
        "${link}" "maxConcurrency"
    [[ "${link}" != *"trojan"* ]] || fail "links must contain only VLESS"
    assert_equal "exactly one link" "1" "$(wc -l <<<"${link}" | tr -d ' ')"

    mihomo=$(build_mihomo_node)
    assert_contains "Mihomo XHTTP" "${mihomo}" "network: xhttp"
    assert_contains "Mihomo stream-up" "${mihomo}" "mode: stream-up"
    assert_contains "Mihomo XHTTP path keeps the Nginx location suffix" \
        "${mihomo}" 'path: "/xhttp-test-path/"'
    assert_contains "Mihomo XMUX" "${mihomo}" "reuse-settings:"
    assert_contains "Mihomo XHTTP prefers IPv6" \
        "${mihomo}" "ip-version: ipv6-prefer"
    assert_contains "Mihomo XMUX limits connections" \
        "${mihomo}" 'max-connections: "2"'
    assert_contains "Mihomo XMUX rotates request counts" \
        "${mihomo}" 'h-max-request-times: "300-600"'
    assert_contains "Mihomo XMUX rotates connection lifetime" \
        "${mihomo}" 'h-max-reusable-secs: "900-1800"'
    assert_not_contains "Mihomo omits client-side padding settings" \
        "${mihomo}" 'x-padding-'
    assert_not_contains "Mihomo XMUX omits incompatible max concurrency" \
        "${mihomo}" "max-concurrency"
    assert_contains "Mihomo XMUX uses browser-like keepalive" "${mihomo}" "h-keep-alive-period: 0"

    (
        AWS_CDN_ENDPOINT_MODE="optimized"
        CDN_CLIENT_IP_FAMILY="ipv6-prefer"
        CDN_CLIENT_IP_FAMILY_RESOLVED=""
        globalping_cache_valid() { return 0; }
        aws_cdn_client_endpoints() {
            printf '%s\n' 203.0.113.10 198.51.100.20
        }

        optimized_links=$(build_node_links)
        assert_equal "optimized mode emits one URI per selected IP" "2" \
            "$(grep -c '^vless://' <<<"${optimized_links}" | tr -d ' ')"
        assert_contains "optimized URI connects to the selected IP" \
            "${optimized_links}" '@203.0.113.10:443'
        assert_contains "optimized URI keeps the CloudFront SNI" \
            "${optimized_links}" 'sni=node.example.com'
        assert_contains "optimized URI keeps the CloudFront XHTTP host" \
            "${optimized_links}" 'host=node.example.com'

        optimized_nodes=$(build_mihomo_nodes)
        assert_equal "optimized mode emits one Mihomo node per selected IP" "2" \
            "$(grep -Fc 'network: xhttp' <<<"${optimized_nodes}" | tr -d ' ')"
        assert_contains "optimized Mihomo node connects to IPv4" \
            "${optimized_nodes}" 'server: "203.0.113.10"'
        assert_contains "optimized Mihomo node keeps CloudFront SNI" \
            "${optimized_nodes}" 'servername: "node.example.com"'
        assert_contains "optimized Mihomo node keeps CloudFront host" \
            "${optimized_nodes}" 'host: "node.example.com"'
        assert_contains "optimized Mihomo node is IPv4-only" \
            "${optimized_nodes}" 'ip-version: ipv4'

        optimized_groups=$(build_mihomo_proxy_groups)
        optimized_names=$(build_mihomo_proxy_names)
        assert_contains "optimized group performs automatic client testing" \
            "${optimized_groups}" 'type: url-test'
        assert_contains "optimized group tests every five minutes" \
            "${optimized_groups}" 'interval: 300'
        assert_contains "PROXY selects the optimized group" \
            "${optimized_names}" 'EASY_ALL_XHTTP_TEST_AUTO'

        optimized_node_file="${TMP_DIR}/mihomo-optimized-nodes.yaml"
        optimized_group_file="${TMP_DIR}/mihomo-optimized-groups.yaml"
        optimized_name_file="${TMP_DIR}/mihomo-optimized-names.yaml"
        optimized_mihomo_file="${TMP_DIR}/mihomo-optimized.yaml"
        printf '%s\n' "${optimized_nodes}" >"${optimized_node_file}"
        printf '%s\n' "${optimized_groups}" >"${optimized_group_file}"
        printf '%s\n' "${optimized_names}" >"${optimized_name_file}"
        render_mihomo_subscription "${ROOT_DIR}/templates/mihomo.yaml" \
            "${optimized_node_file}" "${optimized_mihomo_file}" \
            "${XHTTP_NODE_NAME}" ipv4 "${optimized_group_file}" \
            "${optimized_name_file}"
        assert_equal "rendered optimized subscription contains tenable candidates" "2" \
            "$(grep -Fc 'network: xhttp' "${optimized_mihomo_file}" | tr -d ' ')"
        assert_contains "rendered optimized subscription contains url-test group" \
            "$(<"${optimized_mihomo_file}")" 'type: url-test'
    )

    distribution="${TMP_DIR}/distribution.json"
    build_distribution_config "${distribution}" "test-caller-reference"
    jq -e '
        .CallerReference == "test-caller-reference" and
        .Aliases.Items == ["node.example.com"] and
        .DefaultRootObject == "" and
        .Origins.Items[0].DomainName == "origin.example.com" and
        .Origins.Items[0].CustomOriginConfig.OriginProtocolPolicy == "https-only" and
        .Origins.Items[0].CustomOriginConfig.OriginSslProtocols.Items == ["TLSv1.2"] and
        .Origins.Items[0].CustomOriginConfig.OriginReadTimeout == 120 and
        .Origins.Items[0].CustomOriginConfig.OriginKeepaliveTimeout == 120 and
        (.Origins.Items[0] | has("ResponseCompletionTimeout") | not) and
        .Origins.Items[0].ConnectionAttempts == 2 and
        .Origins.Items[0].ConnectionTimeout == 3 and
        .Origins.Items[0].CustomHeaders.Items[0].HeaderName == "X-Easy-All-Origin-Key" and
        .DefaultCacheBehavior.ViewerProtocolPolicy == "https-only" and
        .DefaultCacheBehavior.CachePolicyId == "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" and
        .DefaultCacheBehavior.OriginRequestPolicyId == "b689b0a8-53d0-40ab-baf2-68738e2966ac" and
        (.DefaultCacheBehavior.AllowedMethods.Items | sort) == (["GET","HEAD","OPTIONS","PUT","POST","PATCH","DELETE"] | sort) and
        .DefaultCacheBehavior.GrpcConfig.Enabled == true and
        .HttpVersion == "http2" and
        .IsIPV6Enabled == true and
        .ViewerCertificate.ACMCertificateArn == "arn:aws:acm:us-east-1:111122223333:certificate/test" and
        .WebACLId == "arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test" and
        .Comment == "easy_all:xhttp:node.example.com"
    ' "${distribution}" >/dev/null || fail "CloudFront distribution config is invalid"

    SUBSCRIPTION_MODE="deploy"
    SUBSCRIPTION_DOMAIN="subscribe.example.net"
    subscription_distribution="${TMP_DIR}/distribution-subscription-domain.json"
    build_distribution_config "${subscription_distribution}" "subscription-caller-reference"
    jq -e '
        .Aliases.Quantity == 2 and
        .Aliases.Items == ["node.example.com","subscribe.example.net"]
    ' "${subscription_distribution}" >/dev/null \
        || fail "CloudFront distribution must include the custom subscription alias"
    unset SUBSCRIPTION_DOMAIN

    payg_distribution="${TMP_DIR}/distribution-payg.json"
    AWS_CLOUDFRONT_BILLING_MODE="payg"
    AWS_WAF_WEB_ACL_ARN=""
    build_distribution_config "${payg_distribution}" "payg-caller-reference"
    jq -e '.CallerReference == "payg-caller-reference" and .WebACLId == ""' \
        "${payg_distribution}" >/dev/null \
        || fail "pay-as-you-go CloudFront config must not attach WAF"
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    AWS_WAF_WEB_ACL_ARN="arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test"

    origin_change="${TMP_DIR}/origin-a-create.json"
    build_origin_a_change_batch "${origin_change}" '[]' '203.0.113.10'
    jq -e '
        .Changes|length == 1 and
        .[0].Action == "CREATE" and
        .[0].ResourceRecordSet.Name == "origin.example.com." and
        .[0].ResourceRecordSet.Type == "A" and
        .[0].ResourceRecordSet.ResourceRecords == [{"Value":"203.0.113.10"}]
    ' "${origin_change}" >/dev/null || fail "Route 53 origin A create batch is invalid"

    origin_replace="${TMP_DIR}/origin-a-replace.json"
    origin_conflicts='[{"Name":"origin.example.com.","Type":"A","TTL":300,"ResourceRecords":[{"Value":"198.51.100.8"}]},{"Name":"origin.example.com.","Type":"AAAA","TTL":300,"ResourceRecords":[{"Value":"2001:db8::8"}]}]'
    build_origin_a_change_batch "${origin_replace}" "${origin_conflicts}" '203.0.113.10'
    jq -e '
        .Changes|length == 3 and
        .[0].Action == "DELETE" and .[0].ResourceRecordSet.Type == "A" and
        .[1].Action == "DELETE" and .[1].ResourceRecordSet.Type == "AAAA" and
        .[2].Action == "CREATE" and .[2].ResourceRecordSet.Type == "A" and
        .[2].ResourceRecordSet.ResourceRecords == [{"Value":"203.0.113.10"}]
    ' "${origin_replace}" >/dev/null || fail "Route 53 origin A replacement batch is invalid"

    viewer_alias="${TMP_DIR}/viewer-alias.json"
    build_viewer_alias_change_batch "${viewer_alias}" '[]' \
        "d111111abcdef8.cloudfront.net."
    jq -e '
        .Changes|length == 2 and
        .[0].Action == "CREATE" and .[0].ResourceRecordSet.Type == "A" and
        .[0].ResourceRecordSet.AliasTarget.HostedZoneId == "Z2FDTNDATAQYW2" and
        .[0].ResourceRecordSet.AliasTarget.DNSName == "d111111abcdef8.cloudfront.net." and
        .[1].Action == "CREATE" and .[1].ResourceRecordSet.Type == "AAAA"
    ' "${viewer_alias}" >/dev/null || fail "Route 53 viewer Alias creation batch is invalid"
    build_viewer_alias_change_batch "${viewer_alias}" '[]' \
        "d111111abcdef8.cloudfront.net." "subscribe.example.net"
    jq -e '
        (.Changes|length) == 2 and
        all(.Changes[]; .ResourceRecordSet.Name == "subscribe.example.net.")
    ' "${viewer_alias}" >/dev/null \
        || fail "Route 53 subscription aliases must use the requested complete hostname"
    exact_cloudfront_cname='[{"Name":"subscribe.example.net.","Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":"d111111abcdef8.cloudfront.net."}]}]'
    viewer_records_are_cname_target "${exact_cloudfront_cname}" \
        "d111111abcdef8.cloudfront.net." \
        || fail "an exact existing CloudFront CNAME must be reusable"
    if (
        AWS_DNS_REPLACE=1
        aws() {
            if [[ "$*" == *"list-resource-record-sets"* ]]; then
                printf '%s\n' '{"ResourceRecordSets":[{"Name":"subscribe.example.net.","Type":"CNAME","TTL":300,"ResourceRecords":[{"Value":"other.example.net."}]}]}'
                return 0
            fi
            fail "a conflicting custom subscription record must never be mutated"
        }
        ensure_viewer_domain_record "subscribe.example.net" "ZSUB" "订阅" \
            "d111111abcdef8.cloudfront.net." 0
    ) >/dev/null 2>&1; then
        fail "AWS custom subscription DNS conflicts must be rejected even with replacement enabled"
    fi
    managed_dual_alias='[
      {"Name":"node.example.com.","Type":"A","AliasTarget":{"HostedZoneId":"Z2FDTNDATAQYW2","DNSName":"d111111abcdef8.cloudfront.net.","EvaluateTargetHealth":false}},
      {"Name":"node.example.com.","Type":"AAAA","AliasTarget":{"HostedZoneId":"Z2FDTNDATAQYW2","DNSName":"d111111abcdef8.cloudfront.net.","EvaluateTargetHealth":false}}
    ]'
    viewer_records_are_alias_target "${managed_dual_alias}" \
        "d111111abcdef8.cloudfront.net." dual \
        || fail "managed A/AAAA aliases must satisfy the dual-stack target"
    if viewer_records_are_alias_target "${managed_dual_alias}" \
        "d111111abcdef8.cloudfront.net." ipv4; then
        fail "managed A/AAAA aliases must not satisfy an IPv4-only target"
    fi
    build_viewer_alias_change_batch "${viewer_alias}" "${managed_dual_alias}" \
        "d111111abcdef8.cloudfront.net."
    jq -e '
        .Changes|length == 4 and
        .[0].Action == "DELETE" and .[0].ResourceRecordSet.Type == "A" and
        .[1].Action == "DELETE" and .[1].ResourceRecordSet.Type == "AAAA" and
        .[2].Action == "CREATE" and .[2].ResourceRecordSet.Type == "A" and
        .[3].Action == "CREATE" and .[3].ResourceRecordSet.Type == "AAAA"
    ' "${viewer_alias}" >/dev/null \
        || fail "Route 53 A/AAAA aliases are not rebuilt as dual stack"

    subscriptions='{"subscriptionSummaries":[
      {"arn":"arn:plan:other","planTier":"FREE","resourceArns":["arn:distribution:other"]},
      {"arn":"arn:plan:easy-all","planTier":"FREE","resourceArns":["arn:distribution:easy-all","arn:waf:easy-all"]}
    ]}'
    assert_equal "pricing plan selection is scoped to the CloudFront distribution" \
        '[{"arn":"arn:plan:easy-all","planTier":"FREE","resourceArns":["arn:distribution:easy-all","arn:waf:easy-all"]}]' \
        "$(select_cloudfront_pricing_subscription "${subscriptions}" "arn:distribution:easy-all")"

    AWS_ACCOUNT_ID="111122223333"
    AWS_CLOUDFRONT_DISTRIBUTION_ID="EASYALL123"
    AWS_CLOUDFRONT_DISTRIBUTION_ARN="arn:aws:cloudfront::111122223333:distribution/EASYALL123"
    AWS_WAF_WEB_ACL_ARN="arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test"
    AWS_ROUTE53_ZONE_ID="ZVIEWER123"
    AWS_CLOUDFRONT_PRICING_PLAN_ARN=""
    pricing_calls="${TMP_DIR}/pricing-plan-calls"
    : >"${pricing_calls}"
    aws() {
        printf '%s\n' "$*" >>"${pricing_calls}"
        case "$*" in
        *"pricing-plan-manager list-subscriptions"*)
            printf '%s\n' '{"subscriptionSummaries":[]}'
            ;;
        *"pricing-plan-manager create-subscription"*)
            printf '%s\n' '{"subscription":{"arn":"arn:aws:pricingplanmanager:us-east-1:111122223333:subscription/easy-all","status":"SYNC_IN_PROGRESS"},"eTag":"v1"}'
            ;;
        *"pricing-plan-manager get-subscription"*)
            printf '%s\n' '{"subscription":{"arn":"arn:aws:pricingplanmanager:us-east-1:111122223333:subscription/easy-all","planTier":"FREE","status":"ACTIVE","resourceArns":["arn:aws:cloudfront::111122223333:distribution/EASYALL123","arn:aws:wafv2:us-east-1:111122223333:global/webacl/easy-all/test","arn:aws:route53:::hostedzone/ZVIEWER123"]},"eTag":"v2"}'
            ;;
        *) return 1 ;;
        esac
    }
    ensure_cloudfront_free_pricing_plan >/dev/null
    pricing_call_text=$(<"${pricing_calls}")
    assert_contains "pricing plan creation is hard-coded to the FREE tier" \
        "${pricing_call_text}" "--plan-tier FREE"
    assert_contains "pricing plan creation includes the viewer Route 53 zone" \
        "${pricing_call_text}" "arn:aws:route53:::hostedzone/ZVIEWER123"
    assert_not_contains "pricing plan automation never approves a paid subscription" \
        "${pricing_call_text}" "approve-paid-subscription"
    unset -f aws

    AWS_CLOUDFRONT_BILLING_MODE="payg"
    AWS_CLOUDFRONT_PRICING_PLAN_ARN="stale-value"
    payg_calls="${TMP_DIR}/payg-calls"
    : >"${payg_calls}"
    aws() {
        printf '%s\n' "$*" >>"${payg_calls}"
        [[ "$*" == *"pricing-plan-manager list-subscriptions"* ]] || return 1
        printf '%s\n' '{"subscriptionSummaries":[]}'
    }
    ensure_cloudfront_payg_mode >/dev/null
    assert_equal "pay-as-you-go mode clears pricing plan state" "" \
        "${AWS_CLOUDFRONT_PRICING_PLAN_ARN}"
    assert_not_contains "pay-as-you-go mode never creates a fixed plan" \
        "$(<"${payg_calls}")" "create-subscription"
    aws() {
        [[ "$*" == *"pricing-plan-manager list-subscriptions"* ]] || return 1
        printf '%s\n' '{"subscriptionSummaries":[{"arn":"arn:plan:existing","planTier":"FREE","resourceArns":["arn:aws:cloudfront::111122223333:distribution/EASYALL123"]}]}'
    }
    if (ensure_cloudfront_payg_mode) >/dev/null 2>&1; then
        fail "pay-as-you-go mode must reject a distribution with a fixed plan"
    fi
    unset -f aws

    AWS_ORIGIN_ROUTE53_ZONE_ID="ZSAME"
    AWS_ROUTE53_ZONE_ID="ZSAME"
    payg_estimate=$(show_cloudfront_billing_estimate)
    assert_contains "pay-as-you-go estimate includes one hosted zone" \
        "${payg_estimate}" '1 个 Hosted Zone：固定费用估算 $0.50/月'
    assert_contains "pay-as-you-go estimate includes DNS query pricing" \
        "${payg_estimate}" '每 100 万次约 $0.40'
    AWS_CLOUDFRONT_BILLING_MODE="flat-free"
    AWS_ORIGIN_ROUTE53_ZONE_ID="ZORIGIN"
    AWS_ROUTE53_ZONE_ID="ZVIEWER"
    flat_estimate=$(show_cloudfront_billing_estimate)
    assert_contains "flat-free estimate has no overage charge" \
        "${flat_estimate}" '超出费用仍为 $0'
    assert_contains "flat-free estimate prices a separate origin hosted zone" \
        "${flat_estimate}" '源站 Zone 另估 $0.50/月'

    payg_flow=$(
        AWS_CLOUDFRONT_BILLING_MODE="payg"
        AWS_WAF_WEB_ACL_ARN="stale-waf"
        install_aws_cli() { printf 'cli\n'; }
        collect_aws_credentials() { printf 'credentials\n'; }
        find_route53_zones() { printf 'zones\n'; }
        show_cloudfront_billing_estimate() { printf 'estimate\n'; }
        find_or_request_acm_certificate() { printf 'acm\n'; }
        ensure_aws_paid_account_plan() { printf 'paid\n'; }
        ensure_cloudfront_web_acl() { printf 'waf\n'; }
        configure_cloudfront_distribution() {
            printf 'cloudfront:%s\n' "${AWS_WAF_WEB_ACL_ARN:-empty}"
        }
        ensure_viewer_alias_records() { printf 'alias\n'; }
        wait_for_cloudfront() { printf 'wait\n'; }
        ensure_cloudfront_free_pricing_plan() { printf 'flat-plan\n'; }
        ensure_cloudfront_payg_mode() { printf 'payg\n'; }
        validate_cloudfront_health() { printf 'health\n'; }
        clear_aws_credentials() { printf 'clear\n'; }
        configure_aws_cdn
    )
    assert_equal "pay-as-you-go cloud flow omits WAF and fixed plan" \
        $'cli\ncredentials\nzones\nestimate\nacm\npaid\ncloudfront:empty\nalias\nwait\npayg\nhealth\nclear' \
        "${payg_flow}"

    flat_flow=$(
        AWS_CLOUDFRONT_BILLING_MODE="flat-free"
        install_aws_cli() { :; }
        collect_aws_credentials() { :; }
        find_route53_zones() { :; }
        show_cloudfront_billing_estimate() { :; }
        find_or_request_acm_certificate() { :; }
        ensure_aws_paid_account_plan() { :; }
        ensure_cloudfront_web_acl() { printf 'waf\n'; AWS_WAF_WEB_ACL_ARN='flat-waf'; }
        configure_cloudfront_distribution() { printf 'cloudfront:%s\n' "${AWS_WAF_WEB_ACL_ARN}"; }
        ensure_viewer_alias_records() { :; }
        wait_for_cloudfront() { :; }
        ensure_cloudfront_free_pricing_plan() { printf 'flat-plan\n'; }
        ensure_cloudfront_payg_mode() { printf 'payg\n'; }
        validate_cloudfront_health() { :; }
        clear_aws_credentials() { :; }
        configure_aws_cdn
    )
    assert_equal "flat-free cloud flow creates WAF and Free plan" \
        $'waf\ncloudfront:flat-waf\nflat-plan' "${flat_flow}"

    template="${ROOT_DIR}/templates/mihomo.yaml"
    node_file="${TMP_DIR}/mihomo-node.yaml"
    mihomo_file="${TMP_DIR}/subscription.yaml"
    validate_mihomo_template "${template}"
    build_mihomo_node >"${node_file}"
    render_mihomo_subscription "${template}" "${node_file}" "${mihomo_file}" \
        "${XHTTP_NODE_NAME}" "${CDN_CLIENT_IP_FAMILY_RESOLVED}"
    assert_equal "one rendered VLESS node" "1" \
        "$(grep -Fc 'type: vless' "${mihomo_file}" | tr -d ' ')"
    assert_equal "one rendered XHTTP node" "1" \
        "$(grep -Fc 'network: xhttp' "${mihomo_file}" | tr -d ' ')"
    assert_contains "Mihomo subscription CDN domain" "$(<"${mihomo_file}")" "node.example.com"
    assert_contains "Mihomo subscription node name" "$(<"${mihomo_file}")" "EASY_ALL_XHTTP_TEST"
    assert_contains "Mihomo subscription XFLASH rules" \
        "$(<"${mihomo_file}")" "DOMAIN,love.xflash.work,DIRECT"
    assert_contains "Mihomo subscription XFLASH application rules" \
        "$(<"${mihomo_file}")" "RULE-SET,applications,DIRECT"
    assert_contains "Mihomo subscription XMUX" "$(<"${mihomo_file}")" "h-keep-alive-period: 0"
    assert_not_contains "Mihomo subscription does not override SSH port 22 routing" \
        "$(<"${mihomo_file}")" "DST-PORT,22,"
    assert_not_contains "Mihomo subscription does not override SSH port 65533 routing" \
        "$(<"${mihomo_file}")" "DST-PORT,65533,"
    assert_contains "IPv4 CDN endpoint keeps the Mihomo IPv6 master switch enabled" \
        "$(<"${mihomo_file}")" $'\nipv6: true\n'
    assert_contains "CDN Mihomo TUN bypasses CGNAT and overlay LAN addresses" \
        "$(<"${mihomo_file}")" "100.64.0.0/10"

    encoded=$(printf '%s' "$(build_node_link)" | openssl base64 -A)
    decoded=$(printf '%s' "${encoded}" | openssl base64 -d -A)
    assert_contains "base64 subscription VLESS" "${decoded}" "vless://"
    assert_contains "base64 subscription XHTTP" "${decoded}" "type=xhttp"
    assert_contains "base64 subscription XMUX" "${decoded}" "extra="

    token_map=$(write_subscription_token_map)
    assert_equal "Nginx token map contains only token values" \
        '    "owner-token-123" 1;' "${token_map}"

    QUOTA_ENABLED=1
    USER_ACCOUNTS='{"owner":{"token":"owner-token-123","uuid":"00000000-0000-4000-8000-000000000001","quota_gb":0},"friend":{"token":"friend-token-123","uuid":"00000000-0000-4000-8000-000000000002","quota_gb":100}}'
    quota_token_map=$(write_subscription_token_map)
    assert_contains "quota token map selects the owner subscription directory" \
        "${quota_token_map}" '"owner-token-123" "owner";'
    assert_contains "quota token map selects the friend subscription directory" \
        "${quota_token_map}" '"friend-token-123" "friend";'
    SUBSCRIPTION_MODE="deploy"
    quota_locations=$(write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}")
    assert_contains "quota subscription uses a token-selected base64 file" \
        "${quota_locations}" '$easy_all_subscription_allowed/base64.txt'
    assert_contains "XHTTP subscription route requires the CDN origin key" \
        "${quota_locations}" '$http_x_easy_all_origin_key'
    assert_contains "Mihomo download keeps the configured filename without an extension" \
        "${quota_locations}" 'Content-Disposition "attachment; filename=EASY_ALL_TEST"'
    assert_not_contains "Mihomo download does not append yaml to the filename" \
        "${quota_locations}" 'filename=EASY_ALL_TEST.yaml'
    QUOTA_ENABLED=0
    USER_ACCOUNTS=""

    SUBSCRIPTION_MODE="link"
    link_nginx=$(
        write_subscription_nginx_maps
        write_subscription_nginx_locations
    )
    assert_equal "link-only mode omits subscription Nginx routes" "" "${link_nginx}"
    SUBSCRIPTION_MODE="deploy"

    validation_requests="${TMP_DIR}/subscription-validation-requests"
    : >"${validation_requests}"
    curl() {
        printf '%s\n' "$*" >>"${validation_requests}"
        case "$*" in
        *"token=invalid"*) printf '403' ;;
        *"flag=clash"*) printf 'network: xhttp\n' ;;
        *) printf 'base64-content\n' ;;
        esac
    }
    validate_subscription_runtime
    assert_contains "XHTTP validates that an invalid token returns 403" \
        "$(<"${validation_requests}")" "token=invalid"
    assert_contains "XHTTP token validation includes the CDN origin key" \
        "$(<"${validation_requests}")" "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}"
    if (
        curl() { printf '200'; }
        validate_subscription_token_rejection \
            "${AWS_ORIGIN_DOMAIN}:443:127.0.0.1" \
            "https://${AWS_ORIGIN_DOMAIN}/subscribe" \
            -H "X-Easy-All-Origin-Key: ${ORIGIN_HEADER_SECRET}"
    ) >/dev/null 2>&1; then
        fail "XHTTP acceptance must reject a 200 response for an invalid token"
    fi
    unset -f curl

    SUBSCRIPTION_DOMAIN="subscribe.example.net"
    subscription_output=$(
        collect_installed_state() { :; }
        show_node() { :; }
        show_subscription
    )
    assert_contains "XHTTP subscription output labels the owner" \
        "${subscription_output}" "通用订阅 (owner):"
    assert_contains "XHTTP subscription output uses the selected complete hostname" \
        "${subscription_output}" "https://subscribe.example.net/subscribe?token=owner-token-123"
    unset SUBSCRIPTION_DOMAIN

    local_apply_calls=$(
        require_root() { printf 'root\n'; }
        begin_quota_maintenance() { :; }
        end_quota_maintenance() { :; }
        collect_installed_state() { printf 'state\n'; }
        snapshot_subscription_update() {
            printf 'snapshot\n'
            UPDATE_SUB_ROLLBACK_ON_EXIT=1
        }
        configure_bbr_tcp() { printf 'bbr\n'; }
        configure_ufw() { printf 'ufw\n'; }
        prepare_aws_origin_dns() { printf 'dns\n'; }
        configure_aws_cdn() { printf 'cdn\n'; }
        refresh_runtime() { printf 'runtime\n'; }
        write_subscriptions() { printf 'subscriptions\n'; }
        validate_subscription_runtime() { printf 'validate-subscription\n'; }
        save_state() { printf 'save\n'; }
        register_easy_all_command() { printf 'register\n'; }
        show_subscription() { printf 'show\n'; }
        success() { :; }
        apply_easy_all
    )
    assert_equal "default XHTTP apply stays local" \
        $'root\nstate\nsnapshot\nbbr\nufw\nruntime\nsubscriptions\nvalidate-subscription\nsave\nregister\nshow' "${local_apply_calls}"

    cloud_apply_calls=$(
        require_root() { printf 'root\n'; }
        begin_quota_maintenance() { :; }
        end_quota_maintenance() { :; }
        collect_installed_state() { printf 'state\n'; }
        snapshot_subscription_update() {
            printf 'snapshot\n'
            UPDATE_SUB_ROLLBACK_ON_EXIT=1
        }
        configure_bbr_tcp() { printf 'bbr\n'; }
        configure_ufw() { printf 'ufw\n'; }
        prepare_aws_origin_dns() { printf 'dns\n'; }
        configure_aws_cdn() { printf 'cdn\n'; }
        refresh_runtime() { printf 'runtime\n'; }
        write_subscriptions() { printf 'subscriptions\n'; }
        validate_subscription_runtime() { printf 'validate-subscription\n'; }
        save_state() { printf 'save\n'; }
        register_easy_all_command() { printf 'register\n'; }
        show_subscription() { printf 'show\n'; }
        success() { :; }
        apply_cloud_resources
    )
    assert_equal "explicit cloud apply completes CDN before switching runtime" \
        $'root\nstate\nsnapshot\nbbr\nufw\ndns\ncdn\nruntime\nsubscriptions\nvalidate-subscription\nsave\nregister\nshow' "${cloud_apply_calls}"

    disable_custom_subscription_calls=$(
        require_root() { :; }
        begin_quota_maintenance() { :; }
        end_quota_maintenance() { :; }
        collect_installed_state() {
            SUBSCRIPTION_MODE="deploy"
            VLESS_CDN_DOMAIN="node.example.com"
            SUBSCRIPTION_DOMAIN="subscribe.example.net"
            SUB_DOWNLOAD_NAME="EASY_ALL_TEST"
        }
        snapshot_subscription_update() { UPDATE_SUB_ROLLBACK_ON_EXIT=1; }
        choose_subscription_mode() { SUBSCRIPTION_MODE="link"; }
        validate_cdn_client_ip_family_runtime() { :; }
        choose_monthly_quota() { QUOTA_ENABLED=0; }
        configure_aws_cdn() { printf 'cloud\n'; }
        remove_previous_aws_subscription_alias() { printf 'cleanup-old-dns\n'; }
        remove_subscriptions() { printf 'remove\n'; }
        save_state() { :; }
        refresh_runtime() { :; }
        install_quota_timer() { :; }
        install_cdn_traffic_protection_timer() { :; }
        show_subscription() { :; }
        success() { :; }
        update_subscription
    )
    assert_contains "disabling a custom AWS subscription hostname removes local subscriptions first" \
        "${disable_custom_subscription_calls}" $'remove\n'
    assert_contains "disabling a custom AWS subscription hostname synchronizes and cleans cloud DNS" \
        "${disable_custom_subscription_calls}" $'cloud\ncleanup-old-dns'

    cloud_rollback_calls=$(
        (
            UPDATE_SUB_BACKUP_DIR="${TMP_DIR}/aws-cloud-rollback"
            install -d -m 0700 "${UPDATE_SUB_BACKUP_DIR}"
            printf '%s\n' '{"CallerReference":"old","Aliases":{"Quantity":1,"Items":["node.example.com"]}}' \
                >"${UPDATE_SUB_BACKUP_DIR}/aws-distribution-config.json"
            AWS_SUBSCRIPTION_CLOUD_ROLLBACK_ON_EXIT=1
            AWS_CLOUDFRONT_DISTRIBUTION_ID="DIST-OLD"
            rollback_log="${TMP_DIR}/aws-cloud-rollback.calls"
            aws() {
                if [[ "${1:-} ${2:-}" == "cloudfront get-distribution-config" ]]; then
                    printf '%s\n' '{"ETag":"etag-current","DistributionConfig":{}}'
                elif [[ "${1:-} ${2:-}" == "cloudfront update-distribution" ]]; then
                    printf 'restore-distribution %s\n' "$*" >>"${rollback_log}"
                elif [[ "${1:-} ${2:-}" == "cloudfront wait" ]]; then
                    printf 'wait-restored\n' >>"${rollback_log}"
                else
                    return 1
                fi
            }
            rollback_provider_subscription_update
            cat "${rollback_log}"
        )
    )
    assert_contains "AWS subscription rollback restores the previous distribution config" \
        "${cloud_rollback_calls}" 'restore-distribution cloudfront update-distribution'
    assert_contains "AWS subscription rollback waits for the restored distribution" \
        "${cloud_rollback_calls}" 'wait-restored'

    retired_alias_calls=$(
        (
            VLESS_CDN_DOMAIN="node.example.com"
            AWS_CLOUDFRONT_DOMAIN="d111.cloudfront.net"
            retired_alias_log="${TMP_DIR}/aws-retired-alias.calls"
            aws() {
                if [[ "${1:-} ${2:-}" == "route53 list-resource-record-sets" ]]; then
                    printf '%s\n' '{"ResourceRecordSets":[
                      {"Name":"old.example.net.","Type":"A","AliasTarget":{"HostedZoneId":"Z2FDTNDATAQYW2","DNSName":"d111.cloudfront.net.","EvaluateTargetHealth":false}},
                      {"Name":"old.example.net.","Type":"AAAA","AliasTarget":{"HostedZoneId":"Z2FDTNDATAQYW2","DNSName":"d111.cloudfront.net.","EvaluateTargetHealth":false}}]}'
                elif [[ "${1:-} ${2:-}" == "route53 change-resource-record-sets" ]]; then
                    printf 'delete-retired-alias %s\n' "$*" >>"${retired_alias_log}"
                else
                    return 1
                fi
            }
            remove_previous_aws_subscription_alias "old.example.net" "ZOLD"
            cat "${retired_alias_log}"
        )
    )
    assert_contains "AWS removes a retired subscription alias only when it still targets the managed distribution" \
        "${retired_alias_calls}" 'delete-retired-alias route53 change-resource-record-sets'
)

core_update_function=$(sed -n '/^update_current_core()/,/^}/p' "${XHTTP_RUNTIME}")
CORE_UPDATE_FUNCTION="${core_update_function}" \
CORE_TEST_ROOT="${TMP_DIR}/core-update" bash -c '
    set -Eeuo pipefail
    eval "${CORE_UPDATE_FUNCTION}"
    RUNTIME_TMP="${CORE_TEST_ROOT}/runtime"
    XRAY_DIR="${CORE_TEST_ROOT}/xray"
    XRAY_BIN="${XRAY_DIR}/xray"
    XRAY_CONFIG="${XRAY_DIR}/config.json"
    XRAY_SERVICE="easy_all-xray.service"
    install -d -m 0755 "${RUNTIME_TMP}" "${XRAY_DIR}"
    printf old-binary >"${XRAY_BIN}"
    printf old-config >"${XRAY_CONFIG}"
    printf old-version >"${XRAY_DIR}/version"
    require_root() { :; }
    begin_quota_maintenance() { :; }
    end_quota_maintenance() { :; }
    collect_installed_state() { :; }
    download_xray() {
        printf new-binary >"${XRAY_BIN}"
        printf new-version >"${XRAY_DIR}/version"
    }
    cdn_traffic_protection_checkpoint() { :; }
    cdn_traffic_protection_needs_apply() { return 0; }
    write_xray_config() { printf new-config >"${XRAY_CONFIG}"; }
    cdn_traffic_mark_enforced() { :; }
    systemctl() { :; }
    validate_protocol_runtime() {
        if [[ ! -f "${CORE_TEST_ROOT}/first-validation" ]]; then
            : >"${CORE_TEST_ROOT}/first-validation"
            die "simulated new-core runtime validation failure"
        fi
        printf validated >"${CORE_TEST_ROOT}/validated"
    }
    warn() { :; }
    success() { :; }
    die() {
        [[ "$*" != "simulated new-core runtime validation failure" ]] || exit 1
        return 1
    }
    if update_current_core; then
        exit 1
    fi
    [[ "$(<"${XRAY_BIN}")" == old-binary ]]
    [[ "$(<"${XRAY_CONFIG}")" == old-config ]]
    [[ "$(<"${XRAY_DIR}/version")" == old-version ]]
    [[ -f "${CORE_TEST_ROOT}/validated" ]]
' || fail "failed XHTTP core update must restore and validate binary, config, and version"

readme=$(cat "${ROOT_DIR}/README.md" "${ROOT_DIR}/docs/aws-guide.md")
assert_contains "README rejects AWS root credentials" "${readme}" "不要使用 AWS 根用户凭证"
assert_contains "README documents AWS token terminology" "${readme}" "Access Key ID"
assert_contains "README matches current IAM group option" "${readme}" "添加用户到组"
assert_contains "README names managed policy" "${readme}" "easy_all_deploy_policy"
assert_contains "AWS guide highlights the required Route 53 zone replacement" \
    "${readme}" "REPLACE_WITH_YOUR_ROUTE53_HOSTED_ZONE_ID"
assert_contains "AWS guide requires the global AWS account partition" \
    "${readme}" "AWS 中国区域账号"
assert_contains "AWS guide documents CloudFront's monthly free transfer allowance" \
    "${readme}" "100 GB + 100 万次请求"
assert_contains "AWS guide documents CloudFront pay-as-you-go free allowance" \
    "${readme}" "1 TB + 1000 万次请求"
assert_contains "AWS guide estimates standard Route 53 queries" \
    "${readme}" '$0.40/百万次'
assert_contains "AWS guide requires Route 53 public DNS delegation for XHTTP" \
    "${readme}" "这是 CDN XHTTP 的**必要条件**"
assert_contains "AWS guide distinguishes DNS delegation from domain registration transfer" \
    "${readme}" "注册商不必迁入 AWS"
assert_contains "AWS guide documents DNSSEC requirements" "${readme}" "DNSSEC"
assert_contains "README includes top-down Mermaid install flow" "${readme}" 'flowchart TD'
assert_contains "README documents direct-enter semantics" "${readme}" \
    "直接回车会采用该值"

printf 'easy_all XHTTP tests passed\n'
