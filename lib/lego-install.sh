#!/usr/bin/env bash

# Pinned, checksum-verified lego installation and protocol-neutral renewal timer.
readonly LEGO_VERSION="v4.35.2"
readonly LEGO_RELEASE_NAME="${LEGO_VERSION#v}"
readonly LEGO_RELEASE_BASE="https://github.com/go-acme/lego/releases/download/${LEGO_VERSION}"
# Release asset names are not uniform: the archive keeps the leading "v",
# the checksums file does not.
readonly LEGO_CHECKSUMS="lego_${LEGO_RELEASE_NAME}_checksums.txt"
readonly LEGO_TIMEOUT="15m"
: "${LEGO_DIR:=/etc/easy_all/acme}"
: "${LEGO_BIN:=${LEGO_DIR}/lego}"
: "${LEGO_VERSION_FILE:=${LEGO_DIR}/version}"
: "${CERT_RENEW_SERVICE:=easy_all-cert-renew.service}"
: "${CERT_RENEW_TIMER:=easy_all-cert-renew.timer}"
: "${CERT_RENEW_SERVICE_FILE:=/etc/systemd/system/${CERT_RENEW_SERVICE}}"
: "${CERT_RENEW_TIMER_FILE:=/etc/systemd/system/${CERT_RENEW_TIMER}}"

download_lego() {
    local archive checksums dir expected actual architecture asset
    architecture=$(dpkg --print-architecture) || die "无法识别 lego 下载架构"
    case "${architecture}" in
    amd64|arm64) asset="lego_${LEGO_VERSION}_linux_${architecture}.tar.gz" ;;
    *) die "lego 下载不支持系统架构 ${architecture}" ;;
    esac
    dir=$(make_temp_dir)
    archive="${dir}/${asset}"
    checksums="${dir}/${LEGO_CHECKSUMS}"
    info "正在下载 lego ${LEGO_VERSION}（Let's Encrypt 客户端）"
    download_https_file "${LEGO_RELEASE_BASE}/${asset}" "${archive}" \
        " lego ${LEGO_VERSION}"
    download_https_file "${LEGO_RELEASE_BASE}/${LEGO_CHECKSUMS}" "${checksums}" \
        " lego 校验文件"
    expected=$(awk -v name="${asset}" '$2 == name {print tolower($1)}' "${checksums}")
    [[ "${expected}" =~ ^[0-9a-f]{64}$ ]] \
        || die "lego 校验文件未包含 ${asset} 的 SHA256"
    actual=$(sha256sum "${archive}" | awk '{print $1}')
    [[ "${expected}" == "${actual}" ]] \
        || die "lego SHA256 校验失败：期望 ${expected}，实际 ${actual}"
    tar -xzf "${archive}" -C "${dir}" lego \
        || die "解压 lego 失败"
    install -d -m 0700 "${LEGO_DIR}"
    install -m 0755 "${dir}/lego" "${LEGO_BIN}"
    printf '%s\n' "${LEGO_VERSION}" >"${LEGO_VERSION_FILE}"
}

ensure_lego() {
    [[ -x "${LEGO_BIN}" && -r "${LEGO_VERSION_FILE}" ]] \
        && [[ "$(<"${LEGO_VERSION_FILE}")" == "${LEGO_VERSION}" ]] \
        && return 0
    download_lego
}

install_certificate_renewal_timer() {
    cat >"${RUNTIME_TMP}/easy_all-cert-renew.service" <<EOF
[Unit]
Description=easy_all Let's Encrypt certificate renewal
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} cert-renew
EOF
    cat >"${RUNTIME_TMP}/easy_all-cert-renew.timer" <<'EOF'
[Unit]
Description=Run easy_all certificate renewal twice a day

[Timer]
OnCalendar=*-*-* 03,15:23:00
RandomizedDelaySec=30m
Persistent=true
Unit=easy_all-cert-renew.service

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-cert-renew.service" "${CERT_RENEW_SERVICE_FILE}"
    install -m 0644 "${RUNTIME_TMP}/easy_all-cert-renew.timer" "${CERT_RENEW_TIMER_FILE}"
    systemctl daemon-reload
    systemctl enable --now "${CERT_RENEW_TIMER}" >/dev/null \
        || die "启用证书续期定时器失败"
}

