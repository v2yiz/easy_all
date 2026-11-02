import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import { writeFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bunnyApi = join(root, 'lib/bunny-api.py');
const tempDir = mkdtempSync(join(tmpdir(), 'bunny-e2e-'));

function run(args = []) {
    return spawnSync('python3', [bunnyApi, ...args], { encoding: 'utf8' });
}

try {
    // 1. 帮助命令与入口（核心路径）
    const helpRes = run(['--help']);
    assert.equal(helpRes.status, 0);
    assert.ok(helpRes.stdout.includes('apply'));
    assert.ok(helpRes.stdout.includes('ips'));

    // 2. IP 列表解析（核心路径）
    const ipsJson = join(tempDir, 'ips.json');
    writeFileSync(ipsJson, JSON.stringify(['192.0.2.1', '198.51.100.0/24']));
    const ipsRes = run(['ips', '--input', ipsJson]);
    assert.equal(ipsRes.status, 0);
    assert.ok(ipsRes.stdout.includes('192.0.2.1/32'));
    assert.ok(ipsRes.stdout.includes('198.51.100.0/24'));

    // 3. 配置文件校验（核心路径）
    const validConfig = join(tempDir, 'valid-config.json');
    writeFileSync(validConfig, JSON.stringify({
        zone: 'example.com',
        origin: 'origin.example.com',
        cdn: 'cdn.example.com',
        ipv4: '1.2.3.4',
        name: 'test-pull-zone',
        secret: '0123456789abcdef0123456789abcdef',
    }));
    const validRes = run(['validate-config', '--config', validConfig]);
    assert.equal(validRes.status, 0, 'Valid config should pass validation');

    // 4. 关键失败场景：缺失必须字段
    const missingFieldConfig = join(tempDir, 'missing-field.json');
    writeFileSync(missingFieldConfig, JSON.stringify({
        zone: 'example.com',
        origin: 'origin.example.com',
    }));
    const missingRes = run(['validate-config', '--config', missingFieldConfig]);
    assert.equal(missingRes.status, 1, 'Missing fields should fail validation');
    assert.ok(missingRes.stderr.includes('Missing config field'));

    // 5. 关键失败场景：非法 IPv4
    const badIpConfig = join(tempDir, 'bad-ip.json');
    writeFileSync(badIpConfig, JSON.stringify({
        zone: 'example.com',
        origin: 'origin.example.com',
        cdn: 'cdn.example.com',
        ipv4: '999.999.999.999',
        name: 'test-pull-zone',
        secret: '0123456789abcdef0123456789abcdef',
    }));
    const badIpRes = run(['validate-config', '--config', badIpConfig]);
    assert.equal(badIpRes.status, 1, 'Invalid IP should fail validation');
    assert.ok(badIpRes.stderr.includes('Invalid ipv4'));
} finally {
    rmSync(tempDir, { recursive: true, force: true });
}

console.log('ok - Bunny API end-to-end tests passed');
