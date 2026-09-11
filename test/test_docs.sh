#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
README_CONTENT=$(<"${ROOT_DIR}/README.md")
PREPARATION_CONTENT=$(<"${ROOT_DIR}/docs/preparation-guide.md")
CLIENT_CONTENT=$(<"${ROOT_DIR}/docs/client-guide.md")
OPERATIONS_CONTENT=$(<"${ROOT_DIR}/docs/operations-guide.md")
TECHNICAL_CONTENT=$(<"${ROOT_DIR}/docs/technical-reference.md")
DEBIAN_INIT_CONTENT=$(<"${ROOT_DIR}/docs/debian-init.md")
ALL_DOCS="${README_CONTENT}
${PREPARATION_CONTENT}
${CLIENT_CONTENT}
${OPERATIONS_CONTENT}
${TECHNICAL_CONTENT}
${DEBIAN_INIT_CONTENT}"
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

for heading in '选择模式' '安装要求' '快速安装' '完成安装' '常用命令' '安全边界' '文档'; do
    assert_contains "README onboarding section" "${README_CONTENT}" "## ${heading}"
done

for doc in preparation-guide client-guide operations-guide technical-reference debian-init; do
    assert_contains "README documentation index" "${README_CONTENT}" "docs/${doc}.md"
done

assert_contains "README documents IPv4-only support" "${README_CONTENT}" '只支持 IPv4。'
assert_contains "README recommends Reality for healthy direct connectivity" \
    "${README_CONTENT}" 'VPS 公网 IP 可用且直连质量良好'
assert_contains "README recommends CDN for poor direct connectivity" \
    "${README_CONTENT}" '直连效果不佳、VPS 公网 IP 已被封'
assert_contains "README includes the bootstrap command" \
    "${README_CONTENT}" 'bootstrap.sh'
assert_contains "README includes post-reboot verification" \
    "${README_CONTENT}" 'BBRv3: active'
assert_not_contains "README omits the old installation flowchart" \
    "${README_CONTENT}" '安装脑图'
assert_not_contains "README omits implementation state schemas" \
    "${README_CONTENT}" 'STATE_VERSION='

while IFS= read -r relative_path; do
    [[ -n "${relative_path}" ]] || continue
    assert_contains "technical reference runtime module list" \
        "${TECHNICAL_CONTENT}" "$(basename "${relative_path}")"
done < <(
    sed -n '/^\(lib\|profiles\)\//p' "${ROOT_DIR}/runtime.manifest"
)

for command in show subscription self-update apply apply-cloud update-sub \
    refresh-cdn-ips update-core renew-cert quota-status quota-set quota-reset \
    status uninstall help; do
    assert_contains "operations guide public command ${command}" \
        "${OPERATIONS_CONTENT}" "| \`${command}"
done

for phrase in \
    '避免查询参数中的 Token 写入日志' \
    '/etc/easy_all/globalping.token' \
    'WORKER_AGGREGATION_CONFIG={...}' \
    '每小时刷新' \
    '与当前入口策略兼容的缓存' \
    'Cloudflare 官方 IPv4 CIDR' \
    '全链路固定 IPv4' \
    'Workers Scripts Write' \
    '默认名称为 `easyall`' \
    '`global_fetch_strictly_public`' \
    'UFW 的 `before.rules` 受管 NAT 区块' \
    '不会生成数万条' \
    '`ForceIPv4` + `UseIPv4`' \
    '`tcp-concurrent`' \
    '`tcp_slow_start_after_idle`' \
    '不能替代 XHTTP' \
    '`13000-60999`' \
    'XanMod LTS 内核' \
    'GOOGLE_EGRESS_RESOLVED=ipv4' \
    '所有需要用户输入的交互提示仅显示中文'; do
    assert_contains "detailed documentation contract" "${ALL_DOCS}" "${phrase}"
done

assert_contains "client guide documents Mihomo selected-IP requirements" \
    "${CLIENT_CONTENT}" '客户端必须能分别保存'
assert_contains "client guide marks Shadowrocket unverified" \
    "${CLIENT_CONTENT}" '目前不把 Shadowrocket 列为'
assert_contains "client guide documents Clash Mi global selection" \
    "${CLIENT_CONTENT}" '手动勾选 `PROXY`'
assert_contains "client guide embeds Clash Mi illustration" \
    "${CLIENT_CONTENT}" 'img/clashmi/clashmi-global-proxy.svg'

WINDOWS_ROW=$(grep '^| Windows ' "${ROOT_DIR}/docs/client-guide.md")
ANDROID_ROW=$(grep '^| Android ' "${ROOT_DIR}/docs/client-guide.md")
IOS_ROW=$(grep '^| iOS / iPadOS ' "${ROOT_DIR}/docs/client-guide.md")
assert_contains "Windows clients include Clash Verge Rev" "${WINDOWS_ROW}" 'Clash Verge Rev'
assert_contains "Android clients include Clash Mi" "${ANDROID_ROW}" 'Clash Mi'
assert_not_contains "Android clients exclude Clash Verge Rev" "${ANDROID_ROW}" 'Clash Verge Rev'
assert_contains "iOS clients include Clash Mi" "${IOS_ROW}" 'Clash Mi'
assert_not_contains "iOS clients exclude unverified Bettbox" "${IOS_ROW}" 'Bettbox'

for phrase in \
    '# 前置准备手册' \
    'Your domain is now protected by Cloudflare' \
    'https://www.spaceship.com/' \
    'https://dash.cloudflare.com/sign-up' \
    'https://dash.globalping.io/tokens' \
    'Network → gRPC' \
    'Cloudflare 官方 IPv4 CIDR' \
    '只筛选和下发 Cloudflare IPv4 边缘节点' \
    '不使用内置 Anycast IP 或域名兜底凑数'; do
    assert_contains "preparation guide contract" "${PREPARATION_CONTENT}" "${phrase}"
done

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
    [[ -s "${ROOT_DIR}/${asset}" ]] || fail "documentation asset is missing: ${asset}"
done

assert_contains "Cloudflare install explains VPS traffic accounting" \
    "${XHTTP_CONTENT}" '月度出站额度通常是可用代理载荷的主要上限'
assert_contains "Cloudflare node prompt includes an example" \
    "${XHTTP_CONTENT}" '客户端连接的 CDN 节点域名（例如 node.example.com）'
assert_contains "Cloudflare node prompt forbids pre-created DNS" \
    "${XHTTP_CONTENT}" '不要提前创建 DNS 记录'
assert_contains "Cloudflare command result includes Xray" \
    "${XHTTP_CONTENT}" 'Cloudflare Worker 订阅、Origin CA 与回源规则已更新'

for legacy_term in AWS Amazon CloudFront 'Route 53' 'xhttp-aws' 'aws-cdn'; do
    assert_not_contains "documentation excludes ${legacy_term}" "${ALL_DOCS}" "${legacy_term}"
    assert_not_contains "launcher excludes ${legacy_term}" "${LAUNCHER_CONTENT}" "${legacy_term}"
    assert_not_contains "Cloudflare profile excludes ${legacy_term}" "${XHTTP_CONTENT}" "${legacy_term}"
done

NON_SVG_ASSET=$(find "${ROOT_DIR}/docs/img" -type f ! -name '*.svg' -print -quit)
[[ -z "${NON_SVG_ASSET}" ]] || fail "non-SVG documentation asset remains: ${NON_SVG_ASSET}"

bash -n "${ROOT_DIR}/easy_all" "${ROOT_DIR}/bootstrap.sh" \
    "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" \
    "${ROOT_DIR}/lib/xhttp-runtime.sh"

printf 'ok - documentation alignment tests passed\n'
