#!/usr/bin/env bash

# sing-box 完整 JSON 客户端订阅：模板 + 结构化节点合成，供 Caddy 鉴权后下发。
# 依赖调用方提供 log.sh 的 die/warn/fail，以及运行时字段：
# PROTOCOL、SCRIPT_DIR、AGGREGATION_NODES；节点构造由 lib/singbox-runtime.sh 提供。
# 官方 1.14.4 不支持 xhttp / mieru，只排除出本格式并提示，不影响其他订阅格式。

singbox_client_template_file() {
    local template="${SCRIPT_DIR}/../templates/singbox.json"
    [[ -s "${template}" ]] || die "缺少 sing-box 客户端模板：${template}"
    printf '%s\n' "${template}"
}

# 聚合节点分成「可用于 sing-box」与「排除」两组，排除原因在此处一次定义。
singbox_aggregation_partition_json() {
    jq -c '
        # 指纹名单取自锁定核心 1.14.4 的 utls 枚举：不在名单里的值会让 sing-box 拒绝整份配置，
        # 而聚合节点校验只要求 fp 非空，因此必须在合成阶段就分流，不能等核心报错。
        def supported_fingerprints:
            ["chrome_psk", "chrome_psk_shuffle", "chrome_padding_psk_shuffle",
             "chrome_pq", "chrome_pq_psk", "chrome", "firefox", "edge", "safari",
             "360", "qq", "ios", "android", "random", "randomized"];
        map(
            . as $node
            | {
                node: .,
                reason: (
                    if $node.type == "mieru" then "mieru 协议"
                    elif $node.security != "reality" then "xhttp 传输"
                    # 1.14.4 的 Reality 客户端会从 ClientHello 里过滤 X25519MLKEM768
                    # （common/tls/reality_client.go），聚合节点的 supportX25519Mlkem768
                    # 在 sing-box 侧无法表达：false 与核心行为一致，true 的 PQ 扩展不会出现，
                    # 两者都仍用经典 X25519 连接，因此都不排除。
                    elif (supported_fingerprints | index($node.fp)) == null then "客户端指纹不受支持"
                    else null end
                )
              }
        )
        | {supported: [.[] | select(.reason == null) | .node],
           excluded: [.[] | select(.reason != null) | {name: .node.name, reason: .reason}]}
    '
}

# 结构化节点 → sing-box outbound；凭据字段直接取自节点对象，不反向解析 URI。
singbox_aggregation_outbounds_json() {
    jq -c '
        map(
            {
              type: "vless",
              tag: .name,
              server: .host,
              server_port: .port,
              uuid: .uuid,
              flow: "xtls-rprx-vision",
              tls: {
                enabled: true,
                server_name: .sni,
                utls: {enabled: true, fingerprint: .fp},
                reality: {enabled: true, public_key: .pbk, short_id: .sid}
              }
            }
            + (if .udp then {packet_encoding: "xudp"} else {network: "tcp"} end)
        )
    '
}

singbox_client_local_outbounds_json() {
    local outbounds='[]'
    if runtime_has_direct_entry; then
        outbounds=$(jq -cn --argjson list "${outbounds}" \
            --argjson node "$(build_singbox_anytls_outbound)" '$list + [$node]')
    fi
    if runtime_has_cdn_entry; then
        outbounds=$(jq -cn --argjson list "${outbounds}" \
            --argjson node "$(build_singbox_ws_outbound)" '$list + [$node]')
    fi
    printf '%s\n' "${outbounds}"
}

# 本机节点 → 受支持的聚合节点；策略组成员只从最终 outbound 生成，避免悬空引用。
singbox_client_outbounds_json() {
    local local_outbounds supported members
    local_outbounds=$(singbox_client_local_outbounds_json)
    supported=$(aggregation_included_nodes | singbox_aggregation_partition_json \
        | jq -c '.supported' | singbox_aggregation_outbounds_json)
    members=$(jq -c '[.[].tag]' <<<"${local_outbounds}")
    members=$(jq -cn --argjson members "${members}" \
        --argjson extra "$(jq -c '[.[].tag]' <<<"${supported}")" '$members + $extra')
    # DIRECT 直连的域名解析必须走本地解析：route.default_domain_resolver 是节点引导解析器，
    # 而 sing-box 的传输级解析不经过 dns.rules，用引导解析器查局域网域名只会得到 NXDOMAIN。
    jq -cn --argjson members "${members}" --argjson local "${local_outbounds}" \
        --argjson supported "${supported}" '
        [{type: "selector", tag: "PROXY", outbounds: $members, default: $members[0]}]
        + [{type: "direct", tag: "DIRECT", domain_resolver: "dns-local"}]
        + $local + $supported'
}

# 被排除的聚合节点只报告节点名、原因与数量，不打印任何凭据字段。
singbox_report_excluded_nodes() {
    local excluded count detail
    excluded=$(singbox_aggregation_partition_json <<<"${AGGREGATION_NODES:-[]}" \
        | jq -r '.excluded[] | [.name, .reason] | @tsv')
    [[ -n "${excluded}" ]] || return 0
    count=$(awk 'END {printf "%d", NR}' <<<"${excluded}")
    detail=$(awk -F'\t' '{printf "%s%s（%s）", (NR > 1 ? "、" : ""), $1, $2}' <<<"${excluded}")
    warn "sing-box 订阅排除 ${count} 个聚合节点：${detail}"
}

# 受支持的 optional 节点名：验收 node=all 时必须出现这些 tag。
singbox_supported_optional_tags() {
    singbox_aggregation_partition_json <<<"${AGGREGATION_NODES:-[]}" \
        | jq -c '[.supported[] | select(.optional == true) | .name]'
}

singbox_client_config_structure_ok() {
    jq -e '
        . as $config
        | ($config.outbounds | map(.tag)) as $tags
        | ($config.dns.servers | map(.tag)) as $servers
        | ($config.route.rule_set | map(.tag)) as $sets
        | ($tags | length) > 0
        and ($tags | length) == ($tags | unique | length)
        and any($config.outbounds[]; .type == "selector" and .tag == "PROXY")
        and all($config.outbounds[] | select(.outbounds != null);
                all(.outbounds[]; . as $tag | $tags | index($tag) != null))
        and ($tags | index($config.route.final) != null)
        and all($config.route.rules[] | select(.outbound != null);
                .outbound as $tag | $tags | index($tag) != null)
        and all($config.route.rules[] | select(.rule_set != null);
                all(.rule_set[]; . as $tag | $sets | index($tag) != null))
        and all($config.dns.rules[] | select(.rule_set != null);
                all(.rule_set[]; . as $tag | $sets | index($tag) != null))
        and all($config.outbounds[] | select(.type == "selector" and .default != null);
                .default as $tag | $tags | index($tag) != null)
        and ($config.route.default_domain_resolver as $resolver
             | ($resolver == null)
               or (if ($resolver | type) == "string"
                   then ($servers | index($resolver) != null)
                   else ($servers | index($resolver.server) != null) end))
        and (($config.route.default_http_client // "") as $client
             | ($client == "")
               or (($config.http_clients // []) | map(.tag) | index($client) != null))
        and ($servers | index($config.dns.final) != null)
        and all($config.dns.rules[] | select(.server != null);
                .server as $tag | $servers | index($tag) != null)
        and all($config.dns.servers[] | select(.detour != null);
                .detour as $tag | $tags | index($tag) != null)
    ' "$1" >/dev/null 2>&1
}

# 候选订阅发布前的最后一道校验：结构引用、真实核心接受、无源站密钥。
validate_singbox_subscription_config() {
    local file=$1
    [[ -s "${file}" ]] || { fail "sing-box 订阅不存在或为空"; return 1; }
    singbox_client_config_structure_ok "${file}" \
        || { fail "sing-box 订阅结构校验失败"; return 1; }
    if [[ -x "${SINGBOX_BIN:-}" ]]; then
        "${SINGBOX_BIN}" check -c "${file}" >/dev/null \
            || { fail "sing-box 客户端配置未通过核心校验"; return 1; }
    fi
    if [[ -n "${ORIGIN_HEADER_SECRET:-}" ]] && grep -Fq -- "${ORIGIN_HEADER_SECRET}" "${file}"; then
        fail "sing-box 订阅包含源站密钥"
        return 1
    fi
    return 0
}

render_singbox_subscription() {
    local destination=$1 outbounds=$2 template
    template=$(singbox_client_template_file)
    jq --argjson outbounds "${outbounds}" '.outbounds = $outbounds' "${template}" \
        >"${destination}" || die "生成 sing-box 订阅失败"
}

# 渲染 default 与 all 两份 JSON；发布由调用方负责，就绪验收不经过这里。
render_singbox_subscription_files() {
    local output_dir=$1 suffix include file
    singbox_report_excluded_nodes
    for suffix in "" "-all"; do
        if [[ "${suffix}" == "-all" ]]; then
            subscription_optional_variants || continue
            include=1
        else
            include=0
        fi
        EASY_ALL_INCLUDE_OPTIONAL=${include}
        file="${output_dir}/singbox${suffix}.json"
        render_singbox_subscription "${file}" "$(singbox_client_outbounds_json)"
        validate_singbox_subscription_config "${file}" \
            || die "sing-box 订阅候选校验失败：${file##*/}"
        chmod 0600 "${file}"
    done
    EASY_ALL_INCLUDE_OPTIONAL=0
}
