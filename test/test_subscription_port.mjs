// 订阅端口的用户可见契约：同一条 Reality 订阅下发的端口，必须落在当前小时池内，
// 并且与 profiles/reality.sh 的 bash 计算（整秒 % 6）完全一致；固定模式下发 443。
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import subscription from '../lib/reality-subscription.js';

const {
    getHourCount, dynamicPortSlot, dynamicPort, nodePort,
} = subscription;

const PORT_BASE = 10000;
const PORTS_PER_HOUR = 6;
const PORT_MAX = PORT_BASE + 366 * 24 * PORTS_PER_HOUR - 1;

// 与 bash 侧独立实现的参考算法：按 Asia/Shanghai 的「年内小时数」和「整秒取模」。
function expectedPort(timestamp) {
    const shifted = new Date(timestamp + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(shifted.getUTCFullYear(), 0, 1);
    const dayStart = Date.UTC(
        shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate(),
    );
    const dayOfYear = Math.floor((dayStart - yearStart) / 86_400_000) + 1;
    const elapsedHours = (dayOfYear - 1) * 24 + shifted.getUTCHours();
    const slot = Math.floor(timestamp / 1000) % PORTS_PER_HOUR;
    return PORT_BASE + elapsedHours * PORTS_PER_HOUR + slot;
}

const samples = [
    Date.UTC(2026, 0, 1, 0, 0, 0),
    Date.UTC(2026, 0, 1, 0, 0, 5),
    Date.UTC(2026, 2, 29, 15, 59, 59),
    Date.UTC(2026, 11, 31, 23, 59, 59),
    Date.UTC(2027, 6, 4, 7, 30, 17),
    Date.UTC(2024, 1, 29, 12, 0, 0),
];

for (const base of samples) {
    // 同一秒内的毫秒抖动不能改变端口：服务端展示与订阅下发必须是同一个值。
    for (const jitter of [0, 1, 240, 999]) {
        const now = base + jitter;
        const port = nodePort(now, 'dynamic');
        assert.equal(port, expectedPort(now), `dynamic port must follow the bash formula at ${now}`);
        assert.equal(port, dynamicPort(getHourCount(now), dynamicPortSlot(now)));
        assert.ok(port >= PORT_BASE && port <= PORT_MAX, 'port must stay inside the dynamic range');
        const hourBase = dynamicPort(getHourCount(now), 0);
        assert.ok(port >= hourBase && port < hourBase + PORTS_PER_HOUR, 'port must stay in the current hour pool');
    }
    assert.equal(nodePort(base, '443'), 443, 'fixed mode must publish the Reality port');
    assert.throws(() => nodePort(base, 'invalid'), /Invalid mode/);
}

console.log('ok - subscription port contract');

// 订阅渲染器的用户可见契约：模板里的端口占位符只属于本机 Reality 节点，
// 聚合节点（reality/xhttp/mieru）必须原样下发；模板不完整时一律 503。
const renderRoot = fs.mkdtempSync(path.join(
    process.env.TMP_ROOT_FALLBACK || '/tmp', 'easy-all-subscription-render-',
));
process.on('exit', () => fs.rmSync(renderRoot, { recursive: true, force: true }));

function render(kind, content) {
    const file = path.join(renderRoot, `${kind}-${Math.random().toString(16).slice(2)}.txt`);
    fs.writeFileSync(file, content);
    const result = { code: 0, body: '' };
    subscription[kind]({
        method: 'GET',
        variables: {
            easy_all_reality_port_mode: 'dynamic',
            request_filename: file,
        },
        headersOut: {},
        return(code, body) {
            result.code = code;
            result.body = body;
        },
    });
    return result;
}

const OWN_LINK = 'vless://11111111-2222-4111-8111-111111111111@198.51.100.10:__EASY_ALL_REALITY_PORT__?encryption=none&security=reality&type=tcp&sni=swdist.apple.com#MY_REALITY';
const REALITY_LINK = 'vless://22222222-2222-4222-8222-222222222222@r.example.com:8443?encryption=none&security=reality&type=tcp&sni=www.example.com#另一台Reality';
const MIERU_LINK = 'mierus://agguser:agg-password-12345@m.example.com?mtu=1400&multiplexing=MULTIPLEXING_LOW&port=50000-50512&profile=default&protocol=TCP#备用Mieru';

const multi = render('base64', Buffer.from([OWN_LINK, REALITY_LINK, MIERU_LINK].join('\n')).toString('base64') + '\n');
assert.equal(multi.code, 200, 'aggregated base64 template must render');
const multiBody = Buffer.from(multi.body, 'base64').toString('utf8');
assert.ok(!multiBody.includes('__EASY_ALL_REALITY_PORT__'), 'placeholder must be replaced');
const [ownLine, ...aggregated] = multiBody.split('\n');
assert.match(ownLine, /^vless:\/\/[^@]+@198\.51\.100\.10:\d+\?/, 'own node keeps its host and gets a real port');
assert.deepEqual(aggregated, [REALITY_LINK, MIERU_LINK], 'aggregated links must pass through unchanged');
const ownPort = Number(ownLine.match(/@198\.51\.100\.10:(\d+)\?/)[1]);
assert.ok(ownPort >= PORT_BASE && ownPort <= PORT_MAX, 'own node port must stay in the dynamic range');

for (const [label, body] of [
    ['two placeholders', Buffer.from([OWN_LINK, OWN_LINK].join('\n')).toString('base64')],
    ['no placeholder', Buffer.from(REALITY_LINK).toString('base64')],
    ['unknown scheme', Buffer.from([OWN_LINK, 'http://evil.example.com/'].join('\n')).toString('base64')],
    ['plain link without reality', Buffer.from('vless://x@h:443?encryption=none&security=tls#x').toString('base64')],
]) {
    assert.equal(render('base64', body + '\n').code, 503, `base64 template must reject ${label}`);
}

const MIHOMO_TEMPLATE = 'proxies:\n  - name: "MY_REALITY"\n    port: __EASY_ALL_REALITY_PORT__\n  - name: "另一台Reality"\n    port: 8443\nproxy-groups:\n# EASY_ALL_REALITY_TEMPLATE_END_V1\n';
const mihomo = render('mihomo', MIHOMO_TEMPLATE);
assert.equal(mihomo.code, 200, 'aggregated mihomo template must render');
assert.match(mihomo.body, /    port: \d+\n/, 'mihomo own node gets a real port');
assert.ok(mihomo.body.includes('    port: 8443\n'), 'aggregated node keeps its literal port');
assert.ok(!mihomo.body.includes('__EASY_ALL_REALITY_PORT__'), 'mihomo placeholder must be replaced');
assert.ok(!mihomo.body.includes('EASY_ALL_REALITY_TEMPLATE_END_V1'), 'end marker must be stripped');
assert.equal(render('mihomo', MIHOMO_TEMPLATE.replace(/\n# EASY_ALL_REALITY_TEMPLATE_END_V1\n$/, '\n')).code, 503,
    'mihomo template without the end marker must be rejected');
assert.equal(render('mihomo', MIHOMO_TEMPLATE.replace('    port: 8443\n', '    port: __EASY_ALL_REALITY_PORT__\n')).code, 503,
    'mihomo template with a second port placeholder must be rejected');

console.log('ok - reality subscription renderer contract');
