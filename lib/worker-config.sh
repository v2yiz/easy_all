#!/usr/bin/env bash

# Shared Cloudflare Worker aggregation input handling for every profile that
# deploys a subscription Worker. The installer never accepts `vpsSubUrl` from
# users: each profile injects its own private node source before building.

validate_cloudflare_worker_name() {
    [[ "$1" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]
}

normalize_worker_aggregation_config() {
    local raw=${1:-}
    [[ -n "${raw}" ]] || raw='{}'
    jq -cer '
      del(.externalSubUrl) |
      if type != "object" then
        error("Worker 聚合配置必须是 JSON object")
      elif has("vpsSubUrl") then
        error("Worker 聚合配置不得包含 vpsSubUrl")
      elif ((keys - ["allowedTokens","nodes","fallbackCdnNodes"]) | length) != 0 then
        error("Worker 聚合配置包含不支持的字段")
      elif ((.nodes // []) | type) != "array"
        or ((.fallbackCdnNodes // []) | type) != "array"
        or (has("allowedTokens") and (.allowedTokens | type) != "object") then
        error("allowedTokens/nodes/fallbackCdnNodes 类型无效")
      elif ((.nodes // []) | map(select((.type // "vless") != "vless" and (.type // "vless") != "trojan")) | length) != 0 then
        error("nodes 仅支持 vless 或 trojan 节点")
      elif ((.fallbackCdnNodes // []) | map(select((.type // "vless") != "vless")) | length) != 0 then
        error("fallbackCdnNodes 仅支持 vless 节点")
      else
        {
          nodes:((.nodes // []) | map(
            if ([.server // "", .host // ""] | any(tostring | contains(":"))) then
              error("nodes 不允许 IPv6 literal")
            else . + {
              name:(if .name == "🇺🇸自建首选750G" or .name == "晚上首选" then "🇺🇸晚上首选" else .name end),
              ipVersion:"ipv4"
            } end
          )),
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
    local choice="" count raw current normalized
    current=$(normalize_worker_aggregation_config \
        "${WORKER_AGGREGATION_CONFIG:-}") \
        || die "当前 Worker 聚合配置无效"
    count=$(jq '.nodes | length' <<<"${current}")
    if [[ -t 0 ]]; then
        printf '说明：Worker 聚合配置不得包含 vpsSubUrl；若包含 allowedTokens，将覆盖刚设置的用户 Token。\n' >&2
        if ((count > 0)); then
            printf '当前 Worker 聚合配置：nodes=%s\n' "${count}" >&2
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
            printf '%s\n' "${WORKER_AGGREGATION_QUESTION:-是否需要进行订阅聚合？}" >&2
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
        || die "Worker 聚合配置无效；请参考 worker-src/config.example.json"
    apply_worker_allowed_tokens_override "${normalized}"
    WORKER_AGGREGATION_CONFIG=$(jq -c 'del(.allowedTokens)' <<<"${normalized}")
}

choose_cloudflare_worker_name() {
    local name=${CLOUDFLARE_WORKER_NAME:-${DEFAULT_CLOUDFLARE_WORKER_NAME}}
    if [[ -t 0 ]]; then
        name=$(prompt_value "Cloudflare Worker 名称（仅限小写字母、数字和短横线，长度 1-63，不能以短横线开头或结尾）" "${name}")
    fi
    validate_cloudflare_worker_name "${name}" \
        || die "Worker 名称只能包含小写字母、数字和短横线，长度 1-63，且不能以短横线开头或结尾"
    CLOUDFLARE_WORKER_NAME=${name}
}
