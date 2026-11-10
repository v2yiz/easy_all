#!/usr/bin/env bash

# 锁定的 Caddy 版本、官方归档与 SHA512 清单校验（design §6）。
# Caddy 官方发布 caddy_<版本>_checksums.txt：摘要取自清单中与本机架构归档精确匹配的唯一一条，
# 必须先校验再解压执行。

if [[ "${EASY_ALL_CADDY_CORE_LOADED:-0}" != "1" ]]; then
    EASY_ALL_CADDY_CORE_LOADED=1

    readonly CADDY_VERSION="2.11.9"
    readonly CADDY_SHA512_AMD64="0e85544340290a16ce4bfb76fe7d65e9de1bf3a6e67f5ccfff30b30d27ea4c73e078077b7bf3e58ae60b6b12e44327705287059c775bca5782e8ee85ea7edd75"
    readonly CADDY_SHA512_ARM64="9e5e76d7888542924de2c25353ae87c5f77e2a22c5b1198633cae13688922282e05383d142599205c88d8d80eee5e967d291214d7abce4835329a191b20dd6e0"
    readonly CADDY_RELEASE_BASE="https://github.com/caddyserver/caddy/releases/download"
    # Caddy 官方清单里的摘要必须与本文件固定的常量一致：清单本身同样来自官方发布账户，
    # 单独比对清单只能发现传输错误，不能把清单当成独立信任根。
    : "${CADDY_BIN:=/etc/easy_all/caddy/caddy}"
    : "${CADDY_CONFIG:=/etc/easy_all/caddy/Caddyfile}"
    : "${CADDY_SERVICE_FILE:=/etc/systemd/system/easy_all-caddy.service}"
    : "${CADDY_SERVICE:=easy_all-caddy.service}"

    caddy_version() {
        printf '%s\n' "${CADDY_VERSION}"
    }

    caddy_arch() {
        case "${1:-$(uname -m)}" in
        x86_64 | amd64) printf 'amd64\n' ;;
        aarch64 | arm64) printf 'arm64\n' ;;
        *) die "Caddy 下载不支持当前系统架构：${1:-$(uname -m)}" ;;
        esac
    }

    caddy_archive_name() {
        printf 'caddy_%s_linux_%s.tar.gz\n' "${CADDY_VERSION}" "${1:-$(caddy_arch)}"
    }

    caddy_archive_url() {
        local arch=${1:-$(caddy_arch)}
        printf '%s/v%s/%s\n' "${CADDY_RELEASE_BASE}" "${CADDY_VERSION}" "$(caddy_archive_name "${arch}")"
    }

    caddy_checksums_url() {
        printf '%s/v%s/caddy_%s_checksums.txt\n' \
            "${CADDY_RELEASE_BASE}" "${CADDY_VERSION}" "${CADDY_VERSION}"
    }

    caddy_expected_sha512() {
        case "${1:-$(caddy_arch)}" in
        amd64) printf '%s\n' "${CADDY_SHA512_AMD64}" ;;
        arm64) printf '%s\n' "${CADDY_SHA512_ARM64}" ;;
        *) die "没有锁定架构的 Caddy SHA512：${1:-}" ;;
        esac
    }

    # 归档第一行是 `v2.11.9 h1:...`；解析失败返回非零。
    caddy_binary_version() {
        local bin=$1 output
        [[ -x "${bin}" ]] || return 1
        output=$("${bin}" version 2>/dev/null | awk 'NR == 1 {print $1}') || true
        [[ -n "${output}" ]] || return 1
        printf '%s\n' "${output}"
    }

    caddy_installed_version() {
        local version
        if version=$(caddy_binary_version "${CADDY_BIN}"); then
            printf '%s\n' "${version}"
        else
            printf 'unknown\n'
        fi
    }

    caddy_sha512_file() {
        local digest
        digest=$(openssl dgst -sha512 "$1" 2>/dev/null | awk '{print $NF}' \
            | tr '[:upper:]' '[:lower:]') || return 1
        [[ "${digest}" =~ ^[0-9a-f]{128}$ ]] || return 1
        printf '%s\n' "${digest}"
    }

    # 清单里必须恰好一条精确文件名条目，且摘要是合法的 128 位十六进制。
    caddy_checksums_sha512() {
        local file=$1 name=$2 matched count digest
        [[ -s "${file}" ]] || die "Caddy SHA512 清单为空：${file}"
        matched=$(awk -v name="${name}" '
            NF >= 2 {
                filename = $NF
                sub(/^\*/, "", filename)
                if (filename != name) next
                print $1
            }
        ' "${file}") || die "读取 Caddy SHA512 清单失败：${file}"
        count=$(printf '%s\n' "${matched}" | grep -c . || true)
        [[ "${count}" == "1" ]] \
            || die "Caddy SHA512 清单中 ${name} 的条目数不是 1（实际 ${count:-0}）"
        digest=$(printf '%s\n' "${matched}" | tr '[:upper:]' '[:lower:]')
        [[ "${digest}" =~ ^[0-9a-f]{128}$ ]] \
            || die "Caddy SHA512 清单中 ${name} 的摘要格式无效"
        printf '%s\n' "${digest}"
    }

    # 下载清单与归档 → 精确条目校验 → 解压 → 候选版本自检 → 原子安装。
    # 清单缺失/重复/格式错/摘要不符都在替换前退出，已安装的旧二进制保持不变。
    download_caddy() {
        local arch archive_name checksums archive temp_dir expected actual candidate stage frozen
        [[ -n "${RUNTIME_TMP:-}" ]] || die "运行时临时目录未初始化，无法下载 Caddy"
        arch=$(caddy_arch) || die "无法确定 Caddy 下载架构"
        archive_name=$(caddy_archive_name "${arch}")
        frozen=$(caddy_expected_sha512 "${arch}") || exit 1
        temp_dir=$(mktemp -d "${RUNTIME_TMP}/caddy.XXXXXX") \
            || die "创建 Caddy 下载临时目录失败"
        checksums="${temp_dir}/caddy_${CADDY_VERSION}_checksums.txt"
        info "正在下载 Caddy ${CADDY_VERSION}（${arch}）"
        # GitHub release 资产地址通过 302 重定向到实际文件：必须 -L 跟随，且只允许
        # 重定向到 HTTPS（design §6），清单与归档都适用。
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 120 --retry 2 \
            -o "${checksums}" "$(caddy_checksums_url)" \
            || die "下载 Caddy 校验清单失败：$(caddy_checksums_url)"
        expected=$(caddy_checksums_sha512 "${checksums}" "${archive_name}") || exit 1
        [[ "${expected}" == "${frozen}" ]] \
            || die "Caddy 摘要来源不一致：${archive_name} 的官方清单值为 ${expected}，代码锁定常量为 ${frozen}；请人工核对后同步常量"
        archive="${temp_dir}/${archive_name}"
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 600 --retry 2 \
            -o "${archive}" "$(caddy_archive_url "${arch}")" \
            || die "下载 Caddy 归档失败：$(caddy_archive_url "${arch}")"
        [[ -s "${archive}" ]] || die "下载 Caddy 归档失败：返回空文件"
        actual=$(caddy_sha512_file "${archive}") \
            || die "计算 Caddy 归档 SHA512 失败：${archive}"
        [[ "${actual}" == "${expected}" ]] \
            || die "Caddy SHA512 校验失败：期望 ${expected}，实际 ${actual}"
        mkdir -p "${temp_dir}/tree" || die "创建 Caddy 解压目录失败：${temp_dir}/tree"
        tar -xzf "${archive}" -C "${temp_dir}/tree" \
            || die "解压 Caddy 归档失败：${archive}"
        candidate=$(find "${temp_dir}/tree" -type f -name caddy | head -n 1)
        [[ -n "${candidate}" ]] || die "Caddy 归档中缺少 caddy 可执行文件"
        chmod 0755 "${candidate}" || die "设置 Caddy 候选文件权限失败：${candidate}"
        [[ "$(caddy_binary_version "${candidate}")" == "v${CADDY_VERSION}" ]] \
            || die "候选 Caddy 版本自检失败：期望 v${CADDY_VERSION}"
        install -d -m 0755 "$(dirname "${CADDY_BIN}")" \
            || die "创建 Caddy 安装目录失败：$(dirname "${CADDY_BIN}")"
        stage=$(mktemp "${CADDY_BIN}.XXXXXX") \
            || die "创建 Caddy 安装暂存文件失败：$(dirname "${CADDY_BIN}")"
        if ! install -m 0755 "${candidate}" "${stage}"; then
            rm -f -- "${stage}"
            die "写入 Caddy 安装暂存文件失败：${stage}"
        fi
        if ! mv -f -- "${stage}" "${CADDY_BIN}"; then
            rm -f -- "${stage}"
            die "发布 Caddy 二进制失败：${CADDY_BIN}"
        fi
        rm -rf -- "${temp_dir}"
        success "Caddy ${CADDY_VERSION} 已安装：${CADDY_BIN}"
    }

    # systemd 在 ExecStartPre/ExecStart 前创建 /run/easy_all-caddy（0600 管理套接字所在），
    # 不暴露 TCP 管理端口；本函数不启停服务。
    install_caddy_service() {
        local stage
        install -d -m 0755 "$(dirname "${CADDY_SERVICE_FILE}")" \
            || die "创建 systemd 单元目录失败：$(dirname "${CADDY_SERVICE_FILE}")"
        stage=$(mktemp "${CADDY_SERVICE_FILE}.XXXXXX") \
            || die "创建 Caddy 单元暂存文件失败：${CADDY_SERVICE_FILE}"
        if ! {
            printf '[Unit]\n'
            printf 'Description=Caddy managed by easy_all\n'
            printf 'Documentation=https://caddyserver.com/docs/\n'
            printf 'After=network-online.target\n'
            printf 'Wants=network-online.target\n'
            printf 'StartLimitIntervalSec=120\n'
            printf 'StartLimitBurst=3\n'
            printf '\n[Service]\n'
            printf 'Type=simple\n'
            printf 'User=root\n'
            printf 'RuntimeDirectory=easy_all-caddy\n'
            printf 'RuntimeDirectoryMode=0700\n'
            printf 'ExecStart=%s run --config %s --adapter caddyfile\n' \
                "${CADDY_BIN}" "${CADDY_CONFIG}"
            printf 'Restart=on-failure\n'
            printf 'RestartSec=10s\n'
            printf 'TimeoutStartSec=30s\n'
            printf 'LimitNOFILE=1048576\n'
            printf '\n[Install]\n'
            printf 'WantedBy=multi-user.target\n'
        } >"${stage}"; then
            rm -f -- "${stage}"
            die "写入 Caddy 单元暂存文件失败：${stage}"
        fi
        if ! { chmod 0644 "${stage}" && mv -f -- "${stage}" "${CADDY_SERVICE_FILE}"; }; then
            rm -f -- "${stage}"
            die "发布 Caddy 服务单元失败：${CADDY_SERVICE_FILE}"
        fi
    }
fi
