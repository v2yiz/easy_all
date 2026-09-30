#!/usr/bin/env bash
# Independent TCP Worker; shares CDN candidates and the authenticated node source.

readonly WORKER_BACKUP_SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)"
readonly WORKER_BACKUP_GROUP_NAME="🇭🇰CF"
readonly WORKER_BACKUP_NODE_LIMIT=6
WORKER_BACKUP_PROBE_PID=0

worker_backup_enabled() {
    [[ "${WORKER_BACKUP_DECOMMISSION:-0}" != "1" && -n "${WORKER_BACKUP_DOMAIN:-}" ]]
}

validate_worker_backup_state() {
    worker_backup_enabled || return 0
    validate_domain "${WORKER_BACKUP_DOMAIN}" \
        && validate_cloudflare_worker_name "${WORKER_BACKUP_NAME:-}" \
        && validate_uuid "${WORKER_BACKUP_UUID:-}" \
        && [[ "${WORKER_BACKUP_PATH:-}" =~ ^/[A-Za-z0-9/_-]+$ ]] \
        || die "Worker 兜底配置无效"
    [[ "${WORKER_BACKUP_DOMAIN}" != "${VLESS_CDN_DOMAIN}" \
        && "${WORKER_BACKUP_DOMAIN}" != "${SUBSCRIPTION_DOMAIN:-}" \
        && "${WORKER_BACKUP_NAME}" != "${CLOUDFLARE_WORKER_NAME:-}" ]] \
        || die "兜底 Worker 必须使用独立域名和名称"
    [[ "${WORKER_BACKUP_DOMAIN}" == *."${CLOUDFLARE_ZONE_NAME}" ]] \
        || die "兜底域名必须属于当前 Cloudflare Zone"
    [[ "${WORKER_BACKUP_PLACEMENT:-off}" == "aws:ap-east-1" \
        || "${WORKER_BACKUP_PLACEMENT:-off}" == "off" ]] \
        || die "Worker 兜底 Placement 仅支持 aws:ap-east-1 或 off"
    # Worker traffic is independent and intentionally excluded from VPS quotas.
    local ips=${WORKER_BACKUP_IPS:-[]}
    jq -e --argjson limit "${WORKER_BACKUP_NODE_LIMIT}" \
        'type == "array" and length <= $limit and all(.[]; type == "string")' <<<"${ips}" >/dev/null \
        || die "Worker 兜底 IP 状态无效"
    local ip
    while IFS= read -r ip; do
        validate_public_ipv4 "${ip}" || die "Worker 兜底 IP 不是公网 IPv4"
    done < <(jq -r '.[]' <<<"${ips}")
}

collect_worker_backup_inputs() {
    local domain=${WORKER_BACKUP_DOMAIN:-} choice="" answer=""
    if [[ -n "${domain}" && -t 0 ]]; then
        printf '当前已配置独立 Worker 兜底节点：%s\n' "${domain}" >&2
        printf '  1. 保留当前配置\n  2. 轮换凭据与路径 (UUID / Path)\n  3. 重新配置域名\n  4. 停用并清理兜底节点\n' >&2
        read_bilingual "请选择 [1]（直接回车保留）:" choice
        case "${choice:-1}" in
        1) ;;
        2)
            WORKER_BACKUP_UUID=$(declare -F generate_user_uuid >/dev/null 2>&1 && generate_user_uuid || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')
            WORKER_BACKUP_PATH="/vless-$(openssl rand -hex 12)"
            ;;
        3)
            WORKER_BACKUP_PREV_DOMAIN=${WORKER_BACKUP_DOMAIN}
            WORKER_BACKUP_PREV_DOMAIN_ID=${WORKER_BACKUP_DOMAIN_ID:-}
            WORKER_BACKUP_PREV_NAME=${WORKER_BACKUP_NAME}
            domain=$(prompt_value "兜底 Worker 独立域名" "backup.${CLOUDFLARE_ZONE_NAME}")
            WORKER_BACKUP_DOMAIN=$(normalize_domain "${domain}")
            WORKER_BACKUP_NAME="easyall-backup-$(printf '%s' "${WORKER_BACKUP_DOMAIN}" | sha256sum | cut -c1-10)"
            WORKER_BACKUP_DOMAIN_ID=""
            ;;
        4)
            WORKER_BACKUP_DECOMMISSION=1
            return 0
            ;;
        *)
            die "选项无效：${choice}"
            ;;
        esac
    elif [[ -z "${domain}" && -t 0 ]]; then
        read_bilingual '部署独立 Worker 兜底节点？[Y/n]:' answer
        [[ ! "${answer}" =~ ^[Nn]$ ]] || return 0
        domain=$(prompt_value "兜底 Worker 独立域名" "backup.${CLOUDFLARE_ZONE_NAME}")
    fi
    [[ -n "${domain}" ]] || return 0
    WORKER_BACKUP_DOMAIN=$(normalize_domain "${domain}")
    WORKER_BACKUP_NAME=${WORKER_BACKUP_NAME:-easyall-backup-$(printf '%s' "${WORKER_BACKUP_DOMAIN}" | sha256sum | cut -c1-10)}
    WORKER_BACKUP_UUID=${WORKER_BACKUP_UUID:-${VLESS_UUID:-$(declare -F generate_user_uuid >/dev/null 2>&1 && generate_user_uuid || cat /proc/sys/kernel/random/uuid 2>/dev/null || openssl rand -hex 16 | sed -E 's/(.{8})(.{4})(.{4})(.{4})(.{12})/\1-\2-\3-\4-\5/')}}
    WORKER_BACKUP_PATH=${WORKER_BACKUP_PATH:-/vless-$(openssl rand -hex 12)}
    WORKER_BACKUP_PLACEMENT=${WORKER_BACKUP_PLACEMENT:-off}
    WORKER_BACKUP_IPS=${WORKER_BACKUP_IPS:-[]}
    validate_worker_backup_state
}

worker_backup_probe_config() {
    local address=$1 port=$2
    local client_path="${WORKER_BACKUP_PATH%/}/"
    jq -n --arg address "${address}" --arg host "${WORKER_BACKUP_DOMAIN}" \
        --arg uuid "${WORKER_BACKUP_UUID}" --arg path "${client_path}" \
        --argjson port "${port}" '{
          log:{loglevel:"warning"},
          inbounds:[{
            tag:"worker-backup-probe-socks",listen:"127.0.0.1",port:$port,
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
                host:$host,path:$path,mode:"stream-one",
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
        }'
}

worker_backup_stop_probe() {
    local pid=${WORKER_BACKUP_PROBE_PID:-0}
    WORKER_BACKUP_PROBE_PID=0
    [[ "${pid}" =~ ^[1-9][0-9]*$ ]] || return 0
    kill "${pid}" >/dev/null 2>&1 || true
    wait "${pid}" >/dev/null 2>&1 || true
}

worker_backup_probe() {
    local ip=${1:-} address probe_dir probe_config probe_log
    local probe_port=0 attempt http_code="" curl_status=0
    address=${ip:-${WORKER_BACKUP_DOMAIN}}
    [[ -x "${XRAY_BIN:-}" ]] || return 1
    probe_dir="${RUNTIME_TMP}/worker-backup-probe"
    probe_config="${probe_dir}/config.json"
    probe_log="${probe_dir}/xray.log"
    install -d -m 0700 "${probe_dir}" || return 1
    for attempt in {1..20}; do
        probe_port=$((20000 + RANDOM % 20000))
        ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q . || break
        probe_port=0
    done
    ((probe_port != 0)) || return 1
    worker_backup_probe_config "${address}" "${probe_port}" >"${probe_config}" || return 1
    if ! "${XRAY_BIN}" run -test -config "${probe_config}" >/dev/null 2>"${probe_log}"; then
        return 1
    fi
    "${XRAY_BIN}" run -config "${probe_config}" >"${probe_log}" 2>&1 &
    WORKER_BACKUP_PROBE_PID=$!
    for attempt in {1..10}; do
        if kill -0 "${WORKER_BACKUP_PROBE_PID}" >/dev/null 2>&1 \
            && ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
            break
        fi
        kill -0 "${WORKER_BACKUP_PROBE_PID}" >/dev/null 2>&1 || break
        sleep 1
    done
    if kill -0 "${WORKER_BACKUP_PROBE_PID}" >/dev/null 2>&1 \
        && ss -H -ltn "sport = :${probe_port}" 2>/dev/null | grep -q .; then
        if http_code=$(curl -sS --noproxy '' \
            --proxy "socks5h://127.0.0.1:${probe_port}" \
            --connect-timeout 10 --max-time 30 -o /dev/null -w '%{http_code}' \
            "${CLOUDFLARE_XHTTP_PROBE_URL:-https://www.gstatic.com/generate_204}" \
            2>>"${probe_log}"); then
            curl_status=0
        else
            curl_status=$?
        fi
    else
        curl_status=1
    fi
    worker_backup_stop_probe
    ((curl_status == 0)) && [[ "${http_code}" == "204" ]]
}

cloudflare_deploy_backup_worker() {
    if [[ "${WORKER_BACKUP_DECOMMISSION:-0}" == "1" ]]; then
        return 0
    fi
    worker_backup_enabled || return 0
    validate_worker_backup_state
    local scripts metadata headers response attempt ready=0
    local backup_worker_src="${WORKER_BACKUP_SCRIPT_DIR}/worker-src/backup.js"
    headers="${RUNTIME_TMP}/cloudflare-worker-api-headers"
    printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    scripts=$(cloudflare_api_request GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts")
    local exists
    exists=$(jq --arg name "${WORKER_BACKUP_NAME}" '[.[] | select(.id == $name)] | length' <<<"${scripts}")
    if [[ "${exists}" != "0" && -z "${WORKER_BACKUP_DOMAIN_ID:-}" ]]; then
        die "兜底 Worker 名称已存在且无本机所有权记录，拒绝覆盖"
    fi
    if [[ -n "${WORKER_BACKUP_DOMAIN_ID:-}" ]]; then
        local domains
        domains=$(cloudflare_api_request GET "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains")
        jq -e --arg id "${WORKER_BACKUP_DOMAIN_ID}" --arg name "${WORKER_BACKUP_NAME}" \
            --arg host "${WORKER_BACKUP_DOMAIN}" \
            'any(.[]; .id == $id and .service == $name and .hostname == $host)' <<<"${domains}" >/dev/null \
            || die "兜底 Worker 自定义域名所有权不匹配，拒绝更新"
    fi
    if [[ "${exists}" != "0" ]]; then
        local deployments
        local prev_deployment="${RUNTIME_TMP}/backup-worker-deployment-prev.json"
        deployments=$(cloudflare_api_request GET \
            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${WORKER_BACKUP_NAME}/deployments") \
            || die "无法读取兜底 Worker 当前部署，中止更新"
        jq -ce '
          .deployments[0].versions
          | select(type == "array" and length >= 1 and length <= 2)
          | select(all(.[];
              (.version_id | type) == "string"
              and (.version_id | test("^[0-9A-Fa-f-]{36}$"))
              and (.percentage | type) == "number"
              and .percentage > 0))
          | select((map(.percentage) | add) == 100)
          | {
              strategy:"percentage",
              versions:map({version_id,percentage}),
              annotations:{"workers/message":"easy_all automatic rollback"}
            }
        ' <<<"${deployments}" >"${prev_deployment}" \
            || die "兜底 Worker 当前部署信息无效，中止更新以避免无法回滚"
        chmod 0600 "${prev_deployment}"
    fi
    metadata="${RUNTIME_TMP}/backup-worker-metadata.json"
    jq -n --arg uuid "${WORKER_BACKUP_UUID}" --arg path "${WORKER_BACKUP_PATH}" \
        --arg placement "${WORKER_BACKUP_PLACEMENT:-off}" '{
          main_module:"worker.js",compatibility_date:"2026-09-28",
          bindings:[{type:"secret_text",name:"UUID",text:$uuid},
                    {type:"plain_text",name:"WS_PATH",text:$path}]
        } + (if $placement == "off" then {} else {placement:{region:$placement}} end)' >"${metadata}"
    chmod 0600 "${metadata}"
    response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 60 -X PUT -H "@${headers}" \
        -F "metadata=@${metadata};type=application/json" \
        -F "worker.js=@${backup_worker_src};filename=worker.js;type=application/javascript+module" \
        "${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${WORKER_BACKUP_NAME}") \
        || die "兜底 Worker 上传失败"
    if ! jq -e '.success == true' <<<"${response}" >/dev/null 2>&1; then
        if [[ "${WORKER_BACKUP_PLACEMENT:-off}" != "off" ]] \
            && grep -qi 'placement' <<<"${response}"; then
            warn "Cloudflare 账户不支持 Smart Placement（${WORKER_BACKUP_PLACEMENT}），降级为标准 Worker（无固定区域出口）"
            WORKER_BACKUP_PLACEMENT="off"
            jq -n --arg uuid "${WORKER_BACKUP_UUID}" --arg path "${WORKER_BACKUP_PATH}" '{
              main_module:"worker.js",compatibility_date:"2026-09-28",
              bindings:[{type:"secret_text",name:"UUID",text:$uuid},
                        {type:"plain_text",name:"WS_PATH",text:$path}]
            }' >"${metadata}"
            response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 60 -X PUT -H "@${headers}" \
                -F "metadata=@${metadata};type=application/json" \
                -F "worker.js=@${backup_worker_src};filename=worker.js;type=application/javascript+module" \
                "${CLOUDFLARE_API_BASE}/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${WORKER_BACKUP_NAME}") \
                || die "兜底 Worker 上传失败"
            jq -e '.success == true' <<<"${response}" >/dev/null \
                || die "兜底 Worker 部署被 API 拒绝：$(jq -r '.errors[0].message // "未知错误"' <<<"${response}")"
        else
            die "兜底 Worker 部署被 API 拒绝：$(jq -r '.errors[0].message // "未知错误"' <<<"${response}")"
        fi
    fi
    [[ "${exists}" != "0" ]] || WORKER_BACKUP_CREATED=1
    cloudflare_api_request POST \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${WORKER_BACKUP_NAME}/subdomain" \
        '{"enabled":false,"previews_enabled":false}' >/dev/null
    # Reuse Custom Domain conflict checks without changing the subscription Worker.
    local CLOUDFLARE_WORKER_NAME=${WORKER_BACKUP_NAME} SUBSCRIPTION_DOMAIN=${WORKER_BACKUP_DOMAIN}
    local CLOUDFLARE_WORKER_DOMAIN_ID=${WORKER_BACKUP_DOMAIN_ID:-} CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=""
    cloudflare_attach_subscription_worker_domain
    WORKER_BACKUP_DOMAIN_ID=${CLOUDFLARE_WORKER_DOMAIN_ID}
    WORKER_BACKUP_CREATED_DOMAIN_ID=${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID}
    info "正在验收独立 Worker 的 TLS、XHTTP stream-one 与 VLESS TCP 转发"
    for ((attempt=1; attempt<=CLOUDFLARE_WORKER_READY_ATTEMPTS; attempt++)); do
        if worker_backup_probe >/dev/null 2>&1; then ready=1; break; fi
        sleep "${CLOUDFLARE_WORKER_READY_INTERVAL}"
    done
    ((ready == 1)) || die "兜底 Worker 转发验收失败，未发布节点"
}

cloudflare_refresh_backup_nodes() {
    worker_backup_enabled || return 0
    validate_worker_backup_state
    [[ -n "${WORKER_BACKUP_DOMAIN_ID:-}" ]] || die "兜底 Worker 尚未部署"
    local ip selected='[]' candidates
    # Reuse the ranked CDN pool; its original-domain TLS verdict is not reusable.
    # Keep historical addresses as candidates, but only publish fresh probe successes.
    candidates=$( { cloudflare_client_candidates | cut -f1; jq -r '.[]' <<<"${WORKER_BACKUP_IPS:-[]}"; } | awk 'NF && !seen[$0]++')
    while IFS= read -r ip; do
        [[ -n "${ip}" ]] || continue
        validate_public_ipv4 "${ip}" || continue
        if worker_backup_probe "${ip}" >/dev/null 2>&1; then
            selected=$(jq -c --arg ip "${ip}" '. + [$ip]' <<<"${selected}")
            [[ "$(jq length <<<"${selected}")" -lt "${WORKER_BACKUP_NODE_LIMIT}" ]] || break
        fi
    done <<<"${candidates}"
    if [[ "${selected}" == '[]' ]]; then
        warn "本轮 Worker 优选验证全部失败，保留上次优选 IP；首次不发布纯 Worker 节点"
        return 0
    fi
    WORKER_BACKUP_IPS=${selected}
}

worker_backup_nodes() {
    worker_backup_enabled || return 0
    [[ -n "${WORKER_BACKUP_DOMAIN_ID:-}" ]] || return 0
    local client_path="${WORKER_BACKUP_PATH%/}/"
    jq -cn --arg host "${WORKER_BACKUP_DOMAIN}" --arg uuid "${WORKER_BACKUP_UUID}" \
        --arg path "${client_path}" --argjson ips "${WORKER_BACKUP_IPS:-[]}" '
        $ips | to_entries[] | {
          type:"vless",security:"tls",network:"xhttp",mode:"stream-one",uuid:$uuid,host:$host,sni:$host,
          server:.value,port:443,path:$path,udp:false,ipVersion:"ipv4",
          xhttpUplinkHttpMethod:"POST",xhttpNoGrpcHeader:false,
          xhttpXmux:{
            maxConnections:4,
            cMaxReuseTimes:0,
            hMaxRequestTimes:"300-600",
            hMaxReusableSecs:"900-1800",
            hKeepAlivePeriod:0
          },
          name:("🇭🇰CF" + ((.key + 1)|tostring))
        }'
}

build_worker_backup_links() {
    worker_backup_nodes | jq -r '
        ({uplinkHTTPMethod:.xhttpUplinkHttpMethod,noGRPCHeader:.xhttpNoGrpcHeader,xmux:.xhttpXmux}
          | tojson | @uri) as $extra |
        "vless://\(.uuid)@\(.server):443?encryption=none&security=tls&type=xhttp&mode=stream-one&alpn=h2&host=\(.host)&sni=\(.sni)&path=\(.path|@uri)&extra=\($extra)&easyAllBackup=1#\(.name|@uri)"'
}

build_worker_backup_mihomo() {
    worker_backup_nodes | jq -r '
        "  - name: \(.name|@json)\n    type: vless\n    server: \(.server|@json)\n    port: 443\n" +
        "    uuid: \(.uuid|@json)\n    network: xhttp\n    tls: true\n    udp: false\n" +
        "    skip-cert-verify: false\n    servername: \(.host|@json)\n    ip-version: ipv4\n" +
        "    alpn: [h2]\n    xhttp-opts:\n      host: \(.host|@json)\n      path: \(.path|@json)\n      mode: stream-one\n" +
        "      no-grpc-header: false\n      uplink-http-method: POST\n      reuse-settings:\n" +
        "        max-connections: \(.xhttpXmux.maxConnections)\n" +
        "        c-max-reuse-times: \(.xhttpXmux.cMaxReuseTimes)\n" +
        "        h-max-request-times: \(.xhttpXmux.hMaxRequestTimes)\n" +
        "        h-max-reusable-secs: \(.xhttpXmux.hMaxReusableSecs)\n" +
        "        h-keep-alive-period: \(.xhttpXmux.hKeepAlivePeriod)"'
}

cloudflare_rollback_backup_worker() {
    local prev_deployment="${RUNTIME_TMP}/backup-worker-deployment-prev.json"
    local failed=0
    if [[ "${WORKER_BACKUP_CREATED:-0}" == "1" ]]; then
        cloudflare_delete_subscription_worker_resources "${WORKER_BACKUP_DOMAIN_ID:-}" "${WORKER_BACKUP_NAME}" || failed=1
    else
        if [[ -n "${WORKER_BACKUP_CREATED_DOMAIN_ID:-}" ]]; then
            if cloudflare_api_request DELETE \
                "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/${WORKER_BACKUP_CREATED_DOMAIN_ID}" \
                >/dev/null 2>&1; then
                WORKER_BACKUP_CREATED_DOMAIN_ID=""
            else
                failed=1
            fi
        fi
        if [[ -s "${prev_deployment}" ]]; then
            if (cloudflare_api_request POST \
                "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/${WORKER_BACKUP_NAME}/deployments?force=true" \
                "$(<"${prev_deployment}")" >/dev/null); then
                rm -f -- "${prev_deployment}"
            else
                local recovery_dir="${STATE_DIR}/recovery" recovery
                if install -d -m 0700 "${recovery_dir}" \
                    && recovery=$(mktemp "${recovery_dir}/backup-worker-deployment.XXXXXX") \
                    && install -m 0600 "${prev_deployment}" "${recovery}"; then
                    warn "恢复兜底 Worker ${WORKER_BACKUP_NAME} 版本失败；账户 ${CLOUDFLARE_ACCOUNT_ID} 的部署快照已保留在 ${recovery}"
                else
                    # Never let the outer EXIT cleanup remove the only recovery copy.
                    local retained="${RUNTIME_TMP}.deployment-recovery.json"
                    if install -m 0600 "${prev_deployment}" "${retained}"; then
                        warn "无法写入恢复目录；部署快照保留在 ${retained}"
                    else
                        warn "无法持久化部署快照；恢复请求内容：$(<"${prev_deployment}")"
                    fi
                fi
                failed=1
            fi
        fi
    fi
    ((failed == 0)) || return 1
}

# Stage retirement in the same state transaction as the replacement subscription.
# No remote deletion is allowed until that transaction has committed.
validate_backup_retirements() {
    jq -e 'type == "array" and all(.[];
        (.account | type == "string" and test("^[A-Za-z0-9_-]+$")) and
        (.name | type == "string" and test("^[a-z0-9][a-z0-9-]{0,62}$")) and
        (.id | type == "string" and test("^[A-Za-z0-9_-]*$")))' \
        <<<"${WORKER_BACKUP_RETIREMENTS:-[]}" >/dev/null
}

cloudflare_prepare_backup_retirement() {
    local name="" id=""
    validate_backup_retirements || die "兜底 Worker 待清理记录无效；停止提交"
    if [[ "${WORKER_BACKUP_DECOMMISSION:-0}" == "1" ]]; then
        name=${WORKER_BACKUP_NAME:-}
        id=${WORKER_BACKUP_DOMAIN_ID:-}
    elif [[ -n "${WORKER_BACKUP_PREV_NAME:-}" ]]; then
        name=${WORKER_BACKUP_PREV_NAME}
        id=${WORKER_BACKUP_PREV_DOMAIN_ID:-}
    fi
    [[ -n "${name}" ]] || return 0
    WORKER_BACKUP_RETIREMENTS=$(jq -ce --arg account "${CLOUDFLARE_ACCOUNT_ID}" \
        --arg name "${name}" --arg id "${id}" \
        '. + [{account:$account,name:$name,id:$id}] | unique_by([.account,.name,.id])' \
        <<<"${WORKER_BACKUP_RETIREMENTS:-[]}") || die "无法保存兜底 Worker 待清理记录"
}

cloudflare_finalize_backup_worker() {
    # The callers must commit before this function. Failed partial deletions are
    # retried from durable state and never reactivate the retired subscription.
    if ! validate_backup_retirements; then
        warn "兜底 Worker 待清理记录无效；保留记录，请检查 state.env"
        return 0
    fi
    if [[ "${WORKER_BACKUP_DECOMMISSION:-0}" == "1" ]]; then
        WORKER_BACKUP_DOMAIN=""
        WORKER_BACKUP_NAME=""
        WORKER_BACKUP_UUID=""
        WORKER_BACKUP_PATH=""
        WORKER_BACKUP_DOMAIN_ID=""
        WORKER_BACKUP_IPS="[]"
        WORKER_BACKUP_PLACEMENT=""
        WORKER_BACKUP_DECOMMISSION=0
    fi
    WORKER_BACKUP_PREV_NAME=""
    WORKER_BACKUP_PREV_DOMAIN_ID=""
    WORKER_BACKUP_PREV_DOMAIN=""
    WORKER_BACKUP_CREATED=0
    WORKER_BACKUP_CREATED_DOMAIN_ID=""
    rm -f -- "${RUNTIME_TMP}/backup-worker-deployment-prev.json"
    local entry account name id remaining='[]'
    local retirements=${WORKER_BACKUP_RETIREMENTS:-[]}
    while IFS= read -r entry; do
        account=$(jq -r '.account' <<<"${entry}")
        name=$(jq -r '.name' <<<"${entry}")
        id=$(jq -r '.id' <<<"${entry}")
        if [[ "${account}" != "${CLOUDFLARE_ACCOUNT_ID}" \
            || "${name}" == "${WORKER_BACKUP_NAME:-}" \
            || "${name}" == "${CLOUDFLARE_WORKER_NAME:-}" ]] \
            || ! (cloudflare_delete_subscription_worker_resources "${id}" "${name}"); then
            warn "旧兜底 Worker ${name} 尚未清理；已保留记录，下次 apply-cloud 重试"
            remaining=$(jq -c --argjson entry "${entry}" '. + [$entry]' <<<"${remaining}")
        fi
    done < <(jq -c '.[]' <<<"${retirements}")
    WORKER_BACKUP_RETIREMENTS=${remaining}
    if [[ "${remaining}" != "${retirements}" ]]; then
        save_state || warn "清理结果保存失败；下次将重新核对云端资源"
    fi
}
