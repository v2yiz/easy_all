#!/usr/bin/env bash

# Shared public network discovery and Xray IPv4 egress policy.

readonly XRAY_OUTBOUND_DOMAIN_STRATEGY="ForceIPv4"
readonly XHTTP_WARP_DEFAULT_ENDPOINT="162.159.192.1:2408"
readonly XHTTP_WARP_DEFAULT_PEER_PUBLIC_KEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
readonly XHTTP_WARP_DEFAULT_ADDRESS="172.16.0.2/32"
readonly XHTTP_WARP_DEFAULT_RESERVED="0,0,0"
readonly WGCF_RELEASES_API="https://api.github.com/repos/ViRb3/wgcf/releases/latest"

detect_public_ipv4() {
    local service ip
    local -a services=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.co"
    )
    for service in "${services[@]}"; do
        ip=$(curl -4fsS --max-time 10 "${service}" 2>/dev/null | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done
    return 1
}

xray_private_ranges_json() {
    jq -cn '[
      "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
      "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24",
      "192.168.0.0/16", "198.18.0.0/15", "224.0.0.0/4", "240.0.0.0/4",
      "::/128", "::1/128", "fc00::/7", "fe80::/10", "ff00::/8"
    ]'
}

xray_direct_outbounds_json() {
    jq -cn --arg strategy "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" '[
      {protocol:"freedom",tag:"direct",settings:{domainStrategy:$strategy}},
      {protocol:"blackhole",tag:"block"}
    ]'
}

xray_direct_routing_json() {
    local private_ranges
    private_ranges=$(xray_private_ranges_json)
    jq -cn --argjson private "${private_ranges}" '{
      domainStrategy:"IPOnDemand",
      rules:[
        {type:"field",ip:$private,outboundTag:"block"},
        {type:"field",network:"tcp,udp",outboundTag:"direct"}
      ]
    }'
}

normalize_xhttp_gemini_warp_mode() {
    local mode=${XHTTP_GEMINI_WARP_MODE:-disabled}
    case "${mode}" in
    disabled)
        XHTTP_GEMINI_WARP_MODE="disabled"
        ;;
    auto)
        XHTTP_GEMINI_WARP_MODE="auto"
        ;;
    manual)
        XHTTP_GEMINI_WARP_MODE="manual"
        ;;
    *) die "状态文件中的 XHTTP_GEMINI_WARP_MODE 无效：${mode}" ;;
    esac
}

xhttp_gemini_warp_enabled() {
    normalize_xhttp_gemini_warp_mode
    [[ "${XHTTP_GEMINI_WARP_MODE}" != "disabled" ]]
}

xhttp_gemini_warp_summary() {
    normalize_xhttp_gemini_warp_mode
    case "${XHTTP_GEMINI_WARP_MODE}" in
    disabled) printf 'disabled' ;;
    auto) printf 'enabled (auto wgcf)' ;;
    manual) printf 'enabled (manual config)' ;;
    esac
}

validate_wireguard_key() {
    [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ || "$1" =~ ^[0-9A-Fa-f]{64}$ ]]
}

validate_warp_endpoint() {
    local endpoint=$1 port
    [[ "${endpoint}" =~ ^[^[:space:]]+:[0-9]{1,5}$ ]] || return 1
    port=${endpoint##*:}
    ((10#${port} >= 1 && 10#${port} <= 65535))
}

validate_warp_address_list() {
    local raw=$1 item count=0
    raw=${raw//,/ }
    for item in ${raw}; do
        [[ "${item}" =~ ^[0-9A-Fa-f:.]+/[0-9]{1,3}$ ]] || return 1
        ((count += 1))
    done
    ((count > 0))
}

validate_warp_reserved() {
    local raw=$1 byte count=0
    raw=${raw//,/ }
    for byte in ${raw}; do
        [[ "${byte}" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#${byte} >= 0 && 10#${byte} <= 255)) || return 1
        ((count += 1))
    done
    ((count == 3))
}

xhttp_warp_state_dir() {
    printf '%s/xhttp-warp' "${STATE_DIR:-/etc/easy_all}"
}

warp_address_json() {
    local raw=${XHTTP_WARP_ADDRESS:-${XHTTP_WARP_DEFAULT_ADDRESS}} item
    raw=${raw//,/ }
    for item in ${raw}; do
        printf '%s\n' "${item}"
    done | jq -Rsc 'split("\n")[:-1]'
}

warp_reserved_json() {
    local raw=${XHTTP_WARP_RESERVED:-${XHTTP_WARP_DEFAULT_RESERVED}} byte
    raw=${raw//,/ }
    for byte in ${raw}; do
        printf '%s\n' "${byte}"
    done | jq -Rsc 'split("\n")[:-1] | map(tonumber)'
}

apply_xhttp_warp_defaults() {
    XHTTP_WARP_PEER_PUBLIC_KEY=${XHTTP_WARP_PEER_PUBLIC_KEY:-${XHTTP_WARP_DEFAULT_PEER_PUBLIC_KEY}}
    XHTTP_WARP_ENDPOINT=${XHTTP_WARP_ENDPOINT:-${XHTTP_WARP_DEFAULT_ENDPOINT}}
    XHTTP_WARP_ADDRESS=${XHTTP_WARP_ADDRESS:-${XHTTP_WARP_DEFAULT_ADDRESS}}
    XHTTP_WARP_RESERVED=${XHTTP_WARP_RESERVED:-${XHTTP_WARP_DEFAULT_RESERVED}}
}

xhttp_warp_fields_are_valid() {
    apply_xhttp_warp_defaults
    validate_wireguard_key "${XHTTP_WARP_PRIVATE_KEY:-}" \
        && validate_wireguard_key "${XHTTP_WARP_PEER_PUBLIC_KEY}" \
        && validate_warp_endpoint "${XHTTP_WARP_ENDPOINT}" \
        && validate_warp_address_list "${XHTTP_WARP_ADDRESS}" \
        && validate_warp_reserved "${XHTTP_WARP_RESERVED}"
}

validate_xhttp_warp_fields() {
    apply_xhttp_warp_defaults
    validate_wireguard_key "${XHTTP_WARP_PRIVATE_KEY:-}" \
        || die "启用 Gemini WARP 时必须提供有效的 XHTTP_WARP_PRIVATE_KEY"
    validate_wireguard_key "${XHTTP_WARP_PEER_PUBLIC_KEY}" \
        || die "XHTTP_WARP_PEER_PUBLIC_KEY 无效"
    validate_warp_endpoint "${XHTTP_WARP_ENDPOINT}" \
        || die "XHTTP_WARP_ENDPOINT 无效"
    validate_warp_address_list "${XHTTP_WARP_ADDRESS}" \
        || die "XHTTP_WARP_ADDRESS 无效"
    validate_warp_reserved "${XHTTP_WARP_RESERVED}" \
        || die "XHTTP_WARP_RESERVED 必须是 3 个 0-255 字节"
}

wgcf_profile_first_value() {
    local profile=$1 key=$2
    awk -F= -v key="${key}" '
        {
            current=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
            if (current == key) {
                value=$0
                sub(/^[^=]*=/, "", value)
                sub(/[[:space:]]*[#;].*$/, "", value)
                gsub(/"/, "", value)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "${profile}"
}

wgcf_profile_join_values() {
    local profile=$1 key=$2
    awk -F= -v key="${key}" '
        {
            current=$1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", current)
            if (current == key) {
                value=$0
                sub(/^[^=]*=/, "", value)
                sub(/[[:space:]]*[#;].*$/, "", value)
                gsub(/[\[\]"]/, "", value)
                gsub(/[[:space:]]+/, "", value)
                count=split(value, items, ",")
                for (i = 1; i <= count; i++) {
                    if (items[i] != "") print items[i]
                }
            }
        }
    ' "${profile}" | paste -sd, -
}

load_wgcf_profile() {
    local profile=$1 address reserved
    [[ -s "${profile}" ]] || die "WARP WireGuard 配置不存在：${profile}"
    XHTTP_WARP_PRIVATE_KEY=$(wgcf_profile_first_value "${profile}" "PrivateKey")
    XHTTP_WARP_PEER_PUBLIC_KEY=$(wgcf_profile_first_value "${profile}" "PublicKey")
    XHTTP_WARP_ENDPOINT=$(wgcf_profile_first_value "${profile}" "Endpoint")
    address=$(wgcf_profile_join_values "${profile}" "Address")
    reserved=$(wgcf_profile_join_values "${profile}" "Reserved")
    XHTTP_WARP_ADDRESS=${address:-${XHTTP_WARP_DEFAULT_ADDRESS}}
    XHTTP_WARP_RESERVED=${reserved:-${XHTTP_WARP_DEFAULT_RESERVED}}
}

wgcf_asset_arch() {
    local arch
    arch=$(dpkg --print-architecture 2>/dev/null || uname -m)
    case "${arch}" in
    amd64 | x86_64) printf 'amd64' ;;
    arm64 | aarch64) printf 'arm64' ;;
    armhf | armv7l) printf 'armv7' ;;
    *) die "当前架构不支持自动下载 wgcf：${arch}" ;;
    esac
}

download_wgcf_binary() {
    local arch release asset url binary
    arch=$(wgcf_asset_arch)
    release=$(curl -fsSL --retry 3 "${WGCF_RELEASES_API}") \
        || die "查询 wgcf 最新版本失败"
    asset=$(jq -r --arg suffix "_linux_${arch}" \
        '.assets[]? | select(.name | endswith($suffix)) | .name' <<<"${release}" | head -n1)
    [[ -n "${asset}" && "${asset}" != "null" ]] || die "未找到适合当前架构的 wgcf Linux ${arch} 版本"
    url=$(jq -r --arg name "${asset}" \
        '.assets[]? | select(.name == $name) | .browser_download_url' <<<"${release}")
    [[ -n "${url}" && "${url}" != "null" ]] || die "未找到 wgcf 下载地址：${asset}"
    binary=$(mktemp "${RUNTIME_TMP:-/tmp}/wgcf.XXXXXX")
    curl -fL --retry 3 "${url}" -o "${binary}" || die "下载 wgcf 失败"
    chmod 0700 "${binary}"
    printf '%s\n' "${binary}"
}

ensure_wgcf_binary() {
    if command -v wgcf >/dev/null 2>&1; then
        command -v wgcf
        return
    fi
    download_wgcf_binary
}

auto_register_xhttp_warp_config() {
    local warp_dir wgcf_bin profile
    warp_dir=$(xhttp_warp_state_dir)
    profile="${warp_dir}/wgcf-profile.conf"
    install -d -m 0700 "${warp_dir}"
    wgcf_bin=$(ensure_wgcf_binary)
    info "正在自动注册免费 Cloudflare WARP WireGuard 配置"
    (
        cd "${warp_dir}"
        umask 077
        [[ -s wgcf-account.toml ]] || printf 'yes\n' | "${wgcf_bin}" register >/dev/null
        "${wgcf_bin}" generate >/dev/null
    ) || die "自动注册或生成 WARP WireGuard 配置失败；可改用手动配置模式"
    load_wgcf_profile "${profile}"
    validate_xhttp_warp_fields
}

ensure_auto_xhttp_warp_config() {
    local profile
    if xhttp_warp_fields_are_valid; then
        return
    fi
    profile="$(xhttp_warp_state_dir)/wgcf-profile.conf"
    if [[ -s "${profile}" ]]; then
        load_wgcf_profile "${profile}"
        xhttp_warp_fields_are_valid && return
    fi
    auto_register_xhttp_warp_config
}

normalize_xhttp_gemini_warp_state() {
    normalize_xhttp_gemini_warp_mode
    if ! xhttp_gemini_warp_enabled; then
        XHTTP_WARP_PRIVATE_KEY=""
        XHTTP_WARP_PEER_PUBLIC_KEY=""
        XHTTP_WARP_ENDPOINT=""
        XHTTP_WARP_ADDRESS=""
        XHTTP_WARP_RESERVED=""
        return
    fi

    if [[ "${XHTTP_GEMINI_WARP_MODE}" == "auto" ]]; then
        ensure_auto_xhttp_warp_config
    else
        apply_xhttp_warp_defaults
    fi
    validate_xhttp_warp_fields
}

choose_xhttp_gemini_warp() {
    local choice default_choice private_key peer_public_key endpoint address reserved
    normalize_xhttp_gemini_warp_mode
    case "${XHTTP_GEMINI_WARP_MODE}" in
    disabled) default_choice=1 ;;
    auto) default_choice=2 ;;
    manual) default_choice=3 ;;
    esac
    if [[ ! -t 0 ]]; then
        normalize_xhttp_gemini_warp_state
        return
    fi

    printf 'Gemini 相关域名是否经 Cloudflare WARP 出站？\n' >&2
    printf 'Route Gemini-related domains through Cloudflare WARP?\n' >&2
    printf '  1. 不启用（默认；所有公网仍走 VPS direct）\n' >&2
    printf '     Disable (default; public egress stays direct from the VPS)\n' >&2
    printf '  2. 自动注册免费 WARP 配置（仅 Gemini 相关域名走 WARP）\n' >&2
    printf '     Auto-register a free WARP config (Gemini-related domains only)\n' >&2
    printf '  3. 手动填写已有 WARP WireGuard 配置\n' >&2
    printf '     Manually enter an existing WARP WireGuard config\n' >&2
    read_bilingual \
        "请选择 [${default_choice}]（直接回车使用默认值）:" \
        "Choose [${default_choice}] (press Enter to use the default):" choice
    choice=${choice:-${default_choice}}
    case "${choice}" in
    1 | disabled)
        XHTTP_GEMINI_WARP_MODE=disabled
        normalize_xhttp_gemini_warp_state
        ;;
    2 | auto)
        XHTTP_GEMINI_WARP_MODE=auto
        XHTTP_WARP_PRIVATE_KEY=""
        XHTTP_WARP_PEER_PUBLIC_KEY=""
        XHTTP_WARP_ENDPOINT=""
        XHTTP_WARP_ADDRESS=""
        XHTTP_WARP_RESERVED=""
        normalize_xhttp_gemini_warp_state
        ;;
    3 | manual)
        XHTTP_GEMINI_WARP_MODE=manual
        private_key=$(prompt_secret \
            "WARP WireGuard PrivateKey（输入不回显；已有值可直接回车保留）" \
            "WARP WireGuard PrivateKey (hidden; press Enter to keep the saved value)") \
            || die "启用 Gemini WARP 需要交互式输入 WARP PrivateKey"
        XHTTP_WARP_PRIVATE_KEY=${private_key:-${XHTTP_WARP_PRIVATE_KEY:-}}
        peer_public_key=$(prompt_value \
            "WARP Peer PublicKey" \
            "${XHTTP_WARP_PEER_PUBLIC_KEY:-${XHTTP_WARP_DEFAULT_PEER_PUBLIC_KEY}}" \
            "WARP peer PublicKey")
        endpoint=$(prompt_value \
            "WARP Endpoint" \
            "${XHTTP_WARP_ENDPOINT:-${XHTTP_WARP_DEFAULT_ENDPOINT}}" \
            "WARP endpoint")
        address=$(prompt_value \
            "WARP Address 列表（逗号或空格分隔）" \
            "${XHTTP_WARP_ADDRESS:-${XHTTP_WARP_DEFAULT_ADDRESS}}" \
            "WARP Address list, comma or space separated")
        reserved=$(prompt_value \
            "WARP reserved 三字节（逗号或空格分隔；没有则保留 0,0,0）" \
            "${XHTTP_WARP_RESERVED:-${XHTTP_WARP_DEFAULT_RESERVED}}" \
            "WARP reserved 3 bytes, comma or space separated; keep 0,0,0 if unavailable")
        XHTTP_WARP_PEER_PUBLIC_KEY=${peer_public_key}
        XHTTP_WARP_ENDPOINT=${endpoint}
        XHTTP_WARP_ADDRESS=${address}
        XHTTP_WARP_RESERVED=${reserved}
        normalize_xhttp_gemini_warp_state
        ;;
    *)
        die "无效选择：${choice}"
        ;;
    esac
}

xray_gemini_domains_json() {
    jq -cn '[
      "domain:gemini.google.com",
      "domain:bard.google.com",
      "domain:gemini.gstatic.com",
      "domain:www.gstatic.com",
      "domain:accounts.google.com",
      "domain:ogs.google.com",
      "domain:www.google.com",
      "domain:www.google.com.hk",
      "domain:generativeai.google",
      "domain:generativelanguage.googleapis.com",
      "domain:proactivebackend-pa.googleapis.com",
      "domain:apis.google.com",
      "domain:clients4.google.com",
      "domain:ogads-pa.clients6.google.com",
      "domain:waa-pa.clients6.google.com",
      "domain:signaler-pa.clients6.google.com",
      "domain:alkalimakersuite-pa.clients6.google.com",
      "domain:makersuite.google.com",
      "domain:ai.google.dev"
    ]'
}

xray_xhttp_outbounds_json() {
    local addresses reserved
    if ! xhttp_gemini_warp_enabled; then
        xray_direct_outbounds_json
        return
    fi
    normalize_xhttp_gemini_warp_state
    addresses=$(warp_address_json)
    reserved=$(warp_reserved_json)
    jq -cn --arg strategy "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" \
        --arg secret_key "${XHTTP_WARP_PRIVATE_KEY}" \
        --arg peer_public_key "${XHTTP_WARP_PEER_PUBLIC_KEY}" \
        --arg endpoint "${XHTTP_WARP_ENDPOINT}" \
        --argjson addresses "${addresses}" \
        --argjson reserved "${reserved}" '[
      {protocol:"freedom",tag:"direct",settings:{domainStrategy:$strategy}},
      {protocol:"wireguard",tag:"warp",settings:{
        secretKey:$secret_key,
        address:$addresses,
        peers:[{publicKey:$peer_public_key,endpoint:$endpoint,allowedIPs:["0.0.0.0/0","::/0"],keepAlive:10}],
        reserved:$reserved,
        mtu:1280,
        noKernelTun:true,
        domainStrategy:"ForceIPv4"
      }},
      {protocol:"blackhole",tag:"block"}
    ]'
}

xray_xhttp_routing_json() {
    local private_ranges gemini_domains
    if ! xhttp_gemini_warp_enabled; then
        xray_direct_routing_json
        return
    fi
    private_ranges=$(xray_private_ranges_json)
    gemini_domains=$(xray_gemini_domains_json)
    jq -cn --argjson private "${private_ranges}" --argjson gemini "${gemini_domains}" '{
      domainStrategy:"IPOnDemand",
      rules:[
        {type:"field",ip:$private,outboundTag:"block"},
        {type:"field",domain:$gemini,outboundTag:"warp"},
        {type:"field",network:"tcp,udp",outboundTag:"direct"}
      ]
    }'
}
