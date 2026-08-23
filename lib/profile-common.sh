#!/usr/bin/env bash

# Shared Profile plumbing, input validation and state normalization.

make_temp_dir() {
    mktemp -d "${RUNTIME_TMP}/part.XXXXXX"
}

read_bilingual() {
    local label_zh=$1 label_en=$2 variable=$3 silent=${4:-0} input
    printf '%s\n%s\n' "${label_zh}" "${label_en}" >&2
    if [[ "${silent}" == "1" ]]; then
        IFS= read -r -s -p '> ' input
        printf '\n' >&2
    else
        IFS= read -r -p '> ' input
    fi
    printf -v "${variable}" '%s' "${input}"
}

prompt_value() {
    local label=$1 default=${2:-} label_en=${3:-Input / see the Chinese prompt above} value
    if [[ -n "${default}" ]]; then
        read_bilingual \
            "${label} [${default}]（直接回车使用默认值）:" \
            "${label_en} [${default}] (press Enter to use the default):" value
        printf '%s' "${value:-${default}}"
    else
        read_bilingual "${label}:" "${label_en}:" value
        printf '%s' "${value}"
    fi
}

register_easy_all_command() {
    local launcher="${SCRIPT_DIR}/../easy_all"
    [[ -f "${launcher}" ]] \
        || die "缺少统一入口，Profile 不能独立注册：${launcher}"
    bash "${launcher}" register-command
}

validate_domain() {
    local domain=$1 label tld
    local -a labels
    [[ ${#domain} -ge 4 && ${#domain} -le 253 ]] || return 1
    [[ "${domain}" == *.* ]] || return 1
    [[ "${domain}" != \*.* ]] || return 1
    [[ "${domain}" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "${domain}" != .* && "${domain}" != *. ]] || return 1
    [[ "${domain}" != *..* ]] || return 1
    IFS=. read -r -a labels <<<"${domain}"
    for label in "${labels[@]}"; do
        [[ ${#label} -ge 1 && ${#label} -le 63 ]] || return 1
        [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]] || return 1
    done
    tld=${labels[$((${#labels[@]} - 1))]}
    [[ "${tld}" =~ ^[A-Za-z]{2,}$ ]]
}

normalize_domain() {
    local domain=$1
    domain=${domain%.}
    tr '[:upper:]' '[:lower:]' <<<"${domain}" | tr -d '\n'
}

validate_ipv4() {
    local ip=$1 octet
    local -a octets
    [[ "${ip}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<<"${ip}"
    for octet in "${octets[@]}"; do
        ((10#${octet} >= 0 && 10#${octet} <= 255)) || return 1
    done
}

validate_uuid() {
    [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]
}

validate_sub_download_name() {
    [[ "$1" =~ ^[A-Za-z0-9._-]{1,64}$ ]]
}

normalize_sub_download_name() {
    local name=${1:-}
    name=${name%.[Yy][Aa][Mm][Ll]}
    name=${name%.[Yy][Mm][Ll]}
    if validate_sub_download_name "${name}"; then
        printf '%s' "${name}"
    else
        printf '%s' "${DEFAULT_SUB_DOWNLOAD_NAME}"
    fi
}
