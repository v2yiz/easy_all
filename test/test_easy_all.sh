#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"
SCRIPT_COPY="${TMP_DIR}/easy_all.test.sh"
TESTS_RUN=0

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

worker_runtime_matches_protocol() {
    node --input-type=module - "$1" "$2" "$3" <<'EOF'
import fs from 'node:fs';

const source = fs.readFileSync(process.argv[2], 'utf8');
const protocol = process.argv[3];
const portMode = process.argv[4];
const encoded = Buffer.from(source).toString('base64');
const worker = await import(`data:text/javascript;base64,${encoded}`);
const env = {SUB_DOWNLOAD_NAME: 'Team.yaml'};

const plainResponse = await worker.default.fetch(
  new Request('https://worker.test/subscribe?token=test-token'),
  env
);
if (plainResponse.status !== 200) process.exit(1);
const decoded = Buffer.from(await plainResponse.text(), 'base64').toString('utf8');

const clashResponse = await worker.default.fetch(
  new Request('https://worker.test/subscribe?token=test-token&flag=clash'),
  env
);
if (clashResponse.status !== 200) process.exit(1);
if (clashResponse.headers.get('content-disposition') !== 'attachment; filename=Team') {
  process.exit(1);
}
const yaml = await clashResponse.text();
for (const part of [
  'external-controller:',
  'DOMAIN-SUFFIX,bilibili.com,DIRECT',
  'DOMAIN-SUFFIX,zhihu.com,DIRECT',
  'DOMAIN-SUFFIX,douyin.com,DIRECT',
  'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
  'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
  'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
  'IP-CIDR6,fc00::/7,DIRECT,no-resolve',
  'IP-CIDR6,fe80::/10,DIRECT,no-resolve',
  'DOMAIN,copilot.microsoft.com,PROXY',
  'DOMAIN-SUFFIX,microsoft.com,DIRECT',
  'DOMAIN-SUFFIX,apple-relay.fastly-edge.com,PROXY',
  'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT',
  'DOMAIN,gemini.google.com,AI_GEMINI',
  'DOMAIN-SUFFIX,github.com,PROXY',
  'IP-CIDR6,2001:b28:f23d::/48,PROXY,no-resolve',
  'rule-providers:',
  'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt',
  'size-limit: 4194304',
  'RULE-SET,private,DIRECT',
  'RULE-SET,google,PROXY',
  'RULE-SET,direct,DIRECT',
  'RULE-SET,telegramcidr,PROXY,no-resolve',
  'RULE-SET,cncidr,DIRECT,no-resolve',
  'GEOSITE,geolocation-!cn,PROXY',
  'GEOIP,CN,DIRECT,no-resolve'
]) {
  if (!yaml.includes(part)) process.exit(1);
}
if (/edgeone\.gh-proxy\.org|RULE-SET,applications,|^    applications:/m.test(yaml)) process.exit(1);
for (const removedDomain of [
  'bytedance.net',
  'larkoffice.com',
  'feishu.cn',
  'bytedance.com',
  'larkenterprise.com'
]) {
  if (yaml.includes(removedDomain)) process.exit(1);
}
if (!/^proxy-groups:$/m.test(yaml)) process.exit(1);
if ((yaml.match(/^\s+- name: PROXY$/gm) || []).length !== 1) process.exit(1);
if ((yaml.match(/^\s+- name: AI_GEMINI$/gm) || []).length !== 1) process.exit(1);
if (/^\s+- name: (?:AI|DOWNLOAD)$/m.test(yaml)) process.exit(1);

const formerKeyResponse = await worker.default.fetch(
  new Request('https://worker.test/subscribe?token=owner'),
  env
);
if (formerKeyResponse.status !== 403) process.exit(1);

const checks = {
  reality: {
    link: ['vless://00000000-0000-4000-8000-000000000001@203.0.113.10:',
      'security=reality', 'type=tcp', 'fp=chrome', 'flow=xtls-rprx-vision',
      'pbk=test-public-key', 'sid=0123456789abcdef', '#MY_REALITY'],
    yaml: ['type: vless', 'network: tcp', 'tls: true', 'reality-opts:',
      'public-key: "test-public-key"', 'client-fingerprint: "chrome"', 'flow: xtls-rprx-vision']
  },
  anytls: {
    link: ['anytls://test-anytls-password@anytls.example.com:', 'sni=anytls.example.com',
      'insecure=0', '#MY_ANYTLS'],
    yaml: ['type: anytls', 'server: "anytls.example.com"',
      'password: "test-anytls-password"', 'client-fingerprint: "chrome"']
  }
};
for (const part of checks[protocol].link) {
  if (!decoded.includes(part)) process.exit(1);
}
for (const part of checks[protocol].yaml) {
  if (!yaml.includes(part)) process.exit(1);
}
const port = Number(decoded.match(/@[^:]+:(\d+)/)?.[1]);
if (portMode === '443') {
  if (port !== 443) process.exit(1);
} else if (!Number.isInteger(port) || port < 10000 || port > 65535) {
  process.exit(1);
}
EOF
}

worker_runtime_accepts_default_node_array() {
    node --input-type=module - "$1" <<'EOF'
import fs from 'node:fs';

const source = fs.readFileSync(process.argv[2], 'utf8')
  .replace(/const DEFAULT_NODE = .*?;/, 'const DEFAULT_NODE = [NODE_CONFIG, NODE_CONFIG];');
const encoded = Buffer.from(source).toString('base64');
const worker = await import(`data:text/javascript;base64,${encoded}`);
const env = {SUB_DOWNLOAD_NAME: 'Team.yaml'};

const plainResponse = await worker.default.fetch(
  new Request('https://worker.test/subscribe?token=test-token'),
  env
);
if (plainResponse.status !== 200) process.exit(1);
const links = Buffer.from(await plainResponse.text(), 'base64').toString('utf8').split('\n');
if (links.length !== 2) process.exit(1);
if (!links[0] || !links[1]) process.exit(1);

const clashResponse = await worker.default.fetch(
  new Request('https://worker.test/subscribe?token=test-token&flag=clash'),
  env
);
if (clashResponse.status !== 200) process.exit(1);
const yaml = await clashResponse.text();
if ((yaml.match(/^  - name: /gm) || []).length !== 2) process.exit(1);
EOF
}

invalid_allowed_tokens_rejected() {
    ! normalize_allowed_tokens "$1" >/dev/null 2>&1
}

missing_allowed_tokens_rejected() {
    (unset ALLOWED_TOKENS; ensure_allowed_tokens) >/dev/null 2>&1
    [[ $? -ne 0 ]]
}

source_script_copy() {
    sed \
        -e "s|^readonly STATE_DIR=.*|readonly STATE_DIR=\"${TMP_DIR}/state\"|" \
        -e "s|^readonly WORKER_FILE=.*|readonly WORKER_FILE=\"${TMP_DIR}/state/subscribe-worker.js\"|" \
        -e "s|^readonly CERT_DIR=.*|readonly CERT_DIR=\"${TMP_DIR}/state/certs\"|" \
        -e "s|^readonly CERT_FILE=.*|readonly CERT_FILE=\"${TMP_DIR}/state/certs/fullchain.pem\"|" \
        -e "s|^readonly KEY_FILE=.*|readonly KEY_FILE=\"${TMP_DIR}/state/certs/private.key\"|" \
        -e "s|^readonly COMMAND_INSTALL_DIR=.*|readonly COMMAND_INSTALL_DIR=\"${TMP_DIR}/cmd\"|" \
        -e "s|^readonly COMMAND_PATH=.*|readonly COMMAND_PATH=\"${TMP_DIR}/bin/easy_all\"|" \
        -e "s|^readonly CERT_RELOAD_HOOK=.*|readonly CERT_RELOAD_HOOK=\"${TMP_DIR}/cmd/reload-tls.sh\"|" \
        -e "s|^readonly XRAY_DIR=.*|readonly XRAY_DIR=\"${TMP_DIR}/state/xray\"|" \
        -e "s|^readonly XRAY_BIN=.*|readonly XRAY_BIN=\"${TMP_DIR}/state/xray/xray\"|" \
        -e "s|^readonly XRAY_CONFIG=.*|readonly XRAY_CONFIG=\"${TMP_DIR}/state/xray/config.json\"|" \
        -e "s|^readonly XRAY_SERVICE_FILE=.*|readonly XRAY_SERVICE_FILE=\"${TMP_DIR}/easy-all-xray.service\"|" \
        -e "s|^readonly SING_BOX_DIR=.*|readonly SING_BOX_DIR=\"${TMP_DIR}/state/sing-box\"|" \
        -e "s|^readonly SING_BOX_BIN=.*|readonly SING_BOX_BIN=\"${TMP_DIR}/state/sing-box/sing-box\"|" \
        -e "s|^readonly SING_BOX_CONFIG=.*|readonly SING_BOX_CONFIG=\"${TMP_DIR}/state/sing-box/config.json\"|" \
        -e "s|^readonly SING_BOX_SERVICE_FILE=.*|readonly SING_BOX_SERVICE_FILE=\"${TMP_DIR}/easy-all-sing-box.service\"|" \
        -e "s|^readonly ACME_HOME=.*|readonly ACME_HOME=\"${TMP_DIR}/acme\"|" \
        -e "s|^readonly ACME_BIN=.*|readonly ACME_BIN=\"${TMP_DIR}/acme/acme.sh\"|" \
        -e "s|^readonly ACME_OWNERSHIP_MARKER=.*|readonly ACME_OWNERSHIP_MARKER=\"${TMP_DIR}/state/acme-installed-by-easy-all\"|" \
        -e "s|^readonly NFT_CONFIG=.*|readonly NFT_CONFIG=\"${TMP_DIR}/nftables.conf\"|" \
        "${ROOT_DIR}/easy_all" >"${SCRIPT_COPY}"
    # shellcheck source=/dev/null
    EASY_ALL_ENTRY_SCRIPT="${ROOT_DIR}/easy_all"
    EASY_ALL_ENTRY_COMMAND=easy_all
    source "${SCRIPT_COPY}"
    SAMPLE_WORKER_SOURCE="${ROOT_DIR}/sample-worker.js"
}

set_protocol_fixture() {
    PROTOCOL=$1
    GEMINI_IP_FAMILY="ipv4"
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    ALLOWED_TOKENS='{"owner":"test-token","friend":"friend-token"}'
    SUB_DOWNLOAD_NAME="MY_SUB"
    SUB_PORT_MODE="dynamic"
    case "${PROTOCOL}" in
    reality)
        NODE_NAME="MY_REALITY"
        NODE_HOST="203.0.113.10"
        REALITY_TARGET="www.cloudflare.com:443"
        REALITY_PUBLIC_KEY="test-public-key"
        REALITY_SHORT_ID="0123456789abcdef"
        ;;
    anytls)
        NODE_NAME="MY_ANYTLS"
        ANYTLS_DOMAIN="anytls.example.com"
        ANYTLS_PASSWORD="test-anytls-password"
        ;;
    esac
}

test_validators_and_defaults() {
    assert_success "Reality target accepts host and port" validate_reality_target "www.cloudflare.com:443"
    assert_failure "Reality target requires port" validate_reality_target "www.cloudflare.com"
    assert_success "Reality protocol is accepted" validate_protocol "reality"
    assert_success "AnyTLS protocol is accepted" validate_protocol "anytls"
    assert_failure "VLESS XHTTP protocol is rejected" validate_protocol "vless-xhttp"
    assert_failure "legacy WSS protocol is rejected" validate_protocol "vless-wss"
    assert_failure "unknown protocol is rejected" validate_protocol "trojan"

    assert_equal "default Worker name is easy-all" "easy-all" "${DEFAULT_WORKER_NAME}"
    assert_success "default Worker name is Cloudflare-compatible" validate_worker_name "${DEFAULT_WORKER_NAME}"
    assert_failure "Worker name rejects underscore" validate_worker_name "easy_all"
    PROTOCOL="reality"
    NODE_HOST="203.0.113.10"
    assert_success "Worker Custom Domain accepts an independent hostname" \
        validate_worker_custom_domain "sub.example.com"
    assert_failure "Worker Custom Domain rejects workers.dev" \
        validate_worker_custom_domain "test.workers.dev"
    NODE_HOST="sub.example.com"
    assert_failure "Worker Custom Domain cannot reuse the Reality node hostname" \
        validate_worker_custom_domain "sub.example.com"
    PROTOCOL="anytls"
    ANYTLS_DOMAIN="tls.example.com"
    assert_failure "Worker Custom Domain cannot reuse the AnyTLS node hostname" \
        validate_worker_custom_domain "tls.example.com"
    assert_equal "AnyTLS defaults to 443" "443" "${DEFAULT_ANYTLS_PORT_MODE}"
    assert_equal "Reality defaults to dynamic" "dynamic" "${DEFAULT_REALITY_PORT_MODE}"
    PROTOCOL="reality"
    assert_equal "Reality protocol fallback resolves to dynamic" \
        "dynamic" "$(protocol_default_port_mode)"
    PROTOCOL="anytls"
    assert_equal "AnyTLS protocol fallback resolves to 443" \
        "443" "$(protocol_default_port_mode)"
    assert_equal "ALLOWED_TOKENS trims user names and token values" \
        '{"owner":"test-token"}' \
        "$(normalize_allowed_tokens '{" owner ":" test-token "}')" 
    assert_success "ALLOWED_TOKENS rejects arrays" \
        invalid_allowed_tokens_rejected '["test-token"]'
    assert_success "ALLOWED_TOKENS rejects duplicate token values" \
        invalid_allowed_tokens_rejected '{"owner":"same-token","friend":"same-token"}'
    assert_success "ALLOWED_TOKENS rejects unsafe token characters" \
        invalid_allowed_tokens_rejected '{"owner":"bad token"}'
    assert_success "ALLOWED_TOKENS rejects non-string token values" \
        invalid_allowed_tokens_rejected '{"owner":12345678}'
    assert_success "non-interactive mode requires ALLOWED_TOKENS" \
        missing_allowed_tokens_rejected

    SSH_PORTS=""
    append_ssh_port "2222"
    append_ssh_port "22"
    append_ssh_port "2222"
    assert_equal "SSH ports are deduplicated" "2222, 22" "${SSH_PORTS}"
    assert_equal "managed reboot filter preserves unrelated jobs" \
        "5 5 * * * /usr/local/bin/backup" \
        "$(printf '%s\n%s\n' \
            "0 4 * * * /usr/sbin/reboot ${CRON_REBOOT_MARKER}" \
            "5 5 * * * /usr/local/bin/backup" | filter_managed_reboot_cron)"
}

test_reality_node_host_detection() {
    local detected preserved default_target explicit_target
    detected=$(
        NODE_HOST=""
        detect_public_ipv4() { printf '%s\n' "198.51.100.23"; }
        collect_reality_node_host
        printf '%s' "${NODE_HOST}"
    )
    assert_equal "Reality defaults to the detected public IPv4" \
        "198.51.100.23" "${detected}"

    preserved=$(
        NODE_HOST="reality.example.com"
        detect_public_ipv4() { return 1; }
        collect_reality_node_host
        printf '%s' "${NODE_HOST}"
    )
    assert_equal "explicit Reality node domain overrides auto-detection" \
        "reality.example.com" "${preserved}"

    default_target=$(
        REALITY_TARGET=""
        collect_reality_target
        printf '%s' "${REALITY_TARGET}"
    )
    assert_equal "Reality target defaults non-interactively" \
        "${DEFAULT_REALITY_TARGET}" "${default_target}"

    explicit_target=$(
        REALITY_TARGET="cdn.example.com:443"
        collect_reality_target
        printf '%s' "${REALITY_TARGET}"
    )
    assert_equal "explicit Reality SNI target overrides the default" \
        "cdn.example.com:443" "${explicit_target}"
}

test_subscription_port_mode_selection() {
    PROTOCOL="reality"
    SUB_PORT_MODE=""
    collect_sub_port_mode
    assert_equal "Reality non-interactive port mode defaults to dynamic" \
        "dynamic" "${SUB_PORT_MODE}"

    PROTOCOL="anytls"
    SUB_PORT_MODE=""
    collect_sub_port_mode
    assert_equal "AnyTLS non-interactive port mode defaults to 443" \
        "443" "${SUB_PORT_MODE}"

    PROTOCOL="reality"
    SUB_PORT_MODE="2"
    collect_sub_port_mode
    assert_equal "port mode menu choice 2 selects dynamic" \
        "dynamic" "${SUB_PORT_MODE}"

    PROTOCOL="anytls"
    SUB_PORT_MODE="1"
    collect_sub_port_mode
    assert_equal "port mode menu choice 1 selects fixed 443" \
        "443" "${SUB_PORT_MODE}"
}

test_restored_interactive_choices() {
    SING_BOX_VERSION=""
    choose_sing_box_version
    assert_equal "sing-box defaults non-interactively to the latest stable release" \
        "latest" "${SING_BOX_VERSION}"

    SING_BOX_VERSION="stable"
    choose_sing_box_version
    assert_equal "sing-box stable alias selects the latest stable release" \
        "latest" "${SING_BOX_VERSION}"

    SING_BOX_VERSION="prerelease"
    choose_sing_box_version >/dev/null
    assert_equal "sing-box prerelease alias selects Alpha" \
        "alpha" "${SING_BOX_VERSION}"

    assert_success "sing-box accepts an exact stable version" \
        validate_sing_box_selector "1.13.12"
    assert_success "sing-box accepts an exact prerelease version" \
        validate_sing_box_selector "v1.14.0-alpha.26"
    assert_failure "sing-box rejects an invalid version selector" \
        validate_sing_box_selector "newest"

    WORKER_NAME=""
    choose_worker_name 0
    assert_equal "Worker name keeps the easy-all default without a prompt" \
        "${DEFAULT_WORKER_NAME}" "${WORKER_NAME}"

    SUB_DOWNLOAD_NAME="Team.yaml"
    choose_subscription_download_name 0
    assert_equal "Mihomo download prompt normalizes the yaml suffix" \
        "Team" "${SUB_DOWNLOAD_NAME}"

    SING_BOX_VERSION=""
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    SUB_DOWNLOAD_NAME="${DEFAULT_SUB_DOWNLOAD_NAME}"
}

test_subscription_prompt_routing() {
    local output
    output=$(
        collect_installed_state() { :; }
        choose_subscription_mode() { SUBSCRIBE_MODE="auto"; }
        choose_worker_name() { printf 'worker:%s\n' "$1"; }
        collect_worker_custom_domain() { printf 'domain\n'; }
        choose_subscription_download_name() { printf 'download:%s\n' "$1"; }
        write_worker() { :; }
        deploy_worker() { return 0; }
        verify_subscription() { return 0; }
        save_state() { :; }
        DEPLOY_MODE=""
        WORKER_URL=""
        configure_subscription 1 1
    )
    assert_equal "first automatic deployment prompts for Worker, domain and download names" \
        $'worker:1\ndomain\ndownload:1' "${output}"

    output=$(
        collect_installed_state() { :; }
        choose_subscription_mode() { SUBSCRIBE_MODE="auto"; }
        choose_worker_name() { printf 'worker:%s\n' "$1"; }
        collect_worker_custom_domain() { printf 'domain\n'; }
        choose_subscription_download_name() { printf 'download:%s\n' "$1"; }
        write_worker() { :; }
        deploy_worker() { return 0; }
        verify_subscription() { return 0; }
        save_state() { :; }
        DEPLOY_MODE="auto"
        WORKER_URL="https://existing-worker.example.test"
        configure_subscription 1 1
    )
    assert_equal "existing automatic deployment reuses its Worker and collects its domain" \
        $'worker:0\ndomain\ndownload:1' "${output}"

    output=$(
        collect_installed_state() { :; }
        choose_subscription_mode() { SUBSCRIBE_MODE="worker"; }
        choose_worker_name() { printf 'unexpected-worker\n'; }
        choose_subscription_download_name() { printf 'download:%s\n' "$1"; }
        write_worker() { :; }
        print_worker_content() { :; }
        save_state() { :; }
        configure_subscription 1 1
    )
    assert_equal "manual deployment asks only for the download name" \
        "download:1" "${output}"
}

test_worker_custom_domain_lifecycle() {
    local api_calls="${TMP_DIR}/custom-domain-api-calls"
    local get_count_file="${TMP_DIR}/custom-domain-get-count"
    local original_cloudflare_api original_cloudflare_deploy_log
    original_cloudflare_api=$(declare -f cloudflare_api)
    original_cloudflare_deploy_log=$(declare -f cloudflare_deploy_log)
    : >"${api_calls}"
    printf '0\n' >"${get_count_file}"
    CF_ACCOUNT_ID="0123456789abcdef0123456789abcdef"
    WORKER_NAME="easy-all"
    WORKER_CUSTOM_DOMAIN="sub.example.com"
    WORKER_DEV_URL="https://easy-all.account.workers.dev"
    WORKER_URL=${WORKER_DEV_URL}
    CUSTOM_DOMAIN_API_MODE="create"
    cloudflare_deploy_log() { :; }
    cloudflare_api() {
        local method=$1 path=$2
        shift 3
        printf '%s\t%s\t%s\n' "${method}" "${path}" "$*" >>"${api_calls}"
        if [[ "${method}" == "GET" ]]; then
            case "${CUSTOM_DOMAIN_API_MODE}" in
            existing)
                printf '%s' '{"success":true,"result":[{"hostname":"sub.example.com","service":"easy-all"}]}'
                ;;
            conflict)
                printf '%s' '{"success":true,"result":[{"hostname":"sub.example.com","service":"another-worker"}]}'
                ;;
            late-existing)
                local get_count
                get_count=$(<"${get_count_file}")
                get_count=$((get_count + 1))
                printf '%s\n' "${get_count}" >"${get_count_file}"
                if ((get_count == 1)); then
                    printf '%s' '{"success":true,"result":[]}'
                else
                    printf '%s' '{"success":true,"result":[{"hostname":"sub.example.com","service":"easy-all"}]}'
                fi
                ;;
            *) printf '%s' '{"success":true,"result":[]}' ;;
            esac
        elif [[ "${CUSTOM_DOMAIN_API_MODE}" == "late-existing" ]]; then
            printf '%s' '{"success":false,"errors":[{"code":100117,"message":"conflict"}]}'
        else
            printf '%s' '{"success":true,"result":{"hostname":"sub.example.com","service":"easy-all"}}'
        fi
    }

    assert_success "new automatic deployment creates its Custom Domain" \
        attach_worker_custom_domain
    assert_equal "new Custom Domain becomes the preferred Worker URL" \
        "https://sub.example.com" "${WORKER_URL}"
    assert_success "Custom Domain attach uses the account domains API" \
        grep -Fq $'PUT\t/accounts/0123456789abcdef0123456789abcdef/workers/domains' \
        "${api_calls}"

    CUSTOM_DOMAIN_API_MODE="existing"
    : >"${api_calls}"
    WORKER_URL=${WORKER_DEV_URL}
    assert_success "repeated deployment reuses its existing Custom Domain" \
        attach_worker_custom_domain
    assert_equal "reused Custom Domain remains the preferred Worker URL" \
        "https://sub.example.com" "${WORKER_URL}"
    assert_equal "reused Custom Domain is not attached again" \
        "0" "$(grep -c $'^PUT\t' "${api_calls}" || true)"

    CUSTOM_DOMAIN_API_MODE="conflict"
    : >"${api_calls}"
    WORKER_URL=${WORKER_DEV_URL}
    assert_failure "deployment refuses a Custom Domain owned by another Worker" \
        attach_worker_custom_domain
    assert_equal "foreign Custom Domain does not replace workers.dev" \
        "${WORKER_DEV_URL}" "${WORKER_URL}"

    CUSTOM_DOMAIN_API_MODE="late-existing"
    : >"${api_calls}"
    printf '0\n' >"${get_count_file}"
    WORKER_URL=${WORKER_DEV_URL}
    assert_success "concurrent attach reuses a domain confirmed on final read" \
        attach_worker_custom_domain
    assert_equal "concurrently attached domain becomes the preferred URL" \
        "https://sub.example.com" "${WORKER_URL}"
    assert_equal "concurrent attach performs one final hostname query" \
        "2" "$(<"${get_count_file}")"

    unset -f cloudflare_api cloudflare_deploy_log
    eval "${original_cloudflare_api}"
    eval "${original_cloudflare_deploy_log}"
}

test_links_and_workers() {
    local protocol port_mode link yaml worker sample_rules generated_rules
    for protocol in reality anytls; do
        set_protocol_fixture "${protocol}"
        link=$(build_node_link)
        yaml=$(build_mihomo_node)
        assert_contains "${protocol} node link contains node name" "${NODE_NAME}" "${link}"
        assert_contains "${protocol} Mihomo node contains name" "${NODE_NAME}" "${yaml}"
        for port_mode in dynamic 443; do
            SUB_PORT_MODE="${port_mode}"
            worker="${TMP_DIR}/worker-${protocol}-${port_mode}.js"
            write_worker "${worker}"
            assert_success "${protocol}/${port_mode} Worker JavaScript syntax valid" node --check "${worker}"
            assert_success "${protocol}/${port_mode} Worker emits base64 and Mihomo outputs" \
                worker_runtime_matches_protocol "${worker}" "${protocol}" "${port_mode}"
            assert_success "${protocol}/${port_mode} Worker accepts DEFAULT_NODE array" \
                worker_runtime_accepts_default_node_array "${worker}"
            sample_rules=$(awk '
                $0 == "// EASY_ALL_RULES_START" {capture = 1}
                capture == 1 {print}
                $0 == "// EASY_ALL_RULES_END" {exit}
            ' "${ROOT_DIR}/sample-worker.js")
            generated_rules=$(awk '
                $0 == "// EASY_ALL_RULES_START" {capture = 1}
                capture == 1 {print}
                $0 == "// EASY_ALL_RULES_END" {exit}
            ' "${worker}")
            assert_equal "${protocol}/${port_mode} Worker rules come unchanged from sample-worker.js" \
                "${sample_rules}" "${generated_rules}"
        done
    done
}

test_sample_worker_template_guards() {
    local invalid_template="${TMP_DIR}/invalid-sample-worker.js"
    local duplicate_policy="${TMP_DIR}/duplicate-policy-worker.js"
    local uppercase_policy="${TMP_DIR}/uppercase-policy-worker.js"
    local gemini_policy
    awk '$0 != "// EASY_ALL_RULES_END"' \
        "${ROOT_DIR}/sample-worker.js" >"${invalid_template}"
    assert_success "sample Worker rejects a missing rules boundary" \
        sample_worker_validation_fails "${invalid_template}"

    awk '$0 != "/* EASY_ALL_GEMINI_DOMAINS_END */"' \
        "${ROOT_DIR}/sample-worker.js" >"${invalid_template}"
    assert_success "sample Worker rejects a missing Gemini policy boundary" \
        sample_worker_validation_fails "${invalid_template}"

    sed 's/"googleapis.com"/"google.com"/' \
        "${ROOT_DIR}/sample-worker.js" >"${duplicate_policy}"
    assert_success "sample Worker rejects duplicate Gemini domains" \
        sample_worker_validation_fails "${duplicate_policy}"

    sed 's/"google.com"/"Google.com"/' \
        "${ROOT_DIR}/sample-worker.js" >"${uppercase_policy}"
    assert_success "sample Worker rejects non-normalized Gemini domains" \
        sample_worker_validation_fails "${uppercase_policy}"

    gemini_policy=$(extract_gemini_domain_suffixes "${ROOT_DIR}/sample-worker.js")
    assert_success "sample Worker limits the family policy to Gemini and Google dependencies" \
        jq -e \
            'index("google.com")
             and index("googleapis.com")
             and index("gstatic.com")
             and (index("openai.com") | not)
             and (index("claude.ai") | not)
             and (index("mega.nz") | not)' \
            <<<"${gemini_policy}"

    assert_success "sample Worker source rejects plain HTTP" \
        sample_worker_fetch_fails "http://example.com/sample-worker.js"
}

test_server_egress_family_configs() {
    local protocol config
    install -d -m 0755 "${XRAY_DIR}" "${SING_BOX_DIR}"
    printf '%s\n' \
        '#!/bin/sh' \
        'if [ "$1" = "x25519" ]; then printf "PublicKey: test-public-key\\n"; fi' \
        'exit 0' >"${XRAY_BIN}"
    printf '%s\n' '#!/bin/sh' 'exit 0' >"${SING_BOX_BIN}"
    chmod 0755 "${XRAY_BIN}" "${SING_BOX_BIN}"

    for protocol in reality; do
        set_protocol_fixture "${protocol}"
        REALITY_PRIVATE_KEY="test-private-key"
        write_xray_config
        config=$(<"${XRAY_CONFIG}")

        assert_equal "${protocol} Xray Gemini outbound follows the selected IPv4 family" \
            "ForceIPv4" \
            "$(jq -r '.outbounds[] | select(.tag == "gemini-family") | .settings.domainStrategy' \
                <<<"${config}")"
        assert_equal "${protocol} Xray keeps a separate normal direct outbound" \
            "direct" "$(jq -r '.outbounds[] | select(.tag == "direct") | .tag' <<<"${config}")"
        assert_equal "${protocol} Xray uses normal direct as the default outbound" \
            "direct" "$(jq -r '.outbounds[0].tag' <<<"${config}")"
        assert_success "${protocol} Xray enables HTTP TLS and QUIC sniffing" \
            jq -e \
                '.inbounds[0].sniffing.enabled == true
                 and (.inbounds[0].sniffing.destOverride == ["http", "tls", "quic"])
                 and .inbounds[0].sniffing.routeOnly == false' \
                <<<"${config}"
        assert_success "${protocol} Xray routes only Gemini through the fixed-family outbound" \
            jq -e \
                '.routing.rules[0].outboundTag == "gemini-family"
                 and ((.routing.rules[0].domain | index("domain:openai.com")) == null)
                 and ((.routing.rules[0].domain | index("domain:claude.ai")) == null)
                 and (.routing.rules[0].domain | index("domain:google.com"))
                 and (.routing.rules[0].domain | index("domain:googleapis.com"))
                 and ((.routing.rules[0].domain | index("domain:mega.nz")) == null)
                 and ((.routing.rules[0].domain | map(startswith("full:")) | any) == false)' \
                <<<"${config}"
        assert_success "${protocol} Xray explicitly sends every unmatched flow to normal direct" \
            jq -e \
                '(.routing.rules | length) == 2
                 and .routing.rules[1].type == "field"
                 and .routing.rules[1].network == "tcp,udp"
                 and .routing.rules[1].outboundTag == "direct"
                 and (.routing.rules[1] | has("domain") | not)' \
                <<<"${config}"
    done

    set_protocol_fixture "reality"
    REALITY_PRIVATE_KEY="test-private-key"
    GEMINI_IP_FAMILY="ipv6"
    write_xray_config
    config=$(<"${XRAY_CONFIG}")
    assert_equal "Xray strictly fixes Gemini to IPv6 when selected" \
        "ForceIPv6" \
        "$(jq -r '.outbounds[] | select(.tag == "gemini-family") | .settings.domainStrategy' \
            <<<"${config}")"
    set_protocol_fixture "anytls"
    write_sing_box_config
    config=$(<"${SING_BOX_CONFIG}")
    assert_equal "sing-box Gemini outbound follows the selected IPv4 family" \
        "ipv4_only" \
        "$(jq -r '.outbounds[] | select(.tag == "gemini-family") | .domain_resolver.strategy' \
            <<<"${config}")"
    assert_equal "sing-box keeps a separate normal direct outbound" \
        "direct" "$(jq -r '.outbounds[] | select(.tag == "direct") | .tag' <<<"${config}")"
    assert_success "sing-box sniffs before applying the Gemini route" \
        jq -e \
            '.route.rules[0].action == "sniff"
             and .route.rules[1].action == "route"
             and .route.rules[1].outbound == "gemini-family"
             and (.route.rules | length) == 2
             and .route.final == "direct"' \
            <<<"${config}"
    assert_success "sing-box routes only Gemini through the fixed-family outbound" \
        jq -e \
            '((.route.rules[1].domain_suffix | index("openai.com")) == null)
             and ((.route.rules[1].domain_suffix | index("claude.ai")) == null)
             and (.route.rules[1].domain_suffix | index("google.com"))
             and (.route.rules[1].domain_suffix | index("googleapis.com"))
             and ((.route.rules[1].domain_suffix | index("mega.nz")) == null)
             and (.route.rules[1] | has("domain") | not)' \
            <<<"${config}"

    GEMINI_IP_FAMILY="ipv6"
    write_sing_box_config
    config=$(<"${SING_BOX_CONFIG}")
    assert_equal "sing-box strictly fixes Gemini to IPv6 when selected" \
        "ipv6_only" \
        "$(jq -r '.outbounds[] | select(.tag == "gemini-family") | .domain_resolver.strategy' \
            <<<"${config}")"
    assert_success "auto Gemini family selects the faster IPv6 route on a dual-stack VPS" \
        bash -c '
            source "$1"
            ip() {
                case "$*" in
                "-6 addr show scope global") printf "inet6 2001:db8::1/64 scope global\n" ;;
                "-6 route show default") printf "default via 2001:db8::ffff dev eth0\n" ;;
                esac
            }
            measure_gemini_ip_family() {
                [[ "$1" == "ipv6" ]] && printf "1.0\n" || printf "2.0\n"
            }
            GEMINI_IP_FAMILY=auto
            resolve_gemini_ip_family
            [[ "${GEMINI_IP_FAMILY_RESOLVED}" == "ipv6" ]]
        ' _ "${SCRIPT_COPY}"
    assert_success "auto Gemini family selects IPv4 when the VPS has no usable IPv6 route" \
        bash -c '
            source "$1"
            ip() { :; }
            measure_gemini_ip_family() { [[ "$1" == "ipv4" ]] && printf "1.0\n"; }
            GEMINI_IP_FAMILY=auto
            resolve_gemini_ip_family
            [[ "${GEMINI_IP_FAMILY_RESOLVED}" == "ipv4" ]]
        ' _ "${SCRIPT_COPY}"

    assert_success "one fetched Worker policy drives both server and generated Worker" \
        custom_worker_policy_drives_server_and_worker
}

sample_worker_validation_fails() {
    ! (validate_sample_worker "$1") >/dev/null 2>&1
}

sample_worker_fetch_fails() {
    ! (
        SAMPLE_WORKER_SOURCE=$1
        fetch_sample_worker "${TMP_DIR}/invalid-fetched-worker.js"
    ) >/dev/null 2>&1
}

custom_worker_policy_drives_server_and_worker() (
    local custom_template="${TMP_DIR}/custom-policy-worker.js"
    local generated_worker="${TMP_DIR}/custom-policy-generated-worker.js"
    sed 's/"googleapis.com"/"policy-source.example"/' \
        "${ROOT_DIR}/sample-worker.js" >"${custom_template}"
    SAMPLE_WORKER_TEMPLATE_FILE=""
    GEMINI_DOMAIN_SUFFIXES_JSON=""
    SAMPLE_WORKER_SOURCE=${custom_template}
    set_protocol_fixture "reality"
    REALITY_PRIVATE_KEY="test-private-key"

    write_xray_config
    SAMPLE_WORKER_SOURCE="${TMP_DIR}/source-must-not-be-fetched-again.js"
    write_worker "${generated_worker}"

    jq -e \
        '(.routing.rules[0].domain | index("domain:policy-source.example"))
         and ((.routing.rules[0].domain | index("domain:googleapis.com")) == null)' \
        "${XRAY_CONFIG}" >/dev/null \
        && grep -Fq '"policy-source.example"' "${generated_worker}" \
        && ! grep -Fq '"googleapis.com"' "${generated_worker}"
)

test_worker_only_subscription_branch() {
    local output content output_file
    set_protocol_fixture "reality"
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    WORKER_URL="https://old-worker.example.test"
    DEPLOY_MODE="auto"
    save_state

    SUBSCRIBE_MODE="worker"
    output_file="${TMP_DIR}/worker-only-output"
    configure_subscription >"${output_file}"
    output=$(<"${output_file}")
    content=$(<"${WORKER_FILE}")

    assert_contains "worker-only branch prints embedded-token notice" \
        "ALLOWED_TOKENS 已内嵌" "${output}"
    assert_contains "worker-only branch emits ALLOWED_TOKENS dict" \
        'const ALLOWED_TOKENS = {"owner":"test-token","friend":"friend-token"};' "${content}"
    assert_contains "worker-only branch emits CONFIGS array" \
        "const CONFIGS = [];" "${content}"
    assert_contains "worker-only branch emits installed node config" \
        "const NODE_CONFIG = defineNode(" "${content}"
    assert_contains "worker-only branch emits DEFAULT_NODE selector" \
        "const DEFAULT_NODE = NODE_CONFIG;" "${content}"
    assert_contains "worker-only branch uses sample Clash rules" \
        "DOMAIN-SUFFIX,bilibili.com,DIRECT" "${content}"
    assert_contains "worker-only branch authenticates by token values" \
        "ALLOWED_TOKEN_VALUES.has(token)" "${content}"
    assert_not_contains "worker-only branch does not depend on SUB_TOKEN secret" \
        "env.SUB_TOKEN" "${content}"
    assert_not_contains "worker-only branch does not print legacy secret command" \
        "secret put SUB_TOKEN" "${output}"
    assert_equal "worker-only branch clears deployed Worker URL" "" "${WORKER_URL}"
    assert_equal "worker-only branch stores manual deploy mode" "worker" "${DEPLOY_MODE}"
    assert_success "worker-only branch generated Worker works" \
        worker_runtime_matches_protocol "${WORKER_FILE}" "reality" "${SUB_PORT_MODE}"
}

test_link_only_subscription_skips_tokens() {
    local content
    set_protocol_fixture "reality"
    ALLOWED_TOKENS=""
    WORKER_URL=""
    DEPLOY_MODE="link"
    SUBSCRIBE_MODE="link"
    save_state

    assert_success "link-only subscription works without ALLOWED_TOKENS" \
        configure_subscription
    content=$(<"${STATE_FILE}")
    assert_contains "link-only mode persists its deployment choice" \
        "DEPLOY_MODE=link" "${content}"
    assert_contains "link-only mode keeps the token field empty" \
        "ALLOWED_TOKENS=''" "${content}"
}

test_state_and_lifecycle_guards() {
    set_protocol_fixture "anytls"
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    WORKER_URL="https://sub.example.com"
    WORKER_DEV_URL="https://easy-all.account.workers.dev"
    WORKER_CUSTOM_DOMAIN="sub.example.com"
    CF_ACCOUNT_ID="account-id"
    DEPLOY_MODE="worker"
    CF_DNS_API_TOKEN="dns-token-must-not-be-saved"
    CF_WORKER_API_TOKEN="worker-token-must-not-be-saved"

    save_state
    local content script_content readme_content
    content=$(<"${STATE_FILE}")
    assert_contains "state saves version" "STATE_VERSION=1" "${content}"
    assert_contains "state saves selected protocol" "PROTOCOL=anytls" "${content}"
    assert_contains "state saves AnyTLS domain" "ANYTLS_DOMAIN=anytls.example.com" "${content}"
    assert_contains "state saves AnyTLS password" "ANYTLS_PASSWORD=test-anytls-password" "${content}"
    assert_not_contains "state does not save XHTTP domain" "VLESS_XHTTP_DOMAIN=" "${content}"
    assert_not_contains "state does not save XHTTP path" "XHTTP_PATH=" "${content}"
    assert_contains "state saves default Worker" "WORKER_NAME=easy-all" "${content}"
    assert_contains "state saves the preferred Worker URL" \
        "WORKER_URL=https://sub.example.com" "${content}"
    assert_contains "state saves the workers.dev fallback" \
        "WORKER_DEV_URL=https://easy-all.account.workers.dev" "${content}"
    assert_contains "state saves the Worker Custom Domain" \
        "WORKER_CUSTOM_DOMAIN=sub.example.com" "${content}"
    assert_contains "state saves the Gemini address-family preference" \
        "GEMINI_IP_FAMILY=ipv4" "${content}"
    assert_contains "state saves allowed token dict" "ALLOWED_TOKENS=" "${content}"
    assert_not_contains "state does not save SUB_TOKEN field" "SUB_TOKEN=" "${content}"
    assert_not_contains "state does not save DNS token" "dns-token-must-not-be-saved" "${content}"
    assert_not_contains "state does not save Worker token" "worker-token-must-not-be-saved" "${content}"
    assert_success "saved state reloads without readonly variable conflicts" load_state
    assert_equal "reloaded state version matches the schema" \
        "${STATE_SCHEMA_VERSION}" "${STATE_VERSION}"

    cat >"${STATE_FILE}" <<'EOF'
STATE_VERSION=1
PROTOCOL=vless-wss
VLESS_WSS_DOMAIN=legacy.example.com
WS_PATH=/legacyws
EOF
    assert_failure "legacy WSS state is rejected and redirected to easy_cmcc" \
        bash -c 'source "$1"; source_state_file' _ "${SCRIPT_COPY}"

    script_content=$(<"${ROOT_DIR}/easy_all")
    assert_not_contains "easy_all does not embed Clash rule contents" \
        "DOMAIN-SUFFIX,bilibili.com,DIRECT" "${script_content}"
    assert_not_contains "easy_all does not embed the fake IP filter" \
        "const FAKE_IP_FILTER =" "${script_content}"
    assert_contains "easy_all reads rules from the sample Worker" \
        "fetch_sample_worker" "${script_content}"
    assert_not_contains "easy_all does not contain a MEGA IPv4-only policy" \
        'IPV4_ONLY_DOMAIN_SUFFIXES_JSON' "${script_content}"
    assert_contains "easy_all extracts the Gemini family policy from the sample Worker" \
        "extract_gemini_domain_suffixes" "${script_content}"
    assert_contains "easy_all validates the sample rules boundary" \
        "// EASY_ALL_RULES_START" "${script_content}"
    assert_contains "easy_all defaults to the repository sample Worker URL" \
        'url=${SAMPLE_WORKER_URL:-${DEFAULT_SAMPLE_WORKER_URL}}' "${script_content}"
    assert_not_contains "easy_all never auto-loads an adjacent sample Worker" \
        'local_sample="${SCRIPT_DIR}/sample-worker.js"' "${script_content}"
    assert_contains "command registration removes legacy sample Worker caches" \
        'rm -f -- "${COMMAND_INSTALL_DIR}/sample-worker.js"' "${script_content}"
    assert_not_contains "easy_all never installs a sample Worker cache" \
        'install -m 0644 "${destination}" "${COMMAND_INSTALL_DIR}/sample-worker.js"' \
        "${script_content}"
    assert_contains "script warns DNS-only before install" "DNS only / 灰云" "${script_content}"
    assert_contains "script keeps AAAA DNS-only before install or switch" \
        "AAAA 记录，也必须保持 DNS only / 灰云并指向当前 VPS 公网 IPv6" \
        "${script_content}"
    assert_contains "script renders pre-install Cloudflare notice in red" \
        'alert "AnyTLS 安装前请确认 Cloudflare DNS A 记录' "${script_content}"
    assert_contains "script rejects XHTTP and points to easy_cmcc" \
        "XHTTP/WSS 请使用 for_cmcc/easy_cmcc" "${script_content}"
    assert_not_contains "script has no Nginx XHTTP proxy" "grpc_pass" "${script_content}"
    assert_not_contains "script has no XHTTP transport implementation" 'network: xhttp' "${script_content}"
    assert_not_contains "script has no WSS transport implementation" 'network: ws' "${script_content}"
    assert_not_contains "client proxy nodes keep the local default address family" \
        'ip-version: ipv4-prefer' "${script_content}"
    assert_contains "script retries Cloudflare rate limits" "408 | 429 | 500 | 502 | 503 | 504" "${script_content}"
    assert_contains "script retries Cloudflare propagation errors" "10007" "${script_content}"
    assert_contains "script retries concurrent Worker updates" "10035" "${script_content}"
    assert_contains "script writes Worker deployment log" "last-worker-deploy.log" "${script_content}"
    assert_contains "script pins acme.sh to its managed home" \
        '"${ACME_BIN}" "$@" --home "${ACME_HOME}"' "${script_content}"
    for acme_action in set-default-ca issue install-cert renew remove list; do
        assert_contains "${acme_action} uses the managed acme.sh wrapper" \
            "run_acme --${acme_action}" "${script_content}"
    done
    assert_not_contains "acme.sh operations do not bypass the managed-home wrapper" \
        '"${ACME_BIN}" --set-default-ca' "${script_content}"
    assert_contains "subscription verification uses Worker version affinity" \
        "Cloudflare-Workers-Version-Key" "${script_content}"
    assert_contains "subscription verification bypasses intermediary caches" \
        "Cache-Control: no-cache" "${script_content}"
    assert_contains "script snapshots protocol switches" "snapshot_protocol_switch" "${script_content}"
    assert_contains "script rolls failed switches back" "rollback_protocol_switch" "${script_content}"
    assert_contains "script avoids rollback after Worker replace" \
        "Worker 已完成 replace" "${script_content}"
    assert_contains "update-sub synchronizes changed ports to nftables" \
        "同步更新 nftables" "${script_content}"
    assert_contains "update-sub refreshes the server policy before the Worker" \
        "refresh_protocol_runtime_config" "${script_content}"
    assert_contains "easy_all bounds receive backlog" "net.core.netdev_max_backlog = 16384" "${script_content}"
    assert_contains "easy_all bounds receive buffers at 32 MiB" "net.core.rmem_max = 33554432" "${script_content}"
    assert_contains "easy_all bounds send buffers at 32 MiB" "net.core.wmem_max = 33554432" "${script_content}"
    assert_contains "easy_all resets legacy TCP Fast Open override" \
        "sysctl -q -w net.ipv4.tcp_fastopen=1" "${script_content}"
    assert_contains "easy_all resets legacy unsent queue override" \
        "sysctl -q -w net.ipv4.tcp_notsent_lowat=4294967295" "${script_content}"
    assert_contains "Reality node prompt offers detected IPv4 as its default" \
        '"${detected_ip}"' "${script_content}"
    assert_contains "Reality setup exposes an SNI target prompt" \
        "Reality SNI / 伪装目标（域名:端口）" "${script_content}"
    assert_contains "interactive setup exposes a subscription port mode prompt" \
        "请选择订阅端口模式" "${script_content}"
    assert_contains "AnyTLS setup exposes a sing-box version menu" \
        "请选择 sing-box 版本" "${script_content}"
    assert_contains "automatic setup exposes a Worker name prompt" \
        "Cloudflare Worker 名称" "${script_content}"
    assert_contains "automatic setup exposes a Worker Custom Domain prompt" \
        "Worker 独立自定义订阅域名" "${script_content}"
    assert_contains "automatic setup uses the Custom Domain API" \
        '/accounts/${CF_ACCOUNT_ID}/workers/domains' "${script_content}"
    assert_not_contains "automatic setup does not configure Worker Routes" \
        '/workers/routes' "${script_content}"
    assert_contains "Worker modes expose a Mihomo download name prompt" \
        "Mihomo 下载文件名（不含 .yaml）" "${script_content}"
    assert_contains "update-sub enables its interactive option menus" \
        "update-sub) update_subscription 1" "${script_content}"
    assert_contains "uninstall explicitly leaves remote Worker and Custom Domain" \
        "远端 Cloudflare Worker 与 Custom Domain 未处理" "${script_content}"
    assert_not_contains "script never deletes remote Worker through API" "DELETE_CLOUDFLARE_WORKER" "${script_content}"

    readme_content=$(<"${ROOT_DIR}/README.md")
    assert_contains "README redirects XHTTP to the CMCC suite" \
        "for_cmcc/easy_cmcc" "${readme_content}"
    assert_contains "README distinguishes shared CMCC-only Zone Token permissions" \
        "Zone Settings → Edit" "${readme_content}"
    assert_contains "README documents Worker subscription verification retry policy" \
        "先等待 10 秒，再进行最多 12 次订阅 HTTP 验收" "${readme_content}"
    assert_contains "README documents automatic Custom Domain reuse" \
        "已经绑定当前 Worker 时直接复用" "${readme_content}"
    assert_contains "README documents reduced client logging" \
        '日志使用 `error` 级别' "${readme_content}"
    assert_contains "README documents disabled process matching" \
        '`find-process-mode: off`' "${readme_content}"
    assert_contains "README removes placeholder DNS setup" \
        "不创建占位 DNS，也不配置 Worker Route" "${readme_content}"
    assert_not_contains "README no longer recommends the 2.2.2.2 placeholder" \
        "2.2.2.2" "${readme_content}"
    assert_not_contains "README download commands do not reuse files based on timestamps" \
        "wget -q -P /root -N" "${readme_content}"
    assert_contains "README downloads updates to a protected temporary path" \
        "wget -qO /root/easy_all.new" "${readme_content}"
    assert_contains "README atomically replaces the installed script" \
        "mv -f /root/easy_all.new /root/easy_all" "${readme_content}"
    assert_not_contains "README omits unattended-operation documentation" \
        "无人值守" "${readme_content}"
}

test_acme_installer_arguments() {
    local installer_args="" acme_args_file="${TMP_DIR}/acme-command-args"
    ANYTLS_DOMAIN="anytls.example.com"
    ACME_EMAIL="ops@example.com"

    curl() {
        local output=""
        while (($#)); do
            case "$1" in
            -o)
                output=$2
                shift 2
                ;;
            *)
                shift
                ;;
            esac
        done
        [[ -n "${output}" ]] || return 1
        install -m 0600 /dev/null "${output}"
    }
    sh() {
        installer_args=$(printf '%s\n' "$@")
        install -d -m 0700 "${ACME_HOME}"
        install -m 0755 /dev/null "${ACME_BIN}"
    }

    install_acme
    unset -f curl sh

    {
        printf '%s\n' '#!/usr/bin/env bash'
        printf '%s\n' 'printf "%s\n" "$@" >"${ACME_ARGS_FILE}"'
    } >"${ACME_BIN}"
    chmod 0755 "${ACME_BIN}"
    export ACME_ARGS_FILE="${acme_args_file}"
    run_acme --set-default-ca --server letsencrypt
    unset ACME_ARGS_FILE

    assert_equal "get.acme.sh receives email in its required first argument" \
        "email=ops@example.com" "$(printf '%s\n' "${installer_args}" | sed -n '2p')"
    assert_equal "get.acme.sh receives --home after the email argument" \
        "--home" "$(printf '%s\n' "${installer_args}" | sed -n '3p')"
    assert_equal "get.acme.sh receives the managed install directory" \
        "${ACME_HOME}" "$(printf '%s\n' "${installer_args}" | sed -n '4p')"
    assert_not_contains "get.acme.sh is not passed the obsolete accountemail option" \
        "--accountemail" "${installer_args}"
    assert_equal "acme.sh wrapper preserves the requested action" \
        "--set-default-ca" "$(sed -n '1p' "${acme_args_file}")"
    assert_equal "acme.sh wrapper appends the home option" \
        "--home" "$(tail -n 2 "${acme_args_file}" | head -n 1)"
    assert_equal "acme.sh wrapper pins the configured home directory" \
        "${ACME_HOME}" "$(tail -n 1 "${acme_args_file}")"
}

test_subscription_retry_policy() {
    local call_file="${TMP_DIR}/subscription-curl-calls"
    local delay_file="${TMP_DIR}/subscription-retry-delays"
    local version_key_file="${TMP_DIR}/subscription-version-keys"
    local calls delays log_content
    printf '0\n' >"${call_file}"
    : >"${delay_file}"
    : >"${version_key_file}"
    install -d -m 0700 "${STATE_DIR}"
    : >"${CLOUDFLARE_DEPLOY_LOG}"
    WORKER_URL="https://worker.example.test"
    ALLOWED_TOKENS='{"owner":"test-token","friend":"friend-token"}'

    curl() {
        local count output="" url="" version_key=""
        count=$(<"${call_file}")
        count=$((count + 1))
        printf '%s\n' "${count}" >"${call_file}"
        while (($#)); do
            case "$1" in
            -o)
                output=$2
                shift 2
                ;;
            -w | --max-time | --connect-timeout)
                shift 2
                ;;
            -H)
                case "$2" in
                'Cloudflare-Workers-Version-Key: '*) version_key=${2#*: } ;;
                esac
                shift 2
                ;;
            -sS)
                shift
                ;;
            *)
                url=$1
                shift
                ;;
            esac
        done
        [[ -n "${output}" && -n "${url}" ]] || return 1
        printf '%s\n' "${version_key}" >>"${version_key_file}"
        if ((count <= 6)); then
            printf 'Forbidden\n' >"${output}"
            printf '403'
        elif [[ "${url}" == *"&flag=clash"* ]]; then
            printf 'proxies:\nproxy-groups:\nrules:\n' >"${output}"
            printf '200'
        else
            printf 'vless://test@example.com:443\n' | base64 >"${output}"
            printf '200'
        fi
    }
    sleep() {
        printf '%s\n' "$1" >>"${delay_file}"
    }

    assert_success "subscription verification eventually succeeds" verify_subscription
    unset -f curl sleep

    calls=$(<"${call_file}")
    delays=$(<"${delay_file}")
    log_content=$(<"${CLOUDFLARE_DEPLOY_LOG}")
    assert_equal "subscription verification requests both formats for four attempts" "8" "${calls}"
    assert_equal "subscription verification waits ten seconds before its first request" \
        "10" "$(sed -n '1p' "${delay_file}")"
    assert_equal "subscription verification sleeps only before and between failed attempts" \
        "4" "$(wc -l <"${delay_file}" | tr -d '[:space:]')"
    assert_success "subscription retry intervals stay between two and five seconds" \
        awk 'NR == 1 {next} $1 < 2 || $1 > 5 {exit 1}' "${delay_file}"
    assert_equal "base64 and Clash use the same version key in attempt one" \
        "$(sed -n '1p' "${version_key_file}")" "$(sed -n '2p' "${version_key_file}")"
    assert_equal "base64 and Clash use the same version key in attempt four" \
        "$(sed -n '7p' "${version_key_file}")" "$(sed -n '8p' "${version_key_file}")"
    assert_failure "different attempts use different Worker version keys" \
        test "$(sed -n '1p' "${version_key_file}")" = "$(sed -n '3p' "${version_key_file}")"
    assert_contains "subscription verification logs twelve maximum attempts" \
        "第 4/12 次，base64 HTTP 200，Clash HTTP 200" "${log_content}"
    assert_contains "subscription retry log includes its randomized delay" \
        "秒后重试" "${log_content}"
    assert_contains "captured subscription delays include retry intervals" $'10\n' "${delays}"
}

test_cloudflare_api_retry_policy() {
    local headers="${TMP_DIR}/cloudflare-response-headers"
    : >"${headers}"

    assert_equal "Cloudflare Retry-After header takes priority" "120" \
        "$(printf 'Retry-After: 120\r\n' >"${headers}"; \
            cloudflare_retry_after "${headers}" '{"retry_after":60}')"
    : >"${headers}"
    assert_equal "Cloudflare structured error body supplies Retry-After fallback" "60" \
        "$(cloudflare_retry_after "${headers}" '{"retry_after":60}')"
    assert_equal "Cloudflare retry delay honors a 520 backoff" "60" \
        "$(cloudflare_retry_delay 1 60)"
    assert_equal "Cloudflare retry delay honors a 521 backoff" "120" \
        "$(cloudflare_retry_delay 1 120)"
    assert_equal "Cloudflare retry delay caps unreasonable values" "300" \
        "$(cloudflare_retry_delay 1 3600)"
    assert_equal "Cloudflare retry delay keeps exponential fallback" "8" \
        "$(cloudflare_retry_delay 4 '')"
}

test_update_subscription_rolls_back_port_change() {
    local status state_content nft_content nft_hash
    local nft_calls="${TMP_DIR}/update-sub-nft-calls"
    set_protocol_fixture "reality"
    SUB_PORT_MODE="443"
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    WORKER_URL="https://old-worker.example.test"
    CF_ACCOUNT_ID="account-id"
    DEPLOY_MODE="auto"
    save_state
    install -d -m 0755 "$(dirname "${XRAY_CONFIG}")"
    printf 'old runtime\n' >"${XRAY_CONFIG}"
    printf 'old worker\n' >"${WORKER_FILE}"
    printf 'old nftables\n' >"${NFT_CONFIG}"
    printf 'old-hash\n' >"${STATE_DIR}/nftables.sha256"
    : >"${nft_calls}"

    require_root() { :; }
    prepare_sample_worker_template() { :; }
    configure_nftables() {
        printf 'new nftables\n' >"${NFT_CONFIG}"
        printf 'new-hash\n' >"${STATE_DIR}/nftables.sha256"
    }
    refresh_protocol_runtime_config() {
        printf 'new runtime\n' >"${XRAY_CONFIG}"
    }
    configure_subscription() {
        printf 'new worker\n' >"${WORKER_FILE}"
        return 1
    }
    systemctl() { return 0; }
    nft() {
        printf '%s\n' "$*" >>"${nft_calls}"
    }

    SUB_PORT_MODE="dynamic"
    set +e
    ( set -e; update_subscription ) >/dev/null 2>&1
    status=$?
    set -e

    state_content=$(<"${STATE_FILE}")
    nft_content=$(<"${NFT_CONFIG}")
    nft_hash=$(<"${STATE_DIR}/nftables.sha256")
    assert_equal "failed port update returns a failure" "1" "${status}"
    assert_contains "failed port update restores the stored port mode" \
        "SUB_PORT_MODE=443" "${state_content}"
    assert_equal "failed port update restores nftables config" "old nftables" "${nft_content}"
    assert_equal "failed port update restores nftables checksum" "old-hash" "${nft_hash}"
    assert_equal "failed Worker update restores the previous runtime config" \
        "old runtime" "$(<"${XRAY_CONFIG}")"
    assert_equal "failed Worker update restores the previous local Worker" \
        "old worker" "$(<"${WORKER_FILE}")"
    assert_contains "failed port update reloads restored active nftables rules" \
        "-f ${NFT_CONFIG}" "$(<"${nft_calls}")"

    unset -f require_root prepare_sample_worker_template configure_nftables
    unset -f refresh_protocol_runtime_config configure_subscription systemctl nft
}

test_update_subscription_orchestration() {
    local calls
    set_protocol_fixture "reality"
    SUB_PORT_MODE="443"
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    DEPLOY_MODE="worker"
    save_state
    calls=$(
        require_root() { printf 'root\n'; }
        prepare_sample_worker_template() { printf 'template\n'; }
        snapshot_subscription_update() {
            printf 'snapshot\n'
            UPDATE_SUB_ROLLBACK_ON_EXIT=1
        }
        refresh_protocol_runtime_config() { printf 'runtime\n'; }
        configure_subscription() { printf 'worker:%s:%s\n' "${1:-0}" "${2:-0}"; }
        show_subscription() { printf 'show\n'; }
        update_subscription
    )
    assert_equal "update-sub uses one template before server and Worker refresh" \
        $'root\ntemplate\nsnapshot\nruntime\nworker:0:0\nshow' "${calls}"
}

test_update_subscription_interactive_options() {
    local calls
    set_protocol_fixture "reality"
    SUB_PORT_MODE="443"
    WORKER_NAME=""
    SUB_DOWNLOAD_NAME=""
    DEPLOY_MODE="worker"
    SUBSCRIBE_MODE=""
    save_state
    SUB_PORT_MODE=""
    calls=$(
        require_root() { printf 'root\n'; }
        collect_sub_port_mode() {
            printf 'port:%s\n' "$1"
            SUB_PORT_MODE=$1
        }
        prepare_sample_worker_template() { printf 'template\n'; }
        snapshot_subscription_update() { printf 'snapshot\n'; }
        refresh_protocol_runtime_config() { printf 'runtime\n'; }
        configure_subscription() { printf 'worker:%s:%s\n' "$1" "$2"; }
        show_subscription() { printf 'show\n'; }
        update_subscription 1
    )
    assert_equal "interactive update-sub routes port, Worker and download choices" \
        $'root\nport:443\ntemplate\nsnapshot\nruntime\nworker:1:1\nshow' "${calls}"
}

test_update_command_orchestration() {
    local calls
    calls=$(
        require_root() { printf 'root\n'; }
        info() { :; }
        configure_bbr_tcp() { printf 'tcp\n'; }
        register_easy_all_command() { printf 'register\n'; }
        update_subscription() {
            printf 'subscription:%s:%s:%s\n' \
                "${SUBSCRIBE_MODE:-}" "${STRICT_WORKER_DEPLOY:-0}" "$#"
        }
        update_easy_all
    )
    assert_equal "update command forces a strict automatic Worker replace" \
        $'root\ntcp\nregister\nsubscription:auto:1:0' "${calls}"
}

test_runtime_refresh_rolls_back_invalid_config() {
    local status
    set_protocol_fixture "reality"
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    WORKER_URL=""
    DEPLOY_MODE="worker"
    REALITY_PRIVATE_KEY="test-private-key"
    save_state
    install -d -m 0755 "$(dirname "${XRAY_CONFIG}")"
    printf 'old-runtime-config\n' >"${XRAY_CONFIG}"

    write_xray_config() {
        printf 'invalid-new-runtime-config\n' >"${XRAY_CONFIG}"
    }
    systemctl() { return 0; }
    validate_protocol_runtime() {
        [[ "$(<"${XRAY_CONFIG}")" == "old-runtime-config" ]]
    }

    set +e
    ( set -e; refresh_protocol_runtime_config ) >/dev/null 2>&1
    status=$?
    set -e

    assert_equal "failed runtime refresh returns a failure" "1" "${status}"
    assert_equal "failed runtime refresh restores the old config" \
        "old-runtime-config" "$(<"${XRAY_CONFIG}")"
    unset -f write_xray_config systemctl validate_protocol_runtime
}

source_script_copy
test_validators_and_defaults
test_reality_node_host_detection
test_subscription_port_mode_selection
test_restored_interactive_choices
test_subscription_prompt_routing
test_worker_custom_domain_lifecycle
test_links_and_workers
test_sample_worker_template_guards
test_server_egress_family_configs
test_worker_only_subscription_branch
test_link_only_subscription_skips_tokens
test_state_and_lifecycle_guards
test_acme_installer_arguments
test_subscription_retry_policy
test_cloudflare_api_retry_policy
test_update_subscription_orchestration
test_update_subscription_interactive_options
test_update_command_orchestration
test_runtime_refresh_rolls_back_invalid_config
test_update_subscription_rolls_back_port_change

printf 'ok - easy_all shell tests passed (%s assertions)\n' "${TESTS_RUN}"
