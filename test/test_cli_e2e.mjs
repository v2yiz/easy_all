import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, unlinkSync, chmodSync, existsSync } from 'node:fs';
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

try {
    // Reality 模式：不支持 CDN 刷新
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="reality"\n');
    const cfRes = run(easyAll, ['refresh-cdn-ips'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(cfRes.status, 1);
    assert.ok(cfRes.stderr.includes('仅适用于纯 CDN 与直连+CDN模式'), cfRes.stderr);

    // 两种 CDN 模式：都提供 apply-cloud / refresh-cdn-ips / 订阅，不提供 Reality 专属命令
    for (const mode of ['cdn', 'combined']) {
        writeFileSync(stateFile, `STATE_VERSION="0"\nPROTOCOL="${mode}"\n`);
        for (const [command, message] of [
            ['rotate-dynamic-ports', '仅适用于 Reality 模式'],
        ]) {
            const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
            assert.equal(res.status, 1, `${command} must be rejected in ${mode} mode`);
            assert.ok(res.stderr.includes(message), `${command}: ${res.stderr}`);
        }
    }
    // 纯 CDN 模式没有 Reality 直连入口，reality-target 必须被拒绝
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="cdn"\n');
    const cdnRealityTarget = run(easyAll, ['reality-target', 'example.com:443'], {
        EASY_ALL_STATE_FILE_OVERRIDE: stateFile,
    });
    assert.equal(cdnRealityTarget.status, 1, 'reality-target must be rejected in cdn mode');
    assert.ok(cdnRealityTarget.stderr.includes('仅适用于 Reality 与直连+CDN模式'), cdnRealityTarget.stderr);
    // 已随模式移除的命令不再存在
    for (const command of ['refresh-origin-ips', 'cert-renew']) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must no longer exist`);
    }

    // 不认识的状态协议：明确拒绝并退出
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="unknown"\n');
    const unknownRes = run(easyAll, ['rotate-dynamic-ports'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(unknownRes.status, 1);
    assert.ok(unknownRes.stderr.includes('无法识别已安装协议'), unknownRes.stderr);
} finally {
    try { unlinkSync(stateFile); } catch {}
}

console.log('ok - CLI end-to-end tests passed');
