/**
 * 订阅服务样例 - Cloudflare Workers
 * 提供 VLESS Reality 订阅、Clash Meta 配置
 *
 * 使用前请替换：
 * 1. ALLOWED_TOKENS 中的订阅 token
 * 2. 节点配置中的 uuid、host、sni、pbk、sid
 * 3. DEFAULT_NODE 指向你希望默认输出的节点
 */
// ================= 配置常量 =================

const ALLOWED_TOKENS = {
    'REPLACE_WITH_TOKEN_1': 'user1',
    'REPLACE_WITH_TOKEN_2': 'user2'
};

const PORT_BASE = 10000;
const PORT_MULTIPLIER = 6;
const DEFAULT_SUB_DOWNLOAD_NAME = 'MY_SUB';
const CONFIGS = [];

function defineNode(config) {
    CONFIGS.push(config);
    return config;
}

// ── 节点 A ──────────────────────────────────────────────────────
const NODE_A_CONFIG = defineNode({
    type: 'vless',
    uuid: '00000000-0000-4000-8000-000000000001',
    host: 'node-a.example.com',
    name: 'NODE_A',
    fp: 'chrome',
    sni: 'www.example.com',
    pbk: 'REPLACE_WITH_REALITY_PUBLIC_KEY_A',
    sid: '0123456789abcdef'
});

// ── 节点 B ──────────────────────────────────────────────────────
const NODE_B_CONFIG = defineNode({
    type: 'vless',
    uuid: '00000000-0000-4000-8000-000000000002',
    host: 'node-b.example.com',
    name: 'NODE_B',
    fp: 'chrome',
    sni: 'www.example.com',
    pbk: 'REPLACE_WITH_REALITY_PUBLIC_KEY_B',
    sid: 'abcdef0123456789'
});

const DEFAULT_NODE = NODE_A_CONFIG; // 控制默认输出的节点

// ================= 规则与模板 =================

const FAKE_IP_FILTER = `      - '+.lan'
      - '+.local'
      - 'localhost'
      - 'time.windows.com'
      - 'time.apple.com'
      - '*.ntp.org.cn'
      - 'pool.ntp.org'`;

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

  # ==================== 国内高流量服务直连 ====================
  # DOMAIN-SUFFIX 同时覆盖域名解析得到的 IPv4（A）与 IPv6（AAAA）。
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

  # ==================== AI 服务 ====================
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,claude.com,PROXY
  - DOMAIN-SUFFIX,claudeusercontent.com,PROXY
  - DOMAIN,gemini.google.com,PROXY
  - DOMAIN,aistudio.google.com,PROXY
  - DOMAIN,ai.google.dev,PROXY
  - DOMAIN-SUFFIX,generativeai.google,PROXY

  # ==================== Apple 精确分流 ====================
  - DOMAIN-SUFFIX,apple-relay.akamaized.net,PROXY
  - DOMAIN-SUFFIX,apple-relay.apple.com,PROXY
  - DOMAIN-SUFFIX,apple-relay.cloudflare.com,PROXY
  - DOMAIN-SUFFIX,apple.com,DIRECT
  - DOMAIN-SUFFIX,apple.co,DIRECT
  - DOMAIN-SUFFIX,apple.com.cn,DIRECT
  - DOMAIN-SUFFIX,aaplimg.com,DIRECT
  - DOMAIN-SUFFIX,icloud.com,DIRECT
  - DOMAIN-SUFFIX,mzstatic.com,DIRECT

  # ==================== Microsoft 精确分流 ====================
  - DOMAIN-SUFFIX,microsoft.com,PROXY
  - DOMAIN-SUFFIX,bing.com,PROXY
  - DOMAIN-SUFFIX,live.com,PROXY
  - DOMAIN-SUFFIX,outlook.com,PROXY
  - DOMAIN-SUFFIX,office.com,PROXY
  - DOMAIN-SUFFIX,msftconnecttest.com,DIRECT
  - DOMAIN-SUFFIX,windowsupdate.com,DIRECT

  # ==================== Google / YouTube ====================
  - DOMAIN-SUFFIX,google.com,PROXY
  - DOMAIN-SUFFIX,googleapis.com,PROXY
  - DOMAIN-SUFFIX,googleusercontent.com,PROXY
  - DOMAIN-SUFFIX,gstatic.com,PROXY
  - DOMAIN-SUFFIX,googlevideo.com,PROXY
  - DOMAIN-SUFFIX,youtube.com,PROXY
  - DOMAIN-SUFFIX,ytimg.com,PROXY

  # ==================== Telegram IP 段 ====================
  - IP-CIDR,91.105.192.0/23,PROXY,no-resolve
  - IP-CIDR,91.108.4.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.8.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.12.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.16.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.20.0/22,PROXY,no-resolve
  - IP-CIDR,91.108.56.0/22,PROXY,no-resolve
  - IP-CIDR,149.154.160.0/20,PROXY,no-resolve
  - IP-CIDR,185.76.151.0/24,PROXY,no-resolve

  # ==================== GEOSITE / GEOIP 兜底 ====================
  - GEOSITE,geolocation-!cn,PROXY
  - GEOSITE,CN,DIRECT
  # GEOIP CN 数据同时匹配国内 IPv4 与 IPv6 目标地址。
  - GEOIP,CN,DIRECT,no-resolve
  - MATCH,PROXY
`;

const CLASH_CONFIG_TEMPLATE = `mixed-port: 1080
allow-lan: false
mode: rule
log-level: info
ipv6: true
external-controller: '127.0.0.1:9090'
unified-delay: true
profile:
    store-selected: true

sniffer:
    enable: true
    force-dns-mapping: true
    parse-pure-ip: true
    override-destination: true
    sniff:
      HTTP:
        ports: [80, 8080-8880]
        override-destination: true
      TLS:
        ports: [443, 8443]
      QUIC:
        ports: [443, 8443]

tun:
    enable: true
    stack: mixed
    auto-route: true
    auto-detect-interface: true
    inet4-address:
      - 198.18.0.1/30
    inet6-address:
      - fdfe:dcba:9877::1/126
    dns-hijack:
      - any:53
      - tcp://any:53
    strict-route: false
    # 如需绕过 TUN 自动路由，在这里添加：
    # route-exclude-address:
    #   - 10.0.0.0/8

dns:
    enable: true
    ipv6: true
    prefer-h3: false
    use-hosts: true
    use-system-hosts: true
    respect-rules: true
    listen: '127.0.0.1:5335'

    default-nameserver:
      - 223.5.5.5
      - 119.29.29.29
      - 8.8.8.8

    proxy-server-nameserver:
      - https://223.5.5.5/dns-query
      - https://dns.alidns.com/dns-query

    nameserver-policy:
      '+.lan': system
      '+.local': system

    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    fake-ip-range6: fdfe:dcba:9876::1/64
    fake-ip-filter:
{fake_ip_filter}

    nameserver:
      - https://dns.alidns.com/dns-query
      - https://doh.pub/dns-query
      - https://223.5.5.5/dns-query

    fallback:
      - https://1.1.1.1/dns-query
      - https://1.0.0.1/dns-query
      - https://dns.google/dns-query
      - https://cloudflare-dns.com/dns-query

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
          - '+.youtube.com'
          - '+.github.com'

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
function buildClashVlessNodeTemplate() {
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
    ip-version: ipv4-prefer
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
    return encodeURIComponent(str).replace(/[!'()*]/g, c => '%' + c.charCodeAt(0).toString(16));
}

function createLink(cfg, port) {
    const params = new URLSearchParams({
        encryption: 'none',
        security: 'reality',
        type: 'tcp',
        sni: cfg.sni,
        fp: cfg.fp,
        pbk: cfg.pbk,
        sid: cfg.sid,
        flow: 'xtls-rprx-vision',
        packetEncoding: 'xudp'
    });
    return `vless://${cfg.uuid}@${cfg.host}:${cfg.port || port}?${params.toString()}#${encodeURIComponentCustom(cfg.name)}`;
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

function generateClashProxyNode(cfg, port) {
    return buildClashVlessNodeTemplate()
        .replace(/{name}/g, cfg.name)
        .replace(/{host}/g, cfg.host)
        .replace(/{port}/g, String(cfg.port || port))
        .replace(/{uuid}/g, cfg.uuid)
        .replace(/{sni}/g, cfg.sni)
        .replace(/{pbk}/g, cfg.pbk)
        .replace(/{sid}/g, cfg.sid)
        .replace(/{fp}/g, cfg.fp);
}

function generateClashConfigMulti(configs, ports, rulesStr) {
    let proxyNodes = '';
    const proxyNames = [];

    for (let i = 0; i < configs.length; i++) {
        proxyNodes += generateClashProxyNode(configs[i], ports[i]);
        proxyNames.push(configs[i].name);
    }

    return CLASH_CONFIG_TEMPLATE
        .replace('{fake_ip_filter}', FAKE_IP_FILTER)
        .replace('{proxy_nodes}', proxyNodes)
        .replace('{proxy_names}', proxyNames.join('\n        - '))
        .replace('{rules_section}', rulesStr);
}

// ================= Workers 主入口 =================

export default {
    async fetch(request, env) {
        try {
            const url = new URL(request.url);
            if (url.pathname !== '/subscribe') {
                return new Response('Not Found', { status: 404 });
            }

            const params = url.searchParams;
            const token = params.get('token');

            if (!token || !ALLOWED_TOKENS[token]) {
                return new Response('403 Forbidden', { status: 403 });
            }

            const flag = params.get('flag') || '';
            const node = params.get('node') || '';
            const currentHourCount = getHourCount();

            let targetConfigs;
            if (node === 'all') {
                targetConfigs = CONFIGS;
            } else {
                targetConfigs = [DEFAULT_NODE];
            }
            const ports = targetConfigs.map((_, i) => calculateDynamicPort(currentHourCount + i));

            const headers = new Headers({
                'Cache-Control': 'no-store, no-cache, must-revalidate, proxy-revalidate, max-age=0',
                'Pragma': 'no-cache',
                'Expires': '0',
                'Access-Control-Allow-Origin': '*',
                'Content-Disposition': flag === 'clash'
                    ? `attachment; filename="${clashDownloadFilename(env)}"`
                    : 'inline'
            });

            if (flag === 'clash') {
                const clashContent = generateClashConfigMulti(targetConfigs, ports, EMBEDDED_CLASH_RULES);
                headers.set('Content-Type', 'text/yaml; charset=UTF-8');
                return new Response(clashContent, { headers });
            }

            const links = targetConfigs.map((cfg, i) => createLink(cfg, ports[i]));
            headers.set('Content-Type', 'text/plain; charset=UTF-8');
            return new Response(base64Encode(links.join('\n')), { headers });
        } catch (error) {
            return new Response(`Error: ${error.message}`, { status: 500 });
        }
    }
};
