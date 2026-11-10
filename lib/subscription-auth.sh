#!/usr/bin/env bash

# 订阅模式、凭据、渲染与发布事务（鉴权由 Caddy 配置承担，这里不再生成 Nginx）

normalize_subscription_mode() {
    case "$1" in
    deploy | local) printf 'deploy\n' ;;
    link | none) printf 'link\n' ;;
    *) return 1 ;;
    esac
}

choose_subscription_mode() {
    local mode=${SUBSCRIPTION_MODE:-} current_mode default_choice choice
    local deploy_description=${SUBSCRIPTION_DEPLOY_DESCRIPTION:-Caddy}
    local default_mode=${SUBSCRIPTION_DEFAULT_MODE:-deploy}
    if [[ "${PROMPT_SUBSCRIPTION_MODE:-0}" == "1" || -z "${mode}" ]]; then
        if [[ -t 0 ]]; then
            current_mode=$(normalize_subscription_mode "${mode:-${default_mode}}") \
                || die "当前订阅服务模式无效：${mode}"
            [[ "${current_mode}" == "link" ]] && default_choice=2 || default_choice=1
            printf '请选择是否部署订阅服务：\n'
            printf '  1. 部署订阅服务（%s；只有当前服务器时推荐）\n' \
                "${deploy_description}"
            printf '  2. 不部署，仅输出节点信息（已有订阅服务器时推荐）\n'
            read_bilingual \
                "请选择 [${default_choice}]（直接回车使用默认值）:" choice
            case "${choice:-}" in
            "") mode=${current_mode} ;;
            1) mode=deploy ;;
            2) mode=link ;;
            deploy | link) mode=${choice} ;;
            *) die "订阅输出选项无效：${choice}" ;;
            esac
        elif [[ -z "${mode}" ]]; then
            die "非交互模式必须设置 SUBSCRIPTION_MODE=deploy 或 SUBSCRIPTION_MODE=link"
        fi
    fi
    SUBSCRIPTION_MODE=$(normalize_subscription_mode "${mode:-${default_mode}}") \
        || die "订阅服务选项无效：${mode}"
}

subscription_enabled() {
    [[ "${SUBSCRIPTION_MODE:-deploy}" != "link" ]]
}

choose_subscription_download_name() {
    local allow_prompt=${1:-1} name=${SUB_DOWNLOAD_NAME:-${DEFAULT_SUB_DOWNLOAD_NAME}}
    if [[ "${allow_prompt}" == "1" && -t 0 ]]; then
        name=$(prompt_value "Mihomo 下载文件名（不含 .yaml）" "${name}")
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
                    elif any($clean[]; (.key == "." or .key == "..")) then
                    error("ALLOWED_TOKENS 用户名不能为 . 或 ..")
                    elif any($clean[]; (.key | test("^[A-Za-z0-9._-]{1,64}$") | not)) then
                    error("ALLOWED_TOKENS 用户名只能包含字母、数字、点、下划线、短横线，长度 1-64")
                    elif any($clean[]; (.value | test("^[A-Za-z0-9._-][A-Za-z0-9._~-]{7,127}$") | not)) then
                    error("ALLOWED_TOKENS token 只能包含 URL 安全字符 A-Z a-z 0-9 . _ ~ -，长度 8-128，且首字符不能是 ~")
                    elif (($clean | map(.key | ascii_downcase) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 清洗后存在重复用户名")
                    elif (($clean | map(.value | ascii_downcase) | unique | length) != ($clean | length)) then
                    error("ALLOWED_TOKENS 不允许重复 token")
                    else
                    $clean | from_entries
                    end
                end
            end
        end
    ' <<<"${raw}"
}

render_mihomo_subscription() {
    local template=$1 node_file=$2 destination=$3 node_name=$4
    local group_file=${5:-} name_file=${6:-}
    local encoded_node_name
    encoded_node_name=$(jq -Rn --arg value "${node_name}" '$value')
    EASY_ALL_NODE_NAME="${encoded_node_name}" \
    awk -v node_file="${node_file}" \
        -v group_file="${group_file}" -v name_file="${name_file}" '
        $0 == "# EASY_ALL_PROXY_NODE" {
            while ((getline line < node_file) > 0) print line
            close(node_file)
            next
        }
        $0 == "# EASY_ALL_PROXY_GROUP" {
            if (group_file != "") {
                while ((getline line < group_file) > 0) print line
                close(group_file)
            }
            next
        }
        $0 == "# EASY_ALL_PROXY_NAME" {
            if (name_file != "") {
                while ((getline line < name_file) > 0) print line
                close(name_file)
            } else {
                print "        - " ENVIRON["EASY_ALL_NODE_NAME"]
            }
            next
        }
        { print }
    ' "${template}" >"${destination}" || die "生成 Mihomo 订阅失败"
}

strip_mihomo_sniffer() {
    local source=$1 content
    [[ -s "${source}" ]] || die "待处理 Mihomo 配置为空：${source}"
    # 行尾注释允许出现（`sniffer:  # 嗅探`），内联映射无法按段剔除。
    # 顶格注释行原样保留：它们也可能属于上一个被剔除的顶层段，不能跟着 sniffer 段一起吐掉。
    content=$(awk '
        /^sniffer:[[:space:]]*(#.*)?$/ { skip = 1; next }
        skip && /^#/ { print; next }
        skip && /^[^[:space:]#]/ { skip = 0 }
        !skip { print }
    ' "${source}") || die "剥离 Mihomo 嗅探配置失败：${source}"
    if grep -q '^sniffer:' <<<"${content}"; then
        die "Mihomo 模板的 sniffer 段必须写成块映射（sniffer: 后不能接内联内容）：${source}"
    fi
    printf '%s\n' "${content}"
}

publish_subscription_files() {
    local source_dir=$1 files file relative target target_dir candidate
    files=$(find "${source_dir}" -type f) || die "读取待发布订阅失败"
    [[ -n "${files}" ]] || die "待发布订阅为空"
    while IFS= read -r file; do
        [[ -s "${file}" ]] || die "待发布订阅文件为空：${file}"
    done <<<"${files}"

    install -d -o 0 -g 0 -m 0700 "${SUBSCRIPTION_DIR}"
    # shortcut: files switch independently; use a version pointer if a whole-generation snapshot is required.
    while IFS= read -r file; do
        relative=${file#"${source_dir}/"}
        target="${SUBSCRIPTION_DIR}/${relative}"
        target_dir=$(dirname -- "${target}")
        # A directory may equal a filename when changing modes.
        [[ -d "${target_dir}" || ! -e "${target_dir}" ]] || rm -f -- "${target_dir}"
        install -d -o 0 -g 0 -m 0700 "${target_dir}"
        candidate=$(mktemp "${target_dir}/.subscription.XXXXXX") \
            || die "创建订阅发布候选文件失败"
        cleanup_files+=("${candidate}")
        install -o 0 -g 0 -m 0600 "${file}" "${candidate}" \
            || die "写入订阅发布候选文件失败"
        [[ ! -d "${target}" ]] || rm -rf -- "${target}"
        mv -f -- "${candidate}" "${target}" || die "发布订阅文件失败"
    done <<<"${files}"

    while IFS= read -r file; do
        relative=${file#"${SUBSCRIPTION_DIR}/"}
        [[ -f "${source_dir}/${relative}" ]] || rm -f -- "${file}"
    done < <(find "${SUBSCRIPTION_DIR}" -type f)
    find "${SUBSCRIPTION_DIR}" -mindepth 1 -depth -type d -empty -delete
}

validate_subscription_token_rejection() {
    local resolve=$1 url=$2
    shift 2
    local status attempt
    # Strict TLS by default: the caller decides the trust store (CloudFront uses
    # the system CA, Cloudflare passes its explicit --cacert); -k is never
    # injected by this shared acceptance helper.
    local -a tls_args=(--proto '=https')
    # Caddy reload 是异步完成的：刚部署后可能仍由旧实例作答（旧实例没有该路由时返回
    # 404）。短暂轮询真正的 403，其他状态立即失败。
    for attempt in {1..20}; do
        status=$(curl -sS "${tls_args[@]}" --noproxy '*' --connect-timeout 5 --max-time 20 \
            -o /dev/null -w '%{http_code}' \
            --resolve "${resolve}" "$@" --get --data-urlencode "token=invalid" "${url}") \
            || die "无效订阅 Token 验收请求失败"
        [[ "${status}" == "404" ]] || break
        sleep 0.25
    done
    [[ "${status}" == "403" ]] || die "无效订阅 Token 未被拒绝（HTTP ${status}）"
}
