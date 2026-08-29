#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
SCRIPT_COPY="${TMP_DIR}/profiles/reality.test.sh"
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
    local module
    install -d -m 0755 "${TMP_DIR}/lib" "${TMP_DIR}/profiles"
    for module in quota.sh platform.sh profile-common.sh network.sh mihomo-template.sh firewall.sh xray-core.sh scheduled-maintenance.sh subscription-auth.sh tcp-tuning.sh; do
        install -m 0644 "${ROOT_DIR}/lib/${module}" "${TMP_DIR}/lib/${module}"
    done
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
        -e "s|^readonly UFW_BEFORE6_RULES=.*|readonly UFW_BEFORE6_RULES=\"${TMP_DIR}/before6.rules\"|" \
        -e "s|^readonly UFW_DEFAULT_CONFIG=.*|readonly UFW_DEFAULT_CONFIG=\"${TMP_DIR}/ufw-default\"|" \
        "${ROOT_DIR}/profiles/reality.sh" >"${SCRIPT_COPY}"
    EASY_ALL_ENTRY_SCRIPT="${ROOT_DIR}/easy_all"
    EASY_ALL_ENTRY_COMMAND=easy_all
    # shellcheck source=/dev/null
    source "${SCRIPT_COPY}"
    MIHOMO_TEMPLATE_SOURCE="${ROOT_DIR}/templates/mihomo.yaml"
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
    REALITY_INBOUND_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV6=""
    REALITY_CLIENT_IP_FAMILY_RESOLVED=""
    SUB_PORT_MODE="dynamic"
    SUBSCRIPTION_MODE="deploy"
    SUBSCRIPTION_DOMAIN="sub.example.com"
    SUB_DOWNLOAD_NAME="MY_SUB"
    ALLOWED_TOKENS='{"owner":"test-token","friend":"friend-token"}'
}

test_syntax_and_worker_removal() {
    local script subscription_module
    bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}"/lib/*.sh
    script=$(<"${ROOT_DIR}/profiles/reality.sh")
    subscription_module=$(<"${ROOT_DIR}/lib/subscription-auth.sh")
    assert_not_contains "installer has no Worker API token" "CF_WORKER_API_TOKEN" "${script}"
    assert_not_contains "installer has no Worker deployment mode" "DEPLOY_MODE" "${script}"
    assert_not_contains "installer has no Worker file" "subscribe-worker.js" "${script}"
    assert_not_contains "installer has no Cloudflare API endpoint" \
        "api.cloudflare.com/client/v4" "${script}"
    assert_not_contains "installer has no sample Worker source" "sample-worker.js" "${script}"
    assert_success "root sample Worker was deleted" test ! -e "${ROOT_DIR}/sample-worker.js"
    assert_contains "Reality input collection is a separate stage" \
        "collect_reality_inputs()" "${script}"
    assert_contains "subscription input collection is a separate stage" \
        "collect_subscription_inputs()" "${script}"
    assert_contains "subscription deployment is a separate stage" \
        "deploy_subscription_output()" "${script}"
    assert_contains "Reality validates AAAA against detected server IPv6" \
        "的 AAAA \${mismatch} 未指向本机公网 IPv6" "${script}"
    assert_contains "Reality uses shared IPv4 direct outbounds" \
        'managed_outbounds=$(xray_direct_outbounds_json)' "${script}"
    assert_contains "Reality uses shared private-address blocking" \
        'managed_routing=$(xray_direct_routing_json)' "${script}"
    assert_contains "shared routing blocks cloud metadata before direct egress" \
        '"169.254.0.0/16"' "$(<"${ROOT_DIR}/lib/network.sh")"
    assert_contains "Reality validates its camouflage target with Xray" \
        'tls ping "${REALITY_TARGET}"' "${script}"
    assert_contains "Reality default prompts explain the enter default" \
        '[${default}]（直接回车使用默认值）' \
        "$(<"${ROOT_DIR}/lib/profile-common.sh")"
    assert_contains "Reality subscription prompt recommends self-hosting for one server" \
        "只有当前服务器时推荐" "${subscription_module}"
    assert_contains "Reality subscription prompt recommends node output for aggregation" \
        "多节点聚合或已有订阅服务器时推荐" "${subscription_module}"
    assert_contains "non-interactive uninstall requires FORCE" \
        "非交互卸载必须显式设置 FORCE=1" "${script}"
    assert_contains "Reality uninstall can preserve ACME state for reinstall" \
        'PRESERVE_ACME=1' "${script}"
    assert_contains "Reality uses the shared scheduled maintenance module" \
        'source "${SCRIPT_DIR}/scheduled-maintenance.sh"' "${script}"
    assert_contains "shared TCP tuning installs XanMod BBRv3 from the official source" \
        "https://dl.xanmod.org/archive.key" "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")"
    assert_contains "installer uses the shared TCP tuning module" \
        'source "${SCRIPT_DIR}/tcp-tuning.sh"' "${script}"
    assert_contains "shared TCP tuning persists Google BBR module loading" \
        "BBR_MODULES_CONFIG" "$(<"${ROOT_DIR}/lib/tcp-tuning.sh")"
}

test_validators_and_modes() {
    assert_success "Reality target accepts host and port" \
        validate_reality_target "www.cloudflare.com:443"
    assert_failure "Reality target requires port" \
        validate_reality_target "www.cloudflare.com"
    assert_equal "Reality defaults to dynamic subscriptions" \
        "dynamic" "${DEFAULT_REALITY_PORT_MODE}"
    assert_equal "Reality state schema records canonical subscription modes" \
        "5" "${STATE_SCHEMA_VERSION}"
    assert_equal "token dictionary is normalized" \
        '{"owner":"test-token"}' \
        "$(normalize_allowed_tokens '{" owner ":" test-token "}')"
    assert_success "compressed IPv6 is accepted" validate_ipv6 "2001:db8::10"
    assert_success "loopback IPv6 is accepted" validate_ipv6 "::1"
    assert_failure "multiple IPv6 compression markers are rejected" \
        validate_ipv6 "2001::db8::10"
    assert_failure "non-IPv6 text is rejected" validate_ipv6 "not-an-ip"

    SUBSCRIPTION_MODE="1"
    choose_subscription_mode
    assert_equal "choice 1 deploys the subscription service" "deploy" "${SUBSCRIPTION_MODE}"
    SUBSCRIPTION_MODE="2"
    choose_subscription_mode
    assert_equal "choice 2 selects links only" "link" "${SUBSCRIPTION_MODE}"

    SUBSCRIPTION_MODE="link"
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    assert_equal "update-sub keeps the current link mode by default" \
        "link" "${SUBSCRIPTION_MODE}"
    PROMPT_SUBSCRIPTION_MODE=0
}

test_reality_inbound_family_and_dns() {
    local detected
    detected=$(
        ip() {
            if [[ "$*" == "-6 -o addr show scope global" ]]; then
                printf '2: eth0 inet6 2001:db8::10/64 scope global\n'
            elif [[ "$*" == "-6 route show default" ]]; then
                printf 'default via 2001:db8::1 dev eth0\n'
            elif [[ "$*" == "-6 route get 2001:db8::10" ]]; then
                printf '2001:db8::10 dev eth0 src 2001:db8::10\n'
            fi
        }
        curl() { printf '2001:db8::10\n'; }
        detect_public_ipv6
    )
    assert_equal "public IPv6 detection requires and returns usable IPv6" \
        "2001:db8::10" "${detected}"

    detected=$(
        detect_public_ipv6() { printf '2001:db8::10\n'; }
        unset REALITY_INBOUND_IP_FAMILY VPS_PUBLIC_IPV6
        info() { :; }
        detect_reality_inbound_family
        printf '%s|%s\n' "${REALITY_INBOUND_IP_FAMILY}" "${VPS_PUBLIC_IPV6}"
    )
    assert_equal "detected public IPv6 enables Reality dual stack" \
        "dual|2001:db8::10" "${detected}"

    NODE_HOST="node.example.com"
    REALITY_INBOUND_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV4="203.0.113.10"
    VPS_PUBLIC_IPV6=""
    dig() {
        case " $* " in
        *" A "*) printf '203.0.113.10\n' ;;
        *" AAAA "*) printf '2001:db8::10\n' ;;
        esac
    }
    assert_failure "AAAA is rejected when the server has no public IPv6" \
        validate_reality_node_dns

    REALITY_INBOUND_IP_FAMILY="dual"
    VPS_PUBLIC_IPV6="2001:db8::10"
    assert_success "matching AAAA is accepted in dual-stack mode" \
        validate_reality_node_dns
    dig() {
        if [[ " $* " == *" A "* ]]; then
            [[ "$*" != *"@"* ]] || return 1
            printf '203.0.113.10\n'
        elif [[ " $* " == *" AAAA "* ]]; then
            printf '2001:db8::10\n'
        fi
    }
    assert_success "system DNS remains usable when public resolvers are blocked" \
        validate_reality_node_dns
    resolve_reality_client_ip_family
    assert_equal "matching VPS IPv6 and AAAA enable a dual-stack Reality endpoint" \
        "dual" "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    dig() {
        [[ " $* " != *" A "* ]] || printf '203.0.113.10\n'
    }
    resolve_reality_client_ip_family
    assert_equal "missing AAAA keeps the Reality endpoint on IPv4" \
        "ipv4" "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    dig() {
        case " $* " in
        *" A "*) printf '203.0.113.10\n' ;;
        *" AAAA "*) printf '2001:db8::20\n' ;;
        esac
    }
    assert_failure "mismatched AAAA is rejected in dual-stack mode" \
        validate_reality_node_dns
    resolve_reality_client_ip_family
    assert_equal "mismatched AAAA falls back to an IPv4 Reality endpoint" \
        "ipv4" "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    dig() {
        case " $* " in
        *" A "*) printf '203.0.113.20\n' ;;
        *" AAAA "*) printf '2001:db8::10\n' ;;
        esac
    }
    assert_failure "mismatched A is rejected for the fixed IPv4 client" \
        validate_reality_node_dns
    dig() {
        case " $* " in
        *" AAAA "*) printf '2001:db8::10\n' ;;
        esac
    }
    assert_failure "missing A is rejected for the fixed IPv4 client" \
        validate_reality_node_dns
    REALITY_INBOUND_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV6=""
    assert_success "Reality client family resolves safely without VPS IPv6" \
        validate_reality_client_ip_family_runtime
    assert_equal "Reality client family stays IPv4 without VPS IPv6" \
        "ipv4" "${REALITY_CLIENT_IP_FAMILY_RESOLVED}"
    unset VPS_PUBLIC_IPV4
    unset -f dig
}

test_reality_target_preflight() {
    local result
    assert_success "Reality target parser accepts a valid SNI TLS 1.3 handshake" \
        reality_tls_ping_succeeded <<'EOF'
Pinging without SNI
Handshake failure: remote error
-------------------
Pinging with SNI
Handshake succeeded
TLS Version: TLS 1.3
EOF
    assert_failure "Reality target parser rejects TLS 1.2" \
        reality_tls_ping_succeeded <<'EOF'
Pinging with SNI
Handshake succeeded
TLS Version: TLS 1.2
EOF
    assert_failure "Reality target parser rejects a failed SNI handshake" \
        reality_tls_ping_succeeded <<'EOF'
Pinging with SNI
Handshake failure: remote error
TLS Version: TLS 1.3
EOF
    result=$(
        detect_public_ipv4() { printf '203.0.113.10\n'; }
        resolve_reality_target_ipv4s() { printf '192.0.2.10\n'; }
        lookup_ip_asns() {
            [[ "$1" == "203.0.113.10" ]] && printf '64500\n' || printf '64501\n'
        }
        validate_reality_target_asn
    )
    assert_contains "Reality target warns when its ASN differs from the VPS" \
        "不同 ASN" "${result}"
    result=$(
        detect_public_ipv4() { printf '203.0.113.10\n'; }
        resolve_reality_target_ipv4s() { printf '192.0.2.10\n'; }
        lookup_ip_asns() { printf '64500\n'; }
        validate_reality_target_asn
    )
    assert_contains "Reality target confirms a matching VPS ASN" \
        "命中同 ASN" "${result}"
}

test_subscription_stage_dispatch() {
    local calls input_calls
    calls=$(
        deploy_subscription_service() { printf 'deploy\n'; }
        remove_subscription_service_runtime() { printf 'link\n'; }
        SUBSCRIPTION_MODE="deploy"
        deploy_subscription_output
        SUBSCRIPTION_MODE="link"
        deploy_subscription_output
    )
    assert_equal "subscription deployment dispatches exactly one selected branch" \
        $'deploy\nlink' "${calls}"

    input_calls=$(
        collect_subscription_domain() { printf 'domain\n'; }
        choose_subscription_download_name() { printf 'download:%s\n' "$1"; }
        choose_monthly_quota() { printf 'quota\n'; }
        quota_enabled() { return 0; }
        collect_deployed_subscription_inputs 0 0
    )
    assert_equal "apply reuses subscription inputs without reopening quota prompts" \
        $'domain\ndownload:0' "${input_calls}"

    input_calls=$(
        collect_subscription_domain() { printf 'domain\n'; }
        choose_subscription_download_name() { printf 'download:%s\n' "$1"; }
        choose_monthly_quota() { printf 'quota\n'; }
        quota_enabled() { return 0; }
        collect_deployed_subscription_inputs 1 1
    )
    assert_equal "interactive install collects all self-hosted subscription inputs" \
        $'domain\ndownload:1\nquota' "${input_calls}"
}

test_mihomo_template() {
    local invalid="${TMP_DIR}/invalid.yaml" rule_count
    validate_mihomo_template "${ROOT_DIR}/templates/mihomo.yaml"
    assert_contains "Mihomo races resolved proxy addresses" \
        "tcp-concurrent: true" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_contains "Mihomo uses the XFLASH fake-IP DNS mode" \
        "enhanced-mode: fake-ip" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_contains "Mihomo uses the XFLASH HTTP/3 DNS endpoint" \
        "https://223.6.6.6/dns-query#h3=true" \
        "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_contains "Mihomo uses the XFLASH proxy bootstrap DNS endpoints" \
        "proxy-server-nameserver: ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']" \
        "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_not_contains "Mihomo does not add a non-XFLASH default nameserver" \
        "default-nameserver:" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_not_contains "Mihomo does not add a non-XFLASH direct nameserver" \
        "direct-nameserver:" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_not_contains "Mihomo does not add the system resolver" \
        "- system" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    rule_count=$(sed -n '/^rules:/,$p' "${ROOT_DIR}/templates/mihomo.yaml" \
        | grep -Ec '^  - ')
    assert_equal "Mihomo template contains only the current XFLASH rules" \
        "162" "${rule_count}"
    assert_contains "Mihomo template uses the XFLASH rule-provider mirror" \
        "edgeone.gh-proxy.org" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_not_contains "Mihomo template omits the latency test group" \
        "name: 延迟测试" "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    assert_not_contains "Mihomo template omits latency test URLs" \
        "url: 'https://cp.cloudflare.com'" \
        "$(<"${ROOT_DIR}/templates/mihomo.yaml")"
    grep -v '^# EASY_ALL_PROXY_NAME$' \
        "${ROOT_DIR}/templates/mihomo.yaml" >"${invalid}"
    assert_failure "template rejects a missing proxy marker" \
        validate_mihomo_template "${invalid}"
}

test_subscription_generation() {
    local base64_file="${TMP_DIR}/base64.txt"
    local mihomo_file="${TMP_DIR}/mihomo.yaml"
    local decoded port yaml node_output expected_dynamic_port
    set_fixture
    expected_dynamic_port=$(dynamic_port_for_current_window)
    collect_installed_state() { :; }
    node_output=$(show_node)
    assert_contains "show node uses the current dynamic Reality port" \
        "@203.0.113.10:${expected_dynamic_port}?" "${node_output}"
    assert_contains "show node uses the same dynamic port in Mihomo" \
        "port: ${expected_dynamic_port}" "${node_output}"
    assert_equal "dynamic subscription port follows the current three-hour window" \
        "${expected_dynamic_port}" "$(generate_subscription_port)"
    assert_equal "dynamic subscription port is stable within the same window" \
        "${expected_dynamic_port}" "$(generate_subscription_port)"
    assert_success "dynamic port range excludes the additional SSH port" \
        bash -c '(( $1 < $2 ))' _ \
        "${DYNAMIC_PORT_MAX}" "${EASY_ALL_ADDITIONAL_SSH_PORT}"
    MIHOMO_TEMPLATE_FILE=""
    generate_subscription_files "${base64_file}" "${mihomo_file}"
    decoded=$(openssl base64 -d -A <"${base64_file}")
    yaml=$(<"${mihomo_file}")
    assert_contains "Base64 subscription contains Reality" "security=reality" "${decoded}"
    port=$(sed -E 's#.*@[^:]+:([0-9]+)\\?.*#\1#' <<<"${decoded}")
    assert_success "dynamic subscription port is in the redirected range" \
        bash -c '(( $1 >= $2 && $1 <= $3 ))' _ \
        "${port}" "${PORT_BASE}" "${DYNAMIC_PORT_MAX}"
    assert_contains "Mihomo subscription contains the same port" \
        "port: ${port}" "${yaml}"
    assert_contains "Mihomo subscription contains Reality options" \
        "reality-opts:" "${yaml}"
    assert_contains "IPv4-only Reality endpoint stays IPv4 in Mihomo" \
        "ip-version: ipv4" "${yaml}"
    assert_contains "Reality endpoint enables the Mihomo IPv6 master switch" \
        $'\nipv6: true\n' "${yaml}"
    assert_contains "Mihomo TUN bypasses CGNAT and overlay LAN addresses" \
        "100.64.0.0/10" "${yaml}"
    assert_not_contains "rendered DNS is not extended beyond XFLASH" \
        $'\n    ipv6: true\n' "${yaml}"
    assert_contains "Mihomo subscription contains XFLASH rules" \
        "DOMAIN,love.xflash.work,DIRECT" "${yaml}"
    assert_contains "Mihomo subscription contains XFLASH application rules" \
        "RULE-SET,applications,DIRECT" "${yaml}"
    assert_contains "Mihomo subscription keeps the XFLASH Telegram rule unchanged" \
        "RULE-SET,telegramcidr,PROXY" "${yaml}"
    assert_not_contains "Mihomo subscription omits the latency test group" \
        "name: 延迟测试" "${yaml}"
    assert_equal "Mihomo node participates only in the PROXY group" \
        "1" "$(grep -Fxc -- '        - "MY_REALITY"' "${mihomo_file}" | tr -d ' ')"
    assert_not_contains "Mihomo subscription does not override SSH port 22 routing" \
        "DST-PORT,22," "${yaml}"
    assert_not_contains "Mihomo subscription does not override SSH port 65533 routing" \
        "DST-PORT,65533," "${yaml}"
    assert_not_contains "rendered subscription removes proxy marker" \
        "EASY_ALL_PROXY_NODE" "${yaml}"

    SUB_PORT_MODE="443"
    node_output=$(show_node)
    assert_contains "show node uses fixed port 443 when selected" \
        "@203.0.113.10:443?" "${node_output}"
    assert_contains "show node uses fixed port 443 in Mihomo" \
        "port: 443" "${node_output}"
    generate_subscription_files "${base64_file}" "${mihomo_file}"
    decoded=$(openssl base64 -d -A <"${base64_file}")
    assert_contains "fixed subscription mode uses port 443" \
        "@203.0.113.10:443?" "${decoded}"

    NODE_HOST="node.example.com"
    REALITY_INBOUND_IP_FAMILY="dual"
    VPS_PUBLIC_IPV6="2001:db8::10"
    REALITY_CLIENT_IP_FAMILY_RESOLVED=""
    dig() { printf '2001:db8::10\n'; }
    generate_subscription_files "${base64_file}" "${mihomo_file}"
    yaml=$(<"${mihomo_file}")
    assert_contains "matching node AAAA keeps automatic dual-stack endpoint" \
        "ip-version: dual" "${yaml}"
    assert_contains "dual-stack endpoint keeps Mihomo IPv6 enabled" \
        $'\nipv6: true\n' "${yaml}"
    assert_not_contains "dual-stack endpoint keeps XFLASH DNS unchanged" \
        $'\n    ipv6: true\n' "${yaml}"
    unset -f dig
    unset -f collect_installed_state
}

test_nginx_and_firewall() {
    local config ufw_config ufw6_config ufw_log="${TMP_DIR}/ufw.log" dynamic_rule_count dynamic_rule6_count
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

    ensure_ssh_boot_service() { return 0; }
    ensure_ssh_fail2ban() { printf 'fail2ban-sshd\n' >>"${ufw_log}"; }
    detect_ssh_ports() { SSH_PORTS="22 65533"; }
    apply_managed_ufw_tcp_ports() {
        printf 'managed-ports %s\n' "$1" >>"${ufw_log}"
    }
    ufw() {
        if [[ "${1:-}" == "status" ]]; then
            printf 'Status: active\n'
        else
            printf '%s\n' "$*" >>"${ufw_log}"
        fi
    }
    iptables-restore() { cat >/dev/null; }
    ip6tables-restore() { cat >/dev/null; }
    cat >"${UFW_BEFORE_RULES}" <<'EOF'
*filter
:ufw-before-input - [0:0]
COMMIT
EOF
    cat >"${UFW_BEFORE6_RULES}" <<'EOF'
*filter
:ufw6-before-input - [0:0]
COMMIT
EOF
    printf 'IPV6=no\n' >"${UFW_DEFAULT_CONFIG}"
    SUBSCRIPTION_MODE="deploy"
    REALITY_INBOUND_IP_FAMILY="dual"
    VPS_PUBLIC_IPV6="2001:db8::10"
    configure_ufw
    ufw_config=$(<"${UFW_BEFORE_RULES}")
    ufw6_config=$(<"${UFW_BEFORE6_RULES}")
    assert_contains "self-hosting opens HTTP" \
        "managed-ports 22 65533 443 80 8443" "$(<"${ufw_log}")"
    assert_contains "self-hosting opens 8443" \
        "managed-ports 22 65533 443 80 8443" "$(<"${ufw_log}")"
    assert_contains "Reality enables shared Fail2ban after UFW" \
        "fail2ban-sshd" "$(<"${ufw_log}")"
    dynamic_rule_count=$(grep -Ec -- '^-A PREROUTING -p tcp --dport [0-9]+ -j REDIRECT --to-ports 443$' <<<"${ufw_config}")
    dynamic_rule6_count=$(grep -Ec -- '^-A PREROUTING -p tcp --dport [0-9]+ -j REDIRECT --to-ports 443$' <<<"${ufw6_config}")
    assert_equal "dynamic Reality forwarding retains history and pre-opens today and tomorrow" \
        "${DYNAMIC_PORT_OPEN_WINDOWS}" "${dynamic_rule_count}"
    assert_equal "dynamic Reality forwarding retains history and pre-opens today and tomorrow for IPv6" \
        "${DYNAMIC_PORT_OPEN_WINDOWS}" "${dynamic_rule6_count}"
    assert_contains "dynamic Reality forwarding includes the current port" \
        "--dport $(dynamic_port_for_current_window) -j REDIRECT --to-ports ${SERVICE_PORT}" \
        "${ufw_config}"

    SUB_PORT_MODE="443"
    write_ufw_nat_rules
    ufw_config=$(<"${UFW_BEFORE_RULES}")
    ufw6_config=$(<"${UFW_BEFORE6_RULES}")
    assert_equal "fixed Reality mode removes IPv4 dynamic NAT rules" "0" \
        "$(grep -Ec -- '^-A PREROUTING -p tcp --dport [0-9]+ -j REDIRECT --to-ports 443$' <<<"${ufw_config}")"
    assert_equal "fixed Reality mode removes IPv6 dynamic NAT rules" "0" \
        "$(grep -Ec -- '^-A PREROUTING -p tcp --dport [0-9]+ -j REDIRECT --to-ports 443$' <<<"${ufw6_config}")"
    assert_not_contains "fixed Reality mode does not retain a dynamic port" \
        "--dport ${PORT_BASE} -j REDIRECT" "${ufw_config}"
    assert_contains "dual-stack Reality enables UFW IPv6" \
        "IPV6=yes" "$(<"${UFW_DEFAULT_CONFIG}")"
    assert_contains "Reality reloads UFW after writing NAT rules" \
        "reload" "$(<"${ufw_log}")"
    unset -f nginx systemctl ensure_ssh_boot_service ensure_ssh_fail2ban detect_ssh_ports apply_managed_ufw_tcp_ports ufw \
        iptables-restore ip6tables-restore
}

test_dynamic_port_year_boundary() {
    local rules rule_count
    set_fixture
    date() {
        case "$*" in
        +%j) printf '001\n' ;;
        +%H) printf '00\n' ;;
        +%Y) printf '2026\n' ;;
        *) return 1 ;;
        esac
    }
    rules=$(write_dynamic_nat_rules)
    rule_count=$(grep -Ec -- '^-A PREROUTING -p tcp --dport [0-9]+ -j REDIRECT --to-ports 443$' <<<"${rules}")
    assert_equal "dynamic NAT keeps history and pre-opens across a year boundary" \
        "${DYNAMIC_PORT_OPEN_WINDOWS}" "${rule_count}"
    assert_contains "dynamic NAT keeps the last port from the previous year" \
        "--dport 12919 -j REDIRECT --to-ports ${SERVICE_PORT}" "${rules}"
    assert_contains "dynamic NAT pre-opens the next day's 00:00 port" \
        "--dport 10008 -j REDIRECT --to-ports ${SERVICE_PORT}" "${rules}"
    assert_contains "dynamic NAT pre-opens the next day's 03:00 port" \
        "--dport 10009 -j REDIRECT --to-ports ${SERVICE_PORT}" "${rules}"
    assert_not_contains "dynamic NAT does not pre-open the next day's 06:00 port" \
        "--dport 10010 -j REDIRECT --to-ports ${SERVICE_PORT}" "${rules}"
    unset -f date
}

test_dynamic_port_boundaries_and_rule_set() {
    local rules rule_ports rule_count unique_count minimum maximum
    local mock_day=1 mock_hour=2 mock_year=2026
    set_fixture
    date() {
        case "$*" in
        +%j) printf '%03d\n' "${mock_day}" ;;
        +%H) printf '%02d\n' "${mock_hour}" ;;
        +%Y) printf '%04d\n' "${mock_year}" ;;
        *) return 1 ;;
        esac
    }
    assert_equal "dynamic port remains in the first window before 03:00" \
        "10000" "$(dynamic_port_for_current_window)"
    mock_hour=3
    assert_equal "dynamic port advances at 03:00" \
        "10001" "$(dynamic_port_for_current_window)"
    mock_day=2
    mock_hour=0
    assert_equal "dynamic port advances at the next day's 00:00" \
        "10008" "$(dynamic_port_for_current_window)"

    mock_year=2028
    mock_day=366
    mock_hour=21
    assert_equal "leap-year final window reaches the configured upper bound" \
        "${DYNAMIC_PORT_MAX}" "$(dynamic_port_for_current_window)"
    rules=$(write_dynamic_nat_rules)
    rule_ports=$(grep -E -- '^-A PREROUTING -p tcp --dport [0-9]+ -j REDIRECT --to-ports 443$' <<<"${rules}" \
        | awk '{print $6}')
    rule_count=$(wc -l <<<"${rule_ports}" | tr -d ' ')
    unique_count=$(sort -n -u <<<"${rule_ports}" | wc -l | tr -d ' ')
    minimum=$(sort -n <<<"${rule_ports}" | head -n1)
    maximum=$(sort -n <<<"${rule_ports}" | tail -n1)
    assert_equal "dynamic NAT rule set has the configured number of entries" \
        "${DYNAMIC_PORT_OPEN_WINDOWS}" "${rule_count}"
    assert_equal "dynamic NAT rule set has no duplicate ports" \
        "${rule_count}" "${unique_count}"
    assert_equal "dynamic NAT rule set starts at the base port" "${PORT_BASE}" "${minimum}"
    assert_equal "dynamic NAT rule set stays below the reserved upper bound" \
        "${DYNAMIC_PORT_MAX}" "${maximum}"
    unset -f date
}

test_rotate_dynamic_ports_command() {
    local calls=""
    set_fixture
    require_root() { :; }
    collect_installed_state() { :; }
    write_ufw_nat_rules() { calls+="write "; }
    ufw() { calls+="reload "; }
    rotate_dynamic_ports
    assert_equal "dynamic port rotation writes and reloads UFW" "write reload " "${calls}"

    calls=""
    SUB_PORT_MODE="443"
    rotate_dynamic_ports
    assert_equal "fixed port rotation is a no-op" "" "${calls}"

    SUB_PORT_MODE="dynamic"
    if (ufw() { return 1; }; rotate_dynamic_ports) >/dev/null 2>&1; then
        fail_test "dynamic port rotation must fail when UFW reload fails"
    fi
    unset -f require_root collect_installed_state write_ufw_nat_rules ufw
}

test_scheduled_reboot_refreshes_dynamic_ports() {
    local cron_state_file="${TMP_DIR}/reboot.cron" cron_state
    : >"${cron_state_file}"
    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            cat "${cron_state_file}"
        elif [[ "${1:-}" == "-" ]]; then
            cat >"${cron_state_file}"
        else
            cat "$1" >"${cron_state_file}"
        fi
    }
    REBOOT_SCHEDULE_MODE=1
    configure_daily_reboot
    cron_state=$(<"${cron_state_file}")
    assert_contains "daily Reality reboot refreshes dynamic NAT first" \
        "rotate-dynamic-ports" "${cron_state}"
    assert_contains "daily Reality reboot remains scheduled" \
        "/usr/sbin/reboot" "${cron_state}"
    unset REBOOT_SCHEDULE_MODE
    unset -f crontab
}

test_dynamic_port_rotation_schedule() {
    local cron_state_file="${TMP_DIR}/dynamic-port.cron" cron_state
    : >"${cron_state_file}"
    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            cat "${cron_state_file}"
        elif [[ "${1:-}" == "-" ]]; then
            cat >"${cron_state_file}"
        else
            cat "$1" >"${cron_state_file}"
        fi
    }
    configure_dynamic_port_rotation
    cron_state=$(<"${cron_state_file}")
    assert_contains "dynamic port rotation runs daily after midnight" \
        "1 0 * * *" "${cron_state}"
    assert_contains "dynamic port rotation calls the managed command" \
        "rotate-dynamic-ports" "${cron_state}"
    SUB_PORT_MODE="443"
    configure_dynamic_port_rotation
    cron_state=$(<"${cron_state_file}")
    assert_not_contains "fixed port mode does not install dynamic rotation" \
        "rotate-dynamic-ports" "${cron_state}"
    remove_dynamic_port_rotation
    cron_state=$(<"${cron_state_file}")
    assert_not_contains "dynamic port rotation can be removed" \
        "rotate-dynamic-ports" "${cron_state}"
    unset -f crontab
}

test_dynamic_port_rotation_rollback() {
    local cron_state_file="${TMP_DIR}/dynamic-port-rollback.cron"
    local cron_state snapshot_state
    install -d -m 0700 "${STATE_DIR}"
    printf 'before-state\n' >"${STATE_FILE}"
    printf 'before-ufw\n' >"${UFW_BEFORE_RULES}"
    printf 'before-ufw6\n' >"${UFW_BEFORE6_RULES}"
    printf 'before-default\n' >"${UFW_DEFAULT_CONFIG}"
    cat >"${cron_state_file}" <<EOF
15 2 * * * /usr/local/bin/user-job
1 0 * * * /usr/local/bin/easy_all rotate-dynamic-ports ${CRON_DYNAMIC_PORT_MARKER}
EOF
    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            cat "${cron_state_file}"
        elif [[ "${1:-}" == "-" ]]; then
            cat >"${cron_state_file}"
        else
            cat "$1" >"${cron_state_file}"
        fi
    }
    snapshot_subscription_update
    snapshot_state="${UPDATE_SUB_BACKUP_DIR}"
    printf 'after-state\n' >"${STATE_FILE}"
    printf 'after-ufw\n' >"${UFW_BEFORE_RULES}"
    printf 'after-ufw6\n' >"${UFW_BEFORE6_RULES}"
    printf 'after-default\n' >"${UFW_DEFAULT_CONFIG}"
    cat >"${cron_state_file}" <<EOF
15 2 * * * /usr/local/bin/user-job
30 3 * * * /usr/local/bin/concurrent-job
1 0 * * * /usr/local/bin/easy_all rotate-dynamic-ports ${CRON_DYNAMIC_PORT_MARKER}
EOF
    systemctl() { :; }
    nginx() { :; }
    source_state_file() { SUBSCRIPTION_MODE="link"; }
    configure_ufw() { :; }
    rollback_subscription_update
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    cron_state=$(<"${cron_state_file}")
    assert_contains "subscription rollback restores the previous managed schedule" \
        "1 0 * * * /usr/local/bin/easy_all rotate-dynamic-ports" "${cron_state}"
    assert_contains "subscription rollback preserves concurrent unmanaged schedules" \
        "30 3 * * * /usr/local/bin/concurrent-job" "${cron_state}"
    assert_contains "subscription rollback preserves unrelated schedules" \
        "15 2 * * * /usr/local/bin/user-job" "${cron_state}"
    assert_equal "subscription rollback restores state" "before-state" \
        "$(<"${STATE_FILE}")"
    assert_equal "subscription rollback restores IPv4 UFW rules" "before-ufw" \
        "$(<"${UFW_BEFORE_RULES}")"
    assert_equal "subscription rollback restores IPv6 UFW rules" "before-ufw6" \
        "$(<"${UFW_BEFORE6_RULES}")"
    assert_equal "subscription rollback restores UFW defaults" "before-default" \
        "$(<"${UFW_DEFAULT_CONFIG}")"
    [[ -d "${snapshot_state}" ]] || fail_test "subscription rollback snapshot was removed too early"
    unset -f crontab systemctl nginx source_state_file configure_ufw
    unset UPDATE_SUB_BACKUP_DIR
}

test_ufw_reapply_preserves_existing_ssh() {
    local state="${TMP_DIR}/ufw-state" state_text ssh_count
    set_fixture
    cat >"${state}" <<'EOF'
22/tcp|ALLOW IN|Anywhere|easy_all-managed
8443/tcp|ALLOW IN|Anywhere|easy_all-managed
80/tcp|ALLOW IN|Anywhere|debian-init-managed
9999/tcp|ALLOW IN|Anywhere|user-rule
EOF
    ufw() {
        local endpoint number temp="${state}.new"
        if [[ "${1:-}" == "status" && "${2:-}" == "numbered" ]]; then
            printf 'Status: active\n'
            awk -F'|' '{printf "[ %d] %s %s %s # %s\n", NR, $1, $2, $3, $4}' "${state}"
            return 0
        fi
        if [[ "${1:-}" == "allow" ]]; then
            endpoint=$2
            if awk -F'|' -v endpoint="${endpoint}" \
                '$1 == endpoint && $2 == "ALLOW IN" {found=1} END {exit(found ? 0 : 1)}' \
                "${state}"; then
                return 0
            fi
            printf '%s|ALLOW IN|Anywhere|%s\n' "${endpoint}" "${4:-}" >>"${state}"
            return 0
        fi
        if [[ "${1:-}" == "--force" && "${2:-}" == "delete" ]]; then
            number=$3
            awk -v number="${number}" 'NR != number' "${state}" >"${temp}"
            mv "${temp}" "${state}"
            return 0
        fi
        [[ "${1:-}" == "--force" && "${2:-}" == "enable" ]] && return 0
        [[ "${1:-}" == "reload" ]] && return 0
        return 1
    }

    apply_managed_ufw_tcp_ports "22 80 443"
    apply_managed_ufw_tcp_ports "22 80 443"
    state_text=$(<"${state}")
    ssh_count=$(awk -F'|' '$1 == "22/tcp" && $2 == "ALLOW IN" {count++} END {print count+0}' "${state}")
    assert_equal "Reality UFW reapply keeps exactly one SSH allow rule" "1" "${ssh_count}"
    assert_contains "Reality UFW reapply keeps the existing managed SSH rule" \
        "22/tcp|ALLOW IN|Anywhere|easy_all-managed" "${state_text}"
    assert_contains "Reality UFW accepts an existing external HTTP allow rule" \
        "80/tcp|ALLOW IN|Anywhere|debian-init-managed" "${state_text}"
    assert_contains "Reality UFW adds a missing service rule" \
        "443/tcp|ALLOW IN|Anywhere|easy_all-managed" "${state_text}"
    assert_not_contains "Reality UFW removes only a stale managed rule" \
        "8443/tcp|ALLOW IN|Anywhere|easy_all-managed" "${state_text}"
    assert_contains "Reality UFW preserves unrelated user rules" \
        "9999/tcp|ALLOW IN|Anywhere|user-rule" "${state_text}"
    unset -f ufw
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

    install -d -m 0700 "${ACME_HOME}/old.example.com_ecc" \
        "${ACME_HOME}/current.example.com_ecc"
    retire_managed_acme_domain "old.example.com"
    assert_success "retiring an old subscription domain removes only its ACME renewal entry" \
        test ! -e "${ACME_HOME}/old.example.com_ecc"
    assert_success "retiring an old subscription domain preserves the current ACME entry" \
        test -d "${ACME_HOME}/current.example.com_ecc"
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

test_secure_download_transport() {
    local destination="${TMP_DIR}/wget-download.test" wget_call=""
    timeout() {
        [[ "${1:-}" == "10m" ]] || return 1
        shift
        "$@"
    }
    wget() {
        local output="" arg
        wget_call="$*"
        while (($#)); do
            arg=$1
            shift
            if [[ "${arg}" == "-O" ]]; then
                output=$1
                shift
            fi
        done
        [[ -n "${output}" ]] || return 1
        printf '%s\n' payload >"${output}"
    }

    download_https_file "https://github.com/example/archive" "${destination}" \
        "测试文件"
    assert_contains "downloads require HTTPS-only redirects" \
        "--https-only" "${wget_call}"
    assert_contains "downloads require TLS 1.2 or newer" \
        "--secure-protocol=TLSv1_2" "${wget_call}"
    assert_contains "downloads retry transient connection failures" \
        "--retry-connrefused" "${wget_call}"
    assert_contains "downloads detect stalled reads" \
        "--read-timeout=45" "${wget_call}"
    assert_success "download helper writes a non-empty destination" \
        test -s "${destination}"
    unset -f timeout wget

    local common_source xray_source xhttp_source
    common_source=$(<"${ROOT_DIR}/lib/profile-common.sh")
    xray_source=$(<"${ROOT_DIR}/lib/xray-core.sh")
    xhttp_source=$(<"${ROOT_DIR}/lib/xhttp-runtime.sh")
    assert_not_contains "acme installation no longer uses get.acme.sh" \
        "get.acme.sh" "${common_source}${xhttp_source}"
    assert_not_contains "Xray downloads no longer use curl" \
        "curl " "${xray_source}"
    assert_contains "acme downloads are restricted to its official GitHub repo" \
        "api.github.com/repos/acmesh-official/acme.sh" "${common_source}"
    assert_contains "Xray downloads are restricted to official release URLs" \
        "github.com/XTLS/Xray-core/releases/download" "${xray_source}"
}

test_state_and_xray() {
    local state config
    install -d -m 0700 "${STATE_DIR}"
    set_fixture
    save_state
    state=$(<"${STATE_FILE}")
    assert_contains "state persists subscription mode" \
        "SUBSCRIPTION_MODE=deploy" "${state}"
    assert_contains "state persists subscription domain" \
        "SUBSCRIPTION_DOMAIN=sub.example.com" "${state}"
    assert_contains "state persists Reality inbound family" \
        "REALITY_INBOUND_IP_FAMILY=ipv4" "${state}"
    assert_not_contains "state omits the derived Reality client endpoint family" \
        "REALITY_CLIENT_IP_FAMILY=auto" "${state}"
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
    write_xray_config
    config=$(<"${XRAY_CONFIG}")
    assert_success "Xray uses Reality Vision" \
        jq -e \
        '.inbounds[0].listen == "0.0.0.0"
         and .inbounds[0].streamSettings.security == "reality"
         and .inbounds[0].streamSettings.sockopt.tcpKeepAliveIdle == 300
         and .inbounds[0].streamSettings.sockopt.tcpKeepAliveInterval == 30
         and .inbounds[0].settings.clients[0].flow == "xtls-rprx-vision"' \
        <<<"${config}"
    assert_success "Xray blocks private and metadata destinations" \
        jq -e \
        '.routing.domainStrategy == "IPOnDemand"
         and (.outbounds[] | select(.tag == "block").protocol) == "blackhole"
         and (.routing.rules[] | select(.outboundTag == "block").ip
             | index("169.254.0.0/16"))' \
        <<<"${config}"
    assert_success "Xray uses dual-stack direct egress and fixed IPv4 for Gemini" \
        jq -e \
        '(.outbounds | map(.tag)) == ["direct","direct-ipv4","block"]
         and .outbounds[0].settings.domainStrategy == "AsIs"
         and .outbounds[1].settings.domainStrategy == "ForceIPv4"
         and (.routing.rules[1].domain | index("domain:gemini.google.com"))
         and .routing.rules[1].outboundTag == "direct-ipv4"
         and .routing.rules[-1]
             == {type:"field",network:"tcp,udp",outboundTag:"direct"}' \
        <<<"${config}"

    REALITY_INBOUND_IP_FAMILY="dual"
    VPS_PUBLIC_IPV6="2001:db8::10"
    write_xray_config
    config=$(<"${XRAY_CONFIG}")
    assert_success "dual-stack Reality listens on IPv4 and IPv6" \
        jq -e \
        '.inbounds[0].listen == "::"
         and .outbounds[0].settings.domainStrategy == "AsIs"
         and .outbounds[1].settings.domainStrategy == "ForceIPv4"' \
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

test_install_pipeline_order() {
    local calls
    rm -f -- "${STATE_FILE}"
    calls=$(
        info() { :; }
        success() { :; }
        require_root() { printf 'root\n'; }
        require_systemd() { printf 'systemd\n'; }
        check_platform() { printf 'platform\n'; }
        choose_protocol() { PROTOCOL="reality"; printf 'protocol\n'; }
        check_install_conflicts() { printf 'conflicts\n'; }
        snapshot_fresh_install() { printf 'snapshot\n'; INSTALL_ROLLBACK_ON_EXIT=1; }
        install_packages() { printf 'packages\n'; }
        initialize_server() { printf 'initialize\n'; }
        collect_reality_inputs() { printf 'reality-inputs\n'; }
        collect_subscription_inputs() {
            SUB_PORT_MODE="dynamic"
            printf 'subscription-inputs:%s:%s\n' "$1" "$2"
        }
        prepare_protocol_assets() { printf 'assets\n'; }
        configure_ufw() { printf 'ufw\n'; }
        install_protocol_runtime() { printf 'runtime\n'; }
        validate_protocol_runtime() { printf 'validate-runtime\n'; }
        deploy_subscription_output() { printf 'subscription-runtime\n'; }
        save_state() { printf 'save\n'; }
        register_easy_all_command() { printf 'register\n'; }
        rotate_dynamic_ports() { printf 'dynamic-port-refresh\n'; }
        configure_dynamic_port_rotation() { printf 'dynamic-port-schedule\n'; }
        install_quota_timer() { printf 'quota-timer\n'; }
        show_subscription() { printf 'show\n'; }
        show_bbrv3_status() { printf 'bbrv3\n'; }
        run_reality_install_pipeline "reality" 1
    )
    assert_equal "Reality install pipeline follows input, common runtime, branch, persistence order" \
        $'root\nsystemd\nplatform\nprotocol\nconflicts\nsnapshot\npackages\ninitialize\nreality-inputs\nsubscription-inputs:1:1\nassets\nufw\nruntime\nvalidate-runtime\nsubscription-runtime\nsave\nregister\ndynamic-port-refresh\ndynamic-port-schedule\nquota-timer\nshow\nbbrv3' \
        "${calls}"
}

source_script_copy
test_syntax_and_worker_removal
test_validators_and_modes
test_reality_inbound_family_and_dns
test_reality_target_preflight
test_subscription_stage_dispatch
test_mihomo_template
test_subscription_generation
test_ufw_reapply_preserves_existing_ssh
test_nginx_and_firewall
test_dynamic_port_year_boundary
test_dynamic_port_boundaries_and_rule_set
test_rotate_dynamic_ports_command
test_scheduled_reboot_refreshes_dynamic_ports
test_dynamic_port_rotation_schedule
test_dynamic_port_rotation_rollback
test_acme_renewal_repair
test_acme_reinstall_and_rate_limit_guidance
test_secure_download_transport
test_state_and_xray
test_install_pipeline_order

printf 'ok - easy_all shell tests passed (%s assertions)\n' "${TESTS_RUN}"
