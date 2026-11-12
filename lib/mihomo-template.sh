#!/usr/bin/env bash

# Shared Mihomo template loading and validation.

# Bundled templates ship with the repository and are checked against a pinned core in
# CI, so a host without the core can still publish one of them by path. Compare
# content instead of location so staged copies keep working.
mihomo_template_matches_bundled() {
    local source=$1 bundled_dir=$2 candidate
    for candidate in "${bundled_dir}"/*.yaml; do
        [[ -f "${candidate}" ]] || continue
        cmp -s "${source}" "${candidate}" && return 0
    done
    return 1
}

# dns 段是否把 ipv6 显式关闭。缩进宽度不限（2/4 空格等），但必须是 dns: 的直接子键：
# 缩进更深的嵌套键、或别处出现的 ipv6: false 都不算。
mihomo_dns_disables_ipv6() {
    awk '
        function indent_of(line) {
            match(line, /^[[:space:]]*/)
            return RLENGTH
        }
        /^dns:[[:space:]]*(#.*)?$/ { inside = 1; child_indent = -1; next }
        !inside { next }
        /^[[:space:]]*$/ { next }
        /^[[:space:]]*#/ { next }
        {
            current = indent_of($0)
            if (current == 0) exit
            if (child_indent < 0) child_indent = current
            if (current != child_indent) next
            body = $0
            sub(/^[[:space:]]+/, "", body)
            sub(/[[:space:]]+#.*$/, "", body)
            if (body ~ /^ipv6:[[:space:]]*false[[:space:]]*$/) found = 1
        }
        END { exit(found ? 0 : 1) }
    ' "${1:?mihomo_dns_disables_ipv6 需要模板路径}"
}

validate_mihomo_template() {
    local source=$1 trusted_without_core=${2:-0} marker count bad_sniffer
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
    # 订阅发布时会按段剔除非 iOS 客户端的嗅探配置；内联写法无法按段剔除，宁可在入口报错。
    bad_sniffer=$(grep -E '^sniffer:' "${source}" \
        | grep -Ev '^sniffer:[[:space:]]*(#.*)?$' || true)
    [[ -z "${bad_sniffer}" ]] \
        || die "Mihomo 模板的 sniffer 段必须写成块映射（sniffer: 后不能接内联内容）：${source}"
    grep -Fxq 'ipv6: false' "${source}" \
        && mihomo_dns_disables_ipv6 "${source}" \
        && ! grep -Eq '^[[:space:]]+(inet6-address|fake-ip-range6):' "${source}" \
        || die "Mihomo 模板必须保持 IPv4-only（顶层与 dns 段都要显式 ipv6: false，且不得出现 IPv6 地址字段）"
    # 仓库 CI 不安装 Mihomo 内核：bundled/trusted 模板在无内核时只做结构校验
    # （npm test 覆盖），不能当作真实内核验收；自定义模板必须在本机通过内核解析。
    local bundled_dir binary check_dir result=0
    bundled_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)/templates"
    binary=${MIHOMO_CHECK_BIN:-mihomo}
    if ! command -v "${binary}" >/dev/null 2>&1; then
        if [[ -z "${MIHOMO_CHECK_BIN:-}" ]] \
            && { [[ "${trusted_without_core}" == "1" ]] \
                || mihomo_template_matches_bundled "${source}" "${bundled_dir}"; }; then
            return 0
        fi
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
    local destination=$1 source=${MIHOMO_TEMPLATE_SOURCE:-} url trusted_without_core=0
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
        trusted_without_core=1
    else
        url=${MIHOMO_TEMPLATE_URL:-${DEFAULT_MIHOMO_TEMPLATE_URL}}
        [[ "${url}" =~ ^https:// ]] \
            || die "MIHOMO_TEMPLATE_URL 必须使用 HTTPS：${url}"
        curl -fsSL --connect-timeout 10 --max-time 30 --retry 3 "${url}" -o "${destination}" \
            || die "下载 Mihomo 模板失败：${url}"
        [[ "${url}" == "${DEFAULT_MIHOMO_TEMPLATE_URL}" ]] && trusted_without_core=1
    fi
    validate_mihomo_template "${destination}" "${trusted_without_core}"
}

prepare_mihomo_template() {
    local template
    # An explicit source always wins over a preselected or persisted template file.
    if [[ -n "${MIHOMO_TEMPLATE_SOURCE:-}" ]]; then
        template="${RUNTIME_TMP}/sample-mihomo.yaml"
        fetch_mihomo_template "${template}"
        MIHOMO_TEMPLATE_FILE=${template}
        return 0
    fi
    if [[ -n "${MIHOMO_TEMPLATE_FILE:-}" ]]; then
        validate_mihomo_template "${MIHOMO_TEMPLATE_FILE}" "${MIHOMO_TEMPLATE_TRUSTED:-0}"
        return 0
    fi
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    fetch_mihomo_template "${template}"
    MIHOMO_TEMPLATE_FILE=${template}
}

# Never print template contents/secrets.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    set -euo pipefail
    die() { printf '%s\n' "$*" >&2; exit 1; }
    validate_mihomo_template "$1" "${MIHOMO_TEMPLATE_TRUSTED:-0}"
fi
