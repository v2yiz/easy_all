#!/usr/bin/env bash

# 锁定的 sing-box 版本、官方归档与代码内固定的 SHA256 校验（design §6）。
# sing-box 官方不发布 checksums 清单：摘要必须随版本更新从官方归档重新计算并随代码审查，
# 不能把下载内容自身摘要当成可信期望。

if [[ "${EASY_ALL_SINGBOX_CORE_LOADED:-0}" != "1" ]]; then
    EASY_ALL_SINGBOX_CORE_LOADED=1

    readonly SINGBOX_VERSION="1.14.4"
    readonly SINGBOX_SHA256_AMD64="699a1b510aa4396b2176d32d1181920399ebf1e267835da6f3b598d0f7c24968"
    readonly SINGBOX_SHA256_ARM64="436441f76ee2f7fe21b5b2d426d3cb261a480455a704865789ad533e4273ec26"
    readonly SINGBOX_RELEASE_BASE="https://github.com/SagerNet/sing-box/releases/download"
    # 运行路径允许环境变量覆盖：测试与隔离验收不得写系统目录。
    : "${SINGBOX_BIN:=/etc/easy_all/sing-box/sing-box}"
    : "${SINGBOX_CONFIG:=/etc/easy_all/sing-box/config.json}"
    : "${SINGBOX_SERVICE_FILE:=/etc/systemd/system/easy_all-singbox.service}"
    : "${SINGBOX_SERVICE:=easy_all-singbox.service}"

    singbox_version() {
        printf '%s\n' "${SINGBOX_VERSION}"
    }

    singbox_arch() {
        case "${1:-$(uname -m)}" in
        x86_64 | amd64) printf 'amd64\n' ;;
        aarch64 | arm64) printf 'arm64\n' ;;
        *) die "sing-box 下载不支持当前系统架构：${1:-$(uname -m)}" ;;
        esac
    }

    singbox_expected_sha256() {
        case "${1:-$(singbox_arch)}" in
        amd64) printf '%s\n' "${SINGBOX_SHA256_AMD64}" ;;
        arm64) printf '%s\n' "${SINGBOX_SHA256_ARM64}" ;;
        *) die "没有锁定架构的 sing-box SHA256：${1:-}" ;;
        esac
    }

    singbox_archive_url() {
        local arch=${1:-$(singbox_arch)}
        printf '%s/v%s/sing-box-%s-linux-%s.tar.gz\n' \
            "${SINGBOX_RELEASE_BASE}" "${SINGBOX_VERSION}" "${SINGBOX_VERSION}" "${arch}"
    }

    # 归档内二进制的第一行是 `sing-box version <版本>`；解析失败返回空串。
    singbox_binary_version() {
        local bin=$1 output
        [[ -x "${bin}" ]] || return 1
        output=$("${bin}" version 2>/dev/null \
            | awk 'NR == 1 && $1 == "sing-box" && $2 == "version" {print $3}') || true
        [[ -n "${output}" ]] || return 1
        printf '%s\n' "${output}"
    }

    singbox_installed_version() {
        local version
        if version=$(singbox_binary_version "${SINGBOX_BIN}"); then
            printf '%s\n' "${version}"
        else
            printf 'unknown\n'
        fi
    }

    singbox_sha256_file() {
        local digest
        digest=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}' \
            | tr '[:upper:]' '[:lower:]') || return 1
        [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s\n' "${digest}"
    }

    # 下载 → 固定摘要校验 → 解压 → 候选版本自检 → 原子安装。
    # 任一步失败都在替换前退出，已安装的旧二进制保持不变；失败信息不含下载内容。
    download_singbox() {
        local arch expected url temp_dir archive candidate actual stage
        [[ -n "${RUNTIME_TMP:-}" ]] || die "运行时临时目录未初始化，无法下载 sing-box"
        arch=$(singbox_arch) || die "无法确定 sing-box 下载架构"
        # 摘要比较不区分大小写：固定常量与归档摘要都先规范化为小写。
        expected=$(singbox_expected_sha256 "${arch}" | tr '[:upper:]' '[:lower:]') || exit 1
        url=$(singbox_archive_url "${arch}")
        temp_dir=$(mktemp -d "${RUNTIME_TMP}/sing-box.XXXXXX") \
            || die "创建 sing-box 下载临时目录失败"
        archive="${temp_dir}/sing-box-${SINGBOX_VERSION}-linux-${arch}.tar.gz"
        info "正在下载 sing-box ${SINGBOX_VERSION}（${arch}）"
        # GitHub release 资产地址通过 302 重定向到实际文件：必须 -L 跟随，且只允许
        # 重定向到 HTTPS（保留 --proto '=https'），否则拿不到归档或降级到明文。
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 600 --retry 2 \
            -o "${archive}" "${url}" \
            || die "下载 sing-box 归档失败：${url}"
        [[ -s "${archive}" ]] || die "下载 sing-box 归档失败：返回空文件"
        actual=$(singbox_sha256_file "${archive}") \
            || die "计算 sing-box 归档 SHA256 失败：${archive}"
        [[ "${actual}" == "${expected}" ]] \
            || die "sing-box SHA256 校验失败：期望 ${expected}，实际 ${actual}"
        mkdir -p "${temp_dir}/tree" || die "创建 sing-box 解压目录失败：${temp_dir}/tree"
        tar -xzf "${archive}" -C "${temp_dir}/tree" \
            || die "解压 sing-box 归档失败：${archive}"
        candidate=$(find "${temp_dir}/tree" -type f -name sing-box | head -n 1)
        [[ -n "${candidate}" ]] || die "sing-box 归档中缺少 sing-box 可执行文件"
        chmod 0755 "${candidate}" || die "设置 sing-box 候选文件权限失败：${candidate}"
        [[ "$(singbox_binary_version "${candidate}")" == "${SINGBOX_VERSION}" ]] \
            || die "候选 sing-box 版本自检失败：期望 ${SINGBOX_VERSION}"
        install -d -m 0755 "$(dirname "${SINGBOX_BIN}")" \
            || die "创建 sing-box 安装目录失败：$(dirname "${SINGBOX_BIN}")"
        # 同目录暂存后 rename：替换是原子的，安装中途失败不会留下半个二进制。
        stage=$(mktemp "${SINGBOX_BIN}.XXXXXX") \
            || die "创建 sing-box 安装暂存文件失败：$(dirname "${SINGBOX_BIN}")"
        if ! install -m 0755 "${candidate}" "${stage}"; then
            rm -f -- "${stage}"
            die "写入 sing-box 安装暂存文件失败：${stage}"
        fi
        if ! mv -f -- "${stage}" "${SINGBOX_BIN}"; then
            rm -f -- "${stage}"
            die "发布 sing-box 二进制失败：${SINGBOX_BIN}"
        fi
        rm -rf -- "${temp_dir}"
        success "sing-box ${SINGBOX_VERSION} 已安装：${SINGBOX_BIN}"
    }

    # ExecStartPre 由计量准备入口填入；空表示本单元没有前置步骤。
    install_singbox_service() {
        local exec_start_pre=${1:-} stage
        install -d -m 0755 "$(dirname "${SINGBOX_SERVICE_FILE}")" \
            || die "创建 systemd 单元目录失败：$(dirname "${SINGBOX_SERVICE_FILE}")"
        stage=$(mktemp "${SINGBOX_SERVICE_FILE}.XXXXXX") \
            || die "创建 sing-box 单元暂存文件失败：${SINGBOX_SERVICE_FILE}"
        if ! {
            printf '[Unit]\n'
            printf 'Description=sing-box managed by easy_all\n'
            printf 'Documentation=https://github.com/SagerNet/sing-box\n'
            printf 'After=network-online.target\n'
            printf 'Wants=network-online.target\n'
            printf 'StartLimitIntervalSec=120\n'
            printf 'StartLimitBurst=3\n'
            printf '\n[Service]\n'
            printf 'Type=simple\n'
            printf 'User=root\n'
            [[ -z "${exec_start_pre}" ]] || printf 'ExecStartPre=%s\n' "${exec_start_pre}"
            printf 'ExecStart=%s run -c %s\n' "${SINGBOX_BIN}" "${SINGBOX_CONFIG}"
            printf 'Restart=on-failure\n'
            printf 'RestartSec=10s\n'
            printf 'TimeoutStartSec=30s\n'
            printf 'LimitNOFILE=1048576\n'
            printf '\n[Install]\n'
            printf 'WantedBy=multi-user.target\n'
        } >"${stage}"; then
            rm -f -- "${stage}"
            die "写入 sing-box 单元暂存文件失败：${stage}"
        fi
        if ! { chmod 0644 "${stage}" && mv -f -- "${stage}" "${SINGBOX_SERVICE_FILE}"; }; then
            rm -f -- "${stage}"
            die "发布 sing-box 服务单元失败：${SINGBOX_SERVICE_FILE}"
        fi
    }
fi
