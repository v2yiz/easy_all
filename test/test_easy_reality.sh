#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf -- "${TMP_DIR}"' EXIT

TESTS_RUN=0
SCRIPT_LOADED=0

fail_test() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
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
    if "$@"; then
        fail_test "${description}"
    fi
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

source_script_copy() {
    local nft_config=$1
    local script_copy="${TMP_DIR}/easy_reality.test.sh"
    if [[ "${SCRIPT_LOADED}" == "1" ]]; then
        return
    fi
    sed \
        -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${TMP_DIR}/state\"|" \
        -e "s|^readonly NFT_CONFIG=.*|readonly NFT_CONFIG=\"${nft_config}\"|" \
        "${ROOT_DIR}/easy_reality.sh" >"${script_copy}"
    # shellcheck source=/dev/null
    source "${script_copy}"
    SCRIPT_LOADED=1
}

test_validators() {
    source_script_copy "${TMP_DIR}/nftables.conf"

    assert_success "valid domain is accepted" validate_domain "node.example.com"
    assert_failure "domain without dot is rejected" validate_domain "localhost"
    assert_failure "domain with leading hyphen is rejected" validate_domain "-bad.example.com"
    assert_failure "domain with empty label is rejected" validate_domain "bad..example.com"

    assert_success "valid IPv4 is accepted" validate_ipv4 "192.168.1.1"
    assert_failure "out-of-range IPv4 is rejected" validate_ipv4 "256.1.1.1"
    assert_failure "malformed IPv4 is rejected" validate_ipv4 "1.2.3"

    assert_success "domain node host is accepted" validate_node_host "node.example.com"
    assert_success "IPv4 node host is accepted" validate_node_host "203.0.113.10"
    assert_failure "invalid node host is rejected" validate_node_host "bad_host"

    assert_success "valid Worker name is accepted" validate_worker_name "easy-reality"
    assert_failure "uppercase Worker name is rejected" validate_worker_name "Easy-Reality"
    assert_failure "underscore Worker name is rejected" validate_worker_name "easy_reality"

    assert_success "443 subscription mode is accepted" validate_sub_port_mode "443"
    assert_success "dynamic subscription mode is accepted" validate_sub_port_mode "dynamic"
    assert_failure "unknown subscription mode is rejected" validate_sub_port_mode "8443"

    assert_success "valid Clash download name is accepted" validate_sub_download_name "MY_SUB-1.2"
    assert_failure "path-like Clash download name is rejected" validate_sub_download_name "../MY_SUB"

    assert_success "valid UUID is accepted" validate_xray_value uuid "00000000-0000-4000-8000-000000000001"
    assert_failure "invalid UUID is rejected" validate_xray_value uuid "not-a-uuid"
    assert_success "valid Reality public key length is accepted" validate_xray_value public_key "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
    assert_failure "short Reality public key is rejected" validate_xray_value public_key "short"
    assert_success "valid short id is accepted" validate_xray_value short_id "0123456789abcdef"
    assert_failure "uppercase short id is rejected" validate_xray_value short_id "0123456789ABCDEF"
}

test_normalizers_and_links() {
    source_script_copy "${TMP_DIR}/nftables.conf"

    assert_equal "yaml suffix is stripped" "Team_Sub" "$(normalize_sub_download_name "Team_Sub.yaml")"
    assert_equal "yml suffix is stripped" "Team_Sub" "$(normalize_sub_download_name "Team_Sub.yml")"
    assert_equal "empty download name falls back" "${DEFAULT_SUB_DOWNLOAD_NAME}" "$(normalize_sub_download_name "")"

    XRAY_UUID="00000000-0000-4000-8000-000000000001"
    NODE_HOST="node.example.com"
    REALITY_PUBLIC_KEY="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
    REALITY_SHORT_ID="0123456789abcdef"
    REALITY_SNI="www.example.com"
    local link
    link="$(build_vless_link)"
    assert_contains "VLESS link contains uuid and host" "vless://${XRAY_UUID}@node.example.com:443" "${link}"
    assert_contains "VLESS link contains reality security" "security=reality" "${link}"
    assert_contains "VLESS link contains public key" "pbk=${REALITY_PUBLIC_KEY}" "${link}"
    assert_contains "VLESS link contains short id" "sid=${REALITY_SHORT_ID}" "${link}"
    assert_contains "VLESS link uses MY_VLESS name" "#MY_VLESS" "${link}"
}

test_dynamic_port_redirect_guard() {
    local nft_config="${TMP_DIR}/nftables.conf"
    source_script_copy "${nft_config}"

    SUB_PORT_MODE="443"
    assert_success "443 mode skips dynamic redirect requirement" require_dynamic_port_redirect

    SUB_PORT_MODE="dynamic"
    printf '%s\n' \
        'table inet nat {' \
        '  chain prerouting {' \
        '    tcp dport 10000-65535 redirect to :443' \
        '  }' \
        '}' >"${nft_config}"
    assert_success "dynamic mode accepts redirect from nftables config" require_dynamic_port_redirect

    printf '%s\n' 'table inet filter { chain input { policy drop; } }' >"${nft_config}"
    die() { return 42; }
    TESTS_RUN=$((TESTS_RUN + 1))
    set +e
    require_dynamic_port_redirect
    local status=$?
    set -e
    [[ "${status}" -eq 42 ]] \
        || fail_test "dynamic mode fails without redirect: expected 42, got ${status}"
    die() { printf 'die: %s\n' "$*" >&2; exit 1; }
}

test_dynamic_port_redirect_ruleset_fallback() {
    local fake_bin="${TMP_DIR}/bin"
    source_script_copy "${TMP_DIR}/nftables.conf"
    rm -f -- "${NFT_CONFIG}"

    mkdir -p "${fake_bin}"
    cat >"${fake_bin}/nft" <<'NFT'
#!/usr/bin/env bash
printf '%s\n' \
  'table inet nat {' \
  '  chain prerouting {' \
  '    tcp dport 10000-65535 redirect to :443' \
  '  }' \
  '}'
NFT
    chmod +x "${fake_bin}/nft"

    SUB_PORT_MODE="dynamic"
    PATH="${fake_bin}:${PATH}" assert_success \
        "dynamic mode accepts redirect from active ruleset" \
        require_dynamic_port_redirect
}

test_minimal_worker_template() {
    source_script_copy "${TMP_DIR}/nftables.conf"

    XRAY_UUID="00000000-0000-4000-8000-000000000001"
    NODE_HOST="node.example.com"
    REALITY_PUBLIC_KEY="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
    REALITY_SHORT_ID="0123456789abcdef"
    REALITY_SNI="www.example.com"
    SUB_PORT_MODE="443"
    SUB_DOWNLOAD_NAME="Team_Sub"

    local worker_file="${TMP_DIR}/subscribe-worker.js"
    write_minimal_worker "${worker_file}"
    local content
    content="$(<"${worker_file}")"

    assert_contains "minimal Worker uses auto registration array" "const CONFIGS = [];" "${content}"
    assert_contains "minimal Worker defines defineNode" "function defineNode(config)" "${content}"
    assert_contains "minimal Worker supports node=all" "url.searchParams.get('node') === 'all'" "${content}"
    assert_contains "minimal Worker emits VLESS links" "vless://" "${content}"
    assert_contains "minimal Worker embeds configured node host" "host: 'node.example.com'" "${content}"
    assert_contains "minimal Worker embeds configured download name" "const SUB_DOWNLOAD_NAME = 'Team_Sub';" "${content}"
    assert_contains "minimal Worker marks Reality VLESS security" "security: 'reality'" "${content}"
    assert_contains "minimal Worker includes TLS Vision sample" "security: 'tls'" "${content}"
    assert_contains "minimal Worker can emit TLS VLESS links" "security," "${content}"
    assert_contains "minimal Worker chooses 443 for TLS Vision" "vlessSecurity(cfg) === 'tls' ? 443" "${content}"
    assert_contains "minimal Worker base64 subscription uses shared link builder" \
        "encodeBase64(targetConfigs.map((cfg, i) => link(cfg, ports[i])).join('\\n'))" \
        "${content}"
    assert_not_contains "minimal Worker does not contain Trojan support" "trojan" "${content}"
}

test_full_worker_template() {
    source_script_copy "${TMP_DIR}/nftables.conf"

    XRAY_UUID="00000000-0000-4000-8000-000000000001"
    NODE_HOST="node.example.com"
    REALITY_PUBLIC_KEY="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQ"
    REALITY_SHORT_ID="0123456789abcdef"
    REALITY_SNI="www.example.com"
    SUB_PORT_MODE="443"
    SUB_DOWNLOAD_NAME="Team_Sub"

    local worker_file="${TMP_DIR}/full-subscribe-worker.js"
    write_worker "${worker_file}"
    local content
    content="$(<"${worker_file}")"

    assert_contains "full Worker uses auto registration array" "const CONFIGS = [];" "${content}"
    assert_contains "full Worker defines defineNode" "function defineNode(config)" "${content}"
    assert_contains "full Worker supports node=all" "node === 'all'" "${content}"
    assert_contains "full Worker replaces node host placeholder" "host: 'node.example.com'" "${content}"
    assert_contains "full Worker replaces download filename" "attachment; filename=\"Team_Sub\"" "${content}"
    assert_contains "full Worker rewrites 443 port mode" "const ports = targetConfigs.map(() => 443);" "${content}"
    assert_contains "full Worker marks Reality VLESS security" "security: 'reality'" "${content}"
    assert_contains "full Worker includes TLS Vision sample" "security: 'tls'" "${content}"
    assert_contains "full Worker has TLS Vision Clash template" "buildClashVlessTlsVisionNodeTemplate" "${content}"
    assert_contains "full Worker can emit TLS VLESS links" "security," "${content}"
    assert_contains "full Worker base64 subscription uses shared link builder" \
        "base64Encode(links.join('\\n'))" \
        "${content}"
    assert_not_contains "full Worker has no unreplaced UUID placeholder" "__UUID__" "${content}"
    assert_not_contains "full Worker has no unreplaced host placeholder" "__HOST__" "${content}"
    assert_not_contains "full Worker does not contain Trojan support" "trojan" "${content}"
}

test_safe_uninstall_helpers() {
    source_script_copy "${TMP_DIR}/nftables.conf"
    local script_content uninstall_body
    mkdir -p "${BACKUP_DIR}"
    touch \
        "${BACKUP_DIR}/xray-config.1.bak" \
        "${BACKUP_DIR}/install-nftables.conf.1.bak" \
        "${BACKUP_DIR}/install-sysctl-bbrv3.1.bak"
    purge_reality_backups
    assert_failure "Reality purge removes Xray config backup" \
        test -e "${BACKUP_DIR}/xray-config.1.bak"
    assert_success "Reality purge preserves nftables initialization backup" \
        test -e "${BACKUP_DIR}/install-nftables.conf.1.bak"
    assert_success "Reality purge preserves sysctl initialization backup" \
        test -e "${BACKUP_DIR}/install-sysctl-bbrv3.1.bak"

    script_content=$(<"${ROOT_DIR}/easy_reality.sh")
    uninstall_body=$(declare -f uninstall_reality)
    assert_contains "Reality exposes purge uninstall mode" \
        "uninstall --purge" "${script_content}"
    assert_contains "Reality remote Worker deletion requires opt-in" \
        'DELETE_CLOUDFLARE_WORKER:-0' "${script_content}"
    assert_not_contains "Reality uninstall never restores system settings" \
        "restore_system_changes" "${uninstall_body}"
    assert_contains "Reality uninstall removes its reboot schedule" \
        "remove_daily_reboot_schedule" "${uninstall_body}"
    assert_contains "Reality uninstall removes its dynamic redirect" \
        "remove_reality_dynamic_redirect" "${uninstall_body}"
    assert_not_contains "Reality uninstall never purges XanMod" \
        "purge_xanmod" "${uninstall_body}"

    local cron_input cron_output nft_input nft_output
    cron_input=$'15 3 * * * /usr/local/bin/backup\n0 4 * * * /sbin/reboot\n0 6 * * * /usr/bin/flock -n /run/daily-reboot.lock /sbin/reboot'
    cron_output=$(filter_managed_reboot_cron <<<"${cron_input}")
    assert_contains "Reality reboot cleanup preserves unrelated cron" \
        "/usr/local/bin/backup" "${cron_output}"
    assert_not_contains "Reality reboot cleanup removes legacy cron" \
        "0 4 * * * /sbin/reboot" "${cron_output}"
    assert_not_contains "Reality reboot cleanup removes managed cron" \
        "/run/daily-reboot.lock" "${cron_output}"

    nft_input=$'table inet nat {\n chain prerouting {\n  type nat hook prerouting priority dstnat; policy accept;\n  tcp dport 10000-65535 redirect to :443\n  tcp dport 8443 redirect to :443\n }\n}'
    nft_output=$(filter_reality_dynamic_redirect <<<"${nft_input}")
    assert_not_contains "Reality cleanup removes only its dynamic range" \
        "10000-65535" "${nft_output}"
    assert_contains "Reality cleanup preserves unrelated nft redirect" \
        "tcp dport 8443 redirect to :443" "${nft_output}"
}

test_validators
test_normalizers_and_links
test_dynamic_port_redirect_guard
test_dynamic_port_redirect_ruleset_fallback
test_minimal_worker_template
test_full_worker_template
test_safe_uninstall_helpers

printf 'ok - easy_reality shell tests passed (%s assertions)\n' "${TESTS_RUN}"
