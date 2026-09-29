// Standalone VLESS-over-WebSocket TCP fallback. No DNS, routing or subscriptions.
import { connect } from 'cloudflare:sockets';

const MAX_PENDING = 1024 * 1024;
// WebSocketPair exposes neither drain nor bufferedAmount. Bound all bytes ever
// queued on this connection; this is a lifetime limit, NOT measured backpressure.
// A timer/rate limit cannot bound memory for a peer that stops receiving.
const MAX_DOWNSTREAM = 8 * 1024 * 1024;
const HEADER_LIMIT = 1024;
const IDLE_MS = 120_000;

export function parseHeader(bytes, uuid) {
    if (bytes.length < 18) return null;
    if (bytes[0] !== 0) throw new Error('Unsupported version');
    const expected = uuid.replaceAll('-', '').toLowerCase();
    const actual = Array.from(bytes.subarray(1, 17), n => n.toString(16).padStart(2, '0')).join('');
    if (actual !== expected) throw new Error('Unauthorized');
    let offset = 18 + bytes[17];
    if (bytes.length < offset + 4) return null;
    if (bytes[offset++] !== 1) throw new Error('TCP only');
    const port = (bytes[offset++] << 8) | bytes[offset++];
    if (!port || port === 25) throw new Error('Invalid port');
    const type = bytes[offset++];
    let hostname;
    if (type === 1) {
        if (bytes.length < offset + 4) return null;
        hostname = Array.from(bytes.subarray(offset, offset + 4)).join('.');
        offset += 4;
    } else if (type === 2) {
        if (bytes.length < offset + 1) return null;
        const length = bytes[offset++];
        if (!length) throw new Error('Empty hostname');
        if (bytes.length < offset + length) return null;
        hostname = new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(offset, offset + length));
        if (hostname.endsWith('.')) hostname = hostname.slice(0, -1);
        if (hostname.length > 253 || !hostname.split('.').every(label => /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/i.test(label))) {
            throw new Error('Invalid hostname');
        }
        offset += length;
    } else if (type === 3) {
        if (bytes.length < offset + 16) return null;
        hostname = '[' + Array.from({ length: 8 }, (_, i) =>
            ((bytes[offset + i * 2] << 8) | bytes[offset + i * 2 + 1]).toString(16)).join(':') + ']';
        offset += 16;
    } else {
        throw new Error('Invalid address type');
    }
    // connect() enforces Cloudflare's private/loopback/Cloudflare-IP denylist,
    // including addresses resolved from hostnames. Never retry through a public relay.
    return { hostname, port, offset };
}

export function relay(ws, uuid, earlyData = new Uint8Array(), dial = connect) {
    let socket, writer, header = new Uint8Array(), pending = 0, stopped = false;
    let downstream = 2; // VLESS response header shares the same budget.
    let chain = Promise.resolve();
    let timer;
    const finish = (code = 1000) => {
        if (stopped) return;
        stopped = true;
        clearTimeout(timer);
        try { ws.close(code, code === 1000 ? 'Closed' : 'Connection failed'); } catch {}
        try { socket?.close().catch(() => {}); } catch {}
    };
    const touch = (timeout = IDLE_MS) => {
        clearTimeout(timer);
        timer = setTimeout(() => finish(1008), timeout);
    };
    async function readRemote() {
        const reader = socket.readable.getReader();
        try {
            while (!stopped) {
                if (ws.readyState !== undefined && ws.readyState !== 1) break;
                const { value, done } = await reader.read();
                if (stopped || done || (ws.readyState !== undefined && ws.readyState !== 1)) break;
                if (value.byteLength > MAX_DOWNSTREAM - downstream) {
                    finish(1009);
                    break;
                }
                touch();
                try {
                    ws.send(value);
                    downstream += value.byteLength;
                } catch {
                    break;
                }
                if (downstream === MAX_DOWNSTREAM) { finish(1009); break; }
                // Fairness only; yielding does not acknowledge delivery.
                await new Promise(resolve => setTimeout(resolve, 0));
            }
            finish();
        } catch { finish(1011); }
        finally { reader.releaseLock(); }
    }
    async function write(bytes) {
        if (stopped) return;
        if (!writer) {
            // Only copy enough bytes to parse the bounded header; keep payload zero-copy.
            const prefix = bytes.subarray(0, HEADER_LIMIT - header.length);
            const joined = new Uint8Array(header.length + prefix.length);
            joined.set(header);
            joined.set(prefix, header.length);
            const parsed = parseHeader(joined, uuid);
            if (!parsed) {
                if (joined.length >= HEADER_LIMIT) throw new Error('Header too large');
                header = joined;
                return;
            }
            const consumed = parsed.offset - header.length;
            socket = dial({ hostname: parsed.hostname, port: parsed.port }, { secureTransport: 'off' });
            socket.closed.catch(() => finish(1011));
            touch(10_000);
            await socket.opened;
            if (stopped) return;
            writer = socket.writable.getWriter();
            header = new Uint8Array();
            ws.send(new Uint8Array([0, 0]));
            void readRemote();
            bytes = bytes.subarray(consumed);
        }
        touch();
        if (bytes.length) await writer.write(bytes);
    }
    function enqueue(data) {
        if (stopped) return;
        if (!(data instanceof ArrayBuffer) && !(data instanceof Uint8Array)) {
            finish(1003);
            return;
        }
        const bytes = data instanceof Uint8Array ? data : new Uint8Array(data);
        pending += bytes.length;
        if (pending > MAX_PENDING) { finish(1009); return; }
        chain = chain.then(() => write(bytes)).catch(() => finish(1008))
            .finally(() => { pending -= bytes.length; });
    }
    ws.addEventListener('message', event => enqueue(event.data));
    ws.addEventListener('close', () => finish());
    ws.addEventListener('error', () => finish(1011));
    touch(10_000);
    if (earlyData.length) enqueue(earlyData);
}

export default {
    fetch(request, env) {
        const url = new URL(request.url);
        if (!/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(env.UUID || '') ||
            !/^\/[A-Za-z0-9/_-]+$/.test(env.WS_PATH || '')) {
            return new Response('Unavailable', { status: 503 });
        }
        if (url.pathname !== env.WS_PATH) return new Response('Not Found', { status: 404 });
        if (request.method !== 'GET' || request.headers.get('Upgrade')?.toLowerCase() !== 'websocket') {
            return new Response('WebSocket required', { status: 426 });
        }
        let earlyData = new Uint8Array();
        const encoded = request.headers.get('Sec-WebSocket-Protocol');
        if (encoded) {
            if (encoded.length > 4096 || !/^[A-Za-z0-9_-]+={0,2}$/.test(encoded)) {
                return new Response('Invalid early data', { status: 400 });
            }
            try { earlyData = Uint8Array.from(atob(encoded.replaceAll('-', '+').replaceAll('_', '/')), c => c.charCodeAt(0)); }
            catch { return new Response('Invalid early data', { status: 400 }); }
        }
        const [client, server] = Object.values(new WebSocketPair());
        server.binaryType = 'arraybuffer';
        server.accept();
        relay(server, env.UUID, earlyData);
        return new Response(null, {
            status: 101,
            webSocket: client,
            headers: encoded ? { 'Sec-WebSocket-Protocol': encoded } : undefined,
        });
    },
};
