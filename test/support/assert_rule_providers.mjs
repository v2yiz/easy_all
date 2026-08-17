import assert from 'node:assert/strict';

const PROVIDERS = Object.freeze([
  ['private', 'domain', 262144, 'DIRECT'],
  ['icloud', 'domain', 262144, 'DIRECT'],
  ['apple', 'domain', 262144, 'DIRECT'],
  ['google', 'domain', 262144, 'PROXY'],
  ['gfw', 'domain', 524288, 'PROXY'],
  ['greatfire', 'domain', 262144, 'PROXY'],
  ['proxy', 'domain', 4194304, 'PROXY'],
  ['direct', 'domain', 4194304, 'DIRECT'],
  ['tld-not-cn', 'domain', 1048576, 'PROXY'],
  ['telegramcidr', 'ipcidr', 262144, 'PROXY,no-resolve'],
  ['lancidr', 'ipcidr', 262144, 'DIRECT,no-resolve'],
  ['cncidr', 'ipcidr', 1048576, 'DIRECT,no-resolve']
]);

export function assertExternalRuleProviders(yaml) {
  const providerSection = yaml.match(/rule-providers:\n([\s\S]*?)\n\nrules:/)?.[1];
  assert.ok(providerSection, 'rule-providers must appear before rules');
  assert.deepEqual(
    [...providerSection.matchAll(/^    ([a-z][a-z-]*):$/gm)].map(match => match[1]),
    PROVIDERS.map(([name]) => name),
    'only the reviewed providers should be loaded, in deterministic order'
  );

  for (let index = 0; index < PROVIDERS.length; index += 1) {
    const [name, behavior, sizeLimit, policy] = PROVIDERS[index];
    const escapedName = name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const start = providerSection.indexOf(`    ${name}:\n`);
    const nextName = PROVIDERS[index + 1]?.[0];
    const end = nextName ? providerSection.indexOf(`    ${nextName}:\n`, start) : providerSection.length;
    assert.ok(start >= 0 && end > start, `${name} provider must exist`);
    const block = providerSection.slice(start, end);
    assert.match(block, /^      type: http$/m);
    assert.match(block, new RegExp(`^      behavior: ${behavior}$`, 'm'));
    assert.match(block, /^      format: yaml$/m);
    assert.match(
      block,
      new RegExp(
        `^      url: 'https://raw\\.githubusercontent\\.com/Loyalsoldier/clash-rules/release/${escapedName}\\.txt'$`,
        'm'
      )
    );
    assert.match(block, new RegExp(`^      path: \\./ruleset/loyalsoldier/${escapedName}\\.yaml$`, 'm'));
    assert.match(block, /^      interval: 86400$/m);
    assert.match(block, /^      proxy: PROXY$/m);
    assert.match(block, new RegExp(`^      size-limit: ${sizeLimit}$`, 'm'));
    assert.match(yaml, new RegExp(`^  - RULE-SET,${escapedName},${policy}$`, 'm'));
  }

  assert.doesNotMatch(yaml, /edgeone\.gh-proxy\.org|cdn\.jsdelivr\.net/);
  assert.doesNotMatch(yaml, /^    applications:|RULE-SET,applications,/m);
  assert.match(yaml, /^find-process-mode: off$/m);
  for (const rule of [
    'DOMAIN-SUFFIX,futooncdn.com,DIRECT',
    'DOMAIN-SUFFIX,ipleak.net,PROXY',
    'DOMAIN-SUFFIX,githubcopilot.com,PROXY',
    'DOMAIN-SUFFIX,jetbrains.ai,PROXY'
  ]) {
    assert.ok(yaml.includes(rule), `${rule} must stay ahead of remote providers`);
  }
  assert.match(yaml, /^      - '\+\.futooncdn\.com'$/m);
  assert.ok(
    yaml.indexOf('DOMAIN-SUFFIX,10jqka.com.cn,DIRECT') < yaml.indexOf('RULE-SET,private,DIRECT') &&
      yaml.indexOf('DOMAIN-SUFFIX,ipleak.net,PROXY') < yaml.indexOf('RULE-SET,direct,DIRECT') &&
      yaml.indexOf('RULE-SET,cncidr,DIRECT,no-resolve') <
        yaml.indexOf('GEOIP,CN,DIRECT,no-resolve'),
    'local safety rules must precede XFLASH providers and geodata fallbacks'
  );
}
