#!/usr/bin/env bash

# Cloudflare CDN XHTTP stream-up profile.
#
# This Profile provides pure VLESS XHTTP stream-up over Cloudflare CDN,
# fully adapted to Cloudflare HTTP/2 and gRPC edge streaming with
# randomized keep-alive server timeout and packet padding.
# Always outputs 6 curated IPv4 nodes.

set -Eeuo pipefail
umask 077

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    printf 'xhttp-cloudflare-streamup.sh 是 easy_all 的 Cloudflare 纯 XHTTP Stream-up Profile；请使用：easy_all install\n' >&2
    exit 2
fi

readonly XHTTP_CLOUDFLARE_PROFILE_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
readonly XHTTP_LIB_DIR="${XHTTP_CLOUDFLARE_PROFILE_ROOT}/../lib"
readonly CLOUDFLARE_API_BASE="https://api.cloudflare.com/client/v4"
readonly CLOUDFLARE_ORIGIN_VALIDITY_DAYS=5475
readonly CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS="20-40"
readonly CLOUDFLARE_XHTTP_PADDING_BYTES="100-1000"
readonly CLOUDFLARE_ORIGIN_CA_ROOT_URL="https://developers.cloudflare.com/ssl/static/origin_ca_ecc_root.pem"
readonly CLOUDFLARE_ORIGIN_IPS_FILE="/etc/easy_all/cloudflare-origin-ipv4.txt"
readonly CLOUDFLARE_UFW_COMMENT="easy_all-cloudflare-origin"
readonly CLOUDFLARE_XHTTP_PROBE_ATTEMPTS="${CLOUDFLARE_XHTTP_PROBE_ATTEMPTS_OVERRIDE:-6}"
readonly CLOUDFLARE_XHTTP_PROBE_INTERVAL="${CLOUDFLARE_XHTTP_PROBE_INTERVAL_OVERRIDE:-5}"
readonly CLOUDFLARE_XHTTP_PROBE_URL="${CLOUDFLARE_XHTTP_PROBE_URL_OVERRIDE:-https://www.gstatic.com/generate_204}"

# shellcheck source=lib/xhttp-runtime.sh
SUBSCRIPTION_DEPLOY_DESCRIPTION_OVERRIDE="Nginx HTTPS（Cloudflare 代理域名）"
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
# shellcheck source=lib/globalping-cdn.sh
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"
source "${XHTTP_LIB_DIR}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"
# shellcheck source=lib/cf-dns.sh
source "${XHTTP_LIB_DIR}/cf-dns.sh"

xhttp_configure_ufw() {
    local desired_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ufw
    fi
    ensure_ssh_boot_service
    detect_ssh_ports strict
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    ufw_tcp_port_has_unmanaged_anywhere_allow 443 \
        && die "检测到非 easy_all 管理的 TCP 443 全网放行规则；请先删除该规则，避免暴露源站与绕过 Cloudflare 回源白名单"
    desired_ports=${SSH_PORTS}
    apply_ssh_ufw_policy "${desired_ports}"
    cloudflare_configure_origin_firewall
    apply_ssh_ufw_policy "${desired_ports}"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | awk '/^Status: active$/ {found=1} END {exit !found}' \
        || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

cloudflare_validate_node_domain_input() {
    local domain=$1 zone_id zone zone_name prefix
    CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR=""
    zone_id=$(cloudflare_lookup_parent_zone "${domain}") || {
        CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR="Cloudflare Active Zone 未覆盖 ${domain}"
        return 1
    }
    zone=$(cloudflare_api_request GET "/zones/${zone_id}") || return 1
    zone_name=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    [[ -n "${zone_name}" ]] || {
        CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR="Cloudflare Zone 未返回有效名称"
        return 1
    }
    if [[ "${domain}" == "${zone_name}" ]]; then
        CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR="不能直接使用主域名 ${zone_name}；请输入一级子域名，例如 node.${zone_name}"
        return 1
    fi
    [[ "${domain}" == *."${zone_name}" ]] || {
        CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR="${domain} 不属于 Cloudflare Zone ${zone_name}"
        return 1
    }
    prefix=${domain%.${zone_name}}
    [[ -n "${prefix}" && "${prefix}" != *.* ]] || {
        CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR="仅支持 Cloudflare Zone 下的一级子域名，例如 node.${zone_name}"
        return 1
    }
    CLOUDFLARE_ZONE_ID=${zone_id}
    CLOUDFLARE_CDN_ZONE_ID=${zone_id}
    CLOUDFLARE_ZONE_NAME=${zone_name}
}

cloudflare_validate_zones() {
    local zone
    CLOUDFLARE_ZONE_ID=$(cloudflare_find_parent_zone "${VLESS_CDN_DOMAIN}")
    CLOUDFLARE_CDN_ZONE_ID=${CLOUDFLARE_ZONE_ID}
    CLOUDFLARE_SUBSCRIPTION_ZONE_ID=$(cloudflare_find_parent_zone "$(active_subscription_link_domain)")
    [[ "${CLOUDFLARE_ZONE_ID}" == "${CLOUDFLARE_SUBSCRIPTION_ZONE_ID}" ]] || die "订阅域名必须在同一个 Cloudflare Zone"
    zone=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}")
    CLOUDFLARE_ZONE_NAME=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    [[ -n "${CLOUDFLARE_ZONE_NAME}" ]] || die "Cloudflare Zone 未返回有效名称"
    cloudflare_validate_universal_hostname "${VLESS_CDN_DOMAIN}"
    cloudflare_validate_universal_hostname "$(active_subscription_link_domain)"
}

cloudflare_validate_universal_hostname() {
    local host=$1 prefix
    [[ "${host}" == *."${CLOUDFLARE_ZONE_NAME}" ]] \
        || die "${host} 不属于 Cloudflare Zone ${CLOUDFLARE_ZONE_NAME}"
    prefix=${host%.${CLOUDFLARE_ZONE_NAME}}
    [[ -n "${prefix}" && "${prefix}" != *.* ]] \
        || die "Cloudflare 模式首版只支持 Zone 下的一级子域名：${host}"
}

cloudflare_prepare_origin() {
    local ip
    cloudflare_collect_api_token
    cloudflare_validate_zones
    ip=${VPS_PUBLIC_IPV4:-$(detect_public_ipv4)} || die "无法探测 VPS 公网 IPv4"
    validate_ipv4 "${ip}" || die "VPS 公网 IPv4 无效：${ip}"
    VPS_PUBLIC_IPV4=${ip}
    cloudflare_ensure_proxied_a "${CLOUDFLARE_ZONE_ID}" "${VLESS_CDN_DOMAIN}" "${ip}"
    CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
}

cloudflare_ensure_origin_ca_root() {
    CLOUDFLARE_ORIGIN_CA_ROOT_FILE="${CERT_DIR}/cloudflare-origin-ca-ecc.pem"
    if [[ -s "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" ]] \
        && openssl x509 -in "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" -noout >/dev/null 2>&1; then
        return 0
    fi
    install -d -m 0700 "${CERT_DIR}"
    curl -fsSL --retry 3 --connect-timeout 10 --max-time 30 \
        "${CLOUDFLARE_ORIGIN_CA_ROOT_URL}" \
        -o "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" \
        || die "下载 Cloudflare Origin CA ECC 根证书失败"
    openssl x509 -in "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" -noout >/dev/null 2>&1 \
        || die "Cloudflare Origin CA ECC 根证书格式无效"
    install -m 0644 "${RUNTIME_TMP}/cloudflare-origin-ca-ecc.pem" \
        "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
}

cloudflare_origin_certificate_is_current() {
    local host expected_hosts actual_hosts
    [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]] || return 1
    openssl x509 -in "${CERT_FILE}" -checkend 2592000 -noout >/dev/null 2>&1 \
        || return 1
    while IFS= read -r host; do
        openssl x509 -in "${CERT_FILE}" -checkhost "${host}" -noout >/dev/null 2>&1 \
            || return 1
    done < <(jq -r '.[]' <<<"$(cloudflare_origin_certificate_hosts)")
    expected_hosts=$(cloudflare_origin_certificate_hosts | jq -r '.[]' | sort -u)
    actual_hosts=$(openssl x509 -in "${CERT_FILE}" -noout -ext subjectAltName 2>/dev/null \
        | sed -n '2,$p' | tr ',' '\n' \
        | sed -n 's/^[[:space:]]*DNS://p' | sort -u)
    [[ -n "${actual_hosts}" && "${actual_hosts}" == "${expected_hosts}" ]] \
        || return 1
    [[ "$(openssl x509 -in "${CERT_FILE}" -pubkey -noout 2>/dev/null \
        | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | cut -d' ' -f1)" \
        == "$(openssl pkey -in "${KEY_FILE}" -pubout -outform DER 2>/dev/null \
        | sha256sum | cut -d' ' -f1)" ]] || return 1
}

xhttp_validate_local_tls_curl_args() {
    local headers="${RUNTIME_TMP}/cloudflare-origin-headers"
    cloudflare_ensure_origin_ca_root
    printf 'X-Easy-All-Origin-Key: %s\n' "${ORIGIN_HEADER_SECRET}" >"${headers}"
    chmod 0600 "${headers}"
    XHTTP_LOCAL_TLS_CURL_ARGS=(--proto '=https' --cacert "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}"
        -H "@${headers}")
}

xhttp_renew_origin_certificate() {
    local old_id
    cloudflare_collect_api_token
    old_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    cloudflare_issue_origin_certificate 1
    nginx -t >/dev/null || die "Cloudflare 新源站证书安装后 Nginx 配置校验失败"
    systemctl reload nginx || systemctl restart nginx \
        || die "Cloudflare 新源站证书已安装，但 Nginx 重载失败"
    validate_protocol_runtime
    save_state
    # 吊销不可逆：先关闭回滚再吊销，避免失败路径把已吊销的旧证书恢复回来。
    UPDATE_SUB_ROLLBACK_ON_EXIT=0
    if [[ -n "${old_id}" && "${old_id}" != "${CLOUDFLARE_ORIGIN_CERT_ID}" ]]; then
        if ! (cloudflare_api_request DELETE "/certificates/${old_id}" >/dev/null); then
            warn "新证书已生效，但撤销旧 Cloudflare Origin CA 证书失败：${old_id}"
        fi
    fi
    cloudflare_clear_api_token
    success "Cloudflare Origin CA 源站证书已轮换"
}

cloudflare_ref() { printf 'easy_all_%s' "$(printf '%s' "$1" | sha256sum | cut -c1-24)"; }

cloudflare_managed_ruleset() {
    local name=$1 phase=$2 listed matches count id
    listed=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets")
    matches=$(jq -c --arg phase "${phase}" \
        '[.[] | select(.kind=="zone" and .phase==$phase)]' <<<"${listed}")
    count=$(jq length <<<"${matches}")
    ((count <= 1)) \
        || die "Cloudflare phase ${phase} 存在多个 zone ruleset，拒绝猜测"
    if ((count == 1)); then jq -r '.[0].id' <<<"${matches}"; return; fi
    id=$(cloudflare_api_request POST "/zones/${CLOUDFLARE_ZONE_ID}/rulesets" "$(jq -cn --arg name "${name}" --arg phase "${phase}" '{name:$name,kind:"zone",phase:$phase,rules:[]}')" | jq -r '.id // empty')
    [[ -n "${id}" ]] || die "Cloudflare 未返回 ruleset ID"
    printf '%s\n' "${id}" >>"${RUNTIME_TMP}/cloudflare-created-rulesets"
    printf '%s' "${id}"
}

cloudflare_upsert_rule() {
    local ruleset=$1 ref=$2 payload=$3 rules matches count id
    rules=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    matches=$(jq -c --arg ref "${ref}" '[.rules[]? | select(.ref==$ref)]' <<<"${rules}"); count=$(jq length <<<"${matches}")
    ((count <= 1)) || die "Cloudflare ruleset 中有多个 easy_all ref ${ref}，拒绝覆盖"
    if ((count == 1)); then
        id=$(jq -r '.[0].id' <<<"${matches}")
        cloudflare_api_request PATCH \
            "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${id}" \
            "${payload}" >/dev/null
    else
        cloudflare_api_request POST \
            "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules" \
            "${payload}" >/dev/null
        CLOUDFLARE_CREATED_RULE_REFS+="${CLOUDFLARE_CREATED_RULE_REFS:+$'\n'}${ruleset}"$'\t'"${ref}"
    fi
}

cloudflare_delete_managed_rule() {
    local ruleset=$1 ref=$2 rules matches count id
    [[ -n "${ruleset}" ]] || return 0
    if ! rules=$(cloudflare_api_request GET \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}"); then
        warn "读取 Cloudflare ruleset 失败，保留旧规则 ${ref}"
        return 0
    fi
    matches=$(jq -c --arg ref "${ref}" \
        '[.rules[]? | select(.ref==$ref)]' <<<"${rules}")
    count=$(jq length <<<"${matches}")
    if ((count > 1)); then
        warn "Cloudflare ruleset 中存在多个旧 easy_all ref ${ref}，拒绝删除"
        return 0
    fi
    ((count == 1)) || return 0
    id=$(jq -r '.[0].id' <<<"${matches}")
    if ! (cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${id}" >/dev/null); then
        warn "删除旧 Cloudflare 规则失败：${ref}"
    fi
}

# Persist old ownership with the replacement state, before any remote deletion.
# A disabled subscription has no active identity. Drain its matching pending
# ownership before access checks, without saving uncommitted replacement state.
# Reusing a formerly retired binding makes it active again. Verify its complete
# cloud identity before canceling retirement or retaining only an old domain.
cloudflare_configure_cdn() {
    cloudflare_configure_rules
    cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/settings/origin_max_http_version" \
        "$(jq -cn '{value:"2"}')" >/dev/null
    warn "Cloudflare gRPC 只能在控制台 Network → gRPC 中手动开启，Zone Settings API 不支持该开关"
}

cloudflare_validate_cdn_health() {
    local probe_uuid="${VLESS_UUID}"
    cloudflare_wait_for_health "${VLESS_CDN_DOMAIN}" "CDN"
    if [[ -n "${probe_uuid}" ]]; then
        cloudflare_wait_for_xhttp "${probe_uuid}"
    fi
}

cloudflare_probe_grpc_edge() {
    local domain=$1 body_file metadata="" curl_status=0 http_code="" content_type=""
    CLOUDFLARE_GRPC_EDGE_ERROR=""
    body_file="${RUNTIME_TMP}/cloudflare-grpc-check-body"
    if metadata=$(curl -sS --http2 --proto '=https' --tlsv1.2 \
        --connect-timeout 5 --max-time 15 --noproxy '*' \
        -X POST -H 'Content-Type: application/grpc' -H 'TE: trailers' \
        --data-binary '' -o "${body_file}" \
        -w $'%{http_code}\t%{content_type}' \
        "https://${domain}/easy_all-health" 2>/dev/null); then
        curl_status=0
    else
        curl_status=$?
    fi
    rm -f -- "${body_file}"
    IFS=$'\t' read -r http_code content_type <<<"${metadata}"
    if ((curl_status != 0)); then
        CLOUDFLARE_GRPC_EDGE_ERROR="连接失败：curl=${curl_status},HTTP=${http_code:-000}"
        return 1
    fi
    if [[ "${http_code}" == "403" && "${content_type}" == text/html* ]]; then
        CLOUDFLARE_GRPC_EDGE_ERROR="Cloudflare Zone 尚未开启 gRPC"
        return 1
    fi
    if [[ "${http_code}" != "200" ]]; then
        CLOUDFLARE_GRPC_EDGE_ERROR="HTTP=${http_code:-000},Content-Type=${content_type:-unknown}"
        return 1
    fi
    return 0
}

cloudflare_wait_for_xhttp() {
    local probe_uuid=$1 attempt
    for ((attempt = 1; attempt <= CLOUDFLARE_XHTTP_PROBE_ATTEMPTS; attempt += 1)); do
        cloudflare_probe_xhttp "${probe_uuid}" && return 0
        ((attempt == CLOUDFLARE_XHTTP_PROBE_ATTEMPTS)) && break
        sleep "${CLOUDFLARE_XHTTP_PROBE_INTERVAL}"
    done
    if ! cloudflare_probe_grpc_edge "${VLESS_CDN_DOMAIN}"; then
        if [[ "${CLOUDFLARE_GRPC_EDGE_ERROR}" == \
            "Cloudflare Zone 尚未开启 gRPC" ]]; then
            die "${CLOUDFLARE_GRPC_EDGE_ERROR}；请在控制台 Network → gRPC 开启，等待生效后重新安装"
        fi
        die "Cloudflare XHTTP 端到端验收失败（已重试 ${CLOUDFLARE_XHTTP_PROBE_ATTEMPTS} 次）：${CLOUDFLARE_XHTTP_PROBE_ERROR:-unknown}；gRPC 边缘辅助诊断：${CLOUDFLARE_GRPC_EDGE_ERROR:-unknown}"
    fi
    die "Cloudflare XHTTP 端到端验收失败（已重试 ${CLOUDFLARE_XHTTP_PROBE_ATTEMPTS} 次）：${CLOUDFLARE_XHTTP_PROBE_ERROR:-unknown}"
}

cloudflare_probe_xhttp() {
    local probe_uuid=${1:-${VLESS_UUID}}
    local probe_dir="${RUNTIME_TMP}/cloudflare-xhttp-probe"
    local probe_config="${probe_dir}/config.json" probe_log="${probe_dir}/xray.log"
    local probe_port=0 probe_pid=0 attempt response="" http_code="" curl_status=0 log_summary
    CLOUDFLARE_XHTTP_PROBE_ERROR=""
    install -d -m 0700 "${probe_dir}"
    for attempt in {1..20}; do
        probe_port=$((20000 + RANDOM % 20000))
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . || break
        probe_port=0
    done
    if ((probe_port == 0)); then
        CLOUDFLARE_XHTTP_PROBE_ERROR="无法分配本机探针端口"
        return 1
    fi
    jq -n --arg address "${VLESS_CDN_DOMAIN}" --arg host "${VLESS_CDN_DOMAIN}" \
        --arg uuid "${probe_uuid}" --arg path "$(xhttp_client_path)" \
        --argjson port "${probe_port}" '{
          log:{loglevel:"warning"},
          inbounds:[{
            tag:"cloudflare-xhttp-probe-socks",listen:"127.0.0.1",port:$port,
            protocol:"socks",settings:{udp:false}
          }],
          outbounds:[{
            tag:"proxy",protocol:"vless",
            settings:{vnext:[{address:$address,port:443,
                              users:[{id:$uuid,encryption:"none"}]}]},
            streamSettings:{
              network:"xhttp",security:"tls",
              tlsSettings:{serverName:$host,alpn:["h2"],fingerprint:"chrome"},
              xhttpSettings:{
                host:$host,path:$path,mode:"stream-up",
                extra:{
                  uplinkHTTPMethod:"POST",
                  noGRPCHeader:false,
                  xmux:{
                    maxConnections:4,
                    cMaxReuseTimes:0,
                    hMaxRequestTimes:"300-600",
                    hMaxReusableSecs:"900-1800",
                    hKeepAlivePeriod:0
                  }
                }
              }
            }
          }]
        }' >"${probe_config}" || {
        CLOUDFLARE_XHTTP_PROBE_ERROR="无法生成探针配置"
        return 1
    }
    if ! "${XRAY_BIN}" run -test -config "${probe_config}" >/dev/null 2>"${probe_log}"; then
        log_summary=$(tail -n 4 "${probe_log}" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
        CLOUDFLARE_XHTTP_PROBE_ERROR="配置校验失败${log_summary:+：${log_summary}}"
        return 1
    fi
    "${XRAY_BIN}" run -config "${probe_config}" >"${probe_log}" 2>&1 &
    probe_pid=$!
    for attempt in {1..10}; do
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . && break
        sleep 1
    done
    if ! ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
        kill "${probe_pid}" >/dev/null 2>&1 || true
        wait "${probe_pid}" >/dev/null 2>&1 || true
        log_summary=$(tail -n 4 "${probe_log}" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
        CLOUDFLARE_XHTTP_PROBE_ERROR="SOCKS 探针未启动${log_summary:+：${log_summary}}"
        return 1
    fi
    if response=$(curl -sS --noproxy '' --proxy "socks5h://127.0.0.1:${probe_port}" \
        --connect-timeout 10 --max-time 30 -w $'\n%{http_code}' \
        "${CLOUDFLARE_XHTTP_PROBE_URL}" 2>>"${probe_log}"); then
        curl_status=0
    else
        curl_status=$?
    fi
    http_code=${response##*$'\n'}
    kill "${probe_pid}" >/dev/null 2>&1 || true
    wait "${probe_pid}" >/dev/null 2>&1 || true
    if [[ "${http_code}" == "204" ]]; then
        success "Cloudflare XHTTP 端到端验收通过"
        return 0
    fi
    log_summary=$(tail -n 4 "${probe_log}" | tr '\n' ' ' | sed 's/[[:space:]][[:space:]]*/ /g')
    CLOUDFLARE_XHTTP_PROBE_ERROR="curl=${curl_status},HTTP=${http_code:-000}${log_summary:+，Xray=${log_summary}}"
    return 1
}

cloudflare_wait_for_health() {
    local domain=$1 label=$2 attempt response
    for attempt in {1..60}; do
        response=$(curl -fsS --connect-timeout 5 --max-time 15 "https://${domain}/easy_all-health" 2>/dev/null || true)
        [[ "${response}" == "easy_all ok" ]] && { success "Cloudflare ${label} 公共健康验收通过"; return; }
        sleep 5
    done
    die "Cloudflare ${label} ${domain} 公共健康验收失败；请检查 DNS、Origin CA、Strict TLS 和规则"
}

cloudflare_purge_managed_rule() {
    local ruleset=$1 ref=$2 rules matches count id
    rules=$(cloudflare_api_request GET \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    matches=$(jq -c --arg ref "${ref}" \
        '[.rules[]? | select(.ref==$ref)]' <<<"${rules}")
    count=$(jq length <<<"${matches}")
    ((count <= 1)) \
        || die "Cloudflare ruleset 中有多个 easy_all ref ${ref}，已停止卸载以避免误删"
    ((count == 1)) || return 0
    id=$(jq -r '.[0].id // empty' <<<"${matches}")
    [[ -n "${id}" ]] || die "Cloudflare easy_all 规则缺少 ID：${ref}"
    cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}/rules/${id}" \
        >/dev/null
}

cloudflare_purge_empty_owned_ruleset() {
    local ruleset=$1 expected_name=$2 expected_phase=$3 current
    current=$(cloudflare_api_request GET \
        "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}")
    if jq -e --arg name "${expected_name}" --arg phase "${expected_phase}" '
        .name == $name and .kind == "zone" and .phase == $phase
        and ((.rules // []) | length) == 0
    ' <<<"${current}" >/dev/null; then
        cloudflare_api_request DELETE \
            "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${ruleset}" >/dev/null
    fi
}

cloudflare_purge_managed_dns_record() {
    local host=$1 records count id comment
    records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" A "${host}")
    count=$(jq length <<<"${records}")
    ((count <= 1)) \
        || die "Cloudflare 域名 ${host} 有多个 A 记录，已停止卸载以避免误删"
    ((count == 1)) || return 0
    id=$(jq -r '.[0].id // empty' <<<"${records}")
    comment=$(jq -r '.[0].comment // empty' <<<"${records}")
    if [[ -z "${id}" || "${comment}" != "easy_all xhttp origin" ]]; then
        info "Cloudflare DNS ${host} 不是 easy_all 标记的记录，予以保留"
        return 0
    fi
    cloudflare_api_request DELETE \
        "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${id}" >/dev/null \
        || die "删除 Cloudflare DNS 记录失败：${host}"
}

XRAY_XHTTP_LOOPBACK_PORT="${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT:-10086}}"
ORIGIN_HEADER_SECRET="${ORIGIN_HEADER_SECRET:-}"
BACKEND="xray"
PROTOCOL="cloudflare-streamup"
CDN_PROVIDER="cloudflare"

xhttp_client_path() {
    printf '%s/' "${XHTTP_PATH%/}"
}

collect_cloudflare_node_domain() {
    local domain=${VLESS_CDN_DOMAIN:-}
    while true; do
        if [[ -z "${domain}" ]]; then
            domain=$(prompt_value "客户端连接的 CDN 节点域名（例如 node.example.com）" "")
        fi
        domain=$(normalize_domain "${domain}")
        if ! validate_domain "${domain}"; then
            warn "CDN 节点域名格式无效，请重新输入完整的一级子域名"
            domain=""
            continue
        fi
        if ! cloudflare_validate_node_domain_input "${domain}"; then
            warn "${CLOUDFLARE_NODE_DOMAIN_INPUT_ERROR:-CDN 节点域名无效，请重新输入}"
            domain=""
            continue
        fi
        VLESS_CDN_DOMAIN=${domain}
        return
    done
}

collect_install_inputs() {
    PROTOCOL="cloudflare-streamup"
    BACKEND="xray"
    CDN_PROVIDER="cloudflare"

    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"

    choose_google_egress_mode

    info "Cloudflare 数据面与订阅共用同一代理域名。"
    info "流量说明：代理数据实时经过 VPS；若 VPS 仅计出站，月度出站额度通常是可用代理载荷的主要上限，但协议开销及 Cloudflare 服务规则会进一步约束；双向计费请按服务商口径折算。"
    info "节点域名提示：使用 Cloudflare Active Zone 下未占用的一级子域名，例如 node.example.com；不要提前创建 DNS 记录。"
    cloudflare_collect_api_token
    collect_cloudflare_node_domain
    CLOUDFLARE_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}
    XHTTP_ORIGIN_DOMAIN=${VLESS_CDN_DOMAIN}

    info "Cloudflare 模式从官方 IPv4 CIDR 轮换抽样，并使用三网 Globalping eyeball 探针预筛。"
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"

    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "XHTTP_PATH 无效"

    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "XHTTP 本机端口无效"

    ORIGIN_HEADER_SECRET=${ORIGIN_HEADER_SECRET:-$(generate_secret)}
    [[ "${ORIGIN_HEADER_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "Origin header 密钥无效"

    choose_subscription_mode
    SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
    if subscription_enabled; then
        choose_subscription_download_name
        ensure_allowed_tokens 1
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
    fi
}

load_state() {
    local variable env_name index=0 state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local -a variables=(
        STATE_VERSION PROTOCOL BACKEND CDN_PROVIDER TCP_ACCELERATION
        GOOGLE_EGRESS_MODE GOOGLE_EGRESS_RESOLVED
        XHTTP_NODE_NAME VLESS_UUID
        VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN
        CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME
        CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID
        CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
        CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID
        VPS_IP_FAMILY VPS_PUBLIC_IPV4 VPS_PUBLIC_IPV6
        XRAY_XHTTP_LOOPBACK_PORT XHTTP_PATH
        ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
    )
    [[ -f "${state_path}" ]] || return 1
    while IFS= read -r -d '' env_name; do
        ((index < ${#variables[@]})) || return 1
        printf -v "${variables[${index}]}" '%s' "${env_name}"
        index=$((index + 1))
    done < <(env -i bash -c '
        state_path=$1
        shift
        source "$state_path" || exit 1
        for variable; do
            printf "%s\0" "${!variable:-}"
        done
    ' _ "${state_path}" "${variables[@]}")
    ((index == ${#variables[@]})) || return 1
    enforce_ipv4_only_policy
    [[ "${PROTOCOL}" == "cloudflare-streamup" && "${CDN_PROVIDER:-}" == "cloudflare" && "${BACKEND:-}" == "xray" ]] \
        || die "状态不是 Cloudflare XHTTP Stream-up"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 Cloudflare 状态版本：${STATE_VERSION:-缺失}；当前版本为 ${STATE_SCHEMA_VERSION}"
    validate_domain "${CLOUDFLARE_ORIGIN_DOMAIN:-}" && validate_domain "${VLESS_CDN_DOMAIN:-}" \
        && validate_uuid "${VLESS_UUID:-}" || die "Cloudflare 状态缺少有效域名或 UUID"
    XHTTP_PATH=$(normalize_xhttp_path "${XHTTP_PATH:-}")
    validate_xhttp_path "${XHTTP_PATH}" || die "状态中的 XHTTP_PATH 无效"

    XRAY_XHTTP_LOOPBACK_PORT=${XRAY_XHTTP_LOOPBACK_PORT:-${DEFAULT_XRAY_XHTTP_LOOPBACK_PORT}}
    validate_loopback_port "${XRAY_XHTTP_LOOPBACK_PORT}" || die "状态中的 XHTTP 本机端口无效"
    [[ "${CLOUDFLARE_ORIGIN_DOMAIN}" == "${VLESS_CDN_DOMAIN}" ]] \
        || die "Cloudflare 状态不是单一 Proxied 源站域名架构"
    [[ -n "${CLOUDFLARE_ZONE_ID:-}" && -n "${CLOUDFLARE_ZONE_NAME:-}" \
        && -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
        && -n "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON:-}" ]] \
        || die "状态缺少 Cloudflare Zone 或 Origin CA 资源"
    [[ "${ORIGIN_HEADER_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] || die "源站密钥无效"
    XHTTP_ORIGIN_DOMAIN=${CLOUDFLARE_ORIGIN_DOMAIN}
    SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-none}") || die "订阅模式无效"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}") || die "订阅文件名无效"
    [[ -z "${ALLOWED_TOKENS:-}" ]] || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") || die "Token 无效"
    validate_google_egress_policy_state \
        || die "状态缺少有效的 Google 出站策略；请重新安装"
    BACKEND="xray"
    PROTOCOL="cloudflare-streamup"
    CDN_PROVIDER="cloudflare"
}

save_state() {
    local target="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local state_dir
    enforce_ipv4_only_policy
    TCP_ACCELERATION="${TCP_ACCELERATION:-skyline}"
    validate_google_egress_policy_state \
        || die "无法保存无效的 Google 出站策略"
    state_dir="$(dirname "${target}")" || die "无法确定状态文件目录"
    install -d -m 0700 "${state_dir}" || die "无法创建状态文件目录"
    local t v value
    t=$(mktemp "${state_dir}/state.env.XXXXXX") || die "无法创建临时状态文件"
    [[ -n "${t}" && -f "${t}" ]] || die "临时状态文件无效"
    cleanup_files+=("${t}")
    {
        for v in STATE_VERSION PROTOCOL BACKEND CDN_PROVIDER TCP_ACCELERATION \
            GOOGLE_EGRESS_MODE GOOGLE_EGRESS_RESOLVED \
            XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN \
            CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME \
            CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID \
            CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON \
            CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID \
            VPS_IP_FAMILY VPS_PUBLIC_IPV4 VPS_PUBLIC_IPV6 \
            XRAY_XHTTP_LOOPBACK_PORT XHTTP_PATH ORIGIN_HEADER_SECRET ALLOWED_TOKENS \
            SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR; do
            case "${v}" in
            STATE_VERSION) value=${STATE_SCHEMA_VERSION} ;;
            PROTOCOL) value=cloudflare-streamup ;;
            BACKEND) value=xray ;;
            CDN_PROVIDER) value=cloudflare ;;
            SUBSCRIPTION_DOMAIN) value=${VLESS_CDN_DOMAIN} ;;
            *) value=${!v:-} ;;
            esac
            printf '%s=%q\n' "${v}" "${value}" || die "写入临时状态文件失败：${v}"
        done
    } >"${t}" || die "无法打开临时状态文件"
    chmod 0600 "${t}" || die "无法设置状态文件权限"
    mv -f -- "${t}" "${target}" || die "无法原子替换状态文件"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Cloudflare CDN XHTTP stream-up 尚未安装"
    load_state
}

xhttp_render_xray_config() {
    install -d -m 0755 "${XRAY_DIR}"
    local clients
    clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" '[{id:$id,email:$email}]')
    local outbounds routing sockopt
    outbounds=$(xray_xhttp_outbounds_json)
    routing=$(xray_xhttp_routing_json)
    sockopt=$(xray_inbound_sockopt_json)
    jq -n \
        --argjson port "${XRAY_XHTTP_LOOPBACK_PORT}" \
        --argjson clients "${clients}" \
        --arg host "${VLESS_CDN_DOMAIN}" \
        --arg path "${XHTTP_PATH}" \
        --arg secs "${CLOUDFLARE_XHTTP_STREAM_UP_SERVER_SECS}" \
        --arg padding "${CLOUDFLARE_XHTTP_PADDING_BYTES}" \
        --arg xray_asset_dir "${XRAY_DIR}" \
        --argjson sockopt "${sockopt}" \
        --argjson outbounds "${outbounds}" \
        --argjson routing "${routing}" '
        {
          log: { loglevel: "warning" },
          env: {XRAY_LOCATION_ASSET:$xray_asset_dir},
          inbounds: [
            {
              tag: "vless-xhttp-h2-in",
              listen: "127.0.0.1",
              port: $port,
              protocol: "vless",
              settings: {
                clients: $clients,
                decryption: "none"
              },
              streamSettings: {
                network: "xhttp",
                sockopt: $sockopt,
                xhttpSettings: {
                  host: $host,
                  path: $path,
                  mode: "stream-up",
                  xPaddingBytes: $padding,
                  scStreamUpServerSecs: $secs
                }
              },
              sniffing: {
                enabled: true,
                destOverride: ["http", "tls", "quic"],
                routeOnly: false
              }
            }
          ],
          outbounds: $outbounds,
          routing: $routing
        }' >"${RUNTIME_TMP}/xray-config.json"
    if [[ -x "${XRAY_BIN}" ]]; then
        "${XRAY_BIN}" run -test -config "${RUNTIME_TMP}/xray-config.json" >/dev/null 2>&1 || die "Xray 配置校验失败"
    fi
    install -m 0600 "${RUNTIME_TMP}/xray-config.json" "${XRAY_CONFIG}"
}

write_nginx_config() {
    local http2_directive="" listen_h2="http2 "
    if nginx_supports_http2_directive; then
        http2_directive=$'\n    http2 on;'
        listen_h2=""
    fi
    install -d -m 0755 "${WEB_ROOT}"
    {
        write_subscription_nginx_maps
        cat <<EOF
server {
    listen 80;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    location / { return 301 https://${XHTTP_ORIGIN_DOMAIN}\$request_uri; }
}

server {
    listen 443 ssl ${listen_h2}backlog=4096 so_keepalive=15s:5s:3;
    server_name ${XHTTP_ORIGIN_DOMAIN};
    ssl_certificate ${CERT_FILE};
    ssl_certificate_key ${KEY_FILE};
    ssl_protocols TLSv1.2 TLSv1.3;${http2_directive}
    tcp_nodelay on;
    keepalive_timeout 5m;

    location = /easy_all-health {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        default_type text/plain;
        add_header Cache-Control "no-store" always;
        return 200 "easy_all ok\n";
    }

EOF
        write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}"
        cat <<EOF
    location ^~ ${XHTTP_PATH}/ {
        if (\$http_x_easy_all_origin_key != "${ORIGIN_HEADER_SECRET}") { return 404; }
        client_max_body_size 0;
        client_body_timeout 1h;
        grpc_set_header Host ${VLESS_CDN_DOMAIN};
        grpc_set_header X-Real-IP \$http_cf_connecting_ip;
        grpc_set_header X-Forwarded-For \$http_cf_connecting_ip;
        grpc_set_header X-Forwarded-Proto https;
        grpc_set_header X-Easy-All-Origin-Key \$http_x_easy_all_origin_key;
        grpc_socket_keepalive on;
        grpc_read_timeout 1h;
        grpc_send_timeout 1h;
        grpc_pass grpc://127.0.0.1:${XRAY_XHTTP_LOOPBACK_PORT};
        access_log off;
    }

    location / { return 404; }
}
EOF
    } >"${RUNTIME_TMP}/easy_all.conf"
    install -m 0600 "${RUNTIME_TMP}/easy_all.conf" "${NGINX_CONFIG}"
    nginx -t >/dev/null || die "Nginx 配置校验失败"
    systemctl enable --now nginx >/dev/null
    systemctl reload nginx || systemctl restart nginx || die "重载 Nginx 失败"
}

cloudflare_add_streamup_header_rule() {
    local ruleset=$1 host=$2 path=$3 ref
    ref=$(cloudflare_ref "header:${host}:${path}")
    local expr
    expr="http.host eq \"${host}\" and (starts_with(http.request.uri.path, \"${path}\") or starts_with(http.request.uri.path, \"/easy_all-health\") or starts_with(http.request.uri.path, \"/subscribe\"))"
    cloudflare_upsert_rule "${ruleset}" "${ref}" \
        "$(jq -cn --arg ref "${ref}" --arg expr "${expr}" --arg key "${ORIGIN_HEADER_SECRET}" \
            '{ref:$ref,description:"easy_all xhttp streamup origin header",expression:$expr,action:"rewrite",action_parameters:{headers:{"X-Easy-All-Origin-Key":{operation:"set",value:$key}}}}')"
}

cloudflare_configure_rules() {
    local host transform strict ref
    host=${VLESS_CDN_DOMAIN}
    transform=$(cloudflare_managed_ruleset "easy_all xhttp streamup headers ${host}" "http_request_late_transform")
    cloudflare_add_streamup_header_rule "${transform}" "${host}" "${XHTTP_PATH}"
    strict=$(cloudflare_managed_ruleset "easy_all xhttp streamup strict ${host}" "http_config_settings")
    while IFS= read -r host; do
        ref=$(cloudflare_ref "strict:${host}")
        cloudflare_upsert_rule "${strict}" "${ref}" \
            "$(jq -cn --arg ref "${ref}" --arg host "${host}" \
                '{ref:$ref,description:"easy_all xhttp streamup strict origin TLS",expression:("http.host eq \""+$host+"\""),action:"set_config",action_parameters:{ssl:"strict",security_level:"essentially_off",bic:false}}')"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')
    CLOUDFLARE_HEADER_RULESET_ID=${transform}
    CLOUDFLARE_STRICT_RULESET_ID=${strict}
}

build_vless_xhttp_link() {
    local server=$1 node_name=$2
    local client_path extra
    client_path=$(xhttp_client_path)
    extra=$(jq -cn '{
        uplinkHTTPMethod: "POST",
        noGRPCHeader: false,
        xmux: {
            maxConnections: 4,
            cMaxReuseTimes: 0,
            hMaxRequestTimes: "300-600",
            hMaxReusableSecs: "900-1800",
            hKeepAlivePeriod: 0
        }
    }')
    printf 'vless://%s@%s:443?encryption=none&security=tls&type=xhttp&sni=%s&fp=chrome&alpn=h2&host=%s&path=%s&mode=stream-up&extra=%s&packetEncoding=xudp#%s' \
        "${VLESS_UUID}" "${server}" "${VLESS_CDN_DOMAIN}" "${VLESS_CDN_DOMAIN}" \
        "$(uri_encode "${client_path}")" \
        "$(uri_encode "${extra}")" "$(uri_encode "${node_name}")"
}

build_mihomo_xhttp_node() {
    local server=$1 node_name=$2
    local client_path
    client_path=$(xhttp_client_path)
    jq -nr --arg name "${node_name}" --arg server "${server}" \
        --arg host "${VLESS_CDN_DOMAIN}" --arg uuid "${VLESS_UUID}" \
        --arg path "${client_path}" '
        "  - name: \($name|@json)\n    type: vless\n    server: \($server|@json)\n    port: 443\n" +
        "    uuid: \($uuid|@json)\n    network: xhttp\n    tls: true\n    udp: true\n" +
        "    skip-cert-verify: false\n    servername: \($host|@json)\n    client-fingerprint: chrome\n" +
        "    packet-encoding: xudp\n    ip-version: ipv4\n    alpn:\n      - h2\n" +
        "    xhttp-opts:\n      host: \($host|@json)\n      path: \($path|@json)\n      mode: stream-up\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n        max-connections: 4\n" +
        "        c-max-reuse-times: 0\n        h-max-request-times: 300-600\n        h-max-reusable-secs: 900-1800\n        h-keep-alive-period: 0\n"'
}

cloudflare_xhttp_streamup_client_candidates() {
    if cdn_optimization_enabled && cloudflare_globalping_cache_compatible; then
        jq -r '
          .candidates | to_entries[]
          | [.value.ip, ((.key + 1)|tostring), (.value.carrier // "anycast")] | @tsv
        ' "${GLOBALPING_CACHE_FILE}"
    fi
}

cloudflare_validate_client_candidate_counts() {
    local candidates=$1 count=0 ip label carrier
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        count=$((count + 1))
    done <<<"${candidates}"
    ((count == CLOUDFLARE_CANDIDATE_LIMIT)) \
        || die "Cloudflare 没有完整的 6 个已验证 IPv4 入口；请先执行 easy_all refresh-cdn-ips"
}

build_node_links() {
    local ip label carrier candidates
    candidates=$(cloudflare_xhttp_streamup_client_candidates)
    cloudflare_validate_client_candidate_counts "${candidates}"
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        build_vless_xhttp_link "${ip}" "🇺🇸优选${label}"
        printf '\n'
    done <<<"${candidates}"
}

build_mihomo_nodes() {
    local ip label carrier candidates
    candidates=$(cloudflare_xhttp_streamup_client_candidates)
    cloudflare_validate_client_candidate_counts "${candidates}"
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        build_mihomo_xhttp_node "${ip}" "🇺🇸优选${label}"
    done <<<"${candidates}"
}

build_mihomo_proxy_names() {
    printf '        - "AUTO"\n'
}

write_mihomo_url_test_group() {
    local group_name=$1 nodes=$2
    local test_url=${3:-https://cp.cloudflare.com/generate_204} node
    [[ -n "${nodes}" ]] || return 0
    printf '    - name: %s\n' "$(jq -Rn --arg value "${group_name}" '$value')"
    printf '      type: url-test\n      hidden: true\n'
    printf '      proxies:\n'
    while IFS= read -r node; do
        [[ -n "${node}" ]] || continue
        printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
    done <<<"${nodes}"
    cat <<EOF
      url: ${test_url}
      interval: 300
      tolerance: 30
      timeout: 5000
      lazy: true
EOF
}

build_mihomo_proxy_groups() {
    local -a all_nodes=()
    local ip label carrier candidates
    candidates=$(cloudflare_xhttp_streamup_client_candidates)
    cloudflare_validate_client_candidate_counts "${candidates}"
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        all_nodes+=("🇺🇸优选${label}")
    done <<<"${candidates}"
    write_mihomo_url_test_group "AUTO" "$(printf '%s\n' "${all_nodes[@]}")"
}

show_node() {
    collect_installed_state
    printf '\n协议: VLESS XHTTP stream-up over Cloudflare CDN（6 个 IPv4）\n节点链接:\n%s\n\n' "$(build_node_links)"
    printf 'Mihomo / Clash 节点:\n'
    build_mihomo_nodes
}

show_status() {
    require_root
    collect_installed_state
    printf '协议: VLESS XHTTP stream-up（Cloudflare CDN 纯流模式）\n'
    show_tcp_acceleration_status
    printf '后端: Xray (%s)\n客户端 CDN 节点域名: %s\nCloudflare 回源域名: %s（数据面单域名）\nOrigin CA: %s（到期 %s）\n客户端入口 IP 族: IPv4\nGoogle 出站: %s\n候选来源: Cloudflare 官方 IPv4 CIDR / 三网 Globalping eyeball 探针\n域名兜底: disabled\n' \
        "$(xray_installed_version)" "${VLESS_CDN_DOMAIN}" "${CLOUDFLARE_ORIGIN_DOMAIN}" "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}" \
        "$(google_egress_status)"
    printf '核心服务: '
    systemctl is-active --quiet "${XRAY_SERVICE}" 2>/dev/null \
        && printf 'active\n' || printf 'inactive\n'
    printf '后端 TCP %s: ' "${XRAY_XHTTP_LOOPBACK_PORT}"
    [[ -n "$(ss -H -ltn "sport = :${XRAY_XHTTP_LOOPBACK_PORT}" 2>/dev/null || true)" ]] \
        && printf 'listening\n' || printf 'not listening\n'
    if subscription_enabled; then
        printf '公开订阅: https://%s/subscribe\n' "${VLESS_CDN_DOMAIN}"
    else
        printf '公开订阅: 未部署\n'
    fi
    printf 'VPS 出站: IPv4-only（IPv6 全局禁用）\n'
    show_globalping_status
}

refresh_cloudflare_cdn_ips() {
    local refresh_status=0
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    install_globalping_refresh_timer
    snapshot_subscription_update
    configure_ufw
    collect_globalping_token
    validate_globalping_access || die "Globalping Token 验证失败"
    persist_globalping_token
    if ! refresh_globalping_cache; then
        refresh_status=1
        warn "Globalping 刷新失败，保留上一版本有效缓存"
    fi
    if subscription_enabled; then
        write_subscriptions
        validate_subscription_runtime
    fi
    save_state
    commit_subscription_update
    release_runtime_write_lock
    ((refresh_status == 0)) || return 1
    success "Cloudflare CDN 精选 IP 与订阅已刷新"
}

rollback_fresh_install() {
    if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "${CLOUDFLARE_ZONE_ID:-}" ]]; then
        (cloudflare_rollback_fresh_install_resources) \
            || warn "首次安装创建的 Cloudflare 资源未能全部自动清理"
    fi
    stop_services
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_preinstall_nginx_default_site || warn "恢复安装前 Nginx 默认站点失败"
    # 前置初始化（SWAP、系统依赖、TCP 加速、Skyline Speeder）不作回滚
    restore_preinstall_crontab
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    cloudflare_clear_api_token
    install_progress_clear
}

cloudflare_rollback_fresh_install_resources() {
    local ruleset ref id failed=0
    while IFS=$'\t' read -r ruleset ref; do
        [[ -n "${ruleset}" && -n "${ref}" ]] || continue
        (cloudflare_delete_managed_rule "${ruleset}" "${ref}") || failed=1
    done <<<"${CLOUDFLARE_CREATED_RULE_REFS:-}"
    if [[ -f "${RUNTIME_TMP}/cloudflare-created-rulesets" ]]; then
        while IFS= read -r id; do
            [[ -n "${id}" ]] || continue
            (cloudflare_api_request DELETE \
                "/zones/${CLOUDFLARE_ZONE_ID}/rulesets/${id}" >/dev/null) \
                || { warn "回滚本次新建的 Cloudflare ruleset 失败：${id}"; failed=1; }
        done <"${RUNTIME_TMP}/cloudflare-created-rulesets"
    fi
    if [[ -n "${CLOUDFLARE_CREATED_ORIGIN_CERT_ID:-}" ]]; then
        (cloudflare_api_request DELETE \
            "/certificates/${CLOUDFLARE_CREATED_ORIGIN_CERT_ID}" >/dev/null) \
            || { warn "回滚本次新建的 Origin CA 证书失败"; failed=1; }
    fi
    if [[ -n "${CLOUDFLARE_CREATED_DNS_RECORD_ID:-}" ]]; then
        (cloudflare_api_request DELETE \
            "/zones/${CLOUDFLARE_ZONE_ID}/dns_records/${CLOUDFLARE_CREATED_DNS_RECORD_ID}" \
            >/dev/null) || { warn "回滚本次新建的 Cloudflare DNS 记录失败"; failed=1; }
    fi
    ((failed == 0)) || return 1
    success "本次首次安装新建的 Cloudflare 资源已回滚"
}

# 中断/失败后的本机清理：不触碰云端资源，交给 purge-cloudflare 处理。
cleanup_partial_install() {
    cleanup_partial_install_local || return 1
    remove_daily_reboot_schedule || true
    cleanup_partial_install_files \
        "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}" \
        "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
}

install_all() {
    [[ -t 0 ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="cloudflare"
    BACKEND="xray"
    PROTOCOL="cloudflare-streamup"
    require_root
    require_systemd
    acquire_runtime_write_lock

    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    check_platform
    report_host_init_state
    ensure_swap
    install_failure_begin cloudflare-streamup
    check_install_conflicts
    install_progress_begin cloudflare-streamup
    install_progress_stage packages
    snapshot_fresh_install
    install_packages
    ensure_ssh_boot_service
    install_progress_stage tcp
    choose_tcp_acceleration
    configure_tcp_acceleration
    configure_daily_reboot
    configure_ipv4_only
    install_progress_stage inputs
    collect_install_inputs
    cloudflare_prepare_origin
    install_progress_stage services
    configure_ufw
    write_bootstrap_nginx_config
    cloudflare_issue_origin_certificate 0
    download_xray
    xhttp_render_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    install_progress_stage cloud
    cloudflare_configure_cdn
    cloudflare_validate_cdn_health
    refresh_globalping_cache \
        || die "首次 Globalping 测量失败"
    subscription_enabled && { write_subscriptions; validate_subscription_runtime; }
    install_progress_stage state
    save_state
    register_easy_all_command
    persist_globalping_token
    install_globalping_refresh_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    install_progress_clear
    cloudflare_finalize_certificate_rotation
    cloudflare_clear_api_token
    # 从这里开始只剩展示类命令：失败不再算“安装失败”。
    INSTALL_FAILURE_ARMED=0
    show_subscription
    success "easy_all Cloudflare CDN XHTTP 与本地订阅安装完成"
    show_tcp_acceleration_status
    prompt_kernel_reboot
}

apply_easy_all() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    snapshot_subscription_update
    configure_tcp_acceleration
    configure_ipv4_only
    refresh_google_egress_selection
    configure_ufw
    if ! globalping_cache_valid; then
        info "当前 Globalping 优选缓存未就绪或已过期，正在执行刷新..."
        refresh_globalping_cache || warn "Globalping 刷新失败，将继续使用现有兼容缓存"
    fi
    finish_xhttp_apply 1 0 1
    save_state
    show_subscription
    install_globalping_refresh_timer
    commit_subscription_update
    success "Cloudflare XHTTP stream-up 本机配置已应用；未修改 Cloudflare 资源"
    warn "提示：若客户端节点超时，请检查 Cloudflare 控制台（域名 -> 网络 -> gRPC）是否已开启！"
}

apply_cloud_resources() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    snapshot_subscription_update
    configure_tcp_acceleration
    configure_ipv4_only
    refresh_google_egress_selection
    configure_ufw
    xhttp_render_xray_config
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn
    if ! globalping_cache_valid; then
        collect_globalping_token
        validate_globalping_access || die "Globalping Token 验证失败"
        persist_globalping_token
        refresh_globalping_cache \
            || die "Cloudflare 入口策略变化后无法生成兼容缓存"
    fi
    finish_xhttp_apply 1 0 1
    cloudflare_validate_cdn_health
    save_state
    install_globalping_refresh_timer
    commit_subscription_update
    cloudflare_finalize_certificate_rotation
    cloudflare_clear_api_token
    show_subscription
    success "Cloudflare DNS、Origin CA、规则和本机配置已应用"
}

update_subscription() {
    require_root
    acquire_runtime_write_lock
    collect_installed_state
    snapshot_subscription_update
    choose_google_egress_mode
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
    if subscription_enabled; then
        choose_subscription_download_name
        ensure_allowed_tokens 1
    else
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
    fi
    xhttp_render_xray_config
    cloudflare_prepare_origin
    cloudflare_issue_origin_certificate 0
    cloudflare_configure_cdn
    if ! globalping_cache_valid; then
        collect_globalping_token
        validate_globalping_access || die "Globalping Token 验证失败"
        persist_globalping_token
        refresh_globalping_cache \
            || die "Cloudflare IPv4 入口池更新失败，已保留旧缓存"
    fi
    finish_xhttp_apply 1 0 1
    cloudflare_validate_cdn_health
    save_state
    install_globalping_refresh_timer
    commit_subscription_update
    cloudflare_finalize_certificate_rotation
    cloudflare_clear_api_token
    show_subscription
    success "Cloudflare 订阅、Origin CA 与回源规则已更新"
}

purge_cloudflare_resources_before_uninstall() {
    local allow_partial=${1:-0} host header_name strict_name
    [[ "${UNINSTALL_PURGE_CLOUD:-0}" == "1" ]] || return 0
    if [[ "${allow_partial}" != "1" ]]; then
        [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
            && -n "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
            && -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
            || die "状态缺少 Cloudflare 证书或 ruleset ID，已停止卸载；本机状态仍保留"
    fi
    cloudflare_collect_api_token

    if [[ -n "${CLOUDFLARE_HEADER_RULESET_ID:-}" ]]; then
        cloudflare_purge_managed_rule "${CLOUDFLARE_HEADER_RULESET_ID}" \
            "$(cloudflare_ref "header:${VLESS_CDN_DOMAIN}:${XHTTP_PATH}")"
    fi
    if [[ -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]]; then
        while IFS= read -r host; do
            cloudflare_purge_managed_rule "${CLOUDFLARE_STRICT_RULESET_ID}" \
                "$(cloudflare_ref "strict:${host}")"
        done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')
    fi

    header_name="easy_all xhttp streamup headers ${VLESS_CDN_DOMAIN}"
    strict_name="easy_all xhttp streamup strict ${VLESS_CDN_DOMAIN}"
    [[ -z "${CLOUDFLARE_HEADER_RULESET_ID:-}" ]] \
        || cloudflare_purge_empty_owned_ruleset "${CLOUDFLARE_HEADER_RULESET_ID}" \
            "${header_name}" "http_request_late_transform"
    [[ -z "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
        || cloudflare_purge_empty_owned_ruleset "${CLOUDFLARE_STRICT_RULESET_ID}" \
            "${strict_name}" "http_config_settings"

    while IFS= read -r host; do
        cloudflare_purge_managed_dns_record "${host}"
    done < <(cloudflare_origin_certificate_hosts | jq -r '.[]')

    if [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]]; then
        cloudflare_api_request DELETE "/certificates/${CLOUDFLARE_ORIGIN_CERT_ID}" >/dev/null \
            || die "Cloudflare Origin CA 吊销失败，已停止卸载；本机状态仍保留"
    fi
    cloudflare_clear_api_token
    success "easy_all 托管的 Cloudflare DNS、规则、ruleset 与 Origin CA 证书已清理"
}

uninstall_all() {
    local mode=${1:-} answer state_path
    require_root
    [[ -z "${mode}" || "${mode}" == "--purge-cloud" ]] \
        || die "uninstall 不支持参数：${mode}"
    [[ -f "${STATE_FILE}" || -d "${STATE_DIR}" ]] || die "easy_all Cloudflare XHTTP stream-up 尚未安装"
    if [[ "${mode}" == "--purge-cloud" && ! -f "${STATE_FILE}" ]]; then
        die "缺少状态文件，无法安全识别 easy_all 托管的 Cloudflare 资源；本机内容未删除"
    fi
    [[ ! -f "${STATE_FILE}" ]] || load_state
    [[ "${FORCE:-0}" == 1 || -t 0 ]] \
        || die "非交互卸载必须设置 FORCE=1"
    UNINSTALL_PURGE_CLOUD=0
    [[ "${mode}" == "--purge-cloud" ]] && UNINSTALL_PURGE_CLOUD=1
    if [[ "${FORCE:-0}" != 1 ]]; then
        if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
            read_bilingual \
                '删除本机内容以及 easy_all 托管的 Cloudflare DNS、规则和 Origin CA 证书？[y/N]:' answer
        else
            read_bilingual \
                '删除本机内容（Cloudflare 资源保留）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    stop_maintenance_services
    acquire_runtime_write_lock "${UNINSTALL_LOCK_WAIT_OVERRIDE:-60}"
    # 拿到写锁后重新读取状态，避免使用等待期间已被其他任务更新的旧值。
    state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    if [[ -f "${state_path}" ]]; then
        load_state
    fi
    purge_cloudflare_resources_before_uninstall
    if [[ "${UNINSTALL_PURGE_CLOUD}" != 1 ]]; then
        warn "Cloudflare 资源（DNS/规则/Origin CA）已保留；本机状态即将删除，之后无法再用 easy_all 清理这些资源"
    fi
    stop_services
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_platform_security_state || {
        warn "SSH 恢复失败；保留防火墙放行、状态与备份，请修正后重试"
        return 1
    }
    restore_preinstall_firewall
    restore_preinstall_ipv6
    restore_preinstall_nginx_default_site || warn "恢复安装前 Nginx 默认站点失败"
    remove_daily_reboot_schedule
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    if [[ "${UNINSTALL_PURGE_CLOUD}" == 1 ]]; then
        success "本机内容及 easy_all 托管的 Cloudflare 远端资源已卸载"
    else
        success "本机内容已卸载；远端 Cloudflare 资源已保留"
    fi
}
