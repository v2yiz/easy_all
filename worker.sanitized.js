/**
 * Sanitized copy of worker.js for sharing.
 * Credentials, private endpoints, and node parameters are placeholders.
 */

// module: worker-src/settings.js
const PORT_BASE = 10000;
// All Reality nodes share one port and rotate it every three hours.
const PORT_ROTATION_HOURS = 3;
const XHTTP_PORT = 443;
const SUBSCRIPTION_PATH = '/subscribe';
const DEFAULT_SUB_DOWNLOAD_NAME = 'EASY_ALL';
const WORKER_VERSION = '2026-08-28-xhttp-ipv6-prefer-v1';
const UPSTREAM_FETCH_TIMEOUT_MS = 12_000;
const UPSTREAM_GENERIC_FETCH_TIMEOUT_MS = 5_000;
const MAX_UPSTREAM_SUBSCRIPTION_SIZE = 512 * 1024;
const XFLASH_FALLBACK_CONFIG = String.raw`
mixed-port: 1080
allow-lan: false
mode: rule
log-level: info
external-controller: '127.0.0.1:9097'
unified-delay: false
profile:
    store-selected: true
tun:
    mtu: 1500
dns:
    enable: true
    use-system-hosts: false
    listen: '127.0.0.1:5335'
    enhanced-mode: fake-ip
    fake-ip-range: 198.18.0.1/16
    fake-ip-filter: ['*.lan', 'stun.*.*.*', 'stun.*.*', time.windows.com, time.nist.gov, time.apple.com, time.asia.apple.com, '*.ntp.org.cn', '*.openwrt.pool.ntp.org', time1.cloud.tencent.com, time.ustc.edu.cn, pool.ntp.org, ntp.ubuntu.com, ntp.aliyun.com, ntp1.aliyun.com, ntp2.aliyun.com, ntp3.aliyun.com, ntp4.aliyun.com, ntp5.aliyun.com, ntp6.aliyun.com, ntp7.aliyun.com, time1.aliyun.com, time2.aliyun.com, time3.aliyun.com, time4.aliyun.com, time5.aliyun.com, time6.aliyun.com, time7.aliyun.com, '*.time.edu.cn', time1.apple.com, time2.apple.com, time3.apple.com, time4.apple.com, time5.apple.com, time6.apple.com, time7.apple.com, time1.google.com, time2.google.com, time3.google.com, time4.google.com, music.163.com, '*.music.163.com', '*.126.net', musicapi.taihe.com, music.taihe.com, songsearch.kugou.com, trackercdn.kugou.com, '*.kuwo.cn', api-jooxtt.sanook.com, api.joox.com, joox.com, y.qq.com, '*.y.qq.com', streamoc.music.tc.qq.com, mobileoc.music.tc.qq.com, isure.stream.qqmusic.qq.com, dl.stream.qqmusic.qq.com, aqqmusic.tc.qq.com, amobile.music.tc.qq.com, '*.xiami.com', '*.music.migu.cn', music.migu.cn, '*.msftconnecttest.com', '*.msftncsi.com', localhost.ptlogin2.qq.com, '*.*.*.srv.nintendo.net', '*.*.stun.playstation.net', 'xbox.*.*.microsoft.com', '*.ipv6.microsoft.com', '*.*.xboxlive.com', speedtest.cros.wr.pvp.net]
    nameserver: ['https://223.6.6.6/dns-query#h3=true', 'https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query', 'https://120.53.53.53/dns-query']
    proxy-server-nameserver: ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']
proxies:
proxy-groups:
rule-providers:
    icloud: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/icloud.txt', path: ./ruleset/icloud.yaml, interval: 86400 }
    apple: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/apple.txt', path: ./ruleset/apple.yaml, interval: 86400 }
    google: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/google.txt', path: ./ruleset/google.yaml, interval: 86400 }
    proxy: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/proxy.txt', path: ./ruleset/proxy.yaml, interval: 86400 }
    direct: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/direct.txt', path: ./ruleset/direct.yaml, interval: 86400 }
    private: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/private.txt', path: ./ruleset/private.yaml, interval: 86400 }
    gfw: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/gfw.txt', path: ./ruleset/gfw.yaml, interval: 86400 }
    greatfire: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/greatfire.txt', path: ./ruleset/greatfire.yaml, interval: 86400 }
    tld-not-cn: { type: http, behavior: domain, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/tld-not-cn.txt', path: ./ruleset/tld-not-cn.yaml, interval: 86400 }
    telegramcidr: { type: http, behavior: ipcidr, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/telegramcidr.txt', path: ./ruleset/telegramcidr.yaml, interval: 86400 }
    cncidr: { type: http, behavior: ipcidr, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/cncidr.txt', path: ./ruleset/cncidr.yaml, interval: 86400 }
    lancidr: { type: http, behavior: ipcidr, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/lancidr.txt', path: ./ruleset/lancidr.yaml, interval: 86400 }
    applications: { type: http, behavior: classical, url: 'https://edgeone.gh-proxy.org/https://raw.githubusercontent.com/Loyalsoldier/clash-rules/release/applications.txt', path: ./ruleset/applications.yaml, interval: 86400 }
rules:
    - 'DOMAIN,subscription.example.invalid,DIRECT'
    - 'DOMAIN-SUFFIX,futooncdn.com,DIRECT'
    - 'PROCESS-NAME,v2ray,DIRECT'
    - 'PROCESS-NAME,xray,DIRECT'
    - 'PROCESS-NAME,naive,DIRECT'
    - 'PROCESS-NAME,trojan,DIRECT'
    - 'PROCESS-NAME,trojan-go,DIRECT'
    - 'PROCESS-NAME,ss-local,DIRECT'
    - 'PROCESS-NAME,privoxy,DIRECT'
    - 'PROCESS-NAME,leaf,DIRECT'
    - 'PROCESS-NAME,v2ray.exe,DIRECT'
    - 'PROCESS-NAME,xray.exe,DIRECT'
    - 'PROCESS-NAME,naive.exe,DIRECT'
    - 'PROCESS-NAME,trojan.exe,DIRECT'
    - 'PROCESS-NAME,trojan-go.exe,DIRECT'
    - 'PROCESS-NAME,ss-local.exe,DIRECT'
    - 'PROCESS-NAME,privoxy.exe,DIRECT'
    - 'PROCESS-NAME,leaf.exe,DIRECT'
    - 'PROCESS-NAME,Surge,DIRECT'
    - 'PROCESS-NAME,Surge 2,DIRECT'
    - 'PROCESS-NAME,Surge 3,DIRECT'
    - 'PROCESS-NAME,Surge 4,DIRECT'
    - 'PROCESS-NAME,Surge%202,DIRECT'
    - 'PROCESS-NAME,Surge%203,DIRECT'
    - 'PROCESS-NAME,Surge%204,DIRECT'
    - 'PROCESS-NAME,Thunder,DIRECT'
    - 'PROCESS-NAME,DownloadService,DIRECT'
    - 'PROCESS-NAME,qBittorrent,DIRECT'
    - 'PROCESS-NAME,Transmission,DIRECT'
    - 'PROCESS-NAME,fdm,DIRECT'
    - 'PROCESS-NAME,aria2c,DIRECT'
    - 'PROCESS-NAME,Folx,DIRECT'
    - 'PROCESS-NAME,NetTransport,DIRECT'
    - 'PROCESS-NAME,uTorrent,DIRECT'
    - 'PROCESS-NAME,WebTorrent,DIRECT'
    - 'PROCESS-NAME,aria2c.exe,DIRECT'
    - 'PROCESS-NAME,BitComet.exe,DIRECT'
    - 'PROCESS-NAME,fdm.exe,DIRECT'
    - 'PROCESS-NAME,NetTransport.exe,DIRECT'
    - 'PROCESS-NAME,qbittorrent.exe,DIRECT'
    - 'PROCESS-NAME,Thunder.exe,DIRECT'
    - 'PROCESS-NAME,ThunderVIP.exe,DIRECT'
    - 'PROCESS-NAME,transmission-daemon.exe,DIRECT'
    - 'PROCESS-NAME,transmission-qt.exe,DIRECT'
    - 'PROCESS-NAME,uTorrent.exe,DIRECT'
    - 'PROCESS-NAME,WebTorrent.exe,DIRECT'
    - 'PROCESS-NAME,aDrive.exe,DIRECT'
    - 'RULE-SET,applications,DIRECT'
    - 'DOMAIN,ssl.gstatic.com,DIRECT'
    - 'DOMAIN-SUFFIX,gstatic.com,XFLASH'
    - 'DOMAIN-SUFFIX,ipleak.net,XFLASH'
    - 'DOMAIN-SUFFIX,browserscan.net,XFLASH'
    - 'DOMAIN-SUFFIX,surfsharkdns.com,XFLASH'
    - 'DOMAIN-SUFFIX,edns.ip-api.com,XFLASH'
    - 'DOMAIN-SUFFIX,dnsleaktest.com,XFLASH'
    - 'DOMAIN-SUFFIX,dnsleak.com,XFLASH'
    - 'DOMAIN-SUFFIX,expressvpn.com,XFLASH'
    - 'DOMAIN-SUFFIX,nordvpn.com,XFLASH'
    - 'DOMAIN-SUFFIX,surfshark.com,XFLASH'
    - 'DOMAIN-SUFFIX,perfect-privacy.com,XFLASH'
    - 'DOMAIN-SUFFIX,browserleaks.com,XFLASH'
    - 'DOMAIN-SUFFIX,browserleaks.org,XFLASH'
    - 'DOMAIN-SUFFIX,browserleaks.net,XFLASH'
    - 'DOMAIN-SUFFIX,vpnunlimited.com,XFLASH'
    - 'DOMAIN-SUFFIX,whoer.net,XFLASH'
    - 'DOMAIN-SUFFIX,whrq.net,XFLASH'
    - 'DOMAIN-SUFFIX,asmr.one,XFLASH'
    - 'DOMAIN,browser-intake-datadoghq.com,XFLASH'
    - 'DOMAIN,chat.openai.com.cdn.cloudflare.net,XFLASH'
    - 'DOMAIN,openai-api.arkoselabs.com,XFLASH'
    - 'DOMAIN,openaicom-api-bdcpf8c6d2e9atf6.z01.azurefd.net,XFLASH'
    - 'DOMAIN,openaicomproductionae4b.blob.core.windows.net,XFLASH'
    - 'DOMAIN,production-openaicom-storage.azureedge.net,XFLASH'
    - 'DOMAIN,static.cloudflareinsights.com,XFLASH'
    - 'DOMAIN-SUFFIX,ai.com,XFLASH'
    - 'DOMAIN-SUFFIX,algolia.net,XFLASH'
    - 'DOMAIN-SUFFIX,api.statsig.com,XFLASH'
    - 'DOMAIN-SUFFIX,auth0.com,XFLASH'
    - 'DOMAIN-SUFFIX,chatgpt.com,XFLASH'
    - 'DOMAIN-SUFFIX,chatgpt.livekit.cloud,XFLASH'
    - 'DOMAIN-SUFFIX,client-api.arkoselabs.com,XFLASH'
    - 'DOMAIN-SUFFIX,events.statsigapi.net,XFLASH'
    - 'DOMAIN-SUFFIX,featuregates.org,XFLASH'
    - 'DOMAIN-SUFFIX,host.livekit.cloud,XFLASH'
    - 'DOMAIN-SUFFIX,identrust.com,XFLASH'
    - 'DOMAIN-SUFFIX,intercom.io,XFLASH'
    - 'DOMAIN-SUFFIX,intercomcdn.com,XFLASH'
    - 'DOMAIN-SUFFIX,launchdarkly.com,XFLASH'
    - 'DOMAIN-SUFFIX,oaistatic.com,XFLASH'
    - 'DOMAIN-SUFFIX,oaiusercontent.com,XFLASH'
    - 'DOMAIN-SUFFIX,observeit.net,XFLASH'
    - 'DOMAIN-SUFFIX,openai.com,XFLASH'
    - 'DOMAIN-SUFFIX,openaiapi-site.azureedge.net,XFLASH'
    - 'DOMAIN-SUFFIX,openaicom.imgix.net,XFLASH'
    - 'DOMAIN-SUFFIX,segment.io,XFLASH'
    - 'DOMAIN-SUFFIX,sentry.io,XFLASH'
    - 'DOMAIN-SUFFIX,stripe.com,XFLASH'
    - 'DOMAIN-SUFFIX,turn.livekit.cloud,XFLASH'
    - 'DOMAIN-SUFFIX,sora.com,XFLASH'
    - 'DOMAIN-KEYWORD,openai,XFLASH'
    - 'DOMAIN,api.msn.com,XFLASH'
    - 'DOMAIN,assets.msn.com,XFLASH'
    - 'DOMAIN,copilot.microsoft.com,XFLASH'
    - 'DOMAIN,gateway.bingviz.microsoft.net,XFLASH'
    - 'DOMAIN,gateway.bingviz.microsoftapp.net,XFLASH'
    - 'DOMAIN,in.appcenter.ms,XFLASH'
    - 'DOMAIN,location.microsoft.com,XFLASH'
    - 'DOMAIN,odc.officeapps.live.com,XFLASH'
    - 'DOMAIN,r.bing.com,XFLASH'
    - 'DOMAIN,self.events.data.microsoft.com,XFLASH'
    - 'DOMAIN,services.bingapis.com,XFLASH'
    - 'DOMAIN,sydney.bing.com,XFLASH'
    - 'DOMAIN,www.bing.com,XFLASH'
    - 'DOMAIN-SUFFIX,api.microsoftapp.net,XFLASH'
    - 'DOMAIN-SUFFIX,bing-shopping.microsoft-falcon.io,XFLASH'
    - 'DOMAIN-SUFFIX,challenges.cloudflare.com,XFLASH'
    - 'DOMAIN-SUFFIX,edgeservices.bing.com,XFLASH'
    - 'DOMAIN-SUFFIX,githubcopilot.com,XFLASH'
    - 'DOMAIN-KEYWORD,openaicom-api,XFLASH'
    - 'DOMAIN-SUFFIX,gvt2.com,XFLASH'
    - 'DOMAIN,ai.google.dev,XFLASH'
    - 'DOMAIN,alkalimakersuite-pa.clients6.google.com,XFLASH'
    - 'DOMAIN,makersuite.google.com,XFLASH'
    - 'DOMAIN-SUFFIX,bard.google.com,XFLASH'
    - 'DOMAIN-SUFFIX,deepmind.com,XFLASH'
    - 'DOMAIN-SUFFIX,deepmind.google,XFLASH'
    - 'DOMAIN-SUFFIX,gemini.google.com,XFLASH'
    - 'DOMAIN-SUFFIX,generativeai.google,XFLASH'
    - 'DOMAIN-SUFFIX,proactivebackend-pa.googleapis.com,XFLASH'
    - 'DOMAIN-SUFFIX,apis.google.com,XFLASH'
    - 'DOMAIN-KEYWORD,colab,XFLASH'
    - 'DOMAIN-KEYWORD,developerprofiles,XFLASH'
    - 'DOMAIN-KEYWORD,generativelanguage,XFLASH'
    - 'DOMAIN,cdn.usefathom.com,XFLASH'
    - 'DOMAIN-SUFFIX,anthropic.com,XFLASH'
    - 'DOMAIN-SUFFIX,claude.ai,XFLASH'
    - 'DOMAIN-SUFFIX,razie.ai,XFLASH'
    - 'DOMAIN-SUFFIX,razie.aws.intellij.net,XFLASH'
    - 'DOMAIN-SUFFIX,jetbrains.ai,XFLASH'
    - 'DOMAIN-SUFFIX,meta.com,XFLASH'
    - 'DOMAIN-SUFFIX,services.googleapis.cn,XFLASH'
    - 'DOMAIN-SUFFIX,xn--ngstr-lra8j.com,XFLASH'
    - 'DOMAIN,clash.razord.top,DIRECT'
    - 'DOMAIN,yacd.haishan.me,DIRECT'
    - 'RULE-SET,private,DIRECT'
    - 'RULE-SET,icloud,DIRECT'
    - 'RULE-SET,apple,DIRECT'
    - 'RULE-SET,google,XFLASH'
    - 'RULE-SET,gfw,XFLASH'
    - 'RULE-SET,greatfire,XFLASH'
    - 'RULE-SET,proxy,XFLASH'
    - 'RULE-SET,direct,DIRECT'
    - 'RULE-SET,tld-not-cn,XFLASH'
    - 'RULE-SET,telegramcidr,XFLASH'
    - 'RULE-SET,lancidr,DIRECT'
    - 'RULE-SET,cncidr,DIRECT'
    - 'GEOIP,LAN,DIRECT'
    - 'GEOIP,CN,DIRECT'
    - 'GEOSITE,CN,DIRECT'
    - 'GEOSITE,private,DIRECT'
    - 'AND,((NETWORK,UDP),(DST-PORT,443)),REJECT'
    - 'MATCH,XFLASH'
`;

// module: worker-src/config.local.js
// EASY_ALL_CONFIG_START
const ALLOWED_TOKENS = {
    user_01: 'REDACTED_TOKEN_01',
    user_02: 'REDACTED_TOKEN_02',
    user_03: 'REDACTED_TOKEN_03',
    user_04: 'REDACTED_TOKEN_04',
    user_05: 'REDACTED_TOKEN_05',
    user_06: 'REDACTED_TOKEN_06',
    user_07: 'REDACTED_TOKEN_07',
    user_08: 'REDACTED_TOKEN_08',
    user_09: 'REDACTED_TOKEN_09',
    user_10: 'REDACTED_TOKEN_10',
    user_11: 'REDACTED_TOKEN_11',
    user_12: 'REDACTED_TOKEN_12',
    user_13: 'REDACTED_TOKEN_13',
    user_14: 'REDACTED_TOKEN_14',
    user_15: 'REDACTED_TOKEN_15',
    user_16: 'REDACTED_TOKEN_16',
    user_17: 'REDACTED_TOKEN_17',
    user_18: 'REDACTED_TOKEN_18',
    user_19: 'REDACTED_TOKEN_19',
    user_20: 'REDACTED_TOKEN_20',
};

const UPSTREAM_SUBSCRIPTION_URL =
    'https://subscription.example.invalid/api/v1/client/REDACTED';

const VMISS_NODE =     {
        type: 'vless',
        security: 'reality',
        network: 'tcp',
        uuid: '00000000-0000-4000-8000-000000000001',
        host: 'node-1.example.invalid',
        name: 'SELF_BUILT_NODE_01',
        fp: 'chrome',
        ipVersion: 'dual',
        sni: 'sni-1.example.invalid',
        pbk: 'REDACTED_PUBLIC_KEY_01',
        sid: 'REDACTED_SHORT_ID_01',
    };

const DEFAULT_NODES = [
        {
        type: 'vless',
        security: 'reality',
        network: 'tcp',
        uuid: '00000000-0000-4000-8000-000000000002',
        host: 'node-2.example.invalid',
        name: 'SELF_BUILT_NODE_02',
        fp: 'chrome',
        ipVersion: 'dual',
        sni: 'sni-2.example.invalid',
        pbk: 'REDACTED_PUBLIC_KEY_02',
        sid: 'REDACTED_SHORT_ID_02',
    },
    {
        type: 'vless',
        security: 'tls',
        network: 'xhttp',
        uuid: '00000000-0000-4000-8000-000000000003',
        host: 'node-3.example.invalid',
        name: 'SELF_BUILT_NODE_03',
        fp: 'chrome',
        sni: 'sni-3.example.invalid',
        path: '/xhttp-redacted/',
        mode: 'stream-up',
        ipVersion: 'ipv6-prefer',
        xhttpNoGrpcHeader: false,
        xhttpUplinkHttpMethod: 'POST',
        xhttpReuseSettings: {
            maxConcurrency: '8-16',
            cMaxReuseTimes: 0,
            hMaxReusableSecs: '1800-3000',
            hKeepAlivePeriod: 0,
        },
    },
];

const ALL_NODES = [VMISS_NODE, ...DEFAULT_NODES];
const ALLOWED_TOKEN_VALUES = new Set(Object.values(ALLOWED_TOKENS));
// EASY_ALL_CONFIG_END

// module: worker-src/ports.js

function getHourCount(now = Date.now()) {
    const nowUtc8 = new Date(now + 8 * 60 * 60 * 1000);
    const yearStart = Date.UTC(nowUtc8.getUTCFullYear(), 0, 1);
    return Math.floor((nowUtc8.getTime() - yearStart) / 3_600_000);
}

function dynamicPort(rotationCount) {
    return PORT_BASE + rotationCount;
}

function nodePort({ now = Date.now } = {}) {
    const hourCount = getHourCount(now());
    const rotationCount = Math.floor(hourCount / PORT_ROTATION_HOURS);
    return dynamicPort(rotationCount);
}

function resolveNodePorts(nodes, dependencies) {
    const port = nodePort(dependencies);
    return nodes.map((node) =>
        node.security === 'reality' ? port : XHTTP_PORT
    );
}

// module: worker-src/node-subscription.js
function uriEncode(value) {
    return encodeURIComponent(String(value)).replace(
        /[!'()*]/g,
        (character) => `%${character.charCodeAt(0).toString(16)}`
    );
}

function yamlString(value) {
    return JSON.stringify(String(value));
}

const DEFAULT_XHTTP_REUSE_SETTINGS = {
    maxConcurrency: '8-16',
    cMaxReuseTimes: 0,
    hMaxReusableSecs: '1800-3000',
    hKeepAlivePeriod: 0,
};

function xhttpString(value, fallback) {
    if (typeof value === 'string' || typeof value === 'number') {
        const result = String(value).trim();
        if (result) {
            return result;
        }
    }
    return fallback;
}

function xhttpNumber(value, fallback) {
    if (typeof value === 'number' && Number.isFinite(value)) {
        return value;
    }
    if (typeof value === 'string' && value.trim()) {
        const result = Number(value);
        if (Number.isFinite(result)) {
            return result;
        }
    }
    return fallback;
}

function xhttpReuseSettings(node) {
    const candidate = node?.xhttpReuseSettings;
    const source =
        candidate && typeof candidate === 'object' && !Array.isArray(candidate)
            ? candidate
            : {};
    return {
        maxConcurrency: xhttpString(
            source.maxConcurrency,
            DEFAULT_XHTTP_REUSE_SETTINGS.maxConcurrency
        ),
        cMaxReuseTimes: Math.max(
            0,
            xhttpNumber(
                source.cMaxReuseTimes,
                DEFAULT_XHTTP_REUSE_SETTINGS.cMaxReuseTimes
            )
        ),
        hMaxReusableSecs: xhttpString(
            source.hMaxReusableSecs,
            DEFAULT_XHTTP_REUSE_SETTINGS.hMaxReusableSecs
        ),
        hKeepAlivePeriod: Math.max(
            0,
            xhttpNumber(
                source.hKeepAlivePeriod,
                DEFAULT_XHTTP_REUSE_SETTINGS.hKeepAlivePeriod
            )
        ),
    };
}

function xhttpClientPath(node) {
    const path = String(node.path || '').trim();
    if (!path.startsWith('/')) {
        throw new Error(`Invalid XHTTP path for ${node.name}`);
    }
    return `${path.replace(/\/+$/, '')}/`;
}

function xhttpExtra(node) {
    const reuse = xhttpReuseSettings(node);
    return {
        noGRPCHeader: Boolean(node?.xhttpNoGrpcHeader),
        uplinkHTTPMethod: xhttpString(node?.xhttpUplinkHttpMethod, 'POST'),
        xmux: {
            maxConcurrency: reuse.maxConcurrency,
            cMaxReuseTimes: reuse.cMaxReuseTimes,
            hMaxReusableSecs: reuse.hMaxReusableSecs,
            hKeepAlivePeriod: reuse.hKeepAlivePeriod,
        },
    };
}

function vlessLink(node, port) {
    const params = new URLSearchParams({
        encryption: 'none',
        security: node.security,
        type: node.network,
        sni: node.sni || node.host,
        fp: node.fp || 'chrome',
    });

    if (node.security === 'reality') {
        params.set('packetEncoding', 'xudp');
        params.set('flow', 'xtls-rprx-vision');
        params.set('pbk', node.pbk);
        params.set('sid', node.sid);
    } else if (node.network === 'xhttp') {
        params.set('packetEncoding', 'xudp');
        params.set('alpn', 'h2');
        params.set('host', node.host);
        params.set('path', xhttpClientPath(node));
        params.set('mode', node.mode);
        params.set('extra', JSON.stringify(xhttpExtra(node)));
    } else {
        throw new Error(`Unsupported VLESS network: ${node.network}`);
    }

    return `vless://${node.uuid}@${node.host}:${port}?${params.toString()}#${uriEncode(node.name)}`;
}

function clashRealityNode(node, port) {
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(node.host)}
    port: ${port}
    uuid: ${yamlString(node.uuid)}
    network: tcp
    tls: true
    udp: true
    skip-cert-verify: false
    flow: xtls-rprx-vision
    servername: ${yamlString(node.sni)}
    reality-opts:
      public-key: ${yamlString(node.pbk)}
      short-id: ${yamlString(node.sid)}
    client-fingerprint: ${yamlString(node.fp)}
    packet-encoding: xudp
    ip-version: ${yamlString(node.ipVersion || 'dual')}
    smux:
      enabled: false`;
}

function clashXhttpNode(node, port) {
    const reuse = xhttpReuseSettings(node);
    return `  - name: ${yamlString(node.name)}
    type: vless
    server: ${yamlString(node.host)}
    port: ${port}
    uuid: ${yamlString(node.uuid)}
    network: xhttp
    tls: true
    udp: true
    skip-cert-verify: false
    servername: ${yamlString(node.sni)}
    client-fingerprint: ${yamlString(node.fp)}
    packet-encoding: xudp
    ip-version: ${yamlString('ipv6-prefer')}
    alpn:
      - h2
    xhttp-opts:
      host: ${yamlString(node.host)}
      path: ${yamlString(xhttpClientPath(node))}
      mode: ${yamlString(node.mode)}
      no-grpc-header: ${Boolean(node?.xhttpNoGrpcHeader)}
      uplink-http-method: ${yamlString(xhttpString(node?.xhttpUplinkHttpMethod, 'POST'))}
      reuse-settings:
        max-concurrency: ${yamlString(reuse.maxConcurrency)}
        c-max-reuse-times: ${reuse.cMaxReuseTimes}
        h-max-reusable-secs: ${yamlString(reuse.hMaxReusableSecs)}
        h-keep-alive-period: ${reuse.hKeepAlivePeriod}`;
}

function clashNode(node, port) {
    if (node.security === 'reality') {
        return clashRealityNode(node, port);
    }
    if (node.network === 'xhttp') {
        return clashXhttpNode(node, port);
    }
    throw new Error(`Unsupported VLESS network: ${node.network}`);
}

function buildBase64Subscription(nodes, ports, upstreamLinks = []) {
    const localLinks = nodes.map((node, index) =>
        vlessLink(node, ports[index])
    );
    return encodeBase64Utf8(
        [...new Set([...localLinks, ...upstreamLinks])].join('\n')
    );
}

// module: worker-src/xflash-yaml.js

function nextTopLevelSection(lines, start) {
    for (let index = start; index < lines.length; index += 1) {
        if (/^[A-Za-z][A-Za-z0-9_-]*:\s*(?:#.*)?$/.test(lines[index])) {
            return index;
        }
    }
    return lines.length;
}

function parseYamlName(value) {
    const trimmed = value.trim().replace(/\s+#.*$/, '');
    if (trimmed.startsWith('"') && trimmed.endsWith('"')) {
        try {
            const parsed = JSON.parse(trimmed);
            return typeof parsed === 'string' ? parsed : null;
        } catch {
            return null;
        }
    }
    if (trimmed.startsWith("'") && trimmed.endsWith("'")) {
        return trimmed.slice(1, -1).replace(/''/g, "'");
    }
    return trimmed && !/[\u0000-\u001f\u007f]/.test(trimmed)
        ? trimmed
        : null;
}

function upstreamProxyNames(lines, start, end) {
    const names = [];
    const seen = new Set();
    for (let index = start + 1; index < end; index += 1) {
        const match =
            lines[index].match(/^\s*-\s+name:\s*(.+?)\s*$/) ||
            lines[index].match(
                /^\s*-\s*\{\s*name\s*:\s*("(?:\\.|[^"\\])*"|'(?:''|[^'])*'|[^,}]+)\s*(?:,|})/
            );
        if (!match) {
            continue;
        }
        const name = parseYamlName(match[1]);
        if (name && !seen.has(name)) {
            seen.add(name);
            names.push(name);
        }
    }
    return names;
}

function forceXhttpIpv6Prefer(lines, start, end, indent) {
    const escapedIndent = indent.replace(/ /g, '\\s');
    const itemPattern = new RegExp(`^${escapedIndent}-\\s+`);
    const starts = [];
    for (let index = start + 1; index < end; index += 1) {
        if (itemPattern.test(lines[index])) {
            starts.push(index);
        }
    }

    for (let item = starts.length - 1; item >= 0; item -= 1) {
        const itemStart = starts[item];
        const itemEnd = item + 1 < starts.length ? starts[item + 1] : end;
        const firstLine = lines[itemStart];
        if (/^\s*-\s*\{/.test(firstLine)) {
            if (!/\bnetwork\s*:\s*["']?xhttp(?:["']|\s|,|})/i.test(firstLine)) {
                continue;
            }
            if (/\bip-version\s*:/i.test(firstLine)) {
                lines[itemStart] = firstLine.replace(
                    /(\bip-version\s*:\s*)(?:"[^"]*"|'[^']*'|[^,}]+)/i,
                    '$1ipv6-prefer'
                );
            } else {
                lines[itemStart] = firstLine.replace(
                    /}\s*(#.*)?$/,
                    ', ip-version: ipv6-prefer }$1'
                );
            }
            continue;
        }

        const propertyIndent = `${indent}  `;
        const networkIndex = lines.findIndex(
            (line, index) =>
                index >= itemStart &&
                index < itemEnd &&
                line.startsWith(propertyIndent) &&
                line.slice(propertyIndent.length).match(
                    /^network\s*:\s*["']?xhttp(?:["']|\s|#|$)/i
                )
        );
        if (networkIndex < 0) {
            continue;
        }
        const ipVersionIndex = lines.findIndex(
            (line, index) =>
                index >= itemStart &&
                index < itemEnd &&
                line.startsWith(propertyIndent) &&
                /^ip-version\s*:/.test(line.slice(propertyIndent.length))
        );
        if (ipVersionIndex >= 0) {
            lines[ipVersionIndex] = `${propertyIndent}ip-version: ipv6-prefer`;
        } else {
            lines.splice(networkIndex + 1, 0, `${propertyIndent}ip-version: ipv6-prefer`);
        }
    }
}

function parseClashRules(lines, start, end) {
    const rules = [];
    for (let index = start + 1; index < end; index += 1) {
        const line = lines[index].trim();
        if (!line || line.startsWith('#')) {
            continue;
        }
        const match = line.match(/^-\s+(.+)$/);
        if (!match) {
            throw new Error('XFLASH rules are not a YAML block list');
        }
        const value = parseYamlName(match[1]);
        if (!value) {
            throw new Error('XFLASH rules contain an invalid YAML value');
        }
        rules.push(value);
    }
    return rules;
}

const TUN_ROUTE_EXCLUDE_ADDRESSES = [
    '10.0.0.0/8',
    '172.16.0.0/12',
    '192.168.0.0/16',
    '169.254.0.0/16',
    '100.64.0.0/10',
    'fc00::/7',
    'fe80::/10',
];

function upsertTunRouteExcludes(lines) {
    let tunStart = lines.findIndex((line) => /^tun:\s*(?:#.*)?$/.test(line));
    if (tunStart < 0) {
        const dnsStart = lines.findIndex((line) => /^dns:\s*(?:#.*)?$/.test(line));
        tunStart = dnsStart >= 0 ? dnsStart : 0;
        lines.splice(tunStart, 0, 'tun:');
    }

    const tunEnd = nextTopLevelSection(lines, tunStart + 1);
    const childIndent =
        lines
            .slice(tunStart + 1, tunEnd)
            .map((line) => line.match(/^(\s+)\S/))
            .find(Boolean)?.[1] || '    ';
    const routePattern = new RegExp(
        `^${childIndent.replace(/ /g, '\\s')}route-exclude-address\\s*:`
    );
    const routeStart = lines.findIndex(
        (line, index) => index > tunStart && index < tunEnd && routePattern.test(line)
    );
    const routeLines = [
        `${childIndent}route-exclude-address:`,
        ...TUN_ROUTE_EXCLUDE_ADDRESSES.map(
            (address) => `${childIndent}  - ${address}`
        ),
    ];

    if (routeStart >= 0) {
        let routeEnd = routeStart + 1;
        while (routeEnd < tunEnd) {
            const line = lines[routeEnd];
            if (!line.trim()) {
                break;
            }
            const indent = line.match(/^(\s*)/)[1].length;
            if (indent <= childIndent.length) {
                break;
            }
            routeEnd += 1;
        }
        lines.splice(routeStart, routeEnd - routeStart, ...routeLines);
        return;
    }

    let insertAt = tunEnd;
    while (insertAt > tunStart + 1 && !lines[insertAt - 1].trim()) {
        insertAt -= 1;
    }
    lines.splice(insertAt, 0, ...routeLines);
}

function mergeXflashClashConfig(
    upstream,
    nodes,
    ports,
    { includeUpstreamProxies = true } = {}
) {
    const hadTrailingNewline = upstream.endsWith('\n');
    const lines = upstream.replace(/\r\n?/g, '\n').split('\n');
    const sections = new Map();
    for (let index = 0; index < lines.length; index += 1) {
        const match = lines[index].match(
            /^([A-Za-z][A-Za-z0-9_-]*):\s*(?:#.*)?$/
        );
        if (match && !sections.has(match[1])) {
            sections.set(match[1], index);
        }
    }

    const proxiesStart = sections.get('proxies');
    const groupsStart = sections.get('proxy-groups');
    const rulesStart = sections.get('rules');
    if (
        !Number.isInteger(proxiesStart) ||
        !Number.isInteger(groupsStart) ||
        !Number.isInteger(rulesStart) ||
        !(proxiesStart < groupsStart && groupsStart < rulesStart)
    ) {
        throw new Error('XFLASH did not return a reusable Clash config');
    }

    const proxiesEnd = nextTopLevelSection(lines, proxiesStart + 1);
    const groupsEnd = nextTopLevelSection(lines, groupsStart + 1);
    const rulesEnd = nextTopLevelSection(lines, rulesStart + 1);
    const upstreamNames = includeUpstreamProxies
        ? upstreamProxyNames(lines, proxiesStart, proxiesEnd)
        : [];
    if (includeUpstreamProxies && !upstreamNames.length) {
        throw new Error('XFLASH config does not contain proxy nodes');
    }
    const firstProxy = lines
        .slice(proxiesStart + 1, proxiesEnd)
        .find((line) => /^\s+-\s+/.test(line));
    const indent = firstProxy?.match(/^(\s*)-/)?.[1] || '  ';

    const upstreamRules = parseClashRules(lines, rulesStart, rulesEnd);
    const rewrittenRules = upstreamRules.map((rule) =>
        rule.replace(/,XFLASH(?=(?:,|\s*$))/g, ',PROXY')
    );
    if (!rewrittenRules.some((rule, index) => rule !== upstreamRules[index])) {
        throw new Error('XFLASH rules do not reference the XFLASH group');
    }

    // Rebuild the whole rules section because upstream quoting and line endings
    // are not stable. One quoted scalar per line is unambiguous to Mihomo.
    lines.splice(
        rulesStart + 1,
        rulesEnd - rulesStart - 1,
        ...rewrittenRules.map((rule) => `  - ${yamlString(rule)}`)
    );

    const proxyNames = [
        ...new Set([...nodes.map((node) => node.name), ...upstreamNames]),
    ];
    const groupLines = [
        '  - name: PROXY',
        '    type: select',
        `    proxies: ${JSON.stringify(proxyNames)}`,
        '  - name: 延迟测试',
        '    type: select',
        `    proxies: ${JSON.stringify(proxyNames)}`,
        "    url: 'https://cp.cloudflare.com'",
        '    interval: 600',
        '    lazy: false',
        '    timeout: 15000',
        '    max-failed-times: 5',
        '    expected-status: 204',
    ];
    lines.splice(groupsStart + 1, groupsEnd - groupsStart - 1, ...groupLines);

    const localLines = nodes.flatMap((node, index) =>
        clashNode(node, ports[index])
            .split('\n')
            .map((line) => `${' '.repeat(indent.length - 2)}${line}`)
    );
    if (includeUpstreamProxies) {
        // A successful live fetch contributes its current XFLASH nodes.
        lines.splice(proxiesStart + 1, 0, ...localLines);
    } else {
        // The static fallback intentionally contains no XFLASH nodes. Always
        // rebuild this section from self-built nodes only.
        lines.splice(
            proxiesStart + 1,
            proxiesEnd - proxiesStart - 1,
            ...localLines
        );
    }

    forceXhttpIpv6Prefer(
        lines,
        proxiesStart,
        nextTopLevelSection(lines, proxiesStart + 1),
        indent
    );

    upsertTunRouteExcludes(lines);

    const unifiedDelay = lines.findIndex((line) =>
        /^unified-delay\s*:/.test(line)
    );
    if (unifiedDelay >= 0) {
        lines[unifiedDelay] = 'unified-delay: false';
    } else {
        lines.unshift('unified-delay: false');
    }

    const tcpConcurrent = lines.findIndex((line) =>
        /^tcp-concurrent\s*:/.test(line)
    );
    if (tcpConcurrent >= 0) {
        lines[tcpConcurrent] = 'tcp-concurrent: true';
    } else {
        lines.unshift('tcp-concurrent: true');
    }
    const ipv6 = lines.findIndex((line) => /^ipv6\s*:/.test(line));
    if (ipv6 >= 0) {
        lines[ipv6] = 'ipv6: true';
    } else {
        lines.unshift('ipv6: true');
    }
    const content = lines.join('\n');
    return hadTrailingNewline && !content.endsWith('\n')
        ? `${content}\n`
        : content;
}

function buildFallbackClashConfig(nodes, ports) {
    return mergeXflashClashConfig(
        XFLASH_FALLBACK_CONFIG,
        nodes,
        ports,
        { includeUpstreamProxies: false }
    );
}

// module: worker-src/xflash-client.js

function decodeBase64Utf8(value) {
    const normalized = String(value)
        .replace(/\s+/g, '')
        .replace(/-/g, '+')
        .replace(/_/g, '/');
    if (
        !normalized ||
        normalized.length % 4 === 1 ||
        !/^[A-Za-z0-9+/]*={0,2}$/.test(normalized)
    ) {
        return null;
    }
    try {
        const binary = atob(
            normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=')
        );
        return new TextDecoder().decode(
            Uint8Array.from(binary, (character) => character.charCodeAt(0))
        );
    } catch {
        return null;
    }
}

function encodeBase64Utf8(value) {
    const bytes = new TextEncoder().encode(String(value));
    let binary = '';
    const chunkSize = 8192;
    for (let index = 0; index < bytes.length; index += chunkSize) {
        binary += String.fromCharCode(...bytes.subarray(index, index + chunkSize));
    }
    return btoa(binary);
}

function upstreamHeaders(requestHeaders, format) {
    const clash = format === 'clash';
    const clientUserAgent = requestHeaders.get('User-Agent');
    const result = new Headers({
        Accept: clash
            ? 'text/yaml, text/plain;q=0.9, */*;q=0.8'
            : requestHeaders.get('Accept') || '*/*',
        'Accept-Language':
            requestHeaders.get('Accept-Language') || 'zh-CN,zh-Hans;q=0.9',
        'Cache-Control': 'no-cache',
        Pragma: 'no-cache',
    });
    // Forward a client UA verbatim. When the client did not send one, leave
    // the header absent instead of inventing a client identity.
    if (clientUserAgent && clientUserAgent.trim()) {
        result.set('User-Agent', clientUserAgent);
    }
    return result;
}

async function fetchXflashSubscription(
    request,
    upstreamUrl,
    {
        fetchImpl = fetch,
        timeoutMs = UPSTREAM_FETCH_TIMEOUT_MS,
        maxSize = MAX_UPSTREAM_SUBSCRIPTION_SIZE,
        format = 'clash',
    } = {}
) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), timeoutMs);
    try {
        const response = await fetchImpl(upstreamUrl, {
            headers: upstreamHeaders(request.headers, format),
            signal: controller.signal,
        });
        if (!response.ok) {
            throw new Error(`XFLASH returned HTTP ${response.status}`);
        }

        const contentLength = Number(response.headers.get('content-length'));
        if (Number.isFinite(contentLength) && contentLength > maxSize) {
            throw new Error('XFLASH subscription is too large');
        }

        const content = await response.text();
        if (content.length > maxSize) {
            throw new Error('XFLASH subscription is too large');
        }
        return content;
    } finally {
        clearTimeout(timeout);
    }
}

async function fetchXflashClashConfig(request, upstreamUrl, options = {}) {
    const content = await fetchXflashSubscription(request, upstreamUrl, {
        ...options,
        format: 'clash',
    });
    return decodeBase64Utf8(content) || content;
}

function subscriptionLinks(content) {
    const decoded = decodeBase64Utf8(content) || String(content);
    const links = decoded
        .replace(/\r\n?/g, '\n')
        .split('\n')
        .map((line) => line.trim())
        .filter((line) => /^[A-Za-z][A-Za-z0-9+.-]*:\/\//.test(line));
    if (!links.length) {
        throw new Error('XFLASH did not return a reusable URI subscription');
    }
    return links;
}

// module: worker-src/http.js

function subscriptionFormat(request, flag) {
    const explicit = String(flag || '').trim().toLowerCase();
    if (['clash', 'mihomo', 'meta', 'stash'].includes(explicit)) {
        return 'clash';
    }
    if (['shadowrocket', 'base64', 'uri', 'v2ray'].includes(explicit)) {
        return 'base64';
    }
    return /(?:clash|mihomo|stash)/i.test(
        request.headers.get('User-Agent') || ''
    )
        ? 'clash'
        : 'base64';
}

function downloadName(env) {
    const value = String(env.SUB_DOWNLOAD_NAME || DEFAULT_SUB_DOWNLOAD_NAME)
        .trim()
        .replace(/\.(?:ya?ml)$/i, '');
    return /^[A-Za-z0-9._-]{1,64}$/.test(value)
        ? value
        : DEFAULT_SUB_DOWNLOAD_NAME;
}

function subscriptionHeaders(format, env) {
    const contentType =
        format === 'clash'
            ? 'text/yaml; charset=UTF-8'
            : 'text/plain; charset=UTF-8';
    const result = new Headers({
        'Cache-Control': 'no-store, no-cache, must-revalidate, max-age=0',
        Pragma: 'no-cache',
        'Content-Type': contentType,
        'X-Content-Type-Options': 'nosniff',
        'X-Robots-Tag': 'noindex, nofollow, noarchive',
    });
    if (format === 'clash') {
        result.set(
            'Content-Disposition',
            `attachment; filename="${downloadName(env)}"`
        );
    }
    return result;
}

function workerResponse(
    request,
    body,
    status = 200,
    responseHeaders = new Headers()
) {
    responseHeaders.set('X-Easy-All-Version', WORKER_VERSION);
    return new Response(request.method === 'HEAD' ? null : body, {
        status,
        headers: responseHeaders,
    });
}

function selectedNodes(url, defaultNodes, allNodes) {
    return url.searchParams.get('node') === 'all' ? allNodes : defaultNodes;
}

function createWorkerHandler({
    allowedTokenValues,
    defaultNodes,
    allNodes,
    upstreamUrl,
    now = Date.now,
    fetchImpl = fetch,
}) {
    async function buildClashSubscription(request, nodes, ports) {
        const upstream = await fetchXflashClashConfig(request, upstreamUrl, {
            fetchImpl,
        });
        return mergeXflashClashConfig(upstream, nodes, ports);
    }

    async function buildGenericSubscription(request, nodes, ports) {
        try {
            const upstream = await fetchXflashSubscription(
                request,
                upstreamUrl,
                {
                    fetchImpl,
                    timeoutMs: UPSTREAM_GENERIC_FETCH_TIMEOUT_MS,
                    format: 'base64',
                }
            );
            const links = subscriptionLinks(upstream);
            return {
                content: buildBase64Subscription(nodes, ports, links),
                degraded: false,
            };
        } catch (error) {
            console.error('XFLASH generic subscription fetch failed', error);
            return {
                content: buildBase64Subscription(nodes, ports),
                degraded: true,
            };
        }
    }

    async function handleSubscription(request, env, url) {
        const format = subscriptionFormat(
            request,
            url.searchParams.get('flag')
        );
        const nodes = selectedNodes(url, defaultNodes, allNodes);
        const ports = resolveNodePorts(nodes, { now });
        let content;
        let degraded = false;

        if (format === 'clash') {
            try {
                content = await buildClashSubscription(
                    request,
                    nodes,
                    ports
                );
            } catch (error) {
                console.error('XFLASH subscription merge failed', error);
                content = buildFallbackClashConfig(nodes, ports);
                degraded = true;
            }
        } else {
            const generic = await buildGenericSubscription(
                request,
                nodes,
                ports
            );
            content = generic.content;
            degraded = generic.degraded;
        }

        const headers = subscriptionHeaders(format, env || {});
        if (degraded) {
            headers.set('X-Easy-All-Warning', 'xflash-unavailable-local-only');
        }
        return workerResponse(
            request,
            content,
            200,
            headers
        );
    }

    return async function handleRequest(request, env, context) {
        if (request.method !== 'GET' && request.method !== 'HEAD') {
            return workerResponse(
                request,
                'Method Not Allowed',
                405,
                new Headers({ Allow: 'GET, HEAD' })
            );
        }

        const url = new URL(request.url);
        if (url.pathname !== SUBSCRIPTION_PATH) {
            return workerResponse(request, 'Not Found', 404);
        }
        if (!allowedTokenValues.has(url.searchParams.get('token'))) {
            return workerResponse(request, 'Forbidden', 403);
        }

        return handleSubscription(request, env, url);
    };
}

// module: worker-src/index.js

const handleRequest = createWorkerHandler({
    allowedTokenValues: ALLOWED_TOKEN_VALUES,
    defaultNodes: DEFAULT_NODES,
    allNodes: ALL_NODES,
    upstreamUrl: UPSTREAM_SUBSCRIPTION_URL,
});

export default {
    fetch: handleRequest,
};
