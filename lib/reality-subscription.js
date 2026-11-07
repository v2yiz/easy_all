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
    // 必须与 profiles/reality.sh 的 dynamic_port_slot_for_now 一致：整秒 % 6。
    // 把毫秒算进槽位会让服务端展示端口与订阅下发端口不同（NAT 段收窄后直接不通）。
    const whole = Math.max(0, Math.trunc(now));
    return Math.floor(whole / 1000) % 6;
}

function dynamicPort(hourCount, slot) {
    return 10000 + hourCount * 6 + slot;
}

// nginx 注入的 SSH 端口快照是空格分隔的十进制列表（见 lib/subscription-auth.sh）。
function sshPortList(value) {
    if (typeof value !== 'string') return [];
    return value.split(/\s+/).filter((item) => /^[0-9]+$/.test(item)).map(Number);
}

// 必须与 profiles/reality.sh 的 dynamic_port_for_current_window 一致：从当前槽位起
// 顺序扫描 6 个槽位并跳过 SSH 端口（NAT 对它们 RETURN，连上去会落到 sshd）。
// 整槽都被 SSH 占用时回退原槽位，这是保留的既有边界。
function dynamicPortAvoidingSsh(hourCount, slot, sshPorts) {
    const poolSize = 6;
    for (let offset = 0; offset < poolSize; offset += 1) {
        const port = dynamicPort(hourCount, (slot + offset) % poolSize);
        if (!sshPorts.includes(port)) return port;
    }
    return dynamicPort(hourCount, slot);
}

function nodePort(timestamp, mode, sshPorts = []) {
    if (!Number.isFinite(timestamp) || timestamp < 0 ||
        !Number.isFinite(new Date(timestamp).getTime())) {
        throw new Error('Invalid time');
    }
    if (mode === '443') return 443;
    if (mode !== 'dynamic') throw new Error('Invalid mode');
    const port = dynamicPortAvoidingSsh(getHourCount(timestamp), dynamicPortSlot(timestamp), sshPorts);
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
        const port = nodePort(
            Date.now(), mode, sshPortList(r.variables.easy_all_ssh_ports),
        );
        let body = fs.readFileSync(path, 'utf8');
        if (format === 'base64') {
            const encoded = body.replace(/[\r\n]+$/, '');
            body = Buffer.from(encoded, 'base64').toString('utf8');
            // 聚合订阅是多条链接（本机 Reality 在前，聚合节点在后，可能含 mierus）。
            const links = body.split('\n');
            const direct = links.filter((link) => link.includes(PORT_PLACEHOLDER));
            if (!encoded || Buffer.from(body, 'utf8').toString('base64') !== encoded ||
                direct.length !== 1 || body.split(PORT_PLACEHOLDER).length !== 2 ||
                !/^vless:\/\/[^\s@]+@[^\s?]+:__EASY_ALL_REALITY_PORT__\?[^\s]+$/.test(direct[0]) ||
                !/[?&]security=reality(?:&|#|$)/.test(direct[0]) ||
                !links.every((link) => /^(?:vless|mierus):\/\/[^\s]+$/.test(link))) {
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

export default {
    base64, mihomo, getHourCount, dynamicPortSlot, dynamicPort, sshPortList, nodePort,
};
