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
    const source = await readFile(outputPath, 'utf8');
    assert.equal((await stat(outputPath)).mode & 0o777, 0o600);
    await writeFile(configPath, '{invalid');
    await assert.rejects(buildWorker({ configPath, outputPath }));
    assert.equal(await readFile(outputPath, 'utf8'), source, 'failed build preserves artifact');
    const context = vm.createContext({ URL, URLSearchParams, Headers, Response, AbortController, TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout, fetch: async () => { throw Error('offline'); }, console: { error() {}, warn() {} } });
    const api = vm.runInContext(source.replace(/export default \{[\s\S]*$/, '({createWorkerHandler, resolveNodePorts, buildClashConfig, fetchXflashSubscription, PRIVATE_CONFIG, LOCAL_NODES});'), context);
    const make = fetchImpl => api.createWorkerHandler({ allowedTokenValues: new Set(['offline-test-token']), localNodes: api.LOCAL_NODES, upstreamUrl: config.upstreamUrl, vpsCdnUrl: config.vpsCdnUrl, now: () => Date.UTC(2026, 0, 1), fetchImpl });
    const request = (suffix = '', token = 'offline-test-token', method = 'GET') => new Request(`https://worker.invalid/subscribe?token=${token}&flag=clash${suffix}`, {method});
    let calls = 0;
    const offline = make(async () => { calls++; throw Error('offline'); });
    assert.equal((await offline(request('', 'bad'))).status, 403);
    assert.equal((await offline(new Request('https://worker.invalid/nope'))).status, 404);
    assert.equal((await offline(request('', 'offline-test-token', 'POST'))).status, 405);
    assert.equal(calls, 0, 'reject before upstream access');
    const fallback = await offline(request());
    assert.equal(fallback.headers.get('X-Easy-All-Version'), '2026-09-07-v0');
    assert.equal(fallback.headers.get('X-Easy-All-Warning'), 'xflash-unavailable-local-only');
    const fallbackBody = await fallback.text();
    assert.ok(fallbackBody.includes('fallback.example.com'));
    assert.ok(fallbackBody.includes('hidden.example.com'));
    assert.ok(!fallbackBody.includes('vmiss.example.com'));
    const allBody = await (await offline(request('&node=all'))).text();
    assert.ok(allBody.includes('hidden.example.com'));
    assert.ok(allBody.includes('vmiss.example.com'));
    assert.equal(await (await offline(request('', 'offline-test-token', 'HEAD'))).text(), '');
    const upstream = `dns:\n  nameserver: [malicious.invalid]\nproxies:\n    - name: Remote\n      type: vless\n      server: remote.example.com\n      port: 443\n      uuid: ${config.nodes[0].uuid}\n      network: xhttp\n      ip-version: ipv4\n      alpn:\n        - h2\nproxy-groups: []\nrules:\n  - MATCH,DIRECT\n`;
    const cf = `vless://${config.nodes[0].uuid}@192.0.2.1:443?security=tls&type=xhttp&host=cdn.example.com&path=%2Fxhttp%2F&mode=stream-up#CF`;
    const live = make(async url => new Response(url === config.vpsCdnUrl ? btoa(cf) : upstream));
    const liveResponse = await live(request());
    assert.equal(liveResponse.headers.get('X-Easy-All-Warning'), null);
    const liveBody = await liveResponse.text();
    const groups = liveBody.split('proxy-groups:\n')[1].split('rules:\n')[0];
    assert.equal((groups.match(/name:/g) || []).length, 2);
    assert.ok(groups.indexOf('name: PROXY') < groups.indexOf('name: 备用优选'));
    const proxyMembers = groups.split('name: 备用优选')[0].split('proxies:')[1].trim().split('\n').map(line => line.trim()).filter(line => line.startsWith('- "')).map(line => JSON.parse(line.slice(2)));
    assert.deepEqual(proxyMembers, ['Reality example', 'Hidden Reality', 'Remote', '备用优选']);
    assert.ok(!groups.includes('DIRECT'));
    const template = await readFile(new URL('../templates/mihomo.yaml', import.meta.url), 'utf8');
    for (const body of [fallbackBody, liveBody]) {
        assert.equal(body.split('rules:\n')[1], template.split('rules:\n')[1]);
        assert.equal(body.split('\nproxies:\n')[0], template.split('\nproxies:\n')[0]);
        assert.ok(body.includes('ipv6: false'));
    }
    assert.ok(liveBody.includes('remote.example.com') && liveBody.includes('192.0.2.1'));
    assert.deepEqual(JSON.parse(groups.split('name: 备用优选')[1].match(/proxies: (\[[^\n]+\])/)[1]), ['🇺🇸备用CF1']);
    assert.ok(groups.split('name: 备用优选')[0].includes('Remote'), 'PROXY includes upstream');
    const fallbackAuto = fallbackBody.split('name: 备用优选')[1].split('rules:\n')[0];
    assert.deepEqual(JSON.parse(fallbackAuto.match(/proxies: (\[[^\n]+\])/)[1]), ['Fallback CF']);
    const fiveCf = [1, 2, 3, 4, 5, 6].map(i => ({ ...config.fallbackCdnNodes[0], name: `🇺🇸备用CF${i}` }));
    const fiveBody = api.buildClashConfig([...api.LOCAL_NODES, ...fiveCf], [10000, 10000, 443, 443, 443, 443, 443, 443], upstream, fiveCf);
    const fiveProxy = fiveBody.split('proxy-groups:')[1].split('name: 备用优选')[0];
    assert.ok(fiveCf.every(node => !fiveProxy.includes(node.name)), 'CF nodes only appear inside backup group');
    assert.ok(!fallbackBody.split('proxy-groups:')[1].split('name: 备用优选')[0].includes('Fallback CF'));
    assert.deepEqual(JSON.parse(fiveBody.split('name: 备用优选')[1].match(/proxies: (\[[^\n]+\])/)[1]), fiveCf.slice(0, 5).map(n => n.name));
    assert.ok(!liveBody.includes('malicious.invalid'));
    assert.ok(liveBody.includes('ip-version: ipv4'));
    assert.throws(() => api.buildClashConfig(api.LOCAL_NODES, [10000], upstream.replace('name: Remote', 'name: 备用优选')));
    assert.throws(() => api.buildClashConfig(api.LOCAL_NODES, [10000], 'proxies: []'));
    const flow = api.buildClashConfig(api.LOCAL_NODES, [10000], 'proxies:\n  - { name: Flow, type: ss, server: flow.example.com, port: 443 }\ndns: {}\n');
    assert.ok(flow.includes('name: Flow'));
    const invalidUpstream = make(async url => new Response(url === config.vpsCdnUrl ? cf : 'proxies: []'));
    assert.equal((await invalidUpstream(request())).headers.get('X-Easy-All-Warning'), 'xflash-unavailable-local-only');
    await assert.rejects(api.fetchXflashSubscription({headers: new Headers()}, config.upstreamUrl, {
        timeoutMs: 5,
        fetchImpl: async (url, {signal}) => new Promise((resolve, reject) => signal.addEventListener('abort', () => reject(Error('aborted')))),
    }));
    await assert.rejects(api.fetchXflashSubscription({headers: new Headers()}, config.upstreamUrl, {
        maxSize: 3, fetchImpl: async () => new Response('oversized'),
    }));
    const generic = make(async url => new Response(url === config.vpsCdnUrl ? cf : 'ss://example#Remote'));
    const genericRequest = new Request('https://worker.invalid/subscribe?token=offline-test-token&flag=base64');
    const genericBody = atob(await (await generic(genericRequest)).text());
    assert.ok(genericBody.includes('ss://example#Remote') && genericBody.includes('192.0.2.1'));
    const degradedGeneric = atob(await (await offline(genericRequest)).text());
    assert.ok(degradedGeneric.includes('fallback.example.com'));
    const ports = api.resolveNodePorts(api.LOCAL_NODES, {now: () => Date.UTC(2026, 0, 1)});
    assert.equal(ports[0], 10002);
    assert.equal(api.resolveNodePorts(api.LOCAL_NODES, {now: () => Date.UTC(2026, 0, 1, 3)})[0], 10003);
    const rules = template.split('\nrules:\n')[1];
    assert.ok(rules.indexOf('steamcontent.com,DIRECT') < rules.indexOf('AND,((NETWORK,UDP)'));
    assert.ok(rules.indexOf('AND,((NETWORK,UDP)') < rules.indexOf('steamcommunity.com,PROXY'));
    assert.ok(rules.indexOf('AND,((NETWORK,UDP)') < rules.indexOf('chatgpt.com,PROXY'));
    console.log('Worker build, authentication, shared policy, node injection and fallback checks passed');
} finally { await rm(temp, {recursive:true, force:true}); }
