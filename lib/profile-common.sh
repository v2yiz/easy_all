#!/usr/bin/env bash

# Shared Profile plumbing, input validation and state normalization.

make_temp_dir() {
    mktemp -d "${RUNTIME_TMP}/part.XXXXXX"
}

download_https_file() {
    local url=$1 destination=$2 description=${3:-文件}
    local -a wget_args=(
        --https-only
        --secure-protocol=TLSv1_2
        --timeout=20
        --read-timeout=45
        --tries=5
        --retry-connrefused
        --waitretry=2
        --max-redirect=10
        --output-file=/dev/stderr
        --show-progress
        -O "${destination}"
    )
    timeout 10m wget "${wget_args[@]}" "${url}" \
        || die "下载${description}失败：${url}"
    [[ -s "${destination}" ]] || die "下载${description}失败：返回空文件"
}

install_acme_from_github() {
    local acme_home=$1 account_email=$2
    local temp_dir release_file archive source_dir version archive_url
    temp_dir=$(make_temp_dir)
    release_file="${temp_dir}/release.json"
    archive="${temp_dir}/acme.tar.gz"
    source_dir="${temp_dir}/source"

    download_https_file \
        "https://api.github.com/repos/acmesh-official/acme.sh/releases/latest" \
        "${release_file}" " acme.sh 最新版本信息"
    version=$(jq -r '.tag_name // empty' "${release_file}")
    archive_url=$(jq -r '.tarball_url // empty' "${release_file}")
    [[ "${version}" =~ ^v?[0-9]+([.][0-9]+){2}$ ]] \
        || die "GitHub 返回了无效的 acme.sh 版本：${version:-空}"
    [[ "${archive_url}" == \
        https://api.github.com/repos/acmesh-official/acme.sh/tarball/* ]] \
        || die "GitHub 返回了无效的 acme.sh 下载地址"

    info "正在从 GitHub 官方仓库下载 acme.sh ${version}"
    download_https_file "${archive_url}" "${archive}" " acme.sh ${version}"
    tar -tzf "${archive}" >/dev/null 2>&1 \
        || die "acme.sh 下载归档损坏"
    install -d -m 0700 "${source_dir}"
    tar -xzf "${archive}" -C "${source_dir}" --strip-components=1 \
        || die "解压 acme.sh 失败"
    [[ -f "${source_dir}/acme.sh" ]] || die "acme.sh 下载归档内容不完整"
    (
        cd "${source_dir}"
        sh ./acme.sh --install -m "${account_email}" --home "${acme_home}"
    ) || die "安装 acme.sh 失败"
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
