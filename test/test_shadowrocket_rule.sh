#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)

node --input-type=module - "${ROOT_DIR}/profiles/shadowrocket-rule.js" <<'EOF'
import fs from "node:fs";

const workerPath = process.argv[2];
const source = fs.readFileSync(workerPath, "utf8");
const moduleUrl = `data:text/javascript;charset=utf-8,${encodeURIComponent(source)}`;

const fixture = `
[General]
ipv6 = false
skip-proxy = 192.168.0.0/16
tun-excluded-routes = 10.0.0.0/8

[Proxy]

[Proxy Group]
# no groups in lazy.conf

[Rule]
RULE-SET,https://example.com/global.list,PROXY
RULE-SET,https://example.com/china.list,DIRECT
FINAL,PROXY

[Host]
${"# fixture padding\n".repeat(80)}`;

const writes = [];
const matches = [];
let upstreamRequest;
let upstreamFetchCount = 0;
globalThis.caches = {
  default: {
    async match(request) {
      matches.push(request);
      return undefined;
    },
    async put(request, response) {
      writes.push([request, response]);
    },
  },
};
globalThis.fetch = async (request) => {
  upstreamFetchCount += 1;
  upstreamRequest = request;
  return new Response(fixture, { status: 200 });
};

const worker = (await import(moduleUrl)).default;
const pending = [];
const response = await worker.fetch(
  new Request("https://rules.example/EASY_ALL.conf"),
  {},
  { waitUntil(promise) { pending.push(promise); } },
);
const output = await response.text();
await Promise.all(pending);

const secondPending = [];
const secondResponse = await worker.fetch(
  new Request("https://rules.example/EASY_ALL.conf"),
  {},
  { waitUntil(promise) { secondPending.push(promise); } },
);
await secondResponse.text();
await Promise.all(secondPending);

function assertContains(needle) {
  if (!output.includes(needle)) {
    throw new Error(`missing output: ${needle}`);
  }
}

assertContains("AUTO = url-test,url=https://cp.cloudflare.com/generate_204,interval=300,tolerance=30,timeout=5,select=0");
assertContains("RULE-SET,https://example.com/global.list,AUTO");
assertContains("RULE-SET,https://example.com/china.list,DIRECT");
assertContains("FINAL,AUTO");
assertContains("update-url = https://rules.example/EASY_ALL.conf");
assertContains("ipv6 = false");
assertContains("AND,((PROTOCOL,UDP),(DEST-PORT,443)),REJECT");

if (output.includes("RULE-SET,https://example.com/global.list,PROXY")) {
  throw new Error("active PROXY rules must be rewritten to AUTO");
}

if (output.includes("policy-regex-filter=")) {
  throw new Error("AUTO group must not contain a node filter");
}

if ((output.match(/^AUTO = url-test/gm) || []).length !== 1) {
  throw new Error("AUTO group must appear exactly once");
}
if (upstreamRequest !== "https://johnshall.github.io/Shadowrocket-ADBlock-Rules-Forever/lazy.conf") {
  throw new Error(`unexpected upstream URL: ${upstreamRequest}`);
}
if (!writes.length) {
  throw new Error("generated configuration was not written to cache");
}
if (upstreamFetchCount !== 2) {
  throw new Error(`every request must fetch upstream; got ${upstreamFetchCount} fetches`);
}
if (matches.length !== 0) {
  throw new Error("successful requests must not read a fresh cache");
}
for (const [request, cachedResponse] of writes) {
  const cacheUrl = new URL(request.url);
  if (cacheUrl.searchParams.get("__easy_all_cache") !== "stale") {
    throw new Error(`unexpected cache kind: ${cacheUrl}`);
  }
  if (cacheUrl.searchParams.get("__easy_all_version") !== "v3") {
    throw new Error(`unexpected cache version: ${cacheUrl}`);
  }
  if (cachedResponse.headers.get("Cache-Control") !== "public, max-age=259200, s-maxage=259200") {
    throw new Error("stale fallback must expire after three days");
  }
}
if (response.headers.get("Cache-Control") !== "no-cache, no-store, must-revalidate") {
  throw new Error("live configuration must not be cached by the client");
}
if (response.headers.get("X-EASY-ALL-Cache") !== "LIVE") {
  throw new Error("live response must be marked LIVE");
}

console.log("ok - Shadowrocket Worker transformation tests passed");
EOF
