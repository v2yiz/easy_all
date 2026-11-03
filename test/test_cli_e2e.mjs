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
    assert.ok(res.stdout.includes('Gcore CDN'), 'Help should list Gcore CDN mode');
    assert.ok(res.stdout.includes('组合'), 'Help should list combined mode');
}

// 2. Gcore 孤儿资源清理命令：帮助可用，且不依赖本机安装状态
const purgeHelp = run(easyAll, ['purge-gcore', '--help']);
assert.equal(purgeHelp.status, 0, purgeHelp.stderr);
assert.ok(purgeHelp.stdout.includes('purge-gcore'), 'purge-gcore help should show usage');

const purgeCfHelp = run(easyAll, ['purge-cloudflare', '--help']);
assert.equal(purgeCfHelp.status, 0, purgeCfHelp.stderr);
assert.ok(purgeCfHelp.stdout.includes('purge-cloudflare'), 'purge-cloudflare help should show usage');

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
