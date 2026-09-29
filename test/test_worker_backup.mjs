import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const uuid = '11111111-2222-4333-8444-555555555555';
const uuidBytes = Buffer.from(uuid.replaceAll('-', ''), 'hex');
const header = Buffer.concat([Buffer.from([0]), uuidBytes, Buffer.from([0, 1, 1, 187, 2, 11]), Buffer.from('example.com')]);
const source = await readFile(new URL('../worker-src/backup.js', import.meta.url), 'utf8');
const timers = new Set();
const { parseHeader, relay, worker } = vm.runInNewContext(source
    .replace("import { connect } from 'cloudflare:sockets';", 'const connect = () => { throw Error("Unexpected dial"); };')
    .replaceAll('export function ', 'function ').replace('export default {', 'const worker = {') + '\n({ parseHeader, relay, worker })', {
    Uint8Array, ArrayBuffer, TextDecoder, URL, atob,
    Response: class extends Response {
        constructor(body, init) {
            if (init?.status === 101) {
                super(null, { status: 200, headers: init?.headers });
                Object.defineProperty(this, 'status', { value: 101 });
                this.webSocket = init?.webSocket;
            } else {
                super(body, init);
            }
        }
    },
    WebSocketPair: function() {
        const s = websocket();
        s.accept = () => {};
        return { 0: websocket(), 1: s };
    },
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

function websocket() {
    return { listeners: {}, sent: [], closes: [],
        readyState: 1,
        addEventListener(name, fn) { this.listeners[name] = fn; },
        send(data) { this.sent.push(Buffer.from(data)); },
        close(code) { this.readyState = 3; this.closes.push(code); },
        message(data) { this.listeners.message({ data }); },
    };
}
const tick = () => new Promise(resolve => setImmediate(resolve));
const ws = websocket();
const writes = [];
let remote, closeCount = 0, calls = 0;
const socket = {
    readable: new ReadableStream({ start(controller) { remote = controller; } }),
    writable: new WritableStream({ write(data) { writes.push(Buffer.from(data)); } }),
    opened: Promise.resolve(), closed: new Promise(() => {}),
    close() { closeCount++; remote.close(); return Promise.resolve(); },
};
relay(ws, uuid, new Uint8Array(), address => {
    calls++; assert.equal(address.hostname, 'example.com'); return socket;
});
ws.message(header.subarray(0, 10));
ws.message(Buffer.concat([header.subarray(10), Buffer.from('first')]));
ws.message(Buffer.from('second'));
await tick();
assert.equal(calls, 1);
assert.equal(Buffer.concat(writes).toString(), 'firstsecond');
remote.enqueue(Buffer.from('reply'));
await tick();
assert.deepEqual(ws.sent, [Buffer.from([0, 0]), Buffer.from('reply')]);
let macrotaskRan = false;
setTimeout(() => { macrotaskRan = true; }, 0);
remote.enqueue(Buffer.from('reply2'));
await new Promise(resolve => setTimeout(resolve, 5));
assert.equal(macrotaskRan, true);
ws.listeners.close();
await tick();
assert.equal(closeCount, 1);
assert.equal(timers.size, 0);

const bad = websocket();
relay(bad, uuid, new Uint8Array(), () => { throw Error('Must not dial'); });
const wrong = Buffer.from(header); wrong[1] ^= 1;
bad.message(wrong);
await tick();
assert.deepEqual(bad.closes, [1008]);
const large = websocket();
relay(large, uuid);
large.message(new Uint8Array(1024 * 1024 + 1));
assert.deepEqual(large.closes, [1009]);
const early = websocket();
let earlyWrites = [];
relay(early, uuid, Buffer.concat([header, Buffer.from('early')]), () => ({
    opened: Promise.resolve(), closed: new Promise(() => {}),
    readable: new ReadableStream(),
    writable: new WritableStream({ write(data) { earlyWrites.push(Buffer.from(data)); } }),
    close: async () => {},
}));
await tick();
assert.equal(Buffer.concat(earlyWrites).toString(), 'early');
early.listeners.close();
assert.equal(timers.size, 0);
assert.equal(worker.fetch(new Request('https://test.invalid/'), {}).status, 503);
assert.equal(worker.fetch(new Request('https://test.invalid/wrong'), { UUID: uuid, WS_PATH: '/ws' }).status, 404);
assert.equal(worker.fetch(new Request('https://test.invalid/ws'), { UUID: uuid, WS_PATH: '/ws' }).status, 426);
const upgradeReq = new Request('https://test.invalid/ws', {
    method: 'GET',
    headers: { Upgrade: 'websocket', 'Sec-WebSocket-Protocol': 'ZXhwb3J0' },
});
const upgradeResp = worker.fetch(upgradeReq, { UUID: uuid, WS_PATH: '/ws' });
assert.equal(upgradeResp.status, 101);
assert.equal(upgradeResp.headers.get('Sec-WebSocket-Protocol'), 'ZXhwb3J0');

// Real aggregation handler: refreshed source is consumed on every request.
let addresses = Array.from({ length: 6 }, (_, i) => `104.16.${i + 1}.${i + 1}`);
const primary = Array.from({ length: 6 }, (_, i) => `vless://${uuid}@104.17.0.${i + 1}:443?security=tls&type=xhttp&host=node.example.com&path=%2Fx#primary${i}`);
const links = () => [...primary, ...addresses.map((address, i) =>
    `vless://${uuid}@${address}:443?security=tls&type=ws&host=backup.example.com&sni=backup.example.com&path=%2Fws&easyAllBackup=1#backup${i}`)].join('\n');
const aggregation = await readFile(new URL('../worker-src/index.js', import.meta.url), 'utf8');
const handler = vm.runInNewContext(aggregation.replace(/export default \{[\s\S]*$/, 'handleRequest;'), {
    PRIVATE_CONFIG: { allowedTokens: { owner: 'test-token' }, nodes: [], fallbackCdnNodes: [], vpsSubUrl: 'https://source.invalid/', requireDynamicCdn: true },
    MIHOMO_TEMPLATE: await readFile(new URL('../templates/mihomo.yaml', import.meta.url), 'utf8'),
    WORKER_VERSION: 'test', URL, URLSearchParams, Headers, Response, AbortController, TextEncoder, TextDecoder,
    atob, btoa, setTimeout, clearTimeout, console,
    fetch: async () => new Response(Buffer.from(links()).toString('base64')),
});
const request = flag => new Request(`https://sub.invalid/subscribe?token=test-token&flag=${flag}`);
let response = await handler(request('clash'));
assert.equal(response.status, 200);
const yaml = await response.text();
assert.equal((yaml.match(/network: ws/g) || []).length, 6);
assert.equal((yaml.match(/network: xhttp/g) || []).length, 6);
assert.equal((yaml.match(/udp: false/g) || []).length, 6);
const groups = yaml.split('proxy-groups:\n')[1].split('rules:\n')[0];
const proxyGroup = groups.split('    - name: 🇺🇸白天首选')[0];
const modeGroup = groups.split('    - name: 代理模式')[1].split('    - name: DEFAULT')[0];
const defaultGroup = groups.split('    - name: DEFAULT')[1].split('    - name: GLOBAL')[0];
const globalGroup = groups.split('    - name: GLOBAL')[1].split('    - name: 🇺🇸白天首选')[0];
const workerGroup = groups.split('    - name: 🇭🇰CF')[1];
assert.ok(!proxyGroup.includes('        - "🇭🇰CF"'));
assert.ok(!proxyGroup.includes('纯CF'));
assert.match(modeGroup, /default-selected: DEFAULT/);
assert.match(modeGroup, /proxies:\s*\n\s*- DEFAULT\s*\n\s*- PROXY/m);
assert.match(defaultGroup, /hidden: true/);
assert.match(defaultGroup, /proxies:\s*\n\s*- PASS\s*$/m);
assert.match(globalGroup, /proxies:\s*\n\s*- PROXY\s*$/m);
assert.ok(!globalGroup.includes('DIRECT') && !globalGroup.includes('REJECT'));
assert.ok(workerGroup.includes('      type: url-test'));
assert.ok(workerGroup.includes('      url: https://www.gstatic.com/generate_204'));
assert.ok(workerGroup.includes('      interval: 300'));
assert.deepEqual(
    JSON.parse(workerGroup.match(/proxies: (\[[^\n]+\])/)[1]),
    ['🇭🇰CF1', '🇭🇰CF2', '🇭🇰CF3', '🇭🇰CF4', '🇭🇰CF5', '🇭🇰CF6'],
);
const rules = yaml.split('rules:\n')[1];
const youtubeModeRule = rules.indexOf('  - GEOSITE,youtube,代理模式');
const youtubeRule = rules.indexOf('  - GEOSITE,youtube,🇭🇰CF');
const googleRule = rules.indexOf('  - GEOSITE,google,PROXY');
assert.ok(youtubeModeRule >= 0 && youtubeModeRule < youtubeRule && youtubeRule < googleRule);
assert.ok(rules.includes('  - AND,((NETWORK,UDP),(DST-PORT,443),(GEOSITE,youtube)),代理模式'));
assert.ok(rules.includes('  - AND,((NETWORK,UDP),(DST-PORT,443),(GEOSITE,youtube)),REJECT'));
addresses = ['104.16.9.9'];
response = await handler(request('base64'));
const decoded = Buffer.from(await response.text(), 'base64').toString();
assert.equal(decoded.split('\n').filter(Boolean).length, 7);
assert.ok(decoded.includes('104.16.9.9'));
assert.ok(!decoded.includes('104.16.2.2'));
assert.ok(!decoded.split('\n').filter(line => line.includes('type=ws')).some(line => line.includes('packetEncoding')));
addresses = [];
response = await handler(request('clash'));
const yamlWithoutWorker = await response.text();
assert.ok(!yamlWithoutWorker.includes('🇭🇰CF'));
assert.ok(!yamlWithoutWorker.includes('EASY_ALL_WORKER_RULE'));
assert.ok(yamlWithoutWorker.includes('    - name: 代理模式'));
assert.ok(yamlWithoutWorker.includes('    - name: DEFAULT'));
console.log('Worker backup parser, relay, limits and dynamic aggregation checks passed');
