import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import vm from 'node:vm';

const source = await readFile(new URL('../worker.js', import.meta.url), 'utf8');
const handleRequest = vm.runInNewContext(
    source.replace(/export default \{[\s\S]*$/, `
        createWorkerHandler({
            allowedTokenValues: new Set(['test']),
            localNodes: LOCAL_NODES,
            upstreamUrl: 'https://upstream.invalid',
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
        assert.ok(content.includes('vmiss.tiandi.party'));
        assert.ok(content.includes('bwg.tiandi.party'));
    }
}
console.log('Worker node visibility checks passed');
