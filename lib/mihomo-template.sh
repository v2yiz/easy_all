#!/usr/bin/env bash

# Shared Mihomo template loading and validation.

validate_mihomo_template() {
    local source=$1 marker count
    [[ -s "${source}" ]] || die "Mihomo 模板为空：${source}"
    for marker in \
        "# EASY_ALL_PROXY_NODE" \
        "# EASY_ALL_PROXY_GROUP" \
        "# EASY_ALL_PROXY_NAME"; do
        count=$(grep -Fxc "${marker}" "${source}" || true)
        [[ "${count}" == "1" ]] \
            || die "Mihomo 模板标记无效：${marker} 应且只能出现一次"
    done
    grep -q '^rules:' "${source}" || die "Mihomo 模板缺少规则"
    grep -Fq '    enhanced-mode: fake-ip' "${source}" \
        || die "Mihomo 模板未使用 XFLASH fake-ip DNS"
    grep -Fq '    store-fake-ip: true' "${source}" \
        || die "Mihomo 模板未持久化 fake-ip 映射"
    grep -Fq '    fake-ip-range6: fdfe:dcba:9876::/64' "${source}" \
        || die "Mihomo 模板缺少 IPv6 fake-ip 地址池"
    grep -Fq '    fake-ip-filter-mode: rule' "${source}" \
        || die "Mihomo 模板未使用 fake-ip 规则过滤"
    grep -Fq '      - MATCH,fake-ip' "${source}" \
        || die "Mihomo 模板缺少 fake-ip 默认规则"
    grep -Fq '    udp-timeout: 300' "${source}" \
        || die "Mihomo 模板 UDP 会话超时不是 300 秒"
    grep -Fq '    use-system-hosts: false' "${source}" \
        || die "Mihomo 模板未使用 XFLASH hosts 策略"
    grep -Fqx 'ipv6: true' "${source}" \
        || die "Mihomo 模板未启用客户端 IPv6"
    grep -Fq '    ipv6: true' "${source}" \
        || die "Mihomo DNS 未启用 IPv6"
    grep -Fq 'unified-delay: false' "${source}" \
        || die "Mihomo 模板必须关闭 unified-delay"
    grep -Fqx 'geodata-mode: true' "${source}" \
        || die "Mihomo 模板未启用 Geo DAT 数据"
    grep -Fqx 'geo-auto-update: true' "${source}" \
        || die "Mihomo 模板未启用 Geo 数据自动更新"
    grep -Fqx 'geo-update-interval: 24' "${source}" \
        || die "Mihomo 模板 Geo 数据更新周期不是 24 小时"
    grep -Fq 'MetaCubeX/meta-rules-dat@release/geoip.dat' "${source}" \
        || die "Mihomo 模板缺少 GeoIP 数据源"
    grep -Fq 'MetaCubeX/meta-rules-dat@release/geosite.dat' "${source}" \
        || die "Mihomo 模板缺少 GeoSite 数据源"
    grep -Fq "      'geosite:cn':" "${source}" \
        || die "Mihomo 模板缺少中国域名 DNS 策略"
    grep -Fq 'https://1.1.1.1/dns-query#PROXY' "${source}" \
        || die "Mihomo 模板缺少 Cloudflare 代理 DNS"
    grep -Fq 'https://8.8.8.8/dns-query#PROXY' "${source}" \
        || die "Mihomo 模板缺少 Google 代理 DNS"
    grep -Fq "proxy-server-nameserver: ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query', 'https://1.1.1.1/dns-query']" \
        "${source}" || die "Mihomo 模板缺少 XFLASH 节点 DNS"
    grep -Fq '  - AND,((NETWORK,UDP),(DST-PORT,443),(GEOIP,CN)),DIRECT' "${source}" \
        || die "Mihomo 模板未放行中国大陆 QUIC"
    if grep -Eq '^[[:space:]]+- PROCESS-NAME,(Thunder|DownloadService|qBittorrent|qbittorrent|Transmission|fdm|aria2c|Folx|NetTransport|uTorrent|WebTorrent|BitComet|ThunderVIP|transmission-daemon|transmission-qt|aDrive)(\.exe)?,DIRECT$' \
        "${source}"; then
        die "Mihomo 模板不应按下载器进程无条件直连"
    fi
    if grep -Eq '^[[:space:]]+(default-nameserver|direct-nameserver|respect-rules):' \
        "${source}"; then
        die "Mihomo 模板包含非 XFLASH DNS 覆盖"
    fi
}

fetch_mihomo_template() {
    local destination=$1 source=${MIHOMO_TEMPLATE_SOURCE:-} url
    if [[ -n "${source}" ]]; then
        if [[ -f "${source}" ]]; then
            install -m 0600 "${source}" "${destination}"
        elif [[ "${source}" =~ ^https:// ]]; then
            curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${source}" -o "${destination}" \
                || die "下载 Mihomo 模板失败：${source}"
            chmod 0600 "${destination}"
        else
            die "MIHOMO_TEMPLATE_SOURCE 必须是本地文件或 HTTPS URL：${source}"
        fi
    elif [[ -f "${SCRIPT_DIR}/../templates/mihomo.yaml" ]]; then
        install -m 0600 "${SCRIPT_DIR}/../templates/mihomo.yaml" "${destination}"
    else
        url=${MIHOMO_TEMPLATE_URL:-${DEFAULT_MIHOMO_TEMPLATE_URL}}
        [[ "${url}" =~ ^https:// ]] \
            || die "MIHOMO_TEMPLATE_URL 必须使用 HTTPS：${url}"
        curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${url}" -o "${destination}" \
            || die "下载 Mihomo 模板失败：${url}"
    fi
    validate_mihomo_template "${destination}"
}

prepare_mihomo_template() {
    local template
    if [[ -n "${MIHOMO_TEMPLATE_FILE:-}" && -s "${MIHOMO_TEMPLATE_FILE}" ]]; then
        return 0
    fi
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    fetch_mihomo_template "${template}"
    MIHOMO_TEMPLATE_FILE=${template}
}
