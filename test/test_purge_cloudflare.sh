#!/usr/bin/env bash
# purge-cloudflare 离线回归测试：不联网、不需要 root，验证分页聚合、删除计划与分页防护。
# 现场故障：cf_list 的 jq 聚合没有 -n，jq 去读 stdin，在交互终端上永久挂起（啥也没清理）。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SCRIPT="${ROOT_DIR}/lib/cloudflare-purge.sh"
TOKEN="fake-token-0123456789abcdef"

TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_purge_test.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

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
        || fail "${label}: missing <${expected}>"
}

mkdir -p "${TMP_DIR}/bin"

# 跳过 root 检查：脚本用 id -u
cat >"${TMP_DIR}/bin/id" <<'EOF'
#!/usr/bin/env bash
printf '0\n'
EOF

# 假的 Cloudflare API。PURGE_TEST_MODE 控制 DNS 分页：
#   normal  ：第 1 页 100 条 + 第 2 页 1 条 easy_all + 1 条用户记录
#   multi   ：第 1/2 页各 100 条 + 第 3 页 5 条（验证恰好整页后仍会探测结束页）
#   loop    ：每页都返回同一份 100 条（验证“接口不分页”检测）
#   endless ：每页 100 条且内容不同（验证页数上限）
#   PURGE_TEST_RULESETS_DENY=1：/rulesets 返回 403（Token 只给了 DNS/证书权限）
cat >"${TMP_DIR}/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
method="GET"
for a in "$@"; do
    case "$a" in
    http*) url=$a ;;
    DELETE | POST | PUT) method=$a ;;
    esac
done
printf '%s %s\n' "${method}" "${url}" >>"${PURGE_TEST_CALLS}"
# 真实 Cloudflare 的成功 DELETE 可能返回 204 + 空体：必须按成功处理。
if [[ "${method}" == "DELETE" && "${PURGE_TEST_EMPTY_DELETE:-0}" == "1" ]]; then
    printf '\n204'
    exit 0
fi
if [[ "${PURGE_TEST_RULESETS_DENY:-0}" == "1" && "${url}" == *"/rulesets"* ]]; then
    printf '{"success":false,"errors":[{"code":10000,"message":"Authentication error"}]}'
    printf '\n403'
    exit 0
fi

# --domain 场景：按 fixture 目录回放 Zone 查询、DNS、ruleset 详情与证书；缺省是空结果。
if [[ -n "${PURGE_TEST_FIXTURE_DIR:-}" ]]; then
    if [[ "${method}" == "DELETE" ]]; then
        printf '{"success":true,"result":{}}\n200'
        exit 0
    fi
    rest=${url#*/client/v4}
    fixture=""
    # Zone 名称查询大小写不敏感（真实 API 同样如此）。
    lookup_name=$(sed -n 's|^/zones?name=\([^&]*\).*|\1|p' <<<"${rest}")
    if [[ -n "${lookup_name}" ]]; then
        lookup_name=$(tr '[:upper:]' '[:lower:]' <<<"${lookup_name}")
        fixture="${PURGE_TEST_FIXTURE_DIR}/zone-${lookup_name}.json"
    else
        path_zone=$(sed -n 's|^/zones/\([^/?]*\)/.*|\1|p' <<<"${rest}")
        if [[ -n "${path_zone}" && "${rest}" == *"/rulesets/"* ]]; then
            rule_id=$(sed -n 's|^/zones/[^/]*/rulesets/\([^/?]*\).*|\1|p' <<<"${rest}")
            fixture="${PURGE_TEST_FIXTURE_DIR}/ruleset-${rule_id}.json"
        elif [[ -n "${path_zone}" && "${rest}" == *"/dns_records"* ]]; then
            fixture="${PURGE_TEST_FIXTURE_DIR}/dns-${path_zone}.json"
        elif [[ -n "${path_zone}" && "${rest}" == *"/rulesets"* ]]; then
            fixture="${PURGE_TEST_FIXTURE_DIR}/rulesets-${path_zone}.json"
        elif [[ "${rest}" == "/certificates"* ]]; then
            query_zone=$(sed -n 's|^/certificates?zone_id=\([^&]*\).*|\1|p' <<<"${rest}")
            fixture="${PURGE_TEST_FIXTURE_DIR}/certs-${query_zone}.json"
        fi
    fi
    if [[ -n "${fixture}" && -f "${fixture}" ]]; then
        cat "${fixture}"
        printf '\n200'
    else
        printf '{"success":true,"result":[]}\n200'
    fi
    exit 0
fi

emit_records() {
    local prefix=$1 n=$2 comment=${3:-easy_all combined} i=1
    printf '{"success":true,"result":['
    while ((i <= n)); do
        ((i == 1)) || printf ','
        printf '{"id":"%s%d","name":"%s%d.tiandi.party","comment":"%s"}' \
            "${prefix}" "${i}" "${prefix}" "${i}" "${comment}"
        i=$((i + 1))
    done
    printf ']}'
}

case "${url}" in
*"/zones?status=active"*)
    printf '{"success":true,"result":[{"id":"z1","name":"tiandi.party","account":{"id":"a1"}}]}'
    ;;
*"/zones/z1/dns_records"*)
    page=$(sed -n 's/.*[?&]page=\([0-9][0-9]*\).*/\1/p' <<<"${url}")
    mode=${PURGE_TEST_MODE:-normal}
    case "${mode}" in
    multi)
        case "${page}" in
        1 | 2) emit_records "m${page}" 100 ;;
        3) emit_records "tail" 5 ;;
        *) emit_records "empty" 0 ;;
        esac
        ;;
    loop)
        emit_records "same" 100
        ;;
    endless)
        counter_file="${PURGE_TEST_COUNTER}"
        n=$(cat "${counter_file}" 2>/dev/null || printf '0')
        n=$((n + 1))
        printf '%s' "${n}" >"${counter_file}"
        emit_records "p${n}" 100
        ;;
    *)
        if [[ "${page}" == "1" ]]; then
            emit_records "first" 100
        elif [[ "${page}" == "2" ]]; then
            printf '{"success":true,"result":[{"id":"tail1","name":"tail.tiandi.party","comment":"easy_all combined"},{"id":"user1","name":"keep.tiandi.party","comment":"mine"}]}'
        else
            emit_records "empty" 0
        fi
        ;;
    esac
    ;;
*"/rulesets"*)
    printf '{"success":true,"result":[]}'
    ;;
*"/certificates"*)
    printf '{"success":true,"result":[]}'
    ;;
*)
    # DELETE：脚本只检查 success
    printf '{"success":true,"result":{}}'
    ;;
esac
printf '\n200'
EOF

chmod +x "${TMP_DIR}/bin/id" "${TMP_DIR}/bin/curl"

# 接管日志固定到 TMP_DIR 下的专用路径（默认不存在）：存量用例不受测试机真实
# /var/log/easy_all/dns-takeover.log 或父进程导出的 override 影响；后置 env 参数仍可覆盖它。
TAKEOVER_LOG="${TMP_DIR}/takeover.log"

run_purge() {
    local calls=$1 out=$2 err=$3
    shift 3
    : >"${calls}"
    PATH="${TMP_DIR}/bin:${PATH}" \
        CLOUDFLARE_API_TOKEN="${TOKEN}" \
        TMPDIR="${TMP_DIR}" \
        PURGE_TEST_CALLS="${calls}" \
        PURGE_TEST_COUNTER="${TMP_DIR}/counter" \
        EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TAKEOVER_LOG}" \
        "$@" bash "${SCRIPT}" --all --yes >"${out}" 2>"${err}" </dev/null
}

# 1) 正常分页：100 + 1 条 easy_all，用户记录不删
CALLS="${TMP_DIR}/calls.log"
OUT="${TMP_DIR}/out"
ERR="${TMP_DIR}/err"
run_purge "${CALLS}" "${OUT}" "${ERR}" env || \
    fail "purge-cloudflare 运行失败：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloudflare: 分页聚合后删除全部 easy_all DNS 记录" "101" "${total}"
assert_equal "purge-cloudflare: 第一页请求一次" "1" \
    "$(grep -c 'dns_records?&per_page=100&page=1' "${CALLS}")"
assert_equal "purge-cloudflare: 满 100 条后继续取第二页" "1" \
    "$(grep -c 'dns_records?&per_page=100&page=2' "${CALLS}")"
assert_equal "purge-cloudflare: 每条 easy_all 记录各发一次 DELETE" "101" \
    "$(grep -c '/zones/z1/dns_records/[a-z]' "${CALLS}")"
assert_equal "purge-cloudflare: 未命中注释的用户记录不删除" "0" \
    "$(grep -c '/zones/z1/dns_records/user1' "${CALLS}")"
assert_contains "purge-cloudflare: 输出包含清理完成" "$(<"${OUT}")" "Cloudflare 清理完成"

# 2) 恰好整页的数据也要能正常结束（先取一页作为结束探测页）
CALLS="${TMP_DIR}/multi-calls.log"
OUT="${TMP_DIR}/multi.out"
ERR="${TMP_DIR}/multi.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env EASY_ALL_PURGE_MAX_PAGES=2 PURGE_TEST_MODE=multi || \
    fail "purge-cloudflare: 恰好整页分页应成功：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloudflare: 页数达到上限但下一页为空时正常结束" "205" "${total}"
assert_equal "purge-cloudflare: 结束探测页被请求" "1" \
    "$(grep -c 'dns_records?&per_page=100&page=3' "${CALLS}")"

# 3) 接口忽略 page：每页相同 -> 立即报错，不无限循环
CALLS="${TMP_DIR}/loop-calls.log"
OUT="${TMP_DIR}/loop.out"
ERR="${TMP_DIR}/loop.err"
if run_purge "${CALLS}" "${OUT}" "${ERR}" env PURGE_TEST_MODE=loop; then
    fail "purge-cloudflare: 接口不分页时应失败退出"
fi
assert_contains "purge-cloudflare: 接口不分页时快速报错" \
    "$(<"${ERR}")$(<"${OUT}")" "疑似未按 page 分页"
assert_equal "purge-cloudflare: 检测到重复页后不再继续翻页" "0" \
    "$(grep -c 'dns_records?&per_page=100&page=3' "${CALLS}")"

# 4) 页数上限：每页内容不同且一直满页 -> 到上限报错，而不是挂起
CALLS="${TMP_DIR}/endless-calls.log"
OUT="${TMP_DIR}/endless.out"
ERR="${TMP_DIR}/endless.err"
if run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env EASY_ALL_PURGE_MAX_PAGES=2 PURGE_TEST_MODE=endless; then
    fail "purge-cloudflare: 超过分页上限时应失败退出"
fi
assert_contains "purge-cloudflare: 超过页数上限时报错" \
    "$(<"${ERR}")$(<"${OUT}")" "扫描超过 2 页"
assert_equal "purge-cloudflare: 到上限后不再继续请求" "0" \
    "$(grep -c 'dns_records?&per_page=100&page=5' "${CALLS}")"

# 5) 状态文件路径遵循 EASY_ALL_STATE_FILE_OVERRIDE（测试隔离与自定义部署）
CALLS="${TMP_DIR}/state-calls.log"
OUT="${TMP_DIR}/state.out"
ERR="${TMP_DIR}/state.err"
STATE_OVERRIDE="${TMP_DIR}/custom-state/state.env"
mkdir -p "$(dirname "${STATE_OVERRIDE}")"
printf 'PROTOCOL="combined"\n' >"${STATE_OVERRIDE}"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env EASY_ALL_STATE_FILE_OVERRIDE="${STATE_OVERRIDE}" \
    || fail "purge-cloudflare: 自定义状态文件路径应成功"
assert_contains "purge-cloudflare: 识别自定义状态文件并告警" \
    "$(<"${OUT}")$(<"${ERR}")" "检测到本机已有 easy_all 安装"

# 6) 成功 DELETE 返回 204 + 空响应体时必须算成功（曾把空体送 jq 判定失败，导致清理中断）
CALLS="${TMP_DIR}/empty-delete-calls.log"
OUT="${TMP_DIR}/empty-delete.out"
ERR="${TMP_DIR}/empty-delete.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env PURGE_TEST_EMPTY_DELETE=1 || \
    fail "purge-cloudflare: 204 空体的成功 DELETE 不得判为失败：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloudflare: 204 空体仍删除全部 easy_all DNS 记录" "101" "${total}"
assert_contains "purge-cloudflare: 204 空体后仍输出清理完成" "$(<"${OUT}")" "Cloudflare 清理完成"


# 7) 只授 DNS/证书权限的 Token 读 /rulesets 会 403：规则只是附带清理对象，
#    不能因此跳过第 1 阶段已收集的 DNS 记录与第 4 阶段的证书清理。
CALLS="${TMP_DIR}/rulesets-deny-calls.log"
OUT="${TMP_DIR}/rulesets-deny.out"
ERR="${TMP_DIR}/rulesets-deny.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env PURGE_TEST_RULESETS_DENY=1 || \
    fail "purge-cloudflare: ruleset 无权限时不得中断清理：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloudflare: ruleset 403 仍删除全部 easy_all DNS 记录" "101" "${total}"
assert_contains "purge-cloudflare: ruleset 403 时告警并继续" \
    "$(<"${OUT}")$(<"${ERR}")" "无法读取 ruleset"
assert_equal "purge-cloudflare: ruleset 403 只告警一次" "1" \
    "$(grep -c '无法读取 ruleset' <<<"$(<"${OUT}")$(<"${ERR}")")"

# 8) --domain 的实际删除集合：A02 规则语法必须完整匹配，A03 只有 Zone 根域才覆盖子域。
#    真实 CLI 入口（--domain ... --yes），curl 只是外部边界。
FIXTURE_ROOT="${TMP_DIR}/fixtures"
write_fixture() { # $1=路径，正文来自 stdin
    mkdir -p "$(dirname "$1")"
    cat >"$1"
}

# Zone example.com（cf.example.com 不是独立 Zone）
write_fixture "${FIXTURE_ROOT}/hosts/zone-example.com.json" <<'EOF'
{"success":true,"result":[{"id":"z1","name":"example.com","account":{"id":"a1"}}]}
EOF
write_fixture "${FIXTURE_ROOT}/hosts/dns-z1.json" <<'EOF'
{"success":true,"result":[
{"id":"dns-cf-example-com","name":"cf.example.com","comment":"easy_all cloudflare"},
{"id":"dns-x-cf-example-com","name":"x.cf.example.com","comment":"easy_all cloudflare"},
{"id":"dns-example-com","name":"example.com","comment":"easy_all cloudflare"},
{"id":"dns-other-example-com","name":"other.example.com","comment":"easy_all cloudflare"},
{"id":"dns-third-example-com","name":"third.example.com","comment":"hand-managed"}
]}
EOF
write_fixture "${FIXTURE_ROOT}/hosts/rulesets-z1.json" <<'EOF'
{"success":true,"result":[{"id":"rs1"}]}
EOF
write_fixture "${FIXTURE_ROOT}/hosts/ruleset-rs1.json" <<'EOF'
{"success":true,"result":{"id":"rs1","name":"easy_all-strict-tls","rules":[
{"id":"r-exact","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"cf.example.com\""},
{"id":"r-ws","ref":"easy_all_cf_strict_tls","expression":"  http.host   eq   \"cf.example.com\"  "},
{"id":"r-upper","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"CF.Example.COM\""},
{"id":"r-desc","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"x.cf.example.com\""},
{"id":"r-other","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"other.example.com\""},
{"id":"r-root","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"example.com\""},
{"id":"r-or","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"cf.example.com\" or http.host eq \"x.cf.example.com\""},
{"id":"r-or-true","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"cf.example.com\" or true"},
{"id":"r-not","ref":"easy_all_cf_strict_tls","expression":"not http.host eq \"cf.example.com\""},
{"id":"r-paren","ref":"easy_all_cf_strict_tls","expression":"(http.host eq \"cf.example.com\")"},
{"id":"r-and","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"cf.example.com\" and http.host eq \"example.com\""},
{"id":"r-tail","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"cf.example.com\" http.host eq \"x.cf.example.com\""},
{"id":"r-noref","ref":"attacker","expression":"http.host eq \"cf.example.com\""}
]}}
EOF
write_fixture "${FIXTURE_ROOT}/hosts/certs-z1.json" <<'EOF'
{"success":true,"result":[
{"id":"cert-cf","hostnames":["cf.example.com"]},
{"id":"cert-mixed","hostnames":["cf.example.com","x.cf.example.com"]},
{"id":"cert-wild","hostnames":["*.cf.example.com"]},
{"id":"cert-zone","hostnames":["example.com"]}
]}
EOF

# cf.example.com 是独立 Zone：输入等于该 Zone 名时才覆盖其后代，且只匹配点分隔后缀。
write_fixture "${FIXTURE_ROOT}/nested/zone-cf.example.com.json" <<'EOF'
{"success":true,"result":[{"id":"z2","name":"cf.example.com","account":{"id":"a2"}}]}
EOF
write_fixture "${FIXTURE_ROOT}/nested/dns-z2.json" <<'EOF'
{"success":true,"result":[
{"id":"dns-a-cf-example-com","name":"a.cf.example.com","comment":"easy_all cloudflare"},
{"id":"dns-xcf-example-com","name":"xcf.example.com","comment":"easy_all cloudflare"}
]}
EOF
write_fixture "${FIXTURE_ROOT}/nested/rulesets-z2.json" <<'EOF'
{"success":true,"result":[{"id":"rs2"}]}
EOF
write_fixture "${FIXTURE_ROOT}/nested/ruleset-rs2.json" <<'EOF'
{"success":true,"result":{"id":"rs2","name":"easy_all-strict-tls","rules":[
{"id":"r-acf","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"a.cf.example.com\""},
{"id":"r-xcf","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"xcf.example.com\""}
]}}
EOF

# 多输入 + 多 Zone：嵌套 Zone 与另一个根 Zone 同时处理。
cp -R "${FIXTURE_ROOT}/nested" "${FIXTURE_ROOT}/multi"
write_fixture "${FIXTURE_ROOT}/multi/zone-example.net.json" <<'EOF'
{"success":true,"result":[{"id":"z4","name":"example.net","account":{"id":"a4"}}]}
EOF
write_fixture "${FIXTURE_ROOT}/multi/dns-z4.json" <<'EOF'
{"success":true,"result":[
{"id":"dns-sub-example-net","name":"sub.example.net","comment":"easy_all cloudflare"},
{"id":"dns-other-example-net","name":"other.example.net","comment":"easy_all cloudflare"}
]}
EOF
write_fixture "${FIXTURE_ROOT}/multi/rulesets-z4.json" <<'EOF'
{"success":true,"result":[{"id":"rs4"}]}
EOF
write_fixture "${FIXTURE_ROOT}/multi/ruleset-rs4.json" <<'EOF'
{"success":true,"result":{"id":"rs4","name":"easy_all-strict-tls","rules":[
{"id":"r-sub","ref":"easy_all_cf_strict_tls","expression":"http.host eq \"sub.example.net\""}
]}}
EOF

# 多 Zone 警告：前面的 Zone 恰好没有 easy_all 记录时不得误报；全部为空时只提示一次。
cp -R "${FIXTURE_ROOT}/nested" "${FIXTURE_ROOT}/warn-mixed"
write_fixture "${FIXTURE_ROOT}/warn-mixed/dns-z2.json" <<'EOF'
{"success":true,"result":[{"id":"user-keep","name":"keep.cf.example.com","comment":"mine"}]}
EOF
write_fixture "${FIXTURE_ROOT}/warn-mixed/zone-example.net.json" <<'EOF'
{"success":true,"result":[{"id":"z4","name":"example.net","account":{"id":"a4"}}]}
EOF
write_fixture "${FIXTURE_ROOT}/warn-mixed/dns-z4.json" <<'EOF'
{"success":true,"result":[{"id":"dns-sub-example-net","name":"sub.example.net","comment":"easy_all cloudflare"}]}
EOF

cp -R "${FIXTURE_ROOT}/nested" "${FIXTURE_ROOT}/warn-empty"
write_fixture "${FIXTURE_ROOT}/warn-empty/dns-z2.json" <<'EOF'
{"success":true,"result":[{"id":"user-keep","name":"keep.cf.example.com","comment":"mine"}]}
EOF
write_fixture "${FIXTURE_ROOT}/warn-empty/zone-example.net.json" <<'EOF'
{"success":true,"result":[{"id":"z4","name":"example.net","account":{"id":"a4"}}]}
EOF
write_fixture "${FIXTURE_ROOT}/warn-empty/dns-z4.json" <<'EOF'
{"success":true,"result":[{"id":"user-keep-2","name":"keep.example.net","comment":"mine"}]}
EOF

# 集合语法：表达式里根本没有 `http.host eq`，旧提取器会因管道失败中止整个清理。
write_fixture "${FIXTURE_ROOT}/setsyntax/zone-example.com.json" <<'EOF'
{"success":true,"result":[{"id":"z1","name":"example.com","account":{"id":"a1"}}]}
EOF
write_fixture "${FIXTURE_ROOT}/setsyntax/dns-z1.json" <<'EOF'
{"success":true,"result":[{"id":"dns-cf-example-com","name":"cf.example.com","comment":"easy_all cloudflare"}]}
EOF
write_fixture "${FIXTURE_ROOT}/setsyntax/rulesets-z1.json" <<'EOF'
{"success":true,"result":[{"id":"rs1"}]}
EOF
write_fixture "${FIXTURE_ROOT}/setsyntax/ruleset-rs1.json" <<'EOF'
{"success":true,"result":{"id":"rs1","name":"easy_all-strict-tls","rules":[
{"id":"r-set","ref":"easy_all_cf_strict_tls","expression":"http.host in {\"cf.example.com\" \"x.cf.example.com\"}"}
]}}
EOF

# 同名重复 Zone：Token 可见两个 active Zone 同名时不能盲取第一个（大小写不敏感匹配后必须唯一）。
write_fixture "${FIXTURE_ROOT}/dupzone/zone-example.com.json" <<'EOF'
{"success":true,"result":[{"id":"z-dup-a","name":"example.com","account":{"id":"a1"}},{"id":"z-dup-b","name":"EXAMPLE.COM","account":{"id":"a2"}}]}
EOF

run_purge_domain() { # $1=calls $2=out $3=err $4=fixture $5=--domain 值
    : >"$1"
    PATH="${TMP_DIR}/bin:${PATH}" \
        CLOUDFLARE_API_TOKEN="${TOKEN}" \
        TMPDIR="${TMP_DIR}" \
        PURGE_TEST_CALLS="$1" \
        PURGE_TEST_FIXTURE_DIR="$4" \
        EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TAKEOVER_LOG}" \
        bash "${SCRIPT}" --domain "$5" --yes >"$2" 2>"$3" </dev/null
}

deleted_paths() { # $1=calls，输出按字典序排序的 DELETE 路径
    sed -n 's|^DELETE https://api.cloudflare.com/client/v4||p' "$1" | sort
}

# 8.1 完整主机名：只删该主机本身，后代 DNS/规则/证书全部保留。
CALLS="${TMP_DIR}/domain-host-calls.log"
OUT="${TMP_DIR}/domain-host.out"
ERR="${TMP_DIR}/domain-host.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" cf.example.com \
    || fail "purge-cloudflare: --domain 完整主机名应成功：$(tail -n 3 "${ERR}")"
expected_host=$(
    cat <<'EOF'
/certificates/cert-cf
/zones/z1/dns_records/dns-cf-example-com
/zones/z1/rulesets/rs1/rules/r-exact
/zones/z1/rulesets/rs1/rules/r-upper
/zones/z1/rulesets/rs1/rules/r-ws
EOF
)
assert_equal "purge-cloudflare: --domain 完整主机名的删除集合" "${expected_host}" \
    "$(deleted_paths "${CALLS}")"
assert_equal "purge-cloudflare: 仍有规则的 ruleset 不删除" "0" \
    "$(grep -cE 'DELETE .*/rulesets/rs[0-9]+$' "${CALLS}" || true)"
assert_equal "purge-cloudflare: 后代 DNS、后代 SAN 与 wildcard 证书保留" "0" \
    "$(grep -cE 'dns-x-cf-example-com|cert-mixed|cert-wild' "${CALLS}" || true)"

# 8.2 Zone 根域：带 easy_all 注释的后代记录进入范围，第三方记录与复杂规则仍保留。
CALLS="${TMP_DIR}/domain-zone-calls.log"
OUT="${TMP_DIR}/domain-zone.out"
ERR="${TMP_DIR}/domain-zone.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" example.com \
    || fail "purge-cloudflare: --domain Zone 根域应成功：$(tail -n 3 "${ERR}")"
expected_zone=$(
    cat <<'EOF'
/certificates/cert-cf
/certificates/cert-mixed
/certificates/cert-zone
/zones/z1/dns_records/dns-cf-example-com
/zones/z1/dns_records/dns-example-com
/zones/z1/dns_records/dns-other-example-com
/zones/z1/dns_records/dns-x-cf-example-com
/zones/z1/rulesets/rs1/rules/r-desc
/zones/z1/rulesets/rs1/rules/r-exact
/zones/z1/rulesets/rs1/rules/r-other
/zones/z1/rulesets/rs1/rules/r-root
/zones/z1/rulesets/rs1/rules/r-upper
/zones/z1/rulesets/rs1/rules/r-ws
EOF
)
assert_equal "purge-cloudflare: --domain Zone 根域的删除集合" "${expected_zone}" \
    "$(deleted_paths "${CALLS}")"
assert_equal "purge-cloudflare: 第三方 DNS 记录与未标记证书保留" "0" \
    "$(grep -cE 'dns-third-example-com|cert-wild' "${CALLS}" || true)"

# 8.3 输入大小写不影响判定：Zone 查询与主机比较都按小写处理。
CALLS="${TMP_DIR}/domain-upper-calls.log"
OUT="${TMP_DIR}/domain-upper.out"
ERR="${TMP_DIR}/domain-upper.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" 'CF.Example.COM' \
    || fail "purge-cloudflare: 大写域名输入应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloudflare: 大写输入与小写输入删除集合一致" "${expected_host}" \
    "$(deleted_paths "${CALLS}")"

# 8.4 嵌套真实 Zone：输入等于 Zone 名才覆盖后代，且不越界到 xcf.example.com。
CALLS="${TMP_DIR}/domain-nested-calls.log"
OUT="${TMP_DIR}/domain-nested.out"
ERR="${TMP_DIR}/domain-nested.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/nested" cf.example.com \
    || fail "purge-cloudflare: 嵌套 Zone 输入应成功：$(tail -n 3 "${ERR}")"
expected_nested=$(
    cat <<'EOF'
/zones/z2/dns_records/dns-a-cf-example-com
/zones/z2/rulesets/rs2/rules/r-acf
EOF
)
assert_equal "purge-cloudflare: 嵌套 Zone 根域覆盖后代但只匹配点分隔后缀" "${expected_nested}" \
    "$(deleted_paths "${CALLS}")"

# 8.5 多输入多 Zone：每个输入按各自 Zone 的范围独立判定。
CALLS="${TMP_DIR}/domain-multi-calls.log"
OUT="${TMP_DIR}/domain-multi.out"
ERR="${TMP_DIR}/domain-multi.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/multi" 'cf.example.com,example.net' \
    || fail "purge-cloudflare: 多输入多 Zone 应成功：$(tail -n 3 "${ERR}")"
expected_multi=$(
    cat <<'EOF'
/zones/z2/dns_records/dns-a-cf-example-com
/zones/z2/rulesets/rs2/rules/r-acf
/zones/z4/dns_records/dns-other-example-net
/zones/z4/dns_records/dns-sub-example-net
/zones/z4/rulesets/rs4/rules/r-sub
EOF
)
assert_equal "purge-cloudflare: 多输入多 Zone 的删除集合" "${expected_multi}" \
    "$(deleted_paths "${CALLS}")"

# 8.6 集合语法：既不产生规则 DELETE，也不能让整个清理中断（DNS/证书仍照常处理）。
CALLS="${TMP_DIR}/domain-set-calls.log"
OUT="${TMP_DIR}/domain-set.out"
ERR="${TMP_DIR}/domain-set.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/setsyntax" cf.example.com \
    || fail "purge-cloudflare: 集合表达式不得中断清理：$(tail -n 3 "${ERR}")"
expected_set=$(
    cat <<'EOF'
/zones/z1/dns_records/dns-cf-example-com
EOF
)
assert_equal "purge-cloudflare: 集合表达式保留规则但继续清理 DNS" "${expected_set}" \
    "$(deleted_paths "${CALLS}")"

# 8.7 多 Zone 警告：只有全部 Zone 都没收集到 easy_all DNS 记录时才提示一次。
warn_count() { grep -c '没有匹配到 easy_all DNS 记录' "$1" || true; }
CALLS="${TMP_DIR}/warn-mixed-calls.log"
OUT="${TMP_DIR}/warn-mixed.out"
ERR="${TMP_DIR}/warn-mixed.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/warn-mixed" \
    'cf.example.com,sub.example.net' \
    || fail "purge-cloudflare: 多 Zone 警告用例应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloudflare: 前面的 Zone 无记录时不得误报警告" "0" "$(warn_count "${OUT}")"
assert_equal "purge-cloudflare: 仍有 easy_all 记录时照常删除" "1" \
    "$(grep -c 'dns_records/dns-sub-example-net' "${CALLS}")"

CALLS="${TMP_DIR}/warn-empty-calls.log"
OUT="${TMP_DIR}/warn-empty.out"
ERR="${TMP_DIR}/warn-empty.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/warn-empty" \
    'cf.example.com,sub.example.net' \
    || fail "purge-cloudflare: 全部为空的多 Zone 用例应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloudflare: 全部 Zone 无记录时恰好提示一次" "1" "$(warn_count "${OUT}")"

# 8.8 --all 语义不变：不按域名范围过滤，也就没有这条 --domain 专属提示。
CALLS="${TMP_DIR}/warn-all-calls.log"
OUT="${TMP_DIR}/warn-all.out"
ERR="${TMP_DIR}/warn-all.err"
: >"${CALLS}"
PATH="${TMP_DIR}/bin:${PATH}" \
    CLOUDFLARE_API_TOKEN="${TOKEN}" \
    TMPDIR="${TMP_DIR}" \
    PURGE_TEST_CALLS="${CALLS}" \
    PURGE_TEST_FIXTURE_DIR="${FIXTURE_ROOT}/warn-empty" \
    bash "${SCRIPT}" --all --yes >"${OUT}" 2>"${ERR}" </dev/null \
    || fail "purge-cloudflare: --all 应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloudflare: --all 不输出 --domain 专属提示" "0" "$(warn_count "${OUT}")"

# 8.9 Token 可见多个同名 active Zone：必须显式报错退出，不得盲取第一个，也不得发出任何清理请求。
CALLS="${TMP_DIR}/dup-calls.log"
OUT="${TMP_DIR}/dup.out"
ERR="${TMP_DIR}/dup.err"
if run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/dupzone" example.com; then
    fail "purge-cloudflare: 同名重复 Zone 必须报错退出，而不是猜一个"
fi
assert_contains "purge-cloudflare: 同名重复 Zone 报错点名 Token 可见多个同名 active Zone" \
    "$(<"${ERR}")$(<"${OUT}")" "Token 可见多个同名 active Zone"
assert_equal "purge-cloudflare: 同名重复 Zone 不发起任何 DELETE/PUT/POST 清理请求" "0" \
    "$(grep -cE '^(DELETE|PUT|POST) ' "${CALLS}" || true)"

# 9) Token 会写进 curl 的 header 文件：换行可注入额外请求头，必须按字符集拒绝
#（修复前只校验长度≥.20，含换行的 Token 会直接被当成合法值使用）。
INVALID_TOKEN=$'AAAAAAAAAAAAAAAAAAAA\nX-Injected: 1'
CALLS="${TMP_DIR}/invalid-token-calls.log"
OUT="${TMP_DIR}/invalid-token.out"
ERR="${TMP_DIR}/invalid-token.err"
: >"${CALLS}"
if PATH="${TMP_DIR}/bin:${PATH}" \
    CLOUDFLARE_API_TOKEN="${INVALID_TOKEN}" \
    TMPDIR="${TMP_DIR}" \
    PURGE_TEST_CALLS="${CALLS}" \
    PURGE_TEST_COUNTER="${TMP_DIR}/counter" \
    bash "${SCRIPT}" --all --yes >"${OUT}" 2>"${ERR}" </dev/null; then
    fail "purge-cloudflare: 含换行的 Token 必须被拒绝"
fi
assert_contains "purge-cloudflare: 含换行的 Token 报格式无效" \
    "$(<"${ERR}")$(<"${OUT}")" "格式无效"
assert_equal "purge-cloudflare: 格式无效的 Token 不发起 API 请求" "0" \
    "$(grep -c . "${CALLS}" || true)"

# 10) 接管而来的 DNS 记录必须保留：--all 不得删除命中接管日志的记录。
#     期望 100 来自既有 fixture：第 1 页 100 条 easy_all + 第 2 页 tail1(user) 与 user1，
#     共 101 条 easy_all，其中 tail.tiandi.party 已被接管 → 保留 1 条，其余 100 条照删。
write_takeover_log() { # $1=host，正文用 jq 生成单行 JSON（与被测代码写入的格式一致）
    jq -cn --arg host "$1" \
        '{ts:"2026-11-10T00:00:00Z",host:$host,old_comment:"",old_content:"203.0.113.9",old_proxied:"false",old_ttl:"300"}' \
        >"${TAKEOVER_LOG}"
}

write_takeover_log tail.tiandi.party
CALLS="${TMP_DIR}/takeover-all-calls.log"
OUT="${TMP_DIR}/takeover-all.out"
ERR="${TMP_DIR}/takeover-all.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" || \
    fail "purge-cloudflare: 存在接管记录时 --all 应成功：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloudflare: --all 保留接管而来的 DNS 后仍删除其余 100 条" "100" "${total}"
assert_equal "purge-cloudflare: --all 不发送接管记录的 DNS DELETE" "0" \
    "$(grep -c '/zones/z1/dns_records/tail1' "${CALLS}")"
assert_equal "purge-cloudflare: --all 其余 easy_all DNS 记录各发一次 DELETE" "100" \
    "$(grep -c '/zones/z1/dns_records/[a-z]' "${CALLS}")"
assert_contains "purge-cloudflare: --all 说明该记录来自强制接管" \
    "$(<"${OUT}")$(<"${ERR}")" "DNS 记录来自强制接管"
assert_contains "purge-cloudflare: --all 给出接管日志路径" \
    "$(<"${OUT}")$(<"${ERR}")" "${TAKEOVER_LOG}"
rm -f "${TAKEOVER_LOG}"

# 11) --domain 根域变体：接管日志只让 DNS 退出删除计划，同一主机的规则与 Origin CA
#     仍按原口径删除（allowed-names 先于接管判定写入）。期望集合即 8.2 的 expected_zone
#     去掉 dns-cf-example-com，只少这一条。
write_takeover_log cf.example.com
CALLS="${TMP_DIR}/takeover-domain-calls.log"
OUT="${TMP_DIR}/takeover-domain.out"
ERR="${TMP_DIR}/takeover-domain.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" example.com \
    || fail "purge-cloudflare: 存在接管记录时 --domain 根域应成功：$(tail -n 3 "${ERR}")"
expected_takeover=$(
    cat <<'EOF'
/certificates/cert-cf
/certificates/cert-mixed
/certificates/cert-zone
/zones/z1/dns_records/dns-example-com
/zones/z1/dns_records/dns-other-example-com
/zones/z1/dns_records/dns-x-cf-example-com
/zones/z1/rulesets/rs1/rules/r-desc
/zones/z1/rulesets/rs1/rules/r-exact
/zones/z1/rulesets/rs1/rules/r-other
/zones/z1/rulesets/rs1/rules/r-root
/zones/z1/rulesets/rs1/rules/r-upper
/zones/z1/rulesets/rs1/rules/r-ws
EOF
)
assert_equal "purge-cloudflare: --domain 根域的删除集合只少掉接管的 DNS 记录" \
    "${expected_takeover}" "$(deleted_paths "${CALLS}")"
assert_contains "purge-cloudflare: 接管主机的 Origin CA 仍被删除" \
    "$(deleted_paths "${CALLS}")" "/certificates/cert-cf"
assert_contains "purge-cloudflare: 接管主机的规则仍被删除" \
    "$(deleted_paths "${CALLS}")" "/zones/z1/rulesets/rs1/rules/r-exact"
rm -f "${TAKEOVER_LOG}"

printf 'ok - purge-cloudflare\n'
