import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';

const workerPath = new URL('../worker.sanitized.js', import.meta.url).href;
const originalFetch = globalThis.fetch;
const originalNow = Date.now;
const originalConsoleError = console.error;

const unavailableFetch = async () => {
    throw new Error('upstream disabled for tests');
};
globalThis.fetch = unavailableFetch;
console.error = () => {};

function expectedDynamicPort(isoTime) {
    const nowUtc8 = new Date(Date.parse(isoTime) + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
    const hourCount = Math.floor(
        (nowUtc8.getTime() - yearStart) / 3_600_000
    );
    return 10_000 + Math.floor(hourCount / 3);
}

function bashDynamicPort(dayOfYear, hour, year) {
    const profilePath = new URL('../profiles/reality.sh', import.meta.url)
        .pathname.replaceAll("'", "'\\''");
    const script = `
        source '${profilePath}'
        date() {
            case "$*" in
            +%j) printf '%03d\\n' "${dayOfYear}" ;;
            +%H) printf '%02d\\n' "${hour}" ;;
            +%Y) printf '%04d\\n' "${year}" ;;
            *) return 1 ;;
            esac
        }
        dynamic_port_for_current_window
    `;
    const result = spawnSync('bash', ['-c', script], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    return Number(result.stdout.trim());
}

async function loadWorkerAt(isoTime, fetchImpl = unavailableFetch) {
    const now = Date.parse(isoTime);
    Date.now = () => now;
    globalThis.fetch = fetchImpl;
    return import(`${workerPath}?test=${encodeURIComponent(isoTime)}`);
}

function portForServer(content, server) {
    const start = content.indexOf(`server: "${server}"`);
    assert.notEqual(start, -1, `missing server ${server}`);
    const match = content.slice(start, start + 240).match(/\n\s+port: (\d+)/);
    assert.ok(match, `missing port for server ${server}`);
    return Number(match[1]);
}

async function testHttpContract() {
    const worker = await loadWorkerAt('2026-08-26T03:00:00Z');
    const token = 'REDACTED_TOKEN_01';

    const methodResponse = await worker.default.fetch(
        new Request('https://worker.example/subscribe?token=' + token, {
            method: 'POST',
        })
    );
    assert.equal(methodResponse.status, 405);
    assert.equal(methodResponse.headers.get('Allow'), 'GET, HEAD');

    const pathResponse = await worker.default.fetch(
        new Request('https://worker.example/other?token=' + token)
    );
    assert.equal(pathResponse.status, 404);

    const tokenResponse = await worker.default.fetch(
        new Request('https://worker.example/subscribe?token=invalid')
    );
    assert.equal(tokenResponse.status, 403);

    const headResponse = await worker.default.fetch(
        new Request('https://worker.example/subscribe?token=' + token, {
            method: 'HEAD',
        })
    );
    assert.equal(headResponse.status, 200);
    assert.equal(await headResponse.text(), '');
}

async function testFallbackPorts() {
    const isoTime = '2026-08-26T03:00:00Z';
    const worker = await loadWorkerAt(isoTime);
    const token = 'REDACTED_TOKEN_01';
    const expected = expectedDynamicPort(isoTime);

    const clashResponse = await worker.default.fetch(
        new Request(
            'https://worker.example/subscribe?token=' + token + '&flag=clash'
        ),
        { SUB_DOWNLOAD_NAME: 'CURRENT_TEST' }
    );
    assert.equal(clashResponse.status, 200);
    assert.equal(
        clashResponse.headers.get('X-Easy-All-Warning'),
        'xflash-unavailable-local-only'
    );
    const clash = await clashResponse.text();
    assert.equal(portForServer(clash, 'node-2.example.invalid'), expected);
    assert.equal(portForServer(clash, 'node-3.example.invalid'), 443);
    assert.match(clash, /- name: 延迟测试\n\s+type: select/);
    assert.match(clash, /url: 'https:\/\/cp\.cloudflare\.com'/);
    assert.match(clash, /timeout: 15000/);
    assert.doesNotMatch(clash, /gstatic\.com\/generate_204/);
    assert.doesNotMatch(clash, /type: url-test/);
    assert.equal(
        clashResponse.headers.get('Content-Disposition'),
        'attachment; filename="CURRENT_TEST"'
    );

    const base64Response = await worker.default.fetch(
        new Request('https://worker.example/subscribe?token=' + token)
    );
    assert.equal(
        base64Response.headers.get('X-Easy-All-Warning'),
        'xflash-unavailable-local-only'
    );
    const base64 = await base64Response.text();
    const links = Buffer.from(base64, 'base64').toString('utf8').split('\n');
    assert.equal(links.length, 2);
    assert.ok(
        links.some((link) => link.includes('@node-2.example.invalid:' + expected + '?'))
    );
    assert.ok(
        links.some((link) => link.includes('@node-3.example.invalid:443?'))
    );

    const allResponse = await worker.default.fetch(
        new Request(
            'https://worker.example/subscribe?token=' + token + '&node=all&flag=clash'
        )
    );
    const all = await allResponse.text();
    assert.equal(portForServer(all, 'node-1.example.invalid'), expected);
    assert.equal(portForServer(all, 'node-2.example.invalid'), expected);
    assert.equal(portForServer(all, 'node-3.example.invalid'), 443);
}

async function testOnlineXflashMerge() {
    const upstream = `mixed-port: 7890
proxies:
  - name: UPSTREAM_SECRET_NODE
    type: vless
    server: upstream-secret.example
    port: 443
    uuid: UPSTREAM_SECRET_UUID
proxy-groups:
  - name: XFLASH
    type: select
    proxies: [UPSTREAM_SECRET_NODE]
rules:
  - DOMAIN-SUFFIX,upstream-rule.example,XFLASH
  - MATCH,XFLASH
`;
    let fetchCalls = 0;
    const worker = await loadWorkerAt(
        '2026-08-26T04:00:00Z',
        async () => {
            fetchCalls += 1;
            return new Response(upstream, {
                status: 200,
                headers: { 'Content-Type': 'text/yaml' },
            });
        }
    );
    const response = await worker.default.fetch(
        new Request(
            'https://worker.example/subscribe?token=REDACTED_TOKEN_01&flag=clash'
        )
    );
    const clash = await response.text();
    assert.equal(fetchCalls, 1);
    assert.equal(response.headers.get('X-Easy-All-Warning'), null);
    assert.match(clash, /DOMAIN-SUFFIX,upstream-rule\.example,PROXY/);
    assert.match(clash, /MATCH,PROXY/);
    assert.match(clash, /UPSTREAM_SECRET_NODE/);
    assert.match(clash, /upstream-secret\.example/);
    assert.match(clash, /UPSTREAM_SECRET_UUID/);
    assert.equal(
        portForServer(clash, 'node-2.example.invalid'),
        expectedDynamicPort('2026-08-26T04:00:00Z')
    );
    assert.equal(portForServer(clash, 'node-3.example.invalid'), 443);

    let base64FetchCalls = 0;
    const base64Worker = await loadWorkerAt(
        '2026-08-26T05:00:00Z',
        async () => {
            base64FetchCalls += 1;
            return new Response(
                Buffer.from(
                    'vless://UPSTREAM_ONLINE_NODE@upstream.example:443'
                ).toString('base64'),
                { status: 200 }
            );
        }
    );
    const base64Response = await base64Worker.default.fetch(
        new Request('https://worker.example/subscribe?token=REDACTED_TOKEN_01')
    );
    const links = Buffer.from(await base64Response.text(), 'base64')
        .toString('utf8')
        .split('\n');
    assert.equal(base64FetchCalls, 1);
    assert.equal(base64Response.headers.get('X-Easy-All-Warning'), null);
    assert.equal(links.length, 3);
    assert.ok(links.every((link) => link.startsWith('vless://')));
    assert.ok(links.some((link) => link.includes('UPSTREAM_ONLINE_NODE')));
}

function testFallbackContainsNoXflashNodes() {
    const workerSource = readFileSync(
        new URL('../worker.sanitized.js', import.meta.url),
        'utf8'
    );
    const fallbackMatch = workerSource.match(
        /const XFLASH_FALLBACK_CONFIG = String\.raw`\n([\s\S]*?)\n`;/
    );
    assert.ok(fallbackMatch, 'missing embedded XFLASH fallback config');
    const fallbackSource = fallbackMatch[1];
    assert.doesNotMatch(fallbackSource, /type:\s*(?:mieru|anytls)/);
    assert.doesNotMatch(fallbackSource, /REDACTED_TRAFFIC_PATTERN/);
    assert.doesNotMatch(fallbackSource, /♻️自动选择|🔯故障转移/);
    assert.match(fallbackSource, /RULE-SET,gfw,XFLASH/);
    assert.match(fallbackSource, /proxies:\nproxy-groups:\nrule-providers:/);
}

async function testRotationBoundaries() {
    const cases = [
        ['2026-01-01T02:59:00+08:00', 1, 2, 2026, 10_000],
        ['2026-01-01T03:00:00+08:00', 1, 3, 2026, 10_001],
        ['2026-01-01T23:59:00+08:00', 1, 23, 2026, 10_007],
        ['2026-01-02T00:00:00+08:00', 2, 0, 2026, 10_008],
        ['2028-12-31T21:00:00+08:00', 366, 21, 2028, 12_927],
    ];
    for (const [isoTime, dayOfYear, hour, year, expected] of cases) {
        const worker = await loadWorkerAt(isoTime);
        const response = await worker.default.fetch(
            new Request(
                'https://worker.example/subscribe?token=REDACTED_TOKEN_01&flag=clash'
            )
        );
        assert.equal(
            portForServer(await response.text(), 'node-2.example.invalid'),
            expected,
            `unexpected port at ${isoTime}`
        );
        assert.equal(
            bashDynamicPort(dayOfYear, hour, year),
            expected,
            `Bash and Worker disagree at ${isoTime}`
        );
    }
}

try {
    await testHttpContract();
    await testFallbackPorts();
    await testOnlineXflashMerge();
    testFallbackContainsNoXflashNodes();
    await testRotationBoundaries();
    console.log('ok - sanitized Worker tests passed');
} finally {
    globalThis.fetch = originalFetch;
    Date.now = originalNow;
    console.error = originalConsoleError;
}
