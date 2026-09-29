// Standalone VLESS TCP fallback: pure XHTTP stream-one.
import { connect } from 'cloudflare:sockets';

const HEADER_LIMIT = 1024;
const CONNECT_TIMEOUT_MS = 10_000;

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

// Native response pulls propagate backpressure to TCP. Unlike WebSocket,
// this path needs no lifetime byte limit or artificial per-chunk timer.
export async function streamOne(request, uuid, dial = connect) {
    if (!request.body) return new Response('Missing body', { status: 400 });
    const input = request.body.getReader();
    const relayAbort = new AbortController();
    let socket, stopped = false;
    let timer;
    const finish = (error) => {
        if (stopped) return;
        stopped = true;
        clearTimeout(timer);
        request.signal?.removeEventListener('abort', disconnected);
        try { relayAbort.abort(error); } catch {}
        try { input.cancel(error).catch(() => {}); } catch {}
        try { socket?.close().catch(() => {}); } catch {}
    };
    const disconnected = () => finish(new Error('Client disconnected'));
    timer = setTimeout(() => finish(new Error('Connection timeout')), CONNECT_TIMEOUT_MS);
    request.signal?.addEventListener('abort', disconnected, { once: true });
    if (request.signal?.aborted) disconnected();
    let status = 400;
    try {
        let header = new Uint8Array(), first, parsed;
        while (!parsed) {
            const { value, done } = await input.read();
            if (stopped || done) throw new Error('Incomplete header');
            const prefix = value.subarray(0, HEADER_LIMIT - header.length);
            const joined = new Uint8Array(header.length + prefix.length);
            joined.set(header);
            joined.set(prefix, header.length);
            parsed = parseHeader(joined, uuid);
            if (parsed) first = value.subarray(parsed.offset - header.length);
            else if (joined.length >= HEADER_LIMIT) throw new Error('Header too large');
            header = joined;
        }
        status = 502;
        socket = dial({ hostname: parsed.hostname, port: parsed.port }, { secureTransport: 'off', allowHalfOpen: true });
        void socket.closed.then(() => finish(), finish);
        await socket.opened;
        if (stopped) throw new Error('Relay closed');

        const initialWriter = socket.writable.getWriter();
        try {
            if (first.length) await initialWriter.write(first);
        } finally {
            initialWriter.releaseLock();
            input.releaseLock();
        }
        clearTimeout(timer);

        const upstream = request.body.pipeTo(socket.writable, { signal: relayAbort.signal });
        const downstream = typeof IdentityTransformStream !== 'undefined'
            ? new IdentityTransformStream()
            : new TransformStream();
        const downstreamPump = (async () => {
            const writer = downstream.writable.getWriter();
            try {
                await writer.write(new Uint8Array([0, 0]));
            } finally {
                writer.releaseLock();
            }
            await socket.readable.pipeTo(downstream.writable, { signal: relayAbort.signal });
        })();

        void upstream.catch(finish);
        void downstreamPump.catch(finish);
        return new Response(downstream.readable, {
            headers: { 'Content-Type': 'text/event-stream', 'Cache-Control': 'no-store', 'X-Accel-Buffering': 'no' },
        });
    } catch (error) {
        finish(error);
        try { input.releaseLock(); } catch {}
        return new Response(status === 400 ? 'Bad request' : 'Relay unavailable', { status });
    }
}

export default {
    fetch(request, env) {
        const url = new URL(request.url);
        if (!/^[\da-f]{8}(?:-[\da-f]{4}){3}-[\da-f]{12}$/i.test(env.UUID || '') ||
            !/^\/[A-Za-z0-9/_-]+$/.test(env.WS_PATH || '')) {
            return new Response('Unavailable', { status: 503 });
        }
        if (url.pathname.replace(/\/$/, '') !== env.WS_PATH.replace(/\/$/, '')) return new Response('Not Found', { status: 404 });
        if (request.method !== 'POST') return new Response('Method Not Allowed', { status: 405 });
        return streamOne(request, env.UUID);
    },
};
