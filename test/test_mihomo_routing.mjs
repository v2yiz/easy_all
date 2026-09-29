import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer, createConnection } from 'node:net';
import { createSocket } from 'node:dgram';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';

// CI supplies the pinned core and Geo data; all test traffic stays on loopback.
if (!process.env.MIHOMO_CHECK_BIN) {
    console.log('SKIP: Mihomo routing check requires MIHOMO_CHECK_BIN and MIHOMO_CHECK_HOME');
    process.exit(0);
}
const temp = await mkdtemp(join(tmpdir(), 'easy-all-routing-'));
const sockets = [];
let core;
let logs = '';
async function unusedPort() {
    const server = createServer();
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    await new Promise(resolve => server.close(resolve));
    return port;
}
async function dnsServer(lastOctet) {
    const socket = createSocket('udp4');
    sockets.push(socket);
    socket.on('message', (query, peer) => {
        let end = 12;
        while (query[end]) end += query[end] + 1;
        end += 5;
        const header = Buffer.from(query.subarray(0, 12));
        header.writeUInt16BE(0x8180, 2);
        header.writeUInt16BE(1, 6);
        const answer = Buffer.from([0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, 203, 0, 113, lastOctet]);
        socket.send(Buffer.concat([header, query.subarray(12, end), answer]), peer.port, peer.address);
    });
    socket.bind(0, '127.0.0.1');
    await once(socket, 'listening');
    return `udp://127.0.0.1:${socket.address().port}`;
}
try {
    const domestic = await dnsServer(1);
    const foreign = await dnsServer(2);
    const port = await unusedPort();
    const controller = await unusedPort();
    let config = await readFile(new URL('../templates/mihomo.yaml', import.meta.url), 'utf8');
    config = config.replace(/^mixed-port:.*$/m, `mixed-port: ${port}`)
        .replace(/^external-controller:.*$/m, `external-controller: '127.0.0.1:${controller}'`)
        .replace('log-level: error', 'log-level: info')
        .replace('geo-auto-update: true', 'geo-auto-update: false')
        .replace(/tun:\n[\s\S]*?\ndns:/, 'tun:\n    enable: false\n\ndns:')
        .replace("listen: '127.0.0.1:5335'", "listen: '127.0.0.1:0'")
        .replaceAll('https://223.5.5.5/dns-query', domestic)
        .replaceAll('https://1.12.12.12/dns-query', domestic)
        .replaceAll('https://1.1.1.1/dns-query#PROXY', foreign)
        .replaceAll('https://8.8.8.8/dns-query#PROXY', foreign)
        .replace(/proxies:\n# EASY_ALL_PROXY_NODE[\s\S]*?\nrules:/,
            'proxies: []\nproxy-groups:\n  - {name: PROXY, type: select, proxies: [REJECT]}\n  - {name: TEST-DIRECT, type: select, proxies: [REJECT]}\nrules:')
        .replaceAll(',DIRECT', ',TEST-DIRECT');
    const file = join(temp, 'config.yaml');
    await writeFile(file, config);
    core = spawn(process.env.MIHOMO_CHECK_BIN, ['-d', process.env.MIHOMO_CHECK_HOME || temp, '-f', file]);
    core.stdout.on('data', chunk => { logs += chunk; });
    core.stderr.on('data', chunk => { logs += chunk; });
    const api = `http://127.0.0.1:${controller}`;
    let ready = false;
    for (let attempt = 0; attempt < 100; attempt++) {
        try { ready = (await fetch(`${api}/version`)).ok; } catch {}
        if (ready || core.exitCode !== null) break;
        await delay(100);
    }
    assert.ok(ready, logs);
    const domesticDomains = ['m5-x.amap.com', 'sync.amap.com', 'short.weixin.qq.com', 'speech.bytedance.com', 'www.doubao.com', 'weatherapi.vivo.com'];
    const foreignDomains = ['services.googleapis.cn', 'github.com', 'api.openai.com', 'api.anthropic.com', 'in.appcenter.ms', 'unknown.ms'];
    for (const [domains, ip, route] of [[domesticDomains, '203.0.113.1', 'TEST-DIRECT'], [foreignDomains, '203.0.113.2', 'PROXY']]) {
        for (const domain of domains) {
            const result = await (await fetch(`${api}/dns/query?name=${domain}&type=A`)).json();
            assert.ok(result.Answer?.some(answer => answer.data === ip), `${domain} DNS: ${JSON.stringify(result)}`);
            const socket = createConnection({host: '127.0.0.1', port});
            socket.setTimeout(2000, () => socket.destroy());
            socket.on('error', () => {});
            socket.on('data', () => {});
            socket.on('connect', () => socket.write(`CONNECT ${domain}:443 HTTP/1.1\r\nHost: ${domain}:443\r\n\r\n`));
            await once(socket, 'close');
            assert.ok(logs.split('\n').some(line => line.includes(`${domain}:443`) && line.includes(`using ${route}`)), `${domain} routing:\n${logs}`);
        }
    }
    console.log('Mihomo real-core domestic routing and DNS exception checks passed');
} finally {
    if (core && core.exitCode === null) { core.kill(); await once(core, 'exit'); }
    for (const socket of sockets) socket.close();
    await rm(temp, {recursive: true, force: true});
}
