import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, mkdir, copyFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createServer, createConnection } from 'node:net';
import { createServer as createHttpServer } from 'node:http';
import { createSocket } from 'node:dgram';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { setTimeout as delay } from 'node:timers/promises';
import vm from 'node:vm';
import { buildWorker } from '../scripts/build-worker.mjs';

const temp = await mkdtemp(join(tmpdir(), 'easy-all-common-'));
const binary = process.env.MIHOMO_CHECK_BIN;
const fcm = ['mtalk.google.com', 'mtalk4.google.com', 'mtalk-dev.google.com', 'mtalk-staging.google.com',
    ...Array.from({length: 8}, (_, i) => `alt${i + 1}-mtalk.google.com`)];
const wechat = ['qpic.cn', 'qlogo.cn', 'wxqcloud.qq.com.cn', 'servicewechat.com',
    'weixin.qq.com', 'wxs.qq.com', 'res.wx.qq.com', 'wechat.com'];
const steamDownloads = ['cdn.steamcontent.com', 'cm.steampowered.com', 'relay.steamserver.net'];
const appleDomestic = ['www.apple.com', 'apps.apple.com', 'swcdn.apple.com', 'updates.cdn-apple.com', 'is1-ssl.mzstatic.com'];
const appleForeign = ['developer.apple.com', 'www.icloud.com', 'review.cdn-apple.com',
    'review.mzstatic.com', 'review.aaplimg.com', 'review.apple-cloudkit.com'];
const privateHosts = ['localhost', 'host.localhost', 'nas.lan', 'nas.local',
    'nas.internal', 'nas.localdomain', 'host.home.arpa'];
const privatePolicy = "'rule-set:private-fallback,geosite-private': system";
const fixtures = {
    'geosite-private': ['domain', '+.private-fixture.net'],
    'geosite-apple-cn': ['domain', '+.apple-cn-fixture.net'],
    'geosite-apple': ['domain', ['+.apple.com', '+.icloud.com', '+.cdn-apple.com',
        '+.mzstatic.com', '+.aaplimg.com', '+.apple-cloudkit.com'].join('\n')],
    'geosite-google': ['domain', '+.google-fixture.net'],
    'geoip-cn': ['ipcidr', '1.2.4.0/24'],
    'geoip-telegram': ['ipcidr', '149.154.160.0/20'],
    'geosite-cn': ['domain', ['+.cn-fixture.net', '+.hxkba.com'].join('\n')],
    'geosite-foreign': ['domain', ['+.foreign-fixture.net', '+.apple.com', '+.icloud.com',
        '+.cdn-apple.com', '+.mzstatic.com', '+.aaplimg.com', '+.apple-cloudkit.com', '+.servicewechat.com',
        '+.qpic.cn', '+.steamcontent.com', '+.cm.steampowered.com', '+.steamserver.net',
        '+.nas.internal', '+.private-fixture.net'].join('\n')],
};
const resources = [];
let core;
let logs = '';

async function waitFor(check, label) {
    for (let attempt = 0; attempt < 120; attempt++) {
        if (await check()) return;
        if (core?.exitCode !== null && core?.exitCode !== undefined) break;
        await delay(50);
    }
    assert.fail(`${label}\n${logs.slice(-8000)}`);
}
async function unusedPort() {
    const server = createServer();
    server.listen(0, '127.0.0.1');
    await once(server, 'listening');
    const port = server.address().port;
    await new Promise(resolve => server.close(resolve));
    return port;
}
async function dnsServer(ip, overrides = {}) {
    const socket = createSocket('udp4');
    resources.push(() => socket.close());
    socket.on('message', (query, peer) => {
        let end = 12;
        const labels = [];
        while (query[end]) {
            const length = query[end];
            labels.push(query.subarray(end + 1, end + 1 + length).toString('ascii'));
            end += length + 1;
        }
        const host = labels.join('.');
        end += 5;
        const header = Buffer.from(query.subarray(0, 12));
        header.writeUInt16BE(0x8180, 2);
        const isA = query.readUInt16BE(end - 4) === 1;
        header.writeUInt16BE(Number(isA), 6);
        const answerIp = overrides[host] || ip;
        const answer = isA ? Buffer.from([0xc0, 12, 0, 1, 0, 1, 0, 0, 0, 60, 0, 4, ...answerIp.split('.').map(Number)]) : Buffer.alloc(0);
        socket.send(Buffer.concat([header, query.subarray(12, end), answer]), peer.port, peer.address);
    });
    socket.bind(0, '127.0.0.1');
    await once(socket, 'listening');
    return `udp://127.0.0.1:${socket.address().port}`;
}
async function tcpProbe(port, host, target = 443) {
    const socket = createConnection({host: '127.0.0.1', port});
    socket.setTimeout(2000, () => socket.destroy());
    socket.on('error', () => {});
    socket.on('data', () => {});
    socket.on('connect', () => socket.write(`CONNECT ${host}:${target} HTTP/1.1\r\nHost: ${host}:${target}\r\n\r\n`));
    await new Promise(resolve => socket.once('close', resolve));
}
async function udpProbe(port, host) {
    const socket = createConnection({host: '127.0.0.1', port});
    const udp = createSocket('udp4');
    socket.on('error', () => {});
    socket.setTimeout(2000, () => socket.destroy());
    try {
        await once(socket, 'connect');
        socket.write(Buffer.from([5, 1, 0]));
        assert.deepEqual((await once(socket, 'data'))[0], Buffer.from([5, 0]));
        socket.write(Buffer.from([5, 3, 0, 1, 0, 0, 0, 0, 0, 0]));
        const [reply] = await once(socket, 'data');
        assert.deepEqual(reply.subarray(0, 4), Buffer.from([5, 0, 0, 1]));
        const address = reply.subarray(4, 8).join('.').replace(/^0\.0\.0\.0$/, '127.0.0.1');
        const name = Buffer.from(host);
        const packet = Buffer.concat([Buffer.from([0, 0, 0, 3, name.length]), name, Buffer.from([1, 187]), Buffer.from('test')]);
        await new Promise((resolve, reject) => udp.send(packet, reply.readUInt16BE(8), address, error => error ? reject(error) : resolve()));
        await delay(80);
    } finally {
        socket.destroy();
        udp.close();
    }
}
async function fakeIpQuery(port, host) {
    const socket = createSocket('udp4');
    const question = Buffer.concat(host.split('.').flatMap(label => [Buffer.from([label.length]), Buffer.from(label)]));
    const header = Buffer.from([0, 7, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
    const received = once(socket, 'message', {signal: AbortSignal.timeout(2000)});
    try {
        socket.send(Buffer.concat([header, question, Buffer.from([0, 0, 1, 0, 1])]), port, '127.0.0.1');
        const [reply] = await received;
        assert.ok(reply.readUInt16BE(6) > 0, `${host}: no DNS answer`);
        return reply.subarray(-4).join('.');
    } finally { socket.close(); }
}
async function stopCore() {
    if (core && core.exitCode === null) {
        core.kill();
        await once(core, 'exit');
    }
    core = undefined;
}

try {
    const configPath = join(temp, 'worker.json');
    const config = JSON.parse(await readFile(new URL('../worker-src/config.example.json', import.meta.url), 'utf8'));
    config.allowedTokens = {owner: 'common-test-token'};
    config.nodes[0].pbk = Buffer.alloc(32, 1).toString('base64url');
    config.fallbackCdnNodes = [];
    await writeFile(configPath, JSON.stringify(config));
    const templates = new Map();
    for (const filename of ['mihomo.yaml', 'mihomo-common.yaml']) {
        const path = new URL(`../templates/${filename}`, import.meta.url);
        const template = await readFile(path, 'utf8');
        templates.set(filename, template);
        const outputPath = join(temp, `${filename}.js`);
        // Omit templatePath for the default: exercise the actual shipped build path.
        await buildWorker({configPath, outputPath, ...(filename === 'mihomo.yaml' ? {} : {templatePath: path.pathname})});
        const source = await readFile(outputPath, 'utf8');
        const context = vm.createContext({URL, URLSearchParams, Headers, Response, AbortController,
            TextEncoder, TextDecoder, atob, btoa, setTimeout, clearTimeout, console,
            fetch: async () => { throw Error('offline'); }});
        const api = vm.runInContext(source.replace(/export default \{[\s\S]*$/, '({buildClashConfig, LOCAL_NODES, MIHOMO_TEMPLATE});'), context);
        assert.equal(api.MIHOMO_TEMPLATE, template);
        for (const upstream of ['', 'proxies:\n  - {name: Remote, type: socks5, server: 127.0.0.1, port: 9}\nrules:\n  - MATCH,DIRECT\n']) {
            const body = api.buildClashConfig(api.LOCAL_NODES, [443], upstream);
            assert.equal(body.split('\nrule-providers:\n')[1], template.split('\nrule-providers:\n')[1].replace('# EASY_ALL_WORKER_RULE', ''));
            assert.ok(!body.includes('# EASY_ALL_'));
            if (binary) {
                const file = join(temp, `${filename}-rendered.yaml`);
                await writeFile(file, body);
                const checked = spawnSync(binary, ['-t', '-d', process.env.MIHOMO_CHECK_HOME || temp, '-f', file], {encoding: 'utf8'});
                assert.equal(checked.status, 0, `${filename}: ${checked.stdout} ${checked.stderr}`);
            }
        }
        assert.ok(!template.includes('GEOSITE,'), 'COMMON must not load the DAT domain database');
        assert.ok(!template.includes('DOMAIN-KEYWORD,'), 'broad keywords must not override domestic services');
        assert.ok(template.includes('/apple-cn.mrs\''), 'Apple provider must load the mainland delivery subset');
        assert.ok(
            template.includes("'rule-set:direct-services,geosite-cn'"),
            `${filename}: domestic DNS policy must cover the cn domain library`,
        );
        assert.ok(
            template.includes("'RULE-SET,geoip-cn,DIRECT,no-resolve'"),
            `${filename}: CN GeoIP fallback must not resolve unknown domains`,
        );
        assert.ok(
            !template.includes("'RULE-SET,geoip-cn,DIRECT'"),
            `${filename}: resolving CN GeoIP fallback must remain removed`,
        );
        assert.equal(
            (template.match(/^    - 'GEOIP,LAN,DIRECT,no-resolve'$/gm) || []).length,
            1,
            `${filename}: exactly one LAN no-resolve rule must remain`,
        );
        assert.ok(
            !/^\s+- 'GEOIP,LAN,DIRECT'$/m.test(template),
            `${filename}: resolving duplicate LAN rule must remain removed`,
        );
        const rules = template.split('\nrules:\n')[1];
        for (const name of ['telegram-fallback', 'geoip-telegram']) {
            const quicRejectRule = `AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,${name},no-resolve)),REJECT`;
            const proxyRule = `RULE-SET,${name},PROXY,no-resolve`;
            assert.ok(
                rules.includes(quicRejectRule),
                `${filename}: ${name} QUIC rejection must not resolve unknown domains`,
            );
            assert.ok(
                !rules.includes(`AND,((NETWORK,UDP),(DST-PORT,443),(RULE-SET,${name})),REJECT`),
                `${filename}: resolving ${name} QUIC rejection must remain removed`,
            );
            assert.ok(
                rules.indexOf(quicRejectRule) >= 0 && rules.indexOf(quicRejectRule) < rules.indexOf(proxyRule),
                `${filename}: ${name} QUIC rejection must remain before its TCP proxy rule`,
            );
        }
        assert.ok(
            template.includes('# 未收录域名默认走 PROXY；LAN/CN IP 兜底仅匹配已有真实目标 IP。'),
            `${filename}: header must document the no-resolve fallback`,
        );
        assert.ok(
            !template.includes('# 未收录域名经代理查询海外 DNS，再按中国 IP 直连；未命中仍走 PROXY。'),
            `${filename}: stale resolving fallback header must remain removed`,
        );
        for (const host of fcm) assert.ok(template.includes(`      - '${host}'\n`), host);
    }
    console.log('COMMON default/full Worker embedding and rendered policy checks passed');
    if (!binary) {
        console.log('SKIP: COMMON real-core DNS/QUIC/failure checks require MIHOMO_CHECK_BIN');
    } else {
        for (const [name, [behavior, payload]] of Object.entries(fixtures)) {
            const source = join(temp, `${name}.txt`);
            await writeFile(source, payload + '\n');
            const converted = spawnSync(binary, ['convert-ruleset', behavior, 'text', source, join(temp, `${name}.mrs`)], {encoding: 'utf8'});
            assert.equal(converted.status, 0, converted.stdout + converted.stderr);
        }
        const domestic = await dnsServer('1.2.4.8');
        const foreign = await dnsServer('203.0.113.8', {'unknown-cn-mapped.net': '1.2.4.9'});
        const lan = await dnsServer('192.168.50.1');
        let downloads = 0;
        const broken = createHttpServer((request, response) => { downloads++; response.end('invalid MRS'); });
        broken.listen(0, '127.0.0.1');
        await once(broken, 'listening');
        resources.push(() => { broken.closeAllConnections(); broken.close(); });
        for (const [filename, template] of templates) {
            for (const cold of [false, true]) {
                const home = join(temp, `${filename}-${cold ? 'cold' : 'cached'}`);
                await mkdir(join(home, 'ruleset'), {recursive: true});
                const names = [...template.matchAll(/path: \.\/ruleset\/(\S+)\.mrs/g)].map(match => match[1]);
                assert.equal(names.length, filename === 'mihomo.yaml' ? 6 : 7, 'keep the MRS memory budget');
                // Do not reuse the old full-Apple cache, even when the new subset download fails.
                await copyFile(join(temp, 'geosite-apple.mrs'), join(home, 'ruleset', 'geosite-apple.mrs'));
                if (!cold) for (const name of names) await copyFile(join(temp, `${name}.mrs`), join(home, 'ruleset', `${name}.mrs`));
                const [port, controller, dnsPort] = await Promise.all([unusedPort(), unusedPort(), unusedPort()]);
                // Only substitute a policy that actually uses the client's system resolver.
                assert.ok(template.includes(privatePolicy), `${filename}: shared private DNS policy`);
                const replaced = template.replace(/^mixed-port:.*$/m, `mixed-port: ${port}`)
                    .replace(/^external-controller:.*$/m, `external-controller: '127.0.0.1:${controller}'`)
                    .replace('log-level: warning', 'log-level: info')
                    .replace(/tun:\n[\s\S]*?\ndns:/, 'tun:\n    enable: false\n\ndns:')
                    .replace("listen: '127.0.0.1:5335'", `listen: '127.0.0.1:${dnsPort}'`)
                    .replaceAll('https://223.5.5.5/dns-query', domestic).replaceAll('https://1.12.12.12/dns-query', domestic)
                    .replaceAll('https://1.1.1.1/dns-query#PROXY', foreign).replaceAll('https://8.8.8.8/dns-query#PROXY', foreign)
                    .replace(privatePolicy, `'rule-set:private-fallback,geosite-private': '${lan}'`)
                    // Preserve rule-providers, unlike the legacy GeoSite test harness.
                    .replace(/proxies:\n# EASY_ALL_PROXY_NODE[\s\S]*?\nrule-providers:/,
                        'proxies: []\nproxy-groups:\n  - {name: PROXY, type: select, proxies: [REJECT]}\n  - {name: TEST-DIRECT, type: select, proxies: [REJECT]}\nrule-providers:')
                    .replaceAll(',DIRECT', ',TEST-DIRECT')
                    .replace(/url: '[^']+'/g, `url: 'http://127.0.0.1:${broken.address().port}/invalid.mrs'`);
                const file = join(home, 'config.yaml');
                await writeFile(file, replaced);
                logs = '';
                const initialDownloads = downloads;
                core = spawn(binary, ['-d', home, '-f', file]);
                core.stdout.on('data', chunk => { logs += chunk; });
                core.stderr.on('data', chunk => { logs += chunk; });
                const api = `http://127.0.0.1:${controller}`;
                const query = async host => (await (await fetch(`${api}/dns/query?name=${host}&type=A`, {signal: AbortSignal.timeout(1500)})).json()).Answer;
                await waitFor(async () => {
                    try {
                        const {providers} = await (await fetch(`${api}/providers/rules`, {signal: AbortSignal.timeout(300)})).json();
                        const initialized = cold ? downloads - initialDownloads >= names.length : names.every(name => providers[name]?.ruleCount > 0);
                        return initialized && (await query('github.com'))?.length > 0;
                    } catch { return false; }
                }, `${filename} ${cold ? 'cold' : 'cached'} startup`);
                for (const [hosts, ip] of [
                    [['m5-x.amap.com', 'short.weixin.qq.com', 'servicewechat.com', 'www.doubao.com', 'weatherapi.vivo.com', ...appleDomestic, ...steamDownloads], '1.2.4.8'],
                    [['github.com', 'services.googleapis.cn', 'google.cn', 'gemini.google.com', 'chatgpt.com', 'steamcommunity.com', 'unknown-public.net', ...appleForeign], '203.0.113.8'],
                    [privateHosts, '192.168.50.1'],
                ]) for (const host of hosts) assert.ok((await query(host))?.some(answer => answer.data === ip), `${filename} ${host} DNS`);
                for (const host of fcm) assert.equal(await fakeIpQuery(dnsPort, host), '203.0.113.8', host);
                for (const root of wechat) for (const host of [root, `cdn.${root}`]) {
                    assert.equal(await fakeIpQuery(dnsPort, host), '1.2.4.8', `${filename} ${host}: WeChat real IP`);
                }
                for (const host of privateHosts) {
                    const ip = host === 'localhost' ? '127.0.0.1' : '192.168.50.1';
                    assert.equal(await fakeIpQuery(dnsPort, host), ip, `${filename} ${host}: private real IP`);
                }
                assert.match(await fakeIpQuery(dnsPort, 'ordinary-public.net'), /^198\.18\./);
                const routed = async (host, route, udp = false, target = 443) => {
                    const start = logs.length;
                    if (udp) await udpProbe(port, host); else await tcpProbe(port, host, target);
                    await waitFor(() => logs.slice(start).split('\n').some(line => line.includes(`${host}:${target}`) && line.includes(`using ${route}`)), `${filename}: ${host} ${udp ? 'UDP' : 'TCP'} -> ${route}`);
                    return logs.slice(start);
                };
                for (const host of ['github.com', 'gemini.google.com', 'chatgpt.com', 'services.googleapis.cn', 'google.cn', 'ssl.gstatic.com', 'grazie.ai', 'steamcommunity.com']) {
                    await routed(host, 'PROXY');
                    await routed(host, 'REJECT', true);
                }
                for (const host of ['www.doubao.com', 'm5-x.amap.com', 'www.apple.com', 'host.home.arpa']) await routed(host, 'TEST-DIRECT');
                for (const host of appleDomestic) {
                    assert.match(await routed(host, 'TEST-DIRECT'), /RuleSet\(apple-cn-fallback\)/);
                    await routed(host, 'TEST-DIRECT', true);
                }
                for (const host of appleForeign) {
                    await routed(host, 'PROXY');
                    await routed(host, 'REJECT', true);
                }
                for (const host of ['0.0.0.0', '0.0.0.1', '0.255.255.254']) {
                    assert.match(await routed(host, 'REJECT'), /IPCIDR\(0\.0\.0\.0\/8\)/);
                    assert.match(await routed(host, 'REJECT', true), /IPCIDR\(0\.0\.0\.0\/8\)/);
                    await routed(host, 'REJECT', false, 5228);
                }
                for (const host of ['servicewechat.com', 'cdn.qpic.cn']) {
                    assert.match(await routed(host, 'TEST-DIRECT'), /RuleSet\(wechat-services\)/);
                    await routed(host, 'TEST-DIRECT', true);
                }
                for (const host of steamDownloads) {
                    assert.match(await routed(host, 'TEST-DIRECT'), /RuleSet\(steam-download\)/);
                    await routed(host, 'TEST-DIRECT', true);
                }
                for (const host of ['nas.internal', 'nas.localdomain']) {
                    assert.match(await routed(host, 'TEST-DIRECT'), /RuleSet\(private-fallback\)/);
                }
                await routed('www.doubao.com', 'TEST-DIRECT', true);
                await routed('unknown-public.net', 'PROXY');
                await routed('unknown-public.net', 'REJECT', true);
                await routed('149.154.167.50', 'PROXY');
                await routed('149.154.167.50', 'REJECT', true);
                // Do not use a DNS fixture address: reverse mapping would restore its domain.
                await routed('1.2.4.9', cold ? 'PROXY' : 'TEST-DIRECT');
                await routed('1.2.4.9', 'PROXY', false, 5228);
                await routed('192.168.1.1', 'TEST-DIRECT', false, 5228);
                if (!cold) {
                    const privateHost = 'nas.private-fixture.net';
                    assert.ok((await query(privateHost))?.some(answer => answer.data === '192.168.50.1'));
                    assert.equal(await fakeIpQuery(dnsPort, privateHost), '192.168.50.1', 'private MRS real IP');
                    assert.match(await routed(privateHost, 'TEST-DIRECT'), /RuleSet\(geosite-private\)/);
                    assert.ok((await query('www.google-fixture.net'))?.some(answer => answer.data === '203.0.113.8'));
                    assert.match(await routed('www.google-fixture.net', 'REJECT', true), /RuleSet,geosite-google/);
                    assert.ok((await query('www.apple-cn-fixture.net'))?.some(answer => answer.data === '1.2.4.8'));
                    assert.match(await routed('www.apple-cn-fixture.net', 'TEST-DIRECT'), /RuleSet\(geosite-apple-cn\)/);
                    const response = await fetch(`${api}/providers/rules/geoip-cn`, {method: 'PUT', signal: AbortSignal.timeout(2000)});
                    assert.ok(!response.ok, 'malformed MRS update must fail');
                    await routed('1.2.4.10', 'TEST-DIRECT');
                    assert.ok(
                        (await query('unknown-cn-mapped.net'))?.some(answer => answer.data === '1.2.4.9'),
                        'unmatched domain must resolve to the CN fixture IP',
                    );
                    await routed('unknown-cn-mapped.net', 'REJECT', true);
                    await routed('unknown-cn-mapped.net', 'PROXY');
                    assert.match(await routed('www.cn-fixture.net', 'TEST-DIRECT'), /RuleSet\(geosite-cn\)/);
                    assert.match(await routed('www.hxkba.com', 'TEST-DIRECT'), /RuleSet\(geosite-cn\)/);
                    if (filename === 'mihomo-common.yaml') {
                        assert.match(await routed('www.foreign-fixture.net', 'PROXY'), /RuleSet\(geosite-foreign\)/);
                    }
                }
                await stopCore();
                console.log(`COMMON ${filename} ${cold ? 'cold failure fallback' : 'cached rules and failed update'} DNS/FCM/TCP/UDP checks passed`);
            }
        }
    }
} finally {
    await stopCore();
    for (const close of resources.reverse()) close();
    await rm(temp, {recursive: true, force: true});
}
