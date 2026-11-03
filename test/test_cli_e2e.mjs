import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, unlinkSync } from 'node:fs';
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
    assert.ok(res.stdout.includes('Bunny CDN'), 'Help should list Bunny CDN mode');
    assert.ok(res.stdout.includes('Gcore CDN'), 'Help should list Gcore CDN mode');
    assert.ok(res.stdout.includes('组合'), 'Help should list combined mode');
    assert.ok(res.stdout.includes('cleanup-partial'), 'Help should list cleanup-partial');
}

// 2. Gcore 孤儿资源清理命令：帮助可用，且不依赖本机安装状态
const purgeHelp = run(easyAll, ['purge-gcore', '--help']);
assert.equal(purgeHelp.status, 0, purgeHelp.stderr);
assert.ok(purgeHelp.stdout.includes('purge-gcore'), 'purge-gcore help should show usage');

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

// 2.6 cleanup-partial 参数校验（root 之前就校验，非 root 环境也能覆盖）
const cleanupHelp = run(easyAll, ['cleanup-partial', '--help']);
assert.equal(cleanupHelp.status, 0, cleanupHelp.stderr);
assert.ok(
    cleanupHelp.stdout.includes('--assume-mode'),
    'cleanup-partial help should document --assume-mode',
);
// 必须隔离：root + FORCE=1 下若状态与 marker 都"不存在"，这条命令会执行真实清理。
const cleanupIsolation = {
    FORCE: '0',
    EASY_ALL_STATE_FILE_OVERRIDE: join(tmpdir(), `no-state-${Date.now()}.env`),
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE: join(tmpdir(), `no-progress-${Date.now()}.env`),
};
const cleanupNumericMode = run(easyAll, ['cleanup-partial', '--assume-mode', '5'], cleanupIsolation);
assert.equal(cleanupNumericMode.status, 1, 'cleanup-partial must not succeed in the test environment');
assert.ok(
    !cleanupNumericMode.stderr.includes('不支持的安装模式'),
    'menu number 5 must be accepted as a mode alias',
);
if (process.getuid && process.getuid() === 0) {
    // root 下别名已被接受并走到非交互守卫；FORCE=0 + 管道 stdin 会在这里拒绝，
    // 不会加载 profile、不会取写锁、不会清理任何路径。
    assert.ok(
        cleanupNumericMode.stderr.includes('非交互清理必须显式设置 FORCE=1'),
        'root run should stop at the non-interactive FORCE guard',
    );
} else {
    assert.ok(
        cleanupNumericMode.stderr.includes('请使用 root 用户运行此脚本'),
        'non-root run should stop at the root check',
    );
}
const cleanupBadMode = run(easyAll, ['cleanup-partial', '--assume-mode', 'nope']);
assert.equal(cleanupBadMode.status, 1, 'unknown mode must be rejected');
assert.ok(
    cleanupBadMode.stderr.includes('不支持的安装模式'),
    'cleanup-partial should reject unknown --assume-mode',
);

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
    assert.ok(cfRes.stderr.includes('仅适用于 CDN 精选 IP 模式'));

    // Bunny 模式：不支持 Reality 专属与直连专属命令
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="bunny-ws"\n');
    const realityTargetRes = run(easyAll, ['reality-target'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(realityTargetRes.status, 1);
    assert.ok(realityTargetRes.stderr.includes('仅适用于 Reality 与组合模式'));

    const rotateRes = run(easyAll, ['rotate-dynamic-ports'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(rotateRes.status, 1);
    assert.ok(rotateRes.stderr.includes('仅适用于 Reality 模式'));

    // 组合模式：只提供三入口与订阅，不提供配额、动态端口与 Bunny 专属命令
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="combined"\n');
    for (const [command, message] of [
        ['quota-status', '组合模式不启用用户配额'],
        ['rotate-dynamic-ports', '仅适用于 Reality 模式'],
        ['refresh-origin-ips', '仅适用于 Bunny 模式'],
        ['cert-renew', '仅适用于 Bunny 模式'],
    ]) {
        const res = run(easyAll, [command], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
        assert.equal(res.status, 1, `${command} must be rejected in combined mode`);
        assert.ok(res.stderr.includes(message), `${command}: ${res.stderr}`);
    }

    // Gcore 模式：不支持 Reality 专属命令
    writeFileSync(stateFile, 'STATE_VERSION="0"\nPROTOCOL="gcore"\n');
    const gcoreRotateRes = run(easyAll, ['rotate-dynamic-ports'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(gcoreRotateRes.status, 1);
    assert.ok(gcoreRotateRes.stderr.includes('仅适用于 Reality 模式'));
} finally {
    try { unlinkSync(stateFile); } catch {}
}

console.log('ok - CLI end-to-end tests passed');
