import assert from 'node:assert/strict';
import { readFile, writeFile, mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import vm from 'node:vm';
import { buildWorker } from '../scripts/build-worker.mjs';

const temp = await mkdtemp(join(tmpdir(), 'worker-visibility-test-'));
try {
    const config = JSON.parse(await readFile(
        new URL('../worker-src/config.example.json', import.meta.url),
        'utf8'
    ));
    const baseNode = config.nodes[0];
    config.allowedTokens = { owner: 'offline-test-token' };
    config.nodes = [
        { ...baseNode, name: 'Visible Reality', host: 'visible.example.com' },
        {
            ...baseNode,
            name: 'Optional Reality',
            host: 'optional.example.com',
            optional: true,
        },
    ];
    const configPath = join(temp, 'config.json');
    const workerPath = join(temp, 'worker.mjs');
    await writeFile(configPath, JSON.stringify(config));
    await buildWorker({ configPath, outputPath: workerPath });

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
                assert.ok(content.includes('optional.example.com'));
            } else {
                assert.ok(!content.includes('optional.example.com'));
            }
            assert.ok(content.includes('visible.example.com'));
        }
    }
} finally {
    await rm(temp, { recursive: true, force: true });
}
console.log('Worker node visibility checks passed');
