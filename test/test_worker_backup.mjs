import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const uuid = '11111111-2222-4333-8444-555555555555';
const uuidBytes = Buffer.from(uuid.replaceAll('-', ''), 'hex');
const header = Buffer.concat([Buffer.from([0]), uuidBytes, Buffer.from([0, 1, 1, 187, 2, 11]), Buffer.from('example.com')]);
const source = await readFile(new URL('../worker-src/backup.js', import.meta.url), 'utf8');
const timers = new Set();
const { parseHeader, streamOne, worker } = vm.runInNewContext(source
    .replace("import { connect } from 'cloudflare:sockets';", 'const connect = () => { throw Error("Unexpected dial"); };')
    .replace('export default {', 'const worker = {')
    .replaceAll(/export\s+(async\s+)?function\s+/g, '$1function ') + '\n({ parseHeader, streamOne, worker })', {
    Uint8Array, ArrayBuffer, TextDecoder, URL, atob, AbortController,
    ReadableStream, WritableStream, TransformStream,
    Response: class extends Response {},
    setTimeout(fn, ms) {
        if (!ms) {
            setImmediate(fn);
            return fn;
        }
        timers.add(fn);
        return fn;
    },
    clearTimeout(fn) { timers.delete(fn); },
});

for (let i = 0; i < header.length; i++) assert.equal(parseHeader(header.subarray(0, i), uuid), null);
assert.equal(parseHeader(header, uuid).hostname, 'example.com');
assert.equal(parseHeader(header, uuid).port, 443);
const fqdn = Buffer.concat([header.subarray(0, 21), Buffer.from([2, 12]), Buffer.from('example.com.')]);
assert.equal(parseHeader(fqdn, uuid).hostname, 'example.com');
const invalidFqdn = Buffer.concat([header.subarray(0, 21), Buffer.from([2, 13]), Buffer.from('example.com..')]);
assert.throws(() => parseHeader(invalidFqdn, uuid), /Invalid hostname/);
assert.throws(() => parseHeader(header, '00000000-0000-4000-8000-000000000000'), /Unauthorized/);
for (const [position, value] of [[0, 1], [18, 2], [21, 9]]) {
    const invalid = Buffer.from(header); invalid[position] = value;
    assert.throws(() => parseHeader(invalid, uuid));
}
const ipv4 = Buffer.concat([header.subarray(0, 21), Buffer.from([1, 8, 8, 8, 8])]);
assert.equal(parseHeader(ipv4, uuid).hostname, '8.8.8.8');
const ipv6 = Buffer.concat([header.subarray(0, 21), Buffer.from([3]), Buffer.alloc(16, 0x20)]);
assert.equal(parseHeader(ipv6, uuid).hostname, '[2020:2020:2020:2020:2020:2020:2020:2020]');
const options = Buffer.concat([header.subarray(0, 17), Buffer.from([2, 0, 0]), header.subarray(18)]);
assert.equal(parseHeader(options, uuid).hostname, 'example.com');

const tick = () => new Promise(resolve => setImmediate(resolve));

// worker.fetch routing
assert.equal(worker.fetch(new Request('https://test.invalid/'), {}).status, 503);
assert.equal(worker.fetch(new Request('https://test.invalid/wrong'), { UUID: uuid, WS_PATH: '/ws' }).status, 404);
assert.equal(worker.fetch(new Request('https://test.invalid/ws'), { UUID: uuid, WS_PATH: '/ws' }).status, 405);

// streamOne: POST without body -> 400
assert.equal((await worker.fetch(new Request('https://test.invalid/ws', { method: 'POST' }), { UUID: uuid, WS_PATH: '/ws' })).status, 400);

// streamOne: POST with invalid/incomplete header -> 400
const badHeaderResp = await worker.fetch(new Request('https://test.invalid/ws', {
    method: 'POST', body: Buffer.from([0, 1, 2, 3]), duplex: 'half',
}), { UUID: uuid, WS_PATH: '/ws' });
assert.equal(badHeaderResp.status, 400);
assert.equal(await badHeaderResp.text(), 'Bad request');

// streamOne: POST with trailing slash matches WS_PATH
const trailingSlashResp = await worker.fetch(new Request('https://test.invalid/ws/', {
    method: 'POST', body: Buffer.from([0, 1, 2, 3]), duplex: 'half',
}), { UUID: uuid, WS_PATH: '/ws' });
assert.equal(trailingSlashResp.status, 400);

// streamOne: POST with dial failure -> 502
const dialFailResp = await worker.fetch(new Request('https://test.invalid/ws', {
    method: 'POST', body: header, duplex: 'half',
}), { UUID: uuid, WS_PATH: '/ws' });
assert.equal(dialFailResp.status, 502);
assert.equal(await dialFailResp.text(), 'Relay unavailable');
assert.equal(timers.size, 0);

// streamOne: Bidirectional data relay with [0, 0] VLESS response
const streamOneWrites = [];
let streamOneRemote, streamOneResolveClosed, streamOneClosed = false;
const streamOneSocket = {
    readable: new ReadableStream({ start(c) { streamOneRemote = c; } }),
    writable: new WritableStream({ write(data) { streamOneWrites.push(Buffer.from(data)); } }),
    opened: Promise.resolve(),
    closed: new Promise(resolve => { streamOneResolveClosed = resolve; }),
    close: async () => { streamOneClosed = true; },
};
const clientPayload = Buffer.concat([header, Buffer.from('stream one request')]);
const streamOneReq = new Request('https://test.invalid/ws', {
    method: 'POST', body: clientPayload, duplex: 'half',
});
let streamOneCalls = 0;
const streamOneResp = await streamOne(streamOneReq, uuid, address => {
    streamOneCalls++;
    assert.equal(address.hostname, 'example.com');
    assert.equal(address.port, 443);
    return streamOneSocket;
});
assert.equal(streamOneCalls, 1);
assert.equal(streamOneResp.status, 200);
assert.equal(streamOneResp.headers.get('Content-Type'), 'text/event-stream');
assert.equal(streamOneResp.headers.get('Cache-Control'), 'no-store');
const streamOneReader = streamOneResp.body.getReader();
const { value: firstChunk, done: firstDone } = await streamOneReader.read();
assert.equal(firstDone, false);
assert.deepEqual(firstChunk, new Uint8Array([0, 0])); // VLESS response header
await tick();
assert.equal(Buffer.concat(streamOneWrites).toString(), 'stream one request');

// Remote sends data
streamOneRemote.enqueue(Buffer.from('remote response'));
const { value: replyChunk } = await streamOneReader.read();
assert.deepEqual(replyChunk, Buffer.from('remote response'));

// Remote closes
streamOneRemote.close();
const { done: streamOneDone } = await streamOneReader.read();
assert.equal(streamOneDone, true);
await tick();
assert.equal(streamOneClosed, false);
streamOneResolveClosed();
await tick();
assert.equal(streamOneClosed, true);
assert.equal(timers.size, 0);

// A remote read-side EOF must not truncate a still-open client upload.
let halfOpenBodyController, halfOpenRemote, halfOpenResolveClosed;
let halfOpenCanceled = false, halfOpenSocketClosed = false;
const halfOpenWrites = [];
const halfOpenBody = new ReadableStream({
    start(controller) {
        halfOpenBodyController = controller;
        controller.enqueue(header);
    },
    cancel() { halfOpenCanceled = true; },
});
const halfOpenSocket = {
    readable: new ReadableStream({ start(controller) { halfOpenRemote = controller; } }),
    writable: new WritableStream({
        write(data) { halfOpenWrites.push(Buffer.from(data)); },
        close() { halfOpenResolveClosed(); },
    }),
    opened: Promise.resolve(),
    closed: new Promise(resolve => { halfOpenResolveClosed = resolve; }),
    close: async () => { halfOpenSocketClosed = true; },
};
const halfOpenResp = await streamOne(new Request('https://test.invalid/ws', {
    method: 'POST', body: halfOpenBody, duplex: 'half',
}), uuid, () => halfOpenSocket);
const halfOpenReader = halfOpenResp.body.getReader();
assert.deepEqual((await halfOpenReader.read()).value, new Uint8Array([0, 0]));
halfOpenRemote.close();
assert.equal((await halfOpenReader.read()).done, true);
await tick();
assert.equal(halfOpenSocketClosed, false);
assert.equal(halfOpenCanceled, false);
halfOpenBodyController.enqueue(Buffer.from('late upload'));
await tick();
assert.equal(Buffer.concat(halfOpenWrites).toString(), 'late upload');
halfOpenBodyController.close();
await tick();
assert.equal(halfOpenSocketClosed, true);
assert.equal(halfOpenCanceled, false);

// streamOne preserves payload when the VLESS header is split across request chunks.
const fragmentedWrites = [];
let fragmentedRemote;
const fragmentedSocket = {
    readable: new ReadableStream({ start(c) { fragmentedRemote = c; } }),
    writable: new WritableStream({ write(data) { fragmentedWrites.push(Buffer.from(data)); } }),
    opened: Promise.resolve(), closed: new Promise(() => {}),
    close: async () => {},
};
const fragmentedBody = new ReadableStream({
    start(controller) {
        controller.enqueue(header.subarray(0, 10));
        controller.enqueue(Buffer.concat([header.subarray(10), Buffer.from('first')]));
        controller.enqueue(Buffer.from('second'));
        controller.close();
    },
});
const fragmentedResp = await streamOne(new Request('https://test.invalid/ws', {
    method: 'POST', body: fragmentedBody, duplex: 'half',
}), uuid, () => fragmentedSocket);
const fragmentedReader = fragmentedResp.body.getReader();
await fragmentedReader.read();
await tick();
assert.equal(Buffer.concat(fragmentedWrites).toString(), 'firstsecond');
fragmentedRemote.close();
await fragmentedReader.read();

// streamOne Backpressure: Upstream TCP reads pause when downstream client is slow / not pulling
let upstreamReadCount = 0;
let backpressureSocketClosed = false;
const backpressureSocket = {
    opened: Promise.resolve(), closed: new Promise(() => {}),
    readable: new ReadableStream({
        pull(controller) {
            upstreamReadCount++;
            controller.enqueue(Buffer.alloc(4096, 0x42));
        },
    }, { highWaterMark: 0 }),
    writable: new WritableStream(),
    close: async () => { backpressureSocketClosed = true; },
};
const bpReq = new Request('https://test.invalid/ws', { method: 'POST', body: header, duplex: 'half' });
const bpResp = await streamOne(bpReq, uuid, () => backpressureSocket);
const bpReader = bpResp.body.getReader();
const bpFirst = await bpReader.read();
assert.deepEqual(bpFirst.value, new Uint8Array([0, 0]));
// Client has not read from downstream response yet. Let event loop tick.
for (let i = 0; i < 50; i++) await tick();
// Because highWaterMark is 0, upstream TCP reader must not continuously read ahead.
assert.ok(upstreamReadCount <= 1, `upstream TCP reads must pause under downstream backpressure (got ${upstreamReadCount})`);

// Client pulls 3 chunks explicitly
for (let i = 0; i < 3; i++) {
    const chunk = await bpReader.read();
    assert.equal(chunk.value.length, 4096);
}
assert.ok(upstreamReadCount <= 4, `upstream reads are paced by client pulls (got ${upstreamReadCount})`);
await bpReader.cancel();
await tick();
assert.equal(backpressureSocketClosed, true);
assert.equal(timers.size, 0);

// streamOne Continuous download exceeding 8 MiB (10 MiB sustained transfer without disconnect)
let tenMbReadCount = 0;
const TOTAL_CHUNKS = 160; // 160 * 64 KiB = 10 MiB > 8 MiB MAX_DOWNSTREAM limit
const CHUNK_SIZE = 64 * 1024;
let tenMbResolveClosed, tenMbSocketClosed = false;
const tenMbSocket = {
    opened: Promise.resolve(),
    closed: new Promise(resolve => { tenMbResolveClosed = resolve; }),
    readable: new ReadableStream({
        pull(controller) {
            if (tenMbReadCount < TOTAL_CHUNKS) {
                const chunk = Buffer.alloc(CHUNK_SIZE, tenMbReadCount % 256);
                tenMbReadCount++;
                controller.enqueue(chunk);
            } else {
                controller.close();
            }
        },
    }, { highWaterMark: 0 }),
    writable: new WritableStream(),
    close: async () => { tenMbSocketClosed = true; },
};
const tenMbReq = new Request('https://test.invalid/ws', { method: 'POST', body: header, duplex: 'half' });
const tenMbResp = await streamOne(tenMbReq, uuid, () => tenMbSocket);
const tenMbReader = tenMbResp.body.getReader();
const tenMbFirst = await tenMbReader.read();
assert.deepEqual(tenMbFirst.value, new Uint8Array([0, 0])); // VLESS header
let receivedBytes = 0;
let chunkIndex = 0;
while (true) {
    const { value, done } = await tenMbReader.read();
    if (done) break;
    assert.equal(value.length, CHUNK_SIZE);
    assert.equal(value[0], chunkIndex % 256);
    receivedBytes += value.length;
    chunkIndex++;
}
await tick();
assert.equal(receivedBytes, 10 * 1024 * 1024, 'streamOne must sustain download exceeding 8 MiB limit');
assert.equal(chunkIndex, TOTAL_CHUNKS);
assert.equal(tenMbSocketClosed, false);
tenMbResolveClosed();
await tick();
assert.equal(tenMbSocketClosed, true);
assert.equal(timers.size, 0);

// streamOne client abort / signal handling
let abortedSocketClosed = false;
const abortController = new AbortController();
const abortSocket = {
    opened: Promise.resolve(), closed: new Promise(() => {}),
    readable: new ReadableStream({
        pull(c) { c.enqueue(Buffer.alloc(1024)); },
    }, { highWaterMark: 0 }),
    writable: new WritableStream(),
    close: async () => { abortedSocketClosed = true; },
};
const abortReq = new Request('https://test.invalid/ws', {
    method: 'POST', body: header, duplex: 'half', signal: abortController.signal,
});
const abortResp = await streamOne(abortReq, uuid, () => abortSocket);
const abortReader = abortResp.body.getReader();
await abortReader.read(); // [0, 0]
abortController.abort();
await tick();
assert.equal(abortedSocketClosed, true);
assert.equal(timers.size, 0);

// Dynamic aggregation handler: refreshed source is consumed on every request.
const primary = Array.from({ length: 6 }, (_, i) => `vless://${uuid}@104.17.0.${i + 1}:443?security=tls&type=xhttp&host=node.example.com&path=%2Fx#primary${i}`);
const workerXmux = {
    maxConnections: 4,
    cMaxReuseTimes: 0,
    hMaxRequestTimes: '300-600',
    hMaxReusableSecs: '900-1800',
    hKeepAlivePeriod: 0,
};
const workerExtra = encodeURIComponent(JSON.stringify({
    uplinkHTTPMethod: 'POST',
    noGRPCHeader: false,
    xmux: workerXmux,
}));
const xhttpBackupLinks = Array.from({ length: 6 }, (_, i) =>
    `vless://${uuid}@104.16.${i + 1}.${i + 1}:443?encryption=none&security=tls&type=xhttp&mode=stream-one&alpn=h2&host=backup.example.com&sni=backup.example.com&path=%2Fws&extra=${workerExtra}&easyAllBackup=1#backup${i}`);
const aggregation = await readFile(new URL('../worker-src/index.js', import.meta.url), 'utf8');
const handler = vm.runInNewContext(aggregation.replace(/export default \{[\s\S]*$/, 'handleRequest;'), {
    PRIVATE_CONFIG: { allowedTokens: { owner: 'test-token' }, nodes: [], fallbackCdnNodes: [], vpsSubUrl: 'https://source.invalid/', requireDynamicCdn: true },
    MIHOMO_TEMPLATE: await readFile(new URL('../templates/mihomo.yaml', import.meta.url), 'utf8'),
    WORKER_VERSION: 'test', URL, URLSearchParams, Headers, Response, AbortController, TextEncoder, TextDecoder,
    atob, btoa, setTimeout, clearTimeout, console,
    fetch: async () => new Response(Buffer.from([...primary, ...xhttpBackupLinks].join('\n')).toString('base64')),
});
const request = flag => new Request(`https://sub.invalid/subscribe?token=test-token&flag=${flag}`);
let response = await handler(request('clash'));
assert.equal(response.status, 200);
const yaml = await response.text();
assert.equal((yaml.match(/network: ws/g) || []).length, 0);
assert.equal((yaml.match(/network: xhttp/g) || []).length, 12);
assert.equal((yaml.match(/mode: "stream-one"/g) || []).length, 6);
assert.equal((yaml.match(/no-grpc-header: false/g) || []).length, 12);
assert.equal((yaml.match(/udp: false/g) || []).length, 6);
assert.equal((yaml.match(/max-connections: 4/g) || []).length, 6);
assert.equal((yaml.match(/h-max-request-times: "300-600"/g) || []).length, 6);
assert.equal((yaml.match(/path: "\/ws\/"/g) || []).length, 6);
const groups = yaml.split('proxy-groups:\n')[1].split('rules:\n')[0];
const proxyGroup = groups.split('    - name: 🇺🇸白天首选')[0];
const globalGroup = groups.split('    - name: GLOBAL')[1].split('    - name: 🇺🇸白天首选')[0];
const workerGroup = groups.split('    - name: 🇭🇰CF')[1];
assert.ok(proxyGroup.includes('        - "🇭🇰CF"'));
assert.equal((groups.match(/hidden: true/g) || []).length, 3);
assert.ok(!groups.includes('代理模式') && !groups.includes('油管兜底'));
assert.ok(!proxyGroup.includes('纯CF'));
assert.match(globalGroup, /proxies:\s*\n\s*- PROXY\s*$/m);
assert.ok(!globalGroup.includes('DIRECT') && !globalGroup.includes('REJECT'));
assert.ok(workerGroup.includes('      type: url-test'));
assert.ok(workerGroup.includes('      url: https://www.gstatic.com/generate_204'));
assert.ok(workerGroup.includes('      interval: 300'));
assert.ok(workerGroup.includes('      timeout: 5000'));
assert.deepEqual(
    JSON.parse(workerGroup.match(/proxies: (\[[^\n]+\])/)[1]),
    ['🇭🇰CF1', '🇭🇰CF2', '🇭🇰CF3', '🇭🇰CF4', '🇭🇰CF5', '🇭🇰CF6'],
);
const rules = yaml.split('rules:\n')[1];
assert.ok(!rules.includes('GEOSITE,youtube,'));
assert.ok(!rules.includes('代理模式'));
assert.ok(rules.includes('GEOSITE,google,PROXY'));

const base64Resp = await handler(request('base64'));
const decoded = Buffer.from(await base64Resp.text(), 'base64').toString();
assert.equal(decoded.split('\n').filter(Boolean).length, 12);
assert.ok(decoded.includes('mode=stream-one'));
assert.ok(decoded.includes('easyAllBackup=1'));
assert.ok(!decoded.includes('type=ws'));
const renderedBackup = decoded.split('\n').find(line => line.includes('easyAllBackup=1'));
assert.deepEqual(JSON.parse(new URL(renderedBackup).searchParams.get('extra')).xmux, workerXmux);
assert.equal(new URL(renderedBackup).searchParams.get('path'), '/ws/');

// Empty worker backup removes group
const emptyHandler = vm.runInNewContext(aggregation.replace(/export default \{[\s\S]*$/, 'handleRequest;'), {
    PRIVATE_CONFIG: { allowedTokens: { owner: 'test-token' }, nodes: [], fallbackCdnNodes: [], vpsSubUrl: 'https://source.invalid/', requireDynamicCdn: true },
    MIHOMO_TEMPLATE: await readFile(new URL('../templates/mihomo.yaml', import.meta.url), 'utf8'),
    WORKER_VERSION: 'test', URL, URLSearchParams, Headers, Response, AbortController, TextEncoder, TextDecoder,
    atob, btoa, setTimeout, clearTimeout, console,
    fetch: async () => new Response(Buffer.from(primary.join('\n')).toString('base64')),
});
response = await emptyHandler(request('clash'));
const yamlWithoutWorker = await response.text();
assert.ok(!yamlWithoutWorker.includes('🇭🇰CF'));
assert.ok(!yamlWithoutWorker.includes('EASY_ALL_WORKER_RULE'));
assert.ok(!yamlWithoutWorker.includes('    - name: 代理模式'));
assert.ok(!yamlWithoutWorker.includes('    - name: 油管兜底'));

console.log('Pure XHTTP stream-one worker backup parser, relay, backpressure and dynamic aggregation checks passed');
