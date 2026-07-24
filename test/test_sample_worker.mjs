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
    assert.doesNotMatch(body, /trojan/i);
  });

  it('returns all registered nodes when node=all is requested', async () => {
    const response = await fetchSubscribe(`token=${VALID_TOKEN}&node=all`);
    const body = decodeBase64Subscription(await responseText(response));
    const links = body.split('\n');

    assert.equal(response.status, 200);
    assert.equal(links.length, 2);
    assert.match(links[0], /^vless:\/\/00000000-0000-4000-8000-000000000001@node-a\.example\.com:10049\?/);
    assert.match(links[1], /^vless:\/\/00000000-0000-4000-8000-000000000002@node-b\.example\.com:10055\?/);
    assert.match(links[0], /#NODE_A$/);
    assert.match(links[1], /#NODE_B$/);
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
    assert.match(body, /      - NODE_A\n        - NODE_B/);
  });
});
