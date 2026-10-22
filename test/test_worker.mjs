import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import vm from 'node:vm';
import { buildWorker } from '../scripts/build-worker.mjs';

const temp = await mkdtemp(join(tmpdir(), 'worker-visibility-test-'));
try {
    const config = JSON.parse(await readFile(
        new URL('../worker-src/config.example.json', import.meta.url),
        'utf8'
    ));
    const baseNode = config.nodes[0];
    config.allowedTokens = { owner: 'offline-test-token' };
    config.nodes = [
        { ...baseNode, name: 'Visible Reality', host: 'visible.example.com' },
        {
            ...baseNode,
            name: 'Optional Reality',
            host: 'optional.example.com',
            optional: true,
        },
    ];
    const configPath = join(temp, 'config.json');
    const workerPath = join(temp, 'worker.mjs');
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath: workerPath });

    const source = await readFile(workerPath, 'utf8');
    const handleRequest = vm.runInNewContext(
        source.replace(/export default \{[\s\S]*$/, `
        createWorkerHandler({
            allowedTokenValues: new Set(['test']),
            localNodes: LOCAL_NODES,
            externalSubUrl: 'https://upstream.invalid',
            vpsSubUrl: '',
            requireDynamicCdn: false,
        });
        `),
        {
            URL, URLSearchParams, Headers, Response, AbortController,
            TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout,
            fetch: async () => { throw new Error('Offline test'); },
            console: { error() {}, warn() {} },
        }
    );

    for (const flag of ['clash', 'base64']) {
        for (const node of ['', '&node=all', '&node=other', '&node=']) {
            const response = await handleRequest(new Request(
                `https://worker.invalid/subscribe?token=test&flag=${flag}${node}`
            ));
            assert.equal(response.status, 200);
            const body = await response.text();
            const content = flag === 'base64' ? atob(body) : body;
            if (node === '&node=all') {
                assert.ok(content.includes('optional.example.com'));
            } else {
                assert.ok(!content.includes('optional.example.com'));
            }
            assert.ok(content.includes('visible.example.com'));
        }
    }
    const createWorkerHandler = vm.runInNewContext(
        source.replace(/export default \{[\s\S]*$/, 'createWorkerHandler;'),
        {
            URL, URLSearchParams, Headers, Response, AbortController,
            TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout,
            fetch: async () => { throw new Error('Offline test'); },
            console: { error() {}, warn() {} },
        }
    );
    const makeDelegate = (fetchImpl, now = () => 0) => createWorkerHandler({
        allowedTokenValues: new Set(),
        localNodes: [],
        externalSubUrl: '',
        vpsSubUrl: 'https://source.invalid/subscribe',
        vpsCdnUseRequestToken: true,
        delegateTokenValidation: true,
        requireDynamicCdn: true,
        now,
        fetchImpl,
    });
    const request = (token, method = 'GET') => new Request(
        `https://worker.invalid/subscribe?token=${token}&flag=base64`, { method }
    );
    const validSource = `vless://${baseNode.uuid}@192.0.2.1:443?security=tls&type=ws&host=cdn.example.com&path=%2Fws#CDN`;
    let clock = 0;
    const calls = [];
    const delegated = makeDelegate(async url => {
        const token = new URL(url).searchParams.get('token');
        calls.push(token);
        return token === 'valid-token'
            ? new Response(validSource)
            : new Response('Forbidden', { status: 403 });
    }, () => clock);
    const firstDenied = await delegated(request('invalid-token'));
    assert.equal(firstDenied.status, 403);
    const cachedDenied = await delegated(request('invalid-token'));
    assert.equal(cachedDenied.status, 403);
    assert.deepEqual([...cachedDenied.headers], [...firstDenied.headers]);
    assert.equal(calls.length, 1, 'repeated denied token must not fetch the source');
    assert.equal(firstDenied.headers.get('X-Easy-All-CDN-Warning'), 'source-unavailable');
    const cachedHead = await delegated(request('invalid-token', 'HEAD'));
    assert.equal(cachedHead.status, 403);
    assert.equal(await cachedHead.text(), '');
    assert.equal(cachedHead.headers.get('X-Easy-All-CDN-Warning'), 'source-unavailable');
    assert.equal(cachedHead.headers.get('X-Easy-All-Version'), firstDenied.headers.get('X-Easy-All-Version'));
    clock = 59_999;
    assert.equal((await delegated(request('invalid-token'))).status, 403);
    assert.equal(calls.length, 1, '403 remains cached before the TTL');
    for (let i = 0; i < 2; i++) {
        assert.equal((await delegated(request('valid-token'))).status, 200);
    }
    assert.equal(calls.filter(token => token === 'valid-token').length, 2, 'success is not cached');
    clock = 60_000;
    assert.equal((await delegated(request('invalid-token'))).status, 403);
    assert.equal(calls.filter(token => token === 'invalid-token').length, 2, 'TTL expiry must fetch again');

    for (const failure of [403, 500, 'network']) {
        let failureCalls = 0;
        const failing = makeDelegate(async () => {
            failureCalls++;
            if (failure === 'network') throw new Error('private source diagnostic');
            return new Response('failed', { status: failure });
        });
        for (let i = 0; i < 2; i++) {
            const response = await failing(request('failure-token'));
            assert.equal(response.status, failure === 403 ? 403 : 502);
            assert.equal(response.headers.get('X-Easy-All-CDN-Warning'), 'source-unavailable');
        }
        assert.equal(failureCalls, failure === 403 ? 1 : 2, 'only 403 is cached');
    }

    let embeddedCalls = 0;
    const embedded = createWorkerHandler({
        allowedTokenValues: new Set(['known-token']),
        localNodes: [],
        externalSubUrl: '',
        vpsSubUrl: 'https://source.invalid/subscribe',
        delegateTokenValidation: false,
        requireDynamicCdn: true,
        fetchImpl: async () => {
            embeddedCalls++;
            return new Response('Forbidden', { status: 403 });
        },
    });
    for (let i = 0; i < 2; i++) {
        const response = await embedded(request('known-token'));
        assert.equal(response.status, 502);
        assert.ok(response.headers.get('X-Easy-All-CDN-Warning').includes('HTTP 403'));
    }
    assert.equal(embeddedCalls, 2, 'embedded-token mode retains its source behavior');

    let evictionCalls = 0;
    const bounded = makeDelegate(async () => {
        evictionCalls++;
        return new Response('Forbidden', { status: 403 });
    });
    for (let i = 0; i <= 500; i++) {
        assert.equal((await bounded(request(`invalid-${i}`))).status, 403);
    }
    await bounded(request('invalid-1'));
    assert.equal(evictionCalls, 501, 'recent entries stay cached at the capacity limit');
    await bounded(request('invalid-0'));
    assert.equal(evictionCalls, 502, 'oldest entry is evicted after 500 tokens');
} finally {
    await rm(temp, { recursive: true, force: true });
}
console.log('Worker node visibility and delegated validation checks passed');
