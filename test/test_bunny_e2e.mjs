import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';
import {
    chmodSync, existsSync, mkdirSync, readFileSync, writeFileSync, mkdtempSync, rmSync,
} from 'node:fs';
import { createServer } from 'node:http';
import { tmpdir } from 'node:os';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const bunnyApi = join(root, 'lib/bunny-api.py');
const tempDir = mkdtempSync(join(tmpdir(), 'bunny-e2e-'));

function runCommand(command, args = [], env = {}) {
    return new Promise((resolve) => {
        const child = spawn(command, args, {
            env: { ...process.env, ...env },
        });
        const timeout = setTimeout(() => child.kill('SIGKILL'), 30000);
        timeout.unref();
        let stdout = '';
        let stderr = '';
        child.stdout.setEncoding('utf8').on('data', (chunk) => { stdout += chunk; });
        child.stderr.setEncoding('utf8').on('data', (chunk) => { stderr += chunk; });
        child.on('close', (status) => {
            clearTimeout(timeout);
            resolve({ status, stdout, stderr });
        });
    });
}

function run(args = [], env = {}) {
    return runCommand('python3', [bunnyApi, ...args], env);
}

async function startApi() {
    const state = {
        zones: [],
        records: [],
        writes: [],
        nextZoneId: 42,
        nextHostnameId: 52,
        nextRuleId: 1,
        nextRecordId: 2,
        certificateCalls: 0,
        failNextRecordLookup: false,
        failAfterDnsPost: false,
    };
    const rule = (
        secret,
        legacy = true,
        guid = 'rule-old',
        trigger = '*',
    ) => ({
        Guid: guid,
        ActionType: 6,
        ActionParameter1: 'X-Easy-All-Origin-Key',
        ActionParameter2: secret,
        Description: 'easy_all private origin',
        Enabled: true,
        OrderIndex: 0,
        TriggerMatchingType: 0,
        Triggers: [{ Type: 0, PatternMatches: [trigger], PatternMatchingType: 0 }],
        ExtraActions: [
            { ActionType: 3, ActionParameter1: '0' },
            { ActionType: 15 },
            ...(legacy ? [{ ActionType: 34 }] : []),
        ],
    });
    const reset = ({
        created = false,
        conflict = false,
        orphan = false,
        badDuplicate = false,
        sharedLegacy = false,
        failAfterDnsPost = false,
    } = {}) => {
        state.zones = [];
        state.records = [{
            id: 'origin-record',
            type: 'A',
            name: 'origin.example.com',
            content: '192.0.2.10',
            proxied: false,
            ttl: 1,
        }, {
            id: 'cdn-record',
            type: 'CNAME',
            name: 'cdn.example.com',
            content: created ? 'unused.b-cdn.net' : 'old-easyall.b-cdn.net',
            proxied: !created,
            ttl: 1,
        }];
        state.writes = [];
        state.certificateCalls = 0;
        state.failNextRecordLookup = false;
        state.failAfterDnsPost = failAfterDnsPost;
        if (!created) {
            state.zones = [{
                Id: 41,
                Name: 'old-easyall',
                CnameDomain: 'old-easyall.b-cdn.net',
                OriginUrl: conflict
                    ? 'https://wrong-origin.example.com'
                    : 'https://origin.example.com',
                OriginHostHeader: conflict
                    ? 'wrong-origin.example.com'
                    : 'origin.example.com',
                VerifyOriginSSL: true,
                EnableWebSockets: true,
                MaxWebSocketConnections: 500,
                MonthlyBandwidthLimit: 500000000000,
                DisableLetsEncrypt: false,
                Type: 1,
                OriginType: 0,
                Enabled: true,
                Suspended: false,
                ZoneSecurityEnabled: false,
                PreloadingScreenShowOnFirstVisit: false,
                Hostnames: [{
                    Id: 51,
                    Value: 'cdn.example.com',
                    ForceSSL: true,
                    HasCertificate: true,
                    IsSystemHostname: false,
                    IsManagedHostname: false,
                }, ...(conflict || sharedLegacy ? [{
                    Id: 50,
                    Value: 'img.example.com',
                    ForceSSL: true,
                    HasCertificate: true,
                    IsSystemHostname: false,
                    IsManagedHostname: false,
                }] : [])],
                EdgeRules: badDuplicate ? [
                    rule(
                        '0123456789abcdef0123456789abcdef',
                        false,
                        'rule-good',
                    ),
                    rule(
                        '0123456789abcdef0123456789abcdef',
                        false,
                        'rule-user',
                        '/admin',
                    ),
                ] : [
                    rule(
                        sharedLegacy
                            ? '0123456789abcdef0123456789abcdef'
                            : 'old-secret',
                        true,
                    ),
                ],
            }];
            if (orphan) {
                state.zones.push({
                    Id: 40,
                    Name: 'new-easyall',
                    CnameDomain: 'new-easyall.b-cdn.net',
                    OriginUrl: 'https://origin.example.com',
                    OriginHostHeader: 'origin.example.com',
                    VerifyOriginSSL: true,
                    EnableWebSockets: true,
                    MaxWebSocketConnections: 500,
                    MonthlyBandwidthLimit: 500000000000,
                    DisableLetsEncrypt: false,
                    Type: 1,
                    OriginType: 0,
                    Enabled: true,
                    Suspended: false,
                    ZoneSecurityEnabled: false,
                    PreloadingScreenShowOnFirstVisit: false,
                    Hostnames: [],
                    EdgeRules: [],
                });
            }
        }
    };
    reset({ orphan: true });
    const server = createServer((req, res) => {
        let body = '';
        req.setEncoding('utf8');
        req.on('data', (chunk) => { body += chunk; });
        req.on('end', () => {
            const url = new URL(req.url, 'http://127.0.0.1');
            const payload = body ? JSON.parse(body) : null;
            const send = (status, responseBody = null) => {
                if (['POST', 'PUT', 'DELETE'].includes(req.method)) {
                    state.writes.push(`${req.method} ${url.pathname}`);
                }
                res.writeHead(
                    status,
                    responseBody === null ? {} : { 'Content-Type': 'application/json' },
                );
                res.end(responseBody === null ? '' : JSON.stringify(responseBody));
            };
            if (url.pathname === '/client/v4/zones' && req.method === 'GET') {
                send(200, { result: [{ id: 'cf-zone' }] });
                return;
            }
            if (url.pathname === '/client/v4/zones/cf-zone/dns_records' && req.method === 'GET') {
                if (state.failNextRecordLookup) {
                    state.failNextRecordLookup = false;
                    send(500, { error: 'simulated lookup failure' });
                    return;
                }
                const name = url.searchParams.get('name');
                send(200, { result: state.records.filter((record) => record.name === name) });
                return;
            }
            if (url.pathname === '/client/v4/zones/cf-zone/dns_records' && req.method === 'POST') {
                const record = { id: `record-${state.nextRecordId++}`, ...payload };
                state.records.push(record);
                state.failNextRecordLookup = state.failAfterDnsPost;
                send(200, { result: record });
                return;
            }
            const recordPath = url.pathname.match(/^\/client\/v4\/zones\/cf-zone\/dns_records\/([^/]+)$/);
            if (recordPath) {
                const index = state.records.findIndex((record) => record.id === recordPath[1]);
                if (index < 0) return send(404);
                if (req.method === 'GET') return send(200, { result: state.records[index] });
                if (req.method === 'PUT') {
                    state.records[index] = { id: recordPath[1], ...payload };
                    return send(200, { result: state.records[index] });
                }
                if (req.method === 'DELETE') {
                    state.records.splice(index, 1);
                    return send(204);
                }
            }
            if (url.pathname === '/pullzone' && req.method === 'GET') {
                send(200, {
                    Items: state.zones,
                    CurrentPage: 1,
                    TotalItems: state.zones.length,
                    HasMoreItems: false,
                });
                return;
            }
            if (url.pathname === '/pullzone' && req.method === 'POST') {
                const zone = {
                    Id: state.nextZoneId++,
                    ...payload,
                    CnameDomain: `${payload.Name}.b-cdn.net`,
                    Hostnames: [],
                    EdgeRules: [],
                };
                state.zones.push(zone);
                send(200, {});
                return;
            }
            if (url.pathname === '/pullzone/loadFreeCertificate' && req.method === 'GET') {
                state.certificateCalls += 1;
                const hostname = state.zones
                    .flatMap((zone) => zone.Hostnames)
                    .find((item) => item.Value === url.searchParams.get('hostname'));
                if (hostname) hostname.HasCertificate = true;
                send(200);
                return;
            }
            const hostnamePath = url.pathname.match(/^\/pullzone\/(\d+)\/addHostname$/);
            if (hostnamePath && req.method === 'POST') {
                if (state.zones.some((zone) => zone.Hostnames.some(
                    (hostname) => hostname.Value === payload.Hostname,
                ))) {
                    send(400, {
                        ErrorKey: 'pullzone.hostname_already_registered',
                        Field: 'Hostname',
                        Message: 'The hostname is already registered.',
                    });
                    return;
                }
                const zone = state.zones.find((item) => String(item.Id) === hostnamePath[1]);
                if (!zone) return send(404);
                zone.Hostnames.push({
                    Id: state.nextHostnameId++,
                    Value: payload.Hostname,
                    ForceSSL: false,
                    HasCertificate: false,
                    IsSystemHostname: false,
                    IsManagedHostname: false,
                });
                return send(204);
            }
            const forceSslPath = url.pathname.match(/^\/pullzone\/(\d+)\/setForceSSL$/);
            if (forceSslPath && req.method === 'POST') {
                const zone = state.zones.find((item) => String(item.Id) === forceSslPath[1]);
                const hostname = zone?.Hostnames.find((item) => item.Value === payload.Hostname);
                if (!hostname) return send(404);
                hostname.ForceSSL = payload.ForceSSL;
                return send(204);
            }
            const removeHostnamePath = url.pathname.match(/^\/pullzone\/(\d+)\/removeHostname$/);
            if (removeHostnamePath && req.method === 'DELETE') {
                const zone = state.zones.find((item) => String(item.Id) === removeHostnamePath[1]);
                if (!zone) return send(404);
                zone.Hostnames = zone.Hostnames.filter((item) => item.Value !== payload.Hostname);
                return send(204);
            }
            const edgePath = url.pathname.match(/^\/pullzone\/(\d+)\/edgerules\/addOrUpdate$/);
            if (edgePath && req.method === 'POST') {
                const zone = state.zones.find((item) => String(item.Id) === edgePath[1]);
                if (!zone) return send(404);
                const index = zone.EdgeRules.findIndex((item) => item.Guid === payload.Guid);
                const stored = {
                    ...payload,
                    Guid: payload.Guid || `rule-${state.nextRuleId++}`,
                };
                if (index >= 0) zone.EdgeRules[index] = stored;
                else zone.EdgeRules.push(stored);
                return send(201);
            }
            const deleteRulePath = url.pathname.match(/^\/pullzone\/(\d+)\/edgerules\/([^/]+)$/);
            if (deleteRulePath && req.method === 'DELETE') {
                const zone = state.zones.find((item) => String(item.Id) === deleteRulePath[1]);
                if (!zone) return send(404);
                zone.EdgeRules = zone.EdgeRules.filter((item) => item.Guid !== deleteRulePath[2]);
                return send(204);
            }
            const detail = url.pathname.match(/^\/pullzone\/(\d+)$/);
            if (detail) {
                const index = state.zones.findIndex((item) => String(item.Id) === detail[1]);
                if (index < 0) return send(404);
                if (req.method === 'GET') return send(200, state.zones[index]);
                if (req.method === 'DELETE') {
                    state.zones.splice(index, 1);
                    return send(204);
                }
            }
            send(404);
        });
    });
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
    return {
        env: {
            EASY_ALL_BUNNY_API: `http://127.0.0.1:${server.address().port}`,
            EASY_ALL_CLOUDFLARE_API: `http://127.0.0.1:${server.address().port}/client/v4`,
        },
        close: () => new Promise((resolve) => server.close(resolve)),
        state,
        reset,
    };
}

try {
    // 已保存安装状态后，订阅输出必须能独立运行，并使用 CDN 域名。
    const stateFile = join(tempDir, 'state.env');
    writeFileSync(stateFile, [
        'PROTOCOL="bunny-ws"',
        'CDN_DOMAIN="cdn.example.com"',
        'ORIGIN_DOMAIN="origin.example.com"',
        'OWNER_TOKEN="test-owner-token"',
        '',
    ].join('\n'));
    const subscriptionRes = spawnSync('bash', ['-c',
        'source "$1"; show_subscription', 'bunny-subscription-test',
        join(root, 'profiles/ws-bunny.sh'),
    ], {
        encoding: 'utf8',
        timeout: 10000,
        env: { ...process.env, STATE_DIR: tempDir, STATE_FILE: stateFile },
    });
    assert.equal(subscriptionRes.status, 0, subscriptionRes.stderr);
    assert.equal(subscriptionRes.stdout,
        '通用订阅 (Base64) (owner): https://cdn.example.com/subscribe?token=test-owner-token\n' +
        'Mihomo / Clash   (owner): https://cdn.example.com/subscribe?token=test-owner-token&flag=clash\n');

    // 1. 帮助命令与入口（核心路径）
    const helpRes = await run(['--help']);
    assert.equal(helpRes.status, 0);
    assert.ok(helpRes.stdout.includes('apply'));
    assert.ok(helpRes.stdout.includes('ips'));

    // 2. IP 列表解析（核心路径）
    const ipsJson = join(tempDir, 'ips.json');
    writeFileSync(ipsJson, JSON.stringify(['192.0.2.1', '198.51.100.0/24']));
    const ipsRes = await run(['ips', '--input', ipsJson]);
    assert.equal(ipsRes.status, 0);
    assert.ok(ipsRes.stdout.includes('192.0.2.1/32'));
    assert.ok(ipsRes.stdout.includes('198.51.100.0/24'));

    // 3. 配置文件校验（核心路径）
    const validConfig = join(tempDir, 'valid-config.json');
    writeFileSync(validConfig, JSON.stringify({
        zone: 'example.com',
        origin: 'origin.example.com',
        cdn: 'cdn.example.com',
        ipv4: '192.0.2.10',
        name: 'test-pull-zone',
        secret: '0123456789abcdef0123456789abcdef',
    }));
    const validRes = await run(['validate-config', '--config', validConfig]);
    assert.equal(validRes.status, 0, 'Valid config should pass validation');

    // 4. 关键失败场景：缺失必须字段
    const missingFieldConfig = join(tempDir, 'missing-field.json');
    writeFileSync(missingFieldConfig, JSON.stringify({
        zone: 'example.com',
        origin: 'origin.example.com',
    }));
    const missingRes = await run(['validate-config', '--config', missingFieldConfig]);
    assert.equal(missingRes.status, 1, 'Missing fields should fail validation');
    assert.ok(missingRes.stderr.includes('<root> (required)'));

    // 5. 关键失败场景：非法 IPv4
    const badIpConfig = join(tempDir, 'bad-ip.json');
    writeFileSync(badIpConfig, JSON.stringify({
        zone: 'example.com',
        origin: 'origin.example.com',
        cdn: 'cdn.example.com',
        ipv4: '999.999.999.999',
        name: 'test-pull-zone',
        secret: '0123456789abcdef0123456789abcdef',
    }));
    const badIpRes = await run(['validate-config', '--config', badIpConfig]);
    assert.equal(badIpRes.status, 1, 'Invalid IP should fail validation');
    assert.ok(badIpRes.stderr.includes('Invalid ipv4'));

    // 6. 异名 Pull Zone 已拥有 CDN Hostname 时必须复用，不能再 AddHostname。
    const api = await startApi();
    try {
        const configFile = join(tempDir, 'apply-config.json');
        const keyFile = join(tempDir, 'bunny.key');
        const cfTokenFile = join(tempDir, 'cloudflare.token');
        const journal = join(tempDir, 'ownership.json');
        const applyArgs = () => [
            'apply', '--journal', journal, '--config', configFile,
            '--key-file', keyFile, '--cloudflare-token-file', cfTokenFile,
        ];
        const purgeArgs = () => [
            'purge', '--journal', journal,
            '--key-file', keyFile, '--cloudflare-token-file', cfTokenFile,
        ];
        writeFileSync(configFile, JSON.stringify({
            zone: 'example.com',
            origin: 'origin.example.com',
            cdn: 'cdn.example.com',
            ipv4: '192.0.2.10',
            name: 'new-easyall',
            secret: '0123456789abcdef0123456789abcdef',
            bandwidth_gb: 500,
        }));
        writeFileSync(keyFile, 'isolated-bunny-key\n');
        writeFileSync(cfTokenFile, 'isolated-cloudflare-token\n');
        const applyRes = await run(applyArgs(), api.env);
        assert.equal(applyRes.status, 0, applyRes.stderr);
        assert.equal(api.state.zones.length, 2, 'orphan same-name Zone must remain untouched');
        const reusedZone = api.state.zones.find((zone) => zone.Name === 'old-easyall');
        assert.equal(reusedZone.Hostnames.length, 1, 'apply must reuse the existing Hostname');
        assert.equal(
            api.state.records.find((record) => record.type === 'CNAME').content,
            'old-easyall.b-cdn.net',
            'CNAME must use the selected Pull Zone CnameDomain',
        );
        assert.equal(api.state.records.find((record) => record.type === 'CNAME').proxied, false);
        assert.equal(reusedZone.EdgeRules.length, 1, 'legacy rule must be updated in place');
        assert.equal(reusedZone.EdgeRules[0].Guid, 'rule-old');
        assert.equal(
            reusedZone.EdgeRules[0].ActionParameter2,
            '0123456789abcdef0123456789abcdef',
        );
        assert.ok(
            reusedZone.EdgeRules[0].ExtraActions.every(
                (action) => action.ActionType <= 32,
            ),
        );
        assert.deepEqual(
            api.state.zones.find((zone) => zone.Name === 'new-easyall').Hostnames,
            [],
        );

        api.state.writes = [];
        const repeatRes = await run(applyArgs(), api.env);
        assert.equal(repeatRes.status, 0, repeatRes.stderr);
        assert.deepEqual(api.state.writes, [], 'second apply must be read-only');

        api.state.writes = [];
        const reusePurgeRes = await run(purgeArgs(), api.env);
        assert.equal(reusePurgeRes.status, 0, reusePurgeRes.stderr);
        assert.deepEqual(api.state.writes, [], 'purge must preserve reused cloud resources');

        // 7. 首次创建后的第二次 apply 必须无写，purge 只删除已拥有且未修改的资源。
        api.reset({ created: true });
        api.state.records = [];
        rmSync(journal, { force: true });
        const createRes = await run(applyArgs(), api.env);
        assert.equal(createRes.status, 0, createRes.stderr);
        assert.equal(api.state.zones.length, 1);
        assert.equal(api.state.zones[0].Hostnames.length, 1);
        assert.equal(api.state.zones[0].Hostnames[0].HasCertificate, true);
        assert.equal(api.state.zones[0].Hostnames[0].ForceSSL, true);
        assert.equal(api.state.zones[0].EdgeRules.length, 1);
        assert.equal(api.state.certificateCalls, 1);

        api.state.writes = [];
        const createRepeatRes = await run(applyArgs(), api.env);
        assert.equal(createRepeatRes.status, 0, createRepeatRes.stderr);
        assert.deepEqual(api.state.writes, [], 'created resources must also be idempotent');

        api.state.zones[0].EdgeRules.push({
            ...structuredClone(api.state.zones[0].EdgeRules[0]),
            Guid: 'user-rule',
            Description: 'user-owned rule',
        });
        api.state.writes = [];
        const extraRulePurgeRes = await run(purgeArgs(), api.env);
        assert.equal(extraRulePurgeRes.status, 1);
        assert.deepEqual(api.state.writes, [], 'extra Edge Rules must block whole-zone deletion');
        api.state.zones[0].EdgeRules.pop();

        const managedRuleGuid = api.state.zones[0].EdgeRules[0].Guid;
        api.state.zones[0].EdgeRules[0].Guid = 'replacement-rule';
        api.state.writes = [];
        const replacementGuidPurge = await run(purgeArgs(), api.env);
        assert.equal(replacementGuidPurge.status, 1);
        assert.deepEqual(api.state.writes, [], 'replacement Rule must not be deleted by ownership');
        api.state.zones[0].EdgeRules[0].Guid = managedRuleGuid;

        api.state.zones[0].EdgeRules[0].ActionParameter2 = 'modified-by-user';
        api.state.writes = [];
        const modifiedPurgeRes = await run(purgeArgs(), api.env);
        assert.equal(modifiedPurgeRes.status, 1);
        assert.deepEqual(api.state.writes, [], 'modified managed resources must not be deleted');
        assert.equal(api.state.zones.length, 1);
        assert.ok(existsSync(journal), 'failed purge must retain the journal');

        api.state.zones[0].EdgeRules[0].ActionParameter2 =
            '0123456789abcdef0123456789abcdef';
        const cleanPurgeRes = await run(purgeArgs(), api.env);
        assert.equal(cleanPurgeRes.status, 0, cleanPurgeRes.stderr);
        assert.equal(api.state.zones.length, 0);
        assert.equal(api.state.records.length, 0);
        assert.equal(existsSync(journal), false);

        // 8. 关键配置冲突必须在首个云写入前终止。
        api.reset({ conflict: true });
        const conflictRes = await run(applyArgs(), api.env);
        assert.equal(conflictRes.status, 1);
        assert.deepEqual(api.state.writes, []);
        assert.match(conflictRes.stderr, /关键配置不匹配/);
        assert.equal(api.state.records.find((record) => record.type === 'CNAME').proxied, true);

        api.reset();
        api.state.zones[0].DisableLetsEncrypt = true;
        api.state.zones[0].Hostnames = [];
        writeFileSync(configFile, JSON.stringify({
            zone: 'example.com',
            origin: 'origin.example.com',
            cdn: 'cdn.example.com',
            ipv4: '192.0.2.10',
            name: 'old-easyall',
            secret: '0123456789abcdef0123456789abcdef',
            bandwidth_gb: 500,
        }));
        api.state.writes = [];
        const letsEncryptConflictRes = await run(applyArgs(), api.env);
        assert.equal(letsEncryptConflictRes.status, 1, letsEncryptConflictRes.stderr);
        assert.deepEqual(api.state.writes, []);
        assert.match(letsEncryptConflictRes.stderr, /禁止 Let's Encrypt/);

        api.reset({ badDuplicate: true });
        rmSync(journal, { force: true });
        api.state.writes = [];
        const duplicateRuleRes = await run(applyArgs(), api.env);
        assert.equal(duplicateRuleRes.status, 1);
        assert.deepEqual(api.state.writes, [], 'every duplicate Rule must pass preflight');
        assert.match(duplicateRuleRes.stderr, /Edge Rule 的结构不匹配/);

        api.reset({ sharedLegacy: true });
        api.state.writes = [];
        const sharedLegacyRes = await run(applyArgs(), api.env);
        assert.equal(sharedLegacyRes.status, 1);
        assert.deepEqual(api.state.writes, [], 'shared legacy Rule must fail before DNS writes');
        assert.match(sharedLegacyRes.stderr, /不是当前格式/);

        api.reset({ created: true, failAfterDnsPost: true });
        api.state.records = [];
        rmSync(journal, { force: true });
        const dnsLookupFailure = await run(applyArgs(), api.env);
        assert.equal(dnsLookupFailure.status, 1);
        const partialJournal = JSON.parse(readFileSync(journal, 'utf8'));
        assert.equal(partialJournal.records.length, 1);
        assert.match(partialJournal.records[0].id, /^record-/);
        assert.equal(partialJournal.records[0].created, true);

        api.reset({ created: true });
        api.state.records = [];
        rmSync(journal, { force: true });
        const schemaSeedRes = await run(applyArgs(), api.env);
        assert.equal(schemaSeedRes.status, 0, schemaSeedRes.stderr);
        const invalidJournal = JSON.parse(readFileSync(journal, 'utf8'));
        invalidJournal.pull_zone.created = 'true';
        writeFileSync(journal, JSON.stringify(invalidJournal));
        api.state.writes = [];
        const invalidCreatedRes = await run(applyArgs(), api.env);
        assert.equal(invalidCreatedRes.status, 1);
        assert.deepEqual(api.state.writes, [], 'invalid ownership schema must fail before writes');
        assert.match(invalidCreatedRes.stderr, /pull_zone\.created \(type\)/);
        assert.equal(invalidCreatedRes.stderr.includes(configFile), false);
        assert.equal(
            invalidCreatedRes.stderr.includes('0123456789abcdef0123456789abcdef'),
            false,
        );

        // 9. 旧版 journal 不足以证明归属，purge 必须拒绝删除。
        writeFileSync(journal, JSON.stringify({
            version: 2,
            pull_id: 41,
            zone_id: 'cf-zone',
            records: [{ id: 'origin-record' }, { id: 'cdn-record' }],
        }));
        api.state.writes = [];
        const legacyPurgeRes = await run(purgeArgs(), api.env);
        assert.equal(legacyPurgeRes.status, 1);
        assert.deepEqual(api.state.writes, []);
        assert.ok(existsSync(journal));

        if (
            process.getuid?.() === 0
            && process.env.EASY_ALL_DEDICATED_TEST_VM === '1'
        ) {
            const cliRoot = join(tempDir, 'cli');
            const cliStateDir = join(cliRoot, 'state');
            const cliRecoveryDir = join(cliRoot, 'recovery');
            const cliWebRoot = join(cliRoot, 'web');
            mkdirSync(cliStateDir, { recursive: true });
            mkdirSync(cliRecoveryDir, { recursive: true });
            mkdirSync(cliWebRoot, { recursive: true });
            const cliState = join(cliStateDir, 'state.env');
            const cliJournal = join(cliRecoveryDir, 'ownership.json');
            const cliKey = join(cliRecoveryDir, 'bunny-api.key');
            const cliToken = join(cliRecoveryDir, 'cloudflare-dns.token');
            const cliStateContent = [
                'STATE_VERSION="2"',
                'PROTOCOL="bunny-ws"',
                'CLOUDFLARE_ZONE="example.com"',
                'ORIGIN_DOMAIN="origin.example.com"',
                'CDN_DOMAIN="cdn.example.com"',
                'VPS_PUBLIC_IPV4="192.0.2.10"',
                'BUNNY_PULL_NAME="new-easyall"',
                'BUNNY_BANDWIDTH_GB="500"',
                'ORIGIN_HEADER_SECRET="root-secret-0123456789"',
                'OWNER_TOKEN="root-owner-token"',
                '',
            ].join('\n');
            writeFileSync(cliState, cliStateContent);
            writeFileSync(cliKey, 'isolated-bunny-key\n');
            writeFileSync(cliToken, 'isolated-cloudflare-token\n');
            const stub = join(cliRoot, 'systemctl');
            writeFileSync(stub, '#!/bin/sh\nexit 0\n');
            chmodSync(stub, 0o755);
            const cliEnv = {
                ...api.env,
                EASY_ALL_STATE_FILE_OVERRIDE: cliState,
                STATE_DIR: cliStateDir,
                STATE_FILE: cliState,
                BUNNY_RECOVERY_DIR: cliRecoveryDir,
                BUNNY_JOURNAL: cliJournal,
                BUNNY_KEY_FILE: cliKey,
                BUNNY_CLOUDFLARE_TOKEN_FILE: cliToken,
                BUNNY_CONFIG: join(cliRecoveryDir, 'config.json'),
                WEB_ROOT: cliWebRoot,
                XRAY_SERVICE_FILE: join(cliRoot, 'easy_all-xray.service'),
                BUNNY_REFRESH_SERVICE_FILE: join(cliRoot, 'bunny-refresh.service'),
                BUNNY_REFRESH_TIMER_FILE: join(cliRoot, 'bunny-refresh.timer'),
                CERT_RENEW_SERVICE_FILE: join(cliRoot, 'cert-renew.service'),
                CERT_RENEW_TIMER_FILE: join(cliRoot, 'cert-renew.timer'),
                NGINX_CONFIG: join(cliRoot, 'nginx.conf'),
                UFW_BEFORE_RULES: join(cliRoot, 'missing-before.rules'),
            };
            api.reset({ orphan: true });
            const cliApply = await runCommand(
                join(root, 'easy_all'), ['apply'], cliEnv,
            );
            assert.equal(cliApply.status, 0, cliApply.stderr);
            assert.ok(existsSync(cliJournal));
            assert.equal(api.state.zones.length, 2);
            assert.deepEqual(
                api.state.zones.find((zone) => zone.Name === 'new-easyall').Hostnames,
                [],
            );
            api.state.writes = [];
            const cliRepeat = await runCommand(
                join(root, 'easy_all'), ['apply'], cliEnv,
            );
            assert.equal(cliRepeat.status, 0, cliRepeat.stderr);
            assert.deepEqual(api.state.writes, [], 'root apply must reuse owner without writes');

            api.reset({ created: true });
            api.state.records = [];
            rmSync(cliJournal, { force: true });
            const ownedApply = await runCommand(
                join(root, 'easy_all'), ['apply'], cliEnv,
            );
            assert.equal(ownedApply.status, 0, ownedApply.stderr);
            assert.equal(api.state.zones.length, 1);
            const ownedJournal = JSON.parse(readFileSync(cliJournal, 'utf8'));

            const sentinel = join(cliStateDir, 'keep-on-failed-purge');
            writeFileSync(sentinel, 'keep\n');
            rmSync(cliState);
            rmSync(cliKey);
            api.state.writes = [];
            const missingKeyPurge = await runCommand(
                join(root, 'easy_all'), ['uninstall', '--purge-cloud'], cliEnv,
            );
            assert.equal(missingKeyPurge.status, 1);
            assert.deepEqual(api.state.writes, []);
            assert.ok(existsSync(sentinel));
            assert.ok(existsSync(cliJournal));
            assert.equal(api.state.zones.length, 1);
            assert.equal(api.state.records.length, 2);

            writeFileSync(cliKey, 'isolated-bunny-key\n');
            const oldJournal = { ...ownedJournal, version: 2 };
            writeFileSync(cliJournal, JSON.stringify(oldJournal));
            api.state.writes = [];
            const oldJournalPurge = await runCommand(
                join(root, 'easy_all'), ['uninstall', '--purge-cloud'], cliEnv,
            );
            assert.equal(oldJournalPurge.status, 1);
            assert.deepEqual(api.state.writes, []);
            assert.ok(existsSync(sentinel));
            assert.ok(existsSync(cliJournal));
            assert.equal(api.state.zones.length, 1);
            assert.equal(api.state.records.length, 2);

            writeFileSync(cliJournal, JSON.stringify(ownedJournal));
            writeFileSync(cliState, cliStateContent);
            writeFileSync(join(cliWebRoot, 'uninstall-sentinel'), 'remove\n');
            api.state.writes = [];
            const mountScript = [
                'mount --make-rprivate / || exit 1',
                'mount --bind "$1" /usr/bin/systemctl || exit 1',
                'shift',
                'exec "$@"',
            ].join('\n');
            const cleanUninstall = await runCommand('unshare', [
                '--mount', '--fork', '--',
                'sh', '-c', mountScript, 'easy-all-root-e2e',
                stub, join(root, 'easy_all'), 'uninstall', '--purge-cloud',
            ], cliEnv);
            assert.equal(cleanUninstall.status, 0, cleanUninstall.stderr);
            assert.equal(existsSync(cliState), false);
            assert.equal(existsSync(cliWebRoot), false);
            assert.equal(existsSync(cliJournal), false);
            assert.equal(api.state.zones.length, 0);
            assert.equal(api.state.records.length, 0);
        }
    } finally {
        await api.close();
    }
} finally {
    rmSync(tempDir, { recursive: true, force: true });
}

console.log('ok - Bunny API end-to-end tests passed');
