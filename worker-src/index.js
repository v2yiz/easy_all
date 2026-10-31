const PORT_BASE = 10000;
// All Reality nodes share six ports per hour and pick one per request by timestamp.
const PORTS_PER_HOUR = 6;
const TLS_PORT = 443;
const SUBSCRIPTION_PATH = '/subscribe';
const DEFAULT_SUB_DOWNLOAD_NAME = 'EASY_ALL';
const VPS_FETCH_TIMEOUT_MS = 12_000;
const MAX_VPS_SUBSCRIPTION_SIZE = 512 * 1024;
const DELEGATED_TOKEN_DENIAL_TTL_MS = 60_000;
const MAX_DELEGATED_TOKEN_DENIALS = 500;
const CDN_NODE_LIMIT = 6;
const CDN_NODE_NAME_PREFIX = '🇺🇸优选';
const CDN_GROUP_NAME = '🇺🇸白天首选';
const WORKER_GROUP_NAME = '🇭🇰CF';
const {
    allowedTokens: ALLOWED_TOKENS,
    nodes: LOCAL_NODES,
    vpsSubUrl: VPS_SUBSCRIPTION_URL,
    vpsCdnUseRequestToken: VPS_CDN_USE_REQUEST_TOKEN = false,
    delegateTokenValidation: DELEGATE_TOKEN_VALIDATION = false,
    requireDynamicCdn: CONFIG_REQUIRE_DYNAMIC_CDN,
    sourceSecret: VPS_CDN_SOURCE_SECRET = '',
    fallbackCdnNodes: FALLBACK_CDN_NODES,
    subscriptionDownloadName: SUBSCRIPTION_DOWNLOAD_NAME = DEFAULT_SUB_DOWNLOAD_NAME,
} = PRIVATE_CONFIG;
const REQUIRE_DYNAMIC_CDN =
    CONFIG_REQUIRE_DYNAMIC_CDN ?? Boolean(VPS_SUBSCRIPTION_URL);
const ALLOWED_TOKEN_VALUES = new Set(Object.values(ALLOWED_TOKENS));

function getHourCount(now = Date.now()) {
    const nowUtc8 = new Date(now + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
    return Math.floor((nowUtc8.getTime() - yearStart) / 3_600_000);
}

function dynamicPortSlot(now = Date.now()) {
    const whole = Math.max(0, Math.trunc(now));
    return (Math.floor(whole / 1000) + (whole % 1000)) % PORTS_PER_HOUR;
}

function dynamicPort(hourCount, slot = 0) {
    return PORT_BASE + hourCount * PORTS_PER_HOUR + slot;
}

function nodePort({ now = Date.now } = {}) {
    const timestamp = now();
    const hourCount = getHourCount(timestamp);
    return dynamicPort(hourCount, dynamicPortSlot(timestamp));
}

function resolveNodePorts(nodes, dependencies) {
    const port = nodePort(dependencies);
    return nodes.map((node) =>
        node.security === 'reality' ? (node.port || port) : (node.port || TLS_PORT)
    );
}

function uriEncode(value) {
    return encodeURIComponent(String(value)).replace(
        /[!'()*]/g,
        (character) => `%${character.charCodeAt(0).toString(16)}`
    );
}

function validSubscriptionToken(value) {
    return /^[A-Za-z0-9._~-]{8,128}$/.test(String(value || ''));
}

function yamlString(value) {
    return JSON.stringify(String(value));
}

function normalizeConnectHost(value) {
    const host = String(value || '').trim();
    return host.startsWith('[') && host.endsWith(']')
        ? host.slice(1, -1)
        : host;
}

function uriAuthorityHost(value) {
    const host = normalizeConnectHost(value);
    return host.includes(':') ? '[' + host + ']' : host;
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

const XHTTP_XMUX_FIELDS = [
    ['maxConnections', 'max-connections'],
    ['cMaxReuseTimes', 'c-max-reuse-times'],
    ['hMaxRequestTimes', 'h-max-request-times'],
    ['hMaxReusableSecs', 'h-max-reusable-secs'],
    ['hKeepAlivePeriod', 'h-keep-alive-period'],
];

function normalizeXhttpXmux(value) {
    if (!value || typeof value !== 'object' || Array.isArray(value)) {
        return null;
    }
    const result = {};
    for (const [field] of XHTTP_XMUX_FIELDS) {
        const current = value[field];
        if (typeof current === 'number' && Number.isFinite(current)) {
            result[field] = current;
        } else if (
            typeof current === 'string' &&
            current.trim() &&
            !/[\r\n\0]/.test(current)
        ) {
            result[field] = current.trim();
        }
    }
    return Object.keys(result).length ? result : null;
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
    const xmux = normalizeXhttpXmux(node?.xhttpXmux);
    if (xmux) {
        extra.xmux = xmux;
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
    const connectHost = uriAuthorityHost(node.server || node.host);
    const connectPort = node.network === 'xhttp' ? (node.port || 443) : port;
    const params = new URLSearchParams({
        encryption: 'none',
        security: node.security,
        type: node.network,
        sni: node.sni || node.host,
        fp: node.fp || 'chrome',
    });

    if (node.workerBackup) params.set('easyAllBackup', '1');
    if (node.security === 'reality') {
        params.set('packetEncoding', 'xudp');
        params.set('flow', 'xtls-rprx-vision');
        params.set('pbk', node.pbk);
        params.set('sid', node.sid);
    } else if (node.network === 'xhttp') {
        if (node.udp !== false) params.set('packetEncoding', 'xudp');
        params.set('alpn', 'h2');
        params.set('host', node.host);
        params.set('path', xhttpClientPath(node));
        params.set('mode', node.mode || 'stream-up');
        params.set('extra', JSON.stringify(xhttpExtra(node)));
    } else if (node.network === 'ws') {
        if (node.udp !== false) params.set('packetEncoding', 'xudp');
        params.set('alpn', node.alpn || 'http/1.1');
        params.set('host', wsHost(node));
        params.set('path', wsUriPath(node));
    } else {
        throw new Error(`Unsupported VLESS network: ${node.network}`);
    }

    return `vless://${node.uuid}@${connectHost}:${connectPort}?${params.toString()}#${uriEncode(node.name)}`;
}

function clashRealityNode(node, port) {
    // Xray 26.9.8+ requires this hybrid key share; mihomo strips it unless asked to keep it.
    const mlkem = node.supportX25519Mlkem768 === false
        ? ''
        : '\n      support-x25519mlkem768: true';
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
      short-id: ${yamlString(node.sid)}${mlkem}
    client-fingerprint: ${yamlString(node.fp)}
    packet-encoding: xudp
    ip-version: ipv4
    smux:
      enabled: false`;
}

function clashXhttpNode(node, port) {
    const noGrpcHeader =
        node.mode === 'packet-up'
            ? ''
            : `      no-grpc-header: ${Boolean(node?.xhttpNoGrpcHeader)}\n`;
    const xmux = normalizeXhttpXmux(node?.xhttpXmux);
    const reuseSettings = xmux
        ? `\n      reuse-settings:\n${XHTTP_XMUX_FIELDS
            .filter(([field]) => Object.hasOwn(xmux, field))
            .map(([field, yamlField]) =>
                `        ${yamlField}: ${JSON.stringify(xmux[field])}`
            )
            .join('\n')}`
        : '';
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(normalizeConnectHost(node.server || node.host))}
    port: ${node.port || port}
    uuid: ${yamlString(node.uuid)}
    network: xhttp
    tls: true
    udp: ${node.udp !== false}
    skip-cert-verify: false
    servername: ${yamlString(node.sni || node.host)}
    client-fingerprint: ${yamlString(node.fp || 'chrome')}
${node.udp === false ? '' : '    packet-encoding: xudp\n'}    ip-version: ipv4
    alpn:
      - h2
    xhttp-opts:
      host: ${yamlString(node.host)}
      path: ${yamlString(xhttpClientPath(node))}
      mode: ${yamlString(node.mode || 'stream-up')}
${noGrpcHeader}      uplink-http-method: ${yamlString(xhttpString(node?.xhttpUplinkHttpMethod, 'POST'))}${reuseSettings}`;
}

function parseVlessLink(link) {
    const url = new URL(link);
    const uuid = url.username;
    const server = normalizeConnectHost(url.hostname);
    const port = Number(url.port) || 443;
    const name = decodeURIComponent(url.hash.replace(/^#/, ''));
    const params = url.searchParams;
    const network = params.get('type');
    if (url.protocol !== 'vless:' || !/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(uuid) || !server || server.includes(':') || params.get('security') !== 'tls' || !['xhttp', 'ws'].includes(network)) {
        throw new Error('Unsupported CF node');
    }
    let extra = {};
    try {
        extra = JSON.parse(params.get('extra') || '{}');
    } catch {}
    return {
        type: 'vless',
        workerBackup: params.get('easyAllBackup') === '1',
        udp: params.get('easyAllBackup') !== '1',
        security: params.get('security') || 'tls',
        network,
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
        xhttpXmux: normalizeXhttpXmux(extra.xmux),
        ipVersion: 'ipv4',
    };
}

function normalizeCdnNodeNames(nodes) {
    const primary = nodes.filter(node => !node.workerBackup).slice(0, CDN_NODE_LIMIT)
        .map((node, index) => ({ ...node, name: CDN_NODE_NAME_PREFIX + (index + 1) }));
    const backup = nodes.filter(node => node.workerBackup).slice(0, CDN_NODE_LIMIT)
        .map((node, index) => ({ ...node, udp: false,
            name: `🇭🇰CF${index + 1}` }));
    return [...primary, ...backup];
}

async function fetchDynamicCdnNodes(url, {
    fetchImpl = fetch,
    timeoutMs = VPS_FETCH_TIMEOUT_MS,
    sourceToken = '',
    sourceSecret = '',
} = {}) {
    if (!url) {
        return { nodes: normalizeCdnNodeNames(FALLBACK_CDN_NODES), error: null };
    }
    try {
        // The parser consumes URI subscriptions, regardless of the caller's format.
        const subscriptionUrl = new URL(url);
        subscriptionUrl.searchParams.set('flag', 'base64');
        if (sourceToken) {
            subscriptionUrl.searchParams.set('token', sourceToken);
        }
        const text = await fetchVpsSubscription(
            subscriptionUrl.toString(), {
                fetchImpl,
                timeoutMs,
                extraHeaders: sourceSecret
                    ? { 'X-Easy-All-Worker-Source': sourceSecret }
                    : {},
            }
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

        const nodes = links.flatMap((link) => {
            try {
                const parsed = parseVlessLink(link);
                return [parsed];
            } catch {
                return [];
            }
        });
        if (nodes.length === 0) {
            throw new Error('Failed to parse any vless links from VPS subscription');
        }
        return { nodes: normalizeCdnNodeNames(nodes), error: null };
    } catch (error) {
        console.warn('Dynamic CF subscription unavailable; using configured fallback nodes:', error.message);
        return {
            nodes: normalizeCdnNodeNames(FALLBACK_CDN_NODES),
            error: error.message,
            sourceStatus: error.httpStatus || 0,
        };
    }
}

function clashWebSocketNode(node, port) {
    const maxEarlyData = wsMaxEarlyData(node);
    const earlyData = maxEarlyData
        ? `\n      max-early-data: ${maxEarlyData}\n      early-data-header-name: ${yamlString(node.earlyDataHeaderName || 'Sec-WebSocket-Protocol')}`
        : '';
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(normalizeConnectHost(node.server || node.host))}
    port: ${port}
    uuid: ${yamlString(node.uuid)}
    network: ws
    tls: true
    udp: ${node.udp !== false}
    skip-cert-verify: false
    servername: ${yamlString(node.sni || node.host)}
    client-fingerprint: ${yamlString(node.fp || 'chrome')}
${node.udp === false ? '' : '    packet-encoding: xudp\n'}    ip-version: ipv4
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

function buildBase64Subscription(nodes, ports) {
    return encodeBase64Utf8(nodes.map((node, index) =>
        vlessLink(node, ports[index])
    ).join('\n'));
}

function clashUrlTestGroup(name, proxyNames, url = 'https://cp.cloudflare.com/generate_204') {
    return [
        `    - name: ${name}`, '      type: url-test', '      hidden: true',
        `      url: ${url}`,
        '      interval: 300', '      tolerance: 30', '      timeout: 5000',
        '      lazy: true', '      proxies: ' + JSON.stringify(proxyNames),
    ].join('\n');
}

function buildClashConfig(nodes, ports, autoNodes = []) {
    const names = nodes.map(node => node.name);
    if (!names.length || new Set(names).size !== names.length ||
        names.some(name => [
            'PROXY', 'GLOBAL', 'PASS',
            CDN_GROUP_NAME, WORKER_GROUP_NAME, 'DIRECT', 'REJECT',
        ].includes(name))) {
        throw new Error('Missing, duplicate or reserved proxy names');
    }
    const autoNames = autoNodes.filter(node => !node.workerBackup).slice(0, CDN_NODE_LIMIT).map(node => node.name);
    const workerNames = autoNodes.filter(node => node.workerBackup).slice(0, CDN_NODE_LIMIT).map(node => node.name);
    const groups = [
        clashUrlTestGroup(CDN_GROUP_NAME, autoNames.length ? autoNames : ['REJECT']),
        workerNames.length
            ? clashUrlTestGroup(WORKER_GROUP_NAME, workerNames, 'https://www.gstatic.com/generate_204')
            : '',
    ].filter(Boolean).join('\n');
    const manualNames = names.filter(name => !autoNames.includes(name) && !workerNames.includes(name));
    const vmissNames = manualNames.filter(name => /US[_ -]?VMISS/i.test(name));
    const eveningNames = manualNames.filter(name => name.includes('晚上首选'));
    const replacements = {
        '# EASY_ALL_PROXY_NODE': nodes.map((node, i) => clashNode(node, ports[i])).join('\n'),
        '# EASY_ALL_PROXY_GROUP': groups,
        '# EASY_ALL_WORKER_RULE': '',
        '# EASY_ALL_PROXY_NAME': [
            ...vmissNames,
            CDN_GROUP_NAME,
            ...eveningNames,
            ...(workerNames.length ? [WORKER_GROUP_NAME] : []),
            ...manualNames.filter(name => !vmissNames.includes(name) && !eveningNames.includes(name)),
        ].map(name => '        - ' + yamlString(name)).join('\n'),
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

async function fetchVpsSubscription(
    url,
    {
        fetchImpl = fetch,
        timeoutMs = VPS_FETCH_TIMEOUT_MS,
        maxSize = MAX_VPS_SUBSCRIPTION_SIZE,
        extraHeaders = {},
    } = {}
) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
        const headers = new Headers({
            Accept: '*/*',
            'Accept-Language': 'zh-CN,zh-Hans;q=0.9',
            'User-Agent': 'v2rayN',
            'Cache-Control': 'no-cache',
            Pragma: 'no-cache',
        });
        for (const [name, value] of Object.entries(extraHeaders)) {
            headers.set(name, value);
        }
        const response = await fetchImpl(url, {
            headers,
            signal: controller.signal,
            cache: 'no-store',
        });
        if (!response.ok) {
            const hint = response.status === 403
                ? ' (check Cloudflare Security Events; Bot Fight Mode cannot be skipped by WAF rules)'
                : response.status === 429
                    ? ' (rate-limited by upstream)'
                    : '';
            const error = Object.assign(
                new Error(`CDN subscription returned HTTP ${response.status}${hint}`),
                { httpStatus: response.status },
            );
            throw error;
        }

        if (response.headers.get('cf-mitigated') === 'challenge') {
            throw new Error('Upstream returned a Cloudflare challenge');
        }

        const contentLength = Number(response.headers.get('content-length'));
        if (Number.isFinite(contentLength) && contentLength > maxSize) {
            throw new Error('CDN subscription is too large');
        }

        const content = await response.text();
        if (content.length > maxSize) {
            throw new Error('CDN subscription is too large');
        }
        return content;
    } finally {
        clearTimeout(timeout);
    }
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
    vpsSubUrl = VPS_SUBSCRIPTION_URL,
    vpsCdnUseRequestToken = VPS_CDN_USE_REQUEST_TOKEN,
    delegateTokenValidation = DELEGATE_TOKEN_VALIDATION,
    requireDynamicCdn = REQUIRE_DYNAMIC_CDN,
    sourceSecret = VPS_CDN_SOURCE_SECRET,
    subscriptionDownloadName = SUBSCRIPTION_DOWNLOAD_NAME,
    now = Date.now,
    fetchImpl = fetch,
}) {
    const deniedTokens = new Map();

    async function handleSubscription(request, env, url) {
        const requestToken = url.searchParams.get('token');
        if (delegateTokenValidation && deniedTokens.has(requestToken)) {
            if (deniedTokens.get(requestToken) > now()) {
                return workerResponse(request, 'Forbidden', 403, new Headers({
                    'X-Easy-All-CDN-Warning': 'source-unavailable',
                }));
            }
            deniedTokens.delete(requestToken);
        }
        const format = subscriptionFormat(
            request,
            url.searchParams.get('flag')
        );
        const {
            nodes: dynamicCdnNodes,
            error: dynamicCdnError,
            sourceStatus,
        } = await fetchDynamicCdnNodes(vpsSubUrl, {
            fetchImpl,
            sourceToken: vpsCdnUseRequestToken ? requestToken : '',
            sourceSecret,
        });
        if (requireDynamicCdn && dynamicCdnError) {
            if (delegateTokenValidation && sourceStatus === 403) {
                deniedTokens.set(requestToken, now() + DELEGATED_TOKEN_DENIAL_TTL_MS);
                if (deniedTokens.size > MAX_DELEGATED_TOKEN_DENIALS) {
                    deniedTokens.delete(deniedTokens.keys().next().value);
                }
            }
            return workerResponse(
                request,
                sourceStatus === 403 && delegateTokenValidation
                    ? 'Forbidden'
                    : 'Subscription source unavailable',
                sourceStatus === 403 && delegateTokenValidation ? 403 : 502,
                new Headers({
                    'X-Easy-All-CDN-Warning': delegateTokenValidation
                        ? 'source-unavailable'
                        : dynamicCdnError,
                })
            );
        }
        const selectedLocalNodes = selectLocalNodes(localNodes, url);
        const nodes = [...selectedLocalNodes, ...dynamicCdnNodes];
        const ports = resolveNodePorts(nodes, { now });
        const content = format === 'clash'
            ? buildClashConfig(nodes, ports, dynamicCdnNodes)
            : buildBase64Subscription(nodes, ports);

        const headers = subscriptionHeaders(format, {
            SUB_DOWNLOAD_NAME:
                env?.SUB_DOWNLOAD_NAME || subscriptionDownloadName,
        });
        if (dynamicCdnError) {
            headers.set('X-Easy-All-CDN-Warning', dynamicCdnError);
        } else if (dynamicCdnNodes?.length) {
            headers.set('X-Easy-All-CDN-Nodes', String(dynamicCdnNodes.length));
        }
        return workerResponse(
            request,
            content,
            200,
            headers
        );
    }

    return async function handleRequest(request, env, _context) {
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
        if (delegateTokenValidation && !vpsSubUrl) {
            return workerResponse(request, 'Subscription source unavailable', 503);
        }
        const requestToken = url.searchParams.get('token');
        if (
            delegateTokenValidation
                ? !validSubscriptionToken(requestToken)
                : !allowedTokenValues.has(requestToken)
        ) {
            return workerResponse(request, 'Forbidden', 403);
        }

        return handleSubscription(request, env, url);
    };
}


const handleRequest = createWorkerHandler({
    allowedTokenValues: ALLOWED_TOKEN_VALUES,
    localNodes: LOCAL_NODES,
    vpsSubUrl: VPS_SUBSCRIPTION_URL,
    vpsCdnUseRequestToken: VPS_CDN_USE_REQUEST_TOKEN,
    delegateTokenValidation: DELEGATE_TOKEN_VALIDATION,
    requireDynamicCdn: REQUIRE_DYNAMIC_CDN,
    sourceSecret: VPS_CDN_SOURCE_SECRET,
    subscriptionDownloadName: SUBSCRIPTION_DOWNLOAD_NAME,
});

export default {
    fetch: handleRequest,
};
