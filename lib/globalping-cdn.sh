#!/usr/bin/env bash

# Shared Globalping authentication and refresh helpers for CDN providers.

readonly GLOBALPING_API_BASE="https://api.globalping.io/v1"
readonly GLOBALPING_TOKEN_FILE="${GLOBALPING_TOKEN_FILE_OVERRIDE:-${STATE_DIR}/globalping.token}"
readonly GLOBALPING_CACHE_FILE="${GLOBALPING_CACHE_FILE_OVERRIDE:-${STATE_DIR}/${GLOBALPING_CACHE_BASENAME_OVERRIDE:-cdn-ips.json}}"
readonly GLOBALPING_REFRESH_SERVICE_FILE="${GLOBALPING_REFRESH_SERVICE_FILE_OVERRIDE:-/etc/systemd/system/easy_all-globalping-refresh.service}"
readonly GLOBALPING_REFRESH_TIMER_FILE="${GLOBALPING_REFRESH_TIMER_FILE_OVERRIDE:-/etc/systemd/system/easy_all-globalping-refresh.timer}"
readonly GLOBALPING_REFRESH_SERVICE="easy_all-globalping-refresh.service"
readonly GLOBALPING_REFRESH_TIMER="easy_all-globalping-refresh.timer"
readonly GLOBALPING_CACHE_MAX_AGE_SECONDS=86400

cdn_optimization_enabled() {
    [[ "${CDN_PROVIDER:-}" == "cloudflare" ]]
}

globalping_cdn_provider_label() {
    printf 'Cloudflare'
}

validate_globalping_token() {
    [[ ${#1} -ge 16 && ${#1} -le 512 && "$1" != *[[:space:]]* ]]
}

validate_public_ipv4() {
    local ip=$1 a b c d
    validate_ipv4 "${ip}" || return 1
    IFS=. read -r a b c d <<<"${ip}"
    a=$((10#${a})); b=$((10#${b})); c=$((10#${c})); d=$((10#${d}))
    ((a != 0 && a != 10 && a != 127 && a < 224)) || return 1
    ((a != 100 || b < 64 || b > 127)) || return 1
    ((a != 169 || b != 254)) || return 1
    ((a != 172 || b < 16 || b > 31)) || return 1
    ((a != 192 || b != 168)) || return 1
    ((a != 198 || b < 18 || b > 19)) || return 1
    ((a != 192 || b != 0 || c != 2)) || return 1
    ((a != 198 || b != 51 || c != 100)) || return 1
    ((a != 203 || b != 0 || c != 113)) || return 1
}

collect_globalping_token() {
    local token=${GLOBALPING_TOKEN:-}
    if [[ -z "${token}" && -s "${GLOBALPING_TOKEN_FILE}" ]]; then
        token=$(<"${GLOBALPING_TOKEN_FILE}")
    fi
    if [[ -z "${token}" ]]; then
        token=$(prompt_secret \
            "Globalping Access Token（仅保存到 VPS root-only 凭据文件）" \
            "Globalping access token (stored only in a root-only VPS credential file)") \
            || die "必须在交互终端中输入 GLOBALPING_TOKEN"
    fi
    validate_globalping_token "${token}" || die "Globalping Token 格式无效"
    GLOBALPING_TOKEN=${token}
}

persist_globalping_token() {
    local temp
    cdn_optimization_enabled || return 0
    collect_globalping_token
    install -d -m 0700 "${STATE_DIR}"
    temp=$(mktemp "${STATE_DIR}/globalping.token.XXXXXX")
    cleanup_files+=("${temp}")
    printf '%s\n' "${GLOBALPING_TOKEN}" >"${temp}"
    install -o root -g root -m 0600 "${temp}" "${GLOBALPING_TOKEN_FILE}"
}

globalping_token_value() {
    if [[ -n "${GLOBALPING_TOKEN:-}" ]]; then
        printf '%s' "${GLOBALPING_TOKEN}"
        return 0
    fi
    [[ -s "${GLOBALPING_TOKEN_FILE}" ]] || return 1
    local token
    token=$(<"${GLOBALPING_TOKEN_FILE}")
    validate_globalping_token "${token}" || return 1
    printf '%s' "${token}"
}

globalping_api_request() {
    local method=$1 path=$2 body=${3:-} token headers
    token=$(globalping_token_value) || {
        warn "缺少 Globalping Token，无法刷新 $(globalping_cdn_provider_label) CDN 精选 IP"
        return 1
    }
    headers=$(make_temp_dir)/globalping-headers
    printf 'Authorization: Bearer %s\n' "${token}" >"${headers}"
    chmod 0600 "${headers}"
    if [[ "${method}" == "POST" ]]; then
        curl -fsS --connect-timeout 10 --max-time 25 \
            -X POST "${GLOBALPING_API_BASE}${path}" \
            -H "@${headers}" \
            -H 'Content-Type: application/json' \
            -H 'User-Agent: easy_all/globalping-cdn' \
            --data "${body}"
    else
        curl -fsS --connect-timeout 10 --max-time 25 \
            "${GLOBALPING_API_BASE}${path}" \
            -H "@${headers}" \
            -H 'Accept: application/json' \
            -H 'User-Agent: easy_all/globalping-cdn'
    fi
}

validate_globalping_access() {
    local limits
    limits=$(globalping_api_request GET "/limits") || return 1
    jq -e '.rateLimit.measurements.create.type == "user"' \
        <<<"${limits}" >/dev/null
}

install_globalping_refresh_timer() {
    if ! cdn_optimization_enabled; then
        remove_globalping_refresh_timer
        return 0
    fi
    cat >"${RUNTIME_TMP}/easy_all-globalping-refresh.service" <<EOF
[Unit]
Description=Refresh easy_all CDN endpoints with Globalping
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=${COMMAND_PATH} refresh-cdn-ips
EOF
    cat >"${RUNTIME_TMP}/easy_all-globalping-refresh.timer" <<EOF
[Unit]
Description=Refresh easy_all CDN endpoints every hour

[Timer]
OnActiveSec=1h
OnUnitActiveSec=1h
Unit=${GLOBALPING_REFRESH_SERVICE}

[Install]
WantedBy=timers.target
EOF
    install -m 0644 "${RUNTIME_TMP}/easy_all-globalping-refresh.service" \
        "${GLOBALPING_REFRESH_SERVICE_FILE}"
    install -m 0644 "${RUNTIME_TMP}/easy_all-globalping-refresh.timer" \
        "${GLOBALPING_REFRESH_TIMER_FILE}"
    systemctl daemon-reload \
        || die "重新加载 Globalping 定时器失败"
    systemctl enable "${GLOBALPING_REFRESH_TIMER}" >/dev/null \
        || die "启用 Globalping 每小时刷新定时器失败"
    systemctl restart "${GLOBALPING_REFRESH_TIMER}" >/dev/null \
        || die "启动 Globalping 每小时刷新定时器失败"
    systemctl is-enabled --quiet "${GLOBALPING_REFRESH_TIMER}" \
        || die "Globalping 每小时刷新定时器未设置为开机启动"
    systemctl is-active --quiet "${GLOBALPING_REFRESH_TIMER}" \
        || die "Globalping 每小时刷新定时器未运行"
}

remove_globalping_refresh_timer() {
    systemctl disable --now "${GLOBALPING_REFRESH_TIMER}" >/dev/null 2>&1 || true
    systemctl stop "${GLOBALPING_REFRESH_SERVICE}" >/dev/null 2>&1 || true
    rm -f -- "${GLOBALPING_REFRESH_SERVICE_FILE}" "${GLOBALPING_REFRESH_TIMER_FILE}"
    command -v systemctl >/dev/null 2>&1 && systemctl daemon-reload >/dev/null 2>&1 || true
}

show_globalping_status() {
    local provider_label
    provider_label=$(globalping_cdn_provider_label)
    if ! cdn_optimization_enabled; then
        printf '%s CDN 精选 IP: disabled\n' "${provider_label}"
        return 0
    fi
    if globalping_cache_valid; then
        printf '%s CDN 精选 IP: enabled，%s 个，最近成功刷新 %s\n' \
            "${provider_label}" \
            "$(jq '.candidates | length' "${GLOBALPING_CACHE_FILE}")" \
            "$(jq -r '.measured_at // "未知"' "${GLOBALPING_CACHE_FILE}")"
    else
        printf '%s CDN 精选 IP: 缓存缺失或超过 24 小时，当前回退 CDN 域名\n' \
            "${provider_label}"
    fi
    printf 'Globalping 定时器: '
    systemctl is-active --quiet "${GLOBALPING_REFRESH_TIMER}" \
        && printf 'active\n' || printf 'inactive\n'
}
