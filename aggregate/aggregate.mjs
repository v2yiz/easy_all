import { readFile, stat } from 'node:fs/promises';
import { createServer } from 'node:http';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import vm from 'node:vm';

const root = fileURLToPath(new URL('../', import.meta.url));
const localUrl = 'https://local-subscription.invalid/subscribe';

async function readConfig(path) {
    let text;
    try { text = await readFile(path, 'utf8'); }
    catch { throw Error('无法读取 aggregate.json，请检查文件位置及权限'); }
    try { return JSON.parse(text); }
    catch { throw Error('aggregate.json 不是有效 JSON，请检查逗号、引号及注释'); }
}

export async function aggregateHandler(configPath, { fetchImpl = fetch, subscriptionDir = '/var/www/easy_all/subscriptions', templatePath = join(root, 'templates/mihomo.yaml'), diagnose = false } = {}) {
    let source;
    try { source = await readFile(join(root, 'worker-src/index.js'), 'utf8'); }
    catch { throw Error('缺少聚合运行文件 worker-src/index.js，请重新 self-update'); }
    return async request => {
        let stage = '读取 aggregate.json';
        try {
            const config = await readConfig(configPath);
            stage = '配置字段：allowedTokens 必须包含合法用户名、至少 16 字符且不重复的令牌';
            const tokens = Object.entries(config.allowedTokens || {});
            if (!tokens.length || tokens.some(([user, token]) => !/^[A-Za-z0-9_-]+$/.test(user) || typeof token !== 'string' || token.length < 16) || new Set(tokens.map(([, token]) => token)).size !== tokens.length) throw Error('Invalid tokens');
            const url = new URL(request.url);
            if (!['GET', 'HEAD'].includes(request.method)) return new Response(null, { status: 405, headers: { Allow: 'GET, HEAD' } });
            if (url.pathname !== '/aggregate') return new Response(null, { status: 404 });
            const user = tokens.find(([, token]) => token === url.searchParams.get('token'))?.[0];
            if (!user) return new Response(null, { status: 403 });
            stage = 'upstreamUrl 必须是有效的 HTTPS 订阅地址';
            const upstream = new URL(config.upstreamUrl);
            if (upstream.protocol !== 'https:' || upstream.username || upstream.password) throw Error('Invalid upstream');
            stage = '读取或校验 templates/mihomo.yaml 模板';
            const template = await readFile(templatePath, 'utf8');
            for (const marker of ['# EASY_ALL_PROXY_NODE', '# EASY_ALL_PROXY_NAME', '# EASY_ALL_PROXY_GROUP']) {
                if (template.split('\n').filter(line => line === marker).length !== 1) throw Error('Invalid template');
            }
            // Per-user deployments have no shared base64.txt. Never substitute owner.
            const shared = join(subscriptionDir, 'base64.txt');
            stage = '检查本机订阅目录权限';
            const sharedExists = await stat(shared).then(s => s.isFile()).catch(e => { if (e.code === 'ENOENT') return false; throw e; });
            const file = sharedExists ? shared : join(subscriptionDir, user, 'base64.txt');
            stage = `读取本机订阅 ${file}（检查文件是否存在、权限及用户名映射）`;
            const local = await readFile(file, 'utf8');
            stage = '加载聚合运行逻辑或生成节点（检查 nodes 数组及 Reality 参数）';
            let upstreamStatus;
            const handler = vm.runInNewContext(source.replace(/export default \{[\s\S]*$/, 'handleRequest;'), {
                PRIVATE_CONFIG: { ...config, vpsCdnUrl: localUrl, fallbackCdnNodes: [] },
                WORKER_VERSION: 'vps-aggregate', MIHOMO_TEMPLATE: template,
                URL, URLSearchParams, Headers, Response, AbortController, TextEncoder, TextDecoder,
                atob, btoa, setTimeout, clearTimeout,
                console: { warn() {}, error() {} },
                fetch: async (target, options) => {
                    if (new URL(target).origin === new URL(localUrl).origin) return new Response(local);
                    const response = await fetchImpl(target, options);
                    upstreamStatus = response.status;
                    return response;
                },
            });
            url.pathname = '/subscribe';
            const response = await handler(new Request(url, { method: request.method, headers: request.headers }), {});
            // Missing or invalid local nodes must not silently distribute stale fallback credentials.
            if (response.headers.has('X-Easy-All-CDN-Warning')) {
                stage = `解析本机订阅 ${file}：没有可用的 TLS XHTTP/WS VLESS 节点`;
                throw Error('Invalid local subscription');
            }
            if (diagnose && response.headers.has('X-Easy-All-Warning')) {
                stage = upstreamStatus === undefined
                    ? 'XFLASH 请求失败：连接、DNS、TLS 或超时问题'
                    : `XFLASH HTTP ${upstreamStatus}，请求失败或正文格式不被支持`;
                throw Error('Invalid upstream subscription');
            }
            return response;
        } catch {
            if (diagnose) throw Error(stage);
            return new Response('Aggregate configuration or local subscription unavailable\n', { status: 503, headers: { 'Cache-Control': 'no-store' } });
        }
    };
}

export async function checkAggregate(configPath, options = {}) {
    const config = await readConfig(configPath);
    if (!config || typeof config !== 'object') throw Error('aggregate.json 顶层必须是对象');
    const tokens = Object.values(config.allowedTokens || {});
    if (!tokens.length || !Array.isArray(config.nodes)) throw Error('配置必须包含 allowedTokens 对象和 nodes 数组（无额外节点填写 []）');
    const handle = await aggregateHandler(configPath, { ...options, diagnose: true });
    for (const token of tokens) {
        for (const ua of ['clash-verge', 'v2rayN']) {
            const url = new URL('http://localhost/aggregate');
            url.searchParams.set('token', token);
            let response;
            try { response = await handle(new Request(url, { headers: { 'User-Agent': ua } })); }
            catch (error) { throw Error(`${ua === 'v2rayN' ? 'Base64' : 'Clash'} 校验失败：${error.message}`); }
            if (response.status !== 200 || response.headers.has('X-Easy-All-Warning')) throw Error('Aggregate validation failed');
            await response.arrayBuffer();
        }
    }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
    const checking = process.argv[2] === '--check';
    const configPath = resolve(process.argv[checking ? 3 : 2] || '/etc/easy_all/aggregate.json');
    try {
        if (checking) {
            await checkAggregate(configPath);
            console.log('聚合校验通过：配置、所有用户本地订阅及 XFLASH 两种格式正常');
        } else {
        await readFile(configPath, 'utf8');
        const handle = await aggregateHandler(configPath);
        const server = createServer(async (req, res) => {
            try {
                const url = new URL(req.url, 'http://127.0.0.1:8788');
                const response = await handle(new Request(url, { method: req.method, headers: req.headers }));
                res.writeHead(response.status, Object.fromEntries(response.headers));
                res.end(req.method === 'HEAD' ? undefined : Buffer.from(await response.arrayBuffer()));
            } catch { res.writeHead(500); res.end(); }
        });
        server.on('error', () => { console.error('Cannot listen on 127.0.0.1:8788'); process.exitCode = 1; });
        server.listen(8788, '127.0.0.1', () => console.log('Aggregate listening on 127.0.0.1:8788/aggregate'));
        }
    } catch (error) {
        console.error(checking ? error.message : 'Cannot start aggregate; run easy_all aggregate --check for diagnostics');
        process.exitCode = 1;
    }
}
