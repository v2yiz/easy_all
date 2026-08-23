#!/usr/bin/env bash

# Shared XHTTP outbound policy for optional Cloudflare WARP egress.
# WARP is implemented inside Xray so it never changes the host default route,
# CDN origin traffic, SSH, Nginx, UFW, or certificate renewal networking.

readonly DEFAULT_WARP_MODE="ai"
readonly WARP_DIR="${STATE_DIR}/warp"
readonly WARP_ACCOUNT_FILE="${WARP_DIR}/wgcf-account.toml"
readonly WARP_PROFILE_FILE="${WARP_DIR}/wgcf-profile.conf"
readonly WGCF_RELEASES_API="https://api.github.com/repos/ViRb3/wgcf/releases/latest"
readonly WARP_MTU="1280"
readonly WARP_TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"

validate_warp_mode() {
    [[ "$1" == "off" || "$1" == "ai" || "$1" == "global" ]]
}

normalize_warp_mode() {
    case "$1" in
    1 | off | disabled | none) printf 'off\n' ;;
    2 | ai | ai-only) printf 'ai\n' ;;
    3 | global | all) printf 'global\n' ;;
    *) return 1 ;;
    esac
}

warp_mode_label() {
    case "${1:-${WARP_MODE:-off}}" in
    off) printf '关闭' ;;
    ai) printf 'AI WARP（Gemini / ChatGPT / Claude）' ;;
    global) printf 'Global WARP（全部节点用户流量）' ;;
    *) printf '未知' ;;
    esac
}

choose_warp_mode() {
    local mode=${WARP_MODE:-} current_mode default_choice=2 choice
    current_mode=$(normalize_warp_mode "${mode:-${DEFAULT_WARP_MODE}}") \
        || die "WARP 模式无效：${mode:-缺失}"
    case "${current_mode}" in
    off) default_choice=1 ;;
    ai) default_choice=2 ;;
    global) default_choice=3 ;;
    esac
    if [[ -t 0 ]]; then
        printf '请选择节点用户的 WARP 出口：\n'
        printf '  1. 不启用 WARP：目标网站看到 VPS 出口 IP\n'
        printf '  2. AI WARP（默认）：Gemini、ChatGPT、Claude 走免费 WARP，其余直连\n'
        printf '  3. Global WARP：全部节点用户 TCP/UDP 走免费 WARP\n'
        printf '提示：免费 WARP 是共享出口，不保证 IP 固定；不会修改 VPS 系统路由或 CDN 回源。\n'
        printf '选择 AI/Global 即表示接受 Cloudflare WARP 服务条款。\n'
        read -r -p "请选择 [${default_choice}]（直接回车使用默认值）: " choice
        mode=${choice:-${current_mode}}
    else
        mode=${mode:-${current_mode}}
    fi
    WARP_MODE=$(normalize_warp_mode "${mode}") || die "WARP 模式无效：${mode}"
}

configure_loaded_warp_mode() {
    WARP_MODE=$(normalize_warp_mode "${WARP_MODE:-off}") \
        || die "状态文件中的 WARP_MODE 无效：${WARP_MODE:-缺失}"
}

warp_enabled() {
    [[ "${WARP_MODE:-off}" != "off" ]]
}

warp_ini_value() {
    local file=$1 section=$2 key=$3
    awk -v expected_section="${section}" -v expected_key="${key}" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*\[/ {
            current=$0
            gsub(/^[[:space:]]*\[|\][[:space:]]*$/, "", current)
            next
        }
        current == expected_section {
            separator=index($0, "=")
            if (separator == 0) next
            name=trim(substr($0, 1, separator - 1))
            if (name == expected_key) {
                print trim(substr($0, separator + 1))
                exit
            }
        }
    ' "${file}"
}

warp_profile_values_json() {
    local profile=${1:-${WARP_PROFILE_FILE}}
    local private_key addresses peer_public_key endpoint allowed_ips mtu
    [[ -s "${profile}" ]] || return 1
    private_key=$(warp_ini_value "${profile}" Interface PrivateKey)
    addresses=$(warp_ini_value "${profile}" Interface Address)
    peer_public_key=$(warp_ini_value "${profile}" Peer PublicKey)
    endpoint=$(warp_ini_value "${profile}" Peer Endpoint)
    allowed_ips=$(warp_ini_value "${profile}" Peer AllowedIPs)
    mtu=$(warp_ini_value "${profile}" Interface MTU)
    mtu=${mtu:-${WARP_MTU}}

    [[ "${private_key}" =~ ^[A-Za-z0-9+/]{43}=$ \
        && "${peer_public_key}" =~ ^[A-Za-z0-9+/]{43}=$ ]] || return 1
    [[ -n "${addresses}" && "${addresses}" != *$'\n'* \
        && -n "${endpoint}" && "${endpoint}" != *[[:space:]]* ]] || return 1
    [[ "${mtu}" =~ ^[0-9]+$ ]] || return 1
    ((10#${mtu} >= 1280 && 10#${mtu} <= 1500)) || return 1
    [[ -n "${allowed_ips}" ]] || allowed_ips="0.0.0.0/0, ::/0"

    jq -ecn \
        --arg private_key "${private_key}" \
        --arg addresses "${addresses}" \
        --arg peer_public_key "${peer_public_key}" \
        --arg endpoint "${endpoint}" \
        --arg allowed_ips "${allowed_ips}" \
        --argjson mtu "${WARP_MTU}" '
        def csv:
          split(",") | map(gsub("^[[:space:]]+|[[:space:]]+$"; ""))
          | map(select(length > 0));
        {
          private_key:$private_key,
          addresses:($addresses | csv),
          peer_public_key:$peer_public_key,
          endpoint:$endpoint,
          allowed_ips:($allowed_ips | csv),
          mtu:$mtu
        }
        | select((.addresses | length) > 0 and (.allowed_ips | length) > 0)
    '
}

validate_warp_profile() {
    warp_profile_values_json "${1:-${WARP_PROFILE_FILE}}" >/dev/null
}

warp_xray_outbound_json() {
    local values
    values=$(warp_profile_values_json) || die "WARP Profile 缺失或格式无效：${WARP_PROFILE_FILE}"
    jq -cn --argjson values "${values}" '
        {
          protocol:"wireguard",
          tag:"warp",
          settings:{
            secretKey:$values.private_key,
            address:$values.addresses,
            peers:[{
              endpoint:$values.endpoint,
              publicKey:$values.peer_public_key,
              keepAlive:25,
              allowedIPs:$values.allowed_ips
            }],
            noKernelTun:true,
            mtu:$values.mtu,
            domainStrategy:"ForceIPv4"
          }
        }
    '
}

warp_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
      "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
    ]'
}

warp_xray_outbounds_json() {
    local warp_outbound
    case "${WARP_MODE:-off}" in
    off)
        jq -cn --arg strategy "${GEMINI_OUTBOUND_DOMAIN_STRATEGY}" '[
          {protocol:"freedom",tag:"direct"},
          {protocol:"freedom",tag:"gemini-family",settings:{domainStrategy:$strategy}}
        ]'
        ;;
    ai | global)
        warp_outbound=$(warp_xray_outbound_json)
        jq -cn --argjson warp "${warp_outbound}" '[
          {protocol:"freedom",tag:"direct"},
          $warp,
          {protocol:"blackhole",tag:"block"}
        ]'
        ;;
    *) die "WARP 模式无效：${WARP_MODE:-缺失}" ;;
    esac
}

warp_xray_routing_json() {
    local private_ranges
    private_ranges=$(warp_private_ranges_json)
    case "${WARP_MODE:-off}" in
    off)
        jq -cn --argjson domains "${GEMINI_DOMAIN_SUFFIXES_JSON}" '{
          domainStrategy:"AsIs",
          rules:[
            {type:"field",domain:($domains | map("domain:" + .)),outboundTag:"gemini-family"},
            {type:"field",network:"tcp,udp",outboundTag:"direct"}
          ]
        }'
        ;;
    ai)
        jq -cn --argjson private "${private_ranges}" \
            --argjson domains "${AI_WARP_DOMAIN_SUFFIXES_JSON}" '{
          domainStrategy:"IPOnDemand",
          rules:[
            {type:"field",ip:$private,outboundTag:"block"},
            {type:"field",domain:($domains | map("domain:" + .)),outboundTag:"warp"},
            {type:"field",network:"tcp,udp",outboundTag:"direct"}
          ]
        }'
        ;;
    global)
        jq -cn --argjson private "${private_ranges}" '{
          domainStrategy:"IPOnDemand",
          rules:[
            {type:"field",ip:$private,outboundTag:"block"},
            {type:"field",network:"tcp,udp",outboundTag:"warp"}
          ]
        }'
        ;;
    *) die "WARP 模式无效：${WARP_MODE:-缺失}" ;;
    esac
}

download_wgcf() {
    local destination=$1 release tag version asset_name asset_url checksums_url
    local checksums expected actual expected_asset_url expected_checksums_url
    release=$(curl -fsSL --retry 3 "${WGCF_RELEASES_API}") \
        || die "读取 wgcf 最新版本失败"
    tag=$(jq -r 'select(.draft == false and .prerelease == false) | .tag_name // empty' \
        <<<"${release}")
    [[ "${tag}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || die "wgcf Release 版本无效：${tag:-缺失}"
    version=${tag#v}
    asset_name="wgcf_${version}_linux_amd64"
    asset_url=$(jq -r --arg name "${asset_name}" \
        '.assets[]? | select(.name == $name) | .browser_download_url' <<<"${release}")
    checksums_url=$(jq -r \
        '.assets[]? | select(.name == "checksums.txt") | .browser_download_url' \
        <<<"${release}")
    expected_asset_url="https://github.com/ViRb3/wgcf/releases/download/${tag}/${asset_name}"
    expected_checksums_url="https://github.com/ViRb3/wgcf/releases/download/${tag}/checksums.txt"
    [[ "${asset_url}" == "${expected_asset_url}" \
        && "${checksums_url}" == "${expected_checksums_url}" ]] \
        || die "wgcf Release 缺少受信任的 amd64 二进制或校验文件"
    checksums="${RUNTIME_TMP}/wgcf-checksums.txt"
    curl -fL --retry 3 "${asset_url}" -o "${destination}" \
        || die "下载 wgcf 失败"
    curl -fsSL --retry 3 "${checksums_url}" -o "${checksums}" \
        || die "下载 wgcf 校验文件失败"
    expected=$(awk -v name="${asset_name}" '$2 == name || $2 == "*" name {print tolower($1); exit}' \
        "${checksums}")
    actual=$(sha256sum "${destination}" | awk '{print tolower($1)}')
    [[ "${expected}" =~ ^[a-f0-9]{64}$ && "${actual}" == "${expected}" ]] \
        || die "wgcf SHA256 校验失败"
    chmod 0700 "${destination}"
}

register_warp_profile() {
    local temp_dir wgcf_bin account profile
    temp_dir=$(make_temp_dir)
    wgcf_bin="${temp_dir}/wgcf"
    account="${temp_dir}/wgcf-account.toml"
    profile="${temp_dir}/wgcf-profile.conf"
    info "下载并校验临时 wgcf；注册免费的 Cloudflare WARP WireGuard Profile"
    warn "启用即接受 Cloudflare WARP 服务条款；wgcf 是非官方注册工具，生成后不常驻运行。"
    download_wgcf "${wgcf_bin}"
    (
        cd -- "${temp_dir}"
        "${wgcf_bin}" --config "${account}" register --accept-tos
        "${wgcf_bin}" --config "${account}" generate
    ) || die "生成免费 WARP Profile 失败"
    validate_warp_profile "${profile}" || die "wgcf 生成的 WARP Profile 无效"
    install -d -m 0700 "${WARP_DIR}"
    install -m 0600 "${account}" "${WARP_ACCOUNT_FILE}"
    install -m 0600 "${profile}" "${WARP_PROFILE_FILE}"
}

prepare_warp_profile() {
    warp_enabled || return 0
    if validate_warp_profile; then
        return 0
    fi
    register_warp_profile
    validate_warp_profile || die "WARP Profile 安装后验收失败"
}

warp_probe_port() {
    local port
    for port in {19080..19120}; do
        if ! ss -H -ltn "sport = :${port}" 2>/dev/null | grep -q .; then
            printf '%s\n' "${port}"
            return 0
        fi
    done
    return 1
}

warp_profile_trace() {
    local port config log pid trace="" attempt outbound
    [[ -x "${XRAY_BIN}" ]] || return 1
    validate_warp_profile || return 1
    port=$(warp_probe_port) || return 1
    config="${RUNTIME_TMP}/warp-probe-${port}.json"
    log="${RUNTIME_TMP}/warp-probe-${port}.log"
    outbound=$(warp_xray_outbound_json) || return 1
    jq -n --argjson port "${port}" --argjson outbound "${outbound}" '{
      log:{loglevel:"warning"},
      inbounds:[{listen:"127.0.0.1",port:$port,protocol:"socks",settings:{udp:false}}],
      outbounds:[$outbound]
    }' >"${config}"
    "${XRAY_BIN}" run -config "${config}" >"${log}" 2>&1 &
    pid=$!
    for attempt in {1..5}; do
        kill -0 "${pid}" 2>/dev/null || break
        trace=$(curl -fsS --max-time 4 --socks5-hostname "127.0.0.1:${port}" \
            "${WARP_TRACE_URL}" 2>/dev/null || true)
        if grep -Fqx 'warp=on' <<<"${trace}"; then
            kill "${pid}" >/dev/null 2>&1 || true
            wait "${pid}" >/dev/null 2>&1 || true
            printf '%s\n' "${trace}"
            return 0
        fi
        sleep 1
    done
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
    if [[ -s "${log}" ]]; then
        printf 'WARP 探针日志：\n' >&2
        tail -n 8 "${log}" >&2
    fi
    return 1
}

validate_warp_egress() {
    local trace
    warp_enabled || return 0
    info "验收 Xray 用户态 WireGuard WARP 出口"
    trace=$(warp_profile_trace) || die "WARP 出口验收失败；不会回退到 VPS 直连出口"
    success "WARP 出口验收通过（IP: $(awk -F= '$1 == "ip" {print $2}' <<<"${trace}")，Colo: $(awk -F= '$1 == "colo" {print $2}' <<<"${trace}")）"
}

show_warp_configuration_status() {
    printf 'WARP 模式: %s\n' "$(warp_mode_label)"
    if warp_enabled; then
        if validate_warp_profile; then
            printf 'WARP Profile: ready（用户态 WireGuard，MTU %s，出口 IPv4 优先）\n' "${WARP_MTU}"
        else
            printf 'WARP Profile: invalid\n'
        fi
    else
        printf 'Gemini 出口族: %s（固定）\n' "$(gemini_ip_family_status)"
    fi
}

show_warp_live_status() {
    local trace ip colo
    require_root
    collect_installed_state
    printf 'WARP 模式: %s\n' "$(warp_mode_label)"
    if ! warp_enabled; then
        printf 'WARP 实时状态: disabled\n'
        return 0
    fi
    trace=$(warp_profile_trace) || die "WARP 实时验收失败；WARP 流量保持失败关闭，不会回退直连"
    ip=$(awk -F= '$1 == "ip" {print $2}' <<<"${trace}")
    colo=$(awk -F= '$1 == "colo" {print $2}' <<<"${trace}")
    printf 'WARP 实时状态: on\nWARP 出口 IP: %s（共享，不保证固定）\nCloudflare Colo: %s\n' \
        "${ip:-未知}" "${colo:-未知}"
}

update_warp_mode() {
    local requested_mode=${1:-}
    (($# <= 1)) || die "用法：easy_all warp-set [off|ai|global]"
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    if [[ -n "${requested_mode}" ]]; then
        WARP_MODE=$(normalize_warp_mode "${requested_mode}") \
            || die "WARP 模式无效：${requested_mode}"
    else
        choose_warp_mode
    fi
    prepare_warp_profile
    validate_warp_egress
    save_state
    refresh_runtime
    end_quota_maintenance
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    show_warp_configuration_status
    success "WARP 模式已更新；未修改 VPS 系统路由或 CDN 资源"
}
