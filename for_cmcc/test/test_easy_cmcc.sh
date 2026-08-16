#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf -- "${TMP_DIR}"
}
trap cleanup EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    [[ "$2" == "$3" ]] || fail "$1: expected '$2', got '$3'"
}

assert_contains() {
    [[ "$2" == *"$3"* ]] || fail "$1: missing '$3'"
}

bash -n "${ROOT_DIR}/easy_cmcc"
installer=$(<"${ROOT_DIR}/easy_cmcc")
output=$("${ROOT_DIR}/easy_cmcc" help)
assert_contains "standalone executable exposes CMCC usage" "${output}" "VLESS WS TLS"

assert_contains "CMCC uses fq" "${installer}" "net.core.default_qdisc = fq"
assert_contains "CMCC uses BBR" "${installer}" "net.ipv4.tcp_congestion_control = bbr"
assert_contains "CMCC bounds receive backlog" "${installer}" "net.core.netdev_max_backlog = 16384"
assert_contains "CMCC bounds receive buffers at 32 MiB" "${installer}" "net.core.rmem_max = 33554432"
assert_contains "CMCC bounds send buffers at 32 MiB" "${installer}" "net.core.wmem_max = 33554432"
assert_contains "CMCC tunes TCP receive buffers" "${installer}" "net.ipv4.tcp_rmem = 4096 131072 33554432"
assert_contains "CMCC tunes TCP send buffers" "${installer}" "net.ipv4.tcp_wmem = 4096 65536 33554432"
assert_contains "CMCC enables MTU probing" "${installer}" "net.ipv4.tcp_mtu_probing = 1"
assert_contains "CMCC keeps long-lived connection cwnd" "${installer}" "net.ipv4.tcp_slow_start_after_idle = 0"
assert_contains "Nginx backlog matches somaxconn" "${installer}" "listen 443 ssl http2 backlog=4096;"
[[ "${installer}" != *"net.ipv4.tcp_fastopen = 3"* ]] \
    || fail "CMCC must not enable unused server-side TCP Fast Open"
[[ "${installer}" != *"net.ipv4.tcp_notsent_lowat = 16384"* ]] \
    || fail "CMCC must not globally throttle unsent TCP data"
assert_contains "CMCC resets legacy TCP Fast Open overrides" "${installer}" \
    "sysctl -q -w net.ipv4.tcp_fastopen=1"
assert_contains "CMCC resets legacy unsent queue overrides" "${installer}" \
    "sysctl -q -w net.ipv4.tcp_notsent_lowat=4294967295"
assert_contains "CMCC update reapplies TCP tuning" "${installer}" \
    'info "刷新 BBR 与 TCP 参数"'
collect_inputs_function=$(awk '
    /^collect_install_inputs\(\) \{/ {capture=1}
    capture {print}
    capture && /^}/ {exit}
' "${ROOT_DIR}/easy_cmcc")
[[ "${collect_inputs_function}" != *"ensure_allowed_tokens"* ]] \
    || fail "CMCC must choose the subscription mode before requesting tokens"
collect_state_function=$(awk '
    /^collect_installed_state\(\) \{/ {capture=1}
    capture {print}
    capture && /^}/ {exit}
' "${ROOT_DIR}/easy_cmcc")
[[ "${collect_state_function}" != *"ensure_allowed_tokens"* ]] \
    || fail "CMCC link-only state inspection must not require tokens"
assert_contains "CMCC persists the Worker Custom Domain" "${installer}" \
    "WORKER_CUSTOM_DOMAIN=%q"
assert_contains "CMCC exposes a Worker name prompt" "${installer}" \
    "Cloudflare Worker 名称"
assert_contains "CMCC exposes a Mihomo download filename prompt" "${installer}" \
    "Mihomo 下载文件名（不含 .yaml）"
assert_contains "CMCC update-sub enables the first-auto Worker name choice" "${installer}" \
    "update-sub) update_subscription 1"
assert_contains "CMCC uses the Custom Domain API" "${installer}" \
    '/accounts/${CF_ACCOUNT_ID}/workers/domains'
[[ "${installer}" != *'/workers/routes'* ]] \
    || fail "CMCC must use Custom Domain instead of a classic Worker Route"
assert_contains "CMCC acme.sh wrapper pins the isolated home" "${installer}" \
    '"${ACME_BIN}" "$@" --home "${ACME_HOME}"'
for acme_action in set-default-ca issue install-cert renew remove list; do
    assert_contains "CMCC ${acme_action} uses the isolated acme.sh wrapper" "${installer}" \
        "run_acme --${acme_action}"
done
if grep -Eq '"\$\{ACME_BIN\}" --(set-default-ca|issue|install-cert|renew|remove|list)' \
    <<<"${installer}"; then
    fail "CMCC acme.sh operations must not bypass the isolated-home wrapper"
fi

readme=$(<"${ROOT_DIR}/README.md")
assert_contains "README identifies the standalone installer" "${readme}" \
    "独立安装器"
assert_contains "README downloads the CMCC monolith" "${readme}" \
    "main/for_cmcc/easy_cmcc"
assert_contains "README documents both WebSocket nodes" "${readme}" \
    '`VLESS_WS` 和 `TROJAN_WS`'
assert_contains "README documents the AUTO and PROXY groups" "${readme}" \
    '一个 `AUTO` 自动测速组和一个 `PROXY` 选择组'
assert_contains "README documents power-conscious client settings" "${readme}" \
    '`tcp-concurrent: false`'
assert_contains "README documents disabled process matching" "${readme}" \
    '`find-process-mode: off`'
assert_contains "README documents disabled WebSocket heartbeat" "${readme}" \
    '`heartbeatPeriod: 0`'
assert_contains "README documents disabled multiplexing" "${readme}" \
    '`smux.enabled: false`'
assert_contains "README documents the DNS-only precondition" "${readme}" \
    "DNS only / 灰云"
assert_contains "README documents enabling the CDN after install" "${readme}" \
    "Proxied / 橙云"
assert_contains "README documents isolated state" "${readme}" \
    "/etc/easy_cmcc/state.env"
assert_contains "README documents that uninstall leaves remote Cloudflare resources" "${readme}" \
    "不删除远端 Worker"
assert_contains "README distinguishes node and subscription domains" "${readme}" \
    "两个不同域名"
assert_contains "README documents the recommended interactive Worker choice" "${readme}" \
    '订阅输出方式 | `1`，自动部署 Worker'
assert_contains "README documents IPv4 and IPv6 LAN bypass" "${readme}" \
    "局域网 IPv4/IPv6 地址绕过 TUN"
assert_contains "README provides standalone troubleshooting" "${readme}" \
    "## 故障排查"
assert_contains "README documents customizable Mihomo download filenames" "${readme}" \
    '不含 `.yaml`'
assert_contains "README documents token-free link-only mode" "${readme}" \
    "只显示节点链接，不生成 Worker"
assert_contains "README documents Cloudflare WebSockets" "${readme}" \
    "开启 WebSockets"
assert_contains "README documents minimal Worker Token scope" "${readme}" \
    "Workers Scripts → Edit"

if bash -c 'source "$1"; choose_protocol reality' _ "${ROOT_DIR}/easy_cmcc" \
    >/dev/null 2>&1; then
    fail "standalone executable must reject Reality"
fi
if bash -c 'source "$1"; choose_protocol vless-grpc' _ "${ROOT_DIR}/easy_cmcc" \
    >/dev/null 2>&1; then
    fail "standalone executable must reject the retired gRPC mode"
fi
if bash -c 'source "$1"; choose_protocol vless-xhttp' _ "${ROOT_DIR}/easy_cmcc" \
    >/dev/null 2>&1; then
    fail "standalone executable must reject XHTTP"
fi

(
    # shellcheck source=/dev/null
    source "${ROOT_DIR}/easy_cmcc"

    assert_equal "entry points at the monolith" "${ROOT_DIR}/easy_cmcc" "${ENTRY_SCRIPT_FILE}"
    assert_equal "state directory is isolated" "/etc/easy_cmcc" "${STATE_DIR}"
    assert_equal "command library is isolated" "/usr/local/lib/easy_cmcc" "${COMMAND_INSTALL_DIR}"
    assert_equal "Xray service is isolated" "easy-cmcc-xray.service" "${XRAY_SERVICE}"
    assert_equal "Nginx config is isolated" "/etc/nginx/conf.d/easy_cmcc.conf" "${NGINX_CONFIG}"
    assert_equal "acme.sh home is isolated" "/root/.acme-cmcc.sh" "${ACME_HOME}"
    assert_equal "Worker name is isolated" "easy-cmcc" "${DEFAULT_WORKER_NAME}"
    assert_equal "CMCC uses state schema v2 without old-protocol migration" "2" "${STATE_SCHEMA_VERSION}"
    assert_equal "CMCC uses the requested VLESS node name" "VLESS_WS" "${DEFAULT_VLESS_NODE_NAME}"
    assert_equal "CMCC uses the requested Trojan node name" "TROJAN_WS" "${DEFAULT_TROJAN_NODE_NAME}"
    assert_contains "Worker URL uses the CMCC subtree" "${DEFAULT_SAMPLE_WORKER_URL}" "/for_cmcc/sample-worker.js"
    assert_contains "CMCC subscription verification uses Worker version affinity" \
        "$(<"${ROOT_DIR}/easy_cmcc")" "Cloudflare-Workers-Version-Key"
    assert_contains "CMCC subscription verification bypasses intermediary caches" \
        "$(<"${ROOT_DIR}/easy_cmcc")" "Cache-Control: no-cache"

    link_only_output=$(
        (
            collect_installed_state() { :; }
            ensure_allowed_tokens() { fail "link-only mode requested subscription tokens"; }
            save_state() { printf 'saved:%s:%s\n' "${DEPLOY_MODE}" "${ALLOWED_TOKENS:-}"; }
            SUBSCRIBE_MODE="link"
            DEPLOY_MODE=""
            ALLOWED_TOKENS=""
            WORKER_URL="https://old-worker.example.test"
            configure_subscription
        )
    )
    assert_equal "CMCC link-only mode skips tokens and clears the Worker URL" \
        "saved:link:" "${link_only_output}"

    first_auto_output=$(
        (
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
    )
    assert_equal "CMCC first automatic deployment prompts for Worker, domain and download names" \
        $'worker:1\ndomain\ndownload:1' "${first_auto_output}"

    existing_auto_output=$(
        (
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
            WORKER_URL="https://existing.example.test"
            configure_subscription 1 1
        )
    )
    assert_equal "CMCC existing automatic deployment reuses its Worker name" \
        $'worker:0\ndomain\ndownload:1' "${existing_auto_output}"

    manual_output=$(
        (
            collect_installed_state() { :; }
            choose_subscription_mode() { SUBSCRIBE_MODE="worker"; }
            choose_worker_name() { printf 'unexpected-worker\n'; }
            collect_worker_custom_domain() { printf 'unexpected-domain\n'; }
            choose_subscription_download_name() { printf 'download:%s\n' "$1"; }
            write_worker() { :; }
            print_worker_content() { :; }
            save_state() { :; }
            configure_subscription 0 1
        )
    )
    assert_equal "CMCC manual Worker mode prompts only for its download filename" \
        "download:1" "${manual_output}"

    SUB_DOWNLOAD_NAME="Team.yaml"
    choose_subscription_download_name 0
    assert_equal "CMCC normalizes a custom Mihomo download filename" \
        "Team" "${SUB_DOWNLOAD_NAME}"

    choose_protocol dual-ws >/dev/null
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    TROJAN_PASSWORD="test-trojan-password-123456"
    VLESS_CDN_DOMAIN="cmcc.example.com"
    VLESS_NODE_NAME="CMCC_VLESS_WS"
    TROJAN_NODE_NAME="CMCC_TROJAN_WS"
    VLESS_WS_PATH="/cmcc-vless-ws"
    TROJAN_WS_PATH="/cmcc-trojan-ws"
    WORKER_CUSTOM_DOMAIN="SUB.EXAMPLE.COM"
    collect_worker_custom_domain
    assert_equal "CMCC normalizes the Worker Custom Domain" \
        "sub.example.com" "${WORKER_CUSTOM_DOMAIN}"
    if (
        WORKER_CUSTOM_DOMAIN="cmcc.example.com"
        collect_worker_custom_domain
    ) >/dev/null 2>&1; then
        fail "CMCC must reject reusing the node domain"
    fi
    if (
        WORKER_CUSTOM_DOMAIN="easy-cmcc.example.workers.dev"
        collect_worker_custom_domain
    ) >/dev/null 2>&1; then
        fail "CMCC must reject workers.dev as a Custom Domain"
    fi
    if (
        WORKER_CUSTOM_DOMAIN="workers.dev"
        collect_worker_custom_domain
    ) >/dev/null 2>&1; then
        fail "CMCC must reject the workers.dev apex as a Custom Domain"
    fi
    links=$(build_node_link)
    assert_contains "subscription contains VLESS" "${links}" "vless://"
    assert_contains "subscription contains Trojan" "${links}" "trojan://"
    assert_contains "both nodes use WebSocket" "${links}" "type=ws"
    assert_contains "VLESS includes its path" "${links}" "path=%2Fcmcc-vless-ws"
    assert_contains "Trojan includes its path" "${links}" "path=%2Fcmcc-trojan-ws"
    assert_contains "nodes force HTTP/1.1" "${links}" "alpn=http%2F1.1"
    assert_equal "subscription contains exactly two links" "2" "$(wc -l <<<"${links}" | tr -d ' ')"
    [[ "${links}" != *"type=xhttp"* && "${links}" != *"type=grpc"* ]] \
        || fail "subscription must contain only WebSocket transports"

    ALLOWED_TOKENS='{"owner":"test-token"}'
    SUB_DOWNLOAD_NAME="CMCC_TEST"
    SAMPLE_WORKER_SOURCE="${ROOT_DIR}/sample-worker.js"
    WORKER_NAME="easy-cmcc"
    worker_output="${TMP_DIR}/subscribe-worker.js"
    write_worker "${worker_output}"
    [[ "$(grep -Fo '"network":"ws"' "${worker_output}" | wc -l | tr -d ' ')" == "2" ]] \
        || fail "rendered Worker must include exactly two WebSocket nodes"
    grep -Fq '"type":"vless"' "${worker_output}" \
        || fail "rendered Worker must include VLESS"
    grep -Fq '"type":"trojan"' "${worker_output}" \
        || fail "rendered Worker must include Trojan"
    grep -Fq '"path":"/cmcc-vless-ws"' "${worker_output}" \
        || fail "rendered Worker must include the VLESS path"
    grep -Fq '"path":"/cmcc-trojan-ws"' "${worker_output}" \
        || fail "rendered Worker must include the Trojan path"
    grep -Fq 'const DEFAULT_NODE = [NODE_VLESS_WS_CONFIG, NODE_TROJAN_WS_CONFIG];' "${worker_output}" \
        || fail "rendered Worker must publish both configured nodes"
    [[ "$(<"${worker_output}")" != *'"network":"grpc"'* && "$(<"${worker_output}")" != *'"network":"xhttp"'* ]] \
        || fail "rendered Worker must not publish gRPC or XHTTP"
    grep -Fq 'network: "ws"' "${ROOT_DIR}/easy_cmcc" \
        || fail "Xray server must require WebSocket"
    assert_contains "Xray server includes a VLESS inbound" "${installer}" \
        'protocol: "vless"'
    assert_contains "Xray server includes a Trojan inbound" "${installer}" \
        'protocol: "trojan"'
    [[ "$(grep -Fc 'heartbeatPeriod: 0' <<<"${installer}")" == "2" ]] \
        || fail "both Xray WebSocket inbounds must disable periodic heartbeat"
    assert_contains "Nginx matches the VLESS path exactly" "${installer}" \
        'location = ${VLESS_WS_PATH}'
    assert_contains "Nginx matches the Trojan path exactly" "${installer}" \
        'location = ${TROJAN_WS_PATH}'
    [[ "$(grep -Fc 'proxy_buffering off;' <<<"${installer}")" == "2" ]] \
        || fail "both Nginx WebSocket paths must disable response buffering"
    node --input-type=module - "${worker_output}" <<'EOF'
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const source = readFileSync(process.argv[2], 'utf8');
const encoded = Buffer.from(source).toString('base64');
const worker = (await import(`data:text/javascript;base64,${encoded}`)).default;
const baseUrl = 'https://worker.test/subscribe?token=test-token';
const plain = await worker.fetch(new Request(baseUrl), {});
assert.equal(plain.status, 200);
const links = Buffer.from(await plain.text(), 'base64').toString('utf8').split('\n');
assert.equal(links.length, 2);
assert.match(links[0], /^vless:/);
assert.match(links[1], /^trojan:/);
const clash = await worker.fetch(new Request(`${baseUrl}&flag=clash`), {});
assert.equal(clash.status, 200);
const yaml = await clash.text();
assert.match(yaml, /^proxies:$/m);
assert.match(yaml, /^proxy-groups:$/m);
assert.match(yaml, /^rules:$/m);
EOF
    mihomo_nodes=$(build_mihomo_node)
    assert_contains "Mihomo nodes race dual-stack CDN addresses" "${mihomo_nodes}" \
        "ip-version: dual"
    assert_contains "Mihomo nodes use WebSocket options" "${mihomo_nodes}" \
        'ws-opts:'
    [[ "$(grep -c 'enabled: false' <<<"${mihomo_nodes}")" == "2" ]] \
        || fail "both Mihomo nodes must disable smux"
    [[ "${mihomo_nodes}" != *"health-check"* ]] \
        || fail "Mihomo nodes must not enable health checks"

    dns_proxy_calls="${TMP_DIR}/cmcc-dns-proxy-calls"
    : >"${dns_proxy_calls}"
    CF_PROXY_MODE="auto"
    CF_DNS_API_TOKEN="test-zone-token"
    VLESS_CDN_DOMAIN="cmcc.example.com"
    find_cloudflare_zone_id() { printf 'zone-id\n'; }
    cloudflare_zone_api() {
        local method=$1 path=$2
        printf '%s\t%s\n' "${method}" "${path}" >>"${dns_proxy_calls}"
        if [[ "${method}" == "GET" && "${path}" == *"type=A&"* ]]; then
            printf '%s' '{"success":true,"result":[{"id":"record-a","proxied":false}]}'
        elif [[ "${method}" == "GET" ]]; then
            printf '%s' '{"success":true,"result":[]}'
        else
            printf '%s' '{"success":true,"result":{"id":"record-a","proxied":true}}'
        fi
    }
    enable_cloudflare_proxy >/dev/null
    grep -Fq $'PATCH\t/zones/zone-id/dns_records/record-a' "${dns_proxy_calls}" \
        || fail "CMCC must automatically proxy the dual WebSocket node DNS record"

    : >"${dns_proxy_calls}"
    enable_cloudflare_websockets >/dev/null
    grep -Fq $'PATCH\t/zones/zone-id/settings/websockets' "${dns_proxy_calls}" \
        || fail "CMCC must automatically enable Cloudflare WebSockets"

    : >"${dns_proxy_calls}"
    CF_PROXY_MODE="manual"
    enable_cloudflare_proxy >/dev/null
    [[ ! -s "${dns_proxy_calls}" ]] \
        || fail "CMCC manual proxy mode must leave DNS records unchanged"

    custom_domain_api_calls="${TMP_DIR}/cmcc-custom-domain-api-calls"
    custom_domain_get_count="${TMP_DIR}/cmcc-custom-domain-get-count"
    : >"${custom_domain_api_calls}"
    printf '0\n' >"${custom_domain_get_count}"
    CF_ACCOUNT_ID="0123456789abcdef0123456789abcdef"
    WORKER_NAME="easy-cmcc"
    WORKER_CUSTOM_DOMAIN="sub.example.com"
    WORKER_DEV_URL="https://easy-cmcc.account.workers.dev"
    WORKER_URL=${WORKER_DEV_URL}
    CUSTOM_DOMAIN_API_MODE="create"
    cloudflare_deploy_log() { :; }
    cloudflare_api() {
        local method=$1 path=$2
        shift 3
        printf '%s\t%s\t%s\n' "${method}" "${path}" "$*" \
            >>"${custom_domain_api_calls}"
        if [[ "${method}" == "GET" ]]; then
            case "${CUSTOM_DOMAIN_API_MODE}" in
            existing)
                printf '%s' '{"success":true,"result":[{"hostname":"sub.example.com","service":"easy-cmcc"}]}'
                ;;
            conflict)
                printf '%s' '{"success":true,"result":[{"hostname":"sub.example.com","service":"another-worker"}]}'
                ;;
            late-existing)
                local get_count
                get_count=$(<"${custom_domain_get_count}")
                get_count=$((get_count + 1))
                printf '%s\n' "${get_count}" >"${custom_domain_get_count}"
                if ((get_count == 1)); then
                    printf '%s' '{"success":true,"result":[]}'
                else
                    printf '%s' '{"success":true,"result":[{"hostname":"sub.example.com","service":"easy-cmcc"}]}'
                fi
                ;;
            *) printf '%s' '{"success":true,"result":[]}' ;;
            esac
        else
            if [[ "${CUSTOM_DOMAIN_API_MODE}" == "late-existing" ]]; then
                printf '%s' '{"success":false,"errors":[{"code":100117,"message":"Hostname already has externally managed DNS records"}]}'
            else
                printf '%s' '{"success":true,"result":{"hostname":"sub.example.com","service":"easy-cmcc"}}'
            fi
        fi
    }
    attach_worker_custom_domain \
        || fail "CMCC must create a new Worker Custom Domain"
    assert_equal "CMCC prefers the attached Custom Domain" \
        "https://sub.example.com" "${WORKER_URL}"
    grep -Fq $'GET\t/accounts/0123456789abcdef0123456789abcdef/workers/domains?hostname=sub.example.com' \
        "${custom_domain_api_calls}" \
        || fail "CMCC must query the exact Custom Domain before attaching it"
    grep -Fq $'PUT\t/accounts/0123456789abcdef0123456789abcdef/workers/domains' \
        "${custom_domain_api_calls}" \
        || fail "CMCC must attach the Custom Domain through the account API"
    grep -Fq '"hostname":"sub.example.com","service":"easy-cmcc"' \
        "${custom_domain_api_calls}" \
        || fail "CMCC must bind the requested hostname to easy-cmcc"

    CUSTOM_DOMAIN_API_MODE="existing"
    : >"${custom_domain_api_calls}"
    WORKER_URL=${WORKER_DEV_URL}
    attach_worker_custom_domain \
        || fail "CMCC must reuse an existing Custom Domain owned by easy-cmcc"
    assert_equal "CMCC reuses its existing Custom Domain" \
        "https://sub.example.com" "${WORKER_URL}"
    [[ "$(grep -c $'^PUT\t' "${custom_domain_api_calls}" || true)" == "0" ]] \
        || fail "CMCC must not recreate an existing correct Custom Domain"

    CUSTOM_DOMAIN_API_MODE="conflict"
    : >"${custom_domain_api_calls}"
    WORKER_URL=${WORKER_DEV_URL}
    if attach_worker_custom_domain; then
        fail "CMCC must not take over a Custom Domain owned by another Worker"
    fi
    assert_equal "CMCC keeps workers.dev after a Custom Domain conflict" \
        "${WORKER_DEV_URL}" "${WORKER_URL}"
    [[ "$(grep -c $'^PUT\t' "${custom_domain_api_calls}" || true)" == "0" ]] \
        || fail "CMCC must not write after detecting a Custom Domain conflict"

    CUSTOM_DOMAIN_API_MODE="late-existing"
    : >"${custom_domain_api_calls}"
    printf '0\n' >"${custom_domain_get_count}"
    WORKER_URL=${WORKER_DEV_URL}
    sleep() { :; }
    attach_worker_custom_domain \
        || fail "CMCC must treat a post-conflict binding to the current Worker as success"
    assert_equal "CMCC accepts a binding confirmed after a 100117 race" \
        "https://sub.example.com" "${WORKER_URL}"
    assert_equal "CMCC rechecks Custom Domain after a binding conflict" \
        "2" "$(<"${custom_domain_get_count}")"
    [[ "$(grep -c $'^PUT\t' "${custom_domain_api_calls}" || true)" == "1" ]] \
        || fail "CMCC must issue one bind request before confirming the race"

    verify_calls_file="${TMP_DIR}/cmcc-verify-calls"
    verify_keys_file="${TMP_DIR}/cmcc-verify-version-keys"
    printf '0\n' >"${verify_calls_file}"
    : >"${verify_keys_file}"
    WORKER_URL="https://worker.example.test"
    curl() {
        local count output="" url="" version_key=""
        count=$(<"${verify_calls_file}")
        count=$((count + 1))
        printf '%s\n' "${count}" >"${verify_calls_file}"
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
        printf '%s\n' "${version_key}" >>"${verify_keys_file}"
        if ((count <= 4)); then
            printf 'Not Found\n' >"${output}"
            printf '404'
        elif [[ "${url}" == *"&flag=clash"* ]]; then
            printf 'proxies:\nproxy-groups:\nrules:\n' >"${output}"
            printf '200'
        else
            printf 'vless://test@example.com:443\n' | base64 >"${output}"
            printf '200'
        fi
    }
    sleep() { :; }
    cloudflare_deploy_log() { :; }
    verify_subscription || fail "CMCC subscription verification must survive propagation errors"
    assert_equal "CMCC verification retries both formats three times" \
        "6" "$(<"${verify_calls_file}")"
    assert_equal "CMCC first base64/Clash pair uses one version key" \
        "$(sed -n '1p' "${verify_keys_file}")" "$(sed -n '2p' "${verify_keys_file}")"
    assert_equal "CMCC successful base64/Clash pair uses one version key" \
        "$(sed -n '5p' "${verify_keys_file}")" "$(sed -n '6p' "${verify_keys_file}")"
    [[ "$(sed -n '1p' "${verify_keys_file}")" != "$(sed -n '3p' "${verify_keys_file}")" ]] \
        || fail "CMCC verification attempts must sample different version keys"
)

printf 'ok - standalone CMCC monolith tests passed\n'
