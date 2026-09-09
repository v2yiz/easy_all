import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm, stat } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import vm from 'node:vm';
import { buildWorker } from '../scripts/build-worker.mjs';

const temp = await mkdtemp(join(tmpdir(), 'worker-test-'));
try {
    const config = JSON.parse(await readFile(new URL('../worker-src/config.example.json', import.meta.url), 'utf8'));
    config.allowedTokens = { owner: 'offline-test-token' };
    config.nodes.push({ ...config.nodes[0], name: 'Hidden Reality', host: 'hidden.example.com' });
    config.nodes.push({ ...config.nodes[0], name: 'Optional VMISS', host: 'vmiss.example.com', optional: true });
    config.fallbackCdnNodes = [{ type: 'vless', security: 'tls', network: 'xhttp', name: 'Fallback CF', host: 'fallback.example.com', uuid: config.nodes[0].uuid, path: '/xhttp/', mode: 'stream-up' }];
    const configPath = join(temp, 'config.json');
    const outputPath = join(temp, 'worker.mjs');
    await writeFile(configPath, JSON.stringify(config));
    const now = Date.UTC(2026, 8, 6, 15, 59);
    assert.equal(await buildWorker({ configPath, outputPath, now }), '2026-09-06-v0');
    const initial = await readFile(outputPath, 'utf8');
    assert.equal(await buildWorker({ configPath, outputPath, now }), '2026-09-06-v1');
    const second = await readFile(outputPath, 'utf8');
    assert.equal(second.replace('2026-09-06-v1', '2026-09-06-v0'), initial, 'only version changes on rebuild');
    assert.equal(await buildWorker({ configPath, outputPath, now: now + 60_000 }), '2026-09-07-v0', 'Beijing midnight resets revision');
    let source = await readFile(outputPath, 'utf8');
    assert.equal((await stat(outputPath)).mode & 0o777, 0o600);
    config.nodes[0].ipVersion = 'dual';
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath, now: now + 120_000 });
    source = await readFile(outputPath, 'utf8');
    assert.ok(source.includes('"ipVersion":"dual"'), 'Reality nodes accept explicit dual-stack');
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath, now: now + 240_000 });
    source = await readFile(outputPath, 'utf8');
    await writeFile(configPath, '{invalid');
    await assert.rejects(buildWorker({ configPath, outputPath }));
    assert.equal(await readFile(outputPath, 'utf8'), source, 'failed build preserves artifact');
    const context = vm.createContext({ URL, URLSearchParams, Headers, Response, AbortController, TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout, fetch: async () => { throw Error('offline'); }, console: { error() {}, warn() {} } });
    const api = vm.runInContext(source.replace(/export default \{[\s\S]*$/, '({createWorkerHandler, resolveNodePorts, buildClashConfig, fetchXflashSubscription, PRIVATE_CONFIG, LOCAL_NODES});'), context);
    const make = fetchImpl => api.createWorkerHandler({ allowedTokenValues: new Set(['offline-test-token']), localNodes: api.LOCAL_NODES, externalSubUrl: config.externalSubUrl, vpsSubUrl: config.vpsSubUrl, requireDynamicCdn: false, now: () => Date.UTC(2026, 0, 1), fetchImpl });
    const request = (suffix = '', token = 'offline-test-token', method = 'GET') => new Request(`https://worker.invalid/subscribe?token=${token}&flag=clash${suffix}`, {method});
    const genericRequest = new Request('https://worker.invalid/subscribe?token=offline-test-token&flag=base64');
    let calls = 0;
    const offline = make(async () => { calls++; throw Error('offline'); });
    assert.equal((await offline(request('', 'bad'))).status, 403);
    assert.equal((await offline(new Request('https://worker.invalid/nope'))).status, 404);
    assert.equal((await offline(request('', 'offline-test-token', 'POST'))).status, 405);
    assert.equal(calls, 0, 'reject before upstream access');
    const fallback = await offline(request());
    assert.equal(fallback.headers.get('X-Easy-All-Version'), '2026-09-07-v2');
    assert.equal(fallback.headers.get('X-Easy-All-Warning'), 'xflash-unavailable-local-only');
    const fallbackBody = await fallback.text();
    assert.ok(fallbackBody.includes('ip-version: dual'));
    assert.ok(fallbackBody.includes('fallback.example.com'));
    assert.ok(fallbackBody.includes('hidden.example.com'));
    assert.ok(!fallbackBody.includes('vmiss.example.com'));
    const allBody = await (await offline(request('&node=all'))).text();
    assert.ok(allBody.includes('hidden.example.com'));
    assert.ok(allBody.includes('vmiss.example.com'));
    assert.equal(await (await offline(request('', 'offline-test-token', 'HEAD'))).text(), '');
    const upstream = `dns:\n  nameserver: [malicious.invalid]\nproxies:\n    - name: Remote\n      type: vless\n      server: remote.example.com\n      port: 443\n      uuid: ${config.nodes[0].uuid}\n      network: xhttp\n      ip-version: ipv4\n      alpn:\n        - h2\n    - { name: Mieru Remote, type: mieru, server: mieru.example.com, port: 443, username: test-user, password: test-password, transport: TCP, multiplexing: MULTIPLEXING_LOW }\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n`;
    const xmux = {
        maxConnections: 4,
        cMaxReuseTimes: 0,
        hMaxRequestTimes: '300-600',
        hMaxReusableSecs: '900-1800',
        hKeepAlivePeriod: 0,
    };
    const cfExtra = encodeURIComponent(JSON.stringify({
        uplinkHTTPMethod: 'POST',
        noGRPCHeader: false,
        xmux,
    }));
    const cf = `vless://${config.nodes[0].uuid}@192.0.2.1:443?security=tls&type=xhttp&host=cdn.example.com&path=%2Fxhttp%2F&mode=stream-up&extra=${cfExtra}#CF`;
    const live = make(async url => new Response(new URL(url).origin === new URL(config.vpsSubUrl).origin ? btoa(cf) : upstream));
    // Format must be pinned even when a copied VPS link requests Clash YAML.
    const dynamicApi = vm.runInContext('({fetchDynamicCdnNodes})', context);
    for (const encoded of [false, true]) {
        const result = await dynamicApi.fetchDynamicCdnNodes(config.vpsSubUrl + '&flag=clash', {
            fetchImpl: async (url, options) => {
                assert.equal(new URL(url).searchParams.get('flag'), 'base64');
                assert.equal(options.headers.get('User-Agent'), 'v2rayN');
                const links = [...Array(6).fill(cf.replace('type=xhttp', 'type=tcp')), ...Array(7).fill(cf)].join('\n');
                return new Response(encoded ? btoa(links) : links);
            },
        });
        assert.equal(result.error, null);
        assert.equal(result.nodes.length, 6, 'limit applies to supported nodes');
        assert.equal(result.nodes[0].name, '🇺🇸优选1');
    }
    const fixedSourceUA = await dynamicApi.fetchDynamicCdnNodes(config.vpsSubUrl, {
        userAgent: 'client-subscription/1.0',
        fetchImpl: async (_url, options) => {
            assert.equal(options.headers.get('User-Agent'), 'v2rayN');
            return new Response(btoa(cf));
        },
    });
    assert.equal(fixedSourceUA.nodes.length, 1, 'private URI source uses a stable supported UA');
    const strictByDefault = api.createWorkerHandler({
        allowedTokenValues: new Set(['offline-test-token']),
        localNodes: api.LOCAL_NODES,
        externalSubUrl: '',
        vpsSubUrl: 'https://node.example.com/subscribe',
        fetchImpl: async () => { throw new Error('source offline'); },
    });
    assert.equal(
        (await strictByDefault(new Request(
            'https://sub.example.com/subscribe?token=offline-test-token'
        ))).status,
        502,
        'a configured VPS source is required unless fallback is explicitly enabled',
    );
    let privateSourceRequest;
    const privateSourceHandler = api.createWorkerHandler({
        allowedTokenValues: new Set(),
        localNodes: [],
        externalSubUrl: '',
        vpsSubUrl: 'https://node.example.com/subscribe',
        vpsCdnUseRequestToken: true,
        delegateTokenValidation: true,
        requireDynamicCdn: true,
        sourceSecret: 'private-worker-source-secret',
        fetchImpl: async (url, options) => {
            privateSourceRequest = { url: new URL(url), options };
            return new Response(btoa(cf));
        },
    });
    const privateSourceResponse = await privateSourceHandler(new Request(
        'https://sub.example.com/subscribe?token=public-user-token&flag=base64'
    ));
    assert.equal(privateSourceResponse.status, 200);
    assert.equal(privateSourceRequest.url.hostname, 'node.example.com');
    assert.equal(privateSourceRequest.url.searchParams.get('token'), 'public-user-token');
    assert.equal(privateSourceRequest.url.searchParams.get('flag'), 'base64');
    assert.equal(
        privateSourceRequest.options.headers.get('X-Easy-All-Worker-Source'),
        'private-worker-source-secret'
    );
    assert.equal(privateSourceRequest.options.cache, 'no-store');
    assert.equal(privateSourceResponse.headers.get('X-Easy-All-Warning'), null);
    const rejectedPrivateSource = api.createWorkerHandler({
        allowedTokenValues: new Set(),
        localNodes: [],
        externalSubUrl: '',
        vpsSubUrl: 'https://node.example.com/subscribe',
        vpsCdnUseRequestToken: true,
        delegateTokenValidation: true,
        requireDynamicCdn: true,
        sourceSecret: 'private-worker-source-secret',
        fetchImpl: async () => new Response('', { status: 403 }),
    });
    assert.equal(
        (await rejectedPrivateSource(new Request(
            'https://sub.example.com/subscribe?token=unknown-user-token'
        ))).status,
        403,
        'private source authentication remains authoritative'
    );
    const unavailablePrivateSource = api.createWorkerHandler({
        allowedTokenValues: new Set(),
        localNodes: [],
        externalSubUrl: '',
        vpsSubUrl: 'https://node.example.com/subscribe',
        vpsCdnUseRequestToken: true,
        delegateTokenValidation: true,
        requireDynamicCdn: true,
        sourceSecret: 'private-worker-source-secret',
        fetchImpl: async () => { throw new Error('source offline'); },
    });
    assert.equal(
        (await unavailablePrivateSource(new Request(
            'https://sub.example.com/subscribe?token=public-user-token'
        ))).status,
        502,
        'private source failures must not fall back around quota enforcement'
    );
    let upstreamUA = '';
    await api.fetchXflashSubscription(
        { headers: new Headers({ 'User-Agent': 'curl/8.0' }) },
        config.externalSubUrl,
        {
            format: 'base64',
            fetchImpl: async (_url, options) => {
                upstreamUA = options.headers.get('User-Agent');
                return new Response(btoa(cf));
            },
        },
    );
    assert.equal(upstreamUA, 'v2rayN', 'unknown URI clients use a supported XFLASH UA');
    await api.fetchXflashSubscription(
        { headers: new Headers({ 'User-Agent': 'clash-verge/v1.7.7' }) },
        config.externalSubUrl,
        {
            format: 'clash',
            fetchImpl: async (_url, options) => {
                upstreamUA = options.headers.get('User-Agent');
                return new Response(upstream);
            },
        },
    );
    assert.equal(upstreamUA, 'mihomo/1.19.30', 'Clash aggregation advertises current Mieru support');
    for (const [status, headers, warning] of [
        [403, {}, 'HTTP 403'],
        [200, {'cf-mitigated': 'challenge'}, 'Cloudflare challenge'],
        [200, {'content-type': 'text/html'}, 'No vless links'],
    ]) {
        const response = await make(async () => new Response('<html>blocked</html>', {status, headers}))(request());
        assert.equal(response.status, 200, 'fallback warning must be a valid HTTP header');
        assert.ok(response.headers.get('X-Easy-All-CDN-Warning').includes(warning));
        assert.ok((await response.text()).includes('fallback.example.com'));
    }
    const liveResponse = await live(request());
    assert.equal(liveResponse.headers.get('X-Easy-All-Warning'), null);
    const liveBody = await liveResponse.text();
    const groups = liveBody.split('proxy-groups:\n')[1].split('rules:\n')[0];
    assert.equal((groups.match(/name:/g) || []).length, 2);
    assert.ok(groups.indexOf('name: PROXY') < groups.indexOf('name: 🇺🇸优选'));
    const proxyMembers = groups.split('name: 🇺🇸优选')[0].split('proxies:')[1].trim().split('\n').map(line => line.trim()).filter(line => line.startsWith('- "')).map(line => JSON.parse(line.slice(2)));
    assert.deepEqual(proxyMembers, ['Reality example', 'Hidden Reality', 'Remote', 'Mieru Remote', '🇺🇸优选']);
    assert.ok(!groups.includes('DIRECT'));
    const template = await readFile(new URL('../templates/mihomo.yaml', import.meta.url), 'utf8');
    for (const body of [fallbackBody, liveBody]) {
        assert.equal(body.split('rules:\n')[1], template.split('rules:\n')[1]);
        assert.equal(body.split('\nproxies:\n')[0], template.split('\nproxies:\n')[0]);
        assert.ok(body.includes('ipv6: true'));
    }
    assert.ok(liveBody.includes('remote.example.com') && liveBody.includes('192.0.2.1'));
    assert.ok(
        liveBody.includes('type: mieru') &&
        liveBody.includes('mieru.example.com') &&
        groups.split('name: 🇺🇸优选')[0].includes('Mieru Remote'),
        'Clash output preserves upstream Mieru nodes and adds them to PROXY',
    );
    for (const expected of [
        'reuse-settings:',
        'max-connections: 4',
        'c-max-reuse-times: 0',
        'h-max-request-times: "300-600"',
        'h-max-reusable-secs: "900-1800"',
        'h-keep-alive-period: 0',
    ]) {
        assert.ok(liveBody.includes(expected), `Clash output preserves XHTTP ${expected}`);
    }
    assert.deepEqual(JSON.parse(groups.split('name: 🇺🇸优选')[1].match(/proxies: (\[[^\n]+\])/)[1]), ['🇺🇸优选1']);
    assert.ok(groups.split('name: 🇺🇸优选')[0].includes('Remote'), 'PROXY includes upstream');
    const encodedXflash = btoa(upstream);
    const htmlTyped = make(async url => new Response(
        new URL(url).origin === new URL(config.vpsSubUrl).origin ? btoa(cf) : encodedXflash,
        { headers: { 'content-type': 'text/html; charset=utf-8' } },
    ));
    const htmlTypedBody = await htmlTyped(request());
    assert.equal(htmlTypedBody.headers.get('X-Easy-All-Warning'), null, 'base64 XFLASH must not be rejected by content type');
    assert.ok((await htmlTypedBody.text()).includes('remote.example.com'));
    const fallbackAuto = fallbackBody.split('name: 🇺🇸优选')[1].split('rules:\n')[0];
    assert.deepEqual(JSON.parse(fallbackAuto.match(/proxies: (\[[^\n]+\])/)[1]), ['🇺🇸优选1']);
    const sixCf = [1, 2, 3, 4, 5, 6].map(i => ({ ...config.fallbackCdnNodes[0], name: `🇺🇸优选${i}` }));
    const sixBody = api.buildClashConfig([...api.LOCAL_NODES, ...sixCf], [10000, 10000, 443, 443, 443, 443, 443, 443], upstream, sixCf);
    const sixProxy = sixBody.split('proxy-groups:')[1].split('name: 🇺🇸优选')[0];
    assert.ok(sixCf.every(node => !sixProxy.includes(node.name)), 'CF nodes only appear inside backup group');
    assert.ok(!fallbackBody.split('proxy-groups:')[1].split('name: 🇺🇸优选')[0].includes('Fallback CF'));
    assert.deepEqual(JSON.parse(sixBody.split('name: 🇺🇸优选')[1].match(/proxies: (\[[^\n]+\])/)[1]), sixCf.slice(0, 6).map(n => n.name));
    assert.ok(!liveBody.includes('malicious.invalid'));
    assert.ok(liveBody.includes('ip-version: ipv4'));
    assert.throws(() => api.buildClashConfig(api.LOCAL_NODES, [10000], upstream.replace('name: Remote', 'name: 🇺🇸优选')));
    assert.throws(
        () => api.buildClashConfig(
            api.LOCAL_NODES,
            [10000],
            upstream.replace('name: Remote', 'name: 请更新客户端，此客户端版本过低'),
        ),
        /client upgrade placeholders/,
    );
    assert.throws(() => api.buildClashConfig(api.LOCAL_NODES, [10000], 'proxies: []'));
    const flow = api.buildClashConfig(api.LOCAL_NODES, [10000], 'proxies:\n  - { name: Flow, type: ss, server: flow.example.com, port: 443 }\ndns: {}\n');
    assert.ok(flow.includes('name: Flow'));
    const invalidUpstream = make(async url => new Response(new URL(url).origin === new URL(config.vpsSubUrl).origin ? cf : 'proxies: []'));
    assert.equal((await invalidUpstream(request())).headers.get('X-Easy-All-Warning'), 'xflash-unavailable-local-only');
    await assert.rejects(api.fetchXflashSubscription({headers: new Headers()}, config.externalSubUrl, {
        timeoutMs: 5,
        fetchImpl: async (url, {signal}) => new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(Error('aborted')))),
    }));
    await assert.rejects(api.fetchXflashSubscription({headers: new Headers()}, config.externalSubUrl, {
        maxSize: 3, fetchImpl: async () => new Response('oversized'),
    }));
    const generic = make(async url => new Response(new URL(url).origin === new URL(config.vpsSubUrl).origin ? cf : 'ss://example#Remote'));
    const genericBody = atob(await (await generic(genericRequest)).text());
    assert.ok(genericBody.includes('ss://example#Remote') && genericBody.includes('192.0.2.1'));
    const genericCf = genericBody.split('\n').find(link => link.includes('@192.0.2.1:443'));
    assert.ok(genericCf, 'generic output preserves the XHTTP connection IP');
    assert.deepEqual(
        JSON.parse(new URL(genericCf).searchParams.get('extra')).xmux,
        xmux,
        'generic output preserves all XHTTP xmux settings',
    );
    const ws = `vless://${config.nodes[0].uuid}@192.0.2.2:443?security=tls&type=ws&sni=ws.example.com&host=ws.example.com&path=%2Fws#WebSocket`;
    const wsLive = make(async url => new Response(
        new URL(url).origin === new URL(config.vpsSubUrl).origin ? btoa(ws) : upstream,
    ));
    const wsBody = await (await wsLive(request())).text();
    assert.ok(wsBody.includes('server: "192.0.2.2"'), 'Clash output preserves the WebSocket connection IP');
    assert.ok(wsBody.includes('servername: "ws.example.com"'), 'WebSocket TLS SNI remains the CDN domain');
    assert.ok(wsBody.includes('Host: "ws.example.com"'), 'WebSocket HTTP Host remains the CDN domain');
    const degradedGeneric = atob(await (await offline(genericRequest)).text());
    assert.ok(degradedGeneric.includes('fallback.example.com'));
    const ports = api.resolveNodePorts(api.LOCAL_NODES, {now: () => Date.UTC(2026, 0, 1)});
    assert.equal(ports[0], 10002);
    assert.equal(api.resolveNodePorts(api.LOCAL_NODES, {now: () => Date.UTC(2026, 0, 1, 3)})[0], 10003);
    assert.equal(
        api.resolveNodePorts([{...api.LOCAL_NODES[0], port: 4443}], {
            now: () => Date.UTC(2026, 0, 1),
        })[0],
        4443,
        'extra Reality nodes may pin a fixed port',
    );
    const rules = template.split('\nrules:\n')[1];
    assert.ok(rules.indexOf('steamcontent.com,DIRECT') < rules.indexOf('AND,((NETWORK,UDP)'));
    assert.ok(rules.indexOf('AND,((NETWORK,UDP)') < rules.indexOf('steamcommunity.com,PROXY'));
    assert.ok(rules.indexOf('AND,((NETWORK,UDP)') < rules.indexOf('chatgpt.com,PROXY'));
    console.log('Worker build, authentication, shared policy, node injection and fallback checks passed');
} finally { await rm(temp, {recursive:true, force:true}); }
