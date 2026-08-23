#!/usr/bin/env bash

# Shared Mihomo template loading, validation and metadata extraction.

extract_domain_suffix_policy() {
    local source=$1 start_marker=$2 end_marker=$3 description=$4
    local json domain normalized compact
    json=$(awk -v start_marker="${start_marker}" -v end_marker="${end_marker}" '
        $0 == start_marker {
            capture = 1
            next
        }
        $0 == end_marker {
            capture = 0
            exit
        }
        capture == 1 {
            print
        }
    ' "${source}" | sed 's/^#[[:space:]]*//') \
        || die "无法提取 Mihomo ${description} 域名策略"
    jq -e '
        type == "array"
        and length > 0
        and all(.[]; type == "string")
        and length == (unique | length)
    ' <<<"${json}" >/dev/null \
        || die "Mihomo ${description} 域名策略必须是非空且不重复的字符串数组"
    while IFS= read -r domain; do
        validate_domain "${domain}" \
            || die "Mihomo ${description} 域名策略包含无效域名：${domain}"
        normalized=$(normalize_domain "${domain}")
        [[ "${normalized}" == "${domain}" ]] \
            || die "Mihomo ${description} 域名必须使用小写规范格式：${domain}"
    done < <(jq -r '.[]' <<<"${json}")
    compact=$(jq -c '.' <<<"${json}") \
        || die "无法规范化 Mihomo ${description} 域名策略"
    printf '%s\n' "${compact}"
}

extract_gemini_domain_suffixes() {
    extract_domain_suffix_policy "$1" \
        "# EASY_ALL_GEMINI_DOMAINS_START" \
        "# EASY_ALL_GEMINI_DOMAINS_END" \
        "Gemini"
}

extract_chatgpt_domain_suffixes() {
    extract_domain_suffix_policy "$1" \
        "# EASY_ALL_CHATGPT_DOMAINS_START" \
        "# EASY_ALL_CHATGPT_DOMAINS_END" \
        "ChatGPT"
}

extract_claude_domain_suffixes() {
    extract_domain_suffix_policy "$1" \
        "# EASY_ALL_CLAUDE_DOMAINS_START" \
        "# EASY_ALL_CLAUDE_DOMAINS_END" \
        "Claude"
}

extract_ai_warp_domain_suffixes() {
    local source=$1 gemini chatgpt claude
    gemini=$(extract_gemini_domain_suffixes "${source}")
    chatgpt=$(extract_chatgpt_domain_suffixes "${source}")
    claude=$(extract_claude_domain_suffixes "${source}")
    jq -cn --argjson gemini "${gemini}" --argjson chatgpt "${chatgpt}" \
        --argjson claude "${claude}" \
        '$gemini + $chatgpt + $claude | unique'
}

validate_mihomo_template() {
    local source=$1 marker count ssh_rules
    [[ -s "${source}" ]] || die "sample-mihomo.yaml 为空：${source}"
    for marker in \
        "# EASY_ALL_PROXY_NODE" \
        "# EASY_ALL_PROXY_NAME" \
        "# EASY_ALL_GEMINI_DOMAINS_START" \
        "# EASY_ALL_GEMINI_DOMAINS_END" \
        "# EASY_ALL_CHATGPT_DOMAINS_START" \
        "# EASY_ALL_CHATGPT_DOMAINS_END" \
        "# EASY_ALL_CLAUDE_DOMAINS_START" \
        "# EASY_ALL_CLAUDE_DOMAINS_END"; do
        count=$(grep -Fxc "${marker}" "${source}" || true)
        [[ "${count}" == "1" ]] \
            || die "sample-mihomo.yaml 模板标记无效：${marker} 应且只能出现一次"
    done
    grep -q '^rules:' "${source}" || die "sample-mihomo.yaml 缺少规则"
    ssh_rules=$(awk '
        $0 == "rules:" {in_rules=1; next}
        in_rules && /^[[:space:]]*-[[:space:]]*/ {
            rule=$0
            sub(/^[[:space:]]*-[[:space:]]*/, "", rule)
            print rule
            if (++count == 2) exit
        }
    ' "${source}")
    [[ "${ssh_rules}" == $'DST-PORT,22,DIRECT\nDST-PORT,65533,DIRECT' ]] \
        || die "sample-mihomo.yaml 的前两条规则必须直连 SSH 端口 22 和 65533"
    extract_gemini_domain_suffixes "${source}" >/dev/null
    extract_chatgpt_domain_suffixes "${source}" >/dev/null
    extract_claude_domain_suffixes "${source}" >/dev/null
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
    if [[ -n "${MIHOMO_TEMPLATE_FILE:-}" \
        && -s "${MIHOMO_TEMPLATE_FILE}" \
        && -n "${GEMINI_DOMAIN_SUFFIXES_JSON:-}" \
        && -n "${CHATGPT_DOMAIN_SUFFIXES_JSON:-}" \
        && -n "${CLAUDE_DOMAIN_SUFFIXES_JSON:-}" \
        && -n "${AI_WARP_DOMAIN_SUFFIXES_JSON:-}" ]]; then
        return 0
    fi
    template="${RUNTIME_TMP}/sample-mihomo.yaml"
    fetch_mihomo_template "${template}"
    GEMINI_DOMAIN_SUFFIXES_JSON=$(extract_gemini_domain_suffixes "${template}")
    CHATGPT_DOMAIN_SUFFIXES_JSON=$(extract_chatgpt_domain_suffixes "${template}")
    CLAUDE_DOMAIN_SUFFIXES_JSON=$(extract_claude_domain_suffixes "${template}")
    AI_WARP_DOMAIN_SUFFIXES_JSON=$(extract_ai_warp_domain_suffixes "${template}")
    MIHOMO_TEMPLATE_FILE=${template}
}
