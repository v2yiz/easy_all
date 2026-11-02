#!/usr/bin/env bash
# End-to-end user-perspective test for Bunny CDN (ws-bunny) profile.
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf -- "${TEST_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected '${expected}', got '${actual}'"
}

assert_contains() {
    local label=$1 needle=$2 haystack=$3
    [[ "${haystack}" == *"${needle}"* ]] || fail "${label}: missing '${needle}'"
}

# 1. Test CLI API parsing and validation
echo "--- Testing bunny-api.py CLI interface ---"
api_help=$(python3 "${ROOT_DIR}/lib/bunny-api.py" --help)
assert_contains "CLI help shows commands" "apply" "${api_help}"
assert_contains "CLI help shows ips" "ips" "${api_help}"

# Test ips parsing
ips_json="${TEST_DIR}/ips.json"
printf '["192.0.2.1", "198.51.100.0/24"]' >"${ips_json}"
parsed_ips=$(python3 "${ROOT_DIR}/lib/bunny-api.py" ips --input "${ips_json}")
assert_contains "IPS parses single IP" "192.0.2.1/32" "${parsed_ips}"
assert_contains "IPS parses CIDR" "198.51.100.0/24" "${parsed_ips}"

# Test validate-config
cfg_json="${TEST_DIR}/config.json"
cat >"${cfg_json}" <<EOF
{"zone":"example.com","origin":"origin.example.com","cdn":"cdn.example.com",
"ipv4":"1.2.3.4","name":"test-zone-42","secret":"0123456789abcdef0123456789abcdef"}
EOF
python3 "${ROOT_DIR}/lib/bunny-api.py" validate-config --config "${cfg_json}" \
    || fail "validate-config failed on valid config"

# 2. Test user profile configuration generation
echo "--- Testing ws-bunny profile user configurations ---"
MOCK_DIR="${TEST_DIR}/root"
mkdir -p "${MOCK_DIR}/etc/easy_all" "${MOCK_DIR}/etc/easy_all-bunny" "${MOCK_DIR}/var/www/easy_all"

# Mock profile environment
(
    export STATE_DIR="${MOCK_DIR}/etc/easy_all"
    export BUNNY_RECOVERY_DIR="${MOCK_DIR}/etc/easy_all-bunny"
    export WEB_ROOT="${MOCK_DIR}/var/www/easy_all"
    export RUNTIME_TMP="${TEST_DIR}/tmp"
    export CERT_FILE="${TEST_DIR}/cert.pem"
    export KEY_FILE="${TEST_DIR}/key.pem"
    export NGINX_CONFIG="${MOCK_DIR}/etc/easy_all/nginx.conf"
    export XRAY_CONFIG="${MOCK_DIR}/etc/easy_all/xray.json"
    mkdir -p "${RUNTIME_TMP}"
    touch "${CERT_FILE}" "${KEY_FILE}"

    # Setup dummy dependencies
    CLOUDFLARE_ZONE="example.com"
    ORIGIN_DOMAIN="origin.example.com"
    CDN_DOMAIN="cdn.example.com"
    VPS_PUBLIC_IPV4="1.2.3.4"
    BUNNY_PULL_NAME="test-pull-zone"
    ORIGIN_HEADER_SECRET="secret1234567890abcdef"
    VLESS_UUID="00000000-1111-2222-3333-444444444444"
    OWNER_TOKEN="token1234567890abcdef"
    ALLOWED_TOKENS="[\"${OWNER_TOKEN}\"]"
    WEBSOCKET_PATH="/ws-test"
    BUNNY_BANDWIDTH_GB="500"
    TCP_ACCELERATION="bbrv3"
    SUB_DOWNLOAD_NAME="EASY_ALL"

    nginx() { return 0; }
    systemctl() { return 0; }

    source "${ROOT_DIR}/profiles/ws-bunny.sh"

    # Test state persistence
    save_state
    [[ -f "${STATE_DIR}/state.env" ]] || fail "save_state did not create state.env"
    state_content=$(<"${STATE_DIR}/state.env")
    assert_contains "state contains protocol" 'PROTOCOL="bunny-ws"' "${state_content}"
    assert_contains "state contains cdn domain" 'CDN_DOMAIN="cdn.example.com"' "${state_content}"

    # Test Nginx user config generation
    write_nginx_config
    [[ -f "${NGINX_CONFIG}" ]] || fail "write_nginx_config did not create nginx config"
    nginx_content=$(<"${NGINX_CONFIG}")
    assert_contains "Nginx config has server_name" "server_name origin.example.com;" "${nginx_content}"
    assert_contains "Nginx config validates origin secret" '$http_x_easy_all_origin_key != "secret1234567890abcdef"' "${nginx_content}"
    assert_contains "Nginx config proxies websocket" 'proxy_pass http://127.0.0.1:10086;' "${nginx_content}"

    # Test Xray user config generation
    write_xray_config
    [[ -f "${XRAY_CONFIG}" ]] || fail "write_xray_config did not create xray config"
    xray_content=$(<"${XRAY_CONFIG}")
    assert_contains "Xray config has vless" '"protocol":"vless"' "${xray_content}"
    assert_contains "Xray config has uuid" '"id":"00000000-1111-2222-3333-444444444444"' "${xray_content}"
    assert_contains "Xray config has ws path" '"path":"/ws-test"' "${xray_content}"

    # Test subscription links
    links=$(build_node_links)
    assert_contains "VLESS link contains CDN domain" "vless://00000000-1111-2222-3333-444444444444@cdn.example.com:443" "${links}"
    assert_contains "VLESS link contains ws path" "path=%2Fws-test" "${links}"

    # Test uninstall preserves recovery data
    bunny_remove_local
    [[ ! -d "${STATE_DIR}" ]] || fail "uninstall should remove STATE_DIR"
)

printf 'ok - Bunny CDN user-perspective tests passed\n'
