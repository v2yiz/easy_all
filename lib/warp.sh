#!/usr/bin/env bash

# Mode 2 only. WARP registration + Xray userspace WireGuard, as in 3x-ui v3.7.0.
# No system tunnel, default-route changes, or automatic device/IP rotation.
readonly WARP_ACCOUNT_FILE="${WARP_ACCOUNT_FILE_OVERRIDE:-${STATE_DIR}/warp/account.json}"
readonly WARP_RECOVERY_FILE="${WARP_RECOVERY_FILE_OVERRIDE:-/root/easy_all-warp-account.json}"
readonly WARP_PENDING_DELETE_FILE="${WARP_PENDING_DELETE_FILE_OVERRIDE:-/root/easy_all-warp-pending-delete.json}"
readonly WARP_PENDING_REGISTRATION_FILE="${RUNTIME_TMP}/warp-pending-registration.json"
readonly WARP_API_BASE="https://api.cloudflareclient.com/v0a4005"
readonly WARP_CLIENT_VERSION="a-6.30-3596"
readonly WARP_TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
WARP_ACCOUNT_CREATED=0

validate_warp_scope() {
    case "${WARP_SCOPE:-off}" in off | gemini | google | all) return 0 ;; esac
    return 1
}

warp_enabled() {
    [[ "${PROTOCOL:-}" == "cloudflare-streamup" && "${WARP_SCOPE:-off}" != "off" ]]
}

warp_geosite_required() {
    warp_enabled && [[ "${WARP_SCOPE}" == "gemini" || "${WARP_SCOPE}" == "google" ]]
}

warp_scope_label() {
    case "${WARP_SCOPE:-off}" in
    off) printf '关闭' ;;
    gemini) printf 'Gemini / Google AI（含 AI Studio、NotebookLM 等）' ;;
    google) printf '全部 Google（含 YouTube）' ;;
    all) printf '全部进入本机 Xray 的代理流量' ;;
    esac
}

choose_warp_scope() {
    local choice default_choice=1
    WARP_SCOPE=${WARP_SCOPE:-off}
    validate_warp_scope || die "WARP_SCOPE 无效"
    [[ "${PROTOCOL:-}" == "cloudflare-streamup" ]] || die "WARP 仅支持模式 2"
    case "${WARP_SCOPE}" in gemini) default_choice=2 ;; google) default_choice=3 ;; all) default_choice=4 ;; esac
    if [[ -t 0 ]]; then
        printf '是否启用 WARP 出站分流？（仅模式 2）\n' >&2
        printf '  1. 不分流，保持原有 VPS 出站策略\n' >&2
        printf '  2. Gemini / Google AI 分流（含 AI Studio、NotebookLM 等）\n' >&2
        printf '  3. 全部 Google 服务分流（包含 YouTube）\n' >&2
        printf '  4. 全部代理流量经 WARP（不改变系统默认路由）\n' >&2
        read_bilingual "请选择 [${default_choice}]（回车保留）:" choice
        case "${choice:-${default_choice}}" in
        1) WARP_SCOPE=off ;;
        2) WARP_SCOPE=gemini ;;
        3) WARP_SCOPE=google ;;
        4) WARP_SCOPE=all ;;
        *) die "WARP 分流选项无效：${choice}" ;;
        esac
    fi
    if warp_enabled; then
        info "WARP 分流：$(warp_scope_label)；不保证 Gemini 地区或账号可用性"
        warp_ensure_account
    fi
}

warp_redact_response() {
    jq '
      walk(if type == "object" then
        with_entries(if (.key | test("token|license|private|secret"; "i"))
          then .value = "<redacted>" else . end)
        else . end)
    ' "$1" 2>/dev/null || cat "$1"
}

warp_register_request() {
    local payload=$1 response=$2 status
    status=$(curl -4 -sS --noproxy '*' --proto '=https' \
        --connect-timeout 10 --max-time 30 --request POST \
        -H "CF-Client-Version: ${WARP_CLIENT_VERSION}" -H 'Content-Type: application/json' \
        --data-binary "@${payload}" -o "${response}" -w '%{http_code}' \
        "${WARP_API_BASE}/reg") || {
        [[ ! -f "${response}" ]] || warp_redact_response "${response}" >&2
        die "WARP API 请求失败：POST /reg（HTTP ${status:-000}）"
    }
    if [[ "${status}" != 2[0-9][0-9] ]] \
        || ! jq -e 'type == "object" and ((.errors // []) | length == 0)' "${response}" >/dev/null; then
        warp_redact_response "${response}" >&2
        die "WARP API 返回错误：POST /reg（HTTP ${status}）"
    fi
}

warp_capture_pending_registration() {
    local response=$1
    jq -e '{
      version:1,device_id:.id,access_token:.token
    } | select(
      (.device_id | type == "string" and length > 0) and
      (.access_token | type == "string" and length > 0)
    )' "${response}" >"${WARP_PENDING_REGISTRATION_FILE}" || {
        warp_redact_response "${response}" >&2
        die "WARP POST /reg 响应缺少设备注销凭据"
    }
    chmod 0600 "${WARP_PENDING_REGISTRATION_FILE}"
}

warp_validate_unregister_credentials() {
    local file=$1
    jq -e '
      (.device_id | type == "string" and length > 0) and
      (.access_token | type == "string" and length > 0)
    ' "${file}" >/dev/null 2>&1
}

warp_validate_account() {
    local file=${1:-${WARP_ACCOUNT_FILE}} address host port
    [[ -s "${file}" ]] || return 1
    jq -e '
      def key: type == "string" and test("^[A-Za-z0-9+/]{43}=$");
      .version == 1 and
      (.device_id | type == "string" and length > 0) and
      (.access_token | type == "string" and length > 0) and
      (.private_key | key) and (.peer.public_key | key) and
      (.peer.endpoint | type == "string" and length > 0) and
      (.addresses | type == "array" and length > 0 and length <= 2 and
        all(.[]; type == "string")) and
      (.reserved | type == "array" and length == 3 and
        all(.[]; type == "number" and floor == . and . >= 0 and . <= 255))
    ' "${file}" >/dev/null 2>&1 || return 1
    while IFS= read -r address; do
        case "${address}" in
        */32) validate_ipv4 "${address%/32}" || return 1 ;;
        */128) validate_ipv6 "${address%/128}" || return 1 ;;
        *) return 1 ;;
        esac
    done < <(jq -r '.addresses[]' "${file}")
    host=$(jq -r '.peer.endpoint' "${file}")
    port=${host##*:}
    [[ "${port}" =~ ^[0-9]{1,5}$ ]] && ((10#${port} > 0 && 10#${port} <= 65535)) || return 1
    host=${host%:*}
    if [[ "${host}" == \[*\] ]]; then
        host=${host#\[}
        validate_ipv6 "${host%\]}" || return 1
    else
        validate_ipv4 "${host}" || validate_domain "${host}" || return 1
    fi
}

warp_account_from_response() {
    local response=$1 private_key_file=$2 destination=$3 reserved
    reserved=$(jq -er '.config.client_id | select(type == "string" and test("^[A-Za-z0-9+/]{4}$"))' \
        "${response}" | openssl base64 -d -A | od -An -v -tu1 | jq -s '.') \
        || { warp_redact_response "${response}" >&2; die "WARP POST /reg 响应缺少有效的 client_id"; }
    jq --rawfile private_key "${private_key_file}" --argjson reserved "${reserved}" '{
      version:1, device_id:.id, access_token:.token,
      private_key:($private_key | gsub("[\r\n]"; "")),
      addresses:[
        (.config.interface.addresses.v4 | select(type == "string" and length > 0) | . + "/32"),
        (.config.interface.addresses.v6 | select(type == "string" and length > 0) | . + "/128")
      ],
      peer:{public_key:.config.peers[0].public_key, endpoint:.config.peers[0].endpoint.host},
      reserved:$reserved
    }' "${response}" >"${destination}" || die "无法解析 WARP 注册响应"
    warp_validate_account "${destination}" || {
        warp_redact_response "${response}" >&2
        die "WARP POST /reg 响应缺少有效的密钥、地址或端点"
    }
}

warp_ensure_account() {
    local choice stage account_dir
    if [[ -e "${WARP_PENDING_DELETE_FILE}" ]]; then
        info "正在处理上次失败后待注销的 WARP 设备"
        warp_unregister_account "${WARP_PENDING_DELETE_FILE}" \
            || die "待注销 WARP 设备仍无法清理；为避免重复注册，已停止"
    fi
    if [[ -e "${WARP_ACCOUNT_FILE}" ]]; then
        warp_validate_account || die "WARP 凭据无效：${WARP_ACCOUNT_FILE}；不会自动重新注册"
        return 0
    fi
    if [[ -e "${WARP_RECOVERY_FILE}" ]]; then
        warp_validate_account "${WARP_RECOVERY_FILE}" \
            || die "WARP 恢复凭据无效：${WARP_RECOVERY_FILE}；不会自动重新注册"
        account_dir=$(dirname "${WARP_ACCOUNT_FILE}")
        install -d -m 0700 "${account_dir}"
        install -m 0600 "${WARP_RECOVERY_FILE}" "${WARP_ACCOUNT_FILE}"
        success "已恢复上次安装失败时保留的 WARP 设备凭据"
        return 0
    fi
    [[ -t 0 ]] || die "首次注册 WARP 必须在交互终端中确认服务条款"
    info "将向 Cloudflare 注册 WARP 设备；凭据只保存在本机，不复用 Cloudflare API Token。"
    read_bilingual "是否同意 WARP 服务条款 https://www.cloudflare.com/application/terms/ 并注册？[y/N]:" choice
    [[ "${choice}" == "y" || "${choice}" == "Y" ]] || die "未同意 WARP 服务条款，已取消"
    if ! command -v wg >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends wireguard-tools
    fi
    stage=$(make_temp_dir)
    wg genkey >"${stage}/private.key" || die "生成 WARP 私钥失败"
    wg pubkey <"${stage}/private.key" >"${stage}/public.key" || die "生成 WARP 公钥失败"
    jq -n --rawfile key "${stage}/public.key" \
        --arg tos "$(date -u '+%Y-%m-%dT%H:%M:%S.000Z')" \
        '{key:($key | gsub("[\r\n]"; "")),tos:$tos,type:"PC",model:"easy_all",name:"easy_all"}' \
        >"${stage}/request.json"
    warp_register_request "${stage}/request.json" "${stage}/response.json"
    warp_capture_pending_registration "${stage}/response.json"
    warp_account_from_response "${stage}/response.json" "${stage}/private.key" "${stage}/account.json"
    account_dir=$(dirname "${WARP_ACCOUNT_FILE}")
    install -d -m 0700 "${account_dir}"
    install -m 0600 "${stage}/account.json" "${WARP_ACCOUNT_FILE}.new"
    mv -f -- "${WARP_ACCOUNT_FILE}.new" "${WARP_ACCOUNT_FILE}"
    WARP_ACCOUNT_CREATED=1
    rm -rf -- "${stage}"
    success "WARP 设备已注册；后续应用复用此凭据，不自动换 IP"
}

warp_unregister_account() {
    local file=${1:-${WARP_ACCOUNT_FILE}} device_id token stage headers response status
    warp_validate_unregister_credentials "${file}" || return 1
    device_id=$(jq -r '.device_id' "${file}")
    token=$(jq -r '.access_token' "${file}")
    stage=$(make_temp_dir)
    headers="${stage}/headers"
    response="${stage}/response.json"
    printf 'CF-Client-Version: %s\nAuthorization: Bearer %s\nAccept: application/json\n' \
        "${WARP_CLIENT_VERSION}" "${token}" >"${headers}"
    chmod 0600 "${headers}"
    status=$(curl -4 -sS --noproxy '*' --proto '=https' \
        --connect-timeout 10 --max-time 30 --request DELETE \
        -H "@${headers}" \
        -o "${response}" -w '%{http_code}' "${WARP_API_BASE}/reg/${device_id}") || {
        [[ ! -s "${response}" ]] || warp_redact_response "${response}" >&2
        warn "WARP API 请求失败：DELETE /reg/${device_id}（HTTP ${status:-000}）"
        return 1
    }
    case "${status}" in
    200 | 204 | 404)
        rm -f -- "${file}"
        return 0
        ;;
    esac
    [[ ! -s "${response}" ]] || warp_redact_response "${response}" >&2
    warn "WARP API 返回错误：DELETE /reg/${device_id}（HTTP ${status}）"
    return 1
}

warp_rollback_fresh_registration() {
    local unregister_file=""
    if [[ -f "${WARP_PENDING_REGISTRATION_FILE}" ]]; then
        unregister_file=${WARP_PENDING_REGISTRATION_FILE}
    elif [[ "${WARP_ACCOUNT_CREATED:-0}" == "1" && -f "${WARP_ACCOUNT_FILE}" ]]; then
        unregister_file=${WARP_ACCOUNT_FILE}
    else
        return 0
    fi
    if warp_unregister_account "${unregister_file}"; then
        info "本次新注册的 WARP 设备已随安装失败回滚"
        return 0
    fi
    if warp_validate_account; then
        install -m 0600 "${WARP_ACCOUNT_FILE}" "${WARP_RECOVERY_FILE}"
        warn "WARP 远端设备注销失败；完整凭据已保留到 ${WARP_RECOVERY_FILE}，下次安装将自动复用"
    else
        install -m 0600 "${unregister_file}" "${WARP_PENDING_DELETE_FILE}"
        warn "WARP 远端设备注销失败；注销凭据已保留到 ${WARP_PENDING_DELETE_FILE}，下次注册前会重试"
    fi
}

warp_finalize_recovery() {
    rm -f -- "${WARP_PENDING_REGISTRATION_FILE}"
    [[ -f "${WARP_RECOVERY_FILE}" ]] || return 0
    warp_validate_account || return 0
    cmp -s "${WARP_RECOVERY_FILE}" "${WARP_ACCOUNT_FILE}" || return 0
    rm -f -- "${WARP_RECOVERY_FILE}"
}

warp_outbound_json() {
    warp_validate_account || die "WARP 凭据缺失或无效；请运行 easy_all warp"
    jq '{
      tag:"warp",protocol:"wireguard",settings:{
        secretKey:.private_key,address:.addresses,reserved:.reserved,
        peers:[{publicKey:.peer.public_key,endpoint:.peer.endpoint}],
        mtu:1420,domainStrategy:"ForceIPv4v6",noKernelTun:true
      }
    }' "${WARP_ACCOUNT_FILE}"
}

warp_rules_json() {
    case "${WARP_SCOPE:-off}" in
    gemini)
        jq -cn '[{type:"field",domain:["geosite:google-gemini"],outboundTag:"warp",ruleTag:"warp-gemini"}]'
        ;;
    google)
        jq -cn '[
          {type:"field",domain:["geosite:google"],outboundTag:"warp",ruleTag:"warp-google"},
          {type:"field",ip:["geoip:google"],outboundTag:"warp",ruleTag:"warp-google-ip"}
        ]'
        ;;
    all | off) printf '[]\n' ;;
    *) die "WARP_SCOPE 无效" ;;
    esac
}

warp_xhttp_outbounds_json() {
    local direct warp
    direct=$(xray_direct_outbounds_json) || return 1
    warp=$(warp_outbound_json) || return 1
    jq -cn --argjson direct "${direct}" --argjson warp "${warp}" --arg scope "${WARP_SCOPE}" \
        'if $scope == "all" then [$warp] + $direct else $direct + [$warp] end'
}

warp_xhttp_routing_json() {
    local routing rules
    routing=$(xray_direct_routing_json) || return 1
    rules=$(warp_rules_json) || return 1
    jq -c --argjson rules "${rules}" --arg scope "${WARP_SCOPE}" '
      .rules = (.rules[:2] + $rules + .rules[2:]) |
      if $scope == "all" then .rules[-1].outboundTag = "warp" else . end
    ' <<<"${routing}"
}

warp_snapshot() {
    local backup=$1
    if [[ -f "${WARP_ACCOUNT_FILE}" ]]; then
        install -m 0600 "${WARP_ACCOUNT_FILE}" "${backup}/warp-account.json"
    else
        install -m 0600 /dev/null "${backup}/warp-account.missing"
    fi
}

warp_restore() {
    local backup=$1
    if [[ -f "${backup}/warp-account.json" ]]; then
        install -d -m 0700 "$(dirname "${WARP_ACCOUNT_FILE}")"
        install -m 0600 "${backup}/warp-account.json" "${WARP_ACCOUNT_FILE}"
    elif [[ -f "${backup}/warp-account.missing" ]]; then
        rm -f -- "${WARP_ACCOUNT_FILE}.new"
        if [[ -f "${WARP_ACCOUNT_FILE}" ]]; then
            warp_validate_account \
                || rm -f -- "${WARP_ACCOUNT_FILE}"
        fi
        if [[ -f "${WARP_ACCOUNT_FILE}" ]]; then
            rm -f -- "${WARP_PENDING_REGISTRATION_FILE}"
            warn "回滚前没有 WARP 凭据；保留本次已注册设备供后续重试"
        elif [[ -f "${WARP_PENDING_REGISTRATION_FILE}" ]]; then
            if ! warp_unregister_account "${WARP_PENDING_REGISTRATION_FILE}"; then
                install -m 0600 "${WARP_PENDING_REGISTRATION_FILE}" \
                    "${WARP_PENDING_DELETE_FILE}"
                warn "WARP 注销失败；已保存凭据，下次注册前重试"
            fi
        fi
    fi
}

# Isolated probe: exercise the exact outbound/settings without exposing a
# permanent SOCKS listener or making quota refresh depend on Internet health.
warp_validate_runtime() (
    warp_enabled || exit 0
    local stage port=0 pid="" attempt response code gemini_route=""
    stage=$(make_temp_dir)
    trap 'if [[ -n "${pid}" ]]; then kill "${pid}" 2>/dev/null || true; wait "${pid}" 2>/dev/null || true; fi; rm -rf -- "${stage}"' EXIT
    trap 'exit 1' INT TERM
    for attempt in {1..20}; do
        port=$((20000 + RANDOM % 20000))
        ss -H -ltn "sport = :${port}" | grep -q . || break
        port=0
    done
    ((port > 0)) || die "无法分配 WARP 本机验证端口"
    jq --argjson port "${port}" --arg access_log "${stage}/access.log" '
      del(.api,.stats,.policy) |
      .log = {access:$access_log,loglevel:"warning"} |
      .inbounds = [{tag:"warp-check",listen:"127.0.0.1",port:$port,
        protocol:"socks",settings:{udp:false}}] |
      .routing.rules = (.routing.rules[:2] + [
        {type:"field",inboundTag:["warp-check"],domain:["full:www.cloudflare.com"],outboundTag:"warp"}
      ] + .routing.rules[2:])
    ' "${XRAY_CONFIG}" >"${stage}/config.json" || die "无法生成 WARP 探针配置"
    "${XRAY_BIN}" run -test -config "${stage}/config.json" >"${stage}/xray.log" 2>&1 \
        || { cat "${stage}/xray.log" >&2; die "WARP 探针配置校验失败"; }
    "${XRAY_BIN}" run -config "${stage}/config.json" >"${stage}/xray.log" 2>&1 &
    pid=$!
    for attempt in {1..20}; do
        kill -0 "${pid}" 2>/dev/null || { cat "${stage}/xray.log" >&2; die "WARP 探针退出"; }
        ss -H -ltn "sport = :${port}" | grep -q . && break
        sleep 0.2
    done
    ss -H -ltn "sport = :${port}" | grep -q . || die "WARP 本机 SOCKS 探针未就绪"
    response=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:${port}" \
        --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' "${WARP_TRACE_URL}") \
        || die "WARP 出站验证失败：GET ${WARP_TRACE_URL}；未回退 VPS 原生出口"
    code=${response##*$'\n'}
    [[ "${code}" == "200" ]] && grep -Eq $'^warp=(on|plus)\r?$' <<<"${response}" \
        || { printf '%s\n' "${response}" >&2; die "WARP trace 未确认有效出口（HTTP ${code}）"; }
    printf 'WARP 出站验证通过：%s\n' "$(grep -E '^(ip|loc|warp)=' <<<"${response}" | tr '\n' ' ')"
    code=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:${port}" \
        --connect-timeout 10 --max-time 30 -o "${stage}/gemini.html" -w '%{http_code}' \
        'https://gemini.google.com/') || die "Gemini HTTPS 连接失败；未回退 VPS 原生出口"
    for attempt in {1..10}; do
        gemini_route=$(grep -F 'accepted tcp:gemini.google.com:443 [warp-check -> warp]' \
            "${stage}/access.log" 2>/dev/null | tail -n 1 || true)
        [[ -n "${gemini_route}" ]] && break
        sleep 0.1
    done
    [[ -n "${gemini_route}" ]] \
        || { cat "${stage}/access.log" >&2 2>/dev/null || true; die "Gemini 请求未命中 WARP 出站，拒绝保存配置"; }
    success "Gemini 路由验证通过：Xray access log 已确认 warp-check -> warp（HTTP ${code}）"
    info "页面状态不等于账号可用，仍需客户端实际对话验收"
)
