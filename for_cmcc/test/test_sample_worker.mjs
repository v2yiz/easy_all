import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { afterEach, beforeEach, describe, it } from 'node:test';

import worker from '../sample-worker.js';
import { assertExternalRuleProviders } from '../../test/support/assert_rule_providers.mjs';

const VALID_TOKEN = 'REPLACE_WITH_TOKEN_1';
const FIXED_NOW = Date.UTC(2026, 0, 1, 0, 0, 0);
let importCounter = 0;

function subscribeUrl(search = '') {
  const query = search.startsWith('?') ? search.slice(1) : search;
  return `https://worker.example.test/subscribe${query ? `?${query}` : ''}`;
}

async function fetchSubscribe(search = '', env = {}) {
  return worker.fetch(new Request(subscribeUrl(search)), env);
}

async function responseText(response) {
  return response.text();
}

async function importSampleWorkerWithSource(source) {
  importCounter += 1;
  const url = `data:text/javascript;charset=utf-8,${encodeURIComponent(`${source}\n//# sourceURL=sample-worker-variant-${importCounter}.mjs`)}`;
  return import(url);
}

function decodeBase64Subscription(text) {
  return Buffer.from(text, 'base64').toString('utf8');
}

function findMihomoBinary() {
  const candidates = [process.env.MIHOMO_BIN, 'mihomo', 'clash-meta'].filter(Boolean);
  return candidates.find(candidate => !spawnSync(candidate, ['-v'], { stdio: 'ignore' }).error);
}

async function assertMihomoAccepts(yaml) {
  const binary = findMihomoBinary();
  if (!binary) {
    if (process.env.REQUIRE_MIHOMO_TESTS === '1') {
      assert.fail('Mihomo binary is required; set MIHOMO_BIN=/path/to/mihomo');
    }
    return false;
  }

  const directory = await mkdtemp(join(tmpdir(), 'easy-cmcc-mihomo-'));
  try {
    const config = join(directory, 'config.yaml');
    const dataDirectory = process.env.MIHOMO_DATA_DIR || directory;
    await writeFile(config, yaml);
    const result = spawnSync(binary, ['-t', '-d', dataDirectory, '-f', config], {
      encoding: 'utf8',
      timeout: 120_000
    });
    assert.equal(result.status, 0, `${result.stdout || ''}${result.stderr || ''}`);
  } finally {
    await rm(directory, { recursive: true, force: true });
  }
  return true;
}

describe('sample-worker Cloudflare Worker', () => {
  let originalDateNow;
  let originalRandom;

  beforeEach(() => {
    originalDateNow = Date.now;
    originalRandom = Math.random;
    Date.now = () => FIXED_NOW;
    Math.random = () => 0;
  });

  afterEach(() => {
    Date.now = originalDateNow;
    Math.random = originalRandom;
  });

  it('keeps rule boundaries, priorities and rule types valid', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    for (const marker of [
      '// EASY_CMCC_CONFIG_START',
      '// EASY_CMCC_CONFIG_END',
      '// EASY_CMCC_RULES_START',
      '// EASY_CMCC_RULES_END'
    ]) {
      assert.equal(source.split(marker).length - 1, 1, `${marker} must occur exactly once`);
    }

    const rulesBlock = source.match(/const EMBEDDED_CLASH_RULES = `rules:\n([\s\S]*?)\n`;/)?.[1];
    assert.ok(rulesBlock, 'embedded Clash rules must be present');
    const rules = rulesBlock
      .split('\n')
      .map(line => line.trim().replace(/^-\s*/, ''))
      .filter(line => /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|GEOSITE|RULE-SET|AND|MATCH),/.test(line));
    const keys = rules.map(rule =>
      rule.startsWith('AND,')
        ? rule.toLowerCase()
        : rule.split(',').slice(0, 2).join(',').toLowerCase()
    );
    assert.equal(new Set(keys).size, keys.length, 'rules must not contain duplicate match keys');
    assert.equal(rules.at(-1), 'MATCH,PROXY');
    assert.match(
      rulesBlock,
      /AND,\(\(NETWORK,UDP\),\(DST-PORT,443\)\),REJECT/,
      'public QUIC must fail fast to TCP'
    );
    assert.equal(
      rules.filter(rule => rule === 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT').length,
      1,
      'the global UDP/443 rejection rule must occur exactly once'
    );
    assert.ok(
      rules.indexOf('IP-CIDR6,fe80::/10,DIRECT,no-resolve') <
        rules.indexOf('AND,((NETWORK,UDP),(DST-PORT,443)),REJECT') &&
        rules.indexOf('AND,((NETWORK,UDP),(DST-PORT,443)),REJECT') <
        rules.indexOf('DOMAIN-SUFFIX,apple-relay.apple.com,PROXY'),
      'UDP/443 rejection must follow LAN bypasses and precede public routing rules'
    );
    assert.ok(
      rules.indexOf('DOMAIN-SUFFIX,apple-relay.apple.com,PROXY') <
      rules.indexOf('DOMAIN-SUFFIX,apple.com,DIRECT')
    );
    assert.ok(
      rules.indexOf('DOMAIN,copilot.microsoft.com,PROXY') <
      rules.indexOf('DOMAIN-SUFFIX,microsoft.com,DIRECT')
    );
    for (const googlePlayDomain of [
      'googleapis.cn',
      'gvt1.com',
      'gvt2.com',
      'gvt3.com',
      'ggpht.com',
      'xn--ngstr-lra8j.com'
    ]) {
      assert.ok(
        rules.includes(`DOMAIN-SUFFIX,${googlePlayDomain},PROXY`),
        `${googlePlayDomain} must use PROXY`
      );
      assert.ok(
        source.includes(`          - '+.${googlePlayDomain}'`),
        `${googlePlayDomain} must use fallback DNS`
      );
    }
    for (const githubDomain of [
      'github.com',
      'githubusercontent.com',
      'githubassets.com',
      'githubstatus.com'
    ]) {
      assert.ok(
        rules.includes(`DOMAIN-SUFFIX,${githubDomain},PROXY`),
        `${githubDomain} must use PROXY`
      );
    }
    for (const githubDownloadDomain of [
      'github.com',
      'githubusercontent.com',
      'githubassets.com'
    ]) {
      assert.ok(
        source.includes(`          - '+.${githubDownloadDomain}'`),
        `${githubDownloadDomain} must use fallback DNS`
      );
    }
    assert.ok(rules.includes('IP-CIDR6,2001:b28:f23d::/48,PROXY,no-resolve'));
    assert.equal(rules.some(rule => /^IP-CIDR,[^,]*:/.test(rule)), false);
    assert.equal(rules.some(rule => /24\.199\.123\.28|45\.76\.214\.191/.test(rule)), false);
  });

  it('rejects non-subscribe paths', async () => {
    const response = await worker.fetch(new Request('https://worker.example.test/health'), {});

    assert.equal(response.status, 404);
    assert.equal(await responseText(response), 'Not Found');
  });

  it('only accepts GET and HEAD and returns hardened response headers', async () => {
    const post = await worker.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}`), { method: 'POST' }),
      {}
    );
    const head = await worker.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&flag=clash`), { method: 'HEAD' }),
      {}
    );

    assert.equal(post.status, 405);
    assert.equal(post.headers.get('allow'), 'GET, HEAD');
    assert.equal(await post.text(), 'Method Not Allowed');
    assert.equal(head.status, 200);
    assert.equal(await head.text(), '');
    assert.equal(head.headers.get('x-content-type-options'), 'nosniff');
    assert.equal(head.headers.get('x-robots-tag'), 'noindex, nofollow, noarchive');
    assert.equal(head.headers.get('referrer-policy'), 'no-referrer');
    assert.equal(head.headers.get('access-control-allow-origin'), null);
  });

  it('does not expose internal error details in 500 responses', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace("portMode: '443'", "portMode: 'invalid'")
    );
    const originalConsoleError = console.error;
    console.error = () => {};
    try {
      const response = await module.default.fetch(
        new Request(subscribeUrl(`token=${VALID_TOKEN}`)),
        {}
      );

      assert.equal(response.status, 500);
      assert.equal(await response.text(), 'Internal Server Error');
      assert.match(response.headers.get('cache-control'), /no-store/);
    } finally {
      console.error = originalConsoleError;
    }
  });

  it('rejects missing or unknown tokens', async () => {
    const missing = await fetchSubscribe();
    const invalid = await fetchSubscribe('token=unknown');
    const formerKey = await fetchSubscribe('token=user1');

    assert.equal(missing.status, 403);
    assert.equal(await responseText(missing), '403 Forbidden');
    assert.equal(invalid.status, 403);
    assert.equal(await responseText(invalid), '403 Forbidden');
    assert.equal(formerKey.status, 403);
    assert.equal(await responseText(formerKey), '403 Forbidden');
  });

  it('returns the WebSocket and XHTTP DEFAULT_NODE entries in the default base64 subscription', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}`);
    const links = decodeBase64Subscription(await responseText(response)).split('\n');

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/plain; charset=UTF-8');
    assert.match(response.headers.get('cache-control'), /no-store/);
    assert.equal(response.headers.get('content-disposition'), 'inline');
    assert.equal(links.length, 2);
    assert.match(links[0], /^vless:\/\/00000000-0000-4000-8000-000000000002@ws\.example\.com:443\?/);
    assert.match(links[0], /type=ws/);
    assert.equal(new URL(links[0]).searchParams.get('path'), '/vless-change-me?ed=2560');
    assert.match(links[0], /#VLESS_WS$/);
    assert.match(links[1], /^vless:\/\/00000000-0000-4000-8000-000000000002@ws\.example\.com:443\?/);
    assert.match(links[1], /type=xhttp/);
    assert.match(links[1], /alpn=h2/);
    assert.match(links[1], /path=%2Fxhttp-change-me/);
    assert.match(links[1], /mode=stream-one/);
    assert.equal(new URL(links[1]).searchParams.has('extra'), false);
    assert.match(links[1], /#VLESS_XHTTP_H2$/);
    assert.doesNotMatch(links.join('\n'), /type=grpc|trojan|reality|anytls/i);
  });

  it('accepts a one-item DEFAULT_NODE array in the default base64 subscription', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace(
        'const DEFAULT_NODE = [NODE_VLESS_WS_CONFIG, NODE_VLESS_XHTTP_CONFIG];',
        'const DEFAULT_NODE = [NODE_VLESS_WS_CONFIG];'
      )
    );
    const response = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}`)),
      {}
    );
    const links = decodeBase64Subscription(await responseText(response)).split('\n');

    assert.equal(response.status, 200);
    assert.equal(links.length, 1);
    assert.match(links[0], /type=ws/);
    assert.equal(new URL(links[0]).searchParams.get('path'), '/vless-change-me?ed=2560');
  });

  it('returns all registered nodes when node=all is requested', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all`);
    const body = decodeBase64Subscription(await responseText(response));
    const links = body.split('\n');

    assert.equal(response.status, 200);
    assert.equal(links.length, 2);
    assert.match(links[0], /^vless:\/\/00000000-0000-4000-8000-000000000002@ws\.example\.com:443\?/);
    assert.match(links[0], /security=tls/);
    assert.match(links[0], /type=ws/);
    assert.match(links[0], /alpn=http%2F1.1/);
    assert.equal(new URL(links[0]).searchParams.get('path'), '/vless-change-me?ed=2560');
    assert.match(links[0], /packetEncoding=xudp/);
    assert.match(links[0], /#VLESS_WS$/);
    assert.match(links[1], /^vless:/);
    assert.match(links[1], /type=xhttp/);
    assert.match(links[1], /alpn=h2/);
    assert.match(links[1], /path=%2Fxhttp-change-me/);
    assert.match(links[1], /mode=stream-one/);
    assert.equal(new URL(links[1]).searchParams.has('extra'), false);
    assert.match(links[1], /packetEncoding=xudp/);
    assert.match(links[1], /#VLESS_XHTTP_H2$/);
    assert.doesNotMatch(body, /type=grpc|trojan|reality|anytls/i);
  });

  it('returns Clash YAML for WebSocket and XHTTP with normalized download filename', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`, {
      SUB_DOWNLOAD_NAME: 'Team_Sub.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/yaml; charset=UTF-8');
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename=Team_Sub');
    assert.match(body, /mixed-port: 1080/);
    assert.match(body, /- name: "VLESS_WS"/);
    assert.match(body, /- name: "VLESS_XHTTP_H2"/);
    assert.match(body, /server: "ws\.example\.com"/);
    assert.match(body, /port: 443/);
    assert.match(body, /type: vless/);
    assert.equal((body.match(/network: ws/g) || []).length, 1);
    assert.equal((body.match(/network: xhttp/g) || []).length, 1);
    assert.match(body, /path: "\/vless-change-me"/);
    assert.match(body, /max-early-data: 2560/);
    assert.match(body, /early-data-header-name: "Sec-WebSocket-Protocol"/);
    assert.match(body, /ip-version: "ipv4"/);
    assert.match(body, /path: "\/xhttp-change-me"/);
    assert.match(body, /mode: "stream-one"/);
    assert.match(body, /alpn:\n      - h2/);
    assert.doesNotMatch(body, /reuse-settings:|max-connections:|c-max-reuse-times:|h-max-request-times:|h-max-reusable-secs:|h-keep-alive-period:/);
    assert.doesNotMatch(body, /network: grpc|type: trojan/);
    assert.match(body, /DOMAIN-SUFFIX,bilibili\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,zhihu\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,douyin\.com,DIRECT/);
    assert.match(body, /DOMAIN,copilot\.microsoft\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,microsoft\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,apple-relay\.fastly-edge\.com,PROXY/);
    assert.match(body, /IP-CIDR6,2001:b28:f23d::\/48,PROXY,no-resolve/);
    assert.match(body, /GEOIP,CN,DIRECT,no-resolve/);
    assert.match(body, /AND,\(\(NETWORK,UDP\),\(DST-PORT,443\)\),REJECT/);
    assertExternalRuleProviders(body);
    assert.doesNotMatch(body, /DOMAIN-KEYWORD,/);
    assert.doesNotMatch(body, /PROCESS-NAME,/);
    assert.ok(
      body.indexOf('DOMAIN-SUFFIX,bilibili.com,DIRECT') <
      body.indexOf('GEOSITE,geolocation-!cn,PROXY')
    );
    assert.doesNotMatch(body, /reality|anytls/i);
  });

  it('uses power-conscious client settings and complete LAN bypasses', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`);
    const body = await responseText(response);
    const nameserverPolicy = body.match(
      /    nameserver-policy:\n([\s\S]*?)\n    enhanced-mode:/
    )?.[1];
    const fakeIpFilter = body.match(
      /    fake-ip-filter:\n([\s\S]*?)\n    nameserver:/
    )?.[1];
    const proxyServerNameserver = body.match(
      /    proxy-server-nameserver:\n([\s\S]*?)\n    nameserver-policy:/
    )?.[1];
    const domesticNameserver = body.match(
      /    nameserver:\n([\s\S]*?)\n    fallback:/
    )?.[1];

    assert.equal(response.status, 200);
    assert.ok(nameserverPolicy, 'nameserver-policy must be present');
    assert.ok(fakeIpFilter, 'fake-ip-filter must be present');
    assert.ok(proxyServerNameserver, 'proxy-server-nameserver must be present');
    assert.ok(domesticNameserver, 'nameserver must be present');
    const expectedDomesticDoH = [
      '- https://dns.alidns.com/dns-query',
      '- https://doh.pub/dns-query'
    ];
    assert.deepEqual(
      proxyServerNameserver.split('\n').map(line => line.trim()).filter(Boolean),
      expectedDomesticDoH,
      'proxy node hostnames must use independent Alibaba and Tencent DoH resolvers'
    );
    assert.deepEqual(
      domesticNameserver.split('\n').map(line => line.trim()).filter(Boolean),
      expectedDomesticDoH,
      'normal domestic lookups must use independent Alibaba and Tencent DoH resolvers'
    );
    assert.doesNotMatch(body, /https:\/\/223\.5\.5\.5\/dns-query/);
    assert.deepEqual(
      fakeIpFilter
        .split('\n')
        .map(line => line.trim().match(/^- '(.+)'$/)?.[1])
        .filter(Boolean),
      [
        '+.lan',
        '+.local',
        'localhost',
        'time.windows.com',
        'time.apple.com',
        '*.ntp.org.cn',
        'pool.ntp.org',
        '+.10jqka.com.cn',
        '+.hexin.cn',
        '+.hexin.com.cn',
        '+.myhexin.com',
        '+.ths123.com',
        '+.iwencai.com',
        '+.iwencai.cn',
        '+.51ifind.com',
        '+.51ifind.com.cn',
        '+.eastmoney.com',
        '+.eastmoney.cn',
        '+.eastmoney.com.cn',
        '+.eastmoneysec.com',
        '+.dfcfw.com',
        '+.guba.com.cn',
        '+.18.cn',
        '+.tdx.com.cn',
        '+.nesc.cn',
        '+.citics.com',
        '+.citics.com.cn',
        '+.citicsinfo.com',
        '+.cs.ecitic.com',
        '+.csc108.com',
        '+.gtht.com',
        '+.gtja.com',
        '+.gtjas.com',
        '+.htsec.com',
        '+.htsec.com.cn',
        '+.haitong.com',
        '+.haitong.com.cn',
        '+.htsc.com',
        '+.htsc.com.cn',
        '+.cmschina.com',
        '+.cmschina.com.cn',
        '+.gf.com.cn',
        '+.guosen.com.cn',
        '+.chinastock.com.cn',
        '+.xyzq.com.cn',
        '+.futooncdn.com'
      ],
      'Fake-IP exclusions must include generic local/time and specified securities domains'
    );
    assert.match(body, /DOMAIN-SUFFIX,10jqka\.com\.cn,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,eastmoney\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,tdx\.com\.cn,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,nesc\.cn,DIRECT/);
    assert.ok(
      body.indexOf('DOMAIN-SUFFIX,10jqka.com.cn,DIRECT') <
      body.indexOf('GEOSITE,geolocation-!cn,PROXY'),
      'explicit securities rules must take precedence over GeoSite fallbacks'
    );
    assert.match(nameserverPolicy, /^\s+'\+\.lan': system$/m);
    assert.match(nameserverPolicy, /^\s+'\+\.local': system$/m);
    assert.match(
      nameserverPolicy,
      /^\s+'geosite:geolocation-!cn':\n\s+- https:\/\/1\.1\.1\.1\/dns-query#PROXY\n\s+- https:\/\/dns\.google\/dns-query#PROXY$/m,
      'all confirmed foreign domains, including Google/Gemini, must use proxy DNS'
    );
    assert.match(body, /^ipv6: true$/m);
    assert.match(body, /^\s+ipv6: false$/m);
    assert.match(body, /^tcp-concurrent: false$/m);
    assert.match(body, /^find-process-mode: off$/m);
    assert.match(body, /^log-level: error$/m);
    assert.match(body, /^sniffer:\n    enable: false$/m);
    assert.match(body, /^    stack: system$/m);
    assert.doesNotMatch(body, /fake-ip-range6:/);
    assert.doesNotMatch(body, /inet6-address:/);
    assert.match(body, /^\s+mtu: 1500$/m);
    assert.match(body, /^\s+udp-timeout: 7200$/m);
    assert.match(body, /^\s+strict-route: false$/m);
    assert.match(body, /^\s+route-exclude-address:$/m);
    assert.match(body, /^\s+- 10\.0\.0\.0\/8$/m);
    for (const excludedSubnet of [
      '10.0.0.0/8',
      '172.16.0.0/12',
      '192.168.0.0/16',
      '169.254.0.0/16',
      'fc00::/7',
      'fe80::/10'
    ]) {
      assert.match(body, new RegExp(`^\\s+- ${excludedSubnet.replaceAll('.', '\\.').replace('/', '\\/')}$`, 'm'));
    }
    assert.doesNotMatch(body, /parse-pure-ip:|force-dns-mapping:|^\s+QUIC:$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.openai\.com'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.claude\.ai'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.google\.com'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.googleapis\.com'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.gstatic\.com'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.mega\.nz'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.mega\.app'$/m);
    assert.doesNotMatch(body, /DOMAIN-SUFFIX,mega\.(?:nz|co\.nz|io|app),/);
    assert.match(body, /DOMAIN,gemini\.google\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,google\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,googleapis\.com,PROXY/);
    assert.match(fakeIpFilter, /^\s+- '\+\.lan'$/m);
    assert.match(fakeIpFilter, /^\s+- '\+\.local'$/m);
    assert.match(nameserverPolicy, /^\s+'\+\.lan': system$/m);
    assert.match(nameserverPolicy, /^\s+'\+\.local': system$/m);
    assert.doesNotMatch(nameserverPolicy, /rule-set:/);
    assert.doesNotMatch(body, /direct-nameserver-follow-policy:/);
    assert.match(body, /https:\/\/1\.1\.1\.1\/dns-query#PROXY/);
    assert.match(body, /https:\/\/dns\.google\/dns-query#PROXY/);
    assert.match(body, /^\s+fallback-lazy-query: true$/m);
    assert.doesNotMatch(body, /\bdhcp:\/\/en0\b/);
    for (const privateRule of [
      'IP-CIDR,10.0.0.0/8,DIRECT,no-resolve',
      'IP-CIDR,172.16.0.0/12,DIRECT,no-resolve',
      'IP-CIDR,192.168.0.0/16,DIRECT,no-resolve',
      'IP-CIDR6,fc00::/7,DIRECT,no-resolve',
      'IP-CIDR6,fe80::/10,DIRECT,no-resolve'
    ]) {
      assert.ok(body.includes(privateRule), `${privateRule} must remain direct`);
    }
  });

  it('keeps node=all limited to both configured nodes and falls back invalid filenames', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all&flag=clash`, {
      SUB_DOWNLOAD_NAME: '../bad/name.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename=EASY_CMCC');
    assert.match(body, /- name: "VLESS_WS"/);
    assert.match(body, /- name: "VLESS_XHTTP_H2"/);
    assert.match(body, /server: "ws\.example\.com"/);
    assert.equal((body.match(/network: ws/g) || []).length, 1);
    assert.equal((body.match(/network: xhttp/g) || []).length, 1);
    assert.match(body, /udp: true/);
    assert.match(body, /path: "\/vless-change-me"/);
    assert.match(body, /path: "\/xhttp-change-me"/);
    assert.match(body, /packet-encoding: xudp/);
    assert.equal((body.match(/alpn:\n      - http\/1\.1/g) || []).length, 1);
    assert.equal((body.match(/alpn:\n      - h2/g) || []).length, 1);
    assert.equal((body.match(/ip-version: "ipv4"/g) || []).length, 1);
    assert.equal((body.match(/ip-version: "dual"/g) || []).length, 1);
    assert.doesNotMatch(body, /network: grpc|type: trojan/);
    assert.match(body, /^proxy-groups:$/m);
    assert.match(body, /- name: PROXY\n      type: select\n      proxies:\n        - AUTO\n        - "VLESS_WS"\n        - "VLESS_XHTTP_H2"/);
    const proxyGroups = body.slice(body.indexOf('proxy-groups:'), body.indexOf('\nrules:'));
    assert.equal((proxyGroups.match(/^    - name:/gm) || []).length, 2);
    assert.doesNotMatch(proxyGroups, /- name: (?:GITHUB|GOOGLE|AI_GEMINI|DOWNLOAD|AI)$/m);
    assert.match(body, /DOMAIN-SUFFIX,chatgpt\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,claude\.ai,PROXY/);
    assert.match(body, /DOMAIN,gemini\.google\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,github\.com,PROXY/);

    assert.equal((body.match(/smux:\n      enabled: false/g) || []).length, 1);
    assert.doesNotMatch(body, /reuse-settings:/);
    assert.match(proxyGroups, /- name: AUTO\n      type: url-test\n      url: 'https:\/\/www\.gstatic\.com\/generate_204'/);
    assert.doesNotMatch(body, /flow: xtls-rprx-vision/);
    assert.doesNotMatch(body, /reality|anytls/i);
  });

  it('quotes malicious node names without injecting YAML list entries', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace(
        "name: 'VLESS_WS',",
        "name: 'bad\\n  - DIRECT {host} {rules_section}',"
      )
    );
    const response = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&flag=clash`)),
      {}
    );
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.match(body, /- name: "bad\\n  - DIRECT \{host\} \{rules_section\}"/);
    assert.match(body, /      - "bad\\n  - DIRECT \{host\} \{rules_section\}"/);
    assert.doesNotMatch(body, /\n\s+- DIRECT ws\.example\.com/);
  });

  it('quotes YAML scalars and brackets IPv6 hosts in subscription URIs', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source
        .replaceAll("host: 'ws.example.com'", "host: '2001:db8::20'")
        .replaceAll("sni: 'ws.example.com'", "sni: 'safe\\nfield: value'")
    );
    const uriResponse = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}`)),
      {}
    );
    const yamlResponse = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&flag=clash`)),
      {}
    );
    const links = decodeBase64Subscription(await uriResponse.text()).split('\n');
    const yaml = await yamlResponse.text();

    assert.equal(uriResponse.status, 200);
    assert.match(links[0], /@\[2001:db8::20\]:443\?/);
    assert.match(links[0], /sni=safe%0Afield%3A\+value/);
    assert.match(yaml, /server: "2001:db8::20"/);
    assert.match(yaml, /servername: "safe\\nfield: value"/);
    assert.equal((yaml.match(/servername: "safe\\nfield: value"/g) || []).length, 2);
    assert.doesNotMatch(yaml, /^\s+sni:/m);
    assert.doesNotMatch(yaml, /^field: value$/m);
  });

  it('validates generated Clash YAML with Mihomo when its binary is available', async context => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`);
    const yaml = await response.text();

    if (!(await assertMihomoAccepts(yaml))) {
      context.skip('Mihomo binary is not installed; use REQUIRE_MIHOMO_TESTS=1 in CI');
    }
  });
});
