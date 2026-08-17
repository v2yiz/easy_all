/**
 * 订阅服务样例 - Cloudflare Workers
 * 同时提供 VLESS WebSocket TLS 与 VLESS XHTTP TLS/H2 的 Cloudflare CDN 订阅
 *
 * 使用前请替换：
 * 1. ALLOWED_TOKENS 中的订阅 token
 * 2. 节点认证信息、TLS 域名、WebSocket 路径和 XHTTP 路径
 * 3. DEFAULT_NODE 保留两个节点，以便同一订阅同时输出
 */
// ================= 配置常量 =================

// EASY_CMCC_CONFIG_START
const ALLOWED_TOKENS = {
    user1: 'REPLACE_WITH_TOKEN_1',
    user2: 'REPLACE_WITH_TOKEN_2'
};
const ALLOWED_TOKEN_VALUES = new Set(Object.values(ALLOWED_TOKENS));

const PORT_BASE = 10000;
const PORT_MULTIPLIER = 6;
const DEFAULT_SUB_DOWNLOAD_NAME = 'EASY_CMCC';
const CONFIGS = [];

function defineNode(config) {
    CONFIGS.push(config);
    return config;
}

function isAllowedToken(token) {
    return Boolean(token && ALLOWED_TOKEN_VALUES.has(token));
}

// ── 两个节点共用 CDN 域名与 UUID，使用独立传输路径 ──────────────
const NODE_VLESS_WS_CONFIG = defineNode({
    type: 'vless',
    security: 'tls',
    network: 'ws',
    uuid: '00000000-0000-4000-8000-000000000002',
    host: 'ws.example.com',
    name: 'VLESS_WS',
    fp: 'chrome',
    sni: 'ws.example.com',
    path: '/vless-change-me',
    maxEarlyData: 2560,
    earlyDataHeaderName: 'Sec-WebSocket-Protocol',
    ipVersion: 'ipv4',
    udp: true,
    packetEncoding: 'xudp',
    portMode: '443'
});

const NODE_VLESS_XHTTP_CONFIG = defineNode({
    type: 'vless',
    security: 'tls',
    network: 'xhttp',
    uuid: '00000000-0000-4000-8000-000000000002',
    host: 'ws.example.com',
    name: 'VLESS_XHTTP_H2',
    fp: 'chrome',
    sni: 'ws.example.com',
    path: '/xhttp-change-me',
    mode: 'auto',
    ipVersion: 'dual',
    udp: true,
    packetEncoding: 'xudp',
    portMode: '443'
});

const DEFAULT_NODE = [NODE_VLESS_WS_CONFIG, NODE_VLESS_XHTTP_CONFIG];

function defaultNodeConfigs() {
    return Array.isArray(DEFAULT_NODE) ? DEFAULT_NODE : [DEFAULT_NODE];
}
// EASY_CMCC_CONFIG_END

// ================= 规则与模板 =================

// EASY_CMCC_RULES_START
// 服务端为 Gemini 及其必要 Google 依赖固定同一出口族；其他 AI 服务保持默认双栈行为。
const GEMINI_DOMAIN_SUFFIXES = Object.freeze(
/* EASY_CMCC_GEMINI_DOMAINS_START */
[
    "ai.google.dev",
    "generativeai.google",
    "google.com",
    "googleapis.com",
    "googleusercontent.com",
    "gstatic.com",
    "ggpht.com"
]
/* EASY_CMCC_GEMINI_DOMAINS_END */
);

const BASE_FAKE_IP_FILTER = [
    '+.lan',
    '+.local',
    'localhost',
    'time.windows.com',
    'time.apple.com',
    '*.ntp.org.cn',
    'pool.ntp.org',
];

// 行情/交易客户端常有自定义长连接和非标准端口。使其获得真实 IPv4，避免
// TUN Fake-IP 映射在连接重建时影响行情刷新；同时在规则中显式直连，不依赖
// GeoSite 数据版本是否收录其域名。
const CN_SECURITIES_DOMAIN_SUFFIXES = Object.freeze([
    // 同花顺 / iFinD
    '10jqka.com.cn',
    'hexin.cn',
    'hexin.com.cn',
    'myhexin.com',
    'ths123.com',
    'iwencai.com',
    'iwencai.cn',
    '51ifind.com',
    '51ifind.com.cn',

    // 东方财富 / 东方财富证券
    'eastmoney.com',
    'eastmoney.cn',
    'eastmoney.com.cn',
    'eastmoneysec.com',
    'dfcfw.com',
    'guba.com.cn',
    '18.cn',

    // 通达信、东北证券
    'tdx.com.cn',
    'nesc.cn',

    // 常用券商客户端
    'citics.com',
    'citics.com.cn',
    'citicsinfo.com',
    'cs.ecitic.com',
    'csc108.com',
    'gtht.com',
    'gtja.com',
    'gtjas.com',
    'htsec.com',
    'htsec.com.cn',
    'haitong.com',
    'haitong.com.cn',
    'htsc.com',
    'htsc.com.cn',
    'cmschina.com',
    'cmschina.com.cn',
    'gf.com.cn',
    'guosen.com.cn',
    'chinastock.com.cn',
    'xyzq.com.cn',
    'futooncdn.com',
]);

const FAKE_IP_FILTER = [...BASE_FAKE_IP_FILTER,
    ...CN_SECURITIES_DOMAIN_SUFFIXES.map(domain => `+.${domain}`),
]
    .map(domain => `      - '${domain}'`)
    .join('\n');

const CN_SECURITIES_DIRECT_RULES = CN_SECURITIES_DOMAIN_SUFFIXES
    .map(domain => `  - DOMAIN-SUFFIX,${domain},DIRECT`)
    .join('\n');

// 官方远程规则经现有代理组更新，避免使用第三方 GitHub 代理；逐项 size-limit
// 可防止异常响应耗尽客户端内存。applications 依赖已关闭的进程探测，故不加载。
const OFFICIAL_CLASH_RULES_BASE_URL =
    'https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release';
const EXTERNAL_RULE_PROVIDER_SPECS = Object.freeze([
    ['private', 'domain', 262144],
    ['icloud', 'domain', 262144],
    ['apple', 'domain', 262144],
    ['google', 'domain', 262144],
    ['gfw', 'domain', 524288],
    ['greatfire', 'domain', 262144],
    ['proxy', 'domain', 4194304],
    ['direct', 'domain', 4194304],
    ['tld-not-cn', 'domain', 1048576],
    ['telegramcidr', 'ipcidr', 262144],
    ['lancidr', 'ipcidr', 262144],
    ['cncidr', 'ipcidr', 1048576],
]);
const EXTERNAL_RULE_PROVIDERS = `rule-providers:\n${EXTERNAL_RULE_PROVIDER_SPECS
    .map(([name, behavior, sizeLimit]) => `    ${name}:
      type: http
      behavior: ${behavior}
      format: yaml
      url: '${OFFICIAL_CLASH_RULES_BASE_URL}/${name}.txt'
      path: ./ruleset/loyalsoldier/${name}.yaml
      interval: 86400
      proxy: PROXY
      size-limit: ${sizeLimit}
`)
    .join('')}`;

const EMBEDDED_CLASH_RULES = `rules:
  # ==================== 本地安全前置规则 ====================
  - DOMAIN-SUFFIX,local,DIRECT
  - DOMAIN-SUFFIX,localhost,DIRECT
  - IP-CIDR,127.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,10.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR,172.16.0.0/12,DIRECT,no-resolve
  - IP-CIDR,192.168.0.0/16,DIRECT,no-resolve
  - IP-CIDR,169.254.0.0/16,DIRECT,no-resolve
  - IP-CIDR6,::1/128,DIRECT,no-resolve
  - IP-CIDR6,fc00::/7,DIRECT,no-resolve
  - IP-CIDR6,fe80::/10,DIRECT,no-resolve

  # WS/XHTTP 均以 TCP 承载；公网 QUIC 必须先于所有代理规则拒绝。
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT

  # 行情域名同时保留 Fake-IP 豁免与显式直连。
${CN_SECURITIES_DIRECT_RULES}

  # Apple Relay 与 Copilot 例外必须先于 Apple/Microsoft 远程规则。
  - DOMAIN-SUFFIX,apple-relay.akamaized.net,PROXY
  - DOMAIN-SUFFIX,apple-relay.apple.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.cloudflare.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.fastly-edge.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.mask.apple-dns.net,PROXY
  - DOMAIN,copilot.microsoft.com,PROXY
  - DOMAIN,copilot.bing.com,PROXY
  - DOMAIN,api.msn.com,PROXY
  - DOMAIN,assets.msn.com,PROXY
  - DOMAIN,gateway.bingviz.microsoft.net,PROXY
  - DOMAIN,gateway.bingviz.microsoftapp.net,PROXY
  - DOMAIN,in.appcenter.ms,PROXY
  - DOMAIN,location.microsoft.com,PROXY
  - DOMAIN,odc.officeapps.live.com,PROXY
  - DOMAIN,self.events.data.microsoft.com,PROXY
  - DOMAIN,services.bingapis.com,PROXY
  - DOMAIN-SUFFIX,bing.com,PROXY
  - DOMAIN-SUFFIX,githubcopilot.com,PROXY
  - DOMAIN-SUFFIX,api.microsoftapp.net,PROXY
  - DOMAIN-SUFFIX,edgeservices.bing.com,PROXY
  - DOMAIN-SUFFIX,bing-shopping.microsoft-falcon.io,PROXY

  # ==================== XFLASH 主体规则 ====================
  - DOMAIN,www.xflash.work,DIRECT
  - DOMAIN,ssl.gstatic.com,DIRECT
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  - DOMAIN-SUFFIX,ipleak.net,PROXY
  - DOMAIN-SUFFIX,browserscan.net,PROXY
  - DOMAIN-SUFFIX,surfsharkdns.com,PROXY
  - DOMAIN-SUFFIX,edns.ip-api.com,PROXY
  - DOMAIN-SUFFIX,dnsleaktest.com,PROXY
  - DOMAIN-SUFFIX,dnsleak.com,PROXY
  - DOMAIN-SUFFIX,expressvpn.com,PROXY
  - DOMAIN-SUFFIX,nordvpn.com,PROXY
  - DOMAIN-SUFFIX,surfshark.com,PROXY
  - DOMAIN-SUFFIX,perfect-privacy.com,PROXY
  - DOMAIN-SUFFIX,browserleaks.com,PROXY
  - DOMAIN-SUFFIX,browserleaks.org,PROXY
  - DOMAIN-SUFFIX,browserleaks.net,PROXY
  - DOMAIN-SUFFIX,vpnunlimited.com,PROXY
  - DOMAIN-SUFFIX,whoer.net,PROXY
  - DOMAIN-SUFFIX,whrq.net,PROXY
  - DOMAIN-SUFFIX,asmr.one,PROXY
  - DOMAIN,browser-intake-datadoghq.com,PROXY
  - DOMAIN,chat.openai.com.cdn.cloudflare.net,PROXY
  - DOMAIN,openai-api.arkoselabs.com,PROXY
  - DOMAIN,openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net,PROXY
  - DOMAIN,openaicomproductionae4b.blob.core.windows.net,PROXY
  - DOMAIN,production-openaicom-storage.azureedge.net,PROXY
  - DOMAIN,static.cloudflareinsights.com,PROXY
  - DOMAIN-SUFFIX,ai.com,PROXY
  - DOMAIN-SUFFIX,algolia.net,PROXY
  - DOMAIN-SUFFIX,api.statsig.com,PROXY
  - DOMAIN-SUFFIX,auth0.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.livekit.cloud,PROXY
  - DOMAIN-SUFFIX,client-api.arkoselabs.com,PROXY
  - DOMAIN-SUFFIX,events.statsigapi.net,PROXY
  - DOMAIN-SUFFIX,featuregates.org,PROXY
  - DOMAIN-SUFFIX,host.livekit.cloud,PROXY
  - DOMAIN-SUFFIX,identrust.com,PROXY
  - DOMAIN-SUFFIX,intercom.io,PROXY
  - DOMAIN-SUFFIX,intercomcdn.com,PROXY
  - DOMAIN-SUFFIX,launchdarkly.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - DOMAIN-SUFFIX,observeit.net,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,openaiapi-site.azureedge.net,PROXY
  - DOMAIN-SUFFIX,openaicom.imgix.net,PROXY
  - DOMAIN-SUFFIX,segment.io,PROXY
  - DOMAIN-SUFFIX,sentry.io,PROXY
  - DOMAIN-SUFFIX,stripe.com,PROXY
  - DOMAIN-SUFFIX,turn.livekit.cloud,PROXY
  - DOMAIN-SUFFIX,sora.com,PROXY
  - DOMAIN-KEYWORD,openai,PROXY
  - DOMAIN,r.bing.com,PROXY
  - DOMAIN,sydney.bing.com,PROXY
  - DOMAIN,www.bing.com,PROXY
  - DOMAIN-SUFFIX,challenges.cloudflare.com,PROXY
  - DOMAIN-KEYWORD,openaicom-api,PROXY
  - DOMAIN-SUFFIX,gvt2.com,PROXY
  - DOMAIN,ai.google.dev,PROXY
  - DOMAIN,alkalimakersuite-pa.clients6.google.com,PROXY
  - DOMAIN,makersuite.google.com,PROXY
  - DOMAIN-SUFFIX,bard.google.com,PROXY
  - DOMAIN-SUFFIX,deepmind.com,PROXY
  - DOMAIN-SUFFIX,deepmind.google,PROXY
  - DOMAIN-SUFFIX,gemini.google.com,PROXY
  - DOMAIN-SUFFIX,generativeai.google,PROXY
  - DOMAIN-SUFFIX,proactivebackend-pa.googleapis.com,PROXY
  - DOMAIN-SUFFIX,apis.google.com,PROXY
  - DOMAIN-KEYWORD,colab,PROXY
  - DOMAIN-KEYWORD,developerprofiles,PROXY
  - DOMAIN-KEYWORD,generativelanguage,PROXY
  - DOMAIN,cdn.usefathom.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,razie.ai,PROXY
  - DOMAIN-SUFFIX,razie.aws.intellij.net,PROXY
  - DOMAIN-SUFFIX,jetbrains.ai,PROXY
  - DOMAIN-SUFFIX,meta.com,PROXY
  - DOMAIN-SUFFIX,services.googleapis.cn,PROXY
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,PROXY
  - DOMAIN,clash.razord.top,DIRECT
  - DOMAIN,yacd.haishan.me,DIRECT
  - RULE-SET,private,DIRECT
  - RULE-SET,icloud,DIRECT
  - RULE-SET,apple,DIRECT
  - RULE-SET,google,PROXY
  - RULE-SET,gfw,PROXY
  - RULE-SET,greatfire,PROXY
  - RULE-SET,proxy,PROXY
  - RULE-SET,direct,DIRECT
  - RULE-SET,tld-not-cn,PROXY
  - RULE-SET,telegramcidr,PROXY,no-resolve
  - RULE-SET,lancidr,DIRECT,no-resolve
  - RULE-SET,cncidr,DIRECT,no-resolve
  - GEOIP,LAN,DIRECT,no-resolve
  - GEOIP,CN,DIRECT,no-resolve
  - GEOSITE,CN,DIRECT
  - GEOSITE,private,DIRECT
  - MATCH,PROXY
`;
// EASY_CMCC_RULES_END

const CLASH_CONFIG_TEMPLATE = `mixed-port: 1080
allow-lan: false
mode: rule
log-level: error
ipv6: true
external-controller: '127.0.0.1:9090'
unified-delay: true
tcp-concurrent: false
find-process-mode: off
profile:
    store-selected: true

sniffer:
    enable: false

tun:
    enable: true
    stack: system
    mtu: 1500
    # 默认 UDP NAT 会话仅保留 5 分钟；行情客户端的低频 UDP 长连接保留 2 小时。
    udp-timeout: 7200
    auto-route: true
    auto-detect-interface: true
    inet4-address:
      - 198.18.0.1/30
    dns-hijack:
      - any:53
      - tcp://any:53
    # Windows TUN + Cloudflare CDN 使用兼容模式，避免严格路由与现有网络栈冲突。
    strict-route: false
    # 局域网 IPv4/IPv6 地址绕过 TUN，保留内网直连能力。
    route-exclude-address:
      - 10.0.0.0/8
      - 172.16.0.0/12
      - 192.168.0.0/16
      - 169.254.0.0/16
      - fc00::/7
      - fe80::/10

dns:
    enable: true
    ipv6: false
    prefer-h3: false
    use-hosts: true
    use-system-hosts: true
    respect-rules: true
    listen: '127.0.0.1:5335'

    default-nameserver:
      - 223.5.5.5
      - 119.29.29.29

    proxy-server-nameserver:
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query

    nameserver-policy:
      '+.lan': system
      '+.local': system
      # 已确认的境外域名（包括 Google/Gemini）经代理使用境外 DoH。
      'geosite:geolocation-!cn':
        - https://1.1.1.1/dns-query#PROXY
        - https://dns.google/dns-query#PROXY

    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    fake-ip-filter:
{fake_ip_filter}

    nameserver:
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query

    fallback:
      - https://1.1.1.1/dns-query
      - https://dns.google/dns-query
    fallback-lazy-query: true

    fallback-filter:
        geoip: true
        geoip-code: CN
        ipcidr:
          - 240.0.0.0/4
          - 0.0.0.0/32
          - 127.0.0.1/32
        domain:
          - '+.google.com'
          - '+.googleapis.com'
          - '+.googleapis.cn'
          - '+.gvt1.com'
          - '+.gvt2.com'
          - '+.gvt3.com'
          - '+.ggpht.com'
          - '+.xn--ngstr-lra8j.com'
          - '+.youtube.com'
          - '+.github.com'
          - '+.githubusercontent.com'
          - '+.githubassets.com'

proxies:
{proxy_nodes}

proxy-groups:
    - name: PROXY
      type: select
      proxies:
        - {proxy_names}
{rule_providers}

{rules_section}
`;

// ── 节点模板 ──────────────────────────
const CLASH_VLESS_WS_TLS_NODE_TEMPLATE = `  - name: {name}
    type: vless
    server: {host}
    port: {port}
    uuid: {uuid}
    network: ws
    tls: true
    udp: {udp}
    skip-cert-verify: false
    servername: {sni}
    client-fingerprint: {fp}
    ip-version: {ip_version}
    packet-encoding: xudp
    alpn:
      - http/1.1
    ws-opts:
      path: {path}
      headers:
        Host: {host}
{ws_early_data_config}    smux:
      enabled: false
`;

const CLASH_VLESS_XHTTP_TLS_NODE_TEMPLATE = `  - name: {name}
    type: vless
    server: {host}
    port: {port}
    uuid: {uuid}
    network: xhttp
    tls: true
    udp: {udp}
    skip-cert-verify: false
    servername: {sni}
    client-fingerprint: {fp}
    ip-version: {ip_version}
    packet-encoding: xudp
    alpn:
      - h2
    xhttp-opts:
      host: {host}
      path: {path}
      mode: {xhttp_mode}
{xhttp_extra_config}
`;

// ================= 辅助函数 =================

function getHourCount() {
    // 取当前 UTC+8 时间，计算自当年元旦 00:00 起的累计小时数
    const nowUtc8 = new Date(Date.now() + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
    const elapsedMs = nowUtc8.getTime() - yearStart;
    return Math.floor(elapsedMs / (60 * 60 * 1000));
}

function calculateDynamicPort(hourCount) {
    // 随机偏移 1~6
    return PORT_BASE + (hourCount * PORT_MULTIPLIER) + Math.floor(Math.random() * 6) + 1;
}

function encodeURIComponentCustom(str) {
    return encodeURIComponent(String(str)).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16));
}

function formatUriHost(value) {
    const host = String(value || '');
    if (!host || /[\s/?#@]/.test(host)) {
        throw new Error('Invalid node host');
    }
    if (host.startsWith('[') && host.endsWith(']')) {
        return host;
    }
    return host.includes(':') ? `[${host}]` : host;
}

function validatePort(value, field) {
    const port = Number(value);
    if (!Number.isInteger(port) || port < 1 || port > 65535) {
        throw new Error(`Invalid ${field}: ${value}`);
    }
    return port;
}

function nodeSecurity(cfg) {
    return cfg.security || 'tls';
}

function nodeNetwork(cfg) {
    return cfg.network || 'tcp';
}

function webSocketMaxEarlyData(cfg) {
    const value = Number(cfg.maxEarlyData ?? 0);
    if (!Number.isInteger(value) || value < 0 || value > 8192) {
        throw new Error(`Invalid WebSocket maxEarlyData: ${cfg.maxEarlyData}`);
    }
    return value;
}

function webSocketClientPath(cfg) {
    const path = cfg.path || '/';
    const maxEarlyData = webSocketMaxEarlyData(cfg);
    if (maxEarlyData === 0) {
        return path;
    }
    return `${path}${path.includes('?') ? '&' : '?'}ed=${maxEarlyData}`;
}

function webSocketEarlyDataConfig(cfg) {
    const maxEarlyData = webSocketMaxEarlyData(cfg);
    if (maxEarlyData === 0) {
        return '';
    }
    const headerName = yamlString(
        cfg.earlyDataHeaderName || 'Sec-WebSocket-Protocol'
    );
    return `      max-early-data: ${maxEarlyData}\n      early-data-header-name: ${headerName}\n`;
}

function xhttpExtraConfig(cfg) {
    if (cfg.mode !== 'stream-up') {
        return '';
    }
    const reuse = cfg.reuseSettings || {};
    return `      no-grpc-header: false
      uplink-http-method: POST
      reuse-settings:
        max-concurrency: ${yamlString(reuse.maxConcurrency || '8-16')}
        c-max-reuse-times: ${Number(reuse.cMaxReuseTimes ?? 0)}
        h-max-request-times: ${yamlString(reuse.hMaxRequestTimes || '600-900')}
        h-max-reusable-secs: ${yamlString(reuse.hMaxReusableSecs || '1800-3000')}
        h-keep-alive-period: ${Number(reuse.hKeepAlivePeriod ?? 60)}
`;
}

function xhttpExtraObject(cfg) {
    if (cfg.mode !== 'stream-up') {
        return null;
    }
    const reuse = cfg.reuseSettings || {};
    return {
        noGRPCHeader: false,
        uplinkMethod: 'POST',
        xmux: {
            maxConcurrency: reuse.maxConcurrency || '8-16',
            cMaxReuseTimes: Number(reuse.cMaxReuseTimes ?? 0),
            hMaxRequestTimes: reuse.hMaxRequestTimes || '600-900',
            hMaxReusableSecs: reuse.hMaxReusableSecs || '1800-3000',
            hKeepAlivePeriod: Number(reuse.hKeepAlivePeriod ?? 60),
        },
    };
}

function resolveNodePort(cfg, dynamicPort) {
    if (cfg.port !== undefined && cfg.port !== null && cfg.port !== '') {
        return validatePort(cfg.port, 'node port');
    }
    if (cfg.portMode === '443') {
        return 443;
    }
    if (cfg.portMode === 'dynamic') {
        return validatePort(dynamicPort, 'dynamic port');
    }
    if (cfg.portMode !== undefined) {
        throw new Error(`Unsupported port mode: ${cfg.portMode}`);
    }
    return nodeSecurity(cfg) === 'tls'
        ? 443
        : validatePort(dynamicPort, 'dynamic port');
}

function createVlessLink(cfg, port) {
    const security = nodeSecurity(cfg);
    const network = nodeNetwork(cfg);
    const host = formatUriHost(cfg.host);
    const sni = cfg.sni || cfg.host;
    const fp = cfg.fp || 'chrome';
    const params = new URLSearchParams({
        encryption: 'none',
        security,
        type: network,
        sni,
        fp
    });

    if (security !== 'tls') {
        throw new Error(`Unsupported VLESS security: ${security}`);
    }

    if (network === 'ws') {
        params.set('alpn', 'http/1.1');
        params.set('host', cfg.host);
        params.set('path', webSocketClientPath(cfg));
        params.set('packetEncoding', cfg.packetEncoding || 'xudp');
    } else if (network === 'xhttp') {
        params.set('alpn', 'h2');
        params.set('host', cfg.host);
        params.set('path', cfg.path || '/');
        params.set('mode', cfg.mode || 'auto');
        const extra = xhttpExtraObject(cfg);
        if (extra) {
            params.set('extra', JSON.stringify(extra));
        }
        params.set('packetEncoding', cfg.packetEncoding || 'xudp');
    } else {
        throw new Error(`Unsupported VLESS network: ${network}`);
    }

    return `vless://${cfg.uuid}@${host}:${resolveNodePort(cfg, port)}?${params.toString()}#${encodeURIComponentCustom(cfg.name)}`;
}

function createLink(cfg, port) {
    if (cfg.type === 'vless') {
        return createVlessLink(cfg, port);
    }
    throw new Error(`Unsupported node type: ${cfg.type}`);
}

function base64Encode(str) {
    const bytes = new TextEncoder().encode(str);
    let binary = '';
    const chunkSize = 8192;
    for (let i = 0; i < bytes.length; i += chunkSize) {
        binary += String.fromCharCode.apply(null, bytes.subarray(i, i + chunkSize));
    }
    return btoa(binary);
}

function normalizeSubDownloadName(value) {
    const name = String(value || DEFAULT_SUB_DOWNLOAD_NAME)
        .trim()
        .replace(/\.(ya?ml)$/i, '');
    return /^[A-Za-z0-9._-]{1,64}$/.test(name) ? name : DEFAULT_SUB_DOWNLOAD_NAME;
}

function clashDownloadFilename(env) {
    return normalizeSubDownloadName(env && env.SUB_DOWNLOAD_NAME);
}

// ================= Clash 配置生成 =================

function yamlString(value) {
    return JSON.stringify(String(value));
}

function renderClashNode(template, cfg, port) {
    const values = {
        name: yamlString(cfg.name),
        host: yamlString(cfg.host),
        port: String(resolveNodePort(cfg, port)),
        uuid: yamlString(cfg.uuid || ''),
        sni: yamlString(cfg.sni || cfg.host),
        fp: yamlString(cfg.fp || 'chrome'),
        path: yamlString(cfg.path || '/'),
        ip_version: yamlString(cfg.ipVersion || 'dual'),
        udp: String(cfg.udp !== false),
        xhttp_mode: yamlString(cfg.mode || 'auto'),
        xhttp_extra_config: xhttpExtraConfig(cfg),
        ws_early_data_config: webSocketEarlyDataConfig(cfg)
    };
    return template.replace(/{([a-z_]+)}/g, (_, key) => values[key]);
}

function generateClashProxyNode(cfg, port) {
    if (cfg.type === 'vless') {
        const security = nodeSecurity(cfg);
        const network = nodeNetwork(cfg);
        let template;
        if (security === 'tls' && network === 'ws') {
            template = CLASH_VLESS_WS_TLS_NODE_TEMPLATE;
        } else if (security === 'tls' && network === 'xhttp') {
            template = CLASH_VLESS_XHTTP_TLS_NODE_TEMPLATE;
        } else {
            throw new Error(`Unsupported VLESS mode: security=${security}, network=${network}`);
        }

        return renderClashNode(template, cfg, port);
    }

    throw new Error(`Unsupported node type: ${cfg.type}`);
}

function generateClashConfigMulti(configs, ports) {
    let proxyNodes = '';
    const proxyNames = [];

    for (let i = 0; i < configs.length; i++) {
        proxyNodes += generateClashProxyNode(configs[i], ports[i]);
        proxyNames.push(yamlString(configs[i].name));
    }

    const sections = {
        fake_ip_filter: FAKE_IP_FILTER,
        proxy_nodes: proxyNodes,
        proxy_names: proxyNames.join('\n        - '),
        rule_providers: EXTERNAL_RULE_PROVIDERS,
        rules_section: EMBEDDED_CLASH_RULES
    };
    return CLASH_CONFIG_TEMPLATE.replace(
        /{(fake_ip_filter|proxy_nodes|proxy_names|rule_providers|rules_section)}/g,
        (_, section) => sections[section]
    );
}

// ================= Workers 主入口 =================

function createResponseHeaders(extra = {}) {
    return new Headers({
        'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0',
        'Pragma': 'no-cache',
        'Expires': '0',
        'X-Content-Type-Options': 'nosniff',
        'X-Robots-Tag': 'noindex, nofollow, noarchive',
        'Referrer-Policy': 'no-referrer',
        ...extra
    });
}

function textResponse(request, body, status, extraHeaders = {}) {
    const headers = createResponseHeaders({
        'Content-Type': 'text/plain; charset=UTF-8',
        ...extraHeaders
    });
    return new Response(request.method === 'HEAD' ? null : body, { status, headers });
}

export default {
    async fetch(request, env) {
        try {
            if (request.method !== 'GET' && request.method !== 'HEAD') {
                return textResponse(request, 'Method Not Allowed', 405, { Allow: 'GET, HEAD' });
            }

            const url = new URL(request.url);
            if (url.pathname !== '/subscribe') {
                return textResponse(request, 'Not Found', 404);
            }

            const params = url.searchParams;
            const token = params.get('token');

            if (!isAllowedToken(token)) {
                return textResponse(request, '403 Forbidden', 403);
            }

            const flag = params.get('flag') || '';
            const node = params.get('node') || '';
            const headers = createResponseHeaders({
                'Content-Disposition': flag === 'clash'
                ? `attachment; filename=${clashDownloadFilename(env)}`
                : 'inline',
                'Content-Type': flag === 'clash'
                ? 'text/yaml; charset=UTF-8'
                : 'text/plain; charset=UTF-8'
            });
            if (request.method === 'HEAD') {
                return new Response(null, { headers });
            }

            const targetConfigs = node === 'all' ? CONFIGS : defaultNodeConfigs();
            const currentHourCount = getHourCount();
            const ports = targetConfigs.map((_, i) => calculateDynamicPort(currentHourCount + i));

            if (flag === 'clash') {
                const clashContent = generateClashConfigMulti(targetConfigs, ports);
                return new Response(clashContent, { headers });
            }

            const links = targetConfigs.map((cfg, i) => createLink(cfg, ports[i]));
            const content = base64Encode(links.join('\n'));
            return new Response(content, { headers });
        } catch (error) {
            console.error('Subscription generation failed', error);
            return textResponse(request, 'Internal Server Error', 500);
        }
    }
};
