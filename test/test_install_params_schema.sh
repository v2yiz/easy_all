#!/usr/bin/env bash
# 各 Profile 安装参数声明的真机可执行性测试：真实 source → 预检 → 聚合校验。
# 覆盖 5 个模式的参数声明、默认值、条件字段（link/deploy/worker）与跨字段校验。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >&2 && pwd)
TMP_DIR=$(command mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_schema_test.XXXXXX")
trap 'command rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}

assert_contains() {
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] \
        || fail "${label}: missing <${expected}> in <${text}>"
}

command -v jq >/dev/null 2>&1 || fail "test_install_params_schema 需要 jq"

# --- 与 test_combined_render.sh 相同的隔离脚手架：Profile 的 readonly 路径与 root 写入 ---
readonly() {
    local arg name val
    for arg in "$@"; do
        [[ "${arg}" == -* ]] && continue
        [[ "${arg}" == *=* ]] || continue
        name=${arg%%=*}
        val=${arg#*=}
        if [[ -z "${!name+x}" ]]; then
            printf -v "${name}" '%s' "${val}"
        fi
    done
}

mktemp() {
    if [[ $# -eq 1 && "$1" == "-d" ]]; then
        command mktemp -d "${TMP_DIR}/runtime.XXXXXX"
    else
        command mktemp "$@"
    fi
}

install() {
    local args=() arg target
    for arg in "$@"; do
        case "${arg}" in
        -o | -g) continue ;;
        esac
        args+=("${arg}")
    done
    target="${args[${#args[@]}-1]}"
    case "${target}" in
    /etc/* | /var/* | /usr/*) target="${TMP_DIR}/root${target}"; args[${#args[@]}-1]="${target}" ;;
    esac
    mkdir -p "$(dirname "${target}")" 2>/dev/null || true
    command install "${args[@]}"
}

export STATE_DIR="${TMP_DIR}/state"
export BACKUP_DIR="${STATE_DIR}/backups"
export STATE_FILE="${STATE_DIR}/state.env"
export RUNTIME_TMP="${TMP_DIR}/runtime"
export CERT_DIR="${STATE_DIR}/certs"
export CERT_FILE="${CERT_DIR}/fullchain.pem"
export KEY_FILE="${CERT_DIR}/private.key"
export WEB_ROOT="${TMP_DIR}/web"
export SUBSCRIPTION_DIR="${WEB_ROOT}/subscriptions"
export COMMAND_INSTALL_DIR="${TMP_DIR}/lib"
export COMMAND_PATH="${TMP_DIR}/bin/easy_all"
export XRAY_DIR="${STATE_DIR}/xray"
export XRAY_BIN="${XRAY_DIR}/xray"
export XRAY_CONFIG="${XRAY_DIR}/config.json"
export XRAY_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-xray.service"
export NGINX_CONFIG="${TMP_DIR}/nginx.conf"
export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${TMP_DIR}/runtime-write.lock"
export EASY_ALL_POLICY_STATE_DIR_OVERRIDE="${TMP_DIR}/policy-state"
export EASY_ALL_POLICY_RC_OVERRIDE="${TMP_DIR}/policy-rc.d"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress.env"
export MIHOMO_TEMPLATE_FILE="${ROOT_DIR}/templates/mihomo.yaml"
export BUNNY_RECOVERY_DIR="${TMP_DIR}/bunny"
export BUNNY_KEY_FILE="${BUNNY_RECOVERY_DIR}/bunny-api.key"
export BUNNY_CLOUDFLARE_TOKEN_FILE="${BUNNY_RECOVERY_DIR}/cloudflare-dns.token"
export BUNNY_CONFIG="${BUNNY_RECOVERY_DIR}/config.json"
export BUNNY_JOURNAL="${BUNNY_RECOVERY_DIR}/ownership.json"
mkdir -p "${STATE_DIR}" "${RUNTIME_TMP}" "${CERT_DIR}" "${WEB_ROOT}" "${COMMAND_INSTALL_DIR}" \
    "${XRAY_DIR}" "${TMP_DIR}/systemd" "${BUNNY_RECOVERY_DIR}"

# 写一份 0600 的参数文件。
write_params() { # $1=文件名 $2=JSON 内容
    printf '%s\n' "$2" >"${TMP_DIR}/$1"
    chmod 600 "${TMP_DIR}/$1"
    printf '%s' "${TMP_DIR}/$1"
}

# 在独立子 shell 中 source 真实 Profile 并跑预检；stdout 只留 call 的探针输出。
run_preflight() { # $1=profile $2=mode $3=params 文件 $4=探针表达式
    local profile=$1 mode=$2 file=$3 probe=$4
    (
        # shellcheck source=/dev/null
        source "${profile}"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/params.sh"
        # 这里模拟 --check-params：只校验，不删除参数文件。
        EASY_ALL_PARAMS_KEEP=1
        params_begin "${mode}" "${file}"
        collect_install_inputs
        params_finish 2>/dev/null
        eval "printf '%s' \"${probe}\""
    )
}

CF_TOKEN="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
GP_TOKEN="globalping-token-value"
TOKEN_MAP='{"owner":"abcdefgh-1234"}'

# 1. reality：link 模式（不部署订阅，不要求 Cloudflare Token）
params=$(write_params reality-link.json "{
  \"schema_version\": 1, \"mode\": \"reality\",
  \"params\": {
    \"NODE_HOST\": \"203.0.113.10\", \"SUBSCRIPTION_MODE\": \"link\",
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/reality.sh" reality "${params}" \
    '${NODE_HOST}|${SUBSCRIPTION_MODE}|${SUB_PORT_MODE}|${REALITY_TARGET}') \
    || fail "reality(link): preflight failed"
assert_equal "reality(link): defaults" \
    "203.0.113.10|link|dynamic|swdist.apple.com:443" "${out}"

# 2. reality：deploy 模式（订阅域名 + Cloudflare Token + Token 字典）
params=$(write_params reality-deploy.json "{
  \"schema_version\": 1, \"mode\": \"reality\",
  \"params\": {
    \"NODE_HOST\": \"203.0.113.10\", \"SUBSCRIPTION_MODE\": \"deploy\",
    \"SUBSCRIPTION_DOMAIN\": \"sub.example.com\",
    \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\",
    \"ALLOWED_TOKENS\": ${TOKEN_MAP},
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/reality.sh" reality "${params}" \
    '${SUBSCRIPTION_MODE}|${SUBSCRIPTION_DOMAIN}|${SUB_DOWNLOAD_NAME}') \
    || fail "reality(deploy): preflight failed"
assert_equal "reality(deploy): subscription fields" \
    "deploy|sub.example.com|EASY_ALL" "${out}"

# 3. reality：worker 模式（私有源域名与 Worker 名必须进入参数）
params=$(write_params reality-worker.json "{
  \"schema_version\": 1, \"mode\": \"reality\",
  \"params\": {
    \"NODE_HOST\": \"203.0.113.10\", \"SUBSCRIPTION_MODE\": \"worker\",
    \"SUBSCRIPTION_DOMAIN\": \"sub.example.com\", \"SUB_SOURCE_DOMAIN\": \"src.example.com\",
    \"CLOUDFLARE_WORKER_NAME\": \"easyall-reality\",
    \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\",
    \"ALLOWED_TOKENS\": ${TOKEN_MAP},
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/reality.sh" reality "${params}" \
    '${SUBSCRIPTION_MODE}|${SUB_SOURCE_DOMAIN}|${WORKER_AGGREGATION_CONFIG}') \
    || fail "reality(worker): preflight failed"
assert_equal "reality(worker): worker fields" \
    'worker|src.example.com|{"nodes":[],"fallbackCdnNodes":[]}' "${out}"

# 4. reality：不适用字段（link 模式给订阅域名）必须报错，而不是被静默忽略
params=$(write_params reality-bad.json "{
  \"schema_version\": 1, \"mode\": \"reality\",
  \"params\": {
    \"NODE_HOST\": \"203.0.113.10\", \"SUBSCRIPTION_MODE\": \"link\",
    \"SUBSCRIPTION_DOMAIN\": \"sub.example.com\", \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
bad=$(
    (
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/reality.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/params.sh"
        params_begin reality "${params}"
        collect_install_inputs
        params_finish
    ) 2>&1
) && fail "reality(link): inapplicable SUBSCRIPTION_DOMAIN must be rejected"
assert_contains "reality(link): inapplicable field reported" "${bad}" "SUBSCRIPTION_DOMAIN"
assert_contains "reality(link): inapplicable field reason" "${bad}" "当前配置下不适用"

# 5. reality：worker 缺少必填项与域名冲突必须一次报全
params=$(write_params reality-worker-bad.json "{
  \"schema_version\": 1, \"mode\": \"reality\",
  \"params\": {
    \"NODE_HOST\": \"203.0.113.10\", \"SUBSCRIPTION_MODE\": \"worker\",
    \"SUBSCRIPTION_DOMAIN\": \"src.example.com\", \"SUB_SOURCE_DOMAIN\": \"src.example.com\",
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
bad=$(
    (
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/reality.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/params.sh"
        params_begin reality "${params}"
        collect_install_inputs
        params_finish
    ) 2>&1
) && fail "reality(worker): invalid worker params must be rejected"
assert_contains "reality(worker): token missing" "${bad}" "ALLOWED_TOKENS"
assert_contains "reality(worker): cf token missing" "${bad}" "CLOUDFLARE_API_TOKEN"
assert_contains "reality(worker): source domain collision" "${bad}" "私有节点源域名不能与 Worker 公开订阅域名相同"

# 6. cloudflare-streamup：link 模式（不部署 Worker 订阅）
params=$(write_params cf-link.json "{
  \"schema_version\": 1, \"mode\": \"cloudflare-streamup\",
  \"params\": {
    \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\", \"VLESS_CDN_DOMAIN\": \"node.example.com\",
    \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\", \"SUBSCRIPTION_MODE\": \"link\",
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" cloudflare-streamup "${params}" \
    '${SUBSCRIPTION_MODE}|${SUBSCRIPTION_DOMAIN}|${CLOUDFLARE_WORKER_NAME}|${XRAY_XHTTP_LOOPBACK_PORT}') \
    || fail "cloudflare(link): preflight failed"
assert_equal "cloudflare(link): fields" "link|||10086" "${out}"

# 7. cloudflare-streamup：deploy 模式（Worker 订阅域名的默认值来自节点域名）
params=$(write_params cf-deploy.json "{
  \"schema_version\": 1, \"mode\": \"cloudflare-streamup\",
  \"params\": {
    \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\", \"VLESS_CDN_DOMAIN\": \"node.example.com\",
    \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\", \"SUBSCRIPTION_MODE\": \"deploy\",
    \"ALLOWED_TOKENS\": ${TOKEN_MAP},
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" cloudflare-streamup "${params}" \
    '${SUBSCRIPTION_MODE}|${SUBSCRIPTION_DOMAIN}|${CLOUDFLARE_WORKER_NAME}|${WORKER_BACKUP_DOMAIN}') \
    || fail "cloudflare(deploy): preflight failed"
assert_equal "cloudflare(deploy): defaults" "deploy|sub.example.com|easyall|" "${out}"

# 8. cloudflare-streamup：Worker 订阅域名与节点域名相同必须拒绝
params=$(write_params cf-bad.json "{
  \"schema_version\": 1, \"mode\": \"cloudflare-streamup\",
  \"params\": {
    \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\", \"VLESS_CDN_DOMAIN\": \"node.example.com\",
    \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\", \"SUBSCRIPTION_MODE\": \"deploy\",
    \"SUBSCRIPTION_DOMAIN\": \"node.example.com\", \"ALLOWED_TOKENS\": ${TOKEN_MAP},
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
bad=$(
    (
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/params.sh"
        params_begin cloudflare-streamup "${params}"
        collect_install_inputs
        params_finish
    ) 2>&1
) && fail "cloudflare(deploy): subscription==node domain must be rejected"
assert_contains "cloudflare(deploy): name collision" "${bad}" "Worker 订阅域名必须与节点域名不同"

# 9. gcore：link 模式
params=$(write_params gcore-link.json "{
  \"schema_version\": 1, \"mode\": \"gcore\",
  \"params\": {
    \"VLESS_CDN_DOMAIN\": \"cdn.example.com\", \"GCORE_ORIGIN_DOMAIN\": \"origin.example.com\",
    \"GCORE_API_TOKEN\": \"gcore-token-value\", \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\",
    \"SUBSCRIPTION_MODE\": \"link\", \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/xhttp-gcore.sh" gcore "${params}" \
    '${VLESS_CDN_DOMAIN}|${GCORE_ORIGIN_DOMAIN}|${XRAY_WEBSOCKET_LOOPBACK_PORT}|${SUBSCRIPTION_MODE}') \
    || fail "gcore(link): preflight failed"
assert_equal "gcore(link): fields" "cdn.example.com|origin.example.com|10087|link" "${out}"

# 10. gcore：两个域名相同必须拒绝
params=$(write_params gcore-bad.json "{
  \"schema_version\": 1, \"mode\": \"gcore\",
  \"params\": {
    \"VLESS_CDN_DOMAIN\": \"same.example.com\", \"GCORE_ORIGIN_DOMAIN\": \"same.example.com\",
    \"GCORE_API_TOKEN\": \"gcore-token-value\", \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\",
    \"SUBSCRIPTION_MODE\": \"link\", \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
bad=$(
    (
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/profiles/xhttp-gcore.sh"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/params.sh"
        params_begin gcore "${params}"
        collect_install_inputs
        params_finish
    ) 2>&1
) && fail "gcore(link): identical domains must be rejected"
assert_contains "gcore(link): identical domains" "${bad}" "CDN 节点域名与源站域名不能相同"

# 11. bunny：默认域名、默认带宽与 Token 文件落位
params=$(write_params bunny.json "{
  \"schema_version\": 1, \"mode\": \"bunny-ws\",
  \"params\": {
    \"CLOUDFLARE_ZONE\": \"example.com\", \"BUNNY_API_KEY\": \"bunny-api-key-value\",
    \"CLOUDFLARE_DNS_TOKEN\": \"cloudflare-dns-token\", \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/ws-bunny.sh" bunny-ws "${params}" \
    '${ORIGIN_DOMAIN}|${CDN_DOMAIN}|${BUNNY_BANDWIDTH_GB}|${OWNER_TOKEN}') \
    || fail "bunny: preflight failed"
assert_equal "bunny: derived domains" \
    "origin.example.com|cdn.example.com|500" "$(cut -d'|' -f1-3 <<<"${out}")"

# 12. combined：完整参数
params=$(write_params combined.json "{
  \"schema_version\": 1, \"mode\": \"combined\",
  \"params\": {
    \"CF_ZONE\": \"example.com\", \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\",
    \"GCORE_API_TOKEN\": \"gcore-token-value\", \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\",
    \"ALLOWED_TOKENS\": ${TOKEN_MAP}, \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/combined.sh" combined "${params}" \
    '${CF_ZONE}|${DIRECT_DOMAIN}|${GCORE_NODE_DOMAIN}|${SUBSCRIPTION_DOMAIN}') \
    || fail "combined: preflight failed"
assert_equal "combined: derived domains" \
    "example.com|node.example.com|gcore.example.com|sub.example.com" "${out}"

# 13. --print-params：每个模式都必须能生成合法模板
template_case() { # $1=profile $2=mode
    local profile=$1 mode=$2
    (
        # shellcheck source=/dev/null
        source "${profile}"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/params.sh"
        params_template_begin "${mode}"
        collect_install_inputs
        params_finish 2>/dev/null
    )
}
for pair in \
    "${ROOT_DIR}/profiles/reality.sh reality" \
    "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh cloudflare-streamup" \
    "${ROOT_DIR}/profiles/xhttp-gcore.sh gcore" \
    "${ROOT_DIR}/profiles/ws-bunny.sh bunny-ws" \
    "${ROOT_DIR}/profiles/combined.sh combined"; do
    set -- ${pair}
    profile=$1
    mode=$2
    template=$(template_case "${profile}" "${mode}") \
        || fail "template(${mode}): generation failed"
    assert_equal "template(${mode}): mode echoed" "${mode}" \
        "$(jq -r '.mode' <<<"${template}")"
    assert_equal "template(${mode}): schema version" "1" \
        "$(jq -r '.schema_version' <<<"${template}")"
    [[ "$(jq -r '.params | length' <<<"${template}")" -ge 5 ]] \
        || fail "template(${mode}): too few fields"
done

# 14. Cloudflare 独立 Worker 兜底域名：可选字段，接受合法的同 Zone 域名
params=$(write_params cf-backup.json "{
  \"schema_version\": 1, \"mode\": \"cloudflare-streamup\",
  \"params\": {
    \"CLOUDFLARE_API_TOKEN\": \"${CF_TOKEN}\", \"VLESS_CDN_DOMAIN\": \"node.example.com\",
    \"GLOBALPING_TOKEN\": \"${GP_TOKEN}\", \"SUBSCRIPTION_MODE\": \"link\",
    \"WORKER_BACKUP_DOMAIN\": \"backup.example.com\",
    \"WORKER_BACKUP_PLACEMENT\": \"aws:ap-east-1\",
    \"VPS_PUBLIC_IPV4\": \"203.0.113.10\"
  }
}")
out=$(run_preflight "${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" cloudflare-streamup "${params}" \
    '${WORKER_BACKUP_DOMAIN}|${WORKER_BACKUP_PLACEMENT}') \
    || fail "cloudflare(link+backup): preflight failed"
assert_equal "cloudflare(link+backup): backup worker fields" \
    "backup.example.com|aws:ap-east-1" "${out}"

# 15. 文档示例必须可用：docs/params-examples.md 的完整 JSON 块替换占位符后跑预检
doc_examples="${ROOT_DIR}/docs/params-examples.md"
[[ -f "${doc_examples}" ]] || fail "missing docs/params-examples.md"
block_dir="${TMP_DIR}/docblocks"
mkdir -p "${block_dir}"
awk -v dir="${block_dir}" '
    /^```json$/ { inside = 1; n++; file = sprintf("%s/block-%02d.json", dir, n); next }
    /^```$/ { inside = 0; next }
    inside { print > file }
' "${doc_examples}"

block_count=0
for block in "${block_dir}"/block-*.json; do
    [[ -e "${block}" ]] || continue
    # 片段（例如配额字段）不是完整文档，跳过。
    jq -e '.mode and .params' "${block}" >/dev/null 2>&1 || continue
    mode=$(jq -r '.mode' "${block}")
    case "${mode}" in
    reality) profile="${ROOT_DIR}/profiles/reality.sh" ;;
    cloudflare-streamup) profile="${ROOT_DIR}/profiles/xhttp-cloudflare-streamup.sh" ;;
    gcore) profile="${ROOT_DIR}/profiles/xhttp-gcore.sh" ;;
    bunny-ws) profile="${ROOT_DIR}/profiles/ws-bunny.sh" ;;
    combined) profile="${ROOT_DIR}/profiles/combined.sh" ;;
    *) fail "doc example: unknown mode ${mode}" ;;
    esac
    normalized="${block_dir}/normalized-$(basename "${block}")"
    jq --arg m "${mode}" '
        .params
        | (if .ALLOWED_TOKENS then .ALLOWED_TOKENS = {owner: "abcdefgh-1234"} else . end)
        | (if (has("NODE_HOST") and ((.NODE_HOST // "") == "")) then .NODE_HOST = "203.0.113.10" else . end)
        | (if (has("VPS_PUBLIC_IPV4") and ((.VPS_PUBLIC_IPV4 // "") == "")) then .VPS_PUBLIC_IPV4 = "203.0.113.10" else . end)
        | (if ((.CLOUDFLARE_API_TOKEN // "") | startswith("<")) then
              .CLOUDFLARE_API_TOKEN = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" else . end)
        | (if ((.GLOBALPING_TOKEN // "") | startswith("<")) then
              .GLOBALPING_TOKEN = "gcore-token-value" else . end)
        | (if ((.GCORE_API_TOKEN // "") | startswith("<")) then
              .GCORE_API_TOKEN = "gcore-token-value" else . end)
        | (if ((.BUNNY_API_KEY // "") | startswith("<")) then
              .BUNNY_API_KEY = "gcore-token-value" else . end)
        | (if ((.CLOUDFLARE_DNS_TOKEN // "") | startswith("<")) then
              .CLOUDFLARE_DNS_TOKEN = "gcore-token-value" else . end)
        | (if ((.OWNER_TOKEN // "") | startswith("<")) then
              .OWNER_TOKEN = "abcdefgh-1234" else . end)
        | {schema_version: 1, mode: $m, params: .}
    ' "${block}" >"${normalized}" || fail "doc example: jq normalize failed: ${block}"
    chmod 600 "${normalized}"
    if ! doc_out=$(run_preflight "${profile}" "${mode}" "${normalized}" 'ok' 2>&1); then
        fail "doc example (${mode}) must pass preflight: ${doc_out}"
    fi
    block_count=$((block_count + 1))
done
[[ "${block_count}" -ge 5 ]] \
    || fail "doc examples: expected at least 5 complete JSON blocks, got ${block_count}"

printf 'ok - install params schema\n'
