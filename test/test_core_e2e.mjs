// 真核心端到端门禁（design §13）：缺核心即失败，不跳过。
// 1) 五模式正式配置通过真实核心校验（sing-box check / xray run -test）与 `caddy validate`；
// 2) 阻断/订阅未就绪变体同样通过核心校验（配置层面覆盖 §7/§8 的两种极端形态）；
// 3) 模式 5 的阻断态必须省略 XHTTP 入站、Caddy 代理路径返回 503。
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync, existsSync, accessSync, constants } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(new URL('.', import.meta.url)));
const singbox = process.env.SINGBOX_BIN || '/etc/easy_all/sing-box/sing-box';
const xray = process.env.XRAY_BIN || '/etc/easy_all/xray/xray';
const caddy = process.env.CADDY_BIN || '/etc/easy_all/caddy/caddy';

const verify = spawnSync('bash', [join(root, 'scripts/verify-cores.sh')], {
  encoding: 'utf8',
  env: process.env,
});
if (verify.status !== 0) {
  process.stderr.write(verify.stdout || '');
  process.stderr.write(verify.stderr || '');
  assert.fail('verify-cores 未通过：缺少锁定版本的核心或配置被拒绝');
}
process.stdout.write(verify.stdout);

// 变体步骤会重新 source profile，核心路径回落到环境变量/默认路径。verify-cores 自己下载的
// 临时副本已随其退出删除：此处缺失必须响亮失败，不能静默降级为 jq 结构校验。
for (const [label, bin] of [['sing-box', singbox], ['Xray', xray], ['Caddy', caddy]]) {
  let ok = existsSync(bin);
  if (ok) {
    try {
      accessSync(bin, constants.X_OK);
    } catch {
      ok = false;
    }
  }
  assert.ok(ok, `缺少可执行的 ${label}（${bin}）：真核心门禁不接受结构校验兜底；请显式设置 SINGBOX_BIN/XRAY_BIN/CADDY_BIN`);
}

// 变体：阻断态（省略 CDN 入站 / 代理路径 503）与订阅未就绪（/subscribe 503）。
const tmp = mkdtempSync(join(tmpdir(), 'easy-all-core-e2e-'));
process.on('exit', () => rmSync(tmp, { recursive: true, force: true }));

const script = `
set -Eeuo pipefail
export RUNTIME_TMP="${tmp}/runtime"
export EASY_ALL_STATE_DIR_OVERRIDE="${tmp}/state"
export EASY_ALL_CERT_DIR_OVERRIDE="${tmp}/certs"
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${tmp}/subscriptions"
source "${root}/profiles/reality-cloudfront.sh"
mkdir -p "\${RUNTIME_TMP}"
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUB_DOWNLOAD_NAME=EASY_ALL
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "\${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
DIRECT_DOMAIN=direct.example.com
DIRECT_NODE_NAME=direct
REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
REALITY_SHORT_ID=0123456789abcdef
CF_NODE_DOMAIN=cf.example.com
CF_NODE_PREFIX=CF
VLESS_UUID=11111111-2222-3333-4444-555555555555
VLESS_PATH=/vless-0123456789ab
CF_ORIGIN_DOMAIN=direct.example.com
SUBSCRIPTION_DOMAIN=cf.example.com
ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
CDN_TRAFFIC_PROTECTION_GB=985
AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE
AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net
AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x
cdn_derive_runtime_fields
install -d -m 0700 "\${CERT_DIR}"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=example.com" \\
    -keyout "\${KEY_FILE}" -out "\${CERT_FILE}" >/dev/null 2>&1
chmod 0600 "\${KEY_FILE}"
render_singbox_config "${tmp}/blocked.json" 1
validate_singbox_config "${tmp}/blocked.json"
render_caddy_config "${tmp}/Caddyfile.blocked" 1 0
validate_caddy_config "${tmp}/Caddyfile.blocked"
`;
const variants = spawnSync('bash', ['-c', script], { encoding: 'utf8', env: process.env });
assert.equal(variants.status, 0, variants.stderr || variants.stdout);

const blocked = spawnSync('jq', ['-e', '[.inbounds[] | select(.tag == "vless-cdn-in")] | length == 0',
  join(tmp, 'blocked.json')], { encoding: 'utf8' });
assert.equal(blocked.status, 0, '阻断态必须省略 CDN 入站');
const caddyBlocked = spawnSync('grep', ['-F', 'respond 503', join(tmp, 'Caddyfile.blocked')], {
  encoding: 'utf8',
});
assert.equal(caddyBlocked.status, 0, '阻断态代理路径必须返回 503');

// 模式 5：同样的阻断/未就绪极端形态必须被真实 xray 与 caddy 接受。
const mode5Script = `
set -Eeuo pipefail
export RUNTIME_TMP="${tmp}/runtime5"
export EASY_ALL_STATE_DIR_OVERRIDE="${tmp}/state5"
export EASY_ALL_CERT_DIR_OVERRIDE="${tmp}/certs5"
export EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${tmp}/subscriptions5"
export XRAY_CONFIG="${tmp}/xray5.json"
export CADDY_CONFIG="${tmp}/Caddyfile5"
source "${root}/profiles/reality-cloudflare-xhttp.sh"
mkdir -p "\${RUNTIME_TMP}"
CF_ZONE=example.com
VPS_PUBLIC_IPV4=203.0.113.10
SUB_DOWNLOAD_NAME=EASY_ALL
ALLOWED_TOKENS='{"owner":"token-abcdefgh"}'
SUBSCRIPTION_CONFIG=$(jq -cn --argjson t "\${ALLOWED_TOKENS}" '{allowedTokens:$t,nodes:[]}')
CLOUDFLARE_ZONE_ID=zoneid
SUBSCRIPTION_MODE=deploy
DIRECT_DOMAIN=direct.example.com
DIRECT_NODE_NAME=direct
VLESS_UUID=11111111-2222-4333-8444-555555555555
REALITY_PRIVATE_KEY=QUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUFBQUE
REALITY_PUBLIC_KEY=QkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkI
REALITY_SHORT_ID=0123456789abcdef
CF_NODE_DOMAIN=cf.example.com
CF_NODE_PREFIX=CF
VLESS_PATH=/vless-0123456789ab
ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef
CLOUDFLARE_TRANSFORM_RULESET_ID=rs-easy-all-test
CLOUDFLARE_TRANSFORM_RULE_ID=rule-easy-all-test
cdn_derive_runtime_fields
install -d -m 0700 "\${CERT_DIR}"
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=direct.example.com" \
    -addext "subjectAltName=DNS:direct.example.com" \
    -keyout "\${KEY_FILE}" -out "\${CERT_FILE}" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=cf.example.com" \
    -addext "subjectAltName=DNS:cf.example.com" \
    -keyout "\${CDN_KEY_FILE}" -out "\${CDN_CERT_FILE}" >/dev/null 2>&1
chmod 0600 "\${KEY_FILE}" "\${CDN_KEY_FILE}"
render_xray_config "\${XRAY_CONFIG}" 1
validate_xray_config "\${XRAY_CONFIG}"
render_caddy_config "\${CADDY_CONFIG}" 1 0
validate_caddy_config "\${CADDY_CONFIG}"
`;
const mode5 = spawnSync('bash', ['-c', mode5Script], { encoding: 'utf8', env: process.env });
assert.equal(mode5.status, 0, mode5.stderr || mode5.stdout);

const xrayBlocked = spawnSync('jq', ['-e', '[.inbounds[] | select(.tag == "vless-cdn-in")] | length == 0',
  join(tmp, 'xray5.json')], { encoding: 'utf8' });
assert.equal(xrayBlocked.status, 0, '模式 5 阻断态必须省略 XHTTP 入站');
const caddy5Blocked = spawnSync('grep', ['-F', 'respond 503', join(tmp, 'Caddyfile5')], {
  encoding: 'utf8',
});
assert.equal(caddy5Blocked.status, 0, '模式 5 阻断态代理路径必须返回 503');

process.stdout.write(`ok - 真核心门禁通过（${singbox} / ${xray} / ${caddy}）\n`);
