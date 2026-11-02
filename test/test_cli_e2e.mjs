import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, unlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const easyAll = join(root, 'easy_all');
const bootstrap = join(root, 'bootstrap.sh');

function run(cmd, args = [], env = {}) {
    return spawnSync(cmd, args, {
        encoding: 'utf8',
        env: { ...process.env, ...env },
    });
}

// 1. CLI 帮助与用法（核心路径）
for (const arg of ['help', '--help', '-h']) {
    const res = run(easyAll, [arg]);
    assert.equal(res.status, 0, `easy_all ${arg} should exit with 0`);
    assert.ok(res.stdout.includes('用法: easy_all [命令]'), 'Help should show usage');
    assert.ok(res.stdout.includes('Reality'), 'Help should list Reality mode');
    assert.ok(res.stdout.includes('Bunny CDN'), 'Help should list Bunny CDN mode');
    assert.ok(res.stdout.includes('Mieru'), 'Help should list Mieru mode');
}

// 2. 未安装状态调用命令（关键失败场景）
const uninstalledRes = run(easyAll, ['status'], {
    EASY_ALL_STATE_FILE_OVERRIDE: join(tmpdir(), 'nonexistent-easy-all-state.env'),
});
assert.equal(uninstalledRes.status, 1, 'Status without installation should exit 1');
assert.ok(
    uninstalledRes.stderr.includes('尚未安装') || uninstalledRes.stdout.includes('尚未安装'),
    'Should notify user that easy_all is not installed'
);

// 3. 非交互环境调用 bootstrap.sh 守卫（关键失败场景）
const bootstrapRes = run('bash', [bootstrap], { stdio: 'pipe' });
assert.equal(bootstrapRes.status, 1, 'bootstrap.sh in non-interactive shell must exit 1');
assert.ok(
    bootstrapRes.stderr.includes('交互终端') || bootstrapRes.stdout.includes('交互终端'),
    'bootstrap.sh should warn against curl | bash without a tty'
);

// 4. 用户视角下的模式专属命令边界路由（核心路径与关键失败校验）
const stateFile = join(tmpdir(), `easy-all-test-state-${Date.now()}.env`);

try {
    // Reality 模式：不支持 CDN 刷新
    writeFileSync(stateFile, 'STATE_VERSION="6"\nPROTOCOL="reality"\n');
    const cfRes = run(easyAll, ['refresh-cdn-ips'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(cfRes.status, 1);
    assert.ok(cfRes.stderr.includes('仅适用于 CDN 精选 IP 模式'));

    // Bunny 模式：不支持 Reality 专属与直连专属命令
    writeFileSync(stateFile, 'STATE_VERSION="2"\nPROTOCOL="bunny-ws"\n');
    const realityTargetRes = run(easyAll, ['reality-target'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(realityTargetRes.status, 1);
    assert.ok(realityTargetRes.stderr.includes('仅适用于 Reality 模式'));

    const rotateRes = run(easyAll, ['rotate-dynamic-ports'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(rotateRes.status, 1);
    assert.ok(rotateRes.stderr.includes('仅适用于直连模式'));

    // Mieru 模式：不支持 TLS 证书续期
    writeFileSync(stateFile, 'STATE_VERSION="2"\nPROTOCOL="mieru"\n');
    const certRes = run(easyAll, ['renew-cert'], { EASY_ALL_STATE_FILE_OVERRIDE: stateFile });
    assert.equal(certRes.status, 1);
    assert.ok(certRes.stderr.includes('Mieru 模式不使用 TLS 证书'));
} finally {
    try { unlinkSync(stateFile); } catch {}
}

console.log('ok - CLI end-to-end tests passed');
