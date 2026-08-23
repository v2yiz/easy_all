#!/usr/bin/env bash

# Shared subscription modes, credentials, rendering and Nginx routes.

normalize_subscription_mode() {
    case "$1" in
    1 | deploy | selfhost | nginx) printf 'deploy\n' ;;
    2 | link | node | vless) printf 'link\n' ;;
    *) return 1 ;;
    esac
}

choose_subscription_mode() {
    local mode=${SUBSCRIBE_MODE:-${SUBSCRIPTION_MODE:-}} current_mode default_choice=1
    local deploy_description=${SUBSCRIPTION_DEPLOY_DESCRIPTION:-Nginx}
    if [[ "${PROMPT_SUBSCRIPTION_MODE:-0}" == "1" || -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            current_mode=$(normalize_subscription_mode "${mode:-deploy}") \
                || die "当前订阅服务模式无效：${mode}"
            [[ "${current_mode}" == "link" ]] && default_choice=2
            printf '请选择是否部署订阅服务：\n'
            printf 'Choose whether to deploy the subscription service:\n'
            printf '  1. 部署订阅服务（%s；只有当前服务器时推荐）\n' \
                "${deploy_description}"
            printf '     Deploy the subscription service (%s; recommended for a single server)\n' \
                "${deploy_description}"
            printf '  2. 不部署，仅输出节点信息（多节点聚合或已有订阅服务器时推荐）\n'
            printf '     Do not deploy it; output node information only (recommended for multi-node setups or an existing subscription server)\n'
            read_bilingual \
                "请选择 [${default_choice}]（直接回车使用默认值）:" \
                "Choose [${default_choice}] (press Enter to use the default):" mode
            mode=${mode:-${current_mode}}
        elif [[ -z "${mode}" ]]; then
            die "非交互模式必须设置 SUBSCRIPTION_MODE=deploy 或 SUBSCRIPTION_MODE=link"
        fi
    fi
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${mode:-deploy}") \
        || die "订阅服务选项无效：${mode}"
    unset SUBSCRIBE_MODE
}

subscription_enabled() {
    [[ "${SUBSCRIPTION_MODE:-deploy}" == "deploy" ]]
}

choose_subscription_download_name() {
    local allow_prompt=${1:-1} name=${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}
    if [[ "${allow_prompt}" == "1" && -t 0 ]]; then
        name=$(prompt_value "Mihomo 下载文件名（不含 .yaml）" "${name}" \
            "Mihomo download filename (without .yaml)")
    fi
    name=$(normalize_sub_download_name "${name}")
    validate_sub_download_name "${name}" || die "Mihomo 下载文件名无效：${name}"
    SUB_DOWNLOAD_NAME=${name}
}

generate_secret() {
    openssl rand -base64 24 | tr '+/' '-_' | tr -d '=\n'
}

normalize_allowed_tokens() {
    local raw=$1
    jq -cer '
        def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
        if type != "object" then
            error("ALLOWED_TOKENS 必须是 JSON object")
        else
            to_entries as $entries
            | if ($entries | length) == 0 then
                error("ALLOWED_TOKENS 不能为空")
            else
                if any($entries[]; (.value | type) != "string") then
                    error("ALLOWED_TOKENS token 值必须是字符串")
                else
                    [ $entries[] | {key: (.key | trim), value: (.value | trim)} ] as $clean
                    | if any($clean[]; .key == "" or .value == "") then
                    error("ALLOWED_TOKENS 不允许空用户名或空 token")
                    elif any($clean[]; (.key | test("^[A-Za-z0-9._-]{1,64}$") | not)) then
                    error("ALLOWED_TOKENS 用户名只能包含字母、数字、点、下划线、短横线，长度 1-64")
                    elif any($clean[]; (.value | test("^[A-Za-z0-9._~-]{8,128}$") | not)) then
                    error("ALLOWED_TOKENS token 只能包含 URL 安全字符 A-Z a-z 0-9 . _ ~ -，长度 8-128")
                    elif (($clean | map(.key) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 清洗后存在重复用户名")
                    elif (($clean | map(.value) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 不允许重复 token")
                    else
                    $clean | from_entries
                    end
                end
            end
        end
    ' <<<"${raw}"
}

ensure_allowed_tokens() {
    local raw prompt_default normalized
    if [[ -n "${ALLOWED_TOKENS:-}" ]]; then
        raw=${ALLOWED_TOKENS}
    elif [[ -t 0 ]]; then
        prompt_default=$(jq -cn --arg token "$(generate_secret)" '{owner: $token}')
        raw=$(prompt_value "订阅用户 Token 字典 JSON（用户名=>token）" "${prompt_default}" \
            "Subscription user Token map JSON (username => Token)")
    else
        die "非交互模式必须设置 ALLOWED_TOKENS，例如 ALLOWED_TOKENS='{\"owner\":\"$(generate_secret)\"}'"
    fi

    normalized=$(normalize_allowed_tokens "${raw}") \
        || die "ALLOWED_TOKENS 无效；请使用 JSON 对象，例如 {\"owner\":\"$(generate_secret)\"}"
    ALLOWED_TOKENS=${normalized}
}

write_subscription_token_map() {
    if quota_enabled; then
        jq -r 'to_entries[] | "    \"" + .value.token + "\" \"" + .key + "\";"' \
            <<<"$(quota_active_accounts_json)"
        return 0
    fi
    jq -r '.[] | "    \"" + . + "\" 1;"' <<<"${ALLOWED_TOKENS}"
}

render_mihomo_subscription() {
    local template=$1 node_file=$2 destination=$3 node_name=$4
    local encoded_node_name
    encoded_node_name=$(jq -Rn --arg value "${node_name}" '$value')
    awk -v node_file="${node_file}" -v node_name="${encoded_node_name}" \
        -v ipv6_enabled=false '
        $0 ~ /^ipv6: (true|false)$/ {
            print "ipv6: " ipv6_enabled
            next
        }
        $0 == "# EASY_ALL_PROXY_NODE" {
            while ((getline line < node_file) > 0) print line
            close(node_file)
            next
        }
        $0 == "# EASY_ALL_PROXY_NAME" { print "        - " node_name; next }
        { print }
    ' "${template}" >"${destination}" || die "生成 Mihomo 订阅失败"
}

write_subscription_nginx_maps() {
    subscription_enabled || return 0
    cat <<'EOF'
map $arg_token $easy_all_subscription_allowed {
    default __denied__;
EOF
    write_subscription_token_map
    cat <<'EOF'
}

map $arg_flag $easy_all_subscription_uri {
    default /_easy_all_subscription/base64;
    clash /_easy_all_subscription/mihomo;
}

EOF
}

write_subscription_nginx_locations() {
    local origin_header_secret=${1:-}
    local base64_alias="${SUBSCRIPTION_BASE64_FILE}"
    local mihomo_alias="${SUBSCRIPTION_MIHOMO_FILE}"
    local origin_guard=""
    subscription_enabled || return 0
    if [[ -n "${origin_header_secret}" ]]; then
        [[ "${origin_header_secret}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            || die "订阅源站保护密钥格式无效"
        origin_guard="        if (\$http_x_easy_all_origin_key != \"${origin_header_secret}\") { return 404; }"
    fi
    if quota_enabled; then
        base64_alias="${SUBSCRIPTION_DIR}/\$easy_all_subscription_allowed/base64.txt"
        mihomo_alias="${SUBSCRIPTION_DIR}/\$easy_all_subscription_allowed/mihomo.yaml"
    fi
    cat <<'EOF'
    location = /subscribe {
EOF
    [[ -z "${origin_guard}" ]] || printf '%s\n' "${origin_guard}"
    cat <<EOF
        if (\$request_method !~ ^(GET|HEAD)$) { return 405; }
        if (\$easy_all_subscription_allowed = __denied__) { return 403; }
        rewrite ^ \$easy_all_subscription_uri last;
    }

    location = /_easy_all_subscription/base64 {
        internal;
        alias ${base64_alias};
        default_type text/plain;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

    location = /_easy_all_subscription/mihomo {
        internal;
        alias ${mihomo_alias};
        default_type text/yaml;
        add_header Content-Disposition "attachment; filename=${SUB_DOWNLOAD_NAME}" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

EOF
}

validate_subscription_token_rejection() {
    local resolve=$1 url=$2
    shift 2
    local status
    status=$(curl -ksS --noproxy '*' -o /dev/null -w '%{http_code}' \
        --resolve "${resolve}" "$@" --get --data-urlencode "token=invalid" "${url}") \
        || die "无效订阅 Token 验收请求失败"
    [[ "${status}" == "403" ]] || die "无效订阅 Token 未被拒绝（HTTP ${status}）"
}
