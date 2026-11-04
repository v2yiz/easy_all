#!/usr/bin/env bash

# Local-only origin certificate validation for Gcore CDN profiles.

gcore_origin_validation_error() {
    printf 'Gcore origin validation failed: %s\n' "$*" >&2
}

gcore_origin_system_ca_file() {
    local trust_file="/etc/ssl/certs/ca-certificates.crt"
    [[ -f "${trust_file}" && -r "${trust_file}" && -s "${trust_file}" ]] || return 1
    printf '%s' "${trust_file}"
}

_gcore_origin_validation_openssl() {
    local candidate executable version help required
    candidate=$(command -v openssl 2>/dev/null) || {
        gcore_origin_validation_error "需要 OpenSSL 3 的隔离根库与主机名验证能力"
        return 1
    }
    [[ -n "${candidate}" && -x "${candidate}" ]] || {
        gcore_origin_validation_error "需要 OpenSSL 3 的隔离根库与主机名验证能力"
        return 1
    }
    executable="$(cd -- "$(dirname -- "${candidate}")" >/dev/null 2>&1 && pwd -P)/$(basename -- "${candidate}")"
    version=$("${executable}" version 2>/dev/null) || {
        gcore_origin_validation_error "无法读取 OpenSSL 版本"
        return 1
    }
    case "${version}" in
    OpenSSL\ 3.*) ;;
    *)
        gcore_origin_validation_error "需要 OpenSSL 3 的隔离根库与主机名验证能力（当前：${version}）"
        return 1
        ;;
    esac
    help=$("${executable}" verify -help 2>&1) || true
    for required in \
        -trusted -untrusted -verify_hostname -purpose \
        -no-CAfile -no-CApath -no-CAstore -check_ss_sig; do
        case "${help}" in
        *"${required}"*) ;;
        *)
            gcore_origin_validation_error "需要 OpenSSL 3 的隔离根库与主机名验证能力（缺少 ${required}）"
            return 1
            ;;
        esac
    done
    printf '%s' "${executable}"
}

_gcore_origin_validation_split_pem() {
    local input=$1 output_dir=$2 strict=$3 count_file count
    count_file="${output_dir}/certificate-count"
    rm -f -- "${count_file}"
    awk -v output_dir="${output_dir}" -v strict_input="${strict}" \
        -v count_file="${count_file}" '
        function certificate_path(number) {
            return output_dir "/part-" sprintf("%04d.pem", number)
        }
        BEGIN {
            rc = 0
            in_certificate = 0
            count = 0
        }
        {
            line = $0
            sub(/\r$/, "", line)
            if (line == "-----BEGIN TRUSTED CERTIFICATE-----" ||
                line == "-----END TRUSTED CERTIFICATE-----") {
                rc = 2
                exit rc
            }
            if (line == "-----BEGIN CERTIFICATE-----") {
                if (in_certificate) {
                    rc = 3
                    exit rc
                }
                count++
                path = certificate_path(count)
                print line > path
                in_certificate = 1
                next
            }
            if (line == "-----END CERTIFICATE-----") {
                if (!in_certificate) {
                    rc = 4
                    exit rc
                }
                print line >> path
                close(path)
                in_certificate = 0
                next
            }
            if (in_certificate) {
                print line >> path
                next
            }
            if (strict_input == "1" && line !~ /^[[:space:]]*$/) {
                rc = 5
                exit rc
            }
        }
        END {
            if (rc == 0 && in_certificate)
                rc = 6
            if (rc == 0 && count == 0)
                rc = 7
            if (rc == 0)
                printf "%d\n", count > count_file
            if (rc != 0)
                exit rc
        }
    ' "${input}" >/dev/null 2>&1 || return 1
    [[ -s "${count_file}" ]] || return 1
    read -r count <"${count_file}" || return 1
    [[ "${count}" =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s' "${count}"
}

_gcore_origin_validation_normalize_pem() {
    local openssl=$1 input=$2 output=$3 temporary="${3}.tmp"
    rm -f -- "${temporary}"
    "${openssl}" x509 -in "${input}" -out "${temporary}" >/dev/null 2>&1 || {
        rm -f -- "${temporary}"
        return 1
    }
    [[ -s "${temporary}" ]] || {
        rm -f -- "${temporary}"
        return 1
    }
    mv -f -- "${temporary}" "${output}" || return 1
}

# The OpenSSL purpose check accepts a CA that also carries serverAuth and a
# matching SAN, so the first certificate is rejected unless its
# basicConstraints attribute is readable and explicitly says CA:FALSE.
_gcore_origin_validation_check_leaf_not_ca() {
    local openssl=$1 leaf=$2 details constraints
    details=$("${openssl}" x509 -in "${leaf}" -noout -text 2>/dev/null) || return 1
    [[ -n "${details}" ]] || return 1
    constraints=$(printf '%s\n' "${details}" | awk '
        /^[[:space:]]*CA:TRUE/ { print "ca"; exit }
        /^[[:space:]]*CA:FALSE/ { print "leaf"; exit }
    ') || return 1
    [[ "${constraints}" == "leaf" ]]
}

_gcore_origin_validation_hash() {
    local openssl=$1 certificate=$2 der=$3 digest
    rm -f -- "${der}"
    "${openssl}" x509 -in "${certificate}" -outform DER -out "${der}" >/dev/null 2>&1 \
        || return 1
    digest=$("${openssl}" dgst -sha256 "${der}" 2>/dev/null) || return 1
    digest=${digest##* }
    [[ "${digest}" =~ ^[0-9a-fA-F]{64}$ ]] || return 1
    printf '%s' "${digest}"
}

_gcore_origin_validation_build_untrusted() {
    local list=$1 candidates_dir=$2 output=$3 exclude=${4:-}
    local index hash candidate
    rm -f -- "${output}"
    while read -r index hash; do
        [[ -n "${index}" && -n "${hash}" ]] || return 1
        [[ -n "${exclude}" && "${index}" == "${exclude}" ]] && continue
        candidate="${candidates_dir}/candidate-${index}.pem"
        [[ -s "${candidate}" ]] || return 1
        cat "${candidate}" >>"${output}" || return 1
    done <"${list}"
    [[ -s "${output}" ]] || rm -f -- "${output}"
    return 0
}

_gcore_origin_validation_verify() {
    local openssl=$1 leaf=$2 root=$3 untrusted=$4 origin_host=$5
    if [[ -s "${untrusted}" ]]; then
        "${openssl}" verify -no-CAfile -no-CApath -no-CAstore \
            -trusted "${root}" -untrusted "${untrusted}" \
            -purpose sslserver -verify_hostname "${origin_host}" \
            -check_ss_sig "${leaf}" >/dev/null 2>&1
    else
        "${openssl}" verify -no-CAfile -no-CApath -no-CAstore \
            -trusted "${root}" \
            -purpose sslserver -verify_hostname "${origin_host}" \
            -check_ss_sig "${leaf}" >/dev/null 2>&1
    fi
}

_gcore_origin_validation_remove_candidate() {
    local list=$1 index=$2
    local next="${list}.next"
    local current_index current_hash
    : >"${next}" || return 1
    while read -r current_index current_hash; do
        [[ -n "${current_index}" && -n "${current_hash}" ]] || return 1
        [[ "${current_index}" == "${index}" ]] && continue
        printf '%s %s\n' "${current_index}" "${current_hash}" >>"${next}" || return 1
    done <"${list}"
    mv -f -- "${next}" "${list}"
}

gcore_build_origin_trusted_ca() {
    local fullchain_file=${1:-} origin_host=${2:-} output_pem=${3:-}
    local openssl trust_file runtime_root output_dir output_name work result output_tmp
    local fullchain_snapshot roots_snapshot leaf_part leaf candidates_dir roots_dir hashes_dir
    local count index hash normalized der candidate_file root_file root_hash selected_root_hash
    local untrusted remaining removed final_ok available_root

    [[ -n "${fullchain_file}" && -n "${origin_host}" && -n "${output_pem}" ]] || {
        gcore_origin_validation_error "缺少 fullchain、主机名或输出路径"
        return 1
    }
    [[ -f "${fullchain_file}" && -r "${fullchain_file}" && -s "${fullchain_file}" ]] || {
        gcore_origin_validation_error "fullchain 不存在、不可读或为空"
        return 1
    }
    [[ -d "${RUNTIME_TMP:-}" && -w "${RUNTIME_TMP}" ]] || {
        gcore_origin_validation_error "RUNTIME_TMP 不可用"
        return 1
    }
    runtime_root=$(cd -- "${RUNTIME_TMP}" >/dev/null 2>&1 && pwd -P) || {
        gcore_origin_validation_error "RUNTIME_TMP 不可用"
        return 1
    }
    output_dir=$(cd -- "$(dirname -- "${output_pem}")" >/dev/null 2>&1 && pwd -P) || {
        gcore_origin_validation_error "输出目录不可用"
        return 1
    }
    case "${output_dir}/" in
    "${runtime_root}/"*) ;;
    *)
        gcore_origin_validation_error "输出路径不在 RUNTIME_TMP 内"
        return 1
        ;;
    esac
    output_name=$(basename -- "${output_pem}")
    output_pem="${output_dir}/${output_name}"
    rm -f -- "${output_pem}" || {
        gcore_origin_validation_error "无法清除旧 CA 输出"
        return 1
    }

    openssl=$(_gcore_origin_validation_openssl) || return 1
    trust_file=$(gcore_origin_system_ca_file) || {
        gcore_origin_validation_error "固定 Debian 系统信任库不存在、不可读或为空"
        return 1
    }
    [[ -f "${trust_file}" && -r "${trust_file}" && -s "${trust_file}" ]] || {
        gcore_origin_validation_error "固定 Debian 系统信任库无效"
        return 1
    }

    work=$(mktemp -d "${runtime_root}/gcore-origin-validation.XXXXXX") || {
        gcore_origin_validation_error "无法创建工作目录"
        return 1
    }
    chmod 0700 "${work}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法保护工作目录"
        return 1
    }
    fullchain_snapshot="${work}/fullchain.pem"
    roots_snapshot="${work}/system-roots.pem"
    result="${work}/trusted-ca.pem"
    if ! cp "${fullchain_file}" "${fullchain_snapshot}" \
        || ! cp "${trust_file}" "${roots_snapshot}"; then
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法快照证书输入"
        return 1
    fi

    leaf="${work}/leaf.pem"
    candidates_dir="${work}/candidates"
    mkdir -m 0700 "${candidates_dir}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法创建 fullchain 解析目录"
        return 1
    }
    count=$(_gcore_origin_validation_split_pem "${fullchain_snapshot}" "${candidates_dir}" 1) || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "fullchain PEM 损坏、截断或混入非证书内容"
        return 1
    }
    leaf_part="${candidates_dir}/part-0001.pem"
    _gcore_origin_validation_normalize_pem "${openssl}" "${leaf_part}" "${leaf}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "源站 leaf 证书解析失败"
        return 1
    }
    _gcore_origin_validation_check_leaf_not_ca "${openssl}" "${leaf}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "源站 leaf 是 CA 证书或无法判定其 basicConstraints"
        return 1
    }

    remaining="${work}/remaining-candidates"
    : >"${remaining}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法记录 fullchain CA 候选"
        return 1
    }
    hashes_dir="${work}/candidate-hashes"
    mkdir -m 0700 "${hashes_dir}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法创建 CA 摘要目录"
        return 1
    }
    index=2
    while ((index <= count)); do
        normalized="${candidates_dir}/normalized-${index}.pem"
        der="${hashes_dir}/candidate-${index}.der"
        _gcore_origin_validation_normalize_pem \
            "${openssl}" "${candidates_dir}/part-$(printf '%04d' "${index}").pem" "${normalized}" \
            || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "fullchain CA 证书解析失败"
            return 1
        }
        hash=$(_gcore_origin_validation_hash "${openssl}" "${normalized}" "${der}") || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "fullchain CA 摘要计算失败"
            return 1
        }
        candidate_file="${candidates_dir}/candidate-${index}.pem"
        if [[ ! -f "${candidate_file}" ]]; then
            cp "${normalized}" "${candidate_file}" || {
                rm -rf -- "${work}" || true
                gcore_origin_validation_error "无法保存 CA 候选"
                return 1
            }
            printf '%s %s\n' "${index}" "${hash}" >>"${remaining}" || {
                rm -rf -- "${work}" || true
                gcore_origin_validation_error "无法记录 CA 候选"
                return 1
            }
        fi
        index=$((index + 1))
    done
    untrusted="${work}/untrusted.pem"
    _gcore_origin_validation_build_untrusted "${remaining}" "${candidates_dir}" "${untrusted}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法组装 fullchain CA 候选"
        return 1
    }

    roots_dir="${work}/roots"
    mkdir -m 0700 "${roots_dir}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法创建系统根解析目录"
        return 1
    }
    count=$(_gcore_origin_validation_split_pem "${roots_snapshot}" "${roots_dir}" 0) || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "系统根库 PEM 损坏"
        return 1
    }
    root_file="${work}/root-hashes"
    : >"${root_file}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法记录系统根"
        return 1
    }
    index=1
    while ((index <= count)); do
        normalized="${roots_dir}/normalized-${index}.pem"
        der="${roots_dir}/root-${index}.der"
        _gcore_origin_validation_normalize_pem \
            "${openssl}" "${roots_dir}/part-$(printf '%04d' "${index}").pem" "${normalized}" \
            || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "系统根证书解析失败"
            return 1
        }
        if ! "${openssl}" verify -no-CApath -no-CAstore -CAfile "${normalized}" \
            -purpose any -check_ss_sig "${normalized}" >/dev/null 2>&1; then
            index=$((index + 1))
            continue
        fi
        root_hash=$(_gcore_origin_validation_hash "${openssl}" "${normalized}" "${der}") || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "系统根摘要计算失败"
            return 1
        }
        if [[ ! -f "${roots_dir}/${root_hash}.pem" ]]; then
            cp "${normalized}" "${roots_dir}/${root_hash}.pem" || {
                rm -rf -- "${work}" || true
                gcore_origin_validation_error "无法保存系统根"
                return 1
            }
        fi
        printf '%s\n' "${root_hash}" >>"${root_file}" || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "无法记录系统根"
            return 1
        }
        index=$((index + 1))
    done
    LC_ALL=C sort -u "${root_file}" -o "${root_file}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法规范化系统根顺序"
        return 1
    }
    [[ -s "${root_file}" ]] || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "固定系统信任库中没有有效自签根"
        return 1
    }

    selected_root_hash=""
    available_root=0
    while read -r root_hash; do
        [[ -n "${root_hash}" ]] || continue
        available_root=1
        candidate_file="${roots_dir}/${root_hash}.pem"
        [[ -s "${candidate_file}" ]] || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "系统根材料缺失"
            return 1
        }
        if _gcore_origin_validation_verify \
            "${openssl}" "${leaf}" "${candidate_file}" "${untrusted}" "${origin_host}"; then
            selected_root_hash=${root_hash}
            break
        fi
    done <"${root_file}"
    ((available_root == 1)) || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "固定系统信任库中没有可尝试的自签根"
        return 1
    }
    [[ -n "${selected_root_hash}" ]] || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "源站证书无法用固定系统根闭合有效链"
        return 1
    }

    while read -r index hash; do
        if [[ "${hash}" == "${selected_root_hash}" ]]; then
            _gcore_origin_validation_remove_candidate "${remaining}" "${index}" || {
                rm -rf -- "${work}" || true
                gcore_origin_validation_error "无法移除重复系统根"
                return 1
            }
            break
        fi
    done <"${remaining}"

    while :; do
        removed=0
        while read -r index hash; do
            _gcore_origin_validation_build_untrusted \
                "${remaining}" "${candidates_dir}" "${untrusted}" "${index}" || {
                rm -rf -- "${work}" || true
                gcore_origin_validation_error "无法组装裁剪候选"
                return 1
            }
            if _gcore_origin_validation_verify \
                "${openssl}" "${leaf}" "${roots_dir}/${selected_root_hash}.pem" \
                "${untrusted}" "${origin_host}"; then
                _gcore_origin_validation_remove_candidate "${remaining}" "${index}" || {
                    rm -rf -- "${work}" || true
                    gcore_origin_validation_error "无法移除无关 fullchain CA"
                    return 1
                }
                removed=1
                break
            fi
        done <"${remaining}"
        ((removed == 1)) || break
    done

    _gcore_origin_validation_build_untrusted "${remaining}" "${candidates_dir}" "${untrusted}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法组装最终 CA 材料"
        return 1
    }
    _gcore_origin_validation_verify \
        "${openssl}" "${leaf}" "${roots_dir}/${selected_root_hash}.pem" \
        "${untrusted}" "${origin_host}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "最终 CA 材料未通过 OpenSSL 验证"
        return 1
    }

    : >"${result}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法创建 CA 输出"
        return 1
    }
    while read -r index hash; do
        candidate_file="${candidates_dir}/candidate-${index}.pem"
        [[ -s "${candidate_file}" ]] || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "最终 CA 候选缺失"
            return 1
        }
        cat "${candidate_file}" >>"${result}" || {
            rm -rf -- "${work}" || true
            gcore_origin_validation_error "无法写入最终 CA 候选"
            return 1
        }
    done <"${remaining}"
    cat "${roots_dir}/${selected_root_hash}.pem" >>"${result}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法写入系统根"
        return 1
    }
    [[ -s "${result}" ]] || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "最终 CA 输出为空"
        return 1
    }
    chmod 0644 "${result}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法设置 CA 输出权限"
        return 1
    }

    output_tmp="${output_dir}/.${output_name}.tmp.$$"
    mv -f -- "${result}" "${output_tmp}" || {
        rm -rf -- "${work}" || true
        gcore_origin_validation_error "无法暂存 CA 输出"
        return 1
    }
    if ! rm -rf -- "${work}"; then
        rm -f -- "${output_tmp}" || true
        gcore_origin_validation_error "无法清理 builder 工作目录"
        return 1
    fi
    mv -f -- "${output_tmp}" "${output_pem}" || {
        rm -f -- "${output_tmp}" || true
        gcore_origin_validation_error "无法原子发布 CA 输出"
        return 1
    }
    final_ok=1
    [[ "${final_ok}" == "1" ]]
}
