import assert from 'node:assert/strict';
import { mkdtemp, readFile, writeFile, mkdir, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { aggregateHandler } from '../aggregate/aggregate.mjs';

const dir = await mkdtemp(join(tmpdir(), 'aggregate-test-'));
try {
    const config = JSON.parse(await readFile(new URL('../worker-src/config.example.json', import.meta.url), 'utf8'));
    config.allowedTokens = { alice: 'alice-token-123456789', bob: 'bob-token-1234567890' };
    const path = join(dir, 'aggregate.json');
    await writeFile(path, JSON.stringify(config));
    await mkdir(join(dir, 'alice'));
    const local = `vless://${config.nodes[0].uuid}@192.0.2.1:443?security=tls&type=xhttp&host=cdn.example.com&path=%2Fxhttp%2F#Local`;
    await writeFile(join(dir, 'alice/base64.txt'), btoa(local));
    let calls = 0;
    const handle = await aggregateHandler(path, { subscriptionDir: dir, fetchImpl: async (url, options) => {
        calls++;
        assert.equal(url, config.upstreamUrl, 'only XFLASH is fetched remotely');
        return new Response(/clash/i.test(options.headers.get('User-Agent')) ? 'proxies:\n  - name: Remote\n    type: ss\n    server: remote.example.com\n' : 'ss://example#Remote');
    } });
    const request = (token, ua = 'v2rayN') => new Request(`http://localhost/aggregate?token=${token}`, { headers: { 'User-Agent': ua } });
    assert.equal((await handle(request('bad'))).status, 403);
    assert.equal(calls, 0);
    for (const ua of ['v2rayN', 'clash-verge']) {
        const response = await handle(request(config.allowedTokens.alice, ua));
        assert.equal(response.status, 200);
        assert.equal(response.headers.get('X-Easy-All-CDN-Nodes'), '1');
        const raw = await response.text();
        const body = ua === 'v2rayN' ? atob(raw) : raw;
        assert.ok(body.includes('192.0.2.1') && body.includes('Remote'));
    }
    assert.equal((await handle(request(config.allowedTokens.bob))).status, 503, 'no cross-user fallback');
    config.allowedTokens.alice = 'replacement-token-123456';
    await writeFile(path, JSON.stringify(config));
    assert.equal((await handle(request('alice-token-123456789'))).status, 403, 'config reload revokes old tokens');
    assert.equal((await handle(request(config.allowedTokens.alice))).status, 200);
    await writeFile(join(dir, 'alice/base64.txt'), 'invalid');
    assert.equal((await handle(request(config.allowedTokens.alice))).status, 503);
    console.log('Aggregate local nodes, UA formats, reload and user isolation checks passed');
} finally { await rm(dir, { recursive: true, force: true }); }
