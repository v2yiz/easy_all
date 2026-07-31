import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { afterEach, beforeEach, describe, it } from 'node:test';

import worker from '../sample-worker.js';

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
      .filter(line => /^(DOMAIN|DOMAIN-SUFFIX|DOMAIN-KEYWORD|IP-CIDR|IP-CIDR6|GEOIP|GEOSITE|MATCH),/.test(line));
    const keys = rules.map(rule => rule.split(',').slice(0, 2).join(',').toLowerCase());

    assert.equal(new Set(keys).size, keys.length, 'rules must not contain duplicate match keys');
    assert.equal(rules.at(-1), 'MATCH,PROXY');
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
    assert.ok(rules.includes('IP-CIDR6,2001:b28:f23d::/48,PROXY,no-resolve'));
    assert.equal(rules.some(rule => /^IP-CIDR,[^,]*:/.test(rule)), false);
    assert.equal(rules.some(rule => /24\.199\.123\.28|45\.76\.214\.191/.test(rule)), false);
  });

  it('rejects non-subscribe paths', async () => {
    const response = await worker.fetch(new Request('https://worker.example.test/health'), {});

    assert.equal(response.status, 404);
    assert.equal(await responseText(response), 'Not Found');
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
    assert.match(body, /^vless:\/\/00000000-0000-4000-8000-000000000001@reality\.example\.com:10049\?/);
    assert.match(body, /security=reality/);
    assert.match(body, /flow=xtls-rprx-vision/);
    assert.match(body, /packetEncoding=xudp/);
    assert.match(body, /#NODE_REALITY$/);
    assert.doesNotMatch(body, /NODE_ANYTLS/);
    assert.doesNotMatch(body, /NODE_VLESS_WSS/);
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
    assert.equal(links.length, 3);
    assert.match(links[0], /^vless:\/\/00000000-0000-4000-8000-000000000001@reality\.example\.com:10049\?/);
    assert.match(links[1], /^anytls:\/\/REPLACE_WITH_ANYTLS_PASSWORD@anytls\.example\.com:10055\/\?/);
    assert.match(links[2], /^vless:\/\/00000000-0000-4000-8000-000000000002@wss\.example\.com:443\?/);
    assert.match(links[0], /#NODE_REALITY$/);
    assert.match(links[1], /sni=anytls\.example\.com/);
    assert.match(links[1], /insecure=0/);
    assert.match(links[1], /#NODE_ANYTLS$/);
    assert.match(links[2], /security=tls/);
    assert.match(links[2], /type=ws/);
    assert.match(links[2], /path=%2Frandompath/);
    assert.match(links[2], /host=wss\.example\.com/);
    assert.doesNotMatch(links[2], /flow=xtls-rprx-vision/);
    assert.match(links[2], /#NODE_VLESS_WSS$/);
  });

  it('returns Clash YAML for the default node with normalized download filename', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`, {
      SUB_DOWNLOAD_NAME: 'Team_Sub.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/yaml; charset=UTF-8');
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename="Team_Sub"');
    assert.match(body, /mixed-port: 1080/);
    assert.match(body, /- name: "NODE_REALITY"/);
    assert.match(body, /server: reality\.example\.com/);
    assert.match(body, /port: 10049/);
    assert.match(body, /type: vless/);
    assert.match(body, /reality-opts:/);
    assert.match(body, /public-key: REPLACE_WITH_REALITY_PUBLIC_KEY/);
    assert.match(body, /DOMAIN-SUFFIX,bilibili\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,zhihu\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,douyin\.com,DIRECT/);
    assert.match(body, /DOMAIN,copilot\.microsoft\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,microsoft\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,apple-relay\.fastly-edge\.com,PROXY/);
    assert.match(body, /IP-CIDR6,2001:b28:f23d::\/48,PROXY,no-resolve/);
    assert.match(body, /GEOIP,CN,DIRECT,no-resolve/);
    assert.ok(
      body.indexOf('DOMAIN-SUFFIX,bilibili.com,DIRECT') <
      body.indexOf('GEOSITE,geolocation-!cn,PROXY')
    );
    assert.doesNotMatch(body, /NODE_ANYTLS/);
    assert.doesNotMatch(body, /NODE_VLESS_WSS/);
    assert.doesNotMatch(body, /trojan/i);
  });

  it('keeps Gemini proxied and IPv4-only without Fake-IP targets', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&flag=clash`);
    const body = await responseText(response);
    const nameserverPolicy = body.match(
      /    nameserver-policy:\n([\s\S]*?)\n    enhanced-mode:/
    )?.[1];
    const fakeIpFilter = body.match(
      /    fake-ip-filter:\n([\s\S]*?)\n    nameserver:/
    )?.[1];

    assert.equal(response.status, 200);
    assert.ok(nameserverPolicy, 'nameserver-policy must be present');
    assert.ok(fakeIpFilter, 'fake-ip-filter must be present');
    assert.match(body, /^ipv6: true$/m);
    assert.match(body, /^\s+ipv6: true$/m);
    assert.match(nameserverPolicy, /'\+\.chatgpt\.com': &ipv4_only_dns/);
    assert.match(nameserverPolicy, /'\+\.openai\.com': \*ipv4_only_dns/);
    assert.match(nameserverPolicy, /'\+\.claude\.ai': \*ipv4_only_dns/);
    assert.match(nameserverPolicy, /'\+\.google\.com': \*ipv4_only_dns/);
    assert.match(nameserverPolicy, /'\+\.googleapis\.com': \*ipv4_only_dns/);
    assert.match(nameserverPolicy, /'\+\.gstatic\.com': \*ipv4_only_dns/);
    assert.doesNotMatch(nameserverPolicy, /'\+\.mega\.nz': \*ipv4_only_dns/);
    assert.doesNotMatch(nameserverPolicy, /'\+\.mega\.co\.nz': \*ipv4_only_dns/);
    assert.doesNotMatch(nameserverPolicy, /'\+\.mega\.io': \*ipv4_only_dns/);
    assert.doesNotMatch(nameserverPolicy, /'\+\.mega\.app': \*ipv4_only_dns/);
    assert.match(nameserverPolicy, /dns-query#disable-ipv6=true&disable-qtype-65=true/);
    assert.match(body, /^\s+strict-route: true$/m);
    assert.match(fakeIpFilter, /^\s+- '\+\.openai\.com'$/m);
    assert.match(fakeIpFilter, /^\s+- '\+\.claude\.ai'$/m);
    assert.match(fakeIpFilter, /^\s+- '\+\.google\.com'$/m);
    assert.match(fakeIpFilter, /^\s+- '\+\.googleapis\.com'$/m);
    assert.match(fakeIpFilter, /^\s+- '\+\.gstatic\.com'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.mega\.nz'$/m);
    assert.doesNotMatch(fakeIpFilter, /^\s+- '\+\.mega\.app'$/m);
    assert.match(body, /DOMAIN-SUFFIX,mega\.nz,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,mega\.co\.nz,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,mega\.io,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,mega\.app,PROXY/);
    assert.match(body, /DOMAIN,gemini\.google\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,google\.com,PROXY/);
    assert.match(body, /DOMAIN-SUFFIX,googleapis\.com,PROXY/);
    assert.doesNotMatch(nameserverPolicy, /'\+\.bilibili\.com': \*ipv4_only_dns/);
  });

  it('returns all Clash proxy nodes for node=all and falls back invalid filenames', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all&flag=clash`, {
      SUB_DOWNLOAD_NAME: '../bad/name.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename="EASY_ALL"');
    assert.match(body, /- name: "NODE_REALITY"/);
    assert.match(body, /server: reality\.example\.com/);
    assert.match(body, /port: 10049/);
    assert.match(body, /- name: "NODE_ANYTLS"/);
    assert.match(body, /type: anytls/);
    assert.match(body, /server: "anytls\.example\.com"/);
    assert.match(body, /port: 10055/);
    assert.match(body, /- name: "NODE_VLESS_WSS"/);
    assert.match(body, /server: wss\.example\.com/);
    assert.match(body, /network: ws/);
    assert.match(body, /path: \/randompath/);
    assert.match(body, /Host: wss\.example\.com/);
    assert.match(body, /      - "NODE_REALITY"\n        - "NODE_ANYTLS"\n        - "NODE_VLESS_WSS"/);

    const wsNode = body.slice(body.indexOf('- name: "NODE_VLESS_WSS"'));
    assert.match(wsNode, /network: ws/);
    assert.match(wsNode, /ws-opts:/);
    assert.doesNotMatch(wsNode, /flow: xtls-rprx-vision/);
  });

  it('quotes malicious VLESS names without injecting YAML list entries', async () => {
    const source = await readFile(new URL('../sample-worker.js', import.meta.url), 'utf8');
    const module = await importSampleWorkerWithSource(
      source.replace(
        "name: 'NODE_REALITY',",
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
    assert.doesNotMatch(body, /\n\s+- DIRECT reality\.example\.com/);
  });
});
