#!/usr/bin/env bash
# 中断安装自愈的单元测试：端口守卫分类、残留识别与安装进度标记。
set -Eeuo pipefail

# A31 阶段一：断言计数器，防止整个文件静默空跑（fixture 出错时最容易全绿）。
TESTS_ASSERTED=0

# A32：skip 必须同时可见（stdout）并计入文件尾「未验证项」汇总——只写 stderr 的 skip
# 在 CI 日志里会被吞掉，读者会以为覆盖完整。
SKIPPED_ITEMS=()
skip_case() { # $1=用例名 $2=原因
    SKIPPED_ITEMS+=("$1：$2")
    printf 'skip - %s：%s\n' "$1" "$2"
}

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 && pwd)
# macOS 的 mktemp 忽略 TMPDIR，受限环境里用户临时目录可能不可写；退回显式模板。
TMP_DIR=$(mktemp -d 2>/dev/null || true)
if [[ -z "${TMP_DIR}" ]]; then
    TMP_DIR=$(mktemp -d "${TMP_ROOT_FALLBACK:-/tmp}/easy_all_test.XXXXXX")
fi
trap 'rm -rf -- "${TMP_DIR}"' EXIT

fail() {
    printf 'not ok - %s\n' "$*" >&2
    exit 1
}

assert_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 text=$2 expected=$3
    [[ "${text}" == *"${expected}"* ]] || fail "${label}: missing <${expected}> in <${text}>"
}

assert_not_contains() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 text=$2 unexpected=$3
    [[ "${text}" != *"${unexpected}"* ]] || fail "${label}: unexpected <${unexpected}> in <${text}>"
}

assert_equal() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1))
    local label=$1 expected=$2 actual=$3
    [[ "${expected}" == "${actual}" ]] || fail "${label}: expected <${expected}> but got <${actual}>"
}

# 隔离全部外部依赖：路径走临时目录，ss 用可编程的假命令。
export RUNTIME_TMP="${TMP_DIR}/runtime"
mkdir -p "${RUNTIME_TMP}"
export EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/progress/install-progress.env"
export EASY_ALL_GUARD_STATE_DIR="${TMP_DIR}/state"
export EASY_ALL_GUARD_STATE_FILE="${TMP_DIR}/state/state.env"
export EASY_ALL_GUARD_SERVICE_FILE="${TMP_DIR}/systemd/easy_all-singbox.service"
export EASY_ALL_GUARD_CADDY_CONFIG="${TMP_DIR}/caddy/Caddyfile"
export EASY_ALL_SS_CMD_OVERRIDE="${TMP_DIR}/fake-ss"
export FAKE_SS_BUSY_PORTS="${TMP_DIR}/fake-ss-busy"
export FAKE_SS_OWNER=nginx

printf '#!/usr/bin/env bash\n' >"${EASY_ALL_SS_CMD_OVERRIDE}"
printf 'set -Eeuo pipefail\n' >>"${EASY_ALL_SS_CMD_OVERRIDE}"
cat >>"${EASY_ALL_SS_CMD_OVERRIDE}" <<'FAKE_SS'
port=${!#}
port=${port##*:}
[[ -f "${FAKE_SS_BUSY_PORTS}" ]] || exit 0
grep -qx -- "${port}" "${FAKE_SS_BUSY_PORTS}" || exit 0
if [[ " $* " == *" -ltnp "* ]]; then
    # FAKE_SS_OWNER=@none 模拟普通用户看不到进程归属（ss 无 users 字段）
    if [[ "${FAKE_SS_OWNER:-nginx}" == "@none" ]]; then
        printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:*\n' "${port}"
    else
        printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:* users:(("%s",pid=4242,fd=6))\n' \
            "${port}" "${FAKE_SS_OWNER:-nginx}"
    fi
else
    printf 'LISTEN 0 511 0.0.0.0:%s 0.0.0.0:*\n' "${port}"
fi
FAKE_SS
chmod +x "${EASY_ALL_SS_CMD_OVERRIDE}"

# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/log.sh"
EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
# 状态 schema 常量与字段集是单一来源：profile-common 的进度/身份写入直接使用它们。
# shellcheck source=lib/state.sh
source "${ROOT_DIR}/lib/state.sh"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/profile-common.sh"

# die 只退出当前子 shell：capture() 用 $( ) 包起来即可拿到消息与状态。
die() { printf '%s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }

busy() { printf '%s\n' "$@" >"${FAKE_SS_BUSY_PORTS}"; }
idle() { rm -f -- "${FAKE_SS_BUSY_PORTS}"; }
reset_artifacts() {
    rm -rf -- "${TMP_DIR}/state" "${TMP_DIR}/systemd" "${TMP_DIR}/caddy" \
        "${TMP_DIR}/progress"
}
capture() {
    local output status=0
    output=$("$@" 2>&1) || status=$?
    printf '%s' "${output}"
    return "${status}"
}

# 1. 端口空闲时不报错
idle
reset_artifacts
assert_equal "idle port passes" "0" "$(assert_install_ports_free 80 443 >/dev/null 2>&1 && echo 0 || echo 1)"

# 1b. 调用方会把多端口字符串作为一个参数传入（模式 5 的 "443 8443"）：
#     整串交给 ss 会拼出非法表达式并被 2>/dev/null 吞掉，端口占用检查会静默失效。
busy 8443
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free "443 8443" || true)
assert_contains "多端口字符串必须逐端口检查" "${output}" "TCP 8443 已被占用"
idle

# 2. 第三方占用保持原文案，并点名占用进程
busy 80
FAKE_SS_OWNER=sshd
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "third-party owner is reported" "${output}" "sshd"
assert_contains "third-party keeps original hint" "${output}" "easy_all 仅支持专用 VPS"
assert_not_contains "third-party is not called residue" "${output}" "cleanup-partial"

# 3. 自身残留占用：给出去残留指引而不是「仅支持专用 VPS」
install_progress_begin combined-cloudfront
install_progress_stage packages
busy 80
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "residue guidance is offered" "${output}" "cleanup-partial"
assert_contains "residue reports the stage" "${output}" "packages"
assert_not_contains "residue is not blamed on a dedicated VPS" "${output}" "仅支持专用 VPS"

# 4. 已安装状态（存在状态文件）永不判为残留
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}"
: >"${EASY_ALL_GUARD_STATE_FILE}"
mkdir -p "$(dirname "${EASY_ALL_GUARD_CADDY_CONFIG}")"
: >"${EASY_ALL_GUARD_CADDY_CONFIG}"
assert_equal "installed state is never residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
output=$(capture assert_install_ports_free 80 || true)
assert_contains "installed-but-busy port still warns" "${output}" "easy_all 仅支持专用 VPS"

# 5. 残留识别：状态目录、服务单元、Caddy 配置、进度标记
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}"
assert_equal "empty state dir alone is not residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
: >"${EASY_ALL_GUARD_STATE_DIR}/runtime-write.lock"
assert_equal "state dir with only the write lock is not residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray"
output=$(capture install_residue_reason || true)
assert_contains "state dir with content is residue" "${output}" "未完成的状态目录"

rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"
mkdir -p "$(dirname "${EASY_ALL_GUARD_SERVICE_FILE}")"
: >"${EASY_ALL_GUARD_SERVICE_FILE}"
output=$(capture install_residue_reason || true)
assert_contains "leftover unit file is residue" "${output}" "残留服务单元"

rm -f -- "${EASY_ALL_GUARD_SERVICE_FILE}"
mkdir -p "$(dirname "${EASY_ALL_GUARD_CADDY_CONFIG}")"
: >"${EASY_ALL_GUARD_CADDY_CONFIG}"
output=$(capture install_residue_reason || true)
assert_contains "leftover caddy config is residue" "${output}" "残留 Caddy 配置"

rm -f -- "${EASY_ALL_GUARD_CADDY_CONFIG}"
assert_equal "clean host has no residue" "1" \
    "$(install_residue_reason >/dev/null 2>&1 && echo 0 || echo 1)"

# 5b. 旧 FQ helper 把开机快照放在了业务 STATE_DIR/backups/qdisc：卸载后只剩这条
#     严格空链时不能把机器当成“未完成安装”（否则永远无法重新安装）。
residue_present() {
    install_residue_reason >/dev/null 2>&1 && printf '0' || printf '1'
}
fq_chain_case() { # $1=变体，准备一个含严格空链或变体的状态目录
    reset_artifacts
    install -d -m 0700 "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc"
    : >"${EASY_ALL_GUARD_STATE_DIR}/runtime-write.lock"
    case "$1" in
    qdisc-json) printf '[]\n' >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/eth0.json" ;;
    qdisc-apply) printf '[]\n' >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/eth0.json.apply" ;;
    qdisc-hidden) : >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/.keep" ;;
    qdisc-lf-name) : >"${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/"$'\n' ;;
    qdisc-lf-symlink)
        : >"${TMP_DIR}/fq-lf-target"
        ln -s "${TMP_DIR}/fq-lf-target" "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc/"$'\n'
        ;;
    state-lf-extra) : >"${EASY_ALL_GUARD_STATE_DIR}/"$'\n' ;;
    pre-install) : >"${EASY_ALL_GUARD_STATE_DIR}/backups/pre-install-complete" ;;
    backups-extra-dir) install -d -m 0700 "${EASY_ALL_GUARD_STATE_DIR}/backups/certs" ;;
    state-extra) : >"${EASY_ALL_GUARD_STATE_DIR}/install-identity.json" ;;
    state-hidden) : >"${EASY_ALL_GUARD_STATE_DIR}/.hidden" ;;
    qdisc-symlink)
        install -d -m 0700 "${TMP_DIR}/fq-elsewhere/qdisc"
        rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc"
        ln -s "${TMP_DIR}/fq-elsewhere/qdisc" "${EASY_ALL_GUARD_STATE_DIR}/backups/qdisc"
        ;;
    backups-symlink)
        install -d -m 0700 "${TMP_DIR}/fq-elsewhere-backups/qdisc"
        rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}/backups"
        ln -s "${TMP_DIR}/fq-elsewhere-backups" "${EASY_ALL_GUARD_STATE_DIR}/backups"
        ;;
    esac
}
fq_chain_case empty
assert_equal "严格空链不算安装残留" "1" "$(residue_present)"
for variant in qdisc-json qdisc-apply qdisc-hidden pre-install backups-extra-dir \
    state-extra state-hidden qdisc-symlink backups-symlink qdisc-lf-name qdisc-lf-symlink \
    state-lf-extra; do
    fq_chain_case "${variant}"
    assert_equal "空链豁免不覆盖 ${variant}" "0" "$(residue_present)"
done
# marker 与服务判定不受空链豁免影响
fq_chain_case empty
install_progress_begin combined
output=$(capture install_residue_reason || true)
assert_contains "空链下的进度标记仍算残留" "${output}" "安装进度标记"
assert_not_contains "空链下的进度标记不再点名状态目录" "${output}" "未完成的状态目录"
install_progress_clear
fq_chain_case empty
install -d -m 0755 "$(dirname -- "${EASY_ALL_GUARD_SERVICE_FILE}")"
: >"${EASY_ALL_GUARD_SERVICE_FILE}"
output=$(capture install_residue_reason || true)
assert_contains "空链下的残留服务单元仍算残留" "${output}" "残留服务单元"
reset_artifacts
rm -rf -- "${TMP_DIR}/fq-elsewhere" "${TMP_DIR}/fq-elsewhere-backups"

# 6. 进度标记生命周期：写入、更新保留其他字段、清理删除目录
install_progress_begin combined
assert_equal "marker records profile" "combined" "$(install_progress_field PROFILE)"
install_progress_begin cloudfront cloudfront
assert_equal "marker records CloudFront chain" "cloudfront" "$(install_progress_field CHAIN)"
assert_equal "marker records CloudFront profile" "cloudfront" "$(install_progress_field PROFILE)"
install_progress_begin combined
assert_equal "marker starts at start" "start" "$(install_progress_field STAGE)"
install_progress_stage services
assert_equal "marker stage advances" "services" "$(install_progress_field STAGE)"
assert_equal "marker keeps profile on stage update" "combined" \
    "$(install_progress_field PROFILE)"
[[ -n "$(install_progress_field STARTED_AT)" ]] || fail "marker keeps started time"
# 覆盖 begin：上一次中断留下的标记不应保留旧阶段
install_progress_begin anytls
assert_equal "rebegin resets stage" "start" "$(install_progress_field STAGE)"
assert_equal "rebegin replaces profile" "anytls" "$(install_progress_field PROFILE)"
install_progress_clear
[[ ! -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] \
    || fail "clearing the marker removes the file"
[[ ! -d "$(dirname "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}")" ]] \
    || fail "clearing the marker removes the empty directory"

# 6b. 标记链路身份：五种模式各自接受同链路标记，其他链路一律拒绝
# （回归：模式 1 的 anytls 链被漏掉，中断后续装总被要求清理重装）。
while read -r marker_profile marker_chain; do
    install_progress_begin "${marker_profile}" "${marker_chain}"
    install_marker_chain_matches "${marker_profile}" \
        || fail "标记链路 ${marker_chain} 必须匹配模式 ${marker_profile}"
done <<'MARKER_CASES'
anytls anytls
cloudfront cloudfront
combined-cloudfront cloudfront
cloudflare cloudflare
combined-cloudflare cloudflare
MARKER_CASES
install_progress_begin combined-cloudfront cloudfront
for wrong_profile in anytls cloudflare; do
    if install_marker_chain_matches "${wrong_profile}"; then
        fail "标记链路 cloudfront 不得匹配模式 ${wrong_profile}"
    fi
done
install_progress_clear

# 6c. 安装身份带 Origin Rule ID：中断后能定位已创建的云端规则
install -d -m 0700 "$(install_state_dir_path)"
PROTOCOL=anytls
CDN_PROFILE_KEY=anytls
CLOUDFLARE_ORIGIN_RULESET_ID=rs-identity
CLOUDFLARE_ORIGIN_RULE_ID=rule-identity
persist_install_identity || fail "安装身份写入失败"
identity_file=$(install_identity_file)
assert_equal "安装身份保存 Origin Rule ID" \
    "rs-identity/rule-identity" \
    "$(jq -r '.cloudflare_origin_ruleset_id + "/" + .cloudflare_origin_rule_id' "${identity_file}")"
CLOUDFLARE_ORIGIN_RULESET_ID=""
CLOUDFLARE_ORIGIN_RULE_ID=""
load_install_identity || fail "安装身份读取失败；无法安全续装"
assert_equal "续装恢复 Origin Rule ID" "rs-identity/rule-identity" \
    "${CLOUDFLARE_ORIGIN_RULESET_ID}/${CLOUDFLARE_ORIGIN_RULE_ID}"
rm -f -- "${identity_file}"
unset PROTOCOL CDN_PROFILE_KEY

# 6d. 订阅模式是安装身份的一部分：link 安装续装时必须恢复 link，
#     否则会拿默认 deploy 覆盖已下发的订阅契约。
install -d -m 0700 "$(install_state_dir_path)"
PROTOCOL=anytls
CDN_PROFILE_KEY=anytls
SUBSCRIPTION_MODE=link
persist_install_identity || fail "安装身份写入失败"
assert_equal "安装身份保存订阅模式" "link" \
    "$(jq -r '.subscription_mode // ""' "$(install_identity_file)")"
SUBSCRIPTION_MODE=deploy
load_install_identity || fail "安装身份读取失败；无法安全续装"
assert_equal "续装恢复订阅模式" "link" "${SUBSCRIPTION_MODE}"
rm -f -- "$(install_identity_file)"
unset PROTOCOL CDN_PROFILE_KEY SUBSCRIPTION_MODE

# 6e. CDN 优选地址随订阅配置进安装身份：续装读到原地址才能沿用同一优选域名不重抽。
install -d -m 0700 "$(install_state_dir_path)"
PROTOCOL=combined-cloudflare
CDN_PROFILE_KEY=combined-cloudflare
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k2v8nq4zt6.cloudfront.182682.xyz"}'
persist_install_identity || fail "安装身份写入失败"
assert_equal "安装身份保存 CDN 优选地址" \
    '"k2v8nq4zt6.cloudfront.182682.xyz"' \
    "$(jq -c '.subscription_config | fromjson | .cdnEdgeAddress' "$(install_identity_file)")"
SUBSCRIPTION_CONFIG='{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[]}'
load_install_identity || fail "安装身份读取失败；无法安全续装"
assert_equal "续装恢复 CDN 优选地址" \
    '{"allowedTokens":{"owner":"token-abcdefgh"},"nodes":[],"cdnEdgeAddress":"k2v8nq4zt6.cloudfront.182682.xyz"}' \
    "${SUBSCRIPTION_CONFIG}"
rm -f -- "$(install_identity_file)"
unset PROTOCOL CDN_PROFILE_KEY SUBSCRIPTION_CONFIG

# 7. 未知端口归属（无 users 信息）时仍能给出可执行结论
busy 443
FAKE_SS_OWNER="@none"
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 443 || true)
assert_contains "unowned busy port still errors" "${output}" "TCP 443 已被占用"

# 8. nginx 占用端口时只报专用 VPS 结论，不再给出旧版本残留的猜测
reset_artifacts
busy 80
FAKE_SS_OWNER=nginx
export FAKE_SS_OWNER
output=$(capture assert_install_ports_free 80 || true)
assert_contains "nginx-owned port keeps dedicated-vps verdict" "${output}" "仅支持专用 VPS"
assert_not_contains "nginx-owned port does not guess a leftover" "${output}" "systemctl disable --now nginx"

# 10. root crontab 清理：只删 easy_all 的定时重启行，过滤失败时绝不提交空内容
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/scheduled-maintenance.sh"
mkdir -p "${TMP_DIR}/bin"
cat >"${TMP_DIR}/bin/crontab" <<'FAKE_CRONTAB'
#!/usr/bin/env bash
state=${FAKE_CRONTAB_FILE:?}
case "${1:-}" in
-l)
    [[ -f "${state}" ]] || { printf 'no crontab for root\n' >&2; exit 1; }
    cat "${state}"
    ;;
-r) rm -f -- "${state}" ;;
*) cat >"${state}" ;;
esac
FAKE_CRONTAB
chmod +x "${TMP_DIR}/bin/crontab"
export FAKE_CRONTAB_FILE="${TMP_DIR}/root-crontab"
export CRON_REBOOT_MARKER="# easy_all-managed-reboot"
# 定时重启的 cron 行需要 flock 抢运行时写锁，并写入锁路径；CI/沙箱不一定有 util-linux flock。
flock() { :; }
export RUNTIME_WRITE_LOCK_FILE="${TMP_DIR}/runtime-write.lock"
# 受管行只调用内部入口，命令路径取自 runtime-core 的 COMMAND_PATH（即安装后的
# /usr/local/bin/easy_all）；本文件直接 source scheduled-maintenance 时不会带上它。
COMMAND_PATH="/usr/local/bin/easy_all"

printf '0 3 * * * /usr/local/bin/user-backup\n0 4 * * * true # easy_all-managed-reboot\n' \
    >"${FAKE_CRONTAB_FILE}"
PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule
assert_contains "user cron entry survives" "$(cat "${FAKE_CRONTAB_FILE}")" "user-backup"
assert_not_contains "managed reboot entry removed" "$(cat "${FAKE_CRONTAB_FILE}")" \
    "easy_all-managed-reboot"

# 没有 marker 的 Profile 调用时必须是纯 no-op
printf '0 3 * * * /usr/local/bin/user-backup\n' >"${FAKE_CRONTAB_FILE}"
before=$(cat "${FAKE_CRONTAB_FILE}")
( unset CRON_REBOOT_MARKER
  PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule ) \
    || fail "missing marker must not error"
assert_equal "missing marker leaves crontab untouched" "${before}" \
    "$(cat "${FAKE_CRONTAB_FILE}")"

# 过滤失败时必须放弃写入，不能清空整份 crontab
filter_managed_reboot_cron() { return 1; }
PATH="${TMP_DIR}/bin:${PATH}" remove_daily_reboot_schedule \
    && fail "filter failure should be reported"
assert_equal "filter failure keeps crontab" "${before}" "$(cat "${FAKE_CRONTAB_FILE}")"
# shellcheck source=/dev/null
source "${ROOT_DIR}/lib/scheduled-maintenance.sh"

# configure_daily_reboot 遇到空 marker 时必须失败退出：空标记会让 awk 过滤输出全空，抹除管理员全部定时任务
( CRON_REBOOT_MARKER=""
  REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=5 \
      PATH="${TMP_DIR}/bin:${PATH}" configure_daily_reboot ) >/dev/null 2>&1 \
    && fail "configure_daily_reboot must refuse to run with an empty CRON_REBOOT_MARKER"
assert_equal "empty marker keeps crontab on configure_daily_reboot" "${before}" \
    "$(cat "${FAKE_CRONTAB_FILE}")"

# 有 marker 时写入受管任务并保留管理员条目
REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=5 CRON_REBOOT_MARKER="${CRON_REBOOT_MARKER}" \
    PATH="${TMP_DIR}/bin:${PATH}" configure_daily_reboot
assert_contains "managed reboot job written" "$(cat "${FAKE_CRONTAB_FILE}")" "0 5 * * *"
assert_contains "user cron survives reboot schedule" "$(cat "${FAKE_CRONTAB_FILE}")" "user-backup"

# 过滤失败时 configure_daily_reboot 也不得提交截断的 crontab
before_configure=$(cat "${FAKE_CRONTAB_FILE}")
filter_managed_reboot_cron() { return 1; }
( REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=6 CRON_REBOOT_MARKER="${CRON_REBOOT_MARKER}" \
      PATH="${TMP_DIR}/bin:${PATH}" configure_daily_reboot ) >/dev/null 2>&1 \
    && fail "configure_daily_reboot must report filter failure"
assert_equal "filter failure keeps crontab on configure_daily_reboot" "${before_configure}" \
    "$(cat "${FAKE_CRONTAB_FILE}")"

# 定时重启的 cron 行只调用内部入口：vixie-cron/cronie 安装时单行命令超 1000 字节
# 直接报 "command too long" 拒装（见 crontab MAX_COMMAND）。用真实 source 链
# （runtime-core → cloudfront-mode）生成受管行并断言字节长度（cron 按字节计，
# 不用 awk length/${#var}，它们在 UTF-8 locale 下按字符计会低估中文 logger 消息的占用），
# 防止模式 4/5 的预命令与 jq 复核再被拼回行内。
printf '0 3 * * * /usr/local/bin/user-backup\n' >"${FAKE_CRONTAB_FILE}"
reboot_line=$(
    (
        export EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
        export EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cron-state"
        source "${ROOT_DIR}/lib/runtime-core.sh"
        source "${ROOT_DIR}/lib/cloudfront-mode.sh"
        PATH="${TMP_DIR}/bin:${PATH}" REBOOT_SCHEDULE_MODE=custom REBOOT_HOUR=5 \
            configure_daily_reboot
        awk 'index($0, "easy_all-managed-reboot") != 0 { print; exit }' \
            "${FAKE_CRONTAB_FILE}"
    ) 2>/dev/null
)
[[ -n "${reboot_line}" ]] || fail "cloudfront reboot cron line missing"
reboot_line_bytes=$(printf '%s' "${reboot_line}" | wc -c | tr -d ' ')
[[ "${reboot_line_bytes}" =~ ^[0-9]+$ ]] \
    || fail "reboot cron line byte count unreadable: ${reboot_line_bytes}"
(( ${reboot_line_bytes} <= 1000 )) \
    || fail "cloudfront reboot cron line too long (${reboot_line_bytes} > 1000): ${reboot_line}"
assert_contains "cloudfront reboot line calls the internal entry" "${reboot_line}" \
    "internal-scheduled-reboot"
assert_contains "cloudfront reboot line keeps the managed marker" "${reboot_line}" \
    "# easy_all-managed-reboot"
# 锁定复核（以及模式 1/2 的“空复核”）已由内部入口承担，行内不再出现 jq 内容
assert_not_contains "cloudfront reboot line no longer inlines the jq check" "${reboot_line}" \
    "protection_offline"

# 内部入口 internal_scheduled_reboot：旧 cron 行
# `( pre ) && if exec 8>lock && flock -n 8; then { check; } && reboot || logger …; else logger …; fi`
# 的顺序与条件必须逐条保持。走真实 source 链（runtime-core，即 cron 触发 easy_all 时那条），
# 外部命令按仓库惯例用 override/stub：reboot 指向 TMP 假命令，flock 与 logger 用函数 stub，
# 假 reboot 与 logger 各写一份日志供断言。
cat >"${TMP_DIR}/bin/fake-reboot" <<'FAKE_REBOOT'
#!/usr/bin/env bash
printf 'reboot\n' >>"${FAKE_REBOOT_LOG:?}"
FAKE_REBOOT
chmod +x "${TMP_DIR}/bin/fake-reboot"

# reboot 自身失败（磁盘只读、systemd 拒绝等）：仍要证明入口走到了 /usr/sbin/reboot 这一步。
cat >"${TMP_DIR}/bin/fake-reboot-fail" <<'FAKE_REBOOT_FAIL'
#!/usr/bin/env bash
printf 'reboot\n' >>"${FAKE_REBOOT_LOG:?}"
exit 7
FAKE_REBOOT_FAIL
chmod +x "${TMP_DIR}/bin/fake-reboot-fail"

internal_reboot_run() {
    local case_name=$1 flock_status=${2:-0}
    local lock_path=${3:-${TMP_DIR}/internal-reboot.lock}
    (
        export EASY_ALL_RUNTIME_LIB_DIR="${ROOT_DIR}/lib"
        export EASY_ALL_STATE_DIR_OVERRIDE="${TMP_DIR}/cron-state"
        # 运行时写锁走 override：断言 TMP 锁文件真的被打开，而不是去碰 /var/lib/easy_all
        export RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${lock_path}"
        export FAKE_HOOK_SCENARIO="${FAKE_HOOK_SCENARIO:-none}"
        # 场景 e 需要一个非零退出的假 reboot，其余场景用成功的那个。
        if [[ "${FAKE_HOOK_SCENARIO}" == "reboot-fail" ]]; then
            export EASY_ALL_REBOOT_BIN_OVERRIDE="${TMP_DIR}/bin/fake-reboot-fail"
        else
            export EASY_ALL_REBOOT_BIN_OVERRIDE="${TMP_DIR}/bin/fake-reboot"
        fi
        export FAKE_REBOOT_LOG="${TMP_DIR}/${case_name}.reboot"
        export FAKE_LOGGER_LOG="${TMP_DIR}/${case_name}.logger"
        # shellcheck source=/dev/null
        source "${ROOT_DIR}/lib/runtime-core.sh"
        # 沙箱/CI 不一定有 util-linux 的 flock，按场景返回成功或失败。
        flock() { return "${flock_status}"; }
        logger() { printf '%s\n' "$*" >>"${FAKE_LOGGER_LOG}"; }
        case "${FAKE_HOOK_SCENARIO}" in
        none) ;;
        # 无钩子，只是假 reboot 换成非零退出的那个（见用例 e）。
        reboot-fail) ;;
        # 预命令失败：旧行里 `( pre ) &&` 直接短路，整行退出码就是 pre 的退出码，
        # 所以这里用显式非零状态 43，断言入口原样传播它。
        # 用 sh 内建的 exit 43 而不是 /bin/false：macOS 没有 /bin/true。
        pre-fail) scheduled_reboot_profile_pre_command() { printf 'exit 43'; } ;;
        # 预命令成功，但取锁后的只读复核失败。
        check-fail)
            scheduled_reboot_profile_pre_command() { printf 'true'; }
            scheduled_reboot_profile_locked_check_command() { printf 'exit 1'; }
            ;;
        esac
        internal_scheduled_reboot
    ) >/dev/null 2>"${TMP_DIR}/${case_name}.stderr"
}

# a. 无钩子（模式 1/2 没有预命令与复核钩子）+ 取锁成功 → 执行重启，不记 logger，锁走 override
export FAKE_HOOK_SCENARIO=none
internal_reboot_run no-hook 0 \
    || fail "internal_scheduled_reboot should succeed when the write lock is free"
[[ -f "${TMP_DIR}/internal-reboot.lock" ]] \
    || fail "internal_scheduled_reboot ignored RUNTIME_WRITE_LOCK_FILE_OVERRIDE"
assert_contains "internal_scheduled_reboot runs reboot on the free lock" \
    "$(cat "${TMP_DIR}/no-hook.reboot")" "reboot"
[[ ! -e "${TMP_DIR}/no-hook.logger" ]] \
    || fail "internal_scheduled_reboot logged a skip although it rebooted"

# b. 取锁失败 → 只记「运行时写锁不可用」并跳过重启
internal_reboot_run lock-busy 1 \
    || fail "internal_scheduled_reboot should not fail when the write lock is busy"
[[ ! -e "${TMP_DIR}/lock-busy.reboot" ]] \
    || fail "internal_scheduled_reboot must not reboot without the write lock"
assert_contains "busy lock logs the write-lock skip message" \
    "$(cat "${TMP_DIR}/lock-busy.logger")" \
    "-t easy_all easy_all 定时重启已跳过：运行时写锁不可用或正被占用"
assert_not_contains "busy lock does not log the traffic-guard message" \
    "$(cat "${TMP_DIR}/lock-busy.logger")" "CDN 流量保护"

# c. 预命令失败 → 静默跳过（旧行里 pre 失败短路，不记 logger），
# 但退出码必须原样传播 pre 的状态（旧行 `( pre ) && …` 的失败码就是 pre 的码）。
# 显式比较状态：不能写成 `|| fail`，那会把非零当成预期成功而吞掉。
export FAKE_HOOK_SCENARIO=pre-fail
pre_fail_status=0
internal_reboot_run pre-fail 0 || pre_fail_status=$?
assert_equal "failing pre command propagates the pre exit code" 43 "${pre_fail_status}"
[[ ! -e "${TMP_DIR}/pre-fail.reboot" ]] \
    || fail "failing pre command must not reboot"
[[ ! -e "${TMP_DIR}/pre-fail.logger" ]] \
    || fail "failing pre command must stay silent (no logger call)"

# d. 预命令成功但取锁后的复核失败 → 只记「CDN 流量保护」并跳过重启
export FAKE_HOOK_SCENARIO=check-fail
internal_reboot_run check-fail 0 || fail "failing locked check must not fail the entry"
[[ ! -e "${TMP_DIR}/check-fail.reboot" ]] \
    || fail "failing locked check must not reboot"
assert_contains "failing locked check logs the traffic-guard message" \
    "$(cat "${TMP_DIR}/check-fail.logger")" \
    "easy_all 定时重启已跳过：CDN 流量保护处于停机/pending 或统计不可读"
assert_not_contains "failing locked check does not log the write-lock message" \
    "$(cat "${TMP_DIR}/check-fail.logger")" "运行时写锁不可用"

# e. reboot 本身失败 → 入口仍返回 0，且只记「CDN 流量保护」那一条消息。
# 这是刻意保持的旧内联语义：`{ check; } && reboot || logger` 里 reboot 失败与复核
# 失败共用同一条审计消息，链尾 logger 成功就把整行的退出码变成 0。
export FAKE_HOOK_SCENARIO=reboot-fail
reboot_fail_status=0
internal_reboot_run reboot-fail 0 || reboot_fail_status=$?
assert_equal "failing reboot keeps the entry exit code at 0 (old inline semantics)" \
    0 "${reboot_fail_status}"
[[ -f "${TMP_DIR}/reboot-fail.reboot" ]] \
    || fail "failing reboot case never reached the reboot binary"
assert_contains "failing reboot really invoked the reboot binary" \
    "$(cat "${TMP_DIR}/reboot-fail.reboot")" "reboot"
# A25：reboot 执行失败与「保护状态不允许重启」必须是两条不同消息，不能合并成一条。
assert_contains "failing reboot logs its own failure message" \
    "$(cat "${TMP_DIR}/reboot-fail.logger")" "easy_all 定时重启执行失败："
assert_not_contains "failing reboot does not log the traffic-guard skip message" \
    "$(cat "${TMP_DIR}/reboot-fail.logger")" \
    "easy_all 定时重启已跳过：CDN 流量保护处于停机/pending 或统计不可读"
assert_not_contains "failing reboot does not log the write-lock message" \
    "$(cat "${TMP_DIR}/reboot-fail.logger")" "运行时写锁不可用"
unset FAKE_HOOK_SCENARIO

# f. 锁文件打不开（状态目录缺失/不可写）：与「抢不到锁」共用同一条 skip 审计消息，
# 入口返回 0，且不重启。审计结论：旧 cron 行 `if exec 8>lock && flock -n 8; then …`
# 在 dash（cron 的 /bin/sh）下打开失败会静默以非零退出、既不留痕也不重启；新入口
# 改为 skip 日志 + exit 0，同样不重启，但排障时能在 syslog 里看到原因。
# 附带断言 stderr 被静默：否则 cron 每触发一次就发一封 "No such file or directory" 邮件。
export FAKE_HOOK_SCENARIO=none
lock_open_fail_dir="${TMP_DIR}/no-such-dir"
rm -rf -- "${lock_open_fail_dir}"
lock_open_fail_status=0
internal_reboot_run lock-open-fail 0 "${lock_open_fail_dir}/reboot.lock" \
    || lock_open_fail_status=$?
assert_equal "unopenable write lock keeps the entry exit code at 0 (old inline semantics)" \
    0 "${lock_open_fail_status}"
[[ ! -e "${lock_open_fail_dir}" ]] \
    || fail "lock-open-fail case must not create the missing state directory"
[[ ! -e "${TMP_DIR}/lock-open-fail.reboot" ]] \
    || fail "unopenable write lock must not reboot"
[[ -f "${TMP_DIR}/lock-open-fail.logger" ]] \
    || fail "unopenable write lock must log the write-lock skip message (not stay silent)"
assert_contains "unopenable write lock logs the write-lock skip message" \
    "$(cat "${TMP_DIR}/lock-open-fail.logger")" \
    "-t easy_all easy_all 定时重启已跳过：运行时写锁不可用或正被占用"
assert_not_contains "unopenable write lock does not log the traffic-guard message" \
    "$(cat "${TMP_DIR}/lock-open-fail.logger")" "CDN 流量保护"
assert_not_contains "unopenable write lock stays quiet on stderr (no cron mail)" \
    "$(cat "${TMP_DIR}/lock-open-fail.stderr" 2>/dev/null)" "No such file or directory"

# 11. 只有完整快照才允许逐项恢复（部分快照不得推断“安装前不存在”）
systemctl() { :; }
stop_maintenance_services() { :; }
stop_services() { :; }
remove_globalping_refresh_timer() { :; }
remove_daily_reboot_schedule() { :; }
restore_install_snapshot() { printf 'RESTORED\n'; }
snapshot_dir="${EASY_ALL_GUARD_STATE_DIR}/backups"
mkdir -p "${snapshot_dir}"
: >"${snapshot_dir}/pre-install-ufw.active"
output=$(capture cleanup_partial_install_local || true)
assert_not_contains "partial snapshot must not restore" "${output}" "RESTORED"
assert_contains "partial snapshot is reported" "${output}" "未找到完整安装前快照"
: >"${snapshot_dir}/pre-install-complete"
output=$(capture cleanup_partial_install_local || true)
assert_contains "complete snapshot restores" "${output}" "RESTORED"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"

# 13. 跨模式清理：profile 映射齐全，未知模式拒绝猜测
assert_equal "anytls maps to its profile" "anytls.sh" "$(profile_script_for anytls)"
assert_equal "cloudfront maps to its profile" "cloudfront.sh" "$(profile_script_for cloudfront)"
assert_equal "cloudflare maps to its profile" "cloudflare.sh" "$(profile_script_for cloudflare)"
assert_equal "combined-cloudfront maps to its profile" "combined.sh" \
    "$(profile_script_for combined-cloudfront)"
assert_equal "combined-cloudflare maps to its profile" "combined-cloudflare.sh" \
    "$(profile_script_for combined-cloudflare)"
assert_equal "unknown mode is rejected" "1" \
    "$(profile_script_for nope >/dev/null 2>&1 && echo 0 || echo 1)"
output=$(capture run_recorded_profile_cleanup nope || true)
assert_contains "unknown recorded mode is explained" "${output}" "无法识别上次安装的模式"

# 14. 残留文件清理：只删传入路径，并清掉进度标记
mkdir -p "${TMP_DIR}/cleanup/conf.d" "${TMP_DIR}/cleanup/state/xray" \
    "${TMP_DIR}/cleanup/web" "${TMP_DIR}/cleanup/bin"
: >"${TMP_DIR}/cleanup/conf.d/easy_all.conf"
: >"${TMP_DIR}/cleanup/state/xray/config.json"
: >"${TMP_DIR}/cleanup/bin/easy_all"
install_progress_begin combined-cloudfront
cleanup_partial_install_files \
    "${TMP_DIR}/cleanup/conf.d/easy_all.conf" \
    "${TMP_DIR}/cleanup/state" \
    "${TMP_DIR}/cleanup/bin/easy_all"
[[ ! -e "${TMP_DIR}/cleanup/conf.d/easy_all.conf" ]] || fail "listed config should be removed"
[[ ! -e "${TMP_DIR}/cleanup/state" ]] || fail "listed state dir should be removed"
[[ ! -e "${TMP_DIR}/cleanup/bin/easy_all" ]] || fail "listed command should be removed"
[[ -d "${TMP_DIR}/cleanup/web" ]] || fail "unlisted paths must be kept"
[[ ! -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] || fail "marker should be cleared"

# 15. 静态回归网：首次安装回滚必须清掉进度标记，并还原安装前 IPv6 配置
body=$(awk '/^rollback_fresh_install\(\) \{/,/^\}/' "${ROOT_DIR}/lib/anytls-mode.sh")
[[ "${body}" == *cleanup_partial_install* ]] \
    || fail "rollback_fresh_install in anytls-mode.sh must run the partial cleanup (clears the marker)"
[[ "${body}" == *cdn_print_cloud_inventory* ]] \
    || fail "rollback_fresh_install in anytls-mode.sh must report retained cloud resources"
cleanup_common_body=$(awk '/^cdn_local_uninstall_common\(\) \{/,/^\}/' "${ROOT_DIR}/lib/anytls-mode.sh")
# 回滚清理会删掉 STATE_DIR（含 IPv6 快照）：还原必须发生在其中。
[[ "${cleanup_common_body}" == *restore_preinstall_ipv6* ]] \
    || fail "anytls local uninstall must restore pre-install IPv6 before deleting the state dir"

# 16. 残留提示文案：有标记时给 cleanup-partial，无标记时只能人工核对
install_progress_begin anytls
hint=$(residue_recovery_hint)
assert_contains "hint with marker offers cleanup-partial" "${hint}" "sudo easy_all cleanup-partial"
install_progress_clear
hint=$(residue_recovery_hint)
assert_contains "hint without marker asks for manual review" "${hint}" "请人工核对后清理"
assert_not_contains "hint without marker does not promise cleanup-partial" \
    "${hint}" "sudo easy_all cleanup-partial"

# 17. launcher 标记快照：模式与身份必须来自同一次读取
mk_marker() {
    install -d -m 0700 "$(dirname "$1")"
    printf 'SCHEMA=1\nPROFILE=%s\nCHAIN=cloudfront\nSTAGE=packages\nSTARTED_AT=%s\n' "$2" "$3" >"$1"
}
marker_file="${TMP_DIR}/identity/install-progress.env"
absent=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "identity is absent without marker" "absent" "${absent}"
mk_marker "${marker_file}" combined-cloudfront "T1"
present=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
assert_equal "snapshot encodes mode, chain, stage, start time and schema" \
    "present|combined-cloudfront|packages|T1|cloudfront|1" "${present}"
mk_marker "${marker_file}" anytls "T2"
replaced=$(bash -c 'source "$1"; launcher_marker_snapshot "$2"' _ "${ROOT_DIR}/easy_all" "${marker_file}")
[[ "${replaced}" != "${present}" ]] || fail "replaced marker must change identity"
[[ "${absent}" != "${present}" ]] || fail "appearing marker must change identity"
rm -f -- "${marker_file}"

# 18. 删除失败必须保留 marker 并返回非零
install_progress_begin combined-cloudfront
rm() { return 1; }
cleanup_partial_install_files "${TMP_DIR}/whatever" \
    && fail "delete failure must be reported"
[[ -f "${EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE}" ]] \
    || fail "delete failure must keep the marker for retry"
unset -f rm
install_progress_clear

# 19. 跨模式清理必须用独立进程
body=$(awk '/^run_recorded_profile_cleanup\(\) \{/,/^\}/' "${ROOT_DIR}/lib/profile-common.sh")
[[ "${body}" == *"bash -c"* ]] || fail "cross-mode cleanup must run in a separate process"

# 25. 无 progress marker 的残留：不再猜测模式，直接要求人工核对
reset_artifacts
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray"
EASY_ALL_SELECTED_MODE=combined
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "markerless residue points at the marker file" "${output}" \
    "安装进度标记缺少模式信息"
# 该状态的标记没有模式信息，cleanup-partial 同样无法接管，提示不得把它当成出路
assert_not_contains "markerless residue does not loop back to cleanup-partial" \
    "${output}" "请先执行 sudo easy_all cleanup-partial"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"

# 标记存在但缺 PROFILE 时：同样给出可执行的人工核对指引，不推给 cleanup-partial
mkdir -p "${EASY_ALL_GUARD_STATE_DIR}/xray" "$(dirname -- "$(install_progress_file)")"
printf 'STAGE=services\nSTARTED_AT=1\n' >"$(install_progress_file)"
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "marker without profile reports the missing mode" "${output}" \
    "安装进度标记缺少模式信息"
assert_not_contains "marker without profile does not loop back to cleanup-partial" \
    "${output}" "请先执行 sudo easy_all cleanup-partial"
rm -rf -- "${EASY_ALL_GUARD_STATE_DIR}"
rm -f -- "$(install_progress_file)"

# 26. 端口守卫不把 nginx 占用说成 easy_all 残留
reset_artifacts
busy 80
FAKE_SS_OWNER=sshd
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "non-nginx owner falls through to the port guard" "${output}" "sshd"

FAKE_SS_OWNER="@none"
export FAKE_SS_OWNER
output=$(capture prepare_fresh_install 80 </dev/null || true)
assert_contains "unknown owner falls through to the port guard" "${output}" "TCP 80 已被占用"
assert_contains "unknown owner keeps the dedicated-vps verdict" "${output}" "仅支持专用 VPS"
reset_artifacts
idle

# 26b. 模式 1 订阅域名必须是 Zone 的一级子域名：默认橙云边缘证书只覆盖一级子域，
# 多级名字会装到最后（公网 TLS 验收）才失败且无法修复，因此必须在输入处拒绝。
run_anytls_inputs_case() { # $1=SUBSCRIPTION_DOMAIN
    local case_dir="${TMP_DIR}/anytls-inputs-$(printf '%s' "$1" | tr '.' '_')"
    rm -rf -- "${case_dir}"
    mkdir -p "${case_dir}/state"
    EASY_ALL_INPUTS_SUB_DOMAIN="$1" \
    RUNTIME_TMP="${case_dir}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${case_dir}/state/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/state/subscriptions" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${case_dir}/progress/install-progress.env" \
        bash -c '
            source "$1/profiles/anytls.sh"
            CF_ZONE=example.com
            SUBSCRIPTION_MODE=deploy
            SUBSCRIPTION_DOMAIN=${EASY_ALL_INPUTS_SUB_DOMAIN}
            # 交互面：一律接受默认值（直连域名/节点名/下载名都取默认）。
            prompt_value() { printf "%s" "${2:-}"; }
            cloudflare_collect_api_token() { :; }
            choose_subscription_config() {
                printf "%s" "{\"allowedTokens\":{\"owner\":\"token-abcdefgh\"},\"nodes\":[]}"
            }
            cdn_apply_subscription_config() { :; }
            cdn_validate_install_owner_token() { :; }
            detect_public_ipv4() { printf "203.0.113.10"; }
            collect_anytls_install_inputs
        ' _ "${ROOT_DIR}" 2>&1
}
multi_level_output=$(run_anytls_inputs_case "deep.sub.example.com") \
    && fail "模式 1 多级订阅域名必须拒绝"
assert_contains "模式 1 多级订阅域名点明一级子域要求" "${multi_level_output}" \
    "订阅域名必须是 example.com 的一级子域名"
assert_contains "模式 1 多级订阅域名给出正确示例" "${multi_level_output}" "如 sub.example.com"
one_level_output=$(run_anytls_inputs_case "sub.example.com") \
    || fail "模式 1 一级订阅域名必须通过：${one_level_output}"

# 26c. 模式 1 端口预检拆两段：link 不启 Caddy、不放 8443，首轮只查 443；deploy 的
# 8443 在订阅模式确定后才补检（仍在任何云端资源创建之前）。
run_anytls_preflight_case() { # $1=SUBSCRIPTION_MODE
    SUBSCRIPTION_MODE="$1" bash -c '
        source "$1/profiles/anytls.sh"
        cdn_prepare_install_ports
        printf "PREFLIGHT-OK\n"
        anytls_assert_subscription_port_free
        printf "SUBSCRIPTION-PORT-OK\n"
    ' _ "${ROOT_DIR}" 2>&1
}
reset_artifacts
idle
busy 8443
link_preflight_status=0
link_preflight_output=$(run_anytls_preflight_case link) || link_preflight_status=$?
assert_equal "模式 1 link 安装不再因宿主占用 8443 失败" "0" "${link_preflight_status}"
assert_contains "link 首轮预检通过" "${link_preflight_output}" "PREFLIGHT-OK"
assert_contains "link 不做订阅端口补检" "${link_preflight_output}" "SUBSCRIPTION-PORT-OK"
deploy_preflight_status=0
deploy_preflight_output=$(run_anytls_preflight_case deploy) || deploy_preflight_status=$?
assert_equal "模式 1 deploy 安装仍因 8443 被占失败" "1" "${deploy_preflight_status}"
assert_contains "deploy 首轮预检只查 443 因此通过" "${deploy_preflight_output}" "PREFLIGHT-OK"
assert_contains "deploy 订阅端口补检点名 8443" "${deploy_preflight_output}" "TCP 8443 已被占用"
assert_not_contains "deploy 补检失败后不再输出成功标记" "${deploy_preflight_output}" \
    "SUBSCRIPTION-PORT-OK"
reset_artifacts
idle

# 26d. 模式 1 安装入口必须真正调用端口预检与进度初始化。
# 写成 `cdn_prepare_install_ports()`（带括号）在 bash 里是「嵌套函数定义」：不调用，
# 还会把真函数重定义成紧随其后的 if 块，而顶层单测（26c 直接调函数）仍会绿。
run_anytls_install_all_case() {
    local case_dir="${TMP_DIR}/anytls-install-all"
    rm -rf -- "${case_dir}"
    mkdir -p "${case_dir}"
    EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
    EASY_ALL_CERT_DIR_OVERRIDE="${case_dir}/certs" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/subscriptions" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${case_dir}/progress/install-progress.env" \
    RUNTIME_TMP="${case_dir}/runtime" \
        bash -c '
            set -Eeuo pipefail
            # shellcheck source=/dev/null
            source "$1/profiles/anytls.sh"
            # 宿主与云端一律替身：本用例只校验 install_all 的调用与控制流。
            require_root() { :; }
            acquire_runtime_write_lock() { :; }
            require_systemd() { :; }
            check_platform() { :; }
            report_host_init_state() { :; }
            ensure_swap() { :; }
            install_failure_begin() { printf "FAILURE-BEGIN: %s\n" "$1"; }
            install_progress_begin() { printf "PROGRESS-BEGIN: %s %s\n" "$1" "$2"; }
            install_progress_stage() { :; }
            prepare_fresh_install() { printf "PREPARE-PORTS: %s\n" "$*"; }
            snapshot_fresh_install() { :; }
            install_packages() { :; }
            install_certbot_deploy_hook() { :; }
            choose_tcp_acceleration() { :; }
            configure_tcp_acceleration() { :; }
            configure_daily_reboot() { :; }
            configure_ipv4_only() { :; }
            # 安装在这里结束（输入阶段之后就是云端资源，不在本用例范围），并就地记录
            # cdn_prepare_install_ports 是否被 install_all 重定义成含 install_progress_begin 的假函数。
            collect_anytls_install_inputs() {
                printf "INPUTS-STAGE\n"
                declare -f cdn_prepare_install_ports | grep -q "install_progress_begin" \
                    && printf "CDN-PREPARE-OVERWRITTEN: yes\n" \
                    || printf "CDN-PREPARE-OVERWRITTEN: no\n"
                exit 0
            }
            # 测试没有 tty：只把 install_all 首行的交互终端门禁换成 no-op，其余函数体原样执行。
            install_all_definition=$(declare -f install_all | grep -v "^    \[\[ -t 0 \]\]")
            eval "${install_all_definition}"
            install_all
        ' _ "${ROOT_DIR}" 2>&1
}
assert_contains "模式 1 安装保留交互终端门禁" "$(<"${ROOT_DIR}/lib/anytls-mode.sh")" \
    '[[ -t 0 ]] || die "安装必须在交互终端中执行"'
install_all_output=$(run_anytls_install_all_case)
assert_contains "模式 1 安装真正执行首轮端口预检" "${install_all_output}" "PREPARE-PORTS: 443"
assert_contains "模式 1 安装真正写安装进度标记" "${install_all_output}" \
    "PROGRESS-BEGIN: anytls anytls"
assert_contains "模式 1 安装进入输入阶段（用例确实驱动了 install_all 函数体）" \
    "${install_all_output}" "INPUTS-STAGE"
assert_contains "cdn_prepare_install_ports 保持原定义未被 install_all 覆盖" \
    "${install_all_output}" "CDN-PREPARE-OVERWRITTEN: no"
assert_not_contains "install_all 不得把端口预检调用写成嵌套函数定义" \
    "${install_all_output}" "CDN-PREPARE-OVERWRITTEN: yes"

# 17) 安装失败诊断：在独立脚本里复现生产路径（set -e + ERR/EXIT 陷阱）
# 不放在 $( ) 里直接 set -e：bash 默认在命令替换中清除 errexit，ERR 陷阱语义会随版本漂移。
run_failure_scenario() { # $1=EXIT 陷阱体
    local script="${TMP_DIR}/failure-scenario.sh"
    {
        printf 'set -Eeuo pipefail\n'
        printf 'source %q\n' "${ROOT_DIR}/lib/log.sh"
        printf 'RUNTIME_LIB_DIR=%q\n' "${ROOT_DIR}/lib"
        printf 'source %q\n' "${ROOT_DIR}/lib/state.sh"
        printf 'source %q\n' "${ROOT_DIR}/lib/profile-common.sh"
        printf 'install_failure_begin combined-cloudfront\n'
        printf 'install_progress_begin combined-cloudfront\n'
        printf 'install_progress_stage services\n'
        printf 'EASY_ALL_LAST_ERROR=%q\n' 'Cloudflare API 请求失败：GET /zones'
        printf 'trap %q EXIT\n' "$1"
        printf 'false\n'
    } >"${script}"
    bash "${script}" 2>&1
}

reset_artifacts
failure_report=$(run_failure_scenario 'install_failure_report') || true
assert_contains "failure-report: mode" "${failure_report}" "模式：combined-cloudfront"
assert_contains "failure-report: stage" "${failure_report}" \
    "失败阶段：services（服务、证书与防火墙）"
assert_contains "failure-report: location" "${failure_report}" "失败位置："
assert_contains "failure-report: source file" "${failure_report}" "failure-scenario.sh:"
assert_contains "failure-report: command" "${failure_report}" "失败命令：false"
assert_contains "failure-report: message" "${failure_report}" \
    "错误信息：Cloudflare API 请求失败：GET /zones"

# 18) 失败报告只打印一次（退出清理与后续调用不应重复刷屏）
reset_artifacts
once=$(run_failure_scenario 'install_failure_report; install_failure_report') || true
assert_equal "failure-report: printed once" "1" "$(grep -c '安装失败' <<<"${once}")"

# 18b) 展示阶段的失败不再算“安装失败”（避免成功安装尾部命令报错时误导）
reset_artifacts
disarmed=$(bash -c '
    set -Eeuo pipefail
    source "$1/lib/log.sh"
    RUNTIME_LIB_DIR="$1/lib"
    source "$1/lib/profile-common.sh"
    install_failure_begin combined
    INSTALL_FAILURE_ARMED=0
    trap "install_failure_report" EXIT
    false
' _ "${ROOT_DIR}" 2>&1) || true
assert_not_contains "failure-report: disarmed after commit" "${disarmed}" "安装失败"

confirm_out=$(printf 'n\n' | (
    read_confirmation '确认？' answer 2>/dev/null
    printf '%s' "${answer}"
))
assert_equal "confirmation: reads answer" "n" "${confirm_out}"

# 27. 状态必需字段单一来源：launcher 分类与核心结构校验使用同一清单
launcher_fields_combined=$(bash -c 'source "$1/lib/state.sh"; state_required_fields combined-cloudfront' \
    _ "${ROOT_DIR}")
launcher_fields_plain=$(bash -c 'source "$1/lib/state.sh"; state_required_fields cloudfront' \
    _ "${ROOT_DIR}")
for field in VPS_PUBLIC_IPV4 CF_NODE_PREFIX OWNER_TOKEN DIRECT_DOMAIN DIRECT_NODE_NAME \
    ANYTLS_PASSWORD; do
    assert_contains "combined 模式必需字段包含 ${field}" "${launcher_fields_combined}" "${field}"
done
assert_not_contains "模式 4 必需字段不含直连字段" "${launcher_fields_plain}" "DIRECT_DOMAIN"
assert_contains "两模式共同必需字段含 VPS_PUBLIC_IPV4" "${launcher_fields_plain}" "VPS_PUBLIC_IPV4"
assert_not_contains "字段清单不再保留 Reality 字段" "${launcher_fields_combined}" "REALITY_"
launcher_body=$(<"${ROOT_DIR}/easy_all")
assert_contains "launcher 复用共享字段清单" "${launcher_body}" "state_missing_fields"
assert_not_contains "launcher 不再自带重复的必需字段函数" "${launcher_body}" \
    "cloudfront_state_required_fields"
assert_not_contains "launcher 不再引用已删除的旧状态库" "${launcher_body}" \
    "cloudflare_state_required_fields"
core_body=$(<"${ROOT_DIR}/lib/runtime-core.sh")
assert_contains "核心结构校验复用共享字段清单" \
    "$(awk '/^cdn_validate_state_structure\(\)/,/^}/' <<<"${core_body}")" \
    'state_required_fields "${protocol}"'
assert_contains "核心结构校验复用“值可为空”规则" \
    "$(awk '/^cdn_validate_state_structure\(\)/,/^}/' <<<"${core_body}")" \
    "state_field_allows_empty"

# launcher 分类：逐字段删除后必须判为不完整，完整状态仍判为完整。
write_state_fixture() { # $1=文件 $2=协议 $3=订阅模式
    local file=$1 protocol=$2 subscription_mode=${3:-deploy} field
    {
        printf 'STATE_VERSION="1"\n'
        printf 'PROTOCOL="%s"\n' "${protocol}"
        printf 'SUBSCRIPTION_MODE="%s"\n' "${subscription_mode}"
        while IFS= read -r field; do
            case "${field}" in
            PROTOCOL | SUBSCRIPTION_MODE) continue ;;
            CDN_TRAFFIC_PROTECTION_GB) printf '%s="985"\n' "${field}" ;;
            SCHEDULED_REBOOT_ENABLED) printf '%s="0"\n' "${field}" ;;
            SCHEDULED_REBOOT_HOUR) printf '%s="4"\n' "${field}" ;;
            *) printf '%s="值"\n' "${field}" ;;
            esac
        done < <(state_required_fields "${protocol}" "${subscription_mode}")
    } >"${file}"
}
launcher_state_complete() {
    bash -c 'source "$1"; launcher_state_complete "$2"' \
        _ "${ROOT_DIR}/easy_all" "$1"
}
fixture_dir="${TMP_DIR}/field-fixtures"
install -d -m 0700 "${fixture_dir}"
for protocol in anytls cloudfront cloudflare combined-cloudfront combined-cloudflare; do
    fixture="${fixture_dir}/${protocol}.env"
    write_state_fixture "${fixture}" "${protocol}"
    launcher_state_complete "${fixture}" || fail "完整 ${protocol} 状态必须判为完整"
    fields=$(bash -c 'source "$1/lib/state.sh"; state_required_fields "$2"' _ "${ROOT_DIR}" "${protocol}")
    while IFS= read -r field; do
        [[ -n "${field}" ]] || continue
        partial="${fixture_dir}/${protocol}.${field}.env"
        grep -v "^${field}=" "${fixture}" >"${partial}"
        launcher_state_complete "${partial}" \
            && fail "缺少 ${protocol}.${field} 不得判为完整状态"
    done <<<"${fields}"
done
for field in VPS_PUBLIC_IPV4 CF_NODE_PREFIX OWNER_TOKEN DIRECT_DOMAIN; do
    assert_equal "示例字段 ${field} 已纳入字段清单" "1" \
        "$(grep -Ec "^${field}$" <<<"${launcher_fields_combined}")"
done

# 27b. 「字段存在」与「值非空」必须区分：合法空值仍算完整，真正缺字段只剩卸载通道。
empty_reboot_fixture="${fixture_dir}/empty-reboot.env"
sed 's/^SCHEDULED_REBOOT_HOUR=.*/SCHEDULED_REBOOT_HOUR=""/' \
    "${fixture_dir}/combined-cloudfront.env" >"${empty_reboot_fixture}"
launcher_state_complete "${empty_reboot_fixture}" \
    || fail "关闭定时重启时 HOUR 可为空，仍应判为完整"
sed 's/^SCHEDULED_REBOOT_ENABLED=.*/SCHEDULED_REBOOT_ENABLED="1"/' \
    "${empty_reboot_fixture}" >"${fixture_dir}/enabled-empty-hour.env"
launcher_state_complete "${fixture_dir}/enabled-empty-hour.env" \
    && fail "启用定时重启时空 HOUR 必须判为不完整"

link_fixture="${fixture_dir}/anytls-link.env"
write_state_fixture "${link_fixture}" anytls link
printf 'MIHOMO_TEMPLATE_SNAPSHOT=""\n' >>"${link_fixture}"
launcher_state_complete "${link_fixture}" \
    || fail "模式 1 link 不发布模板快照，空值仍应判为完整"
assert_equal "模式 1 link 不要求订阅域名" "0" \
    "$(grep -c '^SUBSCRIPTION_DOMAIN=' "${link_fixture}" || true)"
deploy_without_snapshot="${fixture_dir}/cloudfront-empty-snapshot.env"
sed 's/^MIHOMO_TEMPLATE_SNAPSHOT=.*/MIHOMO_TEMPLATE_SNAPSHOT=""/' \
    "${fixture_dir}/cloudfront.env" >"${deploy_without_snapshot}"
launcher_state_complete "${deploy_without_snapshot}" \
    && fail "有订阅站点的模式不得接受空模板快照"

# 28. 不完整状态的卸载路由：两种不完整协议都只走本机通道，完整状态走严格路径
route_output=$(bash -c '
    source "$1"
    source "$(profile_file incomplete-cloudfront)"
    register_easy_all_command() { :; }
    uninstall_incomplete() { printf "LOCAL-ONLY\n"; }
    uninstall_all() { printf "STRICT\n"; }
    dispatch_profile_command incomplete-cloudfront uninstall
    dispatch_profile_command incomplete-combined-cloudfront uninstall
    dispatch_profile_command cloudfront uninstall
    dispatch_profile_command combined-cloudfront uninstall
' _ "${ROOT_DIR}/easy_all" 2>&1)
assert_equal "不完整走本机通道、完整走严格路径" \
    $'LOCAL-ONLY\nLOCAL-ONLY\nSTRICT\nSTRICT' "${route_output}"

# 真实卸载函数：只要本机清理，不调用 AWS/CF、不调用严格 load_state，并退出成功
incomplete_uninstall_output=""
incomplete_uninstall_status=0
run_incomplete_uninstall() { # 零参数入口
    local status=0
    local case_dir="${TMP_DIR}/incomplete-uninstall"
    mkdir -p "${case_dir}/state" "${case_dir}/subscriptions/data" \
        "${case_dir}/bin" "${case_dir}/singbox" "${case_dir}/caddy" \
        "${case_dir}/units"
    : >"${case_dir}/state/state.env"
    EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/subscriptions/data" \
    COMMAND_INSTALL_DIR="${case_dir}/bin" \
    COMMAND_PATH="${case_dir}/bin/easy_all" \
    SINGBOX_BIN="${case_dir}/singbox/sing-box" \
    CADDY_BIN="${case_dir}/caddy/caddy" \
    SINGBOX_SERVICE_FILE="${case_dir}/units/easy_all-singbox.service" \
    CADDY_SERVICE_FILE="${case_dir}/units/easy_all-caddy.service" \
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        require_root() { :; }
        acquire_runtime_write_lock() { :; }
        stop_maintenance_services() { :; }
        stop_services() { :; }
        systemctl() { :; }
        # 内核边界替身：本测试不触碰宿主 iptables；生产路径失败关闭由 metering 门禁覆盖。
        remove_cdn_traffic_protection_timer() { :; }
        cdn_traffic_counters_remove() { :; }
        remove_certbot_deploy_hook() { :; }
        certificate_remove_lineage() { :; }
        restore_platform_security_state() { :; }
        restore_preinstall_firewall() { :; }
        restore_preinstall_ipv6() { :; }
        remove_daily_reboot_schedule() { :; }
        aws_cli() { printf "AWS-CALLED\n"; return 1; }
        cloudflare_api_request() { printf "CF-CALLED\n"; return 1; }
        load_state() { printf "STRICT-LOAD\n"; return 1; }
        FORCE=1
        arg_status=0
        arg_message=$(uninstall_incomplete --purge-cloud 2>&1) || arg_status=$?
        printf "ARG-STATUS=%s ARG-MESSAGE=%s\n" "${arg_status}" "${arg_message}"
        uninstall_incomplete
    ' _ "${ROOT_DIR}" 2>&1 || status=$?
    printf '%s\n' "${status}"
}
incomplete_uninstall_output=$(run_incomplete_uninstall)
incomplete_uninstall_status=${incomplete_uninstall_output##*$'\n'}
assert_equal "incomplete uninstall 退出 0" "0" "${incomplete_uninstall_status}"
assert_contains "incomplete uninstall 保留云端资源" \
    "${incomplete_uninstall_output}" "云端资源无法自动清理，需人工核对"
assert_contains "incomplete uninstall 拒绝旧参数" \
    "${incomplete_uninstall_output}" "ARG-STATUS=1"
assert_contains "incomplete uninstall 旧参数提示新用法" \
    "${incomplete_uninstall_output}" "uninstall 不支持参数"
assert_not_contains "incomplete uninstall 不调用 AWS" \
    "${incomplete_uninstall_output}" "AWS-CALLED"
assert_not_contains "incomplete uninstall 不调用 Cloudflare" \
    "${incomplete_uninstall_output}" "CF-CALLED"
assert_not_contains "incomplete uninstall 不走严格 load_state" \
    "${incomplete_uninstall_output}" "STRICT-LOAD"
assert_not_contains "incomplete uninstall 不再声称云端资源已保留" \
    "${incomplete_uninstall_output}" "云端资源已保留"

# 29. 回滚失败：保留安装进度标记与安装前快照，且 cleanup-partial 可重试
rollback_fail_output=$(EASY_ALL_GUARD_STATE_DIR="${TMP_DIR}/rb-state" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/rb-progress/install-progress.env" \
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        install -d -m 0700 "${EASY_ALL_GUARD_STATE_DIR}/backups"
        : >"${EASY_ALL_GUARD_STATE_DIR}/backups/pre-install-complete"
        install_progress_begin combined cloudfront
        stop_maintenance_services() { :; }
        stop_services() { :; }
        restore_install_snapshot() { return 1; }
        remove_daily_reboot_schedule() { :; }
        cdn_print_cloud_inventory() { :; }
        status=0
        rollback_fresh_install || status=$?
        printf "STATUS=%s\n" "${status}"
        [[ -f "$(install_progress_file)" ]] && printf "MARKER=kept\n"
        [[ -f "${EASY_ALL_GUARD_STATE_DIR}/backups/pre-install-complete" ]] \
            && printf "SNAPSHOT=kept\n"
    ' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "回滚失败必须非零" "${rollback_fail_output}" "STATUS=1"
assert_contains "回滚失败保留安装进度标记" "${rollback_fail_output}" "MARKER=kept"
assert_contains "回滚失败保留安装前快照" "${rollback_fail_output}" "SNAPSHOT=kept"
assert_contains "回滚失败提示重试 cleanup-partial" "${rollback_fail_output}" \
    "sudo easy_all cleanup-partial"
assert_not_contains "回滚失败不得宣称已清理" "${rollback_fail_output}" "云端资源已保留；确认不再使用"

rollback_retry_output=$(EASY_ALL_GUARD_STATE_DIR="${TMP_DIR}/rb-state2" \
    EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${TMP_DIR}/rb-progress2/install-progress.env" \
    bash -c '
        set -Eeuo pipefail
        source "$1/profiles/cloudfront.sh"
        install_progress_begin combined cloudfront
        stop_maintenance_services() { :; }
        stop_services() { :; }
        cleanup_partial_install_local() { :; }
        cdn_cleanup_legacy_globalping_artifacts() { :; }
        cdn_legacy_reclaim_origin_firewall_rules() { :; }
        remove_cdn_traffic_protection_timer() { :; }
        cdn_traffic_counters_remove() { :; }
        remove_certbot_deploy_hook() { :; }
        cdn_remove_origin_lineage() { :; }
        remove_daily_reboot_schedule() { :; }
        cleanup_partial_install_files() { install_progress_clear; }
        cdn_print_cloud_inventory() { :; }
        rollback_fresh_install
        [[ ! -f "$(install_progress_file)" ]] && printf "MARKER=cleared\n"
    ' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "清理成功后才清标记" "${rollback_retry_output}" "MARKER=cleared"

# 29b. restore_state_file 失败语义：返回非零，调用方（回滚）必须继续并保留恢复材料
restore_dir="${TMP_DIR}/restore-semantics"
mkdir -p "${restore_dir}/backup"
printf 'STATE_VERSION=1\n' >"${restore_dir}/backup/state.env"
restore_state_call() { # $1=目标 $2=是否注入 mv 失败
    local target=$1 fail_mv=${2:-0}
    bash -c '
        set -Eeuo pipefail
        source "$1/lib/state.sh"
        source "$1/lib/profile-common.sh"
        die() { printf "DIE:%s\n" "$*" >&2; exit 1; }
        fail() { printf "FAIL:%s\n" "$*" >&2; return 1; }
        cleanup_files=()
        if [[ "${FAIL_MV:-0}" == "1" ]]; then mv() { return 1; }; fi
        status=0
        restore_state_file "$2" "$3" || status=$?
        printf "STATUS=%s\n" "${status}"
    ' _ "${ROOT_DIR}" "${restore_dir}/backup/state.env" "${target}" 2>&1
}
restore_temp_output=$(FAIL_MV=0 restore_state_call "${restore_dir}/missing/state.env") \
    || true
assert_contains "恢复暂存创建失败必须返回错误" "${restore_temp_output}" \
    "创建状态恢复暂存文件失败"
assert_contains "恢复暂存创建失败必须返回 1" "${restore_temp_output}" "STATUS=1"
assert_not_contains "恢复暂存创建失败不得 die 退出整个回滚" "${restore_temp_output}" "DIE:"
mkdir -p "${restore_dir}/target"
restore_mv_output=$(FAIL_MV=1 restore_state_call "${restore_dir}/target/state.env") \
    || true
assert_contains "恢复最终 mv 失败必须返回错误" "${restore_mv_output}" \
    "原子恢复状态文件失败"
assert_contains "恢复最终 mv 失败必须返回 1" "${restore_mv_output}" "STATUS=1"
assert_not_contains "恢复最终 mv 失败不得 die 退出整个回滚" "${restore_mv_output}" "DIE:"

# 状态恢复失败：其余文件继续恢复，RUNTIME_TMP（含 part.* 备份）保留，临时 API 凭据删除。
preserve_dir="${TMP_DIR}/rollback-preserve"
mkdir -p "${preserve_dir}/tmp"
preserve_output=$(
    TMPDIR="${preserve_dir}/tmp" \
    RUNTIME_TMP= \
    EASY_ALL_STATE_DIR_OVERRIDE="${preserve_dir}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${preserve_dir}/subs" \
    EASY_ALL_CERT_DIR_OVERRIDE="${preserve_dir}/state/certs" \
    RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${preserve_dir}/runtime-write.lock" \
        bash -c '
            set -Eeuo pipefail
            source "$1/profiles/anytls.sh"
            printf "%s\n" "${RUNTIME_TMP}" >"$2"
            mkdir -p "${STATE_DIR}" "${CERT_DIR}" "${SUBSCRIPTION_DIR}"
            UPDATE_SUB_BACKUP_DIR=$(make_temp_dir)
            printf "old-state\n" >"${UPDATE_SUB_BACKUP_DIR}/state.env"
            printf "new-cert\n" >"${CERT_FILE}"
            printf "old-cert\n" >"${UPDATE_SUB_BACKUP_DIR}/certificate.pem"
            UPDATE_SUB_ROLLBACK_NO_RESTART=1
            mv() { return 1; }
            status=0
            rollback_subscription_update || status=$?
            printf "ROLLBACK-STATUS=%s CERT=%s PRESERVE=%s\n" "${status}" \
                "$(cat "${CERT_FILE}")" "${PRESERVE_RUNTIME_TMP:-unset}"
            printf "headers\n" >"${RUNTIME_TMP}/cloudflare-api-headers"
            printf "payload\n" >"${RUNTIME_TMP}/cloudflare-api-payload"
            printf "X-Easy-All-Origin-Key: test-origin-key\n" >"${RUNTIME_TMP}/origin-header"
            cleanup
            printf "RUNTIME-TMP-EXISTS=%s\n" \
                "$([[ -d "${RUNTIME_TMP}" ]] && echo yes || echo no)"
            printf "HEADERS-EXISTS=%s PAYLOAD-EXISTS=%s ORIGIN-EXISTS=%s\n" \
                "$([[ -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] && echo yes || echo no)" \
                "$([[ -e "${RUNTIME_TMP}/cloudflare-api-payload" ]] && echo yes || echo no)" \
                "$([[ -e "${RUNTIME_TMP}/origin-header" ]] && echo yes || echo no)"
        ' _ "${ROOT_DIR}" "${preserve_dir}/runtime-path" 2>&1
) || true
assert_contains "回滚中的状态恢复失败不得中止其余恢复" "${preserve_output}" \
    "ROLLBACK-STATUS=0"
assert_contains "状态恢复失败后证书继续恢复" "${preserve_output}" "CERT=old-cert"
assert_contains "状态恢复失败后设置保留临时目录" "${preserve_output}" "PRESERVE=1"
assert_contains "状态恢复失败后打印备份路径" "${preserve_output}" \
    "状态文件回滚失败；已保留回滚备份"
assert_contains "清理后 RUNTIME_TMP 仍存在" "${preserve_output}" "RUNTIME-TMP-EXISTS=yes"
assert_contains "保留前删除 API 请求头" "${preserve_output}" "HEADERS-EXISTS=no"
assert_contains "保留前删除 API 请求体" "${preserve_output}" "PAYLOAD-EXISTS=no"
assert_contains "保留前删除含源站密钥的探活头" "${preserve_output}" "ORIGIN-EXISTS=no"
preserve_runtime=$(<"${preserve_dir}/runtime-path")
[[ -d "${preserve_runtime}" ]] || fail "状态恢复失败后 RUNTIME_TMP 必须保留"
[[ -n "$(find "${preserve_runtime}" -maxdepth 1 -name 'part.*' -print -quit)" ]] \
    || fail "保留的 RUNTIME_TMP 必须包含 part.* 回滚备份"
[[ -z "$(find "${preserve_runtime}" -maxdepth 2 \
    \( -name 'cloudflare-api-headers' -o -name 'cloudflare-api-payload' \
    -o -name 'origin-header' \) -print -quit)" ]] \
    || fail "保留的 RUNTIME_TMP 不得残留 API 凭据与源站头密钥文件"

# 29c. AnyTLS 凭据钩子：模式 1 安装尾部不再 command not found，保留目录不残留 Bearer Token
anytls_hook_body=$(bash -c 'source "$1/profiles/anytls.sh"; declare -F clear_profile_credentials' \
    _ "${ROOT_DIR}" 2>&1) || fail "AnyTLS 必须定义 clear_profile_credentials（127 退出的根因）"
assert_contains "AnyTLS 凭据钩子已定义" "${anytls_hook_body}" "clear_profile_credentials"
anytls_hook_output=$(
    RUNTIME_TMP="${TMP_DIR}/anytls-hook-runtime" \
        bash -c '
            set -Eeuo pipefail
            source "$1/profiles/anytls.sh"
            mkdir -p "${RUNTIME_TMP}"
            printf "Bearer secret-token\n" >"${RUNTIME_TMP}/cloudflare-api-headers"
            printf "payload\n" >"${RUNTIME_TMP}/cloudflare-api-payload"
            CLOUDFLARE_API_TOKEN=secret-token
            clear_profile_credentials
            [[ ! -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] || exit 4
            [[ ! -e "${RUNTIME_TMP}/cloudflare-api-payload" ]] || exit 5
            [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] || exit 6
            printf "HOOK-OK\n"
        ' _ "${ROOT_DIR}" 2>&1
) || fail "AnyTLS 凭据钩子调用失败（模式 1 安装尾部会以 127 退出）"
assert_contains "AnyTLS 钩子删除请求头/请求体并清空 Token" "${anytls_hook_output}" "HOOK-OK"

# 29d. 确认阶段收到 INT/TERM：凭据在确认入口之前已清除，130/143 退出且跳过回滚与后续清理。
# 不分配终端、不后台运行：替身直接进入确认阶段并向自身发送信号，避免依赖 pty/python3。
# 必须使用真实的 clear_profile_credentials（CloudFront 钩子覆盖 AWS 变量），只检查哨兵文件与变量。
confirm_dir="${TMP_DIR}/confirm-signal"
for confirm_signal in INT TERM; do
    confirm_case="${confirm_dir}/${confirm_signal}"
    mkdir -p "${confirm_case}/state" "${confirm_case}/subs" "${confirm_case}/runtime"
    confirm_expected=130
    if [[ "${confirm_signal}" == "TERM" ]]; then
        confirm_expected=143
    fi
    cat >"${confirm_case}/confirm.sh" <<'SCRIPT'
set -Eeuo pipefail
source "${EASY_ALL_TEST_ROOT}/profiles/cloudfront.sh"
install_cleanup_perform() { : >"${CONFIRM_PERFORM}"; }
install_cleanup_after_failure() {
    : >"${CONFIRM_READY}"
    local precheck=ok
    [[ ! -e "${RUNTIME_TMP}/cloudflare-api-headers" ]] || precheck=fail
    [[ ! -e "${RUNTIME_TMP}/cloudflare-api-payload" ]] || precheck=fail
    [[ ! -e "${RUNTIME_TMP}/origin-header" ]] || precheck=fail
    [[ ! -e "${RUNTIME_TMP}/cloudfront-distribution.json" ]] || precheck=fail
    [[ ! -e "${RUNTIME_TMP}/cloudfront-disable.json" ]] || precheck=fail
    [[ -z "${CLOUDFLARE_API_TOKEN:-}" ]] || precheck=fail
    [[ -z "${AWS_ACCESS_KEY_ID:-}" ]] || precheck=fail
    [[ -z "${AWS_SECRET_ACCESS_KEY:-}" ]] || precheck=fail
    printf '%s\n' "${precheck}" >"${CONFIRM_PRECHECK}"
    kill -"${CONFIRM_SIGNAL}" $$
    : >"${CONFIRM_AFTER}"
}
mkdir -p "${RUNTIME_TMP}"
printf 'Authorization: Bearer sentinel-token\n' >"${RUNTIME_TMP}/cloudflare-api-headers"
printf 'payload\n' >"${RUNTIME_TMP}/cloudflare-api-payload"
printf 'origin-header\n' >"${RUNTIME_TMP}/origin-header"
printf '{"DistributionConfig":{}}\n' >"${RUNTIME_TMP}/cloudfront-distribution.json"
printf '{"DistributionConfig":{}}\n' >"${RUNTIME_TMP}/cloudfront-disable.json"
CLOUDFLARE_API_TOKEN=not-a-real-token
AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY
INSTALL_ROLLBACK_ON_EXIT=1
exit 1
SCRIPT
    confirm_status=0
    EASY_ALL_TEST_ROOT="${ROOT_DIR}" \
    CONFIRM_SIGNAL="${confirm_signal}" \
    CONFIRM_READY="${confirm_case}/ready" \
    CONFIRM_PRECHECK="${confirm_case}/precheck" \
    CONFIRM_AFTER="${confirm_case}/after" \
    CONFIRM_PERFORM="${confirm_case}/perform" \
    RUNTIME_TMP="${confirm_case}/runtime" \
    EASY_ALL_STATE_DIR_OVERRIDE="${confirm_case}/state" \
    EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${confirm_case}/subs" \
        bash "${confirm_case}/confirm.sh" >"${confirm_case}/output.log" 2>&1 \
        || confirm_status=$?
    confirm_result="STATUS=${confirm_status} READY=$([[ -e "${confirm_case}/ready" ]] \
        && echo yes || echo no) PRECHECK=$(cat "${confirm_case}/precheck" 2>/dev/null || true) \
        AFTER=$([[ -e "${confirm_case}/after" ]] && echo yes || echo no) \
        PERFORM=$([[ -e "${confirm_case}/perform" ]] && echo yes || echo no)"
    assert_contains "确认阶段 ${confirm_signal} 以 ${confirm_expected} 退出" \
        "${confirm_result}" "STATUS=${confirm_expected}"
    assert_contains "确认阶段 ${confirm_signal} 确实到达确认入口" "${confirm_result}" "READY=yes"
    assert_contains "确认阶段 ${confirm_signal} 进入确认前凭据已清除" "${confirm_result}" "PRECHECK=ok"
    assert_contains "确认阶段 ${confirm_signal} 跳过后续清理" "${confirm_result}" "AFTER=no"
    assert_contains "确认阶段 ${confirm_signal} 不执行回滚" "${confirm_result}" "PERFORM=no"
done

# 29e. verify-cores 临时目录：自建的成功/失败路径回收，外部注入的不删除。
verify_stub_repo="${TMP_DIR}/verify-cores-repo"
mkdir -p "${verify_stub_repo}"
cp -R "${ROOT_DIR}/lib" "${ROOT_DIR}/profiles" "${ROOT_DIR}/scripts" \
    "${ROOT_DIR}/templates" "${verify_stub_repo}/"
cat >"${verify_stub_repo}/lib/singbox-core.sh" <<'STUB'
EASY_ALL_SINGBOX_CORE_LOADED=1
SINGBOX_VERSION=1.14.4
singbox_version() { printf '%s\n' "${SINGBOX_VERSION}"; }
singbox_binary_version() { [[ -x "$1" ]] && printf '%s\n' "${SINGBOX_VERSION}"; }
singbox_installed_version() { singbox_binary_version "${SINGBOX_BIN}"; }
download_singbox() {
    install -d -m 0755 "$(dirname "${SINGBOX_BIN}")"
    printf '#!/bin/sh\nexit 0\n' >"${SINGBOX_BIN}"
    chmod 0755 "${SINGBOX_BIN}"
}
install_singbox_service() { :; }
STUB
cat >"${verify_stub_repo}/lib/caddy-core.sh" <<'STUB'
EASY_ALL_CADDY_CORE_LOADED=1
CADDY_VERSION=2.11.9
caddy_version() { printf '%s\n' "${CADDY_VERSION}"; }
caddy_binary_version() { [[ -x "$1" ]] && printf 'v%s\n' "${CADDY_VERSION}"; }
caddy_installed_version() { caddy_binary_version "${CADDY_BIN}"; }
download_caddy() {
    install -d -m 0755 "$(dirname "${CADDY_BIN}")"
    printf '#!/bin/sh\nexit 0\n' >"${CADDY_BIN}"
    chmod 0755 "${CADDY_BIN}"
}
install_caddy_service() { :; }
STUB
verify_success_tmp="${TMP_DIR}/verify-success-tmp"
mkdir -p "${verify_success_tmp}"
verify_success_output=$(
    TMPDIR="${verify_success_tmp}" \
    RUNTIME_TMP= \
    EASY_ALL_DOWNLOAD_CORES=1 \
    SINGBOX_BIN="${TMP_DIR}/verify-core-bin/sing-box" \
    CADDY_BIN="${TMP_DIR}/verify-core-bin/caddy" \
        bash "${verify_stub_repo}/scripts/verify-cores.sh" 2>&1
) || fail "verify-cores 成功路径未通过：${verify_success_output}"
assert_contains "verify-cores 成功完成" "${verify_success_output}" "ok - verify-cores 完成"
[[ -z "$(find "${verify_success_tmp}" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
    || fail "verify-cores 成功退出必须回收自建临时目录"

verify_fail_tmp="${TMP_DIR}/verify-fail-tmp"
mkdir -p "${verify_fail_tmp}" "${TMP_DIR}/verify-fake-bin"
printf '#!/usr/bin/env bash\nexit 6\n' >"${TMP_DIR}/verify-fake-bin/curl"
chmod 0755 "${TMP_DIR}/verify-fake-bin/curl"
verify_fail_output=$(
    TMPDIR="${verify_fail_tmp}" \
    RUNTIME_TMP= \
    EASY_ALL_DOWNLOAD_CORES=1 \
    PATH="${TMP_DIR}/verify-fake-bin:${PATH}" \
        bash "${ROOT_DIR}/scripts/verify-cores.sh" 2>&1
) || true
assert_contains "verify-cores 下载失败如实报错" "${verify_fail_output}" "下载 sing-box 归档失败"
[[ -z "$(find "${verify_fail_tmp}" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null || true)" ]] \
    || fail "verify-cores 下载失败退出必须回收自建临时目录"

verify_external="${TMP_DIR}/verify-external-runtime"
mkdir -p "${verify_external}"
verify_external_output=$(
    TMPDIR="${verify_fail_tmp}" \
    RUNTIME_TMP="${verify_external}" \
    EASY_ALL_DOWNLOAD_CORES=1 \
    PATH="${TMP_DIR}/verify-fake-bin:${PATH}" \
        bash "${ROOT_DIR}/scripts/verify-cores.sh" 2>&1
) || true
assert_contains "verify-cores 外部注入失败仍如实报错" "${verify_external_output}" \
    "下载 sing-box 归档失败"
[[ -d "${verify_external}" ]] || fail "verify-cores 不得删除外部注入的 RUNTIME_TMP"

# 29f. bootstrap SIGTERM 回收暂存目录（e2e）。
# register-command 的 TERM 回收需要 root 且会替换 /usr/local/lib，非 root CI 无法 e2e；
# 这里只做静态核对，并在交付证据中说明限制，不写成已验证。
if command -v python3 >/dev/null 2>&1; then
    bootstrap_dir="${TMP_DIR}/bootstrap-term"
    mkdir -p "${bootstrap_dir}/tmp-root" "${bootstrap_dir}/bin"
    cat >"${bootstrap_dir}/bin/id" <<'STUB'
#!/usr/bin/env bash
if [[ "${1:-}" == "-u" ]]; then printf '0\n'; exit 0; fi
exec /usr/bin/id "$@"
STUB
    cat >"${bootstrap_dir}/bin/mktemp" <<'STUB'
#!/usr/bin/env bash
dir="${BOOTSTRAP_TMP_ROOT}/tmp.$$.${RANDOM}"
mkdir -p "${dir}" || exit 1
printf '%s\n' "${dir}"
STUB
    cat >"${bootstrap_dir}/bin/git" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$$" >"${BOOTSTRAP_GIT_PID}"
printf 'ready\n' >"${BOOTSTRAP_READY}"
sleep 30
STUB
    chmod 0755 "${bootstrap_dir}/bin/id" "${bootstrap_dir}/bin/mktemp" \
        "${bootstrap_dir}/bin/git"
    bootstrap_result=$(
        BOOTSTRAP_TMP_ROOT="${bootstrap_dir}/tmp-root" \
        BOOTSTRAP_GIT_PID="${bootstrap_dir}/git.pid" \
        BOOTSTRAP_READY="${bootstrap_dir}/ready" \
        BOOTSTRAP_LOG="${bootstrap_dir}/bootstrap.log" \
        EASY_ALL_STATE_FILE_OVERRIDE="${bootstrap_dir}/no-state" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${bootstrap_dir}/no-marker" \
        PATH="${bootstrap_dir}/bin:${PATH}" \
            python3 - "${ROOT_DIR}/bootstrap.sh" <<'PY'
import os, signal, sys, time
pid = os.fork()
if pid == 0:
    log = os.open(os.environ["BOOTSTRAP_LOG"], os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.dup2(log, 1)
    os.dup2(log, 2)
    os.setsid()
    os.execvpe("bash", ["bash", sys.argv[1], "help"], os.environ)
deadline = time.time() + 10
while time.time() < deadline and not os.path.exists(os.environ["BOOTSTRAP_READY"]):
    time.sleep(0.05)
if not os.path.exists(os.environ["BOOTSTRAP_READY"]):
    os.kill(pid, signal.SIGKILL)
    print("READY-TIMEOUT")
    sys.exit(3)
os.killpg(os.getpgid(pid), signal.SIGTERM)
_, status = os.waitpid(pid, 0)
code = os.WEXITSTATUS(status) if os.WIFEXITED(status) else 128 + os.WTERMSIG(status)
print("STATUS=%d" % code)
PY
    ) || fail "bootstrap SIGTERM e2e 驱动失败"
    assert_contains "bootstrap 收到 SIGTERM 以 143 退出" "${bootstrap_result}" "STATUS=143"
    [[ -z "$(find "${bootstrap_dir}/tmp-root" -mindepth 1 -maxdepth 1 -print -quit)" ]] \
        || fail "bootstrap 收到 SIGTERM 必须回收临时目录"
else
    skip_case "bootstrap SIGTERM 回收" "缺少 python3"
fi
register_static=$(sed -n \
    '/if \[\[ "\${command}" == "register-command" \]\]/,/unified_register_easy_all_command/p' \
    "${ROOT_DIR}/easy_all")
assert_contains "register-command 保留 EXIT 清理" "${register_static}" "trap cleanup EXIT"
assert_contains "register-command 显式处理 SIGTERM" "${register_static}" "trap 'exit 143' TERM"
assert_contains "register-command 显式处理 SIGINT" "${register_static}" "trap 'exit 130' INT"

# 29g. register 暂存目录的回收只针对「陈旧」目录：register-command 不能额外取锁
# （bootstrap 已持有同一把 flock，子进程再取会死锁），所以必须用 mtime 阈值区分
# “上次中断遗留”与“另一个并发注册正在填装”，不能一刀切删除。
# easy_all 的 EASY_ALL_INSTALL_DIR 是只读固定路径，这里抽出函数原文、改环境变量驱动。
reclaim_impl="${TMP_DIR}/register-reclaim.sh"
{
    printf 'info() { printf "INFO: %%s\\n" "$*"; }\n'
    sed -n '/^reclaim_stale_register_stages() {$/,/^}$/p' "${ROOT_DIR}/easy_all"
    printf 'reclaim_stale_register_stages\n'
} >"${reclaim_impl}"
grep -q '^reclaim_stale_register_stages() {' "${reclaim_impl}" \
    || fail "无法提取 reclaim_stale_register_stages 实现（函数签名可能已改动）"
reclaim_case="${TMP_DIR}/register-reclaim"
rm -rf -- "${reclaim_case}"
mkdir -p "${reclaim_case}/lib/easy_all.stage.old/deep" \
    "${reclaim_case}/lib/easy_all.stage.fresh" \
    "${reclaim_case}/lib/easy_all.previous.4242"
# 陈旧：mtime 退到很远的过去；新鲜：保持当前时间（另一个并发注册的暂存目录）。
touch -t 202001010000 "${reclaim_case}/lib/easy_all.stage.old" \
    "${reclaim_case}/lib/easy_all.stage.old/deep"
reclaim_output=$(EASY_ALL_INSTALL_DIR="${reclaim_case}/lib/easy_all" \
    bash "${reclaim_impl}" 2>&1)
[[ ! -d "${reclaim_case}/lib/easy_all.stage.old" ]] \
    || fail "陈旧 stage 目录（中断遗留）必须被回收"
[[ -d "${reclaim_case}/lib/easy_all.stage.fresh" ]] \
    || fail "新鲜 stage 目录（并发注册正在填装）不得被回收"
[[ -d "${reclaim_case}/lib/easy_all.previous.4242" ]] \
    || fail "reclaim 不得触碰 .previous.* 目录"
assert_contains "回收陈旧 stage 目录会留一条日志" "${reclaim_output}" \
    "已回收上次注册中断遗留的暂存目录"
rm -rf -- "${reclaim_case}"

# 30. 旧 cdn/combined 标记：launcher 不加载已删除的 Profile，只保留新键路由
legacy_route=$(bash -c '
    source "$1"
    for mode in cdn combined reality; do
        # launcher_die 直接退出进程：每个模式必须在独立子 shell 里探测。
        if ( profile_file "${mode}" >/dev/null 2>&1 ); then
            printf "%s=loaded\n" "${mode}"
        else
            printf "%s=rejected\n" "${mode}"
        fi
    done
    printf "combined-cloudfront=%s\n" "$(basename "$(profile_file combined-cloudfront)")"
    printf "combined-cloudflare=%s\n" "$(basename "$(profile_file combined-cloudflare)")"
' _ "${ROOT_DIR}/easy_all" 2>&1)
for legacy in cdn combined reality; do
    assert_contains "旧模式 ${legacy} 不加载 Profile" "${legacy_route}" "${legacy}=rejected"
done
assert_contains "模式 5 路由到 combined.sh" "${legacy_route}" "combined-cloudfront=combined.sh"
assert_contains "模式 3 路由到 combined-cloudflare.sh" "${legacy_route}" \
    "combined-cloudflare=combined-cloudflare.sh"
[[ ! -e "${ROOT_DIR}/profiles/cdn.sh" ]] || fail "旧 profiles/cdn.sh 必须已删除"

# 新链路清理删除自有 certbot lineage，且不调用云端 API
core_cleanup_body=$(awk '/^cleanup_partial_install\(\)/,/^}/' "${ROOT_DIR}/lib/cloudfront-mode.sh")
assert_contains "新链路清理删除自有 certbot lineage" "${core_cleanup_body}" \
    "certificate_remove_lineage"
assert_not_contains "本机清理不调用 AWS" "${core_cleanup_body}" "aws_cli"
assert_not_contains "本机清理不调用 Cloudflare API" "${core_cleanup_body}" \
    "cloudflare_api_request"
lineage_body=$(awk '/^certificate_remove_lineage\(\)/,/^}/' "${ROOT_DIR}/lib/runtime-core.sh")
assert_contains "lineage 删除只用固定自有名称" "${lineage_body}" "CERTBOT_LINEAGE_NAME"

# 31. uninstall_all 入口级用例：无参数默认清理云端与本机（design §8）。
# 宿主边界（systemctl/ufw/iptables/crontab/sshd/curl/aws/flock/install）用 PATH 替身记录；
# 删除边界用 rm 替身：只真删 ${case_dir} 内的路径，其余路径写 refusals 日志后跳过。
# COMMAND_PATH/COMMAND_INSTALL_DIR/UFW_DEFAULT_CONFIG/CDN_TRAFFIC_GUARD_*.{service,timer}
# 是生产库里的固定字面量，测试不改写它们，只按白名单断言没有触达别的宿主路径。
ENTRY_BIN="${TMP_DIR}/uninstall-entry/bin"
ENTRY_REAL_RM=$(command -v rm)
ENTRY_REAL_INSTALL=$(command -v install)
mkdir -p "${ENTRY_BIN}"

cat >"${ENTRY_BIN}/rm" <<'STUB'
#!/usr/bin/env bash
flags=()
paths=()
for arg in "$@"; do
    case "$arg" in
    --) ;;
    -*) flags+=("$arg") ;;
    *)
        case "$arg" in
        "${ENTRY_TMP_ROOT}" | "${ENTRY_TMP_ROOT}"/*) paths+=("$arg") ;;
        *) printf '%s\n' "$arg" >>"${ENTRY_RM_LOG}" ;;
        esac
        ;;
    esac
done
((${#paths[@]})) || exit 0
exec "${ENTRY_REAL_RM}" "${flags[@]}" "${paths[@]}"
STUB

cat >"${ENTRY_BIN}/iptables" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "iptables $*" >>"${ENTRY_CMD_LOG}"
[[ "${ENTRY_IPTABLES_FAIL:-0}" == "1" ]] && exit 1
exit 0
STUB

cat >"${ENTRY_BIN}/install" <<'STUB'
#!/usr/bin/env bash
args=()
while (($#)); do
    case "$1" in
    -o | --owner | -g | --group) shift 2 ;;
    *) args+=("$1"); shift ;;
    esac
done
exec "${ENTRY_REAL_INSTALL}" "${args[@]}"
STUB

for entry_stub in systemctl ufw crontab sshd; do
    cat >"${ENTRY_BIN}/${entry_stub}" <<STUB
#!/usr/bin/env bash
printf '%s\n' "${entry_stub} \$*" >>"\${ENTRY_CMD_LOG}"
exit 0
STUB
done

cat >"${ENTRY_BIN}/flock" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "flock $*" >>"${ENTRY_CMD_LOG}"
exit 0
STUB

cat >"${ENTRY_BIN}/curl" <<'STUB'
#!/usr/bin/env bash
method=GET
url=""
while (($#)); do
    case "$1" in
    -X) method=$2; shift 2 ;;
    -H | --data-binary | -w | --retry | --connect-timeout | --max-time) shift 2 ;;
    -sS | -s | -S | -fsSL) shift ;;
    *) url=$1; shift ;;
    esac
done
printf '%s %s\n' "${method}" "${url}" >>"${ENTRY_CURL_LOG}"
if [[ "${ENTRY_CLOUD_FAIL:-0}" == "1" ]]; then
    printf 'cloud api unavailable\n500'
    exit 0
fi
case "${method}" in
GET)
    case "${url}" in
    *"/dns_records?"*)
        type=""
        host=""
        query=${url#*\?}
        old_ifs=${IFS}
        IFS='&'
        for part in ${query}; do
            case "${part}" in
            type=*) type=${part#type=} ;;
            name=*) host=${part#name=} ;;
            esac
        done
        IFS=${old_ifs}
        content=${ENTRY_A_CONTENT}
        proxied=false
        if [[ "${type}" != "A" ]]; then
            content=${ENTRY_CNAME_CONTENT}
        fi
        if [[ "${host}" == "${ENTRY_PROXIED_HOST}" ]]; then
            proxied=true
        fi
        printf '{"success":true,"result":[{"id":"rec-%s-%s","name":"%s","type":"%s","content":"%s","comment":"%s","proxied":%s}]}\n200' \
            "${host}" "${type}" "${host}" "${type}" "${content}" "${ENTRY_RECORD_COMMENT}" "${proxied}"
        ;;
    *"/rulesets/"*)
        digest=$(printf '%s' "${ENTRY_SUB_HOST}" | openssl dgst -sha256 | awk '{print $NF}' | tr 'A-F' 'a-f')
        expression="http.host eq \\\"${ENTRY_SUB_HOST}\\\""
        printf '{"success":true,"result":{"rules":[{"id":"%s","ref":"easy_all-%s","action":"route","expression":"%s"}]}}\n200' \
            "${ENTRY_RULE_ID}" "${digest:0:16}" "${expression}"
        ;;
    *) printf '{"success":true,"result":null}\n200' ;;
    esac
    ;;
*)
    printf '{"success":true,"result":null}\n200'
    ;;
esac
STUB

cat >"${ENTRY_BIN}/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ENTRY_AWS_LOG}"
[[ "${ENTRY_AWS_FAIL:-0}" == "1" ]] && exit 254
# 传播竞态：同一查询需要先返回旧值再返回新值，按行弹出的序列文件模拟。
next_response() { # $1=序列文件 $2=默认响应
    local file=$1 default=$2 line
    if [[ -n "${file}" && -s "${file}" ]]; then
        line=$(head -n 1 "${file}")
        tail -n +2 "${file}" >"${file}.next"
        mv "${file}.next" "${file}"
        printf '%s\n' "${line}"
    else
        printf '%s\n' "${default}"
    fi
}
joined=" $* "
case "${joined}" in
*" cloudfront get-distribution-config "*) printf '%s\n' "${ENTRY_DIST_CONFIG_JSON}" ;;
*" cloudfront get-distribution "*)
    response=$(next_response "${ENTRY_DIST_SEQUENCE_FILE:-}" "${ENTRY_DIST_STATUS_JSON}")
    # 回放真实服务约束：delete-distribution 要求分发已禁用（最后一次观察 Enabled=false）。
    # Enabled 是布尔值，`// empty` 会把 false 当空值吞掉，必须显式 tostring。
    jq -r '.Distribution.DistributionConfig.Enabled | tostring' <<<"${response}" \
        >>"${ENTRY_AWS_LOG}.dist-enabled" 2>/dev/null || true
    # 真实 CLI 按 --query/--output 渲染响应：旧实现只问 Status（text），新实现取整份 JSON。
    if [[ "${joined}" == *" --query "* ]]; then
        printf 'Deployed\n'
    else
        printf '%s\n' "${response}"
    fi
    ;;
*" cloudfront update-distribution "*) printf '{}\n' ;;
*" cloudfront delete-distribution "*)
    last_enabled=$(tail -n 1 "${ENTRY_AWS_LOG}.dist-enabled" 2>/dev/null || true)
    if [[ "${last_enabled}" != "false" ]]; then
        printf 'DistributionNotDisabled\n' >&2
        exit 254
    fi
    printf '{}\n'
    ;;
*" acm describe-certificate "*) next_response "${ENTRY_ACM_SEQUENCE_FILE:-}" "${ENTRY_ACM_DESCRIPTION_JSON}" ;;
*" acm list-tags-for-certificate "*) printf '%s\n' "${ENTRY_ACM_TAGS_JSON}" ;;
*" acm delete-certificate "*) printf '{}\n' ;;
*) printf '{}\n' ;;
esac
exit 0
STUB
chmod 0755 "${ENTRY_BIN}/rm" "${ENTRY_BIN}/iptables" "${ENTRY_BIN}/install" \
    "${ENTRY_BIN}/systemctl" "${ENTRY_BIN}/ufw" "${ENTRY_BIN}/crontab" \
    "${ENTRY_BIN}/sshd" "${ENTRY_BIN}/flock" "${ENTRY_BIN}/curl" "${ENTRY_BIN}/aws"

write_uninstall_entry_state() { # $1=状态文件 $2=协议
    local file=$1 protocol=$2
    {
        # PROTOCOL 是 save_state 必写的公共字段：缺了它这份状态不是产品能产出的形态，
        # 也过不了 load_state 的键名白名单（白名单要从 PROTOCOL 派生字段集）。
        printf '%s\n' \
            "STATE_VERSION=1" \
            "PROTOCOL=${protocol}" \
            'TCP_ACCELERATION=off' \
            'VPS_PUBLIC_IPV4=203.0.113.10' \
            'CF_ZONE=example.com' \
            'CLOUDFLARE_ZONE_ID=zone123' \
            'SUBSCRIPTION_MODE=deploy' \
            'SUB_DOWNLOAD_NAME=EASY_ALL' \
            'OWNER_TOKEN=ownertoken-zmtpjzfs' \
            'ALLOWED_TOKENS=\{\"owner\":\"token-abcdefgh\"\}' \
            'SUBSCRIPTION_CONFIG=\{\"allowedTokens\":\{\"owner\":\"token-abcdefgh\"\}\,\"nodes\":\[\]\}' \
            'MIHOMO_TEMPLATE_SNAPSHOT=1' \
            'SCHEDULED_REBOOT_ENABLED=0' \
            'SCHEDULED_REBOOT_HOUR=4'
        case "${protocol}" in
        anytls)
            printf '%s\n' \
                'DIRECT_DOMAIN=direct.example.com' \
                'DIRECT_NODE_NAME=direct' \
                'ANYTLS_PASSWORD=password-abcdefgh' \
                'SUBSCRIPTION_DOMAIN=sub.example.com' \
                'CLOUDFLARE_ORIGIN_RULESET_ID=rs1' \
                'CLOUDFLARE_ORIGIN_RULE_ID=rule1'
            ;;
        cloudflare)
            printf '%s\n' \
                'CF_NODE_DOMAIN=cf.example.com' \
                'CF_NODE_PREFIX=CF' \
                'VLESS_UUID=11111111-2222-4333-8444-555555555555' \
                'VLESS_PATH=/vless-0123456789ab' \
                'CLOUDFLARE_ORIGIN_CERT_ID=cert1' \
                'CLOUDFLARE_ORIGIN_CERT_EXPIRES_ON=2030-01-01'
            ;;
        cloudfront)
            printf '%s\n' \
                'CF_NODE_DOMAIN=cf.example.com' \
                'CF_NODE_PREFIX=CF' \
                'VLESS_UUID=11111111-2222-4333-8444-555555555555' \
                'VLESS_PATH=/vless-0123456789ab' \
                'SUBSCRIPTION_DOMAIN=sub.example.com' \
                'CF_ORIGIN_DOMAIN=origin.example.com' \
                'ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef' \
                'AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE' \
                'AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net' \
                'AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x' \
                'CDN_TRAFFIC_PROTECTION_GB=985'
            ;;
        combined-cloudflare)
            printf '%s\n' \
                'DIRECT_DOMAIN=direct.example.com' \
                'DIRECT_NODE_NAME=direct' \
                'ANYTLS_PASSWORD=password-abcdefgh' \
                'CF_NODE_DOMAIN=cf.example.com' \
                'CF_NODE_PREFIX=CF' \
                'VLESS_UUID=11111111-2222-4333-8444-555555555555' \
                'VLESS_PATH=/vless-0123456789ab' \
                'CLOUDFLARE_ORIGIN_RULESET_ID=rs1' \
                'CLOUDFLARE_ORIGIN_RULE_ID=rule1'
            ;;
        combined-cloudfront)
            printf '%s\n' \
                'DIRECT_DOMAIN=direct.example.com' \
                'DIRECT_NODE_NAME=direct' \
                'ANYTLS_PASSWORD=password-abcdefgh' \
                'CF_NODE_DOMAIN=cf.example.com' \
                'CF_NODE_PREFIX=CF' \
                'VLESS_UUID=11111111-2222-4333-8444-555555555555' \
                'VLESS_PATH=/vless-0123456789ab' \
                'SUBSCRIPTION_DOMAIN=sub.example.com' \
                'CF_ORIGIN_DOMAIN=origin.example.com' \
                'ORIGIN_HEADER_SECRET=0123456789abcdef0123456789abcdef' \
                'AWS_CLOUDFRONT_DISTRIBUTION_ID=EDFDVBD6EXAMPLE' \
                'AWS_CLOUDFRONT_DOMAIN=d111111abcdef8.cloudfront.net' \
                'AWS_ACM_CERTIFICATE_ARN=arn:aws:acm:us-east-1:123456789012:certificate/x' \
                'CDN_TRAFFIC_PROTECTION_GB=985'
            ;;
        esac
    } >"${file}"
}

run_uninstall_entry() { # $1=label $2=profile $3=protocol $4=归注释 $5=cloud_fail $6=aws_fail
    local label=$1 profile=$2 protocol=$3 comment=$4 cloud_fail=$5 aws_fail=$6
    local case_dir="${TMP_DIR}/uninstall-entry/${label}"
    local output status=0 proxied_host="cf.example.com"
    # 橙云 A 记录（模式 2/3 的节点域名）proxied=true；模式 1 的订阅域名也是橙云。
    [[ "${protocol}" == "anytls" ]] && proxied_host="sub.example.com"
    rm -rf -- "${case_dir}"
    mkdir -p "${case_dir}/state" "${case_dir}/websub/subscriptions" \
        "${case_dir}/singbox" "${case_dir}/caddy" "${case_dir}/units" \
        "${case_dir}/runtime" "${case_dir}/counter"
    write_uninstall_entry_state "${case_dir}/state/state.env" "${protocol}"
    printf 'abcdefghijklmnopqrstuvwxyz012345\n' >"${case_dir}/state/cloudflare.token"
    : >"${case_dir}/websub/subscriptions/base64.txt"
    : >"${case_dir}/singbox/sing-box"
    : >"${case_dir}/caddy/caddy"
    : >"${case_dir}/units/easy_all-singbox.service"
    : >"${case_dir}/units/easy_all-caddy.service"
    : >"${case_dir}/refusals.log"
    : >"${case_dir}/curl.log"
    : >"${case_dir}/aws.log"
    : >"${case_dir}/commands.log"
    output=$(
        PATH="${ENTRY_BIN}:${PATH}" \
        ENTRY_TMP_ROOT="${case_dir}" \
        ENTRY_REAL_RM="${ENTRY_REAL_RM}" \
        ENTRY_REAL_INSTALL="${ENTRY_REAL_INSTALL}" \
        ENTRY_RM_LOG="${case_dir}/refusals.log" \
        ENTRY_CURL_LOG="${case_dir}/curl.log" \
        ENTRY_AWS_LOG="${case_dir}/aws.log" \
        ENTRY_CMD_LOG="${case_dir}/commands.log" \
        ENTRY_CLOUD_FAIL="${cloud_fail}" \
        ENTRY_AWS_FAIL="${aws_fail}" \
        ENTRY_IPTABLES_FAIL="${ENTRY_IPTABLES_FAIL:-0}" \
        ENTRY_A_CONTENT="203.0.113.10" \
        ENTRY_CNAME_CONTENT="d111111abcdef8.cloudfront.net" \
        ENTRY_PROXIED_HOST="${proxied_host}" \
        ENTRY_RECORD_COMMENT="${comment}" \
        ENTRY_SUB_HOST="sub.example.com" \
        ENTRY_RULE_ID="rule1" \
        ENTRY_DIST_CONFIG_JSON='{"ETag":"ETAG1","DistributionConfig":{"Comment":"easy_all-cloudfront-cf.example.com","Aliases":{"Items":["cf.example.com","sub.example.com"]},"Origins":{"Items":[{"DomainName":"origin.example.com"}]},"Enabled":true}}' \
        ENTRY_DIST_STATUS_JSON='{"Distribution":{"Status":"Deployed","DistributionConfig":{"Enabled":false}}}' \
        ENTRY_DIST_SEQUENCE_FILE="${ENTRY_DIST_SEQUENCE_FILE:-}" \
        ENTRY_ACM_SEQUENCE_FILE="${ENTRY_ACM_SEQUENCE_FILE:-}" \
        ENTRY_ACM_DESCRIPTION_JSON='{"Certificate":{"DomainName":"cf.example.com","SubjectAlternativeNames":["sub.example.com"],"InUseBy":[]}}' \
        ENTRY_ACM_TAGS_JSON='{"Tags":[{"Key":"easy_all","Value":"managed"},{"Key":"easy_all-node","Value":"cf.example.com"}]}' \
        AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE \
        AWS_SECRET_ACCESS_KEY=test-secret-key-0123456789 \
        RUNTIME_TMP="${case_dir}/runtime" \
        RUNTIME_WRITE_LOCK_FILE_OVERRIDE="${case_dir}/runtime-write.lock" \
        CDN_TRAFFIC_COUNTER_DIR_OVERRIDE="${case_dir}/counter" \
        EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/websub/subscriptions" \
        EASY_ALL_CERT_DIR_OVERRIDE="${case_dir}/state/certs" \
        SINGBOX_BIN="${case_dir}/singbox/sing-box" \
        CADDY_BIN="${case_dir}/caddy/caddy" \
        SINGBOX_SERVICE_FILE="${case_dir}/units/easy_all-singbox.service" \
        CADDY_SERVICE_FILE="${case_dir}/units/easy_all-caddy.service" \
            bash -c '
                set -Eeuo pipefail
                source "$1/profiles/$2.sh"
                require_root() { :; }
                # 宿主边界：SSH/UFW/crontab/certbot/平台安全状态一律无副作用。
                restore_preinstall_firewall() { :; }
                restore_preinstall_ipv6() { :; }
                restore_platform_security_state() { :; }
                remove_daily_reboot_schedule() { :; }
                remove_certbot_deploy_hook() { :; }
                certificate_remove_lineage() { :; }
                # 生产轮询节奏由固定常量决定；这里只压缩 sleep，不改变判定条件。
                sleep() { :; }
                FORCE=1
                gate_status=0
                gate_message=$(uninstall_all --purge-cloud 2>&1) || gate_status=$?
                printf "GATE-STATUS=%s\n" "${gate_status}"
                printf "GATE-MESSAGE=%s\n" "${gate_message}"
                status=0
                uninstall_all || status=$?
                printf "UNINSTALL-STATUS=%s\n" "${status}"
            ' _ "${ROOT_DIR}" "${profile}" 2>&1
    ) || status=$?
    printf '%s\n' "${output}"
    return "${status}"
}

uninstall_entry_value() { # $1=输出 $2=字段
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -n 1
}

assert_uninstall_entry_cleanup() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1)) # $1=label $2=case_dir
    local label=$1 case_dir=$2 path
    for path in state websub singbox caddy; do
        [[ ! -e "${case_dir}/${path}" ]] || fail "${label}: 本机路径未被删除：${path}"
    done
    [[ ! -e "${case_dir}/units/easy_all-singbox.service" ]] \
        || fail "${label}: sing-box 单元文件未删除"
    [[ ! -e "${case_dir}/units/easy_all-caddy.service" ]] \
        || fail "${label}: Caddy 单元文件未删除"
}

assert_refusals_within() {
    TESTS_ASSERTED=$((TESTS_ASSERTED + 1)) # $1=label $2=日志 $3..=白名单
    local label=$1 log=$2 path candidate allowed
    shift 2
    while IFS= read -r path; do
        [[ -n "${path}" ]] || continue
        allowed=0
        for candidate in "$@"; do
            [[ "${path}" == "${candidate}" ]] && allowed=1
        done
        ((allowed == 1)) || fail "${label}: 触及白名单外的宿主路径：${path}"
    done <"${log}"
}

entry_anytls_dir="${TMP_DIR}/uninstall-entry/anytls"
entry_anytls_output=$(run_uninstall_entry anytls anytls anytls "easy_all anytls" 0 0)
assert_equal "模式 1 无参数卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_anytls_output}" UNINSTALL-STATUS)"
assert_equal "模式 1 无参数入口拒绝 --purge-cloud" "1" \
    "$(uninstall_entry_value "${entry_anytls_output}" GATE-STATUS)"
assert_contains "模式 1 参数门禁拒绝旧参数" "${entry_anytls_output}" \
    "uninstall 不支持参数"
assert_contains "模式 1 默认删除直连 A 记录" "$(<"${entry_anytls_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-direct.example.com-A"
assert_contains "模式 1 默认删除订阅 A 记录" "$(<"${entry_anytls_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-sub.example.com-A"
assert_contains "模式 1 默认删除 Origin Rule" "$(<"${entry_anytls_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/rulesets/rs1/rules/rule1"
assert_contains "模式 1 资源清单使用中性标题" "${entry_anytls_output}" "云端资源清单："
assert_contains "模式 1 收尾说明云端结果见上方输出" "${entry_anytls_output}" \
    "easy_all 本机内容已卸载；云端清理结果见上方输出"
assert_uninstall_entry_cleanup "模式 1" "${entry_anytls_dir}"
assert_contains "模式 1 拒绝删除宿主命令路径" "$(<"${entry_anytls_dir}/refusals.log")" \
    "/usr/local/bin/easy_all"
assert_contains "模式 1 拒绝删除宿主安装目录" "$(<"${entry_anytls_dir}/refusals.log")" \
    "/usr/local/lib/easy_all"
assert_refusals_within "模式 1" "${entry_anytls_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all"

entry_combined_cf_dir="${TMP_DIR}/uninstall-entry/combined-cloudflare"
entry_combined_cf_output=$(run_uninstall_entry combined-cloudflare combined-cloudflare \
    combined-cloudflare "easy_all combined-cloudflare" 0 0)
assert_equal "模式 3 无参数卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_combined_cf_output}" UNINSTALL-STATUS)"
assert_contains "模式 3 默认删除直连 A 记录" "$(<"${entry_combined_cf_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-direct.example.com-A"
assert_contains "模式 3 默认删除节点/订阅 A 记录" "$(<"${entry_combined_cf_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-cf.example.com-A"
assert_contains "模式 3 默认删除 Origin Rule" "$(<"${entry_combined_cf_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/rulesets/rs1/rules/rule1"
assert_contains "模式 3 清单点名节点/订阅 A 记录" "${entry_combined_cf_output}" \
    "节点/订阅 A 记录（橙云）: cf.example.com -> 203.0.113.10"
assert_uninstall_entry_cleanup "模式 3" "${entry_combined_cf_dir}"
assert_contains "模式 3 拒绝删除宿主命令路径" \
    "$(<"${entry_combined_cf_dir}/refusals.log")" "/usr/local/bin/easy_all"
assert_refusals_within "模式 3" "${entry_combined_cf_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all"

entry_cloudflare_dir="${TMP_DIR}/uninstall-entry/cloudflare"
entry_cloudflare_output=$(run_uninstall_entry cloudflare cloudflare cloudflare "easy_all cloudflare" 0 0)
assert_equal "模式 2 无参数卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_cloudflare_output}" UNINSTALL-STATUS)"
assert_contains "模式 2 默认删除橙云 A 记录" "$(<"${entry_cloudflare_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-cf.example.com-A"
assert_contains "模式 2 默认吊销 Origin CA" "$(<"${entry_cloudflare_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/certificates/cert1"
assert_uninstall_entry_cleanup "模式 2" "${entry_cloudflare_dir}"
assert_contains "模式 2 拒绝删除宿主命令路径" "$(<"${entry_cloudflare_dir}/refusals.log")" \
    "/usr/local/bin/easy_all"
assert_contains "模式 2 拒绝删除宿主安装目录" "$(<"${entry_cloudflare_dir}/refusals.log")" \
    "/usr/local/lib/easy_all"
assert_refusals_within "模式 2" "${entry_cloudflare_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all"

entry_mode2_dir="${TMP_DIR}/uninstall-entry/cloudfront"
entry_mode2_output=$(run_uninstall_entry cloudfront cloudfront cloudfront "easy_all cloudfront" 0 0)
assert_equal "模式 4 无参数卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_mode2_output}" UNINSTALL-STATUS)"
assert_contains "模式 4 默认删除 CloudFront 分发" "$(<"${entry_mode2_dir}/aws.log")" \
    "delete-distribution"
assert_contains "模式 4 删除前完成部署等待" "$(<"${entry_mode2_dir}/aws.log")" \
    "cloudfront get-distribution --id EDFDVBD6EXAMPLE"
assert_contains "模式 4 默认删除源站 A 记录" "$(<"${entry_mode2_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-origin.example.com-A"
assert_not_contains "模式 4 不出现直连 A 记录" "${entry_mode2_output}" "直连 A 记录:"
assert_uninstall_entry_cleanup "模式 4" "${entry_mode2_dir}"
assert_refusals_within "模式 4" "${entry_mode2_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.timer" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.service"

entry_cf_dir="${TMP_DIR}/uninstall-entry/combined-cloudfront"
entry_cf_output=$(run_uninstall_entry combined-cloudfront combined combined-cloudfront \
    "easy_all cloudfront" 0 0)
assert_equal "模式 5 无参数卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_cf_output}" UNINSTALL-STATUS)"
assert_contains "模式 5 默认删除 CloudFront 分发" "$(<"${entry_cf_dir}/aws.log")" \
    "delete-distribution"
assert_contains "模式 5 默认删除 ACM 证书" "$(<"${entry_cf_dir}/aws.log")" "acm delete-certificate"
assert_contains "模式 5 默认删除源站 A 记录" "$(<"${entry_cf_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-origin.example.com-A"
assert_contains "模式 5 默认删除节点 CNAME" "$(<"${entry_cf_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-cf.example.com-CNAME"
assert_contains "模式 5 默认删除直连 A 记录" "$(<"${entry_cf_dir}/curl.log")" \
    "DELETE https://api.cloudflare.com/client/v4/zones/zone123/dns_records/rec-direct.example.com-A"
assert_contains "模式 5 清单列出独立直连 A 记录" "${entry_cf_output}" \
    "直连 A 记录: direct.example.com -> 203.0.113.10"
assert_contains "模式 5 收尾披露 ACM validation CNAME" "${entry_cf_output}" \
    "若有 ACM validation CNAME 残留，需核实无其他证书使用后人工删除"
assert_uninstall_entry_cleanup "模式 5" "${entry_cf_dir}"
assert_contains "模式 5 拒绝删除宿主命令路径" "$(<"${entry_cf_dir}/refusals.log")" \
    "/usr/local/bin/easy_all"
assert_contains "模式 5 拒绝删除宿主安装目录" "$(<"${entry_cf_dir}/refusals.log")" \
    "/usr/local/lib/easy_all"
assert_contains "模式 5 拒绝删除宿主计量单元" "$(<"${entry_cf_dir}/refusals.log")" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.timer"
assert_refusals_within "模式 5" "${entry_cf_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.timer" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.service"

entry_fail_dir="${TMP_DIR}/uninstall-entry/cloud-fail"
entry_fail_output=$(run_uninstall_entry cloud-fail anytls anytls "easy_all anytls" 1 0)
assert_equal "云端失败时本机卸载照常完成但退出非零" "1" \
    "$(uninstall_entry_value "${entry_fail_output}" UNINSTALL-STATUS)"
assert_contains "云端失败时输出总体告警" "${entry_fail_output}" \
    "云端资源清理未完成；本机卸载继续"
assert_contains "云端失败时仍报告本机卸载完成" "${entry_fail_output}" \
    "easy_all 本机内容已卸载；云端清理结果见上方输出"
assert_uninstall_entry_cleanup "云端失败" "${entry_fail_dir}"
# 失败场景也按白名单上限核对：允许未执行到的删除不出现在日志，但不允许白名单外的宿主路径。
assert_refusals_within "云端失败" "${entry_fail_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all"

entry_both_dir="${TMP_DIR}/uninstall-entry/both-fail"
entry_both_output=$(ENTRY_IPTABLES_FAIL=1 run_uninstall_entry both-fail combined combined-cloudfront \
    "easy_all cloudfront" 1 1)
assert_equal "云端与本机同时失败时退出非零" "1" \
    "$(uninstall_entry_value "${entry_both_output}" UNINSTALL-STATUS)"
assert_contains "云端与本机同时失败时仍报告云端告警" "${entry_both_output}" \
    "云端资源清理未完成；本机卸载继续"
assert_contains "本机清理失败时保留现场" "${entry_both_output}" \
    "已保留本机状态与命令"
[[ -f "${entry_both_dir}/state/state.env" ]] \
    || fail "本机清理失败时不得删除状态文件"
[[ -d "${entry_both_dir}/websub/subscriptions" ]] \
    || fail "本机清理失败时不得删除订阅目录"
assert_refusals_within "云端与本机同时失败" "${entry_both_dir}/refusals.log" \
    "/usr/local/bin/easy_all" "/usr/local/lib/easy_all" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.timer" \
    "/etc/systemd/system/easy_all-cdn-traffic-guard.service"

# 32. 卸载传播竞态 a：禁用后的等待必须同时看到 Status=Deployed 与 Enabled=false。
# 传播期 get-distribution 仍返回旧配置（Deployed + Enabled=true）时，只按 Status 判定
# 会拿过期 ETag 去 delete-distribution 被服务端拒；序列先旧后新，删除必须成功。
ENTRY_DIST_SEQUENCE_FILE="${TMP_DIR}/dist-propagation-sequence.json"
printf '%s\n' \
    '{"Distribution":{"Status":"Deployed","DistributionConfig":{"Enabled":true}}}' \
    '{"Distribution":{"Status":"Deployed","DistributionConfig":{"Enabled":false}}}' \
    >"${ENTRY_DIST_SEQUENCE_FILE}"
entry_propagation_dir="${TMP_DIR}/uninstall-entry/propagation"
entry_propagation_output=$(run_uninstall_entry propagation cloudfront cloudfront \
    "easy_all cloudfront" 0 0)
unset ENTRY_DIST_SEQUENCE_FILE
assert_equal "旧 Deployed 后再见到禁用配置，卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_propagation_output}" UNINSTALL-STATUS)"
assert_contains "传播收敛后删除分发成功" "$(<"${entry_propagation_dir}/aws.log")" \
    "cloudfront delete-distribution"
assert_equal "传播期共查两次分发状态" "2" \
    "$(grep -c 'cloudfront get-distribution --id' "${entry_propagation_dir}/aws.log" || true)"

# 32b. 幂等重跑：分发已禁用（Enabled=false）时，等待首次返回即满足，不误报失败。
ENTRY_DIST_SEQUENCE_FILE="${TMP_DIR}/dist-already-disabled.json"
printf '%s\n' \
    '{"Distribution":{"Status":"Deployed","DistributionConfig":{"Enabled":false}}}' \
    >"${ENTRY_DIST_SEQUENCE_FILE}"
entry_disabled_dir="${TMP_DIR}/uninstall-entry/already-disabled"
entry_disabled_output=$(run_uninstall_entry already-disabled cloudfront cloudfront \
    "easy_all cloudfront" 0 0)
unset ENTRY_DIST_SEQUENCE_FILE
assert_equal "已禁用的分发卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_disabled_output}" UNINSTALL-STATUS)"
assert_equal "已禁用的分发只查一次状态" "1" \
    "$(grep -c 'cloudfront get-distribution --id' "${entry_disabled_dir}/aws.log" || true)"

# 33. 卸载传播竞态 b：删分发后 ACM 的 InUseBy 尚未收敛时，不能立即判为不归属。
# 首查带 InUseBy、第二次为空 → 有界重试后删除证书，退出码 0。
ENTRY_ACM_SEQUENCE_FILE="${TMP_DIR}/acm-settled-sequence.json"
printf '%s\n' \
    '{"Certificate":{"DomainName":"cf.example.com","SubjectAlternativeNames":["sub.example.com"],"InUseBy":["EDFDVBD6EXAMPLE"]}}' \
    '{"Certificate":{"DomainName":"cf.example.com","SubjectAlternativeNames":["sub.example.com"],"InUseBy":[]}}' \
    >"${ENTRY_ACM_SEQUENCE_FILE}"
entry_acm_settle_dir="${TMP_DIR}/uninstall-entry/acm-settle"
entry_acm_settle_output=$(run_uninstall_entry acm-settle combined combined-cloudfront \
    "easy_all cloudfront" 0 0)
unset ENTRY_ACM_SEQUENCE_FILE
assert_equal "ACM InUseBy 收敛后卸载退出 0" "0" \
    "$(uninstall_entry_value "${entry_acm_settle_output}" UNINSTALL-STATUS)"
assert_contains "InUseBy 收敛后删除 ACM 证书" "$(<"${entry_acm_settle_dir}/aws.log")" \
    "acm delete-certificate"
assert_equal "InUseBy 未收敛时重试 describe" "2" \
    "$(grep -c 'acm describe-certificate' "${entry_acm_settle_dir}/aws.log" || true)"

# 34. ACM 终态证书的重申请无法自愈（幂等 Token 只取回同一张证书）：必须快速失败、
# 点名 ARN 与删除指引，而不是在 validation CNAME 上空转到超时。
ACM_BIN="${TMP_DIR}/acm/bin"
mkdir -p "${ACM_BIN}"
cat >"${ACM_BIN}/aws" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${ACM_AWS_LOG}"
joined=" $* "
case "${joined}" in
*" acm describe-certificate "*) printf '%s\n' "${ACM_DESCRIBE_JSON}" ;;
*" acm list-tags-for-certificate "*)
    [[ "${ACM_TAGS_FAIL:-0}" != "1" ]] || exit 1
    printf '%s\n' "${ACM_TAGS_JSON}"
    ;;
*" acm request-certificate "*) printf '%s\n' "${ACM_REQUEST_ARN}" ;;
*) printf '{}\n' ;;
esac
exit 0
STUB
chmod 0755 "${ACM_BIN}/aws"

run_acm_terminal_case() { # $1=存量证书状态 $2=tags JSON $3=list-tags 查询失败
    local status_name=$1 tags_json=${2:-'{"Tags":[{"Key":"easy_all","Value":"managed"},{"Key":"easy_all-node","Value":"cf.example.com"}]}'}
    local tags_fail=${3:-0} case_dir="${TMP_DIR}/acm/${1}" describe_json status=0 output
    rm -rf -- "${case_dir}"
    mkdir -p "${case_dir}/state"
    describe_json=$(jq -cn --arg status "${status_name}" '{
        Certificate:{
            CertificateArn:"arn:aws:acm:us-east-1:123456789012:certificate/x",
            DomainName:"cf.example.com",
            Status:$status,
            SubjectAlternativeNames:["sub.example.com"],
            InUseBy:[],
            DomainValidationOptions:[{ResourceRecord:{
                Name:"_x.cf.example.com.",Type:"CNAME",Value:"_y.acm-validations.aws."}}]
        }}')
    output=$(PATH="${ACM_BIN}:${PATH}" \
        ACM_AWS_LOG="${case_dir}/aws.log" \
        ACM_DESCRIBE_JSON="${describe_json}" \
        ACM_TAGS_JSON="${tags_json}" \
        ACM_TAGS_FAIL="${tags_fail}" \
        ACM_REQUEST_ARN="arn:aws:acm:us-east-1:123456789012:certificate/x" \
        RUNTIME_TMP="${case_dir}/runtime" \
        EASY_ALL_STATE_DIR_OVERRIDE="${case_dir}/state" \
        EASY_ALL_CERT_DIR_OVERRIDE="${case_dir}/state/certs" \
        EASY_ALL_SUBSCRIPTION_DIR_OVERRIDE="${case_dir}/state/subscriptions" \
        EASY_ALL_INSTALL_PROGRESS_FILE_OVERRIDE="${case_dir}/progress/install-progress.env" \
        AWS_ACM_CERTIFICATE_ARN="arn:aws:acm:us-east-1:123456789012:certificate/x" \
        bash -c '
            source "$1/profiles/cloudfront.sh"
            CF_ZONE=example.com
            CF_NODE_DOMAIN=cf.example.com
            SUBSCRIPTION_DOMAIN=sub.example.com
            CF_ORIGIN_DOMAIN=origin.example.com
            # 生产等待节奏由固定常量决定；这里只压缩 sleep，不改变判定条件。
            sleep() { :; }
            dns_ensure_record() { printf "DNS %s\n" "$1"; }
            find_or_request_acm_certificate
        ' _ "${ROOT_DIR}" 2>&1) || status=$?
    printf 'STATUS=%s\n' "${status}"
    printf '%s\n' "${output}"
}

acm_terminal_output=$(run_acm_terminal_case VALIDATION_TIMED_OUT)
assert_equal "终态 ACM 证书立即失败" "1" \
    "$(printf '%s\n' "${acm_terminal_output}" | sed -n 's/^STATUS=//p')"
assert_contains "终态 ACM 证书点名 ARN" "${acm_terminal_output}" \
    "arn:aws:acm:us-east-1:123456789012:certificate/x"
assert_contains "终态 ACM 证书指向 AWS 控制台删除后重试" "${acm_terminal_output}" \
    "AWS 控制台"
assert_not_contains "终态 ACM 证书不再建议 purge-cloud" "${acm_terminal_output}" \
    "purge-cloud"
assert_not_contains "终态 ACM 证书不再把 validation CNAME 当作排查点" \
    "${acm_terminal_output}" "检查 Cloudflare validation CNAME"
assert_not_contains "终态 ACM 证书不再重新申请" \
    "$(<"${TMP_DIR}/acm/VALIDATION_TIMED_OUT/aws.log")" "request-certificate"

acm_pending_output=$(run_acm_terminal_case PENDING_VALIDATION)
assert_equal "非终态 ACM 证书仍走到签发等待超时" "1" \
    "$(printf '%s\n' "${acm_pending_output}" | sed -n 's/^STATUS=//p')"
assert_contains "非终态 ACM 证书仍重新申请" \
    "$(<"${TMP_DIR}/acm/PENDING_VALIDATION/aws.log")" "request-certificate"
assert_contains "非终态 ACM 证书超时仍提示检查 validation CNAME" \
    "${acm_pending_output}" "检查 Cloudflare validation CNAME"
assert_not_contains "非终态 ACM 证书不误报终态" "${acm_pending_output}" "已进入终态"

# 34b. 终态证书但归属无法确认（如 list-tags 查询失败）：同样必须立即失败——幂等 Token
# 重申请只会空转到超时；但文案不得声称是本工具创建的证书。
acm_unconfirmed_output=$(run_acm_terminal_case FAILED '{"Tags":[]}' 1)
assert_equal "无法确认归属的终态 ACM 证书仍立即失败" "1" \
    "$(printf '%s\n' "${acm_unconfirmed_output}" | sed -n 's/^STATUS=//p')"
assert_contains "无法确认归属时点名 ARN" "${acm_unconfirmed_output}" \
    "arn:aws:acm:us-east-1:123456789012:certificate/x"
assert_contains "无法确认归属时明说无法确认" "${acm_unconfirmed_output}" \
    "无法自动确认归属"
assert_contains "无法确认归属时指向 AWS 控制台核对" "${acm_unconfirmed_output}" \
    "请到 AWS 控制台核对该证书"
assert_not_contains "无法确认归属时不声称是本工具证书" "${acm_unconfirmed_output}" \
    "带本节点管理标记"
assert_not_contains "无法确认归属时仍不建 purge-cloud" "${acm_unconfirmed_output}" \
    "purge-cloud"
assert_not_contains "无法确认归属时不把 validation CNAME 当作排查点" \
    "${acm_unconfirmed_output}" "检查 Cloudflare validation CNAME"
assert_not_contains "无法确认归属时不再重新申请" \
    "$(<"${TMP_DIR}/acm/FAILED/aws.log")" "request-certificate"

# 运行时清单完整性：漏登的文件不会随 install/self-update 安装，已安装机器上直接缺模块。
missing_from_manifest=""
for runtime_file in "${ROOT_DIR}"/lib/*.sh "${ROOT_DIR}"/profiles/*.sh "${ROOT_DIR}"/templates/*; do
    runtime_relative=${runtime_file#"${ROOT_DIR}/"}
    grep -qxF -- "${runtime_relative}" "${ROOT_DIR}/runtime.manifest" \
        || missing_from_manifest+=" ${runtime_relative}"
done
assert_equal "runtime.manifest 覆盖全部运行时文件" "" "${missing_from_manifest}"
assert_contains "manifest 包含 AnyTLS 模式库" "$(<"${ROOT_DIR}/runtime.manifest")" \
    "lib/anytls-mode.sh"

# --- A5：产品仅支持 IPv4（fail2ban 只留日志；sshd 关掉 IPv6） ---------------------
# 1) helper 的 IPv6 分支：不得对 ufw 发起任何调用，且必须成功退出（否则 fail2ban action 报错）。
a5_dir="${TMP_DIR}/a5-ipv6"
rm -rf "${a5_dir}"
mkdir -p "${a5_dir}"
cat >"${a5_dir}/ufw" <<'FAKE_UFW'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${A5_UFW_LOG}"
exit 0
FAKE_UFW
chmod +x "${a5_dir}/ufw"
: >"${a5_dir}/ufw.log"
A5_UFW_LOG="${a5_dir}/ufw.log" EASY_ALL_FAIL2BAN_UFW_BIN="${a5_dir}/ufw" \
    UFW_RULES_FILE="${a5_dir}/rules.txt" \
    bash -c 'source "$1/lib/log.sh"; source "$1/lib/platform.sh"
        write_fail2ban_cidr_ufw_helper "$2/helper.sh"' _ "${ROOT_DIR}" "${a5_dir}" \
    || fail "A5: 生成 fail2ban helper 失败"
a5_status=0
A5_UFW_LOG="${a5_dir}/ufw.log" EASY_ALL_FAIL2BAN_UFW_BIN="${a5_dir}/ufw" \
    UFW_RULES_FILE="${a5_dir}/rules.txt" \
    bash "${a5_dir}/helper.sh" ban "2001:db8::1" "${a5_dir}/state" || a5_status=$?
assert_equal "A5: IPv6 封禁请求必须成功退出" "0" "${a5_status}"
assert_equal "A5: IPv6 封禁不得调用 ufw" "0" "$(grep -c . "${a5_dir}/ufw.log" || true)"
[[ ! -e "${a5_dir}/state" ]] || [[ -z "$(find "${a5_dir}/state" -name '*.count' -print -quit)" ]] \
    || fail "A5: IPv6 封禁不得落下计数文件"

# 2) debian-init 的加固项（静态断言：整脚本需要 root + Debian，跑不了）。
debian_init_content=$(<"${ROOT_DIR}/scripts/debian-init.sh")
assert_contains "A5: 加固写入块包含 AddressFamily inet" "${debian_init_content}" \
    'echo "AddressFamily inet"'
assert_contains "A5: sshd -T 断言列表包含 addressfamily inet（小写键名）" \
    "${debian_init_content}" '"addressfamily inet"'
assert_contains "A5: 加固仍在输出「已关闭 IPv6 SSH」" "${debian_init_content}" \
    "已关闭 IPv6 SSH（产品仅支持 IPv4）"
# 只允许 reload：restart 会掐断在线的 SSH 会话。
assert_contains "A5: 加固生效走 reload" "${debian_init_content}" 'systemctl reload'
if grep -Eq 'systemctl[[:space:]]+restart[[:space:]]+"\$unit"' <<<"${debian_init_content}"; then
    fail "A5: 加固生效不得改成 restart"
fi

printf 'ok - install guard\n'

# --- A18：ss 查不了时 fail-open 但必须可见（tcp_port_listening 返回 2） --------------
a18_dir="${TMP_DIR}/a18"
rm -rf "${a18_dir}"
mkdir -p "${a18_dir}"
printf '#!/usr/bin/env bash\nexit 4\n' >"${a18_dir}/ss-fail"
printf '#!/usr/bin/env bash\nexit 0\n' >"${a18_dir}/ss-empty"
chmod +x "${a18_dir}/ss-fail" "${a18_dir}/ss-empty"

# 1) ss 执行失败（exit 4）：不得 die，但必须 warn。
a18_output=$(EASY_ALL_SS_CMD_OVERRIDE="${a18_dir}/ss-fail" \
    bash -c 'source "$1/lib/log.sh"; source "$1/lib/profile-common.sh"
        set +e
        assert_install_ports_free 8443
        printf "FREE_STATUS=%s\n" "$?"' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "A18: ss 执行失败必须告警可见" "${a18_output}" "无法检查端口 8443（ss 不可用）"
assert_contains "A18: ss 执行失败不阻断安装" "${a18_output}" "FREE_STATUS=0"

# 2) ss 命令不存在：同一分支（command -v 失败 → 返回 2）。
a18_missing=$(EASY_ALL_SS_CMD_OVERRIDE="${a18_dir}/no-such-ss" \
    bash -c 'source "$1/lib/log.sh"; source "$1/lib/profile-common.sh"
        set +e
        assert_install_ports_free 8443
        printf "FREE_STATUS=%s\n" "$?"' _ "${ROOT_DIR}" 2>&1) || true
assert_contains "A18: ss 不存在同样要告警" "${a18_missing}" "无法检查端口 8443（ss 不可用）"
assert_contains "A18: ss 不存在同样不阻断" "${a18_missing}" "FREE_STATUS=0"

# 3) 返回码语义：2=无法检查、1=确定无监听（0=有监听由既有 BUSY_PORTS 用例覆盖）。
rc_unavailable=$(EASY_ALL_SS_CMD_OVERRIDE="${a18_dir}/ss-fail" bash -c \
    'source "$1/lib/profile-common.sh"; set +e; tcp_port_listening 1; printf "%s" "$?"' _ "${ROOT_DIR}")
assert_equal "A18: ss 失败返回 2" "2" "${rc_unavailable}"
rc_idle=$(EASY_ALL_SS_CMD_OVERRIDE="${a18_dir}/ss-empty" bash -c \
    'source "$1/lib/profile-common.sh"; set +e; tcp_port_listening 1; printf "%s" "$?"' _ "${ROOT_DIR}")
assert_equal "A18: 无监听返回 1" "1" "${rc_idle}"

# --- B2：回源端口的「预存全局放行」预检（Anywhere / Any / 0.0.0.0/0 + inactive from-形态）---
b2_dir="${TMP_DIR}/b2-ufw"
rm -rf "${b2_dir}"
mkdir -p "${b2_dir}"
cat >"${b2_dir}/ufw" <<'FAKE_UFW'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-}" in
status)
    printf 'Status: %s\n\n' "${B2_STATE:-active}"
    if [[ "${B2_STATE:-active}" == "active" ]]; then
        printf 'To                         Action      From\n'
        printf -- '--                         ------      ----\n'
        [[ ! -f "${B2_RULES}" ]] || cat "${B2_RULES}"
    fi
    ;;
show)
    [[ -f "${B2_ADDED}" ]] && cat "${B2_ADDED}"
    ;;
esac
exit 0
FAKE_UFW
chmod +x "${b2_dir}/ufw"

b2_probe() { # $1=case 名（读同名文件作为 ufw 输出）$2=active|inactive $3=本工具的规则注释
    PATH="${b2_dir}:${PATH}" B2_RULES="${b2_dir}/$1.rules" B2_ADDED="${b2_dir}/$1.added" \
        B2_STATE="${2:-active}" UFW_RULE_COMMENT="${3:-easy_all-cf-origin-8443}" \
        bash -c 'source "$1/lib/firewall.sh"; set +e
            ufw_tcp_port_has_unmanaged_anywhere_allow 8443; printf "%s" "$?"' _ "${ROOT_DIR}"
}
# 三种等价来源形态都必须命中（返回 0）。
printf '[ 1] 8443/tcp                   ALLOW IN    Anywhere\n' >"${b2_dir}/anywhere.rules"
assert_equal "B2: Anywhere 来源的全局放行命中" "0" "$(b2_probe anywhere)"
printf '[ 1] 8443/tcp                   ALLOW IN    0.0.0.0/0\n' >"${b2_dir}/cidr.rules"
assert_equal "B2: 0.0.0.0/0 来源的全局放行命中" "0" "$(b2_probe cidr)"
printf '[ 1] 8443/tcp                   ALLOW IN    Any\n' >"${b2_dir}/any.rules"
assert_equal "B2: Any 来源的全局放行命中" "0" "$(b2_probe any)"
# 无预存（只有 easy_all 自己的注释规则/无关端口）不得命中。
printf '[ 1] 22/tcp                     ALLOW IN    Anywhere\n' >"${b2_dir}/none.rules"
assert_equal "B2: 无预存不得命中" "1" "$(b2_probe none)"
printf '[ 1] 8443/tcp                   ALLOW IN    Anywhere    # easy_all-cf-origin-8443\n' \
    >"${b2_dir}/managed.rules"
assert_equal "B2: easy_all 自己的 CF 段规则不算第三方放行" "1" "$(b2_probe managed)"
# UFW inactive：`ufw show added` 的 from-形态（第 2 轮补的解析）也必须命中。
printf 'ufw allow from 0.0.0.0/0 to any port 8443\n' >"${b2_dir}/inactive.added"
: >"${b2_dir}/inactive.rules"
assert_equal "B2: inactive 分支的 from-形态命中" "0" "$(b2_probe inactive inactive)"
# die 文案必须带自助步骤（ufw status）。
assert_contains "B2: 阻断文案给出 ufw status 自助步骤" "$(<"${ROOT_DIR}/lib/runtime-core.sh")" \
    "请先 ufw status 查明并移除该规则后重试"

# A32：文件尾汇总本轮未验证的用例，避免「skip 静默消失」。
if ((${#SKIPPED_ITEMS[@]} > 0)); then
    printf '未验证项（%s 条）：\n' "${#SKIPPED_ITEMS[@]}"
    printf '  - %s\n' "${SKIPPED_ITEMS[@]}"
fi

# A31 阶段一：本文件必须真的跑过断言（不校验条数，只拦「一个都没跑」）。
(( TESTS_ASSERTED > 0 )) || fail "无断言执行：本文件一个断言都没跑，fixture/前置条件出错时会静默全绿"
printf 'ok - asserted %s\n' "${TESTS_ASSERTED}"
