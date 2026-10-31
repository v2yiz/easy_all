import fs from 'fs';

const PORT_PLACEHOLDER = '__EASY_ALL_REALITY_PORT__';
const TEMPLATE_END_TOKEN = 'EASY_ALL_REALITY_TEMPLATE_END_V1';
const TEMPLATE_END = '# ' + TEMPLATE_END_TOKEN + '\n';

function getHourCount(now) {
    const shifted = new Date(now + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(shifted.getUTCFullYear(), 0, 1);
    return Math.floor((shifted.getTime() - yearStart) / 3600000);
}

function dynamicPortSlot(now) {
    const whole = Math.max(0, Math.trunc(now));
    return (Math.floor(whole / 1000) + (whole % 1000)) % 6;
}

function dynamicPort(hourCount, slot) {
    return 10000 + hourCount * 6 + slot;
}

function nodePort(timestamp, mode) {
    if (!Number.isFinite(timestamp) || timestamp < 0 ||
        !Number.isFinite(new Date(timestamp).getTime())) {
        throw new Error('Invalid time');
    }
    if (mode === '443') return 443;
    if (mode !== 'dynamic') throw new Error('Invalid mode');
    const port = dynamicPort(getHourCount(timestamp), dynamicPortSlot(timestamp));
    if (!Number.isInteger(port) || port < 10000 || port > 62703) {
        throw new Error('Invalid port');
    }
    return port;
}

function uniqueToken(body, token) {
    return body.split(token).length === 2;
}

function render(r, format) {
    if (r.method !== 'GET' && r.method !== 'HEAD') {
        r.return(405);
        return;
    }
    try {
        const mode = r.variables.easy_all_reality_port_mode;
        const path = r.variables.request_filename;
        if ((mode !== 'dynamic' && mode !== '443') || !path) {
            throw new Error('Invalid request variables');
        }
        const port = nodePort(Date.now(), mode);
        let body = fs.readFileSync(path, 'utf8');
        if (format === 'base64') {
            const encoded = body.replace(/[\r\n]+$/, '');
            body = Buffer.from(encoded, 'base64').toString('utf8');
            if (!encoded || Buffer.from(body, 'utf8').toString('base64') !== encoded ||
                !/^vless:\/\/[^\s@]+@[^\s?]+:__EASY_ALL_REALITY_PORT__\?[^\s]+$/.test(body) ||
                !/[?&]security=reality(?:&|#|$)/.test(body)) {
                throw new Error('Invalid link template');
            }
        } else {
            // The trusted generator appends this line only after writing the complete YAML.
            if (!body.endsWith('\n' + TEMPLATE_END) || !uniqueToken(body, TEMPLATE_END_TOKEN)) {
                throw new Error('Incomplete YAML template');
            }
            body = body.slice(0, -TEMPLATE_END.length);
            if (!/(?:^|\n)    port: __EASY_ALL_REALITY_PORT__\n/.test(body)) {
                throw new Error('Invalid YAML port');
            }
        }
        if (!uniqueToken(body, PORT_PLACEHOLDER)) throw new Error('Invalid placeholder');
        body = body.replace(PORT_PLACEHOLDER, String(port));
        if (format === 'base64') body = Buffer.from(body, 'utf8').toString('base64') + '\n';
        // Nginx suppresses HEAD bodies after constructing the complete representation.
        r.return(200, body);
    } catch (error) {
        r.headersOut['Content-Type'] = 'text/plain';
        r.return(503, 'Subscription unavailable\n');
    }
}

function base64(r) { render(r, 'base64'); }
function mihomo(r) { render(r, 'mihomo'); }

export default { base64, mihomo, getHourCount, dynamicPortSlot, dynamicPort, nodePort };
