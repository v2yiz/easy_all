#!/usr/bin/env bash

# Shared Mihomo template loading and validation.

validate_mihomo_template() {
    local source=$1 marker count
    [[ -s "${source}" ]] || die "sample-mihomo.yaml 为空：${source}"
    for marker in "# EASY_ALL_PROXY_NODE" "# EASY_ALL_PROXY_NAME"; do
        count=$(grep -Fxc "${marker}" "${source}" || true)
        [[ "${count}" == "1" ]] \
            || die "sample-mihomo.yaml 模板标记无效：${marker} 应且只能出现一次"
    done
    grep -q '^rules:' "${source}" || die "sample-mihomo.yaml 缺少规则"
    grep -Fq '    enhanced-mode: fake-ip' "${source}" \
        || die "sample-mihomo.yaml 未使用 XFLASH fake-ip DNS"
    grep -Fq '    use-system-hosts: false' "${source}" \
        || die "sample-mihomo.yaml 未使用 XFLASH hosts 策略"
    grep -Fq "https://223.6.6.6/dns-query#h3=true" "${source}" \
        || die "sample-mihomo.yaml 缺少 XFLASH 主 DNS"
    grep -Fq "proxy-server-nameserver: ['https://223.5.5.5/dns-query', 'https://1.12.12.12/dns-query']" \
        "${source}" || die "sample-mihomo.yaml 缺少 XFLASH 节点 DNS"
    if grep -Eq '^[[:space:]]+(default-nameserver|direct-nameserver|respect-rules|ipv6):' \
        "${source}"; then
        die "sample-mihomo.yaml 包含非 XFLASH DNS 覆盖"
    fi
}

fetch_mihomo_template() {
    local destination=$1 source=${MIHOMO_TEMPLATE_SOURCE:-} url
    if [[ -n "${source}" ]]; then
        if [[ -f "${source}" ]]; then
            install -m 0600 "${source}" "${destination}"
        elif [[ "${source}" =~ ^https:// ]]; then
            curl -fsSL --retry 3 "${source}" -o "${destination}" \
                || die "下载 sample-mihomo.yaml 失败：${source}"
            chmod 0600 "${destination}"
        else
            die "MIHOMO_TEMPLATE_SOURCE 必须是本地文件或 HTTPS URL：${source}"
        fi
    elif [[ -f "${SCRIPT_DIR}/sample-mihomo.yaml" ]]; then
        install -m 0600 "${SCRIPT_DIR}/sample-mihomo.yaml" "${destination}"
    else
        url=${MIHOMO_TEMPLATE_URL:-${DEFAULT_MIHOMO_TEMPLATE_URL}}
        [[ "${url}" =~ ^https:// ]] \
            || die "MIHOMO_TEMPLATE_URL 必须使用 HTTPS：${url}"
        curl -fsSL --retry 3 "${url}" -o "${destination}" \
            || die "下载 sample-mihomo.yaml 失败：${url}"
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
