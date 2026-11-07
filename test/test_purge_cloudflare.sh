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
printf '%s\n' "${url}" >>"${PURGE_TEST_CALLS}"
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

run_purge() {
    local calls=$1 out=$2 err=$3
    shift 3
    : >"${calls}"
    PATH="${TMP_DIR}/bin:${PATH}" \
        CLOUDFLARE_API_TOKEN="${TOKEN}" \
        TMPDIR="${TMP_DIR}" \
        PURGE_TEST_CALLS="${calls}" \
        PURGE_TEST_COUNTER="${TMP_DIR}/counter" \
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

printf 'ok - purge-cloudflare\n'
