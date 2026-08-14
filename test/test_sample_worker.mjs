import assert from 'node:assert/strict';
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { afterEach, beforeEach, describe, it } from 'node:test';

import worker from '../sample-worker.js';

const VALID_TOKEN = 'REPLACE_WITH_TOKEN_1';
const FIXED_NOW = Date.UTC(2026, 0, 1, 0, 0, 0);
const REMOVED_BYTEDANCE_DOMAINS = [
  'bytedance.net',
  'tiktok-row.net',
  'zijieapi.com',
  'bytetcc.com',
  'feelgood.cn',
  'bytegoofy.com',
  'byted.org',
  'larkoffice.com',
  'feishu.net',
  'feishu.cn',
  'feishucdn.com',
  'zjurl.cn',
  'bytedance.com',
  'byted-static.com',
  'feishu-3rd-party-services.com',
  'bytehwm.com',
  'ttwebview.com',
  'bytegecko.com',
  'bytescm.com',
  'kundou.cn',
  'bytetos.com',
  'byteeffecttos.com',
  'bytednsdoc.com',
  'bytedanceapi.com',
  'volcvideo.com',
  'feishuimg.com',
  'feishuapp.cn',
  'getfeishu.cn',
  'feishupkg.com',
  'baseopendev.com',
  'bytedapm.com',
  'ibytedapm.com',
  'larkenterprise.com',
  'aiforce.cloud',
  'aiforce.run'
];
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

  const directory = await mkdtemp(join(tmpdir(), 'easy-all-mihomo-'));
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
      '// EASY_ALL_CONFIG_START',
      '// EASY_ALL_CONFIG_END',
      '// EASY_ALL_RULES_START',
      '// EASY_ALL_RULES_END'
    ]) {
      assert.equal(source.split(marker).length - 1, 1, `${marker} must occur exactly once`);
    }

    const rulesBlock = source.match(/const EMBEDDED_CLASH_RULES = `rules:\n([\s\S]*?)\n`;/)?.[1];
    assert.ok(rulesBlock, 'embedded Clash rules must be present');
    const rules = rulesBlock
      .split('\n')
      .map(line => line.trim().replace(/^-\s*/, ''))
      .filter(line => /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|GEOSITE|RULE-SET|AND|MATCH),/.test(line));
    const keys = rules.map(rule => rule.split(',').slice(0, 2).join(',').toLowerCase());
    assert.equal(new Set(keys).size, keys.length, 'rules must not contain duplicate match keys');
    assert.equal(rules.at(-1), 'MATCH,PROXY');
    assert.match(
      rulesBlock,
      /AND,\(\(NETWORK,UDP\),\(DST-PORT,443\)\),REJECT/,
      'unmatched QUIC must fail fast to TCP on Windows'
    );
    assert.ok(
      rulesBlock.indexOf('GEOIP,CN,DIRECT,no-resolve') <
        rulesBlock.indexOf('AND,((NETWORK,UDP),(DST-PORT,443)),REJECT') &&
        rulesBlock.indexOf('AND,((NETWORK,UDP),(DST-PORT,443)),REJECT') <
        rulesBlock.indexOf('MATCH,PROXY'),
      'QUIC rejection must only be the final fallback before MATCH'
    );
    assert.ok(
      rules.indexOf('DOMAIN-SUFFIX,apple-relay.apple.com,PROXY') <
      rules.indexOf('DOMAIN-SUFFIX,apple.com,DIRECT')
    );
    assert.ok(
      rules.indexOf('DOMAIN,copilot.microsoft.com,PROXY') <
      rules.indexOf('DOMAIN-SUFFIX,microsoft.com,DIRECT')
    );
    for (const domain of REMOVED_BYTEDANCE_DOMAINS) {
      assert.equal(source.includes(domain), false, `${domain} must be completely removed`);
    }
    for (const googlePlayDomain of [
      'googleapis.cn',
      'gvt1.com',
      'gvt2.com',
      'gvt3.com',
      'ggpht.com',
      'xn--ngstr-lra8j.com'
    ]) {
      assert.ok(
        rules.includes(`DOMAIN-SUFFIX,${googlePlayDomain},AI_GEMINI`),
        `${googlePlayDomain} must use AI_GEMINI`
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
        rules.includes(`DOMAIN-SUFFIX,${githubDomain},DOWNLOAD`),
        `${githubDomain} must use DOWNLOAD`
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

  it('returns only DEFAULT_NODE in the default base64 subscription', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}`);
    const body = decodeBase64Subscription(await responseText(response));

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/plain; charset=UTF-8');
    assert.match(response.headers.get('cache-control'), /no-store/);
    assert.equal(response.headers.get('content-disposition'), 'inline');
    assert.match(body, /^vless:\/\/00000000-0000-4000-8000-000000000001@reality\.example\.com:443\?/);
    assert.match(body, /security=reality/);
    assert.match(body, /flow=xtls-rprx-vision/);
    assert.match(body, /packetEncoding=xudp/);
    assert.match(body, /#NODE_REALITY$/);
    assert.doesNotMatch(body, /NODE_ANYTLS/);
    assert.doesNotMatch(body, /trojan/i);
  });

  it('accepts an array of DEFAULT_NODE configs in the default base64 subscription', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace(
        'const DEFAULT_NODE = NODE_REALITY_CONFIG;',
        'const DEFAULT_NODE = [NODE_REALITY_CONFIG, NODE_ANYTLS_CONFIG];'
      )
    );
    const response = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}`)),
      {}
    );
    const links = decodeBase64Subscription(await responseText(response)).split('\n');

    assert.equal(response.status, 200);
    assert.equal(links.length, 2);
    assert.match(links[0], /#NODE_REALITY$/);
    assert.match(links[1], /#NODE_ANYTLS$/);
  });

  it('returns all registered nodes when node=all is requested', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all`);
    const body = decodeBase64Subscription(await responseText(response));
    const links = body.split('\n');

    assert.equal(response.status, 200);
    assert.equal(links.length, 2);
    assert.match(links[0], /^vless:\/\/00000000-0000-4000-8000-000000000001@reality\.example\.com:443\?/);
    assert.match(links[1], /^anytls:\/\/REPLACE_WITH_ANYTLS_PASSWORD@anytls\.example\.com:10055\/\?/);
    assert.match(links[0], /#NODE_REALITY$/);
    assert.match(links[1], /sni=anytls\.example\.com/);
    assert.match(links[1], /insecure=0/);
    assert.match(links[1], /#NODE_ANYTLS$/);
  });

  it('returns Clash YAML for the default node with normalized download filename', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`, {
      SUB_DOWNLOAD_NAME: 'Team_Sub.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/yaml; charset=UTF-8');
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename=Team_Sub');
    assert.match(body, /mixed-port: 1080/);
    assert.match(body, /- name: "NODE_REALITY"/);
    assert.match(body, /server: "reality\.example\.com"/);
    assert.match(body, /port: 443/);
    assert.match(body, /type: vless/);
    assert.match(body, /reality-opts:/);
    assert.match(body, /public-key: "REPLACE_WITH_REALITY_PUBLIC_KEY"/);
    assert.match(body, /DOMAIN-SUFFIX,bilibili\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,zhihu\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,douyin\.com,DIRECT/);
    assert.match(body, /DOMAIN,copilot\.microsoft\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,microsoft\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,apple-relay\.fastly-edge\.com,PROXY/);
    assert.match(body, /IP-CIDR6,2001:b28:f23d::\/48,PROXY,no-resolve/);
    assert.match(body, /GEOIP,CN,DIRECT,no-resolve/);
    assert.match(body, /AND,\(\(NETWORK,UDP\),\(DST-PORT,443\)\),REJECT/);
    assert.doesNotMatch(body, /RULE-SET,|rule-providers:|Loyalsoldier\/clash-rules/);
    assert.doesNotMatch(body, /edgeone\.gh-proxy\.org/);
    assert.doesNotMatch(body, /DOMAIN-KEYWORD,/);
    assert.doesNotMatch(body, /PROCESS-NAME,/);
    assert.ok(
      body.indexOf('DOMAIN-SUFFIX,bilibili.com,DIRECT') <
      body.indexOf('GEOSITE,geolocation-!cn,PROXY')
    );
    assert.doesNotMatch(body, /NODE_ANYTLS/);
    assert.doesNotMatch(body, /trojan/i);
  });

  it('uses portable IPv4 DNS/TUN routing and proxy DNS for Google/Gemini', async () => {
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
        'pool.ntp.org'
      ],
      'Fake-IP exclusions must contain only generic local/time domains'
    );
    assert.match(nameserverPolicy, /^\s+'\+\.lan': system$/m);
    assert.match(nameserverPolicy, /^\s+'\+\.local': system$/m);
    assert.match(
      nameserverPolicy,
      /^\s+'geosite:geolocation-!cn':\n\s+- https:\/\/1\.1\.1\.1\/dns-query#PROXY\n\s+- https:\/\/dns\.google\/dns-query#PROXY$/m,
      'all confirmed foreign domains, including Google/Gemini, must use proxy DNS'
    );
    assert.match(body, /^ipv6: false$/m);
    assert.match(body, /^\s+ipv6: false$/m);
    assert.match(body, /^log-level: error$/m);
    assert.match(body, /^find-process-mode: off$/m);
    assert.doesNotMatch(body, /fake-ip-range6:/);
    assert.doesNotMatch(body, /inet6-address:/);
    assert.match(body, /^\s+mtu: 1500$/m);
    assert.match(body, /^\s+strict-route: false$/m);
    assert.match(body, /^\s+route-exclude-address:$/m);
    assert.match(body, /^\s+- 10\.0\.0\.0\/8$/m);
    assert.match(body, /^\s+- 172\.16\.0\.0\/12$/m);
    assert.match(body, /^\s+- 192\.168\.0\.0\/16$/m);
    assert.match(body, /^\s+- 169\.254\.0\.0\/16$/m);
    assert.match(body, /^\s+- fc00::\/7$/m);
    assert.match(body, /^\s+- fe80::\/10$/m);
    assert.doesNotMatch(body, /^\s+- fdbd::\/16$/m);
    assert.match(body, /^    override-destination: false$/m);
    assert.doesNotMatch(body, /^    override-destination: true$/m);
    assert.doesNotMatch(body, /^        override-destination: true$/m);
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
    for (const domain of REMOVED_BYTEDANCE_DOMAINS) {
      assert.equal(body.includes(domain), false, `${domain} must stay removed from Clash YAML`);
    }
  });

  it('uses the gstatic generate_204 endpoint for automatic node probing', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`);
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.match(body, /^    - name: AUTO$/m);
    assert.match(body, /^      type: url-test$/m);
    assert.match(body, /^      url: 'https:\/\/www\.gstatic\.com\/generate_204'$/m);
    assert.match(body, /^      interval: 300$/m);
    assert.match(body, /^      lazy: true$/m);
    assert.match(body, /^    - name: PROXY\n      type: select\n      proxies:\n        - AUTO$/m);
  });

  it('returns all Clash proxy nodes for node=all and falls back invalid filenames', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all&flag=clash`, {
      SUB_DOWNLOAD_NAME: '../bad/name.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename=EASY_ALL');
    assert.match(body, /- name: "NODE_REALITY"/);
    assert.match(body, /server: "reality\.example\.com"/);
    assert.match(body, /port: 443/);
    assert.match(body, /- name: "NODE_ANYTLS"/);
    assert.match(body, /type: anytls/);
    assert.match(body, /server: "anytls\.example\.com"/);
    assert.match(body, /port: 10055/);
    assert.doesNotMatch(body, /ip-version:/);
    assert.match(body, /^proxy-groups:$/m);
    assert.match(body, /- name: PROXY\n      type: select\n      proxies:\n        - AUTO\n        - "NODE_REALITY"/);
    assert.doesNotMatch(body, /- name: (?:AI|AI_GEMINI|DOWNLOAD)$/m);
    assert.match(body, /DOMAIN,gemini\.google\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,github\.com,PROXY/);
  });

  it('quotes malicious node names without injecting YAML list entries', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace(
        "name: 'NODE_REALITY',",
        "name: 'bad\\n  - DIRECT {host} {rules_section}',"
      )
    );
    const response = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&node=all&flag=clash`)),
      {}
    );
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.match(body, /- name: "bad\\n  - DIRECT \{host\} \{rules_section\}"/);
    assert.match(body, /      - "bad\\n  - DIRECT \{host\} \{rules_section\}"/);
    assert.doesNotMatch(body, /\n\s+- DIRECT reality\.example\.com/);
  });

  it('honors both 443 and dynamic port modes for Reality and AnyTLS', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source
        .replace("sid: '0123456789abcdef',\n    portMode: '443'", "sid: '0123456789abcdef',\n    portMode: 'dynamic'")
        .replace("insecure: false,\n    portMode: 'dynamic'", "insecure: false,\n    portMode: '443'")
    );
    const response = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&node=all`)),
      {}
    );
    const links = decodeBase64Subscription(await responseText(response)).split('\n');

    assert.match(links[0], /@reality\.example\.com:10049\?/);
    assert.match(links[1], /@anytls\.example\.com:443\/\?/);
  });

  it('quotes every VLESS scalar and brackets IPv6 URI hosts', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source
        .replace("host: 'reality.example.com'", "host: '2001:db8::10'")
        .replace("sni: 'www.example.com'", "sni: 'safe\\nfield: value'")
    );
    const plain = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}`)),
      {}
    );
    const clash = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&flag=clash`)),
      {}
    );
    const link = decodeBase64Subscription(await responseText(plain));
    const yaml = await responseText(clash);

    assert.match(link, /@\[2001:db8::10\]:443\?/);
    assert.match(yaml, /server: "2001:db8::10"/);
    assert.match(yaml, /servername: "safe\\nfield: value"/);
    assert.doesNotMatch(yaml, /^field: value$/m);
  });

  it('can validate generated YAML with a real Mihomo binary', async (context) => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace(
        'REPLACE_WITH_REALITY_PUBLIC_KEY',
        'Ovep-pmhaM4KmKTU55eLpXrlvTyVu6x8zQAc_e0yHT0'
      )
    );
    const response = await module.default.fetch(
      new Request(subscribeUrl(`token=${VALID_TOKEN}&flag=clash`)),
      {}
    );
    const validated = await assertMihomoAccepts(await responseText(response));
    if (!validated) context.skip('Mihomo is not installed; set MIHOMO_BIN to enable schema validation');
  });
});
