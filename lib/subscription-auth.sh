#!/usr/bin/env bash

# Shared subscription modes, credentials, rendering and Nginx routes.

normalize_subscription_mode() {
    case "$1" in
    deploy | local) printf 'deploy\n' ;;
    link | none) printf 'link\n' ;;
    *) return 1 ;;
    esac
}

choose_subscription_mode() {
    local mode=${SUBSCRIPTION_MODE:-} current_mode default_choice choice
    local deploy_description=${SUBSCRIPTION_DEPLOY_DESCRIPTION:-Nginx}
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
                    error("ALLOWED_TOKENS token 只能包含 URL 安全字符 A-Z a-z 0-9 . _ ~ -，长度 8-128，且首字符不能是 ~（Nginx map 会把 ~ 开头的键当成正则）")
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

# 把 ALLOWED_TOKENS 规范化为字典；安装参数层与 edit-sub 共用。
apply_allowed_tokens_params() {
    local raw=${ALLOWED_TOKENS:-} normalized
    [[ -n "${raw}" ]] \
        || die "缺少 ALLOWED_TOKENS：需要 {\"用户\":\"token\"} JSON"
    normalized=$(normalize_allowed_tokens "${raw}") \
        || die "ALLOWED_TOKENS 无效；请使用 JSON 对象，例如 {\"owner\":\"$(generate_secret)\"}"
    ALLOWED_TOKENS=${normalized}
}

ensure_allowed_tokens() {
    local prompt_existing=${1:-0} raw prompt_default
    if [[ "${prompt_existing}" == "1" && -t 0 ]]; then
        prompt_default=${ALLOWED_TOKENS:-$(jq -cn --arg token "$(generate_secret)" '{owner: $token}')}
        raw=$(prompt_value "订阅用户 Token 完整字典 JSON（用户名=>token）" "${prompt_default}")
    elif [[ -n "${ALLOWED_TOKENS:-}" ]]; then
        raw=${ALLOWED_TOKENS}
    elif [[ -t 0 ]]; then
        prompt_default=$(jq -cn --arg token "$(generate_secret)" '{owner: $token}')
        raw=$(prompt_value "订阅用户 Token 字典 JSON（用户名=>token）" "${prompt_default}")
    else
        die "非交互模式必须设置 ALLOWED_TOKENS，例如 ALLOWED_TOKENS='{\"owner\":\"$(generate_secret)\"}'"
    fi
    ALLOWED_TOKENS=${raw}
    apply_allowed_tokens_params
}

write_subscription_token_map() {
    [[ -n "${ALLOWED_TOKENS:-}" ]] \
        || die "订阅 Token 字典 ALLOWED_TOKENS 未初始化；请执行 sudo easy_all edit-sub 重新配置订阅 Token，或重新安装"
    jq -r '.[] | "    \"" + . + "\" 1;"' <<<"${ALLOWED_TOKENS}"
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
    # 顶格注释行原样保留：它们可能属于下一个顶层段，也可能是 Reality 的终止标记，不能跟着 sniffer 段一起吐掉。
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

write_subscription_nginx_maps() {
    local optional_variants=${1:-0}
    subscription_enabled || return 0
    cat <<'EOF'
map $arg_token $easy_all_subscription_allowed {
    default __denied__;
EOF
    write_subscription_token_map
    cat <<'EOF'
}

# 订阅格式协商：默认按客户端 User-Agent 自动判断；&flag= 只用于强制覆盖。
#  - clash / mihomo / meta / stash / flclash / verge 等内核类客户端 → Mihomo YAML
#  - Shadowrocket / v2rayN / v2rayNG / NekoBox / sing-box 等 URL 类客户端 → Base64(v2ray 链接)
map $arg_flag $easy_all_subscription_forced_format {
    default      "";
    clash        "mihomo";
    mihomo       "mihomo";
    meta         "mihomo";
    stash        "mihomo";
    yaml         "mihomo";
    base64       "base64";
    uri          "base64";
    v2ray        "base64";
    shadowrocket "base64";
}

map $http_user_agent $easy_all_subscription_ua_format {
    default "base64";
    ~*(clash|mihomo|stash|flclash|verge|bettbox) "mihomo";
}

map $easy_all_subscription_forced_format $easy_all_subscription_format {
    default  $easy_all_subscription_ua_format;
    "mihomo" "mihomo";
    "base64" "base64";
}

# 客户端系统识别：显式参数 os=ios（或 iphone/ipad）或 User-Agent 命中 iOS 任一即判定为 iOS
map $arg_os $easy_all_subscription_param_ios {
    default 0;
    ~*^(ios|iphone|ipad)$ 1;
}

map $http_user_agent $easy_all_subscription_ua_ios {
    default 0;
    # 这里的单个 \b 是有意写法：nginx 的 token 解析只解释 \" \' \\ \t \r \n 六种转义
    # （ngx_conf_read_token），其余 \X（含 \b）均原样透传给 PCRE，加不加双引号结果相同。
    ~*(iphone|ipad|ipod|\bios\b) 1;
}

map "$easy_all_subscription_param_ios:$easy_all_subscription_ua_ios" $easy_all_subscription_is_ios {
    default 0;
    ~*1     1;
}

EOF
    if [[ "${optional_variants}" == "1" ]]; then
        cat <<'EOF'

# node=all 时才下发带 optional 标记的聚合节点。
map $arg_node $easy_all_subscription_show_all {
    default 0;
    all     1;
}

map "$easy_all_subscription_format:$easy_all_subscription_is_ios:$easy_all_subscription_show_all" $easy_all_subscription_uri {
    "mihomo:1:1" /_easy_all_subscription/mihomo_ios_all;
    "mihomo:1:0" /_easy_all_subscription/mihomo_ios;
    "mihomo:0:1" /_easy_all_subscription/mihomo_all;
    "mihomo:0:0" /_easy_all_subscription/mihomo;
    # base64 没有 iOS 变体，iOS 与否都落到同一份文件；漏掉 base64:1:1 会让 iOS 客户端
    # （Shadowrocket 等）即使带 &node=all 也被 default 降级到不含 optional 节点的文件。
    "base64:0:1" /_easy_all_subscription/base64_all;
    "base64:1:1" /_easy_all_subscription/base64_all;
    default      /_easy_all_subscription/base64;
}
EOF
    else
        cat <<'EOF'
map "$easy_all_subscription_format:$easy_all_subscription_is_ios" $easy_all_subscription_uri {
    "mihomo:1" /_easy_all_subscription/mihomo_ios;
    "mihomo:0" /_easy_all_subscription/mihomo;
    default    /_easy_all_subscription/base64;
}
EOF
    fi
}

publish_subscription_files() {
    local source_dir=$1 files file relative target target_dir candidate
    files=$(find "${source_dir}" -type f) || die "读取待发布订阅失败"
    [[ -n "${files}" ]] || die "待发布订阅为空"
    while IFS= read -r file; do
        [[ -s "${file}" ]] || die "待发布订阅文件为空：${file}"
    done <<<"${files}"

    install -d -o root -g www-data -m 0750 "${SUBSCRIPTION_DIR}"
    # shortcut: files switch independently; use a version pointer if a whole-generation snapshot is required.
    while IFS= read -r file; do
        relative=${file#"${source_dir}/"}
        target="${SUBSCRIPTION_DIR}/${relative}"
        target_dir=$(dirname -- "${target}")
        # A directory may equal a filename when changing modes.
        [[ -d "${target_dir}" || ! -e "${target_dir}" ]] || rm -f -- "${target_dir}"
        install -d -o root -g www-data -m 0750 "${target_dir}"
        candidate=$(mktemp "${target_dir}/.subscription.XXXXXX") \
            || die "创建订阅发布候选文件失败"
        cleanup_files+=("${candidate}")
        install -o root -g www-data -m 0640 "${file}" "${candidate}" \
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

write_subscription_nginx_locations() {
    local origin_header_secret=${1:-}
    local renderer=${2:-static}
    local optional_variants=${3:-0}
    local error_log="" base64_content="" mihomo_content=""
    local suffix suffix_alias base64_alias mihomo_alias mihomo_ios_alias
    local origin_guard
    case "${renderer}" in static | reality) ;; *) die "订阅渲染类型无效" ;; esac
    subscription_enabled || return 0
    if [[ -n "${origin_header_secret}" ]]; then
        [[ "${origin_header_secret}" =~ ^[A-Za-z0-9._~-]{16,128}$ ]] \
            || die "订阅源站保护密钥格式无效"
        origin_guard="        if (\$http_x_easy_all_origin_key != \"${origin_header_secret}\") { return 404; }"
    else
        origin_guard=""
    fi
    if [[ "${renderer}" == "reality" ]]; then
        [[ "${SUB_PORT_MODE:-}" == "dynamic" || "${SUB_PORT_MODE:-}" == "443" ]] \
            || die "Reality 订阅端口模式无效"
        error_log="        error_log /dev/null;"
        base64_content="        set \$easy_all_reality_port_mode ${SUB_PORT_MODE};
        js_content easy_all_reality_subscription.base64;"
        mihomo_content="        set \$easy_all_reality_port_mode ${SUB_PORT_MODE};
        js_content easy_all_reality_subscription.mihomo;"
    fi
    cat <<EOF
    location = /subscribe {
EOF
    [[ -z "${origin_guard}" ]] || printf '%s\n' "${origin_guard}"
    cat <<EOF
        access_log off;
${error_log}
        if (\$request_method !~ ^(GET|HEAD)$) { return 405; }
        if (\$easy_all_subscription_allowed = __denied__) { return 403; }
        rewrite ^ \$easy_all_subscription_uri last;
    }

EOF
    for suffix in "" "-all"; do
        if [[ "${suffix}" == "-all" ]]; then
            [[ "${optional_variants}" == "1" ]] || continue
            suffix_alias="_all"
            base64_alias=${SUBSCRIPTION_BASE64_ALL_FILE}
            mihomo_alias=${SUBSCRIPTION_MIHOMO_ALL_FILE}
            mihomo_ios_alias=${SUBSCRIPTION_MIHOMO_IOS_ALL_FILE}
        else
            suffix_alias=""
            base64_alias=${SUBSCRIPTION_BASE64_FILE}
            mihomo_alias=${SUBSCRIPTION_MIHOMO_FILE}
            mihomo_ios_alias=${SUBSCRIPTION_MIHOMO_IOS_FILE:-${SUBSCRIPTION_DIR}/mihomo-ios.yaml}
        fi
        cat <<EOF
    location = /_easy_all_subscription/base64${suffix_alias} {
        internal;
        access_log off;
${error_log}
        alias ${base64_alias};
${base64_content}
        default_type text/plain;
        # 同一 URL 按 User-Agent 下发 YAML 或 Base64，必须声明 Vary，避免经 CDN/中间缓存串格式
        add_header Vary "User-Agent" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

    location = /_easy_all_subscription/mihomo${suffix_alias} {
        internal;
        access_log off;
${error_log}
        alias ${mihomo_alias};
${mihomo_content}
        default_type text/yaml;
        add_header Vary "User-Agent" always;
        add_header Content-Disposition "attachment; filename=${SUB_DOWNLOAD_NAME}" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

    location = /_easy_all_subscription/mihomo_ios${suffix_alias} {
        internal;
        access_log off;
${error_log}
        alias ${mihomo_ios_alias};
${mihomo_content}
        default_type text/yaml;
        add_header Vary "User-Agent" always;
        add_header Content-Disposition "attachment; filename=${SUB_DOWNLOAD_NAME}" always;
        add_header Cache-Control "no-store, no-cache, must-revalidate, max-age=0" always;
        add_header Pragma "no-cache" always;
        add_header X-Content-Type-Options "nosniff" always;
        add_header X-Robots-Tag "noindex, nofollow, noarchive" always;
    }

EOF
    done
}

validate_subscription_token_rejection() {
    local resolve=$1 url=$2
    shift 2
    local status arg attempt
    local -a tls_args=(-k)
    for arg in "$@"; do
        if [[ "${arg}" == "--cacert" ]]; then
            # Keep the array non-empty for Bash 3.x + `set -u`; the caller's
            # --cacert remains authoritative and replaces the default -k.
            tls_args=(--proto '=https')
            break
        fi
    done
    # `systemctl reload nginx` returns before every worker has switched to the
    # new config, so a request can still be answered from the previous one.
    # Right after a deploy that previous worker only knows the bootstrap server,
    # which has no /subscribe location and answers `location / { return 404; }`,
    # so a 404 can mean "worker not switched yet" rather than "token missing".
    # Poll briefly for the real 403 and fail fast on any other status.
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
