#!/usr/bin/env bash

# Subscription aggregation shared by all four modes.
# External nodes keep their own protocol fields (vless reality/xhttp, mieru); local
# easy_all nodes are built by lib/singbox-runtime.sh.
# One config object carries both credentials and extra nodes:
#   {"allowedTokens": {"owner": "..."}, "nodes": [...], "cdnEdgeAddress": "..."}
# cdnEdgeAddress is optional and only affects the local CDN node's connection address.
# Nodes marked optional are served only when the client asks for node=all.

# 保留组名的唯一来源：Profile source 时只声明数组（不调用 jq），安装前置预检可直接使用；
# jq 校验用的 JSON 只在真正需要 jq 的订阅处理路径里惰性生成。
readonly LOCAL_AGGREGATION_RESERVED_NAMES=(AUTO CDN-AUTO CDN-FALLBACK PROXY GLOBAL DIRECT REJECT PASS)

# 校验并规范化整个订阅配置；节点名冲突由调用方通过 LOCAL_NODE_NAMES 传入。
normalize_subscription_config() {
    local raw=${1:-} local_names=${2:-[]} tokens nodes reserved edge
    jq -e 'type == "object" and ((keys - ["allowedTokens","nodes","cdnEdgeAddress"]) | length) == 0' \
        <<<"${raw}" >/dev/null 2>&1 \
        || {
            printf '订阅配置只能包含 allowedTokens、nodes 与可选的 cdnEdgeAddress 键\n' >&2
            return 1
        }
    # 优选连接地址的形状校验单独一次调用：不加 2>&1，jq 的 error() 文案必须直达 stderr。
    # 只接受完整主机名（SNI / Host 仍用节点域名，所以这里不支持 *、URL、端口与路径）
    # 与 IP 字面量：连接地址必须是可被客户端解析的主机名。
    jq -e '
        def edge_ok:
            type == "string" and length >= 1 and length <= 253
            and test("^[A-Za-z0-9.-]+$")
            and (test("^[0-9.]+$") | not)
            and (contains("..") | not)
            and (startswith(".") | not) and (endswith(".") | not)
            and ([split(".")[] |
                select(test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$") | not)] | length) == 0
            and (split(".") | length) >= 2;
        if has("cdnEdgeAddress") and .cdnEdgeAddress != null then
            if (.cdnEdgeAddress | edge_ok) then true
            else error("cdnEdgeAddress 必须是完整主机名（FQDN；不支持 *、URL、端口或路径）") end
        else true end
    ' <<<"${raw}" >/dev/null || return 1
    tokens=$(jq -c '.allowedTokens // empty' <<<"${raw}") || return 1
    [[ -n "${tokens}" ]] || {
        printf '订阅配置缺少 allowedTokens\n' >&2
        return 1
    }
    tokens=$(normalize_allowed_tokens "${tokens}") || return 1
    # 保留组名只从 bash 数组生成一次 JSON（仅此 jq 路径需要），不保留第二份手写名单。
    reserved=$(jq -cn '$ARGS.positional' --args "${LOCAL_AGGREGATION_RESERVED_NAMES[@]}") \
        || return 1
    nodes=$(jq -c --argjson reserved "${reserved}" \
        --argjson local "${local_names}" '
        def fail($message): error($message);
        def nonempty: type == "string" and length > 0;
        def name_ok: type == "string" and test("^[^[:cntrl:]]{1,64}$");
        def port_ok: . == null or (type == "number" and . == floor and . >= 1 and . <= 65535);
        def host_ok:
            type == "string" and length >= 1 and length <= 253
            and (contains(":") | not)
            and test("^[A-Za-z0-9.-]+$")
            and (
                test("^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
                or test("^([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$")
                or test("^((25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])\\.){3}(25[0-5]|2[0-4][0-9]|1[0-9][0-9]|[1-9]?[0-9])$")
            );
        def node_allowed_keys:
            if .type == "mieru" then
                ["type","name","host","port","portRange","username","password","transport","multiplexing","trafficPattern","mtu","udp","optional"]
            elif .security == "reality" then
                ["type","name","host","port","security","network","uuid","sni","pbk","sid","fp","supportX25519Mlkem768","udp","optional"]
            else
                ["type","name","host","port","security","network","uuid","sni","path","mode","fp","xhttpUplinkHttpMethod","xhttpNoGrpcHeader","udp","optional"]
            end;
        if type != "array" then fail("nodes 必须是数组") else . end
        | map(
            if type != "object" then fail("nodes 的每一项必须是对象") else . end
            | .type as $type
            | if (["vless","mieru"] | index($type)) == null then
                fail("nodes 仅支持 vless（reality 或 xhttp）与 mieru")
              else . end
            | .name as $name
            | .host as $host
            | if ($name | name_ok | not) then fail("节点名必须是 1-64 个非控制字符") else . end
            | if ($host | host_ok | not) then fail("节点 \($name) 的 host 无效（不支持 IPv6 literal）") else . end
            | if ((keys - node_allowed_keys) | length) != 0 then
                fail("节点 \($name) 包含不支持的字段")
              else . end
            | if (.optional != null and (.optional | type) != "boolean") then
                fail("节点 \($name) 的 optional 必须是布尔值")
              else . end
            | if .port != null and (.port | port_ok | not) then fail("节点 \($name) 的 port 无效") else . end
            | if .type == "mieru" then
                .username as $user
                | .password as $pass
                | if ($user | type) == "string" and ($user | test("^[A-Za-z0-9._~-]{1,64}$")) then . else
                    fail("节点 \($name) 的 mieru username 无效") end
                | if ($pass | type) == "string" and ($pass | test("^[A-Za-z0-9._~-]{8,64}$")) then . else
                    fail("节点 \($name) 的 mieru password 无效") end
                | if (((.port != null) and (.portRange != null)) or ((.port == null) and (.portRange == null))) then
                    fail("节点 \($name) 的 mieru 必须且只能设置 port 或 portRange")
                  else . end
                | if .portRange != null then
                    if (.portRange | type) == "string" and (.portRange | test("^[0-9]+-[0-9]+$")) then
                        (.portRange | capture("^(?<a>[0-9]+)-(?<b>[0-9]+)$")) as $range
                        | if (($range.a | tonumber) >= 1 and ($range.b | tonumber) <= 65535
                            and ($range.a | tonumber) <= ($range.b | tonumber)) then . else
                            fail("节点 \($name) 的 mieru portRange 无效") end
                    else fail("节点 \($name) 的 mieru portRange 无效") end
                  else . end
                | if (.transport // "TCP") != "TCP" then fail("节点 \($name) 的 mieru transport 仅支持 TCP") else . end
                | if (.multiplexing // "MULTIPLEXING_LOW") as $m
                    | (["MULTIPLEXING_OFF","MULTIPLEXING_LOW","MULTIPLEXING_MIDDLE","MULTIPLEXING_HIGH"] | index($m)) == null
                  then fail("节点 \($name) 的 mieru multiplexing 无效") else . end
                | if .trafficPattern != null and ((.trafficPattern | type) != "string"
                    or (.trafficPattern | test("^[A-Za-z0-9+/]+={0,2}$") | not)) then
                    fail("节点 \($name) 的 mieru trafficPattern 无效") else . end
                | if .mtu != null and ((.mtu | type) != "number" or .mtu < 1280 or .mtu > 1500 or .mtu != (.mtu | floor)) then
                    fail("节点 \($name) 的 mieru mtu 必须是 1280-1500 的整数") else . end
                | if .udp != null and (.udp | type) != "boolean" then fail("节点 \($name) 的 udp 必须是布尔值") else . end
                | {
                    type: "mieru",
                    name: .name,
                    host: .host,
                    port: (.port // null),
                    portRange: (.portRange // null),
                    username: .username,
                    password: .password,
                    transport: (.transport // "TCP"),
                    multiplexing: (.multiplexing // "MULTIPLEXING_LOW"),
                    trafficPattern: (.trafficPattern // null),
                    mtu: (.mtu // 1400),
                    udp: (.udp != false),
                    optional: (.optional == true)
                  }
                | with_entries(select(.value != null))
              else
                .security as $security
                | .network as $network
                | if (($security == "reality" and $network == "tcp")
                    or ($security == "tls" and $network == "xhttp")) then . else
                    fail("节点 \($name) 仅支持 vless reality/tcp 或 vless tls/xhttp") end
                | if (.uuid | type) == "string" and (.uuid | test("^[0-9A-Fa-f]{8}(-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}$")) then . else
                    fail("节点 \($name) 的 uuid 无效") end
                | if (.sni | nonempty | not) then fail("节点 \($name) 缺少 sni") else . end
                | if .fp != null and (.fp | nonempty | not) then fail("节点 \($name) 的 fp 无效") else . end
                | if .udp != null and (.udp | type) != "boolean" then fail("节点 \($name) 的 udp 必须是布尔值") else . end
                | if $security == "reality" then
                    if (.pbk | nonempty | not) then fail("节点 \($name) 缺少 pbk") else . end
                    | if (.sid | type) != "string" then fail("节点 \($name) 的 sid 必须是字符串") else . end
                    | if (.sid | test("^([0-9A-Fa-f]{2}){1,8}$") | not) then
                        fail("节点 \($name) 的 sid 必须是 2-16 位偶数长度十六进制") else . end
                    | if .supportX25519Mlkem768 != null and (.supportX25519Mlkem768 | type) != "boolean" then
                        fail("节点 \($name) 的 supportX25519Mlkem768 必须是布尔值") else . end
                    | {
                        type: "vless", name: .name, host: .host, port: (.port // 443),
                        security: "reality", network: "tcp", uuid: .uuid, sni: .sni,
                        pbk: .pbk, sid: .sid, fp: (.fp // "chrome"),
                        supportX25519Mlkem768: (.supportX25519Mlkem768 != false),
                        udp: (.udp != false), optional: (.optional == true)
                      }
                  else
                    if (.path | type) != "string" or (.path | test("^/[^[:space:]]*$") | not) then
                        fail("节点 \($name) 的 xhttp path 必须以 / 开头且不含空白") else . end
                    | if (.mode // "stream-up") as $mode | (["stream-up","packet-up"] | index($mode)) == null then
                        fail("节点 \($name) 的 xhttp mode 无效") else . end
                    | if (.xhttpUplinkHttpMethod // "POST") as $method | (["POST","GET"] | index($method)) == null then
                        fail("节点 \($name) 的 xhttpUplinkHttpMethod 无效") else . end
                    | if .xhttpNoGrpcHeader != null and (.xhttpNoGrpcHeader | type) != "boolean" then
                        fail("节点 \($name) 的 xhttpNoGrpcHeader 必须是布尔值") else . end
                    | {
                        type: "vless", name: .name, host: .host, port: (.port // 443),
                        security: "tls", network: "xhttp", uuid: .uuid, sni: .sni,
                        path: .path, mode: (.mode // "stream-up"), fp: (.fp // "chrome"),
                        xhttpUplinkHttpMethod: (.xhttpUplinkHttpMethod // "POST"),
                        xhttpNoGrpcHeader: (.xhttpNoGrpcHeader == true),
                        udp: (.udp != false), optional: (.optional == true)
                      }
                  end
              end
        )
        | . as $nodes
        | ($nodes | map(.name)) as $names
        | if ($names | length) != ($names | unique | length) then fail("聚合节点存在重名") else . end
        | if any($names[]; (. as $n | ($reserved + $local) | index($n))) then
            fail("聚合节点名不能与本机节点、AUTO 或保留组名冲突")
          else . end
        | $nodes
    ' <<<"$(jq -c '.nodes // []' <<<"${raw}")") || return 1
    # 字段缺失或 null 时不输出该键：无字段的旧状态保持逐字节相同的规范化结果。
    edge=$(jq -r '.cdnEdgeAddress // "" | ascii_downcase' <<<"${raw}") || return 1
    jq -cn --argjson tokens "${tokens}" --argjson nodes "${nodes}" --arg edge "${edge}" \
        '{allowedTokens: $tokens, nodes: $nodes}
         + (if $edge != "" then {cdnEdgeAddress: $edge} else {} end)'
}

# 旧状态/旧环境只提供 Token 字典时，折叠成 nodes 为空的订阅配置。
subscription_config_from_tokens() {
    jq -cn --argjson tokens "${1:-}" \
        '{allowedTokens:$tokens,nodes:[]}'
}

# 校验订阅配置并派生出运行期变量；调用方传入本机节点名，用于拒绝聚合节点重名。
apply_local_aggregation_config() {
    local normalized
    normalized=$(normalize_subscription_config "${1:-}" "${2:-[]}") || return 1
    SUBSCRIPTION_CONFIG=${normalized}
    ALLOWED_TOKENS=$(jq -c '.allowedTokens' <<<"${normalized}") || return 1
    AGGREGATION_NODES=$(jq -c '.nodes' <<<"${normalized}") || return 1
    # 连接地址的运行期派生值：空串等于不启用优选地址（回退节点域名）。
    CF_EDGE_ADDRESS=$(jq -r '.cdnEdgeAddress // ""' <<<"${normalized}") || return 1
    export ALLOWED_TOKENS AGGREGATION_NODES CF_EDGE_ADDRESS
}

# 生效的聚合节点（默认不下发 optional；node=all 时才包含）。
aggregation_included_nodes() {
    jq -c --arg include "${EASY_ALL_INCLUDE_OPTIONAL:-0}" '
        map(select(($include == "1") or (.optional | not)))
    ' <<<"${AGGREGATION_NODES:-[]}"
}

aggregation_node_names() {
    aggregation_included_nodes | jq -c 'map(.name)'
}

aggregation_node_links() {
    local nodes
    nodes=$(aggregation_included_nodes)
    jq -r '
        .[] |
        if .type == "mieru" then
            "mierus://\(.username | @uri):\(.password | @uri)@\(.host)?mtu=\(.mtu)&multiplexing=\(.multiplexing)&port=\(.portRange // (.port | tostring))&profile=default&protocol=TCP"
            + (if .trafficPattern then "&traffic-pattern=\(.trafficPattern | @uri)" else "" end)
            + "#\(.name | @uri)"
        elif .security == "reality" then
            "vless://\(.uuid)@\(.host):\(.port)?encryption=none&security=reality&type=tcp&sni=\(.sni | @uri)&fp=\(.fp | @uri)&pbk=\(.pbk | @uri)&sid=\(.sid | @uri)&flow=xtls-rprx-vision"
            + (if .udp then "&packetEncoding=xudp" else "" end)
            + (if .supportX25519Mlkem768 == false then "&mlkem=0" else "" end)
            + "#\(.name | @uri)"
        else
            . as $node
            # 连接地址用 host（可以是 CDN 优选 IP），HTTP Host 头必须跟 TLS SNI 一致：
            # 回源 Nginx 的 server_name 与 Cloudflare 代理域名都按域名匹配，
            # 把 IP 写进 Host 会直接被边缘拒绝（403 Direct IP Access Denied）。
            | ({uplinkHTTPMethod: $node.xhttpUplinkHttpMethod, noGRPCHeader: $node.xhttpNoGrpcHeader}
               | tojson | @uri) as $extra
            | "vless://\($node.uuid)@\($node.host):\($node.port)?encryption=none&security=tls&type=xhttp&sni=\($node.sni | @uri)&fp=\($node.fp | @uri)&alpn=h2&host=\($node.sni | @uri)&path=\($node.path | @uri)&mode=\($node.mode)&extra=\($extra)" + (if $node.udp then "&packetEncoding=xudp" else "" end) + "#\($node.name | @uri)"
        end
    ' <<<"${nodes}"
}

aggregation_mihomo_nodes() {
    local nodes
    nodes=$(aggregation_included_nodes)
    jq -r '
        .[] |
        if .type == "mieru" then
            "  - name: \(.name | @json)\n    type: mieru\n    server: \(.host | @json)\n"
            + (if .portRange then "    port-range: \(.portRange | @json)\n" else "    port: \(.port)\n" end)
            + "    transport: TCP\n    udp: \(.udp)\n    username: \(.username | @json)\n    password: \(.password | @json)\n    multiplexing: \(.multiplexing)\n"
            + (if .trafficPattern then "    traffic-pattern: \(.trafficPattern | @json)\n" else "" end)
            + "    ip-version: ipv4"
        elif .security == "reality" then
            "  - name: \(.name | @json)\n    type: vless\n    server: \(.host | @json)\n    port: \(.port)\n    uuid: \(.uuid | @json)\n    network: tcp\n    tls: true\n    udp: \(.udp)\n    skip-cert-verify: false\n    flow: xtls-rprx-vision\n    servername: \(.sni | @json)\n    reality-opts:\n      public-key: \(.pbk | @json)\n      short-id: \(.sid | @json)\n"
            + (if .supportX25519Mlkem768 == false then "" else "      support-x25519mlkem768: true\n" end)
            + "    client-fingerprint: \(.fp | @json)\n"
            + (if .udp then "    packet-encoding: xudp\n" else "" end)
            + "    ip-version: ipv4"
        else
            "  - name: \(.name | @json)\n    type: vless\n    server: \(.host | @json)\n    port: \(.port)\n    uuid: \(.uuid | @json)\n    network: xhttp\n    tls: true\n    udp: \(.udp)\n    skip-cert-verify: false\n    servername: \(.sni | @json)\n    client-fingerprint: \(.fp | @json)\n"
            + (if .udp then "    packet-encoding: xudp\n" else "" end)
            + "    ip-version: ipv4\n    alpn:\n      - h2\n    xhttp-opts:\n      host: \(.sni | @json)\n      path: \(.path | @json)\n      mode: \(.mode | @json)\n"
            + (if .xhttpNoGrpcHeader then "      no-grpc-header: true\n" else "" end)
            + "      uplink-http-method: \(.xhttpUplinkHttpMethod | @json)"
        end
    ' <<<"${nodes}"
}

# 明文输入，默认值折叠成一行；多行粘贴以空行结束。
choose_subscription_config() {
    local current=${1:-} default input="" line attempt
    default=${current:-$(jq -cn --arg token "$(generate_secret)" \
        '{allowedTokens:{owner:$token},nodes:[]}')}
    [[ -t 0 ]] || {
        printf '%s' "${default}"
        return 0
    }
    for attempt in 1 2 3 4 5; do
        printf '订阅配置 JSON（allowedTokens=用户 Token，nodes=聚合节点；回车保留当前值，粘贴完成后单独回车结束）:\n%s\n' "${default}" >&2
        input=""
        while IFS= read -r -e -p '> ' line; do
            line=$(strip_terminal_input "${line}")
            if [[ -z "${line}" ]]; then
                # 空行是结束信号；但 JSON 内部的空行也是合法空白，
                # 还没凑成完整 JSON 时不能提前把粘贴内容截断。
                [[ -n "${input}" ]] || break
                jq -e . >/dev/null 2>&1 <<<"${input}" && break
                input+=$'\n'
                continue
            fi
            input+="${input:+$'\n'}${line}"
            jq -e . >/dev/null 2>&1 <<<"${input}" && break
        done
        [[ -n "${input}" ]] || {
            printf '%s' "${default}"
            return 0
        }
        if jq -e . >/dev/null 2>&1 <<<"${input}"; then
            printf '%s' "$(jq -c . <<<"${input}")"
            return 0
        fi
        printf 'JSON 解析失败，请重新输入（输入完整后再用空行结束）\n' >&2
    done
    return 1
}
