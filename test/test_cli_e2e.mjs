import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, readFileSync, unlinkSync, chmodSync, existsSync, statSync, mkdirSync } from 'node:fs';
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
    assert.ok(res.stdout.includes('纯 CDN'), 'Help should list the CDN-only mode');
    assert.ok(res.stdout.includes('直连+CDN'), 'Help should list the combined mode');
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

    // 完整的新 CloudFront 状态：模式专属命令门禁。
    writeFileSync(stateFile, cloudfrontState);
    const rejectedInCloudFront = [
        ['reality-target', ['example.com:443'], '仅适用于 Reality 与直连+CDN模式'],
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

console.log('ok - CLI end-to-end tests passed');
