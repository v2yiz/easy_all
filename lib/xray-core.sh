#!/usr/bin/env bash

# Shared, checksum-verified Xray release installation.

export XRAY_LOCATION_ASSET="${XRAY_DIR}"

# Profiles may override these before sourcing the runtime; the shared core keeps
# its own defaults so a new profile cannot leave the download unbound.
: "${XRAY_RELEASES_API:=https://api.github.com/repos/XTLS/Xray-core/releases/latest}"

xray_installed_version() {
    [[ -s "${XRAY_DIR}/version" ]] \
        && cat "${XRAY_DIR}/version" || printf 'unknown\n'
}

parse_xray_dgst_sha256() {
    awk '
        {
            line = toupper($0)
            if (line !~ /SHA256|SHA2-256/) {
                next
            }
            for (i = 1; i <= NF; i++) {
                token = $i
                gsub(/[^A-Fa-f0-9]/, "", token)
                if (length(token) == 64 && token !~ /[^A-Fa-f0-9]/) {
                    print tolower(token)
                    exit
                }
            }
        }
    ' "$1"
}

download_xray() {
    local release_file archive_url dgst_url version temp_dir archive dgst expected actual
    local asset=${XRAY_ARCHIVE:-} digest_asset version_stage
    if [[ -z "${asset}" ]]; then
        case "$(dpkg --print-architecture)" in
        amd64) asset=Xray-linux-64.zip ;;
        arm64) asset=Xray-linux-arm64-v8a.zip ;;
        *) die "Xray 下载不支持当前系统架构" ;;
        esac
    fi
    digest_asset=${XRAY_DGST:-${asset}.dgst}
    temp_dir=$(make_temp_dir) \
        || die "创建 Xray 下载临时目录失败"
    release_file="${temp_dir}/release.json"
    download_https_file "${XRAY_RELEASES_API}" "${release_file}" \
        " Xray 最新版本信息"
    version=$(jq -r '.tag_name // empty' "${release_file}")
    archive_url=$(jq -r --arg name "${asset}" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "${release_file}")
    dgst_url=$(jq -r --arg name "${digest_asset}" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "${release_file}")
    [[ "${version}" =~ ^v[0-9]+([.][0-9]+){2}$ ]] \
        || die "GitHub 返回了无效的 Xray 版本：${version:-空}"
    [[ "${archive_url}" == \
        https://github.com/XTLS/Xray-core/releases/download/*/${asset} ]] \
        || die "未找到 ${asset}"
    [[ "${dgst_url}" == \
        https://github.com/XTLS/Xray-core/releases/download/*/${digest_asset} ]] \
        || die "未找到 ${digest_asset}"
    archive="${temp_dir}/${asset}"
    dgst="${temp_dir}/${digest_asset}"
    info "正在从 GitHub 官方 Release 下载 Xray ${version}"
    download_https_file "${archive_url}" "${archive}" " Xray ${version}"
    download_https_file "${dgst_url}" "${dgst}" " Xray 校验文件"
    expected=$(parse_xray_dgst_sha256 "${dgst}")
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ -n "${expected}" ]] \
        || die "Xray SHA256 校验文件格式无效：未找到 SHA2-256 摘要"
    [[ "${expected}" == "${actual}" ]] \
        || die "Xray SHA256 校验失败：期望 ${expected}，实际 ${actual}"
    # 函数可能处于 if/|| 上下文，内部 errexit 不可靠：每一步都显式检查。
    unzip -qo "${archive}" -d "${temp_dir}/xray" \
        || die "解压 Xray 安装包失败：${archive}"
    install -d -m 0755 "${XRAY_DIR}" \
        || die "创建 Xray 安装目录失败：${XRAY_DIR}"
    install -m 0755 "${temp_dir}/xray/xray" "${XRAY_BIN}" \
        || die "安装 Xray 二进制失败：${XRAY_BIN}"
    # version 在目标目录内暂存后 rename：写失败不能截断已记录版本。暂存文件由本进程清理，
    # 因为本函数在 update-core 的子 shell 中执行，登记的 cleanup_files 父进程看不到。
    version_stage=$(mktemp "${XRAY_DIR}/.version.XXXXXX") \
        || die "创建 Xray 版本暂存文件失败：${XRAY_DIR}"
    if ! printf '%s\n' "${version}" >"${version_stage}"; then
        rm -f -- "${version_stage}" \
            || warn "无法清理 Xray 版本暂存文件：${version_stage}"
        die "写入 Xray 版本暂存文件失败：${version_stage}"
    fi
    if ! chmod 0644 "${version_stage}"; then
        rm -f -- "${version_stage}" \
            || warn "无法清理 Xray 版本暂存文件：${version_stage}"
        die "设置 Xray 版本文件权限失败：${version_stage}"
    fi
    if ! mv -f -- "${version_stage}" "${XRAY_DIR}/version"; then
        rm -f -- "${version_stage}" \
            || warn "无法清理 Xray 版本暂存文件：${version_stage}"
        die "发布 Xray 版本文件失败：${XRAY_DIR}/version"
    fi
}

install_xray_service() {
    cat >"${RUNTIME_TMP}/easy_all-xray.service" <<EOF
[Unit]
Description=${XRAY_SERVICE_DESCRIPTION:-Xray managed by easy_all}
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
Environment=XRAY_LOCATION_ASSET=${XRAY_DIR}
Environment=GOMEMLIMIT=128MiB
Environment=GODEBUG=madvdontneed=1
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-xray.service" "${XRAY_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${XRAY_SERVICE}" >/dev/null || die "启动 Xray 服务失败"
}
