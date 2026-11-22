// CLI 入口、状态门禁与四条命令面（design §5/§11）。
// 只通过真实 launcher 与真实 state 文件验证行为，不 mock 内部函数。
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(new URL('.', import.meta.url)));
const launcher = join(root, 'easy_all');
const tmp = mkdtempSync(join(tmpdir(), 'easy-all-cli-'));
process.on('exit', () => rmSync(tmp, { recursive: true, force: true }));

function run(args, env = {}) {
  return spawnSync('bash', [launcher, ...args], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
}

function sourceLauncher(script, env = {}) {
  return spawnSync('bash', ['-c', `source ${JSON.stringify(launcher)}; ${script}`], {
    encoding: 'utf8',
    env: { ...process.env, ...env },
  });
}

const stateFile = join(tmp, 'state.env');
const markerFile = join(tmp, 'install-progress.env');
const stateEnv = { EASY_ALL_STATE_FILE_OVERRIDE: stateFile };
const markerEnv = { EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: markerFile };

function writeState(lines) {
  writeFileSync(stateFile, lines.join('\n') + '\n');
}

// 1. 帮助：五模式、全 443、删除的旧命令不再出现。
const help = run(['help']);
assert.equal(help.status, 0, help.stderr);
assert.match(help.stdout, /1 AnyTLS 直连/);
assert.match(help.stdout, /2 纯 CloudFlare/);
assert.match(help.stdout, /3 AnyTLS \+ CloudFlare/);
assert.match(help.stdout, /4 纯 CloudFront/);
assert.match(help.stdout, /5 AnyTLS \+ CloudFront/);
assert.match(help.stdout, /6 Reality \+ CloudFront/);
assert.match(help.stdout, /443/);
assert.doesNotMatch(help.stdout, /reality-target/);
assert.doesNotMatch(help.stdout, /rotate-dynamic-ports/);
assert.doesNotMatch(help.stdout, /internal-traffic-prepare/, '内部入口不对外列在帮助里');
assert.match(help.stdout, /cleanup-partial/);
assert.match(help.stdout, /update-core/);
assert.match(help.stdout, /hellogfw/);
assert.match(help.stdout, /直连 TCP 443 主动探测日志/);
assert.doesNotMatch(help.stdout, /--port/, '帮助不得宣传已删除的 --port');
// uninstall 默认清理本机与云端：帮助必须说明云端清理，且不再列出已删除的参数。
assert.match(help.stdout, /清理本工具创建的云端资源/);
assert.doesNotMatch(help.stdout, /--purge-cloud/, '旧参数已删除，不得再出现在帮助里');

// 2. 未知命令与参数门禁：必须在读取安装状态、加载 Profile、创建运行时临时目录之前拒绝。
// TMPDIR 指向不存在的目录：若仍尝试 mktemp，会得到“无法创建运行时临时目录”而不是目标文案。
const unknown = run(['not-a-command'], { ...stateEnv, TMPDIR: join(tmp, 'no-such-dir') });
assert.notEqual(unknown.status, 0);
assert.match(unknown.stderr, /未知命令/);
assert.doesNotMatch(unknown.stderr, /尚未安装/);
assert.doesNotMatch(unknown.stderr, /运行时临时目录/);
// 旧命令名必须指向新名，而不是只报「未知命令」。
const renamedPurge = run(['purge-cloudflare'], { ...stateEnv, TMPDIR: join(tmp, 'no-such-dir') });
assert.notEqual(renamedPurge.status, 0);
assert.match(renamedPurge.stderr, /命令已改名/);
assert.match(renamedPurge.stderr, /purge-cloudflare → purge-cloud/);
assert.doesNotMatch(renamedPurge.stderr, /未知命令/);
for (const args of [['tcp-resume', 'extra'], ['apply', 'extra']]) {
  const res = run(args, stateEnv);
  assert.notEqual(res.status, 0, `${args[0]} 必须拒绝额外参数`);
  assert.match(res.stderr, /不接受额外参数/, `${args[0]} 的参数门禁`);
  assert.doesNotMatch(res.stderr, /尚未安装/, `${args[0]} 不得先读安装状态`);
}
// install extra 是兼容性控制用例：旧实现也在读取状态前拒绝，不声称它在旧实现上会变红。
const installArgs = run(['install', 'extra'], stateEnv);
assert.notEqual(installArgs.status, 0);
assert.match(installArgs.stderr, /install 不接受参数/);

// 2a. uninstall 只接受零参数：旧参数（--purge-cloud）、--keep-cloud、普通参数、空参数与
// 多参数都必须在读取安装状态之前非零退出，并提示直接执行 easy_all uninstall。
const noRuntimeTmp = join(tmp, 'no-such-dir');
for (const args of [['--purge-cloud'], ['--keep-cloud'], ['extra'], [''], ['a', 'b']]) {
  const res = run(['uninstall', ...args], { ...stateEnv, TMPDIR: noRuntimeTmp });
  const label = `uninstall ${args.map((arg) => JSON.stringify(arg)).join(' ')}`;
  assert.notEqual(res.status, 0, `${label} 必须被拒绝`);
  assert.match(res.stderr, /uninstall 不支持参数/, `${label} 的参数门禁`);
  assert.match(res.stderr, /uninstall 已默认清理本机与云端资源/,
    `${label} 必须提示默认清理云端`);
  assert.doesNotMatch(res.stderr, /尚未安装/, `${label} 不得先读安装状态`);
  assert.doesNotMatch(res.stderr, /运行时临时目录/, `${label} 不得创建运行时临时目录`);
}

// 2b. 防回归：schema 0 状态存在时，未知命令与通用参数门禁仍必须早于状态读取，
// 不能先报「旧版（schema 0）」。用例结束后删除状态，恢复本段原有的未安装态。
writeState(['STATE_VERSION=0', 'PROTOCOL=reality']);
const unknownWithLegacyState = run(['not-a-command'], {
  ...stateEnv,
  TMPDIR: join(tmp, 'no-such-dir'),
});
assert.notEqual(unknownWithLegacyState.status, 0);
assert.match(unknownWithLegacyState.stderr, /未知命令/);
assert.doesNotMatch(unknownWithLegacyState.stderr, /旧版（schema/,
  '未知命令不得先读取状态');
assert.doesNotMatch(unknownWithLegacyState.stderr, /运行时临时目录/);
const applyExtraWithLegacyState = run(['apply', 'extra'], stateEnv);
assert.notEqual(applyExtraWithLegacyState.status, 0);
assert.match(applyExtraWithLegacyState.stderr, /不接受额外参数/);
assert.doesNotMatch(applyExtraWithLegacyState.stderr, /旧版（schema/,
  '参数门禁不得先读取状态');
rmSync(stateFile, { force: true });

// 3. 未安装时的非安装命令必须明确提示未安装。
const empty = run(['status'], stateEnv);
assert.notEqual(empty.status, 0);
assert.match(empty.stderr, /尚未安装/);

// 3b. register-command 只覆盖运行时目录，必须不受「尚未安装」门禁阻断（bootstrap 自愈入口）。
// root 下会真的写入 /usr/local，因此只在非 root 时断言。
if (process.getuid() !== 0) {
  const registerEnv = {
    EASY_ALL_STATE_FILE_OVERRIDE: join(tmp, 'no-state.env'),
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: join(tmp, 'no-marker.env'),
  };
  const register = run(['register-command'], registerEnv);
  assert.notEqual(register.status, 0);
  assert.doesNotMatch(register.stderr, /尚未安装/,
    '自愈入口不能被未安装门禁拦下');
  assert.match(register.stderr, /请使用 root 用户运行此脚本/);
  const registerArgs = run(['register-command', 'extra'], registerEnv);
  assert.notEqual(registerArgs.status, 0);
  assert.match(registerArgs.stderr, /register-command 不接受参数/);
} else {
  // 与 test_cloud_safety.sh / test_install_guard.sh 同口径：skip 必须可见（stdout）。
  process.stdout.write('skip - register-command 自愈门禁：以 root 运行，跳过真实写入 /usr/local 的断言\n');
}

// 4. schema 0 必须拒绝并要求旧版本卸载（不迁移、不接管）。
writeState(['STATE_VERSION=0', 'PROTOCOL=reality']);
// install 在 root 检查之前先做 schema 门禁：旧状态在任何副作用或云资源之前被拒绝。
const installNonRoot = run(['install'], stateEnv);
assert.notEqual(installNonRoot.status, 0);
assert.match(installNonRoot.stderr, /旧版（schema 0）/);
assert.match(installNonRoot.stderr, /uninstall/);
for (const command of ['status', 'apply']) {
  const legacy = run([command], stateEnv);
  assert.notEqual(legacy.status, 0, `${command} 必须拒绝 schema 0`);
  assert.match(legacy.stderr, /旧版（schema 0）/);
  assert.match(legacy.stderr, /uninstall/);
}
assert.doesNotMatch(run(['status'], stateEnv).stderr, /无法识别已安装协议/);

// 4b. 只有旧 marker（无 SCHEMA）时，install/register/self-update 都必须在副作用前拒绝，
// 并且不改动现场。
rmSync(stateFile, { force: true });
const legacyMarker = 'PROFILE=cloudfront\nSTAGE=cloudfront\nSTARTED_AT=T1\n';
writeFileSync(markerFile, legacyMarker);
const legacyMarkerInstall = run(['install'], markerEnv);
assert.notEqual(legacyMarkerInstall.status, 0);
assert.match(legacyMarkerInstall.stderr, /旧版本（SCHEMA=缺失）/);
assert.equal(readFileSync(markerFile, 'utf8'), legacyMarker, '旧 marker 不得被改写');
rmSync(markerFile, { force: true });
rmSync(stateFile, { force: true });

// 5. schema 1 + 已删除协议同样拒绝。
writeState(['STATE_VERSION=1', 'PROTOCOL=cdn']);
const removedProtocol = run(['status'], stateEnv);
assert.notEqual(removedProtocol.status, 0);
assert.match(removedProtocol.stderr, /已删除的旧协议/);

// 6. 结构完整的五模式可被分类；字段不齐只给卸载通道。
writeState([
  'STATE_VERSION=1',
  'PROTOCOL=cloudfront',
  'SUBSCRIPTION_MODE=deploy',
  'TCP_ACCELERATION=off',
  'VPS_PUBLIC_IPV4=203.0.113.10',
  'CF_ZONE=example.com',
  'CLOUDFLARE_ZONE_ID=zoneid',
  'SUB_DOWNLOAD_NAME=EASY_ALL',
  'OWNER_TOKEN=token-abcdefgh',
  'ALLOWED_TOKENS=\\{\\"owner\\":\\"token-abcdefgh\\"\\}',
  'SUBSCRIPTION_CONFIG=\\{\\"allowedTokens\\":\\{\\"owner\\":\\"token-abcdefgh\\"\\}\\,\\"nodes\\":\\[\\]\\}',
  'MIHOMO_TEMPLATE_SNAPSHOT=1',
  'SCHEDULED_REBOOT_ENABLED=0',
  'SCHEDULED_REBOOT_HOUR=4',
  'CF_NODE_DOMAIN=cf.example.com',
  'CF_NODE_PREFIX=CF',
  'VLESS_UUID=11111111-2222-3333-4444-555555555555',
  'VLESS_PATH=/vless-0123456789ab',
  'SUBSCRIPTION_DOMAIN=cf.example.com',
  'CF_ORIGIN_DOMAIN=origin.example.com',
  'ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef',
  'AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE',
  'AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net',
  'AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x',
  'CDN_TRAFFIC_PROTECTION_GB=985',
]);
const complete = sourceLauncher('detect_installed_mode', stateEnv);
assert.equal(complete.status, 0, complete.stderr);
assert.equal(complete.stdout.trim(), 'cloudfront');

// 6a. 命令面：多余参数必须在任何副作用前被拒绝（用户可见的 CLI 契约）。
for (const command of ['show', 'subscription', 'apply', 'apply-cloud', 'edit-sub',
  'cdn-traffic-sync', 'renew-cert', 'status', 'update-core']) {
  const res = run([command, 'extra'], stateEnv);
  assert.notEqual(res.status, 0, `${command} 必须拒绝多余参数`);
  assert.match(res.stderr, /不接受额外参数/, `${command} 的参数门禁`);
}
const badUninstall = run(['uninstall', '--bad'], stateEnv);
assert.notEqual(badUninstall.status, 0);
assert.match(badUninstall.stderr, /uninstall 不支持参数/);

// 6a-1. hellogfw：免 root/免安装帮助、参数白名单与夹带 help 的硬拒绝。
// TMPDIR 指向不存在的目录：任何读取状态或创建运行时临时目录都会得到不同文案。
const noStateEnv = { EASY_ALL_STATE_FILE_OVERRIDE: join(tmp, 'no-hellogfw-state.env') };
for (const flag of ['-h', '--help']) {
  const res = run(['hellogfw', flag], noStateEnv);
  assert.equal(res.status, 0, `${flag} 必须免安装退出 0：${res.stderr}`);
  assert.match(res.stdout, /easy_all hellogfw \[--since <时间范围>\] \[--my-ip <IPv4> \.\.\.\]/);
  assert.match(res.stdout, /443/, '帮助必须说明固定直连端口');
  assert.doesNotMatch(res.stdout, /--port/, '帮助不得宣传 --port');
  assert.doesNotMatch(res.stderr, /尚未安装|请使用 root 用户运行/,
    `${flag} 不得经过安装或 root 门禁`);
}
// 严格形式之外的任何 help 都不得走早期出口：必须由参数门禁非零拒绝。
for (const args of [['--help', '--port', '8443'], ['--help', 'extra'], ['--since', 'x', '--help'],
  ['-h', '--since', 'x'], ['--port', '8443'], ['--since'], ['--my-ip'], ['--unknown']]) {
  const res = run(['hellogfw', ...args], { ...noStateEnv, TMPDIR: join(tmp, 'no-such-dir') });
  const label = `hellogfw ${args.join(' ')}`;
  assert.notEqual(res.status, 0, `${label} 必须被拒绝`);
  assert.doesNotMatch(res.stdout, /easy_all hellogfw \[--since/, `${label} 不得输出帮助正文`);
  assert.doesNotMatch(res.stderr, /尚未安装/, `${label} 必须早于安装状态读取`);
  assert.doesNotMatch(res.stderr, /运行时临时目录/, `${label} 不得创建运行时临时目录`);
}
const hellogfwUsage = sourceLauncher('dispatch_validate_arguments hellogfw --since "2 hours ago"', {});
assert.equal(hellogfwUsage.status, 0, hellogfwUsage.stderr);
const hellogfwMultiIp = sourceLauncher(
  'dispatch_validate_arguments hellogfw --my-ip 203.0.113.10 --my-ip 198.51.100.20', {});
assert.equal(hellogfwMultiIp.status, 0, hellogfwMultiIp.stderr);
const hellogfwMissingSince = sourceLauncher('dispatch_validate_arguments hellogfw --since', {});
assert.notEqual(hellogfwMissingSince.status, 0);
assert.match(hellogfwMissingSince.stderr, /需要一个不以 - 开头的值/);
const hellogfwDashSince = sourceLauncher('dispatch_validate_arguments hellogfw --since -x', {});
assert.notEqual(hellogfwDashSince.status, 0);
assert.match(hellogfwDashSince.stderr, /需要一个不以 - 开头的值/);
const hellogfwExtraHelp = sourceLauncher(
  'dispatch_validate_arguments hellogfw --help --port 8443', {});
assert.notEqual(hellogfwExtraHelp.status, 0);
assert.match(hellogfwExtraHelp.stderr, /hellogfw 不支持参数：--help/);
// 模式 4 的完整状态（沿用上一节的 stateFile）非 help 调用必须被模式门禁拒绝。
const hellogfwModeGate = run(['hellogfw'], stateEnv);
assert.notEqual(hellogfwModeGate.status, 0);
assert.match(hellogfwModeGate.stderr,
  /hellogfw 仅支持含直连 443 的模式（anytls \/ combined-cloudflare \/ combined-cloudfront \/ reality-self）/);
assert.doesNotMatch(hellogfwModeGate.stderr, /请使用 root 用户运行此脚本/,
  '模式门禁必须先于 root 门禁给出可操作的拒绝理由');

// 6b. 模式路由：命令面按协议分流，拒绝项不得进入实现。
const anytlsStateFile = join(tmp, 'state-anytls.env');
writeFileSync(anytlsStateFile, [
  'STATE_VERSION=1',
  'PROTOCOL=anytls',
  'TCP_ACCELERATION=off',
  'VPS_PUBLIC_IPV4=203.0.113.10',
  'CF_ZONE=example.com',
  'CLOUDFLARE_ZONE_ID=zoneid',
  'SUBSCRIPTION_MODE=deploy',
  'SUB_DOWNLOAD_NAME=EASY_ALL',
  'OWNER_TOKEN=token-abcdefgh',
  'ALLOWED_TOKENS=\\{\\"owner\\":\\"token-abcdefgh\\"\\}',
  'SUBSCRIPTION_CONFIG=\\{\\"allowedTokens\\":\\{\\"owner\\":\\"token-abcdefgh\\"\\}\\,\\"nodes\\":\\[\\]\\}',
  'MIHOMO_TEMPLATE_SNAPSHOT=1',
  'SCHEDULED_REBOOT_ENABLED=0',
  'SCHEDULED_REBOOT_HOUR=4',
  'DIRECT_DOMAIN=node.example.com',
  'DIRECT_NODE_NAME=direct',
  'ANYTLS_PASSWORD=password-abcdefgh',
  'SUBSCRIPTION_DOMAIN=sub.example.com',
  'CLOUDFLARE_ORIGIN_RULESET_ID=rs1',
  'CLOUDFLARE_ORIGIN_RULE_ID=rule1',
].join('\n') + '\n');
const anytlsEnv = { EASY_ALL_STATE_FILE_OVERRIDE: anytlsStateFile };
const anytlsMode = sourceLauncher('detect_installed_mode', anytlsEnv);
assert.equal(anytlsMode.stdout.trim(), 'anytls', anytlsMode.stderr);
const syncRejected = run(['cdn-traffic-sync'], anytlsEnv);
assert.notEqual(syncRejected.status, 0);
assert.match(syncRejected.stderr, /cdn-traffic-sync 仅适用于 CloudFront 模式/);
const applyCloudReached = run(['apply-cloud'], anytlsEnv);
assert.match(applyCloudReached.stderr, /请使用 root 用户运行此脚本/,
  'apply-cloud 在模式 1 应进入实现（root 门禁），而不是被路由拒绝');

// 6bb. 模式 3：结构完整可分类；命令面与模式 1 同样可达，但不跑 CloudFront 计量。
const combinedCfStateFile = join(tmp, 'state-combined-cloudflare.env');
writeFileSync(combinedCfStateFile, [
  'STATE_VERSION=1',
  'PROTOCOL=combined-cloudflare',
  'TCP_ACCELERATION=off',
  'VPS_PUBLIC_IPV4=203.0.113.10',
  'CF_ZONE=example.com',
  'CLOUDFLARE_ZONE_ID=zoneid',
  'SUBSCRIPTION_MODE=deploy',
  'SUB_DOWNLOAD_NAME=EASY_ALL',
  'OWNER_TOKEN=token-abcdefgh',
  'ALLOWED_TOKENS=\\{\\"owner\\":\\"token-abcdefgh\\"\\}',
  'SUBSCRIPTION_CONFIG=\\{\\"allowedTokens\\":\\{\\"owner\\":\\"token-abcdefgh\\"\\}\\,\\"nodes\\":\\[\\]\\}',
  'MIHOMO_TEMPLATE_SNAPSHOT=1',
  'SCHEDULED_REBOOT_ENABLED=0',
  'SCHEDULED_REBOOT_HOUR=4',
  'DIRECT_DOMAIN=node.example.com',
  'DIRECT_NODE_NAME=direct',
  'ANYTLS_PASSWORD=password-abcdefgh',
  'CF_NODE_DOMAIN=cf.example.com',
  'CF_NODE_PREFIX=CF',
  'VLESS_UUID=11111111-2222-4333-8444-555555555555',
  'VLESS_PATH=/vless-0123456789ab',
  'CLOUDFLARE_ORIGIN_RULESET_ID=rs1',
  'CLOUDFLARE_ORIGIN_RULE_ID=rule1',
].join('\n') + '\n');
const combinedCfEnv = { EASY_ALL_STATE_FILE_OVERRIDE: combinedCfStateFile };
const combinedCfMode = sourceLauncher('detect_installed_mode', combinedCfEnv);
assert.equal(combinedCfMode.stdout.trim(), 'combined-cloudflare', combinedCfMode.stderr);
const combinedCfSync = run(['cdn-traffic-sync'], combinedCfEnv);
assert.notEqual(combinedCfSync.status, 0);
assert.match(combinedCfSync.stderr, /cdn-traffic-sync 仅适用于 CloudFront 模式/);
const combinedCfApplyCloud = run(['apply-cloud'], combinedCfEnv);
assert.match(combinedCfApplyCloud.stderr, /请使用 root 用户运行此脚本/,
  'apply-cloud 在模式 3 应进入实现（root 门禁），而不是被路由拒绝');

// 6bc. 模式 6（Reality + CloudFront）：与模式 5 同构的字段集，订阅恒 deploy；旧 PROTOCOL=reality 仍拒绝。
const realityKeys = {
  private: Buffer.alloc(32, 0x41).toString('base64url'),
  public: Buffer.alloc(32, 0x42).toString('base64url'),
};
function realityState() {
  return [
    'STATE_VERSION=1',
    'PROTOCOL=reality-self',
    'TCP_ACCELERATION=off',
    'VPS_PUBLIC_IPV4=203.0.113.10',
    'CF_ZONE=example.com',
    'CLOUDFLARE_ZONE_ID=zoneid',
    'SUBSCRIPTION_MODE=deploy',
    'SUB_DOWNLOAD_NAME=EASY_ALL',
    'OWNER_TOKEN=token-abcdefgh',
    'ALLOWED_TOKENS=\\{\"owner\":\"token-abcdefgh\"\\}',
    'SUBSCRIPTION_CONFIG=\{\"allowedTokens\":\{\"owner\":\"token-abcdefgh\"\}\,\"nodes\":\[\]\}',
    'MIHOMO_TEMPLATE_SNAPSHOT=1',
    'SCHEDULED_REBOOT_ENABLED=0',
    'SCHEDULED_REBOOT_HOUR=4',
    'DIRECT_DOMAIN=direct.example.com',
    'DIRECT_NODE_NAME=Reality',
    'VLESS_UUID=11111111-2222-4333-8444-555555555555',
    `REALITY_PRIVATE_KEY=${realityKeys.private}`,
    `REALITY_PUBLIC_KEY=${realityKeys.public}`,
    'REALITY_SHORT_ID=0123456789abcdef',
    'CF_NODE_DOMAIN=cf.example.com',
    'CF_NODE_PREFIX=CF',
    'VLESS_PATH=/vless-0123456789ab',
    // 模式 6 与模式 5 一样复用直连域名做源站域名、节点域名做订阅域名。
    'CF_ORIGIN_DOMAIN=direct.example.com',
    'SUBSCRIPTION_DOMAIN=cf.example.com',
    'ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef',
    'CDN_TRAFFIC_PROTECTION_GB=985',
    'AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE',
    'AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net',
    'AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x',
  ];
}
const realityFile = join(tmp, 'state-reality-self.env');
writeFileSync(realityFile, realityState().join('\n') + '\n');
const realityEnv = { EASY_ALL_STATE_FILE_OVERRIDE: realityFile };
const realityMode = sourceLauncher('detect_installed_mode', realityEnv);
assert.equal(realityMode.stdout.trim(), 'reality-self', realityMode.stderr);
const realityApplyCloud = run(['apply-cloud'], realityEnv);
assert.match(realityApplyCloud.stderr, /请使用 root 用户运行此脚本/,
  'apply-cloud 在模式 6 应进入实现（root 门禁），而不是被路由拒绝');
const realitySync = run(['cdn-traffic-sync'], realityEnv);
assert.notEqual(realitySync.status, 0);
assert.doesNotMatch(realitySync.stderr, /cdn-traffic-sync 仅适用于 CloudFront 模式/,
  '模式 6 必须被 cdn-traffic-sync 放行');
assert.match(realitySync.stderr, /请使用 root 用户运行此脚本/,
  'cdn-traffic-sync 在模式 6 应进入实现（root 门禁）');
const incompleteRealityFile = join(tmp, 'state-reality-self-incomplete.env');
writeFileSync(incompleteRealityFile,
  realityState().filter((line) => !line.startsWith('REALITY_SHORT_ID=')).join('\n') + '\n');
const incompleteReality = sourceLauncher('detect_installed_mode', {
  EASY_ALL_STATE_FILE_OVERRIDE: incompleteRealityFile,
});
assert.equal(incompleteReality.stdout.trim(), 'incomplete-reality-self', incompleteReality.stderr);
// PROTOCOL=reality（旧模式）在 schema 1 下仍必须拒绝，不得被 reality-self 兼容掉。
const legacyRealityFile = join(tmp, 'state-reality-legacy.env');
writeFileSync(legacyRealityFile, 'STATE_VERSION=1\nPROTOCOL=reality\n');
assert.match(run(['status'], { EASY_ALL_STATE_FILE_OVERRIDE: legacyRealityFile }).stderr,
  /已删除的旧协议/,
  '旧的 PROTOCOL=reality 必须继续被拒绝，不得被 reality-self 兼容掉');

// 6c. 已安装（schema 1）情况下，旧 marker 同样必须在代码覆盖前拒绝 register/self-update。
const installedLegacyMarker = 'PROFILE=combined\nSTAGE=services\nSTARTED_AT=T2\n';
writeFileSync(markerFile, installedLegacyMarker);
for (const command of ['register-command', 'self-update']) {
  const legacyRun = run([command], { ...stateEnv, ...markerEnv });
  assert.notEqual(legacyRun.status, 0, `${command} 必须拒绝旧 marker`);
  assert.match(legacyRun.stderr, /旧版本（SCHEMA=缺失）/);
  assert.equal(readFileSync(markerFile, 'utf8'), installedLegacyMarker,
    `${command} 不得改写旧 marker`);
}
rmSync(markerFile, { force: true });

writeState(['STATE_VERSION=1', 'PROTOCOL=anytls', 'SUBSCRIPTION_MODE=deploy']);
const incomplete = sourceLauncher('detect_installed_mode', stateEnv);
assert.equal(incomplete.stdout.trim(), 'incomplete-anytls');
const incompleteInstall = run(['install'], { ...stateEnv, FORCE: '1' });
assert.notEqual(incompleteInstall.status, 0);
// 不完整状态在 install 入口先被 schema/root 门禁拒绝，不会进入任何安装阶段。
assert.match(incompleteInstall.stderr, /root|旧版|schema/);

// 6d. schema 1 但协议不可识别（缺失/非法）：状态损坏不能把机器锁死。
// 分类为 incomplete-unknown，卸载走协议中立的本地清理，不把猜测的协议写回状态。
writeState(['STATE_VERSION=1', 'TCP_ACCELERATION=off']);
const unknownMode = sourceLauncher('detect_installed_mode', stateEnv);
assert.equal(unknownMode.status, 0, unknownMode.stderr);
assert.equal(unknownMode.stdout.trim(), 'incomplete-unknown');
writeState(['STATE_VERSION=1', 'PROTOCOL=bogus']);
const bogusMode = sourceLauncher('detect_installed_mode', stateEnv);
assert.equal(bogusMode.status, 0, bogusMode.stderr);
assert.equal(bogusMode.stdout.trim(), 'incomplete-unknown');
writeState(['STATE_VERSION=1', 'TCP_ACCELERATION=off']);
const unknownStatus = run(['status'], stateEnv);
assert.notEqual(unknownStatus.status, 0);
assert.match(unknownStatus.stderr, /只能先执行 sudo easy_all uninstall/);
// root 下会真的删本机目录，只在非 root 时跑真实 launcher 的 uninstall 路径。
if (process.getuid() !== 0) {
  const unknownUninstall = run(['uninstall'], stateEnv);
  assert.notEqual(unknownUninstall.status, 0);
  assert.doesNotMatch(unknownUninstall.stderr, /无法识别已安装协议/,
    '协议不可识别也必须能进入卸载通道');
  assert.match(unknownUninstall.stderr, /请使用 root 用户运行此脚本/,
    '必须真的走到 uninstall_incomplete 的 root 门禁，而不是被分类拦下');
} else {
  process.stdout.write('skip - uninstall 的 root 门禁：以 root 运行，跳过真实删除本机目录的断言\n');
}

// 7. 中断安装标记：只有 schema 1 才能被 cleanup-partial 接管。
// cleanup-partial 在真实环境由 root 执行；这里直接验证它的 schema 门禁函数。
const oldMarker = sourceLauncher('launcher_marker_schema_gate 0', markerEnv);
assert.notEqual(oldMarker.status, 0);
assert.match(oldMarker.stderr, /旧版本/);
const currentMarker = sourceLauncher('launcher_marker_schema_gate 1', markerEnv);
assert.equal(currentMarker.status, 0, currentMarker.stderr);
assert.doesNotMatch(currentMarker.stderr, /旧版本/);

process.stdout.write('ok - CLI 门禁与五模式入口测试通过\n');

// 8. hellogfw 的直连模式路由：1/3/5/6 进入实现后命中 root 门禁，2 被模式门禁拒绝。
// 不走完整 launcher 是因为这里只需要验证 dispatch_profile_command 的路由分支；
// 真实 launcher 的 help 与参数门禁已在上文验证。
function dispatchHellogfw(profile) {
  return sourceLauncher([
    `module=$(profile_file ${profile})`,
    'source "$module"',
    `dispatch_profile_command ${profile} hellogfw`,
  ].join('\n'), {});
}
const cloudflareRoute = dispatchHellogfw('cloudflare');
assert.notEqual(cloudflareRoute.status, 0);
assert.match(cloudflareRoute.stderr,
  /hellogfw 仅支持含直连 443 的模式（anytls \/ combined-cloudflare \/ combined-cloudfront \/ reality-self）/);
for (const profile of ['anytls', 'combined-cloudflare', 'combined-cloudfront', 'reality-self']) {
  if (process.getuid() !== 0) {
    const res = dispatchHellogfw(profile);
    assert.notEqual(res.status, 0, `${profile} 的非 help 调用必须非零`);
    assert.match(res.stderr, /请使用 root 用户运行此脚本/,
      `${profile} 的 hellogfw 必须真的走到 require_root`);
  } else {
    process.stdout.write(`skip - ${profile} 的 hellogfw root 门禁：以 root 运行，跳过非 root 断言\n`);
  }
}

process.stdout.write('ok - hellogfw 帮助、参数与模式路由测试通过\n');
