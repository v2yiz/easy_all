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
        {
            type: 'trojan',
            name: 'Optional Trojan',
            host: 'trojan.example.com',
            port: 9443,
            password: 'test-password-0123456789abcdef',
            sni: 'trojan.example.com',
            alpn: ['http/1.1'],
            fp: 'chrome',
            optional: true,
        },
    ];
    config.externalSubUrl = 'https://subscription.example.com/removed-url-sentinel';
    config.fallbackCdnNodes = [];
    const configPath = join(temp, 'config.json');
    const workerPath = join(temp, 'worker.mjs');
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath: workerPath });

    const source = await readFile(workerPath, 'utf8');
    const externalCalls = [];
    const standalone = vm.runInNewContext(
        source.replace(/export default \{[\s\S]*$/, '({ fetch: handleRequest });'),
        {
            URL, URLSearchParams, Headers, Response, AbortController,
            TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout,
            fetch: async url => {
                externalCalls.push(url);
                return new Response('ss://example#Removed');
            },
            console: { error() {}, warn() {} },
        }
    );
    for (const flag of ['clash', 'base64']) {
        for (const all of [false, true]) {
            for (const method of ['GET', 'HEAD']) {
                const response = await standalone.fetch(new Request(
                    `https://worker.invalid/subscribe?token=${config.allowedTokens.owner}&flag=${flag}${all ? '&node=all' : ''}`,
                    { method }
                ));
                assert.equal(response.status, 200);
                const body = await response.text();
                if (method !== 'HEAD') {
                    const content = flag === 'base64' ? atob(body) : body;
                    assert.ok(content.includes('visible.example.com'));
                    assert.equal(content.includes('optional.example.com'), all);
                    assert.equal(content.includes('trojan.example.com'), all);
                    if (all) {
                        if (flag === 'clash') {
                            assert.ok(content.includes('    type: trojan'));
                            assert.ok(content.includes('    port: 9443'));
                            assert.ok(content.includes('      - "http/1.1"'));
                        } else {
                            assert.ok(content.includes('trojan://'));
                            assert.ok(content.includes('@trojan.example.com:9443?'));
                        }
                    }
                    const count = flag === 'base64'
                        ? content.split('\n').length
                        : (content.split('\nproxy-groups:')[0].match(/^  - name:/gm) || []).length;
                    assert.equal(count, all ? 3 : 1, 'only configured direct nodes are returned');
                    assert.ok(!/xflash|#Removed/.test(content));
                } else {
                    assert.equal(body, '');
                }
                assert.equal(externalCalls.length, 0, 'standalone Worker must never request the removed external source');
                assert.equal(response.headers.get('X-Easy-All-Warning'), null);
            }
        }
    }
    assert.ok(!source.includes(config.externalSubUrl), 'generated Worker must strip the old URL');
    config.vpsSubUrl = 'https://source.invalid/subscribe';
    config.vpsCdnUseRequestToken = true;
    config.requireDynamicCdn = true;
    config.sourceSecret = 'fixture-own-source-secret';
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath: workerPath });
    const ownSourceCalls = [];
    const ownSourceWorker = vm.runInNewContext(
        (await readFile(workerPath, 'utf8')).replace(/export default \{[\s\S]*$/, '({ fetch: handleRequest });'),
        {
            URL, URLSearchParams, Headers, Response, AbortController,
            TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout,
            fetch: async (url, options) => {
                ownSourceCalls.push(url);
                const requested = new URL(url);
                assert.equal(requested.origin + requested.pathname, config.vpsSubUrl);
                assert.equal(requested.searchParams.get('token'), config.allowedTokens.owner);
                assert.equal(requested.searchParams.get('flag'), 'base64');
                assert.equal(options.headers.get('X-Easy-All-Worker-Source'), config.sourceSecret);
                assert.equal(options.cache, 'no-store');
                assert.ok(options.signal instanceof AbortSignal);
                const primary = `vless://${baseNode.uuid}@192.0.2.1:443?security=tls&type=xhttp&host=cdn.example.com&path=%2Fxhttp#Primary`;
                const backup = primary.replace('192.0.2.1', '192.0.2.2')
                    .replace('?security=', '?easyAllBackup=1&security=');
                return new Response(btoa(primary + '\n' + backup));
            },
            console: { error() {}, warn() {} },
        }
    );
    for (const flag of ['clash', 'base64']) {
        for (const all of [false, true]) {
            for (const method of ['GET', 'HEAD']) {
                const response = await ownSourceWorker.fetch(new Request(
                    `https://worker.invalid/subscribe?token=${config.allowedTokens.owner}&flag=${flag}${all ? '&node=all' : ''}`,
                    { method }
                ));
                assert.equal(response.status, 200);
                assert.equal(response.headers.get('X-Easy-All-CDN-Nodes'), '2');
                assert.equal(response.headers.get('X-Easy-All-Warning'), null);
                assert.equal(response.headers.get('X-Easy-All-CDN-Warning'), null);
                const body = await response.text();
                if (method === 'HEAD') {
                    assert.equal(body, '');
                    continue;
                }
                const content = flag === 'base64' ? decodeURIComponent(atob(body)) : body;
                assert.ok(content.includes('visible.example.com'));
                assert.equal(content.includes('optional.example.com'), all);
                assert.equal(content.includes('trojan.example.com'), all);
                assert.ok(content.includes('192.0.2.1') && content.includes('192.0.2.2'));
                assert.ok(content.includes('🇺🇸优选1') && content.includes('🇭🇰CF1'));
                assert.ok(!/xflash|#Removed/.test(content));
                const count = flag === 'base64'
                    ? content.split('\n').length
                    : (content.split('\nproxy-groups:')[0].match(/^  - name:/gm) || []).length;
                assert.equal(count, all ? 5 : 3, 'only configured direct and own-source nodes are returned');
            }
        }
    }
    assert.equal(ownSourceCalls.length, 8, 'each GET/HEAD fetches only the own source once');
    config.externalSubUrl = { obsolete: true };
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath: workerPath });
    assert.ok(!(await readFile(workerPath, 'utf8')).includes('"externalSubUrl":'), 'legacy fields are inert regardless of value type');

    const handleRequest = vm.runInNewContext(
        source.replace(/export default \{[\s\S]*$/, `
        createWorkerHandler({
            allowedTokenValues: new Set(['test']),
            localNodes: LOCAL_NODES,
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
                assert.ok(content.includes('trojan.example.com'));
            } else {
                assert.ok(!content.includes('optional.example.com'));
                assert.ok(!content.includes('trojan.example.com'));
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

    for (const failure of [403, 429, 500, 503, 'network']) {
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
