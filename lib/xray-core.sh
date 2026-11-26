#!/usr/bin/env bash

# Xray-core 最新官方 Release 下载、.dgst SHA2-256 校验与服务单元。
# 与 sing-box（为避免不兼容配置变更而锁定版本）不同，Xray-core 始终追踪最新官方
# Release：先通过 GitHub `/releases/latest` 跳转解析唯一版本标签，再从同一版本路径
# 下载 `<asset>.dgst` 与归档，核对 SHA2-256 与候选二进制版本号后原子替换。

if [[ "${EASY_ALL_XRAY_CORE_LOADED:-0}" != "1" ]]; then
    EASY_ALL_XRAY_CORE_LOADED=1

    readonly XRAY_RELEASE_BASE="https://github.com/XTLS/Xray-core/releases/download"
    readonly XRAY_LATEST_RELEASE_URL="https://github.com/XTLS/Xray-core/releases/latest"
    # 运行路径允许环境变量覆盖：测试与隔离验收不得写系统目录。
    : "${XRAY_BIN:=/etc/easy_all/xray/xray}"
    : "${XRAY_CONFIG:=/etc/easy_all/xray/config.json}"
    : "${XRAY_SERVICE_FILE:=/etc/systemd/system/easy_all-xray.service}"
    : "${XRAY_SERVICE:=easy_all-xray.service}"

    # 仅接受正式版本号标签（vX.Y 或 vX.Y.Z），拒绝预发布/非标签跳转。
    # 走 `/releases/latest` 302 跳转而非 GitHub REST API，避免匿名 60 次/小时限流。
    xray_latest_version() {
        local effective tag
        effective=$(curl -fsSLI --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 30 --retry 2 \
            -o /dev/null -w '%{url_effective}' "${XRAY_LATEST_RELEASE_URL}") \
            || die "获取 Xray 最新版本失败：${XRAY_LATEST_RELEASE_URL}"
        effective=${effective%%\?*}
        effective=${effective%/}
        tag=${effective##*/}
        [[ "${effective}" == *"/releases/tag/"* && "${tag}" =~ ^v([0-9]+\.[0-9]+(\.[0-9]+)?)$ ]] \
            || die "无法解析 Xray 最新版本标签：${effective:-空}"
        printf '%s\n' "${BASH_REMATCH[1]}"
    }

    xray_arch() {
        case "${1:-$(uname -m)}" in
        x86_64 | amd64) printf 'amd64\n' ;;
        aarch64 | arm64) printf 'arm64\n' ;;
        *) die "Xray 下载不支持当前系统架构：${1:-$(uname -m)}" ;;
        esac
    }

    # 官方归档名按架构区分（amd64 用 -64，arm64 用 -arm64-v8a）。
    xray_archive_name() {
        case "${1:-$(xray_arch)}" in
        amd64) printf 'Xray-linux-64.zip\n' ;;
        arm64) printf 'Xray-linux-arm64-v8a.zip\n' ;;
        *) die "没有支持架构的 Xray 归档：${1:-}" ;;
        esac
    }

    xray_archive_url() {
        local arch=${1:-$(xray_arch)} version=${2:-}
        [[ -n "${version}" ]] || die "xray_archive_url 需要版本号"
        printf '%s/v%s/%s\n' "${XRAY_RELEASE_BASE}" "${version}" "$(xray_archive_name "${arch}")"
    }

    xray_digest_url() {
        local arch=${1:-$(xray_arch)} version=${2:-}
        [[ -n "${version}" ]] || die "xray_digest_url 需要版本号"
        printf '%s.dgst\n' "$(xray_archive_url "${arch}" "${version}")"
    }

    # 归档内二进制的第一行形如 `Xray 26.11.9 (Xray, Penetrates Everything.) ...`。
    xray_binary_version() {
        local bin=$1 output
        [[ -x "${bin}" ]] || return 1
        output=$("${bin}" version 2>/dev/null | awk 'NR == 1 && $1 == "Xray" {print $2}') || true
        [[ -n "${output}" ]] || return 1
        printf '%s\n' "${output}"
    }

    xray_installed_version() {
        local version
        if version=$(xray_binary_version "${XRAY_BIN}"); then
            printf '%s\n' "${version}"
        else
            printf 'unknown\n'
        fi
    }

    xray_sha256_file() {
        local digest
        digest=$(openssl dgst -sha256 "$1" 2>/dev/null | awk '{print $NF}' \
            | tr '[:upper:]' '[:lower:]') || return 1
        [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] || return 1
        printf '%s\n' "${digest}"
    }

    # .dgst 清单里必须恰好一条 SHA2-256 条目；缺失/重复/格式错都在替换前退出。
    xray_digest_sha256() {
        local file=$1 name=$2 matched count digest
        [[ -s "${file}" ]] || die "Xray .dgst 清单为空：${file}"
        matched=$(awk -F'[=[:space:]]+' '
            $1 == "SHA2-256" && NF >= 2 && $2 ~ /^[0-9a-fA-F]+$/ {print $2}
        ' "${file}") || die "读取 Xray .dgst 清单失败：${file}"
        count=$(printf '%s\n' "${matched}" | grep -c . || true)
        [[ "${count}" == "1" ]] \
            || die "Xray .dgst 清单中 ${name} 的 SHA2-256 条目数不是 1（实际 ${count:-0}）"
        digest=$(printf '%s\n' "${matched}" | tr '[:upper:]' '[:lower:]')
        [[ "${digest}" =~ ^[0-9a-f]{64}$ ]] \
            || die "Xray .dgst 清单中 ${name} 的 SHA2-256 摘要格式无效"
        printf '%s\n' "${digest}"
    }

    # 解析最新正式版标签 → 下载同版本 .dgst 与归档 → 校验 SHA2-256 → 解压 → 候选版本自检 → 原子安装。
    # 任一步失败都在替换前退出，已安装的旧二进制保持不变。
    download_xray() {
        local arch version archive_name digest_file archive expected actual temp_dir candidate stage
        [[ -n "${RUNTIME_TMP:-}" ]] || die "运行时临时目录未初始化，无法下载 Xray"
        arch=$(xray_arch) || die "无法确定 Xray 下载架构"
        version=$(xray_latest_version) || exit 1
        archive_name=$(xray_archive_name "${arch}")
        temp_dir=$(mktemp -d "${RUNTIME_TMP}/xray.XXXXXX") \
            || die "创建 Xray 下载临时目录失败"
        digest_file="${temp_dir}/${archive_name}.dgst"
        info "正在下载 Xray ${version}（${arch}，最新官方版本）"
        # GitHub release 资产地址通过 302 重定向到实际文件：必须 -L 跟随，且只允许重定向到 HTTPS。
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 120 --retry 2 \
            -o "${digest_file}" "$(xray_digest_url "${arch}" "${version}")" \
            || die "下载 Xray 校验清单失败：$(xray_digest_url "${arch}" "${version}")"
        expected=$(xray_digest_sha256 "${digest_file}" "${archive_name}") || exit 1
        archive="${temp_dir}/${archive_name}"
        curl -fsSL --proto '=https' --proto-redir '=https' \
            --connect-timeout 10 --max-time 600 --retry 2 \
            -o "${archive}" "$(xray_archive_url "${arch}" "${version}")" \
            || die "下载 Xray 归档失败：$(xray_archive_url "${arch}" "${version}")"
        [[ -s "${archive}" ]] || die "下载 Xray 归档失败：返回空文件"
        actual=$(xray_sha256_file "${archive}") \
            || die "计算 Xray 归档 SHA256 失败：${archive}"
        [[ "${actual}" == "${expected}" ]] \
            || die "Xray SHA256 校验失败：期望 ${expected}，实际 ${actual}"
        unzip -qo "${archive}" -d "${temp_dir}/tree" \
            || die "解压 Xray 归档失败：${archive}"
        candidate=$(find "${temp_dir}/tree" -type f -name xray | head -n 1)
        [[ -n "${candidate}" ]] || die "Xray 归档中缺少 xray 可执行文件"
        chmod 0755 "${candidate}" || die "设置 Xray 候选文件权限失败：${candidate}"
        [[ "$(xray_binary_version "${candidate}")" == "${version}" ]] \
            || die "候选 Xray 版本自检失败：期望 ${version}"
        install -d -m 0755 "$(dirname "${XRAY_BIN}")" \
            || die "创建 Xray 安装目录失败：$(dirname "${XRAY_BIN}")"
        stage=$(mktemp "${XRAY_BIN}.XXXXXX") \
            || die "创建 Xray 安装暂存文件失败：$(dirname "${XRAY_BIN}")"
        if ! install -m 0755 "${candidate}" "${stage}"; then
            rm -f -- "${stage}"
            die "写入 Xray 安装暂存文件失败：${stage}"
        fi
        if ! mv -f -- "${stage}" "${XRAY_BIN}"; then
            rm -f -- "${stage}"
            die "发布 Xray 二进制失败：${XRAY_BIN}"
        fi
        rm -rf -- "${temp_dir}"
        success "Xray ${version} 已安装：${XRAY_BIN}"
    }

    # Xray 需要 XRAY_LOCATION_ASSET 指向 geoip/geosite 目录；本模式零外置数据依赖，
    # 但仍显式声明安装目录，避免核心按 CWD 猜路径。
    install_xray_service() {
        local stage
        install -d -m 0755 "$(dirname "${XRAY_SERVICE_FILE}")" \
            || die "创建 systemd 单元目录失败：$(dirname "${XRAY_SERVICE_FILE}")"
        stage=$(mktemp "${XRAY_SERVICE_FILE}.XXXXXX") \
            || die "创建 Xray 单元暂存文件失败：${XRAY_SERVICE_FILE}"
        if ! {
            printf '[Unit]\n'
            printf 'Description=Xray managed by easy_all\n'
            printf 'Documentation=https://github.com/XTLS/Xray-core\n'
            printf 'After=network-online.target\n'
            printf 'Wants=network-online.target\n'
            printf 'StartLimitIntervalSec=120\n'
            printf 'StartLimitBurst=3\n'
            printf '\n[Service]\n'
            printf 'Type=simple\n'
            printf 'User=root\n'
            printf 'Environment=XRAY_LOCATION_ASSET=%s\n' "$(dirname "${XRAY_BIN}")"
            printf 'ExecStart=%s run -config %s\n' "${XRAY_BIN}" "${XRAY_CONFIG}"
            printf 'Restart=on-failure\n'
            printf 'RestartSec=10s\n'
            printf 'TimeoutStartSec=30s\n'
            printf 'LimitNOFILE=1048576\n'
            printf '\n[Install]\n'
            printf 'WantedBy=multi-user.target\n'
        } >"${stage}"; then
            rm -f -- "${stage}"
            die "写入 Xray 单元暂存文件失败：${stage}"
        fi
        if ! { chmod 0644 "${stage}" && mv -f -- "${stage}" "${XRAY_SERVICE_FILE}"; }; then
            rm -f -- "${stage}"
            die "发布 Xray 服务单元失败：${XRAY_SERVICE_FILE}"
        fi
    }
fi
