import assert from 'node:assert/strict';
import { existsSync } from 'node:fs';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const workerPath = existsSync(new URL('../worker-src/worker.js', import.meta.url))
    ? new URL('../worker-src/worker.js', import.meta.url)
    : new URL('../worker.js', import.meta.url);
if (!existsSync(workerPath)) {
    console.log('worker.js not found, skipping local node test');
    process.exit(0);
}

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
            assert.ok(content.includes('vmiss.tiandi.party'));
        } else {
            assert.ok(!content.includes('vmiss.tiandi.party'));
        }
        assert.ok(content.includes('bwg.tiandi.party'));
    }
}
console.log('Worker node visibility checks passed');
