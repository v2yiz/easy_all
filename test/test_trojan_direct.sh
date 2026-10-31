#!/usr/bin/env bash

# Behaviour tests for the Trojan direct profile and its static fallback site.
# Real system services are stubbed; only the profile logic is exercised.

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
PROFILE_COPY="${TMP_DIR}/profiles/trojan.test.sh"
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

assert_failure() {
    local description=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    if ("$@") >/dev/null 2>&1; then
        fail_test "${description}"
    fi
}

assert_success() {
    local description=$1
    shift
    TESTS_RUN=$((TESTS_RUN + 1))
    "$@" >/dev/null 2>&1 || fail_test "${description}"
}

prepare_profile_copy() {
    local module
    install -d -m 0755 "${TMP_DIR}/profiles" "${TMP_DIR}/lib" \
        "${TMP_DIR}/templates" "${TMP_DIR}/state" "${TMP_DIR}/www" "${TMP_DIR}/cmd"
    cp -R "${ROOT_DIR}/templates/site" "${TMP_DIR}/templates/site"
    for module in log.sh runtime-core.sh quota.sh platform.sh profile-common.sh \
        network.sh mihomo-template.sh firewall.sh xray-core.sh \
        scheduled-maintenance.sh subscription-auth.sh worker-config.sh tcp-tuning.sh; do
        install -m 0644 "${ROOT_DIR}/lib/${module}" "${TMP_DIR}/lib/${module}"
    done
    sed \
        -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${TMP_DIR}/state\"|" \
        -e "s|^readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"${TMP_DIR}/state/backups\"|" \
        -e "s|^readonly STATE_FILE=.*|readonly STATE_FILE=\"${TMP_DIR}/state/state.env\"|" \
        -e "s|^readonly CERT_DIR=.*|readonly CERT_DIR=\"${TMP_DIR}/state/certs\"|" \
        -e "s|^readonly CERT_FILE=.*|readonly CERT_FILE=\"${TMP_DIR}/state/certs/fullchain.pem\"|" \
        -e "s|^readonly KEY_FILE=.*|readonly KEY_FILE=\"${TMP_DIR}/state/certs/private.key\"|" \
        -e "s|^readonly LEGO_DIR=.*|readonly LEGO_DIR=\"${TMP_DIR}/state/acme\"|" \
        -e "s|^readonly LEGO_BIN=.*|readonly LEGO_BIN=\"${TMP_DIR}/state/acme/lego\"|" \
        -e "s|^readonly LEGO_VERSION_FILE=.*|readonly LEGO_VERSION_FILE=\"${TMP_DIR}/state/acme/version\"|" \
        -e "s|^readonly LEGO_CERT_DIR=.*|readonly LEGO_CERT_DIR=\"${TMP_DIR}/state/acme/certificates\"|" \
        -e "s|^readonly LEGO_DNS_ENV=.*|readonly LEGO_DNS_ENV=\"${TMP_DIR}/state/acme/cloudflare-dns.env\"|" \
        -e "s|^readonly LEGO_INSTALL_HOOK=.*|readonly LEGO_INSTALL_HOOK=\"${TMP_DIR}/state/acme/install-certificate\"|" \
        -e "s|^readonly WEB_ROOT=.*|readonly WEB_ROOT=\"${TMP_DIR}/www\"|" \
        -e "s|^readonly SITE_ROOT=.*|readonly SITE_ROOT=\"${TMP_DIR}/www/site\"|" \
        -e "s|^readonly COMMAND_INSTALL_DIR=.*|readonly COMMAND_INSTALL_DIR=\"${TMP_DIR}/cmd\"|" \
        -e "s|^readonly COMMAND_PATH=.*|readonly COMMAND_PATH=\"${TMP_DIR}/cmd/easy_all\"|" \
        -e "s|^readonly XRAY_DIR=.*|readonly XRAY_DIR=\"${TMP_DIR}/state/xray\"|" \
        -e "s|^readonly XRAY_BIN=.*|readonly XRAY_BIN=\"${TMP_DIR}/stub-xray\"|" \
        -e "s|^readonly XRAY_CONFIG=.*|readonly XRAY_CONFIG=\"${TMP_DIR}/state/xray/config.json\"|" \
        -e "s|^readonly XRAY_SERVICE_FILE=.*|readonly XRAY_SERVICE_FILE=\"${TMP_DIR}/easy_all-xray.service\"|" \
        -e "s|^readonly NGINX_CONFIG=.*|readonly NGINX_CONFIG=\"${TMP_DIR}/easy_all-nginx.conf\"|" \
        -e "s|^readonly NGINX_DEFAULT_SITE=.*|readonly NGINX_DEFAULT_SITE=\"${TMP_DIR}/nginx/sites-enabled/default\"|" \
        -e "s|^readonly CERT_RENEW_SERVICE_FILE=.*|readonly CERT_RENEW_SERVICE_FILE=\"${TMP_DIR}/cert-renew.service\"|" \
        -e "s|^readonly CERT_RENEW_TIMER_FILE=.*|readonly CERT_RENEW_TIMER_FILE=\"${TMP_DIR}/cert-renew.timer\"|" \
        -e "s|^readonly UFW_BEFORE_RULES=.*|readonly UFW_BEFORE_RULES=\"${TMP_DIR}/before.rules\"|" \
        -e "s|^readonly UFW_BEFORE6_RULES=.*|readonly UFW_BEFORE6_RULES=\"${TMP_DIR}/before6.rules\"|" \
        -e "s|^readonly UFW_DEFAULT_CONFIG=.*|readonly UFW_DEFAULT_CONFIG=\"${TMP_DIR}/ufw-default\"|" \
        -e "s|^readonly IPV6_SYSCTL_CONF=.*|readonly IPV6_SYSCTL_CONF=\"${TMP_DIR}/99-enable-ipv6.conf\"|" \
        "${ROOT_DIR}/profiles/trojan-direct.sh" >"${PROFILE_COPY}"
}

setup_stubs() {
    cat >"${TMP_DIR}/stub-xray" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod 0755 "${TMP_DIR}/stub-xray"

    nginx() { return 0; }
    systemctl() { return 0; }
    ufw() { return 0; }
    printf '%s\n' '# user cron' >"${TMP_DIR}/crontab"
    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            cat "${TMP_DIR}/crontab"
            return 0
        fi
        cat >"${TMP_DIR}/crontab"
    }
    iptables-restore() { cat >/dev/null; return 0; }
    ip6tables-restore() { cat >/dev/null; return 0; }
    ss() { return 0; }
    dig() { printf '203.0.113.10\n'; }
    curl() { return 0; }
    timeout() { local _unused=$1; shift; "$@"; }
}

setup_state_fixture() {
    install -d -m 0700 "${TMP_DIR}/state"
    PROTOCOL="trojan"
    TCP_ACCELERATION="bbrv3"
    NODE_NAME="MY_TROJAN"
    NODE_HOST="node.example.com"
    TROJAN_PASSWORD="test-password-0123456789abcdef"
    TROJAN_PORT_MODE="dynamic"
    TROJAN_ACME_EMAIL="admin@example.com"
    CLOUDFLARE_ZONE_ID="0123456789abcdef0123456789abcdef"
    CLOUDFLARE_ZONE_NAME="example.com"
    TROJAN_DNS_RECORD_ID="fedcba9876543210fedcba9876543210"
    VPS_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV6=""
    GOOGLE_EGRESS_MODE="ipv4"
    GOOGLE_EGRESS_RESOLVED="ipv4"
    SCHEDULED_REBOOT_ENABLED="0"
    SCHEDULED_REBOOT_HOUR=""
}

test_syntax_and_wiring() {
    local launcher manifest
    bash -n "${ROOT_DIR}/profiles/trojan-direct.sh"
    launcher=$(<"${ROOT_DIR}/easy_all")
    manifest=$(<"${ROOT_DIR}/runtime.manifest")
    assert_contains "launcher maps the Trojan protocol" 'trojan)' "${launcher}"
    assert_contains "launcher registers the Trojan profile" \
        'trojan-direct) candidate="${EASY_ALL_ROOT}/profiles/trojan-direct.sh"' "${launcher}"
    assert_contains "launcher exposes the Trojan menu entry" \
        '3. 直连 - Trojan' "${launcher}"
    assert_contains "launcher routes certificate renewal" \
        'trojan-direct) renew_trojan_certificate' "${launcher}"
    assert_contains "launcher allows dynamic port rotation for Trojan" \
        'reality | trojan-direct) rotate_dynamic_ports' "${launcher}"
    assert_contains "runtime manifest ships the Trojan profile" \
        'profiles/trojan-direct.sh' "${manifest}"
    assert_contains "runtime manifest ships the fallback site" \
        'templates/site/index.html' "${manifest}"
    [[ -s "${ROOT_DIR}/templates/site/assets/style.css" ]] \
        || fail_test "fallback site stylesheet is missing"
    [[ -s "${ROOT_DIR}/templates/site/assets/app.js" ]] \
        || fail_test "fallback site script is missing"
    assert_not_contains "fallback site script makes no network calls" \
        'fetch(' "$(<"${ROOT_DIR}/templates/site/assets/app.js")"
}

test_input_validation() {
    local generated
    (
        TROJAN_PORT_MODE="443"
        collect_trojan_port_mode
        assert_equal "port mode accepts 443" "443" "${TROJAN_PORT_MODE}"
        TROJAN_PORT_MODE="dynamic"
        collect_trojan_port_mode
        assert_equal "port mode accepts dynamic" "dynamic" "${TROJAN_PORT_MODE}"
        if (TROJAN_PORT_MODE="nonsense"; collect_trojan_port_mode) >/dev/null 2>&1; then
            fail_test "port mode accepted an unknown value"
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
        if (NODE_HOST=""; collect_trojan_domain) >/dev/null 2>&1; then
            fail_test "empty Trojan domain was accepted"
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
        if (NODE_HOST="not a domain"; collect_trojan_domain) >/dev/null 2>&1; then
            fail_test "malformed Trojan domain was accepted"
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
        if (TROJAN_PASSWORD="short"; collect_trojan_password) >/dev/null 2>&1; then
            fail_test "short Trojan password was accepted"
        fi
        TESTS_RUN=$((TESTS_RUN + 1))
        TROJAN_PASSWORD=""
        collect_trojan_password
        generated=${TROJAN_PASSWORD}
        [[ "${generated}" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] \
            || fail_test "generated password does not match the allowed charset"
        TESTS_RUN=$((TESTS_RUN + 1))
        TROJAN_ACME_EMAIL=""
        CLOUDFLARE_ZONE_NAME="example.com"
        collect_trojan_acme_email
        assert_equal "ACME email defaults to the managed zone" \
            "admin@example.com" "${TROJAN_ACME_EMAIL}"
    )
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_link_and_mihomo_output() {
    local link node
    link=$(build_trojan_link 443)
    assert_contains "Trojan link uses the trojan scheme" 'trojan://' "${link}"
    assert_contains "Trojan link targets the node port" \
        '@node.example.com:443?' "${link}"
    assert_contains "Trojan link pins the SNI" 'sni=node.example.com' "${link}"
    assert_contains "Trojan link declares http/1.1 ALPN" 'alpn=http%2F1.1' "${link}"
    assert_contains "Trojan link carries the node name" '#MY_TROJAN' "${link}"
    node=$(build_mihomo_node 443)
    assert_contains "Mihomo node is a trojan proxy" '    type: trojan' "${node}"
    assert_contains "Mihomo node pins the server name" '    sni: "node.example.com"' "${node}"
    assert_contains "Mihomo node pins IPv4" '    ip-version: ipv4' "${node}"
    assert_contains "Mihomo node keeps the ALPN list" '      - http/1.1' "${node}"
}

test_static_site_rendering() {
    local index nginx_conf
    render_static_site
    [[ -f "${RUNTIME_TMP}/site/index.html" ]] \
        || fail_test "rendered site is missing index.html"
    index=$(<"${RUNTIME_TMP}/site/index.html")
    assert_contains "rendered site substitutes the domain" \
        'https://node.example.com/' "${index}"
    assert_not_contains "rendered site has no domain placeholder" \
        '__EASY_ALL_SITE_DOMAIN__' "${index}"
    assert_contains "rendered site keeps the acceptance marker" \
        'Operational Analytics for Product Teams' "${index}"
    [[ "$(find "${RUNTIME_TMP}/site" -type f | wc -l | tr -d ' ')" -ge 14 ]] \
        || fail_test "rendered site is incomplete"
    install_static_site
    [[ -f "${SITE_ROOT}/index.html" ]] || fail_test "published site is missing"
    [[ -f "${SITE_ROOT}/.well-known/security.txt" ]] \
        || fail_test "published site drops dot-directories"
    assert_equal "published site root is world readable" "755" \
        "$(stat -c '%a' "${SITE_ROOT}" 2>/dev/null || stat -f '%Lp' "${SITE_ROOT}")"
    assert_equal "published site assets are world readable" "644" \
        "$(stat -c '%a' "${SITE_ROOT}/assets/style.css" 2>/dev/null \
            || stat -f '%Lp' "${SITE_ROOT}/assets/style.css")"

    install -d -m 0755 "$(dirname -- "${NGINX_DEFAULT_SITE}")"
    printf 'default server\n' >"${NGINX_DEFAULT_SITE}"
    write_site_nginx_config
    [[ ! -e "${NGINX_DEFAULT_SITE}" ]] \
        || fail_test "fallback publishing must remove the distro default site"
    nginx_conf=$(<"${NGINX_CONFIG}")
    assert_contains "fallback listener is loopback only" \
        'listen 127.0.0.1:8080 default_server;' "${nginx_conf}"
    assert_contains "fallback server_name is the node domain" \
        'server_name node.example.com;' "${nginx_conf}"
    assert_contains "fallback serves the published site root" \
        'root '"${SITE_ROOT}"';' "${nginx_conf}"
    assert_contains "fallback defines a 404 page" \
        'error_page 404 /404.html;' "${nginx_conf}"
    assert_not_contains "fallback does not advertise an easy_all marker" \
        'easy_all-health' "${nginx_conf}"
}

test_xray_config() {
    local config
    install -d -m 0700 "${CERT_DIR}"
    printf 'placeholder certificate\n' >"${CERT_FILE}"
    printf 'placeholder key\n' >"${KEY_FILE}"
    write_xray_config
    config=$(<"${XRAY_CONFIG}")
    jq -e '
        .inbounds | length == 1
        and .[0].protocol == "trojan"
        and .[0].port == 443
        and .[0].settings.clients[0].password == "test-password-0123456789abcdef"
        and .[0].settings.fallbacks[0].dest == 8080
        and .[0].settings.fallbacks[0].xver == 0
        and .[0].streamSettings.security == "tls"
        and .[0].streamSettings.network == "tcp"
        and .[0].streamSettings.tlsSettings.alpn == ["http/1.1"]
        and .[0].streamSettings.tlsSettings.minVersion == "1.2"
    ' <<<"${config}" >/dev/null || fail_test "Trojan inbound is malformed"
    jq -e '.api == null and .stats == null' <<<"${config}" >/dev/null \
        || fail_test "Trojan mode must not expose the stats API"
    jq -e '.outbounds | map(.tag) == ["direct","block"]' <<<"${config}" >/dev/null \
        || fail_test "Trojan mode reuses the shared direct outbounds"
    jq -e '.routing.rules[1].network == "udp" and .routing.rules[1].port == "443"' \
        <<<"${config}" >/dev/null \
        || fail_test "Trojan mode keeps the shared QUIC blocking rule"
    jq -e --arg cert "${CERT_FILE}" \
        '.inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile == $cert' \
        <<<"${config}" >/dev/null \
        || fail_test "Trojan inbound does not read the managed certificate"
    rm -f -- "${CERT_FILE}" "${KEY_FILE}"
}

test_lego_release_urls() {
    assert_equal "lego release base carries the version tag" \
        "https://github.com/go-acme/lego/releases/download/v4.35.2" "${LEGO_RELEASE_BASE}"
    assert_equal "lego archive asset name" \
        "lego_v4.35.2_linux_amd64.tar.gz" "${LEGO_ARCHIVE}"
    assert_equal "lego checksums asset name" \
        "lego_4.35.2_checksums.txt" "${LEGO_CHECKSUMS}"
    assert_equal "lego archive URL" \
        "https://github.com/go-acme/lego/releases/download/v4.35.2/lego_v4.35.2_linux_amd64.tar.gz" \
        "$(lego_asset_url "${LEGO_ARCHIVE}")"
    assert_equal "lego checksums URL" \
        "https://github.com/go-acme/lego/releases/download/v4.35.2/lego_4.35.2_checksums.txt" \
        "$(lego_asset_url "${LEGO_CHECKSUMS}")"
}

test_ssh_restore_restarts_stale_listener() {
    (
        local log="${TMP_DIR}/ssh-restore.log" state="${TMP_DIR}/ssh-restore.state"
        local fakebin="${TMP_DIR}/fakebin"
        trap 'rm -f -- "${log}" "${state}"; rm -rf -- "${fakebin}"' EXIT
        install -d -m 0755 "${fakebin}" "$(dirname -- "${EASY_ALL_SSH_PORT_CONFIG}")"
        cat >"${fakebin}/sshd" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-t" ]]; then exit 0; fi
printf 'listenaddress 0.0.0.0:22\n'
EOF
        chmod 0755 "${fakebin}/sshd"
        export PATH="${fakebin}:${PATH}"
        rm -rf -- "${BACKUP_DIR}"
        install -d -m 0700 "${BACKUP_DIR}"
        printf '# Managed by easy_all\nPort 65533\n' >"${EASY_ALL_SSH_PORT_CONFIG}"
        : >"${log}"
        printf 'stale\n' >"${state}"
        sleep() { :; }
        ss() {
            if [[ "$(<"${state}")" == "restarted" ]]; then
                printf 'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=12,fd=3))\n'
            else
                printf 'LISTEN 0 128 0.0.0.0:65533 0.0.0.0:* users:(("sshd",pid=12,fd=3))\n'
            fi
        }
        systemctl() {
            printf 'systemctl %s\n' "$*" >>"${log}"
            if [[ "$1 $2" == "restart ssh.service" ]]; then printf 'restarted\n' >"${state}"; fi
            return 0
        }
        ufw() { return 0; }
        fail2ban-client() { return 0; }
        restore_platform_security_state || return 1
        grep -Fq 'systemctl reload ssh.service' "${log}" || return 1
        grep -Fq 'systemctl restart ssh.service' "${log}" || return 1
        [[ ! -e "${EASY_ALL_SSH_PORT_CONFIG}" ]] || return 1
    ) || fail_test "SSH restore must restart when a reload leaves the listener stale"
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_dynamic_port_rules() {
    local conf rules
    {
        printf '*filter\n'
        printf ':ufw-before-input - [0:0]\n'
        printf 'COMMIT\n'
    } >"${UFW_BEFORE_RULES}"

    TROJAN_PORT_MODE="dynamic"
    write_ufw_nat_rules
    rules=$(<"${UFW_BEFORE_RULES}")
    assert_contains "dynamic mode adds the managed NAT block" \
        '# easy_all-nat-start' "${rules}"
    assert_contains "dynamic mode redirects the whole range to 443" \
        '-A PREROUTING -p tcp --dport 10000:62703 -j REDIRECT --to-ports 443' "${rules}"
    assert_contains "dynamic mode protects SSH inside the range" \
        '-A PREROUTING -p tcp --dport 20000 -j RETURN' "${rules}"
    assert_not_contains "dynamic mode ignores SSH ports outside the range" \
        '--dport 22 -j RETURN' "${rules}"

    TROJAN_PORT_MODE="443"
    write_ufw_nat_rules
    rules=$(<"${UFW_BEFORE_RULES}")
    assert_not_contains "fixed port mode drops the NAT block" \
        '# easy_all-nat-start' "${rules}"
    assert_not_contains "fixed port mode drops the redirect" \
        'REDIRECT --to-ports 443' "${rules}"
    TROJAN_PORT_MODE="dynamic"

    conf=$(write_dynamic_nat_rules)
    assert_contains "NAT helper always emits the redirect" \
        '--dport 10000:62703' "${conf}"
}

test_state_roundtrip() {
    local reloaded current_mode
    save_state
    [[ -f "${STATE_FILE}" ]] || fail_test "state file was not written"
    assert_equal "state file is private" "600" \
        "$(stat -c '%a' "${STATE_FILE}" 2>/dev/null || stat -f '%Lp' "${STATE_FILE}")"
    load_state
    assert_equal "state reload keeps the protocol" "trojan" "${PROTOCOL}"
    assert_equal "state reload keeps the domain" "node.example.com" "${NODE_HOST}"
    assert_equal "state reload keeps the port mode" "dynamic" "${TROJAN_PORT_MODE}"
    assert_equal "state reload keeps the zone" "example.com" "${CLOUDFLARE_ZONE_NAME}"

    current_mode=$(state_value_from_file TROJAN_PORT_MODE)
    sed -i.bak "s|^TROJAN_PORT_MODE=.*|TROJAN_PORT_MODE='bogus'|" "${STATE_FILE}"
    assert_failure "state reload rejects an invalid port mode" load_state
    sed -i.bak "s|^TROJAN_PORT_MODE=.*|TROJAN_PORT_MODE='${current_mode}'|" "${STATE_FILE}"
    rm -f -- "${STATE_FILE}.bak"
    load_state
}

state_value_from_file() {
    local key=$1 value
    value=$(sed -n "s|^${key}=||p" "${STATE_FILE}" | tail -n 1)
    value=${value#\'}
    value=${value%\'}
    value=${value#\"}
    value=${value%\"}
    printf '%s' "${value}"
}

test_certificate_guard_and_hook() {
    local hook args token
    install -d -m 0700 "${CERT_DIR}" "${LEGO_DIR}"
    printf 'not a certificate\n' >"${CERT_FILE}"
    printf 'not a key\n' >"${KEY_FILE}"
    assert_failure "incomplete certificate material is rejected" certificate_is_current
    rm -f -- "${CERT_FILE}" "${KEY_FILE}"

    write_certificate_install_hook
    [[ -x "${LEGO_INSTALL_HOOK}" ]] || fail_test "certificate hook is not executable"
    hook=$(<"${LEGO_INSTALL_HOOK}")
    assert_contains "hook installs the leaf chain" 'fullchain.pem' "${hook}"
    assert_contains "hook restarts Xray only when installed" \
        'systemctl cat' "${hook}"

    printf "CLOUDFLARE_DNS_API_TOKEN='0123456789abcdefghij0123456789abcdefghij'\n" \
        >"${LEGO_DNS_ENV}"
    chmod 0600 "${LEGO_DNS_ENV}"
    token=$(trojan_dns_token_from_env)
    assert_equal "persisted token is readable" \
        "0123456789abcdefghij0123456789abcdefghij" "${token}"

    cat >"${LEGO_BIN}" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" >"${TMP_DIR}/lego-args"
printf '%s\n' "\${CLOUDFLARE_DNS_API_TOKEN:-missing}" >"${TMP_DIR}/lego-token"
EOF
    chmod 0755 "${LEGO_BIN}"
    run_lego renew --days 30
    args=$(<"${TMP_DIR}/lego-args")
    assert_contains "lego uses the Cloudflare DNS provider" '--dns' "${args}"
    assert_contains "lego targets the node domain" 'node.example.com' "${args}"
    assert_contains "lego stores state under the runtime directory" \
        "--path" "${args}"
    assert_equal "lego receives the token through the environment" \
        "0123456789abcdefghij0123456789abcdefghij" "$(<"${TMP_DIR}/lego-token")"
}

test_renewal_timer_and_cron() {
    local unit timer cron
    install_certificate_renewal_timer
    unit=$(<"${CERT_RENEW_SERVICE_FILE}")
    timer=$(<"${CERT_RENEW_TIMER_FILE}")
    assert_contains "renewal service calls the registered command" \
        "ExecStart=${COMMAND_PATH} cert-renew" "${unit}"
    assert_contains "renewal timer runs twice a day" '03,15:23:00' "${timer}"
    assert_contains "renewal timer survives downtime" 'Persistent=true' "${timer}"

    TROJAN_PORT_MODE="dynamic"
    configure_dynamic_port_rotation
    cron=$(<"${TMP_DIR}/crontab")
    assert_contains "dynamic mode installs the boot refresh job" \
        'rotate-dynamic-ports' "${cron}"
    assert_contains "boot refresh job is managed" \
        'easy_all-managed-dynamic-ports' "${cron}"
    TROJAN_PORT_MODE="443"
    configure_dynamic_port_rotation
    cron=$(<"${TMP_DIR}/crontab")
    assert_not_contains "fixed mode removes the boot refresh job" \
        'rotate-dynamic-ports' "${cron}"
    assert_contains "fixed mode keeps unrelated cron entries" '# user cron' "${cron}"
    TROJAN_PORT_MODE="dynamic"
}

test_cloudflare_dns_record() {
    local created payload
    created="${TMP_DIR}/cf-payload"
    printf '[]' >"${TMP_DIR}/cf-a"
    printf '[]' >"${TMP_DIR}/cf-aaaa"
    printf '[]' >"${TMP_DIR}/cf-cname"
    trojan_cloudflare_record_list() {
        case "$2" in
        A) cat "${TMP_DIR}/cf-a" ;;
        AAAA) cat "${TMP_DIR}/cf-aaaa" ;;
        CNAME) cat "${TMP_DIR}/cf-cname" ;;
        *) printf '[]' ;;
        esac
    }
    trojan_cloudflare_api_request() {
        if [[ "$1" == "GET" ]]; then
            trojan_cloudflare_record_list "${TMP_DIR}" "${4:-A}" ""
            return 0
        fi
        printf '%s\n' "$3" >"${created}"
        printf '{"id":"aabbccddeeff00112233445566778899"}'
    }
    VPS_PUBLIC_IPV4="203.0.113.10"
    TROJAN_DNS_RECORD_ID=""
    trojan_cloudflare_ensure_dns_a
    payload=$(<"${created}")
    jq -e '.type == "A" and .proxied == false and .content == "203.0.113.10"' \
        <<<"${payload}" >/dev/null \
        || fail_test "managed A record must be DNS only"
    assert_equal "created record id is kept" \
        "aabbccddeeff00112233445566778899" "${TROJAN_DNS_RECORD_ID}"

    printf '[{"id":"aabbccddeeff00112233445566778899","content":"203.0.113.10","proxied":false,"comment":"easy_all trojan direct node"}]' \
        >"${TMP_DIR}/cf-a"
    rm -f -- "${created}"
    TROJAN_DNS_RECORD_ID=""
    trojan_cloudflare_ensure_dns_a
    [[ ! -f "${created}" ]] || fail_test "matching A record must not be rewritten"
    assert_equal "matching A record id is adopted" \
        "aabbccddeeff00112233445566778899" "${TROJAN_DNS_RECORD_ID}"

    printf '[{"id":"aabbccddeeff00112233445566778899","content":"198.51.100.7","proxied":true,"comment":"someone else"}]' \
        >"${TMP_DIR}/cf-a"
    assert_failure "foreign A records are never overwritten" trojan_cloudflare_ensure_dns_a

    printf '[{"id":"aabbccddeeff00112233445566778899","content":"203.0.113.10","proxied":false,"comment":"easy_all trojan direct node"}]' \
        >"${TMP_DIR}/cf-a"
    printf '[{"id":"v6","content":"2001:db8::1","proxied":false}]' >"${TMP_DIR}/cf-aaaa"
    assert_failure "existing AAAA records block the install" trojan_cloudflare_ensure_dns_a
}

main() {
    prepare_profile_copy
    setup_stubs
    EASY_ALL_SSH_PORT_CONFIG="${TMP_DIR}/ssh/00-easy-all-ports.conf"
    EASY_ALL_FAIL2BAN_CONFIG="${TMP_DIR}/fail2ban/jail.d/99-easy-all-sshd.local"
    EASY_ALL_FAIL2BAN_ACTION_CONFIG="${TMP_DIR}/fail2ban/action.d/easy-all-ufw-cidr.conf"
    EASY_ALL_FAIL2BAN_CIDR_HELPER="${TMP_DIR}/cmd/fail2ban-ufw-cidr.sh"
    EASY_ALL_FAIL2BAN_CIDR_STATE_DIR="${TMP_DIR}/fail2ban-state"
    export EASY_ALL_SSH_PORT_CONFIG EASY_ALL_FAIL2BAN_CONFIG \
        EASY_ALL_FAIL2BAN_ACTION_CONFIG EASY_ALL_FAIL2BAN_CIDR_HELPER \
        EASY_ALL_FAIL2BAN_CIDR_STATE_DIR
    # shellcheck source=/dev/null
    source "${PROFILE_COPY}"
    # runtime-core installs its own EXIT trap; chain it so the sandbox is still removed.
    trap 'cleanup >/dev/null 2>&1 || true; rm -rf -- "${TMP_DIR}"' EXIT
    # platform.sh defines the real detector; the sandbox pins the SSH port set instead.
    detect_ssh_ports() { SSH_PORTS="22 20000"; }
    setup_state_fixture
    test_syntax_and_wiring
    test_input_validation
    test_link_and_mihomo_output
    test_static_site_rendering
    test_xray_config
    test_lego_release_urls
    test_ssh_restore_restarts_stale_listener
    test_dynamic_port_rules
    test_state_roundtrip
    test_certificate_guard_and_hook
    test_renewal_timer_and_cron
    test_cloudflare_dns_record
    printf 'ok - %s Trojan direct tests passed\n' "${TESTS_RUN}"
}

main "$@"
