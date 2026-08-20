#!/usr/bin/env bash

# Shared, checksum-verified Xray release installation.

download_xray() {
    local release archive_url dgst_url version temp_dir archive dgst expected actual
    temp_dir=$(make_temp_dir)
    release=$(curl -fsSL --retry 3 "${XRAY_RELEASES_API}") \
        || die "读取 Xray 最新版本失败"
    version=$(jq -r '.tag_name' <<<"${release}")
    archive_url=$(jq -r --arg name "${XRAY_ARCHIVE}" \
        '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release}")
    dgst_url=$(jq -r --arg name "${XRAY_DGST}" \
        '.assets[] | select(.name == $name) | .browser_download_url' <<<"${release}")
    [[ -n "${archive_url}" && "${archive_url}" != "null" ]] \
        || die "未找到 ${XRAY_ARCHIVE}"
    [[ -n "${dgst_url}" && "${dgst_url}" != "null" ]] \
        || die "未找到 ${XRAY_DGST}"
    archive="${temp_dir}/${XRAY_ARCHIVE}"
    dgst="${temp_dir}/${XRAY_DGST}"
    curl -fL --retry 3 "${archive_url}" -o "${archive}" || die "下载 Xray 失败"
    curl -fL --retry 3 "${dgst_url}" -o "${dgst}" || die "下载 Xray 校验文件失败"
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
