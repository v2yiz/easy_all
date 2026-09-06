const PORT_BASE = 10000;
// All Reality nodes share one port and rotate it every three hours.
const PORT_ROTATION_HOURS = 3;
const TLS_PORT = 443;
const SUBSCRIPTION_PATH = '/subscribe';
const DEFAULT_SUB_DOWNLOAD_NAME = 'EASY_ALL';
const UPSTREAM_FETCH_TIMEOUT_MS = 12_000;
const UPSTREAM_GENERIC_FETCH_TIMEOUT_MS = 5_000;
const MAX_UPSTREAM_SUBSCRIPTION_SIZE = 512 * 1024;
const { allowedTokens: ALLOWED_TOKENS, nodes: LOCAL_NODES, upstreamUrl: UPSTREAM_SUBSCRIPTION_URL, vpsCdnUrl: VPS_CDN_SUBSCRIPTION_URL, fallbackCdnNodes: FALLBACK_CDN_NODES } = PRIVATE_CONFIG;
const ALLOWED_TOKEN_VALUES = new Set(Object.values(ALLOWED_TOKENS));

function getHourCount(now = Date.now()) {
    const nowUtc8 = new Date(now + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
    return Math.floor((nowUtc8.getTime() - yearStart) / 3_600_000);
}

function dynamicPort(rotationCount) {
    return PORT_BASE + rotationCount;
}

function nodePort({ now = Date.now } = {}) {
    const hourCount = getHourCount(now());
    const rotationCount = Math.floor(hourCount / PORT_ROTATION_HOURS);
    return dynamicPort(rotationCount);
}

function resolveNodePorts(nodes, dependencies) {
    const port = nodePort(dependencies);
    return nodes.map((node) =>
        node.security === 'reality' ? port : TLS_PORT
    );
}

function uriEncode(value) {
    return encodeURIComponent(String(value)).replace(
        /[!'()*]/g,
        (character) => `%${character.charCodeAt(0).toString(16)}`
    );
}

function yamlString(value) {
    return JSON.stringify(String(value));
}

function xhttpString(value, fallback) {
    if (typeof value === 'string' || typeof value === 'number') {
        const result = String(value).trim();
        if (result) {
            return result;
        }
    }
    return fallback;
}

function xhttpNumber(value, fallback) {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
    }
    if (typeof value === 'string' && value.trim()) {
        const result = Number(value);
        if (Number.isFinite(result)) {
            return result;
        }
    }
    return fallback;
}

function xhttpClientPath(node) {
    const path = String(node.path || '').trim();
    if (!path.startsWith('/')) {
        throw new Error(`Invalid XHTTP path for ${node.name}`);
    }
    return `${path.replace(/\/+$/, '')}/`;
}

function xhttpExtra(node) {
    const extra = {
        uplinkHTTPMethod: xhttpString(node?.xhttpUplinkHttpMethod, 'POST'),
    };
    if (node.mode !== 'packet-up') {
        extra.noGRPCHeader = Boolean(node?.xhttpNoGrpcHeader);
    }
    return extra;
}

function wsPath(node) {
    const path = String(node.path || '').trim();
    if (!path.startsWith('/')) {
        throw new Error(`Invalid WebSocket path for ${node.name}`);
    }
    return path;
}

function wsHost(node) {
    return String(node.wsHost || node.host);
}

function wsMaxEarlyData(node) {
    return Math.max(0, xhttpNumber(node?.maxEarlyData, 0));
}

function wsUriPath(node) {
    const path = wsPath(node);
    const maxEarlyData = wsMaxEarlyData(node);
    if (!maxEarlyData) {
        return path;
    }
    return `${path}${path.includes('?') ? '&' : '?'}ed=${maxEarlyData}`;
}

function vlessLink(node, port) {
    const connectHost = node.server || node.host;
    const connectPort = node.network === 'xhttp' ? (node.port || 443) : port;
    const params = new URLSearchParams({
        encryption: 'none',
        security: node.security,
        type: node.network,
        sni: node.sni || node.host,
        fp: node.fp || 'chrome',
    });

    if (node.security === 'reality') {
        params.set('packetEncoding', 'xudp');
        params.set('flow', 'xtls-rprx-vision');
        params.set('pbk', node.pbk);
        params.set('sid', node.sid);
    } else if (node.network === 'xhttp') {
        params.set('packetEncoding', 'xudp');
        params.set('alpn', 'h2');
        params.set('host', node.host);
        params.set('path', xhttpClientPath(node));
        params.set('mode', node.mode || 'stream-up');
        params.set('extra', JSON.stringify(xhttpExtra(node)));
    } else if (node.network === 'ws') {
        params.set('packetEncoding', 'xudp');
        params.set('alpn', node.alpn || 'http/1.1');
        params.set('host', wsHost(node));
        params.set('path', wsUriPath(node));
    } else {
        throw new Error(`Unsupported VLESS network: ${node.network}`);
    }

    return `vless://${node.uuid}@${connectHost}:${connectPort}?${params.toString()}#${uriEncode(node.name)}`;
}

function clashRealityNode(node, port) {
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(node.host)}
    port: ${port}
    uuid: ${yamlString(node.uuid)}
    network: tcp
    tls: true
    udp: true
    skip-cert-verify: false
    flow: xtls-rprx-vision
    servername: ${yamlString(node.sni)}
    reality-opts:
      public-key: ${yamlString(node.pbk)}
      short-id: ${yamlString(node.sid)}
    client-fingerprint: ${yamlString(node.fp)}
    packet-encoding: xudp
    ip-version: ${yamlString(node.ipVersion || 'dual')}
    smux:
      enabled: false`;
}

function clashXhttpNode(node, port) {
    const noGrpcHeader =
        node.mode === 'packet-up'
            ? ''
            : `      no-grpc-header: ${Boolean(node?.xhttpNoGrpcHeader)}\n`;
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(node.server || node.host)}
    port: ${node.port || port}
    uuid: ${yamlString(node.uuid)}
    network: xhttp
    tls: true
    udp: true
    skip-cert-verify: false
    servername: ${yamlString(node.sni || node.host)}
    client-fingerprint: ${yamlString(node.fp || 'chrome')}
    packet-encoding: xudp
    ip-version: ${yamlString(node.ipVersion || 'ipv4')}
    alpn:
      - h2
    xhttp-opts:
      host: ${yamlString(node.host)}
      path: ${yamlString(xhttpClientPath(node))}
      mode: ${yamlString(node.mode || 'stream-up')}
${noGrpcHeader}      uplink-http-method: ${yamlString(xhttpString(node?.xhttpUplinkHttpMethod, 'POST'))}`;
}

function parseVlessLink(link) {
    const url = new URL(link);
    const uuid = url.username;
    const server = url.hostname;
    const port = Number(url.port) || 443;
    const name = decodeURIComponent(url.hash.replace(/^#/, ''));
    const params = url.searchParams;
    if (url.protocol !== 'vless:' || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(uuid) || !server || params.get('security') !== 'tls' || params.get('type') !== 'xhttp') {
        throw new Error('Unsupported CF node');
    }
    let extra = {};
    try {
        extra = JSON.parse(params.get('extra') || '{}');
    } catch {}
    return {
        type: 'vless',
        security: params.get('security') || 'tls',
        network: params.get('type') || 'xhttp',
        uuid,
        server,
        port,
        host: params.get('host') || params.get('sni') || server,
        sni: params.get('sni') || params.get('host') || server,
        name,
        fp: params.get('fp') || 'chrome',
        path: params.get('path') || '/',
        mode: params.get('mode') || 'stream-up',
        xhttpUplinkHttpMethod: extra.uplinkHTTPMethod || 'POST',
        xhttpNoGrpcHeader: Boolean(extra.noGRPCHeader),
        ipVersion: 'ipv4',
    };
}

async function fetchDynamicCdnNodes(url, { fetchImpl = fetch, timeoutMs = 5000 } = {}) {
    if (!url) return FALLBACK_CDN_NODES;
    try {
        const text = await fetchXflashSubscription(
            { headers: new Headers({ 'User-Agent': 'easy_all_worker' }) },
            url, { fetchImpl, timeoutMs, format: 'base64' }
        );
        const decoded = decodeBase64Utf8(text) || text;
        const links = decoded
            .replace(/\r\n?/g, '\n')
            .split('\n')
            .map((l) => l.trim())
            .filter((l) => l.startsWith('vless://'));

        if (links.length === 0) {
            throw new Error('No vless links found in VPS subscription');
        }

        return links.slice(0, 5).map((link, idx) => {
            const parsed = parseVlessLink(link);
            parsed.name = `🇺🇸备用CF${idx + 1}`;
            return parsed;
        });
    } catch (error) {
        console.warn('Dynamic CF subscription unavailable; using configured fallback nodes');
        return FALLBACK_CDN_NODES;
    }
}

function clashWebSocketNode(node, port) {
    const maxEarlyData = wsMaxEarlyData(node);
    const earlyData = maxEarlyData
        ? `\n      max-early-data: ${maxEarlyData}\n      early-data-header-name: ${yamlString(node.earlyDataHeaderName || 'Sec-WebSocket-Protocol')}`
        : '';
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(node.host)}
    port: ${port}
    uuid: ${yamlString(node.uuid)}
    network: ws
    tls: true
    udp: true
    skip-cert-verify: false
    servername: ${yamlString(node.sni || node.host)}
    client-fingerprint: ${yamlString(node.fp || 'chrome')}
    packet-encoding: xudp
    ip-version: ${yamlString(node.ipVersion || 'ipv4')}
    alpn:
      - ${yamlString(node.alpn || 'http/1.1')}
    ws-opts:
      path: ${yamlString(wsPath(node))}
      headers:
        Host: ${yamlString(wsHost(node))}${earlyData}`;
}

function clashNode(node, port) {
    if (node.security === 'reality') {
        return clashRealityNode(node, port);
    }
    if (node.network === 'xhttp') {
        return clashXhttpNode(node, port);
    }
    if (node.network === 'ws') {
        return clashWebSocketNode(node, port);
    }
    throw new Error(`Unsupported VLESS network: ${node.network}`);
}

function buildBase64Subscription(nodes, ports, upstreamLinks = []) {
    const localLinks = nodes.map((node, index) =>
        vlessLink(node, ports[index])
    );
    return encodeBase64Utf8(
        [...new Set([...localLinks, ...upstreamLinks])].join('\n')
    );
}


function nextTopLevelSection(lines, start) {
    for (let index = start; index < lines.length; index += 1) {
        if (/^[^\s#]/.test(lines[index])) {
            return index;
        }
    }
    return lines.length;
}

function parseYamlName(value) {
    const trimmed = value.trim().replace(/\s+#.*$/, '');
    if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        try {
            const parsed = JSON.parse(trimmed);
            return typeof parsed === 'string' ? parsed : null;
        } catch {
            return null;
        }
    }
    if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
        return trimmed.slice(1, -1).replace(/''/g, "'");
    }
    return trimmed && !/[\u0000-\u001f\u007f]/.test(trimmed)
        ? trimmed
        : null;
}

function upstreamProxyNames(lines, start, end) {
    const names = [];
    const seen = new Set();
    for (let index = start + 1; index < end; index += 1) {
        const match =
            lines[index].match(/^\s*-\s+name:\s*(.+?)\s*$/) ||
            lines[index].match(
                /^\s*-\s*\{\s*name\s*:\s*("(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^,}]+)\s*(?:,|})/
            );
        if (!match) {
            continue;
        }
        const name = parseYamlName(match[1]);
        if (name && !seen.has(name)) {
            seen.add(name);
            names.push(name);
        }
    }
    return names;
}

function buildClashConfig(nodes, ports, upstream = '', autoNodes = []) {
    let upstreamLines = [];
    let upstreamNames = [];
    if (upstream) {
        const lines = upstream.replace(/\r\n?/g, '\n').split('\n');
        const start = lines.findIndex(line => /^proxies:\s*(?:#.*)?$/.test(line));
        if (start < 0) throw new Error('XFLASH proxies must be a YAML block list');
        const end = nextTopLevelSection(lines, start + 1);
        upstreamNames = upstreamProxyNames(lines, start, end);
        const first = lines.slice(start + 1, end).find(line => /^\s*-\s+/.test(line));
        if (!first) throw new Error('XFLASH has no proxy nodes');
        const indent = first.match(/^\s*/)[0].length;
        if (indent < 1) throw new Error('XFLASH proxies must be indented');
        const items = lines.slice(start + 1, end).filter(line => new RegExp('^ {' + indent + '}-\\s+').test(line));
        if (!upstreamNames.length || items.length !== upstreamNames.length) {
            throw new Error('Unsupported or duplicate XFLASH proxy names');
        }
        // ponytail: only name-first block/flow nodes are supported; reject other
        // YAML structures instead of growing a general YAML parser.
        if (lines.slice(start + 1, end).some(line =>
            line.trim() && !line.trim().startsWith('#') && (
                line.match(/^\s*/)[0].length < indent ||
                /(?:^|[\s:,{])[*&!][^\s]/.test(line) ||
                /(?:^|[\s,{])dialer-proxy\s*:/.test(line)
            )
        )) {
            throw new Error('Unsupported XFLASH proxy indentation');
        }
        upstreamLines = lines.slice(start + 1, end).map(line =>
            line.trim() ? '  ' + line.slice(indent) : ''
        );
    }
    const names = [...nodes.map(node => node.name), ...upstreamNames];
    if (!names.length || new Set(names).size !== names.length || names.some(name => ['PROXY', '备用优选', 'DIRECT', 'REJECT'].includes(name))) {
        throw new Error('Missing, duplicate or reserved proxy names');
    }
    const autoNames = autoNodes.slice(0, 5).map(node => node.name);
    const group = [
        '    - name: 备用优选', '      type: url-test',
        '      url: https://cp.cloudflare.com/generate_204',
        '      interval: 300', '      tolerance: 30', '      timeout: 3000',
        '      lazy: true', '      proxies: ' + JSON.stringify(autoNames.length ? autoNames : ['REJECT']),
    ].join('\n');
    const replacements = {
        '# EASY_ALL_PROXY_NODE': [...nodes.map((node, i) => clashNode(node, ports[i])), ...upstreamLines].join('\n'),
        '# EASY_ALL_PROXY_GROUP': group,
        '# EASY_ALL_PROXY_NAME': [...names.filter(name => !autoNodes.some(node => node.name === name)), '备用优选'].map(name => '        - ' + yamlString(name)).join('\n'),
    };
    return MIHOMO_TEMPLATE.split('\n').map(line => replacements[line] ?? line).join('\n');
}

function decodeBase64Utf8(value) {
    const normalized = String(value)
        .replace(/\s+/g, '')
        .replace(/-/g, '+')
        .replace(/_/g, '/');
    if (
        !normalized ||
        normalized.length % 4 === 1 ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(normalized)
    ) {
        return null;
    }
    try {
        const binary = atob(
            normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=')
        );
        return new TextDecoder().decode(
            Uint8Array.from(binary, (character) => character.charCodeAt(0))
        );
    } catch {
        return null;
    }
}

function encodeBase64Utf8(value) {
    const bytes = new TextEncoder().encode(String(value));
    let binary = '';
    const chunkSize = 8192;
    for (let index = 0; index < bytes.length; index += chunkSize) {
        binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
    }
    return btoa(binary);
}

function upstreamHeaders(requestHeaders, format) {
    const clash = format === 'clash';
    const clientUserAgent = requestHeaders.get('User-Agent');
    const result = new Headers({
        Accept: clash
            ? 'text/yaml, text/plain;q=0.9, */*;q=0.8'
            : requestHeaders.get('Accept') || '*/*',
        'Accept-Language':
            requestHeaders.get('Accept-Language') || 'zh-CN,zh-Hans;q=0.9',
        'Cache-Control': 'no-cache',
        Pragma: 'no-cache',
    });
    // Forward a client UA verbatim. When the client did not send one, leave
    // the header absent instead of inventing a client identity.
    if (clientUserAgent && clientUserAgent.trim()) {
        result.set('User-Agent', clientUserAgent);
    }
    return result;
}

async function fetchXflashSubscription(
    request,
    upstreamUrl,
    {
        fetchImpl = fetch,
        timeoutMs = UPSTREAM_FETCH_TIMEOUT_MS,
        maxSize = MAX_UPSTREAM_SUBSCRIPTION_SIZE,
        format = 'clash',
    } = {}
) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
        const response = await fetchImpl(upstreamUrl, {
            headers: upstreamHeaders(request.headers, format),
            signal: controller.signal,
        });
        if (!response.ok) {
            throw new Error(`XFLASH returned HTTP ${response.status}`);
        }

        const contentLength = Number(response.headers.get('content-length'));
        if (Number.isFinite(contentLength) && contentLength > maxSize) {
            throw new Error('XFLASH subscription is too large');
        }

        const content = await response.text();
        if (content.length > maxSize) {
            throw new Error('XFLASH subscription is too large');
        }
        return content;
    } finally {
        clearTimeout(timeout);
    }
}

async function fetchXflashClashConfig(request, upstreamUrl, options = {}) {
    const content = await fetchXflashSubscription(request, upstreamUrl, {
        ...options,
        format: 'clash',
    });
    return decodeBase64Utf8(content) || content;
}

function subscriptionLinks(content) {
    const decoded = decodeBase64Utf8(content) || String(content);
    const links = decoded
        .replace(/\r\n?/g, '\n')
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(line));
    if (!links.length) {
        throw new Error('XFLASH did not return a reusable URI subscription');
    }
    return links;
}


function subscriptionFormat(request, flag) {
    const explicit = String(flag || '').trim().toLowerCase();
    if (['clash', 'mihomo', 'meta', 'stash'].includes(explicit)) {
        return 'clash';
    }
    if (['shadowrocket', 'base64', 'uri', 'v2ray'].includes(explicit)) {
        return 'base64';
    }
    return /(?:clash|mihomo|stash)/i.test(
        request.headers.get('User-Agent') || ''
    )
        ? 'clash'
        : 'base64';
}

function downloadName(env) {
    const value = String(env.SUB_DOWNLOAD_NAME || DEFAULT_SUB_DOWNLOAD_NAME)
        .trim()
        .replace(/\.(?:ya?ml)$/i, '');
    return /^[A-Za-z0-9._-]{1,64}$/.test(value)
        ? value
        : DEFAULT_SUB_DOWNLOAD_NAME;
}

function subscriptionHeaders(format, env) {
    const contentType =
        format === 'clash'
            ? 'text/yaml; charset=UTF-8'
            : 'text/plain; charset=UTF-8';
    const result = new Headers({
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        Pragma: 'no-cache',
        'Content-Type': contentType,
        'X-Content-Type-Options': 'nosniff',
        'X-Robots-Tag': 'noindex, nofollow, noarchive',
    });
    if (format === 'clash') {
        result.set(
            'Content-Disposition',
            `attachment; filename=${downloadName(env)}`
        );
    }
    return result;
}

function workerResponse(
    request,
    body,
    status = 200,
    responseHeaders = new Headers()
) {
    responseHeaders.set('X-Easy-All-Version', WORKER_VERSION);
    return new Response(request.method === 'HEAD' ? null : body, {
        status,
        headers: responseHeaders,
    });
}

function selectLocalNodes(nodes, url) {
    const showAll = url.searchParams.get('node') === 'all';
    if (showAll) {
        return nodes;
    }
    return nodes.filter(
        (node) =>
            !node.optional &&
            !node.allOnly &&
            !/vmiss/i.test(node.name) &&
            !/vmiss/i.test(node.host)
    );
}

function createWorkerHandler({
    allowedTokenValues,
    localNodes,
    upstreamUrl,
    vpsCdnUrl = VPS_CDN_SUBSCRIPTION_URL,
    now = Date.now,
    fetchImpl = fetch,
}) {
    async function buildClashSubscription(request, nodes, ports, autoNodes) {
        const upstream = await fetchXflashClashConfig(request, upstreamUrl, {
            fetchImpl,
        });
        return buildClashConfig(nodes, ports, upstream, autoNodes);
    }

    async function buildGenericSubscription(request, nodes, ports) {
        try {
            const upstream = await fetchXflashSubscription(
                request,
                upstreamUrl,
                {
                    fetchImpl,
                    timeoutMs: UPSTREAM_GENERIC_FETCH_TIMEOUT_MS,
                    format: 'base64',
                }
            );
            const links = subscriptionLinks(upstream);
            return {
                content: buildBase64Subscription(nodes, ports, links),
                degraded: false,
            };
        } catch (error) {
            console.error('XFLASH generic subscription unavailable');
            return {
                content: buildBase64Subscription(nodes, ports),
                degraded: true,
            };
        }
    }

    async function handleSubscription(request, env, url) {
        const format = subscriptionFormat(
            request,
            url.searchParams.get('flag')
        );
        const dynamicCdnNodes = await fetchDynamicCdnNodes(vpsCdnUrl, { fetchImpl });
        const selectedLocalNodes = selectLocalNodes(localNodes, url);
        const nodes = [...selectedLocalNodes, ...dynamicCdnNodes];
        const ports = resolveNodePorts(nodes, { now });
        let content;
        let degraded = false;

        if (format === 'clash') {
            try {
                content = await buildClashSubscription(
                    request,
                    nodes,
                    ports,
                    dynamicCdnNodes
                );
            } catch (error) {
                console.error('XFLASH subscription unavailable or unsupported');
                content = buildClashConfig(nodes, ports, '', dynamicCdnNodes);
                degraded = true;
            }
        } else {
            const generic = await buildGenericSubscription(
                request,
                nodes,
                ports
            );
            content = generic.content;
            degraded = generic.degraded;
        }

        const headers = subscriptionHeaders(format, env || {});
        if (degraded) {
            headers.set('X-Easy-All-Warning', 'xflash-unavailable-local-only');
        }
        return workerResponse(
            request,
            content,
            200,
            headers
        );
    }

    return async function handleRequest(request, env, context) {
        if (request.method !== 'GET' && request.method !== 'HEAD') {
            return workerResponse(
                request,
                'Method Not Allowed',
                405,
                new Headers({ Allow: 'GET, HEAD' })
            );
        }

        const url = new URL(request.url);
        if (url.pathname !== SUBSCRIPTION_PATH) {
            return workerResponse(request, 'Not Found', 404);
        }
        if (!allowedTokenValues.has(url.searchParams.get('token'))) {
            return workerResponse(request, 'Forbidden', 403);
        }

        return handleSubscription(request, env, url);
    };
}


const handleRequest = createWorkerHandler({
    allowedTokenValues: ALLOWED_TOKEN_VALUES,
    localNodes: LOCAL_NODES,
    upstreamUrl: UPSTREAM_SUBSCRIPTION_URL,
    vpsCdnUrl: VPS_CDN_SUBSCRIPTION_URL,
});

export default {
    fetch: handleRequest,
};
