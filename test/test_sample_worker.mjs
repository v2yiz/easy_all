import assert from 'node:assert/strict';
import { afterEach, beforeEach, describe, it } from 'node:test';

import worker from '../sample-worker.js';

const VALID_TOKEN = 'REPLACE_WITH_TOKEN_1';
const FIXED_NOW = Date.UTC(2026, 0, 1, 0, 0, 0);

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

  it('rejects non-subscribe paths', async () => {
    const response = await worker.fetch(new Request('https://worker.example.test/health'), {});

    assert.equal(response.status, 404);
    assert.equal(await responseText(response), 'Not Found');
  });

  it('rejects missing or unknown tokens', async () => {
    const missing = await fetchSubscribe();
    const invalid = await fetchSubscribe('token=unknown');

    assert.equal(missing.status, 403);
    assert.equal(await responseText(missing), '403 Forbidden');
    assert.equal(invalid.status, 403);
    assert.equal(await responseText(invalid), '403 Forbidden');
  });

  it('returns only DEFAULT_NODE in the default base64 subscription', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}`);
    const body = decodeBase64Subscription(await responseText(response));

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-type'), 'text/plain; charset=UTF-8');
    assert.match(response.headers.get('cache-control'), /no-store/);
    assert.equal(response.headers.get('content-disposition'), 'inline');
    assert.match(body, /^vless:\/\/00000000-0000-4000-8000-000000000001@node-a\.example\.com:10049\?/);
    assert.match(body, /security=reality/);
    assert.match(body, /flow=xtls-rprx-vision/);
    assert.match(body, /packetEncoding=xudp/);
    assert.match(body, /#NODE_A$/);
    assert.doesNotMatch(body, /NODE_B/);
    assert.doesNotMatch(body, /NODE_C_TLS_VISION/);
    assert.doesNotMatch(body, /NODE_D_ANYTLS/);
    assert.doesNotMatch(body, /NODE_E_WS_TLS/);
    assert.doesNotMatch(body, /trojan/i);
  });

  it('returns all registered nodes when node=all is requested', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all`);
    const body = decodeBase64Subscription(await responseText(response));
    const links = body.split('\n');

    assert.equal(response.status, 200);
    assert.equal(links.length, 5);
    assert.match(links[0], /^vless:\/\/00000000-0000-4000-8000-000000000001@node-a\.example\.com:10049\?/);
    assert.match(links[1], /^vless:\/\/00000000-0000-4000-8000-000000000002@node-b\.example\.com:10055\?/);
    assert.match(links[2], /^vless:\/\/00000000-0000-4000-8000-000000000003@node-c\.example\.com:443\?/);
    assert.match(links[3], /^anytls:\/\/REPLACE_WITH_ANYTLS_PASSWORD@anytls\.example\.com:10067\/\?/);
    assert.match(links[4], /^vless:\/\/00000000-0000-4000-8000-000000000004@node-e\.example\.com:443\?/);
    assert.match(links[0], /#NODE_A$/);
    assert.match(links[1], /#NODE_B$/);
    assert.match(links[2], /security=tls/);
    assert.match(links[2], /flow=xtls-rprx-vision/);
    assert.doesNotMatch(links[2], /pbk=/);
    assert.doesNotMatch(links[2], /sid=/);
    assert.match(links[2], /#NODE_C_TLS_VISION$/);
    assert.match(links[3], /sni=anytls\.example\.com/);
    assert.match(links[3], /insecure=0/);
    assert.match(links[3], /#NODE_D_ANYTLS$/);
    assert.match(links[4], /security=tls/);
    assert.match(links[4], /type=ws/);
    assert.match(links[4], /path=%2Fhacxws/);
    assert.match(links[4], /host=node-e\.example\.com/);
    assert.doesNotMatch(links[4], /flow=xtls-rprx-vision/);
    assert.match(links[4], /#NODE_E_WS_TLS$/);
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
    assert.match(body, /- name: NODE_A/);
    assert.match(body, /server: node-a\.example\.com/);
    assert.match(body, /port: 10049/);
    assert.match(body, /type: vless/);
    assert.match(body, /reality-opts:/);
    assert.match(body, /public-key: REPLACE_WITH_REALITY_PUBLIC_KEY_A/);
    assert.match(body, /DOMAIN-SUFFIX,bilibili\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,zhihu\.com,DIRECT/);
    assert.match(body, /DOMAIN-SUFFIX,douyin\.com,DIRECT/);
    assert.match(body, /GEOIP,CN,DIRECT,no-resolve/);
    assert.ok(
      body.indexOf('DOMAIN-SUFFIX,bilibili.com,DIRECT') <
      body.indexOf('GEOSITE,geolocation-!cn,PROXY')
    );
    assert.doesNotMatch(body, /NODE_B/);
    assert.doesNotMatch(body, /trojan/i);
  });

  it('returns all Clash proxy nodes for node=all and falls back invalid filenames', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all&flag=clash`, {
      SUB_DOWNLOAD_NAME: '../bad/name.yaml'
    });
    const body = await responseText(response);

    assert.equal(response.status, 200);
    assert.equal(response.headers.get('content-disposition'), 'attachment; filename="MY_SUB"');
    assert.match(body, /- name: NODE_A/);
    assert.match(body, /server: node-a\.example\.com/);
    assert.match(body, /port: 10049/);
    assert.match(body, /- name: NODE_B/);
    assert.match(body, /server: node-b\.example\.com/);
    assert.match(body, /port: 10055/);
    assert.match(body, /- name: NODE_C_TLS_VISION/);
    assert.match(body, /server: node-c\.example\.com/);
    assert.match(body, /port: 443/);
    assert.match(body, /- name: "NODE_D_ANYTLS"/);
    assert.match(body, /type: anytls/);
    assert.match(body, /server: "anytls\.example\.com"/);
    assert.match(body, /port: 10067/);
    assert.match(body, /- name: NODE_E_WS_TLS/);
    assert.match(body, /server: node-e\.example\.com/);
    assert.match(body, /network: ws/);
    assert.match(body, /path: \/hacxws/);
    assert.match(body, /Host: node-e\.example\.com/);
    assert.match(body, /      - NODE_A\n        - NODE_B\n        - NODE_C_TLS_VISION\n        - NODE_D_ANYTLS\n        - NODE_E_WS_TLS/);

    const tlsNode = body.slice(body.indexOf('- name: NODE_C_TLS_VISION'));
    assert.match(tlsNode, /flow: xtls-rprx-vision/);
    assert.match(tlsNode, /servername: node-c\.example\.com/);
    assert.doesNotMatch(tlsNode, /reality-opts:/);

    const wsNode = body.slice(body.indexOf('- name: NODE_E_WS_TLS'));
    assert.match(wsNode, /network: ws/);
    assert.match(wsNode, /ws-opts:/);
    assert.doesNotMatch(wsNode, /flow: xtls-rprx-vision/);
  });
});
