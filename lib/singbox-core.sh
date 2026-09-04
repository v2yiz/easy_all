#!/usr/bin/env bash

# Shared, checksum-verified Sing-box release installation.

if [[ "${_EASY_ALL_SINGBOX_CORE_LOADED:-0}" == "1" ]]; then
    return 0 2>/dev/null || true
fi
_EASY_ALL_SINGBOX_CORE_LOADED=1

SINGBOX_DIR="${SINGBOX_DIR_OVERRIDE:-${STATE_DIR:-/etc/easy_all}/singbox}"
SINGBOX_BIN="${SINGBOX_BIN_OVERRIDE:-${SINGBOX_DIR}/sing-box}"
SINGBOX_CONFIG="${SINGBOX_CONFIG_OVERRIDE:-${SINGBOX_DIR}/config.json}"
SINGBOX_SERVICE_FILE="/etc/systemd/system/easy_all-singbox.service"
SINGBOX_SERVICE="easy_all-singbox.service"
SINGBOX_RELEASES_API="https://api.github.com/repos/SagerNet/sing-box/releases/latest"

download_singbox() {
    local release_file archive_url sha_url version clean_version temp_dir archive sha_file expected actual
    temp_dir=$(make_temp_dir)
    release_file="${temp_dir}/release.json"
    download_https_file "${SINGBOX_RELEASES_API}" "${release_file}" \
        " Sing-box 最新版本信息"
    version=$(jq -r '.tag_name // empty' "${release_file}")
    [[ "${version}" =~ ^v?[0-9]+([.][0-9]+){2}.*$ ]] \
        || die "GitHub 返回了无效的 Sing-box 版本：${version:-空}"
    clean_version="${version#v}"

    archive_url=$(jq -r '
        .assets[]? | select(.name | test("^sing-box-.*-linux-amd64\\.tar\\.gz$")) | .browser_download_url
    ' "${release_file}" | head -n 1)
    [[ -n "${archive_url}" && "${archive_url}" == https://github.com/SagerNet/sing-box/releases/download/* ]] \
        || die "未找到适配 amd64 的 Sing-box 发布归档"

    sha_url=$(jq -r '
        .assets[]? | select(.name | test("^sing-box-.*-linux-amd64\\.tar\\.gz\\.sha256$")) | .browser_download_url
    ' "${release_file}" | head -n 1)

    archive="${temp_dir}/sing-box.tar.gz"
    info "正在从 GitHub 官方 Release 下载 Sing-box ${version}"
    download_https_file "${archive_url}" "${archive}" " Sing-box ${version}"

    if [[ -n "${sha_url}" ]]; then
        sha_file="${temp_dir}/sing-box.sha256"
        download_https_file "${sha_url}" "${sha_file}" " Sing-box 校验文件"
        expected=$(awk '{print $1; exit}' "${sha_file}")
        actual=$(sha256sum "${archive}" | awk '{print $1}')
        [[ -n "${expected}" && "${expected,,}" == "${actual,,}" ]] \
            || die "Sing-box SHA256 校验失败"
    fi

    install -d -m 0700 "${temp_dir}/extracted"
    tar -xzf "${archive}" -C "${temp_dir}/extracted" --strip-components=1 \
        || die "解压 Sing-box 归档失败"
    [[ -f "${temp_dir}/extracted/sing-box" ]] || die "解压后的 Sing-box 文件缺失"

    install -d -m 0755 "${SINGBOX_DIR}"
    install -m 0755 "${temp_dir}/extracted/sing-box" "${SINGBOX_BIN}"
    printf '%s\n' "${version}" >"${SINGBOX_DIR}/version"
}

install_singbox_service() {
    cat >"${RUNTIME_TMP}/easy_all-singbox.service" <<EOF
[Unit]
Description=${SINGBOX_SERVICE_DESCRIPTION:-Sing-box managed by easy_all}
Documentation=https://sing-box.sagernet.org
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONFIG}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-singbox.service" "${SINGBOX_SERVICE_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${SINGBOX_SERVICE}" >/dev/null || die "启动 Sing-box 服务失败"
}

update_singbox_core() {
    require_root
    [[ -x "${SINGBOX_BIN}" ]] || die "Sing-box 尚未安装"
    info "正在检查 Sing-box 核心更新"
    download_singbox
    if systemctl is-active --quiet "${SINGBOX_SERVICE}"; then
        systemctl restart "${SINGBOX_SERVICE}" || die "重启 Sing-box 服务失败"
    fi
    success "Sing-box 核心已更新至最新版本"
}
