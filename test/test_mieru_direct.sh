#!/usr/bin/env bash

# Behaviour tests for the Mieru direct profile. Real system services are
# stubbed; only the profile logic, config rendering and state handling run.

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d)
PROFILE_COPY="${TMP_DIR}/profiles/mieru.test.sh"
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

prepare_profile_copy() {
    local module
    install -d -m 0755 "${TMP_DIR}/profiles" "${TMP_DIR}/lib" \
        "${TMP_DIR}/state" "${TMP_DIR}/cmd"
    for module in log.sh runtime-core.sh quota.sh platform.sh profile-common.sh \
        network.sh mihomo-template.sh firewall.sh xray-core.sh \
        scheduled-maintenance.sh subscription-auth.sh worker-config.sh tcp-tuning.sh; do
        install -m 0644 "${ROOT_DIR}/lib/${module}" "${TMP_DIR}/lib/${module}"
    done
    sed \
        -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${TMP_DIR}/state\"|" \
        -e "s|^readonly BACKUP_DIR=.*|readonly BACKUP_DIR=\"${TMP_DIR}/state/backups\"|" \
        -e "s|^readonly STATE_FILE=.*|readonly STATE_FILE=\"${TMP_DIR}/state/state.env\"|" \
        -e "s|^readonly MIERU_DIR=.*|readonly MIERU_DIR=\"${TMP_DIR}/state/mieru\"|" \
        -e "s|^readonly MIERU_SERVER_CONFIG=.*|readonly MIERU_SERVER_CONFIG=\"${TMP_DIR}/state/mieru/server_config.json\"|" \
        -e "s|^readonly MIERU_CLIENT_CONFIG=.*|readonly MIERU_CLIENT_CONFIG=\"${TMP_DIR}/state/mieru/client_config.json\"|" \
        -e "s|^readonly XRAY_DIR=.*|readonly XRAY_DIR=\"${TMP_DIR}/state/xray\"|" \
        -e "s|^readonly XRAY_BIN=.*|readonly XRAY_BIN=\"${TMP_DIR}/state/xray/xray\"|" \
        -e "s|^readonly XRAY_CONFIG=.*|readonly XRAY_CONFIG=\"${TMP_DIR}/state/xray/config.json\"|" \
        -e "s|^readonly COMMAND_INSTALL_DIR=.*|readonly COMMAND_INSTALL_DIR=\"${TMP_DIR}/cmd\"|" \
        -e "s|^readonly COMMAND_PATH=.*|readonly COMMAND_PATH=\"${TMP_DIR}/cmd/easy_all\"|" \
        -e "s|^readonly UFW_BEFORE_RULES=.*|readonly UFW_BEFORE_RULES=\"${TMP_DIR}/before.rules\"|" \
        -e "s|^readonly UFW_BEFORE6_RULES=.*|readonly UFW_BEFORE6_RULES=\"${TMP_DIR}/before6.rules\"|" \
        -e "s|^readonly UFW_DEFAULT_CONFIG=.*|readonly UFW_DEFAULT_CONFIG=\"${TMP_DIR}/ufw-default\"|" \
        -e "s|^readonly IPV6_SYSCTL_CONF=.*|readonly IPV6_SYSCTL_CONF=\"${TMP_DIR}/99-enable-ipv6.conf\"|" \
        "${ROOT_DIR}/profiles/mieru-direct.sh" >"${PROFILE_COPY}"
}

setup_stubs() {
    export MITA_LOG="${TMP_DIR}/mita.log"
    export DPKG_LOG="${TMP_DIR}/dpkg.log"
    export SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"
    export TEST_PATTERN="CCoQARoECAEQCiIYCAMQASoIMDAwMTAyMDMqCDA0MDUwNjA3"
    export TEST_DIGEST_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
    export TEST_ACTUAL_SHA="${TEST_DIGEST_SHA}"

    mita() {
        printf '%s\n' "$*" >>"${MITA_LOG}"
        case "${1:-}" in
        version) printf '3.39.0\n' ;;
        status) printf 'mita server status is "RUNNING"\n' ;;
        export)
            [[ "${2:-}" == "traffic-pattern" ]] || return 1
            printf '%s\n' "${TEST_PATTERN}"
            ;;
        apply)
            [[ -f "${3:-}" ]] || return 1
            jq -e . "${3}" >/dev/null
            ;;
        start | stop) return 0 ;;
        *) return 0 ;;
        esac
    }
    dpkg() {
        printf '%s\n' "$*" >>"${DPKG_LOG}"
        case "${1:-}" in
        -s) [[ "${2:-}" == "mita" && "${MITA_PACKAGE_INSTALLED:-0}" == "1" ]] ;;
        -i | --purge) return 0 ;;
        *) return 0 ;;
        esac
    }
    systemctl() {
        printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
        return 0
    }
    apt-get() { return 0; }
    timedatectl() { return 0; }
    ufw() { return 0; }
    crontab() {
        if [[ "${1:-}" == "-l" ]]; then
            cat "${TMP_DIR}/crontab"
            return 0
        fi
        cat >"${TMP_DIR}/crontab"
    }
    ss() { return 0; }
    curl() { return 0; }
    sleep() { :; }
    iptables-restore() { cat >/dev/null; return 0; }
    ip6tables-restore() { cat >/dev/null; return 0; }
    printf '%s\n' '# user cron' >"${TMP_DIR}/crontab"
    sha256sum() { printf '%s  %s\n' "${TEST_ACTUAL_SHA}" "$1"; }
}

source_profile() {
    # shellcheck source=/dev/null
    source "${PROFILE_COPY}"
}

set_fixture() {
    install -d -m 0700 "${TMP_DIR}/state"
    PROTOCOL="mieru"
    TCP_ACCELERATION="bbrv3"
    NODE_NAME="MY_MIERU"
    NODE_HOST="203.0.113.10"
    MIERU_PORT="2090"
    MIERU_PORT_RANGE="50000-50512"
    MIERU_USER_NAME="testuser12345678"
    MIERU_USER_PASSWORD="test-password-0123456789abcdef"
    MIERU_VERSION="3.39.0"
    MIERU_CLIENT_SOCKS5_PORT="1080"
    MIERU_CLIENT_HTTP_PORT="8080"
    MIERU_CLIENT_RPC_PORT="4321"
    MIERU_TRAFFIC_SEED="12345"
    MIERU_TRAFFIC_PATTERN="${TEST_PATTERN}"
    VPS_IP_FAMILY="ipv4"
    VPS_PUBLIC_IPV6=""
    GOOGLE_EGRESS_MODE="ipv4"
    GOOGLE_EGRESS_RESOLVED="ipv4"
    SCHEDULED_REBOOT_ENABLED="0"
    SCHEDULED_REBOOT_HOUR=""
}

test_syntax_and_wiring() {
    local launcher manifest
    bash -n "${ROOT_DIR}/profiles/mieru-direct.sh"
    launcher=$(<"${ROOT_DIR}/easy_all")
    manifest=$(<"${ROOT_DIR}/runtime.manifest")
    assert_contains "launcher maps the Mieru protocol" 'mieru)' "${launcher}"
    assert_contains "launcher registers the Mieru profile" \
        'mieru-direct) candidate="${EASY_ALL_ROOT}/profiles/mieru-direct.sh"' "${launcher}"
    assert_contains "launcher exposes the Mieru menu entry" \
        '4. 直连 - Mieru' "${launcher}"
    assert_contains "launcher enforces the Mieru state version" \
        'MIERU_MIN_STATE_VERSION' "${launcher}"
    assert_contains "launcher routes mita core updates" \
        'mieru-direct) update_mieru_core' "${launcher}"
    assert_contains "launcher allows port-range NAT refresh for Mieru" \
        'reality | trojan-direct | mieru-direct) rotate_dynamic_ports' "${launcher}"
    assert_contains "runtime manifest ships the Mieru profile" \
        'profiles/mieru-direct.sh' "${manifest}"
}

check_port_80() ( MIERU_PORT=80; collect_mieru_port )
check_port_abc() ( MIERU_PORT=abc; collect_mieru_port )
check_invalid_host() ( NODE_HOST="not a domain"; collect_mieru_node_host )
normalize_domain_host() { NODE_HOST="Node.Example.COM."; collect_mieru_node_host; }
check_busy_port() ( mita_listening_on_port() { return 0; }; MIERU_PORT=2090; collect_mieru_port )
check_reversed_range() ( MIERU_PORT_RANGE="50512-50000"; mieru_validate_port_range_state )
check_privileged_range() ( MIERU_PORT_RANGE="80-90"; mieru_validate_port_range_state )

test_input_validation() {
    local generated
    MIERU_PORT="2090"
    collect_mieru_port
    assert_equal "port accepts a high port" "2090" "${MIERU_PORT}"
    assert_failure "port rejects 80" check_port_80
    assert_failure "port rejects a non-numeric value" check_port_abc
    assert_failure "port rejects an occupied port" check_busy_port
    MIERU_PORT_RANGE="50000-50512"
    mieru_validate_port_range_state
    assert_failure "port range rejects a reversed range" check_reversed_range
    assert_failure "port range rejects a privileged range" check_privileged_range
    MIERU_PORT_RANGE="50000-50512"
    MIERU_PORT=""
    MIERU_USER_NAME=""
    MIERU_USER_PASSWORD=""
    collect_mieru_credentials
    generated=${MIERU_USER_NAME}
    [[ "${generated}" =~ ^[A-Za-z0-9._~-]{1,64}$ ]] \
        || fail_test "generated user name does not match the allowed charset"
    TESTS_RUN=$((TESTS_RUN + 1))
    generated=${MIERU_USER_PASSWORD}
    [[ "${generated}" =~ ^[A-Za-z0-9._~-]{8,64}$ ]] \
        || fail_test "generated password does not match the allowed charset"
    TESTS_RUN=$((TESTS_RUN + 1))
    assert_not_contains "generated password avoids shell metacharacters" \
        "'" "${generated}"
    MIERU_CLIENT_RPC_PORT=""
    collect_mieru_client_ports
    [[ "${MIERU_CLIENT_RPC_PORT}" =~ ^[0-9]+$ ]] \
        || fail_test "client RPC port was not generated"
    TESTS_RUN=$((TESTS_RUN + 1))
    ((10#${MIERU_CLIENT_RPC_PORT} >= 2000 && 10#${MIERU_CLIENT_RPC_PORT} <= 8000)) \
        || fail_test "client RPC port is outside the expected range"
    TESTS_RUN=$((TESTS_RUN + 1))
    MIERU_TRAFFIC_SEED=""
    collect_mieru_traffic_seed
    ((10#${MIERU_TRAFFIC_SEED} >= 1)) \
        || fail_test "traffic-pattern seed was not generated"
    TESTS_RUN=$((TESTS_RUN + 1))
    assert_failure "invalid node address is rejected" check_invalid_host
    NODE_HOST="203.0.113.10"
    collect_mieru_node_host
    assert_equal "valid node IPv4 is accepted" "203.0.113.10" "${NODE_HOST}"
    normalize_domain_host
    assert_equal "domain input is normalized" "node.example.com" "${NODE_HOST}"
    NODE_HOST="203.0.113.10"
}

test_server_config() {
    local config
    render_mieru_server_config "${TMP_DIR}/server.json"
    config=$(<"${TMP_DIR}/server.json")
    jq -e '
        .portBindings == [{port: 2090, protocol: "TCP"}]
        and .users[0].password == "test-password-0123456789abcdef"
        and .users[0].name == "testuser12345678"
        and .loggingLevel == "INFO"
        and .mtu == 1400
        and .dns.dualStack == "PREFER_IPv4"
        and .trafficPattern.seed == 12345
        and .trafficPattern.unlockAll == false
    ' <<<"${config}" >/dev/null || fail_test "mita server config is malformed"
    validate_mieru_server_config "${TMP_DIR}/server.json"
    jq '.portBindings[0].protocol = "UDP"' <<<"${config}" >"${TMP_DIR}/bad.json"
    assert_failure "server config rejects a UDP binding" \
        validate_mieru_server_config "${TMP_DIR}/bad.json"
}

test_client_config() {
    local config
    render_mieru_client_config "${TMP_DIR}/client.json"
    config=$(<"${TMP_DIR}/client.json")
    jq -e '
        .profiles[0].profileName == "default"
        and .profiles[0].user.name == "testuser12345678"
        and .profiles[0].user.password == "test-password-0123456789abcdef"
        and .profiles[0].servers[0].ipAddress == "203.0.113.10"
        and .profiles[0].servers[0].portBindings == [{portRange: "50000-50512", protocol: "TCP"}]
        and .profiles[0].multiplexing.level == "MULTIPLEXING_LOW"
        and .profiles[0].trafficPattern.seed == 12345
        and .activeProfile == "default"
        and .rpcPort == 4321
        and .socks5Port == 1080
        and .httpProxyPort == 8080
    ' <<<"${config}" >/dev/null || fail_test "Mieru client config is malformed"
    NODE_HOST="node.example.com"
    render_mieru_client_config "${TMP_DIR}/client-domain.json"
    jq -e '
        .profiles[0].servers[0].domainName == "node.example.com"
        and (.profiles[0].servers[0] | has("ipAddress") | not)
    ' "${TMP_DIR}/client-domain.json" >/dev/null \
        || fail_test "Mieru client config must use domainName for domains"
    NODE_HOST="203.0.113.10"
}

test_node_output() {
    local link node
    node=$(build_mihomo_node)
    assert_contains "Mihomo node is a mieru proxy" '    type: mieru' "${node}"
    assert_contains "Mihomo node uses TCP" '    transport: TCP' "${node}"
    assert_contains "Mihomo node enables UDP associate" '    udp: true' "${node}"
    assert_contains "Mihomo node keeps the low multiplexing default" \
        '    multiplexing: MULTIPLEXING_LOW' "${node}"
    assert_contains "Mihomo node carries the exported traffic pattern" \
        "    traffic-pattern: \"${TEST_PATTERN}\"" "${node}"
    assert_contains "Mihomo node uses the port range" \
        '    port-range: "50000-50512"' "${node}"
    assert_not_contains "Mihomo node omits a single port" \
        '    port: 2090' "${node}"
    assert_contains "Mihomo node quotes the server" '    server: "203.0.113.10"' "${node}"
    link=$(build_mierus_link)
    assert_contains "share link uses the mierus scheme" 'mierus://' "${link}"
    assert_contains "share link targets the port range" '&port=50000-50512&' "${link}"
    assert_contains "share link pins the profile" '&profile=default' "${link}"
    assert_contains "share link declares TCP" '&protocol=TCP' "${link}"
    assert_contains "share link carries the traffic pattern" \
        "&traffic-pattern=${TEST_PATTERN}" "${link}"
    MIERU_TRAFFIC_PATTERN="CLlgEAA="
    link=$(build_mierus_link)
    assert_contains "share link URL-encodes base64 padding" \
        "&traffic-pattern=CLlgEAA%3D" "${link}"
    MIERU_TRAFFIC_PATTERN="${TEST_PATTERN}"
    NODE_HOST="node.example.com"
    link=$(build_mierus_link)
    node=$(build_mihomo_node)
    assert_contains "share link accepts a domain" \
        '@node.example.com?' "${link}"
    assert_contains "Mihomo node accepts a domain" \
        '    server: "node.example.com"' "${node}"
    NODE_HOST="203.0.113.10"
}

test_state_roundtrip() {
    save_state
    assert_equal "state file is private" "600" \
        "$(stat -c '%a' "${STATE_FILE}" 2>/dev/null || stat -f '%Lp' "${STATE_FILE}")"
    MIERU_PORT="1111"
    MIERU_USER_NAME="overwritten"
    MIERU_TRAFFIC_PATTERN=""
    load_state
    assert_equal "state restores the port" "2090" "${MIERU_PORT}"
    assert_equal "state restores the port range" "50000-50512" "${MIERU_PORT_RANGE}"
    assert_equal "state restores the user" "testuser12345678" "${MIERU_USER_NAME}"
    assert_equal "state restores the traffic pattern" \
        "${TEST_PATTERN}" "${MIERU_TRAFFIC_PATTERN}"
    assert_equal "state restores the mita version" "3.39.0" "${MIERU_VERSION}"

    NODE_HOST="Node.Example.COM."
    save_state
    NODE_HOST=""
    load_state
    assert_equal "state stores a normalized domain" "node.example.com" "${NODE_HOST}"
    NODE_HOST="203.0.113.10"
    save_state

    sed -i.bak 's/^MIERU_PORT=.*/MIERU_PORT=80/' "${STATE_FILE}" 2>/dev/null \
        || sed -i '' 's/^MIERU_PORT=.*/MIERU_PORT=80/' "${STATE_FILE}"
    assert_failure "state rejects an out-of-range port" load_state
    rm -f -- "${STATE_FILE}.bak"
    save_state
}

test_release_download() {
    local release="${TMP_DIR}/fixture-release.json"
    jq -n '{
        tag_name: "v3.39.0",
        assets: [
            {name: "mita_3.39.0_amd64.deb",
             browser_download_url: "https://github.com/enfein/mieru/releases/download/v3.39.0/mita_3.39.0_amd64.deb"},
            {name: "mita_3.39.0_amd64.deb.sha256.txt",
             browser_download_url: "https://github.com/enfein/mieru/releases/download/v3.39.0/mita_3.39.0_amd64.deb.sha256.txt"}
        ]
    }' >"${release}"
    download_https_file() {
        local url=$1 destination=$2
        case "${url}" in
        */releases/latest) cp "${release}" "${destination}" ;;
        */mita_3.39.0_amd64.deb)
            printf 'deb-payload\n' >"${destination}"
            ;;
        */mita_3.39.0_amd64.deb.sha256.txt)
            printf '%s  mita_3.39.0_amd64.deb\n' "${TEST_DIGEST_SHA}" >"${destination}"
            ;;
        *) return 1 ;;
        esac
    }
    MIERU_DOWNLOAD_VERSION=""
    MIERU_DOWNLOAD_PACKAGE=""
    download_mieru_package "${TMP_DIR}"
    assert_equal "release download resolves the official version" \
        "3.39.0" "${MIERU_DOWNLOAD_VERSION}"
    assert_equal "release download keeps the official asset name" \
        "mita_3.39.0_amd64.deb" "$(basename -- "${MIERU_DOWNLOAD_PACKAGE}")"

    TEST_ACTUAL_SHA="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    assert_failure "release download rejects a checksum mismatch" \
        download_mieru_package "${TMP_DIR}"
}

test_install_and_apply() {
    install_mieru_package "${TMP_DIR}/mita.deb" "3.39.0" >/dev/null
    assert_contains "package install enables mita" 'enable mita.service' \
        "$(<"${SYSTEMCTL_LOG}")"
    assert_failure "package install verifies the mita version" \
        install_mieru_package "${TMP_DIR}/mita.deb" "9.9.9"

    install -d -m 0700 "${MIERU_DIR}"
    render_mieru_server_config "${MIERU_SERVER_CONFIG}"
    : >"${MITA_LOG}"
    mita_listening_on_port() { return 0; }
    apply_mieru_config "${MIERU_SERVER_CONFIG}"
    assert_contains "apply uses the official command" 'apply config' "$(<"${MITA_LOG}")"
    assert_contains "apply restarts mita" 'start' "$(<"${MITA_LOG}")"
    assert_equal "apply exports the traffic pattern" \
        "${TEST_PATTERN}" "${MIERU_TRAFFIC_PATTERN}"

    mita_listening_on_port() { return 1; }
    assert_failure "runtime acceptance requires a listener" apply_mieru_config "${MIERU_SERVER_CONFIG}"
}

test_install_pipeline() {
    (
        rm -f -- "${STATE_FILE}"
        check_platform() { :; }
        require_root() { :; }
        require_systemd() { :; }
        check_install_conflicts() { :; }
        snapshot_fresh_install() { :; }
        install_packages() { :; }
        initialize_server() { :; }
        install_latest_mieru_package() { MIERU_VERSION="3.39.0"; }
        apply_mieru_config() { MIERU_TRAFFIC_PATTERN="${TEST_PATTERN}"; }
        configure_ufw() { :; }
        register_easy_all_command() { :; }
        show_node() { :; }
        show_tcp_acceleration_status() { :; }
        prompt_bbrv3_reboot() { :; }
        run_mieru_install_pipeline 4
        [[ -f "${STATE_FILE}" ]] || fail_test "install pipeline did not save state"
        [[ -f "${MIERU_SERVER_CONFIG}" && -f "${MIERU_CLIENT_CONFIG}" ]] \
            || fail_test "install pipeline did not publish Mieru configs"
        jq -e '.portBindings[0].port == 2090' "${MIERU_SERVER_CONFIG}" >/dev/null \
            || fail_test "install pipeline rendered an unexpected server config"
        grep -q '^PROTOCOL=mieru$' "${STATE_FILE}" \
            || fail_test "install pipeline saved the wrong protocol"
        grep -q '^MIERU_PORT_RANGE=50000-50512$' "${STATE_FILE}" \
            || fail_test "install pipeline saved the wrong port range"
    )
    TESTS_RUN=$((TESTS_RUN + 1))
}

test_nat_and_cron() {
    local rules
    MIERU_PORT="2090"
    MIERU_PORT_RANGE="50000-50512"
    assert_equal "NAT rule redirects the whole range" \
        "-A PREROUTING -p tcp --dport 50000:50512 -j REDIRECT --to-ports 2090" \
        "$(mieru_write_nat_rules)"
    printf '%s\n' '*filter' ':INPUT ACCEPT [0:0]' 'COMMIT' >"${UFW_BEFORE_RULES}"
    write_mieru_nat_rules
    rules=$(<"${UFW_BEFORE_RULES}")
    assert_contains "UFW NAT block starts" '# easy_all-nat-start' "${rules}"
    assert_contains "UFW NAT block redirects the range" \
        '-A PREROUTING -p tcp --dport 50000:50512 -j REDIRECT --to-ports 2090' "${rules}"
    assert_contains "UFW NAT block ends" '# easy_all-nat-end' "${rules}"
    printf '%s\n' '# user cron' >"${TMP_DIR}/crontab"
    configure_dynamic_port_rotation
    assert_contains "reboot cron refreshes the NAT range" \
        'rotate-dynamic-ports' "$(<"${TMP_DIR}/crontab")"
}

test_daily_reboot() {
    printf '%s\n' '# user cron' >"${TMP_DIR}/crontab"
    REBOOT_SCHEDULE_MODE=1
    SCHEDULED_REBOOT_ENABLED=0
    SCHEDULED_REBOOT_HOUR=""
    configure_daily_reboot
    assert_contains "daily reboot installs the 04:00 job" \
        '0 4 * * *' "$(<"${TMP_DIR}/crontab")"
    assert_contains "daily reboot uses the managed marker" \
        '# easy_all-managed-reboot' "$(<"${TMP_DIR}/crontab")"
    remove_daily_reboot_schedule
    assert_not_contains "daily reboot removal deletes the managed job" \
        '# easy_all-managed-reboot' "$(<"${TMP_DIR}/crontab")"
    assert_contains "daily reboot removal preserves unrelated cron" \
        '# user cron' "$(<"${TMP_DIR}/crontab")"
}

test_syntax_and_wiring
prepare_profile_copy
setup_stubs
source_profile
set_fixture
test_input_validation
set_fixture
test_server_config
test_client_config
test_node_output
test_state_roundtrip
test_install_and_apply
set_fixture
test_release_download
set_fixture
test_nat_and_cron
test_daily_reboot
test_install_pipeline

printf 'ok - %d Mieru direct assertions passed\n' "${TESTS_RUN}"
