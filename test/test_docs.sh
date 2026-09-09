#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
README_CONTENT=$(<"${ROOT_DIR}/README.md")
PREPARATION_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/preparation-guide.md")
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
XHTTP_CONTENT=$(<"${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh")

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    local label=$1 haystack=$2 needle=$3
    [[ "${haystack}" == *"${needle}"* ]] || fail "${label}: missing '${needle}'"
}

assert_not_contains() {
    local label=$1 haystack=$2 needle=$3
    [[ "${haystack}" != *"${needle}"* ]] || fail "${label}: unexpected '${needle}'"
}

while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    assert_contains "README runtime module list" "${README_CONTENT}" "$(basename "${relative_path}")"
done < <(
    sed -n '/readonly -a EASY_ALL_RUNTIME_MODULES=(/,/^)/p' "${ROOT_DIR}/easy_all" \
        | sed -n 's/^[[:space:]]*"\(\(lib\|profiles\)\/[^\"]*\)"/\1/p'
)

for command in show subscription self-update apply apply-cloud update-sub \
    refresh-cdn-ips update-core renew-cert quota-status quota-set quota-reset \
    status uninstall help; do
    assert_contains "README public command ${command}" "${README_CONTENT}" "| \`${command}"
done

assert_contains "README documents Reality mode" "${README_CONTENT}" '直连 Reality'
assert_contains "README documents Cloudflare mode" "${README_CONTENT}" 'Cloudflare CDN 精选 IP - XHTTP'
assert_contains "README links the preparation guide" "${README_CONTENT}" 'docs/preparation-guide.md'
assert_contains "README documents root-only Globalping token storage" \
    "${README_CONTENT}" '/etc/easy_all/globalping.token'
assert_contains "README documents subscription access-log suppression" \
    "${README_CONTENT}" '避免查询参数中的 Token 写入'
assert_contains "README documents hourly Globalping refresh" "${README_CONTENT}" '每小时'
assert_contains "README documents compatible-cache reuse" \
    "${README_CONTENT}" '与当前入口策略兼容的缓存'
assert_contains "README documents the official Cloudflare IPv4 pool" \
    "${README_CONTENT}" 'Cloudflare 官方 IPv4 CIDR'
assert_contains "README documents IPv4-only Cloudflare edge nodes" \
    "${README_CONTENT}" 'Cloudflare 客户端入口固定使用 IPv4'
assert_contains "README documents Worker script permission" \
    "${README_CONTENT}" 'Workers Scripts Write'
assert_contains "README documents the default Worker name" \
    "${README_CONTENT}" '默认 `easyall`'
assert_contains "README documents same-zone Worker fetch handling" \
    "${README_CONTENT}" '`global_fetch_strictly_public`'
assert_contains "README documents managed Worker extra nodes" \
    "${README_CONTENT}" 'WORKER_AGGREGATION_CONFIG={...}'
assert_contains "Preparation guide keeps Nginx as a private Worker source" \
    "${PREPARATION_GUIDE_CONTENT}" '`X-Easy-All-Worker-Source`'
assert_contains "README documents the Mihomo requirement for selected IPs" \
    "${README_CONTENT}" '精选 IP 订阅按 Mihomo 的配置格式和 XHTTP 能力生成'
assert_contains "README documents Shadowrocket as unverified" \
    "${README_CONTENT}" '不把 Shadowrocket 列为本项目的已验证客户端'
assert_contains "README explains the Cloudflare VPS traffic boundary" \
    "${README_CONTENT}" '用户上下行载荷之和会消耗 VPS 出站额度'
assert_contains "README distinguishes VPS, proxy entry and Google egress families" \
    "${README_CONTENT}" '“VPS 双栈”“代理节点入口地址族”和“Google 出站地址族”是三项独立能力'
assert_contains "README documents automatic Reality client dual-stack" \
    "${README_CONTENT}" '没有独立的 `dual` 选项'
assert_contains "README documents the Reality AAAA requirement" \
    "${README_CONTENT}" 'DNS only 节点域名的全部 AAAA 都指向该 VPS IPv6'
assert_contains "README keeps VPS dual-stack independent from Cloudflare IPv4 edges" \
    "${README_CONTENT}" '不影响 VPS 自身保留双栈能力'
assert_not_contains "README does not pin Google to stale IPv4-only behavior" \
    "${README_CONTENT}" '固定绑定 IPv4 出站'

assert_contains "Preparation guide has the expected title" \
    "${PREPARATION_GUIDE_CONTENT}" '# 前置准备手册'
assert_contains "Preparation guide documents the Cloudflare success marker" \
    "${PREPARATION_GUIDE_CONTENT}" 'Your domain is now protected by Cloudflare'
assert_contains "Preparation guide embeds the success screenshot" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/cloudflare/cloudflare-domain-protected.svg'
for asset in \
    docs/img/cloudflare/cloudflare-add-domain.svg \
    docs/img/cloudflare/cloudflare-api-token-easy-all.svg \
    docs/img/cloudflare/cloudflare-domain-protected.svg \
    docs/img/cloudflare/cloudflare-grpc.svg \
    docs/img/cloudflare/cloudflare-nameservers.svg \
    docs/img/spaceship/spaceship-domain-search.svg \
    docs/img/spaceship/spaceship-nameservers.svg \
    docs/img/spaceship/spaceship-signup.svg \
    docs/img/clashmi/clashmi-global-proxy.svg; do
    [[ -s "${ROOT_DIR}/${asset}" ]] || fail "Documentation asset is missing: ${asset}"
done
assert_contains "README documents Clash Mi global proxy guide" \
    "${README_CONTENT}" 'docs/img/clashmi/clashmi-global-proxy.svg'
assert_contains "README reminds Clash Mi manual PROXY selection" \
    "${README_CONTENT}" '手动勾选 `PROXY`'
NON_SVG_ASSET=$(find "${ROOT_DIR}/docs/img" -type f ! -name '*.svg' -print -quit)
[[ -z "${NON_SVG_ASSET}" ]] || fail "Non-SVG documentation asset remains: ${NON_SVG_ASSET}"
[[ ! -d "${ROOT_DIR}/docs/preparation" ]] || fail "obsolete preparation asset directory still exists"
[[ ! -d "${ROOT_DIR}/docs/cloudflare" ]] || fail "obsolete top-level Cloudflare asset directory still exists"
[[ ! -d "${ROOT_DIR}/docs/spaceship" ]] || fail "obsolete top-level Spaceship asset directory still exists"
[[ ! -d "${ROOT_DIR}/docs/guide" ]] || fail "obsolete guide directory still exists"
[[ ! -d "${ROOT_DIR}/docs/img/shadowrocket" ]] || fail "obsolete shadowrocket img directory still exists"
assert_contains "Preparation guide documents domain registration" \
    "${PREPARATION_GUIDE_CONTENT}" 'https://www.spaceship.com/'
assert_contains "Preparation guide documents Cloudflare sign-up" \
    "${PREPARATION_GUIDE_CONTENT}" 'https://dash.cloudflare.com/sign-up'
assert_contains "Preparation guide embeds the Spaceship signup illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/spaceship/spaceship-signup.svg'
assert_contains "Preparation guide embeds the Spaceship search illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/spaceship/spaceship-domain-search.svg'
assert_contains "Preparation guide embeds the Cloudflare add-domain illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/cloudflare/cloudflare-add-domain.svg'
assert_contains "Preparation guide embeds the registrar Nameservers illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/spaceship/spaceship-nameservers.svg'
assert_contains "Preparation guide embeds the Cloudflare Nameservers illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/cloudflare/cloudflare-nameservers.svg'
assert_contains "Preparation guide embeds the Cloudflare gRPC illustration" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/cloudflare/cloudflare-grpc.svg'
assert_contains "Preparation guide documents the Globalping token page" \
    "${PREPARATION_GUIDE_CONTENT}" 'https://dash.globalping.io/tokens'
assert_contains "Preparation guide documents the optimized XHTTP mode" \
    "${PREPARATION_GUIDE_CONTENT}" 'Cloudflare CDN 精选 IP XHTTP'
assert_contains "Preparation guide requires an active Zone" \
    "${PREPARATION_GUIDE_CONTENT}" '**Active**'
assert_contains "Preparation guide documents proxied A automation" \
    "${PREPARATION_GUIDE_CONTENT}" '创建唯一的 proxied `A` 记录'
assert_contains "Preparation guide documents the manual gRPC toggle" \
    "${PREPARATION_GUIDE_CONTENT}" 'Network → gRPC'
assert_contains "Preparation guide documents the Cloudflare API token walkthrough" \
    "${PREPARATION_GUIDE_CONTENT}" 'img/cloudflare/cloudflare-api-token-easy-all.svg'
[[ -s "${ROOT_DIR}/docs/img/cloudflare/cloudflare-api-token-easy-all.svg" ]] \
    || fail "Cloudflare API token walkthrough asset is missing"
assert_contains "Preparation guide documents the official IPv4 pool" \
    "${PREPARATION_GUIDE_CONTENT}" 'Cloudflare 官方 IPv4 CIDR'
assert_contains "Preparation guide documents IPv4-only Cloudflare edges" \
    "${PREPARATION_GUIDE_CONTENT}" '只筛选和下发 Cloudflare IPv4 边缘节点'
assert_contains "Preparation guide documents the Cloudflare loss threshold" \
    "${PREPARATION_GUIDE_CONTENT}" '最多允许丢 1 包（10%）'
assert_contains "Preparation guide forbids hostname fallback" \
    "${PREPARATION_GUIDE_CONTENT}" '不使用内置 Anycast IP 或域名兜底凑数'
assert_contains "Preparation guide documents the Mihomo requirement for selected IPs" \
    "${PREPARATION_GUIDE_CONTENT}" '精选 IP 订阅需要使用 Mihomo'
assert_contains "Preparation guide documents automatic VPS dual-stack detection" \
    "${PREPARATION_GUIDE_CONTENT}" '默认 IPv6 路由和可用 HTTPS'
assert_contains "Preparation guide documents Reality IPv6 firewall prerequisites" \
    "${PREPARATION_GUIDE_CONTENT}" '安全组'
assert_contains "Preparation guide preserves VPS dual-stack behavior" \
    "${PREPARATION_GUIDE_CONTENT}" 'VPS 双栈仍可用于 Reality 直连和目标站出站'
assert_contains "Preparation guide documents Shadowrocket as unverified" \
    "${PREPARATION_GUIDE_CONTENT}" 'Shadowrocket 列为已验证客户端'
assert_contains "Preparation guide explains outbound-only VPS accounting" \
    "${PREPARATION_GUIDE_CONTENT}" '仅计出站的 VPS 会把两者计入出站额度'
assert_contains "Cloudflare install interaction explains the VPS traffic boundary" \
    "${XHTTP_CONTENT}" '月度出站额度通常是可用代理载荷的主要上限'
assert_contains "Cloudflare node-domain prompt includes a concrete example" \
    "${XHTTP_CONTENT}" '客户端连接的 CDN 节点域名（例如 node.example.com）'
assert_contains "Cloudflare node-domain hint forbids pre-created DNS records" \
    "${XHTTP_CONTENT}" '不要提前创建 DNS 记录'

assert_contains "README documents merged Profile helpers" "${README_CONTENT}" 'profile-common.sh'
assert_contains "README documents merged scheduled maintenance" \
    "${README_CONTENT}" 'scheduled-maintenance.sh'
assert_contains "README dynamic ports describe NAT" "${README_CONTENT}" 'UFW 的 `before.rules` 受管 NAT 区块'
assert_contains "README dynamic ports reject per-port allows" "${README_CONTENT}" '不会生成数万条'
assert_contains "README documents the IPv4 client default" "${README_CONTENT}" '`ip-version: ipv4`'
assert_contains "README documents conditional VPS dual-stack support" \
    "${README_CONTENT}" '检测到可用公网 IPv6'
assert_contains "README documents locked Google egress selection" \
    "${README_CONTENT}" '再比较延迟中位数'
assert_contains "README documents persisted Google egress state" \
    "${README_CONTENT}" 'GOOGLE_EGRESS_RESOLVED=ipv4|ipv6'
assert_contains "README documents Chinese-only interactive prompts" \
    "${README_CONTENT}" '所有需要用户输入的交互提示仅显示中文'
assert_contains "README documents client connection racing" \
    "${README_CONTENT}" '内置 Mihomo 模板启用 `tcp-concurrent`'
assert_contains "README documents idle slow-start tuning" \
    "${README_CONTENT}" '`tcp_slow_start_after_idle`'
assert_contains "README distinguishes TCP keepalive from XHTTP keepalive" \
    "${README_CONTENT}" '不能替代 XHTTP'
assert_contains "README documents the managed ephemeral port range" "${README_CONTENT}" '`13000-60999`'
assert_contains "README documents XanMod LTS BBRv3" "${README_CONTENT}" 'XanMod LTS 内核'
assert_contains "README documents the BBRv3 reboot boundary" "${README_CONTENT}" '`BBRv3: active`'
assert_contains "README documents GeoSite refresh before reboot" \
    "${README_CONTENT}" '重启前最多用 10 分钟更新并校验 GeoSite/GeoIP'
assert_contains "README keeps the independent Debian initializer" \
    "${README_CONTENT}" '`scripts/debian-init.sh` 是独立的个人服务器初始化工具'
assert_contains "README update-sub includes Xray" "${README_CONTENT}" '同步重建本机 Xray、Nginx 和订阅文件'
assert_contains "XHTTP command message includes Xray" "${XHTTP_CONTENT}" \
    'Cloudflare Worker 订阅、Origin CA 与回源规则已更新'

for content_label in README preparation-guide launcher Cloudflare-profile XHTTP-runtime; do
    case "${content_label}" in
    README) content=${README_CONTENT} ;;
    preparation-guide) content=${PREPARATION_GUIDE_CONTENT} ;;
    launcher) content=${LAUNCHER_CONTENT} ;;
    Cloudflare-profile) content=${XHTTP_CONTENT} ;;
    XHTTP-runtime) content=$(<"${ROOT_DIR}/lib/xhttp-runtime.sh") ;;
    esac
    for legacy_term in AWS Amazon CloudFront 'Route 53' \
        'xhttp-aws' 'aws-cdn'; do
        assert_not_contains "${content_label} excludes ${legacy_term}" "${content}" "${legacy_term}"
    done
done

for removed_path in \
    docs/aws-guide.md \
    docs/aws/aws-architecture.svg \
    docs/aws/aws-cloudfront-settings.svg \
    docs/aws/aws-iam-policy.svg \
    docs/aws/aws-iam-access-key.svg \
    profiles/xhttp-aws.sh \
    profiles/xhttp-cloudflare.sh \
    profiles/singbox-cloudflare.sh \
    lib/singbox-core.sh \
    lib/cdn-traffic-guard.sh \
    docs/shadowrocket-auto-node-guide.md \
    profiles/shadowrocket-rule.js \
    test/test_shadowrocket_rule.sh \
    test/test_xhttp_aws.sh \
    test/test_cdn_traffic_guard.sh \
    test/test_xhttp_cloudflare.sh \
    test/test_singbox_cloudflare.sh; do
    [[ ! -e "${ROOT_DIR}/${removed_path}" ]] || fail "removed path still exists: ${removed_path}"
done

for forbidden_reference in \
    'AWS CDN 精选 IP' \
    'CloudFront' \
    'Route 53' \
    'docs/aws-guide.md' \
    'docs/shadowrocket-auto-node-guide.md' \
    'Shadowrocket 自动选择节点指南'; do
    assert_not_contains "README excludes ${forbidden_reference}" "${README_CONTENT}" "${forbidden_reference}"
    assert_not_contains "preparation guide excludes ${forbidden_reference}" \
        "${PREPARATION_GUIDE_CONTENT}" "${forbidden_reference}"
done

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" \
    "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" \
    "${ROOT_DIR}/lib/xhttp-runtime.sh"

printf 'ok - documentation alignment tests passed\n'
