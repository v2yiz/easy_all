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
    node --input-type=module - "$1" "$2" <<'EOF'
import fs from 'node:fs';

const source = fs.readFileSync(process.argv[2], 'utf8');
const protocol = process.argv[3];
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
if (clashResponse.headers.get('content-disposition') !== 'attachment; filename="Team"') {
  process.exit(1);
}
const yaml = await clashResponse.text();
for (const part of [
  'external-controller:',
  'DOMAIN-SUFFIX,bilibili.com,DIRECT',
  'DOMAIN-SUFFIX,zhihu.com,DIRECT',
  'DOMAIN-SUFFIX,douyin.com,DIRECT',
  'DOMAIN,copilot.microsoft.com,PROXY',
  'DOMAIN-SUFFIX,microsoft.com,DIRECT',
  'DOMAIN-SUFFIX,apple-relay.fastly-edge.com,PROXY',
  'IP-CIDR6,2001:b28:f23d::/48,PROXY,no-resolve',
  'GEOSITE,geolocation-!cn,PROXY',
  'GEOIP,CN,DIRECT,no-resolve'
]) {
  if (!yaml.includes(part)) process.exit(1);
}

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
      'public-key: test-public-key', 'client-fingerprint: chrome', 'flow: xtls-rprx-vision']
  },
  anytls: {
    link: ['anytls://test-anytls-password@anytls.example.com:', 'sni=anytls.example.com',
      'insecure=0', '#MY_ANYTLS'],
    yaml: ['type: anytls', 'server: "anytls.example.com"',
      'password: "test-anytls-password"', 'client-fingerprint: "chrome"']
  },
  'vless-wss': {
    link: ['vless://00000000-0000-4000-8000-000000000001@wss.example.com:443?',
      'security=tls', 'type=ws', 'fp=chrome', 'path=%2Fhacxws', 'host=wss.example.com',
      '#MY_VLESS_WSS'],
    yaml: ['type: vless', 'network: ws', 'port: 443', 'ws-opts:',
      'path: /hacxws', 'Host: wss.example.com']
  }
};
for (const part of checks[protocol].link) {
  if (!decoded.includes(part)) process.exit(1);
}
for (const part of checks[protocol].yaml) {
  if (!yaml.includes(part)) process.exit(1);
}
if (protocol === 'vless-wss' && decoded.includes('flow=xtls-rprx-vision')) process.exit(1);
if (protocol !== 'vless-wss') {
  const port = Number(decoded.match(/@[^:]+:(\d+)/)?.[1]);
  if (!Number.isInteger(port) || port < 10000 || port > 65535) process.exit(1);
}
EOF
}

worker_runtime_accepts_default_node_array() {
    node --input-type=module - "$1" <<'EOF'
import fs from 'node:fs';

const source = fs.readFileSync(process.argv[2], 'utf8')
  .replace('const DEFAULT_NODE = NODE_CONFIG;', 'const DEFAULT_NODE = [NODE_CONFIG, NODE_CONFIG];');
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
        -e "s|^readonly WEB_ROOT=.*|readonly WEB_ROOT=\"${TMP_DIR}/www\"|" \
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
        -e "s|^readonly NGINX_CONFIG=.*|readonly NGINX_CONFIG=\"${TMP_DIR}/nginx.conf\"|" \
        -e "s|^readonly ACME_HOME=.*|readonly ACME_HOME=\"${TMP_DIR}/acme\"|" \
        -e "s|^readonly ACME_BIN=.*|readonly ACME_BIN=\"${TMP_DIR}/acme/acme.sh\"|" \
        -e "s|^readonly ACME_OWNERSHIP_MARKER=.*|readonly ACME_OWNERSHIP_MARKER=\"${TMP_DIR}/state/acme-installed-by-easy-all\"|" \
        -e "s|^readonly NFT_CONFIG=.*|readonly NFT_CONFIG=\"${TMP_DIR}/nftables.conf\"|" \
        "${ROOT_DIR}/easy_all.sh" >"${SCRIPT_COPY}"
    # shellcheck source=/dev/null
    source "${SCRIPT_COPY}"
    SAMPLE_WORKER_SOURCE="${ROOT_DIR}/sample-worker.js"
}

set_protocol_fixture() {
    PROTOCOL=$1
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
    vless-wss)
        NODE_NAME="MY_VLESS_WSS"
        VLESS_WSS_DOMAIN="wss.example.com"
        WS_PATH="/hacxws"
        SUB_PORT_MODE="443"
        ;;
    esac
}

test_validators_and_defaults() {
    assert_success "valid WS path is accepted" validate_ws_path "/hacxws"
    assert_success "generated WS path is valid" validate_ws_path "$(generate_ws_path)"
    assert_failure "WS path must start with slash" validate_ws_path "hacxws"
    assert_failure "WS path rejects query" validate_ws_path "/hacxws?x=1"
    assert_success "Reality target accepts host and port" validate_reality_target "www.cloudflare.com:443"
    assert_failure "Reality target requires port" validate_reality_target "www.cloudflare.com"
    assert_success "Reality protocol is accepted" validate_protocol "reality"
    assert_success "AnyTLS protocol is accepted" validate_protocol "anytls"
    assert_success "VLESS WSS protocol is accepted" validate_protocol "vless-wss"
    assert_failure "unknown protocol is rejected" validate_protocol "trojan"

    assert_equal "default Worker name is easy-all" "easy-all" "${DEFAULT_WORKER_NAME}"
    assert_success "default Worker name is Cloudflare-compatible" validate_worker_name "${DEFAULT_WORKER_NAME}"
    assert_failure "Worker name rejects underscore" validate_worker_name "easy_all"
    assert_equal "AnyTLS defaults to dynamic" "dynamic" "${DEFAULT_ANYTLS_PORT_MODE}"
    assert_equal "Reality defaults to 443" "443" "${DEFAULT_REALITY_PORT_MODE}"
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

test_links_and_workers() {
    local protocol link yaml worker sample_rules generated_rules
    for protocol in reality anytls vless-wss; do
        set_protocol_fixture "${protocol}"
        link=$(build_node_link)
        yaml=$(build_mihomo_node)
        assert_contains "${protocol} node link contains node name" "${NODE_NAME}" "${link}"
        assert_contains "${protocol} Mihomo node contains name" "${NODE_NAME}" "${yaml}"
        worker="${TMP_DIR}/worker-${protocol}.js"
        write_worker "${worker}"
        assert_success "${protocol} Worker JavaScript syntax valid" node --check "${worker}"
        assert_success "${protocol} Worker emits base64 and Mihomo outputs" \
            worker_runtime_matches_protocol "${worker}" "${protocol}"
        assert_success "${protocol} Worker accepts DEFAULT_NODE array" \
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
        assert_equal "${protocol} Worker rules come unchanged from sample-worker.js" \
            "${sample_rules}" "${generated_rules}"
    done
}

test_sample_worker_template_guards() {
    local invalid_template="${TMP_DIR}/invalid-sample-worker.js"
    awk '$0 != "// EASY_ALL_RULES_END"' \
        "${ROOT_DIR}/sample-worker.js" >"${invalid_template}"
    assert_success "sample Worker rejects a missing rules boundary" \
        sample_worker_validation_fails "${invalid_template}"

    assert_success "sample Worker source rejects plain HTTP" \
        sample_worker_fetch_fails "http://example.com/sample-worker.js"
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
        worker_runtime_matches_protocol "${WORKER_FILE}" "reality"
}

test_state_and_lifecycle_guards() {
    set_protocol_fixture "vless-wss"
    XRAY_LOOPBACK_PORT="10085"
    WORKER_NAME="${DEFAULT_WORKER_NAME}"
    WORKER_URL=""
    CF_ACCOUNT_ID="account-id"
    DEPLOY_MODE="worker"
    CF_DNS_API_TOKEN="dns-token-must-not-be-saved"
    CF_WORKER_API_TOKEN="worker-token-must-not-be-saved"

    save_state
    local content script_content readme_content
    content=$(<"${STATE_FILE}")
    assert_contains "state saves version" "STATE_VERSION=1" "${content}"
    assert_contains "state saves selected protocol" "PROTOCOL=vless-wss" "${content}"
    assert_contains "state saves WS path" "WS_PATH=/hacxws" "${content}"
    assert_contains "state saves default Worker" "WORKER_NAME=easy-all" "${content}"
    assert_contains "state saves allowed token dict" "ALLOWED_TOKENS=" "${content}"
    assert_not_contains "state does not save SUB_TOKEN field" "SUB_TOKEN=" "${content}"
    assert_not_contains "state does not save DNS token" "dns-token-must-not-be-saved" "${content}"
    assert_not_contains "state does not save Worker token" "worker-token-must-not-be-saved" "${content}"
    assert_success "saved state reloads without readonly variable conflicts" load_state
    assert_equal "reloaded state version matches the schema" \
        "${STATE_SCHEMA_VERSION}" "${STATE_VERSION}"

    script_content=$(<"${ROOT_DIR}/easy_all.sh")
    assert_not_contains "easy_all does not embed Clash rule contents" \
        "DOMAIN-SUFFIX,bilibili.com,DIRECT" "${script_content}"
    assert_not_contains "easy_all does not embed the fake IP filter" \
        "const FAKE_IP_FILTER =" "${script_content}"
    assert_contains "easy_all reads rules from the sample Worker" \
        "fetch_sample_worker" "${script_content}"
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
    assert_contains "script reminds proxied after install" "Proxied / 橙云" "${script_content}"
    assert_contains "script keeps AAAA DNS-only before install or switch" \
        "AAAA 记录，安装或切换前也请保持 DNS only / 灰云并指向当前 VPS 公网 IPv6" \
        "${script_content}"
    assert_contains "script switches A and AAAA to proxied together after WSS install" \
        "A、AAAA 记录一起从 DNS only / 灰云切换为 Proxied / 橙云" "${script_content}"
    assert_contains "script renders pre-install Cloudflare notice in red" \
        'alert "安装前请确认 Cloudflare DNS A 记录' "${script_content}"
    assert_contains "script renders post-install SSL notice in red" \
        'alert "Cloudflare SSL/TLS 模式请使用 Full' "${script_content}"
    assert_contains "script renders post-install WebSockets notice in red" \
        'alert "请确认 Cloudflare Network 中 WebSockets 已开启。"' "${script_content}"
    assert_contains "script fixes WSS to 443" "VLESS WSS 不支持 dynamic" "${script_content}"
    assert_contains "script warns WSS is recommended only for China Mobile broadband" \
        "仅推荐移动宽带用户选择" "${script_content}"
    assert_contains "script contains nginx WebSocket upgrade" 'proxy_set_header Upgrade \$http_upgrade;' "${script_content}"
    assert_contains "script retries Cloudflare rate limits" "408 | 429 | 500 | 502 | 503 | 504" "${script_content}"
    assert_contains "script retries Cloudflare propagation errors" "10007" "${script_content}"
    assert_contains "script retries concurrent Worker updates" "10035" "${script_content}"
    assert_contains "script writes Worker deployment log" "last-worker-deploy.log" "${script_content}"
    assert_contains "script snapshots protocol switches" "snapshot_protocol_switch" "${script_content}"
    assert_contains "script rolls failed switches back" "rollback_protocol_switch" "${script_content}"
    assert_contains "script avoids rollback after Worker replace" \
        "Worker 已完成 replace" "${script_content}"
    assert_contains "update-sub synchronizes changed ports to nftables" \
        "同步更新 nftables" "${script_content}"
    assert_contains "uninstall explicitly leaves remote Worker" "远端 Cloudflare Worker 未处理" "${script_content}"
    assert_not_contains "script never deletes remote Worker through API" "DELETE_CLOUDFLARE_WORKER" "${script_content}"

    readme_content=$(<"${ROOT_DIR}/README.md")
    assert_contains "README documents AAAA as DNS-only before WSS install" \
        "AAAA 若存在，也应保持灰云并指向 VPS 公网 IPv6" "${readme_content}"
    assert_contains "README documents proxying A and AAAA together after WSS install" \
        "将 A、AAAA 一起切为 Proxied / 橙云" "${readme_content}"
    assert_contains "README documents Worker subscription verification retry policy" \
        "先等待 5 秒，再进行最多 6 次订阅 HTTP 验收" "${readme_content}"
}

test_acme_installer_arguments() {
    local installer_args=""
    VLESS_WSS_DOMAIN="wss.example.com"
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

    assert_equal "get.acme.sh receives email in its required first argument" \
        "email=ops@example.com" "$(printf '%s\n' "${installer_args}" | sed -n '2p')"
    assert_equal "get.acme.sh receives --home after the email argument" \
        "--home" "$(printf '%s\n' "${installer_args}" | sed -n '3p')"
    assert_equal "get.acme.sh receives the managed install directory" \
        "${ACME_HOME}" "$(printf '%s\n' "${installer_args}" | sed -n '4p')"
    assert_not_contains "get.acme.sh is not passed the obsolete accountemail option" \
        "--accountemail" "${installer_args}"
}

test_subscription_retry_policy() {
    local call_file="${TMP_DIR}/subscription-curl-calls"
    local delay_file="${TMP_DIR}/subscription-retry-delays"
    local calls delays log_content
    printf '0\n' >"${call_file}"
    : >"${delay_file}"
    install -d -m 0700 "${STATE_DIR}"
    : >"${CLOUDFLARE_DEPLOY_LOG}"
    WORKER_URL="https://worker.example.test"
    ALLOWED_TOKENS='{"owner":"test-token","friend":"friend-token"}'

    curl() {
        local count
        count=$(<"${call_file}")
        count=$((count + 1))
        printf '%s\n' "${count}" >"${call_file}"
        if ((count < 4)); then
            printf '403'
        else
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
    assert_equal "subscription verification retries until the fourth response" "4" "${calls}"
    assert_equal "subscription verification waits five seconds before its first request" \
        "5" "$(sed -n '1p' "${delay_file}")"
    assert_equal "subscription verification sleeps only before and between failed attempts" \
        "4" "$(wc -l <"${delay_file}" | tr -d '[:space:]')"
    assert_success "subscription retry intervals stay between one and three seconds" \
        awk 'NR == 1 {next} $1 < 1 || $1 > 3 {exit 1}' "${delay_file}"
    assert_contains "subscription verification logs six maximum attempts" \
        "第 4/6 次，HTTP 200" "${log_content}"
    assert_contains "subscription retry log includes its randomized delay" \
        "秒后重试" "${log_content}"
    assert_contains "captured subscription delays include retry intervals" $'5\n' "${delays}"
}

test_update_command_orchestration() {
    local calls
    calls=$(
        require_root() { printf 'root\n'; }
        register_easy_all_command() { printf 'register\n'; }
        update_subscription() { printf 'subscription\n'; }
        update_easy_all
    )
    assert_equal "update command registers the script before updating subscription" \
        $'root\nregister\nsubscription' "${calls}"
}

source_script_copy
test_validators_and_defaults
test_links_and_workers
test_sample_worker_template_guards
test_worker_only_subscription_branch
test_state_and_lifecycle_guards
test_acme_installer_arguments
test_subscription_retry_policy
test_update_command_orchestration

printf 'ok - easy_all shell tests passed (%s assertions)\n' "${TESTS_RUN}"
