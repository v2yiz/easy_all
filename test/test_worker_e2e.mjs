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
    assert.ok(clashYaml.includes('sniffer:'), 'Non-iOS Clash subscription should contain sniffer');

    // 3.2a 双保险平台自适应：iOS UA 命中则自动剥离嗅探
    const iosUaReq = new Request('https://worker.test/subscribe?token=test-token-12345678', {
        headers: { 'User-Agent': 'Stash/2.6.2 (iOS 17.5.1; iPhone14,2)' },
    });
    const iosUaResp = await worker.fetch(iosUaReq);
    assert.equal(iosUaResp.status, 200, 'iOS UA request should return 200');
    const iosUaYaml = await iosUaResp.text();
    assert.ok(iosUaYaml.includes('proxies:'), 'iOS UA subscription should contain proxies key');
    assert.ok(!iosUaYaml.includes('sniffer:'), 'iOS UA subscription should not contain sniffer');

    // 3.2a2 “ios”必须是独立单词：Studios/Radios 这类桌面端 UA 不能被误判为 iOS
    const studioReq = new Request(clashReq.url, {
        headers: { 'User-Agent': 'ClashMeta; Studios/1.0 (Macintosh; Intel Mac OS X 14_0)' },
    });
    const studioResp = await worker.fetch(studioReq);
    assert.equal(studioResp.status, 200, 'Studios UA request should return 200');
    const studioYaml = await studioResp.text();
    assert.ok(studioYaml.includes('sniffer:'), 'UA containing Studios must not be treated as iOS');

    // 3.2b 双保险平台自适应：显式参数 os=ios 命中则剥离嗅探（即便 UA 非 iOS）
    const paramIosReq = new Request('https://worker.test/subscribe?token=test-token-12345678&os=ios', {
        headers: { 'User-Agent': 'ClashMeta; easy_all-client' },
    });
    const paramIosResp = await worker.fetch(paramIosReq);
    assert.equal(paramIosResp.status, 200, 'os=ios param request should return 200');
    const paramIosYaml = await paramIosResp.text();
    assert.ok(paramIosYaml.includes('proxies:'), 'os=ios subscription should contain proxies key');
    assert.ok(!paramIosYaml.includes('sniffer:'), 'os=ios subscription should not contain sniffer');

    // 3.2c 自定义模板把 sniffer 写成行尾注释时，Worker 侧也必须能剥离（构建期校验允许该写法）
    const bundledTemplate = await readFile(join(root, 'templates/mihomo.yaml'), 'utf8');
    const commentedTemplate = bundledTemplate.replace(/^sniffer:$/m, 'sniffer:  # 嗅探');
    assert.notEqual(commentedTemplate, bundledTemplate, 'commented fixture must differ from the bundled template');
    const commentedTemplatePath = join(tempDir, 'commented-template.yaml');
    await writeFile(commentedTemplatePath, commentedTemplate);
    const commentedWorkerPath = join(tempDir, 'worker-commented.mjs');
    // 临时模板与内置模板只差这一行注释，按可信模板跳过内核校验。
    process.env.MIHOMO_TEMPLATE_TRUSTED = '1';
    try {
        await buildWorker({
            configPath: validConfigPath,
            outputPath: commentedWorkerPath,
            templatePath: commentedTemplatePath,
        });
    } finally {
        delete process.env.MIHOMO_TEMPLATE_TRUSTED;
    }
    const commentedWorker = (await import(commentedWorkerPath)).default;
    const iosCommentedYaml = await (await commentedWorker.fetch(iosUaReq.clone())).text();
    assert.ok(!iosCommentedYaml.includes('sniffer:'), 'commented sniffer header must still be stripped for iOS');
    const nonIosCommentedYaml = await (await commentedWorker.fetch(clashReq.clone())).text();
    assert.ok(nonIosCommentedYaml.includes('sniffer:'), 'non-iOS subscription must keep sniffer with a commented header');

    // 3.2d 内联写法无法按段剥离：必须在构建期就被模板校验拦住，而不是下发带 sniffer 的 iOS 订阅。
    // 这里与 3.2c 一样按可信模板构建，否则“没有内核二进制”的通用报错会把真正的失败原因盖住。
    const inlineTemplatePath = join(tempDir, 'inline-template.yaml');
    await writeFile(
        inlineTemplatePath,
        commentedTemplate.replace(/^sniffer:\s+#.*$/m, 'sniffer: {enable: true}'),
    );
    process.env.MIHOMO_TEMPLATE_TRUSTED = '1';
    try {
        await assert.rejects(
            buildWorker({
                configPath: validConfigPath,
                outputPath: join(tempDir, 'worker-inline.mjs'),
                templatePath: inlineTemplatePath,
            }),
            /template validation failed/,
            'inline sniffer mapping must be rejected at build time',
        );
    } finally {
        delete process.env.MIHOMO_TEMPLATE_TRUSTED;
    }

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
