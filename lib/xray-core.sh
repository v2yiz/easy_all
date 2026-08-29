#!/usr/bin/env bash

# Shared, checksum-verified Xray release installation.

download_xray() {
    local release_file archive_url dgst_url version temp_dir archive dgst expected actual
    temp_dir=$(make_temp_dir)
    release_file="${temp_dir}/release.json"
    download_https_file "${XRAY_RELEASES_API}" "${release_file}" \
        " Xray 最新版本信息"
    version=$(jq -r '.tag_name // empty' "${release_file}")
    archive_url=$(jq -r --arg name "${XRAY_ARCHIVE}" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "${release_file}")
    dgst_url=$(jq -r --arg name "${XRAY_DGST}" \
        '.assets[] | select(.name == $name) | .browser_download_url' \
        "${release_file}")
    [[ "${version}" =~ ^v[0-9]+([.][0-9]+){2}$ ]] \
        || die "GitHub 返回了无效的 Xray 版本：${version:-空}"
    [[ "${archive_url}" == \
        https://github.com/XTLS/Xray-core/releases/download/*/${XRAY_ARCHIVE} ]] \
        || die "未找到 ${XRAY_ARCHIVE}"
    [[ "${dgst_url}" == \
        https://github.com/XTLS/Xray-core/releases/download/*/${XRAY_DGST} ]] \
        || die "未找到 ${XRAY_DGST}"
    archive="${temp_dir}/${XRAY_ARCHIVE}"
    dgst="${temp_dir}/${XRAY_DGST}"
    info "正在从 GitHub 官方 Release 下载 Xray ${version}"
    download_https_file "${archive_url}" "${archive}" " Xray ${version}"
    download_https_file "${dgst_url}" "${dgst}" " Xray 校验文件"
    expected=$(awk '
        BEGIN { IGNORECASE = 1 }
        /SHA256|SHA2-256/ {
            for (i = 1; i <= NF; i++) {
                token = $i
                gsub(/[^A-Fa-f0-9]/, "", token)
                if (token ~ /^[A-Fa-f0-9]{64}$/) {
                    print tolower(token)
                    exit
                }
            }
        }
    ' "${dgst}")
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ -n "${expected}" && "${expected,,}" == "${actual,,}" ]] \
        || die "Xray SHA256 校验失败"
    unzip -qo "${archive}" -d "${temp_dir}/xray"
    install -d -m 0755 "${XRAY_DIR}"
    install -m 0755 "${temp_dir}/xray/xray" "${XRAY_BIN}"
    printf '%s\n' "${version}" >"${XRAY_DIR}/version"
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
