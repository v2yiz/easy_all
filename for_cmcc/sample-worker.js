/**
 * 订阅服务样例 - Cloudflare Workers
 * 提供 VLESS XHTTP TLS stream-one 订阅与 Clash Meta 配置
 *
 * 使用前请替换：
 * 1. ALLOWED_TOKENS 中的订阅 token
 * 2. 节点配置中的 uuid、TLS 域名和 XHTTP path
 * 3. DEFAULT_NODE 指向唯一的 XHTTP stream-one 节点
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

// ── VLESS XHTTP TLS 节点（Cloudflare CDN / H2 stream-one）─────────
const NODE_VLESS_XHTTP_CONFIG = defineNode({
    type: 'vless',
    security: 'tls',
    network: 'xhttp',
    uuid: '00000000-0000-4000-8000-000000000002',
    host: 'xhttp.example.com',
    name: 'VLESS_XHTTP',
    fp: 'chrome',
    sni: 'xhttp.example.com',
    path: '/randompath',
    mode: 'stream-one',
    ipVersion: 'dual',
    udp: true,
    portMode: '443'
});

const DEFAULT_NODE = NODE_VLESS_XHTTP_CONFIG;

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

const FAKE_IP_FILTER = BASE_FAKE_IP_FILTER
    .map(domain => `      - '${domain}'`)
    .join('\n');

const EMBEDDED_CLASH_RULES = `rules:
  # ==================== 局域网直连 ====================
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

  # ==================== 精确代理例外 ====================
  # 必须位于 Apple、Microsoft 的直连规则之前。
  - DOMAIN-SUFFIX,apple-relay.akamaized.net,PROXY
  - DOMAIN-SUFFIX,apple-relay.apple.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.cloudflare.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.fastly-edge.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.mask.apple-dns.net,PROXY
  - DOMAIN,copilot.microsoft.com,PROXY
  - DOMAIN,copilot.bing.com,PROXY
  - DOMAIN-SUFFIX,bing.com,PROXY

  # ==================== 国内高流量服务直连 ====================
  # DOMAIN-SUFFIX 覆盖主域及其所有子域；客户端模板默认只请求 IPv4。
  # 视频 / 直播：哔哩哔哩、爱奇艺、优酷、抖音、西瓜、快手
  - DOMAIN-SUFFIX,bilibili.com,DIRECT
  - DOMAIN-SUFFIX,b23.tv,DIRECT
  - DOMAIN-SUFFIX,bilivideo.com,DIRECT
  - DOMAIN-SUFFIX,bilivideo.cn,DIRECT
  - DOMAIN-SUFFIX,hdslb.com,DIRECT
  - DOMAIN-SUFFIX,biliapi.net,DIRECT
  - DOMAIN-SUFFIX,biliapi.com,DIRECT
  - DOMAIN-SUFFIX,acgvideo.com,DIRECT
  - DOMAIN-SUFFIX,iqiyi.com,DIRECT
  - DOMAIN-SUFFIX,qiyi.com,DIRECT
  - DOMAIN-SUFFIX,qiyipic.com,DIRECT
  - DOMAIN-SUFFIX,iqiyipic.com,DIRECT
  - DOMAIN-SUFFIX,youku.com,DIRECT
  - DOMAIN-SUFFIX,ykimg.com,DIRECT
  - DOMAIN-SUFFIX,douyin.com,DIRECT
  - DOMAIN-SUFFIX,douyincdn.com,DIRECT
  - DOMAIN-SUFFIX,douyinpic.com,DIRECT
  - DOMAIN-SUFFIX,douyinstatic.com,DIRECT
  - DOMAIN-SUFFIX,byteimg.com,DIRECT
  - DOMAIN-SUFFIX,pstatp.com,DIRECT
  - DOMAIN-SUFFIX,snssdk.com,DIRECT
  - DOMAIN-SUFFIX,toutiao.com,DIRECT
  - DOMAIN-SUFFIX,ixigua.com,DIRECT
  - DOMAIN-SUFFIX,ixiguavideo.com,DIRECT
  - DOMAIN-SUFFIX,kuaishou.com,DIRECT
  - DOMAIN-SUFFIX,gifshow.com,DIRECT
  - DOMAIN-SUFFIX,ks-cdn.com,DIRECT
  - DOMAIN-SUFFIX,kwaicdn.com,DIRECT

  # 社区 / 图片：知乎、小红书、微博
  - DOMAIN-SUFFIX,zhihu.com,DIRECT
  - DOMAIN-SUFFIX,zhimg.com,DIRECT
  - DOMAIN-SUFFIX,xiaohongshu.com,DIRECT
  - DOMAIN-SUFFIX,xhscdn.com,DIRECT
  - DOMAIN-SUFFIX,xhslink.com,DIRECT
  - DOMAIN-SUFFIX,weibo.com,DIRECT
  - DOMAIN-SUFFIX,weibo.cn,DIRECT
  - DOMAIN-SUFFIX,sina.com.cn,DIRECT
  - DOMAIN-SUFFIX,sinaimg.cn,DIRECT

  # 腾讯 / 百度 / 网易及常用云 CDN
  - DOMAIN-SUFFIX,qq.com,DIRECT
  - DOMAIN-SUFFIX,gtimg.com,DIRECT
  - DOMAIN-SUFFIX,gtimg.cn,DIRECT
  - DOMAIN-SUFFIX,qpic.cn,DIRECT
  - DOMAIN-SUFFIX,qlogo.cn,DIRECT
  - DOMAIN-SUFFIX,weixin.qq.com,DIRECT
  - DOMAIN-SUFFIX,wechat.com,DIRECT
  - DOMAIN-SUFFIX,myqcloud.com,DIRECT
  - DOMAIN-SUFFIX,qcloud.com,DIRECT
  - DOMAIN-SUFFIX,baidu.com,DIRECT
  - DOMAIN-SUFFIX,bdimg.com,DIRECT
  - DOMAIN-SUFFIX,bdstatic.com,DIRECT
  - DOMAIN-SUFFIX,bcebos.com,DIRECT
  - DOMAIN-SUFFIX,163.com,DIRECT
  - DOMAIN-SUFFIX,126.com,DIRECT
  - DOMAIN-SUFFIX,126.net,DIRECT
  - DOMAIN-SUFFIX,127.net,DIRECT

  # 电商 / 本地生活及其静态资源
  - DOMAIN-SUFFIX,taobao.com,DIRECT
  - DOMAIN-SUFFIX,tmall.com,DIRECT
  - DOMAIN-SUFFIX,alibaba.com,DIRECT
  - DOMAIN-SUFFIX,alikunlun.com,DIRECT
  - DOMAIN-SUFFIX,alipay.com,DIRECT
  - DOMAIN-SUFFIX,alicdn.com,DIRECT
  - DOMAIN-SUFFIX,tbcdn.cn,DIRECT
  - DOMAIN-SUFFIX,jd.com,DIRECT
  - DOMAIN-SUFFIX,jdcdn.com,DIRECT
  - DOMAIN-SUFFIX,360buyimg.com,DIRECT
  - DOMAIN-SUFFIX,pinduoduo.com,DIRECT
  - DOMAIN-SUFFIX,yangkeduo.com,DIRECT
  - DOMAIN-SUFFIX,meituan.com,DIRECT
  - DOMAIN-SUFFIX,meituan.net,DIRECT
  - DOMAIN-SUFFIX,dianping.com,DIRECT

  # 地图 / 出行 / 办公及常用国内服务
  - DOMAIN-SUFFIX,amap.com,DIRECT
  - DOMAIN-SUFFIX,autonavi.com,DIRECT
  - DOMAIN-SUFFIX,ctrip.com,DIRECT
  - DOMAIN-SUFFIX,dingtalk.com,DIRECT
  - DOMAIN-SUFFIX,douban.com,DIRECT
  - DOMAIN-SUFFIX,doubanio.com,DIRECT
  - DOMAIN-SUFFIX,ksosoft.com,DIRECT
  - DOMAIN-SUFFIX,mi-img.com,DIRECT
  - DOMAIN-SUFFIX,miui.com,DIRECT
  - DOMAIN-SUFFIX,xiaomi.com,DIRECT

  # ==================== Apple 直连 ====================
  - DOMAIN,www-cdn.icloud.com.akadns.net,DIRECT
  - DOMAIN-SUFFIX,aaplimg.com,DIRECT
  - DOMAIN-SUFFIX,apple-cloudkit.com,DIRECT
  - DOMAIN-SUFFIX,apple.co,DIRECT
  - DOMAIN-SUFFIX,apple.com,DIRECT
  - DOMAIN-SUFFIX,apple.news,DIRECT
  - DOMAIN-SUFFIX,apple.com.cn,DIRECT
  - DOMAIN-SUFFIX,appstore.com,DIRECT
  - DOMAIN-SUFFIX,cdn-apple.com,DIRECT
  - DOMAIN-SUFFIX,icloud-content.com,DIRECT
  - DOMAIN-SUFFIX,icloud.com,DIRECT
  - DOMAIN-SUFFIX,icloud.com.cn,DIRECT
  - DOMAIN-SUFFIX,me.com,DIRECT
  - DOMAIN-SUFFIX,mzstatic.com,DIRECT
  - IP-CIDR,17.0.0.0/8,DIRECT,no-resolve
  - IP-CIDR6,2620:149::/32,DIRECT,no-resolve
  - IP-CIDR6,2403:300::/32,DIRECT,no-resolve
  - IP-CIDR6,2a01:b740::/32,DIRECT,no-resolve

  # ==================== Microsoft 精确分流 ====================
  - DOMAIN-SUFFIX,microsoft.com,DIRECT
  - DOMAIN-SUFFIX,outlook.com,DIRECT
  - DOMAIN-SUFFIX,office365.com,DIRECT
  - DOMAIN-SUFFIX,visualstudio.com,DIRECT
  - DOMAIN-SUFFIX,windows.com,DIRECT
  - DOMAIN-SUFFIX,windowsupdate.com,DIRECT
  - DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
  - DOMAIN-SUFFIX,live.com,PROXY
  - DOMAIN-SUFFIX,office.com,PROXY

  # ==================== AI 服务 ====================
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - DOMAIN-SUFFIX,sora.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,claude.com,PROXY
  - DOMAIN-SUFFIX,claudeusercontent.com,PROXY
  - DOMAIN,gemini.google.com,PROXY
  - DOMAIN,aistudio.google.com,PROXY
  - DOMAIN,ai.google.dev,PROXY
  - DOMAIN-SUFFIX,generativeai.google,PROXY
  - DOMAIN,api.statsig.com,PROXY
  - DOMAIN,browser-intake-datadoghq.com,PROXY
  - DOMAIN,chat.openai.com.cdn.cloudflare.net,PROXY
  - DOMAIN,openai-api.arkoselabs.com,PROXY
  - DOMAIN-SUFFIX,auth0.com,PROXY
  - DOMAIN-SUFFIX,challenges.cloudflare.com,PROXY
  - DOMAIN-SUFFIX,chatgpt.livekit.cloud,PROXY
  - DOMAIN-SUFFIX,client-api.arkoselabs.com,PROXY
  - DOMAIN-SUFFIX,events.statsigapi.net,PROXY
  - DOMAIN-SUFFIX,featuregates.org,PROXY
  - DOMAIN-SUFFIX,host.livekit.cloud,PROXY
  - DOMAIN-SUFFIX,intercom.io,PROXY
  - DOMAIN-SUFFIX,intercomcdn.com,PROXY
  - DOMAIN-SUFFIX,launchdarkly.com,PROXY
  - DOMAIN-SUFFIX,openaiapi-site.azureedge.net,PROXY
  - DOMAIN-SUFFIX,openaicom.imgix.net,PROXY
  - DOMAIN-SUFFIX,segment.io,PROXY
  - DOMAIN-SUFFIX,sentry.io,PROXY
  - DOMAIN-SUFFIX,turn.livekit.cloud,PROXY

  # ==================== Gemini / Google ====================
  # Gemini 依赖的 Google 域名统一进入 PROXY。
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
  - DOMAIN-SUFFIX,googleapis.cn,PROXY
  - DOMAIN-SUFFIX,googleusercontent.com,PROXY
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  # Google Play 的应用包、增量包与图片资源使用独立域名。
  - DOMAIN-SUFFIX,gvt1.com,PROXY
  - DOMAIN-SUFFIX,gvt2.com,PROXY
  - DOMAIN-SUFFIX,gvt3.com,PROXY
  - DOMAIN-SUFFIX,ggpht.com,PROXY
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,PROXY
  - DOMAIN-SUFFIX,googlevideo.com,PROXY
  - DOMAIN-SUFFIX,youtube.com,PROXY
  - DOMAIN-SUFFIX,ytimg.com,PROXY

  # ==================== GitHub ====================
  # GitHub 下载会跳转到 codeload.github.com、release-assets.githubusercontent.com
  # 或 objects.githubusercontent.com；显式代理，避免依赖 GEOSITE / MATCH 兜底。
  - DOMAIN-SUFFIX,github.com,PROXY
  - DOMAIN-SUFFIX,githubusercontent.com,PROXY
  - DOMAIN-SUFFIX,githubassets.com,PROXY
  - DOMAIN-SUFFIX,githubstatus.com,PROXY

  # ==================== LINE ====================
  - DOMAIN-SUFFIX,scdn.co,PROXY
  - DOMAIN-SUFFIX,line.naver.jp,PROXY
  - DOMAIN-SUFFIX,line.me,PROXY
  - DOMAIN-SUFFIX,line-apps.com,PROXY
  - DOMAIN-SUFFIX,line-cdn.net,PROXY
  - DOMAIN-SUFFIX,line-scdn.net,PROXY

  # ==================== Telegram ====================
  - DOMAIN-SUFFIX,t.me,PROXY
  - DOMAIN-SUFFIX,tdesktop.com,PROXY
  - DOMAIN-SUFFIX,telegra.ph,PROXY
  - DOMAIN-SUFFIX,telegram.me,PROXY
  - DOMAIN-SUFFIX,telegram.org,PROXY
  - DOMAIN-SUFFIX,telesco.pe,PROXY
  - IP-CIDR,91.105.192.0/23,PROXY,no-resolve
  - IP-CIDR,91.108.4.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.8.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.12.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.16.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.20.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.56.0/22,PROXY,no-resolve
  - IP-CIDR,109.239.140.0/24,PROXY,no-resolve
  - IP-CIDR,149.154.160.0/20,PROXY,no-resolve
  - IP-CIDR,185.76.151.0/24,PROXY,no-resolve
  - IP-CIDR6,2001:b28:f23d::/48,PROXY,no-resolve
  - IP-CIDR6,2001:b28:f23f::/48,PROXY,no-resolve
  - IP-CIDR6,2001:67c:4e8::/48,PROXY,no-resolve

  # ==================== GEOSITE / GEOIP 兜底 ====================
  # 显式域名规则先于兜底规则；不再重复加载同类远程 rule-provider。
  - GEOSITE,geolocation-!cn,PROXY
  - GEOSITE,CN,DIRECT
  - GEOSITE,private,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  # 与 xflash 保持相同优先级：仅拒绝前述规则均未命中的 UDP/443，避免误伤国内直连。
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - MATCH,PROXY
`;
// EASY_CMCC_RULES_END

const CLASH_CONFIG_TEMPLATE = `mixed-port: 1080
allow-lan: false
mode: rule
log-level: warning
ipv6: true
external-controller: '127.0.0.1:9090'
unified-delay: true
tcp-concurrent: false
profile:
    store-selected: true

sniffer:
    enable: false

tun:
    enable: true
    stack: system
    mtu: 1500
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
      - https://223.5.5.5/dns-query
      - https://dns.alidns.com/dns-query

    nameserver-policy:
      '+.lan': system
      '+.local': system

    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    fake-ip-filter:
{fake_ip_filter}

    nameserver:
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query
      - https://223.5.5.5/dns-query

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
{rules_section}
`;

// ── VLESS 节点模板 ─────────────────
function buildClashVlessXhttpTlsNodeTemplate() {
    return `  - name: {name}
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
      host: {xhttp_host}
      path: {path}
      mode: {mode}
    smux:
      enabled: false
`;
}

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

function vlessSecurity(cfg) {
    return cfg.security || 'tls';
}

function vlessNetwork(cfg) {
    return cfg.network || 'tcp';
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
    return vlessSecurity(cfg) === 'tls'
        ? 443
        : validatePort(dynamicPort, 'dynamic port');
}

function createVlessLink(cfg, port) {
    const security = vlessSecurity(cfg);
    const network = vlessNetwork(cfg);
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

    if (network === 'xhttp') {
        params.set('alpn', 'h2');
        params.set('path', cfg.path || '/');
        params.set('mode', cfg.mode || 'stream-one');
        params.set('packetEncoding', 'xudp');
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

function generateClashProxyNode(cfg, port) {
    if (cfg.type === 'vless') {
        const security = vlessSecurity(cfg);
        const network = vlessNetwork(cfg);
        let template;
        if (security === 'tls' && network === 'xhttp') {
            template = buildClashVlessXhttpTlsNodeTemplate();
        } else {
            throw new Error(`Unsupported VLESS mode: security=${security}, network=${network}`);
        }

        return template
            .replace(/{host}/g, yamlString(cfg.host))
            .replace(/{port}/g, String(resolveNodePort(cfg, port)))
            .replace(/{uuid}/g, yamlString(cfg.uuid))
            .replace(/{sni}/g, yamlString(cfg.sni || cfg.host))
            .replace(/{fp}/g, yamlString(cfg.fp || 'chrome'))
            .replace(/{path}/g, yamlString(cfg.path || '/'))
            .replace(/{mode}/g, yamlString(cfg.mode || 'stream-one'))
            .replace(/{ip_version}/g, yamlString(cfg.ipVersion || 'dual'))
            .replace(/{xhttp_host}/g, yamlString(cfg.xhttpHost || cfg.host))
            .replace(/{udp}/g, String(cfg.udp !== false))
            .replace(/{name}/g, yamlString(cfg.name));
    }

    throw new Error(`Unsupported node type: ${cfg.type}`);
}

function generateClashConfigMulti(configs, ports, rulesStr) {
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
        rules_section: rulesStr
    };
    return CLASH_CONFIG_TEMPLATE.replace(
        /{(fake_ip_filter|proxy_nodes|proxy_names|rules_section)}/g,
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
            const currentHourCount = getHourCount();

            let targetConfigs;
            if (node === 'all') {
                targetConfigs = CONFIGS;
            } else {
                targetConfigs = defaultNodeConfigs();
            }
            const ports = targetConfigs.map((_, i) => calculateDynamicPort(currentHourCount + i));

            const headers = createResponseHeaders({
                'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0',
                'Content-Disposition': flag === 'clash'
                ? `attachment; filename=${clashDownloadFilename(env)}`
                : 'inline'
            });

            if (flag === 'clash') {
                const clashContent = generateClashConfigMulti(targetConfigs, ports, EMBEDDED_CLASH_RULES);
                headers.set('Content-Type', 'text/yaml; charset=UTF-8');
                return new Response(request.method === 'HEAD' ? null : clashContent, { headers });
            }

            const links = targetConfigs.map((cfg, i) => createLink(cfg, ports[i]));
            headers.set('Content-Type', 'text/plain; charset=UTF-8');
            const content = base64Encode(links.join('\n'));
            return new Response(request.method === 'HEAD' ? null : content, { headers });
        } catch (error) {
            console.error('Subscription generation failed', error);
            return textResponse(request, 'Internal Server Error', 500);
        }
    }
};
