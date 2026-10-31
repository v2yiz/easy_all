import { readFile, writeFile, rename, rm, mkdtemp, mkdir } from 'node:fs/promises';
import { realpathSync } from 'node:fs';
import { dirname, resolve, join } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const root = fileURLToPath(new URL('../', import.meta.url));
const configHome = process.env.XDG_CONFIG_HOME || join(homedir(), '.config');
const stateHome = process.env.XDG_STATE_HOME || join(homedir(), '.local/state');
const defaultConfigPath = join(configHome, 'easy_all/worker.json');
const defaultOutputPath = join(stateHome, 'easy_all/worker.js');

export async function buildWorker({
    configPath = defaultConfigPath,
    outputPath = defaultOutputPath,
    templatePath = resolve(root, 'templates/mihomo.yaml'),
    sourcePath = resolve(root, 'worker-src/index.js'),
    now = Date.now(),
} = {}) {
    let config;
    try { config = JSON.parse(await readFile(configPath, 'utf8')); }
    catch { throw new Error(`Cannot read private config: ${configPath}`); }
    const requireValue = (ok, label) => { if (!ok) throw new Error(`Invalid private config: ${label}`); };
    const nonempty = value => typeof value === 'string' && value.trim() && !/[\r\n\0]/.test(value);
    requireValue(config && typeof config === 'object', 'object required');
    requireValue(config.allowedTokens && !Array.isArray(config.allowedTokens) && typeof config.allowedTokens === 'object', 'allowedTokens');
    const tokens = Object.values(config.allowedTokens);
    requireValue(
        tokens.every(value => nonempty(value) && value.length >= 8) &&
            new Set(tokens).size === tokens.length &&
            (config.delegateTokenValidation === true || tokens.length > 0),
        'tokens must be unique strings of at least 8 characters'
    );
    delete config.externalSubUrl;
    // The installer injects its own VPS source before deploying an aggregation input.
    if (config.vpsSubUrl !== undefined && config.vpsSubUrl !== '') {
        let url;
        try { url = new URL(config.vpsSubUrl); } catch {}
        requireValue(url?.protocol === 'https:' && !url.username && !url.password, 'vpsSubUrl');
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
        config.delegateTokenValidation !== true ||
            (nonempty(config.vpsSubUrl) && config.requireDynamicCdn === true),
        'delegateTokenValidation requires vpsSubUrl and requireDynamicCdn'
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
    // Direct aggregation nodes may be VLESS/Reality, Trojan/TLS or Mieru; CDN fallbacks stay VLESS.
    const validTrojanAlpn = value => {
        const list = Array.isArray(value)
            ? value
            : typeof value === 'string' ? value.split(',') : null;
        return Boolean(list) && list.length > 0 &&
            list.every(item => ['h2', 'http/1.1'].includes(String(item).trim()));
    };
    const MIERU_MULTIPLEXING_LEVELS = [
        'MULTIPLEXING_OFF', 'MULTIPLEXING_LOW', 'MULTIPLEXING_MIDDLE', 'MULTIPLEXING_HIGH',
    ];
    for (const key of ['nodes', 'fallbackCdnNodes']) {
        requireValue(Array.isArray(config[key]), key);
        for (const node of config[key]) {
            requireValue(
                node && typeof node === 'object' && nonempty(node.name) && nonempty(node.host),
                `${key} node fields`
            );
            requireValue(
                ['vless', 'trojan', 'mieru'].includes(node.type),
                `${key} type`
            );
            requireValue(
                node.portRange === undefined || node.type === 'mieru',
                `${key} port range is Mieru-only`
            );
            if (node.type === 'mieru') {
                requireValue(key === 'nodes', 'mieru nodes must be direct nodes');
                requireValue(
                    typeof node.username === 'string' &&
                        /^[A-Za-z0-9._~-]{1,64}$/.test(node.username),
                    'mieru username'
                );
                requireValue(
                    typeof node.password === 'string' &&
                        /^[A-Za-z0-9._~-]{8,64}$/.test(node.password),
                    'mieru password'
                );
                const hasPort = node.port !== undefined;
                const hasPortRange = node.portRange !== undefined;
                requireValue(hasPort !== hasPortRange, 'mieru port or portRange');
                if (hasPort) {
                    requireValue(
                        Number.isInteger(node.port) && node.port > 0 && node.port <= 65535,
                        'mieru port'
                    );
                } else {
                    const range = /^(\d+)-(\d+)$/.exec(String(node.portRange));
                    requireValue(Boolean(range), 'mieru portRange');
                    const begin = Number(range[1]);
                    const end = Number(range[2]);
                    requireValue(
                        begin >= 1 && end <= 65535 && begin <= end,
                        'mieru portRange'
                    );
                }
                requireValue(node.transport === undefined || node.transport === 'TCP', 'mieru transport');
                requireValue(
                    node.multiplexing === undefined ||
                        MIERU_MULTIPLEXING_LEVELS.includes(node.multiplexing),
                    'mieru multiplexing'
                );
                requireValue(
                    node.trafficPattern === undefined ||
                        (typeof node.trafficPattern === 'string' &&
                            /^[A-Za-z0-9+/]+={0,2}$/.test(node.trafficPattern)),
                    'mieru traffic pattern'
                );
                requireValue(
                    node.mtu === undefined ||
                        (Number.isInteger(node.mtu) && node.mtu >= 1280 && node.mtu <= 1500),
                    'mieru mtu'
                );
                requireValue(node.udp === undefined || typeof node.udp === 'boolean', 'mieru udp');
            } else if (node.type === 'trojan') {
                requireValue(key === 'nodes', 'trojan nodes must be direct nodes');
                requireValue(
                    nonempty(node.password) &&
                        /^[A-Za-z0-9._~-]{8,64}$/.test(node.password),
                    'trojan password'
                );
                requireValue((node.network ?? 'tcp') === 'tcp', 'trojan network');
                requireValue(node.sni === undefined || nonempty(node.sni), 'trojan sni');
                requireValue(node.fp === undefined || nonempty(node.fp), 'trojan fingerprint');
                requireValue(node.alpn === undefined || validTrojanAlpn(node.alpn), 'trojan alpn');
            } else {
                requireValue(/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(node.uuid), `${key} UUID`);
                if (key === 'nodes') {
                    requireValue(node.security === 'reality' && node.network === 'tcp' && ['sni', 'pbk', 'sid', 'fp'].every(field => nonempty(node[field])), 'Reality parameters');
                } else {
                    requireValue(node.security === 'tls' && ['xhttp', 'ws'].includes(node.network) && nonempty(node.path) && node.path.startsWith('/'), 'CDN parameters');
                }
                requireValue(
                    node.supportX25519Mlkem768 === undefined || typeof node.supportX25519Mlkem768 === 'boolean',
                    `${key} ML-KEM flag`
                );
            }
            requireValue(node.port === undefined || Number.isInteger(node.port) && node.port > 0 && node.port <= 65535, 'port');
            requireValue(node.server === undefined || nonempty(node.server), `${key} server`);
            const allowedIpVersions = ['ipv4', 'ipv6', 'dual'];
            requireValue(
                node.ipVersion === undefined || allowedIpVersions.includes(node.ipVersion),
                `${key} IP family`
            );
            requireValue(
                ![node.server, node.host].some(value => String(value || '').includes(':')),
                `${key} IPv6 literals are disabled`
            );
            node.ipVersion = 'ipv4';
        }
    }
    requireValue(
        config.nodes.length > 0 || config.requireDynamicCdn === true,
        'at least one node source'
    );
    const names = [...config.nodes, ...config.fallbackCdnNodes].map(node => node.name);
    requireValue(new Set(names).size === names.length && names.every(name =>
        !['PROXY', 'GLOBAL', 'PASS', '🇭🇰CF', '🇺🇸白天首选', 'DIRECT', 'REJECT'].includes(name)
    ), 'unique, non-reserved node names');
    requireValue(
        config.nodes.every(node => !/^(?:🇺🇸优选|🇭🇰CF)[1-6]$/.test(node.name)),
        'direct node names must not use reserved CDN names'
    );
    const [template, source] = await Promise.all([
        readFile(templatePath, 'utf8'),
        readFile(sourcePath, 'utf8'),
    ]);
    for (const marker of [
        '# EASY_ALL_PROXY_NODE', '# EASY_ALL_PROXY_GROUP',
        '# EASY_ALL_PROXY_NAME', '# EASY_ALL_WORKER_RULE',
    ]) {
        requireValue(template.split('\n').filter(line => line === marker).length === 1, `template marker ${marker}`);
    }
    const checkedTemplate = spawnSync('bash', [resolve(root, 'lib/mihomo-template.sh'), templatePath], { stdio: 'ignore' });
    if (checkedTemplate.status !== 0) {
        throw new Error('Mihomo template validation failed; custom templates require MIHOMO_CHECK_BIN and valid Geo data');
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
    await mkdir(dirname(outputPath), { recursive: true, mode: 0o700 });
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

// Compare real paths: a symlinked checkout path (macOS /tmp, symlinked repo root)
// would otherwise make this guard false and turn the CLI into a silent no-op.
const scriptPath = fileURLToPath(import.meta.url);
const invokedDirectly = (() => {
    if (!process.argv[1]) return false;
    try { return realpathSync(process.argv[1]) === realpathSync(scriptPath); }
    catch { return resolve(process.argv[1]) === scriptPath; }
})();
if (invokedDirectly) {
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
