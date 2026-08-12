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
assert_contains "standalone executable exposes CMCC usage" "${output}" "XHTTP stream-up、stream-one 与 WSS"

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
assert_contains "CMCC persists the Worker Custom Domain" "${installer}" \
    "WORKER_CUSTOM_DOMAIN=%q"
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
    "独立单文件安装器"
assert_contains "README downloads the CMCC monolith" "${readme}" \
    "main/for_cmcc/easy_cmcc"
assert_contains "README uses the aligned one-line install command" "${readme}" \
    'wget -qO /root/easy_cmcc.new "https://raw.githubusercontent.com/v2yiz/easy_all/main/for_cmcc/easy_cmcc" && chmod 700 /root/easy_cmcc.new && mv -f /root/easy_cmcc.new /root/easy_cmcc && /root/easy_cmcc install'
assert_contains "README documents optimized default proxy order" "${readme}" \
    '`PROXY`：`stream-up` → `stream-one` → WSS'
assert_contains "README documents optimized GitHub order" "${readme}" \
    '`GITHUB`：`stream-up` → WSS → `stream-one`'
assert_contains "README documents optimized Google order" "${readme}" \
    '`GOOGLE`：`stream-up` → `stream-one` → WSS'
assert_contains "README documents the DNS-only precondition" "${readme}" \
    "DNS only / 灰云"
assert_contains "README documents enabling the CDN after install" "${readme}" \
    "Proxied / 橙云"
assert_contains "README documents isolated state" "${readme}" \
    "/etc/easy_cmcc/state.env"
assert_contains "README documents that uninstall leaves remote Cloudflare resources" "${readme}" \
    "远端 Cloudflare Worker 及其 Custom Domain 不会删除"
assert_contains "README documents the expanded Worker verification window" "${readme}" \
    "先等待 10 秒，再进行最多 12 次"
assert_contains "README recommends the custom subscription domain" "${readme}" \
    "推荐：使用 Worker Custom Domain"
assert_contains "README warns against long-term workers.dev subscriptions" "${readme}" \
    "不建议作为长期订阅地址"
assert_contains "README keeps subscription and node domains separate" "${readme}" \
    "不要与 XHTTP/WSS 节点域名"
assert_contains "README documents automatic CDN setup for Custom Domain" "${readme}" \
    "相当于自动完成 Cloudflare CDN 接入"
assert_contains "README documents automatic Custom Domain attachment" "${readme}" \
    "脚本会调用 Cloudflare Custom Domain API"
assert_contains "README documents the workers.dev fallback" "${readme}" \
    '回退到 `workers.dev`'
assert_contains "README documents Custom Domain conflict protection" "${readme}" \
    "拒绝抢占已经绑定到其他 Worker"
assert_contains "README documents idempotent Custom Domain updates" "${readme}" \
    '已绑定到当前 `easy-cmcc` 时直接复用，不重复创建'
assert_contains "README distinguishes node and subscription domains" "${readme}" \
    "两个域名不能相同"
assert_contains "README documents the recommended interactive Worker choice" "${readme}" \
    '订阅输出方式 | `1`，自动部署 Worker'
assert_contains "README documents client import" "${readme}" \
    "客户端导入与验收"
assert_contains "README documents IPv4 and IPv6 LAN bypass" "${readme}" \
    "RFC1918 IPv4、IPv4 链路本地、IPv6 ULA、IPv6 链路本地"
assert_contains "README provides standalone troubleshooting" "${readme}" \
    "## 故障排查"
[[ -s "${ROOT_DIR}/docs/images/cloudflare-worker-custom-domain.svg" ]] \
    || fail "README Worker Custom Domain figure is missing"
for credential_figure in \
    cloudflare-account-id.svg cloudflare-zone-token.svg cloudflare-worker-token.svg; do
    [[ -s "${ROOT_DIR}/../docs/images/${credential_figure}" ]] \
        || fail "README credential figure is missing: ${credential_figure}"
    assert_contains "README references credential figure ${credential_figure}" "${readme}" \
        "../docs/images/${credential_figure}"
done
assert_contains "README explains all four DNS Token permissions" "${readme}" \
    '图中的四行权限对应四项独立操作'
assert_contains "README documents Config Rules naming compatibility" "${readme}" \
    'Config Settings → Write'
assert_contains "README documents minimal Worker Token scope" "${readme}" \
    '不需要 `Workers Routes`、DNS、KV 或 R2 权限'
[[ "${readme}" != *"方案 B"* ]] \
    || fail "README must present only the recommended Worker Custom Domain flow"
[[ "${readme}" != *"无人值守"* ]] \
    || fail "README must omit unattended-operation documentation"

if bash -c 'source "$1"; choose_protocol reality' _ "${ROOT_DIR}/easy_cmcc" \
    >/dev/null 2>&1; then
    fail "standalone executable must reject Reality"
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
    assert_contains "Worker URL uses the CMCC subtree" "${DEFAULT_SAMPLE_WORKER_URL}" "/for_cmcc/sample-worker.js"
    assert_contains "CMCC subscription verification uses Worker version affinity" \
        "$(<"${ROOT_DIR}/easy_cmcc")" "Cloudflare-Workers-Version-Key"
    assert_contains "CMCC subscription verification bypasses intermediary caches" \
        "$(<"${ROOT_DIR}/easy_cmcc")" "Cache-Control: no-cache"

    choose_protocol vless-xhttp >/dev/null
    VLESS_UUID="00000000-0000-4000-8000-000000000001"
    VLESS_XHTTP_DOMAIN="cmcc.example.com"
    NODE_NAME="CMCC_XHTTP"
    XHTTP_PATH="/cmcc-xhttp"
    VLESS_WS_NODE_NAME="CMCC_WSS"
    VLESS_WS_PATH="/cmcc-wss"
    WORKER_CUSTOM_DOMAIN="SUB.EXAMPLE.COM"
    collect_worker_custom_domain
    assert_equal "CMCC normalizes the Worker Custom Domain" \
        "sub.example.com" "${WORKER_CUSTOM_DOMAIN}"
    if (
        WORKER_CUSTOM_DOMAIN="cmcc.example.com"
        collect_worker_custom_domain
    ) >/dev/null 2>&1; then
        fail "CMCC must reject reusing the XHTTP/WSS node domain"
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
    assert_contains "subscription contains XHTTP" "${links}" "type=xhttp"
    assert_contains "XHTTP prefers stream-up" "${links}" "mode=stream-up"
    assert_contains "XHTTP retains stream-one fallback" "${links}" "mode=stream-one"
    assert_contains "XHTTP fallback gets a distinct name" "${links}" "CMCC_XHTTP_STREAM_ONE"
    assert_contains "XHTTP forces HTTP/2" "${links}" "alpn=h2"
    assert_contains "subscription contains WSS" "${links}" "type=ws"
    assert_contains "both transports use TCP 443" "${links}" "@cmcc.example.com:443"

    ALLOWED_TOKENS='{"owner":"test-token"}'
    SUB_DOWNLOAD_NAME="CMCC_TEST"
    SAMPLE_WORKER_SOURCE="${ROOT_DIR}/sample-worker.js"
    WORKER_NAME="easy-cmcc"
    worker_output="${TMP_DIR}/subscribe-worker.js"
    write_worker "${worker_output}"
    grep -Fq '"network":"xhttp"' "${worker_output}" \
        || fail "rendered Worker must include XHTTP"
    [[ "$(grep -Fo '"network":"xhttp"' "${worker_output}" | wc -l | tr -d ' ')" == "2" ]] \
        || fail "rendered Worker must include stream-up and stream-one XHTTP nodes"
    grep -Fq '"mode":"stream-up"' "${worker_output}" \
        || fail "rendered Worker must prefer XHTTP stream-up"
    grep -Fq '"mode":"stream-one"' "${worker_output}" \
        || fail "rendered Worker must retain XHTTP stream-one fallback"
    grep -Fq '"network":"ws"' "${worker_output}" \
        || fail "rendered Worker must include WSS"
    grep -Fq 'const DEFAULT_NODE = [NODE_CONFIG, XHTTP_STREAM_ONE_NODE_CONFIG, WS_NODE_CONFIG]' "${worker_output}" \
        || fail "rendered Worker must publish all three optimized nodes"
    grep -Fq 'mode: "auto"' "${ROOT_DIR}/easy_cmcc" \
        || fail "Xray server must accept all XHTTP upload modes"
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
assert.equal(links.length, 3);
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

    custom_domain_api_calls="${TMP_DIR}/cmcc-custom-domain-api-calls"
    : >"${custom_domain_api_calls}"
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
            *) printf '%s' '{"success":true,"result":[]}' ;;
            esac
        else
            printf '%s' '{"success":true,"result":{"hostname":"sub.example.com","service":"easy-cmcc"}}'
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
