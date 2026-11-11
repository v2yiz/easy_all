#!/usr/bin/env bash
# 阶段 1 基础库：Caddy 固定版本/清单校验、五模式 Caddyfile 结构、订阅路由与服务单元。
# 用户视角：断言生成产物与公开接口；外部边界（下载、caddy 二进制、systemctl）用替身。
set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_caddy_test.XXXXXX")
fi
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
        || fail "${label}: missing <${expected}> in <${text}>"
}
assert_not_contains() {
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] \
        || fail "${label}: unexpected <${unexpected}> in <${text}>"
}
assert_count() {
    local label=$1 text=$2 needle=$3 expected=$4 actual
    actual=$(grep -cF -- "${needle}" <<<"${text}" || true)
    [[ "${actual}" == "${expected}" ]] \
        || fail "${label}: expected ${expected} <${needle}> but got ${actual}"
}
line_of() { # $1=file $2=literal -> 首行行号
    grep -nF -- "$2" "$1" | head -n 1 | cut -d: -f1
}
assert_before() {
    local label=$1 first=$2 second=$3
    [[ -n "${first}" && -n "${second}" ]] \
        || fail "${label}: 缺少定位行（${first:-空}/${second:-空}）"
    ((first < second)) || fail "${label}: 行 ${first} 不在行 ${second} 之前"
}

CADDY_CORE="${ROOT_DIR}/lib/caddy-core.sh"
CADDY_RUNTIME="${ROOT_DIR}/lib/caddy-runtime.sh"
bash -n "${CADDY_CORE}" || fail "语法校验失败：${CADDY_CORE}"
bash -n "${CADDY_RUNTIME}" || fail "语法校验失败：${CADDY_RUNTIME}"

# --- 隔离环境 ---------------------------------------------------------------
export RUNTIME_TMP="${TMP_DIR}/runtime"
mkdir -p "${RUNTIME_TMP}"
export CADDY_BIN="${TMP_DIR}/caddy/caddy"
export CADDY_CONFIG="${TMP_DIR}/caddy/Caddyfile"
export CADDY_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-caddy.service"
export CADDY_ADMIN_SOCKET="${TMP_DIR}/run/easy_all-caddy/admin.sock"
export SUBSCRIPTION_DIR="${TMP_DIR}/subscriptions"
export CERT_FILE="${TMP_DIR}/certs/fullchain.pem"
export KEY_FILE="${TMP_DIR}/certs/private.key"
mkdir -p "${CADDY_BIN%/*}" "${TMP_DIR}/certs" "${SUBSCRIPTION_DIR}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/log.sh"
# shellcheck source=/dev/null
source "${CADDY_CORE}"
# shellcheck source=/dev/null
source "${CADDY_RUNTIME}"

PROTOCOL=cloudfront
CF_NODE_DOMAIN="cf.example.com"
SUBSCRIPTION_DOMAIN="sub.example.com"
CF_ORIGIN_DOMAIN="origin.example.com"
VLESS_PATH="/vless-abcdef123456"
ORIGIN_HEADER_SECRET="zjatxo-abcdefgh1234"
ALLOWED_TOKENS='{"owner":"tok-aaaaaaaa","friend":"tok-bbbbbbbb"}'
SUB_DOWNLOAD_NAME="EASY_ALL"
SUBSCRIPTION_MODE=deploy

# --- 固定常量 ---------------------------------------------------------------
assert_equal "Caddy 锁定版本" "2.11.9" "${CADDY_VERSION}"
assert_equal "Caddy 版本接口" "2.11.9" "$(caddy_version)"
assert_equal "Caddy amd64 SHA512" \
    "0e85544340290a16ce4bfb76fe7d65e9de1bf3a6e67f5ccfff30b30d27ea4c73e078077b7bf3e58ae60b6b12e44327705287059c775bca5782e8ee85ea7edd75" \
    "$(caddy_expected_sha512 amd64)"
assert_equal "Caddy arm64 SHA512" \
    "9e5e76d7888542924de2c25353ae87c5f77e2a22c5b1198633cae13688922282e05383d142599205c88d8d80eee5e967d291214d7abce4835329a191b20dd6e0" \
    "$(caddy_expected_sha512 arm64)"
assert_equal "amd64 映射" "amd64" "$(caddy_arch x86_64)"
assert_equal "aarch64 映射" "arm64" "$(caddy_arch aarch64)"
assert_equal "amd64 归档名" "caddy_2.11.9_linux_amd64.tar.gz" "$(caddy_archive_name amd64)"
assert_equal "amd64 归档 URL" \
    "https://github.com/caddyserver/caddy/releases/download/v2.11.9/caddy_2.11.9_linux_amd64.tar.gz" \
    "$(caddy_archive_url amd64)"
assert_equal "清单 URL" \
    "https://github.com/caddyserver/caddy/releases/download/v2.11.9/caddy_2.11.9_checksums.txt" \
    "$(caddy_checksums_url)"
if (caddy_arch mips) >/dev/null 2>&1; then
    fail "未知架构必须失败"
fi

# --- 五模式站点 -------------------------------------------------------------
render_caddy() { # $1=protocol $2=blocked $3=subscription_ok -> stdout
    local out="${TMP_DIR}/Caddyfile-$1-$2-$3"
    rm -f -- "${out}"
    ( PROTOCOL=$1; render_caddy_config "${out}" "$2" "$3" ) \
        || fail "渲染失败：$1 blocked=$2 subscription_ok=$3"
    cat "${out}"
}

anytls_body=$(render_caddy anytls 0 1)
cloudfront_body=$(render_caddy cloudfront 0 1)
cloudflare_body=$(render_caddy cloudflare 0 1)
combined_body=$(render_caddy combined-cloudfront 0 1)
combined_cf_body=$(render_caddy combined-cloudflare 0 1)

for body_proto in anytls cloudfront cloudflare combined-cloudfront combined-cloudflare; do
    case "${body_proto}" in
    anytls) body=${anytls_body} ;;
    cloudfront) body=${cloudfront_body} ;;
    cloudflare) body=${cloudflare_body} ;;
    combined-cloudfront) body=${combined_body} ;;
    *) body=${combined_cf_body} ;;
    esac
    assert_contains "${body_proto}: 管理套接字" "${body}" "admin unix/${CADDY_ADMIN_SOCKET}"
    assert_contains "${body_proto}: 关闭自动 HTTPS" "${body}" "auto_https off"
    assert_contains "${body_proto}: 只提供 h1/h2" "${body}" "protocols h1 h2"
    assert_not_contains "${body_proto}: 不提供 h3" "${body}" "h3"
    assert_contains "${body_proto}: 绑定 0.0.0.0" "${body}" "bind 0.0.0.0"
    assert_contains "${body_proto}: 显式证书" "${body}" "tls ${CERT_FILE} ${KEY_FILE}"
    assert_contains "${body_proto}: 精确订阅入口" "${body}" "@easy_all_sub path /subscribe /sub"
    assert_not_contains "${body_proto}: 订阅不做前缀匹配" "${body}" "path /subscribe*"
    assert_not_contains "${body_proto}: 不用 query 匹配器取首值" "${body}" "query flag"
    assert_contains "${body_proto}: health 探针" "${body}" 'respond @easy_all_health "easy_all ok" 200'
    assert_contains "${body_proto}: 其他路径 404" "${body}" "respond 404"
done

assert_contains "模式 1 站点：订阅域名 8443" "${anytls_body}" "https://sub.example.com:8443 {"
assert_not_contains "模式 1 无源站守卫" "${anytls_body}" "@easy_all_bad_origin"
assert_not_contains "模式 1 无 CDN 代理路径" "${anytls_body}" "reverse_proxy"
assert_contains "模式 2 站点：源站 443" "${cloudfront_body}" "https://origin.example.com:443 {"
assert_contains "模式 2 有源站守卫" "${cloudfront_body}" \
    "@easy_all_bad_origin expression {http.request.header.X-Easy-All-Origin-Key} != '${ORIGIN_HEADER_SECRET}'"
assert_contains "模式 2 守卫终止连接" "${cloudfront_body}" "abort @easy_all_bad_origin"
assert_contains "模式 2 精确代理路径" "${cloudfront_body}" "handle ${VLESS_PATH} {"
assert_not_contains "模式 2 代理路径不是前缀匹配" "${cloudfront_body}" "handle ${VLESS_PATH}*"
assert_contains "模式 2 转发到回环" "${cloudfront_body}" "reverse_proxy 127.0.0.1:10086"
assert_contains "模式 3 站点：节点域 443" "${cloudflare_body}" "https://cf.example.com:443 {"
assert_not_contains "模式 3 无源站守卫" "${cloudflare_body}" "@easy_all_bad_origin"
assert_contains "模式 3 代理路径" "${cloudflare_body}" "handle ${VLESS_PATH} {"
assert_contains "模式 4 站点：源站 8443" "${combined_body}" "https://origin.example.com:8443 {"
assert_contains "模式 4 有源站守卫" "${combined_body}" "abort @easy_all_bad_origin"
assert_contains "模式 4 代理路径" "${combined_body}" "handle ${VLESS_PATH} {"
assert_contains "模式 5 站点：节点域 8443" "${combined_cf_body}" "https://cf.example.com:8443 {"
assert_not_contains "模式 5 无源站守卫" "${combined_cf_body}" "@easy_all_bad_origin"
assert_contains "模式 5 代理路径" "${combined_cf_body}" "handle ${VLESS_PATH} {"
assert_contains "模式 5 转发到回环" "${combined_cf_body}" "reverse_proxy 127.0.0.1:10086"

# 守卫必须是外层 route 的首个指令，且早于代理路径与订阅入口。
guard_line=$(grep -nF "@easy_all_bad_origin expression" "${TMP_DIR}/Caddyfile-cloudfront-0-1" \
    | head -n 1 | cut -d: -f1)
route_line=$(line_of "${TMP_DIR}/Caddyfile-cloudfront-0-1" "route {")
assert_equal "守卫紧跟外层 route" "$((route_line + 1))" "${guard_line}"
assert_before "守卫早于代理路径" "${guard_line}" \
    "$(line_of "${TMP_DIR}/Caddyfile-cloudfront-0-1" "handle ${VLESS_PATH} {")"
assert_before "守卫早于订阅入口" "${guard_line}" \
    "$(line_of "${TMP_DIR}/Caddyfile-cloudfront-0-1" "handle @easy_all_sub {")"

# --- 订阅路由 ---------------------------------------------------------------
ready_body=${combined_body}
assert_contains "公共头 Vary" "${ready_body}" 'header Vary "User-Agent"'
assert_contains "公共 Cache-Control" "${ready_body}" \
    'header Cache-Control "no-store, no-cache, must-revalidate, max-age=0"'
assert_contains "公共 Pragma" "${ready_body}" 'header Pragma "no-cache"'
assert_contains "公共 X-Content-Type-Options" "${ready_body}" 'header X-Content-Type-Options "nosniff"'
assert_contains "公共 X-Robots-Tag" "${ready_body}" \
    'header X-Robots-Tag "noindex, nofollow, noarchive"'
assert_contains "非 GET/HEAD 返回 405" "${ready_body}" "respond @easy_all_sub_bad_method 405"
assert_contains "非法 Token 返回 403" "${ready_body}" "respond @easy_all_sub_denied 403"
assert_contains "Token 精确列表来自 ALLOWED_TOKENS" "${ready_body}" \
    "{query.token} in ['tok-aaaaaaaa','tok-bbbbbbbb']"

ready_file="${TMP_DIR}/Caddyfile-combined-cloudfront-0-1"
assert_before "公共头先于方法校验" "$(line_of "${ready_file}" 'header Vary "User-Agent"')" \
    "$(line_of "${ready_file}" "respond @easy_all_sub_bad_method 405")"
assert_before "方法校验先于 Token 校验" "$(line_of "${ready_file}" "respond @easy_all_sub_bad_method 405")" \
    "$(line_of "${ready_file}" "respond @easy_all_sub_denied 403")"
assert_before "Token 校验先于协商" "$(line_of "${ready_file}" "respond @easy_all_sub_denied 403")" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_yaml_flag {")"
assert_count "订阅处理器只有一处 file_server" "${ready_body}" "file_server" 1
assert_before "file_server 在订阅处理器内" "$(line_of "${ready_file}" "handle @easy_all_sub {")" \
    "$(line_of "${ready_file}" "file_server")"

# 八产物：YAML 两个入口（flag 与 Clash UA）、Base64 两个入口、sing-box JSON 一个入口。
while IFS='|' read -r artifact expected; do
    assert_count "产物 ${artifact}" "${ready_body}" "rewrite * ${artifact}" "${expected}"
done <<'ARTIFACTS'
/mihomo.yaml|2
/mihomo-ios.yaml|2
/mihomo-all.yaml|2
/mihomo-ios-all.yaml|2
/base64.txt|2
/base64-all.txt|2
/singbox.json|1
/singbox-all.json|1
ARTIFACTS
assert_before "YAML 先于 iOS 分支" "$(line_of "${ready_file}" "handle @easy_all_sub_yaml_flag {")" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_ios {")"
assert_before "iOS 先于 all 分支" "$(line_of "${ready_file}" "handle @easy_all_sub_ios {")" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_all {")"
assert_count "Content-Disposition 只出现在 YAML 与 JSON 分支" "${ready_body}" "Content-Disposition" 3
assert_contains "YAML 下载文件名来自 SUB_DOWNLOAD_NAME" "${ready_body}" \
    'header Content-Disposition "attachment; filename=EASY_ALL"'
assert_contains "JSON 下载文件名追加 .json" "${ready_body}" \
    'header Content-Disposition "attachment; filename=EASY_ALL.json"'
assert_contains "JSON 响应类型" "${ready_body}" \
    'header Content-Type "application/json; charset=utf-8"'
assert_before "Content-Disposition 早于 YAML 分支" \
    "$(line_of "${ready_file}" "Content-Disposition")" \
    "$(line_of "${ready_file}" "rewrite * /mihomo.yaml")"

# JSON 分支：flag 优先于 UA，缺失产物返回 503，且不降级到其他格式。
assert_contains "flag 强制 JSON 列表" "${ready_body}" "{query.flag}.lowerAscii() in ['singbox','sing-box']"
# 六个已确认官方客户端前缀逐个验收，SFT（tvOS）只能手动创建远程配置，最依赖远程 JSON。
for client in sfa sfi sfm sft sfw sfl; do
    assert_contains "已确认 ${client} UA 自动识别" "${ready_body}" \
        ".startsWith('${client} (sing-box ')"
done
assert_not_contains "不对任意 sing-box UA 通配" "${ready_body}" "matches('.*sing-box.*')"
assert_contains "JSON 缺失返回 503" "${ready_body}" "respond @easy_all_sub_json_missing 503"
assert_contains "JSON all 缺失返回 503" "${ready_body}" "respond @easy_all_sub_json_all_missing 503"
assert_contains "JSON 缺失判定用 file 匹配器" "${ready_body}" "not file /singbox.json"
assert_before "YAML flag 先于 Base64 flag" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_yaml_flag {")" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_base64_flag {")"
assert_before "Base64 flag 先于 JSON 分支" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_base64_flag {")" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_singbox {")"
assert_before "JSON 分支先于 Clash UA 分支" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_singbox {")" \
    "$(line_of "${ready_file}" "handle @easy_all_sub_yaml_ua {")"

# 协商矩阵：flag 显式覆盖 UA，UA 回落，os/node 大小写不敏感，重复参数不命中显式分支。
assert_contains "flag 强制 YAML 列表" "${ready_body}" \
    "{query.flag}.lowerAscii() in ['clash','mihomo','meta','stash','yaml']"
assert_contains "flag 强制 Base64 列表" "${ready_body}" \
    "['base64','uri','v2ray','shadowrocket']"
assert_contains "UA 回落命中 YAML 客户端" "${ready_body}" \
    "matches('.*(clash|mihomo|stash|flclash|verge|bettbox).*')"
assert_contains "os=ios 显式判定" "${ready_body}" "{query.os}.lowerAscii() in ['ios','iphone','ipad']"
assert_contains "UA 独立 ios 单词" "${ready_body}" "(^|[^a-z])ios([^a-z]|$)"
assert_contains "node=all 使用完整取值" "${ready_body}" \
    "@easy_all_sub_all expression {query.node}.lowerAscii() == 'all'"
assert_contains "重复 token 逗号拼接后不在列表" "${ready_body}" "!({query.token} in ["

# 未就绪与阻断
unready_body=$(render_caddy combined-cloudfront 0 0)
assert_contains "订阅未就绪返回 503" "${unready_body}" "respond 503"
assert_not_contains "未就绪不下发产物" "${unready_body}" "rewrite *"
assert_not_contains "未就绪不暴露 file_server" "${unready_body}" "file_server"
assert_not_contains "未就绪不下发 Content-Disposition" "${unready_body}" "Content-Disposition"

blocked_body=$(render_caddy cloudfront 1 1)
assert_contains "阻断时代理路径 503" "${blocked_body}" "respond 503"
assert_not_contains "阻断时不转发回环" "${blocked_body}" "reverse_proxy"
assert_contains "阻断不影响订阅" "${blocked_body}" "respond @easy_all_sub_denied 403"

# --- 输入校验 ---------------------------------------------------------------
if (PROTOCOL=anytls; SUBSCRIPTION_MODE=link; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "模式 1 link 不得生成 Caddy 站点"
fi
if (PROTOCOL=cloudfront; CF_ORIGIN_DOMAIN=""; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "模式 2 缺少源站域名必须失败"
fi
if (PROTOCOL=cloudfront; ORIGIN_HEADER_SECRET=""; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "缺少源站头密钥必须失败"
fi
if (PROTOCOL=cloudfront; ORIGIN_HEADER_SECRET="short"; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "过短源站头密钥必须失败"
fi
if (PROTOCOL=cloudfront; ORIGIN_HEADER_SECRET="x'y1234567890abcd"; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "含引号的源站头密钥必须失败"
fi
if (PROTOCOL=cloudfront; VLESS_PATH="vless-noslash"; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "缺少前导斜杠的路径必须失败"
fi
if (PROTOCOL=cloudfront; VLESS_PATH="/vless-*"; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "含通配符的路径必须失败"
fi
if (ALLOWED_TOKENS='{"owner":"tok-a'"'"'inject"}'; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "含引号的 Token 必须失败"
fi
if (ALLOWED_TOKENS=''; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "缺少 Token 字典必须失败"
fi
if (SUB_DOWNLOAD_NAME='has space'; render_caddy_config "${TMP_DIR}/x" 0 1) >/dev/null 2>&1; then
    fail "非法下载文件名必须失败"
fi
if (PROTOCOL=cloudfront; render_caddy_config "${TMP_DIR}/x" 2 1) >/dev/null 2>&1; then
    fail "非法 blocked 取值必须失败"
fi
if (PROTOCOL=cloudfront; render_caddy_config "${TMP_DIR}/x" 0 7) >/dev/null 2>&1; then
    fail "非法订阅就绪取值必须失败"
fi

# --- 校验与写入 -------------------------------------------------------------
# 没有 caddy 二进制时只做结构断言。
export CADDY_BIN_ABSENT="${TMP_DIR}/absent/caddy"
(
    CADDY_BIN=${CADDY_BIN_ABSENT}
    validate_caddy_config "${ready_file}" || exit 1
    tampered_file_server="${TMP_DIR}/tampered-file-server"
    awk '{print} /^\tservers \{$/ {print "\tfile_server"}' "${ready_file}" >"${tampered_file_server}"
    validate_caddy_config "${tampered_file_server}" >/dev/null 2>&1 && exit 1
    tampered_path="${TMP_DIR}/tampered-path"
    sed 's|@easy_all_sub path /subscribe /sub|@easy_all_sub path /subscribe*|' \
        "${ready_file}" >"${tampered_path}"
    validate_caddy_config "${tampered_path}" >/dev/null 2>&1 && exit 1
    exit 0
) || fail "无二进制时的结构校验行为不符合预期"

CADDY_LOG="${TMP_DIR}/caddy.log"
cat >"${CADDY_BIN}" <<'FAKE_CADDY'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_CADDY_LOG}"
case "${1:-}" in
validate)
    # 真实 caddy 失败时把错误写在 stderr；替身必须保留这个契约才能断言回显。
    if [[ "${FAKE_CADDY_STATUS:-0}" != "0" ]]; then
        printf 'Error: adapting config using caddyfile: unexpected end of input\n' >&2
    fi
    exit "${FAKE_CADDY_STATUS:-0}"
    ;;
version) printf 'v2.11.9 h1:test\n' ;;
reload) exit 0 ;;
esac
FAKE_CADDY
chmod +x "${CADDY_BIN}"
export FAKE_CADDY_LOG="${CADDY_LOG}"
: >"${CADDY_LOG}"
validate_caddy_config "${ready_file}" || fail "caddy validate 成功时校验应通过"
assert_equal "调用 caddy validate" \
    "validate --adapter caddyfile --config ${ready_file}" "$(<"${CADDY_LOG}")"
validate_fail_stderr="${TMP_DIR}/validate-fail.stderr"
validate_fail_stdout="${TMP_DIR}/validate-fail.stdout"
if (export FAKE_CADDY_STATUS=1; validate_caddy_config "${ready_file}") \
    >"${validate_fail_stdout}" 2>"${validate_fail_stderr}"; then
    fail "caddy validate 失败时必须失败"
fi
# 失败原因必须回显到 stderr：候选文件退出后就被删，用户看不到就是黑屏失败。
assert_contains "校验失败回显 validator 的 stderr" "$(<"${validate_fail_stderr}")" \
    "Error: adapting config using caddyfile: unexpected end of input"
assert_equal "校验失败不往 stdout 写错误" "" "$(<"${validate_fail_stdout}")"
assert_equal "已安装版本来自 caddy 自报" "v2.11.9" "$(caddy_installed_version)"

write_caddy_config 0 1
assert_equal "写入配置权限 0600" "-rw-------" \
    "$(ls -ld -- "${CADDY_CONFIG}" | awk '{print $1}' | sed 's/[^drwx-]//g')"
written=$(<"${CADDY_CONFIG}")
assert_contains "写入的是当前模式站点" "${written}" "https://origin.example.com:443 {"
assert_equal "写入不留下暂存文件" "" \
    "$(find "${CADDY_CONFIG%/*}" -name 'Caddyfile.*' | tr '\n' ' ')"

# 候选文案不得点名退出后会被删除的 Caddyfile.next：失败原因只给 validator 输出与稳定描述。
candidate_next="${RUNTIME_TMP}/Caddyfile.next"
rm -f -- "${candidate_next}"
missing_stderr="${TMP_DIR}/candidate-missing.stderr"
if validate_caddy_config "${candidate_next}" \
    >"${TMP_DIR}/candidate-missing.stdout" 2>"${missing_stderr}"; then
    fail "候选缺失时必须失败"
fi
assert_contains "候选缺失文案" "$(<"${missing_stderr}")" "Caddy 配置不存在或为空"
assert_not_contains "候选缺失不点名临时路径" "$(<"${missing_stderr}")" "Caddyfile.next"

awk '{print} /^\tservers \{$/ {print "\tfile_server"}' "${ready_file}" >"${candidate_next}"
structure_stderr="${TMP_DIR}/candidate-structure.stderr"
if (CADDY_BIN="${CADDY_BIN_ABSENT}"; validate_caddy_config "${candidate_next}") \
    >"${TMP_DIR}/candidate-structure.stdout" 2>"${structure_stderr}"; then
    fail "结构损坏的候选必须失败"
fi
assert_contains "结构失败文案" "$(<"${structure_stderr}")" "Caddy 配置结构校验失败"
assert_not_contains "结构失败不点名临时路径" "$(<"${structure_stderr}")" "Caddyfile.next"

rm -f -- "${candidate_next}"
wrapper_stderr="${TMP_DIR}/candidate-wrapper.stderr"
if (export FAKE_CADDY_STATUS=1; write_caddy_config 0 1) \
    >"${TMP_DIR}/candidate-wrapper.stdout" 2>"${wrapper_stderr}"; then
    fail "write_caddy_config 在候选校验失败时必须失败"
fi
assert_contains "候选校验失败回显 validator" "$(<"${wrapper_stderr}")" \
    "Error: adapting config using caddyfile: unexpected end of input"
assert_contains "候选校验失败文案" "$(<"${wrapper_stderr}")" \
    "候选 Caddy 配置校验失败（候选文件随本次运行结束删除）"
assert_not_contains "候选校验失败不点名临时路径" "$(<"${wrapper_stderr}")" "Caddyfile.next"

# 有真实 caddy 时用官方二进制复核五种模式的语法。
if command -v caddy >/dev/null 2>&1; then
    for body_file in "${TMP_DIR}"/Caddyfile-{anytls,cloudfront,cloudflare,combined-cloudfront,combined-cloudflare}-0-1; do
        caddy validate --adapter caddyfile --config "${body_file}" >/dev/null 2>&1 \
            || fail "真实 caddy validate 失败：${body_file}"
    done
fi

# --- 服务单元 ---------------------------------------------------------------
SYSTEMCTL_LOG="${TMP_DIR}/systemctl.log"
systemctl() {
    printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
    return 0
}
: >"${SYSTEMCTL_LOG}"
install_caddy_service
unit=$(<"${CADDY_SERVICE_FILE}")
assert_contains "单元以 root 运行" "${unit}" "User=root"
assert_contains "运行目录" "${unit}" "RuntimeDirectory=easy_all-caddy"
assert_contains "运行目录权限" "${unit}" "RuntimeDirectoryMode=0700"
assert_contains "启动参数" "${unit}" \
    "ExecStart=${CADDY_BIN} run --config ${CADDY_CONFIG} --adapter caddyfile"
assert_contains "失败重启" "${unit}" "Restart=on-failure"
assert_equal "安装单元不启停服务" "" "$(<"${SYSTEMCTL_LOG}")"

# --- 重载：只用管理套接字，不改动服务 ---------------------------------------
RELOAD_CADDY_LOG="${CADDY_LOG}"
systemctl() {
    printf '%s\n' "$*" >>"${SYSTEMCTL_LOG}"
    [[ "$1" != "is-active" ]] || return "${FAKE_SERVICE_ACTIVE:-0}"
    return 0
}
: >"${SYSTEMCTL_LOG}"
: >"${RELOAD_CADDY_LOG}"
reload_caddy || fail "服务运行时应重载 Caddy"
assert_equal "通过管理套接字重载" \
    "reload --address unix/${CADDY_ADMIN_SOCKET} --config ${CADDY_CONFIG} --adapter caddyfile" \
    "$(<"${RELOAD_CADDY_LOG}")"
assert_not_contains "重载不重启服务" "$(<"${SYSTEMCTL_LOG}")" "restart"
assert_not_contains "重载不停止服务" "$(<"${SYSTEMCTL_LOG}")" "stop"

: >"${RELOAD_CADDY_LOG}"
: >"${SYSTEMCTL_LOG}"
( export FAKE_SERVICE_ACTIVE=3; reload_caddy ) >/dev/null 2>&1 \
    || fail "服务未运行时应只提示不失败"
assert_equal "服务未运行时不重载" "" "$(<"${RELOAD_CADDY_LOG}")"
assert_not_contains "服务未运行时不启动服务" "$(<"${SYSTEMCTL_LOG}")" "start"

# --- 下载校验 ---------------------------------------------------------------
case "$(uname -m)" in
x86_64 | amd64) TEST_ARCH=amd64 ;;
aarch64 | arm64) TEST_ARCH=arm64 ;;
*) fail "测试机器架构不在锁定范围内：$(uname -m)" ;;
esac
archive_name=$(caddy_archive_name "${TEST_ARCH}")
archive_root="${TMP_DIR}/caddy-archive"
mkdir -p "${archive_root}/caddy"
cat >"${archive_root}/caddy/caddy" <<'FAKE_RELEASE'
#!/usr/bin/env bash
if [[ "${1:-}" == "version" ]]; then
    printf 'v2.11.9 h1:testsignature\n'
    exit 0
fi
exit 0
FAKE_RELEASE
chmod +x "${archive_root}/caddy/caddy"
fake_archive="${TMP_DIR}/${archive_name}"
tar -czf "${fake_archive}" -C "${archive_root}" caddy || fail "无法构造测试归档"
fake_sha=$(openssl dgst -sha512 "${fake_archive}" | awk '{print $NF}')
frozen_sha=$(caddy_expected_sha512 "${TEST_ARCH}")
checksums_file="${TMP_DIR}/checksums.txt"
curl_log="${TMP_DIR}/caddy-curl.log"

caddy_download_case() { # $1=清单内容 $2=期望摘要覆盖（空=用锁定常量）
    local manifest=$1 override=$2 status=0
    printf '%s' "${manifest}" >"${checksums_file}"
    (
        : >"${curl_log}"
        curl() {
            local arg out="" expect_out=0 url=""
            for arg in "$@"; do
                if ((expect_out == 1)); then
                    out=${arg}
                    expect_out=0
                    continue
                fi
                if [[ "${arg}" == "-o" ]]; then
                    expect_out=1
                    continue
                fi
                case "${arg}" in
                https://*) url=${arg} ;;
                esac
            done
            printf '%s\n' "${url}" >>"${curl_log}"
            [[ -n "${out}" ]] || return 1
            case "${url}" in
            *checksums.txt) cp "${checksums_file}" "${out}" ;;
            *.tar.gz) cp "${fake_archive}" "${out}" ;;
            *) return 1 ;;
            esac
        }
        if [[ -n "${override}" ]]; then
            caddy_expected_sha512() { printf '%s\n' "${override}"; }
        fi
        download_caddy
    ) >/dev/null 2>&1 || status=$?
    printf '%s' "${status}"
}

printf 'old-caddy\n' >"${CADDY_BIN}"
chmod 0755 "${CADDY_BIN}"
assert_equal "清单与锁定常量一致时安装成功" "0" \
    "$(caddy_download_case "${fake_sha}  ${archive_name}" "${fake_sha}")"
[[ -x "${CADDY_BIN}" ]] || fail "下载后 caddy 必须可执行"
assert_equal "安装后版本" "v2.11.9" "$(caddy_installed_version)"
assert_contains "先取官方清单" "$(<"${curl_log}")" "caddy_2.11.9_checksums.txt"
assert_contains "再取本机架构归档" "$(<"${curl_log}")" "${archive_name}"

reset_old_caddy() {
    printf 'old-caddy\n' >"${CADDY_BIN}"
    chmod 0755 "${CADDY_BIN}"
}
assert_missing_ok() {
    local label=$1 status=$2
    [[ "${status}" != "0" ]] || fail "${label}: 必须失败"
    assert_equal "${label}: 保留旧二进制" "old-caddy" "$(<"${CADDY_BIN}")"
}

reset_old_caddy
assert_missing_ok "清单摘要与锁定常量不一致" \
    "$(caddy_download_case "${frozen_sha}  ${archive_name}" "")"
reset_old_caddy
assert_missing_ok "归档与清单摘要不符" \
    "$(caddy_download_case "${frozen_sha}  ${archive_name}" "${frozen_sha}")"
reset_old_caddy
assert_missing_ok "清单缺少本机架构条目" \
    "$(caddy_download_case "${fake_sha}  caddy_2.11.9_linux_other.tar.gz" "${fake_sha}")"
reset_old_caddy
assert_missing_ok "清单条目重复" \
    "$(caddy_download_case "${fake_sha}  ${archive_name}
${fake_sha}  ${archive_name}" "${fake_sha}")"
reset_old_caddy
assert_missing_ok "清单摘要格式非法" \
    "$(caddy_download_case "$(printf 'z%.0s' $(seq 1 128))  ${archive_name}" "${fake_sha}")"
reset_old_caddy
assert_missing_ok "清单为空" "$(caddy_download_case "" "${fake_sha}")"

# --- package.json 接线 -------------------------------------------------------
assert_contains "npm test 串入 Caddy 渲染测试" \
    "$(<"${ROOT_DIR}/package.json")" "test/test_caddy_render.sh"

printf 'ok - Caddy 基础库测试通过\n'
