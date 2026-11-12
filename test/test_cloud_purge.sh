#!/usr/bin/env bash
# purge-cloud 离线回归测试：不联网、不需要 root，验证分页聚合、删除计划与分页防护。
# 现场故障：cf_list 的 jq 聚合没有 -n，jq 去读 stdin，在交互终端上永久挂起（啥也没清理）。
set -Eeuo pipefail

# A31 阶段一：断言计数器，防止整个文件静默空跑（fixture 出错时最容易全绿）。
TESTS_ASSERTED=0

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
SCRIPT="${ROOT_DIR}/lib/cloud-purge.sh"
TOKEN="fake-token-0123456789abcdef"

# 统一剔除继承的宿主 AWS 环境：三个 runner 与全部内联调用点都用同一组 env -u 前缀。
AWS_ENV_UNSET=(
    env -u AWS_ACCESS_KEY_ID -u AWS_SECRET_ACCESS_KEY -u AWS_SESSION_TOKEN
    -u AWS_PROFILE -u AWS_DEFAULT_REGION -u AWS_REGION
    -u AWS_CONFIG_FILE -u AWS_SHARED_CREDENTIALS_FILE
)

TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_purge_test.XXXXXX")
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_equal() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] \
        || fail "${label}: expected <${expected}> but got <${actual}>"
}

assert_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
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
# B3：前 N 次请求回放 429（限流），之后放行；计数落在文件里跨进程累计。
if [[ -n "${PURGE_TEST_429_TIMES:-}" ]]; then
    n=$(cat "${PURGE_TEST_429_STATE:-/tmp/easy_all_429_state}" 2>/dev/null || printf 0)
    n=$((n + 1))
    printf '%s' "${n}" >"${PURGE_TEST_429_STATE:-/tmp/easy_all_429_state}"
    if ((n <= PURGE_TEST_429_TIMES)); then
        printf '{"success":false,"errors":[{"code":10000,"message":"rate limited"}]}'
        printf '\n429'
        exit 0
    fi
fi
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
    # --all 场景：把 fixture 目录里所有 zone-*.json 的 result 汇总成一个 Zone 列表。
    if [[ "${rest}" == "/zones?status=active"* ]]; then
        zones='[]'
        for zone_file in "${PURGE_TEST_FIXTURE_DIR}"/zone-*.json; do
            [[ -f "${zone_file}" ]] || continue
            zones=$(jq -c --argjson acc "${zones}" '$acc + (.result // [])' "${zone_file}")
        done
        printf '{"success":true,"result":%s}\n200' "${zones}"
        exit 0
    fi
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

# AWS 哨兵：在任何被测调用之前装好。任何用例意外触达 aws（宿主装有 aws CLI 且凭据穿透）
# 都会撞到这里留下日志并失败，绝不会落到系统 PATH 里的真实 aws。第 11 节会用功能版假 aws 覆盖它。
cat >"${TMP_DIR}/bin/aws" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${TMP_DIR}/aws-sentinel.log"
printf '测试不得调用 aws：%s\n' "\$*" >&2
exit 254
EOF

chmod +x "${TMP_DIR}/bin/id" "${TMP_DIR}/bin/curl" "${TMP_DIR}/bin/aws"

# 接管日志固定到 TMP_DIR 下的专用路径（默认不存在）：存量用例不受测试机真实
# /var/log/easy_all/dns-takeover.log 或父进程导出的 override 影响；后置 env 参数仍可覆盖它。
TAKEOVER_LOG="${TMP_DIR}/takeover.log"

run_purge() {
    local calls=$1 out=$2 err=$3
    shift 3
    : >"${calls}"
    : >"${TMP_DIR}/aws-sentinel.log"
    : >"${TMP_DIR}/aws-calls.log"
    PATH="${TMP_DIR}/bin:${PATH}" \
        CLOUDFLARE_API_TOKEN="${TOKEN}" \
        TMPDIR="${TMP_DIR}" \
        PURGE_TEST_CALLS="${calls}" \
        PURGE_TEST_COUNTER="${TMP_DIR}/counter" \
        PURGE_TEST_AWS_CALLS="${TMP_DIR}/aws-calls.log" \
        EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TAKEOVER_LOG}" \
        "${AWS_ENV_UNSET[@]}" "$@" bash "${SCRIPT}" --all --yes >"${out}" 2>"${err}" </dev/null
}

# 门禁负测：不加 --yes，stdin 固定为非终端；$4 为空表示不提供 Token，其余为脚本参数。
run_purge_gate() { # $1=calls $2=out $3=err $4=token；shift 4
    local calls=$1 out=$2 err=$3 token=$4
    local -a cmd=(
        env -u CLOUDFLARE_API_TOKEN
        "${AWS_ENV_UNSET[@]}"
        PATH="${TMP_DIR}/bin:${PATH}"
        TMPDIR="${TMP_DIR}"
        PURGE_TEST_CALLS="${calls}"
        PURGE_TEST_COUNTER="${TMP_DIR}/counter"
        PURGE_TEST_AWS_CALLS="${TMP_DIR}/aws-calls.log"
        EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TAKEOVER_LOG}"
    )
    shift 4
    [[ -z "${token}" ]] || cmd+=(CLOUDFLARE_API_TOKEN="${token}")
    cmd+=(bash "${SCRIPT}" "$@")
    : >"${calls}"
    : >"${TMP_DIR}/aws-sentinel.log"
    : >"${TMP_DIR}/aws-calls.log"
    "${cmd[@]}" >"${out}" 2>"${err}" </dev/null
}

# 0) 破坏性门禁：非交互终端下缺少范围、Token 或 --yes 都必须在任何删除前拒绝。
CALLS="${TMP_DIR}/gate-scope-calls.log"
OUT="${TMP_DIR}/gate-scope.out"
ERR="${TMP_DIR}/gate-scope.err"
if run_purge_gate "${CALLS}" "${OUT}" "${ERR}" ""; then
    fail "purge-cloud: 无范围且非交互必须拒绝"
fi
assert_contains "purge-cloud: 无范围时输出用法" "$(<"${ERR}")" "用法: easy_all purge-cloud"
assert_equal "purge-cloud: 无范围时不发起 API 请求" "0" \
    "$(grep -c . "${CALLS}" || true)"

CALLS="${TMP_DIR}/gate-token-calls.log"
OUT="${TMP_DIR}/gate-token.out"
ERR="${TMP_DIR}/gate-token.err"
if run_purge_gate "${CALLS}" "${OUT}" "${ERR}" "" --all; then
    fail "purge-cloud: 缺少 Token 且非交互必须拒绝"
fi
assert_contains "purge-cloud: 缺少 Token 时说明非交互要求" "$(<"${ERR}")" \
    "非交互模式必须设置 CLOUDFLARE_API_TOKEN"
assert_equal "purge-cloud: 缺少 Token 时不发起 API 请求" "0" \
    "$(grep -c . "${CALLS}" || true)"

CALLS="${TMP_DIR}/gate-confirm-calls.log"
OUT="${TMP_DIR}/gate-confirm.out"
ERR="${TMP_DIR}/gate-confirm.err"
if run_purge_gate "${CALLS}" "${OUT}" "${ERR}" "${TOKEN}" --all; then
    fail "purge-cloud: 非交互且缺少 --yes 必须拒绝"
fi
assert_contains "purge-cloud: 缺少 --yes 时说明非交互要求" "$(<"${ERR}")" \
    "非交互模式必须加 --yes 才能删除"
assert_equal "purge-cloud: 缺少 --yes 时不发起 DELETE" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"

# 1) 正常分页：100 + 1 条 easy_all，用户记录不删
CALLS="${TMP_DIR}/calls.log"
OUT="${TMP_DIR}/out"
ERR="${TMP_DIR}/err"
run_purge "${CALLS}" "${OUT}" "${ERR}" env || \
    fail "purge-cloud 运行失败：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloud: 分页聚合后删除全部 easy_all DNS 记录" "101" "${total}"
assert_equal "purge-cloud: 第一页请求一次" "1" \
    "$(grep -c 'dns_records?&per_page=100&page=1' "${CALLS}")"
assert_equal "purge-cloud: 满 100 条后继续取第二页" "1" \
    "$(grep -c 'dns_records?&per_page=100&page=2' "${CALLS}")"
assert_equal "purge-cloud: 每条 easy_all 记录各发一次 DELETE" "101" \
    "$(grep -c '/zones/z1/dns_records/[a-z]' "${CALLS}")"
assert_equal "purge-cloud: 未命中注释的用户记录不删除" "0" \
    "$(grep -c '/zones/z1/dns_records/user1' "${CALLS}")"
assert_contains "purge-cloud: 输出包含清理完成" "$(<"${OUT}")" "Cloudflare 清理完成"

# 2) 恰好整页的数据也要能正常结束（先取一页作为结束探测页）
CALLS="${TMP_DIR}/multi-calls.log"
OUT="${TMP_DIR}/multi.out"
ERR="${TMP_DIR}/multi.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env EASY_ALL_PURGE_MAX_PAGES=2 PURGE_TEST_MODE=multi || \
    fail "purge-cloud: 恰好整页分页应成功：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloud: 页数达到上限但下一页为空时正常结束" "205" "${total}"
assert_equal "purge-cloud: 结束探测页被请求" "1" \
    "$(grep -c 'dns_records?&per_page=100&page=3' "${CALLS}")"

# 3) 接口忽略 page：每页相同 -> 立即报错，不无限循环
CALLS="${TMP_DIR}/loop-calls.log"
OUT="${TMP_DIR}/loop.out"
ERR="${TMP_DIR}/loop.err"
if run_purge "${CALLS}" "${OUT}" "${ERR}" env PURGE_TEST_MODE=loop; then
    fail "purge-cloud: 接口不分页时应失败退出"
fi
assert_contains "purge-cloud: 接口不分页时快速报错" \
    "$(<"${ERR}")$(<"${OUT}")" "疑似未按 page 分页"
assert_equal "purge-cloud: 检测到重复页后不再继续翻页" "0" \
    "$(grep -c 'dns_records?&per_page=100&page=3' "${CALLS}")"

# 4) 页数上限：每页内容不同且一直满页 -> 到上限报错，而不是挂起
CALLS="${TMP_DIR}/endless-calls.log"
OUT="${TMP_DIR}/endless.out"
ERR="${TMP_DIR}/endless.err"
if run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env EASY_ALL_PURGE_MAX_PAGES=2 PURGE_TEST_MODE=endless; then
    fail "purge-cloud: 超过分页上限时应失败退出"
fi
assert_contains "purge-cloud: 超过页数上限时报错" \
    "$(<"${ERR}")$(<"${OUT}")" "扫描超过 2 页"
assert_equal "purge-cloud: 到上限后不再继续请求" "0" \
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
    || fail "purge-cloud: 自定义状态文件路径应成功"
assert_contains "purge-cloud: 识别自定义状态文件并告警" \
    "$(<"${OUT}")$(<"${ERR}")" "检测到本机已有 easy_all 安装"

# 6) 成功 DELETE 返回 204 + 空响应体时必须算成功（曾把空体送 jq 判定失败，导致清理中断）
CALLS="${TMP_DIR}/empty-delete-calls.log"
OUT="${TMP_DIR}/empty-delete.out"
ERR="${TMP_DIR}/empty-delete.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env PURGE_TEST_EMPTY_DELETE=1 || \
    fail "purge-cloud: 204 空体的成功 DELETE 不得判为失败：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloud: 204 空体仍删除全部 easy_all DNS 记录" "101" "${total}"
assert_contains "purge-cloud: 204 空体后仍输出清理完成" "$(<"${OUT}")" "Cloudflare 清理完成"


# 7) 只授 DNS/证书权限的 Token 读 /rulesets 会 403：规则只是附带清理对象，
#    不能因此跳过第 1 阶段已收集的 DNS 记录与第 4 阶段的证书清理。
CALLS="${TMP_DIR}/rulesets-deny-calls.log"
OUT="${TMP_DIR}/rulesets-deny.out"
ERR="${TMP_DIR}/rulesets-deny.err"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    env PURGE_TEST_RULESETS_DENY=1 || \
    fail "purge-cloud: ruleset 无权限时不得中断清理：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloud: ruleset 403 仍删除全部 easy_all DNS 记录" "101" "${total}"
assert_contains "purge-cloud: ruleset 403 时告警并继续" \
    "$(<"${OUT}")$(<"${ERR}")" "无法读取 ruleset"
assert_equal "purge-cloud: ruleset 403 只告警一次" "1" \
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

# AWS 专用 fixture：只解析出 Zone example.com，cf.example.com 不是独立 Zone。
# 用来验证「完整主机名只精确匹配」——x.cf.example.com 的资源必须保留。
write_fixture "${FIXTURE_ROOT}/aws-host/zone-example.com.json" <<'EOF'
{"success":true,"result":[{"id":"z1","name":"example.com","account":{"id":"a1"}}]}
EOF

run_purge_domain() { # $1=calls $2=out $3=err $4=fixture $5=--domain 值
    : >"$1"
    : >"${TMP_DIR}/aws-sentinel.log"
    PATH="${TMP_DIR}/bin:${PATH}" \
        CLOUDFLARE_API_TOKEN="${TOKEN}" \
        TMPDIR="${TMP_DIR}" \
        PURGE_TEST_CALLS="$1" \
        PURGE_TEST_FIXTURE_DIR="$4" \
        EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TAKEOVER_LOG}" \
        "${AWS_ENV_UNSET[@]}" bash "${SCRIPT}" --domain "$5" --yes >"$2" 2>"$3" </dev/null
}

deleted_paths() { # $1=calls，输出按字典序排序的 DELETE 路径
    sed -n 's|^DELETE https://api.cloudflare.com/client/v4||p' "$1" | sort
}

# 8.1 完整主机名：只删该主机本身，后代 DNS/规则/证书全部保留。
CALLS="${TMP_DIR}/domain-host-calls.log"
OUT="${TMP_DIR}/domain-host.out"
ERR="${TMP_DIR}/domain-host.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" cf.example.com \
    || fail "purge-cloud: --domain 完整主机名应成功：$(tail -n 3 "${ERR}")"
expected_host=$(
    cat <<'EOF'
/certificates/cert-cf
/zones/z1/dns_records/dns-cf-example-com
/zones/z1/rulesets/rs1/rules/r-exact
/zones/z1/rulesets/rs1/rules/r-upper
/zones/z1/rulesets/rs1/rules/r-ws
EOF
)
assert_equal "purge-cloud: --domain 完整主机名的删除集合" "${expected_host}" \
    "$(deleted_paths "${CALLS}")"
assert_equal "purge-cloud: 仍有规则的 ruleset 不删除" "0" \
    "$(grep -cE 'DELETE .*/rulesets/rs[0-9]+$' "${CALLS}" || true)"
assert_equal "purge-cloud: 后代 DNS、后代 SAN 与 wildcard 证书保留" "0" \
    "$(grep -cE 'dns-x-cf-example-com|cert-mixed|cert-wild' "${CALLS}" || true)"

# 8.2 Zone 根域：带 easy_all 注释的后代记录进入范围，第三方记录与复杂规则仍保留。
CALLS="${TMP_DIR}/domain-zone-calls.log"
OUT="${TMP_DIR}/domain-zone.out"
ERR="${TMP_DIR}/domain-zone.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" example.com \
    || fail "purge-cloud: --domain Zone 根域应成功：$(tail -n 3 "${ERR}")"
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
assert_equal "purge-cloud: --domain Zone 根域的删除集合" "${expected_zone}" \
    "$(deleted_paths "${CALLS}")"
assert_equal "purge-cloud: 第三方 DNS 记录与未标记证书保留" "0" \
    "$(grep -cE 'dns-third-example-com|cert-wild' "${CALLS}" || true)"

# 8.3 输入大小写不影响判定：Zone 查询与主机比较都按小写处理。
CALLS="${TMP_DIR}/domain-upper-calls.log"
OUT="${TMP_DIR}/domain-upper.out"
ERR="${TMP_DIR}/domain-upper.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" 'CF.Example.COM' \
    || fail "purge-cloud: 大写域名输入应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 大写输入与小写输入删除集合一致" "${expected_host}" \
    "$(deleted_paths "${CALLS}")"

# 8.4 嵌套真实 Zone：输入等于 Zone 名才覆盖后代，且不越界到 xcf.example.com。
CALLS="${TMP_DIR}/domain-nested-calls.log"
OUT="${TMP_DIR}/domain-nested.out"
ERR="${TMP_DIR}/domain-nested.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/nested" cf.example.com \
    || fail "purge-cloud: 嵌套 Zone 输入应成功：$(tail -n 3 "${ERR}")"
expected_nested=$(
    cat <<'EOF'
/zones/z2/dns_records/dns-a-cf-example-com
/zones/z2/rulesets/rs2/rules/r-acf
EOF
)
assert_equal "purge-cloud: 嵌套 Zone 根域覆盖后代但只匹配点分隔后缀" "${expected_nested}" \
    "$(deleted_paths "${CALLS}")"

# 8.5 多输入多 Zone：每个输入按各自 Zone 的范围独立判定。
CALLS="${TMP_DIR}/domain-multi-calls.log"
OUT="${TMP_DIR}/domain-multi.out"
ERR="${TMP_DIR}/domain-multi.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/multi" 'cf.example.com,example.net' \
    || fail "purge-cloud: 多输入多 Zone 应成功：$(tail -n 3 "${ERR}")"
expected_multi=$(
    cat <<'EOF'
/zones/z2/dns_records/dns-a-cf-example-com
/zones/z2/rulesets/rs2/rules/r-acf
/zones/z4/dns_records/dns-other-example-net
/zones/z4/dns_records/dns-sub-example-net
/zones/z4/rulesets/rs4/rules/r-sub
EOF
)
assert_equal "purge-cloud: 多输入多 Zone 的删除集合" "${expected_multi}" \
    "$(deleted_paths "${CALLS}")"

# 8.6 集合语法：既不产生规则 DELETE，也不能让整个清理中断（DNS/证书仍照常处理）。
CALLS="${TMP_DIR}/domain-set-calls.log"
OUT="${TMP_DIR}/domain-set.out"
ERR="${TMP_DIR}/domain-set.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/setsyntax" cf.example.com \
    || fail "purge-cloud: 集合表达式不得中断清理：$(tail -n 3 "${ERR}")"
expected_set=$(
    cat <<'EOF'
/zones/z1/dns_records/dns-cf-example-com
EOF
)
assert_equal "purge-cloud: 集合表达式保留规则但继续清理 DNS" "${expected_set}" \
    "$(deleted_paths "${CALLS}")"

# 8.7 多 Zone 警告：只有全部 Zone 都没收集到 easy_all DNS 记录时才提示一次。
warn_count() { grep -c '没有匹配到 easy_all DNS 记录' "$1" || true; }
CALLS="${TMP_DIR}/warn-mixed-calls.log"
OUT="${TMP_DIR}/warn-mixed.out"
ERR="${TMP_DIR}/warn-mixed.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/warn-mixed" \
    'cf.example.com,sub.example.net' \
    || fail "purge-cloud: 多 Zone 警告用例应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 前面的 Zone 无记录时不得误报警告" "0" "$(warn_count "${OUT}")"
assert_equal "purge-cloud: 仍有 easy_all 记录时照常删除" "1" \
    "$(grep -c 'dns_records/dns-sub-example-net' "${CALLS}")"

CALLS="${TMP_DIR}/warn-empty-calls.log"
OUT="${TMP_DIR}/warn-empty.out"
ERR="${TMP_DIR}/warn-empty.err"
run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/warn-empty" \
    'cf.example.com,sub.example.net' \
    || fail "purge-cloud: 全部为空的多 Zone 用例应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 全部 Zone 无记录时恰好提示一次" "1" "$(warn_count "${OUT}")"

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
    "${AWS_ENV_UNSET[@]}" bash "${SCRIPT}" --all --yes >"${OUT}" 2>"${ERR}" </dev/null \
    || fail "purge-cloud: --all 应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: --all 不输出 --domain 专属提示" "0" "$(warn_count "${OUT}")"

# 8.9 Token 可见多个同名 active Zone：必须显式报错退出，不得盲取第一个，也不得发出任何清理请求。
CALLS="${TMP_DIR}/dup-calls.log"
OUT="${TMP_DIR}/dup.out"
ERR="${TMP_DIR}/dup.err"
if run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/dupzone" example.com; then
    fail "purge-cloud: 同名重复 Zone 必须报错退出，而不是猜一个"
fi
assert_contains "purge-cloud: 同名重复 Zone 报错点名 Token 可见多个同名 active Zone" \
    "$(<"${ERR}")$(<"${OUT}")" "Token 可见多个同名 active Zone"
assert_equal "purge-cloud: 同名重复 Zone 不发起任何 DELETE/PUT/POST 清理请求" "0" \
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
    "${AWS_ENV_UNSET[@]}" bash "${SCRIPT}" --all --yes >"${OUT}" 2>"${ERR}" </dev/null; then
    fail "purge-cloud: 含换行的 Token 必须被拒绝"
fi
assert_contains "purge-cloud: 含换行的 Token 报格式无效" \
    "$(<"${ERR}")$(<"${OUT}")" "格式无效"
assert_equal "purge-cloud: 格式无效的 Token 不发起 API 请求" "0" \
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
    fail "purge-cloud: 存在接管记录时 --all 应成功：$(tail -n 3 "${ERR}")"
total=$(sed -n 's/.*Cloudflare 清理完成：\([0-9][0-9]*\) 个对象.*/\1/p' "${OUT}" | tail -n 1)
assert_equal "purge-cloud: --all 保留接管而来的 DNS 后仍删除其余 100 条" "100" "${total}"
assert_equal "purge-cloud: --all 不发送接管记录的 DNS DELETE" "0" \
    "$(grep -c '/zones/z1/dns_records/tail1' "${CALLS}")"
assert_equal "purge-cloud: --all 其余 easy_all DNS 记录各发一次 DELETE" "100" \
    "$(grep -c '/zones/z1/dns_records/[a-z]' "${CALLS}")"
assert_contains "purge-cloud: --all 说明该记录来自强制接管" \
    "$(<"${OUT}")$(<"${ERR}")" "DNS 记录来自强制接管"
assert_contains "purge-cloud: --all 给出接管日志路径" \
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
    || fail "purge-cloud: 存在接管记录时 --domain 根域应成功：$(tail -n 3 "${ERR}")"
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
assert_equal "purge-cloud: --domain 根域的删除集合只少掉接管的 DNS 记录" \
    "${expected_takeover}" "$(deleted_paths "${CALLS}")"
assert_contains "purge-cloud: 接管主机的 Origin CA 仍被删除" \
    "$(deleted_paths "${CALLS}")" "/certificates/cert-cf"
assert_contains "purge-cloud: 接管主机的规则仍被删除" \
    "$(deleted_paths "${CALLS}")" "/zones/z1/rulesets/rs1/rules/r-exact"
rm -f "${TAKEOVER_LOG}"

# 11.0 隔离：父环境带宿主样式 AWS 凭据时，被测脚本必须被剥离凭据、不碰 aws；
# 这是 F1 的回归锁：任何一个调用点漏了 env -u，凭据就会穿透并撞上顶部哨兵。
export AWS_ACCESS_KEY_ID=AKIAFAKEHOSTEXAMPLE
export AWS_SECRET_ACCESS_KEY=fake-host-secret
export AWS_SESSION_TOKEN=fake-host-token
CALLS="${TMP_DIR}/aws-isolation-calls.log"
OUT="${TMP_DIR}/aws-isolation.out"
ERR="${TMP_DIR}/aws-isolation.err"
: >"${TMP_DIR}/aws-sentinel.log"
run_purge "${CALLS}" "${OUT}" "${ERR}" \
    || fail "purge-cloud: 宿主凭据在场时仍应成功跳过 AWS：$(tail -n 3 "${ERR}")"
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
assert_contains "purge-cloud: 宿主凭据被剥离后提示跳过 AWS" "$(<"${OUT}")" "跳过 CloudFront/ACM 清理"
assert_equal "purge-cloud: 宿主凭据不得触达 aws 哨兵" "0" \
    "$(grep -c . "${TMP_DIR}/aws-sentinel.log" || true)"


# 11) CloudFront / ACM：只有携带 AWS 凭据（且 PATH 里有 aws）时才清理；
#     分发按 Comment 前缀 + 别名范围识别，证书按 easy_all=managed 标记 + InUseBy + 域名范围识别。
cat >"${TMP_DIR}/bin/aws" <<'EOF'
#!/usr/bin/env bash
# 功能版假 aws：按官方响应形状回放，并把真实服务对 update/delete 的关键约束
# （DistributionConfig 必填字段、Enabled=false、If-Match 命中最新 ETag）锁进测试。
printf '%s\n' "$*" >>"${PURGE_TEST_AWS_CALLS}"
state_dir=${PURGE_TEST_AWS_STATE_DIR:-/tmp/easy_all_aws_state}
mkdir -p "${state_dir}"

args=("$@")
service="" op="" query=0 id="" config="" ifmatch="" arn=""
no_paginate=0 input_json="{}" input_marker="" input_token=""
for i in "${!args[@]}"; do
    case "${args[$i]}" in
    --query) query=1 ;;
    --id) id=${args[$((i + 1))]:-} ;;
    --distribution-config) config=${args[$((i + 1))]:-} ;;
    --if-match) ifmatch=${args[$((i + 1))]:-} ;;
    --certificate-arn) arn=${args[$((i + 1))]:-} ;;
    --no-paginate) no_paginate=1 ;;
    --cli-input-json) input_json=${args[$((i + 1))]:-} ;;
    esac
done
# 服务端分页参数只从 --cli-input-json 读（缺省 {}）：与真实 CLI 一样，没传就没有 token。
input_marker=$(jq -r '.Marker // empty' <<<"${input_json}" 2>/dev/null || true)
input_token=$(jq -r '.NextToken // empty' <<<"${input_json}" 2>/dev/null || true)
for i in "${!args[@]}"; do
    case "${args[$i]}" in
    cloudfront|acm)
        service=${args[$i]}
        op=${args[$((i + 1))]:-}
        break
        ;;
    esac
done

fail_service() { printf 'fake aws: %s\n' "$*" >&2; exit 254; }

# 每次调用按对象计数：模拟“计划读一次、删除前再读一次”的状态漂移。
count_call() { # $1=key；输出本次是第几次
    local file="${state_dir}/$1" n
    n=$(cat "${file}" 2>/dev/null || printf '0')
    n=$((n + 1))
    printf '%s' "${n}" >"${file}"
    printf '%s' "${n}"
}

# 真实服务 update 后会换 ETag，且只有已禁用的分发才能删除；桩必须复刻这两条，
# 否则「先禁用 → 等 Deployed → 用最新 ETag 删除」的顺序回归拦不住。
dist_etag() { # $1=id
    local file="${state_dir}/etag-$1" version
    version=$(cat "${file}" 2>/dev/null || printf '1')
    printf 'ETAG%s-%s' "${version}" "$1"
}

bump_etag() { # $1=id；update 成功后轮换
    local file="${state_dir}/etag-$1" version
    version=$(cat "${file}" 2>/dev/null || printf '1')
    printf '%s' "$((version + 1))" >"${file}"
}

dist_disabled() { [[ -f "${state_dir}/disabled-$1" ]]; }

dist_enabled_json() { # $1=id；输出 true/false
    if dist_disabled "$1"; then printf 'false'; else printf 'true'; fi
}

dist_config() { # $1=id，输出官方形状的 DistributionConfig
    case "$1" in
    D1) printf '%s' '{"CallerReference":"caller-D1","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com","sub.cf.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com","CustomHeaders":{"Quantity":1,"Items":[{"HeaderName":"X-Easy-All-Origin-Key","HeaderValue":"easy-all-origin-key-sentinel-3f9c"}]}}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    D2) printf '%s' '{"CallerReference":"caller-D2","Comment":"用户自己的分发","Aliases":{"Items":["cf.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    D3) printf '%s' '{"CallerReference":"caller-D3","Comment":"easy_all-cloudfront-x.example.com","Aliases":{"Items":["x.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    D4) printf '%s' '{"CallerReference":"caller-D4","Comment":"easy_all-cloudfront-mixed.example.com","Aliases":{"Items":["cf.example.com","other.example.net"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    DH1) printf '%s' '{"CallerReference":"caller-DH1","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    DH2) printf '%s' '{"CallerReference":"caller-DH2","Comment":"easy_all-cloudfront-x.cf.example.com","Aliases":{"Items":["x.cf.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    DH3) printf '%s' '{"CallerReference":"caller-DH3","Comment":"用户自己的分发","Aliases":{"Items":["cf.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    D5) printf '%s' '{"CallerReference":"caller-D5","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com"]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    *) printf '%s' '{"CallerReference":"caller-unknown","Comment":"x","Aliases":{"Items":[]},"Enabled":true,"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"DefaultCacheBehavior":{"TargetOriginId":"origin.example.com"}}' ;;
    esac
}

cert_domains() { # $1=ARN，输出 DomainName 与各 SAN 换行
    case "$1" in
    *certificate/C1*) printf 'cf.example.com\nsub.cf.example.com\n' ;;
    *certificate/C2*) printf 'x.example.com\n' ;;
    *certificate/C3*) printf 'cf.example.com\n' ;;
    *certificate/C4*) printf 'cf.example.com\n' ;;
    *certificate/C5*) printf 'cf.example.com\n' ;;
    *certificate/C6*) printf 'cf.example.com\n' ;;
    *certificate/C7*) printf 'cf.example.com\n' ;;
    *certificate/C8*) printf 'x.example.com\n' ;;
    *certificate/CH1*) printf 'cf.example.com\n' ;;
    *certificate/CH2*) printf 'x.cf.example.com\n' ;;
    *) printf '' ;;
    esac
}

cert_inuse() { # $1=ARN，输出 InUseBy 数组 JSON
    case "$1" in
    *certificate/C4*) printf '["arn:aws:cloudfront::1:distribution/OTHER"]' ;;
    # C7：无 easy_all 标记但被其他业务分发占用的证书。归属检查必须先于占用记录，否则它会被
    # 写进复核清单，虚报确认数量并对无关证书多发一轮 API。
    *certificate/C7*) printf '["arn:aws:cloudfront::1:distribution/OTHER"]' ;;
    # C8：带管理标记但在用、域名越界（x.example.com）。归属三重要求同时成立，范围外的在用证书
    # 同样不得进复核清单。
    *certificate/C8*) printf '["arn:aws:cloudfront::1:distribution/OTHER"]' ;;
    # C6 模拟「计划阶段被本次要删的分发占用」：分发删除后才变成可删，用于覆盖孤儿证书回收。
    # PURGE_TEST_CERT_INUSE_LAG=N：删除分发后前 N 次读取仍报 ItUseBy，模拟真实收敛滞后。
    *certificate/C6*)
        if [[ "${PURGE_TEST_CERT_INUSE_PURGED:-0}" != "1" ]]; then
            printf '[]'
        elif [[ ! -f "${state_dir}/deleted-D1" ]]; then
            printf '["arn:aws:cloudfront::1:distribution/D1"]'
        elif [[ "${PURGE_TEST_CERT_INUSE_LAG:-0}" != "0" ]]; then
            lag="${state_dir}/c6-lag"
            n=$(cat "${lag}" 2>/dev/null || printf 0)
            if ((n < PURGE_TEST_CERT_INUSE_LAG)); then
                printf '%s' "$((n + 1))" >"${lag}"
                printf '["arn:aws:cloudfront::1:distribution/D1"]'
            else
                printf '[]'
            fi
        else
            printf '[]'
        fi
        ;;
    *) printf '[]' ;;
    esac
}

in_host_scope() { [[ "${PURGE_TEST_AWS_SCOPE:-}" == "host" ]]; }

# 双行为分页桩：带 --no-paginate 时一次只回一页服务端响应（保留截断标记）；
# 不带时复刻真实 CLI 的自动分页——取完所有页、合并 result key 并丢弃
# IsTruncated/NextMarker/NextToken（botocore build_full_result），这正是 F2 的根因形状。
# PURGE_TEST_AWS_MULTIPAGE=dist：CloudFront 三个服务页；=all：CloudFront 同前，ACM 也三页。
dist_page() { # $1=marker；输出该页 Items 数组
    if in_host_scope; then
        case "$1" in
        "") printf '%s' '[{"Id":"DH1","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com"]}},{"Id":"DH2","Comment":"easy_all-cloudfront-x.cf.example.com","Aliases":{"Items":["x.cf.example.com"]}},{"Id":"DH3","Comment":"用户自己的分发","Aliases":{"Items":["cf.example.com"]}}]' ;;
        *) printf '%s' '[]' ;;
        esac
        return
    fi
    case "${PURGE_TEST_AWS_MULTIPAGE:-}" in
    dist | all)
        case "$1" in
        "") printf '%s' '[{"Id":"D1","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com","sub.cf.example.com"]}}]' ;;
        P2) printf '%s' '[{"Id":"D5","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com"]}}]' ;;
        *) printf '%s' '[]' ;;
        esac
        ;;
    *)
        case "$1" in
        "") printf '%s' '[{"Id":"D1","Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com","sub.cf.example.com"]}},{"Id":"D2","Comment":"用户自己的分发","Aliases":{"Items":["cf.example.com"]}},{"Id":"D3","Comment":"easy_all-cloudfront-x.example.com","Aliases":{"Items":["x.example.com"]}},{"Id":"D4","Comment":"easy_all-cloudfront-mixed.example.com","Aliases":{"Items":["cf.example.com","other.example.net"]}}]' ;;
        *) printf '%s' '[]' ;;
        esac
        ;;
    esac
}

dist_next_marker() { # $1=marker；输出该页的 NextMarker（空 = 最后一页）
    case "${PURGE_TEST_AWS_MULTIPAGE:-}" in
    dist | all)
        case "$1" in
        "") printf 'P2' ;;
        P2) printf 'P3' ;;
        esac
        ;;
    esac
}

acm_page() { # $1=token；输出该页 CertificateSummaryList 数组
    if in_host_scope; then
        case "$1" in
        "") printf '%s' '[{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/CH1"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/CH2"}]' ;;
        *) printf '%s' '[]' ;;
        esac
        return
    fi
    case "${PURGE_TEST_AWS_MULTIPAGE:-}" in
    all)
        case "$1" in
        "") printf '%s' '[{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C1"}]' ;;
        T2) printf '%s' '[{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C5"}]' ;;
        *) printf '%s' '[]' ;;
        esac
        ;;
    *)
        case "$1" in
        "")
            if [[ "${PURGE_TEST_CERT_INUSE_PURGED:-0}" == "1" ]]; then
                printf '%s' '[{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C1"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C2"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C3"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C4"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C6"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C7"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C8"}]'
            else
                printf '%s' '[{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C1"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C2"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C3"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C4"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C7"},{"CertificateArn":"arn:aws:acm:us-east-1:1:certificate/C8"}]'
            fi
            ;;
        *) printf '%s' '[]' ;;
        esac
        ;;
    esac
}

acm_next_token() { # $1=token；输出该页的 NextToken（空 = 最后一页）
    case "${PURGE_TEST_AWS_MULTIPAGE:-}" in
    all)
        case "$1" in
        "") printf 'T2' ;;
        T2) printf 'T3' ;;
        esac
        ;;
    esac
}

case "${service} ${op}" in
"cloudfront list-distributions")
    if [[ "${PURGE_TEST_AWS_DENY:-0}" == "1" ]]; then
        printf 'An error occurred (AccessDenied)\n' >&2
        exit 254
    fi
    if [[ "${no_paginate}" == "1" ]]; then
        page_items=$(dist_page "${input_marker}")
        page_next=$(dist_next_marker "${input_marker}")
        if [[ -n "${page_next}" ]]; then
            jq -cn --argjson items "${page_items}" --arg next "${page_next}" \
                '{DistributionList:{IsTruncated:true, NextMarker:$next, Items:$items}}'
        else
            jq -cn --argjson items "${page_items}" \
                '{DistributionList:{IsTruncated:false, Items:$items}}'
        fi
    else
        merged='[]'
        page_marker=""
        while :; do
            merged=$(jq -cn --argjson acc "${merged}" --argjson page "$(dist_page "${page_marker}")" \
                '$acc + $page')
            page_next=$(dist_next_marker "${page_marker}")
            [[ -n "${page_next}" ]] || break
            page_marker=${page_next}
        done
        jq -cn --argjson items "${merged}" '{DistributionList:{Items:$items}}'
    fi
    ;;
"cloudfront get-distribution-config")
    # 官方形状：{ETag, DistributionConfig}，配置在根对象。
    n=$(count_call "config-${id}")
    base=$(dist_config "${id}")
    comment=$(jq -r '.Comment' <<<"${base}")
    aliases=$(jq -c '.Aliases.Items // []' <<<"${base}")
    case "${PURGE_TEST_AWS_DRIFT:-}" in
    dist-comment)
        if [[ "${id}" == "D1" && "${n}" -ge 2 ]]; then
            comment="hand-managed"
        fi
        ;;
    dist-aliases)
        # 作用域：计划产出的全部受管分发（Comment 前缀），自第 1 次读取起别名已为空。
        if [[ "${comment}" == "easy_all-cloudfront-"* ]]; then
            aliases='[]'
        fi
        ;;
    dist-aliases-late)
        # D1 定点：从第 2 次读取（最终删除前复核）开始别名已为空。
        if [[ "${id}" == "D1" && "${n}" -ge 2 ]]; then
            aliases='[]'
        fi
        ;;
    esac
    cfg=$(jq -c --arg comment "${comment}" --argjson aliases "${aliases}" \
        --argjson enabled "$(dist_enabled_json "${id}")" \
        '.Comment = $comment | .Aliases.Items = $aliases | .Enabled = $enabled' <<<"${base}")
    printf '{"ETag":"%s","DistributionConfig":%s}\n' "$(dist_etag "${id}")" "${cfg}"
    ;;
"cloudfront get-distribution")
    # 禁用变更的服务端传播：update 后至少一次读取仍会看到旧配置（Enabled=true、Deployed），
    # 传播完成前 delete-distribution 会以 DistributionNotDisabled 被拒——与真实 AWS 一致。
    enabled=$(dist_enabled_json "${id}")
    propagating="${state_dir}/propagating-${id}"
    if [[ -f "${propagating}" ]]; then
        if [[ "$(cat "${propagating}")" -gt 1 ]]; then
            enabled=true
            printf '%s' "$(( $(cat "${propagating}") - 1 ))" >"${propagating}"
        else
            rm -f -- "${propagating}"
        fi
    fi
    if ((query == 1)); then
        printf 'Deployed\n'
    else
        printf '{"ETag":"%s","Distribution":{"Status":"Deployed","DistributionConfig":%s}}\n' \
            "$(dist_etag "${id}")" \
            "$(dist_config "${id}" | jq -c --argjson enabled "${enabled}" '.Enabled = $enabled')"
    fi
    ;;
"cloudfront update-distribution")
    # 真实服务会拒绝缺必填字段的 DistributionConfig，要求 If-Match 命中当前 ETag，
    # 并在成功后换上新的 ETag；配置走 file://，桩读出后落盘供断言检查密钥未进命令行。
    if [[ "${config}" == file://* ]]; then
        config_file=${config#file://}
        [[ -f "${config_file}" ]] \
            || fail_service "update-distribution 的 file:// 配置不存在：${config_file}"
        cp -- "${config_file}" "${state_dir}/last-config-${id}"
        config=$(cat "${config_file}")
    fi
    jq -e . >/dev/null 2>&1 <<<"${config}" || fail_service "update-distribution 的 config 不是合法 JSON"
    caller=$(jq -r '.CallerReference // empty' <<<"${config}")
    origins=$(jq -r '.Origins.Items // [] | length' <<<"${config}")
    enabled=$(jq -r '.Enabled' <<<"${config}")
    [[ -n "${caller}" ]] || fail_service "update-distribution 缺少 CallerReference"
    ((origins > 0)) || fail_service "update-distribution 缺少 Origins"
    [[ "${enabled}" == "false" ]] || fail_service "update-distribution 的 Enabled 必须为 false"
    [[ "${ifmatch}" == "$(dist_etag "${id}")" ]] || fail_service "update-distribution 的 --if-match 不是最新 ETag：${ifmatch}"
    bump_etag "${id}"
    : >"${state_dir}/disabled-${id}"
    # 禁用请求提交后进入传播期：首轮 get-distribution 仍返回旧的 Enabled=true。
    printf '2' >"${state_dir}/propagating-${id}"
    printf '{}\n'
    ;;
"cloudfront delete-distribution")
    [[ ! -f "${state_dir}/propagating-${id}" ]] \
        || fail_service "delete-distribution 在禁用传播完成前被调用（${id}）"
    dist_disabled "${id}" || fail_service "delete-distribution 必须先禁用分发（${id}）"
    # 删除权限/IAM 抖动：删除失败的分发仍存活，关联证书不能被当成「等收敛」。
    if [[ "${PURGE_TEST_AWS_DENY_DELETE_D1:-0}" == "1" && "${id}" == "D1" ]]; then
        printf 'An error occurred (AccessDenied) when calling the DeleteDistribution operation\n' >&2
        exit 254
    fi
    : >"${state_dir}/deleted-${id}"
    [[ "${ifmatch}" == "$(dist_etag "${id}")" ]] \
        || fail_service "delete-distribution 的 --if-match 不是最新 ETag：${ifmatch}"
    printf '{}\n'
    ;;
"acm list-certificates")
    # 分页异常：每页都返回同一 NextToken，被测脚本必须在第二次请求前停下。
    if [[ "${PURGE_TEST_AWS_LOOP_TOKEN:-0}" == "1" ]]; then
        printf '{"CertificateSummaryList":[],"NextToken":"LOOP"}\n'
        exit 0
    fi
    if [[ "${no_paginate}" == "1" ]]; then
        page_items=$(acm_page "${input_token}")
        page_next=$(acm_next_token "${input_token}")
        if [[ -n "${page_next}" ]]; then
            jq -cn --argjson items "${page_items}" --arg next "${page_next}" \
                '{CertificateSummaryList:$items, NextToken:$next}'
        else
            jq -cn --argjson items "${page_items}" '{CertificateSummaryList:$items}'
        fi
    else
        merged='[]'
        page_token=""
        while :; do
            merged=$(jq -cn --argjson acc "${merged}" --argjson page "$(acm_page "${page_token}")" \
                '$acc + $page')
            page_next=$(acm_next_token "${page_token}")
            [[ -n "${page_next}" ]] || break
            page_token=${page_next}
        done
        jq -cn --argjson items "${merged}" '{CertificateSummaryList:$items}'
    fi
    ;;
"acm describe-certificate")
    if [[ "${PURGE_TEST_AWS_DENY_DESCRIBE:-0}" == "1" ]]; then
        printf 'An error occurred (AccessDenied) when calling DescribeCertificate\n' >&2
        exit 254
    fi
    n=$(count_call "describe-${arn//[^A-Za-z0-9]/_}")
    if [[ "${PURGE_TEST_AWS_DESCRIBE_C6_DENY_FROM:-0}" != "0" && "${arn}" == *certificate/C6* \
        && "${n}" -ge "${PURGE_TEST_AWS_DESCRIBE_C6_DENY_FROM}" ]]; then
        # 节流/IAM 抖动：回收阶段的复核读不到状态，必须告警并计失败，不能当成「不归属」静默略过。
        printf 'An error occurred (Throttling) when calling DescribeCertificate\n' >&2
        exit 254
    fi
    inuse=$(cert_inuse "${arn}")
    if [[ "${PURGE_TEST_AWS_DRIFT:-}" == "cert-inuse" && "${arn}" == *certificate/C1* && "${n}" -ge 2 ]]; then
        inuse='["arn:aws:cloudfront::1:distribution/OTHER"]'
    fi
    names_json=$(cert_domains "${arn}" | jq -R . | jq -sc .)
    jq -cn --argjson names "${names_json}" --argjson inuse "${inuse}" \
        '{Certificate:{DomainName:$names[0], SubjectAlternativeNames:$names, InUseBy:$inuse}}'
    ;;
"acm list-tags-for-certificate")
    if [[ "${PURGE_TEST_AWS_DENY_LISTTAGS:-0}" == "1" ]]; then
        printf 'An error occurred (AccessDenied) when calling ListTagsForCertificate\n' >&2
        exit 254
    fi
    n=$(count_call "tags-${arn//[^A-Za-z0-9]/_}")
    managed=1
    case "${arn}" in
    *certificate/C3* | *certificate/C7*) managed=0 ;;
    esac
    if [[ "${PURGE_TEST_AWS_DRIFT:-}" == "cert-tag" && "${arn}" == *certificate/C1* && "${n}" -ge 2 ]]; then
        managed=0
    fi
    if ((managed == 1)); then
        printf '{"Tags":[{"Key":"easy_all","Value":"managed"}]}\n'
    else
        printf '{"Tags":[]}\n'
    fi
    ;;
"acm delete-certificate")
    # 删除权限/IAM 抖动：证书删除被拒必须计失败（不能当成「合法保留」）。
    if [[ "${PURGE_TEST_AWS_DENY_DELETE_C1:-0}" == "1" && "${arn}" == *certificate/C1 ]]; then
        printf 'An error occurred (AccessDenied) when calling the DeleteCertificate operation\n' >&2
        exit 254
    fi
    printf '{}\n'
    ;;
*) printf '{}\n' ;;
esac
EOF
chmod 755 "${TMP_DIR}/bin/aws"

run_purge_aws() { # $1=calls $2=out $3=err；其余参数原样传给命令
    # F3/F5 用场景 fixture 覆盖默认的 warn-empty；drift 的 per-对象计数在每次调用前重置，
    # 否则同一 TMP_DIR 下前置用例已对 C1/D1 计数，「首次/此后」会失真。
    local calls=$1 out=$2 err=$3
    shift 3
    : >"${calls}"
    : >"${TMP_DIR}/aws-calls.log"
    : >"${TMP_DIR}/aws-sentinel.log"
    rm -rf "${TMP_DIR}/aws-state"
    mkdir -p "${TMP_DIR}/aws-state"
    PATH="${TMP_DIR}/bin:${PATH}" \
        CLOUDFLARE_API_TOKEN="${TOKEN}" \
        TMPDIR="${TMP_DIR}" \
        PURGE_TEST_CALLS="${calls}" \
        PURGE_TEST_AWS_CALLS="${TMP_DIR}/aws-calls.log" \
        PURGE_TEST_AWS_STATE_DIR="${TMP_DIR}/aws-state" \
        PURGE_TEST_FIXTURE_DIR="${PURGE_TEST_AWS_FIXTURE_DIR:-${FIXTURE_ROOT}/warn-empty}" \
        EASY_ALL_DNS_TAKEOVER_LOG_OVERRIDE="${TAKEOVER_LOG}" \
        EASY_ALL_PURGE_AWS_WAIT_ATTEMPTS=3 \
        EASY_ALL_PURGE_AWS_WAIT_SECONDS=0 \
        "${AWS_ENV_UNSET[@]}" \
        AWS_ACCESS_KEY_ID=AKIAFAKEEXAMPLE \
        AWS_SECRET_ACCESS_KEY=fake-secret-key-value \
        bash "${SCRIPT}" "$@" --yes >"${out}" 2>"${err}" </dev/null
}

CALLS="${TMP_DIR}/aws-domain-calls.log"
OUT="${TMP_DIR}/aws-domain.out"
ERR="${TMP_DIR}/aws-domain.err"
AWS_CALLS="${TMP_DIR}/aws-calls.log"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: --domain 的 AWS 清理应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 只删除别名全部在范围内的 easy_all 分发" "1" \
    "$(grep -c 'cloudfront delete-distribution --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 删除前先禁用分发" "1" \
    "$(grep -c 'cloudfront update-distribution --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: update 与 delete 前各读一次 get-distribution-config" "2" \
    "$(grep -c 'cloudfront get-distribution-config --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: update 通过 file:// 传配置，源站头密钥不进命令行" "1" \
    "$(grep -c 'update-distribution --id D1 --if-match ETAG1-D1 --distribution-config file://' "${AWS_CALLS}")"
assert_equal "purge-cloud: aws 调用日志里不出现源站头密钥" "0" \
    "$(grep -c 'HeaderValue' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: 源站头密钥哨兵不进入 aws 命令行" "0" \
    "$(grep -c 'easy-all-origin-key-sentinel-3f9c' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: update 回传完整配置且仅 Enabled=false" "true" \
    "$(jq -r '.CallerReference == "caller-D1" and .Enabled == false' "${TMP_DIR}/aws-state/last-config-D1")"
assert_equal "purge-cloud: update 的 If-Match 是本次读取的 ETag" "1" \
    "$(grep -c 'update-distribution --id D1 --if-match ETAG1-D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: delete 用 update 之后轮换的新 ETag" "1" \
    "$(grep -c 'delete-distribution --id D1 --if-match ETAG2-D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 禁用传播期内继续轮询（首轮旧 Deployed 不算完成）" "2" \
    "$(grep -c 'cloudfront get-distribution --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 用户自己的分发不删除" "0" \
    "$(grep -c 'delete-distribution --id D2' "${AWS_CALLS}")"
assert_equal "purge-cloud: 别名越界的 easy_all 分发不删除" "0" \
    "$(grep -c 'delete-distribution --id D3\|delete-distribution --id D4' "${AWS_CALLS}")"
assert_equal "purge-cloud: 只删除带管理标记且未在用的 ACM 证书" "1" \
    "$(grep -c 'acm delete-certificate --region us-east-1 --certificate-arn arn:aws:acm:us-east-1:1:certificate/C1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 无管理标记的证书不删除" "0" \
    "$(grep -c 'acm delete-certificate.*certificate/C3' "${AWS_CALLS}")"
assert_equal "purge-cloud: InUseBy 非空的证书不删除" "0" \
    "$(grep -c 'delete-certificate.*C4' "${AWS_CALLS}")"
assert_equal "purge-cloud: 无管理标记的在用证书不删除" "0" \
    "$(grep -c 'delete-certificate.*C7' "${AWS_CALLS}")"

assert_contains "purge-cloud: 输出 CloudFront/ACM 清理完成" "$(<"${OUT}")" "CloudFront/ACM 清理完成：2 个对象"

# 计划阶段被「本次要删的分发」占用的证书，分发删除后必须回收；仍被其他分发占用的照旧保留。
export PURGE_TEST_CERT_INUSE_PURGED=1
CALLS="${TMP_DIR}/aws-inuse-calls.log"
OUT="${TMP_DIR}/aws-inuse.out"
ERR="${TMP_DIR}/aws-inuse.err"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: 占用证书回收应成功：$(tail -n 3 "${ERR}")"
unset PURGE_TEST_CERT_INUSE_PURGED
AWS_CALLS="${TMP_DIR}/aws-calls.log"
assert_equal "purge-cloud: 分发删除后回收此前被占用的 ACM 证书" "1" \
    "$(grep -c 'delete-certificate.*certificate/C6' "${AWS_CALLS}")"
assert_equal "purge-cloud: 分发删除后仍被其他分发占用的证书保留" "0" \
    "$(grep -c 'delete-certificate.*C4' "${AWS_CALLS}")"
assert_contains "purge-cloud: 确认前告知复核范围" "$(<"${OUT}")" \
    "另有 2 张被分发占用的 ACM 证书将在分发删除后复核"
# 数量仍是 2（C4 + C6）：C7（无 easy_all 标记）与 C8（域名越界）都不得进复核清单。

# InUseBy 在分发删除后需要时间收敛：仍在引用本次已删分发时必须重试，不能当成「保留」静默放过。
export PURGE_TEST_CERT_INUSE_PURGED=1
export PURGE_TEST_CERT_INUSE_LAG=2
CALLS="${TMP_DIR}/aws-inuse-lag-calls.log"
OUT="${TMP_DIR}/aws-inuse-lag.out"
ERR="${TMP_DIR}/aws-inuse-lag.err"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: InUseBy 收敛重试应成功：$(tail -n 3 "${ERR}")"
unset PURGE_TEST_CERT_INUSE_PURGED PURGE_TEST_CERT_INUSE_LAG
AWS_CALLS="${TMP_DIR}/aws-calls.log"
assert_equal "purge-cloud: InUseBy 收敛后回收证书" "1" \
    "$(grep -c 'delete-certificate.*certificate/C6' "${AWS_CALLS}")"

# 回收阶段读不到证书状态：必须告警并计入「合法保留」（A11 口径：归属不可读＝保留不删），
# 但不能静默略过，也不得删除。
export PURGE_TEST_CERT_INUSE_PURGED=1
export PURGE_TEST_AWS_DESCRIBE_C6_DENY_FROM=2
CALLS="${TMP_DIR}/aws-inuse-deny-calls.log"
OUT="${TMP_DIR}/aws-inuse-deny.out"
ERR="${TMP_DIR}/aws-inuse-deny.err"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: 回收阶段证书不可读属于合法保留，应退出 0：$(tail -n 3 "${ERR}")"
unset PURGE_TEST_CERT_INUSE_PURGED PURGE_TEST_AWS_DESCRIBE_C6_DENY_FROM
AWS_CALLS="${TMP_DIR}/aws-calls.log"
assert_contains "purge-cloud: 回收阶段证书不可读要告警" "$(<"${OUT}")" \
    "无法读取 ACM 证书状态，保留不删"
assert_contains "purge-cloud: 回收阶段证书不可读计入合法保留" "$(<"${OUT}")" "1 个合法保留"
assert_equal "purge-cloud: 回收阶段不可读的证书不删除" "0" \
    "$(grep -c 'delete-certificate.*certificate/C6' "${AWS_CALLS}")"

# InUseBy 已收敛、但随后归属复核读不到状态：同样属于「归属不可读＝保留不删」，
# 必须告警并计入合法保留，且不得删除。
export PURGE_TEST_CERT_INUSE_PURGED=1
export PURGE_TEST_AWS_DESCRIBE_C6_DENY_FROM=3
CALLS="${TMP_DIR}/aws-settle-deny-calls.log"
OUT="${TMP_DIR}/aws-settle-deny.out"
ERR="${TMP_DIR}/aws-settle-deny.err"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: 归属复核不可读属于合法保留，应退出 0：$(tail -n 3 "${ERR}")"
unset PURGE_TEST_CERT_INUSE_PURGED PURGE_TEST_AWS_DESCRIBE_C6_DENY_FROM
AWS_CALLS="${TMP_DIR}/aws-calls.log"
assert_contains "purge-cloud: 归属复核不可读要告警" "$(<"${OUT}")" "无法读取 ACM 证书状态，保留不删"
assert_contains "purge-cloud: 归属复核不可读计入合法保留" "$(<"${OUT}")" "1 个合法保留"
assert_equal "purge-cloud: 归属复核不可读的证书不删除" "0" \
    "$(grep -c 'delete-certificate.*certificate/C6' "${AWS_CALLS}")"

# A11(a)：等待期内仍被已删除分发引用（InUseBy 迟迟不收敛）是合法的等待性保留：
# 退出 0、保留数可见、证书不删；不得再把正确保留报成删除失败。
export PURGE_TEST_CERT_INUSE_PURGED=1
export PURGE_TEST_CERT_INUSE_LAG=999
CALLS="${TMP_DIR}/aws-kept-inuse-calls.log"
OUT="${TMP_DIR}/aws-kept-inuse.out"
ERR="${TMP_DIR}/aws-kept-inuse.err"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: 等待期内仍被引用的证书属合法保留，应退出 0：$(tail -n 3 "${ERR}")"
unset PURGE_TEST_CERT_INUSE_PURGED PURGE_TEST_CERT_INUSE_LAG
AWS_CALLS="${TMP_DIR}/aws-calls.log"
assert_contains "purge-cloud: 等待性保留要告警" "$(<"${OUT}")" \
    "等待期内仍被已删除的分发引用"
assert_contains "purge-cloud: 等待性保留计入合法保留" "$(<"${OUT}")" "1 个合法保留"
assert_equal "purge-cloud: 等待性保留不报删除失败" "0" \
    "$(grep -c '个对象删除失败' "${OUT}" || true)"
assert_equal "purge-cloud: 等待性保留的证书不删除" "0" \
    "$(grep -c 'delete-certificate.*certificate/C6' "${AWS_CALLS}")"

# A11(b)：真正的删除失败（delete-certificate 被拒）仍然计失败，并沿用原 die 文案非零退出。
export PURGE_TEST_AWS_DENY_DELETE_C1=1
CALLS="${TMP_DIR}/aws-cert-delete-fail-calls.log"
OUT="${TMP_DIR}/aws-cert-delete-fail.out"
ERR="${TMP_DIR}/aws-cert-delete-fail.err"
if run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com; then
    fail "purge-cloud: 删除 ACM 证书失败时必须以非零退出"
fi
unset PURGE_TEST_AWS_DENY_DELETE_C1
assert_contains "purge-cloud: 证书删除失败仍按原文案报失败" "$(<"${ERR}")" \
    "有 1 个对象删除失败；可修复后重试同一命令"
assert_contains "purge-cloud: 证书删除失败计入失败数" "$(<"${OUT}")" \
    "CloudFront/ACM 侧有 1 个对象删除失败"

# 分发删除失败时，它的关联证书不能被当成「等已删除分发收敛」：分发仍存活，InUseBy 永不收敛，
# 只会白等满额重试再额外报一次失败。必须立刻按「仍被存活资源占用」跳过。
# 同时这是 A11(c) 的口径锚定：分发侧「删除失败/归属已变化、保留不删」**有意**仍计 aws_failures
# 并触发 die（分发是清理主对象与高影响资源），与证书侧「合法保留」刻意不一致，不得顺手统一。
export PURGE_TEST_CERT_INUSE_PURGED=1
export PURGE_TEST_AWS_DENY_DELETE_D1=1
CALLS="${TMP_DIR}/aws-delete-fail-calls.log"
OUT="${TMP_DIR}/aws-delete-fail.out"
ERR="${TMP_DIR}/aws-delete-fail.err"
if run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com; then
    fail "purge-cloud: 分发删除失败时必须以非零退出"
fi
unset PURGE_TEST_CERT_INUSE_PURGED PURGE_TEST_AWS_DENY_DELETE_D1
AWS_CALLS="${TMP_DIR}/aws-calls.log"
assert_equal "purge-cloud: 删除失败的分发不算已删分发，不进入收敛重试" "0" \
    "$(grep -c '等待期内仍被已删除的分发引用' "${OUT}" || true)"
assert_equal "purge-cloud: 只剩分发本身计一次失败" "1" \
    "$(grep -c 'CloudFront/ACM 侧有 1 个对象删除失败' "${OUT}")"
assert_equal "purge-cloud: 关联证书保留不删" "0" \
    "$(grep -c 'delete-certificate.*certificate/C6' "${AWS_CALLS}")"

CALLS="${TMP_DIR}/aws-all-calls.log"
OUT="${TMP_DIR}/aws-all.out"
ERR="${TMP_DIR}/aws-all.err"
run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all \
    || fail "purge-cloud: --all 的 AWS 清理应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: --all 删除全部受管分发（不含用户的）" "3" \
    "$(grep -c 'cloudfront delete-distribution --id D[134]' "${AWS_CALLS}")"
assert_equal "purge-cloud: --all 不删用户分发" "0" \
    "$(grep -c 'delete-distribution --id D2' "${AWS_CALLS}")"
assert_equal "purge-cloud: --all 删除范围内全部受管证书" "2" \
    "$(grep -cE 'acm delete-certificate .*certificate/(C1|C2)' "${AWS_CALLS}")"
assert_contains "purge-cloud: --all 输出 CloudFront/ACM 清理完成" "$(<"${OUT}")" "CloudFront/ACM 清理完成：5 个对象"

# 缺凭据时必须跳过 AWS，且不调用 aws CLI。
CALLS="${TMP_DIR}/aws-none-calls.log"
OUT="${TMP_DIR}/aws-none.out"
ERR="${TMP_DIR}/aws-none.err"
: >"${TMP_DIR}/aws-calls.log"
run_purge "${CALLS}" "${OUT}" "${ERR}" env \
    || fail "purge-cloud: 无凭据时应成功：$(tail -n 3 "${ERR}")"
assert_contains "purge-cloud: 无 AWS 凭据时提示跳过" "$(<"${OUT}")" "跳过 CloudFront/ACM 清理"
assert_equal "purge-cloud: 无凭据不调用 aws CLI" "0" "$(grep -c . "${TMP_DIR}/aws-calls.log" || true)"

# AWS 枚举失败时必须在删除任何对象之前停止，不能只清一半。
CALLS="${TMP_DIR}/aws-deny-calls.log"
OUT="${TMP_DIR}/aws-deny.out"
ERR="${TMP_DIR}/aws-deny.err"
if PURGE_TEST_AWS_DENY=1 run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: AWS 枚举失败必须非零退出"
fi
assert_contains "purge-cloud: AWS 枚举失败时说明已取消清理" "$(<"${ERR}")$(<"${OUT}")" "已取消清理"
assert_equal "purge-cloud: AWS 枚举失败时不删除分发" "0" \
    "$(grep -c 'delete-distribution' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: AWS 枚举失败时不删除证书" "0" \
    "$(grep -c 'acm delete-certificate' "${AWS_CALLS}" || true)"

# F3：完整主机名（cf.example.com 不是 Zone）只精确匹配。专用清单里 DH1/CH1 精确命中被删，
# DH2/CH2 越界保留、DH3 用户自建保留——判别力来自 DH2/CH2 的「计数 0」反例。
CALLS="${TMP_DIR}/aws-host-calls.log"
OUT="${TMP_DIR}/aws-host.out"
ERR="${TMP_DIR}/aws-host.err"
PURGE_TEST_AWS_SCOPE=host PURGE_TEST_AWS_FIXTURE_DIR="${FIXTURE_ROOT}/aws-host" \
    run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --domain cf.example.com \
    || fail "purge-cloud: 完整主机名的 AWS 清理应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 完整主机名精确命中的分发被删除" "1" \
    "$(grep -c 'cloudfront delete-distribution --id DH1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 完整主机名下的子域分发保留" "0" \
    "$(grep -c 'delete-distribution --id DH2' "${AWS_CALLS}")"
assert_equal "purge-cloud: 用户自建分发保留" "0" \
    "$(grep -c 'delete-distribution --id DH3' "${AWS_CALLS}")"
assert_equal "purge-cloud: 完整主机名精确命中的证书被删除" "1" \
    "$(grep -c 'delete-certificate.*certificate/CH1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 完整主机名下的子域证书保留" "0" \
    "$(grep -c 'delete-certificate.*certificate/CH2' "${AWS_CALLS}")"
assert_equal "purge-cloud: DH1 的 update 回传原 CallerReference 且 Enabled=false" "true" \
    "$(jq -r '.CallerReference == "caller-DH1" and .Enabled == false' "${TMP_DIR}/aws-state/last-config-DH1")"

# F4：计划之后对象归属/状态漂移时，破坏性调用前的复核必须保留对象、点名。
# A11 口径：证书侧漂移属于「合法保留（aws_kept）」——告警仍保留、对象不删，但不再把保留报成删除失败；
# 分发侧漂移（下面 dist-comment）仍计 aws_failures 并非零退出。
CALLS="${TMP_DIR}/aws-drift-tag-calls.log"
OUT="${TMP_DIR}/aws-drift-tag.out"
ERR="${TMP_DIR}/aws-drift-tag.err"
PURGE_TEST_AWS_DRIFT=cert-tag run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all \
    || fail "purge-cloud: 证书标签漂移属于合法保留，应退出 0：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 标签漂移的证书不删除" "0" \
    "$(grep -c 'delete-certificate.*certificate/C1' "${AWS_CALLS}" || true)"
assert_contains "purge-cloud: 标签漂移时点名 ARN" \
    "$(<"${OUT}")$(<"${ERR}")" "arn:aws:acm:us-east-1:1:certificate/C1"
assert_contains "purge-cloud: 标签漂移时说明对象保留" \
    "$(<"${OUT}")$(<"${ERR}")" "保留不删"
assert_contains "purge-cloud: 标签漂移计入合法保留" "$(<"${OUT}")" "1 个合法保留"

CALLS="${TMP_DIR}/aws-drift-inuse-calls.log"
OUT="${TMP_DIR}/aws-drift-inuse.out"
ERR="${TMP_DIR}/aws-drift-inuse.err"
PURGE_TEST_AWS_DRIFT=cert-inuse run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all \
    || fail "purge-cloud: 证书 InUseBy 漂移属于合法保留，应退出 0：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: InUseBy 漂移的证书不删除" "0" \
    "$(grep -c 'delete-certificate.*certificate/C1' "${AWS_CALLS}" || true)"
assert_contains "purge-cloud: InUseBy 漂移时说明对象保留" \
    "$(<"${OUT}")$(<"${ERR}")" "保留不删"

CALLS="${TMP_DIR}/aws-drift-comment-calls.log"
OUT="${TMP_DIR}/aws-drift-comment.out"
ERR="${TMP_DIR}/aws-drift-comment.err"
# 分发侧漂移是 A11(c) 的口径锚定：分发归属漂移意味着状态与云端失步，仍然非零退出。
if PURGE_TEST_AWS_DRIFT=dist-comment run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: 分发 Comment 漂移后必须非零退出"
fi
assert_equal "purge-cloud: Comment 漂移的分发不删除" "0" \
    "$(grep -c 'delete-distribution --id D1' "${AWS_CALLS}" || true)"
assert_contains "purge-cloud: Comment 漂移时说明对象保留" \
    "$(<"${OUT}")$(<"${ERR}")" "保留不删"

# F5：describe-certificate 失败 → 点名 ARN 并整体取消。用 hosts fixture（含 easy_all
# Cloudflare 对象）让「curl 无 DELETE」断言有判别力：红态会先删 Cloudflare 对象并退出 0。
CALLS="${TMP_DIR}/aws-deny-describe-calls.log"
OUT="${TMP_DIR}/aws-deny-describe.out"
ERR="${TMP_DIR}/aws-deny-describe.err"
if PURGE_TEST_AWS_DENY_DESCRIBE=1 PURGE_TEST_AWS_FIXTURE_DIR="${FIXTURE_ROOT}/hosts" \
    run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: ACM describe 失败必须非零退出"
fi
assert_contains "purge-cloud: describe 失败点名被拒 ARN" \
    "$(<"${OUT}")$(<"${ERR}")" "arn:aws:acm:us-east-1:1:certificate/C1"
assert_contains "purge-cloud: describe 失败说明已取消清理" \
    "$(<"${OUT}")$(<"${ERR}")" "已取消清理"
assert_equal "purge-cloud: describe 失败不删除任何 Cloudflare 对象" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"
assert_equal "purge-cloud: describe 失败不调用 delete-certificate" "0" \
    "$(grep -c 'acm delete-certificate' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: describe 失败不调用 delete-distribution" "0" \
    "$(grep -c 'cloudfront delete-distribution' "${AWS_CALLS}" || true)"

# F5：list-tags-for-certificate 失败同样点名 ARN 并整体取消。
CALLS="${TMP_DIR}/aws-deny-tags-calls.log"
OUT="${TMP_DIR}/aws-deny-tags.out"
ERR="${TMP_DIR}/aws-deny-tags.err"
if PURGE_TEST_AWS_DENY_LISTTAGS=1 PURGE_TEST_AWS_FIXTURE_DIR="${FIXTURE_ROOT}/hosts" \
    run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: ACM list-tags 失败必须非零退出"
fi
assert_contains "purge-cloud: list-tags 失败点名被拒 ARN" \
    "$(<"${OUT}")$(<"${ERR}")" "arn:aws:acm:us-east-1:1:certificate/C1"
assert_contains "purge-cloud: list-tags 失败说明已取消清理" \
    "$(<"${OUT}")$(<"${ERR}")" "已取消清理"
assert_equal "purge-cloud: list-tags 失败不删除任何 Cloudflare 对象" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"
assert_equal "purge-cloud: list-tags 失败不调用 delete-certificate" "0" \
    "$(grep -c 'acm delete-certificate' "${AWS_CALLS}" || true)"

# 分页防护：ACM 接口重复返回同一 NextToken 时必须在第二次请求前停下，不能无限循环。
CALLS="${TMP_DIR}/aws-loop-token-calls.log"
OUT="${TMP_DIR}/aws-loop-token.out"
ERR="${TMP_DIR}/aws-loop-token.err"
if PURGE_TEST_AWS_LOOP_TOKEN=1 PURGE_TEST_AWS_FIXTURE_DIR="${FIXTURE_ROOT}/hosts" \
    run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: ACM 分页标记重复时必须非零退出"
fi
assert_contains "purge-cloud: 重复分页标记被点名" \
    "$(<"${OUT}")$(<"${ERR}")" "重复返回同一分页标记"
assert_equal "purge-cloud: 重复分页标记时只请求两次列表" "2" \
    "$(grep -c 'acm list-certificates' "${AWS_CALLS}")"
assert_equal "purge-cloud: 重复分页标记时不删除任何 Cloudflare 对象" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"
assert_equal "purge-cloud: 重复分页标记时不调用 AWS 删除接口" "0" \
    "$(grep -c 'delete-certificate\|delete-distribution' "${AWS_CALLS}" || true)"

# F1：计划后、禁用前别名被清空 → 复核必须失败，不得发出任何 update/delete。
# 漂移作用于计划产出的全部受管分发（D1/D3/D4），因此是全局 0 次。
CALLS="${TMP_DIR}/aws-drift-aliases-calls.log"
OUT="${TMP_DIR}/aws-drift-aliases.out"
ERR="${TMP_DIR}/aws-drift-aliases.err"
AWS_CALLS="${TMP_DIR}/aws-calls.log"
if PURGE_TEST_AWS_DRIFT=dist-aliases run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: 别名清空后必须非零退出"
fi
assert_equal "purge-cloud: 别名清空时不发出 update-distribution" "0" \
    "$(grep -c 'cloudfront update-distribution' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: 别名清空时不发出 delete-distribution" "0" \
    "$(grep -c 'cloudfront delete-distribution' "${AWS_CALLS}" || true)"
assert_contains "purge-cloud: 别名清空时点名分发" \
    "$(<"${OUT}")$(<"${ERR}")" "D1"
assert_contains "purge-cloud: 别名清空时说明保留" \
    "$(<"${OUT}")$(<"${ERR}")" "保留不删"

# F1：禁用 update 已发出、删除前复核时别名被清空 → D1 停在上一次 update，其余对象照常处理。
CALLS="${TMP_DIR}/aws-drift-aliases-late-calls.log"
OUT="${TMP_DIR}/aws-drift-aliases-late.out"
ERR="${TMP_DIR}/aws-drift-aliases-late.err"
if PURGE_TEST_AWS_DRIFT=dist-aliases-late run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: 删除前别名清空必须非零退出"
fi
assert_equal "purge-cloud: 删除前别名清空的 D1 已禁用一次" "1" \
    "$(grep -c 'cloudfront update-distribution --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 删除前别名清空的 D1 不删除" "0" \
    "$(grep -c 'cloudfront delete-distribution --id D1' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: 其余受管分发 D3 仍按计划删除" "1" \
    "$(grep -c 'cloudfront delete-distribution --id D3' "${AWS_CALLS}")"
assert_equal "purge-cloud: 其余受管分发 D4 仍按计划删除" "1" \
    "$(grep -c 'cloudfront delete-distribution --id D4' "${AWS_CALLS}")"
assert_contains "purge-cloud: 删除前别名清空时点名 D1" \
    "$(<"${OUT}")$(<"${ERR}")" "D1"
assert_contains "purge-cloud: 删除前别名清空时说明保留" \
    "$(<"${OUT}")$(<"${ERR}")" "保留不删"

# F2：EASY_ALL_PURGE_MAX_PAGES=1 且 CloudFront 需要 3 个服务页 → 第 2 次响应仍带截断标记，
# 必须在任何删除（含 Cloudflare 侧）之前中止，且不再继续收集 ACM。
CALLS="${TMP_DIR}/aws-max-pages-calls.log"
OUT="${TMP_DIR}/aws-max-pages.out"
ERR="${TMP_DIR}/aws-max-pages.err"
if EASY_ALL_PURGE_MAX_PAGES=1 PURGE_TEST_AWS_MULTIPAGE=dist \
    PURGE_TEST_AWS_FIXTURE_DIR="${FIXTURE_ROOT}/hosts" \
    run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all; then
    fail "purge-cloud: 扫描超过页数上限必须非零退出"
fi
assert_contains "purge-cloud: 超出页数上限时点名上限" \
    "$(<"${OUT}")$(<"${ERR}")" "扫描超过 1 页"
assert_equal "purge-cloud: 超出页数上限时只请求一页加一次探测页" "2" \
    "$(grep -c 'cloudfront list-distributions' "${AWS_CALLS}")"
assert_equal "purge-cloud: 超出页数上限时不再收集 ACM" "0" \
    "$(grep -c 'acm list-certificates' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: 超出页数上限时不调用 AWS 删除接口" "0" \
    "$(grep -cE 'cloudfront (update|delete)-distribution|acm delete-certificate' "${AWS_CALLS}" || true)"
assert_equal "purge-cloud: 超出页数上限时不删除任何 Cloudflare 对象" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"

# F2：正常多页（CloudFront 3 页 + ACM 3 页）→ 退出 0，每个对象只处理一次。
CALLS="${TMP_DIR}/aws-multipage-calls.log"
OUT="${TMP_DIR}/aws-multipage.out"
ERR="${TMP_DIR}/aws-multipage.err"
PURGE_TEST_AWS_MULTIPAGE=all run_purge_aws "${CALLS}" "${OUT}" "${ERR}" --all \
    || fail "purge-cloud: 多页清理应成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 多页时 D1 只禁用一次" "1" \
    "$(grep -c 'cloudfront update-distribution --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 D1 只删除一次" "1" \
    "$(grep -c 'cloudfront delete-distribution --id D1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 D5（第二页）只禁用一次" "1" \
    "$(grep -c 'cloudfront update-distribution --id D5' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 D5（第二页）只删除一次" "1" \
    "$(grep -c 'cloudfront delete-distribution --id D5' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 C1 只删除一次" "1" \
    "$(grep -c 'acm delete-certificate.*certificate/C1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 C5（第二页）只删除一次" "1" \
    "$(grep -c 'acm delete-certificate.*certificate/C5' "${AWS_CALLS}")"
assert_equal "purge-cloud: 计划阶段与删除前各读一次 C1 详情" "2" \
    "$(grep -c 'acm describe-certificate.*certificate/C1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 计划阶段与删除前各读一次 C5 详情" "2" \
    "$(grep -c 'acm describe-certificate.*certificate/C5' "${AWS_CALLS}")"
assert_equal "purge-cloud: 计划阶段与删除前各读一次 C1 标签" "2" \
    "$(grep -c 'acm list-tags-for-certificate.*certificate/C1' "${AWS_CALLS}")"
assert_equal "purge-cloud: 计划阶段与删除前各读一次 C5 标签" "2" \
    "$(grep -c 'acm list-tags-for-certificate.*certificate/C5' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 CloudFront 按服务页各请求一次" "3" \
    "$(grep -c 'cloudfront list-distributions' "${AWS_CALLS}")"
assert_equal "purge-cloud: 多页时 ACM 按服务页各请求一次" "3" \
    "$(grep -c 'acm list-certificates' "${AWS_CALLS}")"
assert_contains "purge-cloud: 多页清理完成计数与对象数一致" \
    "$(<"${OUT}")" "CloudFront/ACM 清理完成：4 个对象"

# A5：调用形状——每次列表都显式关掉 CLI 自动分页并携带服务端分页参数。
assert_equal "purge-cloud: 所有列表调用都带 --no-paginate" "0" \
    "$(grep -E '(cloudfront list-distributions|acm list-certificates)' "${AWS_CALLS}" \
        | grep -vc -- '--no-paginate' || true)"
cf_first=$(grep 'cloudfront list-distributions' "${AWS_CALLS}" | sed -n '1p')
acm_first=$(grep 'acm list-certificates' "${AWS_CALLS}" | sed -n '1p')
assert_contains "purge-cloud: CloudFront 首页用字符串 MaxItems=100" \
    "${cf_first}" '{"MaxItems":"100"}'
assert_contains "purge-cloud: ACM 首页用整数 MaxItems=100" \
    "${acm_first}" '{"MaxItems":100}'
assert_equal "purge-cloud: CloudFront 第二页带 Marker=P2" "1" \
    "$(grep -c 'cloudfront list-distributions --no-paginate --cli-input-json {"MaxItems":"100","Marker":"P2"}' "${AWS_CALLS}")"
assert_equal "purge-cloud: CloudFront 结束探测页带 Marker=P3" "1" \
    "$(grep -c 'cloudfront list-distributions --no-paginate --cli-input-json {"MaxItems":"100","Marker":"P3"}' "${AWS_CALLS}")"
assert_equal "purge-cloud: ACM 第二页带 NextToken=T2" "1" \
    "$(grep -c 'acm list-certificates --region us-east-1 --no-paginate --cli-input-json {"MaxItems":100,"NextToken":"T2"}' "${AWS_CALLS}")"

# 12) 参数与域名范围门禁：非法页数上限、域名零匹配都必须在任何删除之前拒绝。
CALLS="${TMP_DIR}/max-pages-zero-calls.log"
OUT="${TMP_DIR}/max-pages-zero.out"
ERR="${TMP_DIR}/max-pages-zero.err"
if run_purge "${CALLS}" "${OUT}" "${ERR}" env EASY_ALL_PURGE_MAX_PAGES=0; then
    fail "purge-cloud: EASY_ALL_PURGE_MAX_PAGES=0 必须被拒绝"
fi
assert_contains "purge-cloud: 非法页数上限提示必须是正整数" "$(<"${ERR}")" "必须是正整数"
assert_equal "purge-cloud: 非法页数上限不发起 DELETE" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"

CALLS="${TMP_DIR}/domain-nozone-calls.log"
OUT="${TMP_DIR}/domain-nozone.out"
ERR="${TMP_DIR}/domain-nozone.err"
if run_purge_domain "${CALLS}" "${OUT}" "${ERR}" "${FIXTURE_ROOT}/hosts" notinzone.example; then
    fail "purge-cloud: 域名匹配不到 Zone 时必须非零退出"
fi
assert_contains "purge-cloud: 域名零匹配时点名原因" "$(<"${ERR}")" \
    "没有找到包含这些域名的 active Zone"
assert_equal "purge-cloud: 域名零匹配时不发起 DELETE" "0" \
    "$(grep -c '^DELETE ' "${CALLS}" || true)"

# 13) B3：429 有界固定退避（5s/10s；测试用 EASY_ALL_CF_RETRY_SLEEP_OVERRIDE 注入为 0）。
CALLS="${TMP_DIR}/rate-limit-calls.log"
OUT="${TMP_DIR}/rate-limit.out"
ERR="${TMP_DIR}/rate-limit.err"
rm -f "${TMP_DIR}/429.state"
run_purge "${CALLS}" "${OUT}" "${ERR}" env \
    PURGE_TEST_429_TIMES=2 PURGE_TEST_429_STATE="${TMP_DIR}/429.state" \
    EASY_ALL_CF_RETRY_SLEEP_OVERRIDE=0 \
    || fail "purge-cloud: 429→429→200 必须在两次退避后成功：$(tail -n 3 "${ERR}")"
assert_equal "purge-cloud: 429 两次退避后第 3 次成功" "3" \
    "$(grep -c 'zones?status=active' "${CALLS}")"
assert_contains "purge-cloud: 429 退避后仍完成清理" "$(<"${OUT}")" "Cloudflare 清理完成"

# 持续 429：1 次原始 + 2 次退避后放弃，非零退出且请求数有界。
CALLS="${TMP_DIR}/rate-limit-fail-calls.log"
OUT="${TMP_DIR}/rate-limit-fail.out"
ERR="${TMP_DIR}/rate-limit-fail.err"
rm -f "${TMP_DIR}/429b.state"
if run_purge "${CALLS}" "${OUT}" "${ERR}" env \
    PURGE_TEST_429_TIMES=99 PURGE_TEST_429_STATE="${TMP_DIR}/429b.state" \
    EASY_ALL_CF_RETRY_SLEEP_OVERRIDE=0; then
    fail "purge-cloud: 持续 429 必须以非零退出"
fi
assert_equal "purge-cloud: 持续 429 只重试 2 次（请求数有界）" "3" \
    "$(grep -c 'zones?status=active' "${CALLS}")"

printf 'ok - purge-cloud\n'

# A31 阶段一：本文件必须真的跑过断言（不校验条数，只拦「一个都没跑」）。
(( TESTS_ASSERTED > 0 )) || fail "无断言执行：本文件一个断言都没跑，fixture/前置条件出错时会静默全绿"
printf 'ok - asserted %s\n' "${TESTS_ASSERTED}"
