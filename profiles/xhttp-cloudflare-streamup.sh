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
readonly DEFAULT_CLOUDFLARE_WORKER_NAME="easyall"
readonly CLOUDFLARE_WORKER_COMPATIBILITY_DATE="2026-09-09"
readonly CLOUDFLARE_WORKER_SOURCE_HEADER="X-Easy-All-Worker-Source"
readonly CLOUDFLARE_WORKER_SOURCE_FILE="${XHTTP_CLOUDFLARE_PROFILE_ROOT}/../worker-src/index.js"
readonly CLOUDFLARE_WORKER_BUILD_SCRIPT="${XHTTP_CLOUDFLARE_PROFILE_ROOT}/../scripts/build-worker.mjs"
readonly CLOUDFLARE_WORKER_READY_ATTEMPTS="${CLOUDFLARE_WORKER_READY_ATTEMPTS_OVERRIDE:-60}"
readonly CLOUDFLARE_WORKER_READY_INTERVAL="${CLOUDFLARE_WORKER_READY_INTERVAL_OVERRIDE:-5}"
readonly CLOUDFLARE_WORKER_AUTH_ATTEMPTS="${CLOUDFLARE_WORKER_AUTH_ATTEMPTS_OVERRIDE:-6}"
readonly CLOUDFLARE_XHTTP_PROBE_ATTEMPTS="${CLOUDFLARE_XHTTP_PROBE_ATTEMPTS_OVERRIDE:-6}"
readonly CLOUDFLARE_XHTTP_PROBE_INTERVAL="${CLOUDFLARE_XHTTP_PROBE_INTERVAL_OVERRIDE:-5}"
readonly CLOUDFLARE_XHTTP_PROBE_URL="${CLOUDFLARE_XHTTP_PROBE_URL_OVERRIDE:-https://www.gstatic.com/generate_204}"

# shellcheck source=lib/xhttp-runtime.sh
SUBSCRIPTION_DEPLOY_DESCRIPTION_OVERRIDE="Cloudflare Worker 聚合；Nginx 仅作私有节点源"
source "${XHTTP_LIB_DIR}/xhttp-runtime.sh"
readonly CLOUDFLARE_WORKER_BUILD_FILE="${CLOUDFLARE_WORKER_BUILD_FILE_OVERRIDE:-${STATE_DIR}/worker.js}"
# shellcheck source=lib/globalping-cdn.sh
GLOBALPING_CACHE_BASENAME_OVERRIDE="cloudflare-cdn-ips.json"
source "${XHTTP_LIB_DIR}/globalping-cdn.sh"
# shellcheck source=lib/cloudflare-ip-pool.sh
source "${XHTTP_LIB_DIR}/cloudflare-ip-pool.sh"

cloudflare_collect_api_token() {
    if [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]]; then
        CLOUDFLARE_API_TOKEN=$(prompt_secret "Cloudflare API Token（仅当前进程使用，不落盘）") \
            || die "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
    fi
    [[ ${#CLOUDFLARE_API_TOKEN} -ge 20 && ${#CLOUDFLARE_API_TOKEN} -le 512 \
        && "${CLOUDFLARE_API_TOKEN}" != *[[:space:]]* ]] || die "CLOUDFLARE_API_TOKEN 格式无效"
}
cloudflare_clear_api_token() {
    unset CLOUDFLARE_API_TOKEN
    rm -f -- "${RUNTIME_TMP}/cloudflare-api-headers" \
        "${RUNTIME_TMP}/cloudflare-worker-api-headers"
}

cloudflare_api_request() {
    local method=$1 path=$2 payload=${3:-} response headers payload_file status
    [[ -n "${CLOUDFLARE_API_TOKEN:-}" ]] || die "缺少 CLOUDFLARE_API_TOKEN"
    headers="${RUNTIME_TMP}/cloudflare-api-headers"
    printf 'Authorization: Bearer %s\nContent-Type: application/json\n' \
        "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}"
    if [[ -n "${payload}" ]]; then
        payload_file="${RUNTIME_TMP}/cloudflare-api-payload"
        printf '%s' "${payload}" >"${payload_file}"
        chmod 0600 "${payload_file}"
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" -w $'\n%{http_code}' \
            -H "@${headers}" \
            --data-binary "@${payload_file}" "${CLOUDFLARE_API_BASE}${path}") || die "Cloudflare API 请求失败：${method} ${path}"
    else
        response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 45 -X "${method}" -w $'\n%{http_code}' \
            -H "@${headers}" "${CLOUDFLARE_API_BASE}${path}") || die "Cloudflare API 请求失败：${method} ${path}"
    fi
    status=${response##*$'\n'}
    response=${response%$'\n'*}
    if [[ "${method}" == "DELETE" && ( "${status}" == "200" || "${status}" == "204" ) && -z "${response//[[:space:]]/}" ]]; then
        printf 'null\n'
        return 0
    fi
    [[ "${status}" == 2[0-9][0-9] ]] || {
        printf '%s\n' "${response:-<empty>}" >&2
        die "Cloudflare API HTTP ${status:-000}：${method} ${path}"
    }
    jq -e '.success == true' <<<"${response}" >/dev/null \
        || { printf '%s\n' "${response:-<empty>}" >&2; die "Cloudflare API 返回错误（HTTP ${status}）：${method} ${path}"; }
    jq -c '.result' <<<"${response}"
}

validate_cloudflare_worker_name() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

normalize_worker_aggregation_config() {
    local raw=${1:-}
    [[ -n "${raw}" ]] || raw='{}'
    jq -cer '
      if type != "object" then
        error("Worker 聚合配置必须是 JSON object")
      elif has("vpsSubUrl") then
        error("Worker 聚合配置不得包含 vpsSubUrl")
      elif ((keys - ["allowedTokens","nodes","externalSubUrl","fallbackCdnNodes"]) | length) != 0 then
        error("Worker 聚合配置包含不支持的字段")
      elif ((.nodes // []) | type) != "array"
        or ((.fallbackCdnNodes // []) | type) != "array"
        or ((.externalSubUrl // "") | type) != "string"
        or (has("allowedTokens") and (.allowedTokens | type) != "object") then
        error("allowedTokens/nodes/fallbackCdnNodes/externalSubUrl 类型无效")
      else
        {
          nodes:((.nodes // []) | map(
            if ([.server // "", .host // ""] | any(tostring | contains(":"))) then
              error("nodes 不允许 IPv6 literal")
            else . + {ipVersion:"ipv4"} end
          )),
          externalSubUrl:(.externalSubUrl // ""),
          fallbackCdnNodes:((.fallbackCdnNodes // []) | map(
            if ([.server // "", .host // ""] | any(tostring | contains(":"))) then
              error("fallbackCdnNodes 不允许 IPv6 literal")
            else . + {ipVersion:"ipv4"} end
          ))
        }
        + (if has("allowedTokens") then {allowedTokens:.allowedTokens} else {} end)
      end
    ' <<<"${raw}"
}

apply_worker_allowed_tokens_override() {
    local config=$1 tokens token_users quota_users
    jq -e 'has("allowedTokens")' <<<"${config}" >/dev/null || return 0
    tokens=$(normalize_allowed_tokens "$(jq -c '.allowedTokens' <<<"${config}")") \
        || die "Worker 聚合配置中的 allowedTokens 无效"
    if quota_enabled; then
        token_users=$(jq -c 'keys | sort' <<<"${tokens}")
        quota_users=$(jq -c 'keys | sort' <<<"${USER_ACCOUNTS}")
        [[ "${token_users}" == "${quota_users}" ]] \
            || die "启用配额时，Worker 聚合配置 allowedTokens 的用户名必须与配额用户完全一致"
        USER_ACCOUNTS=$(jq -c --argjson tokens "${tokens}" \
            'with_entries(.value.token = $tokens[.key])' <<<"${USER_ACCOUNTS}")
        validate_user_accounts "${USER_ACCOUNTS}" \
            || die "Worker 聚合配置 allowedTokens 覆盖后配额用户状态无效"
    fi
    ALLOWED_TOKENS=${tokens}
    info "Worker 聚合配置的 allowedTokens 已覆盖安装器先前设置的用户 Token"
}

choose_worker_aggregation_config() {
    local choice="" count has_upstream raw current normalized
    current=$(normalize_worker_aggregation_config \
        "${WORKER_AGGREGATION_CONFIG:-}") \
        || die "当前 Worker 聚合配置无效"
    count=$(jq '.nodes | length' <<<"${current}")
    has_upstream=$(jq -r '.externalSubUrl != ""' <<<"${current}")
    if [[ -t 0 ]]; then
        printf '说明：Worker 聚合配置不得包含 vpsSubUrl；若包含 allowedTokens，将覆盖刚设置的用户 Token。\n' >&2
        if ((count > 0)) || [[ "${has_upstream}" == "true" ]]; then
            printf '当前 Worker 聚合配置：nodes=%s，externalSubUrl=%s\n' \
                "${count}" "$([[ "${has_upstream}" == "true" ]] && printf 已配置 || printf 未配置)" >&2
            printf '  1. 保留\n  2. 替换 Worker 聚合 JSON\n  3. 清空聚合配置\n' >&2
            read_bilingual "请选择 [1]（直接回车保留）:" choice
            case "${choice:-1}" in
            1) raw=${current} ;;
            2)
                raw=$(prompt_secret "新的 Worker 聚合 JSON（不得包含 vpsSubUrl）") \
                    || die "读取 Worker 聚合配置失败"
                ;;
            3) raw='{}' ;;
            *) die "Worker 聚合配置选项无效：${choice}" ;;
            esac
        else
            printf '是否需要进行订阅聚合？\n' >&2
            printf '  1. 不需要\n  2. 需要，输入 Worker 聚合 JSON\n' >&2
            read_bilingual "请选择 [1]（直接回车不聚合）:" choice
            case "${choice:-1}" in
            1) raw='{}' ;;
            2)
                raw=$(prompt_secret "Worker 聚合 JSON（不得包含 vpsSubUrl）") \
                    || die "读取 Worker 聚合配置失败"
                ;;
            *) die "Worker 聚合配置选项无效：${choice}" ;;
            esac
        fi
    else
        raw=${current}
    fi
    normalized=$(normalize_worker_aggregation_config "${raw}") \
        || die "Worker 聚合配置无效；请参考 worker-src/config.example.json 并移除 vpsSubUrl"
    apply_worker_allowed_tokens_override "${normalized}"
    WORKER_AGGREGATION_CONFIG=$(jq -c 'del(.allowedTokens)' <<<"${normalized}")
}

choose_cloudflare_worker_name() {
    local name=${CLOUDFLARE_WORKER_NAME:-${DEFAULT_CLOUDFLARE_WORKER_NAME}}
    if [[ -t 0 ]]; then
        name=$(prompt_value "Cloudflare Worker 名称" "${name}")
    fi
    validate_cloudflare_worker_name "${name}" \
        || die "Worker 名称只能包含小写字母、数字和短横线，长度 1-63，且不能以短横线开头或结尾"
    CLOUDFLARE_WORKER_NAME=${name}
}

cloudflare_validate_worker_access() {
    local scripts count
    subscription_enabled || return 0
    [[ "${CLOUDFLARE_ACCOUNT_ID:-}" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "Cloudflare Zone 未返回有效 Account ID"
    scripts=$(cloudflare_api_request GET \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts") \
        || die "当前 Cloudflare Token 缺少 Account / Workers Scripts / Write 权限"
    count=$(jq --arg name "${CLOUDFLARE_WORKER_NAME}" \
        '[.[] | select(.id == $name)] | length' <<<"${scripts}")
    ((count <= 1)) || die "Cloudflare 返回多个同名 Worker：${CLOUDFLARE_WORKER_NAME}"
    CLOUDFLARE_WORKER_EXISTS=${count}
    if ((count == 1)); then
        info "复用 Worker ${CLOUDFLARE_WORKER_NAME}，将更新订阅脚本"
    fi
    if [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" && "${count}" != "1" ]]; then
        die "状态中的 Worker ${CLOUDFLARE_WORKER_NAME} 不存在；拒绝创建来源不明的新 Worker"
    fi
}

ensure_cloudflare_worker_builder() {
    local major
    if ! command -v node >/dev/null 2>&1; then
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends nodejs \
            || die "安装 Worker 构建依赖 nodejs 失败"
    fi
    major=$(node -p 'Number(process.versions.node.split(".")[0])' 2>/dev/null || true)
    [[ "${major}" =~ ^[0-9]+$ && "${major}" -ge 18 ]] \
        || die "Worker 构建需要 Node.js 18 或更高版本"
}

cloudflare_build_subscription_worker() {
    local config aggregation build_output
    [[ -s "${CLOUDFLARE_WORKER_SOURCE_FILE}" ]] \
        || die "缺少 Worker 运行源码：${CLOUDFLARE_WORKER_SOURCE_FILE}"
    [[ -s "${CLOUDFLARE_WORKER_BUILD_SCRIPT}" ]] \
        || die "缺少 Worker 构建脚本：${CLOUDFLARE_WORKER_BUILD_SCRIPT}"
    ensure_cloudflare_worker_builder
    prepare_mihomo_template
    aggregation=$(normalize_worker_aggregation_config \
        "${WORKER_AGGREGATION_CONFIG:-}") \
        || die "Worker 聚合配置无效"
    config=$(jq -cn \
        --argjson aggregation "${aggregation}" \
        --arg source_url "https://${VLESS_CDN_DOMAIN}/subscribe" \
        --arg source_secret "${WORKER_SOURCE_SECRET}" \
        --arg download_name "${SUB_DOWNLOAD_NAME}" '{
          allowedTokens:{},
          nodes:$aggregation.nodes,
          externalSubUrl:$aggregation.externalSubUrl,
          vpsSubUrl:$source_url,
          vpsCdnUseRequestToken:true,
          delegateTokenValidation:true,
          requireDynamicCdn:true,
          sourceSecret:$source_secret,
          fallbackCdnNodes:$aggregation.fallbackCdnNodes,
          subscriptionDownloadName:$download_name
        }')
    printf '%s\n' "${config}" >"${RUNTIME_TMP}/worker-config.json"
    chmod 0600 "${RUNTIME_TMP}/worker-config.json"
    install -d -m 0700 "$(dirname "${CLOUDFLARE_WORKER_BUILD_FILE}")"
    build_output=$(
        EASY_ALL_WORKER_CONFIG_PATH="${RUNTIME_TMP}/worker-config.json" \
        EASY_ALL_WORKER_OUTPUT_PATH="${CLOUDFLARE_WORKER_BUILD_FILE}" \
        EASY_ALL_WORKER_TEMPLATE_PATH="${MIHOMO_TEMPLATE_FILE}" \
        EASY_ALL_WORKER_SOURCE_PATH="${CLOUDFLARE_WORKER_SOURCE_FILE}" \
            node "${CLOUDFLARE_WORKER_BUILD_SCRIPT}"
    ) || die "Worker 构建失败"
    [[ -s "${CLOUDFLARE_WORKER_BUILD_FILE}" ]] \
        || die "Worker 构建未生成输出文件"
    chmod 0600 "${CLOUDFLARE_WORKER_BUILD_FILE}"
    CLOUDFLARE_WORKER_BUILD_CURRENT=1
    info "${build_output}"
}

cloudflare_manual_worker_recovery_path() {
    local home=${HOME:-/root} passwd_entry
    if [[ -n "${CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE:-}" ]]; then
        printf '%s\n' "${CLOUDFLARE_WORKER_RECOVERY_FILE_OVERRIDE}"
        return 0
    fi
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]] \
        && command -v getent >/dev/null 2>&1; then
        passwd_entry=$(getent passwd "${SUDO_USER}" || true)
        [[ -z "${passwd_entry}" ]] || home=$(cut -d: -f6 <<<"${passwd_entry}")
    fi
    [[ "${home}" == /* && -d "${home}" ]] || home=/root
    printf '%s/worker.js\n' "${home%/}"
}

cloudflare_build_manual_worker_recovery() {
    local reason=$1 target config_file config aggregation build_output
    quota_enabled && {
        warn "配额模式不能生成绕过 Nginx 配额校验的手工 Worker"
        return 1
    }
    [[ -n "${ALLOWED_TOKENS:-}" ]] || {
        warn "缺少可内嵌的订阅 Token，无法生成手工 Worker"
        return 1
    }
    target=$(cloudflare_manual_worker_recovery_path)
    [[ "${target}" == /* && -d "$(dirname "${target}")" ]] || {
        warn "Worker 手工恢复路径无效：${target}"
        return 1
    }
    aggregation=$(normalize_worker_aggregation_config \
        "${WORKER_AGGREGATION_CONFIG:-}") || return 1
    config=$(jq -cn \
        --argjson aggregation "${aggregation}" \
        --argjson allowed_tokens "${ALLOWED_TOKENS}" \
        --arg source_url "https://${VLESS_CDN_DOMAIN}/subscribe" \
        --arg source_secret "${WORKER_SOURCE_SECRET}" \
        --arg download_name "${SUB_DOWNLOAD_NAME}" '{
          allowedTokens:$allowed_tokens,
          nodes:$aggregation.nodes,
          externalSubUrl:$aggregation.externalSubUrl,
          vpsSubUrl:$source_url,
          vpsCdnUseRequestToken:true,
          delegateTokenValidation:false,
          requireDynamicCdn:true,
          sourceSecret:$source_secret,
          fallbackCdnNodes:$aggregation.fallbackCdnNodes,
          subscriptionDownloadName:$download_name
        }') || return 1
    config_file="${RUNTIME_TMP}/worker-recovery-config.json"
    printf '%s\n' "${config}" >"${config_file}"
    chmod 0600 "${config_file}"
    build_output=$(
        EASY_ALL_WORKER_CONFIG_PATH="${config_file}" \
        EASY_ALL_WORKER_OUTPUT_PATH="${target}" \
        EASY_ALL_WORKER_TEMPLATE_PATH="${MIHOMO_TEMPLATE_FILE}" \
        EASY_ALL_WORKER_SOURCE_PATH="${CLOUDFLARE_WORKER_SOURCE_FILE}" \
            node "${CLOUDFLARE_WORKER_BUILD_SCRIPT}"
    ) || {
        warn "生成手工部署 Worker 失败"
        return 1
    }
    chmod 0600 "${target}"
    if [[ -n "${SUDO_UID:-}" && -n "${SUDO_GID:-}" \
        && "${target}" == "$(dirname "${target}")/worker.js" ]]; then
        chown "${SUDO_UID}:${SUDO_GID}" "${target}" 2>/dev/null || true
    fi
    CLOUDFLARE_WORKER_MANUAL_DEPLOY_REQUIRED=1
    CLOUDFLARE_WORKER_RECOVERY_FILE=${target}
    warn "Cloudflare Worker 自动验收未通过：${reason:0:500}"
    warn "已生成手工部署文件 ${target}（${build_output}）；本次配置将保留，不执行验收失败回滚"
}

cloudflare_upload_subscription_worker() {
    local script metadata headers response path
    script="${CLOUDFLARE_WORKER_BUILD_FILE}"
    metadata="${RUNTIME_TMP}/easy-all-subscription-worker-metadata.json"
    headers="${RUNTIME_TMP}/cloudflare-worker-api-headers"
    [[ "${CLOUDFLARE_WORKER_BUILD_CURRENT:-0}" == "1" ]] \
        || cloudflare_build_subscription_worker
    jq -n \
        --arg date "${CLOUDFLARE_WORKER_COMPATIBILITY_DATE}" '{
          main_module:"worker.js",
          compatibility_date:$date,
          compatibility_flags:["global_fetch_strictly_public"]
        }' >"${metadata}"
    printf 'Authorization: Bearer %s\n' "${CLOUDFLARE_API_TOKEN}" >"${headers}"
    chmod 0600 "${headers}" "${metadata}"
    path="/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${CLOUDFLARE_WORKER_NAME}")"
    response=$(curl -sS --retry 2 --connect-timeout 10 --max-time 60 \
        -X PUT -H "@${headers}" \
        -F "metadata=@${metadata};type=application/json" \
        -F "worker.js=@${script};type=application/javascript+module" \
        "${CLOUDFLARE_API_BASE}${path}") \
        || die "Cloudflare API 请求失败：PUT ${path}"
    jq -e '.success == true' <<<"${response}" >/dev/null \
        || {
            printf '%s\n' "${response:-<empty>}" >&2
            die "Cloudflare Worker 上传失败：PUT ${path}；请根据上方 Cloudflare API 错误码和消息排查"
        }
    if [[ "${CLOUDFLARE_WORKER_EXISTS:-1}" == "0" ]]; then
        CLOUDFLARE_WORKER_CREATED=1
    fi
}

cloudflare_attach_subscription_worker_domain() {
    local domains matches count existing_service result records type
    domains=$(cloudflare_api_request GET \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains")
    matches=$(jq -c --arg host "${SUBSCRIPTION_DOMAIN}" \
        '[.[] | select((.hostname | ascii_downcase) == $host)]' <<<"${domains}")
    count=$(jq 'length' <<<"${matches}")
    ((count <= 1)) || die "Cloudflare 中存在多个订阅 Worker 自定义域名：${SUBSCRIPTION_DOMAIN}"
    if ((count == 1)); then
        existing_service=$(jq -r '.[0].service // empty' <<<"${matches}")
        [[ "${existing_service}" == "${CLOUDFLARE_WORKER_NAME}" ]] \
            || die "订阅域名 ${SUBSCRIPTION_DOMAIN} 已绑定到其他 Worker：${existing_service}"
        CLOUDFLARE_WORKER_DOMAIN_ID=$(jq -r '.[0].id // empty' <<<"${matches}")
        [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID}" ]] \
            || die "Cloudflare Worker 自定义域名缺少 ID"
        return 0
    fi
    for type in A AAAA CNAME; do
        records=$(cloudflare_record_list "${CLOUDFLARE_ZONE_ID}" \
            "${type}" "${SUBSCRIPTION_DOMAIN}")
        [[ "$(jq 'length' <<<"${records}")" == "0" ]] \
            || die "订阅域名 ${SUBSCRIPTION_DOMAIN} 已有 ${type} 记录；拒绝由 Worker Custom Domain 接管"
    done
    result=$(cloudflare_api_request PUT \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains" \
        "$(jq -cn --arg host "${SUBSCRIPTION_DOMAIN}" \
            --arg service "${CLOUDFLARE_WORKER_NAME}" \
            --arg zone_id "${CLOUDFLARE_ZONE_ID}" \
            --arg zone_name "${CLOUDFLARE_ZONE_NAME}" \
            '{hostname:$host,service:$service,zone_id:$zone_id,zone_name:$zone_name}')")
    CLOUDFLARE_WORKER_DOMAIN_ID=$(jq -r '.id // empty' <<<"${result}")
    [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID}" ]] \
        || die "Cloudflare 未返回 Worker 自定义域名 ID"
    CLOUDFLARE_CREATED_WORKER_DOMAIN_ID=${CLOUDFLARE_WORKER_DOMAIN_ID}
}

cloudflare_deploy_subscription_worker() {
    subscription_enabled || return 0
    cloudflare_validate_worker_access
    cloudflare_upload_subscription_worker
    cloudflare_api_request POST \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${CLOUDFLARE_WORKER_NAME}")/subdomain" \
        "$(jq -cn '{enabled:false,previews_enabled:false}')" >/dev/null
    cloudflare_attach_subscription_worker_domain
}

cloudflare_delete_subscription_worker_resources() {
    local domain_id=${1:-${CLOUDFLARE_WORKER_DOMAIN_ID:-}}
    local worker_name=${2:-${CLOUDFLARE_WORKER_NAME:-}}
    local domains scripts extra_domains
    if [[ -n "${worker_name}" ]]; then
        domains=$(cloudflare_api_request GET \
            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains") || return 1
        extra_domains=$(jq --arg name "${worker_name}" --arg id "${domain_id}" \
            '[.[] | select(.service == $name and .id != $id)] | length' <<<"${domains}")
        ((extra_domains == 0)) \
            || die "Worker ${worker_name} 还绑定了非本安装管理的 Custom Domain，拒绝删除"
    fi
    if [[ -n "${domain_id}" ]]; then
        if jq -e --arg id "${domain_id}" \
            'any(.[]; .id == $id)' <<<"${domains}" >/dev/null; then
            jq -e --arg id "${domain_id}" --arg name "${worker_name}" \
                'any(.[]; .id == $id and .service == $name)' <<<"${domains}" >/dev/null \
                || die "Worker Custom Domain 所有权与状态不一致，拒绝删除"
            cloudflare_api_request DELETE \
                "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/${domain_id}" >/dev/null \
                || return 1
        fi
    fi
    if [[ -n "${worker_name}" ]]; then
        scripts=$(cloudflare_api_request GET \
            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts") || return 1
        if jq -e --arg name "${worker_name}" \
            'any(.[]; .id == $name)' <<<"${scripts}" >/dev/null; then
            cloudflare_api_request DELETE \
                "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/scripts/$(uri_encode "${worker_name}")" >/dev/null \
                || return 1
        fi
    fi
}

cloudflare_validate_subscription_worker() {
    local token="" body headers status attempt decoded ready=0 curl_status=0 warning="" ip
    local invalid_ready=0 invalid_curl_status=0 public_ip=""
    local worker_curl_args=(--noproxy '*')
    subscription_enabled || return 0
    if quota_enabled; then
        token=$(quota_active_accounts_json | jq -r 'first(.[].token) // empty')
        if [[ -z "${token}" ]]; then
            info "所有配额用户均已停用，仅验收 Worker Token 拒绝行为"
        fi
    else
        token=$(jq -r 'first(.[]) // empty' <<<"${ALLOWED_TOKENS}")
    fi
    body="${RUNTIME_TMP}/worker-subscription-body"
    headers="${RUNTIME_TMP}/worker-subscription-headers"
    for ((attempt = 1; attempt <= CLOUDFLARE_WORKER_READY_ATTEMPTS; attempt += 1)); do
        : >"${headers}"
        : >"${body}"
        curl_status=0
        status=$(curl -sS "${worker_curl_args[@]}" --connect-timeout 5 --max-time 30 \
            -D "${headers}" -o "${body}" -w '%{http_code}' \
            --get --data-urlencode "token=${token:-invalid}" \
            --data-urlencode "flag=base64" \
            "https://${SUBSCRIPTION_DOMAIN}/subscribe" 2>/dev/null) || curl_status=$?
        if [[ "${curl_status}" == "0" && -n "${token}" && "${status}" == "200" ]] \
            && ! grep -qi '^X-Easy-All-CDN-Warning:' "${headers}"; then
            decoded=$(openssl base64 -d -A <"${body}" 2>/dev/null || true)
            if grep -q '^vless://' <<<"${decoded}"; then
                ready=1
                break
            fi
        elif [[ "${curl_status}" == "0" && -z "${token}" && "${status}" == "403" ]]; then
            ready=1
            break
        fi
        if ((curl_status == 6)); then
            while IFS= read -r ip; do
                validate_public_ipv4 "${ip}" || continue
                worker_curl_args=(--noproxy '*' --resolve "${SUBSCRIPTION_DOMAIN}:443:${ip}")
                public_ip=${ip}
                info "订阅域名 ${SUBSCRIPTION_DOMAIN} 的本机 DNS 尚未更新，使用 1.1.1.1 的公共解析结果验收"
                break
            done < <(dig +time=3 +tries=1 +short A "${SUBSCRIPTION_DOMAIN}" @1.1.1.1 2>/dev/null)
        fi
        ((attempt == CLOUDFLARE_WORKER_READY_ATTEMPTS)) || sleep "${CLOUDFLARE_WORKER_READY_INTERVAL}"
    done
    if ((ready != 1)); then
        warning=$(awk 'tolower($0) ~ /^x-easy-all-cdn-warning:/ {sub(/^[^:]*:[[:space:]]*/, ""); sub(/\r$/, ""); print; exit}' "${headers}")
        if [[ -n "${token}" ]]; then
            warning=${warning//"${token}"/[redacted]}
            warning=${warning//"$(uri_encode "${token}")"/[redacted]}
        fi
        if [[ "${curl_status}" == "0" && -n "${warning}" \
            && ( "${INSTALL_ROLLBACK_ON_EXIT:-0}" == "1" \
                || "${UPDATE_SUB_ROLLBACK_ON_EXIT:-0}" == "1" ) ]] \
            && cloudflare_build_manual_worker_recovery \
                "curl=${curl_status},HTTP=${status:-000}${warning:+，回源诊断：${warning:0:500}}"; then
            return 0
        fi
        if ((curl_status == 6)); then
            die "订阅域名 ${SUBSCRIPTION_DOMAIN} DNS 解析失败（curl=6）；已等待公共 DNS 发布，请检查 Worker Custom Domain 的 DNS 状态"
        fi
        die "Cloudflare Worker 订阅验收失败：curl=${curl_status},HTTP=${status:-000}${warning:+，回源诊断：${warning:0:500}}；请检查自定义域名证书及 Worker 到 ${VLESS_CDN_DOMAIN} 的公共 fetch"
    fi

    for ((attempt = 1; attempt <= CLOUDFLARE_WORKER_AUTH_ATTEMPTS; attempt += 1)); do
        invalid_curl_status=0
        status=$(curl -sS "${worker_curl_args[@]}" --connect-timeout 5 --max-time 20 \
            -o /dev/null -w '%{http_code}' --get \
            --data-urlencode "token=invalid" \
            "https://${SUBSCRIPTION_DOMAIN}/subscribe" 2>/dev/null) \
            || invalid_curl_status=$?
        if [[ "${invalid_curl_status}" == "0" && "${status}" == "403" ]]; then
            invalid_ready=1
            break
        fi
        if ((invalid_curl_status != 0)) && [[ -z "${public_ip}" ]]; then
            while IFS= read -r ip; do
                validate_public_ipv4 "${ip}" || continue
                public_ip=${ip}
                worker_curl_args=(--noproxy '*' --resolve "${SUBSCRIPTION_DOMAIN}:443:${ip}")
                info "无效 Token 验收连接失败，使用 1.1.1.1 的公共解析结果重试"
                break
            done < <(dig +time=3 +tries=1 +short A "${SUBSCRIPTION_DOMAIN}" @1.1.1.1 2>/dev/null)
        fi
        ((attempt == CLOUDFLARE_WORKER_AUTH_ATTEMPTS)) \
            || sleep "${CLOUDFLARE_WORKER_READY_INTERVAL}"
    done
    if ((invalid_ready != 1)); then
        if ((invalid_curl_status != 0)); then
            die "Cloudflare Worker 无效 Token 验收请求失败：curl=${invalid_curl_status},HTTP=${status:-000}；请检查自定义域名 DNS、证书及边缘传播状态"
        fi
        die "Cloudflare Worker 未拒绝无效订阅 Token（HTTP ${status:-000}）"
    fi

    if [[ -n "${token}" ]]; then
        status=$(curl -sS --connect-timeout 5 --max-time 20 \
            -o /dev/null -w '%{http_code}' --get \
            --data-urlencode "token=${token}" \
            "https://${VLESS_CDN_DOMAIN}/subscribe" 2>/dev/null || true)
        [[ "${status}" == "404" ]] \
            || die "Nginx 节点源可被绕过 Worker 直接访问（HTTP ${status:-000}）"
    fi
    success "Cloudflare Worker 聚合订阅与私有 Nginx 节点源验收通过"
}

cloudflare_fetch_origin_ipv4_ranges() {
    local response
    response=$(curl -fsS --retry 3 --connect-timeout 10 --max-time 30 \
        "${CLOUDFLARE_API_BASE}/ips") \
        || return 1
    jq -er '
        select(.success == true)
        | .result.ipv4_cidrs
        | select(type == "array" and length > 0)
        | unique[]
        | select(test("^([0-9]{1,3}\\.){3}[0-9]{1,3}/([89]|[12][0-9]|3[0-2])$"))
    ' <<<"${response}" | sort -u
}

cloudflare_origin_ufw_rule_numbers() {
    command -v ufw >/dev/null 2>&1 || return 0
    LC_ALL=C ufw status numbered 2>/dev/null \
        | sed -n "/${CLOUDFLARE_UFW_COMMENT}/s/^[[:space:]]*\\[[[:space:]]*\\([0-9][0-9]*\\)\\].*/\\1/p" \
        | sort -rn
}

cloudflare_remove_origin_firewall_rules() {
    local number
    while IFS= read -r number; do
        [[ -n "${number}" ]] || continue
        ufw --force delete "${number}" >/dev/null 2>&1 \
            || warn "删除 Cloudflare 回源 UFW 规则 ${number} 失败"
    done < <(cloudflare_origin_ufw_rule_numbers)
}

cloudflare_configure_origin_firewall() {
    local next current cidr
    next="${RUNTIME_TMP}/cloudflare-origin-ipv4.txt"
    if ! cloudflare_fetch_origin_ipv4_ranges >"${next}" || [[ ! -s "${next}" ]]; then
        if [[ -s "${CLOUDFLARE_ORIGIN_IPS_FILE}" ]]; then
            warn "获取 Cloudflare 官方 IP 段失败，继续使用上一版回源白名单"
            install -m 0600 "${CLOUDFLARE_ORIGIN_IPS_FILE}" "${next}"
        else
            die "无法获取 Cloudflare 官方 IPv4 段，且本机没有可回退的白名单"
        fi
    fi
    current="${RUNTIME_TMP}/cloudflare-origin-ipv4.current"
    if [[ -s "${CLOUDFLARE_ORIGIN_IPS_FILE}" ]]; then
        install -m 0600 "${CLOUDFLARE_ORIGIN_IPS_FILE}" "${current}"
    else
        : >"${current}"
    fi

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        ufw allow proto tcp from "${cidr}" to any port 443 \
            comment "${CLOUDFLARE_UFW_COMMENT}" >/dev/null \
            || die "添加 Cloudflare 回源 UFW 规则失败：${cidr}"
    done <"${next}"
    ufw --force enable >/dev/null || die "启用 UFW 失败"
    ufw reload >/dev/null || die "重载 UFW 失败"

    while IFS= read -r cidr; do
        [[ -n "${cidr}" ]] || continue
        grep -Fxq "${cidr}" "${next}" && continue
        ufw --force delete allow proto tcp from "${cidr}" to any port 443 >/dev/null \
            || warn "删除过期 Cloudflare 回源 UFW 规则失败：${cidr}"
    done <"${current}"
    install -d -m 0700 "$(dirname "${CLOUDFLARE_ORIGIN_IPS_FILE}")"
    install -m 0600 "${next}" "${CLOUDFLARE_ORIGIN_IPS_FILE}"
    ufw reload >/dev/null || die "重载 UFW 失败"
}

xhttp_configure_ufw() {
    local desired_ports
    snapshot_ufw_state
    if ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -o DPkg::Lock::Timeout=300 update
        apt-get -o DPkg::Lock::Timeout=300 install -y --no-install-recommends ufw
    fi
    ensure_ssh_boot_service
    detect_ssh_ports
    configure_ufw_ip_family
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    ufw default deny routed >/dev/null
    desired_ports=${SSH_PORTS}
    apply_managed_ufw_tcp_ports "${desired_ports} 443"
    cloudflare_configure_origin_firewall
    apply_managed_ufw_tcp_ports "${desired_ports}"
    systemctl enable ufw >/dev/null 2>&1 || die "设置 UFW 开机启动失败"
    LC_ALL=C ufw status | grep -q '^Status: active' || die "UFW 未处于 active 状态"
    ensure_ssh_fail2ban
}

cloudflare_lookup_parent_zone() {
    local domain=$1 candidate zone
    candidate=${domain}
    while [[ "${candidate}" == *.* ]]; do
        zone=$(cloudflare_api_request GET "/zones?name=${candidate}&status=active&per_page=50" | jq -r --arg name "${candidate}" '[.[] | select((.name|ascii_downcase)==$name) | .id] | if length == 1 then .[0] else empty end')
        if [[ -n "${zone}" ]]; then printf '%s' "${zone}"; return; fi
        candidate=${candidate#*.}
    done
    return 1
}

cloudflare_find_parent_zone() {
    local domain=$1
    cloudflare_lookup_parent_zone "${domain}" \
        || die "Cloudflare active Zone 未覆盖域名：${domain}"
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

cloudflare_record_list() { cloudflare_api_request GET "/zones/$1/dns_records?type=$2&name=$3&per_page=100"; }
cloudflare_require_single_record() {
    local records=$1 count
    count=$(jq 'length' <<<"${records}")
    ((count <= 1)) || die "Cloudflare 中发现多个同名同类型 DNS 记录，拒绝猜测或覆盖"
}

cloudflare_ensure_proxied_a() {
    local zone=$1 host=$2 ip=$3 records record id content proxied comment type payload result
    for type in A AAAA CNAME; do
        records=$(cloudflare_record_list "${zone}" "${type}" "${host}")
        cloudflare_require_single_record "${records}"
        [[ "${type}" == A ]] || [[ $(jq 'length' <<<"${records}") == 0 ]] || die "${host} 已有 ${type} 记录；拒绝覆盖"
        if [[ "${type}" == A && $(jq 'length' <<<"${records}") == 1 ]]; then
            record=$(jq -c '.[0]' <<<"${records}"); id=$(jq -r '.id' <<<"${record}")
            content=$(jq -r '.content' <<<"${record}"); proxied=$(jq -r '.proxied' <<<"${record}")
            comment=$(jq -r '.comment // empty' <<<"${record}")
            if [[ "${content}" == "${ip}" && "${proxied}" == true ]]; then
                return 0
            fi
            [[ "${comment}" == "easy_all xhttp origin" ]] \
                || die "${host} 的 A 记录与 easy_all 目标不一致或未代理；拒绝覆盖"
            payload=$(jq -cn --arg name "${host}" --arg content "${ip}" \
                '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"easy_all xhttp origin"}')
            cloudflare_api_request PATCH "/zones/${zone}/dns_records/${id}" \
                "${payload}" >/dev/null
            return 0
        fi
    done
    result=$(cloudflare_api_request POST "/zones/${zone}/dns_records" \
        "$(jq -cn --arg name "${host}" --arg content "${ip}" '{type:"A",name:$name,content:$content,ttl:1,proxied:true,comment:"easy_all xhttp origin"}')")
    CLOUDFLARE_CREATED_DNS_RECORD_ID=$(jq -r '.id // empty' <<<"${result}")
    [[ -n "${CLOUDFLARE_CREATED_DNS_RECORD_ID}" ]] \
        || die "Cloudflare 未返回新建 DNS 记录 ID"
}

cloudflare_validate_zones() {
    local zone
    CLOUDFLARE_ZONE_ID=$(cloudflare_find_parent_zone "${VLESS_CDN_DOMAIN}")
    CLOUDFLARE_CDN_ZONE_ID=${CLOUDFLARE_ZONE_ID}
    CLOUDFLARE_SUBSCRIPTION_ZONE_ID=$(cloudflare_find_parent_zone "$(active_subscription_link_domain)")
    [[ "${CLOUDFLARE_ZONE_ID}" == "${CLOUDFLARE_SUBSCRIPTION_ZONE_ID}" ]] || die "订阅域名必须在同一个 Cloudflare Zone"
    zone=$(cloudflare_api_request GET "/zones/${CLOUDFLARE_ZONE_ID}")
    CLOUDFLARE_ZONE_NAME=$(jq -r '.name // empty | ascii_downcase' <<<"${zone}")
    CLOUDFLARE_ACCOUNT_ID=$(jq -r '.account.id // empty' <<<"${zone}")
    [[ -n "${CLOUDFLARE_ZONE_NAME}" ]] || die "Cloudflare Zone 未返回有效名称"
    [[ "${CLOUDFLARE_ACCOUNT_ID}" =~ ^[0-9A-Fa-f]{32}$ ]] \
        || die "Cloudflare Zone 未返回有效 Account ID"
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
    cloudflare_validate_worker_access
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

cloudflare_origin_certificate_hosts() {
    jq -cn --arg cdn "${VLESS_CDN_DOMAIN}" '[$cdn]'
}

cloudflare_issue_origin_certificate() {
    local force=${1:-0} key csr result cert expires hosts san old_id
    cloudflare_ensure_origin_ca_root
    if [[ "${force}" != "1" ]] && cloudflare_origin_certificate_is_current; then
        return 0
    fi
    cloudflare_collect_api_token
    old_id=${CLOUDFLARE_ORIGIN_CERT_ID:-}
    install -d -m 0700 "${CERT_DIR}"
    key="${RUNTIME_TMP}/cloudflare-origin-ecc.key"
    csr="${RUNTIME_TMP}/cloudflare-origin.csr"
    openssl ecparam -name prime256v1 -genkey -noout -out "${key}"
    chmod 0600 "${key}"
    hosts=$(cloudflare_origin_certificate_hosts)
    san=$(jq -r 'map("DNS:" + .) | join(",")' <<<"${hosts}")
    openssl req -new -sha256 -key "${key}" -subj "/CN=${CLOUDFLARE_ORIGIN_DOMAIN}" \
        -addext "subjectAltName=${san}" -out "${csr}"
    result=$(cloudflare_api_request POST '/certificates' "$(jq -cn --arg csr "$(<"${csr}")" --argjson hosts "${hosts}" --argjson validity "${CLOUDFLARE_ORIGIN_VALIDITY_DAYS}" '{hostnames:$hosts,requested_validity:$validity,request_type:"origin-ecc",csr:$csr}')")
    cert=$(jq -r '.certificate // empty' <<<"${result}"); CLOUDFLARE_ORIGIN_CERT_ID=$(jq -r '.id // empty' <<<"${result}"); expires=$(jq -r '.expires_on // empty' <<<"${result}")
    [[ -n "${cert}" && -n "${CLOUDFLARE_ORIGIN_CERT_ID}" && -n "${expires}" ]] || die "Cloudflare 未返回 Origin CA 证书、ID 或到期时间"
    CLOUDFLARE_CREATED_ORIGIN_CERT_ID=${CLOUDFLARE_ORIGIN_CERT_ID}
    printf '%s\n' "${cert}" >"${RUNTIME_TMP}/origin.pem"
    openssl verify -CAfile "${CLOUDFLARE_ORIGIN_CA_ROOT_FILE}" \
        "${RUNTIME_TMP}/origin.pem" >/dev/null \
        || die "Cloudflare Origin CA 证书链验证失败"
    install -m 0600 "${RUNTIME_TMP}/origin.pem" "${CERT_FILE}"
    install -m 0600 "${key}" "${KEY_FILE}"
    CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=${expires}
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=${old_id}
}

xhttp_validate_local_tls_curl_args() {
    local headers="${RUNTIME_TMP}/cloudflare-origin-headers"
    cloudflare_ensure_origin_ca_root
    printf 'X-Easy-All-Origin-Key: %s\n' "${ORIGIN_HEADER_SECRET}" >"${headers}"
    if subscription_enabled; then
        printf '%s: %s\n' "${CLOUDFLARE_WORKER_SOURCE_HEADER}" \
            "${WORKER_SOURCE_SECRET}" >>"${headers}"
    fi
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
    if [[ -n "${old_id}" && "${old_id}" != "${CLOUDFLARE_ORIGIN_CERT_ID}" ]]; then
        if ! (cloudflare_api_request DELETE "/certificates/${old_id}" >/dev/null); then
            warn "新证书已生效，但撤销旧 Cloudflare Origin CA 证书失败：${old_id}"
        fi
    fi
    cloudflare_clear_api_token
    success "Cloudflare Origin CA 源站证书已轮换"
}

cloudflare_finalize_certificate_rotation() {
    local old_id=${CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID:-}
    [[ -n "${old_id}" && "${old_id}" != "${CLOUDFLARE_ORIGIN_CERT_ID:-}" ]] \
        || return 0
    if ! (cloudflare_api_request DELETE "/certificates/${old_id}" >/dev/null); then
        warn "新证书已通过公网验收，但撤销旧 Cloudflare Origin CA 证书失败：${old_id}"
        return 0
    fi
    CLOUDFLARE_PREVIOUS_ORIGIN_CERT_ID=""
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

cloudflare_cleanup_previous_subscription_host() {
    local old_host=$1 old_domain_id=${2:-} current_host domains
    [[ -n "${old_host}" && "${old_host}" != "${VLESS_CDN_DOMAIN}" ]] || return 0
    current_host=$(active_subscription_link_domain)
    [[ "${old_host}" != "${current_host}" ]] || return 0
    [[ -n "${old_domain_id}" ]] || {
        warn "旧订阅域名 ${old_host} 缺少 Worker Domain ID，未自动删除"
        return 0
    }
    domains=$(cloudflare_api_request GET \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains") || {
        warn "读取旧 Worker 订阅域名失败，保留 ${old_host}"
        return 0
    }
    jq -e --arg id "${old_domain_id}" --arg host "${old_host}" \
        --arg service "${CLOUDFLARE_WORKER_NAME}" \
        'any(.[]; .id == $id and (.hostname | ascii_downcase) == $host and .service == $service)' \
        <<<"${domains}" >/dev/null || {
        warn "旧 Worker 订阅域名 ${old_host} 的所有权与状态不一致，予以保留"
        return 0
    }
    cloudflare_api_request DELETE \
        "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/${old_domain_id}" >/dev/null \
        || warn "删除旧 Worker 订阅域名失败：${old_host}"
}

cloudflare_configure_cdn() {
    cloudflare_configure_rules
    cloudflare_api_request PATCH "/zones/${CLOUDFLARE_ZONE_ID}/settings/origin_max_http_version" \
        "$(jq -cn '{value:"2"}')" >/dev/null
    warn "Cloudflare gRPC 只能在控制台 Network → gRPC 中手动开启，Zone Settings API 不支持该开关"
}

cloudflare_validate_cdn_health() {
    local probe_uuid=""
    cloudflare_wait_for_health "${VLESS_CDN_DOMAIN}" "CDN"
    if quota_enabled; then
        probe_uuid=$(quota_active_accounts_json | jq -er 'first(to_entries[]).value.uuid') \
            || {
                info "所有配额用户均已停用，跳过 XHTTP 业务探针，仅验收 CDN 公网健康接口"
                probe_uuid=""
            }
    else
        probe_uuid=${VLESS_UUID}
    fi
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

read_state_field() {
    local file=$1 key=$2 line value
    [[ -f "${file}" ]] || return 1
    line=$(grep -E "^${key}=" "${file}" | tail -n 1) || return 1
    value=${line#*=}
    value=${value#\'}
    value=${value%\'}
    value=${value#\"}
    value=${value%\"}
    printf '%s\n' "${value}"
}

normalize_xhttp_path() {
    local path=${1:-}
    while [[ "${path}" =~ ^/(xhttp|vless)-/(xhttp|vless)- ]]; do
        path="/${path#/*-/}"
    done
    if [[ "${path}" =~ ^/(xhttp|vless)- ]]; then
        path="/xhttp-${path#/*-}"
    elif [[ -n "${path}" ]]; then
        path="/xhttp-${path#/}"
    else
        path="/xhttp-$(openssl rand -hex 12)"
    fi
    path="${path%/}"
    printf '%s\n' "${path}"
}

xhttp_client_path() {
    printf '%s/' "${XHTTP_PATH%/}"
}

collect_cloudflare_worker_inputs() {
    local domain default_domain
    default_domain="sub.${VLESS_CDN_DOMAIN#*.}"
    domain=${SUBSCRIPTION_DOMAIN:-${default_domain}}
    [[ "${domain}" != "${VLESS_CDN_DOMAIN}" ]] || domain=${default_domain}
    if [[ -t 0 ]]; then
        info "订阅域名将绑定到 Cloudflare Worker，必须与节点域名不同。"
        domain=$(prompt_value "Worker 订阅完整域名" "${domain}")
    fi
    domain=$(normalize_domain "${domain}")
    validate_domain "${domain}" || die "SUBSCRIPTION_DOMAIN 无效：${domain}"
    [[ "${domain}" != "${VLESS_CDN_DOMAIN}" ]] \
        || die "Worker 订阅域名必须与节点域名不同，避免 Worker 子请求递归"
    SUBSCRIPTION_DOMAIN=${domain}
    if [[ -z "${CLOUDFLARE_WORKER_NAME:-}" ]]; then
        choose_cloudflare_worker_name
    else
        validate_cloudflare_worker_name "${CLOUDFLARE_WORKER_NAME}" \
            || die "Cloudflare Worker 名称无效"
    fi
    WORKER_SOURCE_SECRET=${WORKER_SOURCE_SECRET:-$(generate_secret)}
    [[ "${WORKER_SOURCE_SECRET}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
        || die "WORKER_SOURCE_SECRET 格式无效"
}

collect_install_inputs() {
    PROTOCOL="cloudflare-streamup"
    BACKEND="xray"
    CDN_PROVIDER="cloudflare"

    XHTTP_NODE_NAME=${XHTTP_NODE_NAME:-${DEFAULT_XHTTP_NODE_NAME}}
    VLESS_UUID=${VLESS_UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || generate_secret)}
    validate_uuid "${VLESS_UUID}" || die "VLESS_UUID 无效"

    choose_google_egress_mode

    info "Cloudflare 数据面采用单域名架构；部署订阅时另用独立域名绑定 Worker。"
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
    if subscription_enabled; then
        collect_cloudflare_worker_inputs
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens 1
        choose_worker_aggregation_config
        cloudflare_build_subscription_worker
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        WORKER_AGGREGATION_CONFIG='{"nodes":[],"externalSubUrl":"","fallbackCdnNodes":[]}'
        choose_monthly_quota 0
    fi
}

load_state() {
    local variable env_name state_path="${EASY_ALL_STATE_FILE_OVERRIDE:-${STATE_FILE}}"
    local -a variables=(
        STATE_VERSION PROTOCOL BACKEND CDN_PROVIDER
        GOOGLE_EGRESS_MODE GOOGLE_EGRESS_RESOLVED
        CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_WORKER_NAME CLOUDFLARE_WORKER_DOMAIN_ID
        WORKER_SOURCE_SECRET WORKER_AGGREGATION_CONFIG
        XHTTP_NODE_NAME VLESS_UUID
        VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN
        CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME
        CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID
        CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON
        CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID
        VPS_IP_FAMILY VPS_PUBLIC_IPV6
        XRAY_XHTTP_LOOPBACK_PORT XHTTP_PATH
        ORIGIN_HEADER_SECRET ALLOWED_TOKENS SUB_DOWNLOAD_NAME
        SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR
        QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE
    )
    [[ -f "${state_path}" ]] || return 1
    for variable in "${variables[@]}"; do
        env_name=$(env -i bash -c 'source "$1" && printf "%s" "${'"${variable}"':-}"' _ "${state_path}")
        printf -v "${variable}" '%s' "${env_name}"
    done
    enforce_ipv4_only_policy
    [[ "${PROTOCOL}" == "cloudflare-streamup" && "${CDN_PROVIDER:-}" == "cloudflare" && "${BACKEND:-}" == "xray" ]] \
        || die "状态不是 Cloudflare XHTTP Stream-up"
    [[ "${STATE_VERSION:-}" == "${STATE_SCHEMA_VERSION}" ]] \
        || die "不支持的 Cloudflare 状态版本：${STATE_VERSION:-缺失}；请重新安装"
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
    SUBSCRIPTION_DOMAIN=$(normalize_domain "${SUBSCRIPTION_DOMAIN:-${VLESS_CDN_DOMAIN}}")
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${SUBSCRIPTION_MODE:-none}") || die "订阅模式无效"
    SUB_DOWNLOAD_NAME=$(normalize_sub_download_name "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}") || die "订阅文件名无效"
    [[ -z "${ALLOWED_TOKENS:-}" ]] || ALLOWED_TOKENS=$(normalize_allowed_tokens "${ALLOWED_TOKENS}") || die "Token 无效"
    if subscription_enabled; then
        [[ "${SUBSCRIPTION_DOMAIN}" != "${VLESS_CDN_DOMAIN}" ]] \
            || die "Worker 订阅域名不能与节点域名相同；请重新安装"
        [[ "${CLOUDFLARE_ACCOUNT_ID:-}" =~ ^[0-9A-Fa-f]{32}$ ]] \
            || die "状态缺少有效的 Cloudflare Account ID；请重新安装"
        validate_cloudflare_worker_name "${CLOUDFLARE_WORKER_NAME:-}" \
            || die "状态缺少有效的 Cloudflare Worker 名称；请重新安装"
        [[ -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" ]] \
            || die "状态缺少 Worker 自定义域名 ID；请重新安装"
        [[ "${WORKER_SOURCE_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            || die "状态缺少有效的 Worker 订阅源密钥；请重新安装"
        WORKER_AGGREGATION_CONFIG=$(normalize_worker_aggregation_config \
            "${WORKER_AGGREGATION_CONFIG:-}" | jq -c 'del(.allowedTokens)') \
            || die "状态中的 Worker 聚合配置无效；请重新安装"
    fi
    QUOTA_ENABLED=${QUOTA_ENABLED:-0}
    [[ "${QUOTA_ENABLED}" == "0" || "${QUOTA_ENABLED}" == "1" ]] \
        || die "状态文件中的 QUOTA_ENABLED 无效"
    if quota_enabled; then
        validate_user_accounts "${USER_ACCOUNTS:-}" || die "状态文件中的 USER_ACCOUNTS 无效"
        validate_quota_start_date "${QUOTA_START_DATE:-}" || die "状态文件中的 QUOTA_START_DATE 无效"
    else
        USER_ACCOUNTS=""
        QUOTA_START_DATE=""
    fi
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
    validate_google_egress_policy_state \
        || die "无法保存无效的 Google 出站策略"
    if subscription_enabled; then
        [[ "${CLOUDFLARE_ACCOUNT_ID:-}" =~ ^[0-9A-Fa-f]{32}$ \
            && -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" \
            && "${WORKER_SOURCE_SECRET:-}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            && validate_cloudflare_worker_name "${CLOUDFLARE_WORKER_NAME:-}" \
            || die "无法保存不完整的 Cloudflare Worker 状态"
        WORKER_AGGREGATION_CONFIG=$(normalize_worker_aggregation_config \
            "${WORKER_AGGREGATION_CONFIG:-}" | jq -c 'del(.allowedTokens)') \
            || die "无法保存无效的 Worker 聚合配置"
    fi
    state_dir="$(dirname "${target}")"
    install -d -m 0700 "${state_dir}"
    local t
    t=$(mktemp "${state_dir}/state.env.XXXXXX")
    cleanup_files+=("${t}")
    {
        for v in STATE_VERSION PROTOCOL BACKEND CDN_PROVIDER \
            GOOGLE_EGRESS_MODE GOOGLE_EGRESS_RESOLVED \
            CLOUDFLARE_ACCOUNT_ID CLOUDFLARE_WORKER_NAME CLOUDFLARE_WORKER_DOMAIN_ID \
            WORKER_SOURCE_SECRET WORKER_AGGREGATION_CONFIG \
            XHTTP_NODE_NAME VLESS_UUID VLESS_CDN_DOMAIN SUBSCRIPTION_DOMAIN \
            CLOUDFLARE_ORIGIN_DOMAIN CLOUDFLARE_ZONE_ID CLOUDFLARE_ZONE_NAME \
            CLOUDFLARE_CDN_ZONE_ID CLOUDFLARE_SUBSCRIPTION_ZONE_ID \
            CLOUDFLARE_ORIGIN_CERT_ID CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON \
            CLOUDFLARE_HEADER_RULESET_ID CLOUDFLARE_STRICT_RULESET_ID \
            VPS_IP_FAMILY VPS_PUBLIC_IPV6 \
            XRAY_XHTTP_LOOPBACK_PORT XHTTP_PATH ORIGIN_HEADER_SECRET ALLOWED_TOKENS \
            SUB_DOWNLOAD_NAME SUBSCRIPTION_MODE SCHEDULED_REBOOT_ENABLED SCHEDULED_REBOOT_HOUR \
            QUOTA_ENABLED USER_ACCOUNTS QUOTA_START_DATE; do
            case "${v}" in
            STATE_VERSION) printf '%s=%q\n' "${v}" "${STATE_SCHEMA_VERSION}" ;;
            PROTOCOL) printf '%s=%q\n' "${v}" "cloudflare-streamup" ;;
            BACKEND) printf '%s=%q\n' "${v}" "xray" ;;
            CDN_PROVIDER) printf '%s=%q\n' "${v}" "cloudflare" ;;
            SUBSCRIPTION_DOMAIN) printf '%s=%q\n' "${v}" "$(subscription_link_domain)" ;;
            *) printf '%s=%q\n' "${v}" "${!v:-}" ;;
            esac
        done
    } >"${t}"
    install -m 0600 "${t}" "${target}"
}

collect_installed_state() {
    [[ -f "${STATE_FILE}" ]] || die "easy_all Cloudflare CDN XHTTP stream-up 尚未安装"
    load_state
}

xhttp_render_xray_config() {
    install -d -m 0755 "${XRAY_DIR}"
    local clients
    if quota_enabled; then
        clients=$(quota_active_clients_json)
    else
        clients=$(jq -cn --arg id "${VLESS_UUID}" --arg email "${XHTTP_NODE_NAME}" '[{id:$id,email:$email}]')
    fi
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
        --argjson routing "${routing}" \
        --argjson quota_enabled "$([[ "${QUOTA_ENABLED:-0}" == "1" ]] && printf true || printf false)" '
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
        }
        + (if $quota_enabled then {
            api:{tag:"api",listen:"127.0.0.1:10085",services:["StatsService"]},
            stats:{},
            policy:{levels:{"0":{statsUserUplink:true,statsUserDownlink:true}}}
          } else {} end)' >"${RUNTIME_TMP}/xray-config.json"
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
        write_subscription_nginx_locations "${ORIGIN_HEADER_SECRET}" \
            "${WORKER_SOURCE_SECRET:-}"
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

build_mihomo_proxy_groups() {
    local -a all_nodes=()
    local ip label carrier candidates
    candidates=$(cloudflare_xhttp_streamup_client_candidates)
    cloudflare_validate_client_candidate_counts "${candidates}"
    while IFS=$'\t' read -r ip label carrier; do
        [[ -n "${ip}" ]] || continue
        all_nodes+=("🇺🇸优选${label}")
    done <<<"${candidates}"

    printf '    - name: "AUTO"\n'
    printf '      type: url-test\n'
    printf '      proxies:\n'
    local node
    for node in "${all_nodes[@]}"; do
        printf '        - %s\n' "$(jq -Rn --arg value "${node}" '$value')"
    done
    cat <<EOF
      url: https://cp.cloudflare.com/generate_204
      interval: 300
      tolerance: 30
      timeout: 3000
      lazy: true
EOF
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
    printf '协议: VLESS XHTTP stream-up（Cloudflare CDN 纯流模式）\n后端: Xray (%s)\n客户端 CDN 节点域名: %s\nCloudflare 回源域名: %s（数据面单域名）\nOrigin CA: %s（到期 %s）\n客户端入口 IP 族: IPv4\nGoogle 出站: %s\n候选来源: Cloudflare 官方 IPv4 CIDR / 三网 Globalping eyeball 探针\n域名兜底: disabled\n' \
        "$(xray_installed_version)" "${VLESS_CDN_DOMAIN}" "${CLOUDFLARE_ORIGIN_DOMAIN}" "${CLOUDFLARE_ORIGIN_CERT_ID}" "${CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON}" \
        "$(google_egress_status)"
    if subscription_enabled; then
        printf '公开订阅: Cloudflare Worker %s（%s）\n' \
            "${CLOUDFLARE_WORKER_NAME}" "${SUBSCRIPTION_DOMAIN}"
        printf 'Nginx 订阅源: 私有，仅允许 Worker 专用密钥访问\n'
        printf '聚合配置: nodes=%s，externalSubUrl=%s，fallbackCdnNodes=%s\n' \
            "$(jq '.nodes | length' <<<"${WORKER_AGGREGATION_CONFIG}")" \
            "$(jq -r 'if .externalSubUrl == "" then "未配置" else "已配置（URL 隐藏）" end' \
                <<<"${WORKER_AGGREGATION_CONFIG}")" \
            "$(jq '.fallbackCdnNodes | length' <<<"${WORKER_AGGREGATION_CONFIG}")"
    else
        printf '公开订阅: 未部署\n'
    fi
    printf 'VPS 出站: IPv4-only（IPv6 全局禁用）\n'
    show_globalping_status
}

show_subscription() {
    collect_installed_state
    show_node
    if ! subscription_enabled; then
        printf '订阅服务: 未部署，仅输出节点信息\n\n'
        return 0
    fi
    printf 'Mihomo 下载文件名: %s\n' "${SUB_DOWNLOAD_NAME}"
    local user token subscription_domain
    subscription_domain=$(subscription_link_domain)
    printf '订阅链接域名: %s\n' "${subscription_domain}"
    while IFS=$'\t' read -r user token; do
        printf '通用订阅 (Base64) (%s): https://%s/subscribe?token=%s\n' \
            "${user}" "${subscription_domain}" "${token}"
        printf 'Mihomo / Clash   (%s): https://%s/subscribe?token=%s&flag=clash\n' \
            "${user}" "${subscription_domain}" "${token}"
    done < <(jq -r 'to_entries[] | [.key,.value] | @tsv' <<<"${ALLOWED_TOKENS}")
    printf '\n'
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
    remove_quota_timer
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_platform_security_state
    restore_preinstall_firewall
    restore_bbr_tcp_install_state
    restore_preinstall_crontab
    rm -f -- "${XRAY_SERVICE_FILE}" "${NGINX_CONFIG}" "${COMMAND_PATH}"
    systemctl daemon-reload >/dev/null 2>&1 || true
    rm -rf -- "${STATE_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" "${XRAY_DIR}"
    cloudflare_clear_api_token
}

cloudflare_rollback_fresh_install_resources() {
    local ruleset ref id failed=0
    if [[ "${CLOUDFLARE_WORKER_CREATED:-0}" == "1" ]]; then
        (cloudflare_delete_subscription_worker_resources \
            "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" "${CLOUDFLARE_WORKER_NAME:-}") \
            || { warn "回滚本次新建的 Cloudflare Worker 失败"; failed=1; }
    elif [[ -n "${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID:-}" ]]; then
        (cloudflare_api_request DELETE \
            "/accounts/${CLOUDFLARE_ACCOUNT_ID}/workers/domains/${CLOUDFLARE_CREATED_WORKER_DOMAIN_ID}" >/dev/null) \
            || { warn "回滚本次新建的 Worker 自定义域名失败"; failed=1; }
    fi
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

install_all() {
    [[ -t 0 || "${FORCE_INTERACTIVE:-0}" == "1" ]] || die "安装必须在交互终端中执行"
    CDN_PROVIDER="cloudflare"
    BACKEND="xray"
    PROTOCOL="cloudflare-streamup"
    require_root
    require_systemd

    [[ ! -f "${STATE_FILE}" ]] || die "easy_all 已安装；请使用 easy_all apply 刷新配置"
    check_platform
    check_install_conflicts
    snapshot_fresh_install
    install_packages
    ensure_ssh_boot_service
    configure_bbr_tcp
    configure_daily_reboot
    collect_install_inputs
    cloudflare_prepare_origin
    configure_ufw
    write_bootstrap_nginx_config
    cloudflare_issue_origin_certificate 0
    download_xray
    xhttp_render_xray_config
    install_xray_service
    write_nginx_config
    validate_protocol_runtime
    cloudflare_configure_cdn
    cloudflare_validate_cdn_health
    refresh_globalping_cache \
        || die "首次 Globalping 测量失败"
    subscription_enabled && { write_subscriptions; validate_subscription_runtime; }
    cloudflare_deploy_subscription_worker
    cloudflare_validate_subscription_worker
    cloudflare_finalize_certificate_rotation
    save_state
    register_easy_all_command
    persist_globalping_token
    install_globalping_refresh_timer
    install_quota_timer
    INSTALL_ROLLBACK_ON_EXIT=0
    cloudflare_clear_api_token
    show_subscription
    if [[ "${CLOUDFLARE_WORKER_MANUAL_DEPLOY_REQUIRED:-0}" == "1" ]]; then
        warn "本机与 Cloudflare 资源已保留；请将 ${CLOUDFLARE_WORKER_RECOVERY_FILE} 手工部署到 Worker ${CLOUDFLARE_WORKER_NAME}"
    else
        success "easy_all Cloudflare CDN XHTTP 与 Worker 聚合订阅安装完成"
    fi
    show_bbrv3_status
    prompt_bbrv3_reboot
}

apply_easy_all() {
    require_root
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
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
    begin_quota_maintenance
    collect_installed_state
    snapshot_subscription_update
    configure_bbr_tcp
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
    cloudflare_deploy_subscription_worker
    cloudflare_validate_subscription_worker
    save_state
    show_subscription
    cloudflare_validate_cdn_health
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
    commit_subscription_update
    if [[ "${CLOUDFLARE_WORKER_MANUAL_DEPLOY_REQUIRED:-0}" == "1" ]]; then
        warn "Cloudflare 资源和本机配置已应用；请将 ${CLOUDFLARE_WORKER_RECOVERY_FILE} 手工部署到 Worker ${CLOUDFLARE_WORKER_NAME}"
    else
        success "Cloudflare Worker、DNS、Origin CA、规则和本机配置已应用"
    fi
}

update_subscription() {
    local previous_subscription_host="" previous_worker_domain_id=""
    local previous_subscription_enabled=0
    require_root
    begin_quota_maintenance
    collect_installed_state
    if subscription_enabled; then
        previous_subscription_enabled=1
        previous_subscription_host=$(active_subscription_link_domain)
        previous_worker_domain_id=${CLOUDFLARE_WORKER_DOMAIN_ID}
    fi
    snapshot_subscription_update
    choose_google_egress_mode
    PROMPT_SUBSCRIPTION_MODE=1
    choose_subscription_mode
    PROMPT_SUBSCRIPTION_MODE=0
    if subscription_enabled; then
        collect_cloudflare_worker_inputs
        choose_subscription_download_name
        choose_monthly_quota 1
        quota_enabled || ensure_allowed_tokens 1
        choose_worker_aggregation_config
        cloudflare_build_subscription_worker
    else
        SUBSCRIPTION_DOMAIN=${VLESS_CDN_DOMAIN}
        SUB_DOWNLOAD_NAME=$(normalize_sub_download_name \
            "${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}")
        ALLOWED_TOKENS=""
        WORKER_AGGREGATION_CONFIG='{"nodes":[],"externalSubUrl":"","fallbackCdnNodes":[]}'
        choose_monthly_quota 0
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
    if subscription_enabled; then
        cloudflare_deploy_subscription_worker
        cloudflare_validate_subscription_worker
        cloudflare_cleanup_previous_subscription_host \
            "${previous_subscription_host}" "${previous_worker_domain_id}"
        save_state
    elif ((previous_subscription_enabled == 1)); then
        cloudflare_delete_subscription_worker_resources \
            "${previous_worker_domain_id}" "${CLOUDFLARE_WORKER_NAME}"
        CLOUDFLARE_WORKER_DOMAIN_ID=""
        CLOUDFLARE_WORKER_NAME=""
        WORKER_SOURCE_SECRET=""
        WORKER_AGGREGATION_CONFIG='{"nodes":[],"externalSubUrl":"","fallbackCdnNodes":[]}'
        save_state
    else
        save_state
    fi
    show_subscription
    cloudflare_validate_cdn_health
    cloudflare_finalize_certificate_rotation
    install_globalping_refresh_timer
    cloudflare_clear_api_token
    commit_subscription_update
    if [[ "${CLOUDFLARE_WORKER_MANUAL_DEPLOY_REQUIRED:-0}" == "1" ]]; then
        warn "订阅配置已保留；请将 ${CLOUDFLARE_WORKER_RECOVERY_FILE} 手工部署到 Worker ${CLOUDFLARE_WORKER_NAME}"
    else
        success "Cloudflare Worker 订阅、Origin CA 与回源规则已更新"
    fi
}

purge_cloudflare_resources_before_uninstall() {
    local allow_partial=${1:-0} host header_name strict_name
    [[ "${UNINSTALL_PURGE_CLOUD:-0}" == "1" ]] || return 0
    if [[ "${allow_partial}" != "1" ]]; then
        [[ -n "${CLOUDFLARE_ORIGIN_CERT_ID:-}" \
            && -n "${CLOUDFLARE_HEADER_RULESET_ID:-}" \
            && -n "${CLOUDFLARE_STRICT_RULESET_ID:-}" ]] \
            || die "状态缺少 Cloudflare 证书或 ruleset ID，已停止卸载；本机状态仍保留"
        if subscription_enabled; then
            [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" \
                && -n "${CLOUDFLARE_WORKER_NAME:-}" \
                && -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" ]] \
                || die "状态缺少 Cloudflare Worker 资源 ID，已停止卸载；本机状态仍保留"
        fi
    fi
    cloudflare_collect_api_token

    if subscription_enabled \
        && [[ -n "${CLOUDFLARE_ACCOUNT_ID:-}" \
            && -n "${CLOUDFLARE_WORKER_NAME:-}" \
            && ( -n "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" \
                || "${CLOUDFLARE_WORKER_CREATED:-0}" == "1" ) ]]; then
        cloudflare_delete_subscription_worker_resources \
            "${CLOUDFLARE_WORKER_DOMAIN_ID:-}" "${CLOUDFLARE_WORKER_NAME}" \
            || die "Cloudflare Worker 或自定义域名删除失败，已停止卸载；本机状态仍保留"
    fi

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
    success "easy_all 托管的 Cloudflare Worker、DNS、规则、ruleset 与 Origin CA 证书已清理"
}

uninstall_all() {
    local mode=${1:-} answer
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
                '删除本机内容以及 easy_all 托管的 Cloudflare Worker、DNS、规则和 Origin CA 证书？[y/N]:' answer
        else
            read_bilingual \
                '删除本机内容（Cloudflare 资源保留）？[y/N]:' answer
        fi
        [[ "${answer}" =~ ^[Yy]$ ]] || die "已取消"
    fi
    purge_cloudflare_resources_before_uninstall
    stop_services
    remove_quota_timer
    remove_globalping_refresh_timer
    cloudflare_remove_origin_firewall_rules
    restore_platform_security_state
    restore_preinstall_firewall
    restore_bbr_tcp_install_state
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
