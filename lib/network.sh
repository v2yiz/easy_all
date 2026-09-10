#!/usr/bin/env bash

# Shared public network discovery and Xray egress policy.

readonly XRAY_OUTBOUND_DOMAIN_STRATEGY="AsIs"
readonly XRAY_INBOUND_TCP_KEEPALIVE_IDLE="300"
readonly XRAY_INBOUND_TCP_KEEPALIVE_INTERVAL="30"
readonly DEFAULT_GOOGLE_EGRESS_MODE="auto"
readonly GOOGLE_EGRESS_PROBE_URL="https://www.gstatic.com/generate_204"
readonly GOOGLE_EGRESS_PROBE_ATTEMPTS="${GOOGLE_EGRESS_PROBE_ATTEMPTS_OVERRIDE:-3}"

validate_ipv6() {
    local ip=${1%%%*} segment rest colons
    [[ -n "${ip}" && ${#ip} -le 39 && "${ip}" == *:* \
        && "${ip}" =~ ^[0-9A-Fa-f:]+$ && "${ip}" != *:::* ]] || return 1
    colons=${ip//[^:]/}
    if [[ "${ip}" == *::* ]]; then
        rest=${ip#*::}
        [[ "${rest}" != *::* ]] || return 1
        ((${#colons} >= 2 && ${#colons} <= 8)) || return 1
    else
        ((${#colons} == 7)) || return 1
    fi
    for segment in ${ip//:/ }; do
        [[ ${#segment} -ge 1 && ${#segment} -le 4 \
            && "${segment}" =~ ^[0-9A-Fa-f]+$ ]] || return 1
    done
}

canonicalize_ipv6() {
    local ip=${1%%%*} canonical=""
    validate_ipv6 "${ip}" || return 1
    if command -v ip >/dev/null 2>&1; then
        canonical=$(ip -6 route get "${ip}" 2>/dev/null \
            | awk 'NR == 1 {for (i=1; i<=NF; i++) if ($i ~ /:/) {print $i; exit}}' \
            || true)
    fi
    [[ -n "${canonical}" ]] || canonical=${ip}
    tr '[:upper:]' '[:lower:]' <<<"${canonical}" | tr -d '\n'
}

detect_public_ipv4() {
    local service ip
    local -a services=(
        "https://api.ipify.org"
        "https://ipv4.icanhazip.com"
        "https://ifconfig.co"
    )
    for service in "${services[@]}"; do
        ip=$(curl -4fsS --noproxy '*' --max-time 10 "${service}" 2>/dev/null \
            | tr -d '[:space:]' || true)
        if validate_ipv4 "${ip}"; then
            printf '%s\n' "${ip}"
            return 0
        fi
    done
    return 1
}

enable_ipv6_for_detection() {
    [[ -d /proc/sys/net/ipv6 ]] || return 1
    sysctl -w net.ipv6.conf.default.disable_ipv6=0 >/dev/null 2>&1 || return 1
    sysctl -w net.ipv6.conf.all.disable_ipv6=0 >/dev/null 2>&1 || return 1
    sysctl -w net.ipv6.conf.lo.disable_ipv6=0 >/dev/null 2>&1 || return 1
}

detect_public_ipv6() {
    local service candidate canonical
    command -v ip >/dev/null 2>&1 || return 1
    ip -6 -o addr show scope global 2>/dev/null | grep -q 'inet6 ' || return 1
    ip -6 route show default 2>/dev/null | grep -q '^default' || return 1
    local -a services=(
        "https://api6.ipify.org"
        "https://ipv6.icanhazip.com"
        "https://ifconfig.co/ip"
    )
    for service in "${services[@]}"; do
        candidate=$(curl -6fsS --noproxy '*' --max-time 10 "${service}" 2>/dev/null \
            | tr -d '[:space:]' || true)
        validate_ipv6 "${candidate}" || continue
        canonical=$(canonicalize_ipv6 "${candidate}") || continue
        printf '%s\n' "${canonical}"
        return 0
    done
    return 1
}

ensure_vps_ip_family() {
    local detected=""
    case "${VPS_IP_FAMILY:-}" in
    dual)
        validate_ipv6 "${VPS_PUBLIC_IPV6:-}" \
            || die "双栈状态缺少有效的 VPS_PUBLIC_IPV6"
        VPS_PUBLIC_IPV6=$(canonicalize_ipv6 "${VPS_PUBLIC_IPV6}")
        return 0
        ;;
    ipv4)
        VPS_PUBLIC_IPV6=""
        return 0
        ;;
    "") ;;
    *) die "VPS_IP_FAMILY 必须是 ipv4 或 dual" ;;
    esac

    if enable_ipv6_for_detection; then
        detected=$(detect_public_ipv6 || true)
    fi
    if [[ -n "${detected}" ]]; then
        VPS_IP_FAMILY="dual"
        VPS_PUBLIC_IPV6=${detected}
        info "检测到可用公网 IPv6：${VPS_PUBLIC_IPV6}；启用 VPS 双栈，Google 出站将在策略选择后锁定"
    else
        VPS_IP_FAMILY="ipv4"
        VPS_PUBLIC_IPV6=""
        info "未检测到可用公网 IPv6；保持 VPS IPv4-only"
    fi
}

vps_dual_stack_enabled() {
    [[ "${VPS_IP_FAMILY:-ipv4}" == "dual" ]]
}

validate_google_egress_mode() {
    [[ "$1" == "auto" || "$1" == "ipv4" || "$1" == "ipv6" ]]
}

validate_google_egress_family() {
    [[ "$1" == "ipv4" || "$1" == "ipv6" ]]
}

native_google_egress_enabled() {
    [[ "${PROTOCOL:-}" != "cloudflare-streamup" \
        || ( "${WARP_SCOPE:-off}" != "google" && "${WARP_SCOPE:-off}" != "all" ) ]]
}

validate_google_egress_policy_state() {
    validate_google_egress_mode "${GOOGLE_EGRESS_MODE:-}" \
        && validate_google_egress_family "${GOOGLE_EGRESS_RESOLVED:-}" \
        || return 1
    native_google_egress_enabled || return 0
    if ! vps_dual_stack_enabled; then
        [[ "${GOOGLE_EGRESS_MODE}" != "ipv6" \
            && "${GOOGLE_EGRESS_RESOLVED}" == "ipv4" ]]
        return
    fi
    case "${GOOGLE_EGRESS_MODE}" in
    auto) return 0 ;;
    ipv4 | ipv6) [[ "${GOOGLE_EGRESS_RESOLVED}" == "${GOOGLE_EGRESS_MODE}" ]] ;;
    esac
}

normalize_google_egress_policy() {
    GOOGLE_EGRESS_MODE=${GOOGLE_EGRESS_MODE:-${DEFAULT_GOOGLE_EGRESS_MODE}}
    validate_google_egress_mode "${GOOGLE_EGRESS_MODE}" \
        || die "GOOGLE_EGRESS_MODE 必须是 auto、ipv4 或 ipv6"
    if ! native_google_egress_enabled; then
        GOOGLE_EGRESS_RESOLVED=${GOOGLE_EGRESS_RESOLVED:-ipv4}
        validate_google_egress_family "${GOOGLE_EGRESS_RESOLVED}" \
            || die "保存的 Google 原生出站地址族无效"
        return 0
    fi
    if ! vps_dual_stack_enabled; then
        [[ "${GOOGLE_EGRESS_MODE}" != "ipv6" ]] \
            || die "Google IPv6 出站需要 VPS 具备可用公网 IPv6"
        GOOGLE_EGRESS_RESOLVED="ipv4"
        return 0
    fi
    case "${GOOGLE_EGRESS_MODE}" in
    ipv4 | ipv6) GOOGLE_EGRESS_RESOLVED=${GOOGLE_EGRESS_MODE} ;;
    auto)
        validate_google_egress_family "${GOOGLE_EGRESS_RESOLVED:-}" \
            || GOOGLE_EGRESS_RESOLVED="ipv4"
        ;;
    esac
}

google_egress_probe_family() {
    local family=$1 flag result code elapsed attempt successes=0 samples="" median
    case "${family}" in
    ipv4) flag=-4 ;;
    ipv6) flag=-6 ;;
    *) return 1 ;;
    esac
    for ((attempt = 1; attempt <= GOOGLE_EGRESS_PROBE_ATTEMPTS; attempt += 1)); do
        result=$(curl "${flag}" -fsS --noproxy '*' --connect-timeout 5 --max-time 10 \
            -o /dev/null -w $'%{http_code}\t%{time_total}' \
            "${GOOGLE_EGRESS_PROBE_URL}" 2>/dev/null) || continue
        code=${result%%$'\t'*}
        elapsed=${result#*$'\t'}
        [[ "${code}" == "204" && "${elapsed}" =~ ^[0-9]+([.][0-9]+)?$ ]] \
            || continue
        samples+="${elapsed}"$'\n'
        successes=$((successes + 1))
    done
    ((successes > 0)) || return 1
    median=$(sort -n <<<"${samples}" | awk '
        {values[NR]=$1}
        END {
            if (NR % 2) printf "%.6f", values[(NR + 1) / 2]
            else printf "%.6f", (values[NR / 2] + values[NR / 2 + 1]) / 2
        }
    ')
    printf '%s\t%s' "${successes}" "${median}"
}

refresh_google_egress_selection() {
    local ipv4_score="" ipv6_score="" selected
    local ipv4_success=0 ipv6_success=0 ipv4_time=0 ipv6_time=0
    normalize_google_egress_policy
    if ! native_google_egress_enabled; then
        info "Google 全部经 WARP 出站；跳过 VPS 原生 Google 探测"
        return 0
    fi
    if ! vps_dual_stack_enabled; then
        GOOGLE_EGRESS_RESOLVED="ipv4"
        info "Google 出站: IPv4（VPS 当前没有可用公网 IPv6）"
        return 0
    fi
    case "${GOOGLE_EGRESS_MODE}" in
    ipv4)
        google_egress_probe_family ipv4 >/dev/null \
            || die "Google IPv4 出站探测失败"
        GOOGLE_EGRESS_RESOLVED="ipv4"
        ;;
    ipv6)
        google_egress_probe_family ipv6 >/dev/null \
            || die "Google IPv6 出站探测失败"
        GOOGLE_EGRESS_RESOLVED="ipv6"
        ;;
    auto)
        ipv4_score=$(google_egress_probe_family ipv4 || true)
        ipv6_score=$(google_egress_probe_family ipv6 || true)
        [[ -n "${ipv4_score}${ipv6_score}" ]] \
            || die "Google IPv4/IPv6 出站探测均失败"
        if [[ -z "${ipv6_score}" ]]; then
            selected="ipv4"
        elif [[ -z "${ipv4_score}" ]]; then
            selected="ipv6"
        else
            IFS=$'\t' read -r ipv4_success ipv4_time <<<"${ipv4_score}"
            IFS=$'\t' read -r ipv6_success ipv6_time <<<"${ipv6_score}"
        fi
        if [[ -n "${ipv4_score}" && -n "${ipv6_score}" ]] \
            && ((ipv6_success > ipv4_success)); then
            selected="ipv6"
        elif [[ -n "${ipv4_score}" && -n "${ipv6_score}" ]] \
            && ((ipv4_success > ipv6_success)); then
            selected="ipv4"
        elif [[ -n "${ipv4_score}" && -n "${ipv6_score}" ]]; then
            if awk -v v4="${ipv4_time}" -v v6="${ipv6_time}" \
                'BEGIN {exit !(v6 < v4)}'; then
                selected="ipv6"
            else
                selected="ipv4"
            fi
        fi
        GOOGLE_EGRESS_RESOLVED=${selected}
        ;;
    esac
    info "Google 出站: ${GOOGLE_EGRESS_RESOLVED}（模式 ${GOOGLE_EGRESS_MODE}；已锁定到下次 apply）"
}

choose_google_egress_mode() {
    local choice default_choice=1
    if ! native_google_egress_enabled; then
        refresh_google_egress_selection
        return
    fi
    GOOGLE_EGRESS_MODE=${GOOGLE_EGRESS_MODE:-${DEFAULT_GOOGLE_EGRESS_MODE}}
    case "${GOOGLE_EGRESS_MODE}" in
    ipv4) default_choice=2 ;;
    ipv6) default_choice=3 ;;
    esac
    if [[ -t 0 ]]; then
        printf '请选择 Google/YouTube 的 VPS 出站 IP 族：\n' >&2
        printf '  1. auto（推荐；探测后锁定 IPv4 或 IPv6，不逐连接回退）\n' >&2
        printf '  2. ipv4（强制全部使用 IPv4）\n' >&2
        printf '  3. ipv6（强制全部使用 IPv6；要求 VPS 双栈）\n' >&2
        read_bilingual "请选择 [${default_choice}]（直接回车使用默认值）:" choice
        case "${choice:-${default_choice}}" in
        1) GOOGLE_EGRESS_MODE="auto" ;;
        2) GOOGLE_EGRESS_MODE="ipv4" ;;
        3) GOOGLE_EGRESS_MODE="ipv6" ;;
        *) die "Google 出站 IP 族选项无效：${choice}" ;;
        esac
    fi
    normalize_google_egress_policy
    refresh_google_egress_selection
}

google_egress_status() {
    normalize_google_egress_policy
    if ! native_google_egress_enabled; then
        printf 'WARP（原生 Google 策略已停用，未执行原生探测）'
        return 0
    fi
    printf '%s（模式 %s）' "${GOOGLE_EGRESS_RESOLVED}" "${GOOGLE_EGRESS_MODE}"
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
    local google_family google_tag google_strategy google_domain_strategy google_source
    normalize_google_egress_policy
    google_family=${GOOGLE_EGRESS_RESOLVED}
    google_tag="direct-google-${google_family}"
    if [[ "${google_family}" == "ipv6" ]]; then
        google_strategy="ForceIPv6"
        google_domain_strategy="UseIPv6"
        google_source=${VPS_PUBLIC_IPV6:-}
    else
        google_strategy="ForceIPv4"
        google_domain_strategy="UseIPv4"
        google_source="0.0.0.0"
    fi
    jq -cn --arg strategy "${XRAY_OUTBOUND_DOMAIN_STRATEGY}" \
        --argjson dual "$(vps_dual_stack_enabled && native_google_egress_enabled \
            && printf true || printf false)" \
        --arg google_tag "${google_tag}" \
        --arg google_strategy "${google_strategy}" \
        --arg google_domain_strategy "${google_domain_strategy}" \
        --arg google_source "${google_source}" '
      [
        {protocol:"freedom",tag:"direct",settings:{domainStrategy:$strategy}}
      ]
      + (if $dual then [
          {
            protocol:"freedom",
            tag:$google_tag,
            sendThrough:$google_source,
            targetStrategy:$google_strategy,
            settings:{domainStrategy:$google_domain_strategy}
          }
        ] else [] end)
      + [{protocol:"blackhole",tag:"block"}]
    '
}

xray_inbound_sockopt_json() {
    jq -cn --argjson idle "${XRAY_INBOUND_TCP_KEEPALIVE_IDLE}" \
        --argjson interval "${XRAY_INBOUND_TCP_KEEPALIVE_INTERVAL}" \
        '{tcpKeepAliveIdle:$idle,tcpKeepAliveInterval:$interval}'
}

xray_direct_routing_json() {
    local private_ranges google_tag
    normalize_google_egress_policy
    google_tag="direct-google-${GOOGLE_EGRESS_RESOLVED}"
    private_ranges=$(xray_private_ranges_json)
    jq -cn --argjson private "${private_ranges}" \
        --argjson dual "$(vps_dual_stack_enabled && native_google_egress_enabled \
            && printf true || printf false)" \
        --arg google_tag "${google_tag}" '{
      domainStrategy:"IPOnDemand",
      rules: (
        [
          {type:"field",ip:$private,outboundTag:"block"},
          {type:"field",network:"udp",port:"443",outboundTag:"block"}
        ]
        + (if $dual then [
            {
              type:"field",
              domain:["geosite:google"],
              outboundTag:$google_tag,
              ruleTag:"google-egress-locked"
            },
            {
              type:"field",
              ip:["geoip:google"],
              outboundTag:$google_tag,
              ruleTag:"google-egress-locked-ip"
            }
          ] else [] end)
        + [{type:"field",network:"tcp,udp",outboundTag:"direct"}]
      )
    }'
}

xray_xhttp_outbounds_json() {
    if declare -F warp_enabled >/dev/null && warp_enabled; then
        warp_xhttp_outbounds_json
        return
    fi
    xray_direct_outbounds_json
}

xray_xhttp_routing_json() {
    if declare -F warp_enabled >/dev/null && warp_enabled; then
        warp_xhttp_routing_json
        return
    fi
    xray_direct_routing_json
}
