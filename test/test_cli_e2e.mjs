import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, readFileSync, unlinkSync, chmodSync, existsSync, statSync, mkdirSync, readdirSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const easyAll = join(root, 'easy_all');
const bootstrap = join(root, 'bootstrap.sh');

// 所有被测命令都在隔离路径下运行：加载 profile 会注册 EXIT trap，其中的
// recover_pending_service_policy 默认要写 /usr/sbin/policy-rc.d 与 /var/lib/easy_all，
// 在 root 下跑测试时不能让测试碰到宿主真实文件。
const isolationRoot = join(tmpdir(), `easy-all-cli-isolation-${process.pid}`);
const isolation = {
    EASY_ALL_POLICY_STATE_DIR_OVERRIDE: join(isolationRoot, 'policy-state'),
    EASY_ALL_POLICY_RC_OVERRIDE: join(isolationRoot, 'policy-rc.d'),
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE: join(isolationRoot, 'runtime-write.lock'),
};

function run(cmd, args = [], env = {}) {
    return spawnSync(cmd, args, {
        encoding: 'utf8',
        env: { ...process.env, ...isolation, ...env },
    });
}

// 1. CLI 帮助与用法（核心路径）
for (const arg of ['help', '--help', '-h']) {
    const res = run(easyAll, [arg]);
    assert.equal(res.status, 0, `easy_all ${arg} should exit with 0`);
    assert.ok(res.stdout.includes('用法: easy_all [命令]'), 'Help should show usage');
    assert.ok(res.stdout.includes('Reality'), 'Help should list Reality mode');
    assert.ok(res.stdout.includes('2 纯 CloudFront'), 'Help should list the CloudFront-only mode');
    assert.ok(res.stdout.includes('3 纯 CloudFlare'), 'Help should list the Cloudflare-only mode');
    assert.ok(res.stdout.includes('4 直连+CloudFront'), 'Help should list the direct+CloudFront mode');
    assert.ok(res.stdout.includes('5 直连+CloudFlare'), 'Help should list the direct+Cloudflare mode');
    assert.ok(res.stdout.includes('cleanup-partial'), 'Help should list cleanup-partial');
}

// 2. purge-cloudflare 帮助
const purgeCfHelp = run(easyAll, ['purge-cloudflare', '--help']);
assert.equal(purgeCfHelp.status, 0, purgeCfHelp.stderr);
assert.ok(purgeCfHelp.stdout.includes('purge-cloudflare'), 'purge-cloudflare help should show usage');

// 2.5 中断安装自救命令：非 root 直接拒绝，不触碰任何文件
if (process.getuid && process.getuid() !== 0) {
    const cleanupPartial = run(easyAll, ['cleanup-partial'], {
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: join(tmpdir(), 'nonexistent-progress.env'),
    });
    assert.equal(cleanupPartial.status, 1, 'cleanup-partial must refuse non-root');
    assert.ok(
        cleanupPartial.stderr.includes('请使用 root 用户运行此脚本'),
        'cleanup-partial should require root',
    );
}

// 2.7 安装入口：install 不接受参数
const installWithArgs = run(easyAll, ['install', 'unexpected-arg']);
assert.equal(installWithArgs.status, 1, 'install with args must fail');
assert.ok(
    installWithArgs.stderr.includes('install 不接受参数'),
    `install with args rejected: ${installWithArgs.stderr}`,
);

// 2.6 cleanup-partial：只接受无参数，且缺进度标记时不会动任何路径
const cleanupHelp = run(easyAll, ['cleanup-partial', '--help']);
assert.equal(cleanupHelp.status, 0, cleanupHelp.stderr);
assert.ok(cleanupHelp.stdout.includes('cleanup-partial'), 'cleanup-partial help should show usage');

const cleanupIsolation = {
    FORCE: '0',
    EASY_ALL_STATE_FILE_OVERRIDE: join(tmpdir(), `no-state-${Date.now()}.env`),
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: join(tmpdir(), `no-progress-${Date.now()}.env`),
};
const cleanupWithArgs = run(easyAll, ['cleanup-partial', 'extra-arg'], cleanupIsolation);
assert.equal(cleanupWithArgs.status, 1, 'cleanup-partial must reject extra arguments');
assert.ok(
    cleanupWithArgs.stderr.includes('用法：easy_all cleanup-partial'),
    cleanupWithArgs.stderr,
);
const cleanupNoMarker = run(easyAll, ['cleanup-partial'], cleanupIsolation);
assert.equal(cleanupNoMarker.status, 1, 'cleanup-partial must not succeed without a marker');
if (process.getuid && process.getuid() === 0) {
    assert.ok(
        cleanupNoMarker.stderr.includes('未检测到安装进度标记'),
        cleanupNoMarker.stderr,
    );
} else {
    assert.ok(
        cleanupNoMarker.stderr.includes('请使用 root 用户运行此脚本'),
        cleanupNoMarker.stderr,
    );
}

// 3. 未安装状态调用命令（关键失败场景）
const uninstalledRes = run(easyAll, ['status'], {
    EASY_ALL_STATE_FILE_OVERRIDE: join(tmpdir(), 'nonexistent-easy-all-state.env'),
});
assert.equal(uninstalledRes.status, 1, 'Status without installation should exit 1');
assert.ok(
    uninstalledRes.stderr.includes('尚未安装') || uninstalledRes.stdout.includes('尚未安装'),
    'Should notify user that easy_all is not installed'
);

// 4. 非交互环境调用 bootstrap.sh 守卫（关键失败场景）
const bootstrapRes = run('bash', [bootstrap], { stdio: 'pipe' });
assert.equal(bootstrapRes.status, 1, 'bootstrap.sh in non-interactive shell must exit 1');
assert.ok(
    bootstrapRes.stderr.includes('交互终端') || bootstrapRes.stdout.includes('交互终端'),
    'bootstrap.sh should warn against curl | bash without a tty'
);

// 5. 用户视角下的模式专属命令边界路由（核心路径与关键失败校验）
const stateFile = join(tmpdir(), `easy-all-test-state-${Date.now()}.env`);

const cloudfrontState = [
    'STATE_VERSION="0"',
    'PROTOCOL="cloudfront"',
    'CDN_PROVIDER="aws"',
    'VPS_PUBLIC_IPV4="198.51.100.10"',
    'CF_ZONE="example.com"',
    'CLOUDFLARE_ZONE_ID="zone-123"',
    'CF_ORIGIN_DOMAIN="origin.example.com"',
    'CF_NODE_DOMAIN="cf.example.com"',
    'SUBSCRIPTION_DOMAIN="sub.example.com"',
    'SUB_DOWNLOAD_NAME="EASYALL"',
    'OWNER_TOKEN="cdnwq-rtbke-3182"',
    `ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'`,
    `SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'`,
    'VLESS_UUID="11111111-2222-4111-8111-111111111111"',
    'CF_NODE_PREFIX="AWS"',
    'XHTTP_PATH="/xhttp-abcdef123456"',
    'ORIGIN_HEADER_SECRET="test-origin-header-secret-1234"',
    'AWS_CLOUDFRONT_DISTRIBUTION_ID="EDFDIST123"',
    'AWS_CLOUDFRONT_DOMAIN="d111.cloudfront.net"',
    'AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:123456789012:certificate/x"',
    'CDN_TRAFFIC_PROTECTION_GB="985"',
    ''
].join('\n');

const combinedCloudfrontState = [
    'STATE_VERSION="0"',
    'PROTOCOL="combined-cloudfront"',
    'CDN_PROVIDER="aws"',
    'VPS_PUBLIC_IPV4="198.51.100.10"',
    'CF_ZONE="example.com"',
    'CLOUDFLARE_ZONE_ID="zone-123"',
    'CF_ORIGIN_DOMAIN="origin.example.com"',
    'CF_NODE_DOMAIN="cf.example.com"',
    'SUBSCRIPTION_DOMAIN="sub.example.com"',
    'SUB_DOWNLOAD_NAME="EASYALL"',
    'OWNER_TOKEN="cdnwq-rtbke-3182"',
    `ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'`,
    `SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'`,
    'VLESS_UUID="11111111-2222-4111-8111-111111111111"',
    'CF_NODE_PREFIX="AWS"',
    'XHTTP_PATH="/xhttp-abcdef123456"',
    'ORIGIN_HEADER_SECRET="test-origin-header-secret-1234"',
    'AWS_CLOUDFRONT_DISTRIBUTION_ID="EDFDIST123"',
    'AWS_CLOUDFRONT_DOMAIN="d111.cloudfront.net"',
    'AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:123456789012:certificate/x"',
    'CDN_TRAFFIC_PROTECTION_GB="985"',
    'DIRECT_DOMAIN="node.example.com"',
    'DIRECT_NODE_NAME="direct-node"',
    'REALITY_TARGET="swdist.apple.com:443"',
    'REALITY_PRIVATE_KEY="test-private"',
    'REALITY_PUBLIC_KEY="test-public"',
    'REALITY_SHORT_ID="0123456789abcdef"',
    ''
].join('\n');

// 结构必需字段清单来自 lib/cloudfront-state.sh；这里按协议写出期望，逐字段删除验证门禁。
const cloudfrontRequiredFields = [
    'PROTOCOL', 'CDN_PROVIDER', 'VPS_PUBLIC_IPV4', 'CF_ZONE', 'CLOUDFLARE_ZONE_ID',
    'CF_ORIGIN_DOMAIN', 'CF_NODE_DOMAIN', 'SUBSCRIPTION_DOMAIN', 'SUB_DOWNLOAD_NAME',
    'OWNER_TOKEN', 'ALLOWED_TOKENS', 'SUBSCRIPTION_CONFIG', 'VLESS_UUID', 'CF_NODE_PREFIX',
    'XHTTP_PATH', 'ORIGIN_HEADER_SECRET', 'AWS_CLOUDFRONT_DISTRIBUTION_ID',
    'AWS_CLOUDFRONT_DOMAIN', 'AWS_ACM_CERTIFICATE_ARN', 'CDN_TRAFFIC_PROTECTION_GB',
];
const combinedDirectFields = [
    'DIRECT_DOMAIN', 'DIRECT_NODE_NAME', 'REALITY_TARGET',
    'REALITY_PRIVATE_KEY', 'REALITY_PUBLIC_KEY', 'REALITY_SHORT_ID',
];

const cloudflareCommonFields = [
    'PROTOCOL', 'CDN_PROVIDER', 'VPS_PUBLIC_IPV4', 'CF_ZONE', 'CLOUDFLARE_ZONE_ID',
    'CF_NODE_DOMAIN', 'SUB_DOWNLOAD_NAME', 'OWNER_TOKEN', 'ALLOWED_TOKENS',
    'SUBSCRIPTION_CONFIG', 'VLESS_UUID', 'CF_NODE_PREFIX', 'XHTTP_PATH',
    'CLOUDFLARE_ORIGIN_CERT_ID', 'CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON',
];

const cloudflareState = [
    'STATE_VERSION="0"',
    'PROTOCOL="cloudflare"',
    'CDN_PROVIDER="cloudflare"',
    'TCP_ACCELERATION="skyline"',
    'VPS_PUBLIC_IPV4="198.51.100.10"',
    'CF_ZONE="example.com"',
    'CLOUDFLARE_ZONE_ID="zone-123"',
    'CF_NODE_DOMAIN="cf.example.com"',
    'SUB_DOWNLOAD_NAME="EASYALL"',
    'OWNER_TOKEN="cdnwq-rtbke-3182"',
    `ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'`,
    `SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'`,
    'VLESS_UUID="11111111-2222-4111-8111-111111111111"',
    'CF_NODE_PREFIX="CF"',
    'XHTTP_PATH="/xhttp-abcdef123456"',
    'CLOUDFLARE_ORIGIN_CERT_ID="cert-123"',
    'CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2039-01-01T00:00:00Z"',
    ''
].join('\n');

const combinedCloudflareState = [
    ...cloudflareState.split('\n').slice(0, -1),
    'PROTOCOL="combined-cloudflare"',
    'DIRECT_DOMAIN="node.example.com"',
    'DIRECT_NODE_NAME="direct-node"',
    'REALITY_TARGET="swdist.apple.com:443"',
    'REALITY_PRIVATE_KEY="test-private"',
    'REALITY_PUBLIC_KEY="test-public"',
    'REALITY_SHORT_ID="0123456789abcdef"',
    ''
].join('\n');

function stateWithoutField(stateText, field) {
    const lines = stateText.split('\n');
    assert.ok(lines.some((line) => line.startsWith(`${field}=`)), `fixture must define ${field}`);
    return lines.filter((line) => !line.startsWith(`${field}=`)).join('\n');
}

try {
    // 旧纯 Cloudflare 状态：明确拒绝，不再映射到任何 Profile。
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="cdn"\n');
    for (const command of ['status', 'apply', 'refresh-cdn-ips']) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected for legacy cdn`);
        assert.ok(
            res.stderr.includes('检测到旧 Cloudflare CDN 安装'),
            `${command}: ${res.stderr}`,
        );
    }
    // 卸载入口可达：非法参数在动任何路径前被拒绝；非 root 只得到 root 提示。
    const legacyUninstall = run(easyAll, ['uninstall', '--bogus'], {
        EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
    });
    assert.equal(legacyUninstall.status, 1, 'legacy uninstall must be reachable but reject bad args');
    assert.ok(
        legacyUninstall.stderr.includes('uninstall 不支持参数') ||
            legacyUninstall.stderr.includes('请使用 root 用户运行此脚本'),
        legacyUninstall.stderr,
    );

    // 不完整的新 CloudFront 状态：拒绝应用，只保留卸载通道。
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="cloudfront"\nCDN_PROVIDER="aws"\n');
    for (const command of ['status', 'apply', 'apply-cloud', 'renew-cert']) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected for incomplete cloudfront`);
        assert.ok(
            res.stderr.includes('CloudFront 状态不完整'),
            `${command}: ${res.stderr}`,
        );
    }
    const incompleteUninstall = run(easyAll, ['uninstall', '--bogus'], {
        EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
    });
    assert.equal(incompleteUninstall.status, 1);
    assert.ok(
        incompleteUninstall.stderr.includes('uninstall 不支持参数') ||
            incompleteUninstall.stderr.includes('请使用 root 用户运行此脚本'),
        incompleteUninstall.stderr,
    );

    // 逐字段删除：结构不完整必须拒绝所有应用命令且零写入（状态文件逐字节不变）。
    const partialFixtures = [
        { protocol: 'cloudfront', state: cloudfrontState, fields: cloudfrontRequiredFields },
        {
            protocol: 'combined-cloudfront',
            state: combinedCloudfrontState,
            fields: [...cloudfrontRequiredFields, ...combinedDirectFields],
        },
    ];
    const sampleFields = new Set(['VPS_PUBLIC_IPV4', 'CF_NODE_PREFIX', 'OWNER_TOKEN', 'DIRECT_DOMAIN']);
    for (const fixture of partialFixtures) {
        for (const field of fixture.fields) {
            // PROTOCOL 是分类依据本身：删掉后属于「未知协议」，由另外的用例覆盖。
            if (field === 'PROTOCOL') continue;
            const partialState = stateWithoutField(fixture.state, field);
            writeFileSync(stateFile, partialState);
            const commands = sampleFields.has(field)
                ? ['apply', 'apply-cloud', 'cdn-traffic-sync']
                : ['apply'];
            for (const command of commands) {
                const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
                assert.equal(
                    res.status,
                    1,
                    `incomplete ${fixture.protocol} without ${field} must reject ${command}: ${res.stderr}`,
                );
                assert.ok(
                    res.stderr.includes('CloudFront 状态不完整'),
                    `${fixture.protocol} without ${field}: ${res.stderr}`,
                );
            }
            assert.equal(
                readFileSync(stateFile, 'utf8'),
                partialState,
                `rejected ${fixture.protocol} without ${field} must not write the state file`,
            );
        }
    }

    // 新增 Cloudflare 橙云链路（模式 3 / 5）：协议分类与字段门禁。
    // 橙云状态不含 AWS 与 985GB 熔断字段，不得因此被判为不完整。
    writeFileSync(stateFile, cloudflareState);
    for (const [command, args, message] of [
        ['reality-target', ['example.com:443'], 'reality-target 仅适用于 Reality 与直连+CDN 模式'],
        ['cdn-traffic-sync', [], 'cdn-traffic-sync 仅适用于 CloudFront 模式'],
        ['rotate-dynamic-ports', [], '仅适用于 Reality 模式'],
    ]) {
        const res = run(easyAll, [command, ...args], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected in cloudflare mode`);
        assert.ok(res.stderr.includes(message), `${command}: ${res.stderr}`);
        assert.ok(
            !res.stderr.includes('状态不完整'),
            `complete cloudflare state must not be classified incomplete: ${res.stderr}`,
        );
    }
    // 模式 5：同一命令同样被 CloudFront-only 门禁拒绝，证明协议未被当成 CloudFront。
    writeFileSync(stateFile, combinedCloudflareState);
    {
        const res = run(easyAll, ['cdn-traffic-sync'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, 'combined-cloudflare must reject cdn-traffic-sync');
        assert.ok(res.stderr.includes('cdn-traffic-sync 仅适用于 CloudFront 模式'), res.stderr);
        assert.ok(!res.stderr.includes('状态不完整'), res.stderr);
    }
    // 不完整 Cloudflare 状态：拒绝所有应用命令，只保留卸载通道。
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="cloudflare"\nCDN_PROVIDER="cloudflare"\n');
    for (const command of ['status', 'apply', 'apply-cloud', 'renew-cert']) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected for incomplete cloudflare`);
        assert.ok(res.stderr.includes('Cloudflare 状态不完整'), `${command}: ${res.stderr}`);
    }
    // CDN_PROVIDER 必须是 cloudflare：写成 aws 时判为不完整，而不是按 CloudFront 接管。
    writeFileSync(stateFile, cloudflareState.replace('CDN_PROVIDER="cloudflare"', 'CDN_PROVIDER="aws"'));
    {
        const res = run(easyAll, ['apply'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, 'cloudflare state with aws provider must be rejected');
        assert.ok(res.stderr.includes('Cloudflare 状态不完整'), res.stderr);
    }
    // 逐字段删除：两个新协议的结构完整性逐项生效，且拒绝时零写入。
    const cloudflareFixtures = [
        { protocol: 'cloudflare', state: cloudflareState, fields: cloudflareCommonFields },
        {
            protocol: 'combined-cloudflare',
            state: combinedCloudflareState,
            fields: [...cloudflareCommonFields, ...combinedDirectFields],
        },
    ];
    for (const fixture of cloudflareFixtures) {
        for (const field of fixture.fields) {
            if (field === 'PROTOCOL') continue;
            const partialState = stateWithoutField(fixture.state, field);
            writeFileSync(stateFile, partialState);
            const res = run(easyAll, ['apply'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
            assert.equal(
                res.status,
                1,
                `incomplete ${fixture.protocol} without ${field} must reject apply: ${res.stderr}`,
            );
            assert.ok(
                res.stderr.includes('Cloudflare 状态不完整'),
                `${fixture.protocol} without ${field}: ${res.stderr}`,
            );
            assert.equal(
                readFileSync(stateFile, 'utf8'),
                partialState,
                `rejected ${fixture.protocol} without ${field} must not write the state file`,
            );
        }
    }
    // 模式 4 的不完整状态必须仍能走“仅本机卸载”通道（否则存量安装无法自救）。
    {
        const partialMode4 = stateWithoutField(combinedCloudfrontState, 'DIRECT_NODE_NAME');
        writeFileSync(stateFile, partialMode4);
        for (const command of ['status', 'apply']) {
            const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
            assert.equal(res.status, 1, `${command} must be rejected for incomplete mode 4`);
            assert.ok(res.stderr.includes('CloudFront 状态不完整'), `${command}: ${res.stderr}`);
        }
        const uninstall = run(easyAll, ['uninstall', '--bogus'], {
            EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
        });
        assert.equal(uninstall.status, 1, 'incomplete mode 4 uninstall must reject bad args');
        assert.ok(
            uninstall.stderr.includes('uninstall 不支持参数') ||
                uninstall.stderr.includes('请使用 root 用户运行此脚本'),
            `incomplete mode 4 uninstall must be reachable: ${uninstall.stderr}`,
        );
        assert.ok(
            !uninstall.stderr.includes('不支持的安装模式'),
            `incomplete mode 4 must not be rejected as unknown mode: ${uninstall.stderr}`,
        );
    }
    // 模式 3 不得要求直连字段：去掉 DIRECT_* 后仍应识别为完整状态（通过 CloudFront-only 门禁）。
    {
        const mode3 = cloudflareState;
        assert.ok(!mode3.includes('DIRECT_DOMAIN='), 'mode 3 fixture must not define direct fields');
        writeFileSync(stateFile, mode3);
        const res = run(easyAll, ['cdn-traffic-sync'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.ok(res.stderr.includes('cdn-traffic-sync 仅适用于 CloudFront 模式'), res.stderr);
    }
    // 旧橙云 combined 状态即便字段齐全也仍只允许卸载。
    writeFileSync(stateFile, combinedCloudflareState
        .replace('PROTOCOL="combined-cloudflare"', 'PROTOCOL="combined"')
        .replace('CDN_PROVIDER="cloudflare"', 'CDN_PROVIDER="cloudflare"'));
    for (const command of ['apply', 'status', 'apply-cloud']) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected for legacy combined`);
        assert.ok(res.stderr.includes('检测到旧 Cloudflare CDN 安装'), `${command}: ${res.stderr}`);
    }

    // 完整的新 CloudFront 状态：模式专属命令门禁。
    writeFileSync(stateFile, cloudfrontState);
    const rejectedInCloudFront = [
        ['reality-target', ['example.com:443'], '仅适用于 Reality 与直连+CDN 模式'],
        ['rotate-dynamic-ports', [], '仅适用于 Reality 模式'],
    ];
    for (const [command, args, message] of rejectedInCloudFront) {
        const res = run(easyAll, [command, ...args], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected in cloudfront mode`);
        assert.ok(res.stderr.includes(message), `${command}: ${res.stderr}`);
    }
    // 删除的命令必须点名「未知命令」，而不是只打印 usage。
    for (const removed of ['refresh-cdn-ips', 'refresh-cdn-ips-extra']) {
        const removedRes = run(easyAll, [removed], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(removedRes.status, 1, `${removed} must no longer exist`);
        assert.ok(
            removedRes.stderr.includes(`未知命令：${removed}`),
            `${removed}: ${removedRes.stderr}`,
        );
        assert.ok(
            !removedRes.stdout.includes('用法: easy_all [命令]'),
            `${removed} must not fall back to usage printing`,
        );
    }

    // 参数门禁：不支持参数的命令在副作用前非零拒绝，state 与安装目录零写入。
    const installDir = '/usr/local/lib/easy_all';
    const installDirBefore = existsSync(installDir) ? statSync(installDir).mtimeMs : null;
    const stateBefore = readFileSync(stateFile, 'utf8');
    const noArgCommands = [
        'install', 'show', 'subscription', 'apply', 'edit-sub', 'status',
        'cdn-traffic-sync', 'register-command', 'verify-release', 'renew-cert',
        'apply-cloud',
    ];
    for (const command of noArgCommands) {
        const res = run(easyAll, [command, 'extra'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} with extra args must fail`);
        assert.ok(
            res.stderr.includes(`${command} 不接受`) || res.stderr.includes('不接受参数'),
            `${command} with extra args: ${res.stderr}`,
        );
        assert.equal(
            readFileSync(stateFile, 'utf8'),
            stateBefore,
            `${command} with extra args must not write the state file`,
        );
    }
    // cleanup-partial 只接受无参（-h/--help 例外），多余参数在动任何路径前被拒绝。
    {
        const res = run(easyAll, ['cleanup-partial', 'extra'], {
            EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
            EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: join(tmpdir(), `no-progress-${Date.now()}.env`),
            FORCE: '0',
        });
        assert.equal(res.status, 1, 'cleanup-partial with extra args must fail');
        assert.ok(res.stderr.includes('用法：easy_all cleanup-partial'), res.stderr);
    }
    // uninstall 只接受可选的 --purge-cloud；多余参数同样在副作用前拒绝。
    const uninstallArgs = [
        ['extra'],
        ['--purge-cloud', 'extra'],
        ['--bogus'],
    ];
    for (const args of uninstallArgs) {
        const res = run(easyAll, ['uninstall', ...args], {
            EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
            FORCE: '0',
        });
        assert.equal(res.status, 1, `uninstall ${args.join(' ')} must fail`);
        assert.ok(res.stderr.includes('uninstall 不支持参数'), res.stderr);
        assert.equal(
            readFileSync(stateFile, 'utf8'),
            stateBefore,
            `uninstall ${args.join(' ')} must not write the state file`,
        );
    }
    assert.equal(
        existsSync(installDir) ? statSync(installDir).mtimeMs : null,
        installDirBefore,
        'rejected commands must not touch the install directory',
    );
    // 合法参数形态越过门禁：无参与 --purge-cloud 都按原语义继续（非 root/非交互在这里停止）。
    for (const args of [[], ['--purge-cloud']]) {
        const res = run(easyAll, ['uninstall', ...args], {
            EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
            FORCE: '0',
        });
        assert.equal(res.status, 1, `uninstall ${args.join(' ')} must stop before deleting anything`);
        assert.ok(
            !res.stderr.includes('uninstall 不支持参数'),
            `uninstall ${args.join(' ')} must pass the argument gate: ${res.stderr}`,
        );
        assert.equal(readFileSync(stateFile, 'utf8'), stateBefore);
    }
    const applyCloudArgs = run(easyAll, ['apply-cloud', 'extra'], {
        EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
    });
    assert.equal(applyCloudArgs.status, 1);
    assert.ok(applyCloudArgs.stderr.includes('apply-cloud 不接受额外参数'), applyCloudArgs.stderr);
    const syncArgs = run(easyAll, ['cdn-traffic-sync', 'extra'], {
        EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
    });
    assert.equal(syncArgs.status, 1);
    assert.ok(syncArgs.stderr.includes('cdn-traffic-sync 不接受额外参数'), syncArgs.stderr);
    // cdn-traffic-sync 必须路由到真实实现，而不是落入未知命令。
    const syncRes = run(easyAll, ['cdn-traffic-sync'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(syncRes.status, 1, 'sync without usage must fail');
    assert.ok(!syncRes.stdout.includes('用法: easy_all [命令]'), syncRes.stdout);

    // 完整状态（包括模式 3 的直连字段）必须越过不完整门禁，进入正常的严格路径。
    writeFileSync(stateFile, combinedCloudfrontState);
    for (const command of ['reality-target', 'apply']) {
        const res = run(easyAll, [command, 'example.com:443'], {
            EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
        });
        assert.ok(
            !res.stderr.includes('CloudFront 状态不完整'),
            `complete combined-cloudfront must pass the gate for ${command}: ${res.stderr}`,
        );
        assert.ok(
            !res.stderr.includes('检测到旧 Cloudflare CDN 安装'),
            `complete combined-cloudfront must not be treated as legacy for ${command}: ${res.stderr}`,
        );
    }

    // 旧 Cloudflare 链路的模式 3 状态：与新 cdn 一样只能卸载后重装。
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="combined"\n');
    for (const command of ['status', 'apply', 'rotate-dynamic-ports']) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected for legacy combined`);
        assert.ok(res.stderr.includes('检测到旧 Cloudflare CDN 安装'), `${command}: ${res.stderr}`);
        assert.ok(res.stderr.includes('sudo easy_all uninstall'), `${command}: ${res.stderr}`);
    }
    const combinedUninstall = run(easyAll, ['uninstall', '--bogus'], {
        EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
    });
    assert.equal(combinedUninstall.status, 1, 'legacy combined uninstall must be reachable');
    assert.ok(
        combinedUninstall.stderr.includes('uninstall 不支持参数') ||
            combinedUninstall.stderr.includes('请使用 root 用户运行此脚本'),
        combinedUninstall.stderr,
    );

    // 不认识的状态协议：明确拒绝并退出
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="unknown"\n');
    const unknownRes = run(easyAll, ['status'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(unknownRes.status, 1);
    assert.ok(unknownRes.stderr.includes('无法识别已安装协议'), unknownRes.stderr);
} finally {
    try { unlinkSync(stateFile); } catch {}
}


// 6. 正常卸载必须真正跑完（不只是参数门禁）：用真实 CLI 进程 + 隔离路径 + 系统命令桩。
// 这些用例把 `id -u` 桩成 0 以越过 root 门禁，但进程本身仍是非 root：
// 若漏配了某个隔离路径，真实写入会因权限失败并让断言失败，而不会破坏测试机。
const sandboxRoot = join(tmpdir(), `easy-all-cli-sandbox-${process.pid}`);
const shimPath = join(sandboxRoot, 'shim.sh');
const callLog = join(sandboxRoot, 'system-calls.log');
const sandbox = {
    state: join(sandboxRoot, 'state'),
    web: join(sandboxRoot, 'web'),
    lib: join(sandboxRoot, 'lib'),
    runtime: join(sandboxRoot, 'runtime'),
    systemd: join(sandboxRoot, 'systemd'),
    certbot: join(sandboxRoot, 'certbot'),
    le: join(sandboxRoot, 'le', 'live', 'easy_all_origin'),
    policy: join(sandboxRoot, 'policy'),
    progress: join(sandboxRoot, 'progress.env'),
    ssh: join(sandboxRoot, 'ssh', 'ports.conf'),
    ufw: join(sandboxRoot, 'ufw', 'default'),
    ipv6: join(sandboxRoot, 'sysctl', 'ipv6.conf'),
    nginxDefault: join(sandboxRoot, 'nginx', 'default'),
    nginx: join(sandboxRoot, 'nginx', 'easy_all.conf'),
    lock: join(sandboxRoot, 'runtime-write.lock'),
    xray: join(sandboxRoot, 'bin', 'xray'),
    usage: join(sandboxRoot, 'state', 'cdn-traffic-usage.json'),
    stateFile: join(sandboxRoot, 'state', 'state.env'),
};
const shimLines = [
    '# 注入到新 bash 进程：readonly 允许环境变量优先（隔离路径），并提供系统命令桩。',
    'readonly() {',
    '    local arg name val',
    '    for arg in "$@"; do',
    '        [[ "${arg}" == -* ]] && continue',
    '        if [[ "${arg}" == *=* ]]; then',
    '            name=${arg%%=*}',
    '            val=${arg#*=}',
    '            [[ -n "${!name+x}" ]] || printf -v "${name}" "%s" "${val}"',
    '        fi',
    '    done',
    '}',
    'id() { if [[ "${1:-}" == "-u" ]]; then printf "0\\n"; return 0; fi; command id "$@"; }',
    'systemctl() { printf "systemctl %s\\n" "$*" >>"${FAKE_CALL_LOG:?}"; return 0; }',
    'nginx() { printf "nginx %s\\n" "$*" >>"${FAKE_CALL_LOG:?}"; return 0; }',
    'ufw() { printf "ufw %s\\n" "$*" >>"${FAKE_CALL_LOG:?}"; return 0; }',
    'sysctl() { return 0; }',
    'flock() { return 0; }',
    'crontab() { printf "crontab %s\\n" "$*" >>"${FAKE_CALL_LOG:?}"; [[ "${1:-}" == "-l" ]] && printf "0 3 * * * /usr/local/bin/user-backup\\n"; return 0; }',
    'ss() {',
    '    case "$*" in',
    '    *":22"*|*-ltnp*|-ltn*) printf \'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=42,fd=3))\\n\' ;;',
    '    esac',
    '    return 0',
    '}',
    'sshd() { case "${1:-}" in -T) printf "listenaddress 0.0.0.0:22\\nport 22\\n" ;; *) return 0 ;; esac; }',
    'install() {',
    '    local args=()',
    '    while [[ $# -gt 0 ]]; do',
    '        case "$1" in',
    '        -o | -g) shift 2 ;;',
    '        *) args+=("$1"); shift ;;',
    '        esac',
    '    done',
    '    command install "${args[@]}"',
    '}',
    '# 本机订阅验收的桩：从已发布产物回放 HTTP 响应，不改变被测函数的判定逻辑。',
    'curl() {',
    '    local arg last=""',
    '    for arg in "$@"; do last=$arg; done',
    '    if [[ " $* " == *" %{http_code} "* ]]; then',
    '        case "${last}" in',
    '        *"/easy_all-health") printf "404" ;;',
    '        *"/subscribe"*) printf "403" ;;',
    '        *) printf "404" ;;',
    '        esac',
    '        return 0',
    '    fi',
    '    case "${last}" in',
    '    *"/easy_all-health") printf "easy_all ok" ;;',
    '    *"flag=clash"*) command cat "${SANDBOX_SUBSCRIPTIONS}/mihomo.yaml" ;;',
    '    *"/subscribe"*) command cat "${SANDBOX_SUBSCRIPTIONS}/base64.txt" ;;',
    '    *) printf "" ;;',
    '    esac',
    '}',
];
const sandboxCloudfrontState = (subscriptionConfig) => [
    'STATE_VERSION="0"',
    'PROTOCOL="cloudfront"',
    'CDN_PROVIDER="aws"',
    'VPS_PUBLIC_IPV4="198.51.100.10"',
    'CF_ZONE="example.com"',
    'CLOUDFLARE_ZONE_ID="zone-123"',
    'CF_ORIGIN_DOMAIN="origin.example.com"',
    'CF_NODE_DOMAIN="cf.example.com"',
    'SUBSCRIPTION_DOMAIN="sub.example.com"',
    'SUB_DOWNLOAD_NAME="EASYALL"',
    'OWNER_TOKEN="cdnwq-rtbke-3182"',
    `ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'`,
    `SUBSCRIPTION_CONFIG='${subscriptionConfig}'`,
    'VLESS_UUID="11111111-2222-4111-8111-111111111111"',
    'CF_NODE_PREFIX="AWS"',
    'XHTTP_PATH="/xhttp-abcdef123456"',
    'ORIGIN_HEADER_SECRET="test-origin-header-secret-1234"',
    'AWS_CLOUDFRONT_DISTRIBUTION_ID="EDFDIST123"',
    'AWS_CLOUDFRONT_DOMAIN="d111.cloudfront.net"',
    'AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:123456789012:certificate/x"',
    'CDN_TRAFFIC_PROTECTION_GB="985"',
    '',
].join('\n');
const sandboxEnv = (extra = {}) => ({
    ...isolation,
    BASH_ENV: shimPath,
    FAKE_CALL_LOG: callLog,
    SANDBOX_SUBSCRIPTIONS: join(sandbox.web, 'subscriptions'),
    STATE_DIR: sandbox.state,
    STATE_FILE: sandbox.stateFile,
    BACKUP_DIR: join(sandbox.state, 'backups'),
    CERT_DIR: join(sandbox.state, 'certs'),
    CERT_FILE: join(sandbox.state, 'certs', 'fullchain.pem'),
    KEY_FILE: join(sandbox.state, 'certs', 'private.key'),
    WEB_ROOT: sandbox.web,
    SUBSCRIPTION_DIR: join(sandbox.web, 'subscriptions'),
    COMMAND_INSTALL_DIR: sandbox.lib,
    XRAY_DIR: join(sandbox.state, 'xray'),
    XRAY_BIN: sandbox.xray,
    XRAY_CONFIG: join(sandbox.state, 'xray', 'config.json'),
    XRAY_SERVICE_FILE: join(sandbox.systemd, 'easy_all-xray.service'),
    NGINX_CONFIG: sandbox.nginx,
    UFW_DEFAULT_CONFIG: sandbox.ufw,
    IPV6_SYSCTL_CONF: sandbox.ipv6,
    EASY_ALL_SSH_PORT_CONFIG: sandbox.ssh,
    EASY_ALL_GUARD_NGINX_DEFAULT_SITE: sandbox.nginxDefault,
    CDN_TRAFFIC_GUARD_SERVICE_FILE: join(sandbox.systemd, 'guard.service'),
    CDN_TRAFFIC_GUARD_TIMER_FILE: join(sandbox.systemd, 'guard.timer'),
    RUNTIME_TMP: sandbox.runtime,
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE: sandbox.lock,
    EASY_ALL_CERTBOT_HOOK_FILE_OVERRIDE: join(sandbox.certbot, 'deploy-hook.sh'),
    EASY_ALL_CERTBOT_LIVE_DIR_OVERRIDE: sandbox.le,
    EASY_ALL_POLICY_STATE_DIR_OVERRIDE: sandbox.policy,
    EASY_ALL_POLICY_RC_OVERRIDE: join(sandboxRoot, 'policy-rc.d'),
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: sandbox.progress,
    EASY_ALL_STATE_FILE_OVERRIDE: sandbox.stateFile,
    FORCE: '1',
    ...extra,
});

function writeCloudfrontSandbox({ subscriptionConfig }) {
    for (const dir of [
        sandbox.state, join(sandbox.state, 'certs'), sandbox.web, join(sandbox.web, 'subscriptions'),
        sandbox.lib, sandbox.runtime, sandbox.systemd, sandbox.certbot, sandbox.le,
        sandbox.policy, join(sandboxRoot, 'bin'), join(sandboxRoot, 'nginx'), join(sandboxRoot, 'ssh'),
        join(sandboxRoot, 'ufw'), join(sandboxRoot, 'sysctl'),
    ]) {
        mkdirSync(dir, { recursive: true });
    }
    writeFileSync(shimPath, `${shimLines.join('\n')}\n`, { mode: 0o700 });
    writeFileSync(join(sandbox.state, 'certs', 'fullchain.pem'), 'cert');
    writeFileSync(join(sandbox.state, 'certs', 'private.key'), 'key', { mode: 0o600 });
    writeFileSync(sandbox.stateFile, sandboxCloudfrontState(subscriptionConfig), { mode: 0o600 });
    writeFileSync(
        sandbox.xray,
        '#!/usr/bin/env bash\ncase "${1:-}" in\napi) printf \'{"stat":[{"name":"inbound>>>vless-xhttp-in>>>traffic>>>uplink","value":5},{"name":"inbound>>>vless-xhttp-in>>>traffic>>>downlink","value":5}]}\' ;;\nesac\nexit 0\n',
        { mode: 0o700 },
    );
    writeFileSync(callLog, '');
}

// root 下这些用例无法安全隔离 /etc 路径（真实 launcher 把系统路径写死），直接跳过。
if (process.getuid && process.getuid() !== 0) {
    // 6.1 正常卸载（无参数）必须完成本机清理并退出 0。
    writeCloudfrontSandbox({
        subscriptionConfig: '{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}',
    });
    const uninstallRes = run(easyAll, ['uninstall'], sandboxEnv());
    assert.equal(uninstallRes.status, 0, `uninstall should complete: ${uninstallRes.stderr}`);
    assert.ok(uninstallRes.stdout.includes('本机内容已卸载'), uninstallRes.stdout);
    assert.ok(uninstallRes.stdout.includes('云端资源已保留'), uninstallRes.stdout);
    assert.ok(!existsSync(sandbox.state), 'uninstall must remove the state directory');
    assert.ok(!existsSync(sandbox.web), 'uninstall must remove the web root');
    const systemCalls = readFileSync(callLog, 'utf8');
    assert.ok(systemCalls.includes('disable --now easy_all-xray.service'), systemCalls);
    assert.ok(systemCalls.includes('disable --now nginx'), systemCalls);
    assert.ok(systemCalls.includes('ufw reload'), systemCalls);

    // 6.2 已卸载后再卸载：正常路径必须给出「尚未安装」，而不是参数错误。
    const secondUninstall = run(easyAll, ['uninstall'], sandboxEnv());
    assert.equal(secondUninstall.status, 1, 'second uninstall must fail');
    assert.ok(secondUninstall.stderr.includes('尚未安装'), secondUninstall.stderr);

    // 7. 跨进程闭环：损坏订阅 → 新进程 edit-sub 修复 → 再一个新进程 cdn-traffic-sync 收敛。
    writeCloudfrontSandbox({ subscriptionConfig: '{ broken-json' });
    writeFileSync(
        sandbox.usage,
        '{"period":"2026-11","used_bytes":0,"blocked":false,"enforced":false,"protection_offline":false,"runtime_id":"","last_uplink":0,"last_downlink":0}\n',
        { mode: 0o600 },
    );
    const editSubRes = run(easyAll, ['edit-sub'], sandboxEnv({
        SUBSCRIPTION_CONFIG: '{"allowedTokens":{"owner":"repair-token-123"},"nodes":[]}',
    }));
    assert.equal(editSubRes.status, 0, `edit-sub repair must succeed: ${editSubRes.stderr}`);
    assert.ok(editSubRes.stdout.includes('订阅已刷新'), editSubRes.stdout);
    const repairedState = readFileSync(sandbox.stateFile, 'utf8');
    assert.ok(repairedState.includes('repair-token-123'), 'edit-sub must persist the new token');
    assert.ok(!repairedState.includes('broken-json'), 'edit-sub must replace the corrupt config');
    for (const product of ['base64.txt', 'mihomo.yaml', 'mihomo-ios.yaml', 'base64-all.txt', 'mihomo-all.yaml', 'mihomo-ios-all.yaml']) {
        assert.ok(existsSync(join(sandbox.web, 'subscriptions', product)), `edit-sub must publish ${product}`);
    }
    // Token 写回必须全链路生效：Nginx map 用新 Token，旧 Token 不再被接受。
    const repairedNginx = readFileSync(sandbox.nginx, 'utf8');
    assert.ok(repairedNginx.includes('"repair-token-123" 1;'), repairedNginx);
    assert.ok(!repairedNginx.includes('"cdnwq-rtbke-3182" 1;'), 'old token must be dropped');
    const repairCalls = readFileSync(callLog, 'utf8');
    assert.ok(!repairCalls.includes('start easy_all-xray'), 'edit-sub must not start Xray');
    assert.ok(!repairCalls.includes('restart easy_all-xray'), 'edit-sub must not restart Xray');

    // 新进程只读磁盘状态：订阅已就绪，采样成功且退出 0。
    const syncRes = run(easyAll, ['cdn-traffic-sync'], sandboxEnv());
    assert.equal(syncRes.status, 0, `cdn-traffic-sync must succeed after repair: ${syncRes.stderr}`);
    const usage = JSON.parse(readFileSync(sandbox.usage, 'utf8'));
    assert.equal(usage.used_bytes, 10, 'new process must sample the CDN inbound counters');
    assert.equal(usage.last_uplink, 5);
    assert.equal(usage.last_downlink, 5);
    assert.equal(usage.blocked, false);
} else {
    console.log('skip - root 下跳过真实 CLI 卸载/修复闭环（无法安全隔离 /etc 系统路径）');
}


// 8. Cloudflare 橙云链路（模式 3/5）的真实 CLI 生命周期：证书轮换、失败回滚、
// 云端清理失败容错、cleanup-partial 失败重试、不完整状态卸载。
// 与第 6 节同一套隔离思路：`id -u` 桩成 0 越过 root 门禁，进程本身仍是非 root，
// 漏配隔离路径会因权限失败而不是破坏测试机。
const cfRoot = join(tmpdir(), `easy-all-cf-cli-${process.pid}`);
const cfShim = join(cfRoot, 'shim.sh');
const cfCalls = join(cfRoot, 'calls.log');
const cfApiLog = join(cfRoot, 'api.log');
const cfCa = join(cfRoot, 'ca');
const cf = {
    state: join(cfRoot, 'state'),
    web: join(cfRoot, 'web'),
    lib: join(cfRoot, 'lib'),
    runtime: join(cfRoot, 'runtime'),
    systemd: join(cfRoot, 'systemd'),
    policy: join(cfRoot, 'policy'),
    progress: join(cfRoot, 'progress.env'),
    ssh: join(cfRoot, 'ssh', 'ports.conf'),
    ufw: join(cfRoot, 'ufw', 'default'),
    ipv6: join(cfRoot, 'sysctl', 'ipv6.conf'),
    nginxDefault: join(cfRoot, 'nginx', 'default'),
    nginx: join(cfRoot, 'nginx', 'easy_all.conf'),
    lock: join(cfRoot, 'runtime-write.lock'),
    xray: join(cfRoot, 'bin', 'xray'),
    stateFile: join(cfRoot, 'state', 'state.env'),
};

const cfShimLines = [
    'readonly() {',
    '    local arg name val',
    '    for arg in "$@"; do',
    '        [[ "${arg}" == -* ]] && continue',
    '        if [[ "${arg}" == *=* ]]; then',
    '            name=${arg%%=*}; val=${arg#*=}',
    '            [[ -n "${!name+x}" ]] || printf -v "${name}" "%s" "${val}"',
    '        fi',
    '    done',
    '}',
    'id() { if [[ "${1:-}" == "-u" ]]; then printf "0\\n"; return 0; fi; command id "$@"; }',
    'systemctl() { printf "systemctl %s\\n" "$*" >>"${CF_CALL_LOG:?}"; return 0; }',
    'nginx() { printf "nginx %s\\n" "$*" >>"${CF_CALL_LOG:?}"; return 0; }',
    'ufw() {',
    '    printf "ufw %s\\n" "$*" >>"${CF_CALL_LOG:?}"',
    '    local rules="${CF_UFW_RULES:?}" port="" cidr="Anywhere" prev="" arg',
    '    for arg in "$@"; do',
    '        [[ "${prev}" != "port" ]] || port="${arg}"',
    '        case "${arg}" in',
    '        */tcp) port="${arg%/tcp}" ;;',
    '        *.*/*) cidr="${arg}" ;;',
    '        esac',
    '        prev="${arg}"',
    '    done',
    '    case "${1:-}" in',
    '    status)',
    '        if [[ "${2:-}" == "numbered" ]]; then awk \'{printf "[%2d] %s\\n", NR, $0}\' "${rules}"; else printf "Status: active\\n"; fi',
    '        ;;',
    '    allow) [[ -z "${port}" ]] || printf "%s/tcp ALLOW IN %s\\n" "${port}" "${cidr}" >>"${rules}" ;;',
    '    --force)',
    '        if [[ "${2:-}" == "delete" && -n "${port}" ]]; then',
    '            grep -v -F "${port}/tcp ALLOW IN ${cidr}" "${rules}" >"${rules}.tmp" 2>/dev/null || :',
    '            command mv "${rules}.tmp" "${rules}"',
    '        fi',
    '        ;;',
    '    esac',
    '    return 0',
    '}',
    'sysctl() { return 0; }',
    'flock() { return 0; }',
    'crontab() { [[ "${1:-}" == "-l" ]] && printf "0 3 * * * /usr/local/bin/user-backup\\n"; return 0; }',
    'dig() { printf "203.0.113.9\\n"; }',
    'timeout() { shift; "$@"; }',
    'sysctl() {',
    '    case "$*" in',
    '    *tcp_congestion_control*) printf "skyline_cc\\n" ;;',
    '    *default_qdisc*) printf "fq\\n" ;;',
    '    *) return 0 ;;',
    '    esac',
    '}',
    'dpkg() { case "${1:-}" in --print-architecture) printf "amd64\\n" ;; --compare-versions) return 0 ;; *) return 0 ;; esac; }',
    'uname() { case "${1:-}" in -r) printf "6.12.9-zabbly+\\n" ;; -m) printf "x86_64\\n" ;; *) printf "Linux\\n" ;; esac; }',
    'ip() { case "$*" in *route*) printf "default via 198.51.100.1 dev eth0\\n" ;; *addr*) printf "    inet 198.51.100.10/24 brd 198.51.100.255 scope global eth0\\n" ;; *) return 0 ;; esac; }',
    'tc() {',
    '    case "$*" in',
    '    *"filter show"*) printf "[]\\n"; return 0 ;;',
    '    *show*) printf \'[{"kind":"fq","handle":"0:","root":true}]\\n\'; return 0 ;;',
    '    *) printf "tc %s\\n" "$*" >>"${CF_CALL_LOG:?}"; return 0 ;;',
    '    esac',
    '}',
    'apt-get() { printf "unexpected apt-get %s\\n" "$*" >>"${CF_CALL_LOG:?}"; return 1; }',
    'apt() { printf "unexpected apt %s\\n" "$*" >>"${CF_CALL_LOG:?}"; return 1; }',
    'dpkg-query() { printf "ii \\n"; return 0; }',
    'fail2ban-client() { return 0; }',
    'modprobe() { return 0; }',
    'update-grub() { return 0; }',
    'grub-install() { return 0; }',
    'mktemp() {',
    '    local args=() arg',
    '    for arg in "$@"; do',
    '        case "${arg}" in',
    '        /usr/local/lib/easy_all*) args+=("${CF_LIB_DIR}${arg#/usr/local/lib/easy_all}") ;;',
    '        *) args+=("${arg}") ;;',
    '        esac',
    '    done',
    '    command mktemp "${args[@]}"',
    '}',

    'ss() {',
    '    case "$*" in',
    '    *"sport = :22"*) printf \'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=42,fd=3))\\n\'; return 0 ;;',
    '    *"sport = :8443"*) printf \'LISTEN 0 128 0.0.0.0:8443 0.0.0.0:*\\n\'; return 0 ;;',
    '    *"sport = :443"*) printf \'LISTEN 0 128 0.0.0.0:443 0.0.0.0:*\\n\'; return 0 ;;',
    '    *"sport = :10086"*) printf \'LISTEN 0 128 127.0.0.1:10086 0.0.0.0:*\\n\'; return 0 ;;',
    '    esac',
    '    printf \'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=42,fd=3))\\n\'',
    '    return 0',
    '}',
    'sshd() { case "${1:-}" in -T) printf "listenaddress 0.0.0.0:22\\nport 22\\n" ;; *) return 0 ;; esac; }',
    'install() {',
    '    local args=() arg mapped target',
    '    while [[ $# -gt 0 ]]; do',
    '        case "$1" in',
    '        -o | -g) shift 2 ;;',
    '        *) args+=("$1"); shift ;;',
    '        esac',
    '    done',
    '    for arg in "${!args[@]}"; do',
    '        case "${args[arg]}" in',
    '        /usr/local/lib) args[arg]="${CF_USR_DIR}/lib" ;;',
    '        /usr/local/bin) args[arg]="${CF_USR_DIR}/bin" ;;',
    '        /usr/local/lib/easy_all*) args[arg]="${CF_LIB_DIR}${args[arg]#/usr/local/lib/easy_all}" ;;',
    '        /usr/local/bin/easy_all) args[arg]="${CF_LIB_DIR}/easy_all" ;;',
    '        esac',
    '    done',
    '    target="${args[${#args[@]}-1]}"',
    '    case "${target}" in /etc/*|/usr/*|/var/*) printf "test isolation: refusing install %s\\n" "${target}" >&2; return 1 ;; esac',
    '    if [[ " ${args[*]} " == *" -d "* ]]; then',
    '        for arg in "${args[@]}"; do',
    '            case "${arg}" in -*) continue ;; esac',
    '            mkdir -p "${arg}"',
    '        done',
    '        return 0',
    '    fi',
    '    mkdir -p "$(dirname "${target}")"',
    '    command install "${args[@]}"',
    '}',
    'mv() {',
    '    local args=() arg target',
    '    for arg in "$@"; do',
    '        case "${arg}" in',
    '        /usr/local/lib) args+=("${CF_USR_DIR}/lib") ;;',
    '        /usr/local/bin) args+=("${CF_USR_DIR}/bin") ;;',
    '        /usr/local/lib/easy_all*) args+=("${CF_LIB_DIR}${arg#/usr/local/lib/easy_all}") ;;',
    '        /usr/local/bin/easy_all) args+=("${CF_LIB_DIR}/easy_all") ;;',
    '        *) args+=("${arg}") ;;',
    '        esac',
    '    done',
    '    target="${args[${#args[@]}-1]}"',
    '    if [[ "${CF_FAIL_STATE_MV:-0}" == "1" && "${target}" == "${STATE_FILE}" ]]; then',
    '        return 1',
    '    fi',
    '    command mv "${args[@]}"',
    '}',
    'ln() {',
    '    local args=() arg',
    '    for arg in "$@"; do',
    '        case "${arg}" in',
    '        /usr/local/bin/easy_all) args+=("${CF_LIB_DIR}/easy_all") ;;',
    '        /usr/local/lib/easy_all*) args+=("${CF_LIB_DIR}${arg#/usr/local/lib/easy_all}") ;;',
    '        *) args+=("${arg}") ;;',
    '        esac',
    '    done',
    '    command ln "${args[@]}"',
    '}',
    'rm() {',
    '    local args=() arg',
    '    for arg in "$@"; do',
    '        case "${arg}" in',
    '        /usr/local/lib) args+=("${CF_USR_DIR}/lib") ;;',
    '        /usr/local/bin) args+=("${CF_USR_DIR}/bin") ;;',
    '        /usr/local/lib/easy_all*) args+=("${CF_LIB_DIR}${arg#/usr/local/lib/easy_all}") ;;',
    '        /usr/local/bin/easy_all) args+=("${CF_LIB_DIR}/easy_all") ;;',
    '        *) args+=("${arg}") ;;',
    '        esac',
    '    done',
    '    command rm "${args[@]}"',
    '}',
    '# Cloudflare API 与订阅/健康探针桩：只替换外部边界，被测逻辑保持原实现。',
    'curl() {',
    '    local last="" arg prev="" argdump="$*" payload_csr cert_json new_cert id payload_file="" method=""',
    '    for arg in "$@"; do',
    '        [[ "${prev}" == "-X" ]] && method=$arg',
    '        last=$arg',
    '        case "${arg}" in @*) payload_file="${arg#@}" ;; esac',
    '        prev=$arg',
    '    done',
    '    [[ -n "${method}" ]] || method=GET',
    '    printf "curl %s\\n" "${argdump}" >>"${CF_API_LOG:?}"',
    '    case "${argdump}" in',
    '    *"api.cloudflare.com"*"/ips"*) printf \'{"success":true,"result":{"ipv4_cidrs":["198.51.100.0/24"]}}\\n\'; return 0 ;;',
    '    *"-X DELETE"*api.cloudflare.com*)',
    '        printf "CFAPI DELETE %s STATE %s\\n" "${last}" "$(grep -E \'^CLOUDFLARE_ORIGIN_CERT_ID=\' "${STATE_FILE:-/nonexistent}" 2>/dev/null | tail -n 1)" >>"${CF_API_LOG:?}"',
    '        printf "\\n204"',
    '        return 0',
    '        ;;',
    '    *"api.cloudflare.com"*"/certificates"*)',
    '        printf "CFAPI %s %s\\n" "${method}" "${last}" >>"${CF_API_LOG:?}"',
    '        payload_csr=$(jq -r ".csr // empty" "${RUNTIME_TMP}/cloudflare-api-payload" 2>/dev/null || true)',
    '        if [[ -z "${payload_csr}" ]]; then printf \'{"success":false}\\n400\'; return 0; fi',
    '        printf "%s" "${payload_csr}" >"${RUNTIME_TMP}/stub.csr"',
    '        openssl x509 -req -sha256 -in "${RUNTIME_TMP}/stub.csr" -CA "${CF_CA_DIR}/ca.pem" \\',
    '            -CAkey "${CF_CA_DIR}/ca.key" -CAcreateserial -days 3000 \\',
    '            -extfile "${CF_CA_DIR}/ext.cnf" -out "${RUNTIME_TMP}/stub-cert.pem" 2>/dev/null || { printf \'{"success":false}\\n500\'; return 0; }',
    '        new_cert=$(command cat "${RUNTIME_TMP}/stub-cert.pem")',
    '        command cp "${RUNTIME_TMP}/stub-cert.pem" "${CF_CA_DIR}/issued.pem" 2>/dev/null || :',
    '        id="cert-new-$(command date +%s)"',
    '        cert_json=$(jq -cn --arg cert "${new_cert}" --arg id "${id}" \\',
    '            \'{success:true,result:{id:$id,certificate:$cert,expires_on:"2039-01-01T00:00:00Z"}}\')',
    '        printf "%s\\n200" "${cert_json}"',
    '        return 0',
    '        ;;',
    '    *"api.cloudflare.com"*"/dns_records?"*)',
    '        if [[ "${CF_DNS_AMBIGUOUS:-0}" == "1" ]]; then',
    '            printf \'{"success":true,"result":[{"id":"d1","type":"A","content":"198.51.100.10","proxied":true,"comment":"easy_all cloudflare"},{"id":"d2","type":"A","content":"198.51.100.11","proxied":true,"comment":"easy_all cloudflare"}]}\\n200\'',
    '        else',
    '            printf \'{"success":true,"result":[]}\\n200\'',
    '        fi',
    '        return 0',
    '        ;;',
    '    *"api.cloudflare.com"*"/dns_records"*)',
    '        if [[ -n "${payload_file}" && -s "${payload_file}" ]]; then',
    '            printf "CFAPI %s %s %s\\n" "${method}" "${last}" "$(command cat "${payload_file}")" >>"${CF_API_LOG:?}"',
    '        fi',
    '        printf \'{"success":true,"result":{"id":"newrec"}}\\n200\'',
    '        return 0',
    '        ;;',
    '    esac',
    '    if [[ "${argdump}" == *"%{http_code}"* ]]; then',
    '        if [[ "${argdump}" == *"/subscribe"* ]]; then printf "403"; else printf "404"; fi',
    '        return 0',
    '    fi',
    '    if [[ "${argdump}" == *"/easy_all-health"* ]]; then',
    '        if [[ "${argdump}" == *"--resolve"* && "${CF_LOCAL_FAIL:-0}" == "1" ]]; then printf "broken"; return 0; fi',
    '        if [[ "${argdump}" != *"--resolve"* && "${CF_PUBLIC_FAIL:-0}" == "1" ]]; then printf "broken"; return 0; fi',
    '        printf "easy_all ok"; return 0',
    '    fi',
    '    if [[ "${argdump}" == *"flag=clash"* ]]; then command cat "${CF_SUBSCRIPTIONS}/mihomo.yaml"; return 0; fi',
    '    if [[ "${argdump}" == *"/subscribe"* ]]; then command cat "${CF_SUBSCRIPTIONS}/base64.txt"; return 0; fi',
    '    printf ""',
    '}',
];

const cfState = (protocol, extra = []) => {
    const common = [
        'STATE_VERSION="0"',
        `PROTOCOL="${protocol}"`,
        'CDN_PROVIDER="cloudflare"',
        'TCP_ACCELERATION="skyline"',
        'VPS_PUBLIC_IPV4="198.51.100.10"',
        'CF_ZONE="example.com"',
        'CLOUDFLARE_ZONE_ID="zone-123"',
        'CF_NODE_DOMAIN="cf.example.com"',
        'SUB_DOWNLOAD_NAME="EASYALL"',
        'OWNER_TOKEN="cdnwq-rtbke-3182"',
        `ALLOWED_TOKENS='{"owner":"cdnwq-rtbke-3182"}'`,
        `SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"cdnwq-rtbke-3182"},"nodes":[]}'`,
        'VLESS_UUID="11111111-2222-4111-8111-111111111111"',
        'CF_NODE_PREFIX="CF"',
        'XHTTP_PATH="/xhttp-abcdef123456"',
        'CLOUDFLARE_ORIGIN_CERT_ID="cert-old-1"',
        'CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON="2039-01-01T00:00:00Z"',
        '',
    ];
    return [...common.slice(0, -1), ...extra, ''].join('\n');
};

const cfEnv = (extra = {}) => ({
    ...isolation,
    BASH_ENV: cfShim,
    CF_CALL_LOG: cfCalls,
    CF_API_LOG: cfApiLog,
    CF_LIB_DIR: cf.lib,
    CF_CA_DIR: cfCa,
    CF_UFW_RULES: join(cfRoot, 'ufw', 'rules.txt'),
    CF_USR_DIR: join(cfRoot, 'usr'),
    CF_SUBSCRIPTIONS: join(cf.web, 'subscriptions'),
    STATE_DIR: cf.state,
    STATE_FILE: cf.stateFile,
    BACKUP_DIR: join(cf.state, 'backups'),
    CERT_DIR: join(cf.state, 'certs'),
    CERT_FILE: join(cf.state, 'certs', 'fullchain.pem'),
    KEY_FILE: join(cf.state, 'certs', 'private.key'),
    WEB_ROOT: cf.web,
    SUBSCRIPTION_DIR: join(cf.web, 'subscriptions'),
    COMMAND_INSTALL_DIR: cf.lib,
    XRAY_DIR: join(cf.state, 'xray'),
    XRAY_BIN: cf.xray,
    XRAY_CONFIG: join(cf.state, 'xray', 'config.json'),
    XRAY_SERVICE_FILE: join(cf.systemd, 'easy_all-xray.service'),
    NGINX_CONFIG: cf.nginx,
    UFW_DEFAULT_CONFIG: cf.ufw,
    IPV6_SYSCTL_CONF: cf.ipv6,
    TCP_SYSCTL_CONF_OVERRIDE: join(cfRoot, 'tcp-tuning.conf'),
    SYSTEMD_SYSTEM_DIR: cf.systemd,
    EASY_ALL_TCP_DIR_OVERRIDE: join(cfRoot, 'tcp'),
    EASY_ALL_NGINX_MAIN_CONF: join(cfRoot, 'nginx', 'nginx.conf'),
    EASY_ALL_FAIL2BAN_CONFIG: join(cfRoot, 'fail2ban', 'jail.local'),
    EASY_ALL_FAIL2BAN_ACTION_CONFIG: join(cfRoot, 'fail2ban', 'action.conf'),
    EASY_ALL_FAIL2BAN_CIDR_HELPER: join(cfRoot, 'fail2ban', 'cidr.sh'),
    EASY_ALL_FAIL2BAN_CIDR_STATE_DIR: join(cfRoot, 'fail2ban', 'state'),
    CDN_PUBLIC_ACCEPT_ATTEMPTS_OVERRIDE: '2',
    CDN_PUBLIC_ACCEPT_SECONDS_OVERRIDE: '0',
    EASY_ALL_SSH_PORT_CONFIG: cf.ssh,
    EASY_ALL_GUARD_NGINX_DEFAULT_SITE: cf.nginxDefault,
    RUNTIME_TMP: cf.runtime,
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE: cf.lock,
    EASY_ALL_POLICY_STATE_DIR_OVERRIDE: cf.policy,
    EASY_ALL_POLICY_RC_OVERRIDE: join(cfRoot, 'policy-rc.d'),
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: cf.progress,
    EASY_ALL_STATE_FILE_OVERRIDE: cf.stateFile,
    CLOUDFLARE_API_TOKEN: 'test-token-0123456789abcdef',
    FORCE: '1',
    ...extra,
});

function writeCfSandbox(stateText, { oldCertDays = 3000 } = {}) {
    for (const dir of [
        cf.state, join(cf.state, 'certs'), cf.state, cf.web, join(cf.web, 'subscriptions'),
        cf.lib, cf.runtime, cf.systemd, cf.policy, cfCa,
        join(cfRoot, 'bin'), join(cfRoot, 'nginx'), join(cfRoot, 'ssh'),
        join(cfRoot, 'ufw'), join(cfRoot, 'sysctl'),
    ]) {
        mkdirSync(dir, { recursive: true });
    }
    writeFileSync(cfShim, `${cfShimLines.join('\n')}\n`, { mode: 0o700 });
    writeFileSync(cf.stateFile, stateText, { mode: 0o600 });
    writeFileSync(cf.xray,
        '#!/usr/bin/env bash\ncase "${1:-}" in\nx25519) printf \'PrivateKey: test-private\\nPassword: test-public\\n\' ;;\ntls) printf \'Pinging with SNI: swdist.apple.com\\nHandshake succeeded\\nTLS Version: TLS 1.3\\n\' ;;\n*) exit 0 ;;\nesac\n',
        { mode: 0o700 });
    writeFileSync(cfCalls, '');
    writeFileSync(cfApiLog, '');
    writeFileSync(join(cfRoot, 'nginx', 'nginx.conf'), 'worker_processes auto;\n');
    writeFileSync(cf.ufw, 'IPV6=yes\nDEFAULT_INPUT_POLICY="DROP"\n');
    writeFileSync(join(cfRoot, 'ufw', 'rules.txt'), '');
    for (const dir of ['fail2ban', 'tcp', 'usr/lib', 'usr/bin']) {
        mkdirSync(join(cfRoot, dir), { recursive: true });
    }
    // 测试 CA 与旧证书：模拟已安装实例当前使用的 Origin CA 身份。
    run('openssl', ['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', join(cfCa, 'ca.key')]);
    run('openssl', ['req', '-new', '-x509', '-sha256', '-key', join(cfCa, 'ca.key'), '-days', '3650',
        '-subj', '/CN=Test Origin CA', '-out', join(cfCa, 'ca.pem')]);
    writeFileSync(join(cfCa, 'ext.cnf'), 'subjectAltName=DNS:cf.example.com\n');
    run('openssl', ['ecparam', '-name', 'prime256v1', '-genkey', '-noout', '-out', join(cf.state, 'certs', 'private.key')]);
    run('openssl', ['req', '-new', '-sha256', '-key', join(cf.state, 'certs', 'private.key'),
        '-subj', '/CN=cf.example.com', '-addext', 'subjectAltName=DNS:cf.example.com',
        '-out', join(cfCa, 'old.csr')]);
    run('openssl', ['x509', '-req', '-sha256', '-in', join(cfCa, 'old.csr'), '-CA', join(cfCa, 'ca.pem'),
        '-CAkey', join(cfCa, 'ca.key'), '-CAcreateserial', '-days', String(oldCertDays),
        '-extfile', join(cfCa, 'ext.cnf'), '-out', join(cf.state, 'certs', 'fullchain.pem')]);
    // 回源 CA 根：生产代码发现该文件有效就不再下载，回源校验仍使用同一 CA。
    writeFileSync(join(cf.state, 'certs', 'cloudflare-origin-ca-ecc.pem'), readFileSync(join(cfCa, 'ca.pem')));
}

if (process.getuid && process.getuid() !== 0) {
    // 8.1 edit-sub：真实 CLI 重建订阅与 Nginx，全程不调用 Cloudflare 管理 API。
    writeCfSandbox(cfState('cloudflare'));
    const cfEdit = run(easyAll, ['edit-sub'], cfEnv({
        SUBSCRIPTION_CONFIG: '{"allowedTokens":{"owner":"cf-token-123456"},"nodes":[]}',
    }));
    assert.equal(cfEdit.status, 0, `cloudflare edit-sub must succeed: ${cfEdit.stderr}`);
    const cfStateText = readFileSync(cf.stateFile, 'utf8');
    assert.ok(cfStateText.includes('cf-token-123456'), 'edit-sub must persist the new token');
    const cfNginx = readFileSync(cf.nginx, 'utf8');
    assert.equal((cfNginx.match(/server_name cf\.example\.com;/g) || []).length, 1,
        'single-domain mode must render exactly one business server');
    assert.ok(cfNginx.includes('grpc_pass grpc://127.0.0.1:10086;'), cfNginx);
    assert.ok(cfNginx.includes('location = /subscribe {'), cfNginx);
    assert.ok(!cfNginx.includes('X-Easy-All-Origin-Key'), 'cloudflare chain must not use the origin header');
    const cfBase64 = Buffer.from(readFileSync(join(cf.web, 'subscriptions', 'base64.txt'), 'utf8'), 'base64').toString();
    assert.equal((cfBase64.match(/vless:\/\/1111/g) || []).length, 1, 'exactly one local CDN node');
    const cfMihomo = readFileSync(join(cf.web, 'subscriptions', 'mihomo.yaml'), 'utf8');
    assert.ok(!cfMihomo.includes('name: CDN-AUTO'), 'no speed-test group may be generated');
    assert.ok(!cfMihomo.includes('name: CDN-FALLBACK'), 'no fallback group may be generated');
    assert.ok(!readFileSync(cfApiLog, 'utf8').includes('api.cloudflare.com'),
        'edit-sub must not call the Cloudflare API');

    // 8.2 模式 5：直连节点排在 CDN 节点之前，且 8443 入站存在。
    writeCfSandbox(cfState('combined-cloudflare', [
        'DIRECT_DOMAIN="node.example.com"',
        'DIRECT_NODE_NAME="direct-node"',
        'REALITY_TARGET="swdist.apple.com:443"',
        'REALITY_PRIVATE_KEY="test-private"',
        'REALITY_PUBLIC_KEY="test-public"',
        'REALITY_SHORT_ID="0123456789abcdef"',
    ]));
    const cfEdit5 = run(easyAll, ['edit-sub'], cfEnv());
    assert.equal(cfEdit5.status, 0, `mode 5 edit-sub must succeed: ${cfEdit5.stderr}`);
    const cfBase64Mode5 = Buffer.from(
        readFileSync(join(cf.web, 'subscriptions', 'base64.txt'), 'utf8'), 'base64').toString();
    const cfLinks = cfBase64Mode5.split('\n').filter((line) => line.startsWith('vless://'));
    assert.equal(cfLinks.length, 2, `mode 5 must publish two local nodes: ${cfBase64Mode5}`);
    assert.ok(cfLinks[0].includes('@node.example.com:8443'), `direct node must come first: ${cfLinks[0]}`);

    // 8.3 renew-cert 成功：新证书落盘、状态写入新 ID、旧证书被吊销。
    writeCfSandbox(cfState('cloudflare'));
    const cfRenew = run(easyAll, ['renew-cert'], cfEnv());
    assert.equal(cfRenew.status, 0, `renew-cert must succeed: ${cfRenew.stderr}`);
    const renewedState = readFileSync(cf.stateFile, 'utf8');
    assert.ok(!renewedState.includes('cert-old-1'), 'state must persist the rotated certificate id');
    assert.ok(readFileSync(cf.stateFile, 'utf8').includes('CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON'), renewedState);
    const renewApi = readFileSync(cfApiLog, 'utf8');
    assert.ok(renewApi.includes('/certificates'), renewApi);
    assert.ok(!renewApi.includes('/dns_records'), `renew-cert must not touch DNS: ${renewApi}`);
    const renewNewId = (renewedState.match(/CLOUDFLARE_ORIGIN_CERT_ID="?([^"\n]+)"?/) || [])[1];
    assert.ok(renewNewId && renewNewId.startsWith('cert-new-'),
        `renew-cert must persist the freshly issued id: ${renewedState}`);
    assert.ok(renewApi.includes('certificates/cert-old-1'),
        `renew-cert must revoke exactly the previous certificate: ${renewApi}`);

    // 8.4 renew-cert 失败：本机恢复旧证书、旧证书不被吊销、新 ID 必须被点名，
    //     且不得推荐按域名 purge（会连当前在用的 DNS 与旧证书一起删掉）。
    writeCfSandbox(cfState('cloudflare'));
    const oldCert = readFileSync(join(cf.state, 'certs', 'fullchain.pem'), 'utf8');
    const cfRenewFail = run(easyAll, ['renew-cert'], cfEnv({ CF_LOCAL_FAIL: '1' }));
    assert.equal(cfRenewFail.status, 1, 'renew-cert must fail when local TLS acceptance fails');
    assert.equal(readFileSync(join(cf.state, 'certs', 'fullchain.pem'), 'utf8'), oldCert,
        'failed rotation must restore the previous certificate');
    assert.ok(readFileSync(cf.stateFile, 'utf8').includes('cert-old-1'),
        'failed rotation must restore the previous state');
    const failApi = readFileSync(cfApiLog, 'utf8');
    assert.ok(!failApi.includes('-X DELETE'), `failed rotation must not revoke any certificate: ${failApi}`);
    const failOut = `${cfRenewFail.stdout}${cfRenewFail.stderr}`;
    assert.ok(/cert-new-\d+/.test(failOut), `retained certificate id must be reported: ${failOut}`);
    assert.ok(failOut.includes('cf.example.com'), `retained certificate domain must be reported: ${failOut}`);
    assert.ok(!failOut.includes('purge-cloudflare --domain'),
        'retained certificate guidance must not suggest the domain-wide purge');

    // 8.5 uninstall --purge-cloud：DNS 归属不明时仍清理证书，本机卸载继续。
    writeCfSandbox(cfState('cloudflare'));
    const cfPurge = run(easyAll, ['uninstall', '--purge-cloud'], cfEnv({ CF_DNS_AMBIGUOUS: '1' }));
    assert.equal(cfPurge.status, 0, `uninstall --purge-cloud must finish locally: ${cfPurge.stderr}`);
    const purgeApi = readFileSync(cfApiLog, 'utf8');
    assert.ok(purgeApi.includes('/certificates/cert-old-1'),
        `certificate must still be revoked when DNS cleanup fails: ${purgeApi}`);
    assert.ok(!existsSync(cf.state), 'uninstall must remove the state directory');
    const purgeOut = `${cfPurge.stdout}${cfPurge.stderr}`;
    assert.ok(purgeOut.includes('同名 A 记录') || purgeOut.includes('无法判断归属'),
        `ambiguous DNS records must be reported: ${purgeOut}`);

    // 8.6 cleanup-partial：业务路径删除失败时保留 marker 与快照，修正后可重试。
    writeCfSandbox(cfState('cloudflare'));
    // 真实的中断安装还没有 state.env：cleanup-partial 只接管未安装状态。
    unlinkSync(cf.stateFile);
    mkdirSync(join(cf.state, 'backups'), { recursive: true });
    writeFileSync(join(cf.state, 'backups', 'pre-install-complete'), '');
    writeFileSync(join(cf.state, 'install-identity.json'), '{"profile":"cloudflare"}');
    writeFileSync(cf.progress, 'PROFILE=cloudflare\nCHAIN=cloudflare\nSTAGE=services\n');
    const blockedDir = join(cf.web, 'blocked');
    mkdirSync(blockedDir, { recursive: true });
    writeFileSync(join(blockedDir, 'file'), 'x');
    chmodSync(blockedDir, 0o000);
    const cfCleanupFail = run(easyAll, ['cleanup-partial'], cfEnv());
    assert.equal(cfCleanupFail.status, 1, 'cleanup-partial must fail while a business path is undeletable');
    assert.ok(existsSync(join(cf.state, 'backups', 'pre-install-complete')),
        'failed cleanup must keep the pre-install snapshot');
    assert.ok(existsSync(join(cf.state, 'install-identity.json')),
        'failed cleanup must keep the install identity');
    assert.ok(existsSync(cf.progress), 'failed cleanup must keep the progress marker');
    const cleanupFailOut = `${cfCleanupFail.stdout}${cfCleanupFail.stderr}`;
    assert.ok(cleanupFailOut.includes('cleanup-partial'),
        `failed cleanup must point at the retry command: ${cleanupFailOut}`);
    chmodSync(blockedDir, 0o755);
    const cfCleanupRetry = run(easyAll, ['cleanup-partial'], cfEnv());
    assert.equal(cfCleanupRetry.status, 0, `cleanup-partial retry must succeed: ${cfCleanupRetry.stderr}`);
    assert.ok(!existsSync(cf.state), 'retry must remove the state directory');
    assert.ok(!existsSync(cf.progress), 'retry must clear the progress marker');

    // 8.7 不完整模式 4 状态：完整走完本机卸载，且不访问云 API。
    writeCfSandbox([
        'STATE_VERSION="0"',
        'PROTOCOL="combined-cloudfront"',
        'CDN_PROVIDER="aws"',
        '',
    ].join('\n'));
    mkdirSync(cf.web, { recursive: true });
    writeFileSync(join(cf.web, 'keep.txt'), 'x');
    const incompleteUninstall = run(easyAll, ['uninstall'], cfEnv());
    assert.equal(incompleteUninstall.status, 0,
        `incomplete mode 4 uninstall must complete: ${incompleteUninstall.stderr}`);
    assert.ok(incompleteUninstall.stdout.includes('云端资源已保留'), incompleteUninstall.stdout);
    assert.ok(!existsSync(cf.state), 'incomplete uninstall must remove local state');
    assert.ok(!existsSync(join(cf.web, 'keep.txt')), 'incomplete uninstall must remove the web root');
    assert.ok(!readFileSync(cfApiLog, 'utf8').includes('api.cloudflare.com'),
        'incomplete uninstall must not call the Cloudflare API');


    // 8.8 模式 3 `apply`：真实 CLI 走完 Xray/Nginx/UFW/订阅编排，且不写云端。
    writeCfSandbox(cfState('cloudflare'));
    const cfApply3 = run(easyAll, ['apply'], cfEnv());
    assert.equal(cfApply3.status, 0, `mode 3 apply must succeed: ${cfApply3.stdout}${cfApply3.stderr}`);
    const apply3Xray = JSON.parse(readFileSync(join(cf.state, 'xray', 'config.json'), 'utf8'));
    const apply3Tags = apply3Xray.inbounds.map((inbound) => inbound.tag).sort();
    assert.deepEqual(apply3Tags, ['vless-xhttp-in'], `mode 3 must only expose the XHTTP inbound: ${apply3Tags}`);
    const apply3Xhttp = apply3Xray.inbounds.find((inbound) => inbound.tag === 'vless-xhttp-in');
    assert.equal(apply3Xhttp.listen, '127.0.0.1', 'XHTTP must listen on loopback only');
    assert.equal(apply3Xhttp.streamSettings.xhttpSettings.host, 'cf.example.com');
    assert.equal(apply3Xhttp.streamSettings.xhttpSettings.mode, 'stream-up');
    const apply3Nginx = readFileSync(cf.nginx, 'utf8');
    assert.equal((apply3Nginx.match(/server_name cf\.example\.com;/g) || []).length, 1,
        'apply must render exactly one business server');
    assert.ok(!apply3Nginx.includes('listen 80;'), 'cloudflare mode must not serve port 80');
    const apply3Artifacts = readdirSync(join(cf.web, 'subscriptions')).filter((name) => name.endsWith('.yaml') || name.endsWith('.txt')).sort();
    assert.deepEqual(apply3Artifacts,
        ['base64-all.txt', 'base64.txt', 'mihomo-all.yaml', 'mihomo-ios-all.yaml', 'mihomo-ios.yaml', 'mihomo.yaml'],
        `apply must publish the six subscription artifacts: ${apply3Artifacts}`);
    const apply3Calls = readFileSync(cfCalls, 'utf8');
    assert.ok(apply3Calls.includes('restart easy_all-xray.service'),
        `apply must restart Xray so the new config takes effect: ${apply3Calls}`);
    assert.ok(!apply3Calls.includes('allow 443/tcp'), `no public 443 allow may be added: ${apply3Calls}`);
    assert.ok(apply3Calls.includes('allow proto tcp from 198.51.100.0/24'), `origin allowlist missing: ${apply3Calls}`);
    const apply3Api = readFileSync(cfApiLog, 'utf8');
    assert.ok(!apply3Api.includes('-X POST'), `apply must not write cloud resources: ${apply3Api}`);
    assert.ok(!apply3Api.includes('/certificates'), `apply must not touch certificates: ${apply3Api}`);

    // 8.9 模式 5 `apply`：额外渲染固定 8443 的 Reality 入站。
    writeCfSandbox(cfState('combined-cloudflare', [
        'DIRECT_DOMAIN="node.example.com"',
        'DIRECT_NODE_NAME="direct-node"',
        'REALITY_TARGET="swdist.apple.com:443"',
        'REALITY_PRIVATE_KEY="test-private"',
        'REALITY_PUBLIC_KEY="test-public"',
        'REALITY_SHORT_ID="0123456789abcdef"',
    ]));
    const cfApply5 = run(easyAll, ['apply'], cfEnv());
    assert.equal(cfApply5.status, 0, `mode 5 apply must succeed: ${cfApply5.stdout}${cfApply5.stderr}`);
    const apply5Xray = JSON.parse(readFileSync(join(cf.state, 'xray', 'config.json'), 'utf8'));
    const apply5Tags = apply5Xray.inbounds.map((inbound) => inbound.tag).sort();
    assert.deepEqual(apply5Tags, ['vless-reality-in', 'vless-xhttp-in'],
        `mode 5 must expose both inbounds: ${apply5Tags}`);
    const apply5Reality = apply5Xray.inbounds.find((inbound) => inbound.tag === 'vless-reality-in');
    assert.equal(apply5Reality.port, 8443, 'mode 5 Reality inbound must stay on 8443');
    assert.equal(apply5Reality.listen, '0.0.0.0');
    const apply5Calls = readFileSync(cfCalls, 'utf8');
    assert.ok(apply5Calls.includes('allow proto tcp from 198.51.100.0/24'), apply5Calls);
    assert.ok(apply5Calls.includes('allow 8443/tcp'), `mode 5 must allow the Reality port: ${apply5Calls}`);
    assert.ok(apply5Calls.includes('restart easy_all-xray.service'), apply5Calls);


    // 8.10 apply-cloud 成功：DNS 写入、Origin CA 重签、公网验收、先提交后吊销。
    writeCfSandbox(cfState('cloudflare'), { oldCertDays: 5 });
    const cfApplyCloud = run(easyAll, ['apply-cloud'], cfEnv());
    assert.equal(cfApplyCloud.status, 0, `apply-cloud must succeed: ${cfApplyCloud.stdout}${cfApplyCloud.stderr}`);
    const acApi = readFileSync(cfApiLog, 'utf8');
    const acState = readFileSync(cf.stateFile, 'utf8');
    const acNewId = (acState.match(/CLOUDFLARE_ORIGIN_CERT_ID="?([^"\n]+)"?/) || [])[1];
    assert.ok(acNewId && acNewId !== 'cert-old-1', `state must persist the rotated id: ${acState}`);
    assert.ok(acNewId.startsWith('cert-new-'), `state must persist the freshly issued id: ${acState}`);
    assert.ok(acApi.includes('/certificates'), `apply-cloud must issue a certificate: ${acApi}`);
    // DNS 写入的同一请求必须携带节点域名、IPv4 与橙云标记。
    const dnsPostLine = acApi.split('\n').find((line) =>
        line.startsWith('CFAPI POST https://api.cloudflare.com/client/v4/zones/zone-123/dns_records '));
    assert.ok(dnsPostLine, `apply-cloud must POST the proxied A record: ${acApi}`);
    assert.ok(dnsPostLine.includes('"type":"A"') && dnsPostLine.includes('"name":"cf.example.com"'),
        `unexpected DNS payload: ${dnsPostLine}`);
    assert.ok(dnsPostLine.includes('"content":"198.51.100.10"') && dnsPostLine.includes('"proxied":true'),
        `DNS record must be the proxied origin address: ${dnsPostLine}`);
    // 新证书必须真的落盘，且吊销目标只能是旧证书。
    const issuedCert = readFileSync(join(cfCa, 'issued.pem'), 'utf8');
    assert.equal(readFileSync(join(cf.state, 'certs', 'fullchain.pem'), 'utf8'), issuedCert,
        'apply-cloud must install the freshly issued certificate');
    const revokeLine = acApi.split('\n').find((line) => line.startsWith('CFAPI DELETE '));
    assert.ok(
        revokeLine &&
            revokeLine.startsWith(
                'CFAPI DELETE https://api.cloudflare.com/client/v4/certificates/cert-old-1 STATE ',
            ),
        `apply-cloud must revoke exactly the previous certificate: ${revokeLine}`,
    );
    assert.ok(revokeLine.includes('CLOUDFLARE_ORIGIN_CERT_ID=' + acNewId),
        `the new state must be committed before the old certificate is revoked: ${revokeLine}`);

    // 8.11 apply-cloud 公网验收失败：旧 state/证书恢复、不吊销、新 ID 被点名。
    writeCfSandbox(cfState('cloudflare'), { oldCertDays: 5 });
    const oldCloudCert = readFileSync(join(cf.state, 'certs', 'fullchain.pem'), 'utf8');
    const acFail = run(easyAll, ['apply-cloud'], cfEnv({ CF_PUBLIC_FAIL: '1' }));
    assert.equal(acFail.status, 1, 'apply-cloud must fail when public acceptance fails');
    assert.equal(readFileSync(join(cf.state, 'certs', 'fullchain.pem'), 'utf8'), oldCloudCert,
        'failed apply-cloud must restore the previous certificate');
    assert.ok(readFileSync(cf.stateFile, 'utf8').includes('cert-old-1'),
        'failed apply-cloud must restore the previous state');
    const acFailApi = readFileSync(cfApiLog, 'utf8');
    assert.ok(!acFailApi.includes('-X DELETE'), `failed apply-cloud must not revoke certificates: ${acFailApi}`);
    const acFailOut = `${acFail.stdout}${acFail.stderr}`;
    assert.ok(/cert-new-\d+/.test(acFailOut), `retained certificate must be reported: ${acFailOut}`);
    assert.ok(acFailOut.includes('cf.example.com'), `report must name the certificate domain: ${acFailOut}`);

    // 8.12 renew-cert 在状态替换与状态恢复都失败时仍必须点名保留的新证书。
    writeCfSandbox(cfState('cloudflare'));
    // 合并 2>&1 到同一流：先后顺序必须可判定，不能事后拼接两路输出。
    const mvFail = run('bash', ['-c', 'exec "$0" renew-cert 2>&1', easyAll],
        cfEnv({ CF_FAIL_STATE_MV: '1' }));
    assert.equal(mvFail.status, 1, 'renew-cert must fail when the state file cannot be replaced');
    const mvFailOut = mvFail.stdout;
    assert.ok(mvFailOut.includes('原子恢复状态文件失败'),
        `state restore must really fail in this scenario: ${mvFailOut}`);
    const mvFailIdIndex = mvFailOut.search(/cert-new-\d+/);
    const mvFailRestoreIndex = mvFailOut.indexOf('原子恢复状态文件失败');
    assert.ok(mvFailIdIndex >= 0 && mvFailIdIndex < mvFailRestoreIndex,
        `retained certificate must be reported before the restore failure: ${mvFailOut}`);
    assert.ok(mvFailOut.includes('cf.example.com'), mvFailOut);
    assert.ok(!readFileSync(cfApiLog, 'utf8').includes('-X DELETE'),
        'failed rotation must not revoke any certificate');

} else {
    console.log('skip - root 下跳过 Cloudflare CLI 生命周期用例（无法安全隔离 /etc 系统路径）');
}

// 测试沙箱含临时 CA 私钥与配置，退出时（成功或失败）统一清理，避免 /tmp 泄漏。
process.on('exit', () => {
    for (const dir of [isolationRoot, sandboxRoot, cfRoot]) {
        try {
            rmSync(dir, { recursive: true, force: true });
        } catch {
            // 清理失败不影响测试结论
        }
    }
});

console.log('ok - CLI end-to-end tests passed');
