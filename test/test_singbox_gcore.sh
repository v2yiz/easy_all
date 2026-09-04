#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
PROFILE="${ROOT_DIR}/profiles/singbox-gcore.sh"
CORE_LIB="${ROOT_DIR}/lib/singbox-core.sh"
TMP_DIR=$(mktemp -d)
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected <${expected}> but got <${actual}>"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing ${expected}"
}

# 1. Syntax check
bash -n "${PROFILE}" "${CORE_LIB}"

# 2. Source modules in isolated environment
export STATE_DIR="${TMP_DIR}/state"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export SINGBOX_DIR_OVERRIDE="${TMP_DIR}/singbox"
export SINGBOX_BIN_OVERRIDE="${TMP_DIR}/singbox/sing-box"
export SINGBOX_CONFIG_OVERRIDE="${TMP_DIR}/singbox/config.json"
export CERT_DIR="${STATE_DIR}/certs"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export SUBSCRIPTION_BASE64_FILE="${SUBSCRIPTION_DIR}/base64.txt"
export SUBSCRIPTION_MIHOMO_FILE="${SUBSCRIPTION_DIR}/mihomo.yaml"
export SUBSCRIPTION_SINGBOX_FILE="${SUBSCRIPTION_DIR}/singbox.json"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export STATE_FILE="${STATE_DIR}/state.env"
export VLESS_CDN_DOMAIN="cdn.example.com"
export GCORE_ORIGIN_DOMAIN="origin.example.com"
export VLESS_UUID="11111111-2222-3333-4444-555555555555"
export TROJAN_PASSWORD="test-trojan-password"
export WEBSOCKET_PATH="/vless-ws-path"
export TROJAN_PATH="/trojan-ws-path"
export SINGBOX_TROJAN_LOOPBACK_PORT=10088
export SINGBOX_VLESS_LOOPBACK_PORT=10087
export ALLOWED_TOKENS='{"owner":"test-token-12345"}'
export SUB_DOWNLOAD_NAME="TEST_SUB"
export SUBSCRIPTION_MODE="deploy"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"

mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" "${TMP_DIR}/singbox"

install() {
    local args=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
        -o|-g) shift 2 ;;
        *) args+=("$1"); shift ;;
        esac
    done
    local target="${args[${#args[@]}-1]}"
    if [[ "${target}" == "/etc/nginx/conf.d/easy_all.conf" ]]; then
        target="${TMP_DIR}/nginx.conf"
        args[${#args[@]}-1]="${target}"
    elif [[ "${target}" == /var/www/easy_all/* || "${target}" == "/var/www/easy_all" ]]; then
        target="${TMP_DIR}/web${target#/var/www/easy_all}"
        args[${#args[@]}-1]="${target}"
    fi
    if [[ " ${args[*]} " == *" -d "* ]]; then
        mkdir -p "${target}"
    elif [[ -n "${target}" ]]; then
        mkdir -p "$(dirname "${target}")"
    fi
    command install "${args[@]}"
}

rm() {
    local args=()
    for arg in "$@"; do
        if [[ "${arg}" == /var/www/easy_all/* || "${arg}" == "/var/www/easy_all" ]]; then
            args+=("${TMP_DIR}/web${arg#/var/www/easy_all}")
        else
            args+=("${arg}")
        fi
    done
    command rm "${args[@]}"
}

# shellcheck source=profiles/singbox-gcore.sh
source "${PROFILE}"

# 3. Test singbox_render_config
singbox_render_config
[[ -f "${SINGBOX_CONFIG}" ]] || fail "Sing-box config file was not created"
singbox_json=$(<"${SINGBOX_CONFIG}")

trojan_port=$(jq -r '.inbounds[] | select(.type=="trojan") | .listen_port' <<<"${singbox_json}")
vless_port=$(jq -r '.inbounds[] | select(.type=="vless") | .listen_port' <<<"${singbox_json}")
trojan_ws=$(jq -r '.inbounds[] | select(.type=="trojan") | .transport.type' <<<"${singbox_json}")
vless_ws=$(jq -r '.inbounds[] | select(.type=="vless") | .transport.type' <<<"${singbox_json}")

assert_equal "Trojan inbound listen port" "10088" "${trojan_port}"
assert_equal "VLESS inbound listen port" "10087" "${vless_port}"
assert_equal "Trojan inbound transport" "ws" "${trojan_ws}"
assert_equal "VLESS inbound transport" "ws" "${vless_ws}"

# Modern server outbounds (no legacy block outbound)
server_outbound_types=$(jq -r '[.outbounds[].type] | join(",")' <<<"${singbox_json}")
server_rule_action=$(jq -r '.route.rules[0].action' <<<"${singbox_json}")
assert_equal "Server outbounds only contain direct" "direct" "${server_outbound_types}"
assert_equal "Server private IP rule uses reject action" "reject" "${server_rule_action}"

# 4. Test link generation
trojan_link=$(build_trojan_websocket_link "${VLESS_CDN_DOMAIN}")
vless_link=$(build_vless_websocket_link "${VLESS_CDN_DOMAIN}")

assert_contains "Trojan link scheme and password" "${trojan_link}" "trojan://test-trojan-password@cdn.example.com:443"
assert_contains "Trojan link type ws" "${trojan_link}" "type=ws"
assert_contains "Trojan link path" "${trojan_link}" "path=%2Ftrojan-ws-path"
assert_contains "VLESS link scheme and uuid" "${vless_link}" "vless://11111111-2222-3333-4444-555555555555@cdn.example.com:443"
assert_contains "VLESS link type ws" "${vless_link}" "type=ws"
assert_contains "VLESS link path" "${vless_link}" "path=%2Fvless-ws-path"

# 5. Test Mihomo nodes and groups
mihomo_nodes=$(build_mihomo_nodes)
mihomo_groups=$(build_mihomo_proxy_groups)
mihomo_names=$(build_mihomo_proxy_names)

assert_contains "Mihomo nodes contain trojan" "${mihomo_nodes}" "type: trojan"
assert_contains "Mihomo nodes contain vless" "${mihomo_nodes}" "type: vless"
assert_contains "Mihomo groups contain url-test" "${mihomo_groups}" "type: url-test"
assert_contains "Mihomo names contain auto group" "${mihomo_names}" "_AUTO"

# 6. Test Sing-box client JSON subscription
singbox_sub=$(build_singbox_subscription_json)
assert_equal "Sing-box subscription is valid JSON" "true" "$(jq -e 'type=="object"' <<<"${singbox_sub}" >/dev/null && echo true)"
sub_trojan_tag=$(jq -r '.outbounds[] | select(.type=="trojan") | .tag' <<<"${singbox_sub}")
sub_vless_tag=$(jq -r '.outbounds[] | select(.type=="vless") | .tag' <<<"${singbox_sub}")
sub_proxy_outbounds=$(jq -r '.outbounds[] | select(.tag=="PROXY") | .outbounds | join(",")' <<<"${singbox_sub}")

assert_contains "Sing-box subscription Trojan tag" "${sub_trojan_tag}" "TROJAN"
assert_contains "Sing-box subscription VLESS tag" "${sub_vless_tag}" "VLESS"
assert_contains "Sing-box subscription PROXY includes AUTO" "${sub_proxy_outbounds}" "_AUTO"

# Modern DNS format assertions (sing-box 1.12+ / 1.14+)
sub_remote_dns_type=$(jq -r '.dns.servers[] | select(.tag=="remote") | .type' <<<"${singbox_sub}")
sub_local_dns_type=$(jq -r '.dns.servers[] | select(.tag=="local") | .type' <<<"${singbox_sub}")
sub_has_legacy_dns_address=$(jq -r '[.dns.servers[] | has("address")] | any' <<<"${singbox_sub}")
sub_has_legacy_dns_outbound_rule=$(jq -r '[.dns.rules[] | has("outbound")] | any' <<<"${singbox_sub}")
sub_route_domain_resolver=$(jq -r '.route.default_domain_resolver' <<<"${singbox_sub}")

assert_equal "Sing-box remote DNS type is https" "https" "${sub_remote_dns_type}"
assert_equal "Sing-box local DNS type is local" "local" "${sub_local_dns_type}"
assert_equal "Sing-box DNS servers do not use legacy address field" "false" "${sub_has_legacy_dns_address}"
assert_equal "Sing-box DNS rules do not use legacy outbound rule" "false" "${sub_has_legacy_dns_outbound_rule}"
assert_equal "Sing-box route sets default_domain_resolver" "local" "${sub_route_domain_resolver}"

# Modern client outbounds (sing-box 1.13+ / 1.14+: no legacy dns or block outbounds)
sub_has_legacy_dns_outbound=$(jq -r '[.outbounds[] | select(.type=="dns")] | length' <<<"${singbox_sub}")
sub_has_legacy_block_outbound=$(jq -r '[.outbounds[] | select(.type=="block")] | length' <<<"${singbox_sub}")
sub_dns_rule_action=$(jq -r '.route.rules[] | select(.protocol=="dns") | .action' <<<"${singbox_sub}")
sub_has_sniff_rule=$(jq -r '[.route.rules[] | select(.action=="sniff")] | length' <<<"${singbox_sub}")
sub_tun_address=$(jq -r '.inbounds[] | select(.type=="tun") | .address[0]' <<<"${singbox_sub}")

assert_equal "Sing-box subscription has no dns outbound" "0" "${sub_has_legacy_dns_outbound}"
assert_equal "Sing-box subscription has no block outbound" "0" "${sub_has_legacy_block_outbound}"
assert_equal "Sing-box subscription routes DNS via hijack-dns action" "hijack-dns" "${sub_dns_rule_action}"
assert_equal "Sing-box subscription includes sniff action in route" "1" "${sub_has_sniff_rule}"
assert_equal "Sing-box subscription tun inbound uses modern address field" "172.19.0.1/30" "${sub_tun_address}"

# 7. Test Nginx config generation
# Mock Gcore CA, mTLS, and system hooks
gcore_prepare_origin_validation_material() { :; }
write_web_root() { :; }
systemctl() { :; }
nginx() { :; }
write_nginx_config

nginx_content=$(<"${TMP_DIR}/nginx.conf")
assert_contains "Nginx defines trojan upstream" "${nginx_content}" "upstream gcore_trojan_backend {"
assert_contains "Nginx defines vless upstream" "${nginx_content}" "upstream gcore_vless_backend {"
assert_contains "Nginx maps singbox flag" "${nginx_content}" "singbox /_easy_all_subscription/singbox;"
assert_contains "Nginx maps clash flag" "${nginx_content}" "clash /_easy_all_subscription/mihomo;"
assert_contains "Nginx location for singbox" "${nginx_content}" "location = /_easy_all_subscription/singbox {"
assert_contains "Nginx location for trojan path" "${nginx_content}" "location = /trojan-ws-path {"
assert_contains "Nginx location for vless path" "${nginx_content}" "location = /vless-ws-path {"

# 8. Test subscription writer
write_subscriptions
[[ -f "${TMP_DIR}/web/subscriptions/base64.txt" ]] || fail "base64.txt subscription was not written"
[[ -f "${TMP_DIR}/web/subscriptions/mihomo.yaml" ]] || fail "mihomo.yaml subscription was not written"
[[ -f "${TMP_DIR}/web/subscriptions/singbox.json" ]] || fail "singbox.json subscription was not written"

assert_contains "Mihomo yaml has trojan" "$(<"${TMP_DIR}/web/subscriptions/mihomo.yaml")" "type: trojan"
assert_contains "Singbox json has trojan" "$(<"${TMP_DIR}/web/subscriptions/singbox.json")" "trojan"

curl() {
    local url="" flag=""
    for arg in "$@"; do
        if [[ "${arg}" == "flag=clash" ]]; then
            flag="clash"
        fi
        if [[ "${arg}" == http* ]]; then
            url="${arg}"
        fi
    done
    if [[ "${url}" == *"/subscribe" ]]; then
        if [[ "${flag}" == "clash" ]]; then
            printf 'network: ws\nproxies:\n'
        else
            printf 'dHJvamFuOi8v...\n'
        fi
        return 0
    fi
    return 1
}
validate_subscription_token_rejection() { :; }
validate_subscription_runtime
unset -f curl validate_subscription_token_rejection

# 9. Test in-place migration detection
TEST_STATE_FILE="${TMP_DIR}/state.env"
export EASY_ALL_STATE_FILE_OVERRIDE="${TEST_STATE_FILE}"

printf 'STATE_VERSION=7\nPROTOCOL=xhttp\nCDN_PROVIDER=gcore\nBACKEND=xray\n' >"${TEST_STATE_FILE}"
assert_equal "Can migrate from xhttp-gcore" "0" "$(can_in_place_migrate_from_xhttp_gcore && echo 0 || echo 1)"

printf 'STATE_VERSION=7\nPROTOCOL=singbox-ws\nCDN_PROVIDER=gcore\nBACKEND=singbox\n' >"${TEST_STATE_FILE}"
assert_equal "Cannot migrate from already singbox" "1" "$(can_in_place_migrate_from_xhttp_gcore && echo 0 || echo 1)"

# 10. Test re-sourcing resilience (prevent readonly variable error)
(
    source "${ROOT_DIR}/profiles/xhttp-gcore.sh"
    source "${ROOT_DIR}/profiles/singbox-gcore.sh"
) || fail "re-sourcing singbox-gcore after xhttp-gcore failed with readonly variable or other error"

# 11. Test switch-backend dispatcher
assert_contains "switch-backend initiates migration from singbox" \
    "$(env EASY_ALL_STATE_FILE_OVERRIDE="${TEST_STATE_FILE}" "${ROOT_DIR}/easy_all" switch-backend 2>&1 || true)" \
    "root"

printf 'STATE_VERSION=6\nPROTOCOL=reality\n' >"${TEST_STATE_FILE}"
assert_contains "switch-backend rejects non-gcore mode" \
    "$(env EASY_ALL_STATE_FILE_OVERRIDE="${TEST_STATE_FILE}" "${ROOT_DIR}/easy_all" switch-backend 2>&1 || true)" \
    "switch-backend 仅适用于 Gcore 模式"

printf 'ok - singbox gcore profile tests passed\n'
