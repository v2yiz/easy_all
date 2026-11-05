// 订阅端口的用户可见契约：同一条 Reality 订阅下发的端口，必须落在当前小时池内，
// 并且与 profiles/reality.sh 的 bash 计算（整秒 % 6）完全一致；固定模式下发 443。
import assert from 'node:assert/strict';
import subscription from '../lib/reality-subscription.js';

const {
    getHourCount, dynamicPortSlot, dynamicPort, nodePort,
} = subscription;

const PORT_BASE = 10000;
const PORTS_PER_HOUR = 6;
const PORT_MAX = PORT_BASE + 366 * 24 * PORTS_PER_HOUR - 1;

// 与 bash 侧独立实现的参考算法：按 Asia/Shanghai 的「年内小时数」和「整秒取模」。
function expectedPort(timestamp) {
    const shifted = new Date(timestamp + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(shifted.getUTCFullYear(), 0, 1);
    const dayStart = Date.UTC(
        shifted.getUTCFullYear(), shifted.getUTCMonth(), shifted.getUTCDate(),
    );
    const dayOfYear = Math.floor((dayStart - yearStart) / 86_400_000) + 1;
    const elapsedHours = (dayOfYear - 1) * 24 + shifted.getUTCHours();
    const slot = Math.floor(timestamp / 1000) % PORTS_PER_HOUR;
    return PORT_BASE + elapsedHours * PORTS_PER_HOUR + slot;
}

const samples = [
    Date.UTC(2026, 0, 1, 0, 0, 0),
    Date.UTC(2026, 0, 1, 0, 0, 5),
    Date.UTC(2026, 2, 29, 15, 59, 59),
    Date.UTC(2026, 11, 31, 23, 59, 59),
    Date.UTC(2027, 6, 4, 7, 30, 17),
    Date.UTC(2024, 1, 29, 12, 0, 0),
];

for (const base of samples) {
    // 同一秒内的毫秒抖动不能改变端口：服务端展示与订阅下发必须是同一个值。
    for (const jitter of [0, 1, 240, 999]) {
        const now = base + jitter;
        const port = nodePort(now, 'dynamic');
        assert.equal(port, expectedPort(now), `dynamic port must follow the bash formula at ${now}`);
        assert.equal(port, dynamicPort(getHourCount(now), dynamicPortSlot(now)));
        assert.ok(port >= PORT_BASE && port <= PORT_MAX, 'port must stay inside the dynamic range');
        const hourBase = dynamicPort(getHourCount(now), 0);
        assert.ok(port >= hourBase && port < hourBase + PORTS_PER_HOUR, 'port must stay in the current hour pool');
    }
    assert.equal(nodePort(base, '443'), 443, 'fixed mode must publish the Reality port');
    assert.throws(() => nodePort(base, 'invalid'), /Invalid mode/);
}

console.log('ok - subscription port contract');
