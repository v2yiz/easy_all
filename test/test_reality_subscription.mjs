import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';
import subscription from '../lib/reality-subscription.js';

const root = fileURLToPath(new URL('..', import.meta.url));
const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'easy-all-subscription-'));
const placeholder = '__EASY_ALL_REALITY_PORT__';
const endToken = 'EASY_ALL_REALITY_TEMPLATE_END_V1';
const end = '# ' + endToken + '\n';
const owner = '00000000-0000-4000-8000-000000000001';
const friend = '00000000-0000-4000-8000-000000000002';
let assertions = 0;
function check(actual, expected, message) {
    assert.deepEqual(actual, expected, message);
    assertions++;
}

// Exercise actual Shell generators in an isolated runtime; only OS/network boundaries are replaced.
fs.cpSync(path.join(root, 'lib'), path.join(fixture, 'lib'), { recursive: true });
fs.mkdirSync(path.join(fixture, 'profiles'));
fs.writeFileSync(path.join(fixture, 'package.json'), '{"type":"module"}\n');
const redirected = {
    STATE_DIR: 'state', WEB_ROOT: 'www', NGINX_CONFIG: 'nginx.conf',
    REALITY_SUBSCRIPTION_JS: 'nginx-renderer.js', COMMAND_INSTALL_DIR: 'command',
    COMMAND_PATH: 'bin/easy_all', XRAY_DIR: 'state/xray', XRAY_BIN: 'state/xray/xray',
    XRAY_CONFIG: 'state/xray/config.json', XRAY_SERVICE_FILE: 'xray.service',
    UFW_BEFORE_RULES: 'before.rules', UFW_BEFORE6_RULES: 'before6.rules',
    UFW_DEFAULT_CONFIG: 'ufw-default', SYSCTL_CONFIG: 'sysctl.conf',
    BBR_MODULES_CONFIG: 'modules.conf', IPV6_SYSCTL_CONF: 'ipv6.conf',
};
let profile = fs.readFileSync(path.join(root, 'profiles/reality.sh'), 'utf8');
for (const [name, file] of Object.entries(redirected)) {
    profile = profile.replace(new RegExp(`^readonly ${name}=.*$`, 'm'), `readonly ${name}="${fixture}/${file}"`);
}
fs.writeFileSync(path.join(fixture, 'profiles/reality.sh'), profile);
const setup = `
export TMPDIR="$FIXTURE"
# BSD mktemp may use Darwin per-user temp even with TMPDIR; keep every file in this fixture.
mktemp() {
    if [[ "$*" == -d ]]; then command mktemp -d "$FIXTURE/runtime.XXXXXX"
    else command mktemp "$@"; fi
}
source "$FIXTURE/profiles/reality.sh"
trap 'command rm -rf -- "$RUNTIME_TMP"' EXIT
PROTOCOL=reality
NODE_NAME=fixture
NODE_HOST=203.0.113.10
VLESS_UUID=${owner}
REALITY_TARGET=www.example.com:443
REALITY_PUBLIC_KEY=fixture-public-key
REALITY_SHORT_ID=0123456789abcdef
SUB_PORT_MODE=dynamic
SUBSCRIPTION_MODE=deploy
SUBSCRIPTION_DOMAIN=sub.example.com
SUB_DOWNLOAD_NAME=MY_SUB
ALLOWED_TOKENS='{"owner":"owner-fixture-token","friend":"friend-fixture-token"}'
QUOTA_ENABLED=0
prepare_mihomo_template() { MIHOMO_TEMPLATE_FILE="$FIXTURE/template.yaml"; }
generate_subscription_port() { printf '443\\n'; }
xray_installed_version() { printf 'v26.10.21\\n'; }
resolve_reality_client_ip_family() { REALITY_CLIENT_IP_FAMILY_RESOLVED=ipv4; }
require_root() { :; }
collect_installed_state() { :; }
nginx_supports_http2_directive() { return 1; }
systemctl() { :; }
nginx() { :; }
# Ignore ownership changes in macOS fixtures, retaining real install/copy/mode behavior.
install() {
    local -a args=()
    while (($#)); do
        case "$1" in -o|-g) shift 2 ;; *) args+=("$1"); shift ;; esac
    done
    command install "\${args[@]}"
}
`;
// Keep template content deliberately rich enough to detect accidental global port replacement.
fs.writeFileSync(path.join(fixture, 'template.yaml'), `mixed-port: 443\ndns:\n  listen: 127.0.0.1:443\nproxies:\n# EASY_ALL_PROXY_NODE\n  - name: external\n    port: 443\nproxy-groups:\n  - name: all\n    proxies:\n# EASY_ALL_PROXY_NAME\nrules:\n  - MATCH,all\n`);
fs.writeFileSync(path.join(fixture, 'render-response.mjs'), `
import subscription from './lib/reality-subscription.js';
const [format, dir, mode] = process.argv.slice(2);
subscription[format]({
    method: 'GET', headersOut: {},
    variables: { request_filename: dir + '/' + (format === 'base64' ? 'base64' : 'mihomo') + '.port-template', easy_all_reality_port_mode: mode },
    return(status, body) { if (status !== 200) process.exit(1); process.stdout.write(body); },
});
`);
function shell(script) {
    const scriptBody = setup + `
trap 'printf "fixture error at line %s\\n" "$LINENO" >&2' ERR
` + script;
    const result = spawnSync('bash', ['-c', scriptBody], {
        env: { ...process.env, FIXTURE: fixture, TMPDIR: fixture }, encoding: 'utf8', timeout: 30000,
    });
    assert.equal(result.status, 0, `Shell fixture failed: ${result.stderr}\n${result.stdout}`);
    assertions++;
    return result.stdout;
}

function request(format, file, timestamp, mode = 'dynamic', method = 'GET') {
    let calls = 0;
    const original = Date.now;
    Date.now = () => { calls++; return timestamp; };
    const response = {
        method, variables: { request_filename: file, easy_all_reality_port_mode: mode }, headersOut: {},
        get args() { throw new Error('must not read query credentials'); },
        error() { assert.fail('must not log'); }, warn() { assert.fail('must not log'); },
        return(status, body) { this.status = status; this.body = body; },
    };
    try { subscription[format](response); } finally { Date.now = original; }
    if (response.status === 200) check(calls, 1, 'one timestamp per request');
    return response;
}
function unavailable(response) {
    check([response.status, response.body, response.headersOut['Content-Type']],
        [503, 'Subscription unavailable\n', 'text/plain']);
}

try {
    shell(`mkdir -p "$STATE_DIR" "$XRAY_DIR"
generate_subscription_files "$FIXTURE/base64.port-template" "$FIXTURE/mihomo.port-template"
build_mihomo_node 443 >"$FIXTURE/reference-node.yaml"
render_mihomo_subscription "$MIHOMO_TEMPLATE_FILE" "$FIXTURE/reference-node.yaml" "$FIXTURE/reference.yaml" "$NODE_NAME"
VLESS_UUID=${friend}
generate_subscription_files "$FIXTURE/friend.base64.port-template" "$FIXTURE/friend.mihomo.port-template"
`);
    const yaml = fs.readFileSync(path.join(fixture, 'mihomo.port-template'), 'utf8');
    const snapshot = fs.readFileSync(path.join(fixture, 'reference.yaml'), 'utf8');
    check(yaml.endsWith(end), true);
    check(yaml.split(endToken).length, 2);
    check(snapshot.includes(endToken), false);
    check(yaml.slice(0, -end.length).replace(placeholder, '443'), snapshot);
    check(snapshot.includes('support-x25519mlkem768: true'), true);
    check(snapshot.includes('ip-version: ipv4'), true);
    const workerText = fs.readFileSync(path.join(root, 'worker-src/index.js'), 'utf8');
    const worker = vm.runInNewContext(workerText.slice(0, workerText.indexOf('function resolveNodePorts')) +
        '\n({getHourCount,dynamicPortSlot,dynamicPort,nodePort})', {
        PRIVATE_CONFIG: { allowedTokens: {}, nodes: [] }, Date,
    });
    const boundaryCases = [
        ['2025-12-31T16:00:00.000Z', 10000], ['2026-01-01T00:00:00.000Z', 10048],
        ['2026-01-01T01:00:00.000Z', 10054], ['2026-12-31T15:59:59.000Z', 62559],
        ['2028-12-31T15:59:59.000Z', 62703],
    ];
    for (const [time, port] of boundaryCases) check(subscription.nodePort(Date.parse(time), 'dynamic'), port);
    const newYear = Date.parse('2025-12-31T16:00:00Z');
    for (let i = 0; i < 7; i++) {
        check(subscription.nodePort(newYear + i, 'dynamic'), 10000 + i % 6);
        check(subscription.nodePort(newYear + i * 1000, 'dynamic'), 10000 + i % 6);
    }
    const times = ['2026-06-01T15:59:59.999Z', '2026-06-01T16:00:00.000Z',
        '2026-01-01T00:59:59.999Z', '2028-02-28T15:59:59.999Z',
        '2028-02-28T16:00:00.000Z', '2028-02-29T16:00:00.000Z',
        '2028-12-31T16:00:00.000Z'].map(Date.parse);
    for (let i = 0; i < 120; i++) times.push(newYear + i * 241234567 + (i * 37) % 1000);
    for (const time of times) check(subscription.nodePort(time, 'dynamic'), worker.nodePort({ now: () => time }));
    for (const mode of ['dynamic', '443']) {
        for (const time of [newYear, newYear + 1, newYear + 3600000]) {
            for (const method of ['GET', 'HEAD']) {
                const b = request('base64', path.join(fixture, 'base64.port-template'), time, mode, method);
                const y = request('mihomo', path.join(fixture, 'mihomo.port-template'), time, mode, method);
                const port = mode === '443' ? 443 : worker.nodePort({ now: () => time });
                check([b.status, y.status], [200, 200]);
                check(y.body, yaml.slice(0, -end.length).replace(placeholder, String(port)));
                const link = Buffer.from(b.body.trim(), 'base64').toString();
                check(link.includes(`@203.0.113.10:${port}?`), true);
                check(link.includes(owner), true);
                const other = request('mihomo', path.join(fixture, 'friend.mihomo.port-template'), time, mode, method);
                check(other.body.includes(friend) && !other.body.includes(owner), true);
            }
        }
    }
    for (const format of ['base64', 'mihomo']) {
        const source = fs.readFileSync(path.join(fixture, `${format === 'base64' ? 'base64' : 'mihomo'}.port-template`), 'utf8');
        const decoded = format === 'base64' ? Buffer.from(source.trim(), 'base64').toString() : source;
        const malformed = ['', decoded.replace(placeholder, '443'), decoded.replace(placeholder, placeholder + placeholder),
            decoded.replace(':' + placeholder + '?', ':443?extra=' + placeholder),
            decoded.replace('    port: ' + placeholder, '    name: ' + placeholder)];
        if (format === 'mihomo') {
            malformed.push(source.slice(0, source.indexOf('    port: ') + ('    port: ' + placeholder + '\n').length),
                source.slice(0, -end.length), source.slice(0, -1), source.slice(0, -12),
                source.slice(0, -end.length - 1) + end,
                source + end, source + '\n', source + 'x');
        }
        // Only include mutations that change the chosen representation.
        for (const text of [...new Set(malformed)].filter(text => text !== decoded)) {
            const file = path.join(fixture, 'broken-template');
            fs.writeFileSync(file, format === 'base64' ? Buffer.from(text).toString('base64') + '\n' : text);
            for (const method of ['GET', 'HEAD']) unavailable(request(format, file, newYear, 'dynamic', method));
        }
        for (const bad of [NaN, Infinity, -1, 1e30]) {
            unavailable(request(format, path.join(fixture, format === 'base64' ? 'base64.port-template' : 'mihomo.port-template'), bad));
            assert.throws(() => subscription.nodePort(bad, '443'));
            assertions++;
        }
        unavailable(request(format, path.join(fixture, 'missing-token-uuid'), newYear));
        unavailable(request(format, fixture, newYear));
        unavailable(request(format, path.join(fixture, 'base64.port-template'), newYear, 'query-mode'));
        check(request(format, '', newYear, 'dynamic', 'POST').status, 405);
    }
    for (const value of ['!!!!', 'YQ', 'YQ====', 'YQ==garbage', fs.readFileSync(path.join(fixture, 'base64.port-template'), 'utf8').trim() + '!']) {
        fs.writeFileSync(path.join(fixture, 'bad-base64'), value);
        unavailable(request('base64', path.join(fixture, 'bad-base64'), newYear));
    }
    shell(`cp "$FIXTURE/template.yaml" "$FIXTURE/template.good"
printf '# ${endToken}\\n' >>"$FIXTURE/template.yaml"
if (generate_subscription_files "$FIXTURE/a" "$FIXTURE/b"); then exit 1; fi
mv "$FIXTURE/template.good" "$FIXTURE/template.yaml"
`);
    const staticLocations = spawnSync('bash', ['-c', `
source "$1/lib/subscription-auth.sh"
SUBSCRIPTION_DIR="$2"
SUBSCRIPTION_BASE64_FILE="$2/base64.txt"
SUBSCRIPTION_MIHOMO_FILE="$2/mihomo.yaml"
SUB_DOWNLOAD_NAME=MY_SUB
subscription_enabled() { return 0; }
quota_enabled() { return 0; }
write_subscription_nginx_locations
`, '_', root, fixture], { encoding: 'utf8', timeout: 10000 });
    check(staticLocations.status, 0, staticLocations.stderr);
    check(staticLocations.stdout.includes('/$easy_all_subscription_allowed/base64.txt;'), true);
    check(/js_content|port-template|error_log/.test(staticLocations.stdout), false);
    shell(`
mkdir -p "$STATE_DIR" "$XRAY_DIR" "$CERT_DIR"
REALITY_PRIVATE_KEY=fixture-private-key
GOOGLE_EGRESS_MODE=ipv4
GOOGLE_EGRESS_RESOLVED=ipv4
printf 'fixture-state\\n' >"$STATE_FILE"
printf 'fixture-cert\\n' >"$CERT_FILE"
printf 'fixture-key\\n' >"$KEY_FILE"
apt-get() { printf 'apt:%s\\n' "$*" >>"$FIXTURE/lifecycle.log"; }
systemctl() { printf 'systemctl:%s\\n' "$*" >>"$FIXTURE/lifecycle.log"; }
nginx() {
    printf 'nginx:%s\\n' "$*" >>"$FIXTURE/lifecycle.log"
    [[ -s "$REALITY_SUBSCRIPTION_JS" ]] || return 1
    if grep -Fq 'js_import ' "$NGINX_CONFIG"; then
        [[ -s "$SUBSCRIPTION_BASE64_FILE" && -s "$SUBSCRIPTION_MIHOMO_FILE" ]] || return 1
    fi
}
# Cloud provisioning is an external boundary; no network or real certificates in this fixture.
reality_cloudflare_prepare_subscription() { [[ -s "$REALITY_SUBSCRIPTION_JS" ]]; }
reality_cloudflare_issue_origin_certificate() { :; }
reality_cloudflare_configure_strict_tls() { :; }
ss() { :; }
rm() {
    if [[ "$*" == '-f -- /etc/nginx/sites-enabled/default' ]]; then return 0; fi
    command rm "$@"
}
curl() {
    if [[ "$*" == *'--request POST'* ]]; then printf '405'; return 0; fi
    if [[ "$*" == *'token=invalid'* ]]; then printf '403'; return 0; fi
    if [[ "$*" == *'/easy_all-health'* ]]; then printf 'easy_all ok'; return 0; fi
    [[ "$*" == *'token@-'* && "$(cat)" == owner-fixture-token ]] || return 1
    local format=base64 body
    [[ "$*" != *'flag=clash'* ]] || format=mihomo
    body=$(node "$FIXTURE/render-response.mjs" "$format" "$SUBSCRIPTION_DIR" "$SUB_PORT_MODE") || return 1
    if [[ "$*" == *'--head'* ]]; then
        if [[ "$format" == mihomo ]]; then printf 'Content-Type: text/yaml\\r\\n'
        else printf 'Content-Type: text/plain\\r\\n'; fi
        printf 'Content-Length: %s\\r\\n' "\${#body}"
    else printf '%s\\n' "$body"; fi
}
# Real deploy chain: dependency/script, bootstrap, two-file publication, writer and local acceptance.
SUB_PORT_MODE=443
deploy_subscription_service
cmp "$SCRIPT_DIR/reality-subscription.js" "$REALITY_SUBSCRIPTION_JS"
grep -Fq 'nginx cron libnginx-mod-http-js' "$FIXTURE/lifecycle.log"
grep -Fq 'js_import ' "$NGINX_CONFIG"
[[ "$(find "$SUBSCRIPTION_DIR" -type f | wc -l | tr -d ' ')" == 2 ]]
! grep -Eq '/(base64.txt|mihomo.yaml);' "$NGINX_CONFIG"
[[ "$(grep -c 'error_log /dev/null;' "$NGINX_CONFIG")" == 3 ]]
grep -Fq 'filename=MY_SUB' "$NGINX_CONFIG"
# The OS command boundary models module/asset validation; an unavailable module aborts deployment.
if (apt-get() { return 1; }; deploy_subscription_service); then exit 1; fi
if (nginx() { return 1; }; write_subscription_nginx_config); then exit 1; fi

# Actual quota_sync_usage -> Reality rebuild -> actual Xray writer + token map writer.
cat >"$XRAY_BIN" <<'XRAY'
#!/bin/sh
case "$1" in
x25519) printf 'PublicKey: fixture-public-key\\n' ;;
run) exit 0 ;;
api) printf '{"stat":[{"name":"user>>>easy_all.friend>>>traffic>>>uplink","value":1100000000}]}\\n' ;;
*) exit 1 ;;
esac
XRAY
chmod 0755 "$XRAY_BIN"
validate_protocol_runtime() { :; }
flock() { :; }
QUOTA_ENABLED=1
QUOTA_START_DATE=2025-01-01
USER_ACCOUNTS='{"owner":{"token":"owner-fixture-token","uuid":"${owner}","quota_gb":0},"friend":{"token":"friend-fixture-token","uuid":"${friend}","quota_gb":1}}'
write_xray_config
install_static_subscriptions
for user in owner friend; do
    [[ "$(find "$SUBSCRIPTION_DIR/$user" -type f | wc -l | tr -d ' ')" == 2 ]]
    for file in base64.port-template mihomo.port-template; do
        [[ -s "$SUBSCRIPTION_DIR/$user/$file" ]]
    done
done
! find "$SUBSCRIPTION_DIR" -type f | grep -Eq '/(base64.txt|mihomo.yaml)$'
grep -Fq '${owner}' "$SUBSCRIPTION_DIR/owner/mihomo.port-template"
! grep -Fq '${friend}' "$SUBSCRIPTION_DIR/owner/mihomo.port-template"
grep -Fq '${friend}' "$SUBSCRIPTION_DIR/friend/mihomo.port-template"
# The nginx boundary now verifies each actual authorized alias source is a complete template.
nginx() { [[ -s "$REALITY_SUBSCRIPTION_JS" ]]; }
: >"$FIXTURE/lifecycle.log"
grep -Fq '${friend}' "$XRAY_CONFIG"
grep -Fq 'friend-fixture-token' "$NGINX_CONFIG"
quota_sync_usage
[[ "$(jq -r '.users.friend.disabled' "$QUOTA_USAGE_FILE")" == true ]]
! grep -Fq '${friend}' "$XRAY_CONFIG"
! grep -Fq 'friend-fixture-token' "$NGINX_CONFIG"
grep -Fq 'owner-fixture-token' "$NGINX_CONFIG"
grep -Fq 'js_content easy_all_reality_subscription.mihomo;' "$NGINX_CONFIG"
! grep -Fq 'apt:' "$FIXTURE/lifecycle.log"

# Normal future update failure restores assets before activating the exact backed-up config.
crontab() { [[ "$1" == -l ]] && return 0; cat >/dev/null; }
source_state_file() { SUBSCRIPTION_MODE=deploy; SUB_PORT_MODE=443; }
restore_dynamic_port_rotation_schedule() { :; }
configure_ufw() { :; }
snapshot_subscription_update
printf 'broken-renderer\\n' >"$REALITY_SUBSCRIPTION_JS"
printf 'damaged-template\\n' >"$SUBSCRIPTION_DIR/owner/mihomo.port-template"
printf 'damaged-cert\\n' >"$CERT_FILE"
printf 'broken-config\\n' >"$NGINX_CONFIG"
nginx() {
    cmp "$UPDATE_SUB_BACKUP_DIR/reality-subscription.js" "$REALITY_SUBSCRIPTION_JS" || return 1
    cmp "$UPDATE_SUB_BACKUP_DIR/fullchain.pem" "$CERT_FILE" || return 1
    cmp "$UPDATE_SUB_BACKUP_DIR/subscriptions/owner/mihomo.port-template" "$SUBSCRIPTION_DIR/owner/mihomo.port-template" || return 1
    cmp "$UPDATE_SUB_BACKUP_DIR/nginx.conf" "$NGINX_CONFIG"
}
rollback_subscription_update
UPDATE_SUB_ROLLBACK_ON_EXIT=0
cmp "$SCRIPT_DIR/reality-subscription.js" "$REALITY_SUBSCRIPTION_JS"
# Missing script makes external validation fail; runtime rebuild restores its previous njs config.
cp "$NGINX_CONFIG" "$FIXTURE/config.before-rebuild"
rm -f "$REALITY_SUBSCRIPTION_JS"
nginx() { [[ -s "$REALITY_SUBSCRIPTION_JS" ]]; }
if rebuild_traffic_runtime >/dev/null 2>&1; then exit 1; fi
cmp "$FIXTURE/config.before-rebuild" "$NGINX_CONFIG"
# Remove service config before its script, and clean orphan script even without WEB_ROOT/config.
install_reality_subscription_renderer
remove_subscription_service_runtime
[[ ! -e "$REALITY_SUBSCRIPTION_JS" && ! -e "$NGINX_CONFIG" ]]
printf 'orphan\\n' >"$REALITY_SUBSCRIPTION_JS"
remove_subscription_service_runtime
[[ ! -e "$REALITY_SUBSCRIPTION_JS" ]]
`);
    shell(`
mkdir -p "$STATE_DIR" "$XRAY_DIR"
cat >"$STATE_FILE" <<'STATE'
STATE_VERSION=7
SUBSCRIPTION_MODE=link
SUB_PORT_MODE=dynamic
SCHEDULED_REBOOT_ENABLED=0
GOOGLE_EGRESS_MODE=ipv4
GOOGLE_EGRESS_RESOLVED=ipv4
STATE
printf '*filter\\nCOMMIT\\n' >"$UFW_BEFORE_RULES"
printf '*filter\\nCOMMIT\\n' >"$UFW_BEFORE6_RULES"
printf 'IPV6=no\\n' >"$UFW_DEFAULT_CONFIG"
printf '15 2 * * * /fixture/user-job\\n' >"$FIXTURE/rollback.cron"
crontab() {
    if [[ "$1" == -l ]]; then cat "$FIXTURE/rollback.cron"
    elif [[ "$1" == - ]]; then cat >"$FIXTURE/rollback.cron"
    else cat "$1" >"$FIXTURE/rollback.cron"; fi
}
# Only host command boundaries are replaced; NAT generation, UFW orchestration and rollback are real.
flock() { :; }
ensure_ssh_boot_service() { :; }
ensure_ssh_fail2ban() { :; }
detect_ssh_ports() { SSH_PORTS=65533; }
iptables-restore() { cat >/dev/null; }
reality_cloudflare_configure_subscription_firewall() { :; }
ufw() {
    if [[ "$1" == status ]]; then
        printf 'Status: active\\n'
        if [[ "\${2:-}" == numbered ]]; then
            printf '[ 1] 65533/tcp ALLOW IN Anywhere # easy_all-managed\\n'
            printf '[ 2] 443/tcp ALLOW IN Anywhere # easy_all-managed\\n'
        fi
    elif [[ "$1" == reload ]]; then
        cat "$UFW_BEFORE_RULES" >"$FIXTURE/active-nat.rules"
        printf 'ufw-reload:%s:%s\\n' "$SUBSCRIPTION_MODE" "$SUB_PORT_MODE" >>"$FIXTURE/rollback.log"
    fi
}
# Absence of nginx is an OS capability fixture, independent of whether CI has the binary installed.
NGINX_PRESENT=0
command() {
    if [[ "$*" == '-v nginx' && "$NGINX_PRESENT" == 0 ]]; then return 1; fi
    builtin command "$@"
}
nginx() { printf 'unexpected-nginx-call\\n' >>"$FIXTURE/rollback.log"; return 127; }
collect_installed_state() { source_state_file; }
# Explicit noninteractive user-input seam: switch link to deploy while requesting fixed port 443.
collect_subscription_inputs() { SUBSCRIPTION_MODE=deploy; }
source_state_file
configure_ufw
configure_dynamic_port_rotation
cp "$STATE_FILE" "$FIXTURE/link-state.before"
cp "$UFW_BEFORE_RULES" "$FIXTURE/link-nat.before"
: >"$FIXTURE/rollback.log"
apt-get() {
    [[ "$SUB_PORT_MODE" == 443 && "$SUBSCRIPTION_MODE" == deploy ]] || return 2
    if grep -Fq -- '--dport 10000:62703' "$FIXTURE/active-nat.rules"; then return 2; fi
    printf 'apt-failed-after-fixed-ufw\\n' >>"$FIXTURE/rollback.log"
    printf '15 2 * * * /fixture/user-job\\n' >"$FIXTURE/rollback.cron"
    return 1
}
SUB_PORT_MODE=443
if update_subscription 0; then printf 'failed deploy unexpectedly succeeded\\n' >&2; exit 1; fi
cmp "$FIXTURE/link-state.before" "$STATE_FILE"
[[ "$SUB_PORT_MODE" == dynamic && "$SUBSCRIPTION_MODE" == link ]]
diff -B "$FIXTURE/link-nat.before" "$UFW_BEFORE_RULES"
grep -Fq -- '--dport 10000:62703' "$FIXTURE/active-nat.rules"
grep -Fq 'apt-failed-after-fixed-ufw' "$FIXTURE/rollback.log"
grep -Fq 'ufw-reload:link:dynamic' "$FIXTURE/rollback.log"
! grep -Fq 'unexpected-nginx-call' "$FIXTURE/rollback.log"
grep -Fq 'rotate-dynamic-ports' "$FIXTURE/rollback.cron"
[[ ! -e "$NGINX_CONFIG" && ! -e "$REALITY_SUBSCRIPTION_JS" ]]
[[ "$UPDATE_SUB_ROLLBACK_ON_EXIT" == 0 && "$RUNTIME_WRITE_LOCK_DEPTH" == 0 ]]

# Existing njs deploy: nginx recovery failure is returned only after independent recovery completes.
NGINX_PRESENT=1
nginx() { return 0; }
SUBSCRIPTION_MODE=deploy
sed 's/SUBSCRIPTION_MODE=link/SUBSCRIPTION_MODE=deploy/' "$STATE_FILE" >"$FIXTURE/deploy-state"
cp "$FIXTURE/deploy-state" "$STATE_FILE"
install_reality_subscription_renderer
install_static_subscriptions
write_subscription_nginx_config
configure_ufw
snapshot_subscription_update
cp "$STATE_FILE" "$FIXTURE/deploy-state.before"
cp "$UFW_BEFORE_RULES" "$FIXTURE/deploy-nat.before"
SUB_PORT_MODE=443
configure_ufw
printf '15 2 * * * /fixture/user-job\\n' >"$FIXTURE/rollback.cron"
: >"$FIXTURE/rollback.log"
nginx() { printf 'nginx-validation-failed\\n' >>"$FIXTURE/rollback.log"; return 1; }
if rollback_subscription_update; then printf 'nginx recovery failure was hidden\\n' >&2; exit 1; fi
UPDATE_SUB_ROLLBACK_ON_EXIT=0
cmp "$FIXTURE/deploy-state.before" "$STATE_FILE"
[[ "$SUB_PORT_MODE" == dynamic && "$SUBSCRIPTION_MODE" == deploy ]]
diff -B "$FIXTURE/deploy-nat.before" "$UFW_BEFORE_RULES"
grep -Fq -- '--dport 10000:62703' "$FIXTURE/active-nat.rules"
grep -Fq 'nginx-validation-failed' "$FIXTURE/rollback.log"
grep -Fq 'ufw-reload:deploy:dynamic' "$FIXTURE/rollback.log"
grep -Fq 'rotate-dynamic-ports' "$FIXTURE/rollback.cron"
`);
    console.log(`ok - Reality request subscription tests passed (${assertions} assertions)`);
} finally {
    fs.rmSync(fixture, { recursive: true, force: true });
}
