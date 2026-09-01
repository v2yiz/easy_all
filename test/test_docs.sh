#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
README_CONTENT=$(<"${ROOT_DIR}/README.md")
PREPARATION_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/preparation-guide.md")
SHADOWROCKET_GUIDE_CONTENT=$(<"${ROOT_DIR}/docs/shadowrocket-auto-node-guide.md")
LAUNCHER_CONTENT=$(<"${ROOT_DIR}/easy_all")
XHTTP_CONTENT=$(<"${ROOT_DIR}/profiles/xhttp-cloudflare.sh")

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
assert_contains "README documents hourly Globalping refresh" "${README_CONTENT}" '每小时'
assert_contains "README documents the 72-hour Globalping fallback" "${README_CONTENT}" '超过 72 小时'
assert_contains "README documents the official Cloudflare IPv4 pool" \
    "${README_CONTENT}" 'Cloudflare 官方 IPv4 CIDR'
assert_contains "README documents the Mihomo requirement for selected IPs" \
    "${README_CONTENT}" '精选 IP 订阅按 Mihomo 的配置格式和 XHTTP 能力生成'
assert_contains "README documents Shadowrocket as unverified" \
    "${README_CONTENT}" '不把 Shadowrocket 列为本项目的已验证客户端'
assert_contains "README links the Shadowrocket auto-node guide" \
    "${README_CONTENT}" 'docs/shadowrocket-auto-node-guide.md'

assert_contains "Shadowrocket guide has the expected title" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '# Shadowrocket AUTO 自动选节点指南'
assert_contains "Shadowrocket guide explains the separate node subscription" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '自己的节点订阅绑定到该分组'
assert_contains "Shadowrocket guide documents the AUTO interval" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '`300` 秒'
assert_contains "Shadowrocket guide documents Config routing mode" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '全局路由**，选择 **配置**'
assert_contains "Shadowrocket guide documents subscription DNS override" \
    "${SHADOWROCKET_GUIDE_CONTENT}" 'https://dns.alidns.com/dns-query'
assert_contains "Shadowrocket guide documents the alternate subscription DNS" \
    "${SHADOWROCKET_GUIDE_CONTENT}" 'https://doh.pub/dns-query'
assert_contains "Shadowrocket guide does not ask users to deploy the Worker" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '用户不需要部署 Worker'
assert_contains "Shadowrocket guide requires rules to use AUTO" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '所有生效的 `PROXY` 规则自动改为 `AUTO`'
assert_contains "Shadowrocket guide distinguishes the macOS DNS path" \
    "${SHADOWROCKET_GUIDE_CONTENT}" 'macOS 版“设置”页没有“订阅”项目'
assert_contains "Shadowrocket guide documents hourly subscription refresh" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '将 **间隔** 设为 **1 小时**'
assert_contains "Shadowrocket guide documents subscription binding" \
    "${SHADOWROCKET_GUIDE_CONTENT}" '打开 **订阅** 开关'
assert_contains "Shadowrocket guide links the no-group upstream" \
    "${SHADOWROCKET_GUIDE_CONTENT}" 'Shadowrocket-ADBlock-Rules-Forever/lazy.conf'
for asset in \
    docs/img/shadowrocket/mac-add-subscription.svg \
    docs/img/shadowrocket/mac-import-config.svg \
    docs/img/shadowrocket/mac-auto-group.svg \
    docs/img/shadowrocket/mac-finish.svg \
    docs/img/shadowrocket/subscription-auto-refresh.svg \
    docs/img/shadowrocket/subscription-dns.svg; do
    [[ -s "${ROOT_DIR}/${asset}" ]] || fail "Shadowrocket guide asset is missing: ${asset}"
done

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
    docs/img/spaceship/spaceship-signup.svg; do
    [[ -s "${ROOT_DIR}/${asset}" ]] || fail "Documentation asset is missing: ${asset}"
done
NON_SVG_ASSET=$(find "${ROOT_DIR}/docs/img" -type f ! -name '*.svg' -print -quit)
[[ -z "${NON_SVG_ASSET}" ]] || fail "Non-SVG documentation asset remains: ${NON_SVG_ASSET}"
[[ ! -d "${ROOT_DIR}/docs/preparation" ]] || fail "obsolete preparation asset directory still exists"
[[ ! -d "${ROOT_DIR}/docs/cloudflare" ]] || fail "obsolete top-level Cloudflare asset directory still exists"
[[ ! -d "${ROOT_DIR}/docs/spaceship" ]] || fail "obsolete top-level Spaceship asset directory still exists"
[[ ! -d "${ROOT_DIR}/docs/guide" ]] || fail "obsolete guide directory still exists"
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
assert_contains "Preparation guide keeps the hostname fallback" \
    "${PREPARATION_GUIDE_CONTENT}" '原始域名兜底节点'
assert_contains "Preparation guide documents the Mihomo requirement for selected IPs" \
    "${PREPARATION_GUIDE_CONTENT}" '精选 IP 订阅需要使用 Mihomo'
assert_contains "Preparation guide documents Shadowrocket as unverified" \
    "${PREPARATION_GUIDE_CONTENT}" 'Shadowrocket 列为已验证客户端'

assert_contains "README documents merged Profile helpers" "${README_CONTENT}" 'profile-common.sh'
assert_contains "README documents merged scheduled maintenance" \
    "${README_CONTENT}" 'scheduled-maintenance.sh'
assert_contains "README dynamic ports describe NAT" "${README_CONTENT}" 'UFW 的 `before.rules` 受管 NAT 区块'
assert_contains "README dynamic ports reject per-port allows" "${README_CONTENT}" '不会生成数万条'
assert_contains "README documents the IPv4 client default" "${README_CONTENT}" '`ip-version: ipv4`'
assert_contains "README documents the automatic Reality endpoint family" \
    "${README_CONTENT}" 'VPS 公网 IPv6 与节点域名 AAAA 完整匹配时使用 `dual`'
assert_contains "README documents bilingual interactive prompts" \
    "${README_CONTENT}" '所有需要用户输入的交互提示都会先显示中文，再在下一行显示英文'
assert_contains "README documents client connection racing" \
    "${README_CONTENT}" '内置 Mihomo 模板启用 `tcp-concurrent`'
assert_contains "README documents idle slow-start tuning" \
    "${README_CONTENT}" '`tcp_slow_start_after_idle`'
assert_contains "README distinguishes TCP keepalive from XHTTP keepalive" \
    "${README_CONTENT}" '不能替代 XHTTP'
assert_contains "README documents the managed ephemeral port range" "${README_CONTENT}" '`13000-60999`'
assert_contains "README documents XanMod LTS BBRv3" "${README_CONTENT}" 'XanMod LTS 内核'
assert_contains "README documents the BBRv3 reboot boundary" "${README_CONTENT}" '`BBRv3: active`'
assert_contains "README keeps the independent Debian initializer" \
    "${README_CONTENT}" '`scripts/debian-init.sh` 是独立的个人服务器初始化工具'
assert_contains "README update-sub includes Xray" "${README_CONTENT}" '同步重建本机 Xray、Nginx 和订阅文件'
assert_contains "XHTTP command message includes Xray" "${XHTTP_CONTENT}" \
    'Cloudflare 订阅、Origin CA 与回源规则已更新'

for content_label in README preparation-guide launcher Cloudflare-profile XHTTP-runtime; do
    case "${content_label}" in
    README) content=${README_CONTENT} ;;
    preparation-guide) content=${PREPARATION_GUIDE_CONTENT} ;;
    launcher) content=${LAUNCHER_CONTENT} ;;
    Cloudflare-profile) content=${XHTTP_CONTENT} ;;
    XHTTP-runtime) content=$(<"${ROOT_DIR}/lib/xhttp-runtime.sh") ;;
    esac
    for legacy_term in AWS Amazon Gcore GCORE CloudFront 'Route 53' \
        'xhttp-aws' 'websocket-gcore' 'aws-cdn' 'gcore-cdn' 'cdn-traffic'; do
        assert_not_contains "${content_label} excludes ${legacy_term}" "${content}" "${legacy_term}"
    done
done

for removed_path in \
    docs/aws-guide.md \
    docs/aws/aws-architecture.svg \
    docs/aws/aws-cloudfront-settings.svg \
    docs/aws/aws-iam-policy.svg \
    docs/aws/aws-iam-access-key.svg \
    docs/gcore/gcore-api-token-create.png \
    profiles/xhttp-aws.sh \
    profiles/websocket-gcore.sh \
    lib/cdn-traffic-guard.sh \
    test/test_xhttp_aws.sh \
    test/test_websocket_gcore.sh \
    test/test_cdn_traffic_guard.sh; do
    [[ ! -e "${ROOT_DIR}/${removed_path}" ]] || fail "removed path still exists: ${removed_path}"
done

for forbidden_reference in \
    'AWS CDN 精选 IP' \
    'Gcore CDN' \
    'CloudFront' \
    'Route 53' \
    'docs/aws-guide.md' \
    'docs/gcore/'; do
    assert_not_contains "README excludes ${forbidden_reference}" "${README_CONTENT}" "${forbidden_reference}"
    assert_not_contains "preparation guide excludes ${forbidden_reference}" \
        "${PREPARATION_GUIDE_CONTENT}" "${forbidden_reference}"
done

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" \
    "${ROOT_DIR}/profiles/xhttp-cloudflare.sh" "${ROOT_DIR}/lib/xhttp-runtime.sh"

printf 'ok - documentation alignment tests passed\n'
