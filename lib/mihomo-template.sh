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
    grep -Fxq 'ipv6: false' "${source}" \
        && grep -Fq '    ipv6: false' "${source}" \
        && ! grep -Eq '^[[:space:]]+(inet6-address|fake-ip-range6):' "${source}" \
        || die "Mihomo 模板必须保持 IPv4-only"
    # Bundled templates are checked with a pinned core in CI. Custom templates must
    # pass the same parser locally before either subscription publisher accepts them.
    local bundled binary check_dir result=0
    bundled="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/templates/mihomo.yaml"
    binary=${MIHOMO_CHECK_BIN:-mihomo}
    if ! command -v "${binary}" >/dev/null 2>&1; then
        [[ -z "${MIHOMO_CHECK_BIN:-}" ]] && cmp -s "${source}" "${bundled}" && return 0
        die "自定义 Mihomo 模板须经内核校验：请安装 mihomo 或设置 MIHOMO_CHECK_BIN"
    fi
    check_dir=$(mktemp -d) || die "无法创建 Mihomo 校验目录"
    # Supply a harmless node so the core can validate the complete template.
    awk '
        $0 == "# EASY_ALL_PROXY_NODE" {
            print "  - {name: easy-all-check, type: socks5, server: 127.0.0.1, port: 9}"
            next
        }
        $0 == "# EASY_ALL_PROXY_NAME" { print "        - easy-all-check"; next }
        $0 == "# EASY_ALL_PROXY_GROUP" { next }
        { print }
    ' "${source}" >"${check_dir}/config.yaml"
    "${binary}" -t -d "${MIHOMO_CHECK_HOME:-${check_dir}}" \
        -f "${check_dir}/config.yaml" >/dev/null 2>&1 || result=$?
    rm -rf -- "${check_dir}"
    ((result == 0)) || die "Mihomo 模板内核校验失败，请检查 YAML、规则及 Geo 数据"
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
        validate_mihomo_template "${MIHOMO_TEMPLATE_FILE}"
        return 0
    fi
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    fetch_mihomo_template "${template}"
    MIHOMO_TEMPLATE_FILE=${template}
}

# The Worker builder uses this same gate; never print template contents/secrets.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    die() { printf '%s\n' "$*" >&2; exit 1; }
    validate_mihomo_template "$1"
fi
