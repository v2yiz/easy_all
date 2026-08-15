/**
 * 订阅服务样例 - Cloudflare Workers
 * 同时提供两个 Cloudflare CDN WebSocket 节点与一个直连 Mieru 节点
 *
 * 使用前请替换：
 * 1. ALLOWED_TOKENS 中的订阅 token
 * 2. 三个节点的认证信息、接入地址和 WebSocket 路径
 * 3. DEFAULT_NODE 保留三个节点，以便同一订阅同时输出
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

// ── 两个节点共用 CDN 域名，但使用独立认证与 WebSocket 路径 ────────
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
    ipVersion: 'dual',
    udp: true,
    packetEncoding: 'xudp',
    portMode: '443'
});

const NODE_TROJAN_WS_CONFIG = defineNode({
    type: 'trojan',
    security: 'tls',
    network: 'ws',
    password: 'replace-with-a-long-random-password',
    host: 'ws.example.com',
    name: 'TROJAN_WS',
    fp: 'chrome',
    sni: 'ws.example.com',
    path: '/trojan-change-me',
    ipVersion: 'dual',
    udp: true,
    portMode: '443'
});

// Mieru 不经过 Cloudflare；host 必须是 VPS 公网 IP 或独立的 DNS only / 灰云域名。
const NODE_MIERU_CONFIG = defineNode({
    type: 'mieru',
    host: '192.0.2.10',
    port: 8443,
    name: 'MIERU',
    username: 'easycmcc',
    password: 'replace-with-a-long-random-mieru-password',
    transport: 'TCP',
    multiplexing: 'MULTIPLEXING_LOW',
    handshakeMode: 'HANDSHAKE_STANDARD',
    udp: true
});

const DEFAULT_NODE = [NODE_VLESS_WS_CONFIG, NODE_TROJAN_WS_CONFIG, NODE_MIERU_CONFIG];

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

  # ==================== 行情 / 证券客户端直连 ====================
  # 这些域名同时位于 Fake-IP 豁免列表，避免专有长连接依赖虚拟地址映射。
${CN_SECURITIES_DIRECT_RULES}

  # ==================== 精确代理例外 ====================
  # 必须位于 Apple、Microsoft 的直连规则之前。
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

  # ==================== 出口 / DNS 隐私检测 ====================
  # 检测站必须始终观察代理出口，不能被远程 DIRECT 规则抢先命中。
  - DOMAIN-SUFFIX,ipleak.net,PROXY
  - DOMAIN-SUFFIX,browserscan.net,PROXY
  - DOMAIN-SUFFIX,surfsharkdns.com,PROXY
  - DOMAIN-SUFFIX,edns.ip-api.com,PROXY
  - DOMAIN-SUFFIX,dnsleaktest.com,PROXY
  - DOMAIN-SUFFIX,dnsleak.com,PROXY
  - DOMAIN-SUFFIX,browserleaks.com,PROXY
  - DOMAIN-SUFFIX,browserleaks.org,PROXY
  - DOMAIN-SUFFIX,browserleaks.net,PROXY
  - DOMAIN-SUFFIX,expressvpn.com,PROXY
  - DOMAIN-SUFFIX,nordvpn.com,PROXY
  - DOMAIN-SUFFIX,surfshark.com,PROXY
  - DOMAIN-SUFFIX,perfect-privacy.com,PROXY
  - DOMAIN-SUFFIX,vpnunlimited.com,PROXY
  - DOMAIN-SUFFIX,whoer.net,PROXY
  - DOMAIN-SUFFIX,whrq.net,PROXY

  # ==================== AI 服务 ====================
  - DOMAIN-SUFFIX,ai.com,PROXY
  - DOMAIN-SUFFIX,algolia.net,PROXY
  - DOMAIN-SUFFIX,chatgpt.com,PROXY
  - DOMAIN-SUFFIX,openai.com,PROXY
  - DOMAIN-SUFFIX,oaistatic.com,PROXY
  - DOMAIN-SUFFIX,oaiusercontent.com,PROXY
  - DOMAIN-SUFFIX,sora.com,PROXY
  - DOMAIN-SUFFIX,anthropic.com,PROXY
  - DOMAIN-SUFFIX,claude.ai,PROXY
  - DOMAIN-SUFFIX,claude.com,PROXY
  - DOMAIN-SUFFIX,claudeusercontent.com,PROXY
  - DOMAIN-SUFFIX,jetbrains.ai,PROXY
  - DOMAIN-SUFFIX,razie.ai,PROXY
  - DOMAIN-SUFFIX,razie.aws.intellij.net,PROXY
  - DOMAIN-SUFFIX,meta.com,PROXY
  - DOMAIN,gemini.google.com,PROXY
  - DOMAIN,aistudio.google.com,PROXY
  - DOMAIN,ai.google.dev,PROXY
  - DOMAIN-SUFFIX,generativeai.google,PROXY
  - DOMAIN,api.statsig.com,PROXY
  - DOMAIN,browser-intake-datadoghq.com,PROXY
  - DOMAIN,chat.openai.com.cdn.cloudflare.net,PROXY
  - DOMAIN,openai-api.arkoselabs.com,PROXY
  - DOMAIN,openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net,PROXY
  - DOMAIN,openaicomproductionae4b.blob.core.windows.net,PROXY
  - DOMAIN,production-openaicom-storage.azureedge.net,PROXY
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
  - DOMAIN-SUFFIX,observeit.net,PROXY
  - DOMAIN-SUFFIX,openaiapi-site.azureedge.net,PROXY
  - DOMAIN-SUFFIX,openaicom.imgix.net,PROXY
  - DOMAIN-SUFFIX,segment.io,PROXY
  - DOMAIN-SUFFIX,sentry.io,PROXY
  - DOMAIN-SUFFIX,stripe.com,PROXY
  - DOMAIN-SUFFIX,turn.livekit.cloud,PROXY

  # ==================== Gemini / Google ====================
  # Gemini 依赖的 Google 域名统一进入 PROXY。
  # WebSocket 公网链路固定为 HTTP/1.1/TCP；先拒绝 YouTube QUIC，让浏览器回退到 TCP，
  # 避免把 QUIC/UDP 经代理封装进 TCP 后产生嵌套重传和队头阻塞。
  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,googlevideo.com)),REJECT
  - AND,((NETWORK,UDP),(DST-PORT,443),(DOMAIN-SUFFIX,youtube.com)),REJECT
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

  # ==================== 外部规则集 ====================
  # 精确与高频规则优先；官方远程规则补齐长尾，IP 规则禁止额外 DNS 解析。
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

  # ==================== GEOSITE / GEOIP 兜底 ====================
  # 客户端内置数据用于远程规则首次下载失败或缓存不可用时的离线兜底。
  - GEOSITE,geolocation-!cn,PROXY
  - GEOSITE,CN,DIRECT
  - GEOSITE,private,DIRECT
  - GEOIP,CN,DIRECT,no-resolve
  # 仅拒绝前述规则均未命中的其他 UDP/443，避免误伤国内直连。
  - AND,((NETWORK,UDP),(DST-PORT,443)),REJECT
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
{rule_providers}

{rules_section}
`;

// ── WebSocket 节点模板 ─────────────────
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
    smux:
      enabled: false
`;

const CLASH_TROJAN_WS_TLS_NODE_TEMPLATE = `  - name: {name}
    type: trojan
    server: {host}
    port: {port}
    password: {password}
    network: ws
    tls: true
    udp: {udp}
    skip-cert-verify: false
    sni: {sni}
    client-fingerprint: {fp}
    ip-version: {ip_version}
    alpn:
      - http/1.1
    ws-opts:
      path: {path}
      headers:
        Host: {host}
    smux:
      enabled: false
`;

const CLASH_MIERU_NODE_TEMPLATE = `  - name: {name}
    type: mieru
    server: {host}
    port: {port}
    transport: {transport}
    udp: {udp}
    username: {username}
    password: {password}
    multiplexing: {multiplexing}
    handshake-mode: {handshake_mode}
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
        params.set('path', cfg.path || '/');
        params.set('packetEncoding', cfg.packetEncoding || 'xudp');
    } else {
        throw new Error(`Unsupported VLESS network: ${network}`);
    }

    return `vless://${cfg.uuid}@${host}:${resolveNodePort(cfg, port)}?${params.toString()}#${encodeURIComponentCustom(cfg.name)}`;
}

function createTrojanLink(cfg, port) {
    const security = nodeSecurity(cfg);
    const network = nodeNetwork(cfg);
    if (security !== 'tls' || network !== 'ws') {
        throw new Error(`Unsupported Trojan mode: security=${security}, network=${network}`);
    }
    const host = formatUriHost(cfg.host);
    const params = new URLSearchParams({
        security: 'tls',
        type: 'ws',
        sni: cfg.sni || cfg.host,
        fp: cfg.fp || 'chrome',
        alpn: 'http/1.1',
        host: cfg.host,
        path: cfg.path || '/'
    });
    return `trojan://${encodeURIComponentCustom(cfg.password)}@${host}:${resolveNodePort(cfg, port)}?${params.toString()}#${encodeURIComponentCustom(cfg.name)}`;
}

function createMieruLink(cfg, port) {
    const host = formatUriHost(cfg.host);
    const transport = cfg.transport || 'TCP';
    const multiplexing = cfg.multiplexing || 'MULTIPLEXING_LOW';
    const handshakeMode = cfg.handshakeMode || 'HANDSHAKE_STANDARD';
    if (transport !== 'TCP' && transport !== 'UDP') {
        throw new Error(`Unsupported Mieru transport: ${transport}`);
    }
    const params = new URLSearchParams({
        profile: cfg.name || 'MIERU',
        port: String(resolveNodePort(cfg, port)),
        protocol: transport,
        multiplexing,
        'handshake-mode': handshakeMode
    });
    return `mierus://${encodeURIComponentCustom(cfg.username)}:${encodeURIComponentCustom(cfg.password)}@${host}?${params.toString()}`;
}

function createLink(cfg, port) {
    if (cfg.type === 'vless') {
        return createVlessLink(cfg, port);
    }
    if (cfg.type === 'trojan') {
        return createTrojanLink(cfg, port);
    }
    if (cfg.type === 'mieru') {
        return createMieruLink(cfg, port);
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
        password: yamlString(cfg.password || ''),
        username: yamlString(cfg.username || ''),
        sni: yamlString(cfg.sni || cfg.host),
        fp: yamlString(cfg.fp || 'chrome'),
        path: yamlString(cfg.path || '/'),
        ip_version: yamlString(cfg.ipVersion || 'dual'),
        udp: String(cfg.udp !== false),
        transport: String(cfg.transport || 'TCP'),
        multiplexing: String(cfg.multiplexing || 'MULTIPLEXING_LOW'),
        handshake_mode: String(cfg.handshakeMode || 'HANDSHAKE_STANDARD')
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
        } else {
            throw new Error(`Unsupported VLESS mode: security=${security}, network=${network}`);
        }

        return renderClashNode(template, cfg, port);
    }

    if (cfg.type === 'trojan') {
        const security = nodeSecurity(cfg);
        const network = nodeNetwork(cfg);
        if (security !== 'tls' || network !== 'ws') {
            throw new Error(`Unsupported Trojan mode: security=${security}, network=${network}`);
        }
        return renderClashNode(CLASH_TROJAN_WS_TLS_NODE_TEMPLATE, cfg, port);
    }

    if (cfg.type === 'mieru') {
        return renderClashNode(CLASH_MIERU_NODE_TEMPLATE, cfg, port);
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
