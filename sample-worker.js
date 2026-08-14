/**
 * 订阅服务样例 - Cloudflare Workers
 * 提供 VLESS Reality / AnyTLS 订阅与 Clash Meta 配置
 *
 * 使用前请替换：
 * 1. ALLOWED_TOKENS 中的订阅 token
 * 2. 节点配置中的 uuid、host、sni、pbk、sid 或 AnyTLS 密码
 * 3. DEFAULT_NODE 指向你希望默认输出的节点，支持单节点或节点数组
 */
// ================= 配置常量 =================

// EASY_ALL_CONFIG_START
const ALLOWED_TOKENS = {
    user1: 'REPLACE_WITH_TOKEN_1',
    user2: 'REPLACE_WITH_TOKEN_2'
};
const ALLOWED_TOKEN_VALUES = new Set(Object.values(ALLOWED_TOKENS));

const PORT_BASE = 10000;
const PORT_MULTIPLIER = 6;
const DEFAULT_SUB_DOWNLOAD_NAME = 'EASY_ALL';
const CONFIGS = [];

function defineNode(config) {
    CONFIGS.push(config);
    return config;
}

function isAllowedToken(token) {
    return Boolean(token && ALLOWED_TOKEN_VALUES.has(token));
}

// ── Reality 节点 ───────────────────────────────────────────────
const NODE_REALITY_CONFIG = defineNode({
    type: 'vless',
    security: 'reality',
    uuid: '00000000-0000-4000-8000-000000000001',
    host: 'reality.example.com',
    name: 'NODE_REALITY',
    fp: 'chrome',
    sni: 'www.example.com',
    pbk: 'REPLACE_WITH_REALITY_PUBLIC_KEY',
    sid: '0123456789abcdef',
    portMode: '443'
});

// ── AnyTLS 节点，默认使用 dynamic 订阅端口 ────────────────────────
const NODE_ANYTLS_CONFIG = defineNode({
    type: 'anytls',
    host: 'anytls.example.com',
    name: 'NODE_ANYTLS',
    password: 'REPLACE_WITH_ANYTLS_PASSWORD',
    sni: 'anytls.example.com',
    fp: 'chrome',
    udp: true,
    insecure: false,
    portMode: 'dynamic'
});

const DEFAULT_NODE = NODE_REALITY_CONFIG; // 控制默认输出的节点，支持 [NODE_REALITY_CONFIG, NODE_ANYTLS_CONFIG]

function defaultNodeConfigs() {
    return Array.isArray(DEFAULT_NODE) ? DEFAULT_NODE : [DEFAULT_NODE];
}
// EASY_ALL_CONFIG_END

// ================= 规则与模板 =================

// EASY_ALL_RULES_START
// 服务端为 Gemini 及其必要 Google 依赖固定同一出口族；其他 AI 服务保持默认双栈行为。
const GEMINI_DOMAIN_SUFFIXES = Object.freeze(
/* EASY_ALL_GEMINI_DOMAINS_START */
[
    "ai.google.dev",
    "generativeai.google",
    "google.com",
    "googleapis.com",
    "googleusercontent.com",
    "gstatic.com",
    "ggpht.com"
]
/* EASY_ALL_GEMINI_DOMAINS_END */
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
]);

const FAKE_IP_FILTER = [...BASE_FAKE_IP_FILTER,
    ...CN_SECURITIES_DOMAIN_SUFFIXES.map(domain => `+.${domain}`),
]
    .map(domain => `      - '${domain}'`)
    .join('\n');

const CN_SECURITIES_DIRECT_RULES = CN_SECURITIES_DOMAIN_SUFFIXES
    .map(domain => `  - DOMAIN-SUFFIX,${domain},DIRECT`)
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

  # ==================== 行情 / 证券客户端直连 ====================
  # 这些域名同时位于 Fake-IP 豁免列表，避免专有长连接依赖虚拟地址映射。
${CN_SECURITIES_DIRECT_RULES}

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
  - DOMAIN-SUFFIX,chatgpt.com,AI
  - DOMAIN-SUFFIX,openai.com,AI
  - DOMAIN-SUFFIX,oaistatic.com,AI
  - DOMAIN-SUFFIX,oaiusercontent.com,AI
  - DOMAIN-SUFFIX,sora.com,AI
  - DOMAIN-SUFFIX,anthropic.com,AI
  - DOMAIN-SUFFIX,claude.ai,AI
  - DOMAIN-SUFFIX,claude.com,AI
  - DOMAIN-SUFFIX,claudeusercontent.com,AI
  - DOMAIN,gemini.google.com,AI_GEMINI
  - DOMAIN,aistudio.google.com,AI_GEMINI
  - DOMAIN,ai.google.dev,AI_GEMINI
  - DOMAIN-SUFFIX,generativeai.google,AI_GEMINI
  - DOMAIN,api.statsig.com,AI
  - DOMAIN,browser-intake-datadoghq.com,AI
  - DOMAIN,chat.openai.com.cdn.cloudflare.net,AI
  - DOMAIN,openai-api.arkoselabs.com,AI
  - DOMAIN-SUFFIX,auth0.com,AI
  - DOMAIN-SUFFIX,challenges.cloudflare.com,AI
  - DOMAIN-SUFFIX,chatgpt.livekit.cloud,AI
  - DOMAIN-SUFFIX,client-api.arkoselabs.com,AI
  - DOMAIN-SUFFIX,events.statsigapi.net,AI
  - DOMAIN-SUFFIX,featuregates.org,AI
  - DOMAIN-SUFFIX,host.livekit.cloud,AI
  - DOMAIN-SUFFIX,intercom.io,AI
  - DOMAIN-SUFFIX,intercomcdn.com,AI
  - DOMAIN-SUFFIX,launchdarkly.com,AI
  - DOMAIN-SUFFIX,openaiapi-site.azureedge.net,AI
  - DOMAIN-SUFFIX,openaicom.imgix.net,AI
  - DOMAIN-SUFFIX,segment.io,AI
  - DOMAIN-SUFFIX,sentry.io,AI
  - DOMAIN-SUFFIX,turn.livekit.cloud,AI

  # ==================== Gemini / Google ====================
  # Gemini 依赖的 Google 域名统一进入 AI_GEMINI，生成订阅时归并到 PROXY。
  - DOMAIN-SUFFIX,google.com,AI_GEMINI
  - DOMAIN-SUFFIX,googleapis.com,AI_GEMINI
  - DOMAIN-SUFFIX,googleapis.cn,AI_GEMINI
  - DOMAIN-SUFFIX,googleusercontent.com,AI_GEMINI
  - DOMAIN-SUFFIX,gstatic.com,AI_GEMINI
  # Google Play 的应用包、增量包与图片资源使用独立域名。
  - DOMAIN-SUFFIX,gvt1.com,AI_GEMINI
  - DOMAIN-SUFFIX,gvt2.com,AI_GEMINI
  - DOMAIN-SUFFIX,gvt3.com,AI_GEMINI
  - DOMAIN-SUFFIX,ggpht.com,AI_GEMINI
  - DOMAIN-SUFFIX,xn--ngstr-lra8j.com,AI_GEMINI
  - DOMAIN-SUFFIX,googlevideo.com,AI_GEMINI
  - DOMAIN-SUFFIX,youtube.com,AI_GEMINI
  - DOMAIN-SUFFIX,ytimg.com,AI_GEMINI

  # ==================== GitHub ====================
  # GitHub 下载会跳转到 codeload.github.com、release-assets.githubusercontent.com
  # 或 objects.githubusercontent.com；显式代理，避免依赖 GEOSITE / MATCH 兜底。
  - DOMAIN-SUFFIX,github.com,DOWNLOAD
  - DOMAIN-SUFFIX,githubusercontent.com,DOWNLOAD
  - DOMAIN-SUFFIX,githubassets.com,DOWNLOAD
  - DOMAIN-SUFFIX,githubstatus.com,DOWNLOAD

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
  # 仅拒绝前述规则均未命中的 UDP/443，避免误伤国内直连。
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
  - MATCH,PROXY
`;
// EASY_ALL_RULES_END

const CLASH_CONFIG_TEMPLATE = `mixed-port: 1080
allow-lan: false
mode: rule
log-level: error
ipv6: false
external-controller: '127.0.0.1:9090'
unified-delay: true
find-process-mode: off
profile:
    store-selected: true

sniffer:
    enable: true
    force-dns-mapping: true
    parse-pure-ip: true
    # 嗅探结果只用于域名分流；不覆写 Fake-IP 映射或原始目标。
    override-destination: false
    sniff:
      HTTP:
        ports: [80, 8080-8880]
        override-destination: false
      TLS:
        ports: [443, 8443]
      QUIC:
        ports: [443, 8443]

tun:
    enable: true
    stack: mixed
    mtu: 1500
    auto-route: true
    auto-detect-interface: true
    inet4-address:
      - 198.18.0.1/30
    dns-hijack:
      - any:53
      - tcp://any:53
    # Windows TUN + Reality/BWG 使用兼容模式，避免严格路由与现有网络栈冲突。
    strict-route: false
    # 通用局域网 IPv4/IPv6 地址绕过 TUN，保留内网直连能力。
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
    - name: AUTO
      type: url-test
      url: 'https://www.gstatic.com/generate_204'
      interval: 300
      lazy: true
      proxies:
        - {proxy_names}

    - name: PROXY
      type: select
      proxies:
        - AUTO
        - {proxy_names}

{rules_section}
`;

// ── VLESS 节点模板 ─────────────────
function buildClashVlessRealityNodeTemplate() {
    return `  - name: {name}
    type: vless
    server: {host}
    port: {port}
    uuid: {uuid}
    network: tcp
    tls: true
    udp: true
    skip-cert-verify: false
    flow: xtls-rprx-vision
    servername: {sni}
    reality-opts:
      public-key: {pbk}
      short-id: {sid}
    client-fingerprint: {fp}
    packet-encoding: xudp
    smux:
      enabled: false
`;
}

function buildClashVlessTlsVisionNodeTemplate() {
    return `  - name: {name}
    type: vless
    server: {host}
    port: {port}
    uuid: {uuid}
    network: tcp
    tls: true
    udp: true
    skip-cert-verify: false
    flow: xtls-rprx-vision
    servername: {sni}
    client-fingerprint: {fp}
    packet-encoding: xudp
    smux:
      enabled: false
`;
}

// ── AnyTLS 节点模板 ─────────────────
function buildClashAnyTlsNodeTemplate() {
    return `  - name: {name}
    type: anytls
    server: {host}
    port: {port}
    password: {password}
    client-fingerprint: {fp}
    udp: {udp}
    sni: {sni}
    skip-cert-verify: {skip_cert_verify}
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
    return cfg.security || 'reality';
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
    if (cfg.type === 'anytls') {
        return validatePort(dynamicPort, 'dynamic port');
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

    if (security === 'reality') {
        if (network !== 'tcp') {
            throw new Error(`Unsupported VLESS Reality network: ${network}`);
        }
        params.set('pbk', cfg.pbk);
        params.set('sid', cfg.sid);
        params.set('flow', 'xtls-rprx-vision');
        params.set('packetEncoding', 'xudp');
    } else if (security !== 'tls') {
        throw new Error(`Unsupported VLESS security: ${security}`);
    }

    if (security === 'tls' && network === 'tcp') {
        params.set('flow', 'xtls-rprx-vision');
        params.set('packetEncoding', 'xudp');
    } else if (network !== 'tcp') {
        throw new Error(`Unsupported VLESS network: ${network}`);
    }

    return `vless://${cfg.uuid}@${host}:${resolveNodePort(cfg, port)}?${params.toString()}#${encodeURIComponentCustom(cfg.name)}`;
}

function createAnyTlsLink(cfg, port) {
    const params = new URLSearchParams({
        sni: cfg.sni || cfg.host,
        insecure: cfg.insecure ? '1' : '0'
    });
    const password = encodeURIComponentCustom(cfg.password);
    const name = encodeURIComponentCustom(cfg.name);
    return `anytls://${password}@${formatUriHost(cfg.host)}:${resolveNodePort(cfg, port)}/?${params.toString()}#${name}`;
}

function createLink(cfg, port) {
    if (cfg.type === 'vless') {
        return createVlessLink(cfg, port);
    }
    if (cfg.type === 'anytls') {
        return createAnyTlsLink(cfg, port);
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
        if (security === 'reality') {
            if (network !== 'tcp') {
                throw new Error(`Unsupported VLESS Reality network: ${network}`);
            }
            template = buildClashVlessRealityNodeTemplate();
        } else if (security === 'tls' && network === 'tcp') {
            template = buildClashVlessTlsVisionNodeTemplate();
        } else {
            throw new Error(`Unsupported VLESS mode: security=${security}, network=${network}`);
        }

        return template
            .replace(/{host}/g, yamlString(cfg.host))
            .replace(/{port}/g, String(resolveNodePort(cfg, port)))
            .replace(/{uuid}/g, yamlString(cfg.uuid))
            .replace(/{sni}/g, yamlString(cfg.sni || cfg.host))
            .replace(/{pbk}/g, yamlString(cfg.pbk || ''))
            .replace(/{sid}/g, yamlString(cfg.sid || ''))
            .replace(/{fp}/g, yamlString(cfg.fp || 'chrome'))
            .replace(/{udp}/g, String(cfg.udp !== false))
            .replace(/{name}/g, yamlString(cfg.name));
    }

    if (cfg.type === 'anytls') {
        return buildClashAnyTlsNodeTemplate()
            .replace(/{host}/g, yamlString(cfg.host))
            .replace(/{port}/g, String(resolveNodePort(cfg, port)))
            .replace(/{password}/g, yamlString(cfg.password))
            .replace(/{fp}/g, yamlString(cfg.fp || 'chrome'))
            .replace(/{udp}/g, String(cfg.udp !== false))
            .replace(/{sni}/g, yamlString(cfg.sni || cfg.host))
            .replace(/{skip_cert_verify}/g, String(Boolean(cfg.insecure)))
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
        rules_section: rulesStr.replaceAll(/\b(?:AI_GEMINI|DOWNLOAD|AI)\b/g, 'PROXY')
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
