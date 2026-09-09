import { readFile, writeFile, rename, rm, mkdtemp } from 'node:fs/promises';
import { dirname, resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));

export async function buildWorker({
    configPath = resolve(root, 'worker-src/config.local.json'),
    outputPath = resolve(root, 'worker-src/worker.js'),
    templatePath = resolve(root, 'templates/mihomo.yaml'),
    sourcePath = resolve(root, 'worker-src/index.js'),
    now = Date.now(),
} = {}) {
    let config;
    try { config = JSON.parse(await readFile(configPath, 'utf8')); }
    catch { throw new Error('Cannot read private config; copy worker-src/config.example.json to config.local.json and fill it in.'); }
    const requireValue = (ok, label) => { if (!ok) throw new Error(`Invalid private config: ${label}`); };
    const nonempty = value => typeof value === 'string' && value.trim() && !/[\r\n\0]/.test(value);
    requireValue(config && typeof config === 'object', 'object required');
    requireValue(config.allowedTokens && !Array.isArray(config.allowedTokens) && typeof config.allowedTokens === 'object', 'allowedTokens');
    const tokens = Object.values(config.allowedTokens);
    requireValue(
        tokens.every(value => nonempty(value) && value.length >= 16) &&
            new Set(tokens).size === tokens.length &&
            (config.delegateTokenValidation === true || tokens.length > 0),
        'tokens must be unique strings of at least 16 characters'
    );
    for (const key of ['externalSubUrl', 'vpsSubUrl']) {
        if (key === 'externalSubUrl' && config[key] === '') continue;
        let url;
        try { url = new URL(config[key]); } catch {}
        requireValue(url?.protocol === 'https:' && !url.username && !url.password, key);
    }
    requireValue(
        config.vpsCdnUseRequestToken === undefined || typeof config.vpsCdnUseRequestToken === 'boolean',
        'vpsCdnUseRequestToken'
    );
    requireValue(
        config.requireDynamicCdn === undefined || typeof config.requireDynamicCdn === 'boolean',
        'requireDynamicCdn'
    );
    requireValue(
        config.delegateTokenValidation === undefined ||
            typeof config.delegateTokenValidation === 'boolean',
        'delegateTokenValidation'
    );
    requireValue(
        config.sourceSecret === undefined || nonempty(config.sourceSecret),
        'sourceSecret'
    );
    requireValue(
        !config.vpsCdnUseRequestToken || nonempty(config.sourceSecret),
        'sourceSecret is required when vpsCdnUseRequestToken is enabled'
    );
    requireValue(
        config.subscriptionDownloadName === undefined ||
            /^[A-Za-z0-9._-]{1,64}$/.test(config.subscriptionDownloadName),
        'subscriptionDownloadName'
    );
    for (const key of ['nodes', 'fallbackCdnNodes']) {
        requireValue(Array.isArray(config[key]), key);
        for (const node of config[key]) {
            requireValue(node && ['name', 'host', 'uuid'].every(field => nonempty(node[field])), `${key} node fields`);
            requireValue(/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(node.uuid), `${key} UUID`);
            requireValue(node.type === 'vless', `${key} type`);
            if (key === 'nodes') {
                requireValue(node.security === 'reality' && node.network === 'tcp' && ['sni', 'pbk', 'sid', 'fp'].every(field => nonempty(node[field])), 'Reality parameters');
            } else {
                requireValue(node.security === 'tls' && ['xhttp', 'ws'].includes(node.network) && nonempty(node.path) && node.path.startsWith('/'), 'CDN parameters');
            }
            requireValue(node.port === undefined || Number.isInteger(node.port) && node.port > 0 && node.port <= 65535, 'port');
            requireValue(node.server === undefined || nonempty(node.server), `${key} server`);
            const allowedIpVersions = key === 'nodes' ? ['ipv4', 'dual'] : ['ipv4', 'ipv6'];
            requireValue(
                node.ipVersion === undefined || allowedIpVersions.includes(node.ipVersion),
                `${key} IP family`
            );
        }
    }
    requireValue(
        config.nodes.length > 0 || config.requireDynamicCdn === true || Boolean(config.externalSubUrl),
        'at least one node source'
    );
    const names = [...config.nodes, ...config.fallbackCdnNodes].map(node => node.name);
    requireValue(new Set(names).size === names.length && names.every(name => !['PROXY', '🇺🇸优选', 'DIRECT', 'REJECT'].includes(name)), 'unique, non-reserved node names');
    requireValue(
        config.nodes.every(node => !/^🇺🇸优选[1-6]$/.test(node.name)),
        'Reality node names must not use reserved CDN names'
    );
    const [template, source] = await Promise.all([
        readFile(templatePath, 'utf8'),
        readFile(sourcePath, 'utf8'),
    ]);
    for (const marker of ['# EASY_ALL_PROXY_NODE', '# EASY_ALL_PROXY_GROUP', '# EASY_ALL_PROXY_NAME']) {
        requireValue(template.split('\n').filter(line => line === marker).length === 1, `template marker ${marker}`);
    }
    const date = new Date(now + 8 * 60 * 60 * 1000).toISOString().slice(0, 10);
    let previous = '';
    try { previous = await readFile(outputPath, 'utf8'); }
    catch (error) { if (error.code !== 'ENOENT') throw error; }
    const last = previous.match(/^const WORKER_VERSION = ['"](\d{4}-\d{2}-\d{2})-v(\d+)['"];$/m);
    const revision = last?.[1] === date ? Number(last[2]) + 1 : 0;
    const version = `${date}-v${revision}`;
    const content = '// Generated by npm run build:worker. Contains private configuration; do not commit.\n'
        + `const WORKER_VERSION = ${JSON.stringify(version)};\n`
        + `const PRIVATE_CONFIG = ${JSON.stringify(config)};\n`
        + `const MIHOMO_TEMPLATE = ${JSON.stringify(template)};\n\n` + source;
    // Validate before touching the existing deployment artifact. Never print compiler
    // output: a syntax error could include a line containing embedded credentials.
    const tempDir = await mkdtemp(join(dirname(outputPath), '.worker-build-'));
    try {
        const temp = join(tempDir, 'worker.mjs');
        await writeFile(temp, content, { mode: 0o600 });
        const checked = spawnSync(process.execPath, ['--check', temp], { stdio: 'ignore' });
        if (checked.status !== 0) throw new Error('Generated Worker syntax check failed');
        await rename(temp, outputPath);
    } finally {
        await rm(tempDir, { recursive: true, force: true });
    }
    return version;
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const configPath = process.env.EASY_ALL_WORKER_CONFIG_PATH
        ? resolve(process.env.EASY_ALL_WORKER_CONFIG_PATH)
        : undefined;
    const outputPath = process.env.EASY_ALL_WORKER_OUTPUT_PATH
        ? resolve(process.env.EASY_ALL_WORKER_OUTPUT_PATH)
        : undefined;
    const templatePath = process.env.EASY_ALL_WORKER_TEMPLATE_PATH
        ? resolve(process.env.EASY_ALL_WORKER_TEMPLATE_PATH)
        : undefined;
    const sourcePath = process.env.EASY_ALL_WORKER_SOURCE_PATH
        ? resolve(process.env.EASY_ALL_WORKER_SOURCE_PATH)
        : undefined;
    try {
        const version = await buildWorker({
            configPath,
            outputPath,
            templatePath,
            sourcePath,
        });
        console.log(`Built worker.js: ${version}`);
    }
    catch (error) { console.error(error.message); process.exitCode = 1; }
}
