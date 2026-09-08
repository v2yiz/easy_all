#!/usr/bin/env bash

# Shared, checksum-verified Xray release installation.

export XRAY_LOCATION_ASSET="${XRAY_DIR}"

XRAY_GEODATA_RELEASE_BASE="${XRAY_GEODATA_RELEASE_BASE_OVERRIDE:-https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download}"

xray_geosite_required() {
    vps_dual_stack_enabled
}

xray_geosite_ready() {
    [[ -s "${XRAY_DIR}/geosite.dat" && -s "${XRAY_DIR}/geoip.dat" ]]
}

validate_xray_google_assets() {
    validate_xray_google_assets_in_dir "${XRAY_DIR}"
}

validate_xray_google_assets_in_dir() {
    local asset_dir=$1
    local config="${RUNTIME_TMP}/xray-google-assets-test.json"
    [[ -x "${XRAY_BIN}" ]] || return 1
    [[ -s "${asset_dir}/geosite.dat" && -s "${asset_dir}/geoip.dat" ]] || return 1
    jq -n '{
      log:{loglevel:"none"},
      inbounds:[],
      outbounds:[{protocol:"freedom",tag:"direct"}],
      routing:{
        domainStrategy:"AsIs",
        rules:[
          {type:"field",domain:["geosite:google"],outboundTag:"direct"},
          {type:"field",ip:["geoip:google"],outboundTag:"direct"}
        ]
      }
    }' >"${config}"
    XRAY_LOCATION_ASSET="${asset_dir}" \
        "${XRAY_BIN}" run -test -config "${config}" >/dev/null 2>&1
}

download_xray() {
    local release_file archive_url dgst_url version temp_dir archive dgst expected actual
    local asset_test_config
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
    if xray_geosite_required; then
        [[ -s "${temp_dir}/xray/geosite.dat" ]] \
            || die "Xray 发布包缺少双栈 Google IPv4 路由所需的 geosite.dat"
        [[ -s "${temp_dir}/xray/geoip.dat" ]] \
            || die "Xray 发布包缺少双栈 Google IPv4 路由所需的 geoip.dat"
        asset_test_config="${temp_dir}/asset-test.json"
        jq -n '{
          log:{loglevel:"none"},
          inbounds:[],
          outbounds:[{protocol:"freedom",tag:"direct"}],
          routing:{
            domainStrategy:"AsIs",
            rules:[
              {type:"field",domain:["geosite:google"],outboundTag:"direct"},
              {type:"field",ip:["geoip:google"],outboundTag:"direct"}
            ]
          }
        }' >"${asset_test_config}"
        chmod 0755 "${temp_dir}/xray/xray"
        XRAY_LOCATION_ASSET="${temp_dir}/xray" \
            "${temp_dir}/xray/xray" run -test -config "${asset_test_config}" \
            >/dev/null 2>&1 \
            || die "Xray geosite.dat 缺少可用的 google 分类"
        install -m 0644 "${temp_dir}/xray/geosite.dat" "${XRAY_DIR}/geosite.dat"
        install -m 0644 "${temp_dir}/xray/geoip.dat" "${XRAY_DIR}/geoip.dat"
    fi
    install -m 0755 "${temp_dir}/xray/xray" "${XRAY_BIN}"
    printf '%s\n' "${version}" >"${XRAY_DIR}/version"
}

ensure_xray_geosite_assets() {
    xray_geosite_required || return 0
    validate_xray_google_assets && return 0
    info "双栈模式缺少有效的 Google GeoSite/GeoIP 资产，正在重新安装校验后的 Xray 发布资产"
    download_xray
    validate_xray_google_assets || die "双栈模式无法安装有效的 Google GeoSite/GeoIP 资产"
}

snapshot_xray_assets() {
    local destination=$1 asset
    install -d -m 0700 "${destination}"
    for asset in geosite.dat geoip.dat; do
        if [[ -f "${XRAY_DIR}/${asset}" ]]; then
            install -m 0644 "${XRAY_DIR}/${asset}" "${destination}/${asset}"
        else
            install -m 0600 /dev/null "${destination}/${asset}.missing"
        fi
    done
}

restore_xray_assets() {
    local source=$1 asset
    for asset in geosite.dat geoip.dat; do
        if [[ -f "${source}/${asset}" ]]; then
            install -m 0644 "${source}/${asset}" "${XRAY_DIR}/${asset}"
        elif [[ -f "${source}/${asset}.missing" ]]; then
            rm -f -- "${XRAY_DIR}/${asset}"
        fi
    done
}

download_xray_geodata_asset() {
    local asset=$1 destination=$2 checksum_file="${destination}.sha256sum"
    local expected actual
    download_https_file "${XRAY_GEODATA_RELEASE_BASE}/${asset}" \
        "${destination}" " ${asset}"
    download_https_file "${XRAY_GEODATA_RELEASE_BASE}/${asset}.sha256sum" \
        "${checksum_file}" " ${asset} SHA256"
    expected=$(awk 'NR == 1 && $1 ~ /^[A-Fa-f0-9]{64}$/ {print tolower($1)}' \
        "${checksum_file}")
    actual=$(sha256sum "${destination}" | awk '{print $1}')
    [[ -n "${expected}" && "${expected}" == "${actual,,}" ]] \
        || die "${asset} SHA256 校验失败"
}

refresh_xray_assets() {
    local stage backup asset changed=0
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    if ! vps_dual_stack_enabled; then
        info "VPS 当前为 IPv4-only，无需更新 Google 双栈路由资产"
        release_runtime_write_lock
        return 0
    fi

    stage=$(make_temp_dir)
    backup=$(make_temp_dir)
    download_xray_geodata_asset geosite.dat "${stage}/geosite.dat"
    download_xray_geodata_asset geoip.dat "${stage}/geoip.dat"
    validate_xray_google_assets_in_dir "${stage}" \
        || die "新 GeoSite/GeoIP 资产缺少可用的 Google 分类"
    for asset in geosite.dat geoip.dat; do
        cmp -s "${stage}/${asset}" "${XRAY_DIR}/${asset}" || changed=1
    done
    if [[ "${changed}" == "1" ]]; then
        snapshot_xray_assets "${backup}"
        if ! (
            for asset in geosite.dat geoip.dat; do
                install -m 0644 "${stage}/${asset}" "${XRAY_DIR}/${asset}.new"
            done
            for asset in geosite.dat geoip.dat; do
                mv -f "${XRAY_DIR}/${asset}.new" "${XRAY_DIR}/${asset}"
            done
            validate_xray_google_assets
        ); then
            rm -f -- "${XRAY_DIR}/geosite.dat.new" "${XRAY_DIR}/geoip.dat.new"
            restore_xray_assets "${backup}"
            die "新 GeoSite/GeoIP 资产发布失败，已恢复旧版本"
        fi
    fi
    release_runtime_write_lock
    if [[ "${changed}" == "1" ]]; then
        success "GeoSite/GeoIP 已更新，将在 Xray 下次启动时生效"
    else
        info "GeoSite/GeoIP 已是最新版本"
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
ExecStart=${XRAY_BIN} run -config ${XRAY_CONFIG}
ExecStopPost=-${COMMAND_PATH} quota-sync
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
