import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildWorker } from '../scripts/build-worker.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const tempDir = await mkdtemp(join(tmpdir(), 'worker-e2e-'));

try {
    // 1. 构建配置边界校验（关键失败场景）
    const invalidConfigPath = join(tempDir, 'invalid-config.json');
    await writeFile(invalidConfigPath, JSON.stringify({ allowedTokens: {} }));
    await assert.rejects(
        buildWorker({ configPath: invalidConfigPath, outputPath: join(tempDir, 'invalid-out.mjs') }),
        /tokens must be unique strings/,
        'Build should fail on invalid allowedTokens'
    );

    // 2. 正常配置构建 Worker（核心路径）
    const exampleConfig = JSON.parse(await readFile(join(root, 'worker-src/config.example.json'), 'utf8'));
    exampleConfig.allowedTokens = { user: 'test-token-12345678' };
    const validConfigPath = join(tempDir, 'valid-config.json');
    const workerOutPath = join(tempDir, 'worker.mjs');
    await writeFile(validConfigPath, JSON.stringify(exampleConfig));
    await buildWorker({ configPath: validConfigPath, outputPath: workerOutPath });

    // 3. HTTP 订阅服务调用（核心路径与关键失败）
    const worker = (await import(workerOutPath)).default;

    // 3.1 核心成功路径：合法 Token 请求 Base64 订阅
    const base64Req = new Request('https://worker.test/subscribe?token=test-token-12345678');
    const base64Resp = await worker.fetch(base64Req);
    assert.equal(base64Resp.status, 200, 'Valid token should return 200');
    const base64Body = await base64Resp.text();
    const decodedLinks = atob(base64Body);
    assert.ok(decodedLinks.includes('vless://'), 'Decoded subscription should contain vless links');

    // 3.2 核心成功路径：Clash/Mihomo 客户端请求 YAML 订阅
    const clashReq = new Request('https://worker.test/subscribe?token=test-token-12345678', {
        headers: { 'User-Agent': 'ClashMeta; easy_all-client' },
    });
    const clashResp = await worker.fetch(clashReq);
    assert.equal(clashResp.status, 200, 'Clash request should return 200');
    const clashYaml = await clashResp.text();
    assert.ok(clashYaml.includes('proxies:'), 'Clash subscription should contain proxies key');
    assert.ok(clashYaml.includes('proxy-groups:'), 'Clash subscription should contain proxy-groups key');

    // 3.3 关键失败场景：无效 Token
    const badTokenReq = new Request('https://worker.test/subscribe?token=wrong-token');
    const badTokenResp = await worker.fetch(badTokenReq);
    assert.equal(badTokenResp.status, 403, 'Invalid token should return 403');

    // 3.4 关键失败场景：缺失 Token
    const noTokenReq = new Request('https://worker.test/subscribe');
    const noTokenResp = await worker.fetch(noTokenReq);
    assert.equal(noTokenResp.status, 403, 'Missing token should return 403');

    // 3.5 关键失败场景：未定义路由
    const notFoundReq = new Request('https://worker.test/invalid-endpoint?token=test-token-12345678');
    const notFoundResp = await worker.fetch(notFoundReq);
    assert.equal(notFoundResp.status, 404, 'Unknown endpoint should return 404');
} finally {
    await rm(tempDir, { recursive: true, force: true });
}

console.log('ok - Worker end-to-end tests passed');
