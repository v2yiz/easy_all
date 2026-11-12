#!/usr/bin/env bash
# Mihomo 订阅模板一致性测试：规则集必须全部是 MRS，引用不得悬空，DNS 策略不得出现裸集合名。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TEMPLATES=(mihomo.yaml mihomo-classic.yaml mihomo-common.yaml)
NAME_RE='[[:alnum:]_@.!-]+'

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

# 提取 rule-providers 段里的 provider 名（4 空格缩进的键）
provider_names() {
    awk '
        /^rule-providers:[[:space:]]*$/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { exit }
        inside && /^    [^[:space:]]+:[[:space:]]*$/ {
            line = $0
            sub(/^    /, "", line)
            sub(/:[[:space:]]*$/, "", line)
            print line
        }
    ' "$1"
}

# 列出 type: http 但不是 format: mrs 的 provider（行尾注释先剔除，避免 `type: http # remote` 绕过检查）
http_providers_without_mrs() {
    awk '
        /^rule-providers:[[:space:]]*$/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { exit }
        inside { raw = $0; sub(/[[:space:]]+#.*$/, "", raw) }
        inside && raw ~ /^    [^[:space:]]+:[[:space:]]*$/ {
            if (name != "" && kind == "http" && fmt != "mrs") print name
            name = raw
            sub(/^    /, "", name)
            sub(/:[[:space:]]*$/, "", name)
            kind = ""
            fmt = ""
            next
        }
        inside && raw ~ /^[[:space:]]+type:[[:space:]]*http[[:space:]]*$/ { kind = "http" }
        inside && raw ~ /^[[:space:]]+format:[[:space:]]*[^[:space:]]/ {
            fmt = raw
            sub(/^[[:space:]]+format:[[:space:]]*/, "", fmt)
            gsub(/[[:space:]]/, "", fmt)
        }
        END {
            if (name != "" && kind == "http" && fmt != "mrs") print name
        }
    ' "$1"
}

# nameserver-policy 中 rule-set: 首段后面的逗号段也是 rule-set 名（首段前缀会套用到每一段）
policy_rule_set_refs() {
    awk '
        /^[[:space:]]+nameserver-policy:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]{4}[^[:space:]]+:/ { exit }
        inside && /^[[:space:]]*#/ { next }
        inside && /^[[:space:]]*\x27/ {
            line = $0
            sub(/^[[:space:]]*\x27/, "", line)
            sub(/\x27:.*$/, "", line)
            if (tolower(line) !~ /^rule-set:/) next
            sub(/^[Rr][Uu][Ll][Ee]-[Ss][Ee][Tt]:/, "", line)
            total = split(line, parts, ",")
            for (i = 1; i <= total; i++) {
                entry = parts[i]
                gsub(/[[:space:]]/, "", entry)
                if (entry != "") print entry
            }
        }
    ' "$1"
}

# nameserver-policy 键的前缀规则（对应 mihomo config/config.go:parseNameServerPolicy）：
# 键含逗号时只看第一个前缀，并把该前缀套用到逗号分隔的每一段；因此首段必须有前缀或是域名，
# 后续段必须不带前缀（否则会变成 rule-set:rule-set:xxx 这种永不匹配的键）。
policy_prefix_violations() {
    awk '
        /^[[:space:]]+nameserver-policy:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]{4}[^[:space:]]+:/ { exit }
        inside && /^[[:space:]]*#/ { next }
        inside && /^[[:space:]]*\x27/ {
            line = $0
            sub(/^[[:space:]]*\x27/, "", line)
            sub(/\x27:.*$/, "", line)
            total = split(line, parts, ",")
            first = parts[1]
            gsub(/[[:space:]]/, "", first)
            if (first == "") print "empty key"
            else if (first !~ /:/ && first !~ /\./) print "missing prefix: " first
            for (i = 2; i <= total; i++) {
                entry = parts[i]
                gsub(/[[:space:]]/, "", entry)
                if (entry == "") print "empty segment after comma"
                else if (entry ~ /:/) print "duplicated prefix: " entry
            }
        }
    ' "$1"
}

# --- TUN 地址与 Fake-IP 池、telegram-fallback 内联集合的不变量 ------------------

# 点分十进制 IPv4 → 32 位整数；非法输入返回非零。
ipv4_to_int() { # $1=a.b.c.d
    local ip=$1 value=0 octet
    local -a octets=()
    IFS=. read -r -a octets <<<"${ip}"
    ((${#octets[@]} == 4)) || return 1
    for octet in "${octets[@]}"; do
        [[ "${octet}" =~ ^[0-9]{1,3}$ ]] || return 1
        ((10#${octet} <= 255)) || return 1
        value=$((value * 256 + 10#${octet}))
    done
    printf '%s' "${value}"
}

# tun.inet4-address 列表项（去掉行首 "- "、引号与行尾空白）
tun_inet4_addresses() { # $1=模板
    awk '
        /^[[:space:]]*inet4-address:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]*-[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/["\x27]/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            next
        }
        inside { exit }
    ' "$1"
}

# dns.fake-ip-range 的 CIDR（去掉引号与行尾空白）
fake_ip_range_of() { # $1=模板
    awk '
        /^[[:space:]]*fake-ip-range:[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*fake-ip-range:[[:space:]]*/, "", line)
            gsub(/["\x27]/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            exit
        }
    ' "$1"
}

# 输出落在自身 fake-ip 池内的 TUN 地址；无重叠时输出为空。Mihomo 把 fake-ip 池当作自己的
# 地址空间：TUN 地址落在池内会被 DNS 假 IP 覆盖，整机分流随即失效（198.18.0.0/16 是默认池）。
tun_addresses_in_fake_ip_pool() { # $1=模板
    local path=$1 range base prefix base_value address address_value
    local size pool_start pool_end
    range=$(fake_ip_range_of "${path}")
    [[ -n "${range}" ]] || { printf 'missing fake-ip-range\n'; return 0; }
    base=${range%%/*}
    prefix=${range#*/}
    if ! base_value=$(ipv4_to_int "${base}"); then
        printf 'invalid fake-ip-range: %s\n' "${range}"
        return 0
    fi
    if [[ ! "${prefix}" =~ ^[0-9]+$ ]] || ((10#${prefix} > 32)); then
        printf 'invalid fake-ip-range: %s\n' "${range}"
        return 0
    fi
    size=$((1 << (32 - 10#${prefix})))
    pool_start=$((base_value / size * size))
    pool_end=$((pool_start + size - 1))
    while IFS= read -r address; do
        [[ -n "${address}" ]] || continue
        if ! address_value=$(ipv4_to_int "${address%%/*}"); then
            printf 'invalid inet4-address: %s\n' "${address}"
            continue
        fi
        if ((address_value >= pool_start && address_value <= pool_end)); then
            printf 'inet4-address %s in fake-ip-range %s\n' "${address}" "${range}"
        fi
    done < <(tun_inet4_addresses "${path}")
}

# rule-providers 里 telegram-fallback 的 payload 列表项
telegram_fallback_payloads() { # $1=模板
    awk '
        /^[[:space:]]*telegram-fallback:[[:space:]]*$/ { inside = 1; next }
        inside && /^[[:space:]]*payload:[[:space:]]*$/ { payload = 1; next }
        payload && /^[[:space:]]*-[[:space:]]*/ {
            line = $0
            sub(/^[[:space:]]*-[[:space:]]*/, "", line)
            gsub(/["\x27]/, "", line)
            sub(/[[:space:]]+$/, "", line)
            print line
            next
        }
        payload { exit }
    ' "$1"
}

# 输出不是合法 IPv4 / IPv4 CIDR 的 payload 项；全部合法时输出为空。
invalid_telegram_payloads() { # $1=模板
    local entry prefix
    while IFS= read -r entry; do
        [[ -n "${entry}" ]] || continue
        if [[ "${entry}" == */* ]]; then
            prefix=${entry#*/}
            [[ "${prefix}" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] \
                && ipv4_to_int "${entry%%/*}" >/dev/null \
                || printf '%s\n' "${entry}"
        else
            ipv4_to_int "${entry}" >/dev/null || printf '%s\n' "${entry}"
        fi
    done < <(telegram_fallback_payloads "$1")
}

# 提取 sniffer 顶层段（用于检查嗅探协议白名单）
sniffer_block() {
    awk '
        /^sniffer:[[:space:]]*(#.*)?$/ { inside = 1; next }
        inside && /^[^[:space:]#]/ { exit }
        inside { print }
    ' "$1"
}

for template in "${TEMPLATES[@]}"; do
    path="${ROOT_DIR}/templates/${template}"
    [[ -s "${path}" ]] || fail "missing template: ${template}"

    # 1. 仓库自带的模板结构校验
    bash "${ROOT_DIR}/lib/mihomo-template.sh" "${path}" >/dev/null \
        || fail "${template}: validate_mihomo_template failed"

    # 2. 不得再依赖 geodata(.dat)
    if grep -Eq '^[[:space:]]*(geodata-mode|geo-auto-update|geo-update-interval|geodata-loader|geox-url):' "${path}"; then
        fail "${template}: still depends on geodata (.dat)"
    fi
    if grep -Eq '^[[:space:]]*(geoip|geosite):[[:space:]]*.*dat' "${path}"; then
        fail "${template}: still downloads .dat files"
    fi

    # 3. 所有 http 规则集必须是 mrs
    offenders=$(http_providers_without_mrs "${path}")
    [[ -z "${offenders}" ]] || fail "${template}: non-mrs http rule-providers: ${offenders}"

    # 4. 不得残留 geosite:/geoip: 旧式引用
    if grep -Eq '(geosite|geoip):[^ ]' "${path}"; then
        fail "${template}: legacy geosite:/geoip: reference remains"
    fi

    # 5. 规则里只允许内置 GEOIP,LAN
    legacy_rules=$(grep -Eo "(GEOSITE|GEOIP),${NAME_RE}" "${path}" \
        | grep -v '^GEOIP,LAN$' || true)
    [[ -z "${legacy_rules}" ]] \
        || fail "${template}: legacy GEOSITE/GEOIP rules: ${legacy_rules//$'\n'/ }"

    # 6. rule-set 引用必须都能在 rule-providers 里找到定义
    names=$(provider_names "${path}")
    refs=$( { grep -Eo "(rule-set:|RULE-SET,)${NAME_RE}" "${path}" \
        | sed -e 's/^rule-set://' -e 's/^RULE-SET,//'
        policy_rule_set_refs "${path}"
    } | LC_ALL=C sort -u)
    dangling=""
    while IFS= read -r ref; do
        [[ -n "${ref}" ]] || continue
        grep -Fxq -- "${ref}" <<<"${names}" || dangling+=" ${ref}"
    done <<<"${refs}"
    [[ -z "${dangling}" ]] || fail "${template}: dangling rule-set refs:${dangling}"

    # 7. nameserver-policy 前缀规则：首段带前缀（或域名），逗号后的段沿用首段前缀
    bare=$(policy_prefix_violations "${path}")
    [[ -z "${bare}" ]] || fail "${template}: nameserver-policy prefix violation: ${bare//$'\n'/; }"

    # 8. sniffer 只允许嗅探 HTTP/TLS。境外 UDP/443 由规则立即 REJECT 并要求应用回退 TCP；
    #    先嗅探 QUIC 会把这次拒绝拖到握手解析之后（据 Android 实机反馈会让 Google Play 下载长期停在
    #    “等待中”，本仓库没有客户端内核可复现）。先剔除注释行，避免注释里的半角 "QUIC:" 造成假失败。
    sniffer=$(sniffer_block "${path}")
    [[ -n "${sniffer}" ]] || fail "${template}: missing sniffer block"
    sniffer_body=$(printf '%s\n' "${sniffer}" | grep -v '^[[:space:]]*#' || true)
    if grep -qiE '^[[:space:]]*quic[[:space:]]*:' <<<"${sniffer_body}"; then
        fail "${template}: QUIC sniffing must stay disabled (UDP/443 is rejected by rules)"
    fi
    grep -qiE '^[[:space:]]*tls[[:space:]]*:' <<<"${sniffer_body}" \
        || fail "${template}: sniffer must keep TLS sniffing"

    # 9. dns 段必须显式声明纯 IP 的 default-nameserver：Mihomo 用它解析 DoH 服务器自已的域名（doh.pub），
    #    不能靠系统解析（TUN dns-hijack 下会绕回自身），也不能回落到内置列表里的境外源。
    default_ns=$(sed -n 's/^[[:space:]]*default-nameserver:[[:space:]]*//p' "${path}")
    [[ -n "${default_ns}" ]] \
        || fail "${template}: dns 段缺少 default-nameserver（DoH 域名需要纯 IP 引导解析）"
    if printf '%s\n' "${default_ns}" | grep -qE '[a-zA-Z]'; then
        fail "${template}: default-nameserver 必须是纯 IP，不能写域名"
    fi
    printf '%s\n' "${default_ns}" | grep -q '223\.5\.5\.5' \
        || fail "${template}: default-nameserver 应包含国内引导源 223.5.5.5"

    # 10. TUN 的 inet4-address 不得落在本模板的 fake-ip 池内。
    overlaps=$(tun_addresses_in_fake_ip_pool "${path}")
    [[ -z "${overlaps}" ]] \
        || fail "${template}: ${overlaps//$'\n'/; }"

    # 11. telegram-fallback 是 ipcidr 内联集合：payload 每项必须是合法 IP/CIDR，
    #     写错（域名、占位符、坏八位组）在客户端会让整段规则集失效。
    bad_payloads=$(invalid_telegram_payloads "${path}")
    [[ -z "${bad_payloads}" ]] \
        || fail "${template}: invalid telegram-fallback payload: ${bad_payloads//$'\n'/ }"

    printf 'ok - %s\n' "${template}"
done

# 9. IPv4-only 校验：dns 段的 ipv6: false 允许任意统一缩进（2 空格等），但必须是 dns 的
#    直接子键；ipv6: true、缺该键、缩进更深的嵌套键与 IPv6 地址字段仍必须拒绝。
lint_dir=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_mihomo_lint.XXXXXX")
trap 'rm -rf -- "${lint_dir}"' EXIT

reindent_dns_block() {
    awk '
        /^dns:[[:space:]]*$/ { inside = 1; print; next }
        inside && /^[^[:space:]#]/ { inside = 0 }
        inside { sub(/^  /, "") }
        { print }
    ' "$1" >"$2"
}

# 用直接入口校验，MIHOMO_TEMPLATE_TRUSTED=1 跳过内核心校验（本仓库模板已在 CI 里用 pin 的内核校验）。
expect_ipv4_only_rejected() {
    local label=$1 path=$2 output
    if output=$(MIHOMO_TEMPLATE_TRUSTED=1 bash "${ROOT_DIR}/lib/mihomo-template.sh" \
        "${path}" 2>&1); then
        fail "${label}: 应被拒绝但校验通过"
    fi
    [[ "${output}" == *"IPv4-only"* ]] \
        || fail "${label}: 报错应指明 IPv4-only，实际：${output}"
}

baseline="${ROOT_DIR}/templates/mihomo.yaml"
two_space="${lint_dir}/mihomo-dns-2spaces.yaml"
reindent_dns_block "${baseline}" "${two_space}"
MIHOMO_TEMPLATE_TRUSTED=1 bash "${ROOT_DIR}/lib/mihomo-template.sh" "${two_space}" \
    || fail "dns 段用 2 空格缩进的合法模板应通过 IPv4-only 校验"

dns_ipv6_true="${lint_dir}/mihomo-dns-ipv6-true.yaml"
awk '
    /^dns:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^[^[:space:]#]/ { inside = 0 }
    inside && /^[[:space:]]+ipv6:[[:space:]]*false[[:space:]]*$/ { print "    ipv6: true"; next }
    { print }
' "${baseline}" >"${dns_ipv6_true}"
expect_ipv4_only_rejected "dns 段 ipv6: true" "${dns_ipv6_true}"

dns_ipv6_missing="${lint_dir}/mihomo-dns-ipv6-missing.yaml"
awk '
    /^dns:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^[^[:space:]#]/ { inside = 0 }
    inside && /^[[:space:]]+ipv6:[[:space:]]*false[[:space:]]*$/ { next }
    { print }
' "${baseline}" >"${dns_ipv6_missing}"
expect_ipv4_only_rejected "dns 段缺少 ipv6: false" "${dns_ipv6_missing}"

# 缩进更深（不是 dns 直接子键）的 ipv6: false 不得当成合法写法。
dns_ipv6_nested="${lint_dir}/mihomo-dns-ipv6-nested.yaml"
awk '
    /^dns:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^[^[:space:]#]/ { inside = 0 }
    inside && /^[[:space:]]+ipv6:[[:space:]]*false[[:space:]]*$/ { print "        ipv6: false"; next }
    { print }
' "${baseline}" >"${dns_ipv6_nested}"
expect_ipv4_only_rejected "dns 段嵌套层级的 ipv6: false" "${dns_ipv6_nested}"

dns_inet6="${lint_dir}/mihomo-dns-inet6.yaml"
awk '
    /^dns:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^[^[:space:]#]/ { inside = 0 }
    inside && /^[[:space:]]+ipv6:[[:space:]]*false[[:space:]]*$/ { print; print "    inet6-address: '::1'"; next }
    { print }
' "${baseline}" >"${dns_inet6}"
expect_ipv4_only_rejected "dns 段 IPv6 地址字段" "${dns_inet6}"

# 10/11 的判定必须真能报警（否则断言会静默空转）：各用一份故意破坏的副本反证一次。
overlap_probe="${lint_dir}/mihomo-tun-in-fake-ip.yaml"
probe_fake_ip=$(fake_ip_range_of "${baseline}")
probe_fake_ip=${probe_fake_ip%%/*}
awk -v replacement="      - ${probe_fake_ip}/30" '
    /^[[:space:]]*inet4-address:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^[[:space:]]*-[[:space:]]*/ { print replacement; inside = 0; next }
    { print }
' "${baseline}" >"${overlap_probe}"
[[ -n "$(tun_addresses_in_fake_ip_pool "${overlap_probe}")" ]] \
    || fail "TUN 地址落在 fake-ip 池内的判定必须能报警（反证失败）"

payload_probe="${lint_dir}/mihomo-telegram-payload.yaml"
awk -v replacement='          - 300.1.1.1/24' '
    /^[[:space:]]*telegram-fallback:[[:space:]]*$/ { inside = 1; print; next }
    inside && /^[[:space:]]*payload:[[:space:]]*$/ { print; payload = 1; next }
    payload && /^[[:space:]]*-[[:space:]]*/ { print replacement; payload = 0; next }
    { print }
' "${baseline}" >"${payload_probe}"
[[ -n "$(invalid_telegram_payloads "${payload_probe}")" ]] \
    || fail "非法的 telegram-fallback payload 判定必须能报警（反证失败）"

printf 'ok - mihomo templates IPv4-only indentation\n'
printf 'ok - mihomo templates\n'
