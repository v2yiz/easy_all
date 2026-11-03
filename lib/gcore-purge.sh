#!/usr/bin/env bash
# One-shot cleanup of easy_all-owned Gcore CDN resources. Works without local state.
set -Eeuo pipefail
umask 077

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly GCORE_API_BASE="https://api.gcore.com"

# shellcheck source=lib/log.sh
source "${SCRIPT_DIR}/log.sh"
# shellcheck source=lib/gcore-cdn.sh
source "${SCRIPT_DIR}/gcore-cdn.sh"

usage() {
    local status=${1:-2} fd=2
    ((status == 0)) && fd=1
    cat >&"${fd}" <<'EOF'
用法: easy_all purge-gcore [--domain <域名>[,<域名>...]] [--all] [--yes]

  --domain <域名>  清理 cname 等于该域名的 CDN Resource，以及它绑定的 Origin Group、证书与 CA
  --all            清理账户内全部 easy_all-* 命名的 Origin Group、证书，以及绑定这些组件的 CDN Resource
  --yes            跳过确认（非交互模式必须显式给出）

不带参数时交互选择范围。只删除 Gcore CDN 对象，不删除 DNS 记录和 Managed DNS Zone。
--domain 传节点域名可精确清理一次安装；传错域名不会子串误伤其他站点。
若 CDN Resource 已先删除，请同时传入源站域名（如 --domain node.example.com,origin.example.com）
或改用 --all。
EOF
    exit "${status}"
}

case "${1:-}" in
-h | --help) usage 0 ;;
esac
[[ "$(id -u)" -eq 0 ]] || die "请使用 root 用户运行此脚本"
for _cmd in curl jq; do
    command -v "${_cmd}" >/dev/null 2>&1 \
        || die "执行清理需要 ${_cmd}，请先安装：apt-get install -y ${_cmd}"
done

PURGE_ALL=0
ASSUME_YES=0
DOMAIN_COUNT=0
DOMAINS=()

add_domains() {
    local input=$1 domain
    local -a list
    IFS=', ' read -r -a list <<<"${input}"
    for domain in "${list[@]}"; do
        [[ -n "${domain}" ]] || continue
        DOMAINS+=("$(tr '[:upper:]' '[:lower:]' <<<"${domain%.}")")
        DOMAIN_COUNT=$((DOMAIN_COUNT + 1))
    done
}

while (($#)); do
    case "$1" in
    --domain) shift; [[ -n "${1:-}" ]] || usage; add_domains "$1" ;;
    --all) PURGE_ALL=1 ;;
    --yes) ASSUME_YES=1 ;;
    *) usage ;;
    esac
    shift
done

if ((PURGE_ALL == 0)) && ((DOMAIN_COUNT == 0)); then
    [[ -t 0 ]] || usage
    printf '清理范围：\n  1. 指定域名相关资源\n  2. 账户内全部 easy_all-* Gcore 资源\n' >&2
    read_prompt '请选择 [1]: ' _scope
    case "${_scope:-1}" in
    1) read_prompt '节点域名（多个用逗号分隔）: ' _input; add_domains "${_input}" ;;
    2) PURGE_ALL=1 ;;
    *) usage ;;
    esac
fi
if ((PURGE_ALL == 0)) && ((DOMAIN_COUNT == 0)); then
    usage
fi

if [[ -z "${GCORE_API_TOKEN:-}" ]]; then
    [[ -t 0 ]] || die "非交互模式必须设置 GCORE_API_TOKEN"
    read_prompt 'Gcore API Token（不落盘）: ' GCORE_API_TOKEN 1
    printf '\n' >&2
fi
[[ ${#GCORE_API_TOKEN} -ge 16 ]] || die "GCORE_API_TOKEN 格式无效"

RUNTIME_TMP=$(mktemp -d "${TMPDIR:-/tmp}/easy_all-purge.XXXXXX") \
    || die "无法创建临时目录"
if [[ -f "/etc/easy_all/state.env" ]]; then
    warn "检测到本机已有 easy_all 安装；清理 Gcore 资源后需要重新安装或 apply-cloud"
fi
trap 'rm -rf -- "${RUNTIME_TMP}"' EXIT

domain_equal() {
    local value=$1 domain
    ((DOMAIN_COUNT > 0)) || return 1
    for domain in "${DOMAINS[@]}"; do
        [[ "${value}" == "${domain}" ]] && return 0
    done
    return 1
}

# easy_all 的 Gcore 对象名格式固定：easy_all-<域> / easy_all-edge-<域> /
# easy_all-edge-client-<域> / easy_all-origin-ca-<域>-<hash>；按完整格式匹配避免子串误伤。
matches_gcore_name() {
    local value=$1 domain escaped
    ((DOMAIN_COUNT > 0)) || return 1
    for domain in "${DOMAINS[@]}"; do
        escaped=${domain//./\\.}
        [[ "${value}" =~ ^easy_all(-edge|-edge-client|-origin-ca)?-${escaped}(-[0-9a-f]{8,})?$ ]] && return 0
    done
    return 1
}

resources=$(gcore_api_request GET "/cdn/resources?limit=1000")
groups=$(gcore_api_request GET "/cdn/origin_groups?limit=1000")
ssl_data=$(gcore_api_request GET "/cdn/sslData?limit=1000")
ssl_certs=$(gcore_api_request GET "/cdn/sslCertificates?limit=1000")

for file in resources groups ssl ca; do : >"${RUNTIME_TMP}/${file}.tsv"; done
: >"${RUNTIME_TMP}/group-names.tsv"
while IFS= read -r _group; do
    [[ -n "${_group}" ]] || continue
    printf '%s\t%s\n' "$(jq -r '.id // empty' <<<"${_group}")" \
        "$(jq -r '.name // empty' <<<"${_group}")" >>"${RUNTIME_TMP}/group-names.tsv"
done < <(gcore_json_items "${groups}")
: >"${RUNTIME_TMP}/linked-groups"
: >"${RUNTIME_TMP}/linked-ssl"
: >"${RUNTIME_TMP}/linked-ca"

add_group() {
    local id=$1 name=$2
    grep -Fqx "${id}" <(cut -f1 "${RUNTIME_TMP}/groups.tsv") && return 0
    printf '%s\t%s\n' "${id}" "${name}" >>"${RUNTIME_TMP}/groups.tsv"
}

# 1) Origin Group：按 easy_all 命名或域名匹配
while IFS= read -r group; do
    [[ -n "${group}" ]] || continue
    id=$(jq -r '.id // empty' <<<"${group}")
    name=$(jq -r '.name // empty' <<<"${group}")
    [[ -n "${id}" ]] || continue
    if { ((PURGE_ALL == 1)) && [[ "${name}" == easy_all-* ]]; } || matches_gcore_name "${name}"; then
        add_group "${id}" "${name}"
    fi
done < <(gcore_json_items "${groups}")

# 2) CDN Resource：域名匹配，或 --all 时绑定到已选 easy_all Origin Group
while IFS= read -r resource; do
    [[ -n "${resource}" ]] || continue
    id=$(jq -r '.id // empty' <<<"${resource}")
    cname=$(tr '[:upper:]' '[:lower:]' <<<"$(jq -r '.cname // empty' <<<"${resource}")")
    group_id=$(jq -r '.originGroup // empty' <<<"${resource}")
    group_name=$(awk -F'\t' -v id="${group_id}" '$1 == id {print $2; exit}' \
        "${RUNTIME_TMP}/group-names.tsv")
    [[ -n "${id}" ]] || continue
    if domain_equal "${cname}" \
        || { ((PURGE_ALL == 1)) && grep -Fqx "${group_id}" <(cut -f1 "${RUNTIME_TMP}/groups.tsv"); }; then
        printf '%s\t%s\n' "${id}" "${cname}" >>"${RUNTIME_TMP}/resources.tsv"
        [[ -z "${group_id}" ]] || add_group "${group_id}" "${group_name}"
        for key in sslData proxy_ssl_data; do
            jq -r --arg key "${key}" '.[$key] // empty' <<<"${resource}" >>"${RUNTIME_TMP}/linked-ssl"
        done
        jq -r '.proxy_ssl_ca // empty' <<<"${resource}" >>"${RUNTIME_TMP}/linked-ca"
    fi
done < <(gcore_json_items "${resources}")

if ((PURGE_ALL == 0)) && [[ ! -s "${RUNTIME_TMP}/resources.tsv" ]]; then
    warn "没有匹配到 cname 等于输入域名的 CDN Resource；若资源已删除，请同时传入源站域名或改用 --all"
fi

# 3) 证书：easy_all 命名、域名匹配或资源绑定
while IFS= read -r certificate; do
    [[ -n "${certificate}" ]] || continue
    id=$(jq -r '.id // empty' <<<"${certificate}")
    name=$(jq -r '.name // empty' <<<"${certificate}")
    [[ -n "${id}" ]] || continue
    if { ((PURGE_ALL == 1)) && [[ "${name}" == easy_all-* ]]; } \
        || matches_gcore_name "${name}" \
        || grep -Fqx "${id}" "${RUNTIME_TMP}/linked-ssl"; then
        printf '%s\t%s\n' "${id}" "${name}" >>"${RUNTIME_TMP}/ssl.tsv"
    fi
done < <(gcore_json_items "${ssl_data}")

while IFS= read -r authority; do
    [[ -n "${authority}" ]] || continue
    id=$(jq -r '.id // empty' <<<"${authority}")
    name=$(jq -r '.name // empty' <<<"${authority}")
    [[ -n "${id}" ]] || continue
    if { ((PURGE_ALL == 1)) && [[ "${name}" == easy_all-* ]]; } \
        || matches_gcore_name "${name}" \
        || grep -Fqx "${id}" "${RUNTIME_TMP}/linked-ca"; then
        printf '%s\t%s\n' "${id}" "${name}" >>"${RUNTIME_TMP}/ca.tsv"
    fi
done < <(gcore_json_items "${ssl_certs}")

total=0
for file in resources groups ssl ca; do
    case "${file}" in
    resources) label="CDN Resource" ;;
    groups) label="Origin Group" ;;
    ssl) label="证书" ;;
    ca) label="Trusted CA" ;;
    esac
    while IFS=$'\t' read -r _id _name; do
        [[ -n "${_id}" ]] || continue
        total=$((total + 1))
        printf '  %-13s %s\n' "${label}" "${_name}"
    done <"${RUNTIME_TMP}/${file}.tsv"
done

if ((total == 0)); then
    info "没有匹配到 easy_all 托管的 Gcore 资源"
    exit 0
fi

info "以上 ${total} 个 Gcore CDN 对象将被删除（不会删除 DNS 记录与 Managed DNS Zone）"
if ((ASSUME_YES == 0)); then
    [[ -t 0 ]] || die "非交互模式必须加 --yes 才能删除"
    read_prompt '确认删除？[y/N]: ' _answer
    [[ "${_answer}" =~ ^[Yy]$ ]] || die "已取消"
fi

failures=0
purge() {
    local kind=$1 label=$2 path=$3 id=$4
    if (gcore_api_delete_optional "${path}" >/dev/null); then
        success "已删除 ${kind}：${label}"
    else
        warn "删除失败 ${kind}：${label}（id=${id}）"
        failures=$((failures + 1))
    fi
}

while IFS=$'\t' read -r id cname; do
    [[ -n "${id}" ]] || continue
    purge "CDN Resource" "${cname}" "/cdn/resources/${id}" "${id}"
done <"${RUNTIME_TMP}/resources.tsv"
while IFS=$'\t' read -r id name; do
    [[ -n "${id}" ]] || continue
    purge "Origin Group" "${name}" "/cdn/origin_groups/${id}" "${id}"
done <"${RUNTIME_TMP}/groups.tsv"
while IFS=$'\t' read -r id name; do
    [[ -n "${id}" ]] || continue
    purge "证书" "${name}" "/cdn/sslData/${id}" "${id}"
done <"${RUNTIME_TMP}/ssl.tsv"
while IFS=$'\t' read -r id name; do
    [[ -n "${id}" ]] || continue
    purge "Trusted CA" "${name}" "/cdn/sslCertificates/${id}" "${id}"
done <"${RUNTIME_TMP}/ca.tsv"

((failures == 0)) || die "有 ${failures} 个对象删除失败；可修复后重试同一命令"
success "Gcore 清理完成：${total} 个对象"
