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

    printf 'ok - %s\n' "${template}"
done

printf 'ok - mihomo templates\n'
