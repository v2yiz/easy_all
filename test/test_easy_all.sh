#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
SCRIPT_COPY="${TMP_DIR}/easy_all.test.sh"
TESTS_RUN=0
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail_test() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local description=$1 expected=$2 actual=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "${actual}" == "${expected}" ]] \
        || fail_test "${description}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local description=$1 needle=$2 haystack=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "${haystack}" == *"${needle}"* ]] \
        || fail_test "${description}: missing '${needle}'"
}

assert_not_contains() {
    local description=$1 needle=$2 haystack=$3
    TESTS_RUN=$((TESTS_RUN + 1))
    [[ "${haystack}" != *"${needle}"* ]] \
        || fail_test "${description}: unexpected '${needle}'"
}

assert_success() {
    local description=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@" || fail_test "${description}"
}

assert_failure() {
    local description=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ("$@") >/dev/null 2>&1; then
        fail_test "${description}"
    fi
}

source_script_copy() {
    install -m 0644 "${ROOT_DIR}/lib/quota.sh" "${TMP_DIR}/quota.sh"
    sed \
        -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${TMP_DIR}/state\"|" \
        -e "s|^readonly WEB_ROOT=.*|readonly WEB_ROOT=\"${TMP_DIR}/www\"|" \
        -e "s|^readonly COMMAND_INSTALL_DIR=.*|readonly COMMAND_INSTALL_DIR=\"${TMP_DIR}/cmd\"|" \
        -e "s|^readonly COMMAND_PATH=.*|readonly COMMAND_PATH=\"${TMP_DIR}/bin/easy_all\"|" \
        -e "s|^readonly XRAY_DIR=.*|readonly XRAY_DIR=\"${TMP_DIR}/state/xray\"|" \
        -e "s|^readonly XRAY_BIN=.*|readonly XRAY_BIN=\"${TMP_DIR}/state/xray/xray\"|" \
        -e "s|^readonly XRAY_CONFIG=.*|readonly XRAY_CONFIG=\"${TMP_DIR}/state/xray/config.json\"|" \
        -e "s|^readonly XRAY_SERVICE_FILE=.*|readonly XRAY_SERVICE_FILE=\"${TMP_DIR}/easy_all-xray.service\"|" \
        -e "s|^readonly NGINX_CONFIG=.*|readonly NGINX_CONFIG=\"${TMP_DIR}/easy_all.conf\"|" \
        -e "s|^readonly ACME_HOME=.*|readonly ACME_HOME=\"${TMP_DIR}/acme\"|" \
        -e "s|^readonly ACME_BIN=.*|readonly ACME_BIN=\"${TMP_DIR}/acme/acme.sh\"|" \
        -e "s|^readonly UFW_BEFORE_RULES=.*|readonly UFW_BEFORE_RULES=\"${TMP_DIR}/before.rules\"|" \
        -e "s|^readonly LEGACY_NFT_CONFIG=.*|readonly LEGACY_NFT_CONFIG=\"${TMP_DIR}/nftables.conf\"|" \
        "${ROOT_DIR}/lib/reality.sh" >"${SCRIPT_COPY}"
    EASY_ALL_ENTRY_SCRIPT="${ROOT_DIR}/easy_all"
    EASY_ALL_ENTRY_COMMAND=easy_all
    # shellcheck source=/dev/null
    source "${SCRIPT_COPY}"
    MIHOMO_TEMPLATE_SOURCE="${ROOT_DIR}/sample-mihomo.yaml"
}

set_fixture() {
    PROTOCOL="reality"
    NODE_NAME="MY_REALITY"
    NODE_HOST="203.0.113.10"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    REALITY_TARGET="www.cloudflare.com:443"
    REALITY_PRIVATE_KEY="test-private-key"
    REALITY_PUBLIC_KEY="test-public-key"
    REALITY_SHORT_ID="0123456789abcdef"
    SUB_PORT_MODE="dynamic"
    SUBSCRIPTION_MODE="selfhost"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    SUB_DOWNLOAD_NAME="MY_SUB"
    ALLOWED_TOKENS='{"owner":"test-token","friend":"friend-token"}'
    GEMINI_IP_FAMILY="ipv4"
}

test_syntax_and_worker_removal() {
    local script
    bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/lib/reality.sh" "${ROOT_DIR}/lib/xhttp.sh"
    script=$(<"${ROOT_DIR}/lib/reality.sh")
    assert_not_contains "installer has no Worker API token" "CF_WORKER_API_TOKEN" "${script}"
    assert_not_contains "installer has no Worker deployment mode" "DEPLOY_MODE" "${script}"
    assert_not_contains "installer has no Worker file" "subscribe-worker.js" "${script}"
    assert_not_contains "installer has no Cloudflare API endpoint" \
        "api.cloudflare.com/client/v4" "${script}"
    assert_not_contains "installer has no sample Worker source" "sample-worker.js" "${script}"
    assert_success "root sample Worker was deleted" test ! -e "${ROOT_DIR}/sample-worker.js"
    assert_contains "install input collection asks for subscription mode" \
        "SUBSCRIPTION_MODE=\${SUBSCRIBE_MODE}" "${script}"
    assert_contains "Reality rejects AAAA node domains" \
        "Reality 节点域名不能发布 AAAA" "${script}"
    assert_contains "Reality default prompts explain the enter default" \
        '[${default}]（直接回车使用默认值）' "${script}"
    assert_contains "Reality subscription prompt recommends self-hosting for one server" \
        "只有当前服务器时推荐" "${script}"
    assert_contains "Reality subscription prompt recommends node output for aggregation" \
        "多节点聚合或已有订阅服务器时推荐" "${script}"
    assert_contains "non-interactive uninstall requires FORCE" \
        "非交互卸载必须显式设置 FORCE=1" "${script}"
    assert_contains "Reality uninstall can preserve ACME state for reinstall" \
        'PRESERVE_ACME=1' "${script}"
    assert_contains "Reality repairs a missing ACME renewal cron job" \
        'run_acme --install-cronjob' "${script}"
    assert_not_contains "installer no longer downloads XanMod" "dl.xanmod.org" "${script}"
    assert_contains "installer persists Google BBR module loading" \
        "BBR_MODULES_CONFIG" "${script}"
}

test_validators_and_modes() {
    assert_success "Reality target accepts host and port" \
        validate_reality_target "www.cloudflare.com:443"
    assert_failure "Reality target requires port" \
        validate_reality_target "www.cloudflare.com"
    assert_equal "Reality defaults to dynamic subscriptions" \
        "dynamic" "${DEFAULT_REALITY_PORT_MODE}"
    assert_equal "token dictionary is normalized" \
        '{"owner":"test-token"}' \
        "$(normalize_allowed_tokens '{" owner ":" test-token "}')"

    SUBSCRIBE_MODE="1"
    SUBSCRIPTION_MODE=""
    choose_subscription_mode
    assert_equal "choice 1 enables self-hosting" "selfhost" "${SUBSCRIBE_MODE}"
    SUBSCRIBE_MODE="2"
    SUBSCRIPTION_MODE=""
    choose_subscription_mode
    assert_equal "choice 2 selects links only" "link" "${SUBSCRIBE_MODE}"

    unset SUBSCRIBE_MODE
    SUBSCRIPTION_MODE="link"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    assert_equal "update-sub keeps the current link mode by default" \
        "link" "${SUBSCRIPTION_MODE}"
    PROMPT_SUBSCRIPTION_MODE=0
}

test_mihomo_template() {
    local policy invalid="${TMP_DIR}/invalid.yaml"
    validate_mihomo_template "${ROOT_DIR}/sample-mihomo.yaml"
    policy=$(extract_gemini_domain_suffixes "${ROOT_DIR}/sample-mihomo.yaml")
    assert_success "Gemini policy contains Google dependencies only" \
        jq -e \
        'index("google.com") and index("googleapis.com")
         and (index("openai.com") | not) and (index("claude.ai") | not)' \
        <<<"${policy}"
    grep -v '^# EASY_ALL_PROXY_NAME$' \
        "${ROOT_DIR}/sample-mihomo.yaml" >"${invalid}"
    assert_failure "template rejects a missing proxy marker" \
        validate_mihomo_template "${invalid}"
}

test_subscription_generation() {
    local base64_file="${TMP_DIR}/base64.txt"
    local mihomo_file="${TMP_DIR}/mihomo.yaml"
    local decoded port yaml
    set_fixture
    MIHOMO_TEMPLATE_FILE=""
    GEMINI_DOMAIN_SUFFIXES_JSON=""
    generate_subscription_files "${base64_file}" "${mihomo_file}"
    decoded=$(openssl base64 -d -A <"${base64_file}")
    yaml=$(<"${mihomo_file}")
    assert_contains "Base64 subscription contains Reality" "security=reality" "${decoded}"
    port=$(sed -E 's#.*@[^:]+:([0-9]+)\\?.*#\1#' <<<"${decoded}")
    assert_success "dynamic subscription port is in the redirected range" \
        bash -c '(( $1 >= 10000 && $1 <= 65535 ))' _ "${port}"
    assert_contains "Mihomo subscription contains the same port" \
        "port: ${port}" "${yaml}"
    assert_contains "Mihomo subscription contains Reality options" \
        "reality-opts:" "${yaml}"
    assert_contains "Mihomo subscription contains complete rules" \
        "RULE-SET,telegramcidr,PROXY,no-resolve" "${yaml}"
    assert_not_contains "rendered subscription removes proxy marker" \
        "EASY_ALL_PROXY_NODE" "${yaml}"
    assert_not_contains "rendered subscription removes policy metadata" \
        "EASY_ALL_GEMINI_DOMAINS" "${yaml}"

    SUB_PORT_MODE="443"
    generate_subscription_files "${base64_file}" "${mihomo_file}"
    decoded=$(openssl base64 -d -A <"${base64_file}")
    assert_contains "fixed subscription mode uses port 443" \
        "@203.0.113.10:443?" "${decoded}"
}

test_nginx_and_firewall() {
    local config ufw_config ufw_log="${TMP_DIR}/ufw.log"
    set_fixture
    install -d -m 0700 "${STATE_DIR}" "${CERT_DIR}"
    install -m 0600 /dev/null "${CERT_FILE}"
    install -m 0600 /dev/null "${KEY_FILE}"
    nginx() { return 0; }
    systemctl() { return 0; }
    write_subscription_nginx_config
    config=$(<"${NGINX_CONFIG}")
    assert_contains "Nginx listens on 8443" "listen 8443 ssl http2;" "${config}"
    assert_contains "Nginx authorizes token values" '"test-token" 1;' "${config}"
    assert_not_contains "Nginx does not authorize token labels" '"owner" 1;' "${config}"
    assert_contains "Nginx keeps static files internal" \
        "location = /_easy_all_subscription/mihomo" "${config}"
    assert_contains "Mihomo download keeps the configured filename without an extension" \
        'Content-Disposition "attachment; filename=MY_SUB"' "${config}"
    assert_not_contains "Mihomo download does not append yaml to the filename" \
        'filename=MY_SUB.yaml' "${config}"

    detect_ssh_ports() { SSH_PORTS="22"; }
    ufw() {
        if [[ "${1:-}" == "status" ]]; then
            printf 'Status: active\n'
        else
            printf '%s\n' "$*" >>"${ufw_log}"
        fi
    }
    iptables-restore() { cat >/dev/null; }
    cat >"${UFW_BEFORE_RULES}" <<'EOF'
*filter
:ufw-before-input - [0:0]
COMMIT
EOF
    SUBSCRIBE_MODE="selfhost"
    configure_ufw
    ufw_config=$(<"${UFW_BEFORE_RULES}")
    assert_contains "self-hosting opens HTTP" \
        "allow 80/tcp comment easy_all-managed" "$(<"${ufw_log}")"
    assert_contains "self-hosting opens 8443" \
        "allow 8443/tcp comment easy_all-managed" "$(<"${ufw_log}")"
    assert_contains "dynamic Reality forwarding remains active" \
        "--dport 10000:65535 -j REDIRECT --to-ports 443" "${ufw_config}"
    unset -f nginx systemctl detect_ssh_ports ufw iptables-restore
}

test_acme_reinstall_and_rate_limit_guidance() {
    local rate_log="${TMP_DIR}/acme-rate-limit.log"
    local generic_log="${TMP_DIR}/acme-generic-error.log"
    local message
    printf '%s\n' \
        '429 urn:ietf:params:acme:error:rateLimited: too many certificates already issued for this exact set of identifiers, retry after 2026-08-20 12:00:00 UTC' \
        >"${rate_log}"
    message=$(describe_acme_issue_failure "${rate_log}" 1)
    assert_contains "ACME rate limit guidance tells the user to wait" \
        "请等待 CA 指定时间后再试" "${message}"
    assert_contains "ACME rate limit guidance includes retry-after" \
        "retry after 2026-08-20 12:00:00 UTC" "${message}"
    assert_contains "ACME duplicate certificate guidance allows a new domain" \
        "全新订阅域名" "${message}"

    printf '%s\n' 'Invalid response from http://sub.example.com/.well-known/acme-challenge' \
        >"${generic_log}"
    message=$(describe_acme_issue_failure "${generic_log}" 1)
    assert_contains "generic ACME failures retain DNS and port guidance" \
        "DNS、CAA 和 TCP 80" "${message}"
    assert_not_contains "generic ACME failures are not mislabeled as rate limits" \
        "触发签发限流" "${message}"

    run_acme() {
        if [[ "$*" == *"--set-default-ca"* ]]; then
            return 0
        fi
        printf '%s\n' \
            '429 rateLimited: too many certificates for this exact set of identifiers, retry after 2026-08-20 12:00:00 UTC'
        return 17
    }
    install_acme() { :; }
    if message=$(issue_subscription_certificate 2>&1); then
        fail_test "rate-limited certificate issuance must fail"
    fi
    assert_contains "certificate issuance reports parsed rate-limit guidance" \
        "Let's Encrypt 触发签发限流（acme.sh 返回 17）" "${message}"
    unset -f run_acme install_acme

    install -d -m 0700 "${ACME_HOME}/sub.example.com_ecc"
    install -m 0700 /dev/null "${ACME_BIN}"
    PRESERVE_ACME=1
    remove_managed_acme_domain "sub.example.com"
    assert_success "PRESERVE_ACME keeps the reusable ACME certificate directory" \
        test -d "${ACME_HOME}/sub.example.com_ecc"
    unset PRESERVE_ACME
}

test_acme_renewal_repair() {
    local cron_state=""
    install -d -m 0700 "${ACME_HOME}"
    cat >"${ACME_BIN}" <<'EOF'
#!/bin/sh
exit 0
EOF
    chmod 0700 "${ACME_BIN}"
    systemctl() { return 0; }
    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            printf '%s\n' "${cron_state}"
        else
            cron_state=$(<"$1")
        fi
    }
    run_acme() {
        [[ "$*" == *"--install-cronjob"* ]] || return 1
        return 0
    }
    install_acme
    assert_contains "existing acme.sh repairs its missing renewal entry" \
        "--cron" "${cron_state}"
    assert_contains "existing acme.sh falls back to an easy_all managed renewal entry" \
        "easy_all-acme-renewal" "${cron_state}"
    unset -f systemctl crontab run_acme
}

test_legacy_firewall_migration() {
    install -d -m 0700 "${STATE_DIR}" "${BACKUP_DIR}"
    printf 'managed legacy rules\n' >"${LEGACY_NFT_CONFIG}"
    sha256sum "${LEGACY_NFT_CONFIG}" | awk '{print $1}' >"${STATE_DIR}/nftables.sha256"
    systemctl() { return 0; }
    nft() { return 0; }
    retire_legacy_nftables
    assert_success "legacy managed nftables config is removed" \
        test ! -e "${LEGACY_NFT_CONFIG}"
    assert_success "legacy nftables ownership marker is removed" \
        test ! -e "${STATE_DIR}/nftables.sha256"

    printf 'user changed rules\n' >"${LEGACY_NFT_CONFIG}"
    printf 'different-hash\n' >"${STATE_DIR}/nftables.sha256"
    assert_failure "modified nftables config fails fast" retire_legacy_nftables
    unset -f systemctl nft
    rm -f -- "${LEGACY_NFT_CONFIG}" "${STATE_DIR}/nftables.sha256"
}

test_state_and_xray() {
    local state config
    set_fixture
    save_state
    state=$(<"${STATE_FILE}")
    assert_contains "state persists subscription mode" \
        "SUBSCRIPTION_MODE=selfhost" "${state}"
    assert_contains "state persists subscription domain" \
        "SUBSCRIPTION_DOMAIN=sub.example.com" "${state}"
    assert_contains "state supports persisting the quota start date" \
        "QUOTA_START_DATE=" "${state}"
    assert_not_contains "state has no Worker name" "WORKER_NAME=" "${state}"
    assert_not_contains "state has no Cloudflare account" "CF_ACCOUNT_ID=" "${state}"

    install -d -m 0755 "${XRAY_DIR}"
    cat >"${XRAY_BIN}" <<'EOF'
#!/bin/sh
if [ "$1" = "x25519" ]; then printf 'PublicKey: test-public-key\n'; fi
exit 0
EOF
    chmod 0755 "${XRAY_BIN}"
    MIHOMO_TEMPLATE_FILE=""
    GEMINI_DOMAIN_SUFFIXES_JSON=""
    write_xray_config
    config=$(<"${XRAY_CONFIG}")
    assert_success "Xray uses Reality Vision" \
        jq -e \
        '.inbounds[0].streamSettings.security == "reality"
         and .inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"' \
        <<<"${config}"
    assert_success "Xray Gemini policy comes from Mihomo template" \
        jq -e \
        '(.routing.rules[0].domain | index("domain:google.com"))
         and ((.routing.rules[0].domain | index("domain:openai.com")) == null)' \
        <<<"${config}"

    QUOTA_ENABLED=1
    USER_ACCOUNTS='{"owner":{"token":"owner-token-123","uuid":"00000000-0000-4000-8000-000000000001","quota_gb":0},"friend":{"token":"friend-token-123","uuid":"00000000-0000-4000-8000-000000000002","quota_gb":100}}'
    rm -f -- "${QUOTA_USAGE_FILE}"
    write_xray_config
    config=$(<"${XRAY_CONFIG}")
    assert_success "quota mode emits independent Xray users and local stats API" \
        jq -e \
        '.api.listen == "127.0.0.1:10085"
         and .api.services == ["StatsService"]
         and .policy.levels["0"].statsUserUplink == true
         and .policy.levels["0"].statsUserDownlink == true
         and (.inbounds[0].settings.clients | map(.email) | sort)
             == ["easy_all.friend","easy_all.owner"]' \
        <<<"${config}"
}

source_script_copy
test_syntax_and_worker_removal
test_validators_and_modes
test_mihomo_template
test_subscription_generation
test_nginx_and_firewall
test_acme_renewal_repair
test_acme_reinstall_and_rate_limit_guidance
test_legacy_firewall_migration
test_state_and_xray

printf 'ok - easy_all shell tests passed (%s assertions)\n' "${TESTS_RUN}"
